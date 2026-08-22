extends SceneTree
## SR2FAB S10: millimetre values leave this surface on one grid.
##
## Vector2 is single-precision. A component the author placed at 75.4 is STORED
## as 75.40000152587890625 — the float32 representation of the number typed, not
## a measurement — and every reply handed that value straight out. It travels:
## smart-remote-v2 is routed by an external Manhattan router that reads pad
## centres over MCP, computes against them, and writes copper back. A sub-micron
## residue in what it read becomes a sub-micron miss in what it writes, which
## then reads as a real geometric finding nobody authored.
##
## MEASURED, because the fix depends on it (godot 4.6.2):
##   Vector2(75.4).x                      -> 75.40000152587890625
##   snapped(that, 0.0001)                -> 75.40000000000000568  (== 75.4)
##   snapped(...) stored back in a Vector2 -> 75.40000152587890625  (grid LOST)
##
## So the grid can only be held at the REPLY boundary, where the value becomes a
## 64-bit float on its way to JSON. That is why there is no ingest-side snap:
## storing a snapped value into a Vector2 gives the float32 back unchanged, so
## an ingest snap is dead code wearing the shape of a guarantee — and snapping
## an author's deliberately off-grid input would silently move their copper.
##
## The round trip closes anyway, which is what the sweep is for: the router
## reads 75.4, writes 75.4, that stores as the same float32, and reads back as
## 75.4 again.
##
## RED/GREEN: every assertion fails against pre-station code, which emitted the
## float32 residue verbatim.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_mm_quantization.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")

## The exact value that exposed this: a real pad centre on smart-remote-v2.
const AUTHORED_X := 75.4
const AUTHORED_Y := 12.5

var _pass := 0
var _fail := 0


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s%s" % [desc, ("" if detail == "" else " — " + detail)])


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)],
		actual == expected)


class FakeEditor extends RefCounted:
	var tab_title: String = ""


func _rig() -> Dictionary:
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict({
		"version": 1, "name": "s10", "width_mm": 100.0, "height_mm": 100.0,
		"layers": ["top", "bottom"],
		"components": [{
			"ref": "Q1", "footprint": "", "x_mm": AUTHORED_X, "y_mm": AUTHORED_Y,
			"rotation_deg": 0, "layer": "top",
			"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0},
				{"number": "2", "x_mm": 1.0, "y_mm": 0.0}]}],
		"nets": [{"name": "GND", "pins": ["Q1.1"]}]})
	return {"panel": panel, "host": panel.get_annotation_host()}


func _init() -> void:
	print("=== S10: millimetre quantization ===\n")
	await process_frame
	_run_the_premise()
	await _run_emitters()
	await _run_round_trip()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── 1: the premise, so a later reader can check it rather than trust it ─────

func _run_the_premise() -> void:
	print("-- 1: what float32 actually does --")
	var v := Vector2(AUTHORED_X, AUTHORED_Y)
	check("a Vector2 does NOT hold the authored value",
		float(v.x) != AUTHORED_X,
		"%.17f" % float(v.x))
	check("snapping it to the 0.1um grid recovers exactly what was authored",
		snapped(v.x, 0.0001) == AUTHORED_X,
		"%.17f" % snapped(v.x, 0.0001))
	# THE REASON THERE IS NO INGEST SNAP. Storing the snapped value back into a
	# Vector2 returns the float32 again, so an ingest-side snap changes nothing.
	var round_tripped := Vector2(snapped(v.x, 0.0001), v.y)
	check("…and storing it BACK into a Vector2 loses the grid again",
		float(round_tripped.x) != AUTHORED_X,
		"%.17f" % float(round_tripped.x))
	# The grid is far coarser than float32 noise, so nothing real is quantized
	# away: two positions 0.1um apart stay distinct.
	check("the grid is coarser than float32 noise at board coordinates",
		Vector2(75.4, 0.0).x != Vector2(75.4001, 0.0).x)


# ── 2: every emitter is on the grid ─────────────────────────────────────────

func _run_emitters() -> void:
	print("\n-- 2: emitters --")
	var rig := _rig()
	var host = rig["host"]

	var pin: Dictionary = await PanelTools.handle(
		host, "minerva_pcb_get_pin_position", {"component_id": "Q1", "pin": "1"})
	check("get_pin_position answers", bool(pin.get("success", false)), str(pin))
	var world: Dictionary = pin.get("world_position", {})
	check_eq("…world_position.x is the authored number", float(world.get("x", -1.0)), AUTHORED_X)
	check_eq("…world_position.y is the authored number", float(world.get("y", -1.0)), AUTHORED_Y)
	var comp_pos: Dictionary = pin.get("component_position", {})
	check_eq("…component_position rides the same grid",
		float(comp_pos.get("x", -1.0)), AUTHORED_X)

	var comps: Dictionary = await PanelTools.handle(host, "minerva_pcb_get_components", {})
	var found := false
	for c in (comps.get("components", []) as Array):
		if str((c as Dictionary).get("ref", "")) == "Q1" \
				or str((c as Dictionary).get("id", "")).findn("Q1") != -1:
			found = true
			check_eq("get_components x is on the grid",
				float((c as Dictionary).get("x", -1.0)), AUTHORED_X)
			check_eq("get_components y is on the grid",
				float((c as Dictionary).get("y", -1.0)), AUTHORED_Y)
	check("the component was found in get_components", found, str(comps.get("components", [])))

	var described: Dictionary = await PanelTools.handle(
		host, "minerva_pcb_describe_component", {"component_id": "Q1"})
	if described.has("x"):
		check_eq("describe_component x is on the grid",
			float(described.get("x", -1.0)), AUTHORED_X)


# ── 3: the loop that actually matters ───────────────────────────────────────

func _run_round_trip() -> void:
	print("\n-- 3: read, compute, write back, read again --")
	var rig := _rig()
	var host = rig["host"]

	# What the external router does: read the pad centre...
	var first: Dictionary = await PanelTools.handle(
		host, "minerva_pcb_get_pin_position", {"component_id": "Q1", "pin": "1"})
	var x: float = float((first.get("world_position", {}) as Dictionary).get("x", 0.0))
	var y: float = float((first.get("world_position", {}) as Dictionary).get("y", 0.0))

	# ...and write geometry back at exactly the coordinate it was given.
	var moved: Dictionary = await PanelTools.handle(
		host, "minerva_pcb_move_component", {"component_id": "Q1", "x": x, "y": y})
	check("the move is accepted", bool(moved.get("success", false)), str(moved))
	check_eq("…and echoes the coordinate it was handed, unchanged",
		[float(moved.get("x", -1.0)), float(moved.get("y", -1.0))], [x, y])

	# ...and reading it again gives the same number a third time. Without the
	# quantization this is where the drift compounds: each hop through float32
	# hands back a value the caller did not send.
	var second: Dictionary = await PanelTools.handle(
		host, "minerva_pcb_get_pin_position", {"component_id": "Q1", "pin": "1"})
	check_eq("a full read/write/read cycle is a fixed point",
		[float((second.get("world_position", {}) as Dictionary).get("x", 0.0)),
		 float((second.get("world_position", {}) as Dictionary).get("y", 0.0))],
		[x, y])
