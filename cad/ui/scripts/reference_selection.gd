extends RefCounted
## Which reference node the user is pointing at, and what that means to
## everyone who cares: the sidebar, the annotation host, and the LLM.
##
## THE CLICK IS THE SEED. An agent measuring a foreign mesh has no idea which
## of forty nodes the user means by "this bracket". A click carries that intent
## exactly once, so it is kept: the node, the point on its surface in BOTH
## frames, and the pane and pixel it came from. minerva_cad_get_selected_reference
## hands the whole thing to the LLM, which can then measure what the human
## pointed at instead of guessing.
##
## HOW THIS AVOIDS FIGHTING EDGE SELECTION. The edge overlay is a Control and
## picks in _gui_input; it consumes the events it uses. The per-pane click
## nodes (reference_click.gd) are plain Nodes and see only _unhandled_input —
## by construction they get a click only when the edge path did not take it.
## The two selections are independent state and both stay set: an edge of the
## evaluated solid and a node of a reference mesh are different questions.
##
## PICKING IS EXACT, NOT AABB-ONLY. A bounding box under the cursor is not a
## surface point, and a point that is not on the surface is not a place to
## anchor an annotation or to start a measurement. So the ray is intersected
## with the triangles themselves, after two cheap box rejections (the whole
## reference, then the part).
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/reference_selection.gd")

const _ReferenceMeshes = preload("reference_meshes.gd")
const _CadPointAnchor = preload("CadPointAnchor.gd")

## Scene-declared nodes this module wires itself to. Found by name rather than
## by path so the panel's node paths live in exactly one place — the scene.
const CLICK_NODE_NAME: String = "ReferenceClickRoot"
const SIDEBAR_NODE_NAME: String = "ReferencePanel"

## Meshes whose triangle arrays are kept unpacked for picking. surface_get_arrays
## copies, so re-reading a 130k-triangle board on every click would be the whole
## cost of the pick; the cache is dropped wholesale when it grows past this,
## because a document with more distinct meshes than this has re-loaded and the
## old ones are unreachable anyway.
const TRIANGLE_CACHE_LIMIT: int = 32

## The panel that owns this module. Read through duck typing (get_pick_ray,
## get_reference_state, get_annotation_host) — never typed, off-tree.
var _panel: Object = null
var _sidebar: Object = null

## The mounted references of the last evaluation, as CADPanel.get_reference_state().
var _records: Array = []

## The last click, or {} when nothing is selected. Shape: see _make_selection().
var _selection: Dictionary = {}

## mesh RID -> [{vertices: PackedVector3Array, indices: PackedInt32Array}, …]
var _triangles: Dictionary = {}


# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

## Connect to the panel's scene-declared click nodes and reference sidebar.
## Safe to call on a panel that declares neither: the module simply never gets
## a click, and the MCP surface still works.
func attach(panel: Object) -> void:
	_panel = panel
	if panel == null or not panel.has_method("find_children"):
		return
	for node in panel.find_children(CLICK_NODE_NAME, "", true, false):
		if node.has_method("setup"):
			node.call("setup", Callable(self, "handle_click"))
	_sidebar = panel.find_child(SIDEBAR_NODE_NAME, true, false)
	if _sidebar != null and _sidebar.has_signal("node_activated"):
		_sidebar.connect("node_activated", Callable(self, "_on_sidebar_activated"))


## The references a mount just put on screen. Called on every evaluation, so
## this is also where a pose change reaches the annotation host and where a
## selection whose reference has gone away is marked stale.
func set_records(records: Array) -> void:
	_records = records
	var host: Object = _host()
	if host != null and host.has_method("set_reference_records"):
		host.call("set_reference_records", records)
	if _sidebar != null and _sidebar.has_method("set_entries"):
		_sidebar.call("set_entries", node_entries(records))
	_revalidate_selection()
	_publish()


func get_records() -> Array:
	return _records


func get_selection() -> Dictionary:
	return _selection


# ---------------------------------------------------------------------------
# Selecting
# ---------------------------------------------------------------------------

## A left click in one pane. Returns true when it selected something, which is
## what tells the click node to mark the event handled; a click on empty space
## clears the selection and stays unhandled so the camera still gets it.
func handle_click(view_id: String, pixel: Vector2) -> bool:
	if _panel == null or not _panel.has_method("get_pick_ray"):
		return false
	var ray: Dictionary = _panel.call("get_pick_ray", view_id, pixel)
	if ray.has("error"):
		return false
	var hit := pick(_records, ray.get("from", Vector3.ZERO), ray.get("to", Vector3.ZERO))
	if hit.is_empty():
		clear_selection()
		return false
	var pose: Transform3D = (hit["record"] as Dictionary).get("pose", Transform3D.IDENTITY)
	_selection = _make_selection(
		hit["record"],
		str(hit["node"]),
		hit["local"],
		to_local_normal(pose, hit["normal"]),
		"surface",
		"click",
		view_id,
		pixel
	)
	_publish()
	return true


## Select a node by name, optionally at a named point in the reference's own
## frame. This is the MCP and sidebar route into the same state a click sets.
## Returns the selection, or {} when the reference or node is not mounted.
func select(reference: String, node_name: String, local_point: Variant = null, source: String = "mcp") -> Dictionary:
	var record := _CadPointAnchor.record_named(_records, reference)
	if record.is_empty():
		return {}
	var chosen := node_name
	if chosen.is_empty():
		var names := _node_names(record)
		if names.is_empty():
			return {}
		chosen = str(names[0])
	var bounds := _node_bounds(record, chosen)
	if bounds.size == Vector3.ZERO and not _has_node(record, chosen):
		return {}
	var point_source := "bounds_centre"
	var local: Vector3 = bounds.get_center()
	if local_point != null:
		local = _CadPointAnchor.vec3_from(local_point)
		point_source = "given"
	_selection = _make_selection(
		record, chosen, local, Vector3.ZERO, point_source, source, "", Vector2.ZERO)
	_publish()
	return _selection


func clear_selection() -> void:
	if _selection.is_empty():
		return
	_selection = {}
	_publish()


## The anchor envelope for the current selection, or {} when nothing is
## selected. This is what an authoring tool or the LLM turns into an annotation
## that follows the reference.
func selection_anchor() -> Dictionary:
	if _selection.is_empty():
		return {}
	return _CadPointAnchor.build(
		str(_selection.get("reference", "")),
		str(_selection.get("node", "")),
		_selection.get("local", Vector3.ZERO),
		_selection.get("normal", Vector3.ZERO),
		_selection.get("world", Vector3.ZERO)
	)


# ---------------------------------------------------------------------------
# Picking
# ---------------------------------------------------------------------------

## The nearest reference surface along the segment from → to, in world
## millimetres. Returns {} on a miss, else
##   {record, node, world, local, normal, distance}
## `local` is the reference's own frame, which is the frame an anchor and the
## .mcad source are written in.
func pick(records: Array, from: Vector3, to: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_t := INF
	var segment := to - from
	var segment_length := segment.length()
	if segment_length <= 0.0:
		return {}
	for entry in records:
		if not (entry is Dictionary):
			continue
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var reference_box: AABB = record.get("world_aabb", AABB())
		if reference_box.size.length_squared() > 0.0 and not reference_box.intersects_segment(from, to):
			continue
		for part_entry in record.get("parts", []):
			if not (part_entry is Dictionary):
				continue
			var part: Dictionary = part_entry
			var mesh: Mesh = part.get("mesh", null)
			if mesh == null:
				continue
			var part_box: AABB = _ReferenceMeshes.transform_aabb(
				pose, part.get("aabb", AABB()))
			if not part_box.intersects_segment(from, to):
				continue
			# The ray goes into the mesh's own frame rather than the vertices
			# coming out into the world: one transform per part instead of one
			# per vertex.
			var to_world: Transform3D = pose * (part.get("transform", Transform3D.IDENTITY) as Transform3D)
			var inverse := to_world.affine_inverse()
			var hit := _hit_mesh(mesh, inverse * from, inverse * to)
			if hit.is_empty():
				continue
			var t := float(hit["t"])
			if t >= best_t:
				continue
			best_t = t
			var world_point: Vector3 = to_world * (hit["point"] as Vector3)
			# Normals transform by the inverse transpose so a non-uniform node
			# scale does not skew them.
			var world_normal: Vector3 = (to_world.basis.inverse().transposed() * (hit["normal"] as Vector3)).normalized()
			if world_normal.dot(segment) > 0.0:
				# Face the way the user is looking from, whichever way the
				# triangle happened to be wound.
				world_normal = -world_normal
			best = {
				"record": record,
				"node": str(part.get("node_path", part.get("node", ""))),
				"node_name": str(part.get("node", "")),
				"world": world_point,
				"local": pose.affine_inverse() * world_point,
				"normal": world_normal,
				"distance": t * segment_length,
			}
	return best


## Nearest triangle intersection in the mesh's own frame. Returns {} on a miss,
## else {t: 0..1 along the segment, point, normal}. The parameter t is used for
## depth ordering rather than a length, so a part with a scaled transform does
## not compare distances in the wrong units.
func _hit_mesh(mesh: Mesh, from: Vector3, to: Vector3) -> Dictionary:
	var span := to - from
	var span_length := span.length()
	if span_length <= 0.0:
		return {}
	var result: Dictionary = {}
	var best_t := INF
	for surface in _triangles_for(mesh):
		var data: Dictionary = surface
		var vertices: PackedVector3Array = data["vertices"]
		var indices: PackedInt32Array = data["indices"]
		var count := indices.size()
		var i := 0
		while i + 2 < count:
			var a := vertices[indices[i]]
			var b := vertices[indices[i + 1]]
			var c := vertices[indices[i + 2]]
			i += 3
			var point: Variant = Geometry3D.segment_intersects_triangle(from, to, a, b, c)
			if point == null:
				continue
			var t := ((point as Vector3) - from).length() / span_length
			if t >= best_t:
				continue
			best_t = t
			result = {
				"t": t,
				"point": point,
				"normal": (b - a).cross(c - a).normalized(),
			}
	return result


## Unpacked triangle arrays for one mesh, cached. Only triangle surfaces are
## taken: a line surface (the ortho outlines) has no inside to hit.
func _triangles_for(mesh: Mesh) -> Array:
	# Instance ids are never reused within a session; RIDs are recycled once a
	# Mesh is freed, which would pick against a re-imported file's stale triangles.
	var key := str(mesh.get_instance_id())
	if _triangles.has(key):
		return _triangles[key]
	var surfaces: Array = []
	for index in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(index) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays: Array = mesh.surface_get_arrays(index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			continue
		var indices := PackedInt32Array()
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
			indices = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			indices.resize(vertices.size())
			for i in range(vertices.size()):
				indices[i] = i
		surfaces.append({"vertices": vertices, "indices": indices})
	if _triangles.size() >= TRIANGLE_CACHE_LIMIT:
		_triangles.clear()
	_triangles[key] = surfaces
	return surfaces


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

## One row per node of every mounted reference, with its bounds in both frames.
## This is what the sidebar lists and what an agent reads to know what the
## user can point at.
static func node_entries(records: Array) -> Array:
	var out: Array = []
	for entry in records:
		if not (entry is Dictionary):
			continue
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var reference := str(record.get("name", ""))
		for node_entry in record.get("node_bounds", []):
			var node: Dictionary = node_entry
			var local_box: AABB = node.get("aabb", AABB())
			out.append({
				"reference": reference,
				"node": str(node.get("name", "")),
				"node_path": str(node.get("path", node.get("name", ""))),
				"local_aabb": local_box,
				"world_aabb": _ReferenceMeshes.transform_aabb(pose, local_box),
			})
	return out


## The selection record every consumer reads. Both frames, always: `local` is
## what goes into the .mcad, `world` is what compares against everything else
## in the scene.
##
## THE NORMAL IS STORED IN THE REFERENCE FRAME, like the point beside it. That
## is the frame CadPointAnchor.build declares, and it is the only frame that
## survives a re-pose: a stored world normal is either transformed a second
## time on resolve or left pointing where the mesh used to face.
##
## `node` is the node's PATH from the file root, which is unique; `node_name`
## is the leaf, which several nodes may share.
func _make_selection(
	record: Dictionary,
	node_name: String,
	local: Vector3,
	normal_local: Vector3,
	point_source: String,
	source: String,
	view_id: String,
	pixel: Vector2
) -> Dictionary:
	var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
	var row := node_row(record, node_name)
	var local_box: AABB = row.get("aabb", AABB())
	return {
		"reference": str(record.get("name", "")),
		"node": str(row.get("path", node_name)) if not row.is_empty() else node_name,
		"node_name": str(row.get("name", node_name)) if not row.is_empty() else node_name,
		"local": local,
		"world": pose * local,
		"normal": normal_local,
		"normal_world": to_world_normal(pose, normal_local),
		"point_source": point_source,
		"source": source,
		"view": view_id,
		"pixel": pixel,
		"local_aabb": local_box,
		"world_aabb": _ReferenceMeshes.transform_aabb(pose, local_box),
		"stale": false,
	}


## A normal from the posed world into the reference's own frame, and back.
## Normals follow the inverse transpose, so a reference posed with a
## non-uniform node scale is not skewed; the pair is exactly inverse.
static func to_local_normal(pose: Transform3D, normal: Vector3) -> Vector3:
	var value := pose.basis.transposed() * normal
	return value.normalized() if value.length_squared() > 0.0 else Vector3.ZERO


static func to_world_normal(pose: Transform3D, normal: Vector3) -> Vector3:
	var value := pose.basis.inverse().transposed() * normal
	return value.normalized() if value.length_squared() > 0.0 else Vector3.ZERO


## Re-derive the world half of the selection against the poses of the mount
## that just happened. A selection whose reference or node has left the
## document is marked stale and kept: the user still pointed at it, and the
## honest report is "that is gone", not an empty answer.
func _revalidate_selection() -> void:
	if _selection.is_empty():
		return
	var record := _CadPointAnchor.record_named(
		_records, str(_selection.get("reference", "")))
	if record.is_empty() or not _has_node(record, str(_selection.get("node", ""))):
		_selection["stale"] = true
		return
	var refreshed := _make_selection(
		record,
		str(_selection.get("node", "")),
		_selection.get("local", Vector3.ZERO),
		_selection.get("normal", Vector3.ZERO),
		str(_selection.get("point_source", "surface")),
		str(_selection.get("source", "click")),
		str(_selection.get("view", "")),
		_selection.get("pixel", Vector2.ZERO)
	)
	_selection = refreshed


## Push the current selection to the annotation host (so a point anchor can be
## authored from it), to the sidebar (so the user sees what they hit), and to
## the panel's annotation-tool status signal (so an armed tool's warning
## follows the selection rather than the tool).
func _publish() -> void:
	var host: Object = _host()
	if host != null and host.has_method("set_selected_reference"):
		host.call("set_selected_reference", _selection)
	if _sidebar != null and _sidebar.has_method("set_selection"):
		_sidebar.call("set_selection", _selection)
	if _panel != null and is_instance_valid(_panel) \
			and _panel.has_signal("annotation_tool_status_changed"):
		_panel.emit_signal("annotation_tool_status_changed")


func _on_sidebar_activated(reference: String, node_name: String) -> void:
	select(reference, node_name, null, "sidebar")


func _host() -> Object:
	if _panel == null or not _panel.has_method("get_annotation_host"):
		return null
	return _panel.call("get_annotation_host")


## The node_bounds row a name picks out. A full PATH names exactly one row; a
## leaf name names the first row that carries it, which is the only sensible
## answer when the caller had no way to know the branch. {} when neither
## matches.
static func node_row(record: Dictionary, node_name: String) -> Dictionary:
	if node_name.is_empty():
		return {}
	var by_leaf: Dictionary = {}
	for node_entry in record.get("node_bounds", []):
		var node: Dictionary = node_entry
		if str(node.get("path", node.get("name", ""))) == node_name:
			return node
		if by_leaf.is_empty() and str(node.get("name", "")) == node_name:
			by_leaf = node
	return by_leaf


func _node_bounds(record: Dictionary, node_name: String) -> AABB:
	return node_row(record, node_name).get("aabb", AABB())


func _has_node(record: Dictionary, node_name: String) -> bool:
	return not node_row(record, node_name).is_empty()


func _node_names(record: Dictionary) -> Array:
	var out: Array = []
	for node_entry in record.get("node_bounds", []):
		var node: Dictionary = node_entry
		out.append(str(node.get("path", node.get("name", ""))))
	return out
