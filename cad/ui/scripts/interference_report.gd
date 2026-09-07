extends "reference_pairs.gd"
## interference_report.gd — turning a walk's crossings into the answer.

## The ray walk in geometry_checks.gd produces crossings: a point, a node, a
## distance along the edge it was found on. Everything between that and the
## reply the panel and the MCP verbs read — folding crossings into pairs,
## measuring how deep each run went, deciding whether a declared contact still
## holds, and the one status line the banner shows — is here. It was split out
## of geometry_checks.gd when that file crossed two thousand lines; nothing
## about the check changed, and one object still carries both halves because
## this script is the walk's base class, exactly as clearance_client.gd and
## reference_pairs.gd are.
##
## The state below lives here rather than with the walk because both halves
## write it: the walk fills the counters and the declaration buckets, and the
## report reads them. A running check owns all of it — the module answers one
## check at a time, which the reservation in geometry_checks.gd enforces.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: geometry_checks.gd extends this script.

## Markers drawn at most. A shell buried in a board can produce thousands of
## crossings and drawing them all says nothing more than drawing two hundred.
const MAX_MARKERS: int = 200

## Points listed per interfering pair. The pair's own point_count is the whole
## number; this bounds what travels in the reply.
const MAX_POINTS_PER_PAIR: int = 8

## The reference records the running check was started with: name, pose and
## converted parts. Snapshotted before the job is submitted, because the
## document may change while the job waits for a physics step.
var _records: Array = []
## Points the last check found, world millimetres, for the markers.
var _marker_points: PackedVector3Array = PackedVector3Array()
## Ray casts spent by the running check — reported, because the cost of this
## check is the one thing a per-evaluation feature has to be honest about.
var _casts: int = 0
## Ceilings the running check hit, in prose.
var _limits: PackedStringArray = PackedStringArray()
## The solid's edges as the running check treated them: how many it holds,
## how many of those could reach a reference at all, and how many of THOSE it
## actually cast a ray from. The three are what the report says it did.
var _edges_total: int = 0
var _edges_reaching: int = 0
var _edges_cast: int = 0
## Nodes whose containment question could not be answered, as
## {reference, node, reason}. A rejected probe is not a clean node.
var _undecided: Array = []
## The declarations the running check was called with, parsed. Empty is the
## default and is every check that came before the argument existed.
var _expected: Array = []
## Crossings the running check folded into a DECLARATION instead of into an
## interference pair, keyed pair-key + declaration index. A bucket carries the
## same fields a pair does, so it can be promoted back into the report whole
## when its measured overlap runs past what was declared.
var _declared: Dictionary = {}
## Declaration indices something was measured against, so the reply can name
## the ones that matched nothing.
var _declared_matched: Dictionary = {}
## Wall clock of the running check, microseconds.
var _started_us: int = 0


## The reference records this check runs against — {name, pose, parts} as the
## panel reports them. Snapshotted before the job is submitted, because the
## document may change while the job waits for a physics step.
func set_records(records: Array) -> void:
	_records = records

func _pose_for(reference_name: String) -> Transform3D:
	return _pose_in(_records, reference_name)


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

## Fold one crossing into its (reference, node) pair. `node_scope` drops
## crossings on other nodes; the pair carries the points in the order they were
## found.
func _absorb(pairs: Dictionary, crossing: Dictionary, node_scope: String) -> void:
	var node_path := str(crossing.get("node", ""))
	if not _node_matches(node_path, node_scope):
		return
	var reference_name := str(crossing.get("reference", ""))
	var point: Vector3 = crossing.get("point", Vector3.ZERO)
	# A crossing a declaration covers goes into that declaration's bucket
	# rather than into the interference pair. It is measured exactly as it
	# would have been — the bucket carries the same fields — and the depth it
	# reaches decides, in _report, whether the declaration holds.
	var declared := _declared_index(reference_name, node_path, point)
	var pair: Dictionary = _declared_pair(declared, reference_name, node_path) \
		if declared >= 0 \
		else _pair_for(pairs, reference_name, node_path)
	pair["point_count"] = int(pair["point_count"]) + 1
	var points: Array = pair["points"]
	if points.size() < MAX_POINTS_PER_PAIR:
		points.append(point)
	# A declared contact is not painted red: its crosses are what the design
	# means to happen. A bucket promoted back into the report in _report takes
	# its markers with it.
	if declared < 0 and _marker_points.size() < MAX_MARKERS:
		_marker_points.append(point)
	if crossing.has("containment"):
		pair["note"] = str(crossing["containment"])


## Which declaration covers a crossing at `point`, or -1 when none does.
func _declared_index(reference_name: String, node_path: String,
		point: Vector3) -> int:
	if _expected.is_empty():
		return -1
	var index: int = _Expected.index_for(_expected, reference_name, node_path,
		[point])
	if index >= 0:
		_declared_matched[index] = true
	return index


## One bucket per (pair, declaration): a node can carry an intended contact
## inside a declared region and an unintended one outside it, and folding both
## under the node would lose exactly the distinction the region was drawn for.
func _declared_pair(index: int, reference_name: String,
		node_path: String) -> Dictionary:
	var key := "%d\n%s" % [index, _pair_key(reference_name, node_path)]
	if not _declared.has(key):
		_declared[key] = {
			"reference": reference_name,
			"node": node_path,
			"entry": _expected[index],
			"points": [],
			"point_count": 0,
			"penetration_mm": 0.0,
			"run_max": {},
			"note": "",
		}
	return _declared[key]


## How deep ONE edge went inside each node it crossed. The crossings of a given
## node along one edge alternate in and out, so consecutive pairs of them bound
## a run inside that node and the longest run of that walk is kept.
##
## THE TWO WALKS ARE KEPT APART, and the depth is the SHALLOWER of them. A run
## is a chord through the overlap along whatever direction that edge happened
## to point, and the two walks point across each other: a peg through a plate
## gives runs of the plate's thickness along the peg's own edges and runs of
## the peg's DIAMETER along the plate's, and the diameter says how wide the peg
## is, not how far it went in. Taking the larger of the two would report a
## 1.6 mm overlap as 3.5 mm deep and fail every declaration drawn for it.
##
## An odd number of crossings means an endpoint of the edge is buried, and
## bounds no run at all — that case is still interference, just without a
## depth. `walk` names which body's edges these crossings were found on.
func _absorb_runs(pairs: Dictionary, crossings: Array, node_scope: String,
		walk: String) -> void:
	var by_node := {}
	for entry in crossings:
		var crossing: Dictionary = entry
		var node_path := str(crossing.get("node", ""))
		if not _node_matches(node_path, node_scope):
			continue
		var reference_name := str(crossing.get("reference", ""))
		# The declared crossings are grouped apart from the rest, so a
		# declaration's depth is measured over the runs it actually covers.
		var declared := _declared_index(reference_name, node_path,
			crossing.get("point", Vector3.ZERO))
		var key := _pair_key(reference_name, node_path)
		if declared >= 0:
			key = "%d\n%s" % [declared, key]
		if not by_node.has(key):
			by_node[key] = []
		(by_node[key] as Array).append(float(crossing.get("distance", 0.0)))
	for key in by_node.keys():
		var distances: Array = by_node[key]
		var table: Dictionary = _declared if _declared.has(key) else pairs
		if distances.size() < 2 or not table.has(key):
			continue
		var pair: Dictionary = table[key]
		var runs: Dictionary = pair["run_max"]
		var index := 0
		while index + 1 < distances.size():
			runs[walk] = maxf(float(runs.get(walk, 0.0)),
				float(distances[index + 1]) - float(distances[index]))
			index += 2
		pair["penetration_mm"] = _depth_from(runs)


## The overlap depth the runs bound: the shallower of the two walks when both
## measured one, and the only one measured otherwise. Zero means no run was
## bounded at all.
func _depth_from(runs: Dictionary) -> float:
	var depth := 0.0
	for key in runs.keys():
		var run := float(runs[key])
		if run <= 0.0:
			continue
		depth = run if depth <= 0.0 else minf(depth, run)
	return depth


func _pair_for(pairs: Dictionary, reference_name: String, node_path: String) -> Dictionary:
	var key := _pair_key(reference_name, node_path)
	if not pairs.has(key):
		pairs[key] = {
			"reference": reference_name,
			"node": node_path,
			"points": [],
			"point_count": 0,
			"penetration_mm": 0.0,
			"run_max": {},
			"note": "",
		}
	return pairs[key]


func _report(pairs: Dictionary) -> Dictionary:
	var out: Array = []
	var total := 0
	for key in pairs.keys():
		var entry := _pair_row(pairs[key])
		total += int(entry["point_count"])
		out.append(entry)
	# What the declarations excused, and what they did not. A bucket whose
	# measured overlap runs past the depth that was declared is put back among
	# the pairs, so an exclusion can never be the reason a crash went unsaid.
	var declared_rows: Array = []
	var excluded := 0
	for key in _declared.keys():
		var bucket: Dictionary = _declared[key]
		var entry: Dictionary = bucket["entry"]
		var depth := float(bucket["penetration_mm"])
		var allowed: float = _Expected.allowance_mm(entry)
		# Depth is the only evidence a declaration can be checked against, and
		# a pair found by parity alone has none: unprovable is not clean.
		var holds: bool = depth > 0.0 and depth <= allowed
		declared_rows.append(_Expected.row(entry, str(bucket["reference"]),
			str(bucket["node"]), "overlap", depth, holds))
		if holds:
			excluded += 1
			continue
		var row := _pair_row(bucket)
		row["declared_intended"] = true
		var found := str(row.get("note", ""))
		row["note"] = (found + "; " if not found.is_empty() else "") \
			+ ("declared an intended contact, but %s: the "
			+ "declaration allows %s mm of overlap") % [
				("the overlap here measures %s mm" % depth) if depth > 0.0
					else "this overlap has no measured depth to check it "
						+ "against (it was found by ray parity, not by a "
						+ "crossing)", allowed]
		# Its crossings were held back from the pane while the declaration
		# stood; the pair is interference after all, so they are painted.
		for point in (bucket["points"] as Array):
			if _marker_points.size() < MAX_MARKERS:
				_marker_points.append(point as Vector3)
		total += int(row["point_count"])
		out.append(row)
	var sampling := ("none: every one of the %d solid edges that reach a "
		+ "reference was cast (of %d the solid has; the rest stand clear of "
		+ "everything in scope, where no ray could cross anything), as was "
		+ "every edge of every reference triangle overlapping the solid") \
		% [_edges_cast, _edges_total]
	if not _limits.is_empty():
		sampling = "TRUNCATED — %s; the counts are floors" % ", ".join(_limits)
	var report := {
		"checked": true,
		"units": "mm",
		# GRADED OVER THE PAIRS THAT REMAIN. A declaration whose overlap it
		# excused is out of this count and listed under expected_contacts with
		# what was measured for it; one it could not excuse is back in.
		"pass": out.is_empty() and _undecided.is_empty(),
		"count": out.size(),
		"point_count": total,
		"pairs": out,
		# A node here was NOT cleared: its containment could not be decided.
		# Reporting it beside the pairs is what keeps "no interference" an
		# answer about geometry rather than about the probes that failed.
		"undecidable": _undecided,
		"undecidable_note": ("containment is decided from a probe verified "
			+ "inside its own body; a node listed here offered none, so it is "
			+ "neither clean nor reported as interfering"),
		"sampling": sampling,
		# What the walk actually covered: every edge the solid has, the ones
		# whose box reaches a reference, and the ones a ray was cast from.
		"solid_edges": _edges_total,
		"edges_reaching": _edges_reaching,
		"edges_cast": _edges_cast,
		"casts": _casts,
		"elapsed_ms": float(Time.get_ticks_usec() - _started_us) / 1000.0,
		# The cost of a per-evaluation check is part of its answer: a reader
		# deciding whether to keep it on can only do that with the bound.
		"cost": "one ray per solid edge whose box reaches a reference, three "
			+ "per overlapping reference triangle, a probe of the runs either "
			+ "side of each crossing that survived, and two or three parity "
			+ "rays when nothing crossed; everything else is an AABB test",
	}
	if not _expected.is_empty():
		report["expected_contacts"] = declared_rows
		report["excluded_count"] = excluded
		report["expected_contacts_unmatched"] = _Expected.unmatched(_expected,
			_declared_matched)
		report["expected_contacts_note"] = "a declared contact is excluded "\
			+ "from `count` only while its MEASURED overlap stays inside the "\
			+ "depth it declared; every declaration is listed above with the "\
			+ "overlap measured for it, and one that ran deeper is back among "\
			+ "the pairs carrying declared_intended"
	return report


## One reported pair: its crossing points in both frames, how many there were,
## and how deep the deepest run went. Shared with the declaration buckets,
## which are the same shape and are reported the same way when a declaration
## turns out not to cover them.
func _pair_row(pair: Dictionary) -> Dictionary:
	var pose := _pose_for(str(pair["reference"]))
	var points: Array = []
	for point in (pair["points"] as Array):
		points.append({
			"world": _vec(point),
			"local": _vec(pose.affine_inverse() * point),
		})
	var entry := {
		"reference": pair["reference"],
		"node": pair["node"],
		"points_mm": points,
		"point_count": int(pair["point_count"]),
	}
	if float(pair["penetration_mm"]) > 0.0:
		entry["penetration_mm"] = float(pair["penetration_mm"])
		entry["penetration_note"] = "the shorter of the two bodies' " \
			+ "longest chords through the other; a lower bound on the " \
			+ "overlap, not a separation depth"
	if not str(pair["note"]).is_empty():
		entry["note"] = str(pair["note"])
	return entry


## A report for a question that could not be asked. `checked` false with a
## reason is not the same answer as "no interference", and a reader that
## cannot tell them apart will trust a check that never ran.
func _nothing(reason: String) -> Dictionary:
	return {
		"checked": false,
		"units": "mm",
		# A check that never ran passes nothing.
		"pass": false,
		"count": 0,
		"point_count": 0,
		"pairs": [],
		"undecidable": [],
		"reason": reason,
		"casts": 0,
		"elapsed_ms": 0.0,
	}


## One line for the panel's status banner, or "" when there is nothing to say.
## It names the FIRST offender rather than summarising: an enclosure is fixed
## one collision at a time. A node whose containment could not be decided is
## named too, WHETHER OR NOT anything else was found: an evaluation that
## reports a pin and stays silent about the washer beside it reads on screen
## as "the washer is fine", which is the one thing it does not know.
func status_line(report: Dictionary) -> String:
	var undecided: Array = report.get("undecidable", []) as Array
	var pairs: Array = report.get("pairs", []) as Array
	if int(report.get("count", 0)) <= 0 or pairs.is_empty():
		if not undecided.is_empty():
			var one: Dictionary = undecided[0]
			return "Interference: undecided for %s%s — %s." % [
				_undecided_name(one),
				_undecided_others(undecided),
				str(one.get("reason", "")),
			]
		return ""
	var first: Dictionary = pairs[0]
	var where := ""
	var points: Array = first.get("points_mm", []) as Array
	if not points.is_empty():
		var world: Array = (points[0] as Dictionary).get("world", []) as Array
		if world.size() >= 3:
			where = " at (%.2f, %.2f, %.2f) mm" % [
				float(world[0]), float(world[1]), float(world[2])]
	var suffix := ""
	if int(report.get("count", 0)) > 1:
		suffix = " (and %d other node(s))" % (int(report.get("count", 0)) - 1)
	var open_tail := ""
	if not undecided.is_empty():
		open_tail = " %s%s undecided." % [
			_undecided_name(undecided[0]), _undecided_others(undecided)]
	return "Interference: the solid runs into %s/%s%s — %d point(s)%s.%s" % [
		str(first.get("reference", "")),
		str(first.get("node", "")),
		where,
		int(report.get("point_count", 0)),
		suffix,
		open_tail,
	]


## What to call an undecided entry on the banner: its node, or the reference
## when the record carried no node path.
func _undecided_name(one: Dictionary) -> String:
	var name := str(one.get("node", ""))
	return name if not name.is_empty() \
		else str(one.get("reference", "the reference"))


func _undecided_others(undecided: Array) -> String:
	return " (and %d other)" % (undecided.size() - 1) \
		if undecided.size() > 1 else ""
