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


mod common;
use serde_json::json;

#[test]
fn wire_format_doc_id_is_float_query_and_delete() {
    // Lay out a scratch dir for the vault + sample docs.
    let work = common::unique_tmp("vault");
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

    // Isolate the library via SCANSORT_LIBRARY_PATH (G8 contract).
    let lib = work.join("library.rules.json");
    let (mut child, mut stdin, mut out) = common::spawn_plugin_with_isolated_library(&lib);
    let init = common::handshake(&mut stdin, &mut out);
    assert!(init["result"]["protocolVersion"].is_string(),
            "initialize must return protocolVersion: {init}");

    // 3. create_vault.
    let cv = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":2,"method":"tools/call","params":{
            "name":"minerva_scansort_create_vault",
            "arguments":{"path": vault_path_str, "name": "wire-test"}
        }
    }));
    let cv_inner = common::unwrap_tool(&cv).expect("create_vault ok");
    assert_eq!(cv_inner["ok"], json!(true), "create_vault response: {cv_inner}");

    // 4. Insert three documents. Capture their doc_ids.
    let mut doc_ids: Vec<i64> = Vec::new();
    for (i, doc_path) in docs.iter().enumerate() {
        let reply = common::rpc(&mut stdin, &mut out, json!({
            "jsonrpc":"2.0","id": 100 + i,"method":"tools/call","params":{
                "name":"minerva_scansort_insert_document",
                "arguments":{
                    "vault_path": vault_path_str,
                    "file_path": doc_path.to_str().unwrap(),
                    "category": "Test",
                }
            }
        }));
        let inner = common::unwrap_tool(&reply).unwrap_or_else(|e|
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
    let q = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":200,"method":"tools/call","params":{
            "name":"minerva_scansort_query_documents",
            "arguments":{
                "vault_path": vault_path_str,
                "doc_id": common::json_float(target),         // <-- JSON FLOAT, the bug shape
            }
        }
    }));
    let q_inner = common::unwrap_tool(&q).expect("query_documents ok");
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
    let d_missing = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":201,"method":"tools/call","params":{
            "name":"minerva_scansort_delete_document",
            "arguments":{
                "vault_path": vault_path_str,
                "doc_id": common::json_float(9_999_999),     // <-- JSON FLOAT, not-found
            }
        }
    }));
    let d_missing_err = common::unwrap_tool(&d_missing).unwrap_err();
    assert!(
        !d_missing_err.contains("is required"),
        "BUG REPRO: delete_document(doc_id=9999999.0) must NOT report 'is required'; \
         got '{d_missing_err}'"
    );

    // 7. delete_document of a REAL doc_id as a JSON FLOAT must succeed.
    let alive = doc_ids[0];
    let d_ok = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":202,"method":"tools/call","params":{
            "name":"minerva_scansort_delete_document",
            "arguments":{
                "vault_path": vault_path_str,
                "doc_id": common::json_float(alive),         // <-- JSON FLOAT, real
            }
        }
    }));
    let d_ok_inner = common::unwrap_tool(&d_ok).expect("delete_document ok");
    assert_eq!(d_ok_inner["ok"], json!(true), "delete_document inner: {d_ok_inner}");
    assert_eq!(
        d_ok_inner["doc_id"].as_i64(), Some(alive),
        "deleted doc_id must echo the integer value of the float arg"
    );

    // 8. New audit_tail tool (T4) — limit as a JSON FLOAT must be honoured.
    //    No audit log exists; we expect a tool_err (not a panic).
    let audit_log = work.join("audit.csv");
    let a = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":203,"method":"tools/call","params":{
            "name":"minerva_scansort_audit_tail",
            "arguments":{
                "log_path": audit_log.to_str().unwrap(),
                "limit": common::json_float(3),              // <-- JSON FLOAT for limit
            }
        }
    }));
    let a_err = common::unwrap_tool(&a).unwrap_err();
    assert!(
        a_err.contains("no file at"),
        "audit_tail on missing file should report 'no file at', got: '{a_err}'"
    );

    // 9. Malformed-int message uses 'must be an integer' (not 'is required').
    let bad = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":204,"method":"tools/call","params":{
            "name":"minerva_scansort_delete_document",
            "arguments":{
                "vault_path": vault_path_str,
                "doc_id": "not a number",
            }
        }
    }));
    let bad_err = common::unwrap_tool(&bad).unwrap_err();
    assert_eq!(bad_err, "doc_id must be an integer",
        "malformed doc_id must report 'must be an integer', got: '{bad_err}'");

    // Clean shutdown.
    drop(stdin); // close stdin so plugin sees EOF and exits
    let status = child.wait().expect("wait");
    assert!(status.success() || status.code() == Some(0),
        "plugin exit status: {status:?}");

    std::fs::remove_dir_all(&work).ok();
}
