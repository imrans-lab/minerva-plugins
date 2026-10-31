//! Local PrusaSlicer CLI boundary. No credentials or printer network requests.
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::process::{Command, Stdio};
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{Error, Result};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SlicerConfig {
    pub executable: PathBuf,
    pub vendor_ini: PathBuf,
    pub vendor_id: String,
    pub model_id: String,
    pub variant: String,
    pub tool_count: u8,
    pub printer_profile: String,
    pub print_profile: String,
    pub material_profile: String,
}
impl SlicerConfig {
    pub fn validate(&self) -> Result<()> {
        for value in [&self.vendor_id, &self.model_id, &self.variant] {
            if value.is_empty()
                || !value
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'-')
            {
                return Err(Error::Invalid(
                    "Slicer vendor, model and variant must be simple identifiers",
                ));
            }
        }
        for value in [
            &self.printer_profile,
            &self.print_profile,
            &self.material_profile,
        ] {
            if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
                return Err(Error::Invalid(
                    "Slicer profiles must be nonempty names without control characters",
                ));
            }
        }
        if !(1..=16).contains(&self.tool_count) {
            return Err(Error::Invalid("Slicer tool count must be1–16"));
        }
        for path in [&self.executable, &self.vendor_ini] {
            if !path.is_absolute() || (cfg!(target_os = "macos") && path.starts_with("/home")) {
                return Err(Error::Invalid("Use absolute local slicer paths"));
            }
        }
        Ok(())
    }
}
pub fn local_file(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() || (cfg!(target_os = "macos") && path.starts_with("/home")) {
        return Err(Error::Invalid("Use an absolute local file path"));
    }
    let canonical =
        fs::canonicalize(path).map_err(|_| Error::Io("Cannot resolve slicer input file"))?;
    if !canonical.is_file() {
        return Err(Error::Invalid("Slicer input must be a regular file"));
    }
    Ok(canonical)
}
pub fn sha256(path: &Path) -> Result<String> {
    let mut file = File::open(path).map_err(|_| Error::Io("Cannot open slicer receipt input"))?;
    let mut digest = Sha256::new();
    let mut bytes = [0_u8; 65536];
    loop {
        let read = file
            .read(&mut bytes)
            .map_err(|_| Error::Io("Cannot hash slicer receipt input"))?;
        if read == 0 {
            break;
        }
        digest.update(&bytes[..read]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

#[derive(Deserialize)]
struct Models {
    printer_models: Vec<Model>,
}
#[derive(Deserialize)]
struct Model {
    id: String,
    vendor_id: String,
    variants: Vec<Variant>,
}
#[derive(Deserialize)]
struct Variant {
    name: serde_json::Value,
    printer_profiles: Vec<PrinterProfile>,
}
#[derive(Deserialize)]
struct PrinterProfile {
    name: String,
    extruders_cnt: u8,
    bed: Bed,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Bed {
    #[serde(rename = "type")]
    pub kind: String,
    pub width: f64,
    pub height: f64,
    pub origin: String,
}
impl Bed {
    pub fn center(&self) -> Result<String> {
        let origin: Vec<f64> = serde_json::from_str(&self.origin)
            .map_err(|_| Error::Protocol("Invalid slicer bed origin"))?;
        if self.kind != "Rectangle"
            || origin.len() != 2
            || !self.width.is_finite()
            || !self.height.is_finite()
            || self.width <= 0.0
            || self.height <= 0.0
            || origin.iter().any(|v| !v.is_finite())
        {
            return Err(Error::Protocol("Slicer requires a known rectangular bed"));
        }
        Ok(format!(
            "{},{}",
            origin[0] + self.width / 2.0,
            origin[1] + self.height / 2.0
        ))
    }
}
#[derive(Deserialize, Serialize)]
pub struct PrintProfile {
    pub name: String,
    pub filament_profiles: Vec<String>,
}
#[derive(Deserialize, Serialize)]
pub struct Profiles {
    pub printer_profile: String,
    pub print_profiles: Vec<PrintProfile>,
}

pub struct Run {
    pub directory: PathBuf,
    pub config: SlicerConfig,
    pub executable: PathBuf,
    pub executable_sha256: String,
    pub vendor_sha256: String,
    pub bed: Bed,
    pub profiles: Profiles,
    pub started: Instant,
    pub version: String,
}
impl Run {
    pub fn prepare(config: &SlicerConfig, root: &Path) -> Result<Self> {
        let started = Instant::now();
        config.validate()?;
        let mut nonce = [0_u8; 16];
        getrandom::fill(&mut nonce).map_err(|_| Error::Io("OS randomness unavailable"))?;
        fs::create_dir_all(root).map_err(|_| Error::Io("Cannot create slicer output root"))?;
        let directory = root.join(nonce.iter().map(|b| format!("{b:02x}")).collect::<String>());
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder
            .create(&directory)
            .map_err(|_| Error::Io("Cannot create private slicer run"))?;
        fs::create_dir(directory.join("vendor"))
            .map_err(|_| Error::Io("Cannot create isolated slicer vendor directory"))?;
        let executable = local_file(&config.executable)?;
        let executable_sha256 = sha256(&executable)?;
        let vendor_sha256 = sha256(&config.vendor_ini)?;
        fs::copy(
            &config.vendor_ini,
            directory
                .join("vendor")
                .join(format!("{}.ini", config.vendor_id)),
        )
        .map_err(|_| Error::Io("Cannot copy slicer vendor profile"))?;
        if sha256(
            &directory
                .join("vendor")
                .join(format!("{}.ini", config.vendor_id)),
        )? != vendor_sha256
        {
            return Err(Error::Io("Slicer vendor profile changed while copying"));
        }
        fs::write(
            directory.join("PrusaSlicer.ini"),
            format!(
                "[vendor:{}]\nmodel:{} = {}\n",
                config.vendor_id, config.model_id, config.variant
            ),
        )
        .map_err(|_| Error::Io("Cannot write isolated slicer settings"))?;
        let args = vec![
            "--query-printer-models".into(),
            "--output".into(),
            directory.join("models.json").into_os_string(),
        ];
        run_cli(
            &executable,
            &directory,
            "models",
            args,
            remaining(started)?,
            true,
        )?;
        let models: Models = read_json(&directory.join("models.json"))?;
        let matching: Vec<_> = models
            .printer_models
            .into_iter()
            .filter(|m| m.id == config.model_id && m.vendor_id == config.vendor_id)
            .flat_map(|m| m.variants)
            .filter(|v| {
                v.name
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| v.name.to_string())
                    == config.variant
            })
            .flat_map(|v| v.printer_profiles)
            .filter(|p| p.name == config.printer_profile && p.extruders_cnt == config.tool_count)
            .collect();
        if matching.len() != 1 {
            return Err(Error::Invalid("Printer model, variant, tool count and profile must match the installed vendor catalog"));
        }
        let bed = matching
            .into_iter()
            .next()
            .ok_or(Error::Protocol("Missing slicer printer profile"))?
            .bed;
        bed.center()?;
        let args = vec![
            "--printer-profile".into(),
            config.printer_profile.clone().into(),
            "--query-print-filament-profiles".into(),
            "--output".into(),
            directory.join("profiles.json").into_os_string(),
        ];
        run_cli(
            &executable,
            &directory,
            "profiles",
            args,
            remaining(started)?,
            true,
        )?;
        let profiles: Profiles = read_json(&directory.join("profiles.json"))?;
        if profiles.printer_profile != config.printer_profile || profiles.print_profiles.is_empty()
        {
            return Err(Error::Protocol(
                "Slicer returned an unexpected profile catalog",
            ));
        }
        run_cli(
            &executable,
            &directory,
            "version",
            vec!["--help".into()],
            remaining(started)?,
            false,
        )?;
        let version = fs::read_to_string(directory.join("version.log"))
            .map_err(|_| Error::Io("Cannot read slicer version"))?
            .lines()
            .next()
            .filter(|line| line.starts_with("PrusaSlicer-") && line.len() < 256)
            .ok_or(Error::Protocol("Unrecognized PrusaSlicer version"))?
            .to_owned();
        Ok(Self {
            directory,
            config: config.clone(),
            executable,
            executable_sha256,
            vendor_sha256,
            bed,
            profiles,
            started,
            version,
        })
    }
    pub fn unchanged(&self) -> Result<()> {
        if sha256(&self.executable)? != self.executable_sha256
            || sha256(&self.config.vendor_ini)? != self.vendor_sha256
        {
            return Err(Error::Io(
                "Slicer executable or vendor profile changed during the run",
            ));
        }
        Ok(())
    }
}
pub fn remaining(started: Instant) -> Result<u64> {
    Duration::from_secs(20)
        .checked_sub(started.elapsed())
        .filter(|left| !left.is_zero())
        .map(|left| left.as_secs().max(1))
        .ok_or(Error::Io("Slicer tool exceeded its 20 second total budget"))
}
fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    if fs::metadata(path)
        .map_err(|_| Error::Io("Slicer did not produce its query output"))?
        .len()
        > 4 * 1024 * 1024
    {
        return Err(Error::Protocol("Slicer query output exceeds4MiB"));
    }
    serde_json::from_reader(
        File::open(path).map_err(|_| Error::Io("Cannot read slicer query output"))?,
    )
    .map_err(|_| Error::Protocol("Invalid slicer query output"))
}

/// Bounded local child. Runs only on Unix, with an owned process group.
pub fn run_cli(
    executable: &Path,
    directory: &Path,
    phase: &str,
    args: Vec<std::ffi::OsString>,
    seconds: u64,
    query: bool,
) -> Result<()> {
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = (executable, directory, phase, args, seconds, query);
        Err(Error::Invalid(
            "Slicing requires macOS or Linux with owned process limits",
        ))
    }
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        let log_path = directory.join(format!("{phase}.log"));
        let log = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&log_path)
            .map_err(|_| Error::Io("Cannot create slicer log"))?;
        let mut command = Command::new(executable);
        command
            .arg("--datadir")
            .arg(directory)
            .arg("--threads")
            .arg("2")
            .args(args)
            .stdin(Stdio::null())
            .stdout(
                log.try_clone()
                    .map_err(|_| Error::Io("Cannot clone slicer log"))?,
            )
            .stderr(log);
        let mut child = crate::slicer_process::OwnedChild::spawn(&mut command)?;
        let start = Instant::now();
        loop {
            let exited = child.exited()?;
            let stats = Command::new("/bin/ps")
                .args(["-axo", "pgid=,rss=,time="])
                .output()
                .ok()
                .filter(|r| r.status.success())
                .and_then(|r| String::from_utf8(r.stdout).ok());
            let usage = stats.as_ref().and_then(|stats| {
                let mut memory = 0_u64;
                let mut cpu = 0.0;
                for line in stats.lines() {
                    let mut fields = line.split_whitespace();
                    if fields.next()?.parse::<u32>().ok()? != child.id() {
                        continue;
                    }
                    memory += fields.next()?.parse::<u64>().ok()?;
                    cpu += cpu_seconds(fields.next()?)?;
                }
                Some((memory, cpu))
            });
            let log_bytes = fs::metadata(&log_path).map(|m| m.len()).unwrap_or(u64::MAX);
            if start.elapsed() > Duration::from_secs(seconds)
                || usage.is_none()
                || usage.is_some_and(|(kb, cpu)| kb > 4 * 1024 * 1024 || cpu > 20.0)
                || log_bytes > 16 * 1024 * 1024
            {
                child.finish()?;
                return Err(Error::Io(
                    "Slicer time, CPU, memory, log limit or monitor failed; output is incomplete",
                ));
            }
            if exited {
                let status = child.finish()?; // Kill group before reaping, including success/error exits.
                return if status.success() || (query && status.code() == Some(1)) {
                    Ok(())
                } else {
                    Err(Error::Io("PrusaSlicer failed; inspect the private run log"))
                };
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
}
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn cpu_seconds(value: &str) -> Option<f64> {
    let (days, time) = value
        .split_once('-')
        .map(|(d, t)| Some((d.parse::<f64>().ok()?, t)))
        .unwrap_or(Some((0.0, value)))?;
    let parts: Vec<f64> = time
        .split(':')
        .map(str::parse)
        .collect::<std::result::Result<_, _>>()
        .ok()?;
    if parts.is_empty() || parts.len() > 3 || parts.iter().any(|v| !v.is_finite() || *v < 0.0) {
        return None;
    }
    Some(
        days * 86400.0
            + parts
                .into_iter()
                .fold(0.0, |total, part| total * 60.0 + part),
    )
}
