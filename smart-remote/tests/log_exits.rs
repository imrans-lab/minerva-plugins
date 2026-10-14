//! Real binary/stdio/LAN exit matrix; transient event/PTT rows have no log RPC to time out.
mod common;
use common::{Device, DEVICE, TOKEN, WAIT};
use serde_json::{json, Value};
use smart_remote_plugin::{schema::Schemas, store::TokenStore};
use std::{
    process::Stdio,
    sync::{
        atomic::{AtomicU8, AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Command,
    sync::{mpsc, Mutex},
};

#[tokio::test]
async fn six_log_states_five_exit_cases_cross_real_binary() {
    for state in [
        "hello/count",
        "page",
        "play/replay",
        "confirmed delete",
        "count changed",
        "idle/PTT",
    ] {
        for exit in [
            "Cancel",
            "Timeout",
            "Disconnect/reconnect",
            "Revoke",
            "Host EOF",
        ] {
            println!("CASE {state}/{exit}");
            exercise(state, exit).await;
        }
    }
}
async fn exercise(state: &str, exit: &str) {
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
    let mode = Arc::new(AtomicU8::new(u8::from(state == "hello/count")));
    let gate = mode.clone();
    let audio = Arc::new(AtomicUsize::new(0));
    let bytes = audio.clone();
    let writer = input.clone();
    let host = tokio::spawn(async move {
        while let Some(line) = output.next_line().await.unwrap() {
            let msg: Value = serde_json::from_str(&line).unwrap();
            if msg["method"] != "minerva/capability" {
                continue;
            }
            let args = &msg["params"]["args"];
            let is_log = msg["params"]["capability"] == "host.speech_log";
            if is_log {
                requests.send(msg.clone()).await.unwrap();
                if gate.load(Ordering::SeqCst) == 1 {
                    continue;
                }
            }
            if args["op"] == "input_chunk" {
                assert_eq!(args["pcm"], "AQIDBA==");
                bytes.fetch_add(1, Ordering::SeqCst);
            }
            let result = if is_log {
                list()
            } else if msg["params"]["capability"] == "host.chat.active" {
                json!({"chat_id":"c1","name":"Chat","group":"","group_id":""})
            } else if args["op"] == "input_begin" {
                json!({"session_id":31})
            } else {
                json!({})
            };
            rpc(&writer, &msg["id"], json!({"success":true,"result":result})).await;
        }
    });
    let mut device = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    hello(&mut device).await;
    let transient = matches!(state, "count changed" | "idle/PTT");
    let mut pending = None;
    if state == "hello/count" {
        pending = Some(next(&mut seen).await)
    } else {
        assert_eq!(device.recv_msg().await["unheard"], 1);
        next(&mut seen).await;
        mode.store(1, Ordering::SeqCst);
        match state {
            "page" => {
                device
                    .send_json(&json!({"type":"log_page","offset":0,"limit":2}))
                    .await
            }
            "play/replay" => device.send_json(&json!({"type":"replay_last"})).await,
            "confirmed delete" => {
                device
                    .send_json(&json!({"type":"log_delete","log_id":"speech_7"}))
                    .await
            }
            "count changed" => {
                event(&input, json!({"unheard":0.0,"total":1.0})).await;
                assert_eq!(device.recv_msg().await["unheard"], 0);
            }
            "idle/PTT" => {
                device
                    .send_json(&json!({"type":"ptt_down","stream":31}))
                    .await;
                assert_eq!(device.recv_msg().await["state"], "recording");
            }
            _ => unreachable!(),
        }
        if !transient {
            pending = Some(next(&mut seen).await)
        } else {
            assert!(
                seen.try_recv().is_err(),
                "transient state starts no log RPC"
            )
        }
    }
    match exit {
        "Cancel" => {
            device
                .send_json(&json!({"type":"mode","mode":"mouse"}))
                .await;
            device.expect_close(1000).await;
            if let Some(request) = pending {
                rpc(
                    &input,
                    &request["id"],
                    json!({"success":true,"result":list()}),
                )
                .await;
            }
            tokio::time::sleep(Duration::from_millis(30)).await;
            assert!(
                seen.try_recv().is_err(),
                "cancelled log request must not continue/retry"
            );
        }
        "Disconnect/reconnect" => {
            mode.store(0, Ordering::SeqCst);
            let mut fresh = Device::connect(
                ([127, 0, 0, 1], port).into(),
                Arc::new(Schemas::load().unwrap()),
            )
            .await;
            hello(&mut fresh).await;
            assert_eq!(fresh.recv_msg().await["unheard"], 1);
            next(&mut seen).await;
            if let Some(request) = pending {
                rpc(
                    &input,
                    &request["id"],
                    json!({"success":true,"result":list()}),
                )
                .await;
            }
            fresh.expect_silence(Duration::from_millis(40)).await;
            assert!(
                seen.try_recv().is_err(),
                "late result cannot refresh replacement"
            );
        }
        "Timeout" if transient => {
            device.expect_silence(Duration::from_millis(60)).await;
            assert!(
                seen.try_recv().is_err(),
                "event/PTT has no log wait/timeout"
            );
            if state == "idle/PTT" {
                device.send_json(&json!({"type":"clear"})).await;
                assert_eq!(device.recv_msg().await["state"], "idle");
                assert_eq!(device.recv_msg().await["text"], "");
            }
        }
        "Timeout" => {
            if state == "confirmed delete" {
                let refresh = tokio::time::timeout(Duration::from_secs(6), seen.recv())
                    .await
                    .unwrap()
                    .unwrap();
                assert_eq!(refresh["params"]["args"]["op"], "list");
                rpc(
                    &input,
                    &refresh["id"],
                    json!({"success":true,"result":list()}),
                )
                .await;
                let Some(common::Event::Msg(outcome)) =
                    device.next_event(Duration::from_secs(6)).await
                else {
                    panic!("missing outcome")
                };
                assert_eq!(outcome["text"], "Deletion outcome unknown");
                assert_eq!(device.recv_msg().await["unheard"], 1);
                assert_eq!(device.recv_msg().await["type"], "log_items");
            } else {
                let Some(common::Event::Msg(error)) =
                    device.next_event(Duration::from_secs(6)).await
                else {
                    panic!("missing timeout")
                };
                assert_eq!(error["code"], "internal");
            }
            assert!(
                seen.try_recv().is_err(),
                "timeout does not retry destructive/play RPC"
            );
        }
        "Revoke" => {
            if transient {
                device
                    .send_json(&json!({"type":"log_page","offset":0,"limit":2}))
                    .await;
                pending = Some(next(&mut seen).await);
            }
            let request = pending.unwrap();
            rpc(&input,&request["id"],json!({"success":false,"error_code":"capability_not_granted","error_message":"Capability not granted"})).await;
            assert_eq!(device.recv_msg().await["text"], "Missed list unavailable");
            if state != "idle/PTT" {
                device
                    .send_json(&json!({"type":"ptt_down","stream":31}))
                    .await;
                assert_eq!(device.recv_msg().await["state"], "recording");
            }
            let mut pcm = common::mic(31, 0, false, 4);
            pcm[4..].copy_from_slice(&[1, 2, 3, 4]);
            device.send_binary(pcm).await;
            tokio::time::timeout(WAIT, async {
                while audio.load(Ordering::SeqCst) == 0 {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
            device
                .send_json(&json!({"type":"log_play","log_id":"speech_7"}))
                .await;
            assert_eq!(device.recv_msg().await["text"], "Missed list unavailable");
            event(&input, json!({"unheard":0,"total":1})).await;
            device.expect_silence(Duration::from_millis(30)).await;
            assert!(
                seen.try_recv().is_err(),
                "disabled log makes no RPC and ignores counts"
            );
        }
        "Host EOF" => {}
        _ => unreachable!(),
    }
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
fn list() -> Value {
    json!({"success":true,"items":[{"log_id":"speech_7","created_at":1780000000.0,"summary":"Saved speech","heard":false,"superseded":false,"origin_kind":"explicit"}],"unheard":1.0,"total":1.0,"errors":[]})
}
async fn hello(device: &mut Device) {
    device.send_json(&common::hello(TOKEN, DEVICE)).await;
    assert_eq!(device.recv_msg().await["type"], "welcome");
    assert_eq!(device.recv_msg().await["type"], "target");
    assert_eq!(device.recv_msg().await["type"], "draft");
}
async fn next(rx: &mut mpsc::Receiver<Value>) -> Value {
    tokio::time::timeout(WAIT, rx.recv())
        .await
        .unwrap()
        .unwrap()
}
async fn rpc(input: &Arc<Mutex<tokio::process::ChildStdin>>, id: &Value, result: Value) {
    input
        .lock()
        .await
        .write_all(format!("{}\n", json!({"jsonrpc":"2.0","id":id,"result":result})).as_bytes())
        .await
        .unwrap();
}
async fn event(input: &Arc<Mutex<tokio::process::ChildStdin>>, payload: Value) {
    input.lock().await.write_all(format!("{}\n",json!({"jsonrpc":"2.0","method":"minerva/host_event","params":{"event":"speech_log.changed","payload":payload}})).as_bytes()).await.unwrap();
}
