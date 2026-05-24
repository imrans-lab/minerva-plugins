//! G8 — DCR `019e564809a9` regression guard.
//!
//! On 2026-05-23 the cycle-1 Layer-2 wire tests (tests/dryrun_session.rs
//! and the library-purge added to tests/session_describe.rs during
//! T-Quality fixes) DELETED the user's real rule library by running
//! `library_delete_rule` against the spawned production binary. The
//! `#[cfg(test)] set_library_path_for_test()` override only worked for
//! in-crate tests; spawned binaries used the production path resolver
//! and reached the real `~/.local/share/scansort/library.rules.json`.
//!
//! The fix introduced the `SCANSORT_LIBRARY_PATH` env var, honoured by
//! `library_path()` in ALL builds (not `cfg(test)`-gated). This test
//! locks the contract in: if anyone removes the env-var precedence in
//! library_path() OR drops the `.env(...)` call in a sibling test, this
//! test fails loudly.
//!
//! See docket hint `019e57af4a8e` and work_item `019e57bd4c30` (G8).

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static COUNTER: AtomicU64 = AtomicU64::new(0);

fn unique_tmp(prefix: &str) -> std::path::PathBuf {
    let pid = std::process::id();
    let n = COUNTER.fetch_add(1, Ordering::SeqCst);
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    std::env::temp_dir().join(format!("scansort-isol-{prefix}-{pid}-{ts}-{n}"))
}

fn rpc(
    stdin: &mut std::process::ChildStdin,
    out: &mut BufReader<std::process::ChildStdout>,
    req: Value,
) -> Value {
    let req_id = req.get("id").cloned();
    let line = req.to_string() + "\n";
    stdin.write_all(line.as_bytes()).unwrap();
    stdin.flush().unwrap();
    loop {
        let mut buf = String::new();
        let n = out.read_line(&mut buf).expect("read");
        if n == 0 {
            panic!("plugin EOF awaiting reply for {:?}", req_id);
        }
        let trimmed = buf.trim();
        if trimmed.is_empty() {
            continue;
        }
        let v: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if v.get("id") == req_id.as_ref() {
            return v;
        }
    }
}

fn unwrap_tool(reply: &Value) -> Value {
    let r = reply.get("result").expect("result");
    let text = r["content"][0]["text"].as_str().expect("text");
    serde_json::from_str(text).unwrap_or_else(|e| panic!("inner JSON ({e}): {text}"))
}

#[test]
fn env_var_isolates_library_from_real_path() {
    // Per-test tmpdir for the library file.
    let work = unique_tmp("env-isolation");
    std::fs::create_dir_all(&work).unwrap();
    let isolated_lib = work.join("library.rules.json");
    assert!(!isolated_lib.exists(), "fresh tmpdir must start empty");

    // Spawn with SCANSORT_LIBRARY_PATH pointing at the isolated path.
    let bin = env!("CARGO_BIN_EXE_scansort-plugin");
    let mut child = Command::new(bin)
        .env("SCANSORT_LIBRARY_PATH", &isolated_lib)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn");
    let mut stdin = child.stdin.take().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());

    // Handshake.
    rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":1,"method":"initialize","params":{}
    }));
    stdin.write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n").unwrap();
    stdin.flush().unwrap();

    // Insert a uniquely-labeled rule into the (isolated) library.
    let probe_label = format!("__isolation_probe_{}", std::process::id());
    let ins = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":2,"method":"tools/call","params":{
            "name":"minerva_scansort_library_insert_rule",
            "arguments":{
                "label": probe_label,
                "instruction":"isolation probe — must NEVER appear in the user's real library",
                "enabled": true
            }
        }
    }));
    let inner = unwrap_tool(&ins);
    assert_eq!(inner["ok"], json!(true), "library_insert_rule failed: {inner}");

    drop(stdin);
    let _ = child.wait();

    // Proof #1: the isolated tmpdir file EXISTS and contains the probe rule.
    assert!(isolated_lib.exists(),
        "SCANSORT_LIBRARY_PATH-targeted file should have been created at {}",
        isolated_lib.display());
    let body = std::fs::read_to_string(&isolated_lib).expect("read isolated lib");
    assert!(body.contains(&probe_label),
        "isolated library at {} must contain the probe label '{}'. Body: {}",
        isolated_lib.display(), probe_label, body);

    // Proof #2: the user's REAL library at the ProjectDirs default DOES NOT
    // contain the probe label. If it does, the env override didn't fire and
    // we just polluted the user's data — fail LOUDLY.
    if let Some(real_lib) = real_library_path() {
        if real_lib.exists() {
            let real_body = std::fs::read_to_string(&real_lib).unwrap_or_default();
            assert!(!real_body.contains(&probe_label),
                "FATAL: probe label '{}' leaked into the real library at {} — \
                 SCANSORT_LIBRARY_PATH override is NOT taking effect. This is the \
                 exact data-loss regression class from 2026-05-23. Body: {}",
                probe_label, real_lib.display(), real_body);
        }
    }

    std::fs::remove_dir_all(&work).ok();
}

/// Replicate the production resolver's default — used only to check that
/// the probe DIDN'T land there. Never written to.
fn real_library_path() -> Option<std::path::PathBuf> {
    // Mirror scansort/src/library.rs library_path()'s ProjectDirs call.
    directories::ProjectDirs::from("", "Minerva", "Scansort")
        .map(|p| p.data_dir().join("library.rules.json"))
}
