mod app;
mod contract;
mod engine;
mod fault;
mod inventory;
mod manager;
mod mcp;
mod owned_process;
mod probe;
mod protocol;
mod questions;
mod runtime;
mod runtime_files;
mod shutdown;
mod snapshot;
mod storage;
mod turn;

use app::App;
use contract::Contract;
use protocol::Peer;
use serde_json::{json, Value};
use std::io;
use std::sync::Arc;

const MANIFEST: &str = include_str!("../manifest.json");

fn tool_result(value: Value) -> Value {
    json!({"content":[{"type":"text","text":value.to_string()}]})
}

fn register(peer: &Peer) -> Result<(), String> {
    peer.capability(
        "host.chat_providers.register",
        json!({
            "entry_id":"t3-code","display_name":"T3 Code (Codex)",
            "generate_tool":"minerva_t3_code_generate","cancel_tool":"minerva_t3_code_cancel",
            "history_mode":"newest_only","timeout_sec":600,
            "metadata":{"resumable":true,"interrupt_in_place":true}
        }),
    )
    .map(|_| ())
}

fn serve(contract: Contract) -> Result<(), String> {
    shutdown::install()?;
    let manifest: Value = serde_json::from_str(MANIFEST).map_err(|e| e.to_string())?;
    let app = Arc::new(App::new(contract));
    let (peer, requests) = Peer::start();
    let mut workers: Vec<std::thread::JoinHandle<()>> = Vec::new();
    loop {
        if shutdown::requested() {
            break;
        }
        let request = match requests.recv_timeout(std::time::Duration::from_millis(100)) {
            Ok(request) => request,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        };
        workers.retain(|worker| !worker.is_finished());
        let method = request["method"].as_str().unwrap_or("");
        if method == "notifications/initialized" {
            let registration = register(&peer);
            let registered = registration.is_ok();
            *app.registration_error
                .lock()
                .map_err(|_| "Registration lock failed")? = registration.err();
            if registered {
                app.start(Arc::clone(&peer));
            }
            continue;
        }
        if request.get("id").is_none() {
            continue;
        }
        let id = &request["id"];
        if method == "tools/call" {
            // Independent chats and Stop remain responsive during a bounded
            // generate wait. Each chat's Engine gate serializes its sends.
            if workers.len() >= 32 {
                peer.write(&json!({"jsonrpc":"2.0","id":id,"result":tool_result(
                    fault::Fault::held("busy","Plugin has32 active calls; retry this held call.").reply())}))?;
                continue;
            }
            let app = Arc::clone(&app);
            let peer = Arc::clone(&peer);
            workers.push(std::thread::spawn(move || {
                let params = &request["params"];
                let result = app.call(
                    &peer,
                    params["name"].as_str().unwrap_or(""),
                    &params["arguments"],
                );
                if let Err(error) = peer.write(
                    &json!({"jsonrpc":"2.0","id":request["id"],"result":tool_result(result)}),
                ) {
                    eprintln!("t3-code: {error}");
                }
            }));
            continue;
        }
        let result = match method {
            "initialize" => json!({"protocolVersion":"2024-11-05","serverName":"t3-code",
                "serverVersion":env!("CARGO_PKG_VERSION"),"serverInfo":{"name":"t3-code","version":env!("CARGO_PKG_VERSION")},"capabilities":{"tools":{}}}),
            "ping" => json!({}),
            "tools/list" => {
                let tools = manifest["tools"]
                    .as_array()
                    .ok_or("Embedded manifest has no tools")?;
                json!({"tools":tools.iter().map(|tool|json!({"name":tool["name"],"description":tool["description"],"inputSchema":tool["input_schema"]})).collect::<Vec<_>>()})
            }
            _ => {
                peer.write(&json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Method not found"}}))?;
                continue;
            }
        };
        peer.write(&json!({"jsonrpc":"2.0","id":id,"result":result}))?;
    }
    app.shutdown();
    for worker in workers {
        if worker.join().is_err() {
            return Err("Tool worker panicked".into());
        }
    }
    Ok(())
}

fn run() -> Result<(), String> {
    let contract = Contract::embedded()?;
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.is_empty() {
        return serve(contract);
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
