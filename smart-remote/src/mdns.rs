//! mDNS advert `_minerva-remote._tcp` with TXT `proto=1`, the device's
//! fallback when the address stored at provisioning does not answer.

use std::fmt;
use std::time::Duration;

use mdns_sd::{ServiceDaemon, ServiceInfo};

pub const SERVICE_TYPE: &str = "_minerva-remote._tcp.local.";
const UNREGISTER_WAIT: Duration = Duration::from_secs(1);

#[derive(Debug)]
pub struct MdnsError(String);

impl fmt::Display for MdnsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "mDNS: {}", self.0)
    }
}

impl std::error::Error for MdnsError {}

impl From<mdns_sd::Error> for MdnsError {
    fn from(e: mdns_sd::Error) -> Self {
        Self(e.to_string())
    }
}

/// The service record for this machine. Addresses are left to the daemon
/// (`addr_auto`), so the record follows interface changes.
pub fn service_info(port: u16) -> Result<ServiceInfo, MdnsError> {
    let host = local_label();
    let info = ServiceInfo::new(
        SERVICE_TYPE,
        &format!("Minerva on {host}"),
        &format!("{host}.local."),
        (),
        port,
        &[("proto", "1")][..],
    )?;
    Ok(info.enable_addr_auto())
}

/// The machine's host name reduced to one DNS label.
fn local_label() -> String {
    let raw = gethostname::gethostname().to_string_lossy().into_owned();
    let first = raw.split('.').next().unwrap_or_default();
    let label: String = first
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .take(63)
        .collect();
    let label = label.trim_matches('-');
    if label.is_empty() {
        "minerva".to_owned()
    } else {
        label.to_owned()
    }
}

pub struct Advert {
    daemon: ServiceDaemon,
    fullname: String,
}

impl Advert {
    pub fn start(port: u16) -> Result<Self, MdnsError> {
        let info = service_info(port)?;
        let fullname = info.get_fullname().to_owned();
        let daemon = ServiceDaemon::new()?;
        daemon.register(info)?;
        Ok(Self { daemon, fullname })
    }

    /// Sends the goodbye record and stops the daemon thread.
    pub fn stop(self) {
        match self.daemon.unregister(&self.fullname) {
            Ok(status) => {
                if status.recv_timeout(UNREGISTER_WAIT).is_err() {
                    log::warn!("mDNS unregister did not confirm");
                }
            }
            Err(e) => log::warn!("mDNS unregister failed: {e}"),
        }
        if let Err(e) = self.daemon.shutdown() {
            log::warn!("mDNS shutdown failed: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_has_type_port_and_proto() {
        let info = service_info(47821).unwrap();
        assert_eq!(info.get_type(), SERVICE_TYPE);
        assert_eq!(info.get_port(), 47821);
        assert_eq!(info.get_property_val_str("proto"), Some("1"));
        assert!(info.get_hostname().ends_with(".local."));
        assert!(info.is_addr_auto());
    }
}
