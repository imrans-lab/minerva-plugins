//! 3d-gen's LANE DECLARATION — generated artifacts travel as paths, proved.
//!
//! WHY THIS EXISTS
//!
//! The per-plugin contract guards weigh six cases against the host's scene
//! control lane (65,536 UTF-8 bytes each way). 3d-gen never approaches it,
//! because nothing that grows with the work ever crosses it: a generated GLB is
//! written to disk by `save_artifact` (temp_dir()/minerva-gen3d/<filename>) and
//! the reply carries {path, filename, bytes} — a handle and a number, never the
//! model. The reference image travels the same way, as `image_path`.
//!
//! So this declares the lane and proves the halves that are provable without a
//! media-gen service:
//!
//!   * NOTHING THAT GROWS GOES IN. Every generating tool's published input
//!     schema is read back from the running binary, and neither takes bytes:
//!     the image arrives as a path. A base64 parameter appearing here is the
//!     change that would put this plugin on the control lane, and it fails this
//!     test the day it lands.
//!   * A NULL OR MALFORMED REQUEST IS REFUSED, with the MCP `isError` flag set
//!     — the machine-readable part, which the host turns into
//!     `error_code: "mcp_tool_error"` — and nothing is written to the artifact
//!     directory on the way to the refusal.
//!
//! WHAT IS DECLARED AND NOT PROVED HERE, stated rather than implied: the
//! SUCCESS arm's shape. Reaching it needs the Minerva media-gen service over a
//! websocket, which this test deliberately does not stand up — a stub would
//! prove the stub. The contract it is declaring is one function wide
//! (src/main.rs `save_artifact` and the `tool_ok(json!({"path", "filename",
//! "bytes"}))` beside it); a change there is a change to this header.
//!
//! WHAT 3D-GEN DOES NOT HAVE: a refusal code of its own. `tool_err` answers
//! {"error": "<prose>"}, so nothing below reads that text — the protocol flag
//! and the payload shape are what is asserted.
//!
//! ORACLE: add a bytes-in parameter to either tool, or return the GLB inline
//! instead of saving it, and the lane this file declares is gone — the first
//! change fails the schema assertion here, and the second makes every real
//! generation exceed the host's cap.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

/// The tools that generate, and the path-shaped input each takes.
const GENERATING_TOOLS: [&str; 2] = ["minerva_gen3d_text_to_3d", "minerva_gen3d_image_to_3d"];

/// Property-name fragments that would mean bytes are crossing the wire. A
/// schema is machine-readable; the description beside it is not, and is never
/// read here.
const BYTES_SHAPED: [&str; 4] = ["_b64", "base64", "_bytes", "image_data"];

/// Where a generated artifact lands. Asserted for COUNT rather than emptiness:
/// this directory is shared with whatever real runs the developer has done.
fn artifact_dir() -> std::path::PathBuf {
    std::env::temp_dir().join("minerva-gen3d")
}

fn artifact_count() -> usize {
    std::fs::read_dir(artifact_dir())
        .map(|entries| entries.count())
        .unwrap_or(0)
}

/// Spawn the real binary with stdio piped. Nothing is mocked: this is the same
/// process the host starts.
fn spawn() -> (Child, ChildStdin, BufReader<ChildStdout>) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_gen3d-plugin"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn gen3d-plugin");
    let stdin = child.stdin.take().expect("stdin");
    let out = BufReader::new(child.stdout.take().expect("stdout"));
    (child, stdin, out)
}

/// One request, and the reply whose id matches it. Progress notifications and
/// capability requests carry no matching id and are skipped, which is also what
/// makes this safe to call for a tool that never reaches its capability hop.
fn rpc(stdin: &mut ChildStdin, out: &mut BufReader<ChildStdout>, req: Value) -> Value {
    let want = req.get("id").cloned();
    stdin
        .write_all((req.to_string() + "\n").as_bytes())
        .expect("write request");
    stdin.flush().expect("flush");
    loop {
        let mut buf = String::new();
        if out.read_line(&mut buf).expect("read reply") == 0 {
            panic!("plugin closed stdout before replying to {want:?}");
        }
        let Ok(value) = serde_json::from_str::<Value>(buf.trim()) else {
            continue; // a log line on stdout
        };
        if value.get("id") == want.as_ref() {
            return value;
        }
    }
}

fn handshake(stdin: &mut ChildStdin, out: &mut BufReader<ChildStdout>) {
    rpc(stdin, out, json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}
    }));
    stdin
        .write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n")
        .expect("write initialized");
    stdin.flush().expect("flush");
}

#[test]
fn nothing_that_grows_with_the_work_crosses_the_wire() {
    let (mut child, mut stdin, mut out) = spawn();
    handshake(&mut stdin, &mut out);

    let listed = rpc(&mut stdin, &mut out, json!({
        "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}
    }));
    let tools = listed["result"]["tools"]
        .as_array()
        .unwrap_or_else(|| panic!("tools/list carried no tools: {listed}"));

    for name in GENERATING_TOOLS {
        let tool = tools
            .iter()
            .find(|t| t.get("name").and_then(Value::as_str) == Some(name))
            .unwrap_or_else(|| panic!("{name} is no longer published: {listed}"));
        let properties = tool["inputSchema"]["properties"]
            .as_object()
            .unwrap_or_else(|| panic!("{name} publishes no input properties: {tool}"));
        for property in properties.keys() {
            for fragment in BYTES_SHAPED {
                assert!(
                    !property.to_ascii_lowercase().contains(fragment),
                    "{name} now takes `{property}`, which carries bytes across the \
                     wire — 3d-gen's declared lane is paths in and paths out, and \
                     this file's header is the contract that has to change first"
                );
            }
        }
    }

    // The one input that names a file does so as a path, which is the lane on
    // the way in.
    let image_tool = tools
        .iter()
        .find(|t| t.get("name").and_then(Value::as_str) == Some("minerva_gen3d_image_to_3d"))
        .expect("image_to_3d");
    assert_eq!(
        image_tool["inputSchema"]["properties"]["image_path"]["type"].as_str(),
        Some("string"),
        "image_to_3d no longer takes its reference image as a path: {image_tool}"
    );

    println!(
        "declared [3d-gen lane]: {} generating tools, none taking bytes; \
         artifacts are saved under {} and answered as a path",
        GENERATING_TOOLS.len(),
        artifact_dir().display()
    );

    drop(stdin);
    let _ = child.wait();
}

#[test]
fn a_null_request_is_refused_and_writes_nothing() {
    let before = artifact_count();
    let (mut child, mut stdin, mut out) = spawn();
    handshake(&mut stdin, &mut out);

    // Both tools, each called with nothing — the null document for a plugin
    // whose document is its prompt. Argument validation runs BEFORE the
    // credentials hop, so no service is involved in either refusal.
    for (id, name) in GENERATING_TOOLS.iter().enumerate() {
        let reply = rpc(&mut stdin, &mut out, json!({
            "jsonrpc": "2.0", "id": 10 + id, "method": "tools/call",
            "params": {"name": name, "arguments": {}}
        }));
        let result = reply
            .get("result")
            .unwrap_or_else(|| panic!("{name}: reply carried no result: {reply}"));
        assert_eq!(
            result.get("isError").and_then(Value::as_bool),
            Some(true),
            "{name}: a request with no arguments was not flagged as an error — \
             the host would hand this to a caller as data: {reply}"
        );
        // The payload's SHAPE, never its prose: an object carrying `error`.
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{name}: refusal carried no text content: {reply}"));
        let payload: Value = serde_json::from_str(text)
            .unwrap_or_else(|e| panic!("{name}: refusal payload is not JSON ({e}): {text}"));
        assert!(
            payload.get("error").and_then(Value::as_str).is_some(),
            "{name}: the refusal names no error field: {payload}"
        );
    }

    // A malformed argument of the right name is refused the same way — an
    // empty prompt is not a prompt.
    let reply = rpc(&mut stdin, &mut out, json!({
        "jsonrpc": "2.0", "id": 20, "method": "tools/call",
        "params": {"name": "minerva_gen3d_text_to_3d", "arguments": {"positive_prompt": ""}}
    }));
    assert_eq!(
        reply["result"].get("isError").and_then(Value::as_bool),
        Some(true),
        "an empty prompt was accepted as a document: {reply}"
    );

    assert_eq!(
        artifact_count(),
        before,
        "a refused generation left something behind in {}",
        artifact_dir().display()
    );

    drop(stdin);
    let _ = child.wait();
}
