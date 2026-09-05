extends RefCounted
## An edge that RUNS ALONG a face is touching it, not through it.
##
## THE CASE THIS EXISTS FOR. A boss whose flat top is coplanar with the board
## it carries is the most common designed contact in an enclosure. The two
## flat faces share a plane, so every triangle edge of the board's underside
## that happens to pass over the boss enters the boss's rim on one side and
## leaves it on the other — a chord of the rim, four millimetres long on a six
## millimetre boss. Every per-crossing test agrees that chord is real: the edge
## does straddle the cylinder's side wall, and the points a short step along it
## are genuinely inside the boss's material, by whatever the float error of the
## contact plane happens to be. The crossing is reported as a penetration whose
## depth is the chord, and an agent reading it moves the boss away from the
## board it is meant to hold up.
##
## WHAT TELLS THEM APART. Not the crossing, and not the parent edge — the RUN
## BETWEEN TWO CROSSINGS. An edge that pierces a body leaves the surface behind
## and travels through material; an edge that lies in a face never leaves the
## surface at all. Only the segment INSIDE the other body can be asked that:
## the parent edge is mostly outside the boss it passes over, so sampling it
## end to end answers about the air around the rim and can never clear a
## crossing. So the chord is sampled, and if a face of that body is within the
## touch epsilon of EVERY sample, the run is lying in it and there is no
## overlap to report. Raise the boss half a millimetre into the board and the
## chord sits half a millimetre inside, far outside the epsilon, and the
## interference stands.
##
## The rays are the caller's: this module owns the rule, not the space. The
## Callable is `func(from: Vector3, to: Vector3) -> Variant` returning the
## first hit position along the segment, or null.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: scripts/geometry_checks.gd, both cast directions.

## Where along the edge it is sampled. The midpoint first, then outwards: an
## edge that really passes through material says so at its middle, and the
## first sample that is not on a face ends the question. The ends themselves
## are never sampled — a crossing IS at an end, and a face is trivially within
## epsilon of it whichever way the edge runs.
const SAMPLE_FRACTIONS: Array[float] = [0.5, 0.25, 0.75, 0.08, 0.92]

## How far either side of a sample the probe ray reaches, in touch epsilons.
## The ray STRADDLES the sample rather than starting on it: a ray fired from a
## point that already sits in the material it is looking for reports whatever
## it meets next, while one that arrives from outside registers the face it
## crosses, which is the face being measured to.
const STRADDLE_EPSILONS: float = 10.0

## The three axes, both senses. Both, because one ray finds only the first
## face along its own direction, and the face the sample is resting on can be
## behind another one.
const _PROBE_DIRECTIONS: Array[Vector3] = [
	Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD,
	Vector3.UP, Vector3.DOWN,
]


## Does the segment a→b lie in a face of the body `ray` casts against, along
## its whole length? Callers pass the RUN between two crossings, not the parent
## edge. False for a degenerate segment: nothing runs along a face in no
## distance.
##
## A chord short enough that its own sagitta is inside the epsilon reads as a
## run along the curved wall it clipped, and is cleared. That is a graze — on a
## three millimetre boss it is under a twentieth of a millimetre long — and the
## depth it would have contributed is smaller still.
static func runs_in_surface(a: Vector3, b: Vector3, epsilon: float,
		ray: Callable) -> bool:
	if a.distance_to(b) <= epsilon:
		return false
	for fraction in SAMPLE_FRACTIONS:
		if not surface_at(a.lerp(b, fraction), epsilon, ray):
			return false
	return true


## Is a face of that body within `epsilon` of `point`?
static func surface_at(point: Vector3, epsilon: float, ray: Callable) -> bool:
	var span := epsilon * STRADDLE_EPSILONS
	for direction in _PROBE_DIRECTIONS:
		var offset: Vector3 = direction * span
		var hit: Variant = ray.call(point + offset, point - offset)
		if hit is Vector3 and point.distance_to(hit as Vector3) <= epsilon:
			return true
	return false


## Which of these crossings are real penetrations?
##
## `crossings` are the crossings of the ONE edge a→b, in order along it, each
## {point: Vector3, key: String}; `key` names the body crossed, because a
## crossing of one body bounds no run through another. `ray_for` is
## func(key: String) -> Callable, the ray against that one body.
##
## Every crossing bounds two runs along its edge — back to the previous
## crossing of the same body, or to the edge's own start, and forward to the
## next one, or to its end. A crossing is CONTACT when either of those runs
## lies in a face of the body: the edge was travelling in the surface and left
## it through the rim of that face, which is the signature of a designed flush
## fit and not of overlap. That end has to be counted, because a rim chord is
## usually bounded by a crossing at one end and the triangle's own vertex,
## sitting a float-noise depth inside the body, at the other — a gate that
## only looked between two crossings would clear almost none of them.
##
## Testing both runs regardless of which one is inside the material costs
## nothing in accuracy: a run through open air has no face within the epsilon
## of it to find, so it answers no on its own.
##
## Returns the surviving indices, in order.
static func penetrating_indices(a: Vector3, b: Vector3, crossings: Array,
		epsilon: float, ray_for: Callable) -> PackedInt32Array:
	var out := PackedInt32Array()
	for index in range(crossings.size()):
		var crossing: Dictionary = crossings[index]
		var key := str(crossing.get("key", ""))
		var point: Vector3 = crossing.get("point", Vector3.ZERO)
		var ray: Callable = ray_for.call(key)
		if runs_in_surface(_neighbour(crossings, index, -1, key, a), point,
					epsilon, ray) \
				or runs_in_surface(point,
					_neighbour(crossings, index, 1, key, b), epsilon, ray):
			continue
		out.append(index)
	return out


## The nearest crossing of the same body on one side, or the edge end past it.
static func _neighbour(crossings: Array, index: int, step: int, key: String,
		fallback: Vector3) -> Vector3:
	var scan := index + step
	while scan >= 0 and scan < crossings.size():
		var other: Dictionary = crossings[scan]
		if str(other.get("key", "")) == key:
			return other.get("point", fallback)
		scan += step
	return fallback
