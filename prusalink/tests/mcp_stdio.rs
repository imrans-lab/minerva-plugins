//! Actual stdio/backend/config contracts; no real vault values and no printer traffic.
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

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
    assert_eq!(tools.len(), 12);
    assert_eq!(tools.len(), declared.len());
    for tool in tools {
        let canonical = format!("minerva_prusalink_{}", tool["name"].as_str().unwrap());
        let definition = declared.iter().find(|t| t["name"] == canonical).unwrap();
        assert_eq!(tool["inputSchema"], definition["input_schema"]);
        assert_eq!(tool["inputSchema"]["additionalProperties"], false);
        if tool["name"] == "set_password" {
            assert_eq!(
                tool["inputSchema"]["properties"]["password"]["minLength"],
                1
            );
            assert!(tool["description"]
                .as_str()
                .unwrap()
                .contains("Arguments are recorded in Minerva's tool-call log."));
        } else {
            assert!(tool["inputSchema"]["properties"].get("password").is_none());
        }
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
        "configure_printer never accepts credentials"
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
    // Public test input only: the explicit write-only tool is the sole password
    // argument owner. A successful save remains successful if verification fails.
    send(
        &mut input,
        call(
            7,
            "set_password",
            json!({"printer":"printer1","password":"public-invalid-input"}),
        ),
    );
    let set = receive(&mut output);
    assert_eq!(
        set["params"]["capability"],
        "secrets:set:prusalink_printer1"
    );
    assert_eq!(
        set["params"]["args"],
        json!({"value":"public-invalid-input"})
    );
    send(
        &mut input,
        json!({"jsonrpc":"2.0","id":set["id"],"result":{"success":true,"result":{"handle":"prusalink_printer1","status":"created"}}}),
    );
    let verify = receive(&mut output);
    assert_eq!(
        verify["params"]["capability"],
        "secrets:get:prusalink_printer1"
    );
    send(
        &mut input,
        json!({"jsonrpc":"2.0","id":verify["id"],"result":{"success":true,"result":{"exists":false}}}),
    );
    assert_eq!(
        body(&receive(&mut output)),
        json!({"printer":"printer1","saved":true,"auth_ok":false})
    );
    send(
        &mut input,
        call(
            8,
            "set_password",
            json!({"printer":"printer1","password":"public-invalid-input"}),
        ),
    );
    let denied = receive(&mut output);
    send(
        &mut input,
        json!({"jsonrpc":"2.0","id":denied["id"],"result":{"success":false,"error_message":"public-invalid-input"}}),
    );
    let failure = receive(&mut output);
    assert_eq!(failure["result"]["isError"], true);
    assert!(!failure.to_string().contains("public-invalid-input"));
    // Exercise the saved-value verification through the real backend and HTTP
    // client, with RFC example text and a disposable loopback server only.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let host = format!("http://{}", listener.local_addr().unwrap());
    let server = thread::spawn(move || {
        for (path,code,extra,body) in [
            ("/api/version","401 Unauthorized","WWW-Authenticate: Digest realm=\"Printer API\", nonce=\"public-protocol-nonce\", qop=\"auth\", algorithm=MD5\r\n",""),
            ("/api/v1/status","200 OK","",r#"{"printer":{"state":"IDLE"}}"#),
            ("/api/v1/job","204 No Content","",""),
            ("/api/v1/storage","200 OK","",r#"{"storage_list":[]}"#),
        ] {
            let (mut stream,_)=listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut headers=Vec::new();let mut byte=[0_u8;1];
            while !headers.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();headers.push(byte[0]);assert!(headers.len()<16*1024);
            }
            let headers=String::from_utf8(headers).unwrap();
            assert!(headers.starts_with(&format!("GET {path} HTTP/1.1\r\n")));
            assert!(!headers.contains("Circle Of Life"));
            if path!="/api/version" { assert!(headers.contains("Authorization: Digest ")); }
            write!(stream,"HTTP/1.1 {code}\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{extra}\r\n{body}",body.len()).unwrap();
            stream.flush().unwrap();
        }
    });
    send(
        &mut input,
        call(
            9,
            "configure_printer",
            json!({"slot":1,"name":"Lab","host":host}),
        ),
    );
    assert_eq!(body(&receive(&mut output))["id"], "printer1");
    send(
        &mut input,
        call(
            10,
            "set_password",
            json!({"printer":"printer1","password":"Circle Of Life"}),
        ),
    );
    let save = receive(&mut output);
    assert_eq!(save["params"]["args"], json!({"value":"Circle Of Life"}));
    send(
        &mut input,
        json!({"jsonrpc":"2.0","id":save["id"],"result":{"success":true,"result":{"handle":"prusalink_printer1","status":"updated"}}}),
    );
    let get = receive(&mut output);
    assert_eq!(
        get["params"]["capability"],
        "secrets:get:prusalink_printer1"
    );
    send(
        &mut input,
        json!({"jsonrpc":"2.0","id":get["id"],"result":{"success":true,"result":{"exists":true,"value":"Circle Of Life"}}}),
    );
    let verified = receive(&mut output);
    assert_eq!(
        body(&verified),
        json!({"printer":"printer1","saved":true,"auth_ok":true})
    );
    assert!(!verified.to_string().contains("Circle Of Life"));
    server.join().unwrap();
    send(
        &mut input,
        call(
            11,
            "set_password",
            json!({"printer":"printer1","password":""}),
        ),
    );
    assert_eq!(receive(&mut output)["result"]["isError"], true);
    send(&mut input, call(12, "list_printers", json!({})));
    let get = receive(&mut output);
    send(
        &mut input,
        json!({"jsonrpc":"2.0","id":get["id"],"result":{"success":true,"result":{"exists":true,"value":"Circle Of Life"}}}),
    );
    let list = receive(&mut output);
    assert_eq!(body(&list)["printers"][0]["has_password"], true);
    assert!(!list.to_string().contains("Circle Of Life"));
    let stored: Value =
        serde_json::from_slice(&std::fs::read(directory.join("printers.json")).unwrap()).unwrap();
    let printer = stored["printers"][0].as_object().unwrap();
    assert_eq!(printer.len(), 4);
    assert!(!stored.to_string().contains("Circle Of Life"));
    for key in ["slot", "name", "host", "user"] {
        assert!(printer.contains_key(key));
    }
    drop(input);
    assert!(child.wait().unwrap().success());
    let mut stderr = String::new();
    std::io::Read::read_to_string(&mut child.stderr.take().unwrap(), &mut stderr).unwrap();
    assert!(stderr.is_empty());
}
