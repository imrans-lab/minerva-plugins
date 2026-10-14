//! One complete ATT value per request: the OS owns long writes and reads.
use super::Session;
use btleplug::api::{CharPropFlags, Characteristic, Descriptor};
use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::time::Duration;
use tokio::sync::watch;
use uuid::Uuid;
use zeroize::Zeroizing;

pub const SERVICE: Uuid = Uuid::from_u128(0x7cfd5818_3705_4e21_8f3a_cce005338a9b);
pub const DESCRIPTION: Uuid = Uuid::from_u128(0x00002901_0000_1000_8000_00805f9b34fb);
const ENDPOINTS: [&str; 6] = [
    "prov-session",
    "proto-ver",
    "prov-scan",
    "prov-config",
    "prov-ctrl",
    "minerva-config",
];
pub const VALUE_LIMIT: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Error {
    Input,
    Busy,
    Operation,
    Interrupted,
    Adapter,
    NotFound,
    Ambiguous,
    Transport,
    Endpoint,
    Version,
    Authentication,
    Timeout,
    Cancelled,
    ValueTooLarge,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "BLE {self:?}")
    }
}
impl std::error::Error for Error {}

/// Native peer and synthetic peer use the same endpoint and exchange owner.
pub trait Peer: Sync {
    fn characteristics(&self) -> BTreeSet<Characteristic>;
    fn descriptor(
        &self,
        descriptor: &Descriptor,
    ) -> impl Future<Output = Result<Vec<u8>, Error>> + Send;
    fn write(
        &self,
        characteristic: &Characteristic,
        bytes: &[u8],
    ) -> impl Future<Output = Result<(), Error>> + Send;
    fn read(
        &self,
        characteristic: &Characteristic,
    ) -> impl Future<Output = Result<Vec<u8>, Error>> + Send;
    fn disconnect(&self) -> impl Future<Output = Result<(), Error>> + Send;
}

/// Discard the authenticated channel and attempt cleanup even after failure.
pub async fn finish_probe<P: Peer>(
    peer: &P,
    result: Result<Session, Error>,
    cancel: &watch::Receiver<bool>,
) -> Result<(), Error> {
    let result = result.map(|mut session| session.cancel());
    let disconnected = tokio::time::timeout(Duration::from_secs(3), peer.disconnect()).await;
    result?;
    if *cancel.borrow() {
        return Err(Error::Cancelled);
    }
    disconnected.map_err(|_| Error::Timeout)?
}

pub async fn bounded<T>(
    future: impl Future<Output = Result<T, Error>>,
    cancel: &mut watch::Receiver<bool>,
) -> Result<T, Error> {
    if *cancel.borrow() {
        return Err(Error::Cancelled);
    }
    tokio::select! {
        biased;
        _ = cancel.changed() => Err(Error::Cancelled),
        result = tokio::time::timeout(Duration::from_secs(10), future) =>
            result.map_err(|_| Error::Timeout)?,
    }
}

pub async fn endpoints<P: Peer>(
    peer: &P,
    cancel: &mut watch::Receiver<bool>,
) -> Result<BTreeMap<String, Characteristic>, Error> {
    let mut found = BTreeMap::new();
    for characteristic in peer.characteristics() {
        if characteristic.service_uuid != SERVICE {
            continue;
        }
        let descriptions: Vec<_> = characteristic
            .descriptors
            .iter()
            .filter(|d| d.uuid == DESCRIPTION)
            .collect();
        if descriptions.len() > 1 {
            return Err(Error::Endpoint);
        }
        let Some(descriptor) = descriptions.first() else {
            continue;
        };
        if descriptor.service_uuid != SERVICE
            || descriptor.characteristic_uuid != characteristic.uuid
        {
            return Err(Error::Endpoint);
        }
        let bytes = bounded(peer.descriptor(descriptor), cancel).await?;
        if bytes.len() > 128 {
            return Err(Error::Endpoint);
        }
        let name = std::str::from_utf8(&bytes).map_err(|_| Error::Endpoint)?;
        if !ENDPOINTS.contains(&name) {
            continue;
        }
        if !characteristic
            .properties
            .contains(CharPropFlags::READ | CharPropFlags::WRITE)
            || found.insert(name.to_owned(), characteristic).is_some()
        {
            return Err(Error::Endpoint);
        }
    }
    if ENDPOINTS.iter().any(|name| !found.contains_key(*name)) {
        return Err(Error::Endpoint);
    }
    Ok(found)
}

/// Write ACK precedes the read. Never split protobufs into ordinary writes.
pub async fn exchange<P: Peer>(
    peer: &P,
    characteristic: &Characteristic,
    request: &[u8],
    cancel: &mut watch::Receiver<bool>,
) -> Result<Vec<u8>, Error> {
    if request.len() > VALUE_LIMIT {
        return Err(Error::ValueTooLarge);
    }
    bounded(peer.write(characteristic, request), cancel).await?;
    let response = bounded(peer.read(characteristic), cancel).await?;
    if response.len() > VALUE_LIMIT {
        return Err(Error::ValueTooLarge);
    }
    Ok(response)
}

#[derive(serde::Deserialize)]
struct Version {
    prov: Security,
    minerva: App,
}
#[derive(serde::Deserialize)]
struct Security {
    sec_ver: u32,
    sec_patch_ver: u32,
}
#[derive(serde::Deserialize)]
struct App {
    ver: String,
    cap: Vec<String>,
}
pub async fn authenticate<P: Peer>(
    peer: &P,
    code: Zeroizing<String>,
    cancel: &mut watch::Receiver<bool>,
) -> Result<Session, Error> {
    authenticate_with_rng(peer, code, cancel, &mut rand_core::OsRng).await
}
pub async fn authenticate_with_rng<P: Peer, R: rand_core::TryCryptoRng>(
    peer: &P,
    code: Zeroizing<String>,
    cancel: &mut watch::Receiver<bool>,
    rng: &mut R,
) -> Result<Session, Error> {
    let names = endpoints(peer, cancel).await?;
    let version = exchange(peer, &names["proto-ver"], b"---", cancel).await?;
    let version: Version = serde_json::from_slice(&version).map_err(|_| Error::Version)?;
    if version.prov.sec_ver != 2
        || version.prov.sec_patch_ver != 1
        || version.minerva.ver != "1"
        || !version.minerva.cap.iter().any(|c| c == "minerva-config")
    {
        return Err(Error::Version);
    }
    let (mut session, first) = Session::start_with_rng(code, version.prov.sec_patch_ver, rng)
        .map_err(|_| Error::Authentication)?;
    let result = async {
        let reply = exchange(peer, &names["prov-session"], &first, cancel).await?;
        let proof = session
            .challenge(&reply)
            .map_err(|_| Error::Authentication)?;
        let reply = exchange(peer, &names["prov-session"], &proof, cancel).await?;
        session.finish(&reply).map_err(|_| Error::Authentication)
    }
    .await;
    if let Err(error) = result {
        session.cancel();
        return Err(error);
    }
    Ok(session)
}
