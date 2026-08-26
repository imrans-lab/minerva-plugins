extends RefCounted
## The words and the colour a bus LANE wears: which net it carries, where it
## ends, and the one net colour every surface (ratsnest airwire, bus ghost,
## rings, pips, status line) paints that net in.
##
## Model-side and static so the text can be pinned without a canvas: the canvas
## draws these strings, the panel's standing status line lists them, and
## bus_target_guidance() hands the same fields to an agent.
##
## Off-tree plugin: NO class_name (see sibling pcb_layer_stack.gd) — reached via
## a relative preload() from model siblings and `model/pcb_bus_labels.gd` from
## ui/.

## The TARGETS-phase rule, said once, before the per-net status.
const TARGETS_RULE := "Click each net's target pad — lanes are numbered in the order you picked the nets."

## LANE ORDER IS PICK ORDER, and lane 1 is the lane on the LEFT of the spine
## looking along it from the sources to the targets (the most negative offset
## in cumulative_offsets; on a y-down board that is the side the spine's
## direction rotated anticlockwise points to). "Outward" moves a net toward
## lane 1 — one step left; "inward" moves it toward the last lane. At lane 1
## outward is a no-op, at the last lane inward is.
const REORDER_RULE := "Click a numbered pip to move that net outward (Shift+click inward) — lane 1 rides the left of the spine looking from the sources to the targets."

## What an ending reads as while no target is landed: "open" once the bus is in
## TARGETS (a commit now would leave the lane open-ended), "?" before that (the
## target is not yet askable).
const ENDING_OPEN := "open"
const ENDING_UNKNOWN := "?"


## THE net colour: the net's own `color` where it has one, white otherwise —
## the ratsnest's rule, so an airwire and the bus lane for one net cannot
## disagree. `net` is a pcb_net.gd object or null.
static func net_color(net) -> Color:
	if net == null:
		return Color.WHITE
	var c = net.color
	return c if c is Color else Color.WHITE


## How a lane ENDS if committed now: the landed target ref, else "open" in
## TARGETS, else "?".
static func ending(target_ref: String, in_targets: bool) -> String:
	if not target_ref.is_empty():
		return target_ref
	return ENDING_OPEN if in_targets else ENDING_UNKNOWN


## The label a lane wears at its far end: "NA → V1.1", "NA → open", "NA → ?".
static func lane_label(net: String, end: String) -> String:
	return "%s → %s" % [net, end]


## One line of the whole mapping, lane order first: "1 NA  U1.1 → V1.1".
static func lane_line(lane_index: int, net: String, source_ref: String, end: String) -> String:
	return "%d %s  %s → %s" % [lane_index, net, source_ref, end]


## Every lane's line, in lane order, from bus_target_guidance() rows (each
## carrying lane_index, net, source_ref, ending).
static func lane_lines(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for raw in rows:
		var r: Dictionary = raw
		out.append(lane_line(int(r.get("lane_index", 0)), str(r.get("net", "")),
			str(r.get("source_ref", "")), str(r.get("ending", ""))))
	return out


## The mapping as ONE status-line string: the lines joined by " · ".
static func lanes_summary(rows: Array) -> String:
	return " · ".join(lane_lines(rows))


## The advisory a crossing bus is given — "pick order NA, NC, NB would leave the
## bundle clean." — or "" when `order` is empty (no clean order, or not
## searched). Advisory only; nothing re-sorts on its own.
static func clean_order_sentence(order: PackedStringArray) -> String:
	if order.is_empty():
		return ""
	return "pick order %s would leave the bundle clean." % ", ".join(order)


## What a reorder click answers with when the net cannot move any further.
static func reorder_end_message(net: String, inward: bool) -> String:
	if inward:
		return "%s is already the last lane — it cannot move further inward." % net
	return "%s is already lane 1, the outermost — it cannot move further outward." % net
