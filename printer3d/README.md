# 3D Printer

Slice, upload, start and monitor 3D prints from Minerva. Tested only with an Original Prusa XL (2-tool, input shaper) through the PrusaLink API, slicing with an installed PrusaSlicer.

Not affiliated with or endorsed by Prusa Research. Prusa, PrusaLink and PrusaSlicer are trademarks of Prusa Research a.s.

Enable PrusaLink on the printer and enter its generated password in the panel.
The default username is `maker`. Local slicing uses an installed PrusaSlicer;
Prusa Connect/cloud access is outside this plugin's scope.

## Setup

Install from this source directory using Minerva's plugin setup action. Setup
requires Rust/Cargo 1.88 or newer and builds the backend from `Cargo.lock`.
For a manual source build:

```sh
cargo build --release --locked
cp target/release/printer3d-plugin ./printer3d-plugin
```

Start 3D Printer in Plugin Manager after installation, then open its panel. If the
backend is stopped or unavailable, the panel shows a message and Retry connection
button; start it in Plugin Manager and retry. Enter a display name and hostname such as
`prusa-xl.local`, username and the password shown under the printer's Network →
PrusaLink settings. Save, then Test connection. Discover tries supplied hosts or
common Prusa `.local` names and a short mDNS browse; some printers do not advertise
an HTTP/Prusa service, so the hostname fallback is intentional.

Eight printer slots have exact vault grants. Display names are editable. Leaving
the password blank when editing retains the current secret. Remove deletes the
slot's secret and confirms it is absent before freeing the slot. Unlock Minerva's
vault if a secret operation fails.

## Clean rename from PrusaLink

This plugin uses the `printer3d` identity, a fresh default data directory and its
own vault namespace. Re-add the printer once and set its password in the 3D Printer
panel. No configuration, slicing data, passwords or grants carry over automatically.
The old `prusalink` installation, configuration, data and vault keys remain intact.
The old plugin can be removed later by an authorized operator; this rename performs
no cleanup. `MINERVA_PLUGIN_DATA_DIR` remains an explicit user-selected override.

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

Runtime names are short; Minerva exposes them as `minerva_printer3d_<name>`.
Every schema rejects extra arguments. No tool returns a password. Only the
write-only `set_password` tool accepts one; its arguments are recorded in Minerva's
tool-call log. Use the panel when the agent should not receive the password.

| Tool | Arguments | Result / effect |
| --- | --- | --- |
| `discover` | optional `hosts` (1–32 HTTP(S) hosts) | Matching PrusaLink hosts, probe/unreachable counts |
| `list_printers` | none | Stable ids, names, hosts, users, `has_password`, stored `slicing` mapping |
| `configure_printer` | `name`, `host`, optional `user`, `slot`, `slicing` or `autodetect_slicing:true`, `slicing_selection` | Add/edit nonsecret metadata; echo stored mapping and secret handle. Explicit autodetect reads identity/catalog and refuses ambiguous choices without saving |
| `set_password` | `printer`, `password` | Write-only vault save, then one authenticated status probe; returns only `printer`, `saved:true`, `auth_ok` |
| `remove_printer` | `printer` | Deletes vault secret, verifies `exists:false`, removes metadata |
| `status` | `printer` | Read-only snapshot of status, job and USB storage |
| `thumbnail` | `printer`, optional `offset`, `reference` | Current-job raster chunk, or `available:false` |
| `upload` | `printer`, local `path`, optional `start:false` | Streams nonempty `.gcode`/`.bgcode` to USB, never overwrites; returns requested `remote_name` and encoded `remote_path` |
| `print` | `printer`, USB-relative `file` | Starts an existing file; only IDLE/READY/FINISHED |
| `stop` | `printer` | Stops current job id; only PRINTING/PAUSED |
| `list_profiles` | `printer`, optional `verbose:false` | Compact names, counts, mapping/defaults, bed, version and hashes; `verbose:true` returns per-print material compatibility |
| `slice` | `printer`, `input_path`, optional `print_profile`, `material_profile`, `extruder` | Local slicing to BGCode with receipts; no upload or print |

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

- macOS: `~/Library/Application Support/Minerva/plugins/printer3d`
- Linux: `$XDG_DATA_HOME/Minerva/plugins/printer3d`, or `~/.local/share/...`
- Windows: `%APPDATA%/Minerva/plugins/printer3d`

`MINERVA_PLUGIN_DATA_DIR` is an optional absolute-path override for isolated
embedding/tests. No data is written to the installation or working directory.
Malformed config is refused rather than overwritten.

The panel sends passwords directly from its field through capability IPC to
Minerva's vault under `printer3d_printer1`…`printer3d_printer8`. The backend uses
private host capability requests to fetch the current secret afresh when a tool
needs authentication; it never persists a password or puts one in results, process command
arguments or plugin logs. The explicit write-only `set_password` alternative sends
the supplied value through the same vault capability, then authenticates using
the saved vault value. A failed probe returns `saved:true, auth_ok:false`; a failed
vault write returns an error. Tool arguments are recorded in Minerva's tool-call
log, so that path does expose the supplied value to the agent and host log. HTTP Digest is implemented from RFC 2617/7616 with
established MD5/SHA crates. Plain HTTP is supported for local printer firmware;
HTTPS uses normal certificate verification. Upload authentication, status reads and
PUT share a 20-second request budget rather than restarting the budget per phase.
Fixed upload phase names and elapsed milliseconds go to stderr, without paths,
credentials or response bodies. A failed PUT has an unknown outcome: inspect the
printer before retrying; the plugin never automatically replays the upload.
A joined deadline worker shuts down this client's sockets after 20 seconds,
including partial-write loops; the per-request budget bounds DNS and response
reads. The deadline does not interrupt vault IPC or local file I/O. The transport
uses pinned ureq 3.5.0 for its socket shutdown and request deadline APIs; no extra
service or executable is required.
Redirects and environment proxies
are disabled. Keep printer access on a trusted local network.

## Validation and release

Run from this crate: `cargo fmt --check`, `cargo clippy --locked --all-targets --
-D warnings`, `cargo test --locked`. Unit checks include public RFC Digest vectors,
path/state boundaries and optional job projection. Stdio tests execute the real
backend with a credential-free host response and isolated metadata. Loopback HTTP
checks use public RFC example credentials to verify no-start/no-overwrite upload
headers, streaming and the busy-start guard. These are protocol checks, not live
vault/printer acceptance.

On macOS, the panel regression check can execute the actual Minerva bridge source
in JavaScriptCore with inert DOM/native adapters (no running Minerva or profile):

```sh
osascript -l JavaScript tests/panel_contract.jxa.js \
  "$PWD/ui/panel.html" /path/to/Minerva/src/Scripts/UI/Controls/WebViewEditor/minerva_bridge.gd
```

It checks unwrapped capability results, notification deduplication, known layer
counts and resuming interrupted thumbnails. It is not a visual browser test;
actual image visibility and Minerva-tab polling suspension remain live acceptance
checks.

Live acceptance requires an operator: set via panel → restart and authenticate →
change secret and authenticate with the new value → remove and confirm absence;
check the actual password is absent from repo/config/logs/tool outputs. Upload a
small file with `start:false` and verify the physical printer is unchanged. Start
and stop require fresh explicit operator go at that moment.

The manifest declares free pricing and three release targets: linux-x86_64,
macos-universal and windows-x86_64. `.github/workflows/printer3d.yml` follows the
Drive Rust-backend workflow: build native binaries (lipo on macOS), copy the HTML
panel, omit source-only `setup` from the packed manifest, and package
`printer3d-<version>-<target>.tar.gz` with `SHA256SUMS`. PrusaSlicer remains a
separately installed application; it is not bundled.

For an artifact-only build, set `PLUGIN_RELEASE_REF` to the reviewed remote
branch or tag and verify it names the release candidate. Use `main` only after
that candidate has been integrated there:

```sh
gh workflow run printer3d.yml --repo imrans-lab/minerva-plugins --ref "${PLUGIN_RELEASE_REF:?Set the reviewed remote branch or tag}" -f publish=false
```

After the required checks and owner's publishing GO, push an annotated
manifest-matching tag, such as `printer3d-v0.1.2`. `printer3d-tags.yml` calls the
same package workflow; dispatch/tag builds run the existing Cargo suite on Linux
and the MCP handshake on each target before publication. The existing publication
guard validates the annotated tag against the manifest and source commit. Manual
non-main publishing produces a branch prerelease; stable manual dispatch preserves
an existing tag and requires the annotated tag path for a new stable release.

Registry selection already includes this plugin. Run `scripts/regen_registry.py`
from the repository root only after the real release tag/assets exist, then commit
the updated `registry.json`; source version changes alone do not create download
URLs or advance the marketplace selection.

### 0.1.2 release notes

- Reuse one DNS resolution within each status call to reduce repeated `.local`
  lookups.
- HTTP Discover results use resolved IPv4 endpoints while retaining the original
  hostname for display.
- Refresh printer cards after Remove and after saving configuration, including
  when the password step fails. Preserve mutation and list-refresh errors.
- Give explicit-host discovery an eight-second shared probe budget, including
  hostname resolution, address fallback and the identity request.

### 0.1.1 release notes

- PrusaLink is now named **3D Printer**, with plugin id `printer3d` and
  `minerva_printer3d_*` tools. The external PrusaLink API and PrusaSlicer names are
  retained.
- Tested only with an Original Prusa XL (2-tool, input shaper) through the
  PrusaLink API, slicing with an installed PrusaSlicer. This does not claim
  compatibility with other printers.
- Not affiliated with or endorsed by Prusa Research. Prusa, PrusaLink and
  PrusaSlicer are trademarks of Prusa Research a.s.
- Re-add the printer once in the 3D Printer panel and enter its password there.
  Configuration, slicing mappings, passwords and grants do not migrate
  automatically. The old `prusalink` installation, data and vault keys remain
  intact; remove the old plugin only after verifying the new installation.

Protocol references: [PrusaLink OpenAPI](https://github.com/prusa3d/Prusa-Link-Web/blob/master/spec/openapi.yaml),
[RFC 7616](https://www.rfc-editor.org/rfc/rfc7616.html),
[RFC 2617](https://www.rfc-editor.org/rfc/rfc2617.html).


Upload/print USB path segments percent-encode every UTF-8 byte outside the
RFC3986 unreserved set (`A–Z a–z 0–9 - . _ ~`). A filename's literal `+` therefore
travels as `%2B`, while spaces travel as `%20`. Folder separators remain route
separators; existing traversal checks still apply. Digest authentication uses the
same encoded URI sent on the wire. Upload's `remote_name` is the requested decoded
filename and `remote_path` is its encoded API path; neither claims to be a
printer-reported canonical or short filename. `file` remains compatible.

## Local slicing (macOS/Linux)

`list_profiles {printer,verbose?:false}` and `slice {printer,input_path,print_profile?,
material_profile?,extruder?}` use an already installed PrusaSlicer. They never
fetch a password, contact the printer, upload, or start a print. Upload and print
remain separate tools requiring their own operator authorization.

Use `configure_printer` with `autodetect_slicing:true` to resolve installed paths
and catalog choices. First configure nonsecret metadata and set the password
through the panel. Then supply that existing `slot` and its matching `host` and
`user`; autodetect never sends an old host's password to a replacement host.
For example:

```json
{
  "slot": 1, "name": "Workshop XL", "host": "http://prusa-xl.local", "user": "maker",
  "autodetect_slicing": true,
  "slicing_selection": {"model_id": "XL2IS", "variant": "0.4"}
}
```

The optional, strict `slicing_selection` accepts exact `model_id`, `variant`,
`tool_count`, `printer_profile`, `print_profile`, and `material_profile` choices.
Missing or conflicting choices return `configured:false`, a reason,
`autodetect.needed_fields`, and compact `autodetect.candidates`. Add the required
selections and retry. Material candidates belong to the selected print profile.
No metadata or prior slicing mapping changes until all choices resolve uniquely.
An invalid call or failed probe/query also leaves configuration intact. Full
`slicing` and `autodetect_slicing:true` are mutually exclusive; `slicing_selection`
requires explicit autodetect. Ordinary configure never fetches a password.

The standard macOS app at `/Applications/PrusaSlicer.app` supplies paths by default.
Other macOS/Linux installs can select absolute `executable` and `vendor_ini` paths,
plus `vendor_id` when it differs from the INI filename stem. Missing installs
return needed path fields; nothing is downloaded. Manual full mappings remain
available without identity probing.

Autodetect alone reads `/api/version` and `/api/v1/info` through the existing
Digest client and slot's vault handle, with an eight-second shared request
deadline. The sanitized identity receipt retains only `version_printer`,
`version_nozzle_diameter`, and `info_nozzle_diameter` from those endpoints. Info
may be unavailable (404); identity fields are optional. Exact reported catalog
model IDs or complete names constrain selection. Opaque firmware codes remain
unverified evidence and require an explicit model ID; the reply then records
`model_source:user_selection`. Recognized contradictory model/nozzle evidence
refuses. Hostnames, serials and loaded filament never select a profile. No
tool-count or HF report is assumed: exact catalog choices or explicit selections
must resolve those fields. Print/material choices use exact compatibility, with
no guessed defaults or first `default_materials` entry.

Catalog discovery enables all model variants declared in a private copy of the
installed vendor INI, then validates with the same isolated CLI queries used by
manual slicing mappings. A successful auto reply includes `configured:true`, the
stored `slicing`, identity provenance, hashes, version and private query directory.
Its CLI work shares the existing 20-second budget and process limits. It never
slices, uploads, starts a print, or edits GUI settings.

Alternatively configure the optional full `slicing` object directly:

```json
{
  "executable": "/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer",
  "vendor_ini": "/Applications/PrusaSlicer.app/Contents/Resources/profiles/PrusaResearch.ini",
  "vendor_id": "PrusaResearch", "model_id": "XL2IS", "variant": "0.4",
  "tool_count": 2,
  "printer_profile": "Original Prusa XL - 2T Input Shaper 0.4 nozzle",
  "print_profile": "0.20mm SPEED @XLIS 0.4",
  "material_profile": "Prusament PLA @XLIS"
}
```

Omitting the mapping preserves it only when the host remains the same. Changing
host without a new mapping clears it. The configure reply echoes the stored
mapping as `slicing` (or `null` when cleared), so preserved defaults are visible.
Existing configs remain readable, and
unmapped printers refuse slicing. The installed catalog must confirm the exact
vendor/model/variant/profile and tool count. Its rectangular bed origin and size
supply the center; other bed shapes fail rather than guessing.

`list_profiles` defaults to a compact reply. `mapping` contains the selected
printer and configured print/material defaults; `profiles` contains sorted,
deduplicated `print_profiles` and `material_profiles` names plus their counts.
Material names are a union across print profiles: they do not imply that every
print/material pair is compatible. Use `list_profiles {printer,verbose:true}`
for the original full catalog, where each `profiles.print_profiles` row retains
its exact compatible `filament_profiles`. Both modes return the bed, slicer
version, executable/vendor hashes and private run directory.

The configured defaults apply when slice arguments omit them. An override must
appear in that printer's compatible catalog. `extruder` overrides are supported
for STL only; 3MF projects retain embedded tool assignments.

Each call retains a private random directory under the plugin data directory's
`slicing/`, with a copied vendor profile and minimal settings, query/log files,
and (on success) `output.bgcode` and `receipt.json`. No GUI profile is edited.
Explicit CLI options disable GUI single-instance forwarding and post-process
hooks; only the export action runs. No shell interprets arguments. Input is a
regular local `.3mf`/`.stl` up to256MiB; output uses a fresh owned path.

Calls share a20second budget across catalog queries and slicing, leaving MCP
response headroom. Each child inherits a20CPU-second limit, uses two slicer
threads, and has its owned process group monitored for20CPU seconds,4GiB RSS
and16MiB logs. The group is signalled before its leader is reaped, including on
normal exit. OS file I/O and the local `ps` monitor are synchronous; these are
monitored application limits, not a container guarantee. Unsupported hosts fail
visibly. A limit/error leaves private evidence and incomplete output; nothing is
retried or uploaded automatically. Inspect the run logs under `slicing/`.

The result records input/output, executable and vendor hashes, exact profiles,
center, version and completion. Metadata comes only from a bounded, CRC32-checked
BGCode-v1 print block (plain INI or zlib). Supported duration and per-tool mass
fields are returned as `est_time_s` and `filament_g_per_tool`;
unsupported/missing metadata is unavailable/null, never inferred. Existing
`flate2`/`crc32fast` dependencies are reused directly for decoding and checksums.
Keep the output/receipt together. Cleanup is manual; the tool deletes no files.
