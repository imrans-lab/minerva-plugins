extends RefCounted
## Pure trace-geometry primitives: point-to-segment, point-to-polyline,
## segment-to-segment, length, axis snapping, trace ends, translate, bounds.
##
## THE single home for these on the GD side. Every function is static and
## side-effect free; polylines are PackedVector2Array in mm, and a "segment" is
## the pair of its two end points. Nothing here knows about traces, zones, or
## buses — it is the arithmetic those all share.
##
## Off-tree plugin: NO class_name (see sibling pcb_layer_stack.gd) — reached via
## a relative preload() from model siblings and `model/pcb_trace_geometry.gd`
## from ui/.
##
## TOLERANCE SEMANTICS, in one place:
##  * `degenerate_len_sq` (mm^2) — a segment whose squared length is strictly
##    BELOW it collapses to its start point instead of being projected onto; an
##    exactly zero-length segment always collapses (the division is undefined).
##    The default 0.0 therefore collapses only the zero-length segment;
##    LEGACY_DEGENERATE_LEN_SQ (1e-4, a 0.01 mm segment) is what the trace
##    model and the route-hint kind have always used and keep using,
##    so a sub-0.01 mm segment measures to its start point there. The two are
##    kept apart on purpose: unifying them would move a pick by up to 0.01 mm
##    at exactly the segments where that is most likely to matter.
##  * `tol` (mm) — inclusive: a distance EQUAL to the tolerance is a hit.
##  * "closest" picks are strict-less-than walks: on a tie the EARLIER segment
##    wins, and that order is part of the contract (a click on a shared vertex
##    picks the incoming segment).
##  * Axis checks are EXACT (== 0.0), never approx: a segment with any non-zero
##    dx and dy is a diagonal, and the unit vectors built from an axis-aligned
##    segment are exactly (+-1, 0) or (0, +-1) with no rounding.


## Squared-length floor the trace model and the route-hint kind treat as "this
## segment is a point": 1e-4 mm^2, i.e. a segment shorter than 0.01 mm.
const LEGACY_DEGENERATE_LEN_SQ := 0.0001


# ── point vs segment ─────────────────────────────────────────────────────────

## The point on segment `a`->`b` nearest `p`. The projection parameter is clamped
## to [0, 1], so anything past an end answers with that end. A zero-length
## segment, or one whose squared length is strictly below `degenerate_len_sq`,
## answers `a`.
static func closest_point_on_segment(p: Vector2, a: Vector2, b: Vector2,
		degenerate_len_sq: float = 0.0) -> Vector2:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq <= 0.0 or len_sq < degenerate_len_sq:
		return a
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t


## Distance from `p` to the SEGMENT `a`->`b` (not the infinite line): the
## distance to closest_point_on_segment, same degenerate rule.
static func distance_to_segment(p: Vector2, a: Vector2, b: Vector2,
		degenerate_len_sq: float = 0.0) -> float:
	return p.distance_to(closest_point_on_segment(p, a, b, degenerate_len_sq))


# ── point vs polyline ────────────────────────────────────────────────────────

## Nearest point on a polyline: {point: Vector2, segment: int, distance: float}.
## `segment` is the index of the winning segment's FIRST point (strict-less-than
## walk, earliest wins a tie). `closed` walks the last->first edge too, as a
## zone outline needs. An empty polyline answers {p, -1, INF}; a single point
## answers {that point, -1, its distance} — there is no segment to name.
static func closest_on_polyline(points: PackedVector2Array, p: Vector2,
		closed: bool = false, degenerate_len_sq: float = 0.0) -> Dictionary:
	if points.is_empty():
		return {"point": p, "segment": -1, "distance": INF}
	if points.size() == 1:
		return {"point": points[0], "segment": -1, "distance": p.distance_to(points[0])}
	var best_point := points[0]
	var best_seg := -1
	var best_dist := INF
	var n := points.size() if closed else points.size() - 1
	for i in n:
		var q := closest_point_on_segment(p, points[i], points[(i + 1) % points.size()],
			degenerate_len_sq)
		var d := p.distance_to(q)
		if d < best_dist:
			best_dist = d
			best_point = q
			best_seg = i
	return {"point": best_point, "segment": best_seg, "distance": best_dist}


## Is `p` within `tol` (inclusive) of any segment of the polyline? Stops at the
## first hit. A polyline of fewer than two points has no segment and never hits
## unless `closed`, where a single point is its own zero-length edge.
static func point_near_polyline(points: PackedVector2Array, p: Vector2, tol: float,
		closed: bool = false, degenerate_len_sq: float = 0.0) -> bool:
	var n := points.size() if closed else points.size() - 1
	for i in n:
		var d := distance_to_segment(p, points[i], points[(i + 1) % points.size()],
			degenerate_len_sq)
		if d <= tol:
			return true
	return false


# ── segment vs segment ───────────────────────────────────────────────────────

## Closest approach between two GENERAL segments: {distance, a, b}, `a` on the
## first and `b` on the second.
##
## A crossing answers distance 0 at the crossing point. Disjoint segments are two
## disjoint convex sets, so their closest approach is attained at an endpoint of
## at least one of them: four point-to-segment projections are the whole answer.
## Collinear overlap, which segment_intersects_segment does not report, lands an
## endpoint of one on the other and so measures zero through the projections —
## with the WITNESS at that endpoint, not at the overlap's middle (see
## axis_aligned_segment_gap for the variant that names the middle).
static func segment_gap(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> Dictionary:
	var hit: Variant = Geometry2D.segment_intersects_segment(a0, a1, b0, b1)
	if hit is Vector2:
		var at: Vector2 = hit
		return {"distance": 0.0, "a": at, "b": at}
	var best: Dictionary = {"distance": INF, "a": a0, "b": b0}
	for p in [a0, a1]:
		var q: Vector2 = closest_point_on_segment(p, b0, b1)
		if p.distance_to(q) < float(best["distance"]):
			best = {"distance": p.distance_to(q), "a": p, "b": q}
	for p in [b0, b1]:
		var q: Vector2 = closest_point_on_segment(p, a0, a1)
		if p.distance_to(q) < float(best["distance"]):
			best = {"distance": p.distance_to(q), "a": q, "b": p}
	return best


## Closest approach between two AXIS-ALIGNED segments: {distance, at, a, b},
## `at` the midpoint of the gap (somewhere BETWEEN the two, for a message to
## quote) and `a`/`b` its two ends.
##
## An axis-aligned segment IS its own bounding box, so "the boxes overlap" and
## "the segments share a point" are the same statement, and the overlap box's
## centre is a point they genuinely share — which is why a collinear overlap
## here reports its MIDDLE where segment_gap reports an endpoint. Only valid for
## axis-aligned input: a diagonal's box overlaps things the segment misses.
## Disjoint segments fall to the same four endpoint projections as segment_gap.
static func axis_aligned_segment_gap(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> Dictionary:
	var lo_x: float = maxf(minf(a0.x, a1.x), minf(b0.x, b1.x))
	var hi_x: float = minf(maxf(a0.x, a1.x), maxf(b0.x, b1.x))
	var lo_y: float = maxf(minf(a0.y, a1.y), minf(b0.y, b1.y))
	var hi_y: float = minf(maxf(a0.y, a1.y), maxf(b0.y, b1.y))
	if lo_x <= hi_x and lo_y <= hi_y:
		var shared := Vector2((lo_x + hi_x) * 0.5, (lo_y + hi_y) * 0.5)
		return {"distance": 0.0, "at": shared, "a": shared, "b": shared}
	var best := _endpoint_gap(a0, b0, b1)
	for candidate in [_endpoint_gap(a1, b0, b1), _endpoint_gap(b0, a0, a1), _endpoint_gap(b1, a0, a1)]:
		if float(candidate["distance"]) < float(best["distance"]):
			best = candidate
	return best


## Point `p` against segment `a`->`b` in the {distance, at, a, b} shape of
## axis_aligned_segment_gap.
static func _endpoint_gap(p: Vector2, a: Vector2, b: Vector2) -> Dictionary:
	var q := closest_point_on_segment(p, a, b)
	return {"distance": p.distance_to(q), "at": (p + q) * 0.5, "a": p, "b": q}


## Closest approach between segment `a0`->`a1` and a whole polyline, in
## segment_gap's {distance, a, b} shape with `a` on the segment. Strict walk,
## earliest polyline segment wins a tie; a polyline with no segment answers
## {INF, a0, a0}.
static func segment_to_polyline_gap(points: PackedVector2Array, a0: Vector2, a1: Vector2) -> Dictionary:
	var best: Dictionary = {"distance": INF, "a": a0, "b": a0}
	for i in range(points.size() - 1):
		var g: Dictionary = segment_gap(a0, a1, points[i], points[i + 1])
		if float(g["distance"]) < float(best["distance"]):
			best = g
	return best


## Does a polyline touch an axis-aligned rectangle? A vertex inside the box
## (inclusive edges, Rect2.has_point) or any segment crossing one of its four
## edges. A region entirely inside a closed outline is NOT a hit: pass a closed
## point list (first point repeated) to test an outline, and add the interior
## case yourself if you need it.
static func polyline_touches_rect(points: PackedVector2Array, region: Rect2) -> bool:
	for p in points:
		if region.has_point(p):
			return true
	if points.size() < 2:
		return false
	var corners := PackedVector2Array([
		region.position,
		Vector2(region.end.x, region.position.y),
		region.end,
		Vector2(region.position.x, region.end.y),
	])
	for i in range(points.size() - 1):
		for c in 4:
			if Geometry2D.segment_intersects_segment(
					points[i], points[i + 1], corners[c], corners[(c + 1) % 4]) != null:
				return true
	return false


# ── length / axis ────────────────────────────────────────────────────────────

## Sum of the segment lengths, accumulated in order; 0.0 below two points.
static func length(points: PackedVector2Array) -> float:
	if points.size() < 2:
		return 0.0
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


## |dx| + |dy| between two points: the shortest Manhattan route can be.
static func manhattan_distance(a: Vector2, b: Vector2) -> float:
	return absf(b.x - a.x) + absf(b.y - a.y)


## Is the direction `d` horizontal or vertical? EXACT zero on one axis; a zero
## vector counts as aligned (it lies on both).
static func is_axis_aligned(d: Vector2) -> bool:
	return d.x == 0.0 or d.y == 0.0


## The unit vector along an axis-aligned, non-zero `d`, built rather than
## normalized so it is EXACTLY (+-1, 0) or (0, +-1). A zero vector answers
## (0, 0); a diagonal answers its vertical sign only, so check is_axis_aligned
## first when the input is not already Manhattan by construction.
static func axis_unit(d: Vector2) -> Vector2:
	return Vector2(signf(d.x), 0.0) if d.y == 0.0 else Vector2(0.0, signf(d.y))


## `p` moved onto whichever axis it travels furthest along from `prev`: the
## horizontal candidate (p.x, prev.y) wins when |dx| >= |dy|, else the vertical
## one. This is how a free-hand click becomes a Manhattan segment.
static func snap_to_axis(prev: Vector2, p: Vector2) -> Vector2:
	var d := p - prev
	return Vector2(p.x, prev.y) if absf(d.x) >= absf(d.y) else Vector2(prev.x, p.y)


## `p` projected onto the axis the segment `prev`->`station` runs along, and
## never behind `station`: a projection at or before the station answers the
## station itself, which a caller reads as "not ahead of it".
static func advance_along_axis(prev: Vector2, station: Vector2, p: Vector2) -> Vector2:
	var u := axis_unit(station - prev)
	var along: float = (p - station).dot(u)
	return station if along <= 0.0 else station + u * along


# ── ends / translate / bounds ────────────────────────────────────────────────

## Which END of the polyline `p` sits on, within `tol` (inclusive): 0 for the
## start, the last index for the end, -1 for neither. The start is tested
## first, so a one-point polyline (or a closed loop whose ends coincide) answers
## 0. Never matches an interior vertex — that is a different question.
static func end_index_at(points: PackedVector2Array, p: Vector2, tol: float) -> int:
	if points.is_empty():
		return -1
	if points[0].distance_to(p) <= tol:
		return 0
	var last := points.size() - 1
	if points[last].distance_to(p) <= tol:
		return last
	return -1


## Every point moved by `delta`; a new array, the input untouched.
static func translated(points: PackedVector2Array, delta: Vector2) -> PackedVector2Array:
	var moved := PackedVector2Array()
	for p in points:
		moved.append(p + delta)
	return moved


## The axis-aligned box holding every point, padded by `margin` on every side
## (min corner moved by -margin, max corner by +margin, size their difference).
## Empty input answers the empty Rect2(); a single point a zero-size box at it.
static func bounds(points: PackedVector2Array, margin: float = 0.0) -> Rect2:
	if points.is_empty():
		return Rect2()
	var min_pos := points[0]
	var max_pos := points[0]
	for p in points:
		min_pos.x = minf(min_pos.x, p.x)
		min_pos.y = minf(min_pos.y, p.y)
		max_pos.x = maxf(max_pos.x, p.x)
		max_pos.y = maxf(max_pos.y, p.y)
	min_pos -= Vector2(margin, margin)
	max_pos += Vector2(margin, margin)
	return Rect2(min_pos, max_pos - min_pos)
