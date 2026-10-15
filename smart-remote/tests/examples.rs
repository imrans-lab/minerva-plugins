//! Replays `protocol/examples` through the plugin. Every example file must be
//! listed here, so a new example cannot be skipped silently.

mod common;

use std::time::Duration;

use common::{examples_dir, file_names, read_example, Device, Frame, Plugin, TOKEN};
use serde_json::json;
use smart_remote_plugin::audio::{parse_frame, FrameError};
use smart_remote_plugin::message::encode_plugin_value;
use smart_remote_plugin::server::Timers;
use smart_remote_plugin::NOT_IMPLEMENTED;

const QUIET: Duration = Duration::from_millis(300);

/// How many leading frames of each valid example need only batch-3
/// behaviour. Past that point the example needs a chat target, drafts,
/// pickers or choices (batch 4).
const VALID: &[(&str, usize)] = &[
    ("auth_refused.jsonl", 2),
    ("choice.jsonl", 2),
    ("explicit_speech.jsonl", 2),
    ("host_aborts_speech.jsonl", 2),
    ("legacy_turn_speech.jsonl", 2),
    ("speaker_start_failed.jsonl", 2),
    ("picker.jsonl", 2),
    ("ptt_interrupts_speech.jsonl", 2),
    ("ptt_turn.jsonl", 2),
    ("send_refusals.jsonl", 3),
    ("speech_log.jsonl", 2),
];

/// What the plugin answers to the device frames of each invalid example.
/// Frames the plugin would send are checked separately below.
enum Invalid {
    /// The plugin replies with exactly these (see `Event::label`).
    DeviceSide(&'static [&'static str]),
    /// The broken frame is plugin→device; the outbound gate must refuse it.
    PluginSide,
}

const INVALID: &[(&str, Invalid)] = &[
    (
        "log_page_limit.jsonl",
        Invalid::DeviceSide(&["error:bad_message", "close:4002"]),
    ),
    ("chats_without_group.jsonl", Invalid::PluginSide),
    (
        "speaker_early_ack.jsonl",
        Invalid::DeviceSide(&["error:internal"]),
    ),
    (
        "speaker_null_success.jsonl",
        Invalid::DeviceSide(&["error:bad_message", "close:4002"]),
    ),
    (
        "extra_field.jsonl",
        Invalid::DeviceSide(&["error:bad_message", "close:4002"]),
    ),
    ("nul_in_string.jsonl", Invalid::PluginSide),
    ("odd_payload.jsonl", Invalid::PluginSide),
    // protocol.md (push-to-talk step 3): the plugin treats a ptt_up that
    // precedes the EOS frame as EOS, so this one is tolerated, not refused.
    (
        "ptt_up_before_eos.jsonl",
        Invalid::DeviceSide(&["error:internal", "error:internal"]),
    ),
    (
        "reserved_bit.jsonl",
        Invalid::DeviceSide(&["error:internal", "error:bad_message", "close:4002"]),
    ),
    (
        "send_before_hello.jsonl",
        Invalid::DeviceSide(&["error:bad_message", "close:4002"]),
    ),
    (
        "seq_gap.jsonl",
        Invalid::DeviceSide(&["error:internal", "error:audio_gap"]),
    ),
    // A frame on a stream that was never announced is dropped without reply.
    ("unannounced_stream.jsonl", Invalid::DeviceSide(&[])),
];

fn listed<'a, T>(table: &'a [(&str, T)], name: &str) -> &'a T {
    &table
        .iter()
        .find(|(n, _)| *n == name)
        .unwrap_or_else(|| panic!("{name} is not classified in this test"))
        .1
}

#[tokio::test]
async fn valid_examples_replay_up_to_the_batch_boundary() {
    let dir = examples_dir();
    let names = file_names(&dir);
    assert_eq!(names.len(), VALID.len(), "examples changed: {names:?}");
    let plugin = Plugin::start(Timers::default()).await;
    for name in names {
        let prefix = *listed(VALID, &name);
        let frames = read_example(&dir.join(&name));
        let mut device = plugin.device().await;
        let mut saw_welcome = false;
        for frame in &frames[..prefix] {
            match frame {
                Frame::DeviceMsg(msg) => device.send_json(msg).await,
                Frame::PluginMsg(expected) => {
                    let mut expected = expected.clone();
                    if expected["type"] == "welcome" {
                        expected["plugin"] = json!(format!("smart-remote {}", env!("CARGO_PKG_VERSION")));
                    }
                    assert_eq!(device.recv_msg().await, expected, "{name}");
                    saw_welcome |= expected["type"] == "welcome";
                }
                other => panic!("{name}: audio inside the batch-3 prefix: {other:?}"),
            }
        }
        if !saw_welcome {
            // The handshake was refused (auth_refused): the close follows.
            device.expect_close(smart_remote_plugin::CLOSE_AUTH).await;
            continue;
        }
        if !matches!(frames.get(prefix - 1), Some(Frame::PluginMsg(m)) if m["type"] == "target") {
            assert_eq!(
                device.recv_msg().await,
                json!({"type":"target","chat_id":null,"name":"","group":"","group_id":null}),
                "{name}: batch 3 has no chat target"
            );
        }
        // The first device message past the boundary gets the defined refusal.
        let next = frames[prefix..].iter().find_map(|f| match f {
            Frame::DeviceMsg(m) => Some(m.clone()),
            _ => None,
        });
        if let Some(msg) = next {
            device.send_json(&msg).await;
            assert_eq!(
                device.recv_msg().await,
                json!({"type":"error","code":"internal","message":NOT_IMPLEMENTED}),
                "{name}: reply to {msg}"
            );
        }
        device.expect_silence(Duration::from_millis(50)).await;
    }
    plugin.stop().await;
}

#[tokio::test]
async fn invalid_examples_are_refused() {
    let dir = examples_dir().join("invalid");
    let names = file_names(&dir);
    assert_eq!(
        names.len(),
        INVALID.len(),
        "invalid examples changed: {names:?}"
    );
    let plugin = Plugin::start(Timers::default()).await;
    for name in names {
        let frames = read_example(&dir.join(&name));
        match listed(INVALID, &name) {
            Invalid::DeviceSide(expected) => {
                let labels = replay_device_frames(&plugin, &frames).await;
                assert_eq!(labels, *expected, "{name}");
            }
            Invalid::PluginSide => {
                let refused = frames.iter().any(|frame| match frame {
                    Frame::PluginMsg(msg) => encode_plugin_value(msg, &plugin.schemas).is_err(),
                    Frame::PluginAudio(bytes) => {
                        matches!(parse_frame(bytes), Err(FrameError::OddPayload(_)))
                    }
                    _ => false,
                });
                assert!(refused, "{name}: the outbound gate accepts every frame");
            }
        }
    }
    plugin.stop().await;
}

/// Sends the device frames of an example and returns the plugin's replies
/// after the handshake.
async fn replay_device_frames(plugin: &Plugin, frames: &[Frame]) -> Vec<String> {
    let mut device: Device = plugin.device().await;
    for frame in frames {
        match frame {
            Frame::DeviceMsg(msg) if msg["type"] == "hello" => {
                assert_eq!(msg["token"], TOKEN);
                device.handshake().await;
            }
            Frame::DeviceMsg(msg) => device.send_json(msg).await,
            Frame::DeviceAudio(bytes) => device.send_binary(bytes.clone()).await,
            Frame::PluginMsg(_) | Frame::PluginAudio(_) => {}
        }
    }
    device.drain_labels(QUIET).await
}
