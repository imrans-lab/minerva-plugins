## mesh_display.gd
## Attached to the MeshRoot Node3D in the scene.
## Receives parsed mesh data from the backend and renders it as an ArrayMesh.
##
## Ported verbatim from ~/gitlab/ccsandbox/experiments/CAD/mcad-app/scripts/mesh_display.gd.
## No dependency on backend_client.gd — data is delivered via Minerva plugin IPC
## (PluginEventBroker) in Round 2+.

extends Node3D
class_name MeshDisplay

## Feature-edge extraction and line-mesh building are shared with the reference
## library, so the evaluated solid and a foreign reference are outlined by one
## piece of code and cannot drift apart.
const _ReferenceMeshes: Script = preload("reference_meshes.gd")

const DEFAULT_MESH_COLOR := Color(0.78, 0.62, 0.12)
const DEFAULT_EDGE_COLOR := Color(0.16, 0.11, 0.02, 0.95)
const DEFAULT_EDGE_LABEL_COLOR := Color(0.97, 0.97, 0.99, 0.98)
const ORTHO_EDGE_COLOR := Color(0.08, 0.09, 0.11, 1.0)
const EDGE_LABEL_OUTWARD_OFFSET := 16.0
const EDGE_LABEL_VERTICAL_OFFSET := 10.0
const EDGE_LABEL_DEPTH_STAGGER := 10.0
const EDGE_LABEL_PIXEL_SIZE := 0.0026
const EDGE_LABEL_FONT_SIZE := 24
## Measurement overlay (grid + axes) drawn under this node on request.
const OVERLAY_NODE_NAME := "MeasurementOverlay"
const OVERLAY_GRID_COLOR := Color(0.42, 0.47, 0.55, 0.55)
## Beyond this many grid lines across the view the spacing is doubled until it
## fits; a grid that dense reads as a solid fill in a snapshot.
const OVERLAY_MAX_LINES := 60

var _mesh_instance: MeshInstance3D
var _edge_instance: MeshInstance3D
var _edge_leader_instance: MeshInstance3D
var _edge_label_root: Node3D
var _wireframe_only: bool = false
var _model_center: Vector3 = Vector3.ZERO
var _feature_edge_count: int = 0
## What the outline pass saw in the mesh it just walked: face count and the
## defects (degenerate faces, open or non-manifold edges, duplicate faces).
## Free — the outline pass welds and walks every triangle anyway.
var _mesh_stats: Dictionary = {}
## World bounds (CAD millimetres) of the reference meshes mounted under this
## node. Auto-framing has to cover them: a document whose only geometry is a
## referenced board would otherwise frame on an empty solid.
var _reference_aabb: AABB = AABB()


func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "MeshInstance"
	add_child(_mesh_instance)

	_edge_instance = MeshInstance3D.new()
	_edge_instance.name = "FeatureEdges"
	add_child(_edge_instance)

	_edge_leader_instance = MeshInstance3D.new()
	_edge_leader_instance.name = "EdgeLeaders"
	add_child(_edge_leader_instance)

	_edge_label_root = Node3D.new()
	_edge_label_root.name = "EdgeLabels"
	add_child(_edge_label_root)


# -------------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------------

## Update the displayed mesh from backend response data.
##
## Expected format:
##   {
##     "vertices": [[x, y, z], ...],
##     "faces":    [[i, j, k], ...],   # triangle indices
##     "normals":  [[x, y, z], ...],   # optional, per-vertex
##     "color":    [r, g, b]           # optional, 0..1
##   }
##
## TODO(scaffold-round-2): wire to plugin IPC instead of HTTP backend.
## In Round 2+, CADPanel._on_ipc_mesh_ready(data) calls update_mesh(data, edge_registry).
## edge_registry parameter retained on the signature but unused — Round 1 stripped
## the auto-emitted Label3D edge callouts; the cad_edge_number annotation kind owns
## that surface now. Underscore prefix silences UNUSED_PARAMETER.
func update_mesh(mesh_data: Dictionary, _edge_registry: Variant = []) -> void:
	clear_mesh()

	var raw_verts = mesh_data.get("vertices", [])
	var raw_faces = mesh_data.get("faces", [])
	var raw_normals = mesh_data.get("normals", [])
	var raw_color: Variant = mesh_data.get("color", null)

	if raw_verts is Array and raw_faces is Array \
			and raw_verts.size() > 0 and raw_faces.size() > 0:
		var aabb := _compute_aabb(raw_verts)
		_model_center = aabb.get_center()
		if _wireframe_only:
			_mesh_instance.mesh = null
			_mesh_instance.visible = false
		else:
			var arr_mesh := _build_array_mesh(raw_verts, raw_faces, raw_normals, raw_color)
			if arr_mesh != null:
				_mesh_instance.mesh = arr_mesh
				_mesh_instance.visible = true
		_edge_instance.mesh = _build_feature_edge_mesh(raw_verts, raw_faces)
		# Default-no-labels: edge id callouts are now handled by the
		# `cad_edge_number` annotation kind, not auto-emitted. The leader
		# helpers and Label3D root remain but stay empty unless something
		# else populates them.
		_edge_leader_instance.mesh = null
		_render_edge_labels([], aabb.get_center())
		_auto_frame(raw_verts, aabb)
	else:
		# References-only document: there is no solid to frame on, but there
		# may well be something to look at.
		_auto_frame([])


func clear_mesh() -> void:
	_mesh_instance.mesh = null
	_mesh_instance.visible = false
	_edge_instance.mesh = null
	_edge_leader_instance.mesh = null
	_model_center = Vector3.ZERO
	_feature_edge_count = 0
	_mesh_stats = {}
	for child in _edge_label_root.get_children():
		child.queue_free()


## Bounds of the reference meshes mounted under this node, in CAD millimetres.
## The panel sets it before pushing a new evaluation; framing merges it in.
func set_reference_aabb(aabb: AABB) -> void:
	_reference_aabb = aabb


func get_reference_aabb() -> AABB:
	return _reference_aabb


## Draw (or clear) the measurement overlay: a millimetre grid on the CAD floor
## and/or the three world axes through the origin. The overlay is scene
## geometry, not a post-process, so it is in every snapshot the host takes of
## this pane without the snapshot verb having to know about it.
##
## `mode` is "none", "grid", "axes" or "grid+axes"; `bounds` is the world
## extent to cover. Returns what was drawn, so the caller can report the grid
## spacing it actually got rather than the one it asked for.
func set_measurement_overlay(mode: String, grid_mm: float, bounds: AABB) -> Dictionary:
	var root := get_node_or_null(OVERLAY_NODE_NAME) as Node3D
	if root != null:
		root.free()
	if mode == "none" or mode.is_empty():
		return {"mode": "none", "grid_mm": 0.0, "lines": 0}

	root = Node3D.new()
	root.name = OVERLAY_NODE_NAME
	add_child(root)

	var extent := maxf(bounds.size.x, bounds.size.y)
	if extent <= 0.0:
		extent = 100.0
	var centre := bounds.get_center()
	var spacing := grid_mm if grid_mm > 0.0 else 10.0
	# Coarsen rather than draw a solid block of lines: an overlay nobody can
	# read through is worse than no overlay.
	while extent / spacing > float(OVERLAY_MAX_LINES):
		spacing *= 2.0

	var lines := 0
	if mode.contains("grid"):
		var half: float = ceil(extent * 0.6 / spacing) * spacing
		var origin_x: float = floor(centre.x / spacing) * spacing
		var origin_y: float = floor(centre.y / spacing) * spacing
		var segments := PackedVector3Array()
		var offset: float = -half
		while offset <= half:
			segments.append(Vector3(origin_x + offset, origin_y - half, 0.0))
			segments.append(Vector3(origin_x + offset, origin_y + half, 0.0))
			segments.append(Vector3(origin_x - half, origin_y + offset, 0.0))
			segments.append(Vector3(origin_x + half, origin_y + offset, 0.0))
			lines += 2
			offset += spacing
		var grid_mesh: ArrayMesh = _ReferenceMeshes.line_mesh_from_segments(
			segments, OVERLAY_GRID_COLOR)
		if grid_mesh != null:
			var grid_instance := MeshInstance3D.new()
			grid_instance.name = "Grid"
			grid_instance.mesh = grid_mesh
			root.add_child(grid_instance)

	if mode.contains("axes"):
		var reach := maxf(extent * 0.6, spacing * 3.0)
		var axes := [
			[Vector3.RIGHT, Color(0.85, 0.24, 0.24, 1.0), "AxisX"],
			[Vector3.UP, Color(0.24, 0.72, 0.32, 1.0), "AxisY"],
			[Vector3.BACK, Color(0.28, 0.46, 0.9, 1.0), "AxisZ"],
		]
		for entry in axes:
			var direction: Vector3 = entry[0]
			var segment := PackedVector3Array([Vector3.ZERO, direction * reach])
			var axis_mesh: ArrayMesh = _ReferenceMeshes.line_mesh_from_segments(
				segment, entry[1] as Color)
			if axis_mesh == null:
				continue
			var axis_instance := MeshInstance3D.new()
			axis_instance.name = str(entry[2])
			axis_instance.mesh = axis_mesh
			root.add_child(axis_instance)
			lines += 1

	return {"mode": mode, "grid_mm": spacing, "lines": lines}


func set_wireframe_only(value: bool) -> void:
	_wireframe_only = value
	if _mesh_instance != null:
		_mesh_instance.visible = not value


# -------------------------------------------------------------------------
# Internal — mesh construction
# -------------------------------------------------------------------------

func _build_array_mesh(
	raw_verts: Array,
	raw_faces: Array,
	raw_normals: Array,
	raw_color: Variant
) -> ArrayMesh:
	# Build flat triangle arrays (one entry per face corner)
	var positions := PackedVector3Array()
	var normals   := PackedVector3Array()
	var indices   := PackedInt32Array()

	# Collect vertex positions
	var vertices := PackedVector3Array()
	for v in raw_verts:
		if v is Array and v.size() >= 3:
			vertices.append(Vector3(float(v[0]), float(v[1]), float(v[2])))
		else:
			return null  # Malformed data

	# Collect per-vertex normals if supplied
	var has_normals := raw_normals is Array and raw_normals.size() == raw_verts.size()
	var vert_normals := PackedVector3Array()
	if has_normals:
		for n in raw_normals:
			if n is Array and n.size() >= 3:
				vert_normals.append(Vector3(float(n[0]), float(n[1]), float(n[2])))
			else:
				has_normals = false
				break

	# Build index list and expanded per-face arrays
	for face in raw_faces:
		if not (face is Array and face.size() >= 3):
			return null

		var i0: int = int(face[0])
		var i1: int = int(face[1])
		var i2: int = int(face[2])

		if i0 >= vertices.size() or i1 >= vertices.size() or i2 >= vertices.size():
			return null

		var idx_base := positions.size()
		positions.append(vertices[i0])
		positions.append(vertices[i1])
		positions.append(vertices[i2])
		indices.append(idx_base)
		indices.append(idx_base + 1)
		indices.append(idx_base + 2)

		if has_normals:
			normals.append(vert_normals[i0])
			normals.append(vert_normals[i1])
			normals.append(vert_normals[i2])

	# Compute flat normals if not supplied
	if not has_normals:
		normals = _compute_flat_normals(positions, indices)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX]  = indices

	var mat := StandardMaterial3D.new()
	mat.albedo_color  = _parse_color(raw_color)
	mat.metallic      = 0.0
	mat.roughness     = 0.92
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# CAD tessellation may contain mixed winding on some triangles; render both
	# sides so the preview reads as a closed solid instead of a patchy shell.
	mat.cull_mode     = BaseMaterial3D.CULL_DISABLED

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	arr_mesh.surface_set_material(0, mat)

	return arr_mesh


func _build_feature_edge_mesh(raw_verts: Array, raw_faces: Array) -> Mesh:
	var positions := PackedVector3Array()
	for v in raw_verts:
		positions.append(_vector3_from_raw(v))

	var indices := PackedInt32Array()
	for face in raw_faces:
		if not (face is Array and face.size() >= 3):
			continue
		indices.append(int(face[0]))
		indices.append(int(face[1]))
		indices.append(int(face[2]))

	var stats := {}
	var segments: PackedVector3Array = _ReferenceMeshes.feature_edge_segments(
		positions, indices, _ReferenceMeshes.FEATURE_EDGE_ANGLE_DEGREES, stats)
	_feature_edge_count = int(segments.size() / 2)
	_mesh_stats = stats
	return _ReferenceMeshes.line_mesh_from_segments(
		segments,
		ORTHO_EDGE_COLOR if _wireframe_only else DEFAULT_EDGE_COLOR
	)


func _parse_color(raw_color: Variant) -> Color:
	if raw_color is Array and raw_color.size() >= 3:
		var color_array: Array = raw_color
		var alpha := 1.0
		if color_array.size() >= 4:
			alpha = float(color_array[3])
		return Color(
			float(color_array[0]),
			float(color_array[1]),
			float(color_array[2]),
			alpha
		)
	return DEFAULT_MESH_COLOR


# Retained for the Round 2 annotation-driven `cad_edge_number` rendering path.
# Currently called only with [] from update_mesh — no auto-emission.
func _render_edge_labels(edge_registry: Variant, model_center: Vector3) -> void:
	if not (edge_registry is Array):
		return
	if edge_registry.is_empty():
		return

	for edge_info in edge_registry:
		if not (edge_info is Dictionary):
			continue
		if not edge_info.has("id") or not edge_info.has("midpoint"):
			continue

		var label_position := _edge_label_position(edge_info, model_center)

		var label := Label3D.new()
		label.text = str(int(edge_info["id"]))
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.pixel_size = EDGE_LABEL_PIXEL_SIZE
		label.font_size = EDGE_LABEL_FONT_SIZE
		label.outline_size = 6
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.modulate = DEFAULT_EDGE_LABEL_COLOR
		label.no_depth_test = false
		label.render_priority = 1
		label.position = label_position
		_edge_label_root.add_child(label)


# Retained for the Round 2 annotation-driven `cad_edge_number` rendering path.
func _build_edge_label_leaders(edge_registry: Variant, model_center: Vector3) -> ImmediateMesh:
	if not (edge_registry is Array):
		return null
	if edge_registry.is_empty():
		return null

	var line_mesh := ImmediateMesh.new()
	var line_count := 0
	line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge_info in edge_registry:
		if not (edge_info is Dictionary):
			continue
		if not edge_info.has("id") or not edge_info.has("midpoint"):
			continue

		var anchor_point := _vector3_from_raw(edge_info["midpoint"])
		var label_position := _edge_label_position(edge_info, model_center)
		var elbow_point := anchor_point.lerp(label_position, 0.55)
		line_mesh.surface_add_vertex(anchor_point)
		line_mesh.surface_add_vertex(elbow_point)
		line_mesh.surface_add_vertex(elbow_point)
		line_mesh.surface_add_vertex(label_position)
		line_count += 1
	line_mesh.surface_end()

	if line_count == 0:
		return null

	var line_material := StandardMaterial3D.new()
	line_material.albedo_color = ORTHO_EDGE_COLOR if _wireframe_only else DEFAULT_EDGE_LABEL_COLOR
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	line_material.no_depth_test = false
	line_mesh.surface_set_material(0, line_material)
	return line_mesh


func _edge_label_position(edge_info: Dictionary, model_center: Vector3) -> Vector3:
	var midpoint := _vector3_from_raw(edge_info["midpoint"])
	var source_point := midpoint
	if edge_info.has("source_point"):
		var source_xy: Variant = edge_info["source_point"]
		if source_xy is Array and source_xy.size() >= 2:
			source_point = Vector3(float(source_xy[0]), float(source_xy[1]), midpoint.z)

	var offset_dir := source_point - Vector3(model_center.x, model_center.y, midpoint.z)
	if offset_dir.length_squared() <= 0.000001:
		offset_dir = Vector3.UP
	else:
		offset_dir = offset_dir.normalized()

	var edge_id := int(edge_info["id"])
	var depth_sign := -1.0 if edge_id % 2 == 0 else 1.0
	return midpoint \
		+ offset_dir * EDGE_LABEL_OUTWARD_OFFSET \
		+ Vector3.UP * EDGE_LABEL_VERTICAL_OFFSET \
		+ Vector3(0, 0, depth_sign * EDGE_LABEL_DEPTH_STAGGER)


func _vector3_from_raw(raw_vertex: Variant) -> Vector3:
	if raw_vertex is Array and raw_vertex.size() >= 3:
		return Vector3(
			float(raw_vertex[0]),
			float(raw_vertex[1]),
			float(raw_vertex[2])
		)
	return Vector3.ZERO


func _compute_flat_normals(
	positions: PackedVector3Array,
	indices: PackedInt32Array
) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(positions.size())

	var i := 0
	while i + 2 < indices.size():
		var a := positions[indices[i]]
		var b := positions[indices[i + 1]]
		var c := positions[indices[i + 2]]
		var n := (b - a).cross(c - a).normalized()
		normals[indices[i]]     = n
		normals[indices[i + 1]] = n
		normals[indices[i + 2]] = n
		i += 3

	return normals


# -------------------------------------------------------------------------
# Internal — camera framing
# -------------------------------------------------------------------------

## Re-target the OrbitCamera so the mesh fits the view.
## Walks up the scene tree to find OrbitCamera by class name.
func _auto_frame(raw_verts: Array, aabb: AABB = AABB()) -> void:
	if aabb == AABB():
		aabb = _compute_aabb(raw_verts)
	if _reference_aabb.size != Vector3.ZERO:
		aabb = _reference_aabb if aabb.size == Vector3.ZERO else aabb.merge(_reference_aabb)
	if aabb.size == Vector3.ZERO:
		return

	var center := aabb.get_center()
	var radius := aabb.size.length() * 0.5

	# The camera lives at a fixed path relative to MeshRoot's grandparent (Scene3D)
	var cam = _find_orbit_camera()
	if cam == null:
		return

	cam.set_target(center)
	# Reasonable distance: cover the bounding sphere with some margin
	cam.set_distance(radius * 2.5)


func _compute_aabb(raw_verts: Array) -> AABB:
	if raw_verts.is_empty():
		return AABB()
	var first: Variant = raw_verts[0]
	if not (first is Array and first.size() >= 3):
		return AABB()
	var mn := Vector3(float(first[0]), float(first[1]), float(first[2]))
	var mx := mn
	for v in raw_verts:
		if not (v is Array and v.size() >= 3):
			continue
		var p := Vector3(float(v[0]), float(v[1]), float(v[2]))
		mn = mn.min(p)
		mx = mx.max(p)
	return AABB(mn, mx - mn)


func _find_orbit_camera():
	# MeshRoot → SubViewport parent → OrbitCamera sibling
	var parent := get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child.get_script() != null and child.get_script().get_global_name() == "OrbitCamera":
			return child
		# Fallback: match by node name
		if child.name == "OrbitCamera":
			return child
	return null


func get_model_center() -> Vector3:
	return _model_center


func is_wireframe_only() -> bool:
	return _wireframe_only


func is_mesh_visible() -> bool:
	return _mesh_instance != null and _mesh_instance.visible and _mesh_instance.mesh != null


func get_feature_edge_count() -> int:
	return _feature_edge_count


## Defect counts for the mesh currently displayed, or {} before one is.
func get_mesh_stats() -> Dictionary:
	return _mesh_stats


func get_debug_state() -> Dictionary:
	return {
		"mesh_instance_visible": _mesh_instance != null and _mesh_instance.visible,
		"mesh_instance_has_mesh": _mesh_instance != null and _mesh_instance.mesh != null,
		"edge_instance_visible": _edge_instance != null and _edge_instance.visible,
		"edge_instance_has_mesh": _edge_instance != null and _edge_instance.mesh != null,
		"edge_leader_visible": _edge_leader_instance != null and _edge_leader_instance.visible,
		"edge_leader_has_mesh": _edge_leader_instance != null and _edge_leader_instance.mesh != null,
		"label3d_count": _edge_label_root.get_child_count() if _edge_label_root != null else 0,
	}
