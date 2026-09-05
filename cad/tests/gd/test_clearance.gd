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
## The pose TURNS the reference as well as moving it — a yaw about the CAD
## world's up axis — so a check that adds pose.origin without applying
## pose.basis ships the wrong triangles and misses the gap by tens of
## millimetres. The yaw is about z, which is the axis the gap is measured
## along, so every distance in the fixture is unchanged by it.
##
## WHAT A DISTANCE CANNOT SEE
##
## A mesh-to-mesh distance is unsigned: a node buried in the solid's material
## is a positive surface-to-surface number, and on its own reads as clearance.
## The verb therefore joins the panel's latest interference report, and the
## suite drives every state of that — a joined report, a stale one, and none
## about this source at all, which is no pass either. The vertices travel as
## float32, and their quantization is an error bar the reply carries.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const GeometryChecks := preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")
const MeshGauge := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")

## The reference bar, in its own frame: long in X, its top face at z = 0.
const BAR_HALF_LENGTH := 50.0
const BAR_HALF_WIDTH := 2.0
const BAR_THICKNESS := 2.0
## The air between the two bars, and the tolerance the assertion allows.
const GAP_MM := 0.8
const GAP_TOLERANCE_MM := 0.005
## The second node, ten millimetres further down, so the reply has something
## to sort.
const FAR_DROP_MM := 10.0

const POSE_ORIGIN := Vector3(100.0, 200.0, 300.0)
## The yaw the reference is posed with, about +z. The bars approach each other
## face to face along z, so the gap is the same at any yaw — but the triangles
## that have to be shipped to find it are not.
const POSE_YAW_DEG := 30.0
## The bar's half extents after the yaw, hand-derived: a bar 100 long and 4
## wide turned 30 degrees spans 50 cos30 + 2 sin30 = 44.301 in x and
## 50 sin30 + 2 cos30 = 26.732 in y.
const YAWED_HALF_X := 44.3013
const YAWED_HALF_Y := 26.7321
## Every vertex of one bar is at least this far from the other bar. At this
## yaw the closest pair is the reference bar's end corner and the solid bar's,
## about 46.5 mm apart — still sixty times the gap being measured.
const VERTEX_SEPARATION_FLOOR_MM := 40.0
const REFERENCE_NAME := "board"
## How far the reference moves under a call that is already in flight. Any
## shift changes the node's world triangles and so its digest, which is the
## whole point: the call that is waiting pinned the OLD one.
const REPOSE_SHIFT := Vector3(7.0, -5.0, 3.0)
## The reference the eviction check mounts, and what the stand-in worker will
## hold of it. More nodes than entries is the whole fixture: 45 nodes into 16
## is what the real board did.
const EVICTION_NODES := 20
const EVICTION_CACHE_BOUND := 16
const NEAR_NODE := "Assembly/Near"
const FAR_NODE := "Assembly/Far"

## The document the panel would hand over. Its text is forwarded verbatim; the
## suite never evaluates it, the worker does.
const SOURCE := "part = translate([-2, -50, 0.8], cube(4, 100, 2))"
## The same document EDITED so the solid grows down around the near bar. The
## stand-in worker never reads the source, so its unsigned 0.8 mm stands —
## which is exactly the blind spot: only an interference report about THIS
## text could say the bar is now inside, and none has been made yet.
const ENCLOSING_SOURCE := "part = translate([-2, -50, -3.0], cube(4, 100, 6))"
## A pose far enough from the origin that float32 world millimetres are
## quantized to whole millimetres: 1e8 lies in [2^26, 2^27), where the float32
## spacing is 2^(26-23) = 8 mm.
const FAR_ORIGIN := Vector3(1.0e8, 0.0, 0.0)
const FAR_QUANTIZATION_MM := 8.0
## The fixture's largest world coordinate is POSE_ORIGIN.z = 300, in
## [2^8, 2^9), where the float32 spacing is 2^(8-23).
const NEAR_QUANTIZATION_MM := 0.000030517578125

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
## What the next call should answer with: "measure", "unbounded" or "error".
var _mode: String = "measure"
## How many blobs the stand-in worker keeps, 0 for all of them. The real
## worker's cache is an LRU with a bound, and a bound is the whole reason a
## key the panel believes uploaded can go missing again.
var _cache_bound: int = 0
## Upload order, oldest first — the eviction order when the bound binds.
var _cache_order: Array = []
## The air the stand-in measures between the bars. The fixture's GAP_MM unless
## a check narrows it to sit just inside a requirement.
var _gap_mm: float = GAP_MM
## The stub panel, so an interference report can be stamped with the poses and
## collider generation it describes.
var _stub: Node = null


func _init() -> void:
	print("=== CAD Clearance Test (solid vs reference, exact) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_pose = Transform3D(Basis(Vector3.BACK, deg_to_rad(POSE_YAW_DEG)), POSE_ORIGIN)
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
	var yawed := _world_box(0.0)
	check("fixture: the pose TURNS the bar — its world box is the hand-derived "
			+ "44.301 x 26.732, not the 50 x 2 of its own frame",
			absf(yawed.size.x * 0.5 - YAWED_HALF_X) < 0.001
				and absf(yawed.size.y * 0.5 - YAWED_HALF_Y) < 0.001,
			"world box = %s" % str(yawed))

	var panel := _StubPanel.new()
	panel.name = "StubPanel"
	panel.answer = _worker_answer
	panel.source = SOURCE
	# The gauge a real panel carries, unbuilt: its rebuild generation is what
	# an interference report is stamped with, and what the join compares.
	panel.gauge = MeshGauge.new()
	panel.gauge.name = "MeshGauge"
	panel.add_child(panel.gauge)
	_stub = panel
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
	# The evidence every passing clearance needs: a clean interference report
	# about this source at these poses. Without one the verdict is false.
	panel.last_eval = _interference_over(SOURCE, [])

	var checks: RefCounted = GeometryChecks.new()
	checks.attach(root)
	checks.set_blob_dir(_blob_dir)
	# What an interference check submitted just before these clearance calls
	# landed. Nothing below may disturb it.
	checks.set_records([{"name": "submitted-by-the-interference-check",
		"pose": _pose, "parts": []}])
	await process_frame

	await _check_upload(panel, checks)
	await _check_answer(panel, checks)
	await _check_batching(panel, checks)
	await _check_refusals(panel, checks)
	await _check_buried(panel, checks)
	await _check_pin_across_a_repose(panel, checks)
	await _check_pose_rewritten_in_place(panel, checks)
	await _check_parts_changed_during_await(panel, checks)
	await _check_unbounded_tolerance(panel, checks)
	await _check_quantization(panel, checks)
	await _check_more_nodes_than_the_worker_caches(panel, checks)
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
	check("upload: each blob is named by the SHA-256 of its header AND its "
			+ "array bytes — the counts are part of what the key identifies, "
			+ "or two readings of one buffer would share it",
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

	# The cap is on BYTES. A source of multibyte characters that fits by
	# CHARACTER count travels twice its measured size, and a sizer
	# counting characters hands the host a message it will refuse as
	# payload_too_large — the exact error this whole split exists to avoid.
	var multibyte := _multibyte_source(limit - base - target_cost - 5)
	check("cap: the fixture is a source that FITS by character count and does "
			+ "not fit in bytes",
			multibyte.length() < limit
				and multibyte.to_utf8_buffer().size() > limit,
			"chars=%d bytes=%d limit=%d" % [multibyte.length(),
				multibyte.to_utf8_buffer().size(), limit])
	panel.source = multibyte
	_payloads.clear()
	var wide: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var wide_over := false
	for payload in _payloads:
		if JSON.stringify(payload).to_utf8_buffer().size() \
				> GeometryChecks.IPC_PAYLOAD_LIMIT_BYTES:
			wide_over = true
	check("cap: it is measured in UTF-8 bytes — the request is refused with a "
			+ "reason rather than sent over the host's byte limit",
			not wide_over and not bool(wide.get("checked", true))
				and str(wide.get("reason", "")).contains("channel limit"),
			"report = %s sent = %d" % [str(wide), _payloads.size()])
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
# The node the distance cannot see
# ---------------------------------------------------------------------------

## FCL measures surface to surface and never signs the result, so a node buried
## in the solid's material comes back as a positive gap — the same number a
## node sitting in clear air would give. The interference check is the half of
## the pair that can tell those apart, and it has already run: it rides in the
## panel's last eval result, stamped with a digest of the source it describes.
##
## The stand-in worker here answers with the fixture's real 0.8 mm of air while
## the interference report names the near node, which is exactly the shape of
## the failure: a positive distance about a body that is already inside.
func _check_buried(panel: Node, checks: RefCounted) -> void:
	panel.last_eval = _interference_over(SOURCE, [NEAR_NODE])
	var report: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var near := _pair_for(report, NEAR_NODE)
	var far := _pair_for(report, FAR_NODE)
	check("buried: a node the interference check found inside the solid is "
			+ "reported at zero and fails, whatever the unsigned distance says",
			is_equal_approx(float(near.get("min_mm", -1.0)), 0.0)
				and not bool(near.get("pass", true))
				and bool(near.get("interference", false))
				and not near.has("solid_point_mm")
				and not bool(report.get("pass", true)),
			"near = %s, pass = %s" % [str(near), str(report.get("pass"))])
	check("buried: the node the report did NOT name keeps its measured gap",
			absf(float(far.get("min_mm", -1.0)) - (GAP_MM + FAR_DROP_MM))
					< GAP_TOLERANCE_MM
				and bool(far.get("pass", false)),
			"far = %s" % str(far))
	check("buried: the reply says the join happened and over how many nodes, "
			+ "so a reader is never left guessing which half answered",
			str(report.get("interference_join", "")).contains("1"),
			"join = '%s'" % str(report.get("interference_join", "")))

	# A report about another document describes another solid. Joining it would
	# fail a node for an overlap that no longer exists — and NOT having a
	# report about this one leaves the question it answers open. Here the DSL
	# is edited so the solid grows around the near bar and clearance is asked
	# before the new evaluation has run: the stand-in worker still answers
	# 0.8 mm of unsigned air, and the only report there is names the OLD
	# source (and, as it happens, the near node — which must not be joined
	# either).
	panel.last_eval = _interference_over(SOURCE, [NEAR_NODE])
	panel.source = ENCLOSING_SOURCE
	var unavailable: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	panel.source = SOURCE
	var unjoined := _pair_for(unavailable, NEAR_NODE)
	# The other half of the same blind spot. A node whose containment the
	# interference check could not DECIDE — every probe it offered landed in a
	# hole or a cavity — is exactly the node whose unsigned distance cannot be
	# trusted: if it is in fact buried, the "gap" is the distance to the wall
	# it is inside. It keeps its measured number and must not pass.
	panel.last_eval = _interference_over(SOURCE, [], [NEAR_NODE])
	var doubtful: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var undecided := _pair_for(doubtful, NEAR_NODE)
	var decided := _pair_for(doubtful, FAR_NODE)
	check("undecidable: a node the interference check could not DECIDE keeps "
			+ "its measured distance, says why, and does not pass",
			not bool(undecided.get("pass", true))
				and bool(undecided.get("containment_undecidable", false))
				and str(undecided.get("note", "")).begins_with(
					"containment undecidable: ")
				and absf(float(undecided.get("min_mm", -1.0)) - GAP_MM)
					< GAP_TOLERANCE_MM
				and not bool(doubtful.get("pass", true))
				and bool(decided.get("pass", false)),
			"undecided = %s far = %s" % [str(undecided), str(decided)])

	# The OTHER direction of the same doubt. An interference report can also
	# fail to decide whether the SOLID is inside a reference; that row names no
	# node, because it is about the whole body. Discarding it lets a hollow
	# shell buried in one reference collect a full set of positive, passing
	# distances — so it doubts every node of that reference.
	panel.last_eval = _interference_over(SOURCE, [], [], REFERENCE_NAME)
	var whole: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var every_row := true
	for entry in (whole.get("pairs", []) as Array):
		var pair: Dictionary = entry
		if bool(pair.get("pass", true)) \
				or not bool(pair.get("containment_undecidable", false)):
			every_row = false
	check("undecidable: a report that could not decide whether the SOLID is "
			+ "inside a reference doubts every node of it — the rows carry "
			+ "the note and none of them passes",
			(whole.get("pairs", []) as Array).size() == 2 and every_row
				and not bool(whole.get("pass", true)),
			"report = %s" % str(whole))

	check("buried: an interference report about a DIFFERENT source is not "
			+ "joined — the node it names keeps its measured gap and its own "
			+ "pass — and the reply says the distances are unsigned",
			absf(float(unjoined.get("min_mm", -1.0)) - GAP_MM) < GAP_TOLERANCE_MM
				and bool(unjoined.get("pass", false))
				and not bool(unjoined.get("interference", false))
				and (unavailable.get("pairs", []) as Array).size() == 2
				and str(unavailable.get("interference_join", "")).contains("unsigned"),
			"pair = %s, join = '%s'" % [str(unjoined),
				str(unavailable.get("interference_join", ""))])
	check("unavailable: with the DSL edited so the solid encloses the near bar "
			+ "and no evaluation of it yet, the clearance does NOT pass — "
			+ "'interference evidence unavailable' — while the worker's "
			+ "unsigned distances are still reported",
			bool(unavailable.get("checked", false))
				and not bool(unavailable.get("pass", true))
				and str(unavailable.get("pass_reason", "")).contains(
					"interference evidence unavailable")
				and (unavailable.get("pairs", []) as Array).size() == 2,
			"report = %s" % str(unavailable))

	# THE JOIN IS ONLY AS FRESH AS THE POSES AND COLLIDERS IT WAS MEASURED
	# AT. The DSL is unchanged, so the source digest still matches — but the
	# reference has been moved since the report ran (here: a pose rewritten
	# in place, the way the panel re-poses), or the colliders rebuilt. A
	# reference that moved INTO the solid after the report was written reads
	# as a positive, unsigned gap, and the old clean report would vouch for
	# it. So the report is stale, nothing is joined, and the check cannot
	# pass: whether any node is buried is unknown. A report stamped at the
	# current state passes again.
	panel.last_eval = _interference_over(SOURCE, [])
	var settled: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var record: Dictionary = panel.records[0]
	record["pose"] = Transform3D(_pose.basis, _pose.origin + REPOSE_SHIFT)
	var after_move: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	record["pose"] = _pose
	# The stand-in's memory of uploaded keys points at files the module's
	# sweep has since replaced; a real worker keeps its own cache. Forget them
	# so the next calls upload afresh rather than decode a swept path.
	_known_blobs.clear()
	var generation_before := int(panel.gauge.get_generation())
	panel.gauge.build([{"mesh": (record["parts"] as Array)[0]["mesh"],
		"transform": _pose, "node": NEAR_NODE, "reference": REFERENCE_NAME}],
		"clearance-fixture|rebuilt")
	var after_rebuild: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	panel.last_eval = _interference_over(SOURCE, [])
	var restamped: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	check("stale: a clean interference report about THIS source but about "
			+ "reference poses that have since moved, or colliders since "
			+ "rebuilt, is not fresh — the check does not pass, says why, "
			+ "and the join note says STALE; a report stamped at the current "
			+ "state passes again",
			bool(settled.get("pass", false))
				and bool(after_move.get("checked", false))
				and not bool(after_move.get("pass", true))
				and str(after_move.get("pass_reason", "")).contains("since changed")
				and str(after_move.get("interference_join", "")).begins_with("STALE")
				and (after_move.get("pairs", []) as Array).size() == 2
				and int(panel.gauge.get_generation()) == generation_before + 1
				and bool(after_rebuild.get("checked", false))
				and not bool(after_rebuild.get("pass", true))
				and str(after_rebuild.get("pass_reason", "")).contains("rebuilt")
				and bool(restamped.get("pass", false))
				and not restamped.has("pass_reason"),
			"settled=%s move=%s rebuild=%s restamped=%s" % [
				str(settled.get("pass")), str(after_move.get("pass_reason",
					after_move.get("pass"))), str(after_rebuild.get("pass_reason",
					after_rebuild.get("pass"))), str(restamped.get("pass_reason",
					restamped.get("pass")))])
	panel.last_eval = _interference_over(SOURCE, [])


## An eval result carrying an interference report over `nodes`, stamped with
## the digest of `source` — the same SHA-256 of the DSL text the check writes
## on its own report, which is how a clearance call tells a report about this
## document from one about the last — and with the stub panel's CURRENT
## reference poses (through the gauge's own records-to-bodies digest) and
## collider generation, which is how it tells a report about these poses from
## one about where the references used to stand.
func _interference_over(source: String, nodes: Array,
		undecided: Array = [], whole_reference: String = "") -> Dictionary:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(source.to_utf8_buffer())
	var pairs: Array = []
	for node in nodes:
		pairs.append({"reference": REFERENCE_NAME, "node": str(node)})
	var open_questions: Array = []
	for node in undecided:
		open_questions.append({
			"reference": REFERENCE_NAME,
			"node": str(node),
			"reason": "every probe this node offered landed in its own hole",
		})
	if not whole_reference.is_empty():
		# The direction-1 shape: no node, because the question was whether the
		# whole solid is inside this reference.
		open_questions.append({
			"reference": whole_reference,
			"node": "",
			"reason": "no probe taken from the solid's own edges could be "
				+ "verified inside its material",
		})
	return {"interference": {
		"checked": true,
		"count": pairs.size(),
		"pairs": pairs,
		"undecidable": open_questions,
		"source_digest": hasher.finish().hex_encode(),
		"records_digest": MeshGauge.bodies_digest(
			MeshGauge.bodies_from_records(_stub.records)),
		"gauge_generation": int(_stub.gauge.get_generation()),
	}}


# ---------------------------------------------------------------------------
# MORE NODES THAN THE WORKER CACHES — the iteration loop, twice
# ---------------------------------------------------------------------------

## A board is one cache entry per NODE, and the worker's cache is bounded. The
## first call in a session always passes, whatever the bound: nothing is
## cached, everything is uploaded, everything is answered. It is the SECOND
## call that finds the worker holding some of the set and not the rest — and a
## retry that names only the keys the worker reported missing uploads exactly
## the blobs that evict the ones it kept, so the retry is answered with a
## fresh set of misses and the panel, its one retry spent, calls that an
## unreadable file.
##
## ORACLE: run the same check twice against a reference with more nodes than
## the stand-in caches. A panel that assumes residency across calls fails the
## second one — and only the second one, which is why a one-shot smoke test
## never saw this.
func _check_more_nodes_than_the_worker_caches(panel: Node, checks: RefCounted) -> void:
	var bar: ArrayMesh = await _bake_bar(0.0)
	var parts: Array = []
	for index in range(EVICTION_NODES):
		# One mesh, one local transform each: distinct world triangles, so
		# distinct blobs and distinct cache entries, without baking twenty
		# meshes. The drop keeps every node clear of the solid.
		parts.append({
			"mesh": bar,
			"transform": Transform3D(Basis.IDENTITY,
				Vector3(0.0, 0.0, -float(index))),
			"node_path": "Assembly/Node%d" % index,
			"node": "Assembly/Node%d" % index,
		})
	var box := _world_box(0.0).merge(_world_box(-float(EVICTION_NODES)))
	panel.records = [{
		"name": REFERENCE_NAME,
		"pose": _pose,
		"world_aabb": box,
		"parts": parts,
	}]
	panel.source = SOURCE
	panel.last_eval = _interference_over(SOURCE, [])

	_mode = "measure"
	_known_blobs.clear()
	_cache_order.clear()
	_cache_bound = EVICTION_CACHE_BOUND
	_payloads.clear()
	var first: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	check("eviction: the fixture really is bigger than the worker's cache — "
			+ "%d nodes into %d entries" % [EVICTION_NODES, EVICTION_CACHE_BOUND],
			_targets_of(0).size() == EVICTION_NODES
				and EVICTION_NODES > EVICTION_CACHE_BOUND
				and _known_blobs.size() == EVICTION_CACHE_BOUND,
			"targets = %d, cached = %d" % [_targets_of(0).size(), _known_blobs.size()])
	check("eviction: the first call in a session is answered, as it always was",
			bool(first.get("checked", false)) and bool(first.get("pass", false)),
			"report = %s" % str(first))

	_payloads.clear()
	var second: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	check("eviction: and so is the second, on a reference with more nodes "
			+ "than the worker keeps",
			bool(second.get("checked", false)) and bool(second.get("pass", false))
				and (second.get("pairs", []) as Array).size() == EVICTION_NODES,
			"report = %s" % str(second))
	check("eviction: the retry carried a path for EVERY target, not only the "
			+ "keys the worker named — the uploads evict the rest",
			_payloads.size() >= 2
				and _targets_of(1).size() == EVICTION_NODES
				and _targets_of(1).all(func(t): return not str(
					(t as Dictionary).get("path", "")).is_empty()),
			"retry targets = %s" % str(_targets_of(1)))

	_cache_bound = 0
	_cache_order.clear()


func _pair_for(report: Dictionary, node: String) -> Dictionary:
	for entry in (report.get("pairs", []) as Array):
		var pair: Dictionary = entry
		if str(pair.get("node", "")) == node:
			return pair
	return {}


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
	# from its own snapshot, so a check running now finds the records the
	# interference path was submitted with — not the ones the clearance call
	# read off the panel.
	check("isolation: a clearance check leaves the interference check's own "
			+ "records exactly as it found them",
			(checks._records as Array).size() == 1
				and str((checks._records[0] as Dictionary).get("name", ""))
					== "submitted-by-the-interference-check",
			"records = %s" % str(checks._records))

	var directory := _blob_dir
	checks.release()
	check("isolation: a panel releases its blob directory when it goes away",
			not DirAccess.dir_exists_absolute(directory),
			"%s survived release()" % directory)


# ---------------------------------------------------------------------------
# A PIN HAS TO SURVIVE A RE-POSE
# ---------------------------------------------------------------------------

## Two calls, one blob store, and a re-pose in between.
##
## The panel names geometry by hash and uploads it only when the worker says
## it has never seen it — so between a call's first request and its retry, the
## body it is about to upload has to still exist. Call A extracts the near
## bar, is told the digest is missing, and waits; while it waits the reference
## is re-posed and call B extracts the SAME NODE at its new place. Storing
## bodies under the node's name means B's body evicts A's, and A's retry then
## has nothing to upload for a digest it holds a pin on: the answer comes back
## `checked: false` for a reason that is entirely the panel's own bookkeeping.
## Bodies are therefore stored under their DIGEST, which is what the files are
## addressed by and what the pin names.
func _check_pin_across_a_repose(panel: Node, checks: RefCounted) -> void:
	var original: Array = panel.records
	_payloads.clear()
	_known_blobs.clear()
	_mode = "measure"

	# A goes first and is NOT awaited: it is still waiting for the worker's
	# "I have never seen this" when the re-pose lands.
	var replies: Array = []
	_collect_clearance(checks, panel, replies)

	panel.records = _records_moved(original, REPOSE_SHIFT)
	var moved: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	panel.records = original

	for _frame in range(600):
		if not replies.is_empty():
			break
		await process_frame
	var first: Dictionary = replies[0] if not replies.is_empty() else {}

	check("pin: a call whose reference is re-posed while it waits still "
			+ "uploads the geometry it pinned — both calls measure, and "
			+ "neither is refused for want of a body it had already hashed",
			bool(first.get("checked", false))
				and (first.get("pairs", []) as Array).size() == 2
				and bool(moved.get("checked", false))
				and (moved.get("pairs", []) as Array).size() == 2,
			"first = %s, moved = %s" % [
				str(first.get("reason", first.get("checked"))),
				str(moved.get("reason", moved.get("checked")))])

	# A CACHE FILE IS ONLY THE FILE ITS NAME CLAIMS. The name is a hash, so a
	# blob of the right LENGTH and the wrong bytes — a half-written file from
	# a crash, a damaged cache — is not the geometry it is addressed as. Reused
	# on its length alone it poisons every retry: the worker refuses the hash,
	# the caller uploads "again", the same bytes are handed over again, and the
	# check never recovers.
	_payloads.clear()
	_known_blobs.clear()
	var report: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var written := PackedStringArray()
	for entry in _targets_of(1):
		written.append(str((entry as Dictionary)["path"]))
	var corrupted := ""
	if written.size() > 0:
		corrupted = written[0]
		var file := FileAccess.open(corrupted, FileAccess.READ)
		var raw := file.get_buffer(int(file.get_length()))
		file.close()
		# The same number of bytes, one of them different: only a hash can
		# tell this apart from the real thing.
		raw[raw.size() - 1] = (int(raw[raw.size() - 1]) + 1) % 256
		var damaged := FileAccess.open(corrupted, FileAccess.WRITE)
		damaged.store_buffer(raw)
		damaged.close()

	_payloads.clear()
	_known_blobs.clear()
	var again: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var repaired := false
	if not corrupted.is_empty():
		var file := FileAccess.open(corrupted, FileAccess.READ)
		if file != null:
			var raw := file.get_buffer(int(file.get_length()))
			file.close()
			var hasher := HashingContext.new()
			hasher.start(HashingContext.HASH_SHA256)
			hasher.update(raw)
			repaired = hasher.finish().hex_encode() \
				== corrupted.get_file().get_basename()
	check("blob: a cache file of the right length and the wrong bytes is "
			+ "rewritten, not reused — the name is a hash, and only the bytes "
			+ "can prove the file is the one it is named for",
			bool(report.get("checked", false)) and not corrupted.is_empty()
				and repaired and bool(again.get("checked", false)),
			"corrupted = %s, repaired = %s, again = %s" % [corrupted,
				str(repaired), str(again.get("reason", again.get("checked")))])

	_payloads.clear()
	_known_blobs.clear()


# ---------------------------------------------------------------------------
# A POSE REWRITTEN IN PLACE, UNDER A CALL IN FLIGHT
# ---------------------------------------------------------------------------

## The panel's records are live objects: a re-pose does not hand out a new
## array, it writes the record's pose where it stands. A call that kept the
## array it was given as its "snapshot" would, after the worker's round trip,
## convert the world geometry it hashed at the OLD pose through the NEW one —
## every world number right, every local one wrong, and the pose comparison
## finding nothing changed because it compares the record with itself.
##
## The geometry was extracted at the poses of entry, so the honest answer is
## the one in THOSE poses: local coordinates converted through the copy, and
## the reply saying the references moved while it waited.
func _check_pose_rewritten_in_place(panel: Node, checks: RefCounted) -> void:
	_payloads.clear()
	_known_blobs.clear()
	_mode = "measure"
	var record: Dictionary = panel.records[0]
	var moved := Transform3D(_pose.basis, _pose.origin + REPOSE_SHIFT)

	var replies: Array = []
	_collect_clearance(checks, panel, replies)
	# The call is waiting for the worker's "never seen it"; the record it
	# was handed is now rewritten in place — same array, same dictionary.
	record["pose"] = moved
	for _frame in range(600):
		if not replies.is_empty():
			break
		await process_frame
	record["pose"] = _pose
	var first: Dictionary = replies[0] if not replies.is_empty() else {}

	var pair := _pair_for(first, NEAR_NODE)
	var world := _as_vector((pair.get("reference_point_mm", {}) as Dictionary)
		.get("world", []))
	var local := _as_vector((pair.get("reference_point_mm", {}) as Dictionary)
		.get("local", []))
	var through_old: Vector3 = _pose.affine_inverse() * world
	var through_new: Vector3 = moved.affine_inverse() * world
	# And a call that nothing moves under says so.
	var settled: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	check("poses: a record whose pose is rewritten IN PLACE while a call "
			+ "waits for the worker is answered in the pose the call was "
			+ "made with — local points converted through the copied pose, "
			+ "never the live one — and the reply says the references moved",
			bool(first.get("checked", false))
				and bool(first.get("references_moved", false))
				and local.distance_to(through_old) < 0.001
				and local.distance_to(through_new) > 1.0
				and bool(settled.get("checked", false))
				and not bool(settled.get("references_moved", true)),
			"first = %s, local = %s, old = %s, new = %s, settled moved = %s" % [
				str(first.get("reason", first.get("checked"))), str(local),
				str(through_old), str(through_new),
				str(settled.get("references_moved"))])
	_payloads.clear()
	_known_blobs.clear()


## The geometry the worker measured was extracted from the part records; a
## part whose transform or mesh is swapped while the call waits describes
## geometry the answer was not measured on. The reply must say the references
## moved and must not pass — a pass here would be a distance reported for
## parts that are no longer in that arrangement.
func _check_parts_changed_during_await(panel: Node, checks: RefCounted) -> void:
	for kind in ["transform", "mesh"]:
		_payloads.clear()
		_known_blobs.clear()
		var part: Dictionary = panel.records[0]["parts"][0]
		var original: Variant = part[kind]
		var replies: Array = []
		_collect_clearance(checks, panel, replies)
		if kind == "transform":
			part[kind] = Transform3D(Basis.IDENTITY, Vector3(10,0,0))
		else:
			var replacement := ArrayMesh.new()
			replacement.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, BoxMesh.new().get_mesh_arrays())
			part[kind] = replacement
		for _frame in range(600):
			if not replies.is_empty():
				break
			await process_frame
		part[kind] = original
		var report: Dictionary = replies[0] if not replies.is_empty() else {}
		check("mid-flight part " + kind + " change prevents clearance passing",
			bool(report.get("references_moved", false)) and not bool(report.get("pass", true)), str(report))
	_payloads.clear()
	_known_blobs.clear()


# ---------------------------------------------------------------------------
# A TOLERANCE THAT IS A GUESS IS NOT A BOUND
# ---------------------------------------------------------------------------

## The worker derives its chord step from the widest curved face it can read.
## A face it cannot read — a spline, a revolution — leaves it guessing from
## the bounding box, and it says so with tolerance_bounded false. A distance
## with no error bar cannot be judged against required_mm, so the panel's
## verdict is FALSE with a reason. The opt-in does not lift that: accepting an
## unbounded tolerance asks for the distances to be graded on min_mm alone,
## which yields an ADVISORY grade — advisory true, pass still false, per pair
## and overall — never a pass. The flag travels either way.
func _check_unbounded_tolerance(panel: Node, checks: RefCounted) -> void:
	_mode = "unbounded"
	var doubted: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var accepted: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5, "accept_unbounded_tolerance": true})
	_mode = "measure"
	var line: String = checks.clearance_status_line(doubted)
	check("tolerance: a worker reply whose tolerance is not a bound fails "
			+ "the check with a reason and a status line that says so, "
			+ "is advisory even when the caller accepts an unbounded tolerance, "
			+ "and carries the flag and the requested tolerance either way",
			bool(doubted.get("checked", false))
				and not bool(doubted.get("pass", true))
				and not bool(doubted.get("tolerance_bounded", true))
				and str(doubted.get("pass_reason", "")).contains("not guaranteed")
				and str(doubted.get("bound", "")).contains(
					"not guaranteed for unrecognised curved faces")
				and absf(float(doubted.get("requested_tolerance_mm", 0.0))
					- GeometryChecks.CLEARANCE_TOLERANCE_MM) < 1.0e-9
				and line.contains("NOT guaranteed")
				and bool(accepted.get("checked", false))
				and not bool(accepted.get("pass", true))
				and bool(accepted.get("advisory", false))
				and accepted.has("pass_reason")
				and not bool(accepted.get("tolerance_bounded", true))
				and (doubted.get("pairs", []) as Array).size() == 2
				and not bool(((doubted.get("pairs", []) as Array)[0] as Dictionary)
					.get("pass", true)),
			"doubted = %s, accepted = %s, line = %s" % [str(doubted),
				str(accepted.get("pass")), line])

	# The opt-in grades the distance as advisory; it cannot certify a pass.
	# The worker's own verdict
	# subtracts its estimate whether or not that estimate is a bound, so a
	# 0.505 mm gap against a 0.5 mm requirement with a 0.01 mm estimate FAILS
	# in the worker's reply (0.495 < 0.5). The caller who accepts an unbounded
	# tolerance has asked for the distances alone, so the panel regrades every
	# pair on min_mm against required_mm — 0.505 >= 0.5 is advisory_pass — and the reply
	# says the bar was waived and what each pair was graded on. Without the
	# opt-in the same reply fails with the reason.
	_mode = "unbounded"
	_gap_mm = 0.505
	var refused: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5, "tolerance_mm": 0.0025})
	var waived: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5, "tolerance_mm": 0.0025,
			"accept_unbounded_tolerance": true})
	_gap_mm = GAP_MM
	_mode = "measure"
	var refused_near := _pair_for(refused, NEAR_NODE)
	var waived_near := _pair_for(waived, NEAR_NODE)
	# bound_mm carries the float32 quantization of the vertices too (a
	# thirty-thousandth of a millimetre at this pose), waived bar or not.
	var quantum := float(refused.get("quantization_mm", 0.0))
	check("tolerance: with the bar waived the advisory grade IS the distance — a "
			+ "0.505 mm gap, 0.5 mm required, 0.01 mm estimated fails on the "
			+ "worker's subtraction, is advisory on min_mm alone under the "
			+ "opt-in with the reply saying the bar was waived, and fails "
			+ "with the reason without it",
			absf(float(refused.get("tessellation_tolerance_mm", 0.0)) - 0.01) < 1.0e-9
				and absf(float(refused_near.get("min_mm", 0.0)) - 0.505) < 1.0e-6
				and absf(float(refused_near.get("bound_mm", 0.0)) - (0.495 - quantum)) < 1.0e-9
				and not bool(refused_near.get("pass", true))
				and not bool(refused.get("pass", true))
				and str(refused.get("pass_reason", "")).contains("not guaranteed")
				and not refused.has("tolerance_waived")
				and not bool(waived_near.get("pass", true))
				and bool(waived_near.get("advisory_pass", false))
				and absf(float(waived_near.get("bound_mm", 0.0)) - (0.505 - quantum)) < 1.0e-9
				and str(waived_near.get("graded_on", "")).contains("waived")
				and not bool(waived.get("pass", true))
				and bool(waived.get("advisory", false))
				and bool(waived.get("tolerance_waived", false))
				and str(waived.get("waiver", "")).contains("WAIVED")
				and waived.has("pass_reason")
				and not bool(waived.get("tolerance_bounded", true)),
			"refused = %s, waived = %s" % [str(refused_near), str(waived)])


# ---------------------------------------------------------------------------
# THE VERTICES TRAVEL AS FLOAT32
# ---------------------------------------------------------------------------

## The blob body is float32, so every world coordinate lands on a grid whose
## pitch is the float32 spacing at its magnitude — an error bar of its own,
## beside the tessellation's. At the fixture's pose it is 2^-15 mm and is
## reported, stated in the bound and subtracted from bound_mm; at a pose a
## hundred million millimetres out it is 8 mm, coarser than any tolerance
## asked for, and the check refuses with the number rather than quote a bar
## it cannot keep.
func _check_quantization(panel: Node, checks: RefCounted) -> void:
	_payloads.clear()
	var near: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	var near_pair := _pair_for(near, NEAR_NODE)
	var quantum := float(near.get("quantization_mm", 0.0))
	check("quantization: at the fixture's pose the float32 step is 2^-15 mm — "
			+ "reported, three orders under the 0.01 mm tolerance, set by the "
			+ "300 mm coordinate, stated in the bound and subtracted from "
			+ "bound_mm beside the tessellation tolerance",
			bool(near.get("checked", false))
				and absf(quantum - NEAR_QUANTIZATION_MM) < 1.0e-12
				and quantum < GeometryChecks.CLEARANCE_TOLERANCE_MM / 100.0
				and absf(float(near.get("largest_coordinate_mm", 0.0)) - POSE_ORIGIN.z) < 0.5
				and str(near.get("bound", "")).contains("quantized")
				and absf(float(near_pair.get("bound_mm", 0.0))
					- (float(near_pair.get("min_mm", 0.0))
						- GeometryChecks.CLEARANCE_TOLERANCE_MM - quantum)) < 1.0e-9
				and bool(near.get("pass", false)),
			"report = %s" % str(near))

	var record: Dictionary = panel.records[0]
	record["pose"] = Transform3D(_pose.basis, FAR_ORIGIN)
	_payloads.clear()
	var far: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	record["pose"] = _pose
	check("quantization: a pose 1e8 mm out quantizes the vertices to 8 mm, "
			+ "coarser than the tolerance asked for — the check is refused "
			+ "with the quantization and the coordinate stated, and nothing "
			+ "is sent to the worker",
			not bool(far.get("checked", true))
				and str(far.get("reason", "")).contains("float32")
				and absf(float(far.get("quantization_mm", 0.0)) - FAR_QUANTIZATION_MM) < 1.0e-9
				and float(far.get("largest_coordinate_mm", 0.0)) >= FAR_ORIGIN.x - 1.0
				and (far.get("pairs", []) as Array).is_empty()
				and _payloads.is_empty(),
			"report = %s, sent = %d" % [str(far), _payloads.size()])
	_payloads.clear()


## Start a clearance call without awaiting it and park its reply in `into`.
func _collect_clearance(checks: RefCounted, panel: Node, into: Array) -> void:
	var reply: Dictionary = await checks.check_clearance(panel,
		{"required_mm": 0.5})
	into.append(reply)


## The suite's records under a shifted pose — the same nodes, somewhere else.
func _records_moved(records: Array, shift: Vector3) -> Array:
	var out: Array = []
	for entry in records:
		var record: Dictionary = (entry as Dictionary).duplicate()
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		record["pose"] = Transform3D(pose.basis, pose.origin + shift)
		out.append(record)
	return out


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

	# Resolve every target's blob BEFORE answering and hold the resolved path
	# here, exactly as the worker holds the built tree in a local list: the
	# cache may evict an entry later in the same request — a batch larger than
	# the bound always does — and that must not lose a target the request has
	# already read.
	var targets: Array = args.get("targets", []) as Array
	var missing: Array = []
	var prepared: Array = []
	for entry in targets:
		var target: Dictionary = entry
		var key := str(target.get("key", ""))
		var path := str(target.get("path", ""))
		if not path.is_empty():
			_remember_blob(key, path)
		if _known_blobs.has(key):
			prepared.append([target, str(_known_blobs[key])])
		else:
			missing.append(key)
	if not missing.is_empty():
		return {"ok": true, "result": {
			"checked": false, "units": "mm", "pairs": [],
			"reason": "no cached geometry", "missing_keys": missing,
		}}

	# The solid's world position is the fixture's, and the reference's comes
	# out of the bytes the module shipped — so the gap is measured across the
	# panel's own product.
	var solid_bottom_z := POSE_ORIGIN.z + _gap_mm
	var required := float(args.get("required_mm", 0.0))
	var tolerance := float(args.get("tolerance_mm", 0.0))
	# "unbounded" is the worker's answer for a solid with a curved face it
	# could not measure: the tolerance is a bounding-box guess, and it says so.
	var bounded := _mode != "unbounded"
	# The worker's verdict arithmetic, verbatim: the bar is the EFFECTIVE
	# tolerance, subtracted whether it is a bound or a guess, and a pair
	# passes only when what is left meets the requirement.
	var effective := tolerance * (1.0 if bounded else 4.0)
	var pairs: Array = []
	for held in prepared:
		var target: Dictionary = (held as Array)[0]
		var blob := _decode_blob(str((held as Array)[1]))
		var box: AABB = blob["box"]
		var top_z: float = box.position.z + box.size.z
		var min_mm: float = maxf(solid_bottom_z - top_z, 0.0)
		var bound_mm := maxf(min_mm - effective, 0.0)
		var pair := {
			"reference": str(target.get("reference", "")),
			"node": str(target.get("node", "")),
			"key": str(target.get("key", "")),
			"min_mm": min_mm,
			"bound_mm": bound_mm,
			"pass": min_mm > 0.0 and bound_mm >= required,
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
	return {"ok": true, "result": {
		"checked": true,
		"units": "mm",
		"pass": pairs.all(func(p): return bool(p["pass"])),
		"required_mm": required,
		"tessellation_tolerance_mm": effective,
		"requested_tolerance_mm": tolerance,
		"tolerance_bounded": bounded,
		"bound": ("the true clearance is at least min_mm - %s mm" % tolerance)
			if bounded else ("chord error ESTIMATED at %s mm; the estimate is "
				% (tolerance * 4.0)) + "not guaranteed for unrecognised curved faces",
		"solid_triangles": 12,
		"engine": "stand-in for python-fcl",
		"cache": {"hits": pairs.size(), "misses": 0, "entries": pairs.size()},
		"pairs": pairs,
	}}


## Take a blob into the stand-in's cache, evicting the oldest when the bound
## binds. THE EVICTION HAPPENS AS THE UPLOADS ARRIVE, exactly as the real
## worker's LRU does: a retry that carries only the keys the last reply named
## missing evicts the ones it did not, and is answered with a fresh set.
func _remember_blob(key: String, path: String) -> void:
	if _known_blobs.has(key):
		_cache_order.erase(key)
	_known_blobs[key] = path
	_cache_order.append(key)
	if _cache_bound <= 0:
		return
	while _cache_order.size() > _cache_bound:
		var evicted: String = str(_cache_order.pop_front())
		_known_blobs.erase(evicted)


class _StubPanel extends Node:
	## The five things geometry_checks.check_clearance asks a panel for. The
	## last eval result is where the interference report the clearance verb
	## joins against arrives from.
	var source: String = ""
	var records: Array = []
	var last_eval: Dictionary = {}
	var answer: Callable
	var gauge: Node = null

	func get_document_state() -> Dictionary:
		return {"source": source, "path": "", "mesh": {},
			"references": [], "last_eval": last_eval}

	func get_mesh_gauge() -> Node:
		return gauge

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


## Where a bar with its top face at `top_z` ends up in the world: the box
## around its eight POSED corners, since the pose turns it.
func _world_box(top_z: float) -> AABB:
	var box := AABB()
	var seen := false
	for x in [-BAR_HALF_LENGTH, BAR_HALF_LENGTH]:
		for y in [-BAR_HALF_WIDTH, BAR_HALF_WIDTH]:
			for z in [top_z - BAR_THICKNESS, top_z]:
				var corner: Vector3 = _pose * Vector3(x, y, z)
				box = AABB(corner, Vector3.ZERO) if not seen else box.expand(corner)
				seen = true
	return box


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
	# The digest covers the HEADER as well as the body, exactly as the panel
	# and the worker compute it: the counts decide how the same bytes are read
	# back, so two readings of one buffer must not share a key.
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(raw.slice(0, 20))
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


## A DSL source of about `length` CHARACTERS whose padding unit is three
## characters and six UTF-8 bytes (a 2-byte micro sign, a 1-byte letter and a
## 3-byte em dash), so its byte length is twice its character length — enough
## to carry a source that fits by characters past a limit measured in bytes.
func _multibyte_source(length: int) -> String:
	var padding: int = maxi(length - SOURCE.length() - 3, 0)
	return SOURCE + "\n# " + "\u00b5m\u2014".repeat(int(padding / 3.0))


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
