extends SceneTree
## T1.5 — the ONE canonical layer-stack + via-span contract (GD side).
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_layer_stack.gd
## The preloads below resolve res:// against the scaffold's src/ root, so
## ../../minerva-plugins reaches this plugin checkout beside it.
##
## Off-tree: the plugin scripts live outside res://; loaded by relative-res path
## (same convention as test_pcb_apply_route_hints.gd) and duck-typed. Until
## move-chore 019f70a26607 stands up a plugin-local gd harness, the scaffold is
## the runner.
##
## Coverage:
##   1. PcbLayerStack canon<->kicad round-trip + via-span legality (pure).
##   2. FUNCTIONAL FLOOR (non-mocked): a REAL PCBData with a top trace, a bottom
##      trace, and a via spanning top<->bottom — serialise to the canonical board
##      dict (traces stay "top"/"bottom"; via carries from_layer/to_layer),
##      round-trip deserialise for equality, and drive panel_tools
##      _export_trace_geometry to prove it emits KiCad "F.Cu"/"B.Cu" at the edge.
##   3. VIA + UNDO (GATE INV-1 guard): undo across a via-bearing checkpoint keeps
##      the via WITH its traces (not orphaned); redo returns both.

const PcbLayerStack := preload("res://../../minerva-plugins/pcb/ui/model/pcb_layer_stack.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PANEL_TOOLS := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PcbAnnotationHost := preload("res://../../minerva-plugins/pcb/ui/PcbAnnotationHost.gd")

var _pass := 0
var _fail := 0


## Minimal duck-typed host so panel_tools._get_data(host) resolves to our board
## (it only needs get_board_data()).
class _StubHost extends RefCounted:
	var _data
	func _init(d) -> void:
		_data = d
	func get_board_data():
		return _data


## Minimal duck-typed canvas so PcbAnnotationHost.get_current_layer() can read a
## trace_layer_filter without a live canvas.
class _StubCanvas extends RefCounted:
	var trace_layer_filter := "top"


func _init() -> void:
	print("=== PcbLayerStack (T1.5 layer contract) Tests ===\n")
	_run_contract()
	_run_functional_floor()
	_run_via_undo()
	_run_host_current_layer()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── assertion helpers ─────────────────────────────────────────────────────────

func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


# ── 1. pure contract ──────────────────────────────────────────────────────────

func _run_contract() -> void:
	print("-- contract: canon<->kicad + via-span --")
	check_eq("canon_to_kicad top", PcbLayerStack.canon_to_kicad("top"), "F.Cu")
	check_eq("canon_to_kicad bottom", PcbLayerStack.canon_to_kicad("bottom"), "B.Cu")
	check_eq("canon_to_kicad empty -> F.Cu", PcbLayerStack.canon_to_kicad(""), "F.Cu")
	check_eq("kicad_to_canon F.Cu", PcbLayerStack.kicad_to_canon("F.Cu"), "top")
	check_eq("kicad_to_canon B.Cu", PcbLayerStack.kicad_to_canon("B.Cu"), "bottom")
	check_eq("kicad_to_canon empty -> top", PcbLayerStack.kicad_to_canon(""), "top")
	# round-trip
	check_eq("round-trip top", PcbLayerStack.kicad_to_canon(PcbLayerStack.canon_to_kicad("top")), "top")
	check_eq("round-trip B.Cu", PcbLayerStack.canon_to_kicad(PcbLayerStack.kicad_to_canon("B.Cu")), "B.Cu")
	# via-span legality
	check("through-via top<->bottom legal", PcbLayerStack.is_legal_via_span("top", "bottom"))
	check("reversed span legal", PcbLayerStack.is_legal_via_span("bottom", "top"))
	check("same-layer span illegal", not PcbLayerStack.is_legal_via_span("top", "top"))
	check("unknown-layer span illegal", not PcbLayerStack.is_legal_via_span("top", "inner1"))
	check("KiCad-named span normalises + legal", PcbLayerStack.is_legal_via_span("F.Cu", "B.Cu"))
	check("is_copper top", PcbLayerStack.is_copper("top"))
	check("is_copper B.Cu", PcbLayerStack.is_copper("B.Cu"))
	check("is_copper inner illegal", not PcbLayerStack.is_copper("inner1"))
	# default stack
	var stack: Array = PcbLayerStack.default_two_layer()
	check_eq("default stack has 2 entries", stack.size(), 2)
	if stack.size() == 2:
		check_eq("entry0 layer_id top", (stack[0] as Dictionary).get("layer_id", ""), "top")
		check_eq("entry0 kicad_alias F.Cu", (stack[0] as Dictionary).get("kicad_alias", ""), "F.Cu")
		check_eq("entry1 layer_id bottom", (stack[1] as Dictionary).get("layer_id", ""), "bottom")
		check_eq("entry1 index 1", int((stack[1] as Dictionary).get("index", -1)), 1)


# ── 2. functional floor (real PCBData) ────────────────────────────────────────

func _seed_board() -> Object:
	var data = PCBData.new()
	var t_top = data.new_trace()
	t_top.id = "t_top"
	t_top.net_name = "N1"
	t_top.layer = "top"
	t_top.width = 0.3
	t_top.waypoints.append(Vector2(0, 0))
	t_top.waypoints.append(Vector2(5, 0))
	data.add_trace(t_top)

	var t_bot = data.new_trace()
	t_bot.id = "t_bot"
	t_bot.net_name = "N1"
	t_bot.layer = "bottom"
	t_bot.width = 0.3
	t_bot.waypoints.append(Vector2(10, 0))
	t_bot.waypoints.append(Vector2(15, 0))
	data.add_trace(t_bot)

	data.add_via({
		"position": Vector2(5, 0),
		"size": 0.8,
		"drill": 0.4,
		"net_name": "N1",
		"from_layer": "top",
		"to_layer": "bottom",
	})
	return data


func _via_from_board(board: Dictionary) -> Dictionary:
	var vias: Array = board.get("vias", [])
	if vias.size() >= 1 and vias[0] is Dictionary:
		return vias[0]
	return {}


func _layer_for(board: Dictionary, trace_id: String) -> String:
	for t in board.get("traces", []):
		if t is Dictionary and str(t.get("id", "")) == trace_id:
			return str(t.get("layer", ""))
	return "<missing>"


func _run_functional_floor() -> void:
	print("-- functional floor: real PCBData serialise/round-trip/export --")
	var data = _seed_board()
	check_eq("board has 2 traces", data.get_trace_count(), 2)
	check_eq("board has 1 via", data.vias.size(), 1)

	# Serialise to the canonical board dict — traces stay canonical, via carries span.
	var board: Dictionary = data.to_board_dict()
	check_eq("serialised t_top layer stays canonical 'top'", _layer_for(board, "t_top"), "top")
	check_eq("serialised t_bot layer stays canonical 'bottom'", _layer_for(board, "t_bot"), "bottom")
	var via: Dictionary = _via_from_board(board)
	check_eq("serialised via from_layer top", str(via.get("from_layer", "")), "top")
	check_eq("serialised via to_layer bottom", str(via.get("to_layer", "")), "bottom")

	# Round-trip deserialise -> re-serialise, assert layer fields survive equal.
	var data2 = PCBData.new()
	data2.from_board_dict(board)
	var board2: Dictionary = data2.to_board_dict()
	check_eq("round-trip t_top layer", _layer_for(board2, "t_top"), "top")
	check_eq("round-trip t_bot layer", _layer_for(board2, "t_bot"), "bottom")
	var via2: Dictionary = _via_from_board(board2)
	check_eq("round-trip via from_layer", str(via2.get("from_layer", "")), "top")
	check_eq("round-trip via to_layer", str(via2.get("to_layer", "")), "bottom")
	check("round-trip via block equal", via == via2)

	# Edge: panel_tools export emits KiCad "F.Cu"/"B.Cu".
	var host = _StubHost.new(data)
	var res: Dictionary = PANEL_TOOLS._export_trace_geometry(host, {})
	check("export ok", bool(res.get("success", false)))
	var td: Dictionary = res.get("trace_data", {})
	var out_traces: Array = td.get("traces", [])
	var kicad_layers := {}
	for seg in out_traces:
		if seg is Dictionary:
			kicad_layers[str(seg.get("layer", ""))] = true
	check("export emits F.Cu at the edge", kicad_layers.has("F.Cu"))
	check("export emits B.Cu at the edge", kicad_layers.has("B.Cu"))
	check("export emits NO canonical 'top' at the edge", not kicad_layers.has("top"))


# ── 3. via + undo (GATE INV-1 guard) ──────────────────────────────────────────

func _via_count_for_net(data, net: String) -> int:
	var n := 0
	for v in data.vias:
		if str(v.get("net_name", "")) == net:
			n += 1
	return n


func _run_via_undo() -> void:
	print("-- via + undo/redo (GATE INV-1) --")
	var data = PCBData.new()
	data.save_to_history("baseline (empty)")          # checkpoint 0
	check_eq("baseline 0 traces", data.get_trace_count(), 0)
	check_eq("baseline 0 vias", data.vias.size(), 0)

	# Add the via-bearing state and checkpoint it.
	var t_top = data.new_trace()
	t_top.id = "u_top"; t_top.net_name = "N1"; t_top.layer = "top"; t_top.width = 0.3
	t_top.waypoints.append(Vector2(0, 0)); t_top.waypoints.append(Vector2(5, 0))
	data.add_trace(t_top)
	var t_bot = data.new_trace()
	t_bot.id = "u_bot"; t_bot.net_name = "N1"; t_bot.layer = "bottom"; t_bot.width = 0.3
	t_bot.waypoints.append(Vector2(5, 0)); t_bot.waypoints.append(Vector2(5, 5))
	data.add_trace(t_bot)
	data.add_via({
		"position": Vector2(5, 0), "size": 0.8, "drill": 0.4,
		"net_name": "N1", "from_layer": "top", "to_layer": "bottom",
	})
	data.save_to_history("add traces + via")          # checkpoint 1 (via-bearing)
	check_eq("checkpoint1 2 traces", data.get_trace_count(), 2)
	check_eq("checkpoint1 1 via", _via_count_for_net(data, "N1"), 1)

	# A later mutation + checkpoint, so undo lands ON the via-bearing state.
	var t_extra = data.new_trace()
	t_extra.id = "u_extra"; t_extra.net_name = "N2"; t_extra.layer = "top"; t_extra.width = 0.3
	t_extra.waypoints.append(Vector2(20, 0)); t_extra.waypoints.append(Vector2(25, 0))
	data.add_trace(t_extra)
	data.save_to_history("add extra trace")           # checkpoint 2
	check_eq("checkpoint2 3 traces", data.get_trace_count(), 3)

	# UNDO to the via-bearing checkpoint: the via must come back WITH the traces
	# (F1 / GATE INV-1: the undo codec carries vias, so they are not orphaned).
	check("can undo", data.can_undo())
	data.undo()
	check_eq("undo -> 2 traces restored", data.get_trace_count(), 2)
	check_eq("undo -> via restored WITH traces (not orphaned)", _via_count_for_net(data, "N1"), 1)

	# Undo again to empty baseline.
	data.undo()
	check_eq("undo -> baseline 0 traces", data.get_trace_count(), 0)
	check_eq("undo -> baseline 0 vias", data.vias.size(), 0)

	# REDO returns both traces AND the via.
	data.redo()
	check_eq("redo -> 2 traces", data.get_trace_count(), 2)
	check_eq("redo -> via returns", _via_count_for_net(data, "N1"), 1)
	data.redo()
	check_eq("redo -> 3 traces", data.get_trace_count(), 3)


# ── 4. PcbAnnotationHost.get_current_layer resolves through the contract ──────
#
# Guards the FOURTH (now-removed) top->F.Cu / bottom->B.Cu dup: the active-layer
# lookup must come from PcbLayerStack, and a non-copper filter keeps the F.Cu
# default (no single active layer).

func _run_host_current_layer() -> void:
	print("-- PcbAnnotationHost.get_current_layer via contract --")
	var host = PcbAnnotationHost.new()
	var canvas = _StubCanvas.new()
	host._canvas = canvas   # inject a stub canvas (bypasses set_canvas signal wiring)

	canvas.trace_layer_filter = "top"
	check_eq("get_current_layer(top) == contract canon_to_kicad", host.get_current_layer(), PcbLayerStack.canon_to_kicad("top"))
	canvas.trace_layer_filter = "bottom"
	check_eq("get_current_layer(bottom) == contract canon_to_kicad", host.get_current_layer(), PcbLayerStack.canon_to_kicad("bottom"))
	# A non-copper filter ("all"/unknown) keeps the F.Cu default — NOT a
	# passthrough of the filter string.
	canvas.trace_layer_filter = "all"
	check_eq("get_current_layer(non-copper filter) -> F.Cu default", host.get_current_layer(), "F.Cu")
