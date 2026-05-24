//! T2 — DCR `019e564809a9` Layer-2 wire test for `session_describe`.
//!
//! Spawns the real scansort-plugin binary and exercises:
//!   - default `include_paths=false` — labels only, no path strings
//!   - explicit `include_paths=true` — path strings appear on every entry
//!   - per-vault enrichment: `doc_count`, `has_password`, `has_sidecar_rules`
//!
//! Sibling of `tests/mcp_wire_numeric_args.rs`; uses the same JSON-RPC
//! helpers (duplicated to keep tests independent).

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
    std::env::temp_dir().join(format!("scansort-desc-{prefix}-{pid}-{ts}-{n}"))
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
    let r = reply
        .get("result")
        .unwrap_or_else(|| panic!("no result: {reply}"));
    let text = r["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("no text: {reply}"));
    serde_json::from_str(text).unwrap_or_else(|e| panic!("bad inner JSON ({e}): {text}"))
}

#[test]
fn session_describe_shape_with_and_without_paths() {
    let work = unique_tmp("setup");
    std::fs::create_dir_all(&work).unwrap();
    let vault_path = work.join("desc-test.ssort");
    let vault_str = vault_path.to_str().unwrap().to_string();
    let dir_path = work.join("dest-dir");
    std::fs::create_dir_all(&dir_path).unwrap();
    let dir_str = dir_path.to_string_lossy().into_owned();
    let source_path = work.join("source-dir");
    std::fs::create_dir_all(&source_path).unwrap();
    let source_str = source_path.to_string_lossy().into_owned();

    // G8: isolate the library to a per-test tmpdir via env var so the
    // spawned binary doesn't read/write the user's real library.
    let lib = work.join("library.rules.json");
    let bin = env!("CARGO_BIN_EXE_scansort-plugin");
    let mut child = Command::new(bin)
        .env("SCANSORT_LIBRARY_PATH", &lib)
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

    // Reset session in case any earlier test left state behind (the plugin
    // process is fresh, but session::SESSION is a per-process global).
    rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":2,"method":"tools/call","params":{
            "name":"minerva_scansort_session_reset","arguments":{}
        }
    }));
    // Purge any rules a sibling test may have left in the on-disk library
    // so this test's rule_library_count assertion is exact, not just present.
    let list = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":2001,"method":"tools/call","params":{
            "name":"minerva_scansort_library_list_rules","arguments":{}
        }
    }));
    if let Some(rules) = unwrap_tool(&list).get("rules").and_then(|v| v.as_array()) {
        for r in rules {
            if let Some(label) = r.get("label").and_then(|v| v.as_str()) {
                rpc(&mut stdin, &mut out, json!({
                    "jsonrpc":"2.0","id":2002,"method":"tools/call","params":{
                        "name":"minerva_scansort_library_delete_rule",
                        "arguments":{"label": label}
                    }
                }));
            }
        }
    }

    // Create a vault and insert two docs so doc_count > 0.
    let cv = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":3,"method":"tools/call","params":{
            "name":"minerva_scansort_create_vault",
            "arguments":{"path": vault_str, "name": "DescTest"}
        }
    }));
    assert_eq!(unwrap_tool(&cv)["ok"], json!(true), "create_vault");

    for i in 0..2 {
        let f = work.join(format!("d{i}.txt"));
        std::fs::write(&f, format!("body {i}")).unwrap();
        rpc(&mut stdin, &mut out, json!({
            "jsonrpc":"2.0","id": 100 + i,"method":"tools/call","params":{
                "name":"minerva_scansort_insert_document",
                "arguments":{"vault_path": vault_str, "file_path": f.to_str().unwrap()}
            }
        }));
    }

    // Register one each of vault/dir/source in the session.
    rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":200,"method":"tools/call","params":{
            "name":"minerva_scansort_session_open_vault",
            "arguments":{"label": "Archive", "path": vault_str}
        }
    }));
    rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":201,"method":"tools/call","params":{
            "name":"minerva_scansort_session_open_directory",
            "arguments":{"label": "DiskOut", "path": dir_str}
        }
    }));
    rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":202,"method":"tools/call","params":{
            "name":"minerva_scansort_session_open_source",
            "arguments":{"label": "Inbox", "path": source_str}
        }
    }));

    // --- 1) include_paths=false (default) ---------------------------------
    let d1 = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":300,"method":"tools/call","params":{
            "name":"minerva_scansort_session_describe","arguments":{}
        }
    }));
    let inner = unwrap_tool(&d1);
    assert_eq!(inner["ok"], json!(true));
    assert_eq!(inner["include_paths"], json!(false));
    let vaults = inner["vaults"].as_array().expect("vaults arr");
    let dirs = inner["dirs"].as_array().expect("dirs arr");
    let sources = inner["sources"].as_array().expect("sources arr");
    assert_eq!(vaults.len(), 1);
    assert_eq!(dirs.len(), 1);
    assert_eq!(sources.len(), 1);

    // No path key anywhere.
    for arr in [vaults, dirs, sources] {
        for v in arr {
            assert!(v.get("path").is_none(),
                "agent-safe default must omit path: {v}");
        }
    }

    // Per-vault enrichment present.
    let v0 = &vaults[0];
    assert_eq!(v0["label"], json!("Archive"));
    assert_eq!(v0["doc_count"], json!(2), "doc_count must reflect inserted docs");
    assert_eq!(v0["has_password"], json!(false),
        "new vault has no password");
    assert_eq!(v0["has_sidecar_rules"], json!(false),
        "no sidecar created in this test");

    // Top-level counters present. After the library purge above
    // rule_library_count must be exactly 0; destination_registry_count
    // is environmental (host-managed registry file) so we only assert
    // its presence as a number.
    assert_eq!(inner["rule_library_count"], json!(0),
        "after library purge, rule_library_count must be 0: {inner}");
    assert!(inner["destination_registry_count"].as_u64().is_some(),
        "destination_registry_count must be present: {inner}");

    // --- 2) include_paths=true --------------------------------------------
    let d2 = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":301,"method":"tools/call","params":{
            "name":"minerva_scansort_session_describe",
            "arguments":{"include_paths": true}
        }
    }));
    let inner2 = unwrap_tool(&d2);
    assert_eq!(inner2["include_paths"], json!(true));
    let vaults2 = inner2["vaults"].as_array().unwrap();
    let dirs2 = inner2["dirs"].as_array().unwrap();
    let sources2 = inner2["sources"].as_array().unwrap();

    // Path field on every entry.
    for arr in [vaults2, dirs2, sources2] {
        for v in arr {
            assert!(v.get("path").and_then(|p| p.as_str()).is_some(),
                "include_paths=true must surface path: {v}");
        }
    }
    assert_eq!(vaults2[0]["path"], json!(vault_str));
    assert_eq!(dirs2[0]["path"], json!(dir_str));
    assert_eq!(sources2[0]["path"], json!(source_str));

    // G10: when include_paths=true the response also carries the full
    // destination_registry list with an is_open_in_session flag per entry.
    // Default (include_paths=false) must NOT carry this field.
    assert!(inner.get("destination_registry").is_none(),
        "include_paths=false MUST omit destination_registry: {inner}");
    let reg = inner2["destination_registry"].as_array()
        .expect("destination_registry must be present when include_paths=true");
    // We didn't add the test vault to the registry, so it may or may not
    // be there. We just verify shape: every entry has path + is_open_in_session.
    for entry in reg {
        assert!(entry.get("path").and_then(|v| v.as_str()).is_some(),
            "every registry entry must have a path: {entry}");
        assert!(entry.get("is_open_in_session").and_then(|v| v.as_bool()).is_some(),
            "every registry entry must have is_open_in_session bool: {entry}");
    }

    // Cleanup.
    rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":900,"method":"tools/call","params":{
            "name":"minerva_scansort_session_reset","arguments":{}
        }
    }));
    drop(stdin);
    let _ = child.wait();
    std::fs::remove_dir_all(&work).ok();
}
