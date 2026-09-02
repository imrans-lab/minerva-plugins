extends SceneTree
## A `pins` entry in a canonical board is an OVERRIDE of the like-numbered land
## and nothing else.
##
## to_board_dict must not write a pin that merely restates the land this host's
## resolve already supplied, and adopt_resolved must re-derive the pin map from
## those lands so dropping them is lossless: a reopened board whose parts state
## only their deviations still has pins to route to. A part that OWNS its pads,
## or that has not resolved, keeps every pin — there is no library reading to
## call the pin redundant against.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_pin_override_only.gd

const PCBComponent := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== pins are overrides only ===\n")
	_test_restating_pins_are_not_written()
	_test_deviations_are_written()
	_test_unresolved_and_authored_parts_keep_every_pin()
	_test_document_round_trip_keeps_the_pin_map()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


## The `resolved[ref]` entry a pcb.deserialize reply carries: two library lands.
func _resolved_entry() -> Dictionary:
	return {
		"footprint_resolved": true,
		"has_pad_geometry": true,
		"pads": [
			{"number": "1", "type": "smd", "shape": "rect",
				"position": {"x": -1.0, "y": 0.0},
				"size": {"width": 1.0, "height": 1.0}, "drill": {"x": 0.0, "y": 0.0},
				"layers": ["F.Cu"]},
			{"number": "2", "type": "smd", "shape": "rect",
				"position": {"x": 1.0, "y": 0.0},
				"size": {"width": 1.0, "height": 1.0}, "drill": {"x": 0.0, "y": 0.0},
				"layers": ["F.Cu"]},
		],
	}


func _library_part(pins: Array) -> Object:
	var data := {"ref": "R1", "footprint": "Resistor_SMD:R_0402", "layer": "top",
		"x_mm": 10.0, "y_mm": 10.0, "rotation_deg": 0.0}
	if not pins.is_empty():
		data["pins"] = pins
	return PCBComponent.from_board_dict(data, _resolved_entry())


func _test_restating_pins_are_not_written() -> void:
	# The board declares exactly what the library already says.
	var comp := _library_part([
		{"number": "1", "x_mm": -1.0, "y_mm": 0.0},
		{"number": "2", "x_mm": 1.0, "y_mm": 0.0},
	])
	var d: Dictionary = comp.to_board_dict()
	check("a library part whose pins equal its lands writes NO pins key", not d.has("pins"))
	check_eq("the pin map itself is intact for routing", comp.pins.size(), 2)


func _test_deviations_are_written() -> void:
	# Three kinds of content the library cannot supply, each of which keeps its pin:
	# a moved pad, a typed override, and the part's own pin-table name.
	var moved: Dictionary = _library_part([{"number": "1", "x_mm": -1.5, "y_mm": 0.0}]).to_board_dict()
	check_eq("a pin off its land is written", (moved.get("pins", []) as Array).size(), 1)

	var overridden: Dictionary = _library_part([
		{"number": "1", "x_mm": -1.0, "y_mm": 0.0, "override": {"pad_width_mm": 2.0}},
	]).to_board_dict()
	var over_pins: Array = overridden.get("pins", [])
	check_eq("a pin carrying a typed override is written", over_pins.size(), 1)
	check("the override rides along verbatim",
		(over_pins[0] as Dictionary).get("override") == {"pad_width_mm": 2.0})

	var named: Dictionary = _library_part([
		{"number": "1", "x_mm": -1.0, "y_mm": 0.0, "name": "VCC"},
	]).to_board_dict()
	check_eq("a pin carrying a symbolic name is written (no land has one)",
		(named.get("pins", []) as Array).size(), 1)


func _test_unresolved_and_authored_parts_keep_every_pin() -> void:
	# No resolve on this host: nothing to call the pin redundant against.
	var unresolved: Object = PCBComponent.from_board_dict({
		"ref": "R2", "footprint": "Resistor_SMD:R_0402", "layer": "top",
		"x_mm": 0.0, "y_mm": 0.0, "rotation_deg": 0.0,
		"pins": [{"number": "1", "x_mm": -1.0, "y_mm": 0.0}]})
	check_eq("an unresolved part keeps its pins",
		((unresolved.to_board_dict().get("pins", [])) as Array).size(), 1)

	# The board OWNS its pads (a `pads` key) — full geometry authority, unchanged.
	var authored: Object = PCBComponent.from_board_dict({
		"ref": "R3", "footprint": "Resistor_SMD:R_0402", "layer": "top",
		"x_mm": 0.0, "y_mm": 0.0, "rotation_deg": 0.0,
		"pins": [{"number": "1", "x_mm": -1.0, "y_mm": 0.0}],
		"pads": (_resolved_entry()["pads"] as Array)}, _resolved_entry())
	var authored_dict: Dictionary = authored.to_board_dict()
	check_eq("a part that owns its pads keeps its pins",
		((authored_dict.get("pins", [])) as Array).size(), 1)
	check("and still states its pads", authored_dict.has("pads"))


func _test_document_round_trip_keeps_the_pin_map() -> void:
	# THE LOSSLESSNESS ORACLE: write a part whose pins all restate the library,
	# reopen the written dict, hand it the same resolve — the pin map must come
	# back whole. If adopt_resolved did not re-derive it, this part would reopen
	# with nothing to route to.
	var written: Dictionary = _library_part([
		{"number": "1", "x_mm": -1.0, "y_mm": 0.0},
		{"number": "2", "x_mm": 1.0, "y_mm": 0.0},
	]).to_board_dict()
	var reopened: Object = PCBComponent.from_board_dict(written, _resolved_entry())
	check_eq("the reopened part has both pins", reopened.pins.size(), 2)
	check("pin 1 sits on its land",
		(reopened.pins.get("1", Vector2.ONE) as Vector2).distance_to(Vector2(-1.0, 0.0)) < 1e-6)
	check("pin 2 sits on its land",
		(reopened.pins.get("2", Vector2.ONE) as Vector2).distance_to(Vector2(1.0, 0.0)) < 1e-6)
	check("and writing it again is still pins-free", not reopened.to_board_dict().has("pins"))


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)
