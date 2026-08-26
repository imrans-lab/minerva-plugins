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
##   6. VIA ANCHORING: a via starts a trace and ends one, on
##      the via's CENTRE and the via's net; a netless via is refused by name; and
##      the copper a click authors is byte-identical to what minerva_pcb_add_trace
##      authors from the same via's coordinates.
##   7. the DOUBLE-CLICK's second press: it commits only when there is still a
##      trace to commit, so a finish-on-anchor keeps its own confirmation
##   8. the NETLESS refusal names every anchor kind, on the model surface an
##      agent reads and the canvas surface a click reads alike
##
## INDEPENDENT REPRESENTATION, throughout: the SERIALIZED trace entities out of
## to_board_dict() and the model's change_journal / history — never the tool's own
## _trace_points / _trace_net / _trace_layer buffers, which are the thing under
## test.

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
## The MCP verb surface. Section 6 asserts the AGENT path and the CLICK path
## land the same copper, so it has to call the real verb, not a stand-in.
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")

var _pass := 0
var _fail := 0


## The pad oracle the tool asks for pads. The real one is PcbAnnotationHost;
## the tool only ever calls pad_at(), so a stub is the honest seam — and it keeps
## this suite free of the annotation substrate entirely.
class StubPadHost extends RefCounted:
	## The production pad-picking rule, so this double cannot drift from it.
	const PCBComponentScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
	## [{component, pin, position, lands?}]. `lands` are optional footprint
	## lands in the SAME shape pcb_component.pads carries, and because this stub
	## measures in an identity frame their `position` is world mm. Omitted, the
	## pin is a bare point — which is what every pad in this suite is.
	var pads: Array = []
	## PanelTools._resolve_data reaches the model through exactly one duck-typed
	## call (panel_tools.gd _get_data -> host.get_board_data()), so the MCP verbs
	## run against this stub without mounting a PCBPanel. Set by _rig.
	var board: Variant = null
	func get_board_data() -> Variant:
		return board
	func pad_at(world_pos: Vector2, radius: float, _filter: Variant = null) -> Dictionary:
		var best: Dictionary = {}
		var best_d := INF
		for p in pads:
			# The production rule, CALLED not copied: distance to the pad's
			# copper. A stub carrying the old centre-distance rule would keep
			# this suite green against a contract that no longer exists.
			var d: float = PCBComponentScript.pin_copper_distance_from(
				Vector2.ZERO, Transform2D.IDENTITY, p["position"],
				p.get("lands", []), world_pos)
			if d > radius:
				continue
			# host.pad_at's TIE-BREAK as well as its distance: equal distances
			# group under is_equal_approx and the lower (component, pin) wins.
			# Ranking by strict `<` would keep whichever pad came first in this
			# array, so the double would answer a click exactly between two
			# pads differently from the surface it stands in for.
			if best.is_empty() or (d < best_d and not is_equal_approx(d, best_d)):
				best_d = d
				best = p
			elif is_equal_approx(d, best_d) and _pad_precedes(p, best):
				best = p
		return best

	static func _pad_precedes(a: Dictionary, b: Dictionary) -> bool:
		var a_comp := str(a.get("component", ""))
		var b_comp := str(b.get("component", ""))
		if a_comp != b_comp:
			return a_comp < b_comp
		return str(a.get("pin", "")) < str(b.get("pin", ""))


func _init() -> void:
	print("=== PCB canvas TRACE tool (BT-93) ===\n")
	_test_start_pad_net_inheritance()
	_test_start_refusals()
	_test_width_chain()
	_test_commit_journal_shape()
	_test_cancel_paths()
	_test_cross_net_finish_is_permissive_but_loud()
	_test_via_anchoring()
	_test_via_click_and_mcp_author_the_same_copper()
	_test_double_click_second_press()
	_test_netless_refusal_names_every_anchor_kind()
	_test_working_layer_is_not_the_view()
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
	host.board = data
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


## ── 6. VIA ANCHORING ─────────────────────────────────────────────────────────
##
## THE FIXTURE, added on top of _rig so sections 1-5 keep the board they were
## written against. Vias go in through data.add_via — the same call
## minerva_pcb_place_via makes — rather than through the board dict, because
## _vias_from_board_list mints no id and get_via_at skips id-less vias: a
## board-dict fixture would be unclickable for a reason that has nothing to do
## with the tool.
##
## Returns [canvas, data, host, netted_via_id, netless_via_id].
func _rig_with_vias() -> Array:
	var rig := _rig()
	var data = rig[1]
	var netted: String = str(data.add_via({
		"position": _VIA_CENTRE, "net_name": "VCC", "size": 0.8, "drill": 0.4,
		"from_layer": "top", "to_layer": "bottom",
	}))
	var netless: String = str(data.add_via({
		"position": _NETLESS_VIA_CENTRE, "net_name": "", "size": 0.8, "drill": 0.4,
		"from_layer": "top", "to_layer": "bottom",
	}))
	return [rig[0], data, rig[2], netted, netless]


## Both vias sit well clear of all three pads (nearest is 11 mm away, against a
## 1.27 mm pad snap) so no assertion below can be satisfied by a pad hit, and
## clear of every world point sections 1-5 click.
const _VIA_CENTRE := Vector2(20.0, 20.0)
const _NETLESS_VIA_CENTRE := Vector2(40.0, 20.0)
## A click 0.5 mm off the via's centre. Inside the pick target (the canvas floors
## it at VIA_HIT_RADIUS_PX/zoom = 6/8 = 0.75 mm at this rig's zoom) and clearly
## OUTSIDE float noise, which is what lets the endpoint assertion below tell
## "snapped to the via's centre" apart from "kept the point I clicked".
const _OFF_CENTRE_CLICK := Vector2(20.5, 20.0)
## A plain waypoint: 8.9 mm from the netted via, 6.3 mm from the nearest pad.
const _WAYPOINT := Vector2(24.0, 12.0)


func _points_of(t: Dictionary) -> Array:
	var out: Array = []
	for p in (t.get("points", []) as Array):
		out.append(Vector2(float((p as Dictionary).get("x_mm", 0.0)),
				float((p as Dictionary).get("y_mm", 0.0))))
	return out


## ORACLE, for every leg: the SERIALIZED trace read back off the board model
## after the gesture, with its endpoint compared against the via's centre as the
## MODEL reports it (data.via_position on the stored via) and its net against the
## via's stored net_name. Neither value is read from the tool's own buffers, and
## neither is a literal copied from the fixture — an implementation that fixed
## only the preview, or only the status line, commits nothing and fails leg (a)
## on the first assertion.
func _test_via_anchoring() -> void:
	print("\n-- via anchoring (1): a via starts a trace, and ends one --")

	# (a) FINISH ON A VIA — the leg the feature exists for. Start on a pad so the
	#     start half is the already-shipped behaviour and only the finish is new.
	var a := _rig_with_vias()
	var canvas_a = a[0]
	var data_a = a[1]
	var via_a: Dictionary = data_a.get_via(str(a[3]))
	var msgs_a: Array = []
	canvas_a.trace_tool_message.connect(func(t: String) -> void: msgs_a.append(t))

	canvas_a._handle_trace_click(Vector2(10.0, 10.0), false)   # start U1.1 (VCC)
	canvas_a._handle_trace_click(_WAYPOINT, false)             # a plain waypoint
	canvas_a._handle_trace_click(_OFF_CENTRE_CLICK, false)     # finish ON THE VIA

	var traces_a := _serialized_traces(data_a)
	check("VIA (a): clicking a via while drawing COMMITTED a trace",
			traces_a.size() == 1, "traces=%d" % traces_a.size())
	var ta: Dictionary = traces_a[0] if traces_a.size() == 1 else {}
	var pts_a: Array = _points_of(ta)
	check("VIA (a): …ending on the via's CENTRE as the model reports it",
			not pts_a.is_empty()
			and (pts_a[pts_a.size() - 1] as Vector2).is_equal_approx(
					data_a.via_position(via_a)),
			"endpoint=%s via centre=%s" % [str(pts_a), str(data_a.via_position(via_a))])
	# The leg that makes the one above non-vacuous: the click was 0.5 mm off the
	# centre, so "kept the click point" and "snapped to the centre" differ.
	check("VIA (a): …NOT at the point that was clicked (the snap is real)",
			not pts_a.is_empty()
			and not (pts_a[pts_a.size() - 1] as Vector2).is_equal_approx(_OFF_CENTRE_CLICK),
			"endpoint=%s click=%s" % [str(pts_a), str(_OFF_CENTRE_CLICK)])
	check("VIA (a): the middle click stayed a plain WAYPOINT, at the point clicked",
			pts_a.size() == 3 and (pts_a[1] as Vector2).is_equal_approx(_WAYPOINT),
			"points=%s" % str(pts_a))
	check("VIA (a): the gesture ENDED — nothing is still being drawn",
			canvas_a._trace_points.is_empty(),
			"%d points still held" % canvas_a._trace_points.size())
	check("VIA (a): no short was announced — the via is on the trace's own net",
			not msgs_a.is_empty() and not msgs_a[msgs_a.size() - 1].contains("short"),
			str(msgs_a))
	canvas_a.free()

	# (b) START ON A VIA — the trace inherits the VIA's net, read back off the
	#     stored via rather than off the fixture literal.
	var b := _rig_with_vias()
	var canvas_b = b[0]
	var data_b = b[1]
	var via_b: Dictionary = data_b.get_via(str(b[3]))
	var msgs_b: Array = []
	canvas_b.trace_tool_message.connect(func(t: String) -> void: msgs_b.append(t))

	canvas_b._handle_trace_click(_OFF_CENTRE_CLICK, false)     # start ON THE VIA
	check("VIA (b): a click on a via ARMED the tool", not canvas_b._trace_points.is_empty())
	check("VIA (b): …and the teach line names the via", not msgs_b.is_empty()
			and msgs_b[0].contains(str(b[3])), str(msgs_b))
	canvas_b._handle_trace_click(_WAYPOINT, false)
	canvas_b._handle_trace_click(Vector2(30.0, 10.0), false)   # finish R1.1 (VCC)

	var traces_b := _serialized_traces(data_b)
	check("VIA (b): starting on a via committed a trace", traces_b.size() == 1,
			"traces=%d" % traces_b.size())
	var tb: Dictionary = traces_b[0] if traces_b.size() == 1 else {}
	check("VIA (b): …carrying the VIA's OWN net, as the model stores it",
			str(tb.get("net", "")) == str(via_b.get("net_name", "")),
			"trace net=%s via says=%s" % [str(tb.get("net", "")),
					str(via_b.get("net_name", ""))])
	var pts_b: Array = _points_of(tb)
	check("VIA (b): …and it BEGINS at the via's centre, not the click point",
			not pts_b.is_empty()
			and (pts_b[0] as Vector2).is_equal_approx(data_b.via_position(via_b))
			and not (pts_b[0] as Vector2).is_equal_approx(_OFF_CENTRE_CLICK),
			"points=%s" % str(pts_b))
	canvas_b.free()

	# (c) THE NEGATIVE: a NETLESS via is REFUSED BY NAME, never silently authored
	#     and never silently demoted to "you clicked nothing". Same shape as the
	#     netless-PAD refusal section 1b pins.
	print("\n-- via anchoring (2): a netless via is refused, by name --")
	var c := _rig_with_vias()
	var canvas_c = c[0]
	var data_c = c[1]
	var msgs_c: Array = []
	canvas_c.trace_tool_message.connect(func(t: String) -> void: msgs_c.append(t))

	canvas_c._handle_trace_click(_NETLESS_VIA_CENTRE, false)
	check("VIA (c): a netless via does not start a trace",
			canvas_c._trace_points.is_empty(),
			"%d points placed" % canvas_c._trace_points.size())
	check("VIA (c): …and nothing was serialized", _serialized_traces(data_c).is_empty())
	var last_c: String = msgs_c[msgs_c.size() - 1] if not msgs_c.is_empty() else ""
	check("VIA (c): …and the refusal NAMES the via and says it is on no net",
			last_c.contains(str(c[4])) and last_c.contains("no net"),
			"message=%s" % last_c)
	# Distinguishes "refused because netless" from "the click missed everything":
	# the miss refusal is a different sentence, pinned in section 1b.
	check("VIA (c): …and it is not the generic \"you missed\" refusal",
			not last_c.contains("that is where its net comes from"),
			"message=%s" % last_c)

	# (c2) …but a netless via is a legal PLACE TO STOP: by then the trace already
	#      has its net. Permissive-but-loud, the same rule the cross-net finish
	#      follows (section 5).
	msgs_c.clear()
	canvas_c._handle_trace_click(Vector2(10.0, 10.0), false)   # start U1.1 (VCC)
	canvas_c._handle_trace_click(_WAYPOINT, false)
	canvas_c._handle_trace_click(_NETLESS_VIA_CENTRE, false)   # finish on it
	var traces_c := _serialized_traces(data_c)
	check("VIA (c2): finishing ON a netless via IS allowed", traces_c.size() == 1,
			"traces=%d" % traces_c.size())
	check("VIA (c2): …the trace keeps the net it started with",
			traces_c.size() == 1 and str(traces_c[0].get("net", "")) == "VCC",
			"net=%s" % (str(traces_c[0].get("net", "")) if traces_c.size() == 1 else "-"))
	check("VIA (c2): …and the netless end is named out loud",
			not msgs_c.is_empty()
			and msgs_c[msgs_c.size() - 1].contains(str(c[4]))
			and msgs_c[msgs_c.size() - 1].contains("no net"),
			str(msgs_c))
	canvas_c.free()


## ── 6b. THE CLICK AND THE VERB AUTHOR THE SAME COPPER ────────────────────────
##
## The constraint this feature was given: "a human clicking a via and an agent
## calling the trace-authoring verb with that via's coordinates should produce
## the same trace."
##
## ORACLE: the two SERIALIZED trace dicts, compared field-for-field with only the
## minted id removed (ids are minted per board and are never equal by
## construction). Two boards built from the identical fixture, one driven by
## _handle_trace_click and one by PanelTools._add_trace — nothing in this test
## reads either implementation's internals, so a click path that snapped to the
## wrong point, inherited the wrong net, or resolved a different width fails on
## the diff rather than on a hand-written expectation that could drift with it.
func _test_via_click_and_mcp_author_the_same_copper() -> void:
	print("\n-- via anchoring (3): the click and minerva_pcb_add_trace agree --")

	# THE HUMAN. Pad U1.1 → a waypoint → the via, clicked off-centre.
	var human := _rig_with_vias()
	var canvas = human[0]
	var data_h = human[1]
	var via: Dictionary = data_h.get_via(str(human[3]))
	var centre: Vector2 = data_h.via_position(via)
	canvas._handle_trace_click(Vector2(10.0, 10.0), false)
	canvas._handle_trace_click(_WAYPOINT, false)
	canvas._handle_trace_click(_OFF_CENTRE_CLICK, false)
	var layer: String = canvas.trace_author_layer()
	var clicked := _serialized_traces(data_h)
	check("PARITY fixture: the click authored exactly one trace", clicked.size() == 1,
			"traces=%d" % clicked.size())

	# THE AGENT. The same three points, the last one being the via's coordinates —
	# which is all an agent has to go on — through the real verb.
	var agent := _rig_with_vias()
	var data_a = agent[1]
	var host_a = agent[2]
	var res: Dictionary = PanelTools._add_trace(host_a, {
		"net_name": str(via.get("net_name", "")),
		"layer": layer,
		"points": [[10.0, 10.0], [_WAYPOINT.x, _WAYPOINT.y], [centre.x, centre.y]],
	})
	check("PARITY: the verb accepted it", bool(res.get("success", false)),
			str(res))
	var authored := _serialized_traces(data_a)
	check("PARITY: …and authored exactly one trace", authored.size() == 1,
			"traces=%d" % authored.size())

	if clicked.size() == 1 and authored.size() == 1:
		var lhs: Dictionary = (clicked[0] as Dictionary).duplicate(true)
		var rhs: Dictionary = (authored[0] as Dictionary).duplicate(true)
		check("PARITY fixture: the two minted ids DIFFER (so erasing them is not "
				+ "erasing the difference)",
				str(lhs.get("id", "")) != str(rhs.get("id", "")),
				"%s vs %s" % [str(lhs.get("id", "")), str(rhs.get("id", ""))])
		lhs.erase("id")
		rhs.erase("id")
		check("PARITY: the click's copper and the verb's copper are IDENTICAL "
				+ "(net, layer, width, every point)",
				lhs == rhs, "click=%s verb=%s" % [str(lhs), str(rhs)])

	canvas.free()
	agent[0].free()


## ── 7. THE DOUBLE-CLICK'S SECOND PRESS ───────────────────────────────────────
##
## A physical double-click reaches this tool as TWO press events; only the second
## carries double_click=true. Every OTHER click-per-point tool on this canvas
## commits on that second press and nowhere else, so its first press can only
## have placed a point. This tool is the exception: press 1 can land on a pad or
## a via and finish the whole trace by itself, leaving press 1's confirmation on
## the status line and NOTHING left to commit.
##
## ORACLE, for every leg: the SERIALIZED board (trace count, geometry) and the
## change journal — neither of which the tool writes directly — plus the message
## channel compared against pcb_data.trace_author_error's OWN output for an empty
## buffer, so the refusal is recognised by asking the model rather than by a copy
## of its wording that could drift away from it.
func _test_double_click_second_press() -> void:
	print("\n-- double-click: the second press does not overwrite press 1's answer --")

	# (a) FINISH ON A PAD by double-click — the gesture the tool documents.
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var msgs: Array = []
	canvas.trace_tool_message.connect(func(t: String) -> void: msgs.append(t))
	# The refusal an empty buffer produces, asked of the model, not written here.
	var empty_buffer_refusal: String = data.trace_author_error("", "", 0)

	canvas._handle_trace_click(Vector2(10.0, 10.0), false)   # start U1.1 (VCC)
	canvas._handle_trace_click(Vector2(20.0, 10.0), false)   # a waypoint
	canvas._handle_trace_click(Vector2(30.0, 10.0), false)   # press 1: finishes on R1.1
	var after_press1 := _serialized_traces(data)
	var journal_after_press1: int = data.change_journal.size()
	var msgs_after_press1: int = msgs.size()

	canvas._handle_trace_click(Vector2(30.0, 10.0), true)    # press 2 of the same click

	check("DBLCLK (a): press 2 said NOTHING — press 1's line is still what is read",
			msgs.size() == msgs_after_press1,
			"press 2 added %s" % str(msgs.slice(msgs_after_press1)))
	check("DBLCLK (a): …and what is read is not the model's empty-buffer refusal",
			not msgs.is_empty() and msgs[msgs.size() - 1] != empty_buffer_refusal,
			"last=%s" % (msgs[msgs.size() - 1] if not msgs.is_empty() else "<none>"))
	var after_press2 := _serialized_traces(data)
	var held: Dictionary = after_press2[0] if after_press2.size() == 1 else {}
	check("DBLCLK (a): …and it names the trace the board actually holds",
			not held.is_empty()
			and msgs[msgs.size() - 1].contains(str(held.get("net", "?")))
			and msgs[msgs.size() - 1].contains(str(held.get("layer", "?"))),
			"last=%s trace=%s" % [msgs[msgs.size() - 1] if not msgs.is_empty() else "<none>",
					str(held)])
	# The constraint: press 2 is a status-channel event only. The copper is
	# compared either side of it, entity for entity, plus the journal length.
	check("DBLCLK (a): the committed copper is IDENTICAL either side of press 2",
			after_press1.size() == 1 and after_press2.size() == 1
			and after_press1[0] == after_press2[0]
			and data.change_journal.size() == journal_after_press1,
			"before=%s after=%s journal %d->%d" % [str(after_press1), str(after_press2),
					journal_after_press1, data.change_journal.size()])
	canvas.free()

	# (b) FINISH ON A VIA by double-click — the same press-1 finish, other anchor.
	var v := _rig_with_vias()
	var canvas_v = v[0]
	var data_v = v[1]
	var msgs_v: Array = []
	canvas_v.trace_tool_message.connect(func(t: String) -> void: msgs_v.append(t))
	canvas_v._handle_trace_click(Vector2(10.0, 10.0), false)   # start U1.1 (VCC)
	canvas_v._handle_trace_click(_WAYPOINT, false)
	canvas_v._handle_trace_click(_OFF_CENTRE_CLICK, false)     # press 1: finishes on the via
	canvas_v._handle_trace_click(_OFF_CENTRE_CLICK, true)      # press 2
	check("DBLCLK (b): the via finish committed exactly one trace",
			_serialized_traces(data_v).size() == 1,
			"traces=%d" % _serialized_traces(data_v).size())
	check("DBLCLK (b): …and the status is not the empty-buffer refusal either",
			not msgs_v.is_empty()
			and msgs_v[msgs_v.size() - 1] != data_v.trace_author_error("", "", 0),
			"last=%s" % (msgs_v[msgs_v.size() - 1] if not msgs_v.is_empty() else "<none>"))
	canvas_v.free()

	# (c) DOUBLE-CLICK TO START. Press 1 arms the trace with its single start
	#     point; press 2 must not report that count back as a failure.
	var s := _rig()
	var canvas_s = s[0]
	var data_s = s[1]
	var msgs_s: Array = []
	canvas_s.trace_tool_message.connect(func(t: String) -> void: msgs_s.append(t))
	canvas_s._handle_trace_click(Vector2(10.0, 10.0), false)
	var started_with: String = msgs_s[msgs_s.size() - 1] if not msgs_s.is_empty() else ""
	canvas_s._handle_trace_click(Vector2(10.0, 10.0), true)
	check("DBLCLK (c): starting by double-click still reads as a start",
			not msgs_s.is_empty() and msgs_s[msgs_s.size() - 1] == started_with,
			"last=%s" % (msgs_s[msgs_s.size() - 1] if not msgs_s.is_empty() else "<none>"))
	check("DBLCLK (c): …with the gesture still live and nothing committed",
			canvas_s._trace_points.size() == 1 and _serialized_traces(data_s).is_empty(),
			"%d points, %d traces" % [canvas_s._trace_points.size(),
					_serialized_traces(data_s).size()])
	canvas_s.free()

	# (d) THE GESTURE THAT MUST KEEP WORKING: double-click on EMPTY SPACE ends a
	#     dangling trace there. Press 1 places the last waypoint, press 2 commits.
	var e := _rig()
	var canvas_e = e[0]
	var data_e = e[1]
	var msgs_e: Array = []
	canvas_e.trace_tool_message.connect(func(t: String) -> void: msgs_e.append(t))
	var end_point := Vector2(22.0, 16.0)   # 10 mm from the nearest pad
	canvas_e._handle_trace_click(Vector2(10.0, 10.0), false)   # start U1.1 (VCC)
	canvas_e._handle_trace_click(Vector2(20.0, 10.0), false)   # a waypoint
	canvas_e._handle_trace_click(end_point, false)             # press 1
	canvas_e._handle_trace_click(end_point, true)              # press 2 commits
	var dangling := _serialized_traces(data_e)
	var dangling_pts: Array = _points_of(dangling[0]) if dangling.size() == 1 else []
	check("DBLCLK (d): a double-click on empty space still COMMITS the trace, "
			+ "ending at the point that was double-clicked",
			dangling.size() == 1 and dangling_pts.size() == 3
			and (dangling_pts[2] as Vector2).is_equal_approx(end_point),
			"traces=%d points=%s" % [dangling.size(), str(dangling_pts)])
	check("DBLCLK (d): …the gesture ended, and the confirmation is what is read",
			canvas_e._trace_points.is_empty()
			and not msgs_e.is_empty()
			and msgs_e[msgs_e.size() - 1] != data_e.trace_author_error("", "", 0),
			"%d points left, last=%s" % [canvas_e._trace_points.size(),
					msgs_e[msgs_e.size() - 1] if not msgs_e.is_empty() else "<none>"])
	canvas_e.free()


## ── 8. THE NETLESS REFUSAL NAMES EVERY ANCHOR KIND ───────────────────────────
##
## Three sentences state where a trace's net comes from: the model's refusal —
## which minerva_pcb_add_trace hands an agent back verbatim as `note` — and the
## canvas's two start refusals. The canvas answers a click with
## _trace_anchor_at, whose kinds are ANCHOR_PAD and ANCHOR_VIA.
##
## ORACLE: those two constants, never either sentence. A kind that stops
## anchoring, or a third one that starts, fails this without anyone having to
## remember which strings mention it. The canvas leg reads the netless-PAD
## gesture on purpose: its anchor LABEL is "Pad U1.9", so "via" can only be
## satisfied by the sentence body. The verb leg compares its note byte-for-byte
## against the model's own output, so the agent-facing and click-facing surfaces
## cannot drift apart unnoticed.
func _test_netless_refusal_names_every_anchor_kind() -> void:
	print("\n-- the netless refusal names every anchor kind --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var host = rig[2]

	# THE RULE ITSELF is untouched: netless refuses, a declared net authors.
	var netless: String = data.trace_author_error("", "top", 2)
	check("RULE: a trace naming no net is refused", not netless.is_empty())
	check("RULE: …and one naming a declared net is authorable",
			data.trace_author_error("VCC", "top", 2).is_empty(),
			data.trace_author_error("VCC", "top", 2))

	# The canvas's own two refusals, taken from real gestures rather than quoted.
	var msgs: Array = []
	canvas.trace_tool_message.connect(func(t: String) -> void: msgs.append(t))
	canvas._handle_trace_click(Vector2(50.0, 35.0), false)   # empty space
	host.pads.append({"component": "U1", "pin": "9", "position": Vector2(14.0, 14.0)})
	canvas._handle_trace_click(Vector2(14.0, 14.0), false)   # a NETLESS pad
	var off_anchor: String = str(msgs[0]).to_lower() if msgs.size() > 0 else ""
	var netless_anchor: String = str(msgs[1]).to_lower() if msgs.size() > 1 else ""

	# Both canvas refusals name both kinds, so the netless leg has to prove it
	# really hit the pad: only that refusal labels the anchor it found. Without
	# this, a missed hit would fall through to the off-anchor sentence and
	# satisfy the loop below on the wrong message.
	check("the netless gesture landed ON the pad, not past it",
			netless_anchor.contains("u1.9"), netless_anchor)

	for kind in [canvas.ANCHOR_PAD, canvas.ANCHOR_VIA]:
		check("the model's refusal names the %s anchor" % str(kind),
				netless.to_lower().contains(str(kind)), netless)
		check("the canvas's netless-anchor refusal names the %s anchor" % str(kind),
				netless_anchor.contains(str(kind)), netless_anchor)
		check("the canvas's off-anchor refusal names the %s anchor" % str(kind),
				off_anchor.contains(str(kind)), off_anchor)

	# THE CALLER THAT STILL REACHES IT. A click cannot: _start_trace refuses a
	# netless anchor before the buffer arms, so _commit_trace never sees an empty
	# net. minerva_pcb_add_trace's net_name is caller-supplied text and does.
	var res: Dictionary = PanelTools._add_trace(host, {
		"net_name": "", "layer": "top", "points": [[10.0, 10.0], [20.0, 10.0]]})
	check("the verb refuses a netless trace", not bool(res.get("success", true)), str(res))
	check("…named trace_not_authorable",
			str(res.get("error", "")) == "trace_not_authorable", str(res))
	check("…carrying the model's own refusal, byte-for-byte",
			str(res.get("note", "")) == netless,
			"note=%s / model says %s" % [str(res.get("note", "")), netless])
	check("…and nothing was written", _serialized_traces(data).is_empty(),
			str(_serialized_traces(data)))

	canvas.free()


## 9. THE WORKING LAYER AUTHORS; THE VIEW SHOWS. Two controls, no crosstalk.
##
## ORACLE: the `layer` field of every SERIALIZED trace, as a multiset, drawn in
## one rig whose VIEW is moved between draws — never trace_author_layer(), which
## is the rule under test. The other half is read back through is_layer_visible,
## the predicate the draw loop itself uses, so "the view did not move" (and, in
## step 2, "the view really did move") is measured rather than assumed.
func _test_working_layer_is_not_the_view() -> void:
	print("\n-- BT-93 (9): the working layer authors, the view only shows --")
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]

	# The toolbar chooser's whole job: pick the bottom, draw on the bottom, and
	# leave both layers on screen.
	canvas.working_layer = "bottom"
	_draw_a_trace(canvas)
	check("BT-93: choosing B.Cu lands the trace on bottom",
			_trace_layers(data) == ["bottom"], str(_trace_layers(data)))
	check("BT-93: …and top copper is still drawn", bool(canvas.is_layer_visible("top")))
	check("BT-93: …as is bottom", bool(canvas.is_layer_visible("bottom")))
	check("BT-93: …with the view filter untouched",
			str(canvas.trace_layer_filter) == "all", str(canvas.trace_layer_filter))

	# An EYE is visibility and nothing else: shutting the layer being authored on
	# hides the copper already there and still lands the next trace on it.
	canvas.working_layer = "top"
	canvas.set_layer_hidden("top", true)
	_draw_a_trace(canvas)
	check("BT-93: hiding F.Cu does not move where the next trace lands",
			_trace_layers(data) == ["bottom", "top"], str(_trace_layers(data)))
	check("BT-93: …and the eye really did shut", not bool(canvas.is_layer_visible("top")))

	# The VIEW filter — the agent's half of the same separation.
	canvas.set_layer_hidden("top", false)
	canvas.trace_layer_filter = "bottom"
	_draw_a_trace(canvas)
	check("BT-93: a bottom-only view filter does not move authoring either",
			_trace_layers(data) == ["bottom", "top", "top"], str(_trace_layers(data)))
	check("BT-93: …though it does scope the view",
			not bool(canvas.is_layer_visible("top")) and bool(canvas.is_layer_visible("bottom")))

	# Refused rather than stored, so no tool ever has to ask "is the working
	# layer a layer at all".
	canvas.working_layer = "all"
	check("BT-93: \"all\" is not a working layer and does not become one",
			str(canvas.working_layer) == "top", str(canvas.working_layer))


## Every committed trace's layer, sorted — an order-independent multiset, so the
## assertions above cannot be satisfied (or broken) by serialisation order.
func _trace_layers(data) -> Array:
	var out: Array = []
	for t in _serialized_traces(data):
		out.append(str((t as Dictionary).get("layer", "")))
	out.sort()
	return out
