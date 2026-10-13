//! Additive v1 compatibility: legacy firmware accepts a turn Speak without origin.
use serde_json::json;
use smart_remote_plugin::{
    message::{encode_plugin_msg, PluginMsg},
    schema::Schemas,
};

#[test]
fn turn_speak_preserves_legacy_shape_and_explicit_keeps_origin() {
    let schemas = Schemas::load().unwrap();
    for (origin, expected) in [
        ("turn", json!({"type":"speak","stream":7,"chat_id":"c1"})),
        (
            "explicit",
            json!({"type":"speak","stream":7,"origin":"explicit"}),
        ),
    ] {
        let message = PluginMsg::Speak {
            stream: 7,
            origin: origin.into(),
            chat_id: (origin == "turn").then(|| "c1".into()),
        };
        let encoded = encode_plugin_msg(&message, &schemas).unwrap();
        let actual: serde_json::Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(actual, expected);
    }
}
