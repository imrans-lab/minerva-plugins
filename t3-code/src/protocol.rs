//! Minerva's line-delimited MCP transport; capability replies keep flowing
//! while the dispatch thread waits for the host.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{self, BufRead, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

pub struct Peer {
    output: Mutex<io::BufWriter<io::Stdout>>,
    pending: Mutex<HashMap<String, mpsc::Sender<Value>>>,
    next_id: AtomicU64,
}

impl Peer {
    pub fn start() -> (Arc<Self>, mpsc::Receiver<Value>) {
        let peer = Arc::new(Self {
            output: Mutex::new(io::BufWriter::new(io::stdout())),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
        });
        let (send, receive) = mpsc::channel();
        let reader = Arc::clone(&peer);
        std::thread::spawn(move || {
            for line in io::stdin().lock().lines() {
                let message = match line.map_err(|e| e.to_string()).and_then(|line| {
                    serde_json::from_str::<Value>(&line).map_err(|e| e.to_string())
                }) {
                    Ok(message) => message,
                    Err(error) => {
                        eprintln!("t3-code: invalid input: {error}");
                        break;
                    }
                };
                if message.get("method").is_some() {
                    if send.send(message).is_err() {
                        break;
                    }
                } else if let Some(id) = message.get("id").and_then(Value::as_str) {
                    let channel = match reader.pending.lock() {
                        Ok(mut pending) => pending.remove(id),
                        Err(_) => break,
                    };
                    if let Some(channel) = channel {
                        if channel.send(message).is_err() {
                            eprintln!("t3-code: host reply arrived after its caller ended");
                        }
                    }
                }
            }
        });
        (peer, receive)
    }

    pub fn write(&self, message: &Value) -> Result<(), String> {
        let mut output = self.output.lock().map_err(|_| "output lock failed")?;
        serde_json::to_writer(&mut *output, message).map_err(|e| e.to_string())?;
        writeln!(output).map_err(|e| e.to_string())?;
        output.flush().map_err(|e| e.to_string())
    }

    pub fn capability(&self, name: &str, arguments: Value) -> Result<Value, String> {
        let id = format!("t3-cap-{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        let (send, receive) = mpsc::channel();
        self.pending
            .lock()
            .map_err(|_| "pending lock failed")?
            .insert(id.clone(), send);
        let result = self
            .write(&json!({
                "jsonrpc": "2.0", "id": id, "method": "minerva/capability",
                "params": {"capability": name, "args": arguments}
            }))
            .and_then(|()| {
                receive
                    .recv_timeout(Duration::from_secs(5))
                    .map_err(|_| format!("{name}: host did not answer within 5 seconds"))
            });
        self.pending
            .lock()
            .map_err(|_| "pending lock failed")?
            .remove(&id);
        let reply = result?;
        if reply.get("error").is_some() {
            return Err(format!("{name}: host refused the capability request"));
        }
        let envelope = &reply["result"];
        if envelope["success"] != true {
            return Err(format!(
                "{name}: {}",
                envelope["error_message"].as_str().unwrap_or("host refused")
            ));
        }
        envelope
            .get("result")
            .cloned()
            .ok_or_else(|| format!("{name}: missing result envelope"))
    }
}
