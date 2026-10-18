extends RefCounted
## Real engine results, not pre-filled cache values, define compatibility.
const Data := preload("../../ui/domain/SpreadsheetData.gd")
const Snapshot := preload("../../ui/snapshot.gd")

func run(check: Callable) -> void:
	var data: Data = Data.new()
	data.set_cell_value(0, 0, 1)
	data.set_cell_value(1, 0, 2)
	var formulas: Array[String] = ["=A1+1", "=1<2", '= "text"', "=A1:A2", "=B1:B2", "=10^1000"]
	# B1 is the flat range; C1 consequently sees a nested Array through B1.
	data.set_cell_value(0, 1, formulas[3])
	data.set_cell_value(0, 2, formulas[4])
	data.set_cell_value(0, 3, formulas[0])
	data.set_cell_value(0, 4, formulas[1])
	data.set_cell_value(0, 5, formulas[2])
	data.set_cell_value(0, 6, formulas[5])
	data.recalculate_all()
	var expected: Dictionary = {"0,1": [1.0, 2.0], "0,2": [[1.0, 2.0], 0], "0,3": 2.0, "0,4": true, "0,5": "text"}
	for key: String in expected:
		var position: Vector2i = Data.parse_cell_key(key)
		check.call("actual engine emits supported cached value " + key, data.get_cell_value(position.y, position.x) == expected[key])
	var overflow: Variant = data.get_cell_value(0, 6)
	check.call("actual power overflow is a nonfinite numeric cache", overflow is float and is_inf(overflow))
	var model: Dictionary = data.to_dict()
	check.call("every real engine value validates before save", Snapshot.validate(model))
	var restored: Data = Data.new()
	restored.load_from_dict(model)
	for key: String in expected:
		var position: Vector2i = Data.parse_cell_key(key)
		check.call("direct model reload preserves cached value " + key, restored.get_cell_value(position.y, position.x) == expected[key])
	var restored_inf: Variant = restored.get_cell_value(0, 6)
	check.call("direct model reload preserves INF", restored_inf is float and is_inf(restored_inf))
	var encoded: String = JSON.stringify(model)
	var parser := JSON.new()
	var parse_result: Error = parser.parse(encoded)
	print("VALUE_DOMAIN_JSON_RESULT=" + str(parse_result))
	if parse_result == OK:
		var parsed: Dictionary = parser.data
		print("VALUE_DOMAIN_JSON_INF_CACHE=" + JSON.stringify(parsed.cells["0,6"].value))
		check.call("JSON-produced cached value remains accepted", Snapshot.validate(parsed))
		var reopened: Data = Data.new()
		reopened.load_from_dict(parsed)
		reopened.recalculate_all()
		for key: String in expected:
			var position: Vector2i = Data.parse_cell_key(key)
			check.call("JSON reopen and evaluation preserve engine value " + key, reopened.get_cell_value(position.y, position.x) == expected[key])
		var evaluated_inf: Variant = reopened.get_cell_value(0, 6)
		check.call("reopened overflow formula evaluates again", evaluated_inf is float and is_inf(evaluated_inf))
	else:
		check.call("existing nonfinite JSON encoding is recorded explicitly", encoded.contains("inf") or encoded.contains("INF"))
		print("EXISTING_NONFINITE_JSON_LOSS=" + parser.get_error_message())
	# Null caches arise when JSON replaces a nonfinite number; loaded formulas
	# still recompute. The cache's nullable contract must remain supported.
	var nullable: Dictionary = model.duplicate(true)
	nullable.cells["0,6"].value = null
	check.call("nullable formula cache validates", Snapshot.validate(nullable))
	for bound: String in ["header_row_count", "frozen_rows", "frozen_cols"]:
		var legacy: Dictionary = model.duplicate(true)
		legacy[bound] = 2147483647
		check.call("legacy excessive bound remains a valid snapshot " + bound, Snapshot.validate(legacy))
		var loaded: Data = Data.new()
		loaded.load_from_dict(legacy)
		check.call("legacy excessive bound round-trips unchanged " + bound, loaded.get(bound) == 2147483647)
	var dimensions: Data = Data.new(100, 26)
	dimensions.frozen_rows = 99
	dimensions.header_row_count = 99
	dimensions.frozen_cols = 25
	for ignored: int in 2:
		dimensions.delete_row(99 - ignored)
		dimensions.delete_column(25 - ignored)
	var saved: Dictionary = dimensions.to_dict()
	check.call("freeze/delete output clamps counts before serialization", dimensions.row_count == 98 and dimensions.column_count == 24
		and saved.frozen_rows == 98 and saved.header_row_count == 98 and saved.frozen_cols == 24)
	check.call("freeze/delete output validates", Snapshot.validate(saved))
	var decoded: Dictionary = JSON.parse_string(JSON.stringify(saved))
	var final: Data = Data.new()
	final.load_from_dict(decoded)
	check.call("freeze/delete JSON reopen preserves clamped counts", final.frozen_rows == 98 and final.header_row_count == 98 and final.frozen_cols == 24)
	var metadata: Data = Data.new(1, 1)
	metadata.delete_row(0)
	metadata.delete_column(0)
	check.call("delete-last metadata defaults are a tested normalization", Snapshot.validate(metadata.to_dict()))
	var cached_object: Dictionary = model.duplicate(true)
	cached_object.cells["0,6"].value = {"cached": [1, null, true]}
	check.call("JSON-compatible Variant cache survives the actual loader", Snapshot.validate(cached_object))
