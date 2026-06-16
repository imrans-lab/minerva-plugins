# A1 — Frozen interface: shared media-gen client + credential seam

Frozen 2026-06-16 (Opus, direct). A2/A3/B1 code against this; changes require a
re-freeze note here. Two surfaces: (1) the Rust crate both plugins consume, (2) the
Minerva host capability that feeds it credentials.

## 1. Rust crate — `shared/rust/minerva-media-client`

First shared **Rust** crate in the repo (existing `shared/` is Go; `go.work` ignores
it). Both plugins depend on it by path:
`minerva-media-client = { path = "../shared/rust/minerva-media-client" }`.
Compiled into each plugin binary at build time → released tarball stays
self-contained; GHA checks out the whole repo so the path dep resolves.

**Model: blocking, single-threaded** — matches the existing Rust-plugin MCP loop
(scansort/agent-relay are synchronous; one `tools/call` in flight at a time). No
tokio. `generate()` blocks until the artifact arrives (up to the request timeout),
calling `on_progress` for each Core notification so the backend can emit
`minerva/plugin_event` for live UI status.

```toml
[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tungstenite = { version = "0.24", features = ["native-tls"] }  # blocking WS+TLS
ureq = "2"            # blocking HTTP for the test-only login()
base64 = "0.22"
uuid = { version = "1", features = ["v4"] }
# JWT 'sub' is read by splitting on '.' + base64-decoding the payload — NO jwt crate,
# NO signature verification (the host already authenticated).
```

### Public API

```rust
pub struct MediaGenConfig {
    pub login_url: String, // default "https://www.turnrock.ai:4040/v1/login"
    pub ws_url:    String, // default "wss://www.turnrock.ai:27500/connect"
    pub request_timeout: std::time::Duration, // default 600s
    pub recv_timeout:    std::time::Duration, // per-frame, default 120s
}
impl Default for MediaGenConfig { /* the defaults above */ }

#[derive(Clone)]
pub struct Credentials { pub ws_url: String, pub token: String, pub client_id: String }

pub struct InputFile {
    pub filename: String,
    pub role: String,          // workflow-specific: "image" | "first_frame" | "last_frame"
    pub bytes: Vec<u8>,
    pub content_type: String,  // e.g. "image/png"
}

pub struct GenerateRequest {
    pub topic: String,             // "media_gen/text_to_3d" | ".../image_to_3d" | ".../text_to_video" | ".../flf2v"
    pub workflow: String,          // "text_to_3d" | "image_to_3d" | "text_to_video" | "flf2v"
    pub params: serde_json::Value, // a JSON object; merged into data{} alongside workflow + files
    pub files: Vec<InputFile>,     // may be empty
}

#[derive(Debug)]
pub enum Progress { Notification(String) }   // from Core "notification"/"notify" text msgs

pub struct Artifact { pub filename: String, pub bytes: Vec<u8> }

#[derive(Debug)]
pub enum MediaError { Auth(String), Connect(String), Register(String),
                      Remote(String), Timeout, Protocol(String) }

pub struct MediaGenClient { /* owns the WS, client_id, config */ }

impl MediaGenClient {
    /// Test-only convenience: REST login (user/pass) -> Credentials (decodes JWT sub).
    pub fn login(cfg: &MediaGenConfig, username: &str, password: &str)
        -> Result<Credentials, MediaError>;

    /// Connect to ws_url, perform the register handshake, await registration_confirmed.
    pub fn connect(cfg: MediaGenConfig, creds: Credentials)
        -> Result<MediaGenClient, MediaError>;

    /// Send one media-gen request; block until the first artifact for this request_id
    /// completes (FILE_END). Calls on_progress for each notification. Answers
    /// heartbeats. Returns all artifacts assembled for the request_id.
    pub fn generate(&mut self, req: GenerateRequest,
                    on_progress: &mut dyn FnMut(Progress))
        -> Result<Vec<Artifact>, MediaError>;
}
```

`generate()` correlates strictly on `request_id`; frames/text for other request_ids
are skipped. On a Core `error` text msg for our request_id → `MediaError::Remote`.

## 2. Minerva host capability — `host.media.credentials`

New capability in `CapabilityBroker.gd` (Opus, direct, Minerva `development`).
Read-only; returns the live Core session creds so the plugin reuses the host's
already-authenticated session (no plugin-side login).

```
capability: "host.media.credentials"
args: {}            // none
success result: { "ws_url": <string>, "token": <string>, "client_id": <string> }
```

Source: `Core.gd` `_jwt_token` (:38) + `_client_id` (:40); ws_url from core_client.
Gated by the manifest grant `host.media.credentials` + policy; **never auto-granted**
if it turns out to expose a broadly-scoped token (revisit scoping in A1a). Error
`media_credentials_unavailable` when not logged in.

Backend usage: tool handler calls `request_capability(.., "host.media.credentials", {})`
→ builds `Credentials` → `MediaGenClient::connect` → `generate`.

## 3. Test requirements (gate A1b commit)

Live connect needs the GPU node, so CI-gating unit tests cover the offline-deterministic
core — these must be green before the A1b commit:
- **Binary frame decode**: golden byte vectors for NEW_MESSAGE / FILE_INFO / FILE_DATA /
  FILE_END (LE widths: json_len u32, num_files u32, file_size u64, name_len u32,
  file_index u32; 1-byte type + 16-byte message_id prefix). Assert multi-chunk
  reassembly + request_id correlation + out-of-order FILE_DATA buffering.
- **Request serialization**: `GenerateRequest` → the exact outbound JSON
  (`cmd:"request"`, topic, `params.data{workflow, ...params, files:[{filename,role,
  data(base64),content_type}]}`, target_service_id "media-gen", request_id, auth).
- **JWT sub extraction**: decode a known unsigned JWT payload → client_id.
- **Heartbeat**: `heartbeat` in → `heartbeat_response` out (shape only).

Live e2e (text_to_3d/image_to_3d/text_to_video/flf2v through the crate) is validated
manually by Opus against the running GPU node (A1c), not in CI.

## Wire protocol appendix (authoritative: minervaservices media-gen-three-workflow-test.py)

- **Login**: `POST {login_url}` `{username,password}` → `data.token` (JWT).
- **WS**: `max_size=None`, ping 20s / timeout 120s.
- **Register** (text JSON): `{cmd:"register", topic:"system", entity_type:"client",
  params:{client_id, auth, request_id}}` → await `{cmd:"registration_confirmed",
  params:{request_id}}` (match request_id); `{cmd:"error",params:{request_id,error}}`.
- **Request** (text JSON): `{cmd:"request", topic, entity_type:"client",
  params:{client_id, request_id, target_service_id:"media-gen",
  data:{workflow, <params...>, files:[{filename, role, data:<base64>, content_type}]},
  auth}}`.
- **Binary frame**: `[0]=type` (0 NEW_MESSAGE,1 FILE_INFO,2 FILE_DATA,3 FILE_END),
  `[1:17]=message_id` (16-byte UUID), `[17:]=payload`:
  - NEW_MESSAGE: `u32 json_len` + `u32 num_files` + JSON header (`params.request_id`).
  - FILE_INFO: `u64 file_size` + `u32 name_len` + filename(utf8). file_index assigned
    sequentially as FILE_INFO frames arrive.
  - FILE_DATA: raw chunk (length implicit); append to current incomplete file.
  - FILE_END: `u32 file_index`; that file's buffer is complete. **All LE.**
- **Text msgs**: `response`(done), `error`(fail), `heartbeat`→reply `heartbeat_response`,
  `notification`/`notify`(progress, → on_progress). Correlate all on `params.request_id`.
