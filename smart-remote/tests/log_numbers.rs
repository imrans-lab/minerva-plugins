//! Integer fields accept restored integral float tokens through the safe JSON range.
use serde_json::json;
use smart_remote_plugin::{
    message::{decode_device_text, DeviceMsg},
    schema::Schemas,
};
#[test]
fn offsets_accept_integral_float_and_reject_fraction_negative_unsafe_or_non_number() {
    let schemas = Schemas::load().unwrap();
    for (value, expected) in [(0.0, 0), (1.0, 1), (9007199254740991.0, 9007199254740991)] {
        let text = json!({"type":"log_page","offset":value,"limit":1}).to_string();
        assert!(
            matches!(decode_device_text(&text,&schemas),Ok(DeviceMsg::LogPage{offset,..}) if offset==expected)
        );
    }
    for value in [
        json!(-1.0),
        json!(0.5),
        json!(9007199254740992.0),
        json!("NaN"),
        json!(null),
    ] {
        assert!(decode_device_text(
            &json!({"type":"log_page","offset":value,"limit":1}).to_string(),
            &schemas
        )
        .is_err());
    }
}
