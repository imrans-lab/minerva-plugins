use prost::Message;
use smart_remote_plugin::provisioning::{
    config_request, config_response, decode, wifi_config, wire::*, Error,
};

#[test]
fn configuration_bytes_obey_the_firmware_contract() {
    let token = "A".repeat(43); // Public all-zero synthetic token, never a device token.
    let bytes = config_request("minerva.local", 47821, &token).unwrap();
    assert!(bytes.len() <= 512);
    assert_eq!(format!("{bytes:?}"), "SecretBytes [redacted]");
    let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        value,
        serde_json::json!({"v":1,"host":"minerva.local","port":47821,"token":token})
    );
    for host in [
        "",
        "::1",
        "::",
        "0.0.0.0",
        "127.0.0.1",
        "localhost",
        "LOCALHOST.",
        "127.1",
        "127.9.8.7",
        "0.0.0.0.",
        "-host",
        "host-",
        "a..b",
        "a/b",
        "a\0b",
    ] {
        assert_eq!(config_request(host, 47821, &token), Err(Error::Config));
    }
    assert_eq!(
        config_request(&"a".repeat(64), 1, &token),
        Err(Error::Config)
    );
    assert_eq!(config_request("host", 0, &token), Err(Error::Config));
    for bad in ["A".repeat(42), "!".repeat(43), "A".repeat(42) + "B"] {
        assert_eq!(config_request("host", 1, &bad), Err(Error::Config));
    }
    assert_eq!(
        config_response(br#"{"v":1,"ok":true,"device_id":"a4cf12b03e5d"}"#).unwrap(),
        "a4cf12b03e5d"
    );
    for bad in [
        r#"{"v":1,"ok":true,"device_id":"a4cf12b03e5d","extra":0}"#,
        r#"{"v":1,"v":1,"ok":true,"device_id":"a4cf12b03e5d"}"#,
        r#"{"v":1,"ok":false,"error":"bad_request"}"#,
        r#"{"v":2,"ok":true,"device_id":"a4cf12b03e5d"}"#,
        r#"{"v":1,"ok":true,"device_id":"A4cf12b03e5d"}"#,
        r#"{"v":1,"ok":true,"device_id":"a4cf12b03e5\u0000"}"#,
    ] {
        assert!(config_response(bad.as_bytes()).is_err());
    }
    let encoded = wifi_config(&[255; 32], &[0; 64]).unwrap();
    let message: WiFiConfigPayload = decode(&encoded).unwrap();
    assert_eq!(message.msg, 2);
    if let Some(wi_fi_config_payload::Payload::CmdSetConfig(c)) = message.payload {
        assert_eq!(c.ssid, vec![255; 32]);
        assert_eq!(c.passphrase, vec![0; 64]);
    } else {
        panic!("wrong canonical command");
    }
    for (ssid, password) in [
        (vec![], vec![]),
        (vec![1; 33], vec![]),
        (vec![1], vec![1; 65]),
    ] {
        assert_eq!(wifi_config(&ssid, &password), Err(Error::Config));
    }
}
#[test]
fn canonical_scan_apply_status_reset_roundtrip_without_field_transcription() {
    let scan = WiFiScanPayload {
        msg: WiFiScanMsgType::TypeCmdScanStart as i32,
        status: 0,
        payload: Some(wi_fi_scan_payload::Payload::CmdScanStart(CmdScanStart {
            blocking: false,
            passive: false,
            group_channels: 0,
            period_ms: 120,
        })),
    };
    assert!(decode::<WiFiScanPayload>(&scan.encode_to_vec()).unwrap() == scan);
    let apply = WiFiConfigPayload {
        msg: WiFiConfigMsgType::TypeCmdApplyConfig as i32,
        payload: Some(wi_fi_config_payload::Payload::CmdApplyConfig(
            CmdApplyConfig {},
        )),
    };
    assert!(decode::<WiFiConfigPayload>(&apply.encode_to_vec()).unwrap() == apply);
    let status = WiFiConfigPayload {
        msg: WiFiConfigMsgType::TypeCmdGetStatus as i32,
        payload: Some(wi_fi_config_payload::Payload::CmdGetStatus(CmdGetStatus {})),
    };
    assert!(decode::<WiFiConfigPayload>(&status.encode_to_vec()).unwrap() == status);
    let reset = WiFiCtrlPayload {
        msg: WiFiCtrlMsgType::TypeCmdCtrlReset as i32,
        status: 0,
        payload: Some(wi_fi_ctrl_payload::Payload::CmdCtrlReset(CmdCtrlReset {})),
    };
    assert!(decode::<WiFiCtrlPayload>(&reset.encode_to_vec()).unwrap() == reset);
}
