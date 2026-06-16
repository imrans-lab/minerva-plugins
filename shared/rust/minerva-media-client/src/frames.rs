/// JWT sub extraction + request JSON builders.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde_json::{json, Value};
use uuid::Uuid;

use crate::{Credentials, GenerateRequest, InputFile, MediaError};

/// Extract the `sub` claim from a JWT without verifying the signature.
/// Splits on '.', base64url-decodes (no pad) the middle segment, parses JSON.
pub fn jwt_sub(token: &str) -> Result<String, MediaError> {
    let parts: Vec<&str> = token.splitn(3, '.').collect();
    if parts.len() < 2 {
        return Err(MediaError::Auth("JWT has fewer than 2 segments".into()));
    }
    let payload_bytes = URL_SAFE_NO_PAD
        .decode(parts[1])
        .map_err(|e| MediaError::Auth(format!("JWT base64 decode: {e}")))?;
    let payload: Value = serde_json::from_slice(&payload_bytes)
        .map_err(|e| MediaError::Auth(format!("JWT JSON parse: {e}")))?;
    payload
        .get("sub")
        .and_then(|v| v.as_str())
        .map(|s| s.to_owned())
        .ok_or_else(|| MediaError::Auth("JWT has no 'sub' claim".into()))
}

/// Encode bytes to standard (padded) base64, as required by the wire spec.
pub fn encode_base64_std(bytes: &[u8]) -> String {
    use base64::engine::general_purpose::STANDARD;
    STANDARD.encode(bytes)
}

/// Build the outbound register JSON message.
pub fn build_register_msg(client_id: &str, token: &str, request_id: &str) -> Value {
    json!({
        "cmd": "register",
        "topic": "system",
        "entity_type": "client",
        "params": {
            "client_id": client_id,
            "auth": token,
            "request_id": request_id
        }
    })
}

/// Build the outbound request JSON message per the wire spec appendix.
///
/// Exact shape:
/// ```json
/// {
///   "cmd": "request",
///   "topic": "<topic>",
///   "entity_type": "client",
///   "params": {
///     "client_id": "<client_id>",
///     "request_id": "<request_id>",
///     "target_service_id": "media-gen",
///     "data": {
///       "workflow": "<workflow>",
///       <...params merged...>,
///       "files": [{ "filename", "role", "data": "<base64-std>", "content_type" }]
///     },
///     "auth": "<token>"
///   }
/// }
/// ```
pub fn build_request_msg(
    creds: &Credentials,
    request_id: &str,
    req: &GenerateRequest,
) -> Value {
    // Build the files array.
    let files: Vec<Value> = req
        .files
        .iter()
        .map(|f: &InputFile| {
            json!({
                "filename": f.filename,
                "role": f.role,
                "data": encode_base64_std(&f.bytes),
                "content_type": f.content_type
            })
        })
        .collect();

    // Merge params into data: start with workflow, overlay params object, then
    // insert files (files overrides any "files" key in params).
    let mut data = serde_json::Map::new();
    data.insert("workflow".into(), Value::String(req.workflow.clone()));
    if let Value::Object(extra) = &req.params {
        for (k, v) in extra {
            data.insert(k.clone(), v.clone());
        }
    }
    data.insert("files".into(), Value::Array(files));

    json!({
        "cmd": "request",
        "topic": req.topic,
        "entity_type": "client",
        "params": {
            "client_id": creds.client_id,
            "request_id": request_id,
            "target_service_id": "media-gen",
            "data": Value::Object(data),
            "auth": creds.token
        }
    })
}

/// Build the heartbeat_response message.
pub fn build_heartbeat_response() -> Value {
    json!({ "cmd": "heartbeat_response" })
}

/// Generate a new random request_id (UUID v4).
pub fn new_request_id() -> String {
    Uuid::new_v4().to_string()
}
