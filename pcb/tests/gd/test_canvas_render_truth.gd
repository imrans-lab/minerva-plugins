extends SceneTree
## THE CANVAS MUST NOT SAY COPPER IS SOMEWHERE IT IS NOT.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_canvas_render_truth.gd
##
## Four renderer defects, one theme: each one made the picture disagree with the
## board the fab would make. The canvas draws in immediate mode and these suites
## run headless with no render device, so the observable throughout is the
## sequence of PAINTER CALLS the draw functions dispatch, recorded by the canvas
## subclass that overrides every painter (recording_canvas.gd).
##
##   1. FLIPPED ARTWORK PRINTS ON THE SIDE IT LANDS ON. Component graphics are
##      footprint-LOCAL, exactly like pads[].layers, so flipping a part to the
##      bottom moves its front strokes to B.SilkS and its back strokes to
##      F.SilkS. The renderer asked for the literal string "F.SilkS", so a
##      footprint that authors back legend never drew at all and a flipped
##      part's legend drew in front ink. ORACLE: the fab emitter's own rule,
##      which reads the SAME loose graphic dicts — gerber._harvest_component_
##      graphics, `pre_placed=False`: "F-authored artwork lands on the back,
##      B-authored artwork lands on the front". A renderer that disagrees with
##      it is drawing a board nobody will make.
##
##   2. A HIDDEN COPPER LAYER TAKES ITS LANDS WITH IT. The layer eye gated that
##      layer's traces and not its lands, so a land declared on a hidden layer
##      stayed painted — copper floating on a layer the view says is not there.
##      ORACLE: the traces beside it. Under one filter, on one board, the lands
##      of a layer must appear exactly when that layer's traces do.
##
##   3. A PROPOSED LAND IS THE LAND IT BECOMES. A placement ghost drew a body
##      outline and no copper at all, so the one thing a reviewer judges a move
##      by — where the lands end up — was the one thing the ghost did not show.
##      ORACLE: the committed render of the same part. Ghost and committed lands
##      are compared call for call: same shape, same corner ratio, same size,
##      same board angle, and positions differing by exactly the proposed move.
##      The bottom-side case is hand-derived, because the ghost used to build
##      its own Transform2D with no back-side mirror in it.
##
##   4. A RESOLVED PART DRAWS NO NOMINAL PINS. With lands hidden and pins shown,
##      a part whose real lands ARE known fell through to the nominal marker —
##      a sketch of copper drawn where the real copper is not. ORACLE: the part
##      beside it. On one board, one pass, the unresolved part must produce the
##      nominal marker and the resolved part must produce nothing.

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PCBComponent := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const RecordingCanvas := preload("res://../../minerva-plugins/pcb/tests/gd/recording_canvas.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== canvas render truth: silk sides, layer eyes, ghost lands, nominal pins ===\n")
	_run_flipped_artwork_prints_where_it_lands()
	_run_hidden_layer_takes_its_lands()
	_run_proposed_land_is_the_land_it_becomes()
	_run_resolved_part_draws_no_nominal_pins()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── shared record helpers ─────────────────────────────────────────────────────

## The `count` an artwork record reports for one requested board layer, or -1
## when the renderer never asked for that layer at all.
func _artwork_count(seq: Array, layer: String) -> int:
	for rec in seq:
		var r: Dictionary = rec
		if str(r["kind"]) == "graphics" and str(r["layer"]) == layer:
			return int(r["count"])
	return -1


## The ink an artwork record was drawn in, or a transparent black when absent.
func _artwork_color(seq: Array, layer: String) -> Color:
	for rec in seq:
		var r: Dictionary = rec
		if str(r["kind"]) == "graphics" and str(r["layer"]) == layer:
			return r["color"] as Color
	return Color(0, 0, 0, 0)


## Land/drill records keyed by "<ref>.<pin>". One record per pad per phase, so
## a caller comparing two renders of the same part compares like with like
## whatever order the passes ran in.
func _lands_by_id(seq: Array) -> Dictionary:
	var out := {}
	for rec in seq:
		var r: Dictionary = rec
		if str(r["kind"]) == "land":
			out[str(r["id"])] = r
	return out


## The ids of every land record, in dispatch order.
func _land_ids(seq: Array) -> Array:
	var out: Array = []
	for rec in seq:
		var r: Dictionary = rec
		if str(r["kind"]) == "land":
			out.append(str(r["id"]))
	return out


## An id list as a SET claim — WHICH ids were painted, whatever order they were
## dispatched in. Painter ORDER is a separate question, asserted where it is
## actually the claim.
func _painted(ids: Array) -> Array:
	var out: Array = ids.duplicate()
	out.sort()
	return out


## The ids of every trace record, in dispatch order.
func _trace_ids(seq: Array) -> Array:
	var out: Array = []
	for rec in seq:
		var r: Dictionary = rec
		if str(r["kind"]) == "trace":
			out.append(str(r["id"]))
	return out


## Do two land records describe the same piece of copper — same land, same
## shape, same size, same board angle, same place?
func _same_land(a: Dictionary, b: Dictionary) -> bool:
	return str(a["id"]) == str(b["id"]) \
		and str(a["pad_type"]) == str(b["pad_type"]) \
		and str(a["shape"]) == str(b["shape"]) \
		and a["corner_rratio"] == b["corner_rratio"] \
		and (a["size"] as Vector2).is_equal_approx(b["size"] as Vector2) \
		and is_equal_approx(float(a["rot"]), float(b["rot"])) \
		and (a["pos"] as Vector2).is_equal_approx(b["pos"] as Vector2)


# ── 1. flipped artwork prints on the side it lands on ─────────────────────────

## A part carrying two silk strokes on one authored layer, mounted on `mount`.
## Setting `id` renders the designator strokes, which ride the same rule.
func _silk_part(mount: String, authored_layer: String):
	var comp := PCBComponent.new()
	comp.id = "U1"
	comp.set_footprint_by_name("CUSTOM")
	comp.layer = mount
	comp.graphics = [
		{"layer": authored_layer, "kind": "line", "width": 0.12,
			"start": Vector2(-1.0, -0.5), "end": Vector2(1.0, -0.5)},
		{"layer": authored_layer, "kind": "circle", "width": 0.12,
			"center": Vector2(-1.2, 0.0), "radius": 0.15},
	]
	return comp


## The artwork records _draw_component_silk dispatches for one part.
func _silk_records(comp) -> Array:
	var rec := RecordingCanvas.new()
	rec._draw_component_silk(comp, comp.get_transform())
	var seq: Array = rec.records.duplicate(true)
	rec.free()
	return seq


func _run_flipped_artwork_prints_where_it_lands() -> void:
	print("-- 1. a flipped part's silk prints on the side it lands on --")

	# The placement rule itself, against the emitter's wording.
	var back = _silk_part("bottom", "F.SilkS")
	var front = _silk_part("top", "F.SilkS")
	check_eq("a top-mounted part's F-authored stroke prints on F.SilkS",
		front.placed_graphic_layer({"layer": "F.SilkS"}), "F.SilkS")
	check_eq("a BOTTOM-mounted part's F-authored stroke prints on B.SilkS",
		back.placed_graphic_layer({"layer": "F.SilkS"}), "B.SilkS")
	check_eq("…and its B-authored stroke prints on F.SilkS — the flip goes both "
			+ "ways, exactly as the gerber emitter reads the same dicts",
		back.placed_graphic_layer({"layer": "B.SilkS"}), "F.SilkS")
	check_eq("the rule is the layer token's, not silk's: a courtyard flips too",
		back.placed_graphic_layer({"layer": "F.CrtYd"}), "B.CrtYd")
	check_eq("a token with no side has no side to swap and passes through",
		back.placed_graphic_layer({"layer": "Cmts.User"}), "Cmts.User")

	# THE BUG: the renderer asked for the literal authored name, so this is the
	# artwork that never reached a painter at all.
	var front_seq := _silk_records(front)
	var back_seq := _silk_records(back)
	check_eq("a top-mounted part's strokes are drawn on F.SilkS",
		_artwork_count(front_seq, "F.SilkS"), 2)
	check_eq("…and nothing of it is drawn on the back",
		_artwork_count(front_seq, "B.SilkS"), 0)
	check_eq("THE BUG: the same part flipped to the bottom draws those strokes "
			+ "on B.SilkS", _artwork_count(back_seq, "B.SilkS"), 2)
	check_eq("…and no longer on the front, where the fab does not print them",
		_artwork_count(back_seq, "F.SilkS"), 0)

	# A footprint that authors BACK legend directly: unreachable before, because
	# no draw call ever named B.SilkS.
	var back_authored_on_top := _silk_records(_silk_part("top", "B.SilkS"))
	check_eq("a footprint that authors B.SilkS on a top-mounted part is drawn "
			+ "at last — it was unreachable while only F.SilkS was requested",
		_artwork_count(back_authored_on_top, "B.SilkS"), 2)
	var back_authored_on_bottom := _silk_records(_silk_part("bottom", "B.SilkS"))
	check_eq("…and flipping THAT part moves its legend to the front",
		_artwork_count(back_authored_on_bottom, "F.SilkS"), 2)

	# Ink: back artwork is seen THROUGH the substrate and must not read as if it
	# were on the near face — the reason the canvas has two silk colours.
	var canvas := PcbCanvasScript.new()
	check_eq("front artwork is drawn in the front ink",
		_artwork_color(front_seq, "F.SilkS"), canvas.silk_color)
	check_eq("back artwork is drawn in the back ink, not the front one",
		_artwork_color(back_seq, "B.SilkS"), canvas.silk_back_color)

	# The DESIGNATOR rides the same rule: it is silk printed on the side its
	# part is mounted on (its strokes are rendered on F.SilkS, footprint-local).
	check("the part renders designator strokes at all",
		back.refdes_graphics.size() > 0 and front.refdes_graphics.size() > 0)
	check_eq("a flipped part's designator is back ink",
		canvas._silk_ink(back.placed_graphic_layer(back.refdes_graphics[0])),
		canvas.silk_back_color)
	check_eq("…and a top-mounted part's stays front ink",
		canvas._silk_ink(front.placed_graphic_layer(front.refdes_graphics[0])),
		canvas.silk_color)
	canvas.free()


# ── 2. a hidden copper layer takes its lands with it ──────────────────────────

## A top-mounted part whose footprint declares one land on EACH side, plus one
## trace per layer. The mixed-layer part is the point: a part whose lands all
## sit on its own mount side disappears wholesale with that side
## (_component_visibility), so it can never show the gap.
func _two_sided_board():
	var d := PCBData.new()
	d.from_board_dict({
		"version": 1, "name": "layer-eye", "width_mm": 40.0, "height_mm": 30.0,
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "U1", "footprint": "CUSTOM", "x_mm": 10.0, "y_mm": 10.0,
			 "rotation_deg": 0.0, "layer": "top",
			 "pins": [{"number": "1", "x_mm": -1.0, "y_mm": 0.0},
					  {"number": "2", "x_mm": 1.0, "y_mm": 0.0}],
			 "pads": [
				{"number": "1", "type": "smd", "shape": "rect",
				 "position": {"x": -1.0, "y": 0.0},
				 "size": {"width": 1.0, "height": 1.0}, "layers": ["F.Cu"]},
				{"number": "2", "type": "smd", "shape": "rect",
				 "position": {"x": 1.0, "y": 0.0},
				 "size": {"width": 1.0, "height": 1.0}, "layers": ["B.Cu"]}]},
		],
		"nets": [], "vias": [], "zones": [],
		"traces": [
			{"id": "t_top", "net": "", "layer": "top", "width_mm": 0.25,
			 "points": [{"x_mm": 4.0, "y_mm": 4.0}, {"x_mm": 16.0, "y_mm": 4.0}]},
			{"id": "t_bot", "net": "", "layer": "bottom", "width_mm": 0.25,
			 "points": [{"x_mm": 4.0, "y_mm": 6.0}, {"x_mm": 16.0, "y_mm": 6.0}]}],
	})
	return d


## Every copper record _draw_copper() dispatches for the two-sided board under
## one view setting. `hidden` closes a layer eye; `filter` sets the layer filter.
func _copper_records(hidden: String, filter: String) -> Array:
	var rec := RecordingCanvas.new()
	rec.data = _two_sided_board()
	if not filter.is_empty():
		rec.trace_layer_filter = filter
	if not hidden.is_empty():
		rec.set_layer_hidden(hidden, true)
	rec._draw_copper()
	var seq: Array = rec.records.duplicate(true)
	rec.free()
	return seq


func _run_hidden_layer_takes_its_lands() -> void:
	print("\n-- 2. hiding a copper layer hides its LANDS, not just its traces --")

	var all_visible := _copper_records("", "")
	check_eq("the control: with every layer visible both lands are painted",
		_painted(_land_ids(all_visible)), ["U1.1", "U1.2"])
	check_eq("…and so are both traces",
		_painted(_trace_ids(all_visible)), ["t_bot", "t_top"])

	var bottom_hidden := _copper_records("bottom", "")
	check_eq("THE BUG: with the bottom eye closed, the land DECLARED on B.Cu is "
			+ "no longer painted", _land_ids(bottom_hidden), ["U1.1"])
	check_eq("…which is exactly what happened to that layer's traces all along",
		_trace_ids(bottom_hidden), ["t_top"])

	# The other form the same question takes: an explicit single-layer filter
	# rather than a closed eye. One predicate answers both (_layer_visible), so
	# lands must follow it there too.
	var top_only := _copper_records("", "top")
	check_eq("under a TOP-only filter the bottom land is not painted either",
		_land_ids(top_only), ["U1.1"])
	check_eq("…matching that filter's traces", _trace_ids(top_only), ["t_top"])


# ── 3. a proposed land is the land it becomes ─────────────────────────────────

## A part with two lands a renderer can get WRONG in different ways: a roundrect
## whose corner ratio is authored, and a through-hole barrel. Off-axis in y, so
## a missing back-side mirror shows up as a moved land rather than a no-op.
func _ghost_part(mount: String):
	var comp := PCBComponent.new()
	comp.id = "P1"
	comp.set_footprint_by_name("CUSTOM")
	comp.layer = mount
	comp.position = Vector2(10.0, 8.0)
	comp.rotation = 0.0
	comp.has_pad_geometry = true
	comp.pads = [
		{"number": "1", "type": "smd", "shape": "roundrect",
			"position": Vector2(-1.0, 0.6), "size": Vector2(1.4, 0.9),
			"rotation": 0.0, "drill": Vector2.ZERO, "layers": ["F.Cu"],
			"corner_rratio": 0.25},
		{"number": "2", "type": "thru_hole", "shape": "circle",
			"position": Vector2(1.0, 0.6), "size": Vector2(1.6, 1.6),
			"rotation": 0.0, "drill": Vector2(0.8, 0.8), "layers": ["*.Cu"]},
	]
	return comp


func _run_proposed_land_is_the_land_it_becomes() -> void:
	print("\n-- 3. a placement ghost's lands are the committed lands --")

	var comp = _ghost_part("top")
	var rec := RecordingCanvas.new()

	# The committed render of this part's copper: what accepting the proposal
	# would produce.
	rec._draw_component_pads(comp, PcbCanvasScript.PadSet.SMD,
		PcbCanvasScript.PadPhase.LANDS)
	rec._draw_component_pads(comp, PcbCanvasScript.PadSet.THT,
		PcbCanvasScript.PadPhase.LANDS)
	var committed := _lands_by_id(rec.records.duplicate(true))

	# The ghost, standing at the part's OWN pose: every call must match.
	rec.records.clear()
	rec._draw_staged_lands(comp, comp.position, comp.rotation)
	var ghost := _lands_by_id(rec.records.duplicate(true))

	check_eq("THE BUG: a placement ghost paints lands at all, one per pad",
		ghost.size(), 2)
	check_eq("…the same lands the committed part paints", committed.size(), 2)
	check("the proposed roundrect is the committed roundrect — shape, authored "
			+ "corner ratio, size, angle and place (%s vs %s)"
					% [str(ghost.get("P1.1")), str(committed.get("P1.1"))],
		ghost.has("P1.1") and committed.has("P1.1")
			and _same_land(ghost["P1.1"], committed["P1.1"]))
	check("…and the proposed barrel is the committed barrel",
		ghost.has("P1.2") and committed.has("P1.2")
			and _same_land(ghost["P1.2"], committed["P1.2"]))
	check("the ghost's copper is DIMMED — a proposal must not read as copper "
			+ "the board already has",
		float((ghost["P1.1"] as Dictionary)["alpha"]) < 1.0)
	check_eq("…while the committed land is drawn at full strength",
		float((committed["P1.1"] as Dictionary)["alpha"]), 1.0)

	# The pose is the PROPOSED one: the whole point of a ghost.
	var delta := Vector2(5.0, -3.0)
	rec.records.clear()
	rec._draw_staged_lands(comp, comp.position + delta, comp.rotation)
	var moved := _lands_by_id(rec.records.duplicate(true))
	check("the moved ghost's roundrect is the same copper, exactly `delta` away",
		((moved["P1.1"] as Dictionary)["pos"] as Vector2).is_equal_approx(
			((committed["P1.1"] as Dictionary)["pos"] as Vector2) + delta))
	check("…still the same size and angle after the move",
		((moved["P1.1"] as Dictionary)["size"] as Vector2).is_equal_approx(
			(committed["P1.1"] as Dictionary)["size"] as Vector2)
		and is_equal_approx(float((moved["P1.1"] as Dictionary)["rot"]),
			float((committed["P1.1"] as Dictionary)["rot"])))

	# THE BACK SIDE, hand-derived. A bottom-mounted part's lands are reflected
	# about the footprint's own x axis (pcbnew's flip: local y negates before the
	# rotation), so pad 1 at local (-1.0, 0.6) on a part at (10, 8) is board
	# (9.0, 7.4) — NOT (9.0, 8.6), which is where a ghost transform built
	# without the mirror puts it.
	var flipped = _ghost_part("bottom")
	rec.records.clear()
	rec._draw_staged_lands(flipped, flipped.position, flipped.rotation)
	var flipped_ghost := _lands_by_id(rec.records.duplicate(true))
	check("a BOTTOM-side ghost is mirrored like its part: local (-1.0, 0.6) "
			+ "lands at board (9.0, 7.4), not (9.0, 8.6) (%s)"
					% str((flipped_ghost["P1.1"] as Dictionary)["pos"]),
		((flipped_ghost["P1.1"] as Dictionary)["pos"] as Vector2)
			.is_equal_approx(Vector2(9.0, 7.4)))

	# A paste-only stencil node is not a land, and a ghost that paints one is
	# inventing copper the fab never makes. The committed surface pass reads it
	# through comp.pad_names_copper; the ghost must read it through the same one.
	var stencilled = _ghost_part("top")
	stencilled.pads.append({"number": "3", "type": "smd", "shape": "rect",
		"position": Vector2(0.0, -1.2), "size": Vector2(2.0, 2.0),
		"rotation": 0.0, "drill": Vector2.ZERO, "layers": ["F.Paste", "F.Mask"]})
	var buckets := {}
	rec._bucket_smd_lands(stencilled, buckets)
	var bucketed: Array = []
	for lid in buckets:
		for land in buckets[lid]:
			bucketed.append(str(((land as Dictionary)["pad"] as Dictionary)["number"]))
	rec.records.clear()
	rec._draw_staged_lands(stencilled, stencilled.position, stencilled.rotation)
	var stencil_ghost := _lands_by_id(rec.records.duplicate(true))
	check("the ghost skips the paste-only aperture, exactly as the committed "
			+ "surface pass does (bucketed=%s, ghost=%s)"
					% [str(bucketed), str(stencil_ghost.keys())],
		not bucketed.has("3") and not stencil_ghost.has("P1.3")
			and stencil_ghost.has("P1.1") and stencil_ghost.has("P1.2"))
	rec.free()


# ── 4. a resolved part draws no nominal pins ──────────────────────────────────

## Two parts: one with real resolved lands, one with bare positional pins and no
## pad geometry at all — the part the nominal marker exists for.
func _resolved_and_unresolved_board():
	var d := PCBData.new()
	d.from_board_dict({
		"version": 1, "name": "nominal", "width_mm": 40.0, "height_mm": 30.0,
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "U1", "footprint": "CUSTOM", "x_mm": 10.0, "y_mm": 10.0,
			 "rotation_deg": 0.0, "layer": "top",
			 "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
			 "pads": [{"number": "1", "type": "smd", "shape": "rect",
				"position": {"x": 0.0, "y": 0.0},
				"size": {"width": 1.0, "height": 1.0}, "layers": ["F.Cu"]}]},
			{"ref": "X1", "footprint": "CUSTOM", "x_mm": 20.0, "y_mm": 10.0,
			 "rotation_deg": 0.0, "layer": "top",
			 "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		],
		"nets": [], "traces": [], "vias": [], "zones": [],
	})
	return d


## Which parts reached a land painter, and how. Returns {"lands": [...],
## "nominal": [...]} of component refs.
func _land_sources(show_pads: bool, show_pins: bool) -> Dictionary:
	var rec := RecordingCanvas.new()
	rec.data = _resolved_and_unresolved_board()
	rec.show_pads = show_pads
	rec.show_pins = show_pins
	rec._draw_copper()
	var lands: Array = []
	var nominal: Array = []
	for entry in rec.records:
		var r: Dictionary = entry
		if str(r["kind"]) != "land":
			continue
		if str(r["pad_type"]) == "fallback_pin":
			nominal.append(str(r["id"]))
		else:
			lands.append(str(r["id"]))
	rec.free()
	return {"lands": lands, "nominal": nominal}


func _run_resolved_part_draws_no_nominal_pins() -> void:
	print("\n-- 4. a part whose lands are known never draws nominal pins --")

	var both_on := _land_sources(true, true)
	check_eq("the control: with lands shown, the resolved part paints its real "
			+ "land", both_on["lands"], ["U1.1"])
	check_eq("…and only the part with NO pad geometry gets a nominal marker",
		both_on["nominal"], ["X1"])

	var pads_off := _land_sources(false, true)
	check_eq("THE BUG: with lands hidden and pins shown, the resolved part draws "
			+ "nothing — not a nominal marker where its real copper is",
		pads_off["nominal"], ["X1"])
	check_eq("…and no real land either, which is what hiding them means",
		pads_off["lands"], [])

	var pins_off := _land_sources(true, false)
	check_eq("with pins hidden the unresolved part draws no marker",
		pins_off["nominal"], [])
	check_eq("…while the resolved part's real copper is untouched by that eye",
		pins_off["lands"], ["U1.1"])


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)
