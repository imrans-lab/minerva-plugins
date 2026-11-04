use crate::{
    contract::Contract,
    engine::Engine,
    fault::{Fault, Result},
    launch,
    manager::Manager,
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
    manager: Mutex<Option<Arc<Manager>>>,
    startup_error: Mutex<Option<String>>,
}

impl App {
    pub fn new(contract: Contract) -> Self {
        Self {
            contract,
            registration_error: Mutex::new(None),
            engines: Mutex::new(BTreeMap::new()),
            manager: Mutex::new(None),
            startup_error: Mutex::new(None),
        }
    }

    /// Host initialization is the only start input. Tool calls never invoke it.
    pub fn start(&self, peer: Arc<Peer>) {
        let result = (|| -> Result<()> {
            let mut manager = self
                .manager
                .lock()
                .map_err(|_| Fault::new("lock_failed", "Runtime registry lock failed."))?;
            if manager.is_some() {
                return Ok(());
            }
            let settings = self.settings(&peer)?;
            let engine = self.engine(&settings)?;
            *manager = Some(Manager::launch(
                settings,
                self.contract.clone(),
                peer,
                engine,
            ));
            Ok(())
        })();
        if let Err(error) = result {
            if let Ok(mut slot) = self.startup_error.lock() {
                *slot = Some(error.text);
            }
        }
    }

    fn manager(&self) -> Result<Arc<Manager>> {
        self.manager.lock().map_err(|_|Fault::new("lock_failed","Runtime registry lock failed."))?.as_ref().cloned()
            .ok_or_else(||Fault::held("runtime_not_started","Runtime lifecycle initialization did not complete. Check status and restart the plugin; Generate never starts it."))
    }

    pub fn shutdown(&self) {
        let manager = self
            .manager
            .lock()
            .ok()
            .and_then(|slot| slot.as_ref().cloned());
        if let Some(manager) = manager {
            manager.shutdown();
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
                json!({"state":"NO_INSTALL","ready":false,"thread_id":"","run_id":"","endpoint":"",
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
            "minerva_t3_code_generate" | "minerva_t3_code_launch" => {
                if name == "minerva_t3_code_launch" && settings.workspace.as_os_str().is_empty() {
                    return Err(Fault::held(
                        "project_unsaved",
                        "Save the Minerva project as a .minproj before starting a T3 session.",
                    ));
                }
                if let Some(error) = self
                    .registration_error
                    .lock()
                    .map_err(|_| Fault::new("lock_failed", "Registration lock failed."))?
                    .as_ref()
                {
                    return Err(Fault::held("registration_failed", error));
                }
                let authorization = (|| -> Result<Arc<Manager>> {
                    let manager = self.manager()?;
                    let chat = if let Some(id) = args["chat_id"].as_str() {
                        engine.chat_status(id)?
                    } else {
                        json!({})
                    };
                    manager.workspace(&settings, chat["workspace"].as_str())?;
                    if args["resume"] == true {
                        manager.wait_for_auth()?;
                    }
                    manager.authorize(&settings)?;
                    Ok(manager)
                })();
                let manager = match authorization {
                    Ok(manager) => manager,
                    Err(mut fault) => {
                        engine.correct_held(args, &mut fault)?;
                        return Err(fault);
                    }
                };
                let result = if name == "minerva_t3_code_launch" {
                    engine.launch(&settings, &self.contract, args, &manager)
                } else {
                    engine.generate(peer, &settings, &self.contract, args)
                };
                if result
                    .as_ref()
                    .is_err_and(|error| error.code == "auth_required")
                {
                    manager.auth_failed();
                }
                result
            }
            "minerva_t3_code_cancel" => {
                engine.record_cancel(args)?;
                let manager = match self.manager() {
                    Ok(manager) => manager,
                    Err(_) => {
                        return Ok(
                            json!({"cancelled":false,"state":"runtime_unavailable","operation_token":args["operation_token"]}),
                        )
                    }
                };
                if !manager.wait_for_auth()? {
                    return Ok(
                        json!({"cancelled":false,"state":"runtime_unavailable","operation_token":args["operation_token"]}),
                    );
                }
                let result = engine.cancel_recorded(manager.owned_settings(), &self.contract, args);
                if result
                    .as_ref()
                    .is_err_and(|error| error.code == "auth_required")
                {
                    if let Ok(manager) = self.manager() {
                        manager.auth_failed();
                    }
                }
                result
            }
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
                current["startup_error"] = json!(*self
                    .startup_error
                    .lock()
                    .map_err(|_| Fault::new("lock_failed", "Startup error lock failed."))?);
                if let Ok(manager) = self.manager() {
                    manager.observe_version(&current, &self.contract)?;
                }
                let lifecycle=self.manager().and_then(|manager|manager.status()).unwrap_or_else(|error|json!({"state":"NO_INSTALL","ready":false,"runtime_message":error.text}));
                for (key, value) in lifecycle.as_object().ok_or_else(|| {
                    Fault::new("manager_state", "Runtime status is not an object.")
                })? {
                    current[key] = value.clone();
                }
                current["compatibility"]["ownership"] = current["ownership"].clone();
                current["compatibility"]["runtime_workspace"] =
                    current["runtime_workspace"].clone();
                current["compatibility"]["owned_versions"] = current["owned_versions"].clone();
                current["version_warning"] = if current["prerequisites_ok"] != true {
                    current["errors"].clone()
                } else {
                    Value::Null
                };
                if args["chat_id"].is_null() {
                    current["launch_options"] = json!({"available":false,"workspace":settings.workspace,
                        "registered":null,"models":[],"default":null,"error_code":"runtime_not_ready"});
                }
                if current["ready"] != true {
                    return Ok(current);
                }
                match engine.runtimes.get(&settings, &self.contract) {
                    Ok(runtime) => {
                        current["endpoint"] = json!(runtime.receipt.endpoint);
                        current["runtime_message"] = json!("Owned T3 runtime is ready. Model calls begin only on Generate; installation drift takes effect on next plugin start.");
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
                        if args["chat_id"].is_null() {
                            current["launch_options"] = launch::options(&runtime).unwrap_or_else(|fault| json!({"available":false,"workspace":runtime.receipt.workspace,
                                "registered":null,"models":[],"default":null,"error_code":fault.code,"error_message":fault.text}));
                        }
                    }
                    Err(error) => {
                        current["ready"] = json!(false);
                        if error.code == "auth_required" {
                            if let Ok(manager) = self.manager() {
                                manager.auth_failed();
                            }
                            current["state"] = json!("DEGRADED");
                        }
                        current["runtime_message"] = json!(error.text);
                        current["runtime_error"] = json!(error.code);
                        if args["chat_id"].is_null() {
                            current["launch_options"]["error_code"] = json!(error.code);
                            current["launch_options"]["error_message"] = json!(error.text);
                        }
                    }
                }
                Ok(current)
            }
            _ => Err(Fault::held("unknown_tool", "Unknown T3 Code tool.")),
        }
    }
}

impl Drop for App {
    fn drop(&mut self) {
        self.shutdown();
    }
}
