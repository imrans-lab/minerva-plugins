//! The stdio JSON-RPC link to Minerva, one message per line, after the
//! agent-relay plugin's router (Minerva `src/plugins/agent-relay/src/router.rs`).
//!
//! Minerva starts with `server/discover`; refusing it with -32601 makes the
//! host fall back to the `initialize` handshake, the only profile that
//! carries Minerva's own methods (`minerva/capability`, `minerva/plugin_event`,
//! `minerva/host_event`). stdout carries only JSON-RPC; logs go to stderr.

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::{json, Value};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

pub const PROTOCOL_VERSION: &str = "2024-11-05";
pub const SERVER_NAME: &str = crate::data_dir::PLUGIN_ID;
const METHOD_NOT_FOUND: i64 = -32601;

#[derive(Debug, Clone, PartialEq)]
pub enum HostError {
    /// The host refused the capability; the text is the host's reason.
    Denied(String),
    /// A JSON-RPC error reply.
    Rpc(Value),
    /// stdin closed before the reply arrived.
    Closed,
}

impl fmt::Display for HostError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Denied(m) => write!(f, "capability denied: {m}"),
            Self::Rpc(e) => write!(f, "capability error: {e}"),
            Self::Closed => f.write_str("host link closed"),
        }
    }
}

impl std::error::Error for HostError {}

type Pending = Mutex<HashMap<String, oneshot::Sender<Result<Value, HostError>>>>;

pub struct HostLink {
    out: mpsc::UnboundedSender<String>,
    pending: Pending,
    next_id: AtomicU64,
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
        R: AsyncBufRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (out, rx) = mpsc::unbounded_channel();
        let link = Arc::new(Self {
            out,
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
        });
        let writer = tokio::spawn(write_lines(rx, output));
        let reader = tokio::spawn(read_lines(input, Arc::clone(&link)));
        (link, HostTasks { reader, writer })
    }

    /// Calls a host capability and waits for its reply, unwrapping the
    /// broker's `{success, result | error_message}` envelope.
    pub async fn call_capability(&self, capability: &str, args: Value) -> Result<Value, HostError> {
        let id = format!("cap-{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        let (tx, rx) = oneshot::channel();
        // Registered before the request is written so the reply cannot
        // arrive first.
        self.lock_pending().insert(id.clone(), tx);
        self.write(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "minerva/capability",
            "params": {"capability": capability, "args": args},
        }));
        rx.await.unwrap_or(Err(HostError::Closed))
    }

    pub fn emit_event(&self, event: &str, payload: Value) {
        self.write(&json!({
            "jsonrpc": "2.0",
            "method": "minerva/plugin_event",
            "params": {"event": event, "payload": payload},
        }));
    }

    fn write(&self, message: &Value) {
        // Fails only after the writer task ended at shutdown; nothing can
        // reach the host then anyway.
        let _ = self.out.send(message.to_string());
    }

    fn lock_pending(
        &self,
    ) -> MutexGuard<'_, HashMap<String, oneshot::Sender<Result<Value, HostError>>>> {
        // Each critical section is a single map operation.
        self.pending.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn on_line(&self, line: &str) {
        let Ok(msg) = serde_json::from_str::<Value>(line) else {
            log::warn!("host sent a line that is not JSON; ignored");
            return;
        };
        let id = msg.get("id").filter(|id| !id.is_null()).cloned();
        match (msg.get("method").and_then(Value::as_str), id) {
            (Some(method), Some(id)) => self.on_request(method, id),
            (Some(method), None) => on_notification(method, msg.get("params")),
            (None, Some(id)) => self.on_reply(&id, &msg),
            (None, None) => log::warn!("host sent JSON-RPC with neither method nor id; ignored"),
        }
    }

    fn on_request(&self, method: &str, id: Value) {
        let result = match method {
            "initialize" => json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION")},
            }),
            "tools/list" => json!({"tools": []}),
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
        Some(false) => Err(HostError::Denied(
            result
                .get("error_message")
                .or_else(|| result.get("error_code"))
                .map_or_else(
                    || result.to_string(),
                    |v| v.as_str().map_or_else(|| v.to_string(), str::to_owned),
                ),
        )),
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

async fn read_lines<R: AsyncBufRead + Unpin>(input: R, link: Arc<HostLink>) {
    let mut lines = input.lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                let line = line.trim();
                if !line.is_empty() {
                    link.on_line(line);
                }
            }
            Ok(None) => {
                log::info!("host closed stdin");
                break;
            }
            Err(e) => {
                log::error!("reading from host failed: {e}");
                break;
            }
        }
    }
    link.fail_pending();
}

async fn write_lines<W: AsyncWrite + Unpin>(
    mut rx: mpsc::UnboundedReceiver<String>,
    mut output: W,
) {
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
    use tokio::io::{duplex, BufReader};

    #[tokio::test]
    async fn capability_call_round_trips_and_unwraps_the_envelope() {
        let (host_side, plugin_side) = duplex(4096);
        let (plugin_read, plugin_write) = tokio::io::split(plugin_side);
        let (host_read, mut host_write) = tokio::io::split(host_side);
        let (link, tasks) = HostLink::start(BufReader::new(plugin_read), plugin_write);
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
            Err(HostError::Denied("not granted".into()))
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
