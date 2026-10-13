//! Real plugin binary/stdio/LAN contract fixture; Minerva service integration is a separate gate.
mod common;
use common::{Device, DEVICE, TOKEN, WAIT};
use serde_json::{json, Value};
use smart_remote_plugin::{schema::Schemas, store::TokenStore};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{mpsc, Mutex};

#[tokio::test]
async fn authoritative_log_controls_cross_real_stdio_and_lan() {
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
    let deleted = Arc::new(AtomicBool::new(false));
    let denied = Arc::new(AtomicBool::new(false));
    let deny = denied.clone();
    let hold_delete = Arc::new(AtomicBool::new(false));
    let hold = hold_delete.clone();
    let malformed = Arc::new(AtomicBool::new(false));
    let (state, bad) = (deleted.clone(), malformed.clone());
    let writer = input.clone();
    let host = tokio::spawn(async move {
        while let Some(line) = output.next_line().await.unwrap() {
            let msg: Value = serde_json::from_str(&line).unwrap();
            if msg["method"] != "minerva/capability" {
                continue;
            }
            let args = &msg["params"]["args"];
            if msg["params"]["capability"] == "host.speech_log" && deny.load(Ordering::SeqCst) {
                writer.lock().await.write_all(format!("{}\n",json!({"jsonrpc":"2.0","id":msg["id"],"result":{"success":false,"error_code":"capability_not_granted","error_message":"Capability not granted"}})).as_bytes()).await.unwrap();
                requests.send(msg).await.unwrap();
                continue;
            }
            if msg["params"]["capability"] == "host.speech_log"
                && args["op"] == "list"
                && (args["offset"] == 8 || args["offset"] == 9)
            {
                requests.send(msg).await.unwrap();
                continue;
            }
            if msg["params"]["capability"] == "host.speech_log"
                && args["op"] == "delete"
                && hold.load(Ordering::SeqCst)
            {
                requests.send(msg).await.unwrap();
                continue;
            }
            let result = match msg["params"]["capability"].as_str().unwrap() {
                "host.chat.active" => {
                    json!({"chat_id":"c1","name":"Chat","group":"","group_id":""})
                }
                "host.audio" if args["op"] == "input_begin" => json!({"session_id":31}),
                "host.speech_log" => match args["op"].as_str().unwrap() {
                    "list" => {
                        json!({"success":true,"items":if state.load(Ordering::SeqCst){json!([])}else{json!([{"log_id":"speech_7","created_at":0,"summary":"ABCDEFGHIJKLMNOPQRSTUVW","heard":false,"superseded":false,"origin_kind":"explicit"}])},"unheard":if bad.load(Ordering::SeqCst){json!(1.5)}else{json!(if state.load(Ordering::SeqCst){0}else{1})},"total":if state.load(Ordering::SeqCst){0}else{1},"errors":[]})
                    }
                    "play" => {
                        json!({"success":true,"delivery":"playing","device":args["device_id"],"log_id":args["log_id"],"unheard_count":1})
                    }
                    "delete" | "delete_all" => {
                        state.store(true, Ordering::SeqCst);
                        json!({"success":true})
                    }
                    _ => panic!("unexpected log op; plugin must never mark heard"),
                },
                _ => json!({}),
            };
            writer.lock().await.write_all(format!("{}\n",json!({"jsonrpc":"2.0","id":msg["id"],"result":{"success":true,"result":result}})).as_bytes()).await.unwrap();
            requests.send(msg).await.unwrap();
        }
    });
    let mut device = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    hello(&mut device).await;
    assert_eq!(
        device.recv_msg().await,
        json!({"type":"missed","unheard":1})
    );
    next_request(&mut seen, "list").await;
    device
        .send_json(&json!({"type":"log_page","offset":0,"limit":2}))
        .await;
    assert_eq!(device.recv_msg().await["unheard"], 1);
    let page = device.recv_msg().await;
    assert_eq!(page["type"], "log_items");
    assert_eq!(page["offset"], 0);
    assert_eq!(page["total"], 1);
    assert_eq!(page["items"][0]["log_id"], "speech_7");
    assert_eq!(page["items"][0]["summary"], "ABCDEFGHIJKLMNOPQRSTU");
    assert_eq!(page["items"][0]["heard"], false);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    assert!((now - 1..=now).contains(&page["items"][0]["age_s"].as_u64().unwrap()));
    let request = next_request(&mut seen, "list").await;
    assert_eq!(
        request["params"]["args"],
        json!({"op":"list","offset":0,"limit":2})
    );
    device
        .send_json(&json!({"type":"log_play","log_id":"speech_7"}))
        .await;
    assert_eq!(
        device.recv_msg().await,
        json!({"type":"status","text":"Playing"})
    );
    assert_eq!(
        next_request(&mut seen, "play").await["params"]["args"],
        json!({"op":"play","log_id":"speech_7","device_id":format!("plugin:smart_remote:remote_{DEVICE}")})
    );
    device.send_json(&json!({"type":"replay_last"})).await;
    assert_eq!(device.recv_msg().await["unheard"], 1);
    assert_eq!(device.recv_msg().await["text"], "Playing");
    assert_eq!(
        next_request(&mut seen, "list").await["params"]["args"]["limit"],
        1
    );
    assert_eq!(
        next_request(&mut seen, "play").await["params"]["args"]["log_id"],
        "speech_7"
    );
    event(&input, "speech_log.changed", json!({"unheard":0,"total":1})).await;
    assert_eq!(
        device.recv_msg().await,
        json!({"type":"missed","unheard":0})
    );
    malformed.store(true, Ordering::SeqCst);
    device
        .send_json(&json!({"type":"log_page","offset":0,"limit":2}))
        .await;
    assert_eq!(device.recv_msg().await["code"], "internal");
    next_request(&mut seen, "list").await;
    malformed.store(false, Ordering::SeqCst);
    // An old unanswered page cannot refresh a new connection.
    device
        .send_json(&json!({"type":"log_page","offset":8,"limit":2}))
        .await;
    let old = next_request(&mut seen, "list").await;
    let mut replacement = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    hello(&mut replacement).await;
    assert_eq!(replacement.recv_msg().await["unheard"], 1);
    next_request(&mut seen, "list").await;
    device = replacement;
    input.lock().await.write_all(format!("{}\n",json!({"jsonrpc":"2.0","id":old["id"],"result":{"success":true,"result":{"success":true,"items":[],"unheard":0,"total":0,"errors":[]}}})).as_bytes()).await.unwrap();
    device
        .expect_silence(std::time::Duration::from_millis(60))
        .await;
    // Pending log work neither blocks nor cancels real microphone bytes.
    device
        .send_json(&json!({"type":"log_page","offset":9,"limit":2}))
        .await;
    next_request(&mut seen, "list").await;
    device
        .send_json(&json!({"type":"ptt_down","stream":31}))
        .await;
    assert_eq!(device.recv_msg().await["state"], "recording");
    device
        .send_json(&json!({"type":"log_page","offset":0,"limit":2}))
        .await;
    assert_eq!(device.recv_msg().await["type"], "status");
    let mut pcm = common::mic(31, 0, false, 4);
    pcm[4..].copy_from_slice(&[1, 2, 3, 4]);
    device.send_binary(pcm).await;
    device.send_binary(common::mic(31, 1, true, 0)).await;
    assert_eq!(device.recv_msg().await["state"], "transcribing");
    assert_eq!(
        next_request(&mut seen, "input_chunk").await["params"]["args"]["pcm"],
        "AQIDBA=="
    );
    let Some(common::Event::Msg(timeout)) =
        device.next_event(std::time::Duration::from_secs(6)).await
    else {
        panic!("missing log timeout")
    };
    assert_eq!(timeout["code"], "internal");
    device.send_json(&json!({"type":"clear"})).await;
    assert_eq!(device.recv_msg().await["state"], "idle");
    assert_eq!(device.recv_msg().await["text"], "");
    next_request(&mut seen, "clear").await;
    device
        .send_json(&json!({"type":"log_delete","log_id":"speech_7"}))
        .await;
    assert_eq!(device.recv_msg().await["text"], "Deleted");
    assert_eq!(device.recv_msg().await["unheard"], 0);
    assert_eq!(device.recv_msg().await["items"], json!([]));
    assert_eq!(
        next_request(&mut seen, "delete").await["params"]["args"],
        json!({"op":"delete","log_id":"speech_7"})
    );
    next_request(&mut seen, "list").await;
    deleted.store(false, Ordering::SeqCst);
    device.send_json(&json!({"type":"log_delete_all"})).await;
    assert_eq!(device.recv_msg().await["text"], "Deleted all");
    assert_eq!(device.recv_msg().await["unheard"], 0);
    assert_eq!(device.recv_msg().await["items"], json!([]));
    assert_eq!(
        next_request(&mut seen, "delete_all").await["params"]["args"],
        json!({"op":"delete_all","confirmed":true})
    );
    next_request(&mut seen, "list").await;
    device.send_json(&json!({"type":"replay_last"})).await;
    assert_eq!(device.recv_msg().await["unheard"], 0);
    assert_eq!(device.recv_msg().await["text"], "Speech log is empty");
    next_request(&mut seen, "list").await;
    assert!(
        seen.try_recv().is_err(),
        "no delete/play retry or mark call"
    );
    hold_delete.store(true, Ordering::SeqCst);
    device
        .send_json(&json!({"type":"log_delete","log_id":"speech_7"}))
        .await;
    next_request(&mut seen, "delete").await;
    let Some(common::Event::Msg(timeout)) =
        device.next_event(std::time::Duration::from_secs(6)).await
    else {
        panic!("missing mutation timeout")
    };
    assert_eq!(timeout["code"], "internal");
    assert!(
        seen.try_recv().is_err(),
        "unknown mutation must not be retried/refreshed"
    );
    // Cancellation/replacement also suppresses a late destructive receipt.
    device
        .send_json(&json!({"type":"log_delete","log_id":"speech_7"}))
        .await;
    let old_delete = next_request(&mut seen, "delete").await;
    let mut replacement = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    hello(&mut replacement).await;
    assert_eq!(replacement.recv_msg().await["unheard"], 0);
    next_request(&mut seen, "list").await;
    device = replacement;
    input.lock().await.write_all(format!("{}\n",json!({"jsonrpc":"2.0","id":old_delete["id"],"result":{"success":true,"result":{"success":true}}})).as_bytes()).await.unwrap();
    device
        .expect_silence(std::time::Duration::from_millis(60))
        .await;
    assert!(
        seen.try_recv().is_err(),
        "cancelled delete must not refresh/retry on replacement"
    );
    device
        .send_json(&json!({"type":"log_page","offset":0,"limit":11}))
        .await;
    assert_eq!(device.recv_msg().await["code"], "bad_message");
    device.expect_close(4002).await;
    let mut revoked = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    hello(&mut revoked).await;
    assert_eq!(revoked.recv_msg().await["unheard"], 0);
    next_request(&mut seen, "list").await;
    denied.store(true, Ordering::SeqCst);
    revoked
        .send_json(&json!({"type":"log_page","offset":0,"limit":1}))
        .await;
    assert_eq!(revoked.recv_msg().await["code"], "internal");
    assert!(matches!(
        revoked.recv().await,
        common::Event::Closed(_) | common::Event::Ended
    ));
    next_request(&mut seen, "unregister").await;
    denied.store(false, Ordering::SeqCst);
    let mut mutation_revoke = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    hello(&mut mutation_revoke).await;
    assert_eq!(mutation_revoke.recv_msg().await["unheard"], 0);
    next_request(&mut seen, "list").await;
    denied.store(true, Ordering::SeqCst);
    mutation_revoke
        .send_json(&json!({"type":"log_delete","log_id":"speech_7"}))
        .await;
    assert_eq!(mutation_revoke.recv_msg().await["code"], "internal");
    assert!(matches!(
        mutation_revoke.recv().await,
        common::Event::Closed(_) | common::Event::Ended
    ));
    next_request(&mut seen, "unregister").await;
    denied.store(false, Ordering::SeqCst);
    let mut at_eof = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    hello(&mut at_eof).await;
    assert_eq!(at_eof.recv_msg().await["unheard"], 0);
    next_request(&mut seen, "list").await;
    at_eof
        .send_json(&json!({"type":"log_delete","log_id":"speech_eof"}))
        .await;
    next_request(&mut seen, "delete").await;
    // Real host stdin EOF cancels an outstanding mutation call and stops the binary.
    host.abort();
    let _ = host.await;
    drop(input);
    assert!(tokio::time::timeout(WAIT, child.wait())
        .await
        .unwrap()
        .unwrap()
        .success());
    drain.await.unwrap();
}
async fn hello(device: &mut Device) {
    device.send_json(&common::hello(TOKEN, DEVICE)).await;
    assert_eq!(device.recv_msg().await["type"], "welcome");
    assert_eq!(device.recv_msg().await["chat_id"], "c1");
    assert_eq!(device.recv_msg().await["type"], "draft");
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
