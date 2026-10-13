//! smart-remote-plugin: started by Minerva as a stdio plugin; serves the
//! remote on the LAN until Minerva closes stdin.
//!
//! Arguments:
//!   --data-dir <path>  paired-device store location (default: Minerva's
//!                      per-plugin data root, see `data_dir`)
//!   --bind <ip>        listen address (default 0.0.0.0, every IPv4 interface)
//!   --port <n>         WebSocket port (default 47821; 0 picks a free one)
//!   --no-mdns          do not advertise `_minerva-remote._tcp`

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use smart_remote_plugin::data_dir::{self, DataDir};
use smart_remote_plugin::host::HostLink;
use smart_remote_plugin::mdns::Advert;
use smart_remote_plugin::schema::Schemas;
use smart_remote_plugin::server::{Server, ServerConfig, DEFAULT_PORT};
use smart_remote_plugin::store::TokenStore;
use tokio::io::BufReader;
use tokio::sync::watch;

struct Args {
    data_dir: DataDir,
    bind: IpAddr,
    port: u16,
    mdns: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut data_dir = None;
    let mut bind = IpAddr::V4(Ipv4Addr::UNSPECIFIED);
    let mut port = DEFAULT_PORT;
    let mut mdns = true;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data-dir" => {
                let path = args.next().filter(|p| !p.is_empty());
                data_dir = Some(PathBuf::from(path.ok_or("--data-dir requires a path")?));
            }
            "--bind" => {
                let value = args.next().ok_or("--bind requires an IP address")?;
                bind = value
                    .parse()
                    .map_err(|_| format!("--bind: {value:?} is not an IP address"))?;
            }
            "--port" => {
                let value = args.next().ok_or("--port requires a number")?;
                port = value
                    .parse()
                    .map_err(|_| format!("--port: {value:?} is not a port number"))?;
            }
            "--no-mdns" => mdns = false,
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    let data_dir = match data_dir {
        Some(dir) => DataDir::Override(dir),
        None => {
            let exe = std::env::current_exe()
                .and_then(std::fs::canonicalize)
                .map_err(|e| {
                    format!("cannot locate the executable for the default data dir: {e}")
                })?;
            data_dir::resolve(None, &exe)
        }
    };
    Ok(Args {
        data_dir,
        bind,
        port,
        mdns,
    })
}

#[tokio::main]
async fn main() -> ExitCode {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .target(env_logger::Target::Stderr)
        .init();
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            log::error!("{message}");
            ExitCode::from(2)
        }
    }
}

async fn run() -> Result<(), String> {
    let args = parse_args()?;
    let schemas = Arc::new(Schemas::load().map_err(|e| e.to_string())?);
    if let DataDir::BesideExecutable(dir) = &args.data_dir {
        log::warn!(
            "not installed under a Minerva plugins directory; pairings are kept in {} and are lost if this directory is replaced",
            dir.display()
        );
    }
    let store = Arc::new(TokenStore::open(args.data_dir.path()).map_err(|e| e.to_string())?);
    let config = ServerConfig::new(SocketAddr::from((args.bind, args.port)));
    let server = Server::bind(config, store, schemas)
        .await
        .map_err(|e| e.to_string())?;
    let addr = server.local_addr().map_err(|e| e.to_string())?;
    log::info!(
        "listening on ws://{addr}{}",
        smart_remote_plugin::server::WS_PATH
    );

    // The device tries its provisioned address first, so a LAN without
    // working multicast degrades to that rather than stopping the plugin.
    let advert = if args.mdns {
        match Advert::start(addr) {
            Ok(Some(advert)) => Some(advert),
            Ok(None) => {
                log::info!("loopback listener; no mDNS advert");
                None
            }
            Err(e) => {
                log::error!("{e}; continuing without the mDNS advert");
                None
            }
        }
    } else {
        None
    };

    let (link, host_tasks) =
        HostLink::start(BufReader::new(tokio::io::stdin()), tokio::io::stdout());
    let (stop, stopped) = watch::channel(false);
    let serving = tokio::spawn(server.run(stopped));

    if let Err(e) = host_tasks.reader.await {
        log::error!("host reader task failed: {e}");
    }
    log::info!("shutting down");
    let _ = stop.send(true);
    if let Err(e) = serving.await {
        log::error!("server task failed: {e}");
    }
    if let Some(advert) = advert {
        tokio::task::spawn_blocking(move || advert.stop())
            .await
            .map_err(|e| e.to_string())?;
    }
    drop(link);
    if let Err(e) = host_tasks.writer.await {
        log::error!("host writer task failed: {e}");
    }
    Ok(())
}
