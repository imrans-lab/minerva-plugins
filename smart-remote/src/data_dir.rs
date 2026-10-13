//! Where the plugin keeps durable data (the paired-device store).
//!
//! Minerva installs a plugin's files in `<user>/plugins/<id>/` and replaces
//! that directory on every update, while `<user>/plugins/data/<id>/` survives
//! updates and rollbacks (Minerva `PluginInstallTransaction.data_directory`).
//! The executable sits at the plugin root, so the data root is found from its
//! real path. A side-loaded build that is not under a `plugins` directory
//! falls back to `data/` beside the executable.

use std::path::{Path, PathBuf};

/// Must equal `id` in manifest.json; a test keeps them in step.
pub const PLUGIN_ID: &str = "smart_remote";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DataDir {
    /// `--data-dir` was given.
    Override(PathBuf),
    /// Minerva's per-plugin data root, which survives updates.
    Minerva(PathBuf),
    /// Not installed by Minerva; the store lives beside the executable and an
    /// update that replaces that directory loses it.
    BesideExecutable(PathBuf),
}

impl DataDir {
    pub fn path(&self) -> &Path {
        match self {
            Self::Override(p) | Self::Minerva(p) | Self::BesideExecutable(p) => p,
        }
    }
}

/// `exe` should be the executable's canonical path.
pub fn resolve(override_dir: Option<PathBuf>, exe: &Path) -> DataDir {
    if let Some(dir) = override_dir {
        return DataDir::Override(dir);
    }
    let exe_dir = exe.parent().unwrap_or_else(|| Path::new("."));
    match exe_dir.parent() {
        Some(plugins) if plugins.file_name().is_some_and(|n| n == "plugins") => {
            DataDir::Minerva(plugins.join("data").join(PLUGIN_ID))
        }
        _ => DataDir::BesideExecutable(exe_dir.join("data")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installed_layout_uses_the_minerva_data_root() {
        let exe = Path::new("/u/Minerva/plugins/smart_remote/smart-remote-plugin");
        assert_eq!(
            resolve(None, exe),
            DataDir::Minerva(PathBuf::from("/u/Minerva/plugins/data/smart_remote"))
        );
    }

    #[test]
    fn side_loaded_build_falls_back_beside_the_executable() {
        let exe = Path::new("/src/minerva-plugin/target/release/smart-remote-plugin");
        assert_eq!(
            resolve(None, exe),
            DataDir::BesideExecutable(PathBuf::from("/src/minerva-plugin/target/release/data"))
        );
        assert_eq!(
            resolve(None, Path::new("/smart-remote-plugin")),
            DataDir::BesideExecutable(PathBuf::from("/data"))
        );
    }

    #[test]
    fn override_wins() {
        let exe = Path::new("/u/Minerva/plugins/smart_remote/smart-remote-plugin");
        assert_eq!(
            resolve(Some(PathBuf::from("/tmp/x")), exe),
            DataDir::Override(PathBuf::from("/tmp/x"))
        );
    }

    #[test]
    fn plugin_id_matches_the_manifest() {
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../manifest.json")).unwrap();
        assert_eq!(manifest["id"], PLUGIN_ID);
    }
}
