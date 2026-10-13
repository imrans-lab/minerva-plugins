//! The LAN WebSocket listener (`ws://<host>:<port>/remote/v1`) and the
//! one-connection-per-device registry.

use std::collections::HashMap;
use std::fmt;
use std::io;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{oneshot, watch};
use tokio::task::JoinSet;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

use crate::schema::Schemas;
use crate::session;
use crate::store::TokenStore;

pub const DEFAULT_PORT: u16 = 47821;
pub const WS_PATH: &str = "/remote/v1";
/// Transport bound on any one WebSocket message, well above both protocol
/// caps so an oversize control frame still reaches the protocol check and
/// gets `bad_message` rather than a transport-level close.
const WS_MESSAGE_LIMIT: usize = 64 * 1024;

/// protocol.md session timers. Tests shorten them.
#[derive(Debug, Clone, Copy)]
pub struct Timers {
    /// From TCP accept until `hello` must have arrived.
    pub hello: Duration,
    pub ping_every: Duration,
    /// Silence after which the link is treated as dead.
    pub dead_after: Duration,
}

impl Default for Timers {
    fn default() -> Self {
        Self {
            hello: Duration::from_secs(5),
            ping_every: Duration::from_secs(15),
            dead_after: Duration::from_secs(45),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub bind: SocketAddr,
    pub timers: Timers,
    /// The `welcome.plugin` string.
    pub plugin_name: String,
}

impl ServerConfig {
    pub fn new(bind: SocketAddr) -> Self {
        Self {
            bind,
            timers: Timers::default(),
            plugin_name: format!("smart-remote {}", env!("CARGO_PKG_VERSION")),
        }
    }
}

#[derive(Debug)]
pub struct ServerError {
    pub addr: SocketAddr,
    pub source: io::Error,
}

impl fmt::Display for ServerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "cannot listen on {}: {}", self.addr, self.source)
    }
}

impl std::error::Error for ServerError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.source)
    }
}

/// State every session shares.
pub(crate) struct Shared {
    pub config: ServerConfig,
    pub store: Arc<TokenStore>,
    pub schemas: Arc<Schemas>,
    pub shutdown: watch::Receiver<bool>,
    live: Mutex<HashMap<String, (u64, oneshot::Sender<()>)>>,
}

impl Shared {
    /// Makes `conn` the live connection for `device_id` and tells the
    /// previous one, if any, to close with 4004. The receiver fires when a
    /// newer connection replaces this one.
    pub fn register(&self, device_id: &str, conn: u64) -> oneshot::Receiver<()> {
        let (tx, rx) = oneshot::channel();
        let previous = self.lock_live().insert(device_id.to_owned(), (conn, tx));
        if let Some((_, replaced)) = previous {
            // The older session may already have ended; nothing to tell then.
            let _ = replaced.send(());
        }
        rx
    }

    pub fn unregister(&self, device_id: &str, conn: u64) {
        let mut live = self.lock_live();
        if live.get(device_id).is_some_and(|(c, _)| *c == conn) {
            live.remove(device_id);
        }
    }

    fn lock_live(&self) -> std::sync::MutexGuard<'_, HashMap<String, (u64, oneshot::Sender<()>)>> {
        // Each critical section is a single map operation, so a poisoned
        // lock still guards a consistent map.
        self.live.lock().unwrap_or_else(|e| e.into_inner())
    }
}

pub struct Server {
    listener: TcpListener,
    config: ServerConfig,
    store: Arc<TokenStore>,
    schemas: Arc<Schemas>,
}

impl Server {
    pub async fn bind(
        config: ServerConfig,
        store: Arc<TokenStore>,
        schemas: Arc<Schemas>,
    ) -> Result<Self, ServerError> {
        let listener = TcpListener::bind(config.bind)
            .await
            .map_err(|source| ServerError {
                addr: config.bind,
                source,
            })?;
        Ok(Self {
            listener,
            config,
            store,
            schemas,
        })
    }

    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.listener.local_addr()
    }

    /// Accepts connections until `shutdown` turns true, then closes every
    /// live session with 1001 and returns once they have finished.
    pub async fn run(self, mut shutdown: watch::Receiver<bool>) {
        let shared = Arc::new(Shared {
            config: self.config,
            store: self.store,
            schemas: self.schemas,
            shutdown: shutdown.clone(),
            live: Mutex::new(HashMap::new()),
        });
        let next_conn = AtomicU64::new(1);
        let mut sessions = JoinSet::new();
        loop {
            tokio::select! {
                () = until_shutdown(&mut shutdown) => break,
                accepted = self.listener.accept() => match accepted {
                    Ok((tcp, peer)) => {
                        let conn = next_conn.fetch_add(1, Ordering::Relaxed);
                        sessions.spawn(serve_connection(tcp, peer, conn, Arc::clone(&shared)));
                    }
                    Err(e) => {
                        log::warn!("accept failed: {e}");
                        // Typically descriptor exhaustion; back off instead of spinning.
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                },
                Some(_) = sessions.join_next(), if !sessions.is_empty() => {}
            }
        }
        while sessions.join_next().await.is_some() {}
    }
}

/// Resolves once shutdown is requested or its sender is gone.
pub(crate) async fn until_shutdown(shutdown: &mut watch::Receiver<bool>) {
    // An Err means the sender was dropped, which also means stop.
    let _ = shutdown.wait_for(|stop| *stop).await;
}

async fn serve_connection(tcp: TcpStream, peer: SocketAddr, conn: u64, shared: Arc<Shared>) {
    let accepted_at = Instant::now();
    let config = WebSocketConfig::default()
        .max_message_size(Some(WS_MESSAGE_LIMIT))
        .max_frame_size(Some(WS_MESSAGE_LIMIT));
    let check_path = |request: &Request, response: Response| {
        if request.uri().path() == WS_PATH {
            Ok(response)
        } else {
            let mut refusal = ErrorResponse::new(Some("not found".into()));
            *refusal.status_mut() = StatusCode::NOT_FOUND;
            Err(refusal)
        }
    };
    // The upgrade counts against the hello deadline, so a client that opens
    // TCP and stalls cannot hold a task open.
    let handshake = tokio_tungstenite::accept_hdr_async_with_config(tcp, check_path, Some(config));
    let ws =
        match tokio::time::timeout_at(accepted_at + shared.config.timers.hello, handshake).await {
            Ok(Ok(ws)) => ws,
            Ok(Err(e)) => {
                log::info!("conn {conn} from {peer}: WebSocket upgrade refused: {e}");
                return;
            }
            Err(_) => {
                log::info!("conn {conn} from {peer}: WebSocket upgrade timed out");
                return;
            }
        };
    log::info!("conn {conn} from {peer}: connected");
    session::run(ws, conn, accepted_at, shared).await;
    log::info!("conn {conn} from {peer}: closed");
}
