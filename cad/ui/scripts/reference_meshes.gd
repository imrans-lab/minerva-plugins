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

## Colour of the placeholder drawn where a reference could not be loaded.
## Warm, saturated and nothing like the reference outline, because the whole
## point of the marker is that it is not mistaken for geometry.
const MISSING_REFERENCE_COLOR: Color = Color(0.90, 0.45, 0.10, 1.0)
## Edge length of that placeholder, in millimetres. A fixed size rather than a
## proportional one: the body it stands in for has no size, and 20 mm is
## visible at the zoom a board is looked at without swamping it.
const MARKER_SIZE_MM: float = 20.0

## What happened to one reference. Reported per reference, so the LLM asking
## about the scene gets a reason rather than a shorter list than it expected.
const STATUS_OK: String = "ok"
const STATUS_UNRESOLVED: String = "unresolved"
const STATUS_MISSING: String = "missing"
const STATUS_UNSUPPORTED: String = "unsupported"
const STATUS_UNREADABLE: String = "unreadable"
const STATUS_EMPTY: String = "empty"
const STATUS_OVERSIZE: String = "oversize"

## SIZE CEILINGS.
##
## The only per-triangle work this module does in GDScript is the feature-edge
## pass; the glTF parse and the draw are native. So the ceilings sit where the
## cost actually is, and there are three of them because the three costs are
## paid at different moments:
##
##   MAX_FILE_BYTES          refused BEFORE the file is opened, so a mesh()
##                           pointed at a video or a disk image never reaches
##                           the importer at all. A .gltf is measured together
##                           with the external buffers its JSON names, since
##                           the geometry lives there, not in the .gltf.
##   OUTLINE_TRIANGLE_BUDGET the mesh still loads, still renders shaded and is
##                           still measurable — only the ortho x-ray outline is
##                           skipped, with a warning naming the count. This is
##                           the one that keeps a huge file from freezing the
##                           panel, because it is the only unbounded GDScript
##                           loop in the load.
##   MAX_TRIANGLES           refused after the native parse and before any
##                           CAD-side work (conversion, outlines, colliders),
##                           stating the numbers. The parse itself is bounded
##                           by MAX_FILE_BYTES, not by this.
##
## The numbers: the case this feature exists for is a fabricated-board export
## of ~130k triangles, whose edge pass is ~1M dictionary operations — a few
## hundred milliseconds, once, then cached against the file's content. The
## outline budget is set just above that so the intended case keeps its x-ray
## and an order-of-magnitude-larger import degrades instead of hanging. The
## hard triangle ceiling is where the shaded body alone costs hundreds of
## megabytes of vertex data for geometry nobody can edit.
const OUTLINE_TRIANGLE_BUDGET: int = 250000
const MAX_TRIANGLES: int = 5000000
const MAX_FILE_BYTES: int = 268435456  # 256 MiB

## Child of a MeshRoot that holds every mounted reference.
const LAYER_NODE_NAME: String = "ReferenceRoot"
## Per-reference containers inside a reference node.
const SHADED_NODE_NAME: String = "Shaded"
const OUTLINE_NODE_NAME: String = "Outline"
## Container for the placeholder of a reference that failed to load.
const MARKER_NODE_NAME: String = "Missing"


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
	## One of the STATUS_* names — why `error` is set, in a form a caller can
	## branch on instead of matching prose. Spelled out rather than written as
	## STATUS_OK: an inner class does not see the outer script's constants.
	var status: String = "ok"
	## Set when the file loaded but something about it should be said out loud:
	## the outline budget, so far.
	var warning: String = ""
	## Measured size of what was read. Reported whether or not a ceiling was
	## hit, because "it is big" is only useful next to the number.
	var triangle_count: int = 0
	var byte_size: int = 0
	## Wall time the read took, milliseconds. The load is a single bounded
	## hitch by design (see the ceilings); this is how anyone checks that claim
	## rather than believing it.
	var load_ms: int = 0
	## True when the triangle count was over the outline budget, so the ortho
	## panes show this body shaded-only.
	var outlines_skipped: bool = false

	func is_ok() -> bool:
		return error.is_empty() and not parts.is_empty()

	## Bounds per node, in CAD-local millimetres, keyed by the node's PATH from
	## the file root. A node split across several glTF primitives (one per
	## material) is merged back into one entry, because the split is an
	## artefact of the exporter, not a fact about the part — but two nodes that
	## merely share a leaf name in different branches are two parts and are
	## never merged. Each row carries both `path` (the identity) and `name`
	## (the leaf, which several rows may share).
	func node_bounds() -> Array:
		var order: Array = []
		var merged := {}
		var names := {}
		for entry in parts:
			var part: Dictionary = entry
			var node_name := str(part.get("node", ""))
			var node_path := str(part.get("node_path", node_name))
			var box: AABB = part.get("aabb", AABB())
			if merged.has(node_path):
				merged[node_path] = (merged[node_path] as AABB).merge(box)
			else:
				merged[node_path] = box
				names[node_path] = node_name
				order.append(node_path)
		var out: Array = []
		for node_path in order:
			out.append({
				"name": str(names[node_path]),
				"path": node_path,
				"aabb": merged[node_path],
			})
		return out


## The ceilings, held as instance values rather than read straight from the
## constants, so the size logic can be exercised against a fixture a test is
## able to build. Nothing in the panel writes them.
var outline_triangle_budget: int = OUTLINE_TRIANGLE_BUDGET
var max_triangles: int = MAX_TRIANGLES
var max_file_bytes: int = MAX_FILE_BYTES

var _cache: Dictionary = {}
## How many times a file has actually been read off disk. The pose changing
## must not move this number; the file changing must.
var _load_count: int = 0
## A file modified this recently is re-hashed regardless of its cheap
## identity: modification times have one-second resolution, so a rewrite in the
## same second that keeps the length would otherwise read as unchanged.
const STAMP_SETTLE_SECONDS: float = 2.0

## Stamps computed during the current mount_all call, keyed by absolute path.
var _stamp_memo: Dictionary = {}
var _in_mount: bool = false
## Absolute path -> {mtime, size, stamp}: the digest that was computed when the
## file last had that modification time and length. This is what keeps a
## keystroke from re-hashing a quarter of a gigabyte.
var _stamp_cache: Dictionary = {}
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
	_stamp_cache.clear()


## Records for the references the last mount actually put geometry on screen
## for: {name, path, resolved_path, units, up, status, reason, warning, stamp, pose,
## local_aabb, world_aabb, triangle_count, bytes, load_ms, outlines_skipped,
## parts, node_bounds}. `parts` is the cached, converted geometry — shared, not
## copied — so a caller that wants colliders or a segmentation reads it
## straight from here.
func mounted_references() -> Array:
	var out: Array = []
	for entry in _mounted:
		if str((entry as Dictionary).get("status", STATUS_OK)) == STATUS_OK:
			out.append(entry)
	return out


## The same records for EVERY reference the last evaluation named, in that
## order, whether or not its file could be read. A reference that failed is
## still a fact about the document — it has a name, a path, a pose and a
## marker in the world — and a caller that only ever sees the ones that
## worked gets a shorter list with no explanation for it.
func reference_records() -> Array:
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
	# The ceilings are part of the key because they decide the result: a
	# refusal cached under a lower limit must not answer for a higher one.
	var key := "%s|%s|%s|%d|%d|%d" % [
		absolute_path,
		units.to_lower(),
		up.to_lower(),
		outline_triangle_budget,
		max_triangles,
		max_file_bytes,
	]
	var cached: LoadedFile = _cache.get(key, null)
	if cached != null and cached.stamp == stamp:
		return cached

	var started := Time.get_ticks_msec()
	var loaded := LoadedFile.new()
	loaded.path = absolute_path
	loaded.stamp = stamp
	_load_count += 1

	if not FileAccess.file_exists(absolute_path):
		return _fail(key, loaded, started, STATUS_MISSING,
				"reference file not found: %s" % absolute_path)

	var extension := absolute_path.get_extension().to_lower()
	if extension != "glb" and extension != "gltf":
		return _fail(key, loaded, started, STATUS_UNSUPPORTED,
				"unsupported reference format '.%s' (glTF/GLB only): %s" % [
					extension, absolute_path,
				])

	loaded.byte_size = _byte_size(absolute_path)
	# Checked before the importer is handed the path: this is the ceiling that
	# stops a wrong path costing minutes rather than milliseconds.
	if loaded.byte_size > max_file_bytes:
		return _fail(key, loaded, started, STATUS_OVERSIZE,
				"reference file is %d bytes (%.1f MB), over the %d byte limit: %s" % [
					loaded.byte_size,
					loaded.byte_size / 1048576.0,
					max_file_bytes,
					absolute_path,
				])

	var file_parts := _read_parts_from_file(absolute_path, loaded, units, up)
	if not loaded.error.is_empty():
		return _fail(key, loaded, started, loaded.status, loaded.error)
	if file_parts.is_empty():
		return _fail(key, loaded, started, STATUS_EMPTY,
				"reference file holds no mesh geometry: %s" % absolute_path)

	loaded.load_ms = Time.get_ticks_msec() - started
	_cache[key] = loaded
	return loaded


## Record a failure on `loaded`, cache it and hand it back. Failures are cached
## like successes so a missing file is not re-stat-ed on every keystroke.
func _fail(
	key: String,
	loaded: LoadedFile,
	started: int,
	status: String,
	reason: String
) -> LoadedFile:
	loaded.status = status
	loaded.error = reason
	loaded.parts = []
	loaded.outlines = []
	loaded.load_ms = Time.get_ticks_msec() - started
	_cache[key] = loaded
	return loaded


## Length of a file in bytes, or 0 when it cannot be opened.
static func _byte_size(absolute_path: String) -> int:
	var handle := FileAccess.open(absolute_path, FileAccess.READ)
	if handle == null:
		return 0
	var length := int(handle.get_length())
	handle.close()
	if absolute_path.get_extension().to_lower() == "gltf":
		length += _external_buffer_bytes(absolute_path)
	return length


## Bytes of the files a .gltf names outside itself. A data: URI is already
## counted by the file's own length; a side file that cannot be opened counts
## as zero and fails later, by name, in the importer.
static func _external_buffer_bytes(gltf_path: String) -> int:
	var total := 0
	for side in _external_file_paths(gltf_path):
		var handle := FileAccess.open(str(side), FileAccess.READ)
		if handle != null:
			total += int(handle.get_length())
			handle.close()
	return total


## Triangles in a mesh, counted over its triangle surfaces only. This is the
## number every size decision and every size message is made of.
static func triangle_count_of(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for surface in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices is PackedInt32Array:
			total += (indices as PackedInt32Array).size() / 3
			continue
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if verts is PackedVector3Array:
			total += (verts as PackedVector3Array).size() / 3
	return total


## Build (or rebuild) the reference layer under `parent` from an evaluation's
## `references` array. Returns {world_aabb, warnings, errors, mounted, marked,
## statuses, status_lines}.
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
	var lines := PackedStringArray()
	var statuses: Array = []
	var mounted := 0
	var marked := 0
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
			var reference_name := str(reference.get("name", ""))
			var pose := transform_from_matrix(reference.get("matrix", []))
			var state := {
				"name": reference_name,
				"path": str(reference.get("path", "")),
				"resolved_path": "",
				# units and up are baked into parts[].transform, so anything
				# keyed on the geometry has to key on them as well.
				"units": str(reference.get("units", "")).to_lower(),
				"up": str(reference.get("up", "")).to_lower(),
				"status": STATUS_OK,
				"reason": "",
				"warning": "",
				"stamp": "",
				"pose": pose,
				"local_aabb": AABB(),
				"world_aabb": AABB(),
				"triangle_count": 0,
				"bytes": 0,
				"load_ms": 0,
				"outlines_skipped": false,
				"parts": [],
				"node_bounds": [],
			}

			var resolved := resolve(str(reference.get("path", "")), document_path)
			if not str(resolved["warning"]).is_empty():
				warnings.append(str(resolved["warning"]))
				state["warning"] = str(resolved["warning"])
			var loaded: LoadedFile = null
			if str(resolved["error"]).is_empty():
				state["resolved_path"] = str(resolved["path"])
				# The unit and up-axis conversion is baked into the cached
				# parts, so what is left to apply per evaluation is the pose,
				# nothing else.
				loaded = load_file(
					str(resolved["path"]),
					str(reference.get("units", "")),
					str(reference.get("up", ""))
				)
				state["stamp"] = loaded.stamp
				state["triangle_count"] = loaded.triangle_count
				state["bytes"] = loaded.byte_size
				state["load_ms"] = loaded.load_ms
				state["outlines_skipped"] = loaded.outlines_skipped
			else:
				state["status"] = STATUS_UNRESOLVED
				state["reason"] = str(resolved["error"])

			if loaded != null and not loaded.is_ok():
				state["status"] = loaded.status
				state["reason"] = loaded.error

			var world := AABB()
			if str(state["status"]) == STATUS_OK:
				layer.add_child(_build_reference_node(loaded, pose, reference_name))
				world = transform_aabb(pose, loaded.local_aabb)
				state["local_aabb"] = loaded.local_aabb
				state["parts"] = loaded.parts
				state["node_bounds"] = loaded.node_bounds()
				if not loaded.warning.is_empty():
					# A resolution warning (absolute path) and a size warning
					# can both apply; keep both.
					var prior := str(state.get("warning", ""))
					state["warning"] = loaded.warning if prior.is_empty() else prior + " " + loaded.warning
					warnings.append(loaded.warning)
					lines.append("%s — %s" % [_label(reference_name), loaded.warning])
				mounted += 1
			else:
				# A failed reference is still drawn: a placeholder at the pose
				# the document asked for. Without it the body is simply absent
				# and the only evidence is a line of text somewhere else.
				layer.add_child(_build_marker_node(pose, reference_name))
				world = transform_aabb(pose, _marker_bounds())
				errors.append(str(state["reason"]))
				lines.append("%s — %s" % [_label(reference_name), str(state["reason"])])
				marked += 1

			state["world_aabb"] = world
			bounds = world if not have_bounds else bounds.merge(world)
			have_bounds = true

			statuses.append({
				"name": state["name"],
				"path": state["path"],
				"resolved_path": state["resolved_path"],
				"status": state["status"],
				"reason": state["reason"],
				"warning": state["warning"],
				"triangle_count": state["triangle_count"],
				"bytes": state["bytes"],
				"load_ms": state["load_ms"],
				"outlines_skipped": state["outlines_skipped"],
			})
			if record:
				_mounted.append(state)

	return {
		"world_aabb": bounds,
		"warnings": warnings,
		"errors": errors,
		"mounted": mounted,
		"marked": marked,
		"statuses": statuses,
		"status_lines": lines,
	}


## How a reference is named in a message: its own name when the document gave
## it one, and the word otherwise — never an empty string, which reads as a
## broken message rather than as an unnamed reference.
static func _label(reference_name: String) -> String:
	return reference_name if not reference_name.is_empty() else "reference"


## Bounds of the placeholder, centred on the pose origin.
static func _marker_bounds() -> AABB:
	var half := MARKER_SIZE_MM * 0.5
	return AABB(Vector3(-half, -half, -half), Vector3.ONE * MARKER_SIZE_MM)


## The placeholder for a reference that could not be loaded: a wireframe cube
## with an axis cross through it, at the pose the document asked for. Lines
## rather than a solid, so it reads as a marker in the ortho x-ray panes and in
## the shaded one alike, and so it cannot be mistaken for the missing body.
func _build_marker_node(pose: Transform3D, reference_name: String) -> Node3D:
	var node := Node3D.new()
	node.name = "Reference_%s" % _label(reference_name)
	node.transform = pose

	var marker := Node3D.new()
	marker.name = MARKER_NODE_NAME
	node.add_child(marker)

	var half := MARKER_SIZE_MM * 0.5
	var segments := PackedVector3Array()
	for axis in range(3):
		for corner in range(4):
			var a := Vector3.ZERO
			var b := Vector3.ZERO
			var u := (axis + 1) % 3
			var v := (axis + 2) % 3
			a[axis] = -half
			b[axis] = half
			a[u] = half if (corner & 1) != 0 else -half
			b[u] = a[u]
			a[v] = half if (corner & 2) != 0 else -half
			b[v] = a[v]
			segments.append(a)
			segments.append(b)
	for axis in range(3):
		var a := Vector3.ZERO
		var b := Vector3.ZERO
		a[axis] = -half
		b[axis] = half
		segments.append(a)
		segments.append(b)

	var lines := MeshInstance3D.new()
	lines.mesh = line_mesh_from_segments(segments, MISSING_REFERENCE_COLOR)
	marker.add_child(lines)
	return node


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
## forever.
##
## The digest is the contract, but hashing is not free — the document is
## re-evaluated on a debounced keystroke and the ceiling on a reference file is
## a quarter of a gigabyte. So the hash is computed only when the cheap
## identity (modification time and length) has changed, or when the file was
## touched within the last couple of seconds: a rewrite inside the same
## second-resolution timestamp that happens to preserve the length would
## otherwise be invisible. An unchanged, settled file costs an open and two
## queries.
func file_stamp(absolute_path: String) -> String:
	if _stamp_memo.has(absolute_path):
		return str(_stamp_memo[absolute_path])
	var stamp := _stamp_uncached(absolute_path)
	if _in_mount:
		_stamp_memo[absolute_path] = stamp
	return stamp


## A .gltf is a JSON manifest plus the files it names: the geometry lives in
## `buffers[].uri` and the materials in `images[].uri`. Rewriting the .bin
## beside an unchanged .gltf changes the mesh and nothing else, so a stamp over
## the JSON alone serves that geometry forever. The stamp of a .gltf is
## therefore the digest of the manifest combined with the digest of every
## external file it names, each one taken through the same two-level
## mtime+size -> sha scheme so an unchanged side file still costs no hashing.
func _stamp_uncached(absolute_path: String) -> String:
	var own := _file_digest(absolute_path)
	if absolute_path.get_extension().to_lower() != "gltf":
		return own
	if own == "missing" or own == "unreadable":
		return own
	var combined := own
	for side in _external_file_paths(absolute_path):
		combined += "|" + str(side) + ":" + _file_digest(str(side))
	return combined.sha256_text()


## Files a .gltf names outside itself, resolved beside it and de-duplicated:
## the buffers hold the geometry, the images the materials. A data: URI is
## inside the JSON already and is not listed.
static func _external_file_paths(gltf_path: String) -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(gltf_path))
	if not (parsed is Dictionary):
		return []
	var base := gltf_path.get_base_dir()
	var out: Array = []
	for key in ["buffers", "images"]:
		for entry in (parsed as Dictionary).get(key, []):
			if not (entry is Dictionary):
				continue
			var uri := str((entry as Dictionary).get("uri", ""))
			if uri.is_empty() or uri.begins_with("data:"):
				continue
			var resolved := base.path_join(uri.uri_decode()).simplify_path()
			if not (resolved in out):
				out.append(resolved)
	out.sort()
	return out


## Content digest of one file, with the cheap-identity cache in front of it.
func _file_digest(absolute_path: String) -> String:
	if not FileAccess.file_exists(absolute_path):
		_stamp_cache.erase(absolute_path)
		return "missing"
	var handle := FileAccess.open(absolute_path, FileAccess.READ)
	if handle == null:
		_stamp_cache.erase(absolute_path)
		return "unreadable"
	var size := int(handle.get_length())
	handle = null
	var mtime := int(FileAccess.get_modified_time(absolute_path))
	var settled: bool = Time.get_unix_time_from_system() - float(mtime) > STAMP_SETTLE_SECONDS
	var cached: Dictionary = _stamp_cache.get(absolute_path, {})
	if settled and not cached.is_empty() \
			and int(cached.get("mtime", -1)) == mtime \
			and int(cached.get("size", -1)) == size:
		return str(cached.get("stamp", ""))
	var digest := FileAccess.get_sha256(absolute_path)
	var stamp: String = digest if not digest.is_empty() else "unreadable"
	# A digest taken while the file is still being written may already be
	# stale by the time the same mtime and size are seen again; only a settled
	# file earns a cache entry.
	if settled:
		_stamp_cache[absolute_path] = {"mtime": mtime, "size": size, "stamp": stamp}
	else:
		_stamp_cache.erase(absolute_path)
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
	# Two distinct failure shapes, and a file that is not what its extension
	# claims lands on either one depending on how far the importer gets: a
	# truncated GLB fails the header check and returns an error code, while
	# some malformed-but-parseable documents come back OK with no scene at all.
	# Both are reported; neither is allowed to reach the caller as an empty
	# success.
	var err := document.append_from_file(absolute_path, state, 0, absolute_path.get_base_dir())
	if err != OK:
		loaded.status = STATUS_UNREADABLE
		loaded.error = "could not read glTF '%s' (error %d)" % [absolute_path, err]
		return []

	var scene := document.generate_scene(state)
	if scene == null:
		loaded.status = STATUS_UNREADABLE
		loaded.error = "glTF '%s' produced no scene" % absolute_path
		return []

	var raw_parts: Array = []
	_collect_meshes(scene, Transform3D.IDENTITY, raw_parts, _file_names(state))
	scene.free()

	for raw in raw_parts:
		loaded.triangle_count += triangle_count_of(raw["mesh"] as Mesh)
	if loaded.triangle_count > max_triangles:
		loaded.status = STATUS_OVERSIZE
		loaded.error = "reference has %d triangles, over the %d limit: %s" % [
			loaded.triangle_count, max_triangles, absolute_path,
		]
		return []
	# Past the budget the shaded body still loads; only the feature-edge pass —
	# the one unbounded GDScript loop in this file — is skipped, so the cost of
	# a very large import stays native and the panel keeps its frame.
	loaded.outlines_skipped = loaded.triangle_count > outline_triangle_budget
	if loaded.outlines_skipped:
		loaded.warning = (
			"reference has %d triangles, over the %d outline budget: "
			+ "showing it shaded without ortho outlines (%s)"
		) % [loaded.triangle_count, outline_triangle_budget, absolute_path]

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
			"node_path": str(raw.get("node_path", raw.get("node", ""))),
			"aabb": box,
		})

		loaded.local_aabb = box if not have_bounds else loaded.local_aabb.merge(box)
		have_bounds = true

		if not loaded.outlines_skipped:
			var outline := _outline_for(mesh, to_cad)
			if outline != null:
				loaded.outlines.append(outline)

	return loaded.parts


## Depth-first walk composing parent transforms. Only mesh nodes are taken:
## a glTF's lights and cameras are the file's own staging and have nothing to
## say about the CAD document that references it.
##
## Every part carries its PATH from the file root as well as its leaf name.
## Foreign assemblies reuse leaf names freely — two branches each holding a
## node called "Body" is ordinary — and a leaf name alone cannot tell them
## apart, so bounds get merged, a filter selects both and a contact is
## attributed to whichever came first. The path is the identity; the leaf name
## stays as the convenient handle. The root itself contributes no segment, so a
## flat file's path is just the node's name.
func _collect_meshes(
	node: Node,
	parent_transform: Transform3D,
	out: Array,
	file_names: Dictionary = {},
	parent_path: String = "",
	depth: int = 0,
	taken: Dictionary = {}
) -> void:
	var here := parent_transform
	if node is Node3D:
		here = parent_transform * (node as Node3D).transform
	var segment := str(file_names.get(str(node.name), str(node.name)))
	# Depth 0 is the file root and contributes no segment.
	var path := ""
	if depth > 0:
		path = segment if parent_path.is_empty() else parent_path + "/" + segment
		path = _unique_path(taken, path)

	var mesh := _mesh_of(node)
	if mesh != null and mesh.get_surface_count() > 0:
		out.append({
			"mesh": mesh,
			"transform": here,
			"node": segment,
			"node_path": path if not path.is_empty() else segment,
		})

	for child in node.get_children():
		_collect_meshes(child, here, out, file_names, path, depth + 1, taken)


## Keep node_path unique. Putting the file's own names back can make two
## SIBLINGS share a path — a branch holding two nodes the file both calls
## "Body" — and a path that names two nodes is not an identity: bounds merge
## and a filter picks whichever came first. The second and later claimants get
## a "#n" suffix in walk order, so the first one keeps the plain path the file
## shows and the numbering is stable for a given file.
func _unique_path(taken: Dictionary, path: String) -> String:
	if not taken.has(path):
		taken[path] = 1
		return path
	var count := int(taken[path]) + 1
	taken[path] = count
	return "%s#%d" % [path, count]


## Generated node name -> the name the FILE gave that node.
##
## The glTF importer makes every node name unique across the whole document,
## so a file with a "Body" in two branches produces "Body" and "Body2" in the
## scene and a caller that types the path the file shows it gets no match. The
## uniquified name is what generate_scene() puts on the node, so it is the key;
## GLTFNode.original_name is the name the file actually carries.
func _file_names(state: GLTFState) -> Dictionary:
	var names := {}
	for entry in state.get_nodes():
		var gltf_node: GLTFNode = entry
		var original := str(gltf_node.original_name)
		if original.is_empty():
			continue
		names[str(gltf_node.get_name())] = original
	return names


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
	node.name = "Reference_%s" % _label(reference_name)
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
