//! Public Codex MCP discovery, without creating a thread or model turn. Only
//! entry names survive discovery; endpoints, headers and tool metadata do not.

use crate::{
    fault::{Fault, Result},
    owned_process::{Launch, OwnedProcess},
    probe::{self, Settings},
    storage::random_id,
};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Write,
    process::Stdio,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

fn problem() -> Fault {
    Fault::held("mcp_inventory", "Cannot classify every enabled Codex MCP entry through public mcpServerStatus/list. Repair its discovery/authentication and restart the plugin; no non-Minerva entry is disabled as a fallback.")
}

fn origin(value: &str) -> Option<(String, u16)> {
    let uri: ureq::http::Uri = value.parse().ok()?;
    let host = uri.host()?;
    let host = if matches!(host, "localhost" | "127.0.0.1" | "[::1]") {
        "loopback"
    } else {
        host
    };
    Some((
        host.to_lowercase(),
        uri.port_u16()
            .unwrap_or(if uri.scheme_str() == Some("https") {
                443
            } else {
                80
            }),
    ))
}

struct Discovery<'a> {
    process: OwnedProcess,
    input: std::process::ChildStdin,
    output: std::process::ChildStdout,
    buffer: Vec<u8>,
    next: u32,
    deadline: Instant,
    cancel: &'a AtomicBool,
    tracked_at: Instant,
}

impl Discovery<'_> {
    fn write(&mut self, value: &Value) -> Result<()> {
        serde_json::to_writer(&mut self.input, value)?;
        self.input.write_all(b"\n")?;
        self.input.flush()?;
        Ok(())
    }

    fn rpc(&mut self, method: &str, params: Value) -> Result<Value> {
        self.next += 1;
        let id = self.next;
        self.write(&json!({"id":id,"method":method,"params":params}))?;
        loop {
            if self.cancel.load(Ordering::Acquire) {
                return Err(Fault::held(
                    "runtime_stopping",
                    "Plugin unload interrupted MCP discovery.",
                ));
            }
            probe::drain(&mut self.output, &mut self.buffer, 8 * 1024 * 1024)
                .map_err(|_| problem())?;
            while let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = self.buffer.drain(..=end).collect();
                let response: Value = serde_json::from_slice(&line).map_err(|_| problem())?;
                if response.get("method").is_some() {
                    // Discovery must never authorize an elicitation, command,
                    // login, file write or model action on a server's behalf.
                    if response.get("id").is_some() {
                        self.write(&json!({"id":response["id"],"error":{"code":-32601,"message":"Inventory only"}}))?;
                    }
                } else if response["id"] == id {
                    return response.get("result").cloned().ok_or_else(problem);
                }
            }
            if Instant::now() >= self.deadline || self.process.exited()? {
                return Err(problem());
            }
            if self.tracked_at.elapsed() >= Duration::from_secs(1) {
                self.process.track()?;
                self.tracked_at = Instant::now();
            }
            std::thread::sleep(Duration::from_millis(30));
        }
    }
}

pub fn disabled_entries(
    settings: &Settings,
    binary: &str,
    environment: &[(String, Option<String>)],
    cancel: &AtomicBool,
) -> Result<Vec<String>> {
    let endpoint = settings
        .get("minerva_mcp_endpoint")
        .map_err(|_| problem())?;
    let target = origin(&endpoint).ok_or_else(problem)?;
    let configured: Value = serde_json::from_str(
        &Launch {
            program: binary,
            args: &["mcp".into(), "list".into(), "--json".into()],
            epoch: &format!("inventory-list-{}", random_id()?),
            environment,
            directory: &settings.workspace,
            scope: false,
        }
        .capture(8 * 1024 * 1024, Duration::from_secs(15), Some(cancel))
        .map_err(|_| problem())?,
    )
    .map_err(|_| problem())?;
    let mut enabled = BTreeMap::new();
    let mut disabled = BTreeSet::new();
    for entry in configured.as_array().ok_or_else(problem)? {
        let name = entry["name"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or_else(problem)?;
        if name == "minerva_t3_crawl" {
            return Err(Fault::held("mcp_name_conflict","The existing Codex config already defines minerva_t3_crawl. Choose another name for that owner entry before starting; its transport/auth fields will not be overwritten."));
        }
        if entry["enabled"] == false {
            continue;
        }
        let is_minerva = entry["transport"]["url"]
            .as_str()
            .and_then(origin)
            .is_some_and(|o| o == target);
        enabled.insert(name.to_owned(), is_minerva);
        if is_minerva {
            disabled.insert(name.to_owned());
        }
    }
    // Disable known Minerva endpoints before starting discovery; discover the
    // remaining entries with the same real home, cwd and provider routing.
    let mut args = Vec::new();
    for name in &disabled {
        args.extend([
            "--config".into(),
            format!("mcp_servers.{}.enabled=false", serde_json::to_string(name)?),
        ]);
    }
    args.extend(["app-server".into(), "--stdio".into()]);
    let mut process = Launch {
        program: binary,
        args: &args,
        epoch: &format!("inventory-{}", random_id()?),
        environment,
        directory: &settings.workspace,
        scope: true,
    }
    .spawn((Stdio::piped(), Stdio::piped(), Stdio::null()))?;
    let input = process.child.stdin.take().ok_or_else(problem)?;
    let output = process.child.stdout.take().ok_or_else(problem)?;
    probe::nonblocking(&output).map_err(|_| problem())?;
    let mut discovery = Discovery {
        process,
        input,
        output,
        buffer: Vec::new(),
        next: 0,
        deadline: Instant::now() + Duration::from_secs(60),
        cancel,
        tracked_at: Instant::now(),
    };
    discovery.rpc("initialize",json!({"clientInfo":{"name":"minerva-t3-inventory","version":env!("CARGO_PKG_VERSION")},"capabilities":{}}))?;
    discovery.write(&json!({"method":"initialized","params":{}}))?;
    let mut cursor = Value::Null;
    let mut seen = BTreeSet::new();
    for _ in 0..100 {
        let page = discovery.rpc(
            "mcpServerStatus/list",
            json!({"cursor":cursor,"limit":100,"detail":"toolsAndAuthOnly"}),
        )?;
        for server in page["data"].as_array().ok_or_else(problem)? {
            let name = server["name"].as_str().ok_or_else(problem)?;
            if disabled.contains(name) {
                continue;
            }
            if !server["toolsError"].is_null()
                || matches!(
                    server["runtimeStatus"].as_str(),
                    Some(
                        "authenticationRequired"
                            | "failed"
                            | "cancelled"
                            | "starting"
                            | "notStarted"
                    )
                )
            {
                return Err(problem());
            }
            let tools = server["tools"].as_object().ok_or_else(problem)?;
            let minerva = server["httpOrigin"]
                .as_str()
                .and_then(origin)
                .is_some_and(|o| o == target)
                || tools.iter().any(|(name, tool)| {
                    [Some(name.as_str()), tool["name"].as_str()]
                        .into_iter()
                        .flatten()
                        .any(|s| {
                            s.rsplit("__")
                                .next()
                                .is_some_and(|s| s.starts_with("minerva_"))
                        })
                });
            if minerva {
                if !server["pluginId"].is_null() {
                    return Err(Fault::held("mcp_plugin_override","A plugin-provided MCP entry exposes Minerva tools. Its per-entry disable override is unproven; disable that entry in Codex and restart this plugin. No non-Minerva entry was changed."));
                }
                disabled.insert(name.to_owned());
            }
            seen.insert(name.to_owned());
        }
        let next = page.get("nextCursor").ok_or_else(problem)?;
        if next.is_null() {
            if enabled
                .iter()
                .any(|(name, known)| !known && !seen.contains(name))
            {
                return Err(problem());
            }
            discovery.process.stop()?;
            return Ok(disabled.into_iter().collect());
        }
        if next == &cursor || !next.is_string() {
            return Err(problem());
        }
        cursor = next.clone();
    }
    Err(problem())
}
