//! Read-only prerequisites. This phase never launches a T3 server or agent.

use semver::Version;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::contract::Contract;

#[derive(Clone)]
pub struct Settings {
    values: BTreeMap<String, String>,
    pub workspace: PathBuf,
    pub private: PathBuf,
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
        let workspace = if saved.is_absolute()
            && saved.is_file()
            && saved
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("minproj"))
        {
            saved
                .parent()
                .filter(|p| p.is_dir())
                .map(Path::to_owned)
                .unwrap_or_default()
        } else {
            PathBuf::new()
        };
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
        if raw.contains("{workspace}") && self.workspace.as_os_str().is_empty() {
            return Err(format!("Setting {key} uses {{workspace}}, but the Minerva project is unsaved. Save a .minproj or choose an explicit private path; no root-relative fallback is used."));
        }
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
pub fn stop_group(child: &mut std::process::Child) -> Result<(), String> {
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
pub fn exited(child: &std::process::Child) -> Result<bool, String> {
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
    command_bounded(path, arguments, codex_home, Duration::from_secs(5))
}

pub fn command_bounded(
    path: &str,
    arguments: &[&str],
    codex_home: Option<&str>,
    timeout: Duration,
) -> Result<String, String> {
    if !cfg!(any(target_os = "linux", target_os = "macos")) {
        return Err("T3 Code crawl does not support this operating system.".into());
    }
    let mut command = Command::new(path);
    command
        .args(arguments)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
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
    let captured = (|| -> Result<Vec<u8>, String> {
        let mut output = child.stdout.take().ok_or("Probe has no output pipe")?;
        nonblocking(&output)?;
        let mut bytes = Vec::new();
        let deadline = Instant::now() + timeout;
        loop {
            drain(&mut output, &mut bytes, 8 * 1024 * 1024)?;
            if exited(&child)? {
                break;
            }
            if Instant::now() >= deadline {
                return Err(format!("{path} prerequisite probe timed out."));
            }
            std::thread::sleep(Duration::from_millis(15));
        }
        drain(&mut output, &mut bytes, 8 * 1024 * 1024)?;
        Ok(bytes)
    })();
    // Every post-spawn error goes through this cleanup while the child PID is
    // still reserved. No pipe/configuration failure can leak the probe.
    let cleanup = stop_group(&mut child);
    let status = child.wait().map_err(|e| e.to_string());
    cleanup?;
    let status = status?;
    let bytes = captured?;
    if !status.success() {
        return Err(format!(
            "{path} {} did not succeed ({}). Check its installation or the existing Codex login.",
            arguments.join(" "),
            status
        ));
    }
    String::from_utf8(bytes).map_err(|_| format!("{path} returned non-UTF-8 output"))
}

pub fn nonblocking(pipe: &impl std::os::fd::AsRawFd) -> Result<(), String> {
    let fd = pipe.as_raw_fd();
    // SAFETY: fd is borrowed from a live owned pipe; fcntl only changes its
    // status flags. No pointer is passed and ownership remains with the pipe.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    // SAFETY: same live borrowed fd and integer-only fcntl operation as above.
    let changed = if flags < 0 {
        -1
    } else {
        unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) }
    };
    if changed < 0 {
        return Err("Cannot make the owned output pipe nonblocking".into());
    }
    Ok(())
}

pub fn drain(reader: &mut impl Read, bytes: &mut Vec<u8>, maximum: usize) -> Result<(), String> {
    let mut buffer = [0u8; 8192];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return Ok(()),
            Ok(size) if bytes.len().saturating_add(size) <= maximum => {
                bytes.extend_from_slice(&buffer[..size])
            }
            Ok(_) => return Err("Owned command output exceeded its bound".into()),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return Err("Cannot read owned command output".into()),
        }
    }
}

fn version(path: &str) -> Result<Version, String> {
    let output = command(path, &["--version"], None)?;
    output
        .split_whitespace()
        .find_map(|part| Version::parse(part.trim_start_matches('v')).ok())
        .ok_or_else(|| format!("Cannot read a version from {path} --version."))
}

pub fn resolve_executable(path: &str) -> Result<PathBuf, String> {
    let requested = Path::new(path);
    let located = if requested.is_absolute() || requested.components().count() > 1 {
        requested.to_owned()
    } else {
        std::env::var_os("PATH").into_iter().flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
            .map(|directory| directory.join(requested)).find(|candidate| candidate.is_file())
            .ok_or_else(||format!("Executable {path} is not installed on PATH; choose its existing executable in T3 Code preferences."))?
    };
    located.canonicalize().map_err(|_| {
        format!(
            "Existing executable is unavailable: {}. No installer was run.",
            located.display()
        )
    })
}

fn installed_t3(path: &str) -> Result<(PathBuf, Version), String> {
    let executable = resolve_executable(path)?;
    let mut file = std::fs::File::open(&executable)
        .map_err(|e| format!("Cannot inspect existing T3 executable: {e}"))?;
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic)
        .map_err(|_| "Existing T3 executable is incomplete; no installer was run")?;
    let native = if cfg!(target_os = "linux") {
        magic == *b"\x7fELF"
    } else {
        matches!(
            magic,
            [0xcf, 0xfa, 0xed, 0xfe]
                | [0xfe, 0xed, 0xfa, 0xcf]
                | [0xca, 0xfe, 0xba, 0xbe]
                | [0xca, 0xfe, 0xba, 0xbf]
        )
    };
    if !native {
        return Err("T3 points to a launcher or script. Phase A never executes it: npm launchers can install on --version. Set the already-installed native runtime executable from a completed official CLI installation (runtime/versions/<version>/t3).".into());
    }
    let parent = executable
        .parent()
        .ok_or("Existing T3 executable has no installation directory")?;
    let marker = std::fs::read_to_string(parent.join(".install-complete"))
        .map_err(|_| "Existing T3 runtime has no readable .install-complete marker. Choose a completed official CLI installation; no installer was run.")?;
    let version = Version::parse(marker.trim())
        .map_err(|_| "Existing T3 installation marker has an invalid version")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if file
            .metadata()
            .map_err(|e| e.to_string())?
            .permissions()
            .mode()
            & 0o111
            == 0
        {
            return Err("Existing native T3 runtime is not executable. Ask the owner to repair the installation.".into());
        }
    }
    Ok((executable, version))
}

pub fn inspect(settings: &Settings, contract: &Contract) -> Result<Value, String> {
    let mut errors = Vec::new();
    if settings.workspace.as_os_str().is_empty() {
        errors.push("Save the Minerva project as a .minproj before starting a new T3 chat.".into());
    }
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
    let mut t3_executable = None;
    match installed_t3(&t3) {
        Ok((executable, found)) => {
            if format!("v{found}") != contract.t3_tag {
                errors.push(format!("Installed T3 marker is {found}; this plugin requires {}. Choose the supported completed installation.", contract.t3_tag));
            }
            versions.insert("t3", found.to_string());
            t3_executable = Some(executable);
        }
        Err(error) => errors.push(error),
    }
    for (name, path) in [("node", &node), ("codex", &codex)] {
        match version(path) {
            Ok(found) => {
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
        "t3_executable": t3_executable, "t3_version_source": "official install-complete marker; T3 not executed",
        "prerequisites_ok": errors.is_empty(), "errors": errors,
        "compatibility": contract.compatibility(json!(versions)),
        "runtime_message": "Phase B is pending the owner's T3 installation decision. No T3 server or agent has been started.",
        "drift_probe": "not-run: no owned T3 endpoint exists in Phase A"
    }))
}
