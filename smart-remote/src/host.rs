//! The stdio JSON-RPC link to Minerva, one message per line, after the
//! agent-relay plugin's router (Minerva `src/plugins/agent-relay/src/router.rs`).
//!
//! Minerva starts with `server/discover`; refusing it with -32601 makes the
//! host fall back to the `initialize` handshake, the only profile that
//! carries Minerva's own methods (`minerva/capability`, `minerva/plugin_event`,
//! `minerva/host_event`). stdout carries only JSON-RPC; logs go to stderr.

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::{json, Value};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{broadcast, mpsc, oneshot};
use tokio::task::JoinHandle;
use zeroize::{Zeroize, Zeroizing};

pub const PROTOCOL_VERSION: &str = "2024-11-05";
pub const SERVER_NAME: &str = crate::data_dir::PLUGIN_ID;
const METHOD_NOT_FOUND: i64 = -32601;

#[derive(Debug, Clone, PartialEq)]
pub enum HostError {
    /// The host refused the operation; preserve its reason and error code.
    Refused {
        code: String,
        reason: String,
    },
    /// A JSON-RPC error reply.
    Rpc(Value),
    /// stdin closed before the reply arrived.
    Closed,
    Overloaded,
    Timeout,
}

impl fmt::Display for HostError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Refused { code, reason } => {
                f.write_str(reason)?;
                if !code.is_empty() {
                    write!(f, " [{code}]")?;
                }
                Ok(())
            }
            Self::Rpc(e) => write!(f, "capability error: {e}"),
            Self::Closed => f.write_str("host link closed"),
            Self::Overloaded => f.write_str("host link queue is full"),
            Self::Timeout => f.write_str("host capability timed out"),
        }
    }
}

impl std::error::Error for HostError {}

type Pending = Mutex<HashMap<String, oneshot::Sender<Result<Value, HostError>>>>;

#[derive(Debug, Clone)]
pub struct HostEvent {
    pub name: String,
    pub payload: Value,
}

pub struct HostLink {
    probe: crate::ble::Probe,
    out: mpsc::Sender<String>,
    events: broadcast::Sender<HostEvent>,
    pending: Pending,
    next_id: AtomicU64,
    closed: AtomicBool,
}

pub struct HostTasks {
    /// Finishes at stdin EOF or a read error.
    pub reader: JoinHandle<()>,
    /// Finishes once every `HostLink` handle is dropped and output is flushed.
    pub writer: JoinHandle<()>,
}

impl HostLink {
    pub fn start<R, W>(input: R, output: W) -> (Arc<Self>, HostTasks)
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (out, rx) = mpsc::channel(64);
        let (events, _) = broadcast::channel(128);
        let link = Arc::new(Self {
            probe: crate::ble::Probe::default(),
            out,
            events,
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            closed: AtomicBool::new(false),
        });
        let writer = tokio::spawn(write_lines(rx, output));
        let reader = tokio::spawn(read_lines(input, Arc::clone(&link)));
        (link, HostTasks { reader, writer })
    }

    /// Calls a host capability and waits for its reply, unwrapping the
    /// broker's `{success, result | error_message}` envelope.
    pub async fn call_capability(&self, capability: &str, args: Value) -> Result<Value, HostError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(HostError::Closed);
        }
        let id = format!("cap-{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        let (tx, rx) = oneshot::channel();
        // Registered before the request is written so the reply cannot
        // arrive first.
        self.lock_pending().insert(id.clone(), tx);
        let request = PendingRequest {
            link: self,
            id: id.clone(),
        };
        if !self.write(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "minerva/capability",
            "params": {"capability": capability, "args": args},
        })) {
            return Err(HostError::Overloaded);
        }
        let seconds = match (capability, args["op"].as_str()) {
            ("host.audio", Some("input_end")) => 125,
            ("host.chat.input", Some("submit")) => 35,
            _ => 5,
        };
        let result = tokio::time::timeout(Duration::from_secs(seconds), rx)
            .await
            .map_err(|_| HostError::Timeout)?
            .unwrap_or(Err(HostError::Closed));
        drop(request);
        result
    }

    pub fn emit_event(&self, event: &str, payload: Value) {
        self.write(&json!({
            "jsonrpc": "2.0",
            "method": "minerva/plugin_event",
            "params": {"event": event, "payload": payload},
        }));
    }

    pub fn subscribe(&self) -> broadcast::Receiver<HostEvent> {
        self.events.subscribe()
    }
    pub async fn shutdown_probe(&self) {
        self.probe.shutdown().await;
    }
    pub fn configure_pairing(&self, store: Arc<crate::store::TokenStore>, port: u16) {
        self.probe.configure(store, port);
    }

    fn write(&self, message: &Value) -> bool {
        // Fails only after the writer task ended at shutdown; nothing can
        // reach the host then anyway.
        let line = message.to_string();
        if line.len() > 64 * 1024 {
            return false;
        }
        self.out.try_send(line).is_ok()
    }

    fn lock_pending(
        &self,
    ) -> MutexGuard<'_, HashMap<String, oneshot::Sender<Result<Value, HostError>>>> {
        // Each critical section is a single map operation.
        self.pending.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn on_line(&self, line: &str) {
        let Ok(mut msg) = serde_json::from_str::<Value>(line) else {
            log::warn!("host sent a line that is not JSON; ignored");
            return;
        };
        let id = msg.get("id").filter(|id| !id.is_null()).cloned();
        let method = msg.get("method").and_then(Value::as_str).map(str::to_owned);
        match (method.as_deref(), id) {
            (Some(method), Some(id)) => self.on_request(method, id, &mut msg["params"]),
            (Some("minerva/host_event"), None) => {
                if let Some(p) = msg.get("params") {
                    if let Some(name) = p.get("event").and_then(Value::as_str) {
                        let _ = self.events.send(HostEvent {
                            name: name.into(),
                            payload: p.get("payload").cloned().unwrap_or(Value::Null),
                        });
                    }
                }
            }
            (Some(method), None) => on_notification(method, msg.get("params")),
            (None, Some(id)) => self.on_reply(&id, &msg),
            (None, None) => log::warn!("host sent JSON-RPC with neither method nor id; ignored"),
        }
        crate::ble::scrub_json(&mut msg);
    }

    fn on_request(&self, method: &str, id: Value, params: &mut Value) {
        let result = match method {
            "initialize" => json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION")},
            }),
            "tools/list" => match crate::ble::tool_definitions() {
                Ok(tools) => json!({"tools": tools}),
                Err(error) => json!({"error": error}),
            },
            "tools/call" => {
                let result = if params["name"] == crate::ble::TOOL_NAME {
                    self.probe.call(&mut params["arguments"])
                } else if params["name"] == crate::ble::PAIRING_TOOL {
                    self.probe.pairing(&mut params["arguments"])
                } else {
                    Err(crate::provisioning::transport::Error::Input)
                };
                let failed = result.is_err();
                let body = result.unwrap_or_else(|error| json!({"error": error}));
                json!({"content": [{"type": "text", "text": body.to_string()}], "isError": failed})
            }
            "ping" => json!({}),
            _ => {
                self.write(&json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": {"code": METHOD_NOT_FOUND, "message": format!("method not found: {method}")},
                }));
                return;
            }
        };
        self.write(&json!({"jsonrpc": "2.0", "id": id, "result": result}));
    }

    fn on_reply(&self, id: &Value, msg: &Value) {
        let Some(key) = id_key(id) else {
            log::warn!("host reply has an unusable id; ignored");
            return;
        };
        let Some(waiter) = self.lock_pending().remove(&key) else {
            log::warn!("host reply for unknown id {key}; ignored");
            return;
        };
        let outcome = match (msg.get("error"), msg.get("result")) {
            (Some(error), _) => Err(HostError::Rpc(error.clone())),
            (None, result) => unwrap_envelope(result.cloned().unwrap_or(Value::Null)),
        };
        // The caller may have stopped waiting; nothing to deliver then.
        let _ = waiter.send(outcome);
    }

    fn fail_pending(&self) {
        for (_, waiter) in self.lock_pending().drain() {
            let _ = waiter.send(Err(HostError::Closed));
        }
    }
}

fn on_notification(method: &str, params: Option<&Value>) {
    match method {
        "notifications/initialized" => log::debug!("host initialized"),
        "minerva/host_event" => {
            let event = params
                .and_then(|p| p.get("event"))
                .and_then(Value::as_str)
                .unwrap_or("<missing>");
            // Declared in the manifest for later batches; no handler yet.
            log::debug!("host event {event} ignored");
        }
        other => log::debug!("host notification {other} ignored"),
    }
}

fn unwrap_envelope(result: Value) -> Result<Value, HostError> {
    match result.get("success").and_then(Value::as_bool) {
        Some(true) => Ok(result.get("result").cloned().unwrap_or(Value::Null)),
        Some(false) => {
            if let Some(detail) = result.get("detail") {
                log::warn!(
                    "Host refusal detail: {}",
                    crate::message::clip(detail.to_string(), 1000)
                );
            }
            Err(HostError::Refused {
                code: result["error_code"].as_str().unwrap_or("").to_owned(),
                reason: result["error_message"]
                    .as_str()
                    .unwrap_or("Host operation failed")
                    .to_owned(),
            })
        }
        None => Ok(result),
    }
}

/// Godot re-encodes numeric ids as floats ("1" comes back as 1.0), which is
/// why outgoing ids are strings; numeric ones are normalised anyway.
fn id_key(id: &Value) -> Option<String> {
    match id {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => n.as_i64().map(|i| i.to_string()).or_else(|| {
            n.as_f64()
                .filter(|f| f.fract() == 0.0)
                .map(|f| format!("{f:.0}"))
        }),
        _ => None,
    }
}

struct PendingRequest<'a> {
    link: &'a HostLink,
    id: String,
}
impl Drop for PendingRequest<'_> {
    fn drop(&mut self) {
        self.link.lock_pending().remove(&self.id);
    }
}

fn dispatch_raw(raw: &mut [u8], link: &HostLink) {
    match std::str::from_utf8(raw) {
        Ok(line) if !line.trim().is_empty() => link.on_line(line.trim()),
        Ok(_) => (),
        Err(_) => log::warn!("host sent invalid UTF-8; ignored"),
    }
    raw.zeroize();
}
async fn read_lines<R: AsyncRead + Unpin>(mut input: R, link: Arc<HostLink>) {
    // Fixed storage avoids reallocating a credential-bearing raw line.
    let mut raw = Zeroizing::new(vec![0; 64 * 1024]);
    let mut chunk = Zeroizing::new([0; 1024]);
    let mut used = 0;
    'reading: loop {
        match input.read(&mut chunk[..]).await {
            Ok(0) => {
                dispatch_raw(&mut raw[..used], &link);
                log::info!("host closed stdin");
                break;
            }
            Ok(count) => {
                for index in 0..count {
                    let byte = chunk[index];
                    chunk[index] = 0;
                    if byte == b'\n' {
                        dispatch_raw(&mut raw[..used], &link);
                        used = 0;
                    } else {
                        if used == raw.len() {
                            log::warn!("host request exceeds 64 KiB; closing link");
                            break 'reading;
                        }
                        raw[used] = byte;
                        used += 1;
                    }
                }
            }
            Err(e) => {
                log::error!("reading from host failed: {e}");
                break;
            }
        }
    }
    link.closed.store(true, Ordering::Release);
    link.probe.cancel();
    link.fail_pending();
}

async fn write_lines<W: AsyncWrite + Unpin>(mut rx: mpsc::Receiver<String>, mut output: W) {
    while let Some(mut line) = rx.recv().await {
        line.push('\n');
        if let Err(e) = output.write_all(line.as_bytes()).await {
            log::error!("writing to host failed: {e}");
            return;
        }
        if let Err(e) = output.flush().await {
            log::error!("flushing to host failed: {e}");
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "current_thread")]
    async fn pairing_mcp_receipts_preserve_worker_markers_and_redacted_domain_outcomes() {
        use tokio::io::{AsyncBufReadExt, BufReader};
        let data = tempfile::tempdir().unwrap();
        let store = Arc::new(crate::store::TokenStore::open(data.path()).unwrap());
        let (input, host_input) = tokio::io::duplex(1024);
        let (output, host_output) = tokio::io::duplex(16384);
        let (link, tasks) = HostLink::start(input, output);
        link.configure_pairing(store, 47821);
        let mut start = json!({"name":crate::ble::PAIRING_TOOL,"arguments":{
            "action":"start","code":"654321"}});
        link.on_request("tools/call", json!(1), &mut start);
        assert!(start["arguments"]["code"].is_null());
        link.on_request(
            "tools/call",
            json!(2),
            &mut json!({"name":crate::ble::PAIRING_TOOL,
            "arguments":{"action":"cancel","operation_id":1}}),
        );
        // No await before cancellation, so the adapter future is never polled.
        link.shutdown_probe().await;
        link.on_request(
            "tools/call",
            json!(3),
            &mut json!({"name":crate::ble::PAIRING_TOOL,
            "arguments":{"action":"status","operation_id":1}}),
        );
        let mut lines = BufReader::new(host_output).lines();
        let mut receipts = Vec::new();
        for id in 1..=3 {
            let receipt: Value = serde_json::from_str(
                &tokio::time::timeout(Duration::from_secs(2), lines.next_line())
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(receipt["id"], id);
            assert_eq!(receipt["result"]["isError"], false);
            let body: Value =
                serde_json::from_str(receipt["result"]["content"][0]["text"].as_str().unwrap())
                    .unwrap();
            assert_eq!(body["ok"], true);
            assert!(!receipt.to_string().contains("654321"));
            if id == 3 {
                assert_eq!(body["stage"], "cancelled");
                assert_eq!(body["error"], "cancelled");
            }
            receipts.push(receipt);
        }
        if let Some(path) = std::env::var_os("SMART_REMOTE_PANEL_RECEIPTS") {
            std::fs::write(path, serde_json::to_vec_pretty(&receipts).unwrap()).unwrap();
        }
        drop(host_input);
        tasks.reader.await.unwrap();
        drop(link);
        tasks.writer.await.unwrap();
    }
    #[test]
    fn host_refusals_show_reason_and_keep_code_without_permission_label() {
        let error = unwrap_envelope(json!({"success":false,"error_code":"busy",
            "error_message":"Another microphone is recording"}))
        .unwrap_err();
        assert_eq!(error.to_string(), "Another microphone is recording [busy]");
        assert_eq!(
            unwrap_envelope(json!({"success":false,"error_code":"permission_denied"}))
                .unwrap_err()
                .to_string(),
            "Host operation failed [permission_denied]"
        );
    }
    use tokio::io::{duplex, AsyncBufReadExt, BufReader};

    #[tokio::test(flavor = "current_thread")]
    async fn raw_input_storage_is_erased_after_valid_invalid_and_partial_lines() {
        let (link, tasks) = HostLink::start(tokio::io::empty(), tokio::io::sink());
        for message in [
            br#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"minerva_smart_remote_ble_probe","arguments":{"action":"start","name":"invalid","code":"654321"}}}"#.as_slice(),
            b"not JSON 654321",
            b"\xff 654321",
        ] {
            let mut raw = message.to_vec();
            dispatch_raw(&mut raw, &link);
            assert!(raw.iter().all(|byte| *byte == 0));
        }
        tasks.reader.await.unwrap();
        drop(link);
        tasks.writer.await.unwrap();

        struct CheckedInput {
            bytes: &'static [u8],
            reads: usize,
        }
        impl AsyncRead for CheckedInput {
            fn poll_read(
                mut self: std::pin::Pin<&mut Self>,
                _: &mut std::task::Context<'_>,
                buffer: &mut tokio::io::ReadBuf<'_>,
            ) -> std::task::Poll<std::io::Result<()>> {
                // The raw read scratch must be zero before every reuse, including EOF.
                assert!(buffer.initialized().iter().all(|byte| *byte == 0));
                self.reads += 1;
                let count = self.bytes.len().min(3);
                buffer.put_slice(&self.bytes[..count]);
                self.bytes = &self.bytes[count..];
                std::task::Poll::Ready(Ok(()))
            }
        }
        // Split code across reads, a newline, then a final partial line at EOF.
        let input = CheckedInput {
            bytes: b"invalid 654321\npartial 654321",
            reads: 0,
        };
        let (link, tasks) = HostLink::start(input, tokio::io::sink());
        tasks.reader.await.unwrap();
        drop(link);
        tasks.writer.await.unwrap();
    }

    #[tokio::test]
    async fn capability_call_round_trips_and_unwraps_the_envelope() {
        let (host_side, plugin_side) = duplex(4096);
        let (plugin_read, plugin_write) = tokio::io::split(plugin_side);
        let (host_read, mut host_write) = tokio::io::split(host_side);
        let (link, tasks) = HostLink::start(plugin_read, plugin_write);
        let mut host_lines = BufReader::new(host_read).lines();

        let call = tokio::spawn({
            let link = Arc::clone(&link);
            async move { link.call_capability("host.chat.active", json!({})).await }
        });
        let request: Value =
            serde_json::from_str(&host_lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(request["method"], "minerva/capability");
        assert_eq!(request["params"]["capability"], "host.chat.active");
        let reply = json!({"jsonrpc":"2.0","id":request["id"],"result":{"success":true,"result":{"chat_id":"c1"}}});
        host_write
            .write_all(format!("{reply}\n").as_bytes())
            .await
            .unwrap();
        assert_eq!(call.await.unwrap(), Ok(json!({"chat_id":"c1"})));

        let call = tokio::spawn({
            let link = Arc::clone(&link);
            async move { link.call_capability("host.chat.input", json!({})).await }
        });
        let request: Value =
            serde_json::from_str(&host_lines.next_line().await.unwrap().unwrap()).unwrap();
        let reply = json!({"jsonrpc":"2.0","id":request["id"],"result":{"success":false,"error_message":"not granted"}});
        host_write
            .write_all(format!("{reply}\n").as_bytes())
            .await
            .unwrap();
        assert_eq!(
            call.await.unwrap(),
            Err(HostError::Refused {
                code: String::new(),
                reason: "not granted".into()
            })
        );

        link.emit_event("smart_remote.test", json!({"n":1}));
        let event: Value =
            serde_json::from_str(&host_lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(event["method"], "minerva/plugin_event");
        assert!(event.get("id").is_none());

        let pending = tokio::spawn({
            let link = Arc::clone(&link);
            async move { link.call_capability("host.chat.active", json!({})).await }
        });
        let _ = host_lines.next_line().await.unwrap();
        host_write.shutdown().await.unwrap();
        tasks.reader.await.unwrap();
        assert_eq!(pending.await.unwrap(), Err(HostError::Closed));
    }

    #[test]
    fn float_ids_normalise() {
        assert_eq!(id_key(&json!(3.0)), Some("3".into()));
        assert_eq!(id_key(&json!("cap-3")), Some("cap-3".into()));
        assert_eq!(id_key(&json!(null)), None);
    }
}
