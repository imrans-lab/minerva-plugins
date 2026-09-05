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
## glTF/GLB and STL. The seam another format plugs into is
## reference_reader.gd's `read_parts_from_file`, which owes the rest of the
## library a list of {mesh, transform} in the FILE's own frame.
##
## Two halves are kept in their own files: reference_reader.gd reads a file and
## knows when it changed, reference_report.gd says what happened to each
## reference and builds the nodes for it. What is left here is the library's
## public surface, the ceilings and the frame maths both halves call back into.
extends RefCounted

const _Reader := preload("reference_reader.gd")
const _Report := preload("reference_report.gd")

## The read artefact and the reporting vocabulary are defined in those two
## modules and named here as well, because a caller holds the library.
const LoadedFile = _Reader.LoadedFile
const STATUS_OK: String = _Report.STATUS_OK
const STATUS_UNRESOLVED: String = _Report.STATUS_UNRESOLVED
const STATUS_MISSING: String = _Report.STATUS_MISSING
const STATUS_UNSUPPORTED: String = _Report.STATUS_UNSUPPORTED
const STATUS_UNREADABLE: String = _Report.STATUS_UNREADABLE
const STATUS_EMPTY: String = _Report.STATUS_EMPTY
const STATUS_OVERSIZE: String = _Report.STATUS_OVERSIZE
const MISSING_REFERENCE_COLOR: Color = _Report.MISSING_REFERENCE_COLOR
const MARKER_SIZE_MM: float = _Report.MARKER_SIZE_MM
const LAYER_NODE_NAME: String = _Report.LAYER_NODE_NAME
const SHADED_NODE_NAME: String = _Report.SHADED_NODE_NAME
const OUTLINE_NODE_NAME: String = _Report.OUTLINE_NODE_NAME
const MARKER_NODE_NAME: String = _Report.MARKER_NODE_NAME

## Reference formats the panel can read, and the ONE list of them: the file
## dialog, the import guard and the skill text all read it from here through
## mesh_import.gd. glTF states its own frame; STL states nothing, which is why
## an STL without units= is loaded AND warned about. OBJ joins the list when
## its parser lands.
const SUPPORTED_EXTENSIONS: Array = ["glb", "gltf", "stl"]

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

## The two halves, each holding the state its own job needs: the reader the
## content stamps, the reporter the records of the last mount.
var _reader: _Reader = null
var _report: _Report = null


func _init() -> void:
	_reader = _Reader.new(self)
	_report = _Report.new(self)


# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

func get_load_count() -> int:
	return _load_count


func clear_cache() -> void:
	_cache.clear()
	_reader.clear_stamps()


## Identity of the bytes on disk — a content digest, so a rewrite that keeps
## the length still reads as a change. Public so a test can see that the cache
## is keyed on content; the scheme that makes it cheap is the reader's.
func file_stamp(absolute_path: String) -> String:
	return _reader.file_stamp(absolute_path)


## Records for the references the last mount put geometry on screen for, and
## the same records for EVERY reference the evaluation named. Both are built
## and held by the reporter.
func mounted_references() -> Array:
	return _report.mounted_references()


func reference_records() -> Array:
	return _report.reference_records()


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
	if not SUPPORTED_EXTENSIONS.has(extension):
		return _fail(key, loaded, started, STATUS_UNSUPPORTED,
				"unsupported reference format '.%s' (%s only): %s" % [
					extension,
					"/".join(PackedStringArray(SUPPORTED_EXTENSIONS)),
					absolute_path,
				])

	loaded.byte_size = _Reader._byte_size(absolute_path)
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

	# STL carries no units and no up-axis, so a source that says nothing is
	# taking the default rather than reading the file. That guess is a silent
	# 25.4x when the file was authored in inches, so it is said out loud.
	if extension == "stl" and units.strip_edges().is_empty():
		loaded.warning = (
			"STL carries no units: '%s' was read as millimetres. "
			+ "Pass units= on the mesh() line to say otherwise."
		) % absolute_path

	var file_parts := _reader.read_parts_from_file(absolute_path, loaded, units, up)
	if not loaded.error.is_empty():
		return _fail(key, loaded, started, loaded.status, loaded.error)
	if file_parts.is_empty():
		return _fail(key, loaded, started, STATUS_EMPTY,
				"reference file holds no mesh geometry: %s" % absolute_path)

	loaded.load_ms = Time.get_ticks_msec() - started
	_cache[key] = loaded
	return loaded


func _fail(
	key: String,
	loaded: LoadedFile,
	started: int,
	status: String,
	reason: String
) -> LoadedFile:
	return _report.fail(_cache, key, loaded, started, status, reason)


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
	_reader.begin_mount()
	_report.begin_mount()
	var report := {}
	var first := true
	for parent in parents:
		report = _report.mount_under(references, document_path, parent as Node3D, first)
		first = false
	_reader.end_mount()
	return report


## Show or hide the shaded reference geometry under `parent`. The ortho panes
## are outline x-rays: the outlines stay, the shaded bodies go.
func set_shaded_visible(parent: Node3D, shaded_visible: bool) -> void:
	_report.set_shaded_visible(parent, shaded_visible)


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
##
## A triangle with no area contributes no normal — it has no plane to disagree
## with — but it is still counted as a USE of each of its edges. Skipping it
## outright leaves the neighbours of a sliver holding one normal each, which
## reads as a boundary, and a boolean cut that leaves a few slivers then
## speckles the middle of a flat face with short segments that only show in the
## panes drawing edges alone.
##
## `stats`, when passed, is filled with what the walk already knows about the
## mesh: {faces, degenerate_faces, open_edges, non_manifold_edges,
## duplicate_faces}. Free here; a second pass over the same triangles is not.
static func feature_edge_segments(
	positions: PackedVector3Array,
	indices: PackedInt32Array,
	angle_degrees: float = FEATURE_EDGE_ANGLE_DEGREES,
	stats: Dictionary = {}
) -> PackedVector3Array:
	var segments := PackedVector3Array()
	if positions.is_empty() or indices.size() < 3:
		return segments

	var welded_id := {}          # Vector3i -> int
	var welded_point := PackedVector3Array()
	var edge_normals := {}       # Vector2i(lo, hi) -> Array[Vector3]
	var edge_uses := {}          # Vector2i(lo, hi) -> int
	var face_uses := {}          # Vector3i(sorted welded corners) -> int
	var degenerate := 0

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
		var ka := _weld(welded_id, welded_point, a)
		var kb := _weld(welded_id, welded_point, b)
		var kc := _weld(welded_id, welded_point, c)
		_count_edge(edge_uses, ka, kb)
		_count_edge(edge_uses, kb, kc)
		_count_edge(edge_uses, kc, ka)
		var corners := [ka, kb, kc]
		corners.sort()
		var face_key := Vector3i(corners[0], corners[1], corners[2])
		face_uses[face_key] = int(face_uses.get(face_key, 0)) + 1

		var normal := (b - a).cross(c - a)
		if normal.length_squared() <= 0.000001:
			degenerate += 1
			continue
		normal = normal.normalized()
		_accumulate_edge(edge_normals, ka, kb, normal)
		_accumulate_edge(edge_normals, kb, kc, normal)
		_accumulate_edge(edge_normals, kc, ka, normal)

	var cosine_threshold := cos(deg_to_rad(angle_degrees))
	var open_edges := 0
	var non_manifold := 0
	for key in edge_uses.keys():
		var uses: int = int(edge_uses[key])
		if uses < 2:
			open_edges += 1
		elif uses > 2:
			non_manifold += 1
		var normals: Array = edge_normals.get(key, [])
		if not _is_feature_edge(normals, cosine_threshold, uses):
			continue
		var pair: Vector2i = key
		segments.append(welded_point[pair.x])
		segments.append(welded_point[pair.y])

	var duplicate_faces := 0
	for count in face_uses.values():
		duplicate_faces += int(count) - 1
	stats["faces"] = triangle_count
	stats["degenerate_faces"] = degenerate
	stats["open_edges"] = open_edges
	stats["non_manifold_edges"] = non_manifold
	stats["duplicate_faces"] = duplicate_faces
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


## Count a triangle against one of its edges, degenerate or not. This is what
## decides whether an edge is a boundary; the normals decide only the angle.
static func _count_edge(edge_uses: Dictionary, a: int, b: int) -> void:
	if a == b:
		return
	var key := Vector2i(min(a, b), max(a, b))
	edge_uses[key] = int(edge_uses.get(key, 0)) + 1


static func _accumulate_edge(edge_normals: Dictionary, a: int, b: int, normal: Vector3) -> void:
	if a == b:
		return
	var key := Vector2i(min(a, b), max(a, b))
	var normals: Variant = edge_normals.get(key, null)
	if normals == null:
		edge_normals[key] = [normal]
		return
	(normals as Array).append(normal)


## An edge is drawn when it bounds the surface (fewer than two triangles use
## it) or when the faces meeting there disagree by more than the threshold. An
## edge whose only other user had no area is neither: it is in the middle of a
## face, and drawing it puts a speck on a flat surface.
static func _is_feature_edge(normals: Array, cosine_threshold: float, uses: int = 0) -> bool:
	if uses > 0 and uses < 2:
		return true
	if normals.size() <= 1:
		return uses == 0
	var minimum_dot := 1.0
	for i in range(normals.size()):
		for j in range(i + 1, normals.size()):
			minimum_dot = min(minimum_dot, (normals[i] as Vector3).dot(normals[j] as Vector3))
	return minimum_dot < cosine_threshold
