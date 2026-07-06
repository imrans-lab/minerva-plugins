# PCB plugin Python worker (`pcb_worker`)

The PCB plugin's geometry/analysis logic runs in a long-lived Python worker
subprocess, driven from Go over the shared Go↔Python bridge
(`shared/bridge`, `shared/runtime`) — the same machinery the CAD plugin uses.
The Go router lazily spawns `python -m pcb_worker` on the first worker-backed
tool call; the bridge gives us framing, request/response correlation, a crash
circuit breaker, and graceful shutdown for free.

- **Worker source:** `pcb/worker/pcb_worker/` (package) + `pcb/worker/tests/`.
- **Entrypoint:** `python -m pcb_worker` (`__main__.py` → `dispatcher.run`).
- **Wire framing:** LSP-style `Content-Length` frames (`framing.py`), identical
  to the CAD worker and to `shared/bridge/framing.go`. stdout carries only
  framed JSON; all logging goes to stderr.
- **Methods are stateless pure functions** over the canonical board-source YAML
  contract (`pcb/internal/board/board.go`, `pcb/docs/board-yaml.md`). There is
  no per-request state (no cache) — unlike CAD's `_last_program`.

## Methods (worker) ↔ MCP tools (Go)

The worker method names carry **no prefix**; the Go router exposes each as an
MCP tool under a `pcb_` prefix — matching CAD's split (MCP `mcad_validate` →
worker method `validate`). The `pcb_` prefix keeps these LLM-facing analysis
tools distinct from the dotted `pcb.serialize`/… panel-IPC channels and from
core Minerva's `minerva_pcb_*` tools.

| MCP tool | worker method | purpose |
|---|---|---|
| `pcb_validate` | `validate` | structural validation → `{ok, errors[], warnings[]}` |
| `pcb_generate` | `generate` | canonical YAML → KiCad file text |
| `pcb_gerbers` | `gerbers` | canonical YAML → Gerber (RS-274X/X2) + Excellon drills — see `docs/gerbers.md` |
| `pcb_check_libraries` | `check_libraries` | footprint/symbol existence vs a `lib_dir` (real data this round — see `docs/libraries.md`) |
| `pcb_check_bom` | `check_bom` | BOM extraction + validation |
| — (health) | `init`, `ping` | version/liveness handshake |

Every method returns the bridge envelope `{"ok": bool, "result"|"error": …}`
(the Go router re-wraps success as `{ok:true, result}` and worker errors as
`{ok:false, error}` for the MCP `content[0].text` payload).

**Not worker methods** — `pcb_fetch_libraries` and `pcb_library_status` are
in-process Go tools (no Python round-trip; the fetch is plain `net/http`) that
provide the `lib_dir` data `check_libraries`/`check_bom` read. See
`docs/libraries.md` for the full fetch/verify/data-dir contract.

### `validate` — `{yaml}` or `{board}` → `{ok, errors[], warnings[]}`

Each entry is `{path, message}` with a canonical field path
(`components[2].ref`, `nets[0].pins[1]`). **Errors** (hard, `ok:false`):

- missing required top-level fields (`version, name, width_mm, height_mm,
  components, nets`) and bad scalar types;
- duplicate component `ref`;
- net pin ref `"Ref.Pad"` that is malformed, names an unknown component, or
  names a pad not declared on a component that declares pins;
- trace missing/unknown `net`, `<2` points, or non-positive `width_mm`;
- via `drill_mm >= diameter_mm`.

**Warnings** (soft, still `ok:true`): coordinates outside the board outline
(components / trace points / vias), trace narrower than
`design_rules.trace_width_mm`, a net pin ref to a component that declares no
pins (can't verify), a via naming an unknown net. A YAML parse failure is
reported as a single validation error (data), not a protocol error, so the LLM
inner loop sees it uniformly.

### `generate` — `{yaml|board, name?, out_dir?}` → `{files, written}`

Returns `files` = `{"<name>.kicad_pcb": text, "<name>.kicad_sch": text,
"<name>.kicad_pro": text}`. Contents travel **inline** — the worker↔Go channel
is stdio (no 64 KiB cap; that cap is only the panel↔plugin IPC broker,
board-yaml.md §"64 KiB IPC payload caveat"). When `out_dir` is supplied the
files are **also** written to disk and `written` = `[{path, bytes_written}]`
(mirrors CAD's `export`, which returns `{path, bytes_written}`).

### `gerbers` — `{yaml|board, name?, out_dir?}` → `{files, written}`

Same envelope as `generate`. `files` = six Gerber layers (`<name>-F_Cu.gbr`,
`-B_Cu`, `-F_Mask`, `-B_Mask`, `-F_SilkS`, `-Edge_Cuts`) plus `-PTH.drl` /
`-NPTH.drl` Excellon drill files (each emitted only when the board has holes of
that class). Gerber layers come from the pinned `gerber-writer` (a runtime
dependency now); the Excellon files are emitted by `pcb_worker.gerber` directly.
Coordinate format is self-declared per layer (read the `%FS` line). See
`docs/gerbers.md` for the coordinate-format decision, the X2 comment-form interop
note, the PTH/NPTH split, silk limitations, and the fab-correctness HITL gate.

`name` defaults to the board `name`. The `.kicad_pcb` faithfully carries every
component as a `footprint` (pads at authored offsets; through-hole pads when a
pin has `drill_mm`, else nominal SMD rect pads), every trace as `segment`
nodes, the outline as four `Edge.Cuts` `gr_line`s, and vias. Nets are declared
and pads/segments reference them. The `.kicad_sch`/`.kicad_pro` are **minimal
netlist-carrying skeletons** (see divergence below).

### `check_libraries` — `{yaml|board, lib_dir?}` → `{ok, checked, missing[], missing_symbols[], missing_data}`

The library **data** ships via `pcb_fetch_libraries` + `pcb/libraries.lock.json`
(see `docs/libraries.md` for the fetch/verify/data-dir contract). The `lib_dir`
arg is the data contract: a directory of KiCAD `*.kicad_sym` symbol libraries
and `*.pretty` footprint libraries (`pcb_worker/libcheck.py` reads both). The
Go router (`internal/tools/worker_tools.go`'s `withDefaultLibDir`) fills in
the fetched-data directory automatically whenever a caller omits `lib_dir`, so
in practice most callers never pass it explicitly.

A footprint resolves if a `.kicad_mod` exists — `"Lib:Name"` →
`<lib_dir>/Lib.pretty/Name.kicad_mod`; a bare `"Name"` is searched across every
`*.pretty` dir. **Footprint match is required** per board-yaml's footprint
field — every component that declares one gates `ok`, and a miss carries
nearest-name `suggestions[]` (via `difflib`).

A component may optionally carry a `symbol` field via the schema's `Extra`
passthrough (board-yaml has no first-class symbol field — components
reference footprints, not symbols). When present, it's checked against the
`.kicad_sym` files' top-level symbol names (see `docs/libraries.md`'s "Worker-
side reading" for the paren-depth scan). **Symbol match is optional/informal**
— a miss lands in `missing_symbols[]` and never affects `ok`.

**No-data contract (never crashes):** with no `lib_dir`, an empty/whitespace
`lib_dir`, or one that doesn't exist, the reply is
`{ok:true, checked:0, missing:[], missing_data:true, hint:"..."}` — `hint`
points the caller at `pcb_fetch_libraries`. With data present:
`{ok, checked, missing:[{ref, footprint, path, suggestions}], missing_symbols:[{ref, symbol, path}], missing_data:false, lib_dir}`.

### `check_bom` — `{yaml|board, lib_dir?}` → `{ok, items[], line_count, part_count, errors, warnings, lib_present, missing_data, hint?}`

Groups components by `(footprint, value)` → `items:[{refs[], footprint, value,
qty}]`. Warns on components missing a `value` or `footprint` (a DNP position is
legitimate, so these are warnings, not errors). Footprint-presence flags
(`footprint_found`) and nearest-name `suggestions[]` (for items that don't
resolve) are added to each item only when `lib_dir` data is present.
`missing_data` mirrors `check_libraries`'s no-data contract (`!lib_present`),
with the same `hint` field when data is absent — the two tools are safe to
treat uniformly.

### `init` / `ping` — health

`init` returns `{worker_version, pyyaml, circuit_synth, circuit_synth_available,
cold_start_ms}`; `ping` returns `{pong, worker_version, cold_start_ms, echo}`.
The worker emits a `worker.ready` notification (with `cold_start_ms`) once cold
start completes, before entering the request loop.

## Cold start

Cold start imports **pyyaml only** (no OCCT-style kernel), then probes the
circuit_synth version via `importlib.metadata` (no import). **Measured cold
start on this dev machine (CPython 3.12.4, Windows): ~78–79 ms.** Because there
is no heavy kernel to warm, the bridge's 60 s `worker.ready` deadline is vast
headroom; the Go router uses `context.Background()` for worker calls (a per-call
timeout ctx would be threaded into `exec.CommandContext` and kill the shared
worker on expiry).

## Dependencies & the circuit_synth divergence

`pyproject.toml` pins **`pyyaml>=6,<7`** as the one hard runtime dependency
(the clean-venv test run uses PyYAML 6.0.3 and nothing else). **`circuit-synth`
is pinned but OPTIONAL** (extra `[circuit_synth]`, `circuit-synth==0.12.1`).

Why optional, and why validate/generate are plain Python:

- circuit_synth 0.12.1 **imports fine on CPython 3.12.4** (~0.4 s) — it is not a
  dead or py3.12-broken package. So no escalation.
- But it generates KiCad from **its own** `Circuit` object graph, and its
  `Component` cannot even be constructed without KiCad **symbol-library** data:
  `Component(symbol="Device:R")` raises `LibraryNotFound` when
  `KICAD_SYMBOL_DIR` is unset (verified). It also imposes **its own
  auto-placement**, which would discard our authored, unit-tagged
  `x_mm/y_mm/rotation_deg` — the whole point of the canonical contract.
- Our `validate` target is **our** YAML schema, not circuit_synth's model, so
  validation is necessarily bespoke plain Python either way.

Therefore `validate`, `generate`, `check_bom`, and `check_libraries` all run in
plain Python over the canonical YAML (`board_model.py`, `kicad.py`). The worker
never imports circuit_synth; it only metadata-probes its version, so a missing
or broken install never blocks the worker. Install the `circuit_synth` extra
only if a future child wants its netlister/ERC **with** real KiCad libraries.

**Recorded constraints (minimal-generate tradeoffs):**

- `.kicad_pcb` SMD pads use a nominal `1×0.6 mm` rect; exact pad geometry per
  footprint is next-child scope. Through-hole pads honor `drill_mm` (and
  `annulus_diameter_mm` from `Extra` when present).
- `.kicad_sch` is a structural skeleton (header + a text block enumerating
  components and nets) — a fully symbol-placed schematic needs symbol-library
  data. `.kicad_pro` is a minimal valid JSON project.

## Running the worker & tests (dev)

The worker needs its deps available to whatever `python3` the bridge resolves.
Resolution order (`shared/runtime/resolve.go`): embedded PBS runtime (none yet
for PCB) → `<plugin>/worker/.venv` → `python3` on PATH.

```bash
# Create a venv OUTSIDE the repo, install the worker (pyyaml + gerber-writer)
# and the dev extra (pytest + pygerber, the gerber round-trip test dependency):
python -m venv /path/to/pcbworker-venv
/path/to/pcbworker-venv/Scripts/pip install -e 'pcb/worker[dev]'   # + optional: '.[circuit_synth]'

# Python tests (50 tests: methods happy paths, malformed YAML, seeded
# structural errors, check_libraries no-data, gerber structural + pygerber
# round-trip + drill split + goldens, stdio smoke):
cd pcb/worker && /path/to/pcbworker-venv/Scripts/python -m pytest tests/ -q

# Go tests, incl. the end-to-end stdio smoke that spawns the real worker.
# The smoke test SKIPS unless PCB_WORKER_PYTHON_DIR names a dir whose python3
# has the worker deps (it is prepended to the spawn PATH). On Windows a venv's
# Scripts/ has python.exe but not python3.exe — copy it once:
cp /path/to/pcbworker-venv/Scripts/python.exe /path/to/pcbworker-venv/Scripts/python3.exe
PCB_WORKER_PYTHON_DIR='...\pcbworker-venv\Scripts' go test ./...
```
