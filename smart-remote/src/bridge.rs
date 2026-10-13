//! Per-authenticated-connection host endpoint. Minerva owns transcription and turns.
use crate::host::{HostError, HostEvent, HostLink};
use crate::message::{clip, DeviceMsg, ErrorCode, PluginMsg};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, watch};
use tokio::task::JoinSet;
use tokio::time::Instant;

pub(crate) enum Update {
    Ready(Result<Value, HostError>),
    Started(u64, u64),
    Submitted(String, Result<Value, HostError>),
    Cleared(Result<Value, HostError>),
    Failed(u64, String),
}
struct Mic {
    generation: u64,
    stream: u8,
    session: Option<u64>,
    chat: String,
    pcm: mpsc::Sender<(Vec<u8>, bool)>,
    cancel: watch::Sender<bool>,
    ended: bool,
    started: Instant,
}
pub(crate) struct Bridge {
    pub host: Arc<HostLink>,
    pub device: String,
    updates: mpsc::Sender<Update>,
    tasks: JoinSet<()>,
    ready: bool,
    generation: u64,
    mic: Option<Mic>,
    target: Value,
    draft: String,
    pub sends: HashMap<u64, (String, bool)>,
    pending_send: bool,
    pending_clear: bool,
    early: VecDeque<HostEvent>,
}
impl Bridge {
    pub fn new(
        host: Arc<HostLink>,
        id: &str,
    ) -> (Self, broadcast::Receiver<HostEvent>, mpsc::Receiver<Update>) {
        let events = host.subscribe();
        let (updates, rx) = mpsc::channel(32);
        let mut b = Self {
            host,
            device: format!("remote_{id}"),
            updates,
            tasks: JoinSet::new(),
            ready: false,
            generation: 0,
            mic: None,
            target: Value::Null,
            draft: String::new(),
            sends: HashMap::new(),
            pending_send: false,
            pending_clear: false,
            early: VecDeque::new(),
        };
        let (host, device, tx) = (b.host.clone(), b.device.clone(), b.updates.clone());
        b.tasks.spawn(async move {
            let result = async {
                host.call_capability("host.audio", json!({"op":"register","device_id":device,"label":"Smart Remote","input":true,"output":true})).await?;
                host.call_capability("host.audio", json!({"op":"availability","device_id":device,"available":true})).await?;
                host.call_capability("host.chat.active", json!({})).await
            }.await;
            let _ = tx.send(Update::Ready(result)).await;
        });
        (b, events, rx)
    }
    pub fn update(&mut self, update: Update) -> Vec<PluginMsg> {
        match update {
            Update::Ready(Ok(target)) => {
                self.ready = true;
                self.target = target;
                vec![self.target_message()]
            }
            Update::Ready(Err(e)) => vec![error(ErrorCode::Internal, &e.to_string())],
            Update::Started(epoch, session) => {
                if let Some(m) = &mut self.mic {
                    if m.generation == epoch {
                        m.session = Some(session);
                    }
                }
                vec![]
            }
            Update::Failed(epoch, message) => {
                if self.mic.as_ref().is_some_and(|m| m.generation == epoch) {
                    self.cancel_mic();
                    vec![mic_state("error", Some(&message))]
                } else {
                    vec![]
                }
            }
            Update::Submitted(chat, result) => {
                self.pending_send = false;
                match result {
                    Ok(v) => match integer(&v["send_id"]) {
                        Some(id) => {
                            self.sends.insert(id, (chat, false));
                            self.draft.clear();
                            vec![PluginMsg::Draft {
                                text: String::new(),
                            }]
                        }
                        None => vec![error(
                            ErrorCode::SendFailed,
                            "Host did not return a send ID",
                        )],
                    },
                    Err(e) => vec![error(ErrorCode::SendFailed, &e.to_string())],
                }
            }
            Update::Cleared(Ok(_)) => {
                self.pending_clear = false;
                self.draft.clear();
                vec![PluginMsg::Draft {
                    text: String::new(),
                }]
            }
            Update::Cleared(Err(e)) => {
                self.pending_clear = false;
                vec![error(ErrorCode::Internal, &e.to_string())]
            }
        }
    }
    pub fn on_text(&mut self, msg: DeviceMsg) -> Vec<PluginMsg> {
        match msg {
            DeviceMsg::PttDown { stream } => {
                if !self.ready {
                    return vec![error(
                        ErrorCode::Internal,
                        "Minerva audio endpoint unavailable",
                    )];
                }
                if self.mic.is_some() {
                    return vec![error(
                        ErrorCode::Busy,
                        "Previous transcription is still active",
                    )];
                }
                let Some(chat) = self.target["chat_id"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                else {
                    return vec![error(ErrorCode::NoTarget, "No target chat")];
                };
                self.generation += 1;
                let generation = self.generation;
                let (pcm, rx) = mpsc::channel(32);
                let (cancel, stopped) = watch::channel(false);
                self.mic = Some(Mic {
                    generation,
                    stream,
                    session: None,
                    chat: chat.clone(),
                    pcm,
                    cancel,
                    ended: false,
                    started: Instant::now(),
                });
                self.tasks.spawn(input(
                    self.host.clone(),
                    self.device.clone(),
                    chat,
                    generation,
                    rx,
                    stopped,
                    self.updates.clone(),
                ));
                vec![mic_state("recording", None)]
            }
            DeviceMsg::PttUp { stream } => self.pcm(stream, &[], true),
            DeviceMsg::Clear => {
                if self.pending_send || self.pending_clear {
                    return vec![error(ErrorCode::Busy, "Input operation is still pending")];
                }
                self.pending_clear = true;
                let (host, tx) = (self.host.clone(), self.updates.clone());
                self.tasks.spawn(async move {
                    let r = host
                        .call_capability("host.chat.input", json!({"op":"clear"}))
                        .await;
                    let _ = tx.send(Update::Cleared(r)).await;
                });
                vec![]
            }
            DeviceMsg::Send => {
                if self.pending_send || self.pending_clear || self.mic.is_some() {
                    return vec![error(ErrorCode::Busy, "Input is still active")];
                }
                let Some(chat) = self.target["chat_id"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                else {
                    return vec![error(ErrorCode::NoTarget, "No target chat")];
                };
                if self.sends.len() >= 128 {
                    return vec![error(ErrorCode::Busy, "Too many outstanding remote turns")];
                }
                self.pending_send = true;
                let (host, tx) = (self.host.clone(), self.updates.clone());
                self.tasks.spawn(async move {
                    let r = host
                        .call_capability(
                            "host.chat.input",
                            json!({"op":"submit","expected_chat_id":chat}),
                        )
                        .await;
                    let _ = tx.send(Update::Submitted(chat, r)).await;
                });
                vec![]
            }
            _ => vec![error(ErrorCode::Internal, "not implemented")],
        }
    }
    pub fn pcm(&mut self, stream: u8, pcm: &[u8], eos: bool) -> Vec<PluginMsg> {
        let Some(m) = &mut self.mic else {
            return vec![];
        };
        if m.stream != stream || m.ended {
            return vec![];
        }
        if m.pcm.try_send((pcm.to_vec(), eos)).is_err() {
            self.cancel_mic();
            return vec![mic_state("error", Some("Microphone queue overflow"))];
        }
        m.ended = eos;
        if eos {
            vec![mic_state("transcribing", None)]
        } else {
            vec![]
        }
    }
    pub fn event(&mut self, event: HostEvent) -> Vec<PluginMsg> {
        let p = &event.payload;
        match event.name.as_str() {
            "chat.active_changed" => {
                if self
                    .mic
                    .as_ref()
                    .is_some_and(|m| p["chat_id"].as_str() != Some(m.chat.as_str()))
                {
                    self.cancel_mic();
                }
                self.target = p.clone();
                vec![self.target_message()]
            }
            "voice.transcript" if p["device_id"].as_str() == Some(self.device.as_str()) => {
                let Some(m) = &self.mic else { return vec![] };
                if m.session.is_none() {
                    if integer(&p["session_id"]).is_some()
                        && p["chat_id"].as_str() == Some(m.chat.as_str())
                        && self.early.len() < 64
                    {
                        self.early.push_back(event);
                    }
                    return vec![];
                }
                if integer(&p["session_id"]) != m.session
                    || p["chat_id"].as_str() != Some(m.chat.as_str())
                {
                    return vec![];
                }
                match p["state"].as_str() {
                    Some("idle") => {
                        self.draft.push_str(p["text"].as_str().unwrap_or(""));
                        self.draft = clip(self.draft.clone(), 6000);
                        self.mic = None;
                        vec![
                            PluginMsg::Draft {
                                text: self.draft.clone(),
                            },
                            mic_state("idle", None),
                        ]
                    }
                    Some("error") => {
                        self.cancel_mic();
                        vec![mic_state(
                            "error",
                            Some(p["error"].as_str().unwrap_or("Transcription failed")),
                        )]
                    }
                    _ => vec![],
                }
            }
            "chat.turn_completed" if p["plugin_id"].as_str() == Some("smart_remote") => {
                let Some(id) = integer(&p["send_id"]) else {
                    return vec![];
                };
                let Some((chat, seen)) = self.sends.get_mut(&id) else {
                    if self.pending_send && self.early.len() < 64 {
                        self.early.push_back(event);
                    }
                    return vec![];
                };
                if *seen || p["chat_id"].as_str() != Some(chat.as_str()) {
                    return vec![];
                }
                *seen = true;
                vec![PluginMsg::Reply {
                    chat_id: chat.clone(),
                    text: clip(p["text"].as_str().unwrap_or("").into(), 6000),
                    outcome: p["outcome"].as_str().unwrap_or("error").into(),
                }]
            }
            _ => vec![],
        }
    }
    pub fn take_early(&mut self) -> Vec<HostEvent> {
        self.early.drain(..).collect()
    }
    pub fn tick(&mut self) -> Vec<PluginMsg> {
        while let Some(r) = self.tasks.try_join_next() {
            if let Err(e) = r {
                log::error!("Host task failed: {e}");
            }
        }
        if self
            .mic
            .as_ref()
            .is_some_and(|m| !m.ended && m.started.elapsed() >= Duration::from_secs(300))
        {
            self.cancel_mic();
            vec![mic_state("error", Some("too_long"))]
        } else {
            vec![]
        }
    }
    pub fn cancel_mic(&mut self) {
        if let Some(m) = self.mic.take() {
            let _ = m.cancel.send(true);
        }
    }
    pub async fn close(&mut self, current: bool) {
        self.cancel_mic();
        if current {
            let _ = self
                .host
                .call_capability(
                    "host.audio",
                    json!({"op":"availability","device_id":self.device,"available":false}),
                )
                .await;
            let _ = self
                .host
                .call_capability(
                    "host.audio",
                    json!({"op":"unregister","device_id":self.device}),
                )
                .await;
        }
        while let Some(r) = self.tasks.join_next().await {
            if let Err(e) = r {
                log::error!("Host task shutdown failed: {e}");
            }
        }
    }
    fn target_message(&self) -> PluginMsg {
        PluginMsg::Target {
            chat_id: self.target["chat_id"].as_str().map(str::to_owned),
            name: clip(self.target["name"].as_str().unwrap_or("").into(), 200),
            group: clip(self.target["group"].as_str().unwrap_or("").into(), 200),
            group_id: self.target["group_id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
        }
    }
}
async fn input(
    host: Arc<HostLink>,
    device: String,
    chat: String,
    epoch: u64,
    mut pcm: mpsc::Receiver<(Vec<u8>, bool)>,
    mut cancel: watch::Receiver<bool>,
    updates: mpsc::Sender<Update>,
) {
    let result = host.call_capability("host.audio", json!({"op":"input_begin","device_id":device,"expected_chat_id":chat,"format":"pcm_s16le","sample_rate":16000,"channels":1})).await;
    let session = match result.and_then(|v| {
        integer(&v["session_id"])
            .ok_or_else(|| HostError::Denied("Missing integer input session ID".into()))
    }) {
        Ok(id) => id,
        Err(e) => {
            let _ = updates.send(Update::Failed(epoch, e.to_string())).await;
            return;
        }
    };
    let _ = updates.send(Update::Started(epoch, session)).await;
    let mut sequence = 0_u64;
    let mut total = 0_usize;
    let failure = loop {
        if *cancel.borrow() {
            break None;
        }
        let frame = tokio::select! { biased; _ = cancel.changed() => break None, frame = pcm.recv() => frame };
        let Some((bytes, eos)) = frame else {
            break None;
        };
        total += bytes.len();
        if total > 9_600_000 {
            break Some("Microphone recording exceeds 300 seconds".to_owned());
        }
        if !bytes.is_empty() {
            let call = host.call_capability("host.audio", json!({"op":"input_chunk","device_id":device,"session_id":session,"sequence":sequence,"pcm":STANDARD.encode(bytes)}));
            let result = tokio::select! { biased; _ = cancel.changed() => break None, result = call => result };
            if let Err(e) = result {
                break Some(e.to_string());
            }
            sequence += 1;
        }
        if eos {
            let result = host.call_capability("host.audio", json!({"op":"input_end","device_id":device,"session_id":session,"sequence":sequence})).await;
            match result {
                Ok(_) => return,
                Err(e) => break Some(e.to_string()),
            }
        }
    };
    let _ = host
        .call_capability(
            "host.audio",
            json!({"op":"input_cancel","device_id":device,"session_id":session}),
        )
        .await;
    if let Some(message) = failure {
        let _ = updates.send(Update::Failed(epoch, message)).await;
    }
}
pub(crate) fn integer(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .filter(|n| *n <= 9_007_199_254_740_991)
        .or_else(|| {
            value
                .as_f64()
                .filter(|n| {
                    n.is_finite() && *n >= 0.0 && n.fract() == 0.0 && *n <= 9_007_199_254_740_991.0
                })
                .map(|n| n as u64)
        })
}
pub(crate) fn error(code: ErrorCode, message: &str) -> PluginMsg {
    PluginMsg::error(code, clip(message.into(), 200))
}
pub(crate) fn mic_state(state: &str, detail: Option<&str>) -> PluginMsg {
    PluginMsg::MicState {
        state: state.into(),
        detail: detail.map(|s| clip(s.into(), 200)),
    }
}
