//! Phase B alone writes/retires owned-runtime.json. This module only consumes
//! that receipt; it never starts/adopts a server or issues a credential.

use crate::{
    contract::Contract,
    fault::{Fault, Result},
    mcp::{self, Client},
    probe::Settings,
    storage::read_private,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    pub schema: u32,
    pub endpoint: String,
    pub server_epoch: String,
    pub base_identity: String,
    pub session_id: String,
    pub expires_at_unix: u64,
    pub t3_tag: String,
    pub base_dir: String,
    pub codex_home: String,
    pub codex_binary: String,
    pub resolved_codex_binary: String,
    pub codex_launch_args: String,
    pub disabled_mcp_entries: Vec<String>,
    pub ownership: String,
    pub workspace: String,
    pub token_file: String,
    pub runtime_mode_ceiling: String,
}

pub fn now() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .map_err(|_| Fault::held("clock_invalid", "System clock precedes the Unix epoch."))
}

/// Pass this string as the owned T3 process's T3CODE_CODEX_LAUNCH_ARGS, and
/// CODEX_HOME separately. T3 tokenizes it; no shell or Codex config-file edit.
pub fn codex_launch_args(settings: &Settings, disabled: &[String]) -> Result<String> {
    let endpoint = settings
        .get("minerva_mcp_endpoint")
        .map_err(|e| Fault::held("settings", e))?;
    mcp::loopback_url(&endpoint)?;
    let entries = [
        ("url", json!(endpoint)),
        ("enabled", json!(true)),
        ("enabled_tools", json!(["minerva_list_chats"])),
        ("disabled_tools", json!([])),
        ("required", json!(true)),
    ];
    let mut arguments = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for name in disabled {
        if name.is_empty() || name == "minerva_t3_crawl" || !seen.insert(name) {
            return Err(Fault::held(
                "mcp_identity",
                "Disabled MCP entry names are invalid or duplicated.",
            ));
        }
        let argument = disable_entry(name)?;
        arguments.push(format!("--config {}", serde_json::to_string(&argument)?));
    }
    arguments.extend(
        entries
            .into_iter()
            .map(|(key, value)| {
                let argument = format!("mcp_servers.minerva_t3_crawl.{key}={value}");
                Ok(format!("--config {}", serde_json::to_string(&argument)?))
            })
            .collect::<Result<Vec<_>>>()?,
    );
    Ok(arguments.join(" "))
}

pub fn disable_entry(name: &str) -> Result<String> {
    if name.is_empty()
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err(Fault::held("mcp_override_name","A Minerva MCP entry has an unusual name. Rename it using letters, digits, underscores or hyphens, then restart; quoted-key override parsing is unproven and no owner config was edited."));
    }
    Ok(format!("mcp_servers.{name}.enabled=false"))
}

pub struct Runtime {
    pub receipt: Receipt,
    pub t3_binary: String,
    pub client: Arc<Client>,
    bearer: String,
    pub capabilities: Value,
}

#[derive(Default)]
pub struct RuntimeCache(Mutex<Option<Arc<Runtime>>>);

impl RuntimeCache {
    pub fn get_ready(&self, settings: &Settings, contract: &Contract) -> Result<Arc<Runtime>> {
        self.lookup(settings, contract, true)
    }

    pub fn get(&self, settings: &Settings, contract: &Contract) -> Result<Arc<Runtime>> {
        self.lookup(settings, contract, false)
    }

    fn lookup(
        &self,
        settings: &Settings,
        contract: &Contract,
        require_models: bool,
    ) -> Result<Arc<Runtime>> {
        let path = settings.private.join("owned-runtime.json");
        if !path.try_exists()? {
            return Err(Fault::held("runtime_not_started", "No owned T3 runtime receipt exists. T1 Phase B is pending the owner's install decision; no prompt was sent."));
        }
        let receipt: Receipt = serde_json::from_str(&read_private(&path)?)?;
        let setting = |key| settings.get(key).map_err(|e| Fault::held("settings", e));
        if receipt.schema != 2
            || receipt.t3_tag != contract.t3_tag
            || receipt.server_epoch.is_empty()
            || receipt.base_identity.is_empty()
            || receipt.session_id.is_empty()
            || receipt.base_dir != setting("t3_base_dir")?
            || receipt.codex_home != setting("codex_home")?
            || receipt.codex_binary != setting("codex_binary")?
            || !std::path::Path::new(&receipt.resolved_codex_binary).is_absolute()
            || receipt.token_file != setting("t3_token_file")?
            || receipt.codex_launch_args
                != codex_launch_args(settings, &receipt.disabled_mcp_entries)?
            || settings
                .workspace
                .canonicalize()
                .ok()
                .as_ref()
                .and_then(|p| p.to_str())
                != Some(receipt.workspace.as_str())
            || !matches!(
                receipt.ownership.as_str(),
                "systemd-user-scope" | "process-group-and-tracked-pids-best-effort"
            )
            || receipt.runtime_mode_ceiling != "approval-required"
        {
            return Err(Fault::held("runtime_identity_changed", "Owned runtime receipt does not match the pinned installation/settings/native MCP identity. Phase B must reconcile it; no endpoint is adopted automatically."));
        }
        if receipt.expires_at_unix <= now()?.saturating_add(10) {
            return Err(Fault::held("auth_required", "Owned T3 credential is expired or near expiry. Explicit reissue must reconcile accepted/unknown operations before any new send."));
        }
        mcp::loopback_url(&receipt.endpoint)?;
        let bearer = read_private(std::path::Path::new(&setting("t3_token_file")?))?
            .trim()
            .to_owned();
        let mut cached = self
            .0
            .lock()
            .map_err(|_| Fault::new("lock_failed", "Runtime cache lock failed."))?;
        let previous = cached
            .as_ref()
            .filter(|runtime| runtime.receipt == receipt && runtime.bearer == bearer);
        if let Some(runtime) = previous {
            if !require_models || crate::turn::ready_codex_provider(runtime).is_ok() {
                return Ok(Arc::clone(runtime));
            }
        }
        // Rediscovery retains the same MCP session/connection, so an uncertain
        // existing send can still use its one safe same-session retry.
        let (client, t3_binary) = if let Some(runtime) = previous {
            (Arc::clone(&runtime.client), runtime.t3_binary.clone())
        } else {
            let client = Arc::new(Client::connect(&receipt.endpoint, bearer.clone())?);
            contract
                .check_catalog(&client.rpc("tools/list", json!({}))?)
                .map_err(|e| Fault::held("contract_mismatch", e))?;
            let binary = crate::probe::resolve_executable(&setting("t3_binary")?)
                .map_err(|e| Fault::held("prerequisites", e))?
                .to_string_lossy()
                .into_owned();
            (client, binary)
        };
        let capabilities = client.tool("orchestrator_capabilities", json!({}))?;
        let runtime = Arc::new(Runtime {
            receipt,
            t3_binary,
            client,
            bearer,
            capabilities,
        });
        // Retain transport even while models are pending. Model lookups must
        // rediscover before reusing an unusable capabilities snapshot.
        *cached = Some(Arc::clone(&runtime));
        if require_models {
            crate::turn::ready_codex_provider(&runtime)?;
        }
        Ok(runtime)
    }
}

pub fn permission(mode: &str) -> Value {
    match mode {
        "approval-required" => {
            json!({"runtime_mode":mode,"sandbox":"read-only","approval_policy":"untrusted"})
        }
        "auto" => {
            json!({"runtime_mode":mode,"sandbox":"workspace-write","approval_policy":"on-request","approvals_reviewer":"auto_review"})
        }
        "auto-accept-edits" => {
            json!({"runtime_mode":mode,"sandbox":"workspace-write","approval_policy":"on-request","approvals_reviewer":"user"})
        }
        "full-access" => {
            json!({"runtime_mode":mode,"sandbox":"danger-full-access","approval_policy":"never"})
        }
        _ => json!({"runtime_mode":mode,"sandbox":"unknown","approval_policy":"unknown"}),
    }
}
