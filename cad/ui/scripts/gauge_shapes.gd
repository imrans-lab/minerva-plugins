extends RefCounted
## gauge_shapes.gd — the shapes a measurement is made with, and the frame they
## are built in. Split out of mesh_gauge.gd so that file stays about physics
## queries; nothing here touches the physics server or holds any state.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/gauge_shapes.gd")

## Sides of the gauge prism. Higher is a better circle and a slower query; at
## 48 the prism is within 0.2% of the cylinder it stands for.
const PRISM_SIDES: int = 48


## The gauge prism for a pin of `radius`. The polygon's INRADIUS is the gauge
## radius, so the prism contains the cylinder it stands for and a prism that
## fits proves the pin fits — the error is one-sided and under 0.2% at 48
## sides. A prism built the other way round would over-report every hole.
static func prism(radius: float, length: float) -> ConvexPolygonShape3D:
	var circumradius := radius / cos(PI / float(PRISM_SIDES))
	var points := PackedVector3Array()
	var half := length * 0.5
	for i in range(PRISM_SIDES):
		var angle := TAU * float(i) / float(PRISM_SIDES)
		var x := cos(angle) * circumradius
		var y := sin(angle) * circumradius
		points.append(Vector3(x, y, -half))
		points.append(Vector3(x, y, half))
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	return shape


## The shape a gauge verb asked for, or null when the name is not one of them.
## For "cylinder", size.x is the diameter and size.y the length.
static func shape_for(kind: String, size: Vector3) -> Shape3D:
	match kind:
		"cylinder":
			return prism(maxf(0.001, size.x * 0.5), maxf(0.001, size.y))
		"box":
			var box := BoxShape3D.new()
			box.size = size
			return box
		"sphere":
			var sphere := SphereShape3D.new()
			sphere.radius = maxf(0.001, size.x * 0.5)
			return sphere
	return null


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
