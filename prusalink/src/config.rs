//! Only nonsecret printer metadata is persisted. Vault handles are fixed exact grants.
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use url::Url;

use crate::error::{Error, Result};

pub const SLOTS: usize = 8; // Owner-approved disposition627: exact host grants, editable display names.

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Printer {
    pub slot: u8,
    pub name: String,
    pub host: String,
    pub user: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slicing: Option<crate::slicer::SlicerConfig>,
}
impl Printer {
    pub fn id(&self) -> String {
        format!("printer{}", self.slot)
    }
    pub fn handle(&self) -> String {
        format!("prusalink_{}", self.id())
    }
}
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    printers: Vec<Printer>,
}

pub struct Store {
    root: PathBuf,
    config: Config,
}
impl Store {
    pub fn open(root: PathBuf) -> Result<Self> {
        if !root.is_absolute() || (cfg!(target_os = "macos") && root.starts_with("/home")) {
            return Err(Error::Invalid(
                "Plugin data directory must be an absolute local path",
            ));
        }
        let path = root.join("printers.json");
        let config = match fs::read(path) {
            Ok(bytes) => serde_json::from_slice::<Config>(&bytes).map_err(|_| Error::Config)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Config::default(),
            Err(_) => return Err(Error::Config),
        };
        for (i, printer) in config.printers.iter().enumerate() {
            validate_printer(printer)?;
            if config.printers[..i]
                .iter()
                .any(|p| p.slot == printer.slot || p.name.eq_ignore_ascii_case(&printer.name))
            {
                return Err(Error::Config);
            }
        }
        Ok(Self { root, config })
    }
    pub fn list(&self) -> &[Printer] {
        &self.config.printers
    }
    pub fn get(&self, id: &str) -> Result<&Printer> {
        self.config
            .printers
            .iter()
            .find(|p| p.id() == id)
            .or_else(|| {
                self.config
                    .printers
                    .iter()
                    .find(|p| p.name.eq_ignore_ascii_case(id))
            })
            .ok_or(Error::Invalid("Unknown printer; add it in the panel first"))
    }
    pub fn configure(
        &mut self,
        slot: Option<u8>,
        name: String,
        host: String,
        user: String,
        slicing: Option<crate::slicer::SlicerConfig>,
    ) -> Result<Printer> {
        let slot = match slot {
            Some(slot) => slot,
            None => (1..=SLOTS as u8)
                .find(|slot| !self.config.printers.iter().any(|p| p.slot == *slot))
                .ok_or(Error::Invalid(
                    "All eight printer slots are in use; remove one first",
                ))?,
        };
        let host = normalize_host(&host)?;
        let slicing = slicing.or_else(|| {
            self.config
                .printers
                .iter()
                .find(|p| p.slot == slot && p.host == host)
                .and_then(|p| p.slicing.clone())
        });
        let printer = Printer {
            slot,
            name: name.trim().into(),
            host,
            user: user.trim().into(),
            slicing,
        };
        validate_printer(&printer)?;
        if self
            .config
            .printers
            .iter()
            .any(|p| p.slot != slot && p.name.eq_ignore_ascii_case(&printer.name))
        {
            return Err(Error::Invalid("Printer display names must be unique"));
        }
        let mut updated = self.config.printers.clone();
        if let Some(existing) = updated.iter_mut().find(|p| p.slot == slot) {
            *existing = printer.clone();
        } else {
            updated.push(printer.clone());
        }
        updated.sort_by_key(|p| p.slot);
        self.save(Config { printers: updated })?;
        Ok(printer)
    }
    pub fn remove(&mut self, slot: u8) -> Result<()> {
        let printers = self
            .config
            .printers
            .iter()
            .filter(|p| p.slot != slot)
            .cloned()
            .collect();
        self.save(Config { printers })
    }
    fn save(&mut self, config: Config) -> Result<()> {
        fs::create_dir_all(&self.root)
            .map_err(|_| Error::Io("Cannot create plugin data directory"))?;
        let mut nonce = [0_u8; 8];
        getrandom::fill(&mut nonce).map_err(|_| Error::Io("OS randomness unavailable"))?;
        let temp = self
            .root
            .join(format!("printers-{:016x}.tmp", u64::from_le_bytes(nonce)));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temp)
            .map_err(|_| Error::Io("Cannot write printer metadata"))?;
        let bytes = serde_json::to_vec_pretty(&config).map_err(|_| Error::Config)?;
        file.write_all(&bytes)
            .and_then(|()| file.sync_all())
            .map_err(|_| Error::Io("Cannot write printer metadata"))?;
        fs::rename(&temp, self.root.join("printers.json"))
            .map_err(|_| Error::Io("Cannot publish printer metadata"))?;
        self.config = config;
        Ok(())
    }
}

pub fn normalize_host(host: &str) -> Result<String> {
    let input = if host.contains("://") {
        host.trim().to_owned()
    } else {
        format!("http://{}", host.trim())
    };
    let url = Url::parse(&input)
        .map_err(|_| Error::Invalid("Host must be an HTTP(S) printer address"))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        return Err(Error::Invalid(
            "Use only a printer host and optional port, without credentials or URL paths",
        ));
    }
    Ok(url.to_string().trim_end_matches('/').into())
}
fn validate_printer(printer: &Printer) -> Result<()> {
    if let Some(slicing) = &printer.slicing {
        slicing.validate()?;
    }
    if (1..=SLOTS as u8).any(|slot| {
        slot != printer.slot && printer.name.eq_ignore_ascii_case(&format!("printer{slot}"))
    }) {
        return Err(Error::Invalid(
            "Display name matches another printer id; choose a different name",
        ));
    }
    if !(1..=SLOTS as u8).contains(&printer.slot)
        || printer.name.is_empty()
        || printer.name.chars().count() > 80
        || printer.name.chars().any(char::is_control)
        || printer.user.is_empty()
        || printer.user.len() > 128
        || printer.user.contains(':')
        || printer.user.chars().any(char::is_control)
    {
        return Err(Error::Invalid(
            "Use a printer slot1–8, name1–80 characters and a valid Digest username",
        ));
    }
    normalize_host(&printer.host)?;
    Ok(())
}

pub fn data_directory() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("MINERVA_PLUGIN_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    #[cfg(target_os = "macos")]
    let base = PathBuf::from(std::env::var_os("HOME").ok_or(Error::Io("HOME is unavailable"))?)
        .join("Library/Application Support");
    #[cfg(windows)]
    let base =
        PathBuf::from(std::env::var_os("APPDATA").ok_or(Error::Io("APPDATA is unavailable"))?);
    #[cfg(not(any(target_os = "macos", windows)))]
    let base = if let Some(path) = std::env::var_os("XDG_DATA_HOME") {
        PathBuf::from(path)
    } else {
        PathBuf::from(std::env::var_os("HOME").ok_or(Error::Io("HOME is unavailable"))?)
            .join(".local/share")
    };
    Ok(base.join("Minerva/plugins/prusalink"))
}
