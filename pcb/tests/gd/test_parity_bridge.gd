extends SceneTree
## T2.3 — Shadow PARITY BRIDGE + cutover coordinator tests (non-mocked, Layer-1).
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   cd <minerva-scaffold> && godot --headless --path src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_parity_bridge.gd
## (host-boot SQLite/_db + MCP-autostart SCRIPT ERRORs are the scaffold's, not
## ours — ignore them; green == 0 FAIL + exit 0.)
##
## Every functional group boots a REAL PCBPanel (plugin_panel_driver), wires the
## real host→panel back-reference (host.set_panel — the mount-time wiring), and
## drives the EXACT production seams: panel_tools._dual_write_propose /
## _proposal_accept / _proposal_reject / _add_via. No fakes; only the router
## worker hop is substituted by a fixture reply (worker *.py is out of fence).
##
## MANDATORY fixtures (the via bugs all hid behind 2-pin single-path fixtures):
##   * a multi-pad (3-pin) net whose route is TWO DISCONNECTED copper paths + a
##     layer-changing via (INV-3 trap), used everywhere;
##   * an undo-AFTER-commit scenario (GATE INV-1 — vias must not be orphaned).

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PcbData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCutover := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_cutover.gd")
const PcbWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbSidecar := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_sidecar.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Shadow Parity Bridge (T2.3) Tests ===\n")
	_run_ingest_correlation()
	_run_reject_bridge()
	_run_accept_bridge_stable_ids()
	_run_add_via_bridge()
	_run_undo_after_commit()
	_run_correlation_persistence()
	_run_cutover_coordinator()
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


# ── fixtures ──────────────────────────────────────────────────────────────────

## 3-pad net "N1": two DISCONNECTED copper groups — {seg_a,seg_b} joined by a
## layer-changing via, and seg_c standing alone (no shared endpoint anywhere).
func _multipad_reply() -> Dictionary:
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
			}
		],
		"via_count": 1,
	}


## A REAL source-hint annotation stored on the host + a propose-shaped source_hints
## array referencing its real id (so the proposal's proposal_for links a live
## annotation and is_annotation_superseded can be exercised). Returns [hint_id,
## source_hints].
func _seed_source_hint(host) -> Array:
	var env: Dictionary = host.build_route_hint_envelope(0.0, 0.0, "", "F.Cu", "waypoint", [[0.0, 0.0], [5.0, 0.0]], "human")
	var hint_id: String = str(host.add_annotation_v2(env))
	var source_hints := [{
		"id": hint_id,
		"kind_payload": {
			"net_names": ["N1"], "width_mm": 0.3,
			"source_pins": ["U1.3"], "dest_pins": ["U2.7"],
		},
	}]
	return [hint_id, source_hints]


## Boot a real PCBPanel + host wired with the panel back-reference, dual-write a
## propose of the multipad fixture, and return a context dict with the driver,
## panel, host, workspace, the source hint id, and the bridged {ann_id, cand_id}.
func _bridged_context() -> Dictionary:
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var ws = panel.get_routing_workspace()

	var seeded := _seed_source_hint(host)
	var hint_id: String = seeded[0]
	var source_hints: Array = seeded[1]

	var out: Dictionary = PanelTools._dual_write_propose(host, _multipad_reply(), source_hints)

	# The proposal annotation = the pcb_route_hint carrying proposal_for.
	var ann_id := ""
	for ann in host.get_all_annotations():
		if ann is Dictionary and (ann as Dictionary).get("kind_payload", {}) is Dictionary:
			var kp: Dictionary = (ann as Dictionary).get("kind_payload", {})
			if kp.has("proposal_for"):
				ann_id = str((ann as Dictionary).get("id", ""))
				break
	var cand_id := str(ws.candidate_for_annotation(ann_id))
	return {
		"driver": driver, "panel": panel, "host": host, "ws": ws,
		"hint_id": hint_id, "ann_id": ann_id, "cand_id": cand_id, "out": out,
	}


# ── 1. one ingest → identical geometry + bidirectional correlation ────────────

func _run_ingest_correlation() -> void:
	print("-- 1. one ingest -> identical geometry + bidirectional correlation --")
	var ctx := _bridged_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var ann_id: String = ctx["ann_id"]
	var cand_id: String = ctx["cand_id"]

	check("proposal annotation authored", not ann_id.is_empty())
	check("candidate created", not cand_id.is_empty())

	# Bidirectional correlation.
	check_eq("candidate_for_annotation(ann) -> cand", ws.candidate_for_annotation(ann_id), cand_id)
	check_eq("annotation_for_candidate(cand) -> ann", ws.annotation_for_candidate(cand_id), ann_id)
	check("is_candidate_bridged", ws.is_candidate_bridged(cand_id))
	check("is_annotation_bridged", ws.is_annotation_bridged(ann_id))

	# Identical geometry: candidate vs the annotation projection's kind_payload.
	var proposal: Dictionary = host.get_by_id(ann_id)
	var kp: Dictionary = proposal.get("kind_payload", {})
	var cand = ws.get_candidate(cand_id)
	check_eq("segment count identical", cand.segments.size(), (kp.get("segments", []) as Array).size())
	check_eq("via count identical", cand.vias.size(), (kp.get("vias", []) as Array).size())
	check_eq("candidate has 3 segments (INV-3, not merged)", cand.segments.size(), 3)
	check_eq("candidate has 1 via", cand.vias.size(), 1)
	# Geometry parity on the disconnected standalone segment (seg 2).
	var raw_seg2: Dictionary = (kp.get("segments", [])[2]) as Dictionary
	var cand_seg2_start: Vector2 = cand.segments[2].get("points")[0]
	check_eq("seg2 start x parity", cand_seg2_start.x, float((raw_seg2.get("start") as Array)[0]))
	check_eq("seg2 start y parity", cand_seg2_start.y, float((raw_seg2.get("start") as Array)[1]))
	var via_pos: Vector2 = cand.vias[0].get("position")
	check_eq("via position parity", via_pos, Vector2(5.0, 0.0))

	ctx["driver"].free_panel(ctx["panel"])


# ── 2. reject-via-bridge: candidate leaves live set + hint un-supersedes ───────

func _run_reject_bridge() -> void:
	print("-- 2. reject-via-bridge: candidate leaves live set + hint un-supersedes --")
	var ctx := _bridged_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var ann_id: String = ctx["ann_id"]
	var cand_id: String = ctx["cand_id"]
	var hint_id: String = ctx["hint_id"]

	# Pre-reject: candidate live, hint superseded by the proposal.
	check("candidate live before reject", cand_id in ws.live_candidate_ids())
	check("hint superseded before reject", host.is_annotation_superseded(host.get_by_id(hint_id)))

	var res: Dictionary = PanelTools._proposal_reject(host, {"id": ann_id})
	check("reject succeeds", bool(res.get("success", false)))
	check_eq("reject reports the bridged candidate", str(res.get("rejected_candidate_id", "")), cand_id)

	# Post-reject: candidate rejected (out of live set), hint un-superseded.
	check_eq("candidate disposition == rejected", ws.get_candidate(cand_id).disposition, "rejected")
	check("candidate NOT in live set after reject", not (cand_id in ws.live_candidate_ids()))
	check("proposal annotation removed", host.get_by_id(ann_id).is_empty())
	check("hint un-superseded after reject", not host.is_annotation_superseded(host.get_by_id(hint_id)))

	ctx["driver"].free_panel(ctx["panel"])


# ── 3. accept-via-bridge: committed + stable trace/via ids survive reload ──────

func _run_accept_bridge_stable_ids() -> void:
	print("-- 3. accept-via-bridge: committed + STABLE ids survive to_board_dict/reload --")
	var ctx := _bridged_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var panel = ctx["panel"]
	var ann_id: String = ctx["ann_id"]
	var cand_id: String = ctx["cand_id"]

	var res: Dictionary = PanelTools._proposal_accept(host, {"id": ann_id})
	check("accept succeeds", bool(res.get("success", false)))
	check_eq("accept reports the committed candidate", str(res.get("committed_candidate_id", "")), cand_id)

	# Candidate committed → left the live set (accept cannot leave it live).
	check_eq("candidate disposition == committed", ws.get_candidate(cand_id).disposition, "committed")
	check("candidate NOT in live set after accept", not (cand_id in ws.live_candidate_ids()))

	var committed: Dictionary = ws.committed_copper_ids(cand_id)
	var trace_ids: Array = committed.get("trace_ids", [])
	var via_ids: Array = committed.get("via_ids", [])
	check("committed candidate records >=1 trace id", trace_ids.size() >= 1)
	check_eq("committed candidate records 1 via id", via_ids.size(), 1)
	check("recorded trace ids are non-empty", not str(trace_ids[0]).is_empty())
	check("recorded via id is non-empty", not str(via_ids[0]).is_empty())

	# STABLE across to_board_dict() → reload into a FRESH PCBData: same ids.
	var board_dict: Dictionary = panel.get_data().to_board_dict()
	var reloaded = PcbData.new()
	reloaded.from_board_dict(board_dict)
	for tid in trace_ids:
		check("trace id '%s' survives reload" % str(tid), reloaded.traces.has(str(tid)))
	var reloaded_via_ids: Array = []
	for v in reloaded.vias:
		reloaded_via_ids.append(str((v as Dictionary).get("id", "")))
	for vid in via_ids:
		check("via id '%s' survives reload" % str(vid), str(vid) in reloaded_via_ids)

	ctx["driver"].free_panel(panel)


# ── 4. add-via on a bridged candidate: candidate + annotation both updated ─────

func _run_add_via_bridge() -> void:
	print("-- 4. add-via on a bridged candidate: route-through updates BOTH stores --")
	var ctx := _bridged_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var ann_id: String = ctx["ann_id"]
	var cand_id: String = ctx["cand_id"]

	var cand = ws.get_candidate(cand_id)
	var vias_before: int = cand.vias.size()
	var rev_before: int = int(cand.candidate_revision)
	var ann_vias_before: int = (host.get_by_id(ann_id).get("kind_payload", {}).get("vias", []) as Array).size()

	# Insert a via at a point ON seg 0 ((0,0)->(5,0)).
	var res: Dictionary = PanelTools._add_via(host, {"id": ann_id, "x": 2.5, "y": 0.0})
	check("add_via succeeds", bool(res.get("success", false)))
	check("add_via reports the bridged candidate was synced", bool(res.get("bridged_candidate_synced", false)))

	# Annotation projection gained a via.
	var ann_vias_after: int = (host.get_by_id(ann_id).get("kind_payload", {}).get("vias", []) as Array).size()
	check_eq("annotation via count +1", ann_vias_after, ann_vias_before + 1)

	# Correlated candidate re-derived to match (both stores updated, not one).
	var cand_after = ws.get_candidate(cand_id)
	check_eq("candidate via count +1", cand_after.vias.size(), vias_before + 1)
	check_eq("candidate via count matches annotation", cand_after.vias.size(), ann_vias_after)
	check("candidate_revision bumped", int(cand_after.candidate_revision) > rev_before)

	ctx["driver"].free_panel(ctx["panel"])


# ── 5. undo after commit: both stores coherent, vias NOT orphaned (INV-1) ──────

func _run_undo_after_commit() -> void:
	print("-- 5. undo after commit: both stores restored, vias NOT orphaned (GATE INV-1) --")
	var ctx := _bridged_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var panel = ctx["panel"]
	var data = panel.get_data()
	var ann_id: String = ctx["ann_id"]
	var cand_id: String = ctx["cand_id"]

	PanelTools._proposal_accept(host, {"id": ann_id})
	check("board has traces after accept", data.traces.size() >= 1)
	check("board has vias after accept", data.vias.size() == 1)
	check_eq("candidate committed after accept", ws.get_candidate(cand_id).disposition, "committed")

	# Board-level undo of the accept: F1 restores traces AND vias together.
	var undone: bool = data.undo()
	check("data.undo() reports success", undone)
	check_eq("undo removed all traces", data.traces.size(), 0)
	# GATE INV-1: vias are NOT orphaned — they came back to the pre-accept count
	# (0) in lockstep with the traces, never left dangling.
	check_eq("undo removed all vias (not orphaned)", data.vias.size(), 0)

	# Workspace side: uncommit brings the candidate back to a live disposition,
	# coherent with a board that no longer holds its copper.
	var reverted: bool = ws.uncommit(cand_id)
	check("workspace.uncommit reports success", reverted)
	check_eq("candidate reverted to proposed", ws.get_candidate(cand_id).disposition, "proposed")
	check("candidate live again after uncommit", cand_id in ws.live_candidate_ids())
	var after: Dictionary = ws.committed_copper_ids(cand_id)
	check_eq("committed trace ids cleared", (after.get("trace_ids", []) as Array).size(), 0)
	check_eq("committed via ids cleared", (after.get("via_ids", []) as Array).size(), 0)

	ctx["driver"].free_panel(panel)


# ── 6. correlation persists through the routing sidecar ───────────────────────

func _run_correlation_persistence() -> void:
	print("-- 6. correlation persists through the routing sidecar --")
	# Ingest correlated candidates directly on a workspace (no panel needed), then
	# round-trip through the FULL sidecar envelope on disk and assert BOTH lookup
	# directions survive.
	var ws = PcbWorkspace.new()
	var rec := {
		"net": "N1",
		"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
		"vias": [[5.0, 0.0]],
		"width": 0.3, "source_hint_ids": ["hint_1"], "source_hints": [],
	}
	var cand_id := str(ws.ingest_record(rec, 7))
	ws.correlate(cand_id, "ann_42", "task_x", 1)
	check("correlation set on workspace", ws.candidate_for_annotation("ann_42") == cand_id)

	var board = PcbData.new()
	var board_dict: Dictionary = board.to_board_dict()
	var dir := "user://t23_corr_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(dir)
	var board_path := dir + "/board.pcbskel"

	var err: int = PcbSidecar.save_workspace(board_path, ws, board_dict, 7)
	check_eq("save_workspace OK", err, OK)

	var loaded = PcbWorkspace.new()
	var status: Dictionary = PcbSidecar.load_into_workspace(board_path, loaded, board_dict, 7)
	check_eq("sidecar loaded clean", str(status.get("status", "")), "loaded_clean")
	check_eq("candidate_for_annotation survives reload", loaded.candidate_for_annotation("ann_42"), cand_id)
	check_eq("annotation_for_candidate survives reload", loaded.annotation_for_candidate(cand_id), "ann_42")
	var corr: Dictionary = loaded.correlations.get(cand_id, {})
	check_eq("correlation task_id survives", str(corr.get("task_id", "")), "task_x")
	check_eq("correlation generation survives (int, not float)", int(corr.get("generation", -1)), 1)

	PcbSidecar.delete_sidecar(board_path)


# ── 7. cutover coordinator: all annotation-authoritative; guarded flip; rollback ─

func _run_cutover_coordinator() -> void:
	print("-- 6. cutover coordinator: annotation-authoritative default, guarded flip, rollback --")

	# The live panel's coordinator is annotation-authoritative in the shadow window.
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var cutover = panel.get_routing_cutover()
	check("panel exposes a cutover coordinator", cutover != null)
	check("panel cutover: all surfaces annotation-authoritative", cutover.all_annotation_authoritative())
	driver.free_panel(panel)

	# Pure-model behaviour on a fresh coordinator.
	var c = PcbCutover.new()
	for s in PcbCutover.SURFACES:
		check("surface '%s' defaults annotation-authoritative" % s, not c.is_workspace_authoritative(s))
		check_eq("surface '%s' authority string" % s, c.authority(s), "annotation")
	check("all_annotation_authoritative() true at start", c.all_annotation_authoritative())

	# Flip requires the workspace-backed assertion.
	check("flip WITHOUT workspace-backed assertion is rejected", not c.set_workspace_authoritative("canvas", false))
	check("canvas still annotation-authoritative after rejected flip", not c.is_workspace_authoritative("canvas"))
	check("flip WITH workspace-backed assertion succeeds", c.set_workspace_authoritative("canvas", true))
	check("canvas now workspace-authoritative", c.is_workspace_authoritative("canvas"))
	check("other surface (verbs) unaffected by canvas flip", not c.is_workspace_authoritative("verbs"))
	check("not all annotation-authoritative after a flip", not c.all_annotation_authoritative())

	# Unknown surface is never mintable.
	check("unknown surface flip rejected", not c.set_workspace_authoritative("bogus", true))
	check("unknown surface reads annotation-authoritative", not c.is_workspace_authoritative("bogus"))

	# Rollback leaves the old UI coherent (surface back to annotation).
	c.rollback("canvas")
	check("canvas rolled back to annotation-authoritative", not c.is_workspace_authoritative("canvas"))
	check("all_annotation_authoritative() true again after rollback", c.all_annotation_authoritative())

	# Round-trips through to_dict/from_dict (a flipped surface persists).
	c.set_workspace_authoritative("persistence", true)
	var restored = PcbCutover.from_dict(c.to_dict())
	check("to_dict/from_dict preserves a flipped surface", restored.is_workspace_authoritative("persistence"))
	check("to_dict/from_dict preserves an un-flipped surface", not restored.is_workspace_authoritative("canvas"))
