extends RefCounted
## PcbHintWaypoint — the shape of ONE entry in a route hint's
## `kind_payload.waypoints`, and the only place that knows a waypoint may name
## a copper LAYER.
##
## ── WHY A WAYPOINT CARRIES A LAYER (work item 01a04106bd) ─────────────────────
## The live HITL: the owner drew one F.Cu hint across a board whose corridor is
## blocked by VBAT_F and the buck cluster, then proposed FOUR separate vias to
## duck under the obstacles. The hint was un-routable as drawn, the four via
## ghosts carried no net and no owner, and the agent recovered the intent only
## by matching via coordinates to hint segments BY EYE. The intent itself is
## simple and ordinary — "F.Cu, duck under here, come back up there, F.Cu" — and
## it had no way to be said.
##
## A waypoint that names a layer says it: the run CHANGES to that layer at that
## point, and whoever materializes the hint puts the hop via exactly there.
## There is nothing left for an agent to geometry-match, because the via is not
## a separate object any more — it is a property of the corner.
##
## ── THE TWO SHAPES ────────────────────────────────────────────────────────────
##   [x_mm, y_mm]                        — a plain corner (the original shape,
##                                         still the shape most hints have)
##   {"x": x_mm, "y": y_mm, "layer": id} — a corner the run changes layer at
##
## `layer` is a CANONICAL copper id ("top" / "in1".."in30" / "bottom") or a
## KiCad copper name ("F.Cu" / "B.Cu" / "In1.Cu"); PcbLayerStack owns the
## translation and this file never invents one. A waypoint with no `layer` key,
## or an empty one, is a plain corner — absent means "keep going on the layer
## you are on", never "default to the top".
##
## Off-tree plugin: NO class_name; reached by relative preload.

const PcbLayerStack := preload("pcb_layer_stack.gd")


## The [x_mm, y_mm] position of one waypoint entry, tolerating every shape the
## panel and a JSON round trip produce. Mirrors pcb_route_hint_kind._to_vec2 —
## kept here as the ARRAY form because the wire/storage side of a hint speaks
## arrays, not Vector2.
static func position_of(entry) -> Array:
	if entry is Array and (entry as Array).size() >= 2:
		return [float((entry as Array)[0]), float((entry as Array)[1])]
	if entry is Vector2:
		return [(entry as Vector2).x, (entry as Vector2).y]
	if entry is Dictionary:
		var d: Dictionary = entry
		if d.has("x") and d.has("y"):
			return [float(d["x"]), float(d["y"])]
		if d.has("x_mm") and d.has("y_mm"):
			return [float(d["x_mm"]), float(d["y_mm"])]
	return []


## The copper layer this waypoint changes the run to, as the CANONICAL id, or
## "" when it is a plain corner. An unrecognised name comes back "" — callers
## that must refuse a typo use error_for() instead, which distinguishes
## "no layer here" from "a layer I cannot read".
static func layer_of(entry) -> String:
	var raw := raw_layer_of(entry)
	# is_copper FIRST: kicad_to_canon passes an unknown name through (with a
	# warning) rather than refusing, so asking it to classify a typo would
	# answer "top-ish" for "F.Co".
	if raw.is_empty() or not PcbLayerStack.is_copper(raw):
		return ""
	return PcbLayerStack.kicad_to_canon(raw)


## The layer name exactly as authored ("" when the entry names none). Kept
## separate from layer_of so an error message can quote what the author wrote
## rather than what the translation made of it.
static func raw_layer_of(entry) -> String:
	if not (entry is Dictionary):
		return ""
	return str((entry as Dictionary).get("layer", "")).strip_edges()


## "" when `entry` is a legal waypoint, otherwise a human-readable reason.
## Refuses a layer this board does not declare when `declared_layers` is a
## non-empty Array of canonical ids — the same fail-closed rule the worker's
## authored-segment path applies, and for the same reason: "in7" as a typo and
## "in7" as a plane are indistinguishable, so an undeclared name is a refusal,
## never copper on a layer that does not exist.
static func error_for(entry, declared_layers: Array = []) -> String:
	if position_of(entry).is_empty():
		return "waypoint is neither [x_mm, y_mm] nor {x, y}"
	var raw := raw_layer_of(entry)
	if raw.is_empty():
		return ""
	if not PcbLayerStack.is_copper(raw):
		return "waypoint layer '%s' is not a copper layer" % raw
	var canon := PcbLayerStack.kicad_to_canon(raw)
	if not declared_layers.is_empty() and not (canon in declared_layers):
		return "waypoint layer '%s' is not declared by this board (declared: %s)" \
			% [raw, str(declared_layers)]
	return ""


## Rebuild one waypoint entry at `position` (Vector2), PRESERVING whatever layer
## the entry it replaces carried. This is what keeps a bend drag from silently
## deleting a layer hop: moving a corner moves the via with it, it does not
## dissolve it back into flat copper.
static func with_position(entry, position: Vector2) -> Variant:
	var raw := raw_layer_of(entry)
	if raw.is_empty():
		return [position.x, position.y]
	var out: Dictionary = (entry as Dictionary).duplicate(true)
	out["x"] = position.x
	out["y"] = position.y
	out.erase("x_mm")
	out.erase("y_mm")
	return out


## Every index in `waypoints` whose entry changes layer, in order. The count of
## these IS the number of hop vias a materialized hint carries.
static func layer_change_indices(waypoints: Array) -> Array:
	var out: Array = []
	for i in range(waypoints.size()):
		if not layer_of(waypoints[i]).is_empty():
			out.append(i)
	return out
