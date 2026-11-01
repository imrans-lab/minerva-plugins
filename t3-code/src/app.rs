use crate::{
    contract::Contract,
    engine::Engine,
    fault::{Fault, Result},
    probe::{self, Settings},
    protocol::Peer,
    runtime,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

pub struct App {
    pub contract: Contract,
    pub registration_error: Mutex<Option<String>>,
    engines: Mutex<BTreeMap<PathBuf, Arc<Engine>>>,
}

impl App {
    pub fn new(contract: Contract) -> Self {
        Self {
            contract,
            registration_error: Mutex::new(None),
            engines: Mutex::new(BTreeMap::new()),
        }
    }

    fn settings(&self, peer: &Peer) -> Result<Settings> {
        let fields = peer
            .capability("host.settings.list", json!({}))
            .map_err(|e| Fault::held("host_unavailable", e))?;
        let project = peer
            .capability("host.project.current", json!({}))
            .map_err(|e| Fault::held("host_unavailable", e))?;
        Settings::from_host(&fields, &project).map_err(|e| Fault::held("settings", e))
    }

    fn engine(&self, settings: &Settings) -> Result<Arc<Engine>> {
        let mut engines = self
            .engines
            .lock()
            .map_err(|_| Fault::new("lock_failed", "Engine registry lock failed."))?;
        if let Some(engine) = engines.get(&settings.private) {
            return Ok(Arc::clone(engine));
        }
        let engine = Arc::new(Engine::open(settings)?);
        engines.insert(settings.private.clone(), Arc::clone(&engine));
        Ok(engine)
    }

    pub fn call(&self, peer: &Peer, name: &str, args: &Value) -> Value {
        self.call_inner(peer, name, args).unwrap_or_else(|fault| {
            if name == "minerva_t3_code_status" {
                json!({"state":"not-started","ready":false,"thread_id":"","run_id":"","endpoint":"",
                    "provider":"codex","t3_tag":self.contract.t3_tag,"errors":[fault.text],
                    "compatibility":self.contract.compatibility(json!({}))})
            } else {
                fault.reply()
            }
        })
    }

    fn call_inner(&self, peer: &Peer, name: &str, args: &Value) -> Result<Value> {
        if args.get("entry_id").is_some_and(|entry| entry != "t3-code") {
            return Err(Fault::held(
                "invalid_entry",
                "This tool serves only the t3-code provider entry.",
            ));
        }
        let settings = self.settings(peer)?;
        let engine = self.engine(&settings)?;
        match name {
            "minerva_t3_code_generate" => {
                if let Some(error) = self
                    .registration_error
                    .lock()
                    .map_err(|_| Fault::new("lock_failed", "Registration lock failed."))?
                    .as_ref()
                {
                    return Err(Fault::held("registration_failed", error));
                }
                engine.generate(peer, &settings, &self.contract, args)
            }
            "minerva_t3_code_cancel" => engine.cancel(&settings, &self.contract, args),
            "minerva_t3_code_status" => {
                let mut current = probe::inspect(&settings, &self.contract)
                    .map_err(|e| Fault::held("prerequisites", e))?;
                if let Some(id) = args["chat_id"].as_str() {
                    for (key, value) in engine.chat_status(id)?.as_object().ok_or_else(|| {
                        Fault::new("invalid_state", "Chat status is not an object.")
                    })? {
                        current[key] = value.clone();
                    }
                }
                current["registration_error"] = json!(*self
                    .registration_error
                    .lock()
                    .map_err(|_| Fault::new("lock_failed", "Registration lock failed."))?);
                match engine.runtimes.get(&settings, &self.contract) {
                    Ok(runtime) => {
                        current["state"] = json!("owned-runtime");
                        current["phase"] = json!("B");
                        current["ready"] = json!(current["prerequisites_ok"] == true);
                        current["endpoint"] = json!(runtime.receipt.endpoint);
                        current["runtime_message"] = json!("Using the Phase B manager's owned runtime receipt. Model calls begin only on Generate.");
                        current["drift_probe"] = json!("passed: owned server tools/list");
                        let mode = current["permission"]["runtime_mode"]
                            .as_str()
                            .unwrap_or("approval-required")
                            .to_owned();
                        current["runtime_mode_source"] = json!(if current["thread_id"] == "" {
                            "explicit launch setting; no thread yet"
                        } else {
                            "last recorded explicit or observed bound-thread mode"
                        });
                        if current["thread_lost"] == true
                            || current["outcome_unknown"] == true
                            || mode != "approval-required"
                            || !current["registration_error"].is_null()
                        {
                            current["ready"] = json!(false);
                        }
                        current["permission"] = runtime::permission(&mode);
                        current["access_ceiling"] = json!(runtime.receipt.runtime_mode_ceiling);
                        current["compatibility"]["runtime_mode"] = json!(mode);
                        current["compatibility"]["model_selection"] = current
                            .get("model_selection")
                            .cloned()
                            .unwrap_or(Value::Null);
                    }
                    Err(error) => {
                        current["runtime_message"] = json!(error.text);
                        current["runtime_error"] = json!(error.code);
                    }
                }
                Ok(current)
            }
            _ => Err(Fault::held("unknown_tool", "Unknown T3 Code tool.")),
        }
    }
}
