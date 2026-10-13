//! smart-remote-v2 Minerva plugin: the LAN side of the device protocol in
//! `protocol/` and the stdio link to Minerva.
//!
//! Design: Docket `smart-remote:01a12de97992`.

pub mod admission;
pub mod audio;
pub mod contract;
pub mod data_dir;
pub mod host;
pub mod mdns;
pub mod message;
pub mod schema;
pub mod server;
mod session;
pub mod store;

pub use session::{
    AUTH_MESSAGE, CLOSE_AUTH, CLOSE_GOING_AWAY, CLOSE_NORMAL, CLOSE_PROTOCOL, CLOSE_PROTO_VERSION,
    CLOSE_REPLACED, NOT_IMPLEMENTED,
};
