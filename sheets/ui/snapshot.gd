extends RefCounted
## Accepted snapshot fields mirror SpreadsheetData/Cell/Chart/AutoFilter loaders.
## Unknown fields and lossy conversions stay opaque at the host boundary.
const MAX_INDEX: int = 2147483647
const REQUIRED: Dictionary = {"model": ["version", "row_count", "column_count", "cells"],
	"cell": ["type", "value"], "filter": ["range", "columns"], "criterion": ["col", "type"]}
const FIELDS: Dictionary = {
	"model": {
		"version": ["integer_enum", [1]], "row_count": ["positive_integer"], "column_count": ["positive_integer"],
		"header_row_count": ["index"], "frozen_rows": ["index"], "frozen_cols": ["index"],
		"columns": ["array", "column"], "rows": ["array", "row"], "cells": ["cells"],
		"charts": ["array", "chart"], "autofilter": ["object", "filter"]},
	"column": {"width": ["number"], "header_name": ["string"], "is_date_column": ["boolean"]},
	"row": {"height": ["number"], "is_header": ["boolean"]},
	"cell": {
		"type": ["integer_enum", [1, 2, 3, 4]], "value": ["cell_value"], "formula": ["string"],
		"bold": ["boolean"], "italic": ["boolean"], "alignment": ["integer_enum", [0, 1, 2, 3]],
		"text_color": ["html_color"], "bg_color": ["html_color"], "date_format": ["string"],
		"number_format": ["string"], "wrap_text": ["boolean"]},
	"chart": {
		"id": ["string"], "title": ["string"], "type": ["integer_enum", [0, 1]], "x_range": ["string"],
		"series": ["array", "series"], "x_is_date": ["boolean"], "first_row_is_header": ["boolean"],
		"date_format": ["string"], "width": ["number"], "height": ["number"],
		"x_axis_label": ["string"], "y_axis_label": ["string"], "show_legend": ["boolean"],
		"show_grid": ["boolean"], "y_auto_scale": ["boolean"], "y_min": ["number"], "y_max": ["number"],
		"background_color_r": ["number"], "background_color_g": ["number"],
		"background_color_b": ["number"], "background_color_a": ["number"]},
	"series": {"range": ["string"], "name": ["string"], "color_r": ["number"],
		"color_g": ["number"], "color_b": ["number"], "color_a": ["number"]},
	"filter": {"range": ["range"], "columns": ["array", "criterion"]},
	"criterion": {"col": ["index"], "type": ["string_enum", ["text", "values"]],
		"text": ["string"], "values": ["strings"]},
}

static func validate(model: Dictionary) -> bool:
	if not _object(model, "model"):
		return false
	var rows_number: float = model.row_count
	var cols_number: float = model.column_count
	var rows: int = int(rows_number)
	var cols: int = int(cols_number)
	for field: String in ["header_row_count", "frozen_rows", "frozen_cols"]:
		var count: float = model.get(field, 0)
		if count > (cols if field == "frozen_cols" else rows):
			return false
	var cells: Dictionary = model.cells
	for key: String in cells:
		var parts: PackedStringArray = key.split(",")
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			return false
		var row: int = parts[0].to_int()
		var col: int = parts[1].to_int()
		if key != "%d,%d" % [row, col] or row < 0 or col < 0 or row >= rows or col >= cols:
			return false
		var cell: Dictionary = cells[key]
		if cell.type == 4:
			var formula: String = cell.get("formula", "")
			if not formula.begins_with("="):
				return false
	if model.has("autofilter"):
		var filter: Dictionary = model.autofilter
		var region: Array = filter.range
		var x: float = region[0]
		var width: float = region[2]
		var seen: Dictionary = {}
		var criteria: Array = filter.columns
		for criterion: Dictionary in criteria:
			var column: float = criterion.col
			var kind: String = criterion.type
			if criterion.size() != 3 or seen.has(column) or column < x or column >= x + width:
				return false
			if not criterion.has("text" if kind == "text" else "values"):
				return false
			seen[column] = true
	return true

static func _object(value: Variant, schema_name: String) -> bool:
	if not value is Dictionary:
		return false
	var fields: Dictionary = value
	var schema: Dictionary = FIELDS[schema_name]
	var required: Array = REQUIRED.get(schema_name, [])
	for key: String in required:
		if not fields.has(key):
			return false
	for key: Variant in fields:
		if not key is String or not schema.has(key):
			return false
		var rule: Array = schema[key]
		if not _value(fields[key], rule):
			return false
	return true

static func _number(value: Variant, integral: bool = false) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = value
	return is_finite(number) and (not integral or (number == floor(number) and number >= 0 and number <= MAX_INDEX))

static func _value(value: Variant, rule: Array) -> bool:
	var kind: String = rule[0]
	match kind:
		"string": return value is String
		"boolean": return value is bool
		"number": return _number(value)
		"index": return _number(value, true)
		"positive_integer": return _number(value, true) and value != 0
		"integer_enum":
			var options: Array = rule[1]
			return _number(value, true) and options.has(value)
		"string_enum":
			var options: Array = rule[1]
			return value is String and options.has(value)
		"html_color":
			if not value is String: return false
			var html: String = value
			return Color.html_is_valid(html)
		"cell_value": return value == null or value is String or value is bool or _number(value)
		"object":
			var schema: String = rule[1]
			return _object(value, schema)
		"array", "strings", "range":
			if not value is Array: return false
			var items: Array = value
			if kind == "range" and items.size() != 4: return false
			for item: Variant in items:
				if kind == "array":
					var schema: String = rule[1]
					if not _object(item, schema): return false
				elif kind == "strings":
					if not item is String: return false
				elif not _number(item, true): return false
			if kind == "range":
				var x: float = items[0]
				var y: float = items[1]
				var width: float = items[2]
				var height: float = items[3]
				return width > 0 and height > 0 and x + width <= MAX_INDEX and y + height <= MAX_INDEX
			return true
		"cells":
			if not value is Dictionary: return false
			var cells: Dictionary = value
			for key: Variant in cells:
				if not key is String or not _object(cells[key], "cell"): return false
			return true
	return false
