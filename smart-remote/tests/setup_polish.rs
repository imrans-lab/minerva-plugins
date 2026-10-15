//! Two single happy paths, each across the real plugin and exact Minerva sibling.
mod common;
use common::{mic, Device, Event, DEVICE, TOKEN};
use serde_json::json;
use smart_remote_plugin::{schema::Schemas, store::TokenStore};
use std::{process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    process::Command,
};

#[tokio::test]
#[ignore = "requires isolated MINERVA_TEST_PROJECT with matching native extensions"]
async fn registered_remote_appears_in_audio_and_video_preferences() {
    combined("audio").await;
}

#[tokio::test]
#[ignore = "requires isolated MINERVA_TEST_PROJECT with matching native extensions"]
async fn ptt_without_a_chat_creates_one_chat_and_captures_pcm() {
    combined("ptt").await;
}

#[tokio::test]
#[ignore = "requires isolated MINERVA_TEST_PROJECT with matching native extensions"]
async fn notification_follows_selected_speaker_after_speech() {
    combined("notification").await;
}

async fn combined(mode: &str) {
    let project = std::env::var("MINERVA_TEST_PROJECT").expect("isolated Minerva project");
    let data = tempfile::tempdir().unwrap();
    TokenStore::open(data.path())
        .unwrap()
        .pair(DEVICE, TOKEN, "Fixture", 0)
        .unwrap();
    let port = std::net::TcpListener::bind(("127.0.0.1", 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let profile = data.path().join("profile");
    let user = profile.join("godot/app_userdata/Minerva");
    std::fs::create_dir_all(&user).unwrap();
    if mode == "audio" {
        std::fs::write(user.join("config_file.cfg"), "[Voice]\ninput_device=\"plugin:smart_remote:remote_a4cf12b03e5d\"\noutput_device=\"plugin:smart_remote:remote_a4cf12b03e5d\"\n[AudioSettings]\nSelectedMic=\"Default\"\n").unwrap();
    }
    let ready = data.path().join("device-ready");
    let mut child = Command::new(std::env::var("SMART_REMOTE_GODOT").unwrap_or("godot".into()))
        .args([
            "--headless",
            "--path",
            &project,
            "--script",
            "res://test/fixtures/smart_remote_setup.gd",
        ])
        .env("XDG_DATA_HOME", &profile)
        .env("XDG_CONFIG_HOME", data.path().join("config"))
        .env("SMART_REMOTE_SETUP_MODE", mode)
        .env("SMART_REMOTE_SETUP_DATA", data.path())
        .env("SMART_REMOTE_SETUP_PORT", port.to_string())
        .env("SMART_REMOTE_SETUP_READY", &ready)
        .env("SMART_REMOTE_PLUGIN_ROOT", env!("CARGO_MANIFEST_DIR"))
        .env(
            "SMART_REMOTE_PLUGIN_BIN",
            env!("CARGO_BIN_EXE_smart-remote-plugin"),
        )
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let mut stderr = child.stderr.take().unwrap();
    let errors = tokio::spawn(async move {
        let mut text = String::new();
        stderr.read_to_string(&mut text).await.unwrap();
        text
    });
    let mut output = String::new();
    tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(line) = lines.next_line().await.unwrap() {
            output.push_str(&line);
            output.push('\n');
            if line == "SETUP_HOST_READY" {
                return;
            }
        }
        panic!("host did not start: {output}");
    })
    .await
    .unwrap();
    let mut device = Device::connect(
        ([127, 0, 0, 1], port).into(),
        Arc::new(Schemas::load().unwrap()),
    )
    .await;
    device.handshake().await;
    if mode == "notification" {
        assert_eq!(device.recv_msg().await, json!({"type":"draft","text":""}));
        assert_eq!(
            device.recv_msg().await,
            json!({"type":"missed","unheard":0})
        );
    }
    std::fs::write(&ready, "ready").unwrap();
    if mode == "ptt" {
        device
            .send_json(&json!({"type":"ptt_down","stream":1}))
            .await;
        device.send_binary(mic(1, 0, false, 640)).await;
    }
    if mode == "notification" {
        let speech = device.recv_msg().await;
        assert_eq!(speech["type"], "speak");
        assert_eq!(speech["origin"], "explicit");
        let speech_stream = speech["stream"].as_u64().unwrap();
        let Event::Binary(frame) = device.recv().await else {
            panic!("speech PCM");
        };
        let header = smart_remote_plugin::audio::parse_frame(&frame).unwrap().0;
        assert!(header.eos);
        let queued = data.path().join("device-ready.queued");
        tokio::time::timeout(Duration::from_secs(5), async {
            while !queued.exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        device.expect_silence(Duration::from_millis(200)).await;
        device.send_json(&json!({"type":"speak_done","stream_id":speech_stream,"ok":true,"last_seq":header.seq})).await;
        let tone = device.recv_msg().await;
        assert_eq!(tone["type"], "speak");
        assert_eq!(tone["origin"], "explicit");
        let stream = tone["stream"].as_u64().unwrap();
        assert_ne!(stream, speech_stream);
        let mut pcm = Vec::new();
        let mut sequence = 0;
        loop {
            let frame = match device.recv().await {
                Event::Binary(frame) => frame,
                Event::Msg(state) if state == json!({"type":"missed","unheard":0}) => continue,
                other => {
                    panic!("expected notification PCM or unchanged log count, received {other:?}")
                }
            };
            let (header, bytes) = smart_remote_plugin::audio::parse_frame(&frame).unwrap();
            assert_eq!(header.stream as u64, stream);
            assert_eq!(header.seq, sequence);
            pcm.extend_from_slice(bytes);
            if header.eos {
                break;
            }
            sequence += 1;
        }
        let wav =
            std::fs::read(std::path::Path::new(&project).join("assets/Audio/notification-pcm.wav"))
                .unwrap();
        let mut offset = 12;
        let mut expected = &[][..];
        while offset + 8 <= wav.len() {
            let size = u32::from_le_bytes(wav[offset + 4..offset + 8].try_into().unwrap()) as usize;
            if &wav[offset..offset + 4] == b"data" {
                expected = &wav[offset + 8..offset + 8 + size];
                break;
            }
            offset += 8 + size + size % 2;
        }
        assert!(!expected.is_empty());
        assert_eq!(
            pcm, expected,
            "wire bytes must match the independently decoded 16 kHz mono PCM tone"
        );
        device
            .send_json(
                &json!({"type":"speak_done","stream_id":stream,"ok":true,"last_seq":sequence}),
            )
            .await;
    }
    let status = tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(line) = lines.next_line().await.unwrap() {
            output.push_str(&line);
            output.push('\n');
        }
        child.wait().await.unwrap()
    })
    .await
    .unwrap();
    let stderr = errors.await.unwrap();
    assert!(
        status.success() && output.contains("SETUP_PASS") && !stderr.contains("SCRIPT ERROR"),
        "{output}\n{stderr}"
    );
}
