//! G11 — DCR `019e564809a9` Layer-2 wire test.
//!
//! Asserts that doc-side tools accept vault_label (resolved via the
//! session) as an alternative to vault_path. Spawns the real plugin
//! binary, opens a vault with a label, inserts a doc using the path,
//! then exercises query_documents + delete_document using ONLY the
//! label.

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
    std::env::temp_dir().join(format!("scansort-label-{prefix}-{pid}-{ts}-{n}"))
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

fn unwrap_tool(reply: &Value) -> Result<Value, String> {
    let r = reply.get("result").expect("result");
    let is_error = r.get("isError").and_then(|v| v.as_bool()).unwrap_or(false);
    let text = r["content"][0]["text"].as_str().expect("text");
    let parsed: Value = serde_json::from_str(text).expect("inner JSON");
    if is_error {
        Err(parsed.get("error").and_then(|v| v.as_str()).unwrap_or("?").to_string())
    } else {
        Ok(parsed)
    }
}

#[test]
fn vault_label_works_in_place_of_vault_path_for_doc_tools() {
    let work = unique_tmp("label");
    std::fs::create_dir_all(&work).unwrap();
    let vault_path = work.join("labeled.ssort");
    let vault_str = vault_path.to_str().unwrap().to_string();
    let doc_path = work.join("doc.txt");
    std::fs::write(&doc_path, b"hello").unwrap();

    let bin = env!("CARGO_BIN_EXE_scansort-plugin");
    let mut child = Command::new(bin)
        .env("SCANSORT_LIBRARY_PATH", work.join("library.rules.json"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn");
    let mut stdin = child.stdin.take().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());

    rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":1,"method":"initialize","params":{}
    }));
    stdin.write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n").unwrap();
    stdin.flush().unwrap();
    rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":2,"method":"tools/call","params":{
            "name":"minerva_scansort_session_reset","arguments":{}
        }
    }));

    // Create vault + insert one doc with VAULT_PATH (handler under test
    // accepts both; this is the path side just for setup).
    let cv = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":3,"method":"tools/call","params":{
            "name":"minerva_scansort_create_vault",
            "arguments":{"path": vault_str, "name": "LabelTest"}
        }
    }));
    assert_eq!(unwrap_tool(&cv).unwrap()["ok"], json!(true), "create_vault");

    let ins = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":4,"method":"tools/call","params":{
            "name":"minerva_scansort_insert_document",
            "arguments":{"vault_path": vault_str, "file_path": doc_path.to_str().unwrap()}
        }
    }));
    let ins_inner = unwrap_tool(&ins).expect("insert");
    let doc_id = ins_inner["doc_id"].as_i64().expect("doc_id");

    // Open the vault in the session under a label.
    rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":5,"method":"tools/call","params":{
            "name":"minerva_scansort_session_open_vault",
            "arguments":{"label":"label-1", "path": vault_str}
        }
    }));

    // 1. query_documents — vault_label only.
    let q = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":10,"method":"tools/call","params":{
            "name":"minerva_scansort_query_documents",
            "arguments":{"vault_label":"label-1"}
        }
    }));
    let q_inner = unwrap_tool(&q).expect("query with label");
    let docs = q_inner["documents"].as_array().expect("docs");
    assert_eq!(docs.len(), 1, "must return the doc when keyed by label");

    // 2. get_document — vault_label only.
    let g = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":11,"method":"tools/call","params":{
            "name":"minerva_scansort_get_document",
            "arguments":{"vault_label":"label-1", "doc_id": doc_id}
        }
    }));
    assert!(unwrap_tool(&g).is_ok(), "get_document with label must succeed");

    // 3. Unknown label → tool_err with the label name.
    let bad = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":12,"method":"tools/call","params":{
            "name":"minerva_scansort_query_documents",
            "arguments":{"vault_label":"does-not-exist"}
        }
    }));
    let bad_err = unwrap_tool(&bad).unwrap_err();
    assert!(bad_err.contains("does-not-exist"),
        "error must name the missing label: {bad_err}");
    assert!(bad_err.contains("not in session") || bad_err.contains("not a vault"),
        "error must distinguish label-vs-path: {bad_err}");

    // 4. Neither label nor path → tool_err.
    let none = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":13,"method":"tools/call","params":{
            "name":"minerva_scansort_query_documents",
            "arguments":{}
        }
    }));
    let none_err = unwrap_tool(&none).unwrap_err();
    assert!(none_err.contains("required"),
        "missing both must report 'required': {none_err}");

    // 5. delete_document via label — proves write-side path also accepts label.
    let d = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":14,"method":"tools/call","params":{
            "name":"minerva_scansort_delete_document",
            "arguments":{"vault_label":"label-1", "doc_id": doc_id}
        }
    }));
    let d_inner = unwrap_tool(&d).expect("delete with label");
    assert_eq!(d_inner["ok"], json!(true));

    rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":900,"method":"tools/call","params":{
            "name":"minerva_scansort_session_reset","arguments":{}
        }
    }));
    drop(stdin);
    let _ = child.wait();
    std::fs::remove_dir_all(&work).ok();
}
