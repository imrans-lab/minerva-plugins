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
## drops the pairs that CLEARED, which is not the same question as the row's
## `pass`: on a solid whose tessellation tolerance could not be bounded every
## row is graded false whatever its gap, so a filter keyed on `pass` hides
## nothing. It is keyed on the distance instead — see `pair_clears`. The
## limit is applied to what survives the filter, so limit=5 with failing_only
## is five FAILING rows and not five rows of which some failed.
##
## The report's own `pass` is graded over every pair before this runs and is
## not touched: a filtered report still says whether the whole scope cleared,
## and it always says how many rows it did not show.
static func filter_clearance(report: Dictionary, limit: int, failing_only: bool) -> Dictionary:
	var pairs: Array = report.get("pairs", []) as Array
	var required := float(report.get("required_mm", 0.0))
	var quantization := float(report.get("quantization_mm", 0.0))
	var kept: Array = []
	for entry in pairs:
		var pair: Dictionary = entry
		if failing_only and pair_clears(pair, required, quantization):
			continue
		kept.append(pair)
	var shown: Array = kept if limit <= 0 or kept.size() <= limit \
		else kept.slice(0, limit)
	# Shallow: only top-level keys are written here, and every pair that
	# travels is one of the caller's own rows, unmodified.
	var out := report.duplicate()
	out["pairs"] = shown
	out["pairs_total"] = pairs.size()
	out["pairs_shown"] = shown.size()
	var hidden := pairs.size() - shown.size()
	out["pairs_hidden"] = hidden
	if failing_only:
		out["pairs_failing"] = kept.size()
	if hidden > 0:
		out["pairs_filter"] = ("%d of %d pairs shown, closest first%s; "
			+ "%d hidden; `pass` is graded over ALL of them — call again "
			+ "without limit/failing_only for the rest") % [shown.size(),
			pairs.size(), " (failing only)" if failing_only else "", hidden]
	return out


## Did this pair clear the gap it had to keep?
##
## The measured distance less the float32 quantization of the shipped
## vertices, against the pair's own required_mm when it declared one and the
## call's otherwise. `pass` is taken as clearing when it is true, but its
## being false is not taken as failing: an unbounded tessellation tolerance
## fails every row in the report without saying anything about any one gap.
## The graded `pass` is read FIRST, before the shapes below: a declared
## contact is a touching row the check itself graded as clearing, and a rule
## of our own here would report it as a failure the row does not claim.
## A pair the check could not reason about — material overlap, a flush
## contact, a containment it could not decide — never clears otherwise,
## because the distance is not the answer for it.
static func pair_clears(pair: Dictionary, required_mm: float,
		quantization_mm: float) -> bool:
	if bool(pair.get("pass", false)):
		return true
	if bool(pair.get("interference", false)) \
			or bool(pair.get("touching", false)) \
			or bool(pair.get("containment_undecidable", false)):
		return false
	var need := float(pair.get("required_mm", required_mm))
	return float(pair.get("min_mm", 0.0)) - quantization_mm >= need


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


## How close two unpaired features' diameters have to be to travel as one
## group. A tenth of the tightest tolerance any of these checks grades on, so
## two nominally identical bores measured a micron apart still group.
const UNPAIRED_DIA_GROUP_MM: float = 0.01


## Collapse a fastener report's unpaired solid features to counts.
##
## An enclosure's shell has thirty-odd cylindrical surfaces no screw is ever
## going into — grille holes, sleeves, pilots, counterbores — and every one of
## them comes back as a row with a world centre and a source. That list is
## most of the reply and it is the same list on every call, so by default the
## rows are grouped into {dia_mm, count, indices} by diameter and by what the
## bore is FOR: the indices are exactly what a `pairs` override names, so the
## override still works off the grouped reply. detail="full" returns the rows.
static func lean_fastener_report(report: Dictionary, detail: String) -> Dictionary:
	if detail == "full":
		return report
	var unpaired: Dictionary = report.get("unpaired", {}) as Dictionary
	var features: Array = unpaired.get("solid_features", []) as Array
	if features.is_empty():
		return report
	var out := report.duplicate(true)
	var lean: Dictionary = out["unpaired"]
	lean["solid_features"] = group_unpaired_features(features)
	lean["solid_features_grouped"] = ("one row per diameter (grouped to %s mm) "
		+ "and fit; `indices` are the solid_feature numbers a `pairs` entry "
		+ "names and `count` is how many features the row stands for. Pass "
		+ "detail=\"full\" for the features themselves, with their centres.") \
		% UNPAIRED_DIA_GROUP_MM
	return out


## The grouping itself: one row per (diameter, fit), or per diameter for the
## surfaces that were never bores — a partial cylinder has no fit, and the
## sweep that disqualified it travels as the range the group covers.
static func group_unpaired_features(features: Array) -> Array:
	var groups: Dictionary = {}
	var order: Array = []
	for entry in features:
		var row: Dictionary = entry
		var dia := snappedf(float(row.get("dia_mm", 0.0)), UNPAIRED_DIA_GROUP_MM)
		var partial := row.has("sweep_deg")
		var fit := str(row.get("fit", ""))
		var key := "%.4f|%s" % [dia, "partial" if partial else fit]
		if not groups.has(key):
			var fresh := {"dia_mm": dia, "count": 0, "indices": []}
			if partial:
				fresh["partial"] = true
				fresh["reason"] = "partial cylinder: a screw down its axis " \
					+ "would be open on one side, so it is never paired " \
					+ "with a hole"
				fresh["sweep_deg"] = {"min": float(row["sweep_deg"]),
					"max": float(row["sweep_deg"])}
			elif not fit.is_empty():
				fresh["fit"] = fit
			groups[key] = fresh
			order.append(key)
		var group: Dictionary = groups[key]
		group["count"] = int(group["count"]) + 1
		if row.has("index"):
			(group["indices"] as Array).append(int(row["index"]))
		if partial:
			var sweep: Dictionary = group["sweep_deg"]
			sweep["min"] = minf(float(sweep["min"]), float(row["sweep_deg"]))
			sweep["max"] = maxf(float(sweep["max"]), float(row["sweep_deg"]))
	var out: Array = []
	for key in order:
		var group: Dictionary = groups[key]
		# A partial surface is not one of the pairing's bores, so it has no
		# index for a `pairs` entry to name and an empty list would read as
		# one it lost.
		if (group["indices"] as Array).is_empty():
			group.erase("indices")
		out.append(group)
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
			% [dsl_number(float(group["length"])), dsl_number(float(group["radius"]))]
		var wrap: String = str(group["wrap"])
		lines.append("%s = %s" % [slug, body if wrap.is_empty() else wrap % body])
		for centre in group["centres"]:
			var at: Array = centre as Array
			if at.size() != 3:
				continue
			var placed := "translate([%s, %s, %s], %s)" % [
				dsl_number(float(at[0])), dsl_number(float(at[1])), dsl_number(float(at[2])), slug]
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
static func dsl_number(value: float) -> String:
	var text := "%.4f" % value
	while text.ends_with("0"):
		text = text.substr(0, text.length() - 1)
	if text.ends_with("."):
		text += "0"
	return text
