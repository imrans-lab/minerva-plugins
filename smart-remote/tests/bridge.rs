//! Real plugin binary/stdio/LAN contract fixture; Minerva service integration is a separate gate.
mod common;
use common::{Device, DEVICE, TOKEN, WAIT};
use serde_json::{json, Value};
use smart_remote_plugin::{schema::Schemas, store::TokenStore};
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{mpsc, Mutex};

#[tokio::test]
async fn remote_pcm_transcript_submit_and_reply_cross_real_stdio() {
    let dir = tempfile::tempdir().unwrap();
    TokenStore::open(dir.path())
        .unwrap()
        .pair(DEVICE, TOKEN, "Fixture", 0)
        .unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_smart-remote-plugin"))
        .args([
            "--data-dir",
            dir.path().to_str().unwrap(),
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
    let input = Arc::new(Mutex::new(child.stdin.take().unwrap()));
    let mut logs = BufReader::new(child.stderr.take().unwrap()).lines();
    let port = tokio::time::timeout(WAIT, async {
        loop {
            let line = logs.next_line().await.unwrap().unwrap();
            if let Some(addr) = line.split("listening on ws://").nth(1) {
                break addr
                    .split('/')
                    .next()
                    .unwrap()
                    .rsplit(':')
                    .next()
                    .unwrap()
                    .parse::<u16>()
                    .unwrap();
            }
        }
    })
    .await
    .unwrap();
    let drain = tokio::spawn(async move { while let Ok(Some(_)) = logs.next_line().await {} });
    let mut output = BufReader::new(child.stdout.take().unwrap()).lines();
    let (requests, mut seen) = mpsc::channel(64);
    let writer = input.clone();
    let host = tokio::spawn(async move {
        while let Some(line) = output.next_line().await.unwrap() {
            let msg: Value = serde_json::from_str(&line).unwrap();
            if msg["method"] != "minerva/capability" {
                continue;
            }
            let args = &msg["params"]["args"];
            let result = match msg["params"]["capability"].as_str().unwrap() {
                "host.chat.active" => {
                    json!({"chat_id":"c1","name":"Chat","group":"","group_id":""})
                }
                "host.chat.input" if args["op"] == "submit" => json!({"chat_id":"c1","send_id":71}),
                "host.audio" if args["op"] == "input_begin" => json!({"session_id":23}),
                _ => json!({}),
            };
            writer.lock().await.write_all(format!("{}\n", json!({"jsonrpc":"2.0","id":msg["id"],"result":{"success":true,"result":result}})).as_bytes()).await.unwrap();
            requests.send(msg).await.unwrap();
        }
    });
    let mut device = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    device.handshake().await;
    assert_eq!(device.recv_msg().await["chat_id"], "c1");
    assert_eq!(device.recv_msg().await["type"], "draft");
    let registered = next_request(&mut seen, "register").await;
    let endpoint = registered["params"]["args"]["device_id"].clone();
    assert_eq!(endpoint, format!("remote_{DEVICE}"));
    device
        .send_json(&json!({"type":"ptt_down","stream":7}))
        .await;
    assert_eq!(device.recv_msg().await["state"], "recording");
    let mut pcm = common::mic(7, 0, false, 4);
    pcm[4..].copy_from_slice(&[1, 2, 3, 4]);
    device.send_binary(pcm).await;
    device.send_binary(common::mic(7, 1, true, 0)).await;
    assert_eq!(device.recv_msg().await["state"], "transcribing");
    let chunk = next_request(&mut seen, "input_chunk").await;
    assert_eq!(chunk["params"]["args"]["session_id"], 23);
    assert_eq!(chunk["params"]["args"]["sequence"], 0);
    assert_eq!(chunk["params"]["args"]["pcm"], "AQIDBA==");
    assert_eq!(
        next_request(&mut seen, "input_end").await["params"]["args"]["sequence"],
        1
    );
    event(
        &input,
        "voice.transcript",
        json!({"device_id":endpoint,"session_id":23,"chat_id":"c1","text":"Hello","state":"idle"}),
    )
    .await;
    assert_eq!(
        device.recv_msg().await,
        json!({"type":"draft","text":"Hello"})
    );
    assert_eq!(device.recv_msg().await["state"], "idle");
    // Duplicate terminal transcript cannot append twice.
    event(
        &input,
        "voice.transcript",
        json!({"device_id":endpoint,"session_id":23,"chat_id":"c1","text":"Hello","state":"idle"}),
    )
    .await;
    device
        .expect_silence(std::time::Duration::from_millis(60))
        .await;
    // Replacement while the old socket is still live serializes endpoint lifecycle.
    let mut replacement = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    replacement.handshake().await;
    assert_eq!(replacement.recv_msg().await["chat_id"], "c1");
    assert_eq!(replacement.recv_msg().await["text"], "Hello");
    next_request(&mut seen, "register").await;
    let available = next_request(&mut seen, "availability").await;
    assert_eq!(available["params"]["args"]["available"], true);
    device = replacement;
    device.send_json(&json!({"type":"send"})).await;
    assert_eq!(
        next_request(&mut seen, "submit").await["params"]["args"]["expected_chat_id"],
        "c1"
    );
    assert_eq!(device.recv_msg().await, json!({"type":"draft","text":""}));
    event(
        &input,
        "chat.turn_completed",
        json!({"plugin_id":"other","send_id":71,"chat_id":"c1","text":"Wrong","outcome":"ok"}),
    )
    .await;
    event(&input,"chat.turn_completed",json!({"plugin_id":"smart_remote","send_id":71,"chat_id":"c1","text":"Reply","outcome":"ok"})).await;
    assert_eq!(device.recv_msg().await["text"], "Reply");
    // Focus change cancels the actual host session; delayed transcription stays out of the OLED draft.
    device
        .send_json(&json!({"type":"ptt_down","stream":8}))
        .await;
    assert_eq!(device.recv_msg().await["state"], "recording");
    next_request(&mut seen, "input_begin").await;
    event(
        &input,
        "chat.active_changed",
        json!({"chat_id":"c2","name":"Other","group":"","group_id":""}),
    )
    .await;
    assert_eq!(device.recv_msg().await["chat_id"], "c2");
    assert_eq!(device.recv_msg().await["state"], "error");
    next_request(&mut seen, "input_cancel").await;
    event(
        &input,
        "voice.transcript",
        json!({"device_id":endpoint,"session_id":23,"chat_id":"c1","text":"Late","state":"idle"}),
    )
    .await;
    device
        .expect_silence(std::time::Duration::from_millis(60))
        .await;
    device
        .send_json(&json!({"type":"mode","mode":"mouse"}))
        .await;
    assert_eq!(
        next_request(&mut seen, "availability").await["params"]["args"]["available"],
        false
    );
    next_request(&mut seen, "unregister").await;
    let mut reconnect = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    reconnect.handshake().await;
    assert_eq!(reconnect.recv_msg().await["chat_id"], "c1");
    assert_eq!(reconnect.recv_msg().await["type"], "draft");
    next_request(&mut seen, "register").await;
    host.abort(); // Releases its writer clone; the real host EOF shuts down the plugin.
    let _ = host.await;
    drop(input);
    assert!(tokio::time::timeout(WAIT, child.wait())
        .await
        .unwrap()
        .unwrap()
        .success());
    drain.await.unwrap();
}
async fn next_request(rx: &mut mpsc::Receiver<Value>, op: &str) -> Value {
    tokio::time::timeout(WAIT, async {
        loop {
            let msg = rx.recv().await.unwrap();
            if msg["params"]["args"]["op"] == op {
                break msg;
            }
        }
    })
    .await
    .unwrap()
}
async fn event(writer: &Arc<Mutex<tokio::process::ChildStdin>>, name: &str, payload: Value) {
    writer.lock().await.write_all(format!("{}\n",json!({"jsonrpc":"2.0","method":"minerva/host_event","params":{"event":name,"payload":payload}})).as_bytes()).await.unwrap();
}
