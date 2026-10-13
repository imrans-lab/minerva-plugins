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
    // Real 24k PCM becomes paced 16k speaker frames; LAN delivery is not a drain ACK.
    event(&input, "voice.audio", json!({"op":"begin","device_id":endpoint,"stream_id":91,"format":"pcm_s16le","sample_rate":24000,"channels":1,"volume":1.0,"origin":{"kind":"turn","chat_id":"c1","send_id":71}})).await;
    let speak = device.recv_msg().await;
    assert_eq!(speak["origin"], "turn");
    assert_eq!(speak["chat_id"], "c1");
    let stream = speak["stream"].as_u64().unwrap();
    device
        .send_json(&json!({"type":"speak_done","stream_id":stream,"ok":true,"last_seq":0}))
        .await;
    assert_eq!(device.recv_msg().await["code"], "tts_failed");
    use base64::{engine::general_purpose::STANDARD, Engine};
    let source: Vec<u8> = (0..2400)
        .flat_map(|n| ((n % 100) as i16).to_le_bytes())
        .collect();
    event(&input,"voice.audio",json!({"op":"chunk","device_id":endpoint,"stream_id":91,"sequence":0,"pcm":STANDARD.encode(&source)})).await;
    event(
        &input,
        "voice.audio",
        json!({"op":"end","device_id":endpoint,"stream_id":91,"sequence":1}),
    )
    .await;
    let started = tokio::time::Instant::now();
    let (mut count, mut seq) = (0, 0);
    loop {
        let common::Event::Binary(frame) = device.recv().await else {
            panic!("expected speaker PCM")
        };
        let header = smart_remote_plugin::audio::parse_frame(&frame).unwrap().0;
        assert_eq!(header.stream as u64, stream);
        assert_eq!(header.seq, seq);
        assert!(frame.len() <= 644);
        count += frame.len() - 4;
        if header.eos {
            break;
        }
        seq += 1;
    }
    assert_eq!(count, 3200);
    assert!(started.elapsed() >= std::time::Duration::from_millis(60));
    assert!(seen.try_recv().is_err(), "no guessed successful completion");
    device
        .send_json(&json!({"type":"speak_done","stream_id":stream,"ok":true,"last_seq":seq}))
        .await;
    let ack = next_request(&mut seen, "output_complete").await;
    assert_eq!(ack["params"]["args"]["stream_id"], 91);
    assert_eq!(ack["params"]["args"]["success"], true);
    // Explicit output has no invented chat origin; a host cancel flushes that stream.
    event(&input,"voice.audio",json!({"op":"begin","device_id":endpoint,"stream_id":92,"format":"pcm_s16le","sample_rate":16000,"channels":1,"volume":1.0,"origin":{"kind":"explicit"}})).await;
    let explicit = device.recv_msg().await;
    assert_eq!(explicit["origin"], "explicit");
    assert!(explicit.get("chat_id").is_none());
    event(
        &input,
        "voice.audio",
        json!({"op":"cancel","device_id":endpoint,"stream_id":92}),
    )
    .await;
    assert_eq!(device.recv_msg().await["code"], "tts_failed");
    let abort = device.recv_msg().await;
    assert_eq!(abort["code"], "speak_aborted");
    assert_eq!(abort["reason"], "host_cancel");
    assert_eq!(
        next_request(&mut seen, "output_complete").await["params"]["args"]["success"],
        false
    );
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
