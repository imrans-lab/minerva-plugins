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

## The ported board canvas (custom-drawn Control child), built on mount.
var _canvas: Control = null

## Toolbar widgets (built on mount).
var _tool_buttons: Dictionary = {}   # ToolMode int -> Button
var _layer_option: OptionButton = null
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
var _view_toggles_box: HBoxContainer = null
var _view_menu_button: MenuButton = null
var _drawer_button: Button = null
var _export_button: Button = null

## Properties section (round C): field name -> value Label.
var _prop_labels: Dictionary = {}
var _properties_body: VBoxContainer = null
var _properties_collapse_btn: Button = null
var _properties_expanded := true

## Pin Info section (WC-1 pin inspector). Hidden until a pin is selected;
## hides again on clear (canvas pin_selected({})).
var _inspect_pin_button: Button = null
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

## View-flag table shared by the wide-mode CheckButtons and the medium/narrow
## View menu (single source of truth: the canvas flags themselves).
const _VIEW_FLAGS := [
	["Grid", "show_grid"],
	["Ratsnest", "show_ratsnest"],
	["Labels", "show_labels"],
	["Traces", "show_traces"],
	["Silk", "show_silk"],
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
	if _registered_editor_name != "":
		AnnotationHostRegistry.deregister(_registered_editor_name)
		_registered_editor_name = ""


# ── UI construction ───────────────────────────────────────────────────────────

## Build toolbar + canvas + status bar. The host gives panels the full rect; we
## own the whole layout (VBox: toolbar / canvas / status).
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

	# Content row: canvas (majority share) + right sidebar (legacy layout clone).
	var content_hbox := HBoxContainer.new()
	content_hbox.name = "ContentHBox"
	content_hbox.clip_contents = true
	content_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(content_hbox)

	# Canvas fills the middle.
	var canvas_container := PanelContainer.new()
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
	# maps board-mm to canvas-LOCAL pixels, and the PanelContainer stylebox inset
	# would offset every marker otherwise.
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

	# Canvas → panel signal wiring.
	_canvas.tool_mode_changed.connect(_on_tool_mode_changed)
	_canvas.component_selected.connect(func(_id: String) -> void:
		_update_status(); _update_properties())
	_canvas.selection_changed.connect(func() -> void:
		_update_status(); _update_properties())
	_canvas.component_lock_changed.connect(_on_component_lock_changed)
	_canvas.zoom_changed.connect(func(_z: float) -> void: _update_status())
	_canvas.pin_selected.connect(_on_pin_selected)

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
	main_vbox.add_child(_bottom_dock_slot)
	_bottom_dock_slot.child_entered_tree.connect(func(_n: Node) -> void:
		call_deferred("_sync_dock_pane_mode"))
	if _dock_parent != null:
		_dock_parent.child_entered_tree.connect(func(_n: Node) -> void:
			call_deferred("_sync_dock_pane_mode"))

	# Model → toolbar (board size label) refresh.
	_data.structure_changed.connect(_update_board_size_label)

	# Status bar.
	_status_label = Label.new()
	_status_label.name = "StatusBar"
	_status_label.custom_minimum_size.y = 22
	main_vbox.add_child(_status_label)

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
	_drawer_button.tooltip_text = "Show/hide the tools sidebar"
	_drawer_button.toggle_mode = true
	_drawer_button.visible = false
	_drawer_button.pressed.connect(_on_drawer_toggled)
	tb.add_child(_drawer_button)

	# Zoom controls.
	var zoom_out := Button.new()
	zoom_out.text = "−"  # minus sign
	zoom_out.tooltip_text = "Zoom out (-)"
	zoom_out.pressed.connect(func() -> void: _canvas._zoom_at(_canvas.size / 2, 0.8))
	tb.add_child(zoom_out)

	var zoom_fit := Button.new()
	var fit_icon := _load_icon("zoom_fit_24.png")
	if fit_icon != null:
		zoom_fit.icon = fit_icon
	else:
		zoom_fit.text = "Fit"
	zoom_fit.tooltip_text = "Zoom to fit"
	zoom_fit.pressed.connect(func() -> void: _canvas.zoom_to_fit())
	tb.add_child(zoom_fit)

	var zoom_in := Button.new()
	zoom_in.text = "+"
	zoom_in.tooltip_text = "Zoom in (+)"
	zoom_in.pressed.connect(func() -> void: _canvas._zoom_at(_canvas.size / 2, 1.2))
	tb.add_child(zoom_in)

	tb.add_child(VSeparator.new())

	# View toggles — a named box so responsive modes can show/hide it whole.
	# Wide mode shows the inline CheckButtons; medium/narrow use the View menu
	# below (both drive the same canvas flags, so they can't drift apart).
	_view_toggles_box = HBoxContainer.new()
	_view_toggles_box.name = "ViewTogglesBox"
	for entry in _VIEW_FLAGS:
		var flag: String = entry[1]
		_view_toggles_box.add_child(_make_toggle(entry[0], true, func(p: bool) -> void:
			_canvas.set(flag, p); _canvas.queue_redraw()))
	tb.add_child(_view_toggles_box)

	# Compact View menu (medium/narrow): the same flags as checkable items,
	# synced from the canvas each time it opens. Narrow also gets Export here.
	_view_menu_button = MenuButton.new()
	_view_menu_button.name = "ViewMenuButton"
	_view_menu_button.text = "View"
	_view_menu_button.visible = false
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
	_export_button.tooltip_text = "Serialize the board to canonical YAML via the plugin backend"
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


func _add_tool_button(tb: Container, mode: int, text: String, tip: String, icon_file := "") -> void:
	var btn := Button.new()
	var icon := _load_icon(icon_file) if not icon_file.is_empty() else null
	if icon != null:
		# Icon-only (legacy look, and the narrow-column width saver); the
		# name stays discoverable via the tooltip.
		btn.icon = icon
	else:
		btn.text = text
	btn.tooltip_text = tip
	btn.toggle_mode = true
	btn.pressed.connect(func() -> void: _toggle_tool_mode(mode))
	tb.add_child(btn)
	_tool_buttons[mode] = btn


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


func _make_toggle(text: String, on: bool, cb: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = on
	c.toggled.connect(cb)
	return c


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

	var tools_flow := FlowContainer.new()
	tools_flow.name = "ToolsFlow"
	_sidebar.add_child(tools_flow)

	# ONE smart Select tool + a Pan tool (Photoshop / GraphicsEditor style,
	# finding 5). Select does select + move + box-select + rotate; Pan drags
	# the whole view.
	_add_tool_button(tools_flow, _PcbCanvasScript.ToolMode.SELECT, "Select",
		"Select & move (S) — click selects; drag a part to move (snaps); drag empty to box-select; R rotates selection",
		"select_24.png")
	_add_tool_button(tools_flow, _PcbCanvasScript.ToolMode.PAN, "Pan",
		"Pan the view — drag anywhere. Also works: right-drag, middle-drag, or hold Space and drag.",
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
	_inspect_pin_button.tooltip_text = "Click on a pin to see its info (Shift+P)"
	_inspect_pin_button.toggle_mode = true
	_inspect_pin_button.pressed.connect(_on_inspect_pin_button_pressed)
	tools_flow.add_child(_inspect_pin_button)
	_tool_buttons[_PcbCanvasScript.ToolMode.INSPECT_PIN] = _inspect_pin_button

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
	trace_btn.tooltip_text = "Draw a single-trace route hint: click a pad or point, click waypoints, " \
		+ "click a pad/double-click empty space to finish (Esc/right-click cancels)"
	trace_btn.toggle_mode = true
	trace_btn.pressed.connect(_on_single_trace_button_pressed)
	tools_flow.add_child(trace_btn)
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
	edit_hint_btn.tooltip_text = "Edit a route hint's bend points: click the hint to select it, " \
		+ "drag a handle to move a bend, right-click a handle to delete it, " \
		+ "click a segment to insert a new bend (Esc/tool-switch exits)"
	edit_hint_btn.toggle_mode = true
	edit_hint_btn.pressed.connect(_on_edit_hint_button_pressed)
	tools_flow.add_child(edit_hint_btn)
	_route_flow_buttons["edit_hint"] = edit_hint_btn

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
	_propose_button.tooltip_text = "Run the router over open route hints and write back inspectable cyan proposals (the board is not changed)"
	_propose_button.pressed.connect(_on_propose_button_pressed)
	tools_flow.add_child(_propose_button)

	_route_flow_mode_label = Label.new()
	_route_flow_mode_label.name = "RouteFlowModeLabel"
	_route_flow_mode_label.text = "Select"
	_route_flow_mode_label.add_theme_font_size_override("font_size", 11)
	_sidebar.add_child(_route_flow_mode_label)

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

	return section


func _set_properties_expanded(expanded: bool) -> void:
	_properties_expanded = expanded
	if _properties_body != null:
		_properties_body.visible = expanded
	if _properties_collapse_btn != null:
		_properties_collapse_btn.button_pressed = expanded
		_properties_collapse_btn.text = "Properties" if expanded else "Properties…"


func _update_properties() -> void:
	if _prop_labels.is_empty() or _canvas == null or _data == null:
		return
	var sel: Array = _canvas.get_selected_components()
	var comp = _data.get_component(sel[0]) if sel.size() == 1 else null
	if comp == null:
		for key in _prop_labels:
			(_prop_labels[key] as Label).text = "-"
		return
	(_prop_labels["ID"] as Label).text = str(comp.id)
	(_prop_labels["Position"] as Label).text = "(%.1f, %.1f)" % [comp.position.x, comp.position.y]
	(_prop_labels["Rotation"] as Label).text = "%.0f°" % float(comp.rotation)
	(_prop_labels["Layer"] as Label).text = str(comp.layer)
	var fp := str(comp.footprint_id)
	if fp.is_empty() and "FootprintType" in _PcbComponentScript:
		fp = str(_PcbComponentScript.FootprintType.keys()[comp.footprint])
	(_prop_labels["Footprint"] as Label).text = fp


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


## DRC-at-propose (docket 019f6f1492e0) status-label suffix. drc_summary is
## {"clean": bool|null, "violation_count": int, "error"?: String} — see
## pcb_worker.methods._attach_route_drc. null means the DRC engine itself
## faulted (never blocks propose — informs, never blocks); an absent/empty
## dict means the worker didn't run DRC at all (e.g. an older worker), in
## which case the status label stays exactly as it was before this round.
func _drc_status_suffix(result: Dictionary) -> String:
	var summary: Dictionary = result.get("drc_summary", {})
	if summary.is_empty():
		return ""
	var clean: Variant = summary.get("clean", null)
	if clean == null:
		return " — DRC: unavailable"
	if bool(clean):
		return " — DRC clean"
	var count := int(summary.get("violation_count", 0))
	return " — DRC: %d violation%s" % [count, "" if count == 1 else "s"]


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
	# within the cluster; future WC-4 bus button shares this path).
	_teardown_active_route_flow_tool()

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


func _update_route_flow_mode_label(kind_key: String) -> void:
	if _route_flow_mode_label == null:
		return
	match kind_key:
		"single_trace":
			_route_flow_mode_label.text = "Single Trace"
		"edit_hint":
			_route_flow_mode_label.text = "Edit Hint"
		_:
			_route_flow_mode_label.text = "Select"


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
	if tool == _active_route_flow_tool:
		return
	_active_route_flow_tool = null
	_active_route_flow_kind = ""
	_untoggle_route_flow_buttons()
	_update_route_flow_mode_label("")


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


## Applies a layout mode. Visibility matrix:
##   wide:   sidebar shown; inline view toggles; Export + board label inline.
##   medium: sidebar shown; toggles fold into the View menu (3-col width is
##           too tight for five labeled CheckButtons); board label → status.
##   narrow: sidebar behind the drawer toggle; View menu carries Export too.
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
	if _view_toggles_box != null:
		_view_toggles_box.visible = wide
		if wide and _canvas != null:
			# Re-sync the inline CheckButtons from the canvas flags — the View
			# menu can change flags while the toggles are hidden (medium/narrow).
			for i in mini(_VIEW_FLAGS.size(), _view_toggles_box.get_child_count()):
				var c := _view_toggles_box.get_child(i) as CheckButton
				if c != null:
					c.set_pressed_no_signal(bool(_canvas.get(_VIEW_FLAGS[i][1])))
	if _view_menu_button != null:
		_view_menu_button.visible = not wide
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
## the route-flow cluster's own tool (same hidden-sidebar-eats-clicks hazard
## the dock pane already guards against — see the call site in
## _apply_layout_mode).
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
		"view_toggles_inline": _view_toggles_box != null and _view_toggles_box.visible,
		"view_menu_visible": _view_menu_button != null and _view_menu_button.visible,
		"properties_expanded": _properties_expanded,
		"dock_position": "sidebar" if _current_dock_slot() == _dock_parent else "bottom",
	}


func _rebuild_layer_option() -> void:
	if _layer_option == null:
		return
	_layer_option.clear()
	_layer_option.add_item("All")
	_layer_option.set_item_metadata(0, "all")
	var layers: Array = _data.layers if _data != null else ["top", "bottom"]
	for layer in layers:
		var idx := _layer_option.item_count
		_layer_option.add_item(str(layer))
		_layer_option.set_item_metadata(idx, str(layer))
	_layer_option.select(0)


# ── Toolbar / canvas event handlers ───────────────────────────────────────────

func _toggle_tool_mode(mode: int) -> void:
	if _canvas == null:
		return
	# Cross-surface mutual exclusion: a canvas tool press releases the
	# route-flow cluster (guarded — never clears another surface's tool).
	if _active_route_flow_tool != null:
		_deactivate_route_flow_tool()
	# Radio behaviour: Select and Pan are the two persistent tools. Clicking a
	# tool activates it; Select is the resting tool, so we never drop to a
	# modeless state. Re-assert button pressed-states even when the mode is
	# unchanged (clicking the already-active toggle button flipped it visually).
	_canvas.set_tool_mode(mode)
	_sync_tool_buttons(_canvas.tool_mode)


func _sync_tool_buttons(mode: int) -> void:
	for m in _tool_buttons:
		(_tool_buttons[m] as Button).button_pressed = (m == mode)


func _on_tool_mode_changed(mode: int) -> void:
	_sync_tool_buttons(mode)
	_update_status()


func _on_layer_selected(index: int) -> void:
	if _canvas == null or _layer_option == null:
		return
	var meta: Variant = _layer_option.get_item_metadata(index)
	_canvas.trace_layer_filter = str(meta) if meta != null else "all"
	_canvas.queue_redraw()


func _on_component_lock_changed(message: String) -> void:
	_set_status(message)
	# Clear the transient lock message after 2s (guard: tree may be gone).
	if is_inside_tree():
		get_tree().create_timer(2.0).timeout.connect(func() -> void:
			if is_instance_valid(_status_label):
				_update_status())


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
	var reply_id := "pcb.serialize:%d" % Time.get_ticks_usec()
	request.emit("pcb.serialize", {"board": _data.to_board_dict()}, reply_id)
	var result: Dictionary = await ipc.await_reply(reply_id, 30000)

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
	var reply_id := "pcb.route:%d" % Time.get_ticks_usec()
	request.emit("pcb.route", params, reply_id)
	var result: Dictionary = await ipc.await_reply(reply_id, 30000)
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


# ── Status / board-size UI ────────────────────────────────────────────────────

func _update_board_size_label() -> void:
	if _board_size_label != null and _data != null:
		_board_size_label.text = "Board: %s×%smm" % [_data.board_width, _data.board_height]


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _update_status() -> void:
	if _status_label == null or _canvas == null or _data == null:
		return
	var sel: Array = _canvas.get_selected_components()
	# Indexed by ToolMode: NONE, SELECT, TRANSLATE, ROTATE, PAN, INSPECT_PIN.
	var mode_names := ["", "Select", "Move", "Rotate", "Pan", "Inspect Pin"]
	var mode_txt := ""
	var tm: int = _canvas.tool_mode
	if tm > 0 and tm < mode_names.size():
		mode_txt = "  [%s]" % mode_names[tm]
	var hint := "  •  wheel/pinch zoom · Pan tool or Space/right/middle-drag to pan"
	# Below wide mode the toolbar's board-size label is hidden — carry it here.
	var board_txt := ""
	if _layout_mode != _PanelLayoutScript.MODE_WIDE:
		board_txt = "  •  %s×%smm" % [_data.board_width, _data.board_height]
		hint = ""
	_status_label.text = "%d parts, %d nets, %d traces  •  %d selected%s%s%s" % [
		_data.get_component_count(), _data.get_net_count(), _data.get_trace_count(),
		sel.size(), mode_txt, board_txt, hint]


## Reflect the current model into the toolbar + canvas (after a load).
func _refresh_board_ui() -> void:
	_rebuild_layer_option()
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
	if _annotation_host != null and not _file_path.is_empty():
		_annotation_host.save_sidecar(_file_path)
	return _data.to_board_dict()


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
