// drive-plugin — Minerva Drive plugin MCP server.
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

use std::collections::HashMap;
use std::io::{self, BufRead, Write};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use artifact_client::{ArtifactClient, Credentials};
use sync::{ArtifactCloudStore, CloudStore, DiskLocalStore, SyncState};

mod artifact_client;
mod sync;

const PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "drive";
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
// Drive folder + state helpers
// ─────────────────────────────────────────────────────────────────────────────

/// The local Drive folder. Uses DRIVE_FOLDER env var if set, otherwise
/// ~/MinervaDrive, falling back to the current directory.
fn drive_folder() -> String {
    if let Ok(v) = std::env::var("DRIVE_FOLDER") {
        if !v.is_empty() {
            return v;
        }
    }
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_default();
    if !home.is_empty() {
        return format!("{home}/MinervaDrive");
    }
    ".".to_owned()
}

/// Path to the persisted state file inside the drive folder.
fn state_file_path(folder: &str) -> String {
    format!("{folder}/.drive-state.json")
}

/// Load state from disk. Generates and persists a device_id on first run.
fn load_state(folder: &str) -> SyncState {
    let path = state_file_path(folder);
    let mut state = match std::fs::read_to_string(&path) {
        Ok(s) => serde_json::from_str::<SyncState>(&s).unwrap_or_default(),
        Err(_) => SyncState::default(),
    };
    if state.device_id.is_empty() {
        state.device_id = uuid::Uuid::new_v4().to_string();
        save_state(folder, &state);
    }
    state
}

/// Serialize state to the state file (pretty JSON).
fn save_state(folder: &str, state: &SyncState) {
    let path = state_file_path(folder);
    if let Ok(json) = serde_json::to_string_pretty(state) {
        if let Err(e) = std::fs::write(&path, json) {
            log::warn!("save_state write {path}: {e}");
        }
    }
}

/// The registered local paths that currently exist as regular files. Registered
/// paths that are missing (e.g. a project not yet pulled on this device) are
/// skipped so sync never tries to read a nonexistent file.
fn tracked_files(state: &SyncState) -> Vec<String> {
    state
        .tracked
        .iter()
        .filter(|p| std::path::Path::new(p).is_file())
        .cloned()
        .collect()
}

/// Read each tracked file and return a map of path -> content hash.
fn local_hashes(tracked: &[String]) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for path in tracked {
        match std::fs::read(path) {
            Ok(bytes) => {
                map.insert(path.clone(), sync::content_hash(&bytes));
            }
            Err(e) => log::warn!("local_hashes read {path}: {e}"),
        }
    }
    map
}

/// Seconds since UNIX epoch as an ISO-like string.
fn now_iso() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    secs.to_string()
}

// ─────────────────────────────────────────────────────────────────────────────
// Client connection helper
// ─────────────────────────────────────────────────────────────────────────────

/// Fetch host.core.session credentials and connect an ArtifactClient.
fn connect_client(
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> Result<ArtifactClient, String> {
    let result = request_capability(out, lines, next_id, "host.core.session", json!({}))?;
    let creds = Credentials::from_session(&result)
        .ok_or_else(|| "host.core.session response missing required fields (ws_url/token/client_id)".to_owned())?;
    ArtifactClient::connect(creds, Duration::from_secs(60), Duration::from_secs(15))
        .map_err(|e| e.to_string())
}

// ─────────────────────────────────────────────────────────────────────────────
// Tool handlers
// ─────────────────────────────────────────────────────────────────────────────

/// Report the readiness of the Drive plugin. The project count is local-first
/// (the registered files), so it is meaningful even when the cloud is offline.
fn handle_status(
    _params: &Value,
    id: Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let folder = drive_folder();
    if let Err(e) = std::fs::create_dir_all(&folder) {
        log::warn!("create drive folder {folder}: {e}");
    }
    let state = load_state(&folder);
    let device = state.device_id.clone();
    let tracked = tracked_files(&state);
    let hashes = local_hashes(&tracked);

    let (listed, connected) = cloud_list_or_local(out, lines, next_id);
    let rows = sync::compute_status(listed, &state, &hashes);
    ok_response(id, tool_ok(json!({
        "ready": true,
        "connected": connected,
        "device": device,
        "project_count": rows.len()
    })))
}

/// List the registered projects and their sync status. Local-first: registered
/// files always appear (the instant they are added), and the list still renders
/// with `connected: false` when the cloud is unreachable — the cloud is used
/// only to enrich each row's status.
fn handle_list(
    _params: &Value,
    id: Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let folder = drive_folder();
    if let Err(e) = std::fs::create_dir_all(&folder) {
        log::warn!("create drive folder {folder}: {e}");
    }
    let state = load_state(&folder);
    let tracked = tracked_files(&state);
    let hashes = local_hashes(&tracked);

    let (listed, connected) = cloud_list_or_local(out, lines, next_id);
    let rows = sync::compute_status(listed, &state, &hashes);
    let projects = serde_json::to_value(&rows).unwrap_or(Value::Array(vec![]));
    ok_response(id, tool_ok(json!({ "projects": projects, "connected": connected })))
}

/// Best-effort fetch of the cloud artifact list. Returns the drive artifacts and
/// `true` when connected; on any connect or list failure returns an empty list
/// and `false`, so read-only views degrade to a local-only picture instead of
/// failing — the file list must never depend on the network.
fn cloud_list_or_local(
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> (Vec<sync::CloudArtifact>, bool) {
    match connect_client(out, lines, next_id) {
        Ok(mut client) => match (ArtifactCloudStore { client: &mut client }).list_drive() {
            Ok(l) => (l, true),
            Err(e) => {
                log::warn!("list_drive failed, showing local view: {e}");
                (Vec::new(), false)
            }
        },
        Err(e) => {
            log::info!("offline, showing local view: {e}");
            (Vec::new(), false)
        }
    }
}

/// Run a sync pass against the artifact service.
fn handle_sync(
    _params: &Value,
    id: Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let folder = drive_folder();
    if let Err(e) = std::fs::create_dir_all(&folder) {
        log::warn!("create drive folder {folder}: {e}");
    }

    let mut client = match connect_client(out, lines, next_id) {
        Ok(c) => c,
        Err(e) => return ok_response(id, tool_err(&e)),
    };

    let mut state = load_state(&folder);
    let tracked = tracked_files(&state);
    let now = now_iso();
    // Clone device_id before mutably borrowing state for sync.
    let device_id = state.device_id.clone();

    let mut cloud = ArtifactCloudStore { client: &mut client };
    let local = DiskLocalStore;
    let report = sync::sync(&mut cloud, &local, &mut state, &tracked, &folder, &device_id, &now);

    // Register any files the sync created locally (cloud-only pulls) so their
    // future edits sync back without the user adding them by hand.
    let known_paths: Vec<String> = state.entries.keys().cloned().collect();
    for p in known_paths {
        if !state.tracked.iter().any(|t| t == &p) {
            state.tracked.push(p);
        }
    }
    save_state(&folder, &state);

    ok_response(id, tool_ok(sync_payload(&report)))
}

/// Register a local file path for sync. Local-only; takes effect on next sync.
fn handle_add(params: &Value, id: Value) -> RpcResponse {
    let path = tool_arg_str(params, "path");
    if path.is_empty() {
        return ok_response(id, tool_err("add requires a non-empty 'path'"));
    }
    let folder = drive_folder();
    let _ = std::fs::create_dir_all(&folder);
    let mut state = load_state(&folder);
    let already = state.tracked.iter().any(|p| p == &path);
    if !already {
        state.tracked.push(path.clone());
        save_state(&folder, &state);
    }
    ok_response(id, tool_ok(json!({
        "ok": true,
        "path": path,
        "added": !already,
        "tracked": state.tracked.len(),
    })))
}

/// Stop syncing a local path. Drops local tracking only; cloud copies remain.
fn handle_remove(params: &Value, id: Value) -> RpcResponse {
    let path = tool_arg_str(params, "path");
    if path.is_empty() {
        return ok_response(id, tool_err("remove requires a non-empty 'path'"));
    }
    let folder = drive_folder();
    let mut state = load_state(&folder);
    let before = state.tracked.len();
    state.tracked.retain(|p| p != &path);
    state.entries.remove(&path);
    save_state(&folder, &state);
    ok_response(id, tool_ok(json!({
        "ok": true,
        "path": path,
        "removed": state.tracked.len() < before,
        "tracked": state.tracked.len(),
    })))
}

/// Read a string argument from a tools/call `arguments` object, trimmed.
fn tool_arg_str(params: &Value, key: &str) -> String {
    params
        .get("arguments")
        .and_then(|a| a.get(key))
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_owned()
}

/// Shape the sync result for the panel: the pushed/pulled name lists, the
/// conflict objects, and the error list are all arrays, plus an `ok` flag.
fn sync_payload(report: &sync::SyncReport) -> Value {
    let mut payload = serde_json::to_value(report).unwrap_or_else(|_| json!({}));
    if let Value::Object(ref mut map) = payload {
        map.insert("ok".to_owned(), Value::Bool(report.errors.is_empty()));
    }
    payload
}

// ─────────────────────────────────────────────────────────────────────────────
// tools/list inline schema
// ─────────────────────────────────────────────────────────────────────────────

fn tools_list_result() -> Value {
    json!({
        "tools": [
            {
                "name": "minerva_drive_status",
                "description": "Return the current connection and readiness status of the Drive plugin. Never fails — returns {ready, connected, device, project_count}.",
                "inputSchema": {
                    "type": "object",
                    "properties": {}
                }
            },
            {
                "name": "minerva_drive_list",
                "description": "List all Drive projects and their sync status (synced / local_ahead / cloud_ahead / conflict / local_only / cloud_only).",
                "inputSchema": {
                    "type": "object",
                    "properties": {}
                }
            },
            {
                "name": "minerva_drive_sync",
                "description": "Run a sync pass: push local changes, pull cloud changes, and record conflicts. Returns the pushed and pulled name lists, conflicts, and any errors.",
                "inputSchema": {
                    "type": "object",
                    "properties": {}
                }
            },
            {
                "name": "minerva_drive_add",
                "description": "Register a local file path to be synced.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"path": {"type": "string", "description": "Absolute local file path to sync."}},
                    "required": ["path"]
                }
            },
            {
                "name": "minerva_drive_remove",
                "description": "Stop syncing a local file path (cloud copies are kept).",
                "inputSchema": {
                    "type": "object",
                    "properties": {"path": {"type": "string", "description": "Local file path to stop syncing."}},
                    "required": ["path"]
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
                    "minerva_drive_status" => {
                        handle_status(&req.params, req.id, &mut out, &mut lines, &mut next_id)
                    }
                    "minerva_drive_list" => {
                        handle_list(&req.params, req.id, &mut out, &mut lines, &mut next_id)
                    }
                    "minerva_drive_sync" => {
                        handle_sync(&req.params, req.id, &mut out, &mut lines, &mut next_id)
                    }
                    "minerva_drive_add" => handle_add(&req.params, req.id),
                    "minerva_drive_remove" => handle_remove(&req.params, req.id),
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

#[cfg(test)]
mod tests {
    use super::*;

    // Guards the sync tool's result shape against the panel's contract: the
    // panel reads pushed/pulled/conflicts/errors as arrays (and conflict items
    // as {name, conflict_copy}). Returning scalar counts here would crash it.
    #[test]
    fn sync_payload_returns_arrays() {
        let report = sync::SyncReport {
            pushed: vec!["a.txt".to_owned()],
            pulled: vec![],
            conflicts: vec![sync::Conflict {
                name: "b.txt".to_owned(),
                conflict_copy: "/p/b.txt.conflict-dev-0".to_owned(),
            }],
            errors: vec![],
        };
        let v = sync_payload(&report);
        assert!(v.get("pushed").map(Value::is_array).unwrap_or(false), "pushed must be an array");
        assert!(v.get("pulled").map(Value::is_array).unwrap_or(false), "pulled must be an array");
        assert!(v.get("conflicts").map(Value::is_array).unwrap_or(false), "conflicts must be an array");
        assert!(v.get("errors").map(Value::is_array).unwrap_or(false), "errors must be an array");
        assert_eq!(v["ok"], json!(true));
        assert_eq!(v["pushed"][0], json!("a.txt"));
        assert_eq!(v["conflicts"][0]["name"], json!("b.txt"));
        assert_eq!(v["conflicts"][0]["conflict_copy"], json!("/p/b.txt.conflict-dev-0"));
    }
}
