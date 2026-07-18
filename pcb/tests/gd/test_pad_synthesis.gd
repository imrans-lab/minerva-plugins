extends SceneTree
## Bug 019f75c24bd2 regression — load_board pad synthesis must emit the pad-type
## token the canvas gates the drill hole on.
##
## _pads_from_canonical_pins (the minerva_pcb_load_board path) must set through-hole
## pads to "thru_hole", NOT "tht": pcb_canvas._draw_component_pads draws the inner
## drill circle only when pad_type in ["thru_hole","np_thru_hole"], so emitting
## "tht" rendered THT pads as solid copper discs with no hole. ("tht" is only the
## setup_generic_pins SIZING argument, never a stored pad type.)
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_pad_synthesis.gd

const PCBComponent := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")

## The exact set pcb_canvas.gd:_draw_component_pads gates the drill hole on. If a
## future edit drifts the synthesized type out of this set, holes stop drawing —
## these tests fail loudly instead of shipping holeless pads again.
const CANVAS_THT_TYPES := ["thru_hole", "np_thru_hole"]

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== load_board pad synthesis (Bug 019f75c24bd2) ===\n")
	_test_tht_with_annulus()
	_test_tht_drill_only()
	_test_smd()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


## Component dict with ONE pin and NO explicit `pads`/`width`/`height` → load_from_board_dict
## falls to _pads_from_canonical_pins (the whole-board load_board path under test).
func _synth_one_pad(pin: Dictionary) -> Dictionary:
	var comp := PCBComponent.new()
	comp.load_from_board_dict({"ref": "U1", "layer": "top", "pins": [pin]})
	return comp.pads[0] if comp.pads.size() == 1 else {}


func _test_tht_with_annulus() -> void:
	var pad := _synth_one_pad({"number": "1", "name": "VCC", "x_mm": 0.0, "y_mm": 0.0,
		"drill_mm": 0.8, "annulus_diameter_mm": 2.0})
	check_eq("THT pad type is 'thru_hole' (not 'tht')", pad.get("type"), "thru_hole")
	check("THT pad type is in the canvas drill-hole gate set", pad.get("type") in CANVAS_THT_TYPES)
	check("THT pad carries a positive drill", (pad.get("drill", Vector2.ZERO) as Vector2).x > 0.0)
	check_eq("THT pad size = annulus diameter", (pad.get("size", Vector2.ZERO) as Vector2).x, 2.0)


func _test_tht_drill_only() -> void:
	var pad := _synth_one_pad({"number": "2", "name": "GND", "x_mm": 0.0, "y_mm": 0.0,
		"drill_mm": 0.5})
	check_eq("drill-only THT pad type is 'thru_hole'", pad.get("type"), "thru_hole")
	check_eq("drill-only THT pad size = drill*2 fallback", (pad.get("size", Vector2.ZERO) as Vector2).x, 1.0)


func _test_smd() -> void:
	var pad := _synth_one_pad({"number": "1", "name": "A", "x_mm": 0.0, "y_mm": 0.0,
		"pad_width_mm": 1.5, "pad_height_mm": 0.9})
	check_eq("SMD pad type is 'smd'", pad.get("type"), "smd")
	check("SMD pad type is NOT in the THT gate set", not (pad.get("type") in CANVAS_THT_TYPES))


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)
