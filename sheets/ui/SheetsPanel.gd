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

func handle_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	if not _loaded or not is_inside_tree():
		return {"success": false, "error_code": "panel_unavailable", "error_message": "Spreadsheet panel is not available."}
	if tool_name in ["minerva_sheets_link_to_note", "minerva_sheets_export_to_nudge"]:
		var operation := "Snapshot note creation" if tool_name == "minerva_sheets_link_to_note" else "Nudge export"
		status.text = operation + " is unavailable in this staging build; it will be available in a later build."
		status.show()
		push_error(status.text)
		return {"success": false, "error_code": "sheets_staging", "error_message": status.text}
	if tool_name.begins_with("minerva_sheets_autofilter_"):
		return _filters.handle(tool_name, arguments)
	return await _tools.handle(tool_name, arguments)
