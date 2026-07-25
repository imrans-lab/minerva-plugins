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

| # | source | trace width | clearance |
|---|---|---|---|
| 1 | explicit caller option | `options.trace_width` | `options.clearance` |
| 2 | hint-authored width | widest `width_mm` among selected hints | — (a route hint has no clearance field) |
| 3 | **the compiled board's design rules** | `design_rules.defaults.trace_width_mm` | `design_rules.minimums.min_clearance_mm` |
| 4 | the engine's own signature default | `route_board`'s `trace_width` | `route_board`'s `clearance` |

Steps 1 and 2 are unchanged in meaning; E2 inserted step 3 ahead of what used to
be the sole fallback. Step 4 is still read from `route_board`'s **signature**
(`_engine_default_mm`) rather than re-spelled as a literal, for the same reason
the candidate overlay reads it there: a duplicated default that drifted would
under- or over-state a keepout as easily as a candidate width.

**An explicit option is admitted or rejected — never reinterpreted.** Absent means
"the caller said nothing", so the next step applies; *present but inadmissible*
fails closed naming the value. Quietly substituting the board's rule for what the
caller asked for is the same dishonesty as quietly routing at the engine's
default. The two dimensions differ only in their **predicate**: `clearance: 0` is
admissible (asking for no clearance is a coherent request, and `positive_mm` would
have silently discarded it), while `trace_width: 0` is not — zero-width copper is
not copper, and routing at it while the overlay checked at something else is the
false-clean shape.

The chain is a sequence of explicit `is None` tests, not an `or` chain: `or`
treats `0.0` as absent, so a step legitimately yielding zero would fall through
while still passing an `is None` guard — the run and the overlay would then
disagree about the width. Every step, step 4 included, goes through the same
admission predicate.

If nothing in the chain yields a usable number the route **fails closed**
(`unsupported_geometry`, zero routes). There is no invented default; step 3's
`min_clearance_mm` is the same field `ir_connectivity` publishes and
`drc_geometric` enforces, so routing cannot reserve less space than DRC will
demand.

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
- **Per-net-class width/clearance minima** — still open. The IR carries the slot
  (`design_rules.net_classes`, with per-class `trace_width_mm` /
  `min_clearance_mm`) but the v1 compiler emits none, so there is nothing for
  routing to honour yet: a run is one width and one clearance for every net.
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
  surface exists to remove.
- **Via diameter / drill** — the board's own authored routing defaults
  (`design_rules.via_diameter_mm` / `via_drill_mm`), which is what acceptance
  writes. The engine's vias are positional only.

If a value cannot be sourced, the overlay fails closed (`unsupported_geometry`)
rather than guess one. Same `error.kind` vocabulary as the table above, plus
`unresolved_geometry` and `internal` from the geometric union.
