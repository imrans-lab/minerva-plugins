extends SceneTree
## A BOARD OPENED AS A DOCUMENT PRINTS ITS DESIGNATORS WHERE THE FAB DOES.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_refdes_anchor_document_load.gd
##
## THE DEFECT. The designator anchor is a DERIVED key: never in the YAML, never
## in the saved board dict, dropped by the codec. A board that came in through
## the host's document path (open a .minpcb, restore a project) went straight
## into the model with no worker round-trip, so every designator drew at the
## constant default (0, -1.5) — while the Gerber printed the anchor derived from
## each part's body. And even the path that DID ask the worker got the wrong
## answer for a part that owns its geometry (a `pads` key): resolve measured the
## LIBRARY footprint's body, the emitters measured the board's own. Both halves
## showed on one board as a label drawn beside its pads and printed 12 mm away.
##
## WHAT THIS PINS. The model's adoption of a worker resolve reply — the function
## the document path now feeds — moves each designator to the anchor the REAL
## worker derives from the board's OWN geometry, and that anchor is the one the
## rule in worker/pcb_worker/refdes_anchor.py documents: the ink box of
## courtyard ∪ outline ∪ lands, designator centred on it and its baseline one
## clearance above. The expected numbers are computed BY HAND from the fixture's
## coordinates below, not by any code under test.
##
##   1. A part whose silk reaches far past its pads gets its label centred on
##      everything it draws — the fab's answer, not the library's.
##   2. A part drawn tight around its pads is the control: same rule, label
##      centred on the pads.
##   3. An AUTHORED placement field survives adoption: hidden stays hidden while
##      the unstated fields adopt the derived answer.
##
## FAILS AGAINST OLD: PCBData had no adopt_derived_anchors; and the worker's
## resolve answered (0.0, -1.48) for the wide part — the library 1206's body.

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbRefdesAnchor := preload("res://../../minerva-plugins/pcb/ui/model/pcb_refdes_anchor.gd")
const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"
const BOARD_ID := "board:00000000000000000000000000000000"
const FP := "Resistor_SMD:R_0805_2012Metric"
const EPS := 0.001

## Hand-computed from _component() below (worker/pcb_worker/refdes_anchor.py
## rule: ink box = each graphic's box grown by half its stroke, lands by their
## size; anchor x = box centre, y = box top - 0.25 clearance - 0.075 half
## stroke of the designator).
##   courtyard  x -1.68..1.68 ± 0.025, y -0.95..0.95 ± 0.025
##   lands      x ±(0.9125 + 0.5125), y ±0.7
##   wide silk  x 10..24 ± 0.075,     y ± 0.075
const TIGHT_ANCHOR := Vector2(0.0, -0.975 - 0.25 - 0.075)
const WIDE_ANCHOR := Vector2((-1.705 + 24.075) / 2.0, -0.975 - 0.25 - 0.075)

var _pass := 0
var _fail := 0
var _used_real_worker := false
var _worker_fell_back := false


func _init() -> void:
	print("=== Document-loaded designators adopt the fab's anchor ===\n")
	await _run_adoption_moves_each_label_to_its_own_body()
	await _run_authored_field_survives_adoption()
	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [
		_pass, _fail, str(_used_real_worker)])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


# ── the real worker ───────────────────────────────────────────────────────────

func _worker_call(tool_name: String, request: Dictionary, fallback: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if not FileAccess.file_exists(binary_path) or not FileAccess.file_exists(wrapper_path):
		_worker_fell_back = true
		_used_real_worker = false
		push_warning("[test_refdes_anchor_document_load] real pcb-plugin binary not built — canned fallback")
		return fallback
	var req_uri := "user://refdes_anchor_document_load_request.json"
	var f := FileAccess.open(req_uri, FileAccess.WRITE)
	if f == null:
		_worker_fell_back = true
		_used_real_worker = false
		printerr("[test_refdes_anchor_document_load] REAL-WORKER INVOCATION FAILED: cannot write %s" % req_uri)
		return fallback
	f.store_string(JSON.stringify(request))
	f.close()
	var req_abs := ProjectSettings.globalize_path(req_uri)
	var output: Array = []
	var exit_code := OS.execute("python3",
		[wrapper_path, binary_path, req_abs, tool_name], output, true)
	DirAccess.remove_absolute(req_abs)
	var parsed: Variant = null
	if not output.is_empty():
		parsed = JSON.parse_string(str(output[0]))
	if exit_code == 0 and parsed is Dictionary and (parsed as Dictionary).has("ok"):
		if not _worker_fell_back:
			_used_real_worker = true
		return parsed
	_worker_fell_back = true
	_used_real_worker = false
	printerr("[test_refdes_anchor_document_load] REAL-WORKER %s FAILED (exit=%d): %s" % [
		tool_name, exit_code, str(output[0]).left(500) if not output.is_empty() else "no output"])
	printerr("[test_refdes_anchor_document_load] canned fallback engaged — real_worker_used will report false and the gd runner fails this suite")
	return fallback


## The document path's enrichment, as the panel drives it: the WHOLE live
## board through pcb.deserialize (a part that owns its geometry must reach the
## worker with the graphics it owns), the reply's board handed to the model.
## Returns the resolved board dict (empty on a failed call).
func _resolved_board(data) -> Dictionary:
	var reply := _worker_call("pcb.deserialize", {"board": data.to_board_dict()}, {"ok": false})
	if not bool(reply.get("ok", false)):
		return {}
	var result = reply.get("result", reply)
	if result is Dictionary and (result as Dictionary).get("board") is Dictionary:
		return (result as Dictionary)["board"]
	return {}


# ── fixture ───────────────────────────────────────────────────────────────────

func _board(components: Array) -> Dictionary:
	return {
		"version": 2, "id": BOARD_ID, "name": "document-load-anchors",
		"width_mm": 60.0, "height_mm": 40.0,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
			"via_diameter_mm": 0.8, "via_drill_mm": 0.4},
		"components": components, "nets": [], "traces": [], "vias": [], "zones": [],
	}


## A FULL-geometry 0805 (its `pads` key makes the board the sole authority;
## the library is never consulted for its body). `wide` adds a silk line that
## reaches 24 mm east of the part — the shape of board art parked on a part.
func _component(ref: String, at: Vector2, wide: bool, extra: Dictionary = {}) -> Dictionary:
	var pads: Array = []
	for number_x in [["1", -0.9125], ["2", 0.9125]]:
		pads.append({"number": number_x[0], "type": "smd", "shape": "roundrect",
			"position": {"x": number_x[1], "y": 0.0},
			"size": {"width": 1.025, "height": 1.4},
			"layers": ["F.Cu", "F.Mask", "F.Paste"], "drill": {"x": 0.0, "y": 0.0}})
	var graphics: Array = [
		{"kind": "poly", "layer": "F.CrtYd", "width": 0.05, "points": [
			{"x": -1.68, "y": -0.95}, {"x": 1.68, "y": -0.95},
			{"x": 1.68, "y": 0.95}, {"x": -1.68, "y": 0.95}]},
	]
	if wide:
		graphics.append({"kind": "line", "layer": "F.SilkS", "width": 0.15,
			"start": {"x": 10.0, "y": 0.0}, "end": {"x": 24.0, "y": 0.0}})
	var comp := {
		"ref": ref, "footprint": FP, "value": "1k",
		"x_mm": at.x, "y_mm": at.y, "rotation_deg": 0.0, "layer": "top",
		"pins": [{"number": "1", "x_mm": -0.9125, "y_mm": 0.0},
			{"number": "2", "x_mm": 0.9125, "y_mm": 0.0}],
		"pads": pads, "graphics": graphics,
	}
	comp.merge(extra)
	return comp


func _anchor_xy(comp) -> Vector2:
	var a: Dictionary = PcbRefdesAnchor.read_anchor(comp)
	return Vector2(float(a["x_mm"]), float(a["y_mm"]))


func _near(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < EPS


# ── sections ──────────────────────────────────────────────────────────────────

func _run_adoption_moves_each_label_to_its_own_body() -> void:
	print("-- 1/2. a document-loaded board adopts the anchor the worker derives from each part's OWN body --")
	var data = PCBData.new()
	data.from_board_dict(_board([
		_component("R1", Vector2(10.0, 10.0), false),
		_component("R2", Vector2(10.0, 25.0), true),
	]))
	var r1 = data.get_component("R1")
	var r2 = data.get_component("R2")
	check("the document path alone leaves both labels at the constant default",
		_near(_anchor_xy(r1), Vector2(0.0, -1.5)) and _near(_anchor_xy(r2), Vector2(0.0, -1.5)))

	var resolved := _resolved_board(data)
	check("the real worker answered the document's board", not resolved.is_empty())
	var moved: int = data.adopt_derived_anchors(resolved)
	check("both designators moved (%d)" % moved, moved == 2)
	check("the tight part's label is centred over its own lands, one clearance above its courtyard ink — got %s"
			% str(_anchor_xy(r1)),
		_near(_anchor_xy(r1), TIGHT_ANCHOR))
	check("the wide part's label is centred over EVERYTHING it draws — the fab's answer, %s — got %s"
			% [str(WIDE_ANCHOR), str(_anchor_xy(r2))],
		_near(_anchor_xy(r2), WIDE_ANCHOR))
	var bounds: Dictionary = PcbRefdesAnchor.board_bounds(r2)
	check("…so on the board its ink is centred on the derived x, not on the pads (min_x %.2f, max_x %.2f)"
			% [float(bounds.get("min_x_mm", 0.0)), float(bounds.get("max_x_mm", 0.0))],
		float(bounds.get("min_x_mm", 0.0)) < 10.0 + WIDE_ANCHOR.x
			and float(bounds.get("max_x_mm", 0.0)) > 10.0 + WIDE_ANCHOR.x)
	check("adopting the same reply again moves nothing", data.adopt_derived_anchors(resolved) == 0)
	check("the board's own lands were not touched by adoption",
		r2.pads.size() == 2 and data.to_board_dict()["components"][1].has("pads"))


func _run_authored_field_survives_adoption() -> void:
	print("-- 3. an authored placement field beats the derived answer, field by field --")
	var data = PCBData.new()
	data.from_board_dict(_board([
		_component("R3", Vector2(10.0, 10.0), true, {"refdes_placement": {"hidden": true}}),
	]))
	var r3 = data.get_component("R3")
	var resolved := _resolved_board(data)
	check("the real worker answered", not resolved.is_empty())
	data.adopt_derived_anchors(resolved)
	var anchor: Dictionary = PcbRefdesAnchor.read_anchor(r3)
	check("hidden stays authored-true after adoption", bool(anchor["hidden"]))
	check("…while the unstated x adopts the derived centre (%s)" % str(anchor["x_mm"]),
		absf(float(anchor["x_mm"]) - WIDE_ANCHOR.x) < EPS)
	check("a hidden designator strokes nothing", r3.refdes_graphics.is_empty())
