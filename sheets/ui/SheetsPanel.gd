class_name Sheets_Panel
extends "res://Scripts/Services/Plugins/MinervaPluginPanel.gd"
## The host owns files and project snapshots; the copied domain owns the model.

const SpreadsheetEditorScript := preload("domain/SpreadsheetEditor.gd")
const SpreadsheetDataScript := preload("domain/SpreadsheetData.gd")
const Snapshot := preload("snapshot.gd")
const SheetRegistry := preload("sheet_registry.gd")
const Tools := preload("MCPSpreadsheetTools.gd")
const FilterTools := preload("MCPSpreadsheetFilterTools.gd")
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
	sheet.export_failed.connect(_show_export_error)
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

func _on_panel_capture_live_state() -> Dictionary:
	return {"document": sheet.serialize(), "history": sheet.history.capture_live_state()}

func _on_panel_restore_live_state(state: Dictionary) -> bool:
	if not state.get("document") is Dictionary or not Snapshot.validate(state.document) or not state.get("history") is Dictionary:
		return false
	if not sheet.history.restore_live_state(state.history):
		return false
	sheet.deserialize(state.document)
	_snapshot_restored = true
	return true

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
	var result: Dictionary = Tools.read_data(data, {"format": "markdown"})
	return [{"type": "text", "text": result.data if result.success else JSON.stringify(result)}]

func _on_panel_create_note_request(_context: Dictionary) -> Dictionary:
	var data: SpreadsheetDataScript = sheet.spreadsheet_data
	return {"kind": "plugin_data", "payload": sheet.serialize(),
		"preview_alt_text": data.to_markdown()}

func _on_panel_restore_from_note(payload: Dictionary) -> bool:
	if payload.size() == 2 and payload.get("version") == 1 and payload.get("legacy_markdown") is String:
		var markdown: String = payload.legacy_markdown
		return _restore_legacy_note(markdown)
	if not Snapshot.validate(payload):
		return false
	sheet.deserialize(payload)
	_snapshot_restored = true
	return true

func _create_snapshot_note(arguments: Dictionary, context: Object = null) -> Dictionary:
	_note_sequence += 1
	var reply_id := "sheets-note:%d" % _note_sequence
	var ipc: Node = get_node("_MinervaIPC")
	var payload := {"editor_name": _panel_key,
		"thread": arguments.get("thread_name", "Spreadsheets"),
		"title": arguments.get("note_title", get_sheet_name())}
	var response: Dictionary
	if context != null:
		response = await ipc.call("request_capability", "host.notes.create_from_editor", payload, context)
	else:
		request.emit("capability:host.notes.create_from_editor", payload, reply_id)
		response = await ipc.call("await_reply", reply_id)
	if context != null and context.call("is_stopped"):
		return context.call("stopped_result")
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
	return await handle_tool_with_context(tool_name, arguments, null)

## The host supplies the native per-call lifetime; no private host import.
func handle_tool_with_context(tool_name: String, arguments: Dictionary, context: Object) -> Dictionary:
	if context != null and context.call("is_stopped"):
		return context.call("stopped_result")
	if not _loaded or not is_inside_tree():
		return {"success": false, "error_code": "panel_unavailable", "error_message": "Spreadsheet panel is not available."}
	if tool_name == "minerva_sheets_link_to_note":
		return await _create_snapshot_note(arguments, context)
	if tool_name == "minerva_sheets_export_to_nudge":
		status.text = "Nudge is unavailable through the plugin host. The spreadsheet has not changed."
		status.show()
		push_error(status.text)
		return {"success": false, "error_code": "nudge_unavailable", "error_message": status.text}
	if tool_name.begins_with("minerva_sheets_autofilter_"):
		return _filters.handle(tool_name, arguments)
	return await _tools.handle(tool_name, arguments, context)

func _restore_legacy_note(markdown: String) -> bool:
	var prepared: Dictionary = _prepare_legacy_note(markdown)
	var data: SpreadsheetDataScript = sheet.spreadsheet_data
	var text: String = prepared.text
	data.from_markdown(text)
	sheet.sync_charts_from_data()
	var canvas: Control = sheet.cells_canvas
	canvas.queue_redraw()
	_snapshot_restored = true
	if prepared.partial:
		status.text = "Couldn't fully read this note's table. The original note is unchanged."
		status.show()
		push_warning(status.text)
	else:
		status.hide()
	return true

static func _prepare_legacy_note(markdown: String) -> Dictionary:
	var accepted := PackedStringArray()
	var chart_lines := PackedStringArray()
	var in_chart: bool = false
	var partial: bool = false
	var rows: int = 0
	var columns: int = -1
	for line: String in markdown.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed == "<!-- SPREADSHEET_CHARTS" and not in_chart:
			in_chart = true
			continue
		if in_chart:
			if trimmed != "-->":
				chart_lines.append(line)
				continue
			in_chart = false
			var parser := JSON.new()
			if parser.parse("\n".join(chart_lines)) == OK and Snapshot.validate_charts(parser.data):
				accepted.append("<!-- SPREADSHEET_CHARTS\n" + JSON.stringify(parser.data) + "\n-->")
			else:
				partial = true
			chart_lines.clear()
			continue
		if trimmed.is_empty():
			continue
		if not trimmed.begins_with("|") or not trimmed.ends_with("|"):
			partial = true
			continue
		var separator: String = trimmed.replace("|", "").replace("-", "").replace(":", "").replace(" ", "")
		if not (separator.is_empty() and trimmed.contains("-")):
			rows += 1
			var width: int = trimmed.count("|") - 1
			if columns != -1 and width != columns:
				partial = true
			columns = width
		accepted.append(line)
	return {"text": "\n".join(accepted), "partial": partial or in_chart or rows < 2}


func _show_export_error(message: String) -> void:
	status.text = message
	status.show()
	push_error(message)
