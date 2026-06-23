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
use sync::{ArtifactCloudStore, CloudStore, DiskLocalStore, SyncState, current_artifact_for};

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

/// The baseline Drive folder: DRIVE_FOLDER env → ~/MinervaDrive → ".".
///
/// This is used ONLY to locate the state file on startup — before we know
/// whether the state contains a `drive_folder_override`. Every other piece of
/// code that needs the folder calls `effective_folder(state)` instead.
fn base_drive_folder() -> String {
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

/// Resolve the effective Drive folder for a loaded state.
///
/// Precedence (highest first):
///   1. `state.drive_folder_override` — set by the user via the panel or the
///      `minerva_drive_set_folder` tool.
///   2. `DRIVE_FOLDER` environment variable.
///   3. `~/MinervaDrive` (the install default).
///
/// Changing the override does NOT move existing tracked or materialized files;
/// only the destination for future cloud-only pulls changes.
fn effective_folder(state: &sync::SyncState) -> String {
    if !state.drive_folder_override.is_empty() {
        return state.drive_folder_override.clone();
    }
    base_drive_folder()
}

/// Path to the persisted state file inside the drive folder.
fn state_file_path(folder: &str) -> String {
    format!("{folder}/.drive-state.json")
}

/// Load state from disk using `base` as the directory to find the state file.
/// Generates and persists a device_id on first run.
///
/// Always pass `base_drive_folder()` here — the state file location is fixed
/// at the base folder so the plugin can always find it. The effective working
/// folder (which may be overridden inside the state) is determined by calling
/// `effective_folder(state)` after loading.
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
/// Returns `folder` so the panel can display the effective Drive folder path.
fn handle_status(
    _params: &Value,
    id: Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let base = base_drive_folder();
    if let Err(e) = std::fs::create_dir_all(&base) {
        log::warn!("create drive base folder {base}: {e}");
    }
    let state = load_state(&base);
    let folder = effective_folder(&state);
    if folder != base {
        if let Err(e) = std::fs::create_dir_all(&folder) {
            log::warn!("create effective drive folder {folder}: {e}");
        }
    }
    let device = state.device_id.clone();
    let tracked = tracked_files(&state);
    let hashes = local_hashes(&tracked);

    let (listed, connected) = cloud_list_or_local(out, lines, next_id);
    let rows = sync::compute_status(listed, &state, &hashes);
    ok_response(id, tool_ok(json!({
        "ready": true,
        "connected": connected,
        "device": device,
        "project_count": rows.len(),
        "folder": folder,
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
    let base = base_drive_folder();
    if let Err(e) = std::fs::create_dir_all(&base) {
        log::warn!("create drive base folder {base}: {e}");
    }
    let state = load_state(&base);
    let folder = effective_folder(&state);
    if folder != base {
        if let Err(e) = std::fs::create_dir_all(&folder) {
            log::warn!("create effective drive folder {folder}: {e}");
        }
    }
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
    let base = base_drive_folder();
    if let Err(e) = std::fs::create_dir_all(&base) {
        log::warn!("create drive base folder {base}: {e}");
    }

    let mut client = match connect_client(out, lines, next_id) {
        Ok(c) => c,
        Err(e) => return ok_response(id, tool_err(&e)),
    };

    let mut state = load_state(&base);
    // Use the effective folder for cloud-only file materialization.
    let folder = effective_folder(&state);
    if folder != base {
        if let Err(e) = std::fs::create_dir_all(&folder) {
            log::warn!("create effective drive folder {folder}: {e}");
        }
    }
    let tracked = tracked_files(&state);
    let now = now_iso();
    // Clone device_id before mutably borrowing state for sync.
    let device_id = state.device_id.clone();

    // Fetch the currently-open project path so sync can defer it rather than
    // changing a file out from under the live session. Degrade gracefully to ""
    // on any error — the sync must still proceed; only the active-project guard
    // is bypassed.
    let active_project_path = request_capability(out, lines, next_id, "host.project.current", json!({}))
        .ok()
        .and_then(|r| r.get("path").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_default();

    let mut cloud = ArtifactCloudStore { client: &mut client };
    let local = DiskLocalStore;
    let report = sync::sync(&mut cloud, &local, &mut state, &tracked, &folder, &device_id, &now, &active_project_path);

    // Register any files the sync created locally (cloud-only pulls) so their
    // future edits sync back without the user adding them by hand.
    let known_paths: Vec<String> = state.entries.keys().cloned().collect();
    for p in known_paths {
        if !state.tracked.iter().any(|t| t == &p) {
            state.tracked.push(p);
        }
    }
    save_state(&base, &state);

    ok_response(id, tool_ok(sync_payload(&report)))
}

/// Register a local file path for sync. Local-only; takes effect on next sync.
fn handle_add(params: &Value, id: Value) -> RpcResponse {
    let path = tool_arg_str(params, "path");
    if path.is_empty() {
        return ok_response(id, tool_err("add requires a non-empty 'path'"));
    }
    let base = base_drive_folder();
    let _ = std::fs::create_dir_all(&base);
    let mut state = load_state(&base);
    let already = state.tracked.iter().any(|p| p == &path);
    if !already {
        state.tracked.push(path.clone());
        save_state(&base, &state);
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
    let base = base_drive_folder();
    let mut state = load_state(&base);
    let before = state.tracked.len();
    state.tracked.retain(|p| p != &path);
    state.entries.remove(&path);
    save_state(&base, &state);
    ok_response(id, tool_ok(json!({
        "ok": true,
        "path": path,
        "removed": state.tracked.len() < before,
        "tracked": state.tracked.len(),
    })))
}

/// Set (or clear) the Drive folder override. Local-only; no files are moved.
///
/// The override is persisted in the state file at the base folder. An empty
/// path clears the override, restoring the DRIVE_FOLDER env / ~/MinervaDrive
/// default. Existing tracked and materialised files are NOT moved — only the
/// destination for future cloud-only pulls changes.
fn handle_set_folder(params: &Value, id: Value) -> RpcResponse {
    let raw = tool_arg_str(params, "path"); // already trimmed by tool_arg_str
    let base = base_drive_folder();
    let _ = std::fs::create_dir_all(&base);
    let mut state = load_state(&base);
    state.drive_folder_override = raw.clone();
    save_state(&base, &state);
    let folder = effective_folder(&state);
    ok_response(id, tool_ok(json!({
        "ok": true,
        "folder": folder,
    })))
}

/// Open a synced project in Minerva — pulling the latest cloud version first,
/// then calling host.project.open. Refuses when the current project is dirty.
fn handle_open(
    params: &Value,
    id: Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let proj_uuid = tool_arg_str(params, "proj_uuid");
    if proj_uuid.is_empty() {
        return ok_response(id, tool_err("open requires a non-empty 'proj_uuid'"));
    }

    // Step 2: Check whether the current project has unsaved changes.
    let current_result = match request_capability(out, lines, next_id, "host.project.current", json!({})) {
        Ok(r) => r,
        Err(e) => return ok_response(id, tool_err(&format!("host.project.current failed: {e}"))),
    };
    let dirty = current_result.get("dirty").and_then(Value::as_bool).unwrap_or(false);

    // Step 3: Guard — never open while there are unsaved changes.
    if dirty {
        return ok_response(id, tool_ok(json!({
            "ok": false,
            "needs_save": true,
            "message": "Save your current project first, then open.",
        })));
    }

    // Step 4: Connect and fetch the cloud artifact list.
    let mut client = match connect_client(out, lines, next_id) {
        Ok(c) => c,
        Err(e) => return ok_response(id, tool_err(&format!("connect failed: {e}"))),
    };
    let listed = match (ArtifactCloudStore { client: &mut client }).list_drive() {
        Ok(l) => l,
        Err(e) => return ok_response(id, tool_err(&format!("list cloud failed: {e}"))),
    };
    let current = match current_artifact_for(&listed, &proj_uuid) {
        Some(a) => a.clone(),
        None => return ok_response(id, tool_err(&format!("project '{proj_uuid}' not found in cloud"))),
    };

    // Step 5: Resolve the local path.
    let base = base_drive_folder();
    let _ = std::fs::create_dir_all(&base);
    let mut state = load_state(&base);
    let folder = effective_folder(&state);
    let local_path = state
        .entries
        .iter()
        .find(|(_, e)| e.proj_uuid == proj_uuid)
        .map(|(path, _)| path.clone())
        .unwrap_or_else(|| {
            let path = if folder.ends_with('/') || folder.ends_with('\\') {
                format!("{}{}", folder, current.manifest.name)
            } else {
                format!("{}/{}", folder, current.manifest.name)
            };
            // Register a new entry so future syncs pick it up.
            state.entries.insert(
                path.clone(),
                sync::TrackedEntry {
                    proj_uuid: proj_uuid.clone(),
                    name: current.manifest.name.clone(),
                    base_version: 0,
                    base_hash: String::new(),
                },
            );
            if !state.tracked.iter().any(|t| t == &path) {
                state.tracked.push(path.clone());
            }
            path
        });

    // Step 6: Pull latest if the local file is missing or stale.
    let needs_pull = match std::fs::read(&local_path) {
        Ok(bytes) => sync::content_hash(&bytes) != current.manifest.content_hash,
        Err(_) => true,
    };
    if needs_pull {
        let bytes = match (ArtifactCloudStore { client: &mut client }).download(&current.uri) {
            Ok(b) => b,
            Err(e) => return ok_response(id, tool_err(&format!("download failed: {e}"))),
        };
        if let Some(parent) = std::path::Path::new(&local_path).parent() {
            if !parent.as_os_str().is_empty() {
                if let Err(e) = std::fs::create_dir_all(parent) {
                    return ok_response(id, tool_err(&format!("create dirs failed: {e}")));
                }
            }
        }
        if let Err(e) = std::fs::write(&local_path, &bytes) {
            return ok_response(id, tool_err(&format!("write file failed: {e}")));
        }
        // Update tracked entry to the pulled version.
        if let Some(entry) = state.entries.get_mut(&local_path) {
            entry.base_version = current.manifest.version;
            entry.base_hash = current.manifest.content_hash.clone();
        }
        save_state(&base, &state);
    }

    // Step 7: Ask Minerva to open the project.
    let open_result = match request_capability(
        out,
        lines,
        next_id,
        "host.project.open",
        json!({ "path": local_path }),
    ) {
        Ok(r) => r,
        Err(e) => return ok_response(id, tool_err(&format!("host.project.open failed: {e}"))),
    };

    // Surface needs_save from the host (should not happen since we checked dirty
    // above, but handle it defensively).
    if open_result.get("needs_save").and_then(Value::as_bool).unwrap_or(false) {
        return ok_response(id, tool_ok(json!({
            "ok": false,
            "needs_save": true,
            "message": "Save your current project first, then open.",
        })));
    }

    ok_response(id, tool_ok(json!({
        "ok": true,
        "opened": local_path,
        "name": current.manifest.name,
    })))
}

/// Download the current cloud version of a project and write it to a local path
/// chosen by the caller. Works for cloud-only projects that have no local copy.
fn handle_export(
    params: &Value,
    id: Value,
    out: &mut impl Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
) -> RpcResponse {
    let proj_uuid = tool_arg_str(params, "proj_uuid");
    let dest_path = tool_arg_str(params, "dest_path");
    if proj_uuid.is_empty() {
        return ok_response(id, tool_err("export requires a non-empty 'proj_uuid'"));
    }
    if dest_path.is_empty() {
        return ok_response(id, tool_err("export requires a non-empty 'dest_path'"));
    }

    let mut client = match connect_client(out, lines, next_id) {
        Ok(c) => c,
        Err(e) => return ok_response(id, tool_err(&format!("connect failed: {e}"))),
    };

    let listed = match (ArtifactCloudStore { client: &mut client }).list_drive() {
        Ok(l) => l,
        Err(e) => return ok_response(id, tool_err(&format!("list cloud failed: {e}"))),
    };

    let art = match current_artifact_for(&listed, &proj_uuid) {
        Some(a) => a,
        None => return ok_response(id, tool_err(&format!("project '{proj_uuid}' not found in cloud"))),
    };

    let name = art.manifest.name.clone();
    let uri = art.uri.clone();

    let bytes = match (ArtifactCloudStore { client: &mut client }).download(&uri) {
        Ok(b) => b,
        Err(e) => return ok_response(id, tool_err(&format!("download failed: {e}"))),
    };

    if let Some(parent) = std::path::Path::new(&dest_path).parent() {
        if !parent.as_os_str().is_empty() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                return ok_response(id, tool_err(&format!("create dirs failed: {e}")));
            }
        }
    }
    let bytes_written = bytes.len();
    if let Err(e) = std::fs::write(&dest_path, &bytes) {
        return ok_response(id, tool_err(&format!("write failed: {e}")));
    }

    ok_response(id, tool_ok(json!({
        "ok": true,
        "dest_path": dest_path,
        "name": name,
        "bytes_written": bytes_written,
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
            },
            {
                "name": "minerva_drive_export",
                "description": "Download the current cloud version of a project to a local path chosen by the caller. Works for Cloud-only projects that have no local copy.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "proj_uuid": {"type": "string", "description": "The project UUID to download."},
                        "dest_path": {"type": "string", "description": "Absolute local path to write the downloaded file to."}
                    },
                    "required": ["proj_uuid", "dest_path"]
                }
            },
            {
                "name": "minerva_drive_set_folder",
                "description": "Set (or clear) the Drive folder — the directory where cloud-only files are pulled and where .drive-state.json lives. An empty path clears the override and restores the DRIVE_FOLDER env / ~/MinervaDrive default. Existing tracked files are NOT moved.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string", "description": "Absolute path to use as the Drive folder, or empty string to clear the override."}
                    },
                    "required": ["path"]
                }
            },
            {
                "name": "minerva_drive_open",
                "description": "Pull the latest cloud version of a project and open it in Minerva. Returns {ok:false, needs_save:true} when the current project has unsaved changes — never discards unsaved work. Returns {ok:true, opened, name} on success.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "proj_uuid": {"type": "string", "description": "The project UUID to open."}
                    },
                    "required": ["proj_uuid"]
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
                    "minerva_drive_export" => {
                        handle_export(&req.params, req.id, &mut out, &mut lines, &mut next_id)
                    }
                    "minerva_drive_set_folder" => handle_set_folder(&req.params, req.id),
                    "minerva_drive_open" => {
                        handle_open(&req.params, req.id, &mut out, &mut lines, &mut next_id)
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

#[cfg(test)]
mod tests {
    use super::*;

    // ── effective_folder precedence ───────────────────────────────────────────

    #[test]
    fn effective_folder_uses_override_when_set() {
        let mut state = sync::SyncState::default();
        state.drive_folder_override = "/my/override".to_owned();
        // The override must win regardless of what DRIVE_FOLDER env holds.
        assert_eq!(effective_folder(&state), "/my/override");
    }

    #[test]
    fn effective_folder_falls_back_to_base_when_override_empty() {
        let state = sync::SyncState::default(); // drive_folder_override is ""
        let result = effective_folder(&state);
        let base = base_drive_folder();
        assert_eq!(result, base,
            "empty override must fall back to base_drive_folder()");
    }

    #[test]
    fn effective_folder_clears_override_on_empty_string() {
        // Setting override to "" and then calling effective_folder must return
        // the base folder (i.e. clearing the override works).
        let mut state = sync::SyncState::default();
        state.drive_folder_override = "/was/set".to_owned();
        state.drive_folder_override = String::new(); // cleared
        let result = effective_folder(&state);
        let base = base_drive_folder();
        assert_eq!(result, base);
    }

    // ── tool payload shapes ───────────────────────────────────────────────────

    // Guards the export tool_ok payload shape: the panel reads ok/dest_path/
    // bytes_written; name is informational. Verify the keys are all present.
    // ── open payload shapes ───────────────────────────────────────────────────

    #[test]
    fn open_payload_ok_shape() {
        // Guards the shape the panel reads on success: ok/opened/name.
        let payload = tool_ok(json!({
            "ok": true,
            "opened": "/tmp/my.minproj",
            "name": "my.minproj",
        }));
        let text = payload["content"][0]["text"].as_str().expect("text content");
        let v: Value = serde_json::from_str(text).expect("valid json");
        assert_eq!(v["ok"], json!(true));
        assert_eq!(v["opened"], json!("/tmp/my.minproj"));
        assert_eq!(v["name"], json!("my.minproj"));
    }

    #[test]
    fn open_payload_needs_save_shape() {
        // Guards the shape the panel reads when unsaved changes block the open.
        let payload = tool_ok(json!({
            "ok": false,
            "needs_save": true,
            "message": "Save your current project first, then open.",
        }));
        let text = payload["content"][0]["text"].as_str().expect("text content");
        let v: Value = serde_json::from_str(text).expect("valid json");
        assert_eq!(v["ok"], json!(false));
        assert_eq!(v["needs_save"], json!(true));
        assert!(!v["message"].as_str().unwrap_or("").is_empty());
    }

    #[test]
    fn open_local_path_resolution_from_state() {
        // When entries already has the proj_uuid, local_path must come from the
        // state key — not a freshly constructed effective_folder+name path.
        let mut state = sync::SyncState::default();
        state.entries.insert(
            "/existing/path/project.minproj".to_owned(),
            sync::TrackedEntry {
                proj_uuid: "uuid-A".to_owned(),
                name: "project.minproj".to_owned(),
                base_version: 3,
                base_hash: "abc".to_owned(),
            },
        );
        // Simulate what handle_open does for path resolution.
        let proj_uuid = "uuid-A";
        let folder = "/drive".to_owned();
        let art_name = "project.minproj";
        let local_path = state
            .entries
            .iter()
            .find(|(_, e)| e.proj_uuid == proj_uuid)
            .map(|(path, _)| path.clone())
            .unwrap_or_else(|| format!("{folder}/{art_name}"));
        assert_eq!(local_path, "/existing/path/project.minproj",
            "path must be resolved from state, not constructed from folder");
    }

    #[test]
    fn open_local_path_resolution_cloud_only() {
        // When the proj_uuid is not in state, path is constructed from effective
        // folder + artifact name. A new entry must be registered.
        let mut state = sync::SyncState::default();
        let proj_uuid = "uuid-B";
        let folder = "/drive".to_owned();
        let art_name = "new.minproj";
        let found_path = state
            .entries
            .iter()
            .find(|(_, e)| e.proj_uuid == proj_uuid)
            .map(|(path, _)| path.clone());
        assert!(found_path.is_none(), "should be absent from state");
        let local_path = found_path.unwrap_or_else(|| {
            let path = format!("{folder}/{art_name}");
            state.entries.insert(
                path.clone(),
                sync::TrackedEntry {
                    proj_uuid: proj_uuid.to_owned(),
                    name: art_name.to_owned(),
                    base_version: 0,
                    base_hash: String::new(),
                },
            );
            if !state.tracked.iter().any(|t| t == &path) {
                state.tracked.push(path.clone());
            }
            path
        });
        assert_eq!(local_path, "/drive/new.minproj");
        assert!(state.entries.contains_key("/drive/new.minproj"),
            "new entry must be registered in state");
        assert!(state.tracked.contains(&"/drive/new.minproj".to_owned()),
            "new path must be added to tracked");
    }

    #[test]
    fn export_payload_shape() {
        let payload = tool_ok(json!({
            "ok": true,
            "dest_path": "/tmp/test.minproj",
            "name": "test.minproj",
            "bytes_written": 1234_u64,
        }));
        let text = payload["content"][0]["text"].as_str().expect("text content");
        let v: Value = serde_json::from_str(text).expect("valid json");
        assert_eq!(v["ok"], json!(true));
        assert_eq!(v["dest_path"], json!("/tmp/test.minproj"));
        assert_eq!(v["name"], json!("test.minproj"));
        assert_eq!(v["bytes_written"], json!(1234_u64));
    }

    #[test]
    fn set_folder_payload_shape() {
        // tool_ok({ok, folder}) must carry both keys the panel reads.
        let payload = tool_ok(json!({
            "ok": true,
            "folder": "/some/path",
        }));
        let text = payload["content"][0]["text"].as_str().expect("text content");
        let v: Value = serde_json::from_str(text).expect("valid json");
        assert_eq!(v["ok"], json!(true));
        assert_eq!(v["folder"], json!("/some/path"));
    }

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
            deferred: vec!["open.minproj".to_owned()],
        };
        let v = sync_payload(&report);
        assert!(v.get("pushed").map(Value::is_array).unwrap_or(false), "pushed must be an array");
        assert!(v.get("pulled").map(Value::is_array).unwrap_or(false), "pulled must be an array");
        assert!(v.get("conflicts").map(Value::is_array).unwrap_or(false), "conflicts must be an array");
        assert!(v.get("errors").map(Value::is_array).unwrap_or(false), "errors must be an array");
        assert!(v.get("deferred").map(Value::is_array).unwrap_or(false), "deferred must be an array");
        assert_eq!(v["ok"], json!(true));
        assert_eq!(v["pushed"][0], json!("a.txt"));
        assert_eq!(v["conflicts"][0]["name"], json!("b.txt"));
        assert_eq!(v["conflicts"][0]["conflict_copy"], json!("/p/b.txt.conflict-dev-0"));
        assert_eq!(v["deferred"][0], json!("open.minproj"));
    }
}
