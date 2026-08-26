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
    x_mm: 20                   # footprint origin (pin-1 location, KiCAD convention)
    y_mm: 12
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
`ui/model/pcb_layer_stack.gd` — and the two directions are deliberately
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

These two keys are compile-time rules only: `Validate` (Go) carries them in
`design_rules` untyped and does not check them, so a malformed value (negative,
non-numeric) passes `validate` and is refused by `compile` with
`invalid_design_rule`.

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

## Persistent identity (schema v2)

Schema v2 introduces **persistent, mint-once entity identity**. This is the
contract half of migration `019f802ca3af` — the gate before any identity-dependent
consumer (DRC, routing) may key off a compiled board. It exists because the
pre-v2 compiler derived trace/via/hole ids from their **ordinal** position, so
inserting or reordering a child silently changed every later child's id and broke
any reference to it (Sol K2 review).

### The `id` field

`Board`, `Trace`, `Via`, `Hole`, `Zone`, and `Cutout` carry an opaque string `id`
(`"board:<hex>"`, `"trace:<hex>"`, …):

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

What has changed is that hand-editing is no longer the only route. The PCB
plugin's canvas now has a zone creation tool, and `pcb_data.create_zone` mints a
real `zone:<hex>` id through `mint_entity_id` — the FIRST UI-side minter of a
persistent id, matching `isMintedID`'s width and alphabet exactly. A zone drawn
in the editor is therefore identity-complete from the moment it is created, on
v1 and v2 boards alike.

### Pin-geometry authority: the `override` sub-struct

The **locked footprint is authoritative** for pad geometry. The inline pin
fields `drill_mm` / `annulus_diameter_mm` / `pad_width_mm` / `pad_height_mm` /
`plated` are **deprecated in v2**: they duplicate what the footprint defines, and
a board carrying both forces consumers to guess which wins.

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
| component `position.{x,y}`                  | `x_mm` / `y_mm`                 | origin = pin 1 |
| component `rotation`                        | `rotation_deg`                  | |
| component `properties.value`               | `value`                         | |
| component `pins` (`name`→`{x,y}` map)       | `pins` (list of `{number,x_mm,y_mm}`) | key → `number` |
| component render fields (`pads`, `color`, `local_bounds`, `width`, `height`, `has_pad_geometry`, `bbox_center_offset`, `label_visible`, `locked`, `footprint_id`) | component `Extra` (inline) | carried losslessly into YAML, no warning |
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
