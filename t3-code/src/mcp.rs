//! Bounded loopback HTTP MCP. No redirects, environment proxy, credentials in
//! diagnostics, automatic auth refresh or retry under a new session.

use crate::fault::{Fault, Result};
use crate::storage::random_id;
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Mutex,
};
use std::time::Duration;

pub fn loopback_url(value: &str) -> Result<()> {
    let uri: ureq::http::Uri = value
        .parse()
        .map_err(|_| Fault::held("invalid_endpoint", "Expected a loopback HTTP MCP URL."))?;
    if uri.scheme_str() != Some("http")
        || !matches!(uri.host(), Some("127.0.0.1" | "[::1]"))
        || uri.port_u16().is_none()
        || uri.query().is_some()
        || uri.authority().is_some_and(|a| a.as_str().contains('@'))
    {
        return Err(Fault::held("invalid_endpoint", "Use explicit loopback http://127.0.0.1:PORT or http://[::1]:PORT, without credentials/query. No remote server or proxy is adopted."));
    }
    Ok(())
}

pub struct Client {
    agent: ureq::Agent,
    endpoint: String,
    bearer: String,
    session: Mutex<Option<String>>,
    protocol: Mutex<String>,
    next: AtomicU64,
    pub connection: String,
}

impl Client {
    pub fn connect(endpoint: &str, bearer: String) -> Result<Self> {
        loopback_url(endpoint)?;
        if bearer.trim().is_empty() || bearer.len() > 16384 || bearer.contains(['\r', '\n']) {
            return Err(Fault::held(
                "invalid_credential",
                "Private MCP bearer is empty or malformed.",
            ));
        }
        let agent = ureq::Agent::config_builder()
            .proxy(None)
            .max_redirects(0)
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(8)))
            .build()
            .into();
        let client = Self {
            agent,
            endpoint: endpoint.into(),
            bearer,
            session: Mutex::new(None),
            protocol: Mutex::new("2025-03-26".into()),
            next: AtomicU64::new(1),
            connection: random_id()?,
        };
        let initialized = client.rpc(
            "initialize",
            json!({"protocolVersion":"2025-03-26", "capabilities":{},
            "clientInfo":{"name":"minerva-t3-code","version":env!("CARGO_PKG_VERSION")}}),
        )?;
        let version = initialized["protocolVersion"].as_str().ok_or_else(|| {
            Fault::new(
                "contract_mismatch",
                "MCP initialize returned no protocol version.",
            )
        })?;
        if !matches!(version, "2025-03-26" | "2025-06-18" | "2025-11-25") {
            return Err(Fault::held(
                "contract_mismatch",
                "T3 negotiated an unsupported MCP protocol.",
            ));
        }
        *client
            .protocol
            .lock()
            .map_err(|_| Fault::new("lock_failed", "MCP protocol lock failed."))? = version.into();
        client.post(
            json!({"jsonrpc":"2.0", "method":"notifications/initialized"}),
            None,
        )?;
        Ok(client)
    }

    fn post(&self, payload: Value, id: Option<u64>) -> Result<Value> {
        let session = self
            .session
            .lock()
            .map_err(|_| Fault::new("lock_failed", "MCP session lock failed."))?
            .clone();
        let protocol = self
            .protocol
            .lock()
            .map_err(|_| Fault::new("lock_failed", "MCP protocol lock failed."))?
            .clone();
        let mut request = self
            .agent
            .post(&self.endpoint)
            .header("Authorization", format!("Bearer {}", self.bearer))
            .header("Accept", "application/json, text/event-stream")
            .header("MCP-Protocol-Version", protocol);
        if let Some(session) = &session {
            request = request.header("Mcp-Session-Id", session);
        }
        let mut response = request.send_json(&payload).map_err(|_| Fault::new("outcome_unknown", "T3 MCP transport failed. A mutation may have been accepted; its receipt is retained."))?;
        let status = response.status().as_u16();
        if matches!(status, 401 | 403) {
            return Err(Fault::refused("auth_required", "T3 MCP authentication expired or was refused. Explicit reissue changes the namespace; unknown sends must be reconciled, never replayed blindly."));
        }
        if !(200..300).contains(&status) {
            return Err(Fault::new("outcome_unknown", format!("T3 MCP HTTP {status}. Mutation outcome is unconfirmed; no automatic new-session resend.")));
        }
        if let Some(header) = response.headers().get("Mcp-Session-Id") {
            let new = header
                .to_str()
                .map_err(|_| Fault::new("contract_mismatch", "Invalid MCP session header."))?;
            let mut current = self
                .session
                .lock()
                .map_err(|_| Fault::new("lock_failed", "MCP session lock failed."))?;
            if current.as_deref().is_some_and(|old| old != new) {
                return Err(Fault::new("outcome_unknown", "T3 changed the MCP session during a request. The accepted outcome must be reconciled."));
            }
            *current = Some(new.into());
        }
        let body = response
            .body_mut()
            .with_config()
            .limit(8 * 1024 * 1024)
            .read_to_string()
            .map_err(|error| match error {
                ureq::Error::BodyExceedsLimit(_) => Fault::new("response_too_large", "T3 MCP response exceeds8MiB. No partial result is used; retain any mutation receipt."),
                _ => Fault::new("outcome_unknown", "Cannot read the T3 MCP response; retain any mutation receipt."),
            })?;
        let Some(id) = id else {
            return Ok(Value::Null);
        };
        let mut messages = Vec::new();
        if body.trim_start().starts_with('{') {
            messages.push(serde_json::from_str::<Value>(&body)?);
        } else {
            let normalized = body.replace("\r\n", "\n");
            for event in normalized.split("\n\n") {
                let data = event
                    .lines()
                    .filter_map(|line| line.strip_prefix("data:"))
                    .map(str::trim_start)
                    .collect::<Vec<_>>()
                    .join("\n");
                if !data.is_empty() {
                    messages.push(serde_json::from_str::<Value>(&data)?);
                }
            }
        }
        let reply = messages
            .into_iter()
            .find(|v| v["id"].as_u64() == Some(id))
            .ok_or_else(|| {
                Fault::new(
                    "outcome_unknown",
                    "T3 MCP response omitted the matching request ID.",
                )
            })?;
        if reply.get("error").is_some() {
            return Err(
                if matches!(reply["error"]["code"].as_i64(), Some(-32601 | -32602)) {
                    Fault::refused(
                        "rpc_refused",
                        "T3 rejected the MCP method/arguments before dispatch.",
                    )
                } else {
                    Fault::new(
                        "outcome_unknown",
                        "T3 returned an internal RPC error; dispatch acceptance is unconfirmed.",
                    )
                },
            );
        }
        reply
            .get("result")
            .cloned()
            .ok_or_else(|| Fault::new("outcome_unknown", "T3 MCP omitted its result."))
    }

    pub fn rpc(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.post(
            json!({"jsonrpc":"2.0", "id":id, "method":method, "params":params}),
            Some(id),
        )
    }

    pub fn tool(&self, name: &str, arguments: Value) -> Result<Value> {
        let envelope = self.rpc("tools/call", json!({"name":name,"arguments":arguments}))?;
        let result = if let Some(value) = envelope.get("structuredContent") {
            value.clone()
        } else {
            let text = envelope["content"]
                .as_array()
                .into_iter()
                .flatten()
                .find_map(|c| {
                    if c["type"] == "text" {
                        c["text"].as_str()
                    } else {
                        None
                    }
                })
                .ok_or_else(|| {
                    Fault::new(
                        "contract_mismatch",
                        "T3 tool returned no structured result.",
                    )
                })?;
            serde_json::from_str(text)?
        };
        if envelope["isError"] == true
            || result.get("code").is_some() && result.get("message").is_some()
        {
            let code = result["code"].as_str().unwrap_or("tool_refused");
            let label = if matches!(code, "thread_not_found" | "not_found") {
                "thread_lost"
            } else {
                "tool_refused"
            };
            let text = if label == "thread_lost" {
                "The bound T3 thread was lost. Start a new Minerva chat for a fresh thread; retained history will not be reconstructed.".to_owned()
            } else {
                format!("T3 tool {name} refused ({code}). Check the bound thread in T3; no replacement or permission broadening is automatic.")
            };
            // These public error codes describe checks before dispatch. A
            // generic orchestration_error can follow a committed mutation.
            return Err(
                if matches!(
                    code,
                    "capability_denied"
                        | "parent_not_active"
                        | "provider_unavailable"
                        | "model_unavailable"
                        | "runtime_mode_escalation_denied"
                        | "interaction_mode_escalation_denied"
                        | "thread_not_found"
                        | "run_not_found"
                        | "thread_not_sendable"
                        | "thread_not_interruptible"
                        | "invalid_request"
                        | "thread_credential_required"
                        | "target_required"
                ) {
                    Fault::refused(label, text)
                } else {
                    Fault::new(label, text)
                },
            );
        }
        Ok(result)
    }
}
