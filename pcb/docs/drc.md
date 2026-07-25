# PCB design-rule checking (three surfaces)

The worker exposes **three distinct DRC surfaces**. They answer different
questions and must not be confused: a pass on one is not a pass on the other.
Every reply carries a `scope` token, and no two are spelled alike.

| | `drc` (`_drc`) | `drc_geometric` (`_drc_geometric`) | candidate overlay (`ir_candidates`) |
|---|---|---|---|
| MCP tool | `minerva_pcb_pcb_drc` | `minerva_pcb_pcb_drc_geometric` | attached to `route()` |
| `scope` | `"connectivity"` | `"geometric"` | `"geometric_candidate"` |
| What it reads | pad **centers** + trace **centerlines** | real **copper + hole geometry** (the ResolvedBoard IR) | the same, over base copper **+ proposed** copper |
| Question | is the net **topology/connectivity** sane? | is the **copper geometrically** legal? | does **this proposal** introduce a geometric violation? |
| Kernel | `pcb_worker.drc` (`run_drc`) | `pcb_worker.drc_geometric` (`run_geometric_drc`) | the same kernel, unchanged |
| Reply shape | legacy `{ok, result:{findings, counts}}` | the geometric **result union** (see below), verbatim | the **candidate union** (see below) |

## `drc` — connectivity / topology (legacy, NOT geometric)

`_drc` runs the centerline checker over a best-effort-resolved board. It reasons
about pad centers and trace centerlines only, so it **cannot verify a clearance,
a trace width, or an annular ring**. Its findings are connectivity faults:
`wrong_net_pad` (endpoint on a different-net pad → short), `crossing` (two
different-net traces intersect), `dangling_endpoint` (a leaf endpoint reaching no
pad/via → open), `layer_change_no_via` (missing via). **A zero-finding `drc`
result is a topology pass, not a proof the copper is geometrically clean.**

## `drc_geometric` — geometric copper DRC (IR-based, fail-closed)

`_drc_geometric` parses the board, compiles it to the **ResolvedBoard IR**
(`compile_board.compile_board`), and runs the pure geometric kernel
(`run_geometric_drc`) over real copper/hole shapes. Checks:

- **GC1** min trace width
- **GC2** copper-to-copper clearance (same canonical layer, same-net exempt)
- **GC3** drill / finished-hole minimums — the finished-hole check is a
  *necessary pre-DFM condition only*: the ResolvedBoard IR carries the **drill**
  diameter, not the plated finished bore, so `drill < min_finished` always fails,
  but a drill that clears the floor is **not** certified finished-clean (that is
  DFM's job)
- **GC4** annular ring
- **GC5** copper-to-edge inset
- **GC6** hole-to-hole spacing

### Result union (returned verbatim — not the `{ok, result}` wrapper)

- **Determinate** (compile succeeded):
  `{ok:true, scope:"geometric", verifies_geometry:true,
  verdict:"clean"|"violations", findings:[…], counts:{…}, warnings:[…],
  board_id, source_digest, rule_profile}`.
- **Indeterminate** (compile failed, or the kernel met geometry it cannot
  model — a non-rectangular outline, a copper zone/pour, …):
  `{ok:false, scope:"geometric", verifies_geometry:false,
  verdict:"indeterminate", error:{kind, message, diagnostics}}` — carrying **no**
  `clean`/`findings`/zero-counts a caller could mistake for a pass. `kind` is
  `unresolved_geometry` when the board parsed but would not compile/resolve
  (unknown footprint, sizeless pad), or `unsupported_geometry` when the kernel
  met geometry it does not model — a non-rectangular outline, a copper zone/pour,
  a via **per-layer padstack** (019f95893989), a copper **board/placed graphic**
  (019f95897086), or a **net-class** width/clearance minimum (019f958b45b9) — or
  `internal` on an unexpected fault.

Every failure at the method boundary returns the **same** indeterminate union
(docket 019f9589b232) — there is no bespoke third shape. A board that will not
**parse** at all is `error.kind:"parse"`, an unexpected `compile_board` exception
is `error.kind:"internal"`, and both still carry
`scope:"geometric", verifies_geometry:false, verdict:"indeterminate"` with **no**
`clean`/`findings`/`counts`. Consumers branch on `verdict`, never on a separate
parse shape.

## Route DRC-at-propose is CONNECTIVITY-scoped (not geometric)

`route()` (docket 019f6f1492e0) attaches a per-route `drc` and a top-level
`drc_summary` to its result. **This is the connectivity/centerline checker
(`drc.run_drc`), not geometric copper DRC** — it cannot verify a clearance, trace
width, or annular ring. Both payloads therefore carry `scope:"connectivity"`
(docket 019f958aa6db):

- per route: `drc: {scope:"connectivity", clean:bool|null, violations:[…]}`
  (`clean:null` + `error` when the DRC engine itself faulted).
- top level: `drc_summary: {scope:"connectivity", clean:bool|null,
  violation_count:int, error?}`.

Consumers **must not** render this as a generic/geometric "DRC clean". The UI
chip (`ui/PCBPanel.gd` `_drc_status_suffix`) reads the scope and renders
"Connectivity clean" / "Connectivity: N violation(s)". The geometric complement
is the candidate overlay below — added **beside** this payload, never replacing
it.

Since Round E1 (`019f97d021a8`) its pad census comes from the **compiled IR**, via
`ir_connectivity.connectivity_board` — the same compile the router consumes, so
the two halves of one route reply cannot disagree about which pads exist. That is
a shared *census*, not shared geometry: the projection carries pad centers and net
ownership only, so this surface remains centerline-scoped exactly as above.

## Candidate overlay — geometric DRC **before** acceptance

`pcb_worker.ir_candidates` (docket `019f952b99f2`, closing bug `019f80b5124d`).

A routing proposal once ran a trace straight through the centre of a
different-net pad and the DRC attached to it reported **clean**. Geometric DRC
detects that fault precisely — it was simply never run, because it reads a
compiled board and a proposal is not yet in one. The overlay is the missing
projection: proposed segments/vias are layered onto the **compiled base
ResolvedBoard** as ordinary IR traces/vias, and the **unchanged** kernel runs
over base + candidates.

**It reimplements no rule.** There is no clearance/width/annular math in
`ir_candidates`. Because the overlay is built at the *IR* level, candidate copper
is projected by `drc_geometric.project_board` itself — the same trace-capsule and
via-land construction an accepted trace gets — so **propose-time and post-accept
agree by construction**, and the kernel's fail-closed guards (zones, copper
graphics, per-layer via padstacks, net-class minima) keep protecting this surface
for free. The kernel is never given knowledge of candidates.

### Candidate union

- **Determinate**: `{ok:true, scope:"geometric_candidate",
  verifies_geometry:true, verdict:"clean"|"violations", findings, counts,
  per_candidate, baseline, board_id, source_digest, rule_profile, warnings}`.
- **Indeterminate**: the same envelope every other geometric failure uses
  (built by `drc_geometric.geometric_indeterminate`, re-scoped):
  `{ok:false, scope:"geometric_candidate", verifies_geometry:false,
  verdict:"indeterminate", error:{kind, message, diagnostics}}` — with **no**
  `findings`/`counts`/`per_candidate`/`baseline`/`clean`.

`verdict` is about the **candidates**: `"clean"` means *this proposal introduces
no geometric violation*, not *the board is clean*. A consumer can always tell
which of three things happened — (a) ran, clean; (b) ran, violations;
(c) could not run — and (c) can never be read as (a).

**Attribution.** Every candidate finding carries
`subjects: [{candidate_id, revision, segment_id|via_id}, …]`, plus
`{candidate_id:"board"}` when committed copper is the other party — the same
subject spelling `draft_check` uses. A canvas can therefore highlight the exact
ghost route that collides, and `source_digest` makes a stale result detectable.

**Baseline vs introduced.** A real board can already be geometrically dirty
(`smart_remote.yaml` carries 12 pre-existing violations, bug `019f989d3179`).
Findings naming at least one candidate entity are `findings`; everything else is
`baseline`, reported beside them and never charged to a proposal. That partition
*is* the delta: candidates only add primitives, GC1/GC3/GC4/GC5 are per-entity
and GC2/GC6 enumerate pairs, so no base-only finding can appear or disappear
because a candidate was added.

**Fail-closed, no approximated copper.** An unknown net, an unknown/foreign
copper layer, a zero-length leg, a segment with no declared width, a via with no
declared diameter/drill, or a duplicate `candidate_id` (which would make
attribution ambiguous) each make the whole reply indeterminate. Widths and via
sizes are never invented — see `docs/routing.md` for where `route()` sources
them.

### Safety invariant — never a false `clean`

The kernel is **fail-safe** (every modeled shape is exact or a superset of the
real copper, so a computed margin never exceeds the true margin) and
**fail-closed** (un-modelable geometry → indeterminate, never a silent skip).
`ok:true` means *the check ran to a verdict*, not *the board passed*.

### Corroborated against kicad-cli

The IR-native verdict is cross-checked against the external `kicad-cli pcb drc`
(KiCad 9.0.x) in `tests/oracle/test_kicad_drc_geometric_oracle.py`: a known
clearance short and a clean board are each rendered through the production IR
path (`kicad.generate_ir`) and confirmed to agree with kicad-cli over the
**intersection** of categories both engines implement (clearance, track width,
annular ring, hole-to-hole, copper-to-edge). This is a *corroboration* — the
kicad board is still a projection of our own IR — not a proof of full geometric
coverage.
