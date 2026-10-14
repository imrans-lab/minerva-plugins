//! One device connection: the protocol.md session rules from `hello` to close.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio::time::{interval_at, sleep_until, timeout, Instant, MissedTickBehavior};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::{Bytes, Message};
use tokio_tungstenite::WebSocketStream;

use crate::admission::Permit;
use crate::audio::{parse_frame, Kind, MicFrame, MicStream};
use crate::bridge::Bridge;
use crate::host::HostEvent;
use crate::message::{
    clip, decode_device_text, encode_plugin_msg, DeviceMsg, ErrorCode, Mode, PluginMsg, Rejection,
};
use crate::server::{until_shutdown, Shared};
use crate::store::Verdict;
use tokio::sync::{broadcast, mpsc};

type Ws = WebSocketStream<TcpStream>;

pub const CLOSE_NORMAL: u16 = 1000;
pub const CLOSE_GOING_AWAY: u16 = 1001;
pub const CLOSE_AUTH: u16 = 4001;
pub const CLOSE_PROTOCOL: u16 = 4002;
pub const CLOSE_PROTO_VERSION: u16 = 4003;
pub const CLOSE_REPLACED: u16 = 4004;

pub const AUTH_MESSAGE: &str = "Unknown pairing token. Re-pair over Bluetooth.";
pub const NOT_IMPLEMENTED: &str = "not implemented";
/// `error.message` is `short_text` in common.json.
const ERROR_MESSAGE_MAX: usize = 200;
/// How long to wait for the peer's half of a close handshake.
const CLOSE_GRACE: Duration = Duration::from_secs(1);

/// How the session ends.
enum End {
    /// Send this close code, optionally after an `error` message.
    Close {
        code: u16,
        error: Option<(ErrorCode, String)>,
    },
    /// The peer closed, vanished, or went silent past the dead-link timer.
    Gone,
}

impl End {
    fn bad_message(detail: impl Into<String>) -> Self {
        Self::Close {
            code: CLOSE_PROTOCOL,
            error: Some((ErrorCode::BadMessage, detail.into())),
        }
    }

    fn from_rejection(rejection: Rejection) -> Self {
        match rejection {
            Rejection::ProtoVersion => Self::Close {
                code: CLOSE_PROTO_VERSION,
                error: Some((
                    ErrorCode::ProtoVersion,
                    "Unsupported protocol version; this plugin speaks version 1.".into(),
                )),
            },
            Rejection::BadMessage(detail) => Self::bad_message(detail),
        }
    }
}

/// `permit` counts this connection as unauthenticated; it is released once
/// the hello is accepted or refused, before any close handshake.
pub(crate) async fn run(
    mut ws: Ws,
    conn: u64,
    accepted_at: Instant,
    permit: Permit,
    shared: Arc<Shared>,
) {
    let deadline = accepted_at + shared.config.timers.hello;
    let first = first_message(&mut ws, deadline, &shared).await;
    drop(permit);
    let hello = match first {
        Ok(hello) => hello,
        Err(end) => return finish(&mut ws, conn, end, &shared).await,
    };
    let Hello { device_id, token } = hello;
    match shared.store.verify(&device_id, &token) {
        Verdict::Refused => {
            log::info!("conn {conn}: device {device_id} refused: unknown pairing token");
            let end = End::Close {
                code: CLOSE_AUTH,
                error: Some((ErrorCode::Auth, AUTH_MESSAGE.into())),
            };
            return finish(&mut ws, conn, end, &shared).await;
        }
        Verdict::Accepted { newly_confirmed } => {
            if newly_confirmed {
                let store = Arc::clone(&shared.store);
                let id = device_id.clone();
                // The hello confirms the pairing; failing to record that
                // costs only a repeat confirmation, so the session proceeds.
                tokio::task::spawn_blocking(move || {
                    if let Err(e) = store.confirm(&id, &token) {
                        log::error!("device {id}: cannot record pairing confirmation: {e}");
                    }
                });
            }
        }
    }
    let mut replaced = shared.register(&device_id, conn);
    log::info!("conn {conn}: device {device_id} authenticated");

    let welcome = PluginMsg::Welcome {
        proto: crate::message::PROTO_VERSION,
        plugin: shared.config.plugin_name.clone(),
    };
    let end = if send(&mut ws, &welcome, &shared).await
        && (shared.host.is_some() || send(&mut ws, &PluginMsg::no_target(), &shared).await)
    {
        serve(&mut ws, &mut replaced, &shared, &device_id, conn).await
    } else {
        End::Gone
    };
    shared.unregister(&device_id, conn);
    finish(&mut ws, conn, end, &shared).await;
}

struct Hello {
    device_id: String,
    token: String,
}

async fn first_message(ws: &mut Ws, deadline: Instant, shared: &Shared) -> Result<Hello, End> {
    let mut shutdown = shared.shutdown.clone();
    let text = loop {
        tokio::select! {
            () = sleep_until(deadline) => return Err(End::bad_message("no hello within 5 s")),
            () = until_shutdown(&mut shutdown) => return Err(going_away()),
            msg = ws.next() => match msg {
                Some(Ok(Message::Text(text))) => break text,
                Some(Ok(Message::Binary(_))) => return Err(End::bad_message("first message must be hello")),
                Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => continue,
                Some(Ok(Message::Close(_)) | Err(_)) | None => return Err(End::Gone),
            },
        }
    };
    match decode_device_text(text.as_str(), &shared.schemas) {
        Ok(DeviceMsg::Hello {
            token, device_id, ..
        }) => Ok(Hello {
            device_id,
            token: token.as_str().to_owned(),
        }),
        Ok(_) => Err(End::bad_message("first message must be hello")),
        Err(rejection) => Err(End::from_rejection(rejection)),
    }
}

/// The authenticated session: control messages, mic frames and keepalive.
async fn serve(
    ws: &mut Ws,
    replaced: &mut tokio::sync::oneshot::Receiver<()>,
    shared: &Shared,
    device_id: &str,
    conn: u64,
) -> End {
    let lifecycle = shared.endpoint_lock(device_id);
    let _lifecycle = lifecycle.lock().await;
    if !shared.is_current(device_id, conn) {
        return End::Gone;
    }
    let (mut bridge, mut events, mut updates) = match &shared.host {
        Some(host) => {
            let (b, e, u) = Bridge::new(host.clone(), device_id, shared.memory.clone());
            (Some(b), Some(e), Some(u))
        }
        None => (None, None, None),
    };
    let mut tick = tokio::time::interval(Duration::from_millis(20));
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let timers = shared.config.timers;
    let mut shutdown = shared.shutdown.clone();
    let mut mic = MicStream::default();
    let mut last_rx = Instant::now();
    let mut ping = interval_at(Instant::now() + timers.ping_every, timers.ping_every);
    ping.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let end = loop {
        let mut replies = tokio::select! {
            _ = &mut *replaced => break End::Close { code: CLOSE_REPLACED, error: None },
            () = until_shutdown(&mut shutdown) => break going_away(),
            () = sleep_until(last_rx + timers.dead_after) => {
                log::info!("no frame for {:?}; dropping the dead link", timers.dead_after);
                break End::Gone;
            }
            _ = ping.tick() => {
                if ws.send(Message::Ping(Bytes::new())).await.is_err() {
                    break End::Gone;
                }
                continue;
            }
            event = receive_event(&mut events) => {
                match event {
                    Ok(event) => bridge.as_mut().map_or_else(Vec::new, |b| b.event(event)),
                    Err(_) => { if let Some(b) = &mut bridge { b.cancel_mic(); b.cancel_output("Host event queue overflow"); } vec![PluginMsg::error(ErrorCode::Internal, "Host event queue overflow"), PluginMsg::MicState {state:"error".into(), detail:Some("Host event queue overflow".into())}] },
                }
            }
            update = receive_update(&mut updates) => {
                if let (Some(b), Some(update)) = (&mut bridge, update) {
                    let mut replies = b.update(update);
                    for event in b.take_early() { replies.extend(b.event(event)); }
                    replies
                } else { vec![] }
            }
            _ = tick.tick() => {
                if let Some(b) = &mut bridge {
                    let replies = b.tick();
                    if let Some(frame) = b.speaker_frame() {
                        if ws.send(Message::Binary(frame.into())).await.is_err() { break End::Gone; }
                    }
                    replies
                } else { vec![] }
            },
            msg = ws.next() => {
                last_rx = Instant::now();
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        if let Some(b) = &mut bridge {
                            match decode_device_text(text.as_str(), &shared.schemas) {
                                Ok(DeviceMsg::Hello { .. }) => break repeated_hello(),
                                Ok(DeviceMsg::Mode { mode: Mode::Mouse }) => break End::Close { code: CLOSE_NORMAL, error: None },
                                Ok(DeviceMsg::Mode { mode: Mode::Voice }) => vec![],
                                Ok(msg) => {
                                    let stream = match &msg { DeviceMsg::PttDown { stream } | DeviceMsg::PttUp { stream } => Some(*stream), _ => None };
                                    let up = matches!(msg, DeviceMsg::PttUp { .. });
                                    let replies = b.on_text(msg);
                                    if let Some(stream) = stream {
                                        if up { mic.end(stream); }
                                        else if replies.iter().any(|r| matches!(r, PluginMsg::MicState { state, .. } if state == "recording")) { mic.announce(stream); }
                                    }
                                    replies
                                }
                                Err(rejection) => break End::from_rejection(rejection),
                            }
                        } else {
                            match on_text(text.as_str(), &mut mic, shared) { Ok(reply) => reply.into_iter().collect(), Err(end) => break end }
                        }
                    },
                    Some(Ok(Message::Binary(frame))) => {
                        let parsed = parse_frame(&frame);
                        match on_binary(&frame, &mut mic) {
                            Ok(reply) => {
                                let mut replies: Vec<_> = reply.into_iter().collect();
                                if let (Some(b), Ok((header, pcm))) = (&mut bridge, parsed) {
                                    // The input worker validates its announced stream too; other streams are never forwarded.
                                    replies.extend(b.pcm(header.stream, pcm, header.eos));
                                }
                                replies
                            },
                            Err(end) => break end,
                        }
                    },
                    Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => vec![],
                    Some(Ok(Message::Close(_)) | Err(_)) | None => break End::Gone,
                }
            }
        };
        if let Some(b) = &mut bridge {
            if let Some(frame) = b.take_barge_frame() {
                if ws.send(Message::Binary(Bytes::from(frame))).await.is_err() {
                    break End::Gone;
                }
            }
            replies.extend(b.take_controls());
        }
        let mut failed = false;
        for reply in replies {
            if !send(ws, &reply, shared).await {
                failed = true;
                break;
            }
        }
        if let Some(b) = &bridge {
            if b.stopped {
                break End::Gone;
            }
            b.remember();
        }
        if failed {
            break End::Gone;
        }
    };
    if let Some(b) = &mut bridge {
        b.cancel_output("Plugin stopping");
        for control in b.take_controls() {
            let _ = send(ws, &control, shared).await;
        }
        b.close(shared.is_current(device_id, conn)).await;
    }
    end
}

async fn receive_event(
    events: &mut Option<broadcast::Receiver<HostEvent>>,
) -> Result<HostEvent, broadcast::error::RecvError> {
    match events {
        Some(rx) => rx.recv().await,
        None => std::future::pending().await,
    }
}
async fn receive_update(
    updates: &mut Option<mpsc::Receiver<crate::bridge::Update>>,
) -> Option<crate::bridge::Update> {
    match updates {
        Some(rx) => rx.recv().await,
        None => std::future::pending().await,
    }
}

fn on_text(text: &str, mic: &mut MicStream, shared: &Shared) -> Result<Option<PluginMsg>, End> {
    let msg = match decode_device_text(text, &shared.schemas) {
        Ok(msg) => msg,
        Err(Rejection::ProtoVersion) => return Err(repeated_hello()),
        Err(rejection) => return Err(End::from_rejection(rejection)),
    };
    match msg {
        DeviceMsg::Hello { .. } => Err(repeated_hello()),
        DeviceMsg::Mode { mode: Mode::Mouse } => Err(End::Close {
            code: CLOSE_NORMAL,
            error: None,
        }),
        DeviceMsg::Mode { mode: Mode::Voice } => Ok(None),
        DeviceMsg::PttDown { stream } => {
            mic.announce(stream);
            Ok(Some(not_implemented()))
        }
        DeviceMsg::PttUp { stream } => {
            mic.end(stream);
            Ok(Some(not_implemented()))
        }
        DeviceMsg::LogPage { .. }
        | DeviceMsg::LogPlay { .. }
        | DeviceMsg::LogDelete { .. }
        | DeviceMsg::LogDeleteAll
        | DeviceMsg::ReplayLast
        | DeviceMsg::Clear
        | DeviceMsg::Send
        | DeviceMsg::PickerOpen
        | DeviceMsg::PickerList { .. }
        | DeviceMsg::TargetSet { .. }
        | DeviceMsg::ChoicePick { .. }
        | DeviceMsg::SpeakDone { .. } => Ok(Some(not_implemented())),
    }
}

fn on_binary(frame: &[u8], mic: &mut MicStream) -> Result<Option<PluginMsg>, End> {
    let (header, _pcm) = parse_frame(frame).map_err(|e| End::bad_message(e.to_string()))?;
    if header.kind != Kind::Mic {
        return Err(End::bad_message(
            "speaker frames only flow plugin to device",
        ));
    }
    Ok(match mic.on_frame(&header) {
        MicFrame::Accepted { .. } | MicFrame::NotCurrent => None,
        MicFrame::Gap { expected, got } => Some(PluginMsg::error(
            ErrorCode::AudioGap,
            format!(
                "mic stream {}: expected seq {expected}, got {got}",
                header.stream
            ),
        )),
    })
}

fn not_implemented() -> PluginMsg {
    PluginMsg::error(ErrorCode::Internal, NOT_IMPLEMENTED)
}

fn repeated_hello() -> End {
    End::bad_message("hello is only valid as the first message")
}

fn going_away() -> End {
    End::Close {
        code: CLOSE_GOING_AWAY,
        error: None,
    }
}

/// Sends one message through the outbound gate. Returns false when the socket
/// is gone. A message that fails the gate is a plugin defect: it is logged and
/// not sent, and the session continues.
async fn send(ws: &mut Ws, msg: &PluginMsg, shared: &Shared) -> bool {
    match encode_plugin_msg(msg, &shared.schemas) {
        Ok(text) => ws.send(Message::text(text)).await.is_ok(),
        Err(e) => {
            log::error!("outbound message withheld: {e}");
            true
        }
    }
}

async fn finish(ws: &mut Ws, conn: u64, end: End, shared: &Shared) {
    let End::Close { code, error } = end else {
        return;
    };
    if let Some((error_code, detail)) = error {
        log::info!("conn {conn}: refusing with {error_code:?}: {detail}");
        let msg = PluginMsg::error(error_code, clip(detail, ERROR_MESSAGE_MAX));
        if !send(ws, &msg, shared).await {
            return;
        }
    }
    let frame = CloseFrame {
        code: CloseCode::from(code),
        reason: "".into(),
    };
    if ws.close(Some(frame)).await.is_err() {
        return;
    }
    // Drive the socket until the peer's close reply arrives, so the device
    // reads our close code rather than a reset.
    let _ = timeout(CLOSE_GRACE, async {
        while let Some(Ok(_)) = ws.next().await {}
    })
    .await;
}
