//! ESP-IDF Security 2 provisioning, independent of BLE transport.
//! Owned buffers zeroize on drop; srp's internal session-key copy does not.
mod config;
mod security2;
pub mod transport;
pub use config::{config_request, config_response, wifi_config};
pub use security2::Session;

#[derive(PartialEq, Eq)]
pub struct SecretBytes(zeroize::Zeroizing<Vec<u8>>);
impl From<Vec<u8>> for SecretBytes {
    fn from(bytes: Vec<u8>) -> Self {
        Self(zeroize::Zeroizing::new(bytes))
    }
}
impl std::ops::Deref for SecretBytes {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        &self.0
    }
}
impl std::fmt::Debug for SecretBytes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SecretBytes [redacted]")
    }
}

/// Credential messages cannot accidentally be formatted with Debug.
/// ```compile_fail,E0277
/// format!("{:?}", smart_remote_plugin::provisioning::wire::CmdSetConfig::default());
/// ```
pub mod wire {
    include!(concat!(env!("OUT_DIR"), "/_.rs"));
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    State,
    Random,
    Version,
    Malformed,
    Proof,
    Cipher,
    Counter,
    Config,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "provisioning {:?}", self)
    }
}
impl std::error::Error for Error {}

pub fn decode<M: prost::Message + Default>(bytes: &[u8]) -> Result<M, Error> {
    if bytes.len() > 4096 {
        return Err(Error::Malformed);
    }
    M::decode(bytes).map_err(|_| Error::Malformed)
}
