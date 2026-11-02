# CAD Plugin for Minerva

`minerva_cad_check_structure {source}` checks the parsed DSL without a live
panel or geometry build. It returns `{pass, findings:[{rule,line,message,fix}]}`.
Rules flag three or more identical primitives outside modules/loops, repeated
numeric literals (except 0, 1, 2, 0.5, 90, 180, 360), subtracted cylinders without
a `g_*` process global or `clear_r`/`tap_r`/`press_r` fit helper in the radius,
literal additions to diameter/2 radii, and finishes on assemblies of placed
copies. Each finding names its repair. This source critic follows dimensional
checks and does not prove dimensions, fit or runtime geometry validity.

See [measurement record v0](docs/measurement-record.md) for nominal measured
inputs and per-parameter uncertainty, and the
[HW-504 composite example](docs/examples/hw504_mount.mcad) for a post module,
four loop-placed supports, radial process allowance and a composite edge finish.

The CAD plugin brings parametric boundary-representation modeling to Minerva
via the `.mcad` DSL. A Go MCP shim wraps a Python worker (build123d + OCCT)
that evaluates CAD scripts and returns B-Rep geometry. The Godot-based
CADPanel provides a 4-view editor with orbit camera, mesh display, and CAD
annotation host.

## Build (local development)

Source installs require Go 1.22+ and CPython 3.12. The worker currently declares
`>=3.12,<3.13`, so point Minerva's `python` toolchain override at a 3.12
interpreter when another Python is first on the GUI application's search path.

```bash
cd cad
python3.12 -m venv worker/.venv
worker/.venv/bin/python -m pip install -e worker
CGO_ENABLED=0 go build -o cad-plugin .
```

Normally Minerva performs those steps: side-loading `cad/manifest.json` creates
or refreshes the editable `worker/.venv`, then builds `cad-plugin`. The setup
pipeline runs on every manifest reinstall; pip and Go retain their own caches,
so unchanged reinstalls are incremental. The first worker install downloads
build123d and its compiled OCCT dependencies and can take several minutes.

The source-built wrapper deliberately prefers `worker/.venv` when it exists,
even if an embedded runtime from the same plugin version is already cached.
This makes a reinstall use the worker in the selected checkout. Marketplace
archives contain no source worker or setup stanza and continue to use the
runtime embedded in their release binary.

Run the test suite:

```bash
go test ./...
```

The bridge tests exercise the subprocess lifecycle and take ~20 seconds.

## Release (per-platform binaries)

The CAD workflow is dispatched explicitly; pushing a tag does not trigger its
package build. Set `PLUGIN_RELEASE_REF` to the reviewed remote branch or tag and
verify it names the release candidate. Use `main` only after that candidate has
been integrated there. Build artifacts without publishing:

```bash
gh workflow run cad.yml --repo imrans-lab/minerva-plugins --ref "${PLUGIN_RELEASE_REF:?Set the reviewed remote branch or tag}" -f publish=false
```

After required acceptance and the owner's publishing GO, dispatch the same
workflow with `-f publish=true`. On `main` it publishes `cad-v<version>`; other
branches produce branch prereleases. An existing stable tag is preserved rather
than overwritten. Verify the remote ref names the reviewed release candidate.

GitHub Actions (`.github/workflows/cad.yml`) builds linux-x86_64,
macos-universal and windows-x86_64 tarballs named
`cad-<version>-<target>.tar.gz`. Each contains the binary with its embedded Python
runtime, `manifest.json`, panel files, licences, and a `SHA256SUMS` sidecar. The
packed manifest omits the source-only setup instructions. The panel CI job checks
only suite registration and host file compatibility against its pinned Minerva
revision; it does not execute Godot or replace runtime/analyzer/GATE-W checks.

After the release lands, regenerate the marketplace index and commit it:

```bash
python3 scripts/regen_registry.py
git add registry.json
git commit -m "registry: cad 0.3.23"
```

### 0.3.23 release notes

- Fit checks return JSON-safe evidence, match clearance results to references,
  and recompute final verdicts after deferred collection. Certified same-check
  gaps or touches can satisfy zero-required contact declarations while retaining
  the actual measured kind and value.
- Auto / Single view / Four views controls sit beside Import. Auto accounts for
  tall displays, and manual choices persist.
- Backend admission supports 8 MiB of encoded arguments within a 16 MiB frame.
  Valid requests above 1 MiB and below those caps remain supported. Bounded queues
  and cancellation retain ownership of actual work.
- Cancelling an active evaluation stops its exact worker generation, verifies
  process and I/O retirement, and starts one replacement. The last painted model,
  editable source, later fresh evaluations and completed exports are retained;
  recovery failures and stale attempts are explicit.

Native stop timing, no-orphan checks, full platform/runtime acceptance and the
matching-host Godot gates remain release acceptance requirements; these source
notes do not claim those checks have passed. The manual workflow's secret scan
defaults to the last commit, so publication also needs the full outgoing-history
scan receipt for the integrated candidate.

## Install in Minerva

**Side-load (development):** install the local `cad/manifest.json` in Minerva's
Plugin Manager. Resolve any Go/Python preflight error, then wait for both setup
steps to finish before starting the plugin.

**Marketplace (end-users):** Minerva fetches
`raw.githubusercontent.com/imrans-lab/minerva-plugins/main/registry.json`
and downloads the matching tarball from the GitHub Release.

## Architecture

- **Go shim** (`internal/bridge/`) — MCP stdio server that launches and
  supervises the Python worker subprocess. Process-group teardown is split
  across `process_group_unix.go` and `process_group_windows.go` for
  cross-platform support.
- **Python worker** (`worker/mcad_worker/`) — build123d/OCCT evaluator;
  parses `.mcad` script, returns B-Rep mesh + metadata.
- **Godot UI panel** (`ui/CADPanel.gd`) — 4-view canvas with orbit camera,
  mesh display, and CAD annotation host.
- Full design: `Docs/design/Go-python-bridge-design.md` in the Minerva repo.

## Request limits and cancellation

The MCP stdin transport accepts newline-delimited JSON with LF or CRLF,
including a final frame at EOF. `tools/call` allows up to 8 MiB of encoded JSON
in `arguments`, matching the host scene bridge bulk-payload allowance. This is
encoded argument size, not decoded source-character count; other host paths
may have their own limits. The whole transport frame
has a separate 16 MiB cap, excluding its line ending. This leaves room for the
RPC envelope; it does not promise to accept arbitrarily large IDs or envelopes.

A complete request within the frame cap whose arguments exceed 8 MiB gets a
structured error with its original RPC ID. Frames beyond 16 MiB are discarded
through the next newline and refused with `id:null`; no ID is guessed from a
partial frame. The backend remains alive and reads the following frame. The
host waiter for a discarded frame may therefore time out.

Worker operations, including detached exports, run through one serial runner.
`cad.cancel_eval` is handled directly, while existing
`cad.export {job_id, wait_ms}` collection uses separate bounded request tasks
and does not spawn the Python worker. Queue exhaustion returns a structured
capacity refusal. Independent input-retention budgets are:

| Owner | Count limit | Encoded input bytes |
| --- | ---: | ---: |
| Ordinary MCP requests | 16 | 32 MiB |
| Export collection requests | 8 | 8 MiB |
| Reserved, active and queued worker calls | 16 | 32 MiB |
| Unfinished detached exports | 16 | 32 MiB |

These are separate owners and may retain separate copies of arguments. They
are not a combined process-memory limit. Existing completed export-result
retention remains 15 minutes. Joining the same export does not reserve a
second detached job.

Evaluation first reserves actual worker capacity, then registers cancellation
before request scheduling. A capacity refusal leaves any previous evaluation
with the same `request_id` intact. Canceling or
replacing an evaluation releases its waiting RPC promptly and suppresses a
late reply; cleanup from an older duplicate `request_id` cannot remove the new
registration. Cancelling a queued evaluation removes or skips only that request;
it never kills an unrelated active export or a shared worker startup.

An active evaluation cancellation fences its exact process generation and all
older queued worker calls, including detached exports that have not reached the
worker. These callers receive `cancelled`; genuinely later requests enter the
new epoch and may wait in the same bounded queue. The bridge signals the owned
process directly, independently of busy Python/OCCT or a blocked stdin write.
The active reservation remains held until actual `Cmd.Wait` and all pipe owners
retire. EOF and a successful kill syscall alone are insufficient. Retirement
failure retains the real process owner, refuses replacement and reports failure.

After verified retirement, exactly one eager replacement uses the existing
`worker.ready` handshake, with a default 60-second deadline (configured by
`MINERVA_WORKER_READY_TIMEOUT_SEC`). There is no automatic evaluation after reset
and no indefinite restart retry. Intentional cancellation does not count against
the three-crashes/60-second circuit breaker. A cancellation receipt distinguishes
`request_cancelled`, `cancelled`, `native_stopped` and `worker_state`
(`unchanged`, `retiring`, `recovering`, `ready` or `failed`); releasing a caller
does not prove native stop or readiness. The two-second retirement budget is an
operational target, not measured native CPU-stop evidence.

Process caches disappear with their generation. Successful evaluations identify
`provenance.process_epoch`. The panel retains its last painted mesh, references,
annotations and completed snapshot alongside editable source. Cancelled or newer
attempts remain explicitly stale, including selection/configuration changes at
the same source version. Completed export artifacts and receipts remain valid.
The next explicit evaluation provides its own source and settings to the fresh
worker. Heavy native CPU-stop, no-orphan, Windows, editor and full-suite acceptance
are still required; source checks do not establish those outcomes.

EOF and explicit server shutdown cancel the subprocess lifetime, join request
and export waiters, retire the runner, then verify owned bridge retirement. Cleanup has
a separate 10-second deadline and reports an incomplete join. It never sends a
shutdown frame behind a busy writer. This process shutdown
is separate from `cad.cancel_eval`.

## License

See `../LICENSE.md` at the repository root.
