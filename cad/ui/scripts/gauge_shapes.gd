extends RefCounted
## gauge_shapes.gd — the gauge frame and the shapes a measurement may ask for.
## Split out of mesh_gauge.gd so that file stays about physics queries; nothing
## here touches the physics server or holds any state.
##
## There are no Shape3D objects here any more. A gauge is tested by rays cast
## from its axis to its own surface, not by a shape query, so a gauge is only
## ever a kind and a size — see constraint 4 in mesh_gauge.gd for the
## measurement that forced that. The PATTERNS those rays are cast in —
## stations along the axis, radials around it, the cap rings and the 26-way
## star — live here for the same reason: they are the gauge's geometry, and
## two modules now cast them.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/gauge_shapes.gd")

## The gauge shapes a verb may name. For "cylinder", size.x is the diameter and
## size.y the length; for "sphere", size.x is the diameter; a "box" is its own
## size in the gauge frame.
const KINDS: Array = ["cylinder", "box", "sphere"]

## Rays cast around a gauge's axis, and stations along it. A ray leaving the
## axis stops at the gauge's own surface, so 24 x 5 rays sample the wall of a
## pin. The radius they measure is the hole's INRADIUS to within the sagitta of
## one facet — 0.003 mm on a 5 mm bore cut in 64 facets.
const GAUGE_AZIMUTHS: int = 24
const GAUGE_STATIONS: int = 5
## Rings of cap rays: a gauge also fouls on what its ENDS run into, so each end
## is sampled from the axis and from two rings inside the gauge radius.
const CAP_RING_FRACTIONS: Array = [0.0, 0.55, 0.95]


static func is_supported(kind: String) -> bool:
	return kind in KINDS


## Basis whose Z is `axis`: the frame every gauge shape is built in.
static func basis_for_axis(axis: Vector3) -> Basis:
	var z := unit(axis)
	var reference := Vector3.UP if absf(z.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var x := reference.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


## How far a box reaches along a direction — the projection of its size onto it.
static func extent_along(bounds: AABB, direction: Vector3) -> float:
	return absf(bounds.size.x * direction.x) \
		+ absf(bounds.size.y * direction.y) \
		+ absf(bounds.size.z * direction.z)


## A Variant coerced to a unit vector, falling back to +Z-up rather than to a
## zero vector: every caller here needs an axis, and a zero axis is a crash.
static func unit(value: Variant) -> Vector3:
	var v: Vector3 = value if value is Vector3 else Vector3.UP
	return v.normalized() if v.length_squared() > 0.0 else Vector3.UP


## Points along the gauge axis the wall rays are cast from.
static func stations(centre: Vector3, axis: Vector3, length: float) -> Array:
	if length <= 0.0:
		return [centre]
	var half := length * 0.5
	var out: Array = []
	for k in range(GAUGE_STATIONS):
		var t := -half + length * float(k) / float(GAUGE_STATIONS - 1)
		out.append(centre + axis * t)
	return out


## Unit directions around the axis, in the gauge's own frame.
static func radials(axis: Vector3) -> Array:
	var basis: Basis = basis_for_axis(axis)
	var out: Array = []
	for i in range(GAUGE_AZIMUTHS):
		var angle := TAU * float(i) / float(GAUGE_AZIMUTHS)
		out.append((basis.x * cos(angle) + basis.y * sin(angle)).normalized())
	return out



## Where the cap rays start: on the axis and on two rings inside the gauge
## radius, so a floor that only covers part of the pin is still found.
static func cap_origins(centre: Vector3, axis: Vector3, radius: float) -> Array:
	var out: Array = [centre]
	var radials := radials(axis)
	for fraction in CAP_RING_FRACTIONS:
		if float(fraction) <= 0.0:
			continue
		var index := 0
		while index < radials.size():
			out.append(centre + (radials[index] as Vector3) * radius * float(fraction))
			# Every third azimuth: a ring is about catching a partial floor,
			# not about measuring it.
			index += 3
	return out


## A fixed 26-direction star: the six axes, the twelve edges and the eight
## corners of a cube. Enough to find any wall a compact gauge touches.
static func sphere_directions() -> Array:
	var out: Array = []
	for x in [-1.0, 0.0, 1.0]:
		for y in [-1.0, 0.0, 1.0]:
			for z in [-1.0, 0.0, 1.0]:
				var direction := Vector3(x, y, z)
				if direction.length_squared() > 0.0:
					out.append(direction.normalized())
	return out
