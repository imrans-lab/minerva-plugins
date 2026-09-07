extends RefCounted
## SEVERAL SCREWS, ONE CALL — and each one graded only where it belongs.
##
## A real enclosure is not held together by one fastener size. The board goes
## down on M3x16 seated on the solid; the stick clips in on M2.5x8 seated on
## its own plate. Asked one screw at a time, that is three calls (one per size,
## plus the unscoped one to find out the scoping was needed), and the unscoped
## call is worse than slow: the diameter window round M3 reaches the joystick's
## 2.6 mm holes, so M3 is graded against holes no M3 will ever enter and the
## reply is full of failures that are not failures.
##
## So a check takes a LIST:
##
##     screws: [{dia_mm, length_mm, head_dia_mm?, seat?, seat_offset_mm?,
##               reference?, node?, min_dia_mm?, max_dia_mm?}]
##
## and each entry is paired only against the holes of ITS OWN reference — the
## whole scene when it names none, which is what a single screw has always
## done. `screw` is sugar for a one-element list and its reply is unchanged,
## because the shape one screw comes back in is the shape every caller and
## every fold already reads.
##
## WHAT A MERGED REPLY IS. One `screws` array — every graded row, each stamped
## with the screw it was graded for — over a `per_screw` list carrying what
## each entry was asked and what its own pairing left unpaired. The envelope
## fields that describe HOW the rays were cast are the same for every entry and
## are carried once.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: ui/panel_tools.gd (_check_fasteners) — which hands in the hole
## finder as a Callable, because that verb lives in the script above this one.

## The obstruction collapse and the unpaired-feature grouping every fastener
## reply goes through before it travels.
const _ReplyShape: Script = preload("reply_shape.gd")
const _FastenerChecks: Script = preload("fastener_checks.gd")

## The diameter window a screw's holes are looked for in, as multiples of the
## thread diameter. Wide enough for a clearance hole and its counterbore,
## narrow enough that a board full of vias is not a hundred candidates.
const HOLE_WINDOW_MIN_D: float = 0.8
const HOLE_WINDOW_MAX_D: float = 2.5


## The screws this call is about, in order, or {error}.
##
## Returns {screws: [spec], listed: bool}. `listed` says the caller used the
## list form, which is what decides whether a one-screw answer comes back in
## the single-screw shape or the merged one.
static func parse(args: Dictionary) -> Dictionary:
	var raw: Variant = args.get("screws", null)
	var listed := raw is Array
	var entries: Array = raw as Array if listed else [args.get("screw", {})]
	if listed and (raw as Array).is_empty():
		return {"error": "screws is empty: pass one or more "
			+ "{dia_mm, length_mm, reference?}, or leave it out and pass a "
			+ "single screw"}
	var out: Array = []
	for index in range(entries.size()):
		if not (entries[index] is Dictionary):
			return {"error": "each screws entry is a dictionary: "
				+ "{dia_mm, length_mm, head_dia_mm?, seat?, reference?, node?}"}
		var one: Dictionary = entries[index]
		var dia := float(one.get("dia_mm", 0.0))
		if dia <= 0.0:
			return {"error": ("check_fasteners needs {dia_mm, length_mm} in "
				+ "millimetres for every screw; entry %d has no dia_mm")
				% index}
		var spec := one.duplicate(true)
		spec["index"] = index
		# The window this entry's holes are looked for in, narrowest statement
		# first: the entry's own, then the CALL's — min_dia_mm/max_dia_mm are
		# documented arguments and a caller who narrowed the window there
		# meant it, for the single-screw sugar and as the default under a list
		# alike — and a band around the thread only when neither said. Per
		# entry, because a window round M3 reaches holes an M2.5 owns and
		# grading one against the other is the noise the list exists to remove.
		spec["min_dia_mm"] = float(one.get("min_dia_mm",
			args.get("min_dia_mm", dia * HOLE_WINDOW_MIN_D)))
		spec["max_dia_mm"] = float(one.get("max_dia_mm",
			args.get("max_dia_mm", dia * HOLE_WINDOW_MAX_D)))
		out.append(spec)
	return {"screws": out, "listed": listed}


## Run every screw in turn and hand back one report.
##
## `find_holes` and `has_reference` are Callables of the verb layer: this
## script is preloaded BY it, and preloading it back would be a cycle. The
## screws run one after another because they share the panel's single solid
## collider, the same reason the parts do.
static func run(panel, args: Dictionary, find_holes: Callable,
		has_reference: Callable) -> Dictionary:
	var parsed := parse(args)
	if parsed.has("error"):
		return parsed
	var specs: Array = parsed["screws"]
	var detail := str(args.get("detail", ""))
	var runs: Array = []
	for entry in specs:
		var spec: Dictionary = entry
		var scope := str(spec.get("reference", args.get("reference", "")))
		if not scope.is_empty() and not bool(has_reference.call(panel, scope)):
			return {"error": "no reference named '%s' is mounted" % scope}
		var node := str(spec.get("node", args.get("node", "")))
		var hole_args := args.duplicate(true)
		hole_args.erase("screws")
		hole_args.erase("screw")
		hole_args["reference"] = scope
		hole_args["node"] = node
		hole_args["min_dia_mm"] = float(spec["min_dia_mm"])
		hole_args["max_dia_mm"] = float(spec["max_dia_mm"])
		var holes: Dictionary = await find_holes.call(panel, hole_args)
		if holes.has("error"):
			return holes
		var report: Dictionary = await panel.check_fasteners({
			# A part-scoped check brings both: the mesh the rays are cast
			# against and the source the B-Rep bores are read from. They must
			# be the same part or the bores would be one shape's and the
			# collider another's.
			"mesh": args.get("mesh", {}),
			"source": str(args.get("source", "")),
			"screw": spec,
			"holes": holes.get("holes", []),
			"pairs": args.get("pairs", []),
			"engagement_min_d": float(args.get("engagement_min_d",
				_FastenerChecks.DEFAULT_ENGAGEMENT_D)),
			"clearance_hole_dia_mm": args.get("clearance_hole_dia_mm", 0.0),
			"compare_fit": bool(args.get("compare_fit", false)),
			"reference": scope,
			"node": node,
		})
		if report.has("error"):
			return report
		report = _ReplyShape.collapse_report_obstructions(report)
		# The unpaired features are the bulk of a shell's reply and are the
		# same list on every call, so they travel as counts unless the caller
		# asks for the rows.
		report = _ReplyShape.lean_fastener_report(report, detail)
		report["holes_considered"] = int(holes.get("count", 0))
		runs.append({"spec": spec, "report": report})
	if runs.size() == 1:
		var only: Dictionary = (runs[0] as Dictionary)["report"]
		only["pairs_note"] = pairs_note()
		return only
	return merge(runs)


## Several screws' reports as one. Every graded row travels, stamped with the
## screw it was graded for; what each entry was ASKED, and what its own
## pairing could not use, stays beside it under per_screw.
static func merge(runs: Array) -> Dictionary:
	var rows: Array = []
	var per_screw: Array = []
	var checked := true
	var failed := 0
	var envelope: Dictionary = {}
	for entry in runs:
		var run: Dictionary = entry
		var spec: Dictionary = run["spec"]
		var report: Dictionary = run["report"]
		var named := {
			"index": int(spec["index"]),
			"dia_mm": float(spec["dia_mm"]),
			"length_mm": float(spec.get("length_mm", 0.0)),
		}
		if not str(spec.get("reference", "")).is_empty():
			named["reference"] = str(spec["reference"])
		if not str(spec.get("node", "")).is_empty():
			named["node"] = str(spec["node"])
		var ran := bool(report.get("checked", false))
		checked = checked and ran
		failed += int(report.get("failed", 0))
		for row_entry in (report.get("screws", []) as Array):
			var row: Dictionary = row_entry
			# The row says which screw it graded, so a merged list is readable
			# without counting back through per_screw.
			row["screw"] = named
			rows.append(row)
		var summary := named.duplicate(true)
		summary["checked"] = ran
		summary["count"] = int(report.get("count", 0))
		summary["failed"] = int(report.get("failed", 0))
		summary["pass"] = bool(report.get("pass", false))
		summary["holes_considered"] = int(report.get("holes_considered", 0))
		summary["dia_window_mm"] = {"min": float(spec["min_dia_mm"]),
			"max": float(spec["max_dia_mm"])}
		if not ran:
			summary["reason"] = str(report.get("reason",
				"this screw's check did not run"))
		if report.has("unpaired"):
			summary["unpaired"] = report["unpaired"]
		if report.has("axis_source"):
			summary["axis_source"] = str(report["axis_source"])
		per_screw.append(summary)
		if envelope.is_empty() and ran:
			envelope = report
	var out := {
		"checked": checked,
		"units": "mm",
		"count": rows.size(),
		"failed": failed,
		"pass": failed == 0 and not rows.is_empty() and checked,
		"screws": rows,
		"per_screw": per_screw,
		"screws_note": "each screw was paired ONLY against the holes of its "
			+ "own reference and its own diameter window (per_screw."
			+ "dia_window_mm), so a size is never graded against a hole "
			+ "another size owns; every row names the screw it belongs to "
			+ "under `screw`, and what each entry's pairing could not use is "
			+ "under per_screw.unpaired.",
		"pairs_note": pairs_note(),
	}
	# How the rays were cast is the same question for every entry, so it is
	# answered once rather than per screw.
	for field in ["engagement_min_d", "tessellation_tolerance_mm",
			"ray_spacing_mm", "ray_spacing", "rays_total", "sampling"]:
		if envelope.has(field):
			out[field] = envelope[field]
	return out


## What the indices in a fastener reply name. One sentence, shared by both
## reply shapes so a reader never has to work out which one they are holding.
static func pairs_note() -> String:
	return "reference_hole_index[].index is the number a pairs entry's " \
		+ "`reference_hole` names — a hole with no usable axis is not in it, " \
		+ "so the numbering is the check's own and not the order " \
		+ "minerva_cad_find_holes reported. Obstruction rows are collapsed " \
		+ "to one per (node, span), keeping the nearest crossing with a " \
		+ "count and the axial range the rays met it over, and " \
		+ "unpaired.solid_features to one row per diameter and fit — pass " \
		+ "detail=\"full\" for the unpaired features themselves."
