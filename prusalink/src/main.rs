//! MCP stdio boundary. Password writes are explicit and results never echo secrets.
use std::collections::VecDeque;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;

use prusalink_plugin::client::{Client, Password};
use prusalink_plugin::config::{self, Printer, Store};
use prusalink_plugin::discovery;
use prusalink_plugin::error::{Error, Result};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};

const MAX_LINE: u64 = 1024 * 1024;
struct Peer {
    input: BufReader<io::Stdin>,
    out: io::Stdout,
    pending: VecDeque<Value>,
    next_id: u64,
}
impl Peer {
    fn send(&mut self, value: &Value) -> Result<()> {
        serde_json::to_writer(&mut self.out, value)
            .map_err(|_| Error::Io("Cannot write MCP response"))?;
        self.out
            .write_all(b"\n")
            .and_then(|()| self.out.flush())
            .map_err(|_| Error::Io("Cannot write MCP response"))
    }
    fn read(&mut self) -> Result<Option<Value>> {
        let mut bytes = Vec::new();
        let count = (&mut self.input)
            .take(MAX_LINE + 1)
            .read_until(b'\n', &mut bytes)
            .map_err(|_| Error::Io("Cannot read MCP input"))?;
        if count == 0 {
            return Ok(None);
        }
        if count as u64 > MAX_LINE {
            return Err(Error::Invalid("MCP input exceeds1MiB"));
        }
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| Error::Invalid("Invalid JSON-RPC input"))
    }
    fn capability(
        &mut self,
        operation: &str,
        printer: &Printer,
        arguments: Value,
    ) -> Result<Value> {
        self.next_id += 1;
        let id = format!("prusalink-cap-{}", self.next_id);
        self.send(&json!({"jsonrpc":"2.0","id":id,"method":"minerva/capability","params":{"capability":format!("secrets:{operation}:{}",printer.handle()),"args":arguments}}))?;
        while let Some(message) = self.read()? {
            if message["id"].as_str() == Some(&id) {
                if message.get("error").is_some() {
                    return Err(Error::Vault);
                }
                let envelope = &message["result"];
                if envelope["success"] != true {
                    return Err(Error::Vault);
                }
                return envelope.get("result").cloned().ok_or(Error::Vault);
            }
            if message["method"] == "notifications/cancelled"
                || message["method"] == "$/cancelRequest"
            {
                return Err(Error::Vault);
            }
            if message.get("method").is_some() {
                if self.pending.len() >= 32 {
                    return Err(Error::Vault);
                }
                self.pending.push_back(message);
            }
            // Unmatched capability replies are discarded without logging their data.
        }
        Err(Error::Vault)
    }
    fn password(&mut self, printer: &Printer) -> Result<Option<Password>> {
        let secret = self.capability("get", printer, json!({}))?;
        if secret["exists"] == false {
            return Ok(None);
        }
        let value = secret["value"].as_str().ok_or(Error::Vault)?;
        if value.is_empty() {
            return Ok(None);
        }
        Ok(Some(Password::new(value.to_owned())?))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DiscoverArgs {
    hosts: Option<Vec<String>>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PrinterArgs {
    printer: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SetPasswordArgs {
    printer: String,
    password: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ThumbnailArgs {
    printer: String,
    #[serde(default)]
    offset: usize,
    reference: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigureArgs {
    slot: Option<u8>,
    name: String,
    host: String,
    #[serde(default = "maker")]
    user: String,
}
fn maker() -> String {
    "maker".into()
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UploadArgs {
    printer: String,
    path: PathBuf,
    #[serde(default)]
    start: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PrintArgs {
    printer: String,
    file: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Empty {}
fn args<T: DeserializeOwned>(value: &Value) -> Result<T> {
    serde_json::from_value(value.clone())
        .map_err(|_| Error::Invalid("Arguments do not match this tool's schema"))
}

fn row(printer: &Printer, has_password: bool) -> Value {
    json!({"id":printer.id(),"slot":printer.slot,"name":printer.name,"host":printer.host,"user":printer.user,"has_password":has_password})
}
fn tool(peer: &mut Peer, store: &mut Store, name: &str, value: &Value) -> Result<Value> {
    match name {
        "discover" => {
            let a: DiscoverArgs = args(value)?;
            serde_json::to_value(discovery::discover(a.hosts)?)
                .map_err(|_| Error::Protocol("Cannot encode discovery result"))
        }
        "list_printers" => {
            let _: Empty = args(value)?;
            let mut printers = Vec::new();
            for printer in store.list() {
                printers.push(row(printer, peer.password(printer)?.is_some()));
            }
            Ok(json!({"printers":printers,"capacity":config::SLOTS}))
        }
        "configure_printer" => {
            let a: ConfigureArgs = args(value)?;
            let printer = store.configure(a.slot, a.name, a.host, a.user)?;
            Ok(
                json!({"id":printer.id(),"slot":printer.slot,"name":printer.name,"host":printer.host,"user":printer.user,"secret_handle":printer.handle()}),
            )
        }
        "set_password" => {
            let a: SetPasswordArgs = args(value)?;
            let printer = store.get(&a.printer)?.clone();
            if a.password.is_empty() || a.password.chars().count() > 4096 {
                return Err(Error::Invalid("Password must contain1–4096 characters"));
            }
            peer.capability("set", &printer, json!({"value":a.password}))?;
            // Verify the saved vault value, rather than authenticating a copy
            // of the input. Probe failures never undo a successful vault write.
            let probe: Result<()> = (|| {
                let password = peer.password(&printer)?.ok_or(Error::MissingPassword)?;
                Client::new(printer.clone(), password)?.status()?;
                Ok(())
            })();
            Ok(json!({"printer":printer.id(),"saved":true,"auth_ok":probe.is_ok()}))
        }
        "remove_printer" => {
            let a: PrinterArgs = args(value)?;
            let printer = store.get(&a.printer)?.clone();
            if peer.password(&printer)?.is_some() {
                peer.capability("delete", &printer, json!({}))?;
            }
            if peer.password(&printer)?.is_some() {
                return Err(Error::Vault);
            }
            store.remove(printer.slot)?;
            Ok(json!({"removed":printer.id(),"exists":false}))
        }
        "status" | "thumbnail" | "upload" | "print" | "stop" => {
            // Validate all argument keys before asking the host for a credential.
            enum Operation {
                Status,
                Thumbnail(usize, Option<String>),
                Stop,
                Upload(PathBuf, bool),
                Print(String),
            }
            let (id, operation) = match name {
                "status" => {
                    let a: PrinterArgs = args(value)?;
                    (a.printer, Operation::Status)
                }
                "thumbnail" => {
                    let a: ThumbnailArgs = args(value)?;
                    if a.offset > 512 * 1024 || !a.offset.is_multiple_of(24 * 1024) {
                        return Err(Error::Invalid("Thumbnail offset is out of range"));
                    }
                    (a.printer, Operation::Thumbnail(a.offset, a.reference))
                }
                "stop" => {
                    let a: PrinterArgs = args(value)?;
                    (a.printer, Operation::Stop)
                }
                "upload" => {
                    let a: UploadArgs = args(value)?;
                    (a.printer, Operation::Upload(a.path, a.start))
                }
                "print" => {
                    let a: PrintArgs = args(value)?;
                    (a.printer, Operation::Print(a.file))
                }
                _ => return Err(Error::Invalid("Unknown tool")),
            };
            let printer = store.get(&id)?.clone();
            let upload = matches!(&operation, Operation::Upload(..));
            if upload {
                eprintln!("prusalink upload phase=vault_request");
            }
            let password = peer.password(&printer)?.ok_or(Error::MissingPassword)?;
            if upload {
                eprintln!("prusalink upload phase=vault_received");
            }
            let mut client = Client::new(printer, password)?;
            match operation {
                Operation::Status => serde_json::to_value(client.status()?)
                    .map_err(|_| Error::Protocol("Cannot encode printer status")),
                Operation::Thumbnail(offset, reference) => {
                    client.thumbnail(offset, reference.as_deref())
                }
                Operation::Stop => client.stop(),
                Operation::Upload(path, start) => client.upload(&path, start),
                Operation::Print(file) => client.print(&file),
            }
        }
        _ => Err(Error::Invalid("Unknown PrusaLink tool")),
    }
}

fn tools() -> Result<Value> {
    let manifest: Value = serde_json::from_str(include_str!("../manifest.json"))
        .map_err(|_| Error::Protocol("Invalid plugin manifest"))?;
    let tools=manifest["tools"].as_array().ok_or(Error::Protocol("Missing manifest tools"))?.iter().map(|tool| {
        let name=tool["name"].as_str().and_then(|s|s.strip_prefix("minerva_prusalink_")).ok_or(Error::Protocol("Invalid manifest namespace"))?;
        Ok(json!({"name":name,"description":tool["description"],"inputSchema":tool["input_schema"]}))
    }).collect::<Result<Vec<_>>>()?;
    Ok(json!({"tools":tools}))
}
fn response(peer: &mut Peer, store: &mut Store, request: Value) -> Result<()> {
    let Some(id) = request.get("id").cloned() else {
        return Ok(());
    };
    if request["jsonrpc"] != "2.0" || !(id.is_null() || id.is_number() || id.is_string()) {
        return peer.send(
            &json!({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid request"}}),
        );
    }
    let result = match request["method"].as_str() {
        Some("initialize") => Ok(
            json!({"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"PrusaLink","version":env!("CARGO_PKG_VERSION")}}),
        ),
        Some("ping") => Ok(json!({})),
        Some("tools/list") => tools(),
        Some("tools/call") => {
            let value = request["params"]
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let outcome = request["params"]["name"]
                .as_str()
                .ok_or(Error::Invalid("Tool name is required"))
                .and_then(|name| {
                    tool(
                        peer,
                        store,
                        name.strip_prefix("minerva_prusalink_").unwrap_or(name),
                        &value,
                    )
                });
            Ok(match outcome {
                Ok(value) => json!({"content":[{"type":"text","text":value.to_string()}]}),
                Err(error) => {
                    json!({"isError":true,"content":[{"type":"text","text":json!({"error":error.to_string()}).to_string()}]})
                }
            })
        }
        _ => return peer.send(
            &json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Method not found"}}),
        ),
    };
    let reply = match result {
        Ok(value) => json!({"jsonrpc":"2.0","id":id,"result":value}),
        Err(error) => {
            json!({"jsonrpc":"2.0","id":id,"error":{"code":-32603,"message":error.to_string()}})
        }
    };
    peer.send(&reply)
}
fn serve() -> Result<()> {
    let mut store = Store::open(config::data_directory()?)?;
    let mut peer = Peer {
        input: BufReader::new(io::stdin()),
        out: io::stdout(),
        pending: VecDeque::new(),
        next_id: 0,
    };
    loop {
        let request = match peer.pending.pop_front() {
            Some(value) => Some(value),
            None => match peer.read() {
                Ok(value) => value,
                Err(Error::Invalid(_)) => {
                    peer.send(&json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Invalid or oversized JSON-RPC input"}}))?;
                    continue;
                }
                Err(error) => return Err(error),
            },
        };
        let Some(request) = request else {
            return Ok(());
        };
        response(&mut peer, &mut store, request)?;
    }
}
fn main() {
    if let Err(error) = serve() {
        eprintln!("prusalink: {error}");
        std::process::exit(1);
    }
}
