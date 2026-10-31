//! Short unauthenticated discovery: documented hostname candidates plus mDNS SRV targets.
use std::collections::BTreeSet;
use std::net::UdpSocket;
use std::thread;
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::client::{probe, Discovered};
use crate::config::normalize_host;
use crate::error::{Error, Result};

#[derive(Serialize)]
pub struct Discovery {
    pub printers: Vec<Discovered>,
    pub probed: usize,
    pub unreachable: usize,
    pub mdns_available: bool,
}
pub fn discover(hosts: Option<Vec<String>>) -> Result<Discovery> {
    let mut candidates = BTreeSet::new();
    let mut mdns_available = false;
    if let Some(hosts) = hosts {
        if hosts.is_empty() || hosts.len() > 32 {
            return Err(Error::Invalid("Provide1–32 printer hosts"));
        }
        for host in hosts {
            candidates.insert(normalize_host(&host)?);
        }
    } else {
        for host in [
            "prusa-xl.local",
            "prusa-mk4.local",
            "prusa-core-one.local",
            "prusa-mini.local",
            "prusa.local",
        ] {
            candidates.insert(normalize_host(host)?);
        }
        if let Ok(found) = browse() {
            mdns_available = true;
            for host in found {
                candidates.insert(normalize_host(&host)?);
            }
        }
    }
    let mut handles = Vec::new();
    for host in candidates.into_iter().take(32) {
        handles.push(
            thread::Builder::new()
                .name("prusalink-discover".into())
                .spawn(move || probe(&host))
                .map_err(|_| Error::Io("Cannot start discovery worker"))?,
        );
    }
    let probed = handles.len();
    let mut printers = Vec::new();
    let mut unreachable = 0;
    for handle in handles {
        match handle.join() {
            Ok(Ok(Some(printer))) => printers.push(printer),
            Ok(Ok(None)) => {}
            Ok(Err(_)) => unreachable += 1,
            Err(_) => return Err(Error::Io("Discovery worker stopped unexpectedly")),
        }
    }
    printers.sort_by(|a, b| a.host.cmp(&b.host));
    Ok(Discovery {
        printers,
        probed,
        unreachable,
        mdns_available,
    })
}

fn browse() -> std::io::Result<BTreeSet<String>> {
    let socket = UdpSocket::bind((std::net::Ipv4Addr::UNSPECIFIED, 0))?;
    // QU asks for a unicast reply to the ephemeral source port (no shared5353 bind).
    let mut query = vec![0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0];
    for service in ["_http._tcp.local", "_prusa-link._tcp.local"] {
        for label in service.split('.') {
            query.push(label.len() as u8);
            query.extend_from_slice(label.as_bytes());
        }
        query.extend_from_slice(&[0, 0, 12, 0x80, 1]);
    }
    socket.send_to(&query, (std::net::Ipv4Addr::new(224, 0, 0, 251), 5353))?;
    let end = Instant::now() + Duration::from_secs(1);
    let mut found = BTreeSet::new();
    let mut bytes = [0_u8; 4096];
    while Instant::now() < end && found.len() < 27 {
        socket.set_read_timeout(Some(
            end.saturating_duration_since(Instant::now())
                .max(Duration::from_millis(1)),
        ))?;
        match socket.recv_from(&mut bytes) {
            Ok((count, _)) => {
                if let Some(hosts) = srv_hosts(&bytes[..count]) {
                    found.extend(hosts);
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                break
            }
            Err(error) => return Err(error),
        }
    }
    Ok(found)
}

fn u16_at(bytes: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_be_bytes([
        *bytes.get(offset)?,
        *bytes.get(offset + 1)?,
    ]))
}
fn name(bytes: &[u8], cursor: &mut usize) -> Option<String> {
    let mut position = *cursor;
    let mut resume = None;
    let mut labels = Vec::new();
    for _ in 0..32 {
        let length = *bytes.get(position)?;
        if length & 0xc0 == 0xc0 {
            let next = *bytes.get(position + 1)?;
            resume.get_or_insert(position + 2);
            position = (usize::from(length & 0x3f) << 8) | usize::from(next);
        } else if length == 0 {
            *cursor = resume.unwrap_or(position + 1);
            let name = labels.join(".");
            return (name.len() <= 253).then_some(name);
        } else if length <= 63 {
            let end = position + 1 + usize::from(length);
            let label = std::str::from_utf8(bytes.get(position + 1..end)?).ok()?;
            // DNS-SD instance labels may contain spaces/punctuation. These are
            // record owners, not hostnames; validate SRV targets separately.
            if label.chars().any(char::is_control) {
                return None;
            }
            labels.push(label);
            position = end;
        } else {
            return None;
        }
    }
    None
}
fn srv_hosts(bytes: &[u8]) -> Option<BTreeSet<String>> {
    if bytes.len() < 12 || bytes[2] & 0x80 == 0 {
        return None;
    }
    let questions = usize::from(u16_at(bytes, 4)?);
    if questions > 32 {
        return None;
    }
    let mut cursor = 12;
    for _ in 0..questions {
        name(bytes, &mut cursor)?;
        cursor += 4;
    }
    let records = usize::from(u16_at(bytes, 6)?)
        + usize::from(u16_at(bytes, 8)?)
        + usize::from(u16_at(bytes, 10)?);
    let mut hosts = BTreeSet::new();
    for _ in 0..records.min(128) {
        name(bytes, &mut cursor)?;
        let kind = u16_at(bytes, cursor)?;
        let length = usize::from(u16_at(bytes, cursor + 8)?);
        cursor += 10;
        let end = cursor.checked_add(length)?;
        bytes.get(cursor..end)?;
        if kind == 33 && length >= 7 {
            let port = u16_at(bytes, cursor + 4)?;
            let mut target = cursor + 6;
            let hostname = name(bytes, &mut target)?;
            if port != 0
                && hostname.ends_with(".local")
                && target <= end
                && hostname.split('.').all(|label| {
                    !label.is_empty()
                        && label
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                })
            {
                hosts.insert(format!("http://{hostname}:{port}"));
            }
        }
        cursor = end;
    }
    Some(hosts)
}
