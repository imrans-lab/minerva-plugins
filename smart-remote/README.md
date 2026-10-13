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

The message schemas are compiled in from `../protocol/schema/`; the tests replay `../protocol/examples/` against a running plugin over real sockets. `tests/mdns.rs` needs working multicast on the machine.

## Running

Minerva starts the binary as a stdio plugin (`manifest.json`) and stops it by closing stdin.

- `--data-dir <path>`: where the paired-device store (`paired_devices.json`) lives. Default: `data/` beside the executable.
- `--port <n>`: WebSocket port, default 47821.
- `--no-mdns`: skip the `_minerva-remote._tcp` advert.

Logs go to stderr (`RUST_LOG` filters them); stdout carries only JSON-RPC.
