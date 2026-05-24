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


mod common;
use serde_json::{json, Value};

#[test]
fn env_var_isolates_library_from_real_path() {
    // Per-test tmpdir for the library file.
    let work = common::unique_tmp("env-isolation");
    std::fs::create_dir_all(&work).unwrap();
    let isolated_lib = work.join("library.rules.json");
    assert!(!isolated_lib.exists(), "fresh tmpdir must start empty");

    // Spawn with SCANSORT_LIBRARY_PATH pointing at the isolated path.
    let (mut child, mut stdin, mut out) = common::spawn_plugin_with_isolated_library(&isolated_lib);

    // Handshake.
    let _init = common::handshake(&mut stdin, &mut out);

    // Insert a uniquely-labeled rule into the (isolated) library.
    let probe_label = format!("__isolation_probe_{}", std::process::id());
    let ins = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc":"2.0","id":2,"method":"tools/call","params":{
            "name":"minerva_scansort_library_insert_rule",
            "arguments":{
                "label": probe_label,
                "instruction":"isolation probe — must NEVER appear in the user's real library",
                "enabled": true
            }
        }
    }));
    let inner = common::unwrap_tool_ok(&ins);
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
