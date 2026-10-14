use super::{wire::*, Error, SecretBytes};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::Deserialize;
use zeroize::Zeroizing;

pub fn config_request(host: &str, port: u16, token: &str) -> Result<SecretBytes, Error> {
    if port == 0
        || host.is_empty()
        || host.len() > 253
        || !host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
    {
        return Err(Error::Config);
    }
    if token.len() != 43 {
        return Err(Error::Config);
    }
    let decoded = Zeroizing::new(URL_SAFE_NO_PAD.decode(token).map_err(|_| Error::Config)?);
    if decoded.len() != 32 {
        return Err(Error::Config);
    }
    #[derive(serde::Serialize)]
    struct Config<'a> {
        v: u32,
        host: &'a str,
        port: u16,
        token: &'a str,
    }
    serde_json::to_vec(&Config {
        v: 1,
        host,
        port,
        token,
    })
    .map(SecretBytes::from)
    .map_err(|_| Error::Config)
}

pub fn config_response(bytes: &[u8]) -> Result<String, Error> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Reply {
        v: u32,
        ok: bool,
        device_id: Option<String>,
        error: Option<String>,
    }
    if bytes.len() > 512 {
        return Err(Error::Malformed);
    }
    let reply: Reply = serde_json::from_slice(bytes).map_err(|_| Error::Malformed)?;
    if reply.v != 1 {
        return Err(Error::Version);
    }
    if !reply.ok || reply.error.is_some() {
        return Err(Error::Config);
    }
    let id = reply.device_id.ok_or(Error::Malformed)?;
    if id.len() != 12
        || !id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(Error::Malformed);
    }
    Ok(id)
}

pub fn wifi_config(ssid: &[u8], password: &[u8]) -> Result<SecretBytes, Error> {
    use prost::Message;
    use zeroize::Zeroize;
    if ssid.is_empty() || ssid.len() > 32 || password.len() > 64 {
        return Err(Error::Config);
    }
    let mut message = WiFiConfigPayload {
        msg: WiFiConfigMsgType::TypeCmdSetConfig as i32,
        payload: Some(wi_fi_config_payload::Payload::CmdSetConfig(CmdSetConfig {
            ssid: ssid.to_vec(),
            passphrase: password.to_vec(),
            bssid: vec![],
            channel: 0,
        })),
    };
    let result = SecretBytes::from(message.encode_to_vec());
    if let Some(wi_fi_config_payload::Payload::CmdSetConfig(ref mut config)) = message.payload {
        config.passphrase.zeroize();
        config.ssid.zeroize();
    }
    Ok(result)
}
