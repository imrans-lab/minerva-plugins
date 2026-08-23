extends SceneTree
## THE RATSNEST: physical connectivity, a spanning tree, and quieting.
## Work item 01a02b5763e87b84a9318b28f7437fa7 (parent DCR 01a02b570e4d).
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_pcb_ratsnest.gd
##
## ── WHAT EACH SECTION'S ORACLE IS ─────────────────────────────────────────────
## Every check below is answerable WITHOUT running the implementation. Where a
## section leans on a hand-built fixture, the fixture's answer is a physical
## fact about the copper it describes; where it leans on an invariant, the
## invariant is a theorem about connectivity that any correct implementation
## must satisfy whatever fixture it is handed. Both kinds are present on
## purpose: a hand-computed fixture only tests what the fixture contains, so a
## fixture too simple would pass a wrong implementation, while an invariant
## holds for every board and therefore cannot be satisfied by accident.
##
##   1. PHYSICAL CONNECTIVITY (fixture). One board, seven nets, each net a
##      separate physical question with a known answer: a routed pair, a pair
##      with a 0.5mm gap, a pair whose only trace is on the wrong side, a
##      through-hole pad reached from the back, a via that changes layers, a
##      pour that joins two pads, and a KEEPOUT that must join nothing.
##      ORACLE: each answer is what a fabricated board would do. None of them
##      is "does this net exist" — net membership is exactly what must NOT
##      decide the answer.
##
##   2. THE EDGE-ADDITION INVARIANT. Joining two SEPARATE islands lowers the
##      count of remaining joins by exactly one; joining two pads ALREADY in
##      the same island lowers it by zero.
##      ORACLE: graph theory. Adding an edge between two connected components
##      merges them (components fall by 1); adding an edge inside one leaves
##      the count alone. It is true of every correct answer on every board, so
##      an implementation that counted traces, or pins, or anything other than
##      islands, fails it.
##
##   3. SPANNING TREE, NOT A CHAIN. Four pads spaced 10mm apart on a line,
##      listed in the net in scrambled order.
##      ORACLE: for equally spaced collinear points the Euclidean MST is
##      provably the chain of ADJACENT pairs — three 10mm links, total 30mm.
##      The renderer this replaces drew pin[i]→pin[i+1] in list order, which on
##      a scrambled list totals more than 30 and contains a link longer than
##      10. Asserted as total length + a per-link ceiling, both derived from
##      the geometry rather than read off the implementation.
##
##   4. DETERMINISM. The same physical board, described twice with every list
##      reversed, must produce the identical picture.
##      ORACLE: two descriptions of one board are one board. Any dependence on
##      Dictionary order, on file order, or on an unstable sort shows up as a
##      difference. (This is the check that would catch a tie broken by
##      iteration order — see the determinism note in pcb_ratsnest.gd.)
##
##   5. QUIETING IS NOT HIDING. A 20-pad unrouted net.
##      ORACLE: two invariants, not a hand-counted picture. (a) the REPORTED
##      remaining count equals islands-1 no matter how many links were drawn —
##      quieting must not change the arithmetic a designer reads; (b) every
##      island is either touched by a drawn link or carries a marker, so no
##      unresolved copper goes unrepresented. Plus the threshold boundary from
##      both sides, which is a statement about the constant, not about a net.
##
##   6. THE CANVAS SEAM. A capture copy draws the same ratsnest as the screen;
##      the cache re-solves when a LIVE DRAG moves copper (a drag mutates
##      component positions WITHOUT bumping board_revision — see
##      pcb_canvas._apply_drag_delta — so a revision-keyed cache would serve a
##      stale picture); and N still toggles the ratsnest.
##      ORACLE: for the capture, two independently computed answers that must
##      agree; for the cache, the physical fact that a pad dragged off the end
##      of its trace is no longer joined to it; for the key, the binding named
##      in the work item.

const Ratsnest := preload("res://../../minerva-plugins/pcb/ui/model/pcb_ratsnest.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
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
## board, so its land exists on EVERY copper layer — which is the whole point
## of the PWR_THT net below.
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
	return d


## net name -> the row solve() reported for it. A net absent from the result is
## a net with nothing left to join, which is a MEANINGFUL answer here, so the
## helper reports remaining = 0 for it rather than hiding the distinction.
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
func _picture(result: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for link in result.get("links", []):
		var l := link as Dictionary
		out.append("link %s %s->%s (%.4f,%.4f)-(%.4f,%.4f)" % [
			str(l["net"]), str(l["a_ref"]), str(l["b_ref"]),
			(l["a"] as Vector2).x, (l["a"] as Vector2).y,
			(l["b"] as Vector2).x, (l["b"] as Vector2).y])
	for marker in result.get("markers", []):
		var m := marker as Dictionary
		out.append("mark %s %s" % [str(m["net"]), str(m["ref"])])
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
			# ROT — a 90-degree part with an OFFSET, ELONGATED land. Placed so
			# the trace below reaches it only if BOTH the pad's offset from the
			# part origin and the pad's own long axis were turned by the part's
			# rotation. Hand-derived: rotating (2,0) by the component transform
			# puts the land's centre at (38,28), and its 3.0 x 0.6 body then
			# spans x 37.7..38.3, y 26.5..29.5 — so a trace ending at (38,27)
			# is on copper. Leave the offset unrotated and the land lands near
			# (40,30) instead, three millimetres away, and the join is lost.
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
			{"id": "z_pour", "layer": "top", "kind": "copper_pour", "net": "POUR",
				"outline": _rect_outline(Vector2(13, 13), Vector2(19, 15))},
			# Carries a net on purpose: what excludes it is that a keepout is
			# not copper. An implementation filtering only on the net name
			# would wrongly join U13.1 and U14.1 here.
			{"id": "z_keep", "layer": "top", "kind": "keepout", "net": "KEEPOUT",
				"outline": _rect_outline(Vector2(13, 27), Vector2(19, 29))},
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
	var tht_ends := PackedStringArray()
	if tht_links.size() == 1:
		tht_ends.append(str((tht_links[0] as Dictionary)["a_ref"]))
		tht_ends.append(str((tht_links[0] as Dictionary)["b_ref"]))
		tht_ends.sort()
	check("…and the airwire names the two lands still apart, not some other pair (%s)"
		% str(tht_ends), tht_ends == PackedStringArray(["U3.1", "U4.1"]))

	check_eq("a via joining a bottom trace to a top land closes the net",
		_remaining(result, "PWR_VIA"), 0)

	check_eq("a copper pour covering two lands on its own layer joins them",
		_remaining(result, "POUR"), 0)

	check_eq("a KEEPOUT is an instruction, not a conductor — it joins nothing",
		_remaining(result, "KEEPOUT"), 1)

	check_eq("a rotated part's offset, elongated land is measured where it is DRAWN",
		_remaining(result, "ROT"), 0)

	# The net-membership trap, stated directly: every net above has exactly two
	# pins, so anything deciding by net membership would answer identically for
	# all eight. Half of them differ. (Written as one assertion over the set so
	# it reads as the claim it is.)
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

	# THE ONE THAT SEPARATES "counts islands" FROM "counts copper": a second
	# trace between two pads ALREADY joined adds copper and adds no
	# connectivity, so the number of joins still needed cannot move.
	_add_trace(d, "INV", "top", Vector2(5, 30), Vector2(10, 30))
	check_eq("a redundant second trace between an already-joined pair changes nothing",
		_remaining(Ratsnest.compute(d), "INV"), 2)

	# …and the mirror of it: copper that bridges the two islands built above
	# merges them, even though neither of its endpoints is a NEW pad.
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

	# The picture is a property of the BOARD, not of the order the net happened
	# to list its pins in.
	var reversed_order := scrambled.duplicate()
	reversed_order.reverse()
	check("reversing the pin list changes nothing about the picture",
		_picture(result) == _picture(Ratsnest.compute(_line_net_board(reversed_order))))


# ── 4. determinism ────────────────────────────────────────────────────────────

func _run_determinism() -> void:
	print("-- 4. the same board draws the same picture every time --")
	var forward := _connectivity_board()
	var picture := _picture(Ratsnest.compute(forward))

	# The SAME physical board, described with every list reversed: components,
	# nets, traces, vias, zones. Nothing about the copper changed, and the spec
	# is the one _connectivity_board() itself loads — not a second hand-typed
	# fixture that could quietly differ.
	var spec := _connectivity_spec()
	for key in ["components", "nets", "traces", "vias", "zones"]:
		var reversed_list: Array = (spec[key] as Array).duplicate()
		reversed_list.reverse()
		spec[key] = reversed_list
	var backward = _board(spec)
	check("a board described in reverse order draws the identical picture",
		_picture(Ratsnest.compute(backward)) == picture)

	# And twice over the same model instance, so nothing carried between runs.
	check("recomputing over the same board is byte-identical",
		_picture(Ratsnest.compute(forward)) == picture)


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

	# (a) THE ARITHMETIC A DESIGNER READS IS UNCHANGED BY QUIETING. Twenty
	# unjoined lands are twenty islands, which is nineteen joins — whatever the
	# renderer chose to draw.
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
	# drawn airwire or carries a marker — which is what makes this quieting
	# rather than hiding. Counted through the pad REFS, so it does not depend
	# on island numbering.
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

	# (c) THE BOUNDARY, from both sides. Stated against the constant rather
	# than a literal, so the test says what the rule IS.
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
	# (the ratsnest is derived, so it is deliberately NOT in the mirrored set —
	# see CAPTURE_MIRRORED_FIELDS). What must hold is that the two answers are
	# the same picture: an agent's screenshot may not disagree with the screen.
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
	# physically breaks the join; a cache keyed on the revision would keep
	# reporting the net as routed while the user watches the pad leave.
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

	# The binding named in the work item: N stays the ratsnest toggle.
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
