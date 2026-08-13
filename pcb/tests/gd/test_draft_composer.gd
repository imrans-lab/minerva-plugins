extends SceneTree
## Epoch UX4 station 3 (docket 019fe0819809; DCR 019fe07523ca S3, A2/A8/A9):
## the effective-draft-board composer + cache isolation.
##
## Seam note: the full draft propose (router round-trip over a COMPOSED board)
## cannot run under the headless scaffold (no IPC backend). What IS pinned
## here, with the real panel and real store: the composer's per-purpose
## content, the panel's request-board decision (_board_for_route_request),
## and the reply-side isolation — the real _propose_into_workspace,
## _ingest_result_into_workspace (the propose/reroute landing path) and
## _materialize_routes consumers fed real worker-shaped results, asserting
## the DRAFT reply labels its health and never feeds the assembly cache
## (A9) while the direct-copper reply still does. The draft_request
## threading at the propose/reroute call sites is read-verified at review
## (those verbs need a live router).
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_draft_composer.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const StagedEntities := preload("res://../../minerva-plugins/pcb/ui/model/pcb_staged_entities.gd")
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const RouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")

var _pass := 0
var _fail := 0


class FakeEditor extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== Draft composer + cache isolation ===\n")
	await process_frame
	_run_composer_content()
	_run_composer_placements()
	await _run_candidate_placement_provenance()
	await _run_board_check_census()
	_run_composer_fail_safe()
	_run_panel_request_board()
	_run_reply_cache_isolation()
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


const TRI := [Vector2(2, 2), Vector2(8, 2), Vector2(8, 8)]
const TRI2 := [Vector2(12, 12), Vector2(18, 12), Vector2(18, 18)]


## A mounted panel whose board declares a net + layers, with one staged zone
## and one staged cutout in its store. Returns {panel, data, store, zone, cutout}.
func _rig() -> Dictionary:
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	var data = panel.get_data()
	data.from_board_dict({
		"version": 1, "name": "draft", "width_mm": 30.0, "height_mm": 30.0,
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [], "nets": [{"name": "GND", "pins": []}],
		"traces": [], "vias": [],
	})
	var store = panel.get_staged_store()
	var zone: Dictionary = data.build_zone_payload("", "top", TRI, "keepout").get("payload", {})
	var cutout: Dictionary = data.build_cutout_payload(TRI2).get("payload", {})
	store.stage("zone", zone, "ai")
	store.stage("cutout", cutout, "ai")
	return {"panel": panel, "data": data, "store": store, "zone": zone, "cutout": cutout}


# ── 1. composer content: staged zones in, cutouts NEVER, input untouched ──────

func _run_composer_content() -> void:
	print("-- 1. composer: per-purpose content --")
	var rig := _rig()
	var board: Dictionary = rig["data"].to_board_dict()
	var zone_id := str(rig["zone"].get("id", ""))
	var base_zone_count: int = (board.get("zones", []) as Array).size()
	var base_cutout_count: int = (board.get("cutouts", []) as Array).size() \
		if board.get("cutouts", null) is Array else 0

	for purpose in ["route", "geometric"]:
		var composed: Dictionary = StagedEntities.effective_draft_board(board, rig["store"], purpose)
		var zones: Array = composed.get("zones", [])
		check_eq("[%s] one staged zone appended" % purpose, zones.size(), base_zone_count + 1)
		var appended: Dictionary = zones[zones.size() - 1]
		check_eq("[%s] …carrying its canonical minted id" % purpose,
			str(appended.get("id", "")), zone_id)
		check("[%s] …payload byte-identical to the staged dict" % purpose,
			str(appended) == str(rig["zone"]))
		var composed_cutouts: int = (composed.get("cutouts", []) as Array).size() \
			if composed.get("cutouts", null) is Array else 0
		check_eq("[%s] staged CUTOUT never composed (uncompilable doctrine)" % purpose,
			composed_cutouts, base_cutout_count)
	check_eq("input board dict never mutated by composition",
		(board.get("zones", []) as Array).size(), base_zone_count)

	# DELIBERATE SEMANTIC (DCR S3 "append staged ZONES only", ratified — no
	# kind filter): a staged copper POUR with a net composes as real,
	# connectable copper — a draft propose may route against an unaccepted
	# pour. Pinned so the surprise is on purpose (cold review st.3 F3).
	var pour: Dictionary = rig["data"].build_zone_payload("GND", "bottom", TRI2, "copper_pour").get("payload", {})
	rig["store"].stage("zone", pour, "ai")
	var with_pour: Dictionary = StagedEntities.effective_draft_board(board, rig["store"], "route")
	var pour_row: Dictionary = {}
	for z in (with_pour.get("zones", []) as Array):
		if str((z as Dictionary).get("id", "")) == str(pour.get("id", "")):
			pour_row = z
	check("a staged copper POUR composes (kind intact)",
		str(pour_row.get("kind", "")) == "copper_pour")
	check_eq("…with its net riding through (connectable copper, per DCR)",
		str(pour_row.get("net", "")), "GND")
	rig["store"].reject(rig["store"].staged_id_for_entity(str(pour.get("id", ""))))

	# Id-dedupe against the board's own zones (two-store drift: accept landed
	# but the sidecar restore revived the entry live-staged): the board's copy
	# wins, no duplicate ids in one request.
	var landed: Dictionary = rig["data"].add_zone_payload(rig["zone"])
	check("(fixture) the staged zone's twin lands on the board", not landed.is_empty())
	var board_with_twin: Dictionary = rig["data"].to_board_dict()
	var deduped: Dictionary = StagedEntities.effective_draft_board(board_with_twin, rig["store"], "route")
	var twin_count := 0
	for z in (deduped.get("zones", []) as Array):
		if str((z as Dictionary).get("id", "")) == zone_id:
			twin_count += 1
	check_eq("a staged zone whose id is already ON the board composes once (board wins)",
		twin_count, 1)

	# The composer reads LIVE entries only: a rejected zone leaves the union.
	rig["store"].reject(rig["store"].staged_id_for_entity(zone_id))
	var after: Dictionary = StagedEntities.effective_draft_board(board, rig["store"], "route")
	check_eq("a rejected zone leaves the composed board",
		(after.get("zones", []) as Array).size(), base_zone_count)

	# A board with NO zones key at all gains one (worker boards omit empties).
	var bare := {"version": 1, "name": "bare", "width_mm": 10.0, "height_mm": 10.0}
	var store2 = StagedEntities.new()
	store2.stage("zone", {"id": "zone:abc", "kind": "keepout", "layer": "top", "outline": []})
	var bare_composed: Dictionary = StagedEntities.effective_draft_board(bare, store2, "route")
	check_eq("zones key created when the board omitted it",
		(bare_composed.get("zones", []) as Array).size(), 1)
	rig["panel"].free()


# ── 1b. composer: staged placements move components (OFC-2, epoch 019ff9421d3f)

## A mounted panel whose board has two components and a net, with ONE staged
## placement (U1 → (20, 25) @ 90°) in its store. Returns {panel, data, store,
## placement}.
func _placement_rig() -> Dictionary:
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	var data = panel.get_data()
	data.from_board_dict({
		"version": 1, "name": "draft", "width_mm": 30.0, "height_mm": 30.0,
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "U1", "footprint": "", "x_mm": 5.0, "y_mm": 5.0,
				"rotation_deg": 0, "layer": "top",
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
			{"ref": "U2", "footprint": "", "x_mm": 25.0, "y_mm": 5.0,
				"rotation_deg": 0, "layer": "top",
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		],
		"nets": [{"name": "SIG", "pins": ["U1.1", "U2.1"]}],
		"traces": [{"id": "t1", "net": "SIG", "layer": "F.Cu", "width_mm": 0.3,
			"points": [{"x_mm": 5.0, "y_mm": 5.0}, {"x_mm": 25.0, "y_mm": 5.0}]}],
		"vias": [],
	})
	var store = panel.get_staged_store()
	var placement: Dictionary = data.build_placement_payload("U1", 20.0, 25.0, 90.0).get("payload", {})
	store.stage("placement", placement, "ai")
	return {"panel": panel, "data": data, "store": store, "placement": placement}


func _composed_comp(composed: Dictionary, ref: String) -> Dictionary:
	for c in (composed.get("components", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("ref", "")) == ref:
			return c
	return {}


func _run_composer_placements() -> void:
	print("-- 1b. composer: staged placements apply the ghost pose --")
	var rig := _placement_rig()
	var board: Dictionary = rig["data"].to_board_dict()

	# BOTH purposes get placements (OFC-2 decision, recorded at the site): a
	# route preview AND a DRC preview must judge copper at the proposed pose.
	for purpose in ["route", "geometric"]:
		var composed: Dictionary = StagedEntities.effective_draft_board(board, rig["store"], purpose)
		var u1: Dictionary = _composed_comp(composed, "U1")
		check_eq("[%s] U1 composes AT the ghost target x" % purpose, float(u1.get("x_mm", 0.0)), 20.0)
		check_eq("[%s] …target y" % purpose, float(u1.get("y_mm", 0.0)), 25.0)
		check_eq("[%s] …target rotation" % purpose, float(u1.get("rotation_deg", -1.0)), 90.0)
		var u2: Dictionary = _composed_comp(composed, "U2")
		check_eq("[%s] unproposed U2 stays put" % purpose, float(u2.get("x_mm", 0.0)), 25.0)
		# Flag-don't-fix rides the composition: copper never moves with the
		# ghost, so the preview honestly shows what the move would strand.
		var t: Dictionary = (composed.get("traces", []) as Array)[0]
		var t_start: Dictionary = (t.get("points", []) as Array)[0]
		check_eq("[%s] traces stay at REAL coordinates (flag-don't-fix)" % purpose,
			float(t_start.get("x_mm", -1.0)), 5.0)

	# Input never mutated: the real board dict still has U1 at its real pose.
	var real_u1: Dictionary = _composed_comp(board, "U1")
	check_eq("input board dict never mutated (U1 real pose intact)",
		float(real_u1.get("x_mm", 0.0)), 5.0)

	# Live-only: a rejected ghost stops composing.
	rig["store"].reject(rig["store"].staged_id_for_entity(str(rig["placement"].get("id", ""))))
	var after: Dictionary = StagedEntities.effective_draft_board(board, rig["store"], "route")
	check_eq("a rejected placement leaves the composed board (U1 back at real pose)",
		float(_composed_comp(after, "U1").get("x_mm", 0.0)), 5.0)

	# Two-store drift, placement flavor: a live ghost naming a component no
	# longer on the board composes NOTHING for that entry (skip + warn), and
	# the rest of the composition survives it.
	var ghost2: Dictionary = rig["data"].build_placement_payload("U2", 10.0, 10.0, 0.0).get("payload", {})
	rig["store"].stage("placement", ghost2, "ai")
	var orphan := {"id": "placement:deadbeef", "component_id": "GONE",
		"from": {"x_mm": 0.0, "y_mm": 0.0, "rotation_deg": 0.0},
		"to": {"x_mm": 1.0, "y_mm": 1.0, "rotation_deg": 0.0},
		"affected_nets": []}
	rig["store"].stage("placement", orphan, "ai")
	var mixed: Dictionary = StagedEntities.effective_draft_board(board, rig["store"], "route")
	check_eq("orphan placement (deleted component) composes nothing for itself — no invented component",
		(mixed.get("components", []) as Array).size(), 2)
	check_eq("…while the healthy ghost beside it still composes",
		float(_composed_comp(mixed, "U2").get("x_mm", 0.0)), 10.0)

	# Unknown purpose fail-safe covers placements too (same gate as zones).
	var unknown: Dictionary = StagedEntities.effective_draft_board(board, rig["store"], "promotion")
	check_eq("unknown purpose leaves components at real poses",
		float(_composed_comp(unknown, "U2").get("x_mm", 0.0)), 25.0)
	rig["panel"].free()


# ── 1c. candidate provenance + the commit gate (OFC-3) ────────────────────────

## One worker-shaped route landing at the ghost's target pad — the geometry is
## opaque to the gate; what matters is that it was generated DURING a live
## ghost.
func _sig_route_result() -> Dictionary:
	return {"success": true, "via_count": 0, "unrouted": [],
		"routes": [{"net": "SIG", "vias": [],
			"segments": [{"start": [20.0, 25.0], "end": [25.0, 5.0],
				"layer": "F.Cu", "width_mm": 0.3}]}]}


func _list_row(host_panel, cid: String) -> Dictionary:
	var reply: Dictionary = PanelTools._workspace_list(
		host_panel.get_annotation_host(), {"include_terminal": true})
	for row in (reply.get("candidates", []) as Array):
		if str((row as Dictionary).get("candidate_id", "")) == cid:
			return row
	return {}


func _ghost_status(row: Dictionary) -> String:
	var dp: Array = row.get("draft_placements", [])
	if dp.is_empty():
		return "(absent)"
	return str((dp[0] as Dictionary).get("status", ""))


## The compose-time capture route_board performs (F1) — the harness twin, one
## derivation with production via _live_placement_snapshot.
func _compose_context(data, host) -> Dictionary:
	return {"board_revision": int(data.board_revision),
		"draft_placements": PanelTools._live_placement_snapshot(host)}


func _first_candidate(ingest_reply: Dictionary) -> Dictionary:
	var rows: Array = (ingest_reply.get("result", {}) as Dictionary).get("candidates", []) \
		if ingest_reply.get("result", null) is Dictionary else ingest_reply.get("candidates", [])
	return rows[0] if rows.size() > 0 else {}


func _run_candidate_placement_provenance() -> void:
	print("-- 1c. candidate draft-placement provenance + commit gate --")
	var rig := _placement_rig()
	var panel = rig["panel"]
	var host = panel.get_annotation_host()
	var workspace = panel.get_routing_workspace()
	var data = rig["data"]
	var store = rig["store"]
	var ghost: Dictionary = rig["placement"]
	var ghost_id := str(ghost.get("id", ""))
	var sid := str(store.staged_id_for_entity(ghost_id))

	# (a) ingest while the ghost is live → provenance stamped, status pending.
	# F1 (Codex 1188): provenance rides the COMPOSE-TIME draft_context that
	# route_board captures atomically with the request and attaches to its
	# reply — this harness plays route_board's part. Ingest never re-samples.
	var ctx := _compose_context(data, host)
	var ingest: Dictionary = await PanelTools._ingest_result_into_workspace(
		host, workspace, data, _sig_route_result(), [], {}, ctx)
	var landed: Array = (ingest.get("result", {}) as Dictionary).get("candidates", []) \
		if ingest.get("result", null) is Dictionary else ingest.get("candidates", [])
	check_eq("(fixture) one candidate landed", landed.size(), 1)
	var cand_row: Dictionary = landed[0] if landed.size() > 0 else {}
	var cid := str(cand_row.get("candidate_id", ""))
	var dp: Array = cand_row.get("draft_placements", [])
	check_eq("ingest reply row carries the ghost dependency", dp.size(), 1)
	check_eq("…by ghost entity id", str((dp[0] as Dictionary).get("id", "")) if dp.size() > 0 else "", ghost_id)
	check_eq("…status pending at generation", _ghost_status(cand_row), "pending")
	check_eq("…and it is DURABLE candidate state (listing agrees)",
		_ghost_status(_list_row(panel, cid)), "pending")

	# (b) commit refuses while the dependency is pending; no copper lands.
	var traces_before: int = data.get_trace_count()
	var refusal: Dictionary = await PanelTools._workspace_commit(host, {"candidate_id": cid})
	check_eq("commit refused while the move is unaccepted",
		bool(refusal.get("success", true)), false)
	check_eq("…by name", str(refusal.get("error", "")), "draft_placement_pending")
	check_eq("…and no copper landed", data.get_trace_count(), traces_before)

	# (c) retargeting the ghost invalidates the candidate's world.
	check("(fixture) ghost retargets to (22, 25)",
		store.update_placement_target(sid, 22.0, 25.0, 90.0))
	check_eq("listing derives invalidated after retarget",
		_ghost_status(_list_row(panel, cid)), "invalidated")
	var refusal2: Dictionary = await PanelTools._workspace_commit(host, {"candidate_id": cid})
	check_eq("commit refuses invalidated by name",
		str(refusal2.get("error", "")), "draft_placement_invalidated")

	# (d) retargeting BACK restores pending — derived, not latched.
	check("(fixture) ghost retargets back to (20, 25)",
		store.update_placement_target(sid, 20.0, 25.0, 90.0))
	check_eq("status derives pending again (no sticky invalidation)",
		_ghost_status(_list_row(panel, cid)), "pending")

	# (e) the move LANDS → dependency satisfied → commit proceeds.
	check("(fixture) the move lands on the board",
		not data.add_placement_payload(ghost).is_empty())
	check_eq("status derives satisfied once the component sits at the target",
		_ghost_status(_list_row(panel, cid)), "satisfied")
	var committed: Dictionary = await PanelTools._workspace_commit(host, {"candidate_id": cid})
	check_eq("commit now succeeds", bool(committed.get("success", false)), true)
	check_eq("…and the copper landed", data.get_trace_count(), traces_before + 1)

	# (f) provenance survives candidate serialization (sidecar round-trip).
	var cobj = workspace.get_candidate(cid)
	var reloaded = RouteCandidate.from_dict(cobj.to_dict())
	check_eq("draft_placements round-trips through to_dict/from_dict",
		str(reloaded.draft_placements), str(cobj.draft_placements))

	# (g) no ghost live at generation → no provenance key at all (legacy shape).
	store.reject(sid)
	var ingest2: Dictionary = await PanelTools._ingest_result_into_workspace(
		host, workspace, data, _sig_route_result(), [], {}, _compose_context(data, host))
	var landed2: Array = (ingest2.get("result", {}) as Dictionary).get("candidates", []) \
		if ingest2.get("result", null) is Dictionary else ingest2.get("candidates", [])
	check("a ghost-free ingest carries NO draft_placements key (absent, not empty)",
		landed2.size() == 1 and not (landed2[0] as Dictionary).has("draft_placements"))

	# ── F1 race seams (Codex 1188): the store changes BETWEEN compose and
	# ingest — provenance must describe the world that was ROUTED, and the
	# derived status must judge it against the world that IS.
	# (h) ghost rejected mid-flight: the candidate still carries the routed
	# ghost, now invalidated — commit refuses instead of landing wrong-pose
	# copper.
	var ghost_h: Dictionary = data.build_placement_payload("U1", 5.0, 5.0, 0.0).get("payload", {})
	store.stage("placement", ghost_h, "ai")
	var ctx_h := _compose_context(data, host)
	store.reject(store.staged_id_for_entity(str(ghost_h.get("id", ""))))
	var ingest_h: Dictionary = await PanelTools._ingest_result_into_workspace(
		host, workspace, data, _sig_route_result(), [], {}, ctx_h)
	var row_h: Dictionary = _first_candidate(ingest_h)
	check_eq("mid-flight REJECT: provenance survives with status invalidated",
		_ghost_status(row_h), "invalidated")
	var commit_h: Dictionary = await PanelTools._workspace_commit(
		host, {"candidate_id": str(row_h.get("candidate_id", ""))})
	check_eq("…and commit refuses it", str(commit_h.get("error", "")), "draft_placement_invalidated")

	# (i) ghost retargeted A→B mid-flight: copper routed at A must NOT read
	# satisfied-by-B — the provenance pins A, the live ghost says B.
	var ghost_i: Dictionary = data.build_placement_payload("U1", 8.0, 8.0, 0.0).get("payload", {})
	store.stage("placement", ghost_i, "ai")
	var sid_i := str(store.staged_id_for_entity(str(ghost_i.get("id", ""))))
	var ctx_i := _compose_context(data, host)
	store.update_placement_target(sid_i, 9.0, 9.0, 0.0)
	var ingest_i: Dictionary = await PanelTools._ingest_result_into_workspace(
		host, workspace, data, _sig_route_result(), [], {}, ctx_i)
	check_eq("mid-flight RETARGET: candidate pins the ROUTED pose, now invalidated",
		_ghost_status(_first_candidate(ingest_i)), "invalidated")
	store.reject(sid_i)

	# (j) ghost staged mid-flight: the request was composed ghost-free, so the
	# candidate carries NO provenance — a ghost that played no part in the
	# routing must not be attributed to it.
	var ctx_j := _compose_context(data, host)
	var ghost_j: Dictionary = data.build_placement_payload("U2", 12.0, 12.0, 0.0).get("payload", {})
	store.stage("placement", ghost_j, "ai")
	var ingest_j: Dictionary = await PanelTools._ingest_result_into_workspace(
		host, workspace, data, _sig_route_result(), [], {}, ctx_j)
	check("mid-flight NEW GHOST: the ghost-free request's candidate stays provenance-free",
		not _first_candidate(ingest_j).has("draft_placements"))
	panel.free()


# ── 1d. board_check: the promote gate's read-only twin (OFC-4) ────────────────

## Fake "_MinervaIPC": captures the panel's request emission and answers the
## next await_reply with a canned worker verdict — the same seam idiom the
## refine-loop suite's broker fakes use, narrowed to one round-trip.
class FakeGateIPC extends Node:
	var verdict: Dictionary = {}
	var captured_channel := ""
	var captured_payload: Dictionary = {}
	var _reply_id := ""
	## F3 race seam: when set, the board "edits itself" while the worker is
	## replying — the revision bumps between snapshot and verdict.
	var bump_mid_flight = null

	func bind(panel_node) -> void:
		name = "_MinervaIPC"
		panel_node.add_child(self)
		panel_node.request.connect(_on_request)

	func _on_request(channel: String, payload: Dictionary, reply_id: String) -> void:
		captured_channel = channel
		captured_payload = payload
		_reply_id = reply_id

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id:
			return {"success": false, "error_code": "timeout", "error_message": "no captured request"}
		if bump_mid_flight != null:
			bump_mid_flight.board_revision += 1
		return {"success": true, "result": {"ok": true, "result": verdict.duplicate(true)}}


func _run_board_check_census() -> void:
	print("-- 1d. board_check: read-only census, no write, no gate --")
	var rig := _placement_rig()
	var panel = rig["panel"]
	var host = panel.get_annotation_host()

	# (a) dispatch + the no-backend guard: the verb is reachable by name and
	# refuses honestly without a worker (fail closed, never a fake census).
	var no_ipc: Dictionary = await PanelTools.handle(host, "minerva_pcb_board_check", {})
	check_eq("without a backend the census refuses", bool(no_ipc.get("success", true)), false)
	check_eq("…by name", str(no_ipc.get("error", "")), "worker_unavailable")

	# (b) a gated verdict passes through VERBATIM, labeled as a report.
	var ipc := FakeGateIPC.new()
	ipc.bind(panel)
	ipc.verdict = {
		"promotable": false,
		"refusals": ["connectivity DRC reports 2 finding(s)"],
		"connectivity": {"findings": [
			{"type": "dangling_endpoint", "net": "SIG", "at": [25.0, 5.0]},
			{"type": "crossing", "nets": ["SIG", "GND"], "at": [15.0, 15.0]}],
			"complete": false, "missing_copper": ["SIG"]},
		"geometric": {"verdict": "clean"},
		"assembly": {"status": "findings", "findings": [{"ref": "U1", "kind": "courtyard"}]},
		"advisory": {"completeness": {"complete": false, "missing_copper": ["SIG"]}},
	}
	var census: Dictionary = await PanelTools.handle(host, "minerva_pcb_board_check", {})
	check_eq("the census itself SUCCEEDS while reporting a would-be refusal",
		bool(census.get("success", false)), true)
	check_eq("…the worker channel is the promote gate's own",
		ipc.captured_channel, "pcb.promote_check")
	check_eq("…promotable rides verbatim", bool(census.get("promotable", true)), false)
	check_eq("…refusals ride verbatim", (census.get("refusals", []) as Array).size(), 1)
	check_eq("…connectivity findings carry coordinates",
		str(((census.get("connectivity", {}) as Dictionary).get("findings", []) as Array)[0].get("at", [])),
		str([25.0, 5.0]))
	check("…advisory present when the worker sent one", census.has("advisory"))
	check("…and the note says read-only", str(census.get("note", "")).contains("read-only"))
	# F3 (Codex 1188): the reply names the revision the verdict describes.
	check_eq("…and names the checked board revision",
		int(census.get("board_revision", -1)), int(rig["data"].board_revision))
	# F4 (Codex 1188): the census feeds the assembly cache workspace_commit's
	# placement gate consults — fresh findings become gate state, not trivia.
	check("the census fed the assembly cache (commit's gate now sees these findings)",
		not panel.get_assembly_state().is_empty())
	# K2 hygiene rides the census's snapshot too: the request board must not
	# carry render-detail residue.
	var sent_board: Dictionary = ipc.captured_payload.get("board", {})
	var first_comp: Dictionary = (sent_board.get("components", []) as Array)[0]
	check("census request board is K2-stripped (no render-detail keys)",
		not first_comp.has("width") and not first_comp.has("local_bounds"))
	# Parity, F5-narrowed (Codex 1188): ONLY the dangling_endpoint finding is
	# markered — the crossing rides the reply but must not be painted in the
	# disconnect vocabulary. (One check either way if this headless mount has
	# no canvas, so the assertion count stays pinned.)
	var canvas = panel._canvas
	check("exactly the dangling_endpoint finding became a marker (crossing did NOT; or no canvas headless)",
		canvas == null or ((canvas._disconnect_markers as Array).size() == 1
			and str(((canvas._disconnect_markers as Array)[0] as Dictionary).get("message", "")).contains("dangling")))

	# (c) a clean verdict reports promotable and clears the markers.
	ipc.verdict = {"promotable": true, "refusals": [],
		"connectivity": {"findings": [], "complete": true},
		"geometric": {"verdict": "clean"},
		"assembly": {"status": "pass", "findings": []}}
	var clean: Dictionary = await PanelTools.handle(host, "minerva_pcb_board_check", {})
	check_eq("a clean census reports promotable", bool(clean.get("promotable", false)), true)
	check("…refusals empty", (clean.get("refusals", []) as Array).is_empty())
	check("…and healed markers clear (or no canvas headless)",
		canvas == null or (canvas._disconnect_markers as Array).is_empty())

	# (d) F3 (Codex 1188): the board changes while the worker replies — the
	# census must refuse as stale and touch NOTHING.
	var markers_before: int = (canvas._disconnect_markers as Array).size() if canvas != null else -1
	ipc.bump_mid_flight = rig["data"]
	ipc.verdict = {"promotable": false, "refusals": ["connectivity DRC reports 1 finding(s)"],
		"connectivity": {"findings": [
			{"type": "dangling_endpoint", "net": "SIG", "at": [1.0, 1.0]}], "complete": false},
		"geometric": {"verdict": "clean"},
		"assembly": {"status": "pass", "findings": []}}
	var stale: Dictionary = await PanelTools.handle(host, "minerva_pcb_board_check", {})
	ipc.bump_mid_flight = null
	check_eq("a mid-flight board edit makes the census refuse", str(stale.get("error", "")), "stale_census")
	check("…naming both revisions",
		stale.has("checked_board_revision") and stale.has("current_board_revision")
			and int(stale.get("current_board_revision", -1)) > int(stale.get("checked_board_revision", -1)))
	check("…and the stale verdict painted NO markers (or no canvas headless)",
		canvas == null or (canvas._disconnect_markers as Array).size() == markers_before)
	panel.free()


# ── 2. composer fail-safe: unknown purpose / absent store compose NOTHING ─────

func _run_composer_fail_safe() -> void:
	print("-- 2. composer: fail-safe direction (drafts omitted, never leaked) --")
	var rig := _rig()
	var board: Dictionary = rig["data"].to_board_dict()
	var base: int = (board.get("zones", []) as Array).size()

	var unknown: Dictionary = StagedEntities.effective_draft_board(board, rig["store"], "promotion")
	check_eq("unknown purpose composes NOTHING (drafts must never leak)",
		(unknown.get("zones", []) as Array).size(), base)
	check("…but still hands back a usable board copy",
		unknown.has("nets") and str(unknown.get("name", "")) == "draft")

	var nulled: Dictionary = StagedEntities.effective_draft_board(board, null, "route")
	check_eq("null store composes nothing", (nulled.get("zones", []) as Array).size(), base)

	var duckless: Dictionary = StagedEntities.effective_draft_board(board, RefCounted.new(), "route")
	check_eq("a store without staged_payloads composes nothing (duck-typed)",
		(duckless.get("zones", []) as Array).size(), base)
	rig["panel"].free()


# ── 3. the panel's request-board decision (route_board's board source) ────────

func _run_panel_request_board() -> void:
	print("-- 3. _board_for_route_request: draft marker composes, absence doesn't --")
	var rig := _rig()
	var panel = rig["panel"]
	var zone_id := str(rig["zone"].get("id", ""))

	var real: Dictionary = panel._board_for_route_request({})
	check_eq("no marker → the REAL board (no staged content)",
		(real.get("zones", []) as Array).size(), 0)

	var draft: Dictionary = panel._board_for_route_request({"draft_request": true})
	var zones: Array = draft.get("zones", [])
	check_eq("draft_request → composed board carries the staged zone", zones.size(), 1)
	check_eq("…by canonical id", str((zones[0] as Dictionary).get("id", "")), zone_id)
	var cutouts: int = (draft.get("cutouts", []) as Array).size() \
		if draft.get("cutouts", null) is Array else 0
	check_eq("…and NO staged cutout ever enters a route request (A2)", cutouts, 0)

	check_eq("a false marker behaves as absent",
		(panel._board_for_route_request({"draft_request": false}).get("zones", []) as Array).size(), 0)
	panel.free()


# ── 4. reply-side isolation: draft health labeled, cache never fed (A9) ───────

func _run_reply_cache_isolation() -> void:
	print("-- 4. _attach_board_health: draft label + assembly-cache isolation --")
	var rig := _rig()
	var panel = rig["panel"]
	var host = panel.get_annotation_host()
	# A worker-shaped route result carrying board_health with an assembly
	# verdict — the exact object _feed_assembly_cache would cache.
	var result := {
		"routes": [],
		"board_health": {
			"complete": false,
			"assembly": {"status": "pass", "findings": []},
		},
	}

	check("assembly cache starts empty", panel.get_assembly_state().is_empty())

	# THE DRAFT CONSUMER (apply_route_hints commit=false): real function, real
	# panel — health surfaces LABELED, cache stays untouched.
	var draft_reply: Dictionary = PanelTools._propose_into_workspace(host, rig["data"], result, [])
	var draft_health: Dictionary = (draft_reply.get("result", {}) as Dictionary).get("board_health", {}) \
		if draft_reply.get("result", null) is Dictionary else draft_reply.get("board_health", {})
	check("draft reply still SURFACES board_health (advisory, not hidden)",
		not draft_health.is_empty())
	check_eq("…labeled draft", bool(draft_health.get("draft", false)), true)
	check("…and the assembly cache was NOT fed (A9: composed-board verdict never keyed to the real board)",
		panel.get_assembly_state().is_empty())

	# THE PRIMARY DRAFT CONSUMER (workspace propose + both reroutes —
	# _ingest_result_into_workspace, cold review st.3 F1): same isolation
	# contract, pinned on the real function so a reverted `true` at its
	# _attach_board_health site cannot stay green.
	var ingest_reply: Dictionary = await PanelTools._ingest_result_into_workspace(
		host, panel.get_routing_workspace(), rig["data"], result, [], {})
	var ingest_health: Dictionary = (ingest_reply.get("result", {}) as Dictionary).get("board_health", {}) \
		if ingest_reply.get("result", null) is Dictionary else ingest_reply.get("board_health", {})
	check("propose/reroute ingest reply surfaces board_health", not ingest_health.is_empty())
	check_eq("…labeled draft", bool(ingest_health.get("draft", false)), true)
	check("…and the cache is STILL untouched", panel.get_assembly_state().is_empty())

	# THE DIRECT CONSUMER (commit=true): same result shape — cache IS fed.
	var direct_reply: Dictionary = PanelTools._materialize_routes(host, rig["data"], result, [])
	var direct_health: Dictionary = (direct_reply.get("result", {}) as Dictionary).get("board_health", {}) \
		if direct_reply.get("result", null) is Dictionary else direct_reply.get("board_health", {})
	check("direct reply carries board_health", not direct_health.is_empty())
	check_eq("…UNlabeled (computed from the real board)",
		draft_health.has("draft") and not direct_health.has("draft"), true)
	check("…and the assembly cache WAS fed (direct copper keeps the shipped contract)",
		not panel.get_assembly_state().is_empty())
	panel.free()
