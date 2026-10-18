class_name Sheets_Panel
extends "res://Scripts/Services/Plugins/MinervaPluginPanel.gd"
## The host owns files and project snapshots; the copied domain owns the model.

const SpreadsheetEditorScript := preload("domain/SpreadsheetEditor.gd")
const SpreadsheetDataScript := preload("domain/SpreadsheetData.gd")
const SheetRegistry := preload("sheet_registry.gd")
const Tools := preload("tools/MCPSpreadsheetTools.gd")
const FilterTools := preload("tools/MCPSpreadsheetFilterTools.gd")
var _tools: Tools
var _filters: FilterTools
var _loaded: bool = false
var _panel_key: String = ""
var _note_sequence: int = 0

@onready var sheet: SpreadsheetEditorScript = $Sheet
@onready var status: RichTextLabel = $Status
var _editor: WeakRef
var _snapshot_restored: bool = false

func _ready() -> void:
	sheet.sheet_resolver = SheetRegistry.resolve
	sheet.content_changed.connect(content_changed.emit)
	_tools = Tools.new(sheet, _matches_locator)
	_filters = FilterTools.new(sheet, _matches_locator)

func _on_panel_loaded(context: Dictionary) -> void:
	_loaded = true
	_panel_key = str(context.get("panel_key", ""))
	var editor: Object = context.get("editor")
	if editor != null:
		_editor = weakref(editor)
	SheetRegistry.register(self, get_sheet_name, get_sheet_data)

func _on_panel_unload() -> void:
	_loaded = false
	SheetRegistry.unregister(self)

func _exit_tree() -> void:
	_loaded = false
	SheetRegistry.unregister(self)

func get_sheet_name() -> String:
	var editor: Object = _editor.get_ref() if _editor != null else null
	return str(editor.get("tab_title")) if editor != null else ""

func _matches_locator(name_: String) -> bool:
	return name_ == get_sheet_name() or (not _panel_key.is_empty() and name_ == _panel_key)

func get_sheet_data() -> RefCounted:
	return sheet.spreadsheet_data

func _on_panel_save_request() -> Dictionary:
	return sheet.serialize()

func _on_panel_load_request(document: Dictionary) -> void:
	status.hide()
	if get_document_action() in ["open", "import"] or (document.has("file_path") and not _snapshot_restored):
		var path: String = str(document.get("file_path", ""))
		var result: Error = sheet.load_file(path)
		if result != OK:
			status.text = "Couldn't open spreadsheet: %s (error %d)" % [path.get_file(), result]
			status.show()
			push_error(status.text)
	elif not document.has("file_path"):
		# Restored snapshots win over the parent Editor backing-file replay.
		sheet.deserialize(document)
		_snapshot_restored = true

func _on_panel_undo_request() -> bool:
	return sheet.undo()

func _on_panel_redo_request() -> bool:
	return sheet.redo()

func _on_panel_render_for_llm(_context: Dictionary) -> Array:
	var data: SpreadsheetDataScript = sheet.spreadsheet_data
	return [{"type": "text", "text": data.to_markdown()}]

func _on_panel_create_note_request(_context: Dictionary) -> Dictionary:
	var data: SpreadsheetDataScript = sheet.spreadsheet_data
	return {"kind": "plugin_data", "payload": sheet.serialize(),
		"preview_alt_text": data.to_markdown()}

func _on_panel_restore_from_note(payload: Dictionary) -> bool:
	if not _valid_snapshot(payload):
		return false
	sheet.deserialize(payload)
	_snapshot_restored = true
	return true

func _create_snapshot_note(arguments: Dictionary) -> Dictionary:
	_note_sequence += 1
	var reply_id := "sheets-note:%d" % _note_sequence
	var ipc: Node = get_node("_MinervaIPC")
	request.emit("capability:host.notes.create_from_editor", {"editor_name": _panel_key,
		"thread": arguments.get("thread_name", "Spreadsheets"),
		"title": arguments.get("note_title", get_sheet_name())}, reply_id)
	var response: Dictionary = await ipc.call("await_reply", reply_id)
	if not _loaded or not is_inside_tree():
		return {"success": false, "error_code": "panel_unavailable", "error_message": "Spreadsheet panel closed during note creation."}
	if not response.get("success", false):
		status.text = str(response.get("error_message", "Snapshot note creation failed"))
		status.show()
		push_error(status.text)
		return response
	var result: Dictionary = response.get("result", {})
	result = result.duplicate(true)
	result["success"] = true
	result["linked_spreadsheet"] = get_sheet_name()
	result["message"] = "Created a snapshot note. Edit reopens this spreadsheet snapshot; later edits are not synchronized."
	return result

func handle_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	if not _loaded or not is_inside_tree():
		return {"success": false, "error_code": "panel_unavailable", "error_message": "Spreadsheet panel is not available."}
	if tool_name == "minerva_sheets_link_to_note":
		return await _create_snapshot_note(arguments)
	if tool_name == "minerva_sheets_export_to_nudge":
		status.text = "Nudge is unavailable through the plugin host. The spreadsheet has not changed."
		status.show()
		push_error(status.text)
		return {"success": false, "error_code": "nudge_unavailable", "error_message": status.text}
	if tool_name.begins_with("minerva_sheets_autofilter_"):
		return _filters.handle(tool_name, arguments)
	return await _tools.handle(tool_name, arguments)

## Session and note snapshots are opaque until the provider accepts the whole
## current format. Never partially load a malformed/future model.
func _valid_snapshot(model: Dictionary) -> bool:
	if model.get("version") != 1 or not model.get("cells") is Dictionary:
		return false
	for key: String in ["row_count", "column_count"]:
		var count: Variant = model.get(key)
		if not (count is int or count is float):
			return false
		var number: float = count
		if not is_finite(number) or number != floor(number) or number < 1:
			return false
	var schema: Dictionary = SpreadsheetDataScript.new(1, 1).to_dict()
	schema["charts"] = [preload("domain/SpreadsheetChart.gd").new().to_dict()]
	schema.charts[0].series = [{"range": "", "name": "", "color_r": 0.0, "color_g": 0.0, "color_b": 0.0, "color_a": 1.0}]
	schema["autofilter"] = {"range": [0], "columns": [{"col": 0, "type": "", "text": "", "values": [""]}]}
	var fields: Dictionary = model.duplicate()
	fields.erase("cells")
	if not _snapshot_shape(fields, schema):
		return false
	var cell_schema: Dictionary = {"type": 0, "formula": "", "bold": false, "italic": false, "alignment": 0,
		"text_color": "", "bg_color": "", "date_format": "", "number_format": "", "wrap_text": false}
	var cells: Dictionary = model.cells
	for key: String in cells:
		var parts: PackedStringArray = key.split(",")
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			return false
		var row_limit: int = model.row_count
		var col_limit: int = model.column_count
		if int(parts[0]) < 0 or int(parts[1]) < 0 or int(parts[0]) >= row_limit or int(parts[1]) >= col_limit:
			return false
		if not cells[key] is Dictionary:
			return false
		var record: Dictionary = cells[key]
		var cell: Dictionary = record.duplicate()
		var value: Variant = cell.get("value")
		if value != null and not (value is String or value is int or value is float):
			return false
		cell.erase("value")
		if not _snapshot_shape(cell, cell_schema):
			return false
	return true

static func _snapshot_shape(value: Variant, example: Variant) -> bool:
	if example is Dictionary:
		if not value is Dictionary:
			return false
		var fields: Dictionary = value
		var schema: Dictionary = example
		for key: Variant in fields:
			if not schema.has(key) or not _snapshot_shape(fields[key], schema[key]):
				return false
		return true
	if example is Array:
		if not value is Array:
			return false
		var items: Array = value
		var schema: Array = example
		for item: Variant in items:
			if schema.is_empty() or not _snapshot_shape(item, schema[0]):
				return false
		return true
	if example is int or example is float:
		if not (value is int or value is float):
			return false
		var number: float = value
		return is_finite(number) and (not example is int or number == floor(number))
	return typeof(value) == typeof(example)
