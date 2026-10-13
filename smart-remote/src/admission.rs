//! Caps on connections that have not authenticated yet, so a LAN peer cannot
//! exhaust the plugin with idle sockets. A connection holds a `Permit` from
//! TCP accept until its `hello` is accepted or it is refused.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex, MutexGuard};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// Unauthenticated connections across all peers.
    pub unauthenticated: usize,
    /// Unauthenticated connections from one IP address.
    pub unauthenticated_per_ip: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            unauthenticated: 16,
            unauthenticated_per_ip: 4,
        }
    }
}

#[derive(Default)]
struct Counts {
    total: usize,
    per_ip: HashMap<IpAddr, usize>,
}

pub(crate) struct Admission {
    limits: Limits,
    counts: Mutex<Counts>,
}

impl Admission {
    pub fn new(limits: Limits) -> Arc<Self> {
        Arc::new(Self {
            limits,
            counts: Mutex::new(Counts::default()),
        })
    }

    /// A permit for one more unauthenticated connection from `ip`, or None
    /// when either cap is reached.
    pub fn try_admit(self: &Arc<Self>, ip: IpAddr) -> Option<Permit> {
        // An IPv4 peer reaching a dual-stack listener appears as ::ffff:a.b.c.d.
        let ip = ip.to_canonical();
        let mut counts = self.lock();
        let from_ip = counts.per_ip.get(&ip).copied().unwrap_or(0);
        if counts.total >= self.limits.unauthenticated
            || from_ip >= self.limits.unauthenticated_per_ip
        {
            return None;
        }
        counts.total += 1;
        counts.per_ip.insert(ip, from_ip + 1);
        Some(Permit {
            admission: Arc::clone(self),
            ip,
        })
    }

    fn lock(&self) -> MutexGuard<'_, Counts> {
        // Every critical section leaves the counts consistent before it can
        // panic, so a poisoned lock still guards valid counts.
        self.counts.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// Released on drop.
pub(crate) struct Permit {
    admission: Arc<Admission>,
    ip: IpAddr,
}

impl Drop for Permit {
    fn drop(&mut self) {
        let mut counts = self.admission.lock();
        counts.total = counts.total.saturating_sub(1);
        if let Some(n) = counts.per_ip.get_mut(&self.ip) {
            *n -= 1;
            if *n == 0 {
                counts.per_ip.remove(&self.ip);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    fn ip(last: u8) -> IpAddr {
        Ipv4Addr::new(192, 168, 1, last).into()
    }

    #[test]
    fn per_ip_and_global_caps_and_release() {
        let admission = Admission::new(Limits {
            unauthenticated: 3,
            unauthenticated_per_ip: 2,
        });
        let a1 = admission.try_admit(ip(1)).unwrap();
        let _a2 = admission.try_admit(ip(1)).unwrap();
        assert!(admission.try_admit(ip(1)).is_none(), "per-IP cap");
        let _b1 = admission.try_admit(ip(2)).unwrap();
        assert!(admission.try_admit(ip(3)).is_none(), "global cap");
        drop(a1);
        assert!(admission.try_admit(ip(3)).is_some());
    }

    #[test]
    fn mapped_ipv4_counts_as_the_same_peer() {
        let admission = Admission::new(Limits {
            unauthenticated: 10,
            unauthenticated_per_ip: 1,
        });
        let _p = admission.try_admit(ip(1)).unwrap();
        let mapped: IpAddr = Ipv4Addr::new(192, 168, 1, 1).to_ipv6_mapped().into();
        assert!(admission.try_admit(mapped).is_none());
        assert!(admission.try_admit(Ipv6Addr::LOCALHOST.into()).is_some());
    }
}
