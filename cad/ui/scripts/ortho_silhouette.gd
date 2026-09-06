extends RefCounted
## The outline a pane showing a direction draws, and what it costs to draw it.
##
## An ortho pane's picture is the outline: the mesh edges that bound the
## surface, that separate a face turned towards the camera from one turned
## away, or where the two faces meeting there disagree by more than a
## threshold. Deciding that is per-edge work, and a shell tessellated to tens
## of thousands of vertices has of the order of a hundred thousand edges. Two
## things follow, and both of them are why this is a script of its own:
##
##   - The ADJACENCY — which welded edges exist, and the normals of the faces
##     meeting at each — depends only on the mesh. It is built at most once per
##     mesh, and LAZILY: a pane left on Perspective draws no outline and never
##     pays for one, and the panel pushes every mesh to every pane.
##   - The PROJECTION — where those edges land on screen — depends only on the
##     camera and the pane size, so it is kept until one of those moves. A
##     redraw for any other reason (a selected edge, a chooser opening, the
##     snapshot verb reading the pane) then costs nothing.
##
## Vertices are welded on a quantized lattice, and the lattice point is used as
## a Vector3i dictionary key directly. Formatting one string per vertex per
## face — three vertices, two keys and a concatenation per face edge — was most
## of the cost of building the adjacency and bought nothing.
##
## No class_name: off-tree plugin scripts cannot use class_name.

## Faces meeting at a smaller angle than this are one surface, not an edge.
const FEATURE_EDGE_ANGLE_DEGREES: float = 24.0
## Lattice pitch for welding, in reciprocal millimetres: 1 micrometre.
const EDGE_QUANTIZE_SCALE: float = 1000.0
## Above this many segments the outline is hairlines however it is stroked.
const DENSE_SEGMENT_COUNT: int = 4000
## Packs two lattice-point indices into one integer key. A mesh with more
## welded points than this cannot be drawn on screen anyway.
const _EDGE_KEY_STRIDE: int = 1 << 32

var _raw_verts: Array = []
var _raw_faces: Array = []
var _adjacency_built: bool = false

# One entry per welded edge, the five arrays in step: the two endpoints, the
# normals of the faces meeting there, and how many of those there are — one
# means the edge bounds the surface.
var _edge_a := PackedVector3Array()
var _edge_b := PackedVector3Array()
var _normal_0 := PackedVector3Array()
var _normal_1 := PackedVector3Array()
var _normal_count := PackedInt32Array()

# Projected endpoint pairs and the camera pose + pane size they are of.
var _points := PackedVector2Array()
var _points_valid: bool = false
var _points_xform: Transform3D = Transform3D.IDENTITY
var _points_size: Vector2 = Vector2.ZERO

# What the caches have actually saved, as counts rather than as milliseconds.
# Every capture of a pane reads its outline, and the whole point of the two
# caches is that a repeat capture of an unmoved camera walks no edge and
# projects no point. A clock cannot say that on a loaded machine; these can.
var _adjacency_builds: int = 0
var _projections: int = 0


## Hand over the mesh in the panel's own {vertices, faces} shape. Nothing is
## walked here: the adjacency is built the first time a pane actually asks for
## an outline.
func set_mesh(vertices: Array, faces: Array) -> void:
	_raw_verts = vertices
	_raw_faces = faces
	_adjacency_built = false
	_clear_adjacency()
	_points = PackedVector2Array()
	_points_valid = false


## Screen-space endpoint pairs for every edge worth drawing, seen from
## `camera` in a pane of `pane_size`. Served from the cache while neither has
## moved since the last call.
func points_for(camera: Camera3D, pane_size: Vector2) -> PackedVector2Array:
	if camera == null:
		return PackedVector2Array()
	var xform := camera.global_transform
	if _points_valid and xform == _points_xform and pane_size == _points_size:
		return _points
	if not _adjacency_built:
		_build_adjacency()
	_points = _project(camera)
	_projections += 1
	_points_valid = true
	_points_xform = xform
	_points_size = pane_size
	return _points


## Whether the outline last projected is dense enough to stroke as a batch.
func is_dense() -> bool:
	return _points.size() >= DENSE_SEGMENT_COUNT * 2


## Welded edges the mesh has. Zero until something has asked for an outline.
func edge_count() -> int:
	return _edge_a.size()


## How many times an adjacency has been walked over this silhouette's whole
## life. One per mesh handed to it is the contract: a second walk for a mesh
## that has not changed is exactly the cost the cache exists to remove.
func adjacency_builds() -> int:
	return _adjacency_builds


## How many times the edges have been projected over this silhouette's whole
## life. One per distinct camera pose and pane size; a repeat with neither
## moved is served from `_points` and does not count.
func projections() -> int:
	return _projections


func _clear_adjacency() -> void:
	_edge_a = PackedVector3Array()
	_edge_b = PackedVector3Array()
	_normal_0 = PackedVector3Array()
	_normal_1 = PackedVector3Array()
	_normal_count = PackedInt32Array()


func _build_adjacency() -> void:
	_clear_adjacency()
	_adjacency_built = true
	_adjacency_builds += 1
	if _raw_verts.is_empty() or _raw_faces.is_empty():
		return
	var point_index := {}
	var edge_slot := {}
	for face in _raw_faces:
		if not (face is Array and (face as Array).size() >= 3):
			continue
		var a := _vector3_from_raw(_raw_verts[int(face[0])])
		var b := _vector3_from_raw(_raw_verts[int(face[1])])
		var c := _vector3_from_raw(_raw_verts[int(face[2])])
		var normal := (b - a).cross(c - a)
		# A triangle with no area carries connectivity but no plane: taking a
		# normal from it would make its two neighbours look like boundaries.
		if normal.length_squared() <= 0.000001:
			continue
		normal = normal.normalized()
		var index_a := _lattice_index(point_index, a)
		var index_b := _lattice_index(point_index, b)
		var index_c := _lattice_index(point_index, c)
		_add_edge(edge_slot, index_a, index_b, a, b, normal)
		_add_edge(edge_slot, index_b, index_c, b, c, normal)
		_add_edge(edge_slot, index_c, index_a, c, a, normal)


## The index of `point` on the welding lattice, adding it if it is new.
func _lattice_index(point_index: Dictionary, point: Vector3) -> int:
	var key := Vector3i(
		roundi(point.x * EDGE_QUANTIZE_SCALE),
		roundi(point.y * EDGE_QUANTIZE_SCALE),
		roundi(point.z * EDGE_QUANTIZE_SCALE)
	)
	var found: Variant = point_index.get(key, null)
	if found != null:
		return int(found)
	var index: int = point_index.size()
	point_index[key] = index
	return index


## Record one face edge. The endpoints are stored in lattice-index order so
## the two faces sharing an edge agree on which way round it is; only the
## first two normals are kept, which is all a manifold edge has.
func _add_edge(edge_slot: Dictionary, index_a: int, index_b: int,
		point_a: Vector3, point_b: Vector3, normal: Vector3) -> void:
	if index_a == index_b:
		return
	var key: int = mini(index_a, index_b) * _EDGE_KEY_STRIDE + maxi(index_a, index_b)
	var slot: Variant = edge_slot.get(key, null)
	if slot == null:
		edge_slot[key] = _edge_a.size()
		if index_b < index_a:
			_edge_a.append(point_b)
			_edge_b.append(point_a)
		else:
			_edge_a.append(point_a)
			_edge_b.append(point_b)
		_normal_0.append(normal)
		_normal_1.append(Vector3.ZERO)
		_normal_count.append(1)
		return
	var at := int(slot)
	if _normal_count[at] < 2:
		_normal_1[at] = normal
		_normal_count[at] = 2


func _project(camera: Camera3D) -> PackedVector2Array:
	var points := PackedVector2Array()
	if _edge_a.is_empty():
		return points
	var view_dir := -camera.global_transform.basis.z.normalized()
	var cosine_threshold := cos(deg_to_rad(FEATURE_EDGE_ANGLE_DEGREES))
	for at in range(_edge_a.size()):
		var wanted: bool = _normal_count[at] == 1
		if not wanted:
			var normal_a := _normal_0[at]
			var normal_b := _normal_1[at]
			var is_silhouette: bool = \
				normal_a.dot(view_dir) * normal_b.dot(view_dir) <= 0.0001
			var is_sharp: bool = normal_a.dot(normal_b) < cosine_threshold
			wanted = is_silhouette or is_sharp
		if not wanted:
			continue
		var p0 := _edge_a[at]
		var p1 := _edge_b[at]
		if camera.is_position_behind(p0) and camera.is_position_behind(p1):
			continue
		points.append(camera.unproject_position(p0))
		points.append(camera.unproject_position(p1))
	return points


func _vector3_from_raw(raw_vertex: Variant) -> Vector3:
	if raw_vertex is Array and (raw_vertex as Array).size() >= 3:
		var values: Array = raw_vertex
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.ZERO
