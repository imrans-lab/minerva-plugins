extends SceneTree
## How much air is there between the evaluated solid and a reference mesh?
##
## WHAT THIS SUITE OWNS, AND WHAT IT DOES NOT
##
## The minimum distance itself is computed in the worker, over a swept-sphere
## BVH (python-fcl). The cad GD harness has no worker — cad/tests/gd/
## EXPECTED_SUITES refuses the `real-worker` attribute until a worker probe
## exists — so the exact-distance arithmetic is pinned by pytest
## (worker/tests/test_clearance.py) where it actually runs.
##
## What the PANEL owns is everything either side of that number, and every one
## of those things is a real bug waiting to happen: which reference file, in
## which units, posed by which matrix; the triangles packed into the blob the
## worker reads; the hash that addresses it; the upload-on-miss retry; and the
## re-framing of the answer back into each reference's own coordinates. So the
## suite drives the real module through a stand-in backend and checks the
## panel's actual product — the BYTES IT SHIPS — against the fixture.
##
## THE FIXTURE, AND WHY IT CROSSES
##
## Two bars at right angles with 0.8 mm of air between them:
##
##   reference  long in X, narrow in Y, top face at z = 0   (posed into world)
##   solid      long in Y, narrow in X, bottom face at z = 0.8
##
## They only approach each other over the 4 x 4 mm square where they cross, so
## the gap is FACE TO FACE: every vertex of either bar is more than 60 mm from
## the other bar. That is deliberate. It is the case a vertex-sampling
## implementation gets wrong by two orders of magnitude, and the suite asserts
## the premise numerically before it asserts anything else.
##
## The stand-in backend does not invent the answer either: it decodes the blob
## the module actually wrote and derives the gap from THOSE coordinates. A
## dropped pose, a wrong unit, a mis-packed index or a byte-order slip changes
## the decoded geometry and the assertion fails.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const GeometryChecks := preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")

## The reference bar, in its own frame: long in X, its top face at z = 0.
const BAR_HALF_LENGTH := 50.0
const BAR_HALF_WIDTH := 2.0
const BAR_THICKNESS := 2.0
## The air between the two bars, and the tolerance the assertion allows.
const GAP_MM := 0.8
const GAP_TOLERANCE_MM := 0.005
## Every vertex of one bar is at least this far from the other bar.
const VERTEX_SEPARATION_FLOOR_MM := 60.0
## The second node, ten millimetres further down, so the reply has something
## to sort.
const FAR_DROP_MM := 10.0

const POSE_ORIGIN := Vector3(100.0, 200.0, 300.0)
const REFERENCE_NAME := "board"
const NEAR_NODE := "Assembly/Near"
const FAR_NODE := "Assembly/Far"

## The document the panel would hand over. Its text is forwarded verbatim; the
## suite never evaluates it, the worker does.
const SOURCE := "part = translate([-2, -50, 0.8], cube(4, 100, 2))"

## The host caps a panel to plugin IPC payload at 64 KiB
## (PluginScenePanelBroker.MAX_PAYLOAD_BYTES). The whole reason the arrays
## travel as a file is that they cannot travel in the message.
const IPC_PAYLOAD_CAP_BYTES := 65536

var _pass: int = 0
var _fail: int = 0
var _pose: Transform3D = Transform3D.IDENTITY
var _blob_dir: String = ""

## The stand-in backend's memory: key -> the path it was uploaded from, which
## is how a second check can be answered without a fresh upload.
var _known_blobs: Dictionary = {}
## Every payload the module sent, in order.
var _payloads: Array = []
## What the next call should answer with: "missing", "measure" or "error".
var _mode: String = "measure"


func _init() -> void:
	print("=== CAD Clearance Test (solid vs reference, exact) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_pose = Transform3D(Basis.IDENTITY, POSE_ORIGIN)
	_blob_dir = OS.get_user_data_dir().path_join("cad-clearance-test")
	_clear_blob_dir()

	var near: ArrayMesh = await _bake_bar(0.0)
	var far: ArrayMesh = await _bake_bar(-FAR_DROP_MM)
	check("fixture: the reference bars baked to meshes",
			near != null and near.get_surface_count() > 0
				and far != null and far.get_surface_count() > 0,
			"bake_static_mesh returned nothing")
	check("fixture: no vertex of either bar is near the other — a "
			+ "vertex-sampling check cannot find this gap",
			_closest_vertex_pair(near) > VERTEX_SEPARATION_FLOOR_MM,
			"closest vertex pair is %.3f mm apart" % _closest_vertex_pair(near))

	var panel := _StubPanel.new()
	panel.name = "StubPanel"
	panel.answer = _worker_answer
	panel.source = SOURCE
	panel.records = [{
		"name": REFERENCE_NAME,
		"pose": _pose,
		"world_aabb": _world_box(0.0),
		"parts": [
			{"mesh": near, "transform": Transform3D.IDENTITY,
				"node_path": NEAR_NODE, "node": NEAR_NODE},
			{"mesh": far, "transform": Transform3D.IDENTITY,
				"node_path": FAR_NODE, "node": FAR_NODE},
		],
	}]
	root.add_child(panel)

	var checks: RefCounted = GeometryChecks.new()
	checks.attach(root)
	checks.set_blob_dir(_blob_dir)
	await process_frame

	await _check_upload(panel, checks)
	await _check_answer(panel, checks)
	await _check_batching(panel, checks)
	await _check_refusals(panel, checks)
	_check_isolation(checks)
	_clear_blob_dir()


# ---------------------------------------------------------------------------
# The upload: hashes first, arrays only when asked for
# ---------------------------------------------------------------------------

func _check_upload(panel: Node, checks: RefCounted) -> void:
	var stale := _blob_dir.path_join("deadbeef.mcadmesh")
	DirAccess.make_dir_recursive_absolute(_blob_dir)
	var junk := FileAccess.open(stale, FileAccess.WRITE)
	if junk != null:
		junk.store_string("left over from an older document")
		junk.close()

	_payloads.clear()
	_known_blobs.clear()
	_mode = "measure"
	var report: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})

	check("upload: the first request carried the source, the clearance and "
			+ "the tolerance, and named every target by hash alone",
			_payloads.size() == 2
				and str((_payloads[0] as Dictionary).get("source", "")) == SOURCE
				and is_equal_approx(
					float((_payloads[0] as Dictionary).get("required_mm", 0.0)), 0.5)
				and float((_payloads[0] as Dictionary).get("tolerance_mm", 0.0)) > 0.0
				and _targets_of(0).size() == 2
				and not _targets_of(0).any(func(t): return (t as Dictionary).has("path")),
			"payloads = %s" % str(_payloads))
	check("upload: a request that names geometry by hash fits the host's "
			+ "64 KiB IPC cap, which the arrays never would",
			JSON.stringify(_payloads[0]).length() < IPC_PAYLOAD_CAP_BYTES,
			"first payload is %d bytes" % JSON.stringify(_payloads[0]).length())
	check("upload: the second request carried a path for every key the "
			+ "worker said it was missing",
			_payloads.size() == 2
				and _targets_of(1).size() == 2
				and _targets_of(1).all(func(t): return not str(
					(t as Dictionary).get("path", "")).is_empty()),
			"second targets = %s" % str(_targets_of(1)))

	var addressed := true
	var decoded_ok := true
	for entry in _targets_of(1):
		var target: Dictionary = entry
		var path := str(target["path"])
		if path.get_file().get_basename() != str(target["key"]):
			addressed = false
		var blob := _decode_blob(path)
		if blob.is_empty() or blob["digest"] != str(target["key"]):
			addressed = false
			continue
		var expected := _world_box(0.0 if str(target["node"]) == NEAR_NODE
			else -FAR_DROP_MM)
		var box: AABB = blob["box"]
		if box.position.distance_to(expected.position) > 1e-3 \
				or box.size.distance_to(expected.size) > 1e-3:
			decoded_ok = false
	check("upload: each blob is named by the SHA-256 of its own array bytes",
			addressed, "a blob's filename is not its content hash")
	check("upload: the blob decodes to the reference's POSED world geometry",
			decoded_ok, "a decoded blob is not the posed bar")
	check("upload: blobs no live reference hashes to are swept away",
			not FileAccess.file_exists(stale), "the stale blob survived")

	# The references have not changed, so the second check must name them and
	# stop: re-uploading a board on every keystroke is the cost this whole
	# design exists to avoid.
	_payloads.clear()
	report = await checks.check_clearance(panel, {"required_mm": 0.5})
	check("upload: an unchanged reference is named, not re-sent",
			_payloads.size() == 1
				and not _targets_of(0).any(func(t): return (t as Dictionary).has("path")),
			"payloads = %s" % str(_payloads))
	check("upload: and the answer still arrives",
			bool(report.get("checked", false)), "report = %s" % str(report))


# ---------------------------------------------------------------------------
# The answer
# ---------------------------------------------------------------------------

func _check_answer(panel: Node, checks: RefCounted) -> void:
	var report: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var pairs: Array = report.get("pairs", []) as Array
	check("answer: a clearance that is met passes, naming both nodes",
			bool(report.get("checked", false)) and bool(report.get("pass", false))
				and pairs.size() == 2,
			"report = %s" % str(report))

	var near_pair: Dictionary = pairs[0] if pairs.size() > 0 else {}
	check("answer: the gap the panel's own shipped bytes describe is the "
			+ "fixture's 0.8 mm, face to face and nowhere near a vertex",
			absf(float(near_pair.get("min_mm", -1.0)) - GAP_MM) < GAP_TOLERANCE_MM,
			"min_mm = %s" % str(near_pair.get("min_mm", null)))
	check("answer: the tightest pair comes first and names its node",
			pairs.size() == 2
				and str(near_pair.get("node", "")) == NEAR_NODE
				and str(near_pair.get("reference", "")) == REFERENCE_NAME
				and float((pairs[1] as Dictionary).get("min_mm", 0.0))
					> float(near_pair.get("min_mm", 0.0)),
			"pairs = %s" % str(pairs))

	var world := _as_vector((near_pair.get("reference_point_mm", {}) as Dictionary)
		.get("world", []))
	var local := _as_vector((near_pair.get("reference_point_mm", {}) as Dictionary)
		.get("local", []))
	check("answer: the reference point arrives in both frames, and the pose "
			+ "takes one to the other",
			(_pose * local).distance_to(world) < 1e-3,
			"world %s vs pose * local %s" % [str(world), str(_pose * local)])
	check("answer: the solid's point is a bare world triple — the evaluated "
			+ "solid is never posed",
			(near_pair.get("solid_point_mm", []) as Array).size() == 3
				and absf(_as_vector(near_pair["solid_point_mm"]).z
					- (POSE_ORIGIN.z + GAP_MM)) < 0.05,
			"solid_point_mm = %s" % str(near_pair.get("solid_point_mm", null)))
	check("answer: the reply states the tessellation tolerance it measured "
			+ "at, and the bound that follows from it",
			float(report.get("tessellation_tolerance_mm", 0.0)) > 0.0
				and str(report.get("bound", "")).contains("at least"),
			"tolerance = %s, bound = %s" % [
				str(report.get("tessellation_tolerance_mm", null)),
				str(report.get("bound", ""))])
	check("answer: the status line quotes the gap WITH its error bar",
			checks.clearance_status_line(report).contains("0.800")
				and checks.clearance_status_line(report).contains("tessellated"),
			"status line = '%s'" % checks.clearance_status_line(report))

	var tight: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 1.0})
	var tight_pairs: Array = tight.get("pairs", []) as Array
	check("answer: a clearance that is NOT met fails, naming the node that "
			+ "is short",
			bool(tight.get("checked", false)) and not bool(tight.get("pass", true))
				and tight_pairs.size() == 2
				and not bool((tight_pairs[0] as Dictionary).get("pass", true))
				and str((tight_pairs[0] as Dictionary).get("node", "")) == NEAR_NODE
				and bool((tight_pairs[1] as Dictionary).get("pass", false)),
			"report = %s" % str(tight))

	# One node scoped away: the panel filters before it asks, so the worker is
	# never sent geometry the question does not cover.
	_payloads.clear()
	var scoped: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5, "node": FAR_NODE})
	check("answer: node= scopes the question before it is asked",
			(scoped.get("pairs", []) as Array).size() == 1
				and str(((scoped.get("pairs", []) as Array)[0] as Dictionary)
					.get("node", "")) == FAR_NODE
				and _targets_of(0).size() == 1,
			"scoped = %s" % str(scoped))

	_mode = "interference"
	var touching: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var first: Dictionary = (touching.get("pairs", []) as Array)[0] \
		if not (touching.get("pairs", []) as Array).is_empty() else {}
	check("answer: bodies with no air between them report zero with the "
			+ "interference flag and no points to quote",
			is_equal_approx(float(first.get("min_mm", -1.0)), 0.0)
				and bool(first.get("interference", false))
				and not first.has("solid_point_mm"),
			"pair = %s" % str(first))
	_mode = "measure"


# ---------------------------------------------------------------------------
# The channel cap — the boundary the whole design exists for
# ---------------------------------------------------------------------------

## Nothing bounds how many nodes a reference has, and every target costs a
## 64-character hash plus an absolute path. A reference with a few hundred
## nodes therefore pushes ONE request past the host's cap, and the host
## refuses it as payload_too_large — a message that says nothing about
## clearance. The sizes here are derived from the module's own constants and
## from a target built the way the module builds it, so the boundary is
## measured rather than guessed.
func _check_batching(panel: Node, checks: RefCounted) -> void:
	var target_cost := _target_cost()
	var limit: int = GeometryChecks.IPC_PAYLOAD_LIMIT_BYTES \
		- GeometryChecks.IPC_PAYLOAD_MARGIN_BYTES
	var base := _head_size("")

	# A source long enough that ONE target fits beside it and two do not.
	panel.source = _padded_source(limit - base - target_cost - 5)
	_payloads.clear()
	var split: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	check("cap: a request that would exceed the host's channel limit is "
			+ "split, one target per request",
			_payloads.size() == 2
				and _targets_of(0).size() == 1 and _targets_of(1).size() == 1,
			"payloads = %d, sizes = %s" % [_payloads.size(),
				str([_targets_of(0).size(), _targets_of(1).size()])])
	var over := false
	for payload in _payloads:
		if JSON.stringify(payload).length() > GeometryChecks.IPC_PAYLOAD_LIMIT_BYTES:
			over = true
	check("cap: every request the split produced is under the limit",
			not over, "a split request still exceeds %d bytes"
				% GeometryChecks.IPC_PAYLOAD_LIMIT_BYTES)
	var split_pairs: Array = split.get("pairs", []) as Array
	check("cap: the split answers are merged into one report, still "
			+ "closest-first",
			bool(split.get("checked", false)) and split_pairs.size() == 2
				and str((split_pairs[0] as Dictionary).get("node", "")) == NEAR_NODE
				and float((split_pairs[1] as Dictionary).get("min_mm", 0.0))
					> float((split_pairs[0] as Dictionary).get("min_mm", 0.0)),
			"split = %s" % str(split))

	# A source so long that no target fits beside it at all: there is nothing
	# to split, so the check has to say so rather than let the host refuse it.
	panel.source = _padded_source(limit - base - target_cost + 10)
	_payloads.clear()
	var refused: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	check("cap: a request that cannot be split at all is refused with a "
			+ "reason, and nothing is sent",
			not bool(refused.get("checked", true))
				and str(refused.get("reason", "")).contains("channel limit")
				and _payloads.is_empty(),
			"report = %s" % str(refused))
	panel.source = SOURCE


# ---------------------------------------------------------------------------
# Refusals — a question that could not be asked is not a clean bill of health
# ---------------------------------------------------------------------------

func _check_refusals(panel: Node, checks: RefCounted) -> void:
	_payloads.clear()
	var no_ask: Dictionary = await checks.check_clearance(panel, {})
	check("refusal: a check with no required_mm is refused, and nothing is "
			+ "sent to the worker",
			not bool(no_ask.get("checked", true))
				and str(no_ask.get("reason", "")).contains("required_mm")
				and _payloads.is_empty(),
			"report = %s" % str(no_ask))

	_payloads.clear()
	var nowhere: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5, "node": "NoSuchNode"})
	check("refusal: a node filter that matches nothing is refused rather "
			+ "than answered as 'everything clears'",
			not bool(nowhere.get("checked", true))
				and not str(nowhere.get("reason", "")).is_empty()
				and _payloads.is_empty(),
			"report = %s" % str(nowhere))

	_mode = "error"
	var broken: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	check("refusal: a worker that cannot answer is quoted, not swallowed",
			not bool(broken.get("checked", true))
				and str(broken.get("reason", "")).contains("python-fcl"),
			"report = %s" % str(broken))
	check("refusal: and a refused check reports no pairs at all",
			(broken.get("pairs", []) as Array).is_empty(),
			"pairs = %s" % str(broken.get("pairs", [])))
	_mode = "measure"


# ---------------------------------------------------------------------------
# What one panel's check must not do to another's
# ---------------------------------------------------------------------------

func _check_isolation(checks: RefCounted) -> void:
	# The blob directory is content-addressed and the sweep knows only about
	# ONE module's references, so two panels sharing a directory would delete
	# each other's freshly written blobs.
	var first: RefCounted = GeometryChecks.new()
	var second: RefCounted = GeometryChecks.new()
	check("isolation: each panel writes its blobs to its own directory",
			first.get_blob_dir() != second.get_blob_dir()
				and first.get_blob_dir().get_base_dir()
					== second.get_blob_dir().get_base_dir(),
			"%s vs %s" % [first.get_blob_dir(), second.get_blob_dir()])

	# The interference check reads _records when its physics step comes, which
	# may be after a clearance call has landed. The clearance path must work
	# from its own snapshot.
	check("isolation: a clearance check leaves the interference check's "
			+ "records alone",
			checks._records.is_empty(),
			"records = %s" % str(checks._records))

	var directory := _blob_dir
	checks.release()
	check("isolation: a panel releases its blob directory when it goes away",
			not DirAccess.dir_exists_absolute(directory),
			"%s survived release()" % directory)


# ---------------------------------------------------------------------------
# The stand-in backend
# ---------------------------------------------------------------------------

## Answer one cad.clearance request the way the worker would. The stand-in
## exists because the worker is a Python process this harness cannot start.
## It DOES recompute the gap — from the blob the module actually wrote, by an
## independent decode — so what the assertions below pin is the panel's
## posing, packing and re-framing, not a triangle-pair distance. The exact
## distance is pinned in worker/tests/test_clearance.py, where FCL runs.
func _worker_answer(args: Dictionary) -> Dictionary:
	_payloads.append(args.duplicate(true))
	if _mode == "error":
		return {"ok": false, "error": {"kind": "internal", "message":
			"clearance needs the python-fcl geometry backend, which this "
			+ "runtime bundle could not load"}}

	var targets: Array = args.get("targets", []) as Array
	var missing: Array = []
	for entry in targets:
		var target: Dictionary = entry
		var key := str(target.get("key", ""))
		var path := str(target.get("path", ""))
		if not path.is_empty():
			_known_blobs[key] = path
		if not _known_blobs.has(key):
			missing.append(key)
	if not missing.is_empty():
		return {"ok": true, "result": {
			"checked": false, "units": "mm", "pairs": [],
			"reason": "no cached geometry", "missing_keys": missing,
		}}

	# The solid's world position is the fixture's, and the reference's comes
	# out of the bytes the module shipped — so the gap is measured across the
	# panel's own product.
	var solid_bottom_z := POSE_ORIGIN.z + GAP_MM
	var required := float(args.get("required_mm", 0.0))
	var pairs: Array = []
	for entry in targets:
		var target: Dictionary = entry
		var blob := _decode_blob(str(_known_blobs[str(target["key"])]))
		var box: AABB = blob["box"]
		var top_z: float = box.position.z + box.size.z
		var min_mm: float = maxf(solid_bottom_z - top_z, 0.0)
		if _mode == "interference":
			min_mm = 0.0
		var pair := {
			"reference": str(target.get("reference", "")),
			"node": str(target.get("node", "")),
			"key": str(target.get("key", "")),
			"min_mm": min_mm,
			"pass": min_mm >= required,
			"triangles": int(blob["triangles"]),
			"cached": true,
		}
		if min_mm <= 0.0:
			pair["interference"] = true
			pair["note"] = "the meshes touch or overlap"
		else:
			# The realising points: the middle of the square where the bars
			# cross, on each of the two facing planes.
			pair["solid_point_mm"] = [POSE_ORIGIN.x, POSE_ORIGIN.y, solid_bottom_z]
			pair["reference_point_mm"] = [POSE_ORIGIN.x, POSE_ORIGIN.y, top_z]
		pairs.append(pair)
	pairs.sort_custom(func(a, b): return float(a["min_mm"]) < float(b["min_mm"]))
	var tolerance := float(args.get("tolerance_mm", 0.0))
	return {"ok": true, "result": {
		"checked": true,
		"units": "mm",
		"pass": pairs.all(func(p): return bool(p["pass"])),
		"required_mm": required,
		"tessellation_tolerance_mm": tolerance,
		"bound": "the true clearance is at least min_mm - %g mm" % tolerance,
		"solid_triangles": 12,
		"engine": "stand-in for python-fcl",
		"cache": {"hits": pairs.size(), "misses": 0, "entries": pairs.size()},
		"pairs": pairs,
	}}


class _StubPanel extends Node:
	## The three things geometry_checks.check_clearance asks a panel for.
	var source: String = ""
	var records: Array = []
	var answer: Callable

	func get_document_state() -> Dictionary:
		return {"source": source, "path": "", "mesh": {}, "references": []}

	func get_reference_state() -> Array:
		return records

	func call_backend(_channel: String, args: Dictionary,
			_timeout_ms: int = 30000) -> Dictionary:
		# Awaited by the caller, so it yields once like the real IPC round trip.
		await (Engine.get_main_loop() as SceneTree).process_frame
		return {"success": true, "result": answer.call(args)}


# ---------------------------------------------------------------------------
# Fixtures and blob decoding
# ---------------------------------------------------------------------------

## One reference bar in its own frame: long in X, narrow in Y, its top face at
## `top_z`. Built with CSG and baked — no mesh binary in the repository.
func _bake_bar(top_z: float) -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Bar"
	var bar := CSGBox3D.new()
	bar.size = Vector3(BAR_HALF_LENGTH * 2.0, BAR_HALF_WIDTH * 2.0, BAR_THICKNESS)
	bar.position = Vector3(0.0, 0.0, top_z - BAR_THICKNESS * 0.5)
	combiner.add_child(bar)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


## Where a bar with its top face at `top_z` ends up in the world.
func _world_box(top_z: float) -> AABB:
	return AABB(
		POSE_ORIGIN + Vector3(-BAR_HALF_LENGTH, -BAR_HALF_WIDTH,
			top_z - BAR_THICKNESS),
		Vector3(BAR_HALF_LENGTH * 2.0, BAR_HALF_WIDTH * 2.0, BAR_THICKNESS))


## The closest any vertex of the reference bar comes to any vertex of the
## solid bar, in world millimetres. The premise the fixture rests on.
func _closest_vertex_pair(mesh: ArrayMesh) -> float:
	var solid: Array = []
	for x in [-BAR_HALF_WIDTH, BAR_HALF_WIDTH]:
		for y in [-BAR_HALF_LENGTH, BAR_HALF_LENGTH]:
			for z in [GAP_MM, GAP_MM + BAR_THICKNESS]:
				solid.append(POSE_ORIGIN + Vector3(x, y, z))
	var closest := INF
	for surface in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		for vertex in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array):
			var world: Vector3 = _pose * vertex
			for point in solid:
				closest = minf(closest, world.distance_to(point as Vector3))
	return closest


## Read a mesh blob back the way the worker does — magic, counts, float32
## coordinates, uint32 indices — and return {digest, box, triangles, vertices}.
## Decoding it HERE is what makes the assertions about it independent of the
## code that wrote it.
func _decode_blob(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var raw := file.get_buffer(int(file.get_length()))
	file.close()
	if raw.size() < 20 or raw.slice(0, 8).get_string_from_utf8() != "MCADMESH":
		return {}
	var version := raw.decode_u32(8)
	var vertex_count := int(raw.decode_u32(12))
	var triangle_count := int(raw.decode_u32(16))
	if version != 1 or raw.size() != 20 + vertex_count * 12 + triangle_count * 12:
		return {}
	var body := raw.slice(20)
	var box := AABB()
	var seen := false
	for i in range(vertex_count):
		var point := Vector3(
			body.decode_float(i * 12),
			body.decode_float(i * 12 + 4),
			body.decode_float(i * 12 + 8))
		box = AABB(point, Vector3.ZERO) if not seen else box.expand(point)
		seen = true
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(body)
	return {
		"digest": hasher.finish().hex_encode(),
		"box": box,
		"vertices": vertex_count,
		"triangles": triangle_count,
	}


## The JSON cost of ONE target at its largest — the with-path form the retry
## sends — built the way the module builds it, from a key it actually wrote.
func _target_cost() -> int:
	var key := str((_targets_of(0)[0] as Dictionary).get("key", "")) \
		if not _targets_of(0).is_empty() else "0".repeat(64)
	return JSON.stringify({
		"reference": REFERENCE_NAME,
		"node": NEAR_NODE,
		"key": key,
		"path": _blob_dir.path_join(key + ".mcadmesh"),
	}).length() + 1


## The JSON size of a request carrying `source` and no targets at all.
func _head_size(source: String) -> int:
	return JSON.stringify({
		"source": source,
		"required_mm": 0.5,
		"tolerance_mm": GeometryChecks.CLEARANCE_TOLERANCE_MM,
		"targets": [],
	}).length()


## A DSL source of exactly `length` characters. Comment lines, so the text is
## something the worker would accept even though this suite never evaluates it.
func _padded_source(length: int) -> String:
	var padding: int = maxi(length - SOURCE.length() - 3, 0)
	return SOURCE + "\n# " + "x".repeat(padding)


func _targets_of(index: int) -> Array:
	if index >= _payloads.size():
		return []
	return (_payloads[index] as Dictionary).get("targets", []) as Array


func _clear_blob_dir() -> void:
	if not DirAccess.dir_exists_absolute(_blob_dir):
		return
	for name in DirAccess.get_files_at(_blob_dir):
		DirAccess.remove_absolute(_blob_dir.path_join(name))


func _as_vector(raw: Variant) -> Vector3:
	if raw is Array and (raw as Array).size() >= 3:
		var values: Array = raw
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3(1e9, 1e9, 1e9)


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass += 1
		print("  PASS  %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])
