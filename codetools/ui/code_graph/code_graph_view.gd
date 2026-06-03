extends Control
## Off-tree plugin script: NO class_name
## Root view for code-magic visualizer. Manages navigation between levels.
## Portable — instance this node (or load the panel scene) and call load_graph()
## or load_from_dict() on the GraphData it creates.
##
## viz_mcp_server has been intentionally excluded: this panel must NOT open any
## TCP server or network socket. All data flows in via load_graph() / load_from_dict().

const GraphDataScript = preload("graph_data.gd")
const Level1Script = preload("level1_boundary_view.gd")
const Level2Script = preload("level2_component_view.gd")
const Level3Script = preload("level3_symbol_view.gd")

signal node_selected(data: Dictionary)

var _graph_data: GraphDataScript
var _current_level := 0  # 0=root, 1=boundary, 2=component, 3=symbol
var _source_base_path := ""
var _project_name := "Project"
var _current_boundary := ""
var _current_symbol_name := ""
var _ann_dialog: Window
var _ann_dialog_text: TextEdit
var _ann_dialog_node: Dictionary = {}
var _diff_data: Dictionary = {}  # {file_path: {before_content, after_content, status}}
var _diff_file_list: Array = []  # ordered list of changed file paths
var _show_changed_only := false

# UI structure
var _root_view: Control          # Level 0: project name
var _split: HSplitContainer      # Levels 1-3: outline | content | inspector
var _breadcrumb_bar: HBoxContainer
var _filter_bar: HBoxContainer
var _outline_panel: VBoxContainer
var _outline_tree: Tree
var _outline_search: LineEdit
var _center_panel: Control       # holds all level views stacked
var _inspector_panel: ScrollContainer
var _inspector_content: VBoxContainer
var _level1: Level1Script
var _level2: Level2Script
var _level3: Level3Script


func _ready() -> void:
	# ── Root view (Level 0) ──
	_root_view = Control.new()
	_root_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root_view)

	# ── Three-column layout for Levels 1-3 ──
	_split = HSplitContainer.new()
	_split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_split.visible = false
	add_child(_split)

	# Left: collapse button + outline tree
	var outline_wrapper := HBoxContainer.new()
	outline_wrapper.add_theme_constant_override("separation", 0)
	_split.add_child(outline_wrapper)

	var outline_toggle := Button.new()
	outline_toggle.text = "<<"
	outline_toggle.flat = true
	outline_toggle.add_theme_font_size_override("font_size", 11)
	outline_toggle.custom_minimum_size.x = 20
	outline_toggle.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	outline_toggle.pressed.connect(func() -> void:
		_outline_panel.visible = not _outline_panel.visible
		outline_toggle.text = ">>" if not _outline_panel.visible else "<<"
	)
	outline_wrapper.add_child(outline_toggle)

	_outline_panel = VBoxContainer.new()
	_outline_panel.custom_minimum_size.x = 240
	_outline_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var outline_header := Label.new()
	outline_header.text = "Outline"
	outline_header.add_theme_font_size_override("font_size", 12)
	outline_header.add_theme_color_override("font_color", Color(0.91, 0.27, 0.38))
	_outline_panel.add_child(outline_header)
	_outline_search = LineEdit.new()
	_outline_search.placeholder_text = "Filter..."
	_outline_search.add_theme_font_size_override("font_size", 11)
	_outline_search.text_changed.connect(_on_outline_search)
	_outline_panel.add_child(_outline_search)

	var changed_toggle := Button.new()
	changed_toggle.text = "Changed only"
	changed_toggle.toggle_mode = true
	changed_toggle.add_theme_font_size_override("font_size", 11)
	changed_toggle.add_theme_color_override("font_color", Color(0.99, 0.77, 0.1))
	changed_toggle.toggled.connect(func(pressed: bool) -> void:
		_show_changed_only = pressed
		_build_outline()
	)
	_outline_panel.add_child(changed_toggle)

	_outline_tree = Tree.new()
	_outline_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_outline_tree.hide_root = true
	_outline_tree.columns = 1
	_outline_tree.item_selected.connect(_on_outline_item_selected)
	_outline_tree.item_activated.connect(_on_outline_item_activated)
	_outline_panel.add_child(_outline_tree)
	outline_wrapper.add_child(_outline_panel)

	# Center column: breadcrumb + level views
	var center_column := VBoxContainer.new()
	center_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.add_child(center_column)

	# Breadcrumb bar
	_breadcrumb_bar = HBoxContainer.new()
	_breadcrumb_bar.add_theme_constant_override("separation", 4)
	center_column.add_child(_breadcrumb_bar)

	# Filter bar (kind toggles + edge type toggles)
	_filter_bar = HBoxContainer.new()
	_filter_bar.add_theme_constant_override("separation", 3)
	center_column.add_child(_filter_bar)

	# Center content + inspector in a split
	var center_split := HSplitContainer.new()
	center_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_column.add_child(center_split)

	_center_panel = Control.new()
	_center_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_center_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_center_panel.clip_contents = true
	center_split.add_child(_center_panel)

	# Right: inspector with collapse toggle
	var inspector_wrapper := HBoxContainer.new()
	inspector_wrapper.add_theme_constant_override("separation", 0)
	center_split.add_child(inspector_wrapper)

	var inspector_toggle := Button.new()
	inspector_toggle.text = ">>"
	inspector_toggle.flat = true
	inspector_toggle.add_theme_font_size_override("font_size", 11)
	inspector_toggle.custom_minimum_size.x = 20
	inspector_toggle.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	inspector_toggle.pressed.connect(func() -> void:
		_inspector_panel.visible = not _inspector_panel.visible
		inspector_toggle.text = "<<" if not _inspector_panel.visible else ">>"
	)
	inspector_wrapper.add_child(inspector_toggle)

	_inspector_panel = ScrollContainer.new()
	_inspector_panel.custom_minimum_size.x = 280
	_inspector_content = VBoxContainer.new()
	_inspector_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_panel.add_child(_inspector_content)
	inspector_wrapper.add_child(_inspector_panel)
	_show_inspector_empty()

	# ── Create level views inside center panel ──
	_level1 = Level1Script.new()
	_level1.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_level1.visible = false
	_center_panel.add_child(_level1)

	_level2 = Level2Script.new()
	_level2.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_level2.visible = false
	_center_panel.add_child(_level2)

	_level3 = Level3Script.new()
	_level3.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_level3.visible = false
	_center_panel.add_child(_level3)

	# Wire signals
	_level1.component_clicked.connect(_on_component_clicked)
	_level1.component_inspected.connect(func(n: Dictionary) -> void:
		if n.is_empty(): _show_inspector_empty()
		else: _show_inspector_node(n)
	)
	_level1.boundary_clicked.connect(_on_boundary_clicked)
	_level2.symbol_clicked.connect(_on_symbol_clicked)
	_level2.symbol_inspected.connect(func(n: Dictionary) -> void:
		if n.is_empty(): _show_inspector_empty()
		else: _show_inspector_node(n)
	)
	_level2.annotate_requested.connect(_on_annotate_node)
	_level2.back_requested.connect(func() -> void: _show_level(1))
	_level3.next_diff_requested.connect(func() -> void: _navigate_diff(1))
	_level3.prev_diff_requested.connect(func() -> void: _navigate_diff(-1))
	_level3.back_requested.connect(func() -> void: _show_level(2))

	# Annotation dialog (shared across levels)
	_ann_dialog = Window.new()
	_ann_dialog.title = "Add Annotation"
	_ann_dialog.size = Vector2i(400, 200)
	_ann_dialog.visible = false
	_ann_dialog.transient = true
	_ann_dialog.exclusive = true
	var ann_vbox := VBoxContainer.new()
	ann_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ann_vbox.add_theme_constant_override("margin_left", 12)
	ann_vbox.add_theme_constant_override("margin_top", 12)
	ann_vbox.add_theme_constant_override("margin_right", 12)
	var ann_label := Label.new()
	ann_label.text = "Annotation:"
	ann_label.add_theme_font_size_override("font_size", 12)
	ann_vbox.add_child(ann_label)
	_ann_dialog_text = TextEdit.new()
	_ann_dialog_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ann_dialog_text.placeholder_text = "Describe..."
	ann_vbox.add_child(_ann_dialog_text)
	var ann_btns := HBoxContainer.new()
	ann_btns.alignment = BoxContainer.ALIGNMENT_END
	var ann_cancel := Button.new()
	ann_cancel.text = "Cancel"
	ann_cancel.pressed.connect(func() -> void: _ann_dialog.hide())
	ann_btns.add_child(ann_cancel)
	var ann_ok := Button.new()
	ann_ok.text = "Add"
	ann_ok.pressed.connect(_on_annotation_dialog_confirmed)
	ann_btns.add_child(ann_ok)
	ann_vbox.add_child(ann_btns)
	_ann_dialog.add_child(ann_vbox)
	add_child(_ann_dialog)

	# NOTE: viz_mcp_server intentionally excluded — no TCP/network socket opened here.


func load_graph(json_path: String, source_base: String = "") -> void:
	_source_base_path = source_base
	_graph_data = GraphDataScript.new()
	if not _graph_data.load_from_file(json_path):
		push_error("CodeGraphView: failed to load %s" % json_path)
		return
	_finish_load(json_path)


func load_from_dict(data: Dictionary, source_base: String = "", project_name_hint: String = "") -> void:
	## Load graph from an in-memory Dictionary (no file I/O). Call this from the
	## panel controller after receiving data via an MCP tool response.
	_source_base_path = source_base
	_graph_data = GraphDataScript.new()
	if not _graph_data.load_from_dict(data):
		push_error("CodeGraphView: failed to load from dict")
		return
	# Use caller-supplied name or fall back to stats
	_project_name = project_name_hint
	if _project_name.is_empty() and _graph_data.stats.has("project_name"):
		_project_name = str(_graph_data.stats.project_name)
	if _project_name.is_empty():
		_project_name = "Project"
	_apply_graph()


func _finish_load(json_path: String) -> void:
	## Shared post-load wiring used by load_graph().
	# Derive project name from stats or path
	_project_name = json_path.get_file().get_basename()
	if _graph_data.stats.has("project_name"):
		_project_name = str(_graph_data.stats.project_name)

	# Load annotations from disk — share across all levels
	var ann_file_path: String = json_path.trim_suffix(".json") + ".annotations.json"
	_level3.annotation_data.file_path = ann_file_path
	if _level3.annotation_data.load_from_file(ann_file_path):
		print("CodeGraphView: loaded annotations from %s" % ann_file_path)
	_level1.annotation_data = _level3.annotation_data
	_level2.annotation_data = _level3.annotation_data

	_apply_graph()


func _apply_graph() -> void:
	## Wire loaded graph data into all level views and show Level 0.
	_level1.load_graph(_graph_data)
	_level2.load_graph(_graph_data)
	_build_root_view()
	_show_level(0)


func _show_level(level: int) -> void:
	_current_level = level

	# Root vs three-column
	_root_view.visible = level == 0
	_split.visible = level > 0

	# Level views
	_level1.visible = level == 1
	_level2.visible = level == 2
	_level3.visible = level == 3

	# Rebuild outline, breadcrumbs, and filters for current level
	if level > 0:
		_build_outline()
		_build_breadcrumbs()
		_build_filters()
		_show_inspector_empty()

	# Hide filters on Level 3 (code view doesn't need them)
	if _filter_bar:
		_filter_bar.visible = level in [1, 2]


# ── Root view (Level 0) ──

func _build_root_view() -> void:
	for child in _root_view.get_children():
		child.queue_free()

	# Dark background
	var bg := ColorRect.new()
	bg.color = Color(0.102, 0.102, 0.18)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_view.add_child(bg)

	# Centered project name in a dotted box
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_view.add_child(center)

	var box := Control.new()
	box.custom_minimum_size = Vector2(300, 150)
	center.add_child(box)

	# We'll draw the dotted box in _draw of root_view
	# For now use a Panel with a label
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.059, 0.204, 0.376, 0.15)
	style.border_color = Color(0.059, 0.204, 0.376)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(30)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER

	var name_label := Label.new()
	name_label.text = _project_name
	name_label.add_theme_font_size_override("font_size", 28)
	name_label.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_label)

	var hint_label := Label.new()
	hint_label.text = "Click to explore"
	hint_label.add_theme_font_size_override("font_size", 12)
	hint_label.add_theme_color_override("font_color", Color(0.38, 0.38, 0.5))
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint_label)

	if _graph_data:
		var stats_label := Label.new()
		var s: Dictionary = _graph_data.stats
		stats_label.text = "%d files · %d symbols · %d edges" % [
			int(s.get("files", 0)), int(s.get("symbols", 0)), int(s.get("edges", 0))]
		stats_label.add_theme_font_size_override("font_size", 10)
		stats_label.add_theme_color_override("font_color", Color(0.31, 0.31, 0.44))
		stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(stats_label)

	panel.add_child(vbox)
	box.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Click handler
	var click_area := Button.new()
	click_area.flat = true
	click_area.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	click_area.pressed.connect(func() -> void: _show_level(1))
	_root_view.add_child(click_area)


# ── Outline tree ──

func _build_outline() -> void:
	_outline_tree.clear()
	if not _graph_data:
		return

	var root: TreeItem = _outline_tree.create_item()

	match _current_level:
		1:
			# Show boundaries > files > classes
			var boundaries: Dictionary = _graph_data.get_boundaries()
			for bname: String in boundaries:
				var b_item: TreeItem = _outline_tree.create_item(root)
				b_item.set_text(0, bname)
				b_item.set_custom_color(0, Color(0.494, 0.784, 0.89))
				b_item.set_metadata(0, {"type": "boundary", "name": bname})

				var bdata: Dictionary = boundaries[bname]
				for file_path: String in bdata.files:
					var f_item: TreeItem = _outline_tree.create_item(b_item)
					f_item.set_text(0, file_path.get_file())
					f_item.set_custom_color(0, Color(0.69, 0.69, 0.69))
					f_item.set_metadata(0, {"type": "file", "path": file_path})

					for node: Dictionary in _graph_data.get_nodes_in_file(file_path):
						if str(node.kind) == "class":
							var c_item: TreeItem = _outline_tree.create_item(f_item)
							c_item.set_text(0, str(node.name))
							c_item.set_custom_color(0, _graph_data.get_kind_color("class"))
							c_item.set_metadata(0, {"type": "class", "id": str(node.id)})
					f_item.collapsed = true
				b_item.collapsed = false
		2, 3:
			# Show files > all symbols (with changed file indicators)
			for file_path: String in _graph_data.get_file_paths():
				var is_changed: bool = _diff_data.has(file_path)
				if _show_changed_only and not is_changed:
					continue

				var f_item: TreeItem = _outline_tree.create_item(root)
				var file_label: String = file_path.get_file()
				if is_changed:
					file_label = "● " + file_label
				f_item.set_text(0, file_label)
				f_item.set_custom_color(0, Color(0.99, 0.77, 0.1) if is_changed else Color(0.69, 0.69, 0.69))
				f_item.set_metadata(0, {"type": "file", "path": file_path})

				var symbols: Array = _graph_data.get_nodes_in_file(file_path)
				symbols.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
					return int(a.line_start) < int(b.line_start))
				for node: Dictionary in symbols:
					var s_item: TreeItem = _outline_tree.create_item(f_item)
					s_item.set_text(0, str(node.name))
					s_item.set_custom_color(0, _graph_data.get_kind_color(str(node.kind)))
					s_item.set_metadata(0, {"type": "symbol", "id": str(node.id)})
				f_item.collapsed = true


func _on_outline_search(text: String) -> void:
	var query: String = text.to_lower()
	_filter_outline_tree(_outline_tree.get_root(), query)


func _filter_outline_tree(item: TreeItem, query: String) -> bool:
	if not item:
		return false
	var any_visible := false
	var child: TreeItem = item.get_first_child()
	while child:
		var child_visible: bool = _filter_outline_tree(child, query)
		var text: String = child.get_text(0).to_lower()
		var match: bool = query.is_empty() or text.contains(query)
		var vis: bool = match or child_visible
		child.visible = vis
		if not query.is_empty() and vis:
			child.collapsed = false
		if vis:
			any_visible = true
		child = child.get_next()
	return any_visible


func _on_outline_item_selected() -> void:
	## Single click: show inspector + highlight in current graph view.
	var item: TreeItem = _outline_tree.get_selected()
	if not item:
		return
	var meta: Variant = item.get_metadata(0)
	if not meta is Dictionary:
		return
	var info: Dictionary = meta
	var item_type: String = str(info.get("type", ""))

	match item_type:
		"symbol", "class":
			var node: Dictionary = _graph_data.get_node_by_id(str(info.id))
			if not node.is_empty():
				_show_inspector_node(node)
				# Highlight in Level 2 graph if visible
				if _current_level == 2:
					_level2._select(str(info.id))
					_level2.queue_redraw()
		"boundary":
			# Just show stats in inspector, don't drill down
			_show_inspector_empty()
		"file":
			_show_inspector_empty()


func _on_outline_item_activated() -> void:
	## Double click / Enter: drill down to the next level.
	var item: TreeItem = _outline_tree.get_selected()
	if not item:
		return
	var meta: Variant = item.get_metadata(0)
	if not meta is Dictionary:
		return
	var info: Dictionary = meta
	var item_type: String = str(info.get("type", ""))

	match item_type:
		"boundary":
			_on_boundary_clicked(str(info.name))
		"symbol", "class":
			var node: Dictionary = _graph_data.get_node_by_id(str(info.id))
			if not node.is_empty():
				_on_symbol_clicked(node)


# ── Inspector panel ──

func _show_inspector_empty() -> void:
	for child in _inspector_content.get_children():
		child.queue_free()
	var label := Label.new()
	label.text = "Click a node to inspect."
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(0.38, 0.38, 0.5))
	_inspector_content.add_child(label)


func _show_inspector_node(node: Dictionary) -> void:
	for child in _inspector_content.get_children():
		child.queue_free()

	_add_inspector_label("FILE")
	_add_inspector_value(str(node.file))

	_add_inspector_label("SYMBOL")
	var kind_color: Color = _graph_data.get_kind_color(str(node.get("kind", "")))
	_add_inspector_value("%s (%s)" % [str(node.name), str(node.get("kind", ""))], kind_color)

	if str(node.get("signature", "")) != "":
		_add_inspector_label("SIGNATURE")
		_add_inspector_value(str(node.signature), Color(0.494, 0.784, 0.89))

	_add_inspector_label("LINES")
	_add_inspector_value("%d - %d" % [int(node.get("line_start", 0)), int(node.get("line_end", 0))])

	_add_inspector_label("FAN-IN / FAN-OUT")
	_add_inspector_value("%d in / %d out" % [int(node.get("fan_in", 0)), int(node.get("fan_out", 0))])

	if str(node.get("description", "")) != "":
		_add_inspector_label("DESCRIPTION")
		var desc := Label.new()
		desc.text = str(node.description)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.add_theme_font_size_override("font_size", 12)
		desc.add_theme_color_override("font_color", Color(0.878, 0.878, 0.878))
		_inspector_content.add_child(desc)

	# Edges
	var edges: Dictionary = _graph_data.get_edges_for_node(str(node.id))
	var incoming: Array = edges.incoming
	if incoming.size() > 0:
		_add_inspector_label("CALLERS (%d)" % incoming.size())
		var shown := 0
		for e: Dictionary in incoming:
			if shown >= 15:
				_add_inspector_value("... +%d more" % (incoming.size() - 15), Color(0.38, 0.38, 0.5))
				break
			var src: Dictionary = _graph_data.get_node_by_id(str(e.source))
			var name: String = str(src.name) if not src.is_empty() else "?"
			_add_inspector_edge("<- %s [%s]" % [name, str(e.type)], str(e.source))
			shown += 1

	var outgoing: Array = edges.outgoing
	if outgoing.size() > 0:
		_add_inspector_label("CALLS (%d)" % outgoing.size())
		var shown := 0
		for e: Dictionary in outgoing:
			if shown >= 15:
				_add_inspector_value("... +%d more" % (outgoing.size() - 15), Color(0.38, 0.38, 0.5))
				break
			var tgt: Dictionary = _graph_data.get_node_by_id(str(e.target))
			var name: String = str(tgt.name) if not tgt.is_empty() else "?"
			_add_inspector_edge("-> %s [%s]" % [name, str(e.type)], str(e.target))
			shown += 1


func _add_inspector_label(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.91, 0.27, 0.38))
	_inspector_content.add_child(label)


func _add_inspector_value(text: String, color := Color(0.878, 0.878, 0.878)) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", color)
	_inspector_content.add_child(label)


func _add_inspector_edge(text: String, target_id: String) -> void:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", 12)
	btn.add_theme_color_override("font_color", Color(0.69, 0.69, 0.69))
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.pressed.connect(func() -> void:
		var node: Dictionary = _graph_data.get_node_by_id(target_id)
		if not node.is_empty():
			_show_inspector_node(node)
	)
	_inspector_content.add_child(btn)


# ── Filters ──

func _build_filters() -> void:
	if not _filter_bar or not _graph_data:
		return
	for child in _filter_bar.get_children():
		child.queue_free()

	# Kind toggles
	var kind_label := Label.new()
	kind_label.text = "Show:"
	kind_label.add_theme_font_size_override("font_size", 11)
	kind_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	_filter_bar.add_child(kind_label)

	for kind: String in GraphDataScript.KIND_COLORS:
		var btn := Button.new()
		btn.text = kind
		btn.toggle_mode = true
		btn.button_pressed = _graph_data.active_kinds.get(kind, false)
		btn.add_theme_font_size_override("font_size", 11)
		btn.toggled.connect(func(pressed: bool) -> void:
			_graph_data.active_kinds[kind] = pressed
			_on_filter_changed()
		)
		_filter_bar.add_child(btn)

	# Separator
	var sep := VSeparator.new()
	_filter_bar.add_child(sep)

	# Edge type toggles
	var edge_label := Label.new()
	edge_label.text = "Edges:"
	edge_label.add_theme_font_size_override("font_size", 11)
	edge_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	_filter_bar.add_child(edge_label)

	for etype: String in GraphDataScript.EDGE_COLORS:
		var btn := Button.new()
		btn.text = etype
		btn.toggle_mode = true
		btn.button_pressed = _graph_data.active_edge_types.get(etype, false)
		btn.add_theme_font_size_override("font_size", 11)
		btn.toggled.connect(func(pressed: bool) -> void:
			_graph_data.active_edge_types[etype] = pressed
			_on_filter_changed()
		)
		_filter_bar.add_child(btn)


func _on_filter_changed() -> void:
	# Rebuild the current level's view
	match _current_level:
		1:
			_level1.queue_redraw()
		2:
			_level2._rebuild()
			_level2.queue_redraw()


# ── Breadcrumbs ──

func _build_breadcrumbs() -> void:
	for child in _breadcrumb_bar.get_children():
		child.queue_free()

	# Root link
	var root_btn := Button.new()
	root_btn.text = _project_name
	root_btn.flat = true
	root_btn.add_theme_font_size_override("font_size", 11)
	root_btn.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89))
	root_btn.pressed.connect(func() -> void: _show_level(0))
	_breadcrumb_bar.add_child(root_btn)

	if _current_level >= 1:
		_add_breadcrumb_sep()
		var l1_btn := Button.new()
		l1_btn.text = "Boundaries"
		l1_btn.flat = true
		l1_btn.add_theme_font_size_override("font_size", 11)
		if _current_level > 1:
			l1_btn.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89))
			l1_btn.pressed.connect(func() -> void: _show_level(1))
		else:
			l1_btn.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89))
		_breadcrumb_bar.add_child(l1_btn)

	if _current_level >= 2 and _current_boundary != "":
		_add_breadcrumb_sep()
		var l2_btn := Button.new()
		l2_btn.text = _current_boundary
		l2_btn.flat = true
		l2_btn.add_theme_font_size_override("font_size", 11)
		if _current_level > 2:
			l2_btn.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89))
			var bname: String = _current_boundary
			l2_btn.pressed.connect(func() -> void:
				_level2.load_graph(_graph_data, bname)
				_show_level(2)
			)
		else:
			l2_btn.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89))
		_breadcrumb_bar.add_child(l2_btn)

	if _current_level >= 3 and _current_symbol_name != "":
		_add_breadcrumb_sep()
		var l3_label := Label.new()
		l3_label.text = _current_symbol_name
		l3_label.add_theme_font_size_override("font_size", 11)
		l3_label.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89))
		_breadcrumb_bar.add_child(l3_label)


func _add_breadcrumb_sep() -> void:
	var sep := Label.new()
	sep.text = ">"
	sep.add_theme_font_size_override("font_size", 11)
	sep.add_theme_color_override("font_color", Color(0.25, 0.25, 0.38))
	_breadcrumb_bar.add_child(sep)


# ── Level navigation ──

func _on_boundary_clicked(boundary_name: String) -> void:
	_current_boundary = boundary_name
	_level2.load_graph(_graph_data, boundary_name)
	_show_level(2)


func _on_component_clicked(component_name: String, boundary_name: String) -> void:
	_current_boundary = boundary_name
	_level2.load_graph(_graph_data, boundary_name)
	_show_level(2)


func _on_symbol_clicked(node_data: Dictionary) -> void:
	_current_symbol_name = str(node_data.get("name", ""))
	var file_rel: String = str(node_data.get("file", ""))
	var full_path: String = _source_base_path.path_join(file_rel) if _source_base_path != "" else file_rel
	var line_start: int = int(node_data.get("line_start", 0))
	var line_end: int = int(node_data.get("line_end", 0))

	_level3.load_symbol(_graph_data, str(node_data.id), full_path, line_start, line_end)

	# If we have diff data for this file, load both before and after, switch to diff mode
	if _diff_data.has(file_rel):
		var diff_info: Dictionary = _diff_data[file_rel]
		_level3.before_lines = str(diff_info.before_content).split("\n")
		_level3.after_lines = str(diff_info.after_content).split("\n")
		_level3._set_mode(Level3Script.Mode.DIFF)

	_show_level(3)
	_show_inspector_node(node_data)
	node_selected.emit(node_data)


func _on_diff_data_loaded(diff_files: Array) -> void:
	## Store diff data, rebuild outline to show change indicators.
	_diff_data.clear()
	_diff_file_list.clear()
	for f: Dictionary in diff_files:
		var path: String = str(f.path)
		_diff_data[path] = f
		_diff_file_list.append(path)
	print("Diff data loaded: %d files" % diff_files.size())
	# Refresh views
	if _current_level == 2:
		_level2.queue_redraw()
	if _current_level > 0:
		_build_outline()


func has_diff_for_file(file_path: String) -> bool:
	return _diff_data.has(file_path)


func _navigate_diff(direction: int) -> void:
	## Navigate to next (+1) or previous (-1) changed file.
	if _diff_file_list.is_empty():
		return
	# Find current file in the list
	var current_file: String = _level3.file_relative_path
	var current_idx: int = _diff_file_list.find(current_file)
	if current_idx < 0:
		current_idx = 0
	else:
		current_idx = (current_idx + direction) % _diff_file_list.size()
		if current_idx < 0:
			current_idx = _diff_file_list.size() - 1

	var next_file: String = _diff_file_list[current_idx]
	# Find a symbol in this file to navigate to
	var symbols: Array = _graph_data.get_nodes_in_file(next_file) if _graph_data else []
	if symbols.size() > 0:
		_on_symbol_clicked(symbols[0])
	else:
		# No indexed symbol — load the file directly
		var diff_info: Dictionary = _diff_data[next_file]
		var full_path: String = _source_base_path.path_join(next_file) if _source_base_path != "" else next_file
		_level3.load_symbol(_graph_data, "", full_path, 1, 50)
		_level3.before_lines = str(diff_info.before_content).split("\n")
		_level3.after_lines = str(diff_info.after_content).split("\n")
		_level3._set_mode(Level3Script.Mode.DIFF)


func _on_annotate_node(node_data: Dictionary) -> void:
	## Ctrl+click on a node in Level 2 — open annotation dialog.
	_ann_dialog_node = node_data
	_ann_dialog.title = "Annotate: %s" % str(node_data.get("name", ""))
	_ann_dialog_text.text = ""
	_ann_dialog.popup_centered()


func _on_annotation_dialog_confirmed() -> void:
	var text: String = _ann_dialog_text.text.strip_edges()
	if text.is_empty() or _ann_dialog_node.is_empty():
		_ann_dialog.hide()
		return
	var file_rel: String = str(_ann_dialog_node.get("file", ""))
	var line_start: int = int(_ann_dialog_node.get("line_start", 1))
	_level3.annotation_data.add_text(file_rel, line_start, text, "human")
	if _level3.annotation_data.file_path != "":
		_level3.annotation_data.save_to_file(_level3.annotation_data.file_path)
	_ann_dialog.hide()
	# Refresh current level to show badge
	if _current_level == 1:
		_level1.queue_redraw()
	elif _current_level == 2:
		_level2.queue_redraw()
