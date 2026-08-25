extends RefCounted
## Pure geometry for parallel bus tracks: mitered polyline offsetting and the
## per-adjacent-pair pitch arithmetic that spaces them.
##
## Off-tree plugin: NO class_name (see sibling pcb_trace.gd / pcb_layer_stack.gd)
## — reached by relative preload. Every function here is STATIC and this file
## imports NOTHING: no PCBData, no canvas, no Godot node types beyond Vector2 and
## the core math built-ins. That is deliberate. The geometry is the whole risk in
## a bus tool (see below), so it is written and pinned where it can be exercised
## with plain numbers, with no scene tree, no board, and no UI to stand up.
##
##
## WHAT THIS IS FOR
## -----------------
## The bus tool is: pick an ORDERED set of nets, draw ONE spine polyline, and
## emit N real Trace entities, one net per track, at clearance-or-better pitch
## along that spine, mitered so the pitch stays constant through bends.
##
## Two layers of that live here. offset_polyline/pitch_between/
## cumulative_offsets place the parallel LANES and know nothing about pads.
## bundle_routes builds on them to produce each net's whole polyline, source pad
## to target pad, adding the axis-aligned breakout legs at both ends; it is the
## one function here that constrains the spine to right angles.
##
##
## WHY NOT REUSE THE ROUTER'S BUS OFFSET
## --------------------------------------
## worker/agent_router/router.py's route_bus() already offsets a bundle, and it
## is WRONG at bends in a way that matters here. It derives ONE perpendicular
## from the FIRST segment only (router.py:1584-1596) and rigid-translates every
## waypoint by it (:1647-1652). On a straight corridor that is exactly right; at
## a corner it is not an offset at all. Worked example, spine (0,0)->(10,0)->
## (10,10) with two tracks at +-0.5: the rigid translate puts BOTH tracks' second
## segments on the line x=10 — pitch 1.0 before the bend, pitch ZERO after it,
## i.e. a dead short between two nets. offset_polyline holds them at x=10.5 and
## x=9.5 through the corner. That single case is why this module exists rather
## than a port, and it is pinned in test_pcb_bus_geometry.gd.
##
## The router is also a campaign non-goal, so it is not being fixed from here.
##
##
## SIGN CONVENTION -- READ BEFORE CALLING
## ---------------------------------------
## For a segment travelling in unit direction d = (dx, dy), the offset normal is
##
##     n(d) = (-dy, dx)
##
## i.e. d rotated by +90 degrees in the (x, y) sense: (1,0) -> (0,1).
##
## The board frame this model uses has x increasing RIGHT and y increasing DOWN
## (the canvas/KiCad convention, not the maths-textbook one), so in the picture a
## user is looking at:
##
##     POSITIVE offset falls to the RIGHT of the direction of travel.
##     NEGATIVE offset falls to the LEFT.
##
## Concretely: offsetting (0,0)->(10,0) by +1 gives (0,1)->(10,1), which is BELOW
## the spine on screen — the right-hand side of someone walking east with y down.
##
## This matches the rotation route_bus already uses for its perpendicular
## (router.py:1592-1594, perp = (-dir_y, dir_x)), so a bundle laid out by track
## index reads the same way in both codebases even though the corner handling
## differs. Reversing the spine's point order flips which physical side a given
## sign lands on — that is inherent to "relative to travel", not a bug, and it is
## why the caller (S4) must fix the spine direction before assigning nets.
##
##
## WHAT THIS DOES NOT SOLVE
## -------------------------
## - INNER-SIDE SELF-OVERLAP. When a segment is shorter than |offset|, the inner
##   offset polyline folds back over itself. A miter limit does not fix that (it
##   is a trimming/clipping problem, not a join problem) and no trimming is done
##   here. A caller of offset_polyline must either refuse a spine with segments
##   shorter than the widest offset or accept the fold; bundle_routes below
##   refuses, and so does the tool layer that calls offset_polyline directly.
## - CLOSED POLYGONS. These are open polylines; the first and last vertices get
##   plain segment-end treatment, never a join.
## - PADS SPREAD ALONG THE CORRIDOR. bundle_routes reaches pads that lie beyond
##   the spine's ends. A row of pads running PARALLEL to the bundle, each one
##   wanting its own perpendicular drop at its own position along the spine, is
##   a different construction (the stations would come from the pads instead of
##   being built distinct) and is refused by name, not served.


## Miter length beyond which an interior joint is bevelled instead of mitered,
## as a MULTIPLE of |offset|.
##
## 4.0 is the standard value (SVG stroke-miterlimit's default, and PostScript's)
## and it is standard because it lands in the right place: the miter ratio is
## 1/sin(theta/2) for interior angle theta, so a limit of 4 bevels everything
## sharper than theta = 2*asin(0.25) ~= 29 degrees and miters everything blunter.
## A right angle sits at 1.414 and an anti-parallel spike at infinity.
##
## The limit is NOT cosmetic here. At 16 degrees interior with a 1mm offset the
## miter point lands 7.07mm from the vertex — a spike of bare copper shot 7mm
## back alongside the trace it belongs to, crossing whatever it finds. Bevelling
## keeps every emitted point within |offset| of the spine. Sharper joints get two
## points instead of one; see offset_polyline's return-shape note.
const MITER_LIMIT := 4.0

## Below this, two consecutive spine points are the SAME point and the segment
## between them has no direction to offset along. In mm — one nanometre, far
## below anything the canvas can author (points land on a quarter-grid), while a
## double-click or a replayed drag can easily produce an exact duplicate.
const _MIN_SEGMENT_MM := 1e-6

## How far inside the required pitch two finished routes may measure before the
## clearance check below calls it a violation, in mm.
##
## Vector2 is 32-bit float whatever the build's precision, so a pair of lanes
## laid out EXACTLY one pitch apart measures that pitch only to within an ulp:
## test_bus_breakout_geometry.gd's mixed-width bend measures 0.799999 against a
## required 0.800000. One micron sits two orders above that noise and three
## below the tightest clearance any fab quotes, so it lets every correctly
## spaced bundle through and still catches every real violation — those miss by
## a fraction of a pitch (0.25mm of 0.5mm in the case that found this), never by
## a micron.
const _CLEARANCE_TOLERANCE_MM := 1e-3


## The parallel polyline at signed perpendicular `offset` from `points`.
##
## Interior vertices are MITERED (the returned vertex is the intersection of the
## two adjacent offset lines, which is what keeps the perpendicular distance to
## the spine equal to |offset| along BOTH segments — the property a rigid
## translate loses at every bend). Joints sharper than MITER_LIMIT are BEVELLED.
##
## RETURN SHAPE IS NOT 1:1 WITH THE INPUT. Callers must not zip the two arrays by
## index:
##   - a mitered interior vertex contributes ONE point,
##   - a bevelled interior vertex contributes TWO,
##   - a duplicate/zero-length input segment contributes NONE (it is dropped
##     before any direction is computed; an exactly reversing spine would
##     otherwise divide by zero).
## For a spine with no bevels and no duplicates the sizes do match, which is the
## common case and what the pitch-invariant test relies on to compare segment i
## with segment i.
##
## Degenerate inputs, all returning something usable rather than erroring:
##   - fewer than 2 distinct points -> the cleaned points, unmoved (there is no
##     direction, so there is no side to fall on),
##   - exactly 2 distinct points -> a simple perpendicular translate,
##   - offset == 0.0 -> the cleaned points (identity in geometry; note the
##     duplicate-dropping still applies, so the ARRAY can be shorter).
static func offset_polyline(points: PackedVector2Array, offset: float) -> PackedVector2Array:
	var pts := _drop_duplicate_points(points)
	if pts.size() < 2 or is_zero_approx(offset):
		return pts

	var out := PackedVector2Array()
	var normals := PackedVector2Array()
	for i in range(pts.size() - 1):
		var d: Vector2 = (pts[i + 1] - pts[i]).normalized()
		normals.append(Vector2(-d.y, d.x))

	# First point: no joint, just the first segment's own offset.
	out.append(pts[0] + normals[0] * offset)

	for i in range(1, pts.size() - 1):
		var u: Vector2 = normals[i - 1]
		var v: Vector2 = normals[i]
		var vertex: Vector2 = pts[i]
		# Solving (M - P).u == offset and (M - P).v == offset with M - P in the
		# span of {u, v} gives M = P + offset * (u + v) / (1 + u.v). The miter
		# ratio |M - P| / |offset| is then sqrt(2 / (1 + u.v)), which is the
		# familiar 1/sin(theta/2). Collinear (u == v, u.v == 1) falls out of the
		# same formula as P + offset*u, so a straight run needs no special case.
		var c: float = clampf(u.dot(v), -1.0, 1.0)
		var denom: float = 1.0 + c
		if denom <= 0.0 or sqrt(2.0 / denom) > MITER_LIMIT:
			# Bevel: end the previous offset segment, start the next one. Two
			# points, each exactly |offset| from the vertex.
			out.append(vertex + u * offset)
			out.append(vertex + v * offset)
		else:
			out.append(vertex + (u + v) * (offset / denom))

	# Last point: no joint, just the last segment's own offset.
	out.append(pts[pts.size() - 1] + normals[normals.size() - 1] * offset)
	return out


## The minimum centre-to-centre distance between two ADJACENT parallel tracks of
## widths `width_a` and `width_b` at the given `clearance`, in mm:
##
##     pitch = width_a/2 + clearance + width_b/2
##
## THE HALF-WIDTH TERMS ARE NOT OPTIONAL. A trace is addressed by its CENTRELINE
## but occupies width_mm of copper, so the gap the fab actually sees between two
## centrelines separated by `pitch` is pitch - a/2 - b/2. Dropping either term
## under-blocks, which is the fail-open direction. This is the same rule
## worker/agent_router/kicad_io.py:243-247 states in as many words ("A trace is a
## CENTERLINE — keepout is w/2 + clearance + w_new/2") and that grid.py:95-108
## enforces for the router's own keepouts.
##
## PER ADJACENT PAIR, which is the difference from route_bus. The router spaces a
## bundle with one uniform `spacing` for every gap (router.py:1646, offset =
## (i - (n-1)/2) * spacing). That is only correct when every track is the same
## width; put a fat clock beside two thin data lines and the uniform figure is
## simultaneously too tight on one side of it and wasteful on the other. Feeding
## each gap its own two widths costs nothing and is right in both cases — for a
## uniform bundle this function reproduces the router's number exactly.
##
## Negative inputs are clamped to zero rather than allowed to shrink the pitch
## below the copper itself, for the reason grid.py:104-107 gives for the same
## clamp: a negative clearance or width would turn the superset invariant inside
## out. A no-rule clearance is 0.0 (see PCBData.design_rule_clearance), and 0.0
## is honest here — it yields touching-but-not-overlapping copper, which the
## caller is free to refuse.
static func pitch_between(width_a: float, width_b: float, clearance: float) -> float:
	return maxf(0.0, width_a) * 0.5 + maxf(0.0, clearance) + maxf(0.0, width_b) * 0.5


## Signed offsets from the spine for N tracks of the given `widths`, centred on
## the spine, spaced by the per-adjacent-pair pitch.
##
## Track i sits at cumulative_offsets(...)[i], to be fed straight to
## offset_polyline as the `offset`. Gap i uses pitch_between(widths[i],
## widths[i+1], clearance), so a mixed-width bundle gets a different spacing
## either side of the fat track. The whole bundle is then shifted so the first
## and last CENTRELINES are symmetric about the spine (the spine runs down the
## middle of the bundle, which is what a user drawing one line expects).
##
## Empty widths -> empty. One width -> [0.0] (a one-track "bus" is the spine).
##
## *** ORDER IS THE CALLER'S ORDER. THIS IS DELIBERATE, AND IT DELIBERATELY
## CONTRADICTS route_bus. ***
##
## The router re-sorts a bus's nets by their destination-side perpendicular
## position before assigning offsets (router.py:1624-1631, "this minimizes
## crossings at the destination end"). That is the right call for a solver
## handed a set of nets and asked to connect them. It is the WRONG call for this
## tool, whose entire premise (docket 019fb572b888) is that the human picks an
## ORDERED set of nets — "the I2S trio" in that order — and gets one net per
## track in the order they picked. Silently permuting a bundle the user ordered
## by hand would make the tool's one contract unverifiable by eye.
##
## So: a reviewer comparing this to route_bus WILL find them disagreeing about
## ordering. They are supposed to. Crossing minimisation belongs to the router,
## which is solving a different problem from a different input.
static func cumulative_offsets(widths: Array, clearance: float) -> Array:
	var n: int = widths.size()
	if n == 0:
		return []
	if n == 1:
		return [0.0]

	var running: float = 0.0
	var positions: Array = [0.0]
	for i in range(n - 1):
		running += pitch_between(float(widths[i]), float(widths[i + 1]), clearance)
		positions.append(running)

	# Centre on the spine: the midpoint of the outermost two CENTRELINES. (Not
	# of the outer copper EDGES — the spine is the line the user drew, and the
	# tracks are what get placed relative to it; with mixed widths the two
	# definitions differ and centreline-symmetry is the one that keeps a
	# reversed net order producing a mirrored, not shifted, bundle.)
	var centre: float = running * 0.5
	var out: Array = []
	for p in positions:
		out.append(float(p) - centre)
	return out


## Every net's COMPLETE polyline, from its source pad to its target pad, for a
## bus riding `spine`.
##
## Track i rides the lane at cumulative_offsets(widths, clearance)[i] — the
## caller's order, never re-sorted (see that function's own note) — and reaches
## its two pads through axis-aligned legs at each end:
##
##     pad --parallel--> corner --perpendicular--> lane . . . lane --> corner --> pad
##
## The corner sits at that track's OWN DEPARTURE STATION: a point along the
## spine's first (last) segment that no other track shares, so the tracks peel
## off the bundle one at a time instead of all turning at the same place.
## Stations are spaced by pitch_between of the two tracks that meet at each
## step, and every width must be positive, so two DEPARTURE legs can neither
## coincide nor sit closer than the clearance rule allows. That is a property of
## how the stations are built, not of a check run over them afterwards. It says
## nothing about the PAD legs, which run at the pads' own perpendicular
## coordinates and are spaced by wherever the pads happen to be.
##
## WHICH TRACK PEELS OFF FIRST IS DERIVED, not fixed by index. Two rules give a
## "must leave before" order over the nets:
##
##   - a track whose leg sweeps across another track's LANE has to be through
##     before that lane starts, so it leaves first;
##   - a track whose leg sweeps across the line another track's PAD LEG runs
##     along has to wait until that track has turned in.
##
## Ties keep the caller's order. When the two rules demand that each of a pair
## goes before the other, the pads cannot be reached without a crossing: the
## call is REFUSED and both nets are named. Nothing is reordered, rerouted or
## moved to another layer to make a crossing go away.
##
## THOSE RULES ARE NOT THE WHOLE GUARANTEE, and the gap is in two directions.
## They compare a leg only with the lanes and pad legs at its OWN end, so they
## never see a leg meeting a lane belonging to a DISTANT part of the spine —
## which is what a spine that turns back alongside its own start puts there.
## And they test for INTERSECTION, a topological property, while copper needs a
## metric one: two legs that never cross can still run a hair apart.
##
## So the COMPLETED routes are measured against each other before they are
## returned. No two nets may come closer than pitch_between(width_i, width_j,
## clearance) — the same rule that spaces the lanes, applied to every pair of
## segments in the two whole polylines, pads and legs included. Closer than
## that is refused by name like everything else here. This module authors copper
## with no DRC gate downstream of it, so the measurement is the gate.
##
## AXIS-ALIGNED ONLY, unlike offset_polyline above: a spine segment with a
## non-zero dx AND dy is refused rather than rounded onto an axis, because no
## rounding here is one a fab would agree with. The legs inherit the frame — the
## pad's own coordinate is carried into the corner unchanged instead of being
## rebuilt from a dot product, which would leave an ulp of diagonal behind.
##
## The pads must lie OUTSIDE the spine: a source pad no further along than the
## spine's first point, a target pad no nearer than its last. Pads spread ALONG
## the corridor (a header running parallel to the bundle) are refused by that
## rule, and deliberately: their legs would have to drop perpendicular at each
## pad's own position, which is a different construction from this one and has
## no distinct-station guarantee.
##
## Returns, on success:
##   {ok: true, error: "", offsets, source_stations, target_stations,
##    source_order, target_order, polylines}
## `polylines[i]` runs from sources[i] to targets[i]; the station arrays give
## each track's departure distance from the spine's first (source) and last
## (target) point; the order arrays give the track indices in departure order.
## On refusal: {ok: false, error: "..."} and nothing else — one field to check,
## the shape the tool layer's own refusals already use.
static func bundle_routes(
		spine: PackedVector2Array,
		net_names: PackedStringArray,
		sources: PackedVector2Array,
		targets: PackedVector2Array,
		widths: Array,
		clearance: float) -> Dictionary:
	var n: int = net_names.size()
	if n == 0:
		return _refused("A bus needs at least one net (none given).")
	if sources.size() != n or targets.size() != n or widths.size() != n:
		return _refused("A bus needs one source, one target and one width per net (%d nets, %d sources, %d targets, %d widths)."
			% [n, sources.size(), targets.size(), widths.size()])
	for i in range(n):
		# Zero width is what would let two departure stations coincide (their
		# spacing is pitch_between of the two widths and the clearance, which a
		# board is allowed to declare as 0.0), so it is refused here rather than
		# clamped — the distinct-station guarantee is the whole point.
		if float(widths[i]) <= 0.0:
			return _refused("Net \"%s\" has no trace width (%.3fmm) — a track with no copper has no lane to leave the bundle from."
				% [net_names[i], float(widths[i])])

	var pts := _drop_duplicate_points(spine)
	if pts.size() < 2:
		return _refused("The bus spine needs at least 2 distinct points (%d given)." % spine.size())
	var shape_error := _spine_shape_error(pts)
	if not shape_error.is_empty():
		return _refused(shape_error)

	var last: int = pts.size() - 1
	var u_src := _axis_unit(pts[1] - pts[0])
	var n_src := Vector2(-u_src.y, u_src.x)
	var u_tgt := _axis_unit(pts[last] - pts[last - 1])
	var n_tgt := Vector2(-u_tgt.y, u_tgt.x)

	# Pads in each end's own frame: `perp` across the bundle (same sign
	# convention as the offsets), the axial component only checked, never kept.
	var src_perp: Array = []
	var tgt_perp: Array = []
	for i in range(n):
		var from_start: Vector2 = sources[i] - pts[0]
		if from_start.dot(u_src) > _MIN_SEGMENT_MM:
			return _refused("Net \"%s\"'s source pad is %.3fmm past the start of the spine — a breakout leg runs from the spine back to its pad, so the spine has to start clear of the pads it fans out to."
				% [net_names[i], from_start.dot(u_src)])
		var from_end: Vector2 = targets[i] - pts[last]
		if from_end.dot(u_tgt) < -_MIN_SEGMENT_MM:
			return _refused("Net \"%s\"'s target pad is %.3fmm short of the end of the spine — a breakout leg runs from the spine out to its pad, so the spine has to end clear of the pads it fans out to."
				% [net_names[i], -from_end.dot(u_tgt)])
		src_perp.append(from_start.dot(n_src))
		tgt_perp.append(from_end.dot(n_tgt))

	var offsets: Array = cumulative_offsets(widths, clearance)
	var src := _departure_stations(src_perp, offsets, widths, clearance, net_names, "source")
	if not bool(src["ok"]):
		return src
	var tgt := _departure_stations(tgt_perp, offsets, widths, clearance, net_names, "target")
	if not bool(tgt["ok"]):
		return tgt
	var src_stations: Array = src["stations"]
	var tgt_stations: Array = tgt["stations"]

	# Room check. The fan-outs eat into the first and last segments, and what is
	# left has to still be a bundle: at least the widest offset, which is the
	# same figure the inner-fold rule uses (a segment shorter than that folds the
	# inner track back over itself) and, on the first/last segment, exactly what
	# keeps every station inside its own offset segment rather than past the
	# miter at the far end of it. A one-segment spine pays both fans.
	var margin := 0.0
	for o in offsets:
		margin = maxf(margin, absf(float(o)))
	var span_src := 0.0
	var span_tgt := 0.0
	for i in range(n):
		span_src = maxf(span_src, float(src_stations[i]))
		span_tgt = maxf(span_tgt, float(tgt_stations[i]))
	for i in range(last):
		var seg_len: float = pts[i].distance_to(pts[i + 1])
		var fanned: float = (span_src if i == 0 else 0.0) + (span_tgt if i == last - 1 else 0.0)
		if seg_len - fanned < margin:
			return _refused("Bus spine segment %d→%d is %.3fmm long; the fan-outs on it take %.3fmm and the bundle still needs %.3fmm of straight run clear of them. Lengthen the spine or move the pads."
				% [i, i + 1, seg_len, fanned, margin])

	var polylines: Array = []
	for i in range(n):
		var offset := float(offsets[i])
		var lane := offset_polyline(pts, offset)
		var d: float = float(src_stations[i])
		var e: float = float(tgt_stations[i])
		# The spine is axis-aligned with no reversal, so every joint miters to a
		# single point and `lane` runs one point per spine vertex; only its two
		# ENDS move, inward to this track's own stations.
		lane[0] = _station_point(pts[0], u_src, d, lane[0])
		lane[lane.size() - 1] = _station_point(pts[last], u_tgt, -e, lane[lane.size() - 1])
		var route := PackedVector2Array()
		route.append(sources[i])
		route.append(_station_point(pts[0], u_src, d, sources[i]))
		route.append_array(lane)
		route.append(_station_point(pts[last], u_tgt, -e, targets[i]))
		route.append(targets[i])
		# A pad already on its own lane, or already at its own station, makes one
		# of those legs zero-length; the corner is then the same point twice.
		polylines.append(_drop_duplicate_points(route))

	# THE GATE. Everything above reasons about one end of the spine at a time
	# and about crossings only; this measures the finished copper.
	var too_close := _clearance_error(polylines, net_names, widths, clearance)
	if not too_close.is_empty():
		return _refused(too_close)

	return {
		"ok": true, "error": "",
		"offsets": offsets,
		"source_stations": src_stations, "target_stations": tgt_stations,
		"source_order": src["order"], "target_order": tgt["order"],
		"polylines": polylines,
	}


## Two nets whose finished routes are closer than the clearance rule allows, as
## a refusal message, or "" when every pair clears.
##
## The required separation is pitch_between of the PAIR's own two widths, the
## same figure cumulative_offsets uses to space their lanes — so a bundle whose
## lanes are correctly spaced measures exactly its requirement and passes, and
## anything the breakout legs do to bring two nets closer than that fails.
static func _clearance_error(polylines: Array, net_names: PackedStringArray,
		widths: Array, clearance: float) -> String:
	for i in range(polylines.size()):
		for j in range(i + 1, polylines.size()):
			var need: float = pitch_between(float(widths[i]), float(widths[j]), clearance)
			var gap: Dictionary = _route_separation(polylines[i], polylines[j])
			var got: float = float(gap["distance"])
			if got >= need - _CLEARANCE_TOLERANCE_MM:
				continue
			var at: Vector2 = gap["at"]
			if got <= _CLEARANCE_TOLERANCE_MM:
				return "Nets \"%s\" and \"%s\" cross at (%.3f, %.3f) — their finished routes are one piece of copper there, which is a short between two nets. Redraw the spine, reorder the picked nets or move their pads." % [net_names[i], net_names[j], at.x, at.y]
			return "Nets \"%s\" and \"%s\" run %.3fmm apart near (%.3f, %.3f) — their %.3fmm and %.3fmm tracks at %.3fmm clearance need %.3fmm between centrelines. Move their pads apart or redraw the spine." % [net_names[i], net_names[j], got, at.x, at.y, float(widths[i]), float(widths[j]), maxf(0.0, clearance), need]
	return ""


## The closest approach between two whole routes: {distance, at}, where `at` is
## a point at that closest approach, for the refusal to quote.
static func _route_separation(a: PackedVector2Array, b: PackedVector2Array) -> Dictionary:
	var best: Dictionary = {"distance": INF, "at": Vector2.ZERO}
	for i in range(a.size() - 1):
		for j in range(b.size() - 1):
			var gap := _segment_separation(a[i], a[i + 1], b[j], b[j + 1])
			if float(gap["distance"]) < float(best["distance"]):
				best = gap
				if float(best["distance"]) <= 0.0:
					return best
	return best


## The closest approach between two segments: {distance, at}.
##
## Every segment reaching here is AXIS-ALIGNED — the spine is (_spine_shape_error
## refuses anything else) and the legs are built by _station_point, which copies
## one coordinate rather than recomputing it. An axis-aligned segment IS its own
## bounding box, so "the boxes overlap" and "the segments share a point" are the
## same statement, and the overlap box's centre is a point they genuinely share.
##
## Disjoint segments are two disjoint convex sets, so their closest approach is
## attained at an endpoint of at least one of them: four point-to-segment tests
## are the whole answer, no parametric solve needed.
static func _segment_separation(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> Dictionary:
	var lo_x: float = maxf(minf(a0.x, a1.x), minf(b0.x, b1.x))
	var hi_x: float = minf(maxf(a0.x, a1.x), maxf(b0.x, b1.x))
	var lo_y: float = maxf(minf(a0.y, a1.y), minf(b0.y, b1.y))
	var hi_y: float = minf(maxf(a0.y, a1.y), maxf(b0.y, b1.y))
	if lo_x <= hi_x and lo_y <= hi_y:
		return {"distance": 0.0, "at": Vector2((lo_x + hi_x) * 0.5, (lo_y + hi_y) * 0.5)}
	var best := _endpoint_gap(a0, b0, b1)
	for candidate in [_endpoint_gap(a1, b0, b1), _endpoint_gap(b0, a0, a1), _endpoint_gap(b1, a0, a1)]:
		if float(candidate["distance"]) < float(best["distance"]):
			best = candidate
	return best


## Point `p` against segment `a`-`b`: {distance, at}, `at` the midpoint of the
## gap so a refusal can name somewhere between the two nets rather than on one.
static func _endpoint_gap(p: Vector2, a: Vector2, b: Vector2) -> Dictionary:
	var ab: Vector2 = b - a
	var len2: float = ab.length_squared()
	var q: Vector2 = a if len2 <= 0.0 else a + ab * clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return {"distance": p.distance_to(q), "at": (p + q) * 0.5}


## The input with consecutive duplicate points removed.
##
## Kept private and applied by offset_polyline itself rather than pushed onto the
## caller: a zero-length segment has no direction, and normalized() on a zero
## vector returns Vector2.ZERO in Godot rather than erroring — which would
## silently produce a zero normal, an offset point sitting ON the spine, and a
## bus track shorted to its neighbour. Dropping the point is the fail-closed
## reading of "these two points are the same point".
static func _drop_duplicate_points(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > _MIN_SEGMENT_MM:
			out.append(p)
	return out


## The one-field refusal every bundle_routes exit shares.
static func _refused(message: String) -> Dictionary:
	return {"ok": false, "error": message}


## Why this spine cannot carry a pad-to-pad bus, or "" when it can.
##
## EXACT zero, not is_zero_approx: a segment with any non-zero dx and dy is a
## diagonal, and the alternative to refusing it is silently moving a point the
## caller placed. Exactness also buys the legs their frame — _axis_unit can
## return a unit vector with no rounding at all, so every emitted segment is
## axis-aligned in float rather than to within an ulp.
static func _spine_shape_error(pts: PackedVector2Array) -> String:
	for i in range(pts.size() - 1):
		var d: Vector2 = pts[i + 1] - pts[i]
		if d.x != 0.0 and d.y != 0.0:
			return "Bus spine segment %d→%d moves on both axes (dx %.3fmm, dy %.3fmm) — a bus bends at 90 degrees only, so its spine has to as well." % [i, i + 1, d.x, d.y]
	for i in range(1, pts.size() - 1):
		if (pts[i] - pts[i - 1]).dot(pts[i + 1] - pts[i]) < 0.0:
			return "The bus spine doubles back at point %d — every track would fold over the one beside it there." % i
	return ""


## The unit vector along an axis-aligned, non-zero `d`, built rather than
## normalized so it is EXACTLY (+-1, 0) or (0, +-1).
static func _axis_unit(d: Vector2) -> Vector2:
	return Vector2(signf(d.x), 0.0) if d.y == 0.0 else Vector2(0.0, signf(d.y))


## The point `axial` mm along `u` from `origin`, on the same perpendicular line
## as `through`.
##
## Axis-aligned frames only. The perpendicular coordinate is COPIED from
## `through` rather than recomputed, which is what makes the segment
## `through` -> result exactly axis-aligned instead of a dot-product round trip
## away from it.
static func _station_point(origin: Vector2, u: Vector2, axial: float, through: Vector2) -> Vector2:
	if u.y == 0.0:
		return Vector2(origin.x + u.x * axial, through.y)
	return Vector2(through.x, origin.y + u.y * axial)


## Where each track leaves the bundle at ONE end, as a distance measured inward
## from that end of the spine.
##
## `pad_perp` and `lane_perp` are that end's frame: the pad's and the lane's
## perpendicular coordinates. Both ends solve the same problem — the target end
## is the source end of the reversed spine, which negates every perpendicular
## coordinate, and every test below is a containment test that negation leaves
## alone — so the caller hands over the target end unchanged and gets stations
## measured backwards from the spine's last point.
##
## Returns {ok, error, stations, order} or the shared one-field refusal.
static func _departure_stations(pad_perp: Array, lane_perp: Array, widths: Array,
		clearance: float, net_names: PackedStringArray, end_label: String) -> Dictionary:
	var n: int = pad_perp.size()
	# leaves_first[i][j]: track i has to be off the bundle before track j is.
	var leaves_first: Array = []
	for i in range(n):
		var row: Array = []
		for j in range(n):
			row.append(false)
		leaves_first.append(row)
	for i in range(n):
		# The band track i's own perpendicular leg sweeps through, closed and
		# widened by the duplicate-point tolerance: a leg that ENDS on another
		# track's lane is touching copper, which is a conflict to order around,
		# not a near miss to allow.
		var lo: float = minf(float(pad_perp[i]), float(lane_perp[i])) - _MIN_SEGMENT_MM
		var hi: float = maxf(float(pad_perp[i]), float(lane_perp[i])) + _MIN_SEGMENT_MM
		for j in range(n):
			if j == i:
				continue
			if float(lane_perp[j]) >= lo and float(lane_perp[j]) <= hi:
				leaves_first[i][j] = true
			if float(pad_perp[j]) >= lo and float(pad_perp[j]) <= hi:
				leaves_first[j][i] = true
	for i in range(n):
		for j in range(i + 1, n):
			if leaves_first[i][j] and leaves_first[j][i]:
				return _refused("Nets \"%s\" and \"%s\" cross at the %s end — neither can leave the bundle before the other. Reorder the picked nets or move their pads."
					% [net_names[i], net_names[j], end_label])

	var indegree := PackedInt32Array()
	indegree.resize(n)
	var placed: Array = []
	for i in range(n):
		placed.append(false)
	for i in range(n):
		for j in range(n):
			if leaves_first[i][j]:
				indegree[j] += 1
	# Lowest index first among the tracks nothing is waiting on, so the caller's
	# order survives wherever the rules do not decide the question.
	var order: Array = []
	while order.size() < n:
		var pick := -1
		for k in range(n):
			if not placed[k] and indegree[k] == 0:
				pick = k
				break
		if pick < 0:
			break
		placed[pick] = true
		order.append(pick)
		for j in range(n):
			if leaves_first[pick][j]:
				indegree[j] -= 1
	if order.size() < n:
		return _refused(_cycle_refusal(leaves_first, placed, net_names, end_label))

	var stations: Array = []
	for i in range(n):
		stations.append(0.0)
	var run := 0.0
	for k in range(1, n):
		run += pitch_between(float(widths[order[k - 1]]), float(widths[order[k]]), clearance)
		stations[order[k]] = run
	return {"ok": true, "error": "", "stations": stations, "order": order}


## Two nets from a cycle of "leaves first" rules, named in a refusal.
##
## Reached only when the ordering could not be completed AND no pair contradicts
## each other directly, i.e. three or more nets chain into a loop. Every
## unplaced track still has an unplaced track waiting ahead of it — that is why
## it was never emitted — so walking backwards along those rules cannot stop and
## must revisit a track; the revisited one and the track it was reached from are
## both on the loop.
static func _cycle_refusal(leaves_first: Array, placed: Array,
		net_names: PackedStringArray, end_label: String) -> String:
	var n: int = placed.size()
	var cur := -1
	for k in range(n):
		if not placed[k]:
			cur = k
			break
	var seen: Dictionary = {}
	while cur >= 0:
		seen[cur] = true
		var prev := -1
		for k in range(n):
			if not placed[k] and bool(leaves_first[k][cur]):
				prev = k
				break
		if prev < 0:
			break
		if seen.has(prev):
			return "Nets \"%s\" and \"%s\" cross at the %s end — their breakout legs sit in a loop with the other nets that no departure order undoes. Reorder the picked nets or move their pads." % [net_names[prev], net_names[cur], end_label]
		cur = prev
	return "The nets cross at the %s end — no departure order lets every track reach its pad without crossing another. Reorder the picked nets or move their pads." % end_label
