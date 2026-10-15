//! Simulated device and in-process plugin for the integration tests. Every
//! message the plugin sends is checked against the protocol schemas and
//! contract rules as it is received.

#![allow(dead_code)] // Each test binary uses a different subset of these helpers.

use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use smart_remote_plugin::admission::Limits;
use smart_remote_plugin::audio::{FrameHeader, Kind, HEADER_LEN};
use smart_remote_plugin::contract::PLUGIN_TEXT_MAX;
use smart_remote_plugin::message::encode_plugin_value;
use smart_remote_plugin::schema::Schemas;
use smart_remote_plugin::server::{Server, ServerConfig, Timers, WS_PATH};
use smart_remote_plugin::store::TokenStore;
use tokio::net::TcpStream;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::{Bytes, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

pub const DEVICE: &str = "a4cf12b03e5d";
pub const TOKEN: &str = "3f9a1c0e7b2d4a6f";
/// How long a test waits for something that should happen.
pub const WAIT: Duration = Duration::from_secs(3);

pub struct Plugin {
    pub addr: SocketAddr,
    pub store: Arc<TokenStore>,
    pub schemas: Arc<Schemas>,
    stop: watch::Sender<bool>,
    task: JoinHandle<()>,
    _dir: tempfile::TempDir,
}

impl Plugin {
    /// A plugin on a free localhost port whose store already pairs DEVICE
    /// with TOKEN.
    pub async fn start(timers: Timers) -> Self {
        Self::start_with(timers, Limits::default()).await
    }

    pub async fn start_with(timers: Timers, limits: Limits) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(TokenStore::open(dir.path()).unwrap());
        store
            .pair(DEVICE, TOKEN, "SR2-3E5D", 1_760_000_000)
            .unwrap();
        let schemas = Arc::new(Schemas::load().unwrap());
        let mut config = ServerConfig::new(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)));
        config.timers = timers;
        config.limits = limits;
        let server = Server::bind(config, Arc::clone(&store), Arc::clone(&schemas))
            .await
            .unwrap();
        let addr = server.local_addr().unwrap();
        let (stop, stopped) = watch::channel(false);
        let task = tokio::spawn(server.run(stopped));
        Self {
            addr,
            store,
            schemas,
            stop,
            task,
            _dir: dir,
        }
    }

    pub async fn device(&self) -> Device {
        Device::connect(self.addr, Arc::clone(&self.schemas)).await
    }

    /// A device that has completed hello → welcome → target.
    pub async fn session(&self) -> Device {
        let mut device = self.device().await;
        device.handshake().await;
        device
    }

    pub async fn stop(self) {
        self.stop.send(true).unwrap();
        tokio::time::timeout(WAIT, self.task)
            .await
            .expect("server stops")
            .unwrap();
    }
}

pub fn hello(token: &str, device_id: &str) -> Value {
    json!({"type":"hello","proto":1,"token":token,"device_id":device_id,"fw":"0.1.0"})
}

pub fn mic(stream: u8, seq: u16, eos: bool, payload: usize) -> Vec<u8> {
    let header = FrameHeader {
        kind: Kind::Mic,
        eos,
        stream,
        seq,
    };
    let mut frame = header.encode().to_vec();
    frame.resize(HEADER_LEN + payload, 0);
    frame
}

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Msg(Value),
    Binary(Vec<u8>),
    Ping,
    /// A close frame with this code.
    Closed(Option<u16>),
    /// The stream ended or failed without a close frame.
    Ended,
}

impl Event {
    /// `"welcome"`, `"error:auth"`, `"close:4002"`, ... for compact asserts.
    pub fn label(&self) -> String {
        match self {
            Self::Msg(v) => match v["type"].as_str() {
                Some("error") => format!("error:{}", v["code"].as_str().unwrap_or("?")),
                Some(t) => t.to_owned(),
                None => "untyped".into(),
            },
            Self::Binary(_) => "binary".into(),
            Self::Ping => "ping".into(),
            Self::Closed(code) => format!("close:{}", code.map_or(0, |c| c)),
            Self::Ended => "ended".into(),
        }
    }
}

pub struct Device {
    ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    schemas: Arc<Schemas>,
    closed: bool,
}

impl Device {
    /// Opens the WebSocket, or returns the upgrade error.
    pub async fn try_connect(
        addr: SocketAddr,
        schemas: Arc<Schemas>,
    ) -> Result<Self, tokio_tungstenite::tungstenite::Error> {
        let (ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}{WS_PATH}")).await?;
        Ok(Self {
            ws,
            schemas,
            closed: false,
        })
    }

    pub async fn connect(addr: SocketAddr, schemas: Arc<Schemas>) -> Self {
        let (ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}{WS_PATH}"))
            .await
            .expect("WebSocket upgrade");
        Self {
            ws,
            schemas,
            closed: false,
        }
    }

    pub async fn send_json(&mut self, value: &Value) {
        self.send_text(&value.to_string()).await;
    }

    pub async fn send_text(&mut self, text: &str) {
        self.ws.send(Message::text(text)).await.expect("send text");
    }

    pub async fn send_binary(&mut self, frame: Vec<u8>) {
        self.ws
            .send(Message::Binary(Bytes::from(frame)))
            .await
            .expect("send binary");
    }

    /// The next frame within `wait`, or None. Plugin messages are validated
    /// against the schemas and contract on the way in.
    pub async fn next_event(&mut self, wait: Duration) -> Option<Event> {
        if self.closed {
            return Some(Event::Ended);
        }
        let until = tokio::time::Instant::now() + wait;
        loop {
            let next = match tokio::time::timeout_at(until, self.ws.next()).await {
                Err(_) => return None,
                Ok(next) => next,
            };
            return Some(match next {
                Some(Ok(Message::Text(text))) => {
                    assert!(text.len() <= PLUGIN_TEXT_MAX, "plugin frame over 8 KiB");
                    let value: Value =
                        serde_json::from_str(text.as_str()).expect("plugin sent JSON");
                    if let Err(e) = encode_plugin_value(&value, &self.schemas) {
                        panic!("plugin sent an invalid message {value}: {e}");
                    }
                    Event::Msg(value)
                }
                Some(Ok(Message::Binary(b))) => Event::Binary(b.to_vec()),
                Some(Ok(Message::Ping(_))) => Event::Ping,
                Some(Ok(Message::Pong(_) | Message::Frame(_))) => continue,
                Some(Ok(Message::Close(frame))) => Event::Closed(frame.map(|f| u16::from(f.code))),
                Some(Err(_)) | None => {
                    self.closed = true;
                    Event::Ended
                }
            });
        }
    }

    /// The next non-ping event, failing the test after WAIT.
    pub async fn recv(&mut self) -> Event {
        loop {
            match self.next_event(WAIT).await {
                Some(Event::Ping) => continue,
                Some(event) => return event,
                None => panic!("nothing from the plugin within {WAIT:?}"),
            }
        }
    }

    pub async fn recv_msg(&mut self) -> Value {
        match self.recv().await {
            Event::Msg(v) => v,
            other => panic!("expected a message, got {other:?}"),
        }
    }

    pub async fn expect_close(&mut self, code: u16) {
        assert_eq!(self.recv().await, Event::Closed(Some(code)));
    }

    /// Asserts nothing but pings arrives for `quiet`, and the link stays up.
    pub async fn expect_silence(&mut self, quiet: Duration) {
        let until = tokio::time::Instant::now() + quiet;
        loop {
            let left = until.saturating_duration_since(tokio::time::Instant::now());
            if left.is_zero() {
                return;
            }
            match self.next_event(left).await {
                None | Some(Event::Ping) => continue,
                Some(other) => panic!("expected silence, got {other:?}"),
            }
        }
    }

    /// Every non-ping event until the link closes or `quiet` passes with
    /// nothing new.
    pub async fn drain_labels(&mut self, quiet: Duration) -> Vec<String> {
        let mut labels = Vec::new();
        loop {
            match self.next_event(quiet).await {
                None => return labels,
                Some(Event::Ping) => continue,
                Some(Event::Ended) => {
                    labels.push("ended".into());
                    return labels;
                }
                Some(event @ Event::Closed(_)) => {
                    labels.push(event.label());
                    return labels;
                }
                Some(event) => labels.push(event.label()),
            }
        }
    }

    pub async fn handshake(&mut self) {
        self.send_json(&hello(TOKEN, DEVICE)).await;
        assert_eq!(
            self.recv_msg().await,
            json!({"type":"welcome","proto":1,"plugin":format!("smart-remote {}", env!("CARGO_PKG_VERSION"))})
        );
        assert_eq!(
            self.recv_msg().await,
            json!({"type":"target","chat_id":null,"name":"","group":"","group_id":null})
        );
    }
}

/// One line of a protocol/examples JSONL file.
#[derive(Debug, Clone)]
pub enum Frame {
    DeviceMsg(Value),
    DeviceAudio(Vec<u8>),
    PluginMsg(Value),
    PluginAudio(Vec<u8>),
}

pub fn examples_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("protocol/examples")
}

pub fn read_example(path: &std::path::Path) -> Vec<Frame> {
    let text = std::fs::read_to_string(path).unwrap();
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|line| {
            let frame: Value = serde_json::from_str(line).unwrap();
            let from_device = match frame["dir"].as_str() {
                Some("d2p") => true,
                Some("p2d") => false,
                other => panic!("bad dir {other:?} in {}", path.display()),
            };
            if let Some(msg) = frame.get("msg") {
                return if from_device {
                    Frame::DeviceMsg(msg.clone())
                } else {
                    Frame::PluginMsg(msg.clone())
                };
            }
            let header = hex_bytes(frame["audio"].as_str().unwrap());
            let mut bytes = header;
            bytes.resize(
                HEADER_LEN + frame["bytes"].as_u64().unwrap_or(0) as usize,
                0,
            );
            if from_device {
                Frame::DeviceAudio(bytes)
            } else {
                Frame::PluginAudio(bytes)
            }
        })
        .collect()
}

fn hex_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
        .collect()
}

pub fn file_names(dir: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap())
        .filter(|e| e.path().extension().is_some_and(|x| x == "jsonl"))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}
