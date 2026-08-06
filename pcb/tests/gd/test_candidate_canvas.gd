extends SceneTree
## C3 (S3) — CANVAS route-candidate rendering, hit-testing and selection-ladder
## integration (DCR 019f7095c395 Stage 3; GATE 019f70f76c2f INV-4).
##
## ── UN-PARKED at the epoch-C boundary (Station 1, un-park + execute) ───────────
## Moved from pcb/tests/pending/ into pcb/tests/gd/ and added to EXPECTED_SUITES
## — it now runs as part of the normal run-gd-tests.sh sweep.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the
## live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_candidate_canvas.gd
##
## ── THE IMMEDIATE-MODE PROBLEM, AND HOW THIS FILE ANSWERS IT (CANVAS F6) ───────
## pcb_canvas.gd draws in immediate mode: _draw() issues draw_polyline/draw_arc
## calls and creates NO child nodes. There is nothing to count, index or inspect
## after a frame, so "assert the canvas drew N ghosts as children" is not a test
## that can exist here.
##
## The production code is therefore built so that it CAN be tested: the entire
## candidate render is derived by ONE pure function, candidate_draw_items(), and
## _draw_route_candidates() does nothing but walk it issuing draw calls. The click
## pick (_candidate_at) and the drag anchor (_entity_anchor) walk the SAME array.
## Every assertion below is on that draw-source data — which is exactly the data
## the draw path reads, so it is the strongest statement available on this canvas:
##
##     rendered geometry == hit-test geometry == model geometry
##
## ── WHAT IS DELIBERATELY NOT HERE ─────────────────────────────────────────────
## No workspace VERB is exercised (Accept/Commit, Keep/Pin, Reject, Try-again,
## Edit): those are C4a's, and this unit ships only the context-menu SEAM. What is
## asserted about the menu is that the seam offers NO live verb and — critically —
## no Delete item, since _remove_entity refuses KIND_CANDIDATE by design.
## No pixel is asserted. Colour/alpha/dash/marker are asserted as the draw-source
## PROPERTIES that decide them, which is where the styling rule actually lives.
##
## Coverage (10 groups):
##   1. THE FLAG GATE: cutover off (the default) ⇒ the whole surface is inert and
##      the selection ladder is byte-identical to pre-S3.
##   2. GATE FIXTURE: 3-pin multi-pad net, >=2 DISCONNECTED copper paths — draw
##      items == model geometry, and the pick agrees with them point for point.
##   3. TERMINAL DISPOSITIONS never render (incl. the committed double-draw trap).
##   4. GHOST STYLING: real layer colour at ghost alpha, and the four channels
##      (outline / dash / marker / selection) expressed WITHOUT recolouring.
##   5. LAYER FILTER: a hidden layer's ghost neither draws nor picks.
##   6. LADDER RUNG ORDER: candidate above component, and the tie rule.
##   7. CHECKLIST SITES: the deliberate refusals (no sweep, no drag, no delete,
##      not counted) and the deliberate participations (cleared, anchored).
##   8. REDRAW WIRING: the workspace signals the canvas subscribes to, and the
##      two it deliberately does not; plus a real hold and a real stale emission.
##   9. CONTEXT-MENU SEAM: one disabled identity line, no dead verbs, no Delete.
##  10. INV-4, GREP-PROVABLE: the candidate region of pcb_canvas.gd contains no
##      waypoint read at all, and the hint kind refuses a candidate-sourced
##      payload on its waypoint fork.
##
## NUMERIC-COMPARISON RULE for this file (inherited from the C1 suite): every
## numeric assertion is normalised with int()/float() before comparing, and NO
## assertion compares whole Dictionaries/Arrays that may have crossed a JSON
## boundary. Colours are compared with is_equal_approx, never ==.

const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const PcbRouteHintKind := preload("res://../../minerva-plugins/pcb/ui/kinds/pcb_route_hint_kind.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PCBComponent := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")
const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbRoutingCutover := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_cutover.gd")

const CANVAS_SOURCE := "res://../../minerva-plugins/pcb/ui/pcb_canvas.gd"

var _pass := 0
var _fail := 0

# Signal recorders (group 8).
var _rec_held: Array = []
var _rec_validation: Array = []

# Signal recorder (group 12 — Codex 1047 fix round, verdict 7).
var _rec_view_changed: int = 0


func _init() -> void:
	print("=== PCB canvas route-candidate rendering + hit-test (C3/S3) Tests ===\n")
	_run_flag_gate()
	_run_gate_fixture_geometry()
	_run_terminal_dispositions_never_render()
	_run_ghost_styling_channels()
	_run_layer_filter()
	_run_ladder_rung_order()
	_run_checklist_sites()
	_run_redraw_wiring()
	_run_context_menu_seam()
	_run_inv4_no_waypoints()
	_run_stroke_run_merge()
	_run_workspace_repaint_edge()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── assertion helpers (same idiom as the shipped canvas + workspace suites) ────

func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


# ── fixtures ──────────────────────────────────────────────────────────────────

## THE GATE FIXTURE (epoch-C regime rule: multi-pad net, 3+ pins, >=2 DISCONNECTED
## copper paths). Identical geometry to the C1 model suite's _multipad_reply, so
## the two units are asserting the SAME route from opposite ends.
##
## HAND-DERIVED, and every number below is used as an oracle further down:
##   net "N7", one hint carrying width_mm 0.3
##   segments (as the router emits them, KiCad layer names):
##     A  (0,0)  -> (10,0)   F.Cu    ⇒ canonical "top"
##     B  (10,0) -> (10,5)   B.Cu    ⇒ canonical "bottom"
##     C  (50,50)-> (60,50)  F.Cu    ⇒ canonical "top"   ← the DISCONNECTED path
##   vias: one at (10,0), stamped with the default through span ["top","bottom"]
## After ingest at board_revision 4 the workspace mints:
##   candidate cand_1, segments seg_1/seg_2/seg_3, via via_1, all width 0.3
##   (the hint's width_mm), diameter 0.8 (make_via's default).
## A and B share the point (10,0); C shares nothing with either — that is the
## disconnected second path, and NOTHING in the render or the pick may assume the
## three segments form one chain (INV-3).
func _multipad_reply() -> Dictionary:
	return {"routes": [{
		"net": "N7",
		"segments": [
			{"start": [0.0, 0.0], "end": [10.0, 0.0], "layer": "F.Cu"},
			{"start": [10.0, 0.0], "end": [10.0, 5.0], "layer": "B.Cu"},
			{"start": [50.0, 50.0], "end": [60.0, 50.0], "layer": "F.Cu"},
		],
		"vias": [[10.0, 0.0]],
	}]}


func _hint(id: String, net: String) -> Dictionary:
	return {"id": id, "kind_payload": {"net_names": [net], "width_mm": 0.3}}


## A canvas with the GATE candidate ingested and the cutover flag FLIPPED ON.
## Returns [canvas, workspace, cutover, candidate_id].
##
## zoom is PINNED to 10.0 (10 px per mm) because every hit tolerance below is
## hand-derived from it — see _tolerances_at_zoom_10.
func _armed_canvas() -> Array:
	var ws = PcbRoutingWorkspace.new()
	var cutover = PcbRoutingCutover.new()
	var cid: String = str(ws.ingest_routing_result(_multipad_reply(), [_hint("h7", "N7")], 4)[0])
	var canvas = PcbCanvasScript.new()
	canvas.zoom = 10.0
	canvas.set_routing_workspace(ws, cutover)
	# The flip asserts a workspace-backed WRITE path, which is what C4a delivers.
	# A TEST may assert it because the test IS the write path here: it drives the
	# workspace directly. Production code must not flip it until C4a lands.
	cutover.set_workspace_authoritative("canvas", true)
	return [canvas, ws, cutover, cid]


## THE TOLERANCE ORACLE, hand-derived once at zoom 10.0 and reused by every pick
## assertion below. Read the production constants' definitions, not their values,
## if this ever drifts:
##   segment tolerance = width/2 + CANDIDATE_HIT_SLACK_PX / zoom
##                     = 0.30/2 + 4.0/10.0  = 0.15 + 0.40 = 0.55 mm
##   via radius        = max(diameter/2, CANDIDATE_VIA_HIT_RADIUS_PX / zoom)
##                     = max(0.8/2, 6.0/10.0) = max(0.40, 0.60) = 0.60 mm
## So, perpendicular to segment A ((0,0)->(10,0)):
##   0.50 mm off  → HIT      (0.50 <= 0.55)
##   0.60 mm off  → MISS     (0.60 >  0.55)
## And along the +x axis past the via at (10,0):
##   (10.50, 0)   → inside BOTH the via disc (0.50 <= 0.60) and segment B's
##                  tolerance (0.50 <= 0.55) ⇒ the VIA wins (documented tie rule)
##   (10.65, 0)   → outside both (0.65 > 0.60 and 0.65 > 0.55) ⇒ MISS
const SEG_TOL_MM := 0.55
const VIA_RADIUS_MM := 0.60


func _items_of_kind(items: Array, kind: String) -> Array:
	var out: Array = []
	for it in items:
		if str(it.get("item_kind", "")) == kind:
			out.append(it)
	return out


func _item_by_id(items: Array, item_id: String) -> Dictionary:
	for it in items:
		if str(it.get("item_id", "")) == item_id:
			return it
	return {}


# ── 1. the flag gate ──────────────────────────────────────────────────────────

func _run_flag_gate() -> void:
	print("-- 1. cutover flag OFF ⇒ the whole candidate surface is inert --")
	var ws = PcbRoutingWorkspace.new()
	var cutover = PcbRoutingCutover.new()
	var cid: String = str(ws.ingest_routing_result(_multipad_reply(), [_hint("h7", "N7")], 4)[0])
	check("fixture really did ingest a candidate", not cid.is_empty())
	check("every cutover surface starts annotation-authoritative",
		cutover.all_annotation_authoritative())

	var canvas = PcbCanvasScript.new()
	canvas.zoom = 10.0
	canvas.set_routing_workspace(ws, cutover)

	check_eq("no draw items while the canvas surface is annotation-authoritative",
		canvas.candidate_draw_items().size(), 0)
	check_eq("no pick while the flag is off — a point ON the ghost",
		canvas._candidate_at(Vector2(5.0, 0.0)), "")
	check_eq("_entity_at returns empty space over the ghost while the flag is off",
		str(canvas._entity_at(Vector2(5.0, 0.0))[0]), "")

	# A canvas with a workspace but NO cutover must read as OFF, never as ON: the
	# coordinator's own fail-safe rule ("an unrecognised surface can never be
	# treated as migrated"), applied to a canvas nobody wired a coordinator into.
	var bare = PcbCanvasScript.new()
	bare.zoom = 10.0
	bare.set_routing_workspace(ws, null)
	check_eq("workspace WITHOUT a cutover reads as OFF (fail-safe, not ON)",
		bare.candidate_draw_items().size(), 0)

	# And a canvas with neither is exactly a pre-S3 canvas.
	var naked = PcbCanvasScript.new()
	naked.zoom = 10.0
	check_eq("an unwired canvas produces no items", naked.candidate_draw_items().size(), 0)
	check_eq("an unwired canvas picks nothing", naked._candidate_at(Vector2(5.0, 0.0)), "")

	# Flipping ON is what makes the SAME canvas start drawing — proving the gate
	# is the flag and not a missing fixture.
	cutover.set_workspace_authoritative("canvas", true)
	check_eq("flipping the canvas surface ON produces 3 segments + 1 via",
		canvas.candidate_draw_items().size(), 4)
	# And rolling back closes it again, one surface at a time.
	cutover.rollback("canvas")
	check_eq("rollback closes the surface again", canvas.candidate_draw_items().size(), 0)

	canvas.free()
	bare.free()
	naked.free()


# ── 2. GATE fixture: rendered == hit-tested == model ──────────────────────────

func _run_gate_fixture_geometry() -> void:
	print("-- 2. GATE 3-pin fixture: draw items == model geometry == pick geometry --")
	var acc := _armed_canvas()
	var canvas = acc[0]
	var ws = acc[1]
	var cid: String = str(acc[3])
	var cand = ws.get_candidate(cid)

	var items: Array = canvas.candidate_draw_items()
	check_eq("one candidate ⇒ 4 draw items (3 segments + 1 via)", items.size(), 4)
	check_eq("3 of them are segments", _items_of_kind(items, "segment").size(), 3)
	check_eq("1 of them is a via", _items_of_kind(items, "via").size(), 1)
	check("segments are emitted BEFORE the via (paint order: vias land on top)",
		str(items[0]["item_kind"]) == "segment" and str(items[3]["item_kind"]) == "via")

	# ── geometry identity: item points ARE the model's points ─────────────────
	# Exact equality is the right oracle here (not is_equal_approx): the items
	# carry the model's own Vector2 values, in BOARD MM, uncopied and
	# unconverted. Any drift at all — a screen conversion, a rounding, a
	# flattening — is a real defect, so this must be exact.
	var seg_items: Array = _items_of_kind(items, "segment")
	check_eq("model really holds 3 independent segments", cand.segments.size(), 3)
	var all_match := true
	for i in range(3):
		var model_seg: Dictionary = cand.segments[i]
		var item: Dictionary = seg_items[i]
		if str(item["item_id"]) != str(model_seg["id"]):
			all_match = false
		if str(item["layer"]) != str(model_seg["layer"]):
			all_match = false
		if not is_equal_approx(float(item["width"]), float(model_seg["width"])):
			all_match = false
		var mp: Array = model_seg["points"]
		var ip: Array = item["points"]
		if mp.size() != ip.size():
			all_match = false
		else:
			for k in range(mp.size()):
				if (mp[k] as Vector2) != (ip[k] as Vector2):
					all_match = false
	check("every segment item is its model segment, field for field, point for point",
		all_match)

	# Hand-derived expectations, spelled out so a wrong ingest cannot pass by
	# merely agreeing with itself.
	check_eq("seg 1 id", str(seg_items[0]["item_id"]), "seg_1")
	check_eq("seg 1 layer is canonical top (F.Cu ⇒ top)", str(seg_items[0]["layer"]), "top")
	check("seg 1 points are (0,0)->(10,0)",
		(seg_items[0]["points"][0] as Vector2) == Vector2(0.0, 0.0)
		and (seg_items[0]["points"][1] as Vector2) == Vector2(10.0, 0.0))
	check_eq("seg 2 layer is canonical bottom (B.Cu ⇒ bottom)", str(seg_items[1]["layer"]), "bottom")
	check("seg 3 is the DISCONNECTED path at (50,50)->(60,50)",
		(seg_items[2]["points"][0] as Vector2) == Vector2(50.0, 50.0)
		and (seg_items[2]["points"][1] as Vector2) == Vector2(60.0, 50.0))
	check("widths came from the hint (0.3mm), not a default",
		is_equal_approx(float(seg_items[0]["width"]), 0.3))

	# INV-3: no chain assumption. Segment 3 shares NO endpoint with 1 or 2, and
	# the render treats it as a first-class item anyway.
	var touches := false
	for a in (seg_items[2]["points"] as Array):
		for b in (seg_items[0]["points"] as Array) + (seg_items[1]["points"] as Array):
			if (a as Vector2) == (b as Vector2):
				touches = true
	check("the fixture really is DISCONNECTED (seg 3 shares no endpoint)", not touches)

	var via_item: Dictionary = _items_of_kind(items, "via")[0]
	check_eq("via id", str(via_item["item_id"]), "via_1")
	check("via geometry is a single point at (10,0)",
		(via_item["points"] as Array).size() == 1
		and (via_item["points"][0] as Vector2) == Vector2(10.0, 0.0))
	check("via colour authority is its from_layer (top)", str(via_item["layer"]) == "top")
	check("via width carries the DIAMETER (0.8), not a stroke width",
		is_equal_approx(float(via_item["width"]), 0.8))

	# ── the pick agrees with the draw, point for point ────────────────────────
	# Every hit below is derived from the ITEMS' own geometry, so this is
	# literally "is what is drawn what is clickable".
	check_eq("a point ON segment 1 picks the candidate",
		canvas._candidate_at(Vector2(5.0, 0.0)), cid)
	check_eq("a point ON the DISCONNECTED segment 3 picks the SAME candidate",
		canvas._candidate_at(Vector2(55.0, 50.0)), cid)
	check_eq("a point ON segment 2 (the bottom-layer leg) picks it",
		canvas._candidate_at(Vector2(10.0, 2.5)), cid)
	check_eq("0.50mm off segment 1 HITS (tolerance is 0.55mm at zoom 10)",
		canvas._candidate_at(Vector2(5.0, 0.5)), cid)
	check_eq("0.60mm off segment 1 MISSES",
		canvas._candidate_at(Vector2(5.0, 0.6)), "")
	check_eq("empty board between the two paths picks nothing",
		canvas._candidate_at(Vector2(30.0, 30.0)), "")

	# THE TIE RULE, asserted as stated in _candidate_at's doc: inside the via
	# disc the VIA answers, and 0.65mm out both claims lapse.
	check_eq("(10.5,0) is inside the via disc AND segment B's tolerance ⇒ picks",
		canvas._candidate_at(Vector2(10.5, 0.0)), cid)
	check_eq("(10.65,0) is outside both ⇒ misses",
		canvas._candidate_at(Vector2(10.65, 0.0)), "")

	# The BOUNDS half of the same claim: the drag anchor reads the same source.
	check_eq("_entity_anchor(candidate) is the first point of the first item",
		canvas._entity_anchor(canvas.KIND_CANDIDATE, cid), Vector2(0.0, 0.0))
	check_eq("_entity_anchor of an unknown candidate is the documented ZERO fallback",
		canvas._entity_anchor(canvas.KIND_CANDIDATE, "cand_nope"), Vector2.ZERO)

	canvas.free()


# ── 3. terminal dispositions never render ─────────────────────────────────────

func _run_terminal_dispositions_never_render() -> void:
	print("-- 3. only proposed/pinned render; terminal dispositions never do --")
	var acc := _armed_canvas()
	var canvas = acc[0]
	var ws = acc[1]
	var cid: String = str(acc[3])

	check_eq("proposed renders", canvas.candidate_draw_items().size(), 4)

	check("pin() is legal from proposed", ws.pin(cid))
	check_eq("pinned STILL renders (it is a live draft, not a terminal state)",
		canvas.candidate_draw_items().size(), 4)

	# ── the COMMITTED DOUBLE-DRAW TRAP ────────────────────────────────────────
	# A committed candidate's copper is on the board and is drawn by _draw_traces
	# from PCBData as REAL copper. If the ghost drew too, the same route would be
	# painted twice — brighter and thicker, reading as an overlap that is not
	# one. The board IS the display of a committed candidate.
	check("mark_committed lands", ws.mark_committed(cid, ["trace_1"], ["via_1"]))
	check_eq("committed produces ZERO draw items (no double-draw)",
		canvas.candidate_draw_items().size(), 0)
	check_eq("and therefore cannot be picked either",
		canvas._candidate_at(Vector2(5.0, 0.0)), "")

	# uncommit is the compensating exit (board undo) — the ghost comes back,
	# restored to the disposition it held before the commit.
	check("uncommit restores it", ws.uncommit(cid))
	check_eq("uncommitted (back to pinned) renders again",
		canvas.candidate_draw_items().size(), 4)

	check("reject() is legal from pinned", ws.reject(cid))
	check_eq("rejected produces ZERO draw items", canvas.candidate_draw_items().size(), 0)

	# SUPERSEDED: a re-propose on the same task retires the prior generation. The
	# retired one must not draw — two answers to one task, drawn on top of each
	# other over the same ground, is unreadable.
	var ws2 = PcbRoutingWorkspace.new()
	var cutover2 = PcbRoutingCutover.new()
	var canvas2 = PcbCanvasScript.new()
	canvas2.zoom = 10.0
	canvas2.set_routing_workspace(ws2, cutover2)
	cutover2.set_workspace_authoritative("canvas", true)
	var first: String = str(ws2.ingest_routing_result(_multipad_reply(), [_hint("h7", "N7")], 4)[0])
	var second: String = str(ws2.ingest_routing_result(_multipad_reply(), [_hint("h7", "N7")], 4)[0])
	check("the re-propose really minted a second candidate", first != second and not second.is_empty())
	check_eq("the superseded prior is not drawn — only the new generation is (4 items)",
		canvas2.candidate_draw_items().size(), 4)
	var drawn_ids := {}
	for it in canvas2.candidate_draw_items():
		drawn_ids[str(it["candidate_id"])] = true
	check("and every drawn item belongs to the NEW candidate",
		drawn_ids.has(second) and not drawn_ids.has(first))

	canvas.free()
	canvas2.free()


# ── 4. ghost styling: the four channels, never a recolour ─────────────────────

func _run_ghost_styling_channels() -> void:
	print("-- 4. ghost styling: layer colour + alpha, and the four channels --")
	var acc := _armed_canvas()
	var canvas = acc[0]
	var ws = acc[1]
	var cid: String = str(acc[3])

	# HAND-DERIVED colour oracle:
	#   trace_top_color    = Color(0.9, 0.3, 0.3, 1.0)  → ghost Color(0.9,0.3,0.3,0.45)
	#   trace_bottom_color = Color(0.3, 0.5, 0.9, 1.0)  → ghost Color(0.3,0.5,0.9,0.45)
	#   CANDIDATE_GHOST_ALPHA = 0.45
	var items: Array = canvas.candidate_draw_items()
	var top_item: Dictionary = _item_by_id(items, "seg_1")
	var bottom_item: Dictionary = _item_by_id(items, "seg_2")
	var via_item: Dictionary = _item_by_id(items, "via_1")

	check("the top-layer ghost is the REAL top trace colour at ghost alpha",
		(top_item["color"] as Color).is_equal_approx(Color(0.9, 0.3, 0.3, 0.45)))
	check("the bottom-layer ghost is the REAL bottom trace colour at ghost alpha",
		(bottom_item["color"] as Color).is_equal_approx(Color(0.3, 0.5, 0.9, 0.45)))
	check("top and bottom ghosts are DIFFERENT colours — a layer change is visible",
		not (top_item["color"] as Color).is_equal_approx(bottom_item["color"] as Color))
	check("the ghost colour matches the canvas's own committed-copper colour, RGB for RGB",
		is_equal_approx((top_item["color"] as Color).r, canvas.trace_top_color.r)
		and is_equal_approx((top_item["color"] as Color).g, canvas.trace_top_color.g)
		and is_equal_approx((top_item["color"] as Color).b, canvas.trace_top_color.b))
	check("alpha is REDUCED (that is the whole 'ghost' — the colour is not)",
		(top_item["color"] as Color).a < 1.0)
	check("the via takes its from_layer's colour",
		(via_item["color"] as Color).is_equal_approx(Color(0.9, 0.3, 0.3, 0.45)))

	# Resting state: no channel is asserted.
	check("proposed + unchecked ⇒ no outline, no dash, no marker, not selected",
		not bool(top_item["outlined"]) and not bool(top_item["dashed"])
		and not bool(top_item["marked"]) and not bool(top_item["selected"]))

	# ── CHANNEL 1: PINNED ⇒ OUTLINE, and the colour does not move ─────────────
	check("pin lands", ws.pin(cid))
	var pinned_items: Array = canvas.candidate_draw_items()
	var pinned_top: Dictionary = _item_by_id(pinned_items, "seg_1")
	check("pinned sets the OUTLINE flag on every item of the candidate",
		bool(pinned_top["outlined"]) and bool(_item_by_id(pinned_items, "via_1")["outlined"]))
	check("THE RULE: pinning did NOT change the stroke colour by one bit",
		(pinned_top["color"] as Color).is_equal_approx(top_item["color"] as Color))
	check("pinning did not turn on the dash or the marker either",
		not bool(pinned_top["dashed"]) and not bool(pinned_top["marked"]))

	# ── CHANNEL 2: STALE ⇒ DASH ───────────────────────────────────────────────
	# rebase() marks only the candidates whose base_board_revision differs. The
	# fixture was ingested at revision 4, so rebasing to 5 stales it.
	var marked_ids: Array = ws.rebase(5)
	check("rebase to a NEW revision marked exactly this candidate stale",
		marked_ids.size() == 1 and str(marked_ids[0]) == cid)
	check_eq("the model says stale", str(ws.get_candidate(cid).validation), "stale")
	var stale_items: Array = canvas.candidate_draw_items()
	var stale_top: Dictionary = _item_by_id(stale_items, "seg_1")
	check("stale sets the DASH flag", bool(stale_top["dashed"]))
	check("THE RULE again: staling did NOT change the stroke colour",
		(stale_top["color"] as Color).is_equal_approx(top_item["color"] as Color))
	check("a stale PINNED candidate carries BOTH channels (they are independent)",
		bool(stale_top["dashed"]) and bool(stale_top["outlined"]))
	check("it is still rendered — stale is a warning, not a removal",
		stale_items.size() == 4)

	# ── CHANNEL 3: VIOLATING ⇒ MARKER ─────────────────────────────────────────
	ws.set_validation(cid, "violating")
	var bad_items: Array = canvas.candidate_draw_items()
	var bad_top: Dictionary = _item_by_id(bad_items, "seg_1")
	check("violating sets the MARKER flag", bool(bad_top["marked"]))
	check("and drops the dash — validation is ONE axis, not a set of flags",
		not bool(bad_top["dashed"]))
	check("THE RULE once more: a violation did NOT recolour the copper",
		(bad_top["color"] as Color).is_equal_approx(top_item["color"] as Color))
	ws.set_validation(cid, "error")
	check("the 'error' validation marks too (same channel, same meaning to a reader)",
		bool(_item_by_id(canvas.candidate_draw_items(), "seg_1")["marked"]))

	# ── CHANNEL 4: SELECTION, and it is not any of the other three ────────────
	ws.set_validation(cid, "clean")
	canvas.selected_candidate_ids.append(cid)
	var sel_items: Array = canvas.candidate_draw_items()
	var sel_top: Dictionary = _item_by_id(sel_items, "seg_1")
	check("selection sets its own flag on every item of the candidate",
		bool(sel_top["selected"]) and bool(_item_by_id(sel_items, "via_1")["selected"]))
	check("selection did not recolour the ghost either",
		(sel_top["color"] as Color).is_equal_approx(top_item["color"] as Color))

	# ── SAME-LAYER OVERLAP self-highlights by ACCUMULATION ────────────────────
	# The mechanism is one draw call per segment at CANDIDATE_GHOST_ALPHA, so two
	# same-layer ghosts crossing composite to a denser colour. What is assertable
	# on draw-source data is the precondition: overlapping segments on the same
	# layer are SEPARATE items carrying the SAME sub-1.0 alpha (never merged, and
	# never pre-multiplied into one opaque stroke).
	var same_layer: Array = []
	for it in sel_items:
		if str(it["item_kind"]) == "segment" and str(it["layer"]) == "top":
			same_layer.append(it)
	check("the two top-layer segments are two SEPARATE draw items", same_layer.size() == 2)
	check("both carry the same reduced alpha, so a crossing composites to a denser line",
		is_equal_approx((same_layer[0]["color"] as Color).a, (same_layer[1]["color"] as Color).a)
		and (same_layer[0]["color"] as Color).a < 1.0)

	canvas.free()


# ── 5. the layer filter ───────────────────────────────────────────────────────

func _run_layer_filter() -> void:
	print("-- 5. a ghost on a filtered-out layer neither draws nor picks --")
	var acc := _armed_canvas()
	var canvas = acc[0]
	var cid: String = str(acc[3])

	check_eq("with the filter at 'all', 4 items", canvas.candidate_draw_items().size(), 4)

	canvas.trace_layer_filter = "top"
	var top_only: Array = canvas.candidate_draw_items()
	# HAND-DERIVED: seg_1 (top) + seg_3 (top) + via_1 (vias are board-wide, like
	# the committed-via draw, because a via spans layers by definition) = 3.
	check_eq("filtering to 'top' drops the bottom-layer segment (3 items left)",
		top_only.size(), 3)
	var layers := {}
	for it in top_only:
		layers[str(it["layer"])] = true
	check("no bottom-layer segment survives the filter", not layers.has("bottom"))
	check("the VIA survives — it spans layers by definition, so it has no single one to hide on",
		_items_of_kind(top_only, "via").size() == 1)

	check_eq("a point on the HIDDEN bottom leg no longer picks (pick == draw)",
		canvas._candidate_at(Vector2(10.0, 2.5)), "")
	check_eq("a point on a VISIBLE top leg still picks",
		canvas._candidate_at(Vector2(5.0, 0.0)), cid)

	canvas.trace_layer_filter = "bottom"
	check_eq("filtering to 'bottom' leaves the bottom segment + the via",
		canvas.candidate_draw_items().size(), 2)
	check_eq("and the top leg stops picking", canvas._candidate_at(Vector2(5.0, 0.0)), "")

	# The view flag is the OTHER gate, and it is separate from show_traces on
	# purpose: hiding committed copper must not hide the proposal against it.
	canvas.trace_layer_filter = "all"
	canvas.show_traces = false
	check_eq("hiding COMMITTED copper does not hide the ghosts",
		canvas.candidate_draw_items().size(), 4)
	canvas.show_route_candidates = false
	check_eq("show_route_candidates=false stops the PICK",
		canvas._candidate_at(Vector2(5.0, 0.0)), "")

	canvas.free()


# ── 6. the ladder rung ────────────────────────────────────────────────────────

## A board carrying ONE component whose body sits ON segment 1 of the fixture.
## PCBComponent's default local_bounds is Rect2(-1.27, -1.27, 5.0, 2.5), so a
## component at (5,0) covers x∈[3.73, 8.73], y∈[-1.27, 1.23] — and the point
## (5,0) is inside it AND on the ghost. That coincidence is the whole test.
func _data_with_part_under_the_ghost():
	var data = PCBData.new()
	var comp = PCBComponent.new()
	comp.id = "U1"
	comp.position = Vector2(5.0, 0.0)
	data.add_component(comp)
	return data


func _run_ladder_rung_order() -> void:
	print("-- 6. selection ladder: the candidate rung sits above component --")
	var acc := _armed_canvas()
	var canvas = acc[0]
	var cutover = acc[2]
	var cid: String = str(acc[3])
	canvas.data = _data_with_part_under_the_ghost()

	# Sanity: the component really is pickable at that point on its own.
	check_eq("the component is under (5,0)", canvas._component_at(Vector2(5.0, 0.0)), "U1")

	var hit: Array = canvas._entity_at(Vector2(5.0, 0.0))
	check_eq("_entity_at prefers the CANDIDATE over the component beneath it",
		str(hit[0]), canvas.KIND_CANDIDATE)
	check_eq("...and returns that candidate's id", str(hit[1]), cid)

	# THE TIE RULE: the claim is tight. One millimetre off the ghost — still well
	# inside the component's body (y=1.0 is inside [-1.27, 1.23]) — and the
	# component wins again.
	var off: Array = canvas._entity_at(Vector2(5.0, 1.0))
	check_eq("1.0mm off the ghost (still inside the part) picks the COMPONENT",
		str(off[0]), canvas.KIND_COMPONENT)
	check_eq("...namely U1", str(off[1]), "U1")

	# And with the surface rolled back, the very same click resolves exactly as
	# it did before this unit existed — the "flag off ⇒ no behaviour change"
	# claim, asserted rather than assumed.
	cutover.rollback("canvas")
	var pre_s3: Array = canvas._entity_at(Vector2(5.0, 0.0))
	check_eq("flag off ⇒ the same click picks the component, exactly as pre-S3",
		str(pre_s3[0]), canvas.KIND_COMPONENT)

	# ── WHERE THE ANNOTATION RUNG IS, and why it is not asserted here ─────────
	# Annotations claim the press BEFORE _entity_at is ever called
	# (_claim_annotation_press, rung 0 of _handle_mouse_button), so the candidate
	# rung cannot outrank them by construction: a claimed press returns before
	# this function runs. That ordering is exercised end-to-end by the armed
	# sections of test_pcb_canvas_input_probe.gd, which mount a real overlay in a
	# real Window; re-deriving it from a model-level fixture here would assert a
	# reimplementation instead of the shipped path.
	check("the ladder order is annotation > candidate > component, by construction",
		canvas.has_method("_claim_annotation_press") and canvas.has_method("_candidate_at"))

	canvas.free()


# ── 7. the extension checklist's deliberate refusals ─────────────────────────

func _run_checklist_sites() -> void:
	print("-- 7. checklist sites: what a candidate does, and what it refuses --")
	var acc := _armed_canvas()
	var canvas = acc[0]
	var ws = acc[1]
	var cid: String = str(acc[3])
	canvas.data = _data_with_part_under_the_ghost()

	# PARTICIPATES: the selection set.
	canvas._add_to_selection(canvas.KIND_CANDIDATE, cid)
	check("_selection_of routes the kind to its own list",
		canvas._selection_of(canvas.KIND_CANDIDATE).size() == 1)
	check("is_entity_selected sees it", canvas.is_entity_selected(canvas.KIND_CANDIDATE, cid))
	check_eq("the public singular getter answers", canvas.get_selected_candidate_id(), cid)
	check_eq("the list getter answers too", canvas.get_selected_candidates().size(), 1)

	# REFUSES: the board count, so no board batch is ever opened for a ghost.
	check_eq("selection_count() stays BOARD-only — a ghost does not open a delete batch",
		canvas.selection_count(), 0)
	check("has_selection() is therefore false with only a candidate selected",
		not canvas.has_selection())

	# PARTICIPATES: the clear. A plain click elsewhere must not leave a ghost lit.
	canvas._clear_selection()
	check_eq("_clear_selection drops the candidate selection too",
		canvas.get_selected_candidate_id(), "")

	# REFUSES: movement.
	canvas._add_to_selection(canvas.KIND_CANDIDATE, cid)
	canvas._capture_drag_origins()
	check("a candidate is never captured for a drag — not even as an empty bucket",
		not canvas._drag_origins.has(canvas.KIND_CANDIDATE))
	var before: Vector2 = ws.get_candidate(cid).segments[0]["points"][0]
	canvas._apply_drag_delta(Vector2(3.0, 3.0))
	check("...so a delta cannot move its geometry",
		(ws.get_candidate(cid).segments[0]["points"][0] as Vector2) == before)

	# REFUSES: deletion, through all three doorways.
	check("_remove_entity refuses KIND_CANDIDATE (the fail-closed third layer)",
		not canvas._remove_entity(canvas.KIND_CANDIDATE, cid))
	check("the ERASER doorway is refused too — a board tool may not discard a proposal",
		not canvas._delete_picked_entity(canvas.KIND_CANDIDATE, cid, "Erase"))
	check("the candidate survives every delete attempt", ws.get_candidate(cid) != null)
	canvas._delete_selection()
	check("...including the trash-can batch", ws.get_candidate(cid) != null)

	# REFUSES: the lock concept (the per-segment `locked` flag is the ROUTER's).
	check("a candidate reports unlocked — the segment `locked` flag is not a UI lock",
		not canvas._is_entity_locked(canvas.KIND_CANDIDATE, cid))
	ws.get_candidate(cid).segments[0]["locked"] = true
	check("...and a router-locked segment still does not make the entity locked",
		not canvas._is_entity_locked(canvas.KIND_CANDIDATE, cid))

	# REFUSES: the marquee.
	canvas._clear_selection()
	canvas.box_select_start = Vector2(0.0, 0.0)
	canvas.box_select_end = Vector2(400.0, 400.0)
	canvas._finalize_box_selection()
	check_eq("a marquee over the whole board sweeps NO candidate",
		canvas.get_selected_candidate_id(), "")

	# NAMES ITSELF: the action label, even though nothing deletes it today.
	check_eq("the kind has a noun for any future verb label",
		canvas._entity_action_label("Reject", canvas.KIND_CANDIDATE, cid),
		"Reject route candidate")

	canvas.free()


# ── 8. redraw wiring ──────────────────────────────────────────────────────────

func _on_held(task_id: String, held_id: String, reason: String) -> void:
	_rec_held.append({"task_id": task_id, "held": held_id, "reason": reason})


func _on_validation(id: String) -> void:
	_rec_validation.append(id)


func _run_redraw_wiring() -> void:
	print("-- 8. workspace → canvas redraw wiring --")
	var acc := _armed_canvas()
	var canvas = acc[0]
	var ws = acc[1]
	var cid: String = str(acc[3])

	# ── WHY THIS IS ASSERTED AS A CONNECTION, NOT AS A REDRAW COUNT ───────────
	# CanvasItem.queue_redraw() sets an internal flag with no public reader, and
	# it is a native method a GDScript subclass may not override. There is
	# therefore no way to count redraw REQUESTS directly. What IS observable —
	# and what actually has to be true — is in two halves, and both are asserted:
	#   (a) the canvas is subscribed to the signal, with the handler that redraws;
	#   (b) the workspace really emits that signal on the event in question.
	# (a) and (b) together are the whole claim.
	var handler := Callable(canvas, "_on_workspace_changed")
	for sig in ["candidate_added", "candidate_changed", "candidate_removed",
			"validation_changed", "ingest_task_held"]:
		check("canvas is subscribed to %s" % sig, ws.is_connected(sig, handler))

	# The two that are deliberately NOT connected. A refused transition left the
	# value unchanged by contract and a task state is derived bookkeeping — neither
	# moves a pixel, so subscribing would buy a redraw per refusal and prove
	# nothing. Asserted so a later "connect everything" tidy-up has to argue.
	check("transition_refused is deliberately NOT connected (no pixel moves)",
		not ws.is_connected("transition_refused", handler))
	check("task_state_changed is deliberately NOT connected (derived bookkeeping)",
		not ws.is_connected("task_state_changed", handler))

	# (b) — the emissions really happen, on the two events the brief names.
	ws.ingest_task_held.connect(_on_held)
	ws.validation_changed.connect(_on_validation)

	# HOLD: pin the candidate, then re-ingest the same route. C1's adjudicated
	# behaviour is that the batch HOLDS the task rather than superseding a pin —
	# so the frame after must still show the pinned prior, not a replacement.
	check("pin lands", ws.pin(cid))
	var again: Array = ws.ingest_routing_result(_multipad_reply(), [_hint("h7", "N7")], 4)
	check_eq("the held ingest created NO candidate", again.size(), 0)
	check_eq("ingest_task_held fired exactly once", _rec_held.size(), 1)
	check_eq("...naming the held candidate", str(_rec_held[0]["held"]), cid)
	check_eq("...with the named reason", str(_rec_held[0]["reason"]), ws.HOLD_PINNED)
	check_eq("and the canvas still draws the PINNED prior, not a phantom replacement",
		canvas.candidate_draw_items().size(), 4)
	check("the drawn ghost is still outlined (still pinned)",
		bool(_item_by_id(canvas.candidate_draw_items(), "seg_1")["outlined"]))

	# STALE: a rebase emits validation_changed, which the canvas is subscribed to.
	_rec_validation.clear()
	var staled: Array = ws.rebase(9)
	check_eq("rebase staled exactly one candidate", staled.size(), 1)
	check_eq("validation_changed fired for it", _rec_validation.size(), 1)
	check_eq("...naming the candidate", str(_rec_validation[0]), cid)
	check("and the next derivation carries the dash",
		bool(_item_by_id(canvas.candidate_draw_items(), "seg_1")["dashed"]))

	# REBINDING: a second set_routing_workspace must not leave the first
	# workspace connected — a stale subscription would redraw this canvas for a
	# board it is no longer showing.
	var ws2 = PcbRoutingWorkspace.new()
	canvas.set_routing_workspace(ws2, acc[2])
	check("rebinding disconnected the OLD workspace",
		not ws.is_connected("candidate_added", handler))
	check("...and connected the new one", ws2.is_connected("candidate_added", handler))
	canvas.set_routing_workspace(null, null)
	check("unbinding disconnects it too", not ws2.is_connected("candidate_added", handler))
	check_eq("and an unbound canvas draws nothing", canvas.candidate_draw_items().size(), 0)

	canvas.free()


# ── 9. the context-menu seam ──────────────────────────────────────────────────

func _run_context_menu_seam() -> void:
	print("-- 9. context menu: the C4a seam, not a menu of dead verbs --")
	var acc := _armed_canvas()
	var canvas = acc[0]
	var ws = acc[1]
	var cid: String = str(acc[3])
	canvas.data = _data_with_part_under_the_ghost()
	# The menu is built in _ready(); build it directly for a free-floating canvas.
	canvas._create_context_menu()

	# The right-press resolves its target through the SAME ladder the left press
	# uses — that is why the candidate rung lives in _entity_at rather than in a
	# private branch of _handle_mouse_button.
	canvas._context_menu_target = canvas._entity_at(Vector2(5.0, 0.0))
	canvas.context_menu_world_pos = Vector2(5.0, 0.0)
	check_eq("the right-press target is the candidate",
		str(canvas._context_menu_target[0]), canvas.KIND_CANDIDATE)

	canvas._update_context_menu_for_selection()
	var labels: Array = []
	# Scan ONLY the seam section — the contiguous run of candidate items from
	# index 0. The ladder appends board-entity items (e.g. "Lock U1") after the
	# seam, and those are legitimately enabled; counting them made the
	# zero-enabled assertion below impossible (review finding, C3).
	var enabled_count := 0
	var in_seam := true
	for i in range(canvas.context_menu.item_count):
		var text: String = canvas.context_menu.get_item_text(i)
		labels.append(text)
		if in_seam and not text.contains("andidate"):
			in_seam = false
		if in_seam and not canvas.context_menu.is_item_disabled(i):
			enabled_count += 1

	check("the seam names the candidate and its state",
		labels.size() >= 1 and str(labels[0]).begins_with("Route candidate %s" % cid))
	check("...including the disposition", str(labels[0]).contains("proposed"))
	check("the identity line is DISABLED — it is information, not an action",
		canvas.context_menu.is_item_disabled(0))
	var has_delete := false
	for l in labels:
		if str(l).contains("Delete") or str(l).contains("Erase"):
			has_delete = true
	check("NO Delete item is offered — it would look live and do nothing",
		not has_delete)
	check("no LIVE verb is offered at all yet (C4a fills the seam)",
		enabled_count == 0)
	check("and the '(no actions)' stub is not added on top of the seam",
		not ("(no actions)" in labels))

	# The label carries validation too, once it says something.
	ws.set_validation(cid, "violating")
	check("a validating candidate's line names the validation as well",
		canvas._candidate_menu_label(cid).contains("violating"))
	ws.set_validation(cid, "clean")
	check("a CLEAN candidate's line does not clutter itself with 'clean'",
		not canvas._candidate_menu_label(cid).contains("clean"))
	check("a vanished candidate degrades to a bare label, never an error",
		canvas._candidate_menu_label("cand_gone") == "Route candidate cand_gone")

	canvas.free()


# ── 10. INV-4, grep-provable ─────────────────────────────────────────────────

func _run_inv4_no_waypoints() -> void:
	print("-- 10. INV-4: no waypoint read anywhere in the candidate path --")

	var f := FileAccess.open(CANVAS_SOURCE, FileAccess.READ)
	check("pcb_canvas.gd is readable for the source scan", f != null)
	if f == null:
		return
	var src := f.get_as_text()
	f.close()

	# THE REGION SCAN. The candidate render/hit/bounds path is one contiguous,
	# named region; this reads that region's text and asserts no CODE line in it
	# reads a waypoint. It is the same claim a reviewer's grep makes, made
	# executable so it cannot silently stop being true.
	#
	# COMMENT LINES ARE STRIPPED FIRST, and that is the correct oracle rather than
	# a convenience: the region's own doc block is where the ban is WRITTEN DOWN
	# ("EXACT GEOMETRY, NEVER WAYPOINTS"), so a raw text scan would be red exactly
	# because the rule is documented. What INV-4 forbids is a waypoint READ, and a
	# read lives in code.
	var start := src.find("#region Route Candidates")
	check("the candidate region exists and is named", start >= 0)
	if start < 0:
		return
	var stop := src.find("#endregion", start)
	check("the region is terminated", stop > start)
	var region := src.substr(start, stop - start)
	check("the region is substantial (it is the whole render + pick path)",
		region.length() > 2000)

	var code_lines: Array = []
	for raw_line in region.split("\n"):
		var stripped := str(raw_line).strip_edges()
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		code_lines.append(stripped)
	check("the region has real code in it, not only prose", code_lines.size() > 100)
	var offenders: Array = []
	for code_line in code_lines:
		if str(code_line).to_lower().contains("waypoint"):
			offenders.append(code_line)
	check("THE INV-4 CLAIM: no CODE line in the candidate region reads a waypoint (%s)"
			% ("clean" if offenders.is_empty() else str(offenders)),
		offenders.is_empty())
	check("the region really does read exact segment geometry instead",
		region.contains("cand.segments") and region.contains("cand.vias"))

	# The three functions the claim is about are all inside that region — so the
	# scan above covers the render, the pick AND the bounds/anchor derivation.
	for fn in ["func candidate_draw_items", "func _candidate_at", "func _draw_route_candidates"]:
		check("%s lives inside the scanned region" % fn, region.contains(fn))
	# _entity_anchor is the one candidate-path function that lives OUTSIDE the
	# region (it is a checklist site, so it belongs with its siblings). Assert its
	# candidate branch reads the same source rather than anything waypoint-shaped.
	# Scoped to the FUNCTION BODY, not to a fixed character window. This read
	# `src.substr(anchor_at, 1800)` when it was authored (C3); C4a/C5 added the
	# KIND_VIA and KIND_CUTOUT branches with their own doc blocks ABOVE
	# KIND_CANDIDATE, which pushed the candidate branch to offset ~2049 — past
	# the window. The suite then reported an INV-4 violation that was not one:
	# the branch still reads candidate_draw_items(), it had just moved. A window
	# that has to be re-tuned every time a sibling branch gains a comment is a
	# fixture that fails on edits it does not care about, so bound the slice by
	# the next top-level `func` instead — the function's real extent.
	var anchor_at := src.find("func _entity_anchor")
	check("the anchor function exists", anchor_at >= 0)
	if anchor_at < 0:
		return
	var anchor_end := src.find("\nfunc ", anchor_at + 1)
	if anchor_end < 0:
		anchor_end = src.length()
	var anchor_body := src.substr(anchor_at, anchor_end - anchor_at)
	check("the anchor's candidate branch reads candidate_draw_items()",
		anchor_body.contains("candidate_draw_items()"))
	# Non-vacuous: the slice really is only _entity_anchor, not the rest of the
	# file (which of course also mentions candidate_draw_items).
	check("the slice is _entity_anchor's own body and stops at the next func",
		anchor_body.contains("KIND_CANDIDATE") and anchor_body.length() < 4000)

	# ── BEHAVIOURAL PIN (boundary polish, epoch C): the source scan above proves
	# the branch READS candidate_draw_items(); it does not prove the branch
	# tracks that source's own filtering. Drive it: hide segment 0's layer
	# ("top", segment A (0,0)->(10,0)) via the layer filter, so the first item
	# candidate_draw_items() still yields is segment B (bottom, (10,0)->(10,5))
	# — _entity_anchor must follow, landing on segment B's first point rather
	# than staying pinned to segment A's. Uses the same GATE fixture as group 2.
	var acc10 := _armed_canvas()
	var canvas10 = acc10[0]
	var cid10: String = str(acc10[3])
	canvas10.trace_layer_filter = "bottom"
	check_eq("filtering out segment 0's layer leaves segment B as the first item",
		_items_of_kind(canvas10.candidate_draw_items(), "segment")[0]["item_id"], "seg_2")
	check_eq("_entity_anchor follows the filtered draw order onto segment B's first point",
		canvas10._entity_anchor(canvas10.KIND_CANDIDATE, cid10), Vector2(10.0, 0.0))
	canvas10.free()

	# And with the cutover flag OFF (canvas surface annotation-authoritative,
	# never flipped), candidate_draw_items() is empty and _entity_anchor must
	# fall back to the documented ZERO rather than reading stale/model geometry.
	var ws11 = PcbRoutingWorkspace.new()
	var cutover11 = PcbRoutingCutover.new()
	var cid11: String = str(ws11.ingest_routing_result(_multipad_reply(), [_hint("h7", "N7")], 4)[0])
	var canvas11 = PcbCanvasScript.new()
	canvas11.zoom = 10.0
	canvas11.set_routing_workspace(ws11, cutover11)
	check_eq("cutover flag off ⇒ _entity_anchor is the documented ZERO fallback",
		canvas11._entity_anchor(canvas11.KIND_CANDIDATE, cid11), Vector2.ZERO)
	canvas11.free()

	# ── THE OTHER HALF OF THE FENCE: the hint kind refuses to serve a candidate ─
	# The waypoint fork in pcb_route_hint_kind.gd stays, because HINTS legitimately
	# have nothing but waypoints. What it must never do is flatten a candidate.
	check("the hint kind knows what a candidate-sourced payload looks like",
		PcbRouteHintKind._is_candidate_sourced({"candidate_id": "cand_1"}))
	check("...by either declared key",
		PcbRouteHintKind._is_candidate_sourced({"workspace_candidate_id": "cand_1"}))
	check("a plain HINT payload is NOT candidate-sourced (the fork stays open to it)",
		not PcbRouteHintKind._is_candidate_sourced(
			{"layer": "F.Cu", "waypoints": [[0, 0], [1, 1]]}))
	check("an empty marker does not count as a marker",
		not PcbRouteHintKind._is_candidate_sourced({"candidate_id": ""}))
	check("the refusal names the offending key AND its value",
		PcbRouteHintKind._candidate_marker_of({"candidate_id": "cand_7"}) == "candidate_id=cand_7")


# ── 11. draw-time stroke-run merge (docket 019fce3a9b6d) ──────────────────────
#
# _merged_candidate_stroke_items chains CONSECUTIVE same-candidate/-layer/-width
# segment items whose endpoints coincide into one polyline item, so the draw
# joins bends the way _draw_single_trace's whole-chain call does for committed
# copper. DRAW ONLY: candidate_draw_items() itself stays per-segment (asserted
# here against the GATE fixture), so the pick/anchor walks are untouched.

func _seg_item(cid: String, layer: String, width: float, pts: Array) -> Dictionary:
	return {"candidate_id": cid, "item_kind": "segment", "item_id": "",
		"layer": layer, "points": pts, "width": width,
		"color": Color.WHITE, "outlined": false, "dashed": false,
		"marked": false, "selected": false}


func _run_stroke_run_merge() -> void:
	print("-- 11. stroke-run merge: bends join, nothing else fuses --")
	var canvas = PcbCanvasScript.new()

	# The positive case: an L-bend on one layer becomes ONE 3-point run.
	var chained: Array = canvas._merged_candidate_stroke_items([
		_seg_item("c1", "top", 0.3, [Vector2(0, 0), Vector2(10, 0)]),
		_seg_item("c1", "top", 0.3, [Vector2(10, 0), Vector2(10, 5)]),
	])
	check_eq("two chained same-layer segments merge to one run", chained.size(), 1)
	check_eq("the run's polyline is the full chained point list",
		chained[0]["points"], [Vector2(0, 0), Vector2(10, 0), Vector2(10, 5)])

	# Every axis that must BREAK the chain, one at a time.
	check_eq("a layer change breaks the run (the via boundary must stay visible)",
		canvas._merged_candidate_stroke_items([
			_seg_item("c1", "top", 0.3, [Vector2(0, 0), Vector2(10, 0)]),
			_seg_item("c1", "bottom", 0.3, [Vector2(10, 0), Vector2(10, 5)]),
		]).size(), 2)
	check_eq("a width change breaks the run",
		canvas._merged_candidate_stroke_items([
			_seg_item("c1", "top", 0.3, [Vector2(0, 0), Vector2(10, 0)]),
			_seg_item("c1", "top", 0.5, [Vector2(10, 0), Vector2(10, 5)]),
		]).size(), 2)
	check_eq("another candidate's segment never joins the run",
		canvas._merged_candidate_stroke_items([
			_seg_item("c1", "top", 0.3, [Vector2(0, 0), Vector2(10, 0)]),
			_seg_item("c2", "top", 0.3, [Vector2(10, 0), Vector2(10, 5)]),
		]).size(), 2)
	check_eq("a real gap (beyond float noise) breaks the run",
		canvas._merged_candidate_stroke_items([
			_seg_item("c1", "top", 0.3, [Vector2(0, 0), Vector2(10, 0)]),
			_seg_item("c1", "top", 0.3, [Vector2(10.5, 0), Vector2(10.5, 5)]),
		]).size(), 2)

	# A via item passes through verbatim and never fuses with anything.
	var with_via: Array = canvas._merged_candidate_stroke_items([
		_seg_item("c1", "top", 0.3, [Vector2(0, 0), Vector2(10, 0)]),
		_seg_item("c1", "top", 0.3, [Vector2(10, 0), Vector2(10, 5)]),
		{"candidate_id": "c1", "item_kind": "via", "item_id": "via_1",
			"layer": "top", "points": [Vector2(10, 0)], "width": 0.8,
			"color": Color.WHITE, "outlined": false, "dashed": false,
			"marked": false, "selected": false},
	])
	check_eq("run + via ⇒ two items", with_via.size(), 2)
	check_eq("the via survives untouched", str(with_via[1]["item_kind"]), "via")

	# The GATE fixture end-to-end: A/B share (10,0) on DIFFERENT layers and C is
	# disconnected, so the merge is a no-op there — and the derivation itself
	# must still be per-segment (the pick's geometry, unmerged).
	var acc := _armed_canvas()
	var canvas12 = acc[0]
	check_eq("gate fixture: derivation stays per-segment for the pick",
		_items_of_kind(canvas12.candidate_draw_items(), "segment").size(), 3)
	check_eq("gate fixture: the merge fuses nothing (layer break + disconnection)",
		_items_of_kind(canvas12._merged_candidate_stroke_items(
			canvas12.candidate_draw_items()), "segment").size(), 3)
	canvas12.free()
	canvas.free()


# ── 12. F2: workspace changes reach the annotation-overlay repaint edge ───────
# (Codex 1047 fix round, verdict 7 — the fix-before half.)
#
# Group 8 proved (a) the canvas is SUBSCRIBED to the workspace signals and
# (b) the workspace really EMITS them. What it never proved is the OTHER half
# of _on_workspace_changed: the relay to view_changed — the same poke pan/zoom/
# fit use to reach the ANNOTATION overlay (PcbAnnotationHost forwards it to the
# base AnnotationHost signal AnnotationOverlay listens on). That relay is what
# keeps a route hint's render-taxonomy mode honest when a workspace-only change
# (propose/reject/supersede) alters the live-candidate answer: without it, a
# rejected candidate left its hint stuck in "markers" with the candidate gone —
# no visible representation of the route at all until an unrelated pan/zoom.
# view_changed IS observable (a plain signal, unlike queue_redraw's private
# flag), so this group asserts the relay directly AND end-to-end.


func _on_view_changed() -> void:
	_rec_view_changed += 1


func _run_workspace_repaint_edge() -> void:
	print("-- 12. F2: workspace change relays to view_changed (repaint edge) --")
	var acc := _armed_canvas()
	var canvas = acc[0]
	var ws = acc[1]
	var cid: String = str(acc[3])

	canvas.view_changed.connect(_on_view_changed)

	# The seam itself, driven directly: ONE handler invocation → exactly ONE
	# view_changed. (The handler is what all five workspace signals share, so
	# this is the relay's whole contract in one call.)
	_rec_view_changed = 0
	canvas._on_workspace_changed()
	check_eq("_on_workspace_changed relays exactly one view_changed", _rec_view_changed, 1)

	# End-to-end via a REAL disposition move: pin(cid) → candidate_changed →
	# _on_workspace_changed → view_changed. Same event order as group 8 (pin
	# before rebase — a stale candidate refuses the pin).
	_rec_view_changed = 0
	check("pin lands (fixture sanity)", ws.pin(cid))
	check("the pin's candidate_changed reached view_changed (>= 1 relay)",
		_rec_view_changed >= 1)

	# End-to-end via a REAL validation event: rebase → validation_changed →
	# view_changed. (Group 8 already proved this emission names cid.)
	_rec_view_changed = 0
	check_eq("rebase staled the candidate (fixture sanity)", ws.rebase(9).size(), 1)
	check("the stale emission reached view_changed (>= 1 relay)",
		_rec_view_changed >= 1)

	# Unbinding severs the whole chain: group 8 proved the workspace-side
	# disconnect; here the view_changed side stays silent through a real
	# emission from the ORPHANED workspace (rebase to yet another revision on
	# ws2-less ws emits nothing canvas-ward once disconnected — drive the
	# signal explicitly so the assertion is not vacuous).
	canvas.set_routing_workspace(null, null)
	_rec_view_changed = 0
	ws.validation_changed.emit(cid)
	check_eq("after unbinding, a workspace emission no longer reaches view_changed",
		_rec_view_changed, 0)

	canvas.free()
