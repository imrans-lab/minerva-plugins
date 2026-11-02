//! Sole owner of runtime lifecycle. Generate can ask for one auth reissue; it
//! cannot spawn/restart a server. Process ownership never comes from disk.

use crate::{
    contract::Contract,
    engine::Engine,
    fault::{Fault, Result},
    inventory,
    mcp::Client,
    owned_process::{Launch, OwnedProcess},
    probe::{self, Settings},
    protocol::Peer,
    runtime::{now, Receipt},
    runtime_files::{self, Files},
    storage::{random_id, read_private},
};
use serde_json::{json, Value};
use std::{
    fs::OpenOptions,
    net::TcpListener,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Mutex,
    },
    thread::JoinHandle,
    time::Duration,
};

#[derive(Clone, Copy, PartialEq)]
enum State {
    NoInstall,
    Installed,
    Starting,
    Ready,
    Degraded,
    Stopping,
    Crashed,
    Drift,
}
impl State {
    fn name(self) -> &'static str {
        match self {
            Self::NoInstall => "NO_INSTALL",
            Self::Installed => "INSTALLED",
            Self::Starting => "STARTING",
            Self::Ready => "READY",
            Self::Degraded => "DEGRADED",
            Self::Stopping => "STOPPING",
            Self::Crashed => "CRASHED",
            Self::Drift => "DRIFT",
        }
    }
    fn reason(self) -> &'static str {
        match self {
            Self::NoInstall => "runtime_no_install",
            Self::Installed => "runtime_installed",
            Self::Starting => "runtime_starting",
            Self::Ready => "runtime_ready",
            Self::Degraded => "auth_required",
            Self::Stopping => "runtime_stopping",
            Self::Crashed => "runtime_crashed",
            Self::Drift => "runtime_drift",
        }
    }
}
struct View {
    state: State,
    step: String,
    failure: Option<String>,
    receipt: Option<Receipt>,
    receipt_current: bool,
    renewing: bool,
    ownership: String,
    disabled: Vec<String>,
    exit: Value,
    pid: Option<u32>,
    versions: Value,
}
enum Input {
    Renew(mpsc::Sender<Result<()>>),
    AuthBarrier(mpsc::Sender<Result<bool>>),
    Stop,
}
pub struct Manager {
    settings: Settings,
    view: Mutex<View>,
    send: mpsc::Sender<Input>,
    stop: AtomicBool,
    worker: Mutex<Option<JoinHandle<()>>>,
}

impl Manager {
    pub fn launch(
        mut settings: Settings,
        contract: Contract,
        peer: Arc<Peer>,
        engine: Arc<Engine>,
    ) -> Arc<Self> {
        if let Ok(folder) = settings.workspace.canonicalize() {
            settings.workspace = folder;
        }
        let (send, receive) = mpsc::channel();
        let manager = Arc::new(Self {
            settings,
            view: Mutex::new(View {
                state: State::NoInstall,
                step: "prerequisites".into(),
                failure: None,
                receipt: None,
                receipt_current: false,
                renewing: false,
                ownership: "not-started".into(),
                disabled: Vec::new(),
                exit: Value::Null,
                pid: None,
                versions: Value::Null,
            }),
            send,
            stop: AtomicBool::new(false),
            worker: Mutex::new(None),
        });
        let runner = Arc::clone(&manager);
        let worker = std::thread::spawn(move || {
            if let Err(error) = runner.run(receive, &contract, &peer, &engine) {
                if let Ok(mut view) = runner.view.lock() {
                    view.state = State::Crashed;
                    view.receipt_current = false;
                    view.receipt = None;
                    view.pid = None;
                }
                runner.fail(&error);
                if let Err(error) = engine.process_exited(&peer) {
                    eprintln!("t3-code: {}", error.text);
                }
            }
        });
        if let Ok(mut slot) = manager.worker.lock() {
            *slot = Some(worker);
        }
        manager
    }
    fn view(&self) -> Result<std::sync::MutexGuard<'_, View>> {
        self.view
            .lock()
            .map_err(|_| Fault::new("lock_failed", "Runtime manager lock failed."))
    }
    fn step(&self, step: &str) -> Result<()> {
        self.view()?.step = step.into();
        self.check_stop()
    }
    fn check_stop(&self) -> Result<()> {
        if self.stop.load(Ordering::Acquire) {
            Err(Fault::held(
                "runtime_stopping",
                "Plugin unload interrupted runtime startup.",
            ))
        } else {
            Ok(())
        }
    }
    fn fail(&self, error: &Fault) {
        if let Ok(mut view) = self.view.lock() {
            view.failure = Some(error.text.clone());
        }
    }

    fn same_settings(&self, current: &Settings) -> Result<()> {
        if current.private != self.settings.private {
            return Err(Fault::held(
                "runtime_identity_changed",
                "Plugin data directory changed; restart the plugin.",
            ));
        }
        for key in [
            "t3_binary",
            "node_binary",
            "codex_binary",
            "codex_home",
            "t3_base_dir",
            "t3_token_file",
            "minerva_mcp_endpoint",
        ] {
            if runtime_files::setting(current, key)? != runtime_files::setting(&self.settings, key)?
            {
                return Err(Fault::held("runtime_identity_changed",format!("Setting {key} changed. Restart the plugin to establish a new owned runtime; no endpoint is adopted.")));
            }
        }
        Ok(())
    }

    pub fn authorize(&self, settings: &Settings) -> Result<()> {
        self.same_settings(settings)?;
        let observed_at = now()?;
        {
            let mut view = self.view()?;
            if view.state == State::Ready
                && view
                    .receipt
                    .as_ref()
                    .is_some_and(|r| r.expires_at_unix <= observed_at.saturating_add(10))
            {
                view.state = State::Degraded;
            }
            if view.state == State::Ready {
                return Ok(());
            }
            if view.state != State::Degraded {
                return Err(Fault::held(view.state.reason(),format!("Owned T3 runtime is {}. Check status and restart the plugin after resolving its prerequisite/failure; Generate never starts a server.",view.state.name())));
            }
        }
        let (send, receive) = mpsc::channel();
        self.send.send(Input::Renew(send)).map_err(|_| {
            Fault::held(
                "runtime_crashed",
                "Owned runtime supervisor has stopped; restart the plugin.",
            )
        })?;
        receive
            .recv_timeout(Duration::from_secs(90))
            .map_err(|_| {
                Fault::held(
                    "auth_required",
                    "Owned auth reissue did not finish within90 seconds; no prompt was sent.",
                )
            })??;
        self.check_stop()
    }

    pub fn auth_failed(&self) {
        if let Ok(mut view) = self.view.lock() {
            if view.state == State::Ready {
                view.state = State::Degraded;
            }
        }
    }

    pub fn workspace(&self, current: &Settings, bound: Option<&str>) -> Result<()> {
        if !matches!(self.view()?.state, State::Ready | State::Degraded) {
            return Ok(());
        }
        let pinned = self.settings.workspace.canonicalize().ok();
        let current_folder = current.workspace.canonicalize().ok();
        let bound_folder = bound
            .map(std::path::Path::new)
            .map(|p| p.canonicalize())
            .transpose()?;
        if pinned.is_none()
            || pinned != current_folder
            || bound_folder
                .as_ref()
                .is_some_and(|folder| Some(folder) != pinned.as_ref())
        {
            return Err(Fault::held("runtime_workspace_changed",format!("Owned runtime folder: {}. Current folder: {}. Chat-bound folder: {}. Save the current project and restart the plugin to switch folders; startup MCP inventory applies to one folder only.",self.settings.workspace.display(),if current.workspace.as_os_str().is_empty(){"<unsaved>".into()}else{current.workspace.display().to_string()},bound.unwrap_or("<new chat>"))));
        }
        Ok(())
    }

    pub fn owned_settings(&self) -> &Settings {
        &self.settings
    }

    pub fn wait_for_auth(&self) -> Result<bool> {
        if !matches!(self.view()?.state, State::Ready | State::Degraded) {
            return Ok(false);
        }
        let (send, receive) = mpsc::channel();
        // The same supervisor serializes renewal and read/Stop barriers.
        // Waiting never issues another credential after a failed renewal.
        self.send.send(Input::AuthBarrier(send)).map_err(|_| {
            Fault::held(
                "runtime_crashed",
                "The runtime supervisor stopped before auth became available.",
            )
        })?;
        receive.recv_timeout(Duration::from_secs(90)).map_err(|_| {
            Fault::held(
                "auth_required",
                "Waiting for auth renewal timed out; the operation was not resumed or interrupted.",
            )
        })?
    }

    pub fn observe_version(&self, probe: &Value, contract: &Contract) -> Result<()> {
        let mut view = self.view()?;
        if view.state == State::Installed
            && probe["compatibility"]["detected_versions"]["t3"]
                .as_str()
                .is_some_and(|version| format!("v{version}") != contract.t3_tag)
        {
            view.state = State::Drift;
        }
        Ok(())
    }

    pub fn status(&self) -> Result<Value> {
        let mut view = self.view()?;
        let current = now()?;
        if view.state == State::Ready
            && view
                .receipt
                .as_ref()
                .is_some_and(|r| r.expires_at_unix <= current.saturating_add(10))
        {
            view.state = State::Degraded;
        }
        Ok(
            json!({"state":view.state.name(),"ready":view.state==State::Ready,"phase":"B",
            "last_failure_step":if view.failure.is_some(){Some(&view.step)}else{None},"runtime_message":view.failure,
            "runtime_step":view.step,"endpoint":view.receipt.as_ref().map(|r|&r.endpoint),
            "server_epoch":view.receipt.as_ref().map(|r|&r.server_epoch),"session_id":view.receipt.as_ref().map(|r|&r.session_id),
            "session_expires_at_unix":view.receipt.as_ref().map(|r|r.expires_at_unix),"receipt_stale":view.state==State::Degraded,
            "receipt_current":view.receipt_current,"auth_reissuing":view.renewing,"ownership":view.ownership,"owned_pid":view.pid,
            "disabled_mcp_entries":view.disabled,"server_exit":view.exit,"access_ceiling":"approval-required",
            "owned_versions":view.versions,"resolved_codex_binary":view.receipt.as_ref().map(|r|&r.resolved_codex_binary),
            "owned_base_dir":view.receipt.as_ref().map(|r|&r.base_dir),"owned_codex_home":view.receipt.as_ref().map(|r|&r.codex_home),
            "runtime_workspace":self.settings.workspace,
            "hard_kill_limit":"Plugin SIGKILL cannot run cleanup. Linux direct-child parent-death SIGTERM and exact stale-scope recovery mitigate it; fallback/macOS orphan-free cleanup is unproven and needs the T4 hardware lane."}),
        )
    }

    pub fn shutdown(&self) {
        self.stop.store(true, Ordering::Release);
        if self.send.send(Input::Stop).is_err() { /* Already stopped; join still owns its receipt. */
        }
        if let Ok(mut worker) = self.worker.lock() {
            if let Some(worker) = worker.take() {
                if worker.join().is_err() {
                    eprintln!("t3-code: runtime supervisor panicked");
                }
            }
        }
    }

    fn start(
        &self,
        contract: &Contract,
        files: &mut Option<Files>,
        process: &mut Option<OwnedProcess>,
    ) -> Result<()> {
        self.step("prerequisites")?;
        let probe = probe::inspect(&self.settings, contract)
            .map_err(|e| Fault::held("prerequisites", e))?;
        self.view()?.versions = probe["compatibility"]["detected_versions"].clone();
        if probe["prerequisites_ok"] != true {
            let version = probe["compatibility"]["detected_versions"]["t3"].as_str();
            self.view()?.state = if version.is_some_and(|v| format!("v{v}") != contract.t3_tag) {
                State::Drift
            } else {
                State::NoInstall
            };
            return Err(Fault::held("prerequisites", probe["errors"].to_string()));
        }
        let executable = probe["t3_executable"]
            .as_str()
            .ok_or_else(|| {
                Fault::held(
                    "prerequisites",
                    "No installed native T3 executable was resolved.",
                )
            })?
            .to_owned();
        self.view()?.state = State::Installed;
        self.step("private_paths")?;
        *files = Some(Files::prepare(
            self.settings.clone(),
            executable,
            random_id()?,
        )?);
        let files = files
            .as_mut()
            .ok_or_else(|| Fault::new("manager_state", "Owned runtime files were not prepared."))?;
        self.step("codex_mcp_inventory")?;
        let disabled = inventory::disabled_entries(
            &self.settings,
            &files.codex_binary,
            &files.environment,
            &self.stop,
        )?;
        self.view()?.disabled = disabled.clone();
        self.step("private_t3_settings")?;
        let launch_args = files.configure(&disabled)?;
        files
            .environment
            .push(("T3CODE_CODEX_LAUNCH_ARGS".into(), Some(launch_args)));
        self.step("connect_off")?;
        files.cli_cancellable(&["connect", "unlink"], Some(&self.stop))?;
        self.step("serve")?;
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
        let port = listener.local_addr()?.port();
        drop(listener);
        let endpoint = format!("http://127.0.0.1:{port}/mcp");
        use std::os::unix::fs::OpenOptionsExt;
        let log_path = files
            .base
            .join(format!("minerva-serve-{}.log", files.epoch));
        let log = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(log_path)?;
        let args = vec![
            "serve".into(),
            "--base-dir".into(),
            files.base.to_string_lossy().into_owned(),
            "--host".into(),
            "127.0.0.1".into(),
            "--port".into(),
            port.to_string(),
            "--mode".into(),
            "web".into(),
            "--no-browser".into(),
        ];
        *process = Some(
            Launch {
                program: &files.executable,
                args: &args,
                epoch: &files.epoch,
                environment: &files.environment,
                directory: &files.base,
                scope: true,
            }
            .spawn((
                Stdio::null(),
                Stdio::from(log.try_clone()?),
                Stdio::from(log),
            ))?,
        );
        let process = process
            .as_mut()
            .ok_or_else(|| Fault::new("manager_state", "Owned runtime process was not created."))?;
        {
            let mut view = self.view()?;
            view.state = State::Starting;
            view.ownership = process.mechanism().into();
            view.pid = Some(process.child.id());
        }
        self.step("mcp_client_issuer")?;
        let receipt = files.issue(
            contract,
            &endpoint,
            disabled,
            process.mechanism().into(),
            &self.stop,
        )?;
        self.step("tools_list")?;
        // Listener readiness is read-only. Authentication/catalog failures are
        // never retried as mutations and do not adopt a different endpoint.
        let deadline = std::time::Instant::now() + Duration::from_secs(30);
        loop {
            self.check_stop()?;
            if process.exited()? {
                return Err(Fault::held(
                    "runtime_crashed",
                    "Owned T3 server exited during startup.",
                ));
            }
            match self.probe_catalog(files, &receipt, contract) {
                Ok(()) => break,
                Err(error)
                    if error.code == "outcome_unknown" && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(200))
                }
                Err(error) => {
                    if error.code == "contract_mismatch" {
                        self.view()?.state = State::Drift;
                    }
                    return Err(error);
                }
            }
        }
        self.step("runtime_receipt")?;
        files.publish(&receipt)?;
        let mut view = self.view()?;
        view.receipt = Some(receipt);
        view.receipt_current = true;
        view.state = State::Ready;
        view.step = "ready".into();
        view.failure = None;
        Ok(())
    }

    fn probe_catalog(&self, files: &Files, receipt: &Receipt, contract: &Contract) -> Result<()> {
        self.check_stop()?;
        let client = Client::connect_timed(
            &receipt.endpoint,
            read_private(&files.token)?,
            Duration::from_secs(1),
            Some(&self.stop),
        )?;
        self.check_stop()?;
        contract
            .check_catalog(&client.rpc("tools/list", json!({}))?)
            .map_err(|e| Fault::held("contract_mismatch", e))
    }

    fn renew(&self, files: &mut Files, contract: &Contract) -> Result<()> {
        {
            let mut view = self.view()?;
            if view.state == State::Ready {
                return Ok(());
            }
            if view.state != State::Degraded {
                return Err(Fault::held(
                    view.state.reason(),
                    "Runtime is no longer available for auth reissue.",
                ));
            }
            view.renewing = true;
            view.receipt_current = false;
            view.step = "auth_reissue".into();
        }
        let result = (|| {
            self.check_stop()?;
            let old = self.view()?.receipt.clone().ok_or_else(|| {
                Fault::held("auth_required", "No owned receipt exists for reissue.")
            })?;
            let receipt = files.issue(
                contract,
                &old.endpoint,
                old.disabled_mcp_entries,
                old.ownership,
                &self.stop,
            )?;
            self.view()?.receipt = Some(receipt.clone());
            files.publish(&receipt)?;
            self.probe_catalog(files, &receipt, contract)?;
            self.check_stop()?;
            let mut view = self.view()?;
            view.state = State::Ready;
            view.receipt_current = true;
            view.step = "ready".into();
            view.failure = None;
            Ok(())
        })();
        self.view()?.renewing = false;
        if let Err(error) = &result {
            self.fail(error);
        }
        result
    }

    fn cleanup(&self, files: &mut Option<Files>, process: &mut Option<OwnedProcess>) -> Result<()> {
        let mut failure = None;
        if let Some(files) = files {
            if let Err(error) = files.revoke() {
                failure = Some(error);
            }
            if let Err(error) = files.retire() {
                failure = Some(error);
            }
        }
        if let Some(mut process) = process.take() {
            match process.stop() {
                Ok(status) => {
                    self.view()?.exit = json!(status.to_string());
                }
                Err(error) => failure = Some(error),
            }
        }
        let mut view = self.view()?;
        view.receipt = None;
        view.receipt_current = false;
        view.pid = None;
        if let Some(error) = failure {
            return Err(error);
        }
        Ok(())
    }

    fn run(
        &self,
        receive: mpsc::Receiver<Input>,
        contract: &Contract,
        peer: &Peer,
        engine: &Engine,
    ) -> Result<()> {
        let mut files = None;
        let mut process = None;
        if let Err(error) = self.start(contract, &mut files, &mut process) {
            self.fail(&error);
            let cleanup = self.cleanup(&mut files, &mut process);
            if !matches!(self.view()?.state, State::NoInstall | State::Drift) {
                self.view()?.state = if cleanup.is_ok() {
                    State::Installed
                } else {
                    State::Crashed
                };
            }
            if let Err(error) = cleanup {
                self.fail(&error);
            }
            return Ok(());
        }
        loop {
            if self.stop.load(Ordering::Acquire) {
                break;
            }
            let owned = process
                .as_mut()
                .ok_or_else(|| Fault::new("manager_state", "Supervisor lost its owned process."))?;
            if let Err(error) = owned.track() {
                eprintln!("t3-code: {}", error.text);
            }
            if owned.exited()? {
                self.view()?.state = State::Crashed;
                let cleanup = self.cleanup(&mut files, &mut process);
                engine.process_exited(peer)?;
                if let Err(error) = cleanup {
                    self.fail(&error);
                } else {
                    self.fail(&Fault::new("runtime_crashed","Owned T3 server exited unexpectedly; restart the plugin. No automatic server restart was attempted."));
                }
                return Ok(());
            }
            match receive.recv_timeout(Duration::from_millis(500)) {
                Ok(Input::Stop) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Ok(Input::Renew(reply)) => {
                    let result = self.renew(
                        files.as_mut().ok_or_else(|| {
                            Fault::new("manager_state", "Supervisor lost its auth state.")
                        })?,
                        contract,
                    );
                    if reply.send(result).is_err() { /* Caller timed out; status retains the outcome. */
                    }
                }
                Ok(Input::AuthBarrier(reply)) => {
                    let view = self.view()?;
                    let result = if matches!(view.state, State::Ready | State::Degraded)
                        && view.receipt_current
                        && !view.renewing
                    {
                        Ok(true)
                    } else if view.state == State::Degraded {
                        Err(Fault::held("auth_required","Credential renewal failed; the operation was not resumed or interrupted."))
                    } else {
                        Ok(false)
                    };
                    drop(view);
                    if reply.send(result).is_err() { /* Caller ended; no operation was submitted by this barrier. */
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
        }
        self.view()?.state = State::Stopping;
        let cleanup = self.cleanup(&mut files, &mut process);
        self.view()?.state = if cleanup.is_ok() {
            State::Installed
        } else {
            State::Crashed
        };
        cleanup
    }
}
