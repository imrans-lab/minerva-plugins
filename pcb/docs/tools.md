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
- **WORKER** — already shipped as Go/worker MCP tools (`pcb_*`); not re-created.
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
| `minerva_pcb_import_trace_geometry` | segment→polyline merge; `data.new_trace()` factory |
| `minerva_pcb_export_trace_geometry` | round-trips with the import shape |
| `minerva_pcb_get_image` | snapshot-style via `host.render_content_to_image`; null-safe headless |
| `minerva_pcb_apply_route_hints` | route the open route hints → cyan proposals (default) or committed traces (`commit=true`); see the route-correction loop below |

Mutations go through the model API, so the change journal, undo history and the
`data_changed` dirty relay come for free.

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
| `pcb_validate` | `validate` | structural validation |
| `pcb_generate` | `generate` | canonical YAML → KiCad text |
| `pcb_gerbers` | `gerbers` | canonical YAML → Gerber (RS-274X/X2) + Excellon drills |
| `pcb_check_libraries` | `check_libraries` | footprint/symbol existence vs a `lib_dir` |
| `pcb_check_bom` | `check_bom` | BOM extraction + validation |
| `pcb_fetch_libraries` / `pcb_library_status` | (in-process Go) | library data dir |

Gerber/fab export shipped via `pcb_gerbers` (docket `019eb47ddebc`). See
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
