extends RefCounted
## How a measurement reply is SHAPED before it goes on the MCP wire.
##
## Every number these helpers keep is measured somewhere else; nothing here
## computes geometry. What they do is decide how much of an answer travels,
## and that is a real constraint: a reference listing for a forty-five node
## board is sixteen kilobytes, a fifty-pair clearance report twenty, and an
## agent sizing one part reads those replies five times over. The rule the
## whole file follows: leanness is a DEFAULT or a FILTER, never a loss — every
## field dropped here is either derivable from what stays or is one named call
## away, and the reply says which.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: panel_tools.gd (the verb layer) and fastener_checks.gd.

## Axis directions a hole can be emitted as DSL along, and the rotate() that
## puts a +Z cylinder on each. A cylinder centred on its axis is the same
## solid either way along that axis, so only the LINE has to match.
const _DSL_AXES: Array = [
	{"axis": Vector3(0.0, 0.0, 1.0), "rotate": ""},
	{"axis": Vector3(1.0, 0.0, 0.0), "rotate": "rotate([0, 90, 0], %s)"},
	{"axis": Vector3(0.0, 1.0, 0.0), "rotate": "rotate([90, 0, 0], %s)"},
]
## How square to a world axis a hole's axis has to be before its DSL can be
## written with a right-angle rotate(). About a quarter of a degree.
const _DSL_AXIS_DOT: float = 0.99999


# ---------------------------------------------------------------------------
# References
# ---------------------------------------------------------------------------

## One reference row, lean: what it is, whether it loaded, and where it is in
## the world. The pose matrix, the per-node boxes and the load statistics are
## what makes the full row large, and every one of them comes back from the
## same verb with detail="full".
static func lean_reference(row: Dictionary) -> Dictionary:
	var boxes: Dictionary = row.get("bbox_mm", {})
	var lean := {
		"name": str(row.get("name", "")),
		"status": str(row.get("status", "")),
		"bbox_mm": {"world": boxes.get("world", {})},
		"node_count": (row.get("nodes", []) as Array).size(),
	}
	# A reference that did not load is the one case where the reason IS the
	# answer, so it travels in both detail levels.
	if not str(row.get("reason", "")).is_empty():
		lean["reason"] = str(row["reason"])
	if not str(row.get("warning", "")).is_empty():
		lean["warning"] = str(row["warning"])
	return lean


# ---------------------------------------------------------------------------
# Clearance pairs
# ---------------------------------------------------------------------------

## Narrow a clearance report's pair list without changing its verdict.
##
## `pairs` arrive sorted by min_mm ascending, so `limit` keeps the CLOSEST n —
## the tightest gaps, which are the ones an edit is about. `failing_only`
## drops the pairs that cleared. The report's own `pass` is graded over every
## pair before this runs and is not touched: a filtered report still says
## whether the whole scope cleared, and says how many rows it did not show.
static func filter_clearance(report: Dictionary, limit: int, failing_only: bool) -> Dictionary:
	var pairs: Array = report.get("pairs", []) as Array
	if limit <= 0 and not failing_only:
		return report
	var kept: Array = []
	for entry in pairs:
		var pair: Dictionary = entry
		if failing_only and bool(pair.get("pass", false)):
			continue
		kept.append(pair)
		if limit > 0 and kept.size() >= limit:
			break
	var out := report.duplicate(true)
	out["pairs"] = kept
	out["pairs_total"] = pairs.size()
	out["pairs_shown"] = kept.size()
	if kept.size() < pairs.size():
		out["pairs_filter"] = ("%d of %d pairs shown, closest first%s; "
			+ "`pass` is graded over ALL of them — call again without "
			+ "limit/failing_only for the rest") % [kept.size(), pairs.size(),
			" (failing only)" if failing_only else ""]
	return out


# ---------------------------------------------------------------------------
# Fastener obstructions
# ---------------------------------------------------------------------------

## Collapse an obstruction list to one row per distinct (node, span).
##
## The path fan casts hundreds of rays and a rib across a bore is met by many
## of them: the raw list is one row per RAY, all naming the same node with
## points a tenth of a millimetre apart. The collapsed row keeps the nearest
## crossing (the one the screw meets first), counts the rest and states the
## axial range they spanned, which is what a reader needs to find the rib.
static func collapse_obstructions(obstructions: Array) -> Array:
	var groups: Dictionary = {}
	var order: Array = []
	for entry in obstructions:
		var row: Dictionary = entry
		var key := "%s|%s|%s" % [str(row.get("reference", "")),
			str(row.get("node", "")), str(row.get("span", ""))]
		var axial := float(row.get("axial_mm", 0.0))
		if not groups.has(key):
			var first := row.duplicate(true)
			first["count"] = 1
			first["axial_range_mm"] = {"min": axial, "max": axial}
			groups[key] = first
			order.append(key)
			continue
		var group: Dictionary = groups[key]
		group["count"] = int(group["count"]) + 1
		var span_range: Dictionary = group["axial_range_mm"]
		span_range["min"] = minf(float(span_range["min"]), axial)
		span_range["max"] = maxf(float(span_range["max"]), axial)
		# The nearest crossing is the one the screw actually runs into, so the
		# representative point and its radius follow the minimum.
		if axial < float(group.get("axial_mm", INF)):
			var nearest := row.duplicate(true)
			nearest["count"] = group["count"]
			nearest["axial_range_mm"] = span_range
			groups[key] = nearest
	var out: Array = []
	for key in order:
		out.append(groups[key])
	return out


## Every obstruction list in a fastener report, collapsed in place.
static func collapse_report_obstructions(report: Dictionary) -> Dictionary:
	var out := report.duplicate(true)
	var rows: Array = out.get("screws", []) as Array
	for entry in rows:
		var row: Dictionary = entry
		for field in ["obstructions", "head_obstructions"]:
			if row.has(field):
				row[field] = collapse_obstructions(row[field] as Array)
	return out


## The reference holes a fastener check paired against, in the order the
## `pairs` override indexes them: [bore_index, hole_index]. Without this the
## indices in the reply name rows the caller never saw.
static func hole_index_rows(holes: Array) -> Array:
	var out: Array = []
	for index in range(holes.size()):
		var hole: Dictionary = holes[index]
		var centre: Dictionary = hole.get("center_mm", {})
		out.append({
			"index": index,
			"reference": str(hole.get("reference", "")),
			"node": str(hole.get("node", "")),
			"dia_mm": float(hole.get("dia_mm", 0.0)),
			"center_mm": centre,
			"through": bool(hole.get("through", false)),
		})
	return out


# ---------------------------------------------------------------------------
# A hole census, as DSL
# ---------------------------------------------------------------------------

## Write a measured hole census as .mcad the caller can paste.
##
## The centres are the WORLD ones: the DSL builds its solid in the same posed
## scene the references are mounted in, so those are the numbers that land the
## slug on the hole. Holes are grouped by radius and by axis so one slug
## serves several, and a hole whose axis is not square to a world axis is
## LEFT OUT and named — a rotate() invented for it would be a guess written in
## a form the reader cannot check.
##
## `kind` is "hole" (slugs to subtract) or "post" (cylinders to add).
static func holes_as_dsl(holes: Array, kind: String, clearance_mm: float,
		depth_mm: float) -> Dictionary:
	var groups: Dictionary = {}
	var order: Array = []
	var skipped: Array = []
	for entry in holes:
		var hole: Dictionary = entry
		var axis_world: Array = (hole.get("axis", {}) as Dictionary).get("world", []) as Array
		var axis := Vector3.ZERO
		if axis_world.size() == 3:
			axis = Vector3(float(axis_world[0]), float(axis_world[1]), float(axis_world[2]))
		var wrap := ""
		var square := false
		for candidate in _DSL_AXES:
			var spec: Dictionary = candidate
			var spec_axis: Vector3 = spec["axis"]
			if absf(axis.normalized().dot(spec_axis)) >= _DSL_AXIS_DOT:
				wrap = str(spec["rotate"])
				square = true
				break
		if not square:
			skipped.append("%s in %s: its axis is not square to a world axis"
				% [str(hole.get("node", "")), str(hole.get("reference", ""))])
			continue
		var radius := float(hole.get("dia_mm", 0.0)) * 0.5 + clearance_mm
		var length := depth_mm
		if length <= 0.0:
			# A slug that only just spans the hole leaves a coplanar face on
			# each end, which is the one thing a boolean cut is fragile about.
			length = maxf(float(hole.get("extent_mm", 0.0)) * 3.0, 1.0)
		var key := "%.4f|%.4f|%s" % [radius, length, wrap]
		if not groups.has(key):
			groups[key] = {"radius": radius, "length": length, "wrap": wrap,
				"centres": []}
			order.append(key)
		(groups[key]["centres"] as Array).append(
			(hole.get("center_mm", {}) as Dictionary).get("world", []))

	var noun := "posts" if kind == "post" else "holes"
	var lines: PackedStringArray = PackedStringArray()
	lines.append("# %d %s measured by minerva_cad_find_holes, world millimetres"
		% [holes.size() - skipped.size(), noun])
	if clearance_mm != 0.0:
		lines.append("# radii carry %s mm of clearance over the measured hole"
			% clearance_mm)
	var slug_index := 0
	var bound := false
	for key in order:
		var group: Dictionary = groups[key]
		slug_index += 1
		var slug := "slug_%d" % slug_index
		var body := "cylinder(h = %s, r = %s, center = true)" \
			% [_number(float(group["length"])), _number(float(group["radius"]))]
		var wrap: String = str(group["wrap"])
		lines.append("%s = %s" % [slug, body if wrap.is_empty() else wrap % body])
		for centre in group["centres"]:
			var at: Array = centre as Array
			if at.size() != 3:
				continue
			var placed := "translate([%s, %s, %s], %s)" % [
				_number(float(at[0])), _number(float(at[1])), _number(float(at[2])), slug]
			if bound:
				lines.append("%s = %s + %s" % [noun, noun, placed])
			else:
				lines.append("%s = %s" % [noun, placed])
				bound = true
	if not bound:
		return {"dsl": "", "skipped": skipped}
	lines.append("# then: part = part %s %s" % ["+" if kind == "post" else "-", noun])
	return {"dsl": "\n".join(lines) + "\n", "skipped": skipped}


## A length as the DSL should read it: no exponent, no trailing zeros, and
## never an empty fraction (build123d takes "5." as 5, a reader does not).
static func _number(value: float) -> String:
	var text := "%.4f" % value
	while text.ends_with("0"):
		text = text.substr(0, text.length() - 1)
	if text.ends_with("."):
		text += "0"
	return text
