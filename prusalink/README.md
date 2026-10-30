# PrusaLink

Connect Minerva to local PrusaLink printers, including XL, MK4 and Core One.
Enable PrusaLink on the printer and enter its generated password in the panel.
The default username is `maker`. Prusa Connect/cloud access and slicing are outside
this plugin's scope.

## Setup

Install from this source directory using Minerva's plugin setup action. Setup
requires Rust/Cargo 1.88 or newer and builds the backend from `Cargo.lock`.
For a manual source build:

```sh
cargo build --release --locked
cp target/release/prusalink-plugin ./prusalink-plugin
```

Open the PrusaLink panel, enter a display name and hostname such as
`prusa-xl.local`, username and the password shown under the printer's Network →
PrusaLink settings. Save, then Test connection. Discover tries supplied hosts or
common Prusa `.local` names and a short mDNS browse; some printers do not advertise
an HTTP/Prusa service, so the hostname fallback is intentional.

Eight printer slots have exact vault grants. Display names are editable. Leaving
the password blank when editing retains the current secret. Remove deletes the
slot's secret and confirms it is absent before freeing the slot. Unlock Minerva's
vault if a secret operation fails.

## Dashboard

Each visible panel polls one status/job/storage snapshot per printer every five
seconds; tools themselves never poll. Cards show state, progress, elapsed and
remaining time, estimated finish time while printing, actual/target nozzle and
bed temperatures, fans, nondefault speed/flow, file name and USB availability.
Temperature history is kept in panel memory for about ten minutes. Dashed graph
lines show targets; solid lines show actual temperatures.

Layer height and total height appear when the current job supplies metadata.
Layer counts are explicitly approximate (variable layer heights can differ).
Missing fields show an unavailable value. PNG/JPEG thumbnails are read from the
current job's reference on the configured printer, with no redirects or alternate
origins; missing thumbnails/404 show a placeholder. Images are capped at 512 KiB
and transferred in 24 KiB chunks to stay below Minerva's 64 KiB control IPC limit.
A thumbnail is requested when the job/reference changes, never on every poll.

Transitions to FINISHED, ERROR, PAUSED or ATTENTION send one `host.notify`
notification per transition. Initial state does not trigger a notification;
transition/history memory ends when the panel closes. Hidden panels stop polling.

## Tools

Runtime names are short; Minerva exposes them as `minerva_prusalink_<name>`.
Every schema rejects extra arguments; no tool accepts or returns a password.

| Tool | Arguments | Result / effect |
| --- | --- | --- |
| `discover` | optional `hosts` (1–32 HTTP(S) hosts) | Matching PrusaLink hosts, probe/unreachable counts |
| `list_printers` | none | Stable ids, names, hosts, users, `has_password` |
| `configure_printer` | `name`, `host`, optional `user`, `slot` | Add/edit nonsecret metadata; returns fixed secret handle for panel IPC |
| `remove_printer` | `printer` | Deletes vault secret, verifies `exists:false`, removes metadata |
| `status` | `printer` | Read-only snapshot of status, job and USB storage |
| `thumbnail` | `printer`, optional `offset`, `reference` | Current-job raster chunk, or `available:false` |
| `upload` | `printer`, local `path`, optional `start:false` | Streams nonempty `.gcode`/`.bgcode` to USB, never overwrites |
| `print` | `printer`, USB-relative `file` | Starts an existing file; only IDLE/READY/FINISHED |
| `stop` | `printer` | Stops current job id; only PRINTING/PAUSED |

Printer arguments accept stable `printer1`…`printer8` ids or unique display names.
**`print`, `stop`, and `upload` with `start:true` change physical hardware. Obtain
explicit operator authorization for those actions.** Upload defaults to no start;
it uses `Overwrite:?0` and `Print-After-Upload:?0`. A transport failure during a
mutation reports an unknown outcome: check the printer before retrying. The
backend never retries these requests automatically. The panel has no moving
controls.

## Data and secrets

Only slot, display name, host and username are saved in `printers.json` under the
OS plugin data directory:

- macOS: `~/Library/Application Support/Minerva/plugins/prusalink`
- Linux: `$XDG_DATA_HOME/Minerva/plugins/prusalink`, or `~/.local/share/...`
- Windows: `%APPDATA%/Minerva/plugins/prusalink`

`MINERVA_PLUGIN_DATA_DIR` is an optional absolute-path override for isolated
embedding/tests. No data is written to the installation or working directory.
Malformed config is refused rather than overwritten.

Passwords go directly from the password field through panel capability IPC to
Minerva's vault under `prusalink_printer1`…`prusalink_printer8`. The backend uses
private host capability requests to fetch the current secret afresh for each
tool request; it never persists a password or puts one in agent-facing results,
command arguments or logs. HTTP Digest is implemented from RFC 2617/7616 with
established MD5/SHA crates. Plain HTTP is supported for local printer firmware;
HTTPS uses normal certificate verification. Redirects and environment proxies
are disabled. Keep printer access on a trusted local network.

## Validation and release

Run from this crate: `cargo fmt --check`, `cargo clippy --locked --all-targets --
-D warnings`, `cargo test --locked`. Unit checks include public RFC Digest vectors,
path/state boundaries and optional job projection. Stdio tests execute the real
backend with a credential-free host response and isolated metadata. Loopback HTTP
checks use public RFC example credentials to verify no-start/no-overwrite upload
headers, streaming and the busy-start guard. These are protocol checks, not live
vault/printer acceptance.

Live acceptance requires an operator: set via panel → restart and authenticate →
change secret and authenticate with the new value → remove and confirm absence;
check the actual password is absent from repo/config/logs/tool outputs. Upload a
small file with `start:false` and verify the physical printer is unchanged. Start
and stop require fresh explicit operator go at that moment.

The manifest declares free pricing and supported release targets. Registry
selection includes this plugin, but a generated marketplace entry waits for the
first real release tag/assets. Do not invent download URLs or publish from this
source change.

Protocol references: [PrusaLink OpenAPI](https://github.com/prusa3d/Prusa-Link-Web/blob/master/spec/openapi.yaml),
[RFC 7616](https://www.rfc-editor.org/rfc/rfc7616.html),
[RFC 2617](https://www.rfc-editor.org/rfc/rfc2617.html).
