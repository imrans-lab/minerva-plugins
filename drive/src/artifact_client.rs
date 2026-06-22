//! WebSocket client for the Core-hosted artifact storage service.
//!
//! Opens a single WebSocket to Core, performs the register handshake, then
//! issues request/response calls to the artifact service. Each call carries its
//! action in the frame `topic` (e.g. `artifact/list-mine`); replies are matched
//! to their call by `request_id`, with a per-call timeout. Blobs cross the wire
//! as standard (padded) base64 inside the JSON payload.
//!
//! The service routes on `topic` and requires the caller to pass its own
//! `user_id` in `params` (the JWT `sub`, which equals the session `client_id`);
//! the service does not derive it from the token. A request sent to the wrong
//! topic is silently dropped, so every call is bounded by a timeout.

#![allow(dead_code)] // the public surface is consumed by the sync layer

use std::time::{Duration, Instant};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::{json, Value};
use tungstenite::{connect, stream::MaybeTlsStream, Message, WebSocket};

/// The Core service id every artifact request is routed to.
const TARGET_SERVICE: &str = "artifact-service";

/// Session credentials minted by the host (`host.core.session`).
#[derive(Clone)]
pub struct Credentials {
    pub ws_url: String,
    pub token: String,
    pub client_id: String,
}

impl Credentials {
    /// Build credentials from a `host.core.session` capability result object,
    /// i.e. the JSON carrying `ws_url`, `token`, and `client_id`. Accepts either
    /// the bare result object or one still wrapped in a `result` field.
    pub fn from_session(value: &Value) -> Option<Self> {
        let obj = value.get("result").unwrap_or(value);
        let ws_url = obj.get("ws_url")?.as_str()?.to_owned();
        let token = obj.get("token")?.as_str()?.to_owned();
        let client_id = obj.get("client_id")?.as_str()?.to_owned();
        if ws_url.is_empty() || token.is_empty() || client_id.is_empty() {
            return None;
        }
        Some(Self { ws_url, token, client_id })
    }
}

/// Metadata for one stored artifact, as returned by `list-mine`.
#[derive(Debug, Clone)]
pub struct ArtifactMeta {
    pub artifact_uri: String,
    pub filename: String,
    pub size: u64,
    pub description: String,
    pub tags: Vec<String>,
    pub visibility: String,
    pub uploaded_at: String,
    pub file_exists: bool,
}

impl ArtifactMeta {
    fn from_value(v: &Value) -> Self {
        Self {
            artifact_uri: v.get("artifact_uri").and_then(Value::as_str).unwrap_or("").to_owned(),
            filename: v.get("filename").and_then(Value::as_str).unwrap_or("").to_owned(),
            size: v.get("size").and_then(Value::as_u64).unwrap_or(0),
            description: v.get("description").and_then(Value::as_str).unwrap_or("").to_owned(),
            tags: v
                .get("tags")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default(),
            visibility: v.get("visibility").and_then(Value::as_str).unwrap_or("").to_owned(),
            uploaded_at: v.get("uploaded_at").and_then(Value::as_str).unwrap_or("").to_owned(),
            file_exists: v.get("file_exists").and_then(Value::as_bool).unwrap_or(false),
        }
    }
}

/// A downloaded artifact's bytes and stored filename.
pub struct DownloadedArtifact {
    pub filename: String,
    pub bytes: Vec<u8>,
}

/// Result of an `upload` call.
pub struct UploadResult {
    pub uri: String,
    pub size: u64,
}

/// Errors surfaced by `ArtifactClient`.
#[derive(Debug)]
pub enum ArtifactError {
    /// WebSocket transport could not be established.
    Connect(String),
    /// The register handshake failed.
    Register(String),
    /// The service accepted the call but reported a failure.
    Remote(String),
    /// No reply arrived within the call's deadline.
    Timeout,
    /// A frame could not be sent, read, or parsed.
    Protocol(String),
}

impl std::fmt::Display for ArtifactError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Connect(s) => write!(f, "connect error: {s}"),
            Self::Register(s) => write!(f, "register error: {s}"),
            Self::Remote(s) => write!(f, "remote error: {s}"),
            Self::Timeout => write!(f, "timeout"),
            Self::Protocol(s) => write!(f, "protocol error: {s}"),
        }
    }
}

impl std::error::Error for ArtifactError {}

/// Blocking, single-connection artifact-service client.
pub struct ArtifactClient {
    ws: WebSocket<MaybeTlsStream<std::net::TcpStream>>,
    creds: Credentials,
    /// Upper bound on how long a single call waits for its reply.
    request_timeout: Duration,
    /// Per-`read()` socket timeout; a quiet gap shorter than `request_timeout`
    /// is not terminal — the call keeps waiting until its deadline.
    recv_timeout: Duration,
}

impl ArtifactClient {
    /// Connect to `creds.ws_url`, register, and await `registration_confirmed`.
    ///
    /// A `REGISTER_CLIENT_ID_IN_USE` error is treated as success: another
    /// connection already holds this client id, but each request authenticates
    /// independently via its `auth` token, so calls still succeed.
    pub fn connect(
        creds: Credentials,
        request_timeout: Duration,
        recv_timeout: Duration,
    ) -> Result<Self, ArtifactError> {
        let (mut ws, _resp) = connect(creds.ws_url.as_str())
            .map_err(|e| ArtifactError::Connect(format!("websocket connect: {e}")))?;
        set_read_timeout(&mut ws, Some(recv_timeout));

        let register_id = new_request_id();
        let reg = json!({
            "cmd": "register",
            "topic": "system",
            "entity_type": "client",
            "params": {
                "client_id": creds.client_id,
                "auth": creds.token,
                "request_id": register_id,
            }
        });
        ws.send(Message::Text(reg.to_string().into()))
            .map_err(|e| ArtifactError::Register(format!("send register: {e}")))?;

        loop {
            let msg = match ws.read() {
                Ok(m) => m,
                Err(tungstenite::Error::Io(ref e))
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    return Err(ArtifactError::Register("timed out awaiting confirmation".into()));
                }
                Err(e) => return Err(ArtifactError::Register(format!("recv: {e}"))),
            };
            let Message::Text(text) = msg else { continue };
            let v: Value = serde_json::from_str(&text)
                .map_err(|e| ArtifactError::Register(format!("parse: {e}")))?;
            let cmd = v.get("cmd").and_then(Value::as_str).unwrap_or("");
            let rid = param_str(&v, "request_id");
            match cmd {
                "registration_confirmed" if rid == register_id => break,
                "error" if rid == register_id => {
                    let code = param_str(&v, "error_code");
                    let err = param_str(&v, "error");
                    if code.contains("IN_USE") || err.contains("IN_USE") {
                        break;
                    }
                    let detail = if err.is_empty() { code } else { err };
                    return Err(ArtifactError::Register(detail));
                }
                _ => {} // events / unrelated request ids during registration
            }
        }

        Ok(Self { ws, creds, request_timeout, recv_timeout })
    }

    /// The session client id (the JWT `sub`), used as the artifact owner key.
    pub fn client_id(&self) -> &str {
        &self.creds.client_id
    }

    /// Issue one artifact call. `action` is the bare verb appended to `artifact/`
    /// for the topic (e.g. `"list-mine"`). Returns the reply's `params.result`.
    fn call(&mut self, action: &str, data: Value) -> Result<Value, ArtifactError> {
        let rid = new_request_id();
        let frame = json!({
            "cmd": "request",
            "topic": format!("artifact/{action}"),
            "entity_type": "client",
            "params": {
                "client_id": self.creds.client_id,
                "request_id": rid,
                "target_service_id": TARGET_SERVICE,
                "user_id": self.creds.client_id,
                "auth": self.creds.token,
                "data": data,
            }
        });
        self.ws
            .send(Message::Text(frame.to_string().into()))
            .map_err(|e| ArtifactError::Protocol(format!("send {action}: {e}")))?;

        let deadline = Instant::now() + self.request_timeout;
        loop {
            if Instant::now() > deadline {
                return Err(ArtifactError::Timeout);
            }
            let msg = match self.ws.read() {
                Ok(m) => m,
                Err(tungstenite::Error::Io(ref e))
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    continue; // a quiet gap is not terminal; only the deadline ends the call
                }
                Err(e) => return Err(ArtifactError::Protocol(format!("recv {action}: {e}"))),
            };
            let Message::Text(text) = msg else { continue };
            let v: Value = serde_json::from_str(&text)
                .map_err(|e| ArtifactError::Protocol(format!("parse {action}: {e}")))?;
            let cmd = v.get("cmd").and_then(Value::as_str).unwrap_or("");
            match cmd {
                "heartbeat" => {
                    let _ = self.ws.send(Message::Text(json!({"cmd": "heartbeat_response"}).to_string().into()));
                }
                "response" if param_str(&v, "request_id") == rid => {
                    return Ok(v.get("params").and_then(|p| p.get("result")).cloned().unwrap_or(Value::Null));
                }
                "error" if param_str(&v, "request_id") == rid => {
                    let err = param_str(&v, "error");
                    return Err(ArtifactError::Remote(if err.is_empty() { "unknown error".into() } else { err }));
                }
                _ => {} // heartbeats handled above; everything else (events, other rids) is skipped
            }
        }
    }

    /// List the caller's own artifacts.
    pub fn list_mine(&mut self) -> Result<Vec<ArtifactMeta>, ArtifactError> {
        let result = self.call("list-mine", json!({}))?;
        let items = result
            .get("artifacts")
            .and_then(Value::as_array)
            .map(|a| a.iter().map(ArtifactMeta::from_value).collect())
            .unwrap_or_default();
        Ok(items)
    }

    /// Upload bytes as a new immutable artifact. `tags` carry the sync manifest.
    pub fn upload(
        &mut self,
        filename: &str,
        bytes: &[u8],
        visibility: &str,
        tags: &[String],
        description: &str,
    ) -> Result<UploadResult, ArtifactError> {
        let data = json!({
            "filename": filename,
            "content": STANDARD.encode(bytes),
            "visibility": visibility,
            "tags": tags,
            "description": description,
        });
        let result = self.call("upload", data)?;
        let uri = result.get("uri").and_then(Value::as_str).unwrap_or("").to_owned();
        if uri.is_empty() {
            return Err(ArtifactError::Protocol("upload reply missing uri".into()));
        }
        let size = result.get("size").and_then(Value::as_u64).unwrap_or(bytes.len() as u64);
        Ok(UploadResult { uri, size })
    }

    /// Download an artifact's bytes by URI (base64 transfer).
    pub fn download(&mut self, uri: &str) -> Result<DownloadedArtifact, ArtifactError> {
        let result = self.call("download", json!({"uri": uri, "transfer_mode": "base64"}))?;
        let content = result
            .get("content")
            .and_then(Value::as_str)
            .ok_or_else(|| ArtifactError::Protocol("download reply missing content".into()))?;
        let bytes = STANDARD
            .decode(content)
            .map_err(|e| ArtifactError::Protocol(format!("base64 decode: {e}")))?;
        let filename = result.get("filename").and_then(Value::as_str).unwrap_or("").to_owned();
        Ok(DownloadedArtifact { filename, bytes })
    }

    /// Delete an artifact the caller owns.
    pub fn delete(&mut self, artifact_uri: &str) -> Result<(), ArtifactError> {
        self.call("delete", json!({"artifact_uri": artifact_uri}))?;
        Ok(())
    }

    /// Replace metadata (tags/description/visibility) on an existing artifact.
    pub fn add_metadata(
        &mut self,
        artifact_uri: &str,
        filename: &str,
        tags: &[String],
        description: &str,
        visibility: &str,
    ) -> Result<(), ArtifactError> {
        self.call(
            "add-metadata",
            json!({
                "artifact_uri": artifact_uri,
                "filename": filename,
                "tags": tags,
                "description": description,
                "visibility": visibility,
            }),
        )?;
        Ok(())
    }

    /// Subscribe to a Core pub/sub topic and await the subscription confirmation.
    pub fn subscribe(&mut self, topic: &str) -> Result<(), ArtifactError> {
        let rid = new_request_id();
        let frame = json!({
            "cmd": "subscribe",
            "topic": "subscription",
            "params": {
                "client_id": self.creds.client_id,
                "request_id": rid,
                "topic": topic,
            }
        });
        self.ws
            .send(Message::Text(frame.to_string().into()))
            .map_err(|e| ArtifactError::Protocol(format!("send subscribe: {e}")))?;

        let deadline = Instant::now() + self.request_timeout;
        loop {
            if Instant::now() > deadline {
                return Err(ArtifactError::Timeout);
            }
            let msg = match self.ws.read() {
                Ok(m) => m,
                Err(tungstenite::Error::Io(ref e))
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    continue;
                }
                Err(e) => return Err(ArtifactError::Protocol(format!("recv subscribe: {e}"))),
            };
            let Message::Text(text) = msg else { continue };
            let v: Value = serde_json::from_str(&text)
                .map_err(|e| ArtifactError::Protocol(format!("parse subscribe: {e}")))?;
            let cmd = v.get("cmd").and_then(Value::as_str).unwrap_or("");
            if cmd == "heartbeat" {
                let _ = self.ws.send(Message::Text(json!({"cmd": "heartbeat_response"}).to_string().into()));
                continue;
            }
            if param_str(&v, "request_id") == rid {
                if cmd == "error" {
                    return Err(ArtifactError::Remote(param_str(&v, "error")));
                }
                return Ok(());
            }
        }
    }

    /// Wait up to `wait` for one pub/sub `event` frame; return its `params`.
    /// Heartbeats are answered transparently; `None` means no event arrived.
    pub fn next_event(&mut self, wait: Duration) -> Result<Option<Value>, ArtifactError> {
        set_read_timeout(&mut self.ws, Some(wait));
        let outcome = self.read_one_event(wait);
        set_read_timeout(&mut self.ws, Some(self.recv_timeout));
        outcome
    }

    fn read_one_event(&mut self, wait: Duration) -> Result<Option<Value>, ArtifactError> {
        let deadline = Instant::now() + wait;
        loop {
            if Instant::now() > deadline {
                return Ok(None);
            }
            let msg = match self.ws.read() {
                Ok(m) => m,
                Err(tungstenite::Error::Io(ref e))
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    return Ok(None);
                }
                Err(e) => return Err(ArtifactError::Protocol(format!("recv event: {e}"))),
            };
            let Message::Text(text) = msg else { continue };
            let v: Value = serde_json::from_str(&text)
                .map_err(|e| ArtifactError::Protocol(format!("parse event: {e}")))?;
            match v.get("cmd").and_then(Value::as_str).unwrap_or("") {
                "heartbeat" => {
                    let _ = self.ws.send(Message::Text(json!({"cmd": "heartbeat_response"}).to_string().into()));
                }
                "event" => return Ok(v.get("params").cloned()),
                _ => {}
            }
        }
    }
}

/// Read a string field from `params`, defaulting to "".
fn param_str(v: &Value, key: &str) -> String {
    v.get("params")
        .and_then(|p| p.get(key))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned()
}

/// Generate a fresh request correlation id.
fn new_request_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Apply a read timeout to the underlying TCP stream (plain or TLS).
fn set_read_timeout(ws: &mut WebSocket<MaybeTlsStream<std::net::TcpStream>>, t: Option<Duration>) {
    match ws.get_mut() {
        MaybeTlsStream::Plain(tcp) => {
            let _ = tcp.set_read_timeout(t);
        }
        MaybeTlsStream::NativeTls(tls) => {
            let _ = tls.get_mut().set_read_timeout(t);
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;

    // Live round-trip against the real artifact service. Opt-in via
    // DRIVE_LIVE_TEST=1 so default `cargo test` (no network, no credentials)
    // skips it. Credentials come from a REST login; override the endpoints and
    // account with DRIVE_LOGIN_URL / DRIVE_WS_URL / DRIVE_USER / DRIVE_PASS.
    #[test]
    fn live_round_trip() {
        if std::env::var("DRIVE_LIVE_TEST").is_err() {
            return;
        }

        let login_url = env_or("DRIVE_LOGIN_URL", "https://www.turnrock.ai:4040/v1/login");
        let ws_url = env_or("DRIVE_WS_URL", "wss://www.turnrock.ai:27500/connect");
        let user = env_or("DRIVE_USER", "test");
        let pass = env_or("DRIVE_PASS", "test");

        let body = serde_json::json!({ "username": user, "password": pass }).to_string();
        let resp = ureq::post(&login_url)
            .set("Content-Type", "application/json")
            .send_string(&body)
            .expect("login request");
        let login: Value = resp.into_json().expect("login json");
        let token = login["data"]["token"].as_str().expect("token").to_owned();
        let client_id = jwt_sub(&token);

        let creds = Credentials { ws_url, token, client_id };
        let mut client = ArtifactClient::connect(creds, Duration::from_secs(30), Duration::from_secs(10))
            .expect("connect + register");

        // Upload a small unique blob, then prove it round-trips and cleans up.
        let stamp = new_request_id();
        let filename = format!("drive-selftest-{stamp}.txt");
        let payload = format!("drive self-test {stamp}").into_bytes();
        let tags = vec![format!("proj:{stamp}"), "device:selftest".to_owned()];

        let up = client
            .upload(&filename, &payload, "private", &tags, "drive self-test")
            .expect("upload");
        assert!(up.uri.starts_with("artifact://"), "uri shape: {}", up.uri);

        let listed = client.list_mine().expect("list_mine");
        assert!(
            listed.iter().any(|a| a.artifact_uri == up.uri),
            "uploaded uri should appear in list-mine"
        );

        let got = client.download(&up.uri).expect("download");
        assert_eq!(got.bytes, payload, "downloaded bytes must match uploaded");

        client.delete(&up.uri).expect("delete");
        let after = client.list_mine().expect("list_mine after delete");
        assert!(
            !after.iter().any(|a| a.artifact_uri == up.uri),
            "deleted uri should be gone from list-mine"
        );

        println!("live_round_trip OK — uri={}, {} artifacts before cleanup", up.uri, listed.len());
    }

    fn env_or(key: &str, default: &str) -> String {
        std::env::var(key).unwrap_or_else(|_| default.to_owned())
    }

    /// Decode the `sub` claim from a JWT without verifying the signature.
    fn jwt_sub(token: &str) -> String {
        let payload = token.split('.').nth(1).expect("jwt payload segment");
        let bytes = URL_SAFE_NO_PAD.decode(payload).expect("jwt base64");
        let claims: Value = serde_json::from_slice(&bytes).expect("jwt claims");
        claims["sub"].as_str().expect("sub claim").to_owned()
    }
}
