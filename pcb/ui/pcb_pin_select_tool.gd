extends RefCounted
## The Pin Select tool — a PAD is a thing you can point at.
##
## Universal Select picks the whole part (44 pins on one part is not unusual),
## so without this tool the human cannot say "this pin" and get_selection cannot
## report one: every pin-level question ("what net is this?", "move these two to
## the other column") gets answered by guessing a refdes from a coordinate. The
## acceptance case is "select two pads, say move these to the other side of
## U1S", and the selection is what gets read.
##
## THIS FILE IS THE TOOL'S RULES, not its plumbing. pcb_canvas.gd owns the
## input events, the paint and the selection storage (KIND_PAD rides the same
## _selection_of framework every other kind does); it calls in here for the
## three things that are the TOOL: what a click picks, what a click does to the
## selection, and where the selected copper is so it can be lit.
##
## The tool IS the canvas's INSPECT_PIN mode, grown up — one pad-picking mode,
## not two. Its single-click behaviour is unchanged (nearest pad → pin_selected),
## so the pin inspector's contract still holds; what is new is that the pick is
## now also a SELECTION, and that shift extends it.
##
## Off-tree module — NO class_name, reached by relative preload.

const _PcbPadRow := preload("model/pcb_pad_row.gd")

## Pick radius in mm, contract §2's inspector default. A click is measured to a
## pad's COPPER (pcb_component.pin_copper_distance, through host.pad_at), not to
## its centre, so a click anywhere on a big connector land picks that land.
const PICK_RADIUS_MM := 5.0


## What a click at `world_pos` picks: "REF.PIN", or "" for empty space.
## `host` is the PcbAnnotationHost (duck-typed) that owns pad_at — the canvas
## does no pad hit-testing of its own, and neither does this tool.
static func pick(host, world_pos: Vector2, filter: Callable) -> String:
	if host == null or not host.has_method("pad_at"):
		return ""
	var hit: Dictionary = host.pad_at(world_pos, PICK_RADIUS_MM, filter)
	if hit.is_empty():
		return ""
	return _PcbPadRow.make_ref(str(hit.get("component", "")), str(hit.get("pin", "")))


## The selection algebra, and the whole of it:
##   click a pad          → that pad alone
##   click empty space    → nothing selected
##   shift-click a pad    → add it, or remove it if it was already in
##   shift-click empty    → the selection is left alone (a missed shift-click
##                          must not throw away a multi-pad selection the human
##                          spent four clicks building)
## Returns the NEW list; never mutates `current`.
static func apply_click(current: Array, ref: String, additive: bool) -> Array:
	if ref.is_empty():
		return current.duplicate() if additive else []
	if not additive:
		return [ref]
	var out: Array = current.duplicate()
	var at := out.find(ref)
	if at >= 0:
		out.remove_at(at)
	else:
		out.append(ref)
	return out


## Where a selected pad's copper is, for the highlight: one entry per LAND, in
## the {position, size, rotation} world form pcb_component.get_pad_world_transform
## hands back — the SAME transform the pad renderer and the copper hit test read,
## so the halo cannot land anywhere but on the copper it belongs to. A pin with
## no land geometry falls back to a zero-size box at its position, which the
## caller draws as a small ring.
static func land_transforms(data, ref: String) -> Array:
	var parts := _PcbPadRow.parse_ref(ref)
	if parts.is_empty() or data == null:
		return []
	var comp = data.get_component(str(parts[0]))
	if comp == null or not comp.pins.has(str(parts[1])):
		return []
	var out: Array = []
	for land in comp.lands_for_pin(str(parts[1])):
		out.append(comp.get_pad_world_transform(land as Dictionary))
	if out.is_empty():
		out.append({"position": comp.get_pin_world_position(str(parts[1])),
			"size": Vector2.ZERO, "rotation": 0.0})
	return out


## The standing status line for a pad selection — what the human sees the
## moment the selection changes. "" when nothing is selected.
static func status_line(data, refs: Array) -> String:
	if refs.is_empty():
		return ""
	if refs.size() == 1:
		var rows: Array = _PcbPadRow.rows_for_refs(data, refs)
		if rows.is_empty():
			return "Pin %s" % str(refs[0])
		var pad: Dictionary = rows[0]
		var net := str(pad.get("net", ""))
		return "Pin %s — %s, %s side" % [str(pad.get("ref", "")),
			net if not net.is_empty() else "no net", str(pad.get("side", "?"))]
	return "%d pins selected: %s" % [refs.size(), ", ".join(PackedStringArray(refs))]
