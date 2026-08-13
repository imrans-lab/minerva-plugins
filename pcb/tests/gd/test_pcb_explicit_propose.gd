extends SceneTree
## Explicit-propose UX + proposal lifecycle E2E (C5, docket 019f6c465fd8).
##
## Run: godot --headless --path . --script test/test_pcb_explicit_propose.gd
## (run from the Minerva worktree's src/ directory — see CRITICAL SAFETY in
## the round brief: never run headless godot from the non-worktree checkout).
##
## Product contract v2 (owner-ratified): the router NEVER runs implicitly —
## proposing routes is always an explicit human or agent act.
##
## S5 UPDATE (C4b, DCR 019f7095c395): "Proposals (cyan AI annotations linked to
## hints via kind_payload.proposal_for)" — the ORIGINAL C5 contract this file's
## name still honors — is RETIRED. Propose now lands RouteCandidates in the
## routing workspace ONLY (panel_tools.gd _propose_into_workspace); no
## annotation is written. Individually answerable still holds, just moved:
## minerva_pcb_workspace_commit(candidate_id) materializes that candidate's
## trace (source hints are left OPEN — the workspace never touches
## annotations, unlike the retired per-proposal accept);
## minerva_pcb_workspace_reject(candidate_id) discards it and reopens its task,
## source hints stay open for iteration either way.
##
## Scenarios:
##   A) Human draws a hint via the Trace tool (real input) → NO candidate
##      exists (nothing auto-fires — panel mount / tool activation / annotation
##      changes never invoke the router; this is deliverable 4's audit,
##      exercised live).
##   B) Click the Propose button (real input on the actual Button, not a
##      direct handler call for the click itself — see _click_propose_button)
##      → a candidate linked to the hint lands in the routing workspace; the
##      board is NOT mutated and NO annotation is added. Also proves the
##      RETIREMENT of the WorkflowAnnotationList generic Accept/Reject wiring
##      (deliverable 2's UI half, DCR finding 4): NEITHER the (would-be)
##      proposal row NOR the plain-hint row ever grows Accept/Reject buttons,
##      because PcbAnnotationHost no longer implements the duck-typed verb pair
##      at all — not because nothing happens to be AI-authored.
##   C) minerva_pcb_workspace_reject via REAL panel-tool dispatch (
##      panel_tool_registry_driver, same rig test_pcb_apply_route_hints.gd /
##      test_pcb_hint_refine_loop.gd use for panel-executed tools) → candidate
##      discarded, source hint still open, zero annotation residue (there was
##      never any to begin with).
##   D) Propose again → commit via minerva_pcb_workspace_commit (REAL dispatch)
##      → a real trace matches the candidate's own polyline exactly; the
##      source hint is left OPEN (S5: commit is a board+disposition
##      transaction only — it cannot delete an annotation it has no reference
##      to); the board has exactly one trace.
##   E) Backend-stopped affordance (bug 019f6c1e0399): sabotage the IPC seam
##      the way test_pcb_apply_route_hints.gd simulates worker-unavailable
##      (a fake "_MinervaIPC" node intercepting panel.request) — but replying
##      with the SAME {error_code:"plugin_not_running", ...} shape
##      PluginScenePanelBroker._dispatch_to_plugin_backend returns when the
##      backend subprocess isn't RUNNING (not the "no bridge at all" shape the
##      existing suite uses). The Propose button's status label shows the
##      human-actionable message; the tool result carries the structured
##      pcb_backend_stopped error + recovery hint.
##   F) Bulk regression: minerva_pcb_apply_route_hints commit=true still works
##      through the SAME _materialize_routes machinery — unaffected by S5 (that
##      branch never wrote an annotation) — delete-on-commit contract intact.
##
## REUSE SCAN: mount/fixture/input/real-worker-stdio conventions copied
## verbatim from test_pcb_hint_refine_loop.gd (real PCBPanel boot headless,
## real input via get_root().push_input(), the e2e_route_stdio.py bridge +
## documented canned fallback for real-worker steps, the FakeBrokerIpc
## broker-fidelity shape). REAL panel-tool dispatch for the workspace
## commit/reject tools uses test/helpers/panel_tool_registry_driver.gd (same
## fixture test_pcb_panel_tools_migration.gd established, reused by every pcb
## panel-tool suite since).
##
## Off-tree: the plugin scripts live outside res://; every panel/host/model
## ref is duck-typed and loaded by path (never typed AS a plugin class).

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")

const EDITOR_NAME := "ExplicitProposeProbe"
const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"
const PCB_PLUGIN_ID := "pcb"

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

var overlay: AnnotationOverlay = null

const U1_PIN1 := Vector2(15.0, 20.0)
const U2_PIN1 := Vector2(55.0, 20.0)
# y=32 (testex find, OFC epoch): these two lived at y=55 on a 40 mm-tall
# board — OUT OF BOUNDS — and only the canned fallback ever routed them; the
# REAL worker refuses endpoint_out_of_bounds. Scenario F never clicks them
# (bulk apply via handle_tool), so an in-bounds row is free of canvas math.
const U3_PIN1 := Vector2(15.0, 32.0)
const U4_PIN1 := Vector2(55.0, 32.0)

var _hint_id := ""
## Workspace candidate id (S5, C4b: propose lands a candidate, not an
## annotation — see the class doc). Renamed from the pre-S5 _proposal_id.
var _candidate_id := ""


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB Explicit-Propose + Proposal-Lifecycle E2E (C5) ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	await _test_a_draw_hint_nothing_auto_fires()
	await _test_b_propose_creates_proposal()
	await _test_c_reject_via_real_dispatch()
	await _test_d_propose_again_then_accept_via_real_dispatch()
	await _test_e_backend_stopped_affordance()
	await _test_f_bulk_commit_regression()

	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [_pass, _fail, str(_used_real_worker)])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture (test_pcb_hint_refine_loop.gd conventions) ───────────────

func _mount() -> bool:
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

	canvas.zoom = 4.0
	canvas.pan_offset = -Vector2(data.board_width, data.board_height) / 2.0 * canvas.zoom
	canvas.queue_redraw()
	await process_frame

	overlay = AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.get_annotation_overlay_parent().add_child(overlay)
	overlay.set_host(host)
	await process_frame

	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR_NAME, host)
	return true


## Only U1/U2 (net SIG) are wired up front — U3/U4 (net SIG2) are added later,
## right before scenario F, so earlier scenarios' router calls only ever see
## the ONE net that has an open hint (matches test_pcb_hint_refine_loop.gd's
## single-net fixture, a proven-working shape for the real worker).
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


# ── input helpers (copied convention from test_pcb_hint_refine_loop.gd) ──────

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


## Real input on the Propose button (deliverable 1: "Click Propose button
## (real input)") — a plain (non-toggle) Button, so a real click is just
## emitting its own `pressed` signal (no button_pressed toggle-state to
## manage, unlike the Trace/Edit-hint radio buttons above). Godot resumes the
## connected async handler across its internal awaits before this call
## returns (signals don't block on coroutine completion), so callers must
## await process_frame in a loop until the panel's status label stops
## reading "Proposing routes…" — mirrors how a real user's click resolves
## asynchronously without freezing the UI thread.
func _click_propose_button() -> void:
	panel._propose_button.pressed.emit()
	var guard := 0
	while panel._status_label.text == "Proposing routes…" and guard < 200:
		await process_frame
		guard += 1


# ── real-worker broker-fidelity fake (test_pcb_hint_refine_loop.gd convention) ─
## Mirrors the live broker (MinervaIPC): wraps the backend reply in
## {success, result} while the Go side forwards the worker's own {ok, result}
## envelope verbatim (HandleRouteChannel).
class FakeBrokerIpc:
	extends Node
	var suite = null
	var _params: Dictionary = {}
	var _reply_id: String = ""

	func on_request(channel: String, params: Dictionary, reply_id: String) -> void:
		if channel == "pcb.route":
			_params = params
			_reply_id = reply_id

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id or suite == null:
			return {"success": false, "error_code": "timeout", "error_message": "no captured request"}
		var worker_env: Dictionary = suite.raw_worker_envelope(_params)
		return {"success": true, "result": worker_env}


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
	printerr("[test_pcb_explicit_propose] REAL-WORKER INVOCATION FAILED (exit=%d): %s" % [exit_code, detail])
	printerr("[test_pcb_explicit_propose] canned fallback engaged — real_worker_used will report false and the gd runner fails this suite; fix the invocation, do not trust the green assertions")


## Runs the REAL pcb-plugin Go binary + Python worker over stdio with the
## exact captured IPC params, footprints rewritten to resolve against the
## worker's real library (see _with_resolvable_footprints). Returns the
## worker's own {ok, result} envelope (matching the live broker's
## double-wrap). The canned single-segment fallback is a subprocess-boundary
## fake: quiet when the binary genuinely isn't built, LOUD via
## _surface_worker_failure when the binary exists but the invocation or the
## worker's reply failed.
func raw_worker_envelope(params: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if not FileAccess.file_exists(binary_path) or not FileAccess.file_exists(wrapper_path):
		# F7 (Codex 1188): every fallback path latches — a later successful
		# call must not flip the run's verdict back to true.
		_worker_fell_back = true
		_used_real_worker = false
		push_warning("[test_pcb_explicit_propose] real pcb-plugin binary not built — " +
			"canned single-segment fallback")
		return {"ok": true, "result": _canned_result_for(params)}
	var req_uri := "user://c5_explicit_propose_route_request.json"
	var f := FileAccess.open(req_uri, FileAccess.WRITE)
	if f == null:
		_worker_fell_back = true
		_used_real_worker = false
		printerr("[test_pcb_explicit_propose] REAL-WORKER INVOCATION FAILED: cannot write %s" % req_uri)
		return {"ok": true, "result": _canned_result_for(params)}
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
	return {"ok": true, "result": _canned_result_for(params)}


## Contract-allowed fallback (subprocess-boundary fake), reached ONLY when the
## real binary isn't built: one straight segment per open route_hint envelope
## in the request, source pad → dest pad, on the hint's own net (derived from
## source_pins' component's connected net — falls back to "SIG" when absent,
## which is the only net every fixture hint in this suite ever uses).
##
## Stamps the worker's own per-route `hint_ids` (docket 019f9c3a136c) with the
## hint's own id — a canned reply that omitted them made every candidate this
## fixture produced unattributed (source_hint_ids empty instead of [_hint_id]).
## Pre-S5 this attribution surfaced as an annotation's kind_payload.
## proposal_for; S5 moved it onto the landed candidate's own source_hint_ids
## (see panel_tools.gd _propose_into_workspace) — the underlying worker
## contract this stamp exercises is unchanged.
func _canned_result_for(params: Dictionary) -> Dictionary:
	var routes: Array = []
	for hint in params.get("route_hints", []):
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = (hint as Dictionary).get("kind_payload", {})
		var src: Array = kp.get("source_pins", [])
		var dst: Array = kp.get("dest_pins", [])
		if src.is_empty() or dst.is_empty():
			continue
		var src_pos := _pin_world_pos(str(src[0]))
		var dst_pos := _pin_world_pos(str(dst[0]))
		var net := _net_for_pin(str(src[0]))
		routes.append({
			"net": net,
			"segments": [{"start": [src_pos.x, src_pos.y], "end": [dst_pos.x, dst_pos.y], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [str((hint as Dictionary).get("id", ""))],
		})
	return {"success": true, "via_count": 0, "routes": routes, "unrouted": []}


func _pin_world_pos(ref: String) -> Vector2:
	var parts := ref.split(".")
	if parts.size() != 2:
		return Vector2.ZERO
	var comp = data.get_component(parts[0])
	if comp == null:
		return Vector2.ZERO
	return comp.get_pin_world_position(parts[1])


func _net_for_pin(ref: String) -> String:
	var parts := ref.split(".")
	if parts.size() != 2:
		return "SIG"
	for net_name in data.nets:
		var net = data.nets[net_name]
		for pin in net.pins:
			if str(pin.get("component_id", "")) == parts[0] and str(pin.get("pin_name", "")) == parts[1]:
				return net.name
	return "SIG"


# ── A: draw a hint via the Trace tool; NOTHING auto-fires ────────────────────

func _test_a_draw_hint_nothing_auto_fires() -> void:
	print("-- A: human draws a hint pin1 -> pin2 via the Trace tool (real input) --")
	check("A: no annotations before drawing", host.get_annotations().size() == 0)

	await _press_trace_button()
	check("A: overlay's active tool is a route-flow tool", overlay.has_active_tool())

	await _click_world(U1_PIN1)
	await _click_world(U2_PIN1)   # dest pad -> commits (0 interior waypoints)

	check("A: hint committed — host has exactly 1 annotation", host.get_annotations().size() == 1,
		"count=%d" % host.get_annotations().size())

	var ann: Dictionary = host.get_annotations()[0] if host.get_annotations().size() == 1 else {}
	_hint_id = str(ann.get("id", ""))
	check("A: hint id assigned", not _hint_id.is_empty())
	# Epoch UX3 station 8a (docket 019fdf903a4a): a zero-interior-waypoint
	# pad→pad commit delegates to minerva_pcb_add_route_intent, so the minted
	# hint is the intent tool's own object ("waypoint", pin provenance, an
	# eager RouteTask — NOT a candidate, so deliverable 4 below still holds).
	check("A: hint_type is waypoint (a TRUE intent — station 8a replaced the single_trace look-alike)",
		str(ann.get("kind_payload", {}).get("hint_type", "")) == "waypoint",
		"kp=%s" % str(ann.get("kind_payload", {})))
	check("A: source_pins == [U1.1]", (ann.get("kind_payload", {}).get("source_pins", []) as Array) == ["U1.1"])
	check("A: dest_pins == [U2.1]", (ann.get("kind_payload", {}).get("dest_pins", []) as Array) == ["U2.1"])

	# Deliverable 4 (nothing auto-fires), exercised live: drawing a hint alone
	# never invokes the router — no candidate exists, board unmutated.
	check("A: NO annotation carries proposal_for — nothing auto-fired",
		not _any_proposal_exists(), "annotations=%s" % str(host.get_annotations()))
	check("A: NO candidate landed in the routing workspace either",
		_workspace_candidate_count() == 0)
	check("A: board has zero traces (nothing auto-fired)", data.get_trace_count() == 0)

	await _release_trace_button()


## S5 (C4b): kept as a pin on the NEGATIVE — nothing ever mints
## kind_payload.proposal_for anymore, on any annotation, for any reason (a
## fresh regression here would mean the retired write-back path came back).
func _any_proposal_exists() -> bool:
	for ann in host.get_annotations():
		if ann is Dictionary and not (ann.get("kind_payload", {}).get("proposal_for", []) as Array).is_empty():
			return true
	return false


func _workspace_candidate_count() -> int:
	var workspace = panel.get_routing_workspace()
	if workspace == null:
		return 0
	return workspace.list_candidates().size()


## LIVE-only lookup (matches _workspace_list's own live-by-default rule): a
## terminal candidate from an earlier scenario (e.g. C's rejected cand_1) must
## never shadow the fresh one a later propose lands for the same net.
func _find_candidate(net: String):
	var workspace = panel.get_routing_workspace()
	if workspace == null:
		return null
	var live: Dictionary = {}
	for id in workspace.live_candidate_ids():
		live[str(id)] = true
	for c in workspace.list_candidates():
		if c != null and str(c.net) == net and live.has(str(c.candidate_id)):
			return c
	return null


# ── B: click Propose; a cyan proposal appears; board unmutated ───────────────

func _test_b_propose_creates_proposal() -> void:
	print("-- B: click Propose (real input, REAL worker) --")

	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	await _click_propose_button()

	check("B: which routing path ran is reported", true,
		"real_worker=%s (binary at <minerva-plugins>/pcb/pcb-plugin)" % str(_used_real_worker))
	# DRC-at-propose (docket 019f6f1492e0): the REAL worker's route() now
	# attaches drc_summary (the canned stdio-boundary fallback in this suite
	# does not — see _canned_result_for), and PCBPanel appends a DRC suffix to
	# the status label when drc_summary is present. The fixture at this point
	# has exactly one net (SIG, U1<->U2, no existing traces) so a real-worker
	# run must come back clean.
	# Real-worker string is the CURRENT status format (testex find: the old
	# "DRC clean" suffix predates the geometric-DRC split and was unreachable
	# while the seam silently ran canned).
	var expected_b_status := "1 proposal — Connectivity clean (pre-existing: none) — Geometric clean" if _used_real_worker else "1 proposal"
	check("B: status label reports one proposal" + (" (DRC clean)" if _used_real_worker else ""),
		panel._status_label.text == expected_b_status,
		"got '%s' expected '%s'" % [panel._status_label.text, expected_b_status])
	# S5 (C4b): propose lands a workspace candidate now, no annotation — the
	# host still holds only the source hint from A.
	check("B: host still has exactly 1 annotation (the hint; no proposal written)",
		host.get_annotations().size() == 1, "count=%d" % host.get_annotations().size())
	check("B: board still unmutated — zero traces", data.get_trace_count() == 0)

	var cand = _find_candidate("SIG")
	check("B: a candidate landed in the routing workspace", cand != null)
	if cand != null:
		_candidate_id = str(cand.candidate_id)
		check("B: candidate id assigned", not _candidate_id.is_empty())
		check("B: candidate links back to the source hint",
			cand.source_hint_ids == [_hint_id],
			"got %s" % str(cand.source_hint_ids))
		check("B: candidate carries a routable polyline (>=1 segment)",
			(cand.segments as Array).size() >= 1)

	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame

	await _test_b2_workflow_list_generic_wiring()


## B2 (deliverable 2's UI half, DCR finding 4 — S5/C4b RETIREMENT): mount the
## CORE WorkflowAnnotationList against the SAME live host and prove NEITHER
## row ever grows Accept/Reject buttons — not even an AI-authored one. Before
## S5, core's duck-typed check (author.kind=="ai") would have offered them on
## a proposal row; DCR finding 4 named that inference wrong for a SOURCE hint
## an agent happens to author (intent/commentary, not a proposal), and the
## fix removes the plugin-side verb pair entirely rather than trying to make
## core's inference smarter (core is out of fence this epoch — see
## PcbAnnotationHost.gd's own note at the retirement site). Seeds a SECOND
## hint stamped author.kind="ai" (not human) specifically to prove the
## negative unconditionally: an AI-authored source hint gets no buttons
## either, because the host simply no longer implements
## accept_annotation_proposal/reject_annotation_proposal — not because
## author.kind happens not to match this time.
func _test_b2_workflow_list_generic_wiring() -> void:
	print("-- B2: WorkflowAnnotationList — NO Accept/Reject on any row (S5 retirement) --")
	check("B2: host has no duck-typed accept_annotation_proposal",
		not host.has_method("accept_annotation_proposal"))
	check("B2: host has no duck-typed reject_annotation_proposal",
		not host.has_method("reject_annotation_proposal"))

	var ai_env: Dictionary = host.build_route_hint_envelope(
		U3_PIN1.x, U3_PIN1.y, "", "F.Cu", "single_trace",
		[[U3_PIN1.x, U3_PIN1.y], [U3_PIN1.x + 4.0, U3_PIN1.y]], "ai")
	var ai_id := str(host.add_annotation_v2(ai_env))
	check("B2: AI-authored hint seeded", not ai_id.is_empty())

	var wf_list := WorkflowAnnotationList.new()
	get_root().add_child(wf_list)
	wf_list.set_host(host)
	await process_frame

	var listing: Array = wf_list.get_listing()
	check("B2: listing has 2 entries (human hint + AI hint — nothing is superseded anymore)",
		listing.size() == 2, "got %d" % listing.size())
	var listed_ids: Array = []
	for e in listing:
		listed_ids.append(str((e as Dictionary).get("id", "")))
	check("B2: the human source hint keeps its row", _hint_id in listed_ids, "listed=%s" % str(listed_ids))
	check("B2: the AI hint keeps its row too", ai_id in listed_ids)

	# Recursive: rows live inside the capped ScrollContainer.
	var groups_node := wf_list.find_child("WorkflowGroups", true, false)
	check("B2: WorkflowGroups node mounted", groups_node != null)
	if groups_node != null:
		var row_count := 0
		var any_buttons := false
		for child in groups_node.get_children():
			if not (child is HBoxContainer):
				continue
			row_count += 1
			if (child as Control).find_child("AcceptButton", false, false) != null \
					or (child as Control).find_child("RejectButton", false, false) != null:
				any_buttons = true
		check("B2: both rows present in the UI tree", row_count == 2, "got %d" % row_count)
		check("B2: NO row anywhere has an Accept or Reject button (human OR AI author)",
			not any_buttons)

	# Remove the B2-only seeded hint: later scenarios assert exact annotation
	# counts and consumed-hint ids against the original fixture board.
	check("B2: seeded AI hint removed", host.remove_annotation(ai_id))

	wf_list.queue_free()
	await process_frame


# ── C: reject via REAL panel-tool dispatch — candidate discarded, hint open ──

func _test_c_reject_via_real_dispatch() -> void:
	print("-- C: minerva_pcb_workspace_reject via REAL registry dispatch --")
	var registry: PluginToolRegistry = REGISTRY_DRIVER.new().build(
		panel, PCB_PLUGIN_ID, EDITOR_NAME, ["minerva_pcb_workspace_reject", "minerva_pcb_workspace_commit"])
	check("C: dispatch registry built", registry != null)
	if registry == null:
		return

	var result: Dictionary = await registry.handle_tool_call("minerva_pcb_workspace_reject", {
		"editor_name": EDITOR_NAME, "candidate_id": _candidate_id,
	})
	check("C: reject ok", bool(result.get("success", false)), str(result))
	check_eq("C: disposition is rejected", str(result.get("disposition", "")), "rejected")
	# S5: reject is a workspace-only transaction — it has no reference to the
	# annotation host, so it cannot report "source_hints_still_open" the way
	# the retired minerva_pcb_proposal_reject did. It stays open because
	# nothing ever touched it, verified directly below.
	check("C: reply names the candidate's own source_hint_ids == [hint_id]",
		(result.get("source_hint_ids", []) as Array) == [_hint_id],
		"got %s" % str(result.get("source_hint_ids", [])))

	check("C: no annotation residue — exactly 1 annotation left (the hint; never had a proposal)",
		host.get_annotations().size() == 1, "count=%d" % host.get_annotations().size())
	var remaining: Dictionary = host.get_by_id(_hint_id)
	check("C: the source hint itself is untouched and still open",
		not remaining.is_empty() and str(remaining.get("lifecycle", "")) == "open")
	check("C: board still has zero traces", data.get_trace_count() == 0)

	_cleanup_stale_registry_dispatch()
	await process_frame


## panel_tool_registry_driver.build() attaches a REAL MinervaIPC helper node
## ("_MinervaIPC") to `panel` and connects an anonymous lambda to panel.request
## — neither is undone by a normal call flow (a platform gap, out of this
## round's fence — same finding test_pcb_hint_refine_loop.gd documents at its
## own call site). Clean both by hand between dispatch calls so a later
## FakeBrokerIpc mount doesn't collide with a stale non-functional broker.
func _cleanup_stale_registry_dispatch() -> void:
	for conn in panel.request.get_connections():
		panel.request.disconnect(conn["callable"])
	for child in panel.get_children():
		if str(child.name).begins_with("_MinervaIPC"):
			panel.remove_child(child)
			child.queue_free()


# ── D: propose again, then commit via REAL dispatch ───────────────────────────

func _test_d_propose_again_then_accept_via_real_dispatch() -> void:
	print("-- D: propose again, then minerva_pcb_workspace_commit via REAL dispatch --")

	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	await _click_propose_button()
	# Same DRC-suffix accommodation as scenario B (see its comment) — still a
	# single clean net (SIG) at this point.
	var expected_d_status := "1 proposal — Connectivity clean (pre-existing: none) — Geometric clean" if _used_real_worker else "1 proposal"
	check("D: status label reports one proposal again", panel._status_label.text == expected_d_status,
		"got '%s' expected '%s'" % [panel._status_label.text, expected_d_status])

	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame

	# S5 (C4b): propose lands a fresh candidate in the workspace (task C's
	# reject reopened the SIG task, so a re-propose gets a new generation for
	# the same task) — no annotation involved, see scenario B's comment.
	var new_cand = _find_candidate("SIG")
	check("D: a fresh candidate exists", new_cand != null)
	if new_cand == null:
		return
	var new_cid := str(new_cand.candidate_id)
	var cand_segments: Array = new_cand.segments
	check("D: candidate links back to the source hint",
		new_cand.source_hint_ids == [_hint_id],
		"got %s" % str(new_cand.source_hint_ids))

	var registry: PluginToolRegistry = REGISTRY_DRIVER.new().build(
		panel, PCB_PLUGIN_ID, EDITOR_NAME, ["minerva_pcb_workspace_commit"])
	check("D: dispatch registry built", registry != null)
	if registry == null:
		return

	check("D: no traces on the board yet", data.get_trace_count() == 0)
	var result: Dictionary = await registry.handle_tool_call("minerva_pcb_workspace_commit", {
		"editor_name": EDITOR_NAME, "candidate_id": new_cid,
	})
	check("D: commit ok", bool(result.get("success", false)), str(result))
	check("D: at least one trace_id reported", not (result.get("trace_ids", []) as Array).is_empty())
	check("D: consumed_hint_ids == [hint_id]",
		(result.get("consumed_hint_ids", []) as Array) == [_hint_id],
		"got %s" % str(result.get("consumed_hint_ids", [])))
	check_eq("D: committed candidate's own disposition is committed",
		str((result.get("candidate", {}) as Dictionary).get("disposition", "")), "committed")

	check("D: exactly one trace on the board", data.get_trace_count() == 1,
		"count=%d" % data.get_trace_count())
	var sig_traces: Array = data.get_traces_for_net("SIG")
	check("D: SIG trace exists", sig_traces.size() == 1)
	if sig_traces.size() == 1:
		var t = sig_traces[0]
		# Reconstruct the expected polyline from the candidate's own segment
		# shape: {"id","layer","width","points":Array[Vector2],"locked"}
		# (pcb_route_candidate.gd make_segment) — NOT the router-reply/
		# annotation shape {start:[x,y], end:[x,y], layer}. First segment's
		# full point list, then every later segment's own points.
		var expected: Array = []
		for seg in cand_segments:
			var pts: Array = (seg as Dictionary).get("points", [])
			for p in pts:
				if expected.is_empty() or not (expected[-1] as Vector2).is_equal_approx(p as Vector2):
					expected.append(p as Vector2)
		check("D: trace polyline matches the candidate's own polyline exactly (point count)",
			(t.waypoints as Array).size() == expected.size(),
			"expected=%s actual=%s" % [str(expected), str(t.waypoints)])
		check("D: trace polyline matches the candidate's own polyline exactly (points)",
			_points_equal(t.waypoints, expected) or _points_equal(t.waypoints, _reversed(expected)),
			"expected=%s actual=%s" % [str(expected), str(t.waypoints)])

	# MF-2 REVERT (review): the pin this used to assert here ("hint stays open,
	# workspace verbs never touch annotations") was a WRONG pin-move. The
	# retired per-proposal accept deleted BOTH the source hint and the
	# proposal annotation; owner-ratified HITL-2 (manifest.json's own
	# apply_route_hints text; the DCR's composite-transaction text) says the
	# TRUE semantic was never delete — it is open→applied, and
	# minerva_pcb_workspace_commit now performs exactly that as its half of
	# the composite transaction (panel_tools.gd _workspace_commit →
	# _set_hint_lifecycle). The hint annotation survives (it is durable
	# intent/commentary), only its lifecycle field closes.
	var hint_after_commit: Dictionary = host.get_by_id(_hint_id)
	check("D: source hint SURVIVES commit (not deleted)", not hint_after_commit.is_empty())
	check_eq("D: source hint lifecycle closed: open -> applied",
		str(hint_after_commit.get("lifecycle", "")), "applied")
	check("D: exactly 1 annotation left (the hint) — there was never a proposal to delete",
		host.get_annotations().size() == 1, "count=%d" % host.get_annotations().size())

	_cleanup_stale_registry_dispatch()
	await process_frame


# ── E: backend-stopped affordance ─────────────────────────────────────────────

## Sabotage-broker fake replying with the SAME shape
## PluginScenePanelBroker._dispatch_to_plugin_backend returns when the pcb
## backend subprocess is registered but not RUNNING — distinct from
## test_pcb_apply_route_hints.gd's "no _MinervaIPC at all" worker-unavailable
## simulation (that shape stays a generic route_worker_unavailable; THIS shape
## is the one PCBPanel.route_board()/panel_tools.gd's _router_unavailable must
## now recognise specifically).
class SabotageBrokerIpc:
	extends Node
	var _reply_id: String = ""

	func on_request(channel: String, _params: Dictionary, reply_id: String) -> void:
		if channel == "pcb.route":
			_reply_id = reply_id

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id:
			return {"success": false, "error_code": "timeout", "error_message": "no captured request"}
		return {"success": false, "error_code": "plugin_not_running",
			"error_message": "Plugin is not running", "plugin_id": PCB_PLUGIN_ID}


func _test_e_backend_stopped_affordance() -> void:
	print("-- E: backend-stopped affordance (bug 019f6c1e0399) --")

	# A fresh open hint so _apply_route_hints reaches the router bridge
	# instead of short-circuiting on "no open route hints".
	var env: Dictionary = host.build_route_hint_envelope(
		U1_PIN1.x, U1_PIN1.y, "", "F.Cu", "single_trace",
		[], "human", "", 0.25, ["U1.1"], ["U2.1"])
	var fresh_hint_id := str(host.add_annotation_v2(env))
	check("E: fresh hint seeded", not fresh_hint_id.is_empty())
	var traces_before_e: int = data.get_trace_count()

	var sabotage := SabotageBrokerIpc.new()
	sabotage.name = "_MinervaIPC"
	panel.add_child(sabotage)
	panel.request.connect(sabotage.on_request)

	# Structured machine shape: call the tool directly (same code path the
	# Propose button uses).
	var tool_result: Dictionary = await panel.handle_tool("minerva_pcb_apply_route_hints", {"commit": false})
	check("E: tool result is not success", not bool(tool_result.get("success", true)))
	check_eq("E: tool error tag", str(tool_result.get("error", "")), "pcb_backend_stopped")
	check_eq("E: recovery hint", str(tool_result.get("recovery_hint", "")), "start via minerva_plugin_start")
	check("E: detail carries the plugin_not_running kind",
		str(tool_result.get("detail", {}).get("kind", "")) == "plugin_not_running",
		str(tool_result))
	check("E: board unmutated by the sabotaged call — trace count unchanged",
		data.get_trace_count() == traces_before_e,
		"before=%d after=%d" % [traces_before_e, data.get_trace_count()])

	# Human-actionable shape: the Propose button's status label.
	await _click_propose_button()
	check_eq("E: status label shows the backend-stopped affordance", panel._status_label.text,
		"Routing needs the pcb backend — it's stopped. Start it from the Plugin Manager, then retry.")

	panel.request.disconnect(sabotage.on_request)
	sabotage.queue_free()
	await process_frame

	check("E: fresh hint still open (never consumed by the failed attempt)",
		str(host.get_by_id(fresh_hint_id).get("lifecycle", "")) == "open")

	# FINDING (not a C5 regression — pre-existing route_board() behavior):
	# PCBPanel.route_board() gathers EVERY pcb_route_hint annotation on the
	# host into the IPC request regardless of the selection/hint_ids scope
	# the caller passed — only _gather_route_hints' SOURCE-hint bookkeeping
	# (consumed ids / width lookup) is scoped by hint_ids; the routes a
	# router reply contains are all materialized unconditionally. Left open,
	# this leftover hint would make F's explicit hint_ids=[sig2] commit also
	# re-route (and re-materialize a duplicate trace for) net SIG. Clean it
	# up so F's assertions measure ONLY its own net, matching how a real user
	# would also want to resolve/redraw a stale failed-propose hint before
	# moving on rather than have it silently ride along on the next call.
	host.remove_annotation(fresh_hint_id)


# ── F: bulk commit=true regression — shared machinery, delete-on-commit intact ─

func _test_f_bulk_commit_regression() -> void:
	print("-- F: bulk apply_route_hints commit=true regression (shared machinery) --")

	var u3 = data.new_component()
	u3.id = "U3"
	u3.position = U3_PIN1
	u3.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(u3)

	var u4 = data.new_component()
	u4.id = "U4"
	u4.position = U4_PIN1
	u4.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(u4)

	data.connect_pin_to_net("SIG2", "U3", "1")
	data.connect_pin_to_net("SIG2", "U4", "1")

	var env: Dictionary = host.build_route_hint_envelope(
		U3_PIN1.x, U3_PIN1.y, "", "F.Cu", "single_trace",
		[], "human", "", 0.3, ["U3.1"], ["U4.1"])
	var sig2_hint_id := str(host.add_annotation_v2(env))
	check("F: SIG2 hint seeded", not sig2_hint_id.is_empty())

	var traces_before: int = data.get_trace_count()

	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	# Explicit hint_ids scopes which ANNOTATION counts as a source hint (so
	# ONLY sig2_hint_id can be consumed/deleted), immune to any hint residue
	# left by earlier scenarios. It does NOT scope which board NETS the
	# worker routes — FINDING (pre-existing, not a C5 regression): board_to_
	# router() (route_bridge.py) builds the router's Board from the
	# canonical board's components/nets only, never reading `traces` — so it
	# has no notion of "already wired" and route_board()/route_board_with_
	# hints() re-route EVERY net on the board with >=2 pads, including SIG
	# (already real-traced by scenario D). traces_added can therefore be >1
	# here; the assertions below check what THIS deliverable actually
	# promises — the SIG2 net got exactly one trace and its hint followed
	# the delete-on-commit contract — not the worker's total trace count.
	var result: Dictionary = await panel.handle_tool("minerva_pcb_apply_route_hints", {
		"hint_ids": [sig2_hint_id], "commit": true,
	})
	check("F: commit ok", bool(result.get("success", false)), str(result))
	check("F: committed flag true", bool(result.get("committed", false)))
	check("F: at least one trace added", int(result.get("traces_added", 0)) >= 1, str(result))
	check("F: board trace count did not decrease",
		data.get_trace_count() >= traces_before,
		"before=%d after=%d" % [traces_before, data.get_trace_count()])

	var sig2_traces: Array = data.get_traces_for_net("SIG2")
	check("F: exactly one SIG2 trace exists", sig2_traces.size() == 1, "count=%d" % sig2_traces.size())

	# MF-2(b2) UNIFIED (narrow re-review, moved pin): "delete-on-commit" was
	# the LEGACY-era reading; the owner-visible contract is open→applied,
	# never delete — _materialize_routes (this bulk commit=true path) now
	# closes the same way minerva_pcb_workspace_commit does.
	check("F: SIG2 hint consumed", (result.get("consumed_hint_ids", []) as Array) == [sig2_hint_id],
		"got %s" % str(result.get("consumed_hint_ids", [])))
	var sig2_hint_after: Dictionary = host.get_by_id(sig2_hint_id)
	check("F: SIG2 hint SURVIVES commit (not deleted)", not sig2_hint_after.is_empty())
	check_eq("F: SIG2 hint lifecycle closed: open -> applied",
		str(sig2_hint_after.get("lifecycle", "")), "applied")

	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame


# ── helpers ────────────────────────────────────────────────────────────────

func _points_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if (a[i] as Vector2).distance_to(b[i] as Vector2) > 0.01:
			return false
	return true


func _reversed(a: Array) -> Array:
	var out := a.duplicate()
	out.reverse()
	return out


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


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)
