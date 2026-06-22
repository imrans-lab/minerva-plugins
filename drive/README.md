# Drive

Multi-device file sync for Minerva. Drive keeps a folder of files in step across
all of one person's machines (Windows, macOS, Linux), surviving edits made on
more than one device without losing work.

## How it works

Drive is **cloud-canonical**. Every save uploads a new immutable, versioned blob
to the Minerva artifact service; the highest version of a project is its current
state, and older versions remain as recoverable history. Each blob carries a
small manifest (project id, version, parent version, content hash, device, and
modified time) so any device can reconstruct the full picture from the list of
its own artifacts.

A sync pass compares each local file against the cloud current:

| Local | Cloud | Action |
|-------|-------|--------|
| unchanged | unchanged | nothing to do |
| changed | unchanged | push a new version |
| unchanged | newer | pull the cloud version |
| changed | newer | **divergence** — see below |

On divergence (both sides changed since the last sync), the cloud version becomes
the canonical file and the local edit is preserved beside it as a conflict copy
named `<file>.conflict-<device>-<timestamp>`. This is last-writer-wins on the
current pointer, and it never discards an edit — you reconcile conflict copies by
hand. Cloud projects with no local copy are downloaded into the drive folder.

## The drive folder

Drive syncs the files directly inside one folder:

- Default: `~/MinervaDrive` (uses `HOME`, or `USERPROFILE` on Windows).
- Override with the `DRIVE_FOLDER` environment variable.

Sync state lives in `<folder>/.drive-state.json`. Hidden files (names starting
with `.`) and conflict copies are not themselves synced.

## Tools

The plugin exposes three MCP tools (also reachable from the panel):

- `minerva_drive_status` — connectivity and project count. Never fails; reports
  `{ready, connected, device, project_count}`.
- `minerva_drive_list` — every project and its status (`synced`, `local_ahead`,
  `cloud_ahead`, `conflict`, `local_only`, `cloud_only`).
- `minerva_drive_sync` — run a sync pass; returns push/pull/conflict counts and
  any errors.

The panel shows device/connection status, a per-project table, and a Sync Now
button, and refreshes when the backend reports a change.

## Building

```sh
cargo build --release          # produces the drive-plugin binary
cargo test --release           # unit tests (offline)
```

The default test suite runs entirely offline. Tests that talk to the live
artifact service are opt-in:

```sh
DRIVE_LIVE_TEST=1 cargo test --release -- --nocapture
```

These use a REST login; override the endpoints/account with `DRIVE_LOGIN_URL`,
`DRIVE_WS_URL`, `DRIVE_USER`, and `DRIVE_PASS`.

## Scope

Drive covers one owner's own devices. Sharing files with other people, and
in-app project opening, are out of scope for this version; sync writes files to
the drive folder on disk.
