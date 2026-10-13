//! Per-authenticated-connection host endpoint. Minerva owns transcription and turns.
use crate::audio::{FrameHeader, Kind};
use crate::host::{HostError, HostEvent, HostLink};
use crate::message::{clip, DeviceMsg, ErrorCode, PluginMsg};
use crate::resample::PcmConverter;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, watch};
use tokio::task::JoinSet;
use tokio::time::Instant;

pub(crate) type RemoteMemory = Arc<Mutex<HashMap<String, (Value, String, Option<String>)>>>;

pub(crate) enum Update {
    Ready(Result<Value, HostError>),
    Started(u64, u64),
    Submitted(String, Result<Value, HostError>),
    Cleared(Result<Value, HostError>),
    Failed(u64, String),
    OutputFailed(String),
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
    startup: Option<tokio::task::JoinHandle<()>>,
    ready: bool,
    pub stopped: bool,
    memory: RemoteMemory,
    generation: u64,
    mic: Option<Mic>,
    target: Value,
    draft: String,
    draft_chat: Option<String>,
    audio_origins: HashMap<u64, String>,
    pub sends: HashMap<u64, String>,
    pending_send: bool,
    pending_clear: bool,
    speaker: Option<Speaker>,
    next_speaker: u8,
    aborts: VecDeque<PluginMsg>,
    barge_frame: Option<Vec<u8>>,
    early: VecDeque<HostEvent>,
}
impl Bridge {
    pub fn new(
        host: Arc<HostLink>,
        id: &str,
        memory: RemoteMemory,
    ) -> (Self, broadcast::Receiver<HostEvent>, mpsc::Receiver<Update>) {
        let events = host.subscribe();
        let (updates, rx) = mpsc::channel(32);
        let remembered = memory
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(id)
            .cloned()
            .unwrap_or((Value::Null, String::new(), None));
        let mut b = Self {
            host,
            device: format!("remote_{id}"),
            updates,
            tasks: JoinSet::new(),
            startup: None,
            ready: false,
            stopped: false,
            memory,
            generation: 0,
            mic: None,
            target: remembered.0,
            draft: remembered.1,
            draft_chat: remembered.2,
            audio_origins: HashMap::new(),
            sends: HashMap::new(),
            pending_send: false,
            pending_clear: false,
            speaker: None,
            next_speaker: 0,
            aborts: VecDeque::new(),
            barge_frame: None,
            early: VecDeque::new(),
        };
        let (host, device, tx) = (b.host.clone(), b.device.clone(), b.updates.clone());
        b.startup = Some(tokio::spawn(async move {
            let result = async {
                host.call_capability("host.audio", json!({"op":"register","device_id":device,"label":"Smart Remote","input":true,"output":true})).await?;
                host.call_capability("host.audio", json!({"op":"availability","device_id":device,"available":true})).await?;
                host.call_capability("host.chat.active", json!({})).await
            }.await;
            let _ = tx.send(Update::Ready(result)).await;
        }));
        (b, events, rx)
    }
    pub fn update(&mut self, update: Update) -> Vec<PluginMsg> {
        match update {
            Update::OutputFailed(message) => {
                if permission_failure(&message) {
                    self.stopped = true;
                }
                vec![error(ErrorCode::TtsFailed, &message)]
            }
            Update::Ready(Ok(target)) => {
                self.ready = true;
                if target["chat_id"]
                    .as_str()
                    .is_some_and(|s| s.is_empty() || s.len() > 128)
                {
                    self.stopped = true;
                    return vec![error(ErrorCode::NoTarget, "Invalid target chat")];
                }
                self.target = target;
                vec![
                    self.target_message(),
                    PluginMsg::Draft {
                        text: self.draft.clone(),
                    },
                ]
            }
            Update::Ready(Err(e)) => {
                self.stopped = true;
                vec![error(ErrorCode::Internal, &e.to_string())]
            }
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
                    if permission_failure(&message) {
                        self.stopped = true;
                    }
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
                            self.audio_origins.insert(id, chat.clone());
                            if self.audio_origins.len() > 128 {
                                if let Some(old) = self.audio_origins.keys().copied().min() {
                                    self.audio_origins.remove(&old);
                                }
                            }
                            self.sends.insert(id, chat);
                            self.draft.clear();
                            self.draft_chat = None;
                            vec![PluginMsg::Draft {
                                text: String::new(),
                            }]
                        }
                        None => vec![error(
                            ErrorCode::SendFailed,
                            "Host did not return a send ID",
                        )],
                    },
                    Err(e) => {
                        if permission_failure(&e.to_string()) {
                            self.stopped = true;
                        }
                        vec![error(
                            if e.to_string().contains("target_changed") {
                                ErrorCode::TargetChanged
                            } else {
                                ErrorCode::SendFailed
                            },
                            &e.to_string(),
                        )]
                    }
                }
            }
            Update::Cleared(Ok(_)) => {
                self.pending_clear = false;
                self.draft.clear();
                self.draft_chat = None;
                vec![PluginMsg::Draft {
                    text: String::new(),
                }]
            }
            Update::Cleared(Err(e)) => {
                self.pending_clear = false;
                if permission_failure(&e.to_string()) {
                    self.stopped = true;
                }
                vec![error(ErrorCode::Internal, &e.to_string())]
            }
        }
    }
    pub fn on_text(&mut self, msg: DeviceMsg) -> Vec<PluginMsg> {
        match msg {
            DeviceMsg::SpeakDone {
                stream_id,
                ok,
                last_seq,
                error: reason,
            } => {
                let Some(s) = &self.speaker else {
                    return vec![];
                };
                if s.wire != stream_id {
                    return vec![];
                }
                let valid = if ok {
                    s.eos.is_some() && last_seq == s.eos
                } else {
                    last_seq.is_none()
                        || last_seq.zip(s.last).is_some_and(|(got, sent)| got <= sent)
                };
                if !valid {
                    return vec![error(
                        ErrorCode::TtsFailed,
                        "Invalid speaker completion sequence",
                    )];
                }
                let host_stream = s.host;
                self.speaker = None;
                self.complete(
                    host_stream,
                    ok,
                    reason.as_deref().unwrap_or("Speaker playback failed"),
                );
                if ok {
                    vec![]
                } else {
                    vec![error(
                        ErrorCode::TtsFailed,
                        reason.as_deref().unwrap_or("Speaker playback failed"),
                    )]
                }
            }
            DeviceMsg::PttDown { stream } => {
                self.barge_in();
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
                if !self.draft.is_empty() && self.draft_chat.as_deref() != Some(chat.as_str()) {
                    return vec![error(
                        ErrorCode::TargetChanged,
                        "Target changed; draft retained",
                    )];
                }
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
                let cancelled = self.mic.is_some();
                self.cancel_mic();
                self.pending_clear = true;
                let (host, tx) = (self.host.clone(), self.updates.clone());
                self.tasks.spawn(async move {
                    let r = host
                        .call_capability("host.chat.input", json!({"op":"clear"}))
                        .await;
                    let _ = tx.send(Update::Cleared(r)).await;
                });
                if cancelled {
                    vec![mic_state("idle", None)]
                } else {
                    vec![]
                }
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
                if !self.draft.is_empty() && self.draft_chat.as_deref() != Some(chat.as_str()) {
                    return vec![error(
                        ErrorCode::TargetChanged,
                        "Target changed; draft retained",
                    )];
                }
                if self.sends.len() >= 128 {
                    return vec![error(ErrorCode::Busy, "Too many outstanding remote turns")];
                }
                if self.draft.is_empty() {
                    return vec![error(ErrorCode::EmptyDraft, "Draft is empty")];
                }
                if chat.len() > 128 {
                    return vec![error(ErrorCode::NoTarget, "Invalid target chat")];
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
            m.started = Instant::now();
        }
        if eos {
            vec![mic_state("transcribing", None)]
        } else {
            vec![]
        }
    }
    pub fn event(&mut self, event: HostEvent) -> Vec<PluginMsg> {
        let p = &event.payload;
        match event.name.as_str() {
            "voice.audio" if p["device_id"].as_str() == Some(self.device.as_str()) => {
                self.audio_event(event)
            }
            "chat.active_changed" => {
                if self
                    .mic
                    .as_ref()
                    .is_some_and(|m| p["chat_id"].as_str() != Some(m.chat.as_str()))
                {
                    self.cancel_mic();
                    self.aborts
                        .push_back(mic_state("error", Some("target_changed")));
                }
                if p["chat_id"]
                    .as_str()
                    .is_some_and(|s| s.len() > 128 || s.is_empty())
                {
                    return vec![error(ErrorCode::NoTarget, "Invalid target chat")];
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
                        self.draft_chat = Some(m.chat.clone());
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
                let Some(chat) = self.sends.get(&id) else {
                    if self.pending_send && self.early.len() < 64 {
                        self.early.push_back(event);
                    }
                    return vec![];
                };
                if p["chat_id"].as_str() != Some(chat.as_str()) {
                    return vec![];
                }
                let chat = chat.clone();
                self.sends.remove(&id);
                vec![PluginMsg::Reply {
                    chat_id: chat.clone(),
                    text: clip(p["text"].as_str().unwrap_or("").into(), 6000),
                    outcome: match p["outcome"].as_str() {
                        Some("ok") => "ok",
                        Some("cancelled") => "cancelled",
                        _ => "error",
                    }
                    .into(),
                }]
            }
            _ => vec![],
        }
    }
    pub fn take_early(&mut self) -> Vec<HostEvent> {
        self.early.drain(..).collect()
    }
    pub fn tick(&mut self) -> Vec<PluginMsg> {
        if self
            .speaker
            .as_ref()
            .is_some_and(|s| s.expires.is_some_and(|d| Instant::now() >= d))
        {
            self.cancel_output("Speaker completion unknown: no drain acknowledgement");
            return vec![error(ErrorCode::TtsFailed, "Speaker completion unknown")];
        }
        let mut failures = Vec::new();
        while let Some(r) = self.tasks.try_join_next() {
            if let Err(e) = r {
                failures.push(error(ErrorCode::Internal, "Host task failed"));
                log::error!("Host task failed: {e}");
            }
        }
        if self.mic.as_ref().is_some_and(|m| {
            m.started.elapsed() >= Duration::from_secs(if m.ended { 125 } else { 300 })
        }) {
            let detail = if self.mic.as_ref().is_some_and(|m| m.ended) {
                "transcribe_timeout"
            } else {
                "too_long"
            };
            self.cancel_mic();
            failures.push(mic_state("error", Some(detail)));
        }
        failures
    }
    pub fn cancel_mic(&mut self) {
        if let Some(m) = self.mic.take() {
            let _ = m.cancel.send(true);
            if m.ended {
                if let Some(session) = m.session {
                    let (host, device) = (self.host.clone(), self.device.clone());
                    self.tasks.spawn(async move { let _ = host.call_capability("host.audio", json!({"op":"input_cancel","device_id":device,"session_id":session})).await; });
                }
            }
        }
    }
    pub fn remember(&self) {
        self.memory
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(
                self.device.trim_start_matches("remote_").into(),
                (
                    self.target.clone(),
                    self.draft.clone(),
                    self.draft_chat.clone(),
                ),
            );
    }
    pub async fn close(&mut self, current: bool) {
        if current {
            self.remember();
        }
        self.cancel_mic();
        self.cancel_output("Remote disconnected");
        if let Some(startup) = self.startup.take() {
            let _ = startup.await;
        }
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
    fn complete(&mut self, stream: u64, success: bool, message: &str) {
        let (host, device, message) = (
            self.host.clone(),
            self.device.clone(),
            clip(message.into(), 200),
        );
        let updates = self.updates.clone();
        self.tasks.spawn(async move {
            if let Err(e) = host.call_capability("host.audio", json!({"op":"output_complete","device_id":device,"stream_id":stream,"success":success,"error_message":message})).await {
                let _ = updates.send(Update::OutputFailed(e.to_string())).await;
                log::warn!("Speaker completion refused: {e}");
            }
        });
    }
    pub fn barge_in(&mut self) {
        if let Some(s) = self.speaker.take() {
            let frame = FrameHeader {
                kind: Kind::Speaker,
                eos: true,
                stream: s.wire,
                seq: s.sequence,
            }
            .encode()
            .to_vec();
            if s.eos.is_none() {
                self.barge_frame = Some(frame);
            }
            self.complete(s.host, false, "Interrupted by microphone");
        }
    }
    pub fn cancel_output(&mut self, message: &str) {
        if let Some(s) = self.speaker.take() {
            let reason = match message {
                "Remote disconnected" | "Plugin stopping" => "plugin_stopping",
                "Minerva cancelled speech"
                | "Replaced by newer speech"
                | "Interrupted by microphone" => "host_cancel",
                _ => "tts_failed",
            };
            self.aborts.push_back(PluginMsg::SpeakAborted {
                code: "speak_aborted".into(),
                stream_id: s.wire,
                reason: reason.into(),
                message: clip(message.into(), 200),
            });
            self.complete(s.host, false, message);
        }
    }
    pub fn take_controls(&mut self) -> Vec<PluginMsg> {
        self.aborts.drain(..).collect()
    }
    fn audio_event(&mut self, event: HostEvent) -> Vec<PluginMsg> {
        let p = &event.payload;
        let Some(stream) = integer(&p["stream_id"]).filter(|n| *n > 0) else {
            return vec![error(ErrorCode::TtsFailed, "Invalid host audio stream ID")];
        };
        if p["op"] == "begin" {
            let origin = &p["origin"];
            let kind = origin["kind"].as_str().unwrap_or("");
            let chat = if kind == "turn" {
                let Some(send) = integer(&origin["send_id"]) else {
                    self.complete(stream, false, "Missing turn origin");
                    return vec![];
                };
                let owned = self
                    .audio_origins
                    .get(&send)
                    .filter(|chat| origin["chat_id"].as_str() == Some(chat.as_str()));
                let Some(chat) = owned else {
                    if self.pending_send && self.early.len() < 64 {
                        self.early.push_back(event);
                    } else {
                        self.complete(stream, false, "Audio turn was not sent by this remote");
                    }
                    return vec![];
                };
                Some(chat.clone())
            } else if kind == "explicit" {
                None
            } else {
                self.complete(stream, false, "Unknown audio origin");
                return vec![];
            };
            let rate = integer(&p["sample_rate"]).and_then(|r| u32::try_from(r).ok());
            if p["format"] != "pcm_s16le" || p["channels"] != 1 || !self.ready {
                self.complete(
                    stream,
                    false,
                    "Unsupported PCM format or unavailable endpoint",
                );
                return vec![error(ErrorCode::TtsFailed, "Unsupported PCM format")];
            }
            let converter = match rate
                .and_then(|r| PcmConverter::new(r, p["volume"].as_f64().unwrap_or(1.0)).ok())
            {
                Some(c) => c,
                None => {
                    self.complete(stream, false, "Unsupported PCM rate or volume");
                    return vec![error(
                        ErrorCode::TtsFailed,
                        "Unsupported PCM rate or volume",
                    )];
                }
            };
            self.cancel_output("Replaced by newer speech");
            self.next_speaker = self.next_speaker.wrapping_add(1);
            self.speaker = Some(Speaker {
                host: stream,
                wire: self.next_speaker,
                converter,
                queue: VecDeque::new(),
                sequence: 0,
                host_sequence: 0,
                input_bytes: 0,
                converted_bytes: 0,
                ended: false,
                eos: None,
                last: None,
                due: Instant::now(),
                expires: None,
            });
            return vec![PluginMsg::Speak {
                stream: self.next_speaker,
                origin: kind.into(),
                chat_id: chat,
            }];
        }
        // Audio belonging to an early begin is held until submit returns its exact send ID.
        if self.speaker.as_ref().map(|s| s.host) != Some(stream) {
            if self.pending_send
                && self.early.iter().any(|e| {
                    e.name == "voice.audio" && integer(&e.payload["stream_id"]) == Some(stream)
                })
                && self.early.len() < 64
            {
                self.early.push_back(event);
            }
            return vec![];
        }
        if p["op"] == "cancel" || p["op"] == "error" {
            self.cancel_output(if p["op"] == "error" {
                "Minerva synthesis failed"
            } else {
                "Minerva cancelled speech"
            });
            return vec![error(ErrorCode::TtsFailed, "Speech cancelled")];
        }
        let Some(s) = self.speaker.as_mut() else {
            return vec![];
        };
        let end = p["op"] == "end";
        let result = (|| -> Result<(), String> {
            if s.ended || integer(&p["sequence"]) != Some(s.host_sequence) {
                return Err("Host PCM sequence/EOS mismatch".into());
            }
            let bytes = if end {
                Vec::new()
            } else if p["op"] == "chunk" {
                let encoded = p["pcm"].as_str().ok_or("Missing PCM payload")?;
                if encoded.len() > 8536 {
                    return Err("PCM chunk exceeds host limit".into());
                }
                let bytes = STANDARD
                    .decode(encoded)
                    .map_err(|_| "Malformed PCM base64")?;
                if bytes.len() > 6400 {
                    return Err("PCM chunk exceeds host limit".into());
                }
                bytes
            } else {
                return Err("Unknown host audio operation".into());
            };
            s.input_bytes += bytes.len();
            if s.input_bytes > 20 * 1024 * 1024 {
                return Err("Host speech exceeds PCM limit".into());
            }
            let output = s.converter.push(&bytes, end).map_err(|e| e.to_string())?;
            s.converted_bytes += output.len();
            if s.converted_bytes > 20 * 1024 * 1024 {
                return Err("Remote speech exceeds PCM limit".into());
            }
            s.queue.extend(output);
            s.ended = end;
            if !end {
                s.host_sequence += 1;
            }
            Ok(())
        })();
        if let Err(message) = result {
            self.cancel_output(&message);
            vec![error(ErrorCode::TtsFailed, &message)]
        } else {
            vec![]
        }
    }
    pub fn take_barge_frame(&mut self) -> Option<Vec<u8>> {
        self.barge_frame.take()
    }
    pub fn speaker_frame(&mut self) -> Option<Vec<u8>> {
        let s = self.speaker.as_mut()?;
        if s.expires.is_some_and(|deadline| Instant::now() >= deadline) {
            return None;
        }
        if s.eos.is_some() || Instant::now() < s.due {
            return None;
        }
        if s.queue.len() < 640 && !s.ended {
            return None;
        }
        let count = s.queue.len().min(640);
        let eos = s.ended && count == s.queue.len();
        if count == 0 && !eos {
            return None;
        }
        let seq = s.sequence;
        let mut frame = FrameHeader {
            kind: Kind::Speaker,
            eos,
            stream: s.wire,
            seq,
        }
        .encode()
        .to_vec();
        frame.extend(s.queue.drain(..count));
        s.last = Some(seq);
        s.sequence = s.sequence.wrapping_add(1);
        // Absolute media clock: timer jitter cannot skip the next frame deadline.
        s.due += Duration::from_secs_f64(count as f64 / 32000.0);
        if eos {
            s.eos = Some(seq);
            s.expires = Some(Instant::now() + Duration::from_secs(300));
        }
        Some(frame)
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
            let call = host.call_capability("host.audio", json!({"op":"input_end","device_id":device,"session_id":session,"sequence":sequence}));
            let result = tokio::select! { biased; _ = cancel.changed() => break None, result = call => result };
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

struct Speaker {
    host: u64,
    wire: u8,
    converter: PcmConverter,
    queue: VecDeque<u8>,
    sequence: u16,
    host_sequence: u64,
    input_bytes: usize,
    converted_bytes: usize,
    ended: bool,
    eos: Option<u16>,
    last: Option<u16>,
    due: Instant,
    expires: Option<Instant>,
}

fn permission_failure(message: &str) -> bool {
    let m = message.to_ascii_lowercase();
    m.contains("not granted") || m.contains("permission_denied") || m.contains("revoked")
}
