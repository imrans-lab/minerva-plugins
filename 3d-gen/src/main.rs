// gen3d-plugin — Minerva 3D Generator plugin MCP server.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
// Logging goes to stderr; stdout carries only JSON-RPC traffic.
//
// Capability re-entrancy contract (from Minerva broker):
// While the plugin is handling a tools/call, Minerva will NOT send another
// tools/call. So when a handler writes a minerva/capability request to stdout,
// the next line on stdin is guaranteed to be either:
//   (a) the matching response (correlated by id), or
//   (b) stdin EOF.
// The synchronous read pattern below is safe under that guarantee.

use std::io::{self, BufRead, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use minerva_media_client::{
    Credentials, GenerateRequest, InputFile, MediaGenClient, MediaGenConfig, Progress,
};

const PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "gen3d";
const SERVER_VERSION: &str = "0.0.1";

// ─────────────────────────────────────────────────────────────────────────────
// JSON-RPC types
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Deserialize, Debug)]
struct RpcRequest {
    #[serde(default)]
    #[allow(dead_code)] // deserialized for protocol completeness; not read
    jsonrpc: String,
    #[serde(default)]
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Serialize)]
struct RpcResponse {
    jsonrpc: String,
    id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<RpcError>,
}

#[derive(Serialize)]
struct RpcError {
    code: i64,
    message: String,
}

fn ok_response(id: Value, result: Value) -> RpcResponse {
    RpcResponse { jsonrpc: "2.0".into(), id, result: Some(result), error: None }
}

fn err_response(id: Value, code: i64, message: String) -> RpcResponse {
    RpcResponse { jsonrpc: "2.0".into(), id, result: None, error: Some(RpcError { code, message }) }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stdio helpers
// ─────────────────────────────────────────────────────────────────────────────

fn write_line(out: &mut (impl Write + ?Sized), v: &impl Serialize) {
    let s = serde_json::to_string(v).unwrap_or_else(|e| {
        log::error!("serialize response: {e}");
        String::new()
    });
    if let Err(e) = writeln!(out, "{}", s) {
        log::error!("write response: {e}");
    }
    let _ = out.flush();
}

// ─────────────────────────────────────────────────────────────────────────────
// Tool content helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Wrap a JSON value as a text content MCP tool result.
fn tool_ok(payload: Value) -> Value {
    let text = serde_json::to_string(&payload).unwrap_or_else(|_| r#"{"ok":false}"#.into());
    json!({ "content": [{"type": "text", "text": text}] })
}

/// Return an MCP isError tool result with a message string.
fn tool_err(message: &str) -> Value {
    let text = serde_json::to_string(&json!({"error": message}))
        .unwrap_or_else(|_| r#"{"error":"serialisation failed"}"#.into());
    json!({ "isError": true, "content": [{"type": "text", "text": text}] })
}

// ─────────────────────────────────────────────────────────────────────────────
// Capability request/response
// ─────────────────────────────────────────────────────────────────────────────

/// Send a minerva/capability request to the host and read the matching
/// response. Safe only within a tools/call handler (re-entrancy contract above).
fn request_capability(
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
    capability: &str,
    args: Value,
) -> Result<Value, String> {
    *next_id += 1;
    let id = format!("cap-{}", next_id);

    let req = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "minerva/capability",
        "params": {
            "capability": capability,
            "args": args,
        }
    });
    write_line(out, &req);
    log::debug!("sent capability request id={id} capability={capability}");

    // Per re-entrancy contract, the next message on stdin is our response.
    // Defensively skip non-JSON and unexpected ids rather than deadlocking.
    for line_result in lines.by_ref() {
        let line = line_result.map_err(|e| format!("stdin read error: {e}"))?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(e) => {
                log::warn!("non-JSON line while waiting for capability response: {e}");
                continue;
            }
        };
        let msg_id = msg.get("id").cloned().unwrap_or(Value::Null);
        if msg_id.as_str() != Some(&id) {
            log::warn!("unexpected message id {:?} while waiting for {} (skipped)", msg_id, id);
            continue;
        }
        if let Some(err) = msg.get("error") {
            return Err(format!("capability error: {err}"));
        }
        return Ok(msg.get("result").cloned().unwrap_or(Value::Null));
    }
    Err("stdin closed waiting for capability response".into())
}

// ─────────────────────────────────────────────────────────────────────────────
// Credential fetch
// ─────────────────────────────────────────────────────────────────────────────

/// Fetch media-gen credentials via host.media.credentials capability.
/// Returns Credentials on success or a tool_err Value on failure.
fn fetch_credentials(
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> Result<Credentials, Value> {
    let response = request_capability(out, lines, next_id, "host.media.credentials", json!({}))
        .map_err(|e| {
            log::error!("host.media.credentials failed: {e}");
            tool_err(&format!("credentials unavailable: {e}"))
        })?;

    let result = response.get("result").unwrap_or(&response);

    let ws_url = result
        .get("ws_url")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let token = result
        .get("token")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let client_id = result
        .get("client_id")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    if ws_url.is_empty() || token.is_empty() || client_id.is_empty() {
        return Err(tool_err(&format!(
            "credentials response missing required fields (ws_url/token/client_id); got: {}",
            result
        )));
    }

    Ok(Credentials { ws_url, token, client_id })
}

// ─────────────────────────────────────────────────────────────────────────────
// Output artifact saving
// ─────────────────────────────────────────────────────────────────────────────

/// Save a GLB artifact to temp_dir()/minerva-gen3d/<filename>.
/// Returns the absolute path string.
fn save_artifact(filename: &str, bytes: &[u8]) -> Result<String, String> {
    let dir = std::env::temp_dir().join("minerva-gen3d");
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("could not create temp dir {}: {e}", dir.display()))?;
    let out_path = dir.join(filename);
    std::fs::write(&out_path, bytes)
        .map_err(|e| format!("could not write artifact {}: {e}", out_path.display()))?;
    Ok(out_path.to_string_lossy().into_owned())
}

// ─────────────────────────────────────────────────────────────────────────────
// Progress notification helper
// ─────────────────────────────────────────────────────────────────────────────

/// Emit a one-way JSON-RPC notification for generation progress.
/// Written directly to stdout; does NOT consume stdin.
fn emit_progress(out: &mut (impl Write + ?Sized), message: &str) {
    let notif = json!({
        "jsonrpc": "2.0",
        "method": "minerva/plugin_event",
        "params": {
            "event": "gen3d.progress",
            "payload": { "message": message },
        },
    });
    write_line(out, &notif);
}

// ─────────────────────────────────────────────────────────────────────────────
// Generation runner (shared by both tools)
// ─────────────────────────────────────────────────────────────────────────────

/// Connect, generate, save, return tool_ok or tool_err value.
/// `out_for_progress` is taken by raw pointer so we can pass it into the
/// FnMut callback without fighting the borrow checker — safe because the
/// callback is only called during `client.generate()` on the same thread.
fn run_generate(
    creds: Credentials,
    req: GenerateRequest,
    out: &mut impl Write,
) -> Value {
    // Connect
    let mut client = match MediaGenClient::connect(MediaGenConfig::default(), creds) {
        Ok(c) => c,
        Err(e) => return tool_err(&format!("connect failed: {e}")),
    };

    // The progress callback reborrows `out` on each call (`&mut *out`); the
    // closure is synchronous and `out` is used nowhere else for the duration of
    // generate(), so a plain reborrow satisfies the borrow checker — no unsafe.
    let artifacts = {
        let mut on_progress = |p: Progress| {
            let Progress::Notification(msg) = p;
            emit_progress(&mut *out, &msg);
        };
        client.generate(req, &mut on_progress)
    };

    match artifacts {
        Err(e) => {
            log::error!("generate failed: {e}");
            tool_err(&format!("generation failed: {e}"))
        }
        Ok(artifacts) => {
            if artifacts.is_empty() {
                return tool_err("generation succeeded but no artifacts were returned");
            }
            // Use the first artifact (GLB).
            let artifact = &artifacts[0];
            match save_artifact(&artifact.filename, &artifact.bytes) {
                Err(e) => tool_err(&format!("failed to save artifact: {e}")),
                Ok(path) => tool_ok(json!({
                    "path": path,
                    "filename": artifact.filename,
                    "bytes": artifact.bytes.len(),
                })),
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tool handlers
// ─────────────────────────────────────────────────────────────────────────────

fn handle_text_to_3d(
    params: &Value,
    id: Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    let positive_prompt = match args.get("positive_prompt").and_then(|v| v.as_str()) {
        Some(p) if !p.is_empty() => p.to_string(),
        _ => return ok_response(id, tool_err("positive_prompt is required")),
    };

    let negative_prompt = args
        .get("negative_prompt")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let seed = args
        .get("seed")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(-1);

    let steps = args
        .get("steps")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(25)
        .clamp(1, 50);

    let guidance = args
        .get("guidance")
        .and_then(|v| v.as_f64())
        .unwrap_or(5.5)
        .clamp(1.0, 15.0);

    // Fetch credentials
    let creds = match fetch_credentials(out, lines, next_id) {
        Ok(c) => c,
        Err(e) => return ok_response(id, e),
    };

    let mut gen_params = json!({
        "positive_prompt": positive_prompt,
        "seed": seed,
        "steps": steps,
        "guidance": guidance,
    });
    if !negative_prompt.is_empty() {
        gen_params["negative_prompt"] = json!(negative_prompt);
    }

    let req = GenerateRequest {
        topic: "media_gen/text_to_3d".into(),
        workflow: "text_to_3d".into(),
        params: gen_params,
        files: vec![],
    };

    let result = run_generate(creds, req, out);
    ok_response(id, result)
}

fn handle_image_to_3d(
    params: &Value,
    id: Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    let image_path_str = match args.get("image_path").and_then(|v| v.as_str()) {
        Some(p) if !p.is_empty() => p.to_string(),
        _ => return ok_response(id, tool_err("image_path is required")),
    };

    let seed = args
        .get("seed")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(-1);

    let steps = args
        .get("steps")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(30)
        .clamp(10, 100);

    let guidance = args
        .get("guidance")
        .and_then(|v| v.as_f64())
        .unwrap_or(5.5)
        .clamp(1.0, 15.0);

    // Read image from disk
    let image_bytes = match std::fs::read(&image_path_str) {
        Ok(b) => b,
        Err(e) => {
            return ok_response(
                id,
                tool_err(&format!("could not read image_path {image_path_str}: {e}")),
            )
        }
    };

    let basename = Path::new(&image_path_str)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("image.png")
        .to_string();

    // Fetch credentials
    let creds = match fetch_credentials(out, lines, next_id) {
        Ok(c) => c,
        Err(e) => return ok_response(id, e),
    };

    let gen_params = json!({
        "seed": seed,
        "steps": steps,
        "guidance": guidance,
    });

    let req = GenerateRequest {
        topic: "media_gen/image_to_3d".into(),
        workflow: "image_to_3d".into(),
        params: gen_params,
        files: vec![InputFile {
            filename: basename,
            role: "image".into(),
            bytes: image_bytes,
            content_type: "image/png".into(),
        }],
    };

    let result = run_generate(creds, req, out);
    ok_response(id, result)
}

// ─────────────────────────────────────────────────────────────────────────────
// Numeric arg helpers (mirrors scansort pattern for Godot float relay)
// ─────────────────────────────────────────────────────────────────────────────

/// Accept a JSON value as an i64. Accepts integer JSON numbers AND
/// integral, finite floats (1.0, -7.0). Rejects fractional floats.
fn lax_i64(v: Option<&Value>) -> Option<i64> {
    let v = v?;
    if let Some(i) = v.as_i64() {
        return Some(i);
    }
    if let Some(f) = v.as_f64() {
        if f.is_finite() && f == f.trunc() && f >= i64::MIN as f64 && f <= i64::MAX as f64 {
            return Some(f as i64);
        }
    }
    None
}

// ─────────────────────────────────────────────────────────────────────────────
// tools/list inline schema
// ─────────────────────────────────────────────────────────────────────────────

fn tools_list_result() -> Value {
    json!({
        "tools": [
            {
                "name": "minerva_gen3d_text_to_3d",
                "description": "Generate a 3D model (GLB) from a text prompt via the Minerva media-gen service. Returns the path to the saved GLB file.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "positive_prompt": {
                            "type": "string",
                            "description": "Text description of the 3D object to generate."
                        },
                        "negative_prompt": {
                            "type": "string",
                            "description": "Text description of things to avoid in the generation."
                        },
                        "seed": {
                            "type": "integer",
                            "description": "Random seed. -1 means random. Default: -1.",
                            "default": -1
                        },
                        "steps": {
                            "type": "integer",
                            "description": "Number of diffusion steps (1–50). Default: 25.",
                            "default": 25,
                            "minimum": 1,
                            "maximum": 50
                        },
                        "guidance": {
                            "type": "number",
                            "description": "Guidance scale (1–15). Default: 5.5.",
                            "default": 5.5,
                            "minimum": 1,
                            "maximum": 15
                        }
                    },
                    "required": ["positive_prompt"]
                }
            },
            {
                "name": "minerva_gen3d_image_to_3d",
                "description": "Generate a 3D model (GLB) from a reference image via the Minerva media-gen service. Returns the path to the saved GLB file.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "image_path": {
                            "type": "string",
                            "description": "Absolute path to a PNG or JPG image on disk to use as the reference."
                        },
                        "seed": {
                            "type": "integer",
                            "description": "Random seed. -1 means random. Default: -1.",
                            "default": -1
                        },
                        "steps": {
                            "type": "integer",
                            "description": "Number of diffusion steps (10–100). Default: 30.",
                            "default": 30,
                            "minimum": 10,
                            "maximum": 100
                        },
                        "guidance": {
                            "type": "number",
                            "description": "Guidance scale (1–15). Default: 5.5.",
                            "default": 5.5,
                            "minimum": 1,
                            "maximum": 15
                        }
                    },
                    "required": ["image_path"]
                }
            }
        ]
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Main loop
// ─────────────────────────────────────────────────────────────────────────────

fn main() {
    // Logging goes to stderr so it never pollutes the JSON-RPC stdout channel.
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .target(env_logger::Target::Stderr)
        .init();

    log::info!("{SERVER_NAME} {SERVER_VERSION} starting");

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    let mut lines = stdin.lock().lines();
    let mut next_id: u64 = 0;

    while let Some(line_result) = lines.next() {
        let line = match line_result {
            Ok(l) => l,
            Err(e) => {
                log::error!("stdin read: {e}");
                break;
            }
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let req: RpcRequest = match serde_json::from_str(trimmed) {
            Ok(r) => r,
            Err(e) => {
                log::warn!("malformed request: {e} — {trimmed}");
                continue;
            }
        };

        log::debug!("← {}", req.method);

        let resp = match req.method.as_str() {
            "initialize" => ok_response(
                req.id,
                json!({
                    "protocolVersion": PROTOCOL_VERSION,
                    "serverName": SERVER_NAME,
                    "serverVersion": SERVER_VERSION,
                    "capabilities": {"tools": {}},
                }),
            ),

            "tools/list" => ok_response(req.id, tools_list_result()),

            "tools/call" => {
                let tool_name = req
                    .params
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");

                match tool_name {
                    "minerva_gen3d_text_to_3d" => {
                        handle_text_to_3d(&req.params, req.id, &mut out, &mut lines, &mut next_id)
                    }
                    "minerva_gen3d_image_to_3d" => {
                        handle_image_to_3d(&req.params, req.id, &mut out, &mut lines, &mut next_id)
                    }
                    other => err_response(
                        req.id,
                        -32601,
                        format!("unknown tool: {other}"),
                    ),
                }
            }

            // notifications/initialized has no id — ignore silently.
            "notifications/initialized" => continue,

            other => {
                log::warn!("unknown method: {other}");
                err_response(req.id, -32601, format!("method not found: {other}"))
            }
        };

        write_line(&mut out, &resp);
    }

    log::info!("{SERVER_NAME} exiting");
}
