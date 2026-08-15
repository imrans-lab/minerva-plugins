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
const PcbRouteHintKind := preload("res://../../minerva-plugins/pcb/ui/kinds/pcb_route_hint_kind.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")
const PcbLayerStack := preload("res://../../minerva-plugins/pcb/ui/model/pcb_layer_stack.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Direct copper verbs (NLC C2 + C3) ===\n")
	await _run_place_via_lands_on_the_board()
	await _run_span_is_not_selectable()
	await _run_refusals_change_nothing()
	await _run_round_trips_with_delete()
	await _run_add_trace_lands_copper()
	await _run_add_trace_refusals()
	await _run_human_via_tool()
	await _run_one_rule_for_both_surfaces()
	await _run_proposal_workspace_contract()
	await _run_proposal_surface_parity()
	await _run_proposal_lifecycle_and_commit_revalidation()
	await _run_trace_hit_junction_and_via_movement()
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



class FakeEditor extends RefCounted:
	var tab_title: String = "NlcProbe"
	var associated_object: Variant = ""


## A panel MOUNTED IN THE REAL TREE, because these suites touch the UI.
##
## plugin_panel_driver.load_panel only calls script.new() — the panel never
## enters the tree, so _ready()/_build_ui() never run and _canvas, _tool_buttons
## and every OptionButton stay null. Both reviews confirmed get_canvas() EXISTS
## and it does; it returns null against an unmounted panel, which only execution
## could show. Mount pattern copied from test_pcb_panel_ui.gd's
## _mount_panel_in_tree, which exists for exactly this reason.
func _mount() -> Variant:
	var panel: Variant = load(PCB_PANEL_SCRIPT_PATH).new()
	get_root().add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(1100, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	for _i in range(6):
		await process_frame
	return panel


func _unmount(panel: Variant) -> void:
	if panel != null and panel is Node:
		(panel as Node).queue_free()
	await process_frame


func _ctx() -> Dictionary:
	var panel = await _mount()
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var data = panel.get_data()
	# A four-layer board, so "the span is always through" is a claim with
	# something to be wrong about — on a 2-layer board top<->bottom is the only
	# span there is and the assertion would be vacuous.
	if data != null and data.has_method("set_board_layers"):
		data.set_board_layers(["top", "in1", "in2", "bottom"])
	# Declared nets. via_author_error refuses a NAMED net the board does not
	# declare (a via on a net nothing else is on is a typo, and the trace side
	# already refused it through trace_author_error), so the fixtures that place
	# a netted via need those nets to exist.
	for net_name in ["GND", "N1"]:
		var net = PcbNet.new()
		net.name = net_name
		data.add_net(net)
	return {"panel": panel, "host": host, "data": data}


# ── 1. it lands on the BOARD, not on a proposal ───────────────────────────────

func _run_place_via_lands_on_the_board() -> void:
	print("-- 1. place_via writes a real board via --")
	var ctx: Dictionary = await _ctx()
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

	await _unmount(ctx["panel"])


# ── 2. a span argument is REFUSED, not ignored ────────────────────────────────

func _run_span_is_not_selectable() -> void:
	print("-- 2. from_layer/to_layer/layers are refused, never silently dropped --")
	var ctx: Dictionary = await _ctx()
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

	await _unmount(ctx["panel"])


# ── 3. every refusal is named, and writes nothing ─────────────────────────────

func _run_refusals_change_nothing() -> void:
	print("-- 3. off-board, stacked, and degenerate geometry all refuse --")
	var ctx: Dictionary = await _ctx()
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

	await _unmount(ctx["panel"])


# ── 4. create and destroy are now symmetric ───────────────────────────────────

func _run_round_trips_with_delete() -> void:
	print("-- 4. place -> delete -> place: the parity claim, end to end --")
	var ctx: Dictionary = await _ctx()
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

	await _unmount(ctx["panel"])


# ── 5. C3: a trace drawn directly, through the HUMAN TOOL'S OWN model path ────
#
# minerva_pcb_delete_traces removed copper directly; nothing drew it. The human
# has had a canvas Trace tool the whole time. RULED HERE, and asserted below:
# the direct verb LANDS COPPER AND RUNS NO DRC, because _commit_trace does not
# gate either — a verb that refused what the Trace tool accepts would make the
# agent a second-class author of the same board.

const PcbNet := preload("res://../../minerva-plugins/pcb/ui/model/pcb_net.gd")


func _trace_ctx() -> Dictionary:
	# N1 is already declared by _ctx(); this alias stays so the trace groups read
	# as stating their own precondition rather than inheriting it silently.
	return await _ctx()


func _run_add_trace_lands_copper() -> void:
	print("-- 5. add_trace writes a real board trace on an INNER layer --")
	var ctx: Dictionary = await _trace_ctx()
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

	await _unmount(ctx["panel"])


# ── 6. C3 refusals: named, and nothing written ────────────────────────────────

func _run_add_trace_refusals() -> void:
	print("-- 6. undeclared layer, unauthorable trace, malformed points --")
	var ctx: Dictionary = await _trace_ctx()
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

	await _unmount(ctx["panel"])


# ── 7. THE HUMAN'S VIA TOOL — the half the owner actually asked for ───────────
#
# "There is no tool to place a via for the human, only propose." That was first
# answered with minerva_pcb_place_via, an MCP verb — the AGENT's half. The owner
# drives this panel with buttons and cannot call MCP, so the reported gap stayed
# open. These assertions are about the CANVAS.

const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")


func _run_human_via_tool() -> void:
	print("-- 7. ToolMode.VIA: a button, a click, a via --")
	var ctx: Dictionary = await _ctx()
	var panel = ctx["panel"]
	var data = ctx["data"]
	# get_canvas lives on the annotation HOST, not the panel (PcbAnnotationHost
	# :1079) — checked rather than assumed.
	var canvas = ctx["host"].get_canvas()
	check("the host exposes the canvas", canvas != null)
	if canvas == null:
		await _unmount(ctx["panel"])
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

	# SNAPPED TO THE AUTHORING GRID, and that is CORRECT — _handle_via_click
	# routes the point through _author_point exactly as the Trace, Zone and
	# Cutout gestures do, so a human's via lands on the same grid as their
	# copper. Found by running this: the first version of this assertion
	# demanded the raw click point and would have pinned a REGRESSION (a via
	# tool that ignored the grid) as correct.
	#
	# Note the deliberate asymmetry with minerva_pcb_place_via, which does NOT
	# snap: an agent supplies exact coordinates and means them, while a human
	# supplies a mouse position and means the nearest grid point.
	var expected: Vector2 = canvas._author_point(Vector2(12.0, 9.0))
	check_eq("at the snapped click point", data.via_position(placed), expected)
	# ...and the snap moved it somewhere SENSIBLE, not merely somewhere
	# self-consistent — a snap returning a constant would satisfy the line above.
	check("the snapped point is within a grid step of the click",
		expected.distance_to(Vector2(12.0, 9.0)) < 1.0)
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

	await _unmount(ctx["panel"])


# ── 8. the model rule itself, read by BOTH surfaces ───────────────────────────

func _run_one_rule_for_both_surfaces() -> void:
	print("-- 8. via_author_error is the single rule --")
	var ctx: Dictionary = await _ctx()
	var data = ctx["data"]

	check_eq("a clean point is placeable",
		str(data.via_author_error(Vector2(5.0, 5.0), 0.8, 0.4)), "")
	check("a drill wider than the pad is refused",
		not str(data.via_author_error(Vector2(5.0, 5.0), 0.4, 0.8)).is_empty())
	check("a drill equal to the pad is refused (the ring would be zero)",
		not str(data.via_author_error(Vector2(5.0, 5.0), 0.4, 0.4)).is_empty())
	check("a point off the board is refused",
		not str(data.via_author_error(Vector2(-1.0, 5.0), 0.8, 0.4)).is_empty())

	await _unmount(ctx["panel"])


# ── 9. standalone proposal model: one entity, one generation ─────────────────

func _run_proposal_workspace_contract() -> void:
	print("-- 9. standalone via proposal model + refusals --")
	var ctx: Dictionary = await _ctx()
	var ws = ctx["panel"].get_routing_workspace()
	var data = ctx["data"]
	var signals := {"added": 0, "changed": 0}
	ws.candidate_added.connect(func(_id: String) -> void: signals.added += 1)
	ws.candidate_changed.connect(func(_id: String) -> void: signals.changed += 1)
	var generation_before := int(ws.workspace_generation())

	var res: Dictionary = ws.propose_via(Vector2(10.0, 11.0), "N1", 0.9, 0.3, data)
	check("workspace proposal succeeds", bool(res.get("ok", false)))
	var cid := str(res.get("candidate_id", ""))
	var candidate = ws.get_candidate(cid)
	check("proposal names a stored candidate", candidate != null and not cid.is_empty())
	check_eq("candidate has zero trace segments", candidate.segments.size(), 0)
	check_eq("candidate has exactly one via", candidate.vias.size(), 1)
	check_eq("candidate starts proposed", str(candidate.disposition), "proposed")
	check_eq("candidate keeps its net", str(candidate.net), "N1")
	var via: Dictionary = candidate.vias[0]
	check_eq("via position is exact", via.get("position"), Vector2(10.0, 11.0))
	check_eq("via diameter survives", float(via.get("diameter", 0.0)), 0.9)
	check_eq("via drill survives", float(via.get("drill", 0.0)), 0.3)
	var span: Array = PcbLayerStack.default_through_via_span()
	check_eq("via uses through-span start", str(via.get("from_layer", "")), str(span[0]))
	check_eq("via uses through-span end", str(via.get("to_layer", "")), str(span[1]))
	check_eq("one candidate means one generation bump",
		int(ws.workspace_generation()), generation_before + 1)
	check_eq("candidate_added emits once", int(signals.added), 1)
	check_eq("no redundant candidate_changed emit", int(signals.changed), 0)

	var duplicate: Dictionary = ws.propose_via(Vector2(10.0, 11.0), "N1", 0.9, 0.3, data)
	check_eq("a duplicate live ghost refuses by name",
		str(duplicate.get("error", "")), "via_not_placeable")
	check("duplicate refusal names the proposed candidate",
		str(duplicate.get("message", "")).contains(cid))
	check_eq("duplicate refusal added nothing", ws.list_candidates().size(), 1)
	check_eq("off-board proposal refuses by name",
		str(ws.propose_via(Vector2(-1.0, 2.0), "", 0.8, 0.4, data).get("error", "")),
		"via_not_placeable")
	check_eq("invalid ring refuses by the same board rule",
		str(ws.propose_via(Vector2(5.0, 5.0), "", 0.4, 0.4, data).get("error", "")),
		"via_not_placeable")
	check_eq("a workspace-only proposal fails closed without its board",
		str(ws.propose_via(Vector2(5.0, 5.0)).get("error", "")), "board_unavailable")

	await _unmount(ctx["panel"])


# ── 10. mounted canvas gesture == MCP surface ─────────────────────────────────

func _run_proposal_surface_parity() -> void:
	print("-- 10. mounted canvas proposal and MCP proposal are parity twins --")
	var human: Dictionary = await _ctx()
	var agent: Dictionary = await _ctx()
	var human_ws = human["panel"].get_routing_workspace()
	var agent_ws = agent["panel"].get_routing_workspace()

	var tool = PcbRouteHintKind.ViaInsertTool.new()
	tool.on_activate(human["host"])
	check("canvas gesture consumes the click", tool._propose_via_at(Vector2(14.0, 16.0)))
	var mcp: Dictionary = PanelTools._propose_via(agent["host"],
		{"x_mm": 14.0, "y_mm": 16.0})
	check("MCP proposal succeeds", bool(mcp.get("success", false)))
	check_eq("each surface creates exactly one ghost",
		[human_ws.list_candidates().size(), agent_ws.list_candidates().size()], [1, 1])
	var human_c = human_ws.list_candidates()[0]
	var agent_c = agent_ws.list_candidates()[0]
	check_eq("surface geometry is identical", human_c.vias, agent_c.vias)
	check_eq("both are via-only", [human_c.segments.size(), agent_c.segments.size()], [0, 0])

	var human_before: int = human_ws.list_candidates().size()
	check("off-board canvas click is consumed", tool._propose_via_at(Vector2(-2.0, 4.0)))
	var mcp_off: Dictionary = PanelTools._propose_via(agent["host"],
		{"x_mm": -2.0, "y_mm": 4.0})
	check_eq("MCP off-board refusal is named", str(mcp_off.get("error", "")),
		"via_not_placeable")
	check_eq("off-board canvas click creates no ghost",
		human_ws.list_candidates().size(), human_before)
	check_eq("off-board MCP call creates no ghost", agent_ws.list_candidates().size(), 1)

	for banned in ["from_layer", "to_layer", "layers"]:
		var args := {"x_mm": 20.0, "y_mm": 20.0}
		args[banned] = "in1"
		check_eq("proposal refuses '%s' rather than dropping it" % banned,
			str(PanelTools._propose_via(agent["host"], args).get("error", "")),
			"span_not_selectable")
	check("non-numeric x refuses",
		not bool(PanelTools._propose_via(agent["host"],
			{"x_mm": "four", "y_mm": 4.0}).get("success", true)))
	check("undeclared net refuses",
		not bool(PanelTools._propose_via(agent["host"],
			{"x_mm": 20.0, "y_mm": 20.0, "net_name": "TYPO"}).get("success", true)))

	tool.on_deactivate()
	await _unmount(human["panel"])
	await _unmount(agent["panel"])


# ── 11. commit/reject/undo and time-of-accept validity ────────────────────────

func _run_proposal_lifecycle_and_commit_revalidation() -> void:
	print("-- 11. via proposal lifecycle + commit-time revalidation --")
	var ctx: Dictionary = await _ctx()
	var data = ctx["data"]
	var ws = ctx["panel"].get_routing_workspace()
	var proposed: Dictionary = PanelTools._propose_via(ctx["host"], {
		"x_mm": 22.0, "y_mm": 23.0, "net_name": "N1",
		"size_mm": 1.0, "drill_mm": 0.35,
	})
	var cid := str(proposed.get("candidate_id", ""))
	check("lifecycle fixture proposed", bool(proposed.get("success", false)))
	check_eq("board is untouched before Accept", data.vias.size(), 0)
	var committed: Dictionary = ws.commit(cid, data)
	check("Accept succeeds", bool(committed.get("ok", false)))
	check_eq("Accept lands exactly one board via", data.vias.size(), 1)
	var landed: Dictionary = data.get_via(str((committed.get("via_ids", []) as Array)[0]))
	check_eq("landed position matches the ghost", data.via_position(landed), Vector2(22.0, 23.0))
	check_eq("landed size matches the ghost", float(landed.get("size", 0.0)), 1.0)
	check_eq("landed drill matches the ghost", float(landed.get("drill", 0.0)), 0.35)
	check_eq("landed net matches the ghost", str(landed.get("net_name", "")), "N1")
	check("one undo succeeds", data.undo())
	check_eq("undo removes the via", data.vias.size(), 0)
	check_eq("undo restores the ghost disposition", str(ws.get_candidate(cid).disposition), "proposed")

	var rejected: Dictionary = PanelTools._propose_via(ctx["host"],
		{"x_mm": 30.0, "y_mm": 31.0})
	var rejected_id := str(rejected.get("candidate_id", ""))
	check("Reject succeeds", ws.reject(rejected_id))
	check_eq("Reject leaves the board untouched", data.vias.size(), 0)
	check_eq("Reject is terminal on the ghost", str(ws.get_candidate(rejected_id).disposition), "rejected")

	# Time-of-check/time-of-accept: real copper landing after proposal must make
	# the stale ghost refuse, not stack a second via at the same point.
	var stale: Dictionary = PanelTools._propose_via(ctx["host"],
		{"x_mm": 40.0, "y_mm": 35.0})
	check("stale-commit fixture proposed (%s)" % str(stale),
		bool(stale.get("success", false)))
	var stale_id := str(stale.get("candidate_id", ""))
	data.add_via({"position": Vector2(40.0, 35.0), "size": 0.8, "drill": 0.4,
		"net_name": "", "from_layer": "top", "to_layer": "bottom"})
	var stale_commit: Dictionary = ws.commit(stale_id, data)
	check_eq("commit revalidation refuses the now-occupied point",
		str(stale_commit.get("error", "")), "via_not_placeable")
	check_eq("refused commit adds no second board via", data.vias.size(), 1)
	check_eq("refused commit leaves the ghost live",
		str(ws.get_candidate(stale_id).disposition), "proposed")

	# A legacy/persisted workspace may contain duplicates even though new
	# proposals cannot create them. Batch preflight must remain all-or-nothing.
	var batch_ctx: Dictionary = await _ctx()
	var batch_ws = batch_ctx["panel"].get_routing_workspace()
	var batch_data = batch_ctx["data"]
	var first: Dictionary = batch_ws.propose_via(Vector2(8.0, 9.0), "", 0.8, 0.4, batch_data)
	var legacy = PcbRouteCandidate.new()
	legacy.add_via(PcbRouteCandidate.make_via("legacy_via", Vector2(8.0, 9.0),
		"top", "bottom", 0.8, 0.4))
	var legacy_id := str(batch_ws.add_candidate(legacy))
	var batch: Dictionary = batch_ws.commit_batch(
		[str(first.get("candidate_id", "")), legacy_id], batch_data)
	check_eq("overlapping standalone batch refuses by name",
		str(batch.get("error", "")), "via_not_placeable")
	check_eq("batch refusal writes no copper", batch_data.vias.size(), 0)

	await _unmount(batch_ctx["panel"])
	await _unmount(ctx["panel"])


# ── 12. trace-hit semantics + Universal Select movement ─────────────────────

func _run_trace_hit_junction_and_via_movement() -> void:
	print("-- 12. trace-hit vias snap, inherit, bisect, and remain movable --")
	var ctx: Dictionary = await _ctx()
	var data = ctx["data"]
	var panel = ctx["panel"]
	var canvas = ctx["host"].get_canvas()
	var workspace = panel.get_routing_workspace()
	var trace = data.create_trace_entity("N1", "top",
		[Vector2(10.0, 10.0), Vector2(30.0, 10.0)], 0.25)
	var trace_id := str(trace.id)

	# The raw point only partly overlaps the trace. It must never survive in
	# that visually-connected/model-disconnected state.
	var placed: Dictionary = PanelTools._place_via(ctx["host"], {
		"x_mm": 20.0, "y_mm": 10.3,
	})
	check("trace-hit direct placement succeeds", bool(placed.get("success", false)))
	check_eq("direct placement reports the trace it joined",
		str(placed.get("trace_id", "")), trace_id)
	var via_id := str(placed.get("via_id", ""))
	var via: Dictionary = data.get_via(via_id)
	check_eq("partly-touching via snaps onto the centreline",
		data.via_position(via), Vector2(20.0, 10.0))
	check_eq("trace-hit via inherits the trace net", str(via.get("net_name", "")), "N1")
	check_eq("trace is explicitly bisected at the via", trace.waypoints.size(), 3)
	check("the bisection point is canonical geometry", Vector2(20.0, 10.0) in trace.waypoints)

	# Universal Select captures committed vias now. Release delegates to
	# PCBData.move_via, so the owned trace junction follows atomically.
	canvas._clear_selection_all()
	canvas._add_to_selection(canvas.KIND_VIA, via_id)
	canvas._capture_drag_origins()
	check("Universal Select captures a committed via for movement",
		canvas._drag_origins.has(canvas.KIND_VIA))
	canvas._apply_drag_delta(Vector2(2.0, 0.0))
	canvas._end_selection_drag()
	via = data.get_via(via_id)
	check_eq("committed via moved through Select-drag",
		data.via_position(via), Vector2(22.0, 10.0))
	check("its trace junction moved with it", Vector2(22.0, 10.0) in trace.waypoints)
	check("the old junction was not left behind", not (Vector2(20.0, 10.0) in trace.waypoints))

	# Via-only ghosts are points in the candidate junction gesture. Moving to
	# empty space clears an inferred net; moving back onto copper snaps/inherits.
	var proposed: Dictionary = workspace.propose_via(
		Vector2(26.0, 10.25), "", 0.8, 0.4, data)
	check("trace-hit via proposal succeeds", bool(proposed.get("ok", false)))
	var cid := str(proposed.get("candidate_id", ""))
	var candidate = workspace.get_candidate(cid)
	check_eq("proposal snaps to the trace", candidate.vias[0]["position"], Vector2(26.0, 10.0))
	check_eq("proposal inherits N1", str(candidate.net), "N1")
	canvas.selected_candidate_ids.clear()
	canvas.selected_candidate_ids.append(cid)
	check("Select-drag arms on a via-only proposal",
		canvas._begin_candidate_junction_drag(cid, Vector2(26.0, 10.0)))
	canvas._end_candidate_junction_drag(Vector2(40.0, 30.0))
	check_eq("via-only proposal moves in empty space",
		candidate.vias[0]["position"], Vector2(40.0, 30.0))
	check_eq("inferred net clears when moved off copper", str(candidate.net), "")
	check("the moved via-only proposal arms again",
		canvas._begin_candidate_junction_drag(cid, Vector2(40.0, 30.0)))
	canvas._end_candidate_junction_drag(Vector2(27.0, 10.2))
	check_eq("proposal re-snaps when moved back to the trace",
		candidate.vias[0]["position"], Vector2(27.0, 10.0))
	check_eq("and re-inherits the trace net", str(candidate.net), "N1")
	var committed: Dictionary = workspace.commit(cid, data)
	check("trace-hit proposal commits", bool(committed.get("ok", false)))
	check("proposal commit materializes the trace bisection",
		Vector2(27.0, 10.0) in trace.waypoints)
	var landed: Dictionary = data.get_via(str((committed.get("via_ids", []) as Array)[0]))
	check_eq("committed proposal via is electrically N1", str(landed.get("net_name", "")), "N1")

	await _unmount(panel)
