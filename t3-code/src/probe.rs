//! Read-only prerequisites. This phase never launches a T3 server or agent.

use semver::Version;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::contract::Contract;

pub struct Settings {
    values: BTreeMap<String, String>,
    pub workspace: PathBuf,
    private: PathBuf,
}

impl Settings {
    pub fn from_host(fields: &Value, project: &Value) -> Result<Self, String> {
        let mut values = BTreeMap::new();
        for field in fields["fields"]
            .as_array()
            .ok_or("host.settings.list returned no fields")?
        {
            let key = field["key"].as_str().ok_or("Settings field has no key")?;
            let value = field["value"]
                .as_str()
                .ok_or_else(|| format!("Setting {key} must be a string"))?;
            values.insert(key.to_owned(), value.to_owned());
        }
        let project_path = project["path"].as_str().unwrap_or("");
        let saved = Path::new(project_path);
        if !saved.is_absolute()
            || !saved.is_file()
            || !saved
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("minproj"))
        {
            return Err("Save the Minerva project as a .minproj before using T3 Code.".into());
        }
        let workspace = saved
            .parent()
            .ok_or("Saved project has no folder")?
            .to_owned();
        if !workspace.is_dir() {
            return Err("The saved Minerva project's folder is unavailable.".into());
        }
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or("HOME is unavailable")?;
        let private = if cfg!(target_os = "macos") {
            home.join("Library/Application Support/Minerva/plugins/t3_code")
        } else {
            std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".local/share"))
                .join("Minerva/plugins/t3_code")
        };
        Ok(Self {
            values,
            workspace,
            private,
        })
    }

    pub fn get(&self, key: &str) -> Result<String, String> {
        let raw = self
            .values
            .get(key)
            .ok_or_else(|| format!("Missing plugin setting {key}"))?;
        let endpoint = self
            .values
            .get("minerva_mcp_endpoint")
            .map(String::as_str)
            .unwrap_or("");
        let value = raw
            .replace("{private}", &self.private.to_string_lossy())
            .replace("{workspace}", &self.workspace.to_string_lossy())
            .replace("{minerva_mcp}", endpoint);
        if value.contains("{private}")
            || value.contains("{workspace}")
            || value.contains("{minerva_mcp}")
        {
            return Err(format!("Setting {key} has an unresolved placeholder; supply its value in T3 Code preferences."));
        }
        if let Some(suffix) = value.strip_prefix("~/") {
            let home = std::env::var_os("HOME").ok_or("HOME is unavailable")?;
            return Ok(PathBuf::from(home)
                .join(suffix)
                .to_string_lossy()
                .into_owned());
        }
        Ok(value)
    }
}

#[cfg(unix)]
fn stop_group(child: &mut std::process::Child) -> Result<(), String> {
    let group = i32::try_from(child.id()).map_err(|_| "Probe process id is invalid")?;
    // SAFETY: the caller created this process_group(0) child and has not
    // reaped it (waitid uses WNOWAIT), so its reserved pid cannot be reused.
    let result = unsafe { libc::kill(-group, libc::SIGKILL) };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::ESRCH) {
            return Err(format!("Cannot stop owned prerequisite probe: {error}"));
        }
    }
    Ok(())
}

#[cfg(unix)]
fn exited(child: &std::process::Child) -> Result<bool, String> {
    let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
    // SAFETY: info points to writable siginfo_t storage and this is our own
    // child's positive pid. WNOWAIT retains it until group cleanup and wait.
    let result = unsafe {
        libc::waitid(
            libc::P_PID,
            child.id(),
            info.as_mut_ptr(),
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        )
    };
    if result != 0 {
        return Err(format!(
            "Cannot inspect prerequisite probe: {}",
            std::io::Error::last_os_error()
        ));
    }
    // SAFETY: the storage was zeroed and successful waitid initialized its
    // result; si_pid is zero when WNOHANG has no exit to report.
    let info = unsafe { info.assume_init() };
    // SAFETY: si_pid reads the process-status member populated by waitid.
    Ok(unsafe { info.si_pid() } != 0)
}

pub fn command(path: &str, arguments: &[&str], codex_home: Option<&str>) -> Result<String, String> {
    if !cfg!(any(target_os = "linux", target_os = "macos")) {
        return Err("T3 Code crawl does not support this operating system.".into());
    }
    let mut command = Command::new(path);
    command
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(home) = codex_home {
        command.env("CODEX_HOME", home);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.spawn().map_err(|e| {
        format!("Cannot run {path}: {e}. Set its executable path in T3 Code preferences.")
    })?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        #[cfg(unix)]
        let finished = exited(&child)?;
        #[cfg(not(unix))]
        let finished = false;
        match finished {
            true => break,
            false if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            false => {
                #[cfg(unix)]
                stop_group(&mut child)?;
                child.wait().map_err(|e| e.to_string())?;
                return Err(format!(
                    "{path} prerequisite probe timed out after 5 seconds."
                ));
            }
        }
    }
    #[cfg(unix)]
    stop_group(&mut child)?;
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!(
            "{path} {} did not succeed ({}). Check its installation or the existing Codex login.",
            arguments.join(" "),
            output.status
        ));
    }
    String::from_utf8(output.stdout).map_err(|_| format!("{path} returned non-UTF-8 output"))
}

fn version(path: &str) -> Result<Version, String> {
    let output = command(path, &["--version"], None)?;
    output
        .split_whitespace()
        .find_map(|part| Version::parse(part.trim_start_matches('v')).ok())
        .ok_or_else(|| format!("Cannot read a version from {path} --version."))
}

pub fn inspect(settings: &Settings, contract: &Contract) -> Result<Value, String> {
    let mut errors = Vec::new();
    if !(cfg!(target_os = "linux") && cfg!(target_arch = "x86_64")
        || cfg!(target_os = "macos") && cfg!(target_arch = "aarch64"))
    {
        return Err(
            "T3 Code crawl supports Linux x86_64 and macOS arm64; Windows is unsupported.".into(),
        );
    }
    let t3 = settings.get("t3_binary")?;
    let node = settings.get("node_binary")?;
    let codex = settings.get("codex_binary")?;
    let codex_home = settings.get("codex_home")?;
    let base_dir = settings.get("t3_base_dir")?;
    let token_file = settings.get("t3_token_file")?;
    if !Path::new(&base_dir).is_absolute()
        || !Path::new(&token_file).is_absolute()
        || !Path::new(&codex_home).is_absolute()
    {
        return Err("T3 base, bearer-file and Codex-home paths must be absolute after placeholder expansion.".into());
    }
    if settings.get("minerva_mcp_endpoint")?.is_empty() {
        errors.push("Set the authorized Minerva MCP endpoint in T3 Code preferences before enabling native Minerva tools.".into());
    }
    let mut versions = BTreeMap::new();
    for (name, path) in [("t3", &t3), ("node", &node), ("codex", &codex)] {
        match version(path) {
            Ok(found) => {
                if name == "t3" && format!("v{found}") != contract.t3_tag {
                    errors.push(format!("Installed T3 is {found}; this plugin requires {}. Choose the supported existing install.", contract.t3_tag));
                }
                if name == "node"
                    && (!found.pre.is_empty()
                        || !((found.major == 22 && found.minor >= 16)
                            || (found.major == 23 && found.minor >= 11)
                            || found.major > 24
                            || (found.major == 24 && found.minor >= 10)))
                {
                    errors.push(format!("Node {found} is below T3's supported engine {}. Ask the owner to choose an appropriate Node installation.", contract.node_engine));
                }
                versions.insert(name, found.to_string());
            }
            Err(error) => errors.push(error),
        }
    }
    if let Err(error) = command(&codex, &["login", "status"], Some(&codex_home)) {
        errors.push(error);
    }
    Ok(json!({
        "state": "not-started", "ready": false, "phase": "A",
        "thread_id": "", "run_id": "", "provider": "codex", "t3_tag": contract.t3_tag,
        "endpoint": "", "base_dir": base_dir, "codex_home": codex_home,
        "workspace": settings.workspace, "t3_token_file": token_file,
        "prerequisites_ok": errors.is_empty(), "errors": errors,
        "compatibility": contract.compatibility(json!(versions)),
        "runtime_message": "Phase B is pending the owner's T3 installation decision. No T3 server or agent has been started.",
        "drift_probe": "not-run: no owned T3 endpoint exists in Phase A"
    }))
}
