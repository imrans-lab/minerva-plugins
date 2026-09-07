extends RefCounted
## clearance_blobs.gd — the content-addressed mesh store the measurement verbs
## hand the worker, and the channel they ask it over.
##
## WHY A FILE AND NOT THE MESSAGE. A panel→plugin IPC payload is capped at
## 64 KiB by the host broker (PluginScenePanelBroker.MAX_PAYLOAD_BYTES), and a
## 130k-triangle board's vertex arrays are megabytes. So reference triangles
## are transformed into world millimetres here, packed into a small binary
## blob, named by the SHA-256 of its own bytes and written next to the user's
## cache; the request carries only hashes, and geometry the worker already
## holds is named rather than re-sent — which is what makes the per-evaluation
## cost a hash lookup rather than a megabyte. Blobs no live reference hashes to
## and no call in flight has pinned are swept away on the next upload.
##
## The frame helpers below are read by every layer above: the key a
## (reference, node) pair is filed under, the node= filter rule every
## measurement verb follows, and the pose a named reference carries.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: extended by scripts/clearance_report.gd, and through it by
## every link above it in the one chain: clearance_client.gd,
## reference_pairs.gd, interference_report.gd, interference_world.gd,
## interference_containment.gd and geometry_checks.gd at the top.


const _WorkerReply: Script = preload("worker_reply.gd")


# ---------------------------------------------------------------------------
# Frame helpers — read by both halves
# ---------------------------------------------------------------------------

## The key a (reference, node) pair is folded under. Shared with the clearance
## join, which has to look a pair up by the same name the interference report
## filed it under.
func _pair_key(reference_name: String, node_path: String) -> String:
	return "%s\n%s" % [reference_name, node_path]


## Does this node path answer to the filter? A filter is either the PATH from
## the file root (one node) or a bare leaf name (every node carrying it) —
## the same rule every other measurement verb's node= follows.
func _node_matches(node_path: String, filter: String) -> bool:
	if filter.is_empty():
		return true
	return node_path == filter or node_path.get_file() == filter


## The pose a named reference carries in `records`; the clearance path reads
## its own snapshot of the records rather than the module's live pose.
func _pose_in(records: Array, reference_name: String) -> Transform3D:
	for entry in records:
		var record: Dictionary = entry
		if str(record.get("name", "")) == reference_name:
			return record.get("pose", Transform3D.IDENTITY)
	return Transform3D.IDENTITY


func _vector(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		var values: Array = raw
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.ZERO


func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


## The worker tessellates the solid and may build a 130k-triangle tree on the
## first call. Later calls are milliseconds. Used only where the panel cannot
## keep an await alive across chunks (see _ask_worker).
const CLEARANCE_TIMEOUT_MS: int = 60000
## One arm of the renewable await, and the total beyond which the worker is
## declared silent rather than slow. The tessellation a clearance pays for is
## unbounded — a lofted shell with a hundred booleans is minutes of OCCT — so
## the wait is re-armed rather than ended, or the panel pays for a measurement
## and drops the reply as stale.
const CLEARANCE_CHUNK_MS: int = 60000
const CLEARANCE_GIVE_UP_MS: int = 900000

## Mesh blob format, read by worker/mcad_worker/clearance.py. Little-endian:
## magic, uint32 version, uint32 vertex count, uint32 triangle count, then
## float32[3V] world millimetres and uint32[3F] indices. Godot's
## `to_byte_array()` is native order, which is little-endian on every target
## the plugin ships to.
const BLOB_MAGIC: String = "MCADMESH"
const BLOB_VERSION: int = 1
const BLOB_DIR_NAME: String = "minerva-cad-clearance"

## The blob BODIES, keyed by their own digest — content-addressed, exactly as
## the files are. Keying them by reference/node instead loses a body the
## moment that node is re-posed, and a call still in flight that pinned the
## old digest can then be asked to upload a body nobody has any more: its
## retry fails with "no cached geometry" for a digest it holds a pin on.
var _bodies: Dictionary = {}
## Which digest each reference/node currently hashes to, with the pose and
## mesh it was extracted from, so an unchanged reference is not walked again
## on the next evaluation. A slot points AT a body; it does not own one.
var _blobs: Dictionary = {}
## Directory the blobs are written to. Overridable so a suite can keep its
## files out of the user's cache.
var _blob_dir: String = ""
## Digests a clearance call now in flight has named, by how many calls name
## them. The sweep keeps these whatever the current document hashes to.
var _pinned_digests: Dictionary = {}


## Where the mesh blobs are written. The user's cache directory by default:
## the files are derived data, addressed by content hash, and a lost cache
## costs one re-upload.
func set_blob_dir(path: String) -> void:
	_blob_dir = path


## Each panel gets its OWN subdirectory. Blobs are content-addressed, so two
## panels showing the same board write identical bytes to identical names —
## but the sweep below knows only about THIS module's references, so a shared
## directory would let one document's check delete another's blobs mid-read.
## The cost of isolation: a directory left behind by a crashed session is not
## reclaimed by any peer; only its own panel ever deletes it.
func get_blob_dir() -> String:
	if _blob_dir.is_empty():
		var base := OS.get_cache_dir()
		if base.is_empty():
			base = OS.get_user_data_dir()
		_blob_dir = base.path_join(BLOB_DIR_NAME) \
			.path_join("panel-%d" % get_instance_id())
	return _blob_dir


## Hold the digests of every target in `batches` against the sweep, and hand
## back the list to drop again.
func _pin(batches: Array) -> PackedStringArray:
	var held := PackedStringArray()
	for batch_entry in batches:
		for target_entry in (batch_entry as Array):
			var digest := str((target_entry as Dictionary).get("key", ""))
			_pinned_digests[digest] = int(_pinned_digests.get(digest, 0)) + 1
			held.append(digest)
	return held


func _unpin(held: PackedStringArray) -> void:
	for digest in held:
		var remaining := int(_pinned_digests.get(digest, 0)) - 1
		if remaining > 0:
			_pinned_digests[digest] = remaining
		else:
			_pinned_digests.erase(digest)


## SHA-256 of a whole blob file, hex — the same hash its name is.
func _digest_of(raw: PackedByteArray) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(raw)
	return hasher.finish().hex_encode()


## The blob header, exactly as the file carries it and as the digest covers
## it: the magic, the version and the two counts, little-endian.
func _blob_header(vertices: int, triangles: int) -> PackedByteArray:
	var header := BLOB_MAGIC.to_utf8_buffer()
	var numbers := PackedInt32Array([BLOB_VERSION, vertices, triangles])
	header.append_array(numbers.to_byte_array())
	return header


func _blob_path(digest: String) -> String:
	return get_blob_dir().path_join(digest + ".mcadmesh")


## Send one measurement request through the panel's IPC helper and unwrap the
## host's two envelopes down to the worker's own result. Returns {error: ...}
## for every layer that can fail, so the caller has one shape to read.
##
## `channel` is the IPC channel, which is also the MCP tool name and names the
## worker method: reference-against-reference measurement (reference_pairs.gd)
## rides the same blob store and the same envelopes on a channel of its own.
func _ask_worker(panel: Object, payload: Dictionary,
		channel: String = "cad.clearance") -> Dictionary:
	# The measurement outlives the verb that started it, so the panel it was
	# handed can be gone by the time a batch is asked.
	if panel == null or not is_instance_valid(panel):
		return {"error": "the CAD panel closed while the clearance "
			+ "measurement was running"}
	var envelope: Dictionary = {}
	if panel.has_method("call_backend_until"):
		envelope = await panel.call_backend_until(channel, payload,
			CLEARANCE_CHUNK_MS, CLEARANCE_GIVE_UP_MS)
	elif panel.has_method("call_backend"):
		envelope = await panel.call_backend(
			channel, payload, CLEARANCE_TIMEOUT_MS)
	else:
		return {"error": "this panel cannot reach the CAD worker"}
	return _WorkerReply.unwrap(envelope, channel.trim_prefix("cad."))


# ---------------------------------------------------------------------------
# Mesh blobs
# ---------------------------------------------------------------------------

## The reference parts a scoped clearance question covers, as
## {reference, node, mesh, xform, pose}. Same node= rule as every other verb.
func _scoped_parts(records: Array, reference_scope: String,
		node_scope: String) -> Array:
	var out: Array = []
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
			out.append({
				"reference": reference_name,
				"node": node_path,
				"mesh": mesh,
				"xform": pose * (part.get("transform", Transform3D.IDENTITY) as Transform3D),
			})
	return out


## The blob for one part — {digest, body, vertices, triangles} — extracting it
## only when the mesh or its pose has changed since the last check. A board is
## a hundred thousand triangles and re-walking it on every keystroke would cost
## more than the measurement it feeds.
func _blob_for(part: Dictionary) -> Dictionary:
	var mesh: Mesh = part["mesh"]
	var xform: Transform3D = part["xform"]
	var slot := "%s\n%s" % [str(part["reference"]), str(part["node"])]
	var cached: Dictionary = _blobs.get(slot, {}) as Dictionary
	if not cached.is_empty() \
			and int(cached.get("mesh_id", 0)) == int(mesh.get_instance_id()) \
			and (cached.get("xform", Transform3D.IDENTITY) as Transform3D) == xform \
			and _bodies.has(str(cached.get("digest", ""))):
		return _bodies[str(cached["digest"])] as Dictionary
	var blob := _extract_blob(mesh, xform)
	if blob.is_empty():
		_blobs.erase(slot)
		return {}
	# The body lives under its digest; the slot only says which digest this
	# node currently hashes to. Re-posing the node moves the slot and leaves
	# the old body exactly where a pin can still find it.
	_bodies[str(blob["digest"])] = blob
	_blobs[slot] = {
		"digest": str(blob["digest"]),
		"mesh_id": int(mesh.get_instance_id()),
		"xform": xform,
	}
	return blob


## Every triangle of `mesh`, transformed into world millimetres, packed into
## the blob body and hashed. Returns {} for a mesh with no triangles.
##
## The body is float32, so every coordinate lands on a grid whose pitch is the
## float32 ulp at its magnitude: a hundredth of a micron at a few hundred
## millimetres, whole millimetres past a hundred million. That pitch is an
## error bar of its own, reported as quantization_mm with the coordinate that
## set it, and the caller refuses to measure to a tolerance finer than it.
func _extract_blob(mesh: Mesh, xform: Transform3D) -> Dictionary:
	var points := PackedFloat32Array()
	var indices := PackedInt32Array()
	var vertex_count := 0
	var largest := 0.0
	for surface in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var base := vertex_count
		for vertex in vertices:
			var world: Vector3 = xform * vertex
			points.append(world.x)
			points.append(world.y)
			points.append(world.z)
			largest = maxf(largest, maxf(absf(world.x),
				maxf(absf(world.y), absf(world.z))))
		vertex_count += vertices.size()
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
			var source: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for index in source:
				indices.append(base + index)
		else:
			# An unindexed surface is a triangle soup: the vertices are the
			# corners, in order.
			for i in range(vertices.size()):
				indices.append(base + i)
	var triangles := int(indices.size() / 3)
	if triangles <= 0 or vertex_count <= 0:
		return {}
	indices.resize(triangles * 3)

	var body := points.to_byte_array()
	body.append_array(indices.to_byte_array())
	# THE HEADER IS PART OF THE HASH. The same bytes mean different geometry
	# under different counts — three vertices with six indices and four
	# vertices with three read the same buffer as different triangles, the
	# index words decoding as coordinates — so a digest over the body alone
	# lets two different meshes share one key, in this panel's own store and
	# in the worker's cache. The header is written ahead of the body in the
	# file and hashed ahead of it here, in the same order and the same
	# little-endian encoding the worker reads back.
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(_blob_header(vertex_count, triangles))
	hasher.update(body)
	return {
		"digest": hasher.finish().hex_encode(),
		"body": body,
		"vertices": vertex_count,
		"triangles": triangles,
		"quantization_mm": float32_ulp(largest),
		"largest_coordinate_mm": largest,
	}


## The spacing between adjacent float32 values at magnitude `x`: 2^(e - 23)
## for the exponent e with 2^e <= |x| < 2^(e+1). The exponent is found by
## walking powers of two rather than by a logarithm, whose rounding at an exact
## power of two would pick the neighbouring binade. Zero for zero.
static func float32_ulp(x: float) -> float:
	var magnitude := absf(x)
	if magnitude <= 0.0:
		return 0.0
	var exponent := int(floor(log(magnitude) / log(2.0)))
	while pow(2.0, exponent + 1) <= magnitude:
		exponent += 1
	while pow(2.0, exponent) > magnitude:
		exponent -= 1
	return pow(2.0, exponent - 23)


## Write the blobs for `keys` where the worker can read them, and sweep away
## the ones nothing points at any more. Returns false if any write failed.
func _upload(keys: Array) -> bool:
	var directory := get_blob_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK \
			and not DirAccess.dir_exists_absolute(directory):
		return false
	var wanted := {}
	for entry in _blobs.values():
		wanted[str((entry as Dictionary).get("digest", ""))] = true
	for digest in _pinned_digests.keys():
		wanted[str(digest)] = true
	for key in keys:
		var digest := str(key)
		var blob := _blob_with_digest(digest)
		if blob.is_empty():
			return false
		if not _write_blob_once(digest, blob):
			return false
	_sweep(directory, wanted)
	return true


## Write one blob, ONCE. A content-addressed file never changes: a name is a
## hash of the bytes, so a file already there under that name is already the
## right file and re-writing it can only make it briefly wrong. Two calls
## uploading the same digest at the same time would otherwise have one of them
## truncate the file the other has just handed the worker, and the worker
## would refuse a hash that was correct a moment earlier.
##
## When the file is missing it is written under a temporary name and RENAMED,
## which is atomic on every filesystem this runs on: a reader either sees no
## file or sees the whole one, never a prefix of it.
func _write_blob_once(digest: String, blob: Dictionary) -> bool:
	var path := _blob_path(digest)
	var header := _blob_header(int(blob["vertices"]), int(blob["triangles"]))
	var body: PackedByteArray = blob["body"]
	var expected := header.size() + body.size()
	if FileAccess.file_exists(path):
		# The name is a hash, so the bytes are the only thing that can prove
		# the file under it is the file. A corrupted or half-written blob of
		# the RIGHT LENGTH would otherwise be reused for the rest of the
		# session: the worker refuses its hash, the caller retries, the same
		# bytes are reused again, and the check never recovers.
		var existing := FileAccess.open(path, FileAccess.READ)
		if existing != null:
			var raw := existing.get_buffer(int(existing.get_length()))
			existing.close()
			if raw.size() == expected and _digest_of(raw) == digest:
				return true
		# Not the file its name claims: a leftover from an interrupted write
		# or a damaged cache, never somebody else's geometry. Replace it.
		DirAccess.remove_absolute(path)
	var temporary := "%s.%d.part" % [path, Time.get_ticks_usec()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(header)
	file.store_buffer(body)
	file.close()
	if DirAccess.rename_absolute(temporary, path) != OK:
		# Somebody else finished first: their file is the same bytes under the
		# same hash, so the upload has still happened.
		DirAccess.remove_absolute(temporary)
		return FileAccess.file_exists(path)
	return true


## Delete blobs in `directory` that no live reference hashes to and no call in
## flight has pinned. Content-addressed files never go stale, they only pile
## up; this keeps the directory the size of the document rather than the size
## of the session.
func _sweep(directory: String, wanted: Dictionary) -> void:
	# The bodies go the same way as the files: a body no live node hashes to
	# and no call in flight has pinned is one nobody can ask for again.
	for digest in _bodies.keys():
		if not wanted.has(str(digest)):
			_bodies.erase(digest)
	var names := DirAccess.get_files_at(directory)
	for name in names:
		if name.ends_with(".part"):
			# A write in flight, or one that died: neither is this sweep's
			# business, and deleting it would race the writer.
			continue
		if not name.ends_with(".mcadmesh"):
			continue
		if wanted.has(name.get_basename()):
			continue
		DirAccess.remove_absolute(directory.path_join(name))


func _blob_with_digest(digest: String) -> Dictionary:
	return _bodies.get(digest, {}) as Dictionary
