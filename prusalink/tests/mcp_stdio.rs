//! Actual stdio/backend/config contracts; no real vault values and no printer traffic.
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

use serde_json::{json, Value};

fn send(input: &mut impl Write, value: Value) {
    writeln!(input, "{value}").unwrap();
    input.flush().unwrap();
}
fn receive(output: &mut impl BufRead) -> Value {
    let mut line = String::new();
    assert!(output.read_line(&mut line).unwrap() > 0);
    serde_json::from_str(&line).unwrap()
}
fn call(id: u64, name: &str, args: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"method":"tools/call","params":{"name":name,"arguments":args}})
}
fn body(reply: &Value) -> Value {
    serde_json::from_str(reply["result"]["content"][0]["text"].as_str().unwrap()).unwrap()
}

#[test]
fn manifest_stdio_metadata_and_private_vault_request_boundary() {
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let directory =
        std::env::temp_dir().join(format!("prusalink-mcp-{}-{unique}", std::process::id()));
    let mut child = Command::new(env!("CARGO_BIN_EXE_prusalink-plugin"))
        .env("MINERVA_PLUGIN_DATA_DIR", &directory)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    send(
        &mut input,
        json!({"jsonrpc":"2.0","id":1,"method":"initialize"}),
    );
    assert_eq!(
        receive(&mut output)["result"]["serverInfo"]["name"],
        "PrusaLink"
    );
    send(
        &mut input,
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
    );
    let reply = receive(&mut output);
    let tools = reply["result"]["tools"].as_array().unwrap();
    let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
    let declared = manifest["tools"].as_array().unwrap();
    assert_eq!(tools.len(), 9);
    assert_eq!(tools.len(), declared.len());
    for tool in tools {
        let canonical = format!("minerva_prusalink_{}", tool["name"].as_str().unwrap());
        let definition = declared.iter().find(|t| t["name"] == canonical).unwrap();
        assert_eq!(tool["inputSchema"], definition["input_schema"]);
        assert_eq!(tool["inputSchema"]["additionalProperties"], false);
        assert!(tool["inputSchema"]["properties"].get("password").is_none());
    }
    let caps = manifest["permissions"]["host_capabilities"]
        .as_array()
        .unwrap();
    assert_eq!(caps.len(), 25);
    assert!(caps.contains(&json!("host.notify")));
    for slot in 1..=8 {
        for operation in ["get", "set", "delete"] {
            assert!(caps.contains(&json!(format!(
                "secrets:{operation}:prusalink_printer{slot}"
            ))));
        }
    }
    send(&mut input, call(3, "list_printers", json!({})));
    assert_eq!(body(&receive(&mut output))["printers"], json!([]));
    send(
        &mut input,
        call(
            4,
            "configure_printer",
            json!({"name":"Lab","host":"127.0.0.1:9","password":"public-invalid-input"}),
        ),
    );
    assert_eq!(
        receive(&mut output)["result"]["isError"],
        true,
        "credentials are not tool arguments"
    );
    send(
        &mut input,
        call(
            5,
            "configure_printer",
            json!({"name":"Lab","host":"127.0.0.1:9"}),
        ),
    );
    let configured = body(&receive(&mut output));
    assert_eq!(configured["id"], "printer1");
    assert_eq!(configured["secret_handle"], "prusalink_printer1");
    send(&mut input, call(6, "list_printers", json!({})));
    let private = receive(&mut output);
    assert_eq!(private["method"], "minerva/capability");
    assert_eq!(
        private["params"]["capability"],
        "secrets:get:prusalink_printer1"
    );
    assert_eq!(private["params"]["args"], json!({}));
    // A host protocol response with NO credential: this is not live vault acceptance.
    send(
        &mut input,
        json!({"jsonrpc":"2.0","id":private["id"],"result":{"success":true,"result":{"exists":false}}}),
    );
    let listed = body(&receive(&mut output));
    assert_eq!(listed["printers"][0]["has_password"], false);
    let stored: Value =
        serde_json::from_slice(&std::fs::read(directory.join("printers.json")).unwrap()).unwrap();
    let printer = stored["printers"][0].as_object().unwrap();
    assert_eq!(printer.len(), 4);
    for key in ["slot", "name", "host", "user"] {
        assert!(printer.contains_key(key));
    }
    drop(input);
    assert!(child.wait().unwrap().success());
    let mut stderr = String::new();
    std::io::Read::read_to_string(&mut child.stderr.take().unwrap(), &mut stderr).unwrap();
    assert!(stderr.is_empty());
}
