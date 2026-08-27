extends RefCounted
## ONE READ for everything inside a board rectangle.
##
## Off-tree module — NO class_name, siblings reached by relative preload (see
## pcb_canvas.gd's port note). Every function here is STATIC and pure; the board
## is never mutated.
##
## ── WHY ──────────────────────────────────────────────────────────────────────
## Understanding the copper around ONE part cost five verbs and a hand
## cross-reference: list_zones + describe_zone (twice) + get_components (all 37
## parts) + spatial_query + pin_info. spatial_query already sweeps a rectangle,
## but it reports copper as bare ID LISTS — no pad nets, no zone outlines, no
## trace free ends — so the answers still had to be reassembled by hand from
## other verbs, and the reassembly is where a reader gets it wrong.
##
## ── NOTHING HERE IS A NEW RULE ───────────────────────────────────────────────
## Every answer is the answer some existing surface already gives:
##
##   which entities are in the rectangle  data.get_components_in_region /
##                                        get_traces_in_region /
##                                        get_vias_in_region /
##                                        get_zones_in_region /
##                                        cutouts_in_region — the SAME sweeps
##                                        the human's marquee walks and
##                                        spatial_query's copper block reads
##   a pad                                PcbPadRow.rows_for_component — the one
##                                        row shape get_selection and pin_info
##                                        emit
##   "this trace end is free"             data.trace_end_is_joined, negated —
##                                        the same predicate the Trace tool
##                                        refuses to draw from and the
##                                        connectivity DRC credits
##   a pour's outline / whether it fills  data.zone_outline_to_list and
##                                        PcbZoneCopper.fill_regions
##   which layers a via really meets      the shared contact predicate
##                                        (PcbCopperContact.nodes_touch), see
##                                        layers_touched below
##
## So a region read cannot disagree with the verb it summarises. Adding an
## answer here means finding the surface that already owns it, never writing a
## second rule.
##
## ── VIEW STATE IS IGNORED, deliberately ──────────────────────────────────────
## Same stance spatial_query's copper block takes: the human's marquee honours
## layer visibility because a person selects what they can see, while an agent
## asking what is in a rectangle is asking about the BOARD. An answer that
## changed with someone else's View menu would be unreproducible. The reply says
## so rather than leaving it to be discovered.

const PcbPadRow := preload("pcb_pad_row.gd")
const PcbCopperContact := preload("pcb_copper_contact.gd")
const PcbZoneCopper := preload("pcb_zone_copper.gd")

## The two ends of a trace, in the order they are reported. Spelled here rather
## than read off pcb_data's TRACE_END_START/END consts because instance
## const-forwarding across a duck-typed `data` is exactly what panel_tools'
## _PcbDataScript note warns against; the VALUES are held equal by the suite.
const TRACE_ENDS: Array[String] = ["start", "end"]


# ── THE REGION READ ──────────────────────────────────────────────────────────

## Everything the board has inside `region`.
##
## `layer` ("" for every layer) filters entities that HAVE a copper layer —
## traces, vias (by the layers their barrel spans), zones, keepouts and pads.
## COMPONENTS ARE NEVER FILTERED BY IT: a part is a physical object with a
## mounting side, not a piece of copper on one layer, and dropping a part
## because its pads are elsewhere would hide the thing the agent is standing
## next to. Its `pads` array is filtered instead.
##
## `annotations` is the live annotation list (host.get_all_annotations()) or
## [] — see notes_in_region.
static func describe(data, region: Rect2, layer: String = "",
		annotations: Array = []) -> Dictionary:
	var want := PcbCopperContact.canon(layer)
	return {
		"region_mm": {
			"x_mm": _mm(region.position.x), "y_mm": _mm(region.position.y),
			"width_mm": _mm(region.size.x), "height_mm": _mm(region.size.y),
		},
		"layer": want,
		"components": components_in_region(data, region, want),
		"traces": traces_in_region(data, region, want),
		# The copper index is built INSIDE vias_in_region, once, and only when
		# the rectangle actually holds a via — a region with none should not pay
		# for a whole-board copper walk.
		"vias": vias_in_region(data, region, want),
		"zones": zones_in_region(data, region, want, false),
		"keepouts": zones_in_region(data, region, want, true),
		"cutouts": cutouts_in_region(data, region),
		"notes": notes_in_region(annotations, region),
		# NAME WHAT WAS SEARCHED, the reason spatial_query's own block does:
		# without it an agent reading "traces: []" cannot tell "nothing is
		# routed here" from "traces were not looked for", and the first
		# reading is the dangerous one — it invites routing through copper the
		# query never examined.
		"searched": ["components", "traces", "vias", "zones", "keepouts",
			"cutouts", "notes"],
		"note": "one read of the board inside region_mm, regardless of layer visibility — this is what the BOARD has, not what the panel currently shows. A trace is listed whole (all of its points) when any part of it enters the region.",
	}


## Every component whose footprint rectangle the region touches, with its pads
## as THE pad row. Sorted by refdes so two reads of an unchanged board are
## byte-identical.
static func components_in_region(data, region: Rect2, want_layer: String) -> Array:
	var ids: Array = data.get_components_in_region(region)
	ids.sort()
	var out: Array = []
	for comp_id in ids:
		var comp = data.get_component(str(comp_id))
		if comp == null:
			continue
		var pads: Array = []
		for row in PcbPadRow.rows_for_component(data, comp):
			if _pad_on_layer(row as Dictionary, want_layer):
				pads.append(row)
		out.append({
			"ref": str(comp.id),
			"position": {"x_mm": _mm(comp.position.x), "y_mm": _mm(comp.position.y)},
			"rotation_deg": _mm(float(comp.rotation)),
			"layer": str(comp.layer),
			"pads": pads,
		})
	return out


## A pad's copper is on `want_layer` when the row says so, or when the row says
## "all" — a through-hole barrel pierces every copper layer, so it is on the
## asked-for layer whatever that layer is. "" wants every layer.
static func _pad_on_layer(row: Dictionary, want_layer: String) -> bool:
	if want_layer.is_empty():
		return true
	var pad_layer := str(row.get("layer", ""))
	return pad_layer == "all" or PcbCopperContact.canon(pad_layer) == want_layer


## Every trace the region touches, WHOLE. A trace that crosses the boundary
## carries all of its points, not the part inside the box: a clipped polyline
## would describe copper that does not exist, and where a run GOES is most of
## why an agent asked about the region at all.
static func traces_in_region(data, region: Rect2, want_layer: String) -> Array:
	var ids: Array = data.get_traces_in_region(region)
	ids.sort()
	var out: Array = []
	for trace_id in ids:
		var trace = data.get_trace(str(trace_id))
		if trace == null:
			continue
		if not want_layer.is_empty() \
				and PcbCopperContact.canon(trace.layer) != want_layer:
			continue
		var points: Array = []
		for p in trace.waypoints:
			points.append({"x_mm": _mm((p as Vector2).x), "y_mm": _mm((p as Vector2).y)})
		out.append({
			"trace_id": str(trace.id),
			"net": str(trace.net_name),
			"layer": str(trace.layer),
			"width_mm": _mm(float(trace.width)),
			"points": points,
			"free_ends": free_ends(data, str(trace.id)),
			"locked": bool(trace.locked),
		})
	return out


## The ends of `trace_id` that are NOT joined to other copper, each with the
## point it sits at.
##
## THE RULE IS data.trace_end_is_joined, NEGATED — nothing else. That predicate
## measures this end's own swept copper against every pad (the shared contact
## predicate), every via, every same-net trace and every same-net POUR FILL, and
## it is what the canvas Trace tool refuses to draw from and what the
## connectivity DRC credits. A region read that answered "free" by a looser rule
## would offer an agent a landing the tool then refuses.
static func free_ends(data, trace_id: String) -> Array:
	var trace = data.get_trace(trace_id)
	if trace == null or trace.waypoints.size() < 2:
		return []
	var out: Array = []
	for end in TRACE_ENDS:
		if data.trace_end_is_joined(trace_id, end):
			continue
		var pt: Vector2 = trace.waypoints[0] if end == TRACE_ENDS[0] \
			else trace.waypoints[trace.waypoints.size() - 1]
		out.append({"end": end, "x_mm": _mm(pt.x), "y_mm": _mm(pt.y)})
	return out


## Every via the region touches, each carrying the layers its copper actually
## MEETS (see layers_touched). `copper` is a prebuilt index; pass {} to build
## one for this call.
static func vias_in_region(data, region: Rect2, want_layer: String,
		copper: Dictionary = {}) -> Array:
	var ids: Array = data.get_vias_in_region(region)
	ids.sort()
	if ids.is_empty():
		return []
	var index: Dictionary = copper if not copper.is_empty() else build_copper_index(data)
	var out: Array = []
	for via_id in ids:
		var via: Dictionary = data.get_via(str(via_id))
		if via.is_empty():
			continue
		var entry := via_entry(data, via, index)
		if not want_layer.is_empty() \
				and not (want_layer in (entry["layers_spanned"] as Array)):
			continue
		out.append(entry)
	return out


## ONE via as a report row: its geometry, the layers its barrel SPANS, and the
## layers its copper actually MEETS. Shared verbatim with minerva_pcb_list_vias
## so the two surfaces cannot describe one via differently.
##
## `via_id` is ABSENT (not blank) on a via with no identity — a via restored
## from a board file predating stable via ids genuinely has none, and "absent"
## says that while "" would claim its identity is the empty string. Same claim
## list_vias and export_trace_geometry already make.
static func via_entry(data, via: Dictionary, copper: Dictionary = {}) -> Dictionary:
	var index: Dictionary = copper if not copper.is_empty() else build_copper_index(data)
	var pos: Vector2 = data.via_position(via)
	var spanned := via_span(via, index.get("stack", PackedStringArray()))
	var entry := {
		"x_mm": _mm(pos.x),
		"y_mm": _mm(pos.y),
		"net_name": str(via.get("net_name", "")),
		"from_layer": str(via.get("from_layer", "")),
		"to_layer": str(via.get("to_layer", "")),
		"size_mm": _mm(float(via.get("size", 0.8))),
		"drill_mm": _mm(float(via.get("drill", 0.4))),
		"layers_spanned": spanned,
		"layers_touched": layers_touched(data, via, index),
	}
	var via_id: String = str(via.get("id", ""))
	if not via_id.is_empty():
		entry["via_id"] = via_id
	return entry


# ── layers_touched ───────────────────────────────────────────────────────────

## The copper layers on which this via's barrel actually MEETS other copper.
##
## THE QUESTION IS NOT "which layers does it span" — every through via spans the
## whole stack, so the span says nothing about whether the via joins anything.
## This walks the span one layer at a time and asks the SHARED contact predicate
## (PcbCopperContact.nodes_touch) whether the barrel's disc ON THAT LAYER meets
## any pad land, any trace's swept copper, or any pour's compiled FILL there —
## the same three conductor kinds the connectivity DRC and the ratsnest read,
## through the same builders.
##
## NET-BLIND, deliberately, exactly as the trace-end rule is for pads and vias:
## this reports COPPER CONTACT, not correctness. A via whose bottom side meets
## nothing is reported as touching only its top, and a via meeting a foreign
## net's copper is reported as touching that layer. Judging either — "this via
## is stranded", "this via is a short" — is DRC's job, and a read verb that
## quietly folded a verdict into a fact would take that judgement away from the
## reader who asked for the fact.
static func layers_touched(data, via: Dictionary, copper: Dictionary = {}) -> Array:
	var index: Dictionary = copper if not copper.is_empty() else build_copper_index(data)
	var nodes: Array = index.get("nodes", [])
	var at: Vector2 = data.via_position(via)
	var radius: float = data.via_radius(via)
	var out: Array = []
	for layer in via_span(via, index.get("stack", PackedStringArray())):
		var barrel := PcbCopperContact.via_node(at, radius, [layer])
		for node in nodes:
			if node is Dictionary and PcbCopperContact.nodes_touch(barrel, node):
				out.append(str(layer))
				break
	return out


## The copper layers a via's barrel occupies: its two endpoints plus everything
## between them in the declared stack. Re-exported from PcbCopperContact so a
## caller holding this script does not need a second preload — ONE derivation,
## shared with the ratsnest's own via nodes.
static func via_span(via: Dictionary, stack: PackedStringArray) -> Array:
	return PcbCopperContact.via_span(via, stack)


## EVERY piece of copper on the board, as contact nodes, built ONCE.
##
## Built once per call rather than per via because layers_touched is otherwise
## O(vias x layers x copper) with the copper rebuilt in the innermost loop —
## which is how a whole-board list_vias turns a cheap read into a slow one. The
## vias themselves are NOT in the index: a via meeting only another via tells a
## reader nothing about whether either one reaches a conductor, and a via would
## trivially "touch" itself.
static func build_copper_index(data) -> Dictionary:
	var stack := PcbCopperContact.copper_stack(data)
	var nodes: Array = []
	for comp_id in data.components:
		var comp = data.components[comp_id]
		for pin_name in comp.get_all_pin_positions():
			nodes.append_array(PcbCopperContact.pad_nodes(comp, str(pin_name), stack))
	for trace_id in data.traces:
		var trace = data.traces[trace_id]
		if trace.waypoints.size() < 2:
			continue
		nodes.append(PcbCopperContact.trace_node(
			PackedVector2Array(trace.waypoints), float(trace.width), trace.layer))
	for zone in data.zones:
		if zone is Dictionary:
			nodes.append_array(PcbZoneCopper.region_nodes(zone as Dictionary))
	return {"stack": stack, "nodes": nodes}


# ── ZONES, KEEPOUTS, CUTOUTS ─────────────────────────────────────────────────

## The zones the region touches, split by KIND: `keepout` true reports the
## keepouts, false the copper pours. They are one entity type in the model and
## two different things to a reader — a pour is copper an agent may land on, a
## keepout is copper it may not create — so they are reported apart rather than
## leaving the reader to filter a mixed list.
##
## `fill_region_count` is the pour's COMPILED fill, read through
## PcbZoneCopper.fill_regions: 0 means the pour conducts NOTHING yet (unfilled,
## or a fill this board dropped), which is the difference between "there is
## ground here" and "there is a request for ground here". Keepouts emit no
## copper and carry no fill, so the key is absent on them.
static func zones_in_region(data, region: Rect2, want_layer: String,
		keepout: bool) -> Array:
	var ids: Array = data.get_zones_in_region(region)
	ids.sort()
	var out: Array = []
	for zone_id in ids:
		var zone: Dictionary = data.get_zone(str(zone_id))
		if zone.is_empty():
			continue
		var kind := str(data.zone_kind(zone))
		if (kind == "keepout") != keepout:
			continue
		if not want_layer.is_empty() \
				and PcbCopperContact.canon(zone.get("layer", "")) != want_layer:
			continue
		var pts: PackedVector2Array = data.zone_outline_points(zone)
		var entry := {
			"zone_id": str(zone_id),
			"kind": kind,
			"net": PcbZoneCopper.zone_net(zone),
			"layer": str(zone.get("layer", "")),
			"point_count": pts.size(),
			"outline": data.zone_outline_to_list(pts),
		}
		if not keepout:
			entry["fill_region_count"] = PcbZoneCopper.fill_regions(zone).size()
		out.append(entry)
	return out


## The board cutouts the region touches. A cutout has no layer and no net (see
## the Cutout type in internal/board), so `layer` never filters it: a hole goes
## through everything.
static func cutouts_in_region(data, region: Rect2) -> Array:
	var ids: Array = data.cutouts_in_region(region)
	ids.sort()
	var out: Array = []
	for cutout_id in ids:
		var cutout: Dictionary = data.get_cutout(str(cutout_id))
		if cutout.is_empty():
			continue
		var pts: PackedVector2Array = data.zone_outline_points(cutout)
		out.append({
			"cutout_id": str(cutout_id),
			"point_count": pts.size(),
			"outline": data.zone_outline_to_list(pts),
		})
	return out


# ── NOTES ────────────────────────────────────────────────────────────────────

## The annotations anchored INSIDE the region.
##
## The anchor POINT is the filter, not the annotation's rendered bounds: a
## marker's bounds are a view concept that changes with zoom, while the point it
## was dropped on is board geometry. An annotation whose anchor lies outside is
## absent even if its bubble would overlap the box.
##
## Text is reported when the annotation carries one (core note kinds put it on
## kind_payload.text); a kind with no text contributes its id and kind, which is
## still enough to go and read it.
static func notes_in_region(annotations: Array, region: Rect2) -> Array:
	var out: Array = []
	for raw in annotations:
		if not (raw is Dictionary):
			continue
		var ann: Dictionary = raw
		if not ann.has("anchor"):
			continue
		var at := anchor_point(ann)
		if not region.has_point(at):
			continue
		var payload: Variant = ann.get("kind_payload", {})
		var text := ""
		if payload is Dictionary:
			text = str((payload as Dictionary).get("text", ""))
		out.append({
			"id": str(ann.get("id", "")),
			"kind": str(ann.get("kind", "")),
			"text": text,
			"anchored_to": str(ann.get("anchored_to", "")),
			"position": {"x_mm": _mm(at.x), "y_mm": _mm(at.y)},
		})
	return out


## An annotation's anchor point in BOARD millimetres.
##
## THE one reader of the v2 anchor wire shape this plugin authors (see
## PcbAnnotationHost's header): `anchor.id` is {x, y} for a pcb/board.point,
## and every semantic anchor (pad, component, net, trace) carries {component,
## pin} or an id in `anchor.id` with the board-mm point in
## `anchor.snapshot.position` [x, y] instead. PcbRouteHintKind.anchor_position
## delegates here, so a hint's own anchor and a region read cannot land on two
## different points.
static func anchor_point(annotation: Dictionary) -> Vector2:
	var anchor: Variant = annotation.get("anchor", null)
	if not (anchor is Dictionary):
		return Vector2.ZERO
	var id: Variant = (anchor as Dictionary).get("id", null)
	if id is Dictionary and (id as Dictionary).has("x") and (id as Dictionary).has("y"):
		return Vector2(float((id as Dictionary)["x"]), float((id as Dictionary)["y"]))
	var snap: Variant = (anchor as Dictionary).get("snapshot", null)
	if snap is Dictionary:
		return _to_vec2((snap as Dictionary).get("position", null))
	return Vector2.ZERO


## A stored point in whichever shape reached us: [x, y] is what the wire format
## says, but a Vector2 survives an in-memory hand-off and a {x_mm,y_mm} /
## {x,y} dict survives a JSON round trip. Accepting all three keeps the marker
## on its real point rather than snapping it to the origin — the tolerance
## PcbRouteHintKind._to_vec2 already had before it delegated here.
static func _to_vec2(raw: Variant) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	if raw is Dictionary:
		var d: Dictionary = raw
		if d.has("x_mm") and d.has("y_mm"):
			return Vector2(float(d["x_mm"]), float(d["y_mm"]))
		if d.has("x") and d.has("y"):
			return Vector2(float(d["x"]), float(d["y"]))
		if d.has("position"):
			return _to_vec2(d.get("position", null))
	return Vector2.ZERO


## Board coordinates leave at the same quantum every other pcb reply uses
## (panel_tools._mm), so a region read and a position read never disagree in the
## last digits.
static func _mm(value: float) -> float:
	return snapped(value, 0.0001)
