//! Bounded BLE authentication and complete provisioning operations.
use crate::provisioning::transport::{self, bounded, Error, Peer, SERVICE};
use crate::provisioning::workflow::{self, Credentials, Job, Progress};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use btleplug::api::{
    Central, Characteristic, Descriptor, Manager as _, Peripheral as _, ScanFilter, WriteType,
};
use btleplug::platform::{Manager, Peripheral};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use zeroize::{Zeroize, Zeroizing};

const REMOTE_NAME: &str = "smart-remote";

pub const TOOL_NAME: &str = "minerva_smart_remote_ble_probe";
pub const PAIRING_TOOL: &str = "minerva_smart_remote_pairing";

pub(crate) fn scrub_json(value: &mut Value) {
    match value {
        Value::String(text) => text.zeroize(),
        Value::Array(values) => values.iter_mut().for_each(scrub_json),
        Value::Object(values) => values.values_mut().for_each(scrub_json),
        _ => (),
    }
}

pub fn tool_definitions() -> Result<Vec<Value>, Error> {
    let manifest: Value =
        serde_json::from_str(include_str!("../manifest.json")).map_err(|_| Error::Input)?;
    Ok(manifest["tools"].as_array().ok_or(Error::Input)?.iter().map(|tool|
        json!({"name": tool["name"], "description": tool["description"], "inputSchema": tool["input_schema"]})).collect())
}

struct Native(Peripheral);
impl Peer for Native {
    fn characteristics(&self) -> BTreeSet<Characteristic> {
        self.0.characteristics()
    }
    async fn descriptor(&self, descriptor: &Descriptor) -> Result<Vec<u8>, Error> {
        self.0
            .read_descriptor(descriptor)
            .await
            .map_err(|_| Error::Transport)
    }
    async fn write(&self, characteristic: &Characteristic, bytes: &[u8]) -> Result<(), Error> {
        self.0
            .write(characteristic, bytes, WriteType::WithResponse)
            .await
            .map_err(|_| Error::Transport)
    }
    async fn read(&self, characteristic: &Characteristic) -> Result<Vec<u8>, Error> {
        self.0
            .read(characteristic)
            .await
            .map_err(|_| Error::Transport)
    }
    async fn disconnect(&self) -> Result<(), Error> {
        if !self.0.is_connected().await.map_err(|_| Error::Transport)? {
            return Ok(());
        }
        self.0.disconnect().await.map_err(|_| Error::Transport)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
enum Stage {
    Scanning,
    Connecting,
    Authenticating,
    Authenticated,
    Failed,
    Cancelled,
}
struct Operation {
    id: u64,
    stage: Stage,
    error: Option<Error>,
    cancel: watch::Sender<bool>,
    input: Option<mpsc::Sender<Credentials>>,
    progress: Progress,
}
impl Operation {
    fn active(&self) -> bool {
        matches!(
            self.stage,
            Stage::Scanning | Stage::Connecting | Stage::Authenticating
        ) || self.progress.persistence.state() == 1
            || matches!(
                self.progress.stage,
                "scanning_wifi"
                    | "awaiting_wifi"
                    | "applying_wifi"
                    | "connecting_wifi"
                    | "waiting_lan"
            )
    }
    fn status(&self) -> Value {
        json!({"ok": true, "operation_id": self.id, "stage": self.stage, "error": self.error, "pairing": self.progress})
    }
}
#[derive(Default)]
struct State {
    next: u64,
    operation: Option<Operation>,
    worker: Option<tokio::task::JoinHandle<()>>,
    context: Option<(Arc<crate::store::TokenStore>, u16)>,
    host: Option<String>,
}
/// Owns one worker; status/cancel do not wait on the adapter or stdio reader.
#[derive(Clone, Default)]
pub struct Probe(Arc<Mutex<State>>);
struct WorkerGuard {
    probe: Probe,
    id: u64,
}
impl Drop for WorkerGuard {
    fn drop(&mut self) {
        if let Ok(mut state) = self.probe.0.lock() {
            if let Some(operation) = state
                .operation
                .as_mut()
                .filter(|o| o.id == self.id && o.active())
            {
                operation.stage = Stage::Failed;
                operation.error = Some(Error::Interrupted);
                operation.progress.stage = "";
            }
        }
    }
}
impl Probe {
    pub fn configure(&self, store: Arc<crate::store::TokenStore>, port: u16) {
        if let Ok(mut state) = self.0.lock() {
            state.context = Some((store, port));
            // UDP connect only selects an OS route; no datagram is sent.
            state.host = std::net::UdpSocket::bind("0.0.0.0:0")
                .and_then(|socket| {
                    socket.connect("1.1.1.1:9")?;
                    socket.local_addr()
                })
                .ok()
                .map(|address| address.ip())
                .filter(|ip| !ip.is_loopback() && !ip.is_unspecified())
                .map(|ip| ip.to_string());
        }
    }
    pub fn pairing(&self, arguments: &mut Value) -> Result<Value, Error> {
        let password = take_secret(arguments, "password");
        match arguments["action"].as_str() {
            Some("describe" | "status" | "cancel") => {
                let describe = arguments["action"] == "describe";
                if !describe {
                    self.call_mode(arguments, true)?;
                }
                let state = self.0.lock().map_err(|_| Error::Operation)?;
                let mut status = state
                    .operation
                    .as_ref()
                    .map(Operation::status)
                    .unwrap_or(json!({}));
                if matches!(status["pairing"]["persistence"].as_str(), Some("stored")) {
                    if let Some(id) = status["pairing"]["device_id"].as_str() {
                        if let Some((store, _)) = &state.context {
                            match store.try_record(id) {
                                Some(Some(record)) if record.confirmed => {
                                    status["pairing"]["stage"] = json!("confirmed")
                                }
                                None => status["pairing"]["confirmation_pending"] = json!(true),
                                _ => status["pairing"]["stage"] = json!("unconfirmed"),
                            }
                        }
                    }
                }
                if !describe {
                    return Ok(status);
                }
                Ok(
                    json!({"host": state.host, "port": state.context.as_ref().map(|c| c.1), "operation": status}),
                )
            }
            Some("apply") => {
                let mut state = self.0.lock().map_err(|_| Error::Operation)?;
                let operation = state
                    .operation
                    .as_mut()
                    .filter(|o| Some(o.id) == arguments["operation_id"].as_u64())
                    .ok_or(Error::Operation)?;
                if operation.progress.stage != "awaiting_wifi" {
                    return Err(Error::Busy);
                }
                let ssid = Zeroizing::new(
                    URL_SAFE_NO_PAD
                        .decode(arguments["ssid"].as_str().ok_or(Error::Input)?)
                        .map_err(|_| Error::Input)?,
                );
                let host = arguments["host"].as_str().ok_or(Error::Input)?.to_owned();
                let port = arguments["port"]
                    .as_u64()
                    .and_then(|p| u16::try_from(p).ok())
                    .filter(|p| *p != 0)
                    .ok_or(Error::Input)?;
                if ssid.is_empty()
                    || ssid.len() > 32
                    || ssid.contains(&0)
                    || password.len() > 64
                    || password.as_bytes().contains(&0)
                {
                    return Err(Error::Input);
                }
                operation
                    .input
                    .as_ref()
                    .ok_or(Error::Operation)?
                    .try_send(Credentials {
                        ssid,
                        password,
                        host,
                        port,
                    })
                    .map_err(|_| Error::Busy)?;
                operation.progress.stage = "applying_wifi";
                operation.progress.error = None;
                Ok(operation.status())
            }
            _ => self.call_mode(arguments, true),
        }
    }
    pub fn call(&self, arguments: &mut Value) -> Result<Value, Error> {
        self.call_mode(arguments, false)
    }
    fn call_mode(&self, arguments: &mut Value, pairing: bool) -> Result<Value, Error> {
        // Take the sole parsed code allocation before any validation failure.
        let code = take_secret(arguments, "code");
        let action = arguments["action"].as_str().ok_or(Error::Input)?;
        let mut state = self.0.lock().map_err(|_| Error::Operation)?;
        match action {
            "start" => {
                if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) {
                    return Err(Error::Input);
                }
                if state.operation.as_ref().is_some_and(Operation::active) {
                    return Err(Error::Busy);
                }
                let runtime =
                    tokio::runtime::Handle::try_current().map_err(|_| Error::Operation)?;
                state.next = state.next.checked_add(1).ok_or(Error::Operation)?;
                let id = state.next;
                let (cancel, cancelled) = watch::channel(false);
                let (input, receiver) = mpsc::channel(1);
                let job = if pairing {
                    Some(Job {
                        store: state.context.as_ref().ok_or(Error::Operation)?.0.clone(),
                        input: receiver,
                    })
                } else {
                    None
                };
                state.operation = Some(Operation {
                    id,
                    stage: Stage::Scanning,
                    error: None,
                    cancel,
                    input: pairing.then_some(input),
                    progress: Progress::default(),
                });
                let probe = self.clone();
                // Captured before polling so abort/drop of an unpolled worker clears Busy.
                let guard = WorkerGuard {
                    probe: self.clone(),
                    id,
                };
                state.worker = Some(runtime.spawn(async move {
                    let _guard = guard;
                    let result = probe.run(id, code, cancelled, job).await;
                    probe.finish(id, result);
                }));
                Ok(state.operation.as_ref().ok_or(Error::Operation)?.status())
            }
            "status" | "cancel" => {
                let id = arguments["operation_id"].as_u64().ok_or(Error::Input)?;
                let operation = state
                    .operation
                    .as_ref()
                    .filter(|o| o.id == id)
                    .ok_or(Error::Operation)?;
                if action == "cancel" && operation.active() {
                    let _ = operation.cancel.send(true);
                }
                Ok(operation.status())
            }
            _ => Err(Error::Input),
        }
    }
    pub fn cancel(&self) {
        if let Ok(state) = self.0.lock() {
            if let Some(operation) = &state.operation {
                let _ = operation.cancel.send(true);
            }
        }
    }
    pub async fn shutdown(&self) {
        self.cancel();
        let worker = self.0.lock().ok().and_then(|mut state| state.worker.take());
        if let Some(mut worker) = worker {
            if tokio::time::timeout(Duration::from_secs(4), &mut worker)
                .await
                .is_err()
            {
                worker.abort();
                let _ = worker.await;
            }
        }
    }
    fn stage(&self, id: u64, stage: Stage) {
        if let Ok(mut state) = self.0.lock() {
            if let Some(operation) = state.operation.as_mut().filter(|o| o.id == id) {
                operation.stage = stage;
            }
        }
    }
    fn finish(&self, id: u64, result: Result<(), Error>) {
        if let Ok(mut state) = self.0.lock() {
            if let Some(operation) = state.operation.as_mut().filter(|o| o.id == id) {
                operation.error = result.err();
                if operation.error.is_some() {
                    operation.progress.stage = "";
                }
                operation.stage = match operation.error {
                    None => Stage::Authenticated,
                    Some(Error::Cancelled) => Stage::Cancelled,
                    Some(_) => Stage::Failed,
                };
            }
        }
    }
    async fn run(
        &self,
        id: u64,
        code: Zeroizing<String>,
        mut cancel: watch::Receiver<bool>,
        job: Option<Job>,
    ) -> Result<(), Error> {
        let manager = bounded(
            async { Manager::new().await.map_err(|_| Error::Adapter) },
            &mut cancel,
        )
        .await?;
        let adapters = bounded(
            async { manager.adapters().await.map_err(|_| Error::Adapter) },
            &mut cancel,
        )
        .await?;
        let adapter = adapters.into_iter().next().ok_or(Error::Adapter)?;
        // Attempt stop even if start was cancelled after an OS-side effect.
        let result = async {
            bounded(
                async {
                    adapter
                        .start_scan(ScanFilter {
                            services: vec![SERVICE],
                        })
                        .await
                        .map_err(|_| Error::Adapter)
                },
                &mut cancel,
            )
            .await?;
            bounded(
                async {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    let mut matches = Vec::new();
                    for peripheral in adapter.peripherals().await.map_err(|_| Error::Adapter)? {
                        let properties = peripheral
                            .properties()
                            .await
                            .map_err(|_| Error::Transport)?;
                        if properties.is_some_and(|p| {
                            p.services.contains(&SERVICE)
                                && (p.local_name.as_deref() == Some(REMOTE_NAME)
                                    || p.advertisement_name.as_deref() == Some(REMOTE_NAME))
                        }) {
                            matches.push(peripheral);
                        }
                    }
                    if matches.is_empty() {
                        Err(Error::NotFound)
                    } else {
                        Ok(matches)
                    }
                },
                &mut cancel,
            )
            .await
        }
        .await;
        let stopped = tokio::time::timeout(Duration::from_secs(3), adapter.stop_scan()).await;
        let peripherals = result?;
        stopped
            .map_err(|_| Error::Timeout)?
            .map_err(|_| Error::Adapter)?;
        // The shared advertised name discovers candidates; the code authenticates one.
        let mut last_error = Error::Authentication;
        for peripheral in peripherals {
            self.stage(id, Stage::Connecting);
            let peer = Native(peripheral);
            let result = async {
                bounded(
                    async { peer.0.connect().await.map_err(|_| Error::Transport) },
                    &mut cancel,
                )
                .await?;
                bounded(
                    async {
                        peer.0
                            .discover_services()
                            .await
                            .map_err(|_| Error::Transport)
                    },
                    &mut cancel,
                )
                .await?;
                self.stage(id, Stage::Authenticating);
                transport::authenticate(&peer, code.clone(), &mut cancel).await
            }
            .await;
            let mut session = match result {
                Ok(session) => session,
                Err(error) => {
                    // Cleanup completes before attempting the next advertised remote.
                    tokio::time::timeout(Duration::from_secs(3), peer.disconnect())
                        .await
                        .map_err(|_| Error::Timeout)??;
                    last_error = error;
                    if last_error == Error::Cancelled {
                        return Err(last_error);
                    }
                    continue;
                }
            };
            drop(code);
            let result = async {
                if let Some(job) = job {
                    workflow::run(
                        &peer,
                        &mut session,
                        job,
                        REMOTE_NAME,
                        &mut cancel,
                        |progress| {
                            if let Ok(mut state) = self.0.lock() {
                                if let Some(operation) =
                                    state.operation.as_mut().filter(|o| o.id == id)
                                {
                                    operation.progress = progress;
                                }
                            }
                        },
                    )
                    .await?;
                }
                Ok(session)
            }
            .await;
            return transport::finish_probe(&peer, result, &cancel).await;
        }
        Err(last_error)
    }
}
fn take_secret(arguments: &mut Value, key: &str) -> Zeroizing<String> {
    match arguments.get_mut(key).map(Value::take) {
        Some(Value::String(text)) => Zeroizing::new(text),
        other => {
            if let Some(mut value) = other {
                scrub_json(&mut value);
            }
            Zeroizing::new(String::new())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "current_thread")]
    async fn worker_drop_panic_and_normal_finish_clear_busy_without_clobbering_results() {
        for panic in [false, true] {
            let probe = Probe::default();
            let (cancel, _) = watch::channel(false);
            probe.0.lock().unwrap().operation = Some(Operation {
                id: 7,
                stage: Stage::Authenticating,
                error: None,
                cancel,
                input: None,
                progress: Progress::default(),
            });
            let guard = WorkerGuard {
                probe: probe.clone(),
                id: 7,
            };
            let worker = tokio::spawn(async move {
                let _guard = guard;
                if panic {
                    panic!("synthetic worker failure");
                }
                std::future::pending::<()>().await;
            });
            if !panic {
                worker.abort();
            }
            assert!(worker.await.is_err());
            let status = probe
                .call(&mut json!({"action":"status","operation_id":7}))
                .unwrap();
            assert_eq!(status["stage"], "failed");
            assert_eq!(status["error"], "interrupted");
            assert!(!probe.0.lock().unwrap().operation.as_ref().unwrap().active());
            let (cancel, _) = watch::channel(false);
            probe.0.lock().unwrap().operation = Some(Operation {
                id: 8,
                stage: Stage::Authenticating,
                error: None,
                cancel,
                input: None,
                progress: Progress::default(),
            });
            drop(WorkerGuard {
                probe: probe.clone(),
                id: 7,
            });
            assert!(probe.0.lock().unwrap().operation.as_ref().unwrap().active());
            probe.finish(8, Ok(()));
            drop(WorkerGuard {
                probe: probe.clone(),
                id: 8,
            });
            assert_eq!(
                probe
                    .call(&mut json!({"action":"status","operation_id":8}))
                    .unwrap()["stage"],
                "authenticated"
            );
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn async_operation_receipts_busy_cancel_and_late_completion_are_redacted() {
        let probe = Probe::default();
        let mut start = json!({"action":"start","code":"654321"});
        let receipt = probe.call(&mut start).unwrap();
        assert_eq!(start["code"], Value::Null);
        assert_eq!(receipt["stage"], "scanning");
        assert!(!receipt.to_string().contains("654321"));
        let id = receipt["operation_id"].as_u64().unwrap();
        let mut busy = json!({"action":"start","code":"654321"});
        assert_eq!(probe.call(&mut busy), Err(Error::Busy));
        assert_eq!(busy["code"], Value::Null);
        assert_eq!(
            probe.call(&mut json!({"action":"status","operation_id":id+1})),
            Err(Error::Operation)
        );
        probe
            .call(&mut json!({"action":"cancel","operation_id":id}))
            .unwrap();
        // No await has yielded to the worker: cancellation precedes Manager::new,
        // so this real start/cancel path performs no adapter/radio operation.
        probe.shutdown().await;
        let status = probe
            .call(&mut json!({"action":"status","operation_id":id}))
            .unwrap();
        assert_eq!(status["stage"], "cancelled");
        assert_eq!(status["error"], "cancelled");
        let next = probe
            .call(&mut json!({"action":"start","code":"654321"}))
            .unwrap();
        assert_eq!(next["operation_id"], id + 1);
        probe.finish(id, Ok(())); // Previous worker cannot update its replacement.
        assert_eq!(
            probe
                .call(&mut json!({"action":"status","operation_id":id+1}))
                .unwrap()["stage"],
            "scanning"
        );
        probe.shutdown().await;
    }

    #[test]
    fn pairing_apply_receipts_are_single_use_redacted_and_identity_bound() {
        let probe = Probe::default();
        let (cancel, _cancelled) = watch::channel(false);
        let (input, mut received) = mpsc::channel(1);
        probe.0.lock().unwrap().operation = Some(Operation {
            id: 9,
            stage: Stage::Authenticating,
            error: None,
            cancel,
            input: Some(input),
            progress: Progress {
                stage: "awaiting_wifi",
                error: Some(Error::Wifi),
                ..Default::default()
            },
        });
        let request = || {
            json!({"action":"apply","operation_id":9,"ssid":"bmV0",
            "password":"synthetic-password","host":"192.0.2.1","port":8000})
        };
        let mut invalid = request();
        invalid["operation_id"] = json!(8);
        assert_eq!(probe.pairing(&mut invalid), Err(Error::Operation));
        assert!(invalid["password"].is_null());
        for field in ["ssid", "port"] {
            let mut invalid = request();
            invalid[field] = if field == "ssid" {
                json!("AA")
            } else {
                json!(0)
            };
            assert_eq!(probe.pairing(&mut invalid), Err(Error::Input));
            assert!(invalid["password"].is_null());
        }
        let mut apply = request();
        let receipt = probe.pairing(&mut apply).unwrap();
        assert!(apply["password"].is_null());
        assert_eq!(receipt["pairing"]["stage"], "applying_wifi");
        assert!(receipt["pairing"]["error"].is_null());
        assert!(!receipt.to_string().contains("synthetic-password"));
        let credentials = received.try_recv().unwrap();
        assert_eq!(&*credentials.ssid, b"net");
        assert_eq!(&*credentials.password, "synthetic-password");
        assert_eq!(probe.pairing(&mut request()), Err(Error::Busy));
        probe
            .pairing(&mut json!({"action":"cancel","operation_id":9}))
            .unwrap();
        assert!(*probe
            .0
            .lock()
            .unwrap()
            .operation
            .as_ref()
            .unwrap()
            .cancel
            .borrow());
        probe.finish(8, Err(Error::Store));
        assert_eq!(
            probe
                .pairing(&mut json!({"action":"status","operation_id":9}))
                .unwrap()["pairing"]["stage"],
            "applying_wifi"
        );
    }

    #[test]
    fn pairing_describe_does_not_confirm_staging_and_refreshes_a_late_lan_hello() {
        let data = tempfile::tempdir().unwrap();
        let store = Arc::new(crate::store::TokenStore::open(data.path()).unwrap());
        let id = "aabbccddeeff";
        store.pair(id, "old synthetic token", "remote", 1).unwrap();
        store.confirm(id, "old synthetic token").unwrap();
        let probe = Probe::default();
        probe.configure(store.clone(), 12345);
        let (cancel, _cancelled) = watch::channel(false);
        probe.0.lock().unwrap().operation = Some(Operation {
            id: 2,
            stage: Stage::Authenticating,
            error: None,
            cancel,
            input: None,
            progress: Progress {
                stage: "applying_wifi",
                device_id: Some(id.into()),
                ..Default::default()
            },
        });
        let describe = || probe.pairing(&mut json!({"action":"describe"})).unwrap();
        assert_eq!(describe()["port"], 12345);
        assert_eq!(describe()["operation"]["pairing"]["stage"], "applying_wifi");
        store.pair(id, "new synthetic token", "remote", 2).unwrap();
        {
            let mut state = probe.0.lock().unwrap();
            let operation = state.operation.as_mut().unwrap();
            operation.progress.stage = "unconfirmed";
            operation
                .progress
                .persistence
                .0
                .store(2, std::sync::atomic::Ordering::Release);
        }
        {
            let _store_lock = store.hold_store_lock_for_test();
            assert_eq!(
                describe()["operation"]["pairing"]["confirmation_pending"],
                true
            );
            probe
                .pairing(&mut json!({"action":"status","operation_id":2}))
                .unwrap();
            probe
                .pairing(&mut json!({"action":"cancel","operation_id":2}))
                .unwrap();
        }
        probe.finish(2, Err(Error::Cancelled));
        assert_eq!(describe()["operation"]["pairing"]["stage"], "unconfirmed");
        store.confirm(id, "old synthetic token").unwrap();
        assert_eq!(describe()["operation"]["pairing"]["stage"], "unconfirmed");
        store.confirm(id, "new synthetic token").unwrap();
        let result = describe();
        assert_eq!(result["operation"]["pairing"]["stage"], "confirmed");
        assert!(!result.to_string().contains("synthetic token"));
    }

    #[test]
    fn input_validation_and_owned_json_scrubbing_cover_nested_strings() {
        let probe = Probe::default();
        for arguments in [
            json!({"code":"654321"}),
            json!({"action":"start","code":"12345x"}),
            json!({"action":"start","code":{"nested":"654321"}}),
        ] {
            let mut arguments = arguments;
            assert_eq!(probe.call(&mut arguments), Err(Error::Input));
            assert_eq!(arguments["code"], Value::Null);
        }
        let mut value = json!({"outer":["654321",{"code":"654321"}],"count":3});
        scrub_json(&mut value);
        assert_eq!(value, json!({"outer":["",{"code":""}],"count":3}));
        for error in [
            Error::Input,
            Error::Transport,
            Error::Authentication,
            Error::Cancelled,
        ] {
            assert!(!format!("{error:?} {error}").contains("654321"));
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn owner_input_expiry_is_terminal_and_releases_the_operation_slot() {
        let probe = Probe::default();
        let (cancel, _cancelled) = watch::channel(false);
        probe.0.lock().unwrap().operation = Some(Operation {
            id: 4,
            stage: Stage::Authenticating,
            error: None,
            cancel,
            input: None,
            progress: Progress {
                stage: "awaiting_wifi",
                ..Default::default()
            },
        });
        probe.0.lock().unwrap().next = 4;
        probe.finish(4, Err(Error::InputTimeout));
        let receipt = probe
            .pairing(&mut json!({"action":"status","operation_id":4}))
            .unwrap();
        assert_eq!(receipt["error"], "input_timeout");
        assert!(!probe.0.lock().unwrap().operation.as_ref().unwrap().active());
        let next = probe
            .call(&mut json!({"action":"start","code":"654321"}))
            .unwrap();
        assert_eq!(next["operation_id"], 5);
        // Cancel before yielding: exercise slot reuse without touching an adapter.
        probe.shutdown().await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_dropped_worker_keeps_its_slot_until_the_real_store_write_settles() {
        let data = tempfile::tempdir().unwrap();
        let store = Arc::new(crate::store::TokenStore::open(data.path()).unwrap());
        let (locked, lock_ready) = std::sync::mpsc::channel();
        let (release, released) = std::sync::mpsc::channel();
        let held_store = store.clone();
        let holder = std::thread::spawn(move || {
            let _lock = held_store.hold_store_lock_for_test();
            locked.send(()).unwrap();
            released.recv().unwrap();
        });
        lock_ready.recv().unwrap();
        let probe = Probe::default();
        probe.configure(store.clone(), 47821);
        let (cancel, _cancelled) = watch::channel(false);
        let progress = Progress {
            stage: "connecting_wifi",
            device_id: Some("aabbccddeeff".into()),
            save_possible: true,
            ..Default::default()
        };
        let persistence = progress.persistence.clone();
        probe.0.lock().unwrap().operation = Some(Operation {
            id: 3,
            stage: Stage::Authenticating,
            error: None,
            cancel,
            input: None,
            progress,
        });
        let guard = WorkerGuard {
            probe: probe.clone(),
            id: 3,
        };
        let writing_store = store.clone();
        let writing = persistence.clone();
        let worker = tokio::spawn(async move {
            let _guard = guard;
            writing
                .pair(
                    writing_store,
                    "aabbccddeeff".into(),
                    Zeroizing::new("synthetic-token".into()),
                    "remote".into(),
                )
                .await
                .unwrap();
        });
        while persistence.state() != 1 {
            tokio::task::yield_now().await;
        }
        worker.abort();
        assert!(worker.await.is_err());
        let status = probe
            .pairing(&mut json!({"action":"status","operation_id":3}))
            .unwrap();
        assert_eq!(status["pairing"]["persistence"], "pending");
        assert_eq!(status["error"], "interrupted");
        assert_eq!(
            probe.pairing(&mut json!({"action":"start","code":"654321"})),
            Err(Error::Busy)
        );
        probe
            .pairing(&mut json!({"action":"cancel","operation_id":3}))
            .unwrap();
        release.send(()).unwrap();
        holder.join().unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while persistence.state() == 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(persistence.state(), 2);
        assert!(store.record("aabbccddeeff").is_some());
        assert!(!probe.0.lock().unwrap().operation.as_ref().unwrap().active());
        assert_eq!(
            probe.pairing(&mut json!({"action":"describe"})).unwrap()["operation"]["pairing"]
                ["stage"],
            "unconfirmed"
        );
        store.confirm("aabbccddeeff", "synthetic-token").unwrap();
        assert_eq!(
            probe
                .pairing(&mut json!({"action":"status","operation_id":3}))
                .unwrap()["pairing"]["stage"],
            "confirmed"
        );
    }
}
