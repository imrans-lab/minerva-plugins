extends AcceptDialog
## Classification Rules Editor — DCR 019e33bf rewrite.
##
## Edits rules in the GLOBAL LIBRARY via the `library_*` MCP tool family. No
## per-vault sidecars, no path arguments — there is exactly one library, lived
## at the plugin's OS app-data path.
##
## Schema (new — DCR 019e33bf): a rule has flat fields (label, name,
## instruction, subfolder, rename_pattern, confidence_threshold, flags) plus a
## list of `stages`. Each stage = {ask, classify{slot_name: {description,
## values: [...]|"..."}}, keep_when?}. Slot names must be unique across all
## stages of a rule (enforced server-side by Rule::validate).
##
## Usage:
##   var dlg = preload("rules_editor_dialog.gd").new()
##   dlg.init(conn)
##   add_child(dlg)
##   dlg.rules_changed.connect(_on_rules_changed)
##   dlg.popup_centered(Vector2(1000, 700))
##
## Off-tree plugin script — no class_name; use preload().

signal rules_changed
signal closed

const _UiScale := preload("ui_scale.gd")

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

var _conn: Object = null

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

# All rules loaded from the library (canonical, server order). Array[Dictionary].
var _rules: Array = []
# Index of currently selected rule in _rules (-1 = none).
var _current_index: int = -1
# The rule the form is currently bound to (a working copy — edits go here on
# harvest, then we POST to the server on Save).
var _working: Dictionary = {}
# True if the working copy is a brand-new (unsaved) rule.
var _is_new: bool = false

# ---------------------------------------------------------------------------
# Widgets (rules list)
# ---------------------------------------------------------------------------

var _list: ItemList = null
var _new_btn: Button = null
var _delete_btn: Button = null

# Widgets (form — flat fields)
var _f_label: LineEdit = null
var _f_name: LineEdit = null
var _f_order: SpinBox = null
var _f_instruction: TextEdit = null
var _f_subfolder: LineEdit = null
var _f_rename_pattern: LineEdit = null
var _f_threshold: SpinBox = null
var _f_enabled: CheckBox = null
var _f_encrypt: CheckBox = null
var _f_stop: CheckBox = null
var _f_default: CheckBox = null

# Widgets (form — stages)
var _stages_container: VBoxContainer = null
var _add_stage_btn: Button = null

# Widgets (form actions)
var _save_btn: Button = null
var _revert_btn: Button = null
var _error_label: Label = null

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func init(conn: Object) -> void:
	_conn = conn

func _ready() -> void:
	_UiScale.apply_to(self)
	title = "Classification Rules"
	get_ok_button().text = "Close"
	confirmed.connect(_on_close)
	canceled.connect(_on_close)
	_build_ui()
	call_deferred("_load_library")

func _on_close() -> void:
	emit_signal("closed")

# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	var split := HBoxContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 8)
	root.add_child(split)

	# Left: rules list + new/delete buttons. Fixed width — no expand.
	var left := VBoxContainer.new()
	left.size_flags_horizontal = 0  # no expand
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.custom_minimum_size = Vector2(240, 0)
	split.add_child(left)

	var list_label := Label.new()
	list_label.text = "Library rules"
	list_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	left.add_child(list_label)

	_list = ItemList.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_rule_selected)
	left.add_child(_list)

	var left_btns := HBoxContainer.new()
	left.add_child(left_btns)

	_new_btn = Button.new()
	_new_btn.text = "New…"
	_new_btn.pressed.connect(_on_new_pressed)
	left_btns.add_child(_new_btn)

	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.pressed.connect(_on_delete_pressed)
	_delete_btn.disabled = true
	left_btns.add_child(_delete_btn)

	# Right: scrollable form.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(right)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)

	var form := VBoxContainer.new()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(form)

	_build_identity_section(form)
	_build_output_section(form)
	_build_stages_section(form)

	# Bottom action row.
	var action_row := HBoxContainer.new()
	right.add_child(action_row)

	_error_label = Label.new()
	_error_label.add_theme_color_override("font_color", Color(0.95, 0.4, 0.4))
	_error_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	action_row.add_child(_error_label)

	_revert_btn = Button.new()
	_revert_btn.text = "Revert"
	_revert_btn.pressed.connect(_on_revert_pressed)
	action_row.add_child(_revert_btn)

	_save_btn = Button.new()
	_save_btn.text = "Save"
	_save_btn.pressed.connect(_on_save_pressed)
	action_row.add_child(_save_btn)

	_set_form_enabled(false)

func _build_identity_section(parent: VBoxContainer) -> void:
	parent.add_child(_section_header("Identity"))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(grid)

	grid.add_child(_label_for("Label*"))
	_f_label = LineEdit.new()
	_f_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_f_label.placeholder_text = "unique-key (required)"
	grid.add_child(_f_label)

	grid.add_child(_label_for("Name"))
	_f_name = LineEdit.new()
	_f_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_f_name)

	grid.add_child(_label_for("Order"))
	_f_order = SpinBox.new()
	_f_order.min_value = -10000
	_f_order.max_value = 10000
	_f_order.step = 1
	grid.add_child(_f_order)

	parent.add_child(_label_for("Instruction"))
	_f_instruction = TextEdit.new()
	_f_instruction.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_f_instruction.custom_minimum_size.y = 80
	_f_instruction.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	parent.add_child(_f_instruction)

func _build_output_section(parent: VBoxContainer) -> void:
	parent.add_child(_section_header("Output"))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(grid)

	grid.add_child(_label_for("Subfolder"))
	_f_subfolder = LineEdit.new()
	_f_subfolder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_f_subfolder.placeholder_text = "e.g. Tax/{year}"
	grid.add_child(_f_subfolder)

	grid.add_child(_label_for("Rename pattern"))
	_f_rename_pattern = LineEdit.new()
	_f_rename_pattern.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_f_rename_pattern.placeholder_text = "e.g. {year}_{issuer}_{doc_type}"
	grid.add_child(_f_rename_pattern)

	grid.add_child(_label_for("Confidence threshold"))
	_f_threshold = SpinBox.new()
	_f_threshold.min_value = 0.0
	_f_threshold.max_value = 1.0
	_f_threshold.step = 0.05
	_f_threshold.value = 0.6
	grid.add_child(_f_threshold)

	var flags := HBoxContainer.new()
	parent.add_child(flags)
	_f_enabled = CheckBox.new()
	_f_enabled.text = "Enabled"
	_f_enabled.button_pressed = true
	flags.add_child(_f_enabled)
	_f_encrypt = CheckBox.new()
	_f_encrypt.text = "Encrypt"
	flags.add_child(_f_encrypt)
	_f_stop = CheckBox.new()
	_f_stop.text = "Stop processing on match"
	flags.add_child(_f_stop)
	_f_default = CheckBox.new()
	_f_default.text = "Default (catch-all)"
	flags.add_child(_f_default)

func _build_stages_section(parent: VBoxContainer) -> void:
	var header := HBoxContainer.new()
	parent.add_child(header)

	var t := Label.new()
	t.text = "Stages"
	t.add_theme_font_size_override("font_size", 16)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(t)

	_add_stage_btn = Button.new()
	_add_stage_btn.text = "+ Add stage"
	_add_stage_btn.pressed.connect(_on_add_stage_pressed)
	header.add_child(_add_stage_btn)

	_stages_container = VBoxContainer.new()
	_stages_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(_stages_container)

# ---------------------------------------------------------------------------
# Stage / Slot widget factories
# ---------------------------------------------------------------------------

func _make_stage_widget(stage_data: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(v)

	# Stage header: label + move up/down/delete.
	var head := HBoxContainer.new()
	v.add_child(head)
	var stage_label := Label.new()
	stage_label.text = "Stage"
	stage_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	head.add_child(stage_label)
	var up_btn := Button.new()
	up_btn.text = "▲"
	up_btn.tooltip_text = "Move stage up"
	up_btn.pressed.connect(_on_stage_move.bind(panel, -1))
	head.add_child(up_btn)
	var down_btn := Button.new()
	down_btn.text = "▼"
	down_btn.tooltip_text = "Move stage down"
	down_btn.pressed.connect(_on_stage_move.bind(panel, 1))
	head.add_child(down_btn)
	var del_btn := Button.new()
	del_btn.text = "✕"
	del_btn.tooltip_text = "Delete stage"
	del_btn.pressed.connect(_on_stage_delete.bind(panel))
	head.add_child(del_btn)

	# Ask.
	v.add_child(_label_for("Ask the LLM"))
	var ask_edit := TextEdit.new()
	ask_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ask_edit.custom_minimum_size.y = 56
	ask_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	ask_edit.text = String(stage_data.get("ask", ""))
	ask_edit.set_meta("role", "ask")
	v.add_child(ask_edit)

	# keep_when.
	var kw_row := HBoxContainer.new()
	v.add_child(kw_row)
	var kw_label := Label.new()
	kw_label.text = "keep_when (optional)"
	kw_row.add_child(kw_label)
	var kw_edit := LineEdit.new()
	kw_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kw_edit.placeholder_text = "e.g.  doc_type in [\"1099\", \"W-2\"]"
	kw_edit.text = String(stage_data.get("keep_when", ""))
	kw_edit.set_meta("role", "keep_when")
	kw_row.add_child(kw_edit)

	# Slots header.
	var slots_header := HBoxContainer.new()
	v.add_child(slots_header)
	var sh_label := Label.new()
	sh_label.text = "Classify slots"
	sh_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slots_header.add_child(sh_label)
	var add_slot := Button.new()
	add_slot.text = "+ Add slot"
	slots_header.add_child(add_slot)

	# Slots container (named so _harvest can find it).
	var slots_box := VBoxContainer.new()
	slots_box.name = "_SlotsBox"
	slots_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(slots_box)

	add_slot.pressed.connect(_on_add_slot_pressed.bind(slots_box))

	# Populate existing slots.
	var classify: Dictionary = stage_data.get("classify", {})
	# Stable order: alphabetical (matches BTreeMap on save).
	var keys: Array = classify.keys()
	keys.sort()
	for k in keys:
		var slot_data: Dictionary = classify.get(k, {})
		slots_box.add_child(_make_slot_widget(String(k), slot_data))

	return panel

func _make_slot_widget(slot_name: String, slot_data: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(v)

	var top := HBoxContainer.new()
	v.add_child(top)

	var name_edit := LineEdit.new()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.placeholder_text = "slot_name (e.g. year, issuer, doc_type)"
	name_edit.text = slot_name
	name_edit.set_meta("role", "slot_name")
	top.add_child(name_edit)

	var del := Button.new()
	del.text = "✕"
	del.tooltip_text = "Delete slot"
	del.pressed.connect(_on_slot_delete.bind(panel))
	top.add_child(del)

	var desc_edit := LineEdit.new()
	desc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_edit.placeholder_text = "human-readable description"
	desc_edit.text = String(slot_data.get("description", ""))
	desc_edit.set_meta("role", "slot_desc")
	v.add_child(desc_edit)

	# Values: detect Open (string) vs Closed (array). Default Open.
	var values_var = slot_data.get("values", "")
	var is_closed: bool = values_var is Array
	var values_row := HBoxContainer.new()
	v.add_child(values_row)
	var mode_lbl := Label.new()
	mode_lbl.text = "Values:"
	values_row.add_child(mode_lbl)
	var mode_opt := OptionButton.new()
	mode_opt.add_item("Open (natural language)", 0)
	mode_opt.add_item("Closed (enumeration)", 1)
	mode_opt.selected = 1 if is_closed else 0
	mode_opt.set_meta("role", "slot_mode")
	values_row.add_child(mode_opt)

	var values_edit := TextEdit.new()
	values_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	values_edit.custom_minimum_size.y = 56
	values_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	values_edit.set_meta("role", "slot_values")
	if is_closed:
		values_edit.text = "\n".join(_array_to_string_lines(values_var))
		values_edit.placeholder_text = "One value per line"
	else:
		values_edit.text = String(values_var)
		values_edit.placeholder_text = "Natural-language constraint, e.g. \"a 4-digit year\""
	v.add_child(values_edit)

	mode_opt.item_selected.connect(_on_slot_mode_changed.bind(values_edit))

	return panel

func _array_to_string_lines(arr_var) -> Array:
	var arr: Array = arr_var if arr_var is Array else []
	var out: Array = []
	for x in arr:
		out.append(String(x))
	return out

# ---------------------------------------------------------------------------
# Data load / select
# ---------------------------------------------------------------------------

func _load_library() -> void:
	if _conn == null:
		_set_error("No MCP connection.")
		return
	var result: Dictionary = await _conn.call_tool("minerva_scansort_library_list_rules", {})
	if not bool(result.get("ok", false)):
		_set_error("library_list_rules failed: " + str(result.get("error", "?")))
		return
	_rules = result.get("rules", [])
	_rebuild_list()
	_set_error("")
	# Auto-select first if any.
	if _rules.size() > 0:
		_list.select(0)
		_on_rule_selected(0)

func _rebuild_list() -> void:
	_list.clear()
	for r in _rules:
		var label_text := String(r.get("label", "?"))
		var enabled: bool = bool(r.get("enabled", true))
		if not enabled:
			label_text += "  (disabled)"
		_list.add_item(label_text)

func _on_rule_selected(idx: int) -> void:
	if idx < 0 or idx >= _rules.size():
		return
	_current_index = idx
	_is_new = false
	_working = _deep_copy_dict(_rules[idx])
	_delete_btn.disabled = false
	_render_form()

func _deep_copy_dict(d: Dictionary) -> Dictionary:
	# JSON round-trip — small dicts only, fine for rule shape.
	return JSON.parse_string(JSON.stringify(d))

# ---------------------------------------------------------------------------
# Form render / harvest
# ---------------------------------------------------------------------------

func _render_form() -> void:
	_set_form_enabled(true)
	_f_label.text = String(_working.get("label", ""))
	# Label is the primary key — only editable on new rules.
	_f_label.editable = _is_new
	_f_name.text = String(_working.get("name", ""))
	_f_order.value = int(_working.get("order", 0))
	_f_instruction.text = String(_working.get("instruction", ""))
	_f_subfolder.text = String(_working.get("subfolder", ""))
	_f_rename_pattern.text = String(_working.get("rename_pattern", ""))
	_f_threshold.value = float(_working.get("confidence_threshold", 0.6))
	_f_enabled.button_pressed = bool(_working.get("enabled", true))
	_f_encrypt.button_pressed = bool(_working.get("encrypt", false))
	_f_stop.button_pressed = bool(_working.get("stop_processing", false))
	_f_default.button_pressed = bool(_working.get("is_default", false))

	_clear_stages_container()
	var stages: Array = _working.get("stages", [])
	for st in stages:
		_stages_container.add_child(_make_stage_widget(st))

func _clear_stages_container() -> void:
	for c in _stages_container.get_children():
		_stages_container.remove_child(c)
		c.queue_free()

func _harvest_form() -> Dictionary:
	var out := {}
	out["label"] = _f_label.text.strip_edges()
	out["name"] = _f_name.text
	out["order"] = int(_f_order.value)
	out["instruction"] = _f_instruction.text
	out["subfolder"] = _f_subfolder.text
	out["rename_pattern"] = _f_rename_pattern.text
	out["confidence_threshold"] = float(_f_threshold.value)
	out["enabled"] = _f_enabled.button_pressed
	out["encrypt"] = _f_encrypt.button_pressed
	out["stop_processing"] = _f_stop.button_pressed
	out["is_default"] = _f_default.button_pressed
	out["stages"] = _harvest_stages()
	return out

func _harvest_stages() -> Array:
	var stages: Array = []
	for stage_panel in _stages_container.get_children():
		var stage_dict := {"ask": "", "classify": {}}
		var slots_box: VBoxContainer = stage_panel.find_child("_SlotsBox", true, false)
		# Walk the stage's children for ask + keep_when.
		_walk_for_roles(stage_panel, stage_dict, slots_box)
		# Walk slots.
		if slots_box != null:
			for slot_panel in slots_box.get_children():
				var sd := _harvest_slot(slot_panel)
				if sd.is_empty():
					continue
				var name_key := String(sd.get("_name", ""))
				if name_key.is_empty():
					continue
				sd.erase("_name")
				stage_dict["classify"][name_key] = sd
		stages.append(stage_dict)
	return stages

func _walk_for_roles(root: Node, stage_dict: Dictionary, slots_box_skip: Node) -> void:
	for c in root.get_children():
		if c == slots_box_skip:
			continue
		var role_var = c.get_meta("role") if c.has_meta("role") else null
		var role := String(role_var) if role_var != null else ""
		if role == "ask" and c is TextEdit:
			stage_dict["ask"] = c.text
		elif role == "keep_when" and c is LineEdit:
			var t: String = c.text.strip_edges()
			if not t.is_empty():
				stage_dict["keep_when"] = t
		if c.get_child_count() > 0:
			_walk_for_roles(c, stage_dict, slots_box_skip)

func _harvest_slot(slot_panel: Node) -> Dictionary:
	var out := {"description": "", "values": ""}
	var name_text := ""
	var mode_closed := false
	var values_text := ""
	_visit_slot_widgets(slot_panel, func(role: String, w: Node):
		match role:
			"slot_name":
				name_text = (w as LineEdit).text.strip_edges()
			"slot_desc":
				out["description"] = (w as LineEdit).text
			"slot_mode":
				mode_closed = (w as OptionButton).selected == 1
			"slot_values":
				values_text = (w as TextEdit).text
	)
	if mode_closed:
		var lines: Array = []
		for ln in values_text.split("\n"):
			var s: String = String(ln).strip_edges()
			if not s.is_empty():
				lines.append(s)
		out["values"] = lines
	else:
		out["values"] = values_text.strip_edges()
	out["_name"] = name_text
	return out

func _visit_slot_widgets(root: Node, fn: Callable) -> void:
	for c in root.get_children():
		var role_var = c.get_meta("role") if c.has_meta("role") else null
		if role_var != null:
			fn.call(String(role_var), c)
		if c.get_child_count() > 0:
			_visit_slot_widgets(c, fn)

# ---------------------------------------------------------------------------
# Button handlers
# ---------------------------------------------------------------------------

func _on_new_pressed() -> void:
	_current_index = -1
	_is_new = true
	_working = {
		"label": "",
		"name": "",
		"instruction": "",
		"subfolder": "",
		"rename_pattern": "",
		"confidence_threshold": 0.6,
		"encrypt": false,
		"enabled": true,
		"is_default": false,
		"order": 0,
		"stop_processing": false,
		"stages": [],
	}
	_delete_btn.disabled = true
	_render_form()
	_list.deselect_all()
	_set_error("")

func _on_delete_pressed() -> void:
	if _current_index < 0 or _current_index >= _rules.size():
		return
	var label: String = String(_rules[_current_index].get("label", ""))
	if label.is_empty():
		return
	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_library_delete_rule", {"label": label}
	)
	if not bool(result.get("ok", false)):
		_set_error("Delete failed: " + str(result.get("error", "?")))
		return
	emit_signal("rules_changed")
	await _load_library()
	_set_form_enabled(false)
	_current_index = -1

func _on_save_pressed() -> void:
	var dict := _harvest_form()
	var label: String = String(dict.get("label", ""))
	if label.is_empty():
		_set_error("Label is required.")
		return
	# Sanity: slot-name uniqueness across stages (server enforces too, but we
	# can give a friendlier message here).
	var seen := {}
	for st in dict.get("stages", []):
		var classify: Dictionary = st.get("classify", {})
		for k in classify.keys():
			if seen.has(k):
				_set_error("Slot name '%s' is used in multiple stages — names must be unique." % k)
				return
			seen[k] = true
	var tool: String
	if _is_new:
		tool = "minerva_scansort_library_insert_rule"
	else:
		tool = "minerva_scansort_library_update_rule"
	var result: Dictionary = await _conn.call_tool(tool, dict)
	if not bool(result.get("ok", false)):
		_set_error("Save failed: " + str(result.get("error", "?")))
		return
	_set_error("Saved.")
	emit_signal("rules_changed")
	await _load_library()
	# Try to re-select what we just saved.
	for i in range(_rules.size()):
		if String(_rules[i].get("label", "")) == label:
			_list.select(i)
			_on_rule_selected(i)
			break

func _on_revert_pressed() -> void:
	if _is_new:
		_on_new_pressed()
	elif _current_index >= 0 and _current_index < _rules.size():
		_on_rule_selected(_current_index)

func _on_add_stage_pressed() -> void:
	_stages_container.add_child(_make_stage_widget({"ask": "", "classify": {}}))

func _on_stage_move(panel: Node, delta: int) -> void:
	var idx: int = panel.get_index()
	var new_idx: int = idx + delta
	if new_idx < 0 or new_idx >= _stages_container.get_child_count():
		return
	_stages_container.move_child(panel, new_idx)

func _on_stage_delete(panel: Node) -> void:
	_stages_container.remove_child(panel)
	panel.queue_free()

func _on_add_slot_pressed(slots_box: VBoxContainer) -> void:
	slots_box.add_child(_make_slot_widget("", {"description": "", "values": ""}))

func _on_slot_delete(slot_panel: Node) -> void:
	var parent: Node = slot_panel.get_parent()
	parent.remove_child(slot_panel)
	slot_panel.queue_free()

func _on_slot_mode_changed(idx: int, values_edit: TextEdit) -> void:
	# Reset placeholder + content style; leave existing text so the user can
	# convert manually if they want.
	if idx == 1:
		values_edit.placeholder_text = "One value per line"
	else:
		values_edit.placeholder_text = "Natural-language constraint, e.g. \"a 4-digit year\""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _section_header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	return l

func _label_for(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	return l

func _set_form_enabled(en: bool) -> void:
	for w in [
		_f_label, _f_name, _f_order, _f_instruction, _f_subfolder,
		_f_rename_pattern, _f_threshold, _f_enabled, _f_encrypt,
		_f_stop, _f_default, _add_stage_btn, _save_btn, _revert_btn,
	]:
		_set_widget_enabled(w, en)
	if _stages_container != null:
		_stages_container.visible = en
	if not en:
		_f_label.text = ""
		_f_name.text = ""
		_f_instruction.text = ""
		_f_subfolder.text = ""
		_f_rename_pattern.text = ""
		_clear_stages_container()

func _set_widget_enabled(w: Node, en: bool) -> void:
	if w == null:
		return
	if w is BaseButton:
		(w as BaseButton).disabled = not en
	elif w is LineEdit:
		(w as LineEdit).editable = en
	elif w is TextEdit:
		(w as TextEdit).editable = en
	elif w is SpinBox:
		(w as SpinBox).editable = en

func _set_error(text: String) -> void:
	if _error_label != null:
		_error_label.text = text
