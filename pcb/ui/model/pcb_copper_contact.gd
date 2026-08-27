extends RefCounted
## ONE predicate: does this piece of copper JOIN that piece of copper?
##
## Off-tree module — NO class_name, siblings reached by relative preload (see
## pcb_canvas.gd's port note). Every function here is STATIC and pure.
##
## "Is this trace end landed on the pad", "is this run driven across the pad",
## "is this end still free to draw from", "are these two pads already joined" —
## one question, asked four ways. It is answered HERE, once, so the panel's
## verbs, the pin inspector and the ratsnest cannot give three answers about one
## board. The worker's connectivity DRC answers it too, in
## worker/pcb_worker/copper_contact.py, and the vectors under pcb/spec/contact
## are what proves the two agree.
##
## ── THE MODEL ────────────────────────────────────────────────────────────────
## A NODE is one connected piece of copper, in ONE uniform shape so a single
## touch predicate serves every kind:
##
##   {
##     "polys":  Array[PackedVector2Array]  # filled areas (rect lands, pour
##                                          #   fill regions)
##     "lines":  Array[PackedVector2Array]  # centrelines (trace runs, round /
##                                          #   oval land axes; a via or a
##                                          #   trace END is a one-point line)
##     "swell":  float                      # half-width around the centreline
##                                          #   (a land's radius, a trace's
##                                          #   half-width)
##     "layers": Dictionary                 # canonical copper layer -> true;
##                                          #   EMPTY means unknown, which meets
##                                          #   everything
##     "bounds": Rect2                      # already grown by swell
##     "at":     Vector2                    # a representative point
##   }
##
## Nothing else about the copper survives into the predicate. A pad, a trace, a
## via and a poured region differ only in which BUILDER made the node — so
## adding a conductor kind is a new builder, never a second predicate.
##
## ── DIRECTION OF ERROR ───────────────────────────────────────────────────────
## THE LAND IS NEVER MODELLED LARGER THAN ITS REAL COPPER. A shape that
## overhangs makes copper merely passing nearby read as touching, which deletes
## a join obligation the board still has — the one direction this must not err
## in. (Contrast pcb_component._land_distance, a POINTER measurement that errs
## LARGE on purpose so a click on real copper resolves to it.)

const PcbLayerStack := preload("pcb_layer_stack.gd")

## COINCIDENCE TOLERANCE, in board mm — how much float noise counts as "the
## same copper". One micron: far below any gap a fabricator could etch and far
## above the rounding error of mm-quantized coordinates.
##
## A tolerance as large as a fabricable gap merges copper that is not joined,
## and the join obligation over that gap disappears — the board reads as more
## finished than it is. Equals copper_contact.TOUCH_EPS_MM on the worker side.
const TOUCH_EPS_MM := 0.001

## Copper radius assumed for a pin with NO pad geometry (an unresolved
## footprint — the canvas already badges those components) when no board is in
## hand to ask. Traces are drawn pad-snapped to the pin centre, so the routed
## case lands at distance 0 and does not depend on this number; it only decides
## whether copper PASSING NEAR a geometry-less pin counts as touching it.
##
## THE BOARD'S OWN CLEARANCE IS THE RULE — see unknown_land_radius below. This
## constant is only the answer when the board declares none, and it equals
## drc.DEFAULT_COINCIDENT_MM on the worker side, which runs the same derivation
## (drc._board_clearance feeding copper_contact.pad_node's
## unknown_land_radius_mm). Two different numbers meant a geometry-less pin
## probed 0.25 mm off centre was joined on one side of the boundary and clear on
## the other.
const DEFAULT_UNKNOWN_LAND_RADIUS_MM := 0.2


## The assumed copper radius for a geometry-less pin ON THIS BOARD: its declared
## `design_rules.clearance_mm`, else DEFAULT_UNKNOWN_LAND_RADIUS_MM. Duck-typed
## on `design_rules`, so a null/rule-less board answers with the default — the
## same answer a headless caller gets.
static func unknown_land_radius(data) -> float:
	if data == null or not is_instance_valid(data) or not ("design_rules" in data):
		return DEFAULT_UNKNOWN_LAND_RADIUS_MM
	var rules = data.design_rules
	if not (rules is Dictionary):
		return DEFAULT_UNKNOWN_LAND_RADIUS_MM
	var clearance := float((rules as Dictionary).get("clearance_mm", 0.0))
	return clearance if clearance > 0.0 else DEFAULT_UNKNOWN_LAND_RADIUS_MM


# ── NODES ─────────────────────────────────────────────────────────────────────

## Assemble one node. `bounds` is grown by the swell PLUS the coincidence
## tolerance, so the bounds test in nodes_touch is strictly more permissive than
## the geometry test it precedes and never rejects a genuine touch.
static func make_node(polys: Array, lines: Array, swell: float,
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
	bounds = bounds.grow(swell + TOUCH_EPS_MM)
	return {
		"polys": polys, "lines": lines, "swell": swell,
		"layers": layers, "bounds": bounds, "at": at, "ref": "",
		"pin_group": "",
	}


## A trace run as its SWEPT COPPER: the centreline polyline swollen by half the
## trace width. The centreline alone cannot answer whether a run covers a land.
static func trace_node(points: PackedVector2Array, width_mm: float,
		layer) -> Dictionary:
	return make_node([], [points], maxf(width_mm, 0.0) * 0.5,
		layer_set([layer]), points[0] if points.size() > 0 else Vector2.ZERO)


## The copper at ONE end of a run: the round cap of its swept width.
##
## Distinct from trace_node on purpose. "Is this END landed?" must not be
## answered by copper at the OTHER end of the same run, which is exactly what
## measuring the whole polyline would do.
static func endpoint_node(at: Vector2, width_mm: float, layer) -> Dictionary:
	return make_node([], [PackedVector2Array([at])], maxf(width_mm, 0.0) * 0.5,
		layer_set([layer]), at)


## A via's barrel as a disc on every layer its span reaches.
static func via_node(at: Vector2, radius_mm: float, layers: Array) -> Dictionary:
	return make_node([], [PackedVector2Array([at])], maxf(radius_mm, 0.0),
		layer_set(layers), at)


## One filled pour region as a conductor. The polygon is the compiled FILL, never
## the authored outline — clearance carving cuts one outline into regions that do
## not conduct to each other.
static func region_node(region: PackedVector2Array, layer) -> Dictionary:
	return make_node([region], [], 0.0, layer_set([layer]),
		region[0] if region.size() > 0 else Vector2.ZERO)


## A land that is NOT copper, and so joins nothing.
##
## An UNPLATED through-hole is the case: a drilled mechanical hole. Its footprint
## pad still declares copper layers (KiCad writes *.Cu on an np_thru_hole line),
## and CAM plates nothing there — so a node built from those layers would bridge
## the whole stack through a hole with no barrel, which is the one error
## direction that deletes a real open.
##
## It is a NODE rather than a dropped pad because the pin still EXISTS: a board
## may name it on a net, and the honest report is "this pin's copper reaches
## nothing", not "this pin is absent". EMPTY GEOMETRY is what makes it join
## nothing — nodes_touch compares polys and lines, and a node with neither can
## match no pair — and the empty layer set is deliberately NOT relied on, since
## an empty layer set reads as UNKNOWN and meets everything.
static func no_copper_node(at: Vector2) -> Dictionary:
	return make_node([], [], 0.0, {}, at)


## True when a node models actual copper.
##
## A no_copper_node — an unplated hole's land — carries neither polys nor lines.
## It touches nothing (the predicate has nothing to compare), and it is nowhere
## an airwire can land either: its layer set is EMPTY, which reads as UNKNOWN
## and so "meets" every other layer. Anything that reports about where copper
## joins must skip it, or a hole with no barrel will answer a question only
## copper can answer.
static func node_has_copper(node: Dictionary) -> bool:
	return not (node.get("polys", []) as Array).is_empty() \
		or not (node.get("lines", []) as Array).is_empty()


## One logical pin as one node per physical land where the footprint resolved,
## or one small disc at the pin centre when it did not.
##
## `stack` is the board's declared copper layers, for the kinds of copper that
## pierce every layer. `unknown_land_radius_mm` is the disc a geometry-less pin
## gets — pass unknown_land_radius(data) wherever a board is in hand, so the
## panel and the worker read one number.
static func pad_nodes(comp, pin_name: String, stack: PackedStringArray,
		unknown_land_radius_mm: float = DEFAULT_UNKNOWN_LAND_RADIUS_MM) -> Array:
	var centre: Vector2 = comp.get_pin_world_position(pin_name)
	var centre_line := PackedVector2Array([centre])
	var matches: Array = []
	if comp.has_pad_geometry:
		for source_order in comp.pads.size():
			var pad = comp.pads[source_order]
			if str((pad as Dictionary).get("number", "")) == pin_name:
				matches.append({"pad": pad, "source_order": source_order,
					"key": pad_geometry_key(pad as Dictionary)})
	if matches.is_empty():
		return [make_node([], [centre_line],
			unknown_land_radius_mm, layer_set(stack), centre)]
	# The source list is not an electrical ordering. Geometry first makes a
	# reversed-but-identical footprint produce the same node and island order;
	# source_order only distinguishes physically identical records.
	matches.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["key"] != b["key"]:
			return str(a["key"]) < str(b["key"])
		return int(a["source_order"]) < int(b["source_order"]))
	var out: Array = []
	for match in matches:
		out.append(physical_pad_node(comp, (match as Dictionary)["pad"], stack,
			centre, matches.size() == 1))
	return out


## A stable description of every property that changes a physical land. Used
## only to ORDER equal-number lands; it never decides connectivity.
static func pad_geometry_key(pad: Dictionary) -> String:
	var pos: Vector2 = pad.get("position", Vector2.ZERO)
	var size: Vector2 = pad.get("size", Vector2(1, 1))
	var layer_names := PackedStringArray()
	var declared = pad.get("layers", [])
	if declared is Array:
		for layer in declared:
			layer_names.append(canon(layer))
	layer_names.sort()
	return "%s|%s|%s|%s|%s|%s|%s|%s|%s" % [
		str(pos.x), str(pos.y), str(pad.get("type", "smd")),
		str(pad.get("shape", "rect")), str(size.x), str(size.y),
		str(pad.get("rotation", 0.0)), str(pad.get("corner_rratio", null)),
		",".join(layer_names)]


## One physical land as one uniform-layer node. `logical_centre` is retained
## only for the legacy single-land rect safeguard; combining it with any one
## of several lands would assign that point the wrong sibling's layers.
##
## SHAPES, each modelled as its exact copper or as a shape INSCRIBED in it:
##   rect      — the oriented quad, exact.
##   circle    — the exact disc: the centre point with the radius as swell.
##   oval      — the exact stadium: the long-axis segment with the short
##               half-axis as swell.
##   roundrect — exact, when the pad carries its corner radius: the rectangle
##               shrunk by that radius on each side, swollen by the radius —
##               the roundrect's own Minkowski decomposition. Without a stated
##               radius it falls back to the maximum-corner-radius member (the
##               inscribed stadium), which every roundrect of the same size
##               contains and so cannot overhang.
##   unknown   — as a radius-less roundrect: the stadium inscribed in the
##               stated size.
##
## ROTATION: a pad has its OWN rotation within the footprint, composed with the
## component's — the pad's offset turns with the component only, the pad's body
## turns with both. Same CW degree convention as the component (see
## pcb_component.get_transform), so a land is measured where it is fabricated.
##
## LAYERS: a PLATED through-hole barrel pierces every declared copper layer; an
## SMD pad has copper only where the footprint says (falling back to the side the
## part is mounted on). A pin with NO pad geometry is given the whole stack —
## nothing in the model says which side its copper is on, and its component is
## already badged as unresolved on the canvas. An UNPLATED hole gets no copper at
## all (see no_copper_node) — the same reading CAM and the bus tool already take.
static func physical_pad_node(comp, pad: Dictionary, stack: PackedStringArray,
		logical_centre: Vector2, only_land: bool) -> Dictionary:

	var pad_type := str(pad.get("type", "smd"))
	if pad_type == "np_thru_hole":
		return no_copper_node(comp.position + (comp.get_transform()
			* (pad.get("position", Vector2.ZERO) as Vector2)))
	var layers: Dictionary
	if pad_type == "thru_hole":
		layers = layer_set(stack)
	else:
		var declared = pad.get("layers", [])
		layers = layer_set(declared if declared is Array else [])
		if layers.is_empty():
			layers = layer_set([comp.layer])

	# world(p) = comp.position + comp_xform * (pad_pos + pad_xform * p):
	# the pad's offset goes through the component transform only, the pad's own
	# points through both.
	var comp_xform: Transform2D = comp.get_transform()
	var pad_xform := Transform2D(
		deg_to_rad(-float(pad.get("rotation", 0.0))), Vector2.ZERO)
	var pad_pos: Vector2 = pad.get("position", Vector2.ZERO)
	var half: Vector2 = (pad.get("size", Vector2(1, 1)) as Vector2) * 0.5
	var shape := str(pad.get("shape", "rect")).strip_edges().to_lower()
	# An AUTHORED zero corner radius is a SHARP rectangle, and the distinction
	# between "no ratio stated" and "ratio 0.0" is one the compiler preserves —
	# so read it here too rather than lumping both into the family fallback.
	var corner_mm := corner_radius_mm(pad, half)
	var authored_ratio = pad.get("corner_rratio", null)
	var states_ratio: bool = authored_ratio is float or authored_ratio is int
	if shape == "roundrect" and corner_mm <= 0.0 and states_ratio:
		shape = "rect"
	var land_centre: Vector2 = comp.position + (comp_xform * pad_pos)
	var route_at := logical_centre if only_land else land_centre

	if shape == "rect":
		var quad := PackedVector2Array()
		for corner in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
				Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
			quad.append(comp.position + (comp_xform * (pad_pos + (pad_xform * (corner as Vector2)))))
		# For a sole land, keep the land AND the pin centre. They should coincide,
		# but they are read from two different fields (`pads[].position` vs
		# `pins[]`), and a trace snapped to the pin centre must still be credited
		# if a footprint ever disagrees with itself. Zero swell, so this adds exact
		# coincidence and nothing looser. With duplicate lands every real centre
		# is already represented by its own node and its own layer set.
		var extra_lines: Array = []
		if only_land:
			extra_lines.append(PackedVector2Array([logical_centre]))
		return make_node([quad], extra_lines, 0.0, layers, route_at)

	# An AUTHORED roundrect is modelled exactly: the corner radius is a fraction
	# of the short side, and the land is the rectangle shrunk by that radius on
	# every side, swollen back by it. Under-modelling it as the inscribed
	# stadium (what a pad with no stated radius still gets, below) drops the
	# four corner regions, and copper landing in a corner then reads as not
	# touching. Only strictly BETWEEN the degenerate ends: a zero radius is the
	# rect above and a maximal one is the stadium below, both already exact.
	if shape == "roundrect" and corner_mm > 0.0 and corner_mm < minf(half.x, half.y):
		var inner := half - Vector2(corner_mm, corner_mm)
		var core := PackedVector2Array()
		for corner_pt in [Vector2(-inner.x, -inner.y), Vector2(inner.x, -inner.y),
				Vector2(inner.x, inner.y), Vector2(-inner.x, inner.y)]:
			core.append(comp.position + (comp_xform * (pad_pos + (pad_xform * (corner_pt as Vector2)))))
		return make_node([core], [], corner_mm, layers, route_at)

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
	return make_node([], [land_line], radius, layers, route_at)


## A roundrect pad's corner radius in mm, or 0.0 when the pad does not state
## one. `corner_rratio` is the worker's own encoding — the radius as a fraction
## of the SHORT side, clamped to the [0, 0.5] the schema admits — so this reads
## the authored land rather than re-deriving a family default the emitters may
## not agree with.
static func corner_radius_mm(pad: Dictionary, half: Vector2) -> float:
	var ratio = pad.get("corner_rratio", null)
	if not (ratio is float or ratio is int):
		return 0.0
	return clampf(float(ratio), 0.0, 0.5) * minf(half.x, half.y) * 2.0


# ── LAYERS ────────────────────────────────────────────────────────────────────

## Canonical copper id for any layer spelling, SILENTLY. PcbLayerStack's own
## kicad_to_canon push_warning()s on an unrecognised name, which is right for a
## board load and wrong here — this runs over every entity on every extract.
static func canon(layer) -> String:
	var low := str(layer).strip_edges().to_lower()
	if low.is_empty():
		return ""
	if PcbLayerStack.is_copper(low):
		return PcbLayerStack.kicad_to_canon(low)
	return low


static func layer_set(layers) -> Dictionary:
	var out := {}
	for l in layers:
		var c := canon(l)
		if not c.is_empty():
			out[c] = true
	return out


# ── TOUCH: does this copper reach that copper ─────────────────────────────────

## THE predicate: are these two pieces of copper one conductor? Their layer sets
## intersect AND their geometry meets within the pair's tolerance.
##
## The bounds test runs first: it keeps the O(nodes^2) sweeps that call this
## from becoming O(segments^2) across a whole board.
static func nodes_touch(a: Dictionary, b: Dictionary) -> bool:
	if not (a["bounds"] as Rect2).intersects(b["bounds"] as Rect2, true):
		return false
	if not layers_meet(a["layers"], b["layers"]):
		return false
	var tol: float = float(a["swell"]) + float(b["swell"]) + TOUCH_EPS_MM
	for la in (a["lines"] as Array):
		for lb in (b["lines"] as Array):
			if lines_meet(la, lb, tol):
				return true
	for la in (a["lines"] as Array):
		for pb in (b["polys"] as Array):
			if line_meets_polygon(la, pb, tol):
				return true
	for lb in (b["lines"] as Array):
		for pa in (a["polys"] as Array):
			if line_meets_polygon(lb, pa, tol):
				return true
	for pa in (a["polys"] as Array):
		for pb in (b["polys"] as Array):
			if polygons_meet(pa, pb, tol):
				return true
	return false


static func layers_meet(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return true   # unknown side: do not invent a separation
	for k in a:
		if b.has(k):
			return true
	return false


## Segment count for a point list, treating a lone point (a via, a trace end, a
## geometry-less pin) as one degenerate segment so every caller has segments.
static func seg_count(pts: PackedVector2Array) -> int:
	if pts.is_empty():
		return 0
	return maxi(1, pts.size() - 1)


static func seg_end(pts: PackedVector2Array, i: int) -> Vector2:
	return pts[i + 1] if i + 1 < pts.size() else pts[i]


## The closest pair between two segments, each segment handed to the engine
## with its endpoints in lexicographic order. A segment is the same set of
## points whichever way its two endpoints are listed, but when the closest
## approach is a CONTINUUM — parallel overlapping runs — the engine returns
## one pair of it, chosen by the order the endpoints arrive in. Fixing that
## order makes the returned pair a function of the segments' geometry alone,
## so a polyline read from either end yields the same witness. Every
## segment-to-segment measurement goes through here, the boolean touch tests
## included, so touch and aim measure with one instrument.
static func seg_closest(a1: Vector2, a2: Vector2,
		b1: Vector2, b2: Vector2) -> PackedVector2Array:
	if point_less(a2, a1):
		var a_swap := a1
		a1 = a2
		a2 = a_swap
	if point_less(b2, b1):
		var b_swap := b1
		b1 = b2
		b2 = b_swap
	return Geometry2D.get_closest_points_between_segments(a1, a2, b1, b2)


## Lexicographic order over one point: x, then y.
static func point_less(a: Vector2, b: Vector2) -> bool:
	if a.x != b.x:
		return a.x < b.x
	return a.y < b.y


static func lines_meet(a: PackedVector2Array, b: PackedVector2Array, tol: float) -> bool:
	for i in seg_count(a):
		for j in seg_count(b):
			var closest := seg_closest(
				a[i], seg_end(a, i), b[j], seg_end(b, j))
			if closest.size() == 2 and closest[0].distance_to(closest[1]) <= tol:
				return true
	return false


static func line_meets_polygon(line: PackedVector2Array, poly: PackedVector2Array,
		tol: float) -> bool:
	if poly.size() < 3:
		return false
	for p in line:
		if Geometry2D.is_point_in_polygon(p, poly):
			return true
	for i in seg_count(line):
		for k in poly.size():
			var closest := seg_closest(
				line[i], seg_end(line, i), poly[k], poly[(k + 1) % poly.size()])
			if closest.size() == 2 and closest[0].distance_to(closest[1]) <= tol:
				return true
	return false


static func polygons_meet(a: PackedVector2Array, b: PackedVector2Array, tol: float) -> bool:
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
			var closest := seg_closest(
				a[i], a[(i + 1) % a.size()], b[k], b[(k + 1) % b.size()])
			if closest.size() == 2 and closest[0].distance_to(closest[1]) <= tol:
				return true
	return false


# ── ASKING THE QUESTION ABOUT A WHOLE BOARD ──────────────────────────────────

## The board's declared copper layers, canonicalised, in stack order. Used for
## the two kinds of copper that pierce EVERY layer: a through-hole pad's barrel
## and a through via.
static func copper_stack(data) -> PackedStringArray:
	var out := PackedStringArray()
	var declared = data.layers if data.layers is Array else []
	for l in declared:
		var c := canon(l)
		if not c.is_empty() and not (c in out):
			out.append(c)
	if out.is_empty():
		out.append("top")
		out.append("bottom")
	return out


## Does `copper` reach any land of `comp`'s pin `pin_name`? The one call the
## panel's own consumers make — the trace verbs' free-end test and the pin
## inspector's "which traces touch this pad" — so a pad the inspector reports as
## touched is a pad the verbs refuse to draw from.
static func copper_joins_pin(copper: Dictionary, comp, pin_name: String,
		stack: PackedStringArray,
		unknown_land_radius_mm: float = DEFAULT_UNKNOWN_LAND_RADIUS_MM) -> bool:
	for land in pad_nodes(comp, pin_name, stack, unknown_land_radius_mm):
		if nodes_touch(copper, land as Dictionary):
			return true
	return false


## The copper layers a via's barrel occupies: its two endpoints plus everything
## between them in the declared stack. (Only through spans are modelled — see
## PcbLayerStack.is_legal_via_span — so in practice this is the whole stack; a
## blind/buried span would yield fewer layers.) A span naming a layer the board
## does not declare answers with its two endpoints rather than guessing what
## lies between two names the stack cannot order.
##
## Lives here, beside via_node, because two callers now need it: the ratsnest's
## same-net copper sweep and the region read's layers_touched. Two copies is how
## one of them ends up reporting a different barrel from the other.
static func via_span(via: Dictionary, stack: PackedStringArray) -> Array:
	var from_layer := canon(via.get("from_layer", "top"))
	var to_layer := canon(via.get("to_layer", "bottom"))
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
