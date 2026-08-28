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
const PCBTraceScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_trace.gd")
## The ONE definition of design_rules.allowed_trace_angles_deg. Section 13
## measures the tool against it, and against the worker's gc12 rule it mirrors.
const PcbTraceAngles := preload("res://../../minerva-plugins/pcb/ui/model/pcb_trace_angles.gd")
const PcbOptionsMenu := preload("res://../../minerva-plugins/pcb/ui/pcb_options_menu.gd")
const PcbPrefsScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_prefs.gd")
const SnapPrefsFixture := preload("res://../../minerva-plugins/pcb/tests/gd/snap_prefs_fixture.gd")

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


## What the three snap preferences held before this run, so the developer's own
## store is handed back untouched (SnapPrefsFixture).
var _saved_snaps: Dictionary = {}


func _init() -> void:
	print("=== PCB canvas TRACE tool (BT-93) ===\n")
	# Sections 13 and 14 read the LIVE snap toggles, which are a real file in
	# the developer's user:// store — a stored snap_angle=false would turn 13b/c
	# /f red for a reason unrelated to the code. Reset to the defaults here,
	# restored before quit.
	_saved_snaps = SnapPrefsFixture.reset()
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
	_test_trace_end_anchor()
	# A COROUTINE: 13e pushes real key events through Input, which is buffered
	# until the next frame, so that section has to await one (test_pcb_canvas
	# _input_probe.gd's precedent). Awaiting it here keeps the sections ordered.
	await _test_angle_snap()
	_test_board_rules_verb_and_menu_are_one_path()
	SnapPrefsFixture.restore(_saved_snaps)
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
func _board(rule_width: float = 0.0, angles: Array = []) -> Dictionary:
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
	if not angles.is_empty():
		var rules: Dictionary = b.get("design_rules", {})
		rules["allowed_trace_angles_deg"] = angles
		b["design_rules"] = rules
	return b


func _rig(rule_width: float = 0.0, angles: Array = []) -> Array:
	var canvas = PcbCanvasScript.new()
	var data = PCBData.new()
	data.from_board_dict(_board(rule_width, angles))
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


## 10. THE TRACE-END ANCHOR: a free end continues its trace.
##
## FIXTURE: a VCC trace from pad U1.1 (10,10) to (20,10). Its start end sits on
## the pad (joined); its end at (20,10) touches nothing — the nearest pad, R1.1,
## is 10 mm away against a 1.27 mm snap, and there is no via — so it is FREE.
##
## ORACLE, every leg: the SERIALIZED board (trace count, id, every point),
## data.history / data.change_journal, and the model's own free_trace_end_at —
## never the tool's message and never its buffers. The click's result and the
## verb's are compared point for point.
func _test_trace_end_anchor() -> void:
	print("\n-- trace-end anchor: a free end continues its trace --")
	var stub_pts: Array = [Vector2(10.0, 10.0), Vector2(20.0, 10.0)]

	# (a) START from the free end, finish on pad R1.1: ONE trace, the ORIGINAL id,
	# waypoints (10,10),(20,10),(24,16),(30,10). Clicked 0.3 mm off the end so a
	# kept click point would read (20.3,10) and fail the exact-point check.
	var rig := _rig()
	var canvas = rig[0]
	var data = rig[1]
	var seed = data.create_trace_entity("VCC", "top", stub_pts)
	data.save_to_history("baseline")
	var seed_id: String = str(seed.id)
	var h0: int = data.history.size()
	var j0: int = data.change_journal.size()
	canvas._handle_trace_click(Vector2(20.3, 10.0), false)
	canvas._handle_trace_click(Vector2(24.0, 16.0), false)
	canvas._handle_trace_click(Vector2(30.0, 10.0), false)
	var after: Array = _serialized_traces(data)
	check("(a) still exactly ONE trace on the board", after.size() == 1, "traces=%d" % after.size())
	var grown_pts: Array = _points_of(after[0]) if after.size() == 1 else []
	check("(a) …with the ORIGINAL id", after.size() == 1 and str(after[0].get("id", "")) == seed_id,
			str(after))
	check("(a) …and the run appended after the free end: (10,10),(20,10),(24,16),(30,10)",
			grown_pts == [Vector2(10, 10), Vector2(20, 10), Vector2(24, 16), Vector2(30, 10)],
			str(grown_pts))
	check("(a) history grew by exactly ONE step", data.history.size() - h0 == 1,
			"delta=%d" % (data.history.size() - h0))
	var rows: Array = []
	for e in data.change_journal.slice(j0):
		rows.append(str((e as Dictionary).get("action", "")))
	check("(a) exactly one journal row, and it is extend_trace (no add_trace)",
			rows == ["extend_trace"], str(rows))
	check("(a) undo restores the two-point stub",
			data.undo() and _points_of(_serialized_traces(data)[0]) == stub_pts)
	data.redo()
	canvas.free()

	# (b) FINISH on a free end. Trace R1.1 (30,10) -> (20,10): its END is free.
	# Draw from pad U1.1 (10,10) and click the free end: the run is appended to
	# the target, reversed, so the polyline stays one piece: (30,10),(20,10),(10,10).
	rig = _rig()
	canvas = rig[0]
	data = rig[1]
	var target = data.create_trace_entity("VCC", "top", [Vector2(30.0, 10.0), Vector2(20.0, 10.0)])
	data.save_to_history("baseline")
	h0 = data.history.size()
	canvas._handle_trace_click(Vector2(10.0, 10.0), false)
	canvas._handle_trace_click(Vector2(20.3, 10.0), false)
	after = _serialized_traces(data)
	check("(b) finishing on a free end leaves ONE trace", after.size() == 1, "traces=%d" % after.size())
	check("(b) …the target's own id", after.size() == 1 and str(after[0].get("id", "")) == str(target.id))
	check("(b) …grown by the run, reversed: (30,10),(20,10),(10,10)",
			after.size() == 1 and _points_of(after[0]) == [Vector2(30, 10), Vector2(20, 10), Vector2(10, 10)],
			str(after))
	check("(b) one history step", data.history.size() - h0 == 1)
	canvas.free()

	# (c) NETLESS trace end is refused BY NAME and writes nothing.
	rig = _rig()
	canvas = rig[0]
	data = rig[1]
	var netless = PCBTraceScript.new()
	netless.net_name = ""
	netless.layer = "top"
	netless.waypoints.append(Vector2(40.0, 30.0))
	netless.waypoints.append(Vector2(46.0, 30.0))
	data.add_trace(netless)
	var msgs: Array = []
	canvas.trace_tool_message.connect(func(t: String) -> void: msgs.append(t))
	j0 = data.change_journal.size()
	canvas._handle_trace_click(Vector2(46.2, 30.0), false)
	var said: String = str(msgs[0]) if not msgs.is_empty() else ""
	check("(c) the netless trace end is refused, naming the kind and the trace",
			said.contains("Trace end") and said.contains(str(netless.id)) and said.contains("no net"), said)
	check("(c) …and nothing was written", data.change_journal.size() == j0
			and _serialized_traces(data).size() == 1)
	canvas.free()

	# (d) A JOINED end is not an anchor. A: (10,10)->(20,10); B: (20,10)->(20,20),
	# both VCC. A's end and B's start meet, so neither is free; B's end (20,20)
	# is. Asked of the model first, then of a gesture: with nothing in progress a
	# click beside the joined point is an off-anchor refusal, not a start.
	rig = _rig()
	canvas = rig[0]
	data = rig[1]
	data.create_trace_entity("VCC", "top", [Vector2(10.0, 10.0), Vector2(20.0, 10.0)])
	var b = data.create_trace_entity("VCC", "top", [Vector2(20.0, 10.0), Vector2(20.0, 20.0)])
	check("(d) the model offers NO free end at the joint",
			data.free_trace_end_at(Vector2(20.3, 10.0), canvas.TRACE_PAD_SNAP_MM).is_empty())
	var free_end: Dictionary = data.free_trace_end_at(Vector2(20.0, 20.3), canvas.TRACE_PAD_SNAP_MM)
	check("(d) …while B's far end IS free (so geometry, not the rule, excluded the joint)",
			str(free_end.get("trace_id", "")) == str(b.id) and str(free_end.get("end", "")) == "end",
			str(free_end))
	msgs = []
	canvas.trace_tool_message.connect(func(t: String) -> void: msgs.append(t))
	j0 = data.change_journal.size()
	canvas._handle_trace_click(Vector2(20.3, 10.0), false)
	check("(d) a click at the joint starts nothing (off-anchor refusal, board untouched)",
			msgs.size() == 1 and str(msgs[0]).begins_with("Start a trace")
			and data.change_journal.size() == j0, str(msgs))
	canvas.free()

	# (e) PAD WINS over a coincident free end. Trace (20,10)->(29,10): its end is
	# 1 mm from R1.1's centre — a bare-point pad, so 1 mm from its copper: free,
	# and inside the 1.27 mm snap of a click on the pad. Clicking the pad centre
	# must start a NEW trace from R1.1, not continue the stub: after finishing
	# on C1.1 the board holds TWO traces and the stub is unchanged.
	rig = _rig()
	canvas = rig[0]
	data = rig[1]
	var stub = data.create_trace_entity("VCC", "top", [Vector2(20.0, 10.0), Vector2(29.0, 10.0)])
	check("(e) fixture: the stub's end IS a free end within snap of the pad click",
			str(data.free_trace_end_at(Vector2(30.0, 10.0), canvas.TRACE_PAD_SNAP_MM).get("trace_id", ""))
				== str(stub.id))
	canvas._handle_trace_click(Vector2(30.0, 10.0), false)
	canvas._handle_trace_click(Vector2(30.0, 25.0), false)
	after = _serialized_traces(data)
	check("(e) the pad won: a SECOND trace was minted", after.size() == 2, "traces=%d" % after.size())
	var stub_after = data.get_trace(str(stub.id))
	check("(e) …and the stub is untouched",
			stub_after != null and PackedVector2Array(stub_after.waypoints)
				== PackedVector2Array([Vector2(20.0, 10.0), Vector2(29.0, 10.0)]))
	canvas.free()

	# (f) MCP PARITY. The verb given the trace end as `start` and the two
	# remaining points authors the SAME polyline (a) did, on the same id.
	rig = _rig()
	data = rig[1]
	var host = rig[2]
	var seed_v = data.create_trace_entity("VCC", "top", stub_pts)
	data.save_to_history("baseline")
	h0 = data.history.size()
	var res: Dictionary = PanelTools._add_trace(host, {
		"start": {"trace_id": str(seed_v.id), "end": "end"},
		"points": [[24.0, 16.0], [30.0, 10.0]],
	})
	check("(f) the verb accepted a trace-end start with no net_name/layer", bool(res.get("success", false)), str(res))
	after = _serialized_traces(data)
	check("(f) the verb's polyline equals the click's, on the seed's id",
			after.size() == 1 and str(after[0].get("id", "")) == str(seed_v.id)
			and _points_of(after[0]) == grown_pts, "%s vs %s" % [str(after), str(grown_pts)])
	check("(f) the verb reports extended_from=end and the grown point count",
			str(res.get("extended_from", "")) == "end" and int(res.get("point_count", 0)) == 4, str(res))
	check("(f) one history step for the verb too", data.history.size() - h0 == 1)
	# The verb refuses what the click declines: the seed's START end sits on
	# pad U1.1 and is joined.
	res = PanelTools._add_trace(host, {
		"start": {"trace_id": str(seed_v.id), "end": "start"}, "points": [[5.0, 5.0]]})
	check("(f) a joined end is refused as trace_end_not_free",
			str(res.get("error", "")) == "trace_end_not_free", str(res))
	# …and a finish on a free end joins by extending, like (b).
	var target_v = data.create_trace_entity("GND", "top", [Vector2(30.0, 25.0), Vector2(40.0, 25.0)])
	res = PanelTools._add_trace(host, {
		"net_name": "GND", "layer": "top", "points": [[40.0, 35.0]],
		"end": {"trace_id": str(target_v.id), "end": "end"}})
	var joined = data.get_trace(str(target_v.id))
	check("(f) an `end` anchor appends the run reversed to the target: (30,25),(40,25),(40,35)",
			bool(res.get("success", false)) and joined != null
			and PackedVector2Array(joined.waypoints)
				== PackedVector2Array([Vector2(30, 25), Vector2(40, 25), Vector2(40, 35)]), str(res))
	rig[0].free()

	# (g) NEAREST END WINS on a short stub: a 2 mm free-floating trace has both
	# ends within snap of any click on it; a click 0.3 mm past its END must
	# answer the end, not the start that is tested first.
	rig = _rig()
	data = rig[1]
	var stub2 = data.create_trace_entity("VCC", "top", [Vector2(40.0, 30.0), Vector2(42.0, 30.0)])
	var near_end: Dictionary = data.free_trace_end_at(Vector2(42.3, 30.0), data.TRACE_SNAP_MM)
	check("(g) a click 0.3 mm past a 2 mm stub's END answers its end",
			str(near_end.get("trace_id", "")) == str(stub2.id) and str(near_end.get("end", "")) == "end",
			str(near_end))
	var near_start: Dictionary = data.free_trace_end_at(Vector2(39.7, 30.0), data.TRACE_SNAP_MM)
	check("(g) …and 0.3 mm before its START answers the start",
			str(near_start.get("end", "")) == "start", str(near_start))
	# (h) LOCKED: a locked trace offers no free end, to the click or the verb.
	stub2.locked = true
	check("(h) a locked trace offers no free end",
			data.free_trace_end_at(Vector2(42.3, 30.0), data.TRACE_SNAP_MM).is_empty())
	var locked_res: Dictionary = PanelTools._add_trace(rig[2], {
		"start": {"trace_id": str(stub2.id), "end": "end"}, "points": [[50.0, 30.0]]})
	check("(h) …and the verb refuses it as trace_locked",
			str(locked_res.get("error", "")) == "trace_locked", str(locked_res))
	# THE MODEL refuses a locked trace on its own, writing no row.
	j0 = data.change_journal.size()
	var model_locked: String = data.extend_trace(str(stub2.id), "end", PackedVector2Array([Vector2(50.0, 30.0)]))
	check("(h) extend_trace itself refuses a locked trace, recognisably, writing no row",
			data.is_locked_refusal(model_locked) and data.change_journal.size() == j0
				and stub2.waypoints.size() == 2, model_locked)
	stub2.locked = false
	# (j) AN END THAT STOPPED BEING FREE is refused at the write: the pick said
	# free, then a same-net trace landed on the end before the extension.
	var picked_free: Dictionary = data.free_trace_end_at(Vector2(42.3, 30.0), data.TRACE_SNAP_MM)
	check("(j) fixture: the stub's end reads free before the joiner lands",
			str(picked_free.get("end", "")) == "end")
	var joiner = data.create_trace_entity("VCC", "top", [Vector2(42.0, 30.0), Vector2(42.0, 25.0)])
	j0 = data.change_journal.size()
	var model_joined: String = data.extend_trace(str(stub2.id), "end", PackedVector2Array([Vector2(50.0, 30.0)]))
	check("(j) extend_trace refuses the now-joined end, recognisably, writing no row",
			data.is_joined_end_refusal(model_joined) and data.change_journal.size() == j0
				and stub2.waypoints.size() == 2, model_joined)
	var joined_res: Dictionary = PanelTools._add_trace(rig[2], {
		"start": {"trace_id": str(stub2.id), "end": "end"}, "points": [[50.0, 30.0]]})
	check("(j) …and the verb names it trace_end_not_free",
			str(joined_res.get("error", "")) == "trace_end_not_free", str(joined_res))
	data.remove_trace(str(joiner.id))   # the stub's end is free again for (i)
	# (i) A LOOP IS REFUSED: starting from one free end and finishing on the
	# same trace's other end would close it — refused by name, nothing written.
	canvas = rig[0]
	msgs = []
	canvas.trace_tool_message.connect(func(t: String) -> void: msgs.append(t))
	j0 = data.change_journal.size()
	canvas._handle_trace_click(Vector2(42.3, 30.0), false)   # start from the END
	canvas._handle_trace_click(Vector2(42.0, 36.0), false)   # a waypoint
	canvas._handle_trace_click(Vector2(39.7, 30.0), false)   # the same trace's START
	check("(i) finishing on the extended trace's own other end is refused, naming the loop",
			str(msgs[msgs.size() - 1]).contains("loop") and data.change_journal.size() == j0
				and PackedVector2Array(stub2.waypoints).size() == 2, str(msgs))
	var loop_res: Dictionary = PanelTools._add_trace(rig[2], {
		"start": {"trace_id": str(stub2.id), "end": "end"},
		"end": {"trace_id": str(stub2.id), "end": "start"}, "points": [[42.0, 36.0]]})
	check("(i) …and the verb refuses the same as trace_end_same_trace",
			str(loop_res.get("error", "")) == "trace_end_same_trace", str(loop_res))
	canvas.free()


## The heading of the single committed trace's one segment, folded the way the
## board's rule is: degrees in [0, 180) from +X toward +Y in the board's y-down
## frame. Read off the SERIALIZED entity, never off the tool's buffer.
func _committed_heading(data) -> float:
	var traces := _serialized_traces(data)
	if traces.size() != 1:
		return -1.0
	var points: Array = (traces[0] as Dictionary).get("points", [])
	if points.size() < 2:
		return -1.0
	var a: Dictionary = points[0]
	var b: Dictionary = points[points.size() - 1]
	return PcbTraceAngles.heading_deg(
		Vector2(float(a.get("x_mm", 0.0)), float(a.get("y_mm", 0.0))),
		Vector2(float(b.get("x_mm", 0.0)), float(b.get("y_mm", 0.0))))


## The last point of the single committed trace, in board mm.
func _committed_end(data) -> Vector2:
	var traces := _serialized_traces(data)
	if traces.size() != 1:
		return Vector2.INF
	var points: Array = (traces[0] as Dictionary).get("points", [])
	if points.is_empty():
		return Vector2.INF
	var p: Dictionary = points[points.size() - 1]
	return Vector2(float(p.get("x_mm", 0.0)), float(p.get("y_mm", 0.0)))


## Draw one run from U1.1 and finish it in open board with a double-click, so
## the endpoint is a WAYPOINT the snap owns rather than a pad centre the anchor
## rung owns. Returns the rig.
func _drag_from_u1(angles: Array, toward: Vector2, snap_grid: bool = false) -> Array:
	var rig := _rig(0.0, angles)
	var canvas = rig[0]
	canvas.snap_to_grid = snap_grid
	canvas._handle_trace_click(Vector2(10.0, 10.0), false)   # start on U1.1 (VCC)
	canvas._handle_trace_click(toward, false)                # the snapped waypoint
	canvas._commit_trace()
	return rig


## 13. THE ANGLE SNAP — the Trace tool draws only in directions the BOARD allows.
##
## ORACLE, throughout: the heading of the SERIALIZED trace, measured by the same
## fold the worker's gc12 check uses (PcbTraceAngles, which mirrors
## drc_geometric._check_gc12_trace_direction byte for byte on the same 1 um
## perpendicular tolerance). A run this tool draws must be a run that check
## passes — that is the whole contract, and measuring the drawn copper against
## the shared definition rather than against a hand-typed number is what pins it.
##
## The drag is 37 degrees on purpose: it is near nothing, so every mode has to
## move it somewhere different and no two expected answers coincide.
func _test_angle_snap() -> void:
	print("-- (13) the Trace tool snaps to design_rules.allowed_trace_angles_deg --")
	# A 37-degree direction from U1.1, long enough that the snap is unambiguous
	# and short enough that no snapped end lands within TRACE_SNAP_MM of R1.1
	# (30,10) or C1.1 (30,25) — an endpoint the anchor rung claimed would be
	# testing the finish path instead of the snap.
	var away := Vector2(10.0, 10.0) + Vector2(8.0, 8.0 * tan(deg_to_rad(37.0)))

	# (a) FREE — the board declares nothing, so the tool invents no constraint.
	var free_rig := _drag_from_u1([], away)
	check("(13a) a board declaring no angles draws the 37-degree run untouched",
			is_equal_approx(_committed_heading(free_rig[1]), 37.0),
			"heading=%f" % _committed_heading(free_rig[1]))
	free_rig[0].free()

	# (b) MANHATTAN — the same drag lands on an axis. ONE segment, not an L: the
	# tool quantises the DIRECTION of the run being drawn; a corner is a second
	# click, which is the human's to place.
	var man_rig := _drag_from_u1([0, 90], away)
	var man_data = man_rig[1]
	check("(13b) …on a Manhattan board the same drag commits ONE segment",
			(_serialized_traces(man_data)[0] as Dictionary).get("points", []).size() == 2,
			str(_serialized_traces(man_data)))
	check("(13b) …running on an axis (37 is nearer 0 than 90, so 0)",
			is_equal_approx(_committed_heading(man_data), 0.0),
			"heading=%f" % _committed_heading(man_data))
	check("(13b) …and gc12's own rule agrees the run conforms",
			PcbTraceAngles.conforms(Vector2(10.0, 10.0), _committed_end(man_data), [0.0, 90.0]))
	man_rig[0].free()

	# (c) OCTILINEAR — 37 is nearest 45, and a steep drag is nearest 90. Two
	# answers from one set, so a snap that always picked the first entry fails.
	var oct_rig := _drag_from_u1([0, 45, 90, 135], away)
	check("(13c) an Octilinear board pulls the 37-degree run onto 45",
			is_equal_approx(_committed_heading(oct_rig[1]), 45.0),
			"heading=%f" % _committed_heading(oct_rig[1]))
	oct_rig[0].free()
	var steep := Vector2(10.0, 10.0) + Vector2(8.0 * tan(deg_to_rad(10.0)), 8.0)
	var steep_rig := _drag_from_u1([0, 45, 90, 135], steep)
	check("(13c) …and an 80-degree run onto 90, from the same set",
			is_equal_approx(_committed_heading(steep_rig[1]), 90.0),
			"heading=%f" % _committed_heading(steep_rig[1]))
	steep_rig[0].free()

	# (d) THE FRAME, pinned where a sign error would show. The board frame is
	# y-DOWN, so a run heading UP-and-right folds to 135, not 45. An asymmetric
	# set is the only one that can catch a negation: {0,45,90,135} maps to
	# itself under the y-flip, so it would pass either way.
	var only45_rig := _rig(0.0, [45])
	var only45 = only45_rig[0]
	only45.snap_to_grid = false
	only45._handle_trace_click(Vector2(30.0, 25.0), false)   # start on C1.1 (GND)
	only45._handle_trace_click(Vector2(30.0, 25.0) + Vector2(10.0, -6.0), false)
	only45._commit_trace()
	check("(13d) a board allowing 45 alone pulls an UP-right drag onto 45 too — "
			+ "the set is a set of lines, and 45 is the down-right diagonal in the board's y-down frame",
			is_equal_approx(_committed_heading(only45_rig[1]), 45.0),
			"heading=%f" % _committed_heading(only45_rig[1]))
	only45.free()
	# …and the pure fold agrees, on the two headings the worker's own test pins.
	check("(13d) heading_deg folds a down-right diagonal to 45",
			is_equal_approx(PcbTraceAngles.heading_deg(Vector2(5, 5), Vector2(15, 15)), 45.0))
	check("(13d) …and an up-right diagonal to 135",
			is_equal_approx(PcbTraceAngles.heading_deg(Vector2(5, 15), Vector2(15, 5)), 135.0))
	check("(13d) a 45-degree run conforms to Octilinear and NOT to Manhattan",
			PcbTraceAngles.conforms(Vector2(5, 5), Vector2(15, 15), [0, 45, 90, 135])
				and not PcbTraceAngles.conforms(Vector2(5, 5), Vector2(15, 15), [0, 90]))
	check("(13d) …and so does a 135-degree one",
			PcbTraceAngles.conforms(Vector2(5, 15), Vector2(15, 5), [0, 45, 90, 135])
				and not PcbTraceAngles.conforms(Vector2(5, 15), Vector2(15, 5), [0, 90]))

	# (e) SHIFT IS THE ESCAPE HATCH — one free-angle segment without changing
	# the board's rule. Pushed through Input, which is where the canvas reads it
	# (a gesture is not an event: the modifier is consulted per motion frame).
	#
	# EACH PUSH IS FOLLOWED BY A FRAME. Input.parse_input_event is BUFFERED —
	# Input.is_key_pressed, which `_free_angle_held()` reads, does not report the
	# key until the buffer is flushed on the next frame. Read in the same frame,
	# the "holding Shift drops the constraint" check would fail and the "release
	# restores it" check would pass vacuously, both for the same reason. Same
	# await-per-event discipline as test_pcb_canvas_input_probe.gd's _set_ctrl.
	var shift_rig := _rig(0.0, [0, 90])
	var shift_canvas = shift_rig[0]
	shift_canvas.snap_to_grid = false
	shift_canvas._handle_trace_click(Vector2(10.0, 10.0), false)
	check("(13e) fixture: the run is angle-constrained before Shift goes down",
			shift_canvas._trace_allowed_angles() == ([0.0, 90.0] as Array[float]),
			str(shift_canvas._trace_allowed_angles()))
	var shift_down := InputEventKey.new()
	shift_down.keycode = KEY_SHIFT
	shift_down.physical_keycode = KEY_SHIFT
	shift_down.pressed = true
	Input.parse_input_event(shift_down)
	await process_frame
	check("(13e) holding Shift drops the constraint for the segment being drawn, "
			+ "without touching the board rule",
			shift_canvas._trace_allowed_angles().is_empty()
				and shift_rig[1].design_rule_trace_angles() == ([0.0, 90.0] as Array[float]),
			str(shift_canvas._trace_allowed_angles()))
	var shift_up := InputEventKey.new()
	shift_up.keycode = KEY_SHIFT
	shift_up.physical_keycode = KEY_SHIFT
	shift_up.pressed = false
	Input.parse_input_event(shift_up)
	await process_frame
	check("(13e) …and releasing it puts the constraint straight back",
			shift_canvas._trace_allowed_angles() == ([0.0, 90.0] as Array[float]),
			str(shift_canvas._trace_allowed_angles()))
	shift_canvas.free()

	# (f) GRID LAST, AND ALONG THE RUN. Quantising x and y independently would
	# push the endpoint off the direction the angle snap just chose, so the
	# DISTANCE along the direction is what the grid quantises. On a 2.54 mm
	# board grid the authoring step is 0.635 mm, and a 45-degree run must land
	# on whole steps in BOTH axes at once.
	var grid_rig := _drag_from_u1([0, 45, 90, 135], away, true)
	var end := _committed_end(grid_rig[1])
	var delta := end - Vector2(10.0, 10.0)
	check("(13f) with grid snap on, the 45-degree run is still exactly 45",
			is_equal_approx(_committed_heading(grid_rig[1]), 45.0),
			"heading=%f end=%s" % [_committed_heading(grid_rig[1]), str(end)])
	check("(13f) …and both axes moved by a whole 0.635 mm authoring step",
			is_equal_approx(delta.x, roundf(delta.x / 0.635) * 0.635)
				and is_equal_approx(delta.y, roundf(delta.y / 0.635) * 0.635),
			"delta=%s" % str(delta))
	grid_rig[0].free()


## 14. THE MENU AND THE VERB ARE ONE PATH.
##
## ORACLE: the BOARD's own design_rules dict and the model's history depth —
## read after a write made through the MCP verb, and compared against what the
## shared read reports. The menu calls the same two functions
## (PcbOptionsMenu.read_state / apply), so pinning the verb against the model
## pins both; a second implementation is what this suite exists to prevent.
func _test_board_rules_verb_and_menu_are_one_path() -> void:
	print("-- (14) minerva_pcb_board_rules and the Options menu are one path --")
	var rig := _rig(0.0, [0, 90])
	var canvas = rig[0]
	var data = rig[1]
	var host = rig[2]
	var prefs = PcbPrefsScript.shared()

	# READ: the verb's reply IS the shared read, and it names the board's mode.
	var read: Dictionary = PanelTools._board_rules(host, {"editor_name": "probe"})
	check("(14) the read reports the board's declared set as a named mode",
			str(read.get("trace_angle_mode", "")) == PcbTraceAngles.MODE_MANHATTAN,
			str(read))
	check("(14) …and the same read the menu builds itself from agrees",
			str(PcbOptionsMenu.read_state(data, prefs).get("trace_angle_mode", "")) == "manhattan")
	check("(14) a rule the board does not declare reads as 0.0, not as a fallback",
			is_equal_approx(float((read.get("design_rules", {}) as Dictionary).get("clearance_mm", -1.0)), 0.0),
			str(read.get("design_rules", {})))

	# WRITE: the mode lands on the BOARD, as one undo step.
	var depth_before: int = int(data.history_index)
	var wrote: Dictionary = PanelTools._board_rules(host, {
		"editor_name": "probe", "trace_angle_mode": "octilinear"})
	check("(14) writing the mode writes design_rules.allowed_trace_angles_deg on the board",
			data.design_rule_trace_angles() == ([0.0, 45.0, 90.0, 135.0] as Array[float]),
			str(data.design_rules))
	check("(14) …the reply names what moved and reads the new mode back",
			(wrote.get("changed", []) as Array).has("allowed_trace_angles_deg")
				and str(wrote.get("trace_angle_mode", "")) == "octilinear", str(wrote))
	check("(14) …and it is exactly ONE undo step",
			int(data.history_index) == depth_before + 1,
			"before=%d after=%d" % [depth_before, int(data.history_index)])

	# The Trace tool reads the new rule immediately — no reload, no re-arm.
	canvas._handle_trace_click(Vector2(10.0, 10.0), false)
	check("(14) the Trace tool picks the new set up on the very next click",
			canvas._trace_allowed_angles() == ([0.0, 45.0, 90.0, 135.0] as Array[float]),
			str(canvas._trace_allowed_angles()))
	canvas._cancel_trace_draw(false)

	# FREE removes the key rather than storing an empty list: the worker refuses
	# `[]` in YAML, and an absent key is how "no constraint" is spelled.
	PanelTools._board_rules(host, {"editor_name": "probe", "trace_angle_mode": "free"})
	check("(14) Free REMOVES the key rather than writing an empty list",
			not (data.design_rules as Dictionary).has("allowed_trace_angles_deg"),
			str(data.design_rules))

	# REFUSALS change nothing at all, and name what was wrong.
	var numeric: Dictionary = PanelTools._board_rules(host, {
		"editor_name": "probe", "trace_width_mm": 0.3, "clearance_mm": 99.0})
	check("(14) an out-of-range value refuses the WHOLE write — the good half does not land",
			not bool(numeric.get("success", false))
				and is_equal_approx(data.design_rule_trace_width(), 0.0),
			str(numeric))
	var both: Dictionary = PanelTools._board_rules(host, {
		"editor_name": "probe", "trace_angle_mode": "manhattan",
		"allowed_trace_angles_deg": [0, 45]})
	check("(14) passing a mode AND an angle list is refused, not silently resolved",
			not bool(both.get("success", false)), str(both))
	var unknown: Dictionary = PanelTools._board_rules(host, {
		"editor_name": "probe", "trace_angle_mode": "diagonal"})
	check("(14) an unknown mode names the modes that exist",
			str(unknown.get("error", "")).contains("octilinear"), str(unknown))

	# A key nobody knows is refused by NAME. The apply loops only read keys they
	# recognise, so without this a misspelling would report ok with changed:[].
	var misspelled: Dictionary = PanelTools._board_rules(host, {
		"editor_name": "probe", "trace_width": 0.3})
	check("(14) an unknown KEY is refused, naming it and the keys that are accepted",
			not bool(misspelled.get("success", false))
				and str(misspelled.get("error", "")).contains("trace_width")
				and str(misspelled.get("error", "")).contains("trace_width_mm"),
			str(misspelled))
	check("(14) …and it changed nothing — no half-write, no silent no-op reported as ok",
			not (data.design_rules as Dictionary).has("trace_width_mm"),
			str(data.design_rules))

	# A board declaring a set this menu cannot express says so, rather than
	# reporting the nearest offered mode.
	PanelTools._board_rules(host, {"editor_name": "probe", "allowed_trace_angles_deg": [30, 120]})
	var custom: Dictionary = PanelTools._board_rules(host, {"editor_name": "probe"})
	check("(14) a set neither mode names reads back as \"custom\"",
			str(custom.get("trace_angle_mode", "")) == PcbTraceAngles.MODE_CUSTOM, str(custom))
	check("(14) …carrying the board's own angles, folded and sorted",
			str(custom.get("allowed_trace_angles_deg", [])) == str([30.0, 120.0] as Array[float]),
			str(custom.get("allowed_trace_angles_deg", [])))
	canvas.free()
