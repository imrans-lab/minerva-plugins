//! The advert is visible to a real mDNS browser on this machine.

use std::time::{Duration, Instant};

use mdns_sd::{ServiceDaemon, ServiceEvent};
use smart_remote_plugin::mdns::{Advert, SERVICE_TYPE};

/// Needs multicast on the machine's network, so it runs only when asked:
/// `SMART_REMOTE_MDNS_TEST=1 cargo test --test mdns`.
const OPT_IN: &str = "SMART_REMOTE_MDNS_TEST";

#[test]
fn advert_resolves_with_port_and_proto_txt() {
    if std::env::var(OPT_IN).as_deref() != Ok("1") {
        eprintln!("skipped: set {OPT_IN}=1 to run the live mDNS test");
        return;
    }
    // An unusual port so another advert on the LAN cannot satisfy the test.
    let port = 47_000 + (std::process::id() % 900) as u16;
    let advert = Advert::start((std::net::Ipv4Addr::UNSPECIFIED, port).into())
        .expect("advert starts")
        .expect("a wildcard bind is advertised");
    let browser = ServiceDaemon::new().unwrap();
    let events = browser.browse(SERVICE_TYPE).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut found = None;
    while found.is_none() {
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(
            !left.is_zero(),
            "advert on port {port} not resolved within 10 s"
        );
        if let Ok(ServiceEvent::ServiceResolved(service)) = events.recv_timeout(left) {
            if service.get_port() == port {
                found = Some(service);
            }
        }
    }
    let service = found.unwrap();
    assert_eq!(service.get_property_val_str("proto"), Some("1"));
    assert!(!service.get_addresses().is_empty());
    assert!(
        service.get_addresses().iter().all(|a| a.is_ipv4()),
        "an IPv4-only listener must not be advertised on IPv6: {:?}",
        service.get_addresses()
    );
    let _ = browser.shutdown();
    advert.stop();
}
