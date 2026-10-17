//! Canonical encrypted provisioning; the worker alone owns credentials/token.
use super::{config_request, config_response, decode, transport::*, wifi_config, wire::*, Session};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use btleplug::api::Characteristic;
use prost::Message;
use rand_core::TryRngCore;
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicU8, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::sync::{mpsc, watch};
use zeroize::Zeroizing;

pub struct Credentials {
    pub ssid: Zeroizing<Vec<u8>>,
    pub password: Zeroizing<String>,
    pub host: String,
    pub port: u16,
}
#[derive(Clone, Default)]
pub struct Persistence(pub(crate) Arc<AtomicU8>);
impl Persistence {
    pub fn state(&self) -> u8 {
        self.0.load(Ordering::Acquire)
    }
    pub(crate) async fn pair(
        &self,
        store: Arc<crate::store::TokenStore>,
        id: String,
        token: Zeroizing<String>,
        name: String,
        address: Option<String>,
    ) -> Result<(), Error> {
        self.0.store(1, Ordering::Release);
        let settlement = Settlement(self.clone());
        tokio::task::spawn_blocking(move || {
            let time = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| Error::Store)?
                .as_secs();
            let result = store
                .pair_with_address(&id, &token, &name, time, address)
                .map_err(|_| Error::Store);
            settlement
                .0
                 .0
                .store(if result.is_ok() { 2 } else { 3 }, Ordering::Release);
            result
        })
        .await
        .map_err(|_| Error::Store)?
    }
}
impl serde::Serialize for Persistence {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(match self.state() {
            1 => "pending",
            2 => "stored",
            3 => "failed",
            _ => "none",
        })
    }
}
struct Settlement(Persistence);
impl Drop for Settlement {
    fn drop(&mut self) {
        let _ = self
            .0
             .0
            .compare_exchange(1, 3, Ordering::AcqRel, Ordering::Acquire);
    }
}
#[derive(Clone, Default, serde::Serialize)]
pub struct Progress {
    pub stage: &'static str,
    pub networks: Vec<Network>,
    pub device_id: Option<String>,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub error: Option<Error>,
    pub save_possible: bool,
    pub persistence: Persistence,
}
#[derive(Clone, serde::Serialize)]
pub struct Network {
    pub ssid: String,
    pub label: String,
}
impl Network {
    fn from_ssid(ssid: &[u8]) -> Self {
        Self {
            ssid: URL_SAFE_NO_PAD.encode(ssid),
            label: String::from_utf8_lossy(ssid).into_owned(),
        }
    }
}
pub struct Job {
    pub store: Arc<crate::store::TokenStore>,
    pub input: mpsc::Receiver<Credentials>,
    pub address: Option<String>,
}
struct Link<'a, P> {
    peer: &'a P,
    session: &'a mut Session,
    names: BTreeMap<String, Characteristic>,
    cancel: &'a mut watch::Receiver<bool>,
    deadline: Option<tokio::time::Instant>,
}
impl<P: Peer> Link<'_, P> {
    async fn rpc<M: Message + Default>(&mut self, name: &str, bytes: &[u8]) -> Result<M, Error> {
        let call = encrypted(
            self.peer,
            &self.names[name],
            self.session,
            bytes,
            self.cancel,
        );
        let reply = match self.deadline {
            Some(deadline) => tokio::time::timeout_at(deadline, call)
                .await
                .map_err(|_| Error::Timeout)??,
            None => call.await?,
        };
        decode(&reply).map_err(|_| Error::Protocol)
    }
    async fn scan(
        &mut self,
        kind: WiFiScanMsgType,
        payload: wi_fi_scan_payload::Payload,
    ) -> Result<wi_fi_scan_payload::Payload, Error> {
        let request = WiFiScanPayload {
            msg: kind as i32,
            status: 0,
            // The pinned Espressif client omits the empty scan-status oneof.
            payload: if kind == WiFiScanMsgType::TypeCmdScanStatus {
                None
            } else {
                Some(payload)
            },
        };
        let reply: WiFiScanPayload = self.rpc("prov-scan", &request.encode_to_vec()).await?;
        if reply.msg != kind as i32 + 1 || reply.status != 0 {
            return Err(Error::Protocol);
        }
        reply.payload.ok_or(Error::Protocol)
    }
    async fn config(
        &mut self,
        kind: WiFiConfigMsgType,
        payload: wi_fi_config_payload::Payload,
    ) -> Result<wi_fi_config_payload::Payload, Error> {
        let request = WiFiConfigPayload {
            msg: kind as i32,
            payload: if kind == WiFiConfigMsgType::TypeCmdApplyConfig {
                None
            } else {
                Some(payload)
            },
        };
        self.config_bytes(&request.encode_to_vec(), kind as i32 + 1)
            .await
    }
    async fn config_bytes(
        &mut self,
        bytes: &[u8],
        kind: i32,
    ) -> Result<wi_fi_config_payload::Payload, Error> {
        let reply: WiFiConfigPayload = self.rpc("prov-config", bytes).await?;
        if reply.msg != kind {
            return Err(Error::Protocol);
        }
        reply.payload.ok_or(Error::Protocol)
    }
}
pub async fn run<P: Peer>(
    peer: &P,
    session: &mut Session,
    mut job: Job,
    name: &str,
    cancel: &mut watch::Receiver<bool>,
    mut update: impl FnMut(Progress),
) -> Result<(), Error> {
    let result = async {
        let names = endpoints(peer, cancel).await?;
        let mut link = Link {
            peer,
            session,
            names,
            cancel,
            deadline: None,
        };
        let mut progress = Progress {
            stage: "scanning_wifi",
            ..Default::default()
        };
        update(progress.clone());
        use wi_fi_scan_payload::Payload as Scan;
        match link
            .scan(
                WiFiScanMsgType::TypeCmdScanStart,
                Scan::CmdScanStart(CmdScanStart {
                    blocking: false,
                    passive: false,
                    group_channels: 0,
                    period_ms: 120,
                }),
            )
            .await?
        {
            Scan::RespScanStart(_) => (),
            _ => return Err(Error::Protocol),
        }
        let mut count = None;
        for _ in 0..30 {
            match link
                .scan(
                    WiFiScanMsgType::TypeCmdScanStatus,
                    Scan::CmdScanStatus(CmdScanStatus {}),
                )
                .await?
            {
                Scan::RespScanStatus(status)
                    if status.scan_finished && status.result_count <= 16 =>
                {
                    count = Some(status.result_count);
                    break;
                }
                Scan::RespScanStatus(status) if !status.scan_finished => (),
                _ => return Err(Error::Protocol),
            }
            bounded(
                async {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    Ok(())
                },
                link.cancel,
            )
            .await?;
        }
        let count = count.ok_or(Error::Timeout)?;
        for index in (0..count).step_by(4) {
            let size = (count - index).min(4);
            let Scan::RespScanResult(results) = link
                .scan(
                    WiFiScanMsgType::TypeCmdScanResult,
                    Scan::CmdScanResult(CmdScanResult {
                        start_index: index,
                        count: size,
                    }),
                )
                .await?
            else {
                return Err(Error::Protocol);
            };
            if results.entries.len() != size as usize {
                return Err(Error::Protocol);
            }
            for entry in results.entries {
                if entry.ssid.len() > 32
                    || entry.bssid.len() != 6
                    || !(1..=14).contains(&entry.channel)
                    || !(0..=7).contains(&entry.auth)
                {
                    return Err(Error::Protocol);
                }
                progress.networks.push(Network::from_ssid(&entry.ssid));
            }
        }
        let mut random = Zeroizing::new([0u8; 32]);
        rand_core::OsRng
            .try_fill_bytes(random.as_mut())
            .map_err(|_| Error::Authentication)?;
        let token = Zeroizing::new(URL_SAFE_NO_PAD.encode(random.as_slice()));
        let mut staged = None;
        loop {
            link.deadline = None;
            progress.stage = "awaiting_wifi";
            update(progress.clone());
            let credentials = tokio::time::timeout(Duration::from_secs(300), async {
                tokio::select! {
                    biased;
                    _ = link.cancel.changed() => Err(Error::Cancelled),
                    input = job.input.recv() => input.ok_or(Error::Cancelled),
                }
            })
            .await
            .map_err(|_| Error::InputTimeout)??;
            link.deadline = Some(tokio::time::Instant::now() + Duration::from_secs(240));
            progress.error = None;
            if staged
                .as_ref()
                .is_some_and(|(host, port)| host != &credentials.host || port != &credentials.port)
            {
                return Err(Error::Input);
            }
            if staged.is_none() {
                let request = config_request(&credentials.host, credentials.port, &token)
                    .map_err(|_| Error::Input)?;
                let reply = encrypted(
                    peer,
                    &link.names["minerva-config"],
                    link.session,
                    &request,
                    link.cancel,
                )
                .await?;
                progress.device_id = Some(config_response(&reply).map_err(|_| Error::Protocol)?);
                staged = Some((credentials.host.clone(), credentials.port));
                progress.host = Some(credentials.host.clone());
                progress.port = Some(credentials.port);
            }
            progress.stage = "applying_wifi";
            update(progress.clone());
            use wi_fi_config_payload::Payload as Config;
            let request = wifi_config(&credentials.ssid, credentials.password.as_bytes())
                .map_err(|_| Error::Input)?;
            match link
                .config_bytes(&request, WiFiConfigMsgType::TypeRespSetConfig as i32)
                .await?
            {
                Config::RespSetConfig(reply) if reply.status == 0 => (),
                _ => return Err(Error::Protocol),
            }
            progress.save_possible = true;
            update(progress.clone());
            match link
                .config(
                    WiFiConfigMsgType::TypeCmdApplyConfig,
                    Config::CmdApplyConfig(CmdApplyConfig {}),
                )
                .await?
            {
                Config::RespApplyConfig(reply) if reply.status == 0 => (),
                _ => return Err(Error::Protocol),
            }
            progress.stage = "connecting_wifi";
            update(progress.clone());
            let mut connected = false;
            let mut failed = false;
            for _ in 0..60 {
                let Config::RespGetStatus(reply) = link
                    .config(
                        WiFiConfigMsgType::TypeCmdGetStatus,
                        Config::CmdGetStatus(CmdGetStatus {}),
                    )
                    .await?
                else {
                    return Err(Error::Protocol);
                };
                if reply.status != 0 {
                    return Err(Error::Protocol);
                }
                match reply.sta_state {
                    0 => {
                        let Some(resp_get_status::State::Connected(state)) = reply.state else {
                            return Err(Error::Protocol);
                        };
                        if state.ssid != *credentials.ssid
                            || state.ip4_addr.parse::<std::net::Ipv4Addr>().is_err()
                        {
                            return Err(Error::Protocol);
                        }
                        connected = true;
                        break;
                    }
                    1 if matches!(
                        reply.state,
                        None | Some(resp_get_status::State::AttemptFailed(_))
                    ) => {}
                    2 if reply.state.is_none() => (),
                    3 => {
                        progress.error = Some(match reply.state {
                            Some(resp_get_status::State::FailReason(0)) => Error::WrongPassword,
                            Some(resp_get_status::State::FailReason(1)) => Error::NetworkNotFound,
                            _ => return Err(Error::Protocol),
                        });
                        failed = true;
                        break;
                    }
                    _ => return Err(Error::Protocol),
                }
                bounded(
                    async {
                        tokio::time::sleep(Duration::from_secs(1)).await;
                        Ok(())
                    },
                    link.cancel,
                )
                .await?;
            }
            if connected {
                link.deadline = None;
                let id = progress.device_id.clone().ok_or(Error::Protocol)?;
                update(progress.clone());
                progress
                    .persistence
                    .pair(
                        job.store.clone(),
                        id.clone(),
                        token.clone(),
                        name.to_owned(),
                        job.address.clone(),
                    )
                    .await?;
                progress.stage = "waiting_lan";
                update(progress.clone());
                for _ in 0..60 {
                    if job.store.record(&id).is_some_and(|r| r.confirmed) {
                        progress.stage = "confirmed";
                        break;
                    }
                    bounded(
                        async {
                            tokio::time::sleep(Duration::from_secs(1)).await;
                            Ok(())
                        },
                        link.cancel,
                    )
                    .await?;
                }
                if progress.stage != "confirmed" {
                    progress.stage = "unconfirmed";
                }
                update(progress);
                return Ok(());
            }
            if !failed {
                return Err(Error::Timeout);
            }
            let reset = WiFiCtrlPayload {
                msg: WiFiCtrlMsgType::TypeCmdCtrlReset as i32,
                status: 0,
                payload: Some(wi_fi_ctrl_payload::Payload::CmdCtrlReset(CmdCtrlReset {})),
            };
            let reply: WiFiCtrlPayload = link.rpc("prov-ctrl", &reset.encode_to_vec()).await?;
            if reply.msg != WiFiCtrlMsgType::TypeRespCtrlReset as i32
                || reply.status != 0
                || !matches!(
                    reply.payload,
                    Some(wi_fi_ctrl_payload::Payload::RespCtrlReset(_))
                )
            {
                return Err(Error::Protocol);
            }
        }
    }
    .await;
    if result.is_err() {
        session.cancel();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_ssid_keeps_url_safe_wire_bytes_separate_from_display_label() {
        let raw = b"\xff\xfeM\xc3\xbcn\xff";
        let network = Network::from_ssid(raw);
        assert_eq!(network.ssid, "__5Nw7xu_w");
        assert_eq!(URL_SAFE_NO_PAD.decode(&network.ssid).unwrap(), raw);
        assert_eq!(network.label, "\u{fffd}\u{fffd}Mün\u{fffd}");
        assert_ne!(
            network.ssid,
            URL_SAFE_NO_PAD.encode(network.label.as_bytes())
        );
    }
}
