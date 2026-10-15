//! Two single happy paths, each across the real plugin and exact Minerva sibling.
mod common;
use common::{mic, Device, DEVICE, TOKEN};
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
    let ready = data.path().join("device-ready");
    let mut child = Command::new(std::env::var("SMART_REMOTE_GODOT").unwrap_or("godot".into()))
        .args([
            "--headless",
            "--path",
            &project,
            "--script",
            "res://test/fixtures/smart_remote_setup.gd",
        ])
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
    std::fs::write(ready, "ready").unwrap();
    if mode == "ptt" {
        device
            .send_json(&json!({"type":"ptt_down","stream":1}))
            .await;
        device.send_binary(mic(1, 0, false, 640)).await;
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
