//! Paired-device store (provisioning.md, "Plugin storage").
//!
//! One JSON file in the plugin data directory holds, per `device_id`, the
//! SHA-256 of its pairing token, the advertised name, the pairing time (Unix
//! seconds) and whether a LAN `hello` has confirmed it. The plaintext token is
//! hashed on entry and never stored or logged. Every change is written to a
//! temporary file, synced and renamed over the old file, so a crash leaves
//! either the old or the new store, never a torn one.

use std::collections::BTreeMap;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

pub const STORE_FILE: &str = "paired_devices.json";
const STORE_VERSION: u32 = 1;

type Digest32 = [u8; 32];

#[derive(Debug)]
pub enum StoreError {
    Io {
        action: &'static str,
        path: PathBuf,
        source: io::Error,
    },
    Corrupt {
        path: PathBuf,
        reason: String,
    },
    BadDeviceId,
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io {
                action,
                path,
                source,
            } => write!(f, "cannot {action} {}: {source}", path.display()),
            Self::Corrupt { path, reason } => {
                write!(
                    f,
                    "paired-device store {} is unusable: {reason}",
                    path.display()
                )
            }
            Self::BadDeviceId => f.write_str("device_id must be 12 lowercase hex digits"),
        }
    }
}

impl std::error::Error for StoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceRecord {
    pub name: String,
    pub paired_at: u64,
    pub confirmed: bool,
    token_sha256: Digest32,
}

#[derive(Serialize, Deserialize)]
struct StoredRecord {
    token_sha256: String,
    name: String,
    paired_at: u64,
    confirmed: bool,
}

#[derive(Serialize, Deserialize)]
struct StoredFile {
    version: u32,
    devices: BTreeMap<String, StoredRecord>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// The token matches. `newly_confirmed` is true when this is the first
    /// `hello` for the record; the caller then persists it with `confirm`.
    Accepted {
        newly_confirmed: bool,
    },
    Refused,
}

pub struct TokenStore {
    path: PathBuf,
    devices: Mutex<BTreeMap<String, DeviceRecord>>,
}

impl TokenStore {
    /// Opens the store in `data_dir`, creating the directory if needed. A
    /// missing file is an empty store; an unreadable or malformed one is an
    /// error, never silently replaced.
    pub fn open(data_dir: &Path) -> Result<Self, StoreError> {
        fs::create_dir_all(data_dir).map_err(|source| StoreError::Io {
            action: "create",
            path: data_dir.to_path_buf(),
            source,
        })?;
        let path = data_dir.join(STORE_FILE);
        let devices = match fs::read(&path) {
            Ok(bytes) => parse(&path, &bytes)?,
            Err(e) if e.kind() == io::ErrorKind::NotFound => BTreeMap::new(),
            Err(source) => {
                return Err(StoreError::Io {
                    action: "read",
                    path,
                    source,
                })
            }
        };
        Ok(Self {
            path,
            devices: Mutex::new(devices),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Stores a new pairing for `device_id`, replacing any earlier one so its
    /// old token stops working. The record starts unconfirmed.
    pub fn pair(
        &self,
        device_id: &str,
        token: &str,
        name: &str,
        paired_at: u64,
    ) -> Result<(), StoreError> {
        if !is_device_id(device_id) {
            return Err(StoreError::BadDeviceId);
        }
        let mut devices = self.lock();
        let mut next = devices.clone();
        next.insert(
            device_id.to_owned(),
            DeviceRecord {
                name: name.to_owned(),
                paired_at,
                confirmed: false,
                token_sha256: hash(token),
            },
        );
        self.persist(&next)?;
        *devices = next;
        Ok(())
    }

    /// Deletes the record; the device's next `hello` is refused.
    pub fn remove(&self, device_id: &str) -> Result<bool, StoreError> {
        let mut devices = self.lock();
        if !devices.contains_key(device_id) {
            return Ok(false);
        }
        let mut next = devices.clone();
        next.remove(device_id);
        self.persist(&next)?;
        *devices = next;
        Ok(true)
    }

    pub fn record(&self, device_id: &str) -> Option<DeviceRecord> {
        self.lock().get(device_id).cloned()
    }

    /// Compares the token's hash with the stored one in constant time. An
    /// unknown device is compared against a zero digest so both refusals do
    /// the same work.
    pub fn verify(&self, device_id: &str, token: &str) -> Verdict {
        let presented = hash(token);
        let devices = self.lock();
        let record = devices.get(device_id);
        let stored = record.map_or([0u8; 32], |r| r.token_sha256);
        let matches: bool = presented.ct_eq(&stored).into();
        match record {
            Some(r) if matches => Verdict::Accepted {
                newly_confirmed: !r.confirmed,
            },
            _ => Verdict::Refused,
        }
    }

    /// Marks the record confirmed and persists it. A record replaced or
    /// removed since `verify` is left alone.
    pub fn confirm(&self, device_id: &str, token: &str) -> Result<(), StoreError> {
        let mut devices = self.lock();
        let presented = hash(token);
        let Some(record) = devices.get(device_id) else {
            return Ok(());
        };
        if record.confirmed || !bool::from(presented.ct_eq(&record.token_sha256)) {
            return Ok(());
        }
        let mut next = devices.clone();
        if let Some(r) = next.get_mut(device_id) {
            r.confirmed = true;
        }
        self.persist(&next)?;
        *devices = next;
        Ok(())
    }

    fn lock(&self) -> MutexGuard<'_, BTreeMap<String, DeviceRecord>> {
        // A panic while holding the lock cannot leave the map half-updated:
        // every writer swaps in a complete map only after persisting it.
        self.devices.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn persist(&self, devices: &BTreeMap<String, DeviceRecord>) -> Result<(), StoreError> {
        let file = StoredFile {
            version: STORE_VERSION,
            devices: devices
                .iter()
                .map(|(id, r)| {
                    (
                        id.clone(),
                        StoredRecord {
                            token_sha256: hex::encode(r.token_sha256),
                            name: r.name.clone(),
                            paired_at: r.paired_at,
                            confirmed: r.confirmed,
                        },
                    )
                })
                .collect(),
        };
        let mut bytes = serde_json::to_vec_pretty(&file).map_err(|e| StoreError::Corrupt {
            path: self.path.clone(),
            reason: e.to_string(),
        })?;
        bytes.push(b'\n');
        write_atomic(&self.path, &bytes)
    }
}

fn parse(path: &Path, bytes: &[u8]) -> Result<BTreeMap<String, DeviceRecord>, StoreError> {
    let corrupt = |reason: String| StoreError::Corrupt {
        path: path.to_path_buf(),
        reason,
    };
    let file: StoredFile = serde_json::from_slice(bytes).map_err(|e| corrupt(e.to_string()))?;
    if file.version != STORE_VERSION {
        return Err(corrupt(format!("unsupported version {}", file.version)));
    }
    let mut devices = BTreeMap::new();
    for (id, r) in file.devices {
        if !is_device_id(&id) {
            return Err(corrupt(format!("bad device_id {id:?}")));
        }
        let token_sha256: Digest32 = hex::decode(&r.token_sha256)
            .ok()
            .and_then(|v| v.try_into().ok())
            .ok_or_else(|| corrupt(format!("bad token_sha256 for {id}")))?;
        devices.insert(
            id,
            DeviceRecord {
                name: r.name,
                paired_at: r.paired_at,
                confirmed: r.confirmed,
                token_sha256,
            },
        );
    }
    Ok(devices)
}

fn hash(token: &str) -> Digest32 {
    Sha256::digest(token.as_bytes()).into()
}

pub fn is_device_id(id: &str) -> bool {
    id.len() == 12 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), StoreError> {
    let io_err = |action: &'static str, p: &Path| {
        let p = p.to_path_buf();
        move |source| StoreError::Io {
            action,
            path: p,
            source,
        }
    };
    let mut tmp_name = path.as_os_str().to_owned();
    tmp_name.push(".tmp");
    let tmp = PathBuf::from(tmp_name);
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&tmp).map_err(io_err("create", &tmp))?;
    file.write_all(bytes).map_err(io_err("write", &tmp))?;
    file.sync_all().map_err(io_err("sync", &tmp))?;
    drop(file);
    fs::rename(&tmp, path).map_err(io_err("replace", path))?;
    #[cfg(unix)]
    if let Some(dir) = path.parent() {
        File::open(dir)
            .and_then(|d| d.sync_all())
            .map_err(io_err("sync", dir))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "a4cf12b03e5d";
    const TOKEN: &str = "3f9a1c0e7b2d4a6f-plaintext-token";

    #[test]
    fn pair_verify_confirm_survives_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::open(dir.path()).unwrap();
        assert_eq!(store.verify(ID, TOKEN), Verdict::Refused);
        store.pair(ID, TOKEN, "SR2-3E5D", 1_760_000_000).unwrap();
        assert_eq!(
            store.verify(ID, TOKEN),
            Verdict::Accepted {
                newly_confirmed: true
            }
        );
        assert_eq!(store.verify(ID, "wrong-token-xxxxxxxx"), Verdict::Refused);
        assert_eq!(store.verify("000000000000", TOKEN), Verdict::Refused);
        store.confirm(ID, TOKEN).unwrap();

        let reopened = TokenStore::open(dir.path()).unwrap();
        let record = reopened.record(ID).unwrap();
        assert!(record.confirmed);
        assert_eq!(record.name, "SR2-3E5D");
        assert_eq!(record.paired_at, 1_760_000_000);
        assert_eq!(
            reopened.verify(ID, TOKEN),
            Verdict::Accepted {
                newly_confirmed: false
            }
        );
    }

    #[test]
    fn file_holds_only_the_hash_and_no_temp_file_remains() {
        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::open(dir.path()).unwrap();
        store.pair(ID, TOKEN, "SR2-3E5D", 1).unwrap();
        let text = fs::read_to_string(store.path()).unwrap();
        assert!(!text.contains(TOKEN));
        assert!(text.contains(&hex::encode(Sha256::digest(TOKEN.as_bytes()))));
        let names: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, vec![std::ffi::OsString::from(STORE_FILE)]);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(store.path()).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[test]
    fn repair_replaces_and_remove_refuses() {
        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::open(dir.path()).unwrap();
        store.pair(ID, TOKEN, "a", 1).unwrap();
        store.confirm(ID, TOKEN).unwrap();
        store.pair(ID, "new-token-0123456789", "a", 2).unwrap();
        assert_eq!(store.verify(ID, TOKEN), Verdict::Refused);
        assert!(!store.record(ID).unwrap().confirmed);
        assert!(store.remove(ID).unwrap());
        assert!(!store.remove(ID).unwrap());
        assert_eq!(store.verify(ID, "new-token-0123456789"), Verdict::Refused);
        assert!(TokenStore::open(dir.path()).unwrap().record(ID).is_none());
    }

    #[test]
    fn confirm_ignores_a_record_replaced_since_verify() {
        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::open(dir.path()).unwrap();
        store.pair(ID, TOKEN, "a", 1).unwrap();
        store.pair(ID, "replacement-token-xx", "a", 2).unwrap();
        store.confirm(ID, TOKEN).unwrap();
        assert!(!store.record(ID).unwrap().confirmed);
    }

    #[test]
    fn rejects_bad_ids_and_corrupt_files() {
        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::open(dir.path()).unwrap();
        assert!(matches!(
            store.pair("A4CF12B03E5D", TOKEN, "a", 1),
            Err(StoreError::BadDeviceId)
        ));
        fs::write(dir.path().join(STORE_FILE), b"{not json").unwrap();
        assert!(matches!(
            TokenStore::open(dir.path()),
            Err(StoreError::Corrupt { .. })
        ));
        fs::write(
            dir.path().join(STORE_FILE),
            br#"{"version":1,"devices":{"a4cf12b03e5d":{"token_sha256":"abcd","name":"","paired_at":0,"confirmed":false}}}"#,
        )
        .unwrap();
        assert!(matches!(
            TokenStore::open(dir.path()),
            Err(StoreError::Corrupt { .. })
        ));
    }
}
