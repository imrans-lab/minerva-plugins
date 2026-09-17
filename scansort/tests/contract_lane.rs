//! scansort's LANE DECLARATION — what this plugin's replies may weigh, proved.
//!
//! WHY THIS EXISTS
//!
//! The per-plugin contract guards weigh six cases against the host's scene
//! control lane, which bounds a panel message at 65,536 UTF-8 bytes. scansort
//! is not on that lane: its panel talks to this binary over the host's DIRECT
//! stdio MCP connection, whose body bound is 32 MiB — three orders of magnitude
//! larger. So a six-case guard here would be measuring a boundary scansort
//! never approaches.
//!
//! What it declares instead, and proves:
//!
//!   * A LISTING REPLY IS CARRIED WHOLE. One registry listing well past the
//!     scene lane's 64 KiB arrives intact over stdio, parses, and names every
//!     entry it was given. If scansort's panel is ever moved onto the scene
//!     lane, this listing is the thing that breaks first, and this test is the
//!     measurement that says by how much.
//!   * A REFUSAL IS STRUCTURED. A call missing a required argument comes back
//!     with the MCP `isError` flag set and a JSON object behind it — the flag
//!     is the machine-readable part, and it is what the host turns into
//!     `error_code: "mcp_tool_error"` for any caller on the plugin surface.
//!
//! WHAT SCANSORT DOES NOT HAVE, stated rather than papered over: a refusal
//! code of its own. `tool_err` (src/main.rs) answers `{"error": "<prose>"}`,
//! so nothing below reads that text — the flag and the shape are what is
//! asserted. A code minted here would be an improvement; a test that matched
//! the prose would be a trap.
//!
//! THE FIXTURE is a registry file written by this test: the entries name vault
//! paths that do not exist, which is a listable state (an unopened vault is
//! listed without its document count), so nothing is created, opened or
//! decrypted and the whole run costs milliseconds.
//!
//! ORACLE: shrink the fixture and the size assertion fails by name rather than
//! passing quietly on a listing that stopped being large; move scansort's panel
//! onto the scene control lane and this listing is the reply that no longer
//! fits, by the margin this test prints.

mod common;

use serde_json::{json, Value};

/// The host's bound on ONE SCENE-PANEL message, which is the lane scansort is
/// declaring it is not on. Mirrors PluginPayloadLimits.CONTROL_BYTES.
const SCENE_CONTROL_BYTES: usize = 64 * 1024;

/// The bound scansort's replies actually answer to: the host's direct stdio
/// MCP body limit.
const STDIO_BODY_BYTES: usize = 32 * 1024 * 1024;

/// Enough registry entries for the listing to clear the scene lane several
/// times over. Measured rather than assumed — see the assertion.
const FIXTURE_VAULTS: usize = 400;

#[test]
fn a_large_listing_is_carried_whole_over_the_stdio_lane() {
    let dir = common::unique_tmp("lane-listing");
    std::fs::create_dir_all(&dir).expect("create fixture dir");
    let registry_path = dir.join("vault_registry.json");

    let mut entries: Vec<Value> = Vec::with_capacity(FIXTURE_VAULTS);
    for i in 0..FIXTURE_VAULTS {
        // Long, realistic paths: a registry's weight is its paths, and a
        // fixture of short names would understate a real one.
        entries.push(json!({
            "path": dir.join(format!(
                "archive/department-{i:03}/scansort-vault-{i:03}-long-enough-to-be-real.sqlite"
            )).to_string_lossy(),
            "name": format!("Department {i:03} scanned records (contract lane fixture)"),
            "added_at": "2026-09-17T00:00:00Z",
        }));
    }
    std::fs::write(&registry_path, serde_json::to_string(&entries).unwrap())
        .expect("write registry fixture");

    let (mut child, mut stdin, mut out) = common::spawn_plugin_with_isolated_library(&dir);
    common::handshake(&mut stdin, &mut out);

    let reply = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {
            "name": "minerva_scansort_registry_list",
            "arguments": {"registry_path": registry_path.to_string_lossy()},
        }
    }));

    let wire_bytes = reply.to_string().len();
    let payload = common::unwrap_tool_ok(&reply);
    let listed = payload
        .get("entries")
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("listing carried no `entries` array: {payload}"));

    println!(
        "measured [scansort lane]: registry_list reply = {wire_bytes} bytes for \
         {} entries — scene control lane is {SCENE_CONTROL_BYTES} bytes, the \
         stdio body limit is {STDIO_BODY_BYTES}",
        listed.len()
    );

    assert_eq!(
        listed.len(),
        FIXTURE_VAULTS,
        "the listing dropped entries: {} of {FIXTURE_VAULTS} arrived",
        listed.len()
    );
    assert!(
        wire_bytes > SCENE_CONTROL_BYTES,
        "the fixture is only {wire_bytes} bytes — it no longer exercises a \
         reply the scene control lane ({SCENE_CONTROL_BYTES}) could not carry"
    );
    assert!(
        wire_bytes < STDIO_BODY_BYTES,
        "the listing is {wire_bytes} bytes, past the stdio body limit \
         ({STDIO_BODY_BYTES}) this lane declares it lives inside"
    );
    // Every entry arrived intact, not merely counted: the last one is the one a
    // truncating transport would lose first.
    let last = &listed[FIXTURE_VAULTS - 1];
    assert!(
        last.get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .contains(&format!("{:03}", FIXTURE_VAULTS - 1)),
        "the last entry did not survive the trip: {last}"
    );

    drop(stdin);
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_refused_call_is_flagged_as_an_error_not_answered_as_data() {
    let dir = common::unique_tmp("lane-refusal");
    std::fs::create_dir_all(&dir).expect("create fixture dir");
    let (mut child, mut stdin, mut out) = common::spawn_plugin_with_isolated_library(&dir);
    common::handshake(&mut stdin, &mut out);

    // registry_add's one required argument, withheld.
    let reply = common::rpc(&mut stdin, &mut out, json!({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": "minerva_scansort_registry_add", "arguments": {}}
    }));

    let result = reply
        .get("result")
        .unwrap_or_else(|| panic!("reply carried no result: {reply}"));
    assert_eq!(
        result.get("isError").and_then(Value::as_bool),
        Some(true),
        "a call missing its required argument was not flagged as an error — the \
         host would pass this to a caller as data: {reply}"
    );
    // The payload's SHAPE, never its prose: an object carrying an `error`
    // field. scansort mints no code of its own; the machine-readable part is
    // the protocol flag above, which the host maps to mcp_tool_error.
    match common::unwrap_tool(&reply) {
        Ok(payload) => panic!("expected a refusal, got a success payload: {payload}"),
        Err(message) => assert!(
            !message.is_empty(),
            "the refusal carried an empty error field: {reply}"
        ),
    }

    drop(stdin);
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
}
