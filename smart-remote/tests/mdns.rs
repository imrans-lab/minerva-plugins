//! The advert is visible to a real mDNS browser on this machine.

use std::time::{Duration, Instant};

use mdns_sd::{ServiceDaemon, ServiceEvent};
use smart_remote_plugin::mdns::{Advert, SERVICE_TYPE};

#[test]
fn advert_resolves_with_port_and_proto_txt() {
    // An unusual port so another advert on the LAN cannot satisfy the test.
    let port = 47_000 + (std::process::id() % 900) as u16;
    let advert = Advert::start(port).expect("advert starts");
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
    let _ = browser.shutdown();
    advert.stop();
}
