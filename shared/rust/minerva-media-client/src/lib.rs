//! `minerva-media-client` — blocking, single-threaded client for the Minerva
//! media-gen WebSocket service.
//!
//! Implements the frozen A1 interface from `docs/design/media-client-API.md`.

pub mod frames;
pub mod wire;

use std::time::{Duration, Instant};

use serde_json::Value;
use tungstenite::{connect, stream::MaybeTlsStream, Message, WebSocket};
use ureq;

use wire::{decode_frame, FrameEvent, MessageAssembler};

// ─────────────────────────────────────────────────────────────────────────────
// Public types
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for `MediaGenClient`.
pub struct MediaGenConfig {
    pub login_url: String,
    pub ws_url: String,
    pub request_timeout: Duration,
    pub recv_timeout: Duration,
}

impl Default for MediaGenConfig {
    fn default() -> Self {
        Self {
            login_url: "https://www.turnrock.ai:4040/v1/login".into(),
            ws_url: "wss://www.turnrock.ai:27500/connect".into(),
            request_timeout: Duration::from_secs(1800), // heavy video (720p/81f dual-expert) can run ~20+ min
            recv_timeout: Duration::from_secs(120),
        }
    }
}

/// Live credentials obtained from the host or via `login()`.
#[derive(Clone)]
pub struct Credentials {
    pub ws_url: String,
    pub token: String,
    pub client_id: String,
}

/// An input file to attach to a `GenerateRequest`.
pub struct InputFile {
    pub filename: String,
    /// Workflow-specific role: "image" | "first_frame" | "last_frame"
    pub role: String,
    pub bytes: Vec<u8>,
    pub content_type: String,
}

/// A media-gen request.
pub struct GenerateRequest {
    /// e.g. "media_gen/text_to_3d"
    pub topic: String,
    /// e.g. "text_to_3d"
    pub workflow: String,
    /// Arbitrary JSON object merged into `data{}` alongside `workflow` + `files`.
    pub params: Value,
    /// Input files; may be empty.
    pub files: Vec<InputFile>,
}

/// Progress notification from the server during `generate()`.
#[derive(Debug)]
pub enum Progress {
    Notification(String),
}

/// A completed output artifact.
pub struct Artifact {
    pub filename: String,
    pub bytes: Vec<u8>,
}

/// Errors returned by `MediaGenClient`.
#[derive(Debug)]
pub enum MediaError {
    Auth(String),
    Connect(String),
    Register(String),
    Remote(String),
    Timeout,
    Protocol(String),
}

impl std::fmt::Display for MediaError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Auth(s) => write!(f, "auth error: {s}"),
            Self::Connect(s) => write!(f, "connect error: {s}"),
            Self::Register(s) => write!(f, "register error: {s}"),
            Self::Remote(s) => write!(f, "remote error: {s}"),
            Self::Timeout => write!(f, "timeout"),
            Self::Protocol(s) => write!(f, "protocol error: {s}"),
        }
    }
}

impl std::error::Error for MediaError {}

// ─────────────────────────────────────────────────────────────────────────────
// Client
// ─────────────────────────────────────────────────────────────────────────────

/// Blocking, single-threaded media-gen client.
pub struct MediaGenClient {
    ws: WebSocket<MaybeTlsStream<std::net::TcpStream>>,
    creds: Credentials,
    config: MediaGenConfig,
}

impl MediaGenClient {
    /// Test-only convenience: REST login → `Credentials` (JWT sub → client_id).
    pub fn login(
        cfg: &MediaGenConfig,
        username: &str,
        password: &str,
    ) -> Result<Credentials, MediaError> {
        let body = serde_json::json!({ "username": username, "password": password });
        let resp = ureq::post(&cfg.login_url)
            .set("Content-Type", "application/json")
            .send_string(&body.to_string())
            .map_err(|e| MediaError::Auth(format!("HTTP login failed: {e}")))?;

        let json: Value = resp
            .into_json::<Value>()
            .map_err(|e| MediaError::Auth(format!("login JSON parse: {e}")))?;

        let token = json
            .get("data")
            .and_then(|d: &Value| d.get("token"))
            .and_then(|t: &Value| t.as_str())
            .ok_or_else(|| MediaError::Auth("login response missing data.token".into()))?
            .to_owned();

        let client_id = frames::jwt_sub(&token)?;

        Ok(Credentials {
            ws_url: cfg.ws_url.clone(),
            token,
            client_id,
        })
    }

    /// Connect to `ws_url`, perform the register handshake, await
    /// `registration_confirmed`.
    pub fn connect(cfg: MediaGenConfig, creds: Credentials) -> Result<Self, MediaError> {
        // tungstenite accepts &str directly via IntoClientRequest.
        let (mut ws, _resp) = connect(creds.ws_url.as_str())
            .map_err(|e| MediaError::Connect(format!("WS connect: {e}")))?;

        // Set read timeout on the underlying stream.
        set_read_timeout(&mut ws, Some(cfg.recv_timeout));

        // Send register.
        let register_id = frames::new_request_id();
        let reg_msg = frames::build_register_msg(&creds.client_id, &creds.token, &register_id);
        ws.send(Message::Text(reg_msg.to_string().into()))
            .map_err(|e| MediaError::Register(format!("send register: {e}")))?;

        // Await registration_confirmed (or error).
        loop {
            let msg = ws
                .read()
                .map_err(|e| MediaError::Register(format!("register recv: {e}")))?;

            if let Message::Text(text) = msg {
                let v: Value = serde_json::from_str(&text)
                    .map_err(|e| MediaError::Register(format!("register JSON: {e}")))?;
                let cmd = v.get("cmd").and_then(|c| c.as_str()).unwrap_or("");
                match cmd {
                    "registration_confirmed" => {
                        // Verify request_id matches.
                        let rid = v
                            .get("params")
                            .and_then(|p| p.get("request_id"))
                            .and_then(|r| r.as_str())
                            .unwrap_or("");
                        if rid == register_id {
                            break;
                        }
                        // Different request_id — might be a stale message, keep waiting.
                    }
                    "error" => {
                        let rid = v
                            .get("params")
                            .and_then(|p| p.get("request_id"))
                            .and_then(|r| r.as_str())
                            .unwrap_or("");
                        if rid == register_id {
                            let err = v
                                .get("params")
                                .and_then(|p| p.get("error"))
                                .and_then(|e| e.as_str())
                                .unwrap_or("unknown")
                                .to_owned();
                            return Err(MediaError::Register(err));
                        }
                    }
                    _ => {} // ignore other msgs during registration
                }
            }
        }

        Ok(Self { ws, creds, config: cfg })
    }

    /// Send one media-gen request; block until all artifacts for this
    /// `request_id` complete. Calls `on_progress` for each notification.
    /// Answers heartbeats transparently.
    pub fn generate(
        &mut self,
        req: GenerateRequest,
        on_progress: &mut dyn FnMut(Progress),
    ) -> Result<Vec<Artifact>, MediaError> {
        let request_id = frames::new_request_id();

        // Build and send the request JSON.
        let req_msg = frames::build_request_msg(&self.creds, &request_id, &req);
        self.ws
            .send(Message::Text(req_msg.to_string().into()))
            .map_err(|e| MediaError::Protocol(format!("send request: {e}")))?;

        let deadline = Instant::now() + self.config.request_timeout;

        // Per-message assembler. Maps message_id → assembler. In practice a
        // single message carries all files for one request.
        let mut assemblers: std::collections::HashMap<[u8; 16], (MessageAssembler, u32)> =
            std::collections::HashMap::new();
        // Tracks the message_id of the binary stream for our request_id (learned
        // from the matching NEW_MESSAGE header). Frames are grouped by it.
        let mut our_message_id: Option<[u8; 16]> = None;

        loop {
            if Instant::now() > deadline {
                return Err(MediaError::Timeout);
            }

            let msg = match self.ws.read() {
                Ok(m) => m,
                Err(tungstenite::Error::Io(ref e))
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    // A quiet per-recv gap is NOT terminal — long generations can
                    // be silent for a while. Keep looping; only the total
                    // request_timeout (checked at loop top) ends it. Matches the
                    // proven harness, which `continue`s on per-recv timeout.
                    continue;
                }
                Err(e) => return Err(MediaError::Protocol(format!("recv: {e}"))),
            };

            match msg {
                Message::Text(_) => {
                    let text = msg
                        .into_text()
                        .map_err(|e| MediaError::Protocol(format!("text decode: {e}")))?;
                    let v: Value = serde_json::from_str(&text)
                        .map_err(|e| MediaError::Protocol(format!("text JSON: {e}")))?;
                    let cmd = v.get("cmd").and_then(|c| c.as_str()).unwrap_or("");
                    let rid = v
                        .get("params")
                        .and_then(|p| p.get("request_id"))
                        .and_then(|r| r.as_str())
                        .unwrap_or("");

                    match cmd {
                        "heartbeat" => {
                            let hb = frames::build_heartbeat_response();
                            let _ = self.ws.send(Message::Text(hb.to_string().into()));
                        }
                        "notification" | "notify" => {
                            if rid == request_id {
                                // Progress text lives at params.data.message.
                                let msg_text = v
                                    .get("params")
                                    .and_then(|p| p.get("data"))
                                    .and_then(|d| d.get("message"))
                                    .and_then(|m| m.as_str())
                                    .unwrap_or("")
                                    .to_owned();
                                on_progress(Progress::Notification(msg_text));
                            }
                            // Skip notifications for other request_ids.
                        }
                        "response" => {
                            if rid == request_id {
                                // The "response" text msg is the TERMINAL success
                                // signal — the binary artifact frames have already
                                // arrived and assembled by now. A params.result.error
                                // means the server failed the request post-transfer.
                                if let Some(err) = v
                                    .get("params")
                                    .and_then(|p| p.get("result"))
                                    .and_then(|r| r.get("error"))
                                    .and_then(|e| e.as_str())
                                {
                                    return Err(MediaError::Remote(err.to_owned()));
                                }
                                let artifacts = our_message_id
                                    .and_then(|mid| assemblers.remove(&mid))
                                    .map(|(asm, _)| {
                                        asm.files
                                            .into_iter()
                                            .filter(|f| f.complete)
                                            .map(|f| Artifact {
                                                filename: f.filename,
                                                bytes: f.data,
                                            })
                                            .collect()
                                    })
                                    .unwrap_or_default();
                                return Ok(artifacts);
                            }
                        }
                        "error" => {
                            if rid == request_id {
                                let err = v
                                    .get("params")
                                    .and_then(|p| p.get("error"))
                                    .and_then(|e| e.as_str())
                                    .unwrap_or("unknown error")
                                    .to_owned();
                                return Err(MediaError::Remote(err));
                            }
                        }
                        _ => {}
                    }
                }

                Message::Binary(data) => {
                    let event = decode_frame(&data)?;
                    match event {
                        FrameEvent::NewMessage { message_id, header } => {
                            if header.request_id == request_id {
                                our_message_id = Some(message_id);
                                assemblers.insert(message_id, (MessageAssembler::new(), 0));
                            }
                            // else: different request_id — skip
                        }

                        FrameEvent::FileInfo {
                            message_id,
                            filename,
                            file_size,
                            ..
                        } => {
                            if Some(message_id) == our_message_id {
                                if let Some((asm, last_idx)) =
                                    assemblers.get_mut(&message_id)
                                {
                                    let idx = asm.on_file_info(filename, file_size);
                                    *last_idx = idx;
                                }
                            }
                        }

                        FrameEvent::FileData { message_id, chunk } => {
                            if Some(message_id) == our_message_id {
                                if let Some((asm, last_idx)) =
                                    assemblers.get_mut(&message_id)
                                {
                                    // FILE_DATA goes to the "active" file (most recently
                                    // FILE_INFO'd). If no FILE_INFO yet, buffer at slot 0.
                                    asm.on_file_data(*last_idx, chunk);
                                }
                            }
                        }

                        FrameEvent::FileEnd { message_id, file_index } => {
                            // Accumulate only; the terminal "response" text msg
                            // returns the assembled artifacts (matches the harness).
                            if Some(message_id) == our_message_id {
                                if let Some((asm, _)) = assemblers.get_mut(&message_id) {
                                    asm.on_file_end(file_index);
                                }
                            }
                        }
                    }
                }

                Message::Ping(data) => {
                    let _ = self.ws.send(Message::Pong(data));
                }
                Message::Pong(_) | Message::Frame(_) => {}
                Message::Close(_) => {
                    return Err(MediaError::Protocol("server closed connection".into()));
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{decode_frame, FrameEvent, MessageAssembler, FRAME_FILE_DATA, FRAME_FILE_END, FRAME_FILE_INFO, FRAME_NEW_MESSAGE};
    use crate::frames::{build_heartbeat_response, build_request_msg, encode_base64_std, jwt_sub};

    // ── helpers ──────────────────────────────────────────────────────────────

    fn make_message_id() -> [u8; 16] {
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    }

    fn push_u32_le(buf: &mut Vec<u8>, v: u32) {
        buf.extend_from_slice(&v.to_le_bytes());
    }

    fn push_u64_le(buf: &mut Vec<u8>, v: u64) {
        buf.extend_from_slice(&v.to_le_bytes());
    }

    fn build_new_message_frame(message_id: &[u8; 16], request_id: &str, num_files: u32) -> Vec<u8> {
        let json = serde_json::json!({
            "cmd": "new_message",
            "params": { "request_id": request_id }
        })
        .to_string();
        let json_bytes = json.as_bytes();

        let mut buf = vec![FRAME_NEW_MESSAGE];
        buf.extend_from_slice(message_id);
        push_u32_le(&mut buf, json_bytes.len() as u32);
        push_u32_le(&mut buf, num_files);
        buf.extend_from_slice(json_bytes);
        buf
    }

    fn build_file_info_frame(message_id: &[u8; 16], file_size: u64, filename: &str) -> Vec<u8> {
        let name_bytes = filename.as_bytes();
        let mut buf = vec![FRAME_FILE_INFO];
        buf.extend_from_slice(message_id);
        push_u64_le(&mut buf, file_size);
        push_u32_le(&mut buf, name_bytes.len() as u32);
        buf.extend_from_slice(name_bytes);
        buf
    }

    fn build_file_data_frame(message_id: &[u8; 16], data: &[u8]) -> Vec<u8> {
        let mut buf = vec![FRAME_FILE_DATA];
        buf.extend_from_slice(message_id);
        buf.extend_from_slice(data);
        buf
    }

    fn build_file_end_frame(message_id: &[u8; 16], file_index: u32) -> Vec<u8> {
        let mut buf = vec![FRAME_FILE_END];
        buf.extend_from_slice(message_id);
        push_u32_le(&mut buf, file_index);
        buf
    }

    // ── §3 test: golden-byte NEW_MESSAGE decode ───────────────────────────

    #[test]
    fn test_decode_new_message() {
        let mid = make_message_id();
        let request_id = "req-abc-123";
        let frame = build_new_message_frame(&mid, request_id, 2);

        let event = decode_frame(&frame).expect("decode should succeed");
        match event {
            FrameEvent::NewMessage { message_id, header } => {
                assert_eq!(message_id, mid);
                assert_eq!(header.request_id, request_id);
                assert_eq!(header.num_files, 2);
            }
            _ => panic!("expected NewMessage, got {:?}", event),
        }
    }

    // ── §3 test: golden-byte FILE_INFO decode ────────────────────────────

    #[test]
    fn test_decode_file_info() {
        let mid = make_message_id();
        let frame = build_file_info_frame(&mid, 1024, "output.glb");

        let event = decode_frame(&frame).expect("decode should succeed");
        match event {
            FrameEvent::FileInfo { message_id, filename, file_size, .. } => {
                assert_eq!(message_id, mid);
                assert_eq!(filename, "output.glb");
                assert_eq!(file_size, 1024);
            }
            _ => panic!("expected FileInfo"),
        }
    }

    // ── §3 test: golden-byte FILE_DATA decode ────────────────────────────

    #[test]
    fn test_decode_file_data() {
        let mid = make_message_id();
        let payload = b"hello world chunk";
        let frame = build_file_data_frame(&mid, payload);

        let event = decode_frame(&frame).expect("decode should succeed");
        match event {
            FrameEvent::FileData { message_id, chunk } => {
                assert_eq!(message_id, mid);
                assert_eq!(chunk, payload);
            }
            _ => panic!("expected FileData"),
        }
    }

    // ── §3 test: golden-byte FILE_END decode ─────────────────────────────

    #[test]
    fn test_decode_file_end() {
        let mid = make_message_id();
        let frame = build_file_end_frame(&mid, 0);

        let event = decode_frame(&frame).expect("decode should succeed");
        match event {
            FrameEvent::FileEnd { message_id, file_index } => {
                assert_eq!(message_id, mid);
                assert_eq!(file_index, 0);
            }
            _ => panic!("expected FileEnd"),
        }
    }

    // ── §3 test: multi-chunk reassembly ──────────────────────────────────

    #[test]
    fn test_multi_chunk_reassembly() {
        let mut asm = MessageAssembler::new();

        // FILE_INFO declares a 10-byte file.
        let idx = asm.on_file_info("out.bin".into(), 10);
        assert_eq!(idx, 0);

        // Two FILE_DATA chunks.
        asm.on_file_data(0, b"hello".to_vec());
        asm.on_file_data(0, b"world".to_vec());

        // FILE_END.
        asm.on_file_end(0);
        assert!(asm.all_complete(1));

        let file = &asm.files[0];
        assert_eq!(file.filename, "out.bin");
        assert_eq!(file.data, b"helloworld");
        assert!(file.complete);
    }

    // ── §3 test: out-of-order FILE_DATA (arrives before FILE_INFO) ───────

    #[test]
    fn test_out_of_order_file_data() {
        let mut asm = MessageAssembler::new();

        // FILE_DATA arrives first (slot 0 doesn't exist yet).
        asm.on_file_data(0, b"early ".to_vec());
        asm.on_file_data(0, b"chunk".to_vec());

        // FILE_INFO now arrives — flushes buffered chunks.
        let idx = asm.on_file_info("late.bin".into(), 11);
        assert_eq!(idx, 0);

        asm.on_file_end(0);
        assert!(asm.all_complete(1));

        assert_eq!(asm.files[0].data, b"early chunk");
    }

    // ── §3 test: request_id correlation ──────────────────────────────────

    #[test]
    fn test_request_id_correlation() {
        let mid = make_message_id();
        let our_rid = "our-request-id";
        let other_rid = "other-request-id";

        // Decode a NEW_MESSAGE with our request_id.
        let frame = build_new_message_frame(&mid, our_rid, 1);
        let event = decode_frame(&frame).unwrap();
        match &event {
            FrameEvent::NewMessage { header, .. } => {
                assert_eq!(header.request_id, our_rid);
                assert_ne!(header.request_id, other_rid);
            }
            _ => panic!("expected NewMessage"),
        }

        // Decode a NEW_MESSAGE with another request_id — should decode fine but
        // have a different request_id (caller filters).
        let mid2 = [99u8; 16];
        let frame2 = build_new_message_frame(&mid2, other_rid, 0);
        let event2 = decode_frame(&frame2).unwrap();
        match event2 {
            FrameEvent::NewMessage { header, .. } => {
                assert_eq!(header.request_id, other_rid);
            }
            _ => panic!("expected NewMessage"),
        }
    }

    // ── §3 test: request JSON serialization ──────────────────────────────

    #[test]
    fn test_request_serialization() {
        let creds = Credentials {
            ws_url: "wss://example.com".into(),
            token: "tok123".into(),
            client_id: "client-xyz".into(),
        };
        let file_bytes = b"PNG DATA";
        let req = GenerateRequest {
            topic: "media_gen/text_to_3d".into(),
            workflow: "text_to_3d".into(),
            params: serde_json::json!({ "prompt": "a red cube" }),
            files: vec![InputFile {
                filename: "ref.png".into(),
                role: "image".into(),
                bytes: file_bytes.to_vec(),
                content_type: "image/png".into(),
            }],
        };
        let request_id = "test-rid-001";

        let v = build_request_msg(&creds, request_id, &req);

        // Top-level keys.
        assert_eq!(v["cmd"], "request");
        assert_eq!(v["topic"], "media_gen/text_to_3d");
        assert_eq!(v["entity_type"], "client");

        // params
        let params = &v["params"];
        assert_eq!(params["client_id"], "client-xyz");
        assert_eq!(params["request_id"], "test-rid-001");
        assert_eq!(params["target_service_id"], "media-gen");
        assert_eq!(params["auth"], "tok123");

        // data
        let data = &params["data"];
        assert_eq!(data["workflow"], "text_to_3d");
        assert_eq!(data["prompt"], "a red cube");

        // files array
        let files = data["files"].as_array().expect("files should be array");
        assert_eq!(files.len(), 1);
        let f = &files[0];
        assert_eq!(f["filename"], "ref.png");
        assert_eq!(f["role"], "image");
        assert_eq!(f["content_type"], "image/png");

        // data field should be standard base64 of the input bytes.
        let expected_b64 = encode_base64_std(file_bytes);
        assert_eq!(f["data"], expected_b64);
    }

    // ── §3 test: JWT sub extraction ───────────────────────────────────────

    #[test]
    fn test_jwt_sub_extraction() {
        // Build a minimal unsigned JWT with a known sub.
        // header.payload.signature (signature can be any non-empty string for
        // our no-verify implementation).
        use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};

        let header = URL_SAFE_NO_PAD.encode(r#"{"alg":"none","typ":"JWT"}"#);
        let payload_json = r#"{"sub":"client-id-42","iat":1718000000}"#;
        let payload = URL_SAFE_NO_PAD.encode(payload_json);
        let token = format!("{header}.{payload}.fakesig");

        let sub = jwt_sub(&token).expect("should extract sub");
        assert_eq!(sub, "client-id-42");
    }

    // ── §3 test: JWT sub extraction — no padding ──────────────────────────

    #[test]
    fn test_jwt_sub_no_padding() {
        // Verify we handle payloads whose base64 length is not divisible by 4.
        use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};

        // This payload has length 47 bytes → base64 URL-safe no-pad is 63 chars.
        let payload_json = r#"{"sub":"abc","extra":"padding-test-1234567890"}"#;
        let header = URL_SAFE_NO_PAD.encode("{}");
        let payload = URL_SAFE_NO_PAD.encode(payload_json);
        let token = format!("{header}.{payload}.");

        let sub = jwt_sub(&token).expect("should extract sub");
        assert_eq!(sub, "abc");
    }

    // ── §3 test: heartbeat → heartbeat_response shape ─────────────────────

    #[test]
    fn test_heartbeat_response_shape() {
        let v = build_heartbeat_response();
        assert_eq!(v["cmd"], "heartbeat_response");
        // Must serialize to a JSON object with exactly cmd.
        let s = v.to_string();
        let parsed: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(parsed["cmd"], "heartbeat_response");
    }

    // ── §3 test: full pipeline — multiple files, multi-chunk ─────────────

    #[test]
    fn test_multi_file_multi_chunk_pipeline() {
        let mut asm = MessageAssembler::new();

        // Two files.
        let idx0 = asm.on_file_info("file0.glb".into(), 10);
        let idx1 = asm.on_file_info("file1.png".into(), 6);
        assert_eq!(idx0, 0);
        assert_eq!(idx1, 1);

        // Interleaved chunks (file0 then file1 then file0).
        asm.on_file_data(0, b"hello".to_vec());
        asm.on_file_data(1, b"pngdat".to_vec());
        asm.on_file_data(0, b"world".to_vec());

        asm.on_file_end(1);
        assert!(!asm.all_complete(2));
        asm.on_file_end(0);
        assert!(asm.all_complete(2));

        assert_eq!(asm.files[0].data, b"helloworld");
        assert_eq!(asm.files[1].data, b"pngdat");
    }

    // ── §3 test: MediaGenConfig defaults ─────────────────────────────────

    #[test]
    fn test_config_defaults() {
        let cfg = MediaGenConfig::default();
        assert_eq!(cfg.login_url, "https://www.turnrock.ai:4040/v1/login");
        assert_eq!(cfg.ws_url, "wss://www.turnrock.ai:27500/connect");
        assert_eq!(cfg.request_timeout, Duration::from_secs(600));
        assert_eq!(cfg.recv_timeout, Duration::from_secs(120));
    }
}
