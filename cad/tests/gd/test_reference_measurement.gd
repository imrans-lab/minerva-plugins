extends SceneTree
## The two questions that are about the REFERENCES and not about the solid:
## how close do two mounted parts come to each other, and how tall are they
## over a patch of the world.
##
## WHAT THIS SUITE OWNS
##
## The pair DISTANCE is computed in the worker over a swept-sphere BVH, and the
## cad GD harness has no worker, so the exact arithmetic is pinned by pytest
## (worker/tests/test_reference_pairs.py). What the panel owns is everything
## either side of that number — which nodes get paired, the blob bytes that are
## shipped, the index-addressed request, and the re-framing of the answer into
## each reference's own coordinates — and the stand-in backend here derives its
## answer from the BYTES THE PANEL ACTUALLY WROTE, so a dropped pose or a
## mis-packed index changes the decoded geometry and the assertion fails.
##
## The z PROFILE is computed in the panel, so it is pinned here outright.
##
## THE FIXTURES, AND WHY THEY ARE SHAPED THIS WAY
##
## Pairs: two blocks 0.5 mm apart in x, each posed, their facing faces
## overlapping in y and z while no two corners line up. 0.5 is a number the
## fixture chose, not one the code computes.
##
## Profile: a stand-in for the KY-023 joystick — a 16 x 16 x 10 housing with a
## 2 x 2 stick standing to 42 — which is exactly the case that made this verb
## necessary. The node's own bounding box says the whole footprint is 42 tall;
## over the housing, away from the stick, the true height is 10. The suite
## asserts both numbers and that they DIFFER, which is the falsifier: an
## implementation reading the boxes reports 42 in both places. One region lies
## wholly INSIDE the housing's top face, so no triangle vertex is in it at all
## and only clipping can answer.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const PanelTools := preload("res://../../minerva-plugins/cad/ui/panel_tools.gd")
const GeometryChecks := preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")
const MeshGauge := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")

## The pair fixture, in millimetres. Two 6 x 8 x 4 blocks; the second is posed
## GAP_MM past the first in x and 3 mm along y, so their faces overlap and
## their corners do not.
const BLOCK := Vector3(6.0, 8.0, 4.0)
const GAP_MM := 0.5
const STICK_POSE := Vector3(40.0, -20.0, 2.0)
const DEVKIT_OFFSET := Vector3(6.0 + GAP_MM, 3.0, 0.0)
const STICK_NODE := "Stick/Body"
const DEVKIT_NODE := "Devkit/Body"

## The profile fixture: a joystick stand-in posed away from the origin, so
## world and local are different numbers everywhere. Housing and stick are ONE
## node, exactly as the KY-023 file has them — which is why its box cannot
## answer the question at all, whatever the boxes are read per node or per
## file.
const HOUSING := Vector3(16.0, 16.0, 10.0)
const CAP_BASE := Vector3(7.0, 7.0, 10.0)
const CAP_TOP := Vector3(9.0, 9.0, 42.0)
const PLATE_BASE := Vector3(0.0, 0.0, -1.7)
const PLATE_TOP := Vector3(16.0, 16.0, -0.1)
const JOYSTICK_POSE := Vector3(20.0, -100.0, 0.1)
const BODY_NODE := "Joystick/Body"
const PLATE_NODE := "Joystick/Plate"
## Heights the fixture is built from, once posed.
const HOUSING_TOP_MM := 10.1
const CAP_TOP_MM := 42.1
const PLATE_TOP_MM := 0.0
const PLATE_FLOOR_MM := -1.6

var _pass: int = 0
var _fail: int = 0
var _blob_dir: String = ""
## Every payload the module sent to the reference-pair channel, in order.
var _payloads: Array = []
## key -> the path it was uploaded from, the stand-in worker's whole memory.
var _known_blobs: Dictionary = {}


func _init() -> void:
	print("=== CAD Reference Measurement Test (part vs part, z profile) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_blob_dir = OS.get_user_data_dir().path_join("cad-reference-pairs-test")
	_clear_blob_dir()
	await _check_pairs()
	await _check_profile()
	_clear_blob_dir()


# ---------------------------------------------------------------------------
# Part against part
# ---------------------------------------------------------------------------

func _check_pairs() -> void:
	var panel := _StubPanel.new()
	panel.name = "StubPanel"
	panel.answer = _worker_answer
	panel.gauge = MeshGauge.new()
	panel.gauge.name = "MeshGauge"
	panel.add_child(panel.gauge)
	panel.records = [
		_record("stick", STICK_POSE, [[STICK_NODE, _box_mesh(Vector3.ZERO, BLOCK)]]),
		_record("devkit", STICK_POSE + DEVKIT_OFFSET,
			[[DEVKIT_NODE, _box_mesh(Vector3.ZERO, BLOCK)]]),
	]
	var checks: RefCounted = GeometryChecks.new()
	checks.attach(root)
	checks.set_blob_dir(_blob_dir)
	panel.checks = checks
	root.add_child(panel)
	await process_frame

	var reply: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "stick", "against": "devkit", "required_mm": 1.0})

	var request: Dictionary = _payloads.back() if not _payloads.is_empty() else {}
	check("request: the two nodes are sent once each and the pair names them "
			+ "by index",
			(request.get("targets", []) as Array).size() == 2
				and (request.get("pairs", []) as Array).size() == 1
				and str((request.get("pairs", [])[0] as Array)) == str([0, 1]),
			"payload = %s" % str(request))
	check("answer: two parts posed 0.5 mm apart measure 0.5 mm — from the "
			+ "bytes the panel shipped, not from the record",
			absf(float(_first(reply).get("min_mm", -1.0)) - GAP_MM) < 0.001,
			"min_mm = %s" % str(_first(reply).get("min_mm", null)))
	check("answer: the pair fails the 1.0 mm it was asked for, and so does "
			+ "the call",
			not bool(_first(reply).get("pass", true))
				and not bool(reply.get("pass", true)),
			"pair = %s" % str(_first(reply)))
	check("answer: both sides are named by reference AND node",
			str((_first(reply).get("a", {}) as Dictionary).get("node", ""))
				== STICK_NODE
			and str((_first(reply).get("b", {}) as Dictionary).get("reference", ""))
				== "devkit",
			"pair = %s" % str(_first(reply)))
	var point_b: Dictionary = _first(reply).get("point_b_mm", {})
	check("answer: the realising point comes back in the devkit's OWN frame "
			+ "as well as the world's",
			_as_vector(point_b.get("world", [])).distance_to(
				_as_vector(point_b.get("local", []))
					+ STICK_POSE + DEVKIT_OFFSET) < 0.001,
			"point_b = %s" % str(point_b))
	check("answer: the mode says this was reference against reference, and "
			+ "no tessellation tolerance is quoted for a measurement that "
			+ "tessellated nothing",
			str(reply.get("mode", "")) == "reference-vs-reference"
				and not reply.has("tessellation_tolerance_mm"),
			"reply keys = %s" % str(reply.keys()))

	var every: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "all-pairs", "required_mm": 0.1})
	check("all-pairs: every pair of mounted references is measured, and two "
			+ "nodes of ONE reference are never a pair",
			int(every.get("pairs_considered", 0)) == 1
				and absf(float(_first(every).get("min_mm", -1.0)) - GAP_MM) < 0.001,
			"reply = %s" % str(every))

	var meeting: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_interference",
		{"reference": "stick", "against": "devkit"})
	check("interference: two parts that miss each other by 0.5 mm list no "
			+ "pair at all and pass",
			(meeting.get("pairs", []) as Array).is_empty()
				and bool(meeting.get("pass", false))
				and bool(meeting.get("overlapping_only", false)),
			"reply = %s" % str(meeting))

	var unknown: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "stick", "against": "nosuch", "required_mm": 1.0})
	check("refusal: against= naming a reference that is not mounted is an "
			+ "error that lists the ones that are",
			not bool(unknown.get("success", true))
				and str(unknown.get("error", "")).contains("nosuch")
				and str(unknown.get("error", "")).contains("devkit"),
			"reply = %s" % str(unknown))
	var itself: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "stick", "against": "stick", "required_mm": 1.0})
	check("refusal: a reference measured against itself is refused rather "
			+ "than answered with zero",
			not bool(itself.get("success", true))
				and str(itself.get("error", "")).contains("same reference"),
			"reply = %s" % str(itself))

	await _check_pair_verdicts(panel)

	panel.queue_free()
	await process_frame


## THE VERDICT, not the number. Every distance below is the stand-in's box
## arithmetic over the bytes the panel wrote; what is pinned here is what the
## panel makes of it.
##
## ORACLES, each a number the fixture chose:
##   quantization — required_mm EQUAL to the 0.5 mm gap fails, because the
##     vertices travelled as float32 and bound_mm is min_mm less that grid;
##     required_mm a hair under it passes.
##   max_pairs — a third part 12 mm away left unmeasured (max_pairs=1) is a
##     bound the reply must grade: 12 clears 0.1 and the call passes, 12 does
##     not clear 20 and the call fails with the reason, whatever the one
##     measured pair did.
##   containment — a nut posed INSIDE the stick's box comes back contained:
##     an overlap, failing, and a declaration does not excuse it.
##   no depth — a lid resting exactly on the devkit is an overlap with no
##     penetration depth from the worker: declaring the contact excuses
##     NOTHING, and the row says why.
##   region — the 0.5 mm pair declared with a region round its witness point
##     is ungraded outside that region: pass withheld, advisory, with a reason.
func _check_pair_verdicts(panel: _StubPanel) -> void:
	var exact: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "stick", "against": "devkit", "required_mm": GAP_MM})
	var under: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "stick", "against": "devkit", "required_mm": GAP_MM - 0.001})
	var row := _first(exact)
	check("verdict: a required gap EQUAL to the measured one fails by the "
			+ "float32 quantization — bound_mm is min_mm less that grid and "
			+ "is what pass is graded on — and a hair under it passes",
			row.has("bound_mm")
				and float(row["bound_mm"]) < float(row.get("min_mm", 0.0))
				and float(exact.get("quantization_mm", 0.0)) > 0.0
				and not bool(row.get("pass", true))
				and not bool(exact.get("pass", true))
				and bool(_first(under).get("pass", false))
				and bool(under.get("pass", false)),
			"exact = %s, under = %s" % [str(row), str(_first(under))])

	panel.records.append(_record("oled", STICK_POSE + Vector3(6.0 + 12.0, 1.0, 0.0),
		[["Oled/Body", _box_mesh(Vector3.ZERO, BLOCK)]]))
	var clear: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "all-pairs", "required_mm": 0.1, "max_pairs": 1})
	var truncated: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "all-pairs", "required_mm": 20.0, "max_pairs": 1})
	check("verdict: candidates left unmeasured beyond max_pairs are graded "
			+ "on their box bound — 12 mm clears 0.1 and the call passes, "
			+ "and does not clear 20, which fails the call with the reason",
			int(clear.get("pairs_measured", 0)) == 1
				and bool(clear.get("truncated", false))
				and bool(clear.get("pass", false))
				and bool(truncated.get("truncated", false))
				and not bool(truncated.get("pass", true))
				and str(truncated.get("pass_reason", "")).contains("max_pairs"),
			"clear = %s, truncated = %s" % [str(clear.get("pass")),
				str(truncated.get("pass_reason"))])

	panel.records.append(_record("nut", STICK_POSE + Vector3(2.0, 2.0, 1.0),
		[["Nut/Body", _box_mesh(Vector3.ZERO, Vector3.ONE)]]))
	var buried: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "stick", "against": "nut", "required_mm": 0.1,
			"expected_contacts": [{"reference": "nut", "why": "it is captive"}]})
	var inside := _first(buried)
	check("verdict: a part inside another's box that the worker finds "
			+ "CONTAINED is an overlap that fails, and a declaration does "
			+ "not excuse it",
			str(inside.get("containment", "")) == "b_inside_a"
				and bool(inside.get("overlap", false))
				and not bool(inside.get("pass", true))
				and not bool(buried.get("pass", true))
				and int(buried.get("excluded_count", 1)) == 0,
			"pair = %s" % str(inside))

	panel.records.append(_record("lid", STICK_POSE + DEVKIT_OFFSET + Vector3(BLOCK.x, 0.0, 0.0),
		[["Lid/Body", _box_mesh(Vector3.ZERO, BLOCK)]]))
	var resting: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "devkit", "against": "lid", "required_mm": 0.0,
			"expected_contacts": [{"reference": "lid", "why": "the lid rests here"}]})
	var touch := _first(resting)
	var declared_rows: Array = resting.get("expected_contacts", []) as Array
	check("verdict: an overlap the worker measured NO depth for is never "
			+ "excused by a declaration — the row fails, says so, and the "
			+ "declaration is listed as not excluding it",
			bool(touch.get("overlap", false))
				and not touch.has("penetration_mm")
				and not bool(touch.get("pass", true))
				and not bool(touch.get("excused_uncertified", false))
				and str(touch.get("note", "")).contains("no measured depth")
				and not bool(resting.get("pass", true))
				and declared_rows.size() == 1
				and not bool((declared_rows[0] as Dictionary).get("excluded", true)),
			"pair = %s, rows = %s" % [str(touch), str(declared_rows)])

	var witness: Array = (_first(under).get("point_a_mm", {}) as Dictionary) \
		.get("world", []) as Array
	var at := _as_vector(witness)
	var regional: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_check_clearance",
		{"reference": "stick", "against": "devkit", "required_mm": 0.1,
			"expected_contacts": [{"reference": "stick", "required_mm": 0.0,
				"region_mm": {"min_mm": [at.x - 1.0, at.y - 1.0, at.z - 1.0],
					"max_mm": [at.x + 1.0, at.y + 1.0, at.z + 1.0]}}]})
	var scoped := _first(regional)
	check("verdict: a region declaration excuses the witness point inside "
			+ "it and leaves the pair UNGRADED outside — pass withheld, "
			+ "advisory, with the reason",
			bool(scoped.get("expected", false))
				and bool(scoped.get("ungraded_outside_region", false))
				and not bool(scoped.get("pass", true))
				and not bool(regional.get("pass", true))
				and bool(regional.get("advisory", false))
				and str(regional.get("pass_reason", "")).contains("region")
				and int(regional.get("excluded_count", 1)) == 0,
			"pair = %s, reply pass_reason = %s" % [str(scoped),
				str(regional.get("pass_reason", ""))])


## The stand-in worker: it decodes the blobs the module wrote and derives every
## distance from THOSE coordinates. The boxes are axis-aligned, so the gap
## between two decoded boxes IS the mesh-to-mesh minimum.
func _worker_answer(args: Dictionary) -> Dictionary:
	_payloads.append(args.duplicate(true))
	var targets: Array = args.get("targets", []) as Array
	var missing: Array = []
	var boxes: Array = []
	for entry in targets:
		var target: Dictionary = entry
		var key := str(target.get("key", ""))
		var path := str(target.get("path", ""))
		if not path.is_empty():
			_known_blobs[key] = path
		if _known_blobs.has(key):
			boxes.append(_decode_box(str(_known_blobs[key])))
		else:
			boxes.append(AABB())
			missing.append(key)
	if not missing.is_empty():
		return {"ok": true, "result": {"checked": false, "units": "mm",
			"pairs": [], "reason": "no cached geometry",
			"missing_keys": missing}}
	var required := float(args.get("required_mm", 0.0))
	var pairs: Array = []
	for entry in (args.get("pairs", []) as Array):
		var pair: Array = entry
		var first: AABB = boxes[int(pair[0])]
		var second: AABB = boxes[int(pair[1])]
		var min_mm: float = maxf(0.0, maxf(first.position.x - second.end.x,
			second.position.x - first.end.x))
		# A box wholly inside the other: the real worker probes parity and
		# reports containment beside a positive surface distance.
		var nested := first.encloses(second)
		if nested:
			min_mm = minf(second.position.x - first.position.x,
				first.end.x - second.end.x)
		var row := {
			"a": (targets[int(pair[0])] as Dictionary).duplicate(),
			"b": (targets[int(pair[1])] as Dictionary).duplicate(),
			"min_mm": min_mm,
			"pass": min_mm > 0.0 and min_mm >= required and not nested,
			"triangles": [12, 12],
		}
		if nested:
			row["containment"] = "b_inside_a"
			row["containment_note"] = "stand-in: b's box lies inside a's"
			row["overlap"] = true
			row["contact_points_mm"] = []
			row["contact_count"] = 0
			row["point_a_mm"] = [first.position.x, first.position.y, first.position.z]
			row["point_b_mm"] = [second.position.x, second.position.y,
				second.position.z]
		elif min_mm <= 0.0:
			row["overlap"] = true
			row["contact_points_mm"] = [[first.end.x, first.end.y, first.end.z]]
			row["contact_count"] = 1
		else:
			row["point_a_mm"] = [first.end.x, first.position.y, first.position.z]
			row["point_b_mm"] = [second.position.x, second.position.y,
				second.position.z]
		pairs.append(row)
	pairs.sort_custom(func(a, b): return float(a["min_mm"]) < float(b["min_mm"]))
	return {"ok": true, "result": {
		"checked": true,
		"units": "mm",
		"pass": pairs.all(func(p): return bool(p["pass"])),
		"required_mm": required,
		"pairs_measured": pairs.size(),
		"cache": {"hits": 0, "misses": pairs.size(), "entries": boxes.size()},
		"engine": "stand-in for python-fcl",
		"bound": "both sides are meshes; nothing was tessellated",
		"pairs": pairs,
	}}


# ---------------------------------------------------------------------------
# How tall is it over here?
# ---------------------------------------------------------------------------

func _check_profile() -> void:
	var panel := _StubPanel.new()
	panel.name = "ProfilePanel"
	panel.records = [_record("joystick", JOYSTICK_POSE, [
		[BODY_NODE, _box_mesh(Vector3.ZERO, HOUSING, CAP_BASE, CAP_TOP)],
		[PLATE_NODE, _box_mesh(PLATE_BASE, PLATE_TOP)],
	])]
	root.add_child(panel)

	# A patch of the housing well away from the stick, and one over the stick.
	var over_housing := {"min_mm": [21.0, -99.0], "max_mm": [25.0, -95.0]}
	var over_cap := {"min_mm": [27.0, -93.0], "max_mm": [29.0, -91.0]}
	var housing: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_reference_profile", {"region_mm": over_housing})
	var cap: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_reference_profile", {"region_mm": over_cap})

	check("profile: over the housing the geometry is 10.1 mm tall — the "
			+ "housing's own top, at its pose",
			absf(float(housing.get("max_z_mm", -1.0)) - HOUSING_TOP_MM) < 0.001,
			"max_z_mm = %s" % str(housing.get("max_z_mm", null)))
	check("profile: over the stick it is 42.1 mm tall",
			absf(float(cap.get("max_z_mm", -1.0)) - CAP_TOP_MM) < 0.001,
			"max_z_mm = %s" % str(cap.get("max_z_mm", null)))
	check("profile: THE FALSIFIER — the two footprints answer with different "
			+ "numbers, which reading the node boxes could not do",
			absf(float(housing.get("max_z_mm", 0.0))
				- float(cap.get("max_z_mm", 0.0))) > 30.0,
			"housing %s vs cap %s" % [str(housing.get("max_z_mm", null)),
				str(cap.get("max_z_mm", null))])
	check("profile: both heights come from the SAME node — one node holding "
			+ "the housing and the stick, whose box is 42 tall everywhere",
			str(housing.get("node", "")) == BODY_NODE
				and str(cap.get("node", "")) == BODY_NODE,
			"housing node %s, cap node %s" % [str(housing.get("node", "")),
				str(cap.get("node", ""))])
	check("profile: the low side of the same footprint is the underside of "
			+ "the node beneath it, so min spans every node in scope",
			absf(float(housing.get("min_z_mm", 0.0)) - PLATE_FLOOR_MM) < 0.001,
			"min_z_mm = %s" % str(housing.get("min_z_mm", null)))
	var at_max: Dictionary = housing.get("at_max_mm", {})
	check("profile: the point that realises the height comes back in the "
			+ "reference's own frame as well as the world's",
			absf(_as_vector(at_max.get("local", [])).z - HOUSING.z) < 0.001
				and absf(_as_vector(at_max.get("world", [])).z
					- HOUSING_TOP_MM) < 0.001,
			"at_max = %s" % str(at_max))

	# A footprint wholly inside the housing's top face: no triangle VERTEX is
	# in it, so only clipping can answer.
	var interior: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_reference_profile",
		{"region_mm": {"min_mm": [26.0, -96.0], "max_mm": [28.0, -94.0]}})
	check("profile: a footprint with no triangle vertex inside it is still "
			+ "measured — the triangles are clipped to the region, not sampled",
			absf(float(interior.get("max_z_mm", -1.0)) - HOUSING_TOP_MM) < 0.001
				and int(interior.get("triangles_inside", 0)) > 0,
			"reply = %s" % str(interior))

	var per_node: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_reference_profile",
		{"region_mm": {"min_mm": [20.0, -100.0], "max_mm": [36.0, -84.0]},
			"per_node": true})
	var rows: Array = per_node.get("nodes", []) as Array
	check("profile: per_node lists each contributing node with its own "
			+ "height, tallest first",
			rows.size() == 2
				and str((rows[0] as Dictionary).get("node", "")) == BODY_NODE
				and absf(float((rows[1] as Dictionary).get("max_z_mm", -1.0))
					- PLATE_TOP_MM) < 0.001,
			"nodes = %s" % str(rows))

	var empty: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_reference_profile",
		{"region_mm": {"min_mm": [500.0, 500.0], "max_mm": [510.0, 510.0]}})
	check("profile: a footprint with nothing under it answers found:false — "
			+ "an answer, not a failed measurement",
			bool(empty.get("success", false))
				and not bool(empty.get("found", true))
				and not empty.has("max_z_mm"),
			"reply = %s" % str(empty))
	var refused: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_reference_profile", {})
	check("profile: a call with no region_mm is a named error rather than a "
			+ "profile of everything",
			not bool(refused.get("success", true))
				and str(refused.get("error", "")).contains("region_mm"),
			"reply = %s" % str(refused))
	var unmounted: Dictionary = await PanelTools.handle(panel,
		"minerva_cad_reference_profile",
		{"region_mm": over_housing, "reference": "nosuch"})
	check("profile: reference= naming nothing mounted is an error listing "
			+ "what is",
			not bool(unmounted.get("success", true))
				and str(unmounted.get("error", "")).contains("joystick"),
			"reply = %s" % str(unmounted))

	panel.queue_free()


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

## One reference record in the shape the panel publishes: a pose and its
## nodes, each with its own mesh and an identity local transform.
func _record(name: String, origin: Vector3, nodes: Array) -> Dictionary:
	var parts: Array = []
	for entry in nodes:
		var node: Array = entry
		parts.append({
			"mesh": node[1],
			"transform": Transform3D.IDENTITY,
			"node_path": str(node[0]),
			"node": str(node[0]),
		})
	return {"name": name, "pose": Transform3D(Basis(), origin), "parts": parts}


## One or two axis-aligned boxes as an ArrayMesh, a surface each: a node of a
## foreign file is one mesh whatever shapes it holds, which is the whole point
## of the housing and the stick sharing a node here.
func _box_mesh(low: Vector3, high: Vector3, second_low: Vector3 = Vector3.ZERO,
		second_high: Vector3 = Vector3.ZERO) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_add_box(mesh, low, high)
	if second_high != second_low:
		_add_box(mesh, second_low, second_high)
	return mesh


func _add_box(mesh: ArrayMesh, low: Vector3, high: Vector3) -> void:
	var vertices := PackedVector3Array()
	for i in range(8):
		vertices.append(Vector3(
			high.x if (i & 4) else low.x,
			high.y if (i & 2) else low.y,
			high.z if (i & 1) else low.z))
	var indices := PackedInt32Array([
		0, 1, 3, 0, 3, 2, 4, 6, 7, 4, 7, 5,
		0, 4, 5, 0, 5, 1, 2, 3, 7, 2, 7, 6,
		0, 2, 6, 0, 6, 4, 1, 5, 7, 1, 7, 3,
	])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


## The world box a blob file describes, read back from its own bytes.
func _decode_box(path: String) -> AABB:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return AABB()
	var raw := file.get_buffer(int(file.get_length()))
	file.close()
	if raw.size() < 20 or raw.slice(0, 8).get_string_from_utf8() != "MCADMESH":
		return AABB()
	var vertex_count := int(raw.decode_u32(12))
	var body := raw.slice(20)
	var box := AABB()
	for i in range(vertex_count):
		var point := Vector3(body.decode_float(i * 12),
			body.decode_float(i * 12 + 4), body.decode_float(i * 12 + 8))
		box = AABB(point, Vector3.ZERO) if i == 0 else box.expand(point)
	return box


func _first(reply: Dictionary) -> Dictionary:
	var pairs: Array = reply.get("pairs", []) as Array
	return pairs[0] as Dictionary if not pairs.is_empty() else {}


func _as_vector(raw: Variant) -> Vector3:
	if raw is Array and (raw as Array).size() >= 3:
		var values: Array = raw
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3(1e9, 1e9, 1e9)


func _clear_blob_dir() -> void:
	if not DirAccess.dir_exists_absolute(_blob_dir):
		return
	for name in DirAccess.get_files_at(_blob_dir):
		DirAccess.remove_absolute(_blob_dir.path_join(name))


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass += 1
		print("  PASS  %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])


class _StubPanel extends Node:
	## What the reference measurement asks a panel for: its references, its
	## worker, and the geometry-checks module the verbs delegate to.
	var records: Array = []
	var checks: RefCounted = null
	var answer: Callable
	var gauge: Node = null

	func get_reference_state() -> Array:
		return records

	func get_document_state() -> Dictionary:
		return {"source": "", "path": "", "mesh": {}, "references": [],
			"last_eval": {}}

	func get_mesh_gauge() -> Node:
		return gauge

	func get_reference_digest() -> String:
		return "stub-digest"

	func check_reference_pairs(args: Dictionary = {}) -> Dictionary:
		if checks == null:
			return {"error": "no geometry checks module"}
		return await checks.check_reference_pairs(self, args)

	func call_backend(_channel: String, args: Dictionary,
			_timeout_ms: int = 30000) -> Dictionary:
		# Awaited by the caller, so it yields once like the real IPC round trip.
		await (Engine.get_main_loop() as SceneTree).process_frame
		return {"success": true, "result": answer.call(args)}
