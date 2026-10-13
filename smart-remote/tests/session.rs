//! protocol.md session rules over a real socket, driven by a simulated device.

mod common;

use std::time::Duration;

use common::{hello, mic, Device, Event, Plugin, DEVICE, TOKEN, WAIT};
use serde_json::json;
use smart_remote_plugin::admission::Limits;
use smart_remote_plugin::server::Timers;
use smart_remote_plugin::store::TokenStore;
use smart_remote_plugin::{
    AUTH_MESSAGE, CLOSE_AUTH, CLOSE_GOING_AWAY, CLOSE_NORMAL, CLOSE_PROTOCOL, CLOSE_PROTO_VERSION,
    CLOSE_REPLACED, NOT_IMPLEMENTED,
};
use tokio::time::Instant;

const QUIET: Duration = Duration::from_millis(300);

fn default_timers() -> Timers {
    Timers::default()
}

async fn expect_error(device: &mut Device, code: &str) -> String {
    let msg = device.recv_msg().await;
    assert_eq!(msg["type"], "error", "{msg}");
    assert_eq!(msg["code"], code, "{msg}");
    msg["message"].as_str().unwrap().to_owned()
}

async fn expect_bad_message_close(device: &mut Device) {
    expect_error(device, "bad_message").await;
    device.expect_close(CLOSE_PROTOCOL).await;
}

#[tokio::test]
async fn hello_gets_welcome_then_null_target_and_confirms_the_pairing() {
    let plugin = Plugin::start(default_timers()).await;
    assert!(!plugin.store.record(DEVICE).unwrap().confirmed);
    let mut device = plugin.session().await;
    device.expect_silence(QUIET).await;
    // Confirmation is persisted off the session task; poll the file.
    let path = plugin.store.path().parent().unwrap().to_path_buf();
    let deadline = Instant::now() + WAIT;
    loop {
        if TokenStore::open(&path)
            .unwrap()
            .record(DEVICE)
            .unwrap()
            .confirmed
        {
            break;
        }
        assert!(Instant::now() < deadline, "pairing never confirmed on disk");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    plugin.stop().await;
}

#[tokio::test]
async fn no_hello_within_the_hello_timer_closes_4002() {
    let timers = Timers {
        hello: Duration::from_millis(300),
        ..Timers::default()
    };
    let plugin = Plugin::start(timers).await;
    let started = Instant::now();
    let mut device = plugin.device().await;
    expect_bad_message_close(&mut device).await;
    let waited = started.elapsed();
    assert!(
        waited >= Duration::from_millis(250),
        "closed after {waited:?}"
    );
    assert!(waited < Duration::from_secs(2), "closed after {waited:?}");
}

#[tokio::test]
async fn anything_but_hello_first_closes_4002() {
    let plugin = Plugin::start(default_timers()).await;
    let mut device = plugin.device().await;
    device.send_json(&json!({"type":"send"})).await;
    expect_bad_message_close(&mut device).await;

    let mut device = plugin.device().await;
    device.send_binary(mic(1, 0, false, 2)).await;
    expect_bad_message_close(&mut device).await;

    let mut device = plugin.device().await;
    device.send_text("not json").await;
    expect_bad_message_close(&mut device).await;
}

#[tokio::test]
async fn unknown_device_or_wrong_token_is_auth_then_4001() {
    let plugin = Plugin::start(default_timers()).await;
    for (token, device_id) in [("wrong-token-0123456", DEVICE), (TOKEN, "0123456789ab")] {
        let mut device = plugin.device().await;
        device.send_json(&hello(token, device_id)).await;
        assert_eq!(expect_error(&mut device, "auth").await, AUTH_MESSAGE);
        device.expect_close(CLOSE_AUTH).await;
    }
    assert!(!plugin.store.record(DEVICE).unwrap().confirmed);
}

#[tokio::test]
async fn unsupported_proto_is_proto_version_then_4003() {
    let plugin = Plugin::start(default_timers()).await;
    let mut device = plugin.device().await;
    let mut msg = hello(TOKEN, DEVICE);
    msg["proto"] = json!(2);
    device.send_json(&msg).await;
    expect_error(&mut device, "proto_version").await;
    device.expect_close(CLOSE_PROTO_VERSION).await;
}

#[tokio::test]
async fn a_non_integer_proto_is_bad_message_then_4002() {
    let plugin = Plugin::start(default_timers()).await;
    for proto in [json!("2"), json!(2.0), json!(1.0)] {
        let mut device = plugin.device().await;
        let mut msg = hello(TOKEN, DEVICE);
        msg["proto"] = proto.clone();
        device.send_json(&msg).await;
        assert_eq!(
            expect_error(&mut device, "bad_message").await,
            "hello.proto must be an integer",
            "proto {proto}"
        );
        device.expect_close(CLOSE_PROTOCOL).await;
    }
}

/// Opens connections that never send hello until the plugin refuses one.
async fn unauthenticated_until_refused(plugin: &Plugin, max: usize) -> Vec<Device> {
    let mut held = Vec::new();
    for _ in 0..max {
        held.push(plugin.device().await);
    }
    let refused = Device::try_connect(plugin.addr, plugin.schemas.clone()).await;
    assert!(refused.is_err(), "connection {} was accepted", max + 1);
    held
}

#[tokio::test]
async fn unauthenticated_connections_are_capped_per_ip_and_released_on_hello() {
    let limits = Limits {
        unauthenticated: 16,
        unauthenticated_per_ip: 2,
    };
    let plugin = Plugin::start_with(default_timers(), limits).await;
    let mut held = unauthenticated_until_refused(&plugin, 2).await;
    // Authenticating releases the slot without closing the connection.
    held[0].handshake().await;
    let mut admitted = plugin.device().await;
    // Refused connections do not hold a slot either.
    admitted
        .send_json(&hello("wrong-token-0123456", "0123456789ab"))
        .await;
    expect_error(&mut admitted, "auth").await;
    admitted.expect_close(CLOSE_AUTH).await;
    drop(admitted);
    let _again = plugin.device().await;
    held[0].expect_silence(QUIET).await;
}

#[tokio::test]
async fn unauthenticated_connections_are_capped_globally() {
    let limits = Limits {
        unauthenticated: 3,
        unauthenticated_per_ip: 16,
    };
    let plugin = Plugin::start_with(default_timers(), limits).await;
    let held = unauthenticated_until_refused(&plugin, 3).await;
    drop(held);
    // Closed connections release their slots once the plugin notices.
    let deadline = Instant::now() + WAIT;
    while Device::try_connect(plugin.addr, plugin.schemas.clone())
        .await
        .is_err()
    {
        assert!(Instant::now() < deadline, "slots never released");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn a_newer_hello_from_the_same_device_closes_the_older_with_4004() {
    let plugin = Plugin::start(default_timers()).await;
    let mut older = plugin.session().await;
    let mut newer = plugin.session().await;
    older.expect_close(CLOSE_REPLACED).await;
    newer.send_json(&json!({"type":"send"})).await;
    assert_eq!(expect_error(&mut newer, "internal").await, NOT_IMPLEMENTED);
    // The replaced session ending must not unregister the newer one.
    let mut newest = plugin.session().await;
    newer.expect_close(CLOSE_REPLACED).await;
    newest.expect_silence(QUIET).await;
}

#[tokio::test]
async fn mode_mouse_closes_1000_and_mode_voice_is_silent() {
    let plugin = Plugin::start(default_timers()).await;
    let mut device = plugin.session().await;
    device
        .send_json(&json!({"type":"mode","mode":"voice"}))
        .await;
    device.expect_silence(QUIET).await;
    device
        .send_json(&json!({"type":"mode","mode":"mouse"}))
        .await;
    device.expect_close(CLOSE_NORMAL).await;
}

#[tokio::test]
async fn later_batch_messages_get_a_defined_refusal_and_the_session_continues() {
    let plugin = Plugin::start(default_timers()).await;
    let mut device = plugin.session().await;
    for msg in [
        json!({"type":"ptt_down","stream":7}),
        json!({"type":"ptt_up","stream":7}),
        json!({"type":"clear"}),
        json!({"type":"send"}),
        json!({"type":"picker_open"}),
        json!({"type":"picker_list","group_id":"grp-1"}),
        json!({"type":"target_set","chat_id":"chat-22"}),
        json!({"type":"choice_pick","choice_id":"q-91","index":1}),
    ] {
        device.send_json(&msg).await;
        assert_eq!(
            device.recv_msg().await,
            json!({"type":"error","code":"internal","message":NOT_IMPLEMENTED}),
            "reply to {msg}"
        );
    }
    device.expect_silence(QUIET).await;
}

#[tokio::test]
async fn contract_and_schema_violations_after_hello_close_4002() {
    let plugin = Plugin::start(default_timers()).await;
    let deep = r#"{"type":"picker_list","group_id":"g","x":[[[[[[[[1]]]]]]]]}"#;
    let oversize = format!(
        r#"{{"type":"picker_list","group_id":"{}"}}"#,
        "g".repeat(4096)
    );
    let cases: Vec<(&str, String)> = vec![
        (
            "escaped NUL in a schema-valid string",
            r#"{"type":"picker_list","group_id":"a\u0000b"}"#.into(),
        ),
        (
            "escaped NUL in a property name",
            r#"{"type":"send","\u0000":1}"#.into(),
        ),
        ("nesting deeper than 8", deep.into()),
        ("text frame over 4 KiB", oversize),
        ("not JSON", "{".into()),
        ("unknown type", r#"{"type":"teleport"}"#.into()),
        ("extra field", r#"{"type":"send","draft":"x"}"#.into()),
        ("repeated hello", hello(TOKEN, DEVICE).to_string()),
        ("non-object", "[1]".into()),
    ];
    for (what, text) in cases {
        let mut device = plugin.session().await;
        device.send_text(&text).await;
        let msg = device.recv_msg().await;
        assert_eq!(
            (msg["type"].as_str(), msg["code"].as_str()),
            (Some("error"), Some("bad_message")),
            "{what}: {msg}"
        );
        device.expect_close(CLOSE_PROTOCOL).await;
    }
}

#[tokio::test]
async fn nul_in_hello_is_caught_although_the_schema_allows_the_field() {
    let plugin = Plugin::start(default_timers()).await;
    let mut device = plugin.device().await;
    let text = hello(TOKEN, DEVICE)
        .to_string()
        .replace("0.1.0", r"0.1\u0000");
    device.send_text(&text).await;
    expect_bad_message_close(&mut device).await;
}

#[tokio::test]
async fn malformed_audio_frames_close_4002() {
    let plugin = Plugin::start(default_timers()).await;
    let mut reserved = mic(1, 0, false, 2);
    reserved[0] |= 0x40;
    let mut speaker = mic(1, 0, false, 2);
    speaker[0] = 0x02;
    let mut unknown_kind = mic(1, 0, false, 2);
    unknown_kind[0] = 0x05;
    for frame in [
        reserved,
        speaker,
        unknown_kind,
        mic(1, 0, false, 641),
        mic(1, 0, false, 4098),
        vec![0x01, 1, 0],
    ] {
        let mut device = plugin.session().await;
        device
            .send_json(&json!({"type":"ptt_down","stream":1}))
            .await;
        expect_error(&mut device, "internal").await;
        device.send_binary(frame).await;
        expect_bad_message_close(&mut device).await;
    }
}

#[tokio::test]
async fn mic_frames_are_sequence_checked_and_dropped() {
    let plugin = Plugin::start(default_timers()).await;
    let mut device = plugin.session().await;
    // Before any ptt_down there is no current stream: dropped silently.
    device.send_binary(mic(7, 0, false, 640)).await;
    device.expect_silence(QUIET).await;

    device
        .send_json(&json!({"type":"ptt_down","stream":7}))
        .await;
    expect_error(&mut device, "internal").await;
    device.send_binary(mic(7, 0, false, 4096)).await;
    device.send_binary(mic(7, 1, false, 3200)).await;
    device.send_binary(mic(9, 0, false, 640)).await; // not the current stream
    device.expect_silence(QUIET).await;
    device.send_binary(mic(7, 3, false, 640)).await;
    expect_error(&mut device, "audio_gap").await;
    // The stream continues from the frame after the gap.
    device.send_binary(mic(7, 4, true, 0)).await;
    device.expect_silence(QUIET).await;
    // After EOS the stream is over.
    device.send_binary(mic(7, 9, false, 640)).await;
    device.expect_silence(QUIET).await;
}

#[tokio::test]
async fn the_plugin_pings_on_its_interval_and_a_responsive_device_stays_up() {
    let timers = Timers {
        ping_every: Duration::from_millis(100),
        dead_after: Duration::from_millis(400),
        ..Timers::default()
    };
    let plugin = Plugin::start(timers).await;
    let mut device = plugin.session().await;
    let started = Instant::now();
    let mut pings = 0;
    // Reading answers each ping with a pong, so the link stays alive well
    // past the dead-link timer.
    // About 12 pings are due; half is enough to show the cadence without
    // failing on a loaded machine.
    while started.elapsed() < Duration::from_millis(1200) {
        match device.next_event(Duration::from_millis(350)).await {
            Some(Event::Ping) => pings += 1,
            None => panic!("no ping within 350 ms"),
            Some(other) => panic!("unexpected {other:?}"),
        }
    }
    assert!(pings >= 6, "only {pings} pings in 1.2 s");
    device.send_json(&json!({"type":"send"})).await;
    expect_error(&mut device, "internal").await;
}

#[tokio::test]
async fn a_silent_device_is_dropped_after_the_dead_link_timer() {
    let timers = Timers {
        ping_every: Duration::from_millis(100),
        dead_after: Duration::from_millis(400),
        ..Timers::default()
    };
    let plugin = Plugin::start(timers).await;
    let mut device = plugin.session().await;
    let silent_since = Instant::now();
    // Not reading means not answering pings: the device is silent.
    tokio::time::sleep(Duration::from_millis(700)).await;
    // Only the pings buffered while silent may arrive before the drop.
    let reading_until = Instant::now() + Duration::from_secs(1);
    loop {
        let left = reading_until.saturating_duration_since(Instant::now());
        match device.next_event(left).await {
            Some(Event::Ping) => continue,
            Some(Event::Ended) => break,
            other => panic!("expected the link to be dropped, got {other:?}"),
        }
    }
    assert!(silent_since.elapsed() >= Duration::from_millis(400));
}

#[tokio::test]
async fn shutdown_closes_live_sessions_with_1001() {
    let plugin = Plugin::start(default_timers()).await;
    let mut device = plugin.session().await;
    let stopping = tokio::spawn(plugin.stop());
    device.expect_close(CLOSE_GOING_AWAY).await;
    stopping.await.unwrap();
}

#[tokio::test]
async fn only_the_protocol_path_upgrades() {
    let plugin = Plugin::start(default_timers()).await;
    let refused = tokio_tungstenite::connect_async(format!("ws://{}/other", plugin.addr)).await;
    match refused {
        Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
            assert_eq!(response.status(), 404);
        }
        other => panic!("expected HTTP 404, got {:?}", other.map(|_| ())),
    }
}
