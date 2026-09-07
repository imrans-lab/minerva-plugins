extends "clearance_report.gd"
## clearance_client.gd — the clearance verb: what it asks the worker, and how
## it hands an answer back inside the caller's window.
##
## Split out of geometry_checks.gd, which had grown to hold two whole
## subsystems: the ray-walk interference check that runs inside a physics step,
## and this one — a worker round trip over a content-addressed blob cache. They
## share nothing but the small frame helpers in scripts/clearance_blobs.gd and
## the pair key the join is filed under.
##
## THE SPLIT IS AN INHERITANCE, NOT A HANDLE. This script extends the report
## fold (scripts/clearance_report.gd), which extends the blob store
## (scripts/clearance_blobs.gd), and the interference chain geometry_checks.gd
## tops extends this one through reference_pairs.gd — so a single object
## still carries every layer's public surface: the panel,
## panel_tools and fastener_checks all hold one geometry-checks instance, and
## the blob directory is named after that instance. Separate objects would have
## renamed the directory and given every caller several things to hold.
##
## What lives here: the measurement job table, whose ticket outlives the tool
## call that started it; the request batching that keeps every message under
## the host's channel cap; and the one retry that uploads geometry the worker
## turns out not to have.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: extended by scripts/reference_pairs.gd, and through it by the
## interference chain scripts/geometry_checks.gd tops.


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

## The panel's evaluation freshness, filed with each ticket when its
## measurement starts and compared at collection.
const _Freshness: Script = preload("eval_freshness.gd")

## Tessellation deviation the measurement asks for, in millimetres. The
## display mesh is tessellated for looking at; a clearance is quoted with this
## number as its error bar, so the check asks for its own, tighter one.
const CLEARANCE_TOLERANCE_MM: float = 0.01

## How long the verb itself waits for a measurement before handing back a
## ticket instead. The caller is an MCP client with its OWN window — around a
## minute, and not ours to widen — and a tool call that outlives it is
## reported as a timeout with nothing to collect and the work thrown away. So
## the verb always answers inside that window: with the report when it is
## ready, and otherwise with the ticket the next call collects it by.
const FIRST_REPLY_MS: int = 20000
## How long a job stays in the table for its ticket to be collected.
const TICKET_KEEP_MS: int = 900000

## The host caps a panel-to-plugin payload at 64 KiB
## (PluginScenePanelBroker.MAX_PAYLOAD_BYTES), measured as the JSON length of
## the payload it receives. The margin covers the difference between the
## caller's stringification and the broker's — float formatting need not agree
## byte for byte — and a request over the cap is refused by the host as
## payload_too_large, which says nothing about clearances.
const IPC_PAYLOAD_LIMIT_BYTES: int = 65536
const IPC_PAYLOAD_MARGIN_BYTES: int = 2048

## Measurements that outlived the verb that started them, by ticket:
## {status, started_ms, settled_ms, report, freshness}. `freshness` is the
## panel's evaluation freshness when the measurement started — the evaluation
## its numbers are about, whatever paints before the ticket is collected. A
## job is erased when its report is handed back, so a ticket names one answer
## exactly once.
var _jobs: Dictionary = {}
var _next_ticket: int = 0
## How long the verb waits before handing back a ticket when the call does
## not say (`wait_ms`). Read from the variable rather than the constant so a
## suite can drive the handover without spending the window waiting for it;
## nothing in the panel ever writes it.
var first_reply_ms: int = FIRST_REPLY_MS


## Delete this panel's blob directory. Called when the panel goes away: the
## sweep only ever runs during an upload, so without this a closed document's
## blobs would sit in the cache until some later document happened to write
## over the same directory — which, now that each panel owns its own, would
## never happen.
func release() -> void:
	# The pins outlive their call only when a measurement's coroutine died
	# holding them; the panel going away is the last chance to drop them.
	_pinned_digests.clear()
	# A job still running holds its own dictionary and will settle into it;
	# dropping the table only means nobody can collect a report about a
	# document that has gone away.
	_jobs.clear()
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
## accept_unbounded_tolerance= (default false), expected_contacts=,
## ticket= (collect only).
##
## EXPECTED CONTACTS. An assembled design touches itself on purpose — a keycap
## on an actuator, a holder on a door — and grading those against required_mm
## leaves no reachable pass. A pair named in expected_contacts is graded
## against the gap IT declares (0, the default, means they may touch) instead
## of required_mm, and appears in `expected_contacts` with the value measured
## for it beside `excluded_count`. Material overlap deeper than the
## declaration allows still fails: an exclusion cannot hide a crash. See
## scripts/expected_contacts.gd.
##
## IT ALWAYS ANSWERS, WHETHER OR NOT IT HAS MEASURED. The worker re-tessellates
## the solid at the measurement tolerance, and on a lofted shell that is
## minutes of OCCT — far past the window the MCP client gives a tool call,
## which is not ours to widen. So the measurement runs as a job and this verb
## returns inside FIRST_REPLY_MS either way: the finished report, or
## {checked: false, status: "running", ticket} naming the ticket a later call
## collects it by. Every settled reply carries `status`, the `ticket` it was
## filed under and `measured_ms`, so a reader can always tell a report that
## was measured from one that is still being measured. A ticket is spent when
## its report is handed back.
##
## The reply is the worker's, re-framed:
##
##   {checked, units, pass, pass_reason?, required_mm, expected_contacts?,
##    excluded_count?,
##    tessellation_tolerance_mm, requested_tolerance_mm, tolerance_bounded,
##    bound, references_moved,
##    pairs: [{reference, node, min_mm, bound_mm, pass, solid_point_mm,
##             reference_point_mm: {world, local}, interference?, touching?,
##             expected?, required_mm?, note?}],
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
##
## CONTACT IS NOT INTERFERENCE. A pair with no air between the meshes measures
## 0 whether the surfaces are flush or one body is inside the other, and an
## unsigned distance cannot tell those apart. Such a pair is reported with
## `touching` and fails every required gap above zero; the `interference` flag
## is the joined report's to give, and appears only for a node it names.
func check_clearance(panel: Object, args: Dictionary = {}) -> Dictionary:
	if panel == null or not is_instance_valid(panel):
		return _no_clearance("the CAD panel is gone")
	var handle := str(args.get("ticket", ""))
	if not handle.is_empty():
		return await _collect(handle, maxi(int(args.get("wait_ms", 0)), 0), panel)
	_sweep_jobs()
	var required_mm := float(args.get("required_mm", 0.0))
	if required_mm <= 0.0:
		return _no_clearance("a clearance check needs required_mm: the "
			+ "distance you want between the solid and everything else")
	var tolerance_mm := float(args.get("tolerance_mm", CLEARANCE_TOLERANCE_MM))
	if tolerance_mm <= 0.0:
		return _no_clearance("tolerance_mm must be greater than zero")
	# A declaration nobody can read is refused rather than dropped: an author
	# who mistyped a reference believes that pair is excused.
	var declared: Dictionary = _Expected.parse(args)
	if not (declared["errors"] as Array).is_empty():
		return _no_clearance("expected_contacts: %s"
			% ", ".join(PackedStringArray(declared["errors"] as Array)))

	var document: Dictionary = {}
	if panel.has_method("get_document_state"):
		document = panel.get_document_state()
	# A part-scoped check states the source that evaluates to ITS part; with
	# none the document's own source is the solid.
	var source := str(args.get("source", ""))
	if source.strip_edges().is_empty():
		source = str(document.get("source", ""))
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

	# The measurement runs as its own coroutine and the verb waits only as long
	# as it may. Everything the job needs from the panel is read HERE, before
	# it detaches: the buried pairs are the interference report standing now.
	var job := {
		"status": "running",
		"started_ms": Time.get_ticks_msec(),
		"settled_ms": 0,
		"report": {},
		"freshness": _Freshness.read(panel),
	}
	var issued := "clearance-%d" % _next_ticket
	_next_ticket += 1
	_jobs[issued] = job
	# Called, not awaited: the coroutine runs to its first await and carries on
	# by itself, so a measurement that outlives this verb still finishes and
	# still lands in its job.
	_measure_into(job, panel, head, plan["batches"] as Array, records,
		_buried_pairs(document, source, records, panel),
		bool(args.get("accept_unbounded_tolerance", false)), bar,
		declared["entries"] as Array)
	# `wait_ms` is the caller's own budget for this call: 0 starts the
	# measurement and hands the ticket straight back, which is how a caller
	# with several parts to measure starts every one before waiting on any.
	await _wait_for(job, maxi(int(args.get("wait_ms", first_reply_ms)), 0))
	if str(job["status"]) == "running":
		return _running(issued, job)
	_jobs.erase(issued)
	return _settled(issued, job, panel)


## Wait up to `budget_ms` for a job to settle, giving the rest of the frame
## back while it does. A module with no scene tree (a caller driving it out of
## one) cannot wait at all, and says so by returning at once.
func _wait_for(job: Dictionary, budget_ms: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var deadline := Time.get_ticks_msec() + budget_ms
	while str(job.get("status", "")) == "running" \
			and Time.get_ticks_msec() < deadline:
		await tree.process_frame


## Run one measurement and leave it in `job`. The pin is taken and dropped
## here so it covers exactly the time the worker is being asked.
func _measure_into(job: Dictionary, panel: Object, head: Dictionary,
		batches: Array, records: Array, buried: Dictionary,
		accept_unbounded: bool, bar: Dictionary,
		expected: Array = []) -> void:
	# The keys this call names are pinned for as long as it runs. Two calls
	# share _blobs and the blob directory, so a reference re-posed between one
	# call's two attempts would otherwise let the other's sweep delete the file
	# the retry names — a single-shot "could not read" with nothing wrong.
	var pinned := _pin(batches)
	var report := await _measure(panel, head, batches, records, buried,
		accept_unbounded, bar, expected)
	_unpin(pinned)
	if bool(report.get("checked", false)):
		report["references_moved"] = is_instance_valid(panel) \
			and panel.has_method("get_reference_state") \
			and not _same_poses(records, panel.get_reference_state() as Array)
		if report["references_moved"]:
			report["pass"] = false
			report["pass_reason"] = "reference geometry changed while clearance was measured; ask again"
	job["report"] = report
	job["settled_ms"] = Time.get_ticks_msec()
	job["status"] = "settled"


## Collect a ticket, waiting up to `wait_ms` for a running job to settle
## first. A ticket is spent when its report is handed back: the answer
## describes geometry that is already ageing, and a reader asking twice must
## measure again rather than be handed a second copy of the old one.
func _collect(handle: String, wait_ms: int, panel: Object) -> Dictionary:
	_sweep_jobs()
	if not _jobs.has(handle):
		return _no_clearance(("no clearance measurement is filed under ticket "
			+ "'%s' — its report was collected already, or nobody collected it "
			+ "for %d s and it was dropped; ask again without a ticket to "
			+ "start a new measurement") % [handle, TICKET_KEEP_MS / 1000])
	var job: Dictionary = _jobs[handle]
	if str(job["status"]) == "running" and wait_ms > 0:
		await _wait_for(job, wait_ms)
	if str(job["status"]) == "running":
		return _running(handle, job)
	_jobs.erase(handle)
	return _settled(handle, job, panel)


## What a measurement that has not finished yet answers with. It is `checked`
## false — nothing has been measured — but it is not a refusal either, and the
## reply says which of the two it is and how to collect the answer.
func _running(handle: String, job: Dictionary) -> Dictionary:
	var waited := Time.get_ticks_msec() - int(job["started_ms"])
	return {
		"checked": false,
		"units": "mm",
		"status": "running",
		"ticket": handle,
		"elapsed_ms": waited,
		"pairs": [],
		"reason": ("the measurement is still running in the worker after "
			+ "%.1f s — the solid is re-tessellated at the measurement "
			+ "tolerance, which on a large lofted shell is minutes of "
			+ "geometry. Nothing has been found: ask again with "
			+ "ticket=\"%s\" to collect the report when it lands.")
			% [waited / 1000.0, handle],
	}


## A settled job's report, stamped with what it cost, which ticket carried
## it, and which evaluation it measured: the freshness filed when the job
## started, against the panel's freshness now, so a report collected after a
## newer evaluation painted says so rather than reading as current. The stamp
## is on every reply, including the ones that came back inside the first wait
## and were never handed a ticket to poll.
func _settled(handle: String, job: Dictionary, panel: Object) -> Dictionary:
	var report: Dictionary = job["report"]
	report["status"] = "complete"
	report["ticket"] = handle
	report["measured_ms"] = int(job["settled_ms"]) - int(job["started_ms"])
	return _Freshness.stamp_ticket(report,
		job.get("freshness", {}) as Dictionary, _Freshness.read(panel))


## Drop jobs nobody collected. A report is geometry-dated and a table that
## grows for the life of the panel is a leak.
##
## A STILL-RUNNING job is never swept, however long it has been running: a
## measurement is several worker batches of minutes each, and erasing its
## ticket mid-flight would leave the report that arrives afterwards with no
## entry to land in and no way to be collected. Only a settled report ages
## out, and it ages from the moment it settled — TICKET_KEEP_MS after there
## was something to collect, not after the work started.
func _sweep_jobs() -> void:
	var now := Time.get_ticks_msec()
	for key in _jobs.keys():
		var job: Dictionary = _jobs[key]
		if str(job.get("status", "")) == "running":
			continue
		if now - int(job.get("settled_ms", 0)) > TICKET_KEEP_MS:
			_jobs.erase(key)


## Ask every batch and fold the replies into one report. Split out so the pin
## its caller takes is dropped on every path out of the measurement.
func _measure(panel: Object, head: Dictionary, batches: Array, records: Array,
		buried: Dictionary, accept_unbounded: bool, bar: Dictionary = {},
		expected: Array = []) -> Dictionary:
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
	return _clearance_report(envelope, raw_pairs, records, buried,
		accept_unbounded, expected)


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

