# smart-remote Minerva plugin

Rust Minerva plugin that bridges the remote to Minerva over the local network: WebSocket server, paired-device sessions, PTT and chat targeting. Audio endpoint integration and secured BLE provisioning are tracked separately in the campaign.

Migrated with scoped history from the sandbox; see `SOURCE_PROVENANCE.md`. The authoritative protocol is `protocol/` in this repository. The sandbox copy is retained during migration; check it with `scripts/check-protocol-sync.sh /path/to/ccsandbox/smart-remote-v2/protocol`.

Design: Docket `smart-remote:01a12de97992`. Minerva core prerequisites: `minerva:01a12de939dd`.

## Build and test

```sh
cargo build --release --locked
cargo fmt --check
cargo clippy --all-targets
cargo test
```

The message schemas are compiled in from `protocol/schema/`; the tests replay `protocol/examples/` against a running plugin over real sockets. The live mDNS test needs multicast and runs only when asked: `SMART_REMOTE_MDNS_TEST=1 cargo test --test mdns`.

The source-tier manifest uses the repository's `cargo_build` + `copy` convention. On Windows, the current host setup executor and standalone manifest builder do not add Cargo's `.exe` suffix to artifact/copy paths; automatic source installation therefore fails until the generic repair tracked for M1b/P2. Native Windows builds and stdio runtime can still be validated directly with `target/release/smart-remote-plugin.exe`. This limitation is retained under orchestrator disposition relay 2925.

## Running

Minerva starts the binary as a stdio plugin (`manifest.json`) and stops it by closing stdin.

- `--data-dir <path>`: where the paired-device store (`paired_devices.json`) lives. Default: Minerva's per-plugin data root, `<plugins>/data/smart_remote/`, found from the executable's real path (`<plugins>/smart_remote/smart-remote-plugin`); it survives plugin updates. A build run from anywhere else falls back to `data/` beside the executable and logs a warning, because replacing that directory loses the pairings.
- `--bind <ip>`: listen address, default `0.0.0.0`.
- `--port <n>`: WebSocket port, default 47821.
- `--no-mdns`: skip the `_minerva-remote._tcp` advert.

Logs go to stderr (`RUST_LOG` filters them); stdout carries only JSON-RPC.

## LAN exposure

By default the plugin listens on every IPv4 interface, so anything on the local network can open a connection. Traffic is plain `ws://`: audio, drafts and the pairing token cross the LAN unencrypted (accepted for the prototype in the design). A connection does nothing until its `hello` carries a paired token; unauthenticated connections are capped at 16 in total and 4 per IP address and must send `hello` within 5 s. Bind a single address with `--bind` to limit exposure; the mDNS advert follows the bind (IPv4 only for `0.0.0.0`, just the bound address for a specific one, none for loopback).
