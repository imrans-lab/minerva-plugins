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
unrotated rectangle and **discards** the rotation argument it accepts
(`grid.py:133`). Handing it a truthful `w/h` for a rotated elongated land would
therefore under-block along the rotated axes. It is handed the land's
axis-aligned **bounding box** instead — a strict superset of the real copper.
Same invariant as the DRC kernel, restated for keepouts:

> the modeled keepout must be a SUPERSET of the fabricated copper. Over-blocking
> is legal; under-blocking never is.

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

- **Effective width/clearance from the IR** and keepout inflation by clearance +
  half the trace width — **Round E2**. Today the engine still applies its own
  defaults (`trace_width=0.25`, `clearance=0.2`), which is what it did before E1:
  `agent_router.Board` carries no design rules, so a board authoring a 0.35mm
  floor is currently routed at 0.25 unless the caller passes options.
- **Grid origin correctness** for a non-zero `RectOutline.origin` — **Round E2**.
  The `Board.origin` is carried, but `RoutingGrid` indexes from zero and
  `_effective_grid_size` expands past the outline to cover outlying pads.
- **Per-net-class width/clearance minima** — **Round E2**, with the rest of rules.
- **Native pad-list path** (`_board_from_native`) — **Round E3**: it still accepts
  a missing size as `0x0`, which is the same class of fictional copper.

## DRC-at-propose is unchanged, and still connectivity-only

`route()` still attaches the centerline `drc.run_drc` result as
`scope:"connectivity"` (see `docs/drc.md`). It is **not** a geometric gate, and E1
does not make it one; geometric candidate feedback is `019f952b99f2`.
