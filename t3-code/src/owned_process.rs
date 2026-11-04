//! Owned runtime process boundary. A reserved, unreaped child protects its
//! process-group identity. Detached descendants use birth-checked PID sweeps;
//! only a systemd scope can enforce cleanup across arbitrary double-forks.

use crate::{
    fault::{Fault, Result},
    probe,
};
use std::collections::{BTreeMap, BTreeSet};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

fn stop_unit(unit: &str) -> Result<()> {
    let inspect = || {
        probe::command_bounded(
            "systemctl",
            &["--user", "show", unit, "--property=LoadState,ActiveState"],
            None,
            Duration::from_millis(200),
        )
    };
    let gone = |text: &str| {
        text.lines()
            .any(|line| matches!(line, "LoadState=not-found" | "ActiveState=inactive"))
    };
    if inspect().is_ok_and(|text| gone(&text)) {
        return Ok(());
    }
    if probe::command_bounded(
        "systemctl",
        &["--user", "stop", unit],
        None,
        Duration::from_millis(2500),
    )
    .is_ok()
        || inspect().is_ok_and(|text| gone(&text))
    {
        return Ok(());
    }
    Err(Fault::new(
        "cleanup_failed",
        "The exact owned systemd scope did not confirm stop.",
    ))
}

pub fn retire_scope(epoch: &str) -> Result<()> {
    if epoch.len() != 48 || !epoch.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(Fault::held(
            "stale_runtime",
            "Saved epoch has an unsupported shape; no unit was signalled.",
        ));
    }
    stop_unit(&format!("minerva-t3-code-{epoch}.scope"))
}

#[derive(Clone, PartialEq)]
struct Process {
    parent: u32,
    group: u32,
    birth: String,
}

fn snapshot() -> Result<BTreeMap<u32, Process>> {
    let text = probe::command_bounded(
        "ps",
        &["-axo", "pid=,ppid=,pgid=,lstart="],
        None,
        Duration::from_millis(200),
    )
    .map_err(|_| {
        Fault::held(
            "process_inventory",
            "Cannot read the OS process inventory for owned-child cleanup.",
        )
    })?;
    let mut processes = BTreeMap::new();
    for line in text.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() != 8 {
            return Err(Fault::held(
                "process_inventory",
                "OS process inventory has an unsupported shape.",
            ));
        }
        let number = |index: usize| {
            fields[index].parse::<u32>().map_err(|_| {
                Fault::held(
                    "process_inventory",
                    "OS process inventory contains an invalid PID.",
                )
            })
        };
        processes.insert(
            number(0)?,
            Process {
                parent: number(1)?,
                group: number(2)?,
                birth: fields[3..].join(" "),
            },
        );
    }
    Ok(processes)
}

pub struct OwnedProcess {
    pub child: Child,
    unit: Option<String>,
    tracked: BTreeMap<u32, Process>,
    reaped: bool,
    grace: Duration,
}

pub struct Launch<'a> {
    pub program: &'a str,
    pub args: &'a [String],
    pub epoch: &'a str,
    pub environment: &'a [(String, Option<String>)],
    pub directory: &'a std::path::Path,
    pub scope: bool,
}

impl Launch<'_> {
    pub fn spawn(self, (input, output, error): (Stdio, Stdio, Stdio)) -> Result<OwnedProcess> {
        let use_scope = self.scope
            && cfg!(target_os = "linux")
            && std::env::var_os("XDG_RUNTIME_DIR").is_some_and(|v| !v.is_empty())
            && probe::command_bounded(
                "systemctl",
                &["--user", "show-environment"],
                None,
                Duration::from_millis(400),
            )
            .is_ok()
            && probe::command_bounded(
                "systemd-run",
                &["--version"],
                None,
                Duration::from_millis(400),
            )
            .is_ok();
        let unit = use_scope.then(|| format!("minerva-t3-code-{}.scope", self.epoch));
        let mut command = if let Some(unit) = &unit {
            let mut command = Command::new("systemd-run");
            command
                .args([
                    "--user",
                    "--scope",
                    "--quiet",
                    "--collect",
                    "--unit",
                    unit,
                    "--property=TimeoutStopSec=2s",
                    "--",
                    "/usr/bin/env",
                    "XDG_RUNTIME_DIR=",
                ])
                .arg(self.program);
            command
        } else {
            let mut command = Command::new(self.program);
            command.env("XDG_RUNTIME_DIR", "");
            command
        };
        for (key, value) in self.environment {
            if let Some(value) = value {
                command.env(key, value);
            } else {
                command.env_remove(key);
            }
        }
        use std::os::unix::process::CommandExt;
        // SAFETY: umask is an async-signal-safe, integer-only syscall in the
        // forked child. The plugin's multithreaded parent umask is untouched.
        unsafe {
            command.pre_exec(|| {
                libc::umask(0o077);
                Ok(())
            });
        }
        #[cfg(target_os = "linux")]
        {
            let parent = std::process::id();
            // SAFETY: pre_exec uses only Linux syscalls, no allocation/locks.
            // Parent death mitigates direct-child survival; it cannot enforce
            // whole-tree cleanup after plugin SIGKILL.
            unsafe {
                command.pre_exec(move || {
                    if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    if libc::getppid() != parent as i32 {
                        return Err(std::io::Error::from_raw_os_error(libc::ECHILD));
                    }
                    Ok(())
                });
            }
        }
        let child = command
            .args(self.args)
            .current_dir(self.directory)
            .stdin(input)
            .stdout(output)
            .stderr(error)
            .process_group(0)
            .spawn()?;
        let mut owned = OwnedProcess {
            child,
            unit,
            tracked: BTreeMap::new(),
            reaped: false,
            grace: if self.scope {
                Duration::from_secs(2)
            } else {
                Duration::from_millis(200)
            },
        };
        if let Err(error) = owned.track() {
            eprintln!("t3-code: {}", error.text);
        }
        Ok(owned)
    }

    /// Capture a short public CLI response only in memory. stderr is discarded
    /// because issuer failures may include secrets. All output has a hard cap.
    pub fn capture(
        self,
        maximum: usize,
        timeout: Duration,
        cancel: Option<&AtomicBool>,
    ) -> Result<String> {
        self.capture_inner(maximum, timeout, cancel, false)
    }

    /// Check the fixed public project-add argv before enabling diagnostics:
    /// the plugin's bearer/auth command cannot enter this path. Upstream's own
    /// internal CLI-token redaction is unverified; output remains bounded.
    /// Issuer/revoke keep using capture(), with failure output hidden.
    pub fn capture_project_registration(
        self,
        maximum: usize,
        timeout: Duration,
        cancel: Option<&AtomicBool>,
    ) -> Result<String> {
        if self.args.len() != 5
            || self.args[0] != "project"
            || self.args[1] != "add"
            || self.args[2] != "--base-dir"
            || std::path::Path::new(&self.args[3]) != self.directory
            || !std::path::Path::new(&self.args[4]).is_absolute()
        {
            return Err(Fault::held(
                "registration_command",
                "Only the owned public project-add command may expose CLI diagnostics.",
            ));
        }
        self.capture_inner(maximum, timeout, cancel, true)
    }

    fn capture_inner(
        self,
        maximum: usize,
        timeout: Duration,
        cancel: Option<&AtomicBool>,
        diagnostics: bool,
    ) -> Result<String> {
        let mut process = self.spawn((
            Stdio::null(),
            Stdio::piped(),
            if diagnostics {
                Stdio::piped()
            } else {
                Stdio::null()
            },
        ))?;
        let mut output = process
            .child
            .stdout
            .take()
            .ok_or_else(|| Fault::new("process_output", "Owned command has no output pipe."))?;
        probe::nonblocking(&output)
            .map_err(|_| Fault::new("process_output", "Cannot observe owned command output."))?;
        let mut errors = process.child.stderr.take();
        if let Some(errors) = &errors {
            probe::nonblocking(errors).map_err(|_| {
                Fault::new("process_output", "Cannot observe public CLI diagnostics.")
            })?;
        }
        let mut error_bytes = Vec::new();
        let mut bytes = Vec::new();
        let deadline = Instant::now() + timeout;
        loop {
            if cancel.is_some_and(|flag| flag.load(Ordering::Acquire)) {
                return Err(Fault::held(
                    "runtime_stopping",
                    "Plugin unload interrupted the owned public CLI command.",
                ));
            }
            probe::drain(&mut output, &mut bytes, maximum).map_err(|_| {
                Fault::new(
                    "process_output",
                    "Owned command exceeded its output bound or failed to return UTF-8.",
                )
            })?;
            if let Some(errors) = &mut errors {
                probe::drain(errors, &mut error_bytes, maximum).map_err(|_| {
                    Fault::new(
                        "process_output",
                        "Public CLI diagnostics exceeded their bound.",
                    )
                })?;
            }
            if bytes.len().saturating_add(error_bytes.len()) > maximum {
                return Err(Fault::new(
                    "process_output",
                    "Public CLI output exceeded its combined bound.",
                ));
            }
            if process.exited()? {
                break;
            }
            if Instant::now() >= deadline {
                return Err(Fault::new(
                    "process_timeout",
                    "Owned public CLI command exceeded its time bound.",
                ));
            }
            std::thread::sleep(Duration::from_millis(30));
        }
        probe::drain(&mut output, &mut bytes, maximum)
            .map_err(|_| Fault::new("process_output", "Owned command output exceeds its bound."))?;
        if let Some(errors) = &mut errors {
            probe::drain(errors, &mut error_bytes, maximum).map_err(|_| {
                Fault::new(
                    "process_output",
                    "Public CLI diagnostics exceeded their bound.",
                )
            })?;
        }
        if bytes.len().saturating_add(error_bytes.len()) > maximum {
            return Err(Fault::new(
                "process_output",
                "Public CLI output exceeded its combined bound.",
            ));
        }
        let status = process.stop()?;
        if !status.success() && diagnostics {
            return Err(Fault::held(
                "project_registration_failed",
                format!(
                    "T3 project registration failed ({status}):\n{}\n{}",
                    String::from_utf8_lossy(&bytes),
                    String::from_utf8_lossy(&error_bytes)
                ),
            ));
        }
        if !status.success() {
            return Err(Fault::new("process_failed",format!("Owned public CLI command failed ({status}); output is kept out of diagnostics.")));
        }
        String::from_utf8(bytes)
            .map_err(|_| Fault::new("process_output", "Owned command returned non-UTF-8 output."))
    }
}

impl OwnedProcess {
    pub fn mechanism(&self) -> &'static str {
        if self.unit.is_some() {
            "systemd-user-scope"
        } else {
            "process-group-and-tracked-pids-best-effort"
        }
    }

    pub fn exited(&self) -> Result<bool> {
        probe::exited(&self.child).map_err(|_| {
            Fault::new(
                "process_observation",
                "Cannot observe the owned runtime process.",
            )
        })
    }

    pub fn track(&mut self) -> Result<()> {
        let current = snapshot()?;
        self.tracked
            .retain(|pid, process| current.get(pid).is_some_and(|p| p.birth == process.birth));
        let mut parents: BTreeSet<u32> = self.tracked.keys().copied().collect();
        parents.insert(self.child.id());
        loop {
            let before = parents.len();
            for (pid, process) in &current {
                if *pid != self.child.id() && parents.contains(&process.parent) {
                    self.tracked.insert(*pid, process.clone());
                    parents.insert(*pid);
                }
            }
            if before == parents.len() {
                break;
            }
        }
        Ok(())
    }

    fn sweep(&mut self, signal: i32) -> Result<()> {
        self.track()?;
        let current = snapshot()?;
        for (pid, process) in &self.tracked {
            // Birth checks reduce PID-reuse exposure; this is explicitly a
            // best-effort fallback, never advertised as cgroup containment.
            if current.get(pid).is_some_and(|p| p.birth == process.birth) {
                let pid = i32::try_from(*pid)
                    .map_err(|_| Fault::new("invalid_pid", "Tracked child PID is invalid."))?;
                // SAFETY: positive PID came from the descendant inventory and
                // its observed birth identity still matches. No name matching.
                let result = unsafe { libc::kill(pid, signal) };
                if result != 0
                    && std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
                {
                    return Err(Fault::new(
                        "cleanup_failed",
                        "Cannot signal a tracked owned descendant.",
                    ));
                }
            }
        }
        Ok(())
    }

    pub fn stop(&mut self) -> Result<ExitStatus> {
        if self.reaped {
            return Err(Fault::new(
                "process_reaped",
                "Owned runtime was already reaped.",
            ));
        }
        let mut failure = None;
        if let Some(unit) = &self.unit {
            if stop_unit(unit).is_err() {
                failure = Some(Fault::new(
                    "cleanup_failed",
                    "Owned systemd scope did not confirm stop; tracked cleanup was attempted.",
                ));
            }
        }
        if let Err(error) = self.sweep(libc::SIGTERM) {
            failure = Some(error);
        }
        let group = i32::try_from(self.child.id())
            .map_err(|_| Fault::new("invalid_pid", "Owned process group is invalid."))?;
        // SAFETY: our unreaped child reserves this group leader's PID. Only
        // members of the group created for this child receive the signal.
        unsafe {
            libc::kill(-group, libc::SIGTERM);
        }
        let deadline = Instant::now() + self.grace;
        while !self.exited()? && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(25));
        }
        if let Err(error) = self.sweep(libc::SIGKILL) {
            failure = Some(error);
        }
        probe::stop_group(&mut self.child)
            .map_err(|_| Fault::new("cleanup_failed", "Cannot kill the owned process group."))?;
        let status = self.child.wait()?;
        self.reaped = true;
        if let Some(error) = failure {
            return Err(error);
        }
        Ok(status)
    }
}

impl Drop for OwnedProcess {
    fn drop(&mut self) {
        if !self.reaped {
            if let Err(error) = self.stop() {
                eprintln!("t3-code: {}", error.text);
            }
        }
    }
}
