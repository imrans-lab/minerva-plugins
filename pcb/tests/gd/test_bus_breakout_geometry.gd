extends SceneTree
## Pins pcb_bus_geometry.bundle_routes — the pad-to-pad half of the bus
## geometry: the parallel bundle plus the axis-aligned breakout legs that carry
## each net from its source pad into its lane and back out to its target pad.
##
## Sibling of test_pcb_bus_geometry.gd, which pins the lane arithmetic
## (offset_polyline / pitch_between / cumulative_offsets) underneath this. Kept
## as its own suite rather than grown onto that one so its assertion pin stays
## the number a trustworthy run measured.
##
## EVERY EXPECTED POINT BELOW IS HAND-DERIVED, and the derivation is written out
## beside it. The bundle lanes come from the offsets that suite already pins; the
## stations, the corners and the legs are worked out here from the offsets, the
## pad positions and the pitch rule, so a reviewer can check any coordinate with
## a calculator and never has to run the code to know what it should be.
##
## A THIRD oracle runs alongside them and depends on no expected coordinate at
## all: _run_geometry_invariants routes both shapes again — the bend mirrored,
## so the frame signs are exercised both ways — and asserts, with its own
## segment-overlap and segment-gap tests, that nothing is diagonal, that every
## route lands on its own two pads, that no two nets share a point, and that no
## two nets come closer than their own pitch. That check knows nothing of
## departure stations or ordering rules; it fails on copper that crosses, or
## merely crowds, however the geometry arrived at it.
##
## TWO CLASSES OF "NO" are pinned separately below. check_refused is for the
## UNBUILDABLE set — nothing could be drawn, so nothing comes back.
## check_bad_but_buildable is for the rest: the rule broke, the geometry came
## back anyway, and the caller is expected to land it and correct it. A change
## that collapsed the second class into the first would still produce the right
## words, and fails on the missing polylines.
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout>.

const BusGeom := preload("res://../../minerva-plugins/pcb/ui/model/pcb_bus_geometry.gd")

## Tolerance for a coordinate comparison, in mm. Looser than the sibling suite's
## 1e-6 for the reason its own DERIVED_EPS records: Vector2 is 32-bit float
## regardless of build precision, and these points are built through an offset
## normal and a miter at magnitudes past 100mm, where one ulp is already ~1e-5.
## 1e-4 mm is 0.1 micron — four orders below any fabrication tolerance, so it
## still fails every real geometry bug (a station off by one track misses by
## 0.5mm, a lane off by one by the same).
const EPS := 1e-4

## Tolerance for a CLEARANCE measurement, in mm — the same one micron the
## module itself allows, and for the same reason: a lane pair laid out exactly
## one pitch apart measures 0.799999 against 0.800000 in 32-bit float. Named
## separately from EPS because it answers a different question (is this copper
## legal) with a different consequence for being wrong.
const MEASURE_EPS := 1e-3

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Bus breakout geometry: pad-to-pad routes ===\n")
	_run_straight_bundle()
	_run_mixed_width_bend()
	_run_geometry_invariants()
	_run_crossing_refusals()
	_run_clearance_refusals()
	_run_structural_refusals()
	_run_pads_already_on_their_lanes()
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
		print("  PASS: %s (%.6f)" % [desc, got])
	else:
		_fail += 1
		printerr("  FAIL: %s — want %.6f, got %.6f" % [desc, want, got])


## Assert a route equals a hand-derived point list, reporting BOTH on failure —
## a geometry failure is unreadable without the actual numbers.
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


## Assert the call was UNBUILDABLE: no geometry could exist, so none came back,
## and the message SAYS what is wrong — every fragment must appear in it. Naming
## the offending nets is half the contract, so a refusal that fires with the
## wrong story still fails here.
func check_refused(desc: String, result: Dictionary, fragments: Array) -> void:
	var message := str(result.get("error", ""))
	var ok := not bool(result.get("ok", true)) \
		and not bool(result.get("buildable", true)) \
		and not result.has("polylines")
	for fragment in fragments:
		if not message.contains(str(fragment)):
			ok = false
	if ok:
		_pass += 1
		print("  PASS: %s — \"%s\"" % [desc, message])
	else:
		_fail += 1
		printerr("  FAIL: %s\n    got: ok=%s buildable=%s error=\"%s\"" % [
			desc, str(result.get("ok")), str(result.get("buildable")), message])


## Assert the call was BAD BUT BUILDABLE: `ok` false because a rule broke, but
## the geometry came back anyway — one usable polyline per net — with the broken
## rules itemised in `findings` and `error` carrying the first one's words.
##
## The distinction is the whole point of the two helpers: a caller cannot
## correct copper that was never drawn, so a rule that CAN be drawn through must
## hand back what it drew. A regression that turned one of these back into a
## bare refusal would still satisfy the fragments and fails here on the geometry.
func check_bad_but_buildable(desc: String, result: Dictionary, routes: int,
		fragments: Array) -> void:
	var message := str(result.get("error", ""))
	var polylines: Array = result.get("polylines", [])
	var findings: Array = result.get("findings", [])
	var ok := not bool(result.get("ok", true)) \
		and bool(result.get("buildable", false)) \
		and polylines.size() == routes \
		and not findings.is_empty() \
		and str((findings[0] as Dictionary).get("message", "")) == message
	for poly in polylines:
		if (poly as PackedVector2Array).size() < 2:
			ok = false
	for fragment in fragments:
		if not message.contains(str(fragment)):
			ok = false
	if ok:
		_pass += 1
		print("  PASS: %s — %d route(s), %d finding(s), \"%s\"" % [
			desc, polylines.size(), findings.size(), message])
	else:
		_fail += 1
		printerr("  FAIL: %s\n    got: ok=%s buildable=%s routes=%d findings=%d error=\"%s\"" % [
			desc, str(result.get("ok")), str(result.get("buildable")),
			polylines.size(), findings.size(), message])


func _pv(arr: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in arr:
		out.append(p)
	return out


func _route(result: Dictionary, index: int) -> PackedVector2Array:
	var polylines: Array = result.get("polylines", [])
	return polylines[index] if index < polylines.size() else PackedVector2Array()


## THE STRAIGHT BUNDLE, every point hand-derived.
##
## Spine (0,0) -> (100,0), so the bundle runs east: u = (1,0) and the offset
## normal n = (-u.y, u.x) = (0,1), i.e. a track's offset is its y.
##
## Three 0.2mm tracks at 0.3mm clearance: pitch = 0.1 + 0.3 + 0.1 = 0.5 for both
## gaps, so cumulative_offsets gives lanes [-0.5, 0.0, +0.5] for A, B, C in the
## caller's order (the sibling suite pins that arithmetic).
##
## SOURCE pads sit west of the spine and ABOVE the whole bundle, in the same
## perpendicular order as the lanes: A (-10,-10), B (-10,-8), C (-10,-6).
## Every track has to travel DOWN to its lane, and C — the lane furthest from
## the pads — has to cross both other lanes to get there, so it must leave
## first, before those lanes have started. B crosses only A's. A crosses none.
## Departure order is therefore C, B, A at stations 0, 0.5, 1.0 (spaced by the
## same 0.5 pitch, since the tracks meeting at each step are the same widths):
##
##     source stations  A = 1.0   B = 0.5   C = 0.0
##
## TARGET pads sit east of the spine and BELOW the whole bundle, again in lane
## order: A (110,20), B (110,22), C (110,24). Mirrored reasoning — A now has to
## cross both other lanes, so A leaves first, measured BACK from the spine's
## end:
##
##     target stations  A = 0.0   B = 0.5   C = 1.0
##
## Each route is then pad, corner at (station, pad-perp), lane start at
## (station, lane), lane end, corner, pad.
func _run_straight_bundle() -> void:
	print("-- straight bundle: three nets, hand-derived pad to pad --")
	var result: Dictionary = BusGeom.bundle_routes(
		_pv([Vector2(0, 0), Vector2(100, 0)]),
		PackedStringArray(["A", "B", "C"]),
		_pv([Vector2(-10, -10), Vector2(-10, -8), Vector2(-10, -6)]),
		_pv([Vector2(110, 20), Vector2(110, 22), Vector2(110, 24)]),
		[0.2, 0.2, 0.2], 0.3)
	check("the straight bundle is routed", bool(result.get("ok", false)))
	if not bool(result.get("ok", false)):
		printerr("    refused: " + str(result.get("error", "")))
		return

	var offsets: Array = result["offsets"]
	check_near("lane A", float(offsets[0]), -0.5)
	check_near("lane B", float(offsets[1]), 0.0)
	check_near("lane C", float(offsets[2]), 0.5)

	var src: Array = result["source_stations"]
	check_near("A leaves the source end last (1.0mm in)", float(src[0]), 1.0)
	check_near("B leaves second (0.5mm in)", float(src[1]), 0.5)
	check_near("C, which crosses both other lanes, leaves first (0.0mm in)",
		float(src[2]), 0.0)
	var tgt: Array = result["target_stations"]
	check_near("A leaves the target end first (0.0mm back)", float(tgt[0]), 0.0)
	check_near("B leaves second (0.5mm back)", float(tgt[1]), 0.5)
	check_near("C leaves last (1.0mm back)", float(tgt[2]), 1.0)

	check_points("A: pad -> corner -> lane -0.5 -> corner -> pad", _route(result, 0),
		[Vector2(-10, -10), Vector2(1, -10), Vector2(1, -0.5),
		 Vector2(100, -0.5), Vector2(100, 20), Vector2(110, 20)])
	check_points("B: rides the spine itself (lane 0.0)", _route(result, 1),
		[Vector2(-10, -8), Vector2(0.5, -8), Vector2(0.5, 0),
		 Vector2(99.5, 0), Vector2(99.5, 22), Vector2(110, 22)])
	check_points("C: leaves at the spine's own first point", _route(result, 2),
		[Vector2(-10, -6), Vector2(0, -6), Vector2(0, 0.5),
		 Vector2(99, 0.5), Vector2(99, 24), Vector2(110, 24)])


## MIXED WIDTHS THROUGH A BEND, every point hand-derived.
##
## Spine (0,0) -> (30,0) -> (30,30): east, then south. Source frame u = (1,0),
## n = (0,1). Target frame is the LAST segment, u = (0,1), so n = (-1,0) — at
## that end a track's offset runs in -x, and a pad's perpendicular coordinate is
## 30 - x.
##
## Widths [1.0, 0.2, 0.2] at 0.2mm clearance. gap A-B = 0.5 + 0.2 + 0.1 = 0.8,
## gap B-C = 0.1 + 0.2 + 0.1 = 0.4; positions 0 / 0.8 / 1.2 centred on 0.6 give
## lanes [-0.6, +0.2, +0.6].
##
## The lane polyline through the right angle is offset_polyline's mitered one:
## for offset o the corner lands at (30 - o, o) and the last point at (30 - o,
## 30), which is what holds the pitch constant round the bend.
##
## SOURCE pads (-5,-4), (-5,-3), (-5,-2), above the bundle in lane order, so the
## departure order is C, B, A as in the straight case. THE STATIONS ARE THE
## DISCRIMINATOR: they are spaced by the pitch of the two tracks meeting at each
## step, not by one uniform figure. C -> B is 0.1 + 0.2 + 0.1 = 0.4, and B -> A
## is 0.1 + 0.2 + 0.5 = 0.8 because A is the 1.0mm track:
##
##     source stations  C = 0.0   B = 0.4   A = 0.4 + 0.8 = 1.2
##
## TARGET pads (29,35), (27,35), (25,35) are perpendicular coordinates 1, 3, 5 —
## lane order again — so A leaves first there and the same widths give
##
##     target stations  A = 0.0   B = 0.8   C = 0.8 + 0.4 = 1.2
func _run_mixed_width_bend() -> void:
	print("-- mixed widths through a 90-degree bend, hand-derived --")
	var result: Dictionary = BusGeom.bundle_routes(
		_pv([Vector2(0, 0), Vector2(30, 0), Vector2(30, 30)]),
		PackedStringArray(["A", "B", "C"]),
		_pv([Vector2(-5, -4), Vector2(-5, -3), Vector2(-5, -2)]),
		_pv([Vector2(29, 35), Vector2(27, 35), Vector2(25, 35)]),
		[1.0, 0.2, 0.2], 0.2)
	check("the bent, mixed-width bundle is routed", bool(result.get("ok", false)))
	if not bool(result.get("ok", false)):
		printerr("    refused: " + str(result.get("error", "")))
		return

	var offsets: Array = result["offsets"]
	check_near("the 1.0mm track's lane", float(offsets[0]), -0.6)
	check_near("middle lane", float(offsets[1]), 0.2)
	check_near("outer lane", float(offsets[2]), 0.6)

	var src: Array = result["source_stations"]
	check_near("C leaves first", float(src[2]), 0.0)
	check_near("B leaves 0.4mm later (the two 0.2mm tracks' pitch)",
		float(src[1]), 0.4)
	check_near("A leaves 0.8mm after B — its 1.0mm width widened THAT step alone",
		float(src[0]), 1.2)
	var tgt: Array = result["target_stations"]
	check_near("A leaves the target end first", float(tgt[0]), 0.0)
	check_near("B is 0.8mm back from it", float(tgt[1]), 0.8)
	check_near("C is a further 0.4mm back", float(tgt[2]), 1.2)
	check("the wide track did NOT get the narrow tracks' spacing",
		absf(float(src[0]) - float(src[1])) > absf(float(src[1]) - float(src[2])) + EPS)

	check_points("A: 1.0mm track, outside of the corner at x = 30.6", _route(result, 0),
		[Vector2(-5, -4), Vector2(1.2, -4), Vector2(1.2, -0.6), Vector2(30.6, -0.6),
		 Vector2(30.6, 30), Vector2(29, 30), Vector2(29, 35)])
	check_points("B: through the corner at x = 29.8", _route(result, 1),
		[Vector2(-5, -3), Vector2(0.4, -3), Vector2(0.4, 0.2), Vector2(29.8, 0.2),
		 Vector2(29.8, 29.2), Vector2(27, 29.2), Vector2(27, 35)])
	check_points("C: inside of the corner at x = 29.4", _route(result, 2),
		[Vector2(-5, -2), Vector2(0, -2), Vector2(0, 0.6), Vector2(29.4, 0.6),
		 Vector2(29.4, 28.8), Vector2(25, 28.8), Vector2(25, 35)])

	# The property the mitered lane buys, measured rather than read off the
	# points above: on the SOUTHBOUND run the three lanes are still their own
	# pitches apart (0.8 and 0.4), where a rigid translate would have collapsed
	# them onto one x.
	var a: PackedVector2Array = _route(result, 0)
	var b: PackedVector2Array = _route(result, 1)
	var c: PackedVector2Array = _route(result, 2)
	check_near("A to B on the post-bend run", absf(a[4].x - b[4].x), 0.8)
	check_near("B to C on the post-bend run", absf(b[4].x - c[4].x), 0.4)


## THE INDEPENDENT ORACLE. Re-routes both shapes — the second one mirrored, so
## the frame signs are exercised in both directions — and asserts the properties
## that make the copper legal, using nothing the implementation computed: no
## diagonal anywhere, every route landing on its own two pads, no two departure
## stations shared, and no two NETS sharing a single point of copper.
func _run_geometry_invariants() -> void:
	print("-- invariants over both routed cases (independent of the expected points) --")
	var cases: Array = [
		{
			"label": "straight, east",
			"spine": _pv([Vector2(0, 0), Vector2(100, 0)]),
			"sources": _pv([Vector2(-10, -10), Vector2(-10, -8), Vector2(-10, -6)]),
			"targets": _pv([Vector2(110, 20), Vector2(110, 22), Vector2(110, 24)]),
			"widths": [0.2, 0.2, 0.2], "clearance": 0.3,
		},
		{
			# The bend case mirrored: west then north, so both frames' unit and
			# normal vectors take their other signs.
			"label": "bent west then north, mixed widths",
			"spine": _pv([Vector2(30, 0), Vector2(0, 0), Vector2(0, -30)]),
			"sources": _pv([Vector2(35, 4), Vector2(35, 3), Vector2(35, 2)]),
			"targets": _pv([Vector2(-5, -35), Vector2(-3, -35), Vector2(-1, -35)]),
			"widths": [1.0, 0.2, 0.2], "clearance": 0.2,
		},
	]
	for case in cases:
		var label: String = str(case["label"])
		var sources: PackedVector2Array = case["sources"]
		var targets: PackedVector2Array = case["targets"]
		var result: Dictionary = BusGeom.bundle_routes(case["spine"],
			PackedStringArray(["A", "B", "C"]), sources, targets,
			case["widths"], float(case["clearance"]))
		if not bool(result.get("ok", false)):
			check("%s: routed" % label, false)
			printerr("    refused: " + str(result.get("error", "")))
			continue
		var polylines: Array = result["polylines"]
		check("%s: one route per net" % label, polylines.size() == 3)

		var diagonals := 0
		var stranded := 0
		for i in range(polylines.size()):
			var route: PackedVector2Array = polylines[i]
			if route.is_empty() or route[0] != sources[i] or route[route.size() - 1] != targets[i]:
				stranded += 1
			for s in range(route.size() - 1):
				var d: Vector2 = route[s + 1] - route[s]
				if absf(d.x) > EPS and absf(d.y) > EPS:
					diagonals += 1
		check("%s: every segment is axis-aligned" % label, diagonals == 0)
		check("%s: every route runs from its own source pad to its own target pad"
			% label, stranded == 0)

		var shared := ""
		for i in range(polylines.size()):
			for j in range(i + 1, polylines.size()):
				if _routes_touch(polylines[i], polylines[j]):
					shared = "%d and %d" % [i, j]
		check("%s: no two nets share a point of copper" % label, shared.is_empty())
		if not shared.is_empty():
			printerr("    tracks %s overlap" % shared)

		# The METRIC half of the same oracle: not crossing is not enough, the
		# copper has to stand off. Measured with this suite's own gap routine
		# against pitch_between of each PAIR's widths — the figure that spaces
		# the lanes, so a correct bundle measures exactly its requirement.
		var widths: Array = case["widths"]
		var clearance: float = float(case["clearance"])
		var tight := ""
		for i in range(polylines.size()):
			for j in range(i + 1, polylines.size()):
				var need: float = BusGeom.pitch_between(float(widths[i]), float(widths[j]), clearance)
				var got: float = _min_gap(polylines[i], polylines[j])
				if got < need - MEASURE_EPS:
					tight = "%d and %d: %.6f < %.6f" % [i, j, got, need]
		check("%s: no two nets come closer than their own pitch" % label, tight.is_empty())
		if not tight.is_empty():
			printerr("    " + tight)

		var src: Array = result["source_stations"]
		var tgt: Array = result["target_stations"]
		var collided := false
		for i in range(src.size()):
			for j in range(i + 1, src.size()):
				if is_equal_approx(float(src[i]), float(src[j])):
					collided = true
				if is_equal_approx(float(tgt[i]), float(tgt[j])):
					collided = true
		check("%s: no two tracks leave the bundle at the same place" % label,
			not collided)


## Two routes sharing any point. Both are axis-aligned polylines, so each
## segment IS its own bounding box and "the boxes overlap" and "the segments
## meet" are the same statement — a vertical and a horizontal meet exactly when
## the vertical's x falls in the horizontal's x span and vice versa on y, which
## is what this test says. Deliberately a different mechanism from the ordering
## rules the module uses to avoid crossings in the first place.
func _routes_touch(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for i in range(a.size() - 1):
		for j in range(b.size() - 1):
			if (minf(a[i].x, a[i + 1].x) <= maxf(b[j].x, b[j + 1].x) + EPS
					and minf(b[j].x, b[j + 1].x) <= maxf(a[i].x, a[i + 1].x) + EPS
					and minf(a[i].y, a[i + 1].y) <= maxf(b[j].y, b[j + 1].y) + EPS
					and minf(b[j].y, b[j + 1].y) <= maxf(a[i].y, a[i + 1].y) + EPS):
				return true
	return false


func _run_crossing_refusals() -> void:
	print("-- crossings are named and drawn, never untangled --")
	# TWO NETS, PADS SWAPPED. Lanes are [-0.25, +0.25] (0.2mm tracks at 0.3mm
	# clearance, pitch 0.5). A is picked first so it rides the -0.25 lane, but
	# A's pad is BELOW the bundle at y +5 and B's is ABOVE at y -5. A has to
	# climb across B's lane and B has to drop across A's, at whichever station
	# each leaves: whoever goes first is crossed by the other. There is no
	# ordering that avoids it, so the copper crosses and the finding says so —
	# it is drawn anyway, because a crossing that was never drawn cannot be
	# corrected.
	check_bad_but_buildable("swapped source pads are named, and still drawn",
		BusGeom.bundle_routes(
			_pv([Vector2(0, 0), Vector2(100, 0)]),
			PackedStringArray(["SDA", "SCL"]),
			_pv([Vector2(-10, 5), Vector2(-10, -5)]),
			_pv([Vector2(110, -5), Vector2(110, 5)]),
			[0.2, 0.2], 0.3),
		2, ["\"SDA\"", "\"SCL\"", "source"])

	# THE SAME PADS AS _run_straight_bundle, PICKED IN THE OPPOSITE ORDER. Pick
	# order decides track position and is never re-sorted, so reversing it puts
	# every net on the far side of the bundle from where its pads are. A tool
	# that quietly re-sorted to make a bus work would return the straight case's
	# bundle again here; this one crosses, and says so.
	check_bad_but_buildable("reversing the pick order is reported, not re-sorted",
		BusGeom.bundle_routes(
			_pv([Vector2(0, 0), Vector2(100, 0)]),
			PackedStringArray(["C", "B", "A"]),
			_pv([Vector2(-10, -6), Vector2(-10, -8), Vector2(-10, -10)]),
			_pv([Vector2(110, 24), Vector2(110, 22), Vector2(110, 20)]),
			[0.2, 0.2, 0.2], 0.3),
		3, ["\"C\"", "\"B\"", "source"])

	# CROSSING AT THE FAR END ONLY. Same source pads as the bend case, but the
	# target pads run the other way along the board edge: their perpendicular
	# coordinates are 5, 3, 1 against lanes -0.6, +0.2, +0.6. The source end is
	# perfectly routable; the finding must name the TARGET end.
	check_bad_but_buildable("a crossing at the target end names that end",
		BusGeom.bundle_routes(
			_pv([Vector2(0, 0), Vector2(30, 0), Vector2(30, 30)]),
			PackedStringArray(["A", "B", "C"]),
			_pv([Vector2(-5, -4), Vector2(-5, -3), Vector2(-5, -2)]),
			_pv([Vector2(25, 35), Vector2(27, 35), Vector2(29, 35)]),
			[1.0, 0.2, 0.2], 0.2),
		3, ["\"A\"", "\"B\"", "target"])


## THE METRIC GAP between two whole routes, in mm — the independent oracle for
## "this copper stands off", written the same way _routes_touch is written for
## "this copper crosses" and deliberately NOT sharing the module's routine.
##
## Both routes are axis-aligned, so each segment IS its own bounding box: the
## boxes overlapping means the segments share a point (gap 0), and otherwise the
## closest approach between two disjoint segments is reached at an endpoint of
## one of them, so the four point-to-segment distances are the whole answer.
func _min_gap(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var best := INF
	for i in range(a.size() - 1):
		for j in range(b.size() - 1):
			if (minf(a[i].x, a[i + 1].x) <= maxf(b[j].x, b[j + 1].x)
					and minf(b[j].x, b[j + 1].x) <= maxf(a[i].x, a[i + 1].x)
					and minf(a[i].y, a[i + 1].y) <= maxf(b[j].y, b[j + 1].y)
					and minf(b[j].y, b[j + 1].y) <= maxf(a[i].y, a[i + 1].y)):
				return 0.0
			best = minf(best, _point_segment(a[i], b[j], b[j + 1]))
			best = minf(best, _point_segment(a[i + 1], b[j], b[j + 1]))
			best = minf(best, _point_segment(b[j], a[i], a[i + 1]))
			best = minf(best, _point_segment(b[j + 1], a[i], a[i + 1]))
	return best


## THE COPPER A BAD BUS HANDS BACK, checked against oracles that know nothing
## about how it was built.
##
## The case is the crowded one above: spine (0,0)->(100,0), SDA from (-8,-2.20)
## to (110,20), SCL from (-6,-1.95) to (110,22), 0.2mm tracks at 0.3mm
## clearance. Its pad legs run 0.25mm apart where 0.5mm is required, so the
## bundle is illegal — and it is exactly that copper the user has to be given in
## order to move a pad and fix it.
##
## ORACLES, none of them the module's own arithmetic:
##   - the four pad coordinates written above, against each route's two ends;
##   - a dx/dy scan of every emitted segment, for Manhattan;
##   - this suite's OWN _min_gap, against the finding's measured_mm — an
##     implementation that reported one number and drew another fails here;
##   - the hand-derived pitch 0.1 + 0.3 + 0.1 = 0.5, against required_mm;
##   - the witness PAIR's own separation, against the same measurement, so the
##     gap bar the canvas draws is the gap the finding claims.
func _check_crowded_copper(result: Dictionary) -> void:
	var a := _route(result, 0)
	var b := _route(result, 1)
	if a.size() < 2 or b.size() < 2:
		check("the crowded bundle handed back both routes", false)
		return
	check("SDA still runs pad to pad",
		a[0].distance_to(Vector2(-8, -2.20)) <= EPS
			and a[a.size() - 1].distance_to(Vector2(110, 20)) <= EPS)
	check("SCL still runs pad to pad",
		b[0].distance_to(Vector2(-6, -1.95)) <= EPS
			and b[b.size() - 1].distance_to(Vector2(110, 22)) <= EPS)

	var diagonals := 0
	for route in [a, b]:
		var pts: PackedVector2Array = route
		for i in range(pts.size() - 1):
			var d: Vector2 = pts[i + 1] - pts[i]
			if absf(d.x) > EPS and absf(d.y) > EPS:
				diagonals += 1
	check("illegal copper is still Manhattan copper", diagonals == 0)

	var findings: Array = result.get("findings", [])
	var clearance: Dictionary = {}
	for f in findings:
		if str((f as Dictionary).get("type", "")) == BusGeom.FINDING_CLEARANCE:
			clearance = f
			break
	if clearance.is_empty():
		check("the crowded bundle raised a clearance finding", false)
		return
	check_near("the finding's measured_mm is what this suite measures",
		float(clearance.get("measured_mm", -1.0)), _min_gap(a, b), MEASURE_EPS)
	check_near("its required_mm is the hand-derived pitch",
		float(clearance.get("required_mm", -1.0)), 0.5, MEASURE_EPS)
	var closest: Array = clearance.get("closest", [])
	var witness: Array = clearance.get("witness", [])
	if closest.size() < 2 or witness.size() < 2:
		check("the finding carries the pair it measured", false)
		return
	check_near("the witness pair spans exactly the gap the finding reports",
		Vector2(float(closest[0]), float(closest[1])).distance_to(
			Vector2(float(witness[0]), float(witness[1]))),
		float(clearance.get("measured_mm", -1.0)), MEASURE_EPS)


func _point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var len2: float = ab.length_squared()
	if len2 <= 0.0:
		return p.distance_to(a)
	return p.distance_to(a + ab * clampf((p - a).dot(ab) / len2, 0.0, 1.0))


## THE FINISHED COPPER IS MEASURED, not just ordered.
##
## The two rules in _departure_stations compare a breakout leg only with the
## lanes and pad legs at its OWN end of the spine, and they compare them for
## INTERSECTION. Both cases below slip through that and were ROUTED, ok == true,
## before this section existed — the routes each case would have emitted are
## written out in full so the defect stays legible after the refusal hides it.
##
##
## CASE 1 — A LEG AGAINST A LANE FROM A DISTANT PART OF THE SPINE.
##
## Spine (0,0) -> (100,0) -> (100,100) -> (-30,100). Every joint is a 90-degree
## turn and no joint doubles back, so neither spine-shape rule fires; the third
## arm nonetheless runs WEST, back past the first arm's start. Two 0.2mm tracks
## at 0.3mm clearance give lanes [-0.25, +0.25] and a 0.5mm pitch.
##
## Source pads (-10,150) and (-10,152) sit above and west of the start. A's pad
## is nearer the bundle, so A leaves first: source stations A = 0.0, B = 0.5.
## Target pads (-40,200) and (-40,198) sit past the west end, and B's is nearer,
## so target stations are B = 0.0, A = 0.5. BOTH ordering walks complete — this
## input has no end-local crossing at all.
##
## A's route then contains the leg (0,150) -> (0,-0.25): a 150mm perpendicular
## drop on the line x = 0. B's lane on the WESTBOUND arm is y = 99.75 and runs
## from x = 99.75 back to x = -30. It passes straight under that leg:
##
##     A: (-10,150) (0,150) (0,-0.25) (100.25,-0.25) (100.25,100.25)
##        (-29.5,100.25) (-29.5,200) (-40,200)
##     B: (-10,152) (0.5,152) (0.5,0.25) (99.75,0.25) (99.75,99.75)
##        (-30,99.75) (-30,198) (-40,198)
##
## ORACLE: refused, naming both nets, quoting the crossing at (0.000, 99.750) —
## and the message must NOT be either end's ordering refusal, since neither
## ordering rule fired.
##
##
## CASE 2 — THE REVIEWER'S LITERAL SPINE, same shape with the west arm stopping
## at x = 0. Same pads at the source end. ORACLE: refused, naming both nets, as
## a crossing. (Its west arm ends on the same x = 0 line the station-0 legs sit
## on, so several segment pairs meet; which one is quoted is not pinned, only
## that it is refused as a cross.)
##
##
## CASE 3 — PARALLEL LEGS THAT NEVER CROSS. Straight spine (0,0) -> (100,0),
## two 0.2mm tracks at 0.3mm clearance: lanes [-0.25, +0.25], required pitch
## 0.5. Source pads (-8,-2.20) and (-6,-1.95) are 0.25mm apart across the
## bundle. SCL's pad is nearer the bundle so it leaves first (stations SCL = 0,
## SDA = 0.5) and no leg crosses anything:
##
##     SDA: (-8,-2.20) (0.5,-2.20) (0.5,-0.25) (100,-0.25) (100,20) (110,20)
##     SCL: (-6,-1.95) (0,-1.95) (0,0.25) (99.5,0.25) (99.5,22) (110,22)
##
## The two pad legs run PARALLEL, 0.25mm apart, over x in [-6, 0] — half the
## 0.5mm the same rule that spaced the lanes demands, i.e. 0.05mm of gap between
## 0.2mm copper where 0.3mm was declared. ORACLE: refused, naming both nets,
## quoting the measured 0.250mm and the required 0.500mm.
##
##
## CASE 4 — THE NEAR MISS, which must still route. Case 3 with SCL's pad moved
## to (-6,-1.70), exactly one pitch from SDA's. Nothing else changes: same
## stations, same lanes, same shapes. ORACLE: routed, and the two routes measure
## exactly 0.5mm apart by this suite's own gap routine. Without it the refusal
## above could be "staggered pads are refused", which is not the contract.
func _run_clearance_refusals() -> void:
	print("-- the finished copper is measured, not just ordered --")

	var folded: Dictionary = BusGeom.bundle_routes(
		_pv([Vector2(0, 0), Vector2(100, 0), Vector2(100, 100), Vector2(-30, 100)]),
		PackedStringArray(["A", "B"]),
		_pv([Vector2(-10, 150), Vector2(-10, 152)]),
		_pv([Vector2(-40, 200), Vector2(-40, 198)]),
		[0.2, 0.2], 0.3)
	check_bad_but_buildable("a leg crossing a lane from a distant part of the spine is named",
		folded, 2, ["\"A\"", "\"B\"", "cross at (0.000, 99.750)"])
	check("that finding is the measurement's, not either end's ordering rule",
		not str(folded.get("error", "")).contains("end —"))

	check_bad_but_buildable("the spine folded back onto its own start is named as a cross",
		BusGeom.bundle_routes(
			_pv([Vector2(0, 0), Vector2(100, 0), Vector2(100, 100), Vector2(0, 100)]),
			PackedStringArray(["SDA", "SCL"]),
			_pv([Vector2(-10, 150), Vector2(-10, 152)]),
			_pv([Vector2(-10, 90), Vector2(-10, 88)]),
			[0.2, 0.2], 0.3),
		2, ["\"SDA\"", "\"SCL\"", "cross at ("])

	var crowded: Dictionary = BusGeom.bundle_routes(
		_pv([Vector2(0, 0), Vector2(100, 0)]),
		PackedStringArray(["SDA", "SCL"]),
		_pv([Vector2(-8, -2.20), Vector2(-6, -1.95)]),
		_pv([Vector2(110, 20), Vector2(110, 22)]),
		[0.2, 0.2], 0.3)
	check_bad_but_buildable("breakout legs running parallel inside the clearance are named",
		crowded, 2, ["\"SDA\"", "\"SCL\"", "0.250mm apart", "need 0.500mm"])
	_check_crowded_copper(crowded)

	var near_miss: Dictionary = BusGeom.bundle_routes(
		_pv([Vector2(0, 0), Vector2(100, 0)]),
		PackedStringArray(["SDA", "SCL"]),
		_pv([Vector2(-8, -2.20), Vector2(-6, -1.70)]),
		_pv([Vector2(110, 20), Vector2(110, 22)]),
		[0.2, 0.2], 0.3)
	check("staggered pads exactly one pitch apart still route", bool(near_miss.get("ok", false)))
	if bool(near_miss.get("ok", false)):
		check_near("and their legs measure exactly that pitch",
			_min_gap(_route(near_miss, 0), _route(near_miss, 1)), 0.5, MEASURE_EPS)


func _run_structural_refusals() -> void:
	print("-- structural refusals --")
	var names := PackedStringArray(["A", "B"])
	var sources := _pv([Vector2(-10, -5), Vector2(-10, 5)])
	var targets := _pv([Vector2(110, -5), Vector2(110, 5)])

	# A diagonal spine cannot carry axis-aligned tracks, and rounding it onto an
	# axis would move a point the caller placed.
	check_refused("a diagonal spine segment is refused, not squared up",
		BusGeom.bundle_routes(_pv([Vector2(0, 0), Vector2(10, 5)]),
			names, sources, targets, [0.2, 0.2], 0.3),
		["0→1", "both axes"])

	# (0,0) -> (50,0) -> (20,0) reverses along the same axis: the offset lanes
	# would fold back over their neighbours.
	check_bad_but_buildable("a spine that doubles back is named — the fold is drawn, not hidden",
		BusGeom.bundle_routes(
			_pv([Vector2(0, 0), Vector2(50, 0), Vector2(20, 0)]),
			names, sources, targets, [0.2, 0.2], 0.3),
		2, ["doubles back", "point 1"])

	# A pad 5mm INSIDE the bundle: its leg would have to run backwards through
	# the fan-out to reach its station.
	check_bad_but_buildable("a source pad past the start of the spine is named by net",
		BusGeom.bundle_routes(_pv([Vector2(0, 0), Vector2(100, 0)]),
			names, _pv([Vector2(5, -5), Vector2(-10, 5)]), targets,
			[0.2, 0.2], 0.3),
		2, ["\"A\"", "5.000mm past"])
	check_bad_but_buildable("a target pad short of the end of the spine is named by net",
		BusGeom.bundle_routes(_pv([Vector2(0, 0), Vector2(100, 0)]),
			names, sources, _pv([Vector2(110, -5), Vector2(97, 5)]),
			[0.2, 0.2], 0.3),
		2, ["\"B\"", "3.000mm short"])

	# ROOM. Three 0.2mm tracks at 0.3mm clearance fan out over 1.0mm at each
	# end and need 0.5mm (the widest offset) of bundle clear of both. A 1.2mm
	# spine has 2.0mm of fan-out to hold and nothing left over.
	check_bad_but_buildable("a spine too short for its own fan-outs is named",
		BusGeom.bundle_routes(_pv([Vector2(0, 0), Vector2(1.2, 0)]),
			PackedStringArray(["A", "B", "C"]),
			_pv([Vector2(-10, -10), Vector2(-10, -8), Vector2(-10, -6)]),
			_pv([Vector2(110, 20), Vector2(110, 22), Vector2(110, 24)]),
			[0.2, 0.2, 0.2], 0.3),
		3, ["0→1", "1.200mm", "2.000mm", "0.500mm"])

	# A zero-width track is what would let two departure stations coincide, so
	# it is refused rather than clamped.
	check_refused("a zero-width track is refused by name",
		BusGeom.bundle_routes(_pv([Vector2(0, 0), Vector2(100, 0)]),
			names, sources, targets, [0.2, 0.0], 0.3),
		["\"B\"", "no trace width"])

	check_refused("a missing endpoint is refused, not routed from a default",
		BusGeom.bundle_routes(_pv([Vector2(0, 0), Vector2(100, 0)]),
			names, _pv([Vector2(-10, -5)]), targets, [0.2, 0.2], 0.3),
		["one source, one target and one width"])
	check_refused("a spine of one distinct point is refused",
		BusGeom.bundle_routes(_pv([Vector2(4, 4), Vector2(4, 4)]),
			names, sources, targets, [0.2, 0.2], 0.3),
		["at least 2 distinct points"])


## A pad already sitting on its own lane needs no perpendicular leg at all: the
## corner and the lane's end are the same point, and the route is a single
## straight run.
##
## Spine (0,0) -> (20,0), two 0.2mm tracks at 0.3mm clearance: pitch 0.5, lanes
## [-0.25, +0.25]. Both pads are placed ON those lanes, so neither track's leg
## sweeps across anything and nothing constrains the order; the caller's order
## stands and the stations are 0.0 and 0.5 at each end. A's route is then
## (-5,-0.25) -> (0,-0.25) -> (20,-0.25) -> (25,-0.25) and B's is the same
## 0.5mm further in at each end.
func _run_pads_already_on_their_lanes() -> void:
	print("-- a pad already on its lane drops the corner instead of doubling it --")
	var result: Dictionary = BusGeom.bundle_routes(
		_pv([Vector2(0, 0), Vector2(20, 0)]),
		PackedStringArray(["A", "B"]),
		_pv([Vector2(-5, -0.25), Vector2(-5, 0.25)]),
		_pv([Vector2(25, -0.25), Vector2(25, 0.25)]),
		[0.2, 0.2], 0.3)
	check("aligned pads route", bool(result.get("ok", false)))
	if not bool(result.get("ok", false)):
		printerr("    refused: " + str(result.get("error", "")))
		return
	check_points("A: one straight run, no repeated corner", _route(result, 0),
		[Vector2(-5, -0.25), Vector2(0, -0.25), Vector2(20, -0.25), Vector2(25, -0.25)])
	check_points("B: the same, 0.5mm in at each end", _route(result, 1),
		[Vector2(-5, 0.25), Vector2(0.5, 0.25), Vector2(19.5, 0.25), Vector2(25, 0.25)])
