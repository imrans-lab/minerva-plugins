@tool
extends EditorPlugin

const OUTPUT_PATH := "res://.codetools/godot_probe/debugger_state.json"
const SCAN_REQUEST_PATH := "res://.codetools/godot_probe/scan_request.json"
const CAPTURE_INTERVAL_SECONDS := 0.5
const SWEEP_SETTLE_FRAMES := 3
const MAX_TEXT_LENGTH := 1200
const MAX_OUTPUT_TEXT_LENGTH := 20000
const MAX_DIAGNOSTIC_ROWS := 40
const DEBUGGER_REGION_HEIGHT := 520.0

var _elapsed := 0.0

# Automatic open-scripts sweep (fix 2 follow-up, 019e988adc59): on a worker
# request (scan_request.json), cycle every open script through the active editor
# — letting each one's warnings panel populate — scrape it, then RESTORE the
# user's original script. A frame-based state machine so warnings have time to
# settle after each switch; runs ONLY on request (never on the passive cadence)
# so it doesn't hijack focus.
var _sweep_active := false
var _sweep_scripts: Array = []
var _sweep_index := 0
var _sweep_results: Array = []
var _sweep_saved: Script = null
var _sweep_settle := 0
var _sweep_nonce := ""
var _last_sweep: Dictionary = {}


func _enter_tree() -> void:
	set_process(true)
	_capture_debugger_state()


func _exit_tree() -> void:
	set_process(false)


func _process(delta: float) -> void:
	if _sweep_active:
		_sweep_step()  # run at frame rate while sweeping (not gated by the 0.5s cadence)
		return
	_elapsed += delta
	if _elapsed < CAPTURE_INTERVAL_SECONDS:
		return
	_elapsed = 0.0
	_check_scan_request()
	_capture_debugger_state()


func _check_scan_request() -> void:
	if not FileAccess.file_exists(SCAN_REQUEST_PATH):
		return
	var f := FileAccess.open(SCAN_REQUEST_PATH, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if not data is Dictionary:
		return
	var nonce := str((data as Dictionary).get("nonce", ""))
	if nonce == "" or nonce == _sweep_nonce:
		return  # already handled this request
	_begin_sweep(nonce)


func _begin_sweep(nonce: String) -> void:
	var ei := get_editor_interface()
	var se := ei.get_script_editor() if ei else null
	if se == null:
		return
	_sweep_nonce = nonce
	_sweep_saved = se.get_current_script()
	_sweep_scripts = se.get_open_scripts()
	_sweep_index = 0
	_sweep_results = []
	_sweep_active = true
	_sweep_goto_current()


func _sweep_goto_current() -> void:
	if _sweep_index >= _sweep_scripts.size():
		return
	var scr: Script = _sweep_scripts[_sweep_index]
	if scr != null:
		get_editor_interface().edit_script(scr)
	_sweep_settle = SWEEP_SETTLE_FRAMES


func _sweep_step() -> void:
	if _sweep_index >= _sweep_scripts.size():
		_finish_sweep()
		return
	if _sweep_settle > 0:
		_sweep_settle -= 1
		return
	var scr: Script = _sweep_scripts[_sweep_index]
	var path := scr.resource_path if scr else ""
	_sweep_results.append({"script": path, "warnings": _scrape_current_warnings()})
	_sweep_index += 1
	if _sweep_index < _sweep_scripts.size():
		_sweep_goto_current()
	else:
		_finish_sweep()


func _finish_sweep() -> void:
	if _sweep_saved != null:
		get_editor_interface().edit_script(_sweep_saved)  # restore the user's script
	_last_sweep = {"nonce": _sweep_nonce, "scripts": _sweep_results}
	_sweep_active = false
	if FileAccess.file_exists(SCAN_REQUEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SCAN_REQUEST_PATH))
	_capture_debugger_state()  # publish the sweep result immediately


func _capture_debugger_state() -> void:
	var base := get_editor_interface().get_base_control()
	var debugger_state := _read_debugger_state(base)
	var output_console_state := _read_output_console_state(base)
	var state := {
		"schema": "sightline.godot.editor_probe_state.v3",
		"project": ProjectSettings.get_setting("application/config/name", ""),
		"project_path": ProjectSettings.globalize_path("res://"),
		"captured_at_unix": Time.get_unix_time_from_system(),
		"source": "godot_editor_probe",
		"debugger": debugger_state,
		"output_console": output_console_state,
		"script_editor": _read_script_editor_warnings(),
		"provenance": {
			"adapter": "godot_editor_plugin",
			"plugin_id": "codetools_probe",
			"output_path": ProjectSettings.globalize_path(OUTPUT_PATH)
		}
	}
	_write_json(state)


# Script-editor Warnings panel scrape (fix 2, bug 019e988adc59). The reload
# warnings in the Debugger/Output have no res:// line; the script editor's
# warnings panel shows "Line N (CODE): message" for the CURRENT open script with
# the real line. file = the current script's path (read via EditorInterface).
var _warning_re: RegEx = null


func _read_script_editor_warnings() -> Dictionary:
	var result := {
		"schema": "codetools.godot.script_editor_warnings.v1",
		"current_script": "",
		"warnings": _scrape_current_warnings(),
		"sweep": _last_sweep,
	}
	var ei := get_editor_interface()
	var se := ei.get_script_editor() if ei else null
	if se != null:
		var cur: Script = se.get_current_script()
		if cur != null:
			result["current_script"] = cur.resource_path
	return result


func _scrape_current_warnings() -> Array:
	var warnings: Array = []
	var ei := get_editor_interface()
	var se := ei.get_script_editor() if ei else null
	if se == null:
		return warnings
	var panels: Array = []
	_collect_warning_panels(se, panels)
	var seen := {}
	for rtl in panels:
		var txt: String = rtl.get_parsed_text() if rtl.has_method("get_parsed_text") else str(rtl.text)
		for raw_line in txt.split("\n"):
			var parsed := _parse_warning_line(raw_line)
			if parsed.is_empty():
				continue
			var key := str(parsed.get("line")) + "|" + str(parsed.get("message"))
			if seen.has(key):
				continue
			seen[key] = true
			warnings.append(parsed)
	return warnings


func _collect_warning_panels(node: Node, out: Array) -> void:
	if node == null:
		return
	if node is RichTextLabel:
		var rtl := node as RichTextLabel
		var t: String = rtl.get_parsed_text() if rtl.has_method("get_parsed_text") else str(rtl.text)
		# The warnings panel lists "Line N (CODE): message" entries.
		if t.find("Line ") != -1 and t.find("):") != -1:
			out.append(rtl)
	for child in node.get_children():
		_collect_warning_panels(child, out)


func _parse_warning_line(line: String) -> Dictionary:
	var t := line.strip_edges()
	if not t.begins_with("Line "):
		return {}
	if _warning_re == null:
		_warning_re = RegEx.new()
		_warning_re.compile("^Line\\s+(\\d+)\\s*\\(([^)]*)\\):\\s*(.*)$")
	var m := _warning_re.search(t)
	if m == null:
		return {}
	return {
		"line": int(m.get_string(1)),
		"code": m.get_string(2),
		"message": m.get_string(3),
	}


func _read_debugger_state(root: Control) -> Dictionary:
	var text_controls: Array = []
	var tree_controls: Array = []
	var tab_bar_controls: Array = []
	_collect_controls(root, text_controls, tree_controls, tab_bar_controls)
	var tabs := _find_debugger_tabs(text_controls)
	var bottom_panel_controls: Array = []
	var debugger_subtree_rows: Array = []
	_collect_bottom_panel_diagnostics(root, bottom_panel_controls, debugger_subtree_rows)
	var rows: Array = []
	var regions: Array = []
	for tab in tabs:
		var region := _debugger_region_for_tab(root, tab)
		regions.append(region)
		_collect_rows_in_region(text_controls, tree_controls, region, rows)
	if rows.is_empty():
		rows.append_array(debugger_subtree_rows)
	rows = _dedupe_rows(rows)
	var tab_text := ""
	if not tabs.is_empty():
		tab_text = str(tabs[0].get("text", ""))
	var warning_count := _count_from_debugger_tab(tab_text)
	if warning_count < 0:
		warning_count = _count_warning_rows(rows)
	var extraction_status := "debugger_tab_not_found"
	if not tabs.is_empty():
		extraction_status = "scoped_debugger_region"
	elif not debugger_subtree_rows.is_empty():
		extraction_status = "debugger_subtree"
	return {
		"schema": "sightline.godot.debugger_rows.v2",
		"extraction_status": extraction_status,
		"tab_text": tab_text,
		"warning_count": warning_count,
		"error_count": _count_error_rows(rows),
		"rows": rows,
		"diagnostics": {
			"debugger_tabs": tabs.slice(0, MAX_DIAGNOSTIC_ROWS),
			"regions": regions,
			"tab_bar_candidates": tab_bar_controls.slice(0, MAX_DIAGNOSTIC_ROWS),
			"text_candidate_count": text_controls.size(),
			"tree_candidate_count": tree_controls.size(),
			"text_candidate_samples": text_controls.slice(0, MAX_DIAGNOSTIC_ROWS),
			"tree_candidate_samples": tree_controls.slice(0, MAX_DIAGNOSTIC_ROWS),
			"bottom_panel_controls": bottom_panel_controls.slice(0, MAX_DIAGNOSTIC_ROWS * 2),
			"debugger_subtree_rows": debugger_subtree_rows.slice(0, MAX_DIAGNOSTIC_ROWS),
			"row_count": rows.size(),
			"row_samples": rows.slice(0, MAX_DIAGNOSTIC_ROWS)
		}
	}


func _read_output_console_state(root: Control) -> Dictionary:
	var records: Array = []
	var text_parts: Array = []
	var counters: Array = []
	_collect_output_console(root, false, records, text_parts, counters)
	var text := _trim_output_text("\n".join(text_parts).strip_edges())
	var lines := _split_lines(text)
	var extraction_status := "output_panel_not_found"
	if not records.is_empty():
		extraction_status = "output_panel_found"
	if not text.is_empty():
		extraction_status = "output_text_found"
	return {
		"schema": "sightline.godot.output_console.v1",
		"extraction_status": extraction_status,
		"text": text,
		"line_count": lines.size(),
		"lines": lines.slice(0, MAX_DIAGNOSTIC_ROWS),
		"counters": counters,
		"diagnostics": {
			"output_controls": records.slice(0, MAX_DIAGNOSTIC_ROWS * 2),
			"text_part_count": text_parts.size()
		}
	}


func _collect_output_console(
	node: Node,
	in_output_subtree: bool,
	records: Array,
	text_parts: Array,
	counters: Array
) -> void:
	if node == null:
		return
	var node_name := str(node.name)
	var node_path := str(node.get_path())
	var next_in_output_subtree := in_output_subtree or (
		node_path.contains("EditorBottomPanel")
		and (node_path.contains("/Output") or node_name == "Output")
	)
	if node is Control and next_in_output_subtree:
		var control := node as Control
		var text := _node_text(control)
		var record := _control_record(control, text)
		record["visible"] = control.visible
		record["visible_in_tree"] = control.is_visible_in_tree()
		if records.size() < MAX_DIAGNOSTIC_ROWS * 2:
			records.append(record)
		if control is RichTextLabel or control is TextEdit:
			var raw_text := _raw_node_text(control).strip_edges()
			if not raw_text.is_empty():
				text_parts.append(raw_text)
		elif control is Button:
			var stripped := text.strip_edges()
			if stripped.is_valid_int():
				counters.append({
					"text": stripped,
					"node_path": node_path,
					"name": node_name,
					"rect": record.get("rect", {})
				})
	for child in node.get_children():
		_collect_output_console(child, next_in_output_subtree, records, text_parts, counters)


func _collect_controls(node: Node, text_controls: Array, tree_controls: Array, tab_bar_controls: Array) -> void:
	if node == null:
		return
	if node is Control and (node as Control).is_visible_in_tree():
		var control := node as Control
		if control is TabBar:
			_collect_tab_bar_records(control as TabBar, text_controls, tab_bar_controls)
		if control is Tree:
			tree_controls.append(_control_record(control, ""))
		var text := _node_text(control)
		if not text.is_empty():
			text_controls.append(_control_record(control, text))
	for child in node.get_children():
		_collect_controls(child, text_controls, tree_controls, tab_bar_controls)


func _node_text(control: Control) -> String:
	return _trim_text(_raw_node_text(control).strip_edges())


func _raw_node_text(control: Control) -> String:
	var text := ""
	if control is Button:
		text = (control as Button).text
	elif control is Label:
		text = (control as Label).text
	elif control is RichTextLabel:
		text = (control as RichTextLabel).get_parsed_text()
	elif control is LineEdit:
		text = (control as LineEdit).text
	elif control is TextEdit:
		text = (control as TextEdit).text
	return text


func _control_record(control: Control, text: String) -> Dictionary:
	var rect := control.get_global_rect()
	return {
		"node_path": str(control.get_path()),
		"class": control.get_class(),
		"name": str(control.name),
		"text": _trim_text(text),
		"rect": _rect_dict(rect)
	}


func _collect_tab_bar_records(tab_bar: TabBar, text_controls: Array, tab_bar_controls: Array) -> void:
	var titles: Array = []
	for index in range(tab_bar.tab_count):
		var text := tab_bar.get_tab_title(index).strip_edges()
		titles.append(text)
		if text.is_empty():
			continue
		var tab_rect := tab_bar.get_tab_rect(index)
		var global_rect := Rect2(tab_bar.get_global_position() + tab_rect.position, tab_rect.size)
		var record := {
			"node_path": str(tab_bar.get_path()),
			"class": tab_bar.get_class(),
			"name": str(tab_bar.name),
			"text": _trim_text(text),
			"rect": _rect_dict(global_rect),
			"tab_index": index,
			"selected": tab_bar.current_tab == index
		}
		text_controls.append(record)
	tab_bar_controls.append({
		"node_path": str(tab_bar.get_path()),
		"class": tab_bar.get_class(),
		"name": str(tab_bar.name),
		"rect": _rect_dict(tab_bar.get_global_rect()),
		"current_tab": tab_bar.current_tab,
		"tab_count": tab_bar.tab_count,
		"titles": titles
	})


func _find_debugger_tabs(text_controls: Array) -> Array:
	var tabs: Array = []
	for record in text_controls:
		var text := str(record.get("text", "")).strip_edges()
		if _is_debugger_tab_text(text):
			tabs.append(record)
	tabs.sort_custom(func(a, b): return float(a["rect"]["y"]) > float(b["rect"]["y"]))
	return tabs


func _is_debugger_tab_text(text: String) -> bool:
	if text == "Debugger":
		return true
	var regex := RegEx.new()
	if regex.compile("^Debugger\\s*\\((\\d+)\\)$") != OK:
		return false
	return regex.search(text) != null


func _debugger_region_for_tab(root: Control, tab: Dictionary) -> Dictionary:
	var tab_rect: Dictionary = tab.get("rect", {})
	var root_rect := root.get_global_rect()
	var tab_y := float(tab_rect.get("y", root_rect.position.y + root_rect.size.y))
	var region_y = max(root_rect.position.y, tab_y - DEBUGGER_REGION_HEIGHT)
	return {
		"x": root_rect.position.x,
		"y": region_y,
		"width": root_rect.size.x,
		"height": max(0.0, tab_y - region_y),
		"tab": tab
	}


func _collect_rows_in_region(text_controls: Array, tree_controls: Array, region: Dictionary, rows: Array) -> void:
	for record in text_controls:
		var text := str(record.get("text", "")).strip_edges()
		if _is_debugger_tab_text(text):
			continue
		if _record_inside_region(record, region) and _looks_like_debugger_message(text):
			rows.append(_row_record("control", text, record))
	for tree_record in tree_controls:
		if not _record_inside_region(tree_record, region):
			continue
		var node := get_node_or_null(NodePath(str(tree_record.get("node_path", ""))))
		if node is Tree:
			_collect_tree_rows(node as Tree, rows, true)


func _collect_tree_rows(tree: Tree, rows: Array, error_tree := false) -> void:
	var root := tree.get_root()
	if root == null:
		return
	if error_tree:
		# Debugger "Errors" tree: every direct child of root is a warning/error.
		# Capture each, regardless of message-pattern (the autocoder push_warning
		# rows don't start with "warning:"), and attach its detail children — the
		# <GDScript Source>/<Stack Trace> rows that carry file.gd:line.
		var item := root.get_first_child()
		var index := 0
		while item != null:
			var text := _join_columns(item, tree.columns)
			if not text.is_empty():
				var details: Array = []
				_collect_item_details(item, tree.columns, details)
				var row := _row_record("tree", text, _control_record(tree, ""))
				row["tree_row_index"] = index
				if not details.is_empty():
					row["details"] = details
				rows.append(row)
				index += 1
			item = item.get_next()
		return
	var counter := [0]
	_collect_tree_item_rows(root, tree.columns, rows, _control_record(tree, ""), counter)


func _join_columns(item: TreeItem, columns: int) -> String:
	var parts: Array[String] = []
	for column in range(columns):
		var text := item.get_text(column).strip_edges()
		if not text.is_empty():
			parts.append(text)
	return _trim_text(" ".join(parts))


func _collect_item_details(item: TreeItem, columns: int, details: Array) -> void:
	var child := item.get_first_child()
	while child != null:
		var text := _join_columns(child, columns)
		if not text.is_empty() and details.size() < 12:
			details.append(text)
		_collect_item_details(child, columns, details)
		child = child.get_next()


func _collect_tree_item_rows(item: TreeItem, columns: int, rows: Array, tree_record: Dictionary, counter: Array) -> void:
	var parts: Array[String] = []
	for column in range(columns):
		var text := item.get_text(column).strip_edges()
		if not text.is_empty():
			parts.append(text)
	var joined := _trim_text(" ".join(parts))
	var index := int(counter[0])
	counter[0] = index + 1
	if _looks_like_debugger_message(joined):
		var row := _row_record("tree", joined, tree_record)
		row["tree_row_index"] = index
		rows.append(row)
	var child := item.get_first_child()
	while child != null:
		_collect_tree_item_rows(child, columns, rows, tree_record, counter)
		child = child.get_next()


func _collect_bottom_panel_diagnostics(node: Node, bottom_panel_controls: Array, debugger_rows: Array) -> void:
	_collect_bottom_panel_diagnostics_inner(node, false, false, bottom_panel_controls, debugger_rows)


func _collect_bottom_panel_diagnostics_inner(
	node: Node,
	in_bottom_panel: bool,
	in_debugger_subtree: bool,
	bottom_panel_controls: Array,
	debugger_rows: Array
) -> void:
	if node == null:
		return
	var node_name := str(node.name)
	var node_path := str(node.get_path())
	var next_in_bottom_panel := in_bottom_panel or node_name.contains("EditorBottomPanel") or node_path.contains("EditorBottomPanel")
	var next_in_debugger_subtree := in_debugger_subtree or (
		next_in_bottom_panel and (node_name == "Debugger" or node_name.contains("Debugger") or node_path.contains("/Debugger"))
	)
	if node is Control and next_in_bottom_panel:
		var control := node as Control
		var record := _control_record(control, _node_text(control))
		record["visible"] = control.visible
		record["visible_in_tree"] = control.is_visible_in_tree()
		if bottom_panel_controls.size() < MAX_DIAGNOSTIC_ROWS * 2:
			bottom_panel_controls.append(record)
		if next_in_debugger_subtree:
			if control is Tree:
				_collect_tree_rows(control as Tree, debugger_rows, true)
			var text := str(record.get("text", "")).strip_edges()
			if _looks_like_debugger_message(text):
				debugger_rows.append(_row_record("debugger_subtree_control", text, record))
	for child in node.get_children():
		_collect_bottom_panel_diagnostics_inner(
			child,
			next_in_bottom_panel,
			next_in_debugger_subtree,
			bottom_panel_controls,
			debugger_rows
		)


func _row_record(source: String, text: String, record: Dictionary) -> Dictionary:
	return {
		"source": source,
		"text": _trim_text(text),
		"severity": _severity_for_text(text),
		"node_path": record.get("node_path", ""),
		"class": record.get("class", ""),
		"name": record.get("name", ""),
		"rect": record.get("rect", {})
	}


func _looks_like_debugger_message(text: String) -> bool:
	if text.is_empty():
		return false
	if text.length() > MAX_TEXT_LENGTH:
		return false
	var lowered := text.to_lower()
	return (
		lowered.begins_with("warning:")
		or lowered.begins_with("error:")
		or lowered.begins_with("script error:")
		or lowered.contains("gdscript::reload:")
		or lowered.contains(" is shadowing ")
		or lowered.contains(" declared below ")
		or lowered.contains("static function")
	)


func _severity_for_text(text: String) -> String:
	var lowered := text.to_lower()
	if lowered.begins_with("script error:"):
		return "script_error"
	if lowered.begins_with("error:"):
		return "error"
	if lowered.begins_with("warning:"):
		return "warning"
	if lowered.contains("gdscript::reload:") or lowered.contains("is shadowing") or lowered.contains("declared below") or lowered.contains("static function"):
		return "warning"
	return "issue"


func _record_inside_region(record: Dictionary, region: Dictionary) -> bool:
	var rect: Dictionary = record.get("rect", {})
	var x := float(rect.get("x", 0.0))
	var y := float(rect.get("y", 0.0))
	var width := float(rect.get("width", 0.0))
	var height := float(rect.get("height", 0.0))
	var rx := float(region.get("x", 0.0))
	var ry := float(region.get("y", 0.0))
	var rw := float(region.get("width", 0.0))
	var rh := float(region.get("height", 0.0))
	var center_x := x + width / 2.0
	var center_y := y + height / 2.0
	return center_x >= rx and center_x <= rx + rw and center_y >= ry and center_y <= ry + rh


func _dedupe_rows(rows: Array) -> Array:
	var seen := {}
	var output: Array = []
	for row in rows:
		var source := str(row.get("source", ""))
		var key := ""
		if source == "tree":
			key = "tree|" + str(row.get("node_path", "")) + "|" + str(row.get("tree_row_index", -1))
		else:
			key = source + "|" + str(row.get("severity", "")) + "|" + str(row.get("text", ""))
		if seen.has(key):
			continue
		seen[key] = true
		output.append(row)
	return output


func _count_from_debugger_tab(text: String) -> int:
	var regex := RegEx.new()
	if regex.compile("^Debugger\\s*\\((\\d+)\\)$") != OK:
		return -1
	var result := regex.search(text)
	if result == null:
		return -1
	return int(result.get_string(1))


func _count_warning_rows(rows: Array) -> int:
	var count := 0
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		if str(row.get("severity", "")) == "warning":
			count += 1
	return count


func _count_error_rows(rows: Array) -> int:
	var count := 0
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var severity := str(row.get("severity", ""))
		if severity == "error" or severity == "script_error":
			count += 1
	return count


func _rect_dict(rect: Rect2) -> Dictionary:
	return {
		"x": rect.position.x,
		"y": rect.position.y,
		"width": rect.size.x,
		"height": rect.size.y
	}


func _trim_text(text: String) -> String:
	if text.length() <= MAX_TEXT_LENGTH:
		return text
	return text.substr(0, MAX_TEXT_LENGTH) + "...<truncated>"


func _trim_output_text(text: String) -> String:
	if text.length() <= MAX_OUTPUT_TEXT_LENGTH:
		return text
	return text.substr(0, MAX_OUTPUT_TEXT_LENGTH) + "...<truncated>"


func _split_lines(text: String) -> Array:
	if text.is_empty():
		return []
	var output: Array = []
	for line in text.split("\n"):
		output.append(line)
	return output


func _write_json(state: Dictionary) -> void:
	var absolute_path := ProjectSettings.globalize_path(OUTPUT_PATH)
	var directory := absolute_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(state, "\t"))
	file.close()
