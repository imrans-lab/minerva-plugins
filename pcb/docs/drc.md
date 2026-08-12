# PCB design-rule checking (three surfaces)

The worker exposes **three distinct DRC surfaces**. They answer different
questions and must not be confused: a pass on one is not a pass on the other.
Every reply carries a `scope` token, and no two are spelled alike.

| | `drc` (`_drc`) | `drc_geometric` (`_drc_geometric`) | candidate overlay (`ir_candidates`) |
|---|---|---|---|
| MCP tool | `minerva_pcb_drc` | `minerva_pcb_drc_geometric` | attached to `route()` |
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

- **GC1** min trace width — per trace, against its **effective** width floor
- **GC2** copper-to-copper clearance (same canonical layer, same-net exempt) —
  per pair, against that pair's **effective** clearance floor
- **GC3** drill / finished-hole minimums — the finished-hole check is a
  *necessary pre-DFM condition only*: the ResolvedBoard IR carries the **drill**
  diameter, not the plated finished bore, so `drill < min_finished` always fails,
  but a drill that clears the floor is **not** certified finished-clean (that is
  DFM's job)
- **GC4** annular ring
- **GC5** copper-to-edge inset
- **GC6** hole-to-hole spacing

### Per-net-class minima (GC1/GC2)

`ManufacturingConstraints` carries the board's blanket floors, but a net may
belong to a `NetClass` naming a stricter `min_trace_width_mm` /
`min_clearance_mm`. A board **authors** its classes under
`design_rules.net_classes`, each entry naming its `members`.
`compile_board._build_net_classes` parses that block and returns the inverted
net-name -> class-id map; `compile_board._finalize_nets` is what assigns
`ResolvedNet.net_class_id` from it, and that per-net id is the link this section
reads. See
[`board-yaml.md`](board-yaml.md), "Net classes", for the authored schema — in
particular, only these two `min_`-prefixed values are authorable, for exactly the
reason given at the end of this list.

`_net_class_minima` builds the `net_id -> (width, clearance)`
map for every net that **references** such a class, and the two checks compare
against the raised floor: `_effective_min_trace_width` for GC1,
`_effective_min_clearance` for GC2. What follows from that:

- The class term only ever **raises** a floor (`max`), never relaxes one, so the
  global manufacturing minimum stays a hard lower bound.
- The clearance floor is per **pair**, not per primitive — the two participants
  can sit on different nets with different classes, so **both** class terms fold
  in. Copper with no net (`net_id is None`, e.g. plated board-hole copper)
  contributes none; the other participant's class still governs.
- Only **referenced** classes are read. A class defined on
  `design_rules.net_classes` that no net points at constrains nothing — the same
  rule `methods._net_class_overrides` applies on the routing side.
- The broad phase (`_broad_phase_pairs`) is swept at the board-wide **maximum**
  clearance floor, not the global one. Its pruning argument is only sound against
  the largest threshold any surviving pair could be compared to; sweeping at the
  global floor while a class demands more would discard a genuinely violating
  pair before it was measured.

  The sweep itself lives in `_sweep_pairs`, over bare boxes, and **GC8 uses the
  same kernel** (epoch CP2 S11) — the mask-sliver check was all-pairs while GC10
  next door already had an AABB gate. GC8's margin is simply
  `min_mask_sliver_mm`: it has no per-net-class term, so the maximum-threshold
  invariant above is satisfied trivially there. Equivalence with all-pairs is
  pinned on near-threshold geometry in `test_gc8_mask_sliver.py`, together with a
  non-vacuity test that the sweep is genuinely pruning — an equivalence test
  passes trivially against a broad phase that returns every pair.
- `NetClass.trace_width_mm`, `via_diameter_mm` and `via_drill_mm` are **nominal**
  routing/via sizes, **not** minima. They imply **no** per-class GC1, GC3 or GC4
  floor, and are deliberately not read — the same two `min_`-prefixed fields, and
  no others, that routing reads. This is settled, not pending.
- **Two fail-closed cases, one per dimension.** An unsourceable class minimum
  returns the indeterminate union, naming the class **and** the field — for
  `min_trace_width_mm` *and* for `min_clearance_mm`. Each goes through the same
  predicate routing admits that field with: `ir_candidates.positive_mm` for width
  ("zero-width copper is not copper"), `agent_router.router.nonnegative_mm` for
  clearance. Geometric DRC reads the same two fields off the same class, so it
  must not reach a different conclusion about a value than routing does.
  What differs between the dimensions is the **predicate**, not the
  fail-closed-ness: `min_clearance_mm: 0.0` is legal (a class may state zero
  clearance) and is then a no-op under `max`, while `min_trace_width_mm: 0.0` is
  not. That single value is the whole of the difference — a negative, NaN,
  infinite or non-numeric clearance fails closed exactly as a bad width does.

### Result union (returned verbatim — not the `{ok, result}` wrapper)

- **Determinate** (compile succeeded):
  `{ok:true, scope:"geometric", verifies_geometry:true,
  verdict:"clean"|"violations", findings:[…], counts:{…}, warnings:[…],
  board_id, source_digest, rule_profile}`.
- **Indeterminate** (compile failed, or the kernel met geometry it cannot
  model — a non-rectangular outer profile, unsupported board graphic, …):
  `{ok:false, scope:"geometric", verifies_geometry:false,
  verdict:"indeterminate", error:{kind, message, diagnostics}}` — carrying **no**
  `clean`/`findings`/zero-counts a caller could mistake for a pass. `kind` is
  `unresolved_geometry` when the board parsed but would not compile/resolve
  (unknown footprint, sizeless pad), or `unsupported_geometry` when the kernel
  met geometry it does not model — a non-rectangular outer profile,
  a via **per-layer padstack** (019f95893989), a copper **board/placed graphic**
  (019f95897086), or a referenced net class whose `min_trace_width_mm` or
  `min_clearance_mm` is not a sourceable value (see "Per-net-class minima" above)
  — or `internal` on an unexpected fault. A net class carrying *sourceable*
  width/clearance minima is **not** an indeterminate cause: those minima are
  applied (019f958b45b9).

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
(docket 019f958aa6db).

**Baseline vs introduced (docket 019f9cc386b6).** Like the geometric candidate
overlay below, this surface partitions findings into what the PROPOSAL
introduces and what the BOARD already had — a second `drc.run_drc` pass over
the *base* board (before the proposed routes) provides the split
(`pcb_worker.methods._attach_route_drc`, `ir_connectivity.partition_findings`).
`clean`/`violations`/`violation_count` above are PROPOSAL-scoped: they answer
"does accepting this introduce a connectivity violation?", exactly as the
candidate overlay's `verdict` is candidate-scoped. The board's own pre-existing
violations live under a sibling `baseline` key and are never folded into the
proposal-scoped numbers — a dirty board must not veto an honest proposal, and a
clean proposal must not launder a dirty board.

- per route: `drc: {scope:"connectivity", clean:bool|null, violations:[…],
  baseline:{…}}` (`clean:null` + `error` when the DRC engine itself faulted).
  `baseline` here is the board's pre-existing violations narrowed to this
  route's net (`_baseline_for_net`), and its determinate shape is
  `{clean:bool, violations:[…]}` — the ROUTE payload's vocabulary, matching
  its sibling `violations` key.
- top level: `drc_summary: {scope:"connectivity", clean:bool|null,
  violation_count:int, error?, baseline:{…}}`, whose determinate `baseline`
  shape is `{clean:bool, violation_count:int, findings:[…]}` — the SUMMARY
  payload's vocabulary.

**The two `baseline`s do not share their determinate key names**, and a reader
written for one is wrong on the other: the summary's carries
`violation_count`/`findings`, the per-route one carries `violations` and no
count at all. Copying `baseline.get("violation_count", 0)` from a summary
reader to a per-route baseline yields `0` for a net that HAS pre-existing
violations — the same silent zero this partition exists to prevent, arrived at
from the other direction. Count the per-route list; do not default a key that
was never there.

**What both shapes DO share is the indeterminate case** (the *base*-board DRC
run itself faulted): `{clean:null, error:str}`, with **no counts and no
findings/violations key at all**. That absence is deliberate: narrowing an
indeterminate baseline to `violation_count:0` (or to an empty `violations`
list) would render "the board is clean" for a board whose state could not be
determined. Consumers **must** branch on `baseline.clean is None` before
reading any count or list — see `ui/PCBPanel.gd` `_baseline_suffix` for the
fail-closed reference implementation.

**`baseline` is present on both determinate and indeterminate `drc_summary`.**
The *top-level* `clean`/`violation_count` follow the usual three-way rule
(`violation_count` is absent when `clean` is `null` — a check that did not run
has no count to report), but the `baseline` key itself is always attached, on
both branches: the base-board run is independent of the post-proposal run and
can succeed (and be reported) even when the post run faults and the proposal
question therefore has no answer. So checking `drc_summary.has("baseline")`
tells a consumer nothing — always branch on `baseline.clean is None` instead,
one level down.

Consumers **must not** render this as a generic/geometric "DRC clean". The UI
chip (`ui/PCBPanel.gd` `_drc_status_suffix`) reads the scope and renders
"Connectivity clean" / "Connectivity: N violation(s)" / "Connectivity:
unavailable", and appends a `" (pre-existing: N)"` or
`" (pre-existing: unknown)"` parenthetical for the baseline half to **all
three** (docket 019f9da15929).

That the parenthetical also rides the `unavailable` branch is the point, not an
accident: the base run and the post-proposal run fail independently, so
"`Connectivity: unavailable (pre-existing: 3)`" is a real and useful state —
the proposal could not be judged, but the board's own pre-existing state is
known and is being reported anyway. Withholding it because the other half
faulted would discard an answer that was successfully computed.

The geometric complement is the candidate overlay below — added **beside** this
payload, never replacing it.

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
graphics, per-layer via padstacks) keep protecting this surface for free. Candidate
copper is likewise measured against the **per-net-class** floors above, because
`_check_gc1_trace_width`/`_check_gc2_clearance` read the overlay board's own
`design_rules.net_classes` — a candidate on a net-classed net is checked at that
class's minima, not the board's blanket ones. The kernel is never given knowledge
of candidates.

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
