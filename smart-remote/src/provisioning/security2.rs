use super::{decode, wire::*, Error, SecretBytes};
use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use prost::Message;
use rand_core::{OsRng, TryCryptoRng};
use sha2_security::Sha512;
use srp::{ClientG3072, ClientVerifier, Group};
use zeroize::Zeroizing;

const USER: &[u8] = b"minerva-remote";
enum State {
    Challenge(Zeroizing<[u8; 32]>, Zeroizing<String>),
    Proof(Box<ClientVerifier<Sha512>>),
    Ready(Box<Channel>),
    Dead,
}
struct Channel {
    cipher: Aes256Gcm,
    nonce: [u8; 12],
    pending: bool,
}
/// One encrypted request/reply at a time. Transport or application decoding
/// errors after dispatch must cancel; retry requires a fresh handshake.
pub struct Session {
    state: State,
}
impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Security2 Session [redacted]")
    }
}
impl Session {
    pub fn start(code: Zeroizing<String>, patch: u32) -> Result<(Self, Vec<u8>), Error> {
        Self::start_with_rng(code, patch, &mut OsRng)
    }
    pub fn start_with_rng<R: TryCryptoRng>(
        code: Zeroizing<String>,
        patch: u32,
        rng: &mut R,
    ) -> Result<(Self, Vec<u8>), Error> {
        let mut secret = Zeroizing::new([0; 32]);
        rng.try_fill_bytes(secret.as_mut())
            .map_err(|_| Error::Random)?;
        Self::start_inner(code, patch, secret)
    }
    fn start_inner(
        code: Zeroizing<String>,
        patch: u32,
        secret: Zeroizing<[u8; 32]>,
    ) -> Result<(Self, Vec<u8>), Error> {
        if patch != 1 {
            return Err(Error::Version);
        }
        if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) {
            return Err(Error::Config);
        }
        if secret.iter().all(|b| *b == 0) {
            return Err(Error::Random);
        }
        let public = ClientG3072::<Sha512>::new().compute_public_ephemeral(secret.as_ref());
        let request = packet(
            Sec2MsgType::S2SessionCommand0,
            sec2_payload::Payload::Sc0(S2SessionCmd0 {
                client_username: USER.to_vec(),
                client_pubkey: public,
            }),
        );
        Ok((
            Self {
                state: State::Challenge(secret, code),
            },
            request,
        ))
    }
    pub fn challenge(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Error> {
        let old = std::mem::replace(&mut self.state, State::Dead);
        let State::Challenge(secret, code) = old else {
            return Err(Error::State);
        };
        let response = response(bytes, Sec2MsgType::S2SessionResponse0)?;
        let Some(sec2_payload::Payload::Sr0(reply)) = response.payload else {
            return Err(Error::Malformed);
        };
        if reply.status != 0
            || reply.device_salt.len() != 16
            || reply.device_pubkey.is_empty()
            || reply.device_pubkey.len() > 384
        {
            return Err(Error::Malformed);
        }
        let group = srp::groups::G3072::generator();
        let modulus = group.params().modulus().to_be_bytes();
        if reply.device_pubkey.len() == 384 && reply.device_pubkey.as_slice() >= modulus.as_ref() {
            return Err(Error::Proof);
        }
        let verifier = ClientG3072::<Sha512>::new()
            .process_reply(
                secret.as_ref(),
                USER,
                code.as_bytes(),
                &reply.device_salt,
                &reply.device_pubkey,
            )
            .map_err(|_| Error::Proof)?;
        let request = packet(
            Sec2MsgType::S2SessionCommand1,
            sec2_payload::Payload::Sc1(S2SessionCmd1 {
                client_proof: verifier.proof().to_vec(),
            }),
        );
        self.state = State::Proof(Box::new(verifier));
        Ok(request)
    }
    pub fn finish(&mut self, bytes: &[u8]) -> Result<(), Error> {
        let old = std::mem::replace(&mut self.state, State::Dead);
        let State::Proof(verifier) = old else {
            return Err(Error::State);
        };
        let response = response(bytes, Sec2MsgType::S2SessionResponse1)?;
        let Some(sec2_payload::Payload::Sr1(reply)) = response.payload else {
            return Err(Error::Malformed);
        };
        if reply.status != 0 || reply.device_nonce.len() != 12 {
            return Err(Error::Malformed);
        }
        let nonce: [u8; 12] = reply
            .device_nonce
            .try_into()
            .map_err(|_| Error::Malformed)?;
        if nonce[8..] != 1u32.to_be_bytes() {
            return Err(Error::Counter);
        }
        // verify_server returns H(S); key() is the raw premaster and is not the AES key.
        let key = verifier
            .verify_server(&reply.device_proof)
            .map_err(|_| Error::Proof)?;
        let cipher = Aes256Gcm::new_from_slice(&key[..32]).map_err(|_| Error::Cipher)?;
        self.state = State::Ready(Box::new(Channel {
            cipher,
            nonce,
            pending: false,
        }));
        Ok(())
    }
    pub fn encrypt(&mut self, bytes: &[u8]) -> Result<SecretBytes, Error> {
        self.crypt(bytes, true)
    }
    pub fn decrypt(&mut self, bytes: &[u8]) -> Result<SecretBytes, Error> {
        self.crypt(bytes, false)
    }
    fn crypt(&mut self, bytes: &[u8], encrypt: bool) -> Result<SecretBytes, Error> {
        let old = std::mem::replace(&mut self.state, State::Dead);
        let State::Ready(mut channel) = old else {
            return Err(Error::State);
        };
        if channel.pending == encrypt {
            return Err(Error::State);
        }
        if bytes.len() > if encrypt { 4080 } else { 4096 } {
            return Err(Error::Malformed);
        }
        let count = u32::from_be_bytes(channel.nonce[8..].try_into().map_err(|_| Error::Counter)?);
        // A request reserves its response too; the counter never wraps or retries.
        if count == 0 || count == u32::MAX || (encrypt && count == u32::MAX - 1) {
            return Err(Error::Counter);
        }
        let nonce = Nonce::from(channel.nonce);
        let result = if encrypt {
            channel.cipher.encrypt(&nonce, bytes)
        } else {
            channel.cipher.decrypt(&nonce, bytes)
        }
        .map_err(|_| Error::Cipher)?;
        channel.nonce[8..].copy_from_slice(&(count + 1).to_be_bytes());
        channel.pending = encrypt;
        self.state = State::Ready(channel);
        Ok(SecretBytes::from(result))
    }
    pub fn cancel(&mut self) {
        self.state = State::Dead;
    }
}
fn packet(kind: Sec2MsgType, payload: sec2_payload::Payload) -> Vec<u8> {
    SessionData {
        sec_ver: 2,
        proto: Some(session_data::Proto::Sec2(Sec2Payload {
            msg: kind as i32,
            payload: Some(payload),
        })),
    }
    .encode_to_vec()
}
fn response(bytes: &[u8], kind: Sec2MsgType) -> Result<Sec2Payload, Error> {
    let message: SessionData = decode(bytes)?;
    if message.sec_ver != 2 {
        return Err(Error::Version);
    }
    let Some(session_data::Proto::Sec2(payload)) = message.proto else {
        return Err(Error::Malformed);
    };
    if payload.msg != kind as i32 {
        return Err(Error::Malformed);
    }
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn counter_limit_refuses_a_request_without_room_for_its_response() {
        for count in [0, u32::MAX - 1, u32::MAX] {
            let mut nonce = [0; 12];
            nonce[8..].copy_from_slice(&count.to_be_bytes());
            let mut session = Session {
                state: State::Ready(Box::new(Channel {
                    cipher: Aes256Gcm::new_from_slice(&[0; 32]).unwrap(),
                    nonce,
                    pending: false,
                })),
            };
            assert_eq!(session.encrypt(b"public-test-payload"), Err(Error::Counter));
            assert_eq!(session.encrypt(b"public-test-payload"), Err(Error::State));
        }
    }
}
