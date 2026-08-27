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
## Beside that pipeline, and reading the same extract:
##
##   focus(bundles, ref) → the ONE nearest place a trace started on pad `ref`
##                     should be routed to, or {} when there is none
##
## `extract` is O(board); `solve` is O(nodes^2) geometry comparisons per net.
## The canvas caches the solve, keyed on a hash of the extract — the solver's
## complete input.
##
## ── DETERMINISM ──────────────────────────────────────────────────────────────
## The same board draws the same picture in every session. Four places where
## iteration order could leak in, and what each does instead:
##
##   * ENUMERATION. Net names, trace ids, via ids and zone ids are SORTED
##     before use, so nothing depends on Dictionary insertion order or on the
##     order a board file lists its entities in.
##   * UNION-FIND ROOTS. `_union` always keeps the SMALLER node index as the
##     root, so the root of a set is its minimum member rather than an artefact
##     of the order the unions arrived in.
##   * SORTS. Godot's sort_custom is not stable, so every comparator here is a
##     TOTAL order — the float key first, then tie-breaks that never call two
##     distinct elements equal.
##   * TIES. Equal-distance choices (which copper an airwire lands on) resolve
##     by the candidates' own coordinates — see _near_update and _edge_beats —
##     never by which candidate a loop visited first, so reordering a zone's
##     fill regions, or the points within one, cannot change the picture.
##   * WITNESSES. The closest-pair primitive receives every segment with its
##     endpoints in a fixed lexicographic order (_seg_closest), so where the
##     closest approach is a CONTINUUM — parallel overlapping runs — the pair
##     it picks is a function of the segments as point sets, and reversing a
##     trace's waypoints cannot move a witness.
##
## No randomness, no time, no hashing of pointer identities.

const PcbLayerStack := preload("pcb_layer_stack.gd")
const PcbBusLabels := preload("pcb_bus_labels.gd")
## THE CONTACT PREDICATE and the copper-node model it reads. This module
## owns which copper OUGHT to be joined and where the airwires go; whether
## two pieces ARE joined is one question the whole plugin asks, so it is
## asked there. Re-exported below for callers holding this script.
const PcbCopperContact := preload("pcb_copper_contact.gd")
## Zone decoding statics (outline points + kind normalisation) live on the data
## model that defines the zone dict's shape; reached through the script, not an
## instance, exactly as pcb_canvas.gd reaches them.
const PCBDataScript := preload("pcb_data.gd")

## COINCIDENCE TOLERANCE and the geometry-less pin's assumed copper radius —
## the CONTACT module's numbers, aliased so this module's own uses (the fill
## ring's area floor) and the predicate cannot drift apart.
const TOUCH_EPS_MM := PcbCopperContact.TOUCH_EPS_MM
const FALLBACK_PAD_RADIUS_MM := PcbCopperContact.FALLBACK_PAD_RADIUS_MM

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
## A NODE is one connected piece of copper in the uniform shape
## PcbCopperContact defines and its predicate reads. This module adds the fields
## only a ratsnest needs, on PAD nodes:
##   "ref"        String — "<component>.<pin>"
##   "pin_group"  String — equal means internally joined inside the component
##   "land_order" int    — position among the pin's lands after they are ordered
##                         by geometry, so a sort comparing it is a total order
##
## A net with fewer than two logical pins is omitted entirely: extra physical
## lands belonging to one pin do not create a routing obligation.
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
		# A duplicate-number footprint expands one logical pin into several land
		# nodes. It still cannot make a one-pin net need routing by itself.
		var logical_pins := {}
		for pad in pads:
			logical_pins[int((pad as Dictionary)["seq"])] = true
		if logical_pins.size() < 2:
			continue
		bundles.append({
			"net": net_name,
			"color": _net_color(net),
			"pads": pads,
			"pieces": _net_copper(data, net_name, stack),
		})
	return bundles


## The board's declared copper layers, canonicalised, in stack order.
static func _copper_stack(data) -> PackedStringArray:
	return PcbCopperContact.copper_stack(data)


## Canonical copper id for any layer spelling, silently.
static func _canon(layer) -> String:
	return PcbCopperContact.canon(layer)


static func _net_pads(data, net, stack: PackedStringArray) -> Array:
	var pads: Array = []
	for pin_seq in net.pins.size():
		var pin = net.pins[pin_seq]
		var comp_id := str((pin as Dictionary).get("component_id", ""))
		var pin_name := str((pin as Dictionary).get("pin_name", ""))
		var comp = data.get_component(comp_id)
		if comp == null:
			continue
		var ref := "%s.%s" % [comp_id, pin_name]
		var lands := _pad_nodes(comp, pin_name, stack)
		for land_order in lands.size():
			var node: Dictionary = lands[land_order]
			node["ref"] = ref
			node["pin_group"] = ref
			node["seq"] = pin_seq
			node["land_order"] = land_order
			pads.append(node)
	# Total order: the ref, then the pin's position in the net's own list. A
	# board CAN list the same pin twice (load_from_board_dict does not dedupe
	# the way add_pin does), so the ref alone is not a total order and the
	# unstable sort_custom would order the duplicates arbitrarily. Physical
	# lands within one occurrence use their geometry-derived order last.
	pads.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["ref"] != b["ref"]:
			return str(a["ref"]) < str(b["ref"])
		if a["seq"] != b["seq"]:
			return int(a["seq"]) < int(b["seq"])
		return int(a["land_order"]) < int(b["land_order"]))
	return pads


## One logical pin as one node per physical land (see PcbCopperContact).
static func _pad_nodes(comp, pin_name: String, stack: PackedStringArray) -> Array:
	return PcbCopperContact.pad_nodes(comp, pin_name, stack)


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
		pieces.append(PcbCopperContact.trace_node(pts, float(trace.width),
			trace.layer))

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
		pieces.append(PcbCopperContact.via_node(at,
			PCBDataScript.via_radius(via), _via_span(via, stack)))

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
			pieces.append(PcbCopperContact.region_node(region,
				(zone as Dictionary).get("layer", "top")))

	return pieces


## A pour's compiled fill regions, when the zone dict carries them: `fill` is an
## Array of regions, each an Array of {x_mm, y_mm} points — the same point
## encoding as the authored outline, one polygon ring per separately filled
## region. Returns them as PackedVector2Array polygons; empty when the fill is
## absent or legitimately produced no copper.
##
## DAMAGED FILL DATA IS NOT COPPER. Any damage anywhere in the fill — a region
## that is not an Array, a point that is not a finite-numbered {x_mm, y_mm}
## Dictionary, a ring that encloses no area — rejects the ENTIRE fill, intact
## sibling regions included: a fill that is partly wrong is a compile output
## that cannot be trusted, and treating any of it as copper could erase an
## airwire the board still needs. Rejection only ever KEEPS airwires.
static func _zone_fill_regions(zone: Dictionary) -> Array:
	var out: Array = []
	var fill = zone.get("fill")
	if not (fill is Array):
		return out
	for region in fill:
		var pts := _fill_region_ring(region)
		if pts.is_empty():
			return []
		out.append(pts)
	return out


## One fill region decoded into its polygon ring, or empty when the region is
## not usable as copper. Every point must be present, a Dictionary, and carry
## finite numeric x_mm AND y_mm — a damaged point is never repaired with a
## defaulted coordinate and never skipped, because either builds a
## plausible-looking shape out of data that no longer describes one. The ring
## must also enclose real area: a collinear or coincident ring is a line, not
## a region of copper.
##
## The area is judged on the payload's own numbers, BEFORE the reduction to
## Vector2: that reduction rounds each coordinate to the vector type's
## precision, and a shoelace sum over absolute board coordinates carries the
## rounding as cancellation noise that grows with the ring's distance from the
## origin — enough to lift a zero-area ring past the cutoff. The reduced points
## must remain finite too: a finite Float64 coordinate can overflow Vector2 and
## turn a bounded polygon into infinite geometry. See _ring_area_2x for how the
## sum is kept at the ring's own scale.
static func _fill_region_ring(region) -> PackedVector2Array:
	var empty := PackedVector2Array()
	if not (region is Array):
		return empty
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	for p in region:
		if not (p is Dictionary):
			return empty
		var x = (p as Dictionary).get("x_mm")
		var y = (p as Dictionary).get("y_mm")
		if not (_finite_number(x) and _finite_number(y)):
			return empty
		xs.append(float(x))
		ys.append(float(y))
	if xs.size() < 3:
		return empty
	# Less enclosed area than the coincidence tolerance can resolve is no
	# area at all.
	if _ring_area_2x(xs, ys) <= TOUCH_EPS_MM * TOUCH_EPS_MM:
		return empty
	var pts := PackedVector2Array()
	for i in xs.size():
		var point := Vector2(xs[i], ys[i])
		if not (is_finite(point.x) and is_finite(point.y)):
			return empty
		pts.append(point)
	return pts


static func _finite_number(v) -> bool:
	if v is int:
		return true
	return v is float and is_finite(v)


## Twice the area a ring encloses (shoelace), sign dropped. Every coordinate
## is translated to the ring's first point before it enters the sum, so the
## terms — and their float cancellation noise — scale with the ring's own
## extent rather than with where the ring sits on the board: the verdict is
## the same at any offset from the origin.
static func _ring_area_2x(xs: PackedFloat64Array, ys: PackedFloat64Array) -> float:
	var s := 0.0
	var n := xs.size()
	for i in n:
		var j := (i + 1) % n
		var ax := xs[i] - xs[0]
		var ay := ys[i] - ys[0]
		var bx := xs[j] - xs[0]
		var by := ys[j] - ys[0]
		s += ax * by - bx * ay
	return absf(s)


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


# ── TOUCH + MEASURE: re-exports of the shared contact module ─────────────────
#
# One implementation, in PcbCopperContact. These stay so a caller (or a sweep
# below) holding this script does not need a second preload, and so touch and
# aim keep measuring with one instrument.


## THE contact predicate, re-exported so a caller holding this script does not
## need a second preload. One implementation, in PcbCopperContact.
static func nodes_touch(a: Dictionary, b: Dictionary) -> bool:
	return PcbCopperContact.nodes_touch(a, b)


static func _layers_meet(a: Dictionary, b: Dictionary) -> bool:
	return PcbCopperContact.layers_meet(a, b)


static func _seg_count(pts: PackedVector2Array) -> int:
	return PcbCopperContact.seg_count(pts)


static func _seg_end(pts: PackedVector2Array, i: int) -> Vector2:
	return PcbCopperContact.seg_end(pts, i)


## The closest pair between two segments, endpoints handed to the engine in a
## fixed lexicographic order so a witness is a function of the geometry alone.
## Every segment-to-segment measurement here goes through it, so touch and aim
## measure with one instrument.
static func _seg_closest(a1: Vector2, a2: Vector2,
		b1: Vector2, b2: Vector2) -> PackedVector2Array:
	return PcbCopperContact.seg_closest(a1, a2, b1, b2)


## Lexicographic order over one point: x, then y.
static func _point_less(a: Vector2, b: Vector2) -> bool:
	return PcbCopperContact.point_less(a, b)


# ── SOLVE: islands, spanning tree, quieting ───────────────────────────────────

## Turn extracted bundles into what to draw.
##
## Returns:
##   {
##     "links":   Array — one airwire each, in draw order:
##                {net, color, a: Vector2, b: Vector2, a_ref, b_ref,
##                layer_change, length}.
##                a/b are the CLOSEST ROUTE TARGETS of the two islands bridged —
##                a pad centre, a point on a trace centreline, a via, a point of
##                a poured region — so the airwire points where the joining
##                copper would land. a_ref/b_ref name the endpoint's pad
##                ("<component>.<pin>") when the endpoint IS a pad, "" when it
##                is other copper. layer_change is true when the two endpoints'
##                copper shares no layer, so closing the join takes a via — it
##                can be true even at zero length, two ends stacked through the
##                board.
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
				"layer_change": bool(edge["layer_change"]),
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
## (a trace is what joins two pads; a via is what joins two traces), plus every
## pair of physical lands in the same logical pin_group: those are joined
## inside the component without sharing geometry or layers here. Copper carrying
## no pad — a stub trace, an orphan pour region — belongs to no reported island
## and never appears in the answer.
##
## Array[int], NOT PackedInt32Array, for the union-find store: `_union` mutates
## it through a call, and a plain Array is by-reference in GDScript. Packed
## arrays are copy-on-write, so a packed store loses every union.
static func _islands(nodes: Array, pad_count: int) -> Array:
	var parent: Array[int] = []
	for i in nodes.size():
		parent.append(i)
	for i in nodes.size():
		var pin_group := str((nodes[i] as Dictionary).get("pin_group", ""))
		for j in range(i + 1, nodes.size()):
			if _root(parent, i) == _root(parent, j):
				continue
			# Equal-number lands are connected inside the component, but remain
			# separate geometry nodes so one land never borrows another's layers.
			if (not pin_group.is_empty()
					and pin_group == str((nodes[j] as Dictionary).get("pin_group", ""))) \
					or nodes_touch(nodes[i], nodes[j]):
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
	var island_of := _island_of_nodes(nodes.size(), islands)

	# Best (shortest) bridge per island pair. An equal-length challenger is
	# resolved by _edge_beats over the candidates' own coordinates, layer need
	# and refs, so which one represents the pair is a property of the board rather than
	# of the order the node pairs are visited in — node visiting order follows
	# node indices, which follow the order the board's lists arrived in. The
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
			var swap := ia > ib
			var cand := {
				"island_a": mini(ia, ib), "island_b": maxi(ia, ib),
				"a": near["b"] if swap else near["a"],
				"b": near["a"] if swap else near["b"],
				"a_ref": str((nodes[j] if swap else nodes[i])["ref"]),
				"b_ref": str((nodes[i] if swap else nodes[j])["ref"]),
				"layer_change": not _layers_meet(
					nodes[i]["layers"], nodes[j]["layers"]),
				"length": float(near["length"]),
			}
			var key := "%d_%d" % [int(cand["island_a"]), int(cand["island_b"])]
			if best.has(key) and not _edge_beats(cand, best[key]):
				continue
			best[key] = cand

	# Total order without further tie-breaks: `best` holds one candidate per
	# island pair, so (island_a, island_b) alone never compares two distinct
	# elements equal.
	var candidates: Array = best.values()
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["length"] != b["length"]:
			return float(a["length"]) < float(b["length"])
		if a["island_a"] != b["island_a"]:
			return int(a["island_a"]) < int(b["island_a"])
		return int(a["island_b"]) < int(b["island_b"]))

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


## True when `cand` should replace `incumbent` as an island pair's bridge:
## strictly shorter; the same length with lexicographically smaller witness
## points; the same points with no layer change against one needing a layer
## change; then refs. The layer question outranks the refs because the two
## candidates draw the same line at the same coordinates yet ask the designer
## for different work — refs only make the surviving equivalent choice
## deterministic, they never decide it. Every key is read off the candidates
## themselves, never off the order they were generated in. Candidates equal on
## every key draw the same airwire, so the incumbent stays.
static func _edge_beats(cand: Dictionary, incumbent: Dictionary) -> bool:
	if float(cand["length"]) != float(incumbent["length"]):
		return float(cand["length"]) < float(incumbent["length"])
	var ca: Vector2 = cand["a"]
	var cb: Vector2 = cand["b"]
	var na: Vector2 = incumbent["a"]
	var nb: Vector2 = incumbent["b"]
	if ca != na or cb != nb:
		return _points_less(ca, cb, na, nb)
	if bool(cand["layer_change"]) != bool(incumbent["layer_change"]):
		return not bool(cand["layer_change"])
	if str(cand["a_ref"]) != str(incumbent["a_ref"]):
		return str(cand["a_ref"]) < str(incumbent["a_ref"])
	if str(cand["b_ref"]) != str(incumbent["b_ref"]):
		return str(cand["b_ref"]) < str(incumbent["b_ref"])
	return false


## Lexicographic order over a witness point pair: a.x, a.y, b.x, b.y.
static func _points_less(a1: Vector2, b1: Vector2, a2: Vector2, b2: Vector2) -> bool:
	if a1 != a2:
		return _point_less(a1, a2)
	return _point_less(b1, b2)


## For each node index, the island it belongs to, or -1 for copper that belongs
## to no pad-bearing island.
static func _island_of_nodes(node_count: int, islands: Array) -> Array[int]:
	var island_of: Array[int] = []
	island_of.resize(node_count)
	island_of.fill(-1)
	for i in islands.size():
		for n in ((islands[i] as Dictionary)["nodes"] as Array):
			island_of[int(n)] = i
	return island_of


# ── FOCUS: the one destination a trace started on a pad should reach ──────────

## The single nearest place to route `origin_ref` to, or {} when there is none.
##
## Measured FROM THE PAD, not from the pad's whole island: the gesture this
## answers starts at that pad, so the distance reported is the distance the
## designer is about to draw. Every node of every OTHER island on the pad's net
## is a candidate — pads, traces, vias and poured regions alike — so the answer
## lands on the copper a new trace would actually touch, which need not be a pad
## centre. The origin's own island is excluded: copper already joined to the pad
## is not somewhere left to route it.
##
## Independent of quieting. A high-fanout net draws only its shortest few
## airwires, but a pad on it still has a nearest unjoined island, and that is
## what this reports.
##
## Returns:
##   {
##     "net": String, "color": Color,
##     "from_ref": String,        # the pad the gesture started on
##     "to_ref": String,          # the destination pad, "" when the destination
##                                #   copper is a trace, via or pour
##     "to_island_ref": String,   # the destination island's identifying pad —
##                                #   its lowest-sorting one; always present
##     "a": Vector2, "b": Vector2,# route targets: a on the origin pad, b on the
##                                #   destination copper
##     "length": float,           # mm between them
##     "layer_change": bool,      # the two ends share no copper layer
##     "label": String,           # net, destination and distance, for the canvas
##   }
##
## DETERMINISM. Candidates are compared with _edge_beats, the same total order
## the spanning tree uses; candidates equal on every one of its keys draw the
## same airwire, and the first-visited one wins. Visiting order follows node
## index, which the extract has already made a function of the board.
static func focus(bundles: Array, origin_ref: String) -> Dictionary:
	if origin_ref.is_empty():
		return {}
	for bundle in bundles:
		var pads: Array = (bundle as Dictionary)["pads"]
		var origin_lands: Array[int] = []
		for i in pads.size():
			if str((pads[i] as Dictionary)["ref"]) == origin_ref:
				origin_lands.append(i)
		if origin_lands.is_empty():
			continue
		return _focus_in_bundle(bundle as Dictionary, origin_ref, origin_lands)
	return {}


## The focus within the one bundle carrying `origin_ref`. `origin_lands` are that
## pin's land nodes; they are joined to each other by pin_group, so they all sit
## in one island and any of them names it.
static func _focus_in_bundle(bundle: Dictionary, origin_ref: String,
		origin_lands: Array[int]) -> Dictionary:
	var pads: Array = bundle["pads"]
	var nodes: Array = pads.duplicate()
	nodes.append_array(bundle["pieces"])
	var islands := _islands(nodes, pads.size())
	if islands.size() < 2:
		return {}
	var island_of := _island_of_nodes(nodes.size(), islands)
	var home := island_of[origin_lands[0]]
	if home < 0:
		return {}

	var best := {}
	for i in origin_lands:
		for j in nodes.size():
			var ib := island_of[j]
			if ib < 0 or ib == home:
				continue
			var near := _nearest_targets(nodes[i], true, nodes[j], j < pads.size())
			var cand := {
				"island": ib,
				"a": near["a"], "b": near["b"],
				"a_ref": origin_ref,
				"b_ref": str((nodes[j] as Dictionary)["ref"]),
				"layer_change": not _layers_meet(
					nodes[i]["layers"], nodes[j]["layers"]),
				"length": float(near["length"]),
			}
			if best.is_empty() or _edge_beats(cand, best):
				best = cand
	if best.is_empty():
		return {}

	var target_island: Dictionary = islands[int(best["island"])]
	var island_ref := str(
		(pads[int((target_island["pads"] as Array)[0])] as Dictionary)["ref"])
	var to_ref := str(best["b_ref"])
	var net_name := str(bundle["net"])
	var named := to_ref if not to_ref.is_empty() else "%s's copper" % island_ref
	return {
		"net": net_name, "color": bundle["color"],
		"from_ref": origin_ref, "to_ref": to_ref, "to_island_ref": island_ref,
		"a": best["a"], "b": best["b"],
		"length": float(best["length"]),
		"layer_change": bool(best["layer_change"]),
		"label": "%s → %s · %.2f mm" % [net_name, named, float(best["length"])],
	}


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
## Distances can tie — symmetric copper offers the same length from several
## places — and a tie resolves toward the lexicographically smallest witness
## points (see _near_update), so the answer is a function of the geometry
## alone, whatever order the candidates are visited in.
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


## Adopt (pa, pb) when it is nearer than the best so far — or exactly as near
## with lexicographically smaller witness points, so an equal-distance tie is
## decided by the points' own coordinates rather than by which candidate the
## walk reached first.
static func _near_update(best: Dictionary, pa: Vector2, pb: Vector2) -> void:
	var d := pa.distance_to(pb)
	if d > float(best["length"]):
		return
	if d == float(best["length"]) and not _points_less(pa, pb, best["a"], best["b"]):
		return
	best["length"] = d
	best["a"] = pa
	best["b"] = pb


## `swapped` says the FIRST polyline argument belongs to the b-side, so the
## witness points land in the right slots.
static func _near_lines(best: Dictionary, la: PackedVector2Array,
		lb: PackedVector2Array, swapped: bool) -> void:
	for i in _seg_count(la):
		for j in _seg_count(lb):
			var closest := _seg_closest(
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
			var closest := _seg_closest(
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
			var closest := _seg_closest(
				pa[i], pa[(i + 1) % pa.size()], pb[k], pb[(k + 1) % pb.size()])
			if closest.size() == 2:
				_near_update(best, closest[0], closest[1])


## extract + solve. The convenience form; the canvas uses the two halves
## separately so it can cache the expensive one.
static func compute(data) -> Dictionary:
	return solve(extract(data))


static func _net_color(net) -> Color:
	return PcbBusLabels.net_color(net)
