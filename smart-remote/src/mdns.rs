//! mDNS advert `_minerva-remote._tcp` with TXT `proto=1`, the device's
//! fallback when the address stored at provisioning does not answer.

use std::fmt;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};

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

/// Which addresses the advert may publish, following the listen address so
/// a device is never sent to an address the listener does not accept.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdvertScope {
    /// Loopback listener: nothing on the LAN can reach it.
    None,
    /// Every IPv4 interface (bound to 0.0.0.0).
    AllIpv4,
    /// Every interface of both families (bound to ::).
    AllInterfaces,
    /// Exactly the bound address.
    Only(IpAddr),
}

pub fn advert_scope(bind: IpAddr) -> AdvertScope {
    if bind.is_loopback() {
        AdvertScope::None
    } else if bind.is_unspecified() {
        match bind {
            IpAddr::V4(_) => AdvertScope::AllIpv4,
            IpAddr::V6(_) => AdvertScope::AllInterfaces,
        }
    } else {
        AdvertScope::Only(bind)
    }
}

/// The service record for this machine. With a wildcard scope the daemon
/// fills in and follows interface addresses (`addr_auto`).
pub fn service_info(scope: AdvertScope, port: u16) -> Result<ServiceInfo, MdnsError> {
    let host = local_label();
    let name = format!("Minerva on {host}");
    // Not the machine's own name: the OS responder answers for that one with
    // every local address, which would undo the scope chosen here.
    let hostname = format!("{host}-minerva-remote.local.");
    let properties = &[("proto", "1")][..];
    Ok(match scope {
        AdvertScope::Only(ip) => {
            ServiceInfo::new(SERVICE_TYPE, &name, &hostname, ip, port, properties)?
        }
        _ => ServiceInfo::new(SERVICE_TYPE, &name, &hostname, (), port, properties)?
            .enable_addr_auto(),
    })
}

/// The machine's host name reduced to a DNS label short enough (48) to take
/// the `-minerva-remote` suffix within the 63-byte label limit.
fn local_label() -> String {
    let raw = gethostname::gethostname().to_string_lossy().into_owned();
    let first = raw.split('.').next().unwrap_or_default();
    let label: String = first
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .take(48)
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
    /// Advertises the listener at `bind`. Returns None when `bind` is
    /// loopback, which no device can reach.
    pub fn start(bind: SocketAddr) -> Result<Option<Self>, MdnsError> {
        let scope = advert_scope(bind.ip());
        if scope == AdvertScope::None {
            return Ok(None);
        }
        let info = service_info(scope, bind.port())?;
        let fullname = info.get_fullname().to_owned();
        let daemon = ServiceDaemon::new()?;
        match scope {
            AdvertScope::AllIpv4 | AdvertScope::Only(IpAddr::V4(_)) => {
                daemon.disable_interface(IfKind::IPv6)?;
            }
            AdvertScope::Only(IpAddr::V6(_)) => daemon.disable_interface(IfKind::IPv4)?,
            AdvertScope::AllInterfaces | AdvertScope::None => {}
        }
        daemon.register(info)?;
        Ok(Some(Self { daemon, fullname }))
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

    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn record_has_type_port_and_proto() {
        let info = service_info(AdvertScope::AllIpv4, 47821).unwrap();
        assert_eq!(info.get_type(), SERVICE_TYPE);
        assert_eq!(info.get_port(), 47821);
        assert_eq!(info.get_property_val_str("proto"), Some("1"));
        assert!(info.get_hostname().ends_with(".local."));
        assert!(info.is_addr_auto());
    }

    #[test]
    fn scope_follows_the_bind_address() {
        assert_eq!(
            advert_scope(Ipv4Addr::UNSPECIFIED.into()),
            AdvertScope::AllIpv4
        );
        assert_eq!(
            advert_scope(Ipv6Addr::UNSPECIFIED.into()),
            AdvertScope::AllInterfaces
        );
        assert_eq!(advert_scope(Ipv4Addr::LOCALHOST.into()), AdvertScope::None);
        assert_eq!(advert_scope(Ipv6Addr::LOCALHOST.into()), AdvertScope::None);
        let lan: IpAddr = Ipv4Addr::new(192, 168, 1, 20).into();
        assert_eq!(advert_scope(lan), AdvertScope::Only(lan));
    }

    #[test]
    fn a_specific_bind_publishes_only_that_address() {
        let lan: IpAddr = Ipv4Addr::new(192, 168, 1, 20).into();
        let info = service_info(AdvertScope::Only(lan), 47821).unwrap();
        assert!(!info.is_addr_auto());
        let addrs: Vec<IpAddr> = info.get_addresses().iter().copied().collect();
        assert_eq!(addrs, vec![lan]);
    }
}
