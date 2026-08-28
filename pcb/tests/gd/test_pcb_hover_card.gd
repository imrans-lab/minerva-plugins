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

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== PCB hover card ===\n")
	_run_component_content()
	_run_trace_content()
	await _run_verb_parity()
	_run_placement()
	await _run_live_canvas()
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
## 0.4 mm copper on GND, and a second part so the board is not a single object.
func _board():
	var d = PCBData.new()
	d.board_width = 100.0
	d.board_height = 60.0

	var u1 = d.new_component()
	u1.id = "U1"
	u1.position = U1_POS
	u1.rotation = U1_ROTATION
	u1.layer = U1_LAYER
	u1.properties["value"] = U1_VALUE
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
	return d


## A detached canvas bound to the fixture board and a real annotation host (the
## host is what answers get_spatial_index / pin_info, so nothing here is stubbed).
## Detached on purpose: _ready never runs, so the font is set explicitly — the
## same font the mounted canvas takes from ThemeDB.
func _canvas(d):
	var canvas = PcbCanvasScript.new()
	canvas.size = CANVAS_SIZE
	canvas.zoom = ZOOM
	canvas.font = ThemeDB.fallback_font
	canvas.font_size = ThemeDB.fallback_font_size
	canvas.set_data(d)
	var host = PcbAnnotationHostScript.new()
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
	check_eq("a kind with no card (a via, a zone) gets NO card",
		canvas._hover_card_content([canvas.KIND_VIA, "via_1"]).size(), 0)


# ── 3. content vs the read verbs ─────────────────────────────────────────────
#
# ORACLE: the card is not allowed its own derivation, so every shared fact is
# compared against the reply the MCP verb gives for the same entity, dispatched
# through the real panel_tools.handle doorway.

func _run_verb_parity() -> void:
	print("\n-- 3. the card and the read verb cannot disagree --")
	var d = _board()
	var canvas = _canvas(d)
	var host = PcbAnnotationHostScript.new()
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


## One real mouse-motion event at a board point, in the canvas's own local
## coordinates (Control._gui_input receives local px).
func _motion(canvas, world_pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = canvas.world_to_screen(world_pos)
	ev.global_position = ev.position
	canvas._gui_input(ev)
