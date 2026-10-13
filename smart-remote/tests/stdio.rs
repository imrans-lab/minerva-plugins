//! Drives the real binary's stdio as a minimal scripted Minerva host.

mod common;

use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use common::{hello, Device, DEVICE, TOKEN, WAIT};
use serde_json::{json, Value};
use smart_remote_plugin::schema::Schemas;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

#[tokio::test]
async fn scripted_host_handshake_host_events_and_clean_exit_on_eof() {
    let data = tempfile::tempdir().unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_smart-remote-plugin"))
        .args([
            "--data-dir",
            data.path().to_str().unwrap(),
            "--bind",
            "127.0.0.1",
            "--port",
            "0",
            "--no-mdns",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap()).lines();
    let mut stderr = BufReader::new(child.stderr.take().unwrap()).lines();

    // The port comes from the startup log line; logs go to stderr only.
    let port: u16 = tokio::time::timeout(WAIT, async {
        loop {
            let line = stderr
                .next_line()
                .await
                .unwrap()
                .expect("plugin exited early");
            if let Some(rest) = line.split("listening on ws://").nth(1) {
                let addr = rest.split('/').next().unwrap();
                return addr.rsplit(':').next().unwrap().parse().unwrap();
            }
        }
    })
    .await
    .expect("listening log line");
    let stderr_drain =
        tokio::spawn(async move { while let Ok(Some(_)) = stderr.next_line().await {} });

    let script = [
        json!({"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}),
        json!({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Minerva","version":"1.0.0"}}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","method":"minerva/host_event","params":{"event":"chat.turn_completed","payload":{"chat_id":"c1","outcome":"ok"}}}),
        json!({"jsonrpc":"2.0","method":"minerva/host_event","params":{"event":"chat.directory_changed","payload":{}}}),
        json!({"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}),
        json!({"jsonrpc":"2.0","id":4.0,"method":"ping"}),
    ];
    for msg in &script {
        stdin
            .write_all(format!("{msg}\n").as_bytes())
            .await
            .unwrap();
    }
    stdin.write_all(b"this line is not json\n").await.unwrap();
    stdin.flush().await.unwrap();

    let mut replies = Vec::new();
    for _ in 0..4 {
        let line = tokio::time::timeout(WAIT, stdout.next_line())
            .await
            .expect("reply within WAIT")
            .unwrap()
            .expect("stdout open");
        let reply: Value =
            serde_json::from_str(&line).unwrap_or_else(|_| panic!("junk on stdout: {line}"));
        assert_eq!(reply["jsonrpc"], "2.0", "{reply}");
        replies.push(reply);
    }
    assert_eq!(replies[0]["id"], 1);
    assert_eq!(replies[0]["error"]["code"], -32601);
    assert_eq!(replies[1]["id"], 2);
    assert_eq!(replies[1]["result"]["protocolVersion"], "2024-11-05");
    assert_eq!(replies[1]["result"]["serverInfo"]["name"], "smart_remote");
    assert!(replies[1]["result"]["capabilities"].is_object());
    assert_eq!(
        replies[2],
        json!({"jsonrpc":"2.0","id":3,"result":{"tools":[]}})
    );
    assert_eq!(replies[3]["id"], 4.0);
    assert_eq!(replies[3]["result"], json!({}));

    // The LAN side of the same process is up and enforcing auth.
    let schemas = Arc::new(Schemas::load().unwrap());
    let mut device = Device::connect(([127, 0, 0, 1], port).into(), schemas).await;
    device.send_json(&hello(TOKEN, DEVICE)).await;
    assert_eq!(device.recv_msg().await["code"], "auth");
    device.expect_close(smart_remote_plugin::CLOSE_AUTH).await;

    drop(stdin);
    let status = tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .expect("exits after stdin EOF")
        .unwrap();
    assert!(status.success(), "exit status {status}");
    assert_eq!(
        stdout.next_line().await.unwrap(),
        None,
        "nothing else on stdout"
    );
    stderr_drain.await.unwrap();
}

#[tokio::test]
async fn unknown_arguments_fail_without_touching_stdout() {
    let output = Command::new(env!("CARGO_BIN_EXE_smart-remote-plugin"))
        .arg("--bogus")
        .stdin(Stdio::null())
        .output()
        .await
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
}
