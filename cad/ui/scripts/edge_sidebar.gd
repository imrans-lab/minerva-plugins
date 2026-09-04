extends RefCounted
## The wide sidebar's edge inspector and everything that changes which edge is
## selected: the Tree and its Prev/Next/Clear buttons, the row the tree
## highlights, and the fan-out of a new selection to the annotation host and to
## every per-pane geometry overlay.
##
## The tree is built in code rather than declared in the scene because its rows
## are the evaluation's edge registry — there is no fixed set of them.
##
## Edge selection and reference-node selection (scripts/reference_selection.gd)
## are independent state: an edge of the evaluated solid and a node of a
## reference mesh are different questions, and both stay set.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/edge_sidebar.gd")

## Verbose tracing of the pick path — which overlay was connected, which
## edge it reported. Off in normal builds; the panel reads it too.
const DEBUG_EDGE_PICK: bool = false

## The panel that owns this module. Read through duck typing (its annotation
## host, its geometry overlays and its edge registry) — never typed, off-tree.
var _panel: Object = null

## The wide layout's sidebar container the tree and buttons hang under. Null
## on a panel whose scene declares no sidebar: nothing is built and every
## method below is a no-op.
var _sidebar: VBoxContainer = null

## Tree node in the wide sidebar listing all edges. Built in attach().
var _edge_tree: Tree = null

## Map edge_id → TreeItem so we can sync selection both directions.
var _edge_tree_items: Dictionary = {}

## Re-entrancy guard for tree → panel selection routing.
var _suppress_tree_selection: bool = false


## Build the wide-mode edge Tree under the given sidebar container, and take
## the panel it reports to. Three buttons (Prev / Next / Clear) sit beneath
## the tree.
func attach(panel: Object, sidebar: VBoxContainer) -> void:
	_panel = panel
	_sidebar = sidebar
	if _sidebar == null:
		return

	var hr := HSeparator.new()
	hr.name = "EdgeSidebarSeparator"
	_sidebar.add_child(hr)

	var label := Label.new()
	label.name = "EdgeSidebarHeader"
	label.text = "Edge Markers"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sidebar.add_child(label)

	_edge_tree = Tree.new()
	_edge_tree.name = "EdgeTree"
	_edge_tree.focus_mode = Control.FOCUS_NONE
	_edge_tree.hide_root = true
	_edge_tree.columns = 3
	_edge_tree.set_column_title(0, "id")
	_edge_tree.set_column_title(1, "len/r")
	_edge_tree.set_column_title(2, "kind")
	_edge_tree.set_column_titles_visible(true)
	_edge_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edge_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_edge_tree.custom_minimum_size = Vector2(0, 180)
	_edge_tree.item_selected.connect(_on_edge_tree_item_selected)
	_sidebar.add_child(_edge_tree)

	var btn_row := HBoxContainer.new()
	btn_row.name = "EdgeButtons"
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sidebar.add_child(btn_row)

	var prev_btn := Button.new()
	prev_btn.text = "Prev"
	prev_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prev_btn.pressed.connect(_on_prev_edge_pressed)
	btn_row.add_child(prev_btn)

	var next_btn := Button.new()
	next_btn.text = "Next"
	next_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	next_btn.pressed.connect(_on_next_edge_pressed)
	btn_row.add_child(next_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_btn.pressed.connect(_on_clear_edge_pressed)
	btn_row.add_child(clear_btn)


## Populate the edge Tree from the current edge_registry.
func render(edges: Array) -> void:
	if _edge_tree == null:
		return
	_edge_tree.clear()
	_edge_tree_items.clear()
	var root := _edge_tree.create_item()
	if edges.is_empty():
		var empty_item := _edge_tree.create_item(root)
		empty_item.set_text(0, "")
		empty_item.set_text(1, "(no edges)")
		empty_item.set_text(2, "")
		return
	# Sort by edge id ascending.
	var sorted: Array = edges.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("id", 0)) < int(b.get("id", 0))
	)
	for edge_info in sorted:
		if not (edge_info is Dictionary):
			continue
		var edge_id := int(edge_info.get("id", 0))
		var kind := str(edge_info.get("kind", "straight"))
		var measure_text := ""
		if kind == "circle":
			measure_text = "%.1f" % float(edge_info.get("radius", 0.0))
		else:
			measure_text = "%.1f" % float(edge_info.get("length", 0.0))
		var item := _edge_tree.create_item(root)
		item.set_text(0, str(edge_id))
		item.set_metadata(0, edge_id)
		item.set_text(1, measure_text)
		item.set_text(2, kind)
		_edge_tree_items[edge_id] = item


## Push a new edge selection to the host and geometry overlays, then sync the tree.
## Single entry point for all callers (overlay clicks, Prev/Next, Clear).
func select_edge(edge_id: int) -> void:
	if _panel._annotation_host != null:
		_panel._annotation_host.set_selected_edge_id(edge_id)
	for ov_id in _panel._geometry_overlays.keys():
		var ov: Control = _panel._geometry_overlays[ov_id] as Control
		if ov != null and ov.has_method("set_selected_edge"):
			ov.call("set_selected_edge", edge_id)
	update_tree_selection()


func _on_edge_tree_item_selected() -> void:
	if _suppress_tree_selection or _edge_tree == null:
		return
	var item: TreeItem = _edge_tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if meta == null:
		return
	var edge_id := int(meta)
	if _panel._annotation_host != null:
		_panel._annotation_host.set_selected_edge_id(edge_id)
	for ov_id in _panel._geometry_overlays.keys():
		var ov: Control = _panel._geometry_overlays[ov_id] as Control
		if ov != null and ov.has_method("set_selected_edge"):
			ov.call("set_selected_edge", edge_id)


## Update the tree's highlighted row to match the host's current edge selection.
## Reads from host; writes no panel-local state.
func update_tree_selection() -> void:
	if _edge_tree == null or _panel._annotation_host == null:
		return
	var edge_id: int = _panel._annotation_host.get_selected_edge_id()
	_suppress_tree_selection = true
	if edge_id != -1 and _edge_tree_items.has(edge_id):
		var item: TreeItem = _edge_tree_items[edge_id]
		_edge_tree.set_selected(item, 0)
		_edge_tree.scroll_to_item(item, true)
	else:
		_edge_tree.deselect_all()
	_suppress_tree_selection = false


func _on_prev_edge_pressed() -> void:
	_step_selected(-1)


func _on_next_edge_pressed() -> void:
	_step_selected(1)


func _on_clear_edge_pressed() -> void:
	select_edge(-1)


func _step_selected(delta: int) -> void:
	var ids: Array = []
	for edge_info in _panel._edge_registry:
		if edge_info is Dictionary:
			ids.append(int(edge_info.get("id", 0)))
	ids.sort()
	var current_id: int = -1
	if _panel._annotation_host != null:
		current_id = _panel._annotation_host.get_selected_edge_id()
	if ids.is_empty():
		select_edge(-1)
		return
	if current_id == -1:
		select_edge(ids[0] if delta >= 0 else ids[ids.size() - 1])
		return
	var idx := ids.find(current_id)
	if idx == -1:
		select_edge(ids[0])
		return
	var next_idx := posmod(idx + delta, ids.size())
	select_edge(ids[next_idx])


## Push the current mesh data + per-pane cameras to every Cad_GeometryOverlay.
## Called whenever a new mesh arrives from the DSL→mesh bridge.
func push_to_overlays() -> void:
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	var view_cameras := {
		"top":   _panel.get_node_or_null(grid + "/TopView/SubViewport/OrbitCamera") as Camera3D,
		"front": _panel.get_node_or_null(grid + "/FrontView/SubViewport/OrbitCamera") as Camera3D,
		"right": _panel.get_node_or_null(grid + "/RightView/SubViewport/OrbitCamera") as Camera3D,
		"iso":   _panel.get_node_or_null(grid + "/IsoView/SubViewport/OrbitCamera") as Camera3D,
		"single": _panel._single_view_camera,
	}
	for ov_id in _panel._geometry_overlays.keys():
		var ov: Control = _panel._geometry_overlays[ov_id] as Control
		if DEBUG_EDGE_PICK:
			print("[edge-pick] connect ov_id=%s ov=%s script=%s" % [
				ov_id,
				str(ov),
				str(ov.get_script()) if ov != null else "<null-node>",
			])
		if ov == null:
			continue
		if ov.has_method("set_mesh_data"):
			ov.call("set_mesh_data", _panel._last_mesh_data)
		var cam: Camera3D = view_cameras.get(ov_id, null)
		if ov.has_method("set_camera"):
			ov.call("set_camera", cam)
		if ov.has_method("set_edge_registry"):
			ov.call("set_edge_registry", _panel._edge_registry)
		# Connect the overlay's pick signal to the panel's selection handler.
		# Idempotent — repeated push_to_overlays() calls
		# (re-evaluate, layout swap) MUST NOT stack callbacks.
		var has_sig: bool = ov.has_signal("edge_selected")
		var already: bool = has_sig and ov.edge_selected.is_connected(_panel._on_edge_selected)
		if has_sig and not already:
			ov.edge_selected.connect(_panel._on_edge_selected)
		if DEBUG_EDGE_PICK:
			print("[edge-pick]   has_signal=%s already_connected=%s mouse_filter=%s" % [
				str(has_sig),
				str(already),
				str(ov.mouse_filter),
			])
	_panel._apply_mesh_visibility()
