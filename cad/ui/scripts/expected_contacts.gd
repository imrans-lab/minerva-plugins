extends RefCounted
## What the design MEANS to touch.
##
## An assembled enclosure is full of contacts that are the design working: the
## keycap presses the switch, the battery holder rests on the door, the collar
## locates the speaker. A check that grades those as failures has no reachable
## pass on any real assembly, and a reader learns to skim it — at which point
## the one row that is a crash reads exactly like the four that are not.
##
## So a check can be TOLD what is intended, per pair:
##
##     expected_contacts: [{reference, node?, region_mm?, required_mm?, why?}]
##
## and the top-level pass grades the rest.
##
## NAMING A NODE IS NOT ENOUGH ON ITS OWN. A board node carries both the bosses
## it is meant to rest on and the traces nothing may touch, so a declaration
## may carry `region_mm` — {min_mm, max_mm}, a box in world millimetres the
## measured contact has to lie in. A contact on the same node that falls
## outside that box matches nothing and is graded as if nothing had been
## declared, which is the whole point of the argument being per pair rather
## than per node.
##
## AN EXCLUSION CANNOT HIDE A CRASH. A declaration says these surfaces MEET; it
## does not say "ignore this pair". `required_mm` is the gap the declared pair
## must keep instead of the call's own required_mm — 0, the default, means they
## may touch — and a NEGATIVE required_mm declares an intended interference fit
## of that depth. Overlap deeper than what was declared is reported and fails
## the check, and every excluded pair is listed in the reply with the value
## that was measured for it, so an exclusion is always auditable against the
## number it excused.
##
## AN OVERLAP WITH NO MEASURED DEPTH IS NEVER EXCUSED. The interference check
## bounds a penetration from the runs of an edge inside the other body; a pair
## it found by ray parity alone (one body wholly inside the other) has no depth
## to compare with an allowance, and unprovable is not clean.
##
## AN EXCLUSION IS CERTIFIED ONLY WHEN THE EVIDENCE IS. The measured overlap
## is a chord along an edge, not an upper bound on the depth, so a declaration
## an overlap stays inside is applied advisorily (certified: false); and a
## region matched by a pair's one witness point says nothing about the same
## pair outside the box (ungraded_outside_region). Both withhold the top-level
## pass with a reason rather than certify it.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: scripts/geometry_checks.gd (interference), scripts/
## clearance_report.gd (clearance), ui/panel_tools.gd (the two verbs).

## Overlap excused by a bare declaration, in millimetres. A designed flush fit
## measured through a tessellated mesh reads a few thousandths of a millimetre
## into the other body; a part in the wrong place is out by tenths. The line
## between them is a hundredth, and an author who wants a real interference fit
## states it as a negative required_mm rather than living on this default.
const CONTACT_TOLERANCE_MM: float = 0.01


## Read the `expected_contacts` argument.
##
## Returns {entries: [...], errors: [...]}. A malformed declaration is an
## ERROR and not a silently dropped row: an author who mistypes a reference
## believes a pair is excused, and a check that says nothing lets them believe
## it. The caller refuses the whole call when `errors` is non-empty.
static func parse(args: Dictionary) -> Dictionary:
	var raw: Variant = args.get("expected_contacts", [])
	var entries: Array = []
	var errors: Array = []
	if raw == null:
		return {"entries": entries, "errors": errors}
	if not (raw is Array):
		errors.append("expected_contacts must be a list of {reference, node?, "
			+ "region_mm?, required_mm?, why?}")
		return {"entries": entries, "errors": errors}
	for item in (raw as Array):
		if not (item is Dictionary):
			errors.append("each expected contact is a dictionary: "
				+ "{reference, node?, region_mm?, required_mm?, why?}")
			continue
		var one: Dictionary = item
		var reference := str(one.get("reference", "")).strip_edges()
		if reference.is_empty():
			errors.append("an expected contact must name the `reference` it "
				+ "is about; `node` and `region_mm` narrow it from there")
			continue
		var entry := {
			"reference": reference,
			"node": str(one.get("node", "")).strip_edges(),
			"required_mm": float(one.get("required_mm", 0.0)),
			"why": str(one.get("why", "")).strip_edges(),
			"region": null,
		}
		if one.has("region_mm"):
			var box: Variant = _box(one["region_mm"])
			if box == null:
				errors.append(("region_mm for '%s' must be "
					+ "{min_mm: [x, y, z], max_mm: [x, y, z]} in world "
					+ "millimetres") % reference)
				continue
			entry["region"] = box
		entries.append(entry)
	return {"entries": entries, "errors": errors}


## EVERY declaration this measurement answers to, in declaration order.
##
## `points` are the world points the measurement was located at — the witness
## points of a clearance pair, the crossing points of an interference pair, and
## for a clearance pair the crossings the interference report named for the
## same two bodies. A declaration carrying a region matches when ANY of them
## lies in its box, so four regions drawn one per boss all match the node whose
## contacts were measured at all four; a measurement with no located point (a
## node the interference check found by parity, which meets no surface
## anywhere in particular) can only be declared by name.
##
## MATCHING IS NOT GRADING. Every index returned is a declaration nothing has
## gone stale about, which is what `unmatched` reports on; the caller grades
## the pair against the STRICTEST of them (see `strictest`), because one pair
## carries one gap and every declaration on it has to hold.
static func indices_for(entries: Array, reference: String, node: String,
		points: Array) -> Array:
	var out: Array = []
	for index in range(entries.size()):
		var entry: Dictionary = entries[index]
		if str(entry["reference"]) != reference:
			continue
		if not _node_matches(node, str(entry["node"])):
			continue
		var region: Variant = entry["region"]
		if region == null:
			out.append(index)
			continue
		for point in points:
			if (region as AABB).has_point(point as Vector3):
				out.append(index)
				break
	return out


## The declaration a measurement is GRADED against, or -1: the strictest of
## the ones it answers to.
static func index_for(entries: Array, reference: String, node: String,
		points: Array) -> int:
	return strictest(entries, indices_for(entries, reference, node, points))


## Of several declarations one pair answers to, the one it is graded against:
## the greatest raw required_mm — the widest gap demanded, or among fits the
## shallowest overlap allowed — first on ties. Two declarations on one pair
## are two requirements, and a pair that fails either fails; grading the
## first and marking the rest matched let the stricter one vanish. -1 when
## `indices` is empty.
static func strictest(entries: Array, indices: Array) -> int:
	var found := -1
	var demanded := -INF
	for index in indices:
		var required := float((entries[int(index)] as Dictionary)["required_mm"])
		if required > demanded:
			demanded = required
			found = int(index)
	return found


## The gap a declared pair must keep. A declaration of contact (0, the
## default) or of an interference fit (negative) asks for no gap at all.
static func required_mm(entry: Dictionary) -> float:
	return maxf(float(entry["required_mm"]), 0.0)


## The overlap a declared pair may have before it is reported as interference
## anyway.
static func allowance_mm(entry: Dictionary) -> float:
	return maxf(-float(entry["required_mm"]), CONTACT_TOLERANCE_MM)


## One line saying what was declared, for the row that records the exclusion.
static func describe(entry: Dictionary) -> String:
	var text := "declared intended: "
	var declared := float(entry["required_mm"])
	if declared > 0.0:
		text += "this pair is graded against its own %s mm" % declared
	elif declared < 0.0:
		text += ("an interference fit up to %s mm deep") % (-declared)
	else:
		text += ("the surfaces may touch; overlap deeper than %s mm is "
			+ "reported anyway") % CONTACT_TOLERANCE_MM
	if not str(entry["why"]).is_empty():
		text += " — %s" % str(entry["why"])
	return text


## The reply row for a declaration that matched something: what was declared,
## what was measured, and whether the declaration held.
static func row(entry: Dictionary, reference: String, node: String,
		measured: String, measured_mm: float, excluded: bool) -> Dictionary:
	var out := {
		"reference": reference,
		"node": node,
		"declared_required_mm": float(entry["required_mm"]),
		"measured": measured,
		"measured_mm": measured_mm,
		"excluded": excluded,
		"note": describe(entry),
	}
	if entry["region"] != null:
		var region: AABB = entry["region"]
		out["region_mm"] = {
			"min_mm": [region.position.x, region.position.y, region.position.z],
			"max_mm": [region.end.x, region.end.y, region.end.z],
		}
	return out


## A REGION EXCUSES ONE WITNESS POINT, NOT THE PAIR. A distance measurement
## matches a region because the pair's closest point lies in the box; how
## close the same two bodies come OUTSIDE the box was not measured
## separately, so a pair a region excused is UNGRADED there: its pass is
## withdrawn, the row and its declaration say so, and the caller reports the
## verdict advisory. Returns how many pairs were ungraded. Interference is
## not affected: every crossing point is matched to a region on its own.
static func ungrade_regions(pairs: Array, declared_rows: Array) -> int:
	var ungraded := 0
	for entry in pairs:
		var pair: Dictionary = entry
		if not bool(pair.get("pass", false)) \
				or not bool(pair.get("declared_region", false)):
			continue
		pair["pass"] = false
		pair["ungraded_outside_region"] = true
		pair["note"] = str(pair.get("note", "")) + "; the region excuses the " \
			+ "witness point inside it, and clearance outside the region was " \
			+ "not measured separately, so this pair is ungraded there"
		ungraded += 1
		for row in declared_rows:
			var declared_row: Dictionary = row
			if declared_row.has("region_mm") \
					and bool(declared_row.get("excluded", false)) \
					and str(declared_row.get("node", "")) == str(pair.get("node", "")) \
					and str(declared_row.get("reference", "")) \
						== str(pair.get("reference", "")):
				declared_row["excluded"] = false
				declared_row["ungraded_outside_region"] = true
				break
	return ungraded


## The declarations nothing was measured against, so a stale exclusion — a
## contact that has since moved away, or a mistyped node — shows up in the
## reply rather than quietly grading nothing.
static func unmatched(entries: Array, matched: Dictionary) -> Array:
	var out: Array = []
	for index in range(entries.size()):
		if matched.has(index):
			continue
		var entry: Dictionary = entries[index]
		out.append({
			"reference": str(entry["reference"]),
			"node": str(entry["node"]),
			"declared_required_mm": float(entry["required_mm"]),
			"note": "no measured contact matched this declaration",
		})
	return out


## Does this node path answer to the filter? Same rule as every other node=
## argument: the path from the file root, or a bare leaf name.
static func _node_matches(node_path: String, filter: String) -> bool:
	if filter.is_empty():
		return true
	return node_path == filter or node_path.get_file() == filter


## {min_mm: [x, y, z], max_mm: [x, y, z]} as an AABB, or null. The box is
## normalised, so a caller that swapped a pair of corners still gets the box
## they drew rather than an empty one.
static func _box(raw: Variant) -> Variant:
	if not (raw is Dictionary):
		return null
	var region: Dictionary = raw
	var low: Variant = _triple(region.get("min_mm", null))
	var high: Variant = _triple(region.get("max_mm", null))
	if low == null or high == null:
		return null
	return AABB(low as Vector3, (high as Vector3) - (low as Vector3)).abs()


static func _triple(raw: Variant) -> Variant:
	if raw is Vector3:
		return raw
	if not (raw is Array) or (raw as Array).size() != 3:
		return null
	var values: Array = raw
	return Vector3(float(values[0]), float(values[1]), float(values[2]))
