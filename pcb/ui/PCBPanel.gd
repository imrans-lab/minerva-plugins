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

## Default skeleton board handed to a fresh (anonymous) editor — a couple of
## crude parts so the canvas isn't blank before a document loads.
const _DEFAULT_BOARD := {
	"version": 1,
	"name": "Untitled",
	"width_mm": 60.0,
	"height_mm": 40.0,
	"grid_mm": 2.54,
	"components": [
		{"ref": "U1", "footprint": "IC_DIP", "x_mm": 8.0, "y_mm": 8.0, "rotation_deg": 0.0,
			"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		{"ref": "R1", "footprint": "RESISTOR", "x_mm": 34.0, "y_mm": 6.0, "rotation_deg": 0.0,
			"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}, {"number": "2", "x_mm": 2.54, "y_mm": 0.0}]},
	],
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

## True while restoring persisted state (board load OR annotation sidecar load).
## Suppresses the content_changed dirty relay so restoring never marks the tab
## dirty (W-14; carry-in 3b extends the gate to cover board load).
var _restoring := false


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

	# Canvas fills the middle.
	var canvas_container := PanelContainer.new()
	canvas_container.name = "CanvasContainer"
	canvas_container.clip_contents = true
	canvas_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(canvas_container)

	_canvas = _PcbCanvasScript.new()
	_canvas.name = "PCBCanvas"
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_container.add_child(_canvas)
	_canvas.set_data(_data)

	# Canvas → panel signal wiring.
	_canvas.tool_mode_changed.connect(_on_tool_mode_changed)
	_canvas.component_selected.connect(func(_id: String) -> void: _update_status())
	_canvas.selection_changed.connect(_update_status)
	_canvas.component_lock_changed.connect(_on_component_lock_changed)
	_canvas.zoom_changed.connect(func(_z: float) -> void: _update_status())

	# Model → toolbar (board size label) refresh.
	_data.structure_changed.connect(_update_board_size_label)

	# Status bar.
	_status_label = Label.new()
	_status_label.name = "StatusBar"
	_status_label.custom_minimum_size.y = 22
	main_vbox.add_child(_status_label)

	_update_board_size_label()
	_update_status()


func _build_toolbar() -> HBoxContainer:
	var tb := HBoxContainer.new()
	tb.name = "Toolbar"
	tb.custom_minimum_size.y = 34

	# Tool-mode buttons (Select / Move / Rotate) — text labels (off-tree: no uid icons).
	_add_tool_button(tb, _PcbCanvasScript.ToolMode.SELECT, "Select", "Select components / traces (S)")
	_add_tool_button(tb, _PcbCanvasScript.ToolMode.TRANSLATE, "Move", "Move selected components")
	_add_tool_button(tb, _PcbCanvasScript.ToolMode.ROTATE, "Rotate", "Rotate selected components (R)")

	tb.add_child(VSeparator.new())

	# Zoom controls.
	var zoom_out := Button.new()
	zoom_out.text = "−"  # minus sign
	zoom_out.tooltip_text = "Zoom out (-)"
	zoom_out.pressed.connect(func() -> void: _canvas._zoom_at(_canvas.size / 2, 0.8))
	tb.add_child(zoom_out)

	var zoom_fit := Button.new()
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

	# View toggles.
	tb.add_child(_make_toggle("Grid", true, func(p: bool) -> void:
		_canvas.show_grid = p; _canvas.queue_redraw()))
	tb.add_child(_make_toggle("Ratsnest", true, func(p: bool) -> void:
		_canvas.show_ratsnest = p; _canvas.queue_redraw()))
	tb.add_child(_make_toggle("Labels", true, func(p: bool) -> void:
		_canvas.show_labels = p; _canvas.queue_redraw()))
	tb.add_child(_make_toggle("Traces", true, func(p: bool) -> void:
		_canvas.show_traces = p; _canvas.queue_redraw()))

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
	var export_btn := Button.new()
	export_btn.text = "Export YAML"
	export_btn.tooltip_text = "Serialize the board to canonical YAML via the plugin backend"
	export_btn.pressed.connect(_on_export_yaml_pressed)
	tb.add_child(export_btn)

	# Spacer + board size label.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tb.add_child(spacer)

	_board_size_label = Label.new()
	_board_size_label.name = "BoardSizeLabel"
	tb.add_child(_board_size_label)

	return tb


func _add_tool_button(tb: HBoxContainer, mode: int, text: String, tip: String) -> void:
	var btn := Button.new()
	btn.text = text
	btn.tooltip_text = tip
	btn.toggle_mode = true
	btn.pressed.connect(func() -> void: _toggle_tool_mode(mode))
	tb.add_child(btn)
	_tool_buttons[mode] = btn


func _make_toggle(text: String, on: bool, cb: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = on
	c.toggled.connect(cb)
	return c


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
	if _canvas.tool_mode == mode:
		_canvas.clear_tool_mode()
	else:
		_canvas.set_tool_mode(mode)


func _on_tool_mode_changed(mode: int) -> void:
	for m in _tool_buttons:
		(_tool_buttons[m] as Button).button_pressed = (m == mode)
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
	var mode_names := ["", "Select", "Move", "Rotate"]
	var mode_txt := ""
	var tm: int = _canvas.tool_mode
	if tm > 0 and tm < mode_names.size():
		mode_txt = "  [%s]" % mode_names[tm]
	_status_label.text = "%d parts, %d nets, %d traces  •  %d selected%s" % [
		_data.get_component_count(), _data.get_net_count(), _data.get_trace_count(),
		sel.size(), mode_txt]


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

	# Load the annotation sidecar for this board file (restored, not edited).
	if _annotation_host != null and not _file_path.is_empty():
		_annotation_host.set_document_path(_file_path)
		_annotation_host.load_sidecar(_file_path)
	_restoring = false

	_refresh_board_ui()
	_zoom_to_fit_deferred()


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
