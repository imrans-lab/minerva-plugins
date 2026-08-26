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
##   NAMES it (see "two classes of no") and hands the folded copper over, and so
##   does the tool layer that calls offset_polyline directly.
## - CLOSED POLYGONS. These are open polylines; the first and last vertices get
##   plain segment-end treatment, never a join.
## - TWO PAD COLUMNS SIDE BY SIDE ALONG THE CORRIDOR. bundle_routes serves a
##   pad column that runs PARALLEL to the bundle by leaving each pad sideways
##   at its own row (see its "SIDEWAYS" note). Two such columns whose rows line
##   up — an LGA under the end of the spine — put two sideways legs in one row,
##   which no departure order separates; that is named in a finding, not
##   served.
##
##
## TWO CLASSES OF "NO" -- READ BEFORE ADDING A CHECK
## -------------------------------------------------
## UNBUILDABLE means no geometry can exist: no nets, a missing source/target/
## width, fewer than two distinct spine points, a diagonal segment, a via
## station at an end of the spine or on a bend. There is nothing to hand back,
## so bundle_routes returns {ok:false, buildable:false} and no polylines.
##
## BAD BUT BUILDABLE means the geometry exists and breaks a rule: two nets
## closer than their pitch, an end whose legs cannot be ordered, a pad inside
## the corridor, a spine shorter than its own fan-outs, a via station with too
## little run either side of it for its own fan-out, a spine that doubles
## back. Those return {ok:false, buildable:true} WITH the polylines and one
## FINDING per broken rule. The caller decides whether that copper lands;
## copper that exists can be corrected, and a refusal that lands nothing leaves
## nothing to correct.
##
## `ok` therefore means CLEAN, not "returned something". A caller that wants
## the geometry regardless reads `buildable`.
##
##
## THE VIA STATION
## ---------------
## bundle_routes takes an optional STATION: one interior spine vertex where
## every track drops a via and continues on another copper layer. The spine
## runs STRAIGHT ACROSS it (a via, not a bend) and there is at most one per
## bus — a bent or end-of-spine station is UNBUILDABLE, because the fan-out
## below has no unambiguous axis to run along there.
##
## Vias claim more room than tracks do, so around the station the lanes WIDEN:
## each track jogs perpendicular from its lane offset to a wider via offset,
## carries the via, and jogs back. That fan is the only geometry a station adds.
## When the via pitch is no wider than the track pitch nothing moves and the
## tracks run straight through their vias.
##
## THE JOGS ARE STAGGERED, outermost first, and that is load-bearing rather
## than decorative: a track that steps out has to cross the band its outer
## neighbour is about to vacate, so one jog per track per axial position is the
## only arrangement in which no jog leg lands inside another's clearance. A
## single shared jog position works for three tracks and shorts four.
##
## The returned `polylines` still hold each net's WHOLE route, both layer runs
## in one array — the clearance measurement, the preview and the pad legs all
## want the whole thing. `via_station_splits[i]` is the index of the via point
## in polylines[i]: points up to it ride the layer the caller drew on, points
## from it ride the layer past the station. A caller landing copper cuts there.
##
## The two runs are measured against each other like any other pair of tracks
## even though they are on different layers. On a spine that goes one way that
## costs nothing: the only place a pre-station run comes near a post-station one
## is the station perpendicular itself, where the via pitch already holds them
## apart. A spine that DOUBLES BACK can lay them side by side and be measured
## for a gap two layers do not need — and that spine is already a finding of its
## own.


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

const PcbTraceGeometry := preload("pcb_trace_geometry.gd")

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

## Finding `type` values. One per rule a BUILDABLE bundle can break, so a
## consumer can branch on the rule without parsing the message prose.
const FINDING_SPINE_DOUBLES_BACK := "bus_spine_doubles_back"
const FINDING_PAD_INSIDE_CORRIDOR := "bus_pad_inside_corridor"
const FINDING_END_CROSSING := "bus_end_crossing"
const FINDING_SPINE_TOO_SHORT := "bus_spine_too_short"
const FINDING_CLEARANCE := "bus_clearance"
const FINDING_VIA_STATION_CROWDED := "bus_via_station_crowded"
const FINDING_PADS_ALONG_SPINE := "bus_pads_along_spine"
const FINDING_SUB_WIDTH_STUB := "bus_sub_width_stub"


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
## ONE THING MOVES A STATION after the ladder has placed it. A lane MITERS its
## bends, so its corner sits |offset| back from (or past) the spine's own
## vertex, at a distance from the end that owes nothing to the station ladder.
## When those two land closer together than the track is wide, the run between
## them is a sub-width stub — copper a fab renders as a notch and DRC measures
## as a defect — and the leg turns at the lane's corner instead, meeting it in a
## single corner. _leg_station holds the spacing guarantee above across that
## move; it declines any snap that would not.
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
## goes before the other, the pads cannot be reached without a crossing: both
## nets are named in a FINDING and the departure order falls back to the
## caller's for whatever the rules could not decide. Nothing is reordered,
## rerouted or moved to another layer to make a crossing go away — the copper
## crosses, and says so.
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
## that is a FINDING like everything else here. This module authors copper with
## no DRC gate downstream of it, so the measurement is the only place the gap
## is ever measured.
##
## AXIS-ALIGNED ONLY, unlike offset_polyline above: a spine segment with a
## non-zero dx AND dy is refused rather than rounded onto an axis, because no
## rounding here is one a fab would agree with. The legs inherit the frame — the
## pad's own coordinate is carried into the corner unchanged instead of being
## rebuilt from a dot product, which would leave an ulp of diagonal behind.
##
## The pads should lie OUTSIDE the spine: a source pad no further along than the
## spine's first point, a target pad no nearer than its last.
##
## SIDEWAYS LEGS. The ladder above assumes each pad's first leg — the one that
## runs PARALLEL to the spine from the pad to its station — crosses nothing.
## A pad column that runs parallel to the bundle (a THT header beside a
## vertical first segment) breaks that: every pad's parallel leg would run down
## the column through the pads nearer the spine, and the legs would lie on one
## line. So a pad that shares a column with another pad of the bus (their
## perpendicular coordinates within a track width of each other, their axial ones at
## least a pitch apart) is a SIDEWAYS pad: it has no parallel leg at all, its
## station IS its own axial position — behind the spine's end, so the station
## is negative — and its lane runs from that row. Each such pad leaves its
## column perpendicular to it, in its own row, and the rows are spaced by the
## pads' own pitch. Its corner keeps the pad's axial coordinate exactly, as the
## across case keeps the perpendicular one. Sideways pads take no part in the
## ladder and never snap to a lane corner (_leg_station), and being past the
## spine's end is no defect for one: it has no forward leg to fold back.
##
## The sideways construction is clean only when the lanes are picked in column
## order — the pad furthest along the column from the spine takes the lane
## furthest from the column, so each leg sweeps only lanes that begin nearer
## the spine than its own row. Any other pick order, a ladder pad whose leg has
## to cross a sideways lane, or a second column whose rows line up with the
## first (two sideways legs in one row) is named in a finding and built anyway.
##
## `via_station_index` names ONE interior vertex of `spine` (the array as GIVEN,
## duplicates and all — it is translated onto the deduplicated spine here) that
## carries a via per track and hands the bundle to another layer; -1, the
## default, is the single-layer bus this function has always built.
## `via_diameter` is what one of those vias measures across its pad, and the
## only thing the widening arithmetic needs from the board's via rules;
## non-positive means "the vias claim no more room than the tracks do", so
## nothing widens.
##
## `open_targets`, when given, is one bool per net: true means that net has NO
## target — its `targets` entry is ignored — and its route ends OPEN at the end
## of its own lane (the lane's last offset point at the spine's end; past the
## via on a station bus), with no target leg. An open net takes no part in the
## target end's ladder, sideways rule or pad findings, and its target station is
## reported as 0.0 and left out of `target_order`. Its copper is still measured
## like everyone else's: a landed net's target leg that crosses an open lane on
## its way to its pad is a clearance finding, not something hidden. Empty (the
## default) lands every net.
##
## Returns, whenever geometry could be built (see the header's "two classes of
## no"):
##   {ok, buildable: true, error, findings, offsets, source_stations,
##    target_stations, source_order, target_order, polylines, open_targets,
##    via_station_index, via_station_offsets, via_station_points,
##    via_station_splits}
## The four via-station keys are EMPTY (via_station_index -1) for a bus with no
## station; otherwise via_station_points[i] is net i's via centre and
## via_station_splits[i] the index of that point in polylines[i].
## `ok` is true only when `findings` is empty; `error` is findings[0].message
## otherwise, so a caller that still checks one string reads the same words it
## always did. `polylines[i]` runs from sources[i] to targets[i]; the station
## arrays give each track's departure distance from the spine's first (source)
## and last (target) point; the order arrays give the track indices in
## departure order.
## When NOTHING could be built: {ok: false, buildable: false, error, findings:
## []} and no geometry.
static func bundle_routes(
		spine: PackedVector2Array,
		net_names: PackedStringArray,
		sources: PackedVector2Array,
		targets: PackedVector2Array,
		widths: Array,
		clearance: float,
		via_station_index: int = -1,
		via_diameter: float = 0.0,
		open_targets: Array = []) -> Dictionary:
	var n: int = net_names.size()
	if n == 0:
		return _unbuildable("A bus needs at least one net (none given).")
	if sources.size() != n or targets.size() != n or widths.size() != n:
		return _unbuildable("A bus needs one source, one target and one width per net (%d nets, %d sources, %d targets, %d widths)."
			% [n, sources.size(), targets.size(), widths.size()])
	if not open_targets.is_empty() and open_targets.size() != n:
		return _unbuildable("open_targets needs one flag per net (%d nets, %d flags)." % [n, open_targets.size()])
	var open: Array = []
	var landed: Array = []
	for i in range(n):
		var is_open: bool = not open_targets.is_empty() and bool(open_targets[i])
		open.append(is_open)
		if not is_open:
			landed.append(i)
	for i in range(n):
		# Zero width is what would let two departure stations coincide (their
		# spacing is pitch_between of the two widths and the clearance, which a
		# board is allowed to declare as 0.0), so it is refused here rather than
		# clamped — the distinct-station guarantee is the whole point.
		if float(widths[i]) <= 0.0:
			return _unbuildable("Net \"%s\" has no trace width (%.3fmm) — a track with no copper has no lane to leave the bundle from."
				% [net_names[i], float(widths[i])])

	var pts := _drop_duplicate_points(spine)
	if pts.size() < 2:
		return _unbuildable("The bus spine needs at least 2 distinct points (%d given)." % spine.size())
	var diagonal := _spine_diagonal_error(pts)
	if not diagonal.is_empty():
		return _unbuildable(diagonal)
	# THE STATION IS RESOLVED BEFORE ANY FINDING, in the UNBUILDABLE class. A
	# station at an end of the spine, or one the spine bends at, leaves the
	# fan-out below no unambiguous axis to run along, so there is no geometry to
	# hand over and correct.
	var station: int = -1
	if via_station_index >= 0:
		station = _dedup_index(spine, via_station_index)
		if station < 1 or station > pts.size() - 2:
			return _unbuildable("A via station needs spine on both sides of it — vertex %d is at an end of this %d-point spine."
				% [via_station_index, pts.size()])
		if PcbTraceGeometry.axis_unit(pts[station] - pts[station - 1]) != PcbTraceGeometry.axis_unit(pts[station + 1] - pts[station]):
			return _unbuildable("The bus spine bends at via-station vertex %d — a station is a straight run across carrying a via, not a corner."
				% via_station_index)

	# From here on every rule is BUILDABLE-but-illegal: it names a finding and
	# the construction carries on, so the caller ends up holding copper it can
	# correct instead of a refusal it cannot.
	var findings: Array = []
	var doubles_back := _spine_doubles_back_error(pts)
	if not doubles_back.is_empty():
		findings.append(_finding(FINDING_SPINE_DOUBLES_BACK, doubles_back, []))

	var last: int = pts.size() - 1
	var u_src := PcbTraceGeometry.axis_unit(pts[1] - pts[0])
	var n_src := Vector2(-u_src.y, u_src.x)
	var u_tgt := PcbTraceGeometry.axis_unit(pts[last] - pts[last - 1])
	var n_tgt := Vector2(-u_tgt.y, u_tgt.x)

	# Pads in each end's own frame: `perp` across the bundle (same sign
	# convention as the offsets) and `axial` measured INWARD from that end of
	# the spine — the target end is the source end of the reversed spine, so
	# its axial sign is flipped and both ends read the same way: a pad outside
	# the spine is negative, a pad past the spine's end positive.
	var src_perp: Array = []
	var src_axial: Array = []
	for i in range(n):
		var from_start: Vector2 = sources[i] - pts[0]
		src_perp.append(from_start.dot(n_src))
		src_axial.append(from_start.dot(u_src))
	var src_sideways: Array = _sideways_tracks(src_perp, src_axial, widths, clearance)
	# The target end is solved over the LANDED nets only — an open net has no
	# pad there to measure, order or fan out — in subset arrays indexed by
	# position in `landed`, then spread back over every net below.
	var tgt_perp_l: Array = []
	var tgt_axial_l: Array = []
	var tgt_widths_l: Array = []
	var tgt_offsets_l: Array = []
	var tgt_names_l := PackedStringArray()
	var offsets: Array = cumulative_offsets(widths, clearance)
	for i in landed:
		var from_end: Vector2 = targets[i] - pts[last]
		tgt_perp_l.append(from_end.dot(n_tgt))
		tgt_axial_l.append(-from_end.dot(u_tgt))
		tgt_widths_l.append(widths[i])
		tgt_offsets_l.append(offsets[i])
		tgt_names_l.append(net_names[i])
	var tgt_sideways_l: Array = _sideways_tracks(tgt_perp_l, tgt_axial_l, tgt_widths_l, clearance)
	for i in range(n):
		# A pad past the spine's end folds its FORWARD leg back over the
		# others; a sideways pad has no forward leg, so the rule is not its.
		if not src_sideways[i] and float(src_axial[i]) > _MIN_SEGMENT_MM:
			findings.append(_finding(FINDING_PAD_INSIDE_CORRIDOR,
				"Net \"%s\"'s source pad is %.3fmm past the start of the spine, along its first segment — the spine is the trunk between the two fan-outs and its legs reach BACK from its start to the source pads, so start it past the source pads in the direction the bus runs (level with them is fine), never before them. A pad column lying along the spine is left sideways from each pad's own row and needs no room."
					% [net_names[i], float(src_axial[i])],
				[net_names[i]], float(src_axial[i]), 0.0, sources[i]))
		if open[i]:
			continue
		var k: int = landed.find(i)
		if not tgt_sideways_l[k] and float(tgt_axial_l[k]) > _MIN_SEGMENT_MM:
			findings.append(_finding(FINDING_PAD_INSIDE_CORRIDOR,
				"Net \"%s\"'s target pad is %.3fmm short of the end of the spine, along its last segment — the legs reach OUT from the spine's end to the target pads, so end it short of the target pads (level with them is fine), never past them. A pad column lying along the spine is left sideways from each pad's own row and needs no room."
					% [net_names[i], float(tgt_axial_l[k])],
				[net_names[i]], float(tgt_axial_l[k]), 0.0, targets[i]))

	# THE WIDENING, and the only geometry a station adds: each track steps out
	# to a via offset before the station and back after it. Nothing moves when
	# the via pitch is no wider than the track pitch, and `fan` is then 0 —
	# every track runs straight through its own via.
	var via_offsets: Array = offsets
	var fan_at: Array = []
	var fan := 0.0
	if station >= 0:
		via_offsets = _via_station_offsets(widths, clearance, via_diameter)
		fan_at = _via_station_fan_distances(offsets, via_offsets, widths, clearance, via_diameter)
		for f in fan_at:
			fan = maxf(fan, float(f))
	var src := _departure_stations(src_perp, src_axial, src_sideways, offsets, widths,
		clearance, net_names, "source")
	findings.append_array(src["findings"])
	var tgt := _departure_stations(tgt_perp_l, tgt_axial_l, tgt_sideways_l, tgt_offsets_l,
		tgt_widths_l, clearance, tgt_names_l, "target")
	findings.append_array(tgt["findings"])
	var src_stations: Array = src["stations"]
	# Spread the landed-only target answers back over every net. An open net
	# gets no station (0.0 in the report) and INF for the corner-snap rule, so
	# no landed leg is ever declined a snap on account of a leg that is not
	# there; the target order is translated back to net indices.
	var tgt_stations: Array = []
	var tgt_snap_stations: Array = []
	var tgt_sideways: Array = []
	for i in range(n):
		tgt_stations.append(0.0)
		tgt_snap_stations.append(INF)
		tgt_sideways.append(false)
	for k in range(landed.size()):
		tgt_stations[landed[k]] = (tgt["stations"] as Array)[k]
		tgt_snap_stations[landed[k]] = (tgt["stations"] as Array)[k]
		tgt_sideways[landed[k]] = tgt_sideways_l[k]
	var tgt_order: Array = []
	for k in (tgt["order"] as Array):
		tgt_order.append(landed[int(k)])

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
		if not open[i]:
			span_tgt = maxf(span_tgt, float(tgt_stations[i]))
	for i in range(last):
		# The two segments the station sits between are judged by the station's
		# own rule below, which measures the same margin and names the station —
		# the more specific rule, so this one steps aside rather than reporting
		# the same short run twice in different words.
		if i == station - 1 or i == station:
			continue
		var seg_len: float = pts[i].distance_to(pts[i + 1])
		var fanned: float = (span_src if i == 0 else 0.0) + (span_tgt if i == last - 1 else 0.0)
		if seg_len - fanned < margin:
			findings.append(_finding(FINDING_SPINE_TOO_SHORT,
				"Bus spine segment %d→%d is %.3fmm long; the fan-outs on it take %.3fmm and the bundle still needs %.3fmm of straight run clear of them. Lengthen the spine or move the pads."
					% [i, i + 1, seg_len, fanned, margin],
				[], seg_len - fanned, margin, (pts[i] + pts[i + 1]) * 0.5))
	if station >= 0:
		findings.append_array(_via_station_findings(pts, station, fan, margin,
			span_src, span_tgt))

	# The station splits the spine in two, so each lane is offset in two pieces
	# and rejoined through the fan. Both pieces end (begin) on the station's own
	# perpendicular, which is what lets the fan be spliced onto their inner ends
	# by REPLACEMENT rather than by hunting for a vertex inside an offset
	# polyline that is not 1:1 with the spine.
	var spine_a := pts if station < 0 else pts.slice(0, station + 1)
	var spine_b := PackedVector2Array() if station < 0 else pts.slice(station)
	var u_st := Vector2.ZERO
	var n_st := Vector2.ZERO
	if station >= 0:
		u_st = PcbTraceGeometry.axis_unit(pts[station] - pts[station - 1])
		n_st = Vector2(-u_st.y, u_st.x)

	var polylines: Array = []
	var station_points: Array = []
	var station_splits: Array = []
	for i in range(n):
		var offset := float(offsets[i])
		var lane := offset_polyline(spine_a, offset)
		# The second piece is built here rather than below because the TARGET
		# leg lands on it, and both legs are placed before any point is.
		var lane_b := PackedVector2Array() if station < 0 else offset_polyline(spine_b, offset)
		var tgt_lane: PackedVector2Array = lane if station < 0 else lane_b
		# Each leg turns at its own station, EXCEPT where that would leave a
		# sub-width remnant of the lane between it and the lane's own corner.
		# A sideways pad's station is its own row and never moves.
		var d: float = float(src_stations[i]) if src_sideways[i] else _leg_station(
			float(src_stations[i]), _lane_corner(lane, true, pts[0], u_src),
			i, src_stations, widths, clearance)
		# An OPEN net turns nowhere at the target end: its lane keeps the offset
		# polyline's own last point and no leg is built.
		var e: float = 0.0
		if not open[i]:
			e = float(tgt_stations[i]) if tgt_sideways[i] else _leg_station(
				float(tgt_stations[i]), _lane_corner(tgt_lane, false, pts[last], -u_tgt),
				i, tgt_snap_stations, widths, clearance)
		# Every point of a leg is placed by _leg_point: on the station line for
		# a ladder pad, on the pad's own row for a sideways one. A pad already
		# on its own lane, or already at its own station, makes a leg
		# zero-length; the corner is then the same point twice, which is why
		# every run below is deduplicated before it is used.
		# A SIDEWAYS pad whose centre already sits under its lane's copper has
		# no reach to draw: the run from its centre to the lane's centreline
		# would be shorter than the track is wide, a stub, so the route begins
		# on the lane in the pad's row and the pad is met by the copper itself.
		var head := PackedVector2Array()
		if not _pad_under_lane(src_sideways[i], float(src_perp[i]), offset, float(widths[i])):
			head.append(sources[i])
			head.append(_leg_point(src_sideways[i], sources[i], pts[0], u_src, d, sources[i]))
		var tail := PackedVector2Array()
		if not open[i] and not _pad_under_lane(tgt_sideways[i],
				(targets[i] - pts[last]).dot(n_tgt), offset, float(widths[i])):
			tail.append(_leg_point(tgt_sideways[i], targets[i], pts[last], u_tgt, -e, targets[i]))
			tail.append(targets[i])

		# Only the lane's two ENDS move, inward to this track's own stations.
		# Indexed from the ends rather than by spine vertex on purpose: a spine
		# that doubles back bevels its reversal into TWO offset points, so
		# `lane` is not 1:1 with the spine there.
		lane[0] = _leg_point(src_sideways[i], sources[i], pts[0], u_src, d, lane[0])
		if station < 0:
			if not open[i]:
				lane[lane.size() - 1] = _leg_point(tgt_sideways[i], targets[i], pts[last],
					u_tgt, -e, lane[lane.size() - 1])
			var route := head
			route.append_array(lane)
			route.append_array(tail)
			polylines.append(_drop_duplicate_points(route))
			continue

		var v: float = float(via_offsets[i])
		# This track's OWN jog positions: a track that does not widen has none,
		# and turns straight into its via.
		var enter: Vector2 = pts[station] - u_st * float(fan_at[i])
		var exit_pt: Vector2 = pts[station] + u_st * float(fan_at[i])
		var via_point: Vector2 = pts[station] + n_st * v
		lane[lane.size() - 1] = enter + n_st * offset
		var run_a := head
		run_a.append_array(lane)
		run_a.append(enter + n_st * v)
		run_a.append(via_point)
		run_a = _drop_duplicate_points(run_a)

		lane_b[0] = exit_pt + n_st * offset
		if not open[i]:
			lane_b[lane_b.size() - 1] = _leg_point(tgt_sideways[i], targets[i], pts[last],
				u_tgt, -e, lane_b[lane_b.size() - 1])
		var run_b := PackedVector2Array()
		run_b.append(via_point)
		run_b.append(exit_pt + n_st * v)
		run_b.append_array(lane_b)
		run_b.append_array(tail)
		run_b = _drop_duplicate_points(run_b)

		# The via point is the LAST of run_a and the FIRST of run_b; the whole
		# route carries it once, and its index is where a caller cuts the
		# polyline into its two layer runs. Read BEFORE the join: a packed
		# array assigned to `whole` is the same array, so run_a grows with it.
		var split := run_a.size() - 1
		var whole := run_a
		for j in range(1, run_b.size()):
			whole.append(run_b[j])
		polylines.append(whole)
		station_points.append(via_point)
		station_splits.append(split)

	# THE MEASUREMENT. Everything above reasons about one end of the spine at a
	# time and about crossings only; this measures the finished copper.
	findings.append_array(_stub_findings(polylines, net_names, widths))
	findings.append_array(_clearance_findings(polylines, net_names, widths, clearance))

	return {
		"ok": findings.is_empty(), "buildable": true,
		"error": "" if findings.is_empty() else str((findings[0] as Dictionary)["message"]),
		"findings": findings,
		"offsets": offsets,
		"source_stations": src_stations, "target_stations": tgt_stations,
		"source_order": src["order"], "target_order": tgt_order,
		"polylines": polylines,
		"open_targets": open,
		"via_station_index": station,
		"via_station_offsets": via_offsets if station >= 0 else [],
		"via_station_points": station_points,
		"via_station_splits": station_splits,
	}


## One finding per pair of nets whose finished routes are closer than the
## clearance rule allows; empty when every pair clears.
##
## The required separation is pitch_between of the PAIR's own two widths, the
## same figure cumulative_offsets uses to space their lanes — so a bundle whose
## lanes are correctly spaced measures exactly its requirement and passes, and
## anything the breakout legs do to bring two nets closer than that is reported.
static func _clearance_findings(polylines: Array, net_names: PackedStringArray,
		widths: Array, clearance: float) -> Array:
	var out: Array = []
	for i in range(polylines.size()):
		for j in range(i + 1, polylines.size()):
			var need: float = pitch_between(float(widths[i]), float(widths[j]), clearance)
			var gap: Dictionary = _route_separation(polylines[i], polylines[j])
			var got: float = float(gap["distance"])
			if got >= need - _CLEARANCE_TOLERANCE_MM:
				continue
			var at: Vector2 = gap["at"]
			var message := ""
			if got <= _CLEARANCE_TOLERANCE_MM:
				message = "Nets \"%s\" and \"%s\" cross at (%.3f, %.3f) — their finished routes are one piece of copper there, which is a short between two nets. Redraw the spine, reorder the picked nets or move their pads." % [net_names[i], net_names[j], at.x, at.y]
			else:
				message = "Nets \"%s\" and \"%s\" run %.3fmm apart near (%.3f, %.3f) — their %.3fmm and %.3fmm tracks at %.3fmm clearance need %.3fmm between centrelines. Move their pads apart or redraw the spine." % [net_names[i], net_names[j], got, at.x, at.y, float(widths[i]), float(widths[j]), maxf(0.0, clearance), need]
			var f := _finding(FINDING_CLEARANCE, message,
				[net_names[i], net_names[j]], got, need, at)
			# The measured PAIR, so a witness can draw the gap it names rather
			# than a bare dot at its midpoint.
			f["closest"] = [float((gap["a"] as Vector2).x), float((gap["a"] as Vector2).y)]
			f["witness"] = [float((gap["b"] as Vector2).x), float((gap["b"] as Vector2).y)]
			out.append(f)
	return out


## The closest approach between two whole routes: {distance, at, a, b}, where
## `at` is a point at that closest approach for the message to quote and `a`/`b`
## are the two points the gap was measured between.
static func _route_separation(a: PackedVector2Array, b: PackedVector2Array) -> Dictionary:
	var best: Dictionary = {"distance": INF, "at": Vector2.ZERO,
		"a": Vector2.ZERO, "b": Vector2.ZERO}
	for i in range(a.size() - 1):
		for j in range(b.size() - 1):
			# Every segment here is AXIS-ALIGNED (the spine by refusal, the legs
			# by construction), which is what lets the box-overlap shortcut and
			# its overlap-centre witness stand in for a general segment test.
			var gap := PcbTraceGeometry.axis_aligned_segment_gap(a[i], a[i + 1], b[j], b[j + 1])
			if float(gap["distance"]) < float(best["distance"]):
				best = gap
				if float(best["distance"]) <= 0.0:
					return best
	return best


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


## The UNBUILDABLE exit: no geometry could be built, so none is returned. The
## `buildable` flag is what a caller reads to tell this apart from a bundle that
## exists and breaks a rule.
static func _unbuildable(message: String) -> Dictionary:
	return {"ok": false, "buildable": false, "error": message, "findings": []}


## ONE broken rule on a bundle that was built anyway.
##
## The geometry keys (closest/witness/midpoint, as [x, y] pairs) mirror the
## draft-check finding shape the routing workspace already stores and the canvas
## already draws witnesses from, so a bus finding needs no second renderer. `at`
## may be null for a rule with no single place on the board — those stay
## readable as text and simply draw no witness.
static func _finding(type: String, message: String, nets: Array,
		measured_mm: float = 0.0, required_mm: float = 0.0,
		at: Variant = null) -> Dictionary:
	var out: Dictionary = {
		"type": type,
		"message": message,
		"nets": nets,
		"measured_mm": measured_mm,
		"required_mm": required_mm,
	}
	if at is Vector2:
		var p: Vector2 = at
		out["closest"] = [p.x, p.y]
		out["witness"] = [p.x, p.y]
		out["midpoint"] = [p.x, p.y]
	return out


## The UNBUILDABLE spine defect — a diagonal segment — or "" when every segment
## is axis-aligned.
##
## EXACT zero, not is_zero_approx: a segment with any non-zero dx and dy is a
## diagonal, and the alternative to refusing it is silently moving a point the
## caller placed. Exactness also buys the legs their frame — axis_unit can
## return a unit vector with no rounding at all, so every emitted segment is
## axis-aligned in float rather than to within an ulp. Nothing downstream here
## can round it, which is why this one is a hard refusal rather than a finding.
static func _spine_diagonal_error(pts: PackedVector2Array) -> String:
	for i in range(pts.size() - 1):
		var d: Vector2 = pts[i + 1] - pts[i]
		if not PcbTraceGeometry.is_axis_aligned(d):
			return "Bus spine segment %d→%d moves on both axes (dx %.3fmm, dy %.3fmm) — a bus bends at 90 degrees only, so its spine has to as well." % [i, i + 1, d.x, d.y]
	return ""


## The BUILDABLE spine defect — a reversal — or "" when the spine never turns
## back on itself. offset_polyline bevels a reversal into two points rather
## than dividing by zero, so the lanes exist; they just fold over each other.
static func _spine_doubles_back_error(pts: PackedVector2Array) -> String:
	for i in range(1, pts.size() - 1):
		if (pts[i] - pts[i - 1]).dot(pts[i + 1] - pts[i]) < 0.0:
			return "The bus spine doubles back at point %d — every track would fold over the one beside it there." % i
	return ""


## Where `points[index]` ends up once _drop_duplicate_points has run, or -1 when
## `index` is not a point of `points` at all.
##
## The via station arrives as an index into the spine the CALLER holds; every
## other coordinate here is taken from the deduplicated one. Walking the same
## keep rule is what keeps a spine with a doubled click from silently moving the
## station one vertex along.
static func _dedup_index(points: PackedVector2Array, index: int) -> int:
	var kept := -1
	var last_kept := Vector2.ZERO
	for i in range(points.size()):
		if kept < 0 or last_kept.distance_to(points[i]) > _MIN_SEGMENT_MM:
			kept += 1
			last_kept = points[i]
		if i == index:
			return kept
	return -1


## The signed offsets the tracks widen to AT the via station.
##
## cumulative_offsets' arithmetic with one substitution: every adjacent pair is
## spaced by the WIDER of its own track pitch and the pitch two vias need, so a
## bundle whose vias already fit inside the track pitch does not move at all and
## one whose vias do not fans out by exactly the difference. Centred the same
## way, so the middle of an odd bundle stays on the spine.
static func _via_station_offsets(widths: Array, clearance: float, via_diameter: float) -> Array:
	var n: int = widths.size()
	if n == 0:
		return []
	if n == 1:
		return [0.0]
	var via_pitch := 0.0
	if via_diameter > 0.0:
		via_pitch = pitch_between(via_diameter, via_diameter, clearance)
	var running := 0.0
	var positions: Array = [0.0]
	for i in range(n - 1):
		running += maxf(pitch_between(float(widths[i]), float(widths[i + 1]), clearance), via_pitch)
		positions.append(running)
	var centre: float = running * 0.5
	var out: Array = []
	for pos in positions:
		out.append(float(pos) - centre)
	return out


## How far before (and after) the station EACH track starts stepping out, in mm,
## parallel to `offsets`. 0.0 for a track that does not widen — it turns
## straight into its via and no jog is built for it at all.
##
## Staggered outermost-first, one rank per distinct distance from the spine,
## spaced by `step`. The stagger is what makes the fan legal (see the header):
## two jog legs at the same axial position must clear each other across the
## bundle, and with real vias three tracks is the most that ever does. Spaced
## along the spine instead, any two legs are at least `step` apart whatever
## they do across it.
##
## `step` is the widest pitch anything here is spaced by — the widest adjacent
## track pitch, or the via pitch when the vias are the wider claim — so it
## needs no separate justification per pair.
static func _via_station_fan_distances(offsets: Array, via_offsets: Array,
		widths: Array, clearance: float, via_diameter: float) -> Array:
	var n: int = offsets.size()
	var out: Array = []
	for i in range(n):
		out.append(0.0)
	var moving: Array = []
	for i in range(n):
		if absf(float(via_offsets[i]) - float(offsets[i])) > _MIN_SEGMENT_MM:
			moving.append(i)
	if moving.is_empty():
		return out

	var step := 0.0
	if via_diameter > 0.0:
		step = pitch_between(via_diameter, via_diameter, clearance)
	for i in range(n - 1):
		step = maxf(step, pitch_between(float(widths[i]), float(widths[i + 1]), clearance))

	# Sorted innermost first so rank 1 (nearest the station) goes to the
	# innermost track and the outermost track jogs farthest out along the
	# spine, i.e. first on the way in. Insertion sort rather than sort_custom:
	# the arrays here are one per bus track.
	for a in range(1, moving.size()):
		var key: int = moving[a]
		var b: int = a - 1
		while b >= 0 and absf(float(offsets[moving[b]])) > absf(float(offsets[key])):
			moving[b + 1] = moving[b]
			b -= 1
		moving[b + 1] = key

	var rank := 0
	for k in range(moving.size()):
		if k > 0 and absf(float(offsets[moving[k]])) \
				> absf(float(offsets[moving[k - 1]])) + _MIN_SEGMENT_MM:
			rank += 1
		out[moving[k]] = float(rank + 1) * step
	return out


## The BUILDABLE rule a via station can break: it sits too close to an end of
## the spine to fan out and back inside the run it has.
##
## Same measurement the spine's own too-short rule makes — what is left of the
## run once the fan-outs have eaten into it, against the width of the bundle —
## and it REPLACES that rule on the station's two segments, so a short run there
## is reported once, in the words that name the station.
##
## It leaves real geometry behind (the jogs fold back over the run they came
## from), so it is a finding and the copper is handed over to be corrected.
static func _via_station_findings(pts: PackedVector2Array, station: int, fan: float,
		margin: float, span_src: float, span_tgt: float) -> Array:
	var out: Array = []
	var last: int = pts.size() - 1
	var before: float = pts[station - 1].distance_to(pts[station]) \
		- (span_src if station - 1 == 0 else 0.0)
	var after: float = pts[station].distance_to(pts[station + 1]) \
		- (span_tgt if station == last - 1 else 0.0)
	if before - fan < margin:
		out.append(_finding(FINDING_VIA_STATION_CROWDED,
			"The via station at spine vertex %d has %.3fmm of run before it once the pads have fanned out; its own fan-out takes %.3fmm and the bundle still needs %.3fmm of straight run clear of that. Move the station along the spine, or lengthen it."
				% [station, before, fan, margin],
			[], before - fan, margin, pts[station]))
	if after - fan < margin:
		out.append(_finding(FINDING_VIA_STATION_CROWDED,
			"The via station at spine vertex %d has %.3fmm of run after it once the pads have fanned out; its own fan-out takes %.3fmm and the bundle still needs %.3fmm of straight run clear of that. Move the station along the spine, or lengthen it."
				% [station, after, fan, margin],
			[], after - fan, margin, pts[station]))
	return out


## Is a SIDEWAYS pad's centre already under its own lane's copper — within
## half the track width of the lane's centreline? Such a pad has no reach to
## draw; its route starts on the lane. A pad exactly on the lane counts too,
## harmlessly: its reach was zero-length and dropped anyway.
static func _pad_under_lane(sideways: bool, pad_perp: float, lane_perp: float,
		width: float) -> bool:
	return sideways and absf(pad_perp - lane_perp) <= width * 0.5 + _CLEARANCE_TOLERANCE_MM


## One finding per net whose finished route carries a run that is shorter than
## its own track is wide but not zero — copper a fab renders as a notch and DRC
## measures as a defect. A ladder pad half a track to a whole track off its
## lane, or a sideways pad the same distance off (nearer than that it is under
## the lane and drawn without a reach), lands here; no leg construction can
## make that jog longer, since its length IS the pad's offset from the lane.
static func _stub_findings(polylines: Array, net_names: PackedStringArray, widths: Array) -> Array:
	var out: Array = []
	for i in range(polylines.size()):
		var route: PackedVector2Array = polylines[i]
		var width: float = float(widths[i])
		for s in range(route.size() - 1):
			var run: float = route[s].distance_to(route[s + 1])
			if run <= _MIN_SEGMENT_MM or run >= width - _CLEARANCE_TOLERANCE_MM:
				continue
			out.append(_finding(FINDING_SUB_WIDTH_STUB,
				"Net \"%s\"'s route has a %.3fmm run at (%.3f, %.3f) on a %.3fmm track — a stub shorter than the copper is wide, which a fab renders as a notch. Move the pad onto its lane, or a full track width off it."
					% [net_names[i], run, route[s].x, route[s].y, width],
				[net_names[i]], run, width, (route[s] + route[s + 1]) * 0.5))
			break
	return out


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


## Where a breakout leg turns, on the perpendicular line through `through`.
##
## A ladder pad turns `axial` mm along `u` from `origin` — _station_point. A
## SIDEWAYS pad turns in its own row: the axial coordinate is COPIED from `pad`
## rather than rebuilt from the station it was measured into, so the pad and
## its corner share that coordinate to the bit and the run between them is
## either exactly zero (dropped) or exactly perpendicular to the spine.
static func _leg_point(sideways: bool, pad: Vector2, origin: Vector2, u: Vector2,
		axial: float, through: Vector2) -> Vector2:
	if sideways:
		return _station_point(pad, u, 0.0, through)
	return _station_point(origin, u, axial, through)


## How far inward from `origin` along `u` the lane's OWN corner sits, in the
## same measure the departure stations use; INF when this end of the lane has
## no corner to reach.
##
## `at_start` picks which end of `lane` the leg lands on: the vertex next to it
## is the first thing along the lane that the station is not about to replace.
## That neighbour always lies on this end segment's offset LINE — a miter is
## |offset| from both segments, and a bevel's two points sit one on each of
## them, nearest end first — so the run between it and the station is
## axis-aligned and its length is the difference of these two distances.
##
## A lane of fewer than three points has no corner here: its far end is another
## station (or a via fan-out), and the run between two stations is the bundle
## itself, not a remnant to be collapsed.
static func _lane_corner(lane: PackedVector2Array, at_start: bool,
		origin: Vector2, u: Vector2) -> float:
	if lane.size() < 3:
		return INF
	var neighbour: Vector2 = lane[1] if at_start else lane[lane.size() - 2]
	return (neighbour - origin).dot(u)


## Where track `index`'s breakout leg actually turns off the spine, as an inward
## distance from that end of the spine.
##
## `station` is what the departure ladder gave it and `corner` is where its lane
## turns away from the end segment. Between the two sits a REMNANT of the lane,
## and when the remnant is shorter than that track's own copper it is not a
## segment anyone drew: it is a sub-width stub, which a fab renders as a notch
## and DRC measures as a defect. The leg then lands ON the corner, so the leg
## and the lane meet at ONE axis-aligned corner instead of two.
##
## THE SNAP ONLY EVER PUSHES A STATION OUTWARD. The room check upstream leaves
## every station at least the widest |offset| of segment before the bend, which
## puts any reachable corner at or beyond the LAST station — so the moved leg
## walks away from the legs behind it rather than into them. It can still reach
## the last station itself when the track being snapped is not the last to
## leave, so a move that would come within pitch of another leg is DECLINED and
## the remnant kept: the ladder's guarantee that two departure legs never sit
## closer than the clearance rule allows outranks a tidy corner, and the stub is
## still measured with everything else downstream.
static func _leg_station(station: float, corner: float, index: int,
		stations: Array, widths: Array, clearance: float) -> float:
	if not is_finite(corner) or absf(corner - station) >= float(widths[index]):
		return station
	for j in range(stations.size()):
		if j == index:
			continue
		var need: float = pitch_between(float(widths[index]), float(widths[j]), clearance)
		if absf(corner - float(stations[j])) < need - _CLEARANCE_TOLERANCE_MM:
			return station
	return corner


## Where each track leaves the bundle at ONE end, as a distance measured inward
## from that end of the spine.
##
## `pad_perp`, `pad_axial` and `lane_perp` are that end's frame: the pad's
## perpendicular and axial coordinates and the lane's perpendicular one. Both
## ends solve the same problem — the target end is the source end of the
## reversed spine, which negates every coordinate, and every test below is a
## containment test that negation leaves alone — so the caller hands over the
## target end in that reversed frame and gets stations measured backwards from
## the spine's last point.
##
## `sideways[i]` (_sideways_tracks) marks the pads that share a column running
## along the spine. Those take no part in the ladder: each one's station is its
## own axial coordinate — its lane runs from its row and its leg leaves the
## column perpendicular to it — and the rows are spaced by the pads, not by the
## pitch rule. The pairs a sideways leg cannot avoid are named by
## _sideways_findings; the ladder below is built over the remaining tracks
## only.
##
## ALWAYS returns stations: {ok, findings, stations, order}. A pair that each
## have to leave before the other, or a longer loop of the same, is a FINDING —
## the order then falls back to the caller's for whatever the rules could not
## decide, so the tracks still get distinct stations and the crossing shows up
## in the copper rather than swallowing it. `order` lists the sideways tracks
## first, outermost row first, then the ladder's departure order.
static func _departure_stations(pad_perp: Array, pad_axial: Array, sideways: Array,
		lane_perp: Array, widths: Array, clearance: float,
		net_names: PackedStringArray, end_label: String) -> Dictionary:
	var n: int = pad_perp.size()
	var findings: Array = _sideways_findings(sideways, pad_perp, pad_axial, lane_perp,
		widths, clearance, net_names, end_label)
	# leaves_first[i][j]: track i has to be off the bundle before track j is.
	# Only ladder tracks take part; a sideways track is already off the bundle
	# behind the spine's end, and is marked placed from the start.
	var leaves_first: Array = []
	for i in range(n):
		var row: Array = []
		for j in range(n):
			row.append(false)
		leaves_first.append(row)
	for i in range(n):
		if sideways[i]:
			continue
		# The band track i's own perpendicular leg sweeps through, closed and
		# widened by the duplicate-point tolerance: a leg that ENDS on another
		# track's lane is touching copper, which is a conflict to order around,
		# not a near miss to allow.
		var lo: float = minf(float(pad_perp[i]), float(lane_perp[i])) - _MIN_SEGMENT_MM
		var hi: float = maxf(float(pad_perp[i]), float(lane_perp[i])) + _MIN_SEGMENT_MM
		for j in range(n):
			if j == i or sideways[j]:
				continue
			if float(lane_perp[j]) >= lo and float(lane_perp[j]) <= hi:
				leaves_first[i][j] = true
			if float(pad_perp[j]) >= lo and float(pad_perp[j]) <= hi:
				leaves_first[j][i] = true
	for i in range(n):
		for j in range(i + 1, n):
			if leaves_first[i][j] and leaves_first[j][i]:
				findings.append(_finding(FINDING_END_CROSSING,
					"Nets \"%s\" and \"%s\" cross at the %s end — neither can leave the bundle before the other. Reorder the picked nets or move their pads."
						% [net_names[i], net_names[j], end_label],
					[net_names[i], net_names[j]]))

	var indegree := PackedInt32Array()
	indegree.resize(n)
	var placed: Array = []
	var ladder_count := 0
	for i in range(n):
		placed.append(bool(sideways[i]))
		if not sideways[i]:
			ladder_count += 1
	for i in range(n):
		for j in range(n):
			if leaves_first[i][j]:
				indegree[j] += 1
	# Lowest index first among the tracks nothing is waiting on, so the caller's
	# order survives wherever the rules do not decide the question.
	var order: Array = []
	while order.size() < ladder_count:
		var pick := -1
		for k in range(n):
			if not placed[k] and indegree[k] == 0:
				pick = k
				break
		if pick < 0:
			# A LOOP the rules cannot untangle. Report it once — the direct
			# pair above may already have named it — then break the loop on the
			# caller's own order, which is the tie-break the whole function
			# uses wherever the rules do not decide.
			if findings.is_empty():
				findings.append(_finding(FINDING_END_CROSSING,
					_cycle_refusal(leaves_first, placed, net_names, end_label), []))
			for k in range(n):
				if not placed[k]:
					pick = k
					break
		if pick < 0:
			break
		placed[pick] = true
		order.append(pick)
		for j in range(n):
			if leaves_first[pick][j]:
				indegree[j] -= 1

	var stations: Array = []
	for i in range(n):
		stations.append(float(pad_axial[i]) if sideways[i] else 0.0)
	var run := 0.0
	for k in range(1, order.size()):
		run += pitch_between(float(widths[order[k - 1]]), float(widths[order[k]]), clearance)
		stations[order[k]] = run
	var first: Array = []
	for i in range(n):
		if sideways[i]:
			first.append(i)
	first.sort_custom(func(a: int, b: int) -> bool:
		return float(stations[a]) < float(stations[b]))
	first.append_array(order)
	return {"ok": findings.is_empty(), "findings": findings,
		"stations": stations, "order": first}


## Which tracks at one end share a pad column that runs ALONG the spine, as one
## bool per track.
##
## Two pads are column-mates when their perpendicular coordinates differ by
## less than the narrower of their two tracks — the parallel leg of one would
## carry its own copper over the other's centre — and their axial coordinates
## are at least a pitch apart, so they are two rows, not one crowded one. The
## test is deliberately that tight: pads STAGGERED by a fraction of a pitch are
## not a column, and a sideways leg from the outer one would cross the inner
## one's lane where the ladder only crowds it. A crowd is measured and named;
## a crossing is a short. Those pairs stay on the ladder, as do pads closer
## than a pitch on both axes, which no leg construction serves.
static func _sideways_tracks(pad_perp: Array, pad_axial: Array, widths: Array,
		clearance: float) -> Array:
	var n: int = pad_perp.size()
	var out: Array = []
	for i in range(n):
		out.append(false)
	for i in range(n):
		for j in range(i + 1, n):
			var need: float = pitch_between(float(widths[i]), float(widths[j]), clearance) \
				- _CLEARANCE_TOLERANCE_MM
			var column: float = minf(float(widths[i]), float(widths[j]))
			if absf(float(pad_perp[i]) - float(pad_perp[j])) < column \
					and absf(float(pad_axial[i]) - float(pad_axial[j])) >= need:
				out[i] = true
				out[j] = true
	return out


## The crossings a SIDEWAYS leg cannot avoid, each named for what it is.
##
## A sideways track i owns two pieces of copper at this end: its lane, running
## from its own row inward, and the leg in that row sweeping the perpendicular
## band from its pad to its lane. Against each other track j that gives:
##
##   - j sideways in the SAME ROW (rows closer than a pitch, bands within a
##     pitch of each other): two legs on one line — the two-column case, which
##     no pick order separates;
##   - j's lane inside i's band and already running at i's row (j's row lies
##     further out): the lanes were picked out of column order;
##   - j a ladder track whose band holds i's lane: j's leg, at a station inside
##     the spine, has to cross a lane that has run since i's row;
##   - j a ladder track whose pad line lies in i's band, with j's pad no nearer
##     the spine than i's row: j's parallel leg runs through i's row.
##
## The crossing itself is also measured by _clearance_findings; this names the
## cause.
static func _sideways_findings(sideways: Array, pad_perp: Array, pad_axial: Array,
		lane_perp: Array, widths: Array, clearance: float,
		net_names: PackedStringArray, end_label: String) -> Array:
	var out: Array = []
	var n: int = sideways.size()
	for i in range(n):
		if not sideways[i]:
			continue
		var lo: float = minf(float(pad_perp[i]), float(lane_perp[i])) - _MIN_SEGMENT_MM
		var hi: float = maxf(float(pad_perp[i]), float(lane_perp[i])) + _MIN_SEGMENT_MM
		var row: float = float(pad_axial[i])
		for j in range(n):
			if j == i:
				continue
			var need: float = pitch_between(float(widths[i]), float(widths[j]), clearance) \
				- _CLEARANCE_TOLERANCE_MM
			var lane_in_band: bool = float(lane_perp[j]) >= lo and float(lane_perp[j]) <= hi
			var pad_in_band: bool = float(pad_perp[j]) >= lo and float(pad_perp[j]) <= hi
			if sideways[j]:
				var lo_j: float = minf(float(pad_perp[j]), float(lane_perp[j]))
				var hi_j: float = maxf(float(pad_perp[j]), float(lane_perp[j]))
				# One row or two: a pair within a pitch of each other is one
				# crowded row and is named ONCE, as that, never also as a
				# crossing from the other side of the pair.
				var same_row: bool = absf(row - float(pad_axial[j])) < need
				if same_row and j < i:
					continue
				if same_row and lo <= hi_j + need and lo_j <= hi + need:
					out.append(_finding(FINDING_PADS_ALONG_SPINE,
						"Nets \"%s\" and \"%s\" both lie along the spine at the %s end, each in a pad column that runs beside the bundle, and their two pads share a row (%.3fmm apart along the spine, where two legs need %.3fmm) — each leaves its column sideways in its own row, so their legs would run over each other. Draw the spine so it leaves this pad group across the columns, or bus the two columns separately."
							% [net_names[i], net_names[j], end_label,
								absf(row - float(pad_axial[j])), need],
						[net_names[i], net_names[j]], absf(row - float(pad_axial[j])), need))
				elif not same_row and lane_in_band and float(pad_axial[j]) < row:
					out.append(_finding(FINDING_END_CROSSING,
						"Nets \"%s\" and \"%s\" cross at the %s end — both lie along the spine in a pad column beside the bundle, and \"%s\", the pad further out along that column, rides a lane between \"%s\"'s pad and its own lane. Pick the nets so the pad furthest along the column takes the lane furthest from it."
							% [net_names[i], net_names[j], end_label, net_names[j], net_names[i]],
						[net_names[i], net_names[j]]))
				continue
			var lo_j: float = minf(float(pad_perp[j]), float(lane_perp[j])) - _MIN_SEGMENT_MM
			var hi_j: float = maxf(float(pad_perp[j]), float(lane_perp[j])) + _MIN_SEGMENT_MM
			if float(lane_perp[i]) >= lo_j and float(lane_perp[i]) <= hi_j:
				out.append(_finding(FINDING_END_CROSSING,
					"Nets \"%s\" and \"%s\" cross at the %s end — \"%s\" lies along the spine in a pad column beside the bundle and its lane runs from its own row, so \"%s\"'s leg into the bundle has to cross it. Pick the nets so \"%s\" rides a lane on the pad side of \"%s\", or move its pad."
						% [net_names[i], net_names[j], end_label, net_names[i], net_names[j],
							net_names[j], net_names[i]],
					[net_names[i], net_names[j]]))
			elif pad_in_band and float(pad_axial[j]) <= row + _MIN_SEGMENT_MM:
				out.append(_finding(FINDING_END_CROSSING,
					"Nets \"%s\" and \"%s\" cross at the %s end — \"%s\" lies along the spine in a pad column beside the bundle and leaves it sideways in its own row, and \"%s\"'s leg runs along the spine through that row. Move \"%s\"'s pad clear of the row, or redraw the spine."
						% [net_names[i], net_names[j], end_label, net_names[i], net_names[j],
							net_names[j]],
					[net_names[i], net_names[j]]))
	return out


## Two nets from a cycle of "leaves first" rules, named in a finding.
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
