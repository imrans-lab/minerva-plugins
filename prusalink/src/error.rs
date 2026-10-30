//! Errors contain only fixed diagnostics, never HTTP bodies or vault payloads.
use std::fmt;

#[derive(Debug)]
pub enum Error {
    Invalid(&'static str),
    Config,
    Io(&'static str),
    Vault,
    MissingPassword,
    Protocol(&'static str),
    Http(u16),
    Transport { mutation: bool, connection: bool },
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(s) | Self::Io(s) | Self::Protocol(s) => f.write_str(s),
            Self::Config => f.write_str("Printer configuration is unreadable; restore the metadata file before making changes"),
            Self::Vault => f.write_str("Vault request failed; unlock Minerva's vault and check plugin permissions"),
            Self::MissingPassword => f.write_str("Set the printer password in the PrusaLink panel"),
            Self::Http(401) => f.write_str("Printer authentication failed; update the password in the panel"),
            Self::Http(507) => f.write_str("Printer storage unavailable; insert a USB stick"),
            Self::Http(409) => f.write_str("Printer refused the operation because its state changed or the file already exists"),
            Self::Http(status) => write!(f,"Printer returned HTTP {status}"),
            Self::Transport { mutation, connection } => {
                f.write_str(if *mutation {
                    "Printer request failed; its outcome is unknown. Check the printer before retrying"
                } else {
                    "Cannot reach the printer; check its host and network"
                })?;
                if cfg!(target_os = "macos") && *connection {
                    f.write_str(". If the printer answers from Terminal, allow Minerva under System Settings → Privacy & Security → Local Network.")?;
                }
                Ok(())
            },
        }
    }
}
impl std::error::Error for Error {}
pub type Result<T> = std::result::Result<T, Error>;
