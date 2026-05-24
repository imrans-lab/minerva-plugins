//! G11 — DCR `019e564809a9` Layer-2 wire test.
//!
//! Asserts that doc-side tools accept vault_label (resolved via the
//! session) as an alternative to vault_path. Spawns the real plugin
//! binary, opens a vault with a label, inserts a doc using the path,
//! then exercises query_documents + delete_document using ONLY the
//! label.


mod common;
use serde_json::{json, Value};

#[test]
fn vault_label_works_in_place_of_vault_path_for_doc_tools() {
    let work = common::unique_tmp("label");
    std::fs::create_dir_all(&work).unwrap();
    let vault_path = work.join("labeled.ssort");
    let vault_str = vault_path.to_str().unwrap().to_string();
    let doc_path = work.join("doc.txt");
    std::fs::write(&doc_path, b"hello").unwrap();

    let (mut child, mut stdin, mut out) = common::spawn_plugin_with_isolated_library(&work.join("library.rules.json"));

    let _init = common::handshake(&mut stdin, &mut out);
    common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":2,"method":"tools/call","params":{
            "name":"minerva_scansort_session_reset","arguments":{}
        }
    }));

    // Create vault + insert one doc with VAULT_PATH (handler under test
    // accepts both; this is the path side just for setup).
    let cv = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":3,"method":"tools/call","params":{
            "name":"minerva_scansort_create_vault",
            "arguments":{"path": vault_str, "name": "LabelTest"}
        }
    }));
    assert_eq!(common::unwrap_tool(&cv).unwrap()["ok"], json!(true), "create_vault");

    let ins = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":4,"method":"tools/call","params":{
            "name":"minerva_scansort_insert_document",
            "arguments":{"vault_path": vault_str, "file_path": doc_path.to_str().unwrap()}
        }
    }));
    let ins_inner = common::unwrap_tool(&ins).expect("insert");
    let doc_id = ins_inner["doc_id"].as_i64().expect("doc_id");

    // Open the vault in the session under a label.
    common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":5,"method":"tools/call","params":{
            "name":"minerva_scansort_session_open_vault",
            "arguments":{"label":"label-1", "path": vault_str}
        }
    }));

    // 1. query_documents — vault_label only.
    let q = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":10,"method":"tools/call","params":{
            "name":"minerva_scansort_query_documents",
            "arguments":{"vault_label":"label-1"}
        }
    }));
    let q_inner = common::unwrap_tool(&q).expect("query with label");
    let docs = q_inner["documents"].as_array().expect("docs");
    assert_eq!(docs.len(), 1, "must return the doc when keyed by label");

    // 2. get_document — vault_label only.
    let g = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":11,"method":"tools/call","params":{
            "name":"minerva_scansort_get_document",
            "arguments":{"vault_label":"label-1", "doc_id": doc_id}
        }
    }));
    assert!(common::unwrap_tool(&g).is_ok(), "get_document with label must succeed");

    // 3. Unknown label → tool_err with the label name.
    let bad = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":12,"method":"tools/call","params":{
            "name":"minerva_scansort_query_documents",
            "arguments":{"vault_label":"does-not-exist"}
        }
    }));
    let bad_err = common::unwrap_tool(&bad).unwrap_err();
    assert!(bad_err.contains("does-not-exist"),
        "error must name the missing label: {bad_err}");
    assert!(bad_err.contains("not in session") || bad_err.contains("not a vault"),
        "error must distinguish label-vs-path: {bad_err}");

    // 4. Neither label nor path → tool_err.
    let none = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":13,"method":"tools/call","params":{
            "name":"minerva_scansort_query_documents",
            "arguments":{}
        }
    }));
    let none_err = common::unwrap_tool(&none).unwrap_err();
    assert!(none_err.contains("required"),
        "missing both must report 'required': {none_err}");

    // 5. delete_document via label — proves write-side path also accepts label.
    let d = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":14,"method":"tools/call","params":{
            "name":"minerva_scansort_delete_document",
            "arguments":{"vault_label":"label-1", "doc_id": doc_id}
        }
    }));
    let d_inner = common::unwrap_tool(&d).expect("delete with label");
    assert_eq!(d_inner["ok"], json!(true));

    common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":900,"method":"tools/call","params":{
            "name":"minerva_scansort_session_reset","arguments":{}
        }
    }));
    drop(stdin);
    let _ = child.wait();
    std::fs::remove_dir_all(&work).ok();
}
