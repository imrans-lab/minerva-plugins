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
## THE RULE. Overlap is SHARED MATERIAL, and four samples can only bound it
## when the shared region is a SLAB: the two bodies each bounded, at the
## crossing, by a face of their own, and those two faces antiparallel — the
## LANDING. Between two antiparallel planes the shared region is the slab
## between them, and a sample one tolerance along the landing normal on each
## side bounds its thickness: inside both means the slab is thicker than the
## tolerance, a genuine overlap; outside one of them on both sides means the
## slab, if any, is thinner than a tolerance, which is a contact. The
## tolerance is expected_contacts.gd's CONTACT_TOLERANCE_MM, the line this
## plugin already draws between a flush fit read through a tessellated mesh
## and a part in the wrong place — a hundredth of a millimetre, two orders of
## magnitude above the noise that produced the false report.
##
## WHAT A LANDING HAS TO BE. Three things, and TOUCHING needs all of them:
##
##   (a) STRICT. The two faces are antiparallel within half a degree
##       (LANDING_COS). Two faces meeting at any wider angle share a WEDGE,
##       not a slab, and a wedge two degrees wide is already a tolerance deep
##       thirty tolerances along — well inside a boss — while every quadrant
##       sample at the crossing lies in at most one body.
##   (b) INCIDENT. Both faces pass through the crossing point within the
##       tolerance. A face is found by a ray anywhere within REACH_TOLERANCES
##       of the crossing, so an antiparallel pair can be a ledge or a seat
##       three tolerances off the crossing: that pair bounds a slab the
##       crossing is not in, and says nothing about the material at it.
##   (c) HELD AT THE SAMPLES. On each across line the quadrant samples
##       straddle, the ray between the two samples meets each body either
##       nowhere or at a face lying in the landing plane within the
##       tolerance. A body absent along that line hides nothing; a body whose
##       boundary there is the landing plane is bounded by it. Both bodies so
##       bounded on both lines is the slab the four samples were placed for.
##
## Together the three bound any wedge inside the probe disc below the
## tolerance: two planes coincident at the crossing within a tolerance and
## antiparallel within half a degree are a tolerance apart at most a root two
## tolerances out, which is where the samples sit. A wedge wide enough to be
## deeper than that a little further along is deeper than the tolerance
## SOMEWHERE on the same pair of bodies, and there the edges of one cross the
## faces of the other in a crossing of their own, which this rule sees
## separately; the gate in interference_containment.gd is per PAIR, and one
## CROSSING verdict closes it for every crossing of that pair. A crossing with
## no landing is UNPROVEN and stays reported.
##
## WHY IT CANNOT CLEAR A REAL CRASH. Three answers, not two. A crossing whose
## samples hold shared material is CROSSING; one whose landing samples are
## verifiably in one body or the other, and never in both, is TOUCHING; and
## everything else is UNPROVEN, which the caller keeps. UNPROVEN covers the
## cases that would otherwise be cleared by ignorance rather than by evidence:
## no landing (the bodies do not rest on each other here — this is a plain
## penetration, or a wedge), a probe the parity walk could not read, and — the
## one that matters most — a body no sample could be found INSIDE. A
## four-micron shim pierced by a column offers no point a hundredth of a
## millimetre inside itself, so nothing here may clear it; that is the same
## rule the per-crossing probes use, and for the same reason.
##
## WHERE THE LANDING IS LOOKED FOR. The crossing lies on the crossed surface
## and on an edge of the other body, and the landing faces are usually
## NEIGHBOURS of those — a bore's mouth is a wall meeting a seat — so each
## body's faces are collected by rays straddling the crossing along the three
## axes, then again from half a tolerance behind each face those rays found:
## a ray fired exactly along a face's boundary edge may miss it, and the seat
## a wall meets is met by a ray a hair inside the wall.
##
## The rays and the parity probes are the caller's: this module owns the rule,
## not the space. `crossed_ray` and `other_ray` are `func(from: Vector3, to:
## Vector3) -> Dictionary`, empty when the segment hit nothing and otherwise
## carrying `position` and `normal`; the two parity probes are `func(point:
## Vector3) -> int` — 1 inside, 0 outside, -1 undecidable.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: scripts/interference_containment.gd, both cast directions.

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

## The four quadrants of the plane the landing normal and the across axis
## span, as multipliers of the two axes. The sample sits one tolerance along
## BOTH axes, so it is clear of the landing plane and of the wall that meets
## it rather than merely on the far side of one.
const _QUADRANTS: Array[Vector2] = [
	Vector2(1.0, 1.0), Vector2(1.0, -1.0),
	Vector2(-1.0, 1.0), Vector2(-1.0, -1.0),
]

## How far the search for each body's faces reaches, in tolerances. It bounds
## which faces can form the landing, not which crossings are cleared: what
## keeps a plain penetration is the landing requirement itself, and what keeps
## a body too thin to sample is the rule that every body must be witnessed.
const REACH_TOLERANCES: float = 4.0

## Two faces are a landing when their normals are antiparallel within this:
## cos 0.5°. Two flat faces read through physics arrive parallel to within
## float noise; anything wider is a wedge, and a two-degree wedge is a
## tolerance deep thirty tolerances from the crossing.
const LANDING_COS: float = 0.99996

## How far behind a found face the second round of rays starts, in
## tolerances — inside the body that face bounds, so a neighbouring face the
## first round only grazed along its edge is met square.
const INSET_TOLERANCES: float = 0.5

## Below this, a projected axis has no direction worth sampling along.
const _AXIS_MIN_LENGTH_SQUARED: float = 1.0e-6

## The three axes, both senses — the directions a body's faces are looked for
## along. Both senses because a face is only reached from one side.
const _PROBE_DIRECTIONS: Array[Vector3] = [
	Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD,
	Vector3.UP, Vector3.DOWN,
]


## Is this crossing a rim touch, a real overlap, or neither provable?
##
## `crossed_normal` is the normal of the surface the crossing landed on and
## `edge_direction` the unit direction of the edge that found it — both are
## candidates for the across axis once the landing normal is known.
## `crossed_ray` casts into the body whose surface was crossed and
## `inside_crossed` probes it; `other_ray` and `inside_other` do the same for
## the body the edge belongs to.
static func classify(
	point: Vector3,
	crossed_normal: Vector3,
	edge_direction: Vector3,
	crossed_ray: Callable,
	other_ray: Callable,
	inside_crossed: Callable,
	inside_other: Callable,
	tolerance_mm: float
) -> Verdict:
	if crossed_normal.length_squared() <= 0.0 or tolerance_mm <= 0.0:
		return Verdict.UNPROVEN
	var reach := tolerance_mm * REACH_TOLERANCES
	var crossed_faces: Array[Dictionary] = faces_near(point, crossed_ray,
		reach, tolerance_mm * INSET_TOLERANCES)
	var other_faces: Array[Dictionary] = faces_near(point, other_ray,
		reach, tolerance_mm * INSET_TOLERANCES)
	# Backface hits can carry either normal sign. Try every nearby plane;
	# sampling one arbitrary wall can put all samples on the actual seat.
	for landing: Vector3 in landing_normals(crossed_faces, other_faces, point, tolerance_mm):
		var across: Variant = across_axis(landing, _across_candidates(
			[crossed_normal], crossed_faces + other_faces, edge_direction))
		if not (across is Vector3):
			continue
		if not _planes_held(point, landing, across, crossed_ray, other_ray, tolerance_mm):
			continue
		var verdict := _sampled(point, landing, across, inside_crossed, inside_other,
			tolerance_mm)
		if verdict != Verdict.UNPROVEN:
			return verdict
	return Verdict.UNPROVEN


## The four quadrant samples, read. CROSSING on the first sample inside both
## bodies; TOUCHING only when every sample could be read and each body was
## witnessed by at least one of them; UNPROVEN otherwise.
static func _sampled(point: Vector3, normal: Vector3, across: Vector3,
		inside_crossed: Callable, inside_other: Callable,
		tolerance_mm: float) -> Verdict:
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


## Candidate landing normals whose planes both pass through the crossing.
## Backface hits may reverse normals, so opposing normals alone are not a
## proof of a seat. classify verifies the boundaries along the sample lines
## before interpreting parity. Parallel candidates share that same check.
static func landing_normals(crossed_faces: Array[Dictionary],
		other_faces: Array[Dictionary], point: Vector3,
		tolerance_mm: float) -> Array[Vector3]:
	var found: Array[Vector3] = []
	for here in crossed_faces:
		var here_normal: Vector3 = here["normal"]
		if plane_offset(here, point) > tolerance_mm:
			continue
		for there in other_faces:
			if here_normal.dot(there["normal"] as Vector3) > -LANDING_COS:
				continue
			if plane_offset(there, point) > tolerance_mm:
				continue
			var duplicate := false
			for held: Vector3 in found:
				if absf(held.dot(here_normal)) > LANDING_COS:
					duplicate = true
					break
			if not duplicate:
				found.append(here_normal)
			break
	return found


## How far `point` lies off the plane of a face, along its normal.
static func plane_offset(face: Dictionary, point: Vector3) -> float:
	return absf((point - (face["point"] as Vector3)).dot(face["normal"] as Vector3))


## Is the landing plane each body's boundary at the samples? Along each of the
## two across lines the samples straddle, the ray from the crossed side to
## the other side is cast into the other body, and the ray back is cast into
## the crossed body: each meets nothing — that body is absent there — or a
## face lying in the landing plane within the tolerance. A hit off the plane,
## or on a face at another angle, is a boundary the slab argument does not
## cover; a hit with no readable normal is a ray that could not be read.
static func _planes_held(point: Vector3, normal: Vector3, across: Vector3,
		crossed_ray: Callable, other_ray: Callable, tolerance_mm: float) -> bool:
	for side: float in [1.0, -1.0]:
		var crossed_side := point - normal * tolerance_mm \
			+ across * (side * tolerance_mm)
		var other_side := point + normal * tolerance_mm \
			+ across * (side * tolerance_mm)
		if not _in_landing_plane(other_ray.call(crossed_side, other_side),
				point, normal, tolerance_mm):
			return false
		if not _in_landing_plane(crossed_ray.call(other_side, crossed_side),
				point, normal, tolerance_mm):
			return false
	return true


## Does a hit lie in the landing plane? No hit is the body being absent along
## the ray, which the plane bounds trivially.
static func _in_landing_plane(hit: Dictionary, point: Vector3, normal: Vector3,
		tolerance_mm: float) -> bool:
	if hit.is_empty():
		return true
	var hit_normal: Vector3 = hit.get("normal", Vector3.ZERO)
	if hit_normal.length_squared() <= 0.0:
		return false
	if absf(hit_normal.normalized().dot(normal)) < LANDING_COS:
		return false
	var position: Vector3 = hit.get("position", point)
	return absf((position - point).dot(normal)) <= tolerance_mm


## The second sampling axis: the first of `directions` with a component
## perpendicular to `normal`. Null when none has one.
static func across_axis(normal: Vector3, directions: Array[Vector3]) -> Variant:
	for direction in directions:
		var across := direction - normal * normal.dot(direction)
		if across.length_squared() > _AXIS_MIN_LENGTH_SQUARED:
			return across.normalized()
	return null


## What the across axis is taken from, in order: the stated normals, then
## every face found around the crossing, then the edge that found it. A face
## is a wall the samples must straddle; the edge, which may run ALONG such a
## wall, is the last resort for two bodies that meet with no wall at all.
static func _across_candidates(normals: Array[Vector3], faces: Array,
		edge_direction: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = normals.duplicate()
	for face in faces:
		out.append((face as Dictionary)["normal"] as Vector3)
	out.append(edge_direction)
	return out


## Every face of one body within `reach` of `point`, as {normal, distance,
## point}: the hit's own position rides along so the face's PLANE, not only
## its direction, can be tested against the crossing.
## Rays straddle the point along each axis rather than starting on it — a
## ray fired from a point already on the surface it is looking for reports
## whatever it meets next — and a second round is fired from `inset` behind
## each face the first round found, which is where a neighbouring face that
## the first round only grazed along its edge is met square.
static func faces_near(point: Vector3, ray: Callable, reach: float,
		inset: float) -> Array[Dictionary]:
	var faces: Array[Dictionary] = _faces_from(point, point, ray, reach)
	var first_round := faces.duplicate()
	for face in first_round:
		var origin := point - (face["normal"] as Vector3) * inset
		for found in _faces_from(origin, point, ray, reach):
			if not _has_face(faces, found):
				faces.append(found)
	return faces


## One round of six straddling rays from `origin`, with each hit's distance
## measured from `point`. Hits past `reach` are not faces of this crossing.
static func _faces_from(origin: Vector3, point: Vector3, ray: Callable,
		reach: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for direction in _PROBE_DIRECTIONS:
		var offset: Vector3 = direction * reach
		var hit: Dictionary = ray.call(origin + offset, origin - offset)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit.get("normal", Vector3.ZERO)
		if normal.length_squared() <= 0.0:
			continue
		var away := point.distance_to(hit.get("position", point) as Vector3)
		if away > reach:
			continue
		var face := {
			"normal": normal.normalized(),
			"distance": away,
			"point": hit.get("position", point) as Vector3,
		}
		if not _has_face(out, face):
			out.append(face)
	return out


## Is a face of this normal already listed? Two hits on one plane from two
## rays are one face; the distance and the point are kept from whichever ray
## found it first — the plane is the same from either.
static func _has_face(faces: Array[Dictionary], face: Dictionary) -> bool:
	for held in faces:
		if (held["normal"] as Vector3).dot(face["normal"] as Vector3) > LANDING_COS:
			return true
	return false
