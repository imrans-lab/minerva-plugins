extends SceneTree
## Pins the trace-geometry library — the one home for point/segment/polyline
## arithmetic every trace, zone and bus pick reads.
##
## EVERY EXPECTED VALUE BELOW IS HAND-DERIVED, and the derivation is written out
## beside it. Numbers pasted back out of the implementation would pin whatever it
## happens to do, including its bugs; the arithmetic here can be checked with a
## calculator and never needs the code run to know the answer.
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout> (same convention as
## every suite here — see test_routing_workspace_model.gd's header).

const Geo := preload("res://../../minerva-plugins/pcb/ui/model/pcb_trace_geometry.gd")

## Tolerance for a coordinate comparison, in mm: far below anything a board
## cares about and far above float32 noise at the single-digit magnitudes here.
const EPS := 1e-6

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Trace geometry: segment, polyline, gap, length, axis, ends, translate, bounds ===\n")
	_run_point_vs_segment()
	_run_point_vs_polyline()
	_run_segment_vs_segment()
	_run_segment_vs_polyline_and_rect()
	_run_length_and_axis()
	_run_ends_translate_bounds()
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


func check_near(desc: String, got: float, want: float, tol := EPS) -> void:
	if absf(got - want) <= tol:
		_pass += 1
		print("  PASS: %s (%.9f)" % [desc, got])
	else:
		_fail += 1
		printerr("  FAIL: %s — want %.9f, got %.9f" % [desc, want, got])


func check_vec(desc: String, got: Vector2, want: Vector2) -> void:
	if absf(got.x - want.x) <= EPS and absf(got.y - want.y) <= EPS:
		_pass += 1
		print("  PASS: %s (%s)" % [desc, str(got)])
	else:
		_fail += 1
		printerr("  FAIL: %s — want %s, got %s" % [desc, str(want), str(got)])


func _pv(arr: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in arr:
		out.append(v)
	return out


# ── 1. point vs segment ──────────────────────────────────────────────────────

func _run_point_vs_segment() -> void:
	print("-- 1. point vs segment --")
	# Segment (0,0)->(10,0) along +x.
	var a := Vector2(0, 0)
	var b := Vector2(10, 0)

	# BESIDE: p=(3,4). Projection parameter t = (p-a).(b-a)/|b-a|^2 = 30/100 = 0.3,
	# foot = (3,0); distance = 4 (the 3-4-5 triangle's short leg).
	check_vec("beside: foot of (3,4) on the x-axis segment is (3,0)",
		Geo.closest_point_on_segment(Vector2(3, 4), a, b), Vector2(3, 0))
	check_near("beside: distance is 4", Geo.distance_to_segment(Vector2(3, 4), a, b), 4.0)

	# BEYOND: p=(13,4). t = 130/100 = 1.3, clamped to 1 -> foot = b = (10,0);
	# distance = sqrt(3^2 + 4^2) = 5.
	check_vec("beyond the end: foot of (13,4) clamps to (10,0)",
		Geo.closest_point_on_segment(Vector2(13, 4), a, b), Vector2(10, 0))
	check_near("beyond the end: distance is 5", Geo.distance_to_segment(Vector2(13, 4), a, b), 5.0)
	# BEFORE: p=(-3,4). t = -30/100 < 0, clamped to 0 -> foot = a; distance 5.
	check_vec("before the start: foot of (-3,4) clamps to (0,0)",
		Geo.closest_point_on_segment(Vector2(-3, 4), a, b), Vector2(0, 0))

	# ON: p=(7,0). t = 70/100 = 0.7, foot = (7,0), distance 0.
	check_vec("on the segment: (7,0) is its own foot",
		Geo.closest_point_on_segment(Vector2(7, 0), a, b), Vector2(7, 0))
	check_near("on the segment: distance is 0", Geo.distance_to_segment(Vector2(7, 0), a, b), 0.0)

	# DIAGONAL segment (0,0)->(4,4), p=(4,0). t = (4*4 + 0*4)/32 = 0.5, foot =
	# (2,2), distance = sqrt(2^2 + 2^2) = 2*sqrt(2) = 2.828427...
	check_vec("diagonal: foot of (4,0) on (0,0)->(4,4) is (2,2)",
		Geo.closest_point_on_segment(Vector2(4, 0), Vector2(0, 0), Vector2(4, 4)), Vector2(2, 2))
	check_near("diagonal: distance is 2*sqrt(2)",
		Geo.distance_to_segment(Vector2(4, 0), Vector2(0, 0), Vector2(4, 4)), 2.0 * sqrt(2.0))

	# ZERO-LENGTH segment (5,5)->(5,5): answers its start whatever p is; distance
	# from (8,9) = sqrt(3^2 + 4^2) = 5.
	check_vec("zero-length segment answers its start",
		Geo.closest_point_on_segment(Vector2(8, 9), Vector2(5, 5), Vector2(5, 5)), Vector2(5, 5))
	check_near("zero-length segment: distance is to that point",
		Geo.distance_to_segment(Vector2(8, 9), Vector2(5, 5), Vector2(5, 5)), 5.0)

	# DEGENERATE FLOOR: segment (0,0)->(0.005,0) has |ab|^2 = 2.5e-5, below the
	# legacy floor 1e-4 but above 0. p = (0.004, 1). With the default floor it
	# projects: t = 0.004*0.005/2.5e-5 = 0.8, foot (0.004, 0). With the legacy
	# floor it collapses to the start (0,0).
	var short_a := Vector2(0, 0)
	var short_b := Vector2(0.005, 0)
	check_vec("a 5-micron segment still projects under the default floor",
		Geo.closest_point_on_segment(Vector2(0.004, 1), short_a, short_b), Vector2(0.004, 0))
	check_vec("...and collapses to its start under the legacy 0.01 mm floor",
		Geo.closest_point_on_segment(Vector2(0.004, 1), short_a, short_b,
			Geo.LEGACY_DEGENERATE_LEN_SQ), Vector2(0, 0))


# ── 2. point vs polyline ─────────────────────────────────────────────────────

func _run_point_vs_polyline() -> void:
	print("-- 2. point vs polyline --")
	# L-shaped polyline (0,0)->(10,0)->(10,10): segment 0 along +x, segment 1 up.
	var pts := _pv([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)])

	# INSIDE tolerance: p=(5,0.4) is 0.4 above segment 0; tol 0.5 -> hit.
	check("(5,0.4) is within 0.5 of the L", Geo.point_near_polyline(pts, Vector2(5, 0.4), 0.5))
	# OUTSIDE tolerance: same p, tol 0.3 -> 0.4 > 0.3, miss.
	check("(5,0.4) is NOT within 0.3 of the L", not Geo.point_near_polyline(pts, Vector2(5, 0.4), 0.3))
	# EXACTLY ON tolerance: p=(5,0.5), tol 0.5 -> inclusive hit.
	check("a distance equal to the tolerance is a hit (inclusive)",
		Geo.point_near_polyline(pts, Vector2(5, 0.5), 0.5))
	# Near the SECOND segment only: p=(10.3, 5) is 0.3 right of segment 1 and
	# sqrt(0.3^2 + 5^2) ~ 5.009 from segment 0's end.
	check("(10.3,5) is within 0.5 of the second segment",
		Geo.point_near_polyline(pts, Vector2(10.3, 5), 0.5))
	# The far corner region: p=(0,10) is 10 from (0,0) and 10 from (10,10) —
	# nearest foot is (0,0) on segment 0 (t clamps to 0) or (10,10) on segment 1
	# (t clamps to 1), both at distance 10. tol 9.99 misses.
	check("(0,10) sits 10 from both arms and misses at tol 9.99",
		not Geo.point_near_polyline(pts, Vector2(0, 10), 9.99))

	# closest_on_polyline: p=(7,3). Segment 0 foot (7,0) at distance 3; segment
	# 1 foot (10,3) also at distance 3 — A TIE, and the earlier segment wins.
	var near: Dictionary = Geo.closest_on_polyline(pts, Vector2(7, 3))
	check("closest on a tie names the EARLIER segment (0)", int(near["segment"]) == 0)
	check_vec("closest on a tie is the earlier segment's foot (7,0)", near["point"], Vector2(7, 0))
	check_near("closest on a tie reports distance 3", float(near["distance"]), 3.0)
	# p=(12,8): segment 1 foot (10,8) at distance 2; segment 0 foot (10,0) at
	# sqrt(4+64) ~ 8.246. Segment 1 wins outright.
	near = Geo.closest_on_polyline(pts, Vector2(12, 8))
	check("(12,8) is nearest segment 1", int(near["segment"]) == 1)
	check_vec("(12,8) foots at (10,8)", near["point"], Vector2(10, 8))

	# CLOSED walk: unit square (0,0),(1,0),(1,1),(0,1). p=(-0.2, 0.5) is 0.2 left
	# of the CLOSING edge (0,1)->(0,0), which only exists when closed. Open, the
	# nearest edge is (0,0)->(1,0) or (1,1)->(0,1) at distance ~0.539 (foot at a
	# corner: sqrt(0.2^2 + 0.5^2)).
	var square := _pv([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	check("closed square: (-0.2,0.5) is within 0.25 of the closing edge",
		Geo.point_near_polyline(square, Vector2(-0.2, 0.5), 0.25, true))
	check("open square: the same point is NOT within 0.25 (no closing edge)",
		not Geo.point_near_polyline(square, Vector2(-0.2, 0.5), 0.25, false))
	var on_close: Dictionary = Geo.closest_on_polyline(square, Vector2(-0.2, 0.5), true)
	check("closed square: the closing edge is segment index 3 (last point -> first)",
		int(on_close["segment"]) == 3)
	check_vec("closed square: foot on the closing edge is (0,0.5)", on_close["point"], Vector2(0, 0.5))

	# EMPTY / SINGLE: no segment to name.
	var none: Dictionary = Geo.closest_on_polyline(PackedVector2Array(), Vector2(3, 3))
	check("empty polyline: segment -1, point is p itself",
		int(none["segment"]) == -1 and none["point"] == Vector2(3, 3))
	var one: Dictionary = Geo.closest_on_polyline(_pv([Vector2(1, 1)]), Vector2(4, 5))
	# distance (1,1)->(4,5) = sqrt(9+16) = 5.
	check("single point: segment -1, distance 5", int(one["segment"]) == -1
		and absf(float(one["distance"]) - 5.0) <= EPS)
	check("a single point never hits an open near-test",
		not Geo.point_near_polyline(_pv([Vector2(1, 1)]), Vector2(1, 1), 1.0))


# ── 3. segment vs segment ────────────────────────────────────────────────────

func _run_segment_vs_segment() -> void:
	print("-- 3. segment vs segment --")
	# PARALLEL: (0,0)->(10,0) and (2,3)->(8,3): 3 apart everywhere. Closest
	# approach is at an endpoint of the second: a0=(0,0) projects to (2,3) at
	# sqrt(4+9); a1=(10,0) to (8,3) likewise; b0=(2,3) projects to (2,0) at 3;
	# b1=(8,3) to (8,0) at 3. First strict minimum found is b0: a=(2,0), b=(2,3).
	var g: Dictionary = Geo.segment_gap(Vector2(0, 0), Vector2(10, 0), Vector2(2, 3), Vector2(8, 3))
	check_near("parallel: gap is 3", float(g["distance"]), 3.0)
	check_vec("parallel: witness on the first segment is (2,0)", g["a"], Vector2(2, 0))
	check_vec("parallel: witness on the second is (2,3)", g["b"], Vector2(2, 3))

	# CROSSING: (0,0)->(10,10) and (0,10)->(10,0) cross at (5,5); distance 0.
	g = Geo.segment_gap(Vector2(0, 0), Vector2(10, 10), Vector2(0, 10), Vector2(10, 0))
	check_near("crossing: gap is 0", float(g["distance"]), 0.0)
	check_vec("crossing: both witnesses are the crossing (5,5)", g["a"], Vector2(5, 5))
	check_vec("crossing: ...and b too", g["b"], Vector2(5, 5))

	# TOUCHING at an end: (0,0)->(10,0) and (10,0)->(10,10) share (10,0). Either
	# the intersection test reports it or a1 projects onto b at distance 0.
	g = Geo.segment_gap(Vector2(0, 0), Vector2(10, 0), Vector2(10, 0), Vector2(10, 10))
	check_near("touching at a shared end: gap is 0", float(g["distance"]), 0.0)
	check_vec("touching: the witness is the shared point", g["a"], Vector2(10, 0))

	# DISJOINT, SKEW: (0,0)->(4,0) and (6,1)->(6,5). Closest is a1=(4,0) to b0=(6,1):
	# sqrt(2^2 + 1^2) = sqrt(5) = 2.2360679...  (b0 projects onto the first at
	# t = 6/4 clamped to 1 -> (4,0), same pair; a1's projection onto the second
	# is t = (4-6)*0 + (0-1)*4 / 16 < 0 -> (6,1).)
	g = Geo.segment_gap(Vector2(0, 0), Vector2(4, 0), Vector2(6, 1), Vector2(6, 5))
	check_near("disjoint skew: gap is sqrt(5)", float(g["distance"]), sqrt(5.0))
	check_vec("disjoint skew: a = (4,0)", g["a"], Vector2(4, 0))
	check_vec("disjoint skew: b = (6,1)", g["b"], Vector2(6, 1))

	# AXIS-ALIGNED variant, collinear OVERLAP: (0,0)->(10,0) and (6,0)->(14,0)
	# overlap on x in [6,10]; the shared box is that span at y=0, centre (8,0).
	var ag: Dictionary = Geo.axis_aligned_segment_gap(
		Vector2(0, 0), Vector2(10, 0), Vector2(6, 0), Vector2(14, 0))
	check_near("axis-aligned overlap: gap is 0", float(ag["distance"]), 0.0)
	check_vec("axis-aligned overlap: 'at' is the overlap's middle (8,0)", ag["at"], Vector2(8, 0))
	# The general test on the same input measures 0 too, but its witness is an
	# ENDPOINT: the first segment's ends are projected first — a0=(0,0) lands
	# at (6,0), distance 6; a1=(10,0) lands on itself, distance 0 — and a1 is
	# the first strict minimum, so the witness is (10,0), never the middle.
	g = Geo.segment_gap(Vector2(0, 0), Vector2(10, 0), Vector2(6, 0), Vector2(14, 0))
	check_near("general overlap: gap is 0 as well", float(g["distance"]), 0.0)
	check_vec("general overlap: witness is the endpoint a1=(10,0), not the middle", g["a"], Vector2(10, 0))
	# AXIS-ALIGNED, disjoint: (0,0)->(10,0) and (3,2)->(3,7). Boxes: x [0,10] vs
	# [3,3] overlap, y [0,0] vs [2,7] do NOT. Endpoint walk: a0 (0,0) -> (3,2) at
	# sqrt(13); a1 (10,0) -> (3,2) at sqrt(53); b0 (3,2) -> (3,0) at 2; b1 (3,7)
	# -> (3,0) at 7. Minimum 2, a = (3,2), b = (3,0), at = midpoint (3,1).
	ag = Geo.axis_aligned_segment_gap(Vector2(0, 0), Vector2(10, 0), Vector2(3, 2), Vector2(3, 7))
	check_near("axis-aligned disjoint: gap is 2", float(ag["distance"]), 2.0)
	check_vec("axis-aligned disjoint: 'at' is the gap's midpoint (3,1)", ag["at"], Vector2(3, 1))
	check_vec("axis-aligned disjoint: a is the probing endpoint (3,2)", ag["a"], Vector2(3, 2))
	check_vec("axis-aligned disjoint: b is its foot (3,0)", ag["b"], Vector2(3, 0))


# ── 4. segment vs polyline, polyline vs rect ─────────────────────────────────

func _run_segment_vs_polyline_and_rect() -> void:
	print("-- 4. segment vs polyline, polyline vs rect --")
	# L (0,0)->(10,0)->(10,10) against the vertical segment (13,2)->(13,6):
	# to segment 0 the nearest pair is (13,2)->(10,0) at sqrt(13); to segment 1
	# it is 3 (b0=(13,2) foots at (10,2)). Minimum 3 with a on the probe segment.
	var l := _pv([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)])
	var g: Dictionary = Geo.segment_to_polyline_gap(l, Vector2(13, 2), Vector2(13, 6))
	check_near("segment to L: gap is 3", float(g["distance"]), 3.0)
	check_vec("segment to L: a is on the probe segment (13,2)", g["a"], Vector2(13, 2))
	check_vec("segment to L: b is on the L (10,2)", g["b"], Vector2(10, 2))
	var empty_gap: Dictionary = Geo.segment_to_polyline_gap(_pv([Vector2(1, 1)]), Vector2(0, 0), Vector2(1, 0))
	check("a polyline with no segment answers INF", float(empty_gap["distance"]) == INF)

	# polyline_touches_rect with box [2,8]x[2,8]:
	#  * a vertex inside: (5,5) -> hit.
	check("a vertex inside the box touches", Geo.polyline_touches_rect(
		_pv([Vector2(5, 5), Vector2(20, 20)]), Rect2(2, 2, 6, 6)))
	#  * a segment crossing with both ends outside: (0,5)->(10,5) crosses the
	#    left edge x=2 and the right edge x=8 -> hit.
	check("a segment crossing the box with both ends outside touches",
		Geo.polyline_touches_rect(_pv([Vector2(0, 5), Vector2(10, 5)]), Rect2(2, 2, 6, 6)))
	#  * entirely outside: (0,9)->(10,9) runs above y=8 -> miss.
	check("a segment passing above the box misses",
		not Geo.polyline_touches_rect(_pv([Vector2(0, 9), Vector2(10, 9)]), Rect2(2, 2, 6, 6)))
	#  * a big open triangle around the box, no vertex inside and no edge
	#    crossing: (0,0),(20,0),(0,20) — the hypotenuse x+y=20 clears the far
	#    corner (8,8) — miss (the interior case is the caller's).
	check("an outline enclosing the box does not touch it (interior is not tested here)",
		not Geo.polyline_touches_rect(
			_pv([Vector2(0, 0), Vector2(20, 0), Vector2(0, 20), Vector2(0, 0)]), Rect2(2, 2, 6, 6)))


# ── 5. length and axis ───────────────────────────────────────────────────────

func _run_length_and_axis() -> void:
	print("-- 5. length and axis --")
	# (0,0)->(3,4)->(3,10): 5 + 6 = 11.
	check_near("length of the 3-4-5 leg plus a 6 run is 11",
		Geo.length(_pv([Vector2(0, 0), Vector2(3, 4), Vector2(3, 10)])), 11.0)
	check_near("a single point has length 0", Geo.length(_pv([Vector2(2, 2)])), 0.0)
	# Manhattan (1,2)->(4,-2): |3| + |-4| = 7.
	check_near("Manhattan distance (1,2)->(4,-2) is 7",
		Geo.manhattan_distance(Vector2(1, 2), Vector2(4, -2)), 7.0)

	# Axis checks on a DIAGONAL (3,3): both components non-zero -> not aligned.
	check("(3,3) is a diagonal", not Geo.is_axis_aligned(Vector2(3, 3)))
	check("(0,-5) is vertical", Geo.is_axis_aligned(Vector2(0, -5)))
	check("(7,0) is horizontal", Geo.is_axis_aligned(Vector2(7, 0)))
	# A 1e-7 skew is still a diagonal: exact, not approx.
	check("a 1e-7 skew is a diagonal (exact zero, not approx)",
		not Geo.is_axis_aligned(Vector2(5, 1e-7)))
	check_vec("axis_unit of (0,-5) is exactly (0,-1)", Geo.axis_unit(Vector2(0, -5)), Vector2(0, -1))
	check_vec("axis_unit of (7,0) is exactly (1,0)", Geo.axis_unit(Vector2(7, 0)), Vector2(1, 0))

	# snap_to_axis from (2,2): (9,5) has |dx|=7 >= |dy|=3 -> horizontal (9,2);
	# (4,9) has |dx|=2 < |dy|=7 -> vertical (2,9); the exact diagonal (6,6)
	# has |dx| == |dy| and the tie goes horizontal: (6,2).
	check_vec("snap: (9,5) from (2,2) goes horizontal to (9,2)",
		Geo.snap_to_axis(Vector2(2, 2), Vector2(9, 5)), Vector2(9, 2))
	check_vec("snap: (4,9) from (2,2) goes vertical to (2,9)",
		Geo.snap_to_axis(Vector2(2, 2), Vector2(4, 9)), Vector2(2, 9))
	check_vec("snap: an exact diagonal ties to horizontal (6,2)",
		Geo.snap_to_axis(Vector2(2, 2), Vector2(6, 6)), Vector2(6, 2))

	# advance_along_axis with the run (0,0)->(5,0) (unit +x) and station (5,0):
	# p=(9,3): along = (4,3).(1,0) = 4 > 0 -> (5,0) + 4*(1,0) = (9,0).
	# p=(3,3): along = -2 <= 0 -> the station itself.
	# p=(5,7): along = 0 -> still the station (not strictly ahead).
	check_vec("advance: (9,3) lands ahead at (9,0)",
		Geo.advance_along_axis(Vector2(0, 0), Vector2(5, 0), Vector2(9, 3)), Vector2(9, 0))
	check_vec("advance: (3,3) is behind and answers the station",
		Geo.advance_along_axis(Vector2(0, 0), Vector2(5, 0), Vector2(3, 3)), Vector2(5, 0))
	check_vec("advance: level with the station is not ahead",
		Geo.advance_along_axis(Vector2(0, 0), Vector2(5, 0), Vector2(5, 7)), Vector2(5, 0))
	# A vertical run (4,10)->(4,6) (unit (0,-1)), p=(1,1): along = (-3,-5).(0,-1)
	# = 5 -> (4,6) + 5*(0,-1) = (4,1).
	check_vec("advance: a downward run projects (1,1) to (4,1)",
		Geo.advance_along_axis(Vector2(4, 10), Vector2(4, 6), Vector2(1, 1)), Vector2(4, 1))


# ── 6. ends, translate, bounds ───────────────────────────────────────────────

func _run_ends_translate_bounds() -> void:
	print("-- 6. ends, translate, bounds --")
	var pts := _pv([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(20, 10)])
	# START: (0.005, -0.005) is sqrt(2)*0.005 ~ 0.00707 from (0,0) -> within 0.01.
	check("a point 7 microns from the start is the start (index 0)",
		Geo.end_index_at(pts, Vector2(0.005, -0.005), 0.01) == 0)
	# END: (20.008, 10) is 0.008 from (20,10) -> index 3.
	check("a point 8 microns from the end is the end (index 3)",
		Geo.end_index_at(pts, Vector2(20.008, 10), 0.01) == 3)
	# MID-POLYLINE VERTEX: (10,0) is a vertex but not an end -> -1.
	check("an interior vertex is not an end", Geo.end_index_at(pts, Vector2(10, 0), 0.01) == -1)
	# JUST OUTSIDE: (0.012, 0) is 0.012 from the start -> -1 at tol 0.01.
	check("12 microns off the start is not the start at tol 0.01",
		Geo.end_index_at(pts, Vector2(0.012, 0), 0.01) == -1)
	# (0, 0.009) is 0.009 from the start: inside 0.01 by a margin float32 cannot
	# blur (an exact-tolerance probe would ride on the rounding of 0.01).
	check("9 microns off the start is still the start",
		Geo.end_index_at(pts, Vector2(0, 0.009), 0.01) == 0)
	check("an empty polyline has no ends", Geo.end_index_at(PackedVector2Array(), Vector2.ZERO, 1.0) == -1)

	# TRANSLATE by (2,-3): each point shifts; the input is left alone.
	var moved := Geo.translated(pts, Vector2(2, -3))
	check("translate keeps the point count", moved.size() == 4)
	check_vec("translate: (0,0) -> (2,-3)", moved[0], Vector2(2, -3))
	check_vec("translate: (20,10) -> (22,7)", moved[3], Vector2(22, 7))
	check_vec("translate leaves the input untouched", pts[0], Vector2(0, 0))

	# BOUNDS of (3,4),(-1,8),(5,2): min (-1,2), max (5,8) -> position (-1,2),
	# size (6,6). With margin 0.5: position (-1.5,1.5), size (7,7).
	var cloud := _pv([Vector2(3, 4), Vector2(-1, 8), Vector2(5, 2)])
	var box := Geo.bounds(cloud)
	check_vec("bounds position is the min corner (-1,2)", box.position, Vector2(-1, 2))
	check_vec("bounds size is (6,6)", box.size, Vector2(6, 6))
	var padded := Geo.bounds(cloud, 0.5)
	check_vec("padded bounds position is (-1.5,1.5)", padded.position, Vector2(-1.5, 1.5))
	check_vec("padded bounds size is (7,7)", padded.size, Vector2(7, 7))
	check("empty input gives the empty rect", Geo.bounds(PackedVector2Array()) == Rect2())
	var dot := Geo.bounds(_pv([Vector2(4, 4)]))
	check("a single point is a zero-size box at itself",
		dot.position == Vector2(4, 4) and dot.size == Vector2.ZERO)
