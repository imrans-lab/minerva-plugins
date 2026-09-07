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
## THE FACE CAN HAVE A HOLE IN IT. A boss is bored for the screw it carries,
## and the bore's mouth is in the very face that seats: the contact face is an
## annulus, and a chord over it crosses the mouth, where the plane goes on but
## the face does not. Nothing is within the touch epsilon of a sample hanging
## over an open bore, so the run is not lying in a face — and it is not
## travelling through material either. Overlap needs VOLUME, so the run is
## sorted three ways rather than two: it lies IN a face, it goes through
## MATERIAL, or it crosses a VOID of that body — the mouth of a bore, or the
## air beside a rim. A crossing survives only when a run beside it goes
## through material. That keeps every piercing edge (its far run is material
## even though its near run is air) and drops the bored flush fit, whose runs
## are face and void and nothing else.
##
## The rays and the parity probe are the caller's: this module owns the rule,
## not the space. The ray Callable is
## `func(from: Vector3, to: Vector3) -> Variant` returning the first hit
## position along the segment, or null; the parity Callable is
## `func(point: Vector3) -> int` — 1 inside the body, 0 outside, -1
## undecidable, and undecidable counts as material because a probe nobody
## could read is not evidence that a part is clear.
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


## What one run is. Callers pass the RUN between two crossings, not the parent
## edge.
enum Run {
	## Every sample lies in a face of the body: the edge was travelling in the
	## surface. A chord short enough that its own sagitta is inside the
	## epsilon reads this way against the curved wall it clipped — a graze, on
	## a three millimetre boss under a twentieth of a millimetre long, whose
	## depth would have been smaller still.
	CONTACT,
	## No sample is in the body's material and not every one is on a face: the
	## run is over the mouth of a bore in the contact face, or in the air
	## beside a rim. Neither is overlap.
	VOID,
	## A sample is inside the body and clear of every face of it. This is the
	## only run that makes its crossings interference.
	MATERIAL,
}

## How many off-face samples of one run are asked whether they are in the
## body's material. Between two consecutive crossings of the SAME body the
## segment is wholly inside it or wholly outside — a change of side is itself
## a crossing — so the most central sample already answers; the second is
## there for a run whose middle grazes a facet. The probe is the expensive
## question (a parity walk, or a gauge), so it is not asked of every sample.
const MATERIAL_PROBES: int = 2


## Sort the segment a→b. A degenerate segment is MATERIAL — not because
## anything runs through material in no distance, but because two crossings
## that coincide bound no contact either, and the crossing's other run is
## what should decide it.
##
## `probe_mm` is the size of the caller's parity probe. A run no longer than
## that has nowhere to put the probe: an edge piercing a plate thinner than
## the probe is bounded by two crossings whose run reads "not in a face" and
## then "not inside" — the probe simply does not fit — and clearing it would
## drop a genuine piercing. A run that thin is undecidable, and undecidable
## counts as material here exactly as it does per crossing.
static func classify_run(a: Vector3, b: Vector3, epsilon: float,
		ray: Callable, inside: Callable, probe_mm: float = 0.0) -> Run:
	var span := a.distance_to(b)
	if span <= epsilon:
		return Run.MATERIAL
	var in_face := true
	var probes := 0
	for fraction in SAMPLE_FRACTIONS:
		if not in_face and probes >= MATERIAL_PROBES:
			break
		var point := a.lerp(b, fraction)
		if surface_at(point, epsilon, ray):
			continue
		in_face = false
		probes += 1
		if span <= probe_mm or int(inside.call(point)) != 0:
			return Run.MATERIAL
	return Run.CONTACT if in_face else Run.VOID


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
## `crossings` are the SURFACE HITS of the ONE edge a→b, in order along it,
## each {point: Vector3, key: String, bound_only: bool}; `key` names the body
## crossed, because a crossing of one body bounds no run through another.
## `ray_for` is func(key: String) -> Callable, the ray against that one body.
##
## A hit marked `bound_only` is one the caller's per-crossing tests already
## threw away — a hit the edge did not straddle, or one with no material
## behind it. It is never classified and never returned, but it still BOUNDS
## the runs of its neighbours, because it is a place the edge met the surface
## whatever the caller decided about it. Leaving those out is what made a
## flush contact report: when the partner hit at the far side of a rim was
## discarded, the surviving one measured its run to the far END of the
## triangle edge instead, out through the air past the rim, and no gate can
## clear a run that is mostly air.
##
## Every crossing bounds two runs along its edge — back to the previous
## crossing of the same body, or to the edge's own start, and forward to the
## next one, or to its end. A crossing is a CONTACT when either of those runs
## lies in a face of the body: the edge was travelling in the surface and left
## it through the rim of that face, which is the signature of a designed flush
## fit and not of overlap. That end has to be counted, because a rim chord is
## usually bounded by a crossing at one end and the triangle's own vertex,
## sitting a float-noise depth inside the body, at the other — a gate that
## only looked between two crossings would clear almost none of them.
##
## And it survives only when the OTHER run goes through material. A run that
## crosses a void of the body — the open mouth of a bore in the seating face,
## or the air outside a rim — is no more an overlap than a run in the face is,
## and a bored flush fit has nothing else: chord over the annulus, chord over
## the mouth, and no material anywhere along either. A piercing edge is
## untouched by that: its near run is air but its far run is material, and one
## material run is enough.
##
## `inside_for` is func(key: String) -> Callable, the parity probe against
## that one body, alongside `ray_for`'s ray. `probe_mm` is how big that probe
## is: a run too short to place it in is undecidable, not clear — see
## classify_run.
##
## Returns the surviving indices, in order.
static func penetrating_indices(a: Vector3, b: Vector3, crossings: Array,
		epsilon: float, ray_for: Callable, inside_for: Callable,
		probe_mm: float = 0.0) -> PackedInt32Array:
	var out := PackedInt32Array()
	for index in range(crossings.size()):
		var crossing: Dictionary = crossings[index]
		if bool(crossing.get("bound_only", false)):
			continue
		var key := str(crossing.get("key", ""))
		var point: Vector3 = crossing.get("point", Vector3.ZERO)
		var ray: Callable = ray_for.call(key)
		var inside: Callable = inside_for.call(key)
		var before := classify_run(_neighbour(crossings, index, -1, key, a),
			point, epsilon, ray, inside, probe_mm)
		var after := classify_run(point,
			_neighbour(crossings, index, 1, key, b), epsilon, ray, inside,
			probe_mm)
		if before == Run.CONTACT or after == Run.CONTACT:
			continue
		if before != Run.MATERIAL and after != Run.MATERIAL:
			continue
		out.append(index)
	return out


## The nearest hit on the same body on one side, or the edge end past it.
## Discarded hits count here: the run ends where the edge met the surface.
static func _neighbour(crossings: Array, index: int, step: int, key: String,
		fallback: Vector3) -> Vector3:
	var scan := index + step
	while scan >= 0 and scan < crossings.size():
		var other: Dictionary = crossings[scan]
		if str(other.get("key", "")) == key:
			return other.get("point", fallback)
		scan += step
	return fallback
