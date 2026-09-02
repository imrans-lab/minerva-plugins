extends SceneTree
## THE CANVAS HOVER CARD — content, parity with the read verbs, and the two
## placement rules that make it paint rather than furniture.
##
## Run (via a Minerva checkout as the Godot host — NEVER the live checkout):
##   pcb/scripts/run-gd-tests.sh <path-to-minerva-checkout>
##
## ── WHAT THIS SUITE IS FOR ───────────────────────────────────────────────────
## The display-only board facts that used to sit in the sidebar (a component's
## id/position/rotation/layer/footprint, a pin's readout) now appear on a card
## painted beside whatever the pointer is resting on. The card must therefore
## be exactly as trustworthy as the read verb for the same entity — and it must
## never get in the way of the board it describes.
##
## ── ORACLES, one per section ─────────────────────────────────────────────────
##   1  CONTENT vs THE FIXTURE. The board is built here with hand-chosen value,
##      footprint, rotation, position, net, width and layer, and the card is
##      read against THOSE numbers. Independent of any derivation: if the card
##      invented its own arithmetic it would disagree with the fixture.
##   2  CONTENT vs THE VERB. The same cards are compared against the replies
##      minerva_pcb_describe_component and minerva_pcb_describe_region give for
##      the same entities, dispatched through panel_tools.handle. Neither
##      surface is allowed its own spelling of a shared fact.
##   3  PLACEMENT. rect_for is pure geometry, so it is walked directly at all
##      four corners of a canvas plus the degenerate "nothing fits" case: the
##      rect must stay inside the canvas and must never contain the anchor.
##   4  LIVE CANVAS. A real mouse-motion event over a part raises a card; a
##      motion onto empty board drops it in the same frame; and a drag, a
##      marquee or an authoring run has none at all.
##   5  THE OPTIONS TOGGLE (work item 01a04b85e620). With `hover_card` off no
##      motion raises a card, but a pin-inspector click still raises the
##      clicked pad's card at the click, and it stands while the pointer
##      roams empty board; with the toggle on, resting on a DIFFERENT pad
##      replaces it. The Options menu's read_state / apply carry the key.
##   6  ZONE, VIA AND GROUP (work item 01a04b9c9064). The read-outs the sidebar
##      used to carry: a zone card (kind, net, layer) and a via card (position,
##      net, size, drill) against the fixture and against describe_zone /
##      list_vias, and a Group line on a grouped part's card.
##
## ── WHAT IS DELIBERATELY NOT HERE ────────────────────────────────────────────
## No pixel is asserted — pcb_canvas draws in immediate mode, so a finished
## frame has nothing to index. What is asserted is the draw's own source: the
## lines and the rect the paint call is handed, which is where every rule
## actually lives. The PAD card is covered by test_pcb_pin_inspector.gd, which
## already has a real pad hit-test, a real host and minerva_pcb_pin_info in
## hand to compare it against.

const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const PcbHoverCard := preload("res://../../minerva-plugins/pcb/ui/pcb_hover_card.gd")
const PcbAnnotationHostScript := preload("res://../../minerva-plugins/pcb/ui/PcbAnnotationHost.gd")
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbPrefs := preload("res://../../minerva-plugins/pcb/ui/model/pcb_prefs.gd")
const PcbOptionsMenu := preload("res://../../minerva-plugins/pcb/ui/pcb_options_menu.gd")
const PrefsFixture := preload("res://../../minerva-plugins/pcb/tests/gd/snap_prefs_fixture.gd")

## Pixels per mm for every canvas in this suite. Pinned so the screen points the
## placement assertions use are hand-derivable from the fixture's board mm.
const ZOOM := 10.0
const CANVAS_SIZE := Vector2(900.0, 600.0)

## The fixture's hand-chosen facts, stated once so every assertion reads them
## off the fixture rather than off the implementation.
const U1_POS := Vector2(30.0, 20.0)
const U1_VALUE := "NE555"
const U1_ROTATION := 90.0
const U1_LAYER := "top"
const TRACE_NET := "GND"
const TRACE_LAYER := "top"
const TRACE_WIDTH := 0.4
const TRACE_A := Vector2(50.0, 40.0)
const TRACE_B := Vector2(62.0, 40.0)
const TRACE_LENGTH := 12.0
const ZONE_ID := "zone:1"
const ZONE_NET := "GND"
const ZONE_LAYER := "top"
## A point ON the pour's outline (midpoint of its 10..25 mm top edge), not
## inside it: _zone_at claims a copper pour only within a few px of its edge —
## an area claim over a pour's interior would make everything under the pour
## unpickable. A keepout is the one zone kind picked by its interior.
const ZONE_EDGE := Vector2(17.5, 45.0)
const VIA_ID := "via_1"
const VIA_POS := Vector2(80.0, 50.0)
const VIA_NET := "GND"
const VIA_SIZE := 0.8
const VIA_DRILL := 0.4

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== PCB hover card ===\n")
	_run_component_content()
	_run_trace_content()
	await _run_verb_parity()
	_run_placement()
	await _run_live_canvas()
	await _run_toggle()
	await _run_zone_via_group()
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
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)],
		actual == expected)


## Is `needle` one of the card's lines, verbatim? The card's contract is line
## content, so every content assertion is an exact line match rather than a
## substring of the whole card — a substring would pass on a line that merely
## contained the text as part of something else.
func _has_line(lines: PackedStringArray, needle: String) -> bool:
	return Array(lines).has(needle)


## The text after `prefix` on the one card line that starts with it, or "".
## Used by the parity section so a fact can be compared as a VALUE — a number
## as a number — rather than through the card's own display formatting, which
## is not what parity is about.
## Board mm agree to within a thousandth: the card prints three decimals, so an
## exact float == would be a statement about display rounding rather than about
## the two surfaces reporting the same measurement.
func _near(a: float, b: float) -> bool:
	return absf(a - b) < 0.001


func _line_value(lines: PackedStringArray, prefix: String) -> String:
	for line in lines:
		if str(line).begins_with(prefix):
			return str(line).substr(prefix.length())
	return ""


# ── the fixture ──────────────────────────────────────────────────────────────

## One rotated part carrying a value and a library footprint, one 12 mm run of
## 0.4 mm copper on GND, a second part so the board is not a single object, a
## GND pour on the top layer and a via, each placed clear of everything else.
func _board():
	var d := PCBData.new()
	d.board_width = 100.0
	d.board_height = 60.0

	var u1 = d.new_component()
	u1.id = "U1"
	u1.position = U1_POS
	u1.rotation = U1_ROTATION
	u1.layer = U1_LAYER
	u1.value = U1_VALUE
	u1.pins = {"1": Vector2(-2.0, 0.0), "2": Vector2(2.0, 0.0)}
	d.add_component(u1)

	var u2 = d.new_component()
	u2.id = "U2"
	u2.position = Vector2(70.0, 20.0)
	u2.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u2)

	d.connect_pin_to_net(TRACE_NET, "U1", "1")
	d.connect_pin_to_net(TRACE_NET, "U2", "1")

	var t = d.new_trace()
	t.id = "T1"
	t.net_name = TRACE_NET
	t.layer = TRACE_LAYER
	t.width = TRACE_WIDTH
	t.add_waypoint(TRACE_A)
	t.add_waypoint(TRACE_B)
	d.add_trace(t)

	d.add_zone_payload({"id": ZONE_ID, "kind": "copper_pour", "net": ZONE_NET,
		"layer": ZONE_LAYER, "outline": [
			{"x_mm": 10.0, "y_mm": 45.0}, {"x_mm": 25.0, "y_mm": 45.0},
			{"x_mm": 25.0, "y_mm": 55.0}, {"x_mm": 10.0, "y_mm": 55.0}]})
	d.add_via({"id": VIA_ID, "position": VIA_POS, "size": VIA_SIZE, "drill": VIA_DRILL,
		"net_name": VIA_NET, "from_layer": "top", "to_layer": "bottom"})
	return d


## A detached canvas bound to the fixture board and a real annotation host (the
## host is what answers get_spatial_index / pin_info, so nothing here is stubbed).
## Detached on purpose: _ready never runs, so the font is set explicitly — the
## same font the mounted canvas takes from ThemeDB.
func _canvas(d):
	var canvas := PcbCanvasScript.new()
	canvas.size = CANVAS_SIZE
	canvas.zoom = ZOOM
	canvas.font = ThemeDB.fallback_font
	canvas.font_size = ThemeDB.fallback_font_size
	canvas.set_data(d)
	var host := PcbAnnotationHostScript.new()
	host.set_canvas(canvas)
	canvas.set_pin_inspector_host(host)
	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	return canvas


# ── 1. component content vs the fixture ──────────────────────────────────────

func _run_component_content() -> void:
	print("-- 1. a component's card says what the fixture put on the board --")
	var d = _board()
	var canvas = _canvas(d)
	var lines: PackedStringArray = canvas._hover_card_content(
		[canvas.KIND_COMPONENT, "U1"])

	check("the refdes is the card's title line",
		lines.size() > 0 and lines[0] == "U1")
	check("value", _has_line(lines, "Value: %s" % U1_VALUE))
	check("footprint (the authored geometry name, not an id)",
		_has_line(lines, "Footprint: %s" % d.get_component("U1").get_footprint_name()))
	check("layer", _has_line(lines, "Layer: %s" % U1_LAYER))
	check("rotation, in degrees", _has_line(lines, "Rotation: 90°"))
	check("position, in board mm", _has_line(lines, "Position: (30, 20) mm"))
	check("nothing else — six lines, no stray rows", lines.size() == 6)

	check_eq("a component the board does not have gets NO card",
		canvas._hover_card_content([canvas.KIND_COMPONENT, "ZZ9"]).size(), 0)


# ── 2. trace content vs the fixture ──────────────────────────────────────────

func _run_trace_content() -> void:
	print("\n-- 2. a trace's card says what the fixture routed --")
	var d = _board()
	var canvas = _canvas(d)
	var lines: PackedStringArray = canvas._hover_card_content([canvas.KIND_TRACE, "T1"])

	check("the trace id is the card's title line",
		lines.size() > 0 and lines[0] == "T1")
	check("net", _has_line(lines, "Net: %s" % TRACE_NET))
	check("width, in mm", _has_line(lines, "Width: 0.4 mm"))
	check("layer", _has_line(lines, "Layer: %s" % TRACE_LAYER))
	# The length is summed over the polyline the region read reports, so this
	# also says the card read the RIGHT trace's geometry: 50->62 mm is 12 mm.
	check("length, summed over the reported polyline (50 -> 62 mm is 12 mm)",
		_has_line(lines, "Length: 12 mm"))
	check("nothing else — five lines", lines.size() == 5)

	check_eq("a trace the board does not have gets NO card",
		canvas._hover_card_content([canvas.KIND_TRACE, "T99"]).size(), 0)
	check_eq("a kind with no card (a cutout) gets NO card",
		canvas._hover_card_content([canvas.KIND_CUTOUT, "cutout_1"]).size(), 0)


# ── 3. content vs the read verbs ─────────────────────────────────────────────
#
# ORACLE: the card is not allowed its own derivation, so every shared fact is
# compared against the reply the MCP verb gives for the same entity, dispatched
# through the real panel_tools.handle doorway.

func _run_verb_parity() -> void:
	print("\n-- 3. the card and the read verb cannot disagree --")
	var d = _board()
	var canvas = _canvas(d)
	var host := PcbAnnotationHostScript.new()
	host.set_canvas(canvas)

	var described: Dictionary = await PanelTools.handle(host,
		"minerva_pcb_describe_component", {"component_id": "U1"})
	check("describe_component answered at all", bool(described.get("success", false)))
	var comp_card: PackedStringArray = canvas._hover_card_content(
		[canvas.KIND_COMPONENT, "U1"])
	check("card value == the verb's value",
		_has_line(comp_card, "Value: %s" % str(described.get("value", ""))))
	check("card footprint == the verb's footprint",
		_has_line(comp_card, "Footprint: %s" % str(described.get("footprint", ""))))
	check("card layer == the verb's layer",
		_has_line(comp_card, "Layer: %s" % str(described.get("layer", ""))))
	var verb_pos: Dictionary = described.get("position", {})
	var card_pos := _line_value(comp_card, "Position: (").trim_suffix(") mm").split(", ")
	check("card position == the verb's position",
		card_pos.size() == 2
			and _near(card_pos[0].to_float(), float(verb_pos.get("x", NAN)))
			and _near(card_pos[1].to_float(), float(verb_pos.get("y", NAN))))

	# The region read covering the trace, asked the way an agent would.
	var region: Dictionary = await PanelTools.handle(host, "minerva_pcb_describe_region",
		{"x_mm": 45.0, "y_mm": 35.0, "width_mm": 25.0, "height_mm": 10.0})
	check("describe_region answered at all", bool(region.get("success", false)))
	var row: Dictionary = {}
	for raw in (region.get("traces", []) as Array):
		if str((raw as Dictionary).get("trace_id", "")) == "T1":
			row = raw
	check("the region read really found T1", not row.is_empty())
	var trace_card: PackedStringArray = canvas._hover_card_content(
		[canvas.KIND_TRACE, "T1"])
	check("card net == the verb's net",
		_has_line(trace_card, "Net: %s" % str(row.get("net", ""))))
	check("card layer == the verb's layer",
		_has_line(trace_card, "Layer: %s" % str(row.get("layer", ""))))
	check("card width == the verb's width_mm",
		_near(_line_value(trace_card, "Width: ").trim_suffix(" mm").to_float(),
			float(row.get("width_mm", NAN))))


# ── 4. placement: inside the canvas, never over the pointer ──────────────────
#
# ORACLE: rect_for is pure geometry, so the rules are checked at every corner of
# the canvas rather than at one comfortable spot in the middle. A card placed at
# the bottom-right corner has to flip to the other diagonal to obey both rules,
# and that flip is exactly what a "it works in the middle" test never sees.

func _run_placement() -> void:
	print("\n-- 4. the card stays inside the canvas and off the pointer --")
	var size := Vector2(180.0, 90.0)
	var canvas_size := CANVAS_SIZE
	for raw_anchor in [Vector2(20.0, 20.0), Vector2(880.0, 20.0),
			Vector2(20.0, 580.0), Vector2(880.0, 580.0),
			Vector2(450.0, 300.0), Vector2(0.0, 0.0),
			Vector2(canvas_size.x, canvas_size.y)]:
		var anchor: Vector2 = raw_anchor
		var rect: Rect2 = PcbHoverCard.rect_for(size, anchor, canvas_size)
		check("anchor %s: inside the canvas" % str(anchor),
			rect.position.x >= 0.0 and rect.position.y >= 0.0
				and rect.end.x <= canvas_size.x and rect.end.y <= canvas_size.y)
		check("anchor %s: does not cover the pointer" % str(anchor),
			not rect.has_point(anchor))
		check_eq("anchor %s: keeps the size it was asked for" % str(anchor),
			rect.size, size)

	# A card wider than the space beside the cursor still may not cover it: the
	# fallback clamps, then pushes off the anchor.
	var wide := PcbHoverCard.rect_for(Vector2(880.0, 60.0), Vector2(450.0, 300.0),
		canvas_size)
	check("a card too wide for either side still clears the pointer",
		not wide.has_point(Vector2(450.0, 300.0)))
	check("…and is still inside the canvas",
		wide.position.x >= 0.0 and wide.end.x <= canvas_size.x)

	# THE OVERSIZED CARD. A clamp alone cannot keep a card bigger than the panel
	# inside it — the only legal origin is 0 and the far edge still overhangs —
	# so the card is CLIPPED to the canvas on the axis it overflows. Oracle: the
	# canvas rectangle itself, which the returned rect must lie within; the
	# numbers below are chosen so nothing about the card fits.
	var cramped := Vector2(120.0, 80.0)
	var huge: Rect2 = PcbHoverCard.rect_for(
		Vector2(400.0, 300.0), cramped * 0.5, cramped)
	check("a card larger than the canvas on BOTH axes never leaves the canvas",
		huge.position.x >= 0.0 and huge.position.y >= 0.0
			and huge.end.x <= cramped.x and huge.end.y <= cramped.y)
	check("…because it is clipped to the canvas, not merely clamped into it",
		huge.size.x <= cramped.x and huge.size.y <= cramped.y
			and huge.size.x > 0.0 and huge.size.y > 0.0)

	# Oversized on ONE axis: clipping the width must not cost the other rule.
	# 400 wide will not fit 120, but 40 tall fits 300 with room either side.
	var tall_canvas := Vector2(120.0, 300.0)
	var pointer := Vector2(60.0, 150.0)
	var clipped: Rect2 = PcbHoverCard.rect_for(
		Vector2(400.0, 40.0), pointer, tall_canvas)
	check("a card clipped on one axis still fits the canvas and clears the pointer",
		clipped.position.x >= 0.0 and clipped.position.y >= 0.0
			and clipped.end.x <= tall_canvas.x and clipped.end.y <= tall_canvas.y
			and not clipped.has_point(pointer))

	check_eq("no lines means no rect at all", PcbHoverCard.rect_for(
		Vector2.ZERO, Vector2(10.0, 10.0), canvas_size), Rect2())

	# measure() is what turns lines into that size; a real font and real lines,
	# so the rect the canvas asks for is the rect these rules were checked on.
	var measured: Vector2 = PcbHoverCard.measure(
		PackedStringArray(["U1", "Value: NE555"]),
		ThemeDB.fallback_font, ThemeDB.fallback_font_size)
	check("measure gives a real box for real lines",
		measured.x > 0.0 and measured.y > 0.0)
	check("a taller card measures taller than a shorter one",
		PcbHoverCard.measure(PackedStringArray(["a", "b", "c"]),
			ThemeDB.fallback_font, ThemeDB.fallback_font_size).y > measured.y)


# ── 5. the live canvas ───────────────────────────────────────────────────────
#
# ORACLE: real InputEventMouseMotion through _gui_input, so what is asserted is
# what the hover chain actually does — not a direct call to the updater.

func _run_live_canvas() -> void:
	print("\n-- 5. a real pointer raises and drops the card --")
	# MOUNTED, and it has to be: pcb_canvas._gui_input returns immediately when
	# the control is not inside the tree. The events are still fed straight to
	# _gui_input in canvas-LOCAL coordinates, so nothing here depends on where a
	# panel would have placed the control.
	var d = _board()
	var canvas = _canvas(d)
	get_root().add_child(canvas)
	canvas.size = CANVAS_SIZE
	await process_frame

	_motion(canvas, U1_POS)
	check("hovering a part raises its card",
		Array(canvas._hover_card_lines).size() > 0
			and canvas._hover_card_lines[0] == "U1")
	var rect: Rect2 = canvas.hover_card_rect()
	check("the card the canvas would paint is inside the canvas rect",
		rect.size.x > 0.0 and rect.position.x >= 0.0 and rect.position.y >= 0.0
			and rect.end.x <= canvas.size.x and rect.end.y <= canvas.size.y)
	check("…and clear of the point being hovered",
		not rect.has_point(canvas.world_to_screen(U1_POS)))

	_motion(canvas, Vector2(90.0, 55.0))
	check("moving onto empty board drops the card in the same frame",
		canvas._hover_card_lines.is_empty())

	# Hovering the copper raises the trace's card through the same chain.
	_motion(canvas, (TRACE_A + TRACE_B) * 0.5)
	check("hovering copper raises the trace's card",
		Array(canvas._hover_card_lines).has("Net: %s" % TRACE_NET))

	# A gesture in flight suppresses it: the card describes a resting pointer,
	# and during a drag or a marquee the pointer is doing something else.
	canvas.is_dragging_selection = true
	_motion(canvas, U1_POS)
	check("a selection drag raises no card", canvas._hover_card_lines.is_empty())
	check("…and paints none either", canvas.hover_card_rect() == Rect2())
	canvas.is_dragging_selection = false

	canvas.is_box_selecting = true
	_motion(canvas, U1_POS)
	check("a marquee raises no card", canvas._hover_card_lines.is_empty())
	canvas.is_box_selecting = false

	# An AUTHORING run owns the pointer, so the tool branch clears the card
	# rather than suppressing it — either way nothing is drawn over the run.
	_motion(canvas, U1_POS)
	check("back at rest, the card returns", not canvas._hover_card_lines.is_empty())
	canvas.set_tool_mode(canvas.ToolMode.TRACE)
	_motion(canvas, U1_POS)
	check("an authoring tool leaves no card", canvas._hover_card_lines.is_empty())
	canvas.set_tool_mode(canvas.ToolMode.SELECT)

	# Leaving the canvas entirely: no motion event says so, so the notification
	# has to. Without it the card would hang over the board.
	_motion(canvas, U1_POS)
	check("card is up before the pointer leaves", not canvas._hover_card_lines.is_empty())
	canvas.notification(Control.NOTIFICATION_MOUSE_EXIT)
	check("the pointer leaving the canvas drops the card",
		canvas._hover_card_lines.is_empty())

	get_root().remove_child(canvas)
	canvas.free()


# ── 6. the Options toggle ────────────────────────────────────────────────────
#
# ORACLE: the same real events as section 5, against the plugin-wide preference
# store (reset and restored around the section, so the developer's own choice
# neither leaks in nor is overwritten).

func _run_toggle() -> void:
	print("\n-- 6. the hover-card toggle, and the pin-inspector click that beats it --")
	var saved: Dictionary = PrefsFixture.reset()
	var prefs = PcbPrefs.shared()
	var d = _board()
	var canvas = _canvas(d)
	get_root().add_child(canvas)
	canvas.size = CANVAS_SIZE
	await process_frame

	# The menu's verb twin carries the key and flips it — the same apply the
	# menu click runs, so the menu is covered without popping one.
	var state: Dictionary = PcbOptionsMenu.read_state(d, prefs)
	check("read_state reports the toggle on by default",
		bool((state.get("view", {}) as Dictionary).get(PcbPrefs.KEY_HOVER_CARD, false)))
	var result: Dictionary = PcbOptionsMenu.apply(d, prefs, {PcbPrefs.KEY_HOVER_CARD: false})
	check("apply turns it off and names the change",
		bool(result.get("ok", false)) and Array(result.get("changed", [])).has(PcbPrefs.KEY_HOVER_CARD))
	check("…and read_state now reports it off",
		not bool((PcbOptionsMenu.read_state(d, prefs)["view"] as Dictionary).get(
			PcbPrefs.KEY_HOVER_CARD, true)))

	_motion(canvas, U1_POS)
	check("off: hovering a part raises no card", canvas._hover_card_lines.is_empty())
	_motion(canvas, (TRACE_A + TRACE_B) * 0.5)
	check("off: hovering copper raises no card", canvas._hover_card_lines.is_empty())

	# The pin inspector's click is the one deliberate way to ask for a card.
	canvas.set_tool_mode(canvas.ToolMode.INSPECT_PIN)
	var pad: Vector2 = d.get_component("U1").get_pin_world_position("1")
	_motion(canvas, pad)
	check("off: the inspector's hover raises no card either", canvas._hover_card_lines.is_empty())
	_click(canvas, pad)
	check("off: clicking a pad with the inspector raises its card",
		Array(canvas._hover_card_lines).size() > 0 and canvas._hover_card_lines[0] == "U1.1")
	var rect: Rect2 = canvas.hover_card_rect()
	check("…anchored at the click: inside the canvas and clear of the pad",
		rect.size.x > 0.0 and not rect.has_point(canvas.world_to_screen(pad)))
	_motion(canvas, Vector2(90.0, 55.0))
	check("…and it stands while the pointer roams",
		Array(canvas._hover_card_lines).size() > 0 and canvas._hover_card_lines[0] == "U1.1")
	_click(canvas, Vector2(90.0, 55.0))
	check("an inspector click on empty board drops it", canvas._hover_card_lines.is_empty())

	_click(canvas, pad)
	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	check("leaving the inspector drops a clicked card", canvas._hover_card_lines.is_empty())

	# Back on: a pinned card survives motion over nothing, and hover replaces
	# it the moment the pointer rests on another pad.
	canvas.set_tool_mode(canvas.ToolMode.INSPECT_PIN)
	_click(canvas, pad)
	PcbOptionsMenu.apply(d, prefs, {PcbPrefs.KEY_HOVER_CARD: true})
	_motion(canvas, Vector2(90.0, 55.0))
	check("on again: motion onto empty board leaves the clicked pad's card up",
		Array(canvas._hover_card_lines).size() > 0 and canvas._hover_card_lines[0] == "U1.1")
	_motion(canvas, d.get_component("U1").get_pin_world_position("2"))
	check("on again: resting on a different pad replaces it",
		Array(canvas._hover_card_lines).size() > 0 and canvas._hover_card_lines[0] == "U1.2")
	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	_motion(canvas, U1_POS)
	check("on again: hovering a part raises its card",
		Array(canvas._hover_card_lines).size() > 0 and canvas._hover_card_lines[0] == "U1")

	# The clearance the owner asked for: a full 19 px between pointer and card.
	var placed: Rect2 = PcbHoverCard.rect_for(Vector2(100.0, 40.0), Vector2(300.0, 300.0), CANVAS_SIZE)
	check("the card sits 19 px off the pointer",
		placed.position.x - 300.0 >= 19.0 and placed.position.y - 300.0 >= 19.0)

	get_root().remove_child(canvas)
	canvas.free()
	PrefsFixture.restore(saved)


# ── 7. zone, via and group cards ─────────────────────────────────────────────
#
# ORACLE: the fixture's own numbers, then the replies minerva_pcb_describe_zone
# and minerva_pcb_list_vias give for the same entities, then a live pointer.

func _run_zone_via_group() -> void:
	print("\n-- 7. zone, via and group cards say what the board says --")
	var d = _board()
	var canvas = _canvas(d)

	var zone: PackedStringArray = canvas._hover_card_content([canvas.KIND_ZONE, ZONE_ID])
	check("the zone id is the card's title line", zone.size() > 0 and zone[0] == ZONE_ID)
	check("zone kind", _has_line(zone, "Kind: copper_pour"))
	check("zone net", _has_line(zone, "Net: %s" % ZONE_NET))
	check("zone layer", _has_line(zone, "Layer: %s" % ZONE_LAYER))
	check("nothing else — four lines", zone.size() == 4)
	check_eq("a zone the board does not have gets NO card",
		canvas._hover_card_content([canvas.KIND_ZONE, "zone:99"]).size(), 0)

	var via: PackedStringArray = canvas._hover_card_content([canvas.KIND_VIA, VIA_ID])
	check("the via id is the card's title line", via.size() > 0 and via[0] == VIA_ID)
	check("via position, in board mm", _has_line(via, "Position: (80, 50) mm"))
	check("via net", _has_line(via, "Net: %s" % VIA_NET))
	check("via size", _has_line(via, "Size: 0.8 mm"))
	check("via drill", _has_line(via, "Drill: 0.4 mm"))
	check("nothing else — five lines", via.size() == 5)
	check_eq("a via the board does not have gets NO card",
		canvas._hover_card_content([canvas.KIND_VIA, "via_99"]).size(), 0)

	# Parity with the verbs, through the real doorway.
	var host := PcbAnnotationHostScript.new()
	host.set_canvas(canvas)
	var described: Dictionary = await PanelTools.handle(host,
		"minerva_pcb_describe_zone", {"zone_id": ZONE_ID})
	check("describe_zone answered at all", bool(described.get("success", false)))
	check("card kind == the verb's kind", _has_line(zone, "Kind: %s" % str(described.get("kind", ""))))
	check("card net == the verb's net", _has_line(zone, "Net: %s" % str(described.get("net", ""))))
	check("card layer == the verb's layer", _has_line(zone, "Layer: %s" % str(described.get("layer", ""))))

	var listed: Dictionary = await PanelTools.handle(host, "minerva_pcb_list_vias", {})
	check("list_vias answered at all", bool(listed.get("success", false)))
	var row: Dictionary = {}
	for raw in (listed.get("vias", []) as Array):
		if str((raw as Dictionary).get("via_id", "")) == VIA_ID:
			row = raw
	check("list_vias really listed the via", not row.is_empty())
	check("card net == the verb's net_name", _has_line(via, "Net: %s" % str(row.get("net_name", ""))))
	check("card size == the verb's size_mm",
		_near(_line_value(via, "Size: ").trim_suffix(" mm").to_float(), float(row.get("size_mm", NAN))))
	check("card drill == the verb's drill_mm",
		_near(_line_value(via, "Drill: ").trim_suffix(" mm").to_float(), float(row.get("drill_mm", NAN))))
	var card_pos := _line_value(via, "Position: (").trim_suffix(") mm").split(", ")
	check("card position == the verb's x_mm/y_mm",
		card_pos.size() == 2
			and _near(card_pos[0].to_float(), float(row.get("x_mm", NAN)))
			and _near(card_pos[1].to_float(), float(row.get("y_mm", NAN))))

	# A grouped part carries its group; a loose part carries no Group line.
	var group_id: String = d.group_components(["U1", "U2"])
	check("fixture: the two parts were grouped", not group_id.is_empty())
	var grouped: PackedStringArray = canvas._hover_card_content([canvas.KIND_COMPONENT, "U1"])
	check("a grouped part's card names its group",
		_has_line(grouped, "Group: 2 parts, anchor %s" % str(d.group_anchor_id(group_id))))
	d.ungroup_components(["U1", "U2"])
	var loose: PackedStringArray = canvas._hover_card_content([canvas.KIND_COMPONENT, "U2"])
	check("an ungrouped part's card has no Group line", _line_value(loose, "Group: ").is_empty())

	# A real pointer raises them through the same chain as parts and traces.
	get_root().add_child(canvas)
	canvas.size = CANVAS_SIZE
	await process_frame
	_motion(canvas, ZONE_EDGE)
	check("hovering a zone raises its card",
		Array(canvas._hover_card_lines).size() > 0 and canvas._hover_card_lines[0] == ZONE_ID)
	_motion(canvas, VIA_POS)
	check("hovering a via raises its card",
		Array(canvas._hover_card_lines).size() > 0 and canvas._hover_card_lines[0] == VIA_ID)
	get_root().remove_child(canvas)
	canvas.free()


## One real left-click (press then release) at a board point, canvas-local.
func _click(canvas, world_pos: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = canvas.world_to_screen(world_pos)
		ev.global_position = ev.position
		canvas._gui_input(ev)


## One real mouse-motion event at a board point, in the canvas's own local
## coordinates (Control._gui_input receives local px).
func _motion(canvas, world_pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = canvas.world_to_screen(world_pos)
	ev.global_position = ev.position
	canvas._gui_input(ev)
