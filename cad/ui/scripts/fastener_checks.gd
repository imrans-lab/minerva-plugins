extends "fastener_probe.gd"
## fastener_checks.gd — will this screw actually go in?
##
## An enclosure is bolted to a board. Everything about that joint is a number
## somebody has to be right about: the boss has to line up with the hole, the
## screw has to REACH the boss without meeting a capacitor on the way, it has
## to bite deep enough to hold, and the head has to land on something flat. An
## LLM iterating on the DSL can see none of that, and a picture of it says
## nothing — so this check answers each of them — and whether the screw bottoms
## out first — with millimetres, per screw.
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
## the boss's own measured tilt — are filtered out by name. The same shank
## rays then carry on down the bore to where the screw's TIP reaches, where
## the only solid they may meet is the bore's wall at its own radius with a
## radial normal: a web, an inward rib or a shelf ending at the wall below the
## mouth is an obstruction there, and solid across the bore at or past its
## extent end is the FLOOR of a blind bore the screw would bottom out on. The
## HEAD fan sees the solid as well as the references, and the one solid hit it
## lets through is the face in the seat plane.
##
## ENGAGEMENT — the overlap of the screw's length, measured from the seat, with
## the bore's axial extent. Graded against a material default: thread-forming
## screws in a thermoplastic boss want 2.0 x d, which is `engagement_min_d`'s
## default; metal-to-metal is 1.0 to 1.5 and the caller states it.
##
## BOTTOMING — a blind bore shallower than the screw is long: the tip meets the
## floor before the head meets its seat, and engagement can read as ample
## while the joint never closes. Graded from the same rays as the path: the
## floor the fan met, the tip's position, and the difference.
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
## WHAT THIS FILE HOLDS. The check itself: the reservation and the run, the
## per-screw sequence that asks the four questions in the order their numbers
## become available, and the report. The measuring underneath it — the ray
## fans, the coaxiality zone, where the solid's bores come from and which bore
## belongs to which hole — is in fastener_probe.gd, and the seat ring and the
## fit table are in fastener_seat.gd under that. This script is the last link
## of that chain, so one object still carries the whole check.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: ui/cad_panel_scene.gd (the panel's own instance),
## ui/panel_tools.gd (minerva_cad_check_fasteners) and
## scripts/fastener_screws.gd (one graded run per screw size).

## Tessellation deviation quoted with every fitted number. The fallback fit
## works on the DISPLAY mesh, whose deviation is the evaluation's own, so this
## is reported as the tolerance in force rather than requested.
const DISPLAY_TOLERANCE_MM: float = 0.1


## Thread-forming screws in a thermoplastic boss want two diameters of
## engagement (Plastite and the moulding boss-design guides put the usable band
## at 1.7-2.2 d); metal-to-metal wants 1.0-1.5 and the caller says so.
const DEFAULT_ENGAGEMENT_D: float = 2.0


## How far short of its end plane a path span stops. A shank ring ray at the
## thread radius meets the boss's own face AT the mouth of the bore, and a head
## ring ray meets the board AT the seat: both are the screw ARRIVING, and a
## span that included its own end plane would report every good joint as
## blocked. Small enough that anything actually in the way is still caught.
const PATH_END_EPSILON_MM: float = 0.01


## Every collision layer at once — the unscoped mask, matching mesh_gauge.
const ALL_LAYERS: int = 0xFFFFFFFF

## The source digest a part-scoped collider is cached under. Shared with the
## interference chain so both name the same body for the same binding.
const _PartCache: Script = preload("part_cache.gd")


## Rays the running check's path fans placed, summed over every screw. Reported
## beside the spacing so a reader can see how densely the disc was covered.
var _path_rays: int = 0
## Wall clock of the running check, microseconds.
var _started_us: int = 0


## The key build_solid caches this call's collider under: the digest of the
## source that evaluates to the named part, and "" — always rebuild — for the
## document's own render target, which has no stamp.
static func _solid_cache_key(source: String) -> String:
	if source.strip_edges().is_empty():
		return ""
	return _PartCache.digest(source)


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
##   screw            {dia_mm, length_mm, head_dia_mm?, seat?, seat_offset_mm?}
##                    — dia and length are mandatory; a check with no screw in
##                    it is not a check. `seat` says WHICH BODY the head lands
##                    on: "reference" (default), "solid", or "offset" with
##                    seat_offset_mm; see SEAT_ON_REFERENCE.
##   mesh             the tessellation to build the solid's collider from, when
##                    the check is scoped to one named part. The document's own
##                    render target otherwise.
##   source           the DSL that evaluates to that same part, for the B-Rep
##                    bores. Must be the part `mesh` came from.
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
		document = preload("evaluation_state.gd").document(panel, args)
	# A part-scoped check brings the tessellation AND the source of ITS part;
	# with neither, both come from the document's own render target.
	var mesh_data: Dictionary = args.get("mesh", {}) as Dictionary
	if (mesh_data.get("faces", []) as Array).is_empty():
		mesh_data = document.get("mesh", {}) as Dictionary
	var solid_source := str(args.get("source", ""))
	if solid_source.strip_edges().is_empty():
		solid_source = str(document.get("source", ""))

	# The references AS THEY ARE NOW, before anything is awaited. Every local
	# coordinate in the reply is a world point taken back through one of these
	# poses, and the panel's own state can be re-posed — or replaced by
	# another call's evaluation — while this one waits for the worker. A check
	# that read the poses afterwards would report this screw's geometry in
	# another document's frame.
	#
	# A COPY, not the panel's array: a re-pose writes the record's pose in
	# place, and a snapshot that held the live record would compare the moved
	# pose with itself and find nothing changed. The deep duplicate copies the
	# dictionaries and their poses and shares the meshes, which never change
	# under a record.
	var records: Array = (panel.get_reference_state() as Array).duplicate(true) \
		if panel.has_method("get_reference_state") else []
	# The COLLIDERS those poses describe, by the generation mesh_gauge counts
	# its rebuilds with. The snapshot above fixes the frame every local
	# coordinate is converted through; this fixes the geometry the rays are
	# cast against. Casting against one epoch and converting through the other
	# is a reply whose world numbers are all right and whose local ones are
	# all wrong — the worst shape a wrong answer can take.
	var epoch := int(gauge.call("get_generation"))
	# And the two have to describe ONE state before anything is awaited. The
	# guards below catch the references moving after this point; they cannot
	# tell that the records were already ahead of the colliders when the
	# check began — a pose rewritten, no rebuild yet, none coming during the
	# wait — and a snapshot taken then holds the new pose beside the old
	# geometry with nothing left to change. So the colliders are asked what
	# they were built from and compared with what these records describe,
	# through the gauge's own derivation. A mismatch is stale: the holes in
	# `args` were measured against whichever of the two was current at the
	# time, and this module cannot measure them again.
	if str(gauge.call("get_bodies_digest")) \
			!= _MeshGauge.bodies_digest(_MeshGauge.bodies_from_records(records)):
		return _stale("the reference colliders are behind the reference poses "
			+ "(colliders behind poses): a re-pose has not been rebuilt into "
			+ "the measurement gauge yet, so rays would meet the old geometry "
			+ "and be reported in the new frame; run minerva_cad_find_holes "
			+ "again and re-ask")

	# The B-Rep first, and OUTSIDE the reservation: it is an IPC round trip to
	# the worker, and holding the solid's collider across it would stall every
	# evaluation for its duration.
	var features := await _solid_cylinders(panel, solid_source, screw, args)
	if features.has("error"):
		return _nothing(str(features["error"]))

	# The references were rebuilt while this check waited for the worker, so
	# the geometry the rays would meet is no longer the geometry the question
	# was asked about. GOING AGAIN IS NOT AN OPTION HERE: the reference HOLES
	# arrived in `args`, measured by minerva_cad_find_holes at the world
	# positions of the old pose, and this module never segments a reference
	# itself. Adopting the new colliders while pairing and seating against
	# those old holes is the mixed epoch in its worst form — every number
	# self-consistent, every one about a document that no longer exists. The
	# caller re-runs find_holes and asks again.
	if int(gauge.call("get_generation")) != epoch \
			or not _same_poses(records, panel):
		return _stale("the references moved while this check waited for the "
			+ "worker — re-posed, re-evaluated, or both — so the holes it was "
			+ "given no longer describe where they are; run "
			+ "minerva_cad_find_holes again and re-ask")

	# Not an evaluation: this check only ever runs because an agent asked for
	# it, so it takes a place in the bounded verb line rather than the one
	# evaluation slot. It waits there for a check that is nearly done and is
	# refused — with what it waited — when the line is full or the wait runs
	# out, because a wait nobody bounds is a hang the caller's client times
	# out inside.
	var reservation: Dictionary = await checks.call("reserve", false)
	var ticket := int(reservation.get("ticket", 0))
	if ticket == 0:
		# The interference module owns the solid's collider and hands out one
		# reservation at a time; a refusal is its answer, not this module's.
		return checks.call("refused", reservation)
	var queued_ms := int(reservation.get("waited_ms", 0))

	var report := await _run(gauge, checks, mesh_data, features, holes,
		screw, args, ticket, records)
	if queued_ms > 0:
		report["queued_ms"] = queued_ms
	# The colliders the rays were cast against are the ones the poses above
	# describe, or the answer is two epochs stitched together.
	if int(gauge.call("get_generation")) != epoch \
			or not _same_poses(records, panel):
		checks.call("release_reservation", ticket)
		return _stale("the references moved while this check was measuring, "
			+ "so its rays and its poses would not describe one state of the "
			+ "document")
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
	# A part-scoped check names the shape it is about — the digest of the
	# source that evaluates to that binding — so the collider the interference
	# leg already welded for it is swapped back in rather than rebuilt. The
	# document's own render target names nothing and rebuilds.
	var triangles := int(checks.call("build_solid", mesh_data, ticket,
		_solid_cache_key(str(args.get("source", "")))))
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

	var pairing := _pair(bores, holes, screw, args)
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
		empty["reference_hole_index"] = pairing["reference_hole_index"]
		empty["note"] = "no solid bore lines up with any of the reference " \
			+ "holes given; every feature is listed under `unpaired`"
		return empty

	# The rays run inside mesh_gauge's physics step: the references' space is
	# only legal to dereference there, and the solid's own space has the same
	# rule. Both are queried in ONE step, so a screw's path is measured against
	# one state of the world rather than two.
	# The synchronous phase — the fit, the pairing — ends here; past this
	# point mesh_gauge times the job out itself, so the reclaim clock is
	# restarted rather than charged for both.
	checks.call("refresh_reservation", ticket)
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
	answer["reference_hole_index"] = pairing["reference_hole_index"]
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

	# +axis is the direction the screw travels: from the hole toward the MIDDLE
	# of the bore. The bore's near END is not the same test — a pilot in a post
	# that starts level with the board's own top face, or a bore that straddles
	# the hole, puts that end on either side of the hole centre and flips the
	# screw round — and a screw run backwards fails every span it measures.
	var direction := hole_axis
	if direction.dot((bore_start + bore_end) * 0.5 - hole_centre) < 0.0:
		direction = -direction

	var dia := float(screw["dia_mm"])
	var length := float(screw["length_mm"])
	var head_dia := float(screw["head_dia_mm"])
	var seat_on := str(screw.get("seat", SEAT_ON_REFERENCE))

	# Axial coordinates are distances along `direction` from the hole centre.
	# One frame for the whole screw, so seat, bore and screw length are
	# comparable numbers rather than three sets of points. EVERYTHING about
	# depth hangs off the seat: engagement, bottoming, where the head's span
	# ends. Getting it from the wrong body is the difference between a joint
	# that is fine and four screws that read "bottoming by 5.4 mm".
	var seat_t := 0.0
	if seat_on == SEAT_AT_OFFSET:
		seat_t = float(screw.get("seat_offset_mm", 0.0))
	elif seat_on == SEAT_ON_SOLID:
		# The first face of the SOLID the head's bearing ring meets on its way
		# in. Only the solid: a board or a component in the head's way is an
		# obstruction, and a seat read off "whatever is nearest" could not tell
		# the two apart.
		var found: Variant = _solid_seat(solid_state, checks, hole_centre,
			direction, head_dia * 0.5, dia * 0.5, reach)
		if found == null:
			return _unmeasurable(hole, bore,
				"screw.seat is 'solid' and the head's ring meets no face of "
				+ "the evaluated solid anywhere along its axis, so there is "
				+ "nothing for the head to sit on; check the screw is coming "
				+ "in from the side the counterbore or the skin is on")
		seat_t = float(found) - _head_drop(screw, head_dia * 0.5, (head_dia + dia) * 0.25)
	else:
		# The plate's head-side face: half its thickness short of the hole's
		# centre. A hole record with no thickness in it has NO seat — and
		# defaulting to zero would put the seat at the centre of the plate and
		# shift every axial number by half of it, silently. Refuse instead.
		var thickness := float(hole.get("depth_mm", 0.0))
		if thickness <= 0.0:
			thickness = float(hole.get("extent_mm", 0.0))
		if thickness <= 0.0:
			return _unmeasurable(hole, bore,
				"the hole record carries neither depth_mm nor extent_mm, so "
				+ "there is no seat plane to measure the screw from; "
				+ "minerva_cad_find_holes reports depth_mm on a verified hole")
		seat_t = -thickness * 0.5 - _head_drop(screw, head_dia * 0.5, float(hole.get("dia_mm", dia)) * 0.5)
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

	# Where the screw's tip ends up with the head on its seat. Everything about
	# depth — engagement, and whether a blind bore's floor is reached before
	# the head is — is a comparison against this one number.
	var tip_t := seat_t + length
	# ISO 1101: the zone is measured over the length the screw is actually in
	# the bore for, not over the whole feature.
	var engaged_from := maxf(bore_entry_t, seat_t)
	var engaged_to := minf(bore_exit_t, tip_t)
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
	# And past the mouth, the ENGAGED BORE. The same rays carry on down the
	# bore for the length the screw occupies, where the only solid they may
	# meet is the bore's own wall: a web left across the bore, an inward rib,
	# a floor the modeller put above the stated depth are all in the screw's
	# way just as surely as a lid over the hole, and a fan that stopped at the
	# mouth called every one of them clear. The span starts past the mouth
	# band (the boss's end face is the screw arriving) and runs to where the
	# TIP reaches: a blind bore's floor met inside that span means the screw
	# is longer than the bore is deep and cannot seat — the fan reports that
	# floor and the row grades it as bottoming, a different finding from an
	# obstruction with the same consequence.
	var expected := {
		"point": bore_start,
		"axis": bore_axis,
		"radius": float(bore.get("dia_mm", 0.0)) * 0.5,
		"from_t": wall_entry_t,
		"to_t": wall_exit_t,
		"band": mouth_band,
		# From the FULL-TURN mouth: between the wall's furthest reach and
		# the mouth at every azimuth the thread is on one side only, and the
		# boss's trimmed end face is the screw arriving there too.
		"bore_from_t": bore_entry_t + mouth_band,
		"bore_to_t": tip_t - PATH_END_EPSILON_MM,
		# Solid across the bore at or past the extent end is the bore's floor.
		"bore_exit_t": bore_exit_t,
		"datum": hole_centre,
		"direction": direction,
	}
	# Where the SHANK's approach begins. Outside everything, except when the
	# head sits on the solid: there the seat plane is a face of the solid the
	# shank's own disc passes through, and a span that started above it counts
	# that face — the head's own bearing surface — as an obstruction. The head
	# fan already covers everything above the seat, at a radius that reaches
	# past the shank's whenever the screw has a head at all, so the shank
	# starts AT the seat plane, to the same tolerance the seat ring lands with.
	var shank_from_t := start_t
	if seat_on == SEAT_ON_SOLID and head_dia >= dia:
		shank_from_t = seat_t + SEAT_TOLERANCE_MM
	var shank := _fan_clear(
		gauge, state, solid_state, checks, origin, direction,
		dia * 0.5, shank_from_t, wall_entry_t - PATH_END_EPSILON_MM,
		hole_centre, mask, reference_scope, expected
	)
	var head := {"clear": true, "obstructions": [], "rays": 0}
	var seat := {"landed": 0, "rays": 0}
	if head_dia > 0.0:
		# The head sees the solid too, or a shell feature standing over the
		# seat — an annular bridge outside the shank and inside the head —
		# is invisible to the only fan wide enough to meet it. The solid face
		# the seat plane lies in is the one hit that is the screw arriving.
		# The conical approach and bearing check use the same axial tolerance
		# around the stated profile, so an accepted seat is not its own blocker.
		var head_tolerance := SEAT_TOLERANCE_MM if screw.get("head_kind", "flat") == "countersunk" else PATH_END_EPSILON_MM
		head = _fan_clear(
			gauge, state, solid_state, checks, origin, direction,
			head_dia * 0.5, start_t, seat_t - head_tolerance,
			hole_centre, mask, reference_scope, {"seat_t": seat_t, "head_profile": screw}
		)
		seat = _seat_support(
			gauge, state, solid_state, checks, origin, direction,
			head_dia * 0.5, dia * 0.5, seat_t, hole_centre, mask,
			reference_scope, seat_on == SEAT_ON_SOLID, screw
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
	# A CLEARANCE BORE IS NOT AN ENGAGEMENT. The screw passes through it; there
	# is no material for the thread to hold. Overlap with one is still measured
	# and reported — it is the span the screw is inside that body for — but it
	# never counts as bite, or a `pairs` override onto the tray's own clearance
	# hole would read as a joint with 7.5 mm of grip in a hole with no thread.
	var bore_fit := str(pair.get("fit", "thread"))
	var engagement_ok := extent_certain and bore_fit == "thread" \
		and engagement - engagement_bound >= engagement_required
	var head_seat_clear := bool(head["clear"])
	var head_support_ok := head_dia <= 0.0 or int(seat["landed"]) > 0
	if screw.get("head_kind", "flat") == "countersunk":
		head_support_ok = int(seat["rays"]) > 0 and seat["landed"] == seat["rays"]
	# BOTTOMING. The fan's bore span runs to the tip, so a floor it met is a
	# floor the tip would reach: the screw runs out of bore before the head
	# reaches its seat. Reported with the numbers — where the tip ends, where
	# the floor is, by how much — because the fix is a shorter screw or a
	# deeper bore and the reader has to know which millimetre to change.
	var bottoming := shank["floor_t"] != null
	var row := {
		"reference": str(hole.get("reference", "")),
		"node": str(hole.get("node", "")),
		"axis_source": str(bore.get("source", "b_rep")),
		"tessellation_tolerance_mm": DISPLAY_TOLERANCE_MM,
		"hole_dia_mm": float(hole.get("dia_mm", 0.0)),
		"hole_gauge_dia_mm": float(hole.get("gauge_dia_mm", 0.0)),
		"bore_dia_mm": float(bore.get("dia_mm", 0.0)),
		# What the paired bore is FOR: only a thread bore can be an
		# engagement, and a reader looking at 7 mm of overlap has to be able
		# to see which kind of hole those millimetres are in.
		"bore_fit": bore_fit,
		"screw_axis": _axes(direction, str(hole.get("reference", ""))),
		"seat_mm": _frames(hole_centre + direction * seat_t, str(hole.get("reference", ""))),
		# Which body the seat plane was read off, and how far along the
		# screw's travel from the hole's centre it landed. Every axial number
		# in this row is measured from it.
		"seat_on": seat_on,
		"seat_offset_mm": seat_t,
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
		"head_support_ok": head_support_ok,
		"head_support_included_in_verdict": true,
		"seat_kind": screw.get("head_kind", "flat"),
		"screw_tip_mm": tip_t,
		"bore_floor_mm": shank["floor_t"],
		"bottoming": bottoming,
		# The span the screw can engage over (full circumference) and the span
		# the bore's wall occupies. They differ by whatever a tilted trim cut
		# off one side of the mouth.
		"bore_extent_mm": {"entry": bore_entry_t, "exit": bore_exit_t},
		"bore_wall_extent_mm": {"entry": wall_entry_t, "exit": wall_exit_t},
	}
	if not bool(shank["clear"]):
		row["obstructions"] = shank["obstructions"]
	if bottoming:
		row["bottoming_by_mm"] = tip_t - float(shank["floor_t"])
	if head_dia > 0.0:
		# The fraction of the SEAT RING that landed, over that ring's own ray
		# count. The head fan is a different ring at a different radius, and
		# dividing by it could never reach 1.0 on a perfectly seated screw.
		row["head_seat_supported"] = float(seat["landed"]) \
			/ maxf(1.0, float(seat["rays"]))
		row["head_seat_rays"] = int(seat["rays"])
		row["head_seat_radius_mm"] = float(seat["radius_mm"])
		row["head_seat_radii_mm"] = seat["radii_mm"]
		# The measured number behind the fraction: how far below the seat
		# plane the surface the ring met actually sits, at its worst.
		row["head_seat_gap_mm"] = seat["gap_mm"]
		row["head_seat_tolerance_mm"] = SEAT_TOLERANCE_MM
		var ring_rule := "one radius" if seat["radii_mm"].size() == 1 else "two radii"
		row["head_seat_rule"] = ("circumference coverage at %s, not bearing area: "
			+ "rays at %s mm from the axis must meet %s material within %.3f mm "
			+ "of the stated bearing profile. Gaps between sampled rings are not seen. "
			+ "Flat heads require some sampled support; countersunk heads require both "
			+ "rings to match the cone. Partial support is reported, not load-rated.") 			% [ring_rule, str(seat["radii_mm"]),
				"solid" if seat_on == SEAT_ON_SOLID else "reference", SEAT_TOLERANCE_MM]

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
		and bool(shank["clear"]) and engagement_ok and head_seat_clear and head_support_ok \
		and not bottoming
	row["why"] = _why(row)
	return row
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
	var blocked := ""
	if not bool(row.get("path_clear", true)):
		var first: Array = row.get("obstructions", []) as Array
		blocked = "the screw path is blocked"
		if not first.is_empty():
			blocked += " by %s%s" % [str((first[0] as Dictionary).get("node",
				"something")), " inside the engaged bore" if str((first[0]
				as Dictionary).get("span", "")) == "bore" else ""]
	# THE WRONG BORE COMES FIRST. A row whose bore is not a thread bore is a
	# joint that was never asked about: the fix is to pair the hole with the
	# bore the screw bites in, and an obstruction is only the second clause.
	if not bool(row.get("engagement_ok", true)) \
			and str(row.get("bore_fit", "thread")) != "thread":
		return ("the screw does not thread into this bore: at %.2f mm it "
			+ "is a %s hole the screw passes through, so the %.2f mm of "
			+ "overlap is not engagement — pair the hole with the bore "
			+ "the screw actually bites in") % [
				float(row.get("bore_dia_mm", 0.0)),
				str(row.get("bore_fit", "")),
				float(row.get("engagement_mm", 0.0))] \
			+ ("; " + blocked if not blocked.is_empty() else "")
	if not blocked.is_empty():
		return blocked
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
	if bool(row.get("bottoming", false)):
		return ("the screw bottoms out: its tip reaches %.2f mm below the hole "
			+ "centre and the bore's floor is at %.2f mm, so it is %.2f mm too "
			+ "long to seat") % [float(row.get("screw_tip_mm", 0.0)),
				float(row.get("bore_floor_mm", 0.0)),
				float(row.get("bottoming_by_mm", 0.0))]
	if not bool(row.get("head_support_ok", true)):
		return "the head lacks the required sampled support on its stated bearing profile"
	if not bool(row.get("head_seat_clear", true)):
		var over: Array = row.get("head_obstructions", []) as Array
		if not over.is_empty():
			return "the head cannot reach its seat: %s stands over it" \
				% str((over[0] as Dictionary).get("node", "something"))
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
