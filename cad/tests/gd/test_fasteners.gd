extends SceneTree
## Will the screws go in? — the panel half of minerva_cad_check_fasteners.
##
## WHAT THIS SUITE OWNS, AND WHAT IT DOES NOT
##
## Two things sit either side of this module and are pinned elsewhere:
##
##   the B-Rep read — the exact axis, radius and axial extent of every
##   cylindrical surface — runs in the worker and is pinned by
##   worker/tests/test_features.py, because the cad GD harness has no worker
##   (EXPECTED_SUITES refuses `real-worker` until a worker probe exists). Here
##   a stand-in backend answers with axes the SUITE constructed from the
##   fixture's own literals.
##
##   the reference holes come from minerva_cad_find_holes, whose fit-then-gauge
##   path is pinned by test_mesh_measurement.gd and test_measurement_verbs.gd.
##   Here they are built from the fixture's literals in the shape that verb
##   reports, because this suite is about what the module does WITH a measured
##   hole, not about measuring one.
##
## Everything between those two is real and is what this suite drives: the
## one-to-one pairing, the ISO 1101 zone and its ISO 273 allowance, the ray fan
## through REAL colliders in the gauge's world and the solid's own, the
## engagement arithmetic, and the head seat. The rays are cast against
## geometry built in-test with CSG and baked — no mesh binary in the repository.
##
## THE FIXTURE, AND WHY EACH SCREW IS THERE
##
## A 60 x 60 x 1.6 board, posed away from the origin, with four 3.4 mm through
## holes, and a small blocker part standing over the third one. Under it, five
## bosses, each with a 2.4 mm pilot bore 8.2 mm deep:
##
##   A  coaxial with hole 1                     -> passes, on every count
##   B  0.5 mm off and tilted 2 degrees         -> fails coaxiality, and only that
##   C  coaxial with hole 3, blocker overhead   -> fails the path, naming the node
##   D  parked 24 mm from every hole            -> unpaired, and said so
##   E  coaxial with hole 4 but standing 1.2 mm clear of the board, with a RIB
##      of the shell bridging that gap across part of its bore and 1.4 mm off
##      the axis                                -> fails the path on the SOLID,
##      which the axis ray alone could never see
##
## The screw is an M3 x 8 with a 6 mm head. ISO 273 medium gives an M3 a 3.4 mm
## clearance hole, so its whole radial allowance is 0.2 mm — which is why B's
## half-millimetre is a failure and not a rounding error, and why the numbers
## below are worth a hundredth of a millimetre.
##
## Every expected number in this file is derived from the fixture's own
## literals in the comment beside it, not from a previous run of the code.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const MeshGauge := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")
const GeometryChecks := preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")
const FastenerChecks := preload("res://../../minerva-plugins/cad/ui/scripts/fastener_checks.gd")

# --- the board ---------------------------------------------------------------
const BOARD_SIZE := Vector3(60.0, 60.0, 1.6)
const BOARD_HALF_THICKNESS := 0.8
const HOLE_DIA := 3.4
const HOLE_RADIUS := 1.7
## The four holes in the board's own frame (z = 0 is mid-thickness).
const HOLE_XY := [Vector2(-20.0, 0.0), Vector2(0.0, 0.0), Vector2(20.0, 0.0),
	Vector2(0.0, -20.0)]
## The blocker: a 4 x 4 x 3 box standing over hole 3, its underside 2.2 mm
## clear of the board's top face, so it is unmistakably in the screw's way and
## unmistakably not touching the board.
const BLOCKER_SIZE := Vector3(4.0, 4.0, 3.0)
const BLOCKER_BOTTOM_Z := 3.0
const BLOCKER_TOP_Z := 6.0

const POSE_ORIGIN := Vector3(100.0, 200.0, 300.0)
const BOARD_REFERENCE := "board"
const BOARD_NODE := "Assembly/Board"
const BLOCKER_NODE := "Assembly/Blocker"

# --- the bosses --------------------------------------------------------------
## Boss OD about 2.5 x the screw diameter, the moulding guides' rule.
const BOSS_OUTER_R := 4.0
const BORE_R := 1.2
## The bore runs from just under the board down into the boss.
const BORE_TOP_Z := -0.8
const BORE_BOTTOM_Z := -9.0
const BORE_LENGTH := 8.2
const BOSS_BOTTOM_Z := -10.8
## Boss B's error, as designed: half a millimetre sideways at the seat plane
## and two degrees of tilt.
const B_OFFSET_MM := 0.5
const B_TILT_DEG := 2.0
## Boss D is parked here, far from every hole, so it can find no partner.
const D_XY := Vector2(-20.0, 24.0)
## Boss E stands 1.2 mm clear of the board so a RIB of the shell can bridge the
## gap across its bore, off-centre: the axis ray misses the rib entirely and
## only the shank ring can see it. Its bore therefore starts 1.2 mm deeper,
## which also puts its engagement short — E is a deliberate double failure and
## the suite asserts the PATH, which is the one `why` reports first.
const E_GAP_MM := 1.2
const E_BORE_TOP_Z := BORE_TOP_Z - E_GAP_MM
const E_BORE_BOTTOM_Z := BORE_BOTTOM_Z - E_GAP_MM
const E_BOSS_BOTTOM_Z := BOSS_BOTTOM_Z - E_GAP_MM
## The rib: 1.5 wide in x, centred 1.4 mm off the bore axis, so it covers
## x in [0.65, 2.15] — across part of the 2.4 mm bore and clear of its centre.
const RIB_SIZE := Vector3(1.5, 8.0, E_GAP_MM)
const RIB_OFFSET_X := 1.4

# --- the screw ---------------------------------------------------------------
const SCREW_DIA := 3.0
const SCREW_LENGTH := 8.0
const HEAD_DIA := 6.0
## ISO 273:1979 medium, M3 -> 3.4 mm, so (3.4 - 3.0) / 2.
const M3_ALLOWED_RADIAL_MM := 0.2
## Engagement, from the fixture: the screw runs from the seat (0.8 mm above the
## hole centre, i.e. axial -0.8) to -0.8 + 8.0 = 7.2; the bore runs from 0.8 to
## 9.0. The overlap is 7.2 - 0.8.
const EXPECTED_ENGAGEMENT_MM := 6.4
## 2.0 x 3.0 mm, the thermoplastic-boss default.
const EXPECTED_REQUIRED_MM := 6.0

## Boss B's radial offset at the two ends of the engaged length, from the
## fixture: 0.5 mm at the seat (axial -0.8), drifting by tan(2 deg) per
## millimetre of travel. At axial 0.8 that is 0.5 - 1.6 * tan(2), at 7.2 it is
## 0.5 - 8.0 * tan(2).
const B_OFFSET_AT_ENTRY_MM := 0.44414
const B_OFFSET_AT_EXIT_MM := 0.22063
const NUMERIC_TOLERANCE_MM := 0.005
const ANGLE_TOLERANCE_DEG := 0.02

## The gate the tessellation fallback is licensed by.
const AGREEMENT_CENTRE_MM := 0.01
const AGREEMENT_ANGLE_DEG := 0.05

var _pass: int = 0
var _fail: int = 0
var _pose: Transform3D = Transform3D.IDENTITY
var _records: Array = []
## The B-Rep answer the stand-in backend gives, built from the fixture.
var _bores: Array = []


func _init() -> void:
	print("=== CAD Fastener Test (will the screws go in?) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_pose = Transform3D(Basis.IDENTITY, POSE_ORIGIN)

	var board: ArrayMesh = await _bake_board()
	var blocker: ArrayMesh = await _bake_blocker()
	check("fixture: the board and the blocker baked to meshes",
			board != null and board.get_surface_count() > 0
				and blocker != null and blocker.get_surface_count() > 0,
			"bake_static_mesh returned nothing")

	var gauge := MeshGauge.new()
	gauge.name = "MeshGauge"
	root.add_child(gauge)
	var checks: RefCounted = GeometryChecks.new()
	checks.attach(root)
	await process_frame

	var built: int = gauge.build([
		{"mesh": board, "transform": _pose, "node": BOARD_NODE,
			"reference": BOARD_REFERENCE},
		{"mesh": blocker, "transform": _pose, "node": BLOCKER_NODE,
			"reference": BOARD_REFERENCE},
	], "fastener-fixture|v1")
	check("fixture: the board and the blocker became two reference colliders",
			built == 2, "built %d colliders" % built)

	_records = [{
		"name": BOARD_REFERENCE,
		"pose": _pose,
		"world_aabb": _reference_world_box(),
		"parts": [
			{"mesh": board, "transform": Transform3D.IDENTITY,
				"node_path": BOARD_NODE, "node": BOARD_NODE},
			{"mesh": blocker, "transform": Transform3D.IDENTITY,
				"node_path": BLOCKER_NODE, "node": BLOCKER_NODE},
		],
	}]
	_bores = _brep_bores()

	var shell: Dictionary = await _shell_mesh()
	check("fixture: the shell arrived as worker mesh data with five bores",
			(shell.get("vertices", []) as Array).size() > 0
				and _bores.size() == 5,
			"vertices=%d bores=%d" % [(shell.get("vertices", []) as Array).size(),
				_bores.size()])

	var panel := _stand_in_panel(gauge, checks, shell)
	var module: RefCounted = FastenerChecks.new()

	var report: Dictionary = await module.check(panel, {
		"screw": _screw(),
		"holes": _holes(),
		"compare_fit": true,
	})
	_check_envelope(report)
	_check_pairing(report)
	_check_screw_a(report)
	_check_screw_b(report)
	_check_screw_c(report)
	_check_screw_e(report)
	_check_fit_agreement(report)
	_check_status_line(module, report)
	await _check_iso_273(module, panel)
	await _check_seatless_hole(module, panel)
	await _check_refusals(module, panel)


# ---------------------------------------------------------------------------
# The report as a whole
# ---------------------------------------------------------------------------

func _check_envelope(report: Dictionary) -> void:
	check("envelope: the check ran and answered for four screws",
			bool(report.get("checked", false)) and int(report.get("count", 0)) == 4,
			"report = %s" % str(report.get("reason", report.get("count", "?"))))
	check("envelope: the whole check fails while any screw does — A passes, "
			+ "B, C and E do not",
			not bool(report.get("pass", true)) and int(report.get("failed", 0)) == 3,
			"pass=%s failed=%s" % [str(report.get("pass")), str(report.get("failed"))])
	check("envelope: the reply states the ray spacing its path check is worth, "
			+ "and says out loud that it is sampled",
			absf(float(report.get("ray_spacing_mm", 0.0))
				- FastenerChecks.RING_SPACING_MM) < 0.0001
				and str(report.get("sampling", "")).contains("between two rays"),
			"ray_spacing_mm=%s" % str(report.get("ray_spacing_mm")))


func _check_pairing(report: Dictionary) -> void:
	var nodes := {}
	for entry in report.get("screws", []):
		nodes[str((entry as Dictionary).get("node", ""))] = true
	check("pairing: every screw is on the board's own node",
			nodes.size() == 1 and nodes.has(BOARD_NODE),
			"nodes = %s" % str(nodes.keys()))

	# The trap the item names: two bosses must never claim one hole. Three
	# pairs over three holes with no repetition is the observable.
	var seats := {}
	for entry in report.get("screws", []):
		var seat: Array = ((entry as Dictionary).get("seat_mm", {}) as Dictionary).get("world", [])
		seats[str(seat)] = true
	check("pairing: four screws sit at four DIFFERENT holes — no hole is "
			+ "claimed twice",
			seats.size() == 4, "distinct seats = %d" % seats.size())

	var unpaired: Dictionary = report.get("unpaired", {}) as Dictionary
	var loose: Array = unpaired.get("solid_features", []) as Array
	check("pairing: the bore that matched no hole is listed rather than "
			+ "quietly dropped",
			loose.size() == 1, "unpaired solid features = %d" % loose.size())


# ---------------------------------------------------------------------------
# Screw A — the one that works
# ---------------------------------------------------------------------------

func _check_screw_a(report: Dictionary) -> void:
	var row := _row_at(report, HOLE_XY[0])
	check("A: a coaxial boss with a clear path and 6.4 mm of bite passes",
			bool(row.get("pass", false)), "row = %s" % str(row.get("why", row)))

	var zone: Dictionary = row.get("coaxiality", {}) as Dictionary
	check("A: its ISO 1101 zone is essentially zero, inside the 0.4 mm the "
			+ "M3's clearance allows",
			float(zone.get("zone_dia_mm", 99.0)) < NUMERIC_TOLERANCE_MM
				and absf(float(zone.get("allowed_mm", 0.0)) - M3_ALLOWED_RADIAL_MM) < 0.0001,
			"zone_dia=%s allowed=%s" % [str(zone.get("zone_dia_mm")),
				str(zone.get("allowed_mm"))])

	check("A: engagement is the overlap of the screw with the bore — 6.4 mm "
			+ "against the 6.0 mm two diameters ask for",
			absf(float(row.get("engagement_mm", 0.0)) - EXPECTED_ENGAGEMENT_MM)
					< NUMERIC_TOLERANCE_MM
				and absf(float(row.get("engagement_required_mm", 0.0))
					- EXPECTED_REQUIRED_MM) < 0.0001
				and bool(row.get("engagement_ok", false)),
			"engagement=%s required=%s" % [str(row.get("engagement_mm")),
				str(row.get("engagement_required_mm"))])

	check("A: the path is clear and the head sits fully on the board",
			bool(row.get("path_clear", false))
				and bool(row.get("head_seat_clear", false))
				and float(row.get("head_seat_supported", 0.0)) > 0.99,
			"path=%s seat=%s supported=%s" % [str(row.get("path_clear")),
				str(row.get("head_seat_clear")), str(row.get("head_seat_supported"))])

	check("A: the row names where its axis came from and the tolerance in force",
			str(row.get("axis_source", "")) == "b_rep"
				and float(row.get("tessellation_tolerance_mm", 0.0)) > 0.0,
			"axis_source=%s tolerance=%s" % [str(row.get("axis_source")),
				str(row.get("tessellation_tolerance_mm"))])

	check("A: the seat is the board's TOP face, reported in both frames",
			absf(_world_of(row["seat_mm"]).z - (POSE_ORIGIN.z + BOARD_HALF_THICKNESS))
					< NUMERIC_TOLERANCE_MM
				and absf(_local_of(row["seat_mm"]).z - BOARD_HALF_THICKNESS)
					< NUMERIC_TOLERANCE_MM,
			"seat = %s" % str(row.get("seat_mm")))


# ---------------------------------------------------------------------------
# Screw B — half a millimetre off, two degrees over
# ---------------------------------------------------------------------------

func _check_screw_b(report: Dictionary) -> void:
	var row := _row_at(report, HOLE_XY[1])
	check("B: a boss 0.5 mm off and 2 degrees over fails",
			not bool(row.get("pass", true)), "row = %s" % str(row))

	check("B: the two numbers that make up the failure are the two the "
			+ "fixture was built with",
			absf(float(row.get("centre_offset_mm", 0.0)) - B_OFFSET_MM)
					< NUMERIC_TOLERANCE_MM
				and absf(float(row.get("axis_angle_deg", 0.0)) - B_TILT_DEG)
					< ANGLE_TOLERANCE_DEG,
			"offset=%s angle=%s" % [str(row.get("centre_offset_mm")),
				str(row.get("axis_angle_deg"))])

	var zone: Dictionary = row.get("coaxiality", {}) as Dictionary
	check("B: the ISO 1101 zone is measured at BOTH ends of the engaged "
			+ "length, so the tilt is in the number and not only the offset",
			absf(float(zone.get("offset_start_mm", 0.0)) - B_OFFSET_AT_ENTRY_MM)
					< NUMERIC_TOLERANCE_MM
				and absf(float(zone.get("offset_end_mm", 0.0)) - B_OFFSET_AT_EXIT_MM)
					< NUMERIC_TOLERANCE_MM,
			"start=%s end=%s" % [str(zone.get("offset_start_mm")),
				str(zone.get("offset_end_mm"))])

	check("B: the zone diameter is twice the larger offset and blows the "
			+ "M3's 0.4 mm allowance",
			absf(float(zone.get("zone_dia_mm", 0.0))
					- 2.0 * B_OFFSET_AT_ENTRY_MM) < NUMERIC_TOLERANCE_MM
				and not bool(zone.get("pass", true)),
			"zone_dia=%s" % str(zone.get("zone_dia_mm")))

	check("B: everything else about it is fine, so `why` sends the reader to "
			+ "the coaxiality and not somewhere else",
			bool(row.get("path_clear", false))
				and bool(row.get("engagement_ok", false))
				and str(row.get("why", "")).contains("coaxiality"),
			"why = %s" % str(row.get("why")))


# ---------------------------------------------------------------------------
# Screw C — something is in the way
# ---------------------------------------------------------------------------

func _check_screw_c(report: Dictionary) -> void:
	var row := _row_at(report, HOLE_XY[2])
	check("C: a boss that lines up perfectly still fails when the screw "
			+ "cannot reach it",
			not bool(row.get("pass", true))
				and not bool(row.get("path_clear", true)),
			"pass=%s path_clear=%s" % [str(row.get("pass")), str(row.get("path_clear"))])

	var obstructions: Array = row.get("obstructions", []) as Array
	var first: Dictionary = obstructions[0] if not obstructions.is_empty() else {}
	check("C: the obstruction NAMES the node in the way — the whole point of "
			+ "the report is that it says what to move",
			str(first.get("node", "")) == BLOCKER_NODE,
			"first obstruction = %s" % str(first))

	check("C: and says where, in both frames, inside the blocker's own height",
			not first.is_empty()
				and _local_of(first["point_mm"]).z >= BLOCKER_BOTTOM_Z - NUMERIC_TOLERANCE_MM
				and _local_of(first["point_mm"]).z <= BLOCKER_TOP_Z + NUMERIC_TOLERANCE_MM,
			"point = %s" % str(first.get("point_mm")))

	check("C: its coaxiality is clean, so the failure is not being blamed on "
			+ "the wrong number",
			bool((row.get("coaxiality", {}) as Dictionary).get("pass", false))
				and str(row.get("why", "")).contains(BLOCKER_NODE),
			"why = %s" % str(row.get("why")))

	check("C: the head cannot reach its seat either, because the same "
			+ "blocker stands over it",
			not bool(row.get("head_seat_clear", true)),
			"head_seat_clear = %s" % str(row.get("head_seat_clear")))


# ---------------------------------------------------------------------------
# Screw E — the shell is in its own screw's way
# ---------------------------------------------------------------------------

## The case a references-only ring fan cannot see. Boss E stands 1.2 mm clear
## of the board and a rib of the SHELL bridges that gap across part of its
## bore, 1.4 mm off the axis — so the axis ray goes straight past it and only
## the shank ring meets it. It is the shell's own geometry, and it is not the
## boss the screw is heading into, which is exactly the distinction the fan's
## `expected` filter has to make.
func _check_screw_e(report: Dictionary) -> void:
	var row := _row_at(report, HOLE_XY[3])
	check("E: a rib of the shell across its own bore blocks the path, even "
			+ "though the axis ray misses it entirely",
			not bool(row.get("path_clear", true)) and not bool(row.get("pass", true)),
			"path_clear=%s pass=%s" % [str(row.get("path_clear")), str(row.get("pass"))])

	var obstructions: Array = row.get("obstructions", []) as Array
	var first: Dictionary = obstructions[0] if not obstructions.is_empty() else {}
	check("E: the obstruction is attributed to the SOLID, not to a reference",
			str(first.get("node", "")) == "<solid>"
				and str(first.get("reference", "")) == "",
			"first obstruction = %s" % str(first))

	# The rib occupies the gap: its top is the board's underside (axial 0.8)
	# and its underside is the boss's top face (axial 0.8 + the gap), which is
	# the mouth of E's bore. A hit anywhere in that band is neither the bore
	# wall nor the boss's end face, which is the only reason it is reported.
	check("E: and it is found in the gap ABOVE the bore's mouth, which is the "
			+ "only place a hit can be neither the bore wall nor the boss face",
			not first.is_empty()
				and float(first.get("axial_mm", -99.0))
					>= BOARD_HALF_THICKNESS - NUMERIC_TOLERANCE_MM
				and float(first.get("axial_mm", 99.0))
					<= BOARD_HALF_THICKNESS + E_GAP_MM + NUMERIC_TOLERANCE_MM,
			"axial = %s" % str(first.get("axial_mm")))

	check("E: its coaxiality is clean, so the boss's own mouth and bore wall "
			+ "were NOT mistaken for obstructions",
			bool((row.get("coaxiality", {}) as Dictionary).get("pass", false))
				and str(row.get("why", "")).contains("blocked"),
			"why = %s" % str(row.get("why")))


# ---------------------------------------------------------------------------
# The measurement that licenses the fallback
# ---------------------------------------------------------------------------

## The gate from the item: a bore the B-Rep knows and the panel's fitter also
## finds must agree on the AXIS to 0.01 mm and 0.05 degrees. The fit here is
## real — it runs over the shell's actual tessellation, through the same
## mesh_features fitter the reference meshes go through — so this is a
## measurement and not a restatement.
func _check_fit_agreement(report: Dictionary) -> void:
	var row := _row_at(report, HOLE_XY[0])
	var agreement: Dictionary = row.get("fit_agreement", {}) as Dictionary
	check("fit: a bore the B-Rep knows and the fitter also finds is compared, "
			+ "not assumed",
			not agreement.is_empty(), "row carried no fit_agreement")
	check("fit: the fitted axis sits inside the 0.01 mm / 0.05 degree gate "
			+ "that licenses using it when the B-Rep has no face",
			float(agreement.get("centre_offset_mm", 99.0)) <= AGREEMENT_CENTRE_MM
				and float(agreement.get("axis_angle_deg", 99.0)) <= AGREEMENT_ANGLE_DEG
				and bool(agreement.get("within_gate", false)),
			"offset=%s angle=%s" % [str(agreement.get("centre_offset_mm")),
				str(agreement.get("axis_angle_deg"))])
	check("fit: the radius difference is REPORTED and not graded — a "
			+ "tessellated bore fits its circumscribed circle by construction",
			agreement.has("radius_delta_mm")
				and float(agreement["radius_delta_mm"]) >= -0.0001
				and str(agreement.get("gate", "")).contains("chordal bias"),
			"radius_delta = %s" % str(agreement.get("radius_delta_mm")))


func _check_status_line(module: RefCounted, report: Dictionary) -> void:
	var line: String = module.status_line(report)
	check("banner: the status line names the FIRST failing screw and why, "
			+ "rather than summarising",
			line.begins_with("Fastener ") and line.contains(BOARD_NODE),
			"line = '%s'" % line)


# ---------------------------------------------------------------------------
# ISO 273: the allowance, and the refusal to invent one
# ---------------------------------------------------------------------------

func _check_iso_273(module: RefCounted, panel: Node) -> void:
	# 9 mm rather than 8, so this screw's engagement (7.4 mm) clears its own
	# 2 x 3.2 = 6.4 mm requirement outright. At 8 mm the two numbers are equal
	# to the last bit and the assertion below would rest on a float compare
	# rather than on the grading it is about.
	var odd_screw := {"dia_mm": 3.2, "length_mm": 9.0, "head_dia_mm": HEAD_DIA}
	var ungraded: Dictionary = await module.check(panel, {
		"screw": odd_screw, "holes": _holes(),
	})
	var row := _row_at(ungraded, HOLE_XY[0])
	var zone: Dictionary = row.get("coaxiality", {}) as Dictionary
	check("ISO 273: a size the medium series does not tabulate is NOT "
			+ "interpolated — it comes back ungraded, saying so",
			not bool(zone.get("graded", true))
				and zone.get("allowed_mm", 0.0) == null
				and zone.get("pass", false) == null
				and str(zone.get("clearance_source", "")).contains("ISO 273"),
			"zone = %s" % str(zone))
	check("ISO 273: an UNGRADED coaxiality does not fail the screw — nobody "
			+ "stating the clearance is not the same as the joint being wrong",
			bool(row.get("pass", false)) and str(row.get("why", "")) == "",
			"pass=%s why='%s'" % [str(row.get("pass")), str(row.get("why"))])

	var stated: Dictionary = await module.check(panel, {
		"screw": odd_screw, "holes": _holes(), "clearance_hole_dia_mm": 3.6,
	})
	var stated_zone: Dictionary = (_row_at(stated, HOLE_XY[0])
		.get("coaxiality", {}) as Dictionary)
	check("ISO 273: stating the clearance hole grades it again — (3.6 - 3.2) / 2",
			bool(stated_zone.get("graded", false))
				and absf(float(stated_zone.get("allowed_mm", 0.0)) - 0.2) < 0.0001
				and bool(stated_zone.get("pass", false)),
			"zone = %s" % str(stated_zone))


# ---------------------------------------------------------------------------
# A hole record that cannot be measured from
# ---------------------------------------------------------------------------

## The seat plane is half the plate's thickness above the hole's centre. With
## no thickness in the record there is no seat, and defaulting it to zero would
## put the seat at the CENTRE of the plate — shifting every axial number by
## half its thickness, silently, in a reply that still says `checked: true`.
func _check_seatless_hole(module: RefCounted, panel: Node) -> void:
	var thin := _hole_record(HOLE_XY[0])
	thin.erase("depth_mm")
	thin.erase("extent_mm")
	var reply: Dictionary = await module.check(panel, {
		"screw": _screw(), "holes": [thin],
	})
	var rows: Array = reply.get("screws", []) as Array
	var row: Dictionary = rows[0] if not rows.is_empty() else {}
	check("seat: a hole record with neither depth_mm nor extent_mm is a NAMED "
			+ "row that fails, not a silent seat at the hole's centre",
			rows.size() == 1 and not bool(row.get("pass", true))
				and not bool(row.get("measured", true))
				and str(row.get("error", "")).contains("depth_mm"),
			"row = %s" % str(row))


# ---------------------------------------------------------------------------
# Refusals — a check that did not run must never read as a pass
# ---------------------------------------------------------------------------

func _check_refusals(module: RefCounted, panel: Node) -> void:
	var no_screw: Dictionary = await module.check(panel, {"holes": _holes()})
	check("refusal: a check with no screw in it is refused, naming what it "
			+ "needs — and reports pass FALSE, not an empty success",
			not bool(no_screw.get("checked", true))
				and not bool(no_screw.get("pass", true))
				and str(no_screw.get("reason", "")).contains("dia_mm"),
			"reply = %s" % str(no_screw))

	var no_holes: Dictionary = await module.check(panel, {"screw": _screw()})
	check("refusal: with no hole to pair against, the reply says to run "
			+ "find_holes rather than reporting nothing wrong",
			not bool(no_holes.get("checked", true))
				and str(no_holes.get("reason", "")).contains("find_holes"),
			"reply = %s" % str(no_holes))

	var far_hole := _hole_record(Vector2(-28.0, 28.0))
	var nowhere: Dictionary = await module.check(panel, {
		"screw": _screw(), "holes": [far_hole],
	})
	check("refusal: a hole no bore lines up with produces no screw rows and "
			+ "is listed as unpaired, not paired with the nearest thing",
			int(nowhere.get("count", 0)) == 0
				and ((nowhere.get("unpaired", {}) as Dictionary)
					.get("reference_holes", []) as Array).size() == 1,
			"reply = %s" % str(nowhere))


# ---------------------------------------------------------------------------
# The stand-in panel and the stand-in backend
# ---------------------------------------------------------------------------

## The six accessors fastener_checks.gd reads off a panel. A real CADPanel
## would drag the scene, the worker IPC and the annotation host into a question
## none of them takes part in.
class StandInPanel extends Node3D:
	var gauge: Node = null
	var checks: RefCounted = null
	var mesh_data: Dictionary = {}
	var bores: Array = []
	## Every payload the module sent to the backend, in order.
	var payloads: Array = []

	func get_mesh_gauge() -> Node:
		return gauge

	func ensure_gauge_built() -> int:
		return int(gauge.get_shape_count()) if gauge != null else 0

	func get_reference_state() -> Array:
		return checks_records

	var checks_records: Array = []

	func get_document_state() -> Dictionary:
		return {"source": "part = <the fixture>", "mesh": mesh_data}

	func get_geometry_checks() -> RefCounted:
		return checks

	## The worker's cylindrical_features reply. The suite constructed these
	## axes from the fixture's literals; the exact B-Rep read is pinned in
	## worker/tests/test_features.py, which is where it runs.
	func call_backend(channel: String, args: Dictionary,
			_timeout_ms: int = 30000) -> Dictionary:
		payloads.append({"channel": channel, "args": args})
		await (Engine.get_main_loop() as SceneTree).process_frame
		return {"success": true, "result": {
			"units": "mm", "count": bores.size(), "cylinders": bores,
		}}


func _stand_in_panel(gauge: Node, checks: RefCounted, shell: Dictionary) -> Node:
	var panel := StandInPanel.new()
	panel.name = "StandInPanel"
	panel.gauge = gauge
	panel.checks = checks
	panel.checks_records = _records
	panel.mesh_data = shell
	panel.bores = _bores
	root.add_child(panel)
	return panel


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

## The board in its own frame: a plate centred on the origin with three
## through holes. Built with CSG and baked — no mesh binary in the repository.
func _bake_board() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Board"
	var plate := CSGBox3D.new()
	plate.size = BOARD_SIZE
	combiner.add_child(plate)
	for xy in HOLE_XY:
		var drill := CSGCylinder3D.new()
		drill.radius = HOLE_RADIUS
		drill.height = BOARD_SIZE.z * 4.0
		drill.sides = 64
		drill.operation = CSGShape3D.OPERATION_SUBTRACTION
		# CSGCylinder3D stands along +Y; the board's holes go along +Z.
		drill.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		drill.position = Vector3((xy as Vector2).x, (xy as Vector2).y, 0.0)
		combiner.add_child(drill)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


## The blocker: one box standing over the third hole, a separate node so the
## obstruction report has a name to give.
func _bake_blocker() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Blocker"
	var box := CSGBox3D.new()
	box.size = BLOCKER_SIZE
	box.position = Vector3(HOLE_XY[2].x, HOLE_XY[2].y,
		(BLOCKER_BOTTOM_Z + BLOCKER_TOP_Z) * 0.5)
	combiner.add_child(box)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


## The shell: four bosses with pilot bores, already in WORLD millimetres —
## which is where an evaluated solid always lives, since it is never posed.
func _shell_mesh() -> Dictionary:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Shell"
	_add_boss(combiner, _boss_transform(HOLE_XY[0], 0.0, 0.0), 0.0)
	_add_boss(combiner, _boss_transform(HOLE_XY[1], B_OFFSET_MM, B_TILT_DEG), 0.0)
	_add_boss(combiner, _boss_transform(HOLE_XY[2], 0.0, 0.0), 0.0)
	_add_boss(combiner, _boss_transform(D_XY, 0.0, 0.0), 0.0)
	_add_boss(combiner, _boss_transform(HOLE_XY[3], 0.0, 0.0), E_GAP_MM)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return _mesh_data(baked, _pose)


## One boss and its bore, in the board's own frame, under `xform`.
## `drop` lowers the boss (and its bore) away from the board, leaving a gap the
## rib then bridges. A boss with no drop sits against the board's underside.
func _add_boss(combiner: CSGCombiner3D, xform: Transform3D, drop: float) -> void:
	var boss := CSGCylinder3D.new()
	boss.radius = BOSS_OUTER_R
	boss.height = BORE_TOP_Z - BOSS_BOTTOM_Z
	boss.sides = 64
	boss.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	boss.position = Vector3(0.0, 0.0, (BORE_TOP_Z + BOSS_BOTTOM_Z) * 0.5 - drop)
	# The cutter runs 2 mm PAST the boss's top face. A cutter whose end plane
	# is coplanar with the face it cuts is the degenerate case every CSG
	# implementation gets to choose its own answer to; the surviving bore
	# surface is still exactly [BORE_BOTTOM_Z, BORE_TOP_Z], which is what the
	# B-Rep reply describes.
	var bore := CSGCylinder3D.new()
	bore.radius = BORE_R
	bore.height = BORE_LENGTH + 2.0
	bore.sides = 64
	bore.operation = CSGShape3D.OPERATION_SUBTRACTION
	bore.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	bore.position = Vector3(0.0, 0.0,
		(BORE_TOP_Z + 2.0 + BORE_BOTTOM_Z) * 0.5 - drop)
	var holder := CSGCombiner3D.new()
	holder.transform = xform
	holder.add_child(boss)
	holder.add_child(bore)
	if drop > 0.0:
		# The rib, bridging the gap the drop opened, ACROSS part of the bore
		# and clear of its centre. It is added after the bore cutter, so the
		# cutter cannot remove it.
		var rib := CSGBox3D.new()
		rib.size = RIB_SIZE
		rib.position = Vector3(RIB_OFFSET_X, 0.0, BORE_TOP_Z - drop * 0.5)
		holder.add_child(rib)
	combiner.add_child(holder)


## Where one boss sits in the board's own frame. `offset` moves it sideways at
## the SEAT plane and `tilt` leans it over in the same direction, so the two
## errors compose exactly the way a mis-modelled boss composes them.
func _boss_transform(xy: Vector2, offset: float, tilt_deg: float) -> Transform3D:
	var basis := Basis(Vector3.UP, deg_to_rad(tilt_deg))
	# The pivot is the seat plane, so `offset` is the offset AT the seat and
	# the tilt does not move the boss sideways there.
	var pivot := Vector3(xy.x + offset, xy.y, BOARD_HALF_THICKNESS)
	return Transform3D(basis, pivot - basis * Vector3(0.0, 0.0, BOARD_HALF_THICKNESS))


## What the worker's cylindrical_features would answer for that shell: one
## concave cylinder per bore, its origin at the START of its extent, the shape
## worker/mcad_worker/features.py reports. In WORLD millimetres.
func _brep_bores() -> Array:
	var out: Array = []
	for entry in [
		[HOLE_XY[0], 0.0, 0.0, 0.0], [HOLE_XY[1], B_OFFSET_MM, B_TILT_DEG, 0.0],
		[HOLE_XY[2], 0.0, 0.0, 0.0], [D_XY, 0.0, 0.0, 0.0],
		[HOLE_XY[3], 0.0, 0.0, E_GAP_MM],
	]:
		var spec: Array = entry
		var xform: Transform3D = _boss_transform(
			spec[0] as Vector2, float(spec[1]), float(spec[2]))
		var world := _pose * xform
		var origin: Vector3 = world * Vector3(
			0.0, 0.0, BORE_BOTTOM_Z - float(spec[3]))
		var direction: Vector3 = (world.basis * Vector3(0.0, 0.0, 1.0)).normalized()
		out.append({
			"source": "b_rep",
			"sense": "concave",
			"radius_mm": BORE_R,
			"dia_mm": BORE_R * 2.0,
			"axis": {"origin_mm": [origin.x, origin.y, origin.z],
				"direction": [direction.x, direction.y, direction.z]},
			"centre_mm": _as_array(origin + direction * (BORE_LENGTH * 0.5)),
			"start_mm": 0.0,
			"end_mm": BORE_LENGTH,
			"length_mm": BORE_LENGTH,
			"sweep_deg": 360.0,
			"closed": true,
			"faces": 2,
			"area_mm2": TAU * BORE_R * BORE_LENGTH,
		})
	return out


func _screw() -> Dictionary:
	return {"dia_mm": SCREW_DIA, "length_mm": SCREW_LENGTH, "head_dia_mm": HEAD_DIA}


## The three holes in the shape minerva_cad_find_holes reports them.
func _holes() -> Array:
	var out: Array = []
	for xy in HOLE_XY:
		out.append(_hole_record(xy as Vector2))
	return out


func _hole_record(xy: Vector2) -> Dictionary:
	var centre := _pose * Vector3(xy.x, xy.y, 0.0)
	var axis: Vector3 = (_pose.basis * Vector3(0.0, 0.0, 1.0)).normalized()
	return {
		"reference": BOARD_REFERENCE,
		"node": BOARD_NODE,
		"form": "concave",
		"center_mm": {"world": _as_array(centre), "local": [xy.x, xy.y, 0.0]},
		"axis": {"world": _as_array(axis), "local": [0.0, 0.0, 1.0]},
		"dia_mm": HOLE_DIA,
		"gauge_dia_mm": HOLE_DIA,
		"depth_mm": BOARD_SIZE.z,
		"extent_mm": BOARD_SIZE.z,
		"through": true,
		"verified": true,
	}


func _reference_world_box() -> AABB:
	var box := AABB(POSE_ORIGIN - Vector3(BOARD_SIZE.x, BOARD_SIZE.y, BOARD_SIZE.z) * 0.5,
		BOARD_SIZE)
	return box.expand(POSE_ORIGIN + Vector3(HOLE_XY[2].x, HOLE_XY[2].y, BLOCKER_TOP_Z))


## The worker's mesh shape: vertex triples and index triples, posed into world.
func _mesh_data(mesh: ArrayMesh, xform: Transform3D) -> Dictionary:
	var vertices: Array = []
	var faces: Array = []
	for surface in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var base := vertices.size()
		for vertex in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array):
			var world: Vector3 = xform * vertex
			vertices.append([world.x, world.y, world.z])
		var raw_index: Variant = arrays[Mesh.ARRAY_INDEX]
		if raw_index is PackedInt32Array and (raw_index as PackedInt32Array).size() >= 3:
			var indices: PackedInt32Array = raw_index
			var i := 0
			while i + 2 < indices.size():
				faces.append([base + indices[i], base + indices[i + 1],
					base + indices[i + 2]])
				i += 3
		else:
			var count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var j := 0
			while j + 2 < count:
				faces.append([base + j, base + j + 1, base + j + 2])
				j += 3
	return {"vertices": vertices, "faces": faces}


# ---------------------------------------------------------------------------
# Reading the report
# ---------------------------------------------------------------------------

## The screw row seated over the hole at `xy` in the board's own frame. Rows
## are looked up by WHERE they are rather than by index, so a change in the
## pairing order cannot silently move an assertion onto another screw.
func _row_at(report: Dictionary, xy: Vector2) -> Dictionary:
	for entry in report.get("screws", []):
		var row: Dictionary = entry
		var seat := _local_of(row.get("seat_mm", {}))
		if absf(seat.x - xy.x) < 0.05 and absf(seat.y - xy.y) < 0.05:
			return row
	return {}


func _world_of(frames: Dictionary) -> Vector3:
	return _as_vector(frames.get("world", []))


func _local_of(frames: Dictionary) -> Vector3:
	return _as_vector(frames.get("local", []))


func _as_vector(raw: Variant) -> Vector3:
	if raw is Array and (raw as Array).size() >= 3:
		var values: Array = raw
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.ZERO


func _as_array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass += 1
		print("  PASS  %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])
