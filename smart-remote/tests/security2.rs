use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use prost::Message;
use rand_core::{TryCryptoRng, TryRngCore};
use smart_remote_plugin::provisioning::{decode, wire::*, Error, Session};
use zeroize::Zeroizing;

#[path = "fixtures/security2.rs"]
mod fixtures;
use fixtures::{Vector, VECTORS};
fn bytes(value: &str) -> Vec<u8> {
    hex::decode(value).unwrap()
}
struct Fixed(Vec<u8>);
impl TryRngCore for Fixed {
    type Error = std::io::Error;
    fn try_next_u32(&mut self) -> Result<u32, Self::Error> {
        Err(std::io::ErrorKind::Unsupported.into())
    }
    fn try_next_u64(&mut self) -> Result<u64, Self::Error> {
        Err(std::io::ErrorKind::Unsupported.into())
    }
    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), Self::Error> {
        if dest.len() != self.0.len() {
            return Err(std::io::ErrorKind::InvalidInput.into());
        }
        dest.copy_from_slice(&self.0);
        Ok(())
    }
}
impl TryCryptoRng for Fixed {}
fn start(v: &Vector, code: &str) -> (Session, Vec<u8>) {
    Session::start_with_rng(
        Zeroizing::new(code.into()),
        1,
        &mut Fixed(bytes(v.ephemeral)),
    )
    .unwrap()
}
fn ready(v: &Vector) -> Session {
    let (mut client, first) = start(v, "000123");
    assert_eq!(first, bytes(v.start));
    assert_eq!(
        client.challenge(&bytes(v.challenge)).unwrap(),
        bytes(v.proof)
    );
    client.finish(&bytes(v.finish)).unwrap();
    client
}
#[test]
fn official_espressif_transcripts_match_full_and_short_public_keys() {
    for v in VECTORS {
        let mut client = ready(v);
        assert_eq!(
            *client.encrypt(&bytes(v.config)).unwrap(),
            bytes(v.config_encrypted)
        );
        assert_eq!(
            *client.decrypt(&bytes(v.config_response)).unwrap(),
            bytes(v.config_reply)
        );
        assert_eq!(
            *client.encrypt(&bytes(v.wifi)).unwrap(),
            bytes(v.wifi_encrypted)
        );
        let response: WiFiConfigPayload =
            decode(&client.decrypt(&bytes(v.wifi_response)).unwrap()).unwrap();
        assert_eq!(response.msg, WiFiConfigMsgType::TypeRespSetConfig as i32);
        let key = bytes(v.session_key);
        let cipher = Aes256Gcm::new_from_slice(&key[..32]).unwrap();
        let nonce = Nonce::from([0, 1, 2, 3, 4, 5, 6, 7, 0, 0, 0, 1]);
        assert_eq!(
            cipher
                .decrypt(&nonce, bytes(v.config_encrypted).as_slice())
                .unwrap(),
            bytes(v.config)
        );
    }
}
#[test]
fn failed_authentication_never_enables_credentials() {
    let v = &VECTORS[0];
    for code in ["000123", "000124"] {
        let (mut client, _) = start(v, code);
        let proof = client.challenge(&bytes(v.challenge)).unwrap();
        let mut finish: SessionData = decode(&bytes(v.finish)).unwrap();
        if code == "000123" {
            if let Some(session_data::Proto::Sec2(ref mut p)) = finish.proto {
                if let Some(sec2_payload::Payload::Sr1(ref mut r)) = p.payload {
                    r.device_proof[0] ^= 1;
                }
            }
        } else {
            assert_ne!(proof, bytes(v.proof));
        }
        assert_eq!(client.finish(&finish.encode_to_vec()), Err(Error::Proof));
        assert_eq!(client.encrypt(b"secret"), Err(Error::State));
        assert_eq!(client.finish(&bytes(v.finish)), Err(Error::State));
    }
    for patch in [0, 2] {
        assert!(matches!(
            Session::start(Zeroizing::new("000123".into()), patch),
            Err(Error::Version)
        ));
    }
    let (mut client, _) = start(v, "000123");
    assert_eq!(client.encrypt(b"secret"), Err(Error::State));
    assert_eq!(client.challenge(&bytes(v.challenge)), Err(Error::State));
}
#[test]
fn malformed_messages_and_statuses_destroy_the_handshake() {
    let v = &VECTORS[0];
    let mut cases = vec![vec![], vec![0xff; 4097]];
    for change in 0..8 {
        let mut msg: SessionData = decode(&bytes(v.challenge)).unwrap();
        if let Some(session_data::Proto::Sec2(ref mut p)) = msg.proto {
            if let Some(sec2_payload::Payload::Sr0(ref mut r)) = p.payload {
                match change {
                    0 => r.device_pubkey = vec![0],
                    1 => r.device_pubkey = vec![1; 385],
                    2 => r.device_salt.pop().map(|_| ()).unwrap(),
                    3 => r.status = 1,
                    4 => r.device_pubkey = vec![255; 384],
                    5 => p.msg = 3,
                    6 => msg.sec_ver = 1,
                    _ => msg.sec_ver = 0,
                }
            }
        }
        cases.push(msg.encode_to_vec());
    }
    for message in cases {
        let (mut client, _) = start(v, "000123");
        assert!(client.challenge(&message).is_err());
        assert_eq!(client.challenge(&bytes(v.challenge)), Err(Error::State));
    }
    for change in 0..3 {
        let (mut client, _) = start(v, "000123");
        client.challenge(&bytes(v.challenge)).unwrap();
        let mut msg: SessionData = decode(&bytes(v.finish)).unwrap();
        if let Some(session_data::Proto::Sec2(ref mut p)) = msg.proto {
            if let Some(sec2_payload::Payload::Sr1(ref mut r)) = p.payload {
                match change {
                    0 => r.device_nonce.pop().map(|_| ()).unwrap(),
                    1 => r.status = 1,
                    _ => r.device_nonce[11] = 0,
                }
            }
        }
        assert!(client.finish(&msg.encode_to_vec()).is_err());
        assert_eq!(client.encrypt(b"secret"), Err(Error::State));
    }
}
#[test]
fn replay_tag_failure_pipelining_and_cancel_destroy_the_cipher() {
    let v = &VECTORS[0];
    for corrupt in [true, false] {
        let mut client = ready(v);
        client.encrypt(&bytes(v.config)).unwrap();
        let mut reply = bytes(v.config_response);
        if corrupt {
            reply[0] ^= 1;
        } else {
            client.decrypt(&reply).unwrap();
            client.encrypt(&bytes(v.wifi)).unwrap();
        }
        assert_eq!(client.decrypt(&reply), Err(Error::Cipher));
        assert_eq!(client.encrypt(b"secret"), Err(Error::State));
    }
    let mut client = ready(v);
    client.encrypt(&bytes(v.config)).unwrap();
    assert_eq!(client.encrypt(b"another request"), Err(Error::State));
    assert_eq!(client.decrypt(&bytes(v.config_response)), Err(Error::State));
    let mut client = ready(v);
    client.cancel();
    assert_eq!(client.encrypt(b"secret"), Err(Error::State));
    assert!(!format!("{client:?}").contains("000123"));
}
