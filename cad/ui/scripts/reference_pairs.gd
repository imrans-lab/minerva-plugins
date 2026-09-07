extends "clearance_client.gd"
## reference_pairs.gd — how close do the REFERENCES come to each other?
##
## Every other check in this plugin measures the evaluated solid against the
## foreign meshes. Laying parts out inside an enclosure is the other question:
## does the OLED sit on the devkit, does the joystick clear the connector,
## does the battery collar run into the board. Before this, that was read off
## bounding boxes by hand — and a bounding box says a part is clear when it is
## not, because a box is not the part.
##
## THE MEASUREMENT IS THE CLEARANCE ONE, WITHOUT THE SOLID. The same blobs,
## the same content-addressed store, the same upload-on-miss retry and the
## same swept-sphere BVH in the worker; only the pairing is new, and the error
## bar is smaller, because neither side is a tessellated B-Rep. Nothing here
## is tessellated at all, so no tessellation tolerance is quoted and the only
## quantization is the float32 grid the blob is written on.
##
## WHY IT IS IN THE INHERITANCE CHAIN rather than holding a handle: the blob
## store, the pins and the blob directory are per module instance, and a
## second object would have re-extracted every reference's triangles and
## written a second copy of them. geometry_checks.gd extends THIS script,
## which extends the clearance client, so the panel still holds one object.
##
## WHICH PAIRS ARE MEASURED. Node against node, never file against file: a
## board is forty-five nodes and "the board is 2 mm from the shell" is not an
## answer anyone can act on. Pairs are ordered by the gap between their world
## bounding boxes — which is a true LOWER BOUND on the distance — and the
## closest MAX_PAIRS of them are measured. The rest are reported as a bound:
## nothing unmeasured is closer than `unmeasured_bound_mm`, so a measured
## number below that is provably the closest pair in the assembly.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: extended by scripts/geometry_checks.gd; driven by
## ui/panel_tools.gd for minerva_cad_check_clearance / _check_interference
## with two references named.

## The IPC channel, which is also the MCP tool name and the worker method.
const PAIRS_CHANNEL := "cad.reference_pairs"

## How many node pairs one call measures. A six-part layout is a few hundred
## candidate pairs and each is a BVH distance in the worker; the cap keeps a
## careless all-pairs call from becoming a minute of measurement, and the
## reply says what it did not measure and how far away that was.
const MAX_PAIRS: int = 200

## The name that asks for every pair in the document rather than for one pair
## of references.
const ALL_PAIRS := "all-pairs"

## What one [i, j] pair entry costs on the wire, generously: two indices, the
## brackets and the separator.
const PAIR_ENTRY_BYTES: int = 16


## Measure reference nodes against each other.
##
## `args`: reference= (a mounted reference, or "all-pairs"), against= (the
## second reference), node=/against_node= (scope either side the usual way),
## required_mm=, limit=, max_pairs=, expected_contacts=, overlapping_only=
## (what minerva_cad_check_interference asks for).
##
## The reply:
##
##   {checked, units, mode, pass, advisory, pass_reason?, required_mm, scope,
##    pairs: [{a: {reference, node}, b: {reference, node}, min_mm, bound_mm,
##             pass, point_a_mm: {world, local}, point_b_mm: {world, local},
##             overlap?, containment?, contact_points_mm?, penetration_mm?,
##             expected?}],
##    pairs_measured, pairs_considered, pairs_shown, pairs_hidden,
##    unmeasured_bound_mm?, quantization_mm, largest_coordinate_mm,
##    expected_contacts?, expected_contacts_unmatched?, excluded_count?,
##    references_moved, engine, cache, bound, note}
##
## sorted closest first. `checked: false` with a `reason` is not the same
## answer as "everything clears": it means the geometry in scope had no pair
## to measure. A CALL that cannot be scoped at all — no reference=/against=,
## a name nothing has mounted, the same reference on both sides — returns
## `{error}` instead, the way the clearance path refuses an unmounted
## reference, so the verb reports a failure rather than a clean sheet.
##
## AN OVERLAP HERE IS NOT THE INTERFERENCE CHECK'S OVERLAP. A mesh-to-mesh
## distance is unsigned: one part wholly inside another measures the air
## between their surfaces, exactly as two parts side by side do. So the
## worker probes containment wherever one node's box lies inside the other's
## (the only place it is possible) and a contained pair is reported as
## overlap, failing any required gap; a probe it could not settle — an open
## mesh — withholds the pass instead of guessing.
## A contact point is located to the two meshes' shared BOUNDING BOX and no
## finer — a point in that box can still be in air — because the collision
## names a triangle corner, not a point of the intersection.
func check_reference_pairs(panel: Object, args: Dictionary = {}) -> Dictionary:
	if panel == null or not is_instance_valid(panel):
		return _no_pairs("the CAD panel is gone")
	var declared: Dictionary = _Expected.parse(args)
	if not (declared["errors"] as Array).is_empty():
		return _no_pairs("expected_contacts: %s"
			% ", ".join(PackedStringArray(declared["errors"] as Array)))

	# A copy for the same reason the clearance path takes one: the panel
	# re-poses a reference by writing its record in place, and the local
	# frames are converted back through the poses the geometry was hashed at.
	var records: Array = []
	if panel.has_method("get_reference_state"):
		records = (panel.get_reference_state() as Array).duplicate(true)

	var scope := _pair_scope(records, args)
	if scope.has("error"):
		# Nothing was measured because the call named nothing measurable. That
		# is the caller's error, not a verdict about the assembly.
		return {"error": str(scope["error"])}
	var parts: Array = scope["parts"]

	var targets: Array = []
	var boxes: Array = []
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
		boxes.append(part["box"])
		if float(blob.get("quantization_mm", 0.0)) > quantization:
			quantization = float(blob["quantization_mm"])
			largest = float(blob.get("largest_coordinate_mm", 0.0))
	if targets.size() < 2:
		return _no_pairs("fewer than two reference nodes in scope carry "
			+ "triangles, so there is no pair to measure")

	var ordered := _candidate_pairs(targets, boxes, scope["cross_only"] as bool)
	if ordered.is_empty():
		return _no_pairs("no pair of reference nodes is in scope; two "
			+ "different references have to be named, or reference=\"%s\""
			% ALL_PAIRS)
	var cap: int = maxi(1, int(args.get("max_pairs", MAX_PAIRS)))
	var measured: Array = ordered.slice(0, mini(cap, ordered.size()))
	var unmeasured_bound := -1.0
	if ordered.size() > measured.size():
		unmeasured_bound = float((ordered[measured.size()] as Dictionary)["bound_mm"])

	var required_mm := float(args.get("required_mm", 0.0))
	var reply := await _ask_pairs(panel, targets, measured, required_mm,
		int(args.get("max_contacts", 0)))
	if reply.has("error"):
		return _no_pairs(str(reply["error"]))
	if not bool(reply.get("checked", false)):
		return _no_pairs(str(reply.get("reason", "the reference-pair "
			+ "measurement did not run and gave no reason")))

	var report := _pairs_report(reply, records, required_mm,
		declared["entries"] as Array, bool(args.get("overlapping_only", false)),
		int(args.get("limit", 0)), quantization)
	report["mode"] = "reference-vs-reference"
	report["scope"] = scope["described"]
	report["quantization_mm"] = quantization
	report["largest_coordinate_mm"] = largest
	report["pairs_considered"] = ordered.size()
	if unmeasured_bound >= 0.0:
		report["unmeasured_bound_mm"] = unmeasured_bound
		report["truncated"] = true
		report["truncated_note"] = ("only the %d closest candidate pairs were "
			+ "measured, ordered by the gap between their world bounding "
			+ "boxes — a true lower bound on the distance — so no unmeasured "
			+ "pair is closer than %s mm; raise max_pairs or scope with node= "
			+ "to measure the rest") % [measured.size(), unmeasured_bound]
		# An unmeasured candidate whose box gap does not itself clear the
		# requirement may be the closest pair in the assembly; the measured
		# rows cannot certify a scope they did not cover.
		if unmeasured_bound - quantization < required_mm:
			report["pass"] = false
			report["pass_reason"] = ("%d candidate pair(s) beyond max_pairs "
				+ "were not measured and their bounding-box gap (%s mm) does "
				+ "not clear required_mm on its own; raise max_pairs or scope "
				+ "with node= before reading this as clear") % [
					ordered.size() - measured.size(), unmeasured_bound]
	report["references_moved"] = panel.has_method("get_reference_state") \
		and not _same_poses(records, panel.get_reference_state() as Array)
	if bool(report["references_moved"]):
		report["pass"] = false
		report["pass_reason"] = "reference geometry changed while the pairs " \
			+ "were measured; ask again"
	return report


# ---------------------------------------------------------------------------
# Scope and pairing
# ---------------------------------------------------------------------------

## Which nodes are in scope and which pairs of them may be measured.
##
## Two named references measure across them and never within either one: two
## nodes of one file are parts of one part. "all-pairs" measures across every
## reference, still never within one.
func _pair_scope(records: Array, args: Dictionary) -> Dictionary:
	var first := str(args.get("reference", "")).strip_edges()
	var second := str(args.get("against", "")).strip_edges()
	var names: Array = []
	for entry in records:
		names.append(str((entry as Dictionary).get("name", "")))
	if first == ALL_PAIRS or second == ALL_PAIRS:
		var every := _parts_with_boxes(records, "", str(args.get("node", "")))
		return {"parts": every, "cross_only": true,
			"described": "every pair of the %d mounted references"
				% names.size()}
	if first.is_empty() or second.is_empty():
		return {"error": ("a reference-against-reference measurement needs "
			+ "reference= and against=, two of the mounted references (%s), "
			+ "or reference=\"%s\" for every pair")
			% [", ".join(PackedStringArray(names)), ALL_PAIRS]}
	if first == second:
		return {"error": "reference= and against= name the same reference "
			+ "('%s'); a part is not measured against itself" % first}
	for named in [first, second]:
		if not names.has(named):
			return {"error": "no reference named '%s' is mounted; mounted: %s"
				% [named, ", ".join(PackedStringArray(names))]}
	var parts := _parts_with_boxes(records, first, str(args.get("node", "")))
	parts.append_array(_parts_with_boxes(records, second,
		str(args.get("against_node", ""))))
	return {"parts": parts, "cross_only": true,
		"described": "%s against %s" % [first, second]}


## The scoped parts with their world bounding boxes, which is what orders the
## pairs before anything is measured.
func _parts_with_boxes(records: Array, reference_scope: String,
		node_scope: String) -> Array:
	var out: Array = []
	for entry in _scoped_parts(records, reference_scope, node_scope):
		var part: Dictionary = entry
		var mesh: Mesh = part["mesh"]
		part["box"] = (part["xform"] as Transform3D) * mesh.get_aabb()
		out.append(part)
	return out


## Candidate pairs, closest bounding boxes first, as
## [{a: index, b: index, bound_mm}]. The box gap is a lower bound on the true
## distance, which is what makes measuring only the head of this list a
## statement about the whole assembly rather than a guess.
func _candidate_pairs(targets: Array, boxes: Array, cross_only: bool) -> Array:
	var out: Array = []
	for first in range(targets.size()):
		for second in range(first + 1, targets.size()):
			if cross_only and str((targets[first] as Dictionary)["reference"]) \
					== str((targets[second] as Dictionary)["reference"]):
				continue
			out.append({
				"a": first,
				"b": second,
				"bound_mm": _box_gap(boxes[first] as AABB, boxes[second] as AABB),
			})
	out.sort_custom(func(x, y): return float((x as Dictionary)["bound_mm"]) \
		< float((y as Dictionary)["bound_mm"]))
	return out


## The distance between two axis-aligned boxes: zero where they overlap.
func _box_gap(first: AABB, second: AABB) -> float:
	var gap := Vector3(
		maxf(0.0, maxf(first.position.x - second.end.x,
			second.position.x - first.end.x)),
		maxf(0.0, maxf(first.position.y - second.end.y,
			second.position.y - first.end.y)),
		maxf(0.0, maxf(first.position.z - second.end.z,
			second.position.z - first.end.z)))
	return gap.length()


# ---------------------------------------------------------------------------
# The worker round trip
# ---------------------------------------------------------------------------

## Ask the worker for one set of pairs, in requests that each fit the host's
## channel cap, uploading the geometry it turns out not to hold.
##
## The pairs name their nodes by INDEX, so each request carries only the
## targets its own pairs name, re-indexed — a batch that shipped the whole
## inventory would spend the payload on nodes it is not asking about.
func _ask_pairs(panel: Object, targets: Array, pairs: Array,
		required_mm: float, max_contacts: int) -> Dictionary:
	var head := {"required_mm": required_mm}
	if max_contacts > 0:
		head["max_contacts"] = max_contacts
	var batches := _batch_pairs(head, targets, pairs)
	if batches.has("error"):
		return {"error": str(batches["error"])}
	var collected: Array = []
	var envelope: Dictionary = {}
	var pinned := PackedStringArray()
	for batch_entry in (batches["batches"] as Array):
		for target_entry in ((batch_entry as Dictionary)["targets"] as Array):
			var digest := str((target_entry as Dictionary)["key"])
			_pinned_digests[digest] = int(_pinned_digests.get(digest, 0)) + 1
			pinned.append(digest)
	for batch_entry in (batches["batches"] as Array):
		var batch: Dictionary = batch_entry
		var reply := await _ask_pair_batch(panel, head, batch)
		if reply.has("error") or not bool(reply.get("checked", false)):
			_unpin(pinned)
			return reply
		envelope = reply
		collected.append_array(reply.get("pairs", []) as Array)
	_unpin(pinned)
	envelope["pairs"] = collected
	return envelope


## One request, retried once with every blob path after a missing-key reply —
## the same rule the clearance batch follows, and for the same reason: the
## worker's cache is bounded, so a retry naming only the reported misses can
## evict the ones it did not name.
func _ask_pair_batch(panel: Object, head: Dictionary,
		batch: Dictionary) -> Dictionary:
	var reply := await _ask_worker(panel, _pair_request(head, batch),
		PAIRS_CHANNEL)
	if reply.has("error"):
		return reply
	if (reply.get("missing_keys", []) as Array).is_empty():
		return reply
	var keys: Array = []
	for entry in (batch["targets"] as Array):
		keys.append(str((entry as Dictionary)["key"]))
	if not _upload(keys):
		return {"error": "could not write the reference geometry to "
			+ get_blob_dir() + " for the worker to read"}
	for entry in (batch["targets"] as Array):
		var target: Dictionary = entry
		target["path"] = _blob_path(str(target["key"]))
	reply = await _ask_worker(panel, _pair_request(head, batch), PAIRS_CHANNEL)
	if reply.has("error"):
		return reply
	var still: Array = reply.get("missing_keys", []) as Array
	if not still.is_empty():
		return {"error": _second_miss_reason(still)}
	return reply


func _pair_request(head: Dictionary, batch: Dictionary) -> Dictionary:
	var payload := head.duplicate()
	payload["targets"] = batch["targets"]
	payload["pairs"] = batch["pairs"]
	return payload


## Split the pairs into requests that each fit the host's channel cap, each
## carrying its own re-indexed target list. Sized on the WITH-PATH form of
## every target, which is the largest a request ever gets, so the retry above
## cannot push one past the cap.
func _batch_pairs(head: Dictionary, targets: Array, pairs: Array) -> Dictionary:
	var limit := IPC_PAYLOAD_LIMIT_BYTES - IPC_PAYLOAD_MARGIN_BYTES
	var head_size := _byte_size(_pair_request(head,
		{"targets": [], "pairs": []}))
	var batches: Array = []
	var current := {"targets": [], "pairs": []}
	var seen: Dictionary = {}
	var size := head_size
	for entry in pairs:
		var pair: Dictionary = entry
		# What this pair adds to the request it lands in: its own [i, j] entry
		# and the targets it names that are not in that request yet. A pair
		# that opens a new request pays for both of its targets.
		var both := _byte_size(_sized(targets[int(pair["a"])] as Dictionary)) \
			+ _byte_size(_sized(targets[int(pair["b"])] as Dictionary)) \
			+ PAIR_ENTRY_BYTES
		var cost := PAIR_ENTRY_BYTES
		for index in [int(pair["a"]), int(pair["b"])]:
			if not seen.has(index):
				cost += _byte_size(_sized(targets[index] as Dictionary)) + 1
		if head_size + both > limit:
			return {"error": "a single reference pair does not fit the host's "
				+ "%d byte channel limit" % IPC_PAYLOAD_LIMIT_BYTES}
		if size + cost > limit:
			batches.append(current)
			current = {"targets": [], "pairs": []}
			seen = {}
			size = head_size
			cost = both
		var local: Array = []
		for index in [int(pair["a"]), int(pair["b"])]:
			if not seen.has(index):
				seen[index] = (current["targets"] as Array).size()
				(current["targets"] as Array).append(
					(targets[index] as Dictionary).duplicate())
			local.append(int(seen[index]))
		(current["pairs"] as Array).append(local)
		size += cost
	if not (current["pairs"] as Array).is_empty():
		batches.append(current)
	return {"batches": batches}


# ---------------------------------------------------------------------------
# The reply
# ---------------------------------------------------------------------------

## Re-frame the worker's pairs: every point gains the coordinates of its own
## reference's frame beside the world ones, the declarations are applied, and
## the verdict is folded.
##
## THE VERDICT IS GRADED ON bound_mm — min_mm less the float32 quantization
## the vertices travelled at — so a gap that meets required_mm only by less
## than the grid it was written on does not pass. A pair the worker found
## CONTAINED (one closed mesh inside the other, with air between their
## surfaces) is an overlap that no declaration excuses; one whose containment
## it could not decide is neither clean nor a crash and withholds the pass. A
## declared overlap is excused by NOTHING unless its depth was measured, and
## a measured depth is a sample of the contacts, not an upper bound, so the
## exclusion it earns is advisory (certified: false) and withholds the pass
## with the reason; a region declaration is ungraded outside its box.
func _pairs_report(reply: Dictionary, records: Array, required_mm: float,
		expected: Array, overlapping_only: bool, limit: int,
		quantization: float) -> Dictionary:
	var rows: Array = []
	var matched: Dictionary = {}
	var excluded := 0
	var unproven := 0
	var undecided := 0
	var expected_rows: Array = []
	var failed := 0
	for entry in (reply.get("pairs", []) as Array):
		var raw: Dictionary = entry
		var side_a: Dictionary = raw.get("a", {})
		var side_b: Dictionary = raw.get("b", {})
		var min_mm := float(raw.get("min_mm", 0.0))
		var containment := str(raw.get("containment", ""))
		var contained := containment == "a_inside_b" or containment == "b_inside_a"
		var overlap := bool(raw.get("overlap", false)) or min_mm <= 0.0 or contained
		var bound_mm := maxf(min_mm - quantization, 0.0)
		var row := {
			"a": {"reference": str(side_a.get("reference", "")),
				"node": str(side_a.get("node", ""))},
			"b": {"reference": str(side_b.get("reference", "")),
				"node": str(side_b.get("node", ""))},
			"min_mm": min_mm,
			"bound_mm": bound_mm,
			"pass": bound_mm >= required_mm and not overlap
				and containment != "undecidable",
		}
		var points: Array = []
		if overlap:
			row["overlap"] = true
			var contacts: Array = []
			for point in (raw.get("contact_points_mm", []) as Array):
				var world := _vector(point)
				points.append(world)
				contacts.append(_framed(world, records,
					str(side_a.get("reference", ""))))
			row["contact_points_mm"] = contacts
			row["contact_count"] = int(raw.get("contact_count", contacts.size()))
			if raw.has("penetration_mm"):
				row["penetration_mm"] = float(raw["penetration_mm"])
			row["note"] = str(raw.get("note", ""))
		if not overlap or contained:
			var point_a := _vector(raw.get("point_a_mm", []))
			var point_b := _vector(raw.get("point_b_mm", []))
			points = [point_a, point_b]
			row["point_a_mm"] = _framed(point_a, records,
				str(side_a.get("reference", "")))
			row["point_b_mm"] = _framed(point_b, records,
				str(side_b.get("reference", "")))
		if not containment.is_empty():
			row["containment"] = containment
			row["containment_note"] = str(raw.get("containment_note", ""))
			if containment == "undecidable":
				row["containment_undecidable"] = true
				undecided += 1
		# A declaration on either side excuses the pair: an intended contact is
		# stated about the part that is meant to touch, and the author has no
		# reason to know which of the two the check will call `a`.
		var index: int = _Expected.index_for(expected,
			str(side_a.get("reference", "")), str(side_a.get("node", "")),
			points)
		if index < 0:
			index = _Expected.index_for(expected,
				str(side_b.get("reference", "")), str(side_b.get("node", "")),
				points)
		if index >= 0:
			var declaration: Dictionary = expected[index]
			matched[index] = true
			var allowed: float = _Expected.required_mm(declaration)
			var excused: bool = bound_mm >= allowed and not overlap \
				and containment != "undecidable"
			var certified := true
			if overlap and allowed <= 0.0 and not contained:
				# An unsigned zero cannot say how deep the overlap is. A depth
				# the worker did measure is a sample of the contacts and not
				# an upper bound, so it earns an advisory exclusion; no depth
				# at all earns none.
				excused = raw.has("penetration_mm") \
					and float(raw["penetration_mm"]) \
						<= _Expected.allowance_mm(declaration)
				certified = false
				if excused:
					row["excused_uncertified"] = true
					unproven += 1
				else:
					row["note"] = str(row.get("note", "")) + "; declared as a " \
						+ "contact, but this overlap has no measured depth, " \
						+ "so the declaration cannot excuse it"
			row["expected"] = true
			if declaration["region"] != null:
				row["declared_region"] = true
			row["pass"] = excused and certified
			var declared_row: Dictionary = _Expected.row(declaration,
				str(side_a.get("reference", "")), str(side_a.get("node", "")),
				"min_mm", min_mm, excused)
			if excused:
				excluded += 1
				if not certified:
					declared_row["certified"] = false
			expected_rows.append(declared_row)
		if not bool(row["pass"]) and not bool(row.get("excused_uncertified", false)):
			failed += 1
		if overlapping_only and not overlap:
			continue
		rows.append(row)
	var ungraded: int = _Expected.ungrade_regions(rows, expected_rows)
	unproven += ungraded
	excluded -= ungraded
	var shown: Array = rows
	if limit > 0 and rows.size() > limit:
		shown = rows.slice(0, limit)
	var report := {
		"checked": true,
		"units": "mm",
		"pass": failed == 0 and unproven == 0 and undecided == 0,
		"advisory": unproven > 0 or undecided > 0,
		"required_mm": required_mm,
		"pairs": shown,
		"pairs_measured": int(reply.get("pairs_measured",
			(reply.get("pairs", []) as Array).size())),
		"pairs_total": rows.size(),
		"pairs_shown": shown.size(),
		"pairs_hidden": rows.size() - shown.size(),
		"cache": reply.get("cache", {}),
		"engine": str(reply.get("engine", "")),
		"bound": str(reply.get("bound", "")),
		"note": "distances are exact for the two meshes and UNSIGNED: a pair "
			+ "reported as overlap may be resting against each other or one "
			+ "inside the other; containment is probed only where one node's "
			+ "box lies inside the other's, and a pair with air between its "
			+ "surfaces whose containment could not be decided withholds the "
			+ "pass. `pass` is graded over every measured pair on bound_mm, "
			+ "the distance less quantization_mm, whatever the list shows.",
	}
	if unproven > 0 or undecided > 0:
		report["pass_reason"] = ("%d declared contact(s) applied advisorily "
			+ "(an overlap depth that is a sample, or a region that excuses "
			+ "one witness point) and %d pair(s) whose containment could not "
			+ "be decided; pass is withheld rather than certified, and an "
			+ "advisory row is not a failure")\
			% [unproven, undecided]
	if not expected.is_empty():
		report["expected_contacts"] = expected_rows
		report["expected_contacts_unmatched"] = _Expected.unmatched(expected,
			matched)
		report["excluded_count"] = excluded
	return report


## A world point with the reference's own frame beside it. The local frame is
## the file's, with the mesh() pose taken back off — the numbers that go into
## the DSL.
func _framed(world: Vector3, records: Array, reference_name: String) -> Dictionary:
	var pose := _pose_in(records, reference_name)
	var local: Vector3 = pose.affine_inverse() * world
	return {"world": _vec(world), "local": _vec(local)}


func _no_pairs(reason: String) -> Dictionary:
	return {
		"checked": false,
		"units": "mm",
		"mode": "reference-vs-reference",
		"pass": false,
		"reason": reason,
		"pairs": [],
	}
