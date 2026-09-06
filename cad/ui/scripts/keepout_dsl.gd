extends RefCounted
## keepout_dsl.gd — the reference listing as .mcad KEEP-OUT envelopes.
##
## minerva_cad_references already carries a world axis-aligned box for every
## node of every mounted reference. This turns that data into source a shell
## can subtract directly:
##
##     keepout_board = translate([...], cube(..., center = true))
##     keepout_board = keepout_board + translate([...], cube(...))
##     # then: part = part - keepout_board
##
## so an enclosure wall is written against the boxes instead of against four
## numbers retyped out of a reply. One binding per reference, one cube per
## node, every cube grown by the caller's clearance on all six sides.
##
## WHAT THE BOX IS NOT. It is the node's bounding box in its WORLD pose, so a
## part mounted at an angle gets the box its rotated silhouette needs, which is
## larger than the part. The emitted comment says so, because a keep-out that
## is too big is only a fit problem while a keep-out that is too small is a
## crash.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: ui/panel_tools.gd (minerva_cad_references emit_dsl=true).

const _ReplyShape: Script = preload("reply_shape.gd")

## How many node cubes may be written in one reply. A board is forty-five
## nodes; an imported STEP assembly can be thousands, and a reply that large
## is not source anyone pastes. Above this the caller has to say which nodes
## they actually want to keep clear.
const MAX_NODES: int = 200

## Width the node-list comment wraps at, so the emitted source stays readable
## in a text tab without a horizontal scroll.
const COMMENT_WIDTH: int = 76


## The keep-out source for `rows` — the detail="full" reference rows the verb
## has already built, each {name, nodes:[{name, path, bbox_mm:{world:{min,
## max}}}]}.
##
## `node_filters` is the caller's nodes= list; each entry is a path from the
## file root or a bare leaf name, the same rule every node= argument uses. An
## empty list means every node of every reference in `rows`.
##
## Returns {dsl, bindings, node_count, omitted} or {error}.
static func emit(rows: Array, node_filters: Array, clearance_mm: float) -> Dictionary:
	if clearance_mm < 0.0:
		return {"error": "clearance_mm must not be negative — a keep-out "
			+ "envelope smaller than the part it stands for keeps nothing out"}
	var wanted := _filters(node_filters)
	var selected: Array = []
	var empty: Array = []
	var total := 0
	for entry in rows:
		var row: Dictionary = entry
		var picked: Array = []
		for node_entry in row.get("nodes", []) as Array:
			var node: Dictionary = node_entry
			if not _wanted(str(node.get("path", node.get("name", ""))),
					str(node.get("name", "")), wanted):
				continue
			picked.append(node)
		if picked.is_empty():
			# A reference whose file did not load has no nodes at all. Saying
			# so is the difference between a smaller keep-out and a wrong one.
			if wanted.is_empty():
				empty.append("%s: loaded no geometry (status %s) — no "
					% [str(row.get("name", "")), str(row.get("status", ""))]
					+ "envelope written for it")
			continue
		total += picked.size()
		selected.append({"name": str(row.get("name", "")), "nodes": picked})
	if total > MAX_NODES:
		return {"error": ("%d nodes are in scope and at most %d are written; "
			+ "pass nodes=[...] naming the ones the design has to clear, or "
			+ "reference=<name> to scope to one file")
			% [total, MAX_NODES]}

	var omitted := _unmatched(wanted, rows)
	omitted.append_array(empty)
	var lines := PackedStringArray()
	lines.append("# Keep-out envelopes from minerva_cad_references, world "
		+ "millimetres.")
	lines.append("# One cube per node: its WORLD axis-aligned bounding box, "
		+ "grown by")
	lines.append("# %s mm on every side. A part mounted at an angle still gets "
		% _ReplyShape.dsl_number(clearance_mm)
		+ "its WORLD")
	lines.append("# box, which is larger than the part — a keep-out is meant "
		+ "to be generous.")
	var bindings: Array = []
	for entry in selected:
		var reference: Dictionary = entry
		var binding := "keepout_%s" % _identifier(str(reference["name"]))
		var written := _write_reference(lines, binding,
			reference["nodes"] as Array, clearance_mm, omitted)
		if written > 0:
			bindings.append(binding)
	for note in omitted:
		lines.append("# %s" % str(note))
	if bindings.is_empty():
		return {"dsl": "", "bindings": [], "node_count": 0, "omitted": omitted}
	lines.append("# then: part = part - %s" % " - ".join(PackedStringArray(bindings)))
	return {
		"dsl": "\n".join(lines) + "\n",
		"bindings": bindings,
		"node_count": total,
		"omitted": omitted,
	}


## One reference's binding, appended to `lines`. Returns how many cubes it
## wrote; a node whose box has no extent in some direction cannot be a cube
## and is named in `omitted` instead.
static func _write_reference(lines: PackedStringArray, binding: String,
		nodes: Array, clearance_mm: float, omitted: Array) -> int:
	var written := 0
	var named := PackedStringArray()
	var body := PackedStringArray()
	for entry in nodes:
		var node: Dictionary = entry
		var path := str(node.get("path", node.get("name", "")))
		var box: Dictionary = (node.get("bbox_mm", {}) as Dictionary).get(
			"world", {}) as Dictionary
		var low: Variant = _point(box.get("min", null))
		var high: Variant = _point(box.get("max", null))
		if low == null or high == null:
			omitted.append("%s: no geometry — nothing to keep out" % path)
			continue
		var size: Vector3 = (high as Vector3) - (low as Vector3) \
			+ Vector3.ONE * (clearance_mm * 2.0)
		if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
			omitted.append(("%s: its box is flat in one direction and "
				+ "clearance_mm is 0, so there is no cube to write") % path)
			continue
		var centre: Vector3 = ((low as Vector3) + (high as Vector3)) * 0.5
		var placed := "translate([%s, %s, %s], cube(%s, %s, %s, center = true))" % [
			_ReplyShape.dsl_number(centre.x),
			_ReplyShape.dsl_number(centre.y),
			_ReplyShape.dsl_number(centre.z),
			_ReplyShape.dsl_number(size.x),
			_ReplyShape.dsl_number(size.y),
			_ReplyShape.dsl_number(size.z),
		]
		if written == 0:
			body.append("%s = %s" % [binding, placed])
		else:
			body.append("%s = %s + %s" % [binding, binding, placed])
		named.append(path)
		written += 1
	if written == 0:
		return 0
	lines.append("# %s — %d node%s:" % [binding, written,
		"" if written == 1 else "s"])
	for line in _wrap(named):
		lines.append("#   %s" % line)
	lines.append_array(body)
	return written


## The node list as comment-width lines, so a forty-five node board reads as a
## paragraph rather than as one very long line.
static func _wrap(names: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	var current := ""
	for name in names:
		if current.is_empty():
			current = name
		elif current.length() + name.length() + 2 <= COMMENT_WIDTH:
			current += ", " + name
		else:
			out.append(current + ",")
			current = name
	if not current.is_empty():
		out.append(current)
	return out


## The caller's nodes= list, stripped and de-duplicated.
static func _filters(raw: Array) -> Array:
	var out: Array = []
	for entry in raw:
		var name := str(entry).strip_edges()
		if name.is_empty() or out.has(name):
			continue
		out.append(name)
	return out


## Same node= rule as every measurement verb: the path from the file root, or
## a bare leaf name. No filters means every node.
static func _wanted(path: String, leaf: String, filters: Array) -> bool:
	if filters.is_empty():
		return true
	for filter in filters:
		var name := str(filter)
		if path == name or path.get_file() == name or leaf == name:
			return true
	return false


## Notes for the nodes= entries no mounted node carries. A name that matched
## nothing is the caller's belief about the file being wrong, and silence
## about it emits a smaller keep-out than they asked for.
static func _unmatched(filters: Array, rows: Array) -> Array:
	var out: Array = []
	for filter in filters:
		var name := str(filter)
		var found := false
		for entry in rows:
			for node_entry in (entry as Dictionary).get("nodes", []) as Array:
				var node: Dictionary = node_entry
				var path := str(node.get("path", node.get("name", "")))
				if path == name or path.get_file() == name \
						or str(node.get("name", "")) == name:
					found = true
					break
			if found:
				break
		if not found:
			out.append(("%s: no node of that name carries geometry — omitted"
				) % name)
	return out


## A binding name the DSL could bind. Reference names come from the source's
## own bindings, so this normally changes nothing; it exists so a name that
## somehow is not an identifier produces source that parses.
static func _identifier(name: String) -> String:
	var out := ""
	for index in range(name.length()):
		var ch := name.substr(index, 1)
		if ch.is_valid_identifier() or (out.length() > 0 and ch.is_valid_int()):
			out += ch
		else:
			out += "_"
	return "reference" if out.is_empty() else out


static func _point(raw: Variant) -> Variant:
	if not (raw is Array) or (raw as Array).size() != 3:
		return null
	var values: Array = raw
	return Vector3(float(values[0]), float(values[1]), float(values[2]))
