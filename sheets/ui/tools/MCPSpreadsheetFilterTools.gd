class_name Sheets_MCPSpreadsheetFilterTools
extends RefCounted
## Plugin-local tool module for spreadsheet AutoFilter: enable a filter range, set a
## column criterion, read the criteria and visible rows, clear one column or
## all criteria, or remove the filter.
##
## Every change goes through SpreadsheetAutoFilterActions with the editor's
## own SpreadsheetHistory, the same path the header dropdown and popup use, so
## MCP and UI changes share one model and one undo stack.
##
## Rows and columns are 1-based at the API. Every result that lists rows
## carries `scope`: "visible" when a criterion hides rows from the list,
## "all" when the list covers every data row. Filtering only hides rows;
## minerva_sheets_get_data always returns every row, hidden ones included.

const ToolUtils := preload("tool_utils.gd")
const SpreadsheetEditorScript := preload("../domain/SpreadsheetEditor.gd")
var _sheet: SpreadsheetEditorScript
var _matches_locator: Callable

const SpreadsheetDataScript := preload("../domain/SpreadsheetData.gd")
const SpreadsheetHistoryScript := preload("../domain/SpreadsheetHistory.gd")
const Actions := preload("../domain/SpreadsheetAutoFilterActions.gd")

const DEFAULT_ROW_LIMIT := 2000

## The sheet a call acts on. `panel` is the SpreadsheetEditor when the sheet
## lives in an editor tab (used to raise its content_changed); null otherwise.
## `error` is set instead when the name did not resolve.
class SheetTarget:
	var data: SpreadsheetDataScript = null
	var history: SpreadsheetHistoryScript = null
	var panel: Object = null
	var error: String = ""

## Resolves editor_name to a SheetTarget. Defaults to the open editor tabs;
## a headless caller can point it at its own sheet and history.
var find_sheet: Callable


func _init(sheet: SpreadsheetEditorScript = null, matches_locator: Callable = Callable()) -> void:
	_sheet = sheet
	_matches_locator = matches_locator
	find_sheet = _find_editor_sheet


func get_tool_names() -> Array[String]:
	return [
		"minerva_sheets_autofilter_enable",
		"minerva_sheets_autofilter_set",
		"minerva_sheets_autofilter_get",
		"minerva_sheets_autofilter_clear",
	]


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	var editor_name: String = str(arguments.get("editor_name", ""))
	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")
	var target: SheetTarget = find_sheet.call(editor_name)
	if not target.error.is_empty():
		return ToolUtils.error(target.error)

	match tool_name:
		"minerva_sheets_autofilter_enable":
			return _enable_filter(target, editor_name, arguments)
		"minerva_sheets_autofilter_set":
			return _set_criterion(target, editor_name, arguments)
		"minerva_sheets_autofilter_get":
			return _state(target, editor_name, arguments)
		"minerva_sheets_autofilter_clear":
			return _clear_filter(target, editor_name, arguments)
	return ToolUtils.error("Unknown spreadsheet filter tool: %s" % tool_name)


#region Verbs

func _enable_filter(target: SheetTarget, editor_name: String, args: Dictionary) -> Dictionary:
	var data := target.data
	var range_str := str(args.get("range", "")).strip_edges()
	var filter_range: Rect2i
	if range_str.is_empty():
		var no_selection: Array[Rect2i] = []
		filter_range = Actions.range_for_enable(data, no_selection, data.get_used_range().position.x)
		if filter_range.size.y < 2:
			return ToolUtils.error("No data rows to filter in %s" % editor_name)
	else:
		filter_range = _parse_range(range_str)
		if filter_range.size.x <= 0:
			return ToolUtils.error("Invalid range: %s" % range_str)
		if filter_range.end.x > data.column_count or filter_range.end.y > data.row_count:
			return ToolUtils.error("Range %s is outside the sheet (%d rows, %d columns)"
				% [range_str, data.row_count, data.column_count])
		if filter_range.size.y < 2:
			return ToolUtils.error("Range %s needs a header row and at least one data row" % range_str)
	return _after_change(target, editor_name, Actions.enable(data, target.history, filter_range))


func _set_criterion(target: SheetTarget, editor_name: String, args: Dictionary) -> Dictionary:
	var data := target.data
	if not data.autofilter.is_active():
		return _not_enabled_error(editor_name)
	var col_result: Variant = _column_arg(data, args)
	if col_result is String:
		return ToolUtils.error(col_result)
	var col: int = col_result

	var has_values := args.has("values") and args["values"] != null
	var has_contains := args.has("contains") and args["contains"] != null
	if has_values == has_contains:
		return ToolUtils.error("Provide exactly one of values or contains")
	if has_contains:
		if not args["contains"] is String:
			return ToolUtils.error("contains must be a string")
		var needle: String = args["contains"]
		if needle.is_empty():
			return ToolUtils.error("contains must not be empty; use minerva_sheets_autofilter_clear to drop the criterion")
		return _after_change(target, editor_name, Actions.set_text(data, target.history, col, needle))
	if not args["values"] is Array:
		return ToolUtils.error("values must be an array of strings")
	var allowed := PackedStringArray()
	for v: Variant in args["values"]:
		if not v is String:
			return ToolUtils.error("values must be an array of strings")
		allowed.append(v)
	return _after_change(target, editor_name, Actions.set_values(data, target.history, col, allowed))


func _clear_filter(target: SheetTarget, editor_name: String, args: Dictionary) -> Dictionary:
	var data := target.data
	if ToolUtils.coerce_bool(args.get("remove", false)):
		return _after_change(target, editor_name, Actions.remove(data, target.history))
	if not data.autofilter.is_active():
		return _not_enabled_error(editor_name)
	if args.has("column") and args["column"] != null:
		var col_result: Variant = _column_arg(data, args)
		if col_result is String:
			return ToolUtils.error(col_result)
		return _after_change(target, editor_name, Actions.clear_column(data, target.history, int(col_result)))
	return _after_change(target, editor_name, Actions.clear_all(data, target.history))


## Filter state of the sheet; the read verb and every change return this.
func _state(target: SheetTarget, editor_name: String, args: Dictionary = {}) -> Dictionary:
	var data := target.data
	var filter := data.autofilter
	var active := filter.is_active()

	# Rows the list covers: the filter range's data rows, or with no filter
	# the used range below its first row (what enabling would filter).
	var first: int
	var end: int
	if active:
		var span := Actions.data_row_span(data)
		first = span.x
		end = span.y
	else:
		var used := data.get_used_range()
		first = used.position.y + 1
		end = maxi(first, used.end.y)

	var visible: Array[int] = []
	for row in range(first, end):
		if filter.is_row_visible(row):
			visible.append(row + 1)

	var offset := maxi(0, ToolUtils.coerce_int(args.get("offset", 0)))
	var limit := maxi(0, ToolUtils.coerce_int(args.get("limit", DEFAULT_ROW_LIMIT), DEFAULT_ROW_LIMIT))
	var page := visible.slice(offset, offset + limit)

	var criteria: Array = []
	for col: int in filter.filtered_columns():
		var entry := filter.get_criterion(col)
		entry["column"] = col + 1
		entry["column_label"] = SpreadsheetDataScript.get_column_label(col)
		criteria.append(entry)

	var fr := filter.filter_range
	return ToolUtils.success({
		"editor_name": editor_name,
		"enabled": active,
		"filter_range": _range_label(fr) if active else "",
		"header_row": fr.position.y + 1 if active else first,
		"criteria": criteria,
		"scope": "visible" if not criteria.is_empty() else "all",
		"visible_rows": page,
		"visible_rows_truncated": offset + page.size() < visible.size(),
		"visible_count": visible.size(),
		"total_rows": end - first,
	})

#endregion


#region Helpers

func _after_change(target: SheetTarget, editor_name: String, changed: bool) -> Dictionary:
	# Same notification the UI raises after a filter change (marks the tab dirty).
	if changed and target.panel != null and target.panel.has_signal("content_changed"):
		target.panel.emit_signal("content_changed")
	var result := _state(target, editor_name)
	result["changed"] = changed
	return result


## 0-based column from the 1-based `column` argument, or an error message.
func _column_arg(data: SpreadsheetDataScript, args: Dictionary) -> Variant:
	var column := ToolUtils.coerce_int(args.get("column", 0))
	if column < 1:
		return "column number is required and must be >= 1 (1-based indexing)"
	var fr := data.autofilter.filter_range
	var col := column - 1
	if col < fr.position.x or col >= fr.end.x:
		return "Column %d is outside the filter range %s" % [column, _range_label(fr)]
	return col


## Rect2i (x = column, y = row, 0-based) from "A1:C10"; empty on bad input.
func _parse_range(range_str: String) -> Rect2i:
	var parts := range_str.split(":")
	if parts.size() != 2:
		return Rect2i()
	var a := SpreadsheetDataScript.parse_cell_reference(parts[0])
	var b := SpreadsheetDataScript.parse_cell_reference(parts[1])
	if a.x < 0 or b.x < 0:
		return Rect2i()
	var top_left := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	var bottom_right := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
	return Rect2i(top_left, bottom_right - top_left + Vector2i.ONE)


func _range_label(r: Rect2i) -> String:
	return "%s:%s" % [
		SpreadsheetDataScript.cell_to_reference(r.position.y, r.position.x),
		SpreadsheetDataScript.cell_to_reference(r.end.y - 1, r.end.x - 1)]


func _not_enabled_error(editor_name: String) -> Dictionary:
	return ToolUtils.error("AutoFilter is not enabled on %s; call minerva_sheets_autofilter_enable first" % editor_name)


func _find_editor_sheet(editor_name: String) -> SheetTarget:
	var target := SheetTarget.new()
	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		target.error = "Spreadsheet editor not found: %s" % editor_name
	elif not editor.spreadsheet_editor:
		target.error = "Spreadsheet editor not initialized"
	elif not editor.spreadsheet_editor.spreadsheet_data:
		target.error = "No spreadsheet data available"
	else:
		target.panel = editor.spreadsheet_editor
		target.data = editor.spreadsheet_editor.spreadsheet_data
		target.history = editor.spreadsheet_editor.history
	return target

#endregion
