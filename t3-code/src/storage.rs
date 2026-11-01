//! Plugin-owned receipts outlive disposable T3 state. One plugin process owns
//! the directory; per-chat locks in Engine serialize generation, not cancel.

use crate::fault::{Fault, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Operation {
    pub token: String,
    pub input: String,
    pub request_id: String,
    pub namespace: String,
    pub connection: String,
    pub tool: String,
    pub arguments: Value,
    pub run_id: Option<String>,
    pub reply: Option<Value>,
    pub settled: bool,
    pub attempted: bool,
    pub accepted: bool,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Question {
    pub thread_id: String,
    pub run_id: String,
    pub request_id: String,
    pub questions: Vec<Value>,
    pub index: usize,
    pub answers: BTreeMap<String, Value>,
    pub options: BTreeMap<String, String>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Chat {
    pub schema: u32,
    pub chat_id: String,
    pub workspace: String,
    pub base_dir: String,
    pub epoch: String,
    pub thread_id: String,
    pub mode: String,
    pub model: Value,
    pub operations: Vec<Operation>,
    pub question: Option<Question>,
    pub lost: bool,
}

pub fn random_id() -> Result<String> {
    let mut bytes = [0u8; 24];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

pub fn private_dir(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)?;
        check_private(path, true)?;
    }
    #[cfg(not(unix))]
    return Err(Fault::held(
        "unsupported_platform",
        "Private Unix state is required.",
    ));
    Ok(())
}

fn check_private(path: &Path, directory: bool) -> Result<()> {
    let info = fs::symlink_metadata(path)?;
    if info.file_type().is_symlink()
        || directory != info.is_dir()
        || (!directory && !info.is_file())
    {
        return Err(Fault::held(
            "private_state",
            "Private state must be a regular file or directory, without a symlink.",
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        // SAFETY: geteuid takes no pointers and only reads this process's uid.
        if info.uid() != unsafe { libc::geteuid() } || info.permissions().mode() & 0o077 != 0 {
            return Err(Fault::held("private_state", "Plugin state must be owned by this user with directories0700/files0600. Correct the private path before retrying."));
        }
    }
    Ok(())
}

pub fn read_private(path: &Path) -> Result<String> {
    check_private(path, false)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let mut text = String::new();
    options
        .open(path)?
        .take(16 * 1024 * 1024 + 1)
        .read_to_string(&mut text)?;
    if text.len() > 16 * 1024 * 1024 {
        return Err(Fault::held(
            "private_state",
            "Private state exceeds the 16MiB read bound.",
        ));
    }
    Ok(text)
}

pub struct Store {
    root: PathBuf,
    _lock: File,
}

impl Store {
    pub fn open(root: &Path) -> Result<Self> {
        private_dir(root)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let lock = options.open(root.join("writer.lock"))?;
        check_private(&root.join("writer.lock"), false)?;
        lock.try_lock().map_err(|_| {
            Fault::held(
                "already_running",
                "Another T3 Code plugin process owns this private directory.",
            )
        })?;
        private_dir(&root.join("chats"))?;
        Ok(Self {
            root: root.to_owned(),
            _lock: lock,
        })
    }

    fn path(&self, chat: &str) -> Result<PathBuf> {
        if chat.is_empty() || chat.len() > 100 {
            return Err(Fault::held(
                "invalid_chat",
                "chat_id must contain1–100 UTF-8 bytes.",
            ));
        }
        let encoded: String = chat.as_bytes().iter().map(|b| format!("{b:02x}")).collect();
        Ok(self.root.join("chats").join(format!("{encoded}.json")))
    }

    pub fn load(&self, id: &str) -> Result<Option<Chat>> {
        let path = self.path(id)?;
        match fs::symlink_metadata(&path) {
            Ok(_) => (),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        }
        let chat: Chat = serde_json::from_str(&read_private(&path)?)?;
        if chat.schema != 1 || chat.chat_id != id {
            return Err(Fault::held(
                "invalid_state",
                "Stored chat identity/schema does not match. No reconstruction is attempted.",
            ));
        }
        Ok(Some(chat))
    }

    pub fn save(&self, chat: &Chat) -> Result<()> {
        let path = self.path(&chat.chat_id)?;
        self.write(&path, &serde_json::to_vec(chat)?)
    }

    pub fn cancellations(&self, id: &str) -> Result<std::collections::BTreeSet<String>> {
        let path = self.path(id)?.with_extension("cancellations.json");
        if !path.try_exists()? {
            return Ok(Default::default());
        }
        Ok(serde_json::from_str(&read_private(&path)?)?)
    }

    pub fn cancel(&self, id: &str, tokens: &std::collections::BTreeSet<String>) -> Result<()> {
        self.write(
            &self.path(id)?.with_extension("cancellations.json"),
            &serde_json::to_vec(tokens)?,
        )
    }

    fn write(&self, path: &Path, bytes: &[u8]) -> Result<()> {
        if bytes.len() > 16 * 1024 * 1024 {
            return Err(Fault::new("private_state_full","This chat's retained receipts exceed16MiB. The existing file is preserved; reconcile any submitted operation before starting a fresh chat."));
        }
        let temporary = path.with_extension(format!("{}.tmp", random_id()?));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        File::open(self.root.join("chats"))?.sync_all()?;
        Ok(())
    }
}
