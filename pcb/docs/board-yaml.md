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
layers: [top, bottom]          # optional layer stack
origin: {x_mm: 0, y_mm: 0}     # optional board origin
design_rules:                  # board-wide manufacturing constraints
  clearance_mm: 0.2
  trace_width_mm: 0.25
  via_diameter_mm: 0.8
  via_drill_mm: 0.4
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
                                # checked informally by pcb_check_libraries when present
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
one, and rejects `annulus_mm` on an unplated hole. The `pcb_gerbers` exporter uses
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

`Board`, `Trace`, `Via`, and `Hole` carry an opaque string `id`
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
independently. `zone` ids are reserved for when zones are modeled (v1/v2 cannot
fabricate zones at all, so no `Zone` struct exists yet).

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
| `layers`                                    | `layers`                        | |
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
