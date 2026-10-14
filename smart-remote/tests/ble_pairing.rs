//! A synthetic BLE device drives the real provisioning owner and real LAN store.
mod common;
use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use btleplug::api::{CharPropFlags, Characteristic, Descriptor};
use prost::Message;
use rand_core::{TryCryptoRng, TryRngCore};
use smart_remote_plugin::{
    provisioning::{
        transport::*,
        wire::*,
        workflow::{self, Credentials, Job},
        Session,
    },
    schema::Schemas,
    server::{Server, ServerConfig},
    store::TokenStore,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::{mpsc, watch};
use uuid::Uuid;
use zeroize::Zeroizing;
#[path = "fixtures/wifi.rs"]
mod oracle;
#[path = "fixtures/security2.rs"]
pub mod security;
const ID: &str = "a4cf12b03e5d";
const SSID: &[u8] = b"synthetic-network";
fn bytes(hex: &str) -> Vec<u8> {
    hex::decode(hex).unwrap()
}
struct Fixed(Vec<u8>);
impl TryRngCore for Fixed {
    type Error = std::io::Error;
    fn try_next_u32(&mut self) -> Result<u32, Self::Error> {
        unreachable!()
    }
    fn try_next_u64(&mut self) -> Result<u64, Self::Error> {
        unreachable!()
    }
    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), Self::Error> {
        dest.copy_from_slice(&self.0);
        Ok(())
    }
}
impl TryCryptoRng for Fixed {}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Case {
    Good,
    Retry,
    MissingNetwork,
    ApplyLostAck,
    WrongKind,
    NonzeroStatus,
    Oversize,
    LostAck,
    Connecting,
    StoreFailure,
    NoLan,
}
struct State {
    reply: Vec<u8>,
    counter: u32,
    handshake: usize,
    endpoints: Vec<String>,
    pages: Vec<(u32, u32)>,
    applies: usize,
    customs: usize,
    resets: usize,
    reads: usize,
    token: Option<Zeroizing<String>>,
}
struct DevicePeer {
    chars: BTreeSet<Characteristic>,
    names: BTreeMap<Uuid, &'static str>,
    cipher: Aes256Gcm,
    state: Mutex<State>,
    case: Case,
}
fn nonce(counter: u32) -> Nonce<aes_gcm::aead::consts::U12> {
    let mut bytes = [0, 1, 2, 3, 4, 5, 6, 7, 0, 0, 0, 0];
    bytes[8..].copy_from_slice(&counter.to_be_bytes());
    Nonce::from(bytes)
}
impl DevicePeer {
    fn new(case: Case) -> Self {
        let mut chars = BTreeSet::new();
        let mut names = BTreeMap::new();
        for (index, name) in [
            "prov-session",
            "proto-ver",
            "prov-scan",
            "prov-config",
            "prov-ctrl",
            "minerva-config",
        ]
        .iter()
        .enumerate()
        {
            let uuid = Uuid::from_u128(0xbbbbbbbb_0000_4444_8888_000000000001 + index as u128);
            chars.insert(Characteristic {
                uuid,
                service_uuid: SERVICE,
                properties: CharPropFlags::READ | CharPropFlags::WRITE,
                descriptors: BTreeSet::from([Descriptor {
                    uuid: DESCRIPTION,
                    service_uuid: SERVICE,
                    characteristic_uuid: uuid,
                }]),
            });
            names.insert(uuid, *name);
        }
        Self {
            chars,
            names,
            cipher: Aes256Gcm::new_from_slice(&bytes(security::VECTORS[0].session_key)[..32])
                .unwrap(),
            case,
            state: Mutex::new(State {
                reply: Vec::new(),
                counter: 1,
                handshake: 0,
                endpoints: Vec::new(),
                pages: Vec::new(),
                applies: 0,
                customs: 0,
                resets: 0,
                reads: 0,
                token: None,
            }),
        }
    }
    fn respond(&self, endpoint: &str, plain: &[u8], state: &mut State) -> Vec<u8> {
        match endpoint {
            "minerva-config" => {
                state.customs += 1;
                let mut config: serde_json::Value = serde_json::from_slice(plain).unwrap();
                assert_eq!(config["host"], "minerva.local");
                assert_eq!(config["port"], 47821);
                let token = config["token"].take().as_str().unwrap().to_owned();
                assert_eq!(URL_SAFE_NO_PAD.decode(&token).unwrap().len(), 32);
                state.token = Some(Zeroizing::new(token));
                br#"{"v":1,"ok":true,"device_id":"a4cf12b03e5d"}"#.to_vec()
            }
            "prov-scan" => {
                let request = WiFiScanPayload::decode(plain).unwrap();
                use wi_fi_scan_payload::Payload as Scan;
                let payload = match request.msg {
                    0 => {
                        assert_eq!(plain, bytes(oracle::SCAN_START));
                        Scan::RespScanStart(RespScanStart {})
                    }
                    2 => {
                        assert_eq!(plain, bytes(oracle::SCAN_STATUS));
                        Scan::RespScanStatus(RespScanStatus {
                            scan_finished: true,
                            result_count: 16,
                        })
                    }
                    4 => {
                        let Some(Scan::CmdScanResult(page)) = request.payload else {
                            panic!("scan page missing")
                        };
                        assert_eq!(page.count, 4);
                        if page.start_index == 0 {
                            assert_eq!(plain, bytes(oracle::SCAN_PAGE));
                        }
                        state.pages.push((page.start_index, page.count));
                        Scan::RespScanResult(RespScanResult {
                            entries: (0..page.count)
                                .map(|_| WiFiScanResult {
                                    ssid: SSID.to_vec(),
                                    channel: 1,
                                    rssi: -40,
                                    bssid: vec![1, 2, 3, 4, 5, 6],
                                    auth: 3,
                                })
                                .collect(),
                        })
                    }
                    _ => panic!("unexpected scan command"),
                };
                WiFiScanPayload {
                    msg: if self.case == Case::WrongKind {
                        99
                    } else {
                        request.msg + 1
                    },
                    status: if self.case == Case::NonzeroStatus {
                        5
                    } else {
                        0
                    },
                    payload: Some(payload),
                }
                .encode_to_vec()
            }
            "prov-config" => {
                let request = WiFiConfigPayload::decode(plain).unwrap();
                use wi_fi_config_payload::Payload as Config;
                let payload = match request.msg {
                    2 => {
                        assert_eq!(plain, bytes(oracle::WIFI_SET));
                        Config::RespSetConfig(RespSetConfig { status: 0 })
                    }
                    4 => {
                        assert_eq!(plain, bytes(oracle::WIFI_APPLY));
                        state.applies += 1;
                        Config::RespApplyConfig(RespApplyConfig { status: 0 })
                    }
                    0 => {
                        assert_eq!(plain, bytes(oracle::WIFI_STATUS));
                        if self.case == Case::Connecting {
                            Config::RespGetStatus(RespGetStatus {
                                status: 0,
                                sta_state: 1,
                                state: None,
                            })
                        } else if matches!(self.case, Case::Retry | Case::MissingNetwork)
                            && state.applies == 1
                        {
                            Config::RespGetStatus(RespGetStatus {
                                status: 0,
                                sta_state: 3,
                                state: Some(resp_get_status::State::FailReason(
                                    if self.case == Case::MissingNetwork {
                                        1
                                    } else {
                                        0
                                    },
                                )),
                            })
                        } else {
                            Config::RespGetStatus(RespGetStatus {
                                status: 0,
                                sta_state: 0,
                                state: Some(resp_get_status::State::Connected(
                                    WifiConnectedState {
                                        ip4_addr: "192.0.2.2".into(),
                                        auth_mode: 3,
                                        ssid: SSID.to_vec(),
                                        bssid: vec![1, 2, 3, 4, 5, 6],
                                        channel: 1,
                                    },
                                )),
                            })
                        }
                    }
                    _ => panic!("unexpected config command"),
                };
                WiFiConfigPayload {
                    msg: request.msg + 1,
                    payload: Some(payload),
                }
                .encode_to_vec()
            }
            "prov-ctrl" => {
                let request = WiFiCtrlPayload::decode(plain).unwrap();
                assert_eq!(request.msg, WiFiCtrlMsgType::TypeCmdCtrlReset as i32);
                assert!(matches!(
                    request.payload,
                    Some(wi_fi_ctrl_payload::Payload::CmdCtrlReset(_))
                ));
                state.resets += 1;
                WiFiCtrlPayload {
                    msg: 2,
                    status: 0,
                    payload: Some(wi_fi_ctrl_payload::Payload::RespCtrlReset(RespCtrlReset {})),
                }
                .encode_to_vec()
            }
            _ => panic!("unexpected encrypted endpoint"),
        }
    }
}
impl Peer for DevicePeer {
    fn characteristics(&self) -> BTreeSet<Characteristic> {
        self.chars.clone()
    }
    async fn descriptor(&self, d: &Descriptor) -> Result<Vec<u8>, Error> {
        Ok(self.names[&d.characteristic_uuid].as_bytes().to_vec())
    }
    async fn write(&self, characteristic: &Characteristic, value: &[u8]) -> Result<(), Error> {
        assert!(value.len() <= 512);
        let endpoint = self.names[&characteristic.uuid];
        let mut state = self.state.lock().unwrap();
        assert!(
            state.reply.is_empty(),
            "read the acknowledged response before another write"
        );
        if endpoint == "proto-ver" {
            state.reply = br#"{"prov":{"sec_ver":2,"sec_patch_ver":1},"minerva":{"ver":"1","cap":["minerva-config"]}}"#.to_vec();
        } else if endpoint == "prov-session" {
            let vector = &security::VECTORS[0];
            assert_eq!(
                value,
                bytes(if state.handshake == 0 {
                    vector.start
                } else {
                    vector.proof
                })
            );
            state.reply = bytes(if state.handshake == 0 {
                vector.challenge
            } else {
                vector.finish
            });
            state.handshake += 1;
        } else {
            let plain = Zeroizing::new(self.cipher.decrypt(&nonce(state.counter), value).unwrap());
            state.counter += 1;
            state.endpoints.push(endpoint.to_owned());
            if self.case == Case::LostAck && endpoint == "minerva-config" {
                return Err(Error::Transport);
            }
            let reply = self.respond(endpoint, &plain, &mut state);
            if self.case == Case::ApplyLostAck && state.applies == 1 {
                return Err(Error::Transport);
            }
            state.reply = if self.case == Case::Oversize {
                vec![0; 513]
            } else {
                self.cipher
                    .encrypt(&nonce(state.counter), reply.as_slice())
                    .unwrap()
            };
            state.counter += 1;
        }
        Ok(())
    }
    async fn read(&self, _: &Characteristic) -> Result<Vec<u8>, Error> {
        let mut state = self.state.lock().unwrap();
        state.reads += 1;
        Ok(std::mem::take(&mut state.reply))
    }
    async fn disconnect(&self) -> Result<(), Error> {
        Ok(())
    }
}
fn credentials() -> Credentials {
    Credentials {
        ssid: Zeroizing::new(SSID.to_vec()),
        password: Zeroizing::new("public-test-password".into()),
        host: "minerva.local".into(),
        port: 47821,
    }
}
async fn session(peer: &DevicePeer, cancel: &mut watch::Receiver<bool>) -> Session {
    authenticate_with_rng(
        peer,
        Zeroizing::new("000123".into()),
        cancel,
        &mut Fixed(bytes(security::VECTORS[0].ephemeral)),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn independent_full_wire_reset_retry_real_store_and_lan_confirmation() {
    for case in [Case::Good, Case::Retry, Case::MissingNetwork] {
        let data = tempfile::tempdir().unwrap();
        let store = Arc::new(TokenStore::open(data.path()).unwrap());
        let peer = Arc::new(DevicePeer::new(case));
        let schemas = Arc::new(Schemas::load().unwrap());
        let server = Server::bind(
            ServerConfig::new(([127, 0, 0, 1], 0).into()),
            store.clone(),
            schemas.clone(),
        )
        .await
        .unwrap();
        let address = server.local_addr().unwrap();
        let (stop, stopped) = watch::channel(false);
        let serving = tokio::spawn(server.run(stopped));
        let (_cancel, mut cancelled) = watch::channel(false);
        let mut session = session(&peer, &mut cancelled).await;
        let (input, receiver) = mpsc::channel(1);
        input
            .try_send(credentials())
            .unwrap_or_else(|_| panic!("initial input"));
        let updates = Arc::new(Mutex::new(Vec::new()));
        let mut client = None;
        let result = workflow::run(
            &*peer,
            &mut session,
            Job {
                store: store.clone(),
                input: receiver,
            },
            "SR2-A1B2",
            &mut cancelled,
            |progress| {
                updates.lock().unwrap().push(progress.clone());
                if progress.stage == "awaiting_wifi" && progress.error.is_some() {
                    assert_eq!(
                        progress.error,
                        Some(if case == Case::Retry {
                            Error::WrongPassword
                        } else {
                            Error::NetworkNotFound
                        })
                    );
                    input
                        .try_send(credentials())
                        .unwrap_or_else(|_| panic!("retry input"));
                }
                if progress.stage == "waiting_lan" {
                    assert!(!store.record(ID).unwrap().confirmed);
                    let token = peer.state.lock().unwrap().token.clone().unwrap();
                    let schemas = schemas.clone();
                    client = Some(tokio::spawn(async move {
                        let mut device = common::Device::connect(address, schemas).await;
                        device.send_json(&common::hello(&token, ID)).await;
                        assert_eq!(device.recv_msg().await["type"], "welcome");
                    }));
                }
            },
        )
        .await;
        assert_eq!(result, Ok(()));
        client.unwrap().await.unwrap();
        assert!(store.record(ID).unwrap().confirmed);
        assert_eq!(updates.lock().unwrap().last().unwrap().stage, "confirmed");
        {
            let state = peer.state.lock().unwrap();
            assert_eq!(state.pages, vec![(0, 4), (4, 4), (8, 4), (12, 4)]);
            assert_eq!(state.customs, 1);
            assert_eq!(state.applies, if case == Case::Good { 1 } else { 2 });
            assert_eq!(state.resets, if case == Case::Good { 0 } else { 1 });
            let token = state.token.as_ref().unwrap();
            assert!(!std::fs::read_to_string(store.path())
                .unwrap()
                .contains(token.as_str()));
            assert!(!serde_json::to_string(&*updates.lock().unwrap())
                .unwrap()
                .contains(token.as_str()));
            assert!(!std::fs::read_to_string(store.path())
                .unwrap()
                .contains("public-test-password"));
            assert!(!serde_json::to_string(&*updates.lock().unwrap())
                .unwrap()
                .contains("public-test-password"));
        }
        stop.send(true).unwrap();
        serving.await.unwrap();
    }
}

#[tokio::test]
async fn cancelled_owner_input_excludes_typing_time_and_invalidates_the_session_without_pairing() {
    for timeout in [false, true] {
        let data = tempfile::tempdir().unwrap();
        let store = Arc::new(TokenStore::open(data.path()).unwrap());
        let peer = DevicePeer::new(Case::Good);
        let (cancel, mut cancelled) = watch::channel(false);
        let mut session = session(&peer, &mut cancelled).await;
        let (_input, receiver) = mpsc::channel(1);
        if timeout {
            tokio::time::pause();
        }
        let result = workflow::run(
            &peer,
            &mut session,
            Job {
                store: store.clone(),
                input: receiver,
            },
            "SR2-A1B2",
            &mut cancelled,
            |progress| {
                if progress.stage == "awaiting_wifi" {
                    if timeout {
                        let cancel = cancel.clone();
                        tokio::spawn(async move {
                            tokio::time::sleep(Duration::from_secs(300)).await;
                            cancel.send(true).unwrap();
                        });
                    } else {
                        cancel.send(true).unwrap();
                    }
                }
            },
        )
        .await;
        assert_eq!(result, Err(Error::Cancelled));
        assert!(store.record(ID).is_none());
        assert_eq!(peer.state.lock().unwrap().customs, 0);
        assert_eq!(
            session.encrypt(b"cannot resume"),
            Err(smart_remote_plugin::provisioning::Error::State)
        );
        if timeout {
            tokio::time::resume();
        }
    }
}

#[tokio::test]
async fn failed_protocol_ack_bounds_store_and_connection_deadline_never_pair_or_resume() {
    for (case, expected) in [
        (Case::WrongKind, Error::Protocol),
        (Case::NonzeroStatus, Error::Protocol),
        (Case::Oversize, Error::ValueTooLarge),
        (Case::LostAck, Error::Transport),
        (Case::ApplyLostAck, Error::Transport),
        (Case::Connecting, Error::Timeout),
        (Case::StoreFailure, Error::Store),
    ] {
        let data = tempfile::tempdir().unwrap();
        let store = Arc::new(TokenStore::open(data.path()).unwrap());
        if case == Case::StoreFailure {
            std::fs::create_dir(store.path()).unwrap();
        }
        let peer = DevicePeer::new(case);
        let (_cancel, mut cancelled) = watch::channel(false);
        let mut session = session(&peer, &mut cancelled).await;
        let (input, receiver) = mpsc::channel(1);
        input
            .try_send(credentials())
            .unwrap_or_else(|_| panic!("input"));
        if case == Case::Connecting {
            tokio::time::pause();
        }
        let mut save_possible = false;
        assert_eq!(
            workflow::run(
                &peer,
                &mut session,
                Job {
                    store: store.clone(),
                    input: receiver
                },
                "SR2-A1B2",
                &mut cancelled,
                |progress| save_possible |= progress.save_possible
            )
            .await,
            Err(expected)
        );
        assert_eq!(
            session.encrypt(b"cannot resume"),
            Err(smart_remote_plugin::provisioning::Error::State)
        );
        assert!(store.record(ID).is_none());
        assert_eq!(
            save_possible,
            matches!(
                case,
                Case::ApplyLostAck | Case::Connecting | Case::StoreFailure
            )
        );
        assert_eq!(
            peer.state.lock().unwrap().resets,
            0,
            "reset only a validated failure"
        );
        if case == Case::Connecting {
            tokio::time::resume();
        }
    }
}

#[tokio::test]
async fn unconfirmed_pairing_survives_and_a_late_real_hello_confirms_it() {
    for cancel_after_store in [false, true] {
        let data = tempfile::tempdir().unwrap();
        let store = Arc::new(TokenStore::open(data.path()).unwrap());
        let peer = DevicePeer::new(Case::NoLan);
        let (cancel, mut cancelled) = watch::channel(false);
        let mut session = session(&peer, &mut cancelled).await;
        let (input, receiver) = mpsc::channel(1);
        tokio::time::pause();
        let began = tokio::time::Instant::now();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(230)).await;
            tokio::time::resume();
            input
                .try_send(credentials())
                .unwrap_or_else(|_| panic!("input"));
        });
        let mut stages = Vec::new();
        let mut lan_started = None;
        let mut final_progress = None;
        let result = workflow::run(
            &peer,
            &mut session,
            Job {
                store: store.clone(),
                input: receiver,
            },
            "SR2-A1B2",
            &mut cancelled,
            |progress| {
                if progress.stage == "waiting_lan" {
                    assert!(began.elapsed() >= Duration::from_secs(230));
                    lan_started = Some(tokio::time::Instant::now());
                    if cancel_after_store {
                        cancel.send(true).unwrap();
                    } else {
                        tokio::time::pause();
                    }
                }
                stages.push(progress.stage);
                final_progress = Some(progress);
            },
        )
        .await;
        assert_eq!(
            result,
            if cancel_after_store {
                Err(Error::Cancelled)
            } else {
                Ok(())
            }
        );
        let progress = final_progress.unwrap();
        assert_eq!(progress.persistence.state(), 2);
        assert!(progress.save_possible);
        if !cancel_after_store {
            assert!(lan_started.unwrap().elapsed() >= Duration::from_secs(60));
            assert_eq!(stages.last(), Some(&"unconfirmed"));
            tokio::time::resume();
        } else {
            assert_eq!(
                session.encrypt(b"cancelled monitor"),
                Err(smart_remote_plugin::provisioning::Error::State)
            );
        }
        assert!(!store.record(ID).unwrap().confirmed);
        let token = peer.state.lock().unwrap().token.clone().unwrap();
        let schemas = Arc::new(Schemas::load().unwrap());
        let server = Server::bind(
            ServerConfig::new(([127, 0, 0, 1], 0).into()),
            store.clone(),
            schemas.clone(),
        )
        .await
        .unwrap();
        let address = server.local_addr().unwrap();
        let (stop, stopped) = watch::channel(false);
        let serving = tokio::spawn(server.run(stopped));
        let mut device = common::Device::connect(address, schemas).await;
        device.send_json(&common::hello(&token, ID)).await;
        assert_eq!(device.recv_msg().await["type"], "welcome");
        tokio::time::timeout(Duration::from_secs(2), async {
            while !store.record(ID).unwrap().confirmed {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        stop.send(true).unwrap();
        serving.await.unwrap();
    }
}
