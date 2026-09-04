extends RefCounted
## gauge_shapes.gd — the gauge frame and the shapes a measurement may ask for.
## Split out of mesh_gauge.gd so that file stays about physics queries; nothing
## here touches the physics server or holds any state.
##
## There are no Shape3D objects here any more. A gauge is tested by rays cast
## from its axis to its own surface, not by a shape query, so a gauge is only
## ever a kind and a size — see constraint 4 in mesh_gauge.gd for the
## measurement that forced that.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/gauge_shapes.gd")

## The gauge shapes a verb may name. For "cylinder", size.x is the diameter and
## size.y the length; for "sphere", size.x is the diameter; a "box" is its own
## size in the gauge frame.
const KINDS: Array = ["cylinder", "box", "sphere"]


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
