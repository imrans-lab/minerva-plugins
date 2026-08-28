# Model layering on the GD side (`pcb/ui/model/`)

The plugin's GDScript is three layers, and the rule for where new code goes
is the whole point of naming them.

## 1. Library modules — `pcb/ui/model/*.gd`, pure and static

| Module | Owns |
|---|---|
| `pcb_trace_geometry.gd` | THE one implementation of each trace-geometry primitive: point→segment, point→polyline, segment↔segment gaps (general and axis-aligned), polyline↔rect, length, Manhattan distance, axis checks and snaps, trace ends (`end_index_at`), translate, bounds. Tolerances are named and passed in (`degenerate_len_sq`, `tol`); tie-breaks are documented. |
| `pcb_bus_geometry.gd` | The parallel-bus construction: mitered offsets, pitch (`pitch_between` is the rule, `lane_pitch_between` the laid spacing, `LANE_PITCH_MARGIN_MM` past it), `bundle_routes` (pad-to-pad routes, via station, open-ended lanes), the clearance measurement, `clean_pick_order`. |
| `pcb_bus_labels.gd` | The words and colour a bus lane wears: `net_color` (the ratsnest's rule), lane labels/lines, the teach-line rules, the open-lane and clean-order sentences. |
| `pcb_layer_stack.gd` | Canonical layer names, KiCad aliases, via-span legality. |
| `pcb_copper_draw_order.gd` | The order the canvas paints copper in, as data: per layer, traces then that layer's lands; then through-hole lands and vias above the whole stack; then every drilled hole as a void. `pcb_canvas._draw_copper()` walks the list and only dispatches. |
| `pcb_staged_entities.gd`, `pcb_ratsnest.gd`, `pcb_spatial_index.gd`, `pcb_routing_workspace.gd`, … | Their own bounded concerns, same shape. |

New geometry goes into `pcb_trace_geometry.gd` — never into `pcb_canvas.gd`
or `panel_tools.gd`. Those two files draw and dispatch; when one of them needs
a distance, a projection, an end test or a bound, it calls the library. A
second copy of a primitive is a bug even when it is byte-identical, because
the two drift.

Pinned without a scene: every module here is `extends RefCounted` with
`static func`s, so `pcb/tests/gd/test_pcb_trace_geometry.gd`,
`test_pcb_bus_geometry.gd` and `test_bus_tool.gd`'s helper sections exercise
them with plain numbers and hand-derived expectations.

## 2. The model — `pcb_data.gd` and the entity scripts

`PCBData` is the board. Every mutation of it is a method ON it — a
**mutator** — and every mutator:

- validates and refuses in its own words (a `String` refusal, or `null`/`""`),
  changing nothing on refusal;
- writes exactly ONE change-journal row (`record_change`) naming what changed;
- emits its signals (`trace_changed`, `data_changed`, …);
- does **not** snapshot history. The CALLER owns the undo step: the canvas,
  `panel_tools.gd` and the panel call `save_to_history` once after the
  mutator(s) that make up one user-visible action, so a batch is one step and
  a refusal leaves no half-step behind.

`extend_trace`, `cut_trace`, `create_trace_entity`, `set_trace_width`,
`create_zone`, the via mutators and the bus's per-net `create_trace_entity`
calls all follow this shape; `bus_commit_plan` shows the batch form (N
mutators, one `save_to_history`, then the `add_bus` row).

Picks that answer a question about the board (`free_trace_end_at`,
`nearest_interior_vertex`, `trace_end_is_joined`, `get_trace_at`) also live on
`PCBData`, read the library for their geometry, and take the VIEW's visibility
predicate as a `Callable` rather than knowing about layer filters themselves.

## 3. The surfaces — `pcb_canvas.gd`, `panel_tools.gd`, `PCBPanel.gd`

The canvas turns gestures into model calls and draws; `panel_tools.gd` turns
MCP arguments into the same model calls and shapes replies; the panel wires
them and owns the toolbar and status line. Parity between a click and a verb
is by construction — both call one model function — so a rule that lives in a
surface instead of the model is a parity gap waiting to be measured.

## Preloads and the no-`class_name` rule

This is an OFF-TREE plugin: its scripts are not in Minerva's `res://` project,
so `class_name` cannot be used (a global class registered from outside the
project fails to resolve). Modules are reached by relative `preload()` and
typed by base class:

```gdscript
# from a model sibling
const PcbTraceGeometry := preload("pcb_trace_geometry.gd")
# from ui/
const PcbTraceGeometry := preload("model/pcb_trace_geometry.gd")
# from ui/kinds/
const _PcbTraceGeometry := preload("../model/pcb_trace_geometry.gd")
# from a test
const Geo := preload("res://../../minerva-plugins/pcb/ui/model/pcb_trace_geometry.gd")
```

Two files that preload each other are a cycle to avoid; when two surfaces
need one number, the number lives on the model (`PCBData.TRACE_SNAP_MM` is the
canvas's `TRACE_PAD_SNAP_MM` and the verbs' coordinate reach) rather than on
either surface.
