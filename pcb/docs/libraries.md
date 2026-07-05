# KiCAD library-data subset (`pcb_fetch_libraries` / `pcb_check_libraries` / `pcb_check_bom`)

KiCAD's symbol and footprint libraries are plain **s-expression data files** —
no KiCAD install, EDA license, or binary is needed to read them. This round
makes `pcb_check_libraries`/`pcb_check_bom` do real work by giving them real
data: a curated common-parts subset, fetched on demand from KiCAD's own
GitLab-hosted library repos, verified by sha256, and read directly by the
Python worker (`pcb/worker/pcb_worker/libcheck.py`).

## The no-FCIB policy (hard)

**Library data files are never checked into this repo.** The repo carries only:

- `pcb/libraries.lock.json` — the lock manifest (source URLs, sha256, size).
- `pcb/scripts/gen_libraries_lock.py` — regenerates the lock from a tag.
- `pcb/internal/libraries/` — the Go fetcher/status reader.
- `pcb/worker/pcb_worker/libcheck.py` — the Python reader.

The actual `.kicad_sym` / `.kicad_mod` bytes live only on a user's machine,
fetched at runtime by `pcb_fetch_libraries` into the plugin's data directory
(see "Data directory" below). Hand-authored test fixtures are the one
exception — `pcb/worker/tests/testdata/fixture_lib/` is a tiny, deliberately
tiny (2 symbols, 2 footprints) fixture written by hand for unit tests, not a
copy of real KiCAD library content.

## Subset rationale — what's in the lock and why

This is a **curated common-parts subset**, not a library mirror. 19 entries:

**Symbol libraries** (whole `.kicad_sym` files — each is a single blob):
`Device`, `Connector`, `Connector_Generic`, `power`, `MCU_Module`,
`Regulator_Linear`. These cover the parts most boards reference: passives,
generic connectors, power-flag symbols, and two common IC families.

**Footprints** (individual `.kicad_mod` files, curated per library —
NOT every footprint in each `.pretty` dir): 3 from `Resistor_SMD.pretty`, 3
from `Capacitor_SMD.pretty`, 2 from `LED_SMD.pretty`, 3 from
`Connector_PinHeader_2.54mm.pretty`, 2 from `Package_SO.pretty` — the handful
of package sizes that show up in most small boards (metric 0402/0603/0805
passives, common pin-header counts, SOIC-8/16).

This is deliberately a starting subset. Widening it (more libraries, more
footprints, or eventually whole-library mirroring) is a re-run of the
generator with an edited curated list (see below) — an explicit, reviewable
change, never silent growth.

## The lock manifest

`pcb/libraries.lock.json`:

```json
{
  "schema_version": 1,
  "tag": "9.0.9.1",
  "generated_at": "2026-07-05T22:00:10Z",
  "source": {
    "symbols_repo": "https://gitlab.com/kicad/libraries/kicad-symbols",
    "footprints_repo": "https://gitlab.com/kicad/libraries/kicad-footprints"
  },
  "entries": [
    {
      "name": "Device.kicad_sym",
      "kind": "symbol_lib",
      "dest": "Device.kicad_sym",
      "url": "https://gitlab.com/kicad/libraries/kicad-symbols/-/raw/9.0.9.1/Device.kicad_sym",
      "sha256": "<64-hex>",
      "size_bytes": 2218424
    },
    {
      "name": "Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod",
      "kind": "footprint",
      "dest": "Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod",
      "url": "https://gitlab.com/kicad/libraries/kicad-footprints/-/raw/9.0.9.1/Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod",
      "sha256": "<64-hex>",
      "size_bytes": 1773
    }
  ]
}
```

`dest` preserves the real KiCad layout (`<Lib>.kicad_sym` flat, `<Lib>.pretty/
<Name>.kicad_mod` nested) — that's the exact shape `libcheck.py`'s
`resolve_footprint`/`list_symbol_libs` expect, and the shape a real KiCad
global library table uses.

### Why per-file pinning, not the GitLab archive-subpath mechanism

GitLab offers two ways to fetch part of a repo at a tag:

1. **`/-/raw/<tag>/<path>`** — a single static blob, served with
   `Accept-Ranges: bytes` (resumable), byte-stable for an immutable tag ref.
   Trivial to sha256-pin; trivial to fetch with a plain `net/http` GET.
2. **`/-/archive/<tag>/<project>-<tag>.tar.gz?path=<subdir>`** — a
   dynamically-generated tarball of a whole subtree. Would let one lock entry
   pull an entire `*.pretty` library (hundreds of footprints), but the archive
   is generated per-request — no guaranteed stable ETag/Content-Length for
   Range-resume — and verifying it means unpacking tar+gzip just to reach a
   handful of curated files.

Since this round's subset is intentionally curated (not "the whole library"),
per-file pinning wins outright: every entry is independently resumable*,
verifiable with nothing more than `net/http` + `sha256`, and matches the
curated-subset intent directly. *Resumability itself (HTTP Range requests) is
not implemented in `FetchAll` this round — entries are small enough (the
largest symbol lib is ~6.7 MB) that a full re-GET on retry is acceptable; the
per-file URL shape is what makes adding Range support a small, later,
non-breaking addition if a future child wants it. A future child that wants
**whole-library** mirroring should revisit option 2.

### Why KiCAD tag `9.0.9.1` (not the newer `10.0.4`)

KiCad 10's `kicad-symbols` repo reorganized: each library that used to be one
flat `<Name>.kicad_sym` file is now a `<Name>.kicad_symdir/` **directory** of
per-symbol files. `kicad-footprints` did **not** undergo the equivalent split.
`9.0.9.1` is the newest stable tag where both repos still use the flat
single-file-per-library `.kicad_sym` shape `libcheck.py` reads (and that most
KiCad installs in the field still expect). A future child adding
`.kicad_symdir` support to `libcheck.py` can move the pin forward.

### Refreshing the lock (`pcb/scripts/gen_libraries_lock.py`)

Refresh = rerun + review diff — never a silent update:

```bash
python pcb/scripts/gen_libraries_lock.py --tag <new-tag>
git diff pcb/libraries.lock.json   # review URLs/sha/size changes before committing
```

The curated library/footprint lists (`SYMBOL_LIBS`, `FOOTPRINT_FILES`) live at
the top of the script — widening the subset means editing those lists, not
this doc.

## The Go-side fetcher (`pcb/internal/libraries/`)

`FetchAll(lockPath, destDir, notify)`:

- **Idempotent** — an entry already present at its destination with a matching
  sha256 is skipped without a network request.
- **Atomic** — each file downloads to a temp file in the same directory as its
  destination (`os.CreateTemp` + streaming sha256 via `io.TeeReader`), and is
  `os.Rename`d into place only after the hash matches. A mismatch or a
  mid-stream I/O error removes the temp file and leaves any prior destination
  file untouched.
- **Never fails the whole batch for one bad entry** — per-entry failures land
  in `FetchResult.Failed[{name,reason}]`; `FetchAll` only returns a top-level
  error for a lock-manifest problem (missing file, malformed JSON, zero
  entries) that makes the whole run meaningless.
- **Progress** — `notify(event, detail)` fires `start`/`skip`/`fetched`/
  `failed`/`summary` events; the MCP tool wiring (`pcb/internal/tools/
  libraries_tools.go`) forwards `failed`/`summary` to `host.notify` (the same
  toast pipe `main.go` already uses for worker errors).

`GetStatus(lockPath, destDir)` re-verifies every entry's sha256 without
fetching anything, returning `{present, version_tag, entries_verified,
total_entries, missing[]}` — a tampered/corrupted file on disk is **not**
counted as verified (re-hashed, not just checked for existence).

## MCP tools

| Tool | Args | Returns |
|---|---|---|
| `pcb_fetch_libraries` | none | `{tag, fetched:[names], skipped:[names], failed:[{name,reason}]}` |
| `pcb_library_status` | none | `{present, version_tag, entries_verified, total_entries, missing:[names]}` |

Both are **in-process** Go tools (no Python worker round-trip) — the fetch is
plain `net/http`, and status is a local sha256 re-verify.

## Data directory

Library data lands under `libraries.DefaultDir()` =
`<plugin data dir>/libraries`, where `<plugin data dir>` is resolved exactly
like every other plugin path in this monorepo — `shared/runtime.DataDir("pcb")`
(honors `MINERVA_PLUGIN_DATA_DIR`, the env var Minerva sets at plugin spawn;
falls back to the per-OS default, e.g. `%APPDATA%/Minerva/plugins/pcb` on
Windows). This is the same resolution CAD uses for its extracted Python
runtime — no new host-side signal was needed.

`pcb/libraries.lock.json` is resolved relative to the plugin root (the
directory containing `manifest.json` / the running `pcb-plugin` binary) via
`os.Executable()` — the same `pluginRootDir()` helper `main.go` already used
for the worker's dev-mode `.venv` lookup.

## Offline / absent-data contract

- **`pcb_fetch_libraries` with no network**: the per-entry HTTP error lands in
  `FetchResult.Failed[{name,reason}]` with a clear message (e.g. connection
  refused / DNS failure) — the tool call itself never errors out or crashes;
  the reply always has the `{tag, fetched, skipped, failed}` shape so a caller
  can inspect exactly which entries failed and retry.
- **`pcb_check_libraries` / `pcb_check_bom` with no library data present**:
  return the pre-existing `missing_data:true` contract (unchanged shape),
  **plus** a `hint` field — `"No KiCAD library data found under lib_dir. Run
  pcb_fetch_libraries first, then retry..."` — so an LLM caller knows exactly
  what to do next. This fires whenever `lib_dir` is absent, blank, or points
  at a directory that doesn't exist yet; it never fires as a crash.
- **Auto-resolution**: `pcb_check_libraries`/`pcb_check_bom` no longer require
  the caller to know the fetch destination path — the Go router
  (`internal/tools/worker_tools.go`'s `withDefaultLibDir`) fills in
  `libraries.DefaultDir()` whenever the caller omits `lib_dir` (or passes an
  empty/whitespace string). An explicit caller-supplied `lib_dir` is never
  overridden — this only changes behavior for callers who weren't passing one
  at all, where the old behavior was always `missing_data:true`.

## Worker-side reading (`pcb_worker/libcheck.py`)

- **Footprints** — existence-only: `.pretty` dirs of `.kicad_mod` files, no
  content parsing. `"Lib:Name"` → `<lib_dir>/Lib.pretty/Name.kicad_mod`; a bare
  `"Name"` is searched across every `*.pretty` dir. **Required** per
  board-yaml's footprint field — every board component that declares a
  footprint gates `check_libraries`'s `ok`.
- **Symbols** — a cheap single-pass paren-depth scan over `.kicad_sym` s-expr
  text, collecting only **top-level** `(symbol "Name" ...)` entries (a part's
  own definition), never the nested per-unit sub-symbols KiCad emits inside
  each part (`"R_0_1"`, `"R_1_1"`, ...) for multi-unit/de-morgan graphics. No
  real s-expression parser. **Optional** — the canonical board-yaml schema has
  no first-class `symbol` field (components reference footprints, not
  symbols); a component may carry one via the schema's `Extra` passthrough,
  and a miss there lands in `check_libraries`'s `missing_symbols[]` as a soft
  signal that never affects `ok`.
- **`check_bom` suggestions** — `difflib.get_close_matches` against every
  present footprint's bare name, surfaced as `suggestions[]` on BOM items
  whose footprint doesn't resolve.

## Out of scope

- **User/commercial libraries.** This subset is KiCAD's own official
  libraries only. Project-specific or vendor libraries are a future child
  (likely an additional, user-supplied `lib_dir` layered alongside the fetched
  common set — `libcheck.py`'s functions already accept an arbitrary
  `lib_dir`, so this is additive, not a rework).
- **Whole-library mirroring.** See "per-file pinning" above — revisit the
  archive-subpath mechanism if a future child wants every footprint in a
  `.pretty` dir, not a curated handful.
- **`.kicad_symdir` (KiCad 10+ per-symbol-file libraries).** Tracked as the
  reason this round pins tag `9.0.9.1`, not `10.0.4`.
- **Symbol-to-footprint cross-referencing** (`fp-lib-table`/`sym-lib-table`
  association logic, footprint-filter matching). Out of scope — this round
  only checks existence.
