class_name Sheets_MCPSpreadsheetTools
extends RefCounted
## Plugin-local tool module for Spreadsheet and Chart domain tools.

const ToolUtils := preload("tool_utils.gd")
const SpreadsheetEditorScript := preload("domain/SpreadsheetEditor.gd")
var _sheet: SpreadsheetEditorScript
var _matches_locator: Callable

const SpreadsheetDataScript := preload("domain/SpreadsheetData.gd")
const SpreadsheetChartScript := preload("domain/SpreadsheetChart.gd")
const SpreadsheetFileHandlerScript := preload("domain/SpreadsheetFileHandler.gd")
const SpreadsheetCellScript := preload("domain/SpreadsheetCell.gd")
const ChartCanvasScript := preload("domain/ChartCanvas.gd")


func _init(sheet: SpreadsheetEditorScript = null, matches_locator: Callable = Callable()) -> void:
	_sheet = sheet
	_matches_locator = matches_locator

func get_tool_names() -> Array[String]:
	return [
		"minerva_sheets_create_editor",
		"minerva_sheets_get_data",
		"minerva_sheets_update_data",
		"minerva_sheets_add_row",
		"minerva_sheets_add_column",
		"minerva_sheets_delete_row",
		"minerva_sheets_delete_column",
		"minerva_sheets_insert_row",
		"minerva_sheets_insert_column",
		"minerva_sheets_format_cells",
		"minerva_sheets_set_row_height",
		"minerva_sheets_set_column_width",
		"minerva_sheets_set_cell_formula",
		"minerva_sheets_add_chart",
		"minerva_sheets_get_chart_image",
		"minerva_sheets_list_charts",
		"minerva_sheets_update_chart",
		"minerva_sheets_delete_chart",
		"minerva_sheets_refresh_charts",
		"minerva_sheets_link_to_note",
		"minerva_sheets_export_to_nudge",
		"minerva_sheets_undo",
		"minerva_sheets_redo",
		"minerva_sheets_get_history",
		"minerva_sheets_fill_down",
		"minerva_sheets_recalculate",
	]


func handle(tool_name: String, arguments: Dictionary, context: Object = null) -> Dictionary:
	if context != null and context.call("is_stopped"):
		return context.call("stopped_result")
	match tool_name:
		"minerva_sheets_create_editor":
			return _create_spreadsheet_editor(arguments)
		"minerva_sheets_get_data":
			return _get_spreadsheet_data(arguments)
		"minerva_sheets_update_data":
			return _update_spreadsheet_data(arguments)
		"minerva_sheets_add_row":
			return _add_spreadsheet_row(arguments)
		"minerva_sheets_add_column":
			return _add_spreadsheet_column(arguments)
		"minerva_sheets_delete_row":
			return _delete_spreadsheet_row(arguments)
		"minerva_sheets_delete_column":
			return _delete_spreadsheet_column(arguments)
		"minerva_sheets_insert_row":
			return _insert_spreadsheet_row(arguments)
		"minerva_sheets_insert_column":
			return _insert_spreadsheet_column(arguments)
		"minerva_sheets_format_cells":
			return _format_cells(arguments)
		"minerva_sheets_set_row_height":
			return _set_row_height(arguments)
		"minerva_sheets_set_column_width":
			return _set_column_width(arguments)
		"minerva_sheets_set_cell_formula":
			return _set_cell_formula(arguments)
		"minerva_sheets_add_chart":
			return _create_chart(arguments)
		"minerva_sheets_get_chart_image":
			return await _get_chart_image(arguments, context)
		"minerva_sheets_list_charts":
			return _list_charts(arguments)
		"minerva_sheets_update_chart":
			return _update_chart(arguments)
		"minerva_sheets_delete_chart":
			return _delete_chart(arguments)
		"minerva_sheets_refresh_charts":
			return _refresh_charts(arguments)
		"minerva_sheets_link_to_note":
			return _link_spreadsheet_to_note(arguments)
		"minerva_sheets_export_to_nudge":
			return _export_to_nudge(arguments)
		"minerva_sheets_undo":
			return _undo_spreadsheet(arguments)
		"minerva_sheets_redo":
			return _redo_spreadsheet(arguments)
		"minerva_sheets_get_history":
			return _get_spreadsheet_history(arguments)
		"minerva_sheets_fill_down":
			return _fill_down_spreadsheet(arguments)
		"minerva_sheets_recalculate":
			return _recalculate_spreadsheet(arguments)
	return ToolUtils.error("Unknown spreadsheet tool: %s" % tool_name)


#region Helpers

## Export spreadsheet as raw JSON data
func _export_raw(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var cells_data: Array = []

	for row in range(bounds.position.y, bounds.position.y + bounds.size.y):
		var row_data: Array = []
		for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
			row_data.append(data.get_cell_display(row, col))
		cells_data.append(row_data)

	return {
		"rows": bounds.size.y,
		"columns": bounds.size.x,
		"data": cells_data
	}


## Export spreadsheet summary (counts, headers, totals)
func _export_summary(data: SpreadsheetDataScript, spreadsheet_editor) -> Dictionary:
	var bounds := data.get_used_range()

	# Get headers (first row)
	var headers: Array = []
	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		headers.append(data.get_cell_display(bounds.position.y, col))

	# Calculate numeric totals per column
	var totals: Dictionary = {}
	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		var total: float = 0.0
		var has_numbers := false
		for row in range(bounds.position.y + 1, bounds.position.y + bounds.size.y):
			var cell = data.get_cell_if_exists(row, col)
			if cell and cell.type == SpreadsheetCellScript.CellType.NUMBER:
				total += float(cell.value)
				has_numbers = true
		if has_numbers:
			var header: String = headers[col - bounds.position.x] if col - bounds.position.x < headers.size() else "Column %d" % col
			totals[header] = total

	return {
		"rows": bounds.size.y,
		"columns": bounds.size.x,
		"headers": headers,
		"totals": totals,
		"chart_count": spreadsheet_editor.charts.size() if spreadsheet_editor else 0
	}


## Export spreadsheet schema (column names and types)
func _export_schema(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var columns: Array = []

	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		var header: String = data.get_cell_display(bounds.position.y, col)

		# Detect column type from first few data cells
		var detected_type := "text"
		var sample_values: Array = []
		for row in range(bounds.position.y + 1, mini(bounds.position.y + 4, bounds.position.y + bounds.size.y)):
			var cell = data.get_cell_if_exists(row, col)
			if cell:
				sample_values.append(data.get_cell_display(row, col))
				if cell.type == SpreadsheetCellScript.CellType.NUMBER:
					detected_type = "number"
				elif cell.type == SpreadsheetCellScript.CellType.DATE:
					detected_type = "date"
				elif cell.type == SpreadsheetCellScript.CellType.FORMULA:
					detected_type = "formula"

		columns.append({
			"name": header,
			"type": detected_type,
			"samples": sample_values
		})

	return {
		"column_count": bounds.size.x,
		"row_count": bounds.size.y - 1,  # Exclude header
		"columns": columns
	}


## Export as time series (first column as date keys)
func _export_timeseries(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var series: Dictionary = {}

	# Get column headers
	var headers: Array = []
	for col in range(bounds.position.x, bounds.position.x + bounds.size.x):
		headers.append(data.get_cell_display(bounds.position.y, col))

	# Build time series with date as key
	for row in range(bounds.position.y + 1, bounds.position.y + bounds.size.y):
		var date_key: String = data.get_cell_display(row, bounds.position.x)
		var values: Dictionary = {}

		for col in range(bounds.position.x + 1, bounds.position.x + bounds.size.x):
			var header: String = headers[col - bounds.position.x]
			values[header] = data.get_cell_display(row, col)

		series[date_key] = values

	return {
		"date_column": headers[0] if headers.size() > 0 else "Date",
		"value_columns": headers.slice(1) if headers.size() > 1 else [],
		"series": series
	}


## Export as key-value pairs from first two columns
func _export_kv_pairs(data: SpreadsheetDataScript) -> Dictionary:
	var bounds := data.get_used_range()
	var pairs: Dictionary = {}

	if bounds.size.x < 2:
		return {"error": "Need at least 2 columns for key-value pairs"}

	for row in range(bounds.position.y + 1, bounds.position.y + bounds.size.y):
		var key_val: String = data.get_cell_display(row, bounds.position.x)
		var value_val: String = data.get_cell_display(row, bounds.position.x + 1)
		if not key_val.is_empty():
			pairs[key_val] = value_val

	return pairs


## Call Nudge MCP server to set a hint
func _call_nudge_set_hint(_component: String, _key: String, _value: Variant) -> Dictionary:
	return {"error": "Nudge is unavailable in this staging build"}

#endregion

#region Tool Implementations

func _create_spreadsheet_editor(_args: Dictionary) -> Dictionary:
	return {"success": false, "error_code": "sheets_staging", "error_message": "Spreadsheet creation uses the backend."}


func _get_spreadsheet_data(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor: ToolUtils.EditorTarget = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data: SpreadsheetDataScript = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	return read_data(data, args)


# The browser-control JSON-RPC envelope is limited to 64 KiB. Capping the
# application JSON at 30 KiB reserves its second JSON-escaping pass and framing.
const READ_REPLY_BYTES: int = 30 * 1024

# Wire accounting follows MCPJsonSerialization.gd:11-13,21-40: full float
# precision and strict JSON C0 escapes. Consume escape pairs so literal
# backslash-v text is distinct from Godot's vertical-tab spelling.
static func _read_reply_bytes(value: Dictionary) -> int:
	var raw: String = JSON.stringify(value, "", true, true)
	var bytes: int = raw.to_utf8_buffer().size()
	var pattern := RegEx.create_from_string(r"[\x00-\x1f]|\\.")
	for matched: RegExMatch in pattern.search_all(raw):
		var token: String = matched.get_string()
		if token == "\\v":
			bytes += 4
		elif token.unicode_at(0) < 0x20:
			bytes += 1 if token.unicode_at(0) in [8, 9, 10, 12, 13] else 5
	return bytes

static func _range_label(bounds: Rect2i) -> String:
	var first: String = SpreadsheetDataScript.cell_to_reference(bounds.position.y, bounds.position.x)
	var last: String = SpreadsheetDataScript.cell_to_reference(bounds.end.y - 1, bounds.end.x - 1)
	return first if bounds.size == Vector2i.ONE else first + ":" + last

static func _read_bounds(text: String, data: SpreadsheetDataScript) -> Rect2i:
	var regex := RegEx.new()
	regex.compile("^\\$?([A-Z]+)\\$?([1-9][0-9]*)(?::\\$?([A-Z]+)\\$?([1-9][0-9]*))?$")
	var matched: RegExMatch = regex.search(text.to_upper().strip_edges())
	if matched == null:
		return Rect2i(-1, -1, -1, -1)
	var positions: Array[Vector2i] = []
	for index: int in [1, 3]:
		var column: String = matched.get_string(index)
		var row: String = matched.get_string(index + 1)
		if column.is_empty():
			positions.append(positions[0])
			continue
		# Check digit lengths before conversion so huge references cannot overflow.
		if column.length() > SpreadsheetDataScript.get_column_label(data.column_count - 1).length() or row.length() > str(data.row_count).length():
			return Rect2i(-1, -1, -1, -1)
		var position := Vector2i(SpreadsheetDataScript.parse_column_label(column), row.to_int() - 1)
		if position.x >= data.column_count or position.y >= data.row_count:
			return Rect2i(-1, -1, -1, -1)
		positions.append(position)
	if positions[1].x < positions[0].x or positions[1].y < positions[0].y:
		return Rect2i(-1, -1, -1, -1)
	return Rect2i(positions[0], positions[1] - positions[0] + Vector2i.ONE)

static func _read_reply(data: SpreadsheetDataScript, bounds: Rect2i, used: Rect2i,
		format_: String, ranged: bool) -> Dictionary:
	var content: Variant
	match format_:
		"json": content = data.to_json_array(bounds)
		"markdown": content = data.to_markdown(false, bounds, false, not ranged)
		_: content = data.to_csv(",", bounds)
	var result := {"success": true, "format": format_, "data": content,
		"row_count": data.row_count, "column_count": bounds.size.x if ranged else data.column_count,
		"used_row_count": used.size.y, "used_column_count": used.size.x, "allocated_column_count": data.column_count,
		"data_starts_at_row": bounds.position.y + 1, "has_leading_empty_rows": used.position.y > 0}
	if ranged:
		result["range"] = _range_label(bounds) if bounds.has_area() else ""
	return result

static func read_data(data: SpreadsheetDataScript, args: Dictionary) -> Dictionary:
	var used: Rect2i = data.get_used_range()
	var bounds: Rect2i = used
	var range_text: String = args.get("range", "")
	var format_: String = args.get("format", "csv")
	var ranged: bool = not range_text.is_empty()
	var requested_range: String = ""
	if ranged:
		bounds = _read_bounds(range_text, data)
		if bounds.size.x < 0:
			return {"success": false, "error_code": "invalid_range",
				"error_message": "Use A1 or A1:C10 in ascending order within the allocated sheet grid.",
				"row_count": data.row_count, "column_count": data.column_count}
		requested_range = _range_label(bounds)
		var requested_start: Vector2i = bounds.position
		bounds = bounds.intersection(used)
		if not bounds.has_area():
			bounds = Rect2i(requested_start, Vector2i.ZERO)
	elif args.get("include_empty_rows", false) and format_ not in ["json", "markdown"]:
		bounds = Rect2i(used.position.x, 0, used.size.x, used.end.y)
	var result: Dictionary = _read_reply(data, bounds, used, format_, ranged)
	if ranged:
		result["requested_range"] = requested_range
	# Keep the historical offset for full CSV reads that include leading blanks.
	if not ranged:
		result["data_starts_at_row"] = used.position.y + 1
	var bytes: int = _read_reply_bytes(result)
	if bytes <= READ_REPLY_BYTES:
		return result
	var refusal := {"success": false, "error_code": "payload_too_large",
		"error_message": "Read a smaller range; no cell data was returned.",
		"row_count": data.row_count, "column_count": data.column_count,
		"used_row_count": used.size.y, "used_column_count": used.size.x, "allocated_column_count": data.column_count,
		"would_return_bytes": bytes, "budget_bytes": READ_REPLY_BYTES}
	var first := Rect2i(bounds.position, Vector2i.ONE)
	var sample: Dictionary = _read_reply(data, first, used, format_, true)
	sample["requested_range"] = _range_label(first)
	if _read_reply_bytes(sample) <= READ_REPLY_BYTES:
		refusal["suggested_range"] = _range_label(first)
	else:
		refusal["error_code"] = "cell_too_large"
		refusal["error_message"] = "This cell cannot fit in one read; no cell data was returned."
		refusal["cell"] = _range_label(first)
		var cell: SpreadsheetCellScript = data.get_cell_if_exists(first.position.y, first.position.x)
		refusal["cell_bytes"] = str(cell.value).to_utf8_buffer().size() if cell != null else 0
	return refusal


func _update_spreadsheet_data(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var csv_content: String = args.get("csv_content", "")
	var cells_raw = args.get("cells", [])
	var cells: Array = []
	if cells_raw is Array:
		cells = cells_raw
	elif cells_raw is String and not cells_raw.is_empty():
		var parsed = JSON.parse_string(cells_raw)
		if parsed is Array:
			cells = parsed

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	var updated_count := 0

	# If CSV content provided, replace all data
	if not csv_content.is_empty():
		editor.spreadsheet_editor.set_content(csv_content)
		updated_count = -1  # Indicate full replacement

	# Update individual cells (with history recording)
	if cells.size() > 0:
		for cell_update in cells:
			if cell_update is Dictionary:
				var cell_ref: String = cell_update.get("cell", "")
				var value: Variant = cell_update.get("value", "")

				if not cell_ref.is_empty():
					var pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(cell_ref)
					if pos.x >= 0 and pos.y >= 0:
						# Use history-recording method
						editor.spreadsheet_editor.set_cell_value_with_history(pos.y, pos.x, value)
						updated_count += 1

	return {
		"success": true,
		"message": "Spreadsheet updated" if updated_count == -1 else "Updated %d cells" % updated_count
	}


func _add_spreadsheet_row(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_row: int = args.get("at_row", -1)
	var values: Array = args.get("values", [])

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	# Determine row index
	var row_idx: int = at_row if at_row >= 0 else data.get_used_range().end.y

	# Insert the row
	data.insert_row(row_idx)

	# Set values if provided (with history recording)
	for col in range(values.size()):
		editor.spreadsheet_editor.set_cell_value_with_history(row_idx, col, values[col])

	# Trigger redraw for row headers
	editor.spreadsheet_editor.row_headers.queue_redraw()

	return {
		"success": true,
		"row_index": row_idx,
		"message": "Row added at index %d" % row_idx
	}


func _add_spreadsheet_column(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_col: int = args.get("at_col", -1)
	var header: String = args.get("header", "")
	var values: Array = args.get("values", [])

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	# Determine column index
	var col_idx: int = at_col if at_col >= 0 else data.column_count

	# Insert the column
	data.insert_column(col_idx)

	# Set header if provided (row 0) with history recording
	var start_row := 0
	if not header.is_empty():
		editor.spreadsheet_editor.set_cell_value_with_history(0, col_idx, header)
		start_row = 1

	# Set values with history recording
	for i in range(values.size()):
		editor.spreadsheet_editor.set_cell_value_with_history(start_row + i, col_idx, values[i])

	# Trigger redraw for column headers
	editor.spreadsheet_editor.column_headers.queue_redraw()

	return {
		"success": true,
		"column_index": col_idx,
		"column_label": SpreadsheetDataScript.get_column_label(col_idx),
		"message": "Column added at index %d" % col_idx
	}


func _delete_spreadsheet_row(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var row: int = args.get("row", -1)

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if row < 1:
		return ToolUtils.error("row number is required and must be >= 1 (1-based indexing)")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	# Convert from 1-based to 0-based indexing
	var internal_row: int = row - 1

	if internal_row >= data.row_count:
		return ToolUtils.error("Row %d out of bounds (max row: %d)" % [row, data.row_count])

	# Delete the row with history support
	var success = editor.spreadsheet_editor.delete_row_with_history(internal_row)
	if not success:
		return ToolUtils.error("Failed to delete row %d" % row)

	return {
		"success": true,
		"deleted_row": row,
		"message": "Row %d deleted (can be undone with Ctrl+Z)" % row
	}


func _delete_spreadsheet_column(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var column: int = args.get("column", -1)

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if column < 1:
		return ToolUtils.error("column number is required and must be >= 1 (1-based indexing)")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	# Convert from 1-based to 0-based indexing
	var internal_col: int = column - 1

	if internal_col >= data.column_count:
		return ToolUtils.error("Column %d out of bounds (max column: %d)" % [column, data.column_count])

	var col_label = SpreadsheetDataScript.get_column_label(internal_col)

	# Delete the column with history support
	var success = editor.spreadsheet_editor.delete_column_with_history(internal_col)
	if not success:
		return ToolUtils.error("Failed to delete column %d (%s)" % [column, col_label])

	return {
		"success": true,
		"deleted_column": column,
		"deleted_column_label": col_label,
		"message": "Column %s deleted (can be undone with Ctrl+Z)" % col_label
	}


func _insert_spreadsheet_row(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_row: int = args.get("at_row", -1)

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if at_row < 0:
		return ToolUtils.error("at_row is required and must be >= 0")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	# Insert empty row
	data.insert_row(at_row)

	# Trigger redraw
	editor.spreadsheet_editor.row_headers.queue_redraw()
	editor.spreadsheet_editor.queue_redraw()

	return {
		"success": true,
		"inserted_at_row": at_row,
		"message": "Empty row inserted at index %d" % at_row
	}


func _insert_spreadsheet_column(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var at_column: int = args.get("at_column", -1)

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if at_column < 0:
		return ToolUtils.error("at_column is required and must be >= 0")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	# Insert empty column
	data.insert_column(at_column)

	var col_label = SpreadsheetDataScript.get_column_label(at_column)

	# Trigger redraw
	editor.spreadsheet_editor.column_headers.queue_redraw()
	editor.spreadsheet_editor.queue_redraw()

	return {
		"success": true,
		"inserted_at_column": at_column,
		"inserted_column_label": col_label,
		"message": "Empty column inserted at %s (index %d)" % [col_label, at_column]
	}


func _format_cells(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var range_str: String = args.get("range", "")

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if range_str.is_empty():
		return ToolUtils.error("range is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	# Parse the range
	var cells_to_format: Array[Vector2i] = []

	if range_str.contains(":"):
		# Range like A1:C10
		var parts: PackedStringArray = range_str.split(":")
		var start_pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(parts[0].strip_edges())
		var end_pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(parts[1].strip_edges())

		if start_pos.x >= 0 and start_pos.y >= 0 and end_pos.x >= 0 and end_pos.y >= 0:
			for row in range(mini(start_pos.y, end_pos.y), maxi(start_pos.y, end_pos.y) + 1):
				for col in range(mini(start_pos.x, end_pos.x), maxi(start_pos.x, end_pos.x) + 1):
					cells_to_format.append(Vector2i(col, row))
	else:
		# Single cell like A1
		var pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(range_str)
		if pos.x >= 0 and pos.y >= 0:
			cells_to_format.append(Vector2i(pos.x, pos.y))

	if cells_to_format.is_empty():
		return ToolUtils.error("Invalid range: %s" % range_str)

	# Build format options dictionary
	var format_options: Dictionary = {}

	if args.has("bold"):
		format_options["bold"] = ToolUtils.coerce_bool(args.get("bold"))
	if args.has("italic"):
		format_options["italic"] = ToolUtils.coerce_bool(args.get("italic"))
	if args.has("alignment"):
		var align_str: String = args.get("alignment", "left")
		match align_str:
			"left":
				format_options["alignment"] = HORIZONTAL_ALIGNMENT_LEFT
			"center":
				format_options["alignment"] = HORIZONTAL_ALIGNMENT_CENTER
			"right":
				format_options["alignment"] = HORIZONTAL_ALIGNMENT_RIGHT
	if args.has("text_color"):
		format_options["text_color"] = ToolUtils.coerce_color(args.get("text_color"), Color.WHITE)
	if args.has("bg_color"):
		format_options["bg_color"] = ToolUtils.coerce_color(args.get("bg_color"), Color.BLACK)
	if args.has("number_format"):
		format_options["number_format"] = args.get("number_format", "none")
	if args.has("wrap_text"):
		format_options["wrap_text"] = ToolUtils.coerce_bool(args.get("wrap_text"))

	# Apply formatting with history recording
	var formatted_count := 0
	for cell_pos in cells_to_format:
		editor.spreadsheet_editor.format_cell_with_history(cell_pos.y, cell_pos.x, format_options)
		formatted_count += 1

	return {
		"success": true,
		"cells_formatted": formatted_count,
		"message": "Formatted %d cells" % formatted_count
	}


func _set_row_height(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var rows: Array = args.get("rows", [])

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if rows.is_empty():
		return ToolUtils.error("rows array is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	var updated_count := 0
	for row_config in rows:
		if not row_config is Dictionary:
			continue
		var row_1based: int = ToolUtils.coerce_int(row_config.get("row", -1), -1)
		var height: float = ToolUtils.coerce_float(row_config.get("height", -1.0), -1.0)
		if row_1based < 1 or height < 0:
			continue

		var row := row_1based - 1  # Convert to 0-based
		if row < 0 or row >= data.row_count:
			continue

		height = clampf(height, SpreadsheetDataScript.MIN_ROW_HEIGHT, SpreadsheetDataScript.MAX_ROW_HEIGHT)
		var old_height: float = data.get_row_height(row)
		data.set_row_height(row, height)
		if height != old_height:
			editor.spreadsheet_editor.history.record_row_resize(row, old_height, height)
		updated_count += 1

	# Trigger UI updates
	editor.spreadsheet_editor.cells_canvas.queue_redraw()
	editor.spreadsheet_editor.row_headers.queue_redraw()
	editor.spreadsheet_editor._update_scrollbar_ranges()

	return {
		"success": true,
		"rows_updated": updated_count,
		"message": "Updated height for %d rows" % updated_count
	}


func _set_column_width(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var columns: Array = args.get("columns", [])

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if columns.is_empty():
		return ToolUtils.error("columns array is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	var updated_count := 0
	for col_config in columns:
		if not col_config is Dictionary:
			continue
		var col_str: String = str(col_config.get("column", ""))
		var width: float = ToolUtils.coerce_float(col_config.get("width", -1.0), -1.0)
		if col_str.is_empty() or width < 0:
			continue

		# Parse column: letter (A, B, ...) or 1-based number
		var col: int = -1
		if col_str.is_valid_int():
			col = int(col_str) - 1  # Convert 1-based to 0-based
		else:
			col = SpreadsheetDataScript.parse_column_label(col_str.to_upper())

		if col < 0 or col >= data.column_count:
			continue

		width = clampf(width, SpreadsheetDataScript.MIN_COLUMN_WIDTH, SpreadsheetDataScript.MAX_COLUMN_WIDTH)
		var old_width: float = data.get_column_width(col)
		data.set_column_width(col, width)
		if width != old_width:
			editor.spreadsheet_editor.history.record_column_resize(col, old_width, width)
		updated_count += 1

	# Trigger UI updates
	editor.spreadsheet_editor.cells_canvas.queue_redraw()
	editor.spreadsheet_editor.column_headers.queue_redraw()
	editor.spreadsheet_editor._update_scrollbar_ranges()

	return {
		"success": true,
		"columns_updated": updated_count,
		"message": "Updated width for %d columns" % updated_count
	}


func _set_cell_formula(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var cell_ref: String = args.get("cell", "")
	var formula: String = args.get("formula", "")

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if cell_ref.is_empty():
		return ToolUtils.error("cell is required")

	if formula.is_empty():
		return ToolUtils.error("formula is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data
	if not data:
		return ToolUtils.error("No spreadsheet data available")

	# Parse cell reference
	var pos: Vector2i = SpreadsheetDataScript.parse_cell_reference(cell_ref)
	if pos.x < 0 or pos.y < 0:
		return ToolUtils.error("Invalid cell reference: %s" % cell_ref)

	# Ensure formula starts with =
	if not formula.begins_with("="):
		formula = "=" + formula

	# Set the formula with history recording
	editor.spreadsheet_editor.set_cell_value_with_history(pos.y, pos.x, formula)

	# Get the computed result
	var cell = data.get_cell(pos.y, pos.x)
	var result: String = cell.get_display_text()

	return {
		"success": true,
		"cell": cell_ref,
		"formula": formula,
		"result": result
	}


func _create_chart(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var title: String = args.get("title", "Chart")
	var chart_type: String = args.get("type", "line")
	var x_range: String = args.get("x_range", "")
	var series: Array = args.get("series", [])
	var x_is_date: bool = ToolUtils.coerce_bool(args.get("x_is_date", false))
	var first_row_is_header: bool = ToolUtils.coerce_bool(args.get("first_row_is_header", true), true)

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if x_range.is_empty():
		return ToolUtils.error("x_range is required")

	if series.is_empty():
		return ToolUtils.error("series is required (array of cell ranges)")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	# Create the chart
	var chart := SpreadsheetChartScript.new()
	chart.title = title
	chart.type = SpreadsheetChartScript.ChartType.LINE if chart_type == "line" else SpreadsheetChartScript.ChartType.BAR
	chart.x_range = x_range
	chart.x_is_date = x_is_date
	chart.first_row_is_header = first_row_is_header

	# Add series
	for series_range in series:
		if series_range is String:
			chart.add_series(series_range)

	# Add the chart
	editor.spreadsheet_editor.add_chart(chart)

	return {
		"success": true,
		"chart_id": chart.id,
		"chart_count": editor.spreadsheet_editor.charts.size(),
		"message": "Chart created successfully"
	}


func _get_chart_image(args: Dictionary, context: Object = null) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var chart_index: int = ToolUtils.coerce_int(args.get("chart_index", 0), 0)
	var width: int = ToolUtils.coerce_int(args.get("width", 800), 800)
	var height: int = ToolUtils.coerce_int(args.get("height", 400), 400)

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var charts = editor.spreadsheet_editor.charts
	if chart_index < 0 or chart_index >= charts.size():
		return ToolUtils.error("Chart index out of range (have %d charts)" % charts.size())

	var canvases: Array = editor.spreadsheet_editor.chart_canvases
	var chart_canvas: ChartCanvasScript = canvases[chart_index] if chart_index < canvases.size() else null
	if not chart_canvas:
		return ToolUtils.error("Chart canvas not available")

	# Make sure the chart canvas has the right chart selected
	var target_chart: SpreadsheetChartScript = charts[chart_index]
	var chart_data: SpreadsheetDataScript = editor.spreadsheet_editor.spreadsheet_data
	chart_canvas.set_chart(target_chart)
	chart_canvas.update_from_spreadsheet(chart_data)

	# Capture the chart as base64 PNG
	var base64_png: String = await chart_canvas.capture_to_base64_png(width, height)
	if context != null and context.call("is_stopped"):
		return context.call("stopped_result")

	if base64_png.is_empty():
		return ToolUtils.error("Failed to capture chart image")

	return {
		"success": true,
		"chart_index": chart_index,
		"chart_title": target_chart.title,
		"width": width,
		"height": height,
		"format": "png",
		"encoding": "base64",
		"image_data": base64_png
	}


func _list_charts(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var charts_info: Array = []
	for i in range(editor.spreadsheet_editor.charts.size()):
		var chart = editor.spreadsheet_editor.charts[i]
		var series_info: Array = []
		for s in chart.series:
			series_info.append({
				"range": s.get("range", ""),
				"name": s.get("name", "")
			})

		charts_info.append({
			"index": i,
			"id": chart.id,
			"title": chart.title,
			"type": "line" if chart.type == SpreadsheetChartScript.ChartType.LINE else "bar",
			"x_range": chart.x_range,
			"x_is_date": chart.x_is_date,
			"first_row_is_header": chart.first_row_is_header,
			"series": series_info
		})

	return {
		"success": true,
		"chart_count": charts_info.size(),
		"charts": charts_info
	}


func _update_chart(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var chart_id: String = args.get("chart_id", "")
	var chart_index: int = ToolUtils.coerce_int(args.get("chart_index", -1), -1)

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	# Find chart by ID or index
	var target_index: int = -1
	if not chart_id.is_empty():
		target_index = editor.spreadsheet_editor.get_chart_index(chart_id)
	elif chart_index >= 0:
		target_index = chart_index

	if target_index < 0 or target_index >= editor.spreadsheet_editor.charts.size():
		return ToolUtils.error("Chart not found. Provide valid chart_id or chart_index.")

	# Build properties dictionary from args
	var properties: Dictionary = {}
	if args.has("title"):
		properties["title"] = args["title"]
	if args.has("type"):
		properties["type"] = args["type"]
	if args.has("x_range"):
		properties["x_range"] = args["x_range"]
	if args.has("series"):
		properties["series"] = args["series"]
	if args.has("x_is_date"):
		properties["x_is_date"] = ToolUtils.coerce_bool(args["x_is_date"])
	if args.has("first_row_is_header"):
		properties["first_row_is_header"] = ToolUtils.coerce_bool(args["first_row_is_header"])
	if args.has("x_axis_label"):
		properties["x_axis_label"] = args["x_axis_label"]
	if args.has("y_axis_label"):
		properties["y_axis_label"] = args["y_axis_label"]
	if args.has("show_legend"):
		properties["show_legend"] = ToolUtils.coerce_bool(args["show_legend"])
	if args.has("y_auto_scale"):
		properties["y_auto_scale"] = ToolUtils.coerce_bool(args["y_auto_scale"])
	if args.has("y_min"):
		properties["y_min"] = ToolUtils.coerce_float(args["y_min"])
	if args.has("y_max"):
		properties["y_max"] = ToolUtils.coerce_float(args["y_max"])

	if properties.is_empty():
		return ToolUtils.error("No properties to update. Provide at least one property.")

	# Update the chart
	var success: bool = editor.spreadsheet_editor.update_chart_properties(target_index, properties)

	if not success:
		return ToolUtils.error("Failed to update chart")

	var chart = editor.spreadsheet_editor.charts[target_index]
	return {
		"success": true,
		"chart_id": chart.id,
		"chart_index": target_index,
		"updated_properties": properties.keys(),
		"message": "Chart updated successfully"
	}


func _delete_chart(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var chart_id: String = args.get("chart_id", "")
	var chart_index: int = ToolUtils.coerce_int(args.get("chart_index", -1), -1)

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	# Find chart by ID or index
	var target_index: int = -1
	if not chart_id.is_empty():
		target_index = editor.spreadsheet_editor.get_chart_index(chart_id)
	elif chart_index >= 0:
		target_index = chart_index

	if target_index < 0 or target_index >= editor.spreadsheet_editor.charts.size():
		return ToolUtils.error("Chart not found. Provide valid chart_id or chart_index.")

	var deleted_id: String = editor.spreadsheet_editor.charts[target_index].id
	editor.spreadsheet_editor.remove_chart(target_index)

	return {
		"success": true,
		"deleted_chart_id": deleted_id,
		"remaining_charts": editor.spreadsheet_editor.charts.size(),
		"message": "Chart deleted successfully"
	}


func _refresh_charts(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	editor.spreadsheet_editor._update_all_charts()

	return {
		"success": true,
		"charts_refreshed": editor.spreadsheet_editor.charts.size(),
		"message": "All charts refreshed"
	}


func _link_spreadsheet_to_note(_args: Dictionary) -> Dictionary:
	return {"success": false, "error_code": "sheets_staging", "error_message": "Snapshot note creation is not available in this staging build."}


func _export_to_nudge(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component: String = args.get("component", "")
	var key: String = args.get("key", "")
	var format_: String = args.get("format", "summary")
	var include_charts: bool = ToolUtils.coerce_bool(args.get("include_charts", false))

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if component.is_empty():
		return ToolUtils.error("component is required")

	if key.is_empty():
		return ToolUtils.error("key is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var data = editor.spreadsheet_editor.spreadsheet_data

	# Build the export value based on format
	var export_value: Variant

	match format_:
		"raw":
			export_value = _export_raw(data)
		"summary":
			export_value = _export_summary(data, editor.spreadsheet_editor)
		"schema":
			export_value = _export_schema(data)
		"timeseries":
			export_value = _export_timeseries(data)
		"kv_pairs":
			export_value = _export_kv_pairs(data)
		_:
			export_value = _export_summary(data, editor.spreadsheet_editor)

	# Add chart info if requested
	if include_charts and editor.spreadsheet_editor.charts.size() > 0:
		var charts_info: Array = []
		for chart in editor.spreadsheet_editor.charts:
			charts_info.append({
				"id": chart.id,
				"title": chart.title,
				"type": "line" if chart.type == SpreadsheetChartScript.ChartType.LINE else "bar",
				"x_range": chart.x_range,
				"series_count": chart.series.size()
			})
		if export_value is Dictionary:
			export_value["charts"] = charts_info

	# Call Nudge MCP to set the hint
	var nudge_result: Dictionary = _call_nudge_set_hint(component, key, export_value)

	if nudge_result.has("error"):
		return ToolUtils.error("Nudge export failed: %s" % nudge_result.get("error", "Unknown error"))

	return {
		"success": true,
		"component": component,
		"key": key,
		"format": format_,
		"message": "Exported spreadsheet data to Nudge as %s/%s" % [component, key]
	}


## Undo the last action(s) in a spreadsheet
func _undo_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var count: int = ToolUtils.coerce_int(args.get("count", 1), 1)

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var spreadsheet = editor.spreadsheet_editor

	if not spreadsheet.can_undo():
		return {
			"success": false,
			"message": "Nothing to undo",
			"undo_count": 0,
			"redo_count": spreadsheet.get_redo_count()
		}

	var undone := 0
	for i in range(count):
		if spreadsheet.undo():
			undone += 1
		else:
			break

	return {
		"success": true,
		"undone_count": undone,
		"remaining_undo_count": spreadsheet.get_undo_count(),
		"redo_count": spreadsheet.get_redo_count(),
		"message": "Undid %d action(s)" % undone
	}


## Redo a previously undone action in a spreadsheet
func _redo_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var count: int = ToolUtils.coerce_int(args.get("count", 1), 1)

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var spreadsheet = editor.spreadsheet_editor

	if not spreadsheet.can_redo():
		return {
			"success": false,
			"message": "Nothing to redo",
			"undo_count": spreadsheet.get_undo_count(),
			"redo_count": 0
		}

	var redone := 0
	for i in range(count):
		if spreadsheet.redo():
			redone += 1
		else:
			break

	return {
		"success": true,
		"redone_count": redone,
		"undo_count": spreadsheet.get_undo_count(),
		"remaining_redo_count": spreadsheet.get_redo_count(),
		"message": "Redid %d action(s)" % redone
	}


## Get the undo/redo history status of a spreadsheet
func _get_spreadsheet_history(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var spreadsheet = editor.spreadsheet_editor

	return {
		"success": true,
		"can_undo": spreadsheet.can_undo(),
		"can_redo": spreadsheet.can_redo(),
		"undo_count": spreadsheet.get_undo_count(),
		"redo_count": spreadsheet.get_redo_count()
	}


## Fill down formulas/values from source row to target rows
func _fill_down_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var source_row: int = ToolUtils.coerce_int(args.get("source_row", 0), 0)
	var target_rows: Array = args.get("target_rows", [])
	var columns: Array = args.get("columns", [])

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	if source_row < 1:
		return ToolUtils.error("source_row must be >= 1 (1-based row number)")

	if target_rows.is_empty():
		return ToolUtils.error("target_rows array is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var spreadsheet = editor.spreadsheet_editor
	var data = spreadsheet.spreadsheet_data

	# Convert 1-based to 0-based
	var source_row_idx: int = source_row - 1

	# Determine columns to fill
	var col_indices: Array[int] = []
	if columns.is_empty():
		# Fill all columns that have data in source row
		for col in range(data.column_count):
			var cell = data.get_cell_if_exists(source_row_idx, col)
			if cell and not cell.is_empty():
				col_indices.append(col)
	else:
		# Parse column letters to indices
		for col_letter in columns:
			var col_idx: int = SpreadsheetDataScript.parse_column_label(str(col_letter).to_upper())
			if col_idx >= 0:
				col_indices.append(col_idx)

	if col_indices.is_empty():
		return ToolUtils.error("No columns to fill (source row is empty or columns not found)")

	# Capture old cells for history
	var old_cells: Dictionary = {}
	var new_cells: Dictionary = {}
	var filled_count: int = 0

	# Fill each target row
	for target_row in target_rows:
		var target_row_idx: int = int(target_row) - 1  # Convert to 0-based
		if target_row_idx < 0 or target_row_idx == source_row_idx:
			continue

		var row_offset: int = target_row_idx - source_row_idx

		for col in col_indices:
			var source_cell = data.get_cell_if_exists(source_row_idx, col)
			if not source_cell:
				continue

			var key := SpreadsheetDataScript.cell_key(target_row_idx, col)

			# Capture old value
			var old_cell = data.get_cell_if_exists(target_row_idx, col)
			if old_cell:
				old_cells[key] = old_cell.to_dict()
			else:
				old_cells[key] = {}

			# Determine what to set
			if source_cell.has_formula():
				# Adjust the formula's row references
				var adjusted_formula: String = spreadsheet._adjust_formula_row_refs(source_cell.formula, row_offset)
				data.set_cell_value(target_row_idx, col, adjusted_formula)
			else:
				# Just copy the value (no adjustment needed)
				data.set_cell_value(target_row_idx, col, source_cell.value)

			# Capture new value
			var new_cell = data.get_cell_if_exists(target_row_idx, col)
			if new_cell:
				new_cells[key] = new_cell.to_dict()
			filled_count += 1

	# Record in history
	if not new_cells.is_empty():
		spreadsheet.history.record_range_edit(source_row_idx + 1, col_indices[0], old_cells, new_cells)

	spreadsheet.cells_canvas.queue_redraw()
	spreadsheet.content_changed.emit()

	# Build column letters for response
	var col_letters: Array[String] = []
	for col in col_indices:
		col_letters.append(SpreadsheetDataScript.get_column_label(col))

	return {
		"success": true,
		"filled_cells": filled_count,
		"source_row": source_row,
		"target_rows": target_rows,
		"columns": col_letters,
		"message": "Filled %d cells from row %d to rows %s in columns %s" % [filled_count, source_row, str(target_rows), ", ".join(col_letters)]
	}


## Recalculate all formulas in a spreadsheet
func _recalculate_spreadsheet(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return ToolUtils.error("editor_name is required")

	var editor = ToolUtils.find_spreadsheet(editor_name, _sheet, _matches_locator)
	if not editor:
		return ToolUtils.error("Spreadsheet editor not found: %s" % editor_name)

	if not editor.spreadsheet_editor:
		return ToolUtils.error("Spreadsheet editor not initialized")

	var spreadsheet = editor.spreadsheet_editor
	spreadsheet._recalculate_all()

	return {
		"success": true,
		"message": "Recalculated all formulas in %s" % editor_name
	}

#endregion
