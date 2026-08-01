extends MinervaPluginPanel

## Ownership marker for the panel-executed tool dispatcher: fallback-resolved
## panels (AnnotationHostRegistry path) aren't broker-keyed by editor name, so
## the dispatcher reads this duck-typed property to verify the calling tool's
## plugin owns this panel (fail-safe deny otherwise). HITL-caught 2026-07-16.
var plugin_id: String = "pcb"
## PCB editor panel — Round B (full board-editing UI port).
##
## Replaces the walking-skeleton crude renderer with the real ported canvas
## (pcb_canvas.gd) + the Round-A board model (model/pcb_data.gd & siblings) +
## a board-editing toolbar and status bar. The platform annotation dock (mounted
## via get_annotation_host()) owns annotation/route-hint authoring; NONE of that
## lives in this panel anymore.
##
## Off-tree class_name gotcha: this plugin lives OUTSIDE Minerva's res:// tree, so
## plugin-local class_names are unresolvable. This script declares NO class_name
## and preloads its siblings by relative path. It extends the CORE base
## MinervaPluginPanel (in res://, resolvable). Cross-file model refs are
## duck-typed (never typed AS a plugin script).
##
## Host integrations preserved VERBATIM from the skeleton (do not regress):
##   * _init builds the PcbAnnotationHost eagerly so get_annotation_host() is
##     valid the instant the platform queries it during mount.
##   * annotations_changed → content_changed relay, gated by _restoring (W-14).
##   * AnnotationHostRegistry register/deregister by editor tab title.
##   * _on_panel_save_request writes the annotation sidecar; _on_panel_load_request
##     captures file_path in BOTH document shapes (W-15) + loads the sidecar.

const _PcbAnnotationHostScript: Script = preload("PcbAnnotationHost.gd")
const _PcbDataScript: Script = preload("model/pcb_data.gd")
const _PcbComponentScript: Script = preload("model/pcb_component.gd")
const _PcbCanvasScript: Script = preload("pcb_canvas.gd")
const _LegacyAnnotationMigration: Script = preload("legacy_annotation_migration.gd")
const _PanelLayoutScript: Script = preload("panel_layout.gd")
const _PcbRouteHintKindScript: Script = preload("kinds/pcb_route_hint_kind.gd")
const _PanelToolsScript: Script = preload("panel_tools.gd")
## The ONE canonical layer contract (canonical id <-> KiCad copper name). The
## layer selector shows KiCad names and carries canonical ids — see
## _rebuild_layer_option. Declared with `:=` (NOT `: Script =`, unlike the
## instantiated-script consts above) so the parser keeps the GDScript class type
## and can resolve its static funcs — a `Script`-typed const cannot.
const PcbLayerStack := preload("model/pcb_layer_stack.gd")
## T2 (S2.2) strangler-fig SHADOW phase: the routing workspace is populated
## ALONGSIDE the existing annotation proposals on every propose (dual-write,
## see panel_tools.gd _dual_write_propose). It drives nothing visible yet —
## annotation proposals remain the UI's source of truth.
const _PcbRoutingWorkspaceScript: Script = preload("model/pcb_routing_workspace.gd")
## T2a: durable, versioned, crash-safe persistence for the routing workspace,
## with a board-coherence fingerprint. Wired beside the annotation sidecar in
## _on_panel_save_request / _on_panel_load_request.
const _PcbRoutingSidecarScript: Script = preload("model/pcb_routing_sidecar.gd")
## T2.3: the strangler-fig cutover coordinator — a per-surface authority latch
## ({canvas, inspector, verbs, mcp, persistence, drc}). In T2.3 every surface
## stays annotation-authoritative (mechanism only); T3/T5 flip individual
## surfaces once their write path is workspace-backed. Built beside the workspace.
const _PcbRoutingCutoverScript: Script = preload("model/pcb_routing_cutover.gd")
## Plugin-scoped preferences (A7, docket 019fb92f07e2). The panel reads the store
## for seeding and writes it when the human turns the width box; the MCP surface
## (panel_tools.gd) reaches the SAME process-wide store, which is why an agent's
## write shows up in this panel's controls.
const _PcbPrefsScript: Script = preload("model/pcb_prefs.gd")
## Trace-width bounds/default — the ONE contract, shared with the model setter
## and the preference registry (pcb_trace.gd).
const _PcbTraceScript: Script = preload("model/pcb_trace.gd")

## The overlay Control name Editor.gd mounts the platform AnnotationOverlay
## under (Editor.gd:855). The route-flow cluster reaches it by find_child on
## the canvas (get_annotation_overlay_parent's own target), the same lookup
## Editor.gd performs — see _find_annotation_overlay.
const _OVERLAY_NODE_NAME := "PlatformAnnotationOverlay"

## Default board handed to a fresh (anonymous) editor. A brand-new board is
## EMPTY (finding 4): no phantom parts the user never placed. Board name / size /
## grid are kept so the canvas has a valid frame to draw and snap against.
const _DEFAULT_BOARD := {
	"version": 1,
	"name": "Untitled",
	"width_mm": 60.0,
	"height_mm": 40.0,
	"grid_mm": 2.54,
	"components": [],
}

var _annotation_host: AnnotationHost = null

## Editor tab name under which we registered the host (for symmetric teardown).
var _registered_editor_name: String = ""

## Absolute board file path (host_owned). Empty for anonymous editors.
var _file_path: String = ""

## Board model (pcb_data.gd) — round-tripped by save/load, edited by the canvas.
var _data = null

## T2 (S2.2) shadow routing workspace (pcb_routing_workspace.gd). In-memory
## only this round (persistence is T2a) — built eagerly beside _data/
## _annotation_host so get_routing_workspace() is valid from construction,
## matching the _annotation_host eager-build convention below.
var _routing_workspace = null

## T2.3 cutover coordinator (pcb_routing_cutover.gd), built eagerly beside the
## workspace so get_routing_cutover() is valid from construction. Mechanism only
## this round — all surfaces annotation-authoritative until T3/T5 flip them.
var _routing_cutover = null

## The ported board canvas (custom-drawn Control child), built on mount.
var _canvas: Control = null

## Toolbar widgets (built on mount).
var _tool_buttons: Dictionary = {}   # ToolMode int -> Button
var _layer_option: OptionButton = null
## Net picker for the zone tools (epoch 6 unit 4). Lives in the sidebar under the
## canvas-tools group and is only visible while a zone tool is armed — it is that
## tool's arming state, not a persistent board control.
var _zone_net_option: OptionButton = null
## Layer picker for the zone tools (epoch 6 boundary fix). Same rules as the net
## picker beside it: sidebar, Draw section, visible only while a zone tool is
## armed, rebuilt on every arm and on board load. Its "View layer" entry is the
## resting state and means "follow the toolbar layer filter" — the behaviour that
## was the ONLY behaviour before this control existed.
var _zone_layer_option: OptionButton = null
## Width box for the Draw ▸ Trace tool (epoch 6 boundary fix). Same arming rules
## again; it starts at the board's design-rule width, which is what the tool used
## unconditionally before there was any UI for it.
var _trace_width_spin: SpinBox = null

## ── Zone re-property rows (A5) ────────────────────────────────────────────────
## Properties-section controls that EDIT THE SELECTED ZONE, as distinct from the
## two sidebar pickers above, which ARM THE TOOL that authors a NEW one. Separate
## control instances on purpose: the arming pickers carry a placeholder that means
## "not chosen yet" / "follow the view filter" — states a committed zone cannot be
## in — and sharing one widget between "what am I about to draw" and "what is this
## thing I selected" would make every rebuild of one clobber the other.
## They populate from the SAME sources (get_net_names, and the declared copper
## stack via _declared_copper_layer_choices, which the arming layer picker now
## calls too).
var _zone_prop_rows: VBoxContainer = null
var _zone_kind_row: HBoxContainer = null
var _zone_kind_value_label: Label = null
var _zone_prop_net_row: HBoxContainer = null
var _zone_prop_net_option: OptionButton = null
var _zone_prop_layer_row: HBoxContainer = null
var _zone_prop_layer_option: OptionButton = null
## WHICH zone the rows describe (""  = none). The zone twin of
## _offset_component_id, and read by the commit handlers so a selection change
## racing a dropdown cannot re-property a zone the user is no longer looking at.
var _zone_prop_zone_id: String = ""

## The selected TRACE's property row (A7, docket 019fb92f07e2) — one editable
## field, its width. Built in the same key-label + value-control shape as the
## zone rows above and shown/hidden by the same rule (exactly one selected trace,
## or it hides: with two selected there is no single width a box could show).
## A mixed component+trace+zone selection shows every half that applies, which is
## what the A5 restructure of _update_properties made possible.
var _trace_prop_rows: VBoxContainer = null
var _trace_prop_width_spin: SpinBox = null
## WHICH trace the row edits ("" = none) — the trace twin of _zone_prop_zone_id,
## for the same reason: a selection change racing a spin-box commit must not
## re-width a trace the user is no longer looking at.
var _trace_prop_trace_id: String = ""

var _board_size_label: Label = null
var _status_label: Label = null

## Responsive layout state (UI redesign round B). Modes resolve from the
## panel's OWN width via panel_layout.gd — wide/medium/narrow with hysteresis.
var _layout_mode: String = ""
var _drawer_open := false
var _sidebar: VBoxContainer = null
var _dock_parent: VBoxContainer = null
## Bottom strip slot for the annotation dock (medium/narrow — HITL note:
## 3-col wants the dock along the bottom; only wide keeps it in the sidebar).
var _bottom_dock_slot: VBoxContainer = null
var _view_menu_button: MenuButton = null
var _drawer_button: Button = null
var _export_button: Button = null

## Properties section (round C): field name -> value Label.
var _prop_labels: Dictionary = {}
var _properties_body: VBoxContainer = null
var _properties_collapse_btn: Button = null
var _properties_expanded := true

## Component-group rows (A4 stage 2). BOTH start hidden and only appear for a
## grouped component, so the Properties section on a board with no groups renders
## exactly the five rows it always did.
##   _group_row    — read-out: member count, anchor ref, locked marker.
##   _offset_row   — the editable X/Y offset of ONE member from its group anchor.
##                   Hidden for the anchor itself (it IS the origin).
var _group_row: HBoxContainer = null
var _group_value_label: Label = null
var _offset_row: HBoxContainer = null
var _offset_x_edit: LineEdit = null
var _offset_y_edit: LineEdit = null
## Which component the offset fields currently edit ("" when they are hidden).
var _offset_component_id: String = ""

## Pin Info section (WC-1 pin inspector). Hidden until a pin is selected;
## hides again on clear (canvas pin_selected({})).
var _inspect_pin_button: Button = null
## Trash-can (item 019fb92f8b83, delete half): a plain action button, NOT a
## radio tool — it never joins _tool_buttons/_toggle_tool_mode's mutual
## exclusion, it just fires _canvas._delete_selection() once. Enabled only
## while the selection is non-empty (_update_delete_button, driven off the
## canvas' selection_changed signal, the same wiring _update_status/
## _update_properties already use).
var _delete_button: Button = null
var _pin_info_section: VBoxContainer = null
var _pin_info_ref_label: Label = null
var _pin_info_value_label: Label = null
var _pin_info_members_label: Label = null

## In-panel route-flow toolbar cluster (WC-3, contract §5 — a conscious
## partial reversal of Round-B "no authoring in panel"). Buttons activate
## substrate AnnotationAuthorTools directly on the shared platform overlay;
## implementations remain ordinary AnnotationAuthorTools (see
## kinds/pcb_route_hint_kind.gd SingleTraceAuthorTool). kind_key -> Button.
var _route_flow_buttons: Dictionary = {}
var _route_flow_mode_label: Label = null
## Propose action button (C5) — a non-toggle act, NOT part of
## _route_flow_buttons' mutual-exclusion radio set.
var _propose_button: Button = null
## kind_key of the cluster's own currently-active tool, or "" when none.
var _active_route_flow_kind: String = ""
## The tool instance the cluster itself activated (used to tell apart "the
## overlay's active tool changed because another surface — e.g. the dock's
## own AnnotationToolbar — took over" from "we changed it ourselves").
var _active_route_flow_tool: AnnotationAuthorTool = null
## The mounted platform AnnotationOverlay's active_tool_changed connection
## (so mutual exclusion also covers OTHER surfaces driving the same overlay,
## e.g. the annotation dock's per-kind buttons — contract: "activation is
## mutually exclusive").
var _overlay_tool_signal_bound: Control = null

## The tool the shared overlay currently holds, tracked off active_tool_changed
## so _sync_universal_select can tell OUR passive arm from another surface's.
var _overlay_active_tool: Object = null

## View-flag table shared by the wide-mode CheckButtons and the medium/narrow
## View menu (single source of truth: the canvas flags themselves).
const _VIEW_FLAGS := [
	["Grid", "show_grid"],
	["Ratsnest", "show_ratsnest"],
	["Labels", "show_labels"],
	["Traces", "show_traces"],
	["Silk", "show_silk"],
	["Courtyard", "show_courtyard"],
	["Hint labels", "show_hint_labels"],
]
const _VIEW_MENU_EXPORT_ID := 100

## True while restoring persisted state (board load OR annotation sidecar load).
## Suppresses the content_changed dirty relay so restoring never marks the tab
## dirty (W-14; carry-in 3b extends the gate to cover board load).
var _restoring := false

## Summary of the last one-shot legacy annotation migration ({migrated, warnings}).
## Populated by _run_legacy_migration; surfaced on the status bar and exposed for
## tests/telemetry via get_last_migration_summary().
var _last_migration: Dictionary = {"migrated": 0, "warnings": []}


func _init() -> void:
	# Build the host eagerly so get_annotation_host() is valid the instant the
	# platform queries it during mount (before _on_panel_loaded fires).
	_annotation_host = _PcbAnnotationHostScript.new()
	# Annotation mutations flip the tab's unsaved glyph via content_changed
	# (gap register W-14). Gated by _restoring: load_sidecar emits the same
	# signal and restoring saved state must not mark the tab dirty.
	_annotation_host.annotations_changed.connect(func() -> void:
		if not _restoring:
			content_changed.emit())

	# T2 (S2.2): the shadow routing workspace, built eagerly alongside the
	# annotation host so get_routing_workspace() is valid immediately.
	_routing_workspace = _PcbRoutingWorkspaceScript.new()

	# T2.3: the cutover coordinator, built eagerly beside the workspace. Every
	# surface defaults annotation-authoritative — nothing is cut over in T2.3.
	_routing_cutover = _PcbRoutingCutoverScript.new()

	# Build the board model and seed the default board WITHOUT dirtying the tab
	# (from_board_dict emits data_changed; gate it).
	_data = _PcbDataScript.new()
	_restoring = true
	_data.from_board_dict(_DEFAULT_BOARD.duplicate(true))
	_restoring = false
	# Carry-in 3b: relay model data_changed → content_changed (dirty glyph),
	# gated by _restoring so board load / seeding never dirties the tab.
	_data.data_changed.connect(func() -> void:
		if not _restoring:
			content_changed.emit())


func get_annotation_host() -> RefCounted:
	return _annotation_host


## Where the platform annotation overlay must mount (Editor.gd duck-types this).
## The host's view transform maps board-mm to CANVAS-local pixels, so the
## overlay has to share the canvas origin — parenting it to the whole panel
## would offset every pointer hit and rendered annotation by the toolbar row
## (see the warning at the canvas mount in _build_ui). Falls back to the panel
## when the canvas isn't built yet.
func get_annotation_overlay_parent() -> Control:
	if _canvas != null and is_instance_valid(_canvas):
		return _canvas
	return self


## The board model (pcb_data.gd) this panel edits. Exposed for MCP/tests.
func get_data():
	return _data


## T2 (S2.2): the shadow routing workspace (pcb_routing_workspace.gd), dual-
## written on every propose alongside the annotation proposals. Exposed for
## MCP/tests; not yet the UI's source of truth for anything (that lands in
## later tasks — see the file-level docstring).
func get_routing_workspace():
	return _routing_workspace


## T2.3: the cutover coordinator (pcb_routing_cutover.gd). Exposed for MCP/tests
## and the surfaces that will consult it once cutover begins (T3/T5). In T2.3 it
## reports every surface annotation-authoritative.
func get_routing_cutover():
	return _routing_cutover


## Panel-executed MCP tool entry point (DCR 019f6c3d0e3d contract §2
## plugin-side convention; wave 1 C2 round docket 019f6c45f09e, wave 2 + core
## deletion C3 round docket 019f6c4604ba). PluginToolRegistry has already
## resolved args.editor_name -> this panel and verified ownership before
## calling here; panel_tools.gd owns EVERY tool body (moved verbatim from
## Minerva core's now-deleted MCPPcbPanelTools.gd — waves 1 and 2). An
## unrecognised tool_name returns {} so the dispatcher maps it to the
## structured tool_unhandled error.
##
## Always awaited: minerva_pcb_apply_route_hints awaits the router worker
## bridge, which makes panel_tools.gd's handle() a coroutine as a whole
## (Godot 4.6 landmine — once any branch awaits, the whole function is a
## coroutine). Awaiting unconditionally here is correct for every tool, sync
## or async: awaiting an already-resolved coroutine call is a no-op wait. The
## PluginToolRegistry dispatcher already awaits THIS call end-to-end (C1
## scenario E proved it).
func handle_tool(tool_name: String, args: Dictionary) -> Dictionary:
	return await _PanelToolsScript.handle(_annotation_host, tool_name, args)


# ── Mount / unmount ───────────────────────────────────────────────────────────

func _on_panel_loaded(ctx: Dictionary) -> void:
	_build_ui()

	# Register the host under the editor tab title so MCP annotation tools
	# (minerva_annotations_query / _render_overlay) can reach it by editor_name.
	var ed: Variant = ctx.get("editor", null)
	if ed != null and "tab_title" in ed and _annotation_host != null:
		var ed_name: String = str(ed.tab_title)
		if not ed_name.is_empty():
			AnnotationHostRegistry.register(ed_name, _annotation_host)
			_registered_editor_name = ed_name

	# Capture the file path (for sidecar resolution).
	_file_path = str(ctx.get("file_path", ""))
	if not _file_path.is_empty() and _annotation_host != null:
		_annotation_host.set_document_path(_file_path)

	# Reflect whatever board is currently loaded.
	_refresh_board_ui()
	_zoom_to_fit_deferred()


func _on_panel_unload() -> void:
	# Unbind the canvas so the host drops its signal connections before the
	# canvas is freed (symmetric with set_canvas in _build_ui).
	if _annotation_host != null and _annotation_host.has_method("set_canvas"):
		_annotation_host.set_canvas(null)
	# Release the passively-armed universal Select before the overlay goes with
	# the panel (B1u3) — symmetric with the arming in _sync_universal_select.
	if _annotation_host != null and _annotation_host.has_method("arm_universal_select"):
		_annotation_host.arm_universal_select(null, false)
	if _registered_editor_name != "":
		AnnotationHostRegistry.deregister(_registered_editor_name)
		_registered_editor_name = ""


# ── UI construction ───────────────────────────────────────────────────────────

## Build the toolbar and one framed workspace. The host gives panels the full
## rect; the workspace frame owns the canvas/sidebar, bottom dock, and status so
## those rows read as one surface instead of floating below the canvas border.
func _build_ui() -> void:
	var main_vbox := VBoxContainer.new()
	main_vbox.name = "MainVBox"
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_vbox)

	# Toolbar inside a horizontal scroll for overflow.
	var toolbar_scroll := ScrollContainer.new()
	toolbar_scroll.name = "ToolbarScroll"
	toolbar_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	toolbar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	toolbar_scroll.custom_minimum_size.y = 38
	main_vbox.add_child(toolbar_scroll)
	toolbar_scroll.add_child(_build_toolbar())

	# One visual boundary owns the complete workspace below the toolbar. The
	# previous CanvasContainer frame ended above BottomDockSlot + StatusBar,
	# which made those rows look as though they overflowed the editor even though
	# every control was correctly inside the panel's allocated rect.
	var workspace_frame := PanelContainer.new()
	workspace_frame.name = "WorkspaceFrame"
	workspace_frame.clip_contents = true
	workspace_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(workspace_frame)

	var workspace_vbox := VBoxContainer.new()
	workspace_vbox.name = "WorkspaceVBox"
	workspace_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace_frame.add_child(workspace_vbox)

	# Content row: canvas (majority share) + right sidebar (legacy layout clone).
	var content_hbox := HBoxContainer.new()
	content_hbox.name = "ContentHBox"
	content_hbox.clip_contents = true
	content_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace_vbox.add_child(content_hbox)

	# Canvas fills the middle. Its container clips but draws no second panel
	# frame; WorkspaceFrame above is the single visual boundary.
	var canvas_container := MarginContainer.new()
	canvas_container.name = "CanvasContainer"
	canvas_container.clip_contents = true
	canvas_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_hbox.add_child(canvas_container)

	_canvas = _PcbCanvasScript.new()
	_canvas.name = "PCBCanvas"
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# If an on-screen AnnotationOverlay is ever mounted here, it MUST be a child
	# of _canvas (same origin) — NOT canvas_container: the host's view transform
	# maps board-mm to canvas-LOCAL pixels and every marker must share that exact
	# local coordinate space.
	canvas_container.add_child(_canvas)
	_canvas.set_data(_data)

	# Bind the annotation host to the live canvas so route-hint markers track
	# board coordinates through zoom/pan and describe_point can read the board
	# model (gap register W-9). Duck-typed: a host without set_canvas simply
	# stays on identity transforms.
	if _annotation_host != null and _annotation_host.has_method("set_canvas"):
		_annotation_host.set_canvas(_canvas)
	if _annotation_host != null and _annotation_host.has_method("set_panel"):
		_annotation_host.set_panel(self)
	# WC-1 pin inspector: the canvas hit-tests through the host's pad_at/pin_info
	# (single source of truth — see PcbAnnotationHost.gd), never duplicating the
	# lookup locally.
	if _annotation_host != null and _canvas.has_method("set_pin_inspector_host"):
		_canvas.set_pin_inspector_host(_annotation_host)
	# UNIVERSAL SELECT (B1u3): the canvas owns the click for BOTH halves of the
	# selection and asks the host for the annotation half. Same duck-typed
	# handshake as the two bindings above.
	if _annotation_host != null and _canvas.has_method("set_annotation_router"):
		_canvas.set_annotation_router(_annotation_host)
	# The platform mounts its AnnotationOverlay as a CHILD of this canvas, some
	# frames after the panel is built (Editor.gd). Arming the universal Select
	# needs that overlay to exist, so we watch for it arriving rather than
	# guessing a frame — and _sync_universal_select is idempotent, so a canvas
	# that gains other children costs one cheap re-check each.
	if not _canvas.child_entered_tree.is_connected(_on_canvas_child_entered):
		_canvas.child_entered_tree.connect(_on_canvas_child_entered)

	# Canvas → panel signal wiring.
	_canvas.tool_mode_changed.connect(_on_tool_mode_changed)
	_canvas.component_selected.connect(func(_id: String) -> void:
		_update_status(); _update_properties())
	_canvas.selection_changed.connect(func() -> void:
		_update_status(); _update_properties(); _update_delete_button())
	_canvas.component_lock_changed.connect(_on_component_lock_changed)
	_canvas.zoom_changed.connect(func(_z: float) -> void: _update_status())
	_canvas.pin_selected.connect(_on_pin_selected)
	_canvas.zone_tool_message.connect(_show_transient_status)
	_canvas.trace_tool_message.connect(_show_transient_status)

	# Right sidebar (legacy layout clone): tool buttons + the platform
	# annotation dock (mounted by Minerva via get_annotation_dock_parent).
	content_hbox.add_child(_build_sidebar())

	# Bottom dock strip: the annotation dock lives HERE in medium/narrow
	# (full panel width under the canvas — HITL note 2026-07-13) and moves
	# into the sidebar slot only in wide mode. Whichever slot the dock pane
	# lands in, _sync_dock_pane_mode re-asserts the pane's internal
	# RIGHT/BOTTOM arrangement (deferred: the platform mount sets RIGHT after
	# parenting, so a same-frame correction would be overwritten).
	_bottom_dock_slot = VBoxContainer.new()
	_bottom_dock_slot.name = "BottomDockSlot"
	_bottom_dock_slot.size_flags_vertical = Control.SIZE_SHRINK_END
	workspace_vbox.add_child(_bottom_dock_slot)
	_bottom_dock_slot.child_entered_tree.connect(func(_n: Node) -> void:
		call_deferred("_sync_dock_pane_mode"))
	if _dock_parent != null:
		_dock_parent.child_entered_tree.connect(func(_n: Node) -> void:
			call_deferred("_sync_dock_pane_mode"))

	# Model → toolbar (board size label) refresh.
	_data.structure_changed.connect(_update_board_size_label)

	# Status bar. TRIM_ELLIPSIS is load-bearing, not cosmetic: an unclipped
	# Label's MINIMUM width is its full text width, and this label carries the
	# armed-tool gesture hint (933px measured at medium) — without overrun
	# handling it inflates the whole WorkspaceVBox→MainVBox chain past the
	# pane and drags every stretch-width row off-screen (bug: the pane clips,
	# nothing scrolls; hint pcb-plugin/label-min-width-inflates-panel). The
	# full untruncated text is mirrored into the tooltip by _set_status.
	_status_label = Label.new()
	_status_label.name = "StatusBar"
	_status_label.custom_minimum_size.y = 22
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.mouse_filter = Control.MOUSE_FILTER_PASS
	workspace_vbox.add_child(_status_label)

	# Smart Select is the resting tool (finding 5) — engaged by default so the
	# canvas is immediately click-to-select/drag-to-move without a mode hunt.
	_canvas.set_tool_mode(_PcbCanvasScript.ToolMode.SELECT)

	_update_board_size_label()
	_update_status()

	# Responsive layout: modes resolve from the panel's OWN width (Minerva's
	# 1/2/3-column layouts are all just widths from in here).
	if not resized.is_connected(_on_panel_resized):
		resized.connect(_on_panel_resized)
	_apply_layout_mode(_PanelLayoutScript.mode_for_width(size.x), true)


func _build_toolbar() -> HBoxContainer:
	var tb := HBoxContainer.new()
	tb.name = "Toolbar"
	tb.custom_minimum_size.y = 34

	# Narrow-mode drawer toggle (hidden outside narrow): slides the sidebar in
	# over a squeezed 3-col panel where it can't be permanently visible.
	_drawer_button = Button.new()
	_drawer_button.name = "SidebarDrawerButton"
	_drawer_button.text = "☰"
	_drawer_button.tooltip_text = _wrap_tooltip("Show/hide the tools sidebar")
	_drawer_button.toggle_mode = true
	_drawer_button.visible = false
	_drawer_button.pressed.connect(_on_drawer_toggled)
	tb.add_child(_drawer_button)

	# Zoom controls.
	var zoom_out := Button.new()
	zoom_out.text = "−"  # minus sign
	zoom_out.tooltip_text = _wrap_tooltip("Zoom out (-)")
	zoom_out.pressed.connect(func() -> void: _canvas._zoom_at(_canvas.size / 2, 0.8))
	tb.add_child(zoom_out)

	var zoom_fit := Button.new()
	var fit_icon := _load_icon("zoom_fit_24.png")
	if fit_icon != null:
		zoom_fit.icon = fit_icon
	else:
		zoom_fit.text = "Fit"
	zoom_fit.tooltip_text = _wrap_tooltip("Zoom to fit")
	zoom_fit.pressed.connect(func() -> void: _canvas.zoom_to_fit())
	tb.add_child(zoom_fit)

	var zoom_in := Button.new()
	zoom_in.text = "+"
	zoom_in.tooltip_text = _wrap_tooltip("Zoom in (+)")
	zoom_in.pressed.connect(func() -> void: _canvas._zoom_at(_canvas.size / 2, 1.2))
	tb.add_child(zoom_in)

	tb.add_child(VSeparator.new())

	# The compact View menu is the ONE view-flags surface at every width
	# (owner ruling 2026-08-01, bug 019fbb6242): the former wide-mode inline
	# CheckButton row overflowed the toolbar at every width in ~[880, 1250]
	# because the WIDE threshold was calibrated when the flag list was five
	# entries long and the list grew to seven. The menu carries every flag as
	# a checkable item, synced from the canvas each time it opens, plus
	# Export YAML (the inline Export button hides at narrow).
	_view_menu_button = MenuButton.new()
	_view_menu_button.name = "ViewMenuButton"
	_view_menu_button.text = "View"
	var popup := _view_menu_button.get_popup()
	for i in _VIEW_FLAGS.size():
		popup.add_check_item(_VIEW_FLAGS[i][0], i)
	popup.add_separator()
	popup.add_item("Export YAML…", _VIEW_MENU_EXPORT_ID)
	popup.about_to_popup.connect(_sync_view_menu_checks)
	popup.id_pressed.connect(_on_view_menu_id_pressed)
	tb.add_child(_view_menu_button)

	tb.add_child(VSeparator.new())

	# Layer selector (drives the canvas trace-layer filter).
	var layer_label := Label.new()
	layer_label.text = "Layer:"
	tb.add_child(layer_label)

	_layer_option = OptionButton.new()
	_layer_option.name = "LayerOption"
	_rebuild_layer_option()
	_layer_option.item_selected.connect(_on_layer_selected)
	tb.add_child(_layer_option)

	tb.add_child(VSeparator.new())

	# YAML export (routes through the Go pcb.serialize channel).
	_export_button = Button.new()
	_export_button.name = "ExportButton"
	_export_button.text = "Export YAML"
	_export_button.tooltip_text = _wrap_tooltip("Export YAML — serialize the board via the plugin backend")
	_export_button.pressed.connect(_on_export_yaml_pressed)
	tb.add_child(_export_button)

	# Spacer + board size label.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tb.add_child(spacer)

	_board_size_label = Label.new()
	_board_size_label.name = "BoardSizeLabel"
	tb.add_child(_board_size_label)

	return tb


## Shared tooltip-wrap mechanism (docket 019fb933d4a9, tooltip overflow fix).
## Godot's default tooltip popup sizes itself to raw tooltip_text with NO
## word-wrap, so anything past a few dozen characters runs off the edge of
## the screen instead of wrapping — there is no engine flag for this. The
## standard trick is to insert our OWN line breaks at word boundaries before
## the text ever reaches tooltip_text; the default tooltip Label honors "\n"
## exactly like any other Label, so no custom Control or _make_custom_tooltip
## override is needed (least invasive, and verifiable by inspecting this
## function's own output — no live app required).
##
## EVERY tooltip_text assignment in this file routes through this function,
## even short ones that are already under the wrap width — that is what makes
## this a MECHANISM rather than a one-off patch: the next tooltip anyone adds
## here, short or long, wraps automatically as long as it is assigned through
## this function too.
const _TOOLTIP_WRAP_CHARS := 60

static func _wrap_tooltip(text: String, max_chars: int = _TOOLTIP_WRAP_CHARS) -> String:
	if text.length() <= max_chars:
		return text
	var lines: PackedStringArray = []
	var current := ""
	for word in text.split(" "):
		if current.is_empty():
			current = word
		elif current.length() + 1 + word.length() <= max_chars:
			current += " " + word
		else:
			lines.append(current)
			current = word
	if not current.is_empty():
		lines.append(current)
	return "\n".join(lines)


func _add_tool_button(tb: Container, mode: int, text: String, tip: String, icon_file := "") -> void:
	var btn := Button.new()
	var icon := _load_icon(icon_file) if not icon_file.is_empty() else null
	if icon != null:
		# Icon-only (legacy look, and the narrow-column width saver); the
		# name stays discoverable via the tooltip.
		btn.icon = icon
	else:
		btn.text = text
	btn.tooltip_text = _wrap_tooltip(tip)
	btn.toggle_mode = true
	btn.pressed.connect(func() -> void: _toggle_tool_mode(mode))
	tb.add_child(btn)
	_tool_buttons[mode] = btn


## Sidebar section label — the 11px caption idiom shared by all three tool
## groups. Named "<text>GroupLabel" (e.g. ProposalsGroupLabel; a repo-wide grep
## 2026-08-01 found NO name lookups, so renaming a section is a text-only change)
## keep resolving.
func _add_group_label(text: String) -> void:
	var group_label := Label.new()
	group_label.name = text + "GroupLabel"
	group_label.text = text
	group_label.add_theme_font_size_override("font_size", 11)
	_sidebar.add_child(group_label)


## Loads an icon from the plugin's own assets dir (next to this script).
## Plugins live OUTSIDE res://, so preload() can't reach the PNGs — resolve the
## script's directory and load from the filesystem. Fail-safe: any miss returns
## null and callers fall back to a text button (never a blank one).
func _load_icon(fname: String) -> Texture2D:
	var script_ref: Script = get_script() as Script
	if script_ref == null or script_ref.resource_path.is_empty():
		return null
	var dir := script_ref.resource_path.get_base_dir()
	var path := ProjectSettings.globalize_path(dir.path_join("assets/icons").path_join(fname))
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


# ── Right sidebar (legacy layout clone) ────────────────────────────────────────

## Tools live in a wrap-capable flow (legacy FlowContainer pattern: buttons wrap
## to more rows as the column narrows instead of overflowing), followed by the
## mount point for the platform annotation dock (Tools/Annotate/list — round A
## hook), which fills the remaining height.
func _build_sidebar() -> VBoxContainer:
	_sidebar = VBoxContainer.new()
	_sidebar.name = "RightSidebar"
	_sidebar.custom_minimum_size.x = 120
	_sidebar.size_flags_vertical = Control.SIZE_EXPAND_FILL

	## Three labeled tool sections (docket 019fb5624e2e; sectioning corrected
	## per boundary bug 019fb5c74980): Select (navigation/inspection), Draw
	## (tools that author board entities), Hints (route-hint authoring for the
	## router). Each section is an 11px label ABOVE its flow so the label
	## unambiguously captions the group below it; HSeparator between sections.
	_add_group_label("Select")
	var tools_flow := FlowContainer.new()
	tools_flow.name = "ToolsFlow"
	_sidebar.add_child(tools_flow)

	# ONE smart Select tool + a Pan tool (Photoshop / GraphicsEditor style,
	# finding 5). Select does select + move + box-select + rotate; Pan drags
	# the whole view.
	_add_tool_button(tools_flow, _PcbCanvasScript.ToolMode.SELECT, "Select",
		"Select & move (S) — click to select, drag to move",
		"select_24.png")
	_add_tool_button(tools_flow, _PcbCanvasScript.ToolMode.PAN, "Pan",
		"Pan the view (drag anywhere)",
		"pan_24.png")

	# Pin inspector (WC-1) — a TRUE toggle (unlike the Select/Pan radio tools):
	# pressed arms INSPECT_PIN, pressed-again exits back to Select.
	_inspect_pin_button = Button.new()
	_inspect_pin_button.name = "InspectPinButton"
	var inspect_icon := _load_icon("inspect_pin_24.png")
	if inspect_icon != null:
		_inspect_pin_button.icon = inspect_icon
	else:
		_inspect_pin_button.text = "Pin"
	_inspect_pin_button.tooltip_text = _wrap_tooltip("Click a pin to see its info (Shift+P)")
	_inspect_pin_button.toggle_mode = true
	_inspect_pin_button.pressed.connect(_on_inspect_pin_button_pressed)
	tools_flow.add_child(_inspect_pin_button)
	_tool_buttons[_PcbCanvasScript.ToolMode.INSPECT_PIN] = _inspect_pin_button

	# Draw section (epoch 6 units 4+5; own section per boundary bug
	# 019fb5c74980): these tools author board ENTITIES — zones and traces that
	# serialize into the board YAML — a different altitude from the Select
	# tools above (which touch nothing) and the router Hints below (which
	# request copper rather than draw it). Two zone buttons rather than one
	# moded tool — the radio idiom _add_tool_button provides is exactly "one
	# of these is active".
	_sidebar.add_child(HSeparator.new())
	_add_group_label("Tools")
	var draw_flow := FlowContainer.new()
	draw_flow.name = "DrawFlow"
	_sidebar.add_child(draw_flow)

	_add_tool_button(draw_flow, _PcbCanvasScript.ToolMode.ZONE_POUR, "Pour",
		"Draw a copper pour (pick a net, click corners, Enter to close)", "pour_24.png")
	_add_tool_button(draw_flow, _PcbCanvasScript.ToolMode.ZONE_KEEPOUT, "Keepout",
		"Draw a keep-out region (click corners, Enter to close)", "keepout_24.png")

	# Trace drawing tool (epoch 6 unit 5). Same section and same reason as the
	# zone tools above: it authors a board ENTITY. It shares a name with the
	# Proposals-group Trace button below and that is deliberate — they draw the
	# same thing at two different altitudes — so the icon (solid pads vs the
	# hint's hollow ones) and tooltip carry the distinction outright: this one
	# IS the copper, that one is a request for copper.
	_add_tool_button(draw_flow, _PcbCanvasScript.ToolMode.TRACE, "Trace",
		"Draw copper directly (click a pad to start)", "trace_draw_24.png")

	# Eraser (item 019fb934827776) + Delete/trash-can (item 019fb92f8b83) live
	# HERE, not in the Select section above (cold-review N3) — the section
	# comment's own taxonomy draws the line at "the Select tools above ...
	# touch nothing"; Eraser and Delete both mutate the board's entity list
	# (they are Draw's destructive twin — Draw adds entities, these remove
	# them), the same altitude as Pour/Keepout/Trace, not Select/Pan's
	# navigate-only altitude. The exclusion wiring is untouched: Eraser is
	# still just another _add_tool_button -> _toggle_tool_mode radio tool, and
	# Delete is still the same plain action button, both merely relocated to
	# this flow.
	_add_tool_button(draw_flow, _PcbCanvasScript.ToolMode.ERASER, "Eraser",
		"Click an entity to delete it (Esc to disarm)", "eraser_24.png")

	_delete_button = Button.new()
	_delete_button.name = "DeleteSelectionButton"
	# Icon with text fallback, same contract as _add_tool_button: a missing
	# asset yields a text button, never a blank one.
	var trash_icon := _load_icon("trash_24.png")
	if trash_icon != null:
		_delete_button.icon = trash_icon
	else:
		_delete_button.text = "Delete"
	_delete_button.tooltip_text = _wrap_tooltip("Delete the whole selection (Delete/Backspace)")
	_delete_button.disabled = true
	_delete_button.pressed.connect(func() -> void: _canvas._delete_selection())
	draw_flow.add_child(_delete_button)

	# The Draw tools' arming controls. Each is shown only while the tool it arms
	# is active, so the resting sidebar is unchanged.
	_zone_net_option = OptionButton.new()
	_zone_net_option.name = "ZoneNetOption"
	_zone_net_option.tooltip_text = _wrap_tooltip("Net for the pour being drawn")
	_zone_net_option.visible = false
	_rebuild_zone_net_option()
	_zone_net_option.item_selected.connect(_on_zone_net_selected)
	_sidebar.add_child(_zone_net_option)

	_zone_layer_option = OptionButton.new()
	_zone_layer_option.name = "ZoneLayerOption"
	_zone_layer_option.tooltip_text = _wrap_tooltip("Copper layer for the zone being drawn")
	_zone_layer_option.visible = false
	_rebuild_zone_layer_option()
	_zone_layer_option.item_selected.connect(_on_zone_layer_selected)
	_sidebar.add_child(_zone_layer_option)

	# Trace width. A SpinBox rather than a picker because width is continuous —
	# there is no list of legal widths to choose from, only the board's design
	# rule as a starting point. Bounds are sanity rails, not fabrication rules —
	# stated once, on the entity that has a width (pcb_trace.MIN/MAX_WIDTH_MM),
	# and shared with the model setter and the preference registry since A7.
	_trace_width_spin = SpinBox.new()
	_trace_width_spin.name = "TraceWidthSpin"
	_trace_width_spin.tooltip_text = _wrap_tooltip("Width of new traces, in mm (design-rule default)")
	_trace_width_spin.min_value = _PcbTraceScript.MIN_WIDTH_MM
	_trace_width_spin.max_value = _PcbTraceScript.MAX_WIDTH_MM
	_trace_width_spin.step = 0.05
	_trace_width_spin.suffix = "mm"
	_trace_width_spin.visible = false
	_trace_width_spin.value_changed.connect(_on_trace_width_changed)
	_sidebar.add_child(_trace_width_spin)

	_sidebar.add_child(HSeparator.new())
	_add_group_label("Proposals")

	var hints_flow := FlowContainer.new()
	hints_flow.name = "HintsFlow"
	_sidebar.add_child(hints_flow)

	# Route-flow toolbar cluster (WC-3, contract §5): a TRUE toggle per route
	# author tool, same idiom as the pin inspector button above. Only
	# single-trace this round; WC-4 adds a "Bus" button beside it into the
	# same _route_flow_buttons table (mutual exclusion is already generic).
	var trace_btn := Button.new()
	trace_btn.name = "SingleTraceButton"
	var trace_icon := _load_icon("trace_24.png")
	if trace_icon != null:
		trace_btn.icon = trace_icon
	else:
		trace_btn.text = "Trace"
	trace_btn.tooltip_text = _wrap_tooltip("Draw a single-trace route hint (click pad, waypoints, pad)")
	trace_btn.toggle_mode = true
	trace_btn.pressed.connect(_on_single_trace_button_pressed)
	hints_flow.add_child(trace_btn)
	_route_flow_buttons["single_trace"] = trace_btn

	# Bend-handle editing tool (C4, docket 019f6c464ff0): select a committed
	# route hint, then drag/right-click/click its bend points to edit them.
	# Same TRUE-toggle idiom as the Trace button; shares mutual exclusion
	# with the rest of the cluster (and the canvas tool surface) for free —
	# see _activate_route_flow_tool.
	var edit_hint_btn := Button.new()
	edit_hint_btn.name = "EditHintButton"
	var edit_hint_icon := _load_icon("waypoint_24.png")
	if edit_hint_icon != null:
		edit_hint_btn.icon = edit_hint_icon
	else:
		edit_hint_btn.text = "Edit Hint"
	edit_hint_btn.tooltip_text = _wrap_tooltip("Edit a route hint's bend points")
	edit_hint_btn.toggle_mode = true
	edit_hint_btn.pressed.connect(_on_edit_hint_button_pressed)
	hints_flow.add_child(edit_hint_btn)
	_route_flow_buttons["edit_hint"] = edit_hint_btn

	# Manual via-insertion tool (U4, DCR 019f7095c395 Stage-2): select a
	# proposal, then click a point on its route to split the segment, add a
	# via, and flip the following run to the opposite copper layer. Same
	# TRUE-toggle idiom as Trace/Edit Hint above; shares mutual exclusion with
	# the rest of the cluster via _route_flow_buttons for free.
	var add_via_btn := Button.new()
	add_via_btn.name = "AddViaButton"
	var add_via_icon := _load_icon("via_24.png")
	if add_via_icon != null:
		add_via_btn.icon = add_via_icon
	else:
		add_via_btn.text = "Add Via"
	add_via_btn.tooltip_text = _wrap_tooltip("Insert a via on a selected proposal")
	add_via_btn.toggle_mode = true
	add_via_btn.pressed.connect(_on_add_via_button_pressed)
	hints_flow.add_child(add_via_btn)
	_route_flow_buttons["add_via"] = add_via_btn

	# Propose button (C5, docket 019f6c465fd8, deliverable 1): explicit-propose
	# UX — the router NEVER runs implicitly (product contract v2). This is a
	# non-toggle ACT button (not part of _route_flow_buttons' mutual-exclusion
	# radio set — it fires once and returns, it doesn't arm a drawing tool),
	# sitting beside the toggle tools for discoverability. Runs the SAME code
	# path as the panel tool minerva_pcb_apply_route_hints with commit=false —
	# see _on_propose_button_pressed.
	_propose_button = Button.new()
	_propose_button.name = "ProposeButton"
	var propose_icon := _load_icon("trace_icon_1_24.png")
	if propose_icon != null:
		_propose_button.icon = propose_icon
	else:
		_propose_button.text = "Propose"
	_propose_button.tooltip_text = _wrap_tooltip("Run the router over open route hints (board unchanged)")
	_propose_button.pressed.connect(_on_propose_button_pressed)
	hints_flow.add_child(_propose_button)

	# RouteFlowModeLabel removed (owner HITL 2026-07-30): its idle text
	# "Select" read as a duplicate section header under the real ones, and the
	# pressed state of the toggle buttons already shows the armed tool.
	# _route_flow_mode_label stays null; _update_route_flow_mode_label is
	# null-guarded, so every update site is a safe no-op.

	_sidebar.add_child(HSeparator.new())

	# Platform annotation dock mounts here (Editor duck-types
	# get_annotation_dock_parent — round A). Fills the remaining column.
	_dock_parent = VBoxContainer.new()
	_dock_parent.name = "AnnotationDockParent"
	_dock_parent.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sidebar.add_child(_dock_parent)

	_sidebar.add_child(HSeparator.new())
	_sidebar.add_child(_build_properties_section())

	_sidebar.add_child(HSeparator.new())
	_sidebar.add_child(_build_pin_info_section())

	return _sidebar


## Properties section (legacy clone): ID / Position / Rotation / Layer /
## Footprint of the single-selected component. Collapsible — wide mode expands
## it by default, medium collapses it (3-col width is precious); the selection
## summary also mirrors into the status bar either way.
func _build_properties_section() -> VBoxContainer:
	var section := VBoxContainer.new()
	section.name = "PropertiesSection"

	_properties_collapse_btn = Button.new()
	_properties_collapse_btn.name = "PropertiesHeader"
	_properties_collapse_btn.text = "Properties"
	_properties_collapse_btn.flat = true
	_properties_collapse_btn.toggle_mode = true
	_properties_collapse_btn.pressed.connect(func() -> void:
		_set_properties_expanded(not _properties_expanded))
	section.add_child(_properties_collapse_btn)

	_properties_body = VBoxContainer.new()
	_properties_body.name = "PropertiesBody"
	section.add_child(_properties_body)

	for field in ["ID", "Position", "Rotation", "Layer", "Footprint"]:
		var row := HBoxContainer.new()
		var key_label := Label.new()
		key_label.text = "%s:" % field
		key_label.custom_minimum_size.x = 60
		row.add_child(key_label)
		var value_label := Label.new()
		value_label.text = "-"
		value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		value_label.clip_text = true
		row.add_child(value_label)
		_prop_labels[field] = value_label
		_properties_body.add_child(row)

	_properties_body.add_child(_build_group_rows())
	_properties_body.add_child(_build_zone_rows())
	_properties_body.add_child(_build_trace_rows())
	return section


## The two component-group rows (A4 stage 2), built in the SAME key-label +
## value-control shape as the five rows above so the section reads as one thing.
##
## The offset fields are the panel's first EDITABLE property control; everything
## above them is a read-out. They commit on Enter (text_submitted) and on losing
## focus, and a refused or malformed edit snaps straight back to the model's
## value — the model, not the field, is what an offset IS.
func _build_group_rows() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "GroupRows"

	_group_row = HBoxContainer.new()
	_group_row.name = "GroupRow"
	_group_row.visible = false
	var group_key := Label.new()
	group_key.text = "Group:"
	group_key.custom_minimum_size.x = 60
	_group_row.add_child(group_key)
	_group_value_label = Label.new()
	_group_value_label.name = "GroupValue"
	_group_value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_group_value_label.clip_text = true
	_group_row.add_child(_group_value_label)
	box.add_child(_group_row)

	_offset_row = HBoxContainer.new()
	_offset_row.name = "OffsetRow"
	_offset_row.visible = false
	var offset_key := Label.new()
	offset_key.text = "Offset:"
	offset_key.custom_minimum_size.x = 60
	_offset_row.add_child(offset_key)
	_offset_x_edit = _build_offset_edit("OffsetX", "X mm")
	_offset_row.add_child(_offset_x_edit)
	_offset_y_edit = _build_offset_edit("OffsetY", "Y mm")
	_offset_row.add_child(_offset_y_edit)
	box.add_child(_offset_row)

	return box


func _build_offset_edit(edit_name: String, hint: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.name = edit_name
	edit.placeholder_text = hint
	edit.tooltip_text = _wrap_tooltip("%s offset from the group anchor, in mm" % hint)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size.x = 48
	edit.text_submitted.connect(func(_t: String) -> void: _commit_member_offset())
	edit.focus_exited.connect(_commit_member_offset)
	return edit


## The selected zone's property rows (A5), built in the SAME key-label +
## value-control shape as the component rows above and the group rows beside them,
## so the section still reads as one thing whichever kind is selected.
##
## KIND is a read-out, not a control. A pour and a keepout are different entities
## with different rules (a pour must name a net; a keepout must not carry one
## here), and "turn this pour into a keepout" is an authoring decision, not a
## property tweak — offering it as a dropdown would quietly strip a net.
##
## The NET row is POURS ONLY, hidden (not merely disabled) for a keepout — the
## exact rule, and the exact reasoning, the arming picker already follows: a
## visible control is a request for input, and asking for a net the model will
## refuse is the UI lying about the contract.
func _build_zone_rows() -> VBoxContainer:
	_zone_prop_rows = VBoxContainer.new()
	_zone_prop_rows.name = "ZoneRows"
	_zone_prop_rows.visible = false

	_zone_kind_row = HBoxContainer.new()
	_zone_kind_row.name = "ZoneKindRow"
	var kind_key := Label.new()
	kind_key.text = "Zone:"
	kind_key.custom_minimum_size.x = 60
	_zone_kind_row.add_child(kind_key)
	_zone_kind_value_label = Label.new()
	_zone_kind_value_label.name = "ZoneKindValue"
	_zone_kind_value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_kind_value_label.clip_text = true
	_zone_kind_row.add_child(_zone_kind_value_label)
	_zone_prop_rows.add_child(_zone_kind_row)

	_zone_prop_net_row = HBoxContainer.new()
	_zone_prop_net_row.name = "ZoneNetRow"
	var net_key := Label.new()
	net_key.text = "Net:"
	net_key.custom_minimum_size.x = 60
	_zone_prop_net_row.add_child(net_key)
	_zone_prop_net_option = OptionButton.new()
	_zone_prop_net_option.name = "ZonePropNetOption"
	_zone_prop_net_option.tooltip_text = _wrap_tooltip("Net this pour is tied to (declared nets only)")
	_zone_prop_net_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_prop_net_option.clip_text = true
	_zone_prop_net_option.item_selected.connect(_on_zone_prop_net_selected)
	_zone_prop_net_row.add_child(_zone_prop_net_option)
	_zone_prop_rows.add_child(_zone_prop_net_row)

	_zone_prop_layer_row = HBoxContainer.new()
	_zone_prop_layer_row.name = "ZoneLayerRow"
	var layer_key := Label.new()
	layer_key.text = "Layer:"
	layer_key.custom_minimum_size.x = 60
	_zone_prop_layer_row.add_child(layer_key)
	_zone_prop_layer_option = OptionButton.new()
	_zone_prop_layer_option.name = "ZonePropLayerOption"
	_zone_prop_layer_option.tooltip_text = _wrap_tooltip("Copper layer this zone sits on (declared stack only)")
	_zone_prop_layer_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_prop_layer_option.clip_text = true
	_zone_prop_layer_option.item_selected.connect(_on_zone_prop_layer_selected)
	_zone_prop_layer_row.add_child(_zone_prop_layer_option)
	_zone_prop_rows.add_child(_zone_prop_layer_row)

	return _zone_prop_rows


func _set_properties_expanded(expanded: bool) -> void:
	_properties_expanded = expanded
	if _properties_body != null:
		_properties_body.visible = expanded
	if _properties_collapse_btn != null:
		_properties_collapse_btn.button_pressed = expanded
		_properties_collapse_btn.text = "Properties" if expanded else "Properties…"


## MEASURED RESTRUCTURE (A5): this used to BLANK AND RETURN whenever no component
## was focused, so a zone-only selection could never reach any property row at
## all — the zone rows would have been dead UI. The component half is byte-for-byte
## what it was, only moved into an else-branch, and the zone half now runs on every
## update regardless of what the component half decided. Nothing about a
## component-only or empty selection changed.
func _update_properties() -> void:
	if _prop_labels.is_empty() or _canvas == null or _data == null:
		return
	var comp = _property_focus_component()
	if comp == null:
		for key in _prop_labels:
			(_prop_labels[key] as Label).text = "-"
		_hide_group_rows()
	else:
		_update_group_rows(comp)
		(_prop_labels["ID"] as Label).text = str(comp.id)
		(_prop_labels["Position"] as Label).text = "(%.1f, %.1f)" % [comp.position.x, comp.position.y]
		(_prop_labels["Rotation"] as Label).text = "%.0f°" % float(comp.rotation)
		(_prop_labels["Layer"] as Label).text = str(comp.layer)
		var fp := str(comp.footprint_id)
		if fp.is_empty() and "FootprintType" in _PcbComponentScript:
			fp = str(_PcbComponentScript.FootprintType.keys()[comp.footprint])
		(_prop_labels["Footprint"] as Label).text = fp
	_update_zone_rows()
	_update_trace_rows()


## Drive the zone re-property rows for the selected zone.
##
## EXACTLY ONE selected zone, or the rows hide — the same rule the component half
## applies to a multi-selection (_property_focus_component returns null for two
## loose parts): with two zones selected there is no single thing a dropdown could
## re-property. A mixed component+zone selection shows BOTH halves, which is
## honest: each describes what it says it describes.
func _update_zone_rows() -> void:
	if _zone_prop_rows == null:
		return
	var selected: Array = _canvas.get_selected_zones()
	if selected.size() != 1:
		_hide_zone_rows()
		return
	var zone_id := str(selected[0])
	var zone: Dictionary = _data.get_zone(zone_id)
	if zone.is_empty():
		_hide_zone_rows()
		return

	_zone_prop_zone_id = zone_id
	_zone_prop_rows.visible = true
	var kind: String = _data.zone_kind(zone)
	var is_keepout := kind == "keepout"
	_zone_kind_value_label.text = "keepout" if is_keepout else "copper pour"
	_zone_prop_net_row.visible = not is_keepout
	if not is_keepout:
		_rebuild_zone_prop_net_option(str(zone.get("net", "")))
	_rebuild_zone_prop_layer_option(str(zone.get("layer", "")))


func _hide_zone_rows() -> void:
	_zone_prop_zone_id = ""
	if _zone_prop_rows != null:
		_zone_prop_rows.visible = false


## The selected TRACE's property rows (A7). ONE row so far — its width — built in
## the same key-label + value-control shape as the zone rows above, with a
## SpinBox for the same reason the arming control uses one: width is continuous,
## so there is no list of legal values to pick from.
##
## Bounded by the SAME contract the model setter enforces (pcb_trace MIN/MAX),
## so a value the box can express is a value the board will accept — a control
## that could offer 40 mm and then be refused would be the UI lying about the
## contract, the rule the zone pickers already follow.
func _build_trace_rows() -> VBoxContainer:
	_trace_prop_rows = VBoxContainer.new()
	_trace_prop_rows.name = "TraceRows"
	_trace_prop_rows.visible = false

	var row := HBoxContainer.new()
	row.name = "TraceWidthRow"
	var key := Label.new()
	key.text = "Width:"
	key.custom_minimum_size.x = 60
	row.add_child(key)

	_trace_prop_width_spin = SpinBox.new()
	_trace_prop_width_spin.name = "TracePropWidthSpin"
	_trace_prop_width_spin.tooltip_text = _wrap_tooltip("Width of the selected trace, in mm (re-widens it)")
	_trace_prop_width_spin.min_value = _PcbTraceScript.MIN_WIDTH_MM
	_trace_prop_width_spin.max_value = _PcbTraceScript.MAX_WIDTH_MM
	_trace_prop_width_spin.step = 0.05
	_trace_prop_width_spin.suffix = "mm"
	_trace_prop_width_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trace_prop_width_spin.value_changed.connect(_on_trace_prop_width_changed)
	row.add_child(_trace_prop_width_spin)
	_trace_prop_rows.add_child(row)

	return _trace_prop_rows


## Drive the trace property row for the selected trace. EXACTLY ONE selected
## trace or the row hides — the same rule the zone half applies, and for the same
## reason: with two traces selected there is no single width a box could show.
func _update_trace_rows() -> void:
	if _trace_prop_rows == null:
		return
	var selected: Array = _canvas.get_selected_traces()
	if selected.size() != 1:
		_hide_trace_rows()
		return
	var trace_id := str(selected[0])
	var trace = _data.get_trace(trace_id)
	if trace == null:
		_hide_trace_rows()
		return
	_trace_prop_trace_id = trace_id
	_trace_prop_rows.visible = true
	# set_value_no_signal for the SAME reason the arming box uses it: assigning
	# would fire value_changed and commit the box's step-rounded number back onto
	# the trace, so merely SELECTING a 0.254 mm trace would silently re-width it
	# to 0.25 and push an undo step nobody asked for.
	_trace_prop_width_spin.set_value_no_signal(float(trace.width))


func _hide_trace_rows() -> void:
	_trace_prop_trace_id = ""
	if _trace_prop_rows != null:
		_trace_prop_rows.visible = false


## Re-width the selected trace. ONE journalled, undoable step; the MODEL owns
## every rule that could refuse it (pcb_data.set_trace_width → pcb_trace.
## width_error) and its refusal string is what the user is shown, after which the
## box is re-read from the model — the board is the truth, the control is a view
## of it, the same contract the zone re-property rows keep.
##
## NO-OP EDITS MUST NOT REACH save_to_history (cold-review F3, the guard the zone
## handlers carry): SpinBox emits value_changed for a re-typed identical value,
## and set_trace_width returns "" for "no change needed" exactly as it does for a
## real write — so an unguarded commit would push a dead "Set trace width" step
## and the user's next Ctrl+Z would appear to do nothing.
func _on_trace_prop_width_changed(value: float) -> void:
	if _trace_prop_trace_id.is_empty() or _data == null:
		return
	var trace_id := _trace_prop_trace_id
	var trace = _data.get_trace(trace_id)
	if trace == null:
		return
	if is_equal_approx(float(trace.width), value):
		return
	var refusal: String = _data.set_trace_width(trace_id, value)
	if not refusal.is_empty():
		_show_transient_status(refusal)
		_update_properties()
		return
	_data.save_to_history("Set trace width")
	if _canvas != null:
		_canvas.queue_redraw()
	_update_properties()


## Populate the re-property net picker from the board's declared nets, selecting
## the pour's current one.
##
## Entry 0 is the same "Net…" placeholder carrying "" the arming picker uses, and
## it is here for the same reason: "this pour names no declared net" is a REAL
## state a loaded board can be in (a net deleted out from under it), and a picker
## that silently displayed some other net instead would be lying about the board.
## Choosing it is not a silent no-op either — set_zone_net refuses an empty net on
## a pour, visibly, which is exactly the message the user needs.
func _rebuild_zone_prop_net_option(current_net: String) -> void:
	if _zone_prop_net_option == null:
		return
	_zone_prop_net_option.clear()
	_zone_prop_net_option.add_item("Net…")
	_zone_prop_net_option.set_item_metadata(0, "")
	var names: Array = _data.get_net_names()
	names.sort()
	var selected := 0
	for net_name in names:
		var idx := _zone_prop_net_option.item_count
		_zone_prop_net_option.add_item(str(net_name))
		_zone_prop_net_option.set_item_metadata(idx, str(net_name))
		if str(net_name) == current_net:
			selected = idx
	_zone_prop_net_option.select(selected)


## Populate the re-property layer picker from the declared copper stack, selecting
## the zone's current layer.
##
## NO placeholder entry, unlike the arming picker: "follow the view filter" is a
## meaningful answer for a zone about to be DRAWN and a meaningless one for a zone
## that already exists on a layer. A board that declares no copper layers gets a
## single disabled entry saying so, and the control goes disabled — the visible
## half of the fail-closed refusal set_zone_layer makes in the model.
func _rebuild_zone_prop_layer_option(current_layer: String) -> void:
	if _zone_prop_layer_option == null:
		return
	_zone_prop_layer_option.clear()
	var choices: Array = _declared_copper_layer_choices()
	if choices.is_empty():
		_zone_prop_layer_option.add_item("(board declares no layers)")
		_zone_prop_layer_option.set_item_metadata(0, "")
		_zone_prop_layer_option.select(0)
		_zone_prop_layer_option.disabled = true
		return
	_zone_prop_layer_option.disabled = false
	var canon_current := PcbLayerStack.kicad_to_canon(current_layer) if not current_layer.is_empty() else ""
	var selected := -1
	for choice in choices:
		var idx := _zone_prop_layer_option.item_count
		_zone_prop_layer_option.add_item(str(choice["label"]))
		_zone_prop_layer_option.set_item_metadata(idx, str(choice["canon"]))
		if str(choice["canon"]) == canon_current:
			selected = idx
	if selected < 0:
		# The zone sits on a layer this board does not declare (an off-contract
		# board, or one whose stack changed under it). Show the truth rather than
		# silently pointing at some other layer the zone is not on.
		_zone_prop_layer_option.add_item("%s (not declared)" % current_layer)
		_zone_prop_layer_option.set_item_metadata(_zone_prop_layer_option.item_count - 1, "")
		selected = _zone_prop_layer_option.item_count - 1
	_zone_prop_layer_option.select(selected)


## Re-property the selected pour's net. ONE journalled, undoable step; the MODEL
## owns every rule that could refuse it (undeclared net, keepout, off-stack layer
## — see pcb_data.set_zone_net), and its refusal string is what the user is shown.
## A refusal re-reads the model into the picker rather than leaving the chosen
## entry standing: the board is the truth, the dropdown is a view of it — the same
## contract _commit_member_offset keeps with the offset fields.
func _on_zone_prop_net_selected(index: int) -> void:
	if _zone_prop_zone_id.is_empty() or _data == null or _zone_prop_net_option == null:
		return
	var meta: Variant = _zone_prop_net_option.get_item_metadata(index)
	var chosen := str(meta) if meta != null else ""
	var zone_id := _zone_prop_zone_id
	# NO-OP PICKS MUST NOT REACH save_to_history (cold-review F3). Godot's
	# OptionButton emits item_selected for EVERY popup pick, including the entry
	# already showing, and set_zone_net returns "" for "no change needed" exactly
	# as it does for a real write — so opening the dropdown and re-picking the
	# current net would push a dead "Set zone net" step. The user's next Ctrl+Z
	# would then appear to do nothing, and the one after it would eat a real edit.
	if str(_data.get_zone(zone_id).get("net", "")) == chosen:
		return
	var refusal: String = _data.set_zone_net(zone_id, chosen)
	if not refusal.is_empty():
		_show_transient_status(refusal)
		_update_properties()
		return
	_data.save_to_history("Set zone net")
	if _canvas != null:
		_canvas.queue_redraw()
	_update_properties()


## Re-property the selected zone's copper layer. Same contract as the net handler
## above, and the same one-step-per-change history shape.
func _on_zone_prop_layer_selected(index: int) -> void:
	if _zone_prop_zone_id.is_empty() or _data == null or _zone_prop_layer_option == null:
		return
	var meta: Variant = _zone_prop_layer_option.get_item_metadata(index)
	var chosen := str(meta) if meta != null else ""
	var zone_id := _zone_prop_zone_id
	# Same no-op guard as the net handler above (cold-review F3). The comparison
	# is RAW stored value vs the picker's canonical id — deliberately, so a zone
	# storing a KiCad name never equals the canonical pick and "F.Cu" -> "top"
	# stays a real normalising write, not a no-op.
	var current := str(_data.get_zone(zone_id).get("layer", ""))
	if not chosen.is_empty() and current == chosen:
		return
	var refusal: String = _data.set_zone_layer(zone_id, chosen)
	if not refusal.is_empty():
		_show_transient_status(refusal)
		_update_properties()
		return
	_data.save_to_history("Set zone layer")
	if _canvas != null:
		_canvas.queue_redraw()
	_update_properties()


## The board's declared COPPER layers as [{label, canon}], KiCad label + canonical
## metadata. ONE list, two pickers: the zone ARMING picker and the zone
## RE-PROPERTY picker both build from it, so the layers you can draw on and the
## layers you can move a zone to can never drift apart. Lifted verbatim out of
## _rebuild_zone_layer_option, whose reasoning (copper only, KiCad presentation,
## canonical comparison) is stated there.
func _declared_copper_layer_choices() -> Array:
	var choices: Array = []
	var declared: Array = _data.layers if _data != null else ["top", "bottom"]
	for layer in declared:
		var raw := str(layer)
		if not PcbLayerStack.is_copper(raw):
			continue
		var canon := PcbLayerStack.kicad_to_canon(raw)
		var label := PcbLayerStack.canon_to_kicad(canon)
		if label.is_empty():
			label = raw
		choices.append({"label": label, "canon": canon})
	return choices


## WHICH component the Properties section describes.
##
## Selecting one component still means that component — unchanged, and the ONLY
## case a board with no groups can reach. A GROUP selection (A4) resolves to the
## member the user last clicked (the canvas' focused_component, Illustrator's key
## object), falling back to the anchor. A multi-select of LOOSE parts still
## resolves to null and still blanks the section, exactly as before.
func _property_focus_component():
	var sel: Array = _canvas.get_selected_components()
	if sel.size() == 1:
		return _data.get_component(sel[0])
	var group_id := _selected_group_id()
	if group_id.is_empty():
		return null
	var focused: String = str(_canvas.focused_component)
	if focused.is_empty() or not sel.has(focused):
		focused = str(_data.group_anchor_id(group_id))
	return _data.get_component(focused)


## The group id when the selection is EXACTLY one whole group, else "".
##
## "Exactly": every selected component carries the same non-empty group id AND the
## selection holds every member of it. Anything looser — two groups, a group plus
## a loose part — is a multi-selection and gets the blank section, because there is
## no single part whose offsets could be shown.
func _selected_group_id() -> String:
	var sel: Array = _canvas.get_selected_components()
	if sel.size() < 2:
		return ""
	var group_id: String = str(_data.component_group_id(sel[0]))
	if group_id.is_empty():
		return ""
	for comp_id in sel:
		if str(_data.component_group_id(comp_id)) != group_id:
			return ""
	if _data.group_member_ids(group_id).size() != sel.size():
		return ""
	return group_id


func _hide_group_rows() -> void:
	_offset_component_id = ""
	if _group_row != null:
		_group_row.visible = false
	if _offset_row != null:
		_offset_row.visible = false


## Drive the group read-out and the offset editor for the focused component.
##
## The offset fields are NOT overwritten while they have focus — otherwise a
## selection-changed relay firing mid-typing would rewrite the digits under the
## user's cursor. They go read-only (not hidden) when the group is locked, so the
## values stay legible while the whole-unit lock refuses edits.
func _update_group_rows(comp) -> void:
	if _group_row == null or _offset_row == null:
		return
	var group_id: String = str(comp.group_id())
	if group_id.is_empty():
		_hide_group_rows()
		return

	var members: Array = _data.group_member_ids(group_id)
	var locked: bool = _data.is_group_locked(group_id)
	_group_row.visible = true
	_group_value_label.text = "%d parts, anchor %s%s" % [
		members.size(), _data.group_anchor_id(group_id), " (locked)" if locked else ""]

	if _data.is_group_anchor(str(comp.id)):
		# The anchor IS the origin — it has no offset to edit. Moving it means
		# moving the whole group, which is what a drag does.
		_offset_component_id = ""
		_offset_row.visible = false
		return

	_offset_component_id = str(comp.id)
	_offset_row.visible = true
	var offset: Vector2 = _data.member_offset(_offset_component_id)
	if not _offset_x_edit.has_focus():
		_offset_x_edit.text = "%.3f" % offset.x
	if not _offset_y_edit.has_focus():
		_offset_y_edit.text = "%.3f" % offset.y
	_offset_x_edit.editable = not locked
	_offset_y_edit.editable = not locked


## Apply the typed offset to exactly the focused member.
##
## ONE history step, and the model owns every rule that could refuse it (unknown
## component, ungrouped, anchor, whole-unit lock, no actual change — see
## pcb_data.set_member_offset). A refusal or a malformed number re-reads the model
## into the fields rather than leaving the typed text standing: the board is the
## truth, the field is a view of it.
func _commit_member_offset() -> void:
	if _offset_component_id.is_empty() or _data == null:
		return
	var raw_x := _offset_x_edit.text.strip_edges()
	var raw_y := _offset_y_edit.text.strip_edges()
	if not raw_x.is_valid_float() or not raw_y.is_valid_float():
		_revert_offset_fields()
		return
	var component_id := _offset_component_id
	if not _data.set_member_offset(component_id, Vector2(raw_x.to_float(), raw_y.to_float())):
		_revert_offset_fields()
		return
	_data.save_to_history("Offset %s" % component_id)
	if _canvas != null:
		_canvas.queue_redraw()
	_update_properties()


## Snap both offset fields back to the model's value after a REFUSED commit.
## _update_group_rows deliberately skips a field that has keyboard focus (so it
## never clobbers live typing), but on the Enter path focus never leaves — the
## refused text would stand while the model holds the old value (cold-review A4
## note 3). After a refusal the typed text is exactly what must not stand, so
## write the fields unconditionally.
func _revert_offset_fields() -> void:
	_update_properties()
	if _offset_component_id.is_empty() or _data == null or _offset_row == null:
		return
	if not _offset_row.visible:
		return
	var offset: Vector2 = _data.member_offset(_offset_component_id)
	_offset_x_edit.text = "%.3f" % offset.x
	_offset_y_edit.text = "%.3f" % offset.y


## Pin Info section (WC-1, contract §3): Component.Pin + the display rule
## (geometry pin_name > net > "(unconnected)", via host.pin_display_name so the
## UI and MCP parity tool compute the SAME string) + net_members. Starts hidden.
func _build_pin_info_section() -> VBoxContainer:
	_pin_info_section = VBoxContainer.new()
	_pin_info_section.name = "PinInfoSection"
	_pin_info_section.visible = false

	var header := Label.new()
	header.name = "PinInfoHeader"
	header.text = "Pin Info"
	_pin_info_section.add_child(header)

	_pin_info_ref_label = Label.new()
	_pin_info_ref_label.name = "PinInfoRef"
	_pin_info_section.add_child(_pin_info_ref_label)

	_pin_info_value_label = Label.new()
	_pin_info_value_label.name = "PinInfoValue"
	_pin_info_section.add_child(_pin_info_value_label)

	_pin_info_members_label = Label.new()
	_pin_info_members_label.name = "PinInfoMembers"
	_pin_info_members_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_pin_info_section.add_child(_pin_info_members_label)

	return _pin_info_section


## Canvas pin_selected relay: {} clears + hides; a populated pin_info Dictionary
## shows "Component.Pin" + the display rule + net members.
func _on_pin_selected(info: Dictionary) -> void:
	if _pin_info_section == null:
		return
	if info.is_empty():
		_pin_info_section.visible = false
		return
	_pin_info_section.visible = true
	_pin_info_ref_label.text = str(info.get("ref", ""))
	var display := ""
	if _annotation_host != null and _annotation_host.has_method("pin_display_name"):
		display = _annotation_host.pin_display_name(info)
	_pin_info_value_label.text = display
	var members: Array = info.get("net_members", [])
	_pin_info_members_label.text = "Net members: %s" % (", ".join(members) if not members.is_empty() else "(none)")


## Toolbar toggle handler — a TRUE toggle, mirroring the canvas's Shift+P
## behaviour (contract §3): pressed arms INSPECT_PIN, un-pressed exits to Select.
func _on_inspect_pin_button_pressed() -> void:
	if _canvas == null or _inspect_pin_button == null:
		return
	if _inspect_pin_button.button_pressed:
		if _active_route_flow_tool != null:
			_deactivate_route_flow_tool()
		_canvas.set_tool_mode(_PcbCanvasScript.ToolMode.INSPECT_PIN)
	else:
		_canvas.set_tool_mode(_PcbCanvasScript.ToolMode.SELECT)
	_sync_tool_buttons(_canvas.tool_mode)


# ── Route-flow toolbar cluster (WC-3, contract §5) ────────────────────────────

## Locate the platform AnnotationOverlay mounted by Editor.gd — a duck-typed,
## by-name lookup under the canvas (get_annotation_overlay_parent's own
## target), mirroring Editor.gd's own `surface.find_child("PlatformAnnotation
## Overlay", true, false)` (Editor.gd:852). Returns null when the overlay
## hasn't been mounted yet (panel not hosted by the platform — e.g. some
## headless test fixtures that never build one).
func _find_annotation_overlay() -> Control:
	if _canvas == null or not is_instance_valid(_canvas):
		return null
	var found := _canvas.find_child(_OVERLAY_NODE_NAME, true, false)
	if found is Control:
		# Bind ONCE per overlay instance so mutual exclusion also covers other
		# surfaces (e.g. the dock's own AnnotationToolbar) driving the same
		# overlay — contract: "Tool activation is mutually exclusive."
		if _overlay_tool_signal_bound != found:
			var cb := Callable(self, "_on_overlay_active_tool_changed")
			if found.has_signal("active_tool_changed") and not found.active_tool_changed.is_connected(cb):
				found.active_tool_changed.connect(cb)
			_overlay_tool_signal_bound = found
		return found
	return null


func _on_single_trace_button_pressed() -> void:
	var btn: Button = _route_flow_buttons.get("single_trace", null)
	if btn == null:
		return
	if btn.button_pressed:
		_activate_route_flow_tool("single_trace")
	else:
		_deactivate_route_flow_tool()


## Edit-hint toggle handler (C4) — same pattern as _on_single_trace_button_pressed.
func _on_edit_hint_button_pressed() -> void:
	var btn: Button = _route_flow_buttons.get("edit_hint", null)
	if btn == null:
		return
	if btn.button_pressed:
		_activate_route_flow_tool("edit_hint")
	else:
		_deactivate_route_flow_tool()


## Add-via toggle handler (U4) — same pattern as _on_edit_hint_button_pressed.
func _on_add_via_button_pressed() -> void:
	var btn: Button = _route_flow_buttons.get("add_via", null)
	if btn == null:
		return
	if btn.button_pressed:
		_activate_route_flow_tool("add_via")
	else:
		_deactivate_route_flow_tool()


## Propose button handler (C5, docket 019f6c465fd8, deliverable 1): an
## explicit human ACT — this is the ONLY thing in this plugin that invokes the
## router besides the equivalent MCP tool call (deliverable 4: nothing else —
## not panel mount, not tool activation, not an annotation-change handler —
## ever reaches _apply_route_hints/route_board; see
## test_pcb_explicit_propose.gd scenario A). Calls through handle_tool(),
## PCBPanel's own plugin-side MCP entry point, with commit=false: the EXACT
## same code path minerva_pcb_apply_route_hints (commit absent/false) takes —
## one implementation, two entry points. Async (awaits the router bridge, same
## as _on_export_yaml_pressed's await ipc.await_reply pattern) so the UI thread
## is never blocked; the button stays interactive (no manual disable — a
## second click before the first resolves just re-runs propose, which is
## idempotent by construction: it only ever reads open hints and writes fresh
## proposal annotations).
func _on_propose_button_pressed() -> void:
	_set_status("Proposing routes…")
	var result: Dictionary = await handle_tool("minerva_pcb_apply_route_hints", {"commit": false})

	if not bool(result.get("success", false)):
		if str(result.get("error", "")) == "pcb_backend_stopped":
			# Backend-stopped affordance (bug 019f6c1e0399): names the cause
			# AND the recovery action, exact wording is this round's call —
			# the structured machine shape (error/detail/recovery_hint) is
			# what panel_tools.gd's _router_unavailable already returns.
			_set_status("Routing needs the pcb backend — it's stopped. Start it from the Plugin Manager, then retry.")
		else:
			_set_status("Propose failed: %s" % str(result.get("note", result.get("error", "unknown error"))))
		return

	var n := int(result.get("proposed", 0))
	if n == 0:
		_set_status("Nothing to route — no open route hints.")
	else:
		_set_status("%d proposal%s%s" % [n, "" if n == 1 else "s", _drc_status_suffix(result)])


## DRC-at-propose (docket 019f6f1492e0) status-label suffix: BOTH scopes,
## concatenated but never blended (docket 019f98b24284 requirement 1/5) — the
## connectivity fragment and the geometric fragment are each self-contained
## (own leading " — ", own label), so a caller can find/assert either
## substring independently and neither can be read as the other's verdict.
## Extracted to a static func (no `self` reads) so the gd test suite can drive
## it with plain result dictionaries — no live PCBPanel/host required.
static func _drc_status_suffix(result: Dictionary) -> String:
	return _connectivity_status_suffix(result) + _geometric_status_suffix(result)


## Connectivity fragment. drc_summary is PROPOSAL-scoped {"scope":
## "connectivity", "clean": bool|null, "violation_count": int, "error"?:
## String, "baseline": {...}} — see pcb_worker.methods._attach_route_drc
## (docket 019f9cc386b6 added the partition; docket 019f9da15929 surfaces the
## `baseline` half here). null `clean` means the DRC engine itself faulted
## (never blocks propose — informs, never blocks); an absent/empty dict means
## the worker didn't run DRC at all (e.g. an older worker), in which case this
## fragment stays exactly as it was before (empty string).
##
## HONEST LABEL (019f958aa6db): this is the CONNECTIVITY/topology checker
## (drc.run_drc — pad centers + trace centerlines), NOT geometric copper DRC. It
## cannot verify a clearance/width/annular ring, so the chip must NOT imply a
## generic "DRC clean". We read scope (default "connectivity") and title-case it
## for the label so a clean connectivity pass reads "Connectivity clean", never
## the misleading bare "DRC clean".
##
## BASELINE (019f9da15929): `violation_count`/`clean` above answer "does
## ACCEPTING THIS introduce a violation?" — they are proposal-scoped, exactly
## like the geometric fragment's candidate-scoped `verdict`, and that part of
## this func is unchanged. `baseline` is the board's own pre-existing state
## (`methods.py` `_attach_route_drc`) and is appended as a parenthetical
## on the SAME chip (not a second " — " scope like the geometric fragment,
## because this is the connectivity scope's own pre-existing state, not a
## different question). See `_baseline_suffix` below for the absence trap.
static func _connectivity_status_suffix(result: Dictionary) -> String:
	var summary: Dictionary = result.get("drc_summary", {})
	if summary.is_empty():
		return ""
	var scope := str(summary.get("scope", "connectivity"))
	var label := scope.capitalize() if scope != "" else "Connectivity"
	var clean: Variant = summary.get("clean", null)
	var proposal_text: String
	if clean == null:
		proposal_text = "%s: unavailable" % label
	elif bool(clean):
		proposal_text = "%s clean" % label
	else:
		var count := int(summary.get("violation_count", 0))
		proposal_text = "%s: %d violation%s" % [label, count, "" if count == 1 else "s"]
	return " — %s%s" % [proposal_text, _baseline_suffix(summary)]


## Pre-existing-board-state parenthetical for the connectivity chip above.
## `summary["baseline"]` is {"clean": bool, "violation_count": int,
## "findings": [...]} when determinate, or {"clean": null, "error": str} —
## with NO `violation_count`/`findings` key — when the base run itself could
## not be completed (`methods.py` `_attach_route_drc`, the `base_error` branch).
## An absent/empty `baseline` dict (older
## worker that never emitted the partition) renders nothing, matching the
## fragment's own absent-summary behaviour.
##
## THE TRAP (project hint 019fa0e84932, docket 019f9da15929): `baseline` is
## present on BOTH the determinate and indeterminate top-level branches of
## _attach_route_drc, so merely checking `summary.has("baseline")` protects
## nothing — it is always there. What actually goes absent is ONE LEVEL DOWN:
## an indeterminate baseline carries no `violation_count` key at all, so
## `int(baseline.get("violation_count", 0))` would silently render "0
## pre-existing" for a board whose state could not be determined — a
## confident wrong answer for exactly the board that most needs a hedge. We
## therefore branch on `baseline["clean"] == null` FIRST, before ever reading
## a count — mirroring `methods.py` `_baseline_for_net`, which refuses to
## narrow an indeterminate baseline to an empty list for the same reason.
static func _baseline_suffix(summary: Dictionary) -> String:
	var baseline: Dictionary = summary.get("baseline", {})
	if baseline.is_empty():
		return ""
	if baseline.get("clean", null) == null:
		return " (pre-existing: unknown)"
	var count := int(baseline.get("violation_count", 0))
	# "none" rather than "0" so the determinate-empty and indeterminate answers
	# read as one vocabulary — "none" / "unknown" — instead of mixing a numeral
	# with a word. A user skimming "(pre-existing: 0)" beside a sibling chip
	# reading "(pre-existing: unknown)" can parse the word as a count; the two
	# are answers to the same question and should look like it. The count is
	# still a numeral whenever there IS one.
	if count == 0:
		return " (pre-existing: none)"
	return " (pre-existing: %d)" % count


## GEOMETRIC copper fragment (docket 019f98b24284) — the complement that closes
## the gap left by the connectivity fragment above: a proposal routed through
## the CENTRE of a different-net pad reads "Connectivity clean" (centerlines
## never crossed) while the copper itself shorts. drc_geometric_summary is the
## candidate-scoped union from panel_tools._write_records_as_proposals — see
## pcb_worker methods.py _attach_route_geometric_drc / ir_candidates.py
## check_candidates module docstring for the three-way contract this reads:
##
##   verdict == "clean"       -> ok=True,  candidates introduce no violation
##   verdict == "violations"  -> ok=True,  candidates introduce >=1 violation
##   anything else            -> ok=False, the check could not run at all
##
## THE INDETERMINATE TRAP (requirement 2): the union deliberately carries NO
## `clean` key — only a 3-way `verdict` string — because a truthy/absent-key
## check is exactly how "could not verify" silently reads as "verified clean"
## in GDScript. Do not "simplify" this to `if summary.get("clean")`; there is
## no such key, and adding one back reintroduces the bug this surface exists
## to remove. `match` on the literal string is the fail-closed shape: only the
## literal "clean" string renders as clean, and both "indeterminate" and any
## future/unknown verdict fall through to the same "unavailable" branch as a
## faulted connectivity check — never counted as a violation, never as clean.
##
## An absent/empty summary (older worker that never attached
## drc_geometric_summary, or a route call that took the non-canonical path
## where the worker skips the attach entirely — methods.py `_route`) is a
## THIRD state again from "indeterminate": render nothing rather than invent a
## verdict the worker never computed (requirement 2/4).
##
## BASELINE EXCLUSION (requirement 4): the union's "findings"/"verdict" are
## already candidate-scoped by the worker — pre-existing board violations live
## under summary["baseline"] and are never read here, so a dirty fixture board
## (the real fixture carries 12) cannot make a clean proposal look dirty.
static func _geometric_status_suffix(result: Dictionary) -> String:
	var summary: Dictionary = result.get("drc_geometric_summary", {})
	if summary.is_empty():
		return ""
	var verdict := str(summary.get("verdict", "indeterminate"))
	match verdict:
		"clean":
			return " — Geometric clean"
		"violations":
			var count := (summary.get("findings", []) as Array).size()
			var who := _offending_nets(result)
			# Name the offender when we can. A batch line that says only "2
			# violations" leaves the user who must REJECT one proposal unable to
			# tell which — and rejecting the right one is the entire decision
			# this surface exists to inform (019f98b24284 requirement 3).
			if who != "":
				return " — Geometric: %d violation%s on %s" % [
					count, "" if count == 1 else "s", who]
			return " — Geometric: %d violation%s" % [count, "" if count == 1 else "s"]
		_:
			# Covers "indeterminate" AND any unrecognized verdict — fail closed,
			# never counted as clean, never counted as a violation (requirement 2).
			#
			# Carry the REASON. "unavailable" on its own is unactionable: the
			# error.kind vocabulary is small, stable and shared with the route
			# reply (parse | compile | unresolved_geometry | unsupported_geometry
			# | route | internal — see ir_candidates.candidate_indeterminate), and
			# it is the difference between "this board has geometry we cannot
			# model yet" and "something faulted". The free-text message is NOT
			# surfaced here: it can be an exception repr, which does not belong
			# in a one-line status label.
			var err: Dictionary = summary.get("error", {})
			var kind := str(err.get("kind", ""))
			if kind != "":
				return " — Geometric: unavailable (%s)" % kind
			return " — Geometric: unavailable"


## Comma-joined net names of the proposals whose OWN geometric verdict is
## "violations", for the batch status line. Reads `proposals[].drc_geometric`,
## stamped per proposal by panel_tools._write_records_as_proposals — the union's
## `per_candidate` is keyed `route[<i>]`, which is a wire-level index a human
## has no way to map back to anything on screen; the net name is what the canvas
## and the hint both label.
##
## Returns "" when nothing can be attributed (an older worker that stamped no
## per-proposal verdict, or a union-level indeterminate) so the caller falls back
## to the bare count rather than printing an empty "on ".
static func _offending_nets(result: Dictionary) -> String:
	var nets: Array[String] = []
	for p in (result.get("proposals", []) as Array):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var geo: Dictionary = (p as Dictionary).get("drc_geometric", {})
		if str(geo.get("verdict", "")) != "violations":
			continue
		var net := str((p as Dictionary).get("net", ""))
		if net != "" and not nets.has(net):
			nets.append(net)
	if nets.is_empty():
		return ""
	# Cap the list: a status label that grows with the batch stops being
	# readable, and past a few names the user is going to open the list anyway.
	if nets.size() > 3:
		return ", ".join(nets.slice(0, 3)) + " +%d more" % (nets.size() - 3)
	return ", ".join(nets)


## New AnnotationAuthorTool instance for a route-flow cluster key. Deliberately
## bypasses kind.author_ui() (see SingleTraceAuthorTool's class doc) — the
## kind's author_ui() stays wired to the generic waypoint tool for the dock's
## own per-kind button.
func _new_route_flow_tool(kind_key: String) -> AnnotationAuthorTool:
	match kind_key:
		"single_trace":
			return _PcbRouteHintKindScript.SingleTraceAuthorTool.new()
		"edit_hint":
			return _PcbRouteHintKindScript.BendHandleEditTool.new()
		"add_via":
			return _PcbRouteHintKindScript.ViaInsertTool.new()
	return null


func _activate_route_flow_tool(kind_key: String) -> void:
	var overlay := _find_annotation_overlay()
	if overlay == null or _annotation_host == null:
		_set_status("Route tool unavailable — annotation overlay not mounted.")
		_untoggle_route_flow_buttons()
		return

	var tool := _new_route_flow_tool(kind_key)
	if tool == null:
		_untoggle_route_flow_buttons()
		return

	# Deactivate any route-flow tool WE previously activated (mutual exclusion
	# within the cluster; future WC-4 bus button shares this path). Done BEFORE
	# the dock clear below so the outgoing tool gets a proper on_deactivate()
	# instead of being silently nulled by that call's overlay null-bounce.
	_teardown_active_route_flow_tool()

	# Cross-surface mutual exclusion, dock half (bug 019fb64fb408, same family
	# as 019fb5e9c8ac): release any dock-armed annotation tool BEFORE this
	# function tracks/activates its own tool below — clearing after would let
	# the overlay's null-bounce reach _on_overlay_active_tool_changed and tear
	# the just-armed tool back down. _active_route_flow_tool is already null
	# by this point (teardown above), so this call's own null-bounce is a
	# harmless no-op against our tracking.
	_clear_dock_active_tool()

	# Cross-surface mutual exclusion (contract §5 / review must_fix): arming a
	# route-flow tool releases the canvas tool surface — Pan/Pin-Inspect drop
	# back to Select and their buttons un-press.
	if _canvas != null and _canvas.tool_mode != _PcbCanvasScript.ToolMode.SELECT:
		_canvas.set_tool_mode(_PcbCanvasScript.ToolMode.SELECT)
		_sync_tool_buttons(_canvas.tool_mode)

	tool.on_activate(_annotation_host)
	if not tool.annotation_ready.is_connected(_on_route_flow_annotation_ready):
		tool.annotation_ready.connect(_on_route_flow_annotation_ready)
	if not tool.cancelled.is_connected(_on_route_flow_cancelled):
		tool.cancelled.connect(_on_route_flow_cancelled)

	# Set tracking BEFORE handing to the overlay: set_active_tool below fires
	# active_tool_changed synchronously, and _on_overlay_active_tool_changed
	# must see a match (no self-reset).
	_active_route_flow_kind = kind_key
	_active_route_flow_tool = tool
	overlay.set_active_tool(tool)

	for k in _route_flow_buttons.keys():
		var b: Button = _route_flow_buttons[k]
		if is_instance_valid(b):
			b.set_pressed_no_signal(k == kind_key)
	_update_route_flow_mode_label(kind_key)


# ── Universal Select (B1u3, item 019fbb9adc) ──────────────────────────────────
#
# This panel offers ONE Select. The board canvas owns the click; the annotation
# half rides along through the PcbAnnotationHost router (see
# pcb_canvas.set_annotation_router). What this section owns is the ARMING: the
# core AnnotationTransformTool is armed PASSIVELY on the shared overlay whenever
# the canvas is in Select mode and no other surface holds the overlay.
#
# "Passively" means the overlay draws the tool and keeps every host wiring but
# stays transparent to the pointer, so the canvas keeps owning clicks — an
# ordinarily-armed tool flips the overlay to MOUSE_FILTER_STOP and Godot's gui
# walk ends there, accepted or not, which is why a tool cannot decline a click.
#
# EVERYTHING IS DUCK-TYPED. A core that cannot arm passively never gets a tool
# armed, the canvas router answers "no" to everything, and this panel behaves
# exactly as it did before this unit — with the dock's own Select still offered,
# because the older AnnotationToolbar ignores the tools_excluded capability too.

## Re-entrancy guard: arming/clearing the overlay emits active_tool_changed
## synchronously, and that handler calls back in here.
var _universal_select_syncing: bool = false


## The passively-armable tool instance, or null when the core cannot supply one.
func _universal_select_tool() -> Object:
	if _annotation_host == null or not _annotation_host.has_method("get_universal_select_tool"):
		return null
	return _annotation_host.get_universal_select_tool()


## Arm or release the universal Select to match the current state. Idempotent,
## and safe to call from any of the three edges that can change the answer:
## the canvas tool mode, the overlay's active tool, and the overlay's arrival.
func _sync_universal_select() -> void:
	if _universal_select_syncing:
		return
	if _annotation_host == null or not _annotation_host.has_method("arm_universal_select"):
		return
	var overlay := _find_annotation_overlay()
	if overlay == null:
		return
	# Armed only when the canvas is resting in Select AND nothing else holds the
	# overlay. A route-flow tool or a dock author tool is a deliberate mode; the
	# universal Select is what the panel falls back to when they let go.
	var ours := _universal_select_tool()
	var foreign := _overlay_active_tool != null and _overlay_active_tool != ours
	# Typed explicitly: _canvas is untyped (duck-typed plugin script), so the
	# tool_mode comparison yields a Variant and inference would refuse.
	var want: bool = _canvas != null \
		and _canvas.tool_mode == _PcbCanvasScript.ToolMode.SELECT \
		and _active_route_flow_tool == null \
		and not foreign
	_universal_select_syncing = true
	_annotation_host.arm_universal_select(overlay, want)
	_universal_select_syncing = false


## The overlay mounts as a child of the canvas after this panel is built; that
## arrival is the third edge _sync_universal_select watches.
func _on_canvas_child_entered(_node: Node) -> void:
	_sync_universal_select()


## Deactivates the cluster's own active tool (if any) and restores Select —
## contract §5: "deactivation restores Select." Does not touch the overlay's
## assignment when some OTHER surface is now driving it (cross-surface case;
## _on_overlay_active_tool_changed already reset our buttons for that).
func _deactivate_route_flow_tool() -> void:
	var overlay := _find_annotation_overlay()
	_teardown_active_route_flow_tool()
	if overlay != null:
		overlay.clear_active_tool()
	_untoggle_route_flow_buttons()
	_update_route_flow_mode_label("")


func _teardown_active_route_flow_tool() -> void:
	if _active_route_flow_tool == null:
		return
	if _active_route_flow_tool.annotation_ready.is_connected(_on_route_flow_annotation_ready):
		_active_route_flow_tool.annotation_ready.disconnect(_on_route_flow_annotation_ready)
	if _active_route_flow_tool.cancelled.is_connected(_on_route_flow_cancelled):
		_active_route_flow_tool.cancelled.disconnect(_on_route_flow_cancelled)
	_active_route_flow_tool.on_deactivate()
	_active_route_flow_tool = null
	_active_route_flow_kind = ""


func _untoggle_route_flow_buttons() -> void:
	for k in _route_flow_buttons.keys():
		var b: Button = _route_flow_buttons[k]
		if is_instance_valid(b) and b.button_pressed:
			b.set_pressed_no_signal(false)


## Also refreshes the status bar (docket 019fb933d4a9): the route-flow
## cluster's tools arm/disarm outside _canvas.tool_mode (they drive an
## AnnotationAuthorTool on the shared overlay, not the canvas tool surface —
## see the class doc above _MODE_HINTS), so _on_tool_mode_changed's own
## _update_status() call never fires for them. This is the one function every
## arm/disarm/cross-surface-takeover path already calls, so it is the natural
## single place to keep the status bar's armed-tool tag and gesture hint in
## step, the same way _sync_tool_buttons stays in step off tool_mode_changed.
func _update_route_flow_mode_label(kind_key: String) -> void:
	# DRY fix (cold review F7): _ROUTE_FLOW_LABELS (declared near _update_status,
	# below) is now the ONE authority for these three strings — this used to
	# carry its own match block producing the identical labels, so renaming one
	# tool meant remembering to edit two places ~10 lines apart in the same call
	# chain (the status-bar tag was the one that silently went stale).
	if _route_flow_mode_label != null:
		_route_flow_mode_label.text = str(_ROUTE_FLOW_LABELS.get(kind_key, "Select"))
	_update_status()


## Forwards a committed envelope to the host (same single call-site convention
## as AnnotationToolbar._on_annotation_ready) — the tool instance stays active
## for continuous tracing (no auto-deactivate on commit).
func _on_route_flow_annotation_ready(annotation: Dictionary) -> void:
	if _annotation_host != null:
		_annotation_host.add_annotation(annotation)


## A cancelled in-progress trace fully deactivates the cluster's tool
## (mirrors AnnotationToolbar._on_tool_cancelled's convention) — re-press the
## button to start drawing again.
func _on_route_flow_cancelled() -> void:
	_deactivate_route_flow_tool()


## Cross-surface mutual exclusion: when the shared overlay's active tool
## changes to something OTHER than what we last handed it (another surface,
## e.g. the dock's AnnotationToolbar, took over — or it was cleared from
## outside), drop our own button/label state without touching the overlay
## again (avoids a feedback loop).
func _on_overlay_active_tool_changed(tool: Object) -> void:
	_overlay_active_tool = tool
	# UNIVERSAL SELECT (B1u3): our own passive arm is not a cross-surface
	# takeover — it IS this panel's resting state, and running the teardown below
	# for it would untoggle the route-flow buttons and blank the mode label every
	# time Select re-arms.
	if tool != null and tool == _universal_select_tool():
		return
	# The overlay now holds something that is NOT our passive Select — another
	# surface's tool, or nothing at all. Either way, let the host forget it armed
	# anything, so a later disarm can never yank a tool we no longer own. This
	# runs BEFORE the route-flow early-out below on purpose: the commonest way
	# our tool gets cleared is _deactivate_route_flow_tool's unconditional
	# overlay.clear_active_tool() with no route tool active at all, which lands
	# here as tool == _active_route_flow_tool == null.
	if _annotation_host != null and _annotation_host.has_method("notify_universal_select_detached"):
		_annotation_host.notify_universal_select_detached()
	if tool == _active_route_flow_tool:
		_sync_universal_select()
		return
	_active_route_flow_tool = null
	_active_route_flow_kind = ""
	_untoggle_route_flow_buttons()
	_update_route_flow_mode_label("")
	# Reverse half of bug 019fb5e9c8ac: another surface (the dock's
	# AnnotationToolbar) armed a tool on the shared overlay — release the
	# canvas tool surface, mirroring _activate_route_flow_tool. A null tool
	# is a clear-out, not a takeover, and must not yank the canvas tool
	# (that path fires when WE clear the overlay while arming a canvas tool).
	if tool != null and _canvas != null \
			and _canvas.tool_mode != _PcbCanvasScript.ToolMode.SELECT:
		_canvas.set_tool_mode(_PcbCanvasScript.ToolMode.SELECT)
		_sync_tool_buttons(_canvas.tool_mode)
	# A clear-out hands the canvas surface back: re-arm the universal Select if
	# nothing else is holding the overlay now.
	_sync_universal_select()


## Where the platform annotation dock must mount (Editor.gd duck-types this —
## round A hook). Opting in makes this panel own the dock's responsive
## placement; the platform's editor-width RIGHT/BOTTOM logic is bypassed.
## Slot depends on the current mode: bottom strip in medium/narrow (HITL:
## 3-col wants the dock along the bottom), sidebar in wide.
func get_annotation_dock_parent() -> Control:
	var slot := _current_dock_slot()
	if slot != null and is_instance_valid(slot):
		return slot
	return null


func _current_dock_slot() -> Control:
	if _layout_mode == _PanelLayoutScript.MODE_WIDE:
		return _dock_parent
	return _bottom_dock_slot if _bottom_dock_slot != null else _dock_parent


## The mounted AnnotationDockPane, wherever it currently sits (duck-typed:
## the platform names it; we just look for its API in either slot).
func _find_dock_pane() -> Node:
	for slot in [_dock_parent, _bottom_dock_slot]:
		if slot == null or not is_instance_valid(slot):
			continue
		for child in slot.get_children():
			if child.has_method("set_dock_mode"):
				return child
	return null


## Moves the mounted dock pane into the current mode's slot and re-asserts its
## internal arrangement (RIGHT = column for the sidebar, BOTTOM = strip).
func _sync_dock_pane_mode() -> void:
	var pane := _find_dock_pane()
	if pane == null or not is_instance_valid(pane):
		return
	var slot := _current_dock_slot()
	if slot != null and pane.get_parent() != slot:
		pane.get_parent().remove_child(pane)
		slot.add_child(pane)
	var wide := _layout_mode == _PanelLayoutScript.MODE_WIDE
	if pane is Control:
		(pane as Control).size_flags_vertical = \
			Control.SIZE_EXPAND_FILL if wide else Control.SIZE_SHRINK_END
	# DockMode enum: RIGHT = 0, BOTTOM = 1 (AnnotationDockPane.gd) — read via
	# get() so a pane without the enum still duck-types safely.
	pane.set_dock_mode(0 if wide else 1)


# ── Per-hint revision undo/redo keyboard seam (C4 deliverable 2c) ─────────────

## Ctrl+Z / Ctrl+Shift+Z routes to per-hint revision undo/redo ONLY when a
## pcb_route_hint annotation is currently selected — otherwise the event is
## left unconsumed so it never collides with a future board-level undo
## binding (see below).
##
## Seam choice (reuse-scan finding): AnnotationOverlay._gui_input only
## special-cases Escape/Delete/Backspace/Enter via its pseudo-pointer
## convention (mods=KEY_ESCAPE/KEY_DELETE/KEY_ENTER through
## on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, mods)) — it does NOT
## forward Ctrl+Z at all, so no AnnotationAuthorTool ever sees it. Nor does
## pcb_canvas.gd's own _handle_key_input (it binds Delete/Escape/R/G/N/L/
## Home/+/-/S but no Ctrl+Z). PCBPanel currently wires NO board-level undo
## either (no Undo button, no Ctrl+Z handler anywhere in this plugin) — the
## legacy in-core Editor.gd:undo_action() match on Type.PCB is dead code for
## this off-tree plugin (its panel type is Type.PLUGIN_SCENE, which
## undo_action() does not match at all). So _unhandled_key_input on the
## panel Control is the first seam nothing else claims: it fires only when
## neither the overlay's nor the canvas's _gui_input consumed the key.
## Gating strictly on "a route hint is selected" keeps this mutually
## exclusive by construction with any future board-level Ctrl+Z binding —
## an edit with no hint selected simply falls through unconsumed.
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var ek: InputEventKey = event
	if not ek.pressed or ek.is_echo():
		return
	if ek.keycode != KEY_Z or not ek.ctrl_pressed:
		return
	if _annotation_host == null:
		return
	# A8u1: hint undo/redo is a SINGLE-hint revision stack (undo_hint_revision
	# takes one id). With a multi-selection there is no unambiguous target, so
	# Ctrl+Z disarms rather than silently rewinding whichever hint happens to be
	# primary. Exactly one selected → unchanged. The disarm is ANNOUNCED, not
	# silent: no board-level Ctrl+Z exists in this plugin (see the header above),
	# so falling through unconsumed would produce a dead key with no explanation —
	# the same thing draw_disarm_notice exists to prevent for bend/via.
	if _annotation_host.has_method("has_multi_selection") and _annotation_host.has_multi_selection():
		_show_transient_status("Hint undo needs one hint selected — %d are selected." \
			% _annotation_host.get_selected_annotation_ids().size())
		get_viewport().set_input_as_handled()
		return
	var sel_id: String = _annotation_host.get_selected_annotation_id()
	if sel_id.is_empty():
		return
	var ann: Dictionary = _annotation_host.get_by_id(sel_id)
	if str(ann.get("kind", "")) != "pcb_route_hint":
		return

	var result: Dictionary
	if ek.shift_pressed:
		result = _annotation_host.redo_hint_revision(sel_id)
	else:
		result = _annotation_host.undo_hint_revision(sel_id)
	if bool(result.get("ok", false)):
		get_viewport().set_input_as_handled()
		if _canvas != null:
			_canvas.queue_redraw()


# ── Responsive layout (round B) ────────────────────────────────────────────────

func _on_panel_resized() -> void:
	if _sidebar == null:
		return
	var mode: String = _PanelLayoutScript.mode_for_width(size.x, _layout_mode)
	if mode != _layout_mode:
		_apply_layout_mode(mode)


## Applies a layout mode. Visibility matrix (the View menu is the one
## view-flags surface at EVERY mode — owner ruling, bug 019fbb6242):
##   wide:   sidebar shown; Export button + board label inline.
##   medium: sidebar shown; board label → status.
##   narrow: sidebar behind the drawer toggle; Export lives in the View menu.
func _apply_layout_mode(mode: String, force := false) -> void:
	if mode == _layout_mode and not force:
		return
	var mode_changed := mode != _layout_mode
	var entering_narrow := mode == _PanelLayoutScript.MODE_NARROW \
		and _layout_mode != _PanelLayoutScript.MODE_NARROW
	_layout_mode = mode

	var narrow := mode == _PanelLayoutScript.MODE_NARROW
	var wide := mode == _PanelLayoutScript.MODE_WIDE

	if entering_narrow:
		_drawer_open = false  # drawer starts closed; canvas gets the width

	if _sidebar != null:
		var show_sidebar := (not narrow) or _drawer_open
		if _sidebar.visible and not show_sidebar and _dock_pane_in_sidebar():
			# Never hide the annotation toolbar with a live author tool — the
			# overlay would keep eating canvas clicks with no visible way out
			# (the dock pane enforces this for its own collapse; mirror it).
			# Only relevant when the dock actually sits in the sidebar — in
			# medium/narrow it lives in the always-visible bottom strip.
			_clear_dock_active_tool()
		_sidebar.visible = show_sidebar

	# Dock placement follows the mode (bottom in medium/narrow, sidebar in
	# wide) — move a mounted pane between slots.
	_sync_dock_pane_mode()
	if _drawer_button != null:
		_drawer_button.visible = narrow
		_drawer_button.button_pressed = _drawer_open
	# The View menu is unconditional at every mode (owner ruling, bug
	# 019fbb6242) — no inline-toggle sibling exists to sync or swap with; the
	# menu re-reads canvas flags on about_to_popup, so it can never go stale.
	if _export_button != null:
		_export_button.visible = not narrow
	if _board_size_label != null:
		_board_size_label.visible = wide
	# Properties default: expanded where width is generous, collapsed in the
	# 3-col medium tier (the status bar mirrors the selection either way).
	# Only on a REAL mode change — a force re-apply (drawer toggle) must not
	# clobber the user's manual expand/collapse choice.
	if mode_changed:
		_set_properties_expanded(wide)
	_update_status()


## Duck-typed: clears the active author tool on the mounted dock pane, AND
## the route-flow cluster's own tool. Three call sites: _apply_layout_mode
## (hidden-sidebar-eats-clicks hazard), _toggle_tool_mode (cross-surface
## exclusion, bug 019fb5e9c8ac — arming a canvas tool must release the dock),
## and _activate_route_flow_tool (bug 019fb64fb408 — arming a route-flow tool
## must release the dock too, called after that function's own teardown of
## any previously-armed route-flow tool so the outgoing tool still gets its
## on_deactivate() instead of a silent null-bounce).
func _clear_dock_active_tool() -> void:
	var pane := _find_dock_pane()
	if pane != null and pane.has_method("clear_active_tool"):
		pane.clear_active_tool()
	_deactivate_route_flow_tool()


func _dock_pane_in_sidebar() -> bool:
	var pane := _find_dock_pane()
	return pane != null and pane.get_parent() == _dock_parent


func _on_drawer_toggled() -> void:
	_drawer_open = not _drawer_open
	_apply_layout_mode(_layout_mode, true)


func _sync_view_menu_checks() -> void:
	if _view_menu_button == null or _canvas == null:
		return
	var popup := _view_menu_button.get_popup()
	for i in _VIEW_FLAGS.size():
		var idx := popup.get_item_index(i)
		if idx >= 0:
			popup.set_item_checked(idx, bool(_canvas.get(_VIEW_FLAGS[i][1])))


func _on_view_menu_id_pressed(id: int) -> void:
	if id == _VIEW_MENU_EXPORT_ID:
		_on_export_yaml_pressed()
		return
	if _canvas == null or id < 0 or id >= _VIEW_FLAGS.size():
		return
	var flag: String = _VIEW_FLAGS[id][1]
	_canvas.set(flag, not bool(_canvas.get(flag)))
	_canvas.queue_redraw()


## Structured layout state for MCP/tests — lets an agent verify responsive
## behavior as data instead of screenshots (LLM-ergonomics requirement).
func get_layout_state() -> Dictionary:
	return {
		"mode": _layout_mode,
		"width": size.x,
		"sidebar_visible": _sidebar != null and _sidebar.visible,
		"drawer_open": _drawer_open,
		"view_menu_visible": _view_menu_button != null and _view_menu_button.visible,
		"properties_expanded": _properties_expanded,
		"dock_position": "sidebar" if _current_dock_slot() == _dock_parent else "bottom",
	}


## Rebuild the layer selector from the board's declared stack.
##
## Epoch 6 unit 3b, owner ruling "layer presentation matches KiCad": the item
## LABEL is the KiCad copper name (F.Cu / In1.Cu / … / B.Cu) because that is what
## a PCB person reads, while the item METADATA stays the CANONICAL id ("top" /
## "in1" / "bottom") because that is what the canvas filter and the board model
## compare against (pcb_canvas._layer_visible is canonical-name equality). "All"
## stays first; the rest follow the board's declared order, which IS stack order
## (enforced by the validator, unit 3a).
func _rebuild_layer_option() -> void:
	if _layer_option == null:
		return
	_layer_option.clear()
	_layer_option.add_item("All")
	_layer_option.set_item_metadata(0, "all")
	var layers: Array = _data.layers if _data != null else ["top", "bottom"]
	for layer in layers:
		var raw := str(layer)
		# A valid board declares canonical ids, but fold a KiCad-named declaration
		# too so the metadata still MATCHES trace.layer instead of filtering to an
		# empty canvas. Non-copper names are left exactly as declared rather than
		# pushed through the copper mapping (which would error on them).
		var canon := raw
		var label := raw
		if PcbLayerStack.is_copper(raw):
			canon = PcbLayerStack.kicad_to_canon(raw)
			label = PcbLayerStack.canon_to_kicad(canon)
		# canon_to_kicad FAILS CLOSED (returns "" and push_error()s) on anything
		# it does not recognise. Show the raw declared name instead — a blank menu
		# entry is a layer the user cannot even name, which is worse than an
		# unfamiliar one.
		if label.is_empty():
			label = raw
		var idx := _layer_option.item_count
		_layer_option.add_item(label)
		_layer_option.set_item_metadata(idx, canon)
	_layer_option.select(0)


# ── Toolbar / canvas event handlers ───────────────────────────────────────────

func _toggle_tool_mode(mode: int) -> void:
	if _canvas == null:
		return
	# Cross-surface mutual exclusion (bug 019fb5e9c8ac): a canvas tool press
	# releases BOTH other tool surfaces — the route-flow cluster AND the
	# platform annotation dock. The old guard only released our own cluster,
	# so a dock-armed tool (e.g. annotation Select) stayed on the shared
	# overlay claiming every click, and Draw-tool clicks never landed.
	_clear_dock_active_tool()
	# Re-click disarm (item 5, 019fbbadd8f0, owner ruling): clicking the
	# ALREADY-armed radio button (Pan, Pour, Keepout, Trace, Eraser) is a
	# second explicit press on the same tool, not a request to re-arm it — it
	# disarms back to Select, the resting tool. Same OUTCOME the route-flow
	# cluster (_activate_route_flow_tool/_deactivate_route_flow_tool) and the
	# pin inspector (_toggle_inspect_pin_mode) already give on their own
	# surfaces — this brings the Tools/Select radio cluster in line with
	# them — but NOT the same mechanism: those two branch on the widget's
	# post-flip `button_pressed`, where this branches on `_canvas.tool_mode`,
	# the model state, which cannot be desynced by a stray button write (see
	# _sync_tool_buttons below, which does exactly such a write on every
	# call). A re-click on Select itself needs no special case — target is
	# already SELECT, and set_tool_mode's same-mode guard keeps that a no-op
	# exactly as it is today.
	var was_armed: bool = _canvas.tool_mode == mode
	var target: int = _PcbCanvasScript.ToolMode.SELECT if was_armed else mode
	# `was_armed` doubles as the announce flag: a disarm re-click is an
	# explicit "get me out" gesture, so any abandoned in-progress zone/trace
	# draw is announced, not silently discarded the way an ordinary
	# tool-to-tool switch discards one. set_tool_mode itself is responsible
	# for making that announce actually land AFTER the mode change settles
	# (cold review F1) — see its doc block.
	_canvas.set_tool_mode(target, was_armed)
	_sync_tool_buttons(_canvas.tool_mode)


func _sync_tool_buttons(mode: int) -> void:
	for m in _tool_buttons:
		(_tool_buttons[m] as Button).set_pressed_no_signal(m == mode)


## Trash-can enablement (item 019fb92f8b83): live off the canvas' own
## selection_changed signal, the same feed _update_status/_update_properties
## already listen on — no separate polling, no separate state to drift.
func _update_delete_button() -> void:
	if _delete_button != null:
		# has_ANY_selection (B1u3): the trash empties the whole panel selection,
		# annotations included, so it must be live when only an annotation is
		# selected. Duck-typed for the same reason every other canvas call here
		# is — a canvas without the verb keeps the board-only answer.
		var live := false
		if _canvas != null:
			live = _canvas.has_any_selection() if _canvas.has_method("has_any_selection") \
				else _canvas.has_selection()
		_delete_button.disabled = not live


func _on_tool_mode_changed(mode: int) -> void:
	_sync_tool_buttons(mode)
	_sync_draw_arm_ui(mode)
	_update_status()
	# The universal Select is armed with the canvas's Select mode and released
	# with it (B1u3) — one tool, one arming, whichever route got us here (button,
	# keyboard, a programmatic set_tool_mode).
	_sync_universal_select()


## Show/hide the Draw tools' arming controls with the tool each one arms, and
## refresh them from the board on every arm (nets, layers and design rules can all
## change between arms). Hooked to tool_mode_changed rather than to the buttons,
## so every route into a Draw mode — button, keyboard, a programmatic
## set_tool_mode — arms the same way.
##
## Was _sync_zone_arm_ui until the epoch 6 boundary added a trace control; the
## rule is one function per CONCEPT ("show the arming controls for the armed
## tool"), not one per widget, so the trace width box joined it rather than
## growing a parallel sync with its own copy of the visibility logic.
## The NET picker is a POUR control, not a zone control (owner boundary ruling
## 2026-07-30, docket 019fb5ad6d20: "Keepouts don't need net connections"). It is
## hidden — not merely ignored — while Keepout is armed, because a visible picker
## is a request for input, and asking for a net the commit path will discard is
## the UI lying about the contract. The LAYER picker stays for both: a keepout is
## still a region on one copper layer.
func _sync_draw_arm_ui(mode: int) -> void:
	var is_pour_tool: bool = mode == _PcbCanvasScript.ToolMode.ZONE_POUR
	var is_zone_tool: bool = is_pour_tool \
		or mode == _PcbCanvasScript.ToolMode.ZONE_KEEPOUT
	var is_trace_tool: bool = mode == _PcbCanvasScript.ToolMode.TRACE

	if _trace_width_spin != null:
		_trace_width_spin.visible = is_trace_tool
		if is_trace_tool:
			_sync_trace_width_spin()

	if _zone_layer_option != null:
		_zone_layer_option.visible = is_zone_tool
		if is_zone_tool:
			_rebuild_zone_layer_option()

	if _zone_net_option == null:
		return
	_zone_net_option.visible = is_pour_tool
	if not is_pour_tool:
		return
	_rebuild_zone_net_option()
	if _data != null and _data.get_net_count() == 0:
		_show_transient_status("This board declares no nets — a copper pour needs one before it can be drawn.")
	elif _canvas != null and str(_canvas.zone_author_net).is_empty():
		_show_transient_status("Pick a net for the pour, then click its corners.")


## Rebuild the zone net picker from the board's declared nets. The first entry is
## a placeholder carrying "" so "no net chosen" is a REAL state the commit path
## can refuse, rather than an implicit selection of whichever net sorted first —
## a pour silently tied to the wrong net is copper on the wrong net.
func _rebuild_zone_net_option() -> void:
	if _zone_net_option == null:
		return
	var previous := str(_canvas.zone_author_net) if _canvas != null else ""
	_zone_net_option.clear()
	_zone_net_option.add_item("Net…")
	_zone_net_option.set_item_metadata(0, "")
	var names: Array = _data.get_net_names() if _data != null else []
	names.sort()
	var selected := 0
	for name in names:
		var idx := _zone_net_option.item_count
		_zone_net_option.add_item(str(name))
		_zone_net_option.set_item_metadata(idx, str(name))
		if str(name) == previous:
			selected = idx
	_zone_net_option.select(selected)
	# Keep the canvas's armed net and the widget in step: a net that vanished with
	# a board reload must not stay armed behind a placeholder.
	if _canvas != null and selected == 0:
		_canvas.zone_author_net = ""


func _on_zone_net_selected(index: int) -> void:
	if _canvas == null or _zone_net_option == null:
		return
	var meta: Variant = _zone_net_option.get_item_metadata(index)
	_canvas.zone_author_net = str(meta) if meta != null else ""


## Rebuild the zone layer picker from the board's declared stack.
##
## Structurally the net picker above and the toolbar's _rebuild_layer_option
## together: first entry is a placeholder carrying "" — but here "" is NOT "no
## choice made", it is the REAL and default choice "follow the view layer filter",
## which is what the zone tools did before this control existed. That is why it is
## labelled "View layer" rather than "Layer…" and why landing on it is not an
## error the commit path refuses.
##
## Labels are KiCad names and metadata is canonical, per the same owner ruling
## _rebuild_layer_option cites ("layer presentation matches KiCad"): F.Cu is what
## a PCB person reads, "top" is what zone.layer and PcbLayerStack compare against.
## COPPER ONLY — a zone is copper (or a keepout over copper), and the canvas
## refuses a non-copper override anyway, so offering a declared non-copper layer
## here would offer a choice that does nothing.
func _rebuild_zone_layer_option() -> void:
	if _zone_layer_option == null:
		return
	var previous := str(_canvas.zone_layer_override) if _canvas != null else ""
	_zone_layer_option.clear()
	_zone_layer_option.add_item("View layer")
	_zone_layer_option.set_item_metadata(0, "")
	# _declared_copper_layer_choices (A5) is where the copper-only / KiCad-label /
	# canonical-metadata rules below used to be spelled out inline; the zone
	# RE-PROPERTY picker needs the identical list, and two copies of "which layers
	# may a zone be on" is exactly one copy too many.
	var selected := 0
	for choice in _declared_copper_layer_choices():
		var idx := _zone_layer_option.item_count
		_zone_layer_option.add_item(str(choice["label"]))
		_zone_layer_option.set_item_metadata(idx, str(choice["canon"]))
		if str(choice["canon"]) == previous:
			selected = idx
	_zone_layer_option.select(selected)
	# Keep the canvas's armed layer and the widget in step: a layer that vanished
	# with a board reload must not stay armed behind the "View layer" entry.
	if _canvas != null and selected == 0:
		_canvas.zone_layer_override = ""


func _on_zone_layer_selected(index: int) -> void:
	if _canvas == null or _zone_layer_option == null:
		return
	var meta: Variant = _zone_layer_option.get_item_metadata(index)
	_canvas.zone_layer_override = str(meta) if meta != null else ""
	# The pour preview labels itself with the effective layer, so a live redraw is
	# what makes the choice visible mid-draw rather than only at commit.
	_canvas.queue_redraw()


## Point the width box at the width the trace tool would commit right now: the
## armed override if the user has set one, else the seeding order below.
##
## set_value_no_signal, NOT `value =` — assigning would fire value_changed and so
## write the box's own (step-rounded, range-clamped) number back as an explicit
## override the user never chose. A board whose design rule is 0.254 mm would
## silently start committing 0.25 mm. Leaving the override at 0.0 keeps
## "untouched" meaning "the board's rule, exactly", and the box is a display until
## the user actually turns it. The same clamp means a sub-0.1 mm design rule shows
## as 0.1 while still committing its true value — the display rounds, the commit
## does not.
func _sync_trace_width_spin() -> void:
	if _trace_width_spin == null:
		return
	var armed: float = float(_canvas.trace_width_override) if _canvas != null else 0.0
	if armed > 0.0:
		_trace_width_spin.set_value_no_signal(armed)
		return
	_trace_width_spin.set_value_no_signal(seeded_trace_width())


## SEEDING ORDER for the width box (owner ruling, A7 docket 019fb92f07e2):
##   1. the BOARD's design_rules.trace_width_mm, when it declares one — a board
##      that states its own trace width outranks anything the user preferred on
##      some other board. The board is a document; the preference is a habit.
##   2. the STORED preference, when the board declares no rule — the no-rule case
##      is exactly the gap a preference exists to fill.
##   3. the control's own default (pcb_trace.DEFAULT_WIDTH_MM, which is also
##      pcb_data.DEFAULT_TRACE_WIDTH_MM) when neither says anything.
##
## Step 2 turns on has_stored(), NOT on the preference's value: an unstored key
## reads back as the registry default, which would make "never chose one" and
## "chose 0.25" indistinguishable and collapse steps 2 and 3 into one. This
## EXTENDS pcb_data.authored_trace_width rather than forking it — that function
## already encodes board-rule-first, and design_rule_trace_width() (A7) is the
## same read with the "declared nothing" case still visible.
func seeded_trace_width() -> float:
	var rule: float = _data.design_rule_trace_width() if _data != null else 0.0
	if rule > 0.0:
		return rule
	var prefs = get_preferences()
	if prefs == null:
		return _PcbTraceScript.DEFAULT_WIDTH_MM
	# Drain BEFORE the has_stored branch: a corrupt prefs file loads as EMPTY
	# values, so has_stored() is false and a drain inside that branch would
	# never fire — the one path that generated the warning would be the one
	# path that never showed it (cold-review A7 F1).
	_drain_pref_warning()
	if prefs.has_stored(_PcbPrefsScript.KEY_TRACE_WIDTH):
		return prefs.get_float(_PcbPrefsScript.KEY_TRACE_WIDTH, _PcbTraceScript.DEFAULT_WIDTH_MM)
	return _PcbTraceScript.DEFAULT_WIDTH_MM


func _on_trace_width_changed(value: float) -> void:
	if _canvas == null:
		return
	_canvas.trace_width_override = value
	# The width the human just chose IS the preference (A7). Only THIS control
	# writes it: the box arms the width of traces NOT YET DRAWN, which is exactly
	# what a "default trace width" preference means. The trace property row below
	# deliberately does NOT write it — re-widening one existing trace is an edit
	# to that trace, and letting it silently repoint the default would mean
	# inspecting an old 0.15 mm trace changed what every future trace looks like.
	# Seeding only consults the preference when the board declares no design rule,
	# so storing it on a board that HAS a rule is still worth doing: it is the
	# width this human wants on the next board that declares none.
	var prefs = get_preferences()
	if prefs != null:
		var res: Dictionary = prefs.set_value(_PcbPrefsScript.KEY_TRACE_WIDTH, value)
		if not bool(res.get("ok", false)):
			_show_transient_status(str(res.get("error", "Preference not stored.")))
		else:
			_drain_pref_warning()
	# The rubber-band preview draws at the armed width, so a mid-draw change is
	# visible immediately instead of only in the committed copper.
	_canvas.queue_redraw()


## The plugin-scoped preference store (pcb_prefs.gd). PROCESS-WIDE, not
## per-panel: a preference belongs to the plugin, so two open PCB tabs cannot
## hold two different ideas of the default trace width, and the MCP tool surface
## can read/write it whether or not a panel is mounted. Exposed for MCP/tests.
func get_preferences():
	return _PcbPrefsScript.shared()


## Show whatever the preference store last had to complain about (a corrupt file,
## an unwritable directory, an unreadable key) on the SAME transient status line
## refused traces and refused zone edits use. take_warning() consumes it, so a
## problem is reported once rather than on every seeding read.
func _drain_pref_warning() -> void:
	var prefs = get_preferences()
	if prefs != null and prefs.has_warning():
		_show_transient_status(prefs.take_warning())


## Apply a preference an AGENT wrote so the human's panel shows it immediately
## (A7 acceptance 4). Called through the host→panel back-reference
## (PcbAnnotationHost.get_panel) by panel_tools' minerva_pcb_set_preference —
## the same duck-typed path run_router/load_board already use.
##
## An explicit preference write is an ARMING act, not merely a stored number:
## it also sets the canvas' trace_width_override, so the next trace the human
## draws really is that wide even on a board whose design rule says otherwise
## (which is what "an agent pref write shows LIVE in the human's spin box" has
## to mean to be worth anything). Unknown keys never reach here — the tool
## validates against the store's registry first.
func apply_preference(key: String, value: Variant) -> void:
	if key != _PcbPrefsScript.KEY_TRACE_WIDTH:
		return
	var width := float(value)
	if _canvas != null:
		_canvas.trace_width_override = width
		_canvas.queue_redraw()
	if _trace_width_spin != null:
		_trace_width_spin.set_value_no_signal(width)


func _on_layer_selected(index: int) -> void:
	if _canvas == null or _layer_option == null:
		return
	var meta: Variant = _layer_option.get_item_metadata(index)
	_canvas.trace_layer_filter = str(meta) if meta != null else "all"
	_canvas.queue_redraw()


func _on_component_lock_changed(message: String) -> void:
	_show_transient_status(message)


## Show a message in the status bar, then fall back to the standing status after
## 2s. The ONE transient-status pathway — the component-lock channel and the zone
## tools' feedback channel both land here rather than each growing their own timer.
func _show_transient_status(message: String) -> void:
	_set_status(message)
	# Clear the transient message after 2s (guard: tree may be gone).
	if is_inside_tree():
		get_tree().create_timer(2.0).timeout.connect(func() -> void:
			if is_instance_valid(_status_label):
				_update_status())


## Backend lifecycle: lazy start-on-demand + process-identity verification
## (docket bug 019f6c1e0399). Godot-scene panels are host-executed independent
## of the plugin's own backend subprocess — PluginScenePanelBroker mounts this
## panel regardless of whether the Go backend is RUNNING (that's the whole
## bug: the panel opens and edits fine while the backend is stopped, and only
## the first IPC round-trip — export/route/load — discovers it). Rather than
## a blanket manifest autostart (which would spend a subprocess on every PCB
## plugin install, including sessions that never touch a routing/export
## action), every backend IPC call below goes through
## _request_with_backend_ensure: on a plugin_not_running reply it starts the
## backend and PROVES the connection it produced is actually "pcb" before
## retrying — see _verify_backend_identity for why a liveness flag is not
## enough.
##
## Lazy-start bridge: no host_capability exists for "start my own plugin" on
## CapabilityBroker's named dispatch table — the only reachable lever from a
## scene panel is capability:mcp.proxy:<tool>, which forwards verbatim to
## MinervaMCPServer (see CapabilityBroker._handle_mcp_proxy). This proxies
## minerva_plugin_start the same way the drive/movie-gen/3d-gen plugins already
## proxy their own host tools. Declared in manifest.json permissions +
## ui.ipc_messages + this panel's ipc_channels.
const _START_BACKEND_CHANNEL := "capability:mcp.proxy:minerva_plugin_start"
## Go-side in-process tool (internal/tools/ping.go, registered at server
## startup — answers directly, no worker hop) — NOT the Python worker's
## internal "ping" JSON-RPC method (worker/pcb_worker/methods.py), which is
## bridge-internal and never reaches Minerva's MCP surface. This is the one
## that's a real, dynamically-discovered MCP tool once the backend is running
## (confirmed by test_pcb_plugin_smoke.gd's Section B: "ping" appears in
## conn.list_tools()) and it echoes a caller-supplied string verbatim, which
## is exactly the round-trip identity primitive we need.
const _PING_CHANNEL := "ping"
const _BACKEND_PLUGIN_ID := "pcb"


## True only for the broker's plugin_not_running reply shape
## (PluginErrors.plugin_not_running: {success:false, error_code:
## "plugin_not_running", ...}) — matched by code AND by message substring, so
## ensure-and-retry still fires if PluginErrors' wording ever changes (same
## defensive match route_board's own plugin_not_running detection already used).
func _reply_says_plugin_not_running(reply: Dictionary) -> bool:
	if typeof(reply) != TYPE_DICTIONARY:
		return false
	var code := str(reply.get("error_code", ""))
	var msg := str(reply.get("error_message", ""))
	return code == "plugin_not_running" or msg.findn("not running") != -1


## PROCESS-IDENTITY check — deliberately NOT a liveness boolean. Sends a
## fresh, locally-generated nonce through the backend's "ping" tool and
## requires ALL THREE: ok==true, plugin=="pcb", AND echo==the exact nonce
## THIS call generated. Liveness alone (ok==true, or "a connection object
## exists") does not prove the round-trip that just happened reached the
## process we mean to talk to — a stale cached reply, a reply satisfying some
## OTHER in-flight request, or a differently-configured backend could all
## satisfy a bare ok==true check. Generating the nonce fresh per call (rather
## than reusing a fixed string) is what makes the comparison meaningful: only
## a live process that received THIS request and echoed it back, right now,
## passes.
func _verify_backend_identity(ipc, timeout_ms: int = 10000) -> bool:
	if ipc == null:
		return false
	var nonce := "pcb-identity-%d-%d" % [Time.get_ticks_usec(), randi()]
	var reply_id := "ping:%d" % Time.get_ticks_usec()
	request.emit(_PING_CHANNEL, {"echo": nonce}, reply_id)
	var reply: Dictionary = await ipc.await_reply(reply_id, timeout_ms)
	if typeof(reply) != TYPE_DICTIONARY or not bool(reply.get("success", false)):
		return false
	# Two levels of unwrap between here and HandlePing's raw {ok,plugin,
	# version,echo} body — confirmed against the REAL binary (Section C of
	# test_pcb_backend_lifecycle.gd), not assumed: main.go's dispatch()
	# ALWAYS wraps every tool's raw result as {ok:true, result:<raw>} before
	# it leaves the Go process (see main.go:347-349); _dispatch_to_plugin_backend
	# then sees that dict has an "ok" key and wraps it AGAIN via
	# PluginErrors.backend_success — so a scene panel calling any backend tool
	# (not just ping) sees {success, result:{ok, result:<raw>}}. This is the
	# SAME double-wrap route_board's own unwrap already contends with for
	# pcb.route (see its "worker envelope arrives one level deeper than the
	# direct-stdio path" comment) — ping is just the leaf case, since its
	# raw body IS the thing we compare, not a further worker envelope.
	var go_envelope: Variant = reply.get("result", {})
	if typeof(go_envelope) != TYPE_DICTIONARY:
		return false
	var body_variant: Variant = (go_envelope as Dictionary).get("result", {})
	if typeof(body_variant) != TYPE_DICTIONARY:
		return false
	var body: Dictionary = body_variant
	return bool(body.get("ok", false)) \
			and str(body.get("plugin", "")) == _BACKEND_PLUGIN_ID \
			and str(body.get("echo", "")) == nonce


## Lazy start-on-demand: ask the host to start the pcb backend (the only
## reachable bridge from a scene panel — see _START_BACKEND_CHANNEL), THEN
## prove via a fresh ping round-trip that the connection it produced is
## actually the pcb backend. minerva_plugin_start's own {ok:true} is never
## treated as sufficient by itself — it only reflects PluginManager's state
## flag flipping to RUNNING, not that this panel can actually reach and
## correctly identify the process over IPC.
func _start_and_verify_backend(ipc, timeout_ms: int = 30000) -> bool:
	if ipc == null:
		return false
	var reply_id := "%s:%d" % [_START_BACKEND_CHANNEL, Time.get_ticks_usec()]
	request.emit(_START_BACKEND_CHANNEL, {"id": _BACKEND_PLUGIN_ID}, reply_id)
	var start_reply: Dictionary = await ipc.await_reply(reply_id, timeout_ms)
	if typeof(start_reply) != TYPE_DICTIONARY or not bool(start_reply.get("success", false)):
		return false
	return await _verify_backend_identity(ipc)


## Wraps a single backend IPC round-trip with on-demand lazy start: send the
## request; if (and only if) the backend replies plugin_not_running, start it
## and verify its identity, then retry ONCE. Every existing call site's error
## handling (route_board / load_board_from_yaml / _on_export_yaml_pressed)
## already understands the raw broker reply shape unchanged by this wrapper —
## on any outcome other than a confirmed start+verify, the ORIGINAL
## plugin_not_running reply is returned verbatim so those call sites' own
## "pcb_backend_stopped" / "start via minerva_plugin_start" messaging still
## fires exactly as before for the caller to see.
func _request_with_backend_ensure(channel: String, payload: Dictionary, timeout_ms: int) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return {"success": false, "error_code": "worker_unavailable",
			"error_message": "plugin IPC channel not ready"}
	var reply_id := "%s:%d" % [channel, Time.get_ticks_usec()]
	request.emit(channel, payload, reply_id)
	var result: Dictionary = await ipc.await_reply(reply_id, timeout_ms)
	if not _reply_says_plugin_not_running(result):
		return result
	if not await _start_and_verify_backend(ipc):
		return result
	var retry_id := "%s:%d" % [channel, Time.get_ticks_usec()]
	request.emit(channel, payload, retry_id)
	return await ipc.await_reply(retry_id, timeout_ms)


## YAML export → pcb.serialize over the plugin IPC channel (carry-in 3a). The
## legacy PCBEditor.export_yaml() called the dropped to_yaml(); the canonical
## boundary + Go channel owns YAML now. 64KiB cap surfaces as payload_too_large
## → shown in the status bar (never crashes).
func _on_export_yaml_pressed() -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_set_status("YAML export unavailable — plugin IPC not ready.")
		return
	_set_status("Exporting YAML…")
	var result: Dictionary = await _request_with_backend_ensure(
			"pcb.serialize", {"board": _data.to_board_dict()}, 30000)

	if not bool(result.get("success", false)):
		var code := str(result.get("error_code", ""))
		var msg := str(result.get("error_message", ""))
		if code.findn("payload_too_large") != -1 or code.findn("too_large") != -1 or msg.findn("64") != -1:
			_set_status("YAML export failed: board exceeds the 64KiB IPC cap.")
		else:
			_set_status("YAML export failed: %s" % (msg if msg != "" else code))
		return

	# Success payload shape is owned by the Go side; surface a size hint if present.
	var payload: Variant = result.get("result", null)
	var yaml_text := ""
	if payload is Dictionary:
		yaml_text = str((payload as Dictionary).get("yaml", (payload as Dictionary).get("text", "")))
	elif payload is String:
		yaml_text = payload
	if yaml_text != "":
		_set_status("YAML exported (%d bytes)." % yaml_text.length())
	else:
		_set_status("YAML export complete.")


## Router bridge (route-correction loop, agent-router child 019eb47eb567). Builds
## the worker `route` request from the LIVE board + the host's route-hint
## annotations and drives it over the plugin IPC channel the same way YAML export
## drives pcb.serialize. Returns the worker's {ok, result:{success, routes,
## unrouted, via_count, …}} envelope verbatim, or a structured worker_unavailable
## when the IPC channel is not ready / times out — the caller
## (host.run_router → MCPPcbPanelTools.minerva_pcb_apply_route_hints) turns that
## into failure-as-feedback rather than crashing.
##
## "pcb.route" is a declared broker channel (manifest.json ipc_channels) forwarded
## to the worker `route` method (internal/tools RouteChannel/HandleRouteChannel,
## bug 019f3815e9f9). The route-correction loop is LIVE; worker_unavailable is
## returned only when the IPC channel is genuinely not ready (panel not mounted).
func route_board(selection: Dictionary) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null or _data == null:
		return {"ok": false, "error": {"kind": "worker_unavailable",
			"message": "plugin IPC channel not ready"}}
	var envelopes: Array = []
	if _annotation_host != null and _annotation_host.has_method("get_all_annotations"):
		for ann in _annotation_host.get_all_annotations():
			if ann is Dictionary and str((ann as Dictionary).get("kind", "")) == "pcb_route_hint":
				# Per-hint revision/redo history never leaves the editing
				# session (C4 deliverable 1 contract: "excluded from
				# route-request building") — strip before it reaches the
				# router worker over IPC.
				if _annotation_host.has_method("strip_hint_history"):
					envelopes.append(_annotation_host.strip_hint_history(ann as Dictionary))
				else:
					envelopes.append(ann)
	var params := {
		"board": _data.to_board_dict(),
		"route_hints": envelopes,
		"selection": selection,
	}
	var result: Dictionary = await _request_with_backend_ensure("pcb.route", params, 30000)
	# The worker returns {ok, result}; the host IPC wrapper may nest it under
	# "result"/"success" — normalise to the worker envelope the apply tool wants.
	if result.has("ok"):
		return result
	if bool(result.get("success", false)) and result.get("result", null) is Dictionary:
		var inner: Dictionary = result.get("result")
		# Live broker shape: MinervaIPC wraps the backend reply in
		# {success, result} while the Go side forwards the worker's own
		# {ok, result} envelope verbatim (HandleRouteChannel) — so the
		# worker envelope arrives one level deeper than the direct-stdio
		# path. Unwrap it rather than re-wrapping (HITL-2 live bug: the
		# apply tool read routes one level too high and proposed nothing).
		if inner.has("ok"):
			return inner
		return {"ok": true, "result": inner}
	# Backend-stopped detection (C5, docket 019f6c465fd8, bug 019f6c1e0399):
	# when the pcb backend subprocess is not RUNNING,
	# PluginScenePanelBroker._dispatch_to_plugin_backend replies with
	# PluginErrors.plugin_not_running(plugin_id) — {success:false,
	# error_code:"plugin_not_running", error_message:"Plugin is not running"} —
	# verbatim (no "ok" key, so it falls through the two checks above). Tag it
	# distinctly from the generic worker_error fallback so panel_tools.gd's
	# _router_unavailable (and the Propose button) can surface a
	# human-actionable "start it" message instead of an opaque routing
	# failure. error_message is ALSO matched by substring (not just the code)
	# so a differently-worded future PluginErrors message still degrades
	# correctly.
	var code := str(result.get("error_code", ""))
	var msg := str(result.get("error_message", ""))
	if code == "plugin_not_running" or msg.findn("not running") != -1:
		return {"ok": false, "error": {"kind": "plugin_not_running",
			"message": msg if not msg.is_empty() else "Plugin is not running",
			"hint": "start via minerva_plugin_start"}}
	return {"ok": false, "error": {"kind": "worker_error",
		"message": str(result.get("error_message", result.get("error", "route failed")))}}


## Whole-board load (minerva_pcb_load_board): parse canonical YAML via the Go
## backend's pcb.deserialize channel, then rebuild the live board from the
## returned canonical dict in ONE call — replacing the multi-call add_component /
## connect_net / import_footprint_geometry / import_trace_geometry sequence.
## Async, mirroring the pcb.serialize / route_board await pattern. Returns
## {ok, result:{component_count, net_count, warnings}} or {ok:false, error:{…}}.
func load_board_from_yaml(yaml_text: String) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null or _data == null:
		return {"ok": false, "error": {"kind": "worker_unavailable",
			"message": "plugin IPC channel not ready"}}
	var result: Dictionary = await _request_with_backend_ensure("pcb.deserialize", {"yaml": yaml_text}, 30000)

	# Unwrap the deserialize reply. HandleDeserialize returns {board, warnings};
	# the broker/worker path nests that under one or more {ok|success, result:{…}}
	# envelopes (the live shape is {ok, result:{board, warnings}}). Recurse through
	# `result` wrappers to the dict that directly carries `board`.
	var payload = _unwrap_to_board(result)
	if payload == null:
		var code := str(result.get("error_code", ""))
		var msg := str(result.get("error_message", result.get("error", "deserialize failed")))
		if code == "plugin_not_running" or msg.findn("not running") != -1:
			return {"ok": false, "error": {"kind": "plugin_not_running",
				"message": msg, "hint": "start via minerva_plugin_start"}}
		return {"ok": false, "error": {"kind": "worker_error", "message": msg}}

	var board: Dictionary = payload.get("board")
	var warnings: Array = payload.get("warnings", [])

	# Rebuild the live board (from_board_dict emits data_changed; suppress the
	# dirty relay for the whole load like the project-file restore path).
	_restoring = true
	_data.from_board_dict(board)
	_restoring = false

	# Reflect the new board in the toolbar/status and frame it in the canvas —
	# _on_data_changed only queue_redraw()s, it does not refit, so mirror the
	# file-open path (which does exactly this) or the capture shows the stale view.
	_refresh_board_ui()
	_zoom_to_fit_deferred()

	return {"ok": true, "result": {
		"component_count": _data.get_component_count(),
		"net_count": _data.nets.size(),
		"warnings": warnings,
	}}


## Recursively unwrap broker/worker envelopes ({ok|success, result:{…}}) down to
## the dict that directly carries a `board` key. Returns that dict (board +
## warnings siblings) or null when no board is present.
func _unwrap_to_board(v) -> Variant:
	if not (v is Dictionary):
		return null
	if v.get("board", null) is Dictionary:
		return v
	if v.get("result", null) is Dictionary:
		return _unwrap_to_board(v.get("result"))
	return null


## On-demand routing draft-check (T2.4). Production wiring for the reusable NATIVE
## draft-check seam T5 depends on: computes the current board coherence token,
## has the routing workspace build the request (flipping the checked candidates
## to "checking"), forwards it over the DECLARED pcb.draft_check broker channel
## with the live board attached, awaits the worker reply, and hands it back to
## workspace.apply_check_result — which GUARDS on the echoed board_token +
## workspace_generation (+ per-candidate revision) before writing any verdict, so
## a stale reply can never mark a candidate clean. Async, mirroring the
## pcb.serialize / route_board await pattern.
##
## ON-DEMAND ONLY. Debounce/coalescing/cancellation/auto-recheck are T6.
##
## Like route_board's live worker hop, the full broker→worker round-trip does not
## run under the headless gd scaffold (no _MinervaIPC backend there); the seam is
## covered by the worker pytest (draft_check) + the gd state-machine test
## (begin_check/apply_check_result with a fake reply). When the IPC channel is not
## ready the checked candidates are reverted (apply_check_result discards an empty
## reply), never left stuck on "checking". Returns the draft_check result dict on
## success, or {} when the hop could not run.
func check_draft(candidate_ids: Array = []) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null or _data == null or _routing_workspace == null:
		if _routing_workspace != null:
			# Still flip+revert so a caller sees a coherent no-op, not stuck state.
			_routing_workspace.begin_check(candidate_ids)
			_routing_workspace.apply_check_result({})
		return {}

	# Board coherence token = the SAME fingerprint the durable sidecar guards with.
	var board_dict: Dictionary = _data.to_board_dict()
	_routing_workspace.board_token = _PcbRoutingSidecarScript.compute_board_fingerprint(board_dict)

	var payload: Dictionary = _routing_workspace.begin_check(candidate_ids)
	payload["board"] = board_dict

	var reply_id := "pcb.draft_check:%d" % Time.get_ticks_usec()
	request.emit("pcb.draft_check", payload, reply_id)
	var result: Dictionary = await ipc.await_reply(reply_id, 30000)

	# Unwrap to the worker's draft_check result dict ({board_token,
	# workspace_generation, findings, per_candidate}). The broker may nest the
	# worker {ok, result} envelope one level deeper under {success, result}
	# (same shape route_board unwraps). apply_check_result guard-discards an
	# empty/mismatched reply, so a failed unwrap safely reverts the candidates.
	var inner: Dictionary = _unwrap_draft_check(result)
	_routing_workspace.apply_check_result(inner)
	return inner


## Dig the draft_check result dict out of whatever envelope the broker returned.
func _unwrap_draft_check(result: Dictionary) -> Dictionary:
	var r: Dictionary = result
	# Broker wrap: {success, result:{ok, result:{…}}} → step into the worker envelope.
	if r.has("result") and r.get("result") is Dictionary and (r.get("result") as Dictionary).has("ok"):
		r = r.get("result")
	# Worker envelope: {ok, result:{…}} → the inner result is what we want.
	if r.has("ok") and r.get("result") is Dictionary:
		r = r.get("result")
	# A well-formed draft_check result carries per_candidate; else treat as no-op.
	if r.has("per_candidate") or r.has("board_token"):
		return r
	return {}


# ── Status / board-size UI ────────────────────────────────────────────────────

func _update_board_size_label() -> void:
	if _board_size_label != null and _data != null:
		_board_size_label.text = "Board: %s×%smm" % [_data.board_width, _data.board_height]


## The ONE status-text writer: the label ellipsizes on overflow (see its
## build-site comment), so the tooltip always carries the full text — hover
## recovers whatever a narrow pane trimmed.
func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
		_status_label.tooltip_text = text


## While-armed gesture grammar (docket 019fb933d4a9): the teaching prose that
## used to live in the tool tooltips (now one clause each — see the
## _wrap_tooltip call sites) relocates HERE, not to a toast. This is a live
## status readout that stays visible for as long as the tool is armed, unlike
## _show_transient_status's 2s toast — the right lifetime for something a user
## needs to read while they work, not glance at once.
##
## Keyed by ToolMode; the route-flow cluster's tools (single_trace/edit_hint/
## add_via, WC-3/C4/U4) aren't in that enum — they arm an AnnotationAuthorTool
## on the shared overlay instead of driving _canvas.tool_mode — so they're
## looked up separately, off _active_route_flow_kind, below.
const _MODE_HINTS := {
	1: "Drag a part to move · drag empty to box-select · R rotates",     # SELECT
	5: "Click a pin to see its info",                                    # INSPECT_PIN
	6: "Pick a net below, click each corner, Enter/dbl-click to close",  # ZONE_POUR
	7: "Click each corner, Enter/dbl-click to close (no net needed)",    # ZONE_KEEPOUT
	8: "Click a pad to start, click waypoints, click a pad to finish",   # TRACE
	9: "Click an entity to delete it (Esc to disarm)",                   # ERASER
}
const _ROUTE_FLOW_LABELS := {
	"single_trace": "Single Trace",
	"edit_hint": "Edit Hint",
	"add_via": "Add Via",
}
const _ROUTE_FLOW_HINTS := {
	"single_trace": "Click a pad/point, waypoints, then a pad to finish",
	"edit_hint": "Drag a handle to move a bend, right-click to delete it",
	"add_via": "Click the proposal, then a point on its route to add a via",
}


func _update_status() -> void:
	if _status_label == null or _canvas == null or _data == null:
		return
	var sel: Array = _canvas.get_selected_components()
	# Indexed by ToolMode: NONE, SELECT, TRANSLATE, ROTATE, PAN, INSPECT_PIN,
	# ZONE_POUR, ZONE_KEEPOUT, TRACE, ERASER. BUG FIX: this array used to stop
	# at 9 entries (through TRACE) while ToolMode.ERASER = 9 — tm < size() was
	# false for the eraser, so it silently got no mode tag at all. ERASER is
	# now entry 9.
	var mode_names := ["", "Select", "Move", "Rotate", "Pan", "Inspect Pin", "Pour", "Keepout", "Trace", "Eraser"]
	var mode_txt := ""
	var armed_hint := ""
	if _active_route_flow_kind != "":
		mode_txt = "  [%s]" % _ROUTE_FLOW_LABELS.get(_active_route_flow_kind, "")
		armed_hint = str(_ROUTE_FLOW_HINTS.get(_active_route_flow_kind, ""))
	else:
		var tm: int = _canvas.tool_mode
		if tm > 0 and tm < mode_names.size():
			mode_txt = "  [%s]" % mode_names[tm]
		armed_hint = str(_MODE_HINTS.get(tm, ""))
	var hint := "  •  wheel/pinch zoom · Pan tool or Space/right/middle-drag to pan"
	if not armed_hint.is_empty():
		hint = "  •  %s" % armed_hint
	# Below wide mode the toolbar's board-size label is hidden — carry it here
	# (unchanged). BUG FIX: the gesture hint above used to be blanked here too,
	# for EVERY non-wide mode — but MEDIUM is the 3-col PRIMARY design target
	# (panel_layout.gd), so that silently hid the armed tool's grammar at the
	# panel's most common width, defeating the very teaching this round moved
	# here. Only NARROW (sidebar behind a drawer, toolbar folded into a View
	# menu — already the one mode that compacts every other secondary readout)
	# still drops it; MEDIUM keeps both the board size AND the hint.
	var board_txt := ""
	if _layout_mode != _PanelLayoutScript.MODE_WIDE:
		board_txt = "  •  %s×%smm" % [_data.board_width, _data.board_height]
	if _layout_mode == _PanelLayoutScript.MODE_NARROW:
		hint = ""
	_set_status("%d parts, %d nets, %d traces  •  %d selected%s%s%s" % [
		_data.get_component_count(), _data.get_net_count(), _data.get_trace_count(),
		sel.size(), mode_txt, board_txt, hint])


## Reflect the current model into the toolbar + canvas (after a load).
func _refresh_board_ui() -> void:
	_rebuild_layer_option()
	_rebuild_zone_net_option()
	# The Draw tools' other two arming controls follow the same load rule: a new
	# board brings its own layer stack and its own design-rule width, so neither a
	# stack entry nor a width left over from the previous board stays armed.
	# _rebuild_zone_layer_option drops a layer the new stack lacks by itself; the
	# width has no such membership test, so it is cleared outright and re-reads the
	# new board's design rule.
	_rebuild_zone_layer_option()
	if _canvas != null:
		_canvas.trace_width_override = 0.0
	_sync_trace_width_spin()
	_update_board_size_label()
	_update_status()
	if _canvas != null:
		_canvas.queue_redraw()


func _zoom_to_fit_deferred() -> void:
	if _canvas == null:
		return
	if _canvas.size.x > 0 and _canvas.size.y > 0:
		_canvas.zoom_to_fit()
	else:
		_canvas.resized.connect(_canvas.zoom_to_fit, CONNECT_ONE_SHOT)


# ── host_owned save/load (board doc + annotation sidecar) ──────────────────────

## Return the board's save state. Ctrl+S writes this Dict to the .pcbskel file as
## JSON (Editor.gd host_owned path). Canonical from now on (port rule 4): the
## returned shape is to_board_dict(). We ALSO flush annotations to the sidecar
## here — the platform does not auto-persist plugin-panel annotation sidecars
## (gap register C-15), so the panel owns that write.
func _on_panel_save_request() -> Dictionary:
	var board_dict: Dictionary = _data.to_board_dict()
	if _annotation_host != null and not _file_path.is_empty():
		_annotation_host.save_sidecar(_file_path)
	# T2a: flush the routing workspace to "<board_path>.routing.json" AFTER the
	# annotation sidecar. The fingerprint is computed from the CURRENT board_dict
	# (the exact fabrication doc we return, which carries NO routing state), so a
	# later load can tell whether this workspace still matches the board.
	# Save vs Save-As: on Save the sidecar rewrites at the same _file_path with a
	# matching fingerprint (candidates load clean next open); on Save-As _file_path
	# has already been updated to the new path by _on_panel_load_request's capture
	# (the host re-drives load with the new path) — but for a same-content Save-As
	# the recomputed fingerprint still matches, so candidates stay valid. Zero
	# candidates ⇒ the sidecar is deleted, never written empty.
	if _routing_workspace != null and not _file_path.is_empty():
		_PcbRoutingSidecarScript.save_workspace(
			_file_path, _routing_workspace, board_dict, int(_data.board_revision))
	return board_dict


## Restore board state previously returned by _on_panel_save_request.
##
## Accepts BOTH shapes (port rule 4):
##   1. Canonical board dict (to_board_dict): {version, name, width_mm, height_mm,
##      grid_mm, components:[…canonical…], nets, traces, vias, design_rules}.
##   2. Legacy skeleton shape {version, kind:"pcbskel_board", board:{width_mm,
##      height_mm}, components:[{ref,x,y,w,h}]} — detected by the nested `board`
##      key and migrated to canonical before load.
##
## The host ALWAYS includes `file_path` (Editor.gd:1117), in BOTH the JSON-merged
## and the raw-text document shapes; we capture it either way (W-15 — the JSON
## branch previously dropped it, so live saves never knew where to write the
## sidecar).
func _on_panel_load_request(document: Dictionary) -> void:
	var doc := document

	# Capture file_path regardless of shape.
	var doc_path := str(document.get("file_path", ""))
	if not doc_path.is_empty():
		_file_path = doc_path

	# Raw-text shape: parse the body ourselves.
	if document.has("raw_text") and not document.has("board") and not document.has("width_mm"):
		var parsed: Variant = JSON.parse_string(str(document.get("raw_text", "")))
		if parsed is Dictionary:
			doc = parsed as Dictionary
		else:
			doc = {}

	# Restoring saved state — suppress the dirty relay for the whole load.
	_restoring = true
	if doc.has("board") and doc["board"] is Dictionary:
		# Legacy skeleton shape → migrate to canonical, then load.
		_data.from_board_dict(_migrate_skeleton_shape(doc))
	elif doc.has("width_mm") or doc.has("components") or doc.has("name"):
		# Canonical board dict.
		_data.from_board_dict(doc)
	# else: unknown/empty body — keep whatever board is already loaded.

	# Annotation persistence for this board file (restored, not edited).
	# Idempotency marker = sidecar presence (docket annotation child 019eb47e4e7e):
	#   * sidecar exists           → load it (already migrated, or authored fresh);
	#                                 NEVER re-migrate — the inline blobs, if the
	#                                 board still carries them, are stale duplicates.
	#   * no sidecar + legacy blobs → ONE-SHOT migrate the inline annotations /
	#                                 route_hints into v2 envelopes, then save the
	#                                 sidecar immediately so the data is durable.
	#   * no sidecar + no legacy    → nothing to load.
	#
	# Dirty-state decision (documented): migration runs INSIDE the _restoring gate,
	# so the migrated envelopes' annotations_changed signals do NOT dirty the tab —
	# migration is a restore-class operation, not a user edit. The board file itself
	# rewrites clean on the next save (to_board_dict() never emits annotations /
	# route_hints), so the inline blobs disappear naturally; the sidecar is the
	# source of truth from here on.
	if _annotation_host != null and not _file_path.is_empty():
		_annotation_host.set_document_path(_file_path)
		if AnnotationSidecar.has_sidecar(_file_path):
			_annotation_host.load_sidecar(_file_path)
		elif _has_legacy_annotation_blobs(doc):
			_run_legacy_migration(doc)
		# else: no sidecar, no legacy blobs — leave the host's list empty.

	# T2a: load the routing workspace sidecar, coherence-gated. Runs INSIDE the
	# _restoring gate (a restore, not a user edit). The fingerprint is recomputed
	# from the board we JUST loaded into _data; a mismatch (board changed under the
	# workspace — Save-As/copy/edit/crash-torn/ABA) marks ALL candidates stale
	# rather than trusting them. Missing sidecar → nothing to load; corrupt/
	# unknown-schema → quarantine, never a crashed load.
	if _routing_workspace != null and not _file_path.is_empty():
		_PcbRoutingSidecarScript.load_into_workspace(
			_file_path, _routing_workspace, _data.to_board_dict(), int(_data.board_revision))
	_restoring = false

	_refresh_board_ui()
	_zoom_to_fit_deferred()


## Run the one-shot legacy → sidecar migration through the annotation host, persist
## the result, and surface the count/warnings on the status bar. Caller guarantees
## _annotation_host + _file_path are set and no sidecar exists yet. Runs while
## _restoring is true so migrated envelopes never dirty the tab.
func _run_legacy_migration(doc: Dictionary) -> void:
	_last_migration = _LegacyAnnotationMigration.migrate(
		doc.get("annotations", {}), doc.get("route_hints", {}), _annotation_host)
	_annotation_host.save_sidecar(_file_path)
	var n := int(_last_migration.get("migrated", 0))
	var warns: Array = _last_migration.get("warnings", [])
	if warns.is_empty():
		_set_status("Migrated %d legacy annotation%s to sidecar." % [n, "" if n == 1 else "s"])
	else:
		_set_status("Migrated %d legacy annotation%s (%d warning%s)." % [
			n, "" if n == 1 else "s", warns.size(), "" if warns.size() == 1 else "s"])


## Summary of the most recent legacy migration ({migrated, warnings}). {0, []}
## when no migrating load has run. Exposed for tests / telemetry.
func get_last_migration_summary() -> Dictionary:
	return _last_migration


## True when the loaded document still carries a NON-EMPTY inline annotations or
## route_hints blob (the one-shot migration trigger).
static func _has_legacy_annotation_blobs(doc: Dictionary) -> bool:
	return not _blob_empty(doc.get("annotations", null)) or not _blob_empty(doc.get("route_hints", null))


static func _blob_empty(v: Variant) -> bool:
	if v is Array:
		return (v as Array).is_empty()
	if v is Dictionary:
		return (v as Dictionary).is_empty()
	return true


## Migrate the legacy skeleton document {board:{width_mm,height_mm},
## components:[{ref,x,y,w,h}]} to a canonical board dict. Crude parts become
## canonical components sized by width/height with a single origin pin — lossy but
## the skeleton carried no pin/net data to lose.
func _migrate_skeleton_shape(doc: Dictionary) -> Dictionary:
	var board: Dictionary = doc.get("board", {})
	var canonical := {
		"version": 1,
		"name": "Untitled",
		"width_mm": float(board.get("width_mm", 100.0)),
		"height_mm": float(board.get("height_mm", 100.0)),
		"components": [],
	}
	for c in doc.get("components", []):
		if not c is Dictionary:
			continue
		canonical["components"].append({
			"ref": str(c.get("ref", "")),
			"x_mm": float(c.get("x", 0.0)),
			"y_mm": float(c.get("y", 0.0)),
			"rotation_deg": 0.0,
			"width": float(c.get("w", 4.0)),
			"height": float(c.get("h", 4.0)),
			"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
		})
	return canonical
