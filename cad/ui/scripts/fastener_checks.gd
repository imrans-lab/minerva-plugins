extends RefCounted
## fastener_checks.gd — will this screw actually go in?
##
## An enclosure is bolted to a board. Everything about that joint is a number
## somebody has to be right about: the boss has to line up with the hole, the
## screw has to REACH the boss without meeting a capacitor on the way, it has
## to bite deep enough to hold, and the head has to land on something flat. An
## LLM iterating on the DSL can see none of that, and a picture of it says
## nothing — so this check answers all four with millimetres, per screw.
##
## WHY A MODULE OF ITS OWN. geometry_checks.gd already holds the ray-walk
## interference check, the blob transport and the clearance report; this is a
## fourth subsystem and it goes beside them rather than inside them. What it
## does BORROW from that module is the one thing it must not duplicate: the
## solid's collider and the world it lives in. A second collider for the same
## body, rebuilt on its own schedule, is two answers about one shape.
##
## THE FOUR QUESTIONS, AND WHAT EACH ONE IS WORTH
##
## COAXIALITY — graded as ISO 1101 grades it. The reference hole's axis is the
## datum; the solid's bore axis is the toleranced feature; the tolerance zone
## is a CYLINDER of diameter t about the datum, and the reported zone_dia_mm is
## twice the larger of the bore axis's radial offsets at the two ends of the
## engaged length. That single number carries both the sideways error and the
## tilt, which is why the standard states it that way, and axis_angle_deg and
## centre_offset_mm are reported beside it so the reader can see which one
## dominates. The allowance comes from the clearance the screw actually has:
## ISO 273 medium series, so an M3 through a 3.4 mm hole may wander (3.4-3)/2 =
## 0.2 mm radially, i.e. a 0.4 mm zone. A diameter with no ISO 273 medium entry
## is NOT interpolated: the row comes back with graded=false, allowed_mm null
## and pass null, the offsets still measured, and it does NOT fail the screw —
## nobody said what clearance that screw gets, which is not the same as the
## joint being wrong. State clearance_hole_dia_mm to have it graded.
##
## PATH — a fan of rays along the screw axis: one on the axis, a ring at the
## shank radius, and a ring at the head radius. The rings are spaced so no gap
## between adjacent rays exceeds RING_SPACING_MM, because a sampled cylinder
## can miss an obstruction thinner than its spacing and this is the constraint
## that bounds what it can miss. Every ray starts OUTSIDE every body (a ray
## launched inside a wall reports nothing against a concave shape) and is
## judged over the span it has to be clear over: the shank from outside to the
## bore's mouth, the head from outside to the seat. Anything hit inside that
## span is an obstruction and is reported with its node and its point — which
## includes the reference's own hole wall when the hole is too small for the
## screw, and that is the correct answer, not a false positive. The SHANK fan
## also sees the solid, so a rib the shell grew across the bore is caught; the
## two hits that are the screw ARRIVING — the bore wall inside its own radius
## and span, and the boss's end face within a band of the mouth derived from
## the boss's own measured tilt — are filtered out by name. The HEAD ring sees
## the references only: it never has to reach the bore, and the solid on its
## span is the top of the boss it is sitting on.
##
## ENGAGEMENT — the overlap of the screw's length, measured from the seat, with
## the bore's axial extent. Graded against a material default: thread-forming
## screws in a thermoplastic boss want 2.0 x d, which is `engagement_min_d`'s
## default; metal-to-metal is 1.0 to 1.5 and the caller states it.
##
## HEAD SEAT — the head ring must reach the seat plane with nothing in front of
## it, and must find material there to sit on. A head hanging over the edge of
## its seat is reported as the fraction of the ring that landed.
##
## WHERE EVERY NUMBER COMES FROM, SAID OUT LOUD
## The solid is an OCCT B-Rep and only its TESSELLATION reaches the panel. So
## the bore axes are asked of the worker (cad.cylindrical_features), where they
## are exact, and the panel fits the tessellation only for a feature the kernel
## has no cylindrical face for. Every screw row carries axis_source (b_rep or
## tessellation_fit) and the tessellation_tolerance_mm in force, and where both
## sources exist for one feature the row carries their disagreement — which is
## the measurement that licenses the fallback in the first place.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/fastener_checks.gd") from CADPanel.gd.

const _MeshFeatures: Script = preload("mesh_features.gd")
const _WorkerReply: Script = preload("worker_reply.gd")

## The IPC channel that answers with the solid's B-Rep cylinders. Channel name
## = MCP tool name; the worker method behind it is "cylindrical_features".
const FEATURES_CHANNEL: String = "cad.cylindrical_features"
## Reading faces off a B-Rep costs one translate of the DSL, which is the same
## work an evaluation already does; a shell with a hundred bosses is still
## seconds, not minutes.
const FEATURES_TIMEOUT_MS: int = 60000

## Tessellation deviation quoted with every fitted number. The fallback fit
## works on the DISPLAY mesh, whose deviation is the evaluation's own, so this
## is reported as the tolerance in force rather than requested.
const DISPLAY_TOLERANCE_MM: float = 0.1

## ISO 273:1979 medium series clearance holes, millimetres: screw diameter to
## hole diameter. Medium is the series graded against; fine and coarse exist
## and are NOT interpolated between, because a wrong allowance silently passes
## a joint that will not go together.
const ISO_273_MEDIUM: Dictionary = {
	1.6: 1.8, 2.0: 2.4, 2.5: 2.9, 3.0: 3.4, 3.5: 3.9, 4.0: 4.5, 5.0: 5.5,
	6.0: 6.6, 8.0: 9.0, 10.0: 11.0, 12.0: 13.5, 14.0: 15.5, 16.0: 17.5,
	18.0: 20.0, 20.0: 22.0, 22.0: 24.0, 24.0: 26.0,
}
## A named diameter matches a table row within this. Screw sizes are exact
## numbers, so this only absorbs the float literal a caller wrote.
const SIZE_EPSILON_MM: float = 0.001

## Thread-forming screws in a thermoplastic boss want two diameters of
## engagement (Plastite and the moulding boss-design guides put the usable band
## at 1.7-2.2 d); metal-to-metal wants 1.0-1.5 and the caller says so.
const DEFAULT_ENGAGEMENT_D: float = 2.0

## No two adjacent rays of a ring may be further apart than this along the
## circle. It is the whole guarantee the path check makes: an obstruction
## narrower than this can pass between two rays unseen. At an M3 shank radius
## of 1.5 mm it works out at 19 rays.
const RING_SPACING_MM: float = 0.5
const MIN_RING_RAYS: int = 8
const MAX_RING_RAYS: int = 128

## Pairing limits. A boss more than this far from a hole's axis, or tilted more
## than this against it, is not that hole's boss — it is an unpaired feature,
## and saying so is more useful than pairing it and reporting a huge error.
const PAIR_MAX_OFFSET_MM: float = 3.0
const PAIR_MAX_ANGLE_DEG: float = 20.0

## The agreement gate the fallback is licensed by: a fitted axis and a B-Rep
## axis for the same feature must agree to this, or the fit cannot be trusted
## at the ISO 273 margin.
const AGREEMENT_CENTRE_MM: float = 0.01
const AGREEMENT_ANGLE_DEG: float = 0.05

## How far outside the scene a path ray starts, in millimetres. Constraint 2 of
## geometry_checks: a ray must begin outside every body.
const OUTSIDE_MARGIN_MM: float = 5.0

## How far past a hit the next cast starts when walking a ray through a stack.
const CROSSING_ADVANCE_MM: float = 0.0002
## A solid surface this close to the bore's own radius IS the bore wall. It
## absorbs the chordal error of a tessellated wall, nothing more.
const BORE_WALL_TOLERANCE_MM: float = 0.05
## How far short of its end plane a path span stops. A shank ring ray at the
## thread radius meets the boss's own face AT the mouth of the bore, and a head
## ring ray meets the board AT the seat: both are the screw ARRIVING, and a
## span that included its own end plane would report every good joint as
## blocked. Small enough that anything actually in the way is still caught.
const PATH_END_EPSILON_MM: float = 0.01
## Surfaces one path ray may cross before it gives up.
const MAX_CROSSINGS_PER_RAY: int = 32
## Obstructions listed per screw. The first one is the one that gets fixed.
const MAX_OBSTRUCTIONS: int = 8

## Every collision layer at once — the unscoped mask, matching mesh_gauge.
const ALL_LAYERS: int = 0xFFFFFFFF


## The reference records the running check was started with, for the poses that
## turn a world point into the reference's own frame.
var _records: Array = []
## Ray casts spent by the running check.
var _casts: int = 0
## Rays the running check's path fans placed, summed over every screw. Reported
## beside the spacing so a reader can see how densely the disc was covered.
var _path_rays: int = 0
## The widest gap the running check actually left between two adjacent rays
## along a ring, millimetres. It is RING_SPACING_MM or less everywhere except
## on a ring wide enough to hit MAX_RING_RAYS, and the reply reports the
## measured number rather than the nominal one so the miss bound is never a
## claim the fan did not keep.
var _widest_arc_mm: float = 0.0
## Wall clock of the running check, microseconds.
var _started_us: int = 0


# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

## Run the whole fastener check for `panel` and return the report:
##
##   {checked, units, count, pass, screw, engagement_min_d,
##    tessellation_tolerance_mm, screws: [...], unpaired: {...},
##    casts, ray_spacing_mm, elapsed_ms}
##
## `args`:
##   screw            {dia_mm, length_mm, head_dia_mm?} — dia and length are
##                    mandatory; a check with no screw in it is not a check.
##   holes            the reference holes to pair against, as
##                    minerva_cad_find_holes reports them. The verb supplies
##                    these; this module never segments a reference itself.
##   pairs            [{solid_feature: <index>, reference_hole: <index>}] to
##                    override the automatic pairing.
##   engagement_min_d multiples of the screw diameter required (default 2.0).
##   clearance_hole_dia_mm  the ISO 273 allowance when the size is not in the
##                    medium table.
##   reference, node  scope, passed straight through to the mask.
##
## `checked` false with a `reason` is not the same answer as "every screw
## passes", and a reader that cannot tell them apart trusts a check that never
## ran.
func check(panel: Object, args: Dictionary = {}) -> Dictionary:
	if panel == null or not is_instance_valid(panel):
		return _nothing("the CAD panel is gone")

	var screw := _screw_from(args)
	if screw.has("error"):
		return _nothing(str(screw["error"]))

	var gauge: Node = panel.get_mesh_gauge() if panel.has_method("get_mesh_gauge") else null
	if gauge == null or not is_instance_valid(gauge) or not gauge.is_inside_tree():
		return _nothing("the measurement gauge is not available on this panel")
	if int(panel.ensure_gauge_built()) <= 0:
		return _nothing("no reference mesh is mounted; there is nothing to screw into")

	var holes: Array = args.get("holes", []) as Array
	if holes.is_empty():
		return _nothing("no reference hole was given to pair against; run "
			+ "minerva_cad_find_holes first, or widen its diameter window")

	var checks: Object = panel.get_geometry_checks() \
		if panel.has_method("get_geometry_checks") else null
	if checks == null or not is_instance_valid(checks):
		return _nothing("the solid's collider is not available on this panel")

	var document: Dictionary = {}
	if panel.has_method("get_document_state"):
		document = panel.get_document_state()
	var mesh_data: Dictionary = document.get("mesh", {}) as Dictionary

	# The references AS THEY ARE NOW, before anything is awaited. Every local
	# coordinate in the reply is a world point taken back through one of these
	# poses, and the panel's own state can be re-posed — or replaced by
	# another call's evaluation — while this one waits for the worker. A check
	# that read the poses afterwards would report this screw's geometry in
	# another document's frame.
	var records: Array = panel.get_reference_state() \
		if panel.has_method("get_reference_state") else []
	# The COLLIDERS those poses describe, by the generation mesh_gauge counts
	# its rebuilds with. The snapshot above fixes the frame every local
	# coordinate is converted through; this fixes the geometry the rays are
	# cast against. Casting against one epoch and converting through the other
	# is a reply whose world numbers are all right and whose local ones are
	# all wrong — the worst shape a wrong answer can take.
	var epoch := int(gauge.call("get_generation"))

	# The B-Rep first, and OUTSIDE the reservation: it is an IPC round trip to
	# the worker, and holding the solid's collider across it would stall every
	# evaluation for its duration.
	var features := await _solid_cylinders(panel, str(document.get("source", "")), screw)

	# The references were rebuilt while this check waited for the worker, so
	# the geometry the rays would meet is no longer the geometry the question
	# was asked about. GOING AGAIN IS NOT AN OPTION HERE: the reference HOLES
	# arrived in `args`, measured by minerva_cad_find_holes at the world
	# positions of the old pose, and this module never segments a reference
	# itself. Adopting the new colliders while pairing and seating against
	# those old holes is the mixed epoch in its worst form — every number
	# self-consistent, every one about a document that no longer exists. The
	# caller re-runs find_holes and asks again.
	if int(gauge.call("get_generation")) != epoch:
		return _stale("the reference meshes were rebuilt while this check "
			+ "waited for the worker, so the holes it was given no longer "
			+ "describe where those references are; run "
			+ "minerva_cad_find_holes again and re-ask")

	# Un-queued: this check only ever runs because an agent asked for it, and
	# an agent is better served by "retry" than by an invisible wait.
	var reservation: Dictionary = await checks.call("reserve", false)
	var ticket := int(reservation.get("ticket", 0))
	if ticket == 0:
		# The interference module owns the solid's collider and hands out one
		# reservation at a time; a refusal is its answer, not this module's.
		return checks.call("refused", reservation)

	var report := await _run(gauge, checks, mesh_data, features, holes,
		screw, args, ticket, records)
	# The colliders the rays were cast against are the ones the poses above
	# describe, or the answer is two epochs stitched together.
	if int(gauge.call("get_generation")) != epoch:
		checks.call("release_reservation", ticket)
		return _stale("the reference meshes were rebuilt while this check was "
			+ "measuring, so its rays and its poses would not describe one "
			+ "state of the document")
	# Reclaimed while this check was awaiting a physics step: the solid's
	# collider belongs to another check now, so this one releases nothing.
	if not bool(checks.call("holds", ticket)):
		report["superseded"] = true
		report["superseded_reason"] = "this check was reclaimed after its " \
			+ "deadline and another check owns the panel's geometry now"
		return report
	checks.call("release_reservation", ticket)
	return report


func _run(
	gauge: Node,
	checks: Object,
	mesh_data: Dictionary,
	features: Dictionary,
	holes: Array,
	screw: Dictionary,
	args: Dictionary,
	ticket: int,
	records: Array
) -> Dictionary:
	# Counters first, so a check that returns early — no bore, no pair — never
	# reports the PREVIOUS check's ray counts, spacing or elapsed time in its
	# envelope.
	_started_us = Time.get_ticks_usec()
	_casts = 0
	_path_rays = 0
	_widest_arc_mm = 0.0
	_records = records
	# The solid's collider belongs to the interference module and is freed on
	# every rebuild, so the ticket travels with the request: a caller that is
	# not the holder is refused rather than allowed to free a body another
	# check is casting against.
	var triangles := int(checks.call("build_solid", mesh_data, ticket))
	if triangles < 0:
		return _nothing("another check holds this panel's geometry; nothing "
			+ "was measured")
	if triangles == 0:
		return _nothing("the evaluation produced no solid geometry to check")

	# The fallback, and the measurement that licenses it. The fit runs whenever
	# the B-Rep is unavailable OR the caller asked for the comparison, so the
	# agreement gate has both numbers to compare on a boss both sources know.
	var fitted: Array = []
	var fit_reason := ""
	if features.get("cylinders", []).is_empty() or bool(args.get("compare_fit", false)):
		var fit := _fit_solid_cylinders(mesh_data, screw)
		fitted = fit.get("cylinders", []) as Array
		fit_reason = str(fit.get("reason", ""))

	var bores: Array = features.get("cylinders", []) as Array
	var axis_source := "b_rep"
	if bores.is_empty():
		bores = fitted
		axis_source = "tessellation_fit"
	if bores.is_empty():
		var reason := "the solid has no cylindrical feature to put a screw in"
		if not str(features.get("reason", "")).is_empty():
			reason += " (%s)" % str(features["reason"])
		elif not fit_reason.is_empty():
			reason += " (%s)" % fit_reason
		return _nothing(reason)

	var reference_scope := str(args.get("reference", ""))
	var mask := ALL_LAYERS
	if not reference_scope.is_empty():
		mask = int(gauge.call("mask_for", reference_scope))

	var pairing := _pair(bores, holes, args)
	# The surfaces that were never candidates, named rather than dropped: a
	# reader looking for a bore the check did not grade has to be able to see
	# why it was not one.
	var partial: Array = features.get("partial", []) as Array
	if not partial.is_empty():
		var unpaired: Dictionary = pairing["unpaired"]
		var loose: Array = unpaired.get("solid_features", []) as Array
		loose.append_array(partial)
		unpaired["solid_features"] = loose
	if pairing["pairs"].is_empty():
		var empty := _report([], pairing, screw, args, axis_source)
		empty["note"] = "no solid bore lines up with any of the reference " \
			+ "holes given; every feature is listed under `unpaired`"
		return empty

	# The rays run inside mesh_gauge's physics step: the references' space is
	# only legal to dereference there, and the solid's own space has the same
	# rule. Both are queried in ONE step, so a screw's path is measured against
	# one state of the world rather than two.
	var answer: Dictionary = await gauge.call("submit", "fasteners", {
		"module": self,
		# Read back in run_check: the job runs after an await, which is where
		# a reclaimed reservation wakes up, and nothing may be written on a
		# ticket that is no longer the holder's.
		"ticket": ticket,
		"mask": mask,
		"reference": reference_scope,
		"node": str(args.get("node", "")),
		"checks": checks,
		"pairs": pairing["pairs"],
		"screw": screw,
		"args": args,
		"axis_source": axis_source,
		"fitted": fitted,
	})
	if answer.has("error"):
		return _nothing(str(answer["error"]))
	answer["unpaired"] = pairing["unpaired"]
	if not fit_reason.is_empty():
		answer["fit_note"] = fit_reason
	return answer


## The job body, run by mesh_gauge inside its physics step with the reference
## space's direct state in hand. `state` is the references' space; the solid's
## own space belongs to the geometry_checks module travelling in the job.
func run_check(gauge: Object, state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	# Everything below reads the solid's collider and writes this module's
	# counters. A reservation reclaimed while the job queued for its physics
	# step owns neither, so it writes nothing and says so.
	var ticket := int(args.get("ticket", 0))
	var checks: Object = args.get("checks", null)
	if ticket != 0 and checks != null and is_instance_valid(checks) \
			and not bool(checks.call("holds", ticket)):
		return _nothing("this check's reservation was reclaimed before its "
			+ "physics step came; another check owns the panel's geometry")
	var solid_state: PhysicsDirectSpaceState3D = checks.call("solid_space") \
		if checks != null and is_instance_valid(checks) else null
	if solid_state == null:
		return {"error": "the solid's collider world is not available"}

	var screw: Dictionary = args.get("screw", {}) as Dictionary
	var verb_args: Dictionary = args.get("args", {}) as Dictionary
	var mask := int(args.get("mask", ALL_LAYERS))
	var reference_scope := str(args.get("reference", ""))
	var reach := _scene_reach(checks)

	var rows: Array = []
	for entry in args.get("pairs", []):
		rows.append(_one_screw(
			gauge, state, solid_state, checks, entry as Dictionary,
			screw, verb_args, mask, reference_scope, reach,
			args.get("fitted", []) as Array
		))
	return _report(rows, {"pairs": args.get("pairs", []), "unpaired": {}},
		screw, verb_args, str(args.get("axis_source", "b_rep")))


# ---------------------------------------------------------------------------
# One screw
# ---------------------------------------------------------------------------

## Everything about one paired (bore, hole): the four questions, in the order
## the numbers become available. The screw axis is the REFERENCE HOLE's axis,
## because the hole is what locates the screw — the boss is the thing being
## judged against it, and grading a feature against itself grades nothing.
func _one_screw(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	solid_state: PhysicsDirectSpaceState3D,
	checks: Object,
	pair: Dictionary,
	screw: Dictionary,
	verb_args: Dictionary,
	mask: int,
	reference_scope: String,
	reach: float,
	fitted: Array
) -> Dictionary:
	var bore: Dictionary = pair["bore"]
	var hole: Dictionary = pair["hole"]
	var hole_axis: Vector3 = pair["hole_axis"]
	var hole_centre: Vector3 = pair["hole_centre"]
	var bore_axis: Vector3 = pair["bore_axis"]
	var bore_start: Vector3 = pair["bore_start"]
	var bore_end: Vector3 = pair["bore_end"]

	# +axis is the direction the screw travels: from the hole into the bore.
	var direction := hole_axis
	if direction.dot(bore_start - hole_centre) < 0.0:
		direction = -direction

	var dia := float(screw["dia_mm"])
	var length := float(screw["length_mm"])
	var head_dia := float(screw["head_dia_mm"])

	# Axial coordinates are distances along `direction` from the hole centre.
	# One frame for the whole screw, so seat, bore and screw length are
	# comparable numbers rather than three sets of points.
	# The seat plane is half the plate's thickness above the hole's centre, so
	# a hole record with no thickness in it has NO seat — and defaulting to
	# zero would put the seat at the centre of the plate and shift every axial
	# number by half of it, silently. Refuse instead.
	var thickness := float(hole.get("depth_mm", 0.0))
	if thickness <= 0.0:
		thickness = float(hole.get("extent_mm", 0.0))
	if thickness <= 0.0:
		return _unmeasurable(hole, bore,
			"the hole record carries neither depth_mm nor extent_mm, so there "
			+ "is no seat plane to measure the screw from; "
			+ "minerva_cad_find_holes reports depth_mm on a verified hole")
	var seat_t := -thickness * 0.5
	var bore_entry_t := (bore_start - hole_centre).dot(direction)
	var bore_exit_t := (bore_end - hole_centre).dot(direction)
	if bore_exit_t < bore_entry_t:
		var swap := bore_entry_t
		bore_entry_t = bore_exit_t
		bore_exit_t = swap
	# The bore's WALL, which reaches past the engaged span wherever a tilted
	# trim leaves material on one side only. The fan reads this one: a hit on
	# the wall above the engaged span is still the screw arriving.
	var wall_entry_t := bore_entry_t
	var wall_exit_t := bore_exit_t
	if bore.has("wall_start") and bore.has("wall_end"):
		wall_entry_t = ((bore["wall_start"] as Vector3) - hole_centre).dot(direction)
		wall_exit_t = ((bore["wall_end"] as Vector3) - hole_centre).dot(direction)
		if wall_exit_t < wall_entry_t:
			var wall_swap := wall_entry_t
			wall_entry_t = wall_exit_t
			wall_exit_t = wall_swap

	# ISO 1101: the zone is measured over the length the screw is actually in
	# the bore for, not over the whole feature.
	var engaged_from := maxf(bore_entry_t, seat_t)
	var engaged_to := minf(bore_exit_t, seat_t + length)
	var engagement := maxf(0.0, engaged_to - engaged_from)
	var min_d := float(verb_args.get("engagement_min_d", DEFAULT_ENGAGEMENT_D))
	var engagement_required := min_d * dia

	var coaxiality := _coaxiality(
		hole_centre, direction, bore_start, bore_axis,
		engaged_from, engaged_to if engagement > 0.0 else bore_exit_t,
		seat_t, dia, verb_args
	)

	# The rays. Everything starts outside every body, on the head side.
	var origin := hole_centre + direction * (seat_t - OUTSIDE_MARGIN_MM - reach)
	var start_t := seat_t - OUTSIDE_MARGIN_MM - reach

	# The shank has to be clear from outside down to the mouth of the bore.
	# Past that it is expected to meet material: a thread-forming screw bites,
	# and a check that called that an obstruction would fail every good joint.
	#
	# The MOUTH BAND is derived, not guessed. The only solid the shank fan can
	# legitimately meet on this span is the boss's own end face, and the one
	# thing that lifts part of that face above the mouth of its bore is the
	# boss's own tilt. The rise is the tilt's tangent times how far from the
	# BORE's axis the ray is — and the fan is centred on the HOLE's axis, so
	# that reach is the fan radius plus the offset between the two. Both
	# numbers have already been measured by the lines above; nothing here is a
	# tolerance somebody chose.
	var mouth_reach := dia * 0.5 + float(coaxiality["centre_offset_mm"])
	var mouth_band := mouth_reach \
		* tan(deg_to_rad(float(coaxiality["axis_angle_deg"]))) \
		+ PATH_END_EPSILON_MM
	var expected := {
		"point": bore_start,
		"axis": bore_axis,
		"radius": float(bore.get("dia_mm", 0.0)) * 0.5,
		"from_t": wall_entry_t,
		"to_t": wall_exit_t,
		"band": mouth_band,
		"datum": hole_centre,
		"direction": direction,
	}
	var shank := _fan_clear(
		gauge, state, solid_state, checks, origin, direction,
		dia * 0.5, start_t, wall_entry_t - PATH_END_EPSILON_MM,
		hole_centre, mask, reference_scope, expected
	)
	var head := {"clear": true, "obstructions": [], "rays": 0}
	var seat := {"landed": 0, "rays": 0}
	if head_dia > 0.0:
		head = _fan_clear(
			gauge, state, solid_state, checks, origin, direction,
			head_dia * 0.5, start_t, seat_t - PATH_END_EPSILON_MM,
			hole_centre, mask, reference_scope, {}
		)
		seat = _seat_support(
			gauge, state, origin, direction, head_dia * 0.5, dia * 0.5,
			seat_t, hole_centre, mask, reference_scope
		)

	_path_rays += int(shank["rays"]) + int(head["rays"])
	# Conservative: the bore's own extent carries a measurement bound, and the
	# grade is taken on the short end of it. An extent that is not exact, or
	# whose bound is only a floor, cannot be graded at all — the screw is not
	# failed for a modelling detail, it is reported as UNKNOWN, which is not a
	# pass either.
	var engagement_bound := float(bore.get("extent_bound_mm", 0.0))
	var extent_certain := bool(bore.get("extent_exact", true)) \
		and bool(bore.get("extent_bounded", true))
	var engagement_ok := extent_certain \
		and engagement - engagement_bound >= engagement_required
	var head_seat_clear := bool(head["clear"])
	var row := {
		"reference": str(hole.get("reference", "")),
		"node": str(hole.get("node", "")),
		"axis_source": str(bore.get("source", "b_rep")),
		"tessellation_tolerance_mm": DISPLAY_TOLERANCE_MM,
		"hole_dia_mm": float(hole.get("dia_mm", 0.0)),
		"hole_gauge_dia_mm": float(hole.get("gauge_dia_mm", 0.0)),
		"bore_dia_mm": float(bore.get("dia_mm", 0.0)),
		"screw_axis": _axes(direction, str(hole.get("reference", ""))),
		"seat_mm": _frames(hole_centre + direction * seat_t, str(hole.get("reference", ""))),
		"coaxiality": coaxiality["zone"],
		"axis_angle_deg": coaxiality["axis_angle_deg"],
		"centre_offset_mm": coaxiality["centre_offset_mm"],
		"path_clear": bool(shank["clear"]),
		"path_rays": int(shank["rays"]),
		"engagement_mm": engagement,
		# What the number is worth. engagement_ok is graded on
		# engagement_mm - engagement_bound_mm, so a bite inside the bound of
		# the threshold is not credited with clearing it.
		"engagement_bound_mm": engagement_bound,
		"engagement_certain": extent_certain,
		"engagement_required_mm": engagement_required,
		"engagement_ok": engagement_ok,
		"head_seat_clear": head_seat_clear,
		# The span the screw can engage over (full circumference) and the span
		# the bore's wall occupies. They differ by whatever a tilted trim cut
		# off one side of the mouth.
		"bore_extent_mm": {"entry": bore_entry_t, "exit": bore_exit_t},
		"bore_wall_extent_mm": {"entry": wall_entry_t, "exit": wall_exit_t},
	}
	if not bool(shank["clear"]):
		row["obstructions"] = shank["obstructions"]
	if head_dia > 0.0:
		# The fraction of the SEAT RING that landed, over that ring's own ray
		# count. The head fan is a different ring at a different radius, and
		# dividing by it could never reach 1.0 on a perfectly seated screw.
		row["head_seat_supported"] = float(seat["landed"]) \
			/ maxf(1.0, float(seat["rays"]))
		row["head_seat_rays"] = int(seat["rays"])
		row["head_seat_radius_mm"] = float(seat["radius_mm"])
		row["head_seat_rule"] = ("circumference coverage at one radius, not "
			+ "bearing area: the fraction of a single ring of rays at "
			+ "%.3f mm from the axis that met reference material within "
			+ "%s mm of the seat plane, so an annular void inside that ring "
			+ "is not seen") % [float(seat["radius_mm"]), RING_SPACING_MM]
		if not head_seat_clear:
			row["head_obstructions"] = head["obstructions"]
	if bore.get("source", "b_rep") == "b_rep":
		var agreement := _agreement(bore, fitted, direction)
		if not agreement.is_empty():
			row["fit_agreement"] = agreement
	# An UNGRADED coaxiality does not fail the screw. There is no allowance to
	# judge it against, the numbers are still reported, and failing on the
	# absence of a table entry would read as "this joint is wrong" when what
	# happened is "nobody said what clearance this screw gets".
	var zone: Dictionary = coaxiality["zone"]
	var coaxiality_ok := (not bool(zone.get("graded", false))) \
		or bool(zone.get("pass", false))
	row["pass"] = coaxiality_ok \
		and bool(shank["clear"]) and engagement_ok and head_seat_clear
	row["why"] = _why(row)
	return row


## The ISO 1101 coaxiality zone, and the two numbers that make it up.
##
## The zone is a cylinder about the DATUM (the hole's axis) that must contain
## the toleranced axis over the toleranced length, so its diameter is twice the
## larger of the bore axis's radial offsets at the two ends of that length.
## Its allowance is what the screw's own clearance gives it: the radial slack
## in an ISO 273 medium hole, doubled to a diameter.
func _coaxiality(
	datum_point: Vector3,
	datum_axis: Vector3,
	bore_point: Vector3,
	bore_axis: Vector3,
	from_t: float,
	to_t: float,
	seat_t: float,
	screw_dia: float,
	verb_args: Dictionary
) -> Dictionary:
	var aligned := bore_axis if bore_axis.dot(datum_axis) >= 0.0 else -bore_axis
	var angle := rad_to_deg(aligned.angle_to(datum_axis))
	var offset_start := _radial_offset(datum_point, datum_axis, bore_point, aligned, from_t)
	var offset_end := _radial_offset(datum_point, datum_axis, bore_point, aligned, to_t)
	var zone_dia := 2.0 * maxf(offset_start, offset_end)
	# The centre offset is quoted AT THE SEAT, where the screw passes the
	# board: it is the number that says whether the shank still fits the hole.
	var centre_offset := _radial_offset(
		datum_point, datum_axis, bore_point, aligned, seat_t)

	var allowance := _iso_273_allowance(screw_dia, verb_args)
	var zone := {
		"offset_start_mm": offset_start,
		"offset_end_mm": offset_end,
		"zone_dia_mm": zone_dia,
		"standard": "ISO 1101 coaxiality zone: a cylinder of diameter "
			+ "zone_dia_mm about the hole axis containing the bore axis over "
			+ "the engaged length",
	}
	if allowance.has("radial_mm"):
		zone["graded"] = true
		zone["allowed_mm"] = float(allowance["radial_mm"])
		zone["allowed_zone_dia_mm"] = float(allowance["radial_mm"]) * 2.0
		zone["clearance_hole_dia_mm"] = float(allowance["hole_dia_mm"])
		zone["clearance_source"] = str(allowance["source"])
		zone["pass"] = zone_dia <= float(allowance["radial_mm"]) * 2.0
	else:
		# UNGRADED, which is not the same as failed: the offsets and the zone
		# are measured and reported, and only the verdict is withheld.
		zone["graded"] = false
		zone["allowed_mm"] = null
		zone["pass"] = null
		zone["clearance_source"] = str(allowance["reason"])
	return {
		"zone": zone,
		"axis_angle_deg": angle,
		"centre_offset_mm": centre_offset,
	}


## Distance from the datum axis to the bore axis, measured in the plane at
## axial coordinate `t` along the datum.
func _radial_offset(
	datum_point: Vector3,
	datum_axis: Vector3,
	bore_point: Vector3,
	bore_axis: Vector3,
	t: float
) -> float:
	var plane_origin := datum_point + datum_axis * t
	# Where the bore axis crosses that plane. A bore axis parallel to the plane
	# never crosses it, which cannot happen here: pairing already refused any
	# bore more than PAIR_MAX_ANGLE_DEG off the datum.
	var denominator := bore_axis.dot(datum_axis)
	if absf(denominator) < 0.000001:
		return INF
	var travel := (plane_origin - bore_point).dot(datum_axis) / denominator
	var crossing := bore_point + bore_axis * travel
	return (crossing - plane_origin).length()


## The radial slack an ISO 273 medium clearance hole gives this screw, or a
## reason there is no number. Never interpolated: a size not in the table is
## the caller's to state.
func _iso_273_allowance(screw_dia: float, verb_args: Dictionary) -> Dictionary:
	var stated := float(verb_args.get("clearance_hole_dia_mm", 0.0))
	if stated > 0.0:
		return {
			"radial_mm": maxf(0.0, (stated - screw_dia) * 0.5),
			"hole_dia_mm": stated,
			"source": "clearance_hole_dia_mm stated by the caller",
		}
	for size in ISO_273_MEDIUM.keys():
		if absf(float(size) - screw_dia) <= SIZE_EPSILON_MM:
			var hole_dia := float(ISO_273_MEDIUM[size])
			return {
				"radial_mm": (hole_dia - screw_dia) * 0.5,
				"hole_dia_mm": hole_dia,
				"source": "ISO 273:1979 medium series, M%s -> %s mm"
					% [screw_dia, hole_dia],
			}
	return {
		"reason": "no ISO 273 medium clearance is tabulated for a %s mm screw, "
			% screw_dia + "and the series is not interpolated between; state "
			+ "clearance_hole_dia_mm to grade the coaxiality",
	}


# ---------------------------------------------------------------------------
# The ray fan
# ---------------------------------------------------------------------------

## Is the span [from_t, to_t] along the axis clear for a cylinder of `radius`?
##
## The whole DISC is sampled, not its rim: concentric rings out to `radius`
## with the axis in the middle, no two adjacent rays further apart than
## RING_SPACING_MM either radially or around a ring. A rim-only fan cannot see
## a rib at half the shank radius no matter how finely it is spaced around,
## and that is exactly where a rib bridging a bore sits. The spacing IS the
## guarantee: an obstruction narrower than it can pass between two rays
## unseen. Every ray starts at `origin`, which the caller has already put
## outside every body.
##
## WHICH BODIES COUNT. Every ray sees the references. Whether it also sees the
## SOLID depends on `expected`: pass the bore's geometry and the fan sees the
## solid too, with the hits that are the screw ARRIVING filtered out —
##
##   a hit inside the bore's own radius and inside its axial span is the bore
##   wall or its mouth;
##   a hit within `band` of the mouth is the boss's own end face, which its
##   tilt lifts above the mouth across the width of the fan.
##
## Anything else on the solid is a genuine obstruction: a rib modelled across
## the bore, a lid over the hole, a wall the shell grew into the gap. Pass an
## empty `expected` and the fan sees the references only — which is what the
## HEAD ring does, because the head never has to reach the bore and the solid
## it would meet on its own span is the top of the boss it is sitting on.
func _fan_clear(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	solid_state: PhysicsDirectSpaceState3D,
	checks: Object,
	origin: Vector3,
	direction: Vector3,
	radius: float,
	from_t: float,
	to_t: float,
	datum: Vector3,
	mask: int,
	reference_scope: String,
	expected: Dictionary
) -> Dictionary:
	var obstructions: Array = []
	var rays := _disc_points(direction, radius)
	var travel := (to_t - from_t) + OUTSIDE_MARGIN_MM * 2.0 + (datum - origin).length()
	var see_solid := not expected.is_empty()
	for index in range(rays.size()):
		var offset: Vector3 = rays[index]
		var start: Vector3 = origin + offset
		var finish: Vector3 = start + direction * travel
		for hit in _crossings(gauge, state, solid_state, checks, start, finish,
				mask, reference_scope, see_solid):
			var crossing: Dictionary = hit
			var t: float = (crossing["point"] as Vector3 - datum).dot(direction)
			if t < from_t or t > to_t:
				continue
			if bool(crossing.get("solid", false)) \
					and _is_the_screw_arriving(crossing["point"], t, expected):
				continue
			if obstructions.size() < MAX_OBSTRUCTIONS:
				obstructions.append({
					"node": str(crossing.get("node", "")),
					"reference": str(crossing.get("reference", "")),
					"point_mm": _frames(crossing["point"], str(crossing.get("reference", ""))),
					"axial_mm": t,
					# Which ring of the disc saw it, and how wide the disc was.
					# An obstruction reported at a ray radius between the two
					# is one no rim-only fan could have found.
					"ray_radius_mm": offset.length(),
					"fan_radius_mm": radius,
				})
			break
	return {
		"clear": obstructions.is_empty(),
		"obstructions": obstructions,
		"rays": rays.size(),
	}


## The offsets of one fan: the axis, then concentric rings out to `radius`.
## Ring radii are spaced by at most RING_SPACING_MM, and each ring carries
## enough rays that adjacent ones on it are no further apart than that either,
## so the whole disc is covered to one stated pitch.
func _disc_points(direction: Vector3, radius: float) -> Array:
	var points: Array = [Vector3.ZERO]
	if radius <= 0.0:
		return points
	var rings := maxi(1, int(ceil(radius / RING_SPACING_MM)))
	for ring in range(1, rings + 1):
		var r := radius * float(ring) / float(rings)
		points.append_array(_ring_offsets(direction, r))
	return points


## Is this hit on the solid the screw arriving at its own boss rather than
## something in its way? See _fan_clear's note for the two cases and why they
## are the only two.
func _is_the_screw_arriving(point: Vector3, t: float, expected: Dictionary) -> bool:
	if expected.is_empty():
		return true
	if t >= float(expected["from_t"]) - float(expected["band"]):
		# The boss's own end face, or anything at or past the mouth.
		return true
	var axis: Vector3 = expected["axis"]
	var offset: Vector3 = point - (expected["point"] as Vector3)
	var radial := (offset - axis * offset.dot(axis)).length()
	if radial > float(expected["radius"]) + BORE_WALL_TOLERANCE_MM:
		return false
	return t >= float(expected["from_t"]) and t <= float(expected["to_t"])


## A reply about a document that moved under it. `checked` false with a reason
## is not a clean bill of health, and this one is not an error either: the
## caller asks again, against whatever the document is now.
func _stale(reason: String) -> Dictionary:
	var report := _nothing(reason)
	report["stale"] = true
	return report


## A screw that cannot be measured at all, reported as a row rather than left
## out. A missing row reads as "there was no screw there"; this reads as "the
## hole record was not good enough to measure from", which is what happened.
func _unmeasurable(hole: Dictionary, bore: Dictionary, reason: String) -> Dictionary:
	return {
		"reference": str(hole.get("reference", "")),
		"node": str(hole.get("node", "")),
		"axis_source": str(bore.get("source", "b_rep")),
		"measured": false,
		"pass": false,
		"error": reason,
		"why": reason,
	}


## How much of the seat ring actually lands on material at the seat plane, as
## {landed, rays}. A head hanging half over the edge of its boss is "clear" —
## nothing is in its way — and still badly seated, and only this number says so.
##
## The ring is sampled between the shank radius and the head radius so a ray
## does not simply fall down the clearance hole and report an unsupported head
## on a perfectly good joint. It reports its OWN ray count rather than leaving
## the caller to divide by some other fan's: the axis point is dropped here (it
## goes straight down the clearance hole and can never land), so a ring whose
## every ray lands reads as exactly 1.0 and not as some fraction of a ring it
## was never part of.
func _seat_support(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	origin: Vector3,
	direction: Vector3,
	head_radius: float,
	shank_radius: float,
	seat_t: float,
	datum: Vector3,
	mask: int,
	reference_scope: String
) -> Dictionary:
	var radius := (head_radius + shank_radius) * 0.5
	var ring := _ring_points(direction, radius)
	# The window a hit may be off the seat plane by is the fan's own spacing:
	# anything further is a different surface, not this seat measured coarsely.
	var landed := 0
	var rays := 0
	# From 1: rays[0] is the axis, which travels down the clearance hole.
	for index in range(1, ring.size()):
		rays += 1
		var start: Vector3 = origin + (ring[index] as Vector3)
		var finish: Vector3 = start + direction * ((datum - origin).length() * 2.0 + head_radius)
		var hit := _reference_ray(gauge, state, start, finish, mask, reference_scope)
		if hit.is_empty():
			continue
		var t: float = (hit["position"] as Vector3 - datum).dot(direction)
		if absf(t - seat_t) <= RING_SPACING_MM:
			landed += 1
	return {"landed": landed, "rays": rays, "radius_mm": radius}


## The offsets of ONE ring: the axis point, then `radius` all the way round
## with enough rays that adjacent ones are no more than RING_SPACING_MM apart.
## The seat measurement is a circumference coverage and wants exactly this.
func _ring_points(direction: Vector3, radius: float) -> Array:
	var points: Array = [Vector3.ZERO]
	if radius <= 0.0:
		return points
	points.append_array(_ring_offsets(direction, radius))
	return points


## One ring's offsets, without the axis point. Records the arc the ring
## actually left between adjacent rays: past MAX_RING_RAYS rays the ring is
## coarser than RING_SPACING_MM, and a reply quoting the nominal spacing there
## would state a miss bound the fan does not keep.
func _ring_offsets(direction: Vector3, radius: float) -> Array:
	var points: Array = []
	if radius <= 0.0:
		return points
	var count := int(ceil(TAU * radius / RING_SPACING_MM))
	count = clampi(count, MIN_RING_RAYS, MAX_RING_RAYS)
	_widest_arc_mm = maxf(_widest_arc_mm, TAU * radius / float(count))
	var u := direction.cross(Vector3.UP)
	if u.length_squared() < 0.001:
		u = direction.cross(Vector3.RIGHT)
	u = u.normalized()
	var v := direction.cross(u).normalized()
	for i in range(count):
		var angle := TAU * float(i) / float(count)
		points.append((u * cos(angle) + v * sin(angle)) * radius)
	return points


## Every surface the segment start→finish crosses, in order. `include_solid`
## decides whether the evaluated solid's own collider is one of the bodies
## looked at; the references always are. The walk re-casts from just past each
## hit, so a ray passing through a board and on into a boss reports the board's
## two faces and then the boss's.
func _crossings(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	solid_state: PhysicsDirectSpaceState3D,
	checks: Object,
	start: Vector3,
	finish: Vector3,
	mask: int,
	reference_scope: String,
	include_solid: bool = true
) -> Array:
	var out: Array = []
	var direction := (finish - start).normalized()
	var cursor := start
	for _step in range(MAX_CROSSINGS_PER_RAY):
		if (finish - cursor).dot(direction) <= 0.0:
			break
		var reference_hit := _reference_ray(gauge, state, cursor, finish, mask, reference_scope)
		var solid_hit: Dictionary = {}
		if include_solid:
			solid_hit = checks.call("solid_ray", solid_state, cursor, finish)
			_casts += 1
		var next := finish
		var chosen := {}
		if not reference_hit.is_empty():
			next = reference_hit["position"]
			chosen = {
				"point": next,
				"node": str(reference_hit.get("node", "")),
				"reference": str(reference_hit.get("reference", "")),
			}
		if not solid_hit.is_empty():
			var point: Vector3 = solid_hit["position"]
			if chosen.is_empty() or cursor.distance_to(point) < cursor.distance_to(next):
				next = point
				chosen = {"point": point, "node": "<solid>", "reference": "",
					"solid": true}
		if chosen.is_empty():
			break
		out.append(chosen)
		cursor = next + direction * CROSSING_ADVANCE_MM
	return out


func _reference_ray(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3,
	mask: int,
	reference_scope: String
) -> Dictionary:
	_casts += 1
	var hit: Dictionary = gauge.call("run_now", state, "raycast", {
		"from": from,
		"to": to,
		"mask": mask,
		"reference": reference_scope,
	})
	if not bool(hit.get("hit", false)):
		return {}
	return hit


# ---------------------------------------------------------------------------
# Where the solid's bores come from
# ---------------------------------------------------------------------------

## The solid's cylindrical features, from the B-Rep, through the worker.
## Returns {cylinders: [...], partial: [...]} or {cylinders: [], reason: "..."}
## — a worker that cannot answer is a reason to fall back to the fitter, not an
## error.
##
## ONLY A CLOSED CYLINDER IS A BORE. A cylindrical surface that does not sweep
## a full turn is a groove, a fillet or the end of a slot: a screw put down its
## axis is held on one side and open on the other. The worker reports the sweep
## and whether it closed, and both are checked HERE rather than trusted from
## the request's closed_only flag, because a partial surface that reaches the
## pairing is graded exactly like a drilled hole. They are listed as partial so
## the reply can name them instead of dropping them.
func _solid_cylinders(panel: Object, source: String, screw: Dictionary) -> Dictionary:
	if source.strip_edges().is_empty():
		return {"cylinders": [], "reason": "the document is empty"}
	if not panel.has_method("call_backend"):
		return {"cylinders": [], "reason": "this panel has no backend channel"}
	var envelope: Dictionary = await panel.call_backend(FEATURES_CHANNEL, {
		"source": source,
		"sense": "concave",
		# Ask for the partial surfaces TOO. The reply promises to name every
		# cylindrical surface that is not a bore, and a worker-side filter
		# would drop them before this module ever saw them — the reply would
		# then quietly omit the groove a reader is looking for.
		"closed_only": false,
		# A bore far smaller than the screw is a vent or a texture, and one far
		# larger is a pocket. Both are noise in a fastener question.
		"min_dia_mm": float(screw["dia_mm"]) * 0.4,
		"max_dia_mm": float(screw["dia_mm"]) * 3.0,
	}, FEATURES_TIMEOUT_MS)
	var result: Dictionary = _WorkerReply.unwrap(envelope, "the solid's B-Rep features")
	if result.has("error"):
		return {"cylinders": [], "reason": str(result["error"])}
	var out: Array = []
	var partial: Array = []
	for entry in result.get("cylinders", []):
		var cylinder: Dictionary = entry
		var axis: Dictionary = cylinder.get("axis", {}) as Dictionary
		var origin := _vector(axis.get("origin_mm", []))
		var direction := _vector(axis.get("direction", [])).normalized()
		if direction.length_squared() < 0.5:
			continue
		# ONE RULE, and it is the worker's: a surface is closed when its
		# measured sweep covers the WHOLE turn. The worker states the
		# threshold it applied on every row, so this check applies that number
		# rather than a constant of its own — a threshold invented here would
		# disagree with the flag beside it the moment either side changed. A
		# row carrying no threshold leaves the verdict to the worker's flag.
		var sweep := float(cylinder.get("sweep_deg", 0.0))
		var threshold := float(cylinder.get("closed_min_sweep_deg", 0.0))
		var closed := bool(cylinder.get("closed", false))
		if threshold > 0.0:
			closed = sweep >= threshold
		if not closed:
			partial.append({
				"dia_mm": float(cylinder.get("dia_mm", 0.0)),
				"centre_mm": _frames(_vector(cylinder.get("centre_mm", [])), ""),
				"source": "b_rep",
				"sweep_deg": sweep,
				"reason": "partial cylinder (sweep %.1f degrees): a screw down "
					% sweep + "its axis is open on one side, so it is not a "
					+ "bore and is never paired with a hole",
			})
			continue
		# TWO extents, and they are different questions. The WALL runs the
		# whole length of the surface — that is where the bore's material is,
		# and a hit inside it is the screw arriving rather than an
		# obstruction. The ENGAGED span is the part of it that goes all the way
		# round: a bore whose mouth is cut by a tilted face has thread on one
		# side and air on the other above the low point of that trim, and a
		# screw only engages where the whole circumference is there.
		var wall_length := float(cylinder.get("extent_max_mm",
			cylinder.get("length_mm", 0.0)))
		var full_start := float(cylinder.get("full_start_mm", 0.0))
		var full_end := float(cylinder.get("full_end_mm", wall_length))
		out.append({
			"source": "b_rep",
			"dia_mm": float(cylinder.get("dia_mm", 0.0)),
			"axis": direction,
			"start": origin + direction * full_start,
			"end": origin + direction * full_end,
			"wall_start": origin,
			"wall_end": origin + direction * wall_length,
			"centre": _vector(cylinder.get("centre_mm", [])),
			"length_mm": full_end - full_start,
			"extent_max_mm": wall_length,
			# The full-turn extent is read in angular bins, so it carries the
			# bin's resolution as an error bar. Engagement is graded with it
			# subtracted: a screw must clear the threshold on the SHORTEST
			# bite the measurement allows, not on the nominal one.
			"extent_bound_mm": float(cylinder.get("extent_full_bound_mm", 0.0)),
			# TWO ways the extent can be a number nobody can grade against.
			# extent_exact false means the face's own boundary could not be
			# adapted and a parametric BOX was used, which can overstate the
			# length by any amount; extent_full_bounded false means an edge was
			# walked at a fixed pitch, so the error bar above is a floor and
			# not a bound. Either one makes engagement unknown rather than
			# measured, and unknown is not a pass.
			"extent_exact": bool(cylinder.get("extent_exact", true)),
			"extent_bounded": bool(cylinder.get("extent_full_bounded", true)),
		})
	return {"cylinders": out, "partial": partial}


## The named fallback: fit the solid's own tessellation. Uses the same fitter
## the reference meshes go through, so a bore the kernel cannot name is
## recovered exactly as a foreign one would be — with the same caveat, that the
## fitted radius is the CIRCUMSCRIBED circle through the facet corners and the
## screw only fits the inscribed one.
func _fit_solid_cylinders(mesh_data: Dictionary, screw: Dictionary) -> Dictionary:
	var soup := _soup_from(mesh_data)
	var positions: PackedVector3Array = soup["positions"]
	var indices: PackedInt32Array = soup["indices"]
	if positions.is_empty() or indices.size() < 3:
		return {"cylinders": [], "reason": "the solid has no mesh to fit"}
	var analysis: Dictionary = _MeshFeatures.analyze_soup(positions, indices, "<solid>")
	var out: Array = []
	for entry in _MeshFeatures.concave_cylinders(
		analysis.get("candidates", []),
		float(screw["dia_mm"]) * 0.4,
		float(screw["dia_mm"]) * 3.0
	):
		var candidate: Dictionary = entry
		var axis: Vector3 = candidate.get("axis", Vector3.UP)
		var centre: Vector3 = candidate.get("center", Vector3.ZERO)
		var half := float(candidate.get("half_extent_mm", 0.0))
		out.append({
			"source": "tessellation_fit",
			"dia_mm": float(candidate.get("dia_mm", 0.0)),
			"inscribed_dia_mm": float(candidate.get("inscribed_dia_mm", 0.0)),
			"axis": axis,
			"start": centre - axis * half,
			"end": centre + axis * half,
			"centre": centre,
			"length_mm": half * 2.0,
			"residual_mm": float(candidate.get("residual_mm", 0.0)),
			"facets": int(candidate.get("facets", 0)),
		})
	return {"cylinders": out}


## The worker's mesh as one soup, in world millimetres — the evaluated solid is
## never posed, so its own frame IS the world.
func _soup_from(mesh_data: Dictionary) -> Dictionary:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	var raw_vertices: Array = mesh_data.get("vertices", []) as Array
	var raw_faces: Array = mesh_data.get("faces", []) as Array
	for raw in raw_vertices:
		positions.append(_vector(raw))
	for entry in raw_faces:
		if not (entry is Array) or (entry as Array).size() < 3:
			continue
		var face: Array = entry
		for corner in range(3):
			var index := int(face[corner])
			if index < 0 or index >= positions.size():
				return {"positions": PackedVector3Array(), "indices": PackedInt32Array()}
			indices.append(index)
	return {"positions": positions, "indices": indices}


## How far a fitted axis is from the B-Rep axis for the SAME feature, and
## whether that is inside the gate the fallback is licensed by. Empty when no
## fit was computed or none of the fits is the same feature.
##
## The radius is reported and deliberately NOT graded: a tessellated bore's
## fitted radius is the circumscribed circle through the facet corners, which
## on a 24-gon M3 pilot sits a hundredth of a millimetre outside the true
## surface by construction. That is a known bias, not a fitting error, and the
## gate is about the AXIS — which is what every fastener number is built on.
func _agreement(bore: Dictionary, fitted: Array, direction: Vector3) -> Dictionary:
	var best := {}
	var best_distance := INF
	var bore_centre: Vector3 = bore["centre"]
	for entry in fitted:
		var candidate: Dictionary = entry
		var distance: float = (candidate["centre"] as Vector3).distance_to(bore_centre)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	if best.is_empty() or best_distance > PAIR_MAX_OFFSET_MM:
		return {}
	var fit_axis: Vector3 = best["axis"]
	var bore_axis: Vector3 = bore["axis"]
	if fit_axis.dot(bore_axis) < 0.0:
		fit_axis = -fit_axis
	var angle := rad_to_deg(fit_axis.angle_to(bore_axis))
	var offset := _radial_offset(
		bore_centre, direction, best["centre"] as Vector3, fit_axis, 0.0)
	return {
		"centre_offset_mm": offset,
		"axis_angle_deg": angle,
		"radius_delta_mm": (float(best["dia_mm"]) - float(bore["dia_mm"])) * 0.5,
		"within_gate": offset <= AGREEMENT_CENTRE_MM and angle <= AGREEMENT_ANGLE_DEG,
		"gate": "the fitted axis must sit within %s mm and %s degrees of the "
			% [AGREEMENT_CENTRE_MM, AGREEMENT_ANGLE_DEG]
			+ "B-Rep axis; radius_delta_mm is the tessellation's chordal bias "
			+ "and is reported, not graded",
	}


# ---------------------------------------------------------------------------
# Pairing
# ---------------------------------------------------------------------------

## Match the solid's bores to the reference holes, one to one.
##
## Greedy by distance: every admissible (bore, hole) combination is scored by
## how far the bore's axis passes from the hole's centre, the list is sorted,
## and pairs are taken in order, skipping any whose bore or hole is already
## spoken for. That is the one-to-one constraint: two bosses near one hole
## must not both claim it. Anything left over is reported by name under
## `unpaired` rather than quietly dropped.
func _pair(bores: Array, holes: Array, args: Dictionary) -> Dictionary:
	var prepared_holes: Array = []
	for entry in holes:
		var hole: Dictionary = entry
		var axis := _vector((hole.get("axis", {}) as Dictionary).get("world", []))
		var centre := _vector((hole.get("center_mm", {}) as Dictionary).get("world", []))
		if axis.length_squared() < 0.5:
			continue
		prepared_holes.append({
			"hole": hole, "axis": axis.normalized(), "centre": centre,
		})

	var explicit: Array = args.get("pairs", []) as Array
	var candidates: Array = []
	if explicit.is_empty():
		for b in range(bores.size()):
			for h in range(prepared_holes.size()):
				var scored := _score(bores[b] as Dictionary, prepared_holes[h] as Dictionary)
				if scored.is_empty():
					continue
				scored["bore_index"] = b
				scored["hole_index"] = h
				candidates.append(scored)
		candidates.sort_custom(func(a, b): return float(a["offset"]) < float(b["offset"]))
	else:
		for entry in explicit:
			var asked: Dictionary = entry
			var b := int(asked.get("solid_feature", -1))
			var h := int(asked.get("reference_hole", -1))
			if b < 0 or b >= bores.size() or h < 0 or h >= prepared_holes.size():
				continue
			var scored := _score(bores[b] as Dictionary, prepared_holes[h] as Dictionary, true)
			scored["bore_index"] = b
			scored["hole_index"] = h
			candidates.append(scored)

	var taken_bores := {}
	var taken_holes := {}
	var pairs: Array = []
	for entry in candidates:
		var candidate: Dictionary = entry
		var b: int = candidate["bore_index"]
		var h: int = candidate["hole_index"]
		if taken_bores.has(b) or taken_holes.has(h):
			continue
		taken_bores[b] = true
		taken_holes[h] = true
		var bore: Dictionary = bores[b]
		var prepared: Dictionary = prepared_holes[h]
		pairs.append({
			"bore": bore,
			"hole": prepared["hole"],
			"hole_axis": prepared["axis"],
			"hole_centre": prepared["centre"],
			"bore_axis": (bore["axis"] as Vector3).normalized(),
			"bore_start": bore["start"],
			"bore_end": bore["end"],
		})

	var loose_bores: Array = []
	for b in range(bores.size()):
		if taken_bores.has(b):
			continue
		var bore: Dictionary = bores[b]
		loose_bores.append({
			"index": b,
			"dia_mm": float(bore.get("dia_mm", 0.0)),
			"centre_mm": _frames(bore["centre"], ""),
			"source": str(bore.get("source", "b_rep")),
		})
	var loose_holes: Array = []
	for h in range(prepared_holes.size()):
		if taken_holes.has(h):
			continue
		var prepared: Dictionary = prepared_holes[h]
		var hole: Dictionary = prepared["hole"]
		loose_holes.append({
			"index": h,
			"reference": str(hole.get("reference", "")),
			"node": str(hole.get("node", "")),
			"dia_mm": float(hole.get("dia_mm", 0.0)),
		})
	return {
		"pairs": pairs,
		"unpaired": {
			"solid_features": loose_bores,
			"reference_holes": loose_holes,
			"rule": ("a bore is paired with the reference hole whose axis it "
				+ "passes closest to, one to one; anything more than %s mm "
				+ "off or %s degrees out is left unpaired rather than "
				+ "mispaired") % [PAIR_MAX_OFFSET_MM, PAIR_MAX_ANGLE_DEG],
		},
	}


## How well one bore lines up with one hole, or {} when it is not a candidate.
func _score(bore: Dictionary, prepared: Dictionary, forced: bool = false) -> Dictionary:
	var bore_axis: Vector3 = (bore["axis"] as Vector3).normalized()
	var hole_axis: Vector3 = prepared["axis"]
	var aligned := bore_axis if bore_axis.dot(hole_axis) >= 0.0 else -bore_axis
	var angle := rad_to_deg(aligned.angle_to(hole_axis))
	var offset := _radial_offset(
		prepared["centre"], hole_axis, bore["centre"], aligned, 0.0)
	if not forced and (angle > PAIR_MAX_ANGLE_DEG or offset > PAIR_MAX_OFFSET_MM):
		return {}
	return {"offset": offset, "angle": angle}


# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

func _report(
	rows: Array,
	pairing: Dictionary,
	screw: Dictionary,
	verb_args: Dictionary,
	axis_source: String
) -> Dictionary:
	var failed := 0
	for entry in rows:
		if not bool((entry as Dictionary).get("pass", false)):
			failed += 1
	return {
		"checked": true,
		"units": "mm",
		"count": rows.size(),
		"failed": failed,
		"pass": failed == 0 and not rows.is_empty(),
		"screw": screw,
		"engagement_min_d": float(verb_args.get(
			"engagement_min_d", DEFAULT_ENGAGEMENT_D)),
		"axis_source": axis_source,
		"tessellation_tolerance_mm": DISPLAY_TOLERANCE_MM,
		"ray_spacing_mm": RING_SPACING_MM,
		"ray_spacing": {
			"radial_mm": RING_SPACING_MM,
			# MEASURED, not nominal: the widest gap any ring of this check
			# actually left between two adjacent rays. It exceeds radial_mm
			# only on a ring wide enough to hit the ray ceiling.
			"angular_mm": _widest_arc_mm,
			"angular_bound_mm": RING_SPACING_MM,
			"angular_note": ("the widest arc between adjacent rays on a ring; "
				+ "a ring needing more than %d rays to hold the radial "
				+ "spacing is capped there and is reported coarser")
				% MAX_RING_RAYS,
		},
		"rays_total": _path_rays,
		"sampling": "the screw path is sampled over the whole DISC of the "
			+ "shank and of the head — concentric rings out from the axis, "
			+ "spaced by ray_spacing.radial_mm, each ring's rays no more than "
			+ "ray_spacing.angular_mm apart along it — and not swept: an "
			+ "obstruction narrower than that spacing can pass between two "
			+ "rays unseen, at any radius",
		"screws": rows,
		"unpaired": pairing.get("unpaired", {}),
		"casts": _casts,
		"elapsed_ms": float(Time.get_ticks_usec() - _started_us) / 1000.0,
	}


## One sentence saying why this screw failed, or "" when it did not. A row of
## eight numbers does not tell a reader which one to act on.
func _why(row: Dictionary) -> String:
	var zone: Dictionary = row.get("coaxiality", {}) as Dictionary
	if bool(zone.get("graded", false)) and not bool(zone.get("pass", false)):
		return "the bore axis is %.3f mm out of a %.3f mm coaxiality zone (%.2f degrees of tilt)" \
			% [float(zone.get("zone_dia_mm", 0.0)) * 0.5,
			   float(zone.get("allowed_zone_dia_mm", 0.0)),
			   float(row.get("axis_angle_deg", 0.0))]
	if not bool(row.get("path_clear", true)):
		var first: Array = row.get("obstructions", []) as Array
		if not first.is_empty():
			return "the screw path is blocked by %s" \
				% str((first[0] as Dictionary).get("node", "something"))
		return "the screw path is blocked"
	if not bool(row.get("engagement_ok", true)):
		if not bool(row.get("engagement_certain", true)):
			return ("the bore's extent is not exact, so the %.2f mm of bite "
				+ "measured here cannot be graded: the kernel could not read "
				+ "this face's own boundary, or could not sample it to a "
				+ "stated deflection") % float(row.get("engagement_mm", 0.0))
		var bound := float(row.get("engagement_bound_mm", 0.0))
		if bound > 0.0:
			return ("the screw engages %.2f mm of bore (+/- %.2f mm) and "
				+ "needs %.2f mm") % [float(row.get("engagement_mm", 0.0)),
					bound, float(row.get("engagement_required_mm", 0.0))]
		return "the screw engages %.2f mm of bore and needs %.2f mm" \
			% [float(row.get("engagement_mm", 0.0)),
			   float(row.get("engagement_required_mm", 0.0))]
	if not bool(row.get("head_seat_clear", true)):
		return "the head cannot reach its seat"
	return ""


## One line for the panel's status banner, or "" when there is nothing to say.
## It names the FIRST failing screw rather than summarising: a joint is fixed
## one screw at a time.
func status_line(report: Dictionary) -> String:
	if not bool(report.get("checked", false)):
		return ""
	for entry in report.get("screws", []):
		var row: Dictionary = entry
		if bool(row.get("pass", false)):
			continue
		return "Fastener %s: %s" % [str(row.get("node", "")), str(row.get("why", "fails"))]
	if int(report.get("count", 0)) > 0:
		return "%d fastener(s) clear" % int(report["count"])
	return ""


## A report for a question that could not be asked. `checked` false with a
## reason is not the same answer as "every screw passes".
func _nothing(reason: String) -> Dictionary:
	return {
		"checked": false,
		"units": "mm",
		"reason": reason,
		"count": 0,
		"pass": false,
		"screws": [],
	}



# ---------------------------------------------------------------------------
# Small shared things
# ---------------------------------------------------------------------------

## The screw the caller asked about, or {error}. A fastener check with no
## screw in it has nothing to be right about.
func _screw_from(args: Dictionary) -> Dictionary:
	var raw: Dictionary = args.get("screw", {}) as Dictionary
	var dia := float(raw.get("dia_mm", 0.0))
	var length := float(raw.get("length_mm", 0.0))
	if dia <= 0.0 or length <= 0.0:
		return {"error": "check_fasteners needs screw: {dia_mm, length_mm} — "
			+ "the thread diameter and the length under the head, both in "
			+ "millimetres"}
	# A pan head is about twice the thread diameter across; it is a default so
	# the head questions can be asked at all, and the reply says it was used.
	var head := float(raw.get("head_dia_mm", 0.0))
	var assumed := head <= 0.0
	if assumed:
		head = dia * 2.0
	return {
		"dia_mm": dia,
		"length_mm": length,
		"head_dia_mm": head,
		"head_dia_assumed": assumed,
	}


## A world point in both frames. `reference_name` names the frame the local
## coordinates belong to; an empty name (the evaluated solid's own points) has
## no reference frame to be in and says so.
func _frames(world: Vector3, reference_name: String) -> Dictionary:
	if reference_name.is_empty():
		return {"world": _vec(world), "local": null,
			"local_unavailable": "the evaluated solid is never posed, so its "
				+ "own frame IS the world"}
	var pose := _pose_in(reference_name)
	return {"world": _vec(world), "local": _vec(pose.affine_inverse() * world)}


## A world direction in both frames. A direction is rotated by the pose, never
## translated, and normalised again because a scaled pose does not preserve
## unit length.
func _axes(world: Vector3, reference_name: String) -> Dictionary:
	if reference_name.is_empty():
		return {"world": _vec(world), "local": null}
	var pose := _pose_in(reference_name)
	var local: Vector3 = pose.basis.inverse() * world
	if local.length_squared() > 0.0:
		local = local.normalized()
	return {"world": _vec(world), "local": _vec(local)}


func _pose_in(reference_name: String) -> Transform3D:
	for entry in _records:
		var record: Dictionary = entry
		if str(record.get("name", "")) == reference_name:
			return record.get("pose", Transform3D.IDENTITY)
	return Transform3D.IDENTITY


## The longest ray worth casting: everything mounted, plus the solid.
func _scene_reach(checks: Object) -> float:
	var box: AABB = checks.call("get_solid_bounds")
	for entry in _records:
		var record: Dictionary = entry
		var world: AABB = record.get("world_aabb", AABB())
		if world.size.length_squared() > 0.0:
			box = box.merge(world)
	return box.size.length() + 10.0


func _vector(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		var values: Array = raw
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.ZERO


func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]
