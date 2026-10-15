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
    let drain = tokio::spawn(async move {
        let mut captured = String::new();
        while let Ok(Some(line)) = logs.next_line().await {
            captured.push_str(&line);
            captured.push('\n');
        }
        captured
    });
    let mut output = BufReader::new(child.stdout.take().unwrap()).lines();
    let (requests, mut seen) = mpsc::channel(64);
    let hold_end = Arc::new(AtomicBool::new(false));
    let drop_begin = Arc::new(AtomicBool::new(false));
    let refuse_start = Arc::new(AtomicBool::new(false));
    let refusal = refuse_start.clone();
    let (hold, drop_request) = (hold_end.clone(), drop_begin.clone());
    let writer = input.clone();
    let host = tokio::spawn(async move {
        let mut offline = false;
        while let Some(line) = output.next_line().await.unwrap() {
            let msg: Value = serde_json::from_str(&line).unwrap();
            if msg["method"] != "minerva/capability" {
                continue;
            }
            let args = &msg["params"]["args"];
            if args["op"] == "availability" {
                offline = args["available"] == false;
            }
            if args["op"] == "output_complete" {
                assert!(!offline, "completion after availability:false");
                assert_ne!(
                    args["stream_id"], 92,
                    "host-cancelled stream completed twice"
                );
                assert_ne!(args["stream_id"], 94, "host error already retired the stream");
                assert_ne!(args["stream_id"], 95, "disconnect retired the stream");
            }
            if args["op"] == "register" && refusal.load(Ordering::SeqCst) {
                writer.lock().await.write_all(format!("{}\n", json!({"jsonrpc":"2.0","id":msg["id"],"result":{"success":false,"error_code":"endpoint_refused","error_message":"Fixture endpoint registration refused","detail":{"reason":"fixture refusal detail"}}})).as_bytes()).await.unwrap();
                requests.send(msg).await.unwrap();
                continue;
            }
            if msg["params"]["capability"] == "host.audio"
                && ((args["op"] == "input_end" && hold.load(Ordering::SeqCst))
                    || (args["op"] == "input_begin" && drop_request.swap(false, Ordering::SeqCst)))
            {
                requests.send(msg).await.unwrap();
                continue;
            }
            let result = match msg["params"]["capability"].as_str().unwrap() {
                "host.speech_log" => {
                    json!({"success":true,"items":[],"unheard":0,"total":0,"errors":[]})
                }
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
    device.send_json(&common::hello(TOKEN, DEVICE)).await;
    assert_eq!(device.recv_msg().await["type"], "welcome");
    assert_eq!(device.recv_msg().await["chat_id"], "c1");
    assert_eq!(device.recv_msg().await["type"], "draft");
    assert_eq!(device.recv_msg().await["type"], "missed");
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
    // A focus switch after transcription retains the bound draft and visibly refuses Send.
    event(
        &input,
        "chat.active_changed",
        json!({"chat_id":"c2","name":"Other","group":"","group_id":""}),
    )
    .await;
    assert_eq!(device.recv_msg().await["chat_id"], "c2");
    device.send_json(&json!({"type":"send"})).await;
    assert_eq!(device.recv_msg().await["code"], "target_changed");
    event(
        &input,
        "chat.active_changed",
        json!({"chat_id":"c1","name":"Chat","group":"","group_id":""}),
    )
    .await;
    assert_eq!(device.recv_msg().await["chat_id"], "c1");
    // Replacement while the old socket is still live serializes endpoint lifecycle.
    let mut replacement = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    replacement.send_json(&common::hello(TOKEN, DEVICE)).await;
    assert_eq!(replacement.recv_msg().await["type"], "welcome");
    assert_eq!(replacement.recv_msg().await["chat_id"], "c1");
    assert_eq!(replacement.recv_msg().await["text"], "Hello");
    assert_eq!(replacement.recv_msg().await["type"], "missed");
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
    assert_eq!(speak, json!({"type":"speak","stream":1,"chat_id":"c1"}));
    assert_eq!(speak["chat_id"], "c1");
    let stream = speak["stream"].as_u64().unwrap();
    device
        .send_json(&json!({"type":"speak_done","stream_id":stream,"ok":true,"last_seq":0}))
        .await;
    assert_eq!(device.recv_msg().await["code"], "tts_failed");
    use base64::{engine::general_purpose::STANDARD, Engine};
    let source: Vec<u8> = (0..36000)
        .flat_map(|n| ((n % 100) as i16).to_le_bytes())
        .collect();
    for (sequence, chunk) in source.chunks(6400).enumerate() {
        event(&input,"voice.audio",json!({"op":"chunk","device_id":endpoint,"stream_id":91,"sequence":sequence,"pcm":STANDARD.encode(chunk)})).await;
    }
    event(&input,"voice.audio",json!({"op":"end","device_id":endpoint,"stream_id":91,"sequence":source.chunks(6400).len()})).await;
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
        assert!(count as f64 / 32000.0 - started.elapsed().as_secs_f64() <= 1.0);
        if header.eos {
            break;
        }
        seq += 1;
    }
    assert_eq!(count, 48000);
    assert!(
        (1.425..=1.575).contains(&started.elapsed().as_secs_f64()),
        "pacing elapsed {:?}",
        started.elapsed()
    );
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
    assert!(abort["message"].as_str().is_some_and(|s| !s.is_empty()));
    // The host already cancelled stream92; it must not get a second terminal report.
    device.send_json(&json!({"type":"speak_done","stream_id":abort["stream_id"],"ok":false,"error":"cancelled"})).await;
    while let Ok(request) = seen.try_recv() {
        assert_ne!(request["params"]["args"]["stream_id"], 92);
    }
    // Device barge-in uses empty EOS, whereas a synthesis failure uses host abort.
    event(&input,"voice.audio",json!({"op":"begin","device_id":endpoint,"stream_id":93,"format":"pcm_s16le","sample_rate":16000,"channels":1,"volume":1.0,"origin":{"kind":"explicit"}})).await;
    let speaking = device.recv_msg().await;
    device
        .send_json(&json!({"type":"ptt_down","stream":10}))
        .await;
    let common::Event::Binary(eos) = device.recv().await else {
        panic!("barge EOS")
    };
    assert_eq!(eos.len(), 4);
    let header = smart_remote_plugin::audio::parse_frame(&eos).unwrap().0;
    assert!(header.eos);
    assert_eq!(header.stream as u64, speaking["stream"].as_u64().unwrap());
    assert_eq!(device.recv_msg().await["state"], "recording");
    next_request(&mut seen, "input_begin").await;
    device.send_json(&json!({"type":"clear"})).await;
    assert_eq!(device.recv_msg().await["state"], "idle");
    assert_eq!(device.recv_msg().await["text"], "");
    next_request(&mut seen, "clear").await;
    event(&input,"voice.audio",json!({"op":"begin","device_id":endpoint,"stream_id":94,"format":"pcm_s16le","sample_rate":16000,"channels":1,"volume":1.0,"origin":{"kind":"explicit"}})).await;
    device.recv_msg().await;
    event(
        &input,
        "voice.audio",
        json!({"op":"error","device_id":endpoint,"stream_id":94}),
    )
    .await;
    assert_eq!(device.recv_msg().await["code"], "tts_failed");
    assert_eq!(device.recv_msg().await["reason"], "tts_failed");
    // A real outstanding STT request outlives the old five-second timeout.
    hold_end.store(true, Ordering::SeqCst);
    device
        .send_json(&json!({"type":"ptt_down","stream":11}))
        .await;
    assert_eq!(device.recv_msg().await["state"], "recording");
    device.send_binary(common::mic(11, 0, true, 0)).await;
    assert_eq!(device.recv_msg().await["state"], "transcribing");
    let outstanding = next_request(&mut seen, "input_end").await;
    tokio::time::sleep(std::time::Duration::from_millis(5200)).await;
    device
        .expect_silence(std::time::Duration::from_millis(60))
        .await;
    event(&input,"voice.audio",json!({"op":"begin","device_id":endpoint,"stream_id":95,"format":"pcm_s16le","sample_rate":16000,"channels":1,"volume":1.0,"origin":{"kind":"explicit"}})).await;
    assert_eq!(device.recv_msg().await["type"], "speak");
    // Reconnect while STT is outstanding; old cancellation completes before new registration.
    let mut wake = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    wake.send_json(&common::hello(TOKEN, DEVICE)).await;
    assert_eq!(wake.recv_msg().await["type"], "welcome");
    assert_eq!(wake.recv_msg().await["chat_id"], "c1");
    assert_eq!(wake.recv_msg().await["type"], "draft");
    assert_eq!(wake.recv_msg().await["type"], "missed");
    next_request(&mut seen, "input_cancel").await;
    next_request(&mut seen, "register").await;
    assert_eq!(
        next_request(&mut seen, "availability").await["params"]["args"]["available"],
        true
    );
    device = wake;
    input.lock().await.write_all(format!("{}\n",json!({"jsonrpc":"2.0","id":outstanding["id"],"result":{"success":true,"result":{}}})).as_bytes()).await.unwrap();
    // Clear also reaches a terminal state while another STT request is outstanding.
    device
        .send_json(&json!({"type":"ptt_down","stream":13}))
        .await;
    assert_eq!(device.recv_msg().await["state"], "recording");
    device.send_binary(common::mic(13, 0, true, 0)).await;
    assert_eq!(device.recv_msg().await["state"], "transcribing");
    next_request(&mut seen, "input_end").await;
    device.send_json(&json!({"type":"clear"})).await;
    assert_eq!(device.recv_msg().await["state"], "idle");
    assert_eq!(device.recv_msg().await["text"], "");
    next_request(&mut seen, "clear").await;
    hold_end.store(false, Ordering::SeqCst);
    // A control timeout is surfaced and releases capture; a late reply is not a new session.
    drop_begin.store(true, Ordering::SeqCst);
    device
        .send_json(&json!({"type":"ptt_down","stream":12}))
        .await;
    assert_eq!(device.recv_msg().await["state"], "recording");
    next_request(&mut seen, "input_begin").await;
    let Some(common::Event::Msg(timeout)) =
        device.next_event(std::time::Duration::from_secs(6)).await
    else {
        panic!("missing timeout")
    };
    assert_eq!(timeout["state"], "error");
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
    reconnect.send_json(&common::hello(TOKEN, DEVICE)).await;
    assert_eq!(reconnect.recv_msg().await["type"], "welcome");
    assert_eq!(reconnect.recv_msg().await["chat_id"], "c1");
    assert_eq!(reconnect.recv_msg().await["type"], "draft");
    assert_eq!(reconnect.recv_msg().await["type"], "missed");
    next_request(&mut seen, "register").await;
    assert_eq!(
        next_request(&mut seen, "availability").await["params"]["args"]["available"],
        true
    );
    drop(reconnect);
    assert_eq!(
        next_request(&mut seen, "availability").await["params"]["args"]["available"],
        false
    );
    next_request(&mut seen, "unregister").await;
    refuse_start.store(true, Ordering::SeqCst);
    let mut refused = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    refused.send_json(&common::hello(TOKEN, DEVICE)).await;
    assert_eq!(refused.recv_msg().await["type"], "welcome");
    assert!(refused.recv_msg().await["message"]
        .as_str()
        .unwrap()
        .contains("Fixture endpoint registration refused"));
    next_request(&mut seen, "register").await;
    host.abort(); // Releases its writer clone; the real host EOF shuts down the plugin.
    let _ = host.await;
    drop(input);
    assert!(tokio::time::timeout(WAIT, child.wait())
        .await
        .unwrap()
        .unwrap()
        .success());
    let diagnostics = drain.await.unwrap();
    assert!(diagnostics.contains("bridge startup failed: Fixture endpoint registration refused"));
    assert!(
        !diagnostics.contains(TOKEN),
        "pairing token stays out of stderr"
    );
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
