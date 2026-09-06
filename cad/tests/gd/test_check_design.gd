extends SceneTree
## minerva_cad_check_design: three checks, one verdict, only the failing rows.
##
## The acceptance loop asks "is this design still wrong, and where" after every
## edit. It used to be three verbs and three reply shapes, and the reader had
## to merge them. This verb runs the same three checks and folds them.
##
## ORACLE. A design with exactly three things wrong in it — one real crash, one
## 0.9 mm pinch under a 1 mm requirement, and one nudged post whose screw will
## not go in — must come back with exactly those three rows and verdict fail,
## and the same design with those contacts declared as intended and the post
## straightened must come back pass. Nothing here measures geometry: the three
## checks are answered by a stand-in panel with canned reports, because what is
## under test is the FOLD — which rows travel, what the verdict is, and what
## the counts say about the rows that did not.
##
## The stand-in is the smallest rig that drives the real verb layer: the three
## check methods a CADPanel answers, plus the gauge and feature modules the
## fastener leg's hole census reaches for (it finds no holes, which is enough —
## the pairing is the panel's, not the verb's).
##
## Run:
##   godot --headless --path <minerva>/src --script \
##     res://../../minerva-plugins/cad/tests/gd/test_check_design.gd

const PanelTools := preload("res://../../minerva-plugins/cad/ui/panel_tools.gd")

## The gap this design has to keep, in millimetres, and the pinch that fails it.
const REQUIRED_MM := 1.0
const PINCH_MM := 0.9
## Crossing points the one interfering pair was found at. More than the verb
## keeps, so the reply has something to count as hidden.
const CROSSINGS := 5

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== CAD check_design (three checks, one verdict) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s — %s" % [label, detail])


func _run() -> void:
	await _check_the_three_faults_are_the_three_rows()
	await _check_a_clean_design_with_declared_contacts_passes()
	await _check_an_undecidable_node_is_not_a_clean_answer()
	await _check_a_busy_collider_is_retried_not_reported()
	await _check_a_running_clearance_comes_back_as_a_ticket()


# ---------------------------------------------------------------------------
# The oracle
# ---------------------------------------------------------------------------

func _check_the_three_faults_are_the_three_rows() -> void:
	var panel := _panel()
	panel.interference = _interference_report([_crash()])
	panel.clearance = _clearance_report([_pinch(), _gap(2.5), _gap(3.0), _gap(4.0)])
	panel.fasteners = _fastener_report([_nudged_post(), _good_screw()])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "screw": {"dia_mm": 3.0, "length_mm": 8.0}})

	check("one crash, one pinch and one nudged post read as verdict fail",
			str(reply.get("verdict", "")) == "fail"
				and int(reply.get("failing_rows", 0)) == 3,
			"verdict = %s, failing_rows = %s" % [str(reply.get("verdict", "")),
				str(reply.get("failing_rows", ""))])

	var crashes: Array = reply["interference"]
	check("the crash travels as the one interference row, naming the node",
			crashes.size() == 1
				and str((crashes[0] as Dictionary)["node"]) == "board/Body",
			"interference = %s" % str(crashes))

	var pinches: Array = reply["clearance"]
	check("the 0.9 mm pinch is the one clearance row — the three gaps that "
			+ "cleared did not travel",
			pinches.size() == 1
				and absf(float((pinches[0] as Dictionary)["min_mm"]) - PINCH_MM) < 1e-6,
			"clearance = %s" % str(pinches))

	var screws: Array = reply["fasteners"]
	check("the nudged post is the one fastener row — the screw that goes in "
			+ "did not travel",
			screws.size() == 1
				and str((screws[0] as Dictionary)["node"]) == "board/PostHole",
			"fasteners = %s" % str(screws))

	var hidden: Dictionary = reply["hidden_counts"]
	check("what it did not show is COUNTED: every clearance pair, every screw "
			+ "and the crossing points behind the row",
			int(hidden.get("clearance_pairs_total", 0)) == 4
				and int(hidden.get("fastener_screws", 0)) == 2
				and int(hidden.get("interference_points", 0)) == CROSSINGS
				and int(hidden.get("interference_points_hidden", 0)) > 0,
			"hidden_counts = %s" % str(hidden))

	var checks: Dictionary = reply["checks"]
	check("and the reply says all three checks ran",
			str(checks.get("interference", "")) == "ran"
				and str(checks.get("clearance", "")) == "ran"
				and str(checks.get("fasteners", "")) == "ran",
			"checks = %s" % str(checks))
	panel.free()


func _check_a_clean_design_with_declared_contacts_passes() -> void:
	var panel := _panel()
	# The board RESTS on the bosses: the contact is the design working, and
	# the checks excuse it because it was declared.
	var interference := _interference_report([])
	interference["expected_contacts"] = [{
		"reference": "board", "node": "board/Body", "measured": "overlap",
		"measured_mm": 0.002, "excluded": true,
	}]
	interference["expected_contacts_unmatched"] = []
	panel.interference = interference
	var seated := _gap(0.0)
	seated["touching"] = true
	seated["pass"] = true
	seated["required_mm"] = 0.0
	panel.clearance = _clearance_report([seated, _gap(2.0)])
	panel.fasteners = _fastener_report([_good_screw()])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design", {
				"required_mm": REQUIRED_MM,
				"screw": {"dia_mm": 3.0, "length_mm": 8.0},
				"expected_contacts": [{"reference": "board", "node": "board/Body",
					"why": "the board seats on the bosses"}],
			})

	check("a clean design whose intended contacts are declared reads pass, "
			+ "with no rows at all",
			str(reply.get("verdict", "")) == "pass"
				and (reply["interference"] as Array).is_empty()
				and (reply["clearance"] as Array).is_empty()
				and (reply["fasteners"] as Array).is_empty(),
			"reply = %s" % str(reply))

	# The same design, asked about without a screw.
	panel.fasteners = _fastener_report([])
	var no_screw: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design", {"required_mm": REQUIRED_MM})
	check("leaving `screw` out skips the fastener leg without making the "
			+ "verdict advisory — it is a scope, not something undecided",
			str(no_screw.get("verdict", "")) == "pass"
				and str((no_screw["checks"] as Dictionary).get("fasteners", ""))
					.begins_with("not asked for"),
			"verdict = %s, checks = %s" % [str(no_screw.get("verdict", "")),
				str(no_screw.get("checks", {}))])
	panel.free()


func _check_an_undecidable_node_is_not_a_clean_answer() -> void:
	var panel := _panel()
	var interference := _interference_report([])
	interference["undecidable"] = [{"reference": "board", "node": "board/Shield",
		"reason": "every probe landed in a cavity"}]
	panel.interference = interference
	panel.clearance = _clearance_report([_gap(2.0)])
	panel.fasteners = _fastener_report([_good_screw()])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "screw": {"dia_mm": 3.0, "length_mm": 8.0}})
	check("a node whose containment could not be decided makes the verdict "
			+ "advisory, not pass, and the note says why",
			str(reply.get("verdict", "")) == "advisory"
				and int(reply.get("failing_rows", 0)) == 0
				and str(reply.get("notes", [])).contains("containment"),
			"verdict = %s, notes = %s" % [str(reply.get("verdict", "")),
				str(reply.get("notes", []))])
	panel.free()


func _check_a_busy_collider_is_retried_not_reported() -> void:
	var panel := _panel()
	# Interference and fasteners share the panel's one solid collider. The
	# panel's OWN per-evaluation check holds it for the first two asks.
	panel.busy_replies = 2
	panel.interference = _interference_report([])
	panel.clearance = _clearance_report([_gap(2.0)])
	panel.fasteners = _fastener_report([_good_screw()])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "screw": {"dia_mm": 3.0, "length_mm": 8.0}})
	check("a leg refused with `busy` is asked again until it answers — the "
			+ "verb never reports the collider refusal as a result",
			panel.interference_calls == 3
				and str((reply["checks"] as Dictionary).get("interference", "")) == "ran"
				and str(reply.get("verdict", "")) == "pass",
			"asked %d times, checks = %s, verdict = %s" % [panel.interference_calls,
				str(reply.get("checks", {})), str(reply.get("verdict", ""))])
	panel.free()


func _check_a_running_clearance_comes_back_as_a_ticket() -> void:
	var panel := _panel()
	panel.interference = _interference_report([_crash()])
	panel.clearance = {"checked": false, "status": "running",
		"ticket": "clearance-4", "pairs": [], "elapsed_ms": 2000,
		"reason": "the measurement is still running in the worker"}
	panel.fasteners = _fastener_report([_good_screw()])

	var reply: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_design",
			{"required_mm": REQUIRED_MM, "screw": {"dia_mm": 3.0, "length_mm": 8.0}})
	check("a clearance that outruns the window comes back as ONE ticket, with "
			+ "the interference and fastener rows already in hand",
			str(reply.get("status", "")) == "running"
				and str(reply.get("ticket", "")) == "clearance-4"
				and str((reply.get("tickets", {}) as Dictionary)
					.get("clearance", "")) == "clearance-4"
				and (reply["interference"] as Array).size() == 1,
			"reply = %s" % str(reply))
	check("and its verdict is still fail — a leg nobody could finish never "
			+ "turns a crash into a clean answer",
			str(reply.get("verdict", "")) == "fail"
				and str((reply["checks"] as Dictionary).get("clearance", ""))
					.contains("running"),
			"verdict = %s, checks = %s" % [str(reply.get("verdict", "")),
				str(reply.get("checks", {}))])
	panel.free()


# ---------------------------------------------------------------------------
# The reports the three checks would have measured
# ---------------------------------------------------------------------------

func _interference_report(pairs: Array) -> Dictionary:
	return {
		"checked": true, "units": "mm",
		"pass": pairs.is_empty(),
		"count": pairs.size(),
		"point_count": pairs.size() * CROSSINGS,
		"pairs": pairs,
		"undecidable": [],
		"records_digest": "board|v1",
	}


func _crash() -> Dictionary:
	var points: Array = []
	for index in range(CROSSINGS):
		var at: Array = [1.0 + float(index) * 0.1, 2.0, 3.0]
		points.append({"world": at, "local": at})
	return {
		"reference": "board", "node": "board/Body",
		"points_mm": points, "point_count": CROSSINGS,
		"penetration_mm": 0.42,
	}


func _clearance_report(pairs: Array) -> Dictionary:
	var clean := true
	for entry in pairs:
		if not bool((entry as Dictionary).get("pass", false)):
			clean = false
	return {
		"checked": true, "units": "mm", "status": "complete",
		"pass": clean,
		"required_mm": REQUIRED_MM,
		"quantization_mm": 0.0,
		"tolerance_bounded": true,
		"tessellation_tolerance_mm": 0.01,
		"pairs": pairs,
	}


func _pinch() -> Dictionary:
	var pair := _gap(PINCH_MM)
	pair["pass"] = false
	return pair


func _gap(distance_mm: float) -> Dictionary:
	return {
		"reference": "board", "node": "board/Body_%s" % distance_mm,
		"min_mm": distance_mm, "bound_mm": distance_mm,
		"pass": distance_mm >= REQUIRED_MM,
		"solid_point_mm": {"world": [0.0, 0.0, 0.0]},
		"reference_point_mm": {"world": [0.0, 0.0, distance_mm],
			"local": [0.0, 0.0, distance_mm]},
	}


func _fastener_report(screws: Array) -> Dictionary:
	var failed := 0
	for entry in screws:
		if not bool((entry as Dictionary).get("pass", false)):
			failed += 1
	return {
		"checked": true, "units": "mm",
		"count": screws.size(),
		"failed": failed,
		"pass": failed == 0 and not screws.is_empty(),
		"screws": screws,
		"unpaired": {},
	}


func _nudged_post() -> Dictionary:
	return {
		"reference": "board", "node": "board/PostHole",
		"axis_source": "b_rep",
		"coaxiality": {"offset_start_mm": 0.6, "allowed_mm": 0.2, "pass": false},
		"path_clear": true, "engagement_mm": 6.0, "engagement_ok": true,
		"pass": false,
		"why": "the post is 0.6 mm off the hole's axis, and the clearance "
			+ "hole allows 0.2 mm",
	}


func _good_screw() -> Dictionary:
	return {
		"reference": "board", "node": "board/CornerHole",
		"axis_source": "b_rep",
		"coaxiality": {"offset_start_mm": 0.02, "allowed_mm": 0.2, "pass": true},
		"path_clear": true, "engagement_mm": 6.0, "engagement_ok": true,
		"pass": true, "why": "",
	}


# ---------------------------------------------------------------------------
# The rig
# ---------------------------------------------------------------------------

func _panel() -> _DesignStandIn:
	var panel := _DesignStandIn.new()
	root.add_child(panel)
	return panel


## A panel that answers the three check methods with canned reports, and
## nothing else. The fastener verb runs a hole census on the way in, so the
## gauge and the feature module are here too — they find nothing, which is all
## this fold needs from them.
class _DesignStandIn extends Node:
	var interference: Dictionary = {}
	var clearance: Dictionary = {}
	var fasteners: Dictionary = {}
	## Refuse the interference check this many times before answering, the way
	## the panel's own per-evaluation check does while it holds the collider.
	var busy_replies: int = 0
	var interference_calls: int = 0

	var _gauge: _GaugeStandIn = null
	var _features: _FeatureStandIn = null

	func _init() -> void:
		_gauge = _GaugeStandIn.new()
		add_child(_gauge)
		_features = _FeatureStandIn.new()

	func get_reference_digest() -> String:
		return "design|v1"

	func get_reference_state() -> Array:
		return [{"name": "board", "parts": [], "pose": Transform3D.IDENTITY,
			"world_aabb": AABB()}]

	func get_mesh_gauge() -> Node:
		return _gauge

	func get_mesh_features() -> RefCounted:
		return _features

	func ensure_gauge_built() -> void:
		pass

	func check_interference(_args: Dictionary) -> Dictionary:
		interference_calls += 1
		if busy_replies > 0:
			busy_replies -= 1
			return {"checked": false, "busy": true, "holder_ticket": 7,
				"holder_age_ms": 30, "count": 0, "pairs": [],
				"reason": "the evaluation's own check holds the geometry"}
		return interference.duplicate(true)

	func check_clearance(_args: Dictionary) -> Dictionary:
		return clearance.duplicate(true)

	func check_fasteners(_args: Dictionary) -> Dictionary:
		return fasteners.duplicate(true)


## Enough gauge for the hole census to run and report nothing.
class _GaugeStandIn extends Node:
	func mask_for(_reference: String) -> int:
		return 1

	func get_shape_count() -> int:
		return 0

	func submit(_kind: String, _args: Dictionary) -> Dictionary:
		return {"seeds": [], "holes": []}


## Enough segmentation for the hole census to propose nothing.
class _FeatureStandIn extends RefCounted:
	func get_analysis_count() -> int:
		return 0

	func features_for_async(_key: String, _parts: Array, _angle: float,
			_tree: SceneTree) -> Dictionary:
		return {"candidates": [], "elapsed_ms": 0}
