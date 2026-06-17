// movie_gen-plugin — Minerva Movie Generator plugin MCP server.
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
const SERVER_NAME: &str = "movie_gen";
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

/// Best-effort: surface a produced artifact in the host UI. PANEL-FIRST — the
/// plugin has its own VideoStreamPlayer, so open the movie-gen panel (idempotent)
/// and emit a `movie_gen.result` event it loads into that player. Only if the
/// panel can't be opened do we fall back to the OS media viewer (os_open).
/// Surfacing is a convenience — the path is already returned to the caller — so
/// any failure is logged and swallowed, never failing the gen. Skipped in
/// background mode.
fn surface_artifact(
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
    path: &str,
) {
    match request_capability(
        out,
        lines,
        next_id,
        "mcp.proxy:minerva_plugin_open_panel",
        json!({"plugin_id": "movie_gen", "panel_name": "movie_gen_panel"}),
    ) {
        Ok(_) => {
            emit_result(out, path);
            log::info!("surfaced artifact in panel: {path}");
        }
        Err(e) => {
            log::warn!("panel surface failed ({e}); falling back to os_open");
            match request_capability(
                out,
                lines,
                next_id,
                "mcp.proxy:minerva_os_open",
                json!({"path": path}),
            ) {
                Ok(_) => log::info!("surfaced artifact via os_open fallback: {path}"),
                Err(e2) => log::warn!("could not surface artifact {path}: {e2}"),
            }
        }
    }
}

/// One-way event telling an open movie-gen panel to load a freshly produced
/// video into its player (mirrors emit_progress).
fn emit_result(out: &mut (impl Write + ?Sized), path: &str) {
    let notif = json!({
        "jsonrpc": "2.0",
        "method": "minerva/plugin_event",
        "params": {
            "event": "movie_gen.result",
            "payload": { "path": path },
        },
    });
    write_line(out, &notif);
}

// ─────────────────────────────────────────────────────────────────────────────
// Credential fetch
// ─────────────────────────────────────────────────────────────────────────────

/// Fetch media-gen credentials via host.core.session capability.
/// Returns Credentials on success or a tool_err Value on failure.
fn fetch_credentials(
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> Result<Credentials, Value> {
    let response = request_capability(out, lines, next_id, "host.core.session", json!({}))
        .map_err(|e| {
            log::error!("host.core.session failed: {e}");
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

/// Save an MP4 artifact to temp_dir()/minerva-movie-gen/<filename>.
/// Returns the absolute path string.
fn save_artifact(filename: &str, bytes: &[u8]) -> Result<String, String> {
    let dir = std::env::temp_dir().join("minerva-movie-gen");
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
            "event": "movie_gen.progress",
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
    background: bool,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
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
            // Use the first artifact (MP4).
            let artifact = &artifacts[0];
            match save_artifact(&artifact.filename, &artifact.bytes) {
                Err(e) => tool_err(&format!("failed to save artifact: {e}")),
                Ok(path) => {
                    // Default = surface in the UI; background mode just returns the path.
                    if !background {
                        surface_artifact(out, lines, next_id, &path);
                    }
                    tool_ok(json!({
                        "path": path,
                        "filename": artifact.filename,
                        "bytes": artifact.bytes.len(),
                    }))
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tool handlers
// ─────────────────────────────────────────────────────────────────────────────

fn handle_text_to_video(
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
        .unwrap_or("blurry, low quality, static, distorted, watermark")
        .to_string();

    let width = args
        .get("width")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(1280)
        .clamp(256, 1280);

    let height = args
        .get("height")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(720)
        .clamp(256, 720);

    let length = args
        .get("length")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(81)
        .clamp(17, 121);

    let fps = args
        .get("fps")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(16)
        .clamp(8, 30);

    let seed = args
        .get("seed")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(-1);

    let steps = args
        .get("steps")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(20)
        .clamp(4, 40);

    let switch_step = args
        .get("switch_step")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(10)
        .clamp(1, 39);

    let cfg = args
        .get("cfg")
        .and_then(|v| v.as_f64())
        .unwrap_or(5.0)
        .clamp(1.0, 12.0);

    let crf = args
        .get("crf")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(18)
        .clamp(0, 28);

    // background=true → generate silently, just return the path (for programmatic
    // chaining). Default false → surface the result in the OS media viewer.
    let background = args
        .get("background")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Fetch credentials
    let creds = match fetch_credentials(out, lines, next_id) {
        Ok(c) => c,
        Err(e) => return ok_response(id, e),
    };

    let gen_params = json!({
        "positive_prompt": positive_prompt,
        "negative_prompt": negative_prompt,
        "width": width,
        "height": height,
        "length": length,
        "fps": fps,
        "seed": seed,
        "steps": steps,
        "switch_step": switch_step,
        "cfg": cfg,
        "crf": crf,
    });

    let req = GenerateRequest {
        topic: "media_gen/text_to_video".into(),
        workflow: "text_to_video".into(),
        params: gen_params,
        files: vec![],
    };

    let result = run_generate(creds, req, background, out, lines, next_id);
    ok_response(id, result)
}

fn handle_flf2v(
    params: &Value,
    id: Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    let first_frame_path = match args.get("first_frame_path").and_then(|v| v.as_str()) {
        Some(p) if !p.is_empty() => p.to_string(),
        _ => return ok_response(id, tool_err("first_frame_path is required")),
    };

    let last_frame_path = match args.get("last_frame_path").and_then(|v| v.as_str()) {
        Some(p) if !p.is_empty() => p.to_string(),
        _ => return ok_response(id, tool_err("last_frame_path is required")),
    };

    // Prompt is OPTIONAL for first-last-frame interpolation — the two keyframes
    // are the primary signal. Default to empty when absent/blank.
    let positive_prompt = args
        .get("positive_prompt")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let negative_prompt = args
        .get("negative_prompt")
        .and_then(|v| v.as_str())
        .unwrap_or("blurry, low quality, static, distorted, watermark")
        .to_string();

    let width = args
        .get("width")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(1280)
        .clamp(256, 1280);

    let height = args
        .get("height")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(720)
        .clamp(256, 720);

    let length = args
        .get("length")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(81)
        .clamp(17, 121);

    let fps = args
        .get("fps")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(16)
        .clamp(8, 30);

    let seed = args
        .get("seed")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(-1);

    let steps = args
        .get("steps")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(20)
        .clamp(4, 40);

    let switch_step = args
        .get("switch_step")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(10)
        .clamp(1, 39);

    let cfg = args
        .get("cfg")
        .and_then(|v| v.as_f64())
        .unwrap_or(5.0)
        .clamp(1.0, 12.0);

    let crf = args
        .get("crf")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(18)
        .clamp(0, 28);

    // background=true → generate silently, just return the path (for programmatic
    // chaining). Default false → surface the result in the OS media viewer.
    let background = args
        .get("background")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Read both image files from disk BEFORE fetching credentials,
    // so we return a structured tool error early if either is missing.
    let first_bytes = match std::fs::read(&first_frame_path) {
        Ok(b) => b,
        Err(e) => {
            return ok_response(
                id,
                tool_err(&format!("could not read first_frame_path {first_frame_path}: {e}")),
            )
        }
    };

    let last_bytes = match std::fs::read(&last_frame_path) {
        Ok(b) => b,
        Err(e) => {
            return ok_response(
                id,
                tool_err(&format!("could not read last_frame_path {last_frame_path}: {e}")),
            )
        }
    };

    let first_basename = Path::new(&first_frame_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("first_frame.png")
        .to_string();

    let last_basename = Path::new(&last_frame_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("last_frame.png")
        .to_string();

    // Fetch credentials
    let creds = match fetch_credentials(out, lines, next_id) {
        Ok(c) => c,
        Err(e) => return ok_response(id, e),
    };

    let gen_params = json!({
        "positive_prompt": positive_prompt,
        "negative_prompt": negative_prompt,
        "width": width,
        "height": height,
        "length": length,
        "fps": fps,
        "seed": seed,
        "steps": steps,
        "switch_step": switch_step,
        "cfg": cfg,
        "crf": crf,
    });

    let req = GenerateRequest {
        topic: "media_gen/flf2v".into(),
        workflow: "flf2v".into(),
        params: gen_params,
        files: vec![
            InputFile {
                filename: first_basename,
                role: "first_frame".into(),
                bytes: first_bytes,
                content_type: "image/png".into(),
            },
            InputFile {
                filename: last_basename,
                role: "last_frame".into(),
                bytes: last_bytes,
                content_type: "image/png".into(),
            },
        ],
    };

    let result = run_generate(creds, req, background, out, lines, next_id);
    ok_response(id, result)
}

fn handle_i2v(
    params: &Value,
    id: Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let args = params.get("arguments").unwrap_or(params);

    let start_frame_path = match args.get("start_frame_path").and_then(|v| v.as_str()) {
        Some(p) if !p.is_empty() => p.to_string(),
        _ => return ok_response(id, tool_err("start_frame_path is required")),
    };

    // Prompt is OPTIONAL for image-to-video — the start keyframe is the primary
    // signal. Default to empty when absent/blank.
    let positive_prompt = args
        .get("positive_prompt")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let negative_prompt = args
        .get("negative_prompt")
        .and_then(|v| v.as_str())
        .unwrap_or("blurry, low quality, static, distorted, watermark")
        .to_string();

    let width = args
        .get("width")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(1280)
        .clamp(256, 1280);

    let height = args
        .get("height")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(720)
        .clamp(256, 720);

    let length = args
        .get("length")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(81)
        .clamp(17, 121);

    let fps = args
        .get("fps")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(16)
        .clamp(8, 30);

    let seed = args
        .get("seed")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(-1);

    let steps = args
        .get("steps")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(20)
        .clamp(4, 40);

    let switch_step = args
        .get("switch_step")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(10)
        .clamp(1, 39);

    let cfg = args
        .get("cfg")
        .and_then(|v| v.as_f64())
        .unwrap_or(5.0)
        .clamp(1.0, 12.0);

    let crf = args
        .get("crf")
        .and_then(|v| lax_i64(Some(v)))
        .unwrap_or(18)
        .clamp(0, 28);

    // background=true → generate silently, just return the path (for programmatic
    // chaining). Default false → surface the result in the OS media viewer.
    let background = args
        .get("background")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Read the start image BEFORE fetching credentials so a missing file
    // returns a structured tool error early.
    let start_bytes = match std::fs::read(&start_frame_path) {
        Ok(b) => b,
        Err(e) => {
            return ok_response(
                id,
                tool_err(&format!("could not read start_frame_path {start_frame_path}: {e}")),
            )
        }
    };

    let start_basename = Path::new(&start_frame_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("start_frame.png")
        .to_string();

    // Fetch credentials
    let creds = match fetch_credentials(out, lines, next_id) {
        Ok(c) => c,
        Err(e) => return ok_response(id, e),
    };

    let gen_params = json!({
        "positive_prompt": positive_prompt,
        "negative_prompt": negative_prompt,
        "width": width,
        "height": height,
        "length": length,
        "fps": fps,
        "seed": seed,
        "steps": steps,
        "switch_step": switch_step,
        "cfg": cfg,
        "crf": crf,
    });

    let req = GenerateRequest {
        topic: "media_gen/i2v".into(),
        workflow: "i2v".into(),
        params: gen_params,
        files: vec![InputFile {
            filename: start_basename,
            role: "start_frame".into(),
            bytes: start_bytes,
            content_type: "image/png".into(),
        }],
    };

    let result = run_generate(creds, req, background, out, lines, next_id);
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
                "name": "minerva_movie_gen_text_to_video",
                "description": "Generate a video (MP4) from a text prompt via the Minerva media-gen service. Returns the path to the saved MP4 file.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "positive_prompt": {
                            "type": "string",
                            "description": "Text description of the video to generate."
                        },
                        "negative_prompt": {
                            "type": "string",
                            "description": "Text description of things to avoid in the generation. Default: 'blurry, low quality, static, distorted, watermark'."
                        },
                        "width": {
                            "type": "integer",
                            "description": "Output video width in pixels (256–1280). Default: 1280.",
                            "default": 1280,
                            "minimum": 256,
                            "maximum": 1280
                        },
                        "height": {
                            "type": "integer",
                            "description": "Output video height in pixels (256–720). Default: 720.",
                            "default": 720,
                            "minimum": 256,
                            "maximum": 720
                        },
                        "length": {
                            "type": "integer",
                            "description": "Number of frames to generate (17–121). Default: 81.",
                            "default": 81,
                            "minimum": 17,
                            "maximum": 121
                        },
                        "fps": {
                            "type": "integer",
                            "description": "Frames per second for the output video (8–30). Default: 16.",
                            "default": 16,
                            "minimum": 8,
                            "maximum": 30
                        },
                        "seed": {
                            "type": "integer",
                            "description": "Random seed. -1 means random. Default: -1.",
                            "default": -1
                        },
                        "steps": {
                            "type": "integer",
                            "description": "Number of diffusion steps (4–40). Default: 20.",
                            "default": 20,
                            "minimum": 4,
                            "maximum": 40
                        },
                        "switch_step": {
                            "type": "integer",
                            "description": "Step at which the sampler switches (1–39). Default: 10.",
                            "default": 10,
                            "minimum": 1,
                            "maximum": 39
                        },
                        "cfg": {
                            "type": "number",
                            "description": "Classifier-free guidance scale (1–12). Default: 5.0.",
                            "default": 5.0,
                            "minimum": 1,
                            "maximum": 12
                        },
                        "crf": {
                            "type": "integer",
                            "description": "H.264 quality (constant rate factor). Lower = higher quality, larger file. 18 ≈ visually lossless. Range 0–28. Default: 18.",
                            "default": 18,
                            "minimum": 0,
                            "maximum": 28
                        },
                        "background": {
                            "type": "boolean",
                            "description": "If true, generate silently and just return the file path — no UI surfacing — for programmatic chaining (e.g. save then upload). If false (default), the result opens in the OS media viewer so the user sees it.",
                            "default": false
                        }
                    },
                    "required": ["positive_prompt"]
                }
            },
            {
                "name": "minerva_movie_gen_flf2v",
                "description": "Generate a video (MP4) by interpolating between a first and last keyframe image via the Minerva media-gen service. Returns the path to the saved MP4 file.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "first_frame_path": {
                            "type": "string",
                            "description": "Absolute path to the start keyframe image on disk."
                        },
                        "last_frame_path": {
                            "type": "string",
                            "description": "Absolute path to the end keyframe image on disk."
                        },
                        "positive_prompt": {
                            "type": "string",
                            "description": "Text description of the motion or transition to generate."
                        },
                        "negative_prompt": {
                            "type": "string",
                            "description": "Text description of things to avoid in the generation. Default: 'blurry, low quality, static, distorted, watermark'."
                        },
                        "width": {
                            "type": "integer",
                            "description": "Output video width in pixels (256–1280). Default: 1280.",
                            "default": 1280,
                            "minimum": 256,
                            "maximum": 1280
                        },
                        "height": {
                            "type": "integer",
                            "description": "Output video height in pixels (256–720). Default: 720.",
                            "default": 720,
                            "minimum": 256,
                            "maximum": 720
                        },
                        "length": {
                            "type": "integer",
                            "description": "Number of frames to generate (17–121). Default: 81.",
                            "default": 81,
                            "minimum": 17,
                            "maximum": 121
                        },
                        "fps": {
                            "type": "integer",
                            "description": "Frames per second for the output video (8–30). Default: 16.",
                            "default": 16,
                            "minimum": 8,
                            "maximum": 30
                        },
                        "seed": {
                            "type": "integer",
                            "description": "Random seed. -1 means random. Default: -1.",
                            "default": -1
                        },
                        "steps": {
                            "type": "integer",
                            "description": "Number of diffusion steps (4–40). Default: 20.",
                            "default": 20,
                            "minimum": 4,
                            "maximum": 40
                        },
                        "switch_step": {
                            "type": "integer",
                            "description": "Step at which the sampler switches (1–39). Default: 10.",
                            "default": 10,
                            "minimum": 1,
                            "maximum": 39
                        },
                        "cfg": {
                            "type": "number",
                            "description": "Classifier-free guidance scale (1–12). Default: 5.0.",
                            "default": 5.0,
                            "minimum": 1,
                            "maximum": 12
                        },
                        "crf": {
                            "type": "integer",
                            "description": "H.264 quality (constant rate factor). Lower = higher quality, larger file. 18 ≈ visually lossless. Range 0–28. Default: 18.",
                            "default": 18,
                            "minimum": 0,
                            "maximum": 28
                        },
                        "background": {
                            "type": "boolean",
                            "description": "If true, generate silently and just return the file path — no UI surfacing — for programmatic chaining (e.g. save then upload). If false (default), the result opens in the OS media viewer so the user sees it.",
                            "default": false
                        }
                    },
                    "required": ["first_frame_path", "last_frame_path"]
                }
            },
            {
                "name": "minerva_movie_gen_i2v",
                "description": "Generate a video (MP4) by animating a single start keyframe image forward via the Minerva media-gen service. The prompt is optional (the keyframe drives the result). Returns the path to the saved MP4 file.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "start_frame_path": {
                            "type": "string",
                            "description": "Absolute path to the start keyframe image on disk."
                        },
                        "positive_prompt": {
                            "type": "string",
                            "description": "Optional text describing the motion to animate from the start frame."
                        },
                        "negative_prompt": {
                            "type": "string",
                            "description": "Text description of things to avoid in the generation. Default: 'blurry, low quality, static, distorted, watermark'."
                        },
                        "width": {
                            "type": "integer",
                            "description": "Output video width in pixels (256–1280). Default: 1280.",
                            "default": 1280,
                            "minimum": 256,
                            "maximum": 1280
                        },
                        "height": {
                            "type": "integer",
                            "description": "Output video height in pixels (256–720). Default: 720.",
                            "default": 720,
                            "minimum": 256,
                            "maximum": 720
                        },
                        "length": {
                            "type": "integer",
                            "description": "Number of frames to generate (17–121). Default: 81.",
                            "default": 81,
                            "minimum": 17,
                            "maximum": 121
                        },
                        "fps": {
                            "type": "integer",
                            "description": "Frames per second for the output video (8–30). Default: 16.",
                            "default": 16,
                            "minimum": 8,
                            "maximum": 30
                        },
                        "seed": {
                            "type": "integer",
                            "description": "Random seed. -1 means random. Default: -1.",
                            "default": -1
                        },
                        "steps": {
                            "type": "integer",
                            "description": "Number of diffusion steps (4–40). Default: 20.",
                            "default": 20,
                            "minimum": 4,
                            "maximum": 40
                        },
                        "switch_step": {
                            "type": "integer",
                            "description": "Step at which the sampler switches (1–39). Default: 10.",
                            "default": 10,
                            "minimum": 1,
                            "maximum": 39
                        },
                        "cfg": {
                            "type": "number",
                            "description": "Classifier-free guidance scale (1–12). Default: 5.0.",
                            "default": 5.0,
                            "minimum": 1,
                            "maximum": 12
                        },
                        "crf": {
                            "type": "integer",
                            "description": "H.264 quality (constant rate factor). Lower = higher quality, larger file. 18 ≈ visually lossless. Range 0–28. Default: 18.",
                            "default": 18,
                            "minimum": 0,
                            "maximum": 28
                        },
                        "background": {
                            "type": "boolean",
                            "description": "If true, generate silently and just return the file path — no UI surfacing — for programmatic chaining (e.g. save then upload). If false (default), the result opens in the OS media viewer so the user sees it.",
                            "default": false
                        }
                    },
                    "required": ["start_frame_path"]
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
                    "minerva_movie_gen_text_to_video" => {
                        handle_text_to_video(&req.params, req.id, &mut out, &mut lines, &mut next_id)
                    }
                    "minerva_movie_gen_flf2v" => {
                        handle_flf2v(&req.params, req.id, &mut out, &mut lines, &mut next_id)
                    }
                    "minerva_movie_gen_i2v" => {
                        handle_i2v(&req.params, req.id, &mut out, &mut lines, &mut next_id)
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
