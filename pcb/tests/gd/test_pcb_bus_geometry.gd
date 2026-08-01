extends SceneTree
## Pins the real bus tool's GEOMETRIC CORE — slices S1 (clearance reader +
## per-adjacent-pair pitch) and S2 (mitered polyline offset + cumulative track
## offsets) of docket 019fb572b888.
##
## These tests ship WITH the code they cover, which is not this campaign's usual
## regime. The exception is deliberate and recorded: new computational geometry
## is the silent-wrong-and-expensive-later class — an offset that is subtly wrong
## at bends produces copper that LOOKS right in a screenshot and shorts two nets
## on the fab floor. Nothing downstream would catch it, because nothing
## downstream exists yet.
##
## EVERY EXPECTED POINT BELOW IS HAND-DERIVED, and the derivation is written out
## beside it. That is the whole value of the file: numbers pasted back out of the
## implementation would pin whatever it happens to do, including its bugs. Where
## a number is not obvious (the miter points, the bevel points, the miter-limit
## boundary) the arithmetic is shown line by line so a reviewer can check it with
## a calculator and never has to run the code to know what the answer should be.
##
## S3 (the ordered net-picker UI) and S4 (the armed canvas tool) are NOT BUILT
## and are not tested here — see pcb_bus_geometry.gd's header for the slice plan.
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout> (same convention as
## every suite here — see test_routing_workspace_model.gd's header).

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const BusGeom := preload("res://../../minerva-plugins/pcb/ui/model/pcb_bus_geometry.gd")

## Tolerance for a coordinate comparison, in mm. Six decimal places is far below
## anything a board cares about (1 nanometre) and far above float32 noise on the
## magnitudes here (tens of mm).
const EPS := 1e-6

## Tolerance for a DERIVED quantity — a distance obtained by normalizing a
## direction, dotting it against a difference, and comparing the result — rather
## than for a coordinate the code wrote down directly. 1e-4 mm = 0.1 micron, four
## orders below any fabrication tolerance, so it still fails any real geometry
## bug (the naive-translate mutation misses by 1.0 mm, the sign flip by 2.0).
##
## It is looser than EPS because Godot's Vector2 is 32-bit float regardless of
## build precision: at the ~40mm coordinates the S-bend spine reaches, one ulp is
## already ~4e-6 mm, so a chained computation cannot land inside 1e-6. Measured,
## not assumed — the S-bend case failed at 1.19e-6 with EPS before this constant
## existed, while every direct point comparison in this file passes at 1e-6.
const DERIVED_EPS := 1e-4

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Bus geometry: mitered offset + pitch (S1+S2, 019fb572b888) ===\n")
	_run_sign_convention()
	_run_two_point_and_straight()
	_run_right_angle()
	_run_obtuse_miter()
	_run_miter_limit_boundary()
	_run_acute_bevel()
	_run_degenerate_inputs()
	_run_zero_offset_identity()
	_run_pitch_invariant_through_bends()
	_run_pitch_between()
	_run_cumulative_offsets()
	_run_design_rule_clearance()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + desc)
	else:
		_fail += 1
		printerr("  FAIL: " + desc)


## Assert an offset result equals a hand-derived point list exactly (to EPS),
## reporting BOTH lists on failure — a geometry failure is unreadable without
## the actual numbers.
func check_points(desc: String, got: PackedVector2Array, want: Array) -> void:
	var ok := got.size() == want.size()
	if ok:
		for i in range(got.size()):
			var w: Vector2 = want[i]
			if absf(got[i].x - w.x) > EPS or absf(got[i].y - w.y) > EPS:
				ok = false
				break
	if ok:
		_pass += 1
		print("  PASS: " + desc)
	else:
		_fail += 1
		printerr("  FAIL: %s\n    want: %s\n    got:  %s" % [desc, str(want), str(got)])


func check_near(desc: String, got: float, want: float, tol := EPS) -> void:
	if absf(got - want) <= tol:
		_pass += 1
		print("  PASS: %s (%.9f)" % [desc, got])
	else:
		_fail += 1
		printerr("  FAIL: %s — want %.9f, got %.9f" % [desc, want, got])


func _pv(arr: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in arr:
		out.append(p)
	return out


## Perpendicular distance from `p` to the INFINITE line through a and b.
func _dist_to_line(p: Vector2, a: Vector2, b: Vector2) -> float:
	var d: Vector2 = (b - a).normalized()
	var n := Vector2(-d.y, d.x)
	return absf((p - a).dot(n))


## The router's approach, reproduced here as the FOIL for the pitch-invariant
## test: derive one perpendicular from the FIRST segment and rigid-translate
## every point by it (worker/agent_router/router.py:1584-1596 + :1647-1652).
func _router_rigid_translate(points: PackedVector2Array, offset: float) -> PackedVector2Array:
	var d: Vector2 = (points[1] - points[0]).normalized()
	var n := Vector2(-d.y, d.x)
	var out := PackedVector2Array()
	for p in points:
		out.append(p + n * offset)
	return out


func _run_sign_convention() -> void:
	print("-- sign convention: +offset is RIGHT of travel (x right, y down) --")
	# Travel east: d = (1,0). Normal n = (-d.y, d.x) = (0,1). With y DOWN, +y is
	# the walker's right hand. So +1 must land BELOW the spine, -1 above it.
	var spine := _pv([Vector2(0, 0), Vector2(10, 0)])
	check_points("east spine, +1 -> y = +1 (right/below)",
		BusGeom.offset_polyline(spine, 1.0),
		[Vector2(0, 1), Vector2(10, 1)])
	check_points("east spine, -1 -> y = -1 (left/above)",
		BusGeom.offset_polyline(spine, -1.0),
		[Vector2(0, -1), Vector2(10, -1)])

	# Travel south (y down): d = (0,1), n = (-1,0). Right of "walking down the
	# screen" is the -x side. This is the rotation route_bus uses too
	# (perp = (-dir_y, dir_x)), so track index reads the same in both.
	check_points("south spine, +1 -> x = -1 (right of travel)",
		BusGeom.offset_polyline(_pv([Vector2(0, 0), Vector2(0, 10)]), 1.0),
		[Vector2(-1, 0), Vector2(-1, 10)])

	# Reversing the spine flips which physical side a sign lands on — inherent
	# to "relative to travel", stated in the module header, pinned here so a
	# future change cannot quietly redefine it.
	check_points("reversed spine mirrors the side",
		BusGeom.offset_polyline(_pv([Vector2(10, 0), Vector2(0, 0)]), 1.0),
		[Vector2(10, -1), Vector2(0, -1)])


func _run_two_point_and_straight() -> void:
	print("-- 2-point translate + collinear straight run --")
	# 2 points: no interior vertex, so no join — a plain perpendicular translate.
	# d = (3,4)/5 = (0.6,0.8); n = (-0.8,0.6); offset 2 -> (-1.6,1.2).
	check_points("2-point diagonal is a plain perpendicular translate",
		BusGeom.offset_polyline(_pv([Vector2(0, 0), Vector2(3, 4)]), 2.0),
		[Vector2(-1.6, 1.2), Vector2(3 - 1.6, 4 + 1.2)])

	# Collinear interior vertex: u == v, so u.v == 1, denom == 2, and the miter
	# formula gives P + offset*(u+v)/2 == P + offset*u. The vertex SURVIVES (it
	# is a real point of the polyline) and simply translates.
	check_points("collinear run keeps its middle vertex, translated",
		BusGeom.offset_polyline(_pv([Vector2(0, 0), Vector2(5, 0), Vector2(10, 0)]), 2.0),
		[Vector2(0, 2), Vector2(5, 2), Vector2(10, 2)])


func _run_right_angle() -> void:
	print("-- right angle: miter point derived by hand --")
	# Spine (0,0) -> (10,0) -> (10,10).
	#   seg0 d0 = (1,0)   -> u = (0,1)
	#   seg1 d1 = (0,1)   -> v = (-1,0)
	#   c = u.v = 0 ; denom = 1 + c = 1
	#   M = P + offset*(u+v)/denom = (10,0) + 1*(-1,1)/1 = (9,1)
	#   miter length |M-P| = |(-1,1)| = sqrt(2) = 1.41421356 = |offset|*sqrt(2/1)
	#   ends: (0,0)+1*u = (0,1) ; (10,10)+1*v = (9,10)
	var spine := _pv([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)])
	var inner := BusGeom.offset_polyline(spine, 1.0)
	check_points("inside of the corner (+1)", inner,
		[Vector2(0, 1), Vector2(9, 1), Vector2(9, 10)])
	check_near("miter length is |offset|*sqrt(2) at a right angle",
		inner[1].distance_to(Vector2(10, 0)), sqrt(2.0))

	# Negative offset takes the OUTSIDE of the same corner: M = (10,0) + (-1)*(-1,1)
	# = (11,-1); ends (0,-1) and (11,10).
	check_points("outside of the corner (-1)",
		BusGeom.offset_polyline(spine, -1.0),
		[Vector2(0, -1), Vector2(11, -1), Vector2(11, 10)])

	# The property that makes it a real offset rather than a translate: BOTH
	# segments of the result sit exactly |offset| from their spine segment. The
	# rigid translate satisfies this on segment 0 only.
	check_near("result segment 0 is 1.0 from spine segment 0",
		_dist_to_line(inner[0], spine[0], spine[1]), 1.0)
	check_near("result segment 1 is 1.0 from spine segment 1",
		_dist_to_line(inner[2], spine[1], spine[2]), 1.0)


func _run_obtuse_miter() -> void:
	print("-- obtuse (135 deg interior) bend: miter point derived by hand --")
	# Spine (0,0) -> (10,0) -> (20,10).
	#   d0 = (1,0)              -> u = (0,1)
	#   d1 = (10,10)/sqrt(200) = (1/sqrt2, 1/sqrt2) -> v = (-1/sqrt2, 1/sqrt2)
	#   c = u.v = 1/sqrt2 = 0.707106781 ; denom = 1.707106781
	#   u+v = (-0.707106781, 1.707106781)
	#   M = (10,0) + (1/1.707106781)*(-0.707106781, 1.707106781)
	#     = (10,0) + 0.585786438*(-0.707106781, 1.707106781)
	#     = (10,0) + (-0.414213562, 1.0)
	#     = (9.585786438, 1.0)          [note 0.414213562 = sqrt(2)-1]
	#   ends: (0,1) ; (20,10) + (-0.707106781, 0.707106781)
	#                        = (19.292893219, 10.707106781)
	var r2 := sqrt(2.0)
	var half := 1.0 / r2
	check_points("135-degree interior miter",
		BusGeom.offset_polyline(_pv([Vector2(0, 0), Vector2(10, 0), Vector2(20, 10)]), 1.0),
		[Vector2(0, 1), Vector2(10 - (r2 - 1.0), 1), Vector2(20 - half, 10 + half)])

	# Miter ratio check: sqrt(2/(1+c)) = sqrt(2/1.707106781) = 1.082392200,
	# which is 1/sin(135/2 deg) = 1/sin(67.5 deg) = 1/0.923879533.
	check_near("miter ratio matches 1/sin(theta/2) at 135 degrees",
		sqrt(2.0 / (1.0 + half)), 1.0 / sin(deg_to_rad(67.5)))


func _run_miter_limit_boundary() -> void:
	print("-- miter limit 4.0: the discriminating pair either side of it --")
	# BELOW THE LIMIT -> still mitered, one point at the joint.
	# Spine (0,0) -> (10,0) -> (2,6): seg1 = (-8,6), length 10, d1 = (-0.8,0.6),
	# v = (-0.6,-0.8). c = u.v = (0,1).(-0.6,-0.8) = -0.8 ; denom = 0.2.
	# ratio = sqrt(2/0.2) = sqrt(10) = 3.16227766 <= 4 -> MITER.
	# M = (10,0) + (1/0.2)*((0,1)+(-0.6,-0.8)) = (10,0) + 5*(-0.6,0.2) = (7,1).
	var mitered := BusGeom.offset_polyline(
		_pv([Vector2(0, 0), Vector2(10, 0), Vector2(2, 6)]), 1.0)
	check("ratio 3.162 joint stays a single mitered point", mitered.size() == 3)
	check_points("miter point at ratio 3.162", mitered,
		[Vector2(0, 1), Vector2(7, 1), Vector2(2 - 0.6, 6 - 0.8)])
	check_near("its miter length is |offset|*sqrt(10)",
		mitered[1].distance_to(Vector2(10, 0)), sqrt(10.0))

	# The limit in closed form: ratio = sqrt(2/(1+c)) = 4 at c = -0.875, which is
	# an interior angle of 2*asin(0.25) = 28.955 degrees. Pinned so a change to
	# MITER_LIMIT is a visible change to a documented angle, not a silent one.
	check_near("MITER_LIMIT 4.0 is the 2*asin(1/4) joint",
		sqrt(2.0 / (1.0 + -0.875)), BusGeom.MITER_LIMIT)


func _run_acute_bevel() -> void:
	print("-- acute bend: bevel fallback (two points, no spike) --")
	# Spine (0,0) -> (10,0) -> (0.4,2.8).
	#   seg1 = (-9.6, 2.8), length = sqrt(92.16 + 7.84) = sqrt(100) = 10
	#   d1 = (-0.96, 0.28) -> v = (-0.28, -0.96) ; u = (0,1)
	#   c = u.v = -0.96 ; denom = 0.04
	#   ratio = sqrt(2/0.04) = sqrt(50) = 7.071067812 > 4 -> BEVEL
	# Had it mitered: M = (10,0) + (1/0.04)*(-0.28, 0.04) = (10,0) + (-7,1)
	#               = (3,1) — a 7.07mm spike of copper shot back alongside the
	#               trace it belongs to. That is what the limit exists to stop.
	# Bevel points: P + offset*u = (10,1) ; P + offset*v = (9.72, -0.96)
	# Ends: (0,1) ; (0.4,2.8) + (-0.28,-0.96) = (0.12, 1.84)
	var spine := _pv([Vector2(0, 0), Vector2(10, 0), Vector2(0.4, 2.8)])
	var got := BusGeom.offset_polyline(spine, 1.0)
	check("acute joint emits TWO points (bevel), not one", got.size() == 4)
	check_points("bevel points at the acute joint", got,
		[Vector2(0, 1), Vector2(10, 1), Vector2(9.72, -0.96), Vector2(0.12, 1.84)])

	# The invariant the bevel buys: no emitted point is further from the vertex
	# than |offset|. The miter would have been 7.07x that.
	check_near("bevel point 1 sits exactly |offset| from the vertex",
		got[1].distance_to(Vector2(10, 0)), 1.0)
	check_near("bevel point 2 sits exactly |offset| from the vertex",
		got[2].distance_to(Vector2(10, 0)), 1.0)
	var spike_free := true
	for p in got:
		if p.distance_to(Vector2(3, 1)) < 0.5:
			spike_free = false
	check("no point lands at the (3,1) miter spike", spike_free)

	# Same joint, negative offset — the bevel is symmetric, not a special case
	# of the inside of a corner.
	check_points("acute bevel on the other side (-1)",
		BusGeom.offset_polyline(spine, -1.0),
		[Vector2(0, -1), Vector2(10, -1), Vector2(10.28, 0.96), Vector2(0.68, 3.76)])


func _run_degenerate_inputs() -> void:
	print("-- degenerate inputs: duplicates, 1 point, 0 points --")
	# A repeated point has no direction. Dropped BEFORE any normal is computed;
	# normalized() on a zero vector returns ZERO in Godot, which would otherwise
	# put an offset point on the spine — a track shorted to its neighbour.
	check_points("consecutive duplicate is dropped, not offset to zero",
		BusGeom.offset_polyline(
			_pv([Vector2(0, 0), Vector2(5, 0), Vector2(5, 0), Vector2(10, 0)]), 1.0),
		[Vector2(0, 1), Vector2(5, 1), Vector2(10, 1)])
	check_points("a duplicated endpoint collapses to a 2-point translate",
		BusGeom.offset_polyline(
			_pv([Vector2(0, 0), Vector2(0, 0), Vector2(10, 0), Vector2(10, 0)]), 1.0),
		[Vector2(0, 1), Vector2(10, 1)])
	check_points("all-identical points -> one point, unmoved",
		BusGeom.offset_polyline(_pv([Vector2(4, 4), Vector2(4, 4), Vector2(4, 4)]), 1.0),
		[Vector2(4, 4)])
	check_points("single point -> itself",
		BusGeom.offset_polyline(_pv([Vector2(4, 4)]), 1.0), [Vector2(4, 4)])
	check_points("empty -> empty", BusGeom.offset_polyline(_pv([]), 1.0), [])


func _run_zero_offset_identity() -> void:
	print("-- zero offset is the identity --")
	var spine := _pv([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(3, 4)])
	check_points("zero offset returns the spine unchanged",
		BusGeom.offset_polyline(spine, 0.0),
		[Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(3, 4)])
	# Including at joints sharp enough to bevel — a bevel of zero width would be
	# a duplicated point, and the zero-offset short-circuit is what prevents it.
	check_points("zero offset does not bevel an acute joint",
		BusGeom.offset_polyline(
			_pv([Vector2(0, 0), Vector2(10, 0), Vector2(0.4, 2.8)]), 0.0),
		[Vector2(0, 0), Vector2(10, 0), Vector2(0.4, 2.8)])


func _run_pitch_invariant_through_bends() -> void:
	print("-- ACCEPTANCE 2: constant pitch through bends --")
	# THE property a bus tool needs and the router's rigid translate does not
	# have: two tracks offset by o and o+pitch stay exactly `pitch` apart along
	# EVERY segment, bends included. Measured as the perpendicular distance from
	# one track's segment to the other's, per segment index (safe to index-pair
	# here because neither spine below has a bevelled joint, so both results have
	# one point per spine vertex).
	var spines := {
		"right angle": _pv([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)]),
		"135-degree bend": _pv([Vector2(0, 0), Vector2(10, 0), Vector2(20, 10)]),
		"S-bend, both directions": _pv([
			Vector2(0, 0), Vector2(10, 0), Vector2(20, 10), Vector2(30, 10),
			Vector2(40, 0)]),
		"2-track spine, long run": _pv([
			Vector2(0, 0), Vector2(20, 0), Vector2(20, 15), Vector2(5, 15)]),
	}
	var pitch := 1.0
	for label in spines:
		var spine: PackedVector2Array = spines[label]
		var a := BusGeom.offset_polyline(spine, -pitch * 0.5)
		var b := BusGeom.offset_polyline(spine, pitch * 0.5)
		var sizes_ok := a.size() == spine.size() and b.size() == spine.size()
		check("%s: both tracks keep one point per spine vertex" % label, sizes_ok)
		if not sizes_ok:
			continue
		var worst_err := 0.0
		for i in range(spine.size() - 1):
			# Midpoint of A's segment i, measured against B's segment i line.
			var mid: Vector2 = (a[i] + a[i + 1]) * 0.5
			worst_err = maxf(worst_err, absf(_dist_to_line(mid, b[i], b[i + 1]) - pitch))
		check_near("%s: worst pitch error over all segments (want %.1f apart)"
			% [label, pitch], worst_err, 0.0, DERIVED_EPS)

	# THE FOIL. The router's approach on the right-angle spine: both tracks'
	# second segments land on x = 10, i.e. pitch 1.0 before the bend and pitch
	# ZERO after it — two nets on the same copper. Asserted red on purpose, so
	# the test above is demonstrably measuring something the naive method fails.
	var rspine: PackedVector2Array = spines["right angle"]
	var ra := _router_rigid_translate(rspine, -0.5)
	var rb := _router_rigid_translate(rspine, 0.5)
	var seg0 := _dist_to_line((ra[0] + ra[1]) * 0.5, rb[0], rb[1])
	var seg1 := _dist_to_line((ra[1] + ra[2]) * 0.5, rb[1], rb[2])
	check_near("rigid translate: correct pitch BEFORE the bend", seg0, 1.0)
	check_near("rigid translate: pitch collapses to 0 AFTER the bend (the bug)",
		seg1, 0.0)


func _run_pitch_between() -> void:
	print("-- S1: per-adjacent-pair pitch (centreline rule) --")
	# w/2 + clearance + w/2, per kicad_io.py:243-247.
	check_near("uniform 0.3mm traces at 0.2mm clearance -> 0.5",
		BusGeom.pitch_between(0.3, 0.3, 0.2), 0.5)
	# Mixed: a 1.0mm track beside a 0.2mm track needs 0.5 + 0.2 + 0.1 = 0.8,
	# where the uniform formula (router.py:1646) would have used one number for
	# both gaps and been wrong on at least one of them.
	check_near("mixed 1.0/0.2 at 0.2 -> 0.8",
		BusGeom.pitch_between(1.0, 0.2, 0.2), 0.8)
	check_near("pitch is symmetric in its two widths",
		BusGeom.pitch_between(0.2, 1.0, 0.2), BusGeom.pitch_between(1.0, 0.2, 0.2))
	# Zero clearance is a real answer (a board declaring no rule): copper that
	# touches but does not overlap.
	check_near("zero clearance -> touching copper, not overlapping",
		BusGeom.pitch_between(0.3, 0.3, 0.0), 0.3)
	# Negatives clamp rather than shrink the pitch below the copper — the
	# superset invariant grid.py:104-107 states for the same clamp.
	check_near("negative width clamps to zero, does not subtract",
		BusGeom.pitch_between(-1.0, 0.3, 0.2), 0.35)
	check_near("negative clearance clamps to zero, does not subtract",
		BusGeom.pitch_between(0.3, 0.3, -5.0), 0.3)


func _run_cumulative_offsets() -> void:
	print("-- S1+S2: cumulative track offsets, caller's order --")
	check("empty widths -> empty", BusGeom.cumulative_offsets([], 0.2).is_empty())
	check_near("one track sits on the spine",
		float(BusGeom.cumulative_offsets([0.3], 0.2)[0]), 0.0)

	# UNIFORM: three 0.3mm tracks at 0.2mm clearance. pitch = 0.5 for both gaps,
	# positions 0 / 0.5 / 1.0, centre 0.5 -> [-0.5, 0, +0.5]. This is exactly the
	# router's (i - (n-1)/2)*spacing for spacing 0.5 — the two agree wherever the
	# router's uniform assumption actually holds.
	var uni: Array = BusGeom.cumulative_offsets([0.3, 0.3, 0.3], 0.2)
	check_near("uniform trio: track 0", float(uni[0]), -0.5)
	check_near("uniform trio: track 1", float(uni[1]), 0.0)
	check_near("uniform trio: track 2", float(uni[2]), 0.5)
	var quad: Array = BusGeom.cumulative_offsets([0.3, 0.3, 0.3, 0.3], 0.2)
	for i in range(4):
		check_near("uniform quad track %d matches (i-(n-1)/2)*pitch" % i,
			float(quad[i]), (float(i) - 1.5) * 0.5)

	# MIXED: [1.0, 0.2, 0.2] at 0.2. gap0 = 0.5+0.2+0.1 = 0.8 ; gap1 = 0.1+0.2+0.1
	# = 0.4. positions 0 / 0.8 / 1.2, centre 0.6 -> [-0.6, +0.2, +0.6].
	var mixed: Array = BusGeom.cumulative_offsets([1.0, 0.2, 0.2], 0.2)
	check_near("mixed trio: fat track", float(mixed[0]), -0.6)
	check_near("mixed trio: middle track", float(mixed[1]), 0.2)
	check_near("mixed trio: outer track", float(mixed[2]), 0.6)
	# Composition: each adjacent GAP is exactly its own pitch_between.
	check_near("gap 0 == pitch_between(1.0, 0.2, 0.2)",
		float(mixed[1]) - float(mixed[0]), BusGeom.pitch_between(1.0, 0.2, 0.2))
	check_near("gap 1 == pitch_between(0.2, 0.2, 0.2)",
		float(mixed[2]) - float(mixed[1]), BusGeom.pitch_between(0.2, 0.2, 0.2))

	# CALLER'S ORDER IS THE OUTPUT ORDER (T11). Reversing the width list mirrors
	# the layout instead of reproducing it: [0.2,0.2,1.0] gives gaps 0.4 then 0.8,
	# positions 0 / 0.4 / 1.2, centre 0.6 -> [-0.6, -0.2, +0.6], which is the
	# negated reverse of the [-0.6,+0.2,+0.6] above. If this function re-sorted
	# its input the way route_bus re-sorts nets (router.py:1624-1631), the two
	# calls would return the SAME array and this would fail.
	var rev: Array = BusGeom.cumulative_offsets([0.2, 0.2, 1.0], 0.2)
	for i in range(3):
		check_near("reversed widths mirror, not repeat, at track %d" % i,
			float(rev[i]), -float(mixed[2 - i]))
	check("reversed order is NOT the same layout",
		absf(float(rev[1]) - float(mixed[1])) > EPS)

	# End to end: feed the offsets to offset_polyline and the tracks come out at
	# the pitches asked for, through a bend.
	var spine := _pv([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)])
	var tracks: Array = []
	for o in mixed:
		tracks.append(BusGeom.offset_polyline(spine, float(o)))
	var t0: PackedVector2Array = tracks[0]
	var t1: PackedVector2Array = tracks[1]
	check_near("mixed bundle holds gap 0 on the post-bend segment",
		_dist_to_line((t0[1] + t0[2]) * 0.5, t1[1], t1[2]),
		BusGeom.pitch_between(1.0, 0.2, 0.2), DERIVED_EPS)


func _run_design_rule_clearance() -> void:
	print("-- S1: design_rule_clearance mirrors the width reader --")
	var data = PCBData.new()
	data.design_rules = {}
	check_near("no design_rules block -> 0.0 (no rule)", data.design_rule_clearance(), 0.0)
	check_near("...same as the width reader on the same board",
		data.design_rule_trace_width(), 0.0)

	data.design_rules = {"trace_width_mm": 0.3}
	check_near("block without clearance_mm -> 0.0", data.design_rule_clearance(), 0.0)

	data.design_rules = {"clearance_mm": 0.0, "trace_width_mm": 0.0}
	check_near("explicit zero clearance -> 0.0", data.design_rule_clearance(), 0.0)
	check_near("...width reader agrees on explicit zero", data.design_rule_trace_width(), 0.0)

	data.design_rules = {"clearance_mm": -0.5, "trace_width_mm": -0.5}
	check_near("negative clearance is not an answer -> 0.0",
		data.design_rule_clearance(), 0.0)
	check_near("...width reader agrees on negative", data.design_rule_trace_width(), 0.0)

	data.design_rules = {"clearance_mm": 0.2, "trace_width_mm": 0.3}
	check_near("declared clearance is returned verbatim",
		data.design_rule_clearance(), 0.2)
	# The pair a bus needs, read off a real board block.
	check_near("board rules compose into the bundle pitch",
		BusGeom.pitch_between(data.design_rule_trace_width(),
			data.design_rule_trace_width(), data.design_rule_clearance()), 0.5)

	# Non-numeric junk in the block must not throw — from_board_dict carries
	# design_rules verbatim, so an Extra sibling of any type can be sitting there.
	data.design_rules = {"clearance_mm": "0.4"}
	check_near("numeric string is coerced, same as the width reader does",
		data.design_rule_clearance(), 0.4)
