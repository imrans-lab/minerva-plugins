//! Synthetic peer replays the public Espressif-client fixture, without radio.
use btleplug::api::{CharPropFlags, Characteristic, Descriptor};
use rand_core::{TryCryptoRng, TryRngCore};
use smart_remote_plugin::provisioning::transport::{
    authenticate_with_rng, bounded, endpoints, exchange, finish_probe, Error, Peer, DESCRIPTION,
    SERVICE,
};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;
use tokio::sync::watch;
use uuid::Uuid;
use zeroize::Zeroizing;
#[path = "fixtures/security2.rs"]
pub mod fixtures;
use fixtures::{Vector, VECTORS};

const NAMES: [&str; 6] = [
    "prov-session",
    "proto-ver",
    "prov-scan",
    "prov-config",
    "prov-ctrl",
    "minerva-config",
];
const VERSION: &[u8] = br#"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":["wifi_scan"]},"minerva":{"ver":"1","cap":["minerva-config"]}}"#;
fn bytes(hex: &str) -> Vec<u8> {
    hex::decode(hex).unwrap()
}
#[derive(Default)]
struct Io {
    writes: Vec<(Uuid, Vec<u8>)>,
    reads: usize,
    pending: bool,
    disconnects: usize,
}
struct Fake {
    chars: BTreeSet<Characteristic>,
    descriptions: BTreeMap<Uuid, Vec<u8>>,
    replies: Vec<Vec<u8>>,
    io: Mutex<Io>,
    fault: Option<&'static str>,
}
impl Fake {
    fn new(vector: &Vector) -> Self {
        let mut fake = Self {
            chars: BTreeSet::new(),
            descriptions: BTreeMap::new(),
            replies: vec![
                VERSION.to_vec(),
                bytes(vector.challenge),
                bytes(vector.finish),
            ],
            io: Mutex::new(Io::default()),
            fault: None,
        };
        // Arbitrary characteristic UUIDs ensure endpoint names own the mapping.
        for (index, name) in NAMES.iter().enumerate() {
            let uuid = Uuid::from_u128(0xaaaaaaaa_0000_4444_8888_000000000001 + index as u128);
            let descriptor = Descriptor {
                uuid: DESCRIPTION,
                service_uuid: SERVICE,
                characteristic_uuid: uuid,
            };
            fake.chars.insert(Characteristic {
                uuid,
                service_uuid: SERVICE,
                properties: CharPropFlags::READ | CharPropFlags::WRITE,
                descriptors: BTreeSet::from([descriptor]),
            });
            fake.descriptions.insert(uuid, name.as_bytes().to_vec());
        }
        fake
    }
}
impl Peer for Fake {
    fn characteristics(&self) -> BTreeSet<Characteristic> {
        self.chars.clone()
    }
    async fn descriptor(&self, descriptor: &Descriptor) -> Result<Vec<u8>, Error> {
        Ok(self.descriptions[&descriptor.characteristic_uuid].clone())
    }
    async fn write(&self, characteristic: &Characteristic, request: &[u8]) -> Result<(), Error> {
        {
            let mut io = self.io.lock().unwrap();
            assert!(!io.pending, "no pipelining or retry");
            io.writes.push((characteristic.uuid, request.to_vec()));
            if self.fault == Some("ack") {
                return Err(Error::Transport);
            }
            io.pending = true;
        }
        if self.fault == Some("hang")
            || (self.fault == Some("challenge_hang") && self.io.lock().unwrap().writes.len() == 2)
        {
            std::future::pending::<()>().await;
        }
        Ok(())
    }
    async fn read(&self, characteristic: &Characteristic) -> Result<Vec<u8>, Error> {
        let mut io = self.io.lock().unwrap();
        assert!(io.pending, "read must follow a successful ACK");
        assert_eq!(characteristic.uuid, io.writes.last().unwrap().0);
        io.pending = false;
        if self.fault == Some("read") || (self.fault == Some("proof_read") && io.reads == 2) {
            return Err(Error::Transport);
        }
        if self.fault == Some("oversize") {
            return Ok(vec![0; 513]);
        }
        let response = self.replies[io.reads].clone();
        io.reads += 1;
        Ok(response)
    }
    async fn disconnect(&self) -> Result<(), Error> {
        self.io.lock().unwrap().disconnects += 1;
        if self.fault == Some("disconnect") {
            return Err(Error::Transport);
        }
        Ok(())
    }
}
struct Fixed(Vec<u8>);
impl TryRngCore for Fixed {
    type Error = std::io::Error;
    fn try_next_u32(&mut self) -> Result<u32, Self::Error> {
        unreachable!()
    }
    fn try_next_u64(&mut self) -> Result<u64, Self::Error> {
        unreachable!()
    }
    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), Self::Error> {
        dest.copy_from_slice(&self.0);
        Ok(())
    }
}
impl TryCryptoRng for Fixed {}
async fn probe(
    fake: &Fake,
    vector: &Vector,
    code: &str,
    cancel: &mut watch::Receiver<bool>,
) -> Result<(), Error> {
    let result = authenticate_with_rng(
        fake,
        Zeroizing::new(code.into()),
        cancel,
        &mut Fixed(bytes(vector.ephemeral)),
    )
    .await;
    finish_probe(fake, result, cancel).await
}

#[tokio::test]
async fn whole_native_values_match_both_independent_transcripts_and_disconnect() {
    for vector in VECTORS {
        let fake = Fake::new(vector);
        let (_cancel, mut cancelled) = watch::channel(false);
        probe(&fake, vector, "000123", &mut cancelled)
            .await
            .unwrap();
        let io = fake.io.lock().unwrap();
        assert_eq!(
            io.writes.iter().map(|w| w.1.clone()).collect::<Vec<_>>(),
            vec![b"---".to_vec(), bytes(vector.start), bytes(vector.proof)]
        );
        assert_eq!(io.reads, 3);
        assert_eq!(io.disconnects, 1);
        assert!(!io.pending);
    }
    assert_eq!(bytes(VECTORS[0].start).len(), 412); // Exceeds firmware MTU256−3.
    assert_eq!(bytes(VECTORS[0].challenge).len(), 416);
}

#[tokio::test]
async fn mapping_refuses_missing_duplicate_properties_and_foreign_descriptors() {
    let (_cancel, mut cancelled) = watch::channel(false);
    for fault in 0..4 {
        let mut fake = Fake::new(&VECTORS[0]);
        let mut first = fake.chars.pop_first().unwrap();
        match fault {
            0 => (),
            1 => {
                fake.descriptions.insert(first.uuid, b"proto-ver".to_vec());
                fake.chars.insert(first);
            }
            2 => {
                first.properties = CharPropFlags::WRITE_WITHOUT_RESPONSE;
                fake.chars.insert(first);
            }
            _ => {
                let mut descriptor = first.descriptors.pop_first().unwrap();
                descriptor.service_uuid = Uuid::nil();
                first.descriptors.insert(descriptor);
                fake.chars.insert(first);
            }
        }
        assert_eq!(endpoints(&fake, &mut cancelled).await, Err(Error::Endpoint));
        assert!(fake.io.lock().unwrap().writes.is_empty());
    }
    let mut fake = Fake::new(&VECTORS[0]);
    let mut unrelated = fake.chars.first().unwrap().clone();
    unrelated.service_uuid = Uuid::nil();
    fake.chars.insert(unrelated);
    assert_eq!(endpoints(&fake, &mut cancelled).await.unwrap().len(), 6);
}

#[tokio::test]
async fn bad_proof_wrong_code_and_version_failure_never_report_success() {
    let vector = &VECTORS[0];
    for fault in 0..3 {
        let mut fake = Fake::new(vector);
        let code = if fault == 1 { "000124" } else { "000123" };
        if fault == 0 {
            fake.replies[2][15] ^= 1;
        }
        if fault == 2 {
            fake.replies[0] = br#"{"prov":{"sec_ver":1,"sec_patch_ver":1},"minerva":{"ver":"1","cap":["minerva-config"]}}"#.to_vec();
        }
        let (_cancel, mut cancelled) = watch::channel(false);
        let expected = if fault == 2 {
            Error::Version
        } else {
            Error::Authentication
        };
        assert_eq!(
            probe(&fake, vector, code, &mut cancelled).await,
            Err(expected)
        );
        assert_eq!(fake.io.lock().unwrap().disconnects, 1);
    }
}

#[tokio::test(start_paused = true)]
async fn ack_read_size_timeout_and_cancel_failure_have_no_retry_and_cleanup() {
    let vector = &VECTORS[0];
    for (fault, expected) in [
        ("ack", Error::Transport),
        ("read", Error::Transport),
        ("oversize", Error::ValueTooLarge),
        ("hang", Error::Timeout),
        ("disconnect", Error::Transport),
        ("proof_read", Error::Transport),
    ] {
        let mut fake = Fake::new(vector);
        fake.fault = Some(fault);
        let (_cancel, mut cancelled) = watch::channel(false);
        assert_eq!(
            probe(&fake, vector, "000123", &mut cancelled).await,
            Err(expected)
        );
        let io = fake.io.lock().unwrap();
        assert_eq!(io.disconnects, 1);
        if fault != "disconnect" && fault != "proof_read" {
            assert_eq!(io.writes.len(), 1);
        }
        if fault == "ack" || fault == "hang" {
            assert_eq!(io.reads, 0);
        }
    }
    let fake = Fake::new(vector);
    let (cancel, mut cancelled) = watch::channel(false);
    cancel.send(true).unwrap();
    assert_eq!(
        probe(&fake, vector, "000123", &mut cancelled).await,
        Err(Error::Cancelled)
    );
    assert_eq!(fake.io.lock().unwrap().disconnects, 1);
    assert!(fake.io.lock().unwrap().writes.is_empty());
    let characteristic = fake.chars.first().unwrap().clone();
    assert_eq!(
        exchange(&fake, &characteristic, &[0; 513], &mut cancelled).await,
        Err(Error::ValueTooLarge)
    );
    // Cancellation beats a ready late completion; dropped future cannot revive it.
    assert_eq!(
        bounded(async { Ok::<_, Error>("late") }, &mut cancelled).await,
        Err(Error::Cancelled)
    );
    let mut fake = Fake::new(vector);
    fake.fault = Some("challenge_hang");
    let (cancel, mut cancelled) = watch::channel(false);
    let cancellation = tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        cancel.send(true).unwrap();
    });
    assert_eq!(
        probe(&fake, vector, "000123", &mut cancelled).await,
        Err(Error::Cancelled)
    );
    cancellation.await.unwrap();
    let io = fake.io.lock().unwrap();
    assert_eq!(io.writes.len(), 2);
    assert_eq!(io.reads, 1);
    assert_eq!(io.disconnects, 1);
}
