extends RefCounted
## fastener_seat.gd — where the head bears, and what a bore is for.
##
## Two questions the screw check asks over and over, split out of
## fastener_checks.gd when that file crossed two thousand lines. Nothing about
## either answer changed: this script is the check's base class, so one object
## still carries the whole check exactly as the panel and panel_tools hold it.
##
## WHERE THE HEAD BEARS. A ring of rays through the annulus between the shank
## and the head radius — never the axis, which falls down the clearance hole —
## finds the first surface the head meets and how much of the ring lands on it.
## The walk that steps a ray through a stack of surfaces is here too, because
## the seat rays and the path rays are the same walk.
##
## WHAT A BORE IS FOR. Thread, clearance or undersize, decided from the bore's
## diameter against the screw's and the ISO 273 medium clearance hole. The
## table is never interpolated: a wrong allowance passes a joint that will not
## go together.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: fastener_checks.gd extends this script.

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

## A bore this multiple of the screw's own diameter or wider is a hole the
## screw passes THROUGH, where no clearance hole is tabulated or stated for
## it. Where ISO 273 has the screw, the table's medium hole is the threshold
## instead (3.4 mm for an M3) — and either way a bore wider than the screw's
## own major diameter is clearance, because the thread has nothing to cut:
## a 3.0 mm pilot is thread, a 3.2 mm bore and a 3.82 mm printed clearance
## bore are not. A clearance bore is never an engagement, however deep it is,
## so which of two coaxial bores gets paired with a hole is not a question a
## distance can answer.
const CLEARANCE_FIT_D: float = 1.1
## A bore narrower than this multiple of the screw's diameter cannot take the
## screw at all: a vent, a moulding pin, a texture. It is paired last, behind
## every bore that could actually receive the screw.
const UNDERSIZE_FIT_D: float = 0.5
## The order the three kinds of bore are paired in. Lower is preferred.
const FIT_RANK: Dictionary = {"thread": 0, "clearance": 1, "undersize": 2}

## No two adjacent rays of a ring may be further apart than this along the
## circle. It is the whole guarantee the path check makes: an obstruction
## narrower than this can pass between two rays unseen. At an M3 shank radius
## of 1.5 mm it works out at 19 rays.
const RING_SPACING_MM: float = 0.5
const MIN_RING_RAYS: int = 8
## How far off the seat plane a surface may sit and still be the seat, along
## the screw axis. Independent of the ring's LATERAL pitch, which says how
## finely the circumference is sampled and nothing about depth: a floor half
## a millimetre below the seat is a head floating half a millimetre, not a
## seat measured coarsely. The seat plane is placed from the hole record's
## centre and thickness, which the hole verb fits to a hundredth, and a
## reference facet meets the ray exactly, so this absorbs that fit and a
## chamfer's rounding and nothing wider.
const SEAT_TOLERANCE_MM: float = 0.05
const MAX_RING_RAYS: int = 128

## How far outside the scene a path ray starts, in millimetres. Constraint 2 of
## geometry_checks: a ray must begin outside every body.
const OUTSIDE_MARGIN_MM: float = 5.0

## How far past a hit the next cast starts when walking a ray through a stack.
const CROSSING_ADVANCE_MM: float = 0.0002

## Surfaces one path ray may cross before it gives up.
const MAX_CROSSINGS_PER_RAY: int = 32


## Ray casts spent by the running check.
var _casts: int = 0
## The widest gap the running check actually left between two adjacent rays
## along a ring, millimetres. It is RING_SPACING_MM or less everywhere except
## on a ring wide enough to hit MAX_RING_RAYS, and the reply reports the
## measured number rather than the nominal one so the miss bound is never a
## claim the fan did not keep.
var _widest_arc_mm: float = 0.0


# ---------------------------------------------------------------------------
# What a bore is for
# ---------------------------------------------------------------------------

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


## What one bore is for, from its diameter and the screw's.
##
##   thread     the screw bites here — a pilot, a moulded boss, a tapped hole.
##              This is the only kind of bore an engagement can be measured in,
##              and it has to be NARROWER than the screw's major diameter: a
##              bore the major diameter already fits through has no material
##              for the thread to cut, however far it is from the ISO 273
##              clearance hole (a 3.2 mm bore takes an M3 with 0.1 mm to
##              spare on either side and holds nothing).
##   clearance  the screw passes through: wider than its major diameter, or at
##              or above the clearance hole that diameter calls for.
##   undersize  narrower than the screw can enter at all.
func _fit_of(bore_dia: float, screw_dia: float, clearance_dia: float) -> String:
	if screw_dia <= 0.0:
		return "thread"
	if bore_dia < screw_dia * UNDERSIZE_FIT_D:
		return "undersize"
	if bore_dia >= clearance_dia or bore_dia > screw_dia + SIZE_EPSILON_MM:
		return "clearance"
	return "thread"


## The diameter at which a bore stops being material the screw threads into.
## ISO 273 medium where the table has this screw, `clearance_hole_dia_mm` when
## the caller states one, and CLEARANCE_FIT_D x d otherwise.
func _clearance_bore_dia(screw_dia: float, args: Dictionary) -> float:
	var stated := float(args.get("clearance_hole_dia_mm", 0.0))
	if stated > 0.0:
		return stated
	for size in ISO_273_MEDIUM:
		if absf(float(size) - screw_dia) <= SIZE_EPSILON_MM:
			return float(ISO_273_MEDIUM[size])
	return screw_dia * CLEARANCE_FIT_D


# ---------------------------------------------------------------------------
# Where the head bears
# ---------------------------------------------------------------------------

## Where the head lands on the SOLID: the axial position of the first face of
## the evaluated solid the head's bearing ring meets travelling in, or null
## when it meets none.
##
## The ring is sampled between the shank radius and the head radius, the same
## annulus the head actually bears on, so a ray does not simply fall down the
## clearance hole the shank passes through. The NEAREST hit over the ring is
## the seat — that is where the head stops — which is why this looks at the
## solid alone: a reference part standing in front of the seat is something in
## the head's way, and the head fan reports it as one. A counterbore in a tray
## floor and a lid's outer skin are both answered by this, with no argument
## beyond `seat: solid`.
func _solid_seat(
	solid_state: PhysicsDirectSpaceState3D,
	checks: Object,
	hole_centre: Vector3,
	direction: Vector3,
	head_radius: float,
	shank_radius: float,
	reach: float
) -> Variant:
	if checks == null or not is_instance_valid(checks) or solid_state == null:
		return null
	# Outside every body on the head's side. The seat is not known yet, so the
	# origin cannot be measured from it: the scene's own reach is what puts
	# this ray in front of everything.
	var origin := hole_centre - direction * (OUTSIDE_MARGIN_MM + reach)
	var travel := (OUTSIDE_MARGIN_MM + reach) * 2.0
	var nearest: Variant = null
	# From 1: _ring_points puts the AXIS first, and the axis travels down the
	# clearance hole the shank passes through — it is never where the head
	# bears, and a floor far down that hole is not a seat.
	var ring := _ring_points(direction, (head_radius + shank_radius) * 0.5)
	for index in range(1, ring.size()):
		var start: Vector3 = origin + (ring[index] as Vector3)
		var hit: Dictionary = checks.call("solid_ray", solid_state, start,
			start + direction * travel)
		_casts += 1
		if hit.is_empty():
			continue
		var t: float = ((hit["position"] as Vector3) - hole_centre).dot(direction)
		if nearest == null or t < float(nearest):
			nearest = t
	return nearest


## How much of the seat ring actually lands on material at the seat plane, as
## {landed, rays, radius_mm, gap_mm}. A head hanging half over the edge of its
## boss is "clear" — nothing is in its way — and still badly seated, and only
## this number says so. `gap_mm` is the signed axial distance from the seat
## plane to the first surface a ring ray met, at its worst over the ring:
## positive is a surface BELOW the seat (the head floats by that much),
## negative is one above it (the head fan's obstruction), null when no ray met
## anything at all.
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
	solid_state: PhysicsDirectSpaceState3D,
	checks: Object,
	origin: Vector3,
	direction: Vector3,
	head_radius: float,
	shank_radius: float,
	seat_t: float,
	datum: Vector3,
	mask: int,
	reference_scope: String,
	include_solid: bool
) -> Dictionary:
	var radius := (head_radius + shank_radius) * 0.5
	var ring := _ring_points(direction, radius)
	# A hit counts as the seat only within SEAT_TOLERANCE_MM of the plane
	# along the axis — a depth question, answered with a depth tolerance.
	# Anything further is a different surface, and how far it sits is
	# reported rather than absorbed.
	var landed := 0
	var rays := 0
	var worst_gap: Variant = null
	# From 1: rays[0] is the axis, which travels down the clearance hole.
	for index in range(1, ring.size()):
		rays += 1
		var start: Vector3 = origin + (ring[index] as Vector3)
		var finish: Vector3 = start + direction * ((datum - origin).length() * 2.0 + head_radius)
		# The body the seat was read off is the body its coverage is measured
		# on. A seat on the reference is graded against the reference alone —
		# a shell feature standing over it is the head fan's obstruction, not a
		# surface the head sits on — and a seat on the solid the same way.
		var hit := {}
		if include_solid:
			hit = checks.call("solid_ray", solid_state, start, finish) \
				if checks != null and is_instance_valid(checks) else {}
			_casts += 1
		else:
			hit = _reference_ray(gauge, state, start, finish, mask, reference_scope)
		if hit.is_empty():
			continue
		var t: float = (hit["position"] as Vector3 - datum).dot(direction)
		var gap := t - seat_t
		if worst_gap == null or gap > float(worst_gap):
			worst_gap = gap
		if absf(gap) <= SEAT_TOLERANCE_MM:
			landed += 1
	return {"landed": landed, "rays": rays, "radius_mm": radius, "gap_mm": worst_gap}


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
				"normal": reference_hit.get("normal", Vector3.ZERO),
				"node": str(reference_hit.get("node", "")),
				"reference": str(reference_hit.get("reference", "")),
			}
		if not solid_hit.is_empty():
			var point: Vector3 = solid_hit["position"]
			if chosen.is_empty() or cursor.distance_to(point) < cursor.distance_to(next):
				next = point
				chosen = {"point": point, "node": "<solid>", "reference": "",
					"normal": solid_hit.get("normal", Vector3.ZERO), "solid": true}
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
