# smart-remote Minerva plugin

Rust Minerva plugin that bridges the remote to Minerva over the local network: WebSocket server, paired-device sessions, PTT and chat targeting. Minerva owns STT/TTS; the plugin forwards mic PCM, echoes targeted transcripts, correlates its remote sends, resamples output to 16 kHz, and paces LAN speaker frames. BLE authentication can be tested with the probe below; the provisioning panel follows separately.

Migrated with scoped history from the sandbox; see `SOURCE_PROVENANCE.md`. The authoritative protocol is `protocol/` in this repository. The sandbox copy is retained during migration; check it with `scripts/check-protocol-sync.sh /path/to/ccsandbox/smart-remote-v2/protocol`.

Design: Docket `smart-remote:01a12de97992`. Minerva core prerequisites: `minerva:01a12de939dd`.

## Build and test

**Linux source installation requires `libdbus-1-dev` and `pkg-config`.** Install them through the OS package manager before building; this plugin uses the system D-Bus library, without a vendored copy. Windows requires the MSVC SDK; macOS uses the system CoreBluetooth framework and Minerva's Bluetooth permission.

```sh
cargo build --release --locked
cargo fmt --check
cargo clippy --all-targets
cargo test
```

The message schemas are compiled in from `protocol/schema/`; the tests replay `protocol/examples/` against a running plugin over real sockets. The live mDNS test needs multicast and runs only when asked: `SMART_REMOTE_MDNS_TEST=1 cargo test --test mdns`.

The source-tier manifest uses `cargo_build` + `copy`; the public builder resolves extensionless Cargo artifacts and copied entrypoints to `.exe` on Windows. Automatic host installation also needs the matching Minerva M1b setup repair (bug `minerva:01a133bf768e`). Native Windows qualification is recorded separately from Linux results.

Playback success requires the current device's exact post-EOS `speak_done` acknowledgement after physical drain. Older firmware leaves completion unknown. Device PTT barge-in uses an empty speaker EOS even if capture is refused. Host cancellation sends `speak_aborted` so updated firmware flushes and mutes playback while preserving capture. Failed endpoint registration is visible on the OLED and closes that connection; reconnect retries registration. The plugin does not retry silently. Input calls have bounded deadlines (5 s controls, 125 s STT completion, 35 s submit); a missing terminal transcript expires visibly after125 s.

Target and draft memory is per paired device for this process lifetime. Reconnect restores it; plugin restart cannot reconstruct an existing host draft and requires a fresh draft before send.

## Running

Minerva starts the binary as a stdio plugin (`manifest.json`) and stops it by closing stdin.

- `--data-dir <path>`: where the paired-device store (`paired_devices.json`) lives. Default: Minerva's per-plugin data root, `<plugins>/data/smart_remote/`, found from the executable's real path (`<plugins>/smart_remote/smart-remote-plugin`); it survives plugin updates. A build run from anywhere else falls back to `data/` beside the executable and logs a warning, because replacing that directory loses the pairings.
- `--bind <ip>`: listen address, default `0.0.0.0`.
- `--port <n>`: WebSocket port, default 47821.
- `--no-mdns`: skip the `_minerva-remote._tcp` advert.

Logs go to stderr (`RUST_LOG` filters them); stdout carries only JSON-RPC.

## BLE authentication probe

Enter remote setup and read its `SR2-XXXX` name and six-digit OLED code. Call `minerva_smart_remote_ble_probe` with `{"action":"start","name":"SR2-XXXX","code":"<OLED code>"}`. Start returns immediately with an `operation_id`; poll `{"action":"status","operation_id":1}` using the returned ID, or send `action:"cancel"` with that ID. One operation runs at a time. The probe uses the first available adapter, scans for five seconds, authenticates Security 2, disconnects, and reports `authenticated`, `failed`, or `cancelled`. It writes no WiFi credentials or pairing record. The code stays in memory and is scrubbed from owned input buffers; native BLE wire logging is disabled.

Each exchange is one whole acknowledged write followed by a complete read, at most512 bytes; the OS handles ATT long writes. Transport failure, timeout or cancellation ends the session and requires a fresh start. Physical long-write interoperability on each platform remains an owner hardware qualification gate.

Only this plugin's own logging targets are user-tunable; dependency diagnostics are capped at warnings regardless of more-specific `RUST_LOG` directives. The application-owned raw input buffers, parsed string values and code allocation are scrubbed. OS/stdio and serde parsing intermediates, compiler copies and opaque SRP allocations cannot be promised erased; this is not machine-wide memory erasure. Linux missing-header diagnostics are supplied by the upstream `libdbus-sys` build script, which names `libdbus-1-dev` and `pkg-config` before the plugin's build script can run.

## LAN exposure

By default the plugin listens on every IPv4 interface, so anything on the local network can open a connection. Traffic is plain `ws://`: audio, drafts and the pairing token cross the LAN unencrypted (accepted for the prototype in the design). A connection does nothing until its `hello` carries a paired token; unauthenticated connections are capped at 16 in total and 4 per IP address and must send `hello` within 5 s. Bind a single address with `--bind` to limit exposure; the mDNS advert follows the bind (IPv4 only for `0.0.0.0`, just the bound address for a specific one, none for loopback).

## Speech log relay

Requires Minerva M1c's `host.speech_log` capability and the granted `speech_log.changed` event. The relay projects a current page (at most10 rows,21-character summaries), plays only this authenticated endpoint, and forwards confirmed single/all deletion once. `log_delete_all` requires the firmware confirmation gesture and forwards the host’s explicit `confirmed:true` guard; Minerva owns scoped deletion and playback cancellation. Minerva owns records, delivery and heard state; the plugin does not keep a shadow log. `replay_last` reads the authoritative newest item before playing its exact ID. Missing/invalid responses and timeouts are visible; no destructive retry occurs. F2 owns confirmation and the modal OLED browser. Actual store/service and firmware integration are separate from the scripted transport fixture.
