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
## WHAT THIS IS FOR, AND WHAT IS DELIBERATELY NOT HERE YET
## -------------------------------------------------------
## The real bus tool (docket 019fb572b888) is: pick an ORDERED set of nets, draw
## ONE spine polyline, and emit N real Trace entities as parallel offsets of that
## spine at clearance-or-better pitch, one net per track, mitered so the pitch
## stays constant through bends. That tool is built in four slices:
##
##   S1  design_rule_clearance() + pitch_between()      <- shipped (S1 half here)
##   S2  offset_polyline() + cumulative_offsets()       <- shipped (this file)
##   S3  the ordered multi-net picker UI                <- NOT BUILT
##   S4  the armed canvas tool + one-undo batch commit  <- NOT BUILT
##
## S3 and S4 are DEFERRED, not forgotten, and not an oversight in review: the
## bus item sequences itself "after the real trace tool proves the direct-
## authoring plumbing", while S1+S2 are pure functions carrying all of the new
## computational geometry. Banking the hard part first, pinned by tests, is the
## point of this file existing before the tool that will call it.
##
## Nothing in pcb/ui/ calls these functions yet. That is expected until S4.
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
##   here. S4 must either refuse a spine with segments shorter than the widest
##   offset, or accept the fold. Recorded so it is a known gap, not a surprise.
## - CLOSED POLYGONS. These are open polylines; the first and last vertices get
##   plain segment-end treatment, never a join.
## - PAD BREAKOUT at the bundle ends, which the bus item itself puts out of scope
##   for v1 ("stop the bundle short of the pads").


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
