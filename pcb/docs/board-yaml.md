# PCB Board-Source Contract (canonical YAML)

The canonical board model is the single schema every downstream child consumes —
the Python geometry worker, the gerber exporter, and the panel port. It is
defined in Go at `pcb/internal/board/` and serialized as deterministic YAML.

Design priority: **durability of the contract over feature breadth.** Field
names are explicit and unit-suffixed (`_mm`, `_deg`) so no consumer guesses
units; unknown fields survive round-trips rather than being silently dropped.

## Schema

This example **compiles clean** against the seed library under both production
output profiles — it is a board, not a sketch. Keep it that way: see "Compiling
the examples" below.

```yaml
version: 1                     # int, contract/schema version
name: Blinky                   # board name
width_mm: 40                   # board outline width (mm)
height_mm: 30                  # board outline height (mm)
grid_mm: 2.54                  # optional snap grid (mm)
layers: [top, bottom]          # optional copper stack; LIST ORDER IS STACK ORDER
                               # (see "Layer stack" below)
origin: {x_mm: 0, y_mm: 0}     # optional board origin
design_rules:                  # board-wide manufacturing constraints
  clearance_mm: 0.2
  trace_width_mm: 0.25
  via_diameter_mm: 0.8
  via_drill_mm: 0.4
  allowed_trace_angles_deg: [0, 45, 90, 135]   # optional; see "Trace angles" below
  zone_min_thickness_mm: 0.15  # optional; see "Zone minima" under "Zones"
  zone_min_island_area_mm2: 0.5 # optional; see "Zone minima" under "Zones"
  net_classes:                 # optional; see "Net classes" below
    - name: Power              # class identity; its IR id is DERIVED from this
      members: [VCC, GND]      # net names that belong to the class
      min_trace_width_mm: 0.6  # optional
      min_clearance_mm: 0.4    # optional
components:
  - ref: U1                    # reference designator
    footprint: Package_DIP:DIP-6_W7.62mm_Socket   # KiCAD footprint id, or a seed alias
    value: NE555               # optional
    x_mm: 20                   # the FOOTPRINT'S OWN origin — see "Where x_mm /
    y_mm: 12                   # y_mm actually put a footprint" below. NOT the
                               # body centre, and not always pin 1.
    rotation_deg: 90
    layer: top
    symbol: Device:NE555P      # OPTIONAL, unmodeled — carried in Extra (see below);
                                # checked informally by minerva_pcb_check_libraries when present
    pins:
      # Component-relative offsets. Inline pin geometry must AGREE with the
      # footprint's own pad positions (see "Pin-geometry authority" below) —
      # these are DIP-6 pins 1 and 2, 2.54mm apart down the package's left side.
      - {number: "1", name: VCC, x_mm: 0, y_mm: 0}
      # Through-hole pad: drill_mm > 0 makes it a TH pad (copper annulus on every
      # copper layer + a drilled hole in the Excellon output). plated defaults to
      # true; set plated: false for a non-plated mechanical pad (routes to NPTH).
      - {number: "2", name: GND, x_mm: 0, y_mm: 2.54, drill_mm: 0.8, annulus_diameter_mm: 1.6}
  - {ref: R1, footprint: R_0805, value: 10k, x_mm: 10, y_mm: 5, rotation_deg: 0, layer: top}
nets:
  - name: VCC
    pins: [U1.1, R1.1]         # "Ref.PadNumber" strings
  - name: GND
    pins: [U1.2, R1.2]
traces:
  - net: VCC
    layer: top
    width_mm: 0.25
    points:                    # ordered polyline; N points = N-1 segments
      - {x_mm: 10, y_mm: 5}
      - {x_mm: 20, y_mm: 12}
vias:
  - {x_mm: 15, y_mm: 8, drill_mm: 0.4, diameter_mm: 0.8, net: VCC,
     from_layer: top, to_layer: bottom}   # `tented` defaults true (no mask opening);
                                           # set `tented: false` to expose the annulus
mounting_holes:                # optional board-level drilled holes (not on a pad)
  - {x_mm: 5, y_mm: 5, diameter_mm: 3.2, plated: false}   # plated defaults to false (NPTH)
  - {x_mm: 8, y_mm: 5, diameter_mm: 2.0, plated: true, annulus_mm: 3.0}  # PTH: annulus_mm REQUIRED
board_graphics:                # optional board-OWNED artwork (see "Board graphics")
  - id: graphic:0123456789abcdef0123456789abcdef
    layer: B.SilkS             # silk or courtyard ONLY; copper and Edge.Cuts are refused
    kind: text                 # the board stores the STRING, never its strokes
    text: (c) 2026 TurnRock
    position: {x_mm: 10, y_mm: 26}
    size_mm: 1.2               # CAP HEIGHT in mm
  - id: graphic:11111111111111111111111111111111
    layer: F.SilkS
    kind: polyline             # OPEN chain; `poly` is the closed twin
    width: 0.15
    points:
      - {x_mm: 30, y_mm: 25}
      - {x_mm: 36, y_mm: 25}
annotations:                   # OPAQUE passthrough (see below)
  - {id: ann-1, kind: note, text: decoupling near U1}
route_hints: []                # OPAQUE passthrough (see below)
```

### Fields the Go contract carries but the v1 compiler refuses

`design_rules.diff_pair_gap_mm` and `design_rules.diff_pair_width_mm` are
modeled by the Go board struct and round-trip losslessly, but the v1 IR carries
them to **no** consumer. Authoring either is therefore **fatal** whenever `rules`
is a requested output — which every production output profile requests — with
`unsupported_design_rule`. They are deliberately absent from the example above
for exactly that reason: a board carrying them does not compile.

This is the same policy, and the same diagnostic code, that refuses the
nominal-size fields on an authored net class (see "Net classes" below).
`compile_board._declared_but_not_modeled` is the single place it is decided.

### Layer stack (`layers`)

`layers` is the board's **copper** stack. It is optional — a board that declares
none is a 2-layer board by convention, and nothing invents a stack for it — but
when it is declared, **the list order IS the physical stack order**: `top` first,
`bottom` last, inner layers in index order between them. Nothing in the codec
sorts or dedupes the list, so what an author writes is what every consumer sees.

Canonical names are lowercase and 1-based, and each has exactly one KiCad alias:

| canonical | KiCad | position |
|---|---|---|
| `top` | `F.Cu` | outer, stack index 0 |
| `in1` … `in30` | `In1.Cu` … `In30.Cu` | inner, in stack order |
| `bottom` | `B.Cu` | outer, last |

The inner range stops at 30 because KiCad's copper stack does (32 layers total),
so every canonical name this contract accepts has an alias a KiCad tool will
take. `in01` is not a name (one layer, one spelling); neither is `inner1`,
`In1.Cu` (that is the alias, not the canonical id), or any non-copper layer —
`Edge.Cuts`, `F.SilkS` and friends are emitter concerns, not stack entries.

`Validate` enforces four rules on a declared stack, first violation wins, with
identical codes in Go (`internal/board/validate.go`, `validateLayers`) and Python
(`worker/pcb_worker/board_validate.py`, `_check_layers`):

| code | when |
|---|---|
| `invalid_layer_name` | an entry is not `top`, `bottom`, or `in<k>` with 1 ≤ k ≤ 30 |
| `duplicate_layer` | the same layer is listed twice |
| `incomplete_layer_stack` | `top` or `bottom` is missing |
| `invalid_layer_stack_order` | the list is not `top`, `in1`…`inK`, `bottom` in that order — inner layers must be **contiguous from `in1`** |

Contiguity is required because a gap (`[top, in1, in3, bottom]`) would assert a
physical layer the board refuses to name, and would make the alias of the layer
below the gap disagree with its position — `In3.Cu` by name, second inner by
place. Requiring contiguity keeps a layer's name and its position the same fact.

Two membership rules follow the stack (epoch GA-1, the `zone_unknown_layer`
precedent applied to the other copper-bearing entities): when a stack is
declared, a trace's `layer` and a via's `from_layer`/`to_layer` must name
declared entries (`trace_unknown_layer` / `via_unknown_layer`, mirrored in
`validateCopperEntityLayers` / `_check_copper_entity_layers`). An **absent**
field stays legal on both entities — pre-GA-1 boards rely on the downstream
defaults — and a board that declares no stack has nothing to check against,
exactly as for zones.

**A declared stack is RESOLVED, and its depth is a profile capability**
(epoch GA-1; before that the compiler refused every stack but `[top, bottom]`).
`compile_board._build_layer_stack` builds the board's resolved stackup from the
declaration — declared order is stack order, dielectric entries interleaved —
and the depth is gated against the **selected manufacturer profile's**
`capabilities.max_copper_layers` (`unsupported_layer_stack` when the board is
deeper than the profile fabricates). A profile that declares no capability is a
2-layer profile: for a ceiling, silence never widens. `jlcpcb-4layer` is the
first profile to declare one. The 2-layer *emitters* still refuse deeper
stacks loudly (`build_gerbers_ir` / `generate_kicad_pcb` fail-closed seals)
until the per-layer fab emitter lands.

**Vias are through-hole only.** `from_layer`/`to_layer` describe a span that
crosses the whole board; blind and buried vias are **not modeled**, and a span
touching an inner layer is illegal (`is_legal_via_span`) **at any declared
depth** — a through-via on a 4-layer board still spans `top` ↔ `bottom` and
carries copper on every layer it passes. Legality derives from the two-entry
outer-pair table, and blind/buried support needs a real span-adjacency rule,
not more entries in it.

The canonical ↔ KiCad mapping has one source of truth per language —
`worker/agent_router/layers.py`, mirrored value-for-value by
`ui/model/pcb_layer_stack.gd` (one of the GD-side library modules; see
`model-layering.md` for how those modules, `PCBData`'s mutators and the
surfaces divide the work) — and the two directions are deliberately
asymmetric:

- **Write / export** (`canon_to_kicad`) **fails closed**: an empty or unknown
  layer name raises (Python) or `push_error`s and returns `""` (GDScript). It no
  longer defaults to `F.Cu`, because a silently defaulted layer name is copper on
  the wrong side of a board somebody fabricates.
- **Read / import** (`kicad_to_canon`) **fails visible**: an unknown name still
  passes through lower-cased, so an old or foreign board stays loadable, but it
  now emits a warning instead of being silent.

### Zones (compiled fill, DRC, routing constraints, and fabrication)

`Zone` is the first entity added to this contract since the v2 schema settled
(docket `019f9a73e5a2`, parent `019f761fda74`) — an authored region on a single
layer. A zone is one of two things, and which one it is decides whether it needs
a net: a **copper pour** (most commonly a ground or power plane), which is copper
and so belongs to a net; or a **keepout**, a rule area that forbids copper rather
than being copper, which needs no net at all — the same as a KiCad rule area.

| key | required | meaning |
|---|---|---|
| `id` | v2 only | mint-once opaque id, `"zone:<hex>"` — same rule as `trace`/`via`/`hole` |
| `kind` | no | `copper_pour` (the default when absent or empty) or `keepout`; canonical lowercase only |
| `net` | **`copper_pour` only** | the net this pour is tied to; must name a declared net. **OPTIONAL on a `keepout`** — see below |
| `layer` | yes | the copper layer this zone is on; must be a member of `layers` when the board declares one |
| `outline` | yes | ordered polygon boundary, `[{x_mm, y_mm}, ...]`; needs at least 3 points |
| `clearance_mm` | no | this zone's copper clearance from foreign-net copper; unset defers to `design_rules.clearance_mm` |
| `thermal_gap_mm` | no | copper gap around a same-net pad that is NOT thermally relieved |
| `thermal_bridge_width_mm` | no | spoke width connecting a thermally-relieved pad to the pour |

**The net requirement is kind-dependent** (owner boundary ruling, 2026-07-30,
docket `019fb5ad6d20`: *"Keepouts don't need net connections"*). A `copper_pour`
must name a declared net; a `keepout` may omit `net` entirely, or carry it empty,
and both mean the same thing — **this keepout applies to all copper, whatever its
net**. A keepout that DOES name a net is still valid and still checked: it is a
net-scoped keepout ("no `GND` copper here"), and the net it names must be
declared, exactly as for a pour. On serialize an empty net is written as an
ABSENT `net` key rather than `net: ""`, so a netless keepout round-trips as the
absence it is.

`Validate` rejects an outline with fewer than 3 points (`invalid_zone_outline`),
a `kind` that is neither `copper_pour` nor `keepout` (`invalid_zone_kind`; an
absent or empty `kind` is `copper_pour`, not an error), a `net` that is missing
on a pour or that names no declared net (`zone_unknown_net`), and a `layer`
absent or outside the declared stack (`zone_unknown_layer`) — this check applies
on v1 boards too, unlike identity, which is v2-only. `kind` is checked BEFORE
`net`, because `kind` is what decides which net rule applies. These four codes
are not yet cross-checked by a shared vector, but `board_validate.py`'s
`_check_zones` mirrors them string-for-string and in the same
first-violation-wins order.

#### Zone minima (`design_rules.zone_min_thickness_mm`, `design_rules.zone_min_island_area_mm2`)

After a pour is carved around foreign copper, the fill may leave fragments no
fab can etch and no via could reconnect. Two board-wide rules decide what the
compiler does with them:

| key | default | meaning |
|---|---|---|
| `zone_min_thickness_mm` | the selected manufacturer profile's `min_trace_width_mm` | a fill region (or any orphan fragment) thinner than this everywhere is a **sliver** and is culled; must be a positive number |
| `zone_min_island_area_mm2` | the area of one default via land, `pi/4 * via_diameter_mm^2` | an orphan fragment (no same-net copper touching it on its layer) with total area below this is **etch scrap** and is culled; `0` means "cull no island by size"; must be non-negative |

Every cull is reported in a `zone_fill_culled` WARNING on its zone, one per zone, naming each region's kind, bounds and area — nothing
is deleted silently. An orphan fragment **at or above** the island minimum is
not culled: the compile refuses it (`zone_fill_failed`) so the author decides
whether to stitch it, extend the pour, or shrink the outline.

Both keys are part of the **shared validation boundary**, not compile-time rules
only: `Validate` (Go) models them as typed `design_rules` fields and checks their
range, the worker's `compile` checks them again, and a malformed value (negative,
non-numeric, a zero thickness) is refused by BOTH with `invalid_design_rule` — so
a board cannot clear `validate` and then fail `compile` on a fabrication
parameter it stated. An UNSTATED key is not a value: it stays absent from the
source, and the default in the table above is derived at compile. The committed
cross-language vectors that pin this are `spec/vectors/350-*` through `400-*`.

**A `copper_pour` zone is AUTHORABLE, COMPILABLE, and FABRICABLE (solid connect
only); a `keepout` zone is AUTHORABLE, COMPILABLE, and enforced by routing and
zone fill.** It round-trips losslessly (YAML and the `pcb.deserialize` JSON
boundary), and `compile_board`'s `_build_zones` produces a `ResolvedZone`, then
`fill_board_zones` (`zone_fill.py`) runs as the LAST compile step — on the
assembled board, sharing the geometric DRC's own copper projection, because a
pour is carved around everything else on its layer (pads, traces, vias, drills)
and cannot be computed before they exist. There is no `zone_unfilled` warning
any more; fill is always attempted, and the outcome is one of three diagnostics:

- `zone_fill_failed` (**ERROR** — the whole compile fails, naming the zone).
  Covers every way a pour cannot be filled without inventing a rule the author
  never wrote: a self-intersecting outline; a copper-to-edge inset that leaves
  no fillable area; overlapping same-net pours; `thermal_gap_mm` /
  `thermal_bridge_width_mm` authored on a zone (v1 fill implements SOLID
  connect only — filling solid would silently discard an authored fabrication
  parameter, so the board is refused rather than mis-filled); and, once a fill
  is computed, two **unfabricable-region** faults reported by name in the same
  error (D0-3): **SLIVER** (a disjoint filled region nowhere as wide as the
  board profile's `min_trace_width_mm` — proven by an empty deflation at half
  that floor, not an area estimate) and **ISLAND** (a region overlapping none
  of the pour's own same-net copper — live copper severed from everything,
  scored only once some other region of the same pour IS attached). Sliver is
  reported in preference to island when a region is both, because an
  unetchable fragment is a fab fact and whether it connects is a netlist fact,
  and sending the author to fix the netlist first would be the wrong order.
  Neither fault is culled the way KiCad culls them — KiCad culls against
  numbers its own schema supplies (`min_thickness`, `island_removal_mode`);
  this contract has neither field yet, so it hands the author the fact instead
  of silently deleting copper.
- `zone_fill_empty` (**WARNING**) — the fill computed successfully with NO
  copper (the outline is entirely consumed by keepouts, clearance, or the
  board-edge inset). A real, computed answer, not the old uncomputed
  `fill=None`; flagged because an author who drew a pour and got none almost
  certainly did not mean to.
- `zone_filled` (**INFO**) — the pour filled: region count and copper area in
  mm².

Downstream of a successful fill:

- `gerber` and `kicad` both EMIT a filled `copper_pour`'s copper — no longer a
  blanket refusal. `kicad` writes the outline plus fill rules (KiCad re-fills
  on open, the same parity oracle checks agree with our computed geometry);
  `gerber` emits the computed fill rings directly.
- `drc_geometric` runs a real clearance check against filled copper instead of
  returning INDETERMINATE for the whole run: finding type `gc7_zone_clearance`
  fires when a foreign-net COPPER PRIMITIVE (pad, trace segment, via land,
  plated board-hole annulus) sits closer to a pour than its effective minimum
  clearance allows — pour copper now participates in clearance like any other
  copper.

  CORRECTED in epoch CP2 S7: this sentence used to read "foreign-net copper (or
  a hole)". GC7 iterates `Projection.copper` and nothing else — it has never
  looked at a drilled bore. Hole-to-pour spacing is enforced one step earlier,
  at FILL time, by `zone_fill._hole_clearance_mm`, which carves every hole the
  pour does not skip at `max(copper clearance, min_hole_to_copper_mm)`; and
  hole-to-copper for the copper the filler does not produce (pads, traces, vias)
  is `gc10_hole_to_copper` (CP2 S7). Three different mechanisms, and the old
  wording credited one of them with another's job.
- `route_bridge` projects each straight-edged keepout into a layer-scoped
  polygon obstacle, and the routing grid rasterises it. A net-scoped keepout is
  conservative in routing today: it blocks every net on that layer, while zone
  fill honours its net scope exactly. Arc-bearing keepouts still fail closed
  rather than being tessellated by an invented tolerance.

A malformed zone *container* still fails closed, but at the shared boundary
rather than in the compiler: `zones: {}` is `invalid_board_structure`
(`validate_board_v2`), while `zones: []` and `zones: null` declare nothing and
are allowed — "an explicitly empty list declares nothing" (review 623 R2 refuses
an empty *mapping*, but allows an empty *list*).

No example in this document authors a zone: what a fill produces depends on
every other authored entity on its layer, which would make the example fragile
rather than illustrative, and the examples are compiled by
`test_every_yaml_example_in_board_yaml_md_compiles` (this file's own
compile-checked-examples test, see "Compiling the examples" below), the same
reason `diff_pair_gap_mm`/`diff_pair_width_mm` are absent from the example
above.

**Editing a committed zone.** The editor treats all three of a zone's authored
properties as live, and every edit goes through the same rules this section
states, so a zone cannot be edited into a shape the validator would reject:

- **Outline** — vertices can be dragged, inserted on an edge, and deleted.
  `set_zone_outline` refuses any write leaving fewer than 3 points, the same
  floor `invalid_zone_outline` enforces. Because `pcb.serialize` validates the
  WHOLE board, a single degenerate outline would make the entire board
  unexportable, so the refusal is at the writer rather than at save time.
- **Net** — re-assignable on a `copper_pour` and validated against the declared
  nets. Refused outright on a `keepout`: net-scoped keepouts are legal in THIS
  contract (see above) but the editor does not author them, matching what its
  zone drawing tool already does.
- **Layer** — re-assignable within the declared copper stack. `set_zone_layer`
  additionally FAILS CLOSED on a board that declares no `layers` at all, where
  the `zone_unknown_layer` rule has nothing to check against and would otherwise
  accept any name.

### Cut-outs

A `cutout` is an opening through the **entire board** — an internal slot or
window milled out of the substrate. Top-level key `cutouts`, a list.

| key | required | meaning |
|---|---|---|
| `id` | v2 only | mint-once opaque id, `"cutout:<hex>"` — same rule as `trace`/`via`/`hole`/`zone` |
| `outline` | yes | ordered polygon boundary, `[{x_mm, y_mm}, ...]`; needs at least 3 points |

That is the whole entity, and each missing field is a decision:

- **No `layer`.** A cutout goes through every layer, so "which layer" is the one
  question it cannot be asked. This is why it is a separate entity rather than a
  third zone `kind`: a keepout is a per-layer prohibition on *copper*, a cutout
  is the absence of *board*.
- **No `net`.** Nothing connects to a hole in the substrate.
- **No `kind`.** There is exactly one thing a v1 cutout can be.
- **No circle or arc variant.** A round opening the fab will drill is already a
  `mounting_holes` entry (it carries `diameter_mm`), and the IR's contour type
  already admits arc segments — so curves are a later *widening* of `outline`,
  not a competing shape. If they arrive, `pth_holes`/`npth_holes` is the
  precedent: an input alias normalized into the canonical form at parse time.

`Validate` rejects an outline with fewer than 3 points
(`invalid_cutout_outline`), on v1 boards too — identity is the only v2-gated
cutout rule. Go's `validateCutouts` and `board_validate.py`'s `_check_cutouts`
went in together and are asserted against each other by the committed vectors in
`spec/vectors/`, so this code string means the same thing on both sides.

**A cutout COMPILES and FABRICATES** (epoch CPN1, docket `019fe2faf76e`; the
compile refusal that used to live here existed to hold back fail-open
`019fbd30f7`, which that round fixed by its own oracle — `outline_frame` now
frames a rect-outer profile faithfully or raises, never a silent bbox). The
compiled shape is `ProfileOutline(outer=<rim rectangle>, cutouts=(...))`, and
every consumer genuinely sees it: both fab emitters draw each cutout as a
second closed Edge.Cuts contour, geometric DRC measures copper-to-edge against
cutout edges (findings name the cutout via `against_entity_id`), routing
reserves each cutout as an all-layer obstacle pre-inflated by
`copper_to_edge_mm`, and zone fill carves pours away from cutouts by the same
band.

**What compile enforces**, all under `invalid_cutout_outline`, on v1 boards
too: at least 3 distinct corners with no zero-length segment (explicit closure
folds to implicit); every vertex **strictly interior** to the rim (a vertex on
or past the rim would be a NOTCH — a reshape of the outer contour v1 does not
model); **no self-intersection and no zero area** (a pentagram or bow-tie ring
has no single interior; a collinear sliver encloses nothing); pairwise
**disjoint bounding boxes** (conservative: genuinely overlapping contours must
be merged; a disjoint diagonal pair whose boxes overlap is refused in the
fail-closed direction); unique ids.

**What is NOT checked, deliberately:** that a cutout avoids pads, traces, vias
or zones (that is DRC's job, and GC5 does it for copper); minimum internal
milling radius; hole-to-cutout-edge distance (filed: `019fe3286237` — no
hole-to-edge class exists for the rim either).

### Compiling the examples

**A schema example must be compiled, not eyeballed.** A schema doc whose example
does not compile is worse than no doc: it teaches a shape the compiler rejects,
and every reader who copies it starts from a broken board. That is not a
convention here, it is a **test**:
`tests/test_compile_board.py::test_every_yaml_example_in_board_yaml_md_compiles`
parses every `yaml` block out of this file and runs it through `compile_board`
against the seed library under **both** production output profiles
(`V1_FAB_OUTPUTS` and `V1_ROUTING_OUTPUTS`). Editing an example so it no longer
compiles turns that test red.

Two of the blocks are **fragments**, not boards — the pin `override` sub-struct
and the `design_rules` net-class block. A fragment is only meaningful inside a
board, so each is spliced into a minimal host and compiled there. The splice is
part of the check: the `override` fragment must be hosted on a **through-hole**
footprint, because `override.drill_mm` on a pad with no footprint drill is
refused outright, and its pin coordinates must match that footprint's real pad
positions or `pin_pad_desync` fires.

Compiling clean does not mean warning-free. Boards built on the seed library
carry `feature_omitted` and `captured_geometry_not_emitted` warnings for
footprint courtyard/fab/paste geometry the v1 emitter does not fabricate; those
are properties of the library, not defects in the example.

### Through-hole & mounting-hole fields (fabrication)

`Pin.drill_mm` / `Pin.annulus_diameter_mm` / `Pin.plated` and the board-level
`mounting_holes` list (`[]Hole`: `x_mm`, `y_mm`, `diameter_mm`, `drill_mm`,
`plated`, `annulus_mm`) are first-class as of docket `019eb47ddebc` — they
formalize the through-hole pad geometry and non-plated mounting holes the gerber
spike carried through `Extra`. A **plated** board hole MUST author `annulus_mm`
(its copper-ring diameter, `> diameter_mm`): the copper ring is never invented, so
both the gerber and KiCad exporters emit exactly the authored ring and cannot
diverge (finding `019f8dbb7104`); the compiler fail-closes a plated hole without
one, and rejects `annulus_mm` on an unplated hole. The `minerva_pcb_gerbers` exporter uses
them to build copper annuli,
mask openings, and the PTH/NPTH Excellon split. See `docs/gerbers.md`. Producers
may pre-split plating with the `pth_holes` / `npth_holes` INPUT aliases; the codec
NORMALIZES them into the single canonical `mounting_holes` collection (with
`plated` set from the alias key) at every parse boundary, so a board always
round-trips as `mounting_holes` and its holes get uniform id-minting + structural
validation — the aliases no longer bypass the v2 identity/validation gate (finding
`019f8b7fb07e` comment 689).

## Assembly (`assembly`)

What an assembly house has to **buy and place** for one component. Optional, and
per-component: a board mid-layout has chosen no parts yet and must still load,
serialize, route and fabricate. What an assembly EXPORT requires is a separate
gate that refuses by name — this block's job is to carry the author's answer
losslessly, not to demand one.

**Assembly export requires a board that strictly compiles.** The BOM and the CPL
are derived from the same compiled board the gerbers come from — one order, one
board — so a board the compiler refuses produces no CSVs at all. That refusal is
named (`assembly_not_compilable`) and lists every component, pad and footprint
that blocked the compile. Before the cutover the CSVs were read straight off the
board YAML, which meant an order could carry CSVs describing one board and
gerbers describing another; the capability that was lost is the ability to
export an order for a board nobody could build.

```yaml
components:
  - ref: U2
    x_mm: 10
    y_mm: 10
    assembly:
      populate: true                     # false = DNP (see below)
      manufacturer: Yageo
      mpn: RC0805FR-0710KL
      package: "0805"                    # the BOM's Footprint/package column
      comment: 10k 1% 1/8W               # the BOM's Comment column
      house_parts: {jlcpcb: C84376}      # house id -> that house's catalogue number
      paste: auto                        # auto | include | exclude
  - ref: J1S
    x_mm: 30
    y_mm: 10
    assembly:
      mpn: PPTC071LFBN-RC
      placements:                        # one drawn part, two soldered parts
        - {ref: J1S_A, offset_mm: {x: 0, y: 0}, rotation_deg: 0}
        - {ref: J1S_B, offset_mm: {x: 22.86, y: 0}, rotation_deg: 0}
        # ...and, where the drawing's own centre is not each part's centre:
        #   {ref: J1S_A, offset_mm: {x: -11.43, y: 0}, anchor_mm: {x: 0, y: 26.67}}
```

| field | meaning |
|---|---|
| `populate` | `false` marks the part **do-not-populate**: it stays in the gerbers (its lands are still etched) and leaves **both** assembly CSVs, logged by ref. Absent means populated. |
| `manufacturer` / `mpn` | the orderable part's identity. |
| `package` | the package name the BOM's Footprint column prints, independent of the footprint id the board routes against. Absent, that column falls back to the authored `footprint`. |
| `comment` | the BOM's Comment column. Absent, it falls back to the component's `value`. |
| `house_parts` | a mapping of house id to that house's own catalogue number (`{jlcpcb: C84376}`). Keyed, not a bare `lcsc` scalar, so a second house is a new entry rather than a new field and a board always states **whose** number it is carrying. The BOM's part-number column prints the entry for the **selected** house; absent, it falls back to `mpn`. |
| `paste` | `auto` (the default) leaves the footprint's own layer list to decide; `exclude` drops this part's stencil apertures; `include` declines to drop them. See "Solder paste is authored, never invented" below. |
| `placements` | the synthetic expansion — see below. Absent is the ordinary case: one placement, at the component's own position, under its own ref. Each entry takes `ref`, `offset_mm`, `rotation_deg` and `anchor_mm`. |

The three column fields resolve to the BOM's cells with exactly one fallback
each, applied once at emit time so no consumer re-decides what a column means:

| BOM column | authored field | fallback when absent |
|---|---|---|
| Comment | `assembly.comment` | the component's `value` |
| Footprint | `assembly.package` | the authored `footprint` ref |
| part number (e.g. "LCSC Part #") | `assembly.house_parts[<selected house>]` | `assembly.mpn` |

Which key names the selected house is a **dialect** fact carried on the house
profile, not a guess: the `jlc` profile reads `house_parts.jlcpcb`. A board
carrying two houses' numbers therefore ships the selected house's, never the
first one written.

**An authored empty `placements: []` is a fault that is KEPT, not tidied away.**
It says "this drawing stands for several parts" and then names none, which the
export gate refuses (`assembly_empty_expansion`). Both codecs round-trip the
empty list rather than dropping the key, so a board that has been through a load
and a save still carries the fault for the gate to find; an absent key stays
absent.

**Unknown keys inside `assembly` are REFUSED**, not preserved — the opposite of
the board's general Extra-passthrough rule (see "Losslessness & the warnings
list"). This block is the only source of part identity for an order, so `mpm:
C123` silently vanishing and resurfacing later as "missing mpn", or a mistyped
`offset_mm` quietly placing a part at its parent's origin, is exactly the quiet
wrong answer the order path exists to refuse. Both codecs enforce it at every
level of the block, including **inside** a placement's `offset_mm` and
`anchor_mm`: `{xx: 22.86, y: 0}` refuses rather than defaulting x to 0
(`internal/board/assembly.go`).

### Identity values are QUOTED strings, and a blank one means absent

`manufacturer`, `mpn`, `package` and `comment` each have three authoring homes,
read in this order: the `assembly` block, then a top-level key on the component,
then the component's `properties` map. The first home that has the key decides.

**Quote them.** A bare `0603` is not text in YAML. It resolves as a number
before any of this is read — `0603` reaches the compiler as `387` (leading
zero, read as octal), `0402` as `258`, `0201` as `129`, `1206` as `1206`;
`0805` alone survives unquoted, by the accident that `8` is not an octal digit.
Nor do the two codecs agree about it: the Go codec decodes the `assembly`
block's fields into typed strings and keeps `0603` intact, but the top-level and
`properties` homes ride the untyped Extra passthrough, so a save through Go
**rewrites those to `387` in the file** and the authored text is gone.

A non-string identity value is therefore a **named refusal** carrying the
component and the field (`invalid_component_assembly`), not a value to guess
at: coercing would print `387` in the Footprint column, and dropping would fall
through to the next home and order whatever was written there.

**A blank value means absent** — `""`, spaces, a lone newline and a bare
`mpn:` with nothing after it all read as "not authored here" and fall through to
the next home, exactly as a missing key does. **There is deliberately no way to
force an empty cell.** All four fields are `omitempty` in the Go codec, so an
authored blank is dropped from the file by the first serialize; a rule that
honoured it in the Python reader alone would be a value that dies on promote.
A part that genuinely has no identity is the export gate's business
(`assembly_missing_identity`), not a blank cell's.

### Expansion refs are AUTHORED

`placements` exists for one drawn component that stands for several identical
physical parts — a socket strip drawn once and soldered twice. Each entry's
`ref` is the designator that part is actually placed under, and it is
**authored**: stable across exports, and unique board-wide. An exporter that
invented these would rename a part between two orders of the same design, and
`Validate` refuses a board where two physical parts would share one designator
(`duplicate_assembly_designator`). `offset_mm` is measured in the parent
component's own frame, before the parent's rotation and side are applied, and
`anchor_mm` states that part's own body centre in its placement's frame (see
"A placement may state its own anchor" under "The assembly anchor").

### Solder paste is authored, never invented

`paste` decides only whether this component's stencil apertures are
**suppressed**. It can never add one: a footprint that declares no `F.Paste` /
`B.Paste` participation gets no aperture under any value, because the gerber
emitter reads paste participation strictly off each pad's resolved layer list
(so a through-hole part emits no paste unless its footprint genuinely asks for
paste-in-hole reflow, and a paste-only SMD aperture node still emits one).

* `auto` — the footprint decides. The default.
* `include` — the footprint decides, and the author has said so on purpose. Same
  emitted apertures as `auto`; the difference is that the question was answered.
* `exclude` — **no** stencil apertures for this component, whatever its
  footprint declares. Copper, mask and drill are untouched, which is what keeps a
  do-not-populate part populatable later.

**A not-populated part whose lands take paste, left on `auto`, refuses at export
time** (`assembly_paste_undecided`). There is no defensible default: paste under
a part nobody places is either deliberate — hand-populated later, or populated by
a different board — or a stencil defect that bridges bare lands. Boards carrying
the legacy `assembly: exclude` scalar on such a footprint have to answer it once;
their gerbers are unaffected either way.

### Hard gates on assembly export

These run over the compiled board before either CSV is rendered, and each
refuses with a stable code naming the component and the field responsible. They
are export-time gates, not load-time validation: a board mid-layout still loads,
compiles and fabricates while carrying any of them.

| code | refuses when |
|---|---|
| `assembly_duplicate_designator` | one designator names two physical parts. In practice this is the CASE-FOLD collision (`C1` and `c1`), which an uploader will not distinguish: an exact repeat is already refused upstream — two components sharing a ref by the compiler (`duplicate_component_ref`, naming the ref), two placements sharing one by `Validate` (`duplicate_assembly_designator`). |
| `assembly_reference_set_mismatch` | the BOM and the CPL name different designators after expansion. |
| `assembly_row_ref_limit` | a grouped BOM row carries more designators than the profile's `max_refs_per_row`, where a house would silently truncate the tail. |
| `assembly_placements_too_close` | two designators on one side sit closer than the profile's `min_designator_separation_mm` — usually a synthetic expansion whose `offset_mm` is missing or zero. |
| `assembly_empty_expansion` | `placements` is authored and names nothing, which resolves back to a single part under the component's own ref. |
| `assembly_paste_undecided` | a not-populated part's lands take paste and `paste` is still `auto`. |
| `assembly_missing_identity` | a populated part lacks an identity field the selected profile requires. |
| `assembly_non_metric_coordinates` | the selected profile states a coordinate unit other than millimetres. |

The per-row and per-placement thresholds are **profile parameters**, not
constants: the figures a particular house publishes are dialect facts the service
profile supplies.

**Advisories do not refuse.** An export also returns `advisories[]` — things the
pipeline could not measure, which a caller should show and a human should judge.
Today there is one: `assembly_anchor_unmeasured`, a **populated** part whose
footprint draws neither a fab body outline nor a sized land, so the emitted
coordinate is its drawn origin rather than a measured centre (see "The assembly
anchor"). Silk-only furniture lands there legitimately, which is why it cannot be
a gate.

### The legacy `assembly: exclude` scalar

The block began as a bare scalar, `assembly: exclude`, marking board
**furniture** (a fiducial, a silk logo) that must never reach a BOM or CPL row.
Boards in the field still carry it. **Both codecs accept it and migrate it on
the spot** to the structured non-populated state:

```
assembly: exclude     ==>     assembly: {populate: false}
```

so exactly one shape reaches every reader and no consumer branches on the
authored form. A migrated board re-emits in the structured form the next time it
is serialized; that rewrite **is** the migration. A scalar other than `exclude`
refuses — a typo reading as "not excluded" would land a fiducial in a BOM with a
fabricated part number.

### Precedence: board YAML wins over the footprint lock

The footprint lock (`pcb/library/footprints.lock.json`) carries its own
`assembly` block per entry — `mpn`, `dist_part_numbers`, `package`,
`orientation_convention`. **That block is PROVENANCE ABOUT THE FOOTPRINT, not an
assertion about any board that places it**: it records which part the geometry
was drawn and blessed for, and it rides the bless report so a reviewer sees the
identity the lock will carry.

**The board YAML is the sole authority for a board's assembly data.** No
compiler, exporter or validator reads a lock's assembly fields into a board, and
a lock value is never a fallback for a missing board value — a populated
component with no identity is a **named refusal**, not a silent library lookup.
Where the two disagree there is nothing to reconcile; the lock is a note about
the drawing, the YAML is the order.

### Where `x_mm` / `y_mm` actually put a footprint

A component's `x_mm` / `y_mm` place the **footprint's own origin** — the datum
the `.kicad_mod` states its pad `(at …)` offsets relative to. Resolution applies
it verbatim: every land, graphic and courtyard point is
`origin + rotate(local_offset)` (`compile_board._place_component` via
`geometry.PlacementTransform`). Nothing re-anchors it.

Where that origin *sits on the part* is a property of the footprint, and the
seed library is split down the middle — re-measured over
`pcb/library/footprints/` (39 footprints), **14 put their origin on pin 1 and
25 do not**; separately, **18 resolve an assembly anchor somewhere other than
their origin** (see "The assembly anchor" below). The two counts are not the
same set: a single-pad fiducial or test point has pin 1 on the origin *and* its
body centred there, while a couple of connectors are body-off-origin without
having pin 1 there.

| footprint | pin 1 relative to origin |
|---|---|
| `Package_DIP:DIP-6_W7.62mm_Socket` | `(0, 0)` — origin **is** pin 1 |
| `Connector_PinSocket_2.54mm:PinSocket_1x07_P2.54mm_Vertical` | `(0, 0)` — origin **is** pin 1 |
| `Resistor_SMD:R_0805_2012Metric` | `(-0.9125, 0)` — origin is the **body centre** |
| `Package_TO_SOT_SMD:SOT-23` | `(-0.9375, -0.95)` — origin is the **body centre** |
| `Package_DFN_QFN:VQFN-16-1EP_3x3mm_P0.5mm_EP1.68x1.68mm` | `(-1.4625, -0.75)` — origin is the **body centre** |

So "the origin is pin 1" is **true only of KiCad's through-hole connector and
DIP families**, and false for every SMD chip footprint here. Under FULL geometry authority (a
component carrying its own `pads` key, see "Geometry authority") the origin is
whatever datum the board author wrote those pad offsets against, and no library
is consulted at all.

The practical consequence: **the placement position is not an assembly
centroid**, and a pick-and-place file that emits it as one is wrong by half a
package on most SMD parts. Deriving that centroid is the assembly exporter's
job, not this field's — and it does it: see "The assembly anchor" below.

### The assembly anchor

Every physically placed part carries a **resolved assembly anchor**: the centre
of its body's bounding box, in board millimetres, composed through the
component's own rotation and side. That is the coordinate the CPL emits, and it
is deliberately not `x_mm`/`y_mm` — a house is told where to **centre** the part.

The anchor is measured from the footprint on a three-step ladder, and **which
step answered is recorded** on the placement (`anchor_basis`) rather than left
to be inferred:

| basis | meaning |
|---|---|
| `fab_outline` | the fab-layer (`F.Fab`/`B.Fab`) body outline — KiCad's own assembly drawing, and the right answer whenever a footprint has one. |
| `lands` | every pad's box, for a footprint that draws no fab outline. |
| `footprint_origin` | the footprint has neither — silk-only board furniture — so the anchor is the origin, **said out loud**. |
| `authored` | not measured at all: this placement stated its own `anchor_mm` (below). Its own token, so a figure a person wrote down is never reported as a box measured off a drawing. |

Silk and the courtyard are deliberately **not** bases. Silk is drawn asymmetric
on purpose (a cathode bar, a pin-1 dot): measured on this library, `D_SMA`'s
silk box centre sits 3.05 mm from its fab box centre. A courtyard is a keep-out
envelope drawn larger than the part, by different margins on different edges.

`assembly.placements` composes on top of this: each authored `offset_mm` is
resolved in the parent's own local frame — through the parent's rotation and
the bottom-side mirror — and each expanded part gets its own anchor, its own
composed rotation and its own CPL row. On the bottom side a per-placement
`rotation_deg` **subtracts** from the parent's rather than adding, because the
side mirror turns a rotation into its inverse.

#### A placement may state its own anchor (`anchor_mm`)

An expansion child has **no geometry of its own** — the parent's footprint draws
all of it, and the child is a ref plus a transform. So with nothing authored,
the one anchor measured off the parent's whole body is handed to every child.
That is right when the drawing **is** the part, and wrong the moment one drawing
spreads several parts across itself.

The DevKit socket set is the worked case. It draws one `F.Fab` body box over
both strips — `(-12.93, -1.1)..(12.93, 62.797)`, centring at `(0, 30.8485)` —
which is the module that plugs in, not either soldered part. Its two 22-pad rows
sit at x `-11.43` and `+11.43`, each spanning y `0..53.34`, so each **strip**
centres at `(±11.43, 26.67)`. The inherited anchor lies between the two strips
and on neither, 4.1785 mm north of both.

**Nothing in the order path catches that.** The only gate that looks at where
parts are asks whether two designators are too *close*
(`assembly_placements_too_close`); two anchors a correct 22.86 mm apart clear it
whatever point they are both measured from. Both files build, and no advisory
fires — the anchors *were* measured, off the wrong body. The first thing that
notices is a person reading a placement preview.

`anchor_mm` is the answer:

```yaml
placements:
  - {ref: U1S_A, offset_mm: {x: -11.43, y: 0}, anchor_mm: {x: 0, y: 26.67}}
  - {ref: U1S_B, offset_mm: {x: 11.43, y: 0}, anchor_mm: {x: 0, y: 26.67}}
```

* It is stated in **this placement's own local frame**, before the parent's
  rotation and side — the same frame `offset_mm`'s result is in — and it is then
  composed through the same transform that places the copper. It is not a board
  coordinate.
* **Absent means absent**: the parent-measured anchor still applies and a board
  that does not author one is unchanged. An authored `{x: 0, y: 0}` is a real
  answer ("this part's centre is its own origin"), not an absence, and both
  codecs round-trip it rather than dropping the key.
* Both numbers above come off the **purchased part**: `11.43` is half the
  22.86 mm row spacing the footprint states in its own `descr`, and `26.67` is
  half a 1x22 strip's pin span (21 × 2.54 / 2). That is the point of the key —
  a compensating offset that folded in the `4.1785` gap would be derivable only
  by opening the `.kicad_mod`.
* A placement that authors one records the `authored` basis, so no consumer is
  told the number was measured.

## Trace angles (`design_rules.allowed_trace_angles_deg`)

The directions this board's traces are allowed to run in. **Optional, and
absent means unconstrained** — which is what almost every board wants and what
every reader spells the same way (the compiler resolves an absent key to an
empty tuple, and the geometric DRC reports `gc12_trace_direction` as *not
evaluated* rather than clean).

**It is BOARD state, not manufacturer-profile state.** A rule profile records
what a board HOUSE publishes, and no house requires orthogonal routing;
Manhattan is a design style its author chose. Putting it in a profile would
assert a fab capability that does not exist.

**The frame.** An entry is a direction measured **from +X toward +Y in the
board's own millimetre frame**, which is **y-down** — the frame every `x_mm` /
`y_mm` in this file uses. On screen the angle therefore sweeps *clockwise*, and
`45` names the **down-and-right** diagonal.

A direction and its reverse are **one constraint**, so every entry folds into
`[0, 180)` on load: `0`, `180` and `-180` are three spellings of the same
horizontal rule, and `-90` folds to `90`. Duplicates after folding collapse.

The two named styles the panel's Options menu offers:

| Style | Set | Meaning |
|---|---|---|
| Manhattan | `[0, 90]` | orthogonal only |
| Octilinear | `[0, 45, 90, 135]` | orthogonal plus both diagonals — **the default a new board is created with** |
| Free | *key absent* | no direction constraint |

Both named sets are closed under the y-flip, so for them the frame above is
invisible. An **asymmetric** set (a board declaring only `30`, say) is read in
the board frame, which is the reason the frame is written down here.

**Malformed is an ERROR, not an ignored key.** A non-list, an empty list, a
non-numeric entry or a non-finite one refuses the board with `bad_trace_angles`.
A board that ASKS for a direction constraint and silently gets none is the
fail-open direction, and it is invisible: every trace passes a check that never
ran. "No constraint" is spelled by **omitting the key**, never by `[]`.

Three surfaces read this one key and must never disagree about it:

- `pcb_worker.compile_board._allowed_trace_angles` — the fold on load;
- `pcb_worker.drc_geometric._check_gc12_trace_direction` — the check, measuring
  a **perpendicular** deviation (1 um) rather than an angle, because an angular
  tolerance is scale-dependent;
- `pcb/ui/model/pcb_trace_angles.gd` — the panel's Trace-tool snap and the
  Options menu, folding identically and on the same tolerance, so a run the
  tool draws is a run the check passes.

## Board graphics

`board_graphics` is artwork the **board** owns rather than a component: a
copyright line, a board name, a polarity mark, a courtyard note.

Every other graphic primitive is owned by a footprint and placed by that
component's transform, so without this collection "a line of text on the back of
this board" has no legal owner: it has to be hung off whatever part happens to be
nearby, as absolute board coordinates that the part's own placement corrupts the
moment anyone moves it.

### The entry

| field | applies to | meaning |
|---|---|---|
| `id` | all | minted `"graphic:<32hex>"` (see "Persistent identity") |
| `layer` | all | `F.SilkS`, `B.SilkS`, `F.CrtYd` or `B.CrtYd` — **nothing else** |
| `kind` | all | `text`, `line`, `circle`, `poly`, `polyline`, `rect` |
| `width` | all | stroke width in mm; defaults to the silk floor (0.15) |
| `text` | `text` | the string |
| `position` | `text` | `{x_mm, y_mm}` anchor; the baseline sits on `y_mm` |
| `size_mm` | `text` | **cap height** in mm (default 1.0) |
| `rotation_deg` | `text` | rotation about the anchor (default 0) |
| `h_align` | `text` | `left` (default) or `center` |
| `mirror` | `text` | override the layer-derived mirroring; normally absent |
| `start` / `end` | `line`, `rect` | two points; for `rect`, opposite corners |
| `center` / `radius` | `circle` | centre point and radius in mm |
| `points` | `poly`, `polyline` | ordered points — `poly` **closes**, `polyline` does not |

Points are the canonical board-level `{x_mm, y_mm}` mapping, the same shape
`traces[].points`, `zones[].outline` and `cutouts[].outline` use — **not** the
bare `[x, y]` pair a component's own `graphics` ride with. Go decodes the typed
`Points []Point` from that mapping alone, so the worker's parser is strict about
it too: one shape on both sides, or a board parses in one language and is
refused by the codec that gates every load.

### Text stores what it SAYS, not its strokes

A `text` entry never carries geometry. The strokes are derived on every compile
from the built-in stroke font (`worker/pcb_worker/board_font.py`, mirrored for
the panel in `ui/model/pcb_board_font_data.gd`), so:

- the source stays readable and editable — fixing a typo is an edit to one
  string, not a regeneration of a hundred polylines;
- the geometry cannot go stale if the font is ever corrected;
- what the editor draws and what the fab receives come from **one** table.

One entry expands to N stroke primitives in the IR, with derived ids
`<id>#<k>`. Those derived ids are internal — they exist because the IR needs
per-primitive identity for diagnostics. Selection, delete-by-id and undo all
operate on the single source `id`, so one text graphic is one object to a user
however many strokes it draws.

The font covers all 95 printable ASCII characters. Anything else renders as a
**box** and is named in the authoring verb's `missing_glyphs` reply — never
silently dropped, because a dropped character shortens a legend without saying
so, and a `?` would be a lie the reader cannot detect (`?` is a real glyph).

### Back-side text

`B.SilkS` text is **mirror-written**, automatically, derived from the layer.

A Gerber is plotted as seen from the **top, through the board**, so back legend
must be mirrored in the file to read correctly once the board is flipped. Tying
that to the layer rather than to an authored flag means a board cannot carry
back text that comes out backwards on the fab.

**The mirror is about the text's own anchor, not the board origin.** "Minerva
v2" at `size_mm: 1.5` anchored at `x_mm: 10` spans x ∈ [10.0, 21.5] on `F.SilkS`
and x ∈ [-1.5, 10.0] on `B.SilkS` — reflections about x = 10. Reflecting about
x = 0 would put the label at [-21.5, -10.0], off the board entirely, and would
mean that asking for text at a position *moved* it. With `h_align: center` the
text mirrors in place, which is usually what a back-side label wants.

The mirror is applied **once**, when the strokes are derived. The emitters apply
none of their own: a board graphic is board-absolute, so it takes the same
`pre_placed` path a compiler-placed component graphic takes — the layer is
authoritative for side and no further mirror may be applied. Applying a second
one at emission time is risk **R7**, and it would read backwards on the
fabricated board while every YAML-level check stayed green, which is why the
oracle inspects the emitted Gerber with an independent parser rather than
trusting the emitter's self-report
(`worker/tests/test_board_graphics.py::test_back_silk_gerber_carries_the_mirrored_strokes`).

### Layers are fail-closed

Silk and courtyard only, and both exclusions are refusals rather than drops:

- **Copper** would be unconnected metal that routing and geometric DRC must
  reason about with no net — both already treat a copper board graphic as
  `unsupported_geometry`.
- **`Edge.Cuts`** already has an owner: the board profile and its `cutouts`. A
  second way to draw the rim is a second answer to "how big is this board".

A malformed or out-of-vocabulary entry is an **error** (`invalid_board_graphic`),
never a silent drop. That is the opposite of the warn-and-drop ruling for
*footprint* silk, deliberately: footprint silk arrives in bulk from a vendored
library nobody curated, while a board graphic is one object a person placed on
purpose, whose disappearance would be invisible.

Courtyard graphics are stored, drawn on the canvas and carried into the KiCad
export, but emit **no Gerber** — courtyard is a documentation layer that is not
among KiCad's nine default fab layers, exactly as a component's own courtyard
geometry is skipped.

### What consumes them

| consumer | behaviour |
|---|---|
| Gerber (`build_gerbers_ir`) | silk strokes land in `F_SilkS` / `B_SilkS`; courtyard skipped |
| KiCad export | `gr_line` / `gr_arc` / `gr_circle` on the graphic's own layer |
| Geometric DRC | projected as silk primitives with `origin: "board_graphic"` |
| Panel | drawn on the canvas, selectable, deletable, one undo step |

## Persistent identity (schema v2)

Schema v2 introduces **persistent, mint-once entity identity**. This is the
contract half of migration `019f802ca3af` — the gate before any identity-dependent
consumer (DRC, routing) may key off a compiled board. It exists because the
pre-v2 compiler derived trace/via/hole ids from their **ordinal** position, so
inserting or reordering a child silently changed every later child's id and broke
any reference to it (Sol K2 review).

### The `id` field

`Board`, `Trace`, `Via`, `Hole`, `Zone`, `Cutout`, and `Graphic` carry an opaque
string `id` (`"board:<hex>"`, `"trace:<hex>"`, `"graphic:<hex>"`, …):

- **Mint-once, never recomputed.** The id is assigned exactly once — by the
  v1→v2 migration for existing boards, or at creation for new ones — and is *not*
  a content hash. A content hash would move when a trace's waypoints or the
  board's name change; identity must survive those edits, which is the whole
  point. Consumers key off `id`, not off position or content.
- **Globally unique by construction**, so it subsumes the earlier
  "board-namespace every child id" rule — two boards cannot collide because each
  mint is independent.
- **`omitempty`.** A v1 board has no ids; the field is absent, so a pre-migration
  board round-trips byte-identically. This makes v2 an *additive* contract change.

Entities that already have a stable identity keep it and gain **no** opaque id:
`Component` → `ref`, `Net` → `name`, `Pin` → (`ref`, `number`). Segments are
derived children of a trace (N points → N-1 segments) and are identified by the
persisted trace id + ordinal — inserting a waypoint renumbers that one trace's
segments, which is inherent and acceptable since segments are never referenced
independently. `zone` and `cutout` ids mint and validate exactly like
`trace`/`via`/`hole` ids — see "Zones" and "Cut-outs" above for their compiled
behavior.

**Where a zone's id comes from.** On the Go side `MigrateV1toV2` is still the
only minter, and it is gated on `Version == 1`; serialize never mints, it writes
what it is given. So a HAND-EDITED **v2** board with a zone carrying no `id`
still fails `unminted_persistent_id` unless the author writes a
`zone:<32 lowercase hex>` token themselves (a **v1** board is fine: author
`zones:` with no `id` and migration mints it). That is the same behaviour a
hand-added trace has, and it fails closed rather than silently accepting an
id-less entity.

What has changed is that hand-editing is no longer the only route. **The PCB
plugin mints persistent ids UI-side for every entity it creates** — traces, vias,
zones, cut-outs and placements alike — through one policy file,
`ui/model/pcb_entity_id.gd`, whose `mint`/`is_minted` match `isMintedID`'s width
and alphabet exactly. Copper drawn in the editor is identity-complete from the
moment it is created, on v1 and v2 boards alike.

**Why the shape matters beyond hand-editing.** `isMintedID` reads an ORDINAL
handle (`trace_7`, `via_12`) as unminted, and `MigrateV1toV2` — which runs on
**every** `pcb.deserialize` of a v1 board — replaces an unminted id with a fresh
random token. An id that is not minted in the contract shape therefore changes on
every load: an id held across `export_yaml` → `load_board` comes back as
`missing_via_ids`, and a routing sidecar's `committed_via_ids` go dangling.
Minting UI-side is what makes an id survive the round trip unchanged. Ordinal ids
are still **accepted** everywhere (old boards, `.minpcb` imports,
`import_trace_geometry` payloads); nothing mints one.

### Geometry authority: full vs partial

A component's geometry is **FULL** when it carries a `pads` key holding a list.
That list is then the sole pad authority and the footprint library is **not
consulted at all** — so a board compiles, DRCs and fabricates on a machine whose
library does not stock the part it was authored against. `graphics`, present or
absent, is the sole graphic authority beside it; a component with pads and no
graphics compiles with a `component_graphics_absent` warning, because it really
will be fabricated with no silkscreen or courtyard. An explicit `pads: []` means
exactly **zero pads**, which is how a graphics-only pseudo-component (a logo, a
revision marking) is expressed.

Geometry is **PARTIAL** when there is no `pads` key. The `footprint` ref is
resolved from the library and stays the geometry authority, with inline `pins`
acting as per-pad-number overrides — the rule described below. A component with
no inline pads and an unresolvable ref still fails `footprint_unresolved`.

The trigger is the `pads` **key**, not its contents, so the two states cannot
overlap. A `pads` list that cannot be read as geometry is refused
(`invalid_component_geometry`); it is never quietly demoted to the library path,
which would substitute one part's copper for another's.

Each pad carries `{number, type, shape, position{x,y}, size{width,height},
drill{x,y}, layers}` plus the fab-affecting optionals the footprint authored —
`corner_rratio`, `raw_shape`, `solder_mask_margin`, `solder_paste_margin`,
`rotation`. Those five are **present-only**: absent means the footprint stated
none, which is a different fact from stating zero, and every producer and
consumer of this shape preserves the difference. `size: {width: null, height:
null}` likewise means "no authored size", and the fail-closed sizeless-SMD gate
is what refuses to fabricate it.

### The authored designator placement: `refdes_placement`

A reference designator ("R1", "U3") is in no IR — it is synthesized from the
component's `ref` at emission time — so *where* it prints is its own question,
with **one precedence rule** everywhere (`worker/pcb_worker/refdes_anchor.py`):

1. the component's **optional** `refdes_placement` block — what a human or an
   agent SET, through `minerva_pcb_set_refdes`;
2. else the footprint's own authored reference `fp_text` on F.SilkS;
3. else the anchor **derived** from the footprint's body: centred one clearance
   above everything it occupies — its courtyard, its drawn outline and its
   lands, **unioned**, so a land or an outline stroke outside the courtyard
   still pushes the label clear.

```yaml
components:
  - ref: SW1
    footprint: EVP-ASAC1A:SW_EVP-ASAC1A
    x_mm: 20
    y_mm: 14
    refdes_placement:         # OPTIONAL — absent means "nobody chose"
      x_mm: 0                 # footprint-LOCAL mm, the part's own y-down frame
      y_mm: -4.2              # the text BASELINE; glyphs grow upward from it
      rotation_deg: 0         # within the footprint frame
      size_mm: 1.0            # cap height
      hidden: false           # true prints no designator for this component
```

**Absent means not authored**, and the derivation applies unchanged; a board that
has never used `set_refdes` serializes exactly as it did before the key existed.
The derived value is **never** written back as authored — that is what keeps
"nobody chose" a fact rule 3 is free to answer differently on the next resolve,
or on a machine with a different library.

The block is a **partial overlay**: every field it omits keeps rules 2/3's
answer, so `refdes_placement: {hidden: true}` suppresses one designator without
freezing where it would otherwise have gone.

Because the placement is per **component**, it is not folded into the footprint
definition — definitions are interned by content id, and two components sharing
one footprint would fork it in two and move the `footprint_id` the library lock
and the BOM group by. The compiler resolves the rule once onto
`ResolvedComponent.refdes`, and the Gerber emitter, the DRC silk projection, the
GC9 placement advisories and the KiCad export all read that single field.

It is **authored source, not derived**: `refdes_placement` is a known component
field on the Go side and is deliberately *not* in `DerivedComponentKeys`, so
`pcb.deserialize` carries it through untouched. Its sibling `refdes_anchor` — the
*effective* placement a resolve computed — **is** derived, and is dropped and
recomputed at that boundary.

Note for the FULL case above: that arm never reads the library, so a footprint's
own `fp_text` is genuinely unavailable to it and the rule there is 1-else-3.
Authoring `refdes_placement` is the only way to state a placement for a component
whose board owns its geometry.

### Pin-geometry authority: the `override` sub-struct

Within the PARTIAL case the **locked footprint is authoritative** for pad
geometry. The inline pin fields `drill_mm` / `annulus_diameter_mm` /
`pad_width_mm` / `pad_height_mm` / `plated` are **deprecated in v2**: they
duplicate what the footprint defines, and a board carrying both forces consumers
to guess which wins.

A v2 board expresses an *intentional* deviation only through the explicit typed
`override` sub-struct on a pin:

```yaml
pins:
  - number: "2"
    x_mm: 0                   # must still AGREE with the footprint's own pad
    y_mm: 2.54                # position — DIP-6 pin 2, as in the schema example
    override:                 # present ONLY when deviating from the footprint
      drill_mm: 0.9           # every field optional; unset = use the footprint's value
```

The deprecated inline fields remain modeled so v1 boards round-trip losslessly;
the v1→v2 migration folds inline geometry that *differs* from the footprint into
`override` and drops what *matches*. A v2 producer must not emit the inline fields.

### Shared validation boundary (Go ↔ Python)

`version` dispatch, required/type-checked fields, id validity, `override`
semantics, and canonical-number constraints are a **single spec both the Go codec
and the Python compiler enforce**, so the two cannot drift. The spec **is**
backed by committed cross-language vectors under `pcb/spec/vectors/` — each case
(`{input.yaml, expect: valid|error, code}`) is loaded and asserted identically by
both `internal/board/vectors_test.go` (Go) and the worker's
`test_board_v2_vectors.py` (Python), with a committed floor
(`minVectors` / `_MIN_VECTORS`) guarding against silent loss. This is the cross-language analogue of the worker's `fab_capability`
drift test.

> **Round status (019f802ca3af):** SHIPPED. Round A landed the contract *shape* —
> the `id`/`override` fields and this spec — and the v1→v2 mint-and-write migration
> (Go), the Python v2 compiler path that *requires* persisted ids (fail-closed), and
> the committed cross-language vectors (`pcb/spec/vectors/`, run by both languages)
> are all now in place.

## `.minpcb` (legacy JSON) → canonical mapping

The in-tree Godot editor's `PCBData.to_dict()` shape maps as follows. The
importer (`board.ImportMinpcb`) applies this and returns a warnings list.

| Legacy `.minpcb` (JSON)                     | Canonical (`_mm` YAML)          | Notes |
|---------------------------------------------|---------------------------------|-------|
| `board_name`                                | `name`                          | |
| `board_width` / `board_height`              | `width_mm` / `height_mm`        | |
| `grid_size`                                 | `grid_mm`                       | |
| `layers`                                    | `layers`                        | copied as-is; must satisfy the stack rules in "Layer stack" |
| `components` (`id`→object **map**)          | `components` (**list**, sorted by id) | deterministic order |
| component `id`                              | `ref`                           | reference designator |
| component `position.{x,y}`                  | `x_mm` / `y_mm`                 | the footprint's own origin — see "Where x_mm / y_mm actually put a footprint" |
| component `rotation`                        | `rotation_deg`                  | |
| component `properties.value`               | `value`                         | |
| component `pins` (`name`→`{x,y}` map)       | `pins` (list of `{number,x_mm,y_mm}`) | key → `number` |
| component render fields (`pads`, `color`, `local_bounds`, `width`, `height`, `has_pad_geometry`, `bbox_center_offset`, `label_visible`, `locked`, `footprint_id`) | component `Extra` (inline) | carried losslessly into YAML, no warning. `pads` is **not** render-only to the compiler — see "Geometry authority: full vs partial" |
| `nets` (`name`→object map)                  | `nets` (list, sorted by name)   | |
| net `pins` (`[{component_id, pin_name}]`)   | `pins` (`["U1.8", ...]`)        | flattened to `Ref.Pad` |
| net `color` / `properties` / `is_power_net` | net `Extra` (inline)            | carried losslessly |
| `traces` (`id`→object map)                  | `traces` (list, sorted by id)   | |
| trace `net_name` / `waypoints` / `width`    | `net` / `points` / `width_mm`   | |
| trace `id`                                  | trace `id` (modeled, v2)        | maps to the persistent `id` field, not `Extra` — see "Persistent identity" |
| trace `locked`                              | trace `Extra`                   | carried losslessly |
| `vias` (array; `position`, `size`, `drill`, `net_name`) | `vias` (`x_mm`,`y_mm`,`diameter_mm`,`drill_mm`,`net`) | rest → `Extra` |
| `annotations` (`id`→object map)             | `annotations` (list of opaque blobs) | **not interpreted** |
| `route_hints` (`id`→object map)             | `route_hints` (list of opaque blobs) | **not interpreted** |

### Component groups (`properties.group_id`)

Two board components that are really **one physical part** (an amplifier module
whose connector is drawn as its own footprint, say) can be stamped into a
**group**: they then select, drag, rotate and delete as a rigid unit, and one
member's offset from the group anchor is numerically editable once the real part
is measured.

**Membership lives in the component's `properties` map, under `group_id`** —
never as a top-level component key. That is a measured constraint, not a style
choice: `board.ImportMinpcb` walks every per-component key against
`knownComponentFields` (`pcb/internal/board/minpcb.go`) and emits
`component "X": non-canonical field "Y" preserved as passthrough` for anything
outside it. `properties` **is** in that set and is carried whole, so a group id
inside it rides every serialization path — `to_dict`, `to_board_dict`, both load
halves, undo snapshots, and the panel's `host_owned` save/load — with **no Go
change and no warning**. A top-level `group_id` would have needed that Go map
extended.

Nothing outside the panel interprets the value. To Go, to the worker and to the
fab outputs it is one more opaque `properties` entry, so grouping changes no
netlist, no copper and no CAM.

```yaml
components:
  - ref: AMP1
    x_mm: 40.0
    y_mm: 25.0
    properties:
      group_id: "group:6f1c…"     # 32 lowercase hex, minted by the panel
  - ref: OUT
    x_mm: 47.62
    y_mm: 25.0
    properties:
      group_id: "group:6f1c…"     # same id ⇒ same physical part
```

**A group *is* the set of components sharing an id** — there is no group registry
block to keep in sync, no group record to go stale, and deleting the last member
deletes the group. The **anchor** is the member with the lowest `ref` in sorted
order, which is stable across a save/reload because `to_board_dict` emits
components sorted by that same key; every other member's offset is defined
against it.

**Ungrouping erases the key** rather than writing an empty string, so a board
that was grouped and then ungrouped serializes identically to one that never was.

**CSV is lossy for `group_id`, exactly as it already is for `locked`.** The
7-column placement CSV (`to_csv`/`from_csv`: `id,footprint,x,y,rotation,layer,
value`) has never carried render or state fields, and `from_csv` builds a **fresh**
component per row — so a CSV round trip drops `locked`, `color`, `pads` and now
`group_id` alike. This is the pre-existing rule, not a new asymmetry: CSV is a
placement interchange, and `.pcbskel`/canonical YAML is the lossless one.

### `design_rules.trace_width_mm` and the editor's width preference (A7)

`design_rules.trace_width_mm` is the board's own answer to "how wide is a trace
here", and it is what the panel's trace tool arms with. Since round A7 the
plugin also carries a **plugin-scoped preference** of the same name
(`trace_width_mm`, stored under the plugin's data directory — see
`docs/tools.md`, "Trace width + preferences"), and the precedence between them
is fixed:

1. **the board's `design_rules.trace_width_mm` wins** whenever it declares one —
   a board is a document that states its own rules, and a preference carried
   from some other board must not override it;
2. the stored preference fills the case where the board declares **no** rule
   (missing, or a non-positive value, which is treated as no answer);
3. failing both, the editor's own default, 0.25 mm.

The preference never alters the board file, and a trace's own `width_mm` is
always what that trace was authored or re-widened to — neither the design rule
nor the preference is re-applied to existing copper.

### Net classes (`design_rules.net_classes`)

A net class states a stricter width/clearance **floor** for a named set of nets.
It is authored as a list under `design_rules`, and each entry both states its
rules and names its member nets:

```yaml
design_rules:
  clearance_mm: 0.2
  trace_width_mm: 0.25
  via_diameter_mm: 0.8
  via_drill_mm: 0.4
  net_classes:
    - name: Power
      members: [VCC, GND]
      min_trace_width_mm: 0.6
      min_clearance_mm: 0.4
```

**Membership lives on the class, not on the net.** There is no per-net class
key, and this is a durability decision rather than a stylistic one: the panel's
net model (`pcb/ui/model/pcb_net.gd`) serialises a **fixed** key set in
`to_board_dict`/`load_from_board_dict`, so a class key written onto a net would
be destroyed by any UI load/save round trip. `pcb/ui/model/pcb_data.gd`
round-trips `design_rules` wholesale, so a members list authored there survives.

**What a class may author.**

| key | required | meaning |
|---|---|---|
| `name` | yes | class identity; the IR `id` is derived from it |
| `members` | no | net names belonging to this class |
| `min_trace_width_mm` | no | this class's minimum trace width |
| `min_clearance_mm` | no | this class's minimum copper clearance |

Those two `min_`-prefixed values are the **only** rules a class may state,
because they are the only two any consumer reads:
`pcb_worker.methods._net_class_overrides` (the width a member net's copper is
routed at) and `pcb_worker.drc_geometric._net_class_minima` (the floors GC1 and
GC2 check that net against). The `NetClass` IR record also carries nominal
`trace_width_mm`, `via_diameter_mm` and `via_drill_mm` fields, and authoring one
gets `unsupported_design_rule` — because carrying a number that changes no routed
copper and no DRC floor would be a rule that lies about being in force.

That diagnostic has **two severities**, and which one you get depends on the
requested output set, not on the class:

- when `rules` is a requested output, it is an **ERROR** and the compile fails;
- otherwise it is a **WARNING**: the compile **succeeds** and the authored value
  is **dropped**.

The second branch is a genuine ignore, so it is worth being precise about who
can reach it. Every current production caller requests `rules` — both
`V1_FAB_OUTPUTS` and `V1_ROUTING_OUTPUTS` contain it — so in practice today the
field is refused. The warning branch exists for a CAM-only profile that does not
consume rules at all, where a fatality argued from DRC/routing would not apply;
it is reachable only by a caller that hand-builds an output set. Do not read
"refused" as unconditional.

A class's `id` is **not** authorable — it is derived from the class name and the
board, the same rule net ids follow — and an authored `id`, or any other
unrecognised key, is refused unconditionally, never silently overruled.

**Identity and membership are fail-closed** — these, unlike the field policy
above, are ERRORs under every output set. The compiler
(`compile_board._build_net_classes`, plus the member-existence pass in
`compile_board`) refuses, never ignores:

| diagnostic | severity | cause |
|---|---|---|
| `duplicate_net_class` | error | two classes declaring the same `name` |
| `net_class_unknown_member` | error | a `members` entry naming no declared net |
| `duplicate_net_class_membership` | error | one net claimed by two classes |
| `invalid_net_class` | error | malformed entry, unknown key, or a minimum that is not a positive number |
| `unsupported_design_rule` | error **or warning** | a class field no consumer reads — see the two-severity note above |

A class minimum is admitted through the **same** positive-number predicate the
board-level `design_rules` numbers go through, which is stricter than the IR's
own `NetClass` validation — a class is a design rule authored in the same block
by the same person, so `min_clearance_mm: 0` is refused here exactly as
`clearance_mm: 0` is.

**An unreferenced class is legal and constrains nothing.** Both consumers read
*referenced* classes only, so a class no net joins reaches no copper. Omitting
the whole `net_classes` key is likewise unchanged behaviour: every net compiles
with no class and every floor is the board's blanket one.

**Two surfaces refuse a class-carrying board rather than drop it silently:**

- `agent_router` (the standalone `agent-router` CLI) has no compiler and models
  no classes at all, so it fails closed instead of routing the same board at the
  blanket rules the worker would route wider.
- `pcb_worker.kicad._ir_board_dict` raises, because the `.kicad_pcb` it emits
  has no per-class channel; dropping classes would leave the KiCad DRC oracle
  checking a board the Python kernel checks at stricter floors.

### pcb-architect alignment

Field names prefer the pcb-architect / pcb-maker skill conventions where they
add clarity, and unify the two source dialects:

- `width_mm`/`height_mm` unify legacy `board_width` and pcb-architect
  `outline.width`.
- Net `pins` use pcb-architect's flat `"U1.VCC"` / `"U1.1"` string form (gerber-
  and diff-pair-friendly) rather than the legacy `{component_id, pin_name}`
  object form. Import uses the **pad number** on the left of the mapping, per the
  pcb-maker skill's numerical-pin-id rule.
- `design_rules` unifies pcb-architect's `constraints` block.

## The opaque-annotation rule

`annotations` and `route_hints` are transported **losslessly but never
interpreted** by this contract. They are `[]map[string]interface{}` blobs. The
legacy `id`→object map is flattened to a list; each blob keeps its `id` inside.
The annotation-migration child owns their semantics — do not add typed structs
for them here.

## Losslessness & the warnings list

`ImportMinpcb` never silently drops a field. Every source field is either
(a) mapped to a canonical field, (b) parked in a struct's inline `Extra` map so
it round-trips into the emitted YAML, or (c) reported in the returned
`warnings` slice. Fields that are known-legacy-but-non-canonical (render detail)
are parked in `Extra` quietly; genuinely unrecognized fields are parked in
`Extra` **and** flagged in `warnings` so the surprise is visible.

Note: `Extra` is `yaml:",inline"` and tagged `json:"-"`, but the nine Extra-bearing
structs carry **custom `MarshalJSON`/`UnmarshalJSON`** (`internal/board/json.go`)
that inline the unknown keys into the JSON object too — so `Extra` survives both
YAML↔YAML **and** the `pcb.deserialize` JSON boundary losslessly (modeled fields
always win a key collision). The canonical fields are the contract; `Extra` is the
forward-compat affordance, preserved on both wire formats.

## Channels (`pcb.serialize` / `pcb.deserialize`)

- `pcb.serialize` — args `{board: <canonical Board JSON>}` → `{yaml: "<source>"}`.
- `pcb.deserialize` — args `{yaml: "..."}` **or** `{minpcb_json: <legacy JSON>}`
  → `{board: <canonical Board dict>, warnings: [...]}`.
- Both fall back to the legacy project_file `{state}` echo when given neither, so
  the manifest's `project_file` host_owned save path is not regressed. The echo
  fallback applies only to genuinely absent args: non-empty but unparseable
  params return a parse error, never a silent `{ok}` echo.
- `pcb.collect_export` / `pcb.apply_export` remain `project_export` echo
  passthroughs.

## 64 KiB IPC payload caveat (gap register A-8)

Minerva's plugin IPC transport caps a single message at **64 KiB**.
`pcb.serialize` refuses at `MaxPayloadBytes` (60 KiB) and returns a structured
`{error: "payload_too_large", bytes: N}` rather than emitting a body the broker
would truncate mid-document. Large boards must be chunked by a future round —
this contract deliberately fails loud instead of corrupting silently.
