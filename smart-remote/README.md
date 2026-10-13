# smart-remote Minerva plugin

Rust Minerva plugin that bridges the remote to Minerva over the local network: WebSocket server, paired-device sessions, PTT and chat targeting. Minerva owns STT/TTS; the plugin forwards mic PCM, echoes targeted transcripts, correlates its remote sends, resamples output to 16 kHz, and paces LAN speaker frames. Secured BLE provisioning remains a later campaign batch.

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

The source-tier manifest uses `cargo_build` + `copy`; the public builder resolves extensionless Cargo artifacts and copied entrypoints to `.exe` on Windows. Automatic host installation also needs the matching Minerva M1b setup repair (bug `minerva:01a133bf768e`). Native Windows qualification is recorded separately from Linux results.

Playback success requires the current device's exact post-EOS `speak_done` acknowledgement after physical drain. Older firmware leaves completion unknown. Host cancellation sends `speak_aborted` so updated firmware flushes and mutes playback while preserving capture. Failed endpoint registration is visible on the OLED and closes that connection; reconnect retries registration. The plugin does not retry silently. Input calls have bounded deadlines (5 s controls, 125 s STT completion, 35 s submit); a missing terminal transcript expires visibly after125 s.

Target and draft memory is per paired device for this process lifetime. Reconnect restores it; plugin restart cannot reconstruct an existing host draft and requires a fresh draft before send.

## Running

Minerva starts the binary as a stdio plugin (`manifest.json`) and stops it by closing stdin.

- `--data-dir <path>`: where the paired-device store (`paired_devices.json`) lives. Default: Minerva's per-plugin data root, `<plugins>/data/smart_remote/`, found from the executable's real path (`<plugins>/smart_remote/smart-remote-plugin`); it survives plugin updates. A build run from anywhere else falls back to `data/` beside the executable and logs a warning, because replacing that directory loses the pairings.
- `--bind <ip>`: listen address, default `0.0.0.0`.
- `--port <n>`: WebSocket port, default 47821.
- `--no-mdns`: skip the `_minerva-remote._tcp` advert.

Logs go to stderr (`RUST_LOG` filters them); stdout carries only JSON-RPC.

## LAN exposure

By default the plugin listens on every IPv4 interface, so anything on the local network can open a connection. Traffic is plain `ws://`: audio, drafts and the pairing token cross the LAN unencrypted (accepted for the prototype in the design). A connection does nothing until its `hello` carries a paired token; unauthenticated connections are capped at 16 in total and 4 per IP address and must send `hello` within 5 s. Bind a single address with `--bind` to limit exposure; the mDNS advert follows the bind (IPv4 only for `0.0.0.0`, just the bound address for a specific one, none for loopback).
