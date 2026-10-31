//! RFC2617/7616 Digest rules. Cryptographic primitives belong to established crates.
use std::collections::BTreeMap;

use md5::{Digest, Md5};
use sha2::{Sha256, Sha512_256};

use crate::error::{Error, Result};

#[derive(Clone)]
pub struct Challenge {
    pub realm: String,
    nonce: String,
    opaque: Option<String>,
    algorithm: Algorithm,
    auth: bool,
    userhash: bool,
}
#[derive(Clone, Copy)]
enum Algorithm {
    Md5,
    Md5Session,
    Sha256,
    Sha256Session,
    Sha512,
    Sha512Session,
}
impl Algorithm {
    fn name(self) -> &'static str {
        match self {
            Self::Md5 => "MD5",
            Self::Md5Session => "MD5-sess",
            Self::Sha256 => "SHA-256",
            Self::Sha256Session => "SHA-256-sess",
            Self::Sha512 => "SHA-512-256",
            Self::Sha512Session => "SHA-512-256-sess",
        }
    }
    fn hash(self, value: &str) -> String {
        match self {
            Self::Md5 | Self::Md5Session => format!("{:x}", Md5::digest(value.as_bytes())),
            Self::Sha256 | Self::Sha256Session => format!("{:x}", Sha256::digest(value.as_bytes())),
            Self::Sha512 | Self::Sha512Session => {
                format!("{:x}", Sha512_256::digest(value.as_bytes()))
            }
        }
    }
    fn session(self) -> bool {
        matches!(
            self,
            Self::Md5Session | Self::Sha256Session | Self::Sha512Session
        )
    }
}

fn parameters(value: &str) -> Result<BTreeMap<String, String>> {
    let (scheme, mut rest) = value.trim().split_once(' ').ok_or(Error::Protocol(
        "Printer did not provide Digest authentication",
    ))?;
    if !scheme.eq_ignore_ascii_case("Digest") {
        return Err(Error::Protocol(
            "Printer did not provide Digest authentication",
        ));
    }
    let mut result = BTreeMap::new();
    while !rest
        .trim_matches(|c: char| c.is_whitespace() || c == ',')
        .is_empty()
    {
        rest = rest.trim_start_matches(|c: char| c.is_whitespace() || c == ',');
        let (key, tail) = rest
            .split_once('=')
            .ok_or(Error::Protocol("Malformed Digest challenge"))?;
        let key = key.trim().to_ascii_lowercase();
        if key.is_empty() || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            return Err(Error::Protocol("Malformed Digest challenge"));
        }
        let tail = tail.trim_start();
        let (value, remainder) = if let Some(quoted) = tail.strip_prefix('"') {
            let mut value = String::new();
            let mut escaped = false;
            let mut end = None;
            for (i, ch) in quoted.char_indices() {
                if escaped {
                    value.push(ch);
                    escaped = false;
                } else if ch == '\\' {
                    escaped = true;
                } else if ch == '"' {
                    end = Some(i + 1);
                    break;
                } else {
                    value.push(ch);
                }
            }
            let end = end.ok_or(Error::Protocol("Malformed Digest challenge"))?;
            (value, &quoted[end..])
        } else {
            let end = tail.find(',').unwrap_or(tail.len());
            (tail[..end].trim().to_owned(), &tail[end..])
        };
        if value.chars().any(char::is_control) || result.insert(key, value).is_some() {
            return Err(Error::Protocol("Malformed Digest challenge"));
        }
        rest = remainder.trim_start();
        if !rest.is_empty() && !rest.starts_with(',') {
            return Err(Error::Protocol("Malformed Digest challenge"));
        }
    }
    Ok(result)
}

impl Challenge {
    pub fn parse(value: &str) -> Result<Self> {
        let mut fields = parameters(value)?;
        let realm = fields
            .remove("realm")
            .ok_or(Error::Protocol("Digest realm missing"))?;
        let nonce = fields
            .remove("nonce")
            .filter(|s| !s.is_empty())
            .ok_or(Error::Protocol("Digest nonce missing"))?;
        let algorithm = match fields
            .remove("algorithm")
            .unwrap_or_else(|| "MD5".into())
            .to_ascii_uppercase()
            .as_str()
        {
            "MD5" => Algorithm::Md5,
            "MD5-SESS" => Algorithm::Md5Session,
            "SHA-256" => Algorithm::Sha256,
            "SHA-256-SESS" => Algorithm::Sha256Session,
            "SHA-512-256" => Algorithm::Sha512,
            "SHA-512-256-SESS" => Algorithm::Sha512Session,
            _ => return Err(Error::Protocol("Printer Digest algorithm is unsupported")),
        };
        let qop = fields.remove("qop");
        let auth = qop
            .as_ref()
            .is_some_and(|s| s.split(',').any(|v| v.trim().eq_ignore_ascii_case("auth")));
        if qop.is_some() && !auth {
            return Err(Error::Protocol("Printer requires unsupported Digest qop"));
        }
        if fields
            .get("charset")
            .is_some_and(|s| !s.eq_ignore_ascii_case("UTF-8"))
        {
            return Err(Error::Protocol("Printer Digest charset is unsupported"));
        }
        Ok(Self {
            realm,
            nonce,
            opaque: fields.remove("opaque"),
            algorithm,
            auth,
            userhash: fields
                .get("userhash")
                .is_some_and(|s| s.eq_ignore_ascii_case("true")),
        })
    }
    pub fn authorization(
        &self,
        method: &str,
        uri: &str,
        user: &str,
        password: &str,
        cnonce: &str,
        count: u32,
    ) -> Result<String> {
        if user.contains(':')
            || user.chars().any(char::is_control)
            || uri.chars().any(char::is_control)
        {
            return Err(Error::Invalid("Invalid Digest username or request path"));
        }
        let hash = |value: &str| self.algorithm.hash(value);
        let a1 = hash(&format!("{user}:{}:{password}", self.realm));
        let a1 = if self.algorithm.session() {
            hash(&format!("{a1}:{}:{cnonce}", self.nonce))
        } else {
            a1
        };
        let a2 = hash(&format!("{method}:{uri}"));
        let nc = format!("{count:08x}");
        let response = if self.auth {
            hash(&format!("{a1}:{}:{nc}:{cnonce}:auth:{a2}", self.nonce))
        } else {
            hash(&format!("{a1}:{}:{a2}", self.nonce))
        };
        let username = if self.userhash {
            hash(&format!("{user}:{}", self.realm))
        } else {
            user.to_owned()
        };
        let mut fields = vec![
            format!("username={}", quote(&username)),
            format!("realm={}", quote(&self.realm)),
            format!("nonce={}", quote(&self.nonce)),
            format!("uri={}", quote(uri)),
            format!("response={}", quote(&response)),
            format!("algorithm={}", self.algorithm.name()),
        ];
        if self.auth {
            fields.extend([
                "qop=auth".into(),
                format!("nc={nc}"),
                format!("cnonce={}", quote(cnonce)),
            ]);
        } else if self.algorithm.session() {
            fields.push(format!("cnonce={}", quote(cnonce)));
        }
        if let Some(opaque) = &self.opaque {
            fields.push(format!("opaque={}", quote(opaque)));
        }
        if self.userhash {
            fields.push("userhash=true".into());
        }
        Ok(format!("Digest {}", fields.join(", ")))
    }
}
fn quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn published_rfc2617_vector() {
        // Public RFC example, never an owner's credential.
        let c=Challenge::parse("Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"").unwrap();
        let header = c
            .authorization(
                "GET",
                "/dir/index.html",
                "Mufasa",
                "Circle Of Life",
                "0a4f113b",
                1,
            )
            .unwrap();
        assert!(header.contains("response=\"6629fae49393a05397450978507c4ef1\""));
    }
    #[test]
    fn published_rfc7616_sha256_and_md5_vectors() {
        for (algorithm, response) in [
            ("MD5", "8ca523f5e9506fed4657c9700eebdbec"),
            (
                "SHA-256",
                "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1",
            ),
        ] {
            let c=Challenge::parse(&format!("Digest realm=\"http-auth@example.org\", qop=\"auth, auth-int\", algorithm={algorithm}, nonce=\"7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v\", opaque=\"FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS\"")).unwrap();
            let header = c
                .authorization(
                    "GET",
                    "/dir/index.html",
                    "Mufasa",
                    "Circle of Life",
                    "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ",
                    1,
                )
                .unwrap();
            assert!(
                header.contains(&format!("response=\"{response}\"")),
                "RFC {algorithm} vector"
            );
        }
    }
}
