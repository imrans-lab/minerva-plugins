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
## is NOT interpolated — the reply says there is no entry and carries the
## numbers ungraded unless the caller states clearance_hole_dia_mm.
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
## screw, and that is the correct answer, not a false positive. Each span stops
## just SHORT of its own end plane, because a head ray meets the board AT the
## seat and that is the screw arriving; and a RING ray sees only the
## references, because the solid it would meet on that span is the boss it is
## heading into. The axis ray sees both.
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
## hole diameter. Medium is the series the fastener item names; fine and coarse
## exist and are NOT interpolated between, because a wrong allowance silently
## passes a joint that will not go together.
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

	# The B-Rep first, and OUTSIDE the reservation: it is an IPC round trip to
	# the worker, and holding the solid's collider across it would stall every
	# evaluation for its duration.
	var features := await _solid_cylinders(panel, str(document.get("source", "")), screw)

	var ticket: int = await checks.call("reserve")
	if ticket == 0:
		return _superseded(_nothing("a newer check started before this one could run"))

	var report := await _run(panel, gauge, checks, mesh_data, features, holes, screw, args)
	checks.call("release_reservation")
	return report


func _run(
	panel: Object,
	gauge: Node,
	checks: Object,
	mesh_data: Dictionary,
	features: Dictionary,
	holes: Array,
	screw: Dictionary,
	args: Dictionary
) -> Dictionary:
	if int(checks.call("build_solid", mesh_data)) <= 0:
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

	_records = panel.get_reference_state()
	var reference_scope := str(args.get("reference", ""))
	var mask := ALL_LAYERS
	if not reference_scope.is_empty():
		mask = int(gauge.call("mask_for", reference_scope))

	var pairing := _pair(bores, holes, args)
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
	_started_us = Time.get_ticks_usec()
	_casts = 0
	var checks: Object = args.get("checks", null)
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
	var half_depth := float(hole.get("depth_mm", 0.0)) * 0.5
	if half_depth <= 0.0:
		half_depth = float(hole.get("extent_mm", 0.0)) * 0.5
	var seat_t := -half_depth
	var bore_entry_t := (bore_start - hole_centre).dot(direction)
	var bore_exit_t := (bore_end - hole_centre).dot(direction)
	if bore_exit_t < bore_entry_t:
		var swap := bore_entry_t
		bore_entry_t = bore_exit_t
		bore_exit_t = swap

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
	var shank := _fan_clear(
		gauge, state, solid_state, checks, origin, direction,
		dia * 0.5, start_t, bore_entry_t - PATH_END_EPSILON_MM,
		hole_centre, mask, reference_scope
	)
	var head := {"clear": true, "obstructions": [], "rays": 0, "landed": 0}
	if head_dia > 0.0:
		head = _fan_clear(
			gauge, state, solid_state, checks, origin, direction,
			head_dia * 0.5, start_t, seat_t - PATH_END_EPSILON_MM,
			hole_centre, mask, reference_scope
		)
		head["landed"] = _seat_support(
			gauge, state, origin, direction, head_dia * 0.5, dia * 0.5,
			seat_t, hole_centre, mask, reference_scope
		)

	var engagement_ok := engagement >= engagement_required
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
		"engagement_mm": engagement,
		"engagement_required_mm": engagement_required,
		"engagement_ok": engagement_ok,
		"head_seat_clear": head_seat_clear,
		"bore_extent_mm": {"entry": bore_entry_t, "exit": bore_exit_t},
	}
	if not bool(shank["clear"]):
		row["obstructions"] = shank["obstructions"]
	if head_dia > 0.0:
		row["head_seat_supported"] = float(head["landed"]) / maxf(1.0, float(head["rays"]))
		if not head_seat_clear:
			row["head_obstructions"] = head["obstructions"]
	if bore.get("source", "b_rep") == "b_rep":
		var agreement := _agreement(bore, fitted, direction)
		if not agreement.is_empty():
			row["fit_agreement"] = agreement
	row["pass"] = bool(coaxiality["zone"].get("pass", false)) \
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
		zone["allowed_mm"] = float(allowance["radial_mm"])
		zone["allowed_zone_dia_mm"] = float(allowance["radial_mm"]) * 2.0
		zone["clearance_hole_dia_mm"] = float(allowance["hole_dia_mm"])
		zone["clearance_source"] = str(allowance["source"])
		zone["pass"] = zone_dia <= float(allowance["radial_mm"]) * 2.0
	else:
		zone["allowed_mm"] = null
		zone["pass"] = false
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
				"source": "ISO 273:1979 medium series, M%g -> %g mm"
					% [screw_dia, hole_dia],
			}
	return {
		"reason": "no ISO 273 medium clearance is tabulated for a %g mm screw, "
			% screw_dia + "and the series is not interpolated between; state "
			+ "clearance_hole_dia_mm to grade the coaxiality",
	}


# ---------------------------------------------------------------------------
# The ray fan
# ---------------------------------------------------------------------------

## Is the span [from_t, to_t] along the axis clear for a cylinder of `radius`?
##
## One ray on the axis and one ring at `radius`, spaced so no two adjacent rays
## are further apart than RING_SPACING_MM: that spacing IS the guarantee, and
## an obstruction narrower than it can pass between two rays unseen. Every ray
## starts at `origin`, which the caller has already put outside every body.
##
## WHICH BODIES COUNT, AND WHY THEY DIFFER BY RAY. A ring ray sees REFERENCE
## geometry only. The solid it would otherwise meet on this span is the boss
## the screw is heading into — its own top face, which a tilted or chamfered
## boss lifts above the mouth of its bore across the width of the ring — and
## calling that an obstruction fails every real joint. The AXIS ray sees both,
## because at the centre it travels down the open bore and cannot meet the
## boss: the only solid it can hit before the mouth is something genuinely in
## the way, a lid or a rib modelled over the hole.
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
	reference_scope: String
) -> Dictionary:
	var obstructions: Array = []
	var rays := _ring_points(direction, radius)
	var travel := (to_t - from_t) + OUTSIDE_MARGIN_MM * 2.0 + (datum - origin).length()
	for index in range(rays.size()):
		var offset: Vector3 = rays[index]
		var start: Vector3 = origin + offset
		var finish: Vector3 = start + direction * travel
		# rays[0] is the axis — see the note above on which bodies count.
		for hit in _crossings(gauge, state, solid_state, checks, start, finish,
				mask, reference_scope, index == 0):
			var crossing: Dictionary = hit
			var t: float = (crossing["point"] as Vector3 - datum).dot(direction)
			if t < from_t or t > to_t:
				continue
			if obstructions.size() < MAX_OBSTRUCTIONS:
				obstructions.append({
					"node": str(crossing.get("node", "")),
					"reference": str(crossing.get("reference", "")),
					"point_mm": _frames(crossing["point"], str(crossing.get("reference", ""))),
					"axial_mm": t,
					"ray_radius_mm": radius,
				})
			break
	return {
		"clear": obstructions.is_empty(),
		"obstructions": obstructions,
		"rays": rays.size(),
	}


## How much of the head ring actually lands on material at the seat plane. A
## head hanging half over the edge of its boss is "clear" — nothing is in its
## way — and still badly seated, and only this number says so.
##
## The ring is sampled between the shank radius and the head radius so a ray
## does not simply fall down the clearance hole and report an unsupported head
## on a perfectly good joint.
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
) -> int:
	var radius := (head_radius + shank_radius) * 0.5
	var landed := 0
	for offset in _ring_points(direction, radius):
		var start: Vector3 = origin + offset
		var finish: Vector3 = start + direction * ((datum - origin).length() * 2.0 + head_radius)
		var hit := _reference_ray(gauge, state, start, finish, mask, reference_scope)
		if hit.is_empty():
			continue
		var t: float = (hit["position"] as Vector3 - datum).dot(direction)
		if absf(t - seat_t) <= RING_SPACING_MM:
			landed += 1
	return landed


## The offsets of one fan: the axis, then a ring at `radius` with enough rays
## that adjacent ones are no more than RING_SPACING_MM apart.
func _ring_points(direction: Vector3, radius: float) -> Array:
	var points: Array = [Vector3.ZERO]
	if radius <= 0.0:
		return points
	var count := int(ceil(TAU * radius / RING_SPACING_MM))
	count = clampi(count, MIN_RING_RAYS, MAX_RING_RAYS)
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
				chosen = {"point": point, "node": "<solid>", "reference": ""}
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
## Returns {cylinders: [...]} or {cylinders: [], reason: "..."} — a worker that
## cannot answer is a reason to fall back to the fitter, not an error.
func _solid_cylinders(panel: Object, source: String, screw: Dictionary) -> Dictionary:
	if source.strip_edges().is_empty():
		return {"cylinders": [], "reason": "the document is empty"}
	if not panel.has_method("call_backend"):
		return {"cylinders": [], "reason": "this panel has no backend channel"}
	var envelope: Dictionary = await panel.call_backend(FEATURES_CHANNEL, {
		"source": source,
		"sense": "concave",
		"closed_only": true,
		# A bore far smaller than the screw is a vent or a texture, and one far
		# larger is a pocket. Both are noise in a fastener question.
		"min_dia_mm": float(screw["dia_mm"]) * 0.4,
		"max_dia_mm": float(screw["dia_mm"]) * 3.0,
	}, FEATURES_TIMEOUT_MS)
	if not bool(envelope.get("success", false)):
		return {"cylinders": [], "reason": "the worker could not read the "
			+ "solid's B-Rep features: %s" % str(envelope.get("error_message", ""))}
	var result: Dictionary = envelope.get("result", {}) as Dictionary
	var out: Array = []
	for entry in result.get("cylinders", []):
		var cylinder: Dictionary = entry
		var axis: Dictionary = cylinder.get("axis", {}) as Dictionary
		var origin := _vector(axis.get("origin_mm", []))
		var direction := _vector(axis.get("direction", [])).normalized()
		if direction.length_squared() < 0.5:
			continue
		out.append({
			"source": "b_rep",
			"dia_mm": float(cylinder.get("dia_mm", 0.0)),
			"axis": direction,
			"start": origin,
			"end": origin + direction * float(cylinder.get("length_mm", 0.0)),
			"centre": _vector(cylinder.get("centre_mm", [])),
			"length_mm": float(cylinder.get("length_mm", 0.0)),
		})
	return {"cylinders": out}


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
		"gate": "the fitted axis must sit within %g mm and %g degrees of the "
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
## spoken for. That is the one-to-one constraint, and it is the trap the item
## names: two bosses near one hole must not both claim it. Anything left over
## is reported by name under `unpaired` rather than quietly dropped.
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
				+ "passes closest to, one to one; anything more than %g mm "
				+ "off or %g degrees out is left unpaired rather than "
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
		"sampling": "the screw path is a ray fan, not a swept solid: an "
			+ "obstruction narrower than ray_spacing_mm can pass between two "
			+ "rays unseen",
		"screws": rows,
		"unpaired": pairing.get("unpaired", {}),
		"casts": _casts,
		"elapsed_ms": float(Time.get_ticks_usec() - _started_us) / 1000.0,
	}


## One sentence saying why this screw failed, or "" when it did not. A row of
## eight numbers does not tell a reader which one to act on.
func _why(row: Dictionary) -> String:
	var zone: Dictionary = row.get("coaxiality", {}) as Dictionary
	if not bool(zone.get("pass", false)):
		if zone.get("allowed_mm", null) == null:
			return "coaxiality is not graded: " + str(zone.get("clearance_source", ""))
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


func _superseded(report: Dictionary) -> Dictionary:
	report["superseded"] = true
	report["superseded_reason"] = "a newer evaluation or verb call started " \
		+ "before this check finished; the panel shows that one"
	return report


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
