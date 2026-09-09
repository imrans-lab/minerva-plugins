extends "fastener_seat.gd"
## fastener_probe.gd — what the screw's rays meet, and which bore is its hole.
##
## The measuring the fastener check is made of, sitting under the check itself.
##
## THE RAY FANS. A disc of rays along the screw's axis — sampled all the way
## out to a radius rather than around its rim, because a rib at half the shank
## radius is exactly what a rim-only fan misses — judged over the span the
## screw has to be clear over. Which hits are the screw ARRIVING and which are
## an obstruction is decided here, and so is the floor of a blind bore the tip
## would bottom out on.
##
## THE COAXIALITY ZONE. The bore axis's radial offset from the hole's axis at
## either end of the engaged length, doubled into the ISO 1101 zone diameter,
## graded against the clearance the screw actually has.
##
## WHERE THE SOLID'S BORES COME FROM. The worker's B-Rep cylindrical features
## first, where they are exact and where only a CLOSED cylinder is a bore; a
## fit to the display tessellation only for a feature the kernel has no
## cylindrical face for. Where both sources exist for one feature their
## disagreement is measured, which is what licenses the fallback at all.
##
## PAIRING. Bores to reference holes, one to one, greedy by what the bore is
## FOR and only then by how close it is — because distance alone pairs the
## wrong one of two coaxial bores in a two-shell enclosure. Anything left over
## is named with its fit, not quietly dropped.
##
## The small shared things all of those need — the screw the caller asked
## about, a world point or direction in both frames, the reference poses, the
## reach of the scene — are here too.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: fastener_checks.gd extends this script.

const _MeshFeatures: Script = preload("mesh_features.gd")
const _WorkerReply: Script = preload("worker_reply.gd")
const _MeshGauge: Script = preload("mesh_gauge.gd")
## The index list the `pairs` override is written against.
const _ReplyShape: Script = preload("reply_shape.gd")

## The IPC channel that answers with the solid's B-Rep cylinders. Channel name
## = MCP tool name; the worker method behind it is "cylindrical_features".
const FEATURES_CHANNEL: String = "cad.cylindrical_features"
## Reading faces off a B-Rep costs one translate of the DSL, which is the same
## work an evaluation already does; a shell with a hundred bosses is still
## seconds, not minutes.
const FEATURES_TIMEOUT_MS: int = 60000


## Where the head lands, as the caller states it. One description of one screw
## covers every enclosure shape, and each value names the BODY the seat plane
## is read off — never "whichever surface is nearest", which cannot tell a seat
## from the thing standing in the head's way.
##   reference  the head-side face of the reference plate the hole is in. The
##              board-on-bosses case, and the default.
##   solid      the first face of the EVALUATED SOLID the head's bearing ring
##              meets travelling along the screw's axis. The two-shell cases:
##              a head counterbored into a tray floor under a sandwiched board,
##              or a head on a lid's outer skin.
##   offset     a seat plane the caller places itself, `seat_offset_mm` along
##              the screw's travel from the hole's centre (negative is short of
##              the hole, which is where a head coming from below sits).
const SEAT_ON_REFERENCE: String = "reference"
const SEAT_ON_SOLID: String = "solid"
const SEAT_AT_OFFSET: String = "offset"


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

## A solid surface this close to the bore's own radius IS the bore wall. It
## absorbs the chordal error of a tessellated wall, nothing more.
const BORE_WALL_TOLERANCE_MM: float = 0.05
## How far off perpendicular to the bore's axis a hit's normal may lean and
## still be the bore's WALL: sin 15 degrees, so a drafted or tapered wall is
## still the wall while a shelf or floor face at the same radius — whose
## normal is axial, |dot| near 1 — is not.
const BORE_WALL_MAX_AXIAL_NORMAL: float = 0.26

## Obstructions listed per screw. The first one is the one that gets fixed.
const MAX_OBSTRUCTIONS: int = 8


## The reference records the running check was started with, for the poses that
## turn a world point into the reference's own frame.
var _records: Array = []


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
## outside every body — `from_t` is where the JUDGED span begins, which may be
## well inside that travel, and a hit short of it belongs to another fan.
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
## the bore, a lid over the hole, a wall the shell grew into the gap. The HEAD
## fan passes `seat_t` instead of a bore: the only solid it may meet on its
## span is a face lying in the seat plane itself — the solid's own seat, or
## the boss top the seat plane runs through — and a solid face anywhere else
## above the seat is a feature standing between the head and where it sits.
## Pass an empty `expected` and the fan sees the references only.
##
## THE ENGAGED BORE IS INSPECTED TOO. When `expected` carries bore_from_t and
## bore_to_t, hits between them — past the mouth, down to the engaged depth —
## are judged by one rule: a hit ON THE SOLID at the bore's own radius about
## its axis is the wall (the screw's thread is meant to meet it), and anything
## else there is an obstruction, reported with span "bore". A REFERENCE part
## at that radius — a sleeve, a post, a pin left in the bore — is not the
## wall however exactly its surface sits on it; only the solid has a wall,
## and the wall is told from a shelf ending at the same radius by its normal.
## The bore span runs to where the screw's TIP reaches, so solid met at or
## past the bore's extent end is the floor of a blind bore the screw would
## bottom out on: it is returned as `floor_t` (the nearest such hit, or null),
## not listed as an obstruction.
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
	var bore_from_t := float(expected.get("bore_from_t", INF))
	var bore_to_t := float(expected.get("bore_to_t", -INF))
	# Past the bore's extent end, inside the span the screw's tip reaches,
	# the solid across the bore is the bore's FLOOR: the nearest such hit is
	# reported rather than listed as an obstruction, because what it says is
	# not "something is in the way" but "the screw is too long for this bore".
	var floor_from_t := float(expected.get("bore_exit_t", INF)) - BORE_WALL_TOLERANCE_MM
	var floor_t: Variant = null
	var far_end := maxf(to_t, bore_to_t) + _head_drop(expected.get("head_profile", {}), radius, 0.0)
	# Long enough to carry every ray from where it starts to the far end of
	# the span, measured from the ORIGIN: the caller may begin the span well
	# inside the ray's travel (a shank seated on the solid starts at the seat
	# plane, not outside), and a length derived from the span's start would
	# then stop the ray short of what it has to look at.
	var origin_t := (origin - datum).dot(direction)
	var travel := (far_end - origin_t) + OUTSIDE_MARGIN_MM * 2.0
	var see_solid := not expected.is_empty()
	for index in range(rays.size()):
		var offset: Vector3 = rays[index]
		var ray_to_t := to_t + _head_drop(expected.get("head_profile", {}), radius, offset.length())
		var start: Vector3 = origin + offset
		var finish: Vector3 = start + direction * travel
		for hit in _crossings(gauge, state, solid_state, checks, start, finish,
				mask, reference_scope, see_solid):
			var crossing: Dictionary = hit
			var t: float = (crossing["point"] as Vector3 - datum).dot(direction)
			var span := ""
			if t >= from_t and t <= ray_to_t:
				span = "approach"
				if bool(crossing.get("solid", false)) \
						and _is_the_screw_arriving(crossing["point"], t, expected):
					continue
			elif t >= bore_from_t and t <= bore_to_t:
				span = "bore"
				if bool(crossing.get("solid", false)):
					if _is_the_bore_wall(crossing["point"],
							crossing.get("normal", Vector3.ZERO), expected):
						continue
					if t >= floor_from_t:
						var offset_from_axis: Vector3 = crossing["point"] - expected["point"]
						var axis: Vector3 = expected["axis"]
						var radial := (offset_from_axis - axis * offset_from_axis.dot(axis)).length()
						var normal: Vector3 = crossing.get("normal", Vector3.ZERO)
						# The far mouth outside the pilot radius is thread leaving
						# the boss, not a floor across the bore's interior.
						if radial >= float(expected["radius"]) - BORE_WALL_TOLERANCE_MM:
							if absf(t - float(expected["bore_exit_t"])) <= BORE_WALL_TOLERANCE_MM \
									and absf(normal.dot(direction)) > 0.5:
								continue
						elif normal.dot(direction) < -0.5:
							if floor_t == null or t < float(floor_t):
								floor_t = t
							continue
			else:
				continue
			if obstructions.size() < MAX_OBSTRUCTIONS:
				obstructions.append({
					"node": str(crossing.get("node", "")),
					"reference": str(crossing.get("reference", "")),
					"point_mm": _frames(crossing["point"], str(crossing.get("reference", ""))),
					"axial_mm": t,
					# Where on the screw's travel it was met: on the approach
					# to the mouth, or inside the engaged bore.
					"span": span,
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
		"floor_t": floor_t,
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
## something in its way? See _fan_clear's note for the cases and why they are
## the only ones. `expected` names the fan: a `seat_t` is the head's, whose
## one legitimate solid hit is a face in the seat plane, to the same axial
## tolerance the seat ring lands with; a bore is the shank's.
func _is_the_screw_arriving(point: Vector3, t: float, expected: Dictionary) -> bool:
	if expected.has("seat_t"):
		return absf(t - float(expected["seat_t"])) <= SEAT_TOLERANCE_MM
	if t >= float(expected["from_t"]) - float(expected["band"]):
		# The boss's own end face, or anything at or past the mouth.
		return true
	var axis: Vector3 = expected["axis"]
	var offset: Vector3 = point - (expected["point"] as Vector3)
	var radial := (offset - axis * offset.dot(axis)).length()
	if radial > float(expected["radius"]) + BORE_WALL_TOLERANCE_MM:
		return false
	return t >= float(expected["from_t"]) and t <= float(expected["to_t"])


## Is this hit on the solid, inside the engaged bore, the bore's own wall? A
## wall hit lies at the bore's radius about the bore's axis, to the
## tessellation slack a chorded cylinder has, AND its face is the wall's: the
## normal of a cylinder's facet is radial, perpendicular to the axis, while a
## shelf or a floor ending at the wall has a face at that same radius whose
## normal is axial — the same point in the bore, a different surface, and one
## the screw cannot pass. A hit nearer the axis is something across the bore,
## and a hit further out is a surface in the material the thread would bite.
## Radius alone cannot tell a reference part from the wall either, so the
## caller asks this only of solid hits. A hit that carries no normal (a shape
## that cannot report one) falls back to the radius rule.
func _is_the_bore_wall(point: Vector3, normal: Vector3, expected: Dictionary) -> bool:
	var axis: Vector3 = expected["axis"]
	var offset: Vector3 = point - (expected["point"] as Vector3)
	var radial := (offset - axis * offset.dot(axis)).length()
	if absf(radial - float(expected["radius"])) > BORE_WALL_TOLERANCE_MM:
		return false
	if normal.length_squared() < 0.5:
		return true
	return absf(normal.normalized().dot(axis)) <= BORE_WALL_MAX_AXIAL_NORMAL


## Do the panel's references still stand where this check's snapshot says?
##
## The collider generation is not enough on its own: poses are what every
## local coordinate is converted through, and a panel that re-poses without
## rebuilding — or rebuilds a moment later — would otherwise let a reply mix
## the frames of two documents. Names, exact poses, mesh identities and local
## transforms are compared even before the lazy collider rebuild. `snapshot`
## is the copy the running check took; imported meshes are immutable resources.
func _same_poses(snapshot: Array, panel: Object) -> bool:
	if not panel.has_method("get_reference_state"):
		return true
	var current: Array = panel.get_reference_state()
	if current.size() != snapshot.size():
		return false
	for index in range(snapshot.size()):
		var was: Dictionary = snapshot[index]
		var now: Dictionary = current[index]
		if str(was.get("name", "")) != str(now.get("name", "")):
			return false
		var before: Transform3D = was.get("pose", Transform3D.IDENTITY)
		var after: Transform3D = now.get("pose", Transform3D.IDENTITY)
		if before != after:
			return false
	return _MeshGauge.bodies_digest(_MeshGauge.bodies_from_records(snapshot)) \
		== _MeshGauge.bodies_digest(_MeshGauge.bodies_from_records(current))


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
func _solid_cylinders(panel: Object, source: String, screw: Dictionary, args: Dictionary = {}) -> Dictionary:
	if source.strip_edges().is_empty():
		return {"cylinders": [], "reason": "the document is empty"}
	if not panel.has_method("call_backend"):
		return {"cylinders": [], "reason": "this panel has no backend channel"}
	var envelope: Dictionary = await panel.call_backend(FEATURES_CHANNEL, {
		"source": source,
		"selection": args.get("selection", ""), "configuration": args.get("configuration", ""),
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
		for field in ["extent_max_mm", "full_start_mm", "full_end_mm", "extent_full_bound_mm"]:
			var value: Variant = cylinder.get(field)
			if not (value is float or value is int) or not is_finite(float(value)):
				return {"cylinders": [], "error": "B-Rep extent metadata missing or invalid: %s" % field}
		for field in ["extent_exact", "extent_full_bounded"]:
			if not cylinder.get(field) is bool:
				return {"cylinders": [], "error": "B-Rep extent metadata missing or invalid: %s" % field}
		var wall_length := float(cylinder["extent_max_mm"])
		var full_start := float(cylinder["full_start_mm"])
		var full_end := float(cylinder["full_end_mm"])
		if wall_length < 0.0 or full_start < 0.0 or full_end < full_start \
				or full_end > wall_length or float(cylinder["extent_full_bound_mm"]) < 0.0:
			return {"cylinders": [], "error": "B-Rep extent metadata has invalid bounds"}
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
			"extent_exact": cylinder["extent_exact"],
			"extent_bounded": cylinder["extent_full_bounded"],
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
## Greedy by FIT, then by distance. Distance alone cannot pair a two-shell
## enclosure: a board bolted from below sits between a clearance bore in the
## tray and a pilot in the post above it, both dead coaxial with the hole, and
## the nearest of the two is whichever the modeller happened to put closer. The
## screw only threads into one of them, so every admissible (bore, hole)
## combination is ranked by what the bore is FOR — thread first, then a
## clearance bore the screw only passes through, then a bore too small to take
## it at all — and only then by how far the bore's axis passes from the hole's
## centre. Pairs are taken in that order, skipping any whose bore or hole is
## already spoken for: two bosses near one hole must not both claim it.
## Anything left over is reported by name, WITH its fit, under `unpaired`
## rather than quietly dropped.
func _pair(bores: Array, holes: Array, screw: Dictionary, args: Dictionary) -> Dictionary:
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

	# Only auto-pairing collapses steps. Explicit indices still address every
	# original hole record, and the response exposes those same indices.
	var step_owner := _step_owners(prepared_holes) if (args.get("pairs", []) as Array).is_empty() else {}

	var screw_dia := float(screw.get("dia_mm", 0.0))
	var clearance_dia := _clearance_bore_dia(screw_dia, args)
	var explicit: Array = args.get("pairs", []) as Array
	var candidates: Array = []
	if explicit.is_empty():
		for b in range(bores.size()):
			for h in range(prepared_holes.size()):
				if step_owner.get(h, h) != h:
					continue
				var scored := _score(bores[b] as Dictionary,
					prepared_holes[h] as Dictionary, screw_dia, clearance_dia)
				if scored.is_empty():
					continue
				scored["bore_index"] = b
				scored["hole_index"] = h
				candidates.append(scored)
		# Fit first, distance second. Sorting on the pair puts every bore the
		# screw can thread into ahead of every bore it merely passes through,
		# so a clearance bore is only ever paired when no thread bore lines up.
		candidates.sort_custom(func(a, b):
			if int(a["fit_rank"]) != int(b["fit_rank"]):
				return int(a["fit_rank"]) < int(b["fit_rank"])
			return float(a["offset"]) < float(b["offset"]))
	else:
		for entry in explicit:
			var asked: Dictionary = entry
			var b := int(asked.get("solid_feature", -1))
			var h := int(asked.get("reference_hole", -1))
			if b < 0 or b >= bores.size() or h < 0 or h >= prepared_holes.size():
				continue
			var scored := _score(bores[b] as Dictionary,
				prepared_holes[h] as Dictionary, screw_dia, clearance_dia, true)
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
		for step in step_owner:
			if step_owner[step] == h:
				taken_holes[step] = true
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
			"fit": str(candidate["fit"]),
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
			"fit": _fit_of(float(bore.get("dia_mm", 0.0)), screw_dia, clearance_dia),
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
	# The holes AS INDEXED. A hole with no usable axis never reaches
	# prepared_holes, so a list built from the caller's own holes array would
	# name rows the override does not address.
	var indexed: Array = []
	for prepared_entry in prepared_holes:
		indexed.append((prepared_entry as Dictionary)["hole"])
	return {
		"pairs": pairs,
		"reference_hole_index": _ReplyShape.hole_index_rows(indexed),
		"unpaired": {
			"solid_features": loose_bores,
			"reference_holes": loose_holes,
			"rule": ("a bore the screw can THREAD into (up to %s mm across "
				+ "for this screw) is preferred over one it only passes "
				+ "through, and only then is the bore whose axis passes "
				+ "closest to the hole's centre taken, one to one; anything "
				+ "more than %s mm off or %s degrees out is left unpaired "
				+ "rather than mispaired") % [clearance_dia,
					PAIR_MAX_OFFSET_MM, PAIR_MAX_ANGLE_DEG],
			"clearance_bore_dia_mm": clearance_dia,
		},
	}


## Adjacent cylindrical intervals on the same reference node form one
## mounting feature. Use the narrowest step to locate the shank and seat.
## Coaxial holes across air gaps or in different nodes remain separate.
func _step_owners(prepared: Array) -> Dictionary:
	var owners := {}
	for i in range(prepared.size()):
		owners[i] = i
	for i in range(prepared.size()):
		for j in range(i):
			var a: Dictionary = prepared[i]
			var b: Dictionary = prepared[j]
			var ah: Dictionary = a["hole"]
			var bh: Dictionary = b["hole"]
			if str(ah.get("reference", "")).is_empty() or ah.get("reference") != bh.get("reference") or ah.get("node") != bh.get("node"):
				continue
			var axis: Vector3 = a["axis"]
			if absf(axis.dot(b["axis"])) < cos(deg_to_rad(AGREEMENT_ANGLE_DEG)):
				continue
			var delta: Vector3 = b["centre"] - a["centre"]
			var along := delta.dot(axis)
			if (delta - along * axis).length() > AGREEMENT_CENTRE_MM:
				continue
			var ae := float(ah.get("extent_mm", ah.get("depth_mm", 0.0)))
			var be := float(bh.get("extent_mm", bh.get("depth_mm", 0.0)))
			if ae <= 0.0 or be <= 0.0 or absf(absf(along) - (ae + be) * 0.5) > SEAT_TOLERANCE_MM:
				continue
			var left: int = owners[i]
			var right: int = owners[j]
			var owner := left if float(prepared[left]["hole"].get("dia_mm", 0.0)) < float(prepared[right]["hole"].get("dia_mm", 0.0)) else right
			for k in owners:
				if owners[k] == left or owners[k] == right:
					owners[k] = owner
	return owners


## How well one bore lines up with one hole, or {} when it is not a candidate.
## `fit` says what the bore is FOR and `fit_rank` orders the three kinds; see
## _fit_of.
func _score(bore: Dictionary, prepared: Dictionary, screw_dia: float,
		clearance_dia: float, forced: bool = false) -> Dictionary:
	var bore_axis: Vector3 = (bore["axis"] as Vector3).normalized()
	var hole_axis: Vector3 = prepared["axis"]
	var aligned := bore_axis if bore_axis.dot(hole_axis) >= 0.0 else -bore_axis
	var angle := rad_to_deg(aligned.angle_to(hole_axis))
	var offset := _radial_offset(
		prepared["centre"], hole_axis, bore["centre"], aligned, 0.0)
	if not forced and (angle > PAIR_MAX_ANGLE_DEG or offset > PAIR_MAX_OFFSET_MM):
		return {}
	var fit := _fit_of(float(bore.get("dia_mm", 0.0)), screw_dia, clearance_dia)
	return {"offset": offset, "angle": angle, "fit": fit,
		"fit_rank": FIT_RANK.get(fit, 1)}


# ---------------------------------------------------------------------------
# Small shared things
# ---------------------------------------------------------------------------

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
	var seat := str(raw.get("seat", SEAT_ON_REFERENCE))
	if not [SEAT_ON_REFERENCE, SEAT_ON_SOLID, SEAT_AT_OFFSET].has(seat):
		return {"error": ("screw.seat must be 'reference' (the head lands on "
			+ "the reference plate the hole is in), 'solid' (on the evaluated "
			+ "solid — a counterbore in a tray floor, a lid's outer skin) or "
			+ "'offset' with seat_offset_mm; '%s' is none of those") % seat}
	var head_kind := str(raw.get("head_kind", "flat"))
	var head_angle := float(raw.get("head_angle_deg", 90.0))
	if head_kind not in ["flat", "countersunk"] or not is_finite(head_angle) or head_angle <= 0.0 or head_angle >= 180.0:
		return {"error": "head_kind must be flat or countersunk; head_angle_deg must be between 0 and 180"}
	var offset := float(raw.get("seat_offset_mm", 0.0))
	if seat == SEAT_AT_OFFSET and not is_finite(offset):
		return {"error": "screw.seat 'offset' needs a finite seat_offset_mm: "
			+ "how far along the screw's travel from the hole's centre the "
			+ "head lands, negative for a head that arrives from the far side "
			+ "of the hole"}
	return {
		"dia_mm": dia,
		"length_mm": length,
		"head_dia_mm": head,
		"head_dia_assumed": assumed,
		"head_kind": head_kind,
		"head_angle_deg": head_angle,
		"seat": seat,
		"seat_offset_mm": offset,
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
