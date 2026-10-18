extends RefCounted
## Independent malformed complete snapshots, one negative per accepted field type.
const NEGATIVES: Array = [
	["version", ["version"], 99],
	["integer", ["row_count"], 2.5],
	["integer type", ["column_count"], true],
	["positive dimension", ["row_count"], 0],
	["formula required", ["cells", "0,0", "type"], 4],
	["filter criterion payload", ["autofilter", "columns", 0, "type"], "text"],
	["duplicate filter indices", ["autofilter", "columns"], [{"col": 0, "type": "values", "values": []}, {"col": 0, "type": "values", "values": []}]],
	["number", ["columns", 0, "width"], "wide"],
	["string", ["columns", 0, "header_name"], 17],
	["boolean", ["rows", 0, "is_header"], 0],
	["enum alignment", ["cells", "0,0", "alignment"], 99],
	["enum cell type", ["cells", "0,0", "type"], -1],
	["HTML text color", ["cells", "0,0", "text_color"], "not-a-color"],
	["HTML background color", ["cells", "0,0", "bg_color"], "#invalid"],
	["object", ["cells"], ["wrong shape"]],
	["nested array", ["rows"], [null]],
	["chart enum", ["charts", 0, "type"], 2],
	["chart number", ["charts", 0, "width"], false],
	["series object", ["charts", 0, "series"], [17]],
	["range length", ["autofilter", "range"], [0, 0, 2]],
	["range size", ["autofilter", "range"], [0, 0, 0, 2]],
	["index", ["autofilter", "columns", 0, "col"], -1],
	["index bounds", ["autofilter", "columns", 0, "col"], 99],
	["filter enum", ["autofilter", "columns", 0, "type"], "regex"],
	["string array", ["autofilter", "columns", 0, "values"], [17]],
	["unknown field", ["future_field"], 1],
]

func entries(native: Dictionary, check: Callable) -> Array[Dictionary]:
	var valid: Dictionary = native.duplicate(true)
	valid.plugin_state.payload.__panel_state.autofilter = {"range": [0, 0, 2, 2],
		"columns": [{"col": 0, "type": "values", "values": ["Name"]}]}
	var model: Dictionary = valid.plugin_state.payload.__panel_state
	var panel_script: Script = load(ProjectSettings.globalize_path("res://../../minerva-plugins/sheets/ui/snapshot.gd"))
	check.call("negative matrix starts from a complete accepted model", panel_script.validate(model))
	var invalid: Array[Dictionary] = []
	for case: Array in NEGATIVES:
		var entry: Dictionary = valid.duplicate(true)
		var target: Variant = entry.plugin_state.payload.__panel_state
		var path: Array = case[1]
		for index: int in path.size() - 1:
			target = target[path[index]]
		target[path[-1]] = case[2]
		invalid.append(entry)
	var orphan: Dictionary = valid.duplicate(true)
	orphan.plugin_state.payload.__panel_state.charts[0].erase("background_color_r")
	invalid.append(orphan)
	var outer: Dictionary = valid.duplicate(true)
	outer.plugin_state.version = 99
	invalid.append(outer) # Only the outer version changes; inner model stays valid.
	var missing: Dictionary = valid.duplicate(true)
	missing.plugin_state.payload.__panel_state.cells["0,0"].erase("type")
	invalid.append(missing)
	var key: Dictionary = valid.duplicate(true)
	key.plugin_state.payload.__panel_state.cells = {"00,0": {"type": 1, "value": "KEEP"}}
	invalid.append(key)
	var nonfinite: Dictionary = model.duplicate(true)
	nonfinite.rows[0].height = INF
	check.call("nonfinite numeric literal is refused before model loading", not panel_script.validate(nonfinite))
	return invalid
