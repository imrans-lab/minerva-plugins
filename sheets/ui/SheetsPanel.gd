class_name Sheets_Panel
extends "res://Scripts/Services/Plugins/MinervaPluginPanel.gd"
## The host owns files and project snapshots; the copied domain owns the model.

const SpreadsheetEditorScript := preload("domain/SpreadsheetEditor.gd")
const SpreadsheetDataScript := preload("domain/SpreadsheetData.gd")
const SheetRegistry := preload("sheet_registry.gd")

@onready var sheet: SpreadsheetEditorScript = $Sheet
@onready var status: Label = $Status
var _editor: WeakRef

func _ready() -> void:
	sheet.sheet_resolver = SheetRegistry.resolve
	sheet.content_changed.connect(content_changed.emit)

func _on_panel_loaded(context: Dictionary) -> void:
	var editor: Object = context.get("editor")
	if editor != null:
		_editor = weakref(editor)
	SheetRegistry.register(self, get_sheet_name, get_sheet_data)

func _on_panel_unload() -> void:
	SheetRegistry.unregister(self)

func _exit_tree() -> void:
	SheetRegistry.unregister(self)

func get_sheet_name() -> String:
	var editor: Object = _editor.get_ref() if _editor != null else null
	return str(editor.get("tab_title")) if editor != null else ""

func get_sheet_data() -> RefCounted:
	return sheet.spreadsheet_data

func _on_panel_save_request() -> Dictionary:
	return sheet.serialize()

func _on_panel_load_request(document: Dictionary) -> void:
	status.hide()
	if get_document_action() in ["open", "import"]:
		var path: String = str(document.get("file_path", ""))
		var result: Error = sheet.load_file(path)
		if result != OK:
			status.text = "Couldn't open spreadsheet: %s (error %d)" % [path.get_file(), result]
			status.show()
	else:
		sheet.deserialize(document)

func _on_panel_undo_request() -> bool:
	return sheet.undo()

func _on_panel_redo_request() -> bool:
	return sheet.redo()

func _on_panel_render_for_llm(_context: Dictionary) -> Array:
	var data: SpreadsheetDataScript = sheet.spreadsheet_data
	return [{"type": "text", "text": data.to_markdown()}]

func handle_tool(_tool_name: String, _arguments: Dictionary) -> Dictionary:
	return {"success": false, "error_code": "sheets_staging", "error_message": "Spreadsheet tools are not available in this staging build."}
