//! Bounded BLE authentication smoke probe. No pairing or credential writes.
use crate::provisioning::transport::{self, bounded, Error, Peer, SERVICE};
use btleplug::api::{
    Central, Characteristic, Descriptor, Manager as _, Peripheral as _, ScanFilter, WriteType,
};
use btleplug::platform::{Manager, Peripheral};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;
use zeroize::{Zeroize, Zeroizing};

pub const TOOL_NAME: &str = "minerva_smart_remote_ble_probe";

pub(crate) fn scrub_json(value: &mut Value) {
    match value {
        Value::String(text) => text.zeroize(),
        Value::Array(values) => values.iter_mut().for_each(scrub_json),
        Value::Object(values) => values.values_mut().for_each(scrub_json),
        _ => (),
    }
}

pub fn tool_definition() -> Result<Value, Error> {
    let manifest: Value =
        serde_json::from_str(include_str!("../manifest.json")).map_err(|_| Error::Input)?;
    let tool = &manifest["tools"][0];
    Ok(
        json!({"name": tool["name"], "description": tool["description"], "inputSchema": tool["input_schema"]}),
    )
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
}
impl Operation {
    fn active(&self) -> bool {
        matches!(
            self.stage,
            Stage::Scanning | Stage::Connecting | Stage::Authenticating
        )
    }
    fn status(&self) -> Value {
        json!({"operation_id": self.id, "stage": self.stage, "error": self.error})
    }
}
#[derive(Default)]
struct State {
    next: u64,
    operation: Option<Operation>,
    worker: Option<tokio::task::JoinHandle<()>>,
}
/// Owns one worker; status/cancel do not wait on the adapter or stdio reader.
#[derive(Clone, Default)]
pub struct Probe(Arc<Mutex<State>>);
impl Probe {
    pub fn call(&self, arguments: &mut Value) -> Result<Value, Error> {
        // Take the sole parsed code allocation before any validation failure.
        let code = match arguments.get_mut("code").map(Value::take) {
            Some(Value::String(code)) => Zeroizing::new(code),
            other => {
                if let Some(mut value) = other {
                    scrub_json(&mut value);
                }
                Zeroizing::new(String::new())
            }
        };
        let action = arguments["action"].as_str().ok_or(Error::Input)?;
        let mut state = self.0.lock().map_err(|_| Error::Operation)?;
        match action {
            "start" => {
                let name = arguments["name"].as_str().ok_or(Error::Input)?;
                if !valid_name(name) || code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit())
                {
                    return Err(Error::Input);
                }
                if state.operation.as_ref().is_some_and(Operation::active) {
                    return Err(Error::Busy);
                }
                state.next = state.next.checked_add(1).ok_or(Error::Operation)?;
                let id = state.next;
                let (cancel, cancelled) = watch::channel(false);
                state.operation = Some(Operation {
                    id,
                    stage: Stage::Scanning,
                    error: None,
                    cancel,
                });
                let probe = self.clone();
                let name = name.to_owned();
                state.worker = Some(tokio::spawn(async move {
                    let result = probe.run(id, &name, code, cancelled).await;
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
        name: &str,
        code: Zeroizing<String>,
        mut cancel: watch::Receiver<bool>,
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
                                && (p.local_name.as_deref() == Some(name)
                                    || p.advertisement_name.as_deref() == Some(name))
                        }) {
                            matches.push(peripheral);
                        }
                    }
                    match matches.len() {
                        0 => Err(Error::NotFound),
                        1 => matches.pop().ok_or(Error::NotFound),
                        _ => Err(Error::Ambiguous),
                    }
                },
                &mut cancel,
            )
            .await
        }
        .await;
        let stopped = tokio::time::timeout(Duration::from_secs(3), adapter.stop_scan()).await;
        let peripheral = result?;
        stopped
            .map_err(|_| Error::Timeout)?
            .map_err(|_| Error::Adapter)?;
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
            transport::authenticate(&peer, code, &mut cancel).await
        }
        .await;
        transport::finish_probe(&peer, result, &cancel).await
    }
}
fn valid_name(name: &str) -> bool {
    name.len() == 8
        && name.starts_with("SR2-")
        && name.as_bytes()[4..]
            .iter()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "current_thread")]
    async fn async_operation_receipts_busy_cancel_and_late_completion_are_redacted() {
        let probe = Probe::default();
        let mut start = json!({"action":"start","name":"SR2-A1B2","code":"654321"});
        let receipt = probe.call(&mut start).unwrap();
        assert_eq!(start["code"], Value::Null);
        assert_eq!(receipt["stage"], "scanning");
        assert!(!receipt.to_string().contains("654321"));
        let id = receipt["operation_id"].as_u64().unwrap();
        let mut busy = json!({"action":"start","name":"SR2-A1B2","code":"654321"});
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
            .call(&mut json!({"action":"start","name":"SR2-A1B2","code":"654321"}))
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
    fn input_validation_and_owned_json_scrubbing_cover_nested_strings() {
        let probe = Probe::default();
        for arguments in [
            json!({"code":"654321"}),
            json!({"action":"start","name":"SR2-abcd","code":"654321"}),
            json!({"action":"start","name":"SR2-ABCD","code":{"nested":"654321"}}),
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
}
