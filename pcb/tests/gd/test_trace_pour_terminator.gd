extends SceneTree
## A PLANE IS SOMETHING A RUN CAN END ON — and an unplated hole is not.
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout>, or directly:
##   godot --headless --path src --script ../../minerva-plugins/pcb/tests/gd/test_trace_pour_terminator.gd
##
## On a plane-returned board most runs end on the pour, not on a pad. Before
## this, the only way to stop there was a double-click, which left the run with
## a FREE END — reported as a dangling open by the connectivity DRC and offered
## straight back by the tool as a loose end to continue from. The fix is one
## more rung on the trace tool's anchor ladder, reading the SAME compiled fill
## the ratsnest counts and the worker's DRC measures.
##
## WHAT IS PINNED:
##   1. a click inside a SAME-NET pour's fill finishes the run, on one press
##   2. …and the end it leaves is not a free end
##   3. a click inside a DIFFERENT-NET pour is a waypoint, not a landing, and
##      the run that stops there keeps a free end for the DRC to name
##   4. an UNFILLED pour terminates nothing — unproven copper is not copper
##   5. a click inside the pour's OUTLINE but in a carved VOID terminates
##      nothing: a pour conducts as its fill
##   6. an unplated hole's land joins nothing, so a net bridged only by one
##      still owes a join
##
## INDEPENDENT REPRESENTATION: the SERIALIZED traces out of to_board_dict() and
## the model's own trace_end_is_joined / the ratsnest's own solve() — never the
## tool's _trace_points buffer, which is the thing under test.

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const Ratsnest := preload("res://../../minerva-plugins/pcb/ui/model/pcb_ratsnest.gd")

var _pass := 0
var _fail := 0


## The pad oracle the tool asks for pads. The tool only ever calls pad_at(), and
## every pad in this suite is a bare point far from any click that is meant to
## reach the plane.
class StubPadHost extends RefCounted:
	var pads: Array = []
	var board: Variant = null
	func get_board_data() -> Variant:
		return board
	func pad_at(world_pos: Vector2, radius: float, _filter: Variant = null) -> Dictionary:
		for p in pads:
			if (p["position"] as Vector2).distance_to(world_pos) <= radius:
				return p
		return {}


func _init() -> void:
	print("=== Trace tool: a same-net pour is a terminator ===\n")
	_test_a_same_net_pour_finishes_the_run()
	_test_a_foreign_pour_is_only_a_waypoint()
	_test_an_unfilled_pour_terminates_nothing()
	_test_a_carved_void_terminates_nothing()
	_test_an_unplated_hole_joins_nothing()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: " + desc)
	else:
		_fail += 1
		if detail.is_empty():
			printerr("  FAIL: " + desc)
		else:
			printerr("  FAIL: %s — %s" % [desc, detail])


# ── the board ────────────────────────────────────────────────────────────────
#
# GND pour: outline (15,15)-(45,35) on TOP, and a fill that is the FRACTURED
# KEYHOLE of that rectangle around a 4 x 6 mm void at (28,22)-(32,28) — a void
# joined to the left edge by a zero-width slit along y = 25, which is how a fill
# expresses a hole. (20,20) is solid copper; (30,25) is the void's centre and is
# inside the OUTLINE but outside the COPPER.
#
# SIG pour: (48,15)-(58,35) on top, filled solid, disjoint from the GND pour —
# two pours of different nets may share a layer, they may not share copper.
#
# Pads: U1.1 (5,5) and R1.1 (5,35) on GND, C1.1 (55,5) on SIG. All far from
# every click below, so no click can be answered by the pad rung.

const GND_SOLID := Vector2(20.0, 20.0)
const GND_VOID := Vector2(30.0, 25.0)


func _keyhole_fill() -> Array:
	return [[
		{"x_mm": 15.0, "y_mm": 15.0}, {"x_mm": 45.0, "y_mm": 15.0},
		{"x_mm": 45.0, "y_mm": 35.0}, {"x_mm": 15.0, "y_mm": 35.0},
		{"x_mm": 15.0, "y_mm": 25.0}, {"x_mm": 28.0, "y_mm": 25.0},
		{"x_mm": 28.0, "y_mm": 28.0}, {"x_mm": 32.0, "y_mm": 28.0},
		{"x_mm": 32.0, "y_mm": 22.0}, {"x_mm": 28.0, "y_mm": 22.0},
		{"x_mm": 28.0, "y_mm": 25.0}, {"x_mm": 15.0, "y_mm": 25.0},
	]]


func _rect_outline(a: Vector2, b: Vector2) -> Array:
	return [{"x_mm": a.x, "y_mm": a.y}, {"x_mm": b.x, "y_mm": a.y},
		{"x_mm": b.x, "y_mm": b.y}, {"x_mm": a.x, "y_mm": b.y}]


func _board() -> Dictionary:
	return {
		"version": 1, "name": "PourBoard", "width_mm": 60.0, "height_mm": 40.0,
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2,
			"trace_width_mm": 0.25},
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "U1", "footprint": "IC", "x_mm": 5.0, "y_mm": 5.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
			{"ref": "R1", "footprint": "R", "x_mm": 5.0, "y_mm": 35.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
			{"ref": "C1", "footprint": "C", "x_mm": 55.0, "y_mm": 5.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		],
		"nets": [
			{"name": "GND", "pins": ["U1.1", "R1.1"]},
			{"name": "SIG", "pins": ["C1.1"]},
		],
		"zones": [
			{"id": "z_gnd", "kind": "copper_pour", "net": "GND", "layer": "top",
				"outline": _rect_outline(Vector2(15, 15), Vector2(45, 35))},
			{"id": "z_sig", "kind": "copper_pour", "net": "SIG", "layer": "top",
				"outline": _rect_outline(Vector2(48, 15), Vector2(58, 35))},
		],
	}


## A pour's fill reaches the model through adopt_zone_fill and no other door
## (PCBData.ZONE_FILL_KEY) — so the fixture hands it over the way the compiler's
## answer arrives, rather than smuggling it in through the board dict.
func _rig(filled: bool = true) -> Array:
	var canvas = PcbCanvasScript.new()
	var data = PCBData.new()
	data.from_board_dict(_board())
	if filled:
		data.adopt_zone_fill([
			{"id": "z_gnd", "fill": _keyhole_fill()},
			{"id": "z_sig", "fill": [_rect_outline(Vector2(48, 15), Vector2(58, 35))]},
		])
	canvas.data = data
	canvas.zoom = 8.0
	canvas.snap_to_grid = false
	var host := StubPadHost.new()
	host.pads = [
		{"component": "U1", "pin": "1", "position": Vector2(5.0, 5.0)},
		{"component": "R1", "pin": "1", "position": Vector2(5.0, 35.0)},
		{"component": "C1", "pin": "1", "position": Vector2(55.0, 5.0)},
	]
	host.board = data
	canvas.set_pin_inspector_host(host)
	canvas.set_tool_mode(canvas.ToolMode.TRACE)
	return [canvas, data]


func _serialized_traces(data) -> Array:
	return (data.to_board_dict().get("traces", []) as Array)


func _last_point(trace: Dictionary) -> Vector2:
	var pts: Array = trace.get("points", [])
	if pts.is_empty():
		return Vector2.INF
	var p: Dictionary = pts[pts.size() - 1]
	return Vector2(float(p.get("x_mm", 0.0)), float(p.get("y_mm", 0.0)))


# ── 1 + 2. a same-net pour finishes the run, and leaves no free end ──────────

func _test_a_same_net_pour_finishes_the_run() -> void:
	print("-- 1. a click in the GND fill finishes a GND run, on ONE press --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]

	canvas._handle_trace_click(Vector2(5.0, 5.0), false)   # start on U1.1 (GND)
	canvas._handle_trace_click(GND_SOLID, false)           # into the plane

	var traces := _serialized_traces(data)
	check("one press inside the plane committed the trace", traces.size() == 1,
		"traces=%d" % traces.size())
	if traces.size() != 1:
		return
	var t: Dictionary = traces[0]
	check("…on the pour's net", str(t.get("net", "")) == "GND")
	check("…ending exactly where the click landed, not at a pad centre",
		_last_point(t).is_equal_approx(GND_SOLID), str(_last_point(t)))

	# ORACLE for "no free end": the model's own rule, which the tool never
	# writes. An end the tool just finished on a plane must not be offered back
	# as somewhere to continue drawing from.
	var tid := str(t.get("id", ""))
	check("the end it left is NOT a free end",
		data.trace_end_is_joined(tid, data.TRACE_END_END))
	check("…and the free-end pick offers nothing there",
		data.free_trace_end_at(GND_SOLID, 1.0).is_empty())


# ── 3. a foreign plane is copper, but not THIS run's copper ─────────────────

func _test_a_foreign_pour_is_only_a_waypoint() -> void:
	print("-- 2. a click in a DIFFERENT net's fill does not finish the run --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]

	canvas._handle_trace_click(Vector2(55.0, 5.0), false)  # start on C1.1 (SIG)
	canvas._handle_trace_click(GND_SOLID, false)           # into the GND plane

	check("nothing was committed — the click was a waypoint",
		_serialized_traces(data).is_empty(),
		"traces=%d" % _serialized_traces(data).size())

	canvas._handle_trace_click(GND_SOLID, true)            # double-click: commit
	var traces := _serialized_traces(data)
	check("the run commits only when the user says so", traces.size() == 1,
		"traces=%d" % traces.size())
	if traces.size() != 1:
		return
	var tid := str((traces[0] as Dictionary).get("id", ""))
	check("…and the end it leaves in the foreign plane IS free — an open for "
		+ "the DRC to name, never a silent join",
		not data.trace_end_is_joined(tid, data.TRACE_END_END))


# ── 4. an unfilled pour is not copper ───────────────────────────────────────

func _test_an_unfilled_pour_terminates_nothing() -> void:
	print("-- 3. an UNFILLED pour terminates nothing --")
	var rig := _rig(false)
	var canvas = rig[0]
	var data = rig[1]

	canvas._handle_trace_click(Vector2(5.0, 5.0), false)   # start on U1.1 (GND)
	canvas._handle_trace_click(GND_SOLID, false)

	check("the same click inside the same outline is a waypoint when no fill "
		+ "has been computed", _serialized_traces(data).is_empty(),
		"traces=%d" % _serialized_traces(data).size())


# ── 5. the fill, not the outline ────────────────────────────────────────────

func _test_a_carved_void_terminates_nothing() -> void:
	print("-- 4. a click in a carved VOID is inside the outline, not the copper --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]

	canvas._handle_trace_click(Vector2(5.0, 5.0), false)   # start on U1.1 (GND)
	canvas._handle_trace_click(GND_VOID, false)

	# (30,25) is 5mm inside the outline's own edges and 2mm from the nearest
	# copper edge of the void. A tool reading the OUTLINE would land here.
	check("a void inside the pour is not somewhere a run can end",
		_serialized_traces(data).is_empty(),
		"traces=%d" % _serialized_traces(data).size())


# ── 6. an unplated hole is not a conductor ──────────────────────────────────

## J1's pin 1 has TWO lands: an SMD land on TOP, and an unplated hole at the same
## spot. F1.1 is an SMD land on the BOTTOM, 1mm to the right, overlapping the
## hole's 3mm land but not the 2mm top land.
##
## F1 IS MOUNTED ON THE BOTTOM AND AUTHORS ITS LAND ON "F.Cu". `pads[].layers`
## are FOOTPRINT-local, exactly like `pads[].position`: the placement rule flips
## them for a bottom-mounted part (PcbComponent.placed_pad_layers), so a land a
## footprint authors on the front is what prints on the BACK once the part is
## placed there. Spelling it "B.Cu" here would put the land on TOP, overlapping
## J1's own top land — one island, and the join this section is about would
## never be owed.
##
## ORACLE, by hand. J1's top land spans x in [9,11] on TOP; F1's spans x in
## [10,12] on BOTTOM — they overlap in plan but share no layer, so they are two
## islands and the net owes ONE join. The unplated hole's land spans x in
## [8.5,11.5] on every layer and would bridge them into one island with nothing
## owed — which is a via with a 3mm barrel that the board does not have.
##
## FAILS AGAINST THE OLD MODEL, which read `np_thru_hole` as an all-layer land
## and reported this net as already whole.
func _test_an_unplated_hole_joins_nothing() -> void:
	print("-- 5. an unplated hole's land joins nothing --")
	var data = PCBData.new()
	data.from_board_dict({
		"version": 1, "name": "NpthBoard", "width_mm": 40.0, "height_mm": 20.0,
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "J1", "footprint": "CUSTOM", "x_mm": 10.0, "y_mm": 10.0,
				"rotation_deg": 0.0, "layer": "top", "has_pad_geometry": true,
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
				"pads": [
					{"number": "1", "type": "smd", "shape": "rect",
						"position": {"x": 0.0, "y": 0.0},
						"size": {"width": 2.0, "height": 2.0},
						"layers": ["F.Cu"]},
					{"number": "1", "type": "np_thru_hole", "shape": "circle",
						"position": {"x": 0.0, "y": 0.0},
						"size": {"width": 3.0, "height": 3.0},
						"drill": {"x": 3.0, "y": 3.0},
						"layers": ["*.Cu"]},
				]},
			{"ref": "F1", "footprint": "CUSTOM", "x_mm": 11.0, "y_mm": 10.0,
				"rotation_deg": 0.0, "layer": "bottom", "has_pad_geometry": true,
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
				"pads": [{"number": "1", "type": "smd", "shape": "rect",
					"position": {"x": 0.0, "y": 0.0},
					"size": {"width": 2.0, "height": 2.0},
					"layers": ["F.Cu"]}]},
		],
		"nets": [{"name": "NPTHNET", "pins": ["J1.1", "F1.1"]}],
		"traces": [], "vias": [], "zones": [],
	})

	var result := Ratsnest.compute(data)
	var links: Array = []
	for link in (result.get("links", []) as Array):
		if str((link as Dictionary)["net"]) == "NPTHNET":
			links.append(link)
	check("the net bridged only by an unplated hole still owes one join",
		links.size() == 1, "links=%d" % links.size())
	if links.size() == 1:
		check("…and that join crosses layers, which is what a real via would fix",
			bool((links[0] as Dictionary)["layer_change"]))
