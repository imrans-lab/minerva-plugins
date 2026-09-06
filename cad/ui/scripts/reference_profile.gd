extends RefCounted
## reference_profile.gd — how TALL is the reference geometry over this patch of
## the board?
##
## The question a layout asks over and over: "if I put the lid at z = 24, what
## am I going to hit?" — and, per part, "how much of that height is this one?".
## Before this it was answered from the per-node bounding boxes, which is wrong
## in the case that matters: a joystick node is a 10 mm housing with a 32 mm
## stick standing out of it, and its box says the whole footprint is 42 mm
## tall. A skin height read off boxes is therefore too tall almost everywhere,
## and the enclosure grows to fit geometry that is not there.
##
## SO IT READS THE TRIANGLES. For a world-XY rectangle, each triangle is
## clipped to that rectangle (Sutherland-Hodgman against the four half-planes)
## and the extreme z is taken over the clipped polygon's corners. That is
## EXACT, not sampled: a triangle is planar, z is linear over it, and a linear
## function on a convex polygon takes its extremes at a corner. No ray, no
## grid pitch, nothing to fall between samples — and no physics, because there
## is nothing here to intersect: the mesh vertices are already the answer.
##
## Triangles whose own XY bounds miss the rectangle are rejected before any
## clipping, which is what keeps a 130k-triangle board affordable.
##
## Z IS UP, in the posed CAD world; a reference's own frame is not used for
## the region, because a region is drawn across the whole assembly and every
## part in it has a different frame. The point that realises each extreme is
## reported in both frames anyway, the way every other measurement is.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: ui/panel_tools.gd (minerva_cad_reference_profile).

## Rows the per-node profile carries before it is cut short. A board is 45
## nodes and an assembly a few hundred; past this the caller wanted a summary,
## not a listing.
const MAX_NODE_ROWS: int = 200


## The z profile of the references over one world-XY rectangle.
##
## `records` are the panel's reference records; `region` is the rectangle in
## world millimetres. Returns
##
##   {found, max_z_mm, min_z_mm, at_max_mm: {world, local}, at_min_mm: {...},
##    reference, node, triangles_considered, triangles_inside,
##    nodes: [{reference, node, max_z_mm, min_z_mm, at_max_mm, at_min_mm,
##             triangles_inside}]}
##
## `found` false means no reference triangle lies over that rectangle at all —
## which is an answer ("nothing is under there"), not a failure.
static func profile(records: Array, region: Rect2, reference_scope: String,
		node_scope: String, per_node: bool) -> Dictionary:
	var best_max := -INF
	var best_min := INF
	var at_max := Vector3.ZERO
	var at_min := Vector3.ZERO
	var owner_reference := ""
	var owner_node := ""
	var considered := 0
	var inside := 0
	var rows: Array = []
	for record_entry in records:
		var record: Dictionary = record_entry
		var reference_name := str(record.get("name", ""))
		if not reference_scope.is_empty() and reference_name != reference_scope:
			continue
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		for part_entry in record.get("parts", []):
			var part: Dictionary = part_entry
			var mesh: Mesh = part.get("mesh", null)
			if mesh == null:
				continue
			var node_path := str(part.get("node_path", part.get("node", "")))
			if not _node_matches(node_path, node_scope):
				continue
			var xform: Transform3D = pose \
				* (part.get("transform", Transform3D.IDENTITY) as Transform3D)
			# A node whose whole world box misses the rectangle carries no
			# triangle that can be in it.
			var box: AABB = xform * mesh.get_aabb()
			if not _box_overlaps(box, region):
				continue
			var one := _node_profile(mesh, xform, region)
			considered += int(one["triangles_considered"])
			if not bool(one["found"]):
				continue
			inside += int(one["triangles_inside"])
			if float(one["max_z_mm"]) > best_max:
				best_max = float(one["max_z_mm"])
				at_max = one["at_max"]
				owner_reference = reference_name
				owner_node = node_path
			if float(one["min_z_mm"]) < best_min:
				best_min = float(one["min_z_mm"])
				at_min = one["at_min"]
			if per_node and rows.size() < MAX_NODE_ROWS:
				rows.append({
					"reference": reference_name,
					"node": node_path,
					"max_z_mm": float(one["max_z_mm"]),
					"min_z_mm": float(one["min_z_mm"]),
					"at_max_mm": _framed(one["at_max"], pose),
					"at_min_mm": _framed(one["at_min"], pose),
					"triangles_inside": int(one["triangles_inside"]),
				})
	var out := {
		"found": best_max > -INF,
		"triangles_considered": considered,
		"triangles_inside": inside,
	}
	if bool(out["found"]):
		out["max_z_mm"] = best_max
		out["min_z_mm"] = best_min
		out["reference"] = owner_reference
		out["node"] = owner_node
		out["at_max_mm"] = _framed(at_max, _pose_of(records, owner_reference))
		out["at_min_mm"] = _framed(at_min, _pose_of(records, owner_reference))
	if per_node:
		rows.sort_custom(func(x, y): return float((x as Dictionary)["max_z_mm"]) \
			> float((y as Dictionary)["max_z_mm"]))
		out["nodes"] = rows
		out["nodes_truncated"] = rows.size() >= MAX_NODE_ROWS
	return out


## The extreme z of ONE node's triangles over the rectangle, in world
## millimetres, with the point that realises each.
static func _node_profile(mesh: Mesh, xform: Transform3D,
		region: Rect2) -> Dictionary:
	var max_z := -INF
	var min_z := INF
	var at_max := Vector3.ZERO
	var at_min := Vector3.ZERO
	var considered := 0
	var inside := 0
	for surface in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := PackedInt32Array()
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
			indices = arrays[Mesh.ARRAY_INDEX]
		else:
			# An unindexed surface is a triangle soup: the vertices in order.
			indices.resize(vertices.size())
			for i in range(vertices.size()):
				indices[i] = i
		var triangle := PackedVector3Array()
		triangle.resize(3)
		for base in range(0, indices.size() - 2, 3):
			considered += 1
			triangle[0] = xform * vertices[indices[base]]
			triangle[1] = xform * vertices[indices[base + 1]]
			triangle[2] = xform * vertices[indices[base + 2]]
			if not _triangle_may_touch(triangle, region):
				continue
			var clipped := _clip(triangle, region)
			if clipped.is_empty():
				continue
			inside += 1
			for point in clipped:
				var world: Vector3 = point
				if world.z > max_z:
					max_z = world.z
					at_max = world
				if world.z < min_z:
					min_z = world.z
					at_min = world
	return {
		"found": max_z > -INF,
		"max_z_mm": max_z,
		"min_z_mm": min_z,
		"at_max": at_max,
		"at_min": at_min,
		"triangles_considered": considered,
		"triangles_inside": inside,
	}


## Clip a polygon to the rectangle in XY, carrying z along the edges it cuts
## (Sutherland-Hodgman). The z of a new corner is interpolated along the edge
## that produced it, which lies in the triangle's own plane, so every corner
## the result carries is a point ON the triangle.
static func _clip(polygon: PackedVector3Array, region: Rect2) -> PackedVector3Array:
	var out := polygon
	# Each half-plane as (axis, keep_at_least, value): x >= min, x <= max, ...
	var planes := [
		[0, true, region.position.x], [0, false, region.end.x],
		[1, true, region.position.y], [1, false, region.end.y],
	]
	for plane_entry in planes:
		if out.is_empty():
			return out
		var plane: Array = plane_entry
		var axis: int = plane[0]
		var lower: bool = plane[1]
		var value: float = plane[2]
		var next := PackedVector3Array()
		for index in range(out.size()):
			var current: Vector3 = out[index]
			var previous: Vector3 = out[(index + out.size() - 1) % out.size()]
			var current_in := _inside(current, axis, lower, value)
			var previous_in := _inside(previous, axis, lower, value)
			if current_in != previous_in:
				next.append(_cross_at(previous, current, axis, value))
			if current_in:
				next.append(current)
		out = next
	return out


static func _inside(point: Vector3, axis: int, lower: bool, value: float) -> bool:
	var coordinate := point.x if axis == 0 else point.y
	return coordinate >= value if lower else coordinate <= value


## Where the segment crosses the plane, with z interpolated along it.
static func _cross_at(from_point: Vector3, to_point: Vector3, axis: int,
		value: float) -> Vector3:
	var start := from_point.x if axis == 0 else from_point.y
	var end := to_point.x if axis == 0 else to_point.y
	var span := end - start
	var t := 0.0 if is_zero_approx(span) else (value - start) / span
	return from_point.lerp(to_point, clampf(t, 0.0, 1.0))


## Can this triangle have any part inside the rectangle? Its own XY bounds
## against the region — the cheap rejection that makes a big board affordable.
static func _triangle_may_touch(triangle: PackedVector3Array,
		region: Rect2) -> bool:
	var min_x: float = minf(triangle[0].x, minf(triangle[1].x, triangle[2].x))
	if min_x > region.end.x:
		return false
	var max_x: float = maxf(triangle[0].x, maxf(triangle[1].x, triangle[2].x))
	if max_x < region.position.x:
		return false
	var min_y: float = minf(triangle[0].y, minf(triangle[1].y, triangle[2].y))
	if min_y > region.end.y:
		return false
	var max_y: float = maxf(triangle[0].y, maxf(triangle[1].y, triangle[2].y))
	return max_y >= region.position.y


static func _box_overlaps(box: AABB, region: Rect2) -> bool:
	return box.position.x <= region.end.x and box.end.x >= region.position.x \
		and box.position.y <= region.end.y and box.end.y >= region.position.y


## Same node= rule as every other measurement verb: the path from the file
## root, or a bare leaf name.
static func _node_matches(node_path: String, filter: String) -> bool:
	if filter.is_empty():
		return true
	return node_path == filter or node_path.get_file() == filter


static func _pose_of(records: Array, reference_name: String) -> Transform3D:
	for entry in records:
		var record: Dictionary = entry
		if str(record.get("name", "")) == reference_name:
			return record.get("pose", Transform3D.IDENTITY)
	return Transform3D.IDENTITY


## A world point with the reference's own frame beside it — the pose taken
## back off, which is the number that goes into the DSL.
static func _framed(world: Vector3, pose: Transform3D) -> Dictionary:
	var local: Vector3 = pose.affine_inverse() * world
	return {
		"world": [world.x, world.y, world.z],
		"local": [local.x, local.y, local.z],
	}
