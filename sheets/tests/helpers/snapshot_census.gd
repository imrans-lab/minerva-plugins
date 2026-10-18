extends RefCounted
## Producer evidence is independent of the validator's hand-written field table.
const Snapshot := preload("../../ui/snapshot.gd")
const FIXTURE: String = "res://test/fixtures/spreadsheet_contract/"
var models: int = 0

func _keys_match(actual: Dictionary, expected: Dictionary) -> bool:
	var left: Array = actual.keys()
	var right: Array = expected.keys()
	left.sort()
	right.sort()
	return left == right

func _union(records: Array) -> Dictionary:
	var found: Dictionary = {}
	for record: Dictionary in records:
		for key: String in record:
			found[key] = true
	return found

func _walk(value: Variant, path: String, check: Callable) -> void:
	if value is Dictionary:
		var object: Dictionary = value
		if object.has_all(["version", "row_count", "column_count", "cells"]):
			if path.begins_with(FIXTURE + "future.minsheet"):
				check.call("intentional future snapshot remains refused", not Snapshot.validate(object))
			else:
				models += 1
				check.call("existing complete snapshot validates " + path, Snapshot.validate(object))
			return
		for key: Variant in object:
			_walk(object[key], path + "/" + str(key), check)
	elif value is Array:
		var array: Array = value
		for index: int in array.size():
			_walk(array[index], path + "/" + str(index), check)

func run(check: Callable, pane: EditorPane, source: String) -> void:
	var frozen: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE + "session.minproj"))
	var editor: Editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Every snapshot feature")
	var panel: Control = editor.plugin_scene_root
	PluginScenePanelHost.invoke_load(panel, frozen.Editors[0].content)
	var data: RefCounted = panel.call("get_sheet_data")
	data.call("set_cell_value", 0, 2, "=1<2")
	var cell: RefCounted = data.call("get_cell", 0, 2)
	for property: String in ["bold", "italic", "wrap_text"]:
		cell.set(property, true)
	cell.set("alignment", HORIZONTAL_ALIGNMENT_RIGHT)
	cell.set("text_color", Color(0.1, 0.2, 0.3, 1.0))
	cell.set("bg_color", Color(0.2, 0.3, 0.4, 0.5))
	cell.set("date_format", "MM/DD/YYYY")
	cell.set("number_format", "percent")
	var columns: Array = data.get("column_meta")
	var column: RefCounted = columns[-1]
	column.set("width", 140.0)
	column.set("header_name", "Feature date column")
	column.set("is_date_column", true)
	var rows: Array = data.get("row_meta")
	var row: RefCounted = rows[0]
	row.set("height", 32.0)
	row.set("is_header", true)
	data.set("header_row_count", 1)
	data.set("frozen_rows", 1)
	data.set("frozen_cols", 1)
	var filter: RefCounted = data.get("autofilter")
	filter.call("set_range", Rect2i(0, 0, 2, 3))
	filter.call("set_value_filter", 0, PackedStringArray(["keep"]))
	filter.call("set_text_filter", 1, "2")
	data.call("recalculate_all")
	var actual: Dictionary = PluginScenePanelHost.invoke_save(panel, {})
	check.call("actual all-feature serializer output validates", Snapshot.validate(actual))
	check.call("all-feature snapshot restores through the public hook", PluginScenePanelHost.invoke_restore_from_note(panel, actual))
	var reopened: Dictionary = PluginScenePanelHost.invoke_save(panel, {})
	check.call("every emitted feature survives real panel save/reload", JSON.parse_string(JSON.stringify(actual)) == JSON.parse_string(JSON.stringify(reopened)))
	editor.free()
	var files: PackedStringArray = DirAccess.get_files_at(FIXTURE)
	files.sort()
	for filename: String in files:
		if filename.get_extension() not in ["json", "minsheet", "minproj"]:
			continue
		var parser := JSON.new()
		var result: Error = parser.parse(FileAccess.get_file_as_string(FIXTURE + filename))
		if filename == "malformed.minsheet":
			check.call("malformed B0 file remains an explicit negative", result != OK)
			continue
		check.call("B0 JSON fixture parses " + filename, result == OK)
		if result == OK:
			_walk(parser.data, FIXTURE + filename, check)
	var capture := JSON.new()
	var capture_path: String = source.path_join("tests/fixtures/builtin-tool-oracle.json")
	check.call("frozen capture JSON is readable", capture.parse(FileAccess.get_file_as_string(capture_path)) == OK)
	_walk(capture.data, "frozen-capture", check)
	check.call("positive audit observed B0 and captured complete models", models == 40)
	print("SNAPSHOT_CENSUS_MODELS=" + str(models))
