extends RefCounted
## clearance_client.gd — the clearance half of the geometry checks.
##
## Split out of geometry_checks.gd, which had grown to hold two whole
## subsystems: the ray-walk interference check that runs inside a physics step,
## and this one — a worker round trip over a content-addressed blob cache. They
## share nothing but the small frame helpers below and the pair key the join is
## filed under.
##
## THE SPLIT IS AN INHERITANCE, NOT A HANDLE. geometry_checks.gd extends this
## script, so one object still carries both halves' public surface: the panel,
## panel_tools and fastener_checks all hold a single geometry-checks instance,
## and the blob directory is named after that instance. A second object would
## have renamed the directory and given every caller two things to hold.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: extended by scripts/geometry_checks.gd.


const _WorkerReply: Script = preload("worker_reply.gd")
const _MeshGauge: Script = preload("mesh_gauge.gd")

## The phrase every unbounded-tolerance pass_reason is built from, and the one
## the status line reads back to tell that cause from a join failure.
const UNBOUNDED_TOLERANCE_REASON := "tessellation tolerance is not guaranteed"


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


## The pose a named reference carries in `records`. Split out so the clearance
## path can work from its own snapshot rather than the module's.
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


# ---------------------------------------------------------------------------
# Clearance — how much air is there?
# ---------------------------------------------------------------------------
#
# Interference answers "do these touch"; clearance answers "by how much do
# they miss", which is the number a wall thickness is edited against. It is a
# different computation and it does not belong in the ray walk above: the
# minimum distance between two meshes is a minimum over TRIANGLE PAIRS, and no
# number of rays finds the gap between two triangle interiors. The worker owns
# it, over a swept-sphere BVH (python-fcl), and answers exactly.
#
# WHAT THIS SIDE OWNS. The panel is the only thing that knows what a reference
# is: which file, in which units, posed by which matrix. So it hands the worker
# triangles already in world millimetres and gets back numbers it re-frames
# into each reference's own coordinates. The worker never opens a mesh file.
#
# WHY A FILE AND NOT THE MESSAGE. A panel→plugin IPC payload is capped at
# 64 KiB by the host broker (PluginScenePanelBroker.MAX_PAYLOAD_BYTES); a
# 130k-triangle board's arrays are megabytes. The arrays therefore travel as a
# small binary blob written next to the user's cache, named by the SHA-256 of
# its own array bytes, and the message carries only hashes. A reference the
# worker has already seen is named and not re-sent — which is what makes the
# per-evaluation cost a hash lookup rather than a megabyte.

## Tessellation deviation the measurement asks for, in millimetres. The
## display mesh is tessellated for looking at; a clearance is quoted with this
## number as its error bar, so the check asks for its own, tighter one.
const CLEARANCE_TOLERANCE_MM: float = 0.01
## The worker tessellates the solid and may build a 130k-triangle tree on the
## first call. Later calls are milliseconds.
const CLEARANCE_TIMEOUT_MS: int = 60000

## Mesh blob format, read by worker/mcad_worker/clearance.py. Little-endian:
## magic, uint32 version, uint32 vertex count, uint32 triangle count, then
## float32[3V] world millimetres and uint32[3F] indices. Godot's
## `to_byte_array()` is native order, which is little-endian on every target
## the plugin ships to.
const BLOB_MAGIC: String = "MCADMESH"
const BLOB_VERSION: int = 1
const BLOB_DIR_NAME: String = "minerva-cad-clearance"

## The host caps a panel-to-plugin payload at 64 KiB
## (PluginScenePanelBroker.MAX_PAYLOAD_BYTES), measured as the JSON length of
## the payload it receives. The margin covers the difference between the
## caller's stringification and the broker's — float formatting need not agree
## byte for byte — and a request over the cap is refused by the host as
## payload_too_large, which says nothing about clearances.
const IPC_PAYLOAD_LIMIT_BYTES: int = 65536
const IPC_PAYLOAD_MARGIN_BYTES: int = 2048

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


## Delete this panel's blob directory. Called when the panel goes away: the
## sweep only ever runs during an upload, so without this a closed document's
## blobs would sit in the cache until some later document happened to write
## over the same directory — which, now that each panel owns its own, would
## never happen.
func release() -> void:
	# The pins outlive their call only when a measurement's coroutine died
	# holding them; the panel going away is the last chance to drop them.
	_pinned_digests.clear()
	_bodies.clear()
	var directory := get_blob_dir()
	_blobs.clear()
	if not DirAccess.dir_exists_absolute(directory):
		return
	for name in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(name))
	DirAccess.remove_absolute(directory)


## minerva_cad_check_clearance — the minimum distance between the solid and
## every reference node in scope, against `required_mm`.
##
## `args`: required_mm (mandatory), reference=, node=, tolerance_mm=,
## accept_unbounded_tolerance= (default false).
##
## The reply is the worker's, re-framed:
##
##   {checked, units, pass, pass_reason?, required_mm,
##    tessellation_tolerance_mm, requested_tolerance_mm, tolerance_bounded,
##    bound, references_moved,
##    pairs: [{reference, node, min_mm, bound_mm, pass, solid_point_mm,
##             reference_point_mm: {world, local}, interference?, note?}],
##    solid_triangles, cache, engine, interference_join}
##
## sorted by min_mm, closest first. `solid_point_mm` is a bare world triple
## because the evaluated solid is never posed — its own frame IS the world.
## `checked: false` with a `reason` is not the same answer as "everything
## clears"; a reader that cannot tell them apart trusts a check that never ran.
##
## `tolerance_bounded` false means the worker could not read the curvature of
## every face and its tessellation tolerance is a guess, not a promise. A gap
## measured on such a mesh has no error bar, so the verdict is `pass` false
## with `pass_reason` saying why. With accept_unbounded_tolerance, every pair
## gets an advisory_pass on min_mm against required_mm; pass stays false.
## `bound_mm` becomes min_mm, and the reply carries `tolerance_waived` with a
## `waiver` saying the bar was set aside; the flag still travels.
##
## The join is only made from a report about THIS source measured against
## the reference poses and colliders standing NOW; a report whose references
## have moved or been rebuilt since is stale, joins nothing and fails the
## check with a `pass_reason`, because whether a node is buried is unknown —
## and so does having NO report about this source (the DSL was edited and not
## yet evaluated): the distances are reported, the verdict is false with
## "interference evidence unavailable".
##
## THE VERTICES TRAVEL AS FLOAT32. Their quantization at the largest world
## coordinate in scope is reported as `quantization_mm` (with
## `largest_coordinate_mm`), stated in `bound`, and subtracted from every
## pair's bound_mm beside the tessellation tolerance; a pose far enough from
## the origin for it to exceed tolerance_mm is refused with a reason.
##
## THE POSES ARE THE ONES THE CHECK WAS CALLED WITH. The geometry is extracted
## and hashed at the poses of entry, so the worker's world answer is about
## those poses, and every local coordinate is converted back through the same
## ones — from a copy taken before the first await, because the panel's
## records are live objects that a re-pose changes in place. A reference that
## moved while the check waited is reported by `references_moved`: the answer
## is self-consistent and describes where the references WERE.
##
## A mesh-to-mesh distance is UNSIGNED, so a node buried in the solid's
## material comes back from the worker as a positive surface-to-surface gap.
## The latest interference report for this same source is joined in for exactly
## that case: a node it names is reported at 0 with the interference flag and
## does not pass. `interference_join` says whether that report was available.
func check_clearance(panel: Object, args: Dictionary = {}) -> Dictionary:
	if panel == null or not is_instance_valid(panel):
		return _no_clearance("the CAD panel is gone")
	var required_mm := float(args.get("required_mm", 0.0))
	if required_mm <= 0.0:
		return _no_clearance("a clearance check needs required_mm: the "
			+ "distance you want between the solid and everything else")
	var tolerance_mm := float(args.get("tolerance_mm", CLEARANCE_TOLERANCE_MM))
	if tolerance_mm <= 0.0:
		return _no_clearance("tolerance_mm must be greater than zero")

	var document: Dictionary = {}
	if panel.has_method("get_document_state"):
		document = panel.get_document_state()
	var source := str(document.get("source", ""))
	if source.strip_edges().is_empty():
		return _no_clearance("there is no DSL source to evaluate a solid from")

	# The records are a LOCAL, never the module's _records: an interference
	# check that has been submitted to mesh_gauge but has not yet had its
	# physics step reads _records when it runs, and a clearance call landing in
	# that window would replace the geometry underneath it. The two entry
	# points share this module; they must not share its state.
	#
	# And a COPY, never the panel's own array: the panel re-poses a reference
	# by writing its record's pose in place, and a check that held the live
	# record would convert old-world geometry through a new pose after the
	# await. A deep duplicate copies the dictionaries and their value types
	# (the poses) while sharing the meshes, which are never rewritten.
	var records: Array = []
	if panel.has_method("get_reference_state"):
		records = (panel.get_reference_state() as Array).duplicate(true)
	var reference_scope := str(args.get("reference", ""))
	var node_scope := str(args.get("node", ""))
	var parts := _scoped_parts(records, reference_scope, node_scope)
	if parts.is_empty():
		return _no_clearance("no reference mesh is in scope; there is "
			+ "nothing to measure a clearance against")

	var targets: Array = []
	# The coarsest float32 step among the vertices about to be measured, and
	# the coordinate that set it. It is an error bar of its own: a vertex
	# written as float32 lands on a grid whose pitch grows with the distance
	# from the origin, and a pose far enough out puts that pitch above the
	# tolerance the caller asked for — at which point no triangle-pair
	# distance can be quoted to that tolerance and the check refuses rather
	# than report a bar it cannot keep.
	var quantization := 0.0
	var largest := 0.0
	for entry in parts:
		var part: Dictionary = entry
		var blob := _blob_for(part)
		if blob.is_empty():
			continue
		targets.append({
			"reference": part["reference"],
			"node": part["node"],
			"key": blob["digest"],
		})
		if float(blob.get("quantization_mm", 0.0)) > quantization:
			quantization = float(blob["quantization_mm"])
			largest = float(blob.get("largest_coordinate_mm", 0.0))
	if targets.is_empty():
		return _no_clearance("the references in scope carry no triangles")
	if quantization > tolerance_mm:
		var refused := _no_clearance(("the reference vertices are written as "
			+ "float32 world millimetres, and at the largest coordinate in "
			+ "scope (%s mm) that quantizes them to %s mm — coarser than the "
			+ "%s mm tolerance asked for, so no distance could be quoted to it; "
			+ "pose the assembly nearer the origin or loosen tolerance_mm")
			% [largest, quantization, tolerance_mm])
		refused["quantization_mm"] = quantization
		refused["largest_coordinate_mm"] = largest
		return refused

	var head := {
		"source": source,
		"required_mm": required_mm,
		"tolerance_mm": tolerance_mm,
	}
	# The quantization rides beside the request, not in it: the worker never
	# sees it, and the reply is stamped with it here.
	var bar := {"quantization_mm": quantization, "largest_coordinate_mm": largest}
	var plan := _batch_targets(head, targets)
	if plan.has("error"):
		return _no_clearance(str(plan["error"]))

	# The keys this call names are pinned for as long as it runs. Two calls
	# share _blobs and the blob directory, so a reference re-posed between one
	# call's two attempts would otherwise let the other's sweep delete the file
	# the retry names — a single-shot "could not read" with nothing wrong.
	var pinned := _pin(plan["batches"] as Array)
	var report := await _measure(panel, head, plan["batches"] as Array, records,
		_buried_pairs(document, source, records, panel),
		bool(args.get("accept_unbounded_tolerance", false)), bar)
	_unpin(pinned)
	if bool(report.get("checked", false)):
		report["references_moved"] = is_instance_valid(panel) \
			and panel.has_method("get_reference_state") \
			and not _same_poses(records, panel.get_reference_state() as Array)
		if report["references_moved"]:
			report["pass"] = false
			report["pass_reason"] = "reference geometry changed while clearance was measured; ask again"
	return report


## Ask every batch and fold the replies into one report. Split out so the pin
## its caller takes is dropped on every path out of the measurement.
func _measure(panel: Object, head: Dictionary, batches: Array, records: Array,
		buried: Dictionary, accept_unbounded: bool, bar: Dictionary = {}) -> Dictionary:
	var envelope: Dictionary = {}
	var raw_pairs: Array = []
	for batch_entry in batches:
		var batch: Array = batch_entry
		var reply := await _ask_batch(panel, head, batch)
		if reply.has("error"):
			return _no_clearance(str(reply["error"]))
		if not bool(reply.get("checked", false)):
			return _no_clearance(str(reply.get("reason", "the clearance check "
				+ "did not run and gave no reason")))
		if not reply.get("tolerance_bounded") is bool:
			return _no_clearance("worker clearance reply has missing or invalid tolerance_bounded metadata")
		envelope = reply
		raw_pairs.append_array(reply.get("pairs", []) as Array)
	envelope.merge(bar, true)
	return _clearance_report(envelope, raw_pairs, records, buried, accept_unbounded)


## Compare names, exact poses, mesh identities and each part's local transform.
## Imported meshes are immutable resources; reloading replaces their identities.
func _same_poses(snapshot: Array, live: Array) -> bool:
	if live.size() != snapshot.size():
		return false
	for index in range(snapshot.size()):
		var was: Dictionary = snapshot[index]
		var now: Dictionary = live[index]
		if str(was.get("name", "")) != str(now.get("name", "")):
			return false
		var before: Transform3D = was.get("pose", Transform3D.IDENTITY)
		var after: Transform3D = now.get("pose", Transform3D.IDENTITY)
		if before != after:
			return false
	return _MeshGauge.bodies_digest(_MeshGauge.bodies_from_records(snapshot)) \
		== _MeshGauge.bodies_digest(_MeshGauge.bodies_from_records(live))


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


## One batch of targets, uploading the geometry the worker turns out not to
## have. A key the worker has not seen (first call, or its cache turned over)
## is answered with the list rather than an error: write those blobs and ask
## once more. Only once — a second miss on freshly written files is a fault,
## not a race, and retrying forever would hide it.
##
## THE RETRY CARRIES EVERY TARGET'S PATH, not only the reported misses. The
## worker's blob cache is bounded, so on a board with more nodes than that
## bound a first call is answered with SOME of its keys missing while the
## worker still holds the rest — and the uploads the retry sends evict exactly
## those. A retry naming only the reported misses is then answered with a
## fresh set of them, and the panel, having already spent its one retry, calls
## that an unreadable file. Residency is never assumed across a call; the
## batches were sized as if every target carried its path, so this cannot push
## the request past the channel cap.
func _ask_batch(panel: Object, head: Dictionary, batch: Array) -> Dictionary:
	var reply := await _ask_worker(panel, _request(head, batch))
	if reply.has("error"):
		return reply
	if (reply.get("missing_keys", []) as Array).is_empty():
		return reply
	var keys: Array = []
	for entry in batch:
		keys.append(str((entry as Dictionary)["key"]))
	if not _upload(keys):
		return {"error": "could not write the reference geometry to "
			+ get_blob_dir() + " for the worker to read"}
	for entry in batch:
		var target: Dictionary = entry
		target["path"] = _blob_path(str(target["key"]))
	reply = await _ask_worker(panel, _request(head, batch))
	if reply.has("error"):
		return reply
	var still: Array = reply.get("missing_keys", []) as Array
	if not still.is_empty():
		return {"error": _second_miss_reason(still)}
	return reply


## Why a retry that carried a path for every target still came back missing
## keys. The two causes send a reader to opposite places: a blob this panel
## could not keep on disk is a filesystem fault HERE, while a blob that is
## present and readable under exactly the name the request carried is the
## worker declining geometry it was handed. Naming the wrong one costs an
## afternoon looking for a file that is sitting right there.
func _second_miss_reason(keys: Array) -> String:
	var unreadable := 0
	for key in keys:
		var handle := FileAccess.open(_blob_path(str(key)), FileAccess.READ)
		if handle == null:
			unreadable += 1
		else:
			handle.close()
	if unreadable > 0:
		return ("%d of the %d reference blobs the worker asked for cannot be "
			+ "read back from %s, so it was sent the path of a file that is "
			+ "not there") % [unreadable, keys.size(), get_blob_dir()]
	return ("the worker reports no geometry for %d reference nodes even "
		+ "though the request carried the path of each one, and every one of "
		+ "those files is present and readable in %s — its own blob cache "
		+ "dropped them, rather than a file being unreadable") \
		% [keys.size(), get_blob_dir()]


func _request(head: Dictionary, targets: Array) -> Dictionary:
	var payload := head.duplicate()
	payload["targets"] = targets
	return payload


## Split `targets` into requests that each fit the host's channel cap.
##
## Nothing bounds how many nodes a reference has, and each target costs a
## 64-character hash plus an absolute path — a few hundred nodes is a request
## the host refuses as payload_too_large, which tells the reader nothing about
## clearance. Sizing uses the WITH-PATH form of every target, which is the
## largest a request ever gets, so the retry inside `_ask_batch` is safe by
## construction rather than by luck.
##
## Returns {batches: [[target, ...], ...]} or {error: reason}. The only way to
## fail is a single target that does not fit alone, which a target cannot
## cause — it is the DSL source sharing the payload.
func _batch_targets(head: Dictionary, targets: Array) -> Dictionary:
	var limit := IPC_PAYLOAD_LIMIT_BYTES - IPC_PAYLOAD_MARGIN_BYTES
	# BYTES, not characters: the host's cap is on the encoded message, and a
	# DSL with multibyte identifiers or comments in it measures shorter than
	# it travels.
	var head_size := _byte_size(_request(head, []))
	var batches: Array = []
	var current: Array = []
	var size := head_size
	for entry in targets:
		var target: Dictionary = entry
		# +1 for the comma the array separator costs.
		var cost := _byte_size(_sized(target)) + 1
		if head_size + cost > limit:
			return {"error": ("the clearance request for node '%s' does not "
				+ "fit the host's %d byte channel limit on its own — the DSL "
				+ "source is too long to measure against a reference")
				% [str(target.get("node", "")), IPC_PAYLOAD_LIMIT_BYTES]}
		if size + cost > limit:
			batches.append(current)
			current = []
			size = head_size
		current.append(target)
		size += cost
	if not current.is_empty():
		batches.append(current)
	return {"batches": batches}


## What one JSON value costs on the wire, in UTF-8 bytes.
func _byte_size(value: Variant) -> int:
	return JSON.stringify(value).to_utf8_buffer().size()


## A target at its largest: the form the retry sends, carrying the blob path.
func _sized(target: Dictionary) -> Dictionary:
	var out := target.duplicate()
	out["path"] = _blob_path(str(target.get("key", "")))
	return out


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


## Re-frame the worker's replies into one report: every reported point gains
## the coordinates of the reference's OWN frame beside the world ones, because
## those are the numbers that get written back into the DSL. `envelope` is the
## last batch's scalar fields (they are the request's own parameters, so every
## batch agrees on them); `raw_pairs` is every batch's pairs together, which
## have to be re-sorted because each batch only sorted its own.
func _clearance_report(envelope: Dictionary, raw_pairs: Array,
		records: Array, buried: Dictionary, accept_unbounded: bool) -> Dictionary:
	var overlapping: Dictionary = buried.get("nodes", {})
	var undecided: Dictionary = buried.get("undecided", {})
	var undecided_references: Dictionary = buried.get("undecided_references", {})
	var pairs: Array = []
	for entry in raw_pairs:
		var raw: Dictionary = entry
		var pair := {
			"reference": str(raw.get("reference", "")),
			"node": str(raw.get("node", "")),
			"min_mm": float(raw.get("min_mm", 0.0)),
			# The worker's verdict is on this: min_mm less the tolerance the
			# mesh keeps. It travels so a reader sees the same number the
			# pass was graded on.
			"bound_mm": float(raw.get("bound_mm", raw.get("min_mm", 0.0))),
			"pass": bool(raw.get("pass", false)),
		}
		if overlapping.has(_pair_key(pair["reference"], pair["node"])):
			# The worker measured surface to surface and found air between two
			# faces; the interference check found this node crossing the solid
			# or buried in it. There is no gap to quote, and the realising
			# points describe a distance that is not the answer.
			pair["min_mm"] = 0.0
			pair["bound_mm"] = 0.0
			pair["pass"] = false
			pair["interference"] = true
			pair["note"] = "the interference check found this node crossing " \
				+ "the solid or lying inside it; a mesh-to-mesh distance is " \
				+ "unsigned and cannot see material a node is already inside"
			pairs.append(pair)
			continue
		var doubt := ""
		if undecided.has(_pair_key(pair["reference"], pair["node"])):
			doubt = str(undecided[_pair_key(pair["reference"], pair["node"])])
		elif undecided_references.has(pair["reference"]):
			doubt = str(undecided_references[pair["reference"]])
		if not doubt.is_empty():
			# The distance is real and is reported; what is not known is which
			# SIDE of the surface it was measured from. A pass here would be a
			# guess, so the row states the doubt and fails.
			pair["pass"] = false
			pair["containment_undecidable"] = true
			pair["note"] = "containment undecidable: %s" % doubt
		if raw.has("solid_point_mm") and raw.has("reference_point_mm"):
			var pose := _pose_in(records, pair["reference"])
			var reference_point := _vector(raw["reference_point_mm"])
			pair["solid_point_mm"] = _vec(_vector(raw["solid_point_mm"]))
			pair["reference_point_mm"] = {
				"world": _vec(reference_point),
				"local": _vec(pose.affine_inverse() * reference_point),
			}
		if bool(raw.get("interference", false)):
			pair["interference"] = true
		if not str(raw.get("note", "")).is_empty() and not pair.has("note"):
			pair["note"] = str(raw["note"])
		pairs.append(pair)
	pairs.sort_custom(func(a, b): return float((a as Dictionary)["min_mm"]) \
		< float((b as Dictionary)["min_mm"]))
	# Only an explicit boolean true establishes a bound. An opt-in can expose
	# a distance-only advisory grade, but cannot make an unknown bound certain.
	var bounded: bool = envelope.get("tolerance_bounded") is bool \
		and envelope.get("tolerance_bounded", false) == true
	var required := float(envelope.get("required_mm", 0.0))
	var waived := not bounded and accept_unbounded
	if waived:
		for entry in pairs:
			var pair: Dictionary = entry
			if bool(pair.get("interference", false)) \
					or bool(pair.get("containment_undecidable", false)):
				continue
			pair["bound_mm"] = float(pair["min_mm"])
			pair["pass"] = float(pair["min_mm"]) > 0.0 \
				and float(pair["min_mm"]) >= required
			pair["graded_on"] = "min_mm alone (less the float32 quantization " \
				+ "of the vertices): the tolerance bar was waived by " \
				+ "accept_unbounded_tolerance"
	var verdict := true
	for entry in pairs:
		if not bool((entry as Dictionary)["pass"]):
			verdict = false
	var pass_reason := ""
	if not bounded and not accept_unbounded:
		verdict = false
		pass_reason = "the " + UNBOUNDED_TOLERANCE_REASON + " for " \
			+ "unrecognised curved faces in the solid, so the measured " \
			+ "distances carry no error bar; pass accept_unbounded_tolerance " \
			+ "to request advisory grades on the distances alone; pass remains false"
	# THE JOIN IS EVIDENCE THE VERDICT NEEDS. A report that could not decide
	# the containment question — measured against reference poses or
	# colliders that have since changed — leaves "is any node buried"
	# unknown; a report about another source, or none at all, leaves it just
	# as unknown: the solid may since have grown around a node that the
	# unsigned distance reports as a positive gap. Unknown is not a pass
	# either way; the distances are still reported.
	if bool(buried.get("stale", false)):
		verdict = false
		pass_reason = str(buried.get("reason", "the interference report is stale"))
	elif not bool(buried.get("fresh", false)):
		verdict = false
		pass_reason = "interference evidence unavailable: no interference " \
			+ "report describes this source, so whether any node is buried in " \
			+ "the solid is unknown and a mesh-to-mesh distance cannot tell; " \
			+ "evaluate the document (the check runs on every evaluation) and " \
			+ "ask again"
	# The float32 quantization of the shipped vertices is a second error bar
	# beside the tessellation's, and it is subtracted from the same bound the
	# verdict is graded on — one rule for both bars.
	var quantization := float(envelope.get("quantization_mm", 0.0))
	if quantization > 0.0:
		for entry in pairs:
			var pair: Dictionary = entry
			if bool(pair.get("interference", false)):
				continue
			pair["bound_mm"] = maxf(float(pair["bound_mm"]) - quantization, 0.0)
			if bool(pair.get("pass", false)) and float(pair["bound_mm"]) < required:
				pair["pass"] = false
				pair["note"] = ("the gap clears required_mm by less than the "
					+ "float32 quantization of the reference vertices (%s mm)") \
					% quantization
				verdict = false
	# An estimate can inform a decision but cannot certify the requested gap.
	if not bounded:
		verdict = false
		if pass_reason.is_empty():
			pass_reason = UNBOUNDED_TOLERANCE_REASON \
				+ "; distances are advisory only"
		for entry in pairs:
			var pair: Dictionary = entry
			pair["advisory_pass"] = bool(pair["pass"]) and waived \
				and bool(buried.get("fresh", false)) and not bool(buried.get("stale", false))
			pair["pass"] = false
	var report := {
		"checked": true,
		"units": "mm",
		"pass": verdict,
		"advisory": not bounded,
		"required_mm": float(envelope.get("required_mm", 0.0)),
		"tessellation_tolerance_mm":
			float(envelope.get("tessellation_tolerance_mm", 0.0)),
		"requested_tolerance_mm": float(envelope.get("requested_tolerance_mm",
			envelope.get("tessellation_tolerance_mm", 0.0))),
		"tolerance_bounded": bounded,
		"bound": str(envelope.get("bound", "")) + (("; the reference vertices "
			+ "travel as float32 world millimetres, quantized to at most %s mm "
			+ "at the largest coordinate (%s mm), and that quantization is "
			+ "subtracted from bound_mm as well") % [quantization,
				float(envelope.get("largest_coordinate_mm", 0.0))]
			if quantization > 0.0 else ""),
		"quantization_mm": quantization,
		"largest_coordinate_mm": float(envelope.get("largest_coordinate_mm", 0.0)),
		"solid_triangles": int(envelope.get("solid_triangles", 0)),
		"engine": str(envelope.get("engine", "")),
		"cache": envelope.get("cache", {}),
		"interference_join": _join_note(buried),
		"pairs": pairs,
	}
	if not pass_reason.is_empty():
		report["pass_reason"] = pass_reason
	if waived:
		report["tolerance_waived"] = true
		report["waiver"] = "the tessellation tolerance is a guess here and " \
			+ "its error bar was WAIVED at the caller's request: every pair " \
			+ "is graded on min_mm against required_mm alone, with no " \
			+ "deduction for chord error"
	return report


## The (reference, node) pairs the panel's latest interference report names as
## crossing the solid or lying inside it, keyed the way a clearance pair is.
##
## The interference check runs on every evaluation and rides in the panel's
## last eval result, so the answer is already there; asking again would rebuild
## the solid's collider for a question that has been answered.
##
## Returns {fresh, stale?, reason?, nodes: {key: true}, undecided: {key: reason},
## undecided_references: {reference: reason}}.
## `fresh` is false when no report describes the source about to be measured —
## the reply then says the join was unavailable rather than implying the
## distances are signed.
##
## FRESH MEANS THE SAME SOURCE, THE SAME POSES AND THE SAME COLLIDERS. A
## report about this source but about references that have since moved, or
## colliders rebuilt since, is `stale`: it cannot say which nodes are buried
## NOW — a reference moved into the solid after it ran reads as a positive,
## unsigned gap — so nothing is joined, and the caller refuses to pass on
## it. The poses are compared through the gauge's own records-to-bodies
## digest, the colliders by its rebuild generation; `records` is the caller's
## snapshot of the panel's records and `panel` supplies the gauge.
##
## UNDECIDED NODES TRAVEL TOO. A node whose containment the interference check
## could not settle is exactly the node whose unsigned distance cannot be
## trusted: if it IS buried, the gap the worker measured is the distance to the
## wall it is inside. Passing such a node on its measured number is the same
## blind spot the join exists to close, so it is carried through and the pair
## says so.
func _buried_pairs(document: Dictionary, source: String, records: Array,
		panel: Object) -> Dictionary:
	var out := {"fresh": false, "nodes": {}, "undecided": {},
		"undecided_references": {}}
	var last_eval: Variant = document.get("last_eval", {})
	if not (last_eval is Dictionary):
		return out
	var report: Variant = (last_eval as Dictionary).get("interference", {})
	if not (report is Dictionary):
		return out
	var interference: Dictionary = report
	if not bool(interference.get("checked", false)):
		return out
	if str(interference.get("source_digest", "")) != _source_digest(source):
		return out
	var moved := str(interference.get("records_digest", "")) \
		!= str(_MeshGauge.bodies_digest(_MeshGauge.bodies_from_records(records)))
	var gauge: Object = panel.get_mesh_gauge() \
		if panel != null and panel.has_method("get_mesh_gauge") else null
	var generation := int(gauge.call("get_generation")) \
		if gauge != null and is_instance_valid(gauge) else -1
	var rebuilt := int(interference.get("gauge_generation", -2)) != generation
	if moved or rebuilt:
		out["stale"] = true
		out["reason"] = ("the latest interference report for this source was "
			+ "measured against %s, so whether any node is buried in the "
			+ "solid NOW is unknown; a mesh-to-mesh distance is unsigned and "
			+ "cannot tell, so this check cannot pass — re-evaluate and ask "
			+ "again") % ("reference poses that have since changed"
				if moved else "reference colliders that have since been rebuilt")
		return out
	out["fresh"] = true
	var nodes: Dictionary = out["nodes"]
	for entry in (interference.get("pairs", []) as Array):
		var pair: Dictionary = entry
		nodes[_pair_key(str(pair.get("reference", "")), str(pair.get("node", "")))] = true
	var undecided: Dictionary = out["undecided"]
	var references: Dictionary = out["undecided_references"]
	for entry in (interference.get("undecidable", []) as Array):
		var row: Dictionary = entry
		var reason := str(row.get("reason",
			"the interference check could not decide it"))
		var node_path := str(row.get("node", ""))
		if node_path.is_empty():
			# The other direction: the SOLID may be inside this reference and
			# no probe could settle it. It names no node, so it doubts every
			# node of that reference — a hollow shell buried in one body would
			# otherwise collect a full set of positive, passing distances.
			references[str(row.get("reference", ""))] = reason
			continue
		undecided[_pair_key(str(row.get("reference", "")), node_path)] = reason
	return out


## What the join contributed, in one sentence, so the reply is readable
## without the reader knowing the interference check exists.
func _join_note(buried: Dictionary) -> String:
	if bool(buried.get("stale", false)):
		return "STALE: " + str(buried.get("reason", ""))
	if not bool(buried.get("fresh", false)):
		return "no interference report describes this source, so none was " \
			+ "joined: a mesh-to-mesh distance is unsigned, and a node buried " \
			+ "in the solid's material reads as a positive gap"
	var count: int = (buried.get("nodes", {}) as Dictionary).size()
	var undecided: int = (buried.get("undecided", {}) as Dictionary).size() \
		+ (buried.get("undecided_references", {}) as Dictionary).size()
	var doubt := ""
	if undecided > 0:
		doubt = ("; %d node(s) whose containment that report could not decide "
			+ "keep their measured distance but do NOT pass, because an "
			+ "unsigned distance cannot say which side of the surface it was "
			+ "measured from") % undecided
	if count == 0:
		return "the latest interference report for this source found no " \
			+ "overlap, so every distance below is between two surfaces " \
			+ "with air in between" + doubt
	return ("%d node(s) the latest interference report for this source found "
		% count + "overlapping the solid are reported at 0 rather than at "
		+ "their unsigned surface-to-surface distance") + doubt


## SHA-256 of the DSL source, hex. Carried on the interference report so a
## clearance check can tell whether that report describes the solid it is
## about to measure against.
func _source_digest(source: String) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(source.to_utf8_buffer())
	return hasher.finish().hex_encode()


## One line for the status banner, naming the tightest gap. A clearance is
## quoted with its error bar or not at all.
func clearance_status_line(report: Dictionary) -> String:
	if not bool(report.get("checked", false)):
		return ""
	var pairs: Array = report.get("pairs", []) as Array
	if pairs.is_empty():
		return ""
	var first: Dictionary = pairs[0]
	var verdict := "clears" if bool(report.get("pass", false)) else "TOO CLOSE"
	# ADVISORY names ONE cause: the tolerance is a guess, so the distances can
	# only inform. A stale or missing interference join is a different failure
	# — the containment question is unanswered — and it overwrites pass_reason,
	# so the reason the report carries is the one that decided the verdict.
	if bool(report.get("advisory", false)) and str(report.get("pass_reason", "")) \
			.contains(UNBOUNDED_TOLERANCE_REASON):
		verdict = "ADVISORY"
	var tolerance := "tessellated to %.3f mm" \
		% float(report.get("tessellation_tolerance_mm", 0.0))
	if not bool(report.get("tolerance_bounded", true)):
		tolerance = "tolerance ~%.3f mm, NOT guaranteed" \
			% float(report.get("tessellation_tolerance_mm", 0.0))
	return "Clearance %s: %s/%s is %.3f mm from the solid (need %.3f, %s)." \
		% [verdict, str(first.get("reference", "")), str(first.get("node", "")),
			float(first.get("min_mm", 0.0)), float(report.get("required_mm", 0.0)),
			tolerance]


func _no_clearance(reason: String) -> Dictionary:
	return {
		"checked": false,
		"units": "mm",
		"pass": false,
		"reason": reason,
		"pairs": [],
	}


## Send one clearance request through the panel's IPC helper and unwrap the
## host's two envelopes down to the worker's own result. Returns {error: ...}
## for every layer that can fail, so the caller has one shape to read.
func _ask_worker(panel: Object, payload: Dictionary) -> Dictionary:
	if not panel.has_method("call_backend"):
		return {"error": "this panel cannot reach the CAD worker"}
	var envelope: Dictionary = await panel.call_backend(
		"cad.clearance", payload, CLEARANCE_TIMEOUT_MS)
	return _WorkerReply.unwrap(envelope, "clearance")


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
