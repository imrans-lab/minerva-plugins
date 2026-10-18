class_name Sheets_ToolUtils
extends RefCounted
## Response/coercion contracts copied from the host; lookup is scoped to one
## mounted Sheets panel, with dependencies supplied by its host-facing root.
const SpreadsheetEditorScript := preload("../domain/SpreadsheetEditor.gd")

class EditorTarget:
	extends RefCounted
	var spreadsheet_editor: SpreadsheetEditorScript

static func find_spreadsheet(name_: String, sheet: SpreadsheetEditorScript, matches_locator: Callable) -> EditorTarget:
	if not is_instance_valid(sheet) or not sheet.is_inside_tree() or not matches_locator.is_valid() or matches_locator.call(name_) != true:
		return null
	var target := EditorTarget.new()
	target.spreadsheet_editor = sheet
	return target

static func success(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result

static func error(msg: String) -> Dictionary:
	return {"error": msg, "success": false}

static func coerce_int(value: Variant, default: int = 0) -> int:
	if value == null:
		return default
	if value is int:
		return value
	if value is float:
		var number: float = value
		return int(number)
	if value is String:
		var text: String = value
		if text.is_valid_int():
			return text.to_int()
	return default

static func coerce_float(value: Variant, default: float = 0.0) -> float:
	if value == null:
		return default
	if value is float:
		return value
	if value is int:
		var number: int = value
		return float(number)
	if value is String:
		var text: String = value
		if text.is_valid_float():
			return text.to_float()
	return default

static func coerce_color(value: Variant, default: Color = Color.TRANSPARENT) -> Color:
	if value == null:
		return default
	if value is Color:
		return value
	if value is String:
		var text: String = value
		var s: String = text.strip_edges()
		if s.is_empty():
			return default
		# Try HTML hex format (with or without #)
		if Color.html_is_valid(s):
			return Color.html(s)
		# Try named color
		if Color.html_is_valid(s.to_lower()):
			return Color.html(s.to_lower())
	return default

static func coerce_bool(value: Variant, default: bool = false) -> bool:
	if value == null:
		return default
	if value is bool:
		return value
	if value is String:
		var text: String = value
		return text.to_lower() == "true"
	if value is int or value is float:
		return value != 0
	return default
