//! T3 — DCR `019e564809a9` Layer-2 wire test for `dryrun_session`.
//!
//! Spawns the real plugin, registers a library rule with one resolved
//! and one unresolved copy_to label, opens a source with two files, and
//! asserts the dryrun report surfaces:
//!   - active_rules[0].resolved_targets / unresolved_targets
//!   - unresolved_targets_summary with the missing-label count
//!   - files_in_session = 2
//!
//! It does NOT assert per-file rule prediction — that requires a rule
//! with filename-keyed conditions, which is a larger fixture than the
//! G5 catch this test is designed to demonstrate.


mod common;
use serde_json::{json, Value};

#[test]
fn dryrun_session_surfaces_unresolved_copy_to_labels() {
    let work = common::unique_tmp("setup");
    std::fs::create_dir_all(&work).unwrap();

    // Source directory with two .pdf files.
    let source_path = work.join("source");
    std::fs::create_dir_all(&source_path).unwrap();
    std::fs::write(source_path.join("invoice-jan.pdf"), b"fake pdf 1").unwrap();
    std::fs::write(source_path.join("invoice-feb.pdf"), b"fake pdf 2").unwrap();

    // Destination directory (the one resolvable label).
    let dest_path = work.join("dest");
    std::fs::create_dir_all(&dest_path).unwrap();

    // G8: isolate the library to a per-test tmpdir via env var so the
    // spawned binary doesn't read/write the user's real library.
    let lib = work.join("library.rules.json");
    let (mut child, mut stdin, mut out) = common::spawn_plugin_with_isolated_library(&lib);

    // Handshake.
    let _init = common::handshake(&mut stdin, &mut out);

    // Reset session to start clean (per-process global).
    common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":2,"method":"tools/call","params":{
            "name":"minerva_scansort_session_reset","arguments":{}
        }
    }));

    // Clear any pre-existing library state from prior tests in the same
    // process. Library tools persist to disk, so list+delete is the
    // honest way to get a clean slate.
    let list_resp = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":3,"method":"tools/call","params":{
            "name":"minerva_scansort_library_list_rules","arguments":{}
        }
    }));
    if let Some(rules) = common::unwrap_tool_ok(&list_resp).get("rules").and_then(|v| v.as_array()) {
        for r in rules {
            if let Some(label) = r.get("label").and_then(|v| v.as_str()) {
                common::rpc(&mut stdin, &mut out, json!({
                    "jsonrpc":"2.0","id":100,"method":"tools/call","params":{
                        "name":"minerva_scansort_library_delete_rule",
                        "arguments":{"label": label}
                    }
                }));
            }
        }
    }

    // Insert a rule with copy_to: ["dest_open", "ghost_label"]. Only
    // "dest_open" will be opened in the session below — "ghost_label"
    // must show up as unresolved.
    let insert = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":4,"method":"tools/call","params":{
            "name":"minerva_scansort_library_insert_rule",
            "arguments":{
                "label": "DryRunTestRule",
                "instruction": "test rule",
                "copy_to": ["dest_open", "ghost_label"],
                "enabled": true
            }
        }
    }));
    let ins_inner = common::unwrap_tool_ok(&insert);
    assert_eq!(ins_inner["ok"], json!(true),
        "library_insert_rule: {ins_inner}");

    // Open one destination dir and one source.
    common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":5,"method":"tools/call","params":{
            "name":"minerva_scansort_session_open_directory",
            "arguments":{"label":"dest_open","path": dest_path.to_str().unwrap()}
        }
    }));
    common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":6,"method":"tools/call","params":{
            "name":"minerva_scansort_session_open_source",
            "arguments":{"label":"Inbox","path": source_path.to_str().unwrap()}
        }
    }));

    // Run dryrun_session.
    let dr = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":7,"method":"tools/call","params":{
            "name":"minerva_scansort_dryrun_session","arguments":{}
        }
    }));
    let inner = common::unwrap_tool_ok(&dr);
    assert_eq!(inner["ok"], json!(true), "dryrun_session reply: {inner}");

    // Active rules: at least one with our test label.
    let active = inner["active_rules"].as_array().expect("active_rules array");
    let our_rule = active.iter().find(|r| r["label"] == json!("DryRunTestRule"))
        .unwrap_or_else(|| panic!("DryRunTestRule not in active_rules: {inner}"));
    assert_eq!(our_rule["resolved_targets"], json!(["dest_open"]),
        "resolved_targets must include dest_open: {our_rule}");
    assert_eq!(our_rule["unresolved_targets"], json!(["ghost_label"]),
        "unresolved_targets must include ghost_label: {our_rule}");

    // Summary: ghost_label appears with count ≥ 1 (1 if no other rules
    // happen to reference it, but tests should be tolerant of pre-existing
    // library state from sibling tests).
    let summary = inner["unresolved_targets_summary"].as_object()
        .expect("unresolved_targets_summary object");
    let ghost_count = summary.get("ghost_label")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    assert!(ghost_count >= 1,
        "ghost_label must appear in unresolved_targets_summary: {summary:?}");

    // files_in_session matches the 2 files we created.
    assert_eq!(inner["files_in_session"], json!(2),
        "files_in_session must be 2 (the two .pdf we created): {inner}");
    let files = inner["files"].as_array().unwrap();
    assert_eq!(files.len(), 2);
    for f in files {
        // Default include_paths=false → no path key on entries.
        assert!(f.get("path").is_none(),
            "default include_paths=false must omit path: {f}");
        assert_eq!(f["source_label"], json!("Inbox"));
    }

    // Cleanup.
    common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":900,"method":"tools/call","params":{
            "name":"minerva_scansort_library_delete_rule",
            "arguments":{"label":"DryRunTestRule"}
        }
    }));
    common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":901,"method":"tools/call","params":{
            "name":"minerva_scansort_session_reset","arguments":{}
        }
    }));

    drop(stdin);
    let _ = child.wait();
    std::fs::remove_dir_all(&work).ok();
}
