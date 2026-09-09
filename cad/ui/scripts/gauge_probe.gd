extends RefCounted
## gauge_probe.gd — the rays ONE gauge is measured with.
##
## The physics is a single question — "what does this segment hit" — handed
## in as a Callable, exactly as gauge_seed.gd takes its own. So the patterns
## below are the same whichever space, or pair of spaces, the caller casts
## into, and mesh_gauge.gd is left holding the colliders and the job queue.
##
## `cast` is called as cast.call(from: Vector3, to: Vector3) and must return a
## physics hit dictionary — {} for a miss, otherwise at least "position". The
## hits are handed BACK raw: attributing one to a node, a reference or the
## evaluated solid is the caller's knowledge, not this file's.
##
## Every search here is bounded (constraint 3 in mesh_gauge.gd): free space
## outside the part reads exactly like free space inside a hole, so a run that
## met nothing reports the bound and says it was not bounded by a surface.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/gauge_probe.gd")

const _Shapes: Script = preload("gauge_shapes.gd")

## Hits reported for one gauge. Contacts are for telling the caller where it
## fouled, not for a complete census.
const MAX_CONTACTS: int = 8
## Clearance either side of a candidate when a ray is cast along its axis to
## ask whether the hole goes through.
const THROUGH_PAD_MM: float = 3.0


# ---------------------------------------------------------------------------
# Fouling
# ---------------------------------------------------------------------------

## Everywhere a gauge of this shape, standing at `centre` along `axis`, runs
## into geometry. Empty means it fits.
##
## Every ray starts inside the gauge and ends on its surface, so a hit is a
## point the gauge's own volume covers.
static func fouls(
	cast: Callable,
	kind: String,
	size: Vector3,
	centre: Vector3,
	axis: Vector3
) -> Array:
	var hits: Array = []
	match kind:
		"cylinder":
			var radius := maxf(0.001, size.x * 0.5)
			var half := maxf(0.0005, size.y * 0.5)
			for from in _Shapes.stations(centre, axis, size.y):
				collect(cast, from, _Shapes.radials(axis), radius, hits)
			# The ends. A pin also fouls on the floor of a pocket, and the axis
			# alone would miss a floor that only reaches part of the way in.
			for direction in [axis, -axis]:
				for start in _Shapes.cap_origins(centre, axis, radius):
					collect(cast, start, [direction], half, hits)
		"sphere":
			collect(cast, centre, _Shapes.sphere_directions(),
				maxf(0.001, size.x * 0.5), hits)
		"box":
			var basis: Basis = _Shapes.basis_for_axis(axis)
			for direction in _Shapes.sphere_directions():
				var reach := box_reach(basis, size, direction)
				if reach > 0.0:
					collect(cast, centre, [direction], reach, hits)
	return hits


## Cast one ray per direction and record every one that lands on geometry.
static func collect(
	cast: Callable,
	from: Vector3,
	directions: Array,
	reach: float,
	hits: Array
) -> void:
	for direction in directions:
		if hits.size() >= MAX_CONTACTS:
			return
		var hit: Dictionary = cast.call(from, from + (direction as Vector3) * reach)
		if hit.is_empty():
			continue
		hits.append(hit)


## How far a box gauge's own surface stands from its centre along `direction`:
## the shortest of the three face distances, so a ray cast to it ends ON the
## box. 0.0 when the direction reaches no face.
static func box_reach(basis: Basis, size: Vector3, direction: Vector3) -> float:
	var local: Vector3 = basis.inverse() * direction
	var reach := INF
	for component in [
		[local.x, size.x * 0.5], [local.y, size.y * 0.5], [local.z, size.z * 0.5]
	]:
		if absf(component[0]) > 0.0001:
			reach = minf(reach, absf(component[1] / component[0]))
	return 0.0 if reach == INF else reach


# ---------------------------------------------------------------------------
# Air around a gauge that fouled nothing
# ---------------------------------------------------------------------------

## Air around a gauge that fouled nothing: {"clearance_mm", "bounded"}.
##
## A CYLINDER grows RADIALLY — the question a pin in a bore asks, and the one
## the hole verification is built on. A SPHERE and a BOX are measured from
## their own surface along the 26-way star they were tested with: the ray
## leaves the centre, the gauge's own reach along that direction comes off what
## the ray ran, and the smallest remainder is the air. Measuring only the
## cylinder left the other two answering "clearance 0, bound <the scene>" at
## every position, which reads as "nothing is here" wherever the gauge stands.
##
## `bounded` is false when no ray met anything inside `bound`; the number is
## then a FLOOR and the caller must report it as "at least this much".
static func free_air(
	cast: Callable,
	kind: String,
	size: Vector3,
	centre: Vector3,
	axis: Vector3,
	bound: float
) -> Dictionary:
	if kind == "cylinder":
		var grown := largest_radius(cast, centre, axis, size.y, size.x * 0.5, bound)
		return {
			"clearance_mm": maxf(0.0, float(grown["radius_mm"]) - size.x * 0.5),
			"bounded": bool(grown["bounded"]),
		}
	var basis: Basis = _Shapes.basis_for_axis(axis)
	var nearest_distance := bound
	var bounded := false
	for direction in _Shapes.sphere_directions():
		var reach: float = maxf(0.001, size.x * 0.5) if kind == "sphere" \
			else box_reach(basis, size, direction)
		if reach <= 0.0:
			continue
		var hit: Dictionary = cast.call(
			centre, centre + (direction as Vector3) * (reach + bound))
		if hit.is_empty():
			continue
		bounded = true
		nearest_distance = minf(nearest_distance,
			maxf(0.0, centre.distance_to(hit["position"] as Vector3) - reach))
	return {"clearance_mm": nearest_distance, "bounded": bounded}


## The nearest surface in any direction from `centre`, or {}. The witness for a
## gauge BURIED in material: its fouling rays stop inside the wall and meet
## nothing, so the skin of the body it is inside has to be looked for over the
## whole scene's reach rather than collected from the rays that tested it.
static func nearest(cast: Callable, centre: Vector3, reach: float) -> Dictionary:
	if reach <= 0.0:
		return {}
	var best := {}
	var best_distance := INF
	for direction in _Shapes.sphere_directions():
		var hit: Dictionary = cast.call(centre, centre + (direction as Vector3) * reach)
		if hit.is_empty():
			continue
		var distance := centre.distance_to(hit["position"] as Vector3)
		if distance < best_distance:
			best_distance = distance
			best = hit
	return best


# ---------------------------------------------------------------------------
# Centring, radius and the through test
# ---------------------------------------------------------------------------

## Largest gauge radius that still fits at `centre`, measured rather than
## searched: the shortest of the rays leaving the axis IS the radius, because a
## pin of that radius touches there and nothing smaller touches anywhere.
##
## Returns {"radius_mm", "bounded"}. `bounded` is false when NO ray met a
## surface within `upper`: the gauge stands in open space, `upper` is the search
## bound rather than a wall, and the radius is only a FLOOR — the caller must
## report it as "at least this much" and never as a measurement. `radius_mm` is
## 0.0 (bounded) when a pin of `lower` would already foul, which is the caller's
## signal that the candidate is not a hole at all.
static func largest_radius(
	cast: Callable,
	centre: Vector3,
	axis: Vector3,
	length: float,
	lower: float,
	upper: float
) -> Dictionary:
	var nearest_hit := upper
	var bounded := false
	for from in _Shapes.stations(centre, axis, length):
		for direction in _Shapes.radials(axis):
			var hit: Dictionary = cast.call(from, from + direction * upper)
			if hit.is_empty():
				continue
			bounded = true
			nearest_hit = minf(nearest_hit, from.distance_to(hit["position"] as Vector3))
	if bounded and nearest_hit < lower:
		return {"radius_mm": 0.0, "bounded": true}
	return {"radius_mm": nearest_hit, "bounded": bounded}


## Slide the gauge along `direction` until it stops fitting either way, and
## return the midpoint of the free interval. Bounded, always.
static func recentre(
	cast: Callable,
	centre: Vector3,
	direction: Vector3,
	probe_radius: float,
	bound: float
) -> Vector3:
	var forward := free_run(cast, centre, direction, probe_radius, bound)
	var backward := free_run(cast, centre, -direction, probe_radius, bound)
	return centre + direction * ((forward - backward) * 0.5)


## Largest distance the probe can be pushed along `direction` and still fit.
##
## One ray does it: the FIRST surface along that direction is where the probe's
## leading edge stops, so the run is that distance less the probe's own radius.
## Constraint 3 comes free — the run cannot jump the wall of the part and read
## the open air beyond as more room — and it is bounded by `bound` besides.
static func free_run(
	cast: Callable,
	centre: Vector3,
	direction: Vector3,
	probe_radius: float,
	bound: float
) -> float:
	var reach := bound + probe_radius
	var hit: Dictionary = cast.call(centre, centre + direction * reach)
	if hit.is_empty():
		return bound
	var distance := centre.distance_to(hit["position"] as Vector3)
	return clampf(distance - probe_radius, 0.0, bound)


## Does the hole go all the way through? A ray along the axis from clear air on
## one side to clear air on the other hits nothing in a through hole and hits
## the floor of a blind pocket. This is the one question a fitter cannot
## answer: the wall of a blind pocket is the same cylinder as the wall of a
## through hole.
static func through(
	cast: Callable,
	centre: Vector3,
	axis: Vector3,
	half_extent: float
) -> Dictionary:
	var reach := half_extent + THROUGH_PAD_MM
	var low := centre - axis * reach
	var high := centre + axis * reach
	var forward: Dictionary = cast.call(low, high)
	if forward.is_empty():
		return {"through": true, "depth_mm": half_extent * 2.0}
	var backward: Dictionary = cast.call(high, low)
	var entry_low := centre - axis * half_extent
	var entry_high := centre + axis * half_extent
	var depth_from_low := ((forward["position"] as Vector3) - entry_low).dot(axis)
	var depth_from_high := 0.0
	if not backward.is_empty():
		depth_from_high = (entry_high - (backward["position"] as Vector3)).dot(axis)
	return {
		"through": false,
		"depth_mm": maxf(0.0, maxf(depth_from_low, depth_from_high)),
	}
