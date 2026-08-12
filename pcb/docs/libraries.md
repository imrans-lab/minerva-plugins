# KiCAD library-data subset (`minerva_pcb_fetch_libraries` / `minerva_pcb_check_libraries` / `minerva_pcb_check_bom`)

KiCAD's symbol and footprint libraries are plain **s-expression data files** —
no KiCAD install, EDA license, or binary is needed to read them. This round
makes `minerva_pcb_check_libraries`/`minerva_pcb_check_bom` do real work by giving them real
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
fetched at runtime by `minerva_pcb_fetch_libraries` into the plugin's data directory
(see "Data directory" below). Hand-authored test fixtures are the one
exception — `pcb/worker/tests/testdata/fixture_lib/` is a tiny, deliberately
tiny (2 symbols, 2 footprints) fixture written by hand for unit tests, not a
copy of real KiCAD library content.

## The OTHER lock: `pcb/library/footprints.lock.json` (acquisition lock v2)

Do not confuse the two locks — they are independent verticals:

- **`pcb/libraries.lock.json`** (this doc, above): the runtime-FETCHED official
  KiCAD subset. Existence/BOM checking only; bytes never committed.
- **`pcb/library/footprints.lock.json`**: the SEED library's acquisition lock.
  Its `.kicad_mod` files ARE committed (vendored text — no-FCIB forbids
  binaries and bulk mirrors, not curated hand-vetted text), and the worker's
  `resolve_footprint`/`compile_board` read REAL GEOMETRY from them.

Since DCR 019ff567f66b (B0) the acquisition lock is **schema v2**:
`{"schema_version": 2, "entries": {ref: entry}}`. Each entry carries the v1
pin (`path`/`sha256`/`size_bytes`) plus provenance: `source_kind`
(`official_kicad|vendor_export|git|url|hand_authored|generated`),
`source_ref`, `license`, `retrieved_at`, `layer`, and reserved slots
(`original_source_path`, `converter_version`, `model3d_ref`, `assembly`
with MPN/distributor part numbers/package/orientation convention, `bless`).
`pcb_worker.footprints.load_lock_document()` is the one loader: it accepts a
v1 flat file read-only (normalized, `schema_version: 1`) and refuses anything
else fail-closed. The census test
(`worker/tests/test_library_lock.py`) walks the shipped lock and fails on any
entry missing provenance or whose vendored bytes drifted from the pin — the
same predicate the marketplace NOTICE gate (B6) enforces at release.

## The LAYER CHAIN: seed → user → project → WIP (S9)

A ref does not resolve from one root and one lock. It resolves from an ORDERED
CHAIN of **layers**, each a complete, independently-pinned library
(`pcb_worker.footprints.LibraryLayer`: `name`, footprint `root`, its own
`lockfile`, and an optional `profile_root`):

| layer | precedence | what it is |
|---|---|---|
| `wip` | highest | the scratch library an author is actively editing |
| `project` | | libraries that travel with the open project |
| `user` | | the user's own parts, in the plugin data dir |
| `seed` | lowest | the shipped `pcb/library/` above — always present |

Lookup walks the chain **highest-precedence-first**, and the **first layer whose
LOCK CONTAINS the ref supplies it**. Two rules make that safe:

- **Anti-shadowing.** Once a layer is chosen it is FINAL: if its file is missing
  or its bytes disagree with ITS pin, the ref is REFUSED (a
  `FootprintLookupError` naming the ref and the layer). It does *not* fall
  through to a lower layer. Falling through would fabricate the seed part under
  the name of the override the author asked for — invisible in every output,
  which is the whole failure a pinned library exists to prevent.
- **The seed is the base.** A caller lists only the layers it ADDS;
  `normalize_library_layers` appends the shipped seed. An override layer can
  shadow a seed part, never delete one.

**Manufacturer profiles resolve through the same chain** (owner ruling): each
layer's profile directory is the sibling `profiles/` of its footprint root —
for the seed, exactly today's `pcb/library/profiles/`. Same first-hit-wins, same
no-fall-through: a malformed override profile is refused, never replaced by the
seed's profile of the same id.

The chain arrives as a PARAMETER (`compile_board(..., library_layers=…)`,
`normalize_board(..., library_layers=…)`, `resolve_footprint(..., layers=…)`),
not from a config file the worker reads. **The default is the seed layer alone**,
which is byte-for-byte the pre-S9 single-root behaviour — every existing call
site keeps its exact results, error strings included, with no edit.

Which layer supplied a footprint is recorded on `Provenance.library_layer` (and
on `LoadedRuleProfile.layer` for profiles). It is carried BESIDE the parsed
footprint (`ResolvedFootprint.layer`), never inside it, so it cannot reach
`FootprintDefinition.content_id`, the pad dicts the emitters serialize, or a
profile's digest — recording the layer moves no fabricated byte.

### The LIVE chain: what a real call actually resolves through (B7)

Every compile-bearing MCP tool (`gerbers`, `generate`, `drc`, `drc_geometric`,
`resolve`, `normalize`, `route`, `mask_view`, `assembly_check`, `board_health`,
`promote_check`, and the panel's board-load `resolve_best_effort`) resolves
through the chain the **Go broker** injects per call
(`worker_tools.go::withLibraryChain`), never through caller-supplied paths:

- `wip_root` → `<data dir>/library_wip`, whose **BLESSED** entries top the
  chain (`bless.live_library_chain` → `blessed_library_chain`; a raw WIP view
  cannot enter — `normalize_library_layers` refuses the name in
  `library_layers`, and an unauthorized `LoadedLibraryLayer` is refused at
  resolution by the capability bit).
- `library_layers` → the durable layers this host has. Today that is the
  **user layer** at `<data dir>/library_user` (root
  `library_user/footprints/`, lock `library_user/footprints.lock.json`,
  profiles `library_user/profiles/` by the sibling convention), included
  exactly when its lock exists on disk. Presence is decided in Go, where
  absence is a fact; a layer that is CONFIGURED but whose lock will not load
  is refused worker-side (anti-shadowing), never demoted to "absent".

Both keys **always override** whatever the caller sent — including with an
empty layer list. Library roots are read sources for fabrication geometry, so
honoring a caller path would let an LLM compile against footprint bytes and a
lock it authored itself, around the bless gate. Same trust rule as
`withWIPRoot`: the host owns paths; the agent chooses the board, never the
library. The worker's single reader of these keys is
`methods._layer_params`; WIP travels ONLY as `wip_root` (footprints only —
manufacturer profiles keep resolving through `library_layers`, so a staged
part can never smuggle a manufacturing floor).

The project layer has **no live anchor yet**: boards travel over the bridge as
content, not paths, so there is nothing host-known to be "board-adjacent". The
worker accepts a `project` layer mapping already; wiring it becomes possible
when boards gain a host-known location.

### PROMOTION: out of WIP, into the user layer (B7)

`minerva_pcb_footprint_promote` (`{ref, overwrite?}`) is the bless gate's exit
door. Blessing makes a staged part resolvable *while it stays staged*; the WIP
layer is staging, not a library (S3 ruling), so a part you intend to keep
**graduates**: `bless.promote_footprint` MOVES the file and its lock entry —
bless record, provenance, assembly metadata intact, only `layer` rewritten to
`user` — into `<data dir>/library_user`, and frees the staging slot. Both
roots are host-forced (`withPromoteRoots`), same write-anywhere argument as
staging.

Refusals, all before any write: not staged; staged but not blessed-approved
(never reviewed OR explicitly rejected); the staged bytes no longer hash to
the blessed pin (rot must not be laundered under a blessed entry); the
destination lock is not schema v2; the ref already exists in the user library
without `overwrite:true`. Write order (dest file → dest lock → WIP entry
removed → WIP file unlinked) makes every crash window inert: the worst cases
are an orphan file no lock references, or the ref present in BOTH layers with
identical pinned bytes (WIP outranks user; re-running converges).

The user-facing loop this completes: *"override footprint X with my measured
version"* → `footprint_stage` (hand_authored) → `footprint_report` → review →
`footprint_bless` (artifact-bound) → **`footprint_promote`** → every board
that names X now resolves the override from the user layer, provenance says
so, and `library_lock_ref` digests the whole chain that could have supplied
it.

## RENDERED BLESS: the library trust boundary (S3)

The coincidence guard (`minerva_pcb_resolve`) compares a declared pin position
against the resolved pad's **centre**. That is a real check and it is nowhere
near a trust boundary: it says nothing about pad size, shape, drill diameter,
courtyard, or pad *numbering*. A footprint whose pads are all half a millimetre
too small, or whose pins 1 and 2 are swapped, passes coincidence and fabricates
garbage.

So the trust boundary is **a human comparing a RENDERED footprint and a FACT
TABLE against the datasheet**. `pcb_worker/bless.py` produces both artifacts,
records the verdict in the acquisition lock's `bless` slot, and — the part that
makes it a boundary rather than a checklist — makes an unblessed part unable to
supply copper.

### Tiering — who has to look

| `source_kind` | tier | why |
|---|---|---|
| `official_kicad` | `auto` | upstream is itself reviewed and mass-verified; hand-blessing each entry buys nothing and trains the reviewer to click through |
| `git` / `url` / `vendor_export` | `human` | third-party text of unknown review depth |
| `generated` | `human` | a synthesizer's output is only as good as its generator |
| `hand_authored` | `human` (the render check is THE control) | we typed the numbers; nothing upstream reviewed them |

`bless.AUTO_BLESS_SOURCE_KINDS` is the single authority for that split.
`bless_footprint` **refuses** a manual verdict on an auto-tier entry instead of
accepting and ignoring it, so the lock can always distinguish parts a human
actually reviewed from parts policy trusted on provenance alone.

### The gate — why an unblessed ref cannot leak through any path

Two independent mechanisms, and **neither touches `resolve_footprint_layered`**:

1. **The WIP layer's lock VIEW excludes unblessed entries.**
   `bless.blessed_wip_layer(wip_root)` returns a `LoadedLibraryLayer` whose
   `lock` dict contains only entries whose `bless` is a well-formed *approved*
   record. `lookup_footprint_layer` picks the supplying layer purely by
   `ref in loaded.lock`, so an unblessed ref is **structurally absent** from the
   chain — there is no resolver branch that could serve it, because the resolver
   is never told it exists. It also fails safe: an unblessed override of a seed
   part resolves to the *seed* part (pinned, blessed), never to the staged bytes.
   `blessed_library_chain()` additionally refuses a caller who tries to pass a
   raw `wip` layer through `layers`, which is the only way to smuggle the
   unfiltered lock back in.
2. **`bless.resolve_wip_footprint()` refuses BY NAME.** Mechanism 1 alone would
   let a staged-but-unblessed ref fall silently through to a lower layer —
   correct, but silence reads as "my staged part is live" to the caller who just
   staged it. This entry point reads the raw WIP lock first and raises
   `BlessError` naming the ref and its state ("staged but not blessed",
   "REJECTED by …").

The raw, unfiltered WIP layer is **never returned by any public function**. It
is built privately for exactly one purpose: *rendering* an unblessed part so a
human can look at it. **Reporting sees staged content; resolution does not.**

A `rejected` verdict is *recorded*, not deleted: the entry stays staged and
stays unresolvable, so the rejection is durable evidence rather than a hole.
Re-staging a ref replaces its bytes and **resets `bless` to null** — new bytes
were never reviewed.

### The artifacts

`footprint_report(ref)` returns `facts` + `svg` + `not_rendered`:

- **`facts`** — pad count, pad numbers, per-pad `{number, type, shape, x_mm,
  y_mm, size, drill}`, courtyard/body bounding boxes, package identity, and the
  lock entry's `source_kind`/`license`/`source_ref`/`layer`. Coordinates are
  footprint-LOCAL with KiCad's **y-DOWN** sign — verbatim what the `.kicad_mod`
  says, so a reviewer can diff the table against the file. Bounding boxes are
  **centreline** geometry (no half-stroke added).
- **`svg`** — self-contained, no external references. It **negates y**, so the
  picture is a conventional top view with y up; x is **not** mirrored, so
  back-side geometry is drawn as seen *through* the board. Both facts are
  restated in a comment inside the SVG itself, because the SVG travels without
  this document. Pad local rotation is emitted as `rotate(+R)` in that frame,
  which is exactly KiCad's `radians(-R)`-in-a-y-down-frame convention
  (`pcb_worker/geometry.py`, pinned by `tests/test_rotation.py`) once y is
  negated; bounding boxes call `geometry.rotate_local_offset` directly, so the
  numbers and the picture cannot drift.
- **`not_rendered`** — every parsed element the picture omits, with a reason
  (paste-layer geometry, a KiCad-6 `start/end/angle` arc whose centre is
  ambiguous, an unmodelled pad shape, a polygon whose `(fill …)` the parser
  drops, the parser's own `unsupported` markers). **An empty `not_rendered` is
  the claim "this picture is complete"** — the only condition under which
  comparing it to a datasheet checks the whole part. A renderer that silently
  skipped an unmodelled primitive would hand a reviewer a picture that looks
  finished and is not, and the reviewer would sign it.

`artifact_sha256` binds the WHOLE review artifact: it digests the staged
bytes' content sha + the complete fact table + `not_rendered` + the SVG. The
report returns it, the bless record stores the value regenerated *at bless
time* (so a footprint that cannot be rendered cannot be blessed), and — the
binding half (Codex 1160) — a HUMAN-tier bless must pass
`expected_artifact_sha256`, the digest of the report the reviewer actually
looked at. If the staged content changed between review and bless, the two
digests disagree and the bless REFUSES with the entry untouched: an approval
never transfers to an artifact nobody saw. Fab-affecting pad fields the SVG
cannot depict (mask/paste margins) are fact rows plus explicit
`not_rendered` entries, so two parts differing only in mask geometry are
never review-identical.

`bless.py` never reads the clock: `blessed_at`/`retrieved_at` arrive from the
caller. `methods.py` is the one place "now" enters (defaulted when the tool call
omits it), so the library stays a pure function of its arguments.

## ACQUISITION: official KiCad on demand (S4)

`minerva_pcb_acquire_footprint {ref: "LibNick:PartName"}` gets ONE official
footprint that the curated subset never listed, and leaves it usable.

**The flow — Go fetches, the worker stages.**

1. **Go** (`internal/libraries/acquire.go`) validates the ref shape (the same
   refusals `bless.py`'s `_split_ref` makes — the ref becomes a URL path here and
   a file path there, so both sides refuse separators and traversal), reads the
   release tag and footprints repo **out of `libraries.lock.json`**, and GETs
   `<repo>/-/raw/<tag>/<Lib>.pretty/<Name>.kicad_mod` — byte-identical addressing
   to what `scripts/gen_libraries_lock.py` writes into the lock. The tag is
   **read, never restated in code**: a literal here would be a second authority
   that disagrees with the lock the moment the lock is regenerated, and the
   disagreement would surface as parts from two different releases in one board.
   Status must be 200, the body must be under 1 MiB, valid UTF-8, and an
   s-expression headed by `footprint`/`module` — a locked entry gets its content
   sanity free from its recorded sha256, an acquired part has no recorded sha
   (that is what acquiring means), so an HTML sign-in page served with status 200
   has to be refused by shape. Go computes the sha256 of the wire bytes.
   **Nothing is written on any path**, so "refused" and "wrote nothing" are the
   same statement.
2. **The worker** (`methods.py` `footprint_acquire_store`) cross-checks its own
   sha256 of the arrived text against the sha Go reported
   (`bless.cross_check_fetched_sha256`) — two independent derivations of one
   file, either side of the bridge — then runs the **existing B2 machinery**:
   `stage_footprint` (parse-validate, atomic write, sha-pin) followed by
   `auto_bless_footprint`. `source_kind` is fixed to `official_kicad` **by the
   method**, never taken from params: a caller-supplied provenance would turn
   this into a general auto-bless doorway. The cross-check runs *before* staging,
   so a mismatch writes nothing at all.

Stage and bless are fused into one call because the pair is not independently
useful here: the fetch has already established the only thing the auto tier rests
on, so a caller left holding a staged-but-unblessed entry between two calls would
have nothing to decide.

**The offline contract.** Acquisition is the ONLY library operation that touches
a network, and it is the only one that can. Resolution — every compile, DRC,
gerber and report path, in the worker — reads sha-pinned bytes off disk and never
opens a socket. A fetch failure is therefore reported as a failure to acquire
*this part*, naming the URL and saying so; existing boards keep resolving. (The
manifest's `permissions.network.mode` is already `unrestricted` from the original
fetcher work and is unchanged by this station; the tool's own description
discloses the outbound HTTPS to gitlab.com.)

**ENDGAME — where this leaves `libraries.lock.json`.** Per-footprint acquisition
entries supersede the existence-only lock: an acquired entry carries the bytes,
the sha, the provenance and the bless verdict, where `libraries.lock.json` only
ever answered "is this file present". From this station the existence-only lock
is **READ-ONLY** — acquisition reads its `tag`/`source.footprints_repo` and
writes nothing back to it. It retires once `check_libraries`/`check_bom` answer
from acquired entries **without regression** (parity, measured, not assumed).
That is a **future station, not this one**: `minerva_pcb_fetch_libraries` and
`minerva_pcb_library_status` keep working exactly as documented above until then.

## LICENSE INVENTORY / NOTICE (S5)

`pcb/NOTICE.md` is the **marketplace-release** license and attribution
inventory for the seed library's acquisition lock
(`pcb/library/footprints.lock.json`, above). It is **generated, never
hand-edited**, by `pcb/scripts/gen_notice.py`, which reads the SAME one
authority the census test (`test_library_lock.py`) reads —
`pcb_worker.footprints.load_lock_document` and `LOCK_SOURCE_KINDS` — and
renders one section per distinct `license`, each listing every entry's ref
and `source_ref` (plus `provenance_note` when present), with third-party
sections stating the attribution obligation plainly (e.g. CC-BY-SA-4.0 WITH
KiCad-libraries-exception for the KiCad-derived entries, Apache-2.0 for the
Espressif entry). Output is deterministic — sorted refs, no timestamps, no
environment data — so regenerating over an unchanged lock is byte-identical.

Regenerate with:

```bash
python3 pcb/scripts/gen_notice.py
git diff pcb/NOTICE.md   # review before committing, same discipline as the libraries lock
```

**Gate semantics — dev census vs. release gate, and why they differ on
purpose.** `test_library_lock.py`'s census is a **dev** gate: it fails an
entry with an empty license, but accepts ANY non-empty string, including one
a human staged as `"UNKNOWN — pending legal review"` while an attribution
question is still open — the right behavior day-to-day, since an
in-progress entry should not block every unrelated PR. `gen_notice.py` is
the **release** gate: it refuses (exit 1, naming every offending ref) an
entry whose `source_kind`/`license`/`source_ref` is empty, whose
`source_kind` falls outside `LOCK_SOURCE_KINDS`, or whose `license` contains
`"UNKNOWN"` (case-insensitive) anywhere in it — the same entry the census
lets through cannot reach a shipped NOTICE while its license stays
unresolved. `gen_notice.py --check` writes nothing and exits 1 on either a
gate refusal or drift between the committed `pcb/NOTICE.md` and a fresh
generation; CI's `fab-gate` job runs this mode on every push and PR under
`pcb/**`, and `test_notice.py`'s shipped-lock test pins the same drift check
so it is caught even where CI is skipped.

**Marketplace co-design.** The release pipeline (docket `019f985bd921`)
reads license/attribution data from **this same acquisition-lock v2
schema** — `source_kind`/`license`/`source_ref`/`retrieved_at` on every
entry — rather than a separate manifest either side maintains
independently. Widening the lock's provenance vocabulary is a schema change
both sides pick up; adding a footprint with a new license is just a new
lock entry, and `gen_notice.py` picks up a new `## <license>` section
automatically the next time it runs.

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
| `minerva_pcb_fetch_libraries` | none | `{tag, fetched:[names], skipped:[names], failed:[{name,reason}]}` |
| `minerva_pcb_library_status` | none | `{present, version_tag, entries_verified, total_entries, missing:[names]}` |
| `minerva_pcb_footprint_stage` | `{ref, kicad_mod_text, source_kind, source_ref, license, retrieved_at?, provenance_note?}` | `{ref, entry, report:{facts, not_rendered, svg_sha256}}` |
| `minerva_pcb_footprint_report` | `{ref, max_svg_bytes?}` | `{ref, facts, not_rendered, svg, svg_sha256, svg_bytes, svg_truncated}` |
| `minerva_pcb_footprint_bless` | `{ref, verdict?, who?, blessed_at?}` | `{ref, entry, report:{…}}` |
| `minerva_pcb_acquire_footprint` | `{ref}` | `{ref, layer:"wip", sha256, source_ref, license, bless, entry, report_summary:{…}}` |

The first two are **in-process** Go tools (no Python worker round-trip) — the
fetch is plain `net/http`, and status is a local sha256 re-verify. The three
`footprint_*` tools are **worker-backed**, forwarding to the worker's
`footprint_stage`/`footprint_report`/`footprint_bless` methods.
`minerva_pcb_acquire_footprint` is **both**: an in-process HTTPS fetch (network
code is Go-only in this plugin — the worker never fetches) followed by a call to
the worker's `footprint_acquire_store`, which stages and auto-blesses through
that same B2 machinery. See *ACQUISITION* above.

`wip_root` is deliberately **absent from those tools' schemas**: the Go handler
forces it to `<plugin data dir>/library_wip` on every call, *always overriding*
any caller value (unlike `lib_dir`, which honours an explicit one). It is a
write destination derived from a ref the caller also controls, so honouring a
caller-supplied root would turn `minerva_pcb_footprint_stage` into a
write-anywhere primitive for an LLM. The host owns the directory; the agent
chooses the part, never the path.

## Data directory

Library data lands under `libraries.DefaultDir()` =
`<plugin data dir>/libraries`, where `<plugin data dir>` is resolved exactly
like every other plugin path in this monorepo — `shared/runtime.DataDir("pcb")`
(honors `MINERVA_PLUGIN_DATA_DIR`, the env var Minerva sets at plugin spawn;
falls back to the per-OS default, e.g. `%APPDATA%/Minerva/plugins/pcb` on
Windows). This is the same resolution CAD uses for its extracted Python
runtime — no new host-side signal was needed.

The **WIP staging library** (S3, above) is that directory's sibling:
`<plugin data dir>/library_wip`, resolved by `tools.wipRootDir()` through the
same `shared/runtime.DataDir("pcb")` call. Its layout mirrors the shipped seed
exactly — `footprints/<Lib>.pretty/<Name>.kicad_mod` beside a
`footprints.lock.json` (schema v2) — so a staged library *is* a library: it can
be promoted to the `user` or `project` layer by moving a directory, with no
rewriting, and `LibraryLayer.profiles`' sibling convention lands on
`<wip_root>/profiles` the same way the seed's does.

`pcb/libraries.lock.json` is resolved relative to the plugin root (the
directory containing `manifest.json` / the running `pcb-plugin` binary) via
`os.Executable()` — the same `pluginRootDir()` helper `main.go` already used
for the worker's dev-mode `.venv` lookup.

## Offline / absent-data contract

- **`minerva_pcb_fetch_libraries` with no network**: the per-entry HTTP error lands in
  `FetchResult.Failed[{name,reason}]` with a clear message (e.g. connection
  refused / DNS failure) — the tool call itself never errors out or crashes;
  the reply always has the `{tag, fetched, skipped, failed}` shape so a caller
  can inspect exactly which entries failed and retry.
- **`minerva_pcb_check_libraries` / `minerva_pcb_check_bom` with no library data present**:
  return the pre-existing `missing_data:true` contract (unchanged shape),
  **plus** a `hint` field — `"No KiCAD library data found under lib_dir. Run
  minerva_pcb_fetch_libraries first, then retry..."` — so an LLM caller knows exactly
  what to do next. This fires whenever `lib_dir` is absent, blank, or points
  at a directory that doesn't exist yet; it never fires as a crash.
- **Auto-resolution**: `minerva_pcb_check_libraries`/`minerva_pcb_check_bom` no longer require
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
