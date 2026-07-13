extends MinervaPluginPanel
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
var _view_toggles_box: HBoxContainer = null
var _view_menu_button: MenuButton = null
var _drawer_button: Button = null
var _export_button: Button = null

## Properties section (round C): field name -> value Label.
var _prop_labels: Dictionary = {}
var _properties_body: VBoxContainer = null
var _properties_collapse_btn: Button = null
var _properties_expanded := true

## View-flag table shared by the wide-mode CheckButtons and the medium/narrow
## View menu (single source of truth: the canvas flags themselves).
const _VIEW_FLAGS := [
	["Grid", "show_grid"],
	["Ratsnest", "show_ratsnest"],
	["Labels", "show_labels"],
	["Traces", "show_traces"],
	["Silk", "show_silk"],
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

	# Canvas → panel signal wiring.
	_canvas.tool_mode_changed.connect(_on_tool_mode_changed)
	_canvas.component_selected.connect(func(_id: String) -> void:
		_update_status(); _update_properties())
	_canvas.selection_changed.connect(func() -> void:
		_update_status(); _update_properties())
	_canvas.component_lock_changed.connect(_on_component_lock_changed)
	_canvas.zoom_changed.connect(func(_z: float) -> void: _update_status())

	# Right sidebar (legacy layout clone): tool buttons + the platform
	# annotation dock (mounted by Minerva via get_annotation_dock_parent).
	content_hbox.add_child(_build_sidebar())

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

	_sidebar.add_child(HSeparator.new())

	# Platform annotation dock mounts here (Editor duck-types
	# get_annotation_dock_parent — round A). Fills the remaining column.
	_dock_parent = VBoxContainer.new()
	_dock_parent.name = "AnnotationDockParent"
	_dock_parent.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sidebar.add_child(_dock_parent)

	_sidebar.add_child(HSeparator.new())
	_sidebar.add_child(_build_properties_section())

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


## Where the platform annotation dock must mount (Editor.gd duck-types this —
## round A hook). Opting in makes this panel own the dock's responsive
## placement; the platform's editor-width RIGHT/BOTTOM logic is bypassed.
func get_annotation_dock_parent() -> Control:
	if _dock_parent != null and is_instance_valid(_dock_parent):
		return _dock_parent
	return null


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
	var entering_narrow := mode == _PanelLayoutScript.MODE_NARROW \
		and _layout_mode != _PanelLayoutScript.MODE_NARROW
	_layout_mode = mode

	var narrow := mode == _PanelLayoutScript.MODE_NARROW
	var wide := mode == _PanelLayoutScript.MODE_WIDE

	if entering_narrow:
		_drawer_open = false  # drawer starts closed; canvas gets the width

	if _sidebar != null:
		_sidebar.visible = (not narrow) or _drawer_open
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
	_set_properties_expanded(wide)
	_update_status()


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
		return {"ok": true, "result": result.get("result")}
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
	# Indexed by ToolMode: NONE, SELECT, TRANSLATE, ROTATE, PAN.
	var mode_names := ["", "Select", "Move", "Rotate", "Pan"]
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
