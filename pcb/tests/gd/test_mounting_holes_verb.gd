extends SceneTree
## SR2FAB S8: minerva_pcb_list_mounting_holes.
##
## Mounting holes could be written to the board and never read back. Nothing on
## any surface reported them, so a hole pattern that had been silently rewritten
## — every hole landing on one line, or two stacked at one point — was invisible
## until the board came back from the fab.
##
## No geometric check covers that shape either. GC11's proximity half never runs
## (no shipped profile publishes a hole-to-edge figure), GC6 fires only on a
## near-collision, and GC10 is about copper. So the verb carries its own
## advisory, and it is ADVISORY: collinear holes are a legitimate pattern on
## plenty of boards.
##
## RED/GREEN: every assertion here fails against pre-station code — the verb did
## not exist, so handle() returned {}.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_mounting_holes_verb.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")

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


func _rig(holes: Array) -> Dictionary:
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	var data = panel.get_data()
	data.mounting_holes.clear()
	for h in holes:
		data.mounting_holes.append(h)
	return {"panel": panel, "host": panel.get_annotation_host()}


func _call(rig: Dictionary) -> Dictionary:
	return await PanelTools.handle(
		rig["host"], "minerva_pcb_list_mounting_holes", {})


func _codes(reply: Dictionary) -> Array:
	var out: Array = []
	for row in (reply.get("placement_advisory", []) as Array):
		out.append(str((row as Dictionary).get("code", "")))
	return out


func _init() -> void:
	print("=== S8: mounting-hole read verb ===\n")
	await process_frame
	await _run_read_back()
	await _run_advisory()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── 1: the holes come back, at the numbers the author typed ─────────────────

func _run_read_back() -> void:
	print("-- 1: read-back --")
	var rig := _rig([
		{"position": Vector2(75.4, 12.5), "diameter": 3.2, "plated": true},
		{"position": Vector2(10.0, 90.0), "diameter": 2.2, "plated": false},
	])
	var reply: Dictionary = await _call(rig)
	check("the verb answers", bool(reply.get("success", false)), str(reply))
	check_eq("both holes come back", int(reply.get("hole_count", -1)), 2)

	var holes: Array = reply.get("mounting_holes", [])
	var first: Dictionary = holes[0]
	# THE QUANTIZATION. Vector2 is single-precision, so 75.4 is stored as
	# 75.4000015258789 — the float32 representation of the number the author
	# typed, not a measurement. Unsnapped it travels to an external router,
	# which computes against it and writes copper back a sub-micron off.
	check_eq("x comes back as the number that was authored", float(first["x_mm"]), 75.4)
	check_eq("…and y too", float(first["y_mm"]), 12.5)
	check_eq("diameter rides along", float(first["diameter_mm"]), 3.2)
	check_eq("plating rides along", bool(first["plated"]), true)
	check_eq("…and the second hole's plating is its own",
		bool((holes[1] as Dictionary)["plated"]), false)
	check_eq("each hole carries the index that identifies it",
		[int(first["index"]), int((holes[1] as Dictionary)["index"])], [0, 1])
	check("the note says what is NOT reported here",
		str(reply.get("note", "")).contains("via"), str(reply.get("note", "")))

	# A board with no mounting holes answers cleanly rather than refusing.
	var empty: Dictionary = await _call(_rig([]))
	check_eq("an empty board reports zero holes", int(empty.get("hole_count", -1)), 0)
	check("…and raises no advisory", not empty.has("placement_advisory"))


# ── 2: the advisory ─────────────────────────────────────────────────────────

func _run_advisory() -> void:
	print("\n-- 2: placement advisory --")

	# (a) THE RECTANGLE — the ordinary, correct pattern. Two holes share each
	#     x and each y, but no THREE are on one line. It must stay silent, or
	#     the advisory fires on almost every real board and gets ignored.
	var rect: Dictionary = await _call(_rig([
		{"position": Vector2(5.0, 5.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(45.0, 5.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(45.0, 60.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(5.0, 60.0), "diameter": 3.2, "plated": false},
	]))
	check("a rectangle of four holes raises nothing",
		not rect.has("placement_advisory"), str(rect.get("placement_advisory", [])))

	# (b) FOUR HOLES ON ONE ROW — the silent-rewrite shape.
	var row: Dictionary = await _call(_rig([
		{"position": Vector2(5.0, 5.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(15.0, 5.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(25.0, 5.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(35.0, 5.0), "diameter": 3.2, "plated": false},
	]))
	check("four holes on one row are reported", _codes(row).has("collinear_holes"))
	check("…and it is an ADVISORY, not a refusal",
		bool(row.get("success", false)), str(row))

	# (c) A DIAGONAL line. Grouping by shared x or y would miss this entirely,
	#     which is why the test is a perpendicular distance and not an axis
	#     comparison.
	var diagonal: Dictionary = await _call(_rig([
		{"position": Vector2(0.0, 0.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(10.0, 10.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(20.0, 20.0), "diameter": 3.2, "plated": false},
	]))
	check("three holes on a diagonal are reported too",
		_codes(diagonal).has("collinear_holes"))

	# (d) NEARLY collinear is not collinear — a real triangle stays silent.
	var triangle: Dictionary = await _call(_rig([
		{"position": Vector2(0.0, 0.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(10.0, 0.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(5.0, 4.0), "diameter": 3.2, "plated": false},
	]))
	check("a genuine triangle stays silent",
		not triangle.has("placement_advisory"),
		str(triangle.get("placement_advisory", [])))

	# (e) TWO HOLES AT ONE POINT — one of them drills nothing new.
	var stacked: Dictionary = await _call(_rig([
		{"position": Vector2(20.0, 20.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(20.0, 20.0), "diameter": 3.2, "plated": false},
	]))
	check("two holes at one point are reported",
		_codes(stacked).has("coincident_holes"))
	check("…naming WHICH two, by index",
		str(stacked.get("placement_advisory", [])).contains("[0, 1]"),
		str(stacked.get("placement_advisory", [])))
	# Two holes cannot be collinear — three is the smallest line.
	check("…and two holes alone raise no collinearity",
		not _codes(stacked).has("collinear_holes"))

	# (f) A stacked pair PLUS a third hole. The pair and its duplicate are
	#     trivially "on a line" with anything, so a naive triple scan reports
	#     two advisories for one fault — noise on the advisory whose whole
	#     value is that it does not cry wolf.
	# ORDER MATTERS, and the first version of this fixture got it wrong. The
	# scan walks triples (i<j<k), so a duplicate pair at indices 0,1 lands as
	# (a,b) — which the pre-fix code ALREADY skipped. The pair has to straddle
	# the third hole to reach the (a,c)/(b,c) positions that were unguarded,
	# or this cell passes on both sides of the fix and proves nothing.
	var stacked_plus: Dictionary = await _call(_rig([
		{"position": Vector2(20.0, 20.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(40.0, 5.0), "diameter": 3.2, "plated": false},
		{"position": Vector2(20.0, 20.0), "diameter": 3.2, "plated": false},
	]))
	check("a stacked pair beside a third hole reports the stack",
		_codes(stacked_plus).has("coincident_holes"))
	check("…and does NOT also report it as a line",
		not _codes(stacked_plus).has("collinear_holes"),
		str(stacked_plus.get("placement_advisory", [])))
