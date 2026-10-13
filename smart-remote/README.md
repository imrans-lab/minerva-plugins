# smart-remote Minerva plugin

Private Rust Minerva plugin that bridges the remote to Minerva over the local network: WebSocket server, pairing, PTT sessions, chat targeting, speech-to-text and text-to-speech via Core, and the computer side of BLE WiFi provisioning.

Kept here, not in the public minerva-plugins repo, so product details stay private and protocol changes land with the firmware in one commit.

Design: Docket `smart-remote:01a12de97992`. Minerva core prerequisites: `minerva:01a12de939dd`.

## Build and test

```sh
cargo fmt --check
cargo clippy --all-targets
cargo test
```

The message schemas are compiled in from `../protocol/schema/`; the tests replay `../protocol/examples/` against a running plugin over real sockets. The live mDNS test needs multicast and runs only when asked: `SMART_REMOTE_MDNS_TEST=1 cargo test --test mdns`.

## Running

Minerva starts the binary as a stdio plugin (`manifest.json`) and stops it by closing stdin.

- `--data-dir <path>`: where the paired-device store (`paired_devices.json`) lives. Default: Minerva's per-plugin data root, `<plugins>/data/smart_remote/`, found from the executable's real path (`<plugins>/smart_remote/smart-remote-plugin`); it survives plugin updates. A build run from anywhere else falls back to `data/` beside the executable and logs a warning, because replacing that directory loses the pairings.
- `--bind <ip>`: listen address, default `0.0.0.0`.
- `--port <n>`: WebSocket port, default 47821.
- `--no-mdns`: skip the `_minerva-remote._tcp` advert.

Logs go to stderr (`RUST_LOG` filters them); stdout carries only JSON-RPC.

## LAN exposure

By default the plugin listens on every IPv4 interface, so anything on the local network can open a connection. Traffic is plain `ws://`: audio, drafts and the pairing token cross the LAN unencrypted (accepted for the prototype in the design). A connection does nothing until its `hello` carries a paired token; unauthenticated connections are capped at 16 in total and 4 per IP address and must send `hello` within 5 s. Bind a single address with `--bind` to limit exposure; the mDNS advert follows the bind (IPv4 only for `0.0.0.0`, just the bound address for a specific one, none for loopback).
