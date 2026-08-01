extends SceneTree
## The CANVAS trace tool (ToolMode.TRACE) — the tool that authors real copper.
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout>, or directly:
##   godot --headless --path src --script ../../minerva-plugins/pcb/tests/gd/test_pcb_trace_tool.gd
##
## Campaign-2 boundary entry BT-93 (item 019fbd31253b). Before this file the real
## trace tool had ZERO coverage: a repo-wide grep of pcb/tests/gd for
## ToolMode.TRACE / create_trace_entity / trace_author_error / _handle_trace_click
## returned nothing. (test_pcb_single_trace_tool.gd, despite its name, is the
## route-HINT tool — an AnnotationAuthorTool on the overlay, not this one.)
##
## WHAT IS PINNED, from the tool's documented grammar:
##   1. start-pad net inheritance (and the two refusals that guard it)
##   2. the width chain: override > board rule > default
##   3. commit → journal + history shape
##   4. Esc / right-click cancel, and a refusal that KEEPS the placed points
##   5. cross-net finish permissiveness (owner ruling: DRC is the correctness
##      net, not the drawing tool — but the short is named out loud)
##
## INDEPENDENT REPRESENTATION, throughout: the SERIALIZED trace entities out of
## to_board_dict() and the model's change_journal / history — never the tool's own
## _trace_points / _trace_net / _trace_layer buffers, which are the thing under
## test.

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")

var _pass := 0
var _fail := 0


## The pad oracle the tool asks for pads. The real one is PcbAnnotationHost;
## the tool only ever calls pad_at(), so a stub is the honest seam — and it keeps
## this suite free of the annotation substrate entirely.
class StubPadHost extends RefCounted:
	var pads: Array = []   # [{component, pin, position}]
	func pad_at(world_pos: Vector2, radius: float, _filter: Variant = null) -> Dictionary:
		var best: Dictionary = {}
		var best_d := INF
		for p in pads:
			var d: float = (p["position"] as Vector2).distance_to(world_pos)
			if d <= radius and d < best_d:
				best_d = d
				best = p
		return best


func _init() -> void:
	print("=== PCB canvas TRACE tool (BT-93) ===\n")
	_test_start_pad_net_inheritance()
	_test_start_refusals()
	_test_width_chain()
	_test_commit_journal_shape()
	_test_cancel_paths()
	_test_cross_net_finish_is_permissive_but_loud()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail.is_empty():
			printerr("  FAIL: %s" % desc)
		else:
			printerr("  FAIL: %s — %s" % [desc, detail])


## Two parts, two declared nets, a declared 2-layer stack, and a board rule width
## that is DISTINCT from the model default — the C2-CHECK 7 lesson: identical
## values mask precedence.
func _board(rule_width: float = 0.0) -> Dictionary:
	var b := {
		"version": 1, "name": "TraceBoard", "width_mm": 60.0, "height_mm": 40.0,
		"grid_mm": 2.54,
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 10.0, "y_mm": 10.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
			{"ref": "R1", "footprint": "RESISTOR", "x_mm": 30.0, "y_mm": 10.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
			{"ref": "C1", "footprint": "CAPACITOR", "x_mm": 30.0, "y_mm": 25.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		],
		"nets": [
			{"name": "VCC", "pins": ["U1.1", "R1.1"]},
			{"name": "GND", "pins": ["C1.1"]},
		],
	}
	if rule_width > 0.0:
		b["design_rules"] = {"trace_width_mm": rule_width}
	return b


func _rig(rule_width: float = 0.0) -> Array:
	var canvas = PcbCanvasScript.new()
	var data = PCBData.new()
	data.from_board_dict(_board(rule_width))
	canvas.data = data
	canvas.zoom = 8.0
	canvas.snap_to_grid = false
	var host := StubPadHost.new()
	host.pads = [
		{"component": "U1", "pin": "1", "position": Vector2(10.0, 10.0)},
		{"component": "R1", "pin": "1", "position": Vector2(30.0, 10.0)},
		{"component": "C1", "pin": "1", "position": Vector2(30.0, 25.0)},
	]
	canvas.set_pin_inspector_host(host)
	canvas.set_tool_mode(canvas.ToolMode.TRACE)
	return [canvas, data, host]


## The serialized traces — the representation the tool never writes directly.
func _serialized_traces(data) -> Array:
	return (data.to_board_dict().get("traces", []) as Array)


## 1. START-PAD NET INHERITANCE.
##
## ORACLE: the net on the SERIALIZED trace, compared against the net the board
## declares for the starting pad — two independent reads (the board's net table
## and the committed entity), never the tool's frozen `_trace_net`.
func _test_start_pad_net_inheritance() -> void:
	print("-- BT-93 (1): the trace inherits its net from the START pad --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]

	canvas._handle_trace_click(Vector2(10.0, 10.0), false)   # start on U1.1 (VCC)
	canvas._handle_trace_click(Vector2(20.0, 10.0), false)   # a waypoint
	canvas._handle_trace_click(Vector2(30.0, 10.0), false)   # finish on R1.1 (VCC)

	var traces := _serialized_traces(data)
	check("BT-93: exactly one trace was committed", traces.size() == 1,
			"traces=%d" % traces.size())
	var t: Dictionary = traces[0] if traces.size() == 1 else {}
	check("BT-93: its net is the START pad's net, read off the board's own table",
			str(t.get("net", "")) == data.find_net_for_pin("U1", "1"),
			"trace net=%s board says=%s" % [str(t.get("net", "")),
					data.find_net_for_pin("U1", "1")])
	check("BT-93: …which is VCC", str(t.get("net", "")) == "VCC")
	check("BT-93: it landed on the authored layer",
			str(t.get("layer", "")) == canvas.trace_author_layer(),
			"layer=%s" % str(t.get("layer", "")))
	check("BT-93: and it carries all three points",
			(t.get("points", []) as Array).size() == 3,
			"points=%s" % str(t.get("points", [])))

	canvas.free()


## 1b. THE TWO START REFUSALS. Both are TRANSIENT MESSAGES, never silent no-ops.
##
## ORACLE: the serialized trace count (still zero) plus the message channel.
func _test_start_refusals() -> void:
	print("\n-- BT-93 (1b): starting off a pad, and on a netless pad --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var host = rig[2]
	var msgs: Array = []
	canvas.trace_tool_message.connect(func(t: String) -> void: msgs.append(t))

	canvas._handle_trace_click(Vector2(50.0, 35.0), false)   # empty board
	check("BT-93: a click on empty board does not start a trace",
			canvas._trace_points.is_empty())
	check("BT-93: …and says why", msgs.size() == 1 and msgs[0].contains("on a pad"),
			str(msgs))

	# A pad the board declares no net for.
	host.pads.append({"component": "U1", "pin": "9", "position": Vector2(14.0, 14.0)})
	canvas._handle_trace_click(Vector2(14.0, 14.0), false)
	check("BT-93: a NETLESS pad does not start a trace either",
			canvas._trace_points.is_empty())
	check("BT-93: …and names the pad", msgs.size() == 2 and msgs[1].contains("no net"),
			str(msgs))
	check("BT-93: nothing was serialized by either refusal",
			_serialized_traces(data).is_empty())

	canvas.free()


## 2. THE WIDTH CHAIN: override > board rule > model default.
##
## ORACLE: the width on the SERIALIZED trace, on THREE boards whose values are all
## mutually distinct (0.55 override / 0.35 rule / the model default). Identical
## values would mask the precedence — the C2-CHECK 7 lesson, applied here.
func _test_width_chain() -> void:
	print("\n-- BT-93 (2): width chain — override > board rule > default --")
	var default_w: float = PCBData.DEFAULT_TRACE_WIDTH_MM
	check("BT-93 fixture: the three widths are mutually distinct "
			+ "(0.55 / 0.35 / default %.3f)" % default_w,
			not is_equal_approx(default_w, 0.35) and not is_equal_approx(default_w, 0.55))

	# (a) override + rule  → the OVERRIDE wins.
	var a := _rig(0.35)
	a[0].trace_width_override = 0.55
	_draw_a_trace(a[0])
	check("BT-93 (a) override+rule: the serialized width is the OVERRIDE (0.55)",
			is_equal_approx(float(_serialized_traces(a[1])[0].get("width_mm", 0.0)), 0.55),
			"got %s" % str(_serialized_traces(a[1])[0].get("width_mm", 0.0)))
	a[0].free()

	# (b) rule, no override → the BOARD RULE wins.
	var b := _rig(0.35)
	_draw_a_trace(b[0])
	check("BT-93 (b) rule only: the serialized width is the BOARD RULE (0.35)",
			is_equal_approx(float(_serialized_traces(b[1])[0].get("width_mm", 0.0)), 0.35),
			"got %s" % str(_serialized_traces(b[1])[0].get("width_mm", 0.0)))
	b[0].free()

	# (c) neither → the MODEL DEFAULT.
	var c := _rig()
	_draw_a_trace(c[0])
	check("BT-93 (c) neither: the serialized width is the model DEFAULT (%.3f)" % default_w,
			is_equal_approx(float(_serialized_traces(c[1])[0].get("width_mm", 0.0)), default_w),
			"got %s" % str(_serialized_traces(c[1])[0].get("width_mm", 0.0)))
	c[0].free()


func _draw_a_trace(canvas) -> void:
	canvas._handle_trace_click(Vector2(10.0, 10.0), false)
	canvas._handle_trace_click(Vector2(20.0, 10.0), false)
	canvas._handle_trace_click(Vector2(30.0, 10.0), false)


## 3. COMMIT → JOURNAL + HISTORY SHAPE.
##
## ORACLE: the model's change_journal entry and history length — two counters the
## tool does not own — plus undo/redo actually moving the SERIALIZED entity.
func _test_commit_journal_shape() -> void:
	print("\n-- BT-93 (3): commit journals once, undo/redo move the entity --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	data.save_to_history("baseline")

	var j0: int = data.change_journal.size()
	var h0: int = data.history.size()
	_draw_a_trace(canvas)

	check("BT-93: history grew by exactly ONE step for the commit",
			data.history.size() - h0 == 1,
			"delta=%d" % (data.history.size() - h0))
	var adds: Array = []
	for e in data.change_journal.slice(j0):
		if str((e as Dictionary).get("action", "")) == "add_trace":
			adds.append(e)
	check("BT-93: exactly one add_trace journal entry", adds.size() == 1,
			"entries=%s" % str(data.change_journal.slice(j0)))

	# MINTED id, not ordinal — the identity rule create_trace_entity exists for.
	var t: Dictionary = _serialized_traces(data)[0]
	check("BT-93: the committed trace carries a MINTED id (\"trace:<hex>\"), not an "
			+ "ordinal add_trace id",
			str(t.get("id", "")).begins_with("trace:"), "id=%s" % str(t.get("id", "")))

	check("BT-93: undo removes the trace from the SERIALIZED board",
			data.undo() and _serialized_traces(data).is_empty())
	check("BT-93: redo puts it back (snapshot-after ordering)",
			data.redo() and _serialized_traces(data).size() == 1)

	canvas.free()


## 4. CANCEL PATHS, and the refusal that KEEPS the points.
##
## ORACLE: the serialized trace count (nothing committed) plus the message
## channel, and — for the refusal — that the placed points SURVIVE, which is the
## documented difference between "refused" and "cancelled".
func _test_cancel_paths() -> void:
	print("\n-- BT-93 (4): Esc / right-click cancel, and refuse-without-discarding --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs: Array = []
	canvas.trace_tool_message.connect(func(t: String) -> void: msgs.append(t))

	# (a) Esc mid-draw.
	canvas._handle_trace_click(Vector2(10.0, 10.0), false)
	canvas._handle_trace_click(Vector2(20.0, 10.0), false)
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	canvas._handle_key_input(esc)
	check("BT-93 (a): Esc discarded the in-progress trace",
			canvas._trace_points.is_empty())
	check("BT-93 (a): …and announced it",
			msgs.size() > 0 and msgs[msgs.size() - 1] == "Trace cancelled.", str(msgs))
	check("BT-93 (a): …and committed nothing", _serialized_traces(data).is_empty())

	# (b) right-press mid-draw.
	canvas._handle_trace_click(Vector2(10.0, 10.0), false)
	canvas._handle_trace_click(Vector2(20.0, 10.0), false)
	var rmb := InputEventMouseButton.new()
	rmb.button_index = MOUSE_BUTTON_RIGHT
	rmb.pressed = true
	rmb.position = canvas.world_to_screen(Vector2(20.0, 10.0))
	canvas._handle_mouse_button(rmb)
	check("BT-93 (b): a right-press cancelled the draw",
			canvas._trace_points.is_empty())
	check("BT-93 (b): …and still committed nothing", _serialized_traces(data).is_empty())

	# (c) REFUSED commit (one point) KEEPS the point: the fix is another click,
	#     not redrawing from scratch. This is the leg that distinguishes a
	#     refusal from a cancel.
	msgs.clear()
	canvas._handle_trace_click(Vector2(10.0, 10.0), false)
	canvas._commit_trace()
	check("BT-93 (c): a 1-point commit is REFUSED", _serialized_traces(data).is_empty())
	# The refusal text is compared BYTE-FOR-BYTE against the model function's own
	# output for the same input — a drift detector, not a copy of the string.
	# (msgs[0] is the start-of-trace announcement; the refusal is the last line.)
	check("BT-93 (c): …with the model's own wording, byte-for-byte",
			not msgs.is_empty()
			and msgs[msgs.size() - 1] == data.trace_author_error("VCC", "top", 1),
			"got %s / model says %s" % [str(msgs), data.trace_author_error("VCC", "top", 1)])
	check("BT-93 (c): …and the placed point SURVIVES the refusal",
			canvas._trace_points.size() == 1,
			"%d points left" % canvas._trace_points.size())

	canvas.free()


## 5. CROSS-NET FINISH is PERMISSIVE but LOUD (owner ruling, canvas ~:4531-4543).
##
## ORACLE: the trace IS in the serialized board (permissive) AND the announcement
## names BOTH nets (loud). Either leg alone can be satisfied by the wrong
## behaviour: a refusal is silent-and-safe, a quiet commit is loud-free.
func _test_cross_net_finish_is_permissive_but_loud() -> void:
	print("\n-- BT-93 (5): cross-net finish commits, and is named out loud --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs: Array = []
	canvas.trace_tool_message.connect(func(t: String) -> void: msgs.append(t))

	canvas._handle_trace_click(Vector2(10.0, 10.0), false)   # start U1.1 (VCC)
	canvas._handle_trace_click(Vector2(20.0, 18.0), false)   # waypoint
	canvas._handle_trace_click(Vector2(30.0, 25.0), false)   # finish C1.1 (GND)

	var traces := _serialized_traces(data)
	check("BT-93 (5): the cross-net trace WAS committed (DRC is the correctness net)",
			traces.size() == 1, "traces=%d" % traces.size())
	check("BT-93 (5): …still carrying the START pad's net",
			traces.size() == 1 and str(traces[0].get("net", "")) == "VCC",
			"net=%s" % (str(traces[0].get("net", "")) if traces.size() == 1 else "-"))
	var last: String = msgs[msgs.size() - 1] if not msgs.is_empty() else ""
	check("BT-93 (5): …and the short was NAMED, with BOTH nets and the word short",
			last.contains("VCC") and last.contains("GND") and last.contains("short"),
			"message=%s" % last)
	check("BT-93 (5): …and DRC is named as what will flag it",
			last.contains("DRC"), "message=%s" % last)

	canvas.free()
