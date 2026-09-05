## reference_reader.gd — reading one foreign mesh file, and knowing when it
## changed.
##
## Two jobs, both owned here so reference_meshes.gd holds only the library's
## public surface:
##
##   IDENTITY   `file_stamp` is what the cache is keyed on: a content digest
##              with a cheap mtime+size gate in front of it, so an unchanged
##              file costs an open and two queries rather than a hash of a
##              quarter of a gigabyte.
##   READ       `read_parts_from_file` turns a glTF/GLB or an STL into the list
##              of {mesh, transform} the rest of the library works in. The
##              per-format half is all that differs; the ceilings, the frame
##              conversion and the outlines are shared in `_convert_parts`, and
##              that is the seam an OBJ parser plugs into.
##
## The frame maths, the ceilings and the status vocabulary belong to the
## library that owns this reader; it is held untyped because typing it would
## mean preloading reference_meshes.gd, which preloads this file.
extends RefCounted

const _StlReader := preload("stl_reader.gd")

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

## The ReferenceMeshes that owns this reader: the ceilings, the frame maths and
## the status vocabulary are its.
var _library: Variant = null


func _init(library: Variant) -> void:
	_library = library


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


## Start and end one mount_all: within it a file is stamped once, however many
## viewports name it.
func begin_mount() -> void:
	_stamp_memo.clear()
	_in_mount = true


func end_mount() -> void:
	_in_mount = false
	_stamp_memo.clear()


## Forget every remembered stamp, so the next mount re-reads from disk.
func clear_stamps() -> void:
	_stamp_memo.clear()
	_stamp_cache.clear()


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


## Read every mesh in a glTF/GLB and record it with its transform composed all
## the way up to the file's root. Composing matters: a glTF exported from
## millimetre data typically carries the 0.001 on a root node, and a walk that
## reads each node's own transform reports millimetres while calling them
## metres.
func read_parts_from_file(
	absolute_path: String,
	loaded: LoadedFile,
	units: String,
	up: String
) -> Array:
	var raw_parts: Array = []
	if absolute_path.get_extension().to_lower() == "stl":
		raw_parts = _StlReader.read_parts(absolute_path, loaded, _library)
		if not loaded.error.is_empty():
			return []
	else:
		raw_parts = _read_gltf_parts(absolute_path, loaded)
		if not loaded.error.is_empty():
			return []
	return _convert_parts(absolute_path, loaded, units, up, raw_parts)


## The glTF half of the read: append the document, walk its scene, and hand
## back the parts in the FILE's frame.
func _read_gltf_parts(absolute_path: String, loaded: LoadedFile) -> Array:
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
		loaded.status = _library.STATUS_UNREADABLE
		loaded.error = "could not read glTF '%s' (error %d)" % [absolute_path, err]
		return []

	var scene := document.generate_scene(state)
	if scene == null:
		loaded.status = _library.STATUS_UNREADABLE
		loaded.error = "glTF '%s' produced no scene" % absolute_path
		return []

	var gltf_parts: Array = []
	_collect_meshes(scene, Transform3D.IDENTITY, gltf_parts, _file_names(state))
	scene.free()
	return gltf_parts


## Size ceilings, frame conversion, bounds and outlines — the same for every
## format, so both readers end here.
func _convert_parts(
	absolute_path: String,
	loaded: LoadedFile,
	units: String,
	up: String,
	raw_parts: Array
) -> Array:
	for raw in raw_parts:
		loaded.triangle_count += _library.triangle_count_of(raw["mesh"] as Mesh)
	if loaded.triangle_count > _library.max_triangles:
		loaded.status = _library.STATUS_OVERSIZE
		loaded.error = "reference has %d triangles, over the %d limit: %s" % [
			loaded.triangle_count, _library.max_triangles, absolute_path,
		]
		return []
	# Past the budget the shaded body still loads; only the feature-edge pass —
	# the one unbounded GDScript loop in the load — is skipped, so the cost of
	# a very large import stays native and the panel keeps its frame.
	loaded.outlines_skipped = loaded.triangle_count > _library.outline_triangle_budget
	if loaded.outlines_skipped:
		loaded.warning = (
			"reference has %d triangles, over the %d outline budget: "
			+ "showing it shaded without ortho outlines (%s)"
		) % [loaded.triangle_count, _library.outline_triangle_budget, absolute_path]

	# The file's own frame -> CAD frame, applied once, here, so that outlines
	# and bounds are computed in millimetres and everything downstream can
	# treat a part transform as CAD-local.
	var frame: Transform3D = _library.conversion_transform(units, up, absolute_path)
	var have_bounds := false
	for raw in raw_parts:
		var mesh: Mesh = raw["mesh"]
		var to_cad: Transform3D = frame * (raw["transform"] as Transform3D)
		var box: AABB = _library.transform_aabb(to_cad, mesh.get_aabb())
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

	return _library.line_mesh_from_segments(
		_library.feature_edge_segments(positions, indices),
		_library.REFERENCE_EDGE_COLOR
	)
