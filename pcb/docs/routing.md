# Canonical routing (IR-based, fail-closed)

Sibling of `docs/drc.md`. Since Round E1 (docket 019f783860c8) the canonical
`route` path **consumes the compiled ResolvedBoard IR or it does not route**.

## Why it fails closed

The owner-ratified Step-4 ruling puts routing in the fail-closed bucket:

> canvas DEGRADES (pins-as-dots + unresolved badge); ROUTING/DRC/CAM FAIL CLOSED.
> No approximated copper.

Before E1 the router was handed the RAW board and `route_bridge._pad_size_for`
returned a nominal `1.0 x 1.0` land for any pad with no authored geometry. That
land is smaller than most real packages, so the router computed keepouts around
copper the board does not have and could propose a trace straight through the
real package land. Accepted, that proposal becomes fabricated copper — precisely
what the ruling forbids. There is no honest size to invent, so the nominal
fallback is gone and every dimension now comes from the IR.

## The path

`_route` (canonical input) → `board_model.load_board` → **strict compile**
(`_compile_or_fail`, `requested_outputs=V1_ROUTING_OUTPUTS`) →
`route_bridge.resolved_board_to_router` → `agent_router`.

**Routing capability profile.** Routing compiles against `("copper", "drill",
"rules")`, not the full fabrication set: a solder-**mask** capability loss cannot
make a route unsafe and must not disable routing, while any dropped copper, drill
or rule stays fatal. It is a strict subset of `FABRICATION_CRITICAL_OUTPUTS`, so a
board that will not compile for routing will not compile for fabrication either.

## What comes from the IR

Position, rotation, side/mirror, copper-layer participation, net ownership, size,
shape and drill — all of it. Pad copper is shaped by
`ir_pads.pad_copper_shape`, the **same neutral owner** the CAM emitters fabricate
from and geometric DRC checks (`pad_source.placed_pad_to_geom` + `th_land`), so
routed keepouts, checked copper and fabricated copper cannot drift apart.

**Conservative envelopes.** `agent_router`'s `RoutingGrid.mark_pad` marks an
unrotated rectangle and **discards** the rotation argument it accepts. Handing it
a truthful `w/h` for a rotated elongated land would therefore under-block along
the rotated axes. It is handed the land's axis-aligned **bounding box** instead —
a strict superset of the real copper. Same invariant as the DRC kernel, restated
for keepouts:

> the modeled keepout must be a SUPERSET of the fabricated copper. Over-blocking
> is legal; under-blocking never is.

**Inflation composes with that superset, it does not replace it** (Round E2).
`RoutingGrid.keepout_margin` = `clearance + trace_width / 2`, and it is the
single owner of the term — **all three** markers go through it (`mark_pad`,
`mark_obstacle`, `mark_trace`), for the same reason `_pos_to_cell` is the single
owner of the world↔cell transform. A margin honoured in one marker and forgotten
in another is an under-block. Growing a box that already contains the rotated
copper still contains it, so the two over-blocks stack.

The half-width term is not decoration: the grid marks **centerline**-addressed
cells (the pathfinder tests one cell per step), so a trace centered exactly
`clearance` away from a pad still lays half its copper inside the clearance ring.
The same arithmetic applies to an already-routed trace, which is why `mark_trace`
now takes the **true copper width** and inflates it here rather than being handed
a pre-inflated `trace_width + 2 * clearance` by the engine: that literal reserved
a half-extent of `w/2 + clearance`, short by the newcomer's own `w/2`. The
correct half-extent — marked copper's half-width, the gap, the newcomer's
half-width — is exactly `w/2 + keepout_margin`.

Each marker writes two concentric regions: the copper itself
(`obstacle_type="pad"` / `"trace"`), and the ring around it as that copper's
reservation (`"pad_clearance"` / `"trace_clearance"`), under three rules that all
say the same thing:

| the ring meets | what happens | why |
|---|---|---|
| free space | claimed for the marker's net | a net owes no clearance to itself, so it may approach its own copper; everyone else is blocked |
| **copper** (pad or trace) | left alone | pads are marked in board order and traces as each net is routed; overwriting B's land with A's net would let A route straight through real copper |
| another **ring** of a different net | `net=None` — nobody passes | first-writer-wins would let that one net route within `clearance` of the other owner |

The precedence is **not** symmetric, and the asymmetry is deliberate: a ring never
overwrites copper, but a **copper** mark does overwrite a contested `net=None`
ring cell unconditionally. That is a weakening, and it is bounded — it is
reachable only where that net's own copper physically sits (plus at most the one
cell `_cell_range` over-claims, whose reasoning is recorded at that method). A
cell occupied by a net's real land is not a place any router could have kept that
net out of, so re-typing it as copper describes the board rather than relaxing a
rule. Under-blocking that mattered would need a ring to lose to something that is
*not* copper, which cannot happen.

An obstacle (hole) belongs to **no** net and clears any net it lands on:
`can_route_through` lets a net cross its own cells, so an inherited net would be a
licence to route through a mounting hole.

**Effective width and clearance (Round E2).** The run routes at the **board's**
rules, not the engine's. `agent_router.Board` has no slot for either — they are
per-run engine options, not board geometry — so `pcb_worker.methods.
_effective_routing_rules` resolves them and passes both to `route_board` /
`route_board_with_hints` explicitly. Precedence, highest first:

| # | source | trace width | clearance | scope |
|---|---|---|---|---|
| 1 | explicit caller option | `options.trace_width` | `options.clearance` | whole run |
| 2 | hint-authored width | widest `width_mm` among selected hints | — (a route hint has no clearance field) | whole run |
| 3 | **net class minima** (this round) | `net_class.min_trace_width_mm` | `net_class.min_clearance_mm` | width: **that net's own copper only**. clearance: **board-wide** — see "Keepout margin" below, this is not a symmetric pair |
| 4 | the compiled board's design rules | `design_rules.defaults.trace_width_mm` | `design_rules.minimums.min_clearance_mm` | whole run (fallback) |
| 5 | the engine's own signature default | `route_board`'s `trace_width` | `route_board`'s `clearance` | whole run (fallback) |

Steps 1 and 2 are unchanged in meaning; E2 inserted (what is now) step 4 ahead
of what used to be the sole fallback, and this round inserted step 3 ahead of
*that*. Step 5 is still read from `route_board`'s **signature**
(`_engine_default_mm`) rather than re-spelled as a literal, for the same reason
the candidate overlay reads it there: a duplicated default that drifted would
under- or over-state a keepout as easily as a candidate width.

**Why step 3 sits exactly there.** Steps 1 and 2 fix a value for the **whole
run** — every net routes at it, uniformly, because that is what "the caller
asked for a 0.6mm run" or "the widest selected hint wants 0.5mm" means. A
per-net class rule must never be read as overriding that: it is scoped to
*one net*, so if it outranked steps 1/2 it would silently reinterpret what an
explicit run-wide request meant for every net that happens to carry a class —
exactly the reinterpretation the "admitted or rejected, never reinterpreted"
rule (below) forbids. So `pcb_worker.methods._route` captures, before the hint
merge, whether the CALLER set `trace_width`/`clearance` explicitly, and again
whether the hint merge added one; step 3 is applied **per net** only for a
dimension neither of those already fixed. It still outranks the board's own
blanket rule (step 4, now the fallback): a class exists precisely to make one
group of nets (say, power) wider than the board's default, and a board-wide
number can't do that.

**An explicit option — or an explicit class rule — is admitted or rejected, never
reinterpreted.** Absent means "the caller/class said nothing", so the next step
applies; *present but inadmissible* fails closed naming the value. Quietly
substituting the board's rule for what the caller (or the net's own class) asked
for is the same dishonesty as quietly routing at the engine's default. The two
dimensions differ only in their **predicate**: `clearance: 0` is admissible
(asking for no clearance is a coherent request, and `positive_mm` would have
silently discarded it), while `trace_width: 0` is not — zero-width copper is not
copper, and routing at it while the overlay checked at something else is the
false-clean shape. `NetClass.min_trace_width_mm: 0` is exactly this case: the
dataclass itself allows `0` (non-negative), but routing refuses it as a width —
see "Per-net-class minima" below.

The chain is a sequence of explicit `is None` tests, not an `or` chain: `or`
treats `0.0` as absent, so a step legitimately yielding zero would fall through
while still passing an `is None` guard — the run and the overlay would then
disagree about the width. Every step, step 5 included, goes through the same
admission predicate.

If nothing in the chain yields a usable number the route **fails closed**
(`unsupported_geometry`, zero routes). There is no invented default; step 4's
`min_clearance_mm` is the same field `ir_connectivity` publishes and
`drc_geometric` enforces, so routing cannot reserve less space than DRC will
demand.

## Per-net-class minima (this round)

**DORMANT on every real board — read this before anything else in this
section.** `ResolvedDesignRules.net_classes` and `ResolvedNet.net_class_id`
have existed in the IR since before this round, but the v1 compiler hardcodes
`net_classes=()` (`compile_board.py`) and never reads a `net_classes` or
per-net class key from the board dict at all. A REAL compiled board — anything
`route()` can be handed today — always has an empty tuple and every net's
`net_class_id` is `None`, so everything below is unreachable until the
compiler is taught to emit a class. This round is the ROUTING (consumer) half
only; authoring net classes on a real board is a separate, still-open
follow-up, filed independently and out of this round's fence. Until it lands,
the only way to exercise this surface at all is to build a `ResolvedBoard`
with `dataclasses.replace` directly (exactly how `drc_geometric`'s own
net-class guard, docket `019f958b45b9`, is tested) or, for an end-to-end test,
to monkeypatch the compile step — see `tests/test_route_rules.py`'s
`net_classed_compile` fixture.

That dormancy is also why the board-wide widening below (see "Keepout margin")
is an acceptable move for THIS round: it cannot change how any real board
routes today, because no real board can carry a class yet. It is documented as
the permanent design, not a "for now" stopgap — it is a legitimate,
conservative answer on its own merits (see below), not merely safe because
nothing exercises it yet.

**Which fields.** `pcb_worker.methods._net_class_overrides` reads
`NetClass.min_trace_width_mm` / `.min_clearance_mm` — the SAME two fields
`drc_geometric`'s pre-existing fail-closed guard already watches
(`nc.min_trace_width_mm is not None or nc.min_clearance_mm is not None`). It
deliberately does **not** read the plain `NetClass.trace_width_mm` (a nominal
default, mirroring `RoutingDefaults.trace_width_mm` — a different concept from
a *minimum*): the task is "route at the class's minima", and the `min_`-prefixed
pair is the minima.

**Per-dimension, not per-class.** A class naming nothing for a dimension (that
field is `None`) contributes nothing for THAT dimension — the net falls through
to step 4/5 exactly as if it carried no class. A class naming an unrelated field
only (e.g. `via_diameter_mm`) contributes nothing to either dimension. A class
that DOES name a dimension is admitted-or-rejected through the same predicates
as an explicit caller option (`positive_mm` for width, non-negative for
clearance) — see the box above.

**An explicit caller clearance defeats a class minimum, board-wide, silently
from the class's point of view.** This is a direct consequence of "steps 1/2
outrank step 3" (the "Why step 3 sits exactly there" box) applied to a
dimension whose margin is board-wide: if the caller passes `options.clearance`
explicitly, `_route` drops the clearance component out of every net's
`net_overrides` BEFORE `_widen_for_net_classes` ever runs (see
`methods._route`, the `caller_set_clearance` guard), so the widening step
never sees the class's `min_clearance_mm` at all — not "widened then
overridden", genuinely never consulted. A board with a "power" class
authoring `min_clearance_mm: 0.5` and a caller passing `options.clearance:
0.1` routes the WHOLE BOARD, including the power net, at 0.1mm — the class's
own requirement stops applying, board-wide, for as long as that option is set.
The reply is honest about it (`clearance_mm.source` reports `"caller_option"`,
never `"net_class"`, on every route — see `test_an_explicit_run_wide_
clearance_is_never_widened_by_a_net_class`), but a reader who authored a class
minimum and separately passes a run-wide clearance option needs to know THIS,
not just that the reply happens to say `caller_option`: it is not a smaller
number than expected, it is the class minimum not applying at all. This is the
same "admitted or rejected, never reinterpreted" policy the explicit-option box
above states for width/clearance individually — restated here because a class
minimum silently losing to a run-wide option is easy to miss the SCOPE of
(one net) if a reader has not connected it to the board-wide margin.

**Keepout margin: board-wide worst case, not per-net.** A per-net margin was
the first cut of this round, and it was wrong: `RoutingGrid.keepout_margin`
(`clearance + trace_width / 2`) sizes a RING that is a static reservation,
written once, by whichever net's copper it protects. Sizing that ring to ONLY
that net's own class cannot also satisfy a STRICTER class net that comes along
later and approaches the SAME copper — the ring it finds there is smaller than
its own requirement demands. That is an under-block, and routing.md's
invariant is unconditional: **the modeled keepout must be a SUPERSET of the
fabricated copper. Over-blocking is legal; under-blocking never is.** There is
no net-class carve-out for that sentence.

The exact `max(class_A, class_B)` fix — track which specific rule each ring
reflects, and compare against the QUERYING net's own rule at
`can_route_through` time — needs per-cell metadata and a query-time lookup,
which does not fit this round's shape (the grid's occupancy model is "one
owner, one static reservation" throughout, not "who is asking"). But the
invariant does not require the exact fix, only a CONSERVATIVE one: size the
grid's OWN `clearance`/`trace_width` — which `keepout_margin` reads for
**every** marking on the board, pad or trace, classed net or not — to the
**widest** value any class present on the board demands, never narrower than
the run's own baseline. `pcb_worker.methods._widen_for_net_classes` computes
it; `agent_router.router.route_board`/`route_board_with_hints` take it as
`keepout_clearance`/`keepout_trace_width`, separate from the (still genuinely
per-net) copper width. This is the SAME move this campaign has used at
every other point it met an under-block it could not model exactly: the
axis-aligned pad envelope for a rotated land, the containing disc for an oval
hole, the conservative obstacle for unnumbered copper. All of them trade
"maybe over-blocks a little" for "never under-blocks", because that is the one
direction the invariant allows.

One consequence worth being explicit about: because the margin is board-wide,
**every** net's keepout reflects the strictest class present, even a net that
carries no class of its own — an unclassed net's own copper is protected (and
protects others) out to the SAME distance as the strictest classed net on the
board, not its own narrower baseline. Concretely: on a board with SIG in a
"power" class (0.6mm width / 0.5mm clearance) and OTHER carrying no class
(0.35mm / 0.3mm board defaults), a foreign net is kept `0.6/2 + 0.5 = 0.8mm`
from OTHER's own pads too, not merely `0.35/2 + 0.3 = 0.475mm` — pinned by
`test_a_strict_class_elsewhere_widens_the_keepout_around_an_unclassed_nets_own_copper`.
COPPER WIDTH stays exactly per-net regardless (OTHER's own trace is still
drawn at 0.35mm) — only the shared RESERVATION widens.

**Bus routing now honours net-class width too.** `agent_router.router.
route_bus` (hint-driven bus/parallel-corridor routing) first cut of this round
laid every net in a bus at the run's baseline copper width unconditionally,
ignoring `net_widths` entirely — a real defect (Codex must-fix), not a scoped
exception: `_attach_effective_routing_rules` stamps a bus-routed net-classed
net's reply with `{"source": "net_class", "value": <class width>}` regardless
of what actually got drawn, so the un-threaded case made the reply LIE about
copper that did not exist at that width — a lying provenance field, worse than
none, and via `ir_candidates.build_overlay` (which reads a segment's own
`width_mm` first) a **false clean** in the candidate overlay too: the proposal
would be checked at the class width while the routed copper was the baseline.
Fixed by threading `net_widths` into `route_bus`'s own per-net loop exactly
like the standard loop — each bus net now draws at its own class-or-baseline
width, the SAME `_net_width` lookup the two other loops use. Only the bus's
parallel-spacing **offset** (`bus_hint.spacing`) stays shared across the whole
bus; that is a layout choice, independent of any one net's width. Pinned by
`test_bus_routing_honours_net_class_width_not_just_the_bus_baseline`, driven
directly through `route_bus` (mirroring `TestBusRouting.test_route_bus_
creates_parallel_traces` in `tests/agent_router/test_router.py`), which probes
that a classed bus net's copper actually reaches its class width while an
unclassed bus-mate's does not. The board-wide keepout widening (above) always
applied to bus nets' pads and to every other net's copper regardless of this
bug — only a bus net's own drawn copper was ever wrong.

**Reply provenance.** Every route now carries `effective_routing_rules`:

```json
"routes": [{
  "net": "VCC",
  "segments": [{"start": [...], "end": [...], "layer": "F.Cu", "width_mm": 0.6}],
  "effective_routing_rules": {
    "trace_width_mm": {"value": 0.6, "source": "net_class"},
    "clearance_mm": {"value": 0.5, "source": "net_class"}
  }
}, {
  "net": "OTHER",
  "segments": [{"start": [...], "end": [...], "layer": "F.Cu", "width_mm": 0.35}],
  "effective_routing_rules": {
    "trace_width_mm": {"value": 0.35, "source": "board_rules"},
    "clearance_mm": {"value": 0.5, "source": "net_class"}
  }
}],
"effective_routing_rules": {
  "trace_width_mm": {"value": 0.35, "source": "board_rules"},
  "clearance_mm": {"value": 0.5, "source": "net_class"}
}
```

`source` is one of `caller_option` / `hint` / `net_class` / `board_rules` /
`engine_default` — never left for a consumer to infer from whether an override
happens to exist. This is the same honesty `drc_geometric`'s three-way verdict
enum already enforces (`ok` means "the check ran", never "the board passed";
here, a concrete `source` is always present, never omitted as "could not
determine which one"). Note the asymmetry that falls out of the margin being
board-wide: `OTHER`'s own `trace_width_mm` is unaffected (its copper is still
drawn at the board's baseline), but its `clearance_mm` reports the SAME
class-widened value as `VCC`'s — because that is the true, currently-enforced
margin around OTHER's copper too, not a per-net number a consumer could
mistake for something narrower. `pcb_worker.methods._attach_effective_
routing_rules` is the single place that stamps both the top-level baseline and
every route's own block, from the exact `net_widths` map and `keepout_
clearance` value also handed to the engine (`kw["net_widths"]`, `kw["keepout_
clearance"]`) — one value, two consumers (the grid and the reply), so they
cannot disagree.

**The candidate overlay follows, for width.** The same stamping writes each
segment's `width_mm`, and `ir_candidates.build_overlay` already reads a
segment's own `width_mm` **before** any caller-supplied default — that
precedence pre-dates this round (docket `019f952b99f2`) and needed no code
change here, only a producer that finally uses it: before this round, no
segment the worker serialized ever carried its own `width_mm`, so every
candidate fell through to the run's single `default_width_mm`. A net-classed
net is therefore now checked at the width it actually got, not the run's
baseline — the false-clean the whole overlay surface exists to prevent (see
"Where candidate dimensions come from" below). Clearance has no equivalent
per-candidate concept in the overlay (geometric DRC's own clearance check
reads `design_rules.minimums.min_clearance_mm` directly, and is unaffected by
this round — see the fail-closed guard note below).

**`drc_geometric`'s own guard is untouched, on purpose.** Geometric DRC has its
own pre-existing fail-closed guard (docket `019f958b45b9`) that returns
`indeterminate` for ANY net-classed board, because it has not yet been taught
to apply per-class minima to GC1/GC2. This round does not touch it: a
net-classed proposal's `drc_geometric.verdict` stays `"indeterminate"`, exactly
as before — this round teaches ROUTING to honour class minima, not DRC, and
leaving that guard exactly as it was is what keeps the two surfaces from
silently disagreeing about whether a net-classed board is safe.

**Endpoint identity vs geometry.** A pad becomes a routable **endpoint** only if it
carries an authored pad number — nets are spelled `U1.2`, hints reference `U1.2`,
the panel labels `U1.2`, so a pad without one cannot be addressed by anything.
That requirement belongs to routing alone, not to the shared IR iteration: KiCad
legitimately leaves NPTH mechanical pads unnumbered, and such a pad is ordinary,
exactly-modelable geometry (docket `019f97eb6adf`). So `ir_pads.iter_ir_pads`
stays permissive and reports missing identity honestly (`human_number is None`),
and each consumer decides:

| pad | routing | connectivity | geometric DRC |
|---|---|---|---|
| numbered copper | routable endpoint | electrical pad | copper |
| **unnumbered** copper, no net | conservative **obstacle** | excluded | copper |
| unnumbered copper **on a net** | **fails closed** | fails closed | copper |
| NPTH (numbered or not) | obstacle | excluded | hole primitive |

Unnumbered copper degrades to a keepout rather than failing the board: it still
has to block, but nothing could route *to* it. A **netted** unnumbered pad is a
contradiction — the netlist claims a connection to something unaddressable — so
that one fails closed rather than silently dropping the connection. NPTH is
excluded from the connectivity census deliberately: `drc._check_dangling` credits
an endpoint near *any* pad as copper-connected, so carrying a mechanical hole
there would report a route as connected to a drill. The same reasoning excludes
unaddressable copper; the short *it* could cause is a copper question, which
geometric DRC's GC2 models exactly over the same IR.

**Hole semantics.** An NPTH pad is an **obstacle, never a routable pad** (no land,
so it is not a connectable endpoint). A PTH pad keeps out its copper **land**, not
its drill. A plated board hole blocks its **annulus**; an unplated one its drill.
Oval and slot holes are blocked by the disc that **contains** them — the grid's
only obstacle primitive is a disc (`Obstacle.polygon` is declared but read
nowhere), so a containing disc is the honest conservative representation.

## Fail-closed reasons

| `error.kind` | Meaning |
|---|---|
| `parse` | the source will not load at all |
| `compile` | the board will not compile — carries the blocking `diagnostics` |
| `unsupported_geometry` | it compiles, but the routing grid cannot model it faithfully |
| `route` | the engine itself faulted |

`unsupported_geometry` covers: **accepted traces/vias** (the grid never sees
existing copper — owned by T7 `019f70ebc9ed`; until it lands, a board with
accepted copper is not routable rather than routable-and-wrong), **inner copper
layers** (the vendored engine is 2-layer F.Cu/B.Cu only), copper **zones**, copper
**board/placed graphics**, and a non-rectangular **outline**.

In every failing case **zero routes** are returned — no partial proposal, no
`routes: []` alongside a verdict a consumer could misread as "nothing needed".

## Not yet done (each has an owner; none of it is silent)

- ~~Effective width/clearance from the IR, and keepout inflation by clearance +
  half the trace width~~ — **done in E2**, both together, for **all three**
  markers (pads, holes, routed traces). They had to ship together: plumbing the
  real width alone would have the router path a 0.35mm trace against keepouts
  sized for 0.25mm, so the proposed copper would be wider than the clearance
  reserved for it — worse than either endpoint. See "Effective width and
  clearance" and "Inflation composes with that superset" above. The engine's own
  defaults (`trace_width=0.25`, `clearance=0.2`) are no longer what a board gets
  routed at.
- ~~Grid origin correctness~~ — **done in E2a**. `RoutingGrid` now carries the
  board `origin` and is the single owner of the world↔cell transform in both
  directions (`_pos_to_cell` / `_cell_to_pos` / `_cell_range`); callers still
  speak world coordinates at every boundary. It also floors rather than
  truncates, so a position just before the origin can no longer fold onto cell
  `-0` and read as in-bounds. The legal routing area is now the **outline**:
  `_effective_grid_size`, which grew the grid to cover any pad outside the board
  (+2mm), is gone — a pad outside the outline makes its net **unrouted** instead
  of routable off-board.
- ~~Per-net-class width/clearance minima~~ — **done, this round**, for the
  ROUTING consumer (see "Per-net-class minima" above). The v1 compiler still
  emits `net_classes=()` for every real board, so this is reachable only via a
  hand-built/monkeypatched `ResolvedBoard` until compiler support lands —
  authoring net classes on a real board is a SEPARATE, still-open piece.
  `drc_geometric`'s own fail-closed guard (`019f958b45b9`) also still fires for
  any net-classed board: geometric DRC has not yet been taught to apply the
  per-class minima this round only teaches ROUTING to honour, and this round
  deliberately leaves that guard as-is rather than paper over it. Bus-hint
  routing (`route_bus`) now honours net-class width too, fixed within this
  round — see "Bus routing now honours net-class width too" above.
- ~~Native pad-list path~~ (`_board_from_native`) — **deleted, Round E3**. It
  still accepted a missing size as `0x0`, the same class of fictional copper
  E1 removed from the canonical path — but rather than fix it, the shape
  itself is gone: `route()` now accepts exactly one board census (canonical
  YAML/dict), and the retired shape returns a structured `parse` error naming
  the replacement. Zero in-repo callers ever constructed a pads list.

## One compile feeds both halves of the reply

`route()` compiles **once**. The router consumes the ResolvedBoard; DRC-at-propose
consumes `ir_connectivity.connectivity_board(rb)` — a normalized projection of the
*same* compiled board into the dict language the legacy connectivity kernel
already speaks (pad centers, net ownership, existing traces/vias). There is **no**
raw-dict and **no** best-effort-resolve fallback on the canonical path.

Both projections sit under **one** `UnsupportedGeometry` boundary, so whichever
meets geometry it cannot model produces the same structured `unsupported_geometry`
zero-route reply. (The connectivity projection briefly ran ahead of that guard,
where its failure would have escaped the route error envelope — `019f97eb6adf`.)

This matters because E1's first cut moved only the routing half. Routes came from
IR pads while the attached DRC still read the raw dict's inline `pins`, so a
**footprint-only** board — components with a `footprint` and no inline pins, which
is both valid and what the panel produces — routed successfully *and* reported
every endpoint `dangling_endpoint`. Same board, same geometry, two pad censuses
(docket `019f97d021a8`).

The projection emits components at the origin with zero rotation and pins carrying
**absolute** positions, because the IR has already placed them; the kernel's own
`component position + rotate(pin offset)` composition is then the identity, so the
IR's placement (including bottom-side mirroring) reaches it unchanged instead of
having a rotation applied twice.

**It is still connectivity-only.** The projection deliberately carries no pad
extents — sharing a pad *census* is not sharing *geometry*. The attached result
stays `scope:"connectivity"` (see `docs/drc.md`) and is **not** a geometric gate.
The geometric gate is the candidate overlay below, attached beside it.

## Geometric DRC-at-propose (the candidate overlay)

Docket `019f952b99f2`, closing bug `019f80b5124d` — a proposal that ran through
the centre of a different-net pad and was reported **clean**, because the only
check attached to it was the centerline one.

The **same** compile feeds a third consumer: `ir_candidates.check_candidates`
layers each proposed route onto `compiled.board` as IR traces/vias and runs the
unchanged geometric kernel over base + candidates. `route()` therefore returns
**two** verdicts per proposal, answering two different questions:

| key | scope | shape |
|---|---|---|
| `routes[].drc` | `connectivity` | `{clean: bool\|null, violations}` (unchanged) |
| `routes[].drc_geometric` | `geometric_candidate` | `{verdict: "clean"\|"violations"\|"indeterminate", violations}` |
| `drc_geometric_summary` | `geometric_candidate` | the full candidate union (`docs/drc.md`) |

The geometric payload deliberately does **not** carry a `clean` field. The
connectivity one does, and a consumer must never be able to read "the geometric
check could not run" as "the geometric check passed". A geometric fault never
fails the route call — the proposal still returns, with an honest
`verdict:"indeterminate"`. The native pad-list path is retired (see "Not yet
done" above): `route()` no longer accepts it at all, so there is no longer a
routed shape that carries neither key.

### Where candidate dimensions come from — nothing is invented

A route reply carries geometry but not sizes, and the fail-closed ruling forbids
approximated copper, so both values are sourced explicitly:

- **Trace width** — the width the run *actually routed at*. Since E2 that is
  literally the value `_effective_routing_rules` resolved and handed to the
  engine (`kw["trace_width"]`, precedence table above), passed on to the overlay:
  one variable, not two derivations that agree by coincidence. A proposal cleared
  at a width it was not routed at is a **false clean**, which is the failure this
  surface exists to remove. Per-net-class minima (this round) extend this rather
  than compete with it: `_attach_effective_routing_rules` stamps each segment's
  own `width_mm` with THAT net's actual width (its class override, or the run's
  baseline), so `build_overlay`'s existing per-segment `width_mm` precedence
  picks the right one automatically — see "Per-net-class minima" above.
- **Via diameter / drill** — the board's own authored routing defaults
  (`design_rules.via_diameter_mm` / `via_drill_mm`), which is what acceptance
  writes. The engine's vias are positional only.

If a value cannot be sourced, the overlay fails closed (`unsupported_geometry`)
rather than guess one. Same `error.kind` vocabulary as the table above, plus
`unresolved_geometry` and `internal` from the geometric union.
