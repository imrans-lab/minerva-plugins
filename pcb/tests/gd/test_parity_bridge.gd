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
## drives production seams. No fakes; only the router worker hop is
## substituted by a fixture reply (worker *.py is out of fence).
##
## S5 UPDATE (C4b, DCR 019f7095c395): panel_tools._dual_write_propose /
## _proposal_accept / _proposal_reject are RETIRED — PROPOSE now lands a
## workspace candidate ONLY (_propose_into_workspace), never a correlated
## annotation, so production code can no longer CONSTRUCT the bridged
## (annotation ↔ candidate) state this suite exercises. The bridge MODEL
## machinery itself (RoutingWorkspace.correlate/candidate_for_annotation/
## annotation_for_candidate/is_candidate_bridged/is_annotation_bridged, and
## _add_via's bridged-sync via sync_candidate_geometry) is UNTOUCHED and
## out of this round's fence (pcb_routing_workspace.gd) — dormant,
## forward-compatible capability, not deleted. Group 3's "accept" step and
## group 5's "undo after accept" step move onto the NEW production path,
## minerva_pcb_workspace_commit, which is what an agent/human actually calls
## now. is_annotation_superseded is ALSO retired (nothing supersedes a hint
## anymore) — the two assertions that exercised it are removed, not ported.
##
## BOUNDARY POLISH (epoch C, oracle-integrity F2 — correlate() has zero
## production callers): groups 1 and 2 hand-built the bridged state via
## ingest_record + correlate() only to re-assert geometry test_workspace_ingest.gd
## already pins directly (group 1) or to replay two primitives glued together
## only by test code (group 2) — both retired; see the comments at their old
## positions below for the full disposition. Group 4 is KEPT as dormant-
## capability coverage of _add_via's bridged sync — it still exercises real,
## compiling, forward-compatible code, just not a reachable production path
## today. Group 5 no longer calls correlate() at all: it never read the
## correlated annotation id, so its setup was rebuilt (_committed_candidate_context)
## to mint only the candidate + source-hint state the group's assertions
## actually use.
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
## `hint_ids` mirrors the worker's own per-route attribution stamp (docket
## 019f9c3a136c, methods.py _hint_ids_by_net) — a real worker always sets this
## key on every route once ANY hint was supplied, so a caller simulating "a
## hint was supplied" must stamp it too, or panel_tools._route_hint_ids
## (correctly) reads an unstamped route as "nothing answered this".
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


## A REAL source-hint annotation stored on the host + a propose-shaped source_hints
## array referencing its real id (so the hand-built proposal's proposal_for
## links a live annotation). Returns [hint_id, source_hints].
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


## Boot a real PCBPanel + host wired with the panel back-reference, and
## HAND-BUILD a bridged pair (proposal-shaped annotation + correlated
## candidate) exactly the shape the now-retired _dual_write_propose used to
## produce — production can no longer construct this state (S5), but the
## model-level bridge machinery that CONSUMES it is untouched, so this
## reproduces its precondition directly instead of routing it through a
## deleted function. Returns a context dict with the driver, panel, host,
## workspace, the source hint id, and the bridged {ann_id, cand_id}.
func _bridged_context() -> Dictionary:
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var ws = panel.get_routing_workspace()

	var seeded := _seed_source_hint(host)
	var hint_id: String = seeded[0]
	var source_hints: Array = seeded[1]

	var records: Array = PanelTools._normalize_route_records(_multipad_reply([hint_id]), source_hints)
	check("fixture normalizes to exactly one record", records.size() == 1)
	var rec: Dictionary = records[0]
	var pts: Array = rec.get("polyline", [])
	var first: Array = pts[0]
	var envelope: Dictionary = host.build_route_hint_envelope(
		float(first[0]), float(first[1]), "", str(rec.get("layer", "F.Cu")), "single_trace", pts, "ai")
	var kp: Dictionary = envelope.get("kind_payload", {})
	kp["net_names"] = [str(rec.get("net", ""))]
	kp["proposal_for"] = rec.get("source_hint_ids", [])
	kp["segments"] = (rec.get("segments", []) as Array).duplicate(true)
	kp["vias"] = (rec.get("vias", []) as Array).duplicate(true)
	envelope["kind_payload"] = kp
	var ann_id := str(host.add_annotation_v2(envelope))

	var cand_id := str(ws.ingest_record(rec, int(panel.get_data().board_revision)))
	if not cand_id.is_empty():
		var cand = ws.get_candidate(cand_id)
		ws.correlate(cand_id, ann_id, str(cand.task_id) if cand != null else "",
			int(cand.generation) if cand != null else 0)

	return {
		"driver": driver, "panel": panel, "host": host, "ws": ws,
		"hint_id": hint_id, "ann_id": ann_id, "cand_id": cand_id,
	}


## Boot a real PCBPanel + host and mint a workspace candidate carrying a real
## source-hint attribution — WITHOUT the bridge/correlate() machinery
## _bridged_context() builds. Group 5 (undo-after-commit) never reads ann_id
## or any correlation lookup; it only needs a candidate whose source_hint_ids
## resolves to a real hint so minerva_pcb_workspace_commit has a lifecycle to
## close. Routing that through correlate() (boundary polish, epoch C: dropped
## per oracle-integrity F2, correlate() has zero production callers) only
## obscured which state the group's assertions actually depend on — this
## builds exactly that state directly. Returns a context dict with the
## driver, panel, host, workspace, the source hint id, and the candidate id.
func _committed_candidate_context() -> Dictionary:
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var ws = panel.get_routing_workspace()

	var seeded := _seed_source_hint(host)
	var hint_id: String = seeded[0]
	var source_hints: Array = seeded[1]

	var records: Array = PanelTools._normalize_route_records(_multipad_reply([hint_id]), source_hints)
	check("fixture normalizes to exactly one record", records.size() == 1)
	var rec: Dictionary = records[0]
	var cand_id := str(ws.ingest_record(rec, int(panel.get_data().board_revision)))

	return {
		"driver": driver, "panel": panel, "host": host, "ws": ws,
		"hint_id": hint_id, "cand_id": cand_id,
	}


# ── 1. RETIRED (boundary polish, epoch C) ──────────────────────────────────────
#
# _run_ingest_correlation used to prove two things: (a) raw ingest geometry
# (segment count/layers/disconnection/via position) and (b) the bidirectional
# correlate() bridge (candidate_for_annotation / annotation_for_candidate /
# is_candidate_bridged / is_annotation_bridged). Half (b) is the dormant
# correlation machinery named in oracle-integrity F2 (correlate() has ZERO
# production callers — grep --include=*.gd, excluding tests) and is dropped
# here rather than kept as coverage nothing production can construct. Half
# (a) is not unique: test_workspace_ingest.gd::_run_ingest_geometry drives
# the IDENTICAL fixture (same net "N1", same three segments, same via at
# (5,0)) straight through PcbRoutingWorkspace.ingest_routing_result and
# already pins segment count == 3, per-segment canonical layers, the seg-2
# disconnection (INV-3), via position, and via layer span. Nothing survives
# rewriting here that test_workspace_ingest.gd does not already assert more
# directly (no panel, no hand-built annotation) — so the group is folded
# into this comment rather than kept as a weaker duplicate. See
# pcb/tests/gd/test_workspace_ingest.gd:122 for the live proof.


# ── 2. RETIRED (boundary polish, epoch C) ──────────────────────────────────────
#
# _run_reject_bridge hand-ran the two calls the retired _proposal_reject tool
# used to make internally (host.remove_annotation(ann_id) then
# ws.reject(cand_id)) — its own doc comment said as much: "hand-run them
# directly since the tool body is gone." With S5's dual-write removed,
# nothing in production wires those two primitives together anymore, so the
# group was two independently-correct calls glued only by test code, not a
# proof of any production seam. Retired rather than kept as a test asserting
# its own hand-authored sequence. host.remove_annotation and
# PcbRoutingWorkspace.reject remain covered individually by their owning
# suites (annotation lifecycle tests, test_routing_workspace_v2.gd's
# disposition-transition matrix).


# ── 3. commit-via-bridge: committed + stable trace/via ids survive reload ──────
#
# S5 (C4b): the retired _proposal_accept is replaced by the production path
# an agent/human actually calls now, minerva_pcb_workspace_commit(candidate_id)
# — a board+disposition transaction that does NOT DELETE the correlated
# proposal annotation OR the real source hint (unlike the retired
# _proposal_accept, which deleted both). MF-2 (review, owner-ratified HITL-2):
# the RoutingWorkspace MODEL still has no reference to the annotation host
# (unchanged), but the panel_tools.gd TOOL LAYER does, and _workspace_commit
# uses it to close the source-hint lifecycle — open→applied — as its half of
# the composite transaction. The STABLE-ids-survive-reload concern under test
# is unchanged either way.

func _run_accept_bridge_stable_ids() -> void:
	print("-- 3. commit-via-bridge: committed + STABLE ids survive to_board_dict/reload --")
	var ctx := _bridged_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var panel = ctx["panel"]
	var ann_id: String = ctx["ann_id"]
	var cand_id: String = ctx["cand_id"]
	var hint_id: String = ctx["hint_id"]

	var res: Dictionary = PanelTools._workspace_commit(host, {"candidate_id": cand_id})
	check("commit succeeds", bool(res.get("success", false)))
	check_eq("commit reports the same candidate_id", str(res.get("candidate_id", "")), cand_id)

	# Candidate committed → left the live set (commit cannot leave it live).
	check_eq("candidate disposition == committed", ws.get_candidate(cand_id).disposition, "committed")
	check("candidate NOT in live set after commit", not (cand_id in ws.live_candidate_ids()))
	# The bridged PROPOSAL annotation (ann_id) is not itself named in
	# consumed_hint_ids (that names the REAL source hint, hint_id) — it
	# survives untouched either way, since nothing ever deletes it.
	check("bridged proposal annotation left untouched by commit", not host.get_by_id(ann_id).is_empty())
	# MF-2: the REAL source hint's lifecycle closes — open -> applied, not deleted.
	var hint_after_commit: Dictionary = host.get_by_id(hint_id)
	check("bridged source hint SURVIVES commit (not deleted)", not hint_after_commit.is_empty())
	check_eq("bridged source hint lifecycle closed: open -> applied",
		str(hint_after_commit.get("lifecycle", "")), "applied")

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


# ── 4. DORMANT-CAPABILITY COVERAGE: _add_via's bridged sync ────────────────────
#
# Per oracle-integrity F2, correlate() (and everything downstream of it —
# is_candidate_bridged / annotation_for_candidate / the bridged-sync branch at
# panel_tools.gd:1377-1383) has ZERO production callers today: S5 retired the
# only path that ever CONSTRUCTED a correlated pair. This group is KEPT, not
# because production can reach it now, but because the bridged-sync code
# itself (PanelTools._add_via re-deriving BOTH the workspace candidate and the
# correlated annotation's kind_payload on a route-through) still exists,
# compiles, and is forward-compatible — a future caller of correlate() would
# inherit this behaviour, and this is the only suite that exercises it. Treat
# it as coverage of dormant capability, not of a reachable production path.

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
	var ctx := _committed_candidate_context()
	var host = ctx["host"]
	var ws = ctx["ws"]
	var panel = ctx["panel"]
	var data = panel.get_data()
	var cand_id: String = ctx["cand_id"]
	var hint_id: String = ctx["hint_id"]

	# S5: minerva_pcb_workspace_commit replaces the retired _proposal_accept —
	# same board+disposition transaction, same GATE INV-1 undo concern.
	PanelTools._workspace_commit(host, {"candidate_id": cand_id})
	check("board has traces after commit", data.traces.size() >= 1)
	check("board has vias after commit", data.vias.size() == 1)
	check_eq("candidate committed after commit", ws.get_candidate(cand_id).disposition, "committed")
	check_eq("MF-2: source hint lifecycle closed by commit: open -> applied",
		str(host.get_by_id(hint_id).get("lifecycle", "")), "applied")

	# MF-2, THE OTHER HALF OF THE ORPHAN CRITERION (chore 019fc36555d3, D0-2):
	# the assertion further down proves the reconciler REOPENS a stranded hint.
	# On its own that is only half a pin — a reconciler that reopened EVERY
	# applied hint unconditionally (drop the `committed_hint_ids.has(hid)` test
	# in _reconcile_hint_lifecycle and reopen in all cases) also satisfies it,
	# and was measured to leave every workspace/parity suite green. That
	# over-reconciliation is not benign: it is the "duplicate copper" failure
	# mode running the OTHER direction — a hint whose candidate is committed
	# and live on the board flips back to "open", so the next propose treats
	# it as unanswered and lands a second candidate for copper that already
	# exists. So pin the negative case at the one moment it is observable:
	# candidate STILL committed (no undo yet), run a workspace verb — which
	# resolves through _workspace_ctx and therefore fires the reconciler — and
	# the hint must be left exactly where commit put it.
	PanelTools._workspace_list(host, {})
	check_eq("hint STAYS 'applied' when its candidate is still committed (reconciler reopens ONLY orphans)",
		str(host.get_by_id(hint_id).get("lifecycle", "")), "applied")
	check_eq("the still-committed candidate is untouched by the reconciler",
		ws.get_candidate(cand_id).disposition, "committed")

	# Board-level undo of the accept: F1 restores traces AND vias together.
	var undone: bool = data.undo()
	check("data.undo() reports success", undone)
	check_eq("undo removed all traces", data.traces.size(), 0)
	# GATE INV-1: vias are NOT orphaned — they came back to the pre-accept count
	# (0) in lockstep with the traces, never left dangling.
	check_eq("undo removed all vias (not orphaned)", data.vias.size(), 0)

	# S5 CONTRACT CHANGE (moved pin, rationale): minerva_pcb_workspace_commit IS
	# INV-1's composite transaction — commit() pairs a PRE-commit disposition
	# snapshot onto the board's OWN history entry (pcb_data.gd bucket 8), so
	# data.undo() above ALREADY restores the candidate's disposition in
	# lockstep with the board — no separate ws.uncommit() call is needed. The
	# retired _proposal_accept went through mark_committed() directly (not the
	# INV-1 batch), which is why the pre-S5 version of this test called
	# ws.uncommit() by hand afterward; under the new path that call is not
	# merely redundant, it now REFUSES (the candidate is no longer "committed"
	# by the time undo has already reverted it) — asserted explicitly below.
	check_eq("candidate disposition restored to proposed BY data.undo() alone",
		ws.get_candidate(cand_id).disposition, "proposed")
	check("candidate live again after undo (no manual uncommit needed)",
		cand_id in ws.live_candidate_ids())
	var after: Dictionary = ws.committed_copper_ids(cand_id)
	check_eq("committed trace ids cleared", (after.get("trace_ids", []) as Array).size(), 0)
	check_eq("committed via ids cleared", (after.get("via_ids", []) as Array).size(), 0)
	check("a stray ws.uncommit() now correctly refuses (already proposed, not committed)",
		not ws.uncommit(cand_id))

	# MF-2 undo-coherence, demonstrated end to end: the hint lifecycle CANNOT
	# ride this same board-history undo (a separate store — see
	# _reconcile_hint_lifecycle's doc) — it is REAL, not hypothetical: right
	# after data.undo() above, the hint is STILL "applied" even though its
	# candidate is already back to "proposed". The compensating half is lazy:
	# it fires the next time ANY workspace tool resolves through
	# _workspace_ctx — proven here with a read-only one (_workspace_list),
	# which must not require its OWN candidate_id/mutation to trigger it.
	check_eq("hint STAYS applied immediately after undo (the gap is real)",
		str(host.get_by_id(hint_id).get("lifecycle", "")), "applied")
	PanelTools._workspace_list(host, {})
	check_eq("hint REOPENS to 'open' the next time any workspace tool runs (compensating half)",
		str(host.get_by_id(hint_id).get("lifecycle", "")), "open")

	# THE CLOSING DIRECTION (Epoch UX2 station 1, cold review F3): redo
	# re-commits the candidate through the same board-history bucket — and
	# just like undo, it never touches the annotation store. Without the
	# reconciler's closing half the hint would stay "open" forever over real
	# committed copper: it would re-ink its full corridor over the traces
	# (the exact leak class station 1's invariant rules out) and the next
	# propose would re-gather it (duplicate copper). Pin the gap AND the heal.
	var redone: bool = data.redo()
	check("data.redo() reports success", redone)
	check("redo restored the traces", data.traces.size() >= 1)
	check_eq("candidate disposition restored to committed BY data.redo() alone",
		ws.get_candidate(cand_id).disposition, "committed")
	check_eq("hint STAYS open immediately after redo (the gap is real, other direction)",
		str(host.get_by_id(hint_id).get("lifecycle", "")), "open")
	PanelTools._workspace_list(host, {})
	check_eq("hint RE-CLOSES to 'applied' the next time any workspace tool runs (closing half)",
		str(host.get_by_id(hint_id).get("lifecycle", "")), "applied")

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
