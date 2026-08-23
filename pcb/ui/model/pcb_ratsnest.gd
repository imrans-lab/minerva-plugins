extends RefCounted
## THE RATSNEST: which copper still needs joining, and to what.
##
## Off-tree module — NO class_name, siblings reached by relative preload (see
## pcb_canvas.gd's port note). Every function here is STATIC and pure: data in,
## drawing instructions out. The canvas owns the pixels; this owns the answer.
##
## ── THE MODEL ────────────────────────────────────────────────────────────────
## CONNECTIVITY IS PHYSICAL, NEVER NOMINAL. Two pads count as already joined
## when COPPER ON THE BOARD joins them — a trace, a via, a pour, or another pad
## whose land overlaps — never because they share a net name. Net membership
## says what SHOULD be joined; this module measures what IS, and the airwires
## are the difference. An airwire disappears when copper lands that joins its
## two ends.
##
## The pipeline:
##
##   extract(data)   → per-net bundles of COPPER PIECES with real geometry
##   solve(bundles)  → islands (union-find over touching pieces), then a
##                     minimum spanning tree over the islands' copper, then
##                     quieting
##   compute(data)   = solve(extract(data))
##
## `extract` is O(board); `solve` is O(nodes^2) geometry comparisons per net.
## The canvas caches the solve, keyed on a hash of the extract — the solver's
## complete input.
##
## ── DETERMINISM ──────────────────────────────────────────────────────────────
## The same board draws the same picture in every session. Three places where
## iteration order could leak in, and what each does instead:
##
##   * ENUMERATION. Net names, trace ids, via ids and zone ids are SORTED
##     before use, so nothing depends on Dictionary insertion order or on the
##     order a board file lists its entities in.
##   * UNION-FIND ROOTS. `_union` always keeps the SMALLER node index as the
##     root, so the root of a set is its minimum member rather than an artefact
##     of the order the unions arrived in.
##   * SORTS. Godot's sort_custom is not stable, so every comparator here is a
##     TOTAL order — the float key first, then integer tie-breaks down to the
##     node indices — and never calls two distinct elements equal.
##
## No randomness, no time, no hashing of pointer identities.

const PcbLayerStack := preload("pcb_layer_stack.gd")
## Zone decoding statics (outline points + kind normalisation) live on the data
## model that defines the zone dict's shape; reached through the script, not an
## instance, exactly as pcb_canvas.gd reaches them.
const PCBDataScript := preload("pcb_data.gd")

## COINCIDENCE TOLERANCE, in board mm — how much float noise counts as "the
## same copper". One micron: far below any gap a fabricator could etch and far
## above the rounding error of mm-quantized coordinates.
##
## A tolerance as large as a fabricable gap merges islands that are not joined,
## and the airwire over that gap disappears — the board reads as more finished
## than it is. (PcbAnnotationHost's _PAD_HIT_RADIUS_MM = 1.0mm is a POINTER
## tolerance for a human aiming a mouse; at that size every pad on a
## 0.5mm-pitch part merges.)
const TOUCH_EPS_MM := 0.001

## Copper radius assumed for a pin with NO pad geometry (an unresolved
## footprint — the canvas already badges those components). Traces are drawn
## pad-snapped to the pin centre, so the routed case lands at distance 0 and
## does not depend on this number; it only decides whether copper PASSING NEAR
## a geometry-less pin counts as touching it.
const FALLBACK_PAD_RADIUS_MM := 0.3

## A net needing MORE than this many joins is quieted (see solve()). Signal
## nets need a handful of joins; distribution nets — ground, rails, a bussed
## reference — need one per pad, so a 36-pad ground net needs 35.
const QUIET_ABOVE_LINKS := 8

## How many airwires a quieted net still draws: its SHORTEST joins, which are
## the local hops a designer routes next. The rest are not deleted — they are
## reported as a count and marked in place (see solve()).
const QUIET_SHOWN_LINKS := 6


# ── EXTRACT: the board's copper, per net, as geometry ─────────────────────────

## Every net's pads and copper, as the solver's complete input.
##
## Returns an Array of bundles, one per net with >= 2 pads, ordered by net name:
##   {
##     "net":   String,
##     "color": Color,
##     "pads":  Array[Dictionary],   # nodes, ordered by "<component>.<pin>"
##     "pieces":Array[Dictionary],   # nodes for traces / vias / pours
##   }
##
## A NODE is one connected piece of copper, in ONE uniform shape so a single
## touch predicate serves all four kinds:
##   {
##     "polys":  Array[PackedVector2Array]  # filled areas (rect pad lands,
##                                          #   pour fill regions)
##     "lines":  Array[PackedVector2Array]  # centrelines (trace runs, round/
##                                          #   oval land axes; a via is a
##                                          #   one-point line)
##     "swell":  float                      # half-width around the centreline
##                                          #   (a land's radius / short half-axis)
##     "layers": Dictionary                 # canonical copper layer -> true
##     "bounds": Rect2                      # already grown by swell
##     "ref":    String                     # pads only: "<component>.<pin>"
##     "at":     Vector2                    # pads only: the pad centre
##   }
##
## A net with fewer than two pads is omitted entirely: there is nothing it could
## ever need joined to.
static func extract(data) -> Array:
	var bundles: Array = []
	if data == null:
		return bundles
	var stack := _copper_stack(data)
	var net_names := PackedStringArray()
	for key in data.nets.keys():
		net_names.append(str(key))
	net_names.sort()
	for net_name in net_names:
		var net = data.nets[net_name]
		if net == null:
			continue
		var pads := _net_pads(data, net, stack)
		if pads.size() < 2:
			continue
		bundles.append({
			"net": net_name,
			"color": _net_color(net),
			"pads": pads,
			"pieces": _net_copper(data, net_name, stack),
		})
	return bundles


## The board's declared copper layers, canonicalised, in stack order. Used for
## the two kinds of copper that pierce EVERY layer: a through-hole pad's barrel
## and a through via.
static func _copper_stack(data) -> PackedStringArray:
	var out := PackedStringArray()
	var declared = data.layers if data.layers is Array else []
	for l in declared:
		var canon := _canon(l)
		if not canon.is_empty() and not (canon in out):
			out.append(canon)
	if out.is_empty():
		out.append("top")
		out.append("bottom")
	return out


## Canonical copper id for any layer spelling, SILENTLY. PcbLayerStack's own
## kicad_to_canon push_warning()s on an unrecognised name, which is right for a
## board load and wrong here — this runs over every entity on every extract.
static func _canon(layer) -> String:
	var low := str(layer).strip_edges().to_lower()
	if low.is_empty():
		return ""
	if PcbLayerStack.is_copper(low):
		return PcbLayerStack.kicad_to_canon(low)
	return low


static func _layer_set(layers) -> Dictionary:
	var out := {}
	for l in layers:
		var canon := _canon(l)
		if not canon.is_empty():
			out[canon] = true
	return out


## A net's pads as nodes, ordered by "<component>.<pin>" so the pad INDEX a
## link reports is a property of the board rather than of the pin list's order.
static func _net_pads(data, net, stack: PackedStringArray) -> Array:
	var pads: Array = []
	for pin in net.pins:
		var comp_id := str((pin as Dictionary).get("component_id", ""))
		var pin_name := str((pin as Dictionary).get("pin_name", ""))
		var comp = data.get_component(comp_id)
		if comp == null:
			continue
		var node := _pad_node(comp, pin_name, stack)
		node["ref"] = "%s.%s" % [comp_id, pin_name]
		node["seq"] = pads.size()
		pads.append(node)
	# Total order: the ref, then the pin's position in the net's own list. A
	# board CAN list the same pin twice (load_from_board_dict does not dedupe
	# the way add_pin does), so the ref alone is not a total order and the
	# unstable sort_custom would order the duplicates arbitrarily.
	pads.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["ref"] != b["ref"]:
			return str(a["ref"]) < str(b["ref"])
		return int(a["seq"]) < int(b["seq"]))
	return pads


## One pad as a node: its land where the footprint resolved, a small disc at
## the pin centre when it did not.
##
## THE LAND IS NEVER MODELLED LARGER THAN ITS REAL COPPER. A shape that
## overhangs the land makes copper merely passing nearby read as touching,
## which deletes an airwire that is still required — the one direction this
## module must not err in. Per shape:
##
##   rect      — the oriented quad, exact.
##   circle    — the exact disc: the centre point with the radius as swell.
##   oval      — the exact stadium: the long-axis segment with the short
##               half-axis as swell.
##   roundrect — the maximum-corner-radius roundrect (the inscribed stadium),
##               which every roundrect of the same size contains; the model
##               does not carry the authored corner radius, so the smallest
##               member of the family is the one that cannot overhang.
##   unknown   — as roundrect: the stadium inscribed in the stated size.
##
## ROTATION: a pad has its OWN rotation within the footprint, composed with the
## component's — the pad's offset turns with the component only, the pad's body
## turns with both. Same CW degree convention as the component (see
## pcb_component.get_transform), so a land is measured where it is fabricated.
##
## LAYERS: a through-hole barrel pierces every declared copper layer; an SMD
## pad has copper only where the footprint says (falling back to the side the
## part is mounted on). A pin with NO pad geometry is given the whole stack —
## nothing in the model says which side its copper is on, and its component is
## already badged as unresolved on the canvas.
static func _pad_node(comp, pin_name: String, stack: PackedStringArray) -> Dictionary:
	var centre: Vector2 = comp.get_pin_world_position(pin_name)
	var centre_line := PackedVector2Array([centre])
	var pad := _pad_geometry(comp, pin_name)
	if pad.is_empty():
		return _make_node([], [centre_line],
			FALLBACK_PAD_RADIUS_MM, _layer_set(stack), centre)

	var pad_type := str(pad.get("type", "smd"))
	var layers: Dictionary
	if pad_type in ["thru_hole", "np_thru_hole"]:
		layers = _layer_set(stack)
	else:
		var declared = pad.get("layers", [])
		layers = _layer_set(declared if declared is Array else [])
		if layers.is_empty():
			layers = _layer_set([comp.layer])

	# world(p) = comp.position + comp_xform * (pad_pos + pad_xform * p):
	# the pad's offset goes through the component transform only, the pad's own
	# points through both.
	var comp_xform: Transform2D = comp.get_transform()
	var pad_xform := Transform2D(
		deg_to_rad(-float(pad.get("rotation", 0.0))), Vector2.ZERO)
	var pad_pos: Vector2 = pad.get("position", Vector2.ZERO)
	var half: Vector2 = (pad.get("size", Vector2(1, 1)) as Vector2) * 0.5
	var shape := str(pad.get("shape", "rect")).strip_edges().to_lower()

	if shape == "rect":
		var quad := PackedVector2Array()
		for corner in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
				Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
			quad.append(comp.position + (comp_xform * (pad_pos + (pad_xform * (corner as Vector2)))))
		# The land AND the pin centre. They should coincide, but they are read
		# from two different fields (`pads[].position` vs `pins[]`), and a trace
		# snapped to the pin centre must still be credited if a footprint ever
		# disagrees with itself. Zero swell, so this adds exact coincidence and
		# nothing looser.
		return _make_node([quad], [centre_line], 0.0, layers, centre)

	# Disc or stadium: a segment (a point, for the disc) swollen by the short
	# half-axis. The pin centre is not added as a separate entry here — the
	# node's swell would grow it into a phantom disc anywhere the two fields
	# disagreed, and the land is the copper that exists.
	var radius := minf(half.x, half.y)
	var extent := maxf(half.x, half.y) - radius
	var axis := Vector2(extent, 0.0) if half.x >= half.y else Vector2(0.0, extent)
	var land_line := PackedVector2Array([
		comp.position + (comp_xform * (pad_pos + (pad_xform * -axis))),
		comp.position + (comp_xform * (pad_pos + (pad_xform * axis))),
	])
	return _make_node([], [land_line], radius, layers, centre)


## The pad dict whose number matches `pin_name`, or {} when the footprint gave
## no geometry for it.
static func _pad_geometry(comp, pin_name: String) -> Dictionary:
	if not comp.has_pad_geometry:
		return {}
	for pad in comp.pads:
		if str((pad as Dictionary).get("number", "")) == pin_name:
			return pad
	return {}


## Every piece of NON-PAD copper carrying this net: traces, vias and copper
## pours. Enumerated in sorted-id order so the piece list — and therefore the
## extract hash the canvas caches on — is a function of the board alone.
##
## KEEPOUTS ARE NOT COPPER and are excluded: a keepout is an instruction about
## where copper may not go, not a conductor.
static func _net_copper(data, net_name: String, stack: PackedStringArray) -> Array:
	var pieces: Array = []

	var trace_ids := PackedStringArray()
	for tid in data.traces.keys():
		trace_ids.append(str(tid))
	trace_ids.sort()
	for tid in trace_ids:
		var trace = data.traces[tid]
		if trace == null or str(trace.net_name) != net_name:
			continue
		var pts := PackedVector2Array(trace.waypoints)
		if pts.is_empty():
			continue
		pieces.append(_make_node([], [pts], maxf(float(trace.width), 0.0) * 0.5,
			_layer_set([trace.layer]), Vector2.ZERO))

	# Vias and zones are ARRAYS whose entries need not carry an id (a via loaded
	# from a canonical board gets one only if the file supplied it — see
	# pcb_data._vias_from_board_list), so ordering by id alone would leave every
	# id-less entry mutually "equal" and hand sort_custom a non-total order.
	# The key falls through to geometry, which every entry has.
	var vias := _sorted_by_key(data.vias, func(v: Dictionary) -> String:
		var p: Vector2 = PCBDataScript.via_position(v)
		return "%s|%.6f|%.6f" % [str(v.get("id", "")), p.x, p.y])
	for via in vias:
		if str((via as Dictionary).get("net_name", "")) != net_name:
			continue
		var at: Vector2 = PCBDataScript.via_position(via)
		pieces.append(_make_node([], [PackedVector2Array([at])],
			maxf(PCBDataScript.via_radius(via), 0.0),
			_layer_set(_via_span(via, stack)), Vector2.ZERO))

	var zones := _sorted_by_key(data.zones, func(z: Dictionary) -> String:
		var pts := PCBDataScript.zone_outline_points(z)
		var head := pts[0] if pts.size() > 0 else Vector2.ZERO
		return "%s|%s|%d|%.6f|%.6f" % [str(z.get("id", "")),
			str(z.get("layer", "")), pts.size(), head.x, head.y])
	for zone in zones:
		if PCBDataScript.zone_kind(zone) != "copper_pour":
			continue
		# Zones spell their net "net" (pcb_data.build_zone_payload); "net_name"
		# is accepted as the fallback the other kinds use.
		if str((zone as Dictionary).get("net", (zone as Dictionary).get("net_name", ""))) != net_name:
			continue
		# A pour conducts as its COMPILED FILL, never as its authored outline.
		# Clearance carving and keepouts can cut one outline into several
		# regions that do not conduct to each other, so the outline overstates
		# what is joined. Each filled region is its OWN conductor node; a pour
		# whose fill is absent (or computed empty) contributes no connection at
		# all — an unproven join stays an airwire rather than a silent merge.
		for region in _zone_fill_regions(zone):
			pieces.append(_make_node([region], [], 0.0,
				_layer_set([(zone as Dictionary).get("layer", "top")]), Vector2.ZERO))

	return pieces


## A pour's compiled fill regions, when the zone dict carries them: `fill` is an
## Array of regions, each an Array of {x_mm, y_mm} points — the same point
## encoding as the authored outline, one polygon ring per separately filled
## region. Returns them as PackedVector2Array polygons; empty when the fill is
## absent, malformed, or legitimately produced no copper.
static func _zone_fill_regions(zone: Dictionary) -> Array:
	var out: Array = []
	var fill = zone.get("fill")
	if not (fill is Array):
		return out
	for region in fill:
		if not (region is Array):
			continue
		var pts := PackedVector2Array()
		for p in region:
			if p is Dictionary:
				pts.append(Vector2(
					float((p as Dictionary).get("x_mm", 0.0)),
					float((p as Dictionary).get("y_mm", 0.0))))
		if pts.size() >= 3:
			out.append(pts)
	return out


## A copy of `entries` ordered by a caller-supplied string key, with the key's
## own position in the source array as the last tie-break — so the order is
## TOTAL even if two entries produce the same key.
static func _sorted_by_key(entries, key_of: Callable) -> Array:
	var keyed: Array = []
	if entries is Array:
		for i in (entries as Array).size():
			var entry = (entries as Array)[i]
			if entry is Dictionary:
				keyed.append({"key": str(key_of.call(entry)), "i": i, "entry": entry})
	keyed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["key"] != b["key"]:
			return str(a["key"]) < str(b["key"])
		return int(a["i"]) < int(b["i"]))
	var out: Array = []
	for k in keyed:
		out.append((k as Dictionary)["entry"])
	return out


## The copper layers a via's barrel touches: its two endpoints plus everything
## between them in the declared stack. (Only through spans are modeled — see
## PcbLayerStack.is_legal_via_span — so in practice this is the whole stack; a
## blind/buried span would yield fewer layers.)
static func _via_span(via: Dictionary, stack: PackedStringArray) -> Array:
	var from_layer := _canon(via.get("from_layer", "top"))
	var to_layer := _canon(via.get("to_layer", "bottom"))
	var lo := -1
	var hi := -1
	for i in stack.size():
		if stack[i] == from_layer:
			lo = i
		if stack[i] == to_layer:
			hi = i
	if lo < 0 or hi < 0:
		return [from_layer, to_layer]
	var out: Array = []
	for i in range(mini(lo, hi), maxi(lo, hi) + 1):
		out.append(stack[i])
	return out


static func _make_node(polys: Array, lines: Array, swell: float,
		layers: Dictionary, at: Vector2) -> Dictionary:
	var bounds := Rect2(at, Vector2.ZERO)
	var seeded := false
	for group in [polys, lines]:
		for pts in group:
			for p in (pts as PackedVector2Array):
				if seeded:
					bounds = bounds.expand(p)
				else:
					bounds = Rect2(p, Vector2.ZERO)
					seeded = true
	if not seeded:
		bounds = Rect2(at, Vector2.ZERO)
	# Grown by the swell PLUS the coincidence tolerance, so the bounds test in
	# nodes_touch is strictly more permissive than the geometry test it precedes
	# and never rejects a genuine touch.
	bounds = bounds.grow(swell + TOUCH_EPS_MM)
	return {
		"polys": polys, "lines": lines, "swell": swell,
		"layers": layers, "bounds": bounds, "at": at, "ref": "",
	}


# ── TOUCH: does this copper reach that copper ─────────────────────────────────

## True when two nodes are the same physical conductor: their layer sets
## intersect AND their geometry meets within the pair's tolerance.
##
## The bounds test runs first: it keeps the O(nodes^2) sweep in solve() from
## becoming O(segments^2) across a whole board.
static func nodes_touch(a: Dictionary, b: Dictionary) -> bool:
	if not (a["bounds"] as Rect2).intersects(b["bounds"] as Rect2, true):
		return false
	if not _layers_meet(a["layers"], b["layers"]):
		return false
	var tol: float = float(a["swell"]) + float(b["swell"]) + TOUCH_EPS_MM
	for la in (a["lines"] as Array):
		for lb in (b["lines"] as Array):
			if _lines_meet(la, lb, tol):
				return true
	for la in (a["lines"] as Array):
		for pb in (b["polys"] as Array):
			if _line_meets_polygon(la, pb, tol):
				return true
	for lb in (b["lines"] as Array):
		for pa in (a["polys"] as Array):
			if _line_meets_polygon(lb, pa, tol):
				return true
	for pa in (a["polys"] as Array):
		for pb in (b["polys"] as Array):
			if _polygons_meet(pa, pb, tol):
				return true
	return false


static func _layers_meet(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return true   # unknown side: do not invent a separation
	for k in a:
		if b.has(k):
			return true
	return false


## Segment count for a point list, treating a lone point (a via, a
## geometry-less pin) as one degenerate segment so every caller has segments.
static func _seg_count(pts: PackedVector2Array) -> int:
	if pts.is_empty():
		return 0
	return maxi(1, pts.size() - 1)


static func _seg_end(pts: PackedVector2Array, i: int) -> Vector2:
	return pts[i + 1] if i + 1 < pts.size() else pts[i]


static func _lines_meet(a: PackedVector2Array, b: PackedVector2Array, tol: float) -> bool:
	for i in _seg_count(a):
		for j in _seg_count(b):
			var closest := Geometry2D.get_closest_points_between_segments(
				a[i], _seg_end(a, i), b[j], _seg_end(b, j))
			if closest.size() == 2 and closest[0].distance_to(closest[1]) <= tol:
				return true
	return false


static func _line_meets_polygon(line: PackedVector2Array, poly: PackedVector2Array,
		tol: float) -> bool:
	if poly.size() < 3:
		return false
	for p in line:
		if Geometry2D.is_point_in_polygon(p, poly):
			return true
	for i in _seg_count(line):
		for k in poly.size():
			var closest := Geometry2D.get_closest_points_between_segments(
				line[i], _seg_end(line, i), poly[k], poly[(k + 1) % poly.size()])
			if closest.size() == 2 and closest[0].distance_to(closest[1]) <= tol:
				return true
	return false


static func _polygons_meet(a: PackedVector2Array, b: PackedVector2Array, tol: float) -> bool:
	if a.size() < 3 or b.size() < 3:
		return false
	for p in a:
		if Geometry2D.is_point_in_polygon(p, b):
			return true
	for p in b:
		if Geometry2D.is_point_in_polygon(p, a):
			return true
	for i in a.size():
		for k in b.size():
			var closest := Geometry2D.get_closest_points_between_segments(
				a[i], a[(i + 1) % a.size()], b[k], b[(k + 1) % b.size()])
			if closest.size() == 2 and closest[0].distance_to(closest[1]) <= tol:
				return true
	return false


# ── SOLVE: islands, spanning tree, quieting ───────────────────────────────────

## Turn extracted bundles into what to draw.
##
## Returns:
##   {
##     "links":   Array — one airwire each, in draw order:
##                {net, color, a: Vector2, b: Vector2, a_ref, b_ref, length}.
##                a/b are the CLOSEST ROUTE TARGETS of the two islands bridged —
##                a pad centre, a point on a trace centreline, a via, a point of
##                a poured region — so the airwire points where the joining
##                copper would land. a_ref/b_ref name the endpoint's pad
##                ("<component>.<pin>") when the endpoint IS a pad, "" when it
##                is other copper.
##     "markers": Array — {net, color, at: Vector2, ref} for each island of a
##                QUIETED net that no drawn link reaches: "there is still
##                unjoined copper here", without a line to reach it
##     "nets":    Array — one row per net that still needs joining, by name:
##                {net, color, islands, remaining, shown, quieted}
##     "quieted": Array — the subset of "nets" with quieted == true, for the
##                on-canvas legend
##     "remaining_total": int — joins still needed across the whole board
##   }
##
## "remaining" is islands - 1: the number of separate pieces of copper on the
## net, less one, is exactly how many joins it still takes to make the net
## whole. It is reported for a quieted net whether or not that net's links are
## drawn, so it does not move when quieting does.
static func solve(bundles: Array) -> Dictionary:
	var out := {
		"links": [], "markers": [], "nets": [], "quieted": [], "remaining_total": 0,
	}
	for bundle in bundles:
		var pads: Array = (bundle as Dictionary)["pads"]
		var nodes: Array = pads.duplicate()
		nodes.append_array((bundle as Dictionary)["pieces"])
		var islands := _islands(nodes, pads.size())
		if islands.size() < 2:
			continue   # one island = the net's copper is already whole

		var edges := _spanning_edges(nodes, pads.size(), islands)
		var remaining := edges.size()
		var quieted := remaining > QUIET_ABOVE_LINKS
		# Clamped: the two thresholds are independent, and drawing more links
		# than the tree has would index past its end.
		var shown := mini(QUIET_SHOWN_LINKS, remaining) if quieted else remaining

		var net_name: String = (bundle as Dictionary)["net"]
		var color: Color = (bundle as Dictionary)["color"]
		var reached := {}
		for e in range(shown):
			var edge: Dictionary = edges[e]
			reached[int(edge["island_a"])] = true
			reached[int(edge["island_b"])] = true
			out["links"].append({
				"net": net_name, "color": color,
				"a": edge["a"], "b": edge["b"],
				"a_ref": edge["a_ref"], "b_ref": edge["b_ref"],
				"length": float(edge["length"]),
			})
		if quieted:
			for i in islands.size():
				if reached.has(i):
					continue
				var rep: Dictionary = pads[int(((islands[i] as Dictionary)["pads"] as Array)[0])]
				out["markers"].append({
					"net": net_name, "color": color,
					"at": rep["at"], "ref": rep["ref"],
				})

		var row := {
			"net": net_name, "color": color, "islands": islands.size(),
			"remaining": remaining, "shown": shown, "quieted": quieted,
		}
		out["nets"].append(row)
		if quieted:
			out["quieted"].append(row)
		out["remaining_total"] = int(out["remaining_total"]) + remaining
	return out


## Group a net's copper into ISLANDS — maximal sets of nodes joined by copper —
## keeping only the islands that contain at least one pad. `nodes` is the pads
## followed by the pieces; `pad_count` says where the boundary is.
##
## Returns Array of {"pads": Array[int], "nodes": Array[int]} — pad indices and
## node indices, each ascending — ordered by each island's smallest pad. The
## nodes are what an airwire aims at (a trace mid-run can be the closest copper
## of its island); the pads are the island's addressable identity.
##
## The sweep unions every touching pair over pads AND copper pieces together
## (a trace is what joins two pads; a via is what joins two traces). Copper
## carrying no pad — a stub trace, an orphan pour region — belongs to no
## reported island and never appears in the answer.
##
## Array[int], NOT PackedInt32Array, for the union-find store: `_union` mutates
## it through a call, and a plain Array is by-reference in GDScript. Packed
## arrays are copy-on-write, so a packed store loses every union.
static func _islands(nodes: Array, pad_count: int) -> Array:
	var parent: Array[int] = []
	for i in nodes.size():
		parent.append(i)
	for i in nodes.size():
		for j in range(i + 1, nodes.size()):
			if _root(parent, i) == _root(parent, j):
				continue
			if nodes_touch(nodes[i], nodes[j]):
				_union(parent, i, j)

	var by_root := {}
	var islands: Array = []
	for p in pad_count:
		var r := _root(parent, p)
		if not by_root.has(r):
			by_root[r] = islands.size()
			islands.append({"pads": [], "nodes": []})
		((islands[int(by_root[r])] as Dictionary)["pads"] as Array).append(p)
	for n in nodes.size():
		var r := _root(parent, n)
		if by_root.has(r):
			((islands[int(by_root[r])] as Dictionary)["nodes"] as Array).append(n)
	return islands


## Find with path compression.
static func _root(parent: Array[int], i: int) -> int:
	var r := i
	while parent[r] != r:
		r = parent[r]
	var walk := i
	while parent[walk] != r:
		var next := parent[walk]
		parent[walk] = r
		walk = next
	return r


## Union with the SMALLER INDEX AS ROOT — see the determinism note at the top.
## Island ordering is read from root identity, so the root has to be a property
## of the set (its minimum member) rather than of union order.
static func _union(parent: Array[int], a: int, b: int) -> void:
	var ra := _root(parent, a)
	var rb := _root(parent, b)
	if ra == rb:
		return
	if ra < rb:
		parent[rb] = ra
	else:
		parent[ra] = rb


## A minimum spanning tree over the islands: exactly islands-1 edges, each
## carrying the CLOSEST pair of route targets that bridges the two islands it
## joins — measured over the islands' COPPER, not over their pad centres, so a
## pad one millimetre from a routed trace bridges to the trace, not to a pad
## fifty millimetres down the same island.
##
## Returned SORTED SHORTEST-FIRST: a quieted net draws the head of this list,
## its most local hops.
##
## Kruskal over one best edge per island pair.
static func _spanning_edges(nodes: Array, pad_count: int, islands: Array) -> Array:
	var island_of: Array[int] = []
	island_of.resize(nodes.size())
	island_of.fill(-1)
	for i in islands.size():
		for n in ((islands[i] as Dictionary)["nodes"] as Array):
			island_of[int(n)] = i

	# Best (shortest) bridge per island pair. Nodes are walked in ascending
	# index order and the comparison is STRICTLY less-than, so a tie keeps the
	# lexicographically smallest node pair without a second tie-break. The
	# edge's a-side always belongs to the LOWER-numbered island.
	var best := {}
	for i in nodes.size():
		if island_of[i] < 0:
			continue   # copper in no pad-bearing island: nothing bridges to it
		for j in range(i + 1, nodes.size()):
			var ia := island_of[i]
			var ib := island_of[j]
			if ib < 0 or ia == ib:
				continue
			var near := _nearest_targets(
				nodes[i], i < pad_count, nodes[j], j < pad_count)
			var key := "%d_%d" % [mini(ia, ib), maxi(ia, ib)]
			if best.has(key) and float((best[key] as Dictionary)["length"]) <= float(near["length"]):
				continue
			var swap := ia > ib
			best[key] = {
				"island_a": mini(ia, ib), "island_b": maxi(ia, ib),
				"node_a": j if swap else i, "node_b": i if swap else j,
				"a": near["b"] if swap else near["a"],
				"b": near["a"] if swap else near["b"],
				"a_ref": str((nodes[j] if swap else nodes[i])["ref"]),
				"b_ref": str((nodes[i] if swap else nodes[j])["ref"]),
				"length": float(near["length"]),
			}

	var candidates: Array = best.values()
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["length"] != b["length"]:
			return float(a["length"]) < float(b["length"])
		if a["island_a"] != b["island_a"]:
			return int(a["island_a"]) < int(b["island_a"])
		if a["island_b"] != b["island_b"]:
			return int(a["island_b"]) < int(b["island_b"])
		if a["node_a"] != b["node_a"]:
			return int(a["node_a"]) < int(b["node_a"])
		return int(a["node_b"]) < int(b["node_b"]))

	var parent: Array[int] = []
	for i in islands.size():
		parent.append(i)
	var edges: Array = []
	for cand in candidates:
		var ia := int((cand as Dictionary)["island_a"])
		var ib := int((cand as Dictionary)["island_b"])
		if _root(parent, ia) == _root(parent, ib):
			continue
		_union(parent, ia, ib)
		edges.append(cand)
		if edges.size() >= islands.size() - 1:
			break
	return edges


# ── AIM: where an airwire between two conductors lands ────────────────────────

## The closest pair of ROUTE TARGETS between two nodes, as
## {a: Vector2, b: Vector2, length: float} with `a` on the first node.
##
## A route target is where joining copper would land, per node kind:
##   pad          — its centre (routes terminate on the pad centre)
##   trace / via  — anywhere on the centreline
##   pour region  — anywhere in the region
##
## The swell is deliberately NOT subtracted: the target is the centreline a new
## trace would be drawn to, not the copper surface. Layers are deliberately not
## consulted: the islands were separated by real connectivity already, and the
## closest in-plane copper is where a designer lands a trace or drops a via.
##
## Every comparison is strictly less-than over a deterministic walk, so ties
## keep the first candidate and the answer is a function of the input alone.
static func _nearest_targets(a: Dictionary, a_pad: bool,
		b: Dictionary, b_pad: bool) -> Dictionary:
	var best := {"a": a["at"], "b": b["at"], "length": INF}
	var a_lines := _target_lines(a, a_pad)
	var b_lines := _target_lines(b, b_pad)
	var a_polys: Array = [] if a_pad else (a["polys"] as Array)
	var b_polys: Array = [] if b_pad else (b["polys"] as Array)
	for la in a_lines:
		for lb in b_lines:
			_near_lines(best, la, lb, false)
		for pb in b_polys:
			_near_line_poly(best, la, pb, false)
	for lb in b_lines:
		for pa in a_polys:
			_near_line_poly(best, lb, pa, true)
	for pa in a_polys:
		for pb in b_polys:
			_near_polys(best, pa, pb)
	return best


## A node's route-target centrelines. A pad aims at its single centre point,
## whatever the extent of its land — its full geometry stays in play for the
## TOUCH question, which is about copper, not about where to route.
static func _target_lines(node: Dictionary, is_pad: bool) -> Array:
	if is_pad:
		return [PackedVector2Array([node["at"]])]
	return node["lines"]


static func _near_update(best: Dictionary, pa: Vector2, pb: Vector2) -> void:
	var d := pa.distance_to(pb)
	if d < float(best["length"]):
		best["length"] = d
		best["a"] = pa
		best["b"] = pb


## `swapped` says the FIRST polyline argument belongs to the b-side, so the
## witness points land in the right slots.
static func _near_lines(best: Dictionary, la: PackedVector2Array,
		lb: PackedVector2Array, swapped: bool) -> void:
	for i in _seg_count(la):
		for j in _seg_count(lb):
			var closest := Geometry2D.get_closest_points_between_segments(
				la[i], _seg_end(la, i), lb[j], _seg_end(lb, j))
			if closest.size() == 2:
				if swapped:
					_near_update(best, closest[1], closest[0])
				else:
					_near_update(best, closest[0], closest[1])


static func _near_line_poly(best: Dictionary, line: PackedVector2Array,
		poly: PackedVector2Array, swapped: bool) -> void:
	if poly.size() < 3:
		return
	for p in line:
		if Geometry2D.is_point_in_polygon(p, poly):
			_near_update(best, p, p)
	for i in _seg_count(line):
		for k in poly.size():
			var closest := Geometry2D.get_closest_points_between_segments(
				line[i], _seg_end(line, i), poly[k], poly[(k + 1) % poly.size()])
			if closest.size() == 2:
				if swapped:
					_near_update(best, closest[1], closest[0])
				else:
					_near_update(best, closest[0], closest[1])


static func _near_polys(best: Dictionary, pa: PackedVector2Array,
		pb: PackedVector2Array) -> void:
	if pa.size() < 3 or pb.size() < 3:
		return
	for p in pa:
		if Geometry2D.is_point_in_polygon(p, pb):
			_near_update(best, p, p)
	for p in pb:
		if Geometry2D.is_point_in_polygon(p, pa):
			_near_update(best, p, p)
	for i in pa.size():
		for k in pb.size():
			var closest := Geometry2D.get_closest_points_between_segments(
				pa[i], pa[(i + 1) % pa.size()], pb[k], pb[(k + 1) % pb.size()])
			if closest.size() == 2:
				_near_update(best, closest[0], closest[1])


## extract + solve. The convenience form; the canvas uses the two halves
## separately so it can cache the expensive one.
static func compute(data) -> Dictionary:
	return solve(extract(data))


static func _net_color(net) -> Color:
	var c = net.color
	return c if c is Color else Color.WHITE
