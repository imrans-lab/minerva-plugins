extends RefCounted
## TWO BODIES THAT MEET AT A RIM ARE TOUCHING, NOT CROSSING.
##
## THE CASE THIS EXISTS FOR. Every screwed post in an enclosure lands on a
## plate that has a hole under it: the boss's flat top is coplanar with the
## board's underside, the boss is bored for the screw, and the board is
## drilled for the same screw. The two rims — the bore's mouth and the hole's
## — are concentric circles lying IN the shared plane, and each is a place
## where one body's cylindrical wall meets the other body's flat face
## SQUARELY. That crossing straddles the wall it hit, there is material a
## probe step behind it, and the run beside it lies in no face (it hangs over
## the open bore), so every per-crossing test and the contact-run rule in
## contact_runs.gd agree it is a penetration. It is not: the two bodies lie on
## opposite sides of the plane and share no volume at all.
##
## WHY THE TOUCH EPSILON CANNOT SETTLE IT. The tests upstream call a contact
## anything within TOUCH_EPSILON_MM (1e-4 mm) of a surface. That is finer than
## the numbers being compared: the physics hit positions are single precision,
## which on a hundred-millimetre part is already a ten-thousandth of a
## millimetre, and a reference mesh authored in metres has its own float noise
## multiplied by a thousand on the way in. So the shared plane arrives a few
## tenths of a micron out of true, the crossing lands on the wrong side of it,
## and the check reports a boss that is exactly where it belongs.
##
## THE RULE. Overlap is SHARED MATERIAL, so that is what is asked for. Around
## the crossing, in the plane spanned by the two surfaces that meet there, sit
## four sample points — one per quadrant — each one contact tolerance clear of
## BOTH surfaces. If any of them is inside both bodies the crossing is a real
## overlap; if none of them is, the bodies meet on a surface and no more. The
## tolerance is expected_contacts.gd's CONTACT_TOLERANCE_MM, the line this
## plugin already draws between a flush fit read through a tessellated mesh
## and a part in the wrong place — a hundredth of a millimetre, two orders of
## magnitude above the noise that produced the false report.
##
## WHY IT CANNOT CLEAR A REAL CRASH. Three answers, not two. A crossing whose
## quadrants hold shared material is CROSSING; one whose quadrants are
## verifiably in one body or the other, and never in both, is TOUCHING; and
## everything else is UNPROVEN, which the caller keeps. UNPROVEN covers the
## cases that would otherwise be cleared by ignorance rather than by evidence:
## no second surface within reach (the bodies do not meet here — this is a
## plain penetration), a probe the parity walk could not read, and — the one
## that matters most — a body no sample could be found INSIDE. A four-micron
## shim pierced by a column offers no point a hundredth of a millimetre inside
## itself, so nothing here may clear it; that is the same rule the per-crossing
## probes use, and for the same reason.
##
## The rays and the parity probes are the caller's: this module owns the rule,
## not the space. `other_ray` is `func(from: Vector3, to: Vector3) ->
## Dictionary`, empty when the segment hit nothing and otherwise carrying
## `position` and `normal`; the two parity probes are `func(point: Vector3) ->
## int` — 1 inside, 0 outside, -1 undecidable.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: scripts/geometry_checks.gd, both cast directions.

## What one crossing turned out to be.
enum Verdict {
	## The two bodies share material near this crossing: a real overlap.
	CROSSING,
	## They meet on a surface here and share no material: a designed contact.
	TOUCHING,
	## Neither could be shown. The caller keeps the crossing — an answer this
	## rule could not reach is not evidence that a part is clear.
	UNPROVEN,
}

## The four quadrants of the plane the two surfaces span, as multipliers of
## the two axes. A rim's overlap wedge, if there is one, lies in exactly one
## of them; the sample sits one tolerance along BOTH axes, so it is clear of
## both surfaces rather than merely on the far side of one.
const _QUADRANTS: Array[Vector2] = [
	Vector2(1.0, 1.0), Vector2(1.0, -1.0),
	Vector2(-1.0, 1.0), Vector2(-1.0, -1.0),
]

## How far the search for the other body's surface reaches, in tolerances. It
## bounds which surface the second axis is taken FROM, not which crossings are
## cleared: on the reference leg the crossing sits on an edge of the other
## body, so a probe of it nearly always hits something. What keeps a plain
## penetration is the shared-material question itself, and what keeps a body
## too thin to sample is the rule below that every body must be witnessed.
const REACH_TOLERANCES: float = 4.0

## Above this, two normals are the same normal and span no plane. Ten degrees
## of tilt is still a plane worth sampling; a degree is float noise on a
## coplanar pair.
const PARALLEL_COS: float = 0.995

## The three axes, both senses — the directions the other body's surface is
## looked for along. Both senses because a face is only reached from one side.
const _PROBE_DIRECTIONS: Array[Vector3] = [
	Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD,
	Vector3.UP, Vector3.DOWN,
]


## Is this crossing a rim touch, a real overlap, or neither provable?
##
## `crossed_normal` is the normal of the surface the crossing landed on and
## `edge_direction` the unit direction of the edge that found it — the second
## axis when the two surfaces turn out to be parallel and span nothing.
## `inside_crossed` probes the body whose surface was crossed, `inside_other`
## the body the edge belongs to, and `other_ray` casts into that same other
## body.
static func classify(
	point: Vector3,
	crossed_normal: Vector3,
	edge_direction: Vector3,
	other_ray: Callable,
	inside_crossed: Callable,
	inside_other: Callable,
	tolerance_mm: float
) -> Verdict:
	if crossed_normal.length_squared() <= 0.0 or tolerance_mm <= 0.0:
		return Verdict.UNPROVEN
	var normal := crossed_normal.normalized()
	var facing: Variant = facing_normal(point, other_ray,
		tolerance_mm * REACH_TOLERANCES)
	if not (facing is Vector3):
		# Nothing of the other body meets this crossing: the bodies are not
		# resting on each other here, so this is a plain penetration and the
		# rule has nothing to say about it.
		return Verdict.UNPROVEN
	# ORTHOGONALIZED ALWAYS, not only when the two normals are nearly parallel.
	# The sample is meant to sit one tolerance clear of BOTH surfaces, and it
	# only does when the two axes are perpendicular: at any other angle the
	# offset along one axis eats into the clearance from the other, and a
	# drafted boss at ten degrees would be sampled a fraction of the tolerance
	# from its own wall — inside the float noise the rule exists to beat.
	var toward: Vector3 = facing
	var across := toward - normal * normal.dot(toward)
	if across.length_squared() <= 0.0 \
			or absf(normal.dot(toward)) > PARALLEL_COS:
		# Two parallel faces: their normals span no plane, so the edge that
		# found the crossing supplies the second axis instead.
		across = edge_direction - normal * normal.dot(edge_direction)
	if across.length_squared() <= 0.0:
		return Verdict.UNPROVEN
	across = across.normalized()
	# A body no sample lands inside is a body thinner than the probe, and
	# nothing here may clear it.
	var seen_crossed := false
	var seen_other := false
	for quadrant in _QUADRANTS:
		var sample := point + normal * (quadrant.x * tolerance_mm) \
			+ across * (quadrant.y * tolerance_mm)
		var here := int(inside_crossed.call(sample))
		if here < 0:
			return Verdict.UNPROVEN
		var there := int(inside_other.call(sample))
		if there < 0:
			return Verdict.UNPROVEN
		if here == 1 and there == 1:
			return Verdict.CROSSING
		seen_crossed = seen_crossed or here == 1
		seen_other = seen_other or there == 1
	if not seen_crossed or not seen_other:
		return Verdict.UNPROVEN
	return Verdict.TOUCHING


## The normal of the nearest surface `other_ray` finds within `reach` of
## `point`, or null. Each ray STRADDLES the point rather than starting on it:
## a ray fired from a point already on the surface it is looking for reports
## whatever it meets next, while one arriving from outside registers the face
## being measured to.
static func facing_normal(point: Vector3, other_ray: Callable,
		reach: float) -> Variant:
	var nearest := reach
	var found: Variant = null
	for direction in _PROBE_DIRECTIONS:
		var offset: Vector3 = direction * reach
		var hit: Dictionary = other_ray.call(point + offset, point - offset)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit.get("normal", Vector3.ZERO)
		if normal.length_squared() <= 0.0:
			continue
		var away := point.distance_to(hit.get("position", point) as Vector3)
		if away > nearest:
			continue
		nearest = away
		found = normal.normalized()
	return found
