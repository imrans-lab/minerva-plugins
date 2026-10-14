//! Canonical encrypted provisioning; the worker alone owns credentials/token.
use super::{config_request, config_response, decode, transport::*, wifi_config, wire::*, Session};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use btleplug::api::Characteristic;
use prost::Message;
use rand_core::TryRngCore;
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use tokio::sync::{mpsc, watch};
use zeroize::Zeroizing;

pub struct Credentials {
    pub ssid: Zeroizing<Vec<u8>>,
    pub password: Zeroizing<String>,
    pub host: String,
    pub port: u16,
}
#[derive(Clone, Default, serde::Serialize)]
pub struct Progress {
    pub stage: &'static str,
    pub networks: Vec<Network>,
    pub device_id: Option<String>,
    pub error: Option<Error>,
}
#[derive(Clone, serde::Serialize)]
pub struct Network {
    pub ssid: String,
    pub label: String,
}
pub struct Job {
    pub store: Arc<crate::store::TokenStore>,
    pub input: mpsc::Receiver<Credentials>,
}
struct Link<'a, P> {
    peer: &'a P,
    session: &'a mut Session,
    names: BTreeMap<String, Characteristic>,
    cancel: &'a mut watch::Receiver<bool>,
}
impl<P: Peer> Link<'_, P> {
    async fn rpc<M: Message + Default>(&mut self, name: &str, bytes: &[u8]) -> Result<M, Error> {
        let reply = encrypted(
            self.peer,
            &self.names[name],
            self.session,
            bytes,
            self.cancel,
        )
        .await?;
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
    let result = tokio::time::timeout(Duration::from_secs(240), async {
        let names = endpoints(peer, cancel).await?;
        let mut link = Link {
            peer,
            session,
            names,
            cancel,
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
                progress.networks.push(Network {
                    ssid: URL_SAFE_NO_PAD.encode(&entry.ssid),
                    label: String::from_utf8_lossy(&entry.ssid).into_owned(),
                });
            }
        }
        let mut random = Zeroizing::new([0u8; 32]);
        rand_core::OsRng
            .try_fill_bytes(random.as_mut())
            .map_err(|_| Error::Authentication)?;
        let token = Zeroizing::new(URL_SAFE_NO_PAD.encode(random.as_slice()));
        let mut staged = None;
        loop {
            progress.stage = "awaiting_wifi";
            update(progress.clone());
            let credentials = tokio::select! {
                biased;
                _ = link.cancel.changed() => return Err(Error::Cancelled),
                input = job.input.recv() => input.ok_or(Error::Cancelled)?,
            };
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
                        if !matches!(reply.state, Some(resp_get_status::State::FailReason(0 | 1))) {
                            return Err(Error::Protocol);
                        }
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
                let id = progress.device_id.clone().ok_or(Error::Protocol)?;
                let store = job.store.clone();
                let stored_token = token.clone();
                let stored_name = name.to_owned();
                let stored_id = id.clone();
                bounded(
                    async move {
                        tokio::task::spawn_blocking(move || {
                            let time = std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .map_err(|_| Error::Store)?
                                .as_secs();
                            store
                                .pair(&stored_id, &stored_token, &stored_name, time)
                                .map_err(|_| Error::Store)
                        })
                        .await
                        .map_err(|_| Error::Store)?
                    },
                    link.cancel,
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
            progress.error = Some(Error::Wifi);
        }
    })
    .await
    .unwrap_or(Err(Error::Timeout));
    if result.is_err() {
        session.cancel();
    }
    result
}
