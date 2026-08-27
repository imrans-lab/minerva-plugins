extends SceneTree
## THE RATSNEST: physical connectivity, a spanning tree, and quieting.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_pcb_ratsnest.gd
##
## ── WHAT EACH SECTION COVERS ─────────────────────────────────────────────────
##
##   1. PHYSICAL CONNECTIVITY (fixture). One board, eight nets, each a separate
##      physical question: a routed pair, a pair with a 0.5mm gap, a pair whose
##      only trace is on the wrong side, a through-hole pad reached from the
##      back, a via that changes layers, a pour whose COMPILED FILL joins two
##      pads, a KEEPOUT that joins nothing, and a rotated part. Every net has
##      exactly two pins, so net membership cannot decide any of the answers.
##      A remaining join whose two ends share no copper layer DECLARES the
##      layer change — even at zero length — and a same-layer join does not.
##
##   2. THE EDGE-ADDITION INVARIANT. Joining two SEPARATE islands lowers the
##      count of remaining joins by exactly one; joining two pads ALREADY in
##      the same island lowers it by zero.
##
##   3. SPANNING TREE, NOT A CHAIN. Four pads spaced 10mm apart on a line,
##      listed in the net in scrambled order. For equally spaced collinear
##      points the Euclidean MST is the chain of ADJACENT pairs: three 10mm
##      links, 30mm total, none longer than 10mm. Asserted as total length plus
##      a per-link ceiling, both derived from the geometry.
##
##   4. DETERMINISM. The same physical board, described twice with every list
##      reversed — the zones' nested fill regions and the points within each
##      region included — produces the identical picture. Any dependence on
##      Dictionary order, on file order, or on an unstable sort shows up as a
##      difference. Two symmetric fixtures put an EXACT equal-distance tie in
##      front of the solver (two equidistant fill regions; two equidistant
##      edges of one notched region) so a tie resolved by visit order rather
##      than by geometry shows up as a moved endpoint. TRACE WAYPOINT ORDER is
##      its own case: every trace reversed on the connectivity board, plus a
##      collinear partially-overlapping pair on different layers, where the
##      closest approach is a CONTINUUM and the witness may not move when a
##      trace's points are listed from the other end.
##
##   5. QUIETING IS NOT HIDING. A 20-pad unrouted net. (a) the REPORTED
##      remaining count equals islands-1 however many links were drawn; (b)
##      every island is either touched by a drawn link or carries a marker.
##      Plus the threshold boundary from both sides, stated against the
##      constant.
##
##   6. THE CANVAS SEAM. A capture copy draws the same ratsnest as the screen;
##      the cache re-solves when a LIVE DRAG moves copper (a drag mutates
##      component positions WITHOUT bumping board_revision — see
##      pcb_canvas._apply_drag_delta); and N toggles the ratsnest.
##
##   7. A POUR CONDUCTS AS ITS COMPILED FILL. The same authored outline joins
##      two pads when its fill is one region covering both, does NOT join them
##      when the fill is two separate regions (one per pad), and proves nothing
##      when no fill is present at all — the outline never stands in for
##      copper. DAMAGED FILL DATA IS NOT COPPER: a region with a non-point
##      entry, a point missing a coordinate, a non-finite coordinate, or a
##      ring enclosing no area contributes no connection — and one damaged
##      region rejects the whole fill, intact siblings included.
##
##   8. A PAD IS NOT ITS BOUNDING BOX. A trace passing where a circular land's
##      bounding-box corner would be, 0.16mm clear of the real disc, does not
##      join; a trace genuinely reaching the disc does.
##
##   9. A PAD'S OWN ROTATION IS PART OF ITS SHAPE. It survives decode and a
##      serialize round trip; the solver's land is where fabrication puts it
##      (offset turned by the component only, body turned by both), so copper
##      on the real end joins and copper on the phantom unrotated end does not.
##
##  10. AN AIRWIRE AIMS AT THE ISLAND'S COPPER. A pad 2mm from the middle of a
##      routed trace gets a 2mm airwire onto the trace, not a 15mm airwire to
##      the nearest pad centre of that island.
##
##  11. A JOIN THAT NEEDS NO LAYER CHANGE BEATS ONE THAT DOES. An island holds
##      a surface land and a through-hole barrel at the same position; against
##      a far bottom-side pad the two candidate joins tie on length and
##      witness points, and only the barrel reaches the bottom. The surviving
##      join declares no layer change whichever ref spelling sorts first —
##      refs make the choice deterministic, they never make it.
##
##  12. DUPLICATE PAD NUMBERS ARE DISTINCT LANDS, ONE LOGICAL PIN. Copper on a
##      non-first land closes the pin, while a through-hole land elsewhere does
##      not lend its bottom-layer reach to a top-only sibling. Reversing the
##      physical-pad list changes neither answer nor picture.
##
##  13. ROUTE FOCUS — one destination, locked for the gesture. (a) six pads with
##      unique nearest neighbours: every pad is offered the nearest one, at that
##      land's copper, measured from the pad the gesture started on, against
##      distances this suite computes itself. (b) the destination is COPPER, so
##      a pad 2mm off a routed trace is aimed at the trace (Godot's own
##      closest-point-on-segment is the oracle) while a pad at the other end of
##      that island is offered the far land it can actually reach. (c) quieting
##      thins the drawn airwires, never the destination: every pad of a 20-pad
##      quieted net has one, at the 4mm grid pitch, including the pads no drawn
##      airwire touches. (d) the canvas seam — idle renders the solver's answer
##      with nothing dimmed, the destination is fixed at gesture start and
##      survives waypoints, cursor movement and a board edit that demonstrably
##      moves the answer, every other airwire recedes without any leaving the
##      picture, a capture copy draws the same thing, and commit and cancel both
##      leave nothing behind.
##
##  14. A VIA IS COPPER WITH EXTENT, ANYWHERE ALONG A RUN. A probe pair strapped
##      to the plane by one via at the exact midpoint of their run — the panel
##      half of the worker's own oracle — joins; the same via slid 0.66mm off
##      the centreline (0.01mm past half-width + annulus) does not; and the
##      free-end verb reads that same annulus rather than a point-in-disc pick.

const Ratsnest := preload("res://../../minerva-plugins/pcb/ui/model/pcb_ratsnest.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PCBComponent := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Ratsnest: physical connectivity, MST, quieting ===\n")
	_run_physical_connectivity()
	_run_edge_addition_invariant()
	_run_spanning_tree_not_chain()
	_run_determinism()
	_run_quieting_is_not_hiding()
	_run_canvas_seam()
	_run_pour_conducts_as_its_fill()
	_run_pad_is_not_its_bounding_box()
	_run_pad_rotation_is_part_of_its_shape()
	_run_airwire_aims_at_island_copper()
	_run_layer_change_tie()
	_run_duplicate_pad_numbers()
	_run_route_focus_is_the_nearest_island()
	_run_route_focus_aims_at_copper()
	_run_route_focus_survives_quieting()
	_run_route_focus_canvas_gesture()
	_run_a_via_is_copper_with_extent()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


# ── fixture helpers ───────────────────────────────────────────────────────────

## A surface-mount pin with real land geometry: 1.0 x 1.0 mm, so its copper
## spans +/-0.5mm around the pin centre. Every distance asserted below is
## measured against that half-millimetre.
func _smd_pin(number: String, x: float, y: float) -> Dictionary:
	return {"number": number, "x_mm": x, "y_mm": y,
		"pad_width_mm": 1.0, "pad_height_mm": 1.0}


## A through-hole pin: 0.6mm drill in a 1.2mm annulus. The barrel pierces the
## board, so its land exists on EVERY copper layer — which is what the PWR_THT
## net below exercises.
func _tht_pin(number: String, x: float, y: float) -> Dictionary:
	return {"number": number, "x_mm": x, "y_mm": y,
		"drill_mm": 0.6, "annulus_diameter_mm": 1.2}


func _part(ref: String, x: float, y: float, pins: Array, layer: String = "top") -> Dictionary:
	return {"ref": ref, "footprint": "CUSTOM", "x_mm": x, "y_mm": y,
		"rotation_deg": 0.0, "layer": layer, "pins": pins}


func _trace(id: String, net: String, layer: String, a: Vector2, b: Vector2,
		width: float = 0.25) -> Dictionary:
	return {"id": id, "net": net, "layer": layer, "width_mm": width,
		"points": [{"x_mm": a.x, "y_mm": a.y}, {"x_mm": b.x, "y_mm": b.y}]}


func _rect_outline(a: Vector2, b: Vector2) -> Array:
	return [{"x_mm": a.x, "y_mm": a.y}, {"x_mm": b.x, "y_mm": a.y},
		{"x_mm": b.x, "y_mm": b.y}, {"x_mm": a.x, "y_mm": b.y}]


func _board(spec: Dictionary):
	var d = PCBData.new()
	var full := {
		"version": 1, "name": "ratsnest-fixture", "width_mm": 45.0, "height_mm": 45.0,
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [], "nets": [], "traces": [], "vias": [], "zones": [],
	}
	for k in spec:
		full[k] = spec[k]
	d.from_board_dict(full)
	_adopt_authored_fills(d, full.get("zones", []))
	return d


## A pour's fill reaches the model through adopt_zone_fill and no other door —
## a board dict never carries one in (PCBData.ZONE_FILL_KEY). The fixtures here
## author a fill inline as the shortest way to say "the compiler answered THIS",
## so hand it over the way a compiler answer arrives.
func _adopt_authored_fills(d, zone_specs) -> void:
	var entries: Array = []
	for zone in (zone_specs as Array):
		if zone is Dictionary and (zone as Dictionary).has("fill"):
			entries.append({"id": (zone as Dictionary).get("id", ""),
				"fill": (zone as Dictionary)["fill"]})
	if not entries.is_empty():
		d.adopt_zone_fill(entries)


## net name -> the row solve() reported for it. A net absent from the result
## has nothing left to join; _remaining() reports 0 for it.
func _rows_by_net(result: Dictionary) -> Dictionary:
	var out := {}
	for row in result.get("nets", []):
		out[str((row as Dictionary)["net"])] = row
	return out


func _remaining(result: Dictionary, net: String) -> int:
	var rows := _rows_by_net(result)
	if not rows.has(net):
		return 0
	return int((rows[net] as Dictionary)["remaining"])


func _links_for(result: Dictionary, net: String) -> Array:
	var out: Array = []
	for link in result.get("links", []):
		if str((link as Dictionary)["net"]) == net:
			out.append(link)
	return out


## A stable text rendering of the whole picture, for comparing two answers.
##
## EMPHASIS IS PART OF THE PICTURE. A canvas render plan tags every link and
## marker with the weight it is drawn at and may carry a focused destination;
## a raw solver answer carries neither, and reads as "normal" with no focus —
## which is exactly what an idle canvas must produce. Without emphasis here,
## "the idle picture is unchanged" would still pass for a canvas that dimmed
## half the board.
func _picture(result: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for link in result.get("links", []):
		var l := link as Dictionary
		out.append("link %s %s->%s (%.4f,%.4f)-(%.4f,%.4f)%s [%s]" % [
			str(l["net"]), str(l["a_ref"]), str(l["b_ref"]),
			(l["a"] as Vector2).x, (l["a"] as Vector2).y,
			(l["b"] as Vector2).x, (l["b"] as Vector2).y,
			" via" if bool(l.get("layer_change", false)) else "",
			str(l.get("emphasis", "normal"))])
	for marker in result.get("markers", []):
		var m := marker as Dictionary
		out.append("mark %s %s [%s]" % [str(m["net"]), str(m["ref"]),
			str(m.get("emphasis", "normal"))])
	var focus: Dictionary = result.get("focus", {})
	if not focus.is_empty():
		out.append("focus %s (%.4f,%.4f)-(%.4f,%.4f) [%s]" % [
			str(focus["label"]),
			(focus["a"] as Vector2).x, (focus["a"] as Vector2).y,
			(focus["b"] as Vector2).x, (focus["b"] as Vector2).y,
			str(focus.get("emphasis", "normal"))])
	for row in result.get("nets", []):
		var r := row as Dictionary
		out.append("net %s islands=%d remaining=%d shown=%d quiet=%s" % [
			str(r["net"]), int(r["islands"]), int(r["remaining"]),
			int(r["shown"]), str(r["quieted"])])
	return out


# ── 1. physical connectivity ──────────────────────────────────────────────────

## ONE board, seven nets, seven independent physical questions. Each net's
## expected answer is stated in its own comment and derived from the copper,
## never from the net.
func _connectivity_board():
	return _board(_connectivity_spec())


## The literal spec above, freshly built on each call so test 4 can permute a
## copy without touching this one.
func _connectivity_spec() -> Dictionary:
	return {
		"components": [
			# SIG_JOINED — routed end to end.
			_part("U1", 10.0, 10.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("U2", 20.0, 10.0, [_smd_pin("1", 0.0, 0.0)]),
			# SIG_GAP — the trace stops short of the second land.
			_part("U7", 10.0, 18.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("U8", 20.0, 18.0, [_smd_pin("1", 0.0, 0.0)]),
			# SIG_WRONGSIDE — two top-side lands, one bottom-side trace.
			_part("U9", 10.0, 24.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("U10", 20.0, 24.0, [_smd_pin("1", 0.0, 0.0)]),
			# PWR_THT — a through-hole land and a surface land, bottom trace.
			_part("U3", 30.0, 10.0, [_tht_pin("1", 0.0, 0.0)]),
			_part("U4", 30.0, 20.0, [_smd_pin("1", 0.0, 0.0)]),
			# PWR_VIA — the same, plus the via that changes layers.
			_part("U11", 34.0, 10.0, [_tht_pin("1", 0.0, 0.0)]),
			_part("U12", 34.0, 20.0, [_smd_pin("1", 0.0, 0.0)]),
			# POUR / KEEPOUT — two lands under an area.
			_part("U5", 14.0, 14.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("U6", 18.0, 14.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("U13", 14.0, 28.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("U14", 18.0, 28.0, [_smd_pin("1", 0.0, 0.0)]),
			# ROT — a 90-degree part with an OFFSET, ELONGATED land. The trace
			# below reaches it only if BOTH the pad's offset from the part origin
			# and the pad's own long axis are turned by the part's rotation.
			# Hand-derived: rotating (2,0) by the component transform puts the
			# land's centre at (38,28), and its 3.0 x 0.6 body then spans
			# x 37.7..38.3, y 26.5..29.5 — so a trace ending at (38,27) is on
			# copper. With the offset unrotated the land sits near (40,30),
			# three millimetres away.
			{"ref": "U15", "footprint": "CUSTOM", "x_mm": 38.0, "y_mm": 30.0,
				"rotation_deg": 90.0, "layer": "top",
				"pins": [{"number": "1", "x_mm": 2.0, "y_mm": 0.0,
					"pad_width_mm": 3.0, "pad_height_mm": 0.6}]},
			_part("U16", 38.0, 24.0, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [
			{"name": "SIG_JOINED", "pins": ["U1.1", "U2.1"]},
			{"name": "SIG_GAP", "pins": ["U7.1", "U8.1"]},
			{"name": "SIG_WRONGSIDE", "pins": ["U9.1", "U10.1"]},
			{"name": "PWR_THT", "pins": ["U3.1", "U4.1"]},
			{"name": "PWR_VIA", "pins": ["U11.1", "U12.1"]},
			{"name": "POUR", "pins": ["U5.1", "U6.1"]},
			{"name": "KEEPOUT", "pins": ["U13.1", "U14.1"]},
			{"name": "ROT", "pins": ["U15.1", "U16.1"]},
		],
		"traces": [
			_trace("t_joined", "SIG_JOINED", "top", Vector2(10, 10), Vector2(20, 10)),
			# Ends at x=19.0. U8.1's land starts at x=19.5, and the trace's own
			# half-width is 0.125 — so 0.375mm of bare laminate remains.
			_trace("t_gap", "SIG_GAP", "top", Vector2(10, 18), Vector2(19, 18)),
			_trace("t_wrong", "SIG_WRONGSIDE", "bottom", Vector2(10, 24), Vector2(20, 24)),
			_trace("t_tht", "PWR_THT", "bottom", Vector2(30, 10), Vector2(30, 20)),
			_trace("t_via", "PWR_VIA", "bottom", Vector2(34, 10), Vector2(34, 20)),
			_trace("t_rot", "ROT", "top", Vector2(38, 24), Vector2(38, 27)),
		],
		"vias": [
			{"id": "v1", "x_mm": 34.0, "y_mm": 20.0, "drill_mm": 0.4,
				"diameter_mm": 0.8, "net": "PWR_VIA",
				"from_layer": "top", "to_layer": "bottom"},
		],
		"zones": [
			# The pour carries its COMPILED FILL: one region covering both
			# lands, so the two pads are one conductor.
			{"id": "z_pour", "layer": "top", "kind": "copper_pour", "net": "POUR",
				"outline": _rect_outline(Vector2(13, 13), Vector2(19, 15)),
				"fill": [_rect_outline(Vector2(13.2, 13.2), Vector2(18.8, 14.8))]},
			# Carries a net AND a fill on purpose: it is excluded because a
			# keepout is not copper, not because of its net or a missing fill.
			{"id": "z_keep", "layer": "top", "kind": "keepout", "net": "KEEPOUT",
				"outline": _rect_outline(Vector2(13, 27), Vector2(19, 29)),
				"fill": [_rect_outline(Vector2(13.2, 27.2), Vector2(18.8, 28.8))]},
		],
	}


func _run_physical_connectivity() -> void:
	print("-- 1. connectivity comes from copper, never from net membership --")
	var d = _connectivity_board()
	var result := Ratsnest.compute(d)

	check_eq("a trace landing on both pads leaves nothing to join",
		_remaining(result, "SIG_JOINED"), 0)
	check("…and draws no airwire at all", _links_for(result, "SIG_JOINED").is_empty())

	check_eq("a trace stopping 0.5mm short of the land is NOT a connection",
		_remaining(result, "SIG_GAP"), 1)
	check_eq("…so exactly one airwire still asks for that join",
		_links_for(result, "SIG_GAP").size(), 1)

	check_eq("copper on the wrong side of the board joins nothing",
		_remaining(result, "SIG_WRONGSIDE"), 1)

	check_eq("a bottom trace reaches a THROUGH-HOLE land but not a top-side SMD one",
		_remaining(result, "PWR_THT"), 1)
	var tht_links := _links_for(result, "PWR_THT")
	check_eq("…and exactly one airwire asks for that join", tht_links.size(), 1)
	if tht_links.size() == 1:
		var tht := tht_links[0] as Dictionary
		# The island holding U3 also holds the bottom trace, whose end sits
		# directly under U4's land — that trace end, not U3's centre 10mm away,
		# is where the joining copper (a via) would land.
		check("…the airwire lands on the trace end under the pad, not on the far pad centre",
			(tht["a"] as Vector2).is_equal_approx(Vector2(30, 20))
				and (tht["b"] as Vector2).is_equal_approx(Vector2(30, 20)))
		check_eq("…its pad endpoint names the still-unjoined land", str(tht["b_ref"]), "U4.1")
		check_eq("…its copper endpoint is mid-island copper, not a pad", str(tht["a_ref"]), "")
		# The bottom trace and the top land share no layer, and the two ends
		# COINCIDE — the join is zero-length, so the line itself can show
		# nothing. The link must say the layer change out loud.
		check("…and a zero-length join across layers DECLARES the layer change",
			tht.has("layer_change") and bool(tht["layer_change"]))

	var gap_links := _links_for(result, "SIG_GAP")
	if gap_links.size() == 1:
		check("a same-layer join declares NO layer change",
			not bool((gap_links[0] as Dictionary).get("layer_change", true)))

	check_eq("a via joining a bottom trace to a top land closes the net",
		_remaining(result, "PWR_VIA"), 0)

	check_eq("a pour whose COMPILED FILL covers two lands on its own layer joins them",
		_remaining(result, "POUR"), 0)

	check_eq("a KEEPOUT is an instruction, not a conductor — it joins nothing",
		_remaining(result, "KEEPOUT"), 1)

	check_eq("a rotated part's offset, elongated land is measured where it is DRAWN",
		_remaining(result, "ROT"), 0)

	# Every net above has exactly two pins, so membership alone gives all eight
	# the same answer. Half of them differ.
	var by_net := {}
	for n in ["SIG_JOINED", "SIG_GAP", "SIG_WRONGSIDE", "PWR_THT", "PWR_VIA",
			"POUR", "KEEPOUT", "ROT"]:
		by_net[n] = _remaining(result, n)
	check("eight identically-shaped nets give four zeros and four ones — "
		+ "membership cannot have produced this (%s)" % str(by_net),
		by_net.values().count(0) == 4 and by_net.values().count(1) == 4)


# ── 2. the edge-addition invariant ────────────────────────────────────────────

func _run_edge_addition_invariant() -> void:
	print("-- 2. invariant: copper joining two islands removes exactly one join --")
	var parts: Array = []
	var pin_refs: Array = []
	for i in 5:
		var ref := "P%d" % (i + 1)
		parts.append(_part(ref, 5.0 + 5.0 * i, 30.0, [_smd_pin("1", 0.0, 0.0)]))
		pin_refs.append("%s.1" % ref)
	var d = _board({
		"components": parts,
		"nets": [{"name": "INV", "pins": pin_refs}],
	})

	check_eq("five separate lands need four joins",
		_remaining(Ratsnest.compute(d), "INV"), 4)

	_add_trace(d, "INV", "top", Vector2(5, 30), Vector2(10, 30))
	check_eq("joining two separate islands drops it by exactly one",
		_remaining(Ratsnest.compute(d), "INV"), 3)

	_add_trace(d, "INV", "top", Vector2(15, 30), Vector2(20, 30))
	check_eq("joining two more, elsewhere on the net, drops it by one again",
		_remaining(Ratsnest.compute(d), "INV"), 2)

	# A second trace between two pads ALREADY joined adds copper and no
	# connectivity, so the number of joins still needed does not move.
	_add_trace(d, "INV", "top", Vector2(5, 30), Vector2(10, 30))
	check_eq("a redundant second trace between an already-joined pair changes nothing",
		_remaining(Ratsnest.compute(d), "INV"), 2)

	# …and copper bridging the two islands built above merges them, even though
	# neither of its endpoints is a NEW pad.
	_add_trace(d, "INV", "top", Vector2(10, 30), Vector2(15, 30))
	check_eq("copper bridging two existing islands merges them",
		_remaining(Ratsnest.compute(d), "INV"), 1)

	_add_trace(d, "INV", "top", Vector2(20, 30), Vector2(25, 30))
	check_eq("the last join closes the net", _remaining(Ratsnest.compute(d), "INV"), 0)
	check("a net with nothing left to join contributes no airwire and no row",
		_links_for(Ratsnest.compute(d), "INV").is_empty()
			and not _rows_by_net(Ratsnest.compute(d)).has("INV"))


func _add_trace(d, net: String, layer: String, a: Vector2, b: Vector2) -> void:
	var t = d.new_trace()
	t.net_name = net
	t.layer = layer
	t.width = 0.25
	t.add_waypoint(a)
	t.add_waypoint(b)
	d.add_trace(t)


# ── 3. spanning tree, not a chain ─────────────────────────────────────────────

func _line_net_board(order: Array):
	var parts: Array = []
	for i in 4:
		parts.append(_part("L%d" % (i + 1), 5.0 + 10.0 * i, 38.0,
			[_smd_pin("1", 0.0, 0.0)]))
	return _board({
		"components": parts,
		"nets": [{"name": "LINE", "pins": order}],
	})


func _run_spanning_tree_not_chain() -> void:
	print("-- 3. a spanning tree over the nearest islands, not the pin list --")
	# Pads at x = 5, 15, 25, 35 on one line, listed OUT of geometric order.
	var scrambled := ["L3.1", "L1.1", "L4.1", "L2.1"]
	var result := Ratsnest.compute(_line_net_board(scrambled))
	var links := _links_for(result, "LINE")

	check_eq("four separate lands need three joins", links.size(), 3)

	var total := 0.0
	var longest := 0.0
	for l in links:
		var len_mm := float((l as Dictionary)["length"])
		total += len_mm
		longest = maxf(longest, len_mm)
	# For equally spaced collinear points the Euclidean MST is the chain of
	# ADJACENT pairs: three 10mm hops, 30mm total, none longer than 10mm.
	check("the tree's total length is the minimum 30mm (got %.3f)" % total,
		is_equal_approx(total, 30.0))
	check("no airwire skips a neighbour — longest is 10mm (got %.3f)" % longest,
		longest <= 10.0 + 1e-4)

	# The picture is a property of the BOARD, not of the order the net lists its
	# pins in.
	var reversed_order := scrambled.duplicate()
	reversed_order.reverse()
	check("reversing the pin list changes nothing about the picture",
		_picture(result) == _picture(Ratsnest.compute(_line_net_board(reversed_order))))


# ── 4. determinism ────────────────────────────────────────────────────────────

func _run_determinism() -> void:
	print("-- 4. the same board draws the same picture every time --")
	# Plain `=`: _connectivity_board() returns Variant (PCBData is an untyped
	# preload), and `:=` cannot infer a type from a Variant-returning call —
	# the script would fail to parse.
	var forward = _connectivity_board()
	var picture := _picture(Ratsnest.compute(forward))

	# The SAME physical board, described with every list reversed: components,
	# nets, traces, vias, zones. The spec is the one _connectivity_board() itself
	# loads, so only the ordering differs.
	var spec := _connectivity_spec()
	for key in ["components", "nets", "traces", "vias", "zones"]:
		var reversed_list: Array = (spec[key] as Array).duplicate()
		reversed_list.reverse()
		spec[key] = reversed_list
	var backward = _board(spec)
	check("a board described in reverse order draws the identical picture",
		_picture(Ratsnest.compute(backward)) == picture)

	# The NESTED lists too: each zone's fill regions reversed, and the points
	# within each region reversed, on top of the top-level reversals.
	var nested := _connectivity_spec()
	for key in ["components", "nets", "traces", "vias", "zones"]:
		var nested_rev: Array = (nested[key] as Array).duplicate()
		nested_rev.reverse()
		nested[key] = nested_rev
	for zone in (nested["zones"] as Array):
		(zone as Dictionary)["fill"] = _reversed_fill((zone as Dictionary).get("fill"))
	check("reversing every zone's fill regions and their points changes nothing",
		_picture(Ratsnest.compute(_board(nested))) == picture)

	# And twice over the same model instance, so nothing carried between runs.
	check("recomputing over the same board is byte-identical",
		_picture(Ratsnest.compute(forward)) == picture)

	# AN EXACT EQUAL-DISTANCE TIE, region against region. T2 carries two fill
	# regions placed symmetrically above and below it; each presents a corner
	# exactly sqrt(9.75^2 + 0.25^2) mm from T1's centre (every coordinate
	# offset is binary-exact, so the two distances are bit-identical), and
	# both beat the 10mm pad pair. Which region the airwire lands on is a pure
	# tie — it may not depend on the order the regions arrive in.
	var up := _rect_outline(Vector2(19.75, 8.0), Vector2(20.25, 9.75))
	var down := _rect_outline(Vector2(19.75, 10.25), Vector2(20.25, 12.0))
	var tie_fwd := Ratsnest.compute(_twin_region_board([up, down]))
	var tie_rev := Ratsnest.compute(_twin_region_board([down, up]))
	var tie_links := _links_for(tie_fwd, "TIE")
	check_eq("the twin-region board owes exactly one join", tie_links.size(), 1)
	if tie_links.size() == 1:
		check("the airwire lands on a region, nearer than the 10mm pad pair (got %.4f)"
			% float((tie_links[0] as Dictionary)["length"]),
			float((tie_links[0] as Dictionary)["length"]) < 10.0 - 1e-3)
	check("swapping the two equidistant regions draws the identical picture",
		_picture(tie_fwd) == _picture(tie_rev))

	# The same tie INSIDE one region: a ring notched on the side facing N1, so
	# its two left-edge segments end 0.25mm above and below N1's row — two
	# witness points at bit-identical distances. Reversing the ring's points
	# reverses the order the two are visited in; the picture may not move.
	var ring := [
		{"x_mm": 19.75, "y_mm": 9.0}, {"x_mm": 22.0, "y_mm": 9.0},
		{"x_mm": 22.0, "y_mm": 11.0}, {"x_mm": 19.75, "y_mm": 11.0},
		{"x_mm": 19.75, "y_mm": 10.25}, {"x_mm": 20.75, "y_mm": 10.25},
		{"x_mm": 20.75, "y_mm": 9.75}, {"x_mm": 19.75, "y_mm": 9.75},
	]
	var ring_rev: Array = ring.duplicate()
	ring_rev.reverse()
	check("reversing the points within a notched region draws the identical picture",
		_picture(Ratsnest.compute(_notched_region_board(ring)))
			== _picture(Ratsnest.compute(_notched_region_board(ring_rev))))

	# TRACE WAYPOINT ORDER, whole board: a trace is the same copper whichever
	# end its points are listed from.
	var tr := _connectivity_spec()
	for trace in (tr["traces"] as Array):
		var pts_rev: Array = ((trace as Dictionary)["points"] as Array).duplicate()
		pts_rev.reverse()
		(trace as Dictionary)["points"] = pts_rev
	check("reversing every trace's waypoints draws the identical picture",
		_picture(Ratsnest.compute(_board(tr))) == picture)

	# THE CONTINUUM CASE. Two collinear traces on different layers overlap for
	# 8mm in plan: EVERY point of the overlap is an equally close approach, so
	# the closest-pair primitive has a continuum to choose one witness from.
	# ORACLE: the copper is identical however either trace lists its points, so
	# the picture — the witness included — may not move; and any correct
	# witness lies inside the overlap, at zero length, declaring the layer
	# change.
	var ovl := Ratsnest.compute(_overlap_board(false, false))
	var ovl_links := _links_for(ovl, "OVL")
	check_eq("the overlapping cross-layer pair still owes exactly one join",
		ovl_links.size(), 1)
	if ovl_links.size() == 1:
		var ol := ovl_links[0] as Dictionary
		check("…at zero length: the copper overlaps in plan (got %.4f)"
			% float(ol["length"]), float(ol["length"]) < 1e-6)
		check("…declaring the layer change", bool(ol["layer_change"]))
		var wx := (ol["a"] as Vector2).x
		check("…witnessed inside the 8mm overlap (got x=%.4f)" % wx,
			wx >= 12.0 - 1e-4 and wx <= 20.0 + 1e-4)
	for flips in [[true, false], [false, true], [true, true]]:
		check("reversing trace waypoints moves nothing (top flipped=%s, bottom flipped=%s)"
			% [str(flips[0]), str(flips[1])],
			_picture(Ratsnest.compute(_overlap_board(flips[0], flips[1])))
				== _picture(ovl))


## `fill` with its regions in reverse order and each region's points reversed;
## anything not Array-shaped comes back untouched.
func _reversed_fill(fill):
	if not (fill is Array):
		return fill
	var regions: Array = (fill as Array).duplicate()
	regions.reverse()
	for i in regions.size():
		if regions[i] is Array:
			var pts: Array = (regions[i] as Array).duplicate()
			pts.reverse()
			regions[i] = pts
	return regions


## Two pads 10mm apart; T2 is joined to every fill region handed in, T1 stands
## alone, so the one remaining join must bridge T1 to T2's island.
func _twin_region_board(fill_regions: Array):
	return _board({
		"components": [
			_part("T1", 10.0, 10.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("T2", 20.0, 10.0, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [{"name": "TIE", "pins": ["T1.1", "T2.1"]}],
		"zones": [{"id": "zt", "layer": "top", "kind": "copper_pour", "net": "TIE",
			"outline": _rect_outline(Vector2(19, 7), Vector2(21, 13)),
			"fill": fill_regions}],
	})


## Two collinear traces on DIFFERENT layers, overlapping in plan for
## x 12..20 at y 10, each landing on its own pad. Two islands — the layers
## never meet — whose closest approach is the whole overlap segment. Each
## flip lists that trace's two waypoints in the opposite order; the copper is
## identical in all four spellings.
func _overlap_board(flip_top: bool, flip_bottom: bool):
	var top_a := Vector2(5, 10)
	var top_b := Vector2(20, 10)
	var bot_a := Vector2(12, 10)
	var bot_b := Vector2(30, 10)
	return _board({
		"components": [
			_part("V1", 5.0, 10.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("V2", 30.0, 10.0, [_smd_pin("1", 0.0, 0.0)], "bottom"),
		],
		"nets": [{"name": "OVL", "pins": ["V1.1", "V2.1"]}],
		"traces": [
			_trace("t_top", "OVL", "top",
				top_b if flip_top else top_a, top_a if flip_top else top_b),
			_trace("t_bot", "OVL", "bottom",
				bot_b if flip_bottom else bot_a, bot_a if flip_bottom else bot_b),
		],
	})


## One pad plus a pad-joined single fill region whose ring is handed in.
func _notched_region_board(ring: Array):
	return _board({
		"components": [
			_part("N1", 10.0, 10.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("N2", 21.0, 10.0, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [{"name": "NTIE", "pins": ["N1.1", "N2.1"]}],
		"zones": [{"id": "zn", "layer": "top", "kind": "copper_pour", "net": "NTIE",
			"outline": _rect_outline(Vector2(19, 8), Vector2(22.5, 12)),
			"fill": [ring]}],
	})


# ── 5. quieting is not hiding ─────────────────────────────────────────────────

func _fanout_board(pad_count: int):
	var parts: Array = []
	var pin_refs: Array = []
	for i in pad_count:
		var ref := "G%d" % (i + 1)
		# A grid, so the MST is a real 2-D tree rather than a line.
		parts.append(_part(ref, 4.0 + 4.0 * float(i % 8), 4.0 + 4.0 * float(i / 8),
			[_smd_pin("1", 0.0, 0.0)]))
		pin_refs.append("%s.1" % ref)
	return _board({
		"components": parts,
		"nets": [{"name": "BIGGND", "pins": pin_refs}],
	})


func _run_quieting_is_not_hiding() -> void:
	print("-- 5. a high-fanout net goes quiet, and says how much is left --")
	var result := Ratsnest.compute(_fanout_board(20))
	var rows := _rows_by_net(result)
	check("the high-fanout net is reported", rows.has("BIGGND"))
	var row: Dictionary = rows.get("BIGGND", {})

	# (a) QUIETING DOES NOT CHANGE THE REPORTED ARITHMETIC. Twenty unjoined
	# lands are twenty islands, which is nineteen joins, whatever is drawn.
	check_eq("twenty unjoined lands are twenty islands", int(row.get("islands", -1)), 20)
	check_eq("…and nineteen joins still to make", int(row.get("remaining", -1)), 19)
	check("the net is marked quieted", bool(row.get("quieted", false)))
	check("the reported count is the FULL remainder, not the drawn count",
		int(row.get("remaining", -1)) > int(row.get("shown", -1)))
	check_eq("only the shortest handful are drawn",
		_links_for(result, "BIGGND").size(), int(row.get("shown", -1)))
	check("the quieted net appears in the legend rows",
		result.get("quieted", []).size() == 1)

	# (b) NOTHING GOES UNREPRESENTED. Every island is either an endpoint of a
	# drawn airwire or carries a marker. Counted through the pad REFS, so it does
	# not depend on island numbering.
	var represented := {}
	for l in _links_for(result, "BIGGND"):
		represented[str((l as Dictionary)["a_ref"])] = true
		represented[str((l as Dictionary)["b_ref"])] = true
	var marked := {}
	for m in result.get("markers", []):
		if str((m as Dictionary)["net"]) == "BIGGND":
			marked[str((m as Dictionary)["ref"])] = true
	var overlap := 0
	for r in marked:
		if represented.has(r):
			overlap += 1
		represented[r] = true
	check_eq("every one of the twenty unresolved lands is drawn on or marked",
		represented.size(), 20)
	check_eq("a land already on a drawn airwire is never ALSO marked", overlap, 0)

	# (c) THE BOUNDARY, from both sides, stated against the constant rather than
	# a literal.
	var at_threshold := Ratsnest.compute(_fanout_board(Ratsnest.QUIET_ABOVE_LINKS + 1))
	var below: Dictionary = _rows_by_net(at_threshold).get("BIGGND", {})
	check_eq("a net needing exactly QUIET_ABOVE_LINKS joins is NOT quieted",
		int(below.get("remaining", -1)), Ratsnest.QUIET_ABOVE_LINKS)
	check("…and draws every one of them",
		not bool(below.get("quieted", true))
			and _links_for(at_threshold, "BIGGND").size() == Ratsnest.QUIET_ABOVE_LINKS)

	var over := Ratsnest.compute(_fanout_board(Ratsnest.QUIET_ABOVE_LINKS + 2))
	var over_row: Dictionary = _rows_by_net(over).get("BIGGND", {})
	check("one more join than that IS quieted",
		bool(over_row.get("quieted", false))
			and _links_for(over, "BIGGND").size() == Ratsnest.QUIET_SHOWN_LINKS)


# ── 6. the canvas seam ────────────────────────────────────────────────────────

func _run_canvas_seam() -> void:
	print("-- 6. capture agrees with the screen; the cache follows the copper --")
	var d = _connectivity_board()
	var canvas = PcbCanvasScript.new()
	canvas.data = d
	canvas.zoom = 8.0

	var live: Dictionary = canvas._ratsnest()
	check("the canvas answer is the module's answer",
		_picture(live) == _picture(Ratsnest.compute(d)))

	# A capture copy shares the board by reference and computes its own answer
	# (the ratsnest is derived, so it is NOT in the mirrored set — see
	# CAPTURE_MIRRORED_FIELDS). The two answers must be the same picture.
	var copy = PcbCanvasScript.new()
	copy.data = d
	canvas.mirror_capture_state_onto(copy)
	check("a capture copy draws the same ratsnest as the screen",
		_picture(copy._ratsnest()) == _picture(live))
	check("the ratsnest VIEW flag is mirrored onto the capture",
		"show_ratsnest" in canvas.CAPTURE_MIRRORED_FIELDS)
	canvas.show_ratsnest = false
	var copy2 = PcbCanvasScript.new()
	copy2.data = d
	canvas.mirror_capture_state_onto(copy2)
	check("…so turning it off on screen turns it off in the capture",
		copy2.show_ratsnest == false)
	canvas.show_ratsnest = true

	# THE LIVE-DRAG CACHE TEST. _apply_drag_delta writes component.position
	# directly and takes no history snapshot, so board_revision does NOT move
	# during a drag. Dragging U2 five millimetres off the end of its trace
	# breaks the join, and the cache has to follow.
	check_eq("before the drag, SIG_JOINED needs no joins",
		_remaining(canvas._ratsnest(), "SIG_JOINED"), 0)
	var revision_before: int = d.board_revision
	d.get_component("U2").position += Vector2(5.0, 0.0)
	check_eq("a live drag does not bump board_revision (the trap this guards)",
		d.board_revision, revision_before)
	check_eq("dragging the pad off its trace end brings the airwire back",
		_remaining(canvas._ratsnest(), "SIG_JOINED"), 1)
	d.get_component("U2").position -= Vector2(5.0, 0.0)
	check_eq("dragging it back onto the trace removes the airwire again",
		_remaining(canvas._ratsnest(), "SIG_JOINED"), 0)

	# The keyboard binding: N stays the ratsnest toggle.
	var before: bool = canvas.show_ratsnest
	canvas._handle_key_input(_key(KEY_N))
	check("N toggles the ratsnest", canvas.show_ratsnest == (not before))
	canvas._handle_key_input(_key(KEY_N))
	check("…and toggles it back", canvas.show_ratsnest == before)

	# Canvases are Nodes and none of these is in a tree, so free them here
	# rather than leaving three orphans in the runner's output.
	canvas.free()
	copy.free()
	copy2.free()


func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev


# ── 7. a pour conducts as its compiled fill ───────────────────────────────────

## Two 1x1mm lands 10mm apart under one authored pour outline. What varies is
## ONLY the `fill` key — the compiled regions — so any difference in the answer
## is attributable to the fill alone.
func _pour_board(zone_extra: Dictionary):
	var zone := {"id": "z1", "layer": "top", "kind": "copper_pour", "net": "PR",
		"outline": _rect_outline(Vector2(8, 8), Vector2(22, 12))}
	for k in zone_extra:
		zone[k] = zone_extra[k]
	return _board({
		"components": [
			_part("P1", 10.0, 10.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("P2", 20.0, 10.0, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [{"name": "PR", "pins": ["P1.1", "P2.1"]}],
		"zones": [zone],
	})


func _run_pour_conducts_as_its_fill() -> void:
	print("-- 7. a pour conducts as its compiled fill, never as its outline --")
	# ORACLE: the compiler is the only thing that knows what a pour conducts —
	# clearance and keepouts can cut one authored outline into regions that do
	# not conduct to each other. So the outline may never stand in for copper:
	# only a carried fill joins anything, and each region is its own conductor.
	check_eq("one fill region covering both lands joins them",
		_remaining(Ratsnest.compute(_pour_board(
			{"fill": [_rect_outline(Vector2(8.5, 8.5), Vector2(21.5, 11.5))]})), "PR"),
		0)

	# The severed pour: the SAME outline compiled into two regions, one under
	# each land. Real same-net copper on both sides, yet no conduction between
	# them — the exact case an outline-as-copper model erases the airwire for.
	var split := Ratsnest.compute(_pour_board({"fill": [
		_rect_outline(Vector2(9, 9), Vector2(11, 11)),
		_rect_outline(Vector2(19, 9), Vector2(21, 11)),
	]}))
	check_eq("two separate fill regions are two conductors — the join is still owed",
		_remaining(split, "PR"), 1)
	var split_links := _links_for(split, "PR")
	check_eq("…and one airwire still asks for it", split_links.size(), 1)
	if split_links.size() == 1:
		# The two regions' facing edges are 8mm apart (x=11 to x=19); the pad
		# centres are 10mm apart. The airwire spans the region gap, proving it
		# aims at the islands' copper rather than at their pad centres.
		check("…spanning the 8mm region gap, not the 10mm pad-centre gap",
			absf(float((split_links[0] as Dictionary)["length"]) - 8.0) < 1e-4)

	check_eq("a pour with NO fill contributes no connection at all",
		_remaining(Ratsnest.compute(_pour_board({})), "PR"), 1)

	check_eq("a fill computed EMPTY contributes no connection either",
		_remaining(Ratsnest.compute(_pour_board({"fill": []})), "PR"), 1)

	# DAMAGED FILL DATA IS NOT COPPER. Each payload below would cover both
	# lands if its damage were repaired (a defaulted coordinate) or skipped (a
	# dropped point or region) — and a plausible-looking shape built that way
	# erases an airwire the designer still needs. ORACLE: the join stays owed,
	# exactly as if the fill were absent.
	var covering := _rect_outline(Vector2(8.5, 8.5), Vector2(21.5, 11.5))

	var with_alien: Array = covering.duplicate()
	with_alien.append("not a point")
	check_eq("a region containing a non-point entry contributes nothing",
		_remaining(Ratsnest.compute(_pour_board({"fill": [with_alien]})), "PR"), 1)

	var with_half_point: Array = covering.duplicate()
	with_half_point.append({"x_mm": 8.5})
	check_eq("a region with a point missing a coordinate contributes nothing",
		_remaining(Ratsnest.compute(_pour_board({"fill": [with_half_point]})), "PR"), 1)

	var with_nan: Array = covering.duplicate()
	with_nan.append({"x_mm": 8.5, "y_mm": NAN})
	check_eq("a region with a non-finite coordinate contributes nothing",
		_remaining(Ratsnest.compute(_pour_board({"fill": [with_nan]})), "PR"), 1)

	# Three collinear points THROUGH both lands: a ring that encloses no
	# copper, yet whose segments would touch both pads if it were believed.
	check_eq("a ring enclosing no area is not a conductor",
		_remaining(Ratsnest.compute(_pour_board({"fill": [[
			{"x_mm": 8.5, "y_mm": 10.0}, {"x_mm": 15.0, "y_mm": 10.0},
			{"x_mm": 21.5, "y_mm": 10.0}]]})), "PR"), 1)

	# The same zero-area construction off the exactly-representable axis: three
	# points on one straight line (6.5 * 0.4 = 13 * 0.2, so the middle point
	# sits ON the chord) whose y values round when narrowed to the engine's
	# vector type. A degeneracy check run AFTER that narrowing, summing in
	# absolute board coordinates, measures the rounding sliver above the cutoff
	# and accepts the ring — and its segments cross both lands, so the join
	# silently closes. ORACLE: zero enclosed area is zero copper wherever the
	# ring sits; the join stays owed.
	check_eq("a zero-area ring at ordinary board coordinates is still not a conductor",
		_remaining(Ratsnest.compute(_pour_board({"fill": [[
			{"x_mm": 8.5, "y_mm": 9.9}, {"x_mm": 15.0, "y_mm": 10.1},
			{"x_mm": 21.5, "y_mm": 10.3}]]})), "PR"), 1)

	# Float64 can hold coordinates that Vector2 cannot. Narrowing the far point
	# below to infinity makes Geometry2D classify both lands inside a triangle
	# whose finite payload contains only P2. A region is usable only when every
	# coordinate remains finite in the geometry type the solver actually reads.
	check_eq("a coordinate that overflows the geometry type rejects the fill",
		_remaining(Ratsnest.compute(_pour_board({"fill": [[
			{"x_mm": 20.0, "y_mm": 10.0}, {"x_mm": 21.0, "y_mm": 10.0},
			{"x_mm": -1e100, "y_mm": 1e100}]]})), "PR"), 1)

	check_eq("one damaged region rejects the WHOLE fill — the intact sibling proves nothing",
		_remaining(Ratsnest.compute(_pour_board({"fill": [covering, 42]})), "PR"), 1)


# ── 8. a pad is not its bounding box ──────────────────────────────────────────

## A component whose single pad has explicit geometry (the editor-authored
## `pads` array path), so the land's SHAPE — not just its size — reaches the
## solver.
func _shaped_part(ref: String, x: float, y: float, pad: Dictionary,
		rotation_deg: float = 0.0) -> Dictionary:
	return {"ref": ref, "footprint": "CUSTOM", "x_mm": x, "y_mm": y,
		"rotation_deg": rotation_deg, "layer": "top",
		"width": 3.0, "height": 3.0, "has_pad_geometry": true,
		"pins": [{"number": "1",
			"x_mm": float((pad.get("position", {}) as Dictionary).get("x", 0.0)),
			"y_mm": float((pad.get("position", {}) as Dictionary).get("y", 0.0))}],
		"pads": [pad]}


func _circle_pad(x: float, y: float, diameter: float) -> Dictionary:
	return {"number": "1", "type": "smd", "shape": "circle",
		"position": {"x": x, "y": y},
		"size": {"width": diameter, "height": diameter},
		"layers": ["F.Cu"]}


func _run_pad_is_not_its_bounding_box() -> void:
	print("-- 8. a circular land is a disc, not the square drawn around it --")
	# ORACLE, hand-derived: a 1.0mm disc at (10,10); a 0.1mm-wide trace starting
	# at (10.45,10.55). Gap to the disc: sqrt(0.45^2+0.55^2) - 0.5 - 0.05
	# = 0.1606mm of bare laminate. Gap to the disc's BOUNDING SQUARE: the corner
	# region puts the same trace 0.05mm from "copper" — within one trace
	# half-width, a false join. The two shapes disagree by 0.16mm; only the disc
	# is the land.
	var d = _board({
		"components": [
			_shaped_part("D1", 10.0, 10.0, _circle_pad(0.0, 0.0, 1.0)),
			_part("D2", 14.0, 10.55, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [{"name": "CIRC", "pins": ["D1.1", "D2.1"]}],
		"traces": [
			_trace("t_corner", "CIRC", "top",
				Vector2(10.45, 10.55), Vector2(14.0, 10.55), 0.1),
		],
	})
	check_eq("a trace crossing only the phantom bounding-box corner does NOT join the disc",
		_remaining(Ratsnest.compute(d), "CIRC"), 1)

	# The control from the other side: the same construction with the trace
	# start moved to (10.35,10.35) — 0.495mm from the centre, inside the disc's
	# 0.55mm reach (radius + trace half-width) — must join, so the fix cannot
	# have shrunk the land below its real copper.
	var joined = _board({
		"components": [
			_shaped_part("D3", 10.0, 10.0, _circle_pad(0.0, 0.0, 1.0)),
			_part("D4", 14.0, 10.35, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [{"name": "CIRC2", "pins": ["D3.1", "D4.1"]}],
		"traces": [
			_trace("t_disc", "CIRC2", "top",
				Vector2(10.35, 10.35), Vector2(14.0, 10.35), 0.1),
		],
	})
	check_eq("a trace genuinely reaching the disc still joins it",
		_remaining(Ratsnest.compute(joined), "CIRC2"), 0)


# ── 9. a pad's own rotation is part of its shape ──────────────────────────────

## A 2.4 x 0.6 pad at local offset (2,0) with pad-local rotation 90, on a
## component itself rotated 90. Hand-derived, in the KiCad CW convention the
## component transform uses: the component turn maps the offset (2,0) to
## (0,-2), so the land centres at comp+(0,-2); the two 90-degree turns compose
## to 180 for the body, so the long axis ends up HORIZONTAL, spanning
## x centre±1.2, y centre±0.3.
##
## The fixture separates every wrong composition: unrotated-pad models leave
## the body VERTICAL; models that turn the offset by the pad's own rotation
## put the centre at comp+(-2,0) instead.
func _rotated_pad() -> Dictionary:
	return {"number": "1", "type": "smd", "shape": "rect",
		"position": {"x": 2.0, "y": 0.0},
		"size": {"width": 2.4, "height": 0.6},
		"rotation": 90.0,
		"layers": ["F.Cu"]}


func _run_pad_rotation_is_part_of_its_shape() -> void:
	print("-- 9. a pad's own rotation survives into the land the solver reads --")
	# Land centre: (20,20) + (0,-2) = (20,18); body horizontal,
	# x 18.8..21.2, y 17.7..18.3.
	var d = _board({
		"components": [
			_shaped_part("R1", 20.0, 20.0, _rotated_pad(), 90.0),
			_part("R2", 28.0, 18.0, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [{"name": "ROTPAD", "pins": ["R1.1", "R2.1"]}],
		"traces": [
			# Ends at (21.1,18): inside the REAL horizontal land, 0.8mm clear
			# of where an unrotated pad's copper would stop.
			_trace("t_real_end", "ROTPAD", "top",
				Vector2(28.0, 18.0), Vector2(21.1, 18.0)),
		],
	})
	var comp = d.get_component("R1")
	check_eq("the pad's local rotation survives decode",
		float((comp.pads[0] as Dictionary).get("rotation", 0.0)), 90.0)
	var again = PCBComponent.from_board_dict(comp.to_board_dict())
	check_eq("…and survives a serialize round trip",
		float((again.pads[0] as Dictionary).get("rotation", 0.0)), 90.0)

	check_eq("copper landing on the REAL end of the turned land joins it",
		_remaining(Ratsnest.compute(d), "ROTPAD"), 0)

	# The phantom end: (20,25.1) is inside where the UNROTATED-pad model puts
	# copper (vertical span to y=25.2) and 0.8mm clear of the real land
	# (y 23.7..24.3 around centre (20,24)).
	var phantom = _board({
		"components": [
			_shaped_part("R3", 20.0, 26.0, _rotated_pad(), 90.0),
			_part("R4", 28.0, 25.1, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [{"name": "ROTPAD2", "pins": ["R3.1", "R4.1"]}],
		"traces": [
			_trace("t_phantom_end", "ROTPAD2", "top",
				Vector2(28.0, 25.1), Vector2(20.0, 25.1)),
		],
	})
	check_eq("copper landing on the PHANTOM unrotated end does not join",
		_remaining(Ratsnest.compute(phantom), "ROTPAD2"), 1)


# ── 10. an airwire aims at the island's copper ────────────────────────────────

func _run_airwire_aims_at_island_copper() -> void:
	print("-- 10. an airwire lands on the nearest copper, not the nearest pad centre --")
	# A1 and A2 are joined by a 30mm trace; A3 sits 2mm above its midpoint. The
	# nearest copper of the joined island to A3 is the trace at (20,40), 2mm
	# away; the nearest PAD CENTRE is A1 at sqrt(15^2+2^2) = 15.13mm. ORACLE:
	# the copper a designer routes to is the trace, and no correct answer can
	# be longer than the 2mm perpendicular.
	var d = _board({
		"components": [
			_part("A1", 5.0, 40.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("A2", 35.0, 40.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("A3", 20.0, 42.0, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [{"name": "AIM", "pins": ["A1.1", "A2.1", "A3.1"]}],
		"traces": [
			_trace("t_span", "AIM", "top", Vector2(5, 40), Vector2(35, 40)),
		],
	})
	var result := Ratsnest.compute(d)
	check_eq("two islands, one join still owed", _remaining(result, "AIM"), 1)
	var links := _links_for(result, "AIM")
	check_eq("…as one airwire", links.size(), 1)
	if links.size() == 1:
		var l := links[0] as Dictionary
		check("the airwire is the 2mm perpendicular onto the trace (got %.3f)"
			% float(l["length"]), absf(float(l["length"]) - 2.0) < 1e-4)
		check("…landing ON the trace at (20,40)",
			(l["a"] as Vector2).is_equal_approx(Vector2(20, 40)))
		check("…from the unjoined pad's centre",
			(l["b"] as Vector2).is_equal_approx(Vector2(20, 42))
				and str(l["b_ref"]) == "A3.1")
		check_eq("…and the copper endpoint is mid-trace, so it names no pad",
			str(l["a_ref"]), "")


# ── 11. a join that needs no layer change beats one that does ─────────────────

## A surface land and a through-hole barrel at the SAME position, one island;
## a far pad on the BOTTOM, the other. The two candidate joins tie on length
## and on witness points; the surface land reaches only the top, the barrel
## reaches every layer. The ref spellings are the fixture's variable.
func _coincident_pads_board(smd_ref: String, tht_ref: String):
	return _board({
		"components": [
			_part(smd_ref, 10.0, 10.0, [_smd_pin("1", 0.0, 0.0)]),
			_part(tht_ref, 10.0, 10.0, [_tht_pin("1", 0.0, 0.0)]),
			_part("F1", 20.0, 10.0, [_smd_pin("1", 0.0, 0.0)], "bottom"),
		],
		"nets": [{"name": "COIN",
			"pins": ["%s.1" % smd_ref, "%s.1" % tht_ref, "F1.1"]}],
	})


func _run_layer_change_tie() -> void:
	print("-- 11. a join that needs no layer change beats one that does --")
	# ORACLE: the island already offers the bottom layer through the barrel at
	# the very same coordinates, so no correct answer reports a layer change —
	# whichever of the two coincident pads' refs sorts first. A tie-break that
	# consults refs before layers picks the surface pad when its ref sorts
	# lower and tells the designer a via is required where none is.
	for names in [["A1", "B1"], ["B1", "A1"]]:
		var smd_ref: String = names[0]
		var tht_ref: String = names[1]
		var result := Ratsnest.compute(_coincident_pads_board(smd_ref, tht_ref))
		var links := _links_for(result, "COIN")
		check_eq("one join owed (smd=%s, tht=%s)" % [smd_ref, tht_ref],
			links.size(), 1)
		if links.size() == 1:
			var l := links[0] as Dictionary
			check("the surviving join needs NO layer change (smd=%s, tht=%s)"
				% [smd_ref, tht_ref], not bool(l["layer_change"]))
			check_eq("…and its near end names the barrel (smd=%s, tht=%s)"
				% [smd_ref, tht_ref], str(l["a_ref"]), "%s.1" % tht_ref)


# ── 12. duplicate pad numbers are distinct lands, one logical pin ────────────

func _explicit_pad(number: String, pad_type: String, shape: String,
		x: float, y: float, layers: Array) -> Dictionary:
	return {"number": number, "type": pad_type, "shape": shape,
		"position": {"x": x, "y": y}, "size": {"width": 1.0, "height": 1.0},
		"layers": layers}


func _duplicate_part(ref: String, x: float, y: float, pads: Array) -> Dictionary:
	return {"ref": ref, "footprint": "CUSTOM", "x_mm": x, "y_mm": y,
		"rotation_deg": 0.0, "layer": "top", "width": 12.0, "height": 3.0,
		"has_pad_geometry": true,
		# load_pad_geometry deliberately rebuilds this logical map from every
		# physical pad, leaving the final duplicate's position as the pin centre.
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}], "pads": pads}


func _duplicate_pad_board(reverse_pads: bool, mixed_layers: bool):
	var pads: Array
	var y := 25.0 if mixed_layers else 10.0
	if mixed_layers:
		pads = [
			_explicit_pad("1", "thru_hole", "rect", 0.0, 0.0, ["*.Cu"]),
			_explicit_pad("1", "smd", "rect", 10.0, 0.0, ["F.Cu"]),
		]
	else:
		pads = [
			_explicit_pad("1", "smd", "rect", 0.0, 0.0, ["F.Cu"]),
			_explicit_pad("1", "smd", "rect", 10.0, 0.0, ["F.Cu"]),
		]
	if reverse_pads:
		pads.reverse()
	var board = _board({
		"components": [
			_duplicate_part("DUP", 10.0, y, pads),
			_part("END", 30.0, y + (0.0 if mixed_layers else 0.4),
				[_smd_pin("1", 0.0, 0.0)], "bottom" if mixed_layers else "top"),
		],
		"nets": [{"name": "DUPNET", "pins": ["DUP.1", "END.1"]}],
		"traces": [
			# The top case touches the second land's body without reaching its
			# centre. The mixed case runs on bottom directly under that top land.
			_trace("t_dup", "DUPNET", "bottom" if mixed_layers else "top",
				Vector2(20.0 if mixed_layers else 19.55,
					y if mixed_layers else y + 0.4),
				Vector2(30.0, y if mixed_layers else y + 0.4), 0.2),
		],
	})
	# The worker's footprint-resolution path calls load_pad_geometry(), whose
	# logical pin map deliberately keeps the final equal-number land's position.
	# Reproduce that enrichment step on this compact board fixture.
	var last_pos: Vector2 = (board.get_component("DUP").pads[1] as Dictionary)["position"]
	board.get_component("DUP").pins["1"] = last_pos
	return board


func _run_duplicate_pad_numbers() -> void:
	print("-- 12. duplicate pad numbers keep per-land geometry and layers --")
	var joined := Ratsnest.compute(_duplicate_pad_board(false, false))
	check_eq("copper on the body of a non-first duplicate land closes the logical pin",
		_remaining(joined, "DUPNET"), 0)
	var extracted := Ratsnest.extract(_duplicate_pad_board(false, false))
	check_eq("both duplicate lands and the other logical pin reach the solver",
		((extracted[0] as Dictionary)["pads"] as Array).size(), 3)
	var one_pin = _board({
		"components": [_duplicate_part("SOLO", 10.0, 15.0, [
			_explicit_pad("1", "smd", "rect", 0.0, 0.0, ["F.Cu"]),
			_explicit_pad("1", "smd", "rect", 10.0, 0.0, ["F.Cu"]),
		])],
		"nets": [{"name": "SOLO_NET", "pins": ["SOLO.1"]}],
	})
	check("two lands of one logical pin do not invent a routable two-pin net",
		Ratsnest.extract(one_pin).is_empty())

	var mixed := Ratsnest.compute(_duplicate_pad_board(false, true))
	check_eq("bottom copper under a top-only duplicate does not borrow the sibling barrel",
		_remaining(mixed, "DUPNET"), 1)
	var links := _links_for(mixed, "DUPNET")
	check_eq("the missing connection remains visible as one airwire", links.size(), 1)
	if links.size() == 1:
		var link := links[0] as Dictionary
		check("the zero-length cue asks for the layer change at the surface land",
			float(link["length"]) < 1e-6)
		check("…and explicitly declares that layer change", bool(link["layer_change"]))

	check("reversing duplicate physical pads changes neither answer nor picture",
		_picture(Ratsnest.compute(_duplicate_pad_board(true, false))) == _picture(joined)
			and _picture(Ratsnest.compute(_duplicate_pad_board(true, true))) == _picture(mixed))


# ── 13. route focus: one locked destination for a trace gesture ───────────────

## Six pads on one net, no copper between them, placed so that every pad's
## nearest neighbour is unique — no two candidates tie, so "the nearest one" has
## exactly one right answer to compare against.
const _STAR_PADS := {
	"S1.1": Vector2(2.0, 2.0), "S2.1": Vector2(6.0, 3.0),
	"S3.1": Vector2(20.0, 4.0), "S4.1": Vector2(21.0, 12.0),
	"S5.1": Vector2(9.0, 20.0), "S6.1": Vector2(34.0, 30.0),
}


func _star_board():
	var parts: Array = []
	var pin_refs: Array = []
	for ref in _STAR_PADS:
		var at: Vector2 = _STAR_PADS[ref]
		parts.append(_part(str(ref).get_slice(".", 0), at.x, at.y,
			[_smd_pin("1", 0.0, 0.0)]))
		pin_refs.append(ref)
	# A second net whose two pads are already joined end to end: nothing left to
	# route, so nothing to focus on.
	parts.append(_part("W1", 4.0, 36.0, [_smd_pin("1", 0.0, 0.0)]))
	parts.append(_part("W2", 14.0, 36.0, [_smd_pin("1", 0.0, 0.0)]))
	return _board({
		"components": parts,
		"nets": [
			{"name": "STAR", "pins": pin_refs},
			{"name": "WHOLE", "pins": ["W1.1", "W2.1"]},
		],
		"traces": [_trace("t_whole", "WHOLE", "top",
			Vector2(4, 36), Vector2(14, 36))],
	})


## The nearest OTHER pad of the star net, measured over pad centres with plain
## arithmetic — the independent answer the focus has to agree with.
func _nearest_star_pad(ref: String) -> Dictionary:
	var here: Vector2 = _STAR_PADS[ref]
	var best_ref := ""
	var best_d := INF
	for other in _STAR_PADS:
		if other == ref:
			continue
		var d: float = here.distance_to(_STAR_PADS[other])
		if d < best_d:
			best_d = d
			best_ref = str(other)
	return {"ref": best_ref, "length": best_d, "at": _STAR_PADS[best_ref]}


## The link list with emphasis stripped — for asserting that receding removed
## nothing, against a picture that deliberately encodes emphasis.
func _link_identities(result: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for link in result.get("links", []):
		var l := link as Dictionary
		out.append("%s %s->%s (%.4f,%.4f)-(%.4f,%.4f)" % [
			str(l["net"]), str(l["a_ref"]), str(l["b_ref"]),
			(l["a"] as Vector2).x, (l["a"] as Vector2).y,
			(l["b"] as Vector2).x, (l["b"] as Vector2).y])
	return out


func _emphases(rows: Array) -> Dictionary:
	var seen := {}
	for row in rows:
		seen[str((row as Dictionary).get("emphasis", ""))] = true
	return seen


func _run_route_focus_is_the_nearest_island() -> void:
	print("-- 13a. the focused destination is the nearest unjoined copper --")
	var d = _star_board()
	var bundles := Ratsnest.extract(d)

	# ORACLE: the nearest other pad, by distance between pad centres, computed
	# here without the solver. A focus that followed the spanning tree, the pin
	# list, or the net's first island would disagree on at least one pad.
	var wrong_target: Array = []
	var wrong_point: Array = []
	var wrong_origin: Array = []
	var wrong_length: Array = []
	for ref in _STAR_PADS:
		var expected := _nearest_star_pad(str(ref))
		var f := Ratsnest.focus(bundles, str(ref))
		if str(f.get("to_ref", "")) != str(expected["ref"]):
			wrong_target.append(ref)
		if not (f.get("b", Vector2.ZERO) as Vector2).is_equal_approx(expected["at"]):
			wrong_point.append(ref)
		if not (f.get("a", Vector2.ZERO) as Vector2).is_equal_approx(_STAR_PADS[ref]):
			wrong_origin.append(ref)
		if absf(float(f.get("length", -1.0)) - float(expected["length"])) > 1e-4:
			wrong_length.append(ref)
	check("every pad is offered its nearest unjoined land (wrong: %s)"
		% str(wrong_target), wrong_target.is_empty())
	check("…at that land's own copper (wrong: %s)" % str(wrong_point),
		wrong_point.is_empty())
	check("…measured from the pad the gesture started on (wrong: %s)"
		% str(wrong_origin), wrong_origin.is_empty())
	check("…and the reported distance is that measured distance (wrong: %s)"
		% str(wrong_length), wrong_length.is_empty())

	# The label has to identify the destination on its own: net, pad, distance.
	check_eq("the label names the net, the destination pad and the distance",
		str(Ratsnest.focus(bundles, "S1.1").get("label", "")),
		"STAR → S2.1 · 4.12 mm")

	check("a pad whose net is already whole is offered nothing",
		Ratsnest.focus(bundles, "W1.1").is_empty())
	check("a ref that is on no pad is offered nothing",
		Ratsnest.focus(bundles, "NOSUCH.1").is_empty())
	check("an empty ref is offered nothing", Ratsnest.focus(bundles, "").is_empty())


func _run_route_focus_aims_at_copper() -> void:
	print("-- 13b. the destination is copper, and it is measured from the pad --")
	# A1 and A2 are joined by a 30mm trace; A3 sits 2mm above its midpoint.
	var d = _board({
		"components": [
			_part("A1", 5.0, 40.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("A2", 35.0, 40.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("A3", 20.0, 42.0, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [{"name": "AIM", "pins": ["A1.1", "A2.1", "A3.1"]}],
		"traces": [_trace("t_span", "AIM", "top", Vector2(5, 40), Vector2(35, 40))],
	})
	var bundles := Ratsnest.extract(d)

	# ORACLE: the closest point on the trace segment, from Godot's own geometry,
	# owing nothing to the ratsnest.
	var foot := Geometry2D.get_closest_point_to_segment(
		Vector2(20, 42), Vector2(5, 40), Vector2(35, 40))
	var from_a3 := Ratsnest.focus(bundles, "A3.1")
	check("the destination is the trace, not the nearest pad centre",
		(from_a3.get("b", Vector2.ZERO) as Vector2).is_equal_approx(foot)
			and absf(float(from_a3.get("length", -1.0)) - 2.0) < 1e-4)
	check("mid-trace copper names no pad of its own…",
		str(from_a3.get("to_ref", "x")) == "")
	check("…so the island is identified by its lowest-sorting pad",
		str(from_a3.get("to_island_ref", "")) == "A1.1")
	check_eq("and the label still says which net, which part and how far",
		str(from_a3.get("label", "")), "AIM → A1.1's copper · 2.00 mm")

	# ORACLE: the distance is the one the designer is about to draw. From A1 the
	# only unjoined copper is A3's land 15.13mm away — the 2mm hop belongs to the
	# other end of A1's own island, and offering it would name a destination this
	# gesture cannot reach in 2mm.
	var from_a1 := Ratsnest.focus(bundles, "A1.1")
	check("a gesture started elsewhere on the island measures from ITS pad",
		str(from_a1.get("to_ref", "")) == "A3.1"
			and absf(float(from_a1.get("length", -1.0))
				- Vector2(5, 40).distance_to(Vector2(20, 42))) < 1e-4)


func _run_route_focus_survives_quieting() -> void:
	print("-- 13c. quieting thins the airwires, never the destination --")
	var d = _fanout_board(20)
	var bundles := Ratsnest.extract(d)
	var solved := Ratsnest.solve(bundles)

	var reached := {}
	for link in _links_for(solved, "BIGGND"):
		reached[str((link as Dictionary)["a_ref"])] = true
		reached[str((link as Dictionary)["b_ref"])] = true
	check("quieting leaves most of this net's pads off every drawn airwire",
		reached.size() < 20)

	# ORACLE: the grid pitch. Every pad in a 4mm grid has a neighbour exactly 4mm
	# away, so any correct destination is 4mm off — including for the pads no
	# drawn airwire touches. A focus read out of the drawn link list would have
	# nothing to offer those.
	var missing: Array = []
	var wrong_length: Array = []
	for i in 20:
		var ref := "G%d.1" % (i + 1)
		var f := Ratsnest.focus(bundles, ref)
		if f.is_empty():
			missing.append(ref)
		elif absf(float(f["length"]) - 4.0) > 1e-4:
			wrong_length.append(ref)
	check("every pad on the quieted net still has a destination (missing: %s)"
		% str(missing), missing.is_empty())
	check("…and each one is the 4mm grid neighbour (wrong: %s)" % str(wrong_length),
		wrong_length.is_empty())


func _run_route_focus_canvas_gesture() -> void:
	print("-- 13d. the canvas locks it for the gesture and leaves nothing behind --")
	var d = _star_board()
	var canvas = PcbCanvasScript.new()
	canvas.data = d
	canvas.zoom = 8.0
	canvas.tool_mode = PcbCanvasScript.ToolMode.TRACE

	# ORACLE (idle): the board's own answer, which the solver produces without
	# any of this. _picture encodes emphasis, so a canvas that dimmed anything
	# with no gesture in progress fails here.
	var idle := canvas.ratsnest_render_plan()
	check("with no gesture the plan is the solved answer, unaltered",
		_picture(idle) == _picture(Ratsnest.compute(d)))
	check("…nothing is receded and no destination is marked",
		_emphases(idle["links"]) == {"normal": true}
			and (idle["focus"] as Dictionary).is_empty())

	canvas._start_trace({"ref": "S1.1", "position": _STAR_PADS["S1.1"], "net": "STAR"})
	var locked: Dictionary = canvas._trace_focus.duplicate()
	check("starting on a pad locks exactly one destination",
		str(locked.get("to_ref", "")) == "S2.1")

	# The gesture continues: waypoints through the real click path, and the
	# rubber-band point the motion handler writes.
	canvas._handle_trace_click(Vector2(4.0, 8.0), false)
	canvas._handle_trace_click(Vector2(6.0, 14.0), false)
	canvas._trace_preview = Vector2(30.0, 30.0)
	canvas._trace_has_preview = true
	check("waypoints and cursor movement do not move it",
		canvas._trace_focus == locked)

	# ORACLE (lock): move the copper the destination was chosen from. The board's
	# answer demonstrably changes; an unlocked focus would change with it — S2 is
	# no longer S1's nearest land once it is 25mm away.
	var before := _picture(canvas._ratsnest())
	d.get_component("S2").position += Vector2(0.0, 25.0)
	check("the underlying answer really did move", _picture(canvas._ratsnest()) != before)
	check("…and the locked destination did not", canvas._trace_focus == locked)

	# ORACLE (recede, do not hide): the same airwires, all of them, at a lower
	# weight — compared against the solver's list with emphasis stripped.
	var during := canvas.ratsnest_render_plan()
	var solved_now := Ratsnest.compute(d)
	check("every airwire the board still owes is still in the picture",
		_link_identities(during) == _link_identities(solved_now))
	check("…and every one of them recedes",
		_emphases(during["links"]) == {"receded": true})
	check("…while the focus is the one thing drawn at full weight",
		str((during["focus"] as Dictionary).get("emphasis", "")) == "focus")

	# An agent's screenshot must not disagree with the screen about any of it.
	check("the focus is registered as draw-affecting state",
		"_trace_focus" in canvas.CAPTURE_MIRRORED_FIELDS)
	var copy = PcbCanvasScript.new()
	copy.data = d
	canvas.mirror_capture_state_onto(copy)
	check("…so a capture copy draws the same focused picture",
		_picture(copy.ratsnest_render_plan()) == _picture(during))

	canvas._cancel_trace_draw(true)
	check("cancelling leaves no focus behind", canvas._trace_focus.is_empty())
	check("…and the board renders as its own answer again",
		_picture(canvas.ratsnest_render_plan()) == _picture(solved_now))

	# Only now, with the gesture over, does a new one see the moved board.
	canvas._start_trace({"ref": "S1.1", "position": _STAR_PADS["S1.1"], "net": "STAR"})
	check("the next gesture picks up the board as it now is",
		str(canvas._trace_focus.get("to_ref", "")) == "S3.1")

	# The commit path tears it down through the same reset.
	canvas._handle_trace_click(Vector2(4.0, 8.0), false)
	canvas._commit_trace()
	check("committing leaves no focus behind", canvas._trace_focus.is_empty())
	check("…and the trace really was committed", d.traces.size() == 2)

	canvas.free()
	copy.free()


# ── 14. a via is copper with extent, anywhere along a run ────────────────────

## The probe pair strapped to the plane by ONE mid-run via — the panel half of
## the worker's own oracle (worker/tests/test_via_copper_credit.py), built from
## the same numbers so the two sides answer one question the same way.
##
## GND's copper is TWO islands: TP1's pair + the plane, and C1/C2 twenty
## millimetres away. The pair reaches the plane only through the 0.8 mm via at
## (8.0, 30.0), which sits at the exact midpoint of their 0.5 mm run, 1.4 mm
## from either end — so nothing about this join is an ENDPOINT fact. The shape
## agreement underneath is pinned by spec/contact cases 200/210.
func _via_strap_board(vias: Array):
	var fill := _rect_outline(Vector2(2, 20), Vector2(30, 40))
	return _board({
		"width_mm": 60.0, "height_mm": 60.0,
		"components": [
			_part("TP1", 8.0, 30.0, [
				{"number": "1", "x_mm": -1.4, "y_mm": 0.0,
					"pad_width_mm": 1.25, "pad_height_mm": 1.75},
				{"number": "2", "x_mm": 1.4, "y_mm": 0.0,
					"pad_width_mm": 1.25, "pad_height_mm": 1.75}]),
			_part("J1", 20.0, 30.0, [
				_tht_pin("1", -2.54, 0.0), _tht_pin("2", 2.54, 0.0)]),
			_part("C1", 45.0, 50.0, [_smd_pin("1", 0.0, 0.0)]),
			_part("C2", 49.0, 50.0, [_smd_pin("1", 0.0, 0.0)]),
		],
		"nets": [{"name": "GND",
			"pins": ["TP1.1", "TP1.2", "J1.1", "J1.2", "C1.1", "C2.1"]}],
		"traces": [
			_trace("t_probe", "GND", "top", Vector2(6.6, 30.0), Vector2(9.4, 30.0), 0.5),
			_trace("t_open", "GND", "top", Vector2(45.0, 50.0), Vector2(49.0, 50.0)),
		],
		"vias": vias,
		"zones": [{"id": "z_gnd", "layer": "bottom", "kind": "copper_pour",
			"net": "GND", "outline": fill, "fill": [fill]}],
	})


func _strap_via(y: float) -> Dictionary:
	return {"id": "v_strap", "x_mm": 8.0, "y_mm": y, "drill_mm": 0.4,
		"diameter_mm": 0.8, "net": "GND",
		"from_layer": "top", "to_layer": "bottom"}


## One board, one via, one end: does that end read as joined?
func _end_on_a_via_board(end_x: float):
	return _board({
		"components": [], "nets": [],
		"traces": [_trace("t", "SIG", "top",
			Vector2(20.0, 10.0), Vector2(end_x, 10.0), 1.0)],
		"vias": [{"id": "v", "x_mm": 10.0, "y_mm": 10.0, "drill_mm": 0.4,
			"diameter_mm": 0.8, "net": "SIG",
			"from_layer": "top", "to_layer": "bottom"}],
	})


func _run_a_via_is_copper_with_extent() -> void:
	print("-- 14. a via is copper with extent, anywhere along a run --")
	check_eq("a via on a run's INTERIOR joins that run to the plane",
		_remaining(Ratsnest.compute(_via_strap_board([_strap_via(30.0)])), "GND"), 1)
	check_eq("…and without it the probe pair is its own island",
		_remaining(Ratsnest.compute(_via_strap_board([])), "GND"), 2)

	# ANTI-CREDIT-EVERYTHING. The same via slid 0.66 mm off the centreline:
	# copper reaches 0.25 mm (half the run) + 0.40 mm (the annulus) = 0.65 mm,
	# so 0.01 mm of laminate is left and the join is still owed. It is also
	# still 1.4 mm from either end of the run, so no endpoint rule saves it.
	check_eq("a via 0.66 mm off the centreline joins nothing",
		_remaining(Ratsnest.compute(
			_via_strap_board([_strap_via(30.66)])), "GND"), 2)

	# THE FREE-END VERB READS THE SAME COPPER. A 1.0 mm run reaches 0.5 mm past
	# its end and the annulus 0.4 mm past the barrel centre, so an end 0.6 mm
	# out is landed and one 1.0 mm out is not — neither of which a bare
	# point-in-disc pick could tell apart, and both of which the worker's
	# dangling credit answers the same way.
	var landed = _end_on_a_via_board(10.6)
	check("a run ending on a via's annulus is NOT a free end",
		landed.trace_end_is_joined("t", landed.TRACE_END_END))
	var clear = _end_on_a_via_board(11.0)
	check("…and one 0.1 mm clear of it still is",
		not clear.trace_end_is_joined("t", clear.TRACE_END_END))
