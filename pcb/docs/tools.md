# PCB agent tool surface — disposition & re-homing

Docket: minerva `019eb47e72a7` · DCR `019dc140`.

The PCB plugin's agent-facing tools were split out of the legacy in-tree
`MCPPCBTools.gd` (~31 tools, one monolith bound to the old in-tree `PCBEditor`).
This table records where each legacy tool went. Three destinations:

- **PANEL-LOCAL** — re-homed to a NEW thin Minerva-core module,
  `src/Scripts/Services/MCP/Modules/MCPPcbPanelTools.gd`, following the CAD
  precedent (`MCPCadTools`). Resolves the live plugin panel via
  `AnnotationHostRegistry.get_host(editor_name)` → `PcbAnnotationHost`
  (duck-typed, no plugin `class_name` references) and drives the board model
  through `host.get_board_data()` / `host.get_spatial_index()`.
- **WORKER** — already shipped as Go/worker MCP tools (`minerva_pcb_*`, round
  D0-expose 019fa486b408 — previously bare `pcb_*`, renamed so the manifest can
  declare them under the same name the broker registers); not re-created.
- **RETIRED** — superseded by a core/platform surface; NOT reimplemented.

The panel-local tool **names are byte-identical** to the legacy names, so the
agent-facing surface is unchanged. See "Coexistence & name collision" below for
how both surfaces run side-by-side until cutover.

## Panel-local (new core module `MCPPcbPanelTools`)

Same `minerva_pcb_<suffix>` names as legacy; same args; equivalent return JSON.

| Tool | Notes |
|---|---|
| `minerva_pcb_set_board_size` | model `set_board_size` (journalled resize) |
| `minerva_pcb_get_components` | golden-parity return shape |
| `minerva_pcb_get_nets` | |
| `minerva_pcb_get_pin_position` | includes `available_pins` self-correction |
| `minerva_pcb_add_component` | golden-parity; `data.new_component()` factory + `set_footprint_by_name`; a `Lib:Part` footprint resolves through the `pcb.footprint_geometry` channel first and lands the library's real pads/silk (`pcb_library_part.gd`) |
| `minerva_pcb_move_component` | golden-parity; snapped |
| `minerva_pcb_move_relative` | NL move via `host.get_spatial_index().interpret_relative_move` |
| `minerva_pcb_rotate_component` | |
| `minerva_pcb_delete_component` | |
| `minerva_pcb_connect_net` | model `connect_pin_to_net` (auto-creates net). MOVES: a pin belongs to at most one net, so any other membership is removed in the same call and named in the reply's `moved`; one undo step (see Pin→net membership below) |
| `minerva_pcb_disconnect_net` | removal half of the pair; `net_name` is an optional GUARD (`pin_not_on_net` refuses the whole call), one undo step |
| `minerva_pcb_free_pins` | one component's pins on NO net, as pad rows; `side` filters to one side/column of the part, `exclude_roles` drops what the board's own pin table flags (see The pad row below) |
| `minerva_pcb_move_net` | move one pin's net onto another pin, ONE undo step; a displaced destination membership is named under `displaced` |
| `minerva_pcb_swap_nets` | exchange two pins' nets, ONE undo step; a netless pin is a legal side, two netless pins are not |
| `minerva_pcb_select` | SET the whole canvas selection, pads included (`"Component.Pin"`); the multi mirror of `minerva_pcb_get_selection`, where `minerva_pcb_point` is the single-entity form |
| `minerva_pcb_spatial_query` | spatial index `get_components_near` + `describe_relative_position`; empty ref → `get_components` shape |
| `minerva_pcb_describe_region` | read-only; ONE read of a board rectangle — components with pad rows, traces with `free_ends`, vias with `layers_touched`, pours with outlines + `fill_region_count`, keepouts, cutouts, anchored notes. Assembled in `model/pcb_region_describe.gd` out of the surfaces that already own each rule (below) |
| `minerva_pcb_describe_component` | golden-parity; spatial `describe_component_context` |
| `minerva_pcb_get_change_journal` | model change journal |
| `minerva_pcb_import_csv` | model `from_csv` |
| `minerva_pcb_export_csv` | model `to_csv` |
| `minerva_pcb_import_footprint_geometry` | mutates existing components' pad geometry + optional position correction |
| `minerva_pcb_import_trace_geometry` | segment→polyline merge; `data.new_trace()` factory; preserves supplied ids |
| `minerva_pcb_export_trace_geometry` | round-trips with the import shape; stamps `trace_id` / via `id` |
| `minerva_pcb_delete_traces` | removes named traces/vias without clearing the board |
| `minerva_pcb_add_trace` | `data.create_trace_entity`, or `data.extend_trace` when `start`/`end` names a free trace end (below); one journalled step |
| `minerva_pcb_cut_trace` | `data.cut_trace` at an interior vertex, by `at_index` or by `x_mm`/`y_mm` (below); one journalled step |
| `minerva_pcb_undo` / `minerva_pcb_redo` | `PCBPanel.board_undo` / `board_redo` (one step of `PCBData` history; the keys and ribbon buttons take the same path — see Board history below) |
| `minerva_pcb_get_image` | snapshot-style via `host.render_content_to_image`; null-safe headless |
| `minerva_pcb_apply_route_hints` | route the open route hints → RouteCandidates in the routing workspace (default) or committed traces (`commit=true`); see the route-correction loop below |
| `minerva_pcb_list_zones` | read-only; summary per zone (`zone_id`, `kind`, `net`, `layer`, `point_count`) |
| `minerva_pcb_describe_zone` | read-only; full zone incl. outline points (`zone_outline_points` → `zone_outline_to_list` round trip) |
| `minerva_pcb_delete_zone` | `data.remove_zone`; one journalled step, mirrors `delete_component`'s idiom |
| `minerva_pcb_set_zone_net` | `data.set_zone_net`; current-value guard before calling the model (below) |
| `minerva_pcb_set_zone_layer` | `data.set_zone_layer`; current-value guard before calling the model (below) |
| `minerva_pcb_create_zone` | `data.create_zone`; one journalled step, refused verbatim via `zone_author_error` (below) |
| `minerva_pcb_set_zone_outline` | `data.set_zone_outline`; caller-owned journal (mirrors the canvas' vertex-drag commit), value-wise no-change guard (below) |
| `minerva_pcb_list_cutouts` | read-only; summary per cutout (`cutout_id`, `point_count`) (below) |
| `minerva_pcb_describe_cutout` | read-only; full cutout incl. outline points (`zone_outline_points` → `zone_outline_to_list` round trip, reused) (below) |
| `minerva_pcb_create_cutout` | `data.create_cutout`; one journalled step, refused verbatim via `cutout_author_error` (below) |
| `minerva_pcb_delete_cutout` | `data.remove_cutout`; one journalled step, mirrors `delete_zone`'s idiom (below) |
| `minerva_pcb_add_silk_text` | `PcbBoardGraphic.build_text` + `data.add_board_graphic`; one journalled step; B.SilkS mirrors (below) |
| `minerva_pcb_add_graphic` | `PcbBoardGraphic.build_geometry` + `data.add_board_graphic`; one journalled step for the whole call (below) |
| `minerva_pcb_delete_graphic` | `data.remove_board_graphic`; one journalled step, mirrors `delete_zone`'s idiom (below) |
| `minerva_pcb_propose_zone` | THE STAGING FAMILY (Epoch UX4, DCR `019fe07523ca`) — arg-identical twin of `create_zone` that lands a review GHOST via `build_zone_payload` + `panel.stage_built_payload` (author "ai"); nothing on the board until accept. NOT the router's `workspace_propose_*` family |
| `minerva_pcb_propose_cutout` | staging twin of `create_cutout`, same contract as `propose_zone` |
| `minerva_pcb_staged_list` | live staged drafts (+ `include_terminal` audit trail); rows carry canonical `entity_id` + store `staged_id` + kind/disposition/author/note |
| `minerva_pcb_staged_accept` | `panel.accept_staged` — replays the direct add with the STORED payload (id preserved, re-validated against the CURRENT board; drift refuses with the author's own words); `entity_ids` = all-or-nothing batch, ONE undo step |
| `minerva_pcb_staged_reject` | `panel.reject_staged` — terminal, history-paired (undo revives the ghost; unrelated undos leave it standing) |
| `minerva_pcb_group_components` | `data.group_components`; one journalled step, merge-no-op vs. too-few-components disambiguated at the tool layer (below) |
| `minerva_pcb_ungroup` | `data.ungroup_components`; accepts `group_id` or `component_ids` (below) |
| `minerva_pcb_set_group_member_offset` | `data.set_member_offset`; every refusal (unknown/ungrouped/anchor/locked) diagnosed at the tool layer, current-value guard (below) |
| `minerva_pcb_set_trace_width` | `data.set_trace_width`; one journalled step, current-value guard, out-of-range **refused** (below) |
| `minerva_pcb_list_vias` | read-only; one entry per board via (`via_id`, `x_mm`, `y_mm`, `net_name`, `from_layer`, `to_layer`, `size_mm`, `drill_mm`, `layers_spanned`, `layers_touched`) — the row is built by `pcb_region_describe.via_entry`, shared with `describe_region` (below) |
| `minerva_pcb_delete_via` | `data.remove_via_by_id`; one journalled step, unknown/empty id **refused** (below) |
| `minerva_pcb_board_rules` | the Options menu's verb twin: read/write the board's trace-angle set, its four numeric design rules and its grid pitch, plus the three per-user snap toggles. `view_state` shape — always reports the whole block; validated whole, applied whole; one undo step (below) |
| `minerva_pcb_set_refdes` | read/move WHERE a component prints its designator; the move is AUTHORED board state and reaches the fab; footprint-local anchor, board-frame stroke box in the reply; validated whole, applied whole; one undo step (below) |
| `minerva_pcb_view_state` | read/set WHAT the canvas is drawing — layer flags, hidden layers, trace-layer filter, working layer; validated whole, applied whole (below) |
| `minerva_pcb_get_preference` | read-only; plugin-scoped preference store (below) |
| `minerva_pcb_set_preference` | validated + clamped write, pushed live into the panel (below) |
| `minerva_pcb_get_layout_state` | read-only; `PCBPanel.get_layout_state()` plus a `plugin_build` deploy-vintage stamp (below) |

Mutations go through the model API, so the change journal, undo history and the
`data_changed` dirty relay come for free.

Trace width is READABLE without a new tool: `minerva_pcb_export_trace_geometry`
already stamps `width` on every emitted segment alongside its `trace_id`, so
"how wide is this trace" was answerable before A7 and no describe-style tool was
added for it.

## Trace width + preferences (`minerva_pcb_set_trace_width`, `get_preference`, `set_preference`, A7)

`minerva_pcb_set_trace_width` rides the same journalled model path the human's
width row uses (`pcb_data.set_trace_width`), with the same current-value guard
the zone setters carry — a re-set of the width a trace already has replies
`{success:true, changed:false}` and touches neither the journal nor the undo
history, while a real change is exactly one `save_to_history` step and repaints
the canvas live off `data_changed`. The reply reports the width **read back off
the trace**, not the requested number. Unknown `trace_id` is an error, never a
silent no-op. A trace's clickable area follows its width (`is_point_near` widens
its hit radius by half the width, live off the trace) — a re-widened trace is
immediately easier to click, by design.

**Widths are refused out of range, preferences are clamped.** The two tools
differ deliberately: `set_trace_width` writes COPPER, so a width outside
0.1–5.0 mm (or non-positive, or non-finite) comes back as the model's own
refusal rather than being quietly rounded into something the caller did not ask
for. `set_preference` writes a STARTING POINT for a range-bounded control, so an
out-of-range value is clamped into the range that control can express and the
reply says so (`clamped:true`) with the stored post-clamp `value`.

The preference store (`pcb/ui/model/pcb_prefs.gd`) is **plugin-scoped, not a
Minerva core preference**: it persists to `user://plugins/data/pcb/preferences.json`
(the install-time plugin data directory Minerva's `PluginManager` creates) as
`{"version":1,"values":{…}}`, survives app restart, and is shared by every open
PCB tab. It has a **known-key registry** — an unrecognised key is refused by
both tools, with the known keys named in the error, never silently adopted. A
missing file is the normal first-run state; a corrupt or unreadable one degrades
to defaults and reports a `warning` rather than failing.

Known keys:

| Key | Type | Range | Meaning |
|---|---|---|---|
| `trace_width_mm` | number | 0.1–5.0 | Width new traces start at when the board declares no design rule |
| `snap_grid` | true/false | — | Pull an authoring click onto the drawing grid (Ctrl/Cmd bypasses it per click) |
| `snap_land` | true/false | — | Let a click near a pad, via or free trace end FINISH the run on it |
| `snap_angle` | true/false | — | Quantise a run's direction to the board's allowed angles (Shift draws one free segment) |

The three snap keys are the per-user half of the **Options menu** (below); the
board's own design rules are not preferences and are read and written with
`minerva_pcb_board_rules`. A boolean is validated and never clamped — there is
no range to clamp into — so `set_preference`'s "clamped" flag is always false
for them.

`get_preference` returns `stored` alongside `value`, because "never chosen"
and "chosen, and equal to the default" are different facts — the panel's seeding
order depends on the distinction.

**Seeding precedence for the width of a NEW trace** (owner ruling):

1. the board's own `design_rules.trace_width_mm`, when it declares one — a board
   that states its trace width outranks a habit carried from another board;
2. the stored `trace_width_mm` preference, when the board declares no rule;
3. the control's own default (0.25 mm) when neither says anything.

`set_preference` on `trace_width_mm` also pushes into the live panel
(`applied_to_panel:true`): the human's width box updates immediately and the
canvas is armed, so the next trace they draw really is that wide. A human turn
of that same box writes the preference back, so the agent's read and the human's
control are two views of one value.

## What the canvas is drawing (`minerva_pcb_view_state`)

`minerva_pcb_set_view` aims the camera; **`minerva_pcb_view_state` says what the
camera is pointed at**, so a caller can interpret its own
`minerva_pcb_get_image` instead of guessing why a layer is missing from the
picture. Call it with nothing but `editor_name` to read:

```
{flags: {show_grid, show_traces, show_silk, show_ratsnest, show_labels,
         show_courtyard, show_route_candidates, show_drc_witnesses,
         show_mask, show_fab_preview},
 layers: [{id, kicad, hidden}, ...],
 trace_layer_filter, working_layer, changed: []}
```

**Writes are absolute, not deltas.** `flags` sets any subset by name;
`hidden_layers` is **the complete set** of canonical layer ids to hide — `[]`
shows every layer, and every id but one solos that one, which is how an inner
layer is inspected on its own. Everything is validated before anything is
applied, the discipline this verb established and `minerva_pcb_board_rules`
follows: a bad flag name or a layer this board does not declare changes
*nothing* and names what was wrong.

**A view flag may only claim a view that is really on screen.** Turning
`show_mask` or `show_fab_preview` on runs the same worker refetch the View menu
runs, so the overlay a caller then captures is real rather than empty. If that
refetch comes back with nothing the flag comes **back down** — it reads `false`
here and `overlay_unavailable: {flag: reason}` carries why, the same sentence
the status bar shows the human.

`fab_preview_layer` isolates ONE emitted Gerber/drill layer while the fab
preview is up (`"all"`, or a key from the `fab_preview_layers` list this call
returns: `f_cu`, `b_cu`, `f_mask`, `f_silks`, `edge_cuts`, `pth`…) — ten layers
composited is a picture of no layer. It is the one write validated *after* it is
applied, because its vocabulary is the artifact set the flags in the same call
may have just fetched: a key the emitted set does not carry refuses with
`layer_not_emitted`, lists what was emitted, and reports in `changed` whatever
else already landed.

`trace_layer_filter` (`"all"` or a declared copper layer id) is applied **last**,
so an explicit value wins. The two compose **asymmetrically**: a specific filter
beats every per-layer eye, so applying `hidden_layers` resets the filter to
`"all"` (reported in `changed`) — without that, soloing a layer would change the
eyes and nothing on screen.

`working_layer` is **not a view control at all**: it is the copper the canvas
*authors* on — the layer the toolbar chooser names and the trace, zone and bus
tools draw on. It is read back on every call and written with a declared copper
layer id (never `"all"`). It composes with nothing above it: setting it changes
nothing on screen, and no view write moves it. The direct authoring verbs
(`add_trace`, `create_zone`, `route_bus_direct`) keep their own explicit layer
arguments and ignore it.

## The Options menu and its verb (`minerva_pcb_board_rules`, DCR `01a0479d23b1`)

The PCB panel's control strip carries a second menu beside **View**:
**Options**. View says what the canvas is *drawing*; Options says what the board
is *drawn under*. `minerva_pcb_board_rules` is its verb twin, and both call the
same two functions in `pcb/ui/pcb_options_menu.gd` — `read_state(data, prefs)`
and `apply(data, prefs, changes)` — so a human's click and an agent's call are
one operation rather than two implementations that agree today.

**Two kinds of setting live in the menu, and the split is the design.**

| In the menu | Kind | Where it persists |
|---|---|---|
| Trace angles (Manhattan / Octilinear / Free) | **board** | `design_rules.allowed_trace_angles_deg` |
| Trace width, via diameter, via drill, clearance | **board** | `design_rules.*` |
| Grid pitch | **board** | `grid_mm` |
| Snap to grid / to pads / to allowed angles | **per-user** | the plugin preference store |

How eagerly a cursor is pulled is a habit of the person drawing; **what** it is
pulled onto belongs to the board and travels with the YAML. The three snap keys
are readable and writable through `minerva_pcb_get_preference` /
`minerva_pcb_set_preference` as well — they are ordinary registry keys, and the
`value` argument accepts a boolean for them.

### Trace angles are a BOARD RULE, not a view flag

Choosing a mode writes `design_rules.allowed_trace_angles_deg`. Two things then
follow from ONE source of truth:

1. the canvas Trace tool **quantises the run's direction** to the allowed set
   while a human draws — preview and committed copper alike, because both go
   through `pcb_canvas._trace_candidate_point`;
2. the worker's `gc12_trace_direction` check **enforces the same set on every
   trace**, agent-routed and imported copper included, and reports itself *not
   evaluated* on a board that declares nothing.

The definition both sides fold by is stated once, in
`pcb/ui/model/pcb_trace_angles.gd` and mirrored in `drc_geometric`'s gc12
docstring and `docs/board-yaml.md`: **a direction from +X toward +Y in the
board's own y-down millimetre frame, folded into `[0, 180)`** because a
direction and its reverse are one constraint. On screen the angle sweeps
clockwise, so `45` is the down-and-right diagonal. Conformance is a
**perpendicular distance** (1 um), not an angle, at both ends — an angular
tolerance is scale-dependent, and the panel and the worker cannot be allowed to
disagree about a marginal segment.

`trace_angle_mode` is the named shorthand for a set; `allowed_trace_angles_deg`
spells one out. **Passing both is refused**, never resolved: a mode IS an angle
set, and a caller that sent conflicting ones asked two different things. A board
declaring some other set reads back as mode `"custom"` and is never coerced to
the nearest named one — reporting a rule the board does not carry is how a menu
and a board silently diverge. **Free removes the key** rather than storing `[]`,
because the compiler refuses an empty list (see `docs/board-yaml.md`) and an
absent key is how "no constraint" is spelled everywhere else.

**`allowed_trace_angles_deg: []` therefore means two different things at the two
ends, and both are correct.** In a board YAML it is `bad_trace_angles` — a
refusal, because a board that asks for a direction constraint and silently gets
none fails open invisibly (`docs/board-yaml.md`). Passed to this verb it is
accepted and read as **Free**: the write path folds it and then *erases* the
key (`PCBData.set_design_rule_trace_angles`), so what reaches the YAML is the
absent key the compiler wants, never the empty list it refuses.

**A new board is created Octilinear** (`PCBPanel._DEFAULT_BOARD`) — the loosest
set that still keeps a hand-drawn run on a direction a fab and a reviewer can
read at a glance.

### Snap priority while drawing

Highest first, from the owner's note that "the snaps get in the way" near small
lands:

1. **Angle** — the direction is quantised first, so a run leaving a land can
   only travel somewhere the board allows. **Shift draws one free-angle
   segment** without touching the board rule (Ctrl/Cmd remains the separate
   "ignore the grid" modifier).
2. **Land** — a click near a pad, via or free trace end finishes the run on it.
   `snap_land` turns that off for the **finish** only: starting a run always
   uses the land under the cursor, because that is where the run's net comes
   from.
3. **Grid, last and ALONG the run.** Quantising x and y independently would push
   the endpoint off the direction step 1 chose, so the *distance* along the
   direction is what the grid quantises — a step of `pitch / max(|ux|, |uy|)`,
   which is the plain pitch for 0 and 90 and `pitch * sqrt(2)` for the
   diagonals, so both axes still move by whole pitches at once. `pitch` here is
   the AUTHORING pitch — a quarter of the board's `grid_mm`, so 0.635 mm on the
   2.54 mm default — not `grid_mm` itself, which is the pitch components sit on.
   The distance is measured **from the run's anchor**, so a run started on an off-grid pad
   centre keeps its waypoints on that anchor's grid rather than the board's —
   unlike zone, cutout and via grid snap, which quantise the point itself.

### Reply shape

A read (nothing but `editor_name`) and a write return the same block:

```
{trace_angle_mode, allowed_trace_angles_deg, offered_modes,
 design_rules: {trace_width_mm, clearance_mm, via_diameter_mm, via_drill_mm, grid_mm},
 snaps: {snap_grid, snap_land, snap_angle},
 changed: []}
```

A design rule reading **0.0 means the board declares none** — a different fact
from an authored 0.25, and the same "0.0 is not an answer" reading
`design_rule_trace_width` already uses. Writes are **validated whole, then
applied whole**, the discipline `view_state` established: an unknown mode, a
malformed angle list or an out-of-range millimetre value changes *nothing* and
names what was wrong. `changed` lists only the rules that really moved, and the
board half of a write is **exactly one undo step** however many rules moved.

## The designator anchor (`minerva_pcb_set_refdes`)

A reference designator ("R1", "U3") is in **no** IR: it is synthesized from the
component's ref at emission time, and *where* it goes is a separate question
with **one precedence rule**, in `worker/pcb_worker/refdes_anchor.py`:

1. the **board's own** `refdes_placement` for that component — what
   `minerva_pcb_set_refdes` writes;
2. else the footprint's own authored reference `fp_text`;
3. else the anchor **derived** from the footprint body (centred one clearance
   above the courtyard).

`minerva_pcb_set_refdes` reads the answer in force and authors rule 1.

Call it with nothing but `editor_name` and `component_id` to read:

```
{component_id, ref,
 anchor: {x_mm, y_mm, rotation_deg, size_mm, hidden},
 bounds: {min_x_mm, min_y_mm, max_x_mm, max_y_mm, width_mm, height_mm},
 changed: []}
```

**The anchor is footprint-LOCAL and it is the text baseline.** Millimetres in
the part's own y-down frame, centred horizontally, with the glyphs growing
*upward* — which is why a `y_mm` of `-2.8` puts the label above the part and why
the text's own height does not appear in the derivation. Because it is local, it
rotates and mirrors with the component for free: a part flipped to the back
keeps its label in the same place relative to its own body.

**`bounds` is the same fact in the BOARD frame** — the box the designator
strokes actually occupy once placed. It is measured off the strokes the canvas
draws, through `PcbComponent.get_transform()`, so a caller that just moved a
label sees where it landed without redoing the placement transform itself. It is
empty when the designator draws nothing (hidden, or a component with no ref).

### The DRC row is what produces these arguments

`minerva_pcb_drc_geometric` reports two placement advisories beside the two
silkscreen DFM rules it already carried:

| Row | What it says |
|---|---|
| `gc9_silk_under_part` | legend printed inside a foreign component's keep-out envelope, or a designator inside its own part's body/pad extent — ink that disappears when the part is soldered |
| `gc9_silk_over_silk` | a designator crossing another part's designator or outline, or board-level silk text — two strokes printed as one blot |

Both are **advisory**: silk is cosmetic by this stack's ratified
output-criticality rule, so they are reported and counted and never move
`verdict`. A footprint's own body outline sitting inside its own courtyard is
*never* a finding — that is the footprint convention, not a defect.

Every designator row carries a `suggestion` **in exactly this verb's argument
shape**: the first compass slot around the part — N, S, E, W, then the diagonals
— at the footprint's own derived offset that clears both rules *and* the
existing silk-to-pad clearance. Pass it straight back to `set_refdes`. When no
slot clears, the suggestion is `hidden: true` and the row says so, because a
designator printed where nobody can read it is worse than one not printed.

### Writes

Validated whole, then applied whole, the discipline `view_state` established: a
misspelled key, a non-finite number, a `size_mm` outside 0.2–10 mm (cap height,
**never clamped**) or a footprint-local offset past ±500 mm changes *nothing*
and is refused by name. `changed` lists only the fields that really moved, and a
write that lands is **exactly one undo step**. `hidden: true` prints no
designator at all, matching the emitter's rule for a footprint whose reference is
authored hidden.

### Scope — what you set is what the fab prints

A write becomes **authored board state**, not a panel decoration. It lands on the
component as `refdes_placement` (documented in `board-yaml.md`), so it is written
by every disk path — the `.pcbskel` save, `export_yaml`, `promote` — survives the
Go codec as an ordinary component field, and rides the wire to the worker, which
resolves it into `ResolvedComponent.refdes` **once** at compile. The Gerber
F.SilkS designator, the DRC silk projection, the GC9 placement advisories and the
`.kicad_pcb` reference all read that one field, so all four move together.

Two things stay derived on purpose. `refdes_anchor` — the *effective* placement —
is still a `DerivedComponentKeys` entry the deserialize boundary drops and
re-derives, because it encodes this host's library. And a placement nobody set is
still absent: the derived answer is never written back as authored, so an unset
component keeps following the footprint.

## The region read (`minerva_pcb_describe_region`)

Understanding the ground around one part otherwise costs five verbs and a hand
cross-reference: `list_zones` + `describe_zone` per zone + `get_components` (the
whole board) + `spatial_query` + `pin_info`. `spatial_query` already sweeps a
rectangle, but its copper block reports **ID lists** — no pad nets, no zone
outlines, no trace free ends — so the answers still have to be reassembled from
other verbs, and the reassembly is where a reader gets it wrong.

`describe_region` is that rectangle answered once. It lives in
`ui/model/pcb_region_describe.gd`; `panel_tools.gd` gets **dispatch wiring
only** (arg validation and the envelope), because that file is already a god
file.

**Nothing in it is a new rule.** Every answer is the answer an existing surface
already gives:

| the reply says | the rule comes from |
| --- | --- |
| what is in the rectangle | `data.get_components_in_region` / `get_traces_in_region` / `get_vias_in_region` / `get_zones_in_region` / `cutouts_in_region` — the same sweeps the human's marquee walks and `spatial_query`'s copper block reads |
| a pad | `PcbPadRow.rows_for_component` — THE pad row, the shape `get_selection`, `pin_info`, `free_pins` and the move/rotate replies all emit |
| `free_ends` | `pcb_data.trace_end_is_joined`, negated — the same predicate the canvas Trace tool refuses to draw from and the connectivity DRC credits (pads by the shared contact predicate, vias by coincidence, same-net traces and same-net POUR FILL) |
| a pour's outline / whether it conducts | `zone_outline_points` → `zone_outline_to_list`, and `PcbZoneCopper.fill_regions` for `fill_region_count` |
| `layers_touched` | `PcbCopperContact.nodes_touch`, per layer (below) |
| a note's anchor point | `pcb_region_describe.anchor_point`, which `PcbRouteHintKind._anchor_position` now delegates to — one reader of the v2 anchor wire shape |

So a region read cannot disagree with the verb it summarises.

**A trace crossing the boundary is listed WHOLE**, with all of its points. A
clipped polyline would describe copper that does not exist, and where a run goes
is most of why the region was asked about.

**Pours and keepouts are reported apart.** They are one entity type in the model
and two different things to a reader: a pour is copper an agent may land on, a
keepout is copper it may not create. `fill_region_count: 0` on a pour means it
conducts **nothing** yet — the difference between "there is ground here" and
"there is a request for ground here".

**An empty region is an answer, not an error**: empty arrays, plus the
`searched` list, which is what tells a reader an array is empty because nothing
is there rather than because nothing was looked for. (Same reason
`spatial_query`'s copper block carries one.)

**View state is ignored**, exactly as `spatial_query`'s copper block ignores it:
the human's marquee honours layer visibility because a person selects what they
can see, while an agent asking what is in a rectangle is asking about the
BOARD. An answer that changed with someone else's View menu would be
unreproducible from the agent's side. The reply says so.

**`layer` filters copper, never components.** Traces, vias (by the layers their
barrel spans), zones, keepouts and pads are filtered; a through-hole pad is on
every layer and so passes any filter. A component is a physical part with a
mounting side, not copper on one layer — dropping it because its pads are
elsewhere would hide the thing the agent is standing next to — so its `pads`
array is filtered instead.

**Notes** are the annotations whose ANCHOR POINT lies inside the rectangle. The
point, not the rendered bounds: a marker's bounds are a view concept that
changes with zoom, while the point it was dropped on is board geometry.

### `layers_touched` (also on `minerva_pcb_list_vias`)

`from_layer`/`to_layer` say what a via's barrel **spans**. Every through via
spans the whole stack — `PcbLayerStack.is_legal_via_span` admits nothing else —
so the span cannot show a via that joins nothing on one side. That was
invisible over MCP: an agent could see a via existed and could not see whether
either end reached copper.

`layers_touched` walks the span one layer at a time and asks the **shared
contact predicate** (`PcbCopperContact.nodes_touch`) whether the barrel's disc
*on that layer* meets any pad land, any trace's swept copper, or any pour's
compiled fill there — the same three conductor kinds the connectivity DRC and
the ratsnest read, through the same builders. `layers_spanned` is reported
beside it so the two claims are never confused.

It is **net-blind, and it judges nothing.** A via whose bottom side meets
nothing is reported as touching only its top; a via meeting a foreign net's
copper is reported as touching that layer. "This via is stranded" and "this via
is a short" are DRC's verdicts to give, and a read verb that folded a verdict
into a fact would take that judgement away from the reader who asked for the
fact.

The board's copper is indexed **once per call**
(`pcb_region_describe.build_copper_index`), not once per via: rebuilding it in
the innermost loop is what turns a whole-board `list_vias` into a slow read.
Vias are deliberately absent from the index — a via meeting only another via
says nothing about whether either reaches a conductor.

`PcbCopperContact.via_span` is the one derivation of "which layers does this
barrel occupy"; `pcb_ratsnest._via_span` delegates to it, so the ratsnest's
same-net sweep and this read cannot describe different barrels.

## Board-via tools (`minerva_pcb_list_vias` / `delete_via`, B1-U2)

MCP parity for the via surface the canvas gained in the same unit (a via is now
a first-class selectable entity: click, marquee, Delete/trash, eraser). Both
tools ride the same journalled model path the canvas does — `data.vias` for the
read, `pcb_data.remove_via_by_id` for the delete — so an agent's delete and a
human's Delete key are indistinguishable to the board and share one undo
history.

**`minerva_pcb_add_via` is NOT the counterpart of these.** It edits any
`pcb_route_hint` annotation carrying per-segment geometry (`kind_payload.
segments`) — splitting a segment and inserting a via, via
`PcbRouteHintKind.apply_via_at_point` — not the board. Since S5 (C4b, DCR
`019f7095c395`) retired proposal annotations, its live target today is a
pre-cutover proposal a `.pcbskel` may still carry until migration drops it, or
any future annotation shape that stamps `segments` itself; it was never
gated on proposal-hood specifically. Nothing it adds appears in `list_vias`.
Board vias are created only by committing routes — `apply_route_hints` with
`commit`, `minerva_pcb_workspace_commit`, or `import_trace_geometry`. The
honest board-via surface is: **create** by
committing routes, **read** by `list_vias` (or `export_trace_geometry`'s
`vias[]`), **delete** by `delete_via` (one) or `delete_traces`' `via_ids`
(several, one undo step). There is deliberately no `move_via`: moving a via
detaches it from the trace ends that meet it, which is routing-tool work, and
the canvas refuses the drag for the same reason.

**Why `list_vias` exists alongside `export_trace_geometry`'s `vias[]`:** that
payload is fabrication geometry — it walks every trace segment on the board and
**aborts the whole export** when any trace sits on a layer it cannot name, so an
unrelated bad layer makes the via list unreadable. `list_vias` reads `data.vias`
directly and answers only "which vias exist and where". Both read the same board
state, so they cannot disagree.

**`via_id` is absent, not blank, on a legacy via.** A via restored from a board
file predating stable via ids carries no `id` key. The key is omitted rather
than emitted as `""`, because "this via has no identity" is a different claim
from "its identity is the empty string" — the same distinction
`export_trace_geometry` already makes. Such a via cannot be deleted by id, and
cannot be selected on the canvas either (`pcb_data.get_via_at` skips it): a
selection stores bare id strings, so picking it would put `""` in the selection
and produce a via that highlights and cannot be deleted.

**Unknown `via_id` is always an error**, empty included — never a silent no-op.
The empty case is routed through `pcb_data.find_via_index` rather than
short-circuited in the tool, for the reason `delete_traces` spells out: `""`
would otherwise match the first via carrying no `id` key and delete copper the
caller never named, and the guard that prevents it has to be the one being
executed.

## Zone tools (`minerva_pcb_list_zones` / `describe_zone` / `delete_zone` / `set_zone_net` / `set_zone_layer`, A6)

MCP parity for the zone surface the canvas already had (round A5 select/edit,
the delete slice): all five ride the same journalled model path as the canvas
— `pcb_data.remove_zone` / `set_zone_net` / `set_zone_layer` — so an agent
mutation and a human canvas edit are indistinguishable to the model, and the
canvas repaints live off the same `data_changed` signal those model calls
already emit (`pcb_canvas.set_data` wires it to `queue_redraw`; no new canvas
code was needed).

**Unknown `zone_id` is always an error**, on every one of the five tools —
never a silent no-op.

**The two setters return `""` from the model for BOTH a real write and "no
change needed"**, so the tool layer copies the same current-value guard
`PCBPanel.gd`'s zone property panel already uses (`_on_zone_prop_net_selected`
/ `_on_zone_prop_layer_selected`): compare the zone's stored value to the
requested one *before* calling the model. A match replies
`{success:true, changed:false}` without touching the model or the undo
history; a real change calls the setter and, on success, takes exactly one
`save_to_history` step. `set_zone_layer`'s guard keeps the model's own
asymmetry — an **empty** requested layer never counts as a match (there is no
legitimate "current" empty layer), so it always reaches the model and comes
back as that setter's refusal.

Every refusal the model can return — a keepout's net (`set_zone_net`), an
undeclared net or layer, an empty layer stack, an unknown zone — surfaces as
`_err(<the model's own string>)`, verbatim.

## Zone geometry parity (`minerva_pcb_create_zone` / `set_zone_outline`, B2)

Rounds out the A6 zone surface (list/describe/delete/set_net/set_layer, above)
with authoring and geometry editing, so the whole zone lifecycle is
agent-reachable the way the canvas' A5 drawing tool and vertex-drag already
are. Both ride the model path only — `data.create_zone` / `data.set_zone_outline`
— never a board-YAML serialize/reload round trip, which would take a
different, untested path from every human gesture and could drift from it
silently.

`create_zone` mints a persistent zone id and journals ONE undoable step
(`data.create_zone` already `record_change`s + `data_changed`s internally, the
same idiom `add_component` uses). Its refusal text is produced by calling
`data.zone_author_error` explicitly, ahead of `create_zone` — `create_zone`
itself only `push_warning()`s its reason to the console and returns `{}`
either way, so the tool asks the model's own rule for the real, verbatim
string (too few points, an undeclared net, a missing/undeclared layer) rather
than inventing one.

`set_zone_outline` is the MCP counterpart of the canvas' vertex-drag commit
(`pcb_canvas._end_zone_vertex_drag`). It journals the SAME
`"edit_zone_outline"` shape that gesture already writes (`zone_id`, `op`,
`vertex_index`, `old_point_count`, `point_count`), with `op: "set_outline"`
and `vertex_index: -1` marking a whole-outline replace rather than a
single-vertex edit. `data.set_zone_outline` is itself a LIVE-DRAG WRITER
(silent about a real write, vocal about a refusal), so the tool owns the
journal entry and the closing `save_to_history` the same way the canvas'
drag-end commit does; the canvas repaints live off the same `data_changed`
signal that commit already emits (`pcb_canvas.set_data` wires it to
`queue_redraw` — no new canvas code). The no-change guard compares the point
lists VALUE-WISE (`Vector2 == Vector2`), not the raw `{x_mm,y_mm}` dicts
`set_zone_outline` stores them as, so a resubmit of the same outline is
`changed:false` regardless of dict key order or float formatting.

## Cutout tools (`minerva_pcb_list_cutouts` / `describe_cutout` / `create_cutout` / `delete_cutout`, campaign 2 epoch B unit 3)

MCP parity for the cutout surface this round adds to the canvas (a click-per-
point draw tool, plus delete via the eraser/trash/context menu). All four ride
the same journalled model path the canvas gesture uses — `pcb_data.create_cutout`
/ `remove_cutout` — so an agent mutation and a human canvas edit are
indistinguishable to the model, and the canvas repaints live off the same
`data_changed` signal those model calls already emit.

A cutout is the SIMPLEST entity in the contract: no net, no layer, no kind — it
is an opening through the whole board, so "which layer" is the one question it
cannot be asked (see `pcb/internal/board/board.go`'s `Cutout` doc). That is why
this is a four-tool subset of the zone surface's seven, not a parallel seven:
there is no `set_net`/`set_layer` to author (nothing to set), and no
`set_zone_outline` counterpart either — v1 ships DRAW + DELETE only, no vertex
editing (see `pcb_canvas.gd`'s Cutout Authoring region for why).

**Unknown `cutout_id` is always an error**, on every one of the four tools —
never a silent no-op, matching the zone tools' own contract.

`create_cutout` mints a persistent cutout id and journals ONE undoable step
(`data.create_cutout` already `record_change`s + `data_changed`s internally,
the same idiom `create_zone` uses). Its refusal text is produced by calling
`data.cutout_author_error` explicitly, ahead of `create_cutout` — the model's
own function only `push_warning()`s its reason and returns `{}` either way, so
the tool asks for the real, verbatim string (the ONE rule a cutout has: an
outline under 3 points) rather than inventing one.

**A cutout COMPILES and FABRICATES** (epoch CPN1, docket `019fe2faf76e`) —
this paragraph used to say the opposite, and the refusal it described existed
only to hold back a fail-open (`019fbd30f7`) that round fixed. An authored
cutout now compiles into `ProfileOutline.cutouts` and reaches every consumer:
both fab emitters draw it as a second closed Edge.Cuts contour, geometric DRC
measures copper-to-edge against its edges (findings name the cutout via
`against_entity_id`), routing reserves it as an all-layer obstacle
pre-inflated by `copper_to_edge_mm`, and zone fill carves pours away from it
by the same band. Compile owns the fail-closed geometry rules — strictly
interior to the rim, pairwise-disjoint bounding boxes, no self-intersection,
no zero area — all under `invalid_cutout_outline`; see `docs/board-yaml.md`'s
"Cut-outs" section for the full contract.

## Board graphics (`minerva_pcb_add_silk_text` / `add_graphic` / `delete_graphic`)

Artwork the **board** owns rather than a component. Without these verbs the only
graphic owner is a footprint, so board text has to be hung off whatever part
happens to be nearby, in absolute board coordinates that the part's own placement
corrupts the moment anyone moves it.

The full schema — every field, the layer allow-list and the mirroring convention
— is in `docs/board-yaml.md` under "Board graphics". What follows is the verb
surface.

### `minerva_pcb_add_silk_text`

`{editor_name, text, position:{x_mm,y_mm}, layer, size_mm, rotation_deg?,
h_align?, width_mm?, id?}` → `{graphic_id, layer, kind, text, size_mm,
rotation_deg, mirrored, width_mm, bounds, missing_glyphs}`.

- `size_mm` is **cap height**: a capital is exactly that tall.
- `layer` is `F.SilkS` or `B.SilkS`. **B-side text is mirrored automatically**,
  derived from the layer, so back legend reads correctly once the board is
  flipped. The mirror is about the text's own anchor — text asked for at
  (10, 10) sits at (10, 10) on either side; it reads the other way, it does not
  move. The reply's `mirrored` says so, so a caller never has to infer it.
- The board stores **what the text says**, not its strokes. Fixing a typo is an
  edit to one string rather than a regeneration of a hundred polylines.
- Characters with no glyph render as a **box** and are listed in
  `missing_glyphs`, with a `note` naming them. Never silently dropped.

### `minerva_pcb_add_graphic`

`{editor_name, layer, width_mm?, id?}` plus **exactly one** of `polylines`,
`points` (+`closed`), `rect:{start,end}`, `circle:{center,radius_mm}` →
`{graphic_id, layer, kind, width_mm, bounds}`, or `{graphics:[…],
graphic_count}` when several polylines were supplied.

Supplying zero or several geometry keys is refused by name rather than resolved
by precedence: silently preferring one is how a caller ends up drawing something
it did not ask for. Every payload is built **before** any is written, so a
malformed third chain refuses the whole call instead of leaving one and a half
graphics for the next undo to half-restore. `layer` is silk or courtyard only —
copper would be unconnected metal with no net, and the board rim already has an
owner.

### `minerva_pcb_delete_graphic`

`{editor_name, graphic_id}` → what was deleted. A text graphic is **one object**
however many strokes it draws, so one call removes the whole legend and one undo
restores it. An unknown id is an explicit error, never a silent no-op.

### GUI parity

Every one of these has a human affordance, so a GUI-only user is never sent to
an MCP verb: board graphics are pickable on the canvas (last rung of the pick
ladder — silk is printed ink drawn over everything, so it must not make what it
covers unclickable), highlight in the selection colour, sweep into a marquee by
bounds, and delete through the Delete key, the eraser, or right-click →
"Delete text" / "Delete graphic". What v1 does **not** have is an in-panel text
tool or a drag handle: artwork is authored at a stated position and is not
movable after the fact, which is why `_capture_drag_origins` deliberately does
not capture it.

### One typeface per board

Every string this project draws on a board — legend text AND reference
designators — comes from `worker/pcb_worker/board_font.py` (authored in-house,
95 printable ASCII glyphs plus an unknown-glyph box, mirrored into
`ui/model/pcb_board_font_data.gd` for the panel). There is no second font.

Designators used to have their own 26-glyph table extracted from KiCad's
Newstroke, whose source file carries a **GPL-2.0-or-later** header, in a
repository that ships under a proprietary licence (`LICENSE.md`). That table is
deleted. What let it sit unnoticed was the INVENTORY, not the copy:
`scripts/gen_notice.py` walks `library/footprints.lock.json`, which inventories
acquired FILES, and a table of literal constants inside a `.py` is not a file.
`gen_notice.py` now carries an explicit allowlist of source-embedded
third-party data tables and renders a NOTICE section for it — empty today, and
`worker/tests/test_notice.py` fails if a source file grows one without being
declared there.

## Group tools (`minerva_pcb_group_components` / `ungroup` / `set_group_member_offset`, B2)

MCP counterparts of the canvas' Ctrl+G / Ctrl+Shift+G gestures
(`pcb_canvas._group_selection` / `_ungroup_selection`) and `PCBPanel`'s offset
LineEdits (`_commit_member_offset`). All three ride `pcb_data`'s group model
(A4 / A4 stage-2) directly — `group_components` / `ungroup_components` /
`set_member_offset` — so an agent's grouping and a human's are the same
operation to the board, and `minerva_pcb_get_components`' `group_id` /
`group_members` / `group_anchor` / `group_offset` fields (already shipped)
describe exactly what these three mutate.

**No lock concept on group/ungroup.** `is_group_locked` gates the operations
that move geometry (translate/rotate/remove/`set_member_offset`) — a lock
protects a physical layout, not the grouping relationship itself.
`group_components` and `ungroup_components` carry no lock check in the model,
and none is added at the tool layer either; only `set_group_member_offset` can
refuse "locked".

`group_components` returns `""` from the model for TWO different reasons it
does not itself distinguish: fewer than two real components after expansion
to existing group-mates, or a selection that is ALREADY exactly one flat
group. The tool tells them apart itself — the first is a real `_err`, the
second is a no-op reply (`changed:false`) carrying the existing group's own id
and members, the same "nothing to do, not a refusal" shape `set_zone_net`'s
current-value guard uses.

`ungroup` accepts either `group_id` (resolved to its member list, so an
unknown `group_id` is an explicit error) or `component_ids` (any member of a
touched group pulls in the whole group) — `group_id` takes precedence when
both are given. Releasing nothing (every named component already ungrouped)
is `changed:false`, not an error.

`set_member_offset` returns a bare `bool` that conflates four different
outcomes (ungrouped, locked, anchor, already-there) into one `false`, so
`set_group_member_offset` re-derives each refusal reason itself, in the
model's own check order (`component_group_id` empty, then `is_group_locked`,
then anchor), before ever calling the model — the caller gets a specific,
stable reason (`Unknown component: …` / `Component … is not in a group.` /
`Group is locked — nothing offset.` / `The anchor has no editable offset —
moving it would move the whole group.`) instead of one bare "refused". The
no-change comparison (target position == current position) is done ahead of
the model call too, so a resubmit of the same offset is `changed:false` and
journals nothing — the same guard idiom every other setter in this file uses.

## Layout state observability (`minerva_pcb_get_layout_state`, B2)

Exposes `PCBPanel.get_layout_state()` — already built for the gd-test suite's
own responsive-layout assertions (`test_pcb_panel_layout.gd`) — as an MCP
tool, plus a `plugin_build` field the panel adds to that same dict.
Read-only: journals nothing, mutates nothing.

**`plugin_build` design choice.** A git SHA is not available at runtime for a
deployed/packaged plugin. Reading `pcb/manifest.json`'s `version` off disk was
considered and rejected: it is a `FileAccess` round trip whose correct path
depends on where this off-tree script happens to live (the dev source dir
today, but not guaranteed for every packaged layout), for a fact whose only
job is "did the human deploy the latest scripts". Instead `PCBPanel.gd`
declares `const PLUGIN_BUILD` — a hand-bumped marker string, the same pattern
`pcb_prefs.gd`'s and `pcb_routing_sidecar.gd`'s `SCHEMA_VERSION` already use
for version-shaped facts in this plugin. It is derived once, at script load
(a constant needs no runtime derivation), and is honest about what it is: a
marker the person editing these scripts bumps by hand, not an
automatically-computed build id. Left stale it under-reports rather than
lying forward. Bump it in `PCBPanel.gd` whenever a round's changes are worth
distinguishing during an HITL "which script is actually running" deploy
check.

## Deleting a subset of traces (`minerva_pcb_delete_traces`, docket `019f809798d1`)

Before this existed, the only removal path was `minerva_pcb_import_trace_geometry`,
which **clears the whole board** and re-imports. Removing one trace therefore meant
exporting everything, filtering outside the tool, and pushing the full replacement
set back through context — measured at ~7 tool calls and two large JSON payloads
for a single partial edit.

Selection is **by identity only**. `trace_ids`, `via_ids` and `net_name` are
combined as a union; at least one is required.

```
minerva_pcb_delete_traces
  editor_name  (required)
  trace_ids    [String]   exact trace ids
  via_ids      [String]   exact via ids
  net_name     String     every trace on this net (exact match)
```

`net_name` selects **traces only, never vias**. A via on that net is copper you
did not name; name it in `via_ids` if you want it gone. Deciding on your behalf
that it is orphaned is exactly the silent judgement the fail-closed ruling forbids.

### Identity in the export payload

`minerva_pcb_export_trace_geometry` stamps identity on what it emits: every
segment carries a `trace_id`, and every via carries an `id`.

**The segments of one trace all repeat the same `trace_id`.** A trace is a
polyline, so a 3-waypoint trace exports as 2 segments naming one id. That is the
relationship, not a duplicate to collapse — it is how you tell which segments are
one continuous piece of copper, and their array order is their order along the
polyline.

A via's `id` is present for any via created through the editor or through import.
It is **absent** on a via restored from a board file predating stable via ids, and
such a via cannot be addressed by `delete_traces`. An absent key means "no
identity" — a different claim from an empty string.

### Id stability across a round trip

Import honours a supplied `trace_id`/`id` instead of renumbering positionally, so
**export → filter → import round-trips identity**. Segments group by `trace_id`
first, then net and layer, so two distinct traces sharing a net and layer are no
longer merged. Id-less segments still merge by net+layer and receive fresh ids
guaranteed not to collide with any you supplied, **regardless of the order you
list them in** — the importer reserves every supplied id before minting anything.
The reply returns the `trace_ids`/`via_ids` that actually landed, so preservation
is verifiable without a second export.

An id can be claimed **once per import**, and that holds for traces and vias
alike. If one supplied id maps to several disconnected polylines — or the same
via id arrives twice — the first claimant keeps it and the rest are minted
fresh; no copper is dropped and none is overwritten. Traces and vias are
separate id spaces (`trace:<hex>` / `via:<hex>`) so a trace and a via spelled
identically never block each other.

**Ids survive a reload.** A freshly minted trace or via id is a persistent token
(`trace:<32 hex>`, `via:<32 hex>` — see board-yaml.md "Persistent identity"), so
an id you hold from before `minerva_pcb_export_yaml` is still the id after
`minerva_pcb_load_board`. Older boards carrying ordinal `trace_7` / `via_12`
handles still load and still delete by those handles, but the deserialize
migration re-mints them, so an ordinal id **does not** survive the round trip;
re-read the ids after a load if that is what you have.

### Partial success

Naming an id that no longer exists is not an error — it means your view of the
board is slightly stale, not that the request was malformed. The ids that exist
are deleted and the stale ones come back named:

```json
{ "success": true,
  "deleted_trace_ids": ["trace_2"], "deleted_trace_count": 1,
  "deleted_via_ids": [], "deleted_via_count": 0,
  "missing_trace_ids": ["trace_9"],
  "remaining_trace_count": 4, "remaining_via_count": 2 }
```

`missing_trace_ids` / `missing_via_ids` appear **only when you supplied the
matching selector**. An empty array means "we checked your ids, none were stale";
an absent key means "you named none, so there was nothing to check".
`net_match_count` follows the same rule — a `0` there is a counted zero (the net
was queried and has no traces), never a stand-in for "not computed". Note it
cannot distinguish a net that exists and is unrouted from a net name you
mistyped; both count zero.

### "committed by" is an ownership claim, and it is checked

`reopened_candidate_ids` / the `note` that names them appear only when the copper
you deleted was **really** a committed route candidate's. Ownership is keyed by
id **and** net, with the candidate's own geometry bounds as the tiebreak: a
sidecar record whose id resolves to copper on another net, or nowhere near the
candidate, is dropped rather than believed. Copper you drew by hand therefore
reports no "committed by" even when a stale record happens to name its id.

A request with no selector at all is the one hard error: deleting nothing and
deleting everything must never be the same request. An **empty** `net_name`, or
empty id arrays, does not count as supplying a selector — a call carrying only
`net_name: ""` is that same error, not a no-op.

### Undo

A delete that changed something is one undo step, exactly like an import — one
undo restores the deleted traces **and** vias. A delete that removed nothing takes
no snapshot, so it adds no step you have to click past.

### Deleting copper a committed candidate owns (bug `01a02bf97224`)

A route candidate is `committed` only for as long as its copper is on the board.
Delete a trace or via that a committed candidate owns and the commit is
**retired**: the candidate returns to its pre-commit disposition (live again,
with any DRC verdict it held staled), its `committed_trace_ids` are cleared, and
its **routing task reopens** — the workspace stops reporting that span as routed.
The reply names them in `reopened_candidate_ids`, absent when the delete touched
no committed copper. Before this, the task stayed `closed` over an empty span and
the candidate was stuck: `commit` refuses a re-commit ("undo the commit or
uncommit it") and nothing ever called `uncommit`.

**Partial loss counts as loss.** A candidate can own several traces and lose one.
The survivors do not connect the span it answered, and deciding whether they might
would be a connectivity judgement made from an id list — the same fail-closed
ruling the missing region selector below rests on. The surviving copper is left on
the board untouched; it is not this pass's to remove.

The rule is `RoutingWorkspace.reconcile_committed_copper(board)`, and it also runs
at the top of **every** workspace verb (`_workspace_ctx`), so copper removed any
other way — the canvas eraser, `delete_via`, a re-import that cleared the board —
is reconciled before any verb reports a task state. It is asked from outside,
against the board as it stands, rather than hooked into `remove_trace`: that
function is also the commit rollback's tool and `_restore_state`'s rebuild path,
where compensating would be wrong. It cannot double-apply on undo — an undo
restores the copper and the disposition layer together, and the pass then finds
nothing missing — and it is idempotent, because a retired commit is no longer
committed. Running it *before* the delete's own `save_to_history` is what puts
both halves of the act in one history entry: undo brings the copper and the
commit back together, redo removes both again.

### Known gap: no region selector, no clipping

There is deliberately **no spatial or bounding-box selector**. A region predicate
must silently decide what to do with a trace that CROSSES the boundary, and this
project's standing ruling is that routing, DRC and CAM fail closed rather than
approximate copper. To clear an area: export, filter on the real coordinates now
that every segment names its trace, then pass the ids you chose.

**Partial-trace clipping — splitting a trace at a boundary and keeping one side —
is not supported.** A trace is deleted whole or not at all. To shorten one today,
delete it and import the geometry you want in its place.

## Drawing and continuing a trace (`minerva_pcb_add_trace`)

The canvas Trace tool's verb twin, through the SAME model path
(`PCBData.trace_author_error` → `create_trace_entity`), so an agent and a
click are refused for the same reasons in the same words. `net_name`,
`layer` and `points` (`[[x_mm, y_mm], …]`, 2+) draw a new trace; `width_mm`
is optional. It runs no DRC — the copper is on the board when it returns.

### Trace-end anchors (`start` / `end`)

A trace has three kinds of anchor: a pad, a via, and a **free trace end** — an
end that touches no pad copper, no via disc, no same-net trace (within
`PCBData.TRACE_END_JOIN_EPS_MM`, 0.05 mm, of the copper itself) and no same-net
pour **fill**. The rule is net-blind for pads and vias but net-aware for traces
and pours: a pad or via of ANY net under the end makes it not free, while
different-net trace or pour copper under it does not (that is a short for DRC,
not a join). A pour joins as its COMPILED fill, never as its outline, and a pour
with no computed fill joins nothing — so an end the Trace tool just finished on
a plane is not offered straight back as a loose end to continue from. A joined
end is not an anchor, and a LOCKED trace offers none (`trace_locked` from the
verb). Continuing a trace
from one of its own ends to its other end is refused (`trace_end_same_trace`):
that would close it into a loop. The verb names one as `{trace_id, end: "start"|"end"}`:

- **`start`** — the run CONTINUES that trace: `PCBData.extend_trace` appends the
  points after its `end` (or prepends them, reversed, before its `start`), and
  the trace keeps its id, net, layer and width. `net_name` and `layer` may be
  omitted; given, they must agree (`trace_end_net_mismatch`,
  `trace_end_layer_mismatch`). `width_mm` is refused — a polyline has one width.
- **`end`** — the run finishes ON that free end and is appended to that trace,
  reversed, so the polyline stays one piece. The target must already share the
  run's net and layer (same two refusals: one polyline cannot carry two nets or
  live on two layers — end on a pad or via instead; a via is how a run changes
  layer). A run that both starts and ends on a trace end extends the START
  trace only; the two traces then touch, which is joined copper.
- Refusals, changing nothing: `no_such_trace`, `trace_end_not_free` (the end
  already touches a pad, a via or same-net copper — a pad counts when the run's
  **swept width** reaches its **land**, the same rule the connectivity DRC's
  `dangling_endpoint` credit reads), the two mismatches,
  `trace_not_extendable` (the model's words, e.g. every point sat on the end),
  and `trace_not_authorable` — which is how a NETLESS start trace is refused,
  with the model's own "must name a net … the pad, via or trace end it starts
  on" sentence.
- The reply carries `extended_from` and the whole grown polyline
  (`points`, `point_count`); one `extend_trace` journal row, one undo step.
  Copper a COMMITTED route candidate owns retires that commit inside the same
  step (`reopened_candidate_ids`), exactly as `minerva_pcb_delete_traces` does.

The canvas does the same: a click within `PCBData.TRACE_SNAP_MM` (1.27 mm) of a
free end anchors on it (pad and via win where they overlap it), the label reads
`Trace end trace:…`, a netless trace end is refused by name exactly as a
netless via is, and the trace's own layer — not the working layer — is where
the continuation lands.

## Cutting a trace at a vertex (`minerva_pcb_cut_trace`)

The verb twin of the canvas's right-click **Cut here** on a trace, through
`PCBData.cut_trace`: the trace keeps its id and its waypoints up to and
including the cut vertex; the tail is dropped in one journalled `cut_trace`
row and one undo step. Name the vertex as `at_index` (0-based) or as
`x_mm`/`y_mm`, which picks the nearest INTERIOR vertex within `TRACE_SNAP_MM`
(`no_vertex_in_reach` when none is). Cutting at an end is refused by name
(`trace_not_cuttable`: index 0 would be a delete, the last index a no-op — the
caller chooses deliberately), as is a 2-point trace (no interior). The reply's
`free_end` says whether the new end is a free end (see above) or already sits
on a pad, a via or same-net copper. A locked trace is refused (`trace_locked`);
copper a committed route candidate owns retires that commit in the same step
(`reopened_candidate_ids`). Runs no DRC.

**Redoing a bad exit** — a bus leg that landed on the wrong pad, a hand-routed
run one bend too far: select the trace → right-click at the last good bend →
**Cut here** → arm Draw ▸ Trace and click the new end — a free end unless
something already joins it (`free_end` in the verb reply) → draw the leg
again. The same three steps from an agent: `minerva_pcb_cut_trace`, then
`minerva_pcb_add_trace` with `start: {trace_id, end: "end"}`.

## Route-correction collaboration loop (`minerva_pcb_apply_route_hints`)

Closes the route-correction loop (agent-router child `019eb47eb567`, DCR
`019dc140`). Signature: `{editor_name, hint_ids?, commit?}`.

**propose → inspect → resolve → iterate**

1. **PROPOSE** (`commit` absent/false) — gather the board's OPEN `pcb_route_hint`
   annotations (or the given `hint_ids`), route them through the worker, and land
   each routed polyline as a **RouteCandidate** in the panel's routing workspace
   (`pcb_routing_workspace.gd`) — the exact landing path
   `minerva_pcb_workspace_propose` uses. This does NOT mutate the board and does
   NOT write an annotation — the user inspects candidates on the canvas (ghost
   traces) or via `minerva_pcb_workspace_list`/`get_active` first. Returns
   `{proposed, proposals:[…], holds:[…], unrouted:[…], stuck:[…]}`; each
   `proposals[]` entry is result-derived (`net`, `layer`, `waypoint_count`,
   `width_mm`, `drc_geometric?`, `source_hint_ids`, `candidate_id`) — `candidate_id`
   (aliased as `id`) is the workspace id to resolve, never an annotation id.
2. **RESOLVE** each candidate — `minerva_pcb_workspace_commit(candidate_id)`
   materializes it as real trace(s)/via(s) in ONE undoable step;
   `minerva_pcb_workspace_reject(candidate_id)` discards it and reopens its task
   for iteration. (Retired, S5/C4b: the old per-proposal
   `minerva_pcb_proposal_accept`/`minerva_pcb_proposal_reject` annotation verbs —
   there is no longer an annotation to accept or reject.)
3. **APPLY** (`commit=true`) — re-route the selected open hints and MATERIALIZE the
   results as real traces in the model directly (journalled via `save_to_history`),
   then transition the source hints `open → applied`. Returns
   `{applied, applied_hint_ids, traces_added, failed:[…], unrouted, stuck}`. Skips
   the propose step entirely — use this for a batch that needs no per-route review.
4. **ITERATE** — applied hints drop out of the default (open) gather; a workspace
   candidate is never itself gathered as a source hint (only `pcb_route_hint`
   ANNOTATIONS are), so re-running after the user edits/adds hints picks up only
   the fresh open hints.

**Failure as feedback.** Partial/failed routing returns WHERE it got stuck rather
than a bare "failed": `stuck` carries each unrouted net with its blocked pad pair
(`{net, from, to, reason}`) plus any bridge warnings — structured data the agent
can reason about (add a waypoint hint, move a part, free a corridor) and re-run.

**Worker invocation — FINDING (in-fence half only; DCR `019dc140`).** The worker
`route` method (`pcb_worker/methods.py`, dispatcher-registered; consumes a
canonical board + `pcb_route_hint` envelopes + a selection and returns
`{success, routes[{net, segments, vias}], unrouted, via_count}`) is **complete and
unchanged**. There is **no in-fence path** for the core apply tool to reach it:

- Worker compute is exposed to core only as **Go MCP tools**
  (`internal/tools/worker_tools.go`), and `route` is not among them — adding
  `minerva_pcb_route` there is out of this round's fence.
- The panel `request` broker reaches **Go channel handlers**
  (`pcb.serialize`/`deserialize`/`collect_export`/`apply_export`, declared in
  `manifest.json` `ipc_channels`), NOT the Python worker's compute methods — and
  `manifest.json` is out of fence too.

So the **in-fence half is wired end-to-end**: `MCPPcbPanelTools._apply_route_hints`
→ `PcbAnnotationHost.run_router(selection)` (async) → `PCBPanel.route_board()`,
which builds `{board: to_board_dict(), route_hints, selection}` and emits a
`pcb.route` broker `request`, awaiting the reply (mirrors the `pcb.serialize`
export path). `pcb.route` is now a declared `ipc_channels` entry forwarded to the
worker `route` method (`internal/tools` `RouteChannel`/`HandleRouteChannel`, bug
019f3815e9f9), so the route-correction loop is LIVE; `route_board` returns a
structured `worker_unavailable` (surfaced by the tool as `route_worker_unavailable`
failure-feedback) only when the IPC channel is genuinely not ready.

A worker that ANSWERS with a refusal is reported differently: its own
`{ok:false, error:{kind, message}}` envelope (`unsupported_geometry`,
`unsupported_scope`, `parse`, `route`) is surfaced as `route_worker_refused`
carrying that `kind` and `message`, so a board-geometry problem never reads as
an outage. `route_worker_unavailable` is reserved for the no-answer kinds
(`worker_unavailable`, `worker_error`, or an `{ok:false}` with no error dict);
`pcb_backend_stopped` stays the backend-not-running affordance. The
write-back / materialize / lifecycle logic is validated headless against a canned
`RoutingResult` in `src/test/test_pcb_apply_route_hints.gd` (the worker call is the
only stubbed seam).

### Host bridge (added to `pcb/ui/PcbAnnotationHost.gd`)

The single duck-typed gateway the off-tree core module reaches through:

- `get_board_data()` → the live `pcb_data` model (all pure-model tools).
- `get_spatial_index()` → a lazily-built `pcb_spatial_index` bound to the live
  model (describe / spatial_query / move_relative).
- `render_content_to_image(rect)` → already existed (get_image).

Plus two factories on `pcb/ui/model/pcb_data.gd` — `new_component()` /
`new_trace()` — because the core module cannot preload the plugin object scripts;
it mints objects here and configures them via duck-typed calls.

## Routing-workspace verbs (`minerva_pcb_workspace_propose` / `minerva_pcb_workspace_commit` / `minerva_pcb_workspace_check` + 7 more, C4a / DCR `019f7095c395` S4)

Ten tools over the **routing workspace** — the store that owns route
*candidates* (ghost routes). Both `minerva_pcb_apply_route_hints` (commit=false)
above and `minerva_pcb_workspace_propose` land in this SAME store (S5, C4b,
DCR `019f7095c395` retired the proposal-annotation path both used to also
write). These ten are the agent's doorway onto exactly the verbs the canvas
context menu offers a human, calling the same `RoutingWorkspace` methods
through the same legality table, so neither surface can gain a power the
other lacks.

| Tool | Notes |
|---|---|
| `minerva_pcb_workspace_propose` | router reply → candidates (no annotations); `holds[]` names any task a PINNED candidate held. `spans:[{source_pin, dest_pin, width_mm?, note?, corridor?}]` (DCR `01a022ab356c` leg B) mints the route intent per span internally — same validation/annotation/ref/width channel as `add_route_intent`, atomic across both stores (any invalid span refuses before anything mints) — then routes them in this same call; `spans` + `hint_ids` are a UNION in one run; reply carries `minted_hint_ids` |
| `minerva_pcb_workspace_list` | live candidates + tasks + selection; `include_terminal` for history |
| `minerva_pcb_workspace_get_active` | the focused candidate + its findings; empty active id is a success, not an error |
| `minerva_pcb_workspace_pin` | Keep — future routing routes around it; stales nothing |
| `minerva_pcb_workspace_unpin` | back to a plain draft; stales nothing |
| `minerva_pcb_workspace_freeze` | Settle (K7) — a stronger pin: keep-out + always draft-checked; reject/try-again/edits refuse (`candidate_frozen`) until unfreeze; commit still legal |
| `minerva_pcb_workspace_unfreeze` | the deliberate demotion back to `proposed` — the only way settled geometry becomes retirable again |
| `minerva_pcb_workspace_reject` | discard + reopen the task; terminal; stales every still-live verdict |
| `minerva_pcb_workspace_commit` | Accept — candidate → real copper, in ONE undoable step (below) |
| `minerva_pcb_workspace_reroute_route` | Try-again on the whole route; router runs before the prior is retired. A candidate whose source hints are GONE (deleted intent) or absent (worker attributed `[]`) no longer refuses (DCR `01a022ab356c` leg C): the run degrades to hint-less task/terminal scoping from the candidate's own endpoints, lands on the SAME task (superseding, never duplicating), and the reply says so (`hintless_fallback: true`); only a candidate with neither hints nor endpoints refuses (`unscopable_candidate`) |
| `minerva_pcb_workspace_reroute_span` | **DEGRADED** to a whole-route reroute, named on every reply (below) |
| `minerva_pcb_workspace_check` | set-scoped draft DRC; findings name candidate/segment/via ids; stale candidates refuse |
| `minerva_pcb_promote` | K13's serialize-back, correctness-gated + completeness-ADVISORY (UX4 owner ruling: granular promotion): full gate → canonical YAML write; correctness refusals name findings with NO acknowledge-through; a clean-partial board promotes with unrouted nets as advisory; panel-side copper/component regression guard (allow_copper_regression overrides) |
| `minerva_pcb_export_yaml` | the live board as canonical YAML TEXT — UNGATED and writes nothing, so a board the promote gate refuses can still be read out and diffed. Refuses a `path` by name: `minerva_pcb_promote` is the only verb that writes the canonical file |
| `minerva_pcb_list_mounting_holes` | mounting holes read back (position/diameter/plated, snapped), with a placement advisory for coincident or collinear holes — a pattern no geometric check covers |
| `minerva_pcb_point` | the get_selection MIRROR — select an entity FOR the human (deixis both ways) |
| `minerva_pcb_select` | the same mirror for a WHOLE selection, pads included — `pads: ["U1S.GPIO38", …]` or `entities: [{kind, id}]`; returns get_selection's own read of the result |
| `minerva_pcb_hint_move_bend` / `_insert_bend` / `_delete_bend` | micro hint edits, one revision each; superseded refuses with the sanctioned exits |
| `minerva_pcb_clear_hints_by_author` | the dock menu's MCP twin (human/ai/all; workflow-class only) |

### Two axes, never coupled

A candidate carries a **disposition** (`proposed` → `pinned` / `frozen` /
`superseded` / `rejected` / `committed` — the workflow decision; `frozen` is
live-but-locked: its only exits are unfreeze and commit) and a **validation**
(`unchecked` → `checking` → `clean` / `violating` / `stale` / `error` — the DRC
health). Setting one never moves the other. Every disposition move goes through
one legality table (`pcb_route_candidate.gd::DISPOSITION_TRANSITIONS`);
`superseded`, `rejected` and `committed` are terminal for workflow verbs, and a
refused move comes back with its own name (`illegal_disposition_transition`,
`terminal_disposition`, `candidate_not_found`, …) rather than prose alone.

### Commit is one transaction (INV-1)

`minerva_pcb_workspace_commit` writes one trace per candidate segment — on that
segment's own layer at its own width, so a multi-layer or multi-path route
survives intact — plus its vias, inside a single `begin_batch`/`end_batch`, and
marks the candidate `committed` inside the same batch. PCBData's history
snapshot carries an **eighth bucket** beside the seven board ones
(components/nets/traces/vias/mounting_holes/zones/cutouts): the workspace's
disposition layer. The commit also stamps the *pre*-commit layer onto the entry
the undo will land on, so **one undo removes the copper and returns the
candidate to its pre-commit disposition**. The bucket is an overlay keyed by
candidate id — a candidate proposed *after* a snapshot is never touched by an
undo of an unrelated edit.

All validation precedes all mutation: a refused commit leaves the board, the
disposition and the history untouched. Source hints are **consumed by record**
(`consumed_hint_ids`), never deleted — deleting an annotation inside a step whose
promise is "one Ctrl+Z reverts it" would put an un-undoable side effect in it.

### Staleness (INV-2)

A verb marks `stale` exactly the candidates whose verdict it invalidated:

- **geometry** edits (via insert, a reroute's re-ingest) → the edited candidate;
- **live-set** verbs (reject / commit / try-again / undo-driven uncommit) →
  every candidate that is live *afterwards*, because the draft check is
  set-scoped and their verdicts named a set that no longer holds;
- **pin / unpin** → nothing, deliberately. Pinning moves no copper and does not
  change the set a check scores; it changes what a *future router run* treats as
  a keep-out. Staling there would erase the very check the user ran in order to
  decide to pin.

Only real verdicts (`clean`/`violating`/`error`) are staled — `unchecked` has no
verdict to lose and `checking` is already covered by the workspace-generation
guard. Every verb reports `stale_candidate_ids`, so re-check scope is never
something a caller has to infer.

### Path-scoped edits (INV-3)

A candidate for a multi-pad net can hold **two or more disconnected copper
paths**. `RoutingWorkspace.add_via` — the edit entry the canvas via gesture and
any future edit tool call — resolves the connected path out of the *segment
graph* (endpoint adjacency over the exact points), splits only the segment the
click landed on, and walks the downstream layer flip over that graph. Segments in
another path are returned in `untouched_segment_ids`, untouched. Degenerate
inserts are named no-ops, never nudged to a nearby legal point:
`degenerate_insert_at_endpoint` (splitting there yields zero-length copper) and
`degenerate_insert_on_via` (two holes at one point).

### Reroute-span degrades, loudly

`agent_router` scopes a run by **whole net**, and `route_bridge.parse_route_scope`
refuses a span rather than widening it ("honouring this would route the entire
net and return copper between pads the task never named"). So
`minerva_pcb_workspace_reroute_span` performs a whole-route reroute and stamps
`degraded: true`, `degraded_to: "whole_route"`, `requested_segment_ids`,
`limitation` and `limitation_docket: "019fc155bc32"` on the reply. It creates no
span-scoped task — recording a span question whose answer is whole-route geometry
would make the model claim a scope it never had.

### Pinned candidates route around as keep-outs; scope reaches the worker where it can be stated completely

(Closes DCR finding 7, docket `019fc1b0db34`.) The worker's `route` method
accepts `scope` (RouteTask/net) and `pinned_candidates` parameters; both now
reach it from `PCBPanel.route_board(selection, extra)`, whose `extra` argument
`panel_tools.gd` computes at every propose/reroute call site
(`_route_request_extra`):

- **`pinned_candidates`** — whenever `RoutingWorkspace.pinned` or `.frozen`
  is non-empty, every HELD (pinned + frozen) candidate is serialised to the
  wire shape `ir_candidates.build_overlay` already accepts
  (`keepout_candidates_wire`, the same candidate language
  `begin_check`/draft_check uses) and sent as fixed copper. The router treats
  it exactly like already-accepted copper: an obstacle at keepout margin on
  another net, pathable-along on its own. A hold protects the **space**, not
  only the candidate — and frozen (Epoch UX3, K8) rides the same wire key
  precisely so no second code path can drift from this proven one.
- **`scope`** — added only where it can be stated *completely*, never guessed:
  - a **reroute** always carries `{"tasks": [{"task_id", "net"}]}` from the
    candidate's own task (no `endpoints`, so it names the whole net, never a
    span).
  - a **propose** with an explicit `hint_ids` selection carries
    `{"nets": [...]}` only when *every* selected hint names its net directly
    via `kind_payload.net_names`. A hint resolvable only through
    `source_pins`/`dest_pins` needs the compiled board to resolve — strictly
    more than the panel can re-derive — so a partial scope is never sent (it
    would make `parse_route_scope` refuse a run that used to work). That call
    stays unscoped, exactly as before.
  - absent scope/no pins: the request is `{board, route_hints, selection}`,
    byte-identical to before this fix.

**Closed (DCR `01a022ab356c` leg C):** a reroute on a candidate with no
`source_hint_ids` (or whose hints were deleted) is no longer refused — it
degrades to a hint-less run scoped by the candidate's own task/net/endpoint
pin refs, lands on the SAME task via the ingest task-key override, and the
reply carries `hintless_fallback: true`. Only a candidate with neither hints
nor ≥2 well-formed endpoint refs refuses (`unscopable_candidate`). Corridor
steering stays hint-keyed, so `corridor`/`preserve_shape_as_corridor` on such
a candidate refuse `steering_unavailable_hintless` (`clear_constraint` remains
the stale-gate recovery).

## Bus tool (`minerva_pcb_route_bus_direct`, campaign 2 epoch C unit 5, DCR `019fb572b888` S3+S4)

MCP parity for the canvas **Bus** tool — a three-phase gesture (pick an
ORDERED net list by clicking one SOURCE pad each, draw one spine polyline,
then click one TARGET pad each) that emits N real Trace entities running the
whole way from pad to pad: an axis-aligned breakout leg into the bundle, the
parallel run mitered through bends so the pitch stays constant, and a leg back
out. It authors copper directly, the same altitude as Draw ▸ Trace — it does
not touch the router or the routing workspace.

**`sources` and `targets` are required**, one `"Component.Pin"` ref per net in
the same order as `nets`, each on the net at its own index. Each track peels
off at its own departure station; when two nets' breakout legs cannot be
ordered without crossing, the copper LANDS and a `bus_end_crossing` finding
names both nets and the end (a bad-but-buildable bus is committed so it can be
corrected — only a bus with no geometry is refused). Nothing is re-sorted,
rerouted or moved to another layer to make a crossing go away. The spine must
be axis-aligned and must start clear of the source pads and end clear of the
target pads.

**END THE SPINE SHORT OF, OR LEVEL WITH, THE LAST TARGET PAD'S COLUMN.** This
is the one rule to know before picking `points`. Each track leaves the bundle
at its own departure station and turns to its target, so a spine that runs
*past* the target column forces every lane to double back, and the crossing and
corridor findings that produces read as a placement problem when the spine is
the problem. A bus whose spine ends level with the target column usually needs
**no pin change at all**; read the spine before you read the pads.

**Open-ended lanes.** A `targets` entry of `""` (the array stays one entry per
net) lands that net's lane with NO target leg: its trace ends at the end of its
lane — past the via, on the station layer, for a station bus — as a FREE end
(see `minerva_pcb_add_trace`'s trace-end anchors). No corridor or off-layer
finding is raised for a target that does not exist; the open copper is still
measured against the board like any other. The reply's `open_nets` names them
and `note` says "N lane(s) end open (…) — finish them with the Trace tool from
their free ends." An EMPTY `targets` is not this: it is the corridor-only
preview, which no verb can commit.

**Lane order and the clean-order advisory.** Lane 1 is the lane on the LEFT of
the spine looking along it from the sources to the targets (the most negative
offset in `cumulative_offsets`). When the plan carries a `bus_end_crossing`
finding, `pcb_bus_geometry.clean_pick_order` tries every order of up to four
nets against `bundle_routes`' own findings on the same spine and pads and the
first order with no end crossing comes back as `clean_order`, with the
sentence "pick order NA, NB, NC would leave the bundle clean." appended to
`note`. Advisory only — nothing re-sorts; five or more nets are not searched.

**Order is the caller's order**, always. `pcb_bus_geometry.gd`'s
`cumulative_offsets` deliberately does NOT re-sort nets by any geometric
property (unlike the router's `route_bus`, which re-sorts by destination-side
perpendicular to minimise crossings) — the bus tool's whole premise is that a
human (or an agent) picks "the I2S trio" in a specific order and gets one net
per track in that order. Reversing the net list mirrors which physical side
each track lands on; it is not a bug.

**One call, one implementation shared with the gesture.** `panel_tools.gd`'s
`bus_plan` (pure: per-net width resolution → `PCBData.design_rule_clearance()`
→ `pcb_bus_geometry.lane_pitch_between` (the rule `pitch_between` plus a fixed
0.01 mm `LANE_PITCH_MARGIN_MM`, so laid copper never sits exactly at the limit
the geometric DRC measures against) via `cumulative_offsets` → the inner-fold
guard → `pcb_bus_geometry.bundle_routes` for each net's whole pad-to-pad
polyline) and `bus_commit_plan` (mutating: N `create_trace_entity` calls + one
`save_to_history`) are called by BOTH the canvas tool's commit path and the two
MCP bus verbs — not independently maintained copies of the same math. A plan
with no targets is the canvas's live corridor PREVIEW only; `bus_commit_plan`
and `bus_propose_plan` both refuse it.

**Which side a pad can be reached from.** `minerva_pcb_pin_info` (and every
candidate row of `bus_target_guidance()`) carries `approach_sides`: the sides
(`north`/`east`/`south`/`west`, board frame, y down) from which a trace at the
board's rule width can leave the pad and run straight out clear of the SAME
component's other pads at the declared clearance — `pcb/ui/model/
pcb_pad_approach.gd`, a pure rectangle rule (`approach_sides(pad, others,
width, clearance)`). An LGA column pad on 1 mm pitch reports only its outer
side; a lone land all four. Foreign components are not consulted.

**When no pick order is clean.** A target-end crossing whose reversed order
crosses at the source end has no `clean_order`; the plan then names the way
out as the next call: `leave_open_net` and a concrete `leave_open_targets`
array (the pair's second net left `""`), and the note reads `no pick order
lands both A and B from this side — leave one open: targets ["T1.2", ""] and
finish NB from its free end …`. Fed straight back to the verb it lands the
other net and leaves the named lane open, whose `nets_detail.free_end` then
feeds `minerva_pcb_add_trace`.

**Read before you write: `dry_run: true`.** `minerva_pcb_route_bus_direct`
with `dry_run: true` runs the same plan through the same gates and returns the
identical reply — `findings`, `note`, `open_nets`, `clean_order`, `nets_detail`
with every lane's offset and polyline — with `trace_ids`/`via_ids` empty,
`dry_run: true` and a `dry_run_note` in place of `undo_note`, and writes
nothing: the board, its history and its change journal are untouched
(`panel_tools.bus_dry_run_plan`). An agent reads a bus's findings this way
instead of landing and deleting copper; when a reviewable on-screen ghost is
wanted, `minerva_pcb_workspace_propose_bus` is the call.

**Why the laid pitch is the rule plus a fixed 0.01 mm** (`LANE_PITCH_MARGIN_MM`):
0.01 mm is over a hundred float32 ulps at any board coordinate, ten times the
bus tool's own measurement tolerance, and a twentieth of the tightest clearance
a fab quotes — invisible to the fab, and every hand-derived figure stays a
two-decimal number. A round-up to the authoring grid was rejected because the
grid is the PLACEMENT pitch (2.54 mm by default, a quarter of it for
authoring) and has nothing to do with clearance: it would widen a 0.5 mm bus
to 0.635 mm on one board and to 1.0 mm on another.

**The reply carries what the next verb needs.** Rule for every copper-creating
verb: return the coordinates and ids the NEXT call needs, never ids alone. Both
bus verbs reply with `nets_detail` (built by `panel_tools.bus_nets_detail`), one
entry per net in bus order:

```json
{"net": "NA", "lane_index": 0, "offset_mm": -0.51, "source": "U1.1",
 "landed": false, "target": "",
 "traces": [{"trace_id": "t12", "layer": "top",
             "points": [[10.0, 10.0], [21.02, 10.0], [21.02, 19.49], [120.0, 19.49]]}],
 "via_id": "",
 "free_end": {"trace_id": "t12", "end": "end"},
 "free_end_x_mm": 120.0, "free_end_y_mm": 19.49, "free_end_layer": "top"}
```

`points` are exactly the board's own trace polylines (two runs around a via
station, with `via_id` and `via: [x, y]`). A landed net names its `target`. An
open lane's `free_end` is the very object `minerva_pcb_add_trace` takes as its
`start` anchor — pass it verbatim and the extension lands on the same trace id.
`minerva_pcb_workspace_propose_bus` returns the same entries keyed by
`candidate_id`, with empty `trace_id`/`via_id` and a null `free_end` (ghosts have
no board ids until committed).

## Bus propose (`minerva_pcb_workspace_propose_bus`, docket `019fcac1509d`)

The bus's PROPOSAL verb — same args and same validation path as
`minerva_pcb_route_bus_direct` (`_bus_plan_from_args` → `bus_plan`), but the
ok'd plan lands through `bus_propose_plan` as one workspace RouteCandidate
per net (disposition `proposed`) instead of committing copper. Nothing is
journalled and the board is not mutated; each ghost is resolved through the
normal workspace verbs (`minerva_pcb_workspace_commit`/`_reject`/`pin`, or
the canvas candidate menu). This closes the S4 gap where the bus was the one
author verb that bypassed the propose → steer → accept loop entirely.

- **Widths are the plan's own.** Each record carries a `width_override` — the
  per-net width `bus_plan` resolved from the board's widest existing trace on
  that net (else the board default) — honoured by
  `RoutingWorkspace.ingest_record`, so a hintless bus candidate does NOT fall
  through to `_width_from_hints`' 0.25 mm default.
- **Task identity is whole-net.** `source_hint_ids` is `[]` (a legitimate
  "no hint answered this" verdict), so re-proposing the same bus supersedes
  the prior ghost per net; a net whose current candidate is PINNED is HELD —
  the candidate is not created and `holds[]` names the task, identical to
  `minerva_pcb_workspace_propose`.
- **The gesture is the same code.** The canvas Bus tool's **Shift+Enter**
  (Enter still commits) calls the SAME `bus_propose_plan`, so a human's
  proposed bus and an agent's are identical geometry by construction.

**Per-net width**, absent `width_override`: the widest EXISTING trace already
on that net, else the board's own `design_rules.trace_width_mm` default (same
rule `authored_trace_width()` gives a fresh trace). `width_override`, when
given, replaces every net's width uniformly.

**The INNER-FOLD FINDING** (`bus_plan`): a segment shorter than the widest
`|offset|` in the bus would make the inner offset polyline fold back on itself
— copper crossing itself. It is a bad-but-buildable finding
(`bus_inner_fold`), never silently accepted: the copper lands and the finding
names the offending segment (by endpoint index) and the offset that tripped
it. The canvas preview shows it live, before Enter is ever pressed (tinted
spine + the reason held in the status line).

**One undo step for the whole bus.** Every net's trace is created before the
single `save_to_history` call, so `Ctrl+Z` (or `PCBData.undo()`) removes all
N traces together — never a partial bus.

`layer` is required unless the board declares exactly one copper layer (there
is no toolbar working layer to fall back on from an MCP call, unlike the
canvas gesture's `trace_author_layer()`).

## Board history (`minerva_pcb_undo` / `minerva_pcb_redo`)

The board model keeps one history step per committed action (every tool commit,
bus, delete, drag-move and mutating verb calls `save_to_history` once). Three
surfaces step it, through ONE implementation (`pcb/ui/pcb_board_history.gd` →
`PCBPanel.board_undo` / `board_redo`):

- **Keys** — `Ctrl+Z` undoes, `Ctrl+Shift+Z` or `Ctrl+Y` redoes, while the panel
  has focus. With a `pcb_route_hint` annotation selected the same keys drive that
  hint's own revision stack instead (`minerva_pcb_hint_undo` / `_redo`); the hint
  owns the key whenever it is the target, so the two stacks never both move.
- **Ribbon** — the editor's Undo/Redo buttons reach the panel through the host
  hook pair `_on_panel_undo_request` / `_on_panel_redo_request`.
- **Verbs** — `minerva_pcb_undo` / `minerva_pcb_redo` (`editor_name` only).

Every route names the step in the status line (`Undid "Add bus (2 nets)" — 2 more
to undo.`) and refreshes the canvas and pickers. The verbs reply:

```json
{"ok": true, "action": "Add bus (2 nets)", "undo_depth": 2, "redo_depth": 1}
```

and refuse with `nothing_to_undo` / `nothing_to_redo` at either end of the
history. A selection drag on the canvas only becomes a move once the pointer has
travelled `DRAG_TRAVEL_PX` (3 px), so a click with a wobble in it
records no step to undo.

## Pin→net membership (`minerva_pcb_connect_net` / `minerva_pcb_disconnect_net`)

**A pin belongs to at most one net.** That invariant is enforced in the model
(`PCBData.connect_pin_to_net`), not at the tool layer, so the canvas, the loader
and both verbs get it for free.

**One representation.** Membership lives in each net's own `pins` list and
nowhere else — there is no per-pin `net` field. `minerva_pcb_get_nets` walks
that list; `minerva_pcb_pin_info`, the canvas pad labels and the route-intent
same-net guard go through `PCBData.find_net_for_pin`, which walks the same list;
`to_board_dict()` emits it, which is what `pcb.serialize` and
`minerva_pcb_export_yaml` turn into YAML. So the surfaces cannot disagree about
what a net holds. They could disagree about what a *pin* holds —
`find_net_for_pin` answers with the first net it finds, while `get_nets` and the
YAML show every net a pin is listed on — but only while a pin is on two nets,
which the invariant forbids.

**Connect MOVES.** `connect_net` takes the pin off every other net in the same
operation. The reply names what changed:

```json
{"success": true, "net_name": "SDA", "connected_pins": ["U1.5"],
 "moved": [{"pin": "U1.5", "from": "GND"}]}
```

`moved` is absent when nothing was taken off another net. It is the one fact the
caller cannot read back afterwards — by then the previous membership is gone.

**Disconnect takes a pin off its net.** `net_name` is optional and is a GUARD,
not a selector: name it to state which net you believe holds the pins and be
refused (`pin_not_on_net`, naming the net each pin is actually on, nothing
mutated) if that belief is stale. A pin already on no net comes back under
`not_connected` and is not an error.

**One undo step each.** Both verbs compose all their model mutations into a
single history step via `pcb/ui/model/pcb_undo_step.gd` — a thin, guaranteed-
closing wrapper around `PCBData.begin_batch` / `end_batch`. One
`minerva_pcb_undo` restores every previous membership at once (in the nets list,
in `pin_info`, and in the exported YAML, because all three read the one list);
`minerva_pcb_redo` re-applies the move.

**A conflicted source is reported, not resolved.** `minerva_pcb_load_board` is
the one place a pin can arrive already listed under two nets. The loader does
not pick a winner and does not drop a membership the source deliberately wrote:
`pcb/ui/model/pcb_net_membership.gd` `conflicts()` names each such pin in the
load reply's `warnings` and in the panel's held status lead (`NET CONFLICT: …`).
Reconnecting the pin with `connect_net` heals it — the move sweeps every foreign
membership, not just the first.

**A routing-sidecar record this board cannot support is dropped, and named.**
The load restores `<board>.routing.json` beside the board, and every committed
route candidate's recorded copper ids are then checked against the board that
just arrived. A claim on copper that is gone, or on copper belonging to another
net, is DROPPED rather than re-attached to whatever now carries that id; a
candidate left claiming nothing has its commit retired and its routing task
reopened. Each such drop is named in the load reply's `warnings`
(`stale routing-sidecar ownership record dropped for candidate …`). This is what
keeps a later `minerva_pcb_delete_traces` from reporting "committed by" a
candidate that never routed the copper you deleted.

## The pad row, and the pad verbs

**A pad is a thing you can point at.** Universal Select picks the whole part;
the **Pin Select** tool (the Select group's third button, keyboard **P**,
Shift+P still works) picks a PAD. Click one to select it, shift-click to add or
remove, Escape or an empty click to clear. That is what makes *"see these pins?
move them to the other side of U1S"* answerable: the selection is read, rather
than a refdes guessed from a coordinate.

**One shape, defined once.** `pcb/ui/model/pcb_pad_row.gd` owns THE pad row, and
every surface that describes a pad emits exactly it:

```json
{"kind": "pad", "ref": "U1S.GPIO8", "component": "U1S", "pin": "GPIO8",
 "net": "I2C_SDA", "position": {"x_mm": 41.5, "y_mm": 22.86},
 "layer": "top", "side": "east",
 "approach_sides": ["east"], "roles": ["strapping"]}
```

| field | means |
| --- | --- |
| `ref` / `component` / `pin` | the one address form; a pad has no minted id of its own |
| `net` | the net holding the pin, `""` when free |
| `position` | the pad's WORLD centre, at the same quantum every other reply uses |
| `layer` | `top` / `bottom`, or `all` for a through-hole barrel |
| `side` | which side/COLUMN of its own component the pad sits on — this is what makes *"the other side of U1S"* a filter instead of a coordinate scan |
| `approach_sides` | which way a board-rule trace can LEAVE the pad, clear of the part's own other lands |
| `roles` | what the board's pin table says the pin is for |

`side` and `approach_sides` are different questions and the names are close: the
first is about the PART's geometry, the second about the ROUTE's.

It appears in `minerva_pcb_get_selection` (selected pads), `minerva_pcb_pin_info`
(plus that tool's own `pin_name` / `net_members` / `trace_ids`),
`minerva_pcb_free_pins`, and in the `pads` array `minerva_pcb_move_component`,
`minerva_pcb_move_relative` and `minerva_pcb_rotate_component` now carry — so
"where did pin 1 land after that rotation?" is answered by the move's own reply
instead of a second round trip. (`minerva_pcb_rotate_component`'s description
also states the convention outright. The NUMBER is KiCad's: `rotation_deg`
applies as R(-angle) in the board's y-down frame, so a pad WEST of the origin
lands SOUTH at 90 and NORTH at 270 — which is a COUNTER-clockwise quarter turn
as drawn on screen. The WORDS are the screen's, not the number's: `'clockwise'`
turns the part clockwise as you watch it, which is `rotation - 90`, and it is
the same turn the canvas R key makes.)

**Roles come from the board, never from memory.** A pin's canonical dict may
carry `roles: [strapping]`; every key beyond `number` / `x_mm` / `y_mm`
round-trips verbatim through `pcb_component.pin_extra`, the Go board model's
`Pin.Extra` and the canonical YAML, so a socket's pin table is authored once in
the board document and read everywhere. A board that declares nothing answers
`roles: []` — the vocabulary the docs and the sidebar are written against is
`strapping`, `uart_console`, `jtag`, `onboard_led`, `adc`, and a board may add
its own.

**Move and swap are one undo step each.** Both go through
`pcb/ui/model/pcb_net_membership.gd` (the only writer of a net's `pins` list)
composed by `pcb_undo_step.compose`, exactly as connect/disconnect are. The
sidebar's "Move net to…" and "Swap nets" buttons and the two MCP verbs run the
SAME model op, so the human's click and the agent's call cannot diverge.

**Deixis runs both ways.** `minerva_pcb_get_selection` answers *"which pins is
the human pointing at?"*; `minerva_pcb_select` answers *"look at THESE"* for a
whole selection — the pads land through the same choke points a click uses, and
the reply carries `get_selection`'s own read of the result so the two cannot
disagree.

## DRC over the live board (`minerva_pcb_board_drc`)

`minerva_pcb_drc` and `minerva_pcb_drc_geometric` are backend tools that take
a document (`yaml` or `board`) — the headless form CI, the Go stdio smoke and
an agent with no tab open use. `minerva_pcb_board_drc {editor_name,
geometric?, verbose_warnings?}` is their LIVE-BOARD twin: the panel serializes
the board on screen (`to_board_dict`) and sends it to the very same backend
tool (both are declared as the panel's IPC channels), snapshotted by reference
(`{board_path, board_digest}`) when it is over the broker's 64 KiB cap — the
pipe `pcb.route`, `pcb.draft_check` and `pcb.serialize` ride — and the
worker's `board_model.load_board` resolves it exactly as it resolves `yaml`.
`geometric:false` (default) runs the connectivity check, `geometric:true` the
geometric union. The reply is the worker's findings payload plus
`check` (`"connectivity"` / `"geometric"`) and `board_source: "editor"`; the
board is never echoed (`PCBPanel.worker_check` → `panel_tools._board_drc`).
`minerva_pcb_pcb_board_health` / `minerva_pcb_pcb_assembly_check` remain
plain channels taking `{board}`: a live-board form of each would be a new
verb, so they were left alone.

## Every board-carrying panel channel rides the same by-ref path

`pcb.fab_preview`, `pcb.mask_view`, `pcb.zone_fill`, `pcb.board_health` and
`pcb.assembly_check` all go through `PCBPanel._payload_by_ref` rather than
inlining the whole board, which fails `payload_too_large` once a board outgrows
the 64 KiB pipe. `_payload_by_ref` is the ONE
snapshot sender `pcb.route` / `pcb.serialize` / `pcb.draft_check` /
`pcb.promote_check` already used: over the limit the board becomes
`{board_path, board_digest}` (201 bytes on that board) and the worker's
`board_model.load_board` resolves it, digest-verified, exactly as it resolves
`yaml`. No saved board file is needed — the snapshot is written by the panel,
so an unsaved board travels the same way. Under the limit the payload is
unchanged.

**An overlay flag is only ever true while artwork is on screen.**
`show_fab_preview` and `show_mask` are raised before their fetch runs. A fetch
that comes back with nothing now takes the flag back down and puts the reason
in the status bar's held lead (`ui/model/pcb_overlay_fetch.gd`, the same
mechanism `pcb_load_checks.status_lead` uses); `minerva_pcb_view_state` reports
that flag as `false` and carries the same sentence under
`overlay_unavailable: {flag: reason}`. A board EDIT under a live preview is a
different case and is unchanged: the artwork is dropped, the flag stays up and
the canvas says "re-open Fab Preview".

## Worker (already live — credited, not re-created)

| Tool | Worker method | Purpose |
|---|---|---|
| `minerva_pcb_validate` | `validate` | structural validation |
| `minerva_pcb_generate` | `generate` | canonical YAML → KiCad text |
| `minerva_pcb_gerbers` | `gerbers` | canonical YAML → Gerber (RS-274X/X2) + Excellon drills |
| `minerva_pcb_check_libraries` | `check_libraries` | footprint/symbol existence vs a `lib_dir` |
| `minerva_pcb_check_bom` | `check_bom` | BOM extraction + validation |
| `minerva_pcb_export_assembly` | `assembly_bom` + `assembly_cpl` | pre-assembly order package (BOM + CPL/pick-and-place CSVs, house profile — `jlc` today) |
| `minerva_pcb_fetch_libraries` / `minerva_pcb_library_status` | (in-process Go) | library data dir |

Gerber/fab export shipped via `minerva_pcb_gerbers` (docket `019eb47ddebc`). See
`docs/gerbers.md` for the layer set, coordinate-format decision, and the
fab-correctness HITL gate; `docs/worker.md` for the worker method.

Assembly export (`minerva_pcb_export_assembly`, docket `019fc2f8b903`, D0-5):
C8 shipped the `assembly_bom`/`assembly_cpl` worker methods
(`worker/pcb_worker/assembly_outputs.py`) with dispatch tests but no
agent-facing tool; this round is the Go/manifest wiring only — one MCP tool
calling both worker methods over the same board+profile, refusals (unknown
house, missing part identity) surfaced verbatim via the same `isError`
convention every other worker-backed tool uses.

## Retired (superseded — NOT reimplemented)

| Legacy tool | Replacement |
|---|---|
| `minerva_pcb_add_annotation` / `list_annotations` / `remove_annotation` / `clear_annotations` | core `minerva_annotations_*` against the pcb host |
| `minerva_pcb_add_route_hint` / `list_route_hints` / `remove_route_hint` / `clear_route_hints` | core `minerva_annotations_*` (`pcb_route_hint` kind) against the pcb host |
| `minerva_pcb_interpret_route_hints` | agent-router child `019eb47eb567` re-homes it |
| `minerva_pcb_create_note` | generic `plugin_data` note flow |
| `minerva_create_pcb_editor` | `minerva_create_plugin_editor` |

## Canvas gestures (human UI, docket `019fb933d4a9`)

The panel's tool tooltips are short by design (Illustrator-style: name +
shortcut + one-phrase action) so the default Godot tooltip popup never
overflows the screen — see `PCBPanel._wrap_tooltip` and the while-armed status
bar text (`_update_status`) for the mechanism. The full step-by-step grammar
each tooltip used to carry lives here instead, and (for the tools that draw or
edit something) as a one-line hint in the status bar for as long as the tool
stays armed.

**Select & move (S)** — click to select; drag a part to move it (snaps to
grid); drag empty canvas to box-select; `R` rotates the selection.

**Pan** — drag anywhere while armed. Also works from any other tool: right-
drag, middle-drag, or hold Space and drag.

**Inspect Pin / Pin Select (P, or Shift+P)** — the toolbar button and the
status bar call this tool *Inspect Pin*; the sidebar section it fills is *Pin
Selection*. Click a pad to SELECT it: its copper is haloed, the Pin Info
section fills, and the Pin Selection section below shows
the pad's row (net, side, roles), the component's free pins under a side
filter, and the two net edits — "Move net to…" and, with exactly two pads
selected, "Swap nets". Shift-click adds or removes a pad; a shift-click on
empty canvas leaves the selection alone, so a multi-pad selection survives a
missed click. A plain click on empty canvas clears it; Escape clears
everything; press the button again to exit to Select. The pad selection is
what `minerva_pcb_get_selection` reports, and what `minerva_pcb_select` sets
from the other side. There is one pad-picking mode, not two: Shift+P arms it
and the single-click readout is the pin inspector's.

**Group / ungroup (Ctrl/Cmd+G / Ctrl/Cmd+Shift+G)** — with 2+ components
selected, groups them so they move as one; ungroups the selected group.
Bare `G` alone toggles the grid instead, not a modifier miss.

**Zone vertex editing** (on a SELECTED zone) — drag a handle to move a
corner, right-click a handle to delete it, click an edge to insert a new
corner there (a zone can't drop below 3 corners — the delete is refused).

**Draw ▸ Pour** — pick its net and layer in the sidebar pickers, then click
each corner on the canvas; double-click or press Enter to close (needs 3+
corners; Esc or right-click cancels mid-draw). Corners snap to a quarter of
the grid — hold Ctrl/Cmd to place freely. With the layer picker left on
"Working layer" the pour goes on the toolbar's working layer.

**Draw ▸ Keepout** — same corner-clicking grammar as Pour (double-click/Enter
to close, Esc/right-click to cancel, quarter-grid snap with Ctrl/Cmd to place
freely), but no net picker: a keepout forbids copper rather than being copper,
the same as a KiCad rule area.

**Draw ▸ Cutout** — same corner-clicking grammar as Pour/Keepout: click each
corner on the canvas; double-click or Enter closes the polygon (needs 3+
corners); Esc or right-click cancels mid-draw, discarding every placed vertex
(not just the last one). Corners snap to a quarter of the grid — hold Ctrl/Cmd
to place freely. No net or layer picker — a cutout is an opening through the
WHOLE board (every layer at once), not copper on one of them, so neither field
applies. The commit toast names the same caveat as the MCP `create_cutout`
tool's schema: authored and validated only — routing, DRC and Gerber export
all ignore a cutout today (see "Cut-outs" in `board-yaml.md`).

**Draw ▸ Trace** — draws real copper directly, bypassing the router (Hints ▸
Trace below instead asks the router for a route). Click a pad, a via **or a
free trace end** to start — the trace takes that anchor's net — then click
each waypoint, then click another anchor to finish on its centre, **or click
inside a pour on your own net to finish there** (or double-click/Enter to end
it where it is; Esc/right-click cancels). A via
anchors for the same reason a pad does: it already carries a net, and a via is
where a hand-routed run changes layer, so it is where the next leg of that run
begins or ends. A **free trace end** — an end touching no pad, via or same-net
copper — anchors because it is where a run stopped: starting on one EXTENDS
that trace (same id; the run is added to its polyline, on the trace's own
layer), and finishing on one appends your run to that trace. A joined end is
not an anchor; where a pad or via and a trace end are both within snap, the
pad or via wins.

A **same-net pour** is the fourth thing a run can finish on, and on a
plane-returned board it is what most GND runs actually end on: one click inside
the plane ends the run there, with no double-click and no free end left behind.
It is the only net-scoped anchor — a click inside a pour of a DIFFERENT net is
a waypoint, not a landing, and a run left ending there reads as an open to the
connectivity DRC and a short to the geometric one, which is what it is. What
the click lands on is the pour's COMPILED fill, so a click inside the outline
but inside a carved void or over an unfilled pour ends nothing, and a hidden
pour is not clickable at all. A pour cannot START a run: a trace inherits its
net from where it starts, and a plane has no place in particular to start from.

An anchor on NO net is refused by name when you start on it
(the trace would have no net to inherit), and merely named out loud when you
finish on a pad or via; finishing on a trace end of another net or another
layer is refused instead, keeping your points — one polyline carries one net
on one layer.

**Cut here** (right-click a trace) — drops everything after the interior
vertex nearest the click (within the pad snap); greyed beside an end vertex,
since cutting there would be a delete or a no-op. One undo step. The new end is
a free end unless something already joins it (`free_end` in the verb reply),
so the recipe for a bad exit is: right-click at the last good bend → Cut here
→ Draw ▸ Trace from that end. Waypoints snap to a quarter of the grid — hold Ctrl/Cmd to place
freely. Drawn at the width set in the sidebar's trace-width box, on the
toolbar's **working layer** — the F.Cu / B.Cu chooser. That chooser sets where
copper goes and nothing else: it never changes what the canvas shows, and
hiding a layer through View ▸ Copper layers never changes where the next trace
lands.

Starting on a **pad** also marks and labels **one destination**: the nearest
copper on that pad's net that is not already joined to it, with the net, the
destination part and the distance. It is picked when the gesture starts and
does not move until the trace commits or is cancelled, and every other
airwire dims while it is up (none are removed). It is guidance only — every
click, waypoint and finish stays exactly as legal as it was; DRC is still the
correctness net. Turning the ratsnest off (N) hides it along with the rest.
Starting on a **via** locks no destination — the focus is resolved from a pad
reference — so the ratsnest draws unchanged for that gesture.

**Draw ▸ Bus** — draws N parallel traces at once (campaign 2 epoch C unit 5,
DCR `019fb572b888`). Three phases in one tool, and **every phase change is a
click** — pads, then clear board, then pads again. **SOURCES** — click a pad to
add its net to an ORDERED list, that pad being the net's source (click a
picked net's pad again to remove it; 2+ needed). A click on a **trace** while
picking sources is inert and refused by name: a trace is not a bus anchor, and
the click that ends SOURCES is also the path's first vertex, which must not
start on existing copper. **PATH** — the first click clear of the pads and of
copper ends SOURCES and places the path's first vertex; each further click
places another, snapped to the axis it travels furthest along so the bus is
Manhattan by construction. From here on a vertex over a trace is fine — the
bus commits on its own layer. **TARGETS** — a click on a pad of one of
the bus's own nets ends PATH and lands that net's target; every legal pad is
ringed on screen and an illegal one is refused by name. Enter or a
double-click clear of the pads then COMMITS (Shift+Enter proposes ghosts); a
net still without a target commits with its lane ending OPEN — a free end the
Trace tool can finish — and the status line says how many lanes end open.
Committing is its own act, never the click that lands a target. Esc/right-click
peels ONE phase per press.

**Every lane wears its net.** Each net's pip, rings, ghost track and airline
share that net's ratsnest colour; the ghost carries "NA → V1.1" (or "NA →
open" / "NA → ?") at its far end; every eligible ring is labelled with its
net, the ratsnest's suggestion is the dashed ring, the landed target the solid
one. The whole mapping is readable at once in the standing status line while
the tool is armed — "lanes: 1 NA  U1.1 → V1.1 · 2 NB  U2.1 → open". The
canvas builds it from `bus_target_guidance()` rows (`lane_index`, `color`,
`ending`); no MCP verb reads the live gesture, so an agent's lane map is the
`nets` order it passed plus the reply's `open_nets`.

**Lane order is pick order, and a visible choice.** Lane 1 is the lane on the
left of the spine looking from the sources to the targets. In SOURCES and
TARGETS, click a pick's NUMBER (the label beside its pip ring — the pad itself
still toggles the net) to move that net one lane outward, toward lane 1;
Shift+click moves it inward; at either end the click is a no-op that says so.
Everything per net moves together, targets included, and the ghosts replan.
When the picked order makes two legs cross, the status line adds "pick order
NA, NB, NC would leave the bundle clean." (up to four nets; advisory only). Which phase you are in is marked on
the Bus button itself for as long as the tool is armed — three pips along its
bottom edge, filled up to the live one, in the order named above. It does not
time out and it does not move with the board, so glancing away never loses it.
While pathing, N
ghost tracks preview live, coloured by net; once every target is picked the
ghosts are the whole pad-to-pad routes that would commit. A spine segment
shorter than the widest track offset, or a pair of nets whose breakout legs
cross, tints the spine and is held in the status line — and still lands, named,
so it can be corrected (only a bus with no geometry is refused). All N traces
land in ONE undo step. See the "Bus tool" section above for
`minerva_pcb_route_bus_direct`, the MCP parity tool calling the exact same
commit path.

**Eraser** — click an entity to delete it: one click, one undo step. Clicking
empty space does nothing and leaves the tool armed. Esc or switching tools
disarms it. Locked components/traces are skipped.

**Delete (trash-can button)** — deletes the WHOLE selection — components,
traces and zones together (Delete/Backspace does the same). One undo restores
all of it. Locked components/traces are skipped.

**Trace-width box** (sidebar, arms alongside Draw ▸ Trace) — width of NEW
traces, in mm. Starts at the board's own `design_rules.trace_width_mm` when it
declares one, else your stored preference (`minerva_pcb_get/set_preference`,
key `trace_width_mm`); turning it stores that preference for boards that
declare no rule. Affects new traces only — it does not re-width anything
already drawn.

**Zone net / layer pickers** (sidebar, arm alongside Pour/Keepout) — the net
picker is required by the board contract for a pour (a keepout needs none, so
the picker hides for it); the layer picker follows the toolbar's working layer
while left on "Working layer", and pins the pour to one copper layer otherwise.

**Hints ▸ Trace (single-trace route hint)** — click a pad or point to start,
click waypoints, then click a pad or double-click empty space to finish
(Esc/right-click cancels). This authors a route REQUEST for the router, not
copper — see Draw ▸ Trace above for drawing copper directly.

A hint's waypoints may carry a **layer** — see "Layer-hop waypoints" in
`docs/routing.md`. An entry is either `[x_mm, y_mm]` (a plain corner) or
`{"x": mm, "y": mm, "layer": "<copper>"}` (a corner the run changes layer at,
where the router places one through via sized from the board's `design_rules`).
That is how ONE hint expresses "F.Cu, duck under here, back up there, F.Cu"
instead of an unroutable straight line plus separate via ghosts. Moving or
inserting a bend — canvas or `minerva_pcb_hint_move_bend` /
`_insert_bend` — preserves whatever layer that waypoint carried; deleting the
bend deletes the hop with it.

**Hints ▸ Edit Hint** — click a committed route hint to select it, drag a
handle to move a bend, right-click a handle to delete it, click a segment to
insert a new bend (Esc or switching tools exits).

**Via proposals carry an owner**. A via proposed with
`minerva_pcb_propose_via`'s `for_hint` — or clicked on canvas while a route
hint is selected — records that hint on the candidate's `source_hint_ids` and
inherits its net, so `minerva_pcb_workspace_list` shows the row as
`owner: "hint <id>"`. Proposed with neither, it is still a legal ghost and
still commits, but every listing marks it `owner: "none"` / `unowned: true`:
"which hint is this via for" is then READ off the listing rather than inferred
by matching via coordinates to hint segments by eye. Via size comes from the
board's `design_rules` unless `size_mm`/`drill_mm` say otherwise.

**Hints ▸ Add Via** — click a route-hint annotation carrying segment geometry
to select it, then click a point on its route to split the segment, add a
via, and flip the trace past that point to the opposite copper layer (Esc or
switching tools exits). Its live target today is a legacy pre-cutover
proposal still on a `.pcbskel` (see S5 above) — a fresh propose lands a
canvas candidate instead, edited via the candidate context menu.

**Propose button** — runs the router over open route hints and lands
inspectable candidates in the routing workspace (rendered as ghost traces on
the canvas); the board itself is not changed until a candidate is committed
(see the route-correction loop above).

**Properties ▸ zone Net / Layer** (re-property an already-drawn zone) — Net
accepts declared nets only (an undeclared net would make the whole board
unexportable); Layer accepts the board's declared copper stack only (moving a
zone off the stack would make the board unexportable).

**Properties ▸ trace Width** (re-property an already-drawn, selected trace) —
changing it re-widens that one trace as a single undoable step; it does not
touch the width used for new traces (that is the sidebar trace-width box
above).

## Coexistence & name collision (until cutover)

The legacy in-tree `MCPPCBTools` STAYS registered until cutover and sits earlier
in `MinervaMCPServer._modules`, so it wins dispatch (first `can_handle` wins) and
owns the runtime `minerva_pcb_*` surface for the **in-tree editor**.
`MinervaMCPServer.tool_registry` is a name-keyed dict (last-writer-wins) and there
is no per-argument routing at `can_handle` time, so a duplicate registration would
either clash or be shadowed.

**Resolution — register-only-when-absent (single registration, identical names).**
`MCPPcbPanelTools` is added as a sibling of `MCPCadTools` (AFTER legacy) and
registers each `minerva_pcb_*` name **only when it is not already in the registry**
— i.e. only after the legacy module is removed at cutover. Until then legacy owns
the runtime surface; the new module's handlers are still fully validated by
`src/test/test_pcb_panel_tools.gd` (which calls `handle()` directly), and they flip
on automatically at cutover with byte-identical names. No distinguishing prefix was
needed.

**Coexistence limitation (documented):** while legacy is present, the plugin
panel's *structural* tools are not reachable over the MCP transport (legacy grabs
the shared names and only knows the in-tree editor). The plugin panel's
annotation/route-hint tools DO work now via the retired→core `minerva_annotations_*`
path (its `PcbAnnotationHost` is registered in `AnnotationHostRegistry`), and its
worker tools work via the plugin IPC channel. Cutover (removing `MCPPCBTools` from
`_modules`) flips the structural surface to the plugin panel with no agent-facing
name change.
