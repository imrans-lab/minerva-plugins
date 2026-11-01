mod contract;
mod probe;
mod protocol;

use contract::Contract;
use protocol::Peer;
use serde_json::{json, Value};
use std::io;

const MANIFEST: &str = include_str!("../manifest.json");

fn tool_result(value: Value) -> Value {
    json!({"content": [{"type": "text", "text": value.to_string()}]})
}

fn status(peer: &Peer, contract: &Contract) -> Value {
    let result = (|| {
        let fields = peer.capability("host.settings.list", json!({}))?;
        let project = peer.capability("host.project.current", json!({}))?;
        let settings = probe::Settings::from_host(&fields, &project)?;
        probe::inspect(&settings, contract)
    })();
    result.unwrap_or_else(|error: String| json!({
        "state": "not-started", "ready": false, "phase": "A",
        "thread_id": "", "run_id": "", "provider": "codex", "t3_tag": contract.t3_tag,
        "endpoint": "", "base_dir": "", "codex_home": "", "errors": [error],
        "compatibility": contract.compatibility(json!({})),
        "runtime_message": "No T3 server or agent has been started. Open T3 Code preferences to correct prerequisites."
    }))
}

fn register(peer: &Peer) -> Result<(), String> {
    peer.capability(
        "host.chat_providers.register",
        json!({
            "entry_id": "t3-code", "display_name": "T3 Code (Codex)",
            "generate_tool": "minerva_t3_code_generate", "cancel_tool": "minerva_t3_code_cancel",
            "history_mode": "newest_only", "timeout_sec": 600,
            "metadata": {"resumable": true, "interrupt_in_place": true}
        }),
    )
    .map(|_| ())
}

fn serve(contract: &Contract) -> Result<(), String> {
    let manifest: Value = serde_json::from_str(MANIFEST).map_err(|e| e.to_string())?;
    let (peer, requests) = Peer::start();
    let mut registration_error = None;
    for request in requests {
        let method = request["method"].as_str().unwrap_or("");
        if method == "notifications/initialized" {
            registration_error = register(&peer).err();
            if let Some(error) = &registration_error {
                eprintln!("t3-code: {error}");
            }
            continue;
        }
        if request.get("id").is_none() {
            continue;
        }
        let id = &request["id"];
        let result = match method {
            "initialize" => json!({
                "protocolVersion": "2024-11-05", "serverName": "t3-code",
                "serverVersion": env!("CARGO_PKG_VERSION"),
                "serverInfo": {"name": "t3-code", "version": env!("CARGO_PKG_VERSION")},
                "capabilities": {"tools": {}}
            }),
            "ping" => json!({}),
            "tools/list" => {
                let tools = manifest["tools"]
                    .as_array()
                    .ok_or("Embedded manifest has no tools")?;
                let listed: Vec<Value> = tools
                    .iter()
                    .map(|tool| {
                        json!({
                            "name": tool["name"], "description": tool["description"],
                            "inputSchema": tool["input_schema"]
                        })
                    })
                    .collect();
                json!({"tools": listed})
            }
            "tools/call" => {
                let name = request["params"]["name"].as_str().unwrap_or("");
                match name {
                    "minerva_t3_code_status" => {
                        let mut current = status(&peer, contract);
                        current["registration_error"] = json!(registration_error);
                        tool_result(current)
                    }
                    "minerva_t3_code_generate" => {
                        let current = status(&peer, contract);
                        let mut errors: Vec<&str> = current["errors"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                            .collect();
                        if let Some(error) = registration_error.as_deref() {
                            errors.push(error);
                        }
                        errors.push("T3 Code runtime is not started: Phase B is pending the owner's installation decision. No prompt was sent.");
                        tool_result(
                            json!({"kind": "error", "code": "runtime_not_started", "text": errors.join("\n")}),
                        )
                    }
                    "minerva_t3_code_cancel" => tool_result(json!({
                        "cancelled": false, "state": "not-started",
                        "text": "No T3 run exists to interrupt.",
                        "operation_token": request["params"]["arguments"]["operation_token"]
                    })),
                    _ => {
                        peer.write(&json!({"jsonrpc": "2.0", "id": id,
                            "error": {"code": -32602, "message": "Unknown t3-code tool"}}))?;
                        continue;
                    }
                }
            }
            _ => {
                peer.write(&json!({"jsonrpc": "2.0", "id": id,
                    "error": {"code": -32601, "message": "Method not found"}}))?;
                continue;
            }
        };
        peer.write(&json!({"jsonrpc": "2.0", "id": id, "result": result}))?;
    }
    Ok(())
}

fn run() -> Result<(), String> {
    let contract = Contract::embedded()?;
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.is_empty() {
        return serve(&contract);
    }
    if arguments.len() == 2 && arguments[0] == "--check-catalog" {
        let input = std::fs::File::open(&arguments[1]).map_err(|e| e.to_string())?;
        let catalog: Value =
            serde_json::from_reader(io::BufReader::new(input)).map_err(|e| e.to_string())?;
        contract.check_catalog(&catalog)?;
        println!("{} tool contract is compatible", contract.t3_tag);
        return Ok(());
    }
    Err("Usage: t3-code-plugin [--check-catalog tools-list.json]".into())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("t3-code: {error}");
        std::process::exit(1);
    }
}
