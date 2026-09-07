extends "clearance_blobs.gd"
## clearance_report.gd — folding the worker's replies into the clearance report
## a reader gets back, and the one-line status it reads as.
##
## The worker answers in world millimetres about triangle pairs. This layer
## turns that into the report: every witness point gains the coordinates of the
## reference's OWN frame beside the world ones, because those are the numbers
## that get written back into the DSL; a declared contact is graded against the
## gap it declared rather than required_mm; the panel's latest interference
## report is joined in so a node buried in the solid's material is not passed
## on an unsigned surface-to-surface gap; and the verdict carries the reason it
## holds — including a tessellation tolerance the worker could not bound.
##
## The join is only made from a report about the same source, the same poses
## and the same colliders; anything else is stale and joins nothing, and the
## check refuses to pass on it.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: extended by scripts/clearance_client.gd.


const _MeshGauge: Script = preload("mesh_gauge.gd")
## The contacts the caller declared intended, and the rule for what a
## declaration does and does not excuse.
const _Expected: Script = preload("expected_contacts.gd")
## A part-scoped measurement joins the report for ITS OWN binding, which is
## kept here by the interference check rather than in the last eval result.
const _PartCache: Script = preload("part_cache.gd")

## The phrase every unbounded-tolerance pass_reason is built from, and the one
## the status line reads back to tell that cause from a join failure.
const UNBOUNDED_TOLERANCE_REASON := "tessellation tolerance is not guaranteed"


## Re-frame the worker's replies into one report: every reported point gains
## the coordinates of the reference's OWN frame beside the world ones, because
## those are the numbers that get written back into the DSL. `envelope` is the
## last batch's scalar fields (they are the request's own parameters, so every
## batch agrees on them); `raw_pairs` is every batch's pairs together, which
## have to be re-sorted because each batch only sorted its own.
func _clearance_report(envelope: Dictionary, raw_pairs: Array,
		records: Array, buried: Dictionary, accept_unbounded: bool,
		expected: Array = []) -> Dictionary:
	var overlapping: Dictionary = buried.get("nodes", {})
	# Where the joined interference report met these bodies, per pair key. A
	# region declaration is matched against these as well as the worker's
	# witness point; see below.
	var contacts: Dictionary = buried.get("contacts", {})
	var undecided: Dictionary = buried.get("undecided", {})
	var undecided_references: Dictionary = buried.get("undecided_references", {})
	var pairs: Array = []
	# Which declaration each pair answered to, and what was measured for it.
	var declared_rows: Array = []
	var matched: Dictionary = {}
	var excluded := 0
	# Declarations applied without a proof: an overlap held inside its
	# allowance by a chord that is not an upper bound, and a region that
	# excuses the one witness point while the rest of the pair goes ungraded.
	# Either makes the verdict advisory, never a pass.
	var unproven := 0
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
		# The declaration is matched on every point the check measured for
		# these two bodies, before anything below erases them: the worker's
		# own witness points, and the crossings the joined interference report
		# named for the same pair. A region is a place in the world, and one
		# pair carries one witness point — four regions round four bosses can
		# only all match if the crossings at all four are matched too. A pair
		# with no located point can only be declared by name.
		var located: Array = _witness_points(raw)
		located.append_array(contacts.get(
			_pair_key(pair["reference"], pair["node"]), []) as Array)
		var answered: Array = _Expected.indices_for(expected,
			str(pair["reference"]), str(pair["node"]), located)
		# GRADED against the STRICTEST of them: one pair keeps one gap, and
		# every declaration on it has to hold, so the widest gap demanded is
		# the one graded and the one row this pair gets. The others are
		# matched — they are declarations about this very pair — and the row
		# says how many there were.
		var declared: int = _Expected.strictest(expected, answered)
		var rule: Dictionary = expected[declared] if declared >= 0 else {}
		for index in answered:
			matched[index] = true
		if declared >= 0:
			pair["expected"] = true
			pair["required_mm"] = _Expected.required_mm(rule)
			pair["note"] = _Expected.describe(rule) + _several(answered.size())
			if rule["region"] != null:
				pair["declared_region"] = true
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
			if declared >= 0:
				# A declaration says these surfaces MEET. Overlap is excused
				# only up to the depth it declared, and only when that depth
				# was actually measured — a node found by ray parity alone has
				# none, and unprovable is not clean.
				var depth := float(overlapping[
					_pair_key(pair["reference"], pair["node"])])
				var allowed: float = _Expected.allowance_mm(rule)
				var holds: bool = depth > 0.0 and depth <= allowed
				# The depth is a chord along an edge, not an upper bound on
				# the overlap: a declaration it stays inside is applied
				# ADVISORILY — the row does not pass, the report says why.
				pair["pass"] = false
				pair["overlap_mm"] = depth
				var measured := "; the overlap measures %s mm" % depth
				if depth <= 0.0:
					measured = "; this overlap has no measured depth (the " \
						+ "interference check found it by ray parity, not " \
						+ "by a crossing), so the declaration cannot excuse it"
				elif holds:
					measured += ", a lower-bound chord and not a proven " \
						+ "depth, so the declaration excuses it only advisorily"
					pair["excused_uncertified"] = true
					unproven += 1
				pair["note"] = _Expected.describe(rule) + measured
				var declared_row: Dictionary = _Expected.row(rule, str(pair["reference"]),
					str(pair["node"]), "overlap", depth, holds)
				if holds:
					declared_row["certified"] = false
					excluded += 1
				declared_rows.append(declared_row)
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
		# The witness points are kept for a contact row too: they locate the touch.
		if float(pair["min_mm"]) <= 0.0 or bool(raw.get("interference", false)):
			# No air at all between the two meshes. The worker cannot say
			# whether that is a flush contact or a crossing — its distance is
			# unsigned — and the interference report, which can, named no
			# crossing here. So the row states contact and fails: calling it
			# interference sends a reader hunting for crossing points that do
			# not exist. A pair whose containment the join could not decide
			# keeps the doubt it was already given as its note.
			pair["min_mm"] = 0.0
			pair["bound_mm"] = 0.0
			# A declared contact with no gap to keep is what these two are
			# MEANT to do; the interference report named no crossing here, so
			# there is nothing beyond the touch to excuse.
			pair["pass"] = declared >= 0 \
				and float(pair["required_mm"]) <= 0.0 \
				and not bool(pair.get("containment_undecidable", false))
			pair["touching"] = true
			if declared >= 0:
				pair["note"] = _Expected.describe(rule) \
					+ "; the surfaces meet at 0 mm" + ("" if bool(pair["pass"])
						else ", and this declaration does not cover that")
				declared_rows.append(_Expected.row(rule, str(pair["reference"]),
					str(pair["node"]), "gap", 0.0, bool(pair["pass"])))
				if bool(pair["pass"]):
					excluded += 1
			if bool(pair.get("interference", false)):
				# A node the interference report found inside the solid has no
				# nearest-surface pair worth quoting: the unsigned distance's
				# witness points are wherever two surfaces happened to meet.
				pair.erase("solid_point_mm")
				pair.erase("reference_point_mm")
			if not pair.has("note"):
				pair["note"] = _contact_note(buried)
			pairs.append(pair)
			continue
		if declared >= 0:
			# Graded against the gap THIS pair declared rather than the call's.
			pair["pass"] = float(pair["bound_mm"]) >= float(pair["required_mm"]) \
				and not bool(pair.get("containment_undecidable", false))
			pair["note"] = _Expected.describe(rule) \
				+ "; the gap measures %s mm" % float(pair["min_mm"])
			declared_rows.append(_Expected.row(rule, str(pair["reference"]),
				str(pair["node"]), "gap", float(pair["min_mm"]),
				bool(pair["pass"])))
			if bool(pair["pass"]):
				excluded += 1
		if not str(raw.get("note", "")).is_empty() and not pair.has("note"):
			pair["note"] = str(raw["note"])
		pairs.append(pair)
	# A region excuses one witness point, not the pair; see _Expected.
	var ungraded: int = _Expected.ungrade_regions(pairs, declared_rows)
	unproven += ungraded
	excluded -= ungraded
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
					or bool(pair.get("touching", false)) \
					or bool(pair.get("containment_undecidable", false)):
				continue
			pair["bound_mm"] = float(pair["min_mm"])
			pair["pass"] = float(pair["min_mm"]) > 0.0 \
				and float(pair["min_mm"]) >= _required_for(pair, required)
			pair["graded_on"] = "min_mm alone (less the float32 quantization " \
				+ "of the vertices): the tolerance bar was waived by " \
				+ "accept_unbounded_tolerance"
	var verdict := true
	for entry in pairs:
		if not bool((entry as Dictionary)["pass"]):
			verdict = false
	var pass_reason := ""
	if unproven > 0:
		pass_reason = ("%d declared contact(s) could only be applied "
			+ "advisorily — an overlap held by a lower-bound chord, or a "
			+ "region that excuses one witness point while the pair is "
			+ "ungraded outside it; pass is withheld rather than certified, "
			+ "and those rows are advisory, not failures — no violation is "
			+ "established by them")\
			% unproven
	if not bounded and not accept_unbounded:
		verdict = false
		# The worker says which kind of face left the bar unproven: a spline
		# whose curvature was sampled, or a face it could not read at all.
		pass_reason = "the " + UNBOUNDED_TOLERANCE_REASON + " for " \
			+ str(envelope.get("tolerance_unbounded_because",
				"unrecognised curved faces in the solid")) \
			+ ", so the measured distances carry no error bar; pass " \
			+ "accept_unbounded_tolerance to request advisory grades on the " \
			+ "distances alone; pass remains false"
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
			if bool(pair.get("interference", false)) \
					or bool(pair.get("touching", false)):
				continue
			pair["bound_mm"] = maxf(float(pair["bound_mm"]) - quantization, 0.0)
			if bool(pair.get("pass", false)) \
					and float(pair["bound_mm"]) < _required_for(pair, required):
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
		"advisory": not bounded or unproven > 0,
		"required_mm": float(envelope.get("required_mm", 0.0)),
		"tessellation_tolerance_mm":
			float(envelope.get("tessellation_tolerance_mm", 0.0)),
		"requested_tolerance_mm": float(envelope.get("requested_tolerance_mm",
			envelope.get("tessellation_tolerance_mm", 0.0))),
		"tolerance_bounded": bounded,
		"tolerance_source": str(envelope.get("tolerance_source", "")),
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
	if not expected.is_empty():
		report["expected_contacts"] = declared_rows
		report["excluded_count"] = excluded
		report["expected_contacts_unmatched"] = _Expected.unmatched(expected,
			matched)
		report["expected_contacts_note"] = "a declared pair is graded on the "\
			+ "gap IT declared instead of required_mm, and is listed above "\
			+ "with the value measured for it; material overlap deeper than "\
			+ "the declaration allows still fails, so an exclusion cannot "\
			+ "hide a crash. An overlap inside its allowance (certified: "\
			+ "false) and a region declaration (ungraded_outside_region) are "\
			+ "applied advisorily: pass stays false with the reason"
	
	if not pass_reason.is_empty():
		report["pass_reason"] = pass_reason
	if waived:
		report["tolerance_waived"] = true
		report["waiver"] = "the tessellation tolerance is a guess here and " \
			+ "its error bar was WAIVED at the caller's request: every pair " \
			+ "is graded on min_mm against required_mm alone, with no " \
			+ "deduction for chord error"
	return report


## The note suffix for a pair several declarations name: it is graded, and
## listed, against the strictest of them.
func _several(count: int) -> String:
	if count <= 1:
		return ""
	return " (the strictest of %d declarations on this pair; the rest are " \
		% count + "matched, not listed)"


## Where in the world a worker pair was realised: the two witness points, when
## it has them. A declaration carrying a region is matched against these, so a
## region drawn round the bosses does not excuse a contact at the far end of
## the same node.
func _witness_points(raw: Dictionary) -> Array:
	var out: Array = []
	if raw.has("solid_point_mm"):
		out.append(_vector(raw["solid_point_mm"]))
	if raw.has("reference_point_mm"):
		out.append(_vector(raw["reference_point_mm"]))
	return out


## The world crossing points an interference pair carries. They are the second
## source of "where this pair was measured": a clearance pair has one witness
## point and an overlapping pair has as many crossings as the walk found, and a
## region declaration is matched against all of them.
func _crossing_points(pair: Dictionary) -> Array:
	var out: Array = []
	for entry in (pair.get("points_mm", []) as Array):
		var world: Variant = (entry as Dictionary).get("world", null)
		if world is Array and (world as Array).size() >= 3:
			var values: Array = world
			out.append(Vector3(float(values[0]), float(values[1]),
				float(values[2])))
	return out


## The gap this pair is graded against: the one it declared, or the call's.
func _required_for(pair: Dictionary, fallback: float) -> float:
	return float(pair["required_mm"]) if pair.has("required_mm") else fallback


## The (reference, node) pairs the panel's latest interference report names as
## crossing the solid or lying inside it, keyed the way a clearance pair is.
##
## The interference check runs on every evaluation and rides in the panel's
## last eval result, so the answer is already there; asking again would rebuild
## the solid's collider for a question that has been answered.
##
## Returns {fresh, stale?, reason?, nodes: {key: penetration_mm}, undecided:
## {key: reason}, undecided_references: {reference: reason}}. The depth travels
## because a declared contact is excused only up to the overlap it declared,
## and the unsigned distance has no depth of its own to compare; 0 means the
## report found the pair but bounded no run inside it.
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
	var out := {"fresh": false, "nodes": {}, "contacts": {}, "undecided": {},
		"undecided_references": {}}
	var digest := _source_digest(source)
	# A PART is measured against its own report, never the document's: the
	# document's solid is the union of every binding, so a node buried in
	# another half would be joined onto this one. The store is keyed by the
	# digest of the source that produced the report, so a hit is by
	# construction about the same shape this measurement is about.
	var interference: Dictionary = _PartCache.interference(panel, digest)
	if interference.is_empty():
		var last_eval: Variant = document.get("last_eval", {})
		if not (last_eval is Dictionary):
			return out
		var report: Variant = (last_eval as Dictionary).get("interference", {})
		if not (report is Dictionary):
			return out
		interference = report
	if not bool(interference.get("checked", false)):
		return out
	if str(interference.get("source_digest", "")) != digest:
		return out
	# A WALK THAT RAN OUT OF RAYS NAMES ONLY SOME OF WHAT CROSSES. The join
	# reads a pair the report does not name as "nothing crossing there", so a
	# truncated report certifies exactly the pairs it never looked at — and a
	# part-scoped check, whose report is the only one it has, would pass on
	# them. Its counts are floors and it is treated as stale: the rows keep
	# their unsigned distances and the check cannot pass on any of them.
	if str(interference.get("sampling", "")).begins_with("TRUNCATED"):
		out["stale"] = true
		out["reason"] = ("the interference report for this source spent its "
			+ "ray budget before the walk finished, so the pairs it does NOT "
			+ "name are unexamined rather than clear; a mesh-to-mesh distance "
			+ "is unsigned and cannot tell them apart, so this check cannot "
			+ "pass — narrow the check with reference= or node= and ask again")
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
	var contacts: Dictionary = out["contacts"]
	for entry in (interference.get("pairs", []) as Array):
		var pair: Dictionary = entry
		var key := _pair_key(str(pair.get("reference", "")),
			str(pair.get("node", "")))
		nodes[key] = float(pair.get("penetration_mm", 0.0))
		contacts[key] = _crossing_points(pair)
	# A contact the declarations excused is not among the pairs — it is under
	# expected_contacts with what was measured for it — and it is exactly the
	# place a region was drawn round, so its crossings are carried too.
	for entry in (interference.get("expected_contacts", []) as Array):
		var row: Dictionary = entry
		var key := _pair_key(str(row.get("reference", "")),
			str(row.get("node", "")))
		var points: Array = _crossing_points(row)
		if contacts.has(key):
			(contacts[key] as Array).append_array(points)
		else:
			contacts[key] = points
	# And neither is a pair the rim rule PROVED to be touching rather than
	# crossing. It is not interference, so it names no depth here; but it is a
	# place the two bodies were measured to meet, and a region drawn round a
	# seat has to keep matching it or the declaration goes stale the moment
	# the seat is graded correctly.
	for entry in (interference.get("contacts", []) as Array):
		var row: Dictionary = entry
		var key := _pair_key(str(row.get("reference", "")),
			str(row.get("node", "")))
		var points: Array = _crossing_points(row)
		if contacts.has(key):
			(contacts[key] as Array).append_array(points)
		else:
			contacts[key] = points
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


## Why a pair measured 0. The distance says only that there is no air here;
## which of the two cases it is — flush surfaces, or one body inside the other
## — is the interference report's answer, and this note says whether that
## report was there to give it.
func _contact_note(buried: Dictionary) -> String:
	if bool(buried.get("fresh", false)) and not bool(buried.get("stale", false)):
		return "the surfaces are flush: the meshes meet at 0 mm and the " \
			+ "interference report for this source names no crossing here, " \
			+ "so this is contact and not overlap; any required gap above " \
			+ "zero is unmet"
	return "the meshes meet at 0 mm, and with no fresh interference report " \
		+ "for this source whether that is a flush contact or a crossing is " \
		+ "unknown: an unsigned distance cannot tell them apart"


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
			+ "overlap, so every distance below is a surface-to-surface gap " \
			+ "and a 0 among them is a flush contact, not a crossing" + doubt
	return ("%d node(s) the latest interference report for this source found "
		% count + "overlapping the solid are reported at 0 rather than at "
		+ "their unsigned surface-to-surface distance") + doubt


## SHA-256 of the DSL source, hex. Carried on the interference report so a
## clearance check can tell whether that report describes the solid it is
## about to measure against.
func _source_digest(source: String) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	# update() refuses an empty buffer with an engine error; finish() alone
	# still gives the digest of the empty string, which is what a document
	# with no source is.
	var bytes := source.to_utf8_buffer()
	if not bytes.is_empty():
		hasher.update(bytes)
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
