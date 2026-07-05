# PCB Board-Source Contract (canonical YAML)

The canonical board model is the single schema every downstream child consumes —
the Python geometry worker, the gerber exporter, and the panel port. It is
defined in Go at `pcb/internal/board/` and serialized as deterministic YAML.

Design priority: **durability of the contract over feature breadth.** Field
names are explicit and unit-suffixed (`_mm`, `_deg`) so no consumer guesses
units; unknown fields survive round-trips rather than being silently dropped.

## Schema

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
  diff_pair_gap_mm: 0.15
  diff_pair_width_mm: 0.2
components:
  - ref: U1                    # reference designator
    footprint: IC_DIP          # footprint type or KiCAD footprint id
    value: NE555               # optional
    x_mm: 20                   # footprint origin (pin-1 location, KiCAD convention)
    y_mm: 12
    rotation_deg: 90
    layer: top
    pins:
      - {number: "1", name: VCC, x_mm: 0, y_mm: 0}   # component-relative offsets
nets:
  - name: VCC
    pins: [U1.8, R1.1]         # "Ref.PadNumber" strings
traces:
  - net: VCC
    layer: top
    width_mm: 0.25
    points:                    # ordered polyline; N points = N-1 segments
      - {x_mm: 10, y_mm: 5}
      - {x_mm: 20, y_mm: 12}
vias:
  - {x_mm: 15, y_mm: 8, drill_mm: 0.4, diameter_mm: 0.8, net: VCC,
     from_layer: top, to_layer: bottom}
annotations: [...]             # OPAQUE passthrough (see below)
route_hints: [...]             # OPAQUE passthrough (see below)
```

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
| trace `id` / `locked`                       | trace `Extra`                   | carried losslessly |
| `vias` (array; `position`, `size`, `drill`, `net_name`) | `vias` (`x_mm`,`y_mm`,`diameter_mm`,`drill_mm`,`net`) | rest → `Extra` |
| `annotations` (`id`→object map)             | `annotations` (list of opaque blobs) | **not interpreted** |
| `route_hints` (`id`→object map)             | `route_hints` (list of opaque blobs) | **not interpreted** |

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

Note: `Extra` is `yaml:",inline"` but `json:"-"`. Unknown keys therefore survive
YAML↔YAML round-trips, but are **not** reflected into the JSON board dict
returned by `pcb.deserialize` (Go's `encoding/json` has no inline support). The
canonical fields are the contract; `Extra` is a YAML-side forward-compat
affordance.

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
