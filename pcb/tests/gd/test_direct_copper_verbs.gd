extends SceneTree
## EPOCH NLC stations C2 + C3 — minerva_pcb_place_via (item 019fff60e05a) and
## minerva_pcb_add_trace (item 01a001c39aa3).
##
## Run (via a Minerva checkout as the Godot host):
##   pcb/scripts/run-gd-tests.sh <path-to-minerva-checkout>
##
## THE PARITY GAP. Copper CREATION was proposal-only while copper DESTRUCTION
## was direct: minerva_pcb_delete_via and minerva_pcb_delete_traces act on the
## board, but the only add-via verb edited a route HINT. An agent could delete a
## via it could not put back, and the owner's N-layer HITL named it — "there is
## no tool to place a via for the human, only propose ... that breaks a goal of
## parity between tools and proposals".
##
## The suite is named for the THEME, not the verb, because C3's direct trace
## verb belongs beside this one: they are the same gap answered twice, and
## splitting them would hide that the pair has to stay symmetric.
##
## REUSE SCAN: panel boot + check helpers follow test_view_state.gd, which
## follows test_parity_bridge.gd. Assertions read back through the MODEL
## (data.vias, data.get_via) rather than trusting the verb's reply — the reply
## is the thing under test.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Direct copper verbs (NLC C2 + C3) ===\n")
	_run_place_via_lands_on_the_board()
	_run_span_is_not_selectable()
	_run_refusals_change_nothing()
	_run_round_trips_with_delete()
	_run_add_trace_lands_copper()
	_run_add_trace_refusals()
	_run_human_via_tool()
	_run_one_rule_for_both_surfaces()
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
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


func _ctx() -> Dictionary:
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var data = panel.get_data()
	# A four-layer board, so "the span is always through" is a claim with
	# something to be wrong about — on a 2-layer board top<->bottom is the only
	# span there is and the assertion would be vacuous.
	if data != null and data.has_method("set_board_layers"):
		data.set_board_layers(["top", "in1", "in2", "bottom"])
	return {"driver": driver, "panel": panel, "host": host, "data": data}


# ── 1. it lands on the BOARD, not on a proposal ───────────────────────────────

func _run_place_via_lands_on_the_board() -> void:
	print("-- 1. place_via writes a real board via --")
	var ctx := _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var before: int = data.vias.size()
	var res: Dictionary = PanelTools._place_via(host, {"x_mm": 10.0, "y_mm": 12.5, "net_name": "GND"})
	check("place_via succeeds", bool(res.get("success", false)))

	# Read back through the MODEL. The reply saying it worked is not evidence
	# that copper exists.
	check_eq("the board gained exactly one via", data.vias.size(), before + 1)
	var via_id := str(res.get("via_id", ""))
	check("the reply names a via id", not via_id.is_empty())
	var stored: Dictionary = data.get_via(via_id)
	check("that id resolves to a stored via", not stored.is_empty())
	check_eq("stored at the point asked for", data.via_position(stored), Vector2(10.0, 12.5))
	check_eq("carrying the net it was given", str(stored.get("net_name", "")), "GND")

	# THROUGH SPAN, unconditionally — on a 4-layer board.
	check_eq("stored span is top", str(stored.get("from_layer", "")), "top")
	check_eq("stored span is bottom", str(stored.get("to_layer", "")), "bottom")

	# Defaults, and the ring between them.
	check_eq("default size", float(stored.get("size", 0.0)), 0.8)
	check_eq("default drill", float(stored.get("drill", 0.0)), 0.4)

	ctx["driver"].free_panel(ctx["panel"])


# ── 2. a span argument is REFUSED, not ignored ────────────────────────────────

func _run_span_is_not_selectable() -> void:
	print("-- 2. from_layer/to_layer/layers are refused, never silently dropped --")
	var ctx := _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	# Silently ignoring an argument someone bothered to write is how a caller
	# comes to believe in a blind/buried via this pipeline cannot fabricate.
	for banned in ["from_layer", "to_layer", "layers"]:
		var args := {"x_mm": 5.0, "y_mm": 5.0}
		args[banned] = "in1"
		var res: Dictionary = PanelTools._place_via(host, args)
		check("'%s' is refused" % banned, not bool(res.get("success", true)))
		check_eq("named span_not_selectable for '%s'" % banned,
			str(res.get("error", "")), "span_not_selectable")

	check_eq("no via was created by any of them", data.vias.size(), 0)

	ctx["driver"].free_panel(ctx["panel"])


# ── 3. every refusal is named, and writes nothing ─────────────────────────────

func _run_refusals_change_nothing() -> void:
	print("-- 3. off-board, stacked, and degenerate geometry all refuse --")
	var ctx := _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var missing: Dictionary = PanelTools._place_via(host, {"y_mm": 1.0})
	check("a missing coordinate refuses", not bool(missing.get("success", true)))

	# Off the board outline. The agent cannot see the board to notice it asked
	# for copper that cannot be manufactured.
	var off: Dictionary = PanelTools._place_via(host,
		{"x_mm": float(data.board_width) + 50.0, "y_mm": 1.0})
	check("a point off the board refuses", not bool(off.get("success", true)))
	check_eq("named via_not_placeable", str(off.get("error", "")), "via_not_placeable")
	# ONE code, the MODEL's own words. via_author_error is the single rule the
	# canvas Via tool reads too, so a click and a tool call are refused
	# identically — the distinguishing detail lives in the message, not in a
	# code the two surfaces would have to keep in step by hand.
	check("and says it is off the board",
		str(off.get("note", "")).contains("outside this"))

	# The annular ring IS size minus drill, so a drill at least as wide as the
	# pad is a hole through nothing.
	var ring: Dictionary = PanelTools._place_via(host,
		{"x_mm": 5.0, "y_mm": 5.0, "size_mm": 0.4, "drill_mm": 0.4})
	check("drill >= size refuses", not bool(ring.get("success", true)))

	var neg: Dictionary = PanelTools._place_via(host,
		{"x_mm": 5.0, "y_mm": 5.0, "drill_mm": -1.0})
	check("a non-positive drill refuses", not bool(neg.get("success", true)))

	check_eq("not one refusal wrote copper", data.vias.size(), 0)

	# Stacking: place one, then ask for the same point again.
	check("the first via at (5,5) is placed",
		bool(PanelTools._place_via(host, {"x_mm": 5.0, "y_mm": 5.0}).get("success", false)))
	var stacked: Dictionary = PanelTools._place_via(host, {"x_mm": 5.0, "y_mm": 5.0})
	check("a second via at the same point refuses", not bool(stacked.get("success", true)))
	check_eq("named via_not_placeable", str(stacked.get("error", "")), "via_not_placeable")
	check("and says a via is already there",
		str(stacked.get("note", "")).contains("already sits"))
	check_eq("still exactly one via", data.vias.size(), 1)

	ctx["driver"].free_panel(ctx["panel"])


# ── 4. create and destroy are now symmetric ───────────────────────────────────

func _run_round_trips_with_delete() -> void:
	print("-- 4. place -> delete -> place: the parity claim, end to end --")
	var ctx := _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var placed: Dictionary = PanelTools._place_via(host, {"x_mm": 20.0, "y_mm": 20.0, "net_name": "N1"})
	var via_id := str(placed.get("via_id", ""))
	check_eq("one via on the board", data.vias.size(), 1)

	# THE WHOLE POINT OF THE STATION: the agent can put back what it removed.
	var deleted: Dictionary = PanelTools._delete_via(host, {"via_id": via_id})
	check("delete_via accepts the id place_via minted", bool(deleted.get("success", false)))
	check_eq("board is empty again", data.vias.size(), 0)

	var again: Dictionary = PanelTools._place_via(host, {"x_mm": 20.0, "y_mm": 20.0, "net_name": "N1"})
	check("the same via can be placed again", bool(again.get("success", false)))
	check_eq("board has one via once more", data.vias.size(), 1)
	# A re-place must not collide with the freed id — the model's id high-water
	# mark is what prevents it, and this is the caller that would notice.
	# ASSERTS INEQUALITY, not merely non-emptiness (cold review, finding 9): a
	# colliding id is also non-empty, so the weaker form could not fail.
	check_eq("the re-placed via gets a FRESH id, not the freed one",
		str(again.get("via_id", "")) != via_id, true)

	ctx["driver"].free_panel(ctx["panel"])


# ── 5. C3: a trace drawn directly, through the HUMAN TOOL'S OWN model path ────
#
# minerva_pcb_delete_traces removed copper directly; nothing drew it. The human
# has had a canvas Trace tool the whole time. RULED HERE, and asserted below:
# the direct verb LANDS COPPER AND RUNS NO DRC, because _commit_trace does not
# gate either — a verb that refused what the Trace tool accepts would make the
# agent a second-class author of the same board.

const PcbNet := preload("res://../../minerva-plugins/pcb/ui/model/pcb_net.gd")


func _trace_ctx() -> Dictionary:
	var ctx := _ctx()
	var net = PcbNet.new()
	net.name = "N1"
	ctx["data"].add_net(net)
	return ctx


func _run_add_trace_lands_copper() -> void:
	print("-- 5. add_trace writes a real board trace on an INNER layer --")
	var ctx := _trace_ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var before: int = data.traces.size()
	var res: Dictionary = PanelTools._add_trace(host, {
		"net_name": "N1", "layer": "in1",
		"points": [[1.0, 1.0], [5.0, 1.0], [5.0, 8.0]],
	})
	check("add_trace succeeds on an inner layer", bool(res.get("success", false)))
	check_eq("the board gained one trace", data.traces.size(), before + 1)

	var tid := str(res.get("trace_id", ""))
	check("the reply names a trace id", not tid.is_empty())
	check("that id is a key on the board", data.traces.has(tid))
	var stored = data.traces.get(tid)
	check_eq("stored on the layer asked for", str(stored.layer), "in1")
	check_eq("stored on the net asked for", str(stored.net_name), "N1")
	check_eq("all three points survived", stored.waypoints.size(), 3)
	check_eq("reported segment count is points - 1", int(res.get("segment_count", -1)), 2)

	# A KiCad spelling must reach the same layer — the vocabularies are
	# interchangeable everywhere else on this surface.
	var res2: Dictionary = PanelTools._add_trace(host, {
		"net_name": "N1", "layer": "In2.Cu", "points": [[2.0, 2.0], [6.0, 2.0]],
	})
	check("a KiCad layer spelling is accepted", bool(res2.get("success", false)))
	check_eq("and is stored canonically", str(res2.get("layer", "")), "in2")

	# THE RULING, stated as an assertion: no DRC gate, and the reply says so
	# rather than leaving the agent to assume the board is clean.
	check("the reply warns that no DRC ran",
		str(res.get("note", "")).to_lower().contains("drc"))

	ctx["driver"].free_panel(ctx["panel"])


# ── 6. C3 refusals: named, and nothing written ────────────────────────────────

func _run_add_trace_refusals() -> void:
	print("-- 6. undeclared layer, unauthorable trace, malformed points --")
	var ctx := _trace_ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var off_stack: Dictionary = PanelTools._add_trace(host, {
		"net_name": "N1", "layer": "in7", "points": [[1.0, 1.0], [2.0, 2.0]]})
	check("a layer this board does not declare refuses",
		not bool(off_stack.get("success", true)))
	check_eq("named layer_not_on_stack", str(off_stack.get("error", "")), "layer_not_on_stack")
	check("and lists the layers it DOES declare",
		(off_stack.get("declared_layers", []) as Array).size() == 4)

	# The model's own rule, in the model's own words — not a re-implementation
	# that could drift from what a human's click is told.
	var one_point: Dictionary = PanelTools._add_trace(host, {
		"net_name": "N1", "layer": "top", "points": [[1.0, 1.0]]})
	check("a one-point trace refuses", not bool(one_point.get("success", true)))
	check_eq("named trace_not_authorable", str(one_point.get("error", "")), "trace_not_authorable")
	check("carrying the model's own wording",
		str(one_point.get("note", "")).contains("at least 2 points"))

	var no_net: Dictionary = PanelTools._add_trace(host, {
		"net_name": "NOPE", "layer": "top", "points": [[1.0, 1.0], [2.0, 2.0]]})
	check("an undeclared net refuses", not bool(no_net.get("success", true)))
	check_eq("also trace_not_authorable", str(no_net.get("error", "")), "trace_not_authorable")

	var bad_pts: Dictionary = PanelTools._add_trace(host, {
		"net_name": "N1", "layer": "top", "points": [[1.0, 1.0], "nope"]})
	check("a malformed point refuses", not bool(bad_pts.get("success", true)))

	var no_layer: Dictionary = PanelTools._add_trace(host, {
		"net_name": "N1", "points": [[1.0, 1.0], [2.0, 2.0]]})
	check("a missing layer refuses", not bool(no_layer.get("success", true)))

	check_eq("not one refusal wrote copper", data.traces.size(), 0)

	ctx["driver"].free_panel(ctx["panel"])


# ── 7. THE HUMAN'S VIA TOOL — the half the owner actually asked for ───────────
#
# "There is no tool to place a via for the human, only propose." That was first
# answered with minerva_pcb_place_via, an MCP verb — the AGENT's half. The owner
# drives this panel with buttons and cannot call MCP, so the reported gap stayed
# open. These assertions are about the CANVAS.

const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")


func _run_human_via_tool() -> void:
	print("-- 7. ToolMode.VIA: a button, a click, a via --")
	var ctx := _ctx()
	var panel = ctx["panel"]
	var data = ctx["data"]
	# get_canvas lives on the annotation HOST, not the panel (PcbAnnotationHost
	# :1079) — checked rather than assumed.
	var canvas = ctx["host"].get_canvas()
	check("the host exposes the canvas", canvas != null)
	if canvas == null:
		ctx["driver"].free_panel(ctx["panel"])
		return

	# THE AFFORDANCE EXISTS. Without a registered tool button there is nothing
	# for a person to press, and every assertion below would be testing a
	# capability only an agent can reach — the exact substitution this group
	# exists to prevent.
	check("a Via tool button is registered in the toolbar",
		(panel._tool_buttons as Dictionary).has(PcbCanvasScript.ToolMode.VIA))

	canvas.set_tool_mode(PcbCanvasScript.ToolMode.VIA)
	check_eq("the canvas arms the Via tool", int(canvas.tool_mode),
		int(PcbCanvasScript.ToolMode.VIA))

	var before: int = data.vias.size()
	canvas._handle_via_click(Vector2(12.0, 9.0))
	check_eq("a click places exactly one via", data.vias.size(), before + 1)

	var placed: Dictionary = data.vias[data.vias.size() - 1]
	check_eq("at the clicked point", data.via_position(placed), Vector2(12.0, 9.0))
	# A v1 via is a through via — no span control on this tool, and none needed.
	check_eq("recorded as a through via (top)", str(placed.get("from_layer", "")), "top")
	check_eq("recorded as a through via (bottom)", str(placed.get("to_layer", "")), "bottom")

	# SAME RULE AS THE AGENT'S VERB. Clicking the same point again must refuse
	# for the same reason minerva_pcb_place_via refuses it — one model rule,
	# read by both surfaces, so the two can never drift.
	canvas._handle_via_click(Vector2(12.0, 9.0))
	check_eq("clicking an occupied point places nothing", data.vias.size(), before + 1)

	# And off the board.
	canvas._handle_via_click(Vector2(float(data.board_width) + 25.0, 5.0))
	check_eq("clicking off the board places nothing", data.vias.size(), before + 1)

	ctx["driver"].free_panel(ctx["panel"])


# ── 8. the model rule itself, read by BOTH surfaces ───────────────────────────

func _run_one_rule_for_both_surfaces() -> void:
	print("-- 8. via_author_error is the single rule --")
	var ctx := _ctx()
	var data = ctx["data"]

	check_eq("a clean point is placeable",
		str(data.via_author_error(Vector2(5.0, 5.0), 0.8, 0.4)), "")
	check("a drill wider than the pad is refused",
		not str(data.via_author_error(Vector2(5.0, 5.0), 0.4, 0.8)).is_empty())
	check("a drill equal to the pad is refused (the ring would be zero)",
		not str(data.via_author_error(Vector2(5.0, 5.0), 0.4, 0.4)).is_empty())
	check("a point off the board is refused",
		not str(data.via_author_error(Vector2(-1.0, 5.0), 0.8, 0.4)).is_empty())

	ctx["driver"].free_panel(ctx["panel"])
