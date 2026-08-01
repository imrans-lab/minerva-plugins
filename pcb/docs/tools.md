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
| `minerva_pcb_add_component` | golden-parity; `data.new_component()` factory + `set_footprint_by_name` |
| `minerva_pcb_move_component` | golden-parity; snapped |
| `minerva_pcb_move_relative` | NL move via `host.get_spatial_index().interpret_relative_move` |
| `minerva_pcb_rotate_component` | |
| `minerva_pcb_delete_component` | |
| `minerva_pcb_connect_net` | model `connect_pin_to_net` (auto-creates net) |
| `minerva_pcb_spatial_query` | spatial index `get_components_near` + `describe_relative_position`; empty ref → `get_components` shape |
| `minerva_pcb_describe_component` | golden-parity; spatial `describe_component_context` |
| `minerva_pcb_get_change_journal` | model change journal |
| `minerva_pcb_import_csv` | model `from_csv` |
| `minerva_pcb_export_csv` | model `to_csv` |
| `minerva_pcb_import_footprint_geometry` | mutates existing components' pad geometry + optional position correction |
| `minerva_pcb_import_trace_geometry` | segment→polyline merge; `data.new_trace()` factory; preserves supplied ids |
| `minerva_pcb_export_trace_geometry` | round-trips with the import shape; stamps `trace_id` / via `id` |
| `minerva_pcb_delete_traces` | removes named traces/vias without clearing the board |
| `minerva_pcb_get_image` | snapshot-style via `host.render_content_to_image`; null-safe headless |
| `minerva_pcb_apply_route_hints` | route the open route hints → cyan proposals (default) or committed traces (`commit=true`); see the route-correction loop below |
| `minerva_pcb_list_zones` | read-only; summary per zone (`zone_id`, `kind`, `net`, `layer`, `point_count`) |
| `minerva_pcb_describe_zone` | read-only; full zone incl. outline points (`zone_outline_points` → `zone_outline_to_list` round trip) |
| `minerva_pcb_delete_zone` | `data.remove_zone`; one journalled step, mirrors `delete_component`'s idiom |
| `minerva_pcb_set_zone_net` | `data.set_zone_net`; current-value guard before calling the model (below) |
| `minerva_pcb_set_zone_layer` | `data.set_zone_layer`; current-value guard before calling the model (below) |
| `minerva_pcb_set_trace_width` | `data.set_trace_width`; one journalled step, current-value guard, out-of-range **refused** (below) |
| `minerva_pcb_list_vias` | read-only; one entry per board via (`via_id`, `x_mm`, `y_mm`, `net_name`, `from_layer`, `to_layer`, `size_mm`, `drill_mm`) (below) |
| `minerva_pcb_delete_via` | `data.remove_via_by_id`; one journalled step, unknown/empty id **refused** (below) |
| `minerva_pcb_get_preference` | read-only; plugin-scoped preference store (below) |
| `minerva_pcb_set_preference` | validated + clamped write, pushed live into the panel (below) |

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

## Board-via tools (`minerva_pcb_list_vias` / `delete_via`, B1-U2)

MCP parity for the via surface the canvas gained in the same unit (a via is now
a first-class selectable entity: click, marquee, Delete/trash, eraser). Both
tools ride the same journalled model path the canvas does — `data.vias` for the
read, `pcb_data.remove_via_by_id` for the delete — so an agent's delete and a
human's Delete key are indistinguishable to the board and share one undo
history.

**`minerva_pcb_add_via` is NOT the counterpart of these.** It edits a
route-hint **proposal annotation** (splitting a proposed segment and inserting a
via into the proposal, via `PcbRouteHintKind.apply_via_at_point`), not the
board. Nothing it adds appears in `list_vias`. Board vias are created only by
committing routes — `apply_route_hints` with `commit`, or
`import_trace_geometry`. The honest board-via surface is: **create** by
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
separate id spaces (`trace_N` / `via_N`) with separate counters, so a trace and
a via spelled identically never block each other.

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

A request with no selector at all is the one hard error: deleting nothing and
deleting everything must never be the same request. An **empty** `net_name`, or
empty id arrays, does not count as supplying a selector — a call carrying only
`net_name: ""` is that same error, not a no-op.

### Undo

A delete that changed something is one undo step, exactly like an import — one
undo restores the deleted traces **and** vias. A delete that removed nothing takes
no snapshot, so it adds no step you have to click past.

### Known gap: no region selector, no clipping

There is deliberately **no spatial or bounding-box selector**. A region predicate
must silently decide what to do with a trace that CROSSES the boundary, and this
project's standing ruling is that routing, DRC and CAM fail closed rather than
approximate copper. To clear an area: export, filter on the real coordinates now
that every segment names its trace, then pass the ids you chose.

**Partial-trace clipping — splitting a trace at a boundary and keeping one side —
is not supported.** A trace is deleted whole or not at all. To shorten one today,
delete it and import the geometry you want in its place.

## Route-correction collaboration loop (`minerva_pcb_apply_route_hints`)

Closes the route-correction loop (agent-router child `019eb47eb567`, DCR
`019dc140`). Signature: `{editor_name, hint_ids?, commit?}`.

**propose → inspect → apply → iterate**

1. **PROPOSE** (`commit` absent/false) — gather the board's OPEN `pcb_route_hint`
   annotations (or the given `hint_ids`), route them through the worker, and write
   each routed polyline back as an **AI-authored proposal annotation**. Proposals
   do NOT mutate the board — the user inspects them in the dock/canvas first.
   Returns `{proposed, proposals:[…], unrouted:[…], stuck:[…]}`.
2. **APPLY** (`commit=true`) — re-route the selected open hints and MATERIALIZE the
   results as real traces in the model (journalled via `save_to_history`), then
   transition the source hints `open → applied`. Returns
   `{applied, applied_hint_ids, traces_added, failed:[…], unrouted, stuck}`.
3. **ITERATE** — applied hints drop out of the default (open) gather, and AI
   proposals are never re-routed (they carry `kind_payload.proposal_for`), so
   re-running after the user edits/adds hints picks up only the fresh open hints.

**Proposal representation (decision).** A proposal is an AI-authored
`pcb_route_hint` envelope — the simplest conformant carrier, no new kind:

- `author.kind = "ai"` → renders in the substrate **author cyan** (the kind's
  `render()` swaps its layer tint for cyan when the author is AI), visually
  distinct from a human, layer-tinted hint.
- `kind_payload.hint_type = "single_trace"`, `waypoints` = the routed polyline,
  `net_names = [net]`, and `proposal_for = [source hint id(s)]` linking the
  proposal to the hint it answers. `lifecycle = "open"`.
- Built through the existing `host.build_route_hint_envelope(…, author_kind="ai")`
  + `add_annotation_v2` — no bespoke authoring path.

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
failure-feedback) only when the IPC channel is genuinely not ready. The
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

## Worker (already live — credited, not re-created)

| Tool | Worker method | Purpose |
|---|---|---|
| `minerva_pcb_validate` | `validate` | structural validation |
| `minerva_pcb_generate` | `generate` | canonical YAML → KiCad text |
| `minerva_pcb_gerbers` | `gerbers` | canonical YAML → Gerber (RS-274X/X2) + Excellon drills |
| `minerva_pcb_check_libraries` | `check_libraries` | footprint/symbol existence vs a `lib_dir` |
| `minerva_pcb_check_bom` | `check_bom` | BOM extraction + validation |
| `minerva_pcb_fetch_libraries` / `minerva_pcb_library_status` | (in-process Go) | library data dir |

Gerber/fab export shipped via `minerva_pcb_gerbers` (docket `019eb47ddebc`). See
`docs/gerbers.md` for the layer set, coordinate-format decision, and the
fab-correctness HITL gate; `docs/worker.md` for the worker method.

## Retired (superseded — NOT reimplemented)

| Legacy tool | Replacement |
|---|---|
| `minerva_pcb_add_annotation` / `list_annotations` / `remove_annotation` / `clear_annotations` | core `minerva_annotations_*` against the pcb host |
| `minerva_pcb_add_route_hint` / `list_route_hints` / `remove_route_hint` / `clear_route_hints` | core `minerva_annotations_*` (`pcb_route_hint` kind) against the pcb host |
| `minerva_pcb_interpret_route_hints` | agent-router child `019eb47eb567` re-homes it |
| `minerva_pcb_create_note` | generic `plugin_data` note flow |
| `minerva_create_pcb_editor` | `minerva_create_plugin_editor` |
| `minerva_pcb_export_yaml` | worker `pcb.serialize` / the panel's **Export YAML** toolbar action |

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

**Inspect Pin (Shift+P)** — click a pin to see its info in the Pin Info
section; press the button again to exit (clicking empty canvas just clears
the readout — the tool stays armed).

**Group / ungroup (Ctrl/Cmd+G / Ctrl/Cmd+Shift+G)** — with 2+ components
selected, groups them so they move as one; ungroups the selected group.
Bare `G` alone toggles the grid instead, not a modifier miss.

**Zone vertex editing** (on a SELECTED zone) — drag a handle to move a
corner, right-click a handle to delete it, click an edge to insert a new
corner there (a zone can't drop below 3 corners — the delete is refused).

**Draw ▸ Pour** — pick its net and layer in the sidebar pickers, then click
each corner on the canvas; double-click or press Enter to close (needs 3+
corners; Esc or right-click cancels mid-draw). Corners snap to a quarter of
the grid — hold Ctrl/Cmd to place freely. With the layer picker left on "View
layer" the pour goes on the toolbar's selected copper layer; on "All" it
falls back to the hardcoded `ZONE_DEFAULT_LAYER`, the bottom copper layer.

**Draw ▸ Keepout** — same corner-clicking grammar as Pour (double-click/Enter
to close, Esc/right-click to cancel, quarter-grid snap with Ctrl/Cmd to place
freely), but no net picker: a keepout forbids copper rather than being copper,
the same as a KiCad rule area.

**Draw ▸ Trace** — draws real copper directly, bypassing the router (Hints ▸
Trace below instead asks the router for a route). Click a pad to start — the
trace takes that pad's net — then click each waypoint, then click another pad
to finish on it (or double-click/Enter to end it where it is; Esc/right-click
cancels). Waypoints snap to a quarter of the grid — hold Ctrl/Cmd to place
freely. Drawn at the width set in the sidebar's trace-width box, on the
toolbar's selected copper layer (or the hardcoded `TRACE_DEFAULT_LAYER`, the
top copper layer, when the filter is "All"). Note this is the OPPOSITE
default from Draw ▸ Pour above (bottom) — leaving the filter on "All" and
drawing both puts them on different layers with no warning.

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
the picker hides for it); the layer picker follows the toolbar's layer filter
while left on "View layer", and falls back to `ZONE_DEFAULT_LAYER` (bottom
copper) when the filter is "All".

**Hints ▸ Trace (single-trace route hint)** — click a pad or point to start,
click waypoints, then click a pad or double-click empty space to finish
(Esc/right-click cancels). This authors a route REQUEST for the router, not
copper — see Draw ▸ Trace above for drawing copper directly.

**Hints ▸ Edit Hint** — click a committed route hint to select it, drag a
handle to move a bend, right-click a handle to delete it, click a segment to
insert a new bend (Esc or switching tools exits).

**Hints ▸ Add Via** — click a proposal to select it, then click a point on its
route to split the segment, add a via, and flip the trace past that point to
the opposite copper layer (Esc or switching tools exits).

**Propose button** — runs the router over open route hints and writes back
inspectable cyan proposals; the board itself is not changed until an applied
route hint is committed (see the route-correction loop above).

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
