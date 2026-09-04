## mesh_features.gd — the PROPOSE half of measuring a foreign mesh.
##
## A reference mesh arrives as a triangle soup with no feature information at
## all: no holes, no cylinders, no faces — only triangles that a CAD kernel
## once knew the meaning of. This module recovers candidates from the geometry
## alone, with no seed point and no preferred axis:
##
##   WELD      coincident positions are merged on a quantised grid first.
##             glTF splits a mesh by material, and every split duplicates the
##             vertices along the seam; without welding, every seam looks like
##             a boundary and no region can cross one.
##   SEGMENT   faces are grouped by normal continuity — two triangles sharing
##             an edge belong together when the angle between their normals is
##             below the region angle. Done with union-find over the shared
##             edges rather than a per-face adjacency table: one pass, no
##             per-face allocation, which is what keeps a 130k-triangle board
##             inside a couple of seconds of GDScript.
##   FIT       each region is fitted with a plane, and failing that a cylinder
##             whose axis comes out of the region's own normals (they all lie
##             perpendicular to it), with a residual reported for both.
##
## WHAT A CANDIDATE IS NOT. A fit is a hypothesis. A tessellated hole is a
## prism, and a least-squares circle through the prism's vertices returns the
## CIRCUMSCRIBED radius with a residual of nearly zero — it is a perfect fit to
## the wrong number. The pin that actually goes through the hole is the
## INSCRIBED circle, radius * cos(pi / facets), and only a physical gauge
## (mesh_gauge.gd) can confirm it. Both numbers are reported, always, with the
## facet count that separates them; nothing here silently rounds a 24-gon into
## a circle.
##
## Everything is in the reference's own local frame, in millimetres — the frame
## reference_meshes.gd bakes at load. The caller poses it.
extends RefCounted

## Position quantisation used to weld coincident vertices, in grid steps per
## millimetre. Matches reference_meshes.gd's outline welding so a mesh that
## outlines cleanly also segments cleanly.
const WELD_PER_MM: float = 1000.0

## Maximum angle between the normals of two triangles sharing an edge for them
## to be considered the same surface. It has to exceed the facet angle of the
## coarsest tessellation worth recovering (a 24-gon hole steps 15 degrees, a
## 64-gon 5.6) while staying below the angles that mean something (a 30-degree
## chamfer, a 90-degree wall). A mesh coarser than about 16 sides per circle
## needs this raised, which is why every verb takes it as an argument.
const DEFAULT_REGION_ANGLE_DEG: float = 25.0

## Regions smaller than this are noise: a single stray triangle fits any
## primitive perfectly and means nothing.
const MIN_REGION_FACES: int = 3

## Bins used to measure how much of a full turn a cylindrical region covers.
## A hole wall covers all of it; a filleted corner covers a quarter.
const ANGULAR_BINS: int = 36

## A region is called planar when its vertices sit this close to the fitted
## plane. Absolute, because CAD tessellation error is absolute.
const PLANE_RESIDUAL_MM: float = 0.005

## A cylinder fit is reported when the vertices sit within this fraction of the
## fitted radius (or PLANE_RESIDUAL_MM, whichever is larger) of the circle.
const CYLINDER_RESIDUAL_FRACTION: float = 0.02


## Cached analysis of one file. Keyed by whatever identity the caller uses for
## the file's bytes (reference_meshes.gd hands over path + content stamp), so a
## pose edit never re-segments and a file edit always does.
var _cache: Dictionary = {}
## How many times a mesh has actually been segmented. A pose change must not
## move this number.
var _analysis_count: int = 0


# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

func get_analysis_count() -> int:
	return _analysis_count


func clear_cache() -> void:
	_cache.clear()


## Candidates for one loaded file, computed once. `parts` is what
## reference_meshes.gd holds: [{mesh: Mesh, transform: Transform3D, node: String}]
## already converted to CAD-local millimetres.
func features_for(
	key: String,
	parts: Array,
	angle_deg: float = DEFAULT_REGION_ANGLE_DEG
) -> Dictionary:
	var cache_key := "%s|%.2f" % [key, angle_deg]
	if _cache.has(cache_key):
		return _cache[cache_key]
	_analysis_count += 1
	var result: Dictionary = analyze(parts, angle_deg)
	_cache[cache_key] = result
	return result


## Segment and fit every part. Returns
## {candidates: Array, triangles: int, regions: int, elapsed_ms: int}.
##
## Cost is linear in the triangle count: one dictionary insert per triangle
## corner to weld, one per triangle edge to pair, one union-find step per
## shared edge, then a pass over each region's vertices to fit. There is no
## nested loop over faces anywhere, and no per-face allocation. The constant is
## a GDScript dictionary operation — a few hundred nanoseconds — so a 130k
## triangle board is roughly a million dictionary operations.
static func analyze(parts: Array, angle_deg: float = DEFAULT_REGION_ANGLE_DEG) -> Dictionary:
	var started := Time.get_ticks_msec()
	var candidates: Array = []
	var triangles := 0
	var regions := 0
	for entry in parts:
		if not (entry is Dictionary):
			continue
		var part: Dictionary = entry
		var mesh: Mesh = part.get("mesh", null)
		if mesh == null:
			continue
		var soup := soup_from_mesh(mesh, part.get("transform", Transform3D.IDENTITY))
		var positions: PackedVector3Array = soup["positions"]
		var indices: PackedInt32Array = soup["indices"]
		triangles += int(indices.size() / 3)
		var found := analyze_soup(positions, indices, str(part.get("node", "")), angle_deg)
		regions += int(found["regions"])
		candidates.append_array(found["candidates"] as Array)
	return {
		"candidates": candidates,
		"triangles": triangles,
		"regions": regions,
		"elapsed_ms": Time.get_ticks_msec() - started,
	}


## Flatten every triangle surface of a mesh into one indexed soup, transformed
## by `to_local`. Surfaces that are not triangles (the outline line meshes, for
## one) are skipped.
static func soup_from_mesh(mesh: Mesh, to_local: Transform3D) -> Dictionary:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	for surface in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var base := positions.size()
		for v in verts:
			positions.append(to_local * v)
		var raw_index: Variant = arrays[Mesh.ARRAY_INDEX]
		if raw_index is PackedInt32Array and (raw_index as PackedInt32Array).size() >= 3:
			for i in (raw_index as PackedInt32Array):
				indices.append(base + i)
		else:
			for i in range(verts.size()):
				indices.append(base + i)
	return {"positions": positions, "indices": indices}


## Segment one soup and fit its regions. Returns {candidates, regions}.
static func analyze_soup(
	positions: PackedVector3Array,
	indices: PackedInt32Array,
	node_name: String,
	angle_deg: float = DEFAULT_REGION_ANGLE_DEG
) -> Dictionary:
	var empty := {"candidates": [], "regions": 0}
	if positions.is_empty() or indices.size() < 3:
		return empty

	var welded := _weld(positions, indices)
	var points: PackedVector3Array = welded["points"]
	var corners: PackedInt32Array = welded["corners"]
	var face_count := int(corners.size() / 3)
	if face_count == 0:
		return empty

	var normals := PackedVector3Array()
	normals.resize(face_count)
	var areas := PackedFloat32Array()
	areas.resize(face_count)
	for f in range(face_count):
		var a := points[corners[f * 3]]
		var b := points[corners[f * 3 + 1]]
		var c := points[corners[f * 3 + 2]]
		var cross := (b - a).cross(c - a)
		var length := cross.length()
		areas[f] = length * 0.5
		normals[f] = (cross / length) if length > 0.000001 else Vector3.ZERO

	var labels := _grow_regions(corners, normals, face_count, angle_deg)
	var groups := _group_faces(labels, face_count)

	var candidates: Array = []
	for root in groups.keys():
		var faces: PackedInt32Array = groups[root]
		if faces.size() < MIN_REGION_FACES:
			continue
		var candidate := _fit_region(points, corners, normals, areas, faces, node_name)
		if not candidate.is_empty():
			candidates.append(candidate)
	return {"candidates": candidates, "regions": groups.size()}


## Convenience for the callers that only want holes: concave cylinders whose
## fitted diameter is inside a range and whose wall goes most of the way round.
static func concave_cylinders(
	candidates: Array,
	min_dia_mm: float,
	max_dia_mm: float,
	min_coverage: float = 0.6
) -> Array:
	var out: Array = []
	for entry in candidates:
		var candidate: Dictionary = entry
		if str(candidate.get("kind", "")) != "cylinder":
			continue
		if str(candidate.get("form", "")) != "concave":
			continue
		var dia := float(candidate.get("dia_mm", 0.0))
		if dia < min_dia_mm or dia > max_dia_mm:
			continue
		if float(candidate.get("coverage", 0.0)) < min_coverage:
			continue
		out.append(candidate)
	return out


# ---------------------------------------------------------------------------
# Weld and segment
# ---------------------------------------------------------------------------

## Merge positions onto a quantised grid. Returns {points, corners}: the welded
## point list and three welded ids per triangle, with degenerate triangles
## (two corners welded together) dropped.
static func _weld(positions: PackedVector3Array, indices: PackedInt32Array) -> Dictionary:
	var ids := {}
	var points := PackedVector3Array()
	var corners := PackedInt32Array()
	var triangle_count := int(indices.size() / 3)
	for t in range(triangle_count):
		var i0 := indices[t * 3]
		var i1 := indices[t * 3 + 1]
		var i2 := indices[t * 3 + 2]
		if i0 >= positions.size() or i1 >= positions.size() or i2 >= positions.size():
			continue
		var a := _weld_one(ids, points, positions[i0])
		var b := _weld_one(ids, points, positions[i1])
		var c := _weld_one(ids, points, positions[i2])
		if a == b or b == c or c == a:
			continue
		corners.append(a)
		corners.append(b)
		corners.append(c)
	return {"points": points, "corners": corners}


static func _weld_one(ids: Dictionary, points: PackedVector3Array, point: Vector3) -> int:
	var key := Vector3i(
		roundi(point.x * WELD_PER_MM),
		roundi(point.y * WELD_PER_MM),
		roundi(point.z * WELD_PER_MM)
	)
	var existing: Variant = ids.get(key, null)
	if existing != null:
		return int(existing)
	var id := points.size()
	points.append(point)
	ids[key] = id
	return id


## Union-find over the shared edges: two faces sharing an edge join the same
## region when their normals agree to within `angle_deg`. Returns the
## representative face id for every face.
##
## Union-find rather than a breadth-first walk because it needs no adjacency
## structure at all — one dictionary entry per edge, discarded as it is
## matched — and the result does not depend on which face happens to be
## visited first.
static func _grow_regions(
	corners: PackedInt32Array,
	normals: PackedVector3Array,
	face_count: int,
	angle_deg: float
) -> PackedInt32Array:
	var parent := PackedInt32Array()
	parent.resize(face_count)
	for f in range(face_count):
		parent[f] = f

	var cosine_limit := cos(deg_to_rad(clampf(angle_deg, 0.1, 89.0)))
	var edge_face := {}
	for f in range(face_count):
		var a := corners[f * 3]
		var b := corners[f * 3 + 1]
		var c := corners[f * 3 + 2]
		_pair_edge(edge_face, parent, normals, cosine_limit, a, b, f)
		_pair_edge(edge_face, parent, normals, cosine_limit, b, c, f)
		_pair_edge(edge_face, parent, normals, cosine_limit, c, a, f)

	var labels := PackedInt32Array()
	labels.resize(face_count)
	for f in range(face_count):
		labels[f] = _find_root(parent, f)
	return labels


static func _pair_edge(
	edge_face: Dictionary,
	parent: PackedInt32Array,
	normals: PackedVector3Array,
	cosine_limit: float,
	a: int,
	b: int,
	face: int
) -> void:
	var key := Vector2i(min(a, b), max(a, b))
	var other: Variant = edge_face.get(key, null)
	if other == null:
		edge_face[key] = face
		return
	# An edge is shared by exactly two faces in a closed mesh. Keeping the
	# first owner means a non-manifold edge pairs its extra faces against the
	# same partner rather than being dropped.
	var partner := int(other)
	if normals[face].dot(normals[partner]) >= cosine_limit:
		_union(parent, face, partner)


static func _find_root(parent: PackedInt32Array, face: int) -> int:
	var root := face
	while parent[root] != root:
		root = parent[root]
	# Path compression, so a long chain is walked once rather than once per query.
	var walk := face
	while parent[walk] != root:
		var next := parent[walk]
		parent[walk] = root
		walk = next
	return root


static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find_root(parent, a)
	var rb := _find_root(parent, b)
	if ra != rb:
		parent[rb] = ra


static func _group_faces(labels: PackedInt32Array, face_count: int) -> Dictionary:
	var groups := {}
	for f in range(face_count):
		var root := labels[f]
		if not groups.has(root):
			groups[root] = PackedInt32Array()
		var bucket: PackedInt32Array = groups[root]
		bucket.append(f)
		groups[root] = bucket
	return groups


# ---------------------------------------------------------------------------
# Fitting
# ---------------------------------------------------------------------------

## Fit one region: a plane if it is flat enough, otherwise a cylinder. An empty
## dictionary means neither fitted well enough to be worth proposing.
static func _fit_region(
	points: PackedVector3Array,
	corners: PackedInt32Array,
	normals: PackedVector3Array,
	areas: PackedFloat32Array,
	faces: PackedInt32Array,
	node_name: String
) -> Dictionary:
	var vertex_ids := {}
	var area := 0.0
	var normal_sum := Vector3.ZERO
	for f in faces:
		vertex_ids[corners[f * 3]] = true
		vertex_ids[corners[f * 3 + 1]] = true
		vertex_ids[corners[f * 3 + 2]] = true
		area += areas[f]
		normal_sum += normals[f] * areas[f]

	var region_points := PackedVector3Array()
	for id in vertex_ids.keys():
		region_points.append(points[int(id)])
	if region_points.size() < 3:
		return {}

	var centroid := _centroid(region_points)
	var plane := _fit_plane(region_points, centroid)
	var plane_residual := float(plane["residual"])
	if plane_residual <= PLANE_RESIDUAL_MM:
		var plane_normal: Vector3 = plane["normal"]
		if plane_normal.dot(normal_sum) < 0.0:
			plane_normal = -plane_normal
		return {
			"kind": "plane",
			"form": "flat",
			"node": node_name,
			"center": centroid,
			"axis": plane_normal,
			"radius_mm": 0.0,
			"dia_mm": 0.0,
			"inscribed_dia_mm": 0.0,
			"extent_mm": 0.0,
			"half_extent_mm": 0.0,
			"residual_mm": plane_residual,
			"facets": 0,
			"coverage": 0.0,
			"face_count": faces.size(),
			"area_mm2": area,
		}

	var cylinder := _fit_cylinder(region_points, corners, normals, faces, points, centroid)
	if cylinder.is_empty():
		return {}
	cylinder["node"] = node_name
	cylinder["face_count"] = faces.size()
	cylinder["area_mm2"] = area
	return cylinder


static func _centroid(region_points: PackedVector3Array) -> Vector3:
	var sum := Vector3.ZERO
	for p in region_points:
		sum += p
	return sum / float(region_points.size())


## Least-squares plane through the region: the normal is the eigenvector of the
## point covariance with the smallest eigenvalue — the direction the points
## spread least in. Residual is the RMS distance to the plane.
static func _fit_plane(region_points: PackedVector3Array, centroid: Vector3) -> Dictionary:
	var covariance := _covariance(region_points, centroid)
	var normal := _smallest_eigenvector(covariance)
	var sum_squared := 0.0
	for p in region_points:
		var d := (p - centroid).dot(normal)
		sum_squared += d * d
	return {
		"normal": normal,
		"residual": sqrt(sum_squared / float(region_points.size())),
	}


## Fit a cylinder without a seed. Every face normal of a cylinder is
## perpendicular to its axis, so the axis is the direction the NORMALS spread
## least in — the smallest eigenvector of their covariance about the origin.
## With the axis known the region flattens to a 2-D circle fit.
static func _fit_cylinder(
	region_points: PackedVector3Array,
	corners: PackedInt32Array,
	normals: PackedVector3Array,
	faces: PackedInt32Array,
	points: PackedVector3Array,
	centroid: Vector3
) -> Dictionary:
	var normal_cloud := PackedVector3Array()
	for f in faces:
		if normals[f] != Vector3.ZERO:
			normal_cloud.append(normals[f])
	if normal_cloud.size() < 3:
		return {}
	var axis := _smallest_eigenvector(_covariance(normal_cloud, Vector3.ZERO))
	if axis.length_squared() < 0.5:
		return {}
	axis = axis.normalized()

	var u := axis.cross(Vector3.UP)
	if u.length_squared() < 0.001:
		u = axis.cross(Vector3.RIGHT)
	u = u.normalized()
	var v := axis.cross(u).normalized()

	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	var axis_min := INF
	var axis_max := -INF
	for p in region_points:
		var d := p - centroid
		xs.append(d.dot(u))
		ys.append(d.dot(v))
		var t := d.dot(axis)
		axis_min = min(axis_min, t)
		axis_max = max(axis_max, t)

	var circle := _fit_circle(xs, ys)
	if circle.is_empty():
		return {}
	var radius := float(circle["radius"])
	if radius <= 0.0001:
		return {}
	var residual := float(circle["residual"])
	if residual > maxf(PLANE_RESIDUAL_MM, radius * CYLINDER_RESIDUAL_FRACTION):
		return {}
	# A nearly-flat region fits an enormous circle with a tiny residual — the
	# curvature is real but it is the curvature of the fitting error. A circle
	# far larger than the patch it was fitted to is not a cylinder.
	var span := AABB(region_points[0], Vector3.ZERO)
	for p in region_points:
		span = span.expand(p)
	if radius > span.size.length() * 2.0:
		return {}

	var center := centroid \
		+ u * float(circle["cx"]) \
		+ v * float(circle["cy"]) \
		+ axis * ((axis_min + axis_max) * 0.5)

	# Concave or convex: take each face's own normal against the direction
	# pointing away from the axis at that face. Normals that point back at the
	# axis are looking into a hole.
	var inward := 0
	var outward := 0
	for f in faces:
		var face_center := (
			points[corners[f * 3]] + points[corners[f * 3 + 1]] + points[corners[f * 3 + 2]]
		) / 3.0
		var offset := face_center - center
		var radial := offset - axis * offset.dot(axis)
		if radial.length_squared() < 0.000001:
			continue
		if normals[f].dot(radial.normalized()) < 0.0:
			inward += 1
		else:
			outward += 1
	if inward == 0 and outward == 0:
		return {}

	var coverage := _angular_coverage(xs, ys, float(circle["cx"]), float(circle["cy"]))
	# A tessellated circle's facet count: the region's faces are quads split
	# into two triangles, so the number of distinct facets around the wall is
	# half the face count when the wall is one ring, and the angular coverage
	# scales it back to a full turn.
	var facets := _facet_estimate(xs, ys, float(circle["cx"]), float(circle["cy"]))
	var inscribed := radius * 2.0
	if facets >= 3:
		inscribed = radius * 2.0 * cos(PI / float(facets))

	return {
		"kind": "cylinder",
		"form": "concave" if inward >= outward else "convex",
		"center": center,
		"axis": axis,
		"radius_mm": radius,
		"dia_mm": radius * 2.0,
		"inscribed_dia_mm": inscribed,
		"extent_mm": axis_max - axis_min,
		"half_extent_mm": (axis_max - axis_min) * 0.5,
		"residual_mm": residual,
		"facets": facets,
		"coverage": coverage,
	}


## Algebraic (Kasa) circle fit: minimising the residual of
## x^2 + y^2 = 2*cx*x + 2*cy*y + c is linear in (cx, cy, c), so it is one 3x3
## solve with no iteration and no starting guess. The reported residual is then
## the true geometric RMS of |distance - radius|, not the algebraic one — the
## algebraic residual flatters large circles.
static func _fit_circle(xs: PackedFloat32Array, ys: PackedFloat32Array) -> Dictionary:
	var n := xs.size()
	if n < 3:
		return {}
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var syy := 0.0
	var sxy := 0.0
	var sz := 0.0
	var sxz := 0.0
	var syz := 0.0
	for i in range(n):
		var x := float(xs[i])
		var y := float(ys[i])
		var z := x * x + y * y
		sx += x
		sy += y
		sxx += x * x
		syy += y * y
		sxy += x * y
		sz += z
		sxz += x * z
		syz += y * z
	var count := float(n)
	var solution := _solve3(
		[
			[2.0 * sxx, 2.0 * sxy, sx],
			[2.0 * sxy, 2.0 * syy, sy],
			[2.0 * sx, 2.0 * sy, count],
		],
		[sxz, syz, sz]
	)
	if solution.is_empty():
		return {}
	var cx := float(solution[0])
	var cy := float(solution[1])
	var c := float(solution[2])
	var radius_squared := c + cx * cx + cy * cy
	if radius_squared <= 0.0:
		return {}
	var radius := sqrt(radius_squared)

	var sum_squared := 0.0
	for i in range(n):
		var dx := float(xs[i]) - cx
		var dy := float(ys[i]) - cy
		var d := sqrt(dx * dx + dy * dy) - radius
		sum_squared += d * d
	return {
		"cx": cx,
		"cy": cy,
		"radius": radius,
		"residual": sqrt(sum_squared / count),
	}


## Fraction of a full turn the region's points occupy around the fitted centre.
## A through-hole wall is 1.0; a rounded outside corner is about 0.25.
static func _angular_coverage(
	xs: PackedFloat32Array,
	ys: PackedFloat32Array,
	cx: float,
	cy: float
) -> float:
	var bins := {}
	for i in range(xs.size()):
		var angle := atan2(float(ys[i]) - cy, float(xs[i]) - cx)
		var bin := int(floor((angle + PI) / TAU * float(ANGULAR_BINS)))
		bins[clampi(bin, 0, ANGULAR_BINS - 1)] = true
	return float(bins.size()) / float(ANGULAR_BINS)


## Distinct facet count around the wall: the number of distinct angles the
## welded points occupy. A tessellated hole has exactly one point column per
## facet corner, so the count of distinct angles is the polygon's side count.
static func _facet_estimate(
	xs: PackedFloat32Array,
	ys: PackedFloat32Array,
	cx: float,
	cy: float
) -> int:
	var seen := {}
	for i in range(xs.size()):
		var angle := atan2(float(ys[i]) - cy, float(xs[i]) - cx)
		# Quantised to a thousandth of a turn: finer than any tessellation
		# worth counting, coarse enough to merge the two ends of a wall column.
		seen[roundi((angle + PI) / TAU * 1000.0) % 1000] = true
	return seen.size()


# ---------------------------------------------------------------------------
# Small dense linear algebra — 3x3 only, written out so it can be read
# ---------------------------------------------------------------------------

## Covariance of a point cloud about `center`, as a symmetric 3x3.
static func _covariance(cloud: PackedVector3Array, center: Vector3) -> Array:
	var m := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
	for p in cloud:
		var d := p - center
		var components := [d.x, d.y, d.z]
		for r in range(3):
			for c in range(3):
				m[r][c] += float(components[r]) * float(components[c])
	var count := float(maxi(1, cloud.size()))
	for r in range(3):
		for c in range(3):
			m[r][c] = float(m[r][c]) / count
	return m


## Eigenvector of a symmetric 3x3 with the smallest eigenvalue, by cyclic
## Jacobi rotation. Iterative but bounded, and it does not care how degenerate
## the matrix is — which the closed-form root-of-the-cubic version does.
static func _smallest_eigenvector(matrix: Array) -> Vector3:
	var a := [
		[float(matrix[0][0]), float(matrix[0][1]), float(matrix[0][2])],
		[float(matrix[1][0]), float(matrix[1][1]), float(matrix[1][2])],
		[float(matrix[2][0]), float(matrix[2][1]), float(matrix[2][2])],
	]
	var v := [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
	for _sweep in range(12):
		var off := absf(float(a[0][1])) + absf(float(a[0][2])) + absf(float(a[1][2]))
		if off < 1e-12:
			break
		for p in range(2):
			for q in range(p + 1, 3):
				var apq := float(a[p][q])
				if absf(apq) < 1e-15:
					continue
				var theta := (float(a[q][q]) - float(a[p][p])) / (2.0 * apq)
				var t := signf(theta) / (absf(theta) + sqrt(theta * theta + 1.0))
				if theta == 0.0:
					t = 1.0
				var cosine := 1.0 / sqrt(t * t + 1.0)
				var sine := t * cosine
				for k in range(3):
					var akp := float(a[k][p])
					var akq := float(a[k][q])
					a[k][p] = cosine * akp - sine * akq
					a[k][q] = sine * akp + cosine * akq
				for k in range(3):
					var apk := float(a[p][k])
					var aqk := float(a[q][k])
					a[p][k] = cosine * apk - sine * aqk
					a[q][k] = sine * apk + cosine * aqk
				for k in range(3):
					var vkp := float(v[k][p])
					var vkq := float(v[k][q])
					v[k][p] = cosine * vkp - sine * vkq
					v[k][q] = sine * vkp + cosine * vkq
	var best := 0
	for i in range(1, 3):
		if float(a[i][i]) < float(a[best][best]):
			best = i
	var out := Vector3(float(v[0][best]), float(v[1][best]), float(v[2][best]))
	return out.normalized() if out.length_squared() > 0.0 else Vector3.UP


## Solve a 3x3 system by Gaussian elimination with partial pivoting. Returns an
## empty array when the matrix is singular — a caller must treat that as "no
## fit", never as zeros.
static func _solve3(matrix: Array, rhs: Array) -> Array:
	var m := [
		[float(matrix[0][0]), float(matrix[0][1]), float(matrix[0][2]), float(rhs[0])],
		[float(matrix[1][0]), float(matrix[1][1]), float(matrix[1][2]), float(rhs[1])],
		[float(matrix[2][0]), float(matrix[2][1]), float(matrix[2][2]), float(rhs[2])],
	]
	for col in range(3):
		var pivot := col
		for row in range(col + 1, 3):
			if absf(float(m[row][col])) > absf(float(m[pivot][col])):
				pivot = row
		if absf(float(m[pivot][col])) < 1e-12:
			return []
		if pivot != col:
			var swap: Array = m[pivot]
			m[pivot] = m[col]
			m[col] = swap
		var lead := float(m[col][col])
		for k in range(col, 4):
			m[col][k] = float(m[col][k]) / lead
		for row in range(3):
			if row == col:
				continue
			var factor := float(m[row][col])
			if factor == 0.0:
				continue
			for k in range(col, 4):
				m[row][k] = float(m[row][k]) - factor * float(m[col][k])
	return [float(m[0][3]), float(m[1][3]), float(m[2][3])]
