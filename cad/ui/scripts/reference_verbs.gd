extends RefCounted
## reference_verbs.gd — the MCP verbs that ask about the REFERENCES alone.
##
## Two questions the solid is not part of, split out of panel_tools.gd, which
## already carries the whole solid-against-reference surface:
##
##   part against part   how close do two mounted references come to each
##                       other, and where do they touch? Reached through
##                       minerva_cad_check_clearance / _check_interference
##                       with against= or reference="all-pairs", because it is
##                       the same question those verbs already answer — only
##                       with a reference on both sides instead of the solid.
##   the z profile       over a world-XY rectangle, how tall is the reference
##                       geometry, in total and per node?
##                       minerva_cad_reference_profile.
##
## WHY THE PROFILE IS ITS OWN VERB and not an argument on
## minerva_cad_references: that verb DESCRIBES what is mounted (paths, poses,
## boxes) and is the cheap first call every measuring session makes. This one
## MEASURES — it walks every triangle over a rectangle and answers with a
## height and the point that realises it. Every other measurement in this
## plugin (find_holes, gauge, probe, the checks) is a verb of its own for the
## same reason: a describing verb that sometimes measures cannot be described
## in one line, and an argument that changes the reply's shape is the thing
## agents get wrong.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: ui/panel_tools.gd.

const _ReferenceProfile: Script = preload("reference_profile.gd")
const _ReferencePairs: Script = preload("reference_pairs.gd")


## Is this check_clearance / check_interference call about two REFERENCES
## rather than about the solid? against= names the second one; the whole
## assembly is asked for as reference="all-pairs".
static func is_pair_call(args: Dictionary) -> bool:
	if not str(args.get("against", "")).strip_edges().is_empty():
		return true
	return str(args.get("reference", "")).strip_edges() \
		== _ReferencePairs.ALL_PAIRS


## minerva_cad_check_clearance with two references: how much air is between
## them, closest pairs first.
static func check_pairs_clearance(panel, args: Dictionary) -> Dictionary:
	return await _pairs(panel, args, false)


## minerva_cad_check_interference with two references: which node pairs have
## no air between them at all, and where they meet.
static func check_pairs_interference(panel, args: Dictionary) -> Dictionary:
	return await _pairs(panel, args, true)


static func _pairs(panel, args: Dictionary, overlapping_only: bool) -> Dictionary:
	if panel == null or not panel.has_method("check_reference_pairs"):
		return _err("reference-against-reference measurement is not available "
			+ "on this panel")
	var call_args := args.duplicate(true)
	call_args["overlapping_only"] = overlapping_only
	if overlapping_only:
		# Interference asks whether they MEET; any positive gap is clean, so
		# the pair verdict is graded against no required gap at all.
		call_args["required_mm"] = 0.0
	var report: Dictionary = await panel.check_reference_pairs(call_args)
	if report.has("error"):
		return _err(str(report["error"]))
	if overlapping_only and bool(report.get("checked", false)):
		report["overlapping_only"] = true
		report["note"] = "only the pairs with no air between them are listed; "\
			+ "minerva_cad_check_clearance on the same two references reports "\
			+ "every pair with the gap it keeps. " + str(report.get("note", ""))
	return _ok(report)


## minerva_cad_reference_profile — the tallest (and lowest) reference geometry
## over a world-XY rectangle, measured from the triangles.
##
## `args`: region_mm {min_mm: [x, y], max_mm: [x, y]} (a third coordinate is
## accepted and ignored — the region is a footprint, not a box), reference=,
## node=, per_node=.
static func reference_profile(panel, args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("get_reference_state"):
		return _err("this panel has no reference geometry to profile")
	var region: Variant = _rect(args.get("region_mm", {}))
	if region == null:
		return _err("minerva_cad_reference_profile needs region_mm: "
			+ "{min_mm: [x, y], max_mm: [x, y]} in world millimetres — the "
			+ "footprint you want the height over")
	var records: Array = panel.get_reference_state() as Array
	var scope := str(args.get("reference", "")).strip_edges()
	if not scope.is_empty() and not _mounted(records, scope):
		return _err("no reference named '%s' is mounted; mounted: %s"
			% [scope, ", ".join(PackedStringArray(_names(records)))])
	var measured: Dictionary = _ReferenceProfile.profile(records,
		region as Rect2, scope, str(args.get("node", "")),
		bool(args.get("per_node", false)))
	var reply := {
		"units": "mm",
		"region_mm": {
			"min_mm": [(region as Rect2).position.x, (region as Rect2).position.y],
			"max_mm": [(region as Rect2).end.x, (region as Rect2).end.y],
		},
		"axis": "z",
	}
	reply.merge(measured)
	if not bool(measured.get("found", false)):
		reply["note"] = "no reference triangle lies over that footprint at "\
			+ "all — nothing is under there, which is an answer and not a "\
			+ "failed measurement"
	else:
		reply["note"] = "max_z_mm is the highest point of any reference "\
			+ "triangle whose footprint meets the region, taken from the "\
			+ "triangles clipped to it and not from the node boxes: a node "\
			+ "whose tall part stands outside the region contributes only "\
			+ "the height it actually has inside it. Positions are given in "\
			+ "world and in the owning reference's own frame. Pass "\
			+ "per_node=true for the same numbers per node."
	return _ok(reply)


## {min_mm: [x, y], max_mm: [x, y]} as a Rect2 in world millimetres, or null.
## Normalised, so a caller who swapped two corners gets the rectangle they
## drew rather than an empty one. A z coordinate may be present and is
## ignored: height is what the verb answers, so bounding it would only let a
## caller cut the top off their own answer.
static func _rect(raw: Variant) -> Variant:
	if not (raw is Dictionary):
		return null
	var box: Dictionary = raw
	var low: Variant = _pair(box.get("min_mm", null))
	var high: Variant = _pair(box.get("max_mm", null))
	if low == null or high == null:
		return null
	var rect := Rect2(low as Vector2, Vector2.ZERO)
	return rect.expand(high as Vector2)


static func _pair(raw: Variant) -> Variant:
	if not (raw is Array) or (raw as Array).size() < 2:
		return null
	var values: Array = raw
	return Vector2(float(values[0]), float(values[1]))


static func _names(records: Array) -> Array:
	var out: Array = []
	for entry in records:
		out.append(str((entry as Dictionary).get("name", "")))
	return out


static func _mounted(records: Array, name: String) -> bool:
	return _names(records).has(name)


static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}
