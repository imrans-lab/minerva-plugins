extends RefCounted
## The real loaders own acceptance. Guards only protect their typed operations.
const Data := preload("domain/SpreadsheetData.gd")
const Cell := preload("domain/SpreadsheetCell.gd")
const Chart := preload("domain/SpreadsheetChart.gd")
const Filter := preload("domain/SpreadsheetAutoFilter.gd")
const MAX_INDEX: int = 2147483647

static func validate(input: Dictionary) -> bool:
	var model: Data = Data.new()
	if input.get("version") != 1 or not _safe(input, model.to_dict()): return false
	model.load_from_dict(input)
	var output: Dictionary = model.to_dict()
	var charts: Array[Dictionary] = []
	var entries: Array = input.get("charts", [])
	for entry: Dictionary in entries:
		var chart: Chart = Chart.new()
		chart.load_from_dict(entry)
		charts.append(chart.to_dict())
	output["charts"] = charts
	return _preserves(input, output)

static func _safe(input: Dictionary, example: Dictionary) -> bool:
	if not _shape(input, example): return false
	var rows: float = input.get("row_count", 100)
	var cols: float = input.get("column_count", 26)
	if rows < 1 or cols < 1: return false
	var cells: Dictionary = input.get("cells", {})
	var prototype: Cell = Cell.new()
	for key: Variant in cells:
		if not key is String: return false
		var address: String = key
		var parts: PackedStringArray = address.split(",")
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int(): return false
		var row: int = parts[0].to_int()
		var col: int = parts[1].to_int()
		if address != "%d,%d" % [row, col] or row < 0 or col < 0 or row >= rows or col >= cols: return false
		if not cells[key] is Dictionary: return false
		var cell: Dictionary = cells[key]
		for info: Dictionary in prototype.get_property_list():
			var name: String = info.name
			if not cell.has(name) or name == "value": continue
			var current: Variant = prototype.get(name)
			if current is Color:
				if not cell[name] is String: return false
				var html: String = cell[name]
				if not Color.html_is_valid(html): return false
			elif not _shape(cell[name], current): return false
		if cell.has("value") and not _json_value(cell.value): return false
		if cell.has("type"):
			var kind: float = cell.type
			if not Cell.CellType.values().has(int(kind)): return false
			if int(kind) == Cell.CellType.FORMULA:
				var formula: String = cell.get("formula", "")
				if not formula.begins_with("="): return false
		if cell.has("alignment"):
			var alignment: float = cell.alignment
			if alignment > HORIZONTAL_ALIGNMENT_FILL: return false
	var charts: Array = input.get("charts", [])
	var chart: Chart = Chart.new()
	chart.series = [{"range": "", "name": "", "color": Color.WHITE}]
	for entry: Variant in charts:
		if not _shape(entry, chart.to_dict()): return false
		var fields: Dictionary = entry
		if fields.has("type"):
			var kind: float = fields.type
			if not Chart.ChartType.values().has(int(kind)): return false
	if input.has("autofilter"):
		if not _safe_filter(input.autofilter): return false
	return true

static func _safe_filter(value: Variant) -> bool:
	var filter: Filter = Filter.new()
	filter.set_range(Rect2i(0, 0, 1, 1))
	filter.set_value_filter(0, PackedStringArray())
	if not _shape(value, filter.to_dict()): return false
	var fields: Dictionary = value
	var region: Array = fields.get("range", [])
	if region.size() != 4: return false
	var x: float = region[0]
	var y: float = region[1]
	var width: float = region[2]
	var height: float = region[3]
	if width <= 0 or height <= 0 or x + width > MAX_INDEX or y + height > MAX_INDEX: return false
	var criteria: Array = fields.get("columns", [])
	for criterion: Dictionary in criteria:
		var column: float = criterion.get("col", -1)
		if column < x or column >= x + width: return false
	return true

static func _shape(value: Variant, example: Variant) -> bool:
	if example is Dictionary:
		if not value is Dictionary: return false
		var fields: Dictionary = value
		var known: Dictionary = example
		for key: Variant in fields:
			if known.has(key) and not _shape(fields[key], known[key]): return false
		return true
	if example is Array:
		if not value is Array: return false
		var array: Array = value
		var examples: Array = example
		for item: Variant in array:
			if not examples.is_empty() and not _shape(item, examples[0]): return false
		return true
	if example is bool: return value is bool
	if example is String: return value is String
	if example is int or example is float:
		if not (value is int or value is float): return false
		var number: float = value
		return is_finite(number) and (not example is int or (number == floor(number) and number >= 0 and number <= MAX_INDEX))
	return true

static func _json_value(value: Variant) -> bool:
	if value == null or value is bool or value is String or value is int or value is float: return true
	if value is Array:
		var array: Array = value
		for item: Variant in array:
			if not _json_value(item): return false
		return true
	if value is Dictionary:
		var fields: Dictionary = value
		for key: Variant in fields:
			if not key is String or not _json_value(fields[key]): return false
		return true
	return false

static func _preserves(input: Variant, output: Variant, path: String = "") -> bool:
	if input is Dictionary:
		if not output is Dictionary: return false
		var fields: Dictionary = input
		var result: Dictionary = output
		for key: Variant in fields:
			if not result.has(key) or not _preserves(fields[key], result[key], path + "/" + str(key) if not path.is_empty() else str(key)): return false
		return true
	if input is Array:
		if not output is Array: return false
		var array: Array = input
		var result: Array = output
		if result.size() != array.size():
			if path not in ["rows", "columns"] or result.size() < array.size(): return false
			var fallback: Dictionary = Data.RowMeta.new().to_dict() if path == "rows" else Data.ColumnMeta.new().to_dict()
			for index: int in range(array.size(), result.size()):
				if result[index] != fallback: return false
		for index: int in array.size():
			if not _preserves(array[index], result[index], path + "/" + str(index)): return false
		return true
	if (input is int or input is float) and (output is int or output is float):
		var left: float = input
		var right: float = output
		if is_nan(left) or is_nan(right): return is_nan(left) and is_nan(right)
		if is_inf(left) or is_inf(right): return left == right
		# Match the serializer's JSON precision, including Color float32 channels.
		return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))
	return typeof(input) == typeof(output) and input == output
