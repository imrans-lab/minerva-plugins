//! Shared helpers for cargo integration tests that spawn the plugin binary.
//!
//! Extracted from the 5 wire-test files that previously copy-pasted these
//! helpers. Tracked as work_item `019e566e7a66` and used by:
//!   - tests/mcp_wire_numeric_args.rs
//!   - tests/session_describe.rs
//!   - tests/dryrun_session.rs
//!   - tests/library_path_isolation.rs
//!   - tests/vault_label.rs
//!   - tests/process_pipeline_v2.rs (cycle 3 / C8)
//!
//! Cargo idiom: each test file declares `mod common;` and uses the helpers
//! via `common::rpc(...)`. Helpers carry `#[allow(dead_code)]` so per-file
//! "unused" warnings don't fire on tests that only use a subset.

#![allow(dead_code)]

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// Unique tmpdir for a test fixture. Uses pid + ns + an atomic counter so
/// parallel test threads can't collide on the same name.
pub fn unique_tmp(prefix: &str) -> std::path::PathBuf {
    let pid = std::process::id();
    let n = COUNTER.fetch_add(1, Ordering::SeqCst);
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    std::env::temp_dir().join(format!("scansort-test-{prefix}-{pid}-{ts}-{n}"))
}

/// Spawn the scansort-plugin binary with stdio piped + the library path
/// isolated to a per-test tmpdir (G8 safety contract). Returns the child
/// + its stdin + a BufReader over stdout. Callers `drop(stdin)` to close
/// the pipe and trigger graceful shutdown.
pub fn spawn_plugin_with_isolated_library(
    library_path: &std::path::Path,
) -> (std::process::Child, ChildStdin, BufReader<ChildStdout>) {
    let bin = env!("CARGO_BIN_EXE_scansort-plugin");
    let mut child = Command::new(bin)
        .env("SCANSORT_LIBRARY_PATH", library_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn scansort-plugin");
    let stdin = child.stdin.take().expect("stdin");
    let out = BufReader::new(child.stdout.take().expect("stdout"));
    (child, stdin, out)
}

/// Send one JSON-RPC request line and return the matching response.
/// Skips state_changed notifications (no id) and re-reads until the
/// response whose id matches the request's id arrives.
pub fn rpc(stdin: &mut ChildStdin, out: &mut BufReader<ChildStdout>, req: Value) -> Value {
    let req_id = req.get("id").cloned();
    let line = req.to_string() + "\n";
    stdin.write_all(line.as_bytes()).expect("write request");
    stdin.flush().expect("flush stdin");

    loop {
        let mut buf = String::new();
        let n = out.read_line(&mut buf).expect("read response line");
        if n == 0 {
            panic!("plugin EOF before reply to {:?}", req_id);
        }
        let trimmed = buf.trim();
        if trimmed.is_empty() {
            continue;
        }
        let v: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => continue, // non-JSON log lines on stdout
        };
        if v.get("id") == req_id.as_ref() {
            return v;
        }
    }
}

/// Send the standard MCP `initialize` handshake + the
/// `notifications/initialized` follow-up. Use after `spawn_plugin_*`
/// and BEFORE any tools/call.
pub fn handshake(stdin: &mut ChildStdin, out: &mut BufReader<ChildStdout>) -> Value {
    let init = rpc(stdin, out, json!({
        "jsonrpc":"2.0","id":1,"method":"initialize","params":{}
    }));
    stdin.write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n").unwrap();
    stdin.flush().unwrap();
    init
}

/// Unwrap a tools/call response into its inner JSON payload (the parsed
/// `content[0].text`). Returns `Err(error_msg)` if the result was a
/// `tool_err` envelope (`isError: true`), `Ok(payload)` otherwise.
pub fn unwrap_tool(reply: &Value) -> Result<Value, String> {
    let result = reply
        .get("result")
        .unwrap_or_else(|| panic!("reply missing 'result': {reply}"));
    let is_error = result.get("isError").and_then(|v| v.as_bool()).unwrap_or(false);
    let text = result["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("reply content[0].text missing: {reply}"));
    let parsed: Value = serde_json::from_str(text)
        .unwrap_or_else(|e| panic!("inner text not JSON ({e}): {text}"));
    if is_error {
        let msg = parsed
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or("(no error message)")
            .to_string();
        Err(msg)
    } else {
        Ok(parsed)
    }
}

/// Variant of [`unwrap_tool`] that panics on tool_err — convenience for
/// callsites that just want to assert success.
pub fn unwrap_tool_ok(reply: &Value) -> Value {
    unwrap_tool(reply).unwrap_or_else(|e| panic!("expected ok, got tool_err: {e}"))
}

/// Build a JSON value that's a Number rendered as a FLOAT (e.g. `1.0`)
/// rather than an integer (`1`). Reproduces the post-Godot wire shape
/// where every JSON integer gets re-serialised as a float. Used by the
/// numeric-args regression test (mcp_wire_numeric_args).
pub fn json_float(n: i64) -> Value {
    Value::from(n as f64)
}
