extends SceneTree
## Cutting a trace at an interior vertex: the model op (pcb_data.cut_trace),
## the canvas's "Cut here" menu item and the MCP verb minerva_pcb_cut_trace,
## all one path.
##
## ORACLE, every leg: the trace's own waypoints and id read back off the model,
## data.history / data.change_journal, and free_trace_end_at — never a tool's
## message and never a reply field that the reply itself computed (the verb's
## numbers are checked AGAINST the waypoints).
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout> (same convention as
## every suite here — see test_routing_workspace_model.gd's header).

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")

var _pass := 0
var _fail := 0


## Minimal duck-typed host — panel_tools._get_data(host) only needs
## get_board_data() (same stand-in shape as test_trace_identity_delete.gd).
class _StubHost extends RefCounted:
	var _data
	var _panel = null
	func _init(d, panel = null) -> void:
		_data = d
		_panel = panel
	func get_board_data():
		return _data
	func get_panel():
		return _panel


## The panel seam panel_tools._get_workspace reads: get_routing_workspace().
class _StubPanel extends RefCounted:
	var _ws
	func _init(ws) -> void:
		_ws = ws
	func get_routing_workspace():
		return _ws


func _init() -> void:
	print("=== Trace cut at an interior vertex ===\n")
	_run_model_cut()
	_run_model_refusals()
	_run_verb_forms_agree()
	_run_cut_end_is_free_unless_joined()
	_run_menu_item()
	_run_locked_and_committed_copper()
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
		printerr("  FAIL: %s%s" % [desc, "" if detail.is_empty() else " — " + detail])


## One part on VCC at (10,10) with a bare-point pin, a declared 2-layer stack.
func _board() -> Dictionary:
	return {
		"version": 1, "name": "CutBoard", "width_mm": 60.0, "height_mm": 40.0,
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 10.0, "y_mm": 10.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		],
		"nets": [{"name": "VCC", "pins": ["U1.1"]}],
	}


## A four-bend VCC trace: (10,10) on the pad, then (20,10), (20,20), (30,20),
## (30,30). Interior vertices are indices 1..3.
const _RUN: Array = [Vector2(10, 10), Vector2(20, 10), Vector2(20, 20), Vector2(30, 20), Vector2(30, 30)]


func _data_with_trace() -> Array:
	var data = PCBData.new()
	data.from_board_dict(_board())
	var trace = data.create_trace_entity("VCC", "top", _RUN)
	data.save_to_history("baseline")
	return [data, str(trace.id)]


func _points(data, trace_id: String) -> PackedVector2Array:
	var t = data.get_trace(trace_id)
	return PackedVector2Array(t.waypoints) if t != null else PackedVector2Array()


func _rows(data, since: int, action: String) -> Array:
	var out: Array = []
	for e in data.change_journal.slice(since):
		if str((e as Dictionary).get("action", "")) == action:
			out.append(e)
	return out


# ── 1. the model op ──────────────────────────────────────────────────────────

func _run_model_cut() -> void:
	print("-- 1. cut_trace keeps the head, drops the tail, one row, undoable --")
	var rig := _data_with_trace()
	var data = rig[0]
	var id: String = rig[1]
	var h0: int = data.history.size()
	var j0: int = data.change_journal.size()

	var error: String = data.cut_trace(id, 2)
	check("cutting at interior vertex 2 succeeds", error.is_empty(), error)
	check("the trace keeps its id", data.get_trace(id) != null)
	check("the head (10,10),(20,10),(20,20) is kept, the tail dropped",
		_points(data, id) == PackedVector2Array([Vector2(10, 10), Vector2(20, 10), Vector2(20, 20)]),
		str(_points(data, id)))
	check("still exactly one trace", data.traces.size() == 1)
	check("the model itself takes NO history step (the caller owns it)",
		data.history.size() == h0, "delta=%d" % (data.history.size() - h0))
	var rows := _rows(data, j0, "cut_trace")
	check("exactly one cut_trace journal row", rows.size() == 1
		and data.change_journal.size() - j0 == 1, str(data.change_journal.slice(j0)))
	if rows.size() == 1:
		var d: Dictionary = rows[0]["details"]
		check("the row names trace, index, dropped count (2), net and layer",
			str(d.get("trace_id", "")) == id and int(d.get("at_index", -1)) == 2
			and int(d.get("dropped_count", -1)) == 2 and str(d.get("net_name", "")) == "VCC"
			and str(d.get("layer", "")) == "top", str(d))
	data.save_to_history("Cut trace")
	check("undo restores all five points",
		data.undo() and _points(data, id) == PackedVector2Array(_RUN), str(_points(data, id)))
	check("redo cuts it again", data.redo() and _points(data, id).size() == 3)


# ── 2. refusals ──────────────────────────────────────────────────────────────

func _run_model_refusals() -> void:
	print("-- 2. ends and short traces are refused by name, changing nothing --")
	var rig := _data_with_trace()
	var data = rig[0]
	var id: String = rig[1]
	var j0: int = data.change_journal.size()

	var at_start: String = data.cut_trace(id, 0)
	check("index 0 (the start) is refused", not at_start.is_empty())
	check("...and the refusal names the index and calls it an end",
		at_start.contains("0") and at_start.to_lower().contains("end"), at_start)
	var at_end: String = data.cut_trace(id, 4)
	check("the last index is refused", not at_end.is_empty() and at_end.contains("4"), at_end)
	check("an out-of-range index is refused", not data.cut_trace(id, 9).is_empty())
	check("a negative index is refused", not data.cut_trace(id, -1).is_empty())
	var missing: String = data.cut_trace("trace:nope", 1)
	check("an unknown trace is refused by id", missing.contains("trace:nope"), missing)

	var stub = data.create_trace_entity("VCC", "top", [Vector2(40, 10), Vector2(50, 10)])
	var short: String = data.cut_trace(str(stub.id), 1)
	check("a 2-point trace is refused (no interior)", not short.is_empty() and short.contains("2"), short)

	check("no refusal wrote a journal row", _rows(data, j0, "cut_trace").is_empty())
	check("...and the five-point trace is intact", _points(data, id) == PackedVector2Array(_RUN))


# ── 3. the verb: index form and coordinate form agree ────────────────────────

func _run_verb_forms_agree() -> void:
	print("-- 3. minerva_pcb_cut_trace: at_index and x_mm/y_mm pick the same vertex --")
	var a := _data_with_trace()
	var host_a := _StubHost.new(a[0])
	var h0: int = a[0].history.size()
	var by_index: Dictionary = PanelTools._cut_trace(host_a, {"trace_id": a[1], "at_index": 3})
	check("index form succeeds", bool(by_index.get("success", false)), str(by_index))
	check("the reply's counts match the waypoints: kept 4, dropped 1",
		int(by_index.get("kept_point_count", 0)) == _points(a[0], a[1]).size()
		and _points(a[0], a[1]).size() == 4 and int(by_index.get("dropped_count", 0)) == 1, str(by_index))
	check("index form: ONE history step", a[0].history.size() - h0 == 1)

	# The coordinate form: (30.4, 19.8) is 0.45 mm from vertex 3 (30,20) and
	# 10 mm from vertex 2 — inside snap for one, outside for the other.
	var b := _data_with_trace()
	var host_b := _StubHost.new(b[0])
	var by_xy: Dictionary = PanelTools._cut_trace(host_b, {"trace_id": b[1], "x_mm": 30.4, "y_mm": 19.8})
	check("coordinate form succeeds", bool(by_xy.get("success", false)), str(by_xy))
	check("...picking vertex 3", int(by_xy.get("at_index", -1)) == 3, str(by_xy))
	check("both forms leave the SAME polyline", _points(a[0], a[1]) == _points(b[0], b[1]),
		"%s vs %s" % [str(_points(a[0], a[1])), str(_points(b[0], b[1]))])

	# Coordinate form beside an END vertex: (30,30) is the last point; nothing
	# interior is within 1.27 mm of (30.2, 30.1), so it is refused, not rounded
	# to the nearest interior vertex 10 mm away.
	var c := _data_with_trace()
	var host_c := _StubHost.new(c[0])
	var at_tail: Dictionary = PanelTools._cut_trace(host_c, {"trace_id": c[1], "x_mm": 30.2, "y_mm": 30.1})
	check("a point beside the END vertex is refused as no_vertex_in_reach",
		str(at_tail.get("error", "")) == "no_vertex_in_reach", str(at_tail))
	check("...and the trace is intact", _points(c[0], c[1]) == PackedVector2Array(_RUN))
	var end_form: Dictionary = PanelTools._cut_trace(host_c, {"trace_id": c[1], "at_index": 4})
	check("the index form at the end is refused as trace_not_cuttable",
		str(end_form.get("error", "")) == "trace_not_cuttable", str(end_form))
	check("a missing trace is no_such_trace",
		str(PanelTools._cut_trace(host_c, {"trace_id": "trace:nope", "at_index": 1}).get("error", "")) == "no_such_trace")
	check("neither form given is a usage error",
		not bool(PanelTools._cut_trace(host_c, {"trace_id": c[1]}).get("success", true)))


# ── 4. the cut end is free — unless something joins it ───────────────────────

func _run_cut_end_is_free_unless_joined() -> void:
	print("-- 4. after a cut the new end is a free end, unless it sits on a pad --")
	var rig := _data_with_trace()
	var data = rig[0]
	var id: String = rig[1]
	check("before the cut, (20,20) is not an end, so not a free end there",
		data.free_trace_end_at(Vector2(20.0, 20.3), data.TRACE_SNAP_MM).is_empty())
	var host := _StubHost.new(data)
	var res: Dictionary = PanelTools._cut_trace(host, {"trace_id": id, "at_index": 2})
	var found: Dictionary = data.free_trace_end_at(Vector2(20.0, 20.3), data.TRACE_SNAP_MM)
	check("after the cut, the model offers (20,20) as the trace's free END",
		str(found.get("trace_id", "")) == id and str(found.get("end", "")) == "end", str(found))
	check("...and the reply agreed (free_end: true)", bool(res.get("free_end", false)), str(res))

	# JOINED: a trace whose interior vertex sits ON the pad. (30,10),(10,10),(10,30)
	# — vertex 1 is U1.1's centre. Cut there: the new end is on the pad, not free.
	var data2 = PCBData.new()
	data2.from_board_dict(_board())
	var on_pad = data2.create_trace_entity("VCC", "top", [Vector2(30, 10), Vector2(10, 10), Vector2(10, 30)])
	data2.save_to_history("baseline")
	var res2: Dictionary = PanelTools._cut_trace(_StubHost.new(data2), {"trace_id": str(on_pad.id), "at_index": 1})
	check("a cut whose new end lands on a pad succeeds", bool(res2.get("success", false)), str(res2))
	check("...but that end is NOT free (the model offers nothing there)",
		data2.free_trace_end_at(Vector2(10.0, 10.0), data2.TRACE_SNAP_MM).is_empty())
	check("...and the reply says so (free_end: false)", not bool(res2.get("free_end", true)), str(res2))


# ── 5. the menu item ─────────────────────────────────────────────────────────

func _run_menu_item() -> void:
	print("-- 5. 'Cut here' on a selected trace runs the same model path --")
	var rig := _data_with_trace()
	var data = rig[0]
	var id: String = rig[1]
	var canvas = PcbCanvasScript.new()
	canvas.data = data
	canvas.zoom = 10.0
	canvas._create_context_menu()

	# The press half writes these; the release half reads them. Aimed 0.3 mm
	# from vertex 2 (20,20).
	canvas.context_menu_world_pos = Vector2(20.3, 20.0)
	canvas._context_menu_target = [canvas.KIND_TRACE, id]
	canvas._update_context_menu_for_selection()
	var cut_i := _menu_index(canvas, "Cut here")
	check("the menu offers Cut here for a trace", cut_i >= 0)
	check("...enabled beside an interior vertex", cut_i >= 0 and not canvas.context_menu.is_item_disabled(cut_i))

	var h0: int = data.history.size()
	var j0: int = data.change_journal.size()
	canvas._on_context_menu_pressed(canvas.MENU_ID_CUT_TRACE)
	check("choosing it cuts at vertex 2: three points kept, same id",
		_points(data, id) == PackedVector2Array([Vector2(10, 10), Vector2(20, 10), Vector2(20, 20)]),
		str(_points(data, id)))
	check("the menu path journals ONE cut_trace row", _rows(data, j0, "cut_trace").size() == 1
		and data.change_journal.size() - j0 == 1)
	check("...and takes ONE history step", data.history.size() - h0 == 1)
	check("undo restores the five points", data.undo() and _points(data, id) == PackedVector2Array(_RUN))

	# Beside an END vertex the item is shown but disabled, and pressing it
	# anyway is a named refusal that writes nothing.
	canvas.context_menu_world_pos = Vector2(30.2, 30.1)
	canvas._update_context_menu_for_selection()
	cut_i = _menu_index(canvas, "Cut here")
	check("beside the end vertex the item is disabled", cut_i >= 0 and canvas.context_menu.is_item_disabled(cut_i))
	var messages: Array = []
	canvas.trace_tool_message.connect(func(t: String) -> void: messages.append(t))
	j0 = data.change_journal.size()
	canvas._on_context_menu_pressed(canvas.MENU_ID_CUT_TRACE)
	check("pressing it there refuses by name and writes nothing",
		messages.size() == 1 and str(messages[0]).to_lower().contains("end")
		and data.change_journal.size() == j0, str(messages))
	canvas.free()


func _menu_index(canvas, text: String) -> int:
	for i in canvas.context_menu.item_count:
		if str(canvas.context_menu.get_item_text(i)).begins_with(text):
			return i
	return -1


# ── 6. a locked trace refuses; committed copper retires its commit ───────────

## A workspace record whose committed copper IS the fixture's five-point run.
func _record_for_run() -> Dictionary:
	var segs: Array = []
	for i in range(_RUN.size() - 1):
		segs.append({"start": [(_RUN[i] as Vector2).x, (_RUN[i] as Vector2).y],
			"end": [(_RUN[i + 1] as Vector2).x, (_RUN[i + 1] as Vector2).y], "layer": "top"})
	return {"net": "VCC", "segments": segs, "vias": [], "source_hints": [],
		"source_hint_ids": [], "width_override": 0.2}


func _run_locked_and_committed_copper() -> void:
	print("-- 6. a locked trace is refused; cutting committed copper retires the commit --")
	var rig := _data_with_trace()
	var data = rig[0]
	var id: String = rig[1]
	data.get_trace(id).locked = true
	var refused: Dictionary = PanelTools._cut_trace(_StubHost.new(data), {"trace_id": id, "at_index": 2})
	check("the verb refuses a locked trace as trace_locked",
		str(refused.get("error", "")) == "trace_locked" and _points(data, id).size() == 5, str(refused))
	# THE MODEL refuses on its own: a direct caller gets the same "no".
	var j_locked: int = data.change_journal.size()
	var model_said: String = data.cut_trace(id, 2)
	check("cut_trace itself refuses a locked trace, recognisably, writing no row",
		data.is_locked_refusal(model_said) and _points(data, id).size() == 5
			and data.change_journal.size() == j_locked, model_said)
	data.get_trace(id).locked = false

	# COMMITTED COPPER, through the verb: the candidate's commit lands the trace,
	# the cut changes its shape, and the commit is retired in the same step.
	var data_v = PCBData.new()
	data_v.from_board_dict(_board())
	data_v.save_to_history("baseline")
	var ws = PcbRoutingWorkspace.new()
	var cid := str(ws.ingest_record(_record_for_run(), int(data_v.board_revision)))
	var committed: Dictionary = ws.commit(cid, data_v)
	check("fixture: the candidate committed one trace", bool(committed.get("ok", false))
		and (committed.get("trace_ids", []) as Array).size() == 1, str(committed))
	var owned: String = str((committed.get("trace_ids", []) as Array)[0]) if (committed.get("trace_ids", []) as Array).size() == 1 else ""
	var host := _StubHost.new(data_v, _StubPanel.new(ws))
	var h0: int = data_v.history.size()
	var res: Dictionary = PanelTools._cut_trace(host, {"trace_id": owned, "at_index": 2})
	check("the cut succeeds and reports the retired commit",
		bool(res.get("success", false)) and (res.get("reopened_candidate_ids", []) as Array) == [cid], str(res))
	check("…the candidate is no longer committed and its task is open again",
		str(ws.get_candidate(cid).disposition) != "committed"
			and str(ws.task_state(str(ws.get_candidate(cid).task_id))) != "closed",
		"%s / %s" % [str(ws.get_candidate(cid).disposition), str(ws.task_state(str(ws.get_candidate(cid).task_id)))])
	check("…in ONE history step with the cut", data_v.history.size() - h0 == 1)

	# The same through the CANVAS menu path.
	var data_c = PCBData.new()
	data_c.from_board_dict(_board())
	data_c.save_to_history("baseline")
	var ws_c = PcbRoutingWorkspace.new()
	var cid_c := str(ws_c.ingest_record(_record_for_run(), int(data_c.board_revision)))
	var committed_c: Dictionary = ws_c.commit(cid_c, data_c)
	var owned_c: String = str((committed_c.get("trace_ids", []) as Array)[0]) if (committed_c.get("trace_ids", []) as Array).size() == 1 else ""
	var canvas = PcbCanvasScript.new()
	canvas.data = data_c
	canvas.zoom = 10.0
	canvas.set_routing_workspace(ws_c)
	canvas._cut_trace_here(owned_c, Vector2(20.3, 20.0))
	check("the canvas cut retires the commit too",
		_points(data_c, owned_c).size() == 3 and str(ws_c.get_candidate(cid_c).disposition) != "committed",
		"%d points, %s" % [_points(data_c, owned_c).size(), str(ws_c.get_candidate(cid_c).disposition)])
	canvas.free()
