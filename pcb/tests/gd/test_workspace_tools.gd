extends SceneTree
## C4a (S4) — routing-workspace VERB layer: the ten minerva_pcb_workspace_* tool
## contracts, the composite COMMIT transaction (INV-1), the stale-on-every-verb
## matrix (INV-2), the PATH-SCOPED via edit (INV-3), and the eraser adjudication.
##
## ── UN-PARKED at the epoch-C boundary (Station 1, un-park + execute) ───────────
## Moved from pcb/tests/pending/ into pcb/tests/gd/ and added to EXPECTED_SUITES
## — it now runs as part of the normal run-gd-tests.sh sweep.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the
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
##  11. ROUTE-REQUEST EXTRA (DCR finding 7, docket 019fc1b0db34): a pinned
##      active candidate makes `pinned_candidates` reach the router; an
##      explicit `scope` reaches it from a reroute's task/net and from a
##      propose whose selected hint names its net; and an unpinned/unscoped
##      call still builds the pre-existing byte-identical request.
##  20. EPOCH UX1 STATION 10 — minerva_pcb_workspace_edit_candidate: move_junction
##      moves every coincident endpoint (and via) on ONE path atomically, refuses
##      ambiguous_junction across disconnected paths sharing near-coincident
##      points, refuses degenerate_result rather than emitting zero-length
##      copper; expected_candidate_revision guards BOTH ops before any mutation;
##      insert_via delegates verbatim to RoutingWorkspace.add_via (refusals pass
##      through); a terminal candidate refuses either op; and a successful edit
##      never touches the candidate's task/routing_constraint (edit != policy).
##  21. EPOCH UX1 STATION 11 — "Replies name legal successors": a compact GATE
##      (string-contains on verb names only) that the guidance `note` key is
##      present and names its expected legal-successor verb(s) on the propose,
##      edit_candidate, commit and reject replies.
##  22. EPOCH UX1 STATION 12 — legacy waypoint-hint migration (DCR 019fd095e694,
##      docket 019fd057ea0b comment 1028, adopted verbatim): a legacy guided
##      hint carrying inline waypoints seeds its task's routing_constraint
##      ONCE at propose time (authored_by "migration", seeded_from_hint_id/
##      _revision provenance, revision 1), task_constraints carries it into
##      the router request, and the hint is stamped superseded; the seed
##      survives a failed router leg (durability, comment 1028); a second
##      propose does not re-seed (revision stays 1); a hint whose task is
##      ALREADY constrained by some other channel is never re-read; a
##      post-seed edit that CHANGES kind_payload.waypoints is refused by
##      PcbAnnotationHost.update_annotation while a non-waypoints edit passes;
##      a 'detailed' hint is untouched by all of it (never seeded, never
##      refused). Fix-round additions (cold review, same DCR): a bus-branch
##      hint carrying waypoints is never seeded (H1-1); the OTHER propose-time
##      entry point (minerva_pcb_apply_route_hints, not just
##      minerva_pcb_workspace_propose) also seeds; the
##      waypoints_superseded_by_constraint_revision marker is HOST-OWNED and
##      is re-injected server-side whenever an update omits it, closing both
##      the accidental-strip and the two-step-bypass shapes (H2-1); the
##      undo/redo seam (_suppress_hint_history) never trips the edit-refusal
##      guard, and the marker's re-injection keeps the guard armed across a
##      restore (H2-2); a hint whose singleton task was absorbed into a
##      MERGED multi-hint task is never re-seeded, constrained or not (H1-2).
##      Codex 1047 fix round, verdict 4 (22m): the NAMED exit —
##      minerva_pcb_hint_convert_to_detailed clears the singly-owned task
##      constraint and, in the SAME call (ordered two-store writes, workspace
##      first — deliberately NOT described as atomic, per verdict 6: the two
##      stores persist in separate sidecars), strips the marker + verdict-5
##      lock fields (_locked_fields/_lock_reason, stamped beside the marker
##      for core's offline live_editor_required refusal), sets detail_level
##      'detailed', re-permits waypoint edits, and a fresh propose never
##      re-seeds; refuses by name on an unstamped hint (not_superseded) and
##      on a merged-task-owned constraint (constraint_not_singly_owned).
##      Codex 1047 fix round, verdict 6 (22n): BOTH torn-save permutations of
##      the constraint+marker pair are repaired by deterministic load-time
##      reconciliation (reconcile_superseded_waypoint_state — workspace
##      constraint store authoritative, marker derived): marker-without-
##      constraint strips marker+locks preserving detail_level as found,
##      constraint-without-marker re-stamps at the constraint's revision
##      (locks included — doubling as the pre-lock-era backfill); every
##      repair emits a structured record (the supported contract) on
##      workspace.last_load_reconciliation, creates NO undo history, and a
##      second pass is a no-op (idempotence).
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
## Group 11's board-net seeding needs a NET OBJECT, not a name — add_net(name)
## silently blows up on `net.name` (same gotcha test_pcb_panel_tools.gd's
## _declare_net documents), hence load() + set .name rather than a string arg.
const PCB_NET_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_net.gd"
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
	await _run_route_request_extra()
	await _run_cross_candidate_check_reply()
	await _run_review_and_honesty_batch()
	await _run_hint_status_placement()
	await _run_ux1_additive_reply_keys()
	await _run_ux1_batch_commit_tool()
	await _run_ux1_add_route_intent()
	await _run_station9_task_constraints()
	_run_station10_edit_candidate()
	_run_ux2_route_quality_metrics()
	await _run_ux1_station11_next_step_guidance()
	await _run_station12_legacy_seeding()
	await _run_board_health_and_commit_gate()
	await _run_ux3_freeze_tools()
	await _run_ux3_witness_selection_read()
	await _run_ux3_commit_dialog()
	await _run_ux3_reclaim_menu()
	await _run_ux3_reverse_parity()
	_run_copper_loss_reconcile()
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


## A real source-hint annotation whose kind_payload.net_names ACTUALLY names
## `net` (group 11's _propose_scope needs a hint the panel can read a net off
## directly — the default _seed_source_hint above builds a bare waypoint with
## no net_names at all, resolvable only worker-side via source/dest pins).
## Returns the hint id.
func _seed_net_named_hint(host, net: String) -> String:
	var env: Dictionary = host.build_route_hint_envelope(
		0.0, 0.0, "", "F.Cu", "waypoint", [[0.0, 0.0], [5.0, 0.0]], "human")
	var kp: Dictionary = env.get("kind_payload", {})
	kp["net_names"] = [net]
	env["kind_payload"] = kp
	return str(host.add_annotation_v2(env))


## A real BUS-type source-hint annotation whose net_names lists TWO real nets
## (review fix c2-epochD: route_bridge.hints_to_router gives hint_type=="bus"
## hints a DIFFERENT resolution rule than _net_for_hint — EVERY present
## net_names entry, not just [0] — so _propose_scope/_reroute_scope must
## recognize and bail on this shape rather than mirror the single-net rule
## against it). Returns the hint id.
func _seed_bus_hint(host, net_a: String, net_b: String) -> String:
	var env: Dictionary = host.build_route_hint_envelope(
		0.0, 0.0, "", "F.Cu", "waypoint", [[0.0, 0.0], [5.0, 0.0]], "human")
	var kp: Dictionary = env.get("kind_payload", {})
	kp["hint_type"] = "bus"
	kp["net_names"] = [net_a, net_b]
	env["kind_payload"] = kp
	return str(host.add_annotation_v2(env))


## Declare a net ON THE BOARD (PCBData.nets), not just in a candidate/route
## fixture — review fix c2-epochD's board-membership check
## (_propose_scope/_reroute_scope's `board_nets`) reads PCBData.get_net_names(),
## which candidate/route fixtures like _multipad_record never touch. Same
## add_net(name-object-not-string) gotcha test_pcb_panel_tools.gd's
## _declare_net documents.
func _declare_net(data, net_name: String) -> void:
	var net = load(PCB_NET_PATH).new()
	net.name = net_name
	data.add_net(net)


## Forward every host call the workspace tools make to the REAL host, and answer
## the ROUTER hop with a fixture. This is the one substitution in the panel
## groups — the router worker is Python and does not run under the gd scaffold.
class RouterShim extends RefCounted:
	var real
	var reply: Dictionary = {}
	var calls: Array = []
	## Station 9 durability test (docket 019fd057ea0b comment 1028): flip to
	## false to make run_router answer worker_unavailable WITHOUT touching the
	## canned `reply` — proves a task's steering write survives a router leg
	## that never lands a candidate. Every existing caller leaves this at its
	## default (true), so their requests are unaffected.
	var answer_ok: bool = true

	func _init(real_host, router_reply: Dictionary) -> void:
		real = real_host
		reply = router_reply

	## `extra` (DCR finding 7 — scope/pinned_candidates) recorded ALONGSIDE
	## selection, not merged into it: a caller asserting "the request panel_tools
	## built" needs to tell "no scope/pinned_candidates were computed" (extra
	## == {}) apart from "selection itself happened to be empty", which a merge
	## would blur.
	func run_router(selection: Dictionary, extra: Dictionary = {}) -> Dictionary:
		calls.append({"selection": selection, "extra": extra})
		if not answer_ok:
			return {"ok": false, "error": {"kind": "worker_unavailable", "message": "forced test failure"}}
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

	## F2 (cold review, Epoch UX1 station 9): forwarded so
	## _stamp_waypoints_superseded's host.update_annotation call reaches the
	## REAL host through this shim, same as every other duck-typed call above.
	func update_annotation(id: String, new_annotation: Dictionary) -> bool:
		return bool(real.update_annotation(id, new_annotation))

	## UX2 station 2 (cold review F1): forwarded so clear_constraint's
	## synchronous marker strip reaches the REAL host's sanctioned release —
	## without this the strip degrades (has_method false) to the lazy
	## load-time reconcile and 19j's stripped-marker assertion goes red.
	func reconcile_strip_superseded_marker(hint_id: String) -> Dictionary:
		return real.reconcile_strip_superseded_marker(hint_id)

	## DCR 019fd5fd9084 (work item 019fd5fe2724): the placement verbs call
	## host.assembly_check after mutating. A canned `assembly_reply` SIMULATES
	## the worker contract's {ok, result:{status, findings, ...}} envelope
	## (the worker is Python — same substitution rationale as run_router);
	## left {} it forwards to the REAL host, whose panel has no IPC headless,
	## so the verbs degrade to the honest tri-state indeterminate — the real
	## bridge chain, exercised end to end minus the wire.
	var assembly_reply: Dictionary = {}
	var assembly_calls: int = 0

	func assembly_check(board: Dictionary) -> Dictionary:
		assembly_calls += 1
		if not assembly_reply.is_empty():
			return assembly_reply
		return await real.assembly_check(board)

	## Forwarded for the placement-verb group (23e): _move_relative resolves
	## the spatial index through host.get_spatial_index — same duck-typed
	## forwarding as get_board_data above.
	func get_spatial_index():
		return real.get_spatial_index()


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
	# The board declares a trace width, as every authored board does. The
	# multipad fixture reply carries no width of its own, so this design rule is
	# what sizes its copper — the last rung of the width ladder, and the reason
	# a widthless reply is committable here. The one group that tests the
	# ladder's END (_run_ux1_width_provenance) clears it deliberately.
	panel.get_data().design_rules = {"trace_width_mm": 0.3}
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
	# begin_check FIRST — this is not ceremony. apply_check_result's GUARD 3
	# (pcb_routing_workspace.gd) discards, per candidate, any verdict for a
	# candidate that is not in the CURRENT in-flight check: `_pending_check`
	# holds the revision+prior snapshot begin_check took, and an empty snapshot
	# means "nobody asked for this candidate", which is a reply that must never
	# set a verdict or store a finding. Calling apply_check_result cold — as this
	# group did when it was authored — therefore stores nothing BY DESIGN, and
	# the drop assertion below would then pass vacuously (0 == 0). Drive the real
	# two-step and echo the payload's own coherence tokens, the same pattern
	# test_workspace_check.gd's _fixture/_matching_reply use.
	var check_payload: Dictionary = f["ws"].begin_check([f["b"]])
	check("begin_check enrolled the candidate under test",
		(check_payload.get("candidates", []) as Array).size() == 1)
	f["ws"].apply_check_result({
		"board_token": check_payload.get("board_token", ""),
		"workspace_generation": check_payload.get("workspace_generation", -1),
		"per_candidate": {f["b"]: "violating"},
		"findings": [{"type": "crossing", "subjects": [{"candidate_id": f["b"], "segment_id": "seg_1"}]}],
	})
	check_eq("the verdict landed", str(f["ws"].get_candidate(f["b"]).validation), "violating")
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
	# 2..8 = the verbs. A separator IS an item in a PopupMenu's item_count,
	# so an index map that forgot it would read Commit's state off the separator.
	# GREW TWICE in Epoch UX3: station 1 added the Freeze/Unfreeze slot (index
	# 4), station 5 added Retry with corridor… (7) and Clear steering (8).
	var state: Array = _menu_state(canvas, cid)
	var labels: Array = state[0]
	var disabled: Array = state[1]
	check_eq("the seam offers identity + separator + seven verbs", labels.size(), 9)
	check("the identity line is disabled (it is a label, not an action)", bool(disabled[0]))
	check_eq("index 1 is the separator (empty text)", str(labels[1]), "")
	check_eq("verb 1 is Commit", str(labels[2]), "Commit")
	check_eq("verb 2 is Pin (the slot shows the move that is available)", str(labels[3]), "Pin")
	check_eq("verb 3 is Freeze (station 1's slot)", str(labels[4]), "Freeze")
	check_eq("verb 4 is Reject", str(labels[5]), "Reject")
	check_eq("verb 5 is Try again", str(labels[6]), "Try again")
	check_eq("verb 6 is Retry with corridor…", str(labels[7]), "Retry with corridor…")
	check_eq("verb 7 is Clear steering", str(labels[8]), "Clear steering")
	check("every state-gated verb is ENABLED for a proposed candidate",
		not bool(disabled[2]) and not bool(disabled[3]) and not bool(disabled[4])
		and not bool(disabled[5]) and not bool(disabled[6]) and not bool(disabled[7]))
	check("Clear steering is GREYED — this task carries no routing constraint",
		bool(disabled[8]))

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
	check_eq("…and the freeze slot still offers Freeze (pinned → frozen is legal)",
		str((_menu_state(canvas, cid)[0] as Array)[4]), "Freeze")

	# COMMIT through the menu handler — station 7 rewired the mouse commit
	# through the PANEL's GATED tool (candidate_commit_requested →
	# _on_candidate_commit_requested → minerva_pcb_workspace_commit): the old
	# direct workspace.commit bypassed the placement gate. The chain is
	# SYNCHRONOUS end-to-end for this arm (no await suspends on the commit
	# path), so the copper is on the board when the press returns. The canvas
	# narrates INTENT on its message channel; the OUTCOME lands on the panel
	# status bar (the gated tool's reply, narrated by _narrate_commit_success).
	_messages.clear()
	canvas._on_context_menu_pressed(canvas.MENU_ID_CANDIDATE_COMMIT)
	check_eq("the menu's Commit wrote one trace per segment",
		int(ctx["data"].traces.size()), traces_before + 3)
	check_eq("it wrote the via", int(ctx["data"].vias.size()), 1)
	check_eq("the candidate is committed", str(ws.get_candidate(cid).disposition), "committed")
	check_eq("intent was narrated on the canvas channel", _messages.size(), 1)
	check("…naming the act in progress", str(_messages[0]).contains("Committing"))
	var commit_status: Variant = ctx["panel"].find_child("StatusBar", true, false)
	check("the OUTCOME landed on the status bar, from the gated tool's reply",
		commit_status != null and str(commit_status.text).contains("Committed"))

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
	check("Freeze is disabled on a committed candidate", bool(after_disabled[4]))
	check("Reject is disabled on a committed candidate", bool(after_disabled[5]))
	check("Try again is disabled on a committed candidate", bool(after_disabled[6]))
	check("Retry with corridor… is disabled on a committed candidate", bool(after_disabled[7]))
	check("Clear steering is disabled on a committed candidate", bool(after_disabled[8]))

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
	# SR2FAB S6: this scaffold's panel has no _MinervaIPC bridge at all, which
	# is a DIFFERENT fault from "the worker did not answer" and used to be
	# reported as the same one. It names itself now.
	check_eq("and the missing worker bridge is its own named envelope",
		str(forced.get("error", "")), "draft_check_unavailable")
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
	# This is a count of ALL manifest.json tools[] entries (names.size() above
	# iterates every tool, not just worker-backed ones) — it moves whenever
	# ANY tool is added or removed, not only on a proposal-tool-removal-shaped
	# change. 69 = 70 - the 2 S5-removed proposal tools + minerva_pcb_route_bus_direct.
	# The pin was WRITTEN at 68 (post-C4b, when this suite was parked) and C5
	# landed the bus tool afterwards, so the number was stale on the day this
	# suite first EXECUTED — not a regression. Verified against manifest.json's
	# own tail entry (`minerva_pcb_route_bus_direct`), which is the C5 addition.
	# + 1 D0-5 worker-backed tool (minerva_pcb_export_assembly, docket
	# 019fc2f8b903) == 70, + 1 bus-propose tool
	# (minerva_pcb_workspace_propose_bus, docket 019fcac1509d) == 71, + 1 Epoch
	# UX1 station 8 tool (minerva_pcb_add_route_intent, DCR 019fd095e694) == 72,
	# + 1 Epoch UX1 station 10 tool (minerva_pcb_workspace_edit_candidate, the
	# ONE discriminated candidate-edit verb, DCR 019fd095e694) == 73,
	# + 1 Codex-1047 verdict-4 tool (minerva_pcb_hint_convert_to_detailed,
	# the named guided->detailed conversion) == 74,
	# + 1 HITL-6b tool (minerva_pcb_get_selection — the deictic read behind
	# "I've selected X, what is it?", docket 019fdf5579) == 75,
	# + 2 Epoch UX3 station-1 tools (minerva_pcb_workspace_freeze/_unfreeze —
	# K7's settlement verb pair, docket 019fdf913513) == 77,
	# + 5 Epoch UX3 station-10 tools (point, hint_move/insert/delete_bend,
	# clear_hints_by_author — docket 019fdf9101b5) == 82,
	# + 1 Epoch UX3 station-11 tool (minerva_pcb_promote — K13's gated
	# serialize-back verb, docket 019fdf91b3ac) == 83,
	# + 5 Epoch UX4 station-8 tools (the STAGING family — propose_zone/
	# propose_cutout/staged_list/staged_accept/staged_reject, DCR
	# 019fe07523ca S8) == 88,
	# + 4 Epoch LIB1 tools (station-3's rendered-bless trio footprint_stage/
	# footprint_report/footprint_bless + station-4's acquire_footprint, DCR
	# 019ff567f66b B2/B3) == 92,
	# + Epoch LIB2 station-1's footprint_promote (B7, docket 019ff7c02fd6:
	# the bless gate's exit door into the durable user layer) == 93,
	# + Epoch LIB2 station-2's import_footprint (B4, docket 019ff568b56b: the
	# arbitrary-source supply chain — git/URL/vendor-export bytes staged
	# UNBLESSED, never auto-trusted) == 94,
	# + the placement-coworking SPIKE's propose_placement + placement_update
	# (staged component-move ghosts, docket 019ff8615fbe) == 96,
	# + Epoch OFC station-4's board_check (the live-board census, promote's
	# read-only twin — docket 019ff942beb4) == 97,
	# + Epoch GA-1's set_board_layers (the N-layer stack declaration verb,
	# docket 019ffa0f404b) == 98. GA-1 bumped the sibling pin
	# (test_manifest_tool_registration.gd, own commit 812bb63) and MISSED this
	# second seat — caught at the GA testex, which is exactly what a second
	# independent pin is for.
	# This is a SECOND, independent count pin on the same manifest.json this
	# round's tools[] addition touches — see
	# tests/gd/test_manifest_tool_registration.gd's own pin (94->96 over the
	# same station) for the "deliberate bump, its own diff"
	# convention this follows.
	# Epoch GA round 2 (98 -> 100): minerva_pcb_staged_freeze +
	# minerva_pcb_staged_unfreeze, K7's freeze doorway. This pin exists
	# BECAUSE the sibling pin in test_manifest_tool_registration.gd counts a
	# different set (registered tools) and can agree while this one is wrong.
	# Epoch NLC C4 (101 -> 102): minerva_pcb_view_state (item 019ffeaccc0c).
	# Epoch NLC C2 (102 -> 103): minerva_pcb_place_via (item 019fff60e05a) —
	# the direct board via that closes the create/destroy parity gap.
	# Epoch NLC C3 (103 -> 104): minerva_pcb_add_trace (item 01a001c39aa3).
	# DCR 01a0033a12a9 (104 -> 105): minerva_pcb_propose_via, the Proposals-area
	# twin of place_via — a via is an entity, so proposing one proposes an entity.
	# DCR 01a0033a12a9 change 2 (105 -> 106): minerva_pcb_update_via — place,
	# delete and list existed; nothing could ADJUST a placed via, so an agent
	# could delete and re-create one (losing its id) but never move or re-net it.
	# DCR 01a0033a12a9 change 3 (106 -> 107): minerva_pcb_fabrication_stage —
	# the board's declared manufacturing intent, so a via-only board can report
	# its unrouted nets as the job rather than as a wall of defects.
	# SR2FAB (107 -> 109): minerva_pcb_export_yaml and
	# minerva_pcb_list_mounting_holes. Both executor:"panel", so the Go pin at
	# 19 backend tools is unaffected.
	# (109 -> 110): minerva_pcb_cut_trace, executor:"panel"; the Go pin stays.
	# (110 -> 112): minerva_pcb_undo / minerva_pcb_redo, the board history's
	# verb twins of Ctrl+Z / Ctrl+Shift+Z; executor:"panel", the Go pin stays.
	# (112 -> 113): minerva_pcb_board_drc, the live-board DRC verb;
	# executor:"panel", the Go pin stays.
	# STALE-PIN CORRECTION, found by this station: the disconnect_net round
	# bumped the sibling pin in test_manifest_tool_registration.gd from 113 to
	# 114 and left THIS one at 113, so this check has been failing against
	# main ever since — the exact "only one of the two pins moved" failure the
	# comment above warns about. 113 -> 114 (disconnect_net) -> 118 (the pad
	# family: free_pins, move_net, swap_nets, select).
	# 119 -> 122: the board-graphics family — minerva_pcb_add_silk_text,
	# minerva_pcb_add_graphic, minerva_pcb_delete_graphic.
	# DERIVED by COUNTING manifest.json's tools[], not measured on a run. Its
	# twin in test_manifest_tool_registration.gd moves with it.
	# 122 -> 123: minerva_pcb_board_rules, the Options menu's verb twin.
	# executor:"panel", so the Go pin at 19 backend tools is unaffected.
	# 123 -> 124: minerva_pcb_set_refdes, the designator-anchor verb.
	# executor:"panel", so the Go pin at 19 backend tools is unaffected.
	check_eq("manifest tool count == 124 (ALL manifest.json tools[] entries)",
		names.size(), 124)
	check("the C4 view-state tool is one of the additions THIS count accounts for",
		"minerva_pcb_view_state" in names)
	check("the C2 place-via tool is another",
		"minerva_pcb_place_via" in names)
	check("the C3 add-trace tool is the third",
		"minerva_pcb_add_trace" in names)
	check("the C5 bus tool is the addition this count accounts for",
		"minerva_pcb_route_bus_direct" in names)
	check("the bus-propose tool is the addition THIS count accounts for",
		"minerva_pcb_workspace_propose_bus" in names)
	check("the station-8 route-intent tool is the addition THIS round's count accounts for",
		"minerva_pcb_add_route_intent" in names)
	check("the station-10 candidate-edit tool is the addition THIS round's count accounts for",
		"minerva_pcb_workspace_edit_candidate" in names)

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
	# UX4 station 10 (HITL-3 nit 5, docket 019fce3ac3): this used to read
	# panel._status_label.text on an UNMOUNTED panel — _status_label is Nil
	# there, so GDScript printed a SCRIPT ERROR and SKIPPED the statement
	# while the suite still reported 0 failed: every green run was one
	# assertion lighter than it claimed. Asserted through the panel's
	# mount-independent notice seam instead (the same value the status label
	# renders from when mounted).
	if panel.has_method("get_last_legacy_drop_notice"):
		var notice := str(panel.get_last_legacy_drop_notice())
		check("drop: the load notice names the legacy proposal drop (got '%s')" % notice,
			notice.find("legacy route proposal") != -1)
	else:
		# Fallback pin: the drop COUNT seam (already asserted above) is the
		# mount-independent half; the prose seam does not exist on this
		# panel build — say so rather than silently skipping.
		check("drop: notice seam present (get_last_legacy_drop_notice)", false)

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
	check("annotations list is non-vacuous (the seeded hint annotation is present)",
		(list_result.get("annotations", []) as Array).size() >= 1)
	var any_drc_via_mcp := false
	for a in (list_result.get("annotations", []) as Array):
		if a is Dictionary and (a as Dictionary).get("kind_payload", {}).has("drc"):
			any_drc_via_mcp = true
	check("no annotation carries kind_payload.drc post-S5 (nothing left to carry it)",
		not any_drc_via_mcp)
	AnnotationHostRegistry._reset_for_test()

	ctx["driver"].free_panel(ctx["panel"])


# ══ 11. ROUTE-REQUEST EXTRA: pinned_candidates + scope reach the router ═══════
# (DCR finding 7, docket 019fc1b0db34 — PCBPanel.route_board previously sent
# only {board, route_hints, selection}; C2 shipped `scope` and
# `pinned_candidates` worker-side and nothing on the GD side reached them.)
#
# `shim.calls` (RouterShim, see the fixtures above) records EVERY run_router
# call as {"selection":…, "extra":…} — the exact two arguments panel_tools.gd
# built and handed to the router bridge, i.e. "the built request" this group
# asserts on. Reading the LAST call after each tool invocation isolates that
# call's own request from whatever earlier calls in the same context recorded.

func _run_route_request_extra() -> void:
	print("-- 11. route-request extra: pinned_candidates + scope --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]

	# ── BASELINE: nothing pinned, no explicit-hint selection -> the
	# pre-existing {mode:"open"} selection; extra carries EXACTLY the
	# draft_request marker (Epoch UX4 station 3: every candidate-producing
	# propose is a DRAFT request — the marker is panel-side, and route_board's
	# allow-list keeps it off the wire) and nothing else (no "scope", no
	# "pinned_candidates").
	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose (nothing pinned) succeeded", bool(first.get("success", false)))
	var call_a: Dictionary = shim.calls[shim.calls.size() - 1]
	check_eq("open propose: selection unchanged", call_a.get("selection", {}), {"mode": "open"})
	var extra_a: Dictionary = call_a.get("extra", {})
	check_eq("open propose: extra is EXACTLY the draft marker (UX4 st.3)",
		extra_a.size(), 1)
	check_eq("…draft_request true", bool(extra_a.get("draft_request", false)), true)
	var cid := str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	check("propose landed a candidate to pin", not cid.is_empty())

	# ── PINNED-ACTIVE: pin it, propose again (still no explicit hint_ids/scope)
	# -> pinned_candidates appears in the request, alone.
	var pinned: Dictionary = PanelTools._workspace_pin(shim, _args({"candidate_id": cid}))
	check("pin succeeded", bool(pinned.get("success", false)))
	var held: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose (one pinned) still succeeded", bool(held.get("success", false)))
	var call_b: Dictionary = shim.calls[shim.calls.size() - 1]
	var extra_b: Dictionary = call_b.get("extra", {})
	check("pinned-active propose: request carries pinned_candidates", extra_b.has("pinned_candidates"))
	check("pinned-active propose: request carries NO scope (open selection, HALF-mutation isolation)",
		not extra_b.has("scope"))
	var pinned_wire: Array = extra_b.get("pinned_candidates", [])
	check_eq("pinned_candidates names exactly the pinned candidate", pinned_wire.size(), 1)
	if pinned_wire.size() == 1:
		var pw: Dictionary = pinned_wire[0]
		check_eq("pinned wire candidate_id matches", str(pw.get("candidate_id", "")), cid)
		check_eq("pinned wire net matches", str(pw.get("net", "")), "N1")
		check_eq("pinned wire carries the candidate's 3 segments",
			(pw.get("segments", []) as Array).size(), 3)
		check_eq("pinned wire carries the candidate's 1 via",
			(pw.get("vias", []) as Array).size(), 1)
		check("pinned wire is the SAME candidate language as draft_check (ir_candidates.build_overlay)",
			pw.has("revision") and pw.has("segments") and pw.has("vias"))

	# ── SCOPE FROM A TASK (reroute): the candidate is still pinned, so this
	# request carries BOTH keys — scope is asserted independently of the
	# pinned_candidates checks above (HALF-mutation isolation the other way).
	var task_id_before := str(ws.get_candidate(cid).task_id)
	var reroute_out: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({"candidate_id": cid}))
	check("reroute succeeded", bool(reroute_out.get("success", false)))
	var call_c: Dictionary = shim.calls[shim.calls.size() - 1]
	var extra_c: Dictionary = call_c.get("extra", {})
	check("reroute: request carries an explicit scope", extra_c.has("scope"))
	var scope_c: Dictionary = extra_c.get("scope", {})
	var tasks_c: Array = scope_c.get("tasks", [])
	check_eq("reroute scope names exactly one task", tasks_c.size(), 1)
	if tasks_c.size() == 1:
		var t: Dictionary = tasks_c[0]
		check_eq("reroute scope task_id matches the candidate's own task", str(t.get("task_id", "")), task_id_before)
		check_eq("reroute scope net matches the candidate's own net", str(t.get("net", "")), "N1")
		check("reroute scope names no endpoints (whole net, never a span)", not t.has("endpoints"))
	check("reroute: request ALSO still carries pinned_candidates (both channels wire independently)",
		extra_c.has("pinned_candidates"))

	ctx["driver"].free_panel(ctx["panel"])

	# ── SCOPE FROM SELECTED HINTS (propose): a fresh, unpinned context where the
	# explicitly-selected hint names its net via kind_payload.net_names — the
	# ONE case panel_tools.gd can assert completely (see _propose_scope).
	var ctx2: Dictionary = await _panel_context()
	var shim2 = ctx2["shim"]
	var host2 = ctx2["host"]
	var data2 = ctx2["data"]
	_declare_net(data2, "N1")
	var net_hint_id: String = _seed_net_named_hint(host2, "N1")
	var scoped_out: Dictionary = await PanelTools._workspace_propose(
		shim2, _args({"hint_ids": [net_hint_id]}))
	check("hint-scoped propose succeeded", bool(scoped_out.get("success", false)))
	var call_d: Dictionary = shim2.calls[shim2.calls.size() - 1]
	var extra_d: Dictionary = call_d.get("extra", {})
	check("hint-scoped propose: request carries an explicit scope", extra_d.has("scope"))
	var nets_d: Array = (extra_d.get("scope", {}) as Dictionary).get("nets", [])
	check_eq("hint-scoped propose scope names exactly one net", nets_d.size(), 1)
	if nets_d.size() == 1:
		check_eq("hint-scoped propose scope names N1", str(nets_d[0]), "N1")
	check("hint-scoped propose: request carries NO pinned_candidates (fresh, nothing pinned)",
		not extra_d.has("pinned_candidates"))

	ctx2["driver"].free_panel(ctx2["panel"])

	# ── REVIEW FIX (c2-epochD): the 3 PROVEN consequences of unioning the whole
	# net_names array instead of mirroring route_bridge._net_for_hint /
	# hints_to_router's bus branch exactly. Each case is a request-shape
	# assertion the SAME way the ones above are — no live worker involved (the
	# RouterShim answers every call with the canned multipad reply regardless
	# of args), so these prove what THIS PANEL builds, matching what the real
	# route_bridge.py functions cited in each comment actually do.

	# ── CASE 1 — STALE names[0]: net_names[0] names a net the board does NOT
	# have. route_bridge._net_for_hint trusts names[0] only if `names[0] in
	# board.nets`; otherwise it WARNS and falls through to source/dest pin
	# resolution — which could easily resolve to a DIFFERENT, real net. A scope
	# built from the stale name regardless (the pre-fix bug) would disagree
	# with whatever the worker actually resolves and hard-refuse
	# (unsupported_scope) a run that used to work unscoped. The fix: bail to
	# unscoped the moment names[0] fails the board-membership check.
	var ctx3: Dictionary = await _panel_context()
	var shim3 = ctx3["shim"]
	var host3 = ctx3["host"]
	var data3 = ctx3["data"]
	_declare_net(data3, "N1")  # the board's REAL net — deliberately NOT named by the hint below
	var stale_hint_id: String = _seed_net_named_hint(host3, "STALE_NET")
	var stale_out: Dictionary = await PanelTools._workspace_propose(
		shim3, _args({"hint_ids": [stale_hint_id]}))
	check("stale-name propose still succeeded (unscoped, same as pre-fix)", bool(stale_out.get("success", false)))
	var call_e: Dictionary = shim3.calls[shim3.calls.size() - 1]
	check("CASE 1 stale-first-name: request carries NO scope (names[0] not on the board)",
		not (call_e.get("extra", {}) as Dictionary).has("scope"))
	ctx3["driver"].free_panel(ctx3["panel"])

	# ── CASE 2 — TWO-NAME WIDENING: a NON-bus hint whose net_names carries TWO
	# real, board-present nets. _net_for_hint trusts ONLY names[0] — a hint is
	# never multi-net unless hint_type=="bus" (hints_to_router). The pre-fix
	# bug unioned the WHOLE array into scope.nets; methods.py:~1778's
	# disagreement check then PASSES (the worker's one resolved net is a
	# subset of the too-wide scope) and OVERWRITES only_nets with the full
	# scope — silently routing the second net too, copper nobody asked for.
	# The fix: take names[0] only, never the rest of the array.
	var ctx4: Dictionary = await _panel_context()
	var shim4 = ctx4["shim"]
	var host4 = ctx4["host"]
	var data4 = ctx4["data"]
	_declare_net(data4, "N1")
	_declare_net(data4, "N2")
	# A non-bus hint (hint_type stays the "waypoint" default) whose net_names
	# names TWO real, board-present nets — built directly rather than via
	# _seed_net_named_hint (which only ever sets one name).
	var two_name_env: Dictionary = host4.build_route_hint_envelope(
		0.0, 0.0, "", "F.Cu", "waypoint", [[0.0, 0.0], [5.0, 0.0]], "human")
	var two_name_kp: Dictionary = two_name_env.get("kind_payload", {})
	two_name_kp["net_names"] = ["N1", "N2"]
	two_name_env["kind_payload"] = two_name_kp
	var two_name_hint_id: String = str(host4.add_annotation_v2(two_name_env))
	var widen_out: Dictionary = await PanelTools._workspace_propose(
		shim4, _args({"hint_ids": [two_name_hint_id]}))
	check("two-name propose still succeeded", bool(widen_out.get("success", false)))
	var call_f: Dictionary = shim4.calls[shim4.calls.size() - 1]
	var scope_f: Dictionary = (call_f.get("extra", {}) as Dictionary).get("scope", {})
	var nets_f: Array = scope_f.get("nets", [])
	check_eq("CASE 2 two-name-widening: scope names exactly ONE net (names[0] only, never both)",
		nets_f.size(), 1)
	if nets_f.size() == 1:
		check_eq("CASE 2: the one net named is N1 (names[0]), never N2",
			str(nets_f[0]), "N1")
	ctx4["driver"].free_panel(ctx4["panel"])

	# ── CASE 3 — BUS-HINT REROUTE REFUSAL: a candidate whose SOLE source hint
	# is a bus hint naming two real nets (N1, N2). Selecting that hint (a
	# reroute always selects the candidate's own source_hint_ids) makes the
	# worker's hint-derived nets include BOTH — route_bridge.hints_to_router's
	# bus branch asks for every present net_names entry, not just this
	# candidate's own. A scope naming only this candidate's single net (the
	# pre-fix behavior) would disagree with that and get hard-refused
	# (unsupported_scope) — for EITHER candidate the bus produced, since both
	# would select the same hint. The fix: recognize the bus hint and skip the
	# scope entirely; the reroute still runs, unscoped.
	var ctx5: Dictionary = await _panel_context()
	var shim5 = ctx5["shim"]
	var host5 = ctx5["host"]
	var data5 = ctx5["data"]
	var ws5 = ctx5["ws"]
	_declare_net(data5, "N1")
	_declare_net(data5, "N2")
	var bus_hint_id: String = _seed_bus_hint(host5, "N1", "N2")
	var bus_cid := str(ws5.ingest_record(_multipad_record([bus_hint_id]), int(data5.board_revision)))
	check("CASE 3 setup: bus-attributed candidate landed", not bus_cid.is_empty())
	var bus_reroute_out: Dictionary = await PanelTools._workspace_reroute_route(
		shim5, _args({"candidate_id": bus_cid}))
	check("bus-hint reroute still succeeded (unscoped, same as pre-fix)",
		bool(bus_reroute_out.get("success", false)))
	var call_g: Dictionary = shim5.calls[shim5.calls.size() - 1]
	check("CASE 3 bus-hint-reroute: request carries NO scope (the bus hint attributes beyond this candidate's own net)",
		not (call_g.get("extra", {}) as Dictionary).has("scope"))
	ctx5["driver"].free_panel(ctx5["panel"])

	# ── CASE 4 — DEGENERATE BUS (review fix c2-epochD, round 2): a bus hint
	# (hint_type=="bus", 2 net_names) where FEWER than 2 of those names are
	# actually present on the board. route_bridge.hints_to_router still ENTERS
	# the bus branch on this hint (entry condition is `hint_type=="bus" and
	# len(names)>=2`, checked BEFORE board presence) and then `continue`s past
	# it having contributed ZERO nets ("bus hint resolved to <2 present nets —
	# skipped") — it does NOT fall back to _net_for_hint's names[0] rule. A
	# first cut of the panel-side check required the bus's PRESENT count to be
	# >=2 before treating it as "a bus", so this exact shape fell through to
	# the names[0] rule and scoped to N1 — a net the worker resolved NOTHING
	# from — which methods.py's disagreement check (0 resolved nets is always
	# a subset) then let overwrite only_nets with. The fix: mirror the
	# worker's BRANCH-ENTRY condition, not the resolved outcome — hint_type
	# =="bus" with >=2 net_names bails scope regardless of how many of those
	# names the board actually has.
	var ctx6: Dictionary = await _panel_context()
	var shim6 = ctx6["shim"]
	var host6 = ctx6["host"]
	var data6 = ctx6["data"]
	var ws6 = ctx6["ws"]
	_declare_net(data6, "N1")  # the ONLY one of the bus's two names present
	var degenerate_bus_hint_id: String = _seed_bus_hint(host6, "N1", "MISSING_NET")
	var degenerate_propose_out: Dictionary = await PanelTools._workspace_propose(
		shim6, _args({"hint_ids": [degenerate_bus_hint_id]}))
	check("degenerate-bus propose still succeeded (unscoped, same as pre-fix)",
		bool(degenerate_propose_out.get("success", false)))
	var call_h: Dictionary = shim6.calls[shim6.calls.size() - 1]
	check("CASE 4 degenerate-bus propose: request carries NO scope (the bus hint resolves to zero nets, not names[0])",
		not (call_h.get("extra", {}) as Dictionary).has("scope"))

	var degenerate_cid := str(ws6.ingest_record(
		_multipad_record([degenerate_bus_hint_id]), int(data6.board_revision)))
	check("CASE 4 setup: degenerate-bus-attributed candidate landed", not degenerate_cid.is_empty())
	var degenerate_reroute_out: Dictionary = await PanelTools._workspace_reroute_route(
		shim6, _args({"candidate_id": degenerate_cid}))
	check("degenerate-bus reroute still succeeded (unscoped, same as pre-fix)",
		bool(degenerate_reroute_out.get("success", false)))
	var call_i: Dictionary = shim6.calls[shim6.calls.size() - 1]
	check("CASE 4 degenerate-bus reroute: request carries NO scope",
		not (call_i.get("extra", {}) as Dictionary).has("scope"))
	ctx6["driver"].free_panel(ctx6["panel"])


# ══ 12. propose reply honesty: cross_candidate_check (docket 019fce3a6c57) ════
#
# A router reply's drc summaries are candidate-vs-board only, so two live
# ghosts crossing each other on one layer read "clean" in every propose reply
# (HITL-3: the GND span shorted BOTH power spans and the user saw it before
# any tool did). The landing path now runs the SAME set-scoped check
# minerva_pcb_workspace_check runs whenever the live set holds >=2 candidates
# and reports it under cross_candidate_check — degrading to a NAMED skip when
# the worker bridge is absent, never failing the landing verb.

func _run_cross_candidate_check_reply() -> void:
	print("-- 12. propose reply honesty: the set-scoped check rides the landing --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]

	# ONE live candidate ⇒ no field at all: a single ghost has no sibling to
	# cross, and the router's own draft DRC already covered candidate-vs-board.
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("single-candidate propose succeeded", bool(out.get("success", false)))
	check("one live candidate ⇒ NO cross_candidate_check field",
		not out.has("cross_candidate_check"))

	# A SECOND task's candidate lands ⇒ live set is 2 and the check must run.
	# This unmounted panel has no _MinervaIPC bridge, so check_draft names that
	# specific fault and the field must carry it — present, honest, non-fatal.
	var hint2: String = _seed_net_named_hint(ctx["host"], "N2")
	shim.reply = {"routes": [{
		"net": "N2",
		"segments": [{"start": [20.0, 0.0], "end": [25.0, 0.0], "layer": "F.Cu"}],
		"vias": [],
		"hint_ids": [hint2],
	}], "via_count": 0}
	var out2: Dictionary = await PanelTools._workspace_propose(
		shim, _args({"hint_ids": [hint2]}))
	check("second propose succeeded", bool(out2.get("success", false)))
	check_eq("the workspace now holds two live candidates",
		(ctx["ws"].live_candidate_ids() as Array).size(), 2)
	check("two live candidates ⇒ cross_candidate_check present",
		out2.has("cross_candidate_check"))
	check_eq("no worker bridge ⇒ the NAMED skip, never a hang or a failure",
		str((out2.get("cross_candidate_check", {}) as Dictionary).get("skipped", "")),
		"draft_check_unavailable")

	ctx["driver"].free_panel(ctx["panel"])


# ══ 13. HITL-3 review + honesty batch ═════════════════════════════════════════
#
# Three fixes from the owner's committed-copper review, one fixture context:
#   a) include_geometry (docket 019fce3ac3f5 item 3): workspace_list/get_active
#      expose a candidate's exact segments/vias — the pre-commit review object.
#   b) commit polyline chaining (docket 019fce6184c2): contiguous same-layer/
#      -width segments land as ONE multi-point trace, not N butt-capped 2-point
#      traces with wedge-gapped corners.
#   c) dangling-copper honesty (docket 019fce619a30): a move whose component
#      had committed copper on its pads names the orphaned trace endpoints in
#      the SAME reply.

func _run_review_and_honesty_batch() -> void:
	print("-- 13. HITL-3 batch: geometry read / commit chaining / dangling copper --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var data = ctx["data"]

	# ── a) include_geometry ───────────────────────────────────────────────────
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose landed the gate candidate", int(out.get("proposed", 0)) == 1)
	var lean: Dictionary = PanelTools._workspace_list(shim, _args())
	check("default list carries NO geometry key",
		not ((lean.get("candidates", []) as Array)[0] as Dictionary).has("geometry"))
	var rich: Dictionary = PanelTools._workspace_list(shim, _args({"include_geometry": true}))
	var rec: Dictionary = (rich.get("candidates", []) as Array)[0]
	check("include_geometry adds the geometry key", rec.has("geometry"))
	var geo: Dictionary = rec.get("geometry", {})
	check_eq("geometry names all 3 segments", (geo.get("segments", []) as Array).size(), 3)
	check_eq("geometry names the via", (geo.get("vias", []) as Array).size(), 1)
	var seg0: Dictionary = (geo.get("segments", []) as Array)[0]
	check("segment points are JSON arrays, not Vector2s",
		(seg0.get("points", []) as Array)[0] is Array)
	check_eq("segment 0 starts at the fixture's (0,0)",
		((seg0.get("points", []) as Array)[0] as Array), [0.0, 0.0])
	check("segment carries layer and width",
		not str(seg0.get("layer", "")).is_empty() and float(seg0.get("width", 0.0)) > 0.0)

	# ── b) commit chains contiguous same-layer segments into one polyline ─────
	# A fresh hint + reply whose 3 segments chain on ONE layer: the commit must
	# land ONE trace with the 4-point walk, not three 2-point fragments.
	var hint3: String = _seed_net_named_hint(ctx["host"], "N3")
	shim.reply = {"routes": [{
		"net": "N3",
		"segments": [
			{"start": [0.0, 20.0], "end": [10.0, 20.0], "layer": "F.Cu"},
			{"start": [10.0, 20.0], "end": [10.0, 25.0], "layer": "F.Cu"},
			{"start": [10.0, 25.0], "end": [20.0, 25.0], "layer": "F.Cu"},
		],
		"vias": [],
		"hint_ids": [hint3],
	}], "via_count": 0}
	var landed: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint3]}))
	var cid3 := str(((landed.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var committed: Dictionary = PanelTools._workspace_commit(shim, _args({"candidate_id": cid3}))
	check("chained commit succeeded", bool(committed.get("success", false)))
	var tids: Array = committed.get("trace_ids", [])
	check_eq("three chained segments became ONE trace", tids.size(), 1)
	if tids.size() == 1:
		var trace = data.get_trace(str(tids[0]))
		check("the trace exists on the board", trace != null)
		if trace != null:
			check_eq("the one trace walks all four points", (trace.waypoints as Array).size(), 4)
			check_eq("…ending at the route's far end",
				trace.waypoints[3], Vector2(20.0, 25.0))

	# The GATE candidate (layer break at the via + a disconnected path) must
	# still commit as THREE traces — chaining never fuses across layers or gaps.
	var cid_gate := str(((out.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var gate_committed: Dictionary = PanelTools._workspace_commit(shim, _args({"candidate_id": cid_gate}))
	check("gate commit succeeded", bool(gate_committed.get("success", false)))
	check_eq("layer-break + disconnected path still commit as three traces",
		(gate_committed.get("trace_ids", []) as Array).size(), 3)

	# ── c) dangling-copper honesty on move/rotate ─────────────────────────────
	var added: Dictionary = await PanelTools._add_component(shim,
		_args({"id": "U9", "footprint": "IC_DIP", "x": 30.0, "y": 40.0}))
	check("fixture component added", bool(added.get("success", false)))
	var comp = data.get_component("U9")
	var pin_positions: Dictionary = comp.get_all_pin_positions()
	var first_pin: Vector2 = pin_positions[pin_positions.keys()[0]]
	var stub = data.new_trace()
	stub.net_name = "N9"
	stub.layer = "top"
	stub.width = 0.3
	stub.waypoints.append(first_pin)
	stub.waypoints.append(first_pin + Vector2(6.0, 0.0))
	data.add_trace(stub)
	var stub_id := str(stub.id)

	var moved: Dictionary = await PanelTools._move_component(shim,
		_args({"component_id": "U9", "x": 60.0, "y": 70.0}))
	check("move succeeded", bool(moved.get("success", false)))
	check("the move names its orphaned copper", moved.has("dangling_copper"))
	var dangles: Array = moved.get("dangling_copper", [])
	check_eq("exactly one endpoint dangles", dangles.size(), 1)
	if dangles.size() == 1:
		var d: Dictionary = dangles[0]
		check_eq("the warning names the stub trace", str(d.get("trace_id", "")), stub_id)
		check_eq("…and its net", str(d.get("net", "")), "N9")
		check_eq("…and the component that abandoned it", str(d.get("component_id", "")), "U9")

	# NEGATIVE GATE: after the move the stub no longer touches U9's pads, so a
	# further rotate must NOT re-report it (was_on_pad is the filter) — and a
	# component with no copper reports nothing at all.
	var rotated: Dictionary = await PanelTools._rotate_component(shim,
		_args({"component_id": "U9", "degrees": 90}))
	check("rotate succeeded", bool(rotated.get("success", false)))
	check("rotate does NOT re-report copper that was already orphaned",
		not rotated.has("dangling_copper"))

	ctx["driver"].free_panel(ctx["panel"])


# ══ 14. Stage A: structured hint status lands ON THE CANDIDATE ═══════════════
#
# Bug 019fcf152791 Stage A. The router reports a machine-readable
# {id, waypoint_status, waypoint_count, net, message} when a non-'detailed'
# single-net hint's authored waypoints were not consumed. PLACEMENT is the
# fix: those statuses also ride stuck[] like every other bridge warning, and
# stuck[] is where 1-3 real notes sit under ~28 repeated emitter warnings
# (019fce3ac3f5 nit 2) — which is precisely how this went unread through two
# HITL cycles. The status must appear on the CANDIDATE the hint produced.

func _run_hint_status_placement() -> void:
	print("-- 14. Stage A: waypoint_status rides the candidate, matched by hint id --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var hint_id: String = str(ctx["hint_id"])

	# Router reply carrying BOTH warning shapes: the structured status keyed to
	# this run's real hint id, a structured status for a hint that is NOT this
	# candidate's (must not attach), and a bare legacy warning (must stay in
	# stuck[] only — this is additive, not a re-route of the warning channel).
	var reply: Dictionary = _multipad_reply([hint_id])
	reply["warnings"] = [
		{"id": hint_id, "waypoint_status": "ignored", "waypoint_count": 3,
			"net": "N1", "message": "3 authored waypoint(s) IGNORED — BYPASSES obstacle avoidance"},
		{"id": "some_other_hint", "waypoint_status": "ignored", "waypoint_count": 1,
			"net": "NZ", "message": "not this candidate's hint"},
		{"id": hint_id, "message": "a bare legacy warning with no status field"},
	]
	shim.reply = reply

	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose succeeded", bool(out.get("success", false)))
	var rec: Dictionary = (out.get("candidates", []) as Array)[0]

	check("the candidate carries hint_status", rec.has("hint_status"))
	var statuses: Array = rec.get("hint_status", [])
	check_eq("only the status for THIS candidate's hint attaches", statuses.size(), 1)
	if statuses.size() == 1:
		var s: Dictionary = statuses[0]
		check_eq("…matched by hint id, never by net", str(s.get("id", "")), hint_id)
		check_eq("…machine-readable status is what a caller branches on",
			str(s.get("waypoint_status", "")), "ignored")
		check_eq("…and it counts the waypoints that were dropped",
			int(s.get("waypoint_count", 0)), 3)
		check("…the prose warns the 'detailed' escape hatch costs obstacle avoidance",
			str(s.get("message", "")).find("BYPASSES obstacle avoidance") != -1)

	# The warning channel is unchanged: every warning still reaches stuck[],
	# including the bare one. Lifting is a COPY onto the candidate, not a move.
	var stuck_msgs: Array = []
	for entry in out.get("stuck", []):
		if entry is Dictionary and (entry as Dictionary).has("warning"):
			stuck_msgs.append((entry as Dictionary)["warning"])
	check_eq("all three warnings still ride stuck[] (nothing was moved)",
		stuck_msgs.size(), 3)

	# NEGATIVE GATE: a run with no structured statuses leaves candidates clean,
	# so hint_status never becomes ambient noise on every propose.
	var plain: Dictionary = _multipad_reply([hint_id])
	plain["warnings"] = [{"id": hint_id, "message": "bare warning only"}]
	shim.reply = plain
	var out2: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var recs2: Array = out2.get("candidates", [])
	if recs2.size() > 0:
		check("no structured status ⇒ NO hint_status key on the candidate",
			not (recs2[0] as Dictionary).has("hint_status"))

	ctx["driver"].free_panel(ctx["panel"])


# ══ 15. Epoch UX1: corridor_adherence attach, width provenance, emitter/stuck split ══
#
# Three additive-reply-key stations, all extending the SAME shared landing
# path (_ingest_result_into_workspace / _attach_hint_status / _stuck_from_result)
# group 14 already exercises — kept together so a change to one station's
# wiring cannot silently leak into another's assertions without a failure
# showing up in this same group.

func _run_ux1_additive_reply_keys() -> void:
	print("-- 15. UX1: corridor_adherence -> hint_status, width provenance, emitter_notes split --")
	await _run_ux1_corridor_adherence()
	await _run_ux1_width_provenance()
	await _run_ux1_emitter_notes_split()


## Station 2 (docket 019fcf152791, "GDScript side"): result.corridor_adherence
## entries lift onto the candidate's hint_status list — same placement argument
## and same hint-id-only matching as waypoint_status (group 14) — attached
## VERBATIM (the worker owns the shape) rather than reshaped into a new vocabulary.
func _run_ux1_corridor_adherence() -> void:
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var hint_id: String = str(ctx["hint_id"])

	# Reply carries a corridor_adherence entry for THIS run's real hint id, and
	# one for a hint that is not this candidate's — the foreign one must not
	# attach, mirroring group 14's "matched by hint id, never by net" gate.
	var reply: Dictionary = _multipad_reply([hint_id])
	reply["corridor_adherence"] = [
		{"hint_id": hint_id, "endpoints": [[0.0, 0.0], [5.0, 0.0]], "status": "honored",
			"corridor_honored": true, "max_deviation_mm": 0.02, "tolerance_mm": 0.1,
			"per_waypoint": [], "skipped_waypoints": []},
		{"hint_id": "some_other_hint", "endpoints": [[9.0, 9.0], [10.0, 10.0]],
			"status": "violated", "corridor_honored": false, "max_deviation_mm": 3.5,
			"tolerance_mm": 0.1, "per_waypoint": [], "skipped_waypoints": []},
	]
	shim.reply = reply

	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose succeeded", bool(out.get("success", false)))
	var rec: Dictionary = (out.get("candidates", []) as Array)[0]
	check("the candidate carries hint_status for its own corridor_adherence entry",
		rec.has("hint_status"))
	var statuses: Array = rec.get("hint_status", [])
	check_eq("only the entry for THIS candidate's hint attaches", statuses.size(), 1)
	if statuses.size() == 1:
		var s: Dictionary = statuses[0]
		check_eq("…matched by hint_id, never by net", str(s.get("hint_id", "")), hint_id)
		check_eq("…attached verbatim: status", str(s.get("status", "")), "honored")
		check_eq("…attached verbatim: corridor_honored", bool(s.get("corridor_honored", false)), true)
		check_eq("…attached verbatim: max_deviation_mm", float(s.get("max_deviation_mm", -1.0)), 0.02)
		check_eq("…attached verbatim: tolerance_mm", float(s.get("tolerance_mm", -1.0)), 0.1)

	# NEGATIVE GATE: no corridor_adherence AND no waypoint_status in the reply
	# ⇒ no hint_status key at all — additive, never ambient.
	var plain: Dictionary = _multipad_reply([hint_id])
	shim.reply = plain
	var out2: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var recs2: Array = out2.get("candidates", [])
	if recs2.size() > 0:
		check("no corridor_adherence, no waypoint_status ⇒ NO hint_status key",
			not (recs2[0] as Dictionary).has("hint_status"))

	ctx["driver"].free_panel(ctx["panel"])


## Station 3 (docket 019fd0ab5af8): the worker's per-route effective width
## provenance (methods.py _attach_effective_routing_rules,
## route["effective_routing_rules"]["trace_width_mm"]) threads onto the
## candidate record as width_mm/width_source — this is what makes an
## owner-authored hint's width falling back to the router's hintless default
## OBSERVABLE instead of silently indistinguishable from an intentional value.
func _run_ux1_width_provenance() -> void:
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var hint_id: String = str(ctx["hint_id"])

	var reply: Dictionary = _multipad_reply([hint_id])
	reply["routes"][0]["effective_routing_rules"] = {
		"trace_width_mm": {"value": 0.5, "source": "hint"},
		"clearance_mm": {"value": 0.2, "source": "board_rules"},
	}
	shim.reply = reply

	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose succeeded", bool(out.get("success", false)))
	var rec: Dictionary = (out.get("candidates", []) as Array)[0]
	check("candidate carries width_mm when the worker attached provenance", rec.has("width_mm"))
	check_eq("…width_mm is the worker's effective width", float(rec.get("width_mm", -1.0)), 0.5)
	check("candidate carries width_source", rec.has("width_source"))
	check_eq("…width_source is relayed verbatim, never reinterpreted",
		str(rec.get("width_source", "")), "hint")

	# NO WORKER PROVENANCE — the oracle this group exists for. The record still
	# carries width_mm (the candidate's own segment width) and the WORKSPACE's
	# ingest verdict as width_source. The seeded hint authors NO width and this
	# reply stamps none, so there is NO width — and the answer to that is
	# 0.0 + "unresolved", never a 0.25mm literal standing in for it. commit()
	# refuses zero-width copper by name, so nothing gets fabricated at a width
	# nobody chose.
	var plain: Dictionary = _multipad_reply([hint_id])
	shim.reply = plain
	# NO board answer either: strip the design rule _panel_context authored, so
	# every rung of the ladder — reply stamp, hint, the net's own copper, the
	# board's default — is genuinely silent.
	ctx["data"].design_rules = {}
	var out2: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var recs2: Array = out2.get("candidates", [])
	if recs2.size() > 0:
		var rec2: Dictionary = recs2[0]
		check_eq("no width from ANY source ⇒ width_mm 0.0, never an invented 0.25",
			float(rec2.get("width_mm", -1.0)), 0.0)
		check_eq("…and width_source says so BY NAME (the silent fallback, visible)",
			str(rec2.get("width_source", "")), "unresolved")

	ctx["driver"].free_panel(ctx["panel"])

	# THE COPPER-CREATING PATH obeys the same precedence. Here the SEGMENTS
	# carry the width and nothing else does — the most specific statement in the
	# reply, the one the worker only ever setdefaults — while a hint and the
	# board both say 0.25mm.
	var ctx3: Dictionary = await _panel_context()
	ctx3["data"].design_rules = {"trace_width_mm": 0.25}
	var hints3: Array = [{"id": str(ctx3["hint_id"]), "kind_payload": {
		"net_names": ["N1"], "width_mm": 0.25,
		"source_pins": ["U1.3"], "dest_pins": ["U2.7"]}}]
	var stamped_reply: Dictionary = _multipad_reply([str(ctx3["hint_id"])])
	for seg in (stamped_reply["routes"][0]["segments"] as Array):
		(seg as Dictionary)["width_mm"] = 0.5
	var applied: Dictionary = PanelTools._materialize_routes(
		ctx3["host"], ctx3["data"], stamped_reply, hints3)
	check("segment-stamped reply lays copper", int(applied.get("traces_added", 0)) > 0)
	var all_stamped := true
	for tid in (applied.get("trace_ids", []) as Array):
		var t = ctx3["data"].traces.get(str(tid))
		if t == null or absf(float(t.width) - 0.5) > 1e-6:
			all_stamped = false
	check("every committed trace is the SEGMENTS' 0.5mm, not the 0.25mm the hint and the board both name",
		all_stamped)

	# MIXED widths in one reply: one trace carries one width, so the route
	# becomes one trace per (layer, width) rather than one trace at whichever
	# width won. The two F.Cu runs here are disconnected AND differently sized.
	var mixed_reply: Dictionary = _multipad_reply([str(ctx3["hint_id"])])
	var mixed_segs: Array = mixed_reply["routes"][0]["segments"]
	(mixed_segs[0] as Dictionary)["width_mm"] = 0.5
	(mixed_segs[1] as Dictionary)["width_mm"] = 0.5
	(mixed_segs[2] as Dictionary)["width_mm"] = 0.75
	var mixed: Dictionary = PanelTools._materialize_routes(
		ctx3["host"], ctx3["data"], mixed_reply, hints3)
	var mixed_widths: Array = []
	for tid in (mixed.get("trace_ids", []) as Array):
		var mt = ctx3["data"].traces.get(str(tid))
		if mt != null:
			mixed_widths.append(snappedf(float(mt.width), 0.001))
	mixed_widths.sort()
	check_eq("a route drawn at two widths commits BOTH, one trace per (layer, width)",
		mixed_widths, [0.5, 0.5, 0.75])
	ctx3["driver"].free_panel(ctx3["panel"])


## Station 5 (docket 019fce3ac3f5 item 2): the ~28 per-component
## emitter-capability warnings ("feature_omitted", "captured_geometry_not_emitted",
## "ordinal_ids") split out of stuck[] into their own emitter_notes list, so the
## 1-3 real per-hint routing warnings in stuck[] are no longer buried.
func _run_ux1_emitter_notes_split() -> void:
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var hint_id: String = str(ctx["hint_id"])

	# One per-hint routing warning (must stay in stuck[]), one emitter
	# capability note (must move to emitter_notes), one unrouted pad pair
	# (always genuine stuck[] feedback).
	var reply: Dictionary = _multipad_reply([hint_id])
	reply["unrouted"] = [{"net": "N2", "from": "U3.1", "to": "U4.2"}]
	reply["warnings"] = [
		{"id": hint_id, "waypoint_status": "ignored", "waypoint_count": 2,
			"net": "N1", "message": "per-hint routing warning"},
		{"code": "feature_omitted", "component": "U5", "message": "capability note"},
	]
	shim.reply = reply

	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose succeeded", bool(out.get("success", false)))

	var stuck: Array = out.get("stuck", [])
	check_eq("stuck has exactly the unrouted entry + the per-hint warning", stuck.size(), 2)
	var has_unrouted := false
	var has_per_hint_warning := false
	for entry in stuck:
		if not (entry is Dictionary):
			continue
		var ed: Dictionary = entry
		if ed.has("reason") and str(ed.get("net", "")) == "N2":
			has_unrouted = true
		if ed.has("warning") and str((ed.get("warning", {}) as Dictionary).get("waypoint_status", "")) == "ignored":
			has_per_hint_warning = true
	check("…the unrouted N2 pair is in stuck[]", has_unrouted)
	check("…the per-hint routing warning is in stuck[]", has_per_hint_warning)

	# F6 (HITL-4, docs/llm-ergonomics.md): routing replies carry a COUNT
	# SUMMARY, never the verbatim per-component list — that list is per-board
	# static and was drowning every propose reply (~27 entries live).
	check("emitter_notes_summary carries the capability count", out.has("emitter_notes_summary"))
	check("…and the verbatim list is GONE from routing replies", not out.has("emitter_notes"))
	var summary: Dictionary = out.get("emitter_notes_summary", {})
	check_eq("…count is 1", int(summary.get("count", 0)), 1)
	check_eq("…broken down by code", int((summary.get("codes", {}) as Dictionary).get("feature_omitted", 0)), 1)
	check("…note points at the fab/export surfaces",
		str(summary.get("note", "")).find("gerbers") != -1)

	# NEGATIVE GATE: no capability-coded warnings ⇒ no summary key —
	# additive, never ambient on every propose.
	var plain: Dictionary = _multipad_reply([hint_id])
	shim.reply = plain
	var out2: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("no capability warnings ⇒ NO emitter_notes_summary key", not out2.has("emitter_notes_summary"))
	check("…and no emitter_notes key either", not out2.has("emitter_notes"))

	ctx["driver"].free_panel(ctx["panel"])


# ══ 16. batch commit through the TOOL (docket 019fd0ab6dd2) ═══════════════════
#
# The model-level transaction is covered in test_routing_workspace_model group
# 7b; THIS group covers the MCP wrapper: the candidate_id/candidate_ids
# exactly-one contract, the batch reply shape, per-member hint-lifecycle
# closure, and the batch undo note.

func _run_ux1_batch_commit_tool() -> void:
	print("-- 16. workspace_commit batch form: one call, one undoable step --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var hint_a: String = str(ctx["hint_id"])

	# Land two candidates on two tasks (N1 via the seeded hint, N2 via a second).
	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var cand_a := str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var hint_b: String = _seed_net_named_hint(ctx["host"], "N2")
	shim.reply = {"routes": [{
		"net": "N2",
		"segments": [{"start": [20.0, 0.0], "end": [25.0, 0.0], "layer": "F.Cu"}],
		"vias": [],
		"hint_ids": [hint_b],
	}], "via_count": 0}
	var second: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_b]}))
	var cand_b := str(((second.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))

	# EXACTLY-ONE contract, judged by argument PRESENCE (Codex review P2).
	var both: Dictionary = PanelTools._workspace_commit(shim,
		_args({"candidate_id": cand_a, "candidate_ids": [cand_b]}))
	check("candidate_id + candidate_ids together refuses", not bool(both.get("success", true)))
	var both_empty: Dictionary = PanelTools._workspace_commit(shim,
		_args({"candidate_id": cand_a, "candidate_ids": []}))
	check("candidate_id + EMPTY candidate_ids is still the ambiguous ask",
		not bool(both_empty.get("success", true)))
	var empty_batch: Dictionary = PanelTools._workspace_commit(shim,
		_args({"candidate_ids": []}))
	check("candidate_ids: [] refuses with the batch form's own error",
		not bool(empty_batch.get("success", true)))
	check("…and the error names the empty batch",
		str(empty_batch.get("error", "")).find("empty batch") != -1)

	# The batch itself.
	var out: Dictionary = PanelTools._workspace_commit(shim,
		_args({"candidate_ids": [cand_a, cand_b]}))
	check("batch commit succeeded", bool(out.get("success", false)))
	check_eq("committed_count", int(out.get("committed_count", 0)), 2)
	check_eq("per-member results", (out.get("results", []) as Array).size(), 2)
	check_eq("candidate records ride the reply", (out.get("candidates", []) as Array).size(), 2)
	for rec in out.get("candidates", []):
		check_eq("member '%s' is committed" % str((rec as Dictionary).get("candidate_id", "")),
			str((rec as Dictionary).get("disposition", "")), "committed")
	check("batch undo note names the whole-batch revert",
		str(out.get("undo_note", "")).find("EVERY batch member") != -1)

	# MF-2 closure ran per member: both source hints transitioned open→applied.
	check_eq("hint A applied", str(ctx["host"].get_by_id(hint_a).get("lifecycle", "")), "applied")
	check_eq("hint B applied", str(ctx["host"].get_by_id(hint_b).get("lifecycle", "")), "applied")

	# THE UNDO ACTUALLY RUNS (Codex review): one undo removes every member's
	# copper and returns both candidates to their pre-commit dispositions.
	var data = ctx["data"]
	check("batch landed copper", data.get_trace_count() > 0)
	data.undo()
	check_eq("one undo removes the whole batch's copper", data.get_trace_count(), 0)
	check_eq("undo restores member A to proposed",
		str(ctx["ws"].get_candidate(cand_a).disposition), "proposed")
	check_eq("undo restores member B to proposed",
		str(ctx["ws"].get_candidate(cand_b).disposition), "proposed")

	ctx["driver"].free_panel(ctx["panel"])
# ══ 17. Epoch UX1 station 8: minerva_pcb_add_route_intent ═════════════════════
#
# ONE authoring call, ATOMICALLY: (a) a connectivity-only pcb_route_hint
# annotation — no waypoints, ever; (b) an eagerly-created RouteTask (task_id
# "NET|hint_id", reusing RoutingWorkspace.ensure_task — no reimplementation);
# (c) when a corridor is given, a routing_constraint STORED ON THE TASK
# (revision 1, authored_by "ai", base_board_revision), never on the
# annotation. NO ROUTING is performed. DCR 019fd095e694, converged on docket
# 019fd057ea0b comment 1028 (eager task creation dissolves the "two router
# round-trips" objection; the corridor's one authoritative home is the task,
# never a second inert copy on the durable connectivity object).
#
# Model-only fixture (no scene mount, no router) — this tool never reaches
# the router, so the same "bare model, no panel" idiom groups 3-7 use is
# enough: a real PcbData with two real 1-pin components on one net, a real
# PcbAnnotationHost, and a bare PcbWorkspace behind a minimal stub panel.

## Stub panel exposing get_data()/get_routing_workspace() — the two duck-typed
## methods _get_data()/_get_workspace() need — without a scene-tree mount.
class _RouteIntentStubPanel extends RefCounted:
	var _data
	var _ws

	func get_data():
		return _data

	func get_routing_workspace():
		return _ws


## A panel with board data but NO get_routing_workspace() method at all, so
## _get_workspace() degrades to null the same way a headless/pre-mount host
## does — the fixture for the workspace_unavailable refusal.
class _RouteIntentStubPanelNoWorkspace extends RefCounted:
	var _data

	func get_data():
		return _data


## Two 1-pin components on net "PWR" (BAT1.1, D1.2), a third 1-pin component
## on its own net "GND" (U1.1, for the cross-net refusal), all on a real
## PCBData bound to a real PcbAnnotationHost via the stub panel above.
## Returns {"host", "data", "ws"}.
func _route_intent_context() -> Dictionary:
	var data = PcbData.new()
	data.save_to_history("baseline")

	var bat1 = data.new_component()
	bat1.id = "BAT1"
	bat1.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(bat1)

	var d1 = data.new_component()
	d1.id = "D1"
	d1.pins = {"2": Vector2(0.0, 0.0)}
	data.add_component(d1)

	data.connect_pin_to_net("PWR", "BAT1", "1")
	data.connect_pin_to_net("PWR", "D1", "2")

	var u1 = data.new_component()
	u1.id = "U1"
	u1.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(u1)
	data.connect_pin_to_net("GND", "U1", "1")

	var ws = PcbWorkspace.new()
	var host = load(ANNOTATION_HOST_SCRIPT_PATH).new()
	var stub := _RouteIntentStubPanel.new()
	stub._data = data
	stub._ws = ws
	host.set_panel(stub)
	return {"host": host, "data": data, "ws": ws}


func _run_ux1_add_route_intent() -> void:
	print("-- 17. Station 8: minerva_pcb_add_route_intent (intent+task+constraint, atomic, no routing) --")
	await _run_route_intent_happy_path_with_corridor()
	_run_route_intent_task_constraint_round_trip()
	_run_route_intent_no_corridor_success()
	_run_route_intent_refusals()
	# ── Cold review fix round (H3-1 orphan/duplicate absorption, H2-1 deletion
	# cascade, SECONDARY: annotation_rejected leg, corridor:[] refusal, JSON
	# round trip, workspace_list constraint surface) ──────────────────────────
	await _run_route_intent_merge_absorption()
	_run_route_intent_deletion_cascade()
	_run_route_intent_annotation_rejected()
	_run_route_intent_constraint_json_round_trip()
	_run_route_intent_corridor_empty_and_workspace_list()
	await _run_ux2_width_on_intent_and_reroute()


## Happy path WITH a corridor: asserts the atomic triple lands, no routing
## happened, the annotation carries NO waypoints/corridor, and the reply
## shape names hint_id/task_id/net/constraint_revision + a legal next step.
## Goes through the DISPATCHER (PanelTools.handle), not the static func
## directly, so the manifest→dispatch wiring is covered at least once.
func _run_route_intent_happy_path_with_corridor() -> void:
	var ctx: Dictionary = _route_intent_context()
	var host = ctx["host"]
	var data = ctx["data"]
	var ws = ctx["ws"]
	var anns_before: int = (host.get_all_annotations() as Array).size()
	var cands_before: int = (ws.list_candidates() as Array).size()

	var args := {
		"editor_name": "PCB",
		"source_pin": "BAT1.1",
		"dest_pin": "D1.2",
		"note": "power feed",
		"corridor": [{"x_mm": 1.0, "y_mm": 0.0}, {"x_mm": 5.0, "y_mm": 0.0}],
	}
	var reply: Dictionary = await PanelTools.handle(host, "minerva_pcb_add_route_intent", args)
	check("add_route_intent succeeded", bool(reply.get("success", false)))
	var hint_id: String = str(reply.get("hint_id", ""))
	check("reply carries a hint_id", not hint_id.is_empty())
	check_eq("reply names the resolved net", str(reply.get("net", "")), "PWR")
	check_eq("reply names the eager task id (NET|hint_id)",
		str(reply.get("task_id", "")), "PWR|%s" % hint_id)
	check_eq("reply carries constraint_revision 1 (a corridor was given)",
		int(reply.get("constraint_revision", 0)), 1)
	check("reply names a legal next step (propose)",
		str(reply.get("note", "")).find("workspace_propose") != -1)

	# ── (a) the annotation: CONNECTIVITY ONLY, no waypoints, ever ────────────
	check_eq("exactly one annotation was created",
		(host.get_all_annotations() as Array).size(), anns_before + 1)
	var ann: Dictionary = host.get_by_id(hint_id)
	check("the annotation exists", not ann.is_empty())
	check_eq("it is a pcb_route_hint", str(ann.get("kind", "")), "pcb_route_hint")
	var kp: Dictionary = ann.get("kind_payload", {}) if ann.get("kind_payload", {}) is Dictionary else {}
	check_eq("source_pins carries exactly source_pin",
		(kp.get("source_pins", []) as Array), ["BAT1.1"])
	check_eq("dest_pins carries exactly dest_pin",
		(kp.get("dest_pins", []) as Array), ["D1.2"])
	check_eq("note lands as text", str(kp.get("text", "")), "power feed")
	check_eq("waypoints is EMPTY — corridor never lands on the annotation, by construction",
		(kp.get("waypoints", []) as Array).size(), 0)
	check("no corridor-shaped key leaked onto the annotation payload",
		not kp.has("corridor") and not kp.has("corridor_points"))

	# ── (b) the eager task, SAME key format ingest mints ─────────────────────
	var task_id: String = str(reply.get("task_id", ""))
	var task = ws.get_task(task_id)
	check("the task exists in the workspace", task != null)
	if task != null:
		check_eq("task net matches the resolved net", str(task.net), "PWR")
		check_eq("task is open — nothing has been routed yet", str(task.state), "open")

		# ── (c) the constraint — stored ON THE TASK, revision 1 ───────────────
		check("the task carries a routing_constraint", task.is_constrained())
		var rc: Dictionary = task.routing_constraint
		check_eq("constraint revision is 1", int(rc.get("revision", 0)), 1)
		check_eq("constraint authored_by is ai", str(rc.get("authored_by", "")), "ai")
		check_eq("constraint base_board_revision matches the board",
			int(rc.get("base_board_revision", -1)), int(data.board_revision))
		check_eq("constraint corridor carries both points",
			(rc.get("corridor_points", []) as Array).size(), 2)
		var pts: Array = rc.get("corridor_points", [])
		if pts.size() == 2:
			check("first corridor point matches", (pts[0] as Vector2).is_equal_approx(Vector2(1.0, 0.0)))
			check("second corridor point matches", (pts[1] as Vector2).is_equal_approx(Vector2(5.0, 0.0)))

	# ── NO ROUTING WAS PERFORMED ──────────────────────────────────────────────
	check_eq("no candidate was created — this tool never routes",
		(ws.list_candidates() as Array).size(), cands_before)


## The task's routing_constraint (corridor_points, revision, authored_by,
## base_board_revision) survives RoutingWorkspace.to_dict() / load_from_dict()
## — the same round trip every other task field already goes through.
func _run_route_intent_task_constraint_round_trip() -> void:
	var ctx: Dictionary = _route_intent_context()
	var host = ctx["host"]
	var data = ctx["data"]
	var ws = ctx["ws"]

	var reply: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
		"corridor": [{"x_mm": 2.0, "y_mm": 3.0}],
	})
	check("intent with corridor succeeded", bool(reply.get("success", false)))
	var task_id: String = str(reply.get("task_id", ""))

	var dumped: Dictionary = ws.to_dict()
	var ws2 = PcbWorkspace.new()
	ws2.load_from_dict(dumped)
	var task2 = ws2.get_task(task_id)
	check("the task survives a round trip through to_dict/load_from_dict", task2 != null)
	if task2 != null:
		check("the round-tripped task is still constrained", task2.is_constrained())
		var rc2: Dictionary = task2.routing_constraint
		check_eq("round-tripped revision survives", int(rc2.get("revision", 0)), 1)
		check_eq("round-tripped authored_by survives", str(rc2.get("authored_by", "")), "ai")
		check_eq("round-tripped base_board_revision survives",
			int(rc2.get("base_board_revision", -1)), int(data.board_revision))
		var pts2: Array = rc2.get("corridor_points", [])
		check_eq("round-tripped corridor point count survives", pts2.size(), 1)
		if pts2.size() == 1:
			check("round-tripped corridor point value survives (Vector2, not a JSON dict)",
				(pts2[0] as Vector2).is_equal_approx(Vector2(2.0, 3.0)))


## No corridor at all: the task is created (eagerly, still) but carries NO
## routing_constraint, and the reply carries NO constraint_revision key —
## absent, not zero, so a caller can tell "no corridor was given" from "a
## corridor was given at revision 0".
func _run_route_intent_no_corridor_success() -> void:
	var ctx: Dictionary = _route_intent_context()
	var host = ctx["host"]
	var ws = ctx["ws"]

	var reply: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
	})
	check("intent without corridor succeeded", bool(reply.get("success", false)))
	check("no constraint_revision key when no corridor was given",
		not reply.has("constraint_revision"))
	var task = ws.get_task(str(reply.get("task_id", "")))
	check("the task still exists (eager creation does not depend on a corridor)", task != null)
	if task != null:
		check("the task carries NO routing_constraint", not task.is_constrained())


## Named refusals: unresolvable pin (missing component AND missing pin, both
## sides), cross-net pins, single-endpoint-only, and workspace_unavailable.
## NOTHING is half-created by any refusal — the fixture host's annotation
## count stays at zero throughout.
func _run_route_intent_refusals() -> void:
	var ctx: Dictionary = _route_intent_context()
	var host = ctx["host"]

	var bad_component: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "NOPE.1", "dest_pin": "D1.2",
	})
	check("an unknown component is refused", not bool(bad_component.get("success", true)))
	check_eq("refusal is named pin_unresolvable", str(bad_component.get("error", "")), "pin_unresolvable")
	check_eq("refusal names the source side", str(bad_component.get("which", "")), "source")

	var bad_pin: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.99", "dest_pin": "D1.2",
	})
	check("an unknown pin on a real component is refused", not bool(bad_pin.get("success", true)))
	check_eq("refusal is named pin_unresolvable", str(bad_pin.get("error", "")), "pin_unresolvable")

	var cross: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "U1.1",
	})
	check("pins on two different nets are refused", not bool(cross.get("success", true)))
	check_eq("refusal is named cross_net_pins", str(cross.get("error", "")), "cross_net_pins")
	check_eq("refusal names the source net", str(cross.get("source_net", "")), "PWR")
	check_eq("refusal names the dest net", str(cross.get("dest_net", "")), "GND")

	var multi: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": ["BAT1.1"], "dest_pin": "D1.2",
	})
	check("an array source_pin is refused (single-endpoint only)", not bool(multi.get("success", true)))
	check_eq("refusal is named single_endpoint_only", str(multi.get("error", "")), "single_endpoint_only")

	var host_no_ws = load(ANNOTATION_HOST_SCRIPT_PATH).new()
	var stub_no_ws := _RouteIntentStubPanelNoWorkspace.new()
	stub_no_ws._data = ctx["data"]
	host_no_ws.set_panel(stub_no_ws)
	var unavailable: Dictionary = PanelTools._add_route_intent(host_no_ws, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
	})
	check("no live workspace is refused", not bool(unavailable.get("success", true)))
	check_eq("refusal is named workspace_unavailable", str(unavailable.get("error", "")), "workspace_unavailable")

	check_eq("no refusal above left an annotation behind",
		(host.get_all_annotations() as Array).size(), 0)


# ══ 18. Station 8 fix round (cold review): H3-1 absorption, H2-1 deletion ═════
# ══ cascade, annotation_rejected, corridor:[] refusal, JSON round trip,     ═══
# ══ workspace_list constraint surface ══════════════════════════════════════
#
# H3-1 (orphan/duplicate tasks on a shared net): the eager task key
# minerva_pcb_add_route_intent mints is "net|hint_id"; ingest_record mints
# "net|<sorted hint ids>" from the worker's BY-NET attribution. Two open
# intents on one net whose route merges into ONE worker answer (hint_ids ==
# [hidA, hidB]) used to produce a THIRD task key equal to neither eager key,
# orphaning both. The fix (_absorb_eager_tasks_for_merge,
# pcb_routing_workspace.gd) folds the candidate-less eager tasks into the
## merged task instead.
#
# H2-1 (deletion cascade): removing a pcb_route_hint annotation for a
# still-unanswered intent now drops its candidate-less eager task too
# (PcbAnnotationHost.remove_annotation → RoutingWorkspace.
# drop_empty_tasks_for_hint). A task with a candidate survives.


## THE ONE THAT FAILED BEFORE THIS FIX ROUND (H3-1). Real mounted panel +
## RouterShim (group 1's idiom) rather than the bare _route_intent_context
## fixture, because this test needs a real workspace_propose round trip —
## two add_route_intent calls on ONE net, then a shimmed propose whose reply
## attributes BOTH hint ids to a SINGLE worker route on that net (methods.py's
## BY-NET attribution — exactly what a worker does when two open intents on
## the same net get answered by one route). Asserts: the candidate lands on
## ONE task (the merged key, not a freshly-minted third), both eager tasks are
## gone (absorbed, not orphaned), and the constraint from the ONE intent that
## carried one survives the absorption onto the merged task.
func _run_route_intent_merge_absorption() -> void:
	print("-- 18. H3-1/H2-1/SECONDARY fix round --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	# Two real 1-pin components on a real net "PWR" — the SAME two-component-
	# one-net shape _route_intent_context builds, layered onto this group's
	# real mounted board (connect_pin_to_net auto-creates the net).
	var bat1 = data.new_component()
	bat1.id = "BAT1"
	bat1.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(bat1)
	var d1 = data.new_component()
	d1.id = "D1"
	d1.pins = {"2": Vector2(0.0, 0.0)}
	data.add_component(d1)
	data.connect_pin_to_net("PWR", "BAT1", "1")
	data.connect_pin_to_net("PWR", "D1", "2")

	# add_route_intent never reaches the router — called on the REAL host
	# directly (not the RouterShim, whose build_route_hint_envelope forwarder
	# only mirrors the shorter toolbar-authoring signature); the shim is used
	# below ONLY for the propose call, which is the one hop that needs it.
	var intent_a: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
		"corridor": [{"x_mm": 1.0, "y_mm": 0.0}],
	})
	check("intent A (with a corridor) succeeded", bool(intent_a.get("success", false)))
	var hint_a := str(intent_a.get("hint_id", ""))
	var task_a := str(intent_a.get("task_id", ""))

	var intent_b: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
	})
	check("intent B (no corridor) succeeded", bool(intent_b.get("success", false)))
	var hint_b := str(intent_b.get("hint_id", ""))
	var task_b := str(intent_b.get("task_id", ""))

	check("both eager tasks exist before propose",
		ws.get_task(task_a) != null and ws.get_task(task_b) != null)
	check_eq("two open, candidate-less tasks so far", (ws.list_tasks() as Array).size(), 2)

	var sorted_ids: Array = [hint_a, hint_b]
	sorted_ids.sort()
	var merged_key := "PWR|%s" % ",".join(sorted_ids)

	shim.reply = {
		"routes": [{
			"net": "PWR",
			"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_a, hint_b],
		}],
		"via_count": 0,
	}

	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_a, hint_b]}))
	check("propose succeeded", bool(out.get("success", false)))
	var cands: Array = out.get("candidates", [])
	check_eq("exactly ONE candidate landed for the merged route (not two, not zero)", cands.size(), 1)
	if cands.size() == 1:
		check_eq("...on the MERGED task key, never a freshly-minted third task",
			str((cands[0] as Dictionary).get("task_id", "")), merged_key)

	check("eager task A was absorbed, not left orphaned", ws.get_task(task_a) == null)
	check("eager task B was absorbed, not left orphaned", ws.get_task(task_b) == null)
	var merged_task = ws.get_task(merged_key)
	check("the merged task exists", merged_task != null)
	check_eq("no orphan and no third task — exactly ONE task remains",
		(ws.list_tasks() as Array).size(), 1)

	if merged_task != null:
		check("the solitary constraint (only intent A carried one) transferred onto the merge",
			merged_task.is_constrained())
		var rc: Dictionary = merged_task.routing_constraint
		check_eq("...revision preserved", int(rc.get("revision", 0)), 1)
		check_eq("...authored_by preserved", str(rc.get("authored_by", "")), "ai")
		var pts: Array = rc.get("corridor_points", [])
		check_eq("...corridor point count preserved", pts.size(), 1)
		if pts.size() == 1:
			check("...corridor point value preserved (Vector2)",
				(pts[0] as Vector2).is_equal_approx(Vector2(1.0, 0.0)))

	ctx["driver"].free_panel(ctx["panel"])


## H2-1: deletion cascade. Two legs on the SAME bare-model fixture group 17
## already uses: (1) an intent with no answer — deleting its annotation via
## the host drops its eager task; (2) an intent a candidate has already
## landed on (the singleton case: one hint, so ingest_record's task_key
## converges on the SAME eager key — no merge needed to exercise this) —
## deleting its annotation leaves the task alone, because a task with a
## candidate is HISTORY (H2-1's own "tasks with candidates stay" rule).
func _run_route_intent_deletion_cascade() -> void:
	var ctx: Dictionary = _route_intent_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	# ── leg 1: unanswered intent — its annotation's removal drops the task ────
	var reply_a: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
	})
	check("intent A succeeded", bool(reply_a.get("success", false)))
	var hint_a := str(reply_a.get("hint_id", ""))
	var task_a := str(reply_a.get("task_id", ""))
	check("task A exists before deletion", ws.get_task(task_a) != null)

	check("removing the annotation succeeds", host.remove_annotation(hint_a))
	check("the unanswered task is GONE after its annotation is deleted",
		ws.get_task(task_a) == null)

	# ── leg 2: propose-then-delete — a task WITH a candidate survives ─────────
	var reply_b: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
	})
	check("intent B succeeded", bool(reply_b.get("success", false)))
	var hint_b := str(reply_b.get("hint_id", ""))
	var task_b := str(reply_b.get("task_id", ""))

	# Singleton ingest (one hint) converges on the SAME eager key — no panel/
	# router needed to prove this leg, ws.ingest_record is the model-level
	# entry point _ingest_result_into_workspace itself funnels through.
	var cid := str(ws.ingest_record({
		"net": "PWR",
		"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
		"vias": [],
		"source_hint_ids": [hint_b],
		"source_hints": [],
	}, int(data.board_revision)))
	check("a candidate landed", not cid.is_empty())
	check_eq("...on the SAME eager task (singleton case converges)",
		str(ws.get_candidate(cid).task_id), task_b)

	check("removing the answered annotation still succeeds", host.remove_annotation(hint_b))
	check("the task WITH a candidate SURVIVES — it is history, not a placeholder",
		ws.get_task(task_b) != null)


## SECONDARY: force add_annotation_v2 to fail (a host stub whose
## add_annotation_v2 always returns "", the validation-rejected contract
## add_annotation_v2 itself documents) so the annotation_rejected leg is
## reachable without needing a genuinely schema-invalid envelope. Asserts the
## named refusal AND that nothing was half-created (no task minted either).
class _RejectingAnnotationHost extends RefCounted:
	var real

	func _init(real_host) -> void:
		real = real_host

	func get_panel():
		return real.get_panel()

	# First-execution fix (boundary run): _add_route_intent resolves the
	# source/dest pins off the BOARD before it ever builds the envelope, so
	# a stub without this forwarder dies at "PCB data not available" and the
	# annotation_rejected leg under test is never reached.
	func get_board_data():
		return real.get_board_data()

	func get_all_annotations() -> Array:
		return real.get_all_annotations()

	func build_route_hint_envelope(x_mm: float, y_mm: float, text: String = "",
			layer: String = "F.Cu", hint_type: String = "waypoint", waypoints: Array = [],
			author_kind: String = "human", detail_level: String = "", width_mm: Variant = null,
			source_pins: Array = [], dest_pins: Array = []) -> Dictionary:
		return real.build_route_hint_envelope(x_mm, y_mm, text, layer, hint_type,
			waypoints, author_kind, detail_level, width_mm, source_pins, dest_pins)

	func add_annotation_v2(_envelope: Dictionary) -> String:
		return ""


func _run_route_intent_annotation_rejected() -> void:
	var ctx: Dictionary = _route_intent_context()
	var rejecting_host := _RejectingAnnotationHost.new(ctx["host"])

	var reply: Dictionary = PanelTools._add_route_intent(rejecting_host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
	})
	check("a rejected envelope refuses", not bool(reply.get("success", true)))
	check_eq("refusal is named annotation_rejected", str(reply.get("error", "")), "annotation_rejected")
	check_eq("no task was created — nothing is half-created by this refusal",
		(ctx["ws"].list_tasks() as Array).size(), 0)


## SECONDARY: full JSON TEXT round trip (to_dict → JSON.stringify →
## JSON.parse_string → load_from_dict), not just the direct dict hand-off the
## group-17 round-trip test already covers — this is what actually exercises
## _constraint_from_json's int()/str() normalisation (JSON turns a whole
## number into a float on the wire) and proves corridor_points come back as
## USABLE Vector2s, not {x,y} dicts, after crossing real JSON text.
func _run_route_intent_constraint_json_round_trip() -> void:
	var ctx: Dictionary = _route_intent_context()
	var host = ctx["host"]
	var ws = ctx["ws"]

	var reply: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
		"corridor": [{"x_mm": 2.5, "y_mm": -3.25}, {"x_mm": 10.0, "y_mm": 0.0}],
	})
	check("intent with a corridor succeeded", bool(reply.get("success", false)))
	var task_id := str(reply.get("task_id", ""))

	var json_text: String = JSON.stringify(ws.to_dict())
	var parsed: Variant = JSON.parse_string(json_text)
	check("the dumped workspace round-trips through JSON text", parsed is Dictionary)
	if not (parsed is Dictionary):
		return

	var ws2 = PcbWorkspace.new()
	ws2.load_from_dict(parsed as Dictionary)
	var task2 = ws2.get_task(task_id)
	check("the task survives the FULL JSON-text round trip", task2 != null)
	if task2 == null:
		return
	check("the round-tripped task is still constrained", task2.is_constrained())
	var rc: Dictionary = task2.routing_constraint
	check_eq("revision coerces back to int (JSON gave a float on the wire)",
		int(rc.get("revision", -1)), 1)
	check("...revision's actual stored type is int, not float", typeof(rc.get("revision")) == TYPE_INT)
	check_eq("base_board_revision coerces back to int too",
		int(rc.get("base_board_revision", -1)), int(ctx["data"].board_revision))
	check("...its actual stored type is int, not float",
		typeof(rc.get("base_board_revision")) == TYPE_INT)
	var pts: Array = rc.get("corridor_points", [])
	check_eq("both corridor points survive", pts.size(), 2)
	if pts.size() == 2:
		check("point 0 is a USABLE Vector2, not a {x,y} dict",
			pts[0] is Vector2 and (pts[0] as Vector2).is_equal_approx(Vector2(2.5, -3.25)))
		check("point 1 is a USABLE Vector2, not a {x,y} dict",
			pts[1] is Vector2 and (pts[1] as Vector2).is_equal_approx(Vector2(10.0, 0.0)))


## SECONDARY: corridor: [] refuses by ARGUMENT PRESENCE with the named error
## ("corridor present but empty"), and workspace_list's task records gain the
## additive constrained/constraint_revision keys — present only on a
## constrained task, absent on every other one (never ambient).
func _run_route_intent_corridor_empty_and_workspace_list() -> void:
	var ctx: Dictionary = _route_intent_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var anns_before: int = (host.get_all_annotations() as Array).size()

	var empty_corridor: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
		"corridor": [],
	})
	check("corridor: [] is refused (present-but-empty, not \"no corridor\")",
		not bool(empty_corridor.get("success", true)))
	check("...named 'corridor present but empty'",
		str(empty_corridor.get("error", "")).find("corridor present but empty") != -1)
	check_eq("no annotation was created by the refused call",
		(host.get_all_annotations() as Array).size(), anns_before)
	check_eq("no task was created either", (ws.list_tasks() as Array).size(), 0)

	# One constrained intent, one unconstrained — workspace_list's additive
	# keys must appear on exactly the constrained one.
	var with_corridor: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
		"corridor": [{"x_mm": 1.0, "y_mm": 1.0}],
	})
	check("intent WITH a corridor succeeds", bool(with_corridor.get("success", false)))
	var task_id_c := str(with_corridor.get("task_id", ""))

	var without_corridor: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
	})
	check("intent WITHOUT a corridor succeeds", bool(without_corridor.get("success", false)))
	var task_id_u := str(without_corridor.get("task_id", ""))

	var listing: Dictionary = PanelTools._workspace_list(host, {"editor_name": "PCB"})
	check("workspace_list succeeded", bool(listing.get("success", false)))
	var trec_c: Variant = null
	var trec_u: Variant = null
	for t in listing.get("tasks", []):
		var td: Dictionary = t
		if str(td.get("task_id", "")) == task_id_c:
			trec_c = td
		elif str(td.get("task_id", "")) == task_id_u:
			trec_u = td
	check("the constrained task's record is present in workspace_list", trec_c != null)
	if trec_c != null:
		check_eq("...constrained:true", bool((trec_c as Dictionary).get("constrained", false)), true)
		check_eq("...constraint_revision == 1", int((trec_c as Dictionary).get("constraint_revision", 0)), 1)
	check("the unconstrained task's record is present too", trec_u != null)
	if trec_u != null:
		check("...NO 'constrained' key (additive-only, never ambient)",
			not (trec_u as Dictionary).has("constrained"))
		check("...NO 'constraint_revision' key either",
			not (trec_u as Dictionary).has("constraint_revision"))


# ══ 19. Station 9 (DCR 019fd095e694): task constraint CONSUMPTION ═══════════
#
# Station 8 (comment 1042) landed PcbRouteTask.routing_constraint — created,
# round-tripped, but never READ. This group covers the read side:
#   19a. PROPOSE READS THE CONSTRAINT — a selected hint whose task carries a
#        routing_constraint gets a "task_constraints" entry attached to the
#        router request; an unconstrained hint's request carries no such key.
#   19b. CANDIDATES CITE THE REVISION — the landed candidate record echoes
#        whatever "constraint_revision" the (shimmed) worker reply attached to
#        its route, additively.
#   19c. REROUTE STEERS THE TASK — corridor bumps the task's constraint
#        revision BEFORE the router runs; a stale expected_constraint_revision
#        is refused BY NAME, naming the actual revision, and does NOT bump it.
#   19d. DURABILITY (comment 1028's invariant) — a router failure after the
#        steering write leaves the bumped constraint standing, AND (F1, cold
#        review) the failure reply itself carries steered:true +
#        constraint_revision, so the bump is never silent.
#   19e. preserve_shape_as_corridor derives the corridor from the candidate's
#        OWN current geometry — but ONLY when it endpoint-chains into ONE
#        continuous path (F6, cold review): the mandatory GATE fixture (two
#        disconnected runs) refuses no_single_path, and a genuinely single-
#        path fixture succeeds.
#   19f. corridor + preserve_shape_as_corridor together is refused BY NAME,
#        by argument PRESENCE, before the router is ever called.
#   19g. F2 (cold review): steering a task whose owning hint still carries
#        legacy kind_payload.waypoints stamps that hint's
#        waypoints_superseded_by_constraint_revision through the standard
#        mutate-with-history seam.
#   19h. F3/F4 (cold review): two separately-constrained route intents that
#        merge onto ONE task (H3-1 absorption, two hints on one net) surface
#        the CONFLICT via propose's `constraint_conflicts`, and neither
#        hint's own task_constraints entry gets the OTHER hint's corridor
#        (owner-keyed emission — no dangling citation).


## 17x (Epoch UX2 station 3, docket 019fde363162): width_mm is part of routing
## intent. add_route_intent lands it on the minted hint's kind_payload (the
## channel _width_from_hints already reads — HITL-5's workaround was three
## wholesale kind_payload patches per width change); reroute_route lands a
## review-time width change on every source hint BEFORE the router leg, with
## the same validate-before-any-mutation ordering as the steering args.
func _run_ux2_width_on_intent_and_reroute() -> void:
	print("-- 17x. width_mm on add_route_intent + reroute_route (UX2 station 3) --")

	# ── intent half (stub-panel context, no router needed) ───────────────────
	var ictx: Dictionary = _route_intent_context()
	var ihost = ictx["host"]
	var anns_before: int = (ihost.get_all_annotations() as Array).size()

	var bad: Dictionary = await PanelTools.handle(ihost, "minerva_pcb_add_route_intent", {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2", "width_mm": 0.0,
	})
	check("width_mm 0 refused", not bool(bad.get("success", true)))
	check_eq("...named invalid_width", str(bad.get("error", "")), "invalid_width")
	check_eq("...and created NOTHING", (ihost.get_all_annotations() as Array).size(), anns_before)

	var bad2: Dictionary = await PanelTools.handle(ihost, "minerva_pcb_add_route_intent", {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2", "width_mm": "wide",
	})
	check_eq("non-numeric width_mm refused invalid_width", str(bad2.get("error", "")), "invalid_width")

	var made: Dictionary = await PanelTools.handle(ihost, "minerva_pcb_add_route_intent", {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2", "width_mm": 0.5,
	})
	check("intent with width_mm succeeded", bool(made.get("success", false)))
	check_eq("reply echoes width_mm", float(made.get("width_mm", 0.0)), 0.5)
	var made_kp: Dictionary = (ihost.get_by_id(str(made.get("hint_id", ""))) as Dictionary) \
		.get("kind_payload", {})
	check_eq("minted hint carries kind_payload.width_mm",
		float(made_kp.get("width_mm", 0.0)), 0.5)

	var plain: Dictionary = await PanelTools.handle(ihost, "minerva_pcb_add_route_intent", {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
	})
	check("width omitted: intent still succeeds", bool(plain.get("success", false)))
	check("...reply carries NO width_mm key", not plain.has("width_mm"))
	check("...hint payload carries NO width_mm key (net class default)",
		not ((ihost.get_by_id(str(plain.get("hint_id", ""))) as Dictionary)
			.get("kind_payload", {}) as Dictionary).has("width_mm"))

	# ── reroute half (RouterShim context — real host, canned router) ─────────
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var host = ctx["host"]
	var ws = ctx["ws"]
	var hint_id: String = str(ctx["hint_id"])

	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose succeeded", bool(first.get("success", false)))
	var cid: String = str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var task = ws.get_task(str(ws.get_candidate(cid).task_id))

	# Validation-before-mutation: invalid width alongside a corridor refuses
	# BEFORE the steer would land — the task stays unconstrained.
	var mixed_bad: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid, "corridor": [{"x_mm": 2.0, "y_mm": 2.0}], "width_mm": -1.0,
	}))
	check_eq("invalid width refused before any steer", str(mixed_bad.get("error", "")), "invalid_width")
	check("...task NOT constrained by the refused call", not task.is_constrained())

	var rerouted: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid, "width_mm": 0.6,
	}))
	check("reroute with width_mm succeeded", bool(rerouted.get("success", false)))
	check_eq("reply echoes width_mm", float(rerouted.get("width_mm", 0.0)), 0.6)
	check_eq("source hint's kind_payload.width_mm updated",
		float(((host.get_by_id(hint_id) as Dictionary).get("kind_payload", {}) as Dictionary)
			.get("width_mm", 0.0)), 0.6)

	# Durability: width lands before the router — a failed leg keeps it, and
	# the failure reply still echoes it.
	var cid2: String = str(((rerouted.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	shim.answer_ok = false
	var wfail: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid2, "width_mm": 0.8,
	}))
	check("router leg failed", not bool(wfail.get("success", true)))
	check_eq("width landed on the hint anyway (write-before-router)",
		float(((host.get_by_id(hint_id) as Dictionary).get("kind_payload", {}) as Dictionary)
			.get("width_mm", 0.0)), 0.8)
	check_eq("failure reply echoes width_mm", float(wfail.get("width_mm", 0.0)), 0.8)
	shim.answer_ok = true

	ctx["driver"].free_panel(ctx["panel"])


func _run_station9_task_constraints() -> void:
	print("-- 19. Station 9: task constraint CONSUMPTION (propose + reroute) --")
	await _run_station9_propose_reads_constraint()
	await _run_station9_reroute_steers_and_guards()
	await _run_station9_durability_survives_router_failure()
	await _run_station9_preserve_shape_as_corridor()
	await _run_station9_both_args_refused()
	await _run_station9_legacy_hint_steered_stamp()
	await _run_station9_two_constrained_intents_one_net()
	await _run_station9_stale_candidate_commit_refused()
	await _run_ux2_clear_constraint()


## Real 1-pin BAT1/D1 components on net "PWR", layered onto a real mounted
## panel — the same shape group 18's H3-1 fixture builds — so
## minerva_pcb_add_route_intent's pin resolution has real pads to resolve
## against while the propose call still goes through the RouterShim.
func _station9_intent_context() -> Dictionary:
	var ctx: Dictionary = await _panel_context()
	var data = ctx["data"]
	var bat1 = data.new_component()
	bat1.id = "BAT1"
	bat1.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(bat1)
	var d1 = data.new_component()
	d1.id = "D1"
	d1.pins = {"2": Vector2(0.0, 0.0)}
	data.add_component(d1)
	data.connect_pin_to_net("PWR", "BAT1", "1")
	data.connect_pin_to_net("PWR", "D1", "2")
	return ctx


## 19a + 19b combined (one propose round trip covers both halves cheaply):
## the request built for a constrained hint carries task_constraints keyed by
## hint id with the constraint's own corridor/preferred_layer/revision; an
## UNCONSTRAINED hint proposed alongside it contributes NO entry; and the
## landed candidate record echoes whatever constraint_revision the (shimmed)
## worker reply attached to its route.
func _run_station9_propose_reads_constraint() -> void:
	print("-- 19a/19b. propose attaches task_constraints; candidate cites constraint_revision --")
	var ctx: Dictionary = await _station9_intent_context()
	var host = ctx["host"]
	var shim = ctx["shim"]

	var intent: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
		"corridor": [{"x_mm": 1.0, "y_mm": 2.0}, {"x_mm": 3.0, "y_mm": 4.0}],
		"note": "steered",
	})
	check("constrained intent succeeded", bool(intent.get("success", false)))
	var hint_id: String = str(intent.get("hint_id", ""))
	check_eq("intent reply carries revision 1", int(intent.get("constraint_revision", 0)), 1)

	# The unconstrained control: the panel context's own seeded hint, ALREADY
	# attributed by the shim's default multipad reply — no task ever gave it a
	# corridor.
	var plain_hint_id: String = str(ctx["hint_id"])

	shim.reply = {
		"routes": [{
			"net": "PWR",
			"segments": [{"start": [1.0, 2.0], "end": [3.0, 4.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
			# Simulates the worker echoing the constraint revision it consumed
			# (route_bridge/router.py/methods.py, worker-side of this station) —
			# the panel-side stamping half is what this assertion actually tests.
			"constraint_revision": 1,
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("propose (constrained hint) succeeded", bool(out.get("success", false)))
	var call: Dictionary = shim.calls[shim.calls.size() - 1]
	var extra: Dictionary = call.get("extra", {})
	check("request carries task_constraints", extra.has("task_constraints"))
	var tc: Dictionary = extra.get("task_constraints", {})
	check_eq("task_constraints names exactly the constrained hint", tc.size(), 1)
	if tc.has(hint_id):
		var entry: Dictionary = tc[hint_id]
		var pts: Array = entry.get("corridor_points", [])
		check_eq("wire corridor carries both points", pts.size(), 2)
		if pts.size() == 2:
			check_eq("point 0 x", float((pts[0] as Array)[0]), 1.0)
			check_eq("point 0 y", float((pts[0] as Array)[1]), 2.0)
			check_eq("point 1 x", float((pts[1] as Array)[0]), 3.0)
			check_eq("point 1 y", float((pts[1] as Array)[1]), 4.0)
		check_eq("wire preferred_layer (unset -> empty string)", str(entry.get("preferred_layer", "?")), "")
		check_eq("wire revision echoed", int(entry.get("revision", 0)), 1)

	var cands: Array = out.get("candidates", [])
	check_eq("exactly one candidate landed", cands.size(), 1)
	if cands.size() == 1:
		check_eq("candidate record cites constraint_revision (shim reply echo)",
			int((cands[0] as Dictionary).get("constraint_revision", 0)), 1)

	# ── unconstrained control, same shim/host, a DIFFERENT hint ──────────────
	shim.reply = _multipad_reply([plain_hint_id])
	var out2: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [plain_hint_id]}))
	check("propose (unconstrained hint) succeeded", bool(out2.get("success", false)))
	var call2: Dictionary = shim.calls[shim.calls.size() - 1]
	check("unconstrained hint's request carries NO task_constraints key at all (byte-identical no-regression)",
		not (call2.get("extra", {}) as Dictionary).has("task_constraints"))
	var cands2: Array = out2.get("candidates", [])
	if cands2.size() > 0:
		check("unconstrained candidate carries NO constraint_revision key",
			not (cands2[0] as Dictionary).has("constraint_revision"))

	ctx["driver"].free_panel(ctx["panel"])


## 19c: corridor STEERS the task (revision 0 -> 1 -> 2 across two successful
## reroutes), and a STALE expected_constraint_revision is refused BY NAME —
## constraint_revision_conflict, naming the actual revision — WITHOUT bumping
## the task, before trying again with the correct value.
func _run_station9_reroute_steers_and_guards() -> void:
	print("-- 19c. reroute corridor bumps revision; expected_constraint_revision guards it --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]

	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("initial propose succeeded", bool(first.get("success", false)))
	var cid: String = str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var task_id: String = str(ws.get_candidate(cid).task_id)
	var task = ws.get_task(task_id)
	check("task starts UNCONSTRAINED", task != null and not task.is_constrained())

	# ── successful steer: revision 0 -> 1 ────────────────────────────────────
	var reroute1: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid, "corridor": [{"x_mm": 9.0, "y_mm": 9.0}],
	}))
	check("reroute with corridor succeeded", bool(reroute1.get("success", false)))
	check("task is now CONSTRAINED", task.is_constrained())
	check_eq("revision bumped to 1", int(task.routing_constraint.get("revision", 0)), 1)
	check_eq("authored_by is ai", str(task.routing_constraint.get("authored_by", "")), "ai")
	var cid2: String = str(((reroute1.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	check("reroute landed a NEW candidate generation", not cid2.is_empty() and cid2 != cid)

	# ── stale expected_constraint_revision: refused, revision UNCHANGED ──────
	var reroute2: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid2, "corridor": [{"x_mm": 1.0, "y_mm": 1.0}],
		"expected_constraint_revision": 0,
	}))
	check("stale expected_constraint_revision is refused", not bool(reroute2.get("success", true)))
	check_eq("refusal named constraint_revision_conflict", str(reroute2.get("error", "")), "constraint_revision_conflict")
	check_eq("refusal names the ACTUAL revision (1)", int(reroute2.get("actual_constraint_revision", -1)), 1)
	check_eq("refusal echoes what was expected", int(reroute2.get("expected_constraint_revision", -1)), 0)
	check_eq("the refused call did NOT bump the revision", int(task.routing_constraint.get("revision", 0)), 1)
	check_eq("...and did not touch the corridor either", (task.routing_constraint.get("corridor_points", []) as Array).size(), 1)

	# ── correct expected_constraint_revision: succeeds, revision 1 -> 2 ──────
	var reroute3: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid2, "corridor": [{"x_mm": 2.0, "y_mm": 2.0}, {"x_mm": 3.0, "y_mm": 3.0}],
		"expected_constraint_revision": 1,
	}))
	check("correctly-guarded reroute succeeded", bool(reroute3.get("success", false)))
	check_eq("revision bumped to 2", int(task.routing_constraint.get("revision", 0)), 2)
	check_eq("corridor replaced (2 points now)", (task.routing_constraint.get("corridor_points", []) as Array).size(), 2)

	ctx["driver"].free_panel(ctx["panel"])


## 19d (docket 019fd057ea0b comment 1028's durability invariant): the
## constraint is written BEFORE the router runs, so a router that then FAILS
## leaves the bump standing — steering does not depend on obtaining a
## candidate. F1 (cold review): the FAILURE REPLY ITSELF now says so —
## `steered:true` + `constraint_revision` (the NEW revision) — so a caller
## never has to separately re-read the task to discover the bump happened.
func _run_station9_durability_survives_router_failure() -> void:
	print("-- 19d. durability: a failed router leg does not undo the steering write, and REPORTS it (F1) --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]

	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("initial propose succeeded", bool(first.get("success", false)))
	var cid: String = str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var task = ws.get_task(str(ws.get_candidate(cid).task_id))
	check("task starts unconstrained", task != null and not task.is_constrained())

	shim.answer_ok = false
	var reroute_fail: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid, "corridor": [{"x_mm": 7.0, "y_mm": 7.0}],
	}))
	check("the router leg itself failed (worker_unavailable)", not bool(reroute_fail.get("success", true)))
	check("the task is CONSTRAINED anyway — the write happened before the failed router call",
		task.is_constrained())
	check_eq("revision bumped to 1 despite the router failure", int(task.routing_constraint.get("revision", 0)), 1)
	check("no NEW candidate landed (the router leg genuinely failed)",
		str(reroute_fail.get("rerouted_candidate_id", "")).is_empty())

	# ── F1: the failure envelope itself carries the bump ─────────────────────
	check("failure reply carries steered:true (F1: the bump is never silent)",
		bool(reroute_fail.get("steered", false)))
	check_eq("failure reply's constraint_revision matches the NEW revision (1) — "
		+ "a retry passes THIS number as expected_constraint_revision",
		int(reroute_fail.get("constraint_revision", -1)), 1)

	# ── F1 ordering: a plain (non-steering) reroute failure carries NEITHER
	# key — `steered` is stamped only when THIS call actually steered.
	var plain_fail: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({"candidate_id": cid}))
	check("a non-steering reroute also fails while the worker is down",
		not bool(plain_fail.get("success", true)))
	check("...but carries no steered key (nothing was steered by this call)",
		not plain_fail.has("steered"))
	check("...and no constraint_revision key either",
		not plain_fail.has("constraint_revision"))

	shim.answer_ok = true
	ctx["driver"].free_panel(ctx["panel"])


## 19e: preserve_shape_as_corridor derives the corridor from the candidate's
## OWN current geometry (chained segment points, joints deduped) rather than
## from an explicit `corridor` arg — but ONLY when every segment
## endpoint-chains into ONE continuous path (F6, cold review, Epoch UX1
## station 9). The mandatory GATE fixture (_multipad_reply, see its own doc)
## is deliberately TWO disconnected paths; the pre-fix implementation
## concatenated them anyway, fabricating a jump the candidate's own geometry
## never drew — this asserts that is now a NAMED refusal instead, and adds a
## genuinely single-path fixture proving the honouring case still works.
func _run_station9_preserve_shape_as_corridor() -> void:
	print("-- 19e. preserve_shape_as_corridor: disconnected refuses (F6), single path succeeds --")

	# ── disconnected geometry (the mandatory GATE fixture): refused, no mutation ──
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]

	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("initial propose succeeded", bool(first.get("success", false)))
	var cid: String = str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var task = ws.get_task(str(ws.get_candidate(cid).task_id))
	check("task starts unconstrained", task != null and not task.is_constrained())

	# _multipad_reply's own geometry: two joined segments ((0,0)->(5,0)->(5,5))
	# plus a THIRD, disconnected one ((50,50)->(60,50)) — 2 disconnected runs.
	var out: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid, "preserve_shape_as_corridor": true,
	}))
	check("disconnected geometry is refused, not silently bridged with a fabricated jump",
		not bool(out.get("success", true)))
	check_eq("refusal named no_single_path", str(out.get("error", "")), "no_single_path")
	check_eq("refusal names the run count (2 disconnected paths)", int(out.get("runs", 0)), 2)
	check("the task is still UNCONSTRAINED — a refused steer writes nothing",
		not task.is_constrained())

	ctx["driver"].free_panel(ctx["panel"])

	# ── single connected path: succeeds, derives the chained/deduped points ──
	var ctx2: Dictionary = await _panel_context()
	var shim2 = ctx2["shim"]
	var ws2 = ctx2["ws"]
	var hint_id2: String = str(ctx2["hint_id"])
	shim2.reply = {
		"routes": [{
			"net": "N1",
			"segments": [
				{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"},
				{"start": [5.0, 0.0], "end": [5.0, 5.0], "layer": "F.Cu"},
			],
			"vias": [],
			"hint_ids": [hint_id2],
		}],
		"via_count": 0,
	}
	var first2: Dictionary = await PanelTools._workspace_propose(shim2, _args())
	check("connected-fixture propose succeeded", bool(first2.get("success", false)))
	var cid2: String = str(((first2.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var task2 = ws2.get_task(str(ws2.get_candidate(cid2).task_id))
	check("connected task starts unconstrained", task2 != null and not task2.is_constrained())

	var out2: Dictionary = await PanelTools._workspace_reroute_route(shim2, _args({
		"candidate_id": cid2, "preserve_shape_as_corridor": true,
	}))
	check("preserve_shape_as_corridor succeeds on a single connected path",
		bool(out2.get("success", false)))
	check("task is now constrained", task2.is_constrained())
	check_eq("revision bumped to 1", int(task2.routing_constraint.get("revision", 0)), 1)
	var pts2: Array = task2.routing_constraint.get("corridor_points", [])
	check_eq("derived corridor carries 3 chained/deduped points", pts2.size(), 3)
	var expected2: Array = [Vector2(0, 0), Vector2(5, 0), Vector2(5, 5)]
	if pts2.size() == 3:
		for i in range(3):
			check("point %d matches the candidate's own geometry" % i,
				(pts2[i] as Vector2).is_equal_approx(expected2[i]))

	ctx2["driver"].free_panel(ctx2["panel"])


## 19f: corridor and preserve_shape_as_corridor together — refused BY NAME, by
## ARGUMENT PRESENCE (this file's established P2 convention), BEFORE the
## router is ever reached (no new call recorded on the shim).
func _run_station9_both_args_refused() -> void:
	print("-- 19f. corridor + preserve_shape_as_corridor together is refused --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]

	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("initial propose succeeded", bool(first.get("success", false)))
	var cid: String = str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var calls_before: int = shim.calls.size()

	var out: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid, "corridor": [{"x_mm": 1.0, "y_mm": 1.0}],
		"preserve_shape_as_corridor": true,
	}))
	check("both-args reroute is refused", not bool(out.get("success", true)))
	check_eq("refusal named corridor_args_conflict", str(out.get("error", "")), "corridor_args_conflict")
	check_eq("the router was NEVER reached — refused before any call", shim.calls.size(), calls_before)

	ctx["driver"].free_panel(ctx["panel"])


## 19g (F2, cold review): steering a task whose owning hint still carries
## legacy kind_payload.waypoints stamps that hint's
## waypoints_superseded_by_constraint_revision through the standard
## mutate-with-history seam (host.update_annotation) — the
## duplicated-authority guard: an editor looking at the hint's own waypoints
## must be able to tell they no longer describe what steers the route.
func _run_station9_legacy_hint_steered_stamp() -> void:
	print("-- 19g. F2: steering stamps the owning hint's legacy waypoints as superseded --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var host = ctx["host"]
	var hint_id: String = str(ctx["hint_id"])

	# _panel_context's own seeded hint (_seed_source_hint) carries REAL legacy
	# waypoints ([[0,0],[5,0]]) on the actual annotation (not just the
	# fabricated source_hints shape a few other tests build by hand) —
	# confirm the fixture assumption before relying on it.
	var seeded_ann: Dictionary = host.get_by_id(hint_id)
	var seeded_kp: Dictionary = seeded_ann.get("kind_payload", {})
	check("fixture sanity: the seeded hint carries legacy waypoints",
		not (seeded_kp.get("waypoints", []) as Array).is_empty())
	check("fixture sanity: not yet superseded",
		not seeded_kp.has("waypoints_superseded_by_constraint_revision"))

	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("initial propose succeeded", bool(first.get("success", false)))
	var cid: String = str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))

	var out: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid, "corridor": [{"x_mm": 8.0, "y_mm": 8.0}],
	}))
	check("steered reroute succeeded", bool(out.get("success", false)))

	var after_ann: Dictionary = host.get_by_id(hint_id)
	var after_kp: Dictionary = after_ann.get("kind_payload", {})
	check("legacy waypoints are STILL PRESENT — additive, never cleared",
		not (after_kp.get("waypoints", []) as Array).is_empty())
	check("...now stamped waypoints_superseded_by_constraint_revision",
		after_kp.has("waypoints_superseded_by_constraint_revision"))
	check_eq("...naming revision 1 (the constraint this steer just wrote)",
		int(after_kp.get("waypoints_superseded_by_constraint_revision", -1)), 1)

	ctx["driver"].free_panel(ctx["panel"])


## Two independent 1-pin pairs (BAT1.1—D1.2, R1.1—R2.1), both on net "PWR" —
## the shape 19h needs to mint two SEPARATE single-hint intents that later
## merge onto one worker-attributed route.
func _station9_two_intent_context() -> Dictionary:
	var ctx: Dictionary = await _panel_context()
	var data = ctx["data"]
	var bat1 = data.new_component()
	bat1.id = "BAT1"
	bat1.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(bat1)
	var d1 = data.new_component()
	d1.id = "D1"
	d1.pins = {"2": Vector2(0.0, 0.0)}
	data.add_component(d1)
	var r1 = data.new_component()
	r1.id = "R1"
	r1.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(r1)
	var r2 = data.new_component()
	r2.id = "R2"
	r2.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(r2)
	data.connect_pin_to_net("PWR", "BAT1", "1")
	data.connect_pin_to_net("PWR", "D1", "2")
	data.connect_pin_to_net("PWR", "R1", "1")
	data.connect_pin_to_net("PWR", "R2", "1")
	return ctx


## 19h (F3/F4, cold review): two SEPARATELY-CONSTRAINED route intents that
## share ONE net. Their eager, still-open tasks are each a SINGLETON
## ("PWR|hintA", "PWR|hintB") and each carries its OWN corridor — proposing
## BOTH hints together must build a task_constraints request that cites EACH
## hint's OWN corridor under EXACTLY that hint's own key (F3: owner-keyed
## emission, no dangling citation — the pre-fix defect would have echoed one
## hint's corridor for the other too, purely because a merged task's
## membership test matched both). When the (shimmed) worker reply then fuses
## both hints onto ONE route (hint_ids:[hintA,hintB]), the resulting merge
## finds both eager tasks constrained — a genuine authoring conflict — and
## that outcome must reach the reply as `constraint_conflicts` (F4), not
## live only in a push_warning nobody outside the engine console ever sees.
## P1-A (Codex 1047): the conflict no longer ABSORBS the constrained
## singletons — they survive with their constraints intact (per-hint
## steering continues next propose via the owner_hint_id-gated
## task_constraints channel); only the MERGED task is left unconstrained.
## The old behavior (erase both singletons, keep neither constraint) was a
## permanent dead state for station-12-seeded legacy hints: stamped
## superseded + edit-refused, yet nothing left steering.
func _run_station9_two_constrained_intents_one_net() -> void:
	print("-- 19h. F3/F4: two constrained intents, one net — owner-keyed request, conflict surfaced --")
	var ctx: Dictionary = await _station9_two_intent_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]

	var intent_a: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "BAT1.1", "dest_pin": "D1.2",
		"corridor": [{"x_mm": 1.0, "y_mm": 1.0}],
	})
	check("intent A succeeded", bool(intent_a.get("success", false)))
	var hint_a: String = str(intent_a.get("hint_id", ""))

	var intent_b: Dictionary = PanelTools._add_route_intent(host, {
		"editor_name": "PCB", "source_pin": "R1.1", "dest_pin": "R2.1",
		"corridor": [{"x_mm": 2.0, "y_mm": 2.0}, {"x_mm": 3.0, "y_mm": 3.0}],
	})
	check("intent B succeeded", bool(intent_b.get("success", false)))
	var hint_b: String = str(intent_b.get("hint_id", ""))

	check("the two intents minted DIFFERENT singleton tasks",
		str(intent_a.get("task_id", "")) != str(intent_b.get("task_id", "")))

	# ── F3: the OUTGOING request is owner-keyed, no dangling citation ────────
	shim.reply = {
		"routes": [{
			"net": "PWR",
			"segments": [{"start": [0.0, 0.0], "end": [1.0, 1.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_a, hint_b],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_a, hint_b]}))
	check("propose (two constrained hints) succeeded", bool(out.get("success", false)))
	var call: Dictionary = shim.calls[shim.calls.size() - 1]
	var tc: Dictionary = (call.get("extra", {}) as Dictionary).get("task_constraints", {})
	check_eq("task_constraints names BOTH hints", tc.size(), 2)
	if tc.has(hint_a):
		var pts_a: Array = (tc[hint_a] as Dictionary).get("corridor_points", [])
		check_eq("hint A's entry carries ITS OWN corridor (1 point) — not hint B's", pts_a.size(), 1)
	if tc.has(hint_b):
		var pts_b: Array = (tc[hint_b] as Dictionary).get("corridor_points", [])
		check_eq("hint B's entry carries ITS OWN corridor (2 points) — not hint A's", pts_b.size(), 2)

	# ── F4: the merge conflict reaches the reply ─────────────────────────────
	check("propose reply carries constraint_conflicts", out.has("constraint_conflicts"))
	var conflicts: Array = out.get("constraint_conflicts", [])
	check_eq("exactly one conflict recorded (one merge, two constrained absorbed tasks)",
		conflicts.size(), 1)
	if conflicts.size() == 1:
		var conflict: Dictionary = conflicts[0]
		check_eq("conflict named conflicting_constraints_kept_on_singletons (P1-A)",
			str(conflict.get("reason", "")), "conflicting_constraints_kept_on_singletons")
		var ids: Array = conflict.get("task_ids", [])
		check_eq("conflict names both conflicting task ids", ids.size(), 2)
		check("...naming hint A's eager task", str(intent_a.get("task_id", "")) in ids)
		check("...naming hint B's eager task", str(intent_b.get("task_id", "")) in ids)

	# ── P1-A (Codex 1047): the constrained singletons SURVIVE the merge ─────
	var surv_a = ws.get_task(str(intent_a.get("task_id", "")))
	var surv_b = ws.get_task(str(intent_b.get("task_id", "")))
	check("hint A's constrained singleton survived the conflicting merge", surv_a != null)
	check("hint B's constrained singleton survived the conflicting merge", surv_b != null)
	if surv_a != null:
		check("...A still carries its OWN constraint", surv_a.is_constrained())
	if surv_b != null:
		check("...B still carries its OWN constraint", surv_b.is_constrained())

	# The merged task itself ends up UNCONSTRAINED (no single task-level
	# winner exists) — but per-hint steering continues off the singletons.
	var cands: Array = out.get("candidates", [])
	check_eq("exactly one candidate landed (the merged route)", cands.size(), 1)
	if cands.size() == 1:
		var merged_task = ws.get_task(str((cands[0] as Dictionary).get("task_id", "")))
		check("the merged task exists", merged_task != null)
		if merged_task != null:
			check("the merged task is UNCONSTRAINED — neither conflicting corridor won",
				not merged_task.is_constrained())

		# ── V2 (Codex 1047 — boundary-delta test 2): EXPLICIT-corridor steering
		# on the merged multi-hint task refuses BEFORE mutation and BEFORE the
		# worker call. Pre-fix it "succeeded": revision bumped, owner_hint_id
		# written as "" — a constraint _task_constraints_for_hints deliberately
		# emits for NO hint, i.e. a successful-looking durable no-op.
		var merged_cid: String = str((cands[0] as Dictionary).get("candidate_id", ""))
		var calls_before: int = shim.calls.size()
		var steer: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
			"candidate_id": merged_cid, "corridor": [{"x_mm": 5.0, "y_mm": 5.0}],
		}))
		check("explicit-corridor steer on a merged task is refused", not bool(steer.get("success", true)))
		check_eq("...named multi_span_task (same name as the preserve-shape refusal)",
			str(steer.get("error", "")), "multi_span_task")
		var refused_hints: Array = steer.get("hint_ids", [])
		check_eq("...naming both member hints", refused_hints.size(), 2)
		if merged_task != null:
			check("...refused BEFORE mutation: merged task still unconstrained",
				not merged_task.is_constrained())
		check_eq("...refused BEFORE the worker call: no new router hop",
			shim.calls.size(), calls_before)
		check("...and no steered flag (nothing was durably written)", not steer.has("steered"))


## 19i (P1-B, Codex 1047 consolidated review — boundary-delta tests 3 + 4):
## candidate constraint provenance is DURABLE, and a candidate generated
## against an OLD constraint cannot be silently committed after steering
## advanced it. The exact correctness-critical sequence Codex named: steer
## succeeds (candidate at revision 1) → steer again but the router FAILS
## (revision durably 2, prior candidate still live) → committing that prior
## candidate must refuse constraint_stale_candidate with NO copper written →
## rerouting under the current revision lands a fresh candidate that commits
## cleanly. Also asserts the provenance survives into minerva_pcb_workspace_
## list records (pre-fix it lived only on the immediate propose reply).
func _run_station9_stale_candidate_commit_refused() -> void:
	print("-- 19i. stale-constraint candidate: durable provenance + commit refusal (P1-B) --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var hint_id: String = str(ctx["hint_id"])

	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("initial propose succeeded", bool(first.get("success", false)))
	var cid: String = str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	check_eq("unconstrained candidate carries the -1 sentinel durably",
		int(ws.get_candidate(cid).constraint_revision), -1)

	# ── steer 1: worker reply stamps the generating revision + hint status ───
	var reply1: Dictionary = _multipad_reply([hint_id])
	(reply1["routes"][0] as Dictionary)["constraint_revision"] = 1
	reply1["warnings"] = [{"id": hint_id, "waypoint_status": "corridor_honored",
		"message": "corridor honored"}]
	shim.reply = reply1
	var steer1: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid, "corridor": [{"x_mm": 4.0, "y_mm": 4.0}],
	}))
	check("steer 1 succeeded", bool(steer1.get("success", false)))
	var cid2: String = str(((steer1.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var c2 = ws.get_candidate(cid2)
	check_eq("candidate 2 DURABLY carries constraint_revision 1 (not reply-only)",
		int(c2.constraint_revision), 1)
	check("candidate 2 DURABLY carries hint_status", not (c2.hint_status as Array).is_empty())

	# ── boundary-delta 4: the provenance reaches workspace LIST records ──────
	var listed: Dictionary = PanelTools._workspace_list(shim, _args())
	var listed_rec: Dictionary = {}
	for r in listed.get("candidates", []):
		if str((r as Dictionary).get("candidate_id", "")) == cid2:
			listed_rec = r
	check("list found candidate 2", not listed_rec.is_empty())
	check_eq("...list record carries constraint_revision",
		int(listed_rec.get("constraint_revision", -99)), 1)
	check("...list record carries hint_status", listed_rec.has("hint_status"))

	# ── steer 2 FAILS at the router: revision durably 2, cid2 still live ─────
	shim.answer_ok = false
	var steer2: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid2, "corridor": [{"x_mm": 8.0, "y_mm": 8.0}],
		"expected_constraint_revision": 1,
	}))
	check("steer 2's router leg failed (by design)", not bool(steer2.get("success", true)))
	check("...but reported steered:true", bool(steer2.get("steered", false)))
	var task = ws.get_task(str(c2.task_id))
	check_eq("task constraint durably at revision 2", int(task.routing_constraint.get("revision", 0)), 2)
	check_eq("candidate 2 still live (proposed)", str(c2.disposition), "proposed")

	# ── the stale commit is REFUSED by name, before any mutation ─────────────
	var stale_commit: Dictionary = PanelTools._workspace_commit(shim, _args({"candidate_id": cid2}))
	check("committing the pre-steer candidate is refused", not bool(stale_commit.get("success", true)))
	check_eq("...named constraint_stale_candidate", str(stale_commit.get("error", "")), "constraint_stale_candidate")
	check_eq("...no disposition move happened", str(c2.disposition), "proposed")

	# ── reroute under the CURRENT revision, then commit cleanly ──────────────
	shim.answer_ok = true
	var reply2: Dictionary = _multipad_reply([hint_id])
	(reply2["routes"][0] as Dictionary)["constraint_revision"] = 3
	shim.reply = reply2
	var steer3: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid2, "corridor": [{"x_mm": 8.0, "y_mm": 8.0}],
		"expected_constraint_revision": 2,
	}))
	check("reroute under the current revision succeeded", bool(steer3.get("success", false)))
	var cid3: String = str(((steer3.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	check_eq("fresh candidate stamped with the generating revision (3)",
		int(ws.get_candidate(cid3).constraint_revision), 3)
	var clean_commit: Dictionary = PanelTools._workspace_commit(shim, _args({"candidate_id": cid3}))
	check("committing the current-revision candidate succeeds", bool(clean_commit.get("success", false)))

	ctx["driver"].free_panel(ctx["panel"])


## 19j (Epoch UX2 station 2, docket 019fde361cf0): clear_constraint — a task
## corridor can now be REMOVED, not only replaced. HITL-5 exposed the gap:
## after a placement change made stored corridors wrong, "route this unguided
## now" required reject+delete+recreate, and the constraint_stale_candidate
## refusal advised a verb that did not exist. A clear IS a steer: same
## precondition ordering, same expected_constraint_revision guard, same
## write-before-router durability; what it writes is {} (the
## _hint_convert_to_detailed cleared-state precedent), and the owner hint's
## supersession marker is stripped synchronously through the sanctioned
## release, so its own waypoints are live authority again.
func _run_ux2_clear_constraint() -> void:
	print("-- 19j. clear_constraint: remove a task corridor, guarded + durable (UX2 station 2) --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var host = ctx["host"]
	var hint_id: String = str(ctx["hint_id"])

	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("initial propose succeeded", bool(first.get("success", false)))
	var cid: String = str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var task = ws.get_task(str(ws.get_candidate(cid).task_id))

	# clear on a task with no constraint: refused BY NAME, not no-op success.
	var clear0: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid, "clear_constraint": true,
	}))
	check("clear on an UNCONSTRAINED task refused", not bool(clear0.get("success", true)))
	check_eq("...named no_constraint_to_clear", str(clear0.get("error", "")), "no_constraint_to_clear")

	# Steer first (revision 1) so there is something to clear; the seeded
	# legacy hint gets stamped superseded by this write (19g's contract).
	var steer: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid, "corridor": [{"x_mm": 8.0, "y_mm": 8.0}],
	}))
	check("steer succeeded", bool(steer.get("success", false)))
	check("task constrained after steer", task.is_constrained())
	check("owner hint stamped superseded by the steer",
		(host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
			.has("waypoints_superseded_by_constraint_revision"))
	var cid2: String = str(((steer.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))

	# clear + corridor together: refused corridor_args_conflict, nothing moved.
	var conflict: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid2, "clear_constraint": true, "corridor": [{"x_mm": 1.0, "y_mm": 1.0}],
	}))
	check("clear + corridor refused", not bool(conflict.get("success", true)))
	check_eq("...named corridor_args_conflict", str(conflict.get("error", "")), "corridor_args_conflict")
	check("...constraint untouched by the refusal", task.is_constrained())

	# Stale expected_constraint_revision guards a clear exactly like a steer.
	var stale: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid2, "clear_constraint": true, "expected_constraint_revision": 0,
	}))
	check("stale-guarded clear refused", not bool(stale.get("success", true)))
	check_eq("...named constraint_revision_conflict", str(stale.get("error", "")), "constraint_revision_conflict")
	check("...constraint still standing", task.is_constrained())

	# The real clear, correctly guarded: constraint gone, marker stripped,
	# reply reports what was cleared, and the reroute landed a fresh candidate.
	var clear: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid2, "clear_constraint": true, "expected_constraint_revision": 1,
	}))
	check("guarded clear succeeded", bool(clear.get("success", false)))
	check("task UNCONSTRAINED after clear", not task.is_constrained())
	check("reply carries cleared_constraint:true", bool(clear.get("cleared_constraint", false)))
	check_eq("reply names the revision that was cleared (1)",
		int(clear.get("cleared_constraint_revision", -1)), 1)
	check_eq("reply's constraint_revision is 0 now", int(clear.get("constraint_revision", -1)), 0)
	check("owner hint's supersession marker STRIPPED (waypoints live again)",
		not (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
			.has("waypoints_superseded_by_constraint_revision"))
	check("clear's reroute landed a NEW candidate",
		not str(((clear.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", "")).is_empty() \
			if not (clear.get("candidates", []) as Array).is_empty() else false)

	# Durability: with the worker DOWN, the clear still lands before the failed
	# router leg — and the failure reply says so. This leg also pins the
	# MONOTONIC REVISION FLOOR (cold review F2): the earlier clear left
	# constraint_revision_floor = 1 on the task, so the re-steer below resumes
	# at revision 2 — it must NEVER reuse revision 1, or a still-live
	# pre-clear candidate stamped 1 would pass the constraint_stale_candidate
	# commit gate against a brand-new corridor.
	# The generation stamp is WORKER-attached (methods.py puts
	# constraint_revision on the route it steered) — simulate that half of
	# the contract on the canned reply, the same way 19i does, so the landed
	# candidate durably carries the revision the steer below writes (2).
	var steer_reply: Dictionary = _multipad_reply([hint_id])
	(steer_reply["routes"][0] as Dictionary)["constraint_revision"] = 2
	shim.reply = steer_reply
	var steer_again: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": str(((clear.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", "")),
		"corridor": [{"x_mm": 3.0, "y_mm": 3.0}],
	}))
	check("re-steer for the durability leg succeeded", bool(steer_again.get("success", false)))
	check("task re-constrained", task.is_constrained())
	check_eq("re-steer resumed ABOVE the cleared revision (floor): revision 2, not 1",
		int(task.routing_constraint.get("revision", 0)), 2)
	var cid4: String = str(((steer_again.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	shim.answer_ok = false
	var clear_fail: Dictionary = await PanelTools._workspace_reroute_route(shim, _args({
		"candidate_id": cid4, "clear_constraint": true,
	}))
	check("router leg failed (worker down)", not bool(clear_fail.get("success", true)))
	check("constraint CLEARED anyway — the write happened before the router",
		not task.is_constrained())
	check("failure reply carries cleared_constraint:true (never silent)",
		bool(clear_fail.get("cleared_constraint", false)))
	check_eq("failure reply names the cleared revision (2 — the floor kept it monotonic)",
		int(clear_fail.get("cleared_constraint_revision", -1)), 2)
	shim.answer_ok = true

	# Codex 1049 finding 1: the failed router leg left the PRE-CLEAR candidate
	# live — stamped with the revision (2) of the corridor the clear just
	# removed. Committing it must refuse by name: its copper follows steering
	# the user explicitly removed, and _governing_constraint_revision alone
	# (-1 on an unconstrained task) cannot see that — the clear FLOOR can.
	check_eq("pre-clear candidate still carries its generation stamp (revision 2)",
		int(ws.get_candidate(cid4).constraint_revision), 2)
	check("pre-clear candidate is still LIVE (failed router leg retired nothing)",
		cid4 in ws.live_candidate_ids())
	var stale_commit: Dictionary = PanelTools._workspace_commit(shim, _args({"candidate_id": cid4}))
	check("committing the pre-clear candidate is refused", not bool(stale_commit.get("success", true)))
	check_eq("...named constraint_stale_candidate (cleared-floor rule)",
		str(stale_commit.get("error", "")), "constraint_stale_candidate")

	ctx["driver"].free_panel(ctx["panel"])


# ══ 20. EPOCH UX1 STATION 10: minerva_pcb_workspace_edit_candidate ═══════════
#
# The ONE discriminated candidate-edit tool (DCR 019fd095e694, docket
# 019fd057ea0b comments 1026/1028): move_junction (junction IDENTITY, not a
# flattened bend index) and insert_via (delegates verbatim to
# RoutingWorkspace.add_via). Model-only fixture (no scene mount, no router) —
# same "bare model behind a minimal stub panel" idiom station 8's group 17
# already exercises — so a change to one station's fixture idiom is caught by
# a change to the shared helper, not by two copies drifting apart.

## A real PcbData + a bare PcbWorkspace behind _RouteIntentStubPanel (reused
## from group 17, DEFINED ABOVE), holding ONE multipad candidate — path A:
## (0,0)->(5,0)->(5,5) via a via AT (5,0) [the join point under test], path B:
## (50,50)->(60,50) wholly disconnected. Returns {"host","data","ws","cid"}.
func _edit_candidate_context() -> Dictionary:
	var data = PcbData.new()
	data.save_to_history("baseline")
	var ws = PcbWorkspace.new()
	var host = load(ANNOTATION_HOST_SCRIPT_PATH).new()
	var stub := _RouteIntentStubPanel.new()
	stub._data = data
	stub._ws = ws
	host.set_panel(stub)
	var cid := str(ws.ingest_record(_multipad_record(), int(data.board_revision)))
	return {"host": host, "data": data, "ws": ws, "cid": cid}


## A SECOND candidate, on its OWN net, built from two segments whose nearest
## endpoints are 1.5*EDIT_EPS_MM apart: (0,0)->(5,0) and
## (5.0+1.5*EPS,0)->(10,0). That gap is OUTSIDE the coincidence epsilon (so
## _segments_adjacent does NOT merge them — they stay two genuinely
## disconnected paths; the eps-radius match balls around each endpoint don't
## even need to touch each other to both be found by a query point sitting
## between them, since 1.5*EPS < 2*EPS). This is the realistic shape of the
## ambiguous_junction hazard: not two paths sharing one exact coordinate
## (impossible — exact coincidence IS the adjacency test, so it would merge
## them), but two logically-separate junctions a few float-ULPs apart, e.g.
## after a router reply's own JSON round-trip, that a naive single-epsilon
## match would silently resolve to whichever path was found first.
## Returns {"host","data","ws","cid","eps"}.
func _near_miss_context() -> Dictionary:
	var eps: float = PcbWorkspace.EDIT_EPS_MM
	var data = PcbData.new()
	data.save_to_history("baseline")
	var ws = PcbWorkspace.new()
	var host = load(ANNOTATION_HOST_SCRIPT_PATH).new()
	var stub := _RouteIntentStubPanel.new()
	stub._data = data
	stub._ws = ws
	host.set_panel(stub)
	var record: Dictionary = {
		"net": "N2",
		"segments": [
			{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"},
			{"start": [5.0 + 1.5 * eps, 0.0], "end": [10.0, 0.0], "layer": "F.Cu"},
		],
		"vias": [],
		"width": 0.3,
		"source_hint_ids": ["hint_near_miss"],
		"source_hints": [],
	}
	var cid := str(ws.ingest_record(record, int(data.board_revision)))
	return {"host": host, "data": data, "ws": ws, "cid": cid, "eps": eps}


func _run_station10_edit_candidate() -> void:
	print("-- 20. Station 10: minerva_pcb_workspace_edit_candidate (move_junction / insert_via) --")
	_run_station10_move_junction_happy_path()
	_run_station10_move_junction_terminal_endpoint_allowed()
	_run_station10_move_junction_ambiguous()
	_run_station10_move_junction_via_membership_ambiguous()
	_run_station10_move_junction_not_found()
	_run_station10_move_junction_degenerate()
	_run_station10_move_junction_degenerate_neighbor_in_moved_set()
	_run_station10_revision_conflict()
	_run_station10_commit_in_progress_guard()
	_run_station10_insert_via_delegation()
	_run_station10_terminal_candidate_refused()
	_run_station10_edit_never_touches_task_constraint()
	_run_station10_unknown_op_refused()


## move_junction moves EVERY coincident endpoint (both segments' shared point)
## AND the via sitting on it, atomically, in ONE connected path — and leaves
## the wholly disconnected path byte-identical. The mandatory INV-3-style GATE
## assertion this station's own tests must carry, per the file's group 6/7
## convention.
func _run_station10_move_junction_happy_path() -> void:
	var ctx: Dictionary = _edit_candidate_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var cand = ws.get_candidate(cid)
	var rev_before: int = int(cand.candidate_revision)

	# Path B, captured BEFORE the edit — the untouched-path assertion is a
	# comparison, not a claim (same convention as group 6's _run_inv3_path_scoped_edit).
	var path_b_pts_before: Array = (cand.segments[2] as Dictionary).get("points", []).duplicate()

	var out: Dictionary = PanelTools._workspace_edit_candidate(host, _args({
		"candidate_id": cid, "op": "move_junction",
		"point": [5.0, 0.0], "to": [5.0, 20.0],
	}))
	check("move_junction succeeded", bool(out.get("success", false)))
	check_eq("op is echoed", str(out.get("op", "")), "move_junction")
	var moved_segs: Array = out.get("moved_segment_ids", [])
	check_eq("both of path A's segments (sharing the join) moved", moved_segs.size(), 2)
	var moved_vias: Array = out.get("moved_via_ids", [])
	check_eq("the via sitting on the junction moved too", moved_vias.size(), 1)
	check_eq("candidate_revision bumped by exactly one",
		int(out.get("candidate_revision", -1)), rev_before + 1)
	check_eq("validation went stale (INV-2, geometry half)",
		str(out.get("validation", "")), "stale")

	# ── THE GATE: the moved endpoints, exactly ─────────────────────────────
	var seg_a: Dictionary = cand.segments[0]
	var seg_b: Dictionary = cand.segments[1]
	check("path A's first leg now ends at the new point",
		(seg_a.get("points", []) as Array)[1] == Vector2(5.0, 20.0))
	check("path A's second leg now starts at the new point",
		(seg_b.get("points", []) as Array)[0] == Vector2(5.0, 20.0))
	var via: Dictionary = cand.vias[0]
	check_eq("the via itself moved to the new point", via.get("position", Vector2()), Vector2(5.0, 20.0))

	# ── path B is byte-identical ─────────────────────────────────────────────
	var path_b_after: Array = (cand.segments[2] as Dictionary).get("points", [])
	check_eq("disconnected path B's point count is unchanged", path_b_after.size(), path_b_pts_before.size())
	check("disconnected path B's first point is unchanged", path_b_after[0] == path_b_pts_before[0])
	check("disconnected path B's last point is unchanged", path_b_after[1] == path_b_pts_before[1])

	# ── candidate-local: no auto-pin, disposition untouched ───────────────────
	check_eq("the candidate was NOT pinned by editing it", str(cand.disposition), "proposed")
	check("the reply names the edit-local / not-durable contract",
		str(out.get("note", "")).contains("candidate-local") and str(out.get("note", "")).contains("pin"))


## P2 (fix round, docket 019fd095e694): moving a route's TERMINAL endpoint —
## path A's (0,0) end, the end a real board would anchor to a pad — is an
## ALLOWED edit, not refused. move_junction has no pad/board awareness (a pure
## candidate model has no pad lookup, same as add_via's own header notes) and
## does not need one to do its job correctly: detaching the draft's copper
## from its pad is exactly the kind of change re-validation exists to catch
## (INV-2) — the candidate_revision bump and staled verdict below ARE that
## catch, not a gap. This test makes that ruling explicit rather than leaving
## it an inference from the happy-path test's shared, non-terminal junction.
func _run_station10_move_junction_terminal_endpoint_allowed() -> void:
	var ctx: Dictionary = _edit_candidate_context()
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var cand = ws.get_candidate(cid)
	var rev_before: int = int(cand.candidate_revision)

	var out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "move_junction",
		"point": [0.0, 0.0], "to": [0.0, 30.0],
	}))
	check("moving path A's own pad-anchored terminal endpoint succeeds", bool(out.get("success", false)))
	check_eq("candidate_revision bumped", int(out.get("candidate_revision", -1)), rev_before + 1)
	check_eq("validation went stale — the detach IS what check/commit must now catch",
		str(out.get("validation", "")), "stale")
	var seg_a: Dictionary = cand.segments[0]
	check("the terminal point actually moved",
		(seg_a.get("points", []) as Array)[0] == Vector2(0.0, 30.0))


## Two genuinely disconnected paths whose junctions each independently fall
## within EDIT_EPS_MM of the query point, but not within it of EACH OTHER —
## refused BY NAME rather than silently acting on whichever path was found
## first (the exact flattened-index failure class docket 1026 warned against).
func _run_station10_move_junction_ambiguous() -> void:
	var ctx: Dictionary = _near_miss_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var eps: float = ctx["eps"]
	var cand = ws.get_candidate(cid)
	var rev_before: int = int(cand.candidate_revision)
	var pts_before: Array = [
		(cand.segments[0] as Dictionary).get("points", []).duplicate(),
		(cand.segments[1] as Dictionary).get("points", []).duplicate(),
	]

	var midpoint := Vector2(5.0 + 0.75 * eps, 0.0)
	var out: Dictionary = PanelTools._workspace_edit_candidate(host, _args({
		"candidate_id": cid, "op": "move_junction",
		"point": [midpoint.x, midpoint.y], "to": [5.0, 20.0],
	}))
	check("ambiguous move_junction is refused", not bool(out.get("success", true)))
	check_eq("named ambiguous_junction", str(out.get("error", "")), PcbWorkspace.ERR_AMBIGUOUS_JUNCTION)

	# NO-OP: neither path moved, no revision bump.
	check_eq("candidate_revision did not move", int(cand.candidate_revision), rev_before)
	for i in range(2):
		var seg: Dictionary = cand.segments[i]
		check("segment %d's points are untouched by the refusal" % i,
			(seg.get("points", []) as Array) == pts_before[i])


## P3 (fix round, docket 019fd095e694): a hit VIA that is within EDIT_EPS_MM
## of the query point but NOT coincident with the resolved path's own matched
## endpoint — a via belonging to a separate junction (the shape a via anchored
## on a disconnected path B takes when float noise happens to land it within
## tolerance of path A's query point) — is refused ambiguous_junction, same as
## a segment-level near-miss, and NOTHING moves. Before this station's fix
## round, via hits were collected candidate-wide by raw distance to `point`
## and moved unconditionally, without ever checking path membership — this is
## the regression test for that gap.
func _run_station10_move_junction_via_membership_ambiguous() -> void:
	var eps: float = PcbWorkspace.EDIT_EPS_MM
	var ctx: Dictionary = _edit_candidate_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var cand = ws.get_candidate(cid)
	var rev_before: int = int(cand.candidate_revision)

	# A stray via near path A's real junction (5,0), but NOT coincident with it
	# — the position a via genuinely anchored elsewhere (path B) would land at
	# after a small coordinate perturbation.
	var stray_via: Dictionary = PcbRouteCandidate.make_via(
		"via_stray_b", Vector2(5.0 + 1.2 * eps, 0.0), "top", "bottom")
	cand.add_via(stray_via)

	var segs_before: Array = [
		(cand.segments[0] as Dictionary).get("points", []).duplicate(),
		(cand.segments[1] as Dictionary).get("points", []).duplicate(),
	]
	var vias_before: Array = [
		(cand.vias[0] as Dictionary).get("position", Vector2()),
		(cand.vias[1] as Dictionary).get("position", Vector2()),
	]

	# Query point sits within EDIT_EPS_MM of path A's REAL junction (5,0) — so
	# path A's own segment endpoints are hit cleanly, no segment-level
	# ambiguity — but ALSO within EDIT_EPS_MM of the stray via, whose actual
	# position (5+1.2*eps) is itself MORE than EDIT_EPS_MM from (5,0).
	var query := Vector2(5.0 + 0.3 * eps, 0.0)
	var out: Dictionary = PanelTools._workspace_edit_candidate(host, _args({
		"candidate_id": cid, "op": "move_junction",
		"point": [query.x, query.y], "to": [5.0, 20.0],
	}))
	check("a via not coincident with the resolved path's endpoint is refused", not bool(out.get("success", true)))
	check_eq("named ambiguous_junction", str(out.get("error", "")), PcbWorkspace.ERR_AMBIGUOUS_JUNCTION)

	# NO-OP: nothing moved — not path A's segments, not either via.
	check_eq("candidate_revision did not move", int(cand.candidate_revision), rev_before)
	check("path A's segments are untouched",
		(cand.segments[0] as Dictionary).get("points", []) == segs_before[0]
			and (cand.segments[1] as Dictionary).get("points", []) == segs_before[1])
	check("both vias (the real one AND the stray one) are untouched",
		(cand.vias[0] as Dictionary).get("position", Vector2()) == vias_before[0]
			and (cand.vias[1] as Dictionary).get("position", Vector2()) == vias_before[1])


## No segment endpoint or via anywhere near the query point.
func _run_station10_move_junction_not_found() -> void:
	var ctx: Dictionary = _edit_candidate_context()
	var out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": ctx["cid"], "op": "move_junction",
		"point": [500.0, 500.0], "to": [5.0, 20.0],
	}))
	check("a move on empty geometry is refused", not bool(out.get("success", true)))
	check_eq("named junction_not_found", str(out.get("error", "")), PcbWorkspace.ERR_JUNCTION_NOT_FOUND)


## Moving path A's join point (5,0) onto (5,5) — path A's OTHER endpoint of
## the second leg — collapses that leg to zero length. Refused, not emitted
## (docket 019f9cc3245d), and no-op like every other refusal in this group.
func _run_station10_move_junction_degenerate() -> void:
	var ctx: Dictionary = _edit_candidate_context()
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var cand = ws.get_candidate(cid)
	var rev_before: int = int(cand.candidate_revision)

	var out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "move_junction",
		"point": [5.0, 0.0], "to": [5.0, 5.0],
	}))
	check("a degenerate move is refused", not bool(out.get("success", true)))
	check_eq("named degenerate_result", str(out.get("error", "")), PcbWorkspace.ERR_DEGENERATE_RESULT)
	check_eq("candidate_revision did not move", int(cand.candidate_revision), rev_before)
	check_eq("nothing was split or added",
		(cand.segments as Array).size(), 3)


## P4a (fix round, docket 019fd095e694): a segment short enough that BOTH its
## endpoints independently fall within EDIT_EPS_MM of the query point — its
## OWN neighbour is ITSELF in the moved set. Pre-move the two points already
## sit within 2*EDIT_EPS_MM of each other (the same junction, wearing two
## point-indices); moving both to `to` collapses the leg to EXACT zero length
## regardless of what `to` is. `to` here is 50mm away — nowhere near either
## point's PRE-move position — proving the refusal is unconditional rather
## than the old check's accidental catch (which only fired when `to` happened
## to land near a STATIC, non-moving neighbour).
func _run_station10_move_junction_degenerate_neighbor_in_moved_set() -> void:
	var eps: float = PcbWorkspace.EDIT_EPS_MM
	var data = PcbData.new()
	data.save_to_history("baseline")
	var ws = PcbWorkspace.new()
	var host = load(ANNOTATION_HOST_SCRIPT_PATH).new()
	var stub := _RouteIntentStubPanel.new()
	stub._data = data
	stub._ws = ws
	host.set_panel(stub)
	# BUILT DIRECTLY, not through ingest_record, and that is the point of this
	# comment. The leg here is 0.4 * EDIT_EPS_MM = 4e-5 mm long, and ingest now
	# DROPS a segment whose ends coincide within COPPER_COINCIDENT_EPS_MM (1e-3)
	# — correctly, because copper that short is unmanufacturable and reaches the
	# board as a zero-length segment that makes the whole thing uncompilable.
	# So this state can no longer arrive through ingest at all.
	#
	# The state is still worth reaching, because what THIS test exercises is the
	# EDIT-side guard: move_junction must refuse to collapse a leg whose
	# neighbour is itself in the moved set. Constructing the candidate directly
	# keeps that guard under test without asking the ingest guard to admit
	# copper it exists to reject.
	var seed_cand = PcbRouteCandidate.new()
	seed_cand.net = "N3"
	seed_cand.task_id = "N3|hint_degenerate_neighbor"
	seed_cand.add_segment(PcbRouteCandidate.make_segment(
		"seg_degenerate", "top", 0.3, [Vector2(0.0, 0.0), Vector2(0.4 * eps, 0.0)]))
	var cid := str(ws.add_candidate(seed_cand))
	var cand = ws.get_candidate(cid)
	var rev_before: int = int(cand.candidate_revision)
	var pts_before: Array = (cand.segments[0] as Dictionary).get("points", []).duplicate()

	var query := Vector2(0.2 * eps, 0.0)
	var out: Dictionary = PanelTools._workspace_edit_candidate(host, _args({
		"candidate_id": cid, "op": "move_junction",
		"point": [query.x, query.y], "to": [50.0, 50.0],
	}))
	check("a move whose neighbour is itself in the moved set is refused", not bool(out.get("success", true)))
	check_eq("named degenerate_result", str(out.get("error", "")), PcbWorkspace.ERR_DEGENERATE_RESULT)
	check_eq("candidate_revision did not move", int(cand.candidate_revision), rev_before)
	check("segment points are untouched",
		(cand.segments[0] as Dictionary).get("points", []) == pts_before)


## expected_candidate_revision guards BOTH ops, before either op's own
## model-side work runs — a stale caller is refused candidate_revision_conflict
## and nothing mutates. Symmetric with station 9's expected_constraint_revision.
func _run_station10_revision_conflict() -> void:
	var ctx: Dictionary = _edit_candidate_context()
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var cand = ws.get_candidate(cid)
	var actual: int = int(cand.candidate_revision)

	var stale_move: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "move_junction", "expected_candidate_revision": actual + 5,
		"point": [5.0, 0.0], "to": [5.0, 20.0],
	}))
	check("stale move_junction is refused", not bool(stale_move.get("success", true)))
	check_eq("named candidate_revision_conflict", str(stale_move.get("error", "")), "candidate_revision_conflict")
	check_eq("the refusal names the expected revision", int(stale_move.get("expected_candidate_revision", -1)), actual + 5)
	check_eq("the refusal names the ACTUAL revision", int(stale_move.get("actual_candidate_revision", -1)), actual)
	check_eq("nothing mutated", int(cand.candidate_revision), actual)

	var stale_via: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "insert_via", "expected_candidate_revision": actual + 5,
		"position": [50.0, 50.0], "from_layer": "top", "to_layer": "bottom",
	}))
	check("stale insert_via is refused too (BOTH ops guarded)", not bool(stale_via.get("success", true)))
	check_eq("named candidate_revision_conflict", str(stale_via.get("error", "")), "candidate_revision_conflict")
	check_eq("nothing mutated by the via leg either", int(cand.candidate_revision), actual)

	# The CORRECT revision succeeds, and the reply's bumped number is the one
	# a chained second edit must supply.
	var ok_move: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "move_junction", "expected_candidate_revision": actual,
		"point": [5.0, 0.0], "to": [5.0, 20.0],
	}))
	check("the correct expected_candidate_revision succeeds", bool(ok_move.get("success", false)))
	check_eq("candidate_revision bumped by one", int(ok_move.get("candidate_revision", -1)), actual + 1)


## P4b (fix round, docket 019fd095e694 — the "guard-parity VERIFIED" review
## finding, sharpest question of the cold review): move_junction's OWN
## reentrancy guard (mirrored, comment-for-comment, from add_via's) actually
## refuses commit_in_progress and mutates nothing while a commit transaction
## is mid-flight — not just an assertion in a doc comment. Both ops are
## exercised through the SAME candidate/workspace with the flag forced true,
## proving the guard holds for move_junction with the identical shape it
## already held for add_via (station 10's insert_via, delegating verbatim).
func _run_station10_commit_in_progress_guard() -> void:
	var ctx: Dictionary = _edit_candidate_context()
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var cand = ws.get_candidate(cid)
	var rev_before: int = int(cand.candidate_revision)
	var segs_before: int = (cand.segments as Array).size()
	var vias_before: int = (cand.vias as Array).size()

	ws._commit_transaction_active = true

	var move_out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "move_junction",
		"point": [5.0, 0.0], "to": [5.0, 20.0],
	}))
	check("move_junction refuses mid-commit", not bool(move_out.get("success", true)))
	check_eq("named commit_in_progress", str(move_out.get("error", "")), PcbWorkspace.ERR_COMMIT_IN_PROGRESS)

	var via_out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "insert_via",
		"position": [2.5, 0.0], "from_layer": "top", "to_layer": "bottom",
	}))
	check("insert_via (add_via) refuses mid-commit too", not bool(via_out.get("success", true)))
	check_eq("named commit_in_progress", str(via_out.get("error", "")), PcbWorkspace.ERR_COMMIT_IN_PROGRESS)

	# Reset the flag — this is a fixture-local simulation of reentrancy, not a
	# real commit, and a stuck flag would wedge every later edit on this
	# workspace.
	ws._commit_transaction_active = false

	check_eq("candidate_revision did not move", int(cand.candidate_revision), rev_before)
	check_eq("no segment was added or split", (cand.segments as Array).size(), segs_before)
	check_eq("no via was added or moved", (cand.vias as Array).size(), vias_before)


## insert_via delegates VERBATIM to RoutingWorkspace.add_via — success shape
## and refusals both pass through unchanged, proving this is delegation, not
## a reimplementation.
func _run_station10_insert_via_delegation() -> void:
	var ctx: Dictionary = _edit_candidate_context()
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var cand = ws.get_candidate(cid)
	var segs_before: int = (cand.segments as Array).size()
	var vias_before: int = (cand.vias as Array).size()

	# Success leg: split path A's top leg at its midpoint, same shape the
	# model-level INV-3 gate (group 6) exercises directly.
	var out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "insert_via",
		"position": [2.5, 0.0], "from_layer": "top", "to_layer": "bottom",
	}))
	check("insert_via succeeded", bool(out.get("success", false)))
	check_eq("op is echoed", str(out.get("op", "")), "insert_via")
	check("via_id is present (add_via's own reply field, passed through)", not str(out.get("via_id", "")).is_empty())
	check_eq("one segment was added (the split)", (cand.segments as Array).size(), segs_before + 1)
	check_eq("one via was added", (cand.vias as Array).size(), vias_before + 1)
	check_eq("candidate_revision reported matches the model",
		int(out.get("candidate_revision", -1)), int(cand.candidate_revision))

	# Refusal leg: add_via's own degenerate-on-vertex refusal, named identically
	# through this tool as it is called directly on the model (group 7).
	var refused: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "insert_via",
		"position": [0.0, 0.0], "from_layer": "top", "to_layer": "bottom",
	}))
	check("an on-vertex insert_via is refused", not bool(refused.get("success", true)))
	check_eq("add_via's own named refusal passes through unchanged",
		str(refused.get("error", "")), PcbWorkspace.ERR_DEGENERATE_AT_ENDPOINT)


## A terminal candidate (committed/rejected/superseded) is a record, not a
## draft — both ops refuse it, the same rule add_via already enforced before
## this station existed.
func _run_station10_terminal_candidate_refused() -> void:
	var ctx: Dictionary = _edit_candidate_context()
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	check("reject the candidate", ws.reject(cid))

	var move_out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "move_junction",
		"point": [5.0, 0.0], "to": [5.0, 20.0],
	}))
	check("move_junction on a terminal candidate is refused", not bool(move_out.get("success", true)))
	check_eq("named candidate_not_editable", str(move_out.get("error", "")), PcbWorkspace.ERR_NOT_EDITABLE)

	var via_out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "insert_via",
		"position": [2.5, 0.0], "from_layer": "top", "to_layer": "bottom",
	}))
	check("insert_via on a terminal candidate is refused too", not bool(via_out.get("success", true)))
	check_eq("named candidate_not_editable", str(via_out.get("error", "")), PcbWorkspace.ERR_NOT_EDITABLE)


## EDIT != POLICY, asserted directly (docket 1028): a candidate's task carries
## an EXPLICIT routing_constraint BEFORE the edit; move_junction and insert_via
## both succeed; the task's constraint (object identity AND revision) is
## BYTE-IDENTICAL afterward — a direct candidate edit never silently becomes
## future router policy, and it does not pin either.
func _run_station10_edit_never_touches_task_constraint() -> void:
	var ctx: Dictionary = _edit_candidate_context()
	var ws = ctx["ws"]
	var cid: String = ctx["cid"]
	var cand = ws.get_candidate(cid)
	var task = ws.get_task(str(cand.task_id))
	check("the candidate's task exists", task != null)
	if task == null:
		return
	task.routing_constraint = {
		"corridor_points": [Vector2(1.0, 1.0), Vector2(2.0, 2.0)],
		"preferred_layer": "top",
		"revision": 7,
		"authored_by": "human",
		"base_board_revision": 0,
		"owner_hint_id": "hint_1",
	}
	var constraint_before: Dictionary = (task.routing_constraint as Dictionary).duplicate(true)

	var move_out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": cid, "op": "move_junction",
		"point": [5.0, 0.0], "to": [5.0, 20.0],
	}))
	check("move_junction succeeded", bool(move_out.get("success", false)))
	check("the task's routing_constraint is BYTE-IDENTICAL after the edit",
		(task.routing_constraint as Dictionary) == constraint_before)
	check_eq("the constraint revision in particular did not move",
		int((task.routing_constraint as Dictionary).get("revision", -1)), 7)
	check_eq("the candidate was NOT pinned", str(cand.disposition), "proposed")

	var via_out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		# First-execution fix (boundary run): [50,50] is path B's START VERTEX
		# — add_via correctly refuses that as degenerate_insert_at_endpoint.
		# The midpoint of path B ((50,50)->(60,50)) is the intended split.
		"candidate_id": cid, "op": "insert_via",
		"position": [55.0, 50.0], "from_layer": "top", "to_layer": "bottom",
	}))
	check("insert_via succeeded", bool(via_out.get("success", false)))
	check("the task's routing_constraint is STILL byte-identical after the via edit too",
		(task.routing_constraint as Dictionary) == constraint_before)
	check_eq("the candidate was NOT pinned by the via edit either", str(cand.disposition), "proposed")


## An op outside {move_junction, insert_via} is refused by name rather than
## silently doing nothing or falling through to one of the two.
func _run_station10_unknown_op_refused() -> void:
	var ctx: Dictionary = _edit_candidate_context()
	var out: Dictionary = PanelTools._workspace_edit_candidate(ctx["host"], _args({
		"candidate_id": ctx["cid"], "op": "delete_segment",
		"point": [5.0, 0.0], "to": [5.0, 20.0],
	}))
	check("an unknown op is refused", not bool(out.get("success", true)))
	check_eq("named unknown_op", str(out.get("error", "")), "unknown_op")


# ══ 20x. EPOCH UX2 STATION 4 — route-quality metrics on candidate records ════

## Minimal segments-bearing stand-in for the pure-function rows (the real
## candidate object's only field _route_quality/_chained_runs read).
class _FakeQualityCandidate extends RefCounted:
	var segments: Array = []

	static func of(paths: Array) -> _FakeQualityCandidate:
		var c := _FakeQualityCandidate.new()
		for path in paths:
			var pts: Array = []
			for p in path:
				pts.append(Vector2(p[0], p[1]))
			c.segments.append({"points": pts})
		return c


## docket 019fde36651a — the HITL-5 lesson mechanized: candidate records carry
## bend_count / routed_length_mm / length_ratio so "this route wants a
## placement change" is a SIGNAL, not a human catch (the A/B was 5+5+5
## signal-chasing segments vs 2+2+5 placement-first on identical spans).
func _run_ux2_route_quality_metrics() -> void:
	print("-- 20x. route-quality metrics: bend_count / routed_length_mm / length_ratio (UX2 station 4) --")

	# Straight single run: 0 bends, ratio 1.0.
	var straight := _FakeQualityCandidate.of([[[0.0, 0.0], [10.0, 0.0]]])
	var q: Dictionary = PanelTools._route_quality(straight)
	check_eq("straight run: 0 bends", int(q.get("bend_count", -1)), 0)
	check_eq("straight run: routed length 10", float(q.get("routed_length_mm", 0.0)), 10.0)
	check_eq("straight run: ratio 1.0", float(q.get("length_ratio", 0.0)), 1.0)

	# Collinear joint (a via splitting a straight run into two segments) is
	# NOT a bend — the two segments chain and the direction never turns.
	var split := _FakeQualityCandidate.of([[[0.0, 0.0], [5.0, 0.0]], [[5.0, 0.0], [10.0, 0.0]]])
	check_eq("collinear via joint: still 0 bends",
		int(PanelTools._route_quality(split).get("bend_count", -1)), 0)

	# A degenerate ZERO-LENGTH leg sitting exactly AT a corner must not make
	# the bend vanish (cold review F3): the walk carries the last
	# non-degenerate direction across it.
	var dup := _FakeQualityCandidate.of([[[0.0, 0.0], [5.0, 0.0], [5.0, 0.0], [5.0, 5.0]]])
	check_eq("duplicated corner vertex: the bend still counts",
		int(PanelTools._route_quality(dup).get("bend_count", -1)), 1)

	# Vias-only / geometry-less candidate: honest zeros, ratio absent (cold
	# review F2 — uniform record shape, never missing bend/length keys).
	var empty := _FakeQualityCandidate.of([])
	var qe: Dictionary = PanelTools._route_quality(empty)
	check_eq("no geometry: bend_count 0", int(qe.get("bend_count", -1)), 0)
	check_eq("no geometry: routed 0", float(qe.get("routed_length_mm", -1.0)), 0.0)
	check("no geometry: ratio absent", not qe.has("length_ratio"))

	# misalignment_mm (HITL-6, docket 019fdf2bce15): the 2-pin alignment
	# signal — min(|dx|,|dy|) between a SINGLE run's endpoints. The exact
	# HITL-6 GND shape: 10.16mm run then a 0.54mm jog — 1 bend, ratio 1.0,
	# and misalignment says the bend is STRUCTURAL (pads offset 0.54).
	var gnd_shape := _FakeQualityCandidate.of([
		[[71.12, 10.7], [60.96, 10.7], [60.96, 10.16]]])
	var qg: Dictionary = PanelTools._route_quality(gnd_shape)
	check_eq("HITL-6 GND shape: 1 bend", int(qg.get("bend_count", -1)), 1)
	check("HITL-6 GND shape: ratio 1.0 (efficient — but not bend-free)",
		absf(float(qg.get("length_ratio", 0.0)) - 1.0) < 0.001)
	check("HITL-6 GND shape: misalignment_mm 0.54 (the structural offset)",
		absf(float(qg.get("misalignment_mm", -1.0)) - 0.54) < 0.001)
	check("straight run: misalignment_mm 0 (aligned — any bend would be a detour)",
		absf(float(q.get("misalignment_mm", -1.0))) < 0.001)

	# L-shape: 1 bend, rectilinear ratio exactly 1.0 (manhattan-minimal).
	var ell := _FakeQualityCandidate.of([[[0.0, 0.0], [5.0, 0.0], [5.0, 5.0]]])
	var ql: Dictionary = PanelTools._route_quality(ell)
	check_eq("L-shape: 1 bend", int(ql.get("bend_count", -1)), 1)
	check_eq("L-shape: ratio 1.0 (a rectilinear L is manhattan-minimal)",
		float(ql.get("length_ratio", 0.0)), 1.0)

	# The HITL-5 smell shape: a detour between near-neighbors — U over an
	# obstacle. (0,0)→(5,0)→(5,5)→(10,5)→(10,0)→(15,0): routed 25, endpoints
	# 15 apart → ratio 1.667, 4 bends. THE signal the station exists for.
	var detour := _FakeQualityCandidate.of([
		[[0.0, 0.0], [5.0, 0.0], [5.0, 5.0], [10.0, 5.0], [10.0, 0.0], [15.0, 0.0]]])
	var qd: Dictionary = PanelTools._route_quality(detour)
	check_eq("detour: 4 bends", int(qd.get("bend_count", -1)), 4)
	check_eq("detour: routed 25", float(qd.get("routed_length_mm", 0.0)), 25.0)
	# is_equal_approx, not ==: snappedf(25.0/15.0, 0.001) and the literal
	# 1.667 may differ by one ULP.
	check("detour: ratio ~1.667 (the placement-change smell)",
		absf(float(qd.get("length_ratio", 0.0)) - 1.667) < 0.0005)

	# Closed loop: manhattan minimum ~0 — ratio ABSENT (a ratio against zero
	# is noise), the other two metrics still report.
	var loop := _FakeQualityCandidate.of([
		[[0.0, 0.0], [5.0, 0.0], [5.0, 5.0], [0.0, 5.0], [0.0, 0.0]]])
	var qo: Dictionary = PanelTools._route_quality(loop)
	check("closed loop: length_ratio absent", not qo.has("length_ratio"))
	check_eq("closed loop: routed 20 still reported", float(qo.get("routed_length_mm", 0.0)), 20.0)

	# Record level, against the REAL multipad candidate (two disconnected
	# runs: L-path with a via at the turn + a straight far run): metrics ride
	# _candidate_record — the ONE shape every workspace tool reports.
	var ctx: Dictionary = _edit_candidate_context()
	var ws = ctx["ws"]
	var rec: Dictionary = PanelTools._candidate_record(ws, ws.get_candidate(str(ctx["cid"])))
	check_eq("multipad record: bend_count 1 (the L turn; via joint on the far run is straight)",
		int(rec.get("bend_count", -1)), 1)
	check_eq("multipad record: routed_length_mm 20", float(rec.get("routed_length_mm", 0.0)), 20.0)
	check_eq("multipad record: length_ratio 1.0 (both runs manhattan-minimal)",
		float(rec.get("length_ratio", 0.0)), 1.0)
	check("multipad record: NO misalignment_mm (two runs — no single pad pair to blame)",
		not rec.has("misalignment_mm"))


# ══ 21. EPOCH UX1 STATION 11 — replies name legal successors ═════════════════

## COMPACT GATE for station 11 (DCR 019fd095e694, docket 019fd095e694 "MCP
## surface" bullet "Replies name legal successors"): the `note` guidance key
## is present and names its expected legal-successor verb(s) on propose,
## edit_candidate, commit and reject. STRING-CONTAINS on verb names only —
## same convention this file's own line ~2246 already uses for
## add_route_intent's note — never a full-prose comparison, so a wording tweak
## to the sentence around the verb name does not make this suite brittle.
func _run_ux1_station11_next_step_guidance() -> void:
	print("-- 21. Station 11: replies name legal successors --")

	# ── propose reply names workspace_commit / workspace_reject ──────────────
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var proposed: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var propose_note := str(proposed.get("note", ""))
	check("propose reply carries a guidance note", not propose_note.is_empty())
	check("propose guidance names workspace_commit", propose_note.contains("workspace_commit"))
	check("propose guidance names workspace_reject", propose_note.contains("workspace_reject"))
	var proposed_cands: Array = proposed.get("candidates", [])
	check("propose landed a candidate to commit next", proposed_cands.size() > 0)
	var cid := str((proposed_cands[0] as Dictionary).get("candidate_id", "")) if proposed_cands.size() > 0 else ""

	# ── commit reply names propose (what's next once copper lands) ───────────
	var committed: Dictionary = PanelTools._workspace_commit(shim, _args({"candidate_id": cid}))
	var commit_note := str(committed.get("note", ""))
	check("commit reply carries a guidance note", not commit_note.is_empty())
	check("commit guidance names propose", commit_note.contains("propose"))
	ctx["driver"].free_panel(ctx["panel"])

	# ── edit_candidate reply names pin / reroute_route ────────────────────────
	var edit_ctx: Dictionary = _edit_candidate_context()
	var edited: Dictionary = PanelTools._workspace_edit_candidate(edit_ctx["host"], _args({
		"candidate_id": edit_ctx["cid"], "op": "move_junction",
		"point": [5.0, 0.0], "to": [5.0, 20.0],
	}))
	var edit_note := str(edited.get("note", ""))
	check("edit_candidate reply carries a guidance note", not edit_note.is_empty())
	check("edit_candidate guidance names pin", edit_note.contains("pin"))
	check("edit_candidate guidance names reroute_route", edit_note.contains("reroute_route"))

	# ── reject reply names re-propose / edit the intent ───────────────────────
	var reject_ctx: Dictionary = await _panel_context()
	var reject_shim = reject_ctx["shim"]
	var reproposed: Dictionary = await PanelTools._workspace_propose(reject_shim, _args())
	var reproposed_cands: Array = reproposed.get("candidates", [])
	check("second propose landed a candidate to reject next", reproposed_cands.size() > 0)
	var rcid := str((reproposed_cands[0] as Dictionary).get("candidate_id", "")) \
		if reproposed_cands.size() > 0 else ""
	var rejected: Dictionary = PanelTools._workspace_reject(reject_shim, _args({"candidate_id": rcid}))
	var reject_note := str(rejected.get("note", ""))
	check("reject reply carries a guidance note", not reject_note.is_empty())
	check("reject guidance names re-propose", reject_note.contains("re-propose"))
	reject_ctx["driver"].free_panel(reject_ctx["panel"])


# ══ 22. EPOCH UX1 STATION 12: legacy waypoint-hint migration ═════════════════
#
# DCR 019fd095e694, docket 019fd057ea0b comment 1028, §"LEGACY WAYPOINT-HINT
# MIGRATION" (adopted verbatim). panel_tools.gd's _seed_legacy_waypoint_constraints
# (propose-time, before _run_router) + PcbAnnotationHost._refuses_superseded_waypoint_edit
# (update_annotation's own edit-refusal gate).

## A REAL pcb_route_hint annotation carrying real inline waypoints AND
## net_names naming a REAL board net — the legacy-authoring shape this
## station migrates. Built the same way _seed_net_named_hint (group 11) does,
## with an explicit detail_level so a 'detailed' control case can be built
## too (default "" lets build_route_hint_envelope auto-derive it from
## waypoint count — 2-3 points -> "guided", the common legacy case). Declares
## `net` on the board first (station 12's own net resolution needs
## PCBData.get_net_names() to carry it, same as every other
## _propose_scope/_reroute_scope net-membership check in this file). Returns
## the hint id.
func _seed_legacy_waypoint_hint(host, data, net: String, waypoints: Array, detail_level: String = "") -> String:
	_declare_net(data, net)
	var env: Dictionary = host.build_route_hint_envelope(
		0.0, 0.0, "", "F.Cu", "waypoint", waypoints, "human", detail_level)
	var kp: Dictionary = env.get("kind_payload", {})
	kp["net_names"] = [net]
	env["kind_payload"] = kp
	return str(host.add_annotation_v2(env))


func _run_station12_legacy_seeding() -> void:
	print("-- 22. Station 12: legacy waypoint-hint migration (seeding + edit refusal) --")
	await _run_station12_seeds_on_propose()
	await _run_station12_seed_survives_router_failure()
	await _run_station12_second_propose_does_not_reseed()
	await _run_station12_post_seed_edit_refusal()
	await _run_station12_detailed_hint_untouched()
	await _run_station12_already_constrained_task_not_reseeded()
	await _run_station12_bus_hint_never_seeded()
	await _run_station12_apply_route_hints_also_seeds()
	await _run_station12_marker_reinjected_on_omission()
	await _run_station12_undo_seam_reinjects_marker()
	await _run_station12_merged_task_never_reseeded()
	await _run_station12_conflicting_seeds_survive_merge()
	await _run_station12_convert_to_detailed()
	await _run_station12_recon_consistent_noop()
	await _run_station12_recon_marker_without_constraint()
	await _run_station12_recon_constraint_without_marker()
	await _run_station12_recon_marker_out_of_shape()
	await _run_station12_recon_undo_of_conversion()


## 22a: a legacy guided hint carrying waypoints seeds its task's
## routing_constraint at propose time — authored_by "migration",
## seeded_from_hint_id/_revision provenance, revision 1, corridor equal to the
## hint's own waypoints — task_constraints carries it into the router
## request, and the owning hint is stamped
## waypoints_superseded_by_constraint_revision (waypoints themselves
## untouched, additive-only, same contract station 9's own stamp already
## established).
func _run_station12_seeds_on_propose() -> void:
	print("-- 22a. legacy guided hint with waypoints: propose seeds the task constraint --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var wp: Array = [[0.0, 0.0], [5.0, 0.0]]
	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_PWR", wp)

	# ── fixture sanity ────────────────────────────────────────────────────
	var before_ann: Dictionary = host.get_by_id(hint_id)
	var before_kp: Dictionary = before_ann.get("kind_payload", {})
	check("fixture sanity: hint carries waypoints", not (before_kp.get("waypoints", []) as Array).is_empty())
	check_eq("fixture sanity: detail_level auto-derived to guided (2 points)",
		str(before_kp.get("detail_level", "")), "guided")
	check("fixture sanity: not yet superseded",
		not before_kp.has("waypoints_superseded_by_constraint_revision"))
	check("fixture sanity: task does not exist yet", ws.task_for_hint(hint_id) == null)

	shim.reply = {
		"routes": [{
			"net": "LEGACY_PWR",
			"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("propose succeeded", bool(out.get("success", false)))

	var task = ws.task_for_hint(hint_id)
	check("task now exists (eagerly minted, singleton 'net|hint_id' key)", task != null)
	if task != null:
		check("task is constrained", task.is_constrained())
		check_eq("revision is 1", int(task.routing_constraint.get("revision", 0)), 1)
		check_eq("authored_by is migration", str(task.routing_constraint.get("authored_by", "")), "migration")
		check_eq("owner_hint_id names this hint", str(task.routing_constraint.get("owner_hint_id", "")), hint_id)
		check_eq("seeded_from_hint_id names this hint",
			str(task.routing_constraint.get("seeded_from_hint_id", "")), hint_id)
		check_eq("seeded_from_hint_revision is 0 (a fresh, never-edited hint)",
			int(task.routing_constraint.get("seeded_from_hint_revision", -1)), 0)
		var pts: Array = task.routing_constraint.get("corridor_points", [])
		check_eq("corridor carries both of the hint's own waypoints", pts.size(), 2)
		if pts.size() == 2:
			check("point 0 matches the hint's own first waypoint",
				(pts[0] as Vector2).is_equal_approx(Vector2(0.0, 0.0)))
			check("point 1 matches the hint's own second waypoint",
				(pts[1] as Vector2).is_equal_approx(Vector2(5.0, 0.0)))

	# ── the seeded constraint reached the router request (station 9, unmodified) ──
	var call: Dictionary = shim.calls[shim.calls.size() - 1]
	var tc: Dictionary = (call.get("extra", {}) as Dictionary).get("task_constraints", {})
	check("request carries task_constraints for the seeded hint", tc.has(hint_id))

	# ── the hint itself: stamped, waypoints preserved ────────────────────────
	var after_ann: Dictionary = host.get_by_id(hint_id)
	var after_kp: Dictionary = after_ann.get("kind_payload", {})
	check("legacy waypoints are STILL PRESENT — additive, never cleared",
		not (after_kp.get("waypoints", []) as Array).is_empty())
	check("...now stamped waypoints_superseded_by_constraint_revision",
		after_kp.has("waypoints_superseded_by_constraint_revision"))
	check_eq("...naming revision 1 (the constraint this seed just wrote)",
		int(after_kp.get("waypoints_superseded_by_constraint_revision", -1)), 1)

	ctx["driver"].free_panel(ctx["panel"])


## 22b (docket 019fd057ea0b comment 1028's durability invariant, same wording
## station 9's own 19d test carries): the seeded constraint is written BEFORE
## the router runs, so a router leg that then FAILS leaves the seed standing
## — steering durability must not depend on obtaining a candidate.
func _run_station12_seed_survives_router_failure() -> void:
	print("-- 22b. seeding survives a failed router leg (durability, comment 1028) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_PWR2", [[1.0, 1.0], [2.0, 2.0]])
	check("task does not exist yet", ws.task_for_hint(hint_id) == null)

	shim.answer_ok = false
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("propose itself failed (router unavailable)", not bool(out.get("success", true)))

	var task = ws.task_for_hint(hint_id)
	check("the task was seeded anyway — the write happened before the failed router call",
		task != null and task.is_constrained())
	if task != null:
		check_eq("authored_by is migration", str(task.routing_constraint.get("authored_by", "")), "migration")
		check_eq("revision is 1", int(task.routing_constraint.get("revision", 0)), 1)

	var ann: Dictionary = host.get_by_id(hint_id)
	check("the hint is stamped superseded despite the router failure",
		(ann.get("kind_payload", {}) as Dictionary).has("waypoints_superseded_by_constraint_revision"))

	shim.answer_ok = true
	ctx["driver"].free_panel(ctx["panel"])


## 22c: a SECOND propose of the same hint does not re-seed — the constraint's
## revision stays 1, and its fields (authored_by included) are untouched. This
## is the "singleton task already constrained" half of the ONE-TIME gate
## (22f below is the "task constrained by a DIFFERENT channel" half).
func _run_station12_second_propose_does_not_reseed() -> void:
	print("-- 22c. a second propose does not re-seed (revision stays 1) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_PWR3", [[0.0, 0.0], [3.0, 0.0]])
	shim.reply = {
		"routes": [{
			"net": "LEGACY_PWR3",
			"segments": [{"start": [0.0, 0.0], "end": [3.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var first: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("first propose succeeded", bool(first.get("success", false)))
	var task = ws.task_for_hint(hint_id)
	check("task constrained after the first propose", task != null and task.is_constrained())
	check_eq("revision is 1 after the first propose", int(task.routing_constraint.get("revision", 0)), 1)

	var second: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("second propose succeeded", bool(second.get("success", false)))
	var task2 = ws.task_for_hint(hint_id)
	check("still the SAME constrained task", task2 != null and task2 == task)
	check_eq("revision is STILL 1 — the hint's waypoints were not re-read",
		int(task2.routing_constraint.get("revision", 0)), 1)
	check_eq("authored_by still migration (never overwritten)",
		str(task2.routing_constraint.get("authored_by", "")), "migration")

	ctx["driver"].free_panel(ctx["panel"])


## 22d (station 12's other half — PcbAnnotationHost.update_annotation): once
## a hint is stamped superseded, an update that CHANGES kind_payload.waypoints
## is refused (return false, no mutation); an update that leaves waypoints
## untouched (here: kind_payload.text) passes through unaffected.
func _run_station12_post_seed_edit_refusal() -> void:
	print("-- 22d. post-seed waypoints edit refused; non-waypoints edit passes --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var data = ctx["data"]

	var wp: Array = [[0.0, 0.0], [4.0, 0.0]]
	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_PWR4", wp)
	shim.reply = {
		"routes": [{
			"net": "LEGACY_PWR4",
			"segments": [{"start": [0.0, 0.0], "end": [4.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("propose succeeded", bool(out.get("success", false)))

	var ann: Dictionary = host.get_by_id(hint_id)
	check("fixture sanity: hint is stamped superseded",
		(ann.get("kind_payload", {}) as Dictionary).has("waypoints_superseded_by_constraint_revision"))

	# ── waypoints edit: refused, nothing mutated ──────────────────────────
	var changed: Dictionary = ann.duplicate(true)
	var changed_kp: Dictionary = (changed.get("kind_payload", {}) as Dictionary).duplicate(true)
	changed_kp["waypoints"] = [[0.0, 0.0], [9.0, 9.0]]
	changed["kind_payload"] = changed_kp
	var ok1: bool = host.update_annotation(hint_id, changed)
	check("a waypoints edit on a superseded hint is REFUSED (returns false)", not ok1)
	var still: Dictionary = host.get_by_id(hint_id)
	var still_kp: Dictionary = still.get("kind_payload", {})
	var still_wp: Array = still_kp.get("waypoints", [])
	check_eq("stored waypoints unchanged by the refused edit", still_wp.size(), 2)
	if still_wp.size() == 2:
		check_eq("...still the original second point's x", float((still_wp[1] as Array)[0]), 4.0)

	# ── non-waypoints edit on the SAME superseded hint: passes ───────────────
	var changed2: Dictionary = still.duplicate(true)
	var changed2_kp: Dictionary = (changed2.get("kind_payload", {}) as Dictionary).duplicate(true)
	changed2_kp["text"] = "edited note"
	changed2["kind_payload"] = changed2_kp
	var ok2: bool = host.update_annotation(hint_id, changed2)
	check("a non-waypoints edit on the SAME superseded hint SUCCEEDS", ok2)
	var after2: Dictionary = host.get_by_id(hint_id)
	var after2_kp: Dictionary = after2.get("kind_payload", {})
	check_eq("text field actually changed", str(after2_kp.get("text", "")), "edited note")
	check_eq("waypoints still unchanged by the accepted edit",
		(after2_kp.get("waypoints", []) as Array).size(), 2)

	ctx["driver"].free_panel(ctx["panel"])


## 22e: a 'detailed' hint (the as-drawn channel) is untouched by every half of
## this station — never seeded (no task constraint lands), never stamped, and
## therefore an edit to its waypoints is never refused by the guard either.
## detail_level is passed explicitly here (rather than relying on
## auto-derivation from waypoint count) so the test asserts the FIELD, not an
## accident of point count.
func _run_station12_detailed_hint_untouched() -> void:
	print("-- 22e. a 'detailed' hint is never seeded and never refused --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var wp: Array = [[0.0, 0.0], [1.0, 0.0], [2.0, 1.0], [3.0, 1.0]]
	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_PWR5", wp, "detailed")

	var before_ann: Dictionary = host.get_by_id(hint_id)
	check_eq("fixture sanity: detail_level is detailed",
		str((before_ann.get("kind_payload", {}) as Dictionary).get("detail_level", "")), "detailed")

	shim.reply = {
		"routes": [{
			"net": "LEGACY_PWR5",
			"segments": [{"start": [0.0, 0.0], "end": [3.0, 1.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("propose succeeded", bool(out.get("success", false)))

	var task = ws.task_for_hint(hint_id)
	check("no SEEDED constraint landed on this hint's task",
		task == null or not task.is_constrained())

	var after_ann: Dictionary = host.get_by_id(hint_id)
	check("the hint was NEVER stamped superseded",
		not (after_ann.get("kind_payload", {}) as Dictionary).has("waypoints_superseded_by_constraint_revision"))

	# an edit to its waypoints is NOT refused either — nothing ever marked it.
	var changed: Dictionary = after_ann.duplicate(true)
	var changed_kp: Dictionary = (changed.get("kind_payload", {}) as Dictionary).duplicate(true)
	changed_kp["waypoints"] = [[0.0, 0.0], [5.0, 5.0]]
	changed["kind_payload"] = changed_kp
	var ok: bool = host.update_annotation(hint_id, changed)
	check("a waypoints edit on a 'detailed' hint is NOT refused by station 12's guard", ok)

	ctx["driver"].free_panel(ctx["panel"])


## 22f: a hint carrying waypoints whose task is ALREADY constrained by some
## OTHER channel (here: a direct write, standing in for a prior
## add_route_intent corridor or an explicit steer) is left completely alone —
## the pre-existing constraint's fields are untouched, and the hint is never
## stamped (nothing this station did caused the supersession).
func _run_station12_already_constrained_task_not_reseeded() -> void:
	print("-- 22f. a hint whose task is ALREADY constrained by another channel is not re-seeded --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_PWR6", [[0.0, 0.0], [7.0, 0.0]])

	# Pre-constrain the hint's own eager task through some OTHER channel —
	# the SAME singleton key ("net|hint_id") ensure_task/_add_route_intent
	# mint, so this is indistinguishable, model-side, from a prior
	# add_route_intent corridor or an explicit steer having landed first.
	var task_id: String = "LEGACY_PWR6|%s" % hint_id
	var pre_task = ws.ensure_task(task_id, "LEGACY_PWR6")
	pre_task.routing_constraint = {
		"corridor_points": [Vector2(100.0, 100.0)],
		"preferred_layer": "",
		"revision": 5,
		"authored_by": "human",
		"base_board_revision": 0,
		"owner_hint_id": hint_id,
	}

	shim.reply = {
		"routes": [{
			"net": "LEGACY_PWR6",
			"segments": [{"start": [0.0, 0.0], "end": [7.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("propose succeeded", bool(out.get("success", false)))

	var task = ws.task_for_hint(hint_id)
	check("still the SAME pre-existing task", task != null and task == pre_task)
	check_eq("constraint UNCHANGED — authored_by still human",
		str(task.routing_constraint.get("authored_by", "")), "human")
	check_eq("revision UNCHANGED (still 5)", int(task.routing_constraint.get("revision", 0)), 5)
	check_eq("corridor UNCHANGED (1 point — not replaced by the hint's own 2 waypoints)",
		(task.routing_constraint.get("corridor_points", []) as Array).size(), 1)

	var ann: Dictionary = host.get_by_id(hint_id)
	check("the hint was NEVER stamped — this station never touched it",
		not (ann.get("kind_payload", {}) as Dictionary).has("waypoints_superseded_by_constraint_revision"))

	ctx["driver"].free_panel(ctx["panel"])


## 22g (H1-1, fix round): a BUS-BRANCH hint (_is_bus_branch_hint —
## hint_type=="bus" with >=2 net_names, mirroring route_bridge.
## hints_to_router's own bus-branch ENTRY condition) carrying waypoints is
## NEVER seeded — its waypoints are not the single-net corridor this station
## writes, the exact "PROVEN REGRESSION" class _propose_scope's own doc names
## for the scope builders (group 11 CASE 3/4), reused here rather than
## re-derived. No task is minted at all (not merely left unconstrained), and
## the hint is never stamped superseded.
func _run_station12_bus_hint_never_seeded() -> void:
	print("-- 22g. a bus-branch hint carrying waypoints is never seeded (H1-1) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	_declare_net(data, "BUS_LEG_A")
	_declare_net(data, "BUS_LEG_B")
	var bus_hint_id: String = _seed_bus_hint(host, "BUS_LEG_A", "BUS_LEG_B")
	var before_kp: Dictionary = (host.get_by_id(bus_hint_id).get("kind_payload", {}) as Dictionary)
	check("fixture sanity: the bus hint carries waypoints",
		not (before_kp.get("waypoints", []) as Array).is_empty())
	check("fixture sanity: task does not exist yet", ws.task_for_hint(bus_hint_id) == null)

	# Router leg forced to fail (same isolation idiom as 22b) so the only
	# thing under test is the SEEDING gate itself, run before any router hop.
	shim.answer_ok = false
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [bus_hint_id]}))
	check("propose itself failed (router unavailable, by design)", not bool(out.get("success", true)))

	check("no task was ever minted for the bus hint",
		ws.task_for_hint(bus_hint_id) == null)
	var after_kp: Dictionary = (host.get_by_id(bus_hint_id).get("kind_payload", {}) as Dictionary)
	check("the bus hint was never stamped superseded",
		not after_kp.has("waypoints_superseded_by_constraint_revision"))

	shim.answer_ok = true
	ctx["driver"].free_panel(ctx["panel"])


## 22h (claim coverage): minerva_pcb_apply_route_hints is the OTHER
## propose-time entry point _seed_legacy_waypoint_constraints is wired into
## (panel_tools.gd's own doc names both callers) — only _workspace_propose was
## exercised above. Same fixture/assertions as 22a, driven through
## PanelTools._apply_route_hints instead (commit defaults false, so this
## exercises the SAME _propose_into_workspace landing path as
## _workspace_propose, sharing one router round trip with the commit=true
## branch per that function's own doc).
func _run_station12_apply_route_hints_also_seeds() -> void:
	print("-- 22h. the OTHER entry point (_apply_route_hints) also seeds --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var wp: Array = [[0.0, 0.0], [6.0, 0.0]]
	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_APPLY", wp)
	check("fixture sanity: task does not exist yet", ws.task_for_hint(hint_id) == null)

	shim.reply = {
		"routes": [{
			"net": "LEGACY_APPLY",
			"segments": [{"start": [0.0, 0.0], "end": [6.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._apply_route_hints(shim, _args({"hint_ids": [hint_id]}))
	check("apply_route_hints (propose branch) succeeded", bool(out.get("success", false)))

	var task = ws.task_for_hint(hint_id)
	check("task now exists (eagerly minted, singleton 'net|hint_id' key)", task != null)
	if task != null:
		check("task is constrained", task.is_constrained())
		check_eq("authored_by is migration", str(task.routing_constraint.get("authored_by", "")), "migration")
		check_eq("revision is 1", int(task.routing_constraint.get("revision", 0)), 1)

	var after_kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("...now stamped waypoints_superseded_by_constraint_revision via THIS entry point too",
		after_kp.has("waypoints_superseded_by_constraint_revision"))

	ctx["driver"].free_panel(ctx["panel"])


## 22i (H2-1, fix round): the marker is HOST-OWNED state. An update whose
## incoming kind_payload OMITS waypoints_superseded_by_constraint_revision —
## standing in for a partial-payload caller (e.g. an MCP patch) or the first
## half of a deliberate two-step bypass — while leaving waypoints themselves
## untouched (so it is not itself refused) must not be able to strip the
## marker: PcbAnnotationHost.update_annotation re-injects it from `old`
## before storing. Proven both by re-reading the stored annotation AND by
## showing the guard is still armed: a FOLLOW-UP edit that changes waypoints
## is still refused, which could only happen if the marker truly survived in
## STORAGE, not just in the update's return value.
func _run_station12_marker_reinjected_on_omission() -> void:
	print("-- 22i. update omitting the marker still stores it (H2-1); guard re-arms --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var data = ctx["data"]

	var wp: Array = [[0.0, 0.0], [8.0, 0.0]]
	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_REINJECT", wp)
	shim.reply = {
		"routes": [{
			"net": "LEGACY_REINJECT",
			"segments": [{"start": [0.0, 0.0], "end": [8.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("propose succeeded", bool(out.get("success", false)))
	var seeded_ann: Dictionary = host.get_by_id(hint_id)
	check("fixture sanity: hint is stamped superseded",
		(seeded_ann.get("kind_payload", {}) as Dictionary).has("waypoints_superseded_by_constraint_revision"))

	# ── an update that OMITS the marker, waypoints UNCHANGED ─────────────────
	var stripped: Dictionary = seeded_ann.duplicate(true)
	var stripped_kp: Dictionary = (stripped.get("kind_payload", {}) as Dictionary).duplicate(true)
	stripped_kp.erase("waypoints_superseded_by_constraint_revision")
	stripped["kind_payload"] = stripped_kp
	var ok1: bool = host.update_annotation(hint_id, stripped)
	check("the marker-omitting update itself succeeds (waypoints untouched, not refused)", ok1)

	var restored: Dictionary = host.get_by_id(hint_id)
	var restored_kp: Dictionary = restored.get("kind_payload", {})
	check("the marker is STILL PRESENT in storage — re-injected, not silently dropped",
		restored_kp.has("waypoints_superseded_by_constraint_revision"))
	check_eq("...re-injected value matches what `old` carried",
		int(restored_kp.get("waypoints_superseded_by_constraint_revision", -1)), 1)

	# ── the guard is still armed: a waypoints edit is STILL refused ──────────
	var changed: Dictionary = restored.duplicate(true)
	var changed_kp: Dictionary = (changed.get("kind_payload", {}) as Dictionary).duplicate(true)
	changed_kp.erase("waypoints_superseded_by_constraint_revision")  # the bypass's 2nd step
	changed_kp["waypoints"] = [[0.0, 0.0], [99.0, 99.0]]
	changed["kind_payload"] = changed_kp
	var ok2: bool = host.update_annotation(hint_id, changed)
	check("a waypoints edit — even one that ALSO tries to drop the marker in the same call — is REFUSED", not ok2)
	var still: Dictionary = host.get_by_id(hint_id)
	check_eq("stored waypoints unchanged by the refused edit",
		((still.get("kind_payload", {}) as Dictionary).get("waypoints", []) as Array).size(), 2)

	ctx["driver"].free_panel(ctx["panel"])


## 22j (H2-2, fix round): the undo/redo seam
## (_shift_hint_revision/_suppress_hint_history) must not be caught by the
## edit-refusal guard — a restored PRIOR payload legitimately changes
## waypoints back to a pre-seed value, and that IS the undo, not an editor
## trying to bypass the guard. Fixture: a legacy hint is edited ONCE (pushing
## a pre-seed waypoints snapshot onto its revision stack) before it is seeded
## and stamped, so its revision stack holds a real prior payload predating
## the marker. undo_hint_revision must then (1) succeed despite changing
## waypoints, and (2) leave the marker PRESENT on the restored annotation
## (H2-1's re-injection, proven the same way as 22i: a fresh waypoints edit
## right after the undo is still refused — the guard re-arms).
func _run_station12_undo_seam_reinjects_marker() -> void:
	print("-- 22j. undo restores pre-seed waypoints without refusal; guard re-arms after (H2-2) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var data = ctx["data"]

	var wp0: Array = [[0.0, 0.0], [3.0, 0.0]]
	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_UNDO", wp0)

	# A REAL prior edit, before any seeding — pushes wp0 onto the revision
	# stack and leaves the hint's CURRENT waypoints at wp1.
	var wp1: Array = [[0.0, 0.0], [3.0, 0.0], [6.0, 0.0]]
	var pre_seed_ann: Dictionary = host.get_by_id(hint_id)
	var edited: Dictionary = pre_seed_ann.duplicate(true)
	var edited_kp: Dictionary = (edited.get("kind_payload", {}) as Dictionary).duplicate(true)
	edited_kp["waypoints"] = wp1
	edited["kind_payload"] = edited_kp
	check("fixture setup: the pre-seed waypoints edit succeeds", host.update_annotation(hint_id, edited))
	var stack_before_seed: Array = (host.get_by_id(hint_id).get("revision_stack", []) as Array)
	check_eq("fixture sanity: one prior revision recorded (the wp0 payload)", stack_before_seed.size(), 1)

	# Seed + stamp against the CURRENT waypoints (wp1).
	shim.reply = {
		"routes": [{
			"net": "LEGACY_UNDO",
			"segments": [{"start": [0.0, 0.0], "end": [6.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("propose succeeded", bool(out.get("success", false)))
	var seeded_ann: Dictionary = host.get_by_id(hint_id)
	var seeded_kp: Dictionary = seeded_ann.get("kind_payload", {})
	check("fixture sanity: seeded against the CURRENT (wp1) waypoints",
		JSON.stringify(seeded_kp.get("waypoints", [])) == JSON.stringify(wp1))
	check("fixture sanity: stamped superseded",
		seeded_kp.has("waypoints_superseded_by_constraint_revision"))

	# ── the undo itself: changes waypoints back to wp0, must NOT be refused ──
	var undo_result: Dictionary = host.undo_hint_revision(hint_id)
	check("undo_hint_revision succeeds despite restoring different waypoints (not refused)",
		bool(undo_result.get("ok", false)))

	var after_undo_ann: Dictionary = host.get_by_id(hint_id)
	var after_undo_kp: Dictionary = after_undo_ann.get("kind_payload", {})
	check("waypoints actually restored to the pre-seed (wp0) value",
		JSON.stringify(after_undo_kp.get("waypoints", [])) == JSON.stringify(wp0))
	check("the marker is PRESENT on the restored annotation — re-injected across the undo (H2-1)",
		after_undo_kp.has("waypoints_superseded_by_constraint_revision"))

	# ── the guard re-arms: a FRESH waypoints edit right after is refused ─────
	var reedit: Dictionary = after_undo_ann.duplicate(true)
	var reedit_kp: Dictionary = (reedit.get("kind_payload", {}) as Dictionary).duplicate(true)
	reedit_kp["waypoints"] = [[0.0, 0.0], [42.0, 42.0]]
	reedit["kind_payload"] = reedit_kp
	var ok: bool = host.update_annotation(hint_id, reedit)
	check("a fresh waypoints edit after the undo is REFUSED again — the guard re-armed", not ok)

	ctx["driver"].free_panel(ctx["panel"])


## 22k (H1-2, fix round, MED): a hint whose OWN singleton task was absorbed
## into a MERGED multi-hint task (H3-1 absorption — some other hint's route
## merged with this one) must never be re-seeded: task_for_hint's membership
## fallback returns the merged task, but that task is NOT this hint's own —
## minting a fresh singleton beside it (the pre-fix behavior whenever the
## merged task happened to land unconstrained — e.g. an absorption of
## never-constrained singletons; since P1-A/Codex 1047 a constraint CONFLICT
## keeps its singletons alive instead of dropping them, so the unconstrained
## merge arises only from genuinely unconstrained absorptions) would fork a
## corridor away from the task the router actually answers for this hint.
## The merged task is built directly (same direct-injection technique 22f
## uses to simulate "another channel") rather than via a real merging
## propose, so the assertion isolates the SEEDING gate itself — the fabricated
## task's key names TWO hints, deliberately UNCONSTRAINED, which is exactly
## the shape the OLD code's `is_constrained()`-only check let slip through.
func _run_station12_merged_task_never_reseeded() -> void:
	print("-- 22k. a hint whose singleton was absorbed into a merged task is never re-seeded (H1-2) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var wp: Array = [[0.0, 0.0], [4.0, 0.0]]
	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "MERGED_NET", wp)

	# Fabricate the merged task exactly as a real H3-1 absorption would leave
	# it: a key naming BOTH this hint and some other hint, UNCONSTRAINED
	# (e.g. the absorption's own CONFLICT rule kept neither absorbed
	# constraint). Same "<net>|<sorted hint ids>" format group 18's real
	# merge-absorption fixture asserts (_task_key, pcb_routing_workspace.gd).
	var sorted_ids: Array = [hint_id, "other_hint_owning_this_merge"]
	sorted_ids.sort()
	var merged_task_id := "MERGED_NET|%s" % ",".join(sorted_ids)
	var merged_task = ws.ensure_task(merged_task_id, "MERGED_NET")
	check("fixture setup: the merged task is genuinely a 2-hint membership",
		ws.task_hint_ids(merged_task_id).size() == 2)
	check("fixture setup: the merged task starts UNCONSTRAINED (the shape the old code slipped past)",
		not merged_task.is_constrained())
	check("fixture sanity: task_for_hint falls back to the merged task (membership match)",
		ws.task_for_hint(hint_id) == merged_task)

	# Router leg forced to fail (22b/22g's isolation idiom) so only the
	# seeding gate itself is under test.
	shim.answer_ok = false
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("propose itself failed (router unavailable, by design)", not bool(out.get("success", true)))

	check("no NEW singleton task was minted beside the merged one",
		ws.get_task("MERGED_NET|%s" % hint_id) == null)
	check_eq("exactly the one (merged) task exists — no resurrection", (ws.list_tasks() as Array).size(), 1)
	check("the merged task is STILL unconstrained — untouched by this station",
		not merged_task.is_constrained())
	check("task_for_hint still resolves to the SAME merged task", ws.task_for_hint(hint_id) == merged_task)

	var ann: Dictionary = host.get_by_id(hint_id)
	check("the hint was never stamped — this station never touched it",
		not (ann.get("kind_payload", {}) as Dictionary).has("waypoints_superseded_by_constraint_revision"))

	shim.answer_ok = true
	ctx["driver"].free_panel(ctx["panel"])


## 22l (P1-A, Codex 1047 consolidated review — boundary-delta test 1): TWO
## guided legacy hints on ONE net, both seeded on the same propose, whose
## (shimmed) worker reply fuses both hint ids onto a single route. The merge
## absorption finds two conflicting seeded constraints. Pre-fix this was the
## PERMANENT dead state Codex's P1 named: both singletons erased, neither
## constraint kept, both hints still stamped superseded (edit-refused), and
## the H1-2 membership gate refusing to ever re-seed — superseded waypoints
## with nothing left steering. Post-fix contract asserted here: both
## singleton tasks SURVIVE with their own constraints, the merged task is
## unconstrained, the supersession stamps stay TRUTHFUL (a live constraint
## still matches each stamp), the conflict is surfaced, and a SECOND propose
## still emits BOTH corridors per-hint — steering never dies.
func _run_station12_conflicting_seeds_survive_merge() -> void:
	print("-- 22l. two guided legacy hints, one net: conflicting merge keeps both seeds steering (P1-A) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var hint_a: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_MERGE", [[0.0, 0.0], [5.0, 0.0]])
	var hint_b: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_MERGE", [[0.0, 2.0], [5.0, 2.0], [6.0, 2.0]])

	shim.reply = {
		"routes": [{
			"net": "LEGACY_MERGE",
			"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_a, hint_b],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_a, hint_b]}))
	check("first propose succeeded", bool(out.get("success", false)))

	# ── the conflict is surfaced, not silent ─────────────────────────────────
	var conflicts: Array = out.get("constraint_conflicts", [])
	check_eq("exactly one constraint conflict surfaced", conflicts.size(), 1)
	if conflicts.size() == 1:
		check_eq("...named conflicting_constraints_kept_on_singletons",
			str((conflicts[0] as Dictionary).get("reason", "")), "conflicting_constraints_kept_on_singletons")

	# ── both seeded singletons SURVIVE, each with its OWN corridor ───────────
	var task_a = ws.get_task("LEGACY_MERGE|%s" % hint_a)
	var task_b = ws.get_task("LEGACY_MERGE|%s" % hint_b)
	check("hint A's seeded singleton survived the conflicting merge", task_a != null)
	check("hint B's seeded singleton survived the conflicting merge", task_b != null)
	if task_a != null and task_b != null:
		check("...A still constrained", task_a.is_constrained())
		check("...B still constrained", task_b.is_constrained())
		check_eq("...A keeps ITS OWN 2-point corridor",
			(task_a.routing_constraint.get("corridor_points", []) as Array).size(), 2)
		check_eq("...B keeps ITS OWN 3-point corridor",
			(task_b.routing_constraint.get("corridor_points", []) as Array).size(), 3)

	# ── the merged task exists, holds the candidate, stays unconstrained ─────
	var sorted_ids: Array = [hint_a, hint_b]
	sorted_ids.sort()
	var merged_key := "LEGACY_MERGE|%s" % ",".join(sorted_ids)
	var merged_task = ws.get_task(merged_key)
	check("the merged task exists", merged_task != null)
	if merged_task != null:
		check("...and is UNCONSTRAINED (no single task-level winner)",
			not merged_task.is_constrained())
	check_eq("exactly three tasks: two surviving singletons + the merge",
		(ws.list_tasks() as Array).size(), 3)

	# ── the stamps stay TRUTHFUL: stamped rev 1, and a live constraint at
	#    rev 1 still exists for each hint (no stale supersession markers) ─────
	for hid in [hint_a, hint_b]:
		var kp: Dictionary = (host.get_by_id(str(hid)) as Dictionary).get("kind_payload", {})
		check_eq("hint %s still stamped superseded at revision 1" % str(hid),
			int(kp.get("waypoints_superseded_by_constraint_revision", -1)), 1)
	if task_a != null:
		check_eq("...matched by A's live constraint revision",
			int(task_a.routing_constraint.get("revision", 0)), 1)
	if task_b != null:
		check_eq("...matched by B's live constraint revision",
			int(task_b.routing_constraint.get("revision", 0)), 1)

	# ── a SECOND propose still steers BOTH hints — the dead state is gone ────
	var out2: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_a, hint_b]}))
	check("second propose succeeded", bool(out2.get("success", false)))
	var call: Dictionary = shim.calls[shim.calls.size() - 1]
	var tc: Dictionary = (call.get("extra", {}) as Dictionary).get("task_constraints", {})
	check_eq("second request's task_constraints still names BOTH hints", tc.size(), 2)
	if tc.has(hint_a):
		check_eq("...hint A steered by its OWN 2-point corridor",
			((tc[hint_a] as Dictionary).get("corridor_points", []) as Array).size(), 2)
	if tc.has(hint_b):
		check_eq("...hint B steered by its OWN 3-point corridor",
			((tc[hint_b] as Dictionary).get("corridor_points", []) as Array).size(), 3)

	ctx["driver"].free_panel(ctx["panel"])


## 22m (Codex 1047 fix round, verdict 4): minerva_pcb_hint_convert_to_detailed
## — the NAMED guided→detailed conversion, end to end against the REAL host +
## workspace. The "stuck state" verdict 4 rules on is: seeded constraint +
## superseded stamp + edit refusal, with no honest exit. This test walks the
## full exit: seed via a real propose, convert, and assert EVERY half is
## released by the one call (ordered two-store writes, workspace half first —
## NOT atomic across the two sidecars, per verdict 6; the load-time
## reconciliation suite 22n owns the torn shapes) — task unconstrained,
## marker gone, verdict-5 lock
## fields gone, detail_level 'detailed', a waypoints edit now ACCEPTED by
## host.update_annotation, and a FRESH propose does NOT re-seed (the seeder's
## own `detailed` gate) — plus the two named refusals: an ordinary unstamped
## hint (not_superseded) and a constraint owned by a MERGED multi-hint task
## (constraint_not_singly_owned — fabricated via ws.ensure_task, 22k's
## direct-injection technique). The convert call goes to the REAL host (not
## the RouterShim): the verb never touches the router, and in production the
## dispatcher hands the tool the panel's real host.
func _run_station12_convert_to_detailed() -> void:
	print("-- 22m. minerva_pcb_hint_convert_to_detailed: full exit from the superseded state (v4) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var wp: Array = [[0.0, 0.0], [5.0, 0.0]]
	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "LEGACY_CONVERT", wp)
	shim.reply = {
		"routes": [{
			"net": "LEGACY_CONVERT",
			"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
			"vias": [],
			"hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("propose succeeded (seed + stamp landed)", bool(out.get("success", false)))
	var task = ws.task_for_hint(hint_id)
	check("fixture sanity: task constrained by the seed", task != null and task.is_constrained())
	var seeded_kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("fixture sanity: stamped superseded",
		seeded_kp.has("waypoints_superseded_by_constraint_revision"))
	check("fixture sanity: verdict-5 lock fields stamped alongside the marker",
		seeded_kp.get("_locked_fields", null) is Array
		and "waypoints" in (seeded_kp.get("_locked_fields", []) as Array)
		and "detail_level" in (seeded_kp.get("_locked_fields", []) as Array))
	check("fixture sanity: _lock_reason names the convert tool",
		str(seeded_kp.get("_lock_reason", "")).contains("minerva_pcb_hint_convert_to_detailed"))

	# ── the conversion itself ─────────────────────────────────────────────────
	var conv: Dictionary = PanelTools._hint_convert_to_detailed(host, _args({"hint_id": hint_id}))
	check("conversion succeeded", bool(conv.get("success", false)))
	check_eq("reply names the hint", str(conv.get("hint_id", "")), hint_id)
	check_eq("reply names the governing task", str(conv.get("task_id", "")), str(task.task_id))
	check_eq("reply carries cleared_constraint_revision 1 (the seed's revision)",
		int(conv.get("cleared_constraint_revision", -1)), 1)
	check_eq("reply's detail_level is detailed", str(conv.get("detail_level", "")), "detailed")
	check("reply note says waypoints are editable + routed as-drawn",
		str(conv.get("note", "")).contains("as-drawn"))

	# ── every half released ──────────────────────────────────────────────────
	check("task is UNCONSTRAINED after conversion", not task.is_constrained())
	var conv_kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("marker GONE (not re-injected — the sanctioned release bypassed H2-1)",
		not conv_kp.has("waypoints_superseded_by_constraint_revision"))
	check("_locked_fields gone", not conv_kp.has("_locked_fields"))
	check("_lock_reason gone", not conv_kp.has("_lock_reason"))
	check_eq("detail_level is detailed", str(conv_kp.get("detail_level", "")), "detailed")
	check("legacy waypoints preserved through the conversion",
		(conv_kp.get("waypoints", []) as Array).size() == 2)

	# ── the stuck state is exited: waypoints editable again ──────────────────
	var edited: Dictionary = host.get_by_id(hint_id)
	var edited_kp: Dictionary = (edited.get("kind_payload", {}) as Dictionary).duplicate(true)
	edited_kp["waypoints"] = [[0.0, 0.0], [5.0, 0.0], [5.0, 5.0]]
	edited["kind_payload"] = edited_kp
	check("a waypoints edit is now ACCEPTED by host.update_annotation",
		host.update_annotation(hint_id, edited))
	check_eq("...and stored", ((host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
		.get("waypoints", []) as Array).size(), 3)

	# ── a fresh propose does NOT re-seed (the seeder's `detailed` gate) ──────
	var out2: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("second propose succeeded", bool(out2.get("success", false)))
	check("task STILL unconstrained — never re-seeded", not task.is_constrained())
	var after2_kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("hint never re-stamped — the detailed gate holds",
		not after2_kp.has("waypoints_superseded_by_constraint_revision"))

	# ── refusal: an ordinary, never-stamped hint has nothing to convert ──────
	var plain_id: String = _seed_legacy_waypoint_hint(host, data, "PLAIN_NET", [[0.0, 0.0], [2.0, 0.0]])
	var plain: Dictionary = PanelTools._hint_convert_to_detailed(host, _args({"hint_id": plain_id}))
	check("unstamped hint: refused", not bool(plain.get("success", true)))
	check_eq("...by name: not_superseded", str(plain.get("error", "")), "not_superseded")

	# ── refusal: unknown id / non-hint id ────────────────────────────────────
	var missing: Dictionary = PanelTools._hint_convert_to_detailed(host, _args({"hint_id": "ann_nope"}))
	check_eq("unknown id refused by name: hint_not_found", str(missing.get("error", "")), "hint_not_found")

	# ── refusal: constraint owned by a MERGED multi-hint task ────────────────
	var shared_id: String = _seed_legacy_waypoint_hint(host, data, "SHARED_NET", [[0.0, 0.0], [3.0, 0.0]])
	# Fabricate the merged CONSTRAINED task directly (22k's technique), keyed
	# "<net>|<sorted hint ids>" — task_for_hint's membership fallback finds it.
	var sorted_ids: Array = [shared_id, "other_hint_sharing_this_merge"]
	sorted_ids.sort()
	var merged_id := "SHARED_NET|%s" % ",".join(sorted_ids)
	var merged_task = ws.ensure_task(merged_id, "SHARED_NET")
	merged_task.routing_constraint = {
		"corridor_points": [Vector2(1.0, 1.0), Vector2(2.0, 2.0)],
		"preferred_layer": "",
		"revision": 2,
		"authored_by": "ai",
		"base_board_revision": 0,
		"owner_hint_id": "",
	}
	# Stamp the hint superseded (the real steer path would have) so the ONLY
	# thing refusing is ownership, not not_superseded.
	PanelTools._stamp_waypoints_superseded(host, shared_id, 2)
	check("fixture sanity: shared hint is stamped",
		(host.get_by_id(shared_id).get("kind_payload", {}) as Dictionary)
			.has("waypoints_superseded_by_constraint_revision"))
	var shared: Dictionary = PanelTools._hint_convert_to_detailed(host, _args({"hint_id": shared_id}))
	check("merged-owned constraint: refused", not bool(shared.get("success", true)))
	check_eq("...by name: constraint_not_singly_owned",
		str(shared.get("error", "")), "constraint_not_singly_owned")
	check_eq("...naming the owning task", str(shared.get("task_id", "")), merged_id)
	check("...note names reroute_route as the legal alternative",
		str(shared.get("note", "")).contains("reroute_route"))
	check("the merged task's constraint is UNTOUCHED by the refusal", merged_task.is_constrained())
	check("the shared hint is STILL stamped (no half-release)",
		(host.get_by_id(shared_id).get("kind_payload", {}) as Dictionary)
			.has("waypoints_superseded_by_constraint_revision"))

	ctx["driver"].free_panel(ctx["panel"])


# ── 22n (Codex 1047 fix round, verdict 6): boundary-delta test 7 — both
# torn-save permutations of the constraint+marker pair, repaired by the
# deterministic load-time reconciliation pass. The entry point is exercised
# EXACTLY the way production calls it: PCBPanel._on_panel_load_request calls
# PanelTools.reconcile_superseded_waypoint_state(host, workspace) once both
# sidecars are in memory — the pass is a static seam (same technique every
# other station-12 test uses), so these tests drive that same callable
# directly against the real host + workspace, fabricating each torn state the
# way the real world produces it (constraint cleared under a surviving marker;
# constraint written with no stamp; pre-lock-era stamp; undo of a conversion).
# AUTHORITY RULE under test: the workspace constraint store is authoritative,
# the marker is derived. detail_level rule under test: the strip PRESERVES it
# as found (rationale pinned on reconcile_strip_superseded_marker's own doc).


## 22n-1: the consistent case — a real propose seeds constraint AND marker,
## and reconciliation finds NOTHING: zero records, zero writes (payload
## byte-identical), the workspace channel left empty, and a second pass is
## equally empty (idempotence on the common path — the pass must be safe to
## run on every single load).
func _run_station12_recon_consistent_noop() -> void:
	print("-- 22n-1. load reconciliation: consistent stores are a strict no-op (v6) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "RECON_OK", [[0.0, 0.0], [5.0, 0.0]])
	shim.reply = {
		"routes": [{
			"net": "RECON_OK",
			"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
			"vias": [], "hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("fixture: propose succeeded (both stores written)", bool(out.get("success", false)))
	var task = ws.task_for_hint(hint_id)
	check("fixture: constraint present", task != null and task.is_constrained())
	check("fixture: marker present", (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
		.has("waypoints_superseded_by_constraint_revision"))

	var payload_before: String = JSON.stringify(host.get_by_id(hint_id).get("kind_payload", {}))
	var records: Array = PanelTools.reconcile_superseded_waypoint_state(host, ws)
	check_eq("consistent stores: ZERO records", records.size(), 0)
	check_eq("workspace channel empty", (ws.last_load_reconciliation as Array).size(), 0)
	check("payload byte-identical (no writes)",
		JSON.stringify(host.get_by_id(hint_id).get("kind_payload", {})) == payload_before)
	var records2: Array = PanelTools.reconcile_superseded_waypoint_state(host, ws)
	check_eq("second pass equally empty (idempotence)", records2.size(), 0)

	ctx["driver"].free_panel(ctx["panel"])


## 22n-2: MARKER-WITHOUT-CONSTRAINT — the "annotations sidecar saved, workspace
## sidecar not" (or crash-after-stamp-then-constraint-lost) permutation,
## fabricated the way it really occurs: a real seed, then the constraint
## vanishes under the surviving marker. Reconciliation strips marker + lock
## keys through the host's sanctioned bookkeeping path, PRESERVES detail_level
## as found ('guided' — the pinned rule), emits ONE structured record, creates
## NO history step, re-permits waypoint edits, and a second pass is a no-op.
func _run_station12_recon_marker_without_constraint() -> void:
	print("-- 22n-2. load reconciliation: marker-without-constraint strips (detail_level preserved) (v6) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "RECON_TORN_A", [[1.0, 0.0], [6.0, 0.0]])
	shim.reply = {
		"routes": [{
			"net": "RECON_TORN_A",
			"segments": [{"start": [1.0, 0.0], "end": [6.0, 0.0], "layer": "F.Cu"}],
			"vias": [], "hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("fixture: propose seeded both stores", bool(out.get("success", false)))
	var task = ws.task_for_hint(hint_id)
	check("fixture: constrained", task != null and task.is_constrained())

	# The tear: the constraint is gone, the marker survives (the exact shape a
	# lost workspace sidecar — or the documented undo-of-conversion asymmetry —
	# produces on the next load).
	task.routing_constraint = {}
	check("fixture sanity: marker still present under the cleared constraint",
		(host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
			.has("waypoints_superseded_by_constraint_revision"))

	var stack_before: int = (host.get_by_id(hint_id).get("revision_stack", []) as Array).size()
	var records: Array = PanelTools.reconcile_superseded_waypoint_state(host, ws)
	check_eq("exactly ONE record", records.size(), 1)
	if records.size() == 1:
		var rec: Dictionary = records[0]
		check_eq("record names the hint", str(rec.get("hint_id", "")), hint_id)
		check_eq("record action: released_stale_marker", str(rec.get("action", "")), "released_stale_marker")
		check_eq("record reason: marker_without_constraint",
			str(rec.get("reason", "")), "marker_without_constraint")
		check_eq("record names the (now unconstrained) task", str(rec.get("task_id", "")), str(task.task_id))
	check_eq("workspace channel mirrors the records",
		(ws.last_load_reconciliation as Array).size(), 1)

	var kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("marker stripped", not kp.has("waypoints_superseded_by_constraint_revision"))
	check("_locked_fields stripped", not kp.has("_locked_fields"))
	check("_lock_reason stripped", not kp.has("_lock_reason"))
	check_eq("detail_level PRESERVED as found — 'guided', never forced 'detailed' (the pinned rule)",
		str(kp.get("detail_level", "")), "guided")
	check("waypoints untouched", (kp.get("waypoints", []) as Array).size() == 2)

	# (f) reconciliation is bookkeeping — no undo history step.
	var stack_after: int = (host.get_by_id(hint_id).get("revision_stack", []) as Array).size()
	check("NO history step created by the repair", stack_after == stack_before)

	# The stale guard is disarmed: waypoint edits are live authority again.
	var edit: Dictionary = host.get_by_id(hint_id)
	var edit_kp: Dictionary = (edit.get("kind_payload", {}) as Dictionary).duplicate(true)
	edit_kp["waypoints"] = [[1.0, 0.0], [6.0, 0.0], [6.0, 4.0]]
	edit["kind_payload"] = edit_kp
	check("waypoints edit ACCEPTED after the repair", host.update_annotation(hint_id, edit))

	# Idempotence: the repaired state reconciles to nothing.
	var records2: Array = PanelTools.reconcile_superseded_waypoint_state(host, ws)
	check_eq("second pass: ZERO records (idempotence)", records2.size(), 0)
	check_eq("second pass: channel reset to empty (per-call convention)",
		(ws.last_load_reconciliation as Array).size(), 0)

	ctx["driver"].free_panel(ctx["panel"])


## 22n-3: CONSTRAINT-WITHOUT-MARKER — the "workspace sidecar saved, annotations
## sidecar not" (or crash between the seed's constraint write and its stamp)
## permutation, fabricated exactly as the crash leaves it: the constraint dict
## the seeder writes (owner_hint_id + seeded_from provenance, revision 1) on
## the eagerly-minted singleton task, with the hint never stamped.
## Reconciliation re-stamps the marker AT THE CONSTRAINT'S REVISION via the
## same _stamp_waypoints_superseded every live writer uses — lock keys
## included — emits ONE structured record, creates NO history step, and the
## edit-refusal guard is RE-ARMED afterwards.
func _run_station12_recon_constraint_without_marker() -> void:
	print("-- 22n-3. load reconciliation: constraint-without-marker re-stamps (guard re-armed) (v6) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var wp: Array = [[0.0, 2.0], [4.0, 2.0]]
	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "RECON_TORN_B", wp)
	# The crash shape: constraint landed (workspace store), stamp never ran.
	var task = ws.ensure_task("RECON_TORN_B|%s" % hint_id, "RECON_TORN_B")
	task.routing_constraint = {
		"corridor_points": [Vector2(0.0, 2.0), Vector2(4.0, 2.0)],
		"preferred_layer": "F.Cu",
		"revision": 1,
		"authored_by": "migration",
		"base_board_revision": 0,
		"owner_hint_id": hint_id,
		"seeded_from_hint_id": hint_id,
		"seeded_from_hint_revision": 0,
	}
	check("fixture sanity: hint carries NO marker",
		not (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
			.has("waypoints_superseded_by_constraint_revision"))

	var stack_before: int = (host.get_by_id(hint_id).get("revision_stack", []) as Array).size()
	var records: Array = PanelTools.reconcile_superseded_waypoint_state(host, ws)
	check_eq("exactly ONE record", records.size(), 1)
	if records.size() == 1:
		var rec: Dictionary = records[0]
		check_eq("record names the hint", str(rec.get("hint_id", "")), hint_id)
		check_eq("record action: restamped_marker", str(rec.get("action", "")), "restamped_marker")
		check_eq("record reason: constraint_without_marker",
			str(rec.get("reason", "")), "constraint_without_marker")
		check_eq("record carries the constraint's revision", int(rec.get("constraint_revision", -1)), 1)
		check_eq("record names the governing task", str(rec.get("task_id", "")), str(task.task_id))

	var kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("marker re-stamped", kp.has("waypoints_superseded_by_constraint_revision"))
	check_eq("...at the constraint's revision (the authoritative store's number)",
		int(kp.get("waypoints_superseded_by_constraint_revision", -1)), 1)
	check("lock keys present (the stamp writes them — CX-C shape)",
		kp.get("_locked_fields", null) is Array and kp.has("_lock_reason"))
	check("NO history step created by the repair",
		(host.get_by_id(hint_id).get("revision_stack", []) as Array).size() == stack_before)

	# The guard is RE-ARMED: a waypoints edit is refused again.
	var edit: Dictionary = host.get_by_id(hint_id)
	var edit_kp: Dictionary = (edit.get("kind_payload", {}) as Dictionary).duplicate(true)
	edit_kp["waypoints"] = [[0.0, 2.0], [9.0, 9.0]]
	edit["kind_payload"] = edit_kp
	check("waypoints edit REFUSED after the re-stamp", not host.update_annotation(hint_id, edit))
	check_eq("...with the structured refusal populated",
		str((host.last_update_refusal as Dictionary).get("error", "")), "waypoints_superseded")

	# Idempotence: marker now matches the constraint — nothing on pass two.
	var records2: Array = PanelTools.reconcile_superseded_waypoint_state(host, ws)
	check_eq("second pass: ZERO records (idempotence)", records2.size(), 0)

	ctx["driver"].free_panel(ctx["panel"])


## 22n-4: MARKER-OUT-OF-SHAPE — two sub-shapes, one rule ("re-stamp to current
## shape"): (a) the PRE-LOCK-ERA stamp (marker present, verdict-5 lock keys
## absent — a sidecar stamped before CX-C existed; core's offline lock
## convention names this exact backfill as CX-D's) gets its locks backfilled;
## (b) a marker naming a STALE revision under a constraint that has moved on
## is re-stamped to the constraint's revision. Both emit reason
## "marker_out_of_shape" with the constraint's (authoritative) revision.
func _run_station12_recon_marker_out_of_shape() -> void:
	print("-- 22n-4. load reconciliation: pre-lock-era + stale-revision stamps re-shaped (v6) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	# (a) pre-lock-era: marker WITHOUT lock keys. Fabricated by adding the
	# marker alone through the ordinary update seam (marker ADDITION is never
	# refused, and H2-1 re-injection no-ops because `old` carried no marker) —
	# exactly the payload a CX-C-predating sidecar loads with.
	var old_id: String = _seed_legacy_waypoint_hint(host, data, "RECON_PRELOCK", [[0.0, 4.0], [3.0, 4.0]])
	var old_task = ws.ensure_task("RECON_PRELOCK|%s" % old_id, "RECON_PRELOCK")
	old_task.routing_constraint = {
		"corridor_points": [Vector2(0.0, 4.0), Vector2(3.0, 4.0)],
		"preferred_layer": "F.Cu", "revision": 3, "authored_by": "migration",
		"base_board_revision": 0, "owner_hint_id": old_id,
		"seeded_from_hint_id": old_id, "seeded_from_hint_revision": 0,
	}
	var pre: Dictionary = host.get_by_id(old_id)
	var pre_kp: Dictionary = (pre.get("kind_payload", {}) as Dictionary).duplicate(true)
	pre_kp["waypoints_superseded_by_constraint_revision"] = 3
	pre["kind_payload"] = pre_kp
	check("fixture: pre-lock-era stamp accepted", host.update_annotation(old_id, pre))
	check("fixture sanity: marker present, locks ABSENT",
		(host.get_by_id(old_id).get("kind_payload", {}) as Dictionary)
			.has("waypoints_superseded_by_constraint_revision")
		and not (host.get_by_id(old_id).get("kind_payload", {}) as Dictionary).has("_locked_fields"))

	var records: Array = PanelTools.reconcile_superseded_waypoint_state(host, ws)
	check_eq("pre-lock-era: exactly ONE record", records.size(), 1)
	if records.size() == 1:
		check_eq("...reason marker_out_of_shape", str((records[0] as Dictionary).get("reason", "")),
			"marker_out_of_shape")
		check_eq("...action restamped_marker", str((records[0] as Dictionary).get("action", "")),
			"restamped_marker")
	var back_kp: Dictionary = (host.get_by_id(old_id).get("kind_payload", {}) as Dictionary)
	check("locks BACKFILLED by the re-stamp", back_kp.get("_locked_fields", null) is Array
		and "waypoints" in (back_kp.get("_locked_fields", []) as Array)
		and back_kp.has("_lock_reason"))
	check_eq("marker still at the constraint's revision",
		int(back_kp.get("waypoints_superseded_by_constraint_revision", -1)), 3)

	# (b) stale-revision marker: constraint moved to revision 5, marker says 3.
	old_task.routing_constraint["revision"] = 5
	var records_b: Array = PanelTools.reconcile_superseded_waypoint_state(host, ws)
	check_eq("stale revision: exactly ONE record", records_b.size(), 1)
	if records_b.size() == 1:
		check_eq("...reason marker_out_of_shape", str((records_b[0] as Dictionary).get("reason", "")),
			"marker_out_of_shape")
		check_eq("...carrying the NEW revision", int((records_b[0] as Dictionary)
			.get("constraint_revision", -1)), 5)
	check_eq("marker re-stamped to the constraint's revision",
		int((host.get_by_id(old_id).get("kind_payload", {}) as Dictionary)
			.get("waypoints_superseded_by_constraint_revision", -1)), 5)

	# Idempotence after both repairs.
	check_eq("final pass: ZERO records",
		(PanelTools.reconcile_superseded_waypoint_state(host, ws) as Array).size(), 0)

	ctx["driver"].free_panel(ctx["panel"])


## 22n-5: the UNDO-OF-CONVERSION torn state reconciles per the strip rule on
## the next load, and the guided flow RESUMES end-to-end: seed via a real
## propose → convert (clears constraint + releases marker) → undo (restores
## the pre-conversion payload wholesale — marker, locks, 'guided' — while the
## constraint stays cleared: the DOCUMENTED asymmetry) → reconcile (the "next
## load"): marker stripped, detail_level 'guided' PRESERVED (the undo restored
## it, and preserving it is exactly what lets the seeder re-run) → a fresh
## propose RE-SEEDS constraint + marker at revision 1 — the pre-torn guided
## intent, recovered without any user action beyond reloading.
func _run_station12_recon_undo_of_conversion() -> void:
	print("-- 22n-5. load reconciliation: undo-of-conversion torn state → guided flow resumes (v6) --")
	var ctx: Dictionary = await _panel_context()
	var host = ctx["host"]
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var hint_id: String = _seed_legacy_waypoint_hint(host, data, "RECON_UNDO", [[2.0, 0.0], [7.0, 0.0]])
	shim.reply = {
		"routes": [{
			"net": "RECON_UNDO",
			"segments": [{"start": [2.0, 0.0], "end": [7.0, 0.0], "layer": "F.Cu"}],
			"vias": [], "hint_ids": [hint_id],
		}],
		"via_count": 0,
	}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("fixture: propose seeded both stores", bool(out.get("success", false)))
	var task = ws.task_for_hint(hint_id)
	check("fixture: constrained", task != null and task.is_constrained())

	var conv: Dictionary = PanelTools._hint_convert_to_detailed(host, _args({"hint_id": hint_id}))
	check("conversion succeeded", bool(conv.get("success", false)))
	check("...task unconstrained", not task.is_constrained())

	var undone: Dictionary = host.undo_hint_revision(hint_id)
	check("undo of the conversion ok", bool(undone.get("ok", false)))
	var undone_kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("undo restored the marker (annotation side only — the documented asymmetry)",
		undone_kp.has("waypoints_superseded_by_constraint_revision"))
	check_eq("undo restored detail_level 'guided' (pre-conversion payload, wholesale)",
		str(undone_kp.get("detail_level", "")), "guided")
	check("the constraint stays cleared — the torn state under test", not task.is_constrained())

	# "The next load": reconciliation repairs per rule (a).
	var records: Array = PanelTools.reconcile_superseded_waypoint_state(host, ws)
	check_eq("ONE record: marker_without_constraint", records.size(), 1)
	if records.size() == 1:
		check_eq("...reason", str((records[0] as Dictionary).get("reason", "")),
			"marker_without_constraint")
	var recon_kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("marker stripped", not recon_kp.has("waypoints_superseded_by_constraint_revision"))
	check_eq("detail_level STILL 'guided' — preserved, so the seeder can resume",
		str(recon_kp.get("detail_level", "")), "guided")

	# The guided flow resumes: a fresh propose re-seeds constraint + marker.
	var out2: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint_id]}))
	check("re-propose succeeded", bool(out2.get("success", false)))
	# Revision 2, not 1 (Epoch UX2 station 2, cold review F2): the conversion
	# CLEARED revision 1, which set the task's constraint_revision_floor — the
	# re-seed resumes ABOVE it, so a stale pre-clear candidate stamped 1 can
	# never pass the commit gate against this fresh constraint.
	check("task RE-CONSTRAINED by the seeder (revision 2 — above the cleared floor)",
		task.is_constrained() and int(task.routing_constraint.get("revision", 0)) == 2)
	check("hint RE-STAMPED by the seeder",
		(host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
			.has("waypoints_superseded_by_constraint_revision"))

	ctx["driver"].free_panel(ctx["panel"])


# ══ 23. DCR 019fd5fd9084 — board_health ledger + commit acknowledgment gate ═══
#
# The worker-contract split (built in parallel; the RouterShim fixtures below
# SIMULATE it): every ok routing result carries a top-level `board_health`
# {complete:true|false|null, missing_copper:[net], partial:[...], assembly:
# {status:"pass"|"findings"|"indeterminate", findings:[...]}, approximate:true}
# — the old assembly_advisories key is GONE. The PANEL (a) passes board_health
# through verbatim, enriched with board_revision + preflight.rendered_this_
# revision (stamped by a successful get_image capture — simulated here via the
# same panel.note_render_captured seam _get_image calls, since a headless
# unmounted panel has no canvas to actually rasterize); (b) feeds an
# assembly-state cache the COMMIT verbs consult: fresh findings intersecting
# the committing candidate's endpoint components refuse
# placement_blocker_unacknowledged unless acknowledge_placement:true; stale/
# absent/indeterminate WARN (assembly_note) and never block; a batch refuses
# whole on one blocked member (all-or-nothing). (c) The four placement verbs
# (work item 019fd5fe2724) invalidate the cache and re-check via the
# pcb.assembly_check channel, attaching the tri-state as `assembly`.

func _run_board_health_and_commit_gate() -> void:
	print("-- 23. DCR 019fd5fd9084: board_health + commit acknowledgment gate --")
	await _run_bh_pass_through_and_enrichment()
	await _run_bh_commit_gate_matrix()
	await _run_bh_endpoint_fallback_and_tri_state()
	await _run_bh_batch_gate()
	await _run_bh_placement_verb_tri_state()
	await _run_ux2_snap_disclosure_and_pin_groups()


## The worker-contract board_health fixture (benign completeness by default so
## the enrichment tests can flip individual axes explicitly).
func _board_health_fixture() -> Dictionary:
	return {
		"complete": false,
		"missing_copper": ["VCC_5V"],
		"partial": [],
		"assembly": {"status": "pass", "findings": []},
		"approximate": true,
	}


func _run_bh_pass_through_and_enrichment() -> void:
	print("  -- 23a. board_health pass-through + panel enrichment + preflight flip --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var panel = ctx["panel"]
	var data = ctx["data"]
	var revision: int = int(data.board_revision)

	var reply: Dictionary = _multipad_reply([str(ctx["hint_id"])])
	reply["board_health"] = _board_health_fixture()
	shim.reply = reply

	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose succeeded", bool(out.get("success", false)))
	check("reply carries board_health", out.has("board_health"))
	var bh: Dictionary = out.get("board_health", {})
	check_eq("worker completeness verdict passes through VERBATIM",
		bh.get("complete", null), false)
	check("missing_copper passes through verbatim",
		"VCC_5V" in (bh.get("missing_copper", []) as Array))
	check_eq("panel enrichment: board_revision is the LIVE board's",
		int(bh.get("board_revision", -1)), revision)
	var preflight: Dictionary = bh.get("preflight", {})
	check_eq("preflight: nothing rendered yet this session -> false",
		preflight.get("rendered_this_revision", null), false)

	# Epoch UX4 station 3 (A9 — the F6 cache-isolation rule, REVERSING this
	# group's pre-UX4 expectation): a propose is a DRAFT request, its health
	# was computed from the COMPOSED board, so it is surfaced LABELED and the
	# assembly cache — the REAL board's verdict, read by the commit
	# acknowledgment gate — is NEVER fed by it.
	check_eq("draft reply's health is labeled draft (UX4 A9)",
		bool(bh.get("draft", false)), true)
	check("…and the assembly cache was NOT fed (composed-board verdict never keyed to the real board)",
		panel.get_assembly_state().is_empty())

	# PREFLIGHT FLIP: simulate a successful get_image capture via the SAME seam
	# _get_image stamps through (note_render_captured — an unmounted panel has
	# no canvas, so the capture itself cannot run headless), then re-propose.
	panel.note_render_captured(int(data.board_revision))
	out = await PanelTools._workspace_propose(shim, _args())
	var bh2: Dictionary = out.get("board_health", {})
	check_eq("preflight flips true once THIS revision was rendered",
		(bh2.get("preflight", {}) as Dictionary).get("rendered_this_revision", null), true)

	# OLDER WORKER: a result with NO board_health attaches nothing (absent-key
	# contract). Cache stance post-UX4: the cache was never fed by any propose
	# in this group (A9), and an absent health certainly feeds nothing either.
	shim.reply = _multipad_reply([str(ctx["hint_id"])])
	out = await PanelTools._workspace_propose(shim, _args())
	check("absent board_health stays absent on the reply (older worker)",
		not out.has("board_health"))
	check("…and the cache is still untouched (never fed by a draft — UX4 A9)",
		panel.get_assembly_state().is_empty())

	ctx["driver"].free_panel(ctx["panel"])


func _run_bh_commit_gate_matrix() -> void:
	print("  -- 23b. commit gate matrix: findings gate, ack records, stale/indeterminate warn --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var panel = ctx["panel"]
	var ws = ctx["ws"]
	var data = ctx["data"]

	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var cid := str(((out.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	check("fixture candidate landed", not cid.is_empty())
	# Endpoint components via the PRIMARY source: the candidate's own endpoints
	# (RouteTask.endpoints open-dict shape, {"component","pin"}).
	var cand = ws.get_candidate(cid)
	cand.endpoints = [{"component": "U1", "pin": "3"}, {"component": "U2", "pin": "7"}]

	var finding := {"kind": "courtyard_overlap", "components": ["U1", "D1"],
		"message": "U1 and D1 courtyards overlap — parts cannot be assembled"}

	# ── FRESH findings INTERSECTING the endpoints, no acknowledgment: REFUSE ──
	panel.set_assembly_state({"status": "findings", "findings": [finding]},
		int(data.board_revision))
	var res: Dictionary = PanelTools._workspace_commit(shim, _args({"candidate_id": cid}))
	check("gated commit refused", not bool(res.get("success", true)))
	check_eq("…by name", str(res.get("error", "")), "placement_blocker_unacknowledged")
	check_eq("…listing the blocking finding", (res.get("blocking_findings", []) as Array).size(), 1)
	check("…which names the colliding components",
		"U1" in (((res.get("blocking_findings", []) as Array)[0] as Dictionary).get("components", []) as Array))
	check_eq("refusal left the candidate un-committed (no copper laid)",
		str(ws.get_candidate(cid).disposition), "proposed")

	# ── FRESH findings NOT intersecting: silent commit-eligible (proved next
	# via a fresh non-blocking state), covered here by flipping the components.
	panel.set_assembly_state({"status": "findings",
		"findings": [{"kind": "courtyard_overlap", "components": ["D1", "BAT1"]}]},
		int(data.board_revision))
	# (do not commit yet — the intersecting-findings ack case below consumes cid)

	# ── acknowledge_placement carries the commit THROUGH the blocker ──────────
	panel.set_assembly_state({"status": "findings", "findings": [finding]},
		int(data.board_revision))
	res = PanelTools._workspace_commit(shim,
		_args({"candidate_id": cid, "acknowledge_placement": true}))
	check("acknowledged commit succeeded", bool(res.get("success", false)))
	check_eq("…and RECORDS the acknowledged findings",
		(res.get("acknowledged_placement_findings", []) as Array).size(), 1)
	check("…no advisory note on a fresh findings state", not res.has("assembly_note"))
	check_eq("copper landed", str(ws.get_candidate(cid).disposition), "committed")

	# ── STALE cache (revision mismatch): WARN, never block ────────────────────
	# The commit above bumped board_revision, so land a SECOND candidate and
	# feed the cache at a deliberately old revision.
	var hint2: String = _seed_net_named_hint(ctx["host"], "N1")
	shim.reply = _multipad_reply([hint2])
	out = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint2]}))
	var cid2 := str(((out.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var cand2 = ws.get_candidate(cid2)
	cand2.endpoints = [{"component": "U1", "pin": "3"}]
	panel.set_assembly_state({"status": "findings", "findings": [finding]},
		int(data.board_revision) - 1)
	res = PanelTools._workspace_commit(shim, _args({"candidate_id": cid2}))
	check("stale findings do NOT block the commit", bool(res.get("success", false)))
	var note: Dictionary = res.get("assembly_note", {})
	check_eq("…but the reply WARNS with an indeterminate assembly_note",
		str(note.get("status", "")), "indeterminate")
	check("…whose reason names the staleness",
		str(note.get("reason", "")).findn("stale") != -1)

	# ── INDETERMINATE state: WARN, never block ────────────────────────────────
	var hint3: String = _seed_net_named_hint(ctx["host"], "N1")
	shim.reply = _multipad_reply([hint3])
	out = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint3]}))
	var cid3 := str(((out.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	panel.set_assembly_state({"status": "indeterminate", "error": "worker faulted: kaboom"},
		int(data.board_revision))
	res = PanelTools._workspace_commit(shim, _args({"candidate_id": cid3}))
	check("indeterminate assembly state does NOT block", bool(res.get("success", false)))
	note = res.get("assembly_note", {})
	check_eq("…and warns indeterminate", str(note.get("status", "")), "indeterminate")
	check("…carrying the worker's own error", str(note.get("reason", "")).findn("kaboom") != -1)

	# ── ABSENT cache: WARN, never block ───────────────────────────────────────
	var hint4: String = _seed_net_named_hint(ctx["host"], "N1")
	shim.reply = _multipad_reply([hint4])
	out = await PanelTools._workspace_propose(shim, _args({"hint_ids": [hint4]}))
	var cid4 := str(((out.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	panel.invalidate_assembly_state()
	res = PanelTools._workspace_commit(shim, _args({"candidate_id": cid4}))
	check("absent cache does NOT block", bool(res.get("success", false)))
	check_eq("…and warns indeterminate",
		str((res.get("assembly_note", {}) as Dictionary).get("status", "")), "indeterminate")

	ctx["driver"].free_panel(ctx["panel"])


func _run_bh_endpoint_fallback_and_tri_state() -> void:
	print("  -- 23c. endpoint-component fallback (pin-ref parse) + tri-state normalizer --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var host = ctx["host"]
	var hint_id := str(ctx["hint_id"])

	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var cid := str(((out.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var cand = ws.get_candidate(cid)

	# The default fixture hint carries no pin refs, so BOTH structured sources
	# are empty — prove the gate falls back to parsing the source hints' own
	# kind_payload.source_pins/dest_pins ("U7.3" -> "U7") through host.get_by_id.
	cand.endpoints = []
	var task = ws.get_task(str(cand.task_id))
	if task != null:
		task.endpoints = []
	var ann: Dictionary = (host.get_by_id(hint_id) as Dictionary).duplicate(true)
	var kp: Dictionary = ann.get("kind_payload", {})
	kp["source_pins"] = ["U7.3"]
	kp["dest_pins"] = ["U8.1"]
	ann["kind_payload"] = kp
	check("fixture hint updated with pin refs", bool(host.update_annotation(hint_id, ann)))
	var comps: Array = PanelTools._candidate_endpoint_components(shim, ws, cand)
	check("fallback parsed the source-pin component", "U7" in comps)
	check("…and the dest-pin component", "U8" in comps)
	check_eq("…exactly the two components", comps.size(), 2)

	# ── _assembly_tri_state: the normalizer every seam shares ─────────────────
	var tri: Dictionary = PanelTools._assembly_tri_state(
		{"ok": true, "result": {"status": "findings", "findings": [{"components": ["A", "B"]}]}})
	check_eq("ok envelope with a recognised status passes verbatim",
		str(tri.get("status", "")), "findings")
	check_eq("…findings intact", (tri.get("findings", []) as Array).size(), 1)
	tri = PanelTools._assembly_tri_state(
		{"ok": false, "error": {"kind": "worker_unavailable", "message": "no backend"}})
	check_eq("a failed channel degrades to indeterminate", str(tri.get("status", "")), "indeterminate")
	check("…carrying the error message", str(tri.get("error", "")).findn("no backend") != -1)
	tri = PanelTools._assembly_tri_state({"ok": true, "result": {"status": "sideways"}})
	check_eq("an unrecognised status fails CLOSED to indeterminate (never a pass)",
		str(tri.get("status", "")), "indeterminate")

	ctx["driver"].free_panel(ctx["panel"])


func _run_bh_batch_gate() -> void:
	print("  -- 23d. batch: ONE unacknowledged blocked member refuses the WHOLE batch --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var panel = ctx["panel"]
	var ws = ctx["ws"]
	var data = ctx["data"]
	var host = ctx["host"]

	# Two candidates on two nets (two net-named hints, one shim route each).
	var h_a: String = _seed_net_named_hint(host, "NA")
	var h_b: String = _seed_net_named_hint(host, "NB")
	shim.reply = {"routes": [
		{"net": "NA", "segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
			"vias": [], "hint_ids": [h_a]},
		{"net": "NB", "segments": [{"start": [0.0, 10.0], "end": [5.0, 10.0], "layer": "F.Cu"}],
			"vias": [], "hint_ids": [h_b]},
	], "via_count": 0}
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args({"hint_ids": [h_a, h_b]}))
	check_eq("two candidates landed", int(out.get("proposed", 0)), 2)
	var recs: Array = out.get("candidates", [])
	var cid_a := str((recs[0] as Dictionary).get("candidate_id", ""))
	var cid_b := str((recs[1] as Dictionary).get("candidate_id", ""))
	ws.get_candidate(cid_a).endpoints = [{"component": "U1", "pin": "1"}]
	ws.get_candidate(cid_b).endpoints = [{"component": "U5", "pin": "1"}]

	# Findings touch ONLY candidate A's endpoint component.
	panel.set_assembly_state({"status": "findings",
		"findings": [{"kind": "courtyard_overlap", "components": ["U1", "D1"]}]},
		int(data.board_revision))

	var res: Dictionary = PanelTools._workspace_commit(shim,
		_args({"candidate_ids": [cid_a, cid_b]}))
	check("batch with one blocked member refused WHOLE", not bool(res.get("success", true)))
	check_eq("…by name", str(res.get("error", "")), "placement_blocker_unacknowledged")
	var blocked: Array = res.get("blocked_members", [])
	check_eq("…naming exactly the one blocked member", blocked.size(), 1)
	if blocked.size() == 1:
		check_eq("…which is candidate A", str((blocked[0] as Dictionary).get("candidate_id", "")), cid_a)
	check_eq("all-or-nothing: the UNBLOCKED member laid no copper either",
		str(ws.get_candidate(cid_b).disposition), "proposed")
	check_eq("…and neither did the blocked one",
		str(ws.get_candidate(cid_a).disposition), "proposed")

	# Acknowledged: the whole batch proceeds and the reply records per-member.
	res = PanelTools._workspace_commit(shim,
		_args({"candidate_ids": [cid_a, cid_b], "acknowledge_placement": true}))
	check("acknowledged batch succeeded", bool(res.get("success", false)))
	check_eq("…committing both members", int(res.get("committed_count", 0)), 2)
	var acked: Array = res.get("acknowledged_placement_findings", [])
	check_eq("…recording the one blocked member's findings", acked.size(), 1)
	if acked.size() == 1:
		check_eq("…attributed to candidate A",
			str((acked[0] as Dictionary).get("candidate_id", "")), cid_a)

	ctx["driver"].free_panel(ctx["panel"])


## 23f (Epoch UX2 station 6, docket 019fde367b24): snap disclosure + the
## pin_groups int normalization — two honesty polish items from HITL-5.
func _run_ux2_snap_disclosure_and_pin_groups() -> void:
	print("  -- 23f. snap disclosure on placement replies + pin_groups int (UX2 station 6) --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var data = ctx["data"]

	# Off-grid request (the HITL-5 shape: 70.68 asked, 71.12 landed on the
	# 2.54 grid): reply carries the LANDED coordinates + snapped:true +
	# requested with the caller's own numbers.
	var added: Dictionary = await PanelTools._add_component(shim,
		_args({"id": "U8", "footprint": "RESISTOR", "x": 70.68, "y": 12.7}))
	check("off-grid add succeeded", bool(added.get("success", false)))
	check("add reply discloses the snap", bool(added.get("snapped", false)))
	check_eq("...requested carries the caller's x", float((added.get("requested", []) as Array)[0]), 70.68)
	check("...landed x is the grid point (~71.12)",
		absf(float(added.get("x", 0.0)) - 71.12) < 0.001)

	var moved: Dictionary = await PanelTools._move_component(shim,
		_args({"component_id": "U8", "x": 20.0, "y": 20.0}))
	check("off-grid move succeeded", bool(moved.get("success", false)))
	check("move reply discloses the snap (20.0 -> 20.32)", bool(moved.get("snapped", false)))
	check_eq("...requested echoes the ask", float((moved.get("requested", []) as Array)[0]), 20.0)
	check("...x is the landed grid point (~20.32)",
		absf(float(moved.get("x", 0.0)) - 20.32) < 0.001)

	# ON-grid request: no snap keys at all (absent-when-empty — the common
	# case's reply shape is unchanged).
	var exact: Dictionary = await PanelTools._move_component(shim,
		_args({"component_id": "U8", "x": 25.4, "y": 25.4}))
	check("on-grid move succeeded", bool(exact.get("success", false)))
	check("on-grid reply carries NO snapped key", not exact.has("snapped"))
	check("on-grid reply carries NO requested key", not exact.has("requested"))

	# FREEFORM (HITL-6, docket 019fdf2b939e): snap_to_grid:false lands the
	# part EXACTLY where asked — the sub-grid pin alignment the forced snap
	# made unreachable (BAT1 at y=12.16 to zero the 0.54mm GND jog). No snap
	# happened, so no disclosure keys either.
	var free: Dictionary = await PanelTools._move_component(shim,
		_args({"component_id": "U8", "x": 12.16, "y": 25.4, "snap_to_grid": false}))
	check("freeform move succeeded", bool(free.get("success", false)))
	check("freeform lands EXACTLY at the asked x (12.16, off-grid)",
		absf(float(free.get("x", 0.0)) - 12.16) < 0.0005)
	check("freeform reply carries NO snapped key (nothing was snapped)",
		not free.has("snapped"))
	if data.has_component("U8"):
		check("model position is the exact freeform point",
			absf(float(data.get_component("U8").position.x) - 12.16) < 0.0005)

	# move_relative: new_x/new_y now report where the part actually IS (the
	# pre-fix reply echoed the interpreted point even when the snap moved it).
	var mr: Dictionary = await PanelTools._move_relative(shim,
		_args({"component_id": "U8", "direction": "right"}))
	check("move_relative succeeded", bool(mr.get("success", false)))
	if data.has_component("U8"):
		# Compared on the 0.1um reply grid, not bit-for-bit. This assertion
		# guards LANDED-vs-REQUESTED — a grid-scale distinction (2.54mm) — and
		# the reply now quantizes, so the model holds 17.7800006866455 while the
		# reply says 17.78. Demanding float32 bit-equality of a reply would
		# require the reply to carry the residue this surface exists to remove;
		# 0.0005 is the same tolerance the freeform checks above use and is
		# three orders of magnitude tighter than the thing being guarded.
		# EXACT against the reply grid, not a tolerance. This guards
		# LANDED-vs-REQUESTED (a 2.54mm distinction), and the reply now
		# quantizes, so the model holds 17.7800006866455 while the reply says
		# 17.78. Comparing to the SNAPPED model value pins the reply contract
		# itself rather than allowing any 0.0005mm mismatch to pass.
		check_eq("move_relative new_x is the component's ACTUAL position",
			float(mr.get("new_x", -1.0)),
			snappedf(float(data.get_component("U8").position.x), 0.0001))

	# pin_groups int normalization (the F5 constraint_revision class): a
	# worker board_health whose partial[].pin_groups crossed the JSON hop as
	# 9.0 reaches the caller as int 9.
	var reply: Dictionary = _multipad_reply([str(ctx["hint_id"])])
	var fixture: Dictionary = _board_health_fixture()
	fixture["complete"] = false
	fixture["partial"] = [{"net": "GND", "pin_groups": 9.0}]
	reply["board_health"] = fixture
	shim.reply = reply
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose succeeded", bool(out.get("success", false)))
	var partial: Array = (out.get("board_health", {}) as Dictionary).get("partial", [])
	check_eq("partial passes through", partial.size(), 1)
	if partial.size() == 1:
		var pg: Variant = (partial[0] as Dictionary).get("pin_groups")
		check("pin_groups is an INT after the lift (9, not 9.0)",
			pg is int and int(pg) == 9)

	ctx["driver"].free_panel(ctx["panel"])


func _run_bh_placement_verb_tri_state() -> void:
	print("  -- 23e. placement verbs: cache invalidate + assembly_check re-run + attach --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var panel = ctx["panel"]
	var data = ctx["data"]

	# Canned channel reply SIMULATING the worker contract's assembly_check.
	shim.assembly_reply = {"ok": true, "result": {"status": "findings",
		"findings": [{"kind": "courtyard_overlap", "components": ["U9", "D1"]}]}}
	var added: Dictionary = await PanelTools._add_component(shim,
		_args({"id": "U9", "footprint": "RESISTOR", "x": 10.0, "y": 10.0}))
	check("add succeeded", bool(added.get("success", false)))
	check_eq("verb reply carries the tri-state assembly verdict",
		str((added.get("assembly", {}) as Dictionary).get("status", "")), "findings")
	check_eq("the channel was called exactly once", int(shim.assembly_calls), 1)
	var cached: Dictionary = panel.get_assembly_state()
	check_eq("cache refreshed with the verdict",
		str((cached.get("assembly", {}) as Dictionary).get("status", "")), "findings")
	check_eq("…at the post-mutation revision",
		int(cached.get("board_revision", -1)), int(data.board_revision))

	# Channel down next op ({} forwards to the REAL host -> headless panel ->
	# worker_unavailable): the verb attaches indeterminate and the cache follows
	# — proving invalidate-then-refresh, not stale-verdict survival.
	shim.assembly_reply = {}
	var moved: Dictionary = await PanelTools._move_component(shim,
		_args({"component_id": "U9", "x": 20.0, "y": 20.0}))
	check("move succeeded", bool(moved.get("success", false)))
	check_eq("channel-down move attaches indeterminate (never silent)",
		str((moved.get("assembly", {}) as Dictionary).get("status", "")), "indeterminate")
	check_eq("…and the cache followed (old findings verdict did NOT survive)",
		str((panel.get_assembly_state().get("assembly", {}) as Dictionary).get("status", "")),
		"indeterminate")

	# rotate + move_relative wear the same stamp.
	shim.assembly_reply = {"ok": true, "result": {"status": "pass", "findings": []}}
	var rotated: Dictionary = await PanelTools._rotate_component(shim,
		_args({"component_id": "U9", "degrees": 90}))
	check_eq("rotate attaches the tri-state too",
		str((rotated.get("assembly", {}) as Dictionary).get("status", "")), "pass")
	var mr: Dictionary = await PanelTools._move_relative(shim,
		_args({"component_id": "U9", "direction": "right"}))
	check_eq("move_relative attaches the tri-state too",
		str((mr.get("assembly", {}) as Dictionary).get("status", "")), "pass")

	# A REFUSAL mutates nothing and re-checks nothing: the cache stays put.
	var calls_before: int = int(shim.assembly_calls)
	var bad: Dictionary = await PanelTools._add_component(shim,
		_args({"footprint": "BOGUS", "x": 1.0, "y": 1.0}))
	check("refusal reply carries no assembly key",
		not bool(bad.get("success", true)) and not bad.has("assembly"))
	check_eq("…and did not re-run the channel", int(shim.assembly_calls), calls_before)

	ctx["driver"].free_panel(ctx["panel"])


# ══ 24. Epoch UX3 station 1: FREEZE tools — settlement at the MCP doorway ═════
# The tool layer's half of K7/K8: the freeze/unfreeze dispatch pair, the
# frozen-task hold surfaced on a propose reply with its OWN named reason, the
# frozen candidate riding the pinned_candidates keep-out wire (K8's obstacle
# half, asserted on the BUILT request exactly as group 11 does for pins), and
# the named refusals freeze's teeth produce at this layer.

func _run_ux3_freeze_tools() -> void:
	print("-- 24. UX3 station 1: freeze/unfreeze tools, frozen hold, keep-out wire --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]

	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose landed a candidate", bool(first.get("success", false)))
	var cid := str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))

	# ── FREEZE dispatches through the shared disposition-verb seam ───────────
	var frozen: Dictionary = PanelTools._workspace_freeze(shim, _args({"candidate_id": cid}))
	check("freeze succeeded", bool(frozen.get("success", false)))
	check_eq("freeze moved the disposition", str(frozen.get("disposition", "")), "frozen")
	check("freeze reply teaches the contract (note names unfreeze)",
		str(frozen.get("note", "")).contains("unfreeze"))
	check("the workspace frozen index agrees", ws.is_frozen(cid))
	check("workspace_list reports it in frozen_candidate_ids",
		cid in (PanelTools._workspace_list(shim, _args()).get("frozen_candidate_ids", []) as Array))

	# ── the frozen candidate HOLDS its task on a batch propose, with the
	# FROZEN reason — not the pinned one ─────────────────────────────────────
	var held: Dictionary = await PanelTools._workspace_propose(shim, _args())
	check("propose over a frozen task still succeeded", bool(held.get("success", false)))
	check_eq("propose landed NOTHING for the frozen task", int(held.get("proposed", 0)), 0)
	var holds: Array = held.get("holds", [])
	check_eq("the frozen hold is surfaced exactly once", holds.size(), 1)
	if holds.size() == 1:
		check_eq("the hold carries HOLD_FROZEN",
			str((holds[0] as Dictionary).get("reason", "")), PcbWorkspace.HOLD_FROZEN)
		check_eq("the hold names the frozen candidate",
			str((holds[0] as Dictionary).get("held_candidate_id", "")), cid)

	# ── K8's obstacle half at the REQUEST layer: the frozen candidate rides
	# the pinned_candidates wire (one wire, one worker contract — the same
	# assertion shape group 11 makes for pins) ───────────────────────────────
	var call_last: Dictionary = shim.calls[shim.calls.size() - 1]
	var extra: Dictionary = call_last.get("extra", {})
	check("frozen-active propose: request carries pinned_candidates", extra.has("pinned_candidates"))
	var wire: Array = extra.get("pinned_candidates", [])
	check_eq("the keep-out wire names exactly the frozen candidate", wire.size(), 1)
	if wire.size() == 1:
		check_eq("keep-out wire candidate_id matches",
			str((wire[0] as Dictionary).get("candidate_id", "")), cid)
		check("keep-out wire speaks the shared candidate language",
			(wire[0] as Dictionary).has("segments") and (wire[0] as Dictionary).has("revision"))

	# ── the teeth at this layer: reject refuses BY NAME while frozen ─────────
	var refused: Dictionary = PanelTools._workspace_reject(shim, _args({"candidate_id": cid}))
	check("reject on a frozen candidate fails", not bool(refused.get("success", true)))
	check_eq("the refusal is NAMED illegal_disposition_transition (frozen is live, not terminal)",
		str(refused.get("error", "")), PcbRouteCandidate.ERR_ILLEGAL_TRANSITION)
	check_eq("the refusal names where it stood", str(refused.get("from", "")), "frozen")

	# edit_candidate's move_junction doorway refuses with the model's own name.
	var edit_refused: Dictionary = PanelTools._workspace_edit_candidate(shim, _args({
		"candidate_id": cid, "op": "move_junction",
		"point": [5.0, 0.0], "to": [5.0, 1.0]}))
	check("edit_candidate on a frozen candidate fails", not bool(edit_refused.get("success", true)))
	check_eq("...named candidate_frozen", str(edit_refused.get("error", "")), PcbWorkspace.ERR_FROZEN)

	# Cold-review finding 3: the bridged Add-Via gate fires BEFORE the
	# annotation write — a frozen bridged candidate refuses the WHOLE edit, so
	# the two stores can never diverge under a success reply.
	var bridged_hint: String = str(ctx["hint_id"])
	ws.correlate(cid, bridged_hint)
	var ann_before: Dictionary = (ctx["host"].get_by_id(bridged_hint) as Dictionary).duplicate(true)
	var via_refused: Dictionary = PanelTools._add_via(ctx["host"], {
		"id": bridged_hint, "x": 2.0, "y": 0.0})
	check("bridged add_via on a frozen candidate fails", not bool(via_refused.get("success", true)))
	check_eq("...named candidate_frozen (the same one name every edit doorway uses)",
		str(via_refused.get("error", "")), "candidate_frozen")
	var ann_after: Dictionary = ctx["host"].get_by_id(bridged_hint)
	check("...and the ANNOTATION was not touched either (no store divergence)",
		str(ann_after.get("kind_payload", {})) == str(ann_before.get("kind_payload", {})))

	# ── UNFREEZE: the demotion, after which reject is legal again ────────────
	var unfrozen: Dictionary = PanelTools._workspace_unfreeze(shim, _args({"candidate_id": cid}))
	check("unfreeze succeeded", bool(unfrozen.get("success", false)))
	check_eq("unfreeze returned to proposed", str(unfrozen.get("disposition", "")), "proposed")
	check("...and left the frozen index", not ws.is_frozen(cid))
	var rejected: Dictionary = PanelTools._workspace_reject(shim, _args({"candidate_id": cid}))
	check("reject is legal after the two-step demotion", bool(rejected.get("success", false)))

	# Unknown candidate refuses identically to the sibling verbs.
	var missing: Dictionary = PanelTools._workspace_freeze(shim, _args({"candidate_id": "cand_nope"}))
	check_eq("freeze on an unknown candidate is named candidate_not_found",
		str(missing.get("error", "")), PcbWorkspace.ERR_NO_CANDIDATE)

	ctx["driver"].free_panel(ctx["panel"])


# ══ 25. Epoch UX3 station 4: the focused FINDING is get_selection-visible ═════
# Clicking a DRC witness records "cid#index" in workspace.selected_finding_id;
# minerva_pcb_get_selection then answers with the STORED finding verbatim plus
# locating ids — the read half of K11's feedback loop.

func _run_ux3_witness_selection_read() -> void:
	print("-- 25. UX3 station 4: focused finding rides get_selection --")
	var ctx: Dictionary = await _panel_context()
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var first: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var cid := str(((first.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))

	ws.begin_check()
	ws.apply_check_result({
		"board_token": ws.board_token,
		"workspace_generation": ws.workspace_generation(),
		"per_candidate": {cid: "violating"},
		"findings": [{
			"type": "gc2_copper_clearance", "measured_mm": 0.1, "required_mm": 0.2,
			"layer": "F.Cu", "net_name": "N1",
			"closest": [2.0, 0.0], "witness": [2.0, 1.5],
			"subjects": [{"candidate_id": cid}],
		}],
	})
	ws.selected_finding_id = "%s#0" % cid

	var sel: Dictionary = PanelTools._get_selection(shim, _args())
	check("get_selection succeeds", bool(sel.get("success", false)))
	var finding_entries: Array = []
	for e in sel.get("selection", []):
		if e is Dictionary and str((e as Dictionary).get("kind", "")) == "finding":
			finding_entries.append(e)
	check_eq("exactly one finding entry", finding_entries.size(), 1)
	if finding_entries.size() == 1:
		var fe: Dictionary = finding_entries[0]
		check_eq("it locates itself", str(fe.get("id", "")), "%s#0" % cid)
		check_eq("…and its candidate", str(fe.get("candidate_id", "")), cid)
		check_eq("the stored verdict rides verbatim: type",
			str(fe.get("type", "")), "gc2_copper_clearance")
		check("…measured vs required",
			is_equal_approx(float(fe.get("measured_mm", 0.0)), 0.1)
			and is_equal_approx(float(fe.get("required_mm", 0.0)), 0.2))
		check("…witness geometry (the same keys the canvas draws)",
			(fe.get("closest", []) as Array).size() == 2
			and (fe.get("witness", []) as Array).size() == 2)

	# A DANGLING focus (findings replaced since the click) contributes nothing.
	ws.selected_finding_id = "%s#7" % cid
	var sel2: Dictionary = PanelTools._get_selection(shim, _args())
	var dangling := 0
	for e2 in sel2.get("selection", []):
		if e2 is Dictionary and str((e2 as Dictionary).get("kind", "")) == "finding":
			dangling += 1
	check_eq("a dangling finding id contributes NO entry (no guess)", dangling, 0)

	ctx["driver"].free_panel(ctx["panel"])


# ══ 26. Epoch UX3 station 7: mouse commit rides the gate + the ack dialog ═════
# The canvas signal → panel handler → gated tool chain, and the acknowledge
# state machine (_pending_ack_commit → confirm/cancel). No new commit
# semantics — the assertions mirror the tool-level gate group, reached through
# the HUMAN doorway.

func _run_ux3_commit_dialog() -> void:
	print("-- 26. UX3 station 7: gated mouse commit, acknowledge state machine --")
	# MOUNTED: the narration assertions read the StatusBar, which only exists
	# once _build_ui has run (the same reason group 8 mounts).
	var ctx: Dictionary = await _panel_context(true)
	var shim = ctx["shim"]
	var ws = ctx["ws"]
	var panel = ctx["panel"]
	var data = ctx["data"]

	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var cid := str(((out.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	var cand = ws.get_candidate(cid)
	cand.endpoints = [{"component": "U1", "pin": "3"}, {"component": "U2", "pin": "7"}]
	var finding := {"kind": "courtyard_overlap", "components": ["U1", "D1"],
		"message": "U1 and D1 courtyards overlap"}
	panel.set_assembly_state({"status": "findings", "findings": [finding]},
		int(data.board_revision))

	# ── the handler hits the gate: pending state, no copper, narrated ────────
	var traces_before: int = int(data.traces.size())
	await panel._on_candidate_commit_requested([cid])
	check("the gate parked a pending acknowledgment", not panel._pending_ack_commit.is_empty())
	check_eq("…for the requested candidate",
		str((panel._pending_ack_commit.get("candidate_ids", []) as Array)[0]), cid)
	var pend_blocked: Array = panel._pending_ack_commit.get("blocked", [])
	check_eq("…carrying the blocking findings in the batch shape", pend_blocked.size(), 1)
	check_eq("no copper was laid", int(data.traces.size()), traces_before)
	check_eq("the candidate is still proposed", str(ws.get_candidate(cid).disposition), "proposed")
	var status: Variant = panel.find_child("StatusBar", true, false)
	check("the refusal is narrated (acknowledgment named)",
		status != null and str(status.text).contains("acknowledgment"))

	# ── CANCEL clears the pending state and commits nothing ──────────────────
	panel._cancel_placement_ack()
	check("cancel cleared the pending state", panel._pending_ack_commit.is_empty())
	check_eq("…and still no copper", int(data.traces.size()), traces_before)

	# ── CONFIRM re-runs with acknowledge_placement:true: copper lands and the
	# consent is recorded on the reply exactly as the MCP path records it ─────
	await panel._on_candidate_commit_requested([cid])
	check("pending again", not panel._pending_ack_commit.is_empty())
	await panel._confirm_placement_ack()
	check("confirm consumed the pending state", panel._pending_ack_commit.is_empty())
	check_eq("the acknowledged commit laid the copper",
		int(data.traces.size()), traces_before + 3)
	check_eq("the candidate is committed", str(ws.get_candidate(cid).disposition), "committed")
	check("the outcome narrates the acknowledgment count",
		status != null and str(status.text).contains("acknowledged"))

	ctx["driver"].free_panel(ctx["panel"])


# ══ 27. Epoch UX3 station 9: the superseded-hint mouse exit ═══════════════════
# The press-time resolver gates on exactly one selected, SUPERSEDED route
# hint; the menu offers "Reclaim waypoints" and the handler runs the SAME
# convert tool (one implementation). Applied-locked hints (lifecycle lock, no
# supersession marker) never offer the item — conversion is not their exit.

func _run_ux3_reclaim_menu() -> void:
	print("-- 27. UX3 station 9: reclaim resolver + menu item + one-tool delegation --")
	var ctx: Dictionary = await _panel_context(true)
	var host = ctx["host"]
	var canvas = ctx["panel"]._canvas
	var hint_id: String = str(ctx["hint_id"])

	# Not superseded yet: the resolver refuses.
	host.set_selected_annotation_ids(PackedStringArray([hint_id]))
	check_eq("an ordinary hint resolves no reclaim target",
		str(canvas._superseded_hint_selected()), "")

	# Stamp the supersession marker (the shape station 12's seeding writes).
	var ann: Dictionary = host.get_by_id(hint_id)
	var kp: Dictionary = ann.get("kind_payload", {})
	kp["waypoints_superseded_by_constraint_revision"] = 2
	ann["kind_payload"] = kp
	check("marker stamped", host.update_annotation(hint_id, ann))
	check_eq("a superseded hint resolves as the reclaim target",
		str(canvas._superseded_hint_selected()), hint_id)

	# Multi-selection has no unambiguous target.
	var second_env: Dictionary = host.build_route_hint_envelope(
		1.0, 1.0, "", "F.Cu", "waypoint", [[1.0, 1.0], [2.0, 1.0]], "human")
	var second_id: String = str(host.add_annotation_v2(second_env))
	host.set_selected_annotation_ids(PackedStringArray([hint_id, second_id]))
	check_eq("a multi-selection resolves nothing",
		str(canvas._superseded_hint_selected()), "")
	host.set_selected_annotation_ids(PackedStringArray([hint_id]))

	# The menu carries the item when the press resolved a target.
	canvas._create_context_menu()
	canvas._context_menu_target = ["", ""]
	canvas._context_menu_superseded_hint = canvas._superseded_hint_selected()
	canvas._update_context_menu_for_selection()
	var labels: Array = []
	for i in range(canvas.context_menu.item_count):
		labels.append(canvas.context_menu.get_item_text(i))
	check("the menu offers Reclaim waypoints (convert to detailed)",
		"Reclaim waypoints (convert to detailed)" in labels)

	# The handler runs the ONE convert tool: marker stripped, hint editable.
	_messages.clear()
	canvas.trace_tool_message.connect(_on_canvas_message)
	canvas._reclaim_superseded_hint(hint_id)
	var after: Dictionary = host.get_by_id(hint_id)
	check("the conversion stripped the supersession marker",
		not (after.get("kind_payload", {}) as Dictionary).has("waypoints_superseded_by_constraint_revision"))
	check("the outcome was narrated", _messages.size() >= 1
		and str(_messages[-1]).contains("Reclaimed"))
	canvas.trace_tool_message.disconnect(_on_canvas_message)

	ctx["driver"].free_panel(ctx["panel"])


# ══ 28. Epoch UX3 station 10: reverse deixis + micro hint edits + clear ═══════

func _run_ux3_reverse_parity() -> void:
	print("-- 28. UX3 station 10: point verb, bend micro-edits, clear-by-author --")
	var ctx: Dictionary = await _panel_context(true)
	var shim = ctx["shim"]
	var host = ctx["host"]
	var ws = ctx["ws"]
	var canvas = ctx["panel"]._canvas
	var hint_id: String = str(ctx["hint_id"])

	# ── (a) POINT: the get_selection mirror, through the click's choke points ─
	var out: Dictionary = await PanelTools._workspace_propose(shim, _args())
	var cid := str(((out.get("candidates", []) as Array)[0] as Dictionary).get("candidate_id", ""))
	ctx["panel"].get_routing_cutover().set_workspace_authoritative("canvas", true)
	canvas.set_routing_workspace(ws, ctx["panel"].get_routing_cutover())

	var pointed: Dictionary = PanelTools._point(shim, _args({"kind": "candidate", "id": cid}))
	check("point at a candidate succeeds", bool(pointed.get("success", false)))
	check("…it became the canvas selection", cid in canvas.selected_candidate_ids)
	check_eq("…and the workspace active candidate (the click's own active-sync)",
		str(ws.active_candidate_id), cid)
	# The round trip: get_selection now reports what point selected.
	var sel: Dictionary = PanelTools._get_selection(shim, _args())
	var sel_ids: Array = []
	for e in sel.get("selection", []):
		if e is Dictionary and str((e as Dictionary).get("kind", "")) == "candidate":
			sel_ids.append(str((e as Dictionary).get("id", "")))
	check("…and get_selection mirrors it back (deixis both ways)", cid in sel_ids)

	var missing: Dictionary = PanelTools._point(shim, _args({"kind": "component", "id": "U404"}))
	check("pointing at a missing entity refuses by name",
		not bool(missing.get("success", true))
		and str(missing.get("error", "")) == "not_found")
	var bad_kind: Dictionary = PanelTools._point(shim, _args({"kind": "netclass", "id": "x"}))
	check_eq("an unknown kind refuses by name", str(bad_kind.get("error", "")), "unknown_kind")

	# Point at the seeded hint annotation → host selection.
	var ann_point: Dictionary = PanelTools._point(shim, _args({"kind": "annotation", "id": hint_id}))
	check("point at an annotation succeeds", bool(ann_point.get("success", false)))
	check("…it is the host's selected annotation",
		str(host.get_selected_annotation_id()) == hint_id)

	# ── (b) bend micro-edits: one verb, one bend, one revision ───────────────
	# The seeded hint's waypoints are [[0,0],[5,0]] (legacy full-path shape →
	# zero interior bends).
	var ins: Dictionary = PanelTools._hint_bend_edit(host, {"hint_id": hint_id,
		"x_mm": 2.0, "y_mm": 1.0}, "insert")
	check("insert lands", bool(ins.get("success", false)))
	check_eq("…bend_count 1", int(ins.get("bend_count", 0)), 1)
	var mv: Dictionary = PanelTools._hint_bend_edit(host, {"hint_id": hint_id,
		"index": 0, "x_mm": 2.5, "y_mm": 1.5}, "move")
	check("move lands", bool(mv.get("success", false)))
	check("…at the new position",
		is_equal_approx(float(((mv.get("bends", []) as Array)[0] as Array)[0]), 2.5))
	var oob: Dictionary = PanelTools._hint_bend_edit(host, {"hint_id": hint_id,
		"index": 7, "x_mm": 0.0, "y_mm": 0.0}, "move")
	check_eq("out-of-range refuses by name",
		str(oob.get("error", "")), "bend_index_out_of_range")
	var del: Dictionary = PanelTools._hint_bend_edit(host, {"hint_id": hint_id, "index": 0}, "delete")
	check("delete lands", bool(del.get("success", false)))
	check_eq("…bend_count back to 0", int(del.get("bend_count", 1)), 0)

	# Superseded lock: the marker refuses every micro verb with the exits named.
	var ann2: Dictionary = host.get_by_id(hint_id)
	var kp2: Dictionary = ann2.get("kind_payload", {})
	kp2["waypoints_superseded_by_constraint_revision"] = 3
	ann2["kind_payload"] = kp2
	host.update_annotation(hint_id, ann2)
	var locked: Dictionary = PanelTools._hint_bend_edit(host, {"hint_id": hint_id,
		"x_mm": 1.0, "y_mm": 1.0}, "insert")
	check_eq("a superseded hint refuses by name",
		str(locked.get("error", "")), "waypoints_superseded")
	check("…naming the sanctioned exits", str(locked.get("note", "")).contains("convert_to_detailed"))

	# ── (c) clear-by-author: the dock filter, over MCP ───────────────────────
	var ai_env: Dictionary = host.build_route_hint_envelope(
		3.0, 3.0, "", "F.Cu", "waypoint", [[3.0, 3.0], [4.0, 3.0]], "ai")
	var ai_id: String = str(host.add_annotation_v2(ai_env))
	check("an AI hint exists", not str(ai_id).is_empty())
	var cleared: Dictionary = PanelTools._clear_hints_by_author(host, {"author": "ai"})
	check("clear by author=ai succeeds", bool(cleared.get("success", false)))
	check_eq("…removing exactly the AI hint", int(cleared.get("removed", 0)), 1)
	check("…the human hint survives", not (host.get_by_id(hint_id) as Dictionary).is_empty())
	var bad_author: Dictionary = PanelTools._clear_hints_by_author(host, {"author": "codex"})
	check("an unknown author refuses", not bool(bad_author.get("success", true)))

	ctx["driver"].free_panel(ctx["panel"])


# ══ 29. COPPER-LOSS RECONCILE ════════════════════════════════════════════════
#
# Deleting copper a COMMITTED candidate owns must retire that commit: the
# disposition leaves "committed", committed_trace_ids stops naming traces the
# board no longer has, and the routing TASK REOPENS.
#
# What each part of the group pins down:
#   * a HEALTHY commit SURVIVES the pass — asserted BEFORE anything is deleted,
#     so an existence check that cannot tell present from absent (wrong lookup,
#     object-vs-id compare) fails here.
#   * the TASK STATE is the claim, so task_state / open_task_ids / disposition
#     are the load-bearing assertions and the id list is checked second.
#     Filtering dead ids out of committed_trace_ids at read time passes a
#     shape-only test and fails these.
#   * the SURVIVORS are read off the BOARD, not off the reply, so copper the
#     caller did not name must still be there afterwards.
#   * UNDO AND REDO BOTH WAYS. Undo of the delete brings the copper AND the
#     commit back; redo takes both away again. That holds only because the
#     reconcile runs INSIDE the delete's own history step.

func _run_copper_loss_reconcile() -> void:
	print("-- 29. bug 01a02bf97224: deleting committed copper retires the commit and reopens the span --")
	_run_copper_loss_model()
	_run_copper_loss_delete_tool()


## MODEL half: the rule itself, on the mandatory multipad fixture (3 traces +
## 1 via, two layers, two disconnected paths).
func _run_copper_loss_model() -> void:
	var ctx := _model_context()
	var ws = ctx["ws"]
	var data = ctx["data"]
	var cid: String = ctx["cid"]
	var task_id: String = str(ws.get_candidate(cid).task_id)

	# PIN first, so the disposition the reconcile restores is a NON-DEFAULT one:
	# a candidate committed from "proposed" cannot tell a real restore from a
	# constructor default.
	check("pin the candidate before committing", ws.pin(cid))
	var res: Dictionary = ws.commit(cid, data)
	check("commit reports ok", bool(res.get("ok", false)))
	var committed_traces: Array = (res.get("trace_ids", []) as Array).duplicate()
	check_eq("the fixture committed three traces", committed_traces.size(), 3)
	check_eq("…and one via", (res.get("via_ids", []) as Array).size(), 1)
	check_eq("its task is closed", ws.task_state(task_id), "closed")

	# A REAL VERDICT to lose: "unchecked" has nothing to stale, so a candidate
	# that never carried a verdict cannot show that the reconcile stales one.
	ws.set_validation(cid, "clean")

	# ── THE NEGATIVE, FIRST: intact copper is not loss ────────────────────────
	check_eq("a pass over INTACT copper retires nothing",
		(ws.reconcile_committed_copper(data) as Array).size(), 0)
	check_eq("…the candidate is still committed",
		str(ws.get_candidate(cid).disposition), "committed")
	check_eq("…its task is still closed", ws.task_state(task_id), "closed")
	check_eq("…and its verdict is untouched", str(ws.get_candidate(cid).validation), "clean")

	# ── PARTIAL LOSS: one of three traces removed, by the board's own remover ─
	var doomed := str(committed_traces[1])
	data.remove_trace(doomed)
	check("the board no longer resolves the deleted trace", data.get_trace(doomed) == null)

	var retired: Array = ws.reconcile_committed_copper(data)
	check_eq("losing ONE of three traces retires the commit", retired.size(), 1)
	check_eq("…naming the candidate", str(retired[0]) if retired.size() > 0 else "", cid)
	check_eq("…which is back at its PRE-commit disposition",
		str(ws.get_candidate(cid).disposition), "pinned")
	check_eq("…ITS TASK IS OPEN AGAIN — the span is not routed",
		ws.task_state(task_id), "open")
	check("…and the task reads open from the list surface too",
		task_id in ws.open_task_ids())
	check_eq("…the dead copper ids are CLEARED, not filtered at read time",
		(ws.committed_copper_ids(cid).get("trace_ids", []) as Array).size(), 0)
	check_eq("…the recorded vias are cleared with them (never orphaned)",
		(ws.committed_copper_ids(cid).get("via_ids", []) as Array).size(), 0)
	check_eq("…and the verdict scored against the old copper is staled",
		str(ws.get_candidate(cid).validation), "stale")

	# ── THE SURVIVORS ARE NOT THIS PASS'S TO REMOVE ──────────────────────────
	check_eq("the two traces the user did NOT name are still on the board",
		int(data.traces.size()), 2)
	check("the first survivor is still resolvable by id",
		data.get_trace(str(committed_traces[0])) != null)
	check("the third survivor is still resolvable by id",
		data.get_trace(str(committed_traces[2])) != null)
	check_eq("the via is untouched too", int(data.vias.size()), 1)

	# ── IDEMPOTENT: a retired commit is not committed, so a second pass has
	#    nothing to do — including the pass at every workspace verb's entry.
	check_eq("a second pass retires nothing",
		(ws.reconcile_committed_copper(data) as Array).size(), 0)
	check_eq("…and the disposition did not move again",
		str(ws.get_candidate(cid).disposition), "pinned")
	check_eq("…nor did the task state", ws.task_state(task_id), "open")

	# ── A COMMIT THAT CLAIMED NO COPPER IS NEVER RETIRED ─────────────────────
	# mark_committed's annotation-accept shape records no ids: it makes no claim
	# about board copper, so an EMPTY board does not falsify it.
	var ws2 = PcbWorkspace.new()
	var bare = PcbData.new()
	bare.save_to_history("baseline")
	var cid2 := str(ws2.ingest_record(_multipad_record(), int(bare.board_revision)))
	check("the id-less fixture marks committed", ws2.mark_committed(cid2))
	check_eq("…its task is closed", ws2.task_state(str(ws2.get_candidate(cid2).task_id)), "closed")
	check_eq("a pass over a board with NO copper at all retires nothing",
		(ws2.reconcile_committed_copper(bare) as Array).size(), 0)
	check_eq("…the id-less commit stands", str(ws2.get_candidate(cid2).disposition), "committed")


## TOOL half: commit, then minerva_pcb_delete_traces, then
## minerva_pcb_workspace_list — plus the undo/redo pairing the in-history-step
## reconcile produces.
func _run_copper_loss_delete_tool() -> void:
	var data = PcbData.new()
	data.save_to_history("baseline")
	var ws = PcbWorkspace.new()
	var host = load(ANNOTATION_HOST_SCRIPT_PATH).new()
	var stub := _RouteIntentStubPanel.new()
	stub._data = data
	stub._ws = ws
	host.set_panel(stub)

	var cid := str(ws.ingest_record(_multipad_record(), int(data.board_revision)))
	var task_id: String = str(ws.get_candidate(cid).task_id)
	var res: Dictionary = ws.commit(cid, data)
	check("tool half: commit lands", bool(res.get("ok", false)))
	var committed_traces: Array = (res.get("trace_ids", []) as Array).duplicate()
	check_eq("tool half: three traces committed", committed_traces.size(), 3)

	# The BEFORE reading, through the real listing tool.
	var before: Dictionary = PanelTools._workspace_list(host, _args({"include_terminal": true}))
	check("workspace_list succeeds", bool(before.get("success", false)))
	check_eq("before the delete the task reads CLOSED",
		_task_state_in(before, task_id), "closed")

	# ── THE ACCEPTANCE ACT: delete ONE of the committed traces by id ─────────
	var doomed := str(committed_traces[0])
	var deleted: Dictionary = PanelTools._delete_traces(host, _args({"trace_ids": [doomed]}))
	check("delete_traces succeeds", bool(deleted.get("success", false)))
	check_eq("…removing exactly the one named trace",
		int(deleted.get("deleted_trace_count", -1)), 1)
	check_eq("…leaving the other two", int(deleted.get("remaining_trace_count", -1)), 2)
	check("…and SAYING it reopened routing work",
		(deleted.get("reopened_candidate_ids", []) as Array).has(cid))
	check("…in a note that names the consequence",
		str(deleted.get("note", "")).to_lower().contains("open"))

	# ── THE ACCEPTANCE READING ───────────────────────────────────────────────
	var after: Dictionary = PanelTools._workspace_list(host, _args({"include_terminal": true}))
	check_eq("AFTER the delete the task reads OPEN — not routed",
		_task_state_in(after, task_id), "open")
	check("…and it is listed among open_task_ids",
		(after.get("open_task_ids", []) as Array).has(task_id))
	var rec: Dictionary = _candidate_in(after, cid)
	check_eq("…the candidate is live again", str(rec.get("disposition", "")), "proposed")
	check("…and no longer names copper the board cannot find",
		not rec.has("committed_trace_ids"))

	# ── UNDO: the copper AND the commit come back together (bucket 8) ────────
	check("undo of the delete reports success", data.undo())
	check_eq("…the deleted trace is back", int(data.traces.size()), 3)
	check_eq("…and the candidate is committed again",
		str(ws.get_candidate(cid).disposition), "committed")
	var undone: Dictionary = PanelTools._workspace_list(host, _args({"include_terminal": true}))
	check_eq("…so the task reads closed once more", _task_state_in(undone, task_id), "closed")
	check("…and the verb-entry pass did NOT re-fire on the restored copper",
		str(ws.get_candidate(cid).disposition) == "committed")

	# ── REDO: both halves leave again, from the delete's own history entry ───
	check("redo of the delete reports success", data.redo())
	check_eq("…the trace is gone again", int(data.traces.size()), 2)
	check_eq("…and the commit is retired again, without a second reconcile",
		str(ws.get_candidate(cid).disposition), "proposed")
	var redone: Dictionary = PanelTools._workspace_list(host, _args({"include_terminal": true}))
	check_eq("…the task reads open again", _task_state_in(redone, task_id), "open")


## The `state` of one task in a workspace_list reply, or "" when the listing
## does not carry it. Read from the REPLY, never from the model.
func _task_state_in(reply: Dictionary, task_id: String) -> String:
	for t in (reply.get("tasks", []) as Array):
		if t is Dictionary and str((t as Dictionary).get("task_id", "")) == task_id:
			return str((t as Dictionary).get("state", ""))
	return ""


## One candidate record out of a workspace_list reply, {} when absent.
func _candidate_in(reply: Dictionary, candidate_id: String) -> Dictionary:
	for c in (reply.get("candidates", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("candidate_id", "")) == candidate_id:
			return c
	return {}
