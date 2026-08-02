extends SceneTree
## C4a (S4) — routing-workspace VERB layer: the ten minerva_pcb_workspace_* tool
## contracts, the composite COMMIT transaction (INV-1), the stale-on-every-verb
## matrix (INV-2), the PATH-SCOPED via edit (INV-3), and the eraser adjudication.
##
## ── PARKED (epoch C regime) ───────────────────────────────────────────────────
## This file lives in pcb/tests/pending/, NOT pcb/tests/gd/. It is deliberately
## invisible to the runner (run-gd-tests.sh globs pcb/tests/gd/test_*.gd) and to
## the EXPECTED_SUITES manifest cross-check. It is AUTHORED for review this
## epoch and EXECUTED at the epoch boundary, where it moves into gd/ and is added
## to EXPECTED_SUITES in the same commit.
##
## Run (at the boundary, via a Minerva scaffold as the Godot host — NEVER the
## live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_workspace_tools.gd
##
## ── WHAT IS REAL AND WHAT IS SUBSTITUTED ──────────────────────────────────────
## Groups 1, 2 and 8 boot a REAL PCBPanel (plugin_panel_driver) with its real
## board, real annotation host and real RoutingWorkspace, and drive the REAL tool
## bodies in panel_tools.gd. The ONLY substitution is the router worker hop — a
## thin shim forwards every host call to the real host and answers run_router
## with a fixture reply, exactly the substitution test_parity_bridge.gd already
## makes (the worker is Python and does not run under the gd scaffold).
##
## Groups 3-7 use a bare RoutingWorkspace + PCBData with NO panel, because the
## three invariants live in the MODEL: a panel would add mounting noise to
## assertions about a history bucket and a segment graph. The one exception is
## group 5's legacy Add-Via case, which MUST cross the annotation side to prove
## anything, and group 9's tool-envelope half.
##
## Coverage (9 groups):
##   1. TOOL SURFACE: list/get_active/pin/unpin/reject reply shapes, live-only
##      default, named refusals, and PROPOSE surfacing ingest HOLDS.
##   2. REROUTE-SPAN DEGRADE: the reply names degraded/degraded_to/limitation/
##      docket, reroutes the WHOLE route, and creates NO span-scoped task.
##   3. INV-1 GATE: undo-after-commit restores the BOARD **and** the candidate's
##      pre-commit disposition; redo restores both again. Multi-pad fixture with
##      a via, per the GATE's mandatory-fixture rule.
##   4. INV-1 ATOMICITY: every refusal path leaves NO half-state — no copper, no
##      disposition move, no history entry.
##   5. INV-2 MATRIX: every candidate-mutating verb versus what it stales, INCL.
##      the two deliberate non-stalers (pin/unpin) asserted as non-stalers, and
##      sync_candidate_geometry driven through the real legacy Add-Via tool.
##   6. INV-3 GATE: a via edit on one path leaves the DISCONNECTED path
##      byte-identical; the layer-run flip stops at an existing layer change.
##   7. INV-3 REFUSALS: degenerate inserts (on a vertex, inside an existing
##      via's disc), no segment under the point, illegal span, a from_layer that
##      disagrees with the copper, terminal candidate.
##   8. ERASER ADJUDICATION, both ways: the eraser does NOT reject a ghost, and
##      it does NOT refuse silently either — it emits a notice naming Reject.
##   9. CHECK GATE: a stale candidate refuses the draft check by name, and
##      include_stale is the stated second exit.
##
## NUMERIC-COMPARISON RULE for this file (same as the C1/C3 suites): every
## numeric assertion is normalised with int()/float() before comparing, and NO
## assertion compares whole containers whose values may have crossed a JSON
## boundary. GDScript container equality is type-strict about the int/float
## distinction JSON erases, so a container compare is a coin-flip oracle.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PcbData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")
const PcbCutover := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_cutover.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const ANNOTATION_HOST_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PcbAnnotationHost.gd"
## C4b (S5) group 10 only — same helper the shipped panel-tool suites use for
## the load-request drive + temp-sidecar cleanup idiom.
const DRIVER := preload("res://test/helpers/plugin_panel_driver.gd")

var _pass := 0
var _fail := 0

# Recorder for the canvas teach/notice channel (group 8).
var _messages: Array = []


## The host document a panel is handed on mount. Same stand-in the shipped
## canvas probe uses (test_pcb_canvas_input_probe.gd) — a panel needs an
## `editor` object with these two fields and nothing else.
class FakeEditor extends RefCounted:
	var tab_title: String = "C4a Tab"
	var associated_object: Variant = ""


func _init() -> void:
	print("=== Routing-workspace VERB layer (C4a / S4) Tests ===\n")
	await process_frame
	await _run_tool_surface()
	await _run_reroute_span_degrade()
	_run_inv1_undo_after_commit()
	_run_inv1_atomicity()
	await _run_inv2_stale_matrix()
	_run_inv3_path_scoped_edit()
	_run_inv3_degenerate_refusals()
	await _run_eraser_adjudication()
	await _run_check_stale_gate()
	await _run_removal_contract()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── assertion helpers (same idiom as the shipped suites) ──────────────────────

func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


# ══ fixtures ═════════════════════════════════════════════════════════════════

## THE MANDATORY GATE FIXTURE. 3-pad net "N1" whose route is TWO DISCONNECTED
## copper paths:
##   path A — seg (0,0)->(5,0) on F.Cu  +  seg (5,0)->(5,5) on B.Cu, joined by a
##            layer-changing via at (5,0);
##   path B — seg (50,50)->(60,50) on F.Cu, sharing NO endpoint with either.
## Hand-derived: 3 segments, 2 layers, 1 via, 2 components in the segment graph.
## `hint_ids` mirrors the worker's own per-route attribution stamp (methods.py
## _hint_ids_by_net) — a real reply always carries it once any hint was supplied.
func _multipad_reply(hint_ids: Array = []) -> Dictionary:
	return {
		"routes": [
			{
				"net": "N1",
				"segments": [
					{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"},
					{"start": [5.0, 0.0], "end": [5.0, 5.0], "layer": "B.Cu"},
					{"start": [50.0, 50.0], "end": [60.0, 50.0], "layer": "F.Cu"},
				],
				"vias": [[5.0, 0.0]],
				"hint_ids": hint_ids,
			}
		],
		"via_count": 1,
	}


## The same fixture as a NORMALIZED record (what ingest_record consumes), so the
## model-only groups build the identical geometry without a panel.
func _multipad_record(hint_ids: Array = ["hint_1"]) -> Dictionary:
	return {
		"net": "N1",
		"segments": _multipad_reply()["routes"][0]["segments"],
		"vias": [[5.0, 0.0]],
		"width": 0.3,
		"source_hint_ids": hint_ids,
		"source_hints": [],
	}


## A workspace holding ONE multipad candidate at board revision 0, plus a board.
## Returns {"ws":…, "data":…, "cid":…}. The board carries a BASELINE history
## entry, because undo() restores the PREVIOUS entry and a board with only one
## entry has nothing to undo to.
func _model_context() -> Dictionary:
	var ws = PcbWorkspace.new()
	var data = PcbData.new()
	data.save_to_history("baseline")
	var cid := str(ws.ingest_record(_multipad_record(), int(data.board_revision)))
	return {"ws": ws, "data": data, "cid": cid}


## A real source-hint annotation on a real host + the propose-shaped source_hints
## array referencing its real id. Returns [hint_id, source_hints].
func _seed_source_hint(host) -> Array:
	var env: Dictionary = host.build_route_hint_envelope(
		0.0, 0.0, "", "F.Cu", "waypoint", [[0.0, 0.0], [5.0, 0.0]], "human")
	var hint_id: String = str(host.add_annotation_v2(env))
	return [hint_id, [{
		"id": hint_id,
		"kind_payload": {"net_names": ["N1"], "width_mm": 0.3,
			"source_pins": ["U1.3"], "dest_pins": ["U2.7"]},
	}]]


## Forward every host call the workspace tools make to the REAL host, and answer
## the ROUTER hop with a fixture. This is the one substitution in the panel
## groups — the router worker is Python and does not run under the gd scaffold.
class RouterShim extends RefCounted:
	var real
	var reply: Dictionary = {}
	var calls: Array = []

	func _init(real_host, router_reply: Dictionary) -> void:
		real = real_host
		reply = router_reply

	func run_router(selection: Dictionary) -> Dictionary:
		calls.append(selection)
		return {"ok": true, "result": reply}

	func get_board_data():
		return real.get_board_data()

	func get_panel():
		return real.get_panel()

	func get_all_annotations() -> Array:
		return real.get_all_annotations()

	func get_by_id(id: String) -> Dictionary:
		return real.get_by_id(id)

	func build_route_hint_envelope(x: float, y: float, note: String, layer: String,
			kind: String, pts: Array, author: String) -> Dictionary:
		return real.build_route_hint_envelope(x, y, note, layer, kind, pts, author)

	func add_annotation_v2(envelope: Dictionary) -> String:
		return str(real.add_annotation_v2(envelope))

	func remove_annotation(id: String) -> bool:
		return bool(real.remove_annotation(id))


## Boot a real PCBPanel, wire the host->panel back-reference, and wrap the host
## in a RouterShim answering with the multipad fixture.
## Returns {"driver","panel","host","shim","ws","data","hint_id"}.
##
## `mounted` decides HOW real the panel is, and the distinction is load-bearing:
## plugin_panel_driver.load_panel() only INSTANTIATES the script, which is all
## the tool bodies need (they reach the board/workspace through the host). The
## CANVAS is built during the panel's own mount, so panel._canvas is null until
## the panel is in the tree and _on_panel_loaded has run — group 8 drives a real
## canvas and therefore asks for the full mount, at the cost of the four frames
## a container needs to lay out.
func _panel_context(mounted: bool = false) -> Dictionary:
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	if mounted:
		get_root().add_child(panel)
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.size = Vector2(900, 700)
		panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
		for _i in range(4):
			await process_frame
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var seeded := _seed_source_hint(host)
	var shim := RouterShim.new(host, _multipad_reply([str(seeded[0])]))
	return {
		"driver": driver, "panel": panel, "host": host, "shim": shim,
		"ws": panel.get_routing_workspace(), "data": panel.get_data(),
		"hint_id": str(seeded[0]),
	}


## The tools take editor_name in production (the dispatcher resolves the panel
## from it before calling here), so the arg is present but never read by these
## bodies — spelled once so every call site below reads the same.
func _args(extra: Dictionary = {}) -> Dictionary:
	var a: Dictionary = {"editor_name": "PCB"}
	a.merge(extra, true)
	return a


# ══ 1. tool surface + propose HOLDS ══════════════════════════════════════════

func _run_tool_surface() -> void:
	print("-- 1. tool surface: list / get_active / pin / unpin / reject + propose HOLDS --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]

	# ── PROPOSE lands CANDIDATES and writes NO proposal annotation ────────────
	var anns_before: int = (ctx["host"].get_all_annotations() as Array).size()
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose succeeded", bool(out.get("success", false)))
	check_eq("propose landed one candidate", int(out.get("proposed", 0)), 1)
	check_eq("propose saw one route", int(out.get("routes_returned", 0)), 1)
	check_eq("propose held nothing on a fresh workspace",
		(out.get("holds", []) as Array).size(), 0)
	check_eq("propose wrote NO annotation (the workspace is the answer, not a shadow)",
		(ctx["host"].get_all_annotations() as Array).size(), anns_before)
	var cand_rec: Dictionary = (out.get("candidates", []) as Array)[0]
	var cid := str(cand_rec.get("candidate_id", ""))
	check("candidate record carries an id", not cid.is_empty())
	check_eq("candidate is proposed", str(cand_rec.get("disposition", "")), "proposed")
	check_eq("candidate is unchecked", str(cand_rec.get("validation", "")), "unchecked")
	check_eq("candidate reports 3 segments", int(cand_rec.get("segment_count", 0)), 3)
	check_eq("candidate reports 1 via", int(cand_rec.get("via_count", 0)), 1)
	check_eq("candidate names BOTH layers", (cand_rec.get("layers", []) as Array).size(), 2)
	check_eq("its task is open", str(cand_rec.get("task_state", "")), "open")

	# ── LIST: live-only by default ────────────────────────────────────────────
	var listed: Dictionary = PanelTools._workspace_list(shim, _args())
	check_eq("list returns the one live candidate", int(listed.get("count", 0)), 1)
	check_eq("list reports one task", (listed.get("tasks", []) as Array).size(), 1)
	check_eq("list reports the task as open", (listed.get("open_task_ids", []) as Array).size(), 1)

	# ── GET_ACTIVE with nothing active is a SUCCESS, not an error ─────────────
	var active: Dictionary = PanelTools._workspace_get_active(shim, _args())
	check("get_active succeeds with no active candidate", bool(active.get("success", false)))
	check_eq("get_active reports an empty active id", str(active.get("active_candidate_id", "")), "")
	ws.set_active(cid)
	active = PanelTools._workspace_get_active(shim, _args())
	check_eq("get_active reports the focused candidate", str(active.get("active_candidate_id", "")), cid)

	# ── PIN / UNPIN ───────────────────────────────────────────────────────────
	var pinned: Dictionary = PanelTools._workspace_pin(shim, _args({"candidate_id": cid}))
	check("pin succeeded", bool(pinned.get("success", false)))
	check_eq("pin moved the disposition", str(pinned.get("disposition", "")), "pinned")
	check("pin is reported in pinned_candidate_ids",
		cid in (PanelTools._workspace_list(shim, _args()).get("pinned_candidate_ids", []) as Array))

	# ── PROPOSE AGAIN: the pinned candidate HOLDS its task, and it is SURFACED
	# (this is the reason holds exist — the reply lands FEWER candidates than
	# routes and must say which task and why).
	var held: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("second propose still succeeded", bool(held.get("success", false)))
	check_eq("second propose landed NOTHING", int(held.get("proposed", 0)), 0)
	check_eq("second propose still saw one route", int(held.get("routes_returned", 0)), 1)
	var holds: Array = held.get("holds", [])
	check_eq("the held task is reported exactly once", holds.size(), 1)
	if holds.size() == 1:
		var h: Dictionary = holds[0]
		check_eq("the hold names the pinned candidate", str(h.get("held_candidate_id", "")), cid)
		check_eq("the hold names the net", str(h.get("net", "")), "N1")
		check_eq("the hold is named pinned_candidate_held",
			str(h.get("reason", "")), PcbWorkspace.HOLD_PINNED)
	check_eq("the pinned candidate is untouched",
		str(ws.get_candidate(cid).disposition), "pinned")

	# ── UNPIN, then REJECT ────────────────────────────────────────────────────
	var unpinned: Dictionary = PanelTools._workspace_unpin(shim, _args({"candidate_id": cid}))
	check("unpin succeeded", bool(unpinned.get("success", false)))
	check_eq("unpin returned to proposed", str(unpinned.get("disposition", "")), "proposed")

	var rejected: Dictionary = PanelTools._workspace_reject(shim, _args({"candidate_id": cid}))
	check("reject succeeded", bool(rejected.get("success", false)))
	check_eq("reject moved the disposition", str(rejected.get("disposition", "")), "rejected")
	check_eq("reject reopened the task", str(rejected.get("task_state", "")), "open")

	# ── NAMED REFUSALS, not prose ─────────────────────────────────────────────
	var refused: Dictionary = PanelTools._workspace_pin(shim, _args({"candidate_id": cid}))
	check("pinning a rejected candidate fails", not bool(refused.get("success", true)))
	check_eq("the refusal is NAMED terminal_disposition",
		str(refused.get("error", "")), PcbRouteCandidate.ERR_TERMINAL_DISPOSITION)
	check_eq("the refusal names where it was", str(refused.get("from", "")), "rejected")
	check_eq("the refusal names where it was asked to go", str(refused.get("to", "")), "pinned")

	var missing: Dictionary = PanelTools._workspace_pin(shim, _args({"candidate_id": "cand_nope"}))
	check_eq("an unknown candidate is named candidate_not_found",
		str(missing.get("error", "")), PcbWorkspace.ERR_NO_CANDIDATE)

	# A terminal candidate is hidden by default and visible on request — the
	# list's two modes, asserted as two answers about the SAME candidate.
	check_eq("terminal candidates are hidden by default",
		int(PanelTools._workspace_list(shim, _args()).get("count", 0)), 0)
	check_eq("include_terminal reveals it",
		int(PanelTools._workspace_list(shim, _args({"include_terminal": true})).get("count", 0)), 1)

	ctx["driver"].free_panel(ctx["panel"])


# ══ 2. reroute-span DEGRADES, and says so on the reply ═══════════════════════

func _run_reroute_span_degrade() -> void:
	print("-- 2. reroute_span degrades to a whole-route reroute, named on the reply --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var cid := str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var task_before := str(ws.get_candidate(cid).task_id)
	var tasks_before: int = (ws.list_tasks() as Array).size()

	var out: Dictionary = await PanelTools._workspace_reroute_span(
		shim, _args({"candidate_id": cid, "segment_ids": ["seg_2"]}))
	check("reroute_span succeeded", bool(out.get("success", false)))
	check("the reply DECLARES it degraded", bool(out.get("degraded", false)))
	check_eq("it names what it degraded to", str(out.get("degraded_to", "")), "whole_route")
	check_eq("it echoes the span the caller asked for",
		(out.get("requested_segment_ids", []) as Array).size(), 1)
	check("it explains the limitation in words", str(out.get("limitation", "")).length() > 40)
	check_eq("it cites the tracking docket",
		str(out.get("limitation_docket", "")), "019fc155bc32")
	check_eq("it landed a WHOLE-ROUTE candidate (3 segments, not the 1 named)",
		int(((out.get("candidates", []) as Array)[0] as Dictionary).get("segment_count", 0)), 3)

	# NO span-scoped task was invented. Recording a span QUESTION whose ANSWER is
	# whole-route geometry would make the model claim a scope it never had.
	check_eq("no new task was created", (ws.list_tasks() as Array).size(), tasks_before)
	check("the replacement answers the SAME task", bool(out.get("same_task", false)))
	for t in ws.list_tasks():
		check("no task is span-scoped", not bool(t.is_span_scoped()))
	check_eq("the prior task id is reported", str(out.get("prior_task_id", "")), task_before)

	# The prior was PROPOSED, so the ingest itself superseded it — one live
	# answer per task, still.
	check_eq("the prior candidate was superseded",
		str(ws.get_candidate(cid).disposition), "superseded")
	check_eq("its task has exactly one live answer",
		(ws.candidates_for_task(task_before) as Array).size(), 1)

	ctx["driver"].free_panel(ctx["panel"])


# ══ 3. INV-1 GATE: undo after commit restores BOARD **and** DISPOSITION ══════

func _run_inv1_undo_after_commit() -> void:
	print("-- 3. INV-1 GATE: undo-after-commit restores the board AND the pre-commit disposition --")
	var ctx := _model_context()
	var ws = ctx["ws"]
	var data = ctx["data"]
	var cid: String = ctx["cid"]
	check("the GATE fixture landed a candidate", not cid.is_empty())

	# PIN it first, so the restored disposition is a NON-DEFAULT value: a test
	# that committed from "proposed" could not tell a real restore from a
	# constructor default.
	check("pin the candidate before committing", ws.pin(cid))
	var history_before: int = (data.history as Array).size()

	var res: Dictionary = ws.commit(cid, data)
	check("commit reports ok", bool(res.get("ok", false)))
	check_eq("commit wrote ONE TRACE PER SEGMENT", (res.get("trace_ids", []) as Array).size(), 3)
	check_eq("commit wrote the via", (res.get("via_ids", []) as Array).size(), 1)
	check_eq("the board holds 3 traces", int(data.traces.size()), 3)
	check_eq("the board holds 1 via", int(data.vias.size()), 1)
	check_eq("commit is ONE history step", int((data.history as Array).size()), history_before + 1)
	check_eq("the candidate is committed", str(ws.get_candidate(cid).disposition), "committed")
	check_eq("its task closed", ws.task_state(str(ws.get_candidate(cid).task_id)), "closed")
	check_eq("the source hints were consumed BY RECORD",
		(ws.consumed_hint_ids(cid) as Array).size(), 1)
	check_eq("the recorded copper ids match what was written",
		(ws.committed_copper_ids(cid).get("trace_ids", []) as Array).size(), 3)

	# Per-segment fidelity: the two layers survive as two layers. A commit that
	# flattened them would produce three traces on one layer and read as green
	# on a count-only assertion.
	var layers: Dictionary = {}
	for tid in data.traces:
		layers[str(data.traces[tid].layer)] = true
	check_eq("committed copper carries BOTH layers", layers.size(), 2)
	check("committed copper carries the top layer", layers.has("top"))
	check("committed copper carries the bottom layer", layers.has("bottom"))

	# ── THE GATE ──────────────────────────────────────────────────────────────
	check("data.undo() reports success", data.undo())
	check_eq("undo removed every trace", int(data.traces.size()), 0)
	check_eq("undo removed the via (never orphaned)", int(data.vias.size()), 0)
	check_eq("undo restored the PRE-COMMIT disposition (bucket 8)",
		str(ws.get_candidate(cid).disposition), "pinned")
	check("undo put the candidate back in the live set", cid in ws.live_candidate_ids())
	check("undo restored the derived pinned-set entry", ws.is_pinned(cid))
	check_eq("undo reopened the task",
		ws.task_state(str(ws.get_candidate(cid).task_id)), "open")
	check_eq("undo cleared the recorded copper ids",
		(ws.committed_copper_ids(cid).get("trace_ids", []) as Array).size(), 0)
	check_eq("the restored candidate is STALE (the board moved under it)",
		str(ws.get_candidate(cid).validation), "stale")

	# ── AND BACK: redo restores both halves too, from the POST-commit bucket ──
	check("data.redo() reports success", data.redo())
	check_eq("redo restored the traces", int(data.traces.size()), 3)
	check_eq("redo restored the via", int(data.vias.size()), 1)
	check_eq("redo restored the committed disposition",
		str(ws.get_candidate(cid).disposition), "committed")


# ══ 4. INV-1 ATOMICITY: a refused commit leaves NO half-state ════════════════

func _run_inv1_atomicity() -> void:
	print("-- 4. INV-1 atomicity: every refusal leaves no copper, no move, no history --")

	# (a) A segment the board cannot model — ONE point. All validation precedes
	#     all mutation, so nothing at all should have happened.
	var ws = PcbWorkspace.new()
	var data = PcbData.new()
	data.save_to_history("baseline")
	var c = PcbRouteCandidate.new()
	c.net = "N1"
	c.task_id = "N1|"
	c.add_segment(PcbRouteCandidate.make_segment("", "top", 0.3, [Vector2(0, 0), Vector2(5, 0)]))
	c.add_segment(PcbRouteCandidate.make_segment("", "top", 0.3, [Vector2(9, 9)]))
	var cid := str(ws.add_candidate(c))
	var history_before: int = (data.history as Array).size()
	var res: Dictionary = ws.commit(cid, data)
	check("a one-point segment refuses the commit", not bool(res.get("ok", true)))
	check_eq("the refusal is NAMED unmodelable_segment",
		str(res.get("error", "")), PcbWorkspace.ERR_UNMODELABLE_SEGMENT)
	check_eq("NO copper was written (not even the good segment)", int(data.traces.size()), 0)
	check_eq("NO via was written", int(data.vias.size()), 0)
	check_eq("NO history entry was appended", int((data.history as Array).size()), history_before)
	check_eq("the disposition did NOT move", str(ws.get_candidate(cid).disposition), "proposed")

	# (b) An illegal via span — same shape, different reason.
	var ws2 = PcbWorkspace.new()
	var data2 = PcbData.new()
	data2.save_to_history("baseline")
	var c2 = PcbRouteCandidate.new()
	c2.net = "N1"
	c2.add_segment(PcbRouteCandidate.make_segment("", "top", 0.3, [Vector2(0, 0), Vector2(5, 0)]))
	c2.add_via(PcbRouteCandidate.make_via("", Vector2(5, 0), "top", "top"))
	var cid2 := str(ws2.add_candidate(c2))
	var res2: Dictionary = ws2.commit(cid2, data2)
	check("a same-layer via span refuses the commit", not bool(res2.get("ok", true)))
	check_eq("the refusal is NAMED illegal_via_span",
		str(res2.get("error", "")), PcbWorkspace.ERR_ILLEGAL_VIA_SPAN)
	check_eq("no copper was written for the legal segment either",
		int(data2.traces.size()), 0)

	# (c) A TERMINAL candidate refuses before the board is opened at all.
	var ctx := _model_context()
	var ws3 = ctx["ws"]
	var data3 = ctx["data"]
	var cid3: String = ctx["cid"]
	check("reject it first", ws3.reject(cid3))
	var hist3: int = (data3.history as Array).size()
	var res3: Dictionary = ws3.commit(cid3, data3)
	check("committing a rejected candidate is refused", not bool(res3.get("ok", true)))
	check_eq("the refusal is the LEGALITY TABLE's own name",
		str(res3.get("error", "")), PcbRouteCandidate.ERR_TERMINAL_DISPOSITION)
	check_eq("the board was never opened", int((data3.history as Array).size()), hist3)
	check_eq("still no copper", int(data3.traces.size()), 0)

	# (d) No board at all is a named refusal, not a crash and not a fake success.
	var res4: Dictionary = ws3.commit(cid3, null)
	check_eq("commit with no board is named board_unavailable",
		str(res4.get("error", "")), PcbWorkspace.ERR_NO_BOARD)


# ══ 5. INV-2: the stale-on-every-verb MATRIX ═════════════════════════════════

## Two live candidates on DIFFERENT tasks, both carrying a real verdict, plus a
## board. Returns {"ws","data","a","b"}.
func _stale_context() -> Dictionary:
	var ws = PcbWorkspace.new()
	var data = PcbData.new()
	data.save_to_history("baseline")
	var a := str(ws.ingest_record(_multipad_record(["hint_a"]), 0))
	var rec_b: Dictionary = _multipad_record(["hint_b"])
	rec_b["net"] = "N2"
	var b := str(ws.ingest_record(rec_b, 0))
	ws.set_validation(a, "clean")
	ws.set_validation(b, "clean")
	return {"ws": ws, "data": data, "a": a, "b": b}


func _run_inv2_stale_matrix() -> void:
	print("-- 5. INV-2: which verb stales which candidate (incl. the deliberate non-stalers) --")

	# ── pin / unpin: THE DELIBERATE NON-STALERS ───────────────────────────────
	# Asserted as non-stalers, not merely omitted: pinning moves no copper and
	# does not change the set a draft check scores, so the check the user ran in
	# order to DECIDE to pin must survive the pinning.
	var p := _stale_context()
	check("pin applies", p["ws"].pin(p["a"]))
	check_eq("pin did NOT stale the pinned candidate",
		str(p["ws"].get_candidate(p["a"]).validation), "clean")
	check_eq("pin did NOT stale the other candidate",
		str(p["ws"].get_candidate(p["b"]).validation), "clean")
	check("unpin applies", p["ws"].unpin(p["a"]))
	check_eq("unpin did NOT stale the unpinned candidate",
		str(p["ws"].get_candidate(p["a"]).validation), "clean")
	check_eq("unpin did NOT stale the other candidate",
		str(p["ws"].get_candidate(p["b"]).validation), "clean")

	# ── reject: the live set changed, so every candidate LIVE AFTERWARDS goes ──
	var r := _stale_context()
	check("reject applies", r["ws"].reject(r["a"]))
	check_eq("the other LIVE candidate went stale",
		str(r["ws"].get_candidate(r["b"]).validation), "stale")
	check_eq("the rejected candidate is terminal, so its verdict is not touched",
		str(r["ws"].get_candidate(r["a"]).validation), "clean")

	# ── supersede (targeted Try-again): same rule ─────────────────────────────
	var s := _stale_context()
	check("supersede applies", s["ws"].supersede(s["a"]))
	check_eq("the other live candidate went stale",
		str(s["ws"].get_candidate(s["b"]).validation), "stale")

	# ── commit: the live set AND the board changed ────────────────────────────
	var k := _stale_context()
	check("commit applies", bool(k["ws"].commit(k["a"], k["data"]).get("ok", false)))
	check_eq("the other live candidate went stale",
		str(k["ws"].get_candidate(k["b"]).validation), "stale")

	# ── uncommit (the board-undo compensator): the returning candidate is LIVE
	#    afterwards, so the rule catches it too ────────────────────────────────
	var u := _stale_context()
	check("commit first", bool(u["ws"].commit(u["a"], u["data"]).get("ok", false)))
	u["ws"].set_validation(u["a"], "clean")   # pretend it was re-checked as copper
	u["ws"].set_validation(u["b"], "clean")
	check("uncommit applies", u["ws"].uncommit(u["a"]))
	check_eq("the RETURNING candidate went stale",
		str(u["ws"].get_candidate(u["a"]).validation), "stale")
	check_eq("the other live candidate went stale too",
		str(u["ws"].get_candidate(u["b"]).validation), "stale")

	# ── the geometry half: an EDIT stales only the edited candidate ───────────
	var e := _stale_context()
	var edit: Dictionary = e["ws"].add_via(e["a"], Vector2(2.5, 0.0), "top", "bottom")
	check("the via edit applied", bool(edit.get("ok", false)))
	check_eq("the EDITED candidate went stale",
		str(e["ws"].get_candidate(e["a"]).validation), "stale")
	check_eq("the untouched candidate kept its verdict",
		str(e["ws"].get_candidate(e["b"]).validation), "clean")
	check("the edit bumped candidate_revision",
		int(e["ws"].get_candidate(e["a"]).candidate_revision) > 0)

	# ── UNCHECKED is not "staled": there is no verdict to invalidate, and
	#    staling every fresh candidate on every re-propose would be noise ──────
	var n := _stale_context()
	n["ws"].set_validation(n["b"], "unchecked")
	check("reject applies", n["ws"].reject(n["a"]))
	check_eq("an UNCHECKED candidate is left unchecked, not staled",
		str(n["ws"].get_candidate(n["b"]).validation), "unchecked")

	# ── findings go with the verdict (stale findings can never render) ────────
	var f := _stale_context()
	f["ws"].apply_check_result({
		"board_token": f["ws"].board_token,
		"workspace_generation": f["ws"].workspace_generation(),
		"per_candidate": {f["b"]: "violating"},
		"findings": [{"type": "crossing", "subjects": [{"candidate_id": f["b"], "segment_id": "seg_1"}]}],
	})
	check_eq("the finding was stored", (f["ws"].findings_for_candidate(f["b"]) as Array).size(), 1)
	check("reject the other candidate", f["ws"].reject(f["a"]))
	check_eq("staling DROPPED the findings (they name subjects that may be gone)",
		(f["ws"].findings_for_candidate(f["b"]) as Array).size(), 0)

	# ── THE LEGACY ADD-VIA PATH also stales, and it is the one that could hurt ──
	# panel_tools._add_via edits a proposal ANNOTATION and then re-derives the
	# correlated candidate's geometry through sync_candidate_geometry. That is a
	# GEOMETRY verb reached from the annotation side, so a candidate that had been
	# checked clean would otherwise carry that verdict onto copper that just
	# changed shape. The bumped candidate_revision does NOT cover this: it only
	# discards an IN-FLIGHT check, never a verdict that already landed.
	#
	# Driven through the REAL bridged path — but S5 (C4b, DCR 019f7095c395)
	# retired _dual_write_propose: PROPOSE no longer writes a proposal
	# annotation, only a workspace candidate (panel_tools.gd
	# _propose_into_workspace). This scenario is therefore a LEGACY-BOARD case
	# now, not a fresh-propose one: a board saved before the cutover may still
	# carry a proposal annotation correlated to a candidate (both stores were
	# written together back then, by the now-retired dual-write). Hand-build
	# that exact pre-S5 pairing — same envelope shape, same ingest+correlate —
	# so the bridged-staling behavior under test (legacy Add-Via still reaching
	# a correlated candidate) is exercised unchanged.
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var bws = ctx["ws"]
	var seeded := _seed_source_hint(host)
	var legacy_records: Array = PanelTools._normalize_route_records(
		_multipad_reply([str(seeded[0])]), seeded[1])
	check("legacy fixture: one route record normalized", legacy_records.size() == 1)
	var ann_id := ""
	var bcid := ""
	if legacy_records.size() == 1:
		var lrec: Dictionary = legacy_records[0]
		var lpts: Array = lrec.get("polyline", [])
		var lfirst: Array = lpts[0]
		var lenv: Dictionary = host.build_route_hint_envelope(
			float(lfirst[0]), float(lfirst[1]), "", str(lrec.get("layer", "F.Cu")),
			"single_trace", lpts, "ai")
		var lkp: Dictionary = lenv.get("kind_payload", {})
		lkp["net_names"] = [str(lrec.get("net", ""))]
		lkp["proposal_for"] = lrec.get("source_hint_ids", [])
		lkp["segments"] = (lrec.get("segments", []) as Array).duplicate(true)
		lkp["vias"] = (lrec.get("vias", []) as Array).duplicate(true)
		lenv["kind_payload"] = lkp
		ann_id = str(host.add_annotation_v2(lenv))
		bcid = str(bws.ingest_record(lrec, int(ctx["data"].board_revision)))
		if not bcid.is_empty() and bws.has_method("correlate"):
			var lcand = bws.get_candidate(bcid)
			bws.correlate(bcid, ann_id, str(lcand.task_id) if lcand != null else "",
				int(lcand.generation) if lcand != null else 0)
	check("the legacy pairing bridged a candidate to its proposal", not bcid.is_empty())
	bws.set_validation(bcid, "clean")
	var rev_before: int = int(bws.get_candidate(bcid).candidate_revision)

	# (2.5, 0) is the midpoint of the fixture's first leg — real copper.
	var added: Dictionary = PanelTools._add_via(host, {"id": ann_id, "x": 2.5, "y": 0.0})
	check("the legacy Add-Via tool succeeded", bool(added.get("success", false)))
	check("it reported the bridged sync", bool(added.get("bridged_candidate_synced", false)))
	check("sync_candidate_geometry bumped candidate_revision",
		int(bws.get_candidate(bcid).candidate_revision) > rev_before)
	check_eq("AND the clean verdict is gone — the geometry moved under it",
		str(bws.get_candidate(bcid).validation), "stale")
	ctx["driver"].free_panel(ctx["panel"])


# ══ 6. INV-3 GATE: the via edit is PATH-SCOPED ═══════════════════════════════

func _run_inv3_path_scoped_edit() -> void:
	print("-- 6. INV-3 GATE: a via edit on one path leaves the DISCONNECTED path untouched --")
	var ctx := _model_context()
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var cand = ws.get_candidate(cid)

	# Hand-derived from _multipad_record: segments[0] = path A top leg,
	# segments[1] = path A bottom leg, segments[2] = path B (disconnected).
	var id_a := str((cand.segments[0] as Dictionary).get("id", ""))
	var id_b := str((cand.segments[1] as Dictionary).get("id", ""))
	var id_c := str((cand.segments[2] as Dictionary).get("id", ""))

	# The graph itself, before any edit: TWO components, and the connected-path
	# query agrees with the fixture's own drawing.
	var path_a: Array = ws.connected_path_segment_ids(cid, id_a)
	check_eq("path A has exactly two segments", path_a.size(), 2)
	check("path A contains the top leg", id_a in path_a)
	check("path A contains the bottom leg (joined at the via point)", id_b in path_a)
	var path_c: Array = ws.connected_path_segment_ids(cid, id_c)
	check_eq("path B stands alone", path_c.size(), 1)
	check("path B is the far segment", id_c in path_c)

	# The exact geometry of path B, captured BEFORE the edit so "untouched" is a
	# comparison and not a claim.
	var c_points_before: Array = (cand.segments[2] as Dictionary).get("points", []).duplicate()
	var c_layer_before := str((cand.segments[2] as Dictionary).get("layer", ""))
	var segs_before: int = (cand.segments as Array).size()

	# EDIT ON PATH A, at the midpoint of its top leg: (2.5, 0) on (0,0)-(5,0).
	var res: Dictionary = ws.add_via(cid, Vector2(2.5, 0.0), "top", "bottom")
	check("the edit applied", bool(res.get("ok", false)))
	check_eq("the split kept the hit segment's id as the HEAD",
		str(res.get("head_segment_id", "")), id_a)
	check("a NEW segment id was minted for the tail",
		str(res.get("tail_segment_id", "")) != id_a and not str(res.get("tail_segment_id", "")).is_empty())
	check_eq("exactly one segment was added", (cand.segments as Array).size(), segs_before + 1)
	check_eq("exactly one via was added", (cand.vias as Array).size(), 2)

	# ── THE GATE ASSERTION ────────────────────────────────────────────────────
	var untouched: Array = res.get("untouched_segment_ids", [])
	check_eq("exactly one segment was outside the edited path", untouched.size(), 1)
	check("the DISCONNECTED path B is the one named untouched", id_c in untouched)
	var c_after: Dictionary = {}
	for seg in cand.segments:
		if seg is Dictionary and str((seg as Dictionary).get("id", "")) == id_c:
			c_after = seg
	check("path B still exists under its own id", not c_after.is_empty())
	check_eq("path B's LAYER is unchanged", str(c_after.get("layer", "")), c_layer_before)
	check_eq("path B's point count is unchanged",
		(c_after.get("points", []) as Array).size(), c_points_before.size())
	check("path B's first point is unchanged",
		(c_after.get("points", []) as Array)[0] == c_points_before[0])
	check("path B's last point is unchanged",
		(c_after.get("points", []) as Array)[1] == c_points_before[1])

	# ── the layer-run flip STOPS at an existing layer change ──────────────────
	# The tail flips to bottom. Path A's OTHER leg is ALREADY bottom, so the walk
	# must not traverse it (and must not flip it back). Flat concatenation would
	# have re-layered everything after the split point, which is the exact
	# router hazard INV-3 names.
	var relayered: Array = res.get("relayered_segment_ids", [])
	check_eq("exactly ONE segment was re-layered (the tail)", relayered.size(), 1)
	check_eq("it is the tail", str(relayered[0]), str(res.get("tail_segment_id", "")))
	for seg in cand.segments:
		if seg is Dictionary and str((seg as Dictionary).get("id", "")) == id_b:
			check_eq("the already-bottom leg is still bottom",
				str((seg as Dictionary).get("layer", "")), "bottom")

	# The split is exact: head ends where the tail begins, at the via.
	var head_pts: Array = []
	var tail_pts: Array = []
	for seg in cand.segments:
		if not (seg is Dictionary):
			continue
		if str((seg as Dictionary).get("id", "")) == id_a:
			head_pts = (seg as Dictionary).get("points", [])
		elif str((seg as Dictionary).get("id", "")) == str(res.get("tail_segment_id", "")):
			tail_pts = (seg as Dictionary).get("points", [])
	check_eq("head runs (0,0)->(2.5,0)", head_pts.size(), 2)
	check("head ends at the split point", head_pts[1] == Vector2(2.5, 0.0))
	check("tail begins at the split point", tail_pts[0] == Vector2(2.5, 0.0))
	check("tail ends where the original did", tail_pts[1] == Vector2(5.0, 0.0))
	check_eq("the reported via position is the split point",
		float((res.get("at", [0.0, 0.0]) as Array)[0]), 2.5)


# ══ 7. INV-3: degenerate inserts are NAMED refusals, never nudged ════════════

func _run_inv3_degenerate_refusals() -> void:
	print("-- 7. INV-3: degenerate/illegal via inserts are named no-ops --")
	var ctx := _model_context()
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var cand = ws.get_candidate(cid)
	var segs_before: int = (cand.segments as Array).size()
	var vias_before: int = (cand.vias as Array).size()
	var rev_before: int = int(cand.candidate_revision)

	# (a) ON A VERTEX — splitting there yields zero-length copper.
	var v: Dictionary = ws.add_via(cid, Vector2(0.0, 0.0), "top", "bottom")
	check("an insert on a segment vertex is refused", not bool(v.get("ok", true)))
	check_eq("named degenerate_insert_at_endpoint",
		str(v.get("error", "")), PcbWorkspace.ERR_DEGENERATE_AT_ENDPOINT)

	# (b) ON AN EXISTING VIA — two holes at one point. Checked BEFORE the segment
	#     hit, because "there is already a via here" is a different mistake from
	#     "nothing is here".
	var v2: Dictionary = ws.add_via(cid, Vector2(5.0, 0.0), "top", "bottom")
	check("an insert on an existing via is refused", not bool(v2.get("ok", true)))
	check_eq("named degenerate_insert_on_via",
		str(v2.get("error", "")), PcbWorkspace.ERR_DEGENERATE_ON_VIA)

	# (c) EMPTY BOARD — no segment under the point.
	var v3: Dictionary = ws.add_via(cid, Vector2(100.0, 100.0), "top", "bottom")
	check("an insert on empty board is refused", not bool(v3.get("ok", true)))
	check_eq("named no_segment_at_point",
		str(v3.get("error", "")), PcbWorkspace.ERR_NO_SEGMENT_AT_POINT)

	# (d) ILLEGAL SPAN — a via that goes nowhere.
	var v4: Dictionary = ws.add_via(cid, Vector2(2.5, 0.0), "top", "top")
	check("a same-layer span is refused", not bool(v4.get("ok", true)))
	check_eq("named illegal_via_span",
		str(v4.get("error", "")), PcbWorkspace.ERR_ILLEGAL_VIA_SPAN)

	# EVERY refusal is a NO-OP: nothing split, nothing added, no revision bump —
	# and in particular nothing was NUDGED to a nearby legal point, which would
	# be copper the user never asked for.
	check_eq("no segment was split by any refusal", (cand.segments as Array).size(), segs_before)
	check_eq("no via was added by any refusal", (cand.vias as Array).size(), vias_before)
	check_eq("candidate_revision did not move", int(cand.candidate_revision), rev_before)
	check_eq("validation did not move", str(cand.validation), "unchecked")

	# (e) NEAR — not on — the via's CENTRE. (4.9, 0) is 0.1mm from the via at
	#     (5,0) and squarely ON seg_1's copper. The via's claim is its own disc,
	#     0.8mm diameter => 0.4mm radius, so this is a click on the VIA. Matching
	#     the centre exactly (1e-4mm) instead would fall through to the segment
	#     and stack a second hole a tenth of a millimetre from the first.
	var v6: Dictionary = ws.add_via(cid, Vector2(4.9, 0.0), "top", "bottom")
	check("a click inside the via's disc is refused", not bool(v6.get("ok", true)))
	check_eq("named degenerate_insert_on_via",
		str(v6.get("error", "")), PcbWorkspace.ERR_DEGENERATE_ON_VIA)
	check("the refusal reports the claim radius it used",
		str(v6.get("message", "")).contains("0.400"))
	# ...and 1.0mm away, clear of both the disc and the segment's own tolerance,
	# is a plain miss. Two different answers about the same via prove the claim
	# is a radius and not "anywhere near".
	check_eq("clear of the disc AND the copper is a plain miss",
		str(ws.add_via(cid, Vector2(6.0, 0.0), "top", "bottom").get("error", "")),
		PcbWorkspace.ERR_NO_SEGMENT_AT_POINT)

	# (f) from_layer MUST BE THE LAYER THE COPPER IS ON. (5, 2.5) lies on seg_2,
	#     which the fixture puts on BOTTOM. Asking to leave "top" there is a
	#     caller error, and correcting it silently would RE-LAYER the head of the
	#     run — moving copper the user never touched.
	var v7: Dictionary = ws.add_via(cid, Vector2(5.0, 2.5), "top", "bottom")
	check("a from_layer that disagrees with the copper is refused",
		not bool(v7.get("ok", true)))
	check_eq("named from_layer_mismatch",
		str(v7.get("error", "")), PcbWorkspace.ERR_LAYER_MISMATCH)
	check("the refusal names both layers",
		str(v7.get("message", "")).contains("bottom") and str(v7.get("message", "")).contains("top"))
	check_eq("nothing was split by the mismatch", (cand.segments as Array).size(), segs_before)
	# The SAME point with the RIGHT from_layer is legal — proving the refusal is
	# about the layer and not about the point.
	var v8: Dictionary = ws.add_via(cid, Vector2(5.0, 2.5), "bottom", "top")
	check("the same point with the correct from_layer is accepted", bool(v8.get("ok", false)))
	check_eq("and it split seg_2, not seg_1",
		str(v8.get("head_segment_id", "")), str((cand.segments[1] as Dictionary).get("id", "")))

	# (g) A TERMINAL candidate is a record, not an editing surface.
	check("reject it", ws.reject(cid))
	var v5: Dictionary = ws.add_via(cid, Vector2(2.5, 0.0), "top", "bottom")
	check("editing a rejected candidate is refused", not bool(v5.get("ok", true)))
	check_eq("named candidate_not_editable",
		str(v5.get("error", "")), PcbWorkspace.ERR_NOT_EDITABLE)


# ══ 8. ERASER ADJUDICATION + the canvas VERB MENU ════════════════════════════

func _on_canvas_message(text: String) -> void:
	_messages.append(text)


## The context-menu labels currently on offer for `candidate_id`, and whether
## each is disabled. Rebuilds the seam rather than reading a cached menu, which
## is what the real right-click does.
func _menu_state(canvas, candidate_id: String) -> Array:
	canvas.context_menu.clear()
	canvas._add_candidate_menu_seam(candidate_id)
	var labels: Array = []
	var disabled: Array = []
	for i in range(canvas.context_menu.item_count):
		labels.append(canvas.context_menu.get_item_text(i))
		disabled.append(canvas.context_menu.is_item_disabled(i))
	return [labels, disabled]


func _run_eraser_adjudication() -> void:
	print("-- 8. eraser on a ghost: NOT a reject, NOT silent; and the verb menu --")
	# MOUNTED: this group drives a real canvas, which only exists once the panel
	# is in the tree and has run its own mount (see _panel_context).
	var ctx: Dictionary = await _panel_context(true)
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var canvas = ctx["panel"]._canvas
	check("the mounted panel built a canvas", canvas != null)
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var cid := str(((out.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))

	# The candidate surface must be LIVE for the eraser to be able to resolve a
	# ghost at all — with the cutover flag off, _entity_at never returns one.
	ctx["panel"].get_routing_cutover().set_workspace_authoritative("canvas", true)
	canvas.set_routing_workspace(ws, ctx["panel"].get_routing_cutover())
	_messages.clear()
	canvas.trace_tool_message.connect(_on_canvas_message)

	var traces_before: int = int(ctx["data"].traces.size())
	# (0,0) is the start of path A's top leg — on the ghost's own ink.
	canvas._handle_eraser_click(Vector2(0.0, 0.0))

	# HALF ONE — it did NOT reject. The disposition is untouched, the task is
	# still open, and no un-undoable workflow decision was taken by a tool whose
	# whole grammar is Ctrl+Z.
	check_eq("the eraser did NOT reject the candidate",
		str(ws.get_candidate(cid).disposition), "proposed")
	check("the candidate is still live", cid in ws.live_candidate_ids())
	check_eq("the eraser wrote no copper", int(ctx["data"].traces.size()), traces_before)

	# HALF TWO — it did NOT refuse silently, which is the defect the chore names.
	check_eq("exactly one notice was emitted", _messages.size(), 1)
	if _messages.size() == 1:
		var msg := str(_messages[0])
		check("the notice names the candidate", msg.contains(cid))
		check("the notice names the verb that DOES discard it", msg.contains("Reject"))
		check("the notice says why the eraser will not", msg.to_lower().contains("draft"))

	# ── THE VERB MENU: the human's doorway onto the same workspace verbs ───────
	# INDEX MAP (hand-derived, and the reason it is spelled out): 0 = the
	# disabled identity line, 1 = the SEPARATOR _context_menu_separate() inserts,
	# 2..5 = the four verbs. A separator IS an item in a PopupMenu's item_count,
	# so an index map that forgot it would read Commit's state off the separator.
	var state: Array = _menu_state(canvas, cid)
	var labels: Array = state[0]
	var disabled: Array = state[1]
	check_eq("the seam offers identity + separator + four verbs", labels.size(), 6)
	check("the identity line is disabled (it is a label, not an action)", bool(disabled[0]))
	check_eq("index 1 is the separator (empty text)", str(labels[1]), "")
	check_eq("verb 1 is Commit", str(labels[2]), "Commit")
	check_eq("verb 2 is Pin (the slot shows the move that is available)", str(labels[3]), "Pin")
	check_eq("verb 3 is Reject", str(labels[4]), "Reject")
	check_eq("verb 4 is Try again", str(labels[5]), "Try again")
	check("every verb is ENABLED for a proposed candidate",
		not bool(disabled[2]) and not bool(disabled[3]) and not bool(disabled[4]) and not bool(disabled[5]))

	# PIN through the menu handler — the same path a real click takes, including
	# the frozen press target.
	canvas._context_menu_target = [canvas.KIND_CANDIDATE, cid]
	_messages.clear()
	canvas._on_context_menu_pressed(canvas.MENU_ID_CANDIDATE_PIN)
	check_eq("the menu's Pin moved the disposition",
		str(ws.get_candidate(cid).disposition), "pinned")
	check_eq("it reported the outcome on the status line", _messages.size(), 1)
	check("the outcome names the act", str(_messages[0]).contains("Pinned"))
	check_eq("the pinned slot now offers Unpin", str((_menu_state(canvas, cid)[0] as Array)[3]), "Unpin")

	# COMMIT through the menu handler — the one verb that touches copper, and it
	# goes through the workspace's transaction, not through any board path here.
	_messages.clear()
	canvas._on_context_menu_pressed(canvas.MENU_ID_CANDIDATE_COMMIT)
	check_eq("the menu's Commit wrote one trace per segment",
		int(ctx["data"].traces.size()), traces_before + 3)
	check_eq("it wrote the via", int(ctx["data"].vias.size()), 1)
	check_eq("the candidate is committed", str(ws.get_candidate(cid).disposition), "committed")
	check_eq("it reported the outcome", _messages.size(), 1)
	check("the outcome names the act", str(_messages[0]).contains("Committed"))

	# A COMMITTED candidate is terminal for every workflow verb, and the menu says
	# so BEFORE the click rather than refusing after it.
	#
	# COMMIT IS THE ONE THAT NEEDS ASSERTING. The legality table calls an IDENTITY
	# move legal, so can_transition(id, "committed") is TRUE for an already-
	# committed candidate — an item gated on that alone would stay live and lay a
	# SECOND set of copper for one candidate. Both guards are checked: the menu
	# greys it, and the workspace refuses it by name if anything else calls in.
	var after: Array = _menu_state(canvas, cid)
	var after_disabled: Array = after[1]
	check("Commit is disabled on a committed candidate (the identity-move trap)",
		bool(after_disabled[2]))
	check("Pin is disabled on a committed candidate", bool(after_disabled[3]))
	check("Reject is disabled on a committed candidate", bool(after_disabled[4]))
	check("Try again is disabled on a committed candidate", bool(after_disabled[5]))

	var traces_at_commit: int = int(ctx["data"].traces.size())
	var recommit: Dictionary = ws.commit(cid, ctx["data"])
	check("a second commit is REFUSED", not bool(recommit.get("ok", true)))
	check_eq("named already_committed",
		str(recommit.get("error", "")), PcbWorkspace.ERR_ALREADY_COMMITTED)
	check_eq("and it wrote no second set of copper",
		int(ctx["data"].traces.size()), traces_at_commit)

	canvas.trace_tool_message.disconnect(_on_canvas_message)
	ctx["driver"].free_panel(ctx["panel"])


# ══ 9. CHECK: a stale candidate refuses, with both exits named ═══════════════

func _run_check_stale_gate() -> void:
	print("-- 9. workspace_check refuses a stale candidate and names both exits --")
	var ws = PcbWorkspace.new()
	var data = PcbData.new()
	var cid := str(ws.ingest_record(_multipad_record(), int(data.board_revision)))

	# Move the board on. rebase() is what the tool runs first, and it is what
	# makes the gate mean anything — before it, nothing threads the live board
	# revision into the workspace at all.
	data.save_to_history("an unrelated edit")
	data.begin_batch()
	var t = data.new_trace()
	t.net_name = "OTHER"
	t.layer = "top"
	t.width = 0.3
	t.waypoints.append(Vector2(80, 80))
	t.waypoints.append(Vector2(90, 80))
	data.add_trace(t)
	data.end_batch("an unrelated edit")
	check("the board revision advanced", int(data.board_revision) > 0)

	var marked: Array = ws.rebase(int(data.board_revision))
	check_eq("rebase staled the candidate generated against the older board",
		marked.size(), 1)
	check_eq("its validation is stale", str(ws.get_candidate(cid).validation), "stale")
	check_eq("its DISPOSITION was preserved (the axes are orthogonal)",
		str(ws.get_candidate(cid).disposition), "proposed")

	# The tool-level gate is asserted through the workspace state the tool reads,
	# because the draft-check hop itself needs the worker (not available here);
	# the no-reply path is what a scaffold run exercises, and it must revert
	# rather than leave a candidate stuck on "checking".
	var request: Dictionary = ws.begin_check([cid])
	check_eq("begin_check flipped it to checking",
		str(ws.get_candidate(cid).validation), "checking")
	check_eq("the request carries the candidate", (request.get("candidates", []) as Array).size(), 1)
	ws.apply_check_result({})
	check_eq("an empty reply reverted it to STALE, never to clean",
		str(ws.get_candidate(cid).validation), "stale")

	# ── THE TOOL-LEVEL ENVELOPE ───────────────────────────────────────────────
	# The model half above proves the STATE; this half proves what the AGENT is
	# actually handed, which is a different artefact and the one a caller
	# branches on. Runs on a real panel because _workspace_check resolves its
	# workspace and board through the host — and it never reaches the worker hop
	# on this path, because the stale gate refuses first.
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var tws = ctx["ws"]
	var tdata = ctx["data"]
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var tcid := str(((out.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))

	# A check with the board exactly where the candidate was generated is NOT
	# refused — the gate must fire on staleness, not on being a check.
	var fresh: Dictionary = await PanelTools._workspace_check(shim, _args())
	check("a check on a fresh candidate is not refused as stale",
		str(fresh.get("error", "")) != "stale_candidates")

	# Move the board on, then ask again.
	tdata.begin_batch()
	var t2 = tdata.new_trace()
	t2.net_name = "OTHER"
	t2.layer = "top"
	t2.width = 0.3
	t2.waypoints.append(Vector2(80, 80))
	t2.waypoints.append(Vector2(90, 80))
	tdata.add_trace(t2)
	tdata.end_batch("an unrelated edit")

	var refused: Dictionary = await PanelTools._workspace_check(shim, _args())
	check("the tool REFUSED", not bool(refused.get("success", true)))
	check_eq("the envelope is NAMED stale_candidates",
		str(refused.get("error", "")), "stale_candidates")
	check("it names WHICH candidates are stale",
		tcid in (refused.get("stale_candidate_ids", []) as Array))
	check("it separates the ones IT just staled by rebasing",
		tcid in (refused.get("newly_stale_candidate_ids", []) as Array))
	check_eq("it reports the board revision the gate was measured against",
		int(refused.get("board_revision", -1)), int(tdata.board_revision))
	var note := str(refused.get("note", ""))
	check("the note names exit 1 (fresh geometry)",
		note.to_lower().contains("re-propose") or note.to_lower().contains("reroute"))
	check("the note names exit 2 (include_stale)", note.contains("include_stale"))
	check_eq("no verdict was written by a refused check",
		str(tws.get_candidate(tcid).validation), "stale")

	# EXIT 2, taken: the gate lets it through, and the run then fails on the
	# worker hop the scaffold does not have — which must ALSO be a named
	# envelope, and must leave the candidate stale rather than stuck on
	# "checking" or, worse, clean.
	var forced: Dictionary = await PanelTools._workspace_check(shim, _args({"include_stale": true}))
	check("include_stale got past the gate",
		str(forced.get("error", "")) != "stale_candidates")
	check_eq("and the missing worker is its own named envelope",
		str(forced.get("error", "")), "draft_check_no_reply")
	check_eq("the candidate is still stale, never clean, never stuck checking",
		str(tws.get_candidate(tcid).validation), "stale")

	ctx["driver"].free_panel(ctx["panel"])


# ══ 10. S5 REMOVAL CONTRACT (C4b, DCR 019f7095c395) ═══════════════════════════
#
# PARKED APPEND (C4b): the proposal-as-annotation machinery C4a's own comment
# marked "retired by S5" is actually gone by the time this group runs — the
# two per-proposal MCP tools are absent from the manifest and unreachable
# through the dispatcher, the plugin no longer exposes the duck-typed
# Accept/Reject verb pair core's WorkflowAnnotationList checks for (nor the
# is_annotation_superseded hook that hid an answered hint behind its
# proposal), and a pre-cutover .pcbskel's leftover proposal annotations are
# DROPPED at load time with a visible, counted notice — never silently
# ignored, never silently re-materialized into workspace candidates (see the
# C4b report's decider package for why an importer was rejected: a pre-U2
# proposal is waypoint-flattened, and an importer built against that shape
# would mint a WRONG single-layer, via-less candidate).
func _run_removal_contract() -> void:
	print("\n-- 10. S5 removal contract (C4b) --")
	await _run_removal_manifest_tools_absent()
	_run_removal_no_accept_reject_verbs()
	_run_removal_legacy_load_notice()
	await _run_removal_no_drc_via_mcp_annotations()


## (a) proposal tools absent from the manifest AND unreachable through the
## dispatcher (handle() returns {} for an unrecognised tool_name — the
## PluginToolRegistry contract that maps to tool_unhandled).
func _run_removal_manifest_tools_absent() -> void:
	var manifest_text := FileAccess.get_file_as_string("res://../../minerva-plugins/pcb/manifest.json")
	check("manifest.json readable", not manifest_text.is_empty())
	var parsed: Variant = JSON.parse_string(manifest_text)
	check("manifest.json parses", parsed is Dictionary)
	if not (parsed is Dictionary):
		return
	var names: Array = []
	for t in (parsed as Dictionary).get("tools", []):
		if t is Dictionary:
			names.append(str((t as Dictionary).get("name", "")))
	check("minerva_pcb_proposal_accept absent from manifest", not ("minerva_pcb_proposal_accept" in names))
	check("minerva_pcb_proposal_reject absent from manifest", not ("minerva_pcb_proposal_reject" in names))
	check_eq("manifest tool count == 68 (70 - the 2 S5-removed proposal tools)",
		names.size(), 68)

	# Unreachable through the dispatcher too, not just missing from the list —
	# a bare host with no panel is enough: handle() matches on tool_name alone
	# before it ever touches the host.
	var host = load(ANNOTATION_HOST_SCRIPT_PATH).new()
	var accept_reply: Dictionary = await PanelTools.handle(host, "minerva_pcb_proposal_accept", {"id": "x"})
	check("dispatch: proposal_accept unhandled (empty dict, got %s)" % str(accept_reply), accept_reply.is_empty())
	var reject_reply: Dictionary = await PanelTools.handle(host, "minerva_pcb_proposal_reject", {"id": "x"})
	check("dispatch: proposal_reject unhandled (empty dict, got %s)" % str(reject_reply), reject_reply.is_empty())


## (b) hint annotations carry no Accept/Reject verbs. The plugin-side
## duck-typed methods core's WorkflowAnnotationList checks for
## (accept_annotation_proposal / reject_annotation_proposal, has_method-gated)
## are gone from PcbAnnotationHost, so no pcb annotation — hint or (formerly)
## proposal — can ever grow the buttons regardless of author.kind (DCR
## finding 4: an agent-authored SOURCE hint is intent/commentary, not a
## proposal, and must not either). is_annotation_superseded — the sibling hook
## that hid a hint behind its live proposal — is gone with it: nothing
## supersedes a hint anymore.
func _run_removal_no_accept_reject_verbs() -> void:
	var host = load(ANNOTATION_HOST_SCRIPT_PATH).new()
	check("host has no accept_annotation_proposal", not host.has_method("accept_annotation_proposal"))
	check("host has no reject_annotation_proposal", not host.has_method("reject_annotation_proposal"))
	check("host has no is_annotation_superseded", not host.has_method("is_annotation_superseded"))


## (c) legacy-proposal load produces the notice + drops cleanly. Seeds a
## sidecar (via a first panel) carrying one AI-authored proposal annotation in
## the pre-S5 shape (kind_payload.proposal_for) alongside its still-open
## source hint, then loads that same file into a FRESH panel and asserts: the
## proposal is gone, the drop count is exact, the source hint (never named by
## the drop — only the proposal_for-carrying annotation itself is removed) is
## untouched, and the status label carries the notice.
func _run_removal_legacy_load_notice() -> void:
	var driver = DRIVER.new()
	var board_dir: String = driver.make_temp_board_dir("c4b_legacy_proposal_drop")
	var board_path := board_dir + "/legacy.pcbskel"
	driver.cleanup_sidecar(board_path)

	var seed_panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var seed_host = seed_panel.get_annotation_host()
	seed_host.set_document_path(board_path)
	var seed_data = seed_panel.get_data()
	seed_data.board_width = 40.0
	seed_data.board_height = 30.0

	# The still-open source hint the (soon-legacy) proposal answers.
	var hint_env: Dictionary = seed_host.build_route_hint_envelope(
		1.0, 1.0, "", "F.Cu", "waypoint", [], "human")
	var hint_id := str(seed_host.add_annotation_v2(hint_env))
	check("seed: source hint added", not hint_id.is_empty())

	# A pre-S5-shaped AI proposal answering it — the exact envelope shape the
	# now-retired panel_tools.gd _write_one_proposal used to author (hand-built
	# here since that helper no longer exists).
	var prop_env: Dictionary = seed_host.build_route_hint_envelope(
		1.0, 1.0, "", "F.Cu", "single_trace", [[1.0, 1.0], [5.0, 1.0]], "ai")
	var pkp: Dictionary = prop_env.get("kind_payload", {})
	pkp["net_names"] = ["N1"]
	pkp["proposal_for"] = [hint_id]
	prop_env["kind_payload"] = pkp
	var proposal_id := str(seed_host.add_annotation_v2(prop_env))
	check("seed: legacy proposal added", not proposal_id.is_empty())
	check_eq("seed: exactly 2 annotations before save", seed_host.get_annotations().size(), 2)

	var save_err: int = seed_host.save_sidecar(board_path)
	check_eq("seed: sidecar saved", save_err, OK)
	driver.free_panel(seed_panel)

	# Fresh panel, fresh load — the actual load-time drop path under test.
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	driver.drive_load_merged(panel, board_path, {"width_mm": 40.0, "height_mm": 30.0, "name": "Legacy"})

	check_eq("drop: exactly 1 legacy proposal dropped", panel.get_last_legacy_proposals_dropped(), 1)
	var host = panel.get_annotation_host()
	check("drop: proposal annotation gone", host.get_by_id(proposal_id).is_empty())
	check("drop: source hint UNTOUCHED (drop never names the hints it answered)",
		not host.get_by_id(hint_id).is_empty())
	check_eq("drop: exactly 1 annotation remains (the hint)", host.get_annotations().size(), 1)
	check("drop: status label carries the notice (got '%s')" % panel._status_label.text,
		panel._status_label.text.find("legacy route proposal") != -1)

	driver.free_panel(panel)
	driver.cleanup_sidecar(board_path)
	driver.cleanup_board_file(board_path)


## (d) MF-1 (narrow re-review, 2026-08-02): the MCP annotations_list negative
## proof — "no annotation carries kind_payload.drc post-S5" — moved here from
## test_pcb_drc_propose.gd, where it sat behind a structurally unreachable
## _used_real_worker gate (docket 019fc22284537bdfa9861c159bad76b1,
## "Workerless e2e rig defects" — two independent rig bugs, filed not fixed,
## keep that suite's real-worker branch dead in every environment). This
## group drives propose through _propose_into_workspace DIRECTLY with a
## hand-built reply carrying a per-route `drc` verdict (the exact shape
## pcb_worker.methods._attach_route_drc produces) — no RouterShim/run_router
## indirection needed, since _propose_into_workspace takes the router `result`
## as a plain argument — so it actually executes once this file is promoted
## to tests/gd/ at the epoch boundary, unlike the suite it was moved out of.
func _run_removal_no_drc_via_mcp_annotations() -> void:
	print("-- 10d. MF-1: no annotation carries kind_payload.drc post-S5 (moved from drc_propose) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var data = ctx["data"]
	var hint_id: String = ctx["hint_id"]

	var reply := {
		"routes": [{
			"net": "N1",
			"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
			"drc": {"scope": "connectivity", "clean": false, "violation_count": 1,
				"violations": [{"type": "clearance"}]},
		}],
		"via_count": 0,
		"drc_summary": {"scope": "connectivity", "clean": false, "violation_count": 1},
	}
	var source_hints: Array = [{
		"id": hint_id,
		"kind_payload": {"net_names": ["N1"], "width_mm": 0.3,
			"source_pins": ["U1.3"], "dest_pins": ["U2.7"]},
	}]

	var out: Dictionary = PanelTools._propose_into_workspace(host, data, reply, source_hints)
	check("propose ok", bool(out.get("success", false)))
	check("propose landed a candidate carrying its own drc verdict",
		((out.get("proposals", []) as Array)[0] as Dictionary).get("drc", {}).get("clean", true) == false)

	# MCPAnnotationTools._annotations_list resolves its host via
	# AnnotationHostRegistry (editor_name -> host) — none of the OTHER groups
	# in this file need it (they call PanelTools/model functions directly),
	# so register/reset locally rather than widen _panel_context for one group.
	const _EDITOR_NAME := "MF1RemovalProbe"
	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(_EDITOR_NAME, host)
	var ann_tools = MCPAnnotationTools.new(null)
	var list_result: Dictionary = ann_tools._annotations_list({"editor_name": _EDITOR_NAME})
	var any_drc_via_mcp := false
	for a in (list_result.get("annotations", []) as Array):
		if a is Dictionary and (a as Dictionary).get("kind_payload", {}).has("drc"):
			any_drc_via_mcp = true
	check("no annotation carries kind_payload.drc post-S5 (nothing left to carry it)",
		not any_drc_via_mcp)
	AnnotationHostRegistry._reset_for_test()

	ctx["driver"].free_panel(ctx["panel"])
