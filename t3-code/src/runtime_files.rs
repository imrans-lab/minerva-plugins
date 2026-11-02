//! Private launch configuration and public CLI authentication. No private T3
//! imports, database access, real-home edits or credential copying.

use crate::{
    contract::Contract,
    fault::{string, Fault, Result},
    owned_process::{retire_scope, Launch},
    probe::{self, Settings},
    runtime::{self, Receipt},
    storage::{private_dir, read_private, write_private},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde_json::{json, Value};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
};

pub fn environment(settings: &Settings) -> Result<Vec<(String, Option<String>)>> {
    let node = probe::resolve_executable(&setting(settings, "node_binary")?)
        .map_err(|e| Fault::held("prerequisites", e))?;
    if node.file_name() != Some(std::ffi::OsStr::new("node")) {
        return Err(Fault::held("prerequisites","Select the existing Node executable named node, so child shebangs resolve to the checked runtime."));
    }
    let directory = node
        .parent()
        .ok_or_else(|| Fault::held("prerequisites", "Node executable has no parent directory."))?;
    let mut paths = vec![directory.to_owned()];
    paths.extend(
        std::env::var_os("PATH")
            .into_iter()
            .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>()),
    );
    let path = std::env::join_paths(paths)
        .map_err(|_| Fault::held("prerequisites", "Cannot construct the selected Node PATH."))?;
    let mut values: Vec<_> = std::env::vars_os()
        .filter_map(|(name, _)| name.to_str().map(str::to_owned))
        .filter(|name| {
            name.starts_with("T3CODE_")
                || name.starts_with("OTEL_")
                || matches!(
                    name.as_str(),
                    "T3_SERVICE_LAUNCHER_CONTEXT" | "VITE_DEV_SERVER_URL" | "NODE_CHANNEL_FD"
                )
        })
        .map(|name| (name, None))
        .collect();
    values.extend([
        ("T3CODE_TELEMETRY_ENABLED".into(), Some("false".into())),
        ("T3CODE_LAN".into(), Some("false".into())),
        (
            "CODEX_HOME".into(),
            Some(
                PathBuf::from(setting(settings, "codex_home")?)
                    .canonicalize()?
                    .to_string_lossy()
                    .into_owned(),
            ),
        ),
        (
            "PATH".into(),
            Some(
                path.into_string().map_err(|_| {
                    Fault::held("prerequisites", "Selected Node PATH is not UTF-8.")
                })?,
            ),
        ),
        ("LC_ALL".into(), Some("C".into())),
    ]);
    Ok(values)
}

pub fn setting(settings: &Settings, key: &str) -> Result<String> {
    settings.get(key).map_err(|e| Fault::held("settings", e))
}

fn exclusive(path: &Path) -> Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    Ok(OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?)
}

fn scopes(value: &Value) -> Option<std::collections::BTreeSet<&str>> {
    value.as_array()?.iter().map(Value::as_str).collect()
}

pub struct Files {
    pub settings: Settings,
    pub base: PathBuf,
    pub token: PathBuf,
    pub environment: Vec<(String, Option<String>)>,
    pub executable: String,
    pub epoch: String,
    pub session: Option<String>,
    pub codex_binary: String,
    _base_lock: File,
    token_owned: bool,
    receipt_owned: bool,
}

impl Files {
    pub fn prepare(settings: Settings, executable: String, epoch: String) -> Result<Self> {
        private_dir(&settings.private)?;
        let base = PathBuf::from(setting(&settings, "t3_base_dir")?);
        let token = PathBuf::from(setting(&settings, "t3_token_file")?);
        let home = PathBuf::from(setting(&settings, "codex_home")?).canonicalize()?;
        let codex_binary = probe::resolve_executable(&setting(&settings, "codex_binary")?)
            .map_err(|e| Fault::held("prerequisites", e))?
            .to_string_lossy()
            .into_owned();
        private_dir(&base)?;
        let canonical = base.canonicalize()?;
        if canonical.starts_with(&home) || home.starts_with(&canonical) {
            return Err(Fault::held(
                "private_path",
                "T3 base must be separate from the real Codex home.",
            ));
        }
        let owner = base.join(".minerva-owner.json");
        let identity = json!({"schema":1,"plugin_private":settings.private.canonicalize()?});
        let lock = if owner.try_exists()? {
            let current: Value = serde_json::from_str(&read_private(&owner)?)?;
            if current != identity {
                return Err(Fault::held("base_not_owned","T3 base belongs to another plugin instance; select an empty private directory."));
            }
            use std::os::unix::fs::OpenOptionsExt;
            OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&owner)?
        } else {
            if fs::read_dir(&base)?.next().is_some() {
                return Err(Fault::held("base_not_owned","T3 base is nonempty and has no plugin ownership receipt. Select an empty private directory; existing T3 data will not be adopted or rewritten."));
            }
            let mut lock = exclusive(&owner)?;
            lock.write_all(&serde_json::to_vec(&identity)?)?;
            lock.sync_all()?;
            lock
        };
        lock.try_lock().map_err(|_| {
            Fault::held(
                "already_running",
                "Another plugin process owns this T3 base.",
            )
        })?;
        private_dir(&base.join("userdata"))?;
        let parent = token
            .parent()
            .ok_or_else(|| Fault::held("private_path", "Bearer path has no parent directory."))?;
        private_dir(parent)?;
        let token_parent = parent.canonicalize()?;
        let private = settings.private.canonicalize()?;
        let target = token_parent.join(
            token
                .file_name()
                .ok_or_else(|| Fault::held("private_path", "Bearer file has no name."))?,
        );
        if token_parent.starts_with(&home)
            || target.starts_with(&canonical)
            || target.starts_with(private.join("chats"))
            || target == private.join("owned-runtime.json")
            || target == private.join("writer.lock")
        {
            return Err(Fault::held(
                "private_path",
                "Bearer file must be outside the real Codex home, T3 base and plugin control/chat files.",
            ));
        }
        // Existing arbitrary files are never overwritten or deleted. This file
        // is created exclusively by this process before any issuer is invoked.
        let environment = environment(&settings)?;
        let mut files = Self {
            settings,
            base,
            token,
            environment,
            executable,
            epoch,
            session: None,
            codex_binary,
            _base_lock: lock,
            token_owned: false,
            receipt_owned: false,
        };
        files.recover()?;
        if files
            .base
            .join("userdata/server-runtime.json")
            .try_exists()?
        {
            return Err(Fault::held("stale_runtime","A prior T3 server record remains after stale-scope reconciliation. Inspect that server before restarting; no saved PID is adopted or signalled."));
        }
        exclusive(&files.token).map_err(|_|Fault::held("token_path_busy","Bearer path already exists or cannot be created privately. Reconcile the old runtime and choose a fresh token path; no existing file was overwritten."))?;
        files.token_owned = true;
        Ok(files)
    }

    fn recover(&mut self) -> Result<()> {
        let path = self.settings.private.join("owned-runtime.json");
        if !path.try_exists()? {
            return Ok(());
        }
        let old: Receipt = serde_json::from_str(&read_private(&path)?)?;
        if old.schema != 2
            || old.base_dir != setting(&self.settings, "t3_base_dir")?
            || old.server_epoch.len() != 48
            || !old.server_epoch.bytes().all(|b| b.is_ascii_hexdigit())
            || old.session_id.is_empty()
            || old.token_file != setting(&self.settings, "t3_token_file")?
        {
            return Err(Fault::held("stale_runtime","Saved runtime identity does not match this plugin's claimed base/token path; reconcile it manually. No unit or PID was signalled."));
        }
        match old.ownership.as_str() {
            "systemd-user-scope" if cfg!(target_os = "linux") => retire_scope(&old.server_epoch)?,
            "systemd-user-scope" | "process-group-and-tracked-pids-best-effort" => {}
            _ => {
                return Err(Fault::held(
                    "stale_runtime",
                    "Saved runtime ownership mechanism is unsupported; no process was signalled.",
                ))
            }
        }
        self.session = Some(old.session_id);
        self.revoke()?;
        if self.token.try_exists()? {
            read_private(&self.token)?;
            fs::remove_file(&self.token)?;
        }
        fs::remove_file(path)?;
        Ok(())
    }

    pub fn cli(&self, args: &[&str]) -> Result<String> {
        self.cli_cancellable(args, None)
    }

    pub fn cli_cancellable(&self, args: &[&str], cancel: Option<&AtomicBool>) -> Result<String> {
        let mut args: Vec<String> = args.iter().map(|v| (*v).into()).collect();
        args.extend([
            "--base-dir".into(),
            self.base.to_string_lossy().into_owned(),
        ]);
        Launch {
            program: &self.executable,
            args: &args,
            epoch: &format!("cli-{}", crate::storage::random_id()?),
            environment: &self.environment,
            directory: &self.base,
            scope: false,
        }
        .capture(
            1024 * 1024,
            std::time::Duration::from_secs(if args.iter().any(|v| v == "revoke") {
                2
            } else {
                30
            }),
            cancel,
        )
    }

    pub fn configure(&self, disabled: &[String]) -> Result<String> {
        let args = runtime::codex_launch_args(&self.settings, disabled)?;
        let path = self.base.join("userdata/settings.json");
        let mut config: Value = if path.try_exists()? {
            serde_json::from_str(&read_private(&path)?)?
        } else {
            json!({})
        };
        let object = config.as_object_mut().ok_or_else(|| {
            Fault::held("settings_shape", "Private T3 settings must be an object.")
        })?;
        for (key, value) in [
            ("enableProviderUpdateChecks", json!(false)),
            ("continueThreadsAfterServerUpdate", json!(false)),
            ("defaultRuntimeMode", json!("approval-required")),
            ("guestSharingEnabled", json!(false)),
            ("linkedEnvironmentsEnabled", json!(false)),
            ("enableAgentBrowserAccess", json!(false)),
            ("autoResumeLimitedThreads", json!(false)),
            ("snoozeLimitedThreads", json!(false)),
        ] {
            object.insert(key.into(), value);
        }
        let instances = object
            .entry("providerInstances")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .ok_or_else(|| {
                Fault::held("settings_shape", "Private T3 providers must be an object.")
            })?;
        // This is the plugin's claimed private T3 base, never owner config.
        for instance in instances.values_mut() {
            if let Some(instance) = instance.as_object_mut() {
                instance.insert("enabled".into(), json!(false));
            }
        }
        instances.insert("codex".into(),json!({"driver":"codex","enabled":true,"config":{
            "setupMode":"existing","binaryPath":self.codex_binary,
            "homePath":PathBuf::from(setting(&self.settings,"codex_home")?).canonicalize()?,"shadowHomePath":"","launchArgs":args}}));
        write_private(&path, &serde_json::to_vec_pretty(&config)?)?;
        Ok(args)
    }

    pub fn issue(
        &mut self,
        contract: &Contract,
        endpoint: &str,
        disabled: Vec<String>,
        ownership: String,
        cancel: &AtomicBool,
    ) -> Result<Receipt> {
        if let Some(old) = self.session.take() {
            // A failed revocation does not authorize reusing an old namespace.
            // Preserve the old id for controlled-unload retry on failure.
            if let Err(error) = self.cli(&["auth", "session", "revoke", &old]) {
                self.session = Some(old);
                return Err(error);
            }
        }
        let output = self.cli_cancellable(
            &[
                "auth",
                "session",
                "issue",
                "--subject",
                "mcp-client",
                "--scope",
                "orchestration:read",
                "--scope",
                "orchestration:operate",
                "--ttl",
                "1h",
                "--label",
                "minerva-t3-code",
                "--json",
            ],
            Some(cancel),
        )?;
        let issued: Value = serde_json::from_str(&output)?;
        let session = string(&issued, "sessionId")?.to_owned();
        self.session = Some(session.clone());
        let bearer = string(&issued, "token")?;
        // Pinned v0.1.6 SessionStore.ts741: base64url(JSON).signature, not JWT.
        // These are trusted CLI metadata, NOT client-side authentication. T3
        // still verifies the signature, revocation and scopes on every call.
        let payload = bearer
            .split_once('.')
            .ok_or_else(|| {
                Fault::held(
                    "issuer_shape",
                    "Public issuer returned an unsupported token shape.",
                )
            })?
            .0;
        let bytes = URL_SAFE_NO_PAD.decode(payload).map_err(|_| {
            Fault::held(
                "issuer_shape",
                "Public issuer returned invalid expiry metadata.",
            )
        })?;
        let claims: Value = serde_json::from_slice(&bytes)?;
        let expiry = claims["exp"].as_u64().ok_or_else(|| {
            Fault::held("issuer_shape", "Public issuer returned no expiry metadata.")
        })? / 1000;
        let now = runtime::now()?;
        let expected =
            std::collections::BTreeSet::from(["orchestration:read", "orchestration:operate"]);
        if claims["sid"] != session
            || claims["sub"] != "mcp-client"
            || claims["method"] != "bearer-access-token"
            || issued["subject"] != "mcp-client"
            || issued["method"] != "bearer-access-token"
            || expiry <= now.saturating_add(10)
            || expiry > now.saturating_add(3610)
            || scopes(&issued["scopes"]).as_ref() != Some(&expected)
            || scopes(&claims["scopes"]).as_ref() != Some(&expected)
        {
            return Err(Fault::held(
                "issuer_shape",
                "Public issuer identity/scopes/expiry differs from the pinned mcp-client contract.",
            ));
        }
        write_private(&self.token, bearer.as_bytes())?;
        Ok(Receipt {
            schema: 2,
            endpoint: endpoint.into(),
            server_epoch: self.epoch.clone(),
            session_id: session,
            expires_at_unix: expiry,
            t3_tag: contract.t3_tag.clone(),
            base_dir: setting(&self.settings, "t3_base_dir")?,
            codex_home: setting(&self.settings, "codex_home")?,
            codex_binary: setting(&self.settings, "codex_binary")?,
            resolved_codex_binary: self.codex_binary.clone(),
            codex_launch_args: runtime::codex_launch_args(&self.settings, &disabled)?,
            disabled_mcp_entries: disabled,
            ownership,
            workspace: self
                .settings
                .workspace
                .canonicalize()?
                .to_string_lossy()
                .into_owned(),
            runtime_mode_ceiling: "approval-required".into(),
            token_file: setting(&self.settings, "t3_token_file")?,
        })
    }

    pub fn publish(&mut self, receipt: &Receipt) -> Result<()> {
        self.receipt_owned = true;
        write_private(
            &self.settings.private.join("owned-runtime.json"),
            &serde_json::to_vec(receipt)?,
        )
    }

    pub fn retire(&mut self) -> Result<()> {
        let mut error = None;
        // Both paths were created exclusively by this runtime. T3 state, chats
        // and the real Codex home are deliberately outside this retirement.
        for (owned, path) in [
            (
                &mut self.receipt_owned,
                self.settings.private.join("owned-runtime.json"),
            ),
            (&mut self.token_owned, self.token.clone()),
        ] {
            if *owned {
                if let Err(failure) = fs::remove_file(&path) {
                    if failure.kind() != std::io::ErrorKind::NotFound {
                        error = Some(Fault::from(failure));
                        continue;
                    }
                }
                *owned = false;
            }
        }
        if let Some(error) = error {
            return Err(error);
        }
        Ok(())
    }

    pub fn revoke(&mut self) -> Result<()> {
        if let Some(session) = self.session.clone() {
            self.cli(&["auth", "session", "revoke", &session])?;
            self.session = None;
        }
        Ok(())
    }
}

impl Drop for Files {
    fn drop(&mut self) {
        if let Err(error) = self.revoke() {
            eprintln!("t3-code: {}", error.text);
        }
        if let Err(error) = self.retire() {
            eprintln!("t3-code: {}", error.text);
        }
    }
}
