//! Shared isolated catalog queries; callers supply enabled model/variant settings.
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::time::Instant;

use crate::error::{Error, Result};
use crate::slicer::{local_file, remaining, run_cli, sha256, Models, Profiles};

pub(crate) struct Catalog {
    pub directory: PathBuf,
    pub executable: PathBuf,
    pub executable_sha256: String,
    pub vendor_ini: PathBuf,
    pub vendor_sha256: String,
    pub vendor_id: String,
    pub started: Instant,
}
impl Catalog {
    pub fn prepare(
        executable: &Path,
        vendor_ini: &Path,
        vendor_id: &str,
        settings: &str,
        root: &Path,
        started: Instant,
    ) -> Result<Self> {
        if !crate::slicer::identifier(vendor_id) {
            return Err(Error::Invalid("Use a simple slicer vendor identifier"));
        }
        let executable = local_file(executable)?;
        let vendor_ini = local_file(vendor_ini)?;
        let executable_sha256 = sha256(&executable)?;
        let vendor_sha256 = sha256(&vendor_ini)?;
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
        fs::copy(
            &vendor_ini,
            directory.join("vendor").join(format!("{vendor_id}.ini")),
        )
        .map_err(|_| Error::Io("Cannot copy slicer vendor profile"))?;
        let catalog = Self {
            directory,
            executable,
            executable_sha256,
            vendor_ini,
            vendor_sha256,
            vendor_id: vendor_id.to_owned(),
            started,
        };
        catalog.unchanged()?;
        fs::write(catalog.directory.join("PrusaSlicer.ini"), settings)
            .map_err(|_| Error::Io("Cannot write isolated slicer settings"))?;
        Ok(catalog)
    }
    pub fn models(&self) -> Result<Models> {
        self.query("models", vec!["--query-printer-models".into()])
    }
    pub fn profiles(&self, printer_profile: &str) -> Result<Profiles> {
        let profiles: Profiles = self.query(
            "profiles",
            vec![
                "--printer-profile".into(),
                printer_profile.into(),
                "--query-print-filament-profiles".into(),
            ],
        )?;
        if profiles.printer_profile != printer_profile || profiles.print_profiles.is_empty() {
            return Err(Error::Protocol(
                "Slicer returned an unexpected profile catalog",
            ));
        }
        Ok(profiles)
    }
    fn query<T: serde::de::DeserializeOwned>(
        &self,
        phase: &str,
        mut args: Vec<std::ffi::OsString>,
    ) -> Result<T> {
        let output = self.directory.join(format!("{phase}.json"));
        args.extend(["--output".into(), output.clone().into_os_string()]);
        run_cli(
            &self.executable,
            &self.directory,
            phase,
            args,
            remaining(self.started)?,
            true,
        )?;
        if fs::metadata(&output)
            .map_err(|_| Error::Io("Slicer did not produce its query output"))?
            .len()
            > 4 * 1024 * 1024
        {
            return Err(Error::Protocol("Slicer query output exceeds4MiB"));
        }
        serde_json::from_reader(
            File::open(output).map_err(|_| Error::Io("Cannot read slicer query output"))?,
        )
        .map_err(|_| Error::Protocol("Invalid slicer query output"))
    }
    pub fn version(&self) -> Result<String> {
        run_cli(
            &self.executable,
            &self.directory,
            "version",
            vec!["--help".into()],
            remaining(self.started)?,
            false,
        )?;
        fs::read_to_string(self.directory.join("version.log"))
            .map_err(|_| Error::Io("Cannot read slicer version"))?
            .lines()
            .next()
            .filter(|line| line.starts_with("PrusaSlicer-") && line.len() < 256)
            .map(str::to_owned)
            .ok_or(Error::Protocol("Unrecognized PrusaSlicer version"))
    }
    pub fn unchanged(&self) -> Result<()> {
        if sha256(&self.executable)? != self.executable_sha256
            || sha256(&self.vendor_ini)? != self.vendor_sha256
            || sha256(
                &self
                    .directory
                    .join("vendor")
                    .join(format!("{}.ini", self.vendor_id)),
            )? != self.vendor_sha256
        {
            return Err(Error::Io(
                "Slicer executable or vendor profile changed during the run",
            ));
        }
        remaining(self.started)?;
        Ok(())
    }
}
