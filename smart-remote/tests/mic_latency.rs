//! Real LAN and stdio PCM delivery with deliberately slow public host replies.
mod common;
use base64::{engine::general_purpose::STANDARD, Engine};
use common::{Device, DEVICE, TOKEN, WAIT};
use serde_json::{json, Value};
use smart_remote_plugin::{schema::Schemas, store::TokenStore};
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{mpsc, Mutex};

#[tokio::test]
async fn realtime_microphone_survives_slow_host_roundtrips() {
    for (latency, data_eos) in [(40, false), (80, true)] {
        slow_host(latency, data_eos).await;
    }
}

async fn slow_host(latency: u64, data_eos: bool) {
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
            if args["op"] == "input_chunk" {
                tokio::time::sleep(std::time::Duration::from_millis(latency)).await;
            }
            let result = match msg["params"]["capability"].as_str().unwrap() {
                "host.chat.active" => {
                    json!({"chat_id":"c1","name":"Chat","group":"","group_id":""})
                }
                "host.audio" if args["op"] == "input_begin" => json!({"session_id":23}),
                "host.speech_log" if args["op"] == "list" => {
                    json!({"success":true,"unheard":0,"total":0,"items":[],"errors":[]})
                }
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
    device.send_json(&common::hello(TOKEN, DEVICE)).await;
    assert_eq!(device.recv_msg().await["type"], "welcome");
    assert_eq!(device.recv_msg().await["chat_id"], "c1");
    assert_eq!(device.recv_msg().await["type"], "draft");
    assert_eq!(
        device.recv_msg().await,
        json!({"type":"missed","unheard":0})
    );
    device
        .send_json(&json!({"type":"ptt_down","stream":7}))
        .await;
    assert_eq!(device.recv_msg().await["state"], "recording");
    let mut expected = Vec::new();
    let mut clock = tokio::time::interval(std::time::Duration::from_millis(20));
    clock.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    for seq in 0..120_u16 {
        clock.tick().await;
        let mut frame = common::mic(7, seq, data_eos && seq == 119, 640);
        let bytes: Vec<u8> = (0..320)
            .flat_map(|n| ((seq as i32 * 320 + n) as i16).to_le_bytes())
            .collect();
        frame[4..].copy_from_slice(&bytes);
        expected.extend(bytes);
        device.send_binary(frame).await;
    }
    if !data_eos {
        device.send_binary(common::mic(7, 120, true, 0)).await;
    }
    let mut delivered = Vec::new();
    let mut chunks = 0_u64;
    let mut ended = false;
    tokio::time::timeout(std::time::Duration::from_secs(4), async {
        while let Some(msg) = seen.recv().await {
            let args = &msg["params"]["args"];
            if args["op"] == "input_chunk" {
                assert_eq!(args["sequence"], chunks);
                let bytes = STANDARD.decode(args["pcm"].as_str().unwrap()).unwrap();
                assert!(!bytes.is_empty() && bytes.len() <= 6400);
                delivered.extend(bytes);
                chunks += 1;
            }
            if args["op"] == "input_end" {
                assert_eq!(args["sequence"], chunks);
                ended = true;
                break;
            }
            assert_ne!(
                args["op"], "input_cancel",
                "realtime input must not overflow"
            );
        }
    })
    .await
    .expect("ordered EOS reaches the host despite its reply latency");
    assert!(ended, "channel closure cannot substitute for input_end");
    assert_eq!(delivered, expected);
    assert!(chunks < 120, "queued PCM must coalesce");
    assert_eq!(device.recv_msg().await["state"], "transcribing");
    child.kill().await.unwrap();
    host.abort();
    drain.abort();
}
