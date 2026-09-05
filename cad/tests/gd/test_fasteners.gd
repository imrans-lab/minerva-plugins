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
## Two more on a one-boss shell: a thin SHELF at the bore radius is told from
## the wall by its normal, and a 10 mm screw in the 8.2 mm blind bore BOTTOMS.
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
## in it is 1.0 mm below the seat plane — twenty times the SEAT_TOLERANCE_MM
## band that counts as landed. The seat ring is sampled at (head + shank) / 2
## = 2.25 mm, so the pocket covers exactly the half of that ring on its own
## side.
const POCKET_DEPTH_MM := 1.0
const POCKET_SIZE := Vector3(12.0, 12.0, 4.0)
## Hole 2 is COUNTERBORED: a 7 mm recess, 0.3 mm deep, all the way round, so
## the whole seat ring (2.25 mm from the axis, inside the 3.5 mm recess) finds
## a complete annular floor 0.3 mm BELOW the seat plane. That is a head
## floating 0.3 mm — six times the seat tolerance and well inside the ring's
## 0.5 mm lateral pitch, so a seating window borrowed from that pitch reads
## it as fully supported. It touches nothing else about B: the hole record
## still places the seat at the board's top face, the shank rays pass down
## the 3.4 mm hole clear of the recess wall, and the head ring's span ends
## at the seat plane above the floor.
const COUNTERBORE_RADIUS := 3.5
const COUNTERBORE_DEPTH_MM := 0.3
## The rib: 0.5 wide in x, centred 0.65 mm off the bore axis, so it covers
## x in [0.4, 0.9] — at MID-RADIUS of the M3 shank. It misses the axis ray
## (x = 0) and it misses the shank's outer ring (x = 1.5) and the head's
## (x = 3.0), so a fan that samples only the axis and the rim cannot see it at
## any angular spacing; only rings across the whole disc can.
const RIB_SIZE := Vector3(0.5, 8.0, E_GAP_MM)
const RIB_OFFSET_X := 0.65
## The web INSIDE a bore, for the check that is asked separately: a bar
## across the whole bore diameter, 2 mm below the mouth, 0.3 mm thick, wider
## than the fan's pitch so the axis ray and its neighbours all meet it.
const WEB_DROP_MM := 2.0
const WEB_SIZE := Vector3(BORE_R * 2.0 + 0.4, 0.6, 0.3)
## How much further the bore's WALL reaches than the stretch of it that goes
## all the way round — the shape a tilted trim leaves. The engaged length must
## be measured on the full-circumference extent and not on this one.
const WALL_OVERRUN_MM := 1.0
## A reference SLEEVE standing in boss A's bore, its top SLEEVE_TOP_T below
## the hole centre — inside the engaged span — and its annulus spanning the
## bore radius. Driven with a screw whose shank radius IS the bore radius, so
## the fan's outer ring of rays lies exactly at the bore radius: a check that
## exempted every hit at that radius as the bore wall would read the sleeve
## as wall.
const SLEEVE_NODE := "Assembly/Sleeve"
const SLEEVE_INNER_R := 0.9
const SLEEVE_OUTER_R := 1.35
const SLEEVE_HEIGHT := 1.0
const SLEEVE_TOP_T := 3.0
const SLEEVE_SCREW_DIA := BORE_R * 2.0
## An annular BRIDGE of the shell standing on the board's top face around
## hole 1: outside the shank's fan, inside the head's, BRIDGE_HEIGHT tall.
const BRIDGE_INNER_R := 2.0
const BRIDGE_OUTER_R := 2.8
const BRIDGE_HEIGHT := 1.0
## A thin annular shelf inside boss A's bore, SHELF_DROP_MM below its mouth:
## its exposed top face spans only R-0.05..R (the rest merges into the wall),
## so every point of it lies within the bore-wall radius tolerance — a hit
## there is told from the wall by its NORMAL alone. The screw diameter puts
## the fan's outer ring at 1.17 mm: over the shelf, inside the chorded wall.
const SHELF_DROP_MM := 2.0
const SHELF_INNER_R := BORE_R - 0.05
const SHELF_OUTER_R := 1.5
const SHELF_HEIGHT := 0.3
const SHELF_SCREW_DIA := 2.34
const SHELF_RING_R := SHELF_SCREW_DIA * 0.5
## A screw longer than boss A's blind bore is deep: seat at -0.8, tip at
## 9.2 axial, floor (the full-turn extent end) at 0.8 + 8.2 = 9.0.
const BOTTOMING_SCREW_LENGTH := 10.0
const BORE_FLOOR_T := BOARD_HALF_THICKNESS + BORE_LENGTH
const BOTTOMING_TIP_T := -BOARD_HALF_THICKNESS + BOTTOMING_SCREW_LENGTH

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
## A groove that is nearly a hole and is not one: 355 degrees leaves five
## degrees of its wall missing, so a screw down its axis is open on one side.
## It is the case a "within one bin of a full turn" rule waves through.
const GROOVE_SWEEP_DEG := 355.0
## The threshold the worker states on every row: every bin of the turn, with
## an epsilon for float formatting and nothing else.
const CLOSED_MIN_SWEEP_DEG := 359.99
## The worker's angular resolution, reported on every cylinder row (72 bins of
## 5 degrees). It is what the extent's error bar is measured in; the closed
## rule is the whole turn, not a bin of slack.
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
	await _check_web_in_bore(module, panel)
	await _check_sleeve_in_bore(module, panel)
	await _check_bridge_over_the_seat(module, panel)
	await _check_shelf_in_bore(module, panel)
	await _check_bottoming(module, panel, report)
	await _check_through_bore(module, panel)
	await _check_missing_extent_metadata(module, panel)
	await _check_parts_changed_during_await(module, panel)
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
	check("pairing: a 355-degree groove nearer the hole than the boss is NOT "
			+ "paired — five degrees of missing wall is not a hole, and it is "
			+ "listed as a partial cylinder with its sweep",
			named_partial.has(GROOVE_DIA)
				and str(named_partial[GROOVE_DIA]).contains("355"),
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
			+ "the bores that DO sweep a full turn are graded as bores",
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

	# Both extents are axial distances from the seat, measured down the screw.
	# The fixture's bore is anchored at its far end, so the WALL_OVERRUN_MM of
	# wall that is not there at every azimuth sits at the MOUTH: the wall
	# starts WALL_OVERRUN_MM nearer the seat than the full-turn extent does,
	# and both end together at the bore's bottom. Engagement is measured on
	# the full-circumference extent — 0.8 to 9.0 axial — and grading it on the
	# wall instead would add that millimetre to every bite the check reports.
	var engaged: Dictionary = row.get("bore_extent_mm", {}) as Dictionary
	var walled: Dictionary = row.get("bore_wall_extent_mm", {}) as Dictionary
	check("A: engagement is measured on the extent that goes ALL THE WAY "
			+ "ROUND, with the wall's own further reach reported beside it",
			absf(float(engaged.get("exit", 0.0))
					- (BORE_LENGTH + BOARD_HALF_THICKNESS)) < NUMERIC_TOLERANCE_MM
				and absf(float(walled.get("exit", 0.0))
					- float(engaged.get("exit", 99.0))) < NUMERIC_TOLERANCE_MM
				and absf(float(engaged.get("entry", 0.0))
					- float(walled.get("entry", 99.0)) - WALL_OVERRUN_MM)
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

	# The counterbore: a complete floor 0.3 mm below the seat plane. Nothing
	# is in the head's way, so the seat is CLEAR — and NOT supported, because
	# a surface 0.3 mm down is a head floating 0.3 mm, whatever the ring's
	# lateral pitch is. The reply says how far by. The gap is measured to the
	# baked floor, which lies within a hundredth of the CSG literal.
	check("B: a complete annular floor 0.3 mm below the seat is not a seat — "
			+ "the ring reads unsupported, the head is still clear, and the "
			+ "measured seat gap is the counterbore's depth",
			bool(row.get("head_seat_clear", false))
				and float(row.get("head_seat_supported", 1.0)) < 0.001
				and int(row.get("head_seat_rays", 0)) == EXPECTED_SEAT_RAYS
				and absf(float(row.get("head_seat_gap_mm", 0.0))
					- COUNTERBORE_DEPTH_MM) < 0.01
				and float(row.get("head_seat_tolerance_mm", 1.0)) < COUNTERBORE_DEPTH_MM,
			"supported=%s gap=%s tolerance=%s rays=%s" % [
				str(row.get("head_seat_supported")), str(row.get("head_seat_gap_mm")),
				str(row.get("head_seat_tolerance_mm")), str(row.get("head_seat_rays"))])


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
	# re-posed — colliders and all, the way a re-evaluated document moves
	# them — and a second check is asked for on that new state.
	panel.checks_records = _records_at(moved)
	_rebuild_gauge(panel, moved)
	var second: Dictionary = await module.check(panel, {
		"screw": _screw(), "holes": _holes(),
	})
	for _frame in range(600):
		if not replies.is_empty():
			break
		await process_frame
	panel.checks_records = original
	_rebuild_gauge(panel, _pose)

	var first: Dictionary = replies[0] if not replies.is_empty() else {}
	# STALE, BOTH OF THEM, and for the same reason. A pose is what every local
	# coordinate is converted through and every ray is cast against: a panel
	# that re-poses under a check in flight has changed the document the check
	# was asked about, whether or not the colliders have caught up yet. The
	# reply that would otherwise come back — old-world holes and colliders
	# converted through the new pose — is the mixed epoch this guard exists to
	# refuse, and it is the most dangerous shape a wrong answer can take,
	# because every number in it is self-consistent. The second check is in
	# the same position: it snapshots the new poses while the colliders still
	# stand at the old ones, and it either stands down (busy, because the
	# first still holds the geometry, or stale) or it must answer in a frame
	# that matches what it measured.
	# The check started AFTER the move is in a consistent world of its own —
	# new poses, new colliders — so it either stands down for a documented
	# reason or answers in the frame it snapshotted, never in the one the
	# first check was called with.
	var expected := Vector3(HOLE_XY[0].x, HOLE_XY[0].y, BOARD_HALF_THICKNESS)
	var moved_expected: Vector3 = moved.affine_inverse() * (_pose * expected)
	var second_row := _row_at_world(second, _pose * expected)
	var second_local := _local_of(second_row.get("seat_mm", {}))
	var second_ok := bool(second.get("busy", false)) \
		or bool(second.get("stale", false)) \
		or (bool(second.get("checked", false))
			and second_local.distance_to(moved_expected) < NUMERIC_TOLERANCE_MM)
	check("poses: a check whose references are re-posed while it waits for "
			+ "the worker comes back STALE — a pose change is a document "
			+ "change — while the check started after the move answers in "
			+ "the frame it was called with",
			not first.is_empty()
				and bool(first.get("stale", false))
				and not bool(first.get("checked", true))
				and int(first.get("count", -1)) == 0
				and str(first.get("reason", "")).contains("find_holes")
				and second_ok
				and second_local.distance_to(expected) > NUMERIC_TOLERANCE_MM,
			"first = %s, second_local = %s, moved_expected = %s" % [
				str(first.get("reason", first)), str(second_local),
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
	_rebuild_gauge(panel, _pose)

	var after: Dictionary = later[0] if not later.is_empty() else {}
	# STALE, and nothing else. The HOLES this check was handed were measured
	# at the old pose by a verb this module does not run — it never segments a
	# reference itself — so there is no fresh set to pair against. Going again
	# on the new colliders with the old holes would seat every screw at a
	# world position the reference has left, with every number in the reply
	# self-consistent and every one of them wrong. So no row is measured at
	# all, and the reply names the verb to re-run.
	check("poses: a check whose reference COLLIDERS were rebuilt under it "
			+ "comes back STALE — it neither mixes new geometry with the "
			+ "holes it was given nor reports a single measured row",
			not after.is_empty()
				and bool(after.get("stale", false))
				and not bool(after.get("checked", true))
				and int(after.get("count", -1)) == 0
				and str(after.get("reason", "")).contains("find_holes"),
			"after = %s" % str(after))

	# The re-pose the panel actually performs: not a new array of records but
	# the SAME record with its pose rewritten where it stands, and no collider
	# rebuilt yet. A check holding the live record as its snapshot compares
	# the moved pose with itself, sees the generation unmoved, and answers —
	# old holes, old colliders, new pose — as if nothing had happened. The
	# snapshot has to be a copy for the comparison to mean anything.
	var record: Dictionary = panel.checks_records[0]
	var in_place: Array = []
	_collect_check(module, panel, in_place)
	record["pose"] = Transform3D(_pose.basis, _pose.origin + POSE_SHIFT)
	for _frame in range(600):
		if not in_place.is_empty():
			break
		await process_frame
	record["pose"] = _pose
	var rewritten: Dictionary = in_place[0] if not in_place.is_empty() else {}
	check("poses: a record whose pose is rewritten IN PLACE while a check "
			+ "waits for the worker — same array, same dictionary, no "
			+ "collider rebuilt — still comes back STALE with no rows",
			not rewritten.is_empty()
				and bool(rewritten.get("stale", false))
				and not bool(rewritten.get("checked", true))
				and int(rewritten.get("count", -1)) == 0
				and str(rewritten.get("reason", "")).contains("find_holes"),
			"rewritten = %s" % str(rewritten))

	# The window BEFORE a check starts. The panel rewrites a pose in place and
	# the colliders are rebuilt lazily, on the next measurement — so a check
	# can begin with records already ahead of the gauge, and if nothing
	# rebuilds during its wait, every guard that watches for a change sees
	# none: the snapshot holds the new pose, the generation never moves, and
	# the rays are cast against the OLD geometry and reported in the NEW
	# frame. The check has to notice at entry that the colliders were not
	# built from the records it holds. Either answer is honest: stale with a
	# reason, or a rebuild that puts the colliders at the new pose and a reply
	# framed in it — what it must never do is answer from the mixed epoch.
	var skew_pose := Transform3D(_pose.basis, _pose.origin + POSE_SHIFT)
	var generation_before := int(panel.gauge.get_generation())
	record["pose"] = skew_pose
	var skewed: Dictionary = await module.check(panel, {
		"screw": _screw(), "holes": _holes(),
	})
	var generation_after := int(panel.gauge.get_generation())
	record["pose"] = _pose
	var skew_row := _row_at_world(skewed, _pose * expected)
	var skew_local := _local_of(skew_row.get("seat_mm", {}))
	var skew_expected: Vector3 = skew_pose.affine_inverse() * (_pose * expected)
	var honest_stale := bool(skewed.get("stale", false)) \
		and not bool(skewed.get("checked", true)) \
		and int(skewed.get("count", -1)) == 0 \
		and str(skewed.get("reason", "")).contains("colliders behind poses")
	var honest_rebuild := bool(skewed.get("checked", false)) \
		and generation_after > generation_before \
		and skew_local.distance_to(skew_expected) < NUMERIC_TOLERANCE_MM
	check("poses: a check that STARTS with a pose already rewritten and the "
			+ "colliders not yet rebuilt — nothing changing during its wait — "
			+ "is stale (colliders behind poses) or rebuilds consistently, "
			+ "never old rays reframed through the new pose",
			(honest_stale or honest_rebuild)
				and not (bool(skewed.get("checked", false))
					and generation_after == generation_before),
			"skewed = %s, generation %d -> %d, local = %s, expected = %s" % [
				str(skewed.get("reason", skewed.get("count"))),
				generation_before, generation_after, str(skew_local),
				str(skew_expected)])
	# Restored: the gauge is untouched by a stale answer, and if the module
	# rebuilt, the poses now say the original again.
	_rebuild_gauge(panel, _pose)


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
	# Labelled by the pose: build() treats an identical label as a no-op, so
	# a label that did not change with the pose would leave the colliders
	# where the previous rebuild put them.
	panel.gauge.call("build", bodies, "fastener-fixture|%s" % str(pose))


## The suite's reference records under a different pose.
func _records_at(pose: Transform3D) -> Array:
	var out: Array = []
	for entry in _records:
		var record: Dictionary = (entry as Dictionary).duplicate()
		record["pose"] = pose
		out.append(record)
	return out


# ---------------------------------------------------------------------------
# A web INSIDE the bore
# ---------------------------------------------------------------------------

## The shank fan used to stop at the mouth of the bore, so a web left across
## the bore — a modelling slip that leaves a floor where thread should be —
## was reported path-clear as long as the approach was open. The same rays
## carry on down the ENGAGED bore now, where the only solid they may meet is
## the bore's own wall. A separate check on a one-boss shell, so the main
## report's five screws are left exactly as they are.
func _check_web_in_bore(module: RefCounted, panel: Node) -> void:
	var original_mesh: Dictionary = panel.mesh_data
	var original_bores: Array = panel.bores
	panel.mesh_data = await _webbed_shell_mesh()
	panel.bores = [_bores[0]]
	var report: Dictionary = await module.check(panel, {
		"screw": _screw(), "holes": _holes(),
	})
	panel.mesh_data = original_mesh
	panel.bores = original_bores

	var row := _row_at(report, HOLE_XY[0])
	var obstructions: Array = row.get("obstructions", []) as Array
	var first: Dictionary = obstructions[0] if not obstructions.is_empty() else {}
	# The web's faces, as axial distances from the hole centre: the mouth is
	# BOARD_HALF_THICKNESS down, the web WEB_DROP_MM below that.
	var web_top := BOARD_HALF_THICKNESS + WEB_DROP_MM
	var web_bottom := web_top + WEB_SIZE.z
	check("web: a web across the bore 2 mm below its mouth blocks the screw "
			+ "— the path is not clear, the obstruction is the SOLID inside "
			+ "the engaged bore at the web's own depth, `why` says so, and "
			+ "the coaxial boss is not blamed for anything else",
			bool(report.get("checked", false)) and int(report.get("count", 0)) == 1
				and not bool(row.get("path_clear", true))
				and not bool(row.get("pass", true))
				and str(first.get("node", "")) == "<solid>"
				and str(first.get("span", "")) == "bore"
				and float(first.get("axial_mm", -99.0))
					>= web_top - NUMERIC_TOLERANCE_MM
				and float(first.get("axial_mm", 99.0))
					<= web_bottom + NUMERIC_TOLERANCE_MM
				and str(row.get("why", "")).contains("inside the engaged bore")
				and bool((row.get("coaxiality", {}) as Dictionary).get("pass", false))
				and bool(row.get("engagement_ok", false))
				and bool(row.get("head_seat_clear", false)),
			"row = %s" % str(row))


## One coaxial boss at hole 1 with a web across its bore, as worker mesh data.
func _webbed_shell_mesh() -> Dictionary:
	return await _one_boss_shell_mesh(WEB_DROP_MM, false)


## One coaxial boss at hole 1, with a web `web_drop` below its mouth when that
## is positive and, when `bridge` is set, an annular bridge of the shell
## standing on the board's top face around the hole.
func _one_boss_shell_mesh(web_drop: float, bridge: bool,
		shelf_drop: float = 0.0) -> Dictionary:
	var combiner := CSGCombiner3D.new()
	combiner.name = "OneBossShell"
	var xform := _boss_transform(HOLE_XY[0], 0.0, 0.0)
	_add_boss(combiner, xform, 0.0, web_drop, shelf_drop)
	if bridge:
		var holder := CSGCombiner3D.new()
		holder.transform = xform
		var ring := _tube(BRIDGE_OUTER_R, BRIDGE_INNER_R, BRIDGE_HEIGHT)
		# The bridge stands on the seat: its underside on the board's top
		# face, its top BRIDGE_HEIGHT above it.
		ring.position = Vector3(0.0, 0.0, BOARD_HALF_THICKNESS + BRIDGE_HEIGHT * 0.5)
		holder.add_child(ring)
		combiner.add_child(holder)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return _mesh_data(baked, _pose)


## A tube along +Z: a cylinder with a coaxial cylinder cut out of it.
func _tube(outer_r: float, inner_r: float, height: float) -> CSGCombiner3D:
	var tube := CSGCombiner3D.new()
	var outer := CSGCylinder3D.new()
	outer.radius = outer_r
	outer.height = height
	outer.sides = 64
	outer.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	var inner := CSGCylinder3D.new()
	inner.radius = inner_r
	inner.height = height + 2.0
	inner.sides = 64
	inner.operation = CSGShape3D.OPERATION_SUBTRACTION
	inner.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	tube.add_child(outer)
	tube.add_child(inner)
	return tube


# ---------------------------------------------------------------------------
# A REFERENCE part at the bore radius
# ---------------------------------------------------------------------------

## Inside the engaged bore the only hit the fan may let through is the bore's
## own wall, and the wall is a surface OF THE SOLID at the bore's radius. A
## reference part whose surface sits at that radius — a sleeve or a pin left
## in the bore — is in the screw's way however exactly it matches the radius.
## The sleeve here is a reference body under the board's own pose, and the
## screw's shank radius is the bore radius, so the fan's outer ring meets the
## sleeve's top face at the bore radius precisely.
func _check_sleeve_in_bore(module: RefCounted, panel: Node) -> void:
	var original_mesh: Dictionary = panel.mesh_data
	var original_bores: Array = panel.bores
	var sleeve: ArrayMesh = await _bake_sleeve()
	var record: Dictionary = (_records[0] as Dictionary).duplicate()
	var parts: Array = (record["parts"] as Array).duplicate()
	parts.append({"mesh": sleeve, "transform": Transform3D.IDENTITY,
		"node_path": SLEEVE_NODE, "node": SLEEVE_NODE})
	record["parts"] = parts
	var with_sleeve: Array = [record]
	panel.checks_records = with_sleeve
	panel.gauge.call("build", MeshGauge.bodies_from_records(with_sleeve),
		"fastener-fixture|sleeve")
	panel.mesh_data = await _one_boss_shell_mesh(0.0, false)
	panel.bores = [_bores[0]]
	var report: Dictionary = await module.check(panel, {
		"screw": {"dia_mm": SLEEVE_SCREW_DIA, "length_mm": SCREW_LENGTH,
			"head_dia_mm": HEAD_DIA},
		"holes": _holes(),
	})
	panel.mesh_data = original_mesh
	panel.bores = original_bores
	panel.checks_records = _records
	_rebuild_gauge(panel, _pose)

	var row := _row_at(report, HOLE_XY[0])
	var obstructions: Array = row.get("obstructions", []) as Array
	var first: Dictionary = obstructions[0] if not obstructions.is_empty() else {}
	var only_the_sleeve := not obstructions.is_empty()
	for entry in obstructions:
		if str((entry as Dictionary).get("node", "")) != SLEEVE_NODE:
			only_the_sleeve = false
	check("sleeve: a REFERENCE sleeve whose top face sits at the bore radius "
			+ "inside the engaged span blocks the screw — the path is not "
			+ "clear, every obstruction names the sleeve under its reference "
			+ "(never the solid's wall), at the sleeve's own depth, met by "
			+ "the ring of rays at exactly the bore radius, and `why` says so",
			bool(report.get("checked", false)) and int(report.get("count", 0)) == 1
				and not bool(row.get("path_clear", true))
				and not bool(row.get("pass", true))
				and only_the_sleeve
				and str(first.get("reference", "")) == BOARD_REFERENCE
				and str(first.get("span", "")) == "bore"
				and absf(float(first.get("axial_mm", -99.0)) - SLEEVE_TOP_T)
					<= NUMERIC_TOLERANCE_MM
				and absf(float(first.get("ray_radius_mm", -99.0)) - BORE_R)
					<= NUMERIC_TOLERANCE_MM
				and str(row.get("why", "")).contains(SLEEVE_NODE)
				and str(row.get("why", "")).contains("inside the engaged bore")
				and bool(row.get("head_seat_clear", false)),
			"row = %s" % str(row))


## The sleeve in the board's own frame: a tube down boss A's bore, its top
## SLEEVE_TOP_T below the hole centre.
func _bake_sleeve() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Sleeve"
	var tube := _tube(SLEEVE_OUTER_R, SLEEVE_INNER_R, SLEEVE_HEIGHT)
	tube.position = Vector3(HOLE_XY[0].x, HOLE_XY[0].y,
		-(SLEEVE_TOP_T + SLEEVE_HEIGHT * 0.5))
	combiner.add_child(tube)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


# ---------------------------------------------------------------------------
# A SOLID feature between the head and its seat
# ---------------------------------------------------------------------------

## The head fan has to see the solid too. An annular bridge of the shell
## standing on the seat around the hole, outside the shank's radius and
## inside the head's, is met by no shank ray and by no reference ray — the
## seat ring lands on the board through the bridge's hole and reads fully
## supported — so the head fan is the only sampler wide enough to find it,
## and it can only do so with the solid among the bodies it casts against.
func _check_bridge_over_the_seat(module: RefCounted, panel: Node) -> void:
	var original_mesh: Dictionary = panel.mesh_data
	var original_bores: Array = panel.bores
	panel.mesh_data = await _one_boss_shell_mesh(0.0, true)
	panel.bores = [_bores[0]]
	var report: Dictionary = await module.check(panel, {
		"screw": _screw(), "holes": _holes(),
	})
	panel.mesh_data = original_mesh
	panel.bores = original_bores

	var row := _row_at(report, HOLE_XY[0])
	var over: Array = row.get("head_obstructions", []) as Array
	var first: Dictionary = over[0] if not over.is_empty() else {}
	# The bridge's top face, as an axial distance from the hole centre: the
	# seat is BOARD_HALF_THICKNESS above it, the bridge BRIDGE_HEIGHT higher.
	var bridge_top := -(BOARD_HALF_THICKNESS + BRIDGE_HEIGHT)
	check("bridge: an annular bridge of the SOLID standing on the seat, "
			+ "outside the shank and inside the head, fails head_seat_clear "
			+ "— the head obstruction is the solid on the approach at the "
			+ "bridge's top, met at a ray radius the shank never reaches — "
			+ "while the shank path stays clear, the seat ring still lands "
			+ "on the board, and `why` names it",
			bool(report.get("checked", false)) and int(report.get("count", 0)) == 1
				and bool(row.get("path_clear", false))
				and not bool(row.get("head_seat_clear", true))
				and not bool(row.get("pass", true))
				and str(first.get("node", "")) == "<solid>"
				and str(first.get("span", "")) == "approach"
				and absf(float(first.get("axial_mm", 99.0)) - bridge_top)
					<= NUMERIC_TOLERANCE_MM
				and float(first.get("ray_radius_mm", 0.0)) > SCREW_DIA * 0.5
				and float(first.get("ray_radius_mm", 99.0)) <= HEAD_DIA * 0.5
				and float(row.get("head_seat_supported", 0.0)) > 0.99
				and str(row.get("why", "")).contains("head cannot reach its seat")
				and str(row.get("why", "")).contains("<solid>")
				and bool(row.get("engagement_ok", false)),
			"row = %s" % str(row))


# ---------------------------------------------------------------------------
# A SHELF at the bore radius — the wall is a face, not a radius
# ---------------------------------------------------------------------------

## Inside the engaged bore a solid hit at the bore's radius used to be the
## wall by that fact alone. A thin shelf ending at the wall has a top face at
## that same radius, and a ray over it meets a face whose normal is AXIAL —
## the screw stops there. The fan's outer ring at 1.17 mm lies within the
## 0.05 mm wall tolerance of the 1.2 mm bore, so only the normal can tell.
func _check_shelf_in_bore(module: RefCounted, panel: Node) -> void:
	var original_mesh: Dictionary = panel.mesh_data
	var original_bores: Array = panel.bores
	panel.mesh_data = await _one_boss_shell_mesh(0.0, false, SHELF_DROP_MM)
	panel.bores = [_bores[0]]
	var report: Dictionary = await module.check(panel, {
		"screw": {"dia_mm": SHELF_SCREW_DIA, "length_mm": SCREW_LENGTH,
			"head_dia_mm": HEAD_DIA},
		"holes": _holes(),
	})
	panel.mesh_data = original_mesh
	panel.bores = original_bores

	var row := _row_at(report, HOLE_XY[0])
	var obstructions: Array = row.get("obstructions", []) as Array
	var first: Dictionary = obstructions[0] if not obstructions.is_empty() else {}
	var shelf_top := BOARD_HALF_THICKNESS + SHELF_DROP_MM
	check("shelf: a thin annular shelf spanning R-0.05..R at 2 mm depth blocks "
			+ "the screw — the obstruction is the SOLID inside the engaged "
			+ "bore at the shelf's top, met by a ray within the wall radius "
			+ "tolerance of the bore radius (the radius rule alone would have "
			+ "called it the wall), and `why` says so",
			bool(report.get("checked", false)) and int(report.get("count", 0)) == 1
				and not bool(row.get("path_clear", true))
				and not bool(row.get("pass", true))
				and str(first.get("node", "")) == "<solid>"
				and str(first.get("span", "")) == "bore"
				and absf(float(first.get("axial_mm", -99.0)) - shelf_top)
					<= NUMERIC_TOLERANCE_MM
				and absf(float(first.get("ray_radius_mm", -99.0)) - SHELF_RING_R)
					<= NUMERIC_TOLERANCE_MM
				and absf(float(first.get("ray_radius_mm", -99.0)) - BORE_R)
					<= FastenerChecks.BORE_WALL_TOLERANCE_MM
				and str(row.get("why", "")).contains("inside the engaged bore")
				and bool(row.get("head_seat_clear", false))
				and not bool(row.get("bottoming", true)),
			"row = %s" % str(row))


## Engagement is measured from the bore's full-turn extent, so every field the
## measurement rests on has to be present and of the stated type. Erasing one
## field at a time must make the check REFUSE and name the missing field; a
## report that comes back checked with a graded engagement would show the
## module filling a gap in the worker's reply with a default of its own.
func _check_missing_extent_metadata(module: RefCounted, panel: Node) -> void:
	var original: Array = panel.bores
	for field in ["extent_max_mm", "full_start_mm", "full_end_mm", "extent_full_bound_mm", "extent_exact", "extent_full_bounded"]:
		panel.bores = original.duplicate(true)
		panel.bores[0].erase(field)
		var report: Dictionary = await module.check(panel, {"screw":_screw(), "holes":_holes()})
		check("missing " + field + " refuses instead of guessing engagement",
			not bool(report.get("checked", true)) and str(report.get("reason", "")).contains(field), str(report))
	panel.bores = original


## The gauge's colliders are built from the part records; a part whose
## transform or mesh is swapped while a check waits leaves the rays it is
## about to cast describing geometry that is no longer there. The check must
## come back stale and unchecked, and must not rebuild the colliders itself —
## a report with rows, or a bumped gauge generation, would show it measuring
## across two epochs.
func _check_parts_changed_during_await(module: RefCounted, panel: Node) -> void:
	for kind in ["transform", "mesh"]:
		var part: Dictionary = panel.checks_records[0]["parts"][0]
		var original: Variant = part[kind]
		var epoch: int = panel.gauge.get_generation()
		var replies: Array = []
		_collect_check(module, panel, replies)
		if kind == "transform":
			part[kind] = Transform3D(Basis.IDENTITY, Vector3(10,0,0))
		else:
			var replacement := ArrayMesh.new()
			replacement.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, BoxMesh.new().get_mesh_arrays())
			part[kind] = replacement
		for _frame in range(600):
			if not replies.is_empty():
				break
			await process_frame
		part[kind] = original
		var report: Dictionary = replies[0] if not replies.is_empty() else {}
		check("mid-flight part " + kind + " change is stale before collider rebuild",
			bool(report.get("stale", false)) and not bool(report.get("checked", true))
			and panel.gauge.get_generation() == epoch, str(report))


## Bottoming is a floor question, so a bore with no floor cannot bottom. The
## same 10 mm screw that bottoms in boss A's blind bore is run down a bore
## drilled clean through its boss: the fan reaches the far mouth and meets
## nothing, so the row must pass with bottoming false. A row that bottoms here
## would show the far mouth, or the extent end, being read as material.
func _check_through_bore(module: RefCounted, panel: Node) -> void:
	var original_mesh: Dictionary = panel.mesh_data
	var original_bores: Array = panel.bores
	var combiner = CSGCombiner3D.new()
	var holder = CSGCombiner3D.new()
	holder.transform = _boss_transform(HOLE_XY[0], 0.0, 0.0)
	var boss = CSGCylinder3D.new()
	boss.radius = BOSS_OUTER_R
	boss.height = BORE_LENGTH
	boss.sides = 64
	boss.rotation.x = PI * 0.5
	boss.position.z = (BORE_TOP_Z + BORE_BOTTOM_Z) * 0.5
	holder.add_child(boss)
	var cutter = CSGCylinder3D.new()
	cutter.radius = BORE_R
	cutter.height = BORE_LENGTH + 4.0
	cutter.sides = 64
	cutter.rotation.x = PI * 0.5
	cutter.position.z = boss.position.z
	cutter.operation = CSGShape3D.OPERATION_SUBTRACTION
	holder.add_child(cutter)
	combiner.add_child(holder)
	root.add_child(combiner)
	await process_frame
	panel.mesh_data = _mesh_data(combiner.bake_static_mesh(), _pose)
	combiner.queue_free()
	panel.bores = [(_bores[0] as Dictionary).duplicate(true)]
	panel.bores[0].extent_max_mm = BORE_LENGTH
	panel.bores[0].extent_exact = true
	panel.bores[0].extent_full_bounded = true
	var report: Dictionary = await module.check(panel, {"screw":{"dia_mm":SCREW_DIA, "length_mm":BOTTOMING_SCREW_LENGTH, "head_dia_mm":HEAD_DIA}, "holes":_holes()})
	var row = _row_at(report, HOLE_XY[0])
	check("through pilot bore: oversize screw exits without bottoming", not bool(row.get("bottoming", true)) and bool(row.get("pass", false)), str(row))
	panel.mesh_data = original_mesh
	panel.bores = original_bores


# ---------------------------------------------------------------------------
# BOTTOMING — a screw longer than its blind bore is deep
# ---------------------------------------------------------------------------

## Boss A's bore is blind, 8.2 mm deep from a mouth 0.8 mm under the seat, so
## its floor is 9.0 mm down the axis. A 10 mm screw's tip ends 9.2 mm down: it
## meets the floor before the head meets the board, with engagement (8.2 mm)
## reading as ample and the path otherwise clear. The row must say bottoming,
## with the tip, the floor and the 0.2 mm excess — and the main report's 8 mm
## screw in the same bore must not.
func _check_bottoming(module: RefCounted, panel: Node, main: Dictionary) -> void:
	var original_mesh: Dictionary = panel.mesh_data
	var original_bores: Array = panel.bores
	panel.mesh_data = await _one_boss_shell_mesh(0.0, false)
	panel.bores = [_bores[0]]
	var report: Dictionary = await module.check(panel, {
		"screw": {"dia_mm": SCREW_DIA, "length_mm": BOTTOMING_SCREW_LENGTH,
			"head_dia_mm": HEAD_DIA},
		"holes": _holes(),
	})
	panel.mesh_data = original_mesh
	panel.bores = original_bores

	var row := _row_at(report, HOLE_XY[0])
	var fine := _row_at(main, HOLE_XY[0])
	check("bottoming: a 10 mm screw in the 8.2 mm blind bore bottoms out — "
			+ "tip at 9.2, floor at 9.0, 0.2 mm too long — the row fails on "
			+ "that alone with the path clear, the bite ample and the head "
			+ "seated, `why` says so, and the 8 mm screw in the same bore "
			+ "does not bottom",
			bool(report.get("checked", false)) and int(report.get("count", 0)) == 1
				and bool(row.get("bottoming", false))
				and not bool(row.get("pass", true))
				and absf(float(row.get("screw_tip_mm", 0.0)) - BOTTOMING_TIP_T)
					<= NUMERIC_TOLERANCE_MM
				and absf(float(row.get("bore_floor_mm", 0.0)) - BORE_FLOOR_T)
					<= NUMERIC_TOLERANCE_MM
				and absf(float(row.get("bottoming_by_mm", 0.0))
					- (BOTTOMING_TIP_T - BORE_FLOOR_T)) <= NUMERIC_TOLERANCE_MM
				and bool(row.get("path_clear", false))
				and bool(row.get("engagement_ok", false))
				and bool(row.get("head_seat_clear", false))
				and str(row.get("why", "")).contains("bottoms out")
				and not bool(fine.get("bottoming", true))
				and fine.get("bore_floor_mm", 0.0) == null
				and bool(fine.get("pass", false)),
			"row = %s, main A = %s" % [str(row), str(fine.get("why", fine.get("pass")))])


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
	# The counterbore around hole 2: its floor is a complete ring 0.3 mm under
	# the seat plane, which must read as a floating head and not as a seat.
	var counterbore := CSGCylinder3D.new()
	counterbore.radius = COUNTERBORE_RADIUS
	counterbore.height = COUNTERBORE_DEPTH_MM * 2.0
	counterbore.sides = 64
	counterbore.operation = CSGShape3D.OPERATION_SUBTRACTION
	counterbore.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	# Centred ON the top face, so exactly COUNTERBORE_DEPTH_MM of it is in
	# the board.
	counterbore.position = Vector3(HOLE_XY[1].x, HOLE_XY[1].y, BOARD_HALF_THICKNESS)
	combiner.add_child(counterbore)
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
## `web_drop`, when positive, leaves a web across the bore that far below its
## mouth; `shelf_drop`, when positive, a thin annular shelf at the wall.
func _add_boss(combiner: CSGCombiner3D, xform: Transform3D, drop: float,
		web_drop: float = 0.0, shelf_drop: float = 0.0) -> void:
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
	if web_drop > 0.0:
		# The web, across the whole bore and into its wall on both sides,
		# added after the cutter so the cutter cannot remove it.
		var web := CSGBox3D.new()
		web.size = WEB_SIZE
		web.position = Vector3(0.0, 0.0,
			BORE_TOP_Z - drop - web_drop - WEB_SIZE.z * 0.5)
		holder.add_child(web)
	if shelf_drop > 0.0:
		# The shelf: a tube whose outside merges into the wall, leaving a
		# ring of top face R-0.05..R exposed. Added after the cutter.
		var shelf := _tube(SHELF_OUTER_R, SHELF_INNER_R, SHELF_HEIGHT)
		shelf.position = Vector3(0.0, 0.0,
			BORE_TOP_Z - drop - shelf_drop - SHELF_HEIGHT * 0.5)
		holder.add_child(shelf)
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
			"sweep_deg": 360.0,
			"closed": true,
			"bin_deg": BIN_DEG,
			"closed_min_sweep_deg": CLOSED_MIN_SWEEP_DEG,
			"faces": 2,
			"area_mm2": TAU * BORE_R * BORE_LENGTH,
			"extent_full_exact": false,
			"extent_exact": true,
			"extent_full_bounded": true,
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
		"closed_min_sweep_deg": CLOSED_MIN_SWEEP_DEG,
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


## The same row, found by the seat's WORLD point. The local frame is whatever
## poses the reply was converted through, so it cannot identify a row in a
## check that was re-posed under: only the world point stays put, because the
## hole records the caller passed in are in world millimetres and unchanged.
func _row_at_world(report: Dictionary, world: Vector3) -> Dictionary:
	for entry in report.get("screws", []):
		var row: Dictionary = entry
		if _world_of(row.get("seat_mm", {})).distance_to(world) < 0.05:
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
