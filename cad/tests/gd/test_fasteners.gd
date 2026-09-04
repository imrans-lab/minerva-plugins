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
## A 60 x 60 x 1.6 board, posed away from the origin AND TURNED, with five
## 3.4 mm through holes, and a small blocker part standing over the third one.
## Under it, six bosses, each with a 2.4 mm pilot bore 8.2 mm deep:
##
##   A  coaxial with hole 1                     -> passes, on every count
##   B  0.5 mm off and tilted 2 degrees         -> fails coaxiality, and only that
##   C  coaxial with hole 3, blocker overhead   -> fails the path, naming the node
##   D  parked 24 mm from every hole            -> unpaired, and said so
##   E  coaxial with hole 4 but standing 1.2 mm clear of the board, with a RIB
##      of the shell bridging that gap at MID-RADIUS of the shank — clear of
##      the axis and clear of the shank's outer ring
##                                              -> fails the path on the SOLID,
##      which neither the axis ray nor a rim-only fan could ever see
##   F  coaxial with hole 5, whose seat plane is milled away on one side of
##      the axis                                -> passes, with HALF its seat
##      ring unsupported: the one number that grades how the head lands
##
## THE POSE IS TURNED, and that is load-bearing. The board is yawed about the
## CAD world's up axis and leaned about x, so the screw axis is nowhere near
## world z and every seat, obstruction and offset has to come from the hole's
## OWN axis and the pose's basis. A check that reads world z, or that adds
## pose.origin without applying pose.basis, fails here and passes on an
## identity pose.
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
## The five holes in the board's own frame (z = 0 is mid-thickness).
const HOLE_XY := [Vector2(-20.0, 0.0), Vector2(0.0, 0.0), Vector2(20.0, 0.0),
	Vector2(0.0, -20.0), Vector2(0.0, 20.0)]
## The blocker: a 4 x 4 x 3 box standing over hole 3, its underside 2.2 mm
## clear of the board's top face, so it is unmistakably in the screw's way and
## unmistakably not touching the board.
const BLOCKER_SIZE := Vector3(4.0, 4.0, 3.0)
const BLOCKER_BOTTOM_Z := 3.0
const BLOCKER_TOP_Z := 6.0

const POSE_ORIGIN := Vector3(100.0, 200.0, 300.0)
## How far the board is turned: a yaw about +z and a lean about +x.
const POSE_YAW_DEG := 30.0
const POSE_LEAN_DEG := 20.0
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
## gap across its bore at mid-radius: the axis ray misses it and so does the
## shank's outer ring, so only a fan that samples the whole disc sees it. Its
## bore therefore starts 1.2 mm deeper,
## which also puts its engagement short — E is a deliberate double failure and
## the suite asserts the PATH, which is the one `why` reports first.
const E_GAP_MM := 1.2
const E_BORE_TOP_Z := BORE_TOP_Z - E_GAP_MM
const E_BORE_BOTTOM_Z := BORE_BOTTOM_Z - E_GAP_MM
const E_BOSS_BOTTOM_Z := BOSS_BOTTOM_Z - E_GAP_MM
## Hole 5's seat plane is milled away on one side: a pocket whose straight
## edge passes through the hole's own axis, 1.0 mm deep, so a seat ray landing
## in it is 1.0 mm below the seat plane — twice the RING_SPACING_MM band that
## counts as landed. The seat ring is sampled at (head + shank) / 2 = 2.25 mm,
## so the pocket covers exactly the half of that ring on its own side.
const POCKET_DEPTH_MM := 1.0
const POCKET_SIZE := Vector3(12.0, 12.0, 4.0)
## The rib: 0.5 wide in x, centred 0.65 mm off the bore axis, so it covers
## x in [0.4, 0.9] — at MID-RADIUS of the M3 shank. It misses the axis ray
## (x = 0) and it misses the shank's outer ring (x = 1.5) and the head's
## (x = 3.0), so a fan that samples only the axis and the rim cannot see it at
## any angular spacing; only rings across the whole disc can.
const RIB_SIZE := Vector3(0.5, 8.0, E_GAP_MM)
const RIB_OFFSET_X := 0.65
## How much further the bore's WALL reaches than the stretch of it that goes
## all the way round — the shape a tilted trim leaves. The engaged length must
## be measured on the full-circumference extent and not on this one.
const WALL_OVERRUN_MM := 1.0

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
## The seat ring's own ray count, from the module's spacing rule:
## ceil(TAU * 2.25 / 0.5) = 29 rays, none of which is the axis ray.
const EXPECTED_SEAT_RAYS := 29
## Half of that ring lies over the pocket. Which side each ray falls on
## depends on where the ring's first ray happens to start, so 14 or 15 of the
## 29 land — and a ray landing on the pocket's own edge can go either way.
const HALF_SEAT_MIN := 0.40
const HALF_SEAT_MAX := 0.60
const ANGLE_TOLERANCE_DEG := 0.02

## A 180-degree cylindrical groove of a diameter the screw window accepts,
## sitting EXACTLY on hole 2's axis — nearer it than boss B, which is half a
## millimetre off. A check that pairs on geometry alone therefore prefers the
## groove to B and grades a screw against a surface that is open on one side;
## a check that asks whether the surface closed never considers it.
const GROOVE_DIA := 2.8
const GROOVE_SWEEP_DEG := 180.0
## The worker's angular resolution, reported on every cylinder row (72 bins of
## 5 degrees). The panel derives its closed rule from THIS number, so hole 5's
## bore is given a sweep exactly one bin short of a full turn — the seam a
## real bore leaves — and must still be graded as a bore.
const BIN_DEG := 5.0
## How far the panel is re-posed under a check that is already in flight. Big
## enough that a reply framed in the wrong pose is off by tens of millimetres
## and cannot be mistaken for a rounding difference.
const POSE_SHIFT := Vector3(50.0, -30.0, 20.0)
## The error bar the worker puts on a full-turn extent (it is read in angular
## bins). Engagement is graded on the extent MINUS this, so it has to be small
## enough that screw A still clears its 6.0 mm requirement on 6.4 mm of bite.
const EXTENT_BOUND_MM := 0.3

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
	_pose = Transform3D(
		Basis(Vector3.BACK, deg_to_rad(POSE_YAW_DEG))
			* Basis(Vector3.RIGHT, deg_to_rad(POSE_LEAN_DEG)),
		POSE_ORIGIN)
	check("fixture: the pose TURNS the board as well as moving it, so the "
			+ "screw axis is nowhere near world z",
			absf((_pose.basis * Vector3(0.0, 0.0, 1.0)).normalized()
				.angle_to(Vector3(0.0, 0.0, 1.0)) - deg_to_rad(POSE_LEAN_DEG))
					< deg_to_rad(0.01),
			"axis = %s" % str(_pose.basis * Vector3(0.0, 0.0, 1.0)))

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
	check("fixture: the shell arrived as worker mesh data with six bores and "
			+ "one half-turn groove",
			(shell.get("vertices", []) as Array).size() > 0
				and _bores.size() == 7,
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
	_check_pairing(report, panel)
	_check_screw_a(report)
	_check_screw_b(report)
	_check_screw_c(report)
	_check_screw_e(report)
	_check_screw_f(report)
	_check_fit_agreement(report)
	_check_status_line(module, report)
	await _check_iso_273(module, panel)
	await _check_seatless_hole(module, panel)
	await _check_refusals(module, panel)
	await _check_pose_snapshot(module, panel)


# ---------------------------------------------------------------------------
# The report as a whole
# ---------------------------------------------------------------------------

func _check_envelope(report: Dictionary) -> void:
	check("envelope: the check ran and answered for five screws",
			bool(report.get("checked", false)) and int(report.get("count", 0)) == 5,
			"report = %s" % str(report.get("reason", report.get("count", "?"))))
	check("envelope: the whole check fails while any screw does — A and F "
			+ "pass, B, C and E do not",
			not bool(report.get("pass", true)) and int(report.get("failed", 0)) == 3,
			"pass=%s failed=%s" % [str(report.get("pass")), str(report.get("failed"))])
	check("envelope: the reply states the ray spacing its path check is worth, "
			+ "and says out loud that it is sampled",
			absf(float(report.get("ray_spacing_mm", 0.0))
				- FastenerChecks.RING_SPACING_MM) < 0.0001
				and str(report.get("sampling", "")).contains("between two rays"),
			"ray_spacing_mm=%s" % str(report.get("ray_spacing_mm")))

	# The disc, stated as two spacings and counted. A rim-only fan over these
	# five screws could place at most (1 + 19) + (1 + 38) = 59 rays each; the
	# disc places three rings on the shank and six on the head, so the total
	# cannot be mistaken for the old fan's.
	var spacing: Dictionary = report.get("ray_spacing", {}) as Dictionary
	# The angular number is MEASURED — the widest arc any ring of this check
	# left between two rays — so a ring capped at the module's ray ceiling
	# cannot report a bound it did not keep. Every ring here is well inside
	# the cap, so the realised arc must come in at or under the nominal one.
	check("envelope: the spacing is stated in BOTH directions the disc is "
			+ "sampled in, the angular one measured rather than assumed, and "
			+ "the rays it placed are counted",
			absf(float(spacing.get("radial_mm", 0.0))
					- FastenerChecks.RING_SPACING_MM) < 0.0001
				and float(spacing.get("angular_mm", 0.0)) > 0.0
				and float(spacing.get("angular_mm", 99.0))
					<= FastenerChecks.RING_SPACING_MM + 0.0001
				and int(report.get("rays_total", 0)) > 5 * 59,
			"ray_spacing=%s rays_total=%s"
				% [str(spacing), str(report.get("rays_total"))])


func _check_pairing(report: Dictionary, panel: Node) -> void:
	var nodes := {}
	for entry in report.get("screws", []):
		nodes[str((entry as Dictionary).get("node", ""))] = true
	check("pairing: every screw is on the board's own node",
			nodes.size() == 1 and nodes.has(BOARD_NODE),
			"nodes = %s" % str(nodes.keys()))

	# Two bosses must never claim one hole: five pairs over five holes with no
	# repetition is the observable that says they did not.
	var seats := {}
	for entry in report.get("screws", []):
		var seat: Array = ((entry as Dictionary).get("seat_mm", {}) as Dictionary).get("world", [])
		seats[str(seat)] = true
	check("pairing: five screws sit at five DIFFERENT holes — no hole is "
			+ "claimed twice",
			seats.size() == 5, "distinct seats = %d" % seats.size())

	var unpaired: Dictionary = report.get("unpaired", {}) as Dictionary
	var loose: Array = unpaired.get("solid_features", []) as Array
	check("pairing: the bore that matched no hole and the surface that was "
			+ "never a bore are both listed rather than quietly dropped",
			loose.size() == 2, "unpaired solid features = %d" % loose.size())

	# The groove sits exactly on hole 2's axis and boss B sits half a
	# millimetre off it, so a check that pairs on geometry alone hands hole 2
	# to the groove and B's own row disappears. Both halves are asserted: the
	# groove is named as a partial surface, and B is still the screw at that
	# hole (its row is checked in full further down).
	var named_partial := {}
	for entry in loose:
		var feature: Dictionary = entry
		if str(feature.get("reason", "")).contains("partial cylinder"):
			named_partial[float(feature.get("dia_mm", 0.0))] = \
				str(feature.get("reason", ""))
	check("pairing: a half-turn groove nearer the hole than the boss is NOT "
			+ "paired — it is listed as a partial cylinder, with its sweep",
			named_partial.has(GROOVE_DIA)
				and str(named_partial[GROOVE_DIA]).contains("180"),
			"partial = %s" % str(named_partial))

	# Two halves of the same rule. The request must ASK for the partial
	# surfaces — a worker-side filter would drop the groove before this module
	# saw it, and the reply would promise a listing it could never make — and
	# the panel's own threshold must come from the worker's reported bin
	# width, so hole 5's bore, one bin short of a full turn, is still a bore.
	var asked: Dictionary = {}
	for entry in _payloads_of(panel):
		asked = (entry as Dictionary).get("args", {}) as Dictionary
	check("pairing: the request asks the worker for partial surfaces too, and "
			+ "a bore one bin short of a full turn is still a bore",
			asked.has("closed_only") and not bool(asked["closed_only"])
				and not named_partial.has(BORE_R * 2.0)
				and _row_at(report, HOLE_XY[4]).has("engagement_mm"),
			"asked=%s partial=%s" % [str(asked), str(named_partial.keys())])


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

	# The bore's wall runs WALL_OVERRUN_MM deeper than the stretch of it that
	# goes all the way round. Engagement is measured on the full-circumference
	# extent — 0.8 to 9.0 axial — and grading it on the wall instead would add
	# that millimetre to every bite the check reports.
	var engaged: Dictionary = row.get("bore_extent_mm", {}) as Dictionary
	var walled: Dictionary = row.get("bore_wall_extent_mm", {}) as Dictionary
	check("A: engagement is measured on the extent that goes ALL THE WAY "
			+ "ROUND, with the wall's own deeper reach reported beside it",
			absf(float(engaged.get("exit", 0.0))
					- (BORE_LENGTH + BOARD_HALF_THICKNESS)) < NUMERIC_TOLERANCE_MM
				and absf(float(walled.get("exit", 0.0))
					- (BORE_LENGTH + BOARD_HALF_THICKNESS + WALL_OVERRUN_MM))
					< NUMERIC_TOLERANCE_MM,
			"engaged=%s wall=%s" % [str(engaged), str(walled)])

	check("A: the engagement it is graded on is the measured bite MINUS the "
			+ "extent's own error bar, so a bore measured in bins cannot pass "
			+ "on the bin boundary",
			absf(float(row.get("engagement_bound_mm", -1.0)) - EXTENT_BOUND_MM)
					< NUMERIC_TOLERANCE_MM
				and float(row.get("engagement_mm", 0.0)) - EXTENT_BOUND_MM
					>= float(row.get("engagement_required_mm", 0.0))
				and bool(row.get("engagement_ok", false)),
			"engagement=%s bound=%s required=%s" % [
				str(row.get("engagement_mm")), str(row.get("engagement_bound_mm")),
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

	# The seat is the hole's centre lifted half the plate's thickness along the
	# hole's own axis. Under a turned pose that is the posed point
	# (x, y, +0.8), which the pose gives directly and the module has to reach
	# by transforming an axis.
	check("A: the seat is the board's TOP face, reported in both frames",
			_world_of(row["seat_mm"]).distance_to(_pose * Vector3(
					HOLE_XY[0].x, HOLE_XY[0].y, BOARD_HALF_THICKNESS))
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

	# The whole point of the disc: this rib is at 0.4-0.9 mm from the axis,
	# and the fan's own ring radii are 0.5, 1.0 and 1.5. A hit reported at a
	# ray radius that is neither 0 (the axis) nor the fan's own radius (the
	# rim) is a hit no rim-only fan could have made.
	check("E: the rib is caught by a ray between the axis and the rim — the "
			+ "radius a fan of axis-plus-rim never samples",
			float(first.get("ray_radius_mm", -1.0)) > 0.01
				and float(first.get("ray_radius_mm", 99.0))
					< float(first.get("fan_radius_mm", 0.0)) - 0.01,
			"ray_radius=%s fan_radius=%s"
				% [str(first.get("ray_radius_mm")), str(first.get("fan_radius_mm"))])

	check("E: its coaxiality is clean, so the boss's own mouth and bore wall "
			+ "were NOT mistaken for obstructions",
			bool((row.get("coaxiality", {}) as Dictionary).get("pass", false))
				and str(row.get("why", "")).contains("blocked"),
			"why = %s" % str(row.get("why")))


# ---------------------------------------------------------------------------
# Screw F — a head hanging half over a milled-away seat
# ---------------------------------------------------------------------------

## Nothing is in this screw's way and nothing is out of line: what is wrong is
## that half the ring its head bears on has no material under it. That is the
## one thing head_seat_supported grades, and it is graded over the SEAT ring's
## own rays — a denominator borrowed from any other fan would put the number
## somewhere other than a half.
func _check_screw_f(report: Dictionary) -> void:
	var row := _row_at(report, HOLE_XY[4])
	var supported := float(row.get("head_seat_supported", -1.0))
	check("F: the seat ring is sampled at the module's own spacing — 29 rays "
			+ "round a 2.25 mm ring, and the axis ray is not one of them",
			int(row.get("head_seat_rays", 0)) == EXPECTED_SEAT_RAYS,
			"rays = %s" % str(row.get("head_seat_rays")))
	check("F: with the seat plane milled away on one side of the axis, half "
			+ "the ring lands and half does not",
			supported > HALF_SEAT_MIN and supported < HALF_SEAT_MAX,
			"supported = %s" % str(row.get("head_seat_supported")))
	# The number is a coverage of ONE ring, and the row has to say so: a
	# reader who takes it for bearing area credits an annular void inside the
	# ring with holding the head.
	check("F: the row says what the seat number actually is — coverage of one "
			+ "ring at a stated radius, not bearing area",
			absf(float(row.get("head_seat_radius_mm", 0.0))
					- (HEAD_DIA + SCREW_DIA) * 0.25) < NUMERIC_TOLERANCE_MM
				and str(row.get("head_seat_rule", "")).contains("one radius")
				and str(row.get("head_seat_rule", "")).contains("not bearing area"),
			"radius=%s rule='%s'" % [str(row.get("head_seat_radius_mm")),
				str(row.get("head_seat_rule"))])

	check("F: a half-seated head is REPORTED, not graded — nothing is in its "
			+ "way, so the screw still passes and `why` stays silent",
			bool(row.get("pass", false))
				and bool(row.get("head_seat_clear", false))
				and bool(row.get("path_clear", false))
				and str(row.get("why", "")) == "",
			"pass=%s why='%s'" % [str(row.get("pass")), str(row.get("why"))])


# ---------------------------------------------------------------------------
# The measurement that licenses the fallback
# ---------------------------------------------------------------------------

## The gate: a bore the B-Rep knows and the panel's fitter also finds must
## agree on the AXIS to 0.01 mm and 0.05 degrees. The fit here is
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

	# This check follows a successful one, and it returns before any ray is
	# cast. Its envelope must therefore say ZERO rays — the counters belong to
	# the check that is reporting them, and inheriting the previous check's
	# numbers is a report about work this one never did.
	check("refusal: an empty check reports its OWN cost — no rays, no casts — "
			+ "rather than inheriting the last check's counters",
			int(nowhere.get("rays_total", -1)) == 0
				and int(nowhere.get("casts", -1)) == 0
				and float(nowhere.get("elapsed_ms", -1.0)) >= 0.0,
			"rays_total=%s casts=%s" % [str(nowhere.get("rays_total")),
				str(nowhere.get("casts"))])

	# An extent the kernel could not read exactly is not a bite anyone can
	# grade: the boundary fell back to a parametric BOX, which can overstate
	# the length by any amount. The screw is not failed for a modelling
	# detail — it is reported as ungraded, which is not a pass either.
	var honest: Array = panel.bores
	var uncertain: Array = []
	for entry in honest:
		var cylinder: Dictionary = (entry as Dictionary).duplicate(true)
		if absf(float(cylinder.get("dia_mm", 0.0)) - BORE_R * 2.0) < 0.001:
			cylinder["extent_exact"] = false
		uncertain.append(cylinder)
	panel.bores = uncertain
	var unsure: Dictionary = await module.check(panel, {
		"screw": _screw(), "holes": _holes(),
	})
	panel.bores = honest
	var unsure_row := _row_at(unsure, HOLE_XY[0])
	check("uncertain extent: a bore whose extent is not exact cannot be "
			+ "graded — engagement is not ok, says it is not certain, and the "
			+ "row explains that the boundary was not read",
			not bool(unsure_row.get("engagement_ok", true))
				and not bool(unsure_row.get("engagement_certain", true))
				and str(unsure_row.get("why", "")).contains("not exact")
				and not bool(unsure_row.get("pass", true)),
			"row = %s" % str(unsure_row))


# ---------------------------------------------------------------------------
# The poses a check answers in
# ---------------------------------------------------------------------------

## Every local coordinate in the reply is a world point taken back through a
## reference's pose, and the check reaches the worker before it measures
## anything — an IPC round trip it deliberately does not hold the geometry
## across. The panel's own state can change in that window: a re-pose, a new
## evaluation, or a second check's document. A check that read the poses
## afterwards would report this screw in another document's frame, silently,
## because every world number would still be right.
##
## Here the panel is re-posed WHILE the first check is in flight and a second
## check is started on the new pose. The first must answer in the pose it was
## called with. The second either answers in the new one or is refused as busy
## — the two checks share one collider and take it one at a time — but it must
## never answer in the first's frame.
func _check_pose_snapshot(module: RefCounted, panel: Node) -> void:
	var original: Array = panel.checks_records
	var moved := Transform3D(_pose.basis, _pose.origin + POSE_SHIFT)
	var replies: Array = []
	_collect_check(module, panel, replies)
	# Between the first check's entry and its measurement: the panel is
	# re-posed and a second check is asked for.
	panel.checks_records = _records_at(moved)
	var second: Dictionary = await module.check(panel, {
		"screw": _screw(), "holes": _holes(),
	})
	for _frame in range(600):
		if not replies.is_empty():
			break
		await process_frame
	panel.checks_records = original

	var first: Dictionary = replies[0] if not replies.is_empty() else {}
	var first_row := _row_at(first, HOLE_XY[0])
	var first_local := _local_of(first_row.get("seat_mm", {}))
	var expected := Vector3(HOLE_XY[0].x, HOLE_XY[0].y, BOARD_HALF_THICKNESS)
	# The second check, if it ran at all, is in the MOVED frame: same world
	# point, a local that differs by the shift taken back through the basis.
	var second_row := _row_at(second, HOLE_XY[0])
	var second_local := _local_of(second_row.get("seat_mm", {}))
	var moved_expected: Vector3 = moved.affine_inverse() 		* (_pose * expected)
	var second_ok := bool(second.get("busy", false)) 		or (not bool(second.get("checked", false))) 		or second_local.distance_to(moved_expected) < NUMERIC_TOLERANCE_MM
	check("poses: a check answers in the poses it was CALLED with, even "
			+ "though the panel was re-posed while it waited for the worker; "
			+ "a check started after the move never answers in the old frame",
			not first.is_empty()
				and first_local.distance_to(expected) < NUMERIC_TOLERANCE_MM
				and second_ok,
			"first_local=%s expected=%s second=%s moved_expected=%s" % [
				str(first_local), str(expected), str(second_local),
				str(moved_expected)])

	# The other half of the same window. A snapshot of the POSES is not enough
	# on its own: the colliders those poses describe can be rebuilt in the
	# same gap, and a check that cast its rays against the new geometry while
	# converting the hits through the old poses would report world numbers
	# that are all right and local ones that are all wrong. Here the panel is
	# re-posed AND the gauge rebuilt while a check waits, so the check must
	# either go again on the new state or say it is stale — never answer in
	# the frame it started in.
	var rebuilt := Transform3D(_pose.basis, _pose.origin - POSE_SHIFT)
	var later: Array = []
	_collect_check(module, panel, later)
	panel.checks_records = _records_at(rebuilt)
	_rebuild_gauge(panel, rebuilt)
	for _frame in range(600):
		if not later.is_empty():
			break
		await process_frame
	panel.checks_records = original

	var after: Dictionary = later[0] if not later.is_empty() else {}
	var after_row := _row_at(after, HOLE_XY[0])
	var after_local := _local_of(after_row.get("seat_mm", {}))
	var rebuilt_expected: Vector3 = rebuilt.affine_inverse() \
		* (_pose * expected)
	check("poses: a check whose reference COLLIDERS were rebuilt under it "
			+ "either measures the new state or comes back stale — it never "
			+ "mixes new geometry with old poses",
			not after.is_empty()
				and (bool(after.get("stale", false))
					or after_local.distance_to(rebuilt_expected)
						< NUMERIC_TOLERANCE_MM)
				and after_local.distance_to(expected) > NUMERIC_TOLERANCE_MM,
			"after=%s local=%s rebuilt_expected=%s" % [
				str(after.get("stale", after.get("checked", "?"))),
				str(after_local), str(rebuilt_expected)])


## Start a check without awaiting it and park its reply in `into`.
func _collect_check(module: RefCounted, panel: Node, into: Array) -> void:
	var reply: Dictionary = await module.check(panel, {
		"screw": _screw(), "holes": _holes(),
	})
	into.append(reply)


## Rebuild the gauge's colliders at a new pose, the way a re-evaluated
## document does — which is what makes the generation move.
func _rebuild_gauge(panel: Node, pose: Transform3D) -> void:
	var bodies: Array = []
	for entry in _records:
		var record: Dictionary = entry
		for part_entry in record.get("parts", []):
			var part: Dictionary = part_entry
			bodies.append({
				"mesh": part.get("mesh", null),
				"transform": pose,
				"node": str(part.get("node_path", "")),
				"reference": str(record.get("name", "")),
			})
	panel.gauge.call("build", bodies, "fastener-fixture|reposed")


## The suite's reference records under a different pose.
func _records_at(pose: Transform3D) -> Array:
	var out: Array = []
	for entry in _records:
		var record: Dictionary = (entry as Dictionary).duplicate()
		record["pose"] = pose
		out.append(record)
	return out


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

	## The worker's cylindrical_features reply, in the shape the HOST actually
	## delivers: the broker's envelope wrapping the worker's own
	## {ok, result} — two levels, not one. A stand-in that flattens them lets
	## a module reading one level pass here and find nothing in production.
	## The suite constructed these axes from the fixture's literals; the exact
	## B-Rep read is pinned in worker/tests/test_features.py, which is where
	## it runs.
	func call_backend(channel: String, args: Dictionary,
			_timeout_ms: int = 30000) -> Dictionary:
		payloads.append({"channel": channel, "args": args})
		await (Engine.get_main_loop() as SceneTree).process_frame
		# The worker's own closed_only filter, honoured here: a module that
		# asks for closed features only never receives a partial one, and its
		# own partial-surface reporting would be dead code in production
		# while the reply promised it.
		var answered: Array = []
		for entry in bores:
			var cylinder: Dictionary = entry
			if bool(args.get("closed_only", false)) \
					and not bool(cylinder.get("closed", false)):
				continue
			answered.append(cylinder)
		return {"success": true, "result": {"ok": true, "result": {
			"units": "mm", "count": answered.size(), "cylinders": answered,
			"exact": true,
		}}}


## Every payload the stand-in backend was sent, in order.
func _payloads_of(panel: Node) -> Array:
	return panel.payloads


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

## The board in its own frame: a plate centred on the origin with five through
## holes, the last of which has half its seat plane milled away. Built with CSG
## and baked — no mesh binary in the repository.
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
	# The pocket over hole 5: its straight edge runs through that hole's axis,
	# so the half of the seat ring on the +x side of the axis has no material
	# at the seat plane while the other half is untouched.
	var pocket := CSGBox3D.new()
	pocket.size = POCKET_SIZE
	pocket.operation = CSGShape3D.OPERATION_SUBTRACTION
	pocket.position = Vector3(
		HOLE_XY[4].x + POCKET_SIZE.x * 0.5,
		HOLE_XY[4].y,
		BOARD_HALF_THICKNESS - POCKET_DEPTH_MM + POCKET_SIZE.z * 0.5)
	combiner.add_child(pocket)
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


## The shell: six bosses with pilot bores, already in WORLD millimetres —
## which is where an evaluated solid always lives, since it is never posed.
func _shell_mesh() -> Dictionary:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Shell"
	_add_boss(combiner, _boss_transform(HOLE_XY[0], 0.0, 0.0), 0.0)
	_add_boss(combiner, _boss_transform(HOLE_XY[1], B_OFFSET_MM, B_TILT_DEG), 0.0)
	_add_boss(combiner, _boss_transform(HOLE_XY[2], 0.0, 0.0), 0.0)
	_add_boss(combiner, _boss_transform(D_XY, 0.0, 0.0), 0.0)
	_add_boss(combiner, _boss_transform(HOLE_XY[3], 0.0, 0.0), E_GAP_MM)
	_add_boss(combiner, _boss_transform(HOLE_XY[4], 0.0, 0.0), 0.0)
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
		[HOLE_XY[3], 0.0, 0.0, E_GAP_MM], [HOLE_XY[4], 0.0, 0.0, 0.0],
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
			"end_mm": BORE_LENGTH + WALL_OVERRUN_MM,
			"length_mm": BORE_LENGTH + WALL_OVERRUN_MM,
			# The two extents the worker reports for a bore whose mouth is cut
			# by a tilted face: the wall reaches WALL_OVERRUN_MM further than
			# the stretch that is there at every azimuth, and only the latter
			# is thread a screw can engage.
			"extent_max_mm": BORE_LENGTH + WALL_OVERRUN_MM,
			"extent_full_mm": BORE_LENGTH,
			"full_start_mm": 0.0,
			"full_end_mm": BORE_LENGTH,
			"sweep_deg": 360.0 - (BIN_DEG if spec[0] == HOLE_XY[4] else 0.0),
			# The worker's rule: closed is "within one bin of a full turn", so
			# the bore whose seam leaves a single bin empty is still closed.
			"closed": true,
			"bin_deg": BIN_DEG,
			"faces": 2,
			"area_mm2": TAU * BORE_R * BORE_LENGTH,
			"extent_full_exact": false,
			"extent_full_bound_mm": EXTENT_BOUND_MM,
		})
	out.append(_brep_groove())
	return out


## The groove the check must refuse to treat as a bore: a half-turn surface on
## hole 2's own axis, closed false, reported by the worker exactly as it
## reports a bore.
func _brep_groove() -> Dictionary:
	var xform: Transform3D = _boss_transform(HOLE_XY[1] as Vector2, 0.0, 0.0)
	var world := _pose * xform
	var origin: Vector3 = world * Vector3(0.0, 0.0, BORE_BOTTOM_Z)
	var direction: Vector3 = (world.basis * Vector3(0.0, 0.0, 1.0)).normalized()
	return {
		"source": "b_rep",
		"sense": "concave",
		"radius_mm": GROOVE_DIA * 0.5,
		"dia_mm": GROOVE_DIA,
		"axis": {"origin_mm": [origin.x, origin.y, origin.z],
			"direction": [direction.x, direction.y, direction.z]},
		"centre_mm": _as_array(origin + direction * (BORE_LENGTH * 0.5)),
		"start_mm": 0.0,
		"end_mm": BORE_LENGTH,
		"length_mm": BORE_LENGTH,
		"extent_max_mm": BORE_LENGTH,
		"extent_full_mm": BORE_LENGTH,
		"full_start_mm": 0.0,
		"full_end_mm": BORE_LENGTH,
		"sweep_deg": GROOVE_SWEEP_DEG,
		"closed": false,
		"bin_deg": BIN_DEG,
		"faces": 1,
		"area_mm2": PI * GROOVE_DIA * 0.5 * BORE_LENGTH,
	}


func _screw() -> Dictionary:
	return {"dia_mm": SCREW_DIA, "length_mm": SCREW_LENGTH, "head_dia_mm": HEAD_DIA}


## The five holes in the shape minerva_cad_find_holes reports them.
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


## The board's world bounds with the blocker's top corner in them. The pose
## turns the board, so the box is the one around the POSED corners.
func _reference_world_box() -> AABB:
	var box := AABB()
	var seen := false
	for x in [-BOARD_SIZE.x * 0.5, BOARD_SIZE.x * 0.5]:
		for y in [-BOARD_SIZE.y * 0.5, BOARD_SIZE.y * 0.5]:
			for z in [-BOARD_SIZE.z * 0.5, BOARD_SIZE.z * 0.5]:
				var corner: Vector3 = _pose * Vector3(x, y, z)
				box = AABB(corner, Vector3.ZERO) if not seen else box.expand(corner)
				seen = true
	return box.expand(_pose * Vector3(HOLE_XY[2].x, HOLE_XY[2].y, BLOCKER_TOP_Z))


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
