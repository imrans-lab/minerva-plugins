//! T1 — DCR `019e564809a9` Layer-2 wire test for G1 (BLOCKER).
//!
//! This is the test the predecessor DCR did NOT have. It spawns the real
//! scansort-plugin binary and feeds JSON-RPC over stdio with numeric args
//! shaped exactly the way Minerva's MCP HTTP relay delivers them after
//! routing through Godot's JSON parser — i.e. every integer comes through
//! as a JSON FLOAT (`1.0` rather than `1`).
//!
//! The cargo lib tests for `lax_i64` cover the parsing primitive. This
//! file proves the primitive is *wired in* at every handler that takes an
//! integer arg — the wire format gets all the way down to the SQL `WHERE
//! doc_id = ?` and back. See [feedback_test_at_integration_boundary.md].
//!
//! Bug-is-dead probes:
//!   1. `query_documents(doc_id=1.0)` must return EXACTLY one document
//!      (pre-fix the filter was silently dropped → ALL docs returned).
//!   2. `delete_document(doc_id=9999999.0)` must NOT report
//!      "doc_id is required" (pre-fix the parse failed closed).
//!   3. `delete_document(doc_id=<real>.0)` must succeed (handler reads the
//!      float as the integer it represents).

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
    std::env::temp_dir().join(format!("scansort-wire-{prefix}-{pid}-{ts}-{n}"))
}

/// One JSON-RPC interaction. Sends request line, returns the parsed reply
/// whose `id` matches the request's id (skipping any state_changed
/// notifications the plugin emits along the way).
fn rpc(
    stdin: &mut std::process::ChildStdin,
    out: &mut BufReader<std::process::ChildStdout>,
    req: Value,
) -> Value {
    let req_id = req.get("id").cloned();
    let line = req.to_string() + "\n";
    stdin
        .write_all(line.as_bytes())
        .expect("write request");
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
            Err(_) => continue, // non-JSON log lines on stdout are unexpected but ignore them
        };
        // Skip state_changed notifications (no id), match on id.
        if v.get("id") == req_id.as_ref() {
            return v;
        }
    }
}

/// Unwrap a tools/call response into its inner JSON payload. Returns Err with
/// the error message if the response was a `tool_err`.
fn unwrap_tool(reply: &Value) -> Result<Value, String> {
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

fn float(n: i64) -> Value {
    // Emit as a JSON float (post-Godot wire format). serde_json keeps
    // trailing zero for f64 values so this serializes as e.g. "1.0".
    Value::from(n as f64)
}

#[test]
fn wire_format_doc_id_is_float_query_and_delete() {
    // Lay out a scratch dir for the vault + sample docs.
    let work = unique_tmp("vault");
    std::fs::create_dir_all(&work).expect("mkdir work");
    let vault_path = work.join("test.ssort");
    let vault_path_str = vault_path.to_str().unwrap().to_string();

    // Three sample files to insert.
    let docs: Vec<std::path::PathBuf> = (0..3)
        .map(|i| {
            let p = work.join(format!("doc-{i}.txt"));
            std::fs::write(&p, format!("doc {i} body")).unwrap();
            p
        })
        .collect();

    // Spawn the plugin binary. Cargo sets CARGO_BIN_EXE_<name> for
    // integration tests automatically.
    let bin = env!("CARGO_BIN_EXE_scansort-plugin");
    let mut child = Command::new(bin)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn scansort-plugin");

    let mut stdin = child.stdin.take().expect("stdin");
    let mut out = BufReader::new(child.stdout.take().expect("stdout"));

    // 1. initialize.
    let init = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":1,"method":"initialize","params":{}
    }));
    assert!(init["result"]["protocolVersion"].is_string(),
            "initialize must return protocolVersion: {init}");

    // 2. initialized notification (no reply expected, so don't read).
    stdin.write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n").unwrap();
    stdin.flush().unwrap();

    // 3. create_vault.
    let cv = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":2,"method":"tools/call","params":{
            "name":"minerva_scansort_create_vault",
            "arguments":{"path": vault_path_str, "name": "wire-test"}
        }
    }));
    let cv_inner = unwrap_tool(&cv).expect("create_vault ok");
    assert_eq!(cv_inner["ok"], json!(true), "create_vault response: {cv_inner}");

    // 4. Insert three documents. Capture their doc_ids.
    let mut doc_ids: Vec<i64> = Vec::new();
    for (i, doc_path) in docs.iter().enumerate() {
        let reply = rpc(&mut stdin, &mut out, json!({
            "jsonrpc":"2.0","id": 100 + i,"method":"tools/call","params":{
                "name":"minerva_scansort_insert_document",
                "arguments":{
                    "vault_path": vault_path_str,
                    "file_path": doc_path.to_str().unwrap(),
                    "category": "Test",
                }
            }
        }));
        let inner = unwrap_tool(&reply).unwrap_or_else(|e|
            panic!("insert_document failed: {e}"));
        let id = inner["doc_id"].as_i64()
            .unwrap_or_else(|| panic!("insert response missing doc_id: {inner}"));
        doc_ids.push(id);
    }
    assert_eq!(doc_ids.len(), 3);

    // 5. BUG REPRO #1 (silent): query_documents with doc_id as a JSON FLOAT
    //    must filter to exactly one row. Pre-fix this returned ALL rows
    //    because the as_i64() parse failed and the filter became None.
    let target = doc_ids[1];
    let q = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":200,"method":"tools/call","params":{
            "name":"minerva_scansort_query_documents",
            "arguments":{
                "vault_path": vault_path_str,
                "doc_id": float(target),         // <-- JSON FLOAT, the bug shape
            }
        }
    }));
    let q_inner = unwrap_tool(&q).expect("query_documents ok");
    let returned = q_inner["documents"].as_array().expect("documents array");
    assert_eq!(
        returned.len(),
        1,
        "BUG REPRO: query_documents(doc_id={target}.0) must return EXACTLY one document, \
         got {} (silent-filter-dropped bug). full inner: {q_inner}",
        returned.len()
    );
    let returned_id = returned[0]["doc_id"].as_i64().expect("doc_id field");
    assert_eq!(returned_id, target,
        "filtered doc must be the requested one; got id={returned_id}, expected {target}");

    // 6. BUG REPRO #2 (loud): delete_document with non-existent doc_id as a
    //    JSON FLOAT must NOT report "doc_id is required". Pre-fix the parse
    //    failed and the handler emitted "doc_id is required" instead of
    //    "Document <id> not found".
    let d_missing = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":201,"method":"tools/call","params":{
            "name":"minerva_scansort_delete_document",
            "arguments":{
                "vault_path": vault_path_str,
                "doc_id": float(9_999_999),     // <-- JSON FLOAT, not-found
            }
        }
    }));
    let d_missing_err = unwrap_tool(&d_missing).unwrap_err();
    assert!(
        !d_missing_err.contains("is required"),
        "BUG REPRO: delete_document(doc_id=9999999.0) must NOT report 'is required'; \
         got '{d_missing_err}'"
    );

    // 7. delete_document of a REAL doc_id as a JSON FLOAT must succeed.
    let alive = doc_ids[0];
    let d_ok = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":202,"method":"tools/call","params":{
            "name":"minerva_scansort_delete_document",
            "arguments":{
                "vault_path": vault_path_str,
                "doc_id": float(alive),         // <-- JSON FLOAT, real
            }
        }
    }));
    let d_ok_inner = unwrap_tool(&d_ok).expect("delete_document ok");
    assert_eq!(d_ok_inner["ok"], json!(true), "delete_document inner: {d_ok_inner}");
    assert_eq!(
        d_ok_inner["doc_id"].as_i64(), Some(alive),
        "deleted doc_id must echo the integer value of the float arg"
    );

    // 8. New audit_tail tool (T4) — limit as a JSON FLOAT must be honoured.
    //    No audit log exists; we expect a tool_err (not a panic).
    let audit_log = work.join("audit.csv");
    let a = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":203,"method":"tools/call","params":{
            "name":"minerva_scansort_audit_tail",
            "arguments":{
                "log_path": audit_log.to_str().unwrap(),
                "limit": float(3),              // <-- JSON FLOAT for limit
            }
        }
    }));
    let a_err = unwrap_tool(&a).unwrap_err();
    assert!(
        a_err.contains("no file at"),
        "audit_tail on missing file should report 'no file at', got: '{a_err}'"
    );

    // 9. Malformed-int message uses 'must be an integer' (not 'is required').
    let bad = rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":204,"method":"tools/call","params":{
            "name":"minerva_scansort_delete_document",
            "arguments":{
                "vault_path": vault_path_str,
                "doc_id": "not a number",
            }
        }
    }));
    let bad_err = unwrap_tool(&bad).unwrap_err();
    assert_eq!(bad_err, "doc_id must be an integer",
        "malformed doc_id must report 'must be an integer', got: '{bad_err}'");

    // Clean shutdown.
    drop(stdin); // close stdin so plugin sees EOF and exits
    let status = child.wait().expect("wait");
    assert!(status.success() || status.code() == Some(0),
        "plugin exit status: {status:?}");

    std::fs::remove_dir_all(&work).ok();
}
