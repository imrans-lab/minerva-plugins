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
##   1. PcbLayerStack canon<->kicad round-trip + via-span legality (pure),
##      including the epoch GA-1 additions: default_stack/stack_for_count,
##      stack_shape_error (the GD mirror of validateLayers/_check_layers),
##      inner_index_any (the silent draw-loop-safe inner lookup).
##   2. FUNCTIONAL FLOOR (non-mocked): a REAL PCBData with a top trace, a bottom
##      trace, and a via spanning top<->bottom — serialise to the canonical board
##      dict (traces stay "top"/"bottom"; via carries from_layer/to_layer),
##      round-trip deserialise for equality, and drive panel_tools
##      _export_trace_geometry to prove it emits KiCad "F.Cu"/"B.Cu" at the edge.
##   3. VIA + UNDO (GATE INV-1 guard): undo across a via-bearing checkpoint keeps
##      the via WITH its traces (not orphaned); redo returns both.
##   5. SET_BOARD_LAYERS (epoch GA-1): the stack as a mutable, undoable board
##      property — shape refusals verbatim from the one GD rule, occupancy
##      refusal while copper sits on a removed layer, the layers history
##      bucket across undo/redo, and the panel_tools MCP handler (count and
##      layers spellings, reply shape, refusal passthrough).

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
## working_layer without a live canvas.
class _StubCanvas extends RefCounted:
	var working_layer := "top"


func _init() -> void:
	print("=== PcbLayerStack (T1.5 layer contract) Tests ===\n")
	_run_contract()
	_run_functional_floor()
	_run_via_undo()
	_run_host_current_layer()
	_run_set_board_layers()
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
	# FAILS CLOSED (epoch 6): an empty/unrecognised canonical layer id must NOT
	# silently default to "F.Cu" — canon_to_kicad push_error()s (see
	# pcb_layer_stack.gd's "FAILS CLOSED" doc comment on canon_to_kicad, which
	# names the exact message shape: 'PcbLayerStack.canon_to_kicad: unknown
	# copper layer "<id>" — expected "top", "bottom", "in1"..."in<N>", or a
	# KiCad copper name ("F.Cu"/"B.Cu"/"In<k>.Cu")') and returns "" instead of a
	# defaulted alias. The empty-string return IS the refusal signal at this
	# pure-function boundary — there is no structured error dict here (unlike
	# the dispatcher-boundary error shapes in other suites); GDScript has no
	# hook to assert on a push_error's message text from a test script, so the
	# message content is pinned by the production doc comment instead.
	check_eq("canon_to_kicad empty -> refuses (returns \"\", not a defaulted F.Cu)", PcbLayerStack.canon_to_kicad(""), "")
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
	# Default stack + count derivation (epoch GA-1: default_two_layer()'s rich
	# entries were dead API with divergent colors; the plain-id default_stack
	# replaced them).
	check_eq("default_stack is [top, bottom]", PcbLayerStack.default_stack(), ["top", "bottom"])
	check_eq("stack_for_count(2)", PcbLayerStack.stack_for_count(2), ["top", "bottom"])
	check_eq("stack_for_count(4)", PcbLayerStack.stack_for_count(4), ["top", "in1", "in2", "bottom"])
	check_eq("stack_for_count(6)", PcbLayerStack.stack_for_count(6),
		["top", "in1", "in2", "in3", "in4", "bottom"])
	# Every count-derived stack is exactly the shape the shape rule admits —
	# the one-derivation property that keeps the two spellings from diverging.
	for n in [2, 3, 4, 8, 32]:
		check_eq("stack_for_count(%d) passes stack_shape_error" % n,
			PcbLayerStack.stack_shape_error(PcbLayerStack.stack_for_count(n)), "")

	# Inner-layer naming (GA-1: the function-level mapping is load-bearing now).
	check_eq("canon_to_kicad in1", PcbLayerStack.canon_to_kicad("in1"), "In1.Cu")
	check_eq("canon_to_kicad in30", PcbLayerStack.canon_to_kicad("in30"), "In30.Cu")
	check_eq("kicad_to_canon In7.Cu", PcbLayerStack.kicad_to_canon("In7.Cu"), "in7")
	check("via span touching a canonical inner layer is illegal",
		not PcbLayerStack.is_legal_via_span("top", "in1"))
	check("inner<->inner span illegal", not PcbLayerStack.is_legal_via_span("in1", "in2"))

	# inner_index_any: the SILENT spelling-agnostic lookup (draw-loop safe).
	check_eq("inner_index_any in3", PcbLayerStack.inner_index_any("in3"), 3)
	check_eq("inner_index_any In12.Cu", PcbLayerStack.inner_index_any("In12.Cu"), 12)
	check_eq("inner_index_any top -> 0", PcbLayerStack.inner_index_any("top"), 0)
	check_eq("inner_index_any F.SilkS -> 0", PcbLayerStack.inner_index_any("F.SilkS"), 0)
	check_eq("inner_index_any in0 -> 0", PcbLayerStack.inner_index_any("in0"), 0)
	check_eq("inner_index_any in31 -> 0", PcbLayerStack.inner_index_any("in31"), 0)

	# stack_shape_error refusal matrix (the GD mirror of Go validateLayers /
	# Python _check_layers — same rules, refusal-string spelling).
	check_eq("shape: valid 2-layer", PcbLayerStack.stack_shape_error(["top", "bottom"]), "")
	check_eq("shape: valid 4-layer",
		PcbLayerStack.stack_shape_error(["top", "in1", "in2", "bottom"]), "")
	check("shape: too short refused",
		not PcbLayerStack.stack_shape_error(["top"]).is_empty())
	check("shape: non-canonical name refused",
		not PcbLayerStack.stack_shape_error(["top", "inner1", "bottom"]).is_empty())
	check("shape: duplicate refused",
		not PcbLayerStack.stack_shape_error(["top", "top", "bottom"]).is_empty())
	check("shape: missing bottom refused",
		not PcbLayerStack.stack_shape_error(["top", "in1", "in2"]).is_empty())
	check("shape: wrong order refused",
		not PcbLayerStack.stack_shape_error(["bottom", "top"]).is_empty())
	check("shape: inner gap refused",
		not PcbLayerStack.stack_shape_error(["top", "in2", "bottom"]).is_empty())
	check("shape: inners out of order refused",
		not PcbLayerStack.stack_shape_error(["top", "in2", "in1", "bottom"]).is_empty())


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
# lookup must come from PcbLayerStack, reading the canvas's WORKING layer (where
# copper is authored) and not its view filter. A non-copper value keeps the F.Cu
# default.

func _run_host_current_layer() -> void:
	print("-- PcbAnnotationHost.get_current_layer via contract --")
	var host = PcbAnnotationHost.new()
	var canvas = _StubCanvas.new()
	host._canvas = canvas   # inject a stub canvas (bypasses set_canvas signal wiring)

	canvas.working_layer = "top"
	check_eq("get_current_layer(top) == contract canon_to_kicad", host.get_current_layer(), PcbLayerStack.canon_to_kicad("top"))
	canvas.working_layer = "bottom"
	check_eq("get_current_layer(bottom) == contract canon_to_kicad", host.get_current_layer(), PcbLayerStack.canon_to_kicad("bottom"))
	# A non-copper value keeps the F.Cu default — NOT a passthrough of the
	# string. The live canvas refuses one, but this hook is duck-typed.
	canvas.working_layer = "all"
	check_eq("get_current_layer(non-copper working layer) -> F.Cu default", host.get_current_layer(), "F.Cu")


# ── 5. set_board_layers (epoch GA-1): the stack as a mutable board property ──

func _run_set_board_layers() -> void:
	print("-- set_board_layers: shape gate, occupancy gate, undo bucket, MCP handler --")
	var data = PCBData.new()
	check_eq("fresh board default stack", data.layers, ["top", "bottom"] as Array[String])

	# SHAPE refusals come back verbatim from the one GD rule.
	check("shape refusal: non-canonical",
		not data.set_board_layers(["top", "inner1", "bottom"]).is_empty())
	check("shape refusal: wrong order",
		not data.set_board_layers(["bottom", "top"]).is_empty())
	check_eq("refused edits leave the stack untouched", data.layers,
		["top", "bottom"] as Array[String])

	# Widen 2 -> 4: succeeds, spellings normalised, undoable.
	data.save_to_history("baseline")
	check_eq("widen to 4 succeeds", data.set_board_layers(["top", "in1", "in2", "bottom"]), "")
	data.save_to_history("widen")
	check_eq("stack is 4 deep", data.layers,
		["top", "in1", "in2", "bottom"] as Array[String])
	# KiCad/mixed-case spellings normalise to canonical on the way in.
	check_eq("re-declare with mixed case is a no-op",
		data.set_board_layers(["Top", "IN1", "in2", "BOTTOM"]), "")
	check_eq("mixed-case no-op left canonical ids", data.layers,
		["top", "in1", "in2", "bottom"] as Array[String])

	# OCCUPANCY gate: copper on in1 blocks shrinking back to 2 and names the
	# stranded trace; vias never block (a through-via spans top<->bottom,
	# which every legal stack contains).
	var t_inner = data.new_trace()
	t_inner.id = "t_inner"; t_inner.net_name = "N1"; t_inner.layer = "in1"; t_inner.width = 0.3
	t_inner.waypoints.append(Vector2(0, 0)); t_inner.waypoints.append(Vector2(5, 0))
	data.add_trace(t_inner)
	data.add_via({"position": Vector2(5, 0), "size": 0.8, "drill": 0.4,
		"net_name": "N1", "from_layer": "top", "to_layer": "bottom"})
	var refusal: String = data.set_board_layers(["top", "bottom"])
	check("shrink over occupied in1 refused", not refusal.is_empty())
	check("refusal names the stranded trace", refusal.contains("t_inner"))
	check_eq("refused shrink left the 4-layer stack", data.layers.size(), 4)
	# Clearing the copper unblocks the shrink; the through-via alone never blocks.
	data.remove_trace("t_inner")
	check_eq("shrink after clearing copper succeeds",
		data.set_board_layers(["top", "bottom"]), "")
	check_eq("via survived the shrink", data.vias.size(), 1)
	data.save_to_history("shrink")

	# UNDO/REDO: the layers bucket restores the stack with the board.
	data.undo()
	check_eq("undo returns the 4-layer stack", data.layers,
		["top", "in1", "in2", "bottom"] as Array[String])
	data.undo()
	check_eq("second undo returns the 2-layer baseline", data.layers,
		["top", "bottom"] as Array[String])
	data.redo()
	check_eq("redo returns the 4-layer stack again", data.layers,
		["top", "in1", "in2", "bottom"] as Array[String])

	# MCP handler: both argument spellings, reply shape, refusal passthrough.
	var data2 = PCBData.new()
	var host = _StubHost.new(data2)
	var res: Dictionary = PANEL_TOOLS._set_board_layers(host, {"count": 4})
	check("handler count=4 ok", bool(res.get("success", false)))
	check_eq("handler reply carries the stack", res.get("layers", []),
		["top", "in1", "in2", "bottom"])
	check_eq("handler changed=true on a real edit", bool(res.get("changed", true)), true)
	res = PANEL_TOOLS._set_board_layers(host, {"layers": ["top", "in1", "in2", "bottom"]})
	check("handler explicit same stack ok", bool(res.get("success", false)))
	check_eq("handler changed=false on a no-op", bool(res.get("changed", true)), false)
	res = PANEL_TOOLS._set_board_layers(host, {"layers": ["top", "in9", "bottom"]})
	check("handler malformed stack refused", not bool(res.get("success", true)))
	res = PANEL_TOOLS._set_board_layers(host, {})
	check("handler with neither arg refused", not bool(res.get("success", true)))
	res = PANEL_TOOLS._set_board_layers(host, {"count": 4.5})
	check("handler fractional count refused", not bool(res.get("success", true)))
	# GDScript JSON numbers arrive as floats — a whole-number float count works.
	res = PANEL_TOOLS._set_board_layers(host, {"count": 2.0})
	check("handler whole-float count accepted", bool(res.get("success", false)))
	check_eq("whole-float count built the 2-layer stack", res.get("layers", []),
		["top", "bottom"])
	# Epoch GA repair round (Codex whole-epoch review finding 5): strict
	# argument grammar — no silent widening of invalid input.
	res = PANEL_TOOLS._set_board_layers(host, {"count": 1.0})
	check("handler count below 2 refused, never clamped up",
		not bool(res.get("success", true)))
	res = PANEL_TOOLS._set_board_layers(host, {"count": 33.0})
	check("handler count above 32 refused",
		not bool(res.get("success", true)))
	res = PANEL_TOOLS._set_board_layers(
		host, {"layers": ["top", "bottom"], "count": 4.0})
	check("handler layers+count together refused (mutually exclusive)",
		not bool(res.get("success", true)))
