## reference_meshes.gd — the CAD panel's foreign-geometry library.
##
## An evaluation reply carries `references`: mesh files the .mcad source named
## with `mesh("path")` and posed with the ordinary transform verbs. The worker
## never opens those files; this module does, and it is the only place that
## does. Its three jobs are:
##
##   LOAD ONCE      a file is read from disk the first time it is named and
##                  kept, keyed by absolute path plus a content stamp. Poses
##                  change on every keystroke; the file does not.
##   CONVERT ONCE   the file's own units and up-axis are folded into the part
##                  transforms at load, so everything downstream is CAD frame:
##                  millimetres, Z-up. Feature edges for the ortho x-ray panes
##                  are extracted in that frame at load and cached with it —
##                  a 130k-triangle board must never re-extract on a pose edit.
##   POSE PER EVAL  mounting applies the evaluation's 4x4 to the converted
##                  geometry and nothing else.
##
## The host hands a plugin panel `raw_text` alongside `file_path` for every
## document it loads, and for a binary file that string stops at the first NUL
## byte (five characters for a GLB). Nothing here takes text: the only input is
## a path.
##
## glTF/GLB only for now. The seam an OBJ or STL parser plugs into is
## `_read_parts_from_file`, which owes the rest of the module a list of
## {mesh, transform} in the FILE's own frame.
extends RefCounted

## Millimetres per unit, for the `units` a reference may declare.
const UNIT_SCALE_MM: Dictionary = {
	"mm": 1.0,
	"cm": 10.0,
	"m": 1000.0,
	"in": 25.4,
}

## Dihedral angle above which a shared edge is drawn as a feature edge.
const FEATURE_EDGE_ANGLE_DEGREES: float = 28.0
## Position quantisation (per millimetre) used to weld coincident vertices
## before edges are matched. Tessellators emit the same corner many times with
## the last bits differing; without welding every triangle edge looks like a
## boundary.
const FEATURE_EDGE_QUANTIZE_SCALE: float = 1000.0

## Colour of the reference outline in the ortho panes. Deliberately cooler and
## lighter than the evaluated solid's edges so a foreign body reads as foreign.
const REFERENCE_EDGE_COLOR: Color = Color(0.20, 0.36, 0.55, 1.0)

## Child of a MeshRoot that holds every mounted reference.
const LAYER_NODE_NAME: String = "ReferenceRoot"
## Per-reference containers inside a reference node.
const SHADED_NODE_NAME: String = "Shaded"
const OUTLINE_NODE_NAME: String = "Outline"


## One file, read and converted into the CAD frame. Shared by every viewport
## and every pose that names it.
class LoadedFile extends RefCounted:
	var path: String = ""
	## Identity of the bytes on disk: a content digest, so a rewrite within the
	## same second at the same length still reads as a change.
	var stamp: String = ""
	## [{mesh: Mesh, transform: Transform3D, node: String, aabb: AABB}] —
	## transforms are file-frame to CAD-local (millimetres, Z-up), parent
	## transforms already composed; `aabb` is that part's bounds in the same
	## frame and `node` the name it had in the file, so a measurement can be
	## reported against the node the author named rather than against "the
	## file".
	var parts: Array = []
	## Feature-edge line meshes, already in CAD-local millimetres, so they
	## mount with an identity transform. Parallel to nothing — one per part
	## that produced any.
	var outlines: Array = []
	## Bounds of every part in CAD-local millimetres.
	var local_aabb: AABB = AABB()
	## Non-empty when the file could not be read; the panel surfaces it.
	var error: String = ""

	func is_ok() -> bool:
		return error.is_empty() and not parts.is_empty()

	## Bounds per named node, in CAD-local millimetres. A node split across
	## several glTF primitives (one per material) is merged back into one
	## entry, because the split is an artefact of the exporter, not a fact
	## about the part.
	func node_bounds() -> Array:
		var order: Array = []
		var merged := {}
		for entry in parts:
			var part: Dictionary = entry
			var node_name := str(part.get("node", ""))
			var box: AABB = part.get("aabb", AABB())
			if merged.has(node_name):
				merged[node_name] = (merged[node_name] as AABB).merge(box)
			else:
				merged[node_name] = box
				order.append(node_name)
		var out: Array = []
		for node_name in order:
			out.append({"name": node_name, "aabb": merged[node_name]})
		return out


var _cache: Dictionary = {}
## How many times a file has actually been read off disk. The pose changing
## must not move this number; the file changing must.
var _load_count: int = 0
## Stamps computed during the current mount_all call, keyed by absolute path.
var _stamp_memo: Dictionary = {}
var _in_mount: bool = false
## What the last mount actually put on screen: one record per reference that
## loaded, in the order the evaluation named them. This is what the
## measurement surface reads — it is the only place that knows which file each
## posed body came from and where it ended up.
var _mounted: Array = []


# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

func get_load_count() -> int:
	return _load_count


func clear_cache() -> void:
	_cache.clear()
	_stamp_memo.clear()


## Records for the references the last mount put on screen: {name, path,
## resolved_path, stamp, pose, local_aabb, world_aabb, parts, node_bounds}.
## `parts` is the cached, converted geometry — shared, not copied — so a caller
## that wants colliders or a segmentation reads it straight from here.
func mounted_references() -> Array:
	return _mounted


## Resolve the path a `mesh()` call wrote against the document that wrote it.
## Returns {path, warning, error}; `path` is empty when `error` is set.
func resolve(raw_path: String, document_path: String) -> Dictionary:
	var out := {"path": "", "warning": "", "error": ""}
	var raw := raw_path.strip_edges()
	if raw.is_empty():
		out["error"] = "mesh() was given an empty path"
		return out

	if raw.is_absolute_path():
		out["path"] = raw.simplify_path()
		if document_path.strip_edges().is_empty():
			# Nothing to be relative TO yet. Absolute works, but the source
			# stops being portable the moment it is saved and moved.
			out["warning"] = (
				"'%s' is an absolute path in an unsaved document — save the "
				+ ".mcad first and make the path relative to it."
			) % raw
		return out

	if document_path.strip_edges().is_empty():
		out["error"] = (
			"'%s' is relative but the document has never been saved — "
			+ "save it, or give mesh() an absolute path."
		) % raw
		return out

	out["path"] = document_path.get_base_dir().path_join(raw).simplify_path()
	return out


## Read a file, or hand back the copy already read. `units`/`up` are what the
## reference declared (blank means "whatever the format says") and take part in
## the cache key, because they decide the conversion baked into the result.
## Never throws: a failure comes back as a LoadedFile carrying `error`, and is
## cached too, so a missing file is not re-stat-ed on every keystroke.
func load_file(absolute_path: String, units: String = "", up: String = "") -> LoadedFile:
	var stamp := file_stamp(absolute_path)
	var key := "%s|%s|%s" % [absolute_path, units.to_lower(), up.to_lower()]
	var cached: LoadedFile = _cache.get(key, null)
	if cached != null and cached.stamp == stamp:
		return cached

	var loaded := LoadedFile.new()
	loaded.path = absolute_path
	loaded.stamp = stamp
	_load_count += 1

	if not FileAccess.file_exists(absolute_path):
		loaded.error = "reference file not found: %s" % absolute_path
		_cache[key] = loaded
		return loaded

	var extension := absolute_path.get_extension().to_lower()
	if extension != "glb" and extension != "gltf":
		loaded.error = "unsupported reference format '.%s' (glTF/GLB only): %s" % [
			extension, absolute_path,
		]
		_cache[key] = loaded
		return loaded

	var file_parts := _read_parts_from_file(absolute_path, loaded, units, up)
	if not loaded.error.is_empty():
		_cache[key] = loaded
		return loaded
	if file_parts.is_empty():
		loaded.error = "reference file holds no mesh geometry: %s" % absolute_path
		_cache[key] = loaded
		return loaded

	_cache[key] = loaded
	return loaded


## Build (or rebuild) the reference layer under `parent` from an evaluation's
## `references` array. Returns {world_aabb, warnings, errors, mounted}.
##
## Rebuilding the nodes is cheap: the meshes are shared resources handed over
## from the cache, so a pose edit re-parents pointers, it does not re-read
## anything.
func mount(references: Array, document_path: String, parent: Node3D) -> Dictionary:
	return mount_all(references, document_path, [parent])


## Mount the same references under several parents (one per viewport) in one
## evaluation. Each file is stamped once per call rather than once per parent,
## so the cost of the content digest stays flat; the report is the last
## parent's, identical for all of them.
func mount_all(references: Array, document_path: String, parents: Array) -> Dictionary:
	_stamp_memo.clear()
	_in_mount = true
	_mounted = []
	var report := {}
	var first := true
	for parent in parents:
		report = _mount_under(references, document_path, parent as Node3D, first)
		first = false
	_in_mount = false
	_stamp_memo.clear()
	return report


func _mount_under(
	references: Array,
	document_path: String,
	parent: Node3D,
	record: bool
) -> Dictionary:
	var warnings := PackedStringArray()
	var errors := PackedStringArray()
	var mounted := 0
	var bounds := AABB()
	var have_bounds := false

	if parent != null:
		var layer := _layer(parent, true)
		for child in layer.get_children():
			layer.remove_child(child)
			child.free()

		for entry in references:
			if not (entry is Dictionary):
				continue
			var reference: Dictionary = entry
			var resolved := resolve(str(reference.get("path", "")), document_path)
			if not str(resolved["warning"]).is_empty():
				warnings.append(str(resolved["warning"]))
			if not str(resolved["error"]).is_empty():
				errors.append(str(resolved["error"]))
				continue

			# The unit and up-axis conversion is baked into the cached parts,
			# so what is left to apply per evaluation is the pose, nothing else.
			var loaded := load_file(
				str(resolved["path"]),
				str(reference.get("units", "")),
				str(reference.get("up", ""))
			)
			if not loaded.is_ok():
				errors.append(loaded.error)
				continue

			var pose := transform_from_matrix(reference.get("matrix", []))
			layer.add_child(
				_build_reference_node(loaded, pose, str(reference.get("name", ""))))
			mounted += 1

			var world := transform_aabb(pose, loaded.local_aabb)
			if record:
				_mounted.append({
					"name": str(reference.get("name", "")),
					"path": str(reference.get("path", "")),
					"resolved_path": loaded.path,
					"stamp": loaded.stamp,
					"pose": pose,
					"local_aabb": loaded.local_aabb,
					"world_aabb": world,
					"parts": loaded.parts,
					"node_bounds": loaded.node_bounds(),
				})
			bounds = world if not have_bounds else bounds.merge(world)
			have_bounds = true

	return {
		"world_aabb": bounds,
		"warnings": warnings,
		"errors": errors,
		"mounted": mounted,
	}


## Show or hide the shaded reference geometry under `parent`. The ortho panes
## are outline x-rays: the outlines stay, the shaded bodies go.
func set_shaded_visible(parent: Node3D, shaded_visible: bool) -> void:
	var layer := _layer(parent, false)
	if layer == null:
		return
	for reference_node in layer.get_children():
		var shaded := reference_node.get_node_or_null(SHADED_NODE_NAME)
		if shaded != null:
			shaded.visible = shaded_visible


# ---------------------------------------------------------------------------
# Frame conversion — static, so a test can check the arithmetic on its own
# ---------------------------------------------------------------------------

## Transform taking a point in the file's frame to the CAD frame (millimetres,
## Z-up). `units`/`up` come from the reference; when either is blank the
## format's own convention decides, which for glTF is metres, Y-up.
static func conversion_transform(units: String, up: String, path: String = "") -> Transform3D:
	var extension := path.get_extension().to_lower()
	var is_gltf := extension == "glb" or extension == "gltf"

	var unit_key := units.strip_edges().to_lower()
	if unit_key.is_empty():
		unit_key = "m" if is_gltf else "mm"
	var scale: float = float(UNIT_SCALE_MM.get(unit_key, 1.0))

	var up_key := up.strip_edges().to_lower()
	if up_key.is_empty():
		up_key = "y" if is_gltf else "z"

	var basis := Basis.IDENTITY
	match up_key:
		"y":
			# File +Y is up; CAD +Z is up. Rotate +90 about X: (x, y, z) -> (x, -z, y).
			basis = Basis(Vector3.RIGHT, deg_to_rad(90.0))
		"x":
			# File +X is up. Rotate -90 about Y: (x, y, z) -> (-z, y, x).
			basis = Basis(Vector3.UP, deg_to_rad(-90.0))
		_:
			basis = Basis.IDENTITY

	return Transform3D(basis.scaled(Vector3(scale, scale, scale)), Vector3.ZERO)


## Turn the worker's row-major 4x4 into a Transform3D. Godot's Basis
## constructor takes the transformed unit vectors — the matrix COLUMNS.
static func transform_from_matrix(matrix: Variant) -> Transform3D:
	if not (matrix is Array) or (matrix as Array).size() < 3:
		return Transform3D.IDENTITY
	var rows: Array = matrix
	var m := []
	for r in range(3):
		if not (rows[r] is Array) or (rows[r] as Array).size() < 4:
			return Transform3D.IDENTITY
		m.append(rows[r])
	var basis := Basis(
		Vector3(float(m[0][0]), float(m[1][0]), float(m[2][0])),
		Vector3(float(m[0][1]), float(m[1][1]), float(m[2][1])),
		Vector3(float(m[0][2]), float(m[1][2]), float(m[2][2]))
	)
	var origin := Vector3(float(m[0][3]), float(m[1][3]), float(m[2][3]))
	return Transform3D(basis, origin)


## Bounds of `box` after `xform`. Written out rather than leaned on so the
## corner set is visible: a rotated box's bounds are the bounds of its corners,
## never the rotated bounds.
static func transform_aabb(xform: Transform3D, box: AABB) -> AABB:
	var lo := box.position
	var hi := box.position + box.size
	var mn := Vector3.INF
	var mx := -Vector3.INF
	for i in range(8):
		var corner := Vector3(
			hi.x if (i & 1) != 0 else lo.x,
			hi.y if (i & 2) != 0 else lo.y,
			hi.z if (i & 4) != 0 else lo.z
		)
		var p := xform * corner
		mn = mn.min(p)
		mx = mx.max(p)
	return AABB(mn, mx - mn)


# ---------------------------------------------------------------------------
# Feature edges — shared with mesh_display.gd, which draws the same outline
# for the evaluated solid
# ---------------------------------------------------------------------------

## Endpoint pairs of every feature edge in an indexed triangle soup: an edge
## used by one face (a boundary) or joining two faces that disagree by more
## than `angle_degrees`. Positions are welded on a quantised grid first, so the
## result depends on geometry rather than on how the tessellator numbered it.
static func feature_edge_segments(
	positions: PackedVector3Array,
	indices: PackedInt32Array,
	angle_degrees: float = FEATURE_EDGE_ANGLE_DEGREES
) -> PackedVector3Array:
	var segments := PackedVector3Array()
	if positions.is_empty() or indices.size() < 3:
		return segments

	var welded_id := {}          # Vector3i -> int
	var welded_point := PackedVector3Array()
	var edge_normals := {}       # Vector2i(lo, hi) -> Array[Vector3]

	var triangle_count := indices.size() / 3
	for t in range(triangle_count):
		var i0 := indices[t * 3]
		var i1 := indices[t * 3 + 1]
		var i2 := indices[t * 3 + 2]
		if i0 >= positions.size() or i1 >= positions.size() or i2 >= positions.size():
			continue
		var a := positions[i0]
		var b := positions[i1]
		var c := positions[i2]
		var normal := (b - a).cross(c - a)
		if normal.length_squared() <= 0.000001:
			continue
		normal = normal.normalized()

		var ka := _weld(welded_id, welded_point, a)
		var kb := _weld(welded_id, welded_point, b)
		var kc := _weld(welded_id, welded_point, c)
		_accumulate_edge(edge_normals, ka, kb, normal)
		_accumulate_edge(edge_normals, kb, kc, normal)
		_accumulate_edge(edge_normals, kc, ka, normal)

	var cosine_threshold := cos(deg_to_rad(angle_degrees))
	for key in edge_normals.keys():
		var normals: Array = edge_normals[key]
		if not _is_feature_edge(normals, cosine_threshold):
			continue
		var pair: Vector2i = key
		segments.append(welded_point[pair.x])
		segments.append(welded_point[pair.y])
	return segments


## Line mesh for a set of endpoint pairs, or null when there are none.
static func line_mesh_from_segments(segments: PackedVector3Array, color: Color) -> ArrayMesh:
	if segments.size() < 2:
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = segments

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


static func _weld(
	welded_id: Dictionary,
	welded_point: PackedVector3Array,
	point: Vector3
) -> int:
	var key := Vector3i(
		roundi(point.x * FEATURE_EDGE_QUANTIZE_SCALE),
		roundi(point.y * FEATURE_EDGE_QUANTIZE_SCALE),
		roundi(point.z * FEATURE_EDGE_QUANTIZE_SCALE)
	)
	var existing: Variant = welded_id.get(key, null)
	if existing != null:
		return int(existing)
	var id := welded_point.size()
	welded_point.append(point)
	welded_id[key] = id
	return id


static func _accumulate_edge(edge_normals: Dictionary, a: int, b: int, normal: Vector3) -> void:
	if a == b:
		return
	var key := Vector2i(min(a, b), max(a, b))
	var normals: Variant = edge_normals.get(key, null)
	if normals == null:
		edge_normals[key] = [normal]
		return
	(normals as Array).append(normal)


static func _is_feature_edge(normals: Array, cosine_threshold: float) -> bool:
	if normals.size() <= 1:
		return true
	var minimum_dot := 1.0
	for i in range(normals.size()):
		for j in range(i + 1, normals.size()):
			minimum_dot = min(minimum_dot, (normals[i] as Vector3).dot(normals[j] as Vector3))
	return minimum_dot < cosine_threshold


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

## Identity of the bytes on disk. Public so a test can see that the cache is
## keyed on content: a cache keyed on the path alone shows a stale board
## forever. Memoised only while mount_all is running; a direct call always
## hashes the file as it is now.
func file_stamp(absolute_path: String) -> String:
	if _stamp_memo.has(absolute_path):
		return str(_stamp_memo[absolute_path])
	var stamp := "missing"
	if FileAccess.file_exists(absolute_path):
		var digest := FileAccess.get_sha256(absolute_path)
		stamp = digest if not digest.is_empty() else "unreadable"
	if _in_mount:
		_stamp_memo[absolute_path] = stamp
	return stamp


## Read every mesh in a glTF/GLB and record it with its transform composed all
## the way up to the file's root. Composing matters: a glTF exported from
## millimetre data typically carries the 0.001 on a root node, and a walk that
## reads each node's own transform reports millimetres while calling them
## metres.
func _read_parts_from_file(
	absolute_path: String,
	loaded: LoadedFile,
	units: String,
	up: String
) -> Array:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var err := document.append_from_file(absolute_path, state, 0, absolute_path.get_base_dir())
	if err != OK:
		loaded.error = "could not read glTF '%s' (error %d)" % [absolute_path, err]
		return []

	var scene := document.generate_scene(state)
	if scene == null:
		loaded.error = "glTF '%s' produced no scene" % absolute_path
		return []

	var raw_parts: Array = []
	_collect_meshes(scene, Transform3D.IDENTITY, raw_parts)
	scene.free()

	# The file's own frame -> CAD frame, applied once, here, so that outlines
	# and bounds are computed in millimetres and everything downstream can
	# treat a part transform as CAD-local.
	var frame := conversion_transform(units, up, absolute_path)
	var have_bounds := false
	for raw in raw_parts:
		var mesh: Mesh = raw["mesh"]
		var to_cad: Transform3D = frame * (raw["transform"] as Transform3D)
		var box := transform_aabb(to_cad, mesh.get_aabb())
		loaded.parts.append({
			"mesh": mesh,
			"transform": to_cad,
			"node": str(raw.get("node", "")),
			"aabb": box,
		})

		loaded.local_aabb = box if not have_bounds else loaded.local_aabb.merge(box)
		have_bounds = true

		var outline := _outline_for(mesh, to_cad)
		if outline != null:
			loaded.outlines.append(outline)

	return loaded.parts


## Depth-first walk composing parent transforms. Only mesh nodes are taken:
## a glTF's lights and cameras are the file's own staging and have nothing to
## say about the CAD document that references it.
func _collect_meshes(node: Node, parent_transform: Transform3D, out: Array) -> void:
	var here := parent_transform
	if node is Node3D:
		here = parent_transform * (node as Node3D).transform

	var mesh := _mesh_of(node)
	if mesh != null and mesh.get_surface_count() > 0:
		out.append({"mesh": mesh, "transform": here, "node": str(node.name)})

	for child in node.get_children():
		_collect_meshes(child, here, out)


## MeshInstance3D and the importer's ImporterMeshInstance3D both answer
## get_mesh(); the latter answers with an ImporterMesh, which wraps the real
## one. Duck-typed so this file does not depend on the importer class existing.
func _mesh_of(node: Node) -> Mesh:
	if not node.has_method("get_mesh"):
		return null
	var candidate: Variant = node.call("get_mesh")
	if candidate is Mesh:
		return candidate
	if candidate != null and candidate is Object and (candidate as Object).has_method("get_mesh"):
		var inner: Variant = (candidate as Object).call("get_mesh")
		if inner is Mesh:
			return inner
	return null


## Feature edges for one mesh, in CAD-local millimetres. Extracted here, once,
## while the file is being read — never on a pose change and never per pane.
func _outline_for(mesh: Mesh, to_cad: Transform3D) -> ArrayMesh:
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
			positions.append(to_cad * v)
		var idx_var: Variant = arrays[Mesh.ARRAY_INDEX]
		if idx_var is PackedInt32Array and (idx_var as PackedInt32Array).size() >= 3:
			for i in (idx_var as PackedInt32Array):
				indices.append(base + i)
		else:
			for i in range(verts.size()):
				indices.append(base + i)

	return line_mesh_from_segments(
		feature_edge_segments(positions, indices),
		REFERENCE_EDGE_COLOR
	)


## One reference: a posed node holding the shaded bodies and the outline.
func _build_reference_node(loaded: LoadedFile, pose: Transform3D, reference_name: String) -> Node3D:
	var node := Node3D.new()
	node.name = "Reference_%s" % (reference_name if not reference_name.is_empty() else "unnamed")
	node.transform = pose

	var shaded := Node3D.new()
	shaded.name = SHADED_NODE_NAME
	node.add_child(shaded)
	for part in loaded.parts:
		var instance := MeshInstance3D.new()
		instance.mesh = part["mesh"]
		instance.transform = part["transform"]
		shaded.add_child(instance)

	var outline := Node3D.new()
	outline.name = OUTLINE_NODE_NAME
	node.add_child(outline)
	for line_mesh in loaded.outlines:
		var lines := MeshInstance3D.new()
		lines.mesh = line_mesh
		outline.add_child(lines)

	return node


func _layer(parent: Node3D, create: bool) -> Node3D:
	var existing := parent.get_node_or_null(LAYER_NODE_NAME)
	if existing != null:
		return existing as Node3D
	if not create:
		return null
	var layer := Node3D.new()
	layer.name = LAYER_NODE_NAME
	parent.add_child(layer)
	return layer
