//! smart-remote-plugin: started by Minerva as a stdio plugin; serves the
//! remote on the LAN until Minerva closes stdin.
//!
//! Arguments:
//!   --data-dir <path>  paired-device store location (default: `data/` beside
//!                      the executable)
//!   --port <n>         WebSocket port (default 47821; 0 picks a free one)
//!   --no-mdns          do not advertise `_minerva-remote._tcp`

use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use smart_remote_plugin::host::HostLink;
use smart_remote_plugin::mdns::Advert;
use smart_remote_plugin::schema::Schemas;
use smart_remote_plugin::server::{Server, ServerConfig, DEFAULT_PORT};
use smart_remote_plugin::store::TokenStore;
use tokio::io::BufReader;
use tokio::sync::watch;

struct Args {
    data_dir: PathBuf,
    port: u16,
    mdns: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut data_dir = None;
    let mut port = DEFAULT_PORT;
    let mut mdns = true;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data-dir" => {
                let path = args.next().filter(|p| !p.is_empty());
                data_dir = Some(PathBuf::from(path.ok_or("--data-dir requires a path")?));
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
        Some(dir) => dir,
        None => std::env::current_exe()
            .map_err(|e| format!("cannot locate the executable for the default data dir: {e}"))?
            .parent()
            .ok_or("the executable has no parent directory")?
            .join("data"),
    };
    Ok(Args {
        data_dir,
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
    let store = Arc::new(TokenStore::open(&args.data_dir).map_err(|e| e.to_string())?);
    let config = ServerConfig::new(SocketAddr::from((Ipv4Addr::UNSPECIFIED, args.port)));
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
        Advert::start(addr.port())
            .map_err(|e| log::error!("{e}; continuing without the mDNS advert"))
            .ok()
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
