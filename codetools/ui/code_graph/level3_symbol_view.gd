extends Control
## Off-tree plugin script: NO class_name
## Level 3: Symbol/LoC view with Explore, Annotate, and Diff modes.
## Shows source code with the selected function focused.

const GraphDataScript = preload("graph_data.gd")
const AnnotationDataScript = preload("annotation_data.gd")

signal back_requested()
signal next_diff_requested()
signal prev_diff_requested()

enum Mode { CODE, DIFF }  # CODE = explore + annotate merged

var graph_data: GraphDataScript
var annotation_data: AnnotationDataScript
var current_mode: Mode = Mode.CODE
var symbol_id := ""
var file_path := ""
var file_relative_path := ""  # for annotation matching
var func_start := 0
var func_end := 0
var before_lines: PackedStringArray = []
var after_lines: PackedStringArray = []

# Annotation interaction state
var _ann_selecting := false
var _ann_select_start := 0
var _ann_select_end := 0

# Annotation arrow overlay state
var _ann_gutter_markers: Dictionary = {}  # ann_id -> Control
var _ann_panel_controls: Dictionary = {}  # ann_id -> Control
var _ann_overlay: Control = null
var _ann_line_hboxes: Dictionary = {}  # ann_id -> Array of HBoxContainer

# UI elements
var _mode_bar: HBoxContainer
var _split: HSplitContainer
var _info_panel: VBoxContainer
var _info_scroll: ScrollContainer
var _code_scroll: ScrollContainer
var _code_container: VBoxContainer
var _code_area_parent: VBoxContainer  # toolbar + scroll area
var _fixed_toolbar: HBoxContainer  # stays fixed above scroll
var _current_code_area: Control  # currently active code area (scroll or annotate split)
var _ann_input_dialog: Window
var _ann_input_text: TextEdit
var _context_menu: PopupMenu
var _context_line: int = 0  # line number for context menu actions


func _ready() -> void:
	# Top: mode buttons
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(vbox)

	_mode_bar = HBoxContainer.new()
	_mode_bar.add_theme_constant_override("separation", 4)
	vbox.add_child(_mode_bar)

	var btn_code := Button.new()
	btn_code.text = "Code"
	btn_code.toggle_mode = true
	btn_code.button_pressed = true
	btn_code.toggled.connect(func(p: bool) -> void: if p: _set_mode(Mode.CODE))
	_mode_bar.add_child(btn_code)

	var btn_diff := Button.new()
	btn_diff.text = "Diff"
	btn_diff.toggle_mode = true
	btn_diff.toggled.connect(func(p: bool) -> void: if p: _set_mode(Mode.DIFF))
	_mode_bar.add_child(btn_diff)

	var btn_group := ButtonGroup.new()
	btn_code.button_group = btn_group
	btn_diff.button_group = btn_group

	# Breadcrumb
	var breadcrumb := Label.new()
	breadcrumb.text = "docket > Core > DocketDB > execute_query"
	breadcrumb.add_theme_font_size_override("font_size", 11)
	breadcrumb.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89))
	_mode_bar.add_child(breadcrumb)

	# Back button
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.add_theme_font_size_override("font_size", 11)
	back_btn.pressed.connect(func() -> void: back_requested.emit())
	_mode_bar.add_child(back_btn)

	# Main split: info panel + code
	_split = HSplitContainer.new()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_split)

	_info_scroll = ScrollContainer.new()
	# Info panel with collapse toggle
	var info_wrapper := HBoxContainer.new()
	info_wrapper.add_theme_constant_override("separation", 0)
	_split.add_child(info_wrapper)

	var info_toggle := Button.new()
	info_toggle.text = "<<"
	info_toggle.flat = true
	info_toggle.add_theme_font_size_override("font_size", 11)
	info_toggle.custom_minimum_size.x = 20
	info_toggle.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	info_toggle.pressed.connect(func() -> void:
		_info_scroll.visible = not _info_scroll.visible
		info_toggle.text = ">>" if not _info_scroll.visible else "<<"
	)
	info_wrapper.add_child(info_toggle)

	_info_scroll.custom_minimum_size.x = 280
	info_wrapper.add_child(_info_scroll)

	_info_panel = VBoxContainer.new()
	_info_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_scroll.add_child(_info_panel)

	# Code area: VBox with fixed toolbar + scrollable code below
	_code_area_parent = VBoxContainer.new()
	_code_area_parent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_area_parent.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.add_child(_code_area_parent)

	# Fixed toolbar (populated in _render_annotate, stays outside scroll)
	_fixed_toolbar = HBoxContainer.new()
	_code_area_parent.add_child(_fixed_toolbar)

	_code_scroll = ScrollContainer.new()
	_code_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code_area_parent.add_child(_code_scroll)

	_code_container = VBoxContainer.new()
	_code_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_scroll.add_child(_code_container)

	_current_code_area = _code_scroll

	# Annotation input dialog
	_ann_input_dialog = Window.new()
	_ann_input_dialog.title = "Add Annotation"
	_ann_input_dialog.size = Vector2i(400, 250)
	_ann_input_dialog.visible = false
	_ann_input_dialog.transient = true
	_ann_input_dialog.exclusive = true

	var dialog_vbox := VBoxContainer.new()
	dialog_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dialog_vbox.add_theme_constant_override("margin_left", 12)
	dialog_vbox.add_theme_constant_override("margin_top", 12)
	dialog_vbox.add_theme_constant_override("margin_right", 12)

	var text_label := Label.new()
	text_label.text = "Annotation:"
	text_label.add_theme_font_size_override("font_size", 12)
	dialog_vbox.add_child(text_label)

	_ann_input_text = TextEdit.new()
	_ann_input_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ann_input_text.placeholder_text = "Describe the annotation..."
	dialog_vbox.add_child(_ann_input_text)

	var btn_bar := HBoxContainer.new()
	btn_bar.alignment = BoxContainer.ALIGNMENT_END
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func() -> void: _ann_input_dialog.hide())
	btn_bar.add_child(cancel_btn)
	var ok_btn := Button.new()
	ok_btn.text = "Add"
	ok_btn.pressed.connect(_on_annotation_confirmed)
	btn_bar.add_child(ok_btn)
	dialog_vbox.add_child(btn_bar)

	_ann_input_dialog.add_child(dialog_vbox)
	add_child(_ann_input_dialog)

	# Initialize annotation data
	annotation_data = AnnotationDataScript.new()

	# Context menu for right-click on code lines
	_context_menu = PopupMenu.new()
	_context_menu.add_item("Add Annotation", 0)
	_context_menu.add_item("Add Region Annotation...", 1)
	_context_menu.add_separator()
	_context_menu.add_item("Remove Annotation", 2)
	_context_menu.id_pressed.connect(_on_context_menu_action)
	add_child(_context_menu)


func load_symbol(data: GraphDataScript, sym_id: String, source_path: String,
				  line_start: int, line_end: int) -> void:
	graph_data = data
	symbol_id = sym_id
	# Store relative path for annotation matching
	var node: Dictionary = data.get_node_by_id(sym_id)
	file_relative_path = str(node.get("file", "")) if not node.is_empty() else ""
	file_path = source_path
	func_start = line_start
	func_end = line_end

	# Read the source file
	before_lines.clear()
	if FileAccess.file_exists(source_path):
		var f := FileAccess.open(source_path, FileAccess.READ)
		if f:
			var text: String = f.get_as_text()
			f.close()
			before_lines = text.split("\n")
	# Default: after = before (no diff). Call set_diff_after() to provide modified version.
	after_lines = before_lines.duplicate()

	# Render immediately
	current_mode = Mode.CODE
	_render()


func set_diff_after(content: String) -> void:
	## Set the "after" content for diff view. Call after load_symbol().
	after_lines = content.split("\n")
	if current_mode == Mode.DIFF:
		_render()


func _set_mode(mode: Mode) -> void:
	current_mode = mode
	_render()


func _render() -> void:
	_render_info()
	_render_code()


func _render_info() -> void:
	for child in _info_panel.get_children():
		child.queue_free()

	if not graph_data or symbol_id == "":
		return

	var node: Dictionary = graph_data.get_node_by_id(symbol_id)
	if node.is_empty():
		return

	_add_info_label("FILE")
	_add_info_value(str(node.file) + ":" + str(node.line_start) + "-" + str(node.line_end))

	_add_info_label("SYMBOL")
	var kind_color: Color = graph_data.get_kind_color(str(node.get("kind", "")))
	_add_info_value(str(node.name) + " (" + str(node.get("kind", "")) + ")", kind_color)

	_add_info_label("SIGNATURE")
	_add_info_value(str(node.get("signature", "")), Color(0.494, 0.784, 0.89))

	if str(node.get("description", "")) != "":
		_add_info_label("DESCRIPTION")
		var desc_label := Label.new()
		desc_label.text = str(node.description)
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_label.add_theme_font_size_override("font_size", 12)
		desc_label.add_theme_color_override("font_color", Color(0.878, 0.878, 0.878))
		_info_panel.add_child(desc_label)

	_add_info_label("FAN-IN / FAN-OUT")
	_add_info_value("%d in / %d out" % [int(node.get("fan_in", 0)), int(node.get("fan_out", 0))])

	# Callers
	var edges: Dictionary = graph_data.get_edges_for_node(symbol_id)
	var incoming: Array = edges.incoming
	if incoming.size() > 0:
		_add_info_label("CALLERS (%d)" % incoming.size())
		var shown := 0
		for e: Dictionary in incoming:
			if shown >= 10:
				_add_info_value("... +%d more" % (incoming.size() - 10), Color(0.38, 0.38, 0.5))
				break
			var src: Dictionary = graph_data.get_node_by_id(str(e.source))
			var name: String = str(src.name) if not src.is_empty() else str(e.get("source_name", "?"))
			_add_info_edge("<- " + name + " [" + str(e.type) + "]")
			shown += 1


func _render_code() -> void:
	# Clear current code area
	if _current_code_area and _current_code_area != _code_scroll:
		_current_code_area.queue_free()
		_current_code_area = null

	for child in _code_container.get_children():
		child.queue_free()

	# Clean up old top_level annotation panels and overlay
	for ann_id: String in _ann_panel_controls:
		var panel: Control = _ann_panel_controls[ann_id]
		if panel and is_instance_valid(panel):
			panel.queue_free()
	_ann_panel_controls.clear()
	_ann_gutter_markers.clear()
	_ann_line_hboxes.clear()
	if _ann_overlay and is_instance_valid(_ann_overlay):
		_ann_overlay.queue_free()
		_ann_overlay = null

	match current_mode:
		Mode.CODE:
			_code_scroll.visible = true
			_current_code_area = _code_scroll
			_render_annotate()  # annotate mode IS the code view (explore + annotations merged)
		Mode.DIFF:
			_code_scroll.visible = true
			_current_code_area = _code_scroll
			_render_diff()


func _render_explore() -> void:
	## Show entire file with focused function bright, rest faded.
	## Annotated lines show a subtle gutter marker so the user knows annotations exist.
	var file_anns: Array[Dictionary] = annotation_data.get_for_file(file_relative_path)
	var annotated_lines: Dictionary = {}
	for ann: Dictionary in file_anns:
		for ln in range(int(ann.line_start), int(ann.line_end) + 1):
			if not annotated_lines.has(ln):
				annotated_lines[ln] = []
			annotated_lines[ln].append(ann)

	var _func_header_node: Control = null
	for i in range(before_lines.size()):
		var line_num: int = i + 1
		var in_func: bool = line_num >= func_start and line_num <= func_end
		var is_header: bool = line_num == func_start
		var has_ann: bool = annotated_lines.has(line_num)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 0)

		# Gutter marker (thin bar — indicates annotation exists, no interaction)
		var gutter := ColorRect.new()
		gutter.custom_minimum_size = Vector2(3, 0)
		gutter.size_flags_vertical = Control.SIZE_EXPAND_FILL
		if has_ann:
			var ann: Dictionary = annotated_lines[line_num][0]
			gutter.color = Color(0.9, 0.6, 0.97, 0.5) if str(ann.author) == "human" else Color(0.3, 0.67, 0.97, 0.5)
		else:
			gutter.color = Color(0, 0, 0, 0)
		hbox.add_child(gutter)

		# Line number
		var ln := Label.new()
		ln.text = str(line_num)
		ln.custom_minimum_size.x = 44
		ln.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		ln.add_theme_font_size_override("font_size", 13)
		ln.add_theme_color_override("font_color",
			Color(0.376, 0.376, 0.502) if in_func else Color(0.19, 0.19, 0.25))
		hbox.add_child(ln)

		# Code
		var code := Label.new()
		code.text = "  " + (before_lines[i] if i < before_lines.size() else "")
		code.add_theme_font_size_override("font_size", 13)
		code.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		if is_header:
			code.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89))
			var bg := StyleBoxFlat.new()
			bg.bg_color = Color(0.059, 0.204, 0.376, 0.12)
			hbox.add_theme_stylebox_override("panel", bg)
			_func_header_node = hbox
		elif in_func:
			code.add_theme_color_override("font_color", Color(0.878, 0.878, 0.878))
		else:
			code.add_theme_color_override("font_color", Color(0.19, 0.19, 0.25))

		hbox.add_child(code)

		# Subtle background tint for annotated lines (applied after code is added, skipped on header to avoid conflict)
		if has_ann and not is_header:
			var ann: Dictionary = annotated_lines[line_num][0]
			var ann_bg := StyleBoxFlat.new()
			ann_bg.bg_color = Color(0.9, 0.6, 0.97, 0.03) if str(ann.author) == "human" else Color(0.3, 0.67, 0.97, 0.03)
			hbox.add_theme_stylebox_override("panel", ann_bg)

		_code_container.add_child(hbox)

	# Scroll to center the function header after layout
	if _func_header_node:
		call_deferred("_scroll_to_function", _func_header_node)


func _scroll_to_function(target: Control) -> void:
	# Wait one more frame for layout to finalize
	await get_tree().process_frame
	if not is_instance_valid(target):
		return
	var scroll_y: float = target.position.y - _code_scroll.size.y / 2.0
	_code_scroll.scroll_vertical = int(maxf(0, scroll_y))


func _render_annotate() -> void:
	## Full-width code view with gutter markers, clickable lines, and floating annotations.
	var file_anns: Array[Dictionary] = annotation_data.get_for_file(file_relative_path)

	# Fixed toolbar (outside scroll, stays visible)
	for child in _fixed_toolbar.get_children():
		child.queue_free()

	var toolbar_bg := StyleBoxFlat.new()
	toolbar_bg.bg_color = Color(0.059, 0.204, 0.376, 0.3)
	toolbar_bg.set_content_margin_all(4)
	_fixed_toolbar.add_theme_stylebox_override("panel", toolbar_bg)
	_fixed_toolbar.add_theme_constant_override("separation", 12)

	var ann_btn := Button.new()
	ann_btn.text = "+ Annotate"
	ann_btn.add_theme_font_size_override("font_size", 12)
	ann_btn.add_theme_color_override("font_color", Color(0.9, 0.6, 0.97))
	ann_btn.pressed.connect(func() -> void:
		_ann_select_start = func_start
		_ann_select_end = func_start
		_show_annotation_dialog()
	)
	_fixed_toolbar.add_child(ann_btn)

	var ann_count_label := Label.new()
	ann_count_label.text = "%d annotations" % file_anns.size()
	ann_count_label.add_theme_font_size_override("font_size", 12)
	ann_count_label.add_theme_color_override("font_color", Color(0.69, 0.69, 0.69))
	_fixed_toolbar.add_child(ann_count_label)

	var toolbar_hint := Label.new()
	toolbar_hint.text = "right-click line number for menu"
	toolbar_hint.add_theme_font_size_override("font_size", 11)
	toolbar_hint.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89, 0.5))
	_fixed_toolbar.add_child(toolbar_hint)

	# Build annotated line lookup
	var annotated_lines: Dictionary = {}
	for ann: Dictionary in file_anns:
		for ln in range(int(ann.line_start), int(ann.line_end) + 1):
			if not annotated_lines.has(ln):
				annotated_lines[ln] = []
			annotated_lines[ln].append(ann)

	_ann_gutter_markers.clear()
	_ann_panel_controls.clear()
	_ann_line_hboxes.clear()

	var _func_header_node: Control = null

	for i in range(before_lines.size()):
		var line_num: int = i + 1
		var in_func: bool = line_num >= func_start and line_num <= func_end
		var is_header: bool = line_num == func_start
		var has_ann: bool = annotated_lines.has(line_num)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 0)

		# Gutter marker (4px, colored for annotated lines)
		var gutter := ColorRect.new()
		gutter.custom_minimum_size = Vector2(4, 0)
		gutter.size_flags_vertical = Control.SIZE_EXPAND_FILL
		if has_ann:
			var ann: Dictionary = annotated_lines[line_num][0]
			gutter.color = Color(0.9, 0.6, 0.97, 0.8) if str(ann.author) == "human" else Color(0.3, 0.67, 0.97, 0.8)
			if int(ann.line_start) == line_num:
				_ann_gutter_markers[str(ann.id)] = gutter
			var ann_id: String = str(ann.id)
			if not _ann_line_hboxes.has(ann_id):
				_ann_line_hboxes[ann_id] = []
			_ann_line_hboxes[ann_id].append(hbox)
		else:
			gutter.color = Color(0, 0, 0, 0)
		hbox.add_child(gutter)

		# Line number (clickable Button for adding annotations)
		var ln_btn := Button.new()
		ln_btn.text = str(line_num)
		ln_btn.custom_minimum_size.x = 44
		ln_btn.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		ln_btn.flat = true
		ln_btn.add_theme_font_size_override("font_size", 13)
		ln_btn.add_theme_color_override("font_color",
			Color(0.376, 0.376, 0.502) if in_func else Color(0.19, 0.19, 0.25))
		ln_btn.add_theme_color_override("font_hover_color", Color(0.9, 0.6, 0.97))
		var captured_line: int = line_num
		ln_btn.pressed.connect(func() -> void: _on_annotation_line_clicked(captured_line))
		# Right-click on line number for context menu
		ln_btn.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				_show_context_menu(captured_line, event.global_position)
				ln_btn.accept_event()
		)
		hbox.add_child(ln_btn)

		# Code text
		var code := Label.new()
		code.text = "  " + (before_lines[i] if i < before_lines.size() else "")
		code.add_theme_font_size_override("font_size", 13)
		code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		code.mouse_filter = Control.MOUSE_FILTER_STOP
		var context_line: int = line_num
		code.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				_show_context_menu(context_line, event.global_position)
				code.accept_event()
		)

		if is_header:
			code.add_theme_color_override("font_color", Color(0.494, 0.784, 0.89))
			var header_bg := StyleBoxFlat.new()
			header_bg.bg_color = Color(0.059, 0.204, 0.376, 0.12)
			hbox.add_theme_stylebox_override("panel", header_bg)
			_func_header_node = hbox
		elif in_func:
			code.add_theme_color_override("font_color", Color(0.878, 0.878, 0.878))
		else:
			code.add_theme_color_override("font_color", Color(0.19, 0.19, 0.25))

		# Subtle background tint for annotated regions (skip header to avoid conflict)
		if has_ann and not is_header:
			var ann: Dictionary = annotated_lines[line_num][0]
			var is_human: bool = str(ann.author) == "human"
			var ann_bg := StyleBoxFlat.new()
			ann_bg.bg_color = Color(0.9, 0.6, 0.97, 0.08) if is_human else Color(0.3, 0.67, 0.97, 0.06)
			hbox.add_theme_stylebox_override("panel", ann_bg)

		hbox.add_child(code)
		_code_container.add_child(hbox)

	# Add floating annotation panels as overlay on _code_area_parent
	# They sit on top of the scroll, positioned based on line Y minus scroll offset
	call_deferred("_add_floating_annotations", file_anns)

	# Scroll to center the function header after layout
	if _func_header_node:
		call_deferred("_scroll_to_function", _func_header_node)


func _add_floating_annotations(file_anns: Array[Dictionary]) -> void:
	await get_tree().process_frame

	if file_anns.is_empty():
		return

	# Add each panel directly to this Control (Level3SymbolView) so they're
	# above the ScrollContainer in the scene tree and receive input directly.
	var seen: Dictionary = {}
	for ann: Dictionary in file_anns:
		var ann_id: String = str(ann.id)
		if seen.has(ann_id):
			continue
		seen[ann_id] = true

		var gutter: Control = _ann_gutter_markers.get(ann_id)
		if not gutter or not is_instance_valid(gutter):
			continue

		var panel := _create_floating_panel(ann)
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		panel.top_level = true  # detach from parent input chain — receives input directly
		add_child(panel)
		_ann_panel_controls[ann_id] = panel

	# Arrow overlay — also top_level so it draws over everything
	_ann_overlay = AnnotationArrowOverlay.new()
	_ann_overlay.top_level = true
	_ann_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ann_overlay)

	# Position panels and arrows — update on scroll
	call_deferred("_position_panels_on_code")
	call_deferred("_update_arrows_deferred")
	_code_scroll.get_v_scroll_bar().value_changed.connect(func(_val: float) -> void:
		_position_panels_on_code()
		_update_arrows()
	)


func _update_arrows_deferred() -> void:
	await get_tree().process_frame
	_update_arrows()


func _update_arrows() -> void:
	if not _ann_overlay or not is_instance_valid(_ann_overlay):
		return
	if _ann_panel_controls.is_empty():
		return
	# Match overlay to the scroll viewport so it does not cover the fixed toolbar.
	_ann_overlay.global_position = _code_scroll.global_position
	_ann_overlay.size = _code_scroll.size

	var scroll_y: float = float(_code_scroll.scroll_vertical)
	_ann_overlay.connections.clear()
	for ann_id: String in _ann_panel_controls:
		var panel: Control = _ann_panel_controls.get(ann_id)
		var gutter: Control = _ann_gutter_markers.get(ann_id)
		if not panel or not gutter:
			continue
		if not is_instance_valid(panel) or not is_instance_valid(gutter):
			continue
		# Panel left center (global → overlay local)
		var panel_global: Vector2 = panel.global_position
		var from_pt: Vector2 = Vector2(
			panel_global.x - _ann_overlay.global_position.x,
			panel_global.y - _ann_overlay.global_position.y + panel.size.y / 2.0)
		# Arrow endpoint: right edge of code text, Y from line position in scroll
		# Use position within _code_container (not global) minus scroll offset
		var line_hbox: Control = gutter.get_parent()
		var line_y_in_container: float = line_hbox.position.y  # position in _code_container
		var line_y_visible: float = line_y_in_container - scroll_y  # visible position in scroll viewport

		var code_label: Control = line_hbox.get_child(2) if line_hbox.get_child_count() > 2 else line_hbox
		var text_width: float = code_label.get_theme_font("font").get_string_size(
			code_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			code_label.get_theme_font_size("font_size")).x
		# X: code label's X offset within the line + text width + padding
		var code_x_in_line: float = code_label.position.x
		var text_right_x: float = code_x_in_line + text_width + 16.0

		var to_pt: Vector2 = Vector2(text_right_x, line_y_visible + line_hbox.size.y / 2.0)
		_ann_overlay.connections.append({
			"from": from_pt, "to": to_pt,
			"color": Color(0.494, 0.784, 0.89, 0.4)
		})
	_ann_overlay.queue_redraw()


func _show_context_menu(line_num: int, screen_pos: Vector2) -> void:
	_context_line = line_num
	# Show/hide "Remove" option based on whether this line has an annotation
	var has_ann := false
	for ann: Dictionary in annotation_data.get_for_file(file_relative_path):
		if int(ann.line_start) <= line_num and int(ann.line_end) >= line_num:
			has_ann = true
			break
	_context_menu.set_item_disabled(2, not has_ann)  # "Remove Annotation"
	_context_menu.position = Vector2i(int(screen_pos.x), int(screen_pos.y))
	_context_menu.popup()


func _on_context_menu_action(id: int) -> void:
	match id:
		0:  # Add Annotation
			_ann_select_start = _context_line
			_ann_select_end = _context_line
			_show_annotation_dialog()
		1:  # Add Region — start selection
			_ann_selecting = true
			_ann_select_start = _context_line
			_ann_select_end = _context_line
		2:  # Remove Annotation
			for ann: Dictionary in annotation_data.get_for_file(file_relative_path):
				if int(ann.line_start) <= _context_line and int(ann.line_end) >= _context_line:
					annotation_data.remove(str(ann.id))
					if annotation_data.file_path != "":
						annotation_data.save_to_file(annotation_data.file_path)
					_render()
					break


func _position_panels_on_code() -> void:
	## Position annotation panels using global_position (panels are top_level).
	if _ann_panel_controls.is_empty():
		return
	var scroll_y: float = float(_code_scroll.scroll_vertical)
	var scroll_global: Vector2 = _code_scroll.global_position
	var scroll_size: Vector2 = _code_scroll.size

	var panel_width := 280.0
	var panel_margin := 16.0
	var panel_x: float = scroll_global.x + scroll_size.x - panel_width - panel_margin
	var next_y: float = scroll_global.y

	for ann_id: String in _ann_panel_controls:
		var panel: Control = _ann_panel_controls[ann_id]
		var gutter: Control = _ann_gutter_markers.get(ann_id)
		if not panel or not gutter:
			continue
		if not is_instance_valid(panel) or not is_instance_valid(gutter):
			continue

		# Check for saved position (saved as global)
		var saved_x: float = -1.0
		var saved_y: float = -1.0
		for a: Dictionary in annotation_data.annotations:
			if str(a.id) == ann_id:
				saved_x = float(a.get("panel_x", -1.0))
				saved_y = float(a.get("panel_y", -1.0))
				break

		if saved_x >= 0 and saved_y >= 0:
			panel.global_position = Vector2(saved_x, saved_y)
		else:
			# Position relative to the scroll viewport, adjusted for scroll
			var gutter_y: float = gutter.get_parent().position.y - scroll_y
			var target_y: float = maxf(scroll_global.y + gutter_y, next_y)
			panel.global_position = Vector2(panel_x, target_y)
			next_y = target_y + panel.size.y + 8.0

		panel.size = Vector2(panel_width, 0)


func _position_floating_panels(overlay: Control) -> void:
	## Position floating panels based on gutter marker positions minus scroll offset.
	if not is_instance_valid(overlay):
		return
	var scroll_y: float = float(_code_scroll.scroll_vertical)
	var panel_width := 280.0
	var panel_margin := 16.0
	var panel_x: float = overlay.size.x - panel_width - panel_margin
	var next_y := 0.0  # track to avoid overlap

	for ann_id: String in _ann_panel_controls:
		var panel: Control = _ann_panel_controls[ann_id]
		var gutter: Control = _ann_gutter_markers.get(ann_id)
		if not panel or not gutter:
			continue
		if not is_instance_valid(panel) or not is_instance_valid(gutter):
			continue

		# Check for saved position
		var saved_x: float = -1.0
		var saved_y: float = -1.0
		for a: Dictionary in annotation_data.annotations:
			if str(a.id) == ann_id:
				saved_x = float(a.get("panel_x", -1.0))
				saved_y = float(a.get("panel_y", -1.0))
				break

		if saved_x >= 0 and saved_y >= 0:
			panel.position = Vector2(saved_x, saved_y)
			panel.size = Vector2(panel_width, 0)
			next_y = maxf(next_y, saved_y + panel.size.y + 8.0)
		else:
			# Gutter position in code_container space, adjusted for scroll
			var gutter_y: float = gutter.get_parent().position.y - scroll_y
			# Avoid overlap with previous panel
			var target_y: float = maxf(gutter_y, next_y)
			panel.position = Vector2(panel_x, target_y)
			panel.size = Vector2(panel_width, 0)
			next_y = target_y + panel.size.y + 8.0

	# Update arrows
	_recompute_arrows_from_overlay(overlay)


func _recompute_arrows_from_overlay(overlay: Control) -> void:
	if not _ann_overlay or not is_instance_valid(_ann_overlay):
		return
	var scroll_y: float = float(_code_scroll.scroll_vertical)
	_ann_overlay.connections.clear()
	for ann_id: String in _ann_panel_controls:
		var panel: Control = _ann_panel_controls.get(ann_id)
		var gutter: Control = _ann_gutter_markers.get(ann_id)
		if not panel or not gutter:
			continue
		if not is_instance_valid(panel) or not is_instance_valid(gutter):
			continue
		# Panel left edge center
		var from_pt := Vector2(panel.position.x, panel.position.y + panel.size.y / 2.0)
		# Gutter right edge center (adjusted for scroll)
		var gutter_y: float = gutter.get_parent().position.y - scroll_y + gutter.size.y / 2.0
		var to_pt := Vector2(overlay.size.x * 0.5, gutter_y)  # Point to middle of code area
		var color := Color(0.494, 0.784, 0.89, 0.4)
		_ann_overlay.connections.append({"from": from_pt, "to": to_pt, "color": color})
	_ann_overlay.queue_redraw()


func _create_floating_panel(ann: Dictionary) -> DraggablePanel:
	var is_human: bool = str(ann.author) == "human"
	var box := DraggablePanel.new()
	box.ann_id = str(ann.id)
	box.annotation_data_ref = annotation_data
	box.on_drag_moved = func() -> void:
		_update_arrows()  # only update arrows during drag, don't reposition panels
	var style := StyleBoxFlat.new()
	if is_human:
		style.bg_color = Color(0.9, 0.6, 0.97, 0.15)
		style.border_color = Color(0.9, 0.6, 0.97, 0.4)
	else:
		style.bg_color = Color(0.3, 0.67, 0.97, 0.12)
		style.border_color = Color(0.3, 0.67, 0.97, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(8)
	box.add_theme_stylebox_override("panel", style)
	box.mouse_filter = Control.MOUSE_FILTER_STOP

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_PASS

	var line_ref := Label.new()
	var line_text: String = "line %d" % int(ann.line_start)
	if int(ann.line_start) != int(ann.line_end):
		line_text = "lines %d-%d" % [int(ann.line_start), int(ann.line_end)]
	line_ref.text = "%s · %s  [drag to move]" % [line_text, str(ann.author)]
	line_ref.add_theme_font_size_override("font_size", 10)
	line_ref.add_theme_color_override("font_color",
		Color(0.7, 0.55, 0.78) if is_human else Color(0.5, 0.65, 0.8))
	line_ref.mouse_filter = Control.MOUSE_FILTER_PASS
	vbox.add_child(line_ref)

	var text_label := Label.new()
	text_label.text = str(ann.text)
	text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_label.add_theme_font_size_override("font_size", 12)
	text_label.add_theme_color_override("font_color",
		Color(0.92, 0.84, 0.97) if is_human else Color(0.84, 0.9, 0.97))
	text_label.mouse_filter = Control.MOUSE_FILTER_PASS
	vbox.add_child(text_label)

	var del_btn := Button.new()
	del_btn.text = "Remove"
	del_btn.add_theme_font_size_override("font_size", 9)
	del_btn.add_theme_color_override("font_color", Color(0.5, 0.35, 0.4))
	del_btn.flat = true
	var ann_id: String = str(ann.id)
	del_btn.pressed.connect(func() -> void:
		annotation_data.remove(ann_id)
		if annotation_data.file_path != "":
			annotation_data.save_to_file(annotation_data.file_path)
		_render()
	)
	vbox.add_child(del_btn)

	box.add_child(vbox)

	# Hover highlighting
	var ann_id_str: String = str(ann.id)
	box.mouse_entered.connect(func() -> void:
		var lines: Array = _ann_line_hboxes.get(ann_id_str, [])
		for line_hbox in lines:
			if is_instance_valid(line_hbox):
				var hl_bg := StyleBoxFlat.new()
				hl_bg.bg_color = Color(0.494, 0.784, 0.89, 0.15)
				line_hbox.add_theme_stylebox_override("panel", hl_bg)
	)
	box.mouse_exited.connect(func() -> void:
		var lines: Array = _ann_line_hboxes.get(ann_id_str, [])
		var ann_is_human: bool = str(ann.author) == "human"
		for line_hbox in lines:
			if is_instance_valid(line_hbox):
				var restore_bg := StyleBoxFlat.new()
				restore_bg.bg_color = Color(0.9, 0.6, 0.97, 0.08) if ann_is_human else Color(0.3, 0.67, 0.97, 0.06)
				line_hbox.add_theme_stylebox_override("panel", restore_bg)
	)

	return box


func _scroll_to_function_in(scroll: ScrollContainer, target: Control) -> void:
	await get_tree().process_frame
	var scroll_y: float = target.position.y - scroll.size.y / 2.0
	scroll.scroll_vertical = int(maxf(0, scroll_y))


func _on_annotation_line_clicked(line_num: int) -> void:
	if Input.is_key_pressed(KEY_SHIFT):
		# Shift+click: set region start or end
		if not _ann_selecting:
			_ann_selecting = true
			_ann_select_start = line_num
			_ann_select_end = line_num
		else:
			_ann_select_end = line_num
			_ann_selecting = false
			_show_annotation_dialog()
	else:
		_ann_select_start = line_num
		_ann_select_end = line_num
		_show_annotation_dialog()


func _show_annotation_dialog() -> void:
	_ann_input_text.text = ""
	if _ann_select_start != _ann_select_end:
		_ann_input_dialog.title = "Annotate lines %d-%d" % [
			mini(_ann_select_start, _ann_select_end),
			maxi(_ann_select_start, _ann_select_end)]
	else:
		_ann_input_dialog.title = "Annotate line %d" % _ann_select_start
	_ann_input_dialog.popup_centered()


func _on_annotation_confirmed() -> void:
	var text: String = _ann_input_text.text.strip_edges()
	if text.is_empty():
		_ann_input_dialog.hide()
		return

	var start_line: int = mini(_ann_select_start, _ann_select_end)
	var end_line: int = maxi(_ann_select_start, _ann_select_end)
	annotation_data.add_arrow(file_relative_path, start_line, end_line, text)

	if annotation_data.file_path != "":
		annotation_data.save_to_file(annotation_data.file_path)
	_ann_input_dialog.hide()
	_render()


func _render_diff() -> void:
	## Beyond Compare style side-by-side diff with aligned lines.
	_code_scroll.visible = false

	# Diff toolbar with prev/next navigation
	for child in _fixed_toolbar.get_children():
		child.queue_free()
	var toolbar_bg := StyleBoxFlat.new()
	toolbar_bg.bg_color = Color(0.059, 0.204, 0.376, 0.3)
	toolbar_bg.set_content_margin_all(4)
	_fixed_toolbar.add_theme_stylebox_override("panel", toolbar_bg)
	_fixed_toolbar.add_theme_constant_override("separation", 8)

	var prev_btn := Button.new()
	prev_btn.text = "< Prev"
	prev_btn.add_theme_font_size_override("font_size", 12)
	prev_btn.pressed.connect(func() -> void: prev_diff_requested.emit())
	_fixed_toolbar.add_child(prev_btn)

	var diff_label := Label.new()
	diff_label.text = "Diff: %s" % file_relative_path.get_file()
	diff_label.add_theme_font_size_override("font_size", 12)
	diff_label.add_theme_color_override("font_color", Color(0.99, 0.77, 0.1))
	diff_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fixed_toolbar.add_child(diff_label)

	var next_btn := Button.new()
	next_btn.text = "Next >"
	next_btn.add_theme_font_size_override("font_size", 12)
	next_btn.pressed.connect(func() -> void: next_diff_requested.emit())
	_fixed_toolbar.add_child(next_btn)

	var diff_pairs: Array = _compute_lcs_diff(before_lines, after_lines)

	# Two-column layout (size_flags, NOT anchor preset — _code_area_parent is a VBoxContainer)
	var columns := HSplitContainer.new()
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code_area_parent.add_child(columns)
	_current_code_area = columns

	# Left: before
	var before_panel := VBoxContainer.new()
	before_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(before_panel)

	var before_header := Label.new()
	before_header.text = "  Before"
	before_header.add_theme_font_size_override("font_size", 12)
	before_header.add_theme_color_override("font_color", Color(1.0, 0.42, 0.42))
	var bh_bg := StyleBoxFlat.new()
	bh_bg.bg_color = Color(0.086, 0.129, 0.243)
	before_header.add_theme_stylebox_override("normal", bh_bg)
	before_panel.add_child(before_header)

	var before_scroll := ScrollContainer.new()
	before_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	before_panel.add_child(before_scroll)
	var before_vbox := VBoxContainer.new()
	before_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	before_scroll.add_child(before_vbox)

	# Right: after
	var after_panel := VBoxContainer.new()
	after_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(after_panel)

	var after_header := Label.new()
	after_header.text = "  After"
	after_header.add_theme_font_size_override("font_size", 12)
	after_header.add_theme_color_override("font_color", Color(0.32, 0.81, 0.4))
	var ah_bg := StyleBoxFlat.new()
	ah_bg.bg_color = Color(0.086, 0.129, 0.243)
	after_header.add_theme_stylebox_override("normal", ah_bg)
	after_panel.add_child(after_header)

	var after_scroll := ScrollContainer.new()
	after_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	after_panel.add_child(after_scroll)
	var after_vbox := VBoxContainer.new()
	after_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	after_scroll.add_child(after_vbox)

	# Render aligned pairs, track function header for scrolling
	var _diff_func_header: Control = null
	for pair: Dictionary in diff_pairs:
		var status: String = str(pair.status)
		var before_line: HBoxContainer
		var after_line: HBoxContainer
		match status:
			"same":
				before_line = _make_diff_line(int(pair.before_num), str(pair.before_text), "same")
				after_line = _make_diff_line(int(pair.after_num), str(pair.after_text), "same")
				before_vbox.add_child(before_line)
				after_vbox.add_child(after_line)
				if int(pair.before_num) == func_start:
					_diff_func_header = before_line
			"removed":
				before_line = _make_diff_line(int(pair.before_num), str(pair.before_text), "removed")
				before_vbox.add_child(before_line)
				after_vbox.add_child(_make_diff_spacer())
				if int(pair.before_num) == func_start:
					_diff_func_header = before_line
			"added":
				before_vbox.add_child(_make_diff_spacer())
				after_line = _make_diff_line(int(pair.after_num), str(pair.after_text), "added")
				after_vbox.add_child(after_line)

	# Sync scrolling
	before_scroll.get_v_scroll_bar().value_changed.connect(func(val: float) -> void:
		after_scroll.scroll_vertical = int(val)
	)
	after_scroll.get_v_scroll_bar().value_changed.connect(func(val: float) -> void:
		before_scroll.scroll_vertical = int(val)
	)

	# Scroll to function
	if _diff_func_header:
		call_deferred("_scroll_to_function_in", before_scroll, _diff_func_header)


func _compute_lcs_diff(a: PackedStringArray, b: PackedStringArray) -> Array:
	## LCS-based diff producing aligned pairs for side-by-side display.
	var m: int = a.size()
	var n: int = b.size()

	# Build LCS table
	var dp: Array = []
	for i in range(m + 1):
		var row: PackedInt32Array = PackedInt32Array()
		row.resize(n + 1)
		dp.append(row)

	for i in range(1, m + 1):
		for j in range(1, n + 1):
			if a[i - 1] == b[j - 1]:
				dp[i][j] = dp[i - 1][j - 1] + 1
			else:
				dp[i][j] = maxi(dp[i - 1][j], dp[i][j - 1])

	# Backtrack to produce diff
	var i: int = m
	var j: int = n
	var ops: Array = []

	while i > 0 or j > 0:
		if i > 0 and j > 0 and a[i - 1] == b[j - 1]:
			ops.push_front({"status": "same", "before_num": i, "after_num": j,
				"before_text": a[i - 1], "after_text": b[j - 1]})
			i -= 1
			j -= 1
		elif j > 0 and (i == 0 or dp[i][j - 1] >= dp[i - 1][j]):
			ops.push_front({"status": "added", "before_num": 0, "after_num": j,
				"before_text": "", "after_text": b[j - 1]})
			j -= 1
		else:
			ops.push_front({"status": "removed", "before_num": i, "after_num": 0,
				"before_text": a[i - 1], "after_text": ""})
			i -= 1

	return ops


func _make_diff_line(line_num: int, text: String, status: String) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 0)

	var ln := Label.new()
	ln.text = str(line_num) if line_num > 0 else ""
	ln.custom_minimum_size.x = 40
	ln.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ln.add_theme_font_size_override("font_size", 13)
	ln.add_theme_color_override("font_color", Color(0.3, 0.3, 0.45))
	hbox.add_child(ln)

	var marker := Label.new()
	marker.custom_minimum_size.x = 16
	marker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	marker.add_theme_font_size_override("font_size", 13)
	match status:
		"added":
			marker.text = "+"
			marker.add_theme_color_override("font_color", Color(0.32, 0.81, 0.4))
		"removed":
			marker.text = "-"
			marker.add_theme_color_override("font_color", Color(1.0, 0.42, 0.42))
		_:
			marker.text = " "
			marker.add_theme_color_override("font_color", Color(0.25, 0.25, 0.38))
	hbox.add_child(marker)

	var code := Label.new()
	code.text = text
	code.add_theme_font_size_override("font_size", 13)
	code.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var bg := StyleBoxFlat.new()
	match status:
		"added":
			code.add_theme_color_override("font_color", Color(0.7, 0.92, 0.7))
			bg.bg_color = Color(0.32, 0.81, 0.4, 0.08)
		"removed":
			code.add_theme_color_override("font_color", Color(0.92, 0.7, 0.7))
			bg.bg_color = Color(1.0, 0.42, 0.42, 0.08)
		_:
			code.add_theme_color_override("font_color", Color(0.45, 0.45, 0.55))
			bg.bg_color = Color(0, 0, 0, 0)
	hbox.add_theme_stylebox_override("panel", bg)

	hbox.add_child(code)
	return hbox


func _make_diff_spacer() -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 0)
	var spacer := Label.new()
	spacer.text = " "
	spacer.add_theme_font_size_override("font_size", 13)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.15, 0.15, 0.22, 0.5)
	hbox.add_theme_stylebox_override("panel", bg)
	hbox.add_child(spacer)
	return hbox


# ── Info panel helpers ──

func _add_info_label(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.91, 0.27, 0.38))
	_info_panel.add_child(label)

func _add_info_value(text: String, color := Color(0.878, 0.878, 0.878)) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", color)
	_info_panel.add_child(label)

func _add_info_edge(text: String) -> void:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", 11)
	btn.add_theme_color_override("font_color", Color(0.69, 0.69, 0.69))
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_info_panel.add_child(btn)


func _compute_annotation_arrows() -> void:
	if not _ann_overlay:
		return
	await get_tree().process_frame
	_recompute_arrows_immediate()


func _recompute_arrows_immediate() -> void:
	if not _ann_overlay or not is_instance_valid(_ann_overlay):
		return
	_ann_overlay.connections.clear()
	for ann_id: String in _ann_panel_controls:
		var panel: Control = _ann_panel_controls.get(ann_id)
		var gutter: Control = _ann_gutter_markers.get(ann_id)
		if not panel or not gutter:
			continue
		if not is_instance_valid(panel) or not is_instance_valid(gutter):
			continue
		# Get positions relative to the overlay
		var panel_pos: Vector2 = panel.global_position - _ann_overlay.global_position
		var gutter_pos: Vector2 = gutter.global_position - _ann_overlay.global_position
		# Connect from left edge of panel to right edge of gutter
		var from_pt: Vector2 = Vector2(panel_pos.x, panel_pos.y + panel.size.y / 2.0)
		var to_pt: Vector2 = Vector2(gutter_pos.x + gutter.size.x, gutter_pos.y + gutter.size.y / 2.0)
		var color := Color(0.494, 0.784, 0.89, 0.4)
		_ann_overlay.connections.append({"from": from_pt, "to": to_pt, "color": color})
	_ann_overlay.queue_redraw()


class DraggablePanel extends PanelContainer:
	## A PanelContainer that can be dragged by the user.
	## Uses _gui_input override instead of signal for reliable event handling.
	var ann_id: String = ""
	var annotation_data_ref: RefCounted = null  # AnnotationData
	var on_drag_moved: Callable  # called when dragged, for updating arrows
	var _dragging := false

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
			else:
				_dragging = false
				_save_position()
			accept_event()
		elif event is InputEventMouseMotion and _dragging:
			position += event.relative
			_save_position()  # save during drag so layout respects current position
			accept_event()
			if on_drag_moved.is_valid():
				on_drag_moved.call()

	func _save_position() -> void:
		if not annotation_data_ref:
			return
		for a: Dictionary in annotation_data_ref.annotations:
			if str(a.id) == ann_id:
				a.panel_x = global_position.x
				a.panel_y = global_position.y
				break
		if annotation_data_ref.file_path != "":
			annotation_data_ref.save_to_file(annotation_data_ref.file_path)


class AnnotationArrowOverlay extends Control:
	## Transparent overlay that draws arrow lines from annotation panels to gutter markers.
	var connections: Array = []  # [{from: Vector2, to: Vector2, color: Color}]

	func _draw() -> void:
		for conn: Dictionary in connections:
			var from_pos: Vector2 = conn.from
			var to_pos: Vector2 = conn.to
			var color: Color = conn.color
			# Draw an elbow line: horizontal from panel edge, vertical, horizontal to gutter
			var mid_x: float = (from_pos.x + to_pos.x) / 2.0
			draw_line(from_pos, Vector2(mid_x, from_pos.y), color, 1.5)
			draw_line(Vector2(mid_x, from_pos.y), Vector2(mid_x, to_pos.y), color, 1.5)
			draw_line(Vector2(mid_x, to_pos.y), to_pos, color, 1.5)
			# Small circle at the gutter end
			draw_circle(to_pos, 3.0, color)
