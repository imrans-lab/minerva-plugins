extends SceneTree
## Single-trace author tool E2E-3/E2E-4 (WC-3, docket 019f6a894a37).
##
## Run: godot --headless --path . --script test/test_pcb_single_trace_tool.gd
## (run from the Minerva worktree's src/ directory; also runnable WITHOUT
## --headless under xvfb-run for the windowed pixel-probe branch of A1 — see
## _test_e2e3_a_human_hints_it).
##
## E2E-3 "human hints it, agent routes it" (two-pin test board, one net, no
## traces): A) simulate human with the single-trace tool: click pin 1 pad →
## click pin 2 pad → hint commits and DRAWS. B) agent sees it via MCP
## (annotations_list/query). C) agent acts: apply_route_hints → workspace
## candidate (S5, C4b, DCR 019f7095c395 — was a cyan proposal annotation
## before this round) → commit → REAL trace connecting pin1-pin2. D) serialize
## → trace in saved YAML/board dict; reload → trace and hint state intact.
##
## E2E-4 "human changes their mind" (same board): A) start, add a waypoint,
## right-click cancel → nothing persisted. B) start again, click the source
## pad as destination → self-reference cancel → nothing persisted. C) author
## a real hint, clear-by-author(human) → gone from canvas/MCP/sidecar; a
## pre-seeded AI proposal SURVIVES the human-clear.
##
## REUSE SCAN: mount/fixture/input conventions copied verbatim from
## test_pcb_workflow_kinds.gd (real PCBPanel boot headless, real input via
## get_root().push_input(), MCP via panel.handle_tool()). The apply/
## materialize call sequence for E2E-3C is copied from test_pcb_apply_
## route_hints.gd (_gather_route_hints / _write_back_proposals /
## _materialize_routes), with the canned RoutingResult REPLACED by a call to
## the REAL pcb-plugin Go binary + real Python pcb_worker over stdio (see
## _real_route_result / pcb/scripts/e2e_route_stdio.py) — falls back to a
## documented canned result ONLY if the binary genuinely isn't built at
## <minerva-plugins>/pcb/pcb-plugin (contract-allowed fallback), and always
## reports which path ran.
##
## S5 (C4b, DCR 019f7095c395): PANEL_TOOLS._write_back_proposals — referenced
## in the two REUSE SCAN paragraphs below by name for history — is RETIRED;
## E2E-3C now calls _propose_into_workspace, which lands a RouteCandidate
## instead of a proposal annotation.
##
## C3 migration (docket 019f6c4604ba, wave 2 + core deletion): the core
## module MCPPcbPanelTools.gd this suite used to construct directly
## (`pcb_tools = PCB_MODULE.new(null)`) is DELETED. Its wave-2 tool bodies
## and the whole route-workflow helper cluster moved VERBATIM to
## pcb/ui/panel_tools.gd (PANEL_TOOLS, static funcs) — internal-helper call
## sites (_gather_route_hints / _write_back_proposals / _materialize_routes)
## now call PANEL_TOOLS.<name>(...) directly (mechanical edit, receiver only).
## Tool-surface calls (get_image, apply_route_hints) now go through
## panel.handle_tool(tool_name, args) — PCBPanel's plugin-side entry point,
## the same one PluginToolRegistry forwards to in production — and are
## AWAITED unconditionally: apply_route_hints awaits the router bridge,
## which makes panel_tools.gd's handle() (and therefore PCBPanel.handle_tool)
## a coroutine end to end (Godot 4.6 static-typing landmine — see
## panel_tools.gd's class doc).

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const ANN_MODULE := preload("res://Scripts/Services/MCP/Modules/MCPAnnotationTools.gd")
const PANEL_TOOLS := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const DRIVER := preload("res://test/helpers/plugin_panel_driver.gd")
const _WorkflowListScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/WorkflowAnnotationList.gd")

const EDITOR_NAME := "SingleTraceProbe"
const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"

var _pass := 0
var _fail := 0
var _used_real_worker := false
# Latched by any seam fallback: once ONE real-worker call has fallen back,
# a later successful call must not flip the report back to true — the run
# as a whole did not prove the real worker end to end (bug 019ff2b1fccb).
var _worker_fell_back := false

var panel = null
var canvas = null
var host = null
var data = null
var driver = null

var overlay: AnnotationOverlay = null
var ann_tools = null

const U1_PIN1 := Vector2(15.0, 20.0)
const U2_PIN1 := Vector2(55.0, 20.0)
const WAYPOINT_AT := Vector2(35.0, 10.0)
const EMPTY_DEST_AT := Vector2(35.0, 30.0)


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB Single-Trace Tool E2E-3 / E2E-4 ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	await _test_e2e3_a_human_hints_it()
	await _test_e2e3_b_agent_sees_it()
	await _test_e2e3_c_agent_routes_it()
	await _test_e2e3_d_serialize_reload()

	await _test_mutual_exclusion_across_surfaces()
	await _test_e2e4_a_cancel_mid_draw()
	await _test_e2e4_b_self_reference_cancel()
	await _test_e2e4_c_clear_by_author()

	await _test_apply_tool_full_mcp_broker_path()

	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [_pass, _fail, str(_used_real_worker)])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture (test_pcb_workflow_kinds.gd conventions) ─────────────────

func _mount() -> bool:
	driver = DRIVER.new()
	panel = load(PANEL_PATH).new()
	if panel == null:
		return false
	get_root().add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size = Vector2(900, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})

	host = panel.get_annotation_host()
	data = panel.get_data()
	if host == null or data == null:
		return false

	_build_fixture_board(data)

	for _i in range(4):
		await process_frame

	canvas = panel._canvas
	if canvas == null:
		return false

	# Deterministic view (same technique as test_pcb_workflow_kinds.gd — avoids
	# depending on zoom_to_fit's content-bbox heuristics / the documented
	# canvas_zoom_to_fit test race).
	canvas.zoom = 4.0
	canvas.pan_offset = -Vector2(data.board_width, data.board_height) / 2.0 * canvas.zoom
	canvas.queue_redraw()
	await process_frame

	# The REAL platform overlay, named exactly as Editor.gd mounts it, so the
	# panel's own _find_annotation_overlay() (route-flow cluster) locates it —
	# this test exercises the PRODUCTION lookup path, not a test-only stand-in.
	overlay = AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.get_annotation_overlay_parent().add_child(overlay)
	overlay.set_host(host)
	await process_frame

	ann_tools = ANN_MODULE.new(null)   # server=null — handle() is server-free.
	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR_NAME, host)
	return true


func _build_fixture_board(d) -> void:
	d.board_width = 70.0
	d.board_height = 40.0
	# Real design rules, authored (testex find, same class as drc_propose's
	# fixture note / docket 019fc22284537bdfa9861c159bad76b1 defect 2): the
	# worker's compile_board._build_design_rules fail-closed REFUSES a board
	# whose design_rules omit any of the four positive-number rules — the
	# real-worker path was unreachable with the default (unset) rules, and the
	# canned fallback silently ate the refusal until the OFC-1 gate made it
	# loud. 0.25 mm equals pcb_trace.DEFAULT_WIDTH_MM, so no width-dependent
	# assertion in this suite shifts.
	d.design_rules = {
		"trace_width_mm": 0.25,
		"clearance_mm": 0.2,
		"via_diameter_mm": 0.8,
		"via_drill_mm": 0.4,
	}

	var u1 = d.new_component()
	u1.id = "U1"
	u1.position = U1_PIN1
	u1.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u1)

	var u2 = d.new_component()
	u2.id = "U2"
	u2.position = U2_PIN1
	u2.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u2)

	d.connect_pin_to_net("SIG", "U1", "1")
	d.connect_pin_to_net("SIG", "U2", "1")


# ── input helpers (copied convention from test_pcb_workflow_kinds.gd) ────────

func _push_button(pos: Vector2, btn: int, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _world_to_root_screen(world_pos: Vector2) -> Vector2:
	return canvas.get_global_transform() * canvas.world_to_screen(world_pos)


func _click_world(world_pos: Vector2, btn: int = MOUSE_BUTTON_LEFT) -> void:
	var pt := _world_to_root_screen(world_pos)
	_push_button(pt, btn, true)
	await process_frame
	_push_button(pt, btn, false)
	await process_frame


func _press_escape() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	get_root().push_input(ev, true)
	await process_frame


# ── route-flow cluster button helpers (drives the REAL PCBPanel handler) ─────

func _press_trace_button() -> void:
	var btn: Button = panel._route_flow_buttons["single_trace"]
	btn.button_pressed = true
	panel._on_single_trace_button_pressed()
	await process_frame


func _release_trace_button() -> void:
	var btn: Button = panel._route_flow_buttons["single_trace"]
	btn.button_pressed = false
	panel._on_single_trace_button_pressed()
	await process_frame


func _active_tool():
	return panel._active_route_flow_tool


# ── E2E-3A: human hints it (toolbar + click flow + preview) ──────────────────

func _test_e2e3_a_human_hints_it() -> void:
	print("-- E2E-3 A: human draws a single-trace hint pin1 → pin2 --")

	check("A: no annotations before drawing", host.get_annotations().size() == 0)

	await _press_trace_button()
	check("A: Trace button toggled on", (panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	# RouteFlowModeLabel was deleted (owner HITL 2026-07-30, see PCBPanel.gd's
	# comment above _update_route_flow_mode_label): its idle "Select" text read
	# as a duplicate section header, so _route_flow_mode_label now stays null
	# permanently and every update site is a null-guarded no-op. The old
	# ".text == \"Single Trace\"" assertion here crashed on that null
	# ("Invalid access to property or key 'text' on a base object of type
	# 'Nil'"), which GDScript treats as a script error that skips the
	# statement rather than failing it — the assertion was silently dropped
	# from the tally, not counted as a FAIL. The pressed-button toggle above
	# and the active-tool check below are the CURRENT signals for "armed".
	check("A: mode label intentionally removed (null by design, not stale)",
		panel._route_flow_mode_label == null)
	check("A: overlay's active tool is our tool", overlay.has_active_tool() and _active_tool() != null)

	await _click_world(U1_PIN1)
	var tool = _active_tool()
	check("A: tool state is drawing after first click", tool != null and tool.current_state() == "drawing")
	var src: Dictionary = tool.source_info() if tool != null else {}
	check("A: source snapped to pad U1.1", str(src.get("type", "")) == "pad"
		and str(src.get("component", "")) == "U1" and str(src.get("pin", "")) == "1",
		"src=%s" % str(src))

	await _click_world(U2_PIN1)
	check("A: hint committed — host has 1 annotation", host.get_annotations().size() == 1,
		"count=%d" % host.get_annotations().size())

	var ann: Dictionary = host.get_annotations()[0] if host.get_annotations().size() == 1 else {}
	check("A: kind is pcb_route_hint", str(ann.get("kind", "")) == "pcb_route_hint")
	var kp: Dictionary = ann.get("kind_payload", {})
	# ── Epoch UX3 station 8a (docket 019fdf903a4a): a zero-interior-waypoint
	# pad→pad commit is now a TRUE INTENT — the gesture delegates to
	# minerva_pcb_add_route_intent, so the minted hint is the intent tool's
	# own object (hint_type "waypoint", no waypoints, pin provenance, an
	# EAGER RouteTask "NET|hint") rather than the old single_trace look-alike
	# with no task and no constraint slot. The old oracle here pinned the
	# look-alike; this is the parity contract replacing it.
	check("A: hint_type is waypoint (a TRUE intent, not the single_trace look-alike)",
		str(kp.get("hint_type", "")) == "waypoint", "kp=%s" % str(kp))
	check("A: source_pins == [U1.1]", (kp.get("source_pins", []) as Array) == ["U1.1"], "got %s" % str(kp.get("source_pins")))
	check("A: dest_pins == [U2.1]", (kp.get("dest_pins", []) as Array) == ["U2.1"], "got %s" % str(kp.get("dest_pins")))
	check("A: no interior waypoints (a bare connectivity intent)", (kp.get("waypoints", []) as Array).is_empty())
	check("A: layer defaults F.Cu", str(kp.get("layer", "")) == "F.Cu")
	# D9a-2 (unchanged by station 8): with the width picker at its 0 (auto)
	# default the gesture stamps NO width — any authored width_mm key would
	# silently overrule the board's design rule, and a 0.0 sentinel is not an
	# acceptable stand-in for "absent".
	check("A: no width_mm key stamped (picker at auto ⇒ board default)",
		not kp.has("width_mm"), "kp=%s" % str(kp))
	var author: Dictionary = ann.get("author", {})
	check("A: author kind human (the gesture's author pass-through — a human's act never mints an 'ai' hint)",
		str(author.get("kind", "")) == "human")
	var anchor: Dictionary = ann.get("anchor", {})
	# The intent tool anchors at the source pin's position as a board.point
	# (its existing shape, shared verbatim with the agent's calls).
	check("A: anchor is the intent tool's board.point at the source pin",
		str(anchor.get("type", "")) == "board.point", "anchor=%s" % str(anchor))
	check("A: an EAGER RouteTask exists for the intent (SIG|<hint_id>)",
		panel.get_routing_workspace().get_task("SIG|%s" % str(ann.get("id", ""))) != null)

	check("A: tool stays armed for continuous tracing (button still pressed)",
		(panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	check("A: tool internal state reset to idle post-commit", tool.current_state() == "idle")

	# Canvas state assertion ("DRAWS"): the hint is visible + hit-testable —
	# clicking its polyline midpoint (with the Select tool) selects it. Swap
	# in a Select tool the same way the dock would after deactivating Trace.
	#
	# R4/chore 019fb6632a4e: AnnotationSelectTool no longer exists in core —
	# owner-ratified chore 019fb59b34ee deleted it (and its 3 siblings)
	# outright after commit 38ea58cf ("promote AnnotationTransformTool as THE
	# select tool; press-drag selects and moves") folded click-to-select
	# semantics into AnnotationTransformTool ("OUTSIDE / no selection → select
	# semantics (hit-test annotations)" — see its own class doc). This left
	# the reference here a hard parse error (Identifier "AnnotationSelectTool"
	# not declared), failing the WHOLE script to load — not merely leaving
	# annotations empty. AnnotationTransformTool is the direct, currently
	# supported replacement; same on_activate(host)/on_deactivate() interface.
	await _release_trace_button()
	var select_tool := AnnotationTransformTool.new()
	select_tool.on_activate(host)
	overlay.set_active_tool(select_tool)
	await process_frame
	var midpoint: Vector2 = (U1_PIN1 + U2_PIN1) / 2.0
	await _click_world(midpoint)
	check("A: hint renders + hit-tests (click on its polyline selects it)",
		host.get_selected_annotation_id() == str(ann.get("id", "")),
		"selected='%s' expected='%s'" % [host.get_selected_annotation_id(), str(ann.get("id", ""))])
	host.set_selected_annotation_id("")
	select_tool.on_deactivate()
	overlay.clear_active_tool()

	# Pixel-probe branch: windowed (xvfb-run) gets a real image; a bare
	# --headless run must get the graceful null envelope (contract §1c).
	var img_result: Dictionary = await panel.handle_tool("minerva_pcb_get_image", {"editor_name": EDITOR_NAME})
	if DisplayServer.get_name() == "headless":
		check("A: pcb_get_image ok:true headless", bool(img_result.get("success", false)), str(img_result))
		check("A: pcb_get_image graceful null envelope headless",
			img_result.get("image_data", "SENTINEL") == null, str(img_result))
	else:
		check("A: pcb_get_image returns real pixels (windowed)",
			bool(img_result.get("success", false)) and img_result.get("image_data", null) != null
			and int(img_result.get("width", 0)) > 0 and int(img_result.get("height", 0)) > 0,
			str(img_result))


# ── E2E-3B: agent sees it via MCP ─────────────────────────────────────────────

func _test_e2e3_b_agent_sees_it() -> void:
	print("-- E2E-3 B: agent sees the hint via MCP annotations_list/query --")
	var listed: Dictionary = await ann_tools.handle("minerva_annotations_list", {"editor_name": EDITOR_NAME})
	check("B: annotations_list ok", bool(listed.get("ok", listed.get("success", false))), str(listed))
	check("B: annotations_list count == 1", int(listed.get("count", -1)) == 1, str(listed))

	var queried: Dictionary = await ann_tools.handle("minerva_annotations_query", {"editor_name": EDITOR_NAME})
	check("B: annotations_query ok", bool(queried.get("ok", false)), str(queried))
	var results: Array = queried.get("annotations", queried.get("results", []))
	check("B: annotations_query returns 1 entry", results.size() == 1, "got %s" % str(queried))
	if results.size() == 1:
		var ann: Dictionary = results[0]
		var kp: Dictionary = ann.get("kind_payload", {})
		check("B: MCP sees source_pins", (kp.get("source_pins", []) as Array) == ["U1.1"])
		check("B: MCP sees dest_pins", (kp.get("dest_pins", []) as Array) == ["U2.1"])
		# Station 8a (Codex 1056 finding 3c): the pad→pad gesture now mints a
		# TRUE intent, whose anchor is the intent tool's board.point at the
		# source pin — section A's oracle moved; this twin moves with it.
		check("B: MCP sees the intent tool's board.point anchor",
			str((ann.get("anchor", {}) as Dictionary).get("type", "")) == "board.point")


# ── E2E-3C: agent acts — propose → commit → REAL trace ───────────────────────

func _test_e2e3_c_agent_routes_it() -> void:
	print("-- E2E-3 C: agent routes it (propose → commit → real trace) --")
	check("C: no traces on the board yet", data.get_trace_count() == 0)

	var source_hints: Array = PANEL_TOOLS._gather_route_hints(host, [])
	check("C: gather finds the open source hint", source_hints.size() == 1, "size=%d" % source_hints.size())

	var result := await _route_result(source_hints)
	check("C: which routing path ran is reported", true,
		"real_worker=%s (binary at <minerva-plugins>/pcb/pcb-plugin)" % str(_used_real_worker))
	check("C: route result reports success", bool(result.get("success", false)), str(result))
	check("C: route result has a SIG route", _has_route_for_net(result, "SIG"), str(result))

	# PROPOSE (S5): lands a workspace candidate, board unmutated, no annotation.
	var propose_res: Dictionary = PANEL_TOOLS._propose_into_workspace(host, data, result, source_hints)
	check("C: propose ok", bool(propose_res.get("success", false)), str(propose_res))
	check("C: exactly one candidate landed", int(propose_res.get("proposed", 0)) == 1, str(propose_res))
	check("C: board still has 0 traces after propose", data.get_trace_count() == 0)
	check("C: no proposal annotation was written (S5)", _find_proposal().is_empty())

	var workspace = PANEL_TOOLS._get_workspace(host)
	var cand = _find_candidate(workspace, "SIG")
	check("C: candidate for SIG exists", cand != null)
	if cand != null:
		var expected_linked: Array = [str((source_hints[0] as Dictionary).get("id", ""))]
		check("C: candidate source_hint_ids is exactly [the SIG source hint id]",
			cand.source_hint_ids == expected_linked,
			"got=%s expected=%s" % [str(cand.source_hint_ids), str(expected_linked)])

	# COMMIT (materialize): REAL trace connecting pin1-pin2 along the hinted line.
	var commit_res: Dictionary = PANEL_TOOLS._materialize_routes(host, data, result, source_hints)
	check("C: materialize ok", bool(commit_res.get("success", false)), str(commit_res))
	check("C: one trace added", int(commit_res.get("traces_added", 0)) >= 1, str(commit_res))
	check("C: board now has a trace", data.get_trace_count() >= 1)

	var sig_traces: Array = data.get_traces_for_net("SIG")
	check("C: SIG trace exists", sig_traces.size() >= 1)
	if sig_traces.size() >= 1:
		var t = sig_traces[0]
		check("C: trace starts at U1.1", (t.get_start() as Vector2).is_equal_approx(U1_PIN1)
			or (t.get_end() as Vector2).is_equal_approx(U1_PIN1), "start=%s end=%s" % [str(t.get_start()), str(t.get_end())])
		check("C: trace reaches U2.1", (t.get_start() as Vector2).is_equal_approx(U2_PIN1)
			or (t.get_end() as Vector2).is_equal_approx(U2_PIN1), "start=%s end=%s" % [str(t.get_start()), str(t.get_end())])

	# Owner-ratified contract (HITL-2): an accepted hint is DELETED once its
	# real trace exists. commit=true here goes through _materialize_routes
	# DIRECTLY (unaffected by S5 — that branch never wrote an annotation), so
	# the consumed-hint deletion is unchanged; its removed_proposal_ids sweep
	# now finds nothing (S5: propose above wrote no proposal for it to find),
	# not because anything went wrong, but because there was never one to
	# remove — the workspace candidate propose landed is a SEPARATE store commit
	# never touches.
	# MF-2(b2) UNIFIED (narrow re-review, moved pin): "delete-on-commit" was
	# the LEGACY-era HITL-2 reading; the owner-visible contract is
	# open→applied, never delete — _materialize_routes now closes the same
	# way minerva_pcb_workspace_commit does.
	var consumed_ids: Array = commit_res.get("consumed_hint_ids", [])
	check("C: source hint consumed", consumed_ids.size() == 1)
	if consumed_ids.size() == 1:
		var consumed_ann: Dictionary = host.get_by_id(str(consumed_ids[0]))
		check("C: source hint SURVIVES commit (not deleted)", not consumed_ann.is_empty())
		check("C: source hint lifecycle closed: open -> applied",
			str(consumed_ann.get("lifecycle", "")) == "applied",
			"got '%s'" % str(consumed_ann.get("lifecycle", "")))
	var removed_props: Array = commit_res.get("removed_proposal_ids", [])
	check("C: no proposal to remove (S5: propose never wrote one)", removed_props.is_empty(), str(commit_res))
	for ann in host.get_annotations():
		var kp2: Dictionary = (ann as Dictionary).get("kind_payload", {})
		check("C: no proposal residue on the board", not (kp2 is Dictionary and kp2.has("proposal_for")))


## Footprint rewrite for the real worker's fail-closed IR compile (Round E,
## 019f783860c8): a footprint-less fixture board is refused with `component
## 'U1' has no footprint ref` — which is exactly how this suite silently
## degraded to canned results (bug 019ff2b1fccb). Faithful port of
## test_pcb_drc_propose.gd's _with_resolvable_footprints (item 019fc2228453);
## see the original for the full pin/net/hint renumbering contract.
const _REAL_FOOTPRINT_REF := "TH_TestPoint"


func _with_resolvable_footprints(params: Dictionary) -> Dictionary:
	var wire: Dictionary = params.duplicate(true)
	var board: Dictionary = wire.get("board", {})
	var renumber: Dictionary = {}
	for c in (board.get("components", []) as Array):
		if not (c is Dictionary):
			continue
		var comp: Dictionary = c
		comp["footprint"] = _REAL_FOOTPRINT_REF
		var ref := str(comp.get("ref", ""))
		for p in (comp.get("pins", []) as Array):
			if p is Dictionary:
				var old_number := str((p as Dictionary).get("number", ""))
				renumber["%s.%s" % [ref, old_number]] = "%s.1" % ref
				(p as Dictionary)["number"] = "1"
	for n in (board.get("nets", []) as Array):
		if not (n is Dictionary):
			continue
		var pin_refs: Array = (n as Dictionary).get("pins", [])
		for i in range(pin_refs.size()):
			var old_ref := str(pin_refs[i])
			if renumber.has(old_ref):
				pin_refs[i] = renumber[old_ref]
	for hint in (wire.get("route_hints", []) as Array):
		if not (hint is Dictionary):
			continue
		var kp: Variant = (hint as Dictionary).get("kind_payload")
		if not (kp is Dictionary):
			continue
		for key in ["source_pins", "dest_pins"]:
			var pins: Array = (kp as Dictionary).get(key, [])
			for i in range(pins.size()):
				var old_ref := str(pins[i])
				if renumber.has(old_ref):
					pins[i] = renumber[old_ref]
	return wire


## Prints WHY a real-worker invocation fell back, loudly, before the canned
## result masks it — this suite is designated real-worker in EXPECTED_SUITES,
## so the gd runner FAILS the run on real_worker_used=false.
func _surface_worker_failure(exit_code: int, output: Array, parsed: Variant) -> void:
	var detail := "no output from wrapper"
	if parsed is Dictionary:
		detail = JSON.stringify((parsed as Dictionary).get("error", parsed))
	elif not output.is_empty():
		detail = str(output[0]).left(500)
	printerr("[test_pcb_single_trace_tool] REAL-WORKER INVOCATION FAILED (exit=%d): %s" % [exit_code, detail])
	printerr("[test_pcb_single_trace_tool] canned fallback engaged — real_worker_used will report false and the gd runner fails this suite; fix the invocation, do not trust the green assertions")


## Real-worker-first route call (contract: prefer the real subprocess path).
## Returns a RoutingResult shaped exactly like the worker's own envelope
## ({success, via_count, routes:[{net,segments,vias}], unrouted}); sets
## _used_real_worker so the report can state which path ran (latched false
## for the whole run once any seam falls back).
func _route_result(source_hints: Array) -> Dictionary:
	var real := _real_route_result(data.to_board_dict(), source_hints, {"mode": "open"})
	if not real.is_empty():
		if not _worker_fell_back:
			_used_real_worker = true
		return real
	_worker_fell_back = true
	_used_real_worker = false
	push_warning("[test_pcb_single_trace_tool] real worker unavailable or refused (see any " +
		"REAL-WORKER INVOCATION FAILED line above) — canned RoutingResult fallback")
	return _canned_fallback_result(source_hints)


## Drives the REAL pcb-plugin Go binary + real Python pcb_worker over stdio via
## pcb/scripts/e2e_route_stdio.py (Godot's OS.execute cannot pipe stdin — see
## that script's header), with footprints rewritten to resolve against the
## worker's real library (see _with_resolvable_footprints). Returns {} (never
## crashes) so the caller can fall back cleanly: QUIETLY when the binary
## genuinely isn't built, LOUDLY via _surface_worker_failure when the binary
## exists but the invocation or the worker's reply failed.
func _real_route_result(board_dict: Dictionary, hints: Array, selection: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	if not FileAccess.file_exists(binary_path):
		return {}
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if not FileAccess.file_exists(wrapper_path):
		return {}

	var req_uri := "user://e2e3_route_request.json"
	var f := FileAccess.open(req_uri, FileAccess.WRITE)
	if f == null:
		printerr("[test_pcb_single_trace_tool] REAL-WORKER INVOCATION FAILED: cannot write %s" % req_uri)
		return {}
	f.store_string(JSON.stringify(_with_resolvable_footprints(
		{"board": board_dict, "route_hints": hints, "selection": selection})))
	f.close()
	var req_abs := ProjectSettings.globalize_path(req_uri)

	var output: Array = []
	var exit_code := OS.execute("python3", [wrapper_path, binary_path, req_abs], output, true)
	DirAccess.remove_absolute(req_abs)
	var parsed: Variant = null
	if not output.is_empty():
		parsed = JSON.parse_string(str(output[0]))
	if exit_code != 0 or not (parsed is Dictionary) or not bool((parsed as Dictionary).get("ok", false)):
		_surface_worker_failure(exit_code, output, parsed)
		return {}
	var res: Variant = (parsed as Dictionary).get("result", {})
	return res if res is Dictionary else {}


## Contract-allowed fallback (subprocess-boundary fake) ONLY reached when the
## real binary genuinely isn't built — same RoutingResult shape
## test_pcb_apply_route_hints.gd's _canned_result() uses, specialised to a
## direct pin1→pin2 SIG route (no waypoints, matches our fixture).
##
## Stamps the worker's own per-route `hint_ids` (docket 019f9c3a136c) from
## source_hints' real ids — a canned reply that omitted them made every
## candidate this fixture produced unattributed (empty source_hint_ids).
func _canned_fallback_result(source_hints: Array = []) -> Dictionary:
	var hint_ids: Array = []
	for h in source_hints:
		if h is Dictionary:
			hint_ids.append(str((h as Dictionary).get("id", "")))
	return {
		"success": true,
		"via_count": 0,
		"routes": [{
			"net": "SIG",
			"segments": [{"start": [U1_PIN1.x, U1_PIN1.y], "end": [U2_PIN1.x, U2_PIN1.y], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": hint_ids,
		}],
		"unrouted": [],
	}


func _has_route_for_net(result: Dictionary, net: String) -> bool:
	for route in result.get("routes", []):
		if route is Dictionary and str((route as Dictionary).get("net", "")) == net:
			return true
	return false


## S5 (C4b): kept as a pin on the NEGATIVE — nothing ever mints
## kind_payload.proposal_for anymore. Superseded for FINDING what propose
## actually produces by _find_candidate below.
func _find_proposal() -> Dictionary:
	for ann in host.get_all_annotations():
		if not (ann is Dictionary):
			continue
		if str(ann.get("kind", "")) != "pcb_route_hint":
			continue
		var kp: Dictionary = ann.get("kind_payload", {})
		if kp.has("proposal_for"):
			return ann
	return {}


func _find_candidate(workspace, net: String):
	if workspace == null:
		return null
	var live: Dictionary = {}
	for id in workspace.live_candidate_ids():
		live[str(id)] = true
	for c in workspace.list_candidates():
		if c != null and str(c.net) == net and live.has(str(c.candidate_id)):
			return c
	return null


# ── E2E-3D: serialize → reload, trace + hint state intact ────────────────────

func _test_e2e3_d_serialize_reload() -> void:
	print("-- E2E-3 D: serialize the board → trace present; reload → intact --")

	# A real on-disk path so save/load exercises the ACTUAL sidecar round-trip
	# (host_owned pattern — _on_panel_save_request writes the sidecar as a
	# side effect; Editor.gd owns writing the returned board dict to disk as
	# JSON, which is exactly the "saved YAML"/board-file equivalent here).
	var board_dir: String = driver.make_temp_board_dir("e2e3d_single_trace")
	var board_path: String = board_dir + "/board.minpcb"
	panel._file_path = board_path
	host.set_document_path(board_path)

	# MF-2(b2) UNIFIED: commit now closes consumed hints open→applied rather
	# than deleting them, so C's hint may still be on the board here (as
	# "applied") — hint_count_before/hint_ids_before are captured DYNAMICALLY
	# right after seeding this scenario's own fresh hint below, so the
	# round-trip assertions prove fidelity of whatever state actually exists
	# at this point rather than assuming a specific starting count.
	var env_d: Dictionary = host.build_route_hint_envelope(
		U1_PIN1.x, U1_PIN1.y, "", "F.Cu", "single_trace",
		[[U1_PIN1.x, U1_PIN1.y], [U2_PIN1.x, U2_PIN1.y]], "human")
	check("D: fresh open hint seeded", not str(host.add_annotation_v2(env_d)).is_empty())

	var trace_count_before: int = data.get_trace_count()
	var hint_count_before: int = host.get_annotations().size()
	var hint_ids_before: Array = []
	for ann in host.get_annotations():
		hint_ids_before.append(str((ann as Dictionary).get("id", "")))

	var saved: Dictionary = panel._on_panel_save_request()
	var traces: Array = saved.get("traces", [])
	check("D: saved board dict carries a trace", traces.size() >= 1, "traces=%s" % str(traces))
	check("D: sidecar was written", AnnotationSidecar.has_sidecar(board_path))

	# Reload the SAME saved shape back through the panel's own load hook
	# (host_owned round-trip — the exact path Ctrl+S/reopen drives) with a
	# real file_path so the sidecar branch actually runs.
	var doc: Dictionary = saved.duplicate(true)
	doc["file_path"] = board_path
	panel._on_panel_load_request(doc)
	await process_frame

	check("D: trace count intact after reload", data.get_trace_count() == trace_count_before,
		"before=%d after=%d" % [trace_count_before, data.get_trace_count()])
	check("D: hint annotation count intact after reload (via sidecar)",
		host.get_annotations().size() == hint_count_before,
		"before=%d after=%d" % [hint_count_before, host.get_annotations().size()])
	for hid in hint_ids_before:
		check("D: hint %s survives the reload" % hid, not host.get_by_id(hid).is_empty())

	driver.cleanup_sidecar(board_path)
	driver.cleanup_board_file(board_path)


# ── E2E-4A: cancel mid-draw (waypoint placed, right-click cancels) ───────────

func _test_e2e4_a_cancel_mid_draw() -> void:
	print("-- E2E-4 A: right-click mid-draw cancels — nothing persisted --")
	var before_count: int = host.get_annotations().size()

	await _press_trace_button()
	await _click_world(U1_PIN1)
	await _click_world(WAYPOINT_AT)   # append a waypoint
	var tool = _active_tool()
	check("4A: waypoint recorded", tool != null and tool.waypoint_count() == 1)

	await _click_world(WAYPOINT_AT, MOUSE_BUTTON_RIGHT)   # right-click cancels
	check("4A: right-click cancel deactivates the tool (button un-pressed)",
		not (panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	check("4A: no envelope committed — annotation count unchanged",
		host.get_annotations().size() == before_count,
		"before=%d after=%d" % [before_count, host.get_annotations().size()])

	var listed: Dictionary = await ann_tools.handle("minerva_annotations_list", {"editor_name": EDITOR_NAME})
	check("4A: MCP echoes the unchanged count (no echo of a cancelled draft)",
		int(listed.get("count", -1)) == before_count, str(listed))


# ── E2E-4B: self-reference cancel ─────────────────────────────────────────────

func _test_e2e4_b_self_reference_cancel() -> void:
	print("-- E2E-4 B: clicking the source pad as its own destination cancels --")
	var before_count: int = host.get_annotations().size()

	await _press_trace_button()
	await _click_world(U1_PIN1)   # source = pad U1.1
	await _click_world(U1_PIN1)   # same pad again → self-reference

	check("4B: self-reference cancel deactivates the tool (button un-pressed)",
		not (panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	check("4B: no envelope committed on self-reference",
		host.get_annotations().size() == before_count,
		"before=%d after=%d" % [before_count, host.get_annotations().size()])

	var listed: Dictionary = await ann_tools.handle("minerva_annotations_list", {"editor_name": EDITOR_NAME})
	check("4B: MCP echoes the unchanged count", int(listed.get("count", -1)) == before_count, str(listed))


# ── E2E-4C: clear-by-author(human) spares AI proposals ────────────────────────

func _test_e2e4_c_clear_by_author() -> void:
	print("-- E2E-4 C: clear-by-author(human) removes human hints, spares AI proposals --")

	# A fresh REAL human hint (pin1 → pin2 again — the E2E-3 hint is already
	# 'applied' by this point, which clear_annotations_by_author does NOT
	# special-case; author.kind is what matters).
	await _press_trace_button()
	await _click_world(U1_PIN1)
	await _click_world(U2_PIN1)
	await _release_trace_button()

	# Post-HITL-2 contract: E2E-3C's proposal was deleted with its consumed
	# hint, so seed this scenario's own AI-authored proposal to spare.
	var ai_env: Dictionary = host.build_route_hint_envelope(
		U1_PIN1.x, U1_PIN1.y, "", "F.Cu", "single_trace",
		[[U1_PIN1.x, U1_PIN1.y], [U2_PIN1.x, U2_PIN1.y]], "ai")
	check("4C: AI proposal seeded", not str(host.add_annotation_v2(ai_env)).is_empty())

	var human_ids: Array = []
	var ai_ids: Array = []
	for ann in host.get_annotations():
		if not (ann is Dictionary):
			continue
		var a: Dictionary = ann.get("author", {})
		if str(a.get("kind", "")) == "human":
			human_ids.append(str(ann.get("id", "")))
		elif str(a.get("kind", "")) == "ai":
			ai_ids.append(str(ann.get("id", "")))
	check("4C: at least one human hint present pre-clear", human_ids.size() >= 1, "human_ids=%s" % str(human_ids))
	check("4C: an AI proposal present pre-clear", ai_ids.size() >= 1, "ai_ids=%s" % str(ai_ids))

	var workflow_list = _WorkflowListScript.new()
	get_root().add_child(workflow_list)
	workflow_list.set_host(host)
	await process_frame

	var removed: int = workflow_list.clear_by_author("human")
	check("4C: clear_by_author(human) removed >= 1", removed >= 1, "removed=%d" % removed)

	for hid in human_ids:
		check("4C: human hint %s gone from the host" % hid, host.get_by_id(hid).is_empty())
	for aid in ai_ids:
		check("4C: AI proposal %s SURVIVES the human-clear" % aid, not host.get_by_id(aid).is_empty())

	# Gone from MCP too (UI clear IS a real removal, not a view filter).
	var listed: Dictionary = await ann_tools.handle("minerva_annotations_list", {"editor_name": EDITOR_NAME})
	var mcp_ids := []
	for a in listed.get("annotations", listed.get("results", [])):
		mcp_ids.append(str((a as Dictionary).get("id", "")))
	for hid in human_ids:
		check("4C: human hint %s gone from MCP" % hid, not (hid in mcp_ids))
	for aid in ai_ids:
		check("4C: AI proposal %s still visible via MCP" % aid, aid in mcp_ids)

	# Gone from the sidecar (persist the clear, then reload and confirm).
	var sidecar_doc := "user://e2e4c_board.minpcb"
	var err: int = host.save_sidecar(sidecar_doc)
	check("4C: sidecar save OK", err == OK, "err=%d" % err)
	host.set_annotations([])
	var loaded: int = host.load_sidecar(sidecar_doc)
	var reloaded_kinds := {}
	for hid in human_ids:
		reloaded_kinds[hid] = false
	for aid in ai_ids:
		reloaded_kinds[aid] = false
	for ann in host.get_annotations():
		var aid2 := str((ann as Dictionary).get("id", ""))
		if reloaded_kinds.has(aid2):
			reloaded_kinds[aid2] = true
	for hid in human_ids:
		check("4C: human hint %s absent from reloaded sidecar" % hid, not reloaded_kinds.get(hid, false))
	for aid in ai_ids:
		check("4C: AI proposal %s present in reloaded sidecar" % aid, reloaded_kinds.get(aid, false))
	check("4C: reload count == survivors only", loaded == ai_ids.size(), "loaded=%d expected=%d" % [loaded, ai_ids.size()])

	var sidecar_path := sidecar_doc + ".annotations.json"
	if FileAccess.file_exists(sidecar_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar_path))
	workflow_list.queue_free()
	await process_frame


# ── cross-surface mutual exclusion (review must_fix regression) ──────────────
## Arming the Trace tool must release the canvas tool surface (Pan /
## Pin-Inspect drop to Select, buttons un-press) and vice versa: pressing a
## canvas tool while tracing deactivates the route-flow cluster.
func _test_mutual_exclusion_across_surfaces() -> void:
	print("\n-- mutual exclusion: route-flow cluster vs canvas tool surface --")
	var canvas = panel._canvas
	var modes = canvas.ToolMode

	# Pin-Inspect armed, then Trace pressed -> canvas back to SELECT, button off.
	panel._inspect_pin_button.button_pressed = true
	panel._on_inspect_pin_button_pressed()
	await process_frame
	check("MX: pin-inspect armed (precondition)", canvas.tool_mode == modes.INSPECT_PIN)
	await _press_trace_button()
	check("MX: trace activation resets canvas to SELECT", canvas.tool_mode == modes.SELECT,
		"mode=%d" % canvas.tool_mode)
	check("MX: pin-inspect button un-pressed", not panel._inspect_pin_button.button_pressed)
	check("MX: trace tool active", _active_tool() != null)

	# Trace active, then Pan pressed -> route-flow cluster fully released.
	panel._toggle_tool_mode(modes.PAN)
	await process_frame
	check("MX: canvas tool press deactivates trace tool", _active_tool() == null)
	check("MX: trace button un-pressed after canvas tool press",
		not (panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	check("MX: canvas is in PAN", canvas.tool_mode == modes.PAN)

	# Trace active, then Pin-Inspect pressed -> same release path.
	await _press_trace_button()
	check("MX: trace re-armed", _active_tool() != null)
	panel._inspect_pin_button.button_pressed = true
	panel._on_inspect_pin_button_pressed()
	await process_frame
	check("MX: pin-inspect press deactivates trace tool", _active_tool() == null)
	check("MX: canvas is in INSPECT_PIN", canvas.tool_mode == modes.INSPECT_PIN)

	# Restore a neutral state for the next scenario.
	panel._inspect_pin_button.button_pressed = false
	panel._on_inspect_pin_button_pressed()
	await process_frame


# ── full MCP path through the broker envelope (HITL-2 live-bug regression) ───
## The live broker (MinervaIPC) wraps the backend reply in {success, result}
## while the Go side forwards the worker's own {ok, result} envelope verbatim
## (HandleRouteChannel) — so route_board receives a DOUBLE-wrapped envelope.
## E2E-3C fed the RoutingResult straight into the write-back helpers and never
## crossed that hop, which let a live "0 proposals from a routable hint" bug
## through. This section drives the REAL minerva_pcb_apply_route_hints handle()
## through a broker-fidelity IPC fake (still calling the REAL worker binary
## when present).
class FakeBrokerIpc:
	extends Node
	var suite = null
	var _params: Dictionary = {}
	var _reply_id: String = ""

	func on_request(channel: String, params: Dictionary, reply_id: String) -> void:
		if channel == "pcb.route":
			_params = params
			_reply_id = reply_id

	## Duck-typed stand-in for MinervaIPC.await_reply — returns the LIVE broker
	## envelope shape: {success:true, result:<worker's own {ok, result}>}.
	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id or suite == null:
			return {"success": false, "error_code": "timeout", "error_message": "no captured request"}
		var worker_env: Dictionary = suite.raw_worker_envelope(_params)
		return {"success": true, "result": worker_env}


## Runs the stdio bridge with the exact captured IPC params (footprints
## rewritten via _with_resolvable_footprints); returns the worker's own
## {ok, result} envelope (NOT unwrapped). This seam participates in the
## real_worker_used verdict too — it used to be invisible to it, so a canned
## broker path could hide behind a green report. Canned fallback keeps the
## same double shape: quiet when the binary genuinely isn't built, LOUD via
## _surface_worker_failure when the invocation or reply failed.
func raw_worker_envelope(params: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if not FileAccess.file_exists(binary_path) or not FileAccess.file_exists(wrapper_path):
		_worker_fell_back = true
		_used_real_worker = false
		push_warning("[test_pcb_single_trace_tool] real pcb-plugin binary not built — " +
			"canned broker-path fallback")
		return {"ok": true, "result": _canned_fallback_result()}
	var req_uri := "user://e2e_broker_route_request.json"
	var f := FileAccess.open(req_uri, FileAccess.WRITE)
	if f == null:
		_worker_fell_back = true
		_used_real_worker = false
		printerr("[test_pcb_single_trace_tool] REAL-WORKER INVOCATION FAILED: cannot write %s" % req_uri)
		return {"ok": true, "result": _canned_fallback_result()}
	f.store_string(JSON.stringify(_with_resolvable_footprints(params)))
	f.close()
	var req_abs := ProjectSettings.globalize_path(req_uri)
	var output: Array = []
	var exit_code := OS.execute("python3", [wrapper_path, binary_path, req_abs], output, true)
	DirAccess.remove_absolute(req_abs)
	var parsed: Variant = null
	if not output.is_empty():
		parsed = JSON.parse_string(str(output[0]))
	if exit_code == 0 and parsed is Dictionary and bool((parsed as Dictionary).get("ok", false)):
		if not _worker_fell_back:
			_used_real_worker = true
		return parsed
	_worker_fell_back = true
	_used_real_worker = false
	_surface_worker_failure(exit_code, output, parsed)
	return {"ok": true, "result": _canned_fallback_result()}


func _test_apply_tool_full_mcp_broker_path() -> void:
	print("\n-- apply tool through the FULL MCP + broker-envelope path --")
	var traces_before: int = data.get_trace_count()

	# Fresh UN-CONNECTED pair for THIS scenario (testex find, OFC epoch): the
	# old target U1.1→U2.1 was ALREADY CONNECTED by E2E-3C's committed trace,
	# and the REAL worker correctly reports span_outcomes=already_connected
	# and proposes NOTHING — only the canned double blindly re-routed it. The
	# broker-envelope proof needs a span the router can actually route.
	var u5 = data.new_component()
	u5.id = "U5"
	u5.position = Vector2(15.0, 30.0)
	u5.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(u5)
	var u6 = data.new_component()
	u6.id = "U6"
	u6.position = Vector2(55.0, 30.0)
	u6.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(u6)
	data.connect_pin_to_net("SIG3", "U5", "1")
	data.connect_pin_to_net("SIG3", "U6", "1")

	# Fresh open hint (host-authored twin of a tool-drawn one).
	var env: Dictionary = host.build_route_hint_envelope(
		15.0, 30.0, "", "F.Cu", "single_trace",
		[[15.0, 30.0], [55.0, 30.0]], "human")
	var kp: Dictionary = env.get("kind_payload", {})
	kp["source_pins"] = ["U5.1"]
	kp["dest_pins"] = ["U6.1"]
	env["kind_payload"] = kp
	var hint_id := str(host.add_annotation_v2(env))
	check("BR: fresh hint added", not hint_id.is_empty())

	# Broker-fidelity IPC fake mounted exactly where route_board looks.
	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	var propose_res: Dictionary = await panel.handle_tool(
		"minerva_pcb_apply_route_hints", {"editor_name": EDITOR_NAME})
	check("BR: propose ok through full MCP path", bool(propose_res.get("success", false)), str(propose_res))
	check("BR: broker double-envelope unwrapped -> >=1 proposal",
		int(propose_res.get("proposed", 0)) >= 1, str(propose_res))

	var commit_res: Dictionary = await panel.handle_tool(
		"minerva_pcb_apply_route_hints", {"editor_name": EDITOR_NAME, "commit": true})
	check("BR: commit ok through full MCP path", bool(commit_res.get("success", false)), str(commit_res))
	check("BR: trace added through full MCP path", data.get_trace_count() > traces_before,
		"before=%d after=%d" % [traces_before, data.get_trace_count()])

	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame


# ── assertion helper ──────────────────────────────────────────────────────────

func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)
