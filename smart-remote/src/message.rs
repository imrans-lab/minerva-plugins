//! Typed control messages and the checks every text frame passes through.
//!
//! Inbound: size cap → JSON → contract rules → protocol version → schema →
//! typed message. Outbound: typed message → U+0000 stripped → contract rules →
//! schema → size cap. Field definitions live only in `protocol/schema/`; the
//! types here are the plugin's view of messages that already passed it.

use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::contract::{self, ContractViolation, DEVICE_TEXT_MAX, PLUGIN_TEXT_MAX};
use crate::schema::{Direction, SchemaViolation, Schemas};

pub const PROTO_VERSION: u64 = 1;

/// A pairing token as received. Its Debug output is redacted so that a
/// logged message can never carry it.
#[derive(Deserialize, Clone, PartialEq, Eq)]
#[serde(transparent)]
pub struct Token(String);

impl Token {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Token {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Token(<redacted>)")
    }
}

#[derive(Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Voice,
    Mouse,
}

#[derive(Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DeviceMsg {
    Hello {
        proto: u64,
        token: Token,
        device_id: String,
        fw: String,
    },
    PttDown {
        stream: u8,
    },
    PttUp {
        stream: u8,
    },

    Clear,
    Send,
    Mode {
        mode: Mode,
    },
    PickerOpen,
    PickerList {
        group_id: String,
    },
    TargetSet {
        chat_id: String,
    },
    ChoicePick {
        choice_id: String,
        index: u8,
    },
}

#[derive(Serialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    Auth,
    ProtoVersion,
    BadMessage,
    AudioGap,
    Busy,
    NoTarget,
    SendFailed,
    EmptyDraft,
    TargetChanged,
    TtsFailed,
    Internal,
}

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PluginMsg {
    Welcome {
        proto: u64,
        plugin: String,
    },
    Target {
        chat_id: Option<String>,
        name: String,
        group: String,
        group_id: Option<String>,
    },

    Draft {
        text: String,
    },
    MicState {
        state: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    Reply {
        chat_id: String,
        text: String,
        outcome: String,
    },
    Error {
        code: ErrorCode,
        message: String,
    },
}

impl PluginMsg {
    pub fn error(code: ErrorCode, message: impl Into<String>) -> Self {
        Self::Error {
            code,
            message: message.into(),
        }
    }

    /// `target{chat_id:null}`: no chat is open.
    pub fn no_target() -> Self {
        Self::Target {
            chat_id: None,
            name: String::new(),
            group: String::new(),
            group_id: None,
        }
    }
}

/// Why an inbound text frame was refused. Each maps to one protocol.md
/// outcome: `ProtoVersion` → `error{proto_version}` + 4003, `BadMessage` →
/// `error{bad_message}` + 4002.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rejection {
    ProtoVersion,
    BadMessage(String),
}

impl From<ContractViolation> for Rejection {
    fn from(v: ContractViolation) -> Self {
        Self::BadMessage(v.to_string())
    }
}

impl From<SchemaViolation> for Rejection {
    fn from(v: SchemaViolation) -> Self {
        Self::BadMessage(v.to_string())
    }
}

pub fn decode_device_text(text: &str, schemas: &Schemas) -> Result<DeviceMsg, Rejection> {
    if text.len() > DEVICE_TEXT_MAX {
        return Err(Rejection::BadMessage("text frame over 4 KiB".into()));
    }
    let value: Value = serde_json::from_str(text)
        .map_err(|_| Rejection::BadMessage("text frame is not valid JSON".into()))?;
    contract::check(&value)?;
    // The version is checked before the schema: hello.json pins proto to 1, so
    // schema-first would turn every other version into bad_message, and
    // protocol.md gives an unsupported proto its own code (4003). Only a
    // JSON integer is a version; anything else (2.0, "2") is bad_message.
    if value.get("type").and_then(Value::as_str) == Some("hello") {
        match value.get("proto") {
            Some(proto) if proto.is_i64() || proto.is_u64() => {
                if proto.as_u64() != Some(PROTO_VERSION) {
                    return Err(Rejection::ProtoVersion);
                }
            }
            Some(_) => {
                return Err(Rejection::BadMessage(
                    "hello.proto must be an integer".into(),
                ))
            }
            None => {}
        }
    }
    schemas.validate(Direction::DeviceToPlugin, &value)?;
    serde_json::from_value(value)
        .map_err(|_| Rejection::BadMessage("message does not match its type".into()))
}

#[derive(Debug)]
pub enum EncodeError {
    Serialize(String),
    Contract(ContractViolation),
    Schema(SchemaViolation),
    TooLarge(usize),
}

impl fmt::Display for EncodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Serialize(m) => write!(f, "cannot serialize: {m}"),
            Self::Contract(v) => write!(f, "breaks the protocol contract: {v}"),
            Self::Schema(v) => write!(f, "breaks its schema: {v}"),
            Self::TooLarge(n) => write!(f, "{n} bytes is over the 8 KiB plugin frame cap"),
        }
    }
}

impl std::error::Error for EncodeError {}

pub fn encode_plugin_msg(msg: &PluginMsg, schemas: &Schemas) -> Result<String, EncodeError> {
    let mut value = serde_json::to_value(msg).map_err(|e| EncodeError::Serialize(e.to_string()))?;
    contract::strip_nul(&mut value);
    encode_plugin_value(&value, schemas)
}

/// The outbound gate on its own, for a message already in JSON form.
pub fn encode_plugin_value(value: &Value, schemas: &Schemas) -> Result<String, EncodeError> {
    contract::check(value).map_err(EncodeError::Contract)?;
    schemas
        .validate(Direction::PluginToDevice, value)
        .map_err(EncodeError::Schema)?;
    let text = serde_json::to_string(value).map_err(|e| EncodeError::Serialize(e.to_string()))?;
    if text.len() > PLUGIN_TEXT_MAX {
        return Err(EncodeError::TooLarge(text.len()));
    }
    Ok(text)
}

/// Shortens `text` to at most `max` bytes on a character boundary.
pub fn clip(mut text: String, max: usize) -> String {
    if text.len() > max {
        let mut end = max;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn schemas() -> Schemas {
        Schemas::load().unwrap()
    }

    const HELLO: &str = r#"{"type":"hello","proto":1,"token":"3f9a1c0e7b2d4a6f","device_id":"a4cf12b03e5d","fw":"0.1.0"}"#;

    #[test]
    fn hello_decodes_with_redacted_token() {
        let msg = decode_device_text(HELLO, &schemas()).unwrap();
        let DeviceMsg::Hello {
            ref token,
            ref device_id,
            ..
        } = msg
        else {
            panic!("not hello: {msg:?}");
        };
        assert_eq!(token.as_str(), "3f9a1c0e7b2d4a6f");
        assert_eq!(device_id, "a4cf12b03e5d");
        assert!(!format!("{msg:?}").contains("3f9a1c0e7b2d4a6f"));
    }

    #[test]
    fn other_proto_versions_are_proto_version_not_bad_message() {
        let text = HELLO.replace("\"proto\":1", "\"proto\":2");
        assert_eq!(
            decode_device_text(&text, &schemas()),
            Err(Rejection::ProtoVersion)
        );
        for proto in ["-1", "0", "18446744073709551615"] {
            let text = HELLO.replace("\"proto\":1", &format!("\"proto\":{proto}"));
            assert_eq!(
                decode_device_text(&text, &schemas()),
                Err(Rejection::ProtoVersion),
                "proto {proto}"
            );
        }
        for proto in ["\"1\"", "\"2\"", "2.0", "1.0", "1e0", "null"] {
            let text = HELLO.replace("\"proto\":1", &format!("\"proto\":{proto}"));
            assert!(
                matches!(
                    decode_device_text(&text, &schemas()),
                    Err(Rejection::BadMessage(_))
                ),
                "proto {proto}"
            );
        }
    }

    #[test]
    fn nul_in_an_otherwise_valid_message_is_bad_message() {
        let text = HELLO.replace("0.1.0", r"0.1\u00000");
        assert_eq!(
            decode_device_text(&text, &schemas()),
            Err(Rejection::BadMessage("U+0000 in a string".into()))
        );
    }

    #[test]
    fn oversize_and_non_json_are_bad_message() {
        let big = format!(
            r#"{{"type":"send","pad":"{}"}}"#,
            "x".repeat(DEVICE_TEXT_MAX)
        );
        assert!(matches!(
            decode_device_text(&big, &schemas()),
            Err(Rejection::BadMessage(_))
        ));
        assert!(matches!(
            decode_device_text("not json", &schemas()),
            Err(Rejection::BadMessage(_))
        ));
        assert!(matches!(
            decode_device_text(r#"{"type":"teleport"}"#, &schemas()),
            Err(Rejection::BadMessage(_))
        ));
    }

    #[test]
    fn every_device_type_has_a_variant() {
        let s = schemas();
        let samples = [
            json!({"type":"ptt_down","stream":1}),
            json!({"type":"ptt_up","stream":1}),
            json!({"type":"clear"}),
            json!({"type":"send"}),
            json!({"type":"mode","mode":"mouse"}),
            json!({"type":"picker_open"}),
            json!({"type":"picker_list","group_id":"g"}),
            json!({"type":"target_set","chat_id":"c"}),
            json!({"type":"choice_pick","choice_id":"q","index":0}),
            serde_json::from_str(HELLO).unwrap(),
        ];
        let mut covered: Vec<&str> = samples
            .iter()
            .map(|v| v["type"].as_str().unwrap())
            .collect();
        covered.sort_unstable();
        let mut defined: Vec<&str> = s.types(Direction::DeviceToPlugin).collect();
        defined.sort_unstable();
        assert_eq!(covered, defined, "a device schema has no sample here");
        for sample in samples {
            decode_device_text(&sample.to_string(), &s)
                .unwrap_or_else(|e| panic!("{sample} rejected: {e:?}"));
        }
    }

    #[test]
    fn outbound_strips_nul_and_validates() {
        let s = schemas();
        let msg = PluginMsg::error(ErrorCode::Internal, "a\0b");
        let text = encode_plugin_msg(&msg, &s).unwrap();
        assert_eq!(text, r#"{"type":"error","code":"internal","message":"ab"}"#);
        let too_long = PluginMsg::error(ErrorCode::Internal, "x".repeat(201));
        assert!(matches!(
            encode_plugin_msg(&too_long, &s),
            Err(EncodeError::Schema(_))
        ));
        assert!(encode_plugin_msg(&PluginMsg::no_target(), &s).is_ok());
    }

    #[test]
    fn clip_respects_char_boundaries() {
        assert_eq!(clip("héllo".into(), 2), "h");
        assert_eq!(clip("abc".into(), 5), "abc");
    }
}
