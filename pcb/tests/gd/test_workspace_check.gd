extends SceneTree
## T2.4 — RoutingWorkspace draft-check STATE MACHINE tests (IPC-decoupled).
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_workspace_check.gd
## Same preload/run convention as test_workspace_ingest.gd.
##
## Coverage:
##   1. begin_check flips the targets to "checking" and returns a payload carrying
##      board_token + workspace_generation + per-candidate revision + geometry.
##   2. apply_check_result on a MATCHING reply sets clean/violating, stores
##      findings ATTRIBUTED to the right segment of a MULTI-PAD candidate
##      (disconnected path A vs path B), and emits validation_changed.
##   3. MISMATCH DISCARD (three cases), each must leave the candidate NOT-clean:
##        (i)   stale board_token
##        (ii)  stale workspace_generation (set mutated after begin_check)
##        (iii) a candidate's revision drifted after begin_check
##      A stale reply must NEVER mark a candidate clean.
##   4. Geometric indeterminacy downgrades connectivity-clean candidates to
##      error, and a stale reply cannot replace the current diagnostic.

const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")


class FakeDraftData extends RefCounted:
	var board_revision: int = 0


## Simulates a mixed-version/raw worker that still says connectivity-clean while
## naming geometric indeterminacy. The panel applies the reply to the workspace;
## the MCP adapter must return that guarded state, not resurrect the raw clean.
class FakeDraftPanel extends RefCounted:
	var workspace

	func _init(ws) -> void:
		workspace = ws

	func check_draft(ids: Array) -> Dictionary:
		var payload: Dictionary = workspace.begin_check(ids)
		var per_candidate: Dictionary = {}
		for cid in ids:
			per_candidate[str(cid)] = "clean"
		var reply := {
			"board_token": payload.get("board_token", ""),
			"workspace_generation": payload.get("workspace_generation", -1),
			"per_candidate": per_candidate,
			"findings": [],
			"geometric_indeterminate": {
				"kind": "unsupported_geometry", "message": "synthetic refusal"},
		}
		workspace.apply_check_result(reply)
		return reply


class FakeDraftHost extends RefCounted:
	var panel

	func _init(value) -> void:
		panel = value

	func get_panel():
		return panel

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== RoutingWorkspace draft-check (T2.4) Tests ===\n")
	_run_begin_check()
	_run_apply_match()
	_run_mismatch_stale_token()
	_run_mismatch_stale_generation()
	_run_mismatch_revision_drift()
	_run_geometric_indeterminate()
	_run_stale_diagnostic_discard()
	await _run_cross_check_reply_honesty()
	_run_load_resets_check_epoch()
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

## A workspace with two candidates, board_token set, a check begun. Returns
## {ws, c1, c2, payload}. C1 is a MULTI-PAD candidate: two DISCONNECTED segments
## (path A + path B), no chain assumed (INV-3). C2 is single-segment.
func _fresh() -> Dictionary:
	var ws = PcbRoutingWorkspace.new()

	var c1 = PcbRouteCandidate.new()
	c1.net = "SIG"
	c1.candidate_revision = 3
	c1.add_segment(PcbRouteCandidate.make_segment("", "top", 0.25, [Vector2(0, 0), Vector2(5, 0)]))       # path A
	c1.add_segment(PcbRouteCandidate.make_segment("", "top", 0.25, [Vector2(50, 50), Vector2(60, 50)]))   # path B (disconnected)
	ws.add_candidate(c1)

	var c2 = PcbRouteCandidate.new()
	c2.net = "CLEAN"
	c2.candidate_revision = 1
	c2.add_segment(PcbRouteCandidate.make_segment("", "top", 0.25, [Vector2(0, 90), Vector2(5, 90)]))
	ws.add_candidate(c2)

	ws.board_token = "sha256:board-A"
	var payload: Dictionary = ws.begin_check()
	return {"ws": ws, "c1": c1, "c2": c2, "payload": payload}


## Build a MATCHING reply for a fixture (echoes its payload's coherence tokens).
## `c1_verdict`/`c2_verdict` set per_candidate; the crossing finding names path
## A's segment id ONLY (attribution must land on A, not B).
func _matching_reply(fx: Dictionary, c1_verdict: String, c2_verdict: String) -> Dictionary:
	var payload: Dictionary = fx["payload"]
	var c1 = fx["c1"]
	var seg_a_id: String = str((c1.segments[0] as Dictionary).get("id", ""))
	return {
		"board_token": payload["board_token"],
		"workspace_generation": payload["workspace_generation"],
		"per_candidate": {c1.candidate_id: c1_verdict, fx["c2"].candidate_id: c2_verdict},
		"findings": [
			{"kind": "crossing", "nets": ["SIG", "EXIST"], "layer": "top",
			 "at": [2.5, 0.0],
			 "subjects": [{"candidate_id": c1.candidate_id, "segment_id": seg_a_id}]},
		],
	}


# ── 1. begin_check ────────────────────────────────────────────────────────────

func _run_begin_check() -> void:
	print("-- 1. begin_check: checking state + payload tokens + geometry --")
	var fx := _fresh()
	var ws = fx["ws"]
	var c1 = fx["c1"]
	var c2 = fx["c2"]
	var payload: Dictionary = fx["payload"]

	check_eq("c1 validation == checking", c1.validation, "checking")
	check_eq("c2 validation == checking", c2.validation, "checking")
	check_eq("payload board_token stamped", str(payload.get("board_token", "")), "sha256:board-A")
	check_eq("payload workspace_generation == current", int(payload.get("workspace_generation", -1)), ws.workspace_generation())

	var cands: Array = payload.get("candidates", [])
	check_eq("payload carries both candidates", cands.size(), 2)
	var by_id := {}
	for c in cands:
		by_id[str((c as Dictionary).get("candidate_id", ""))] = c
	var p1: Dictionary = by_id.get(c1.candidate_id, {})
	check_eq("payload c1 revision snapshot", int(p1.get("revision", -1)), 3)
	check_eq("payload c1 net", str(p1.get("net", "")), "SIG")
	check_eq("payload c1 carries both (disconnected) segments", (p1.get("segments", []) as Array).size(), 2)
	var seg0: Dictionary = (p1.get("segments", []) as Array)[0]
	check("payload segment carries stable id", not str(seg0.get("id", "")).is_empty())
	check("payload segment carries [[x,y],…] points", (seg0.get("points", []) as Array).size() == 2)


# ── 2. apply MATCH → verdicts + attributed findings + emissions ───────────────

func _run_apply_match() -> void:
	print("-- 2. apply_check_result MATCH: verdicts, subject-attributed findings --")
	var fx := _fresh()
	var ws = fx["ws"]
	var c1 = fx["c1"]
	var c2 = fx["c2"]

	var emitted := {}
	ws.validation_changed.connect(func(id: String) -> void: emitted[id] = true)

	ws.apply_check_result(_matching_reply(fx, "violating", "clean"))

	check_eq("c1 -> violating", c1.validation, "violating")
	check_eq("c2 -> clean", c2.validation, "clean")
	check("validation_changed emitted for c1", emitted.has(c1.candidate_id))
	check("validation_changed emitted for c2", emitted.has(c2.candidate_id))

	# Findings stored on c1 and attributed to path A's segment, NOT path B.
	var f1: Array = ws.findings_for_candidate(c1.candidate_id)
	check_eq("c1 has one stored finding", f1.size(), 1)
	var seg_a_id: String = str((c1.segments[0] as Dictionary).get("id", ""))
	var seg_b_id: String = str((c1.segments[1] as Dictionary).get("id", ""))
	var named := {}
	for s in (f1[0] as Dictionary).get("subjects", []):
		named[str((s as Dictionary).get("segment_id", ""))] = true
	check("finding attributed to path A segment", named.has(seg_a_id))
	check("finding NOT attributed to path B segment", not named.has(seg_b_id))
	check_eq("clean candidate stores no finding", ws.findings_for_candidate(c2.candidate_id).size(), 0)


# ── 3(i). stale board_token → whole-reply discard ────────────────────────────

func _run_mismatch_stale_token() -> void:
	print("-- 3(i). MISMATCH stale board_token → discard, nothing clean --")
	var fx := _fresh()
	var ws = fx["ws"]
	var c1 = fx["c1"]
	var c2 = fx["c2"]
	var reply := _matching_reply(fx, "clean", "clean")
	reply["board_token"] = "sha256:board-B-STALE"  # board changed under us

	ws.apply_check_result(reply)

	check("c1 NOT clean after stale-token discard", c1.validation != "clean")
	check("c2 NOT clean after stale-token discard", c2.validation != "clean")
	check_eq("c1 reverted to prior (unchecked)", c1.validation, "unchecked")
	check_eq("c2 reverted to prior (unchecked)", c2.validation, "unchecked")


# ── 3(ii). stale workspace_generation → whole-reply discard ──────────────────

func _run_mismatch_stale_generation() -> void:
	print("-- 3(ii). MISMATCH stale workspace_generation → discard, nothing clean --")
	var fx := _fresh()
	var ws = fx["ws"]
	var c1 = fx["c1"]
	var c2 = fx["c2"]
	# Reply built BEFORE the set mutates (carries the begin-time generation).
	var reply := _matching_reply(fx, "clean", "clean")

	# Mutate the candidate set after begin_check → generation bumps.
	var c3 = PcbRouteCandidate.new()
	c3.net = "LATE"
	c3.add_segment(PcbRouteCandidate.make_segment("", "top", 0.25, [Vector2(0, 0), Vector2(1, 0)]))
	ws.add_candidate(c3)
	check("generation advanced past the reply's", ws.workspace_generation() != int(reply["workspace_generation"]))

	ws.apply_check_result(reply)

	check("c1 NOT clean after stale-generation discard", c1.validation != "clean")
	check("c2 NOT clean after stale-generation discard", c2.validation != "clean")
	check_eq("c1 reverted to prior (unchecked)", c1.validation, "unchecked")


# ── 3(iii). candidate revision drift → per-candidate discard ─────────────────

func _run_mismatch_revision_drift() -> void:
	print("-- 3(iii). MISMATCH candidate revision drift → per-candidate discard --")
	var fx := _fresh()
	var ws = fx["ws"]
	var c1 = fx["c1"]
	var c2 = fx["c2"]
	# A reply that would mark BOTH clean; c1's geometry then drifts mid-flight.
	var reply := _matching_reply(fx, "clean", "clean")

	c1.candidate_revision = int(c1.candidate_revision) + 1  # edited after begin_check

	ws.apply_check_result(reply)

	check("drifted c1 NOT marked clean by a stale reply", c1.validation != "clean")
	check_eq("drifted c1 reverted to prior (unchecked)", c1.validation, "unchecked")
	# c2 did not drift and its tokens match → legitimately clean.
	check_eq("undrifted c2 legitimately clean", c2.validation, "clean")
	check_eq("no finding stored on the discarded c1", ws.findings_for_candidate(c1.candidate_id).size(), 0)


# ── 4. geometric indeterminacy is state, subject to the same guards ──────────

func _run_geometric_indeterminate() -> void:
	print("-- 4(i). geometric indeterminate ⇒ no connectivity-only clean --")
	var fx := _fresh()
	var ws = fx["ws"]
	var c1 = fx["c1"]
	var c2 = fx["c2"]
	var reply := _matching_reply(fx, "clean", "clean")
	reply["geometric_indeterminate"] = {
		"kind": "unsupported_geometry",
		"message": "candidate copper could not be modeled",
	}

	ws.apply_check_result(reply)

	check_eq("indeterminate c1 is error, never clean", c1.validation, "error")
	check_eq("indeterminate c2 is error, never clean", c2.validation, "error")
	check_eq("the actionable geometric reason is retained",
		str(ws.geometric_indeterminate().get("kind", "")), "unsupported_geometry")


func _run_stale_diagnostic_discard() -> void:
	print("-- 4(ii). stale reply cannot overwrite the current diagnostic --")
	var fx := _fresh()
	var ws = fx["ws"]
	var c1 = fx["c1"]
	var c2 = fx["c2"]
	var current := _matching_reply(fx, "clean", "clean")
	current["geometric_indeterminate"] = {
		"kind": "current_reason", "message": "the coherent check's reason"}
	ws.apply_check_result(current)

	# Start another check, then deliver a reply for a different board. Its
	# diagnostic must be discarded with its verdicts; pending candidates return
	# to the prior error state established by the coherent reply above.
	fx["payload"] = ws.begin_check()
	var stale := _matching_reply(fx, "clean", "clean")
	stale["board_token"] = "sha256:stale-board"
	stale["geometric_indeterminate"] = {
		"kind": "stale_reason", "message": "must not become current"}
	ws.apply_check_result(stale)

	check_eq("stale diagnostic was discarded",
		str(ws.geometric_indeterminate().get("kind", "")), "current_reason")
	check_eq("stale reply reverted c1 to its prior error", c1.validation, "error")
	check_eq("stale reply reverted c2 to its prior error", c2.validation, "error")

	# A later coherent determinate reply clears the diagnostic normally.
	fx["payload"] = ws.begin_check()
	ws.apply_check_result(_matching_reply(fx, "clean", "clean"))
	check("coherent determinate reply clears the diagnostic",
		ws.geometric_indeterminate().is_empty())
	check_eq("coherent determinate reply may mark c1 clean", c1.validation, "clean")


func _run_cross_check_reply_honesty() -> void:
	print("-- 4(iii). automatic cross-check exposes guarded verdict + reason --")
	var fx := _fresh()
	var ws = fx["ws"]
	# _fresh starts a model-only pending check; discard it before the fake panel
	# begins the check owned by this tool call.
	ws.apply_check_result({})
	var cross: Dictionary = await PanelTools._cross_candidate_check(
		FakeDraftHost.new(FakeDraftPanel.new(ws)), ws, FakeDraftData.new())
	var c1_id := str(fx["c1"].candidate_id)

	check_eq("cross-check per_candidate is guarded, not raw clean",
		str((cross.get("per_candidate", {}) as Dictionary).get(c1_id, "")), "error")
	check_eq("cross-check validation agrees with its verdict",
		str((cross.get("validation", {}) as Dictionary).get(c1_id, "")), "error")
	check_eq("cross-check exposes the geometric refusal",
		str((cross.get("geometric_indeterminate", {}) as Dictionary).get("kind", "")),
		"unsupported_geometry")
	check("cross-check note makes the refusal visible",
		str(cross.get("note", "")).contains("could NOT be verified"))


func _run_load_resets_check_epoch() -> void:
	print("-- 4(iv). document load clears diagnostics and invalidates old replies --")
	var fx := _fresh()
	var ws = fx["ws"]
	ws.apply_check_result(_matching_reply(fx, "clean", "clean"))
	var saved: Dictionary = ws.to_dict()

	# Establish a current refusal, then leave another reply in flight from the
	# old document. The saved replacement intentionally reuses the same candidate
	# ids and board token: generation is the load boundary's decisive guard.
	fx["payload"] = ws.begin_check()
	var refused := _matching_reply(fx, "clean", "clean")
	refused["geometric_indeterminate"] = {
		"kind": "old_document", "message": "must not cross the load boundary"}
	ws.apply_check_result(refused)
	fx["payload"] = ws.begin_check()
	var late_reply := _matching_reply(fx, "clean", "clean")
	var old_generation: int = int(ws.workspace_generation())

	ws.load_from_dict(saved)
	var loaded_c1 = ws.get_candidate(str(fx["c1"].candidate_id))
	check("load clears the prior document's geometric diagnostic",
		ws.geometric_indeterminate().is_empty())
	check("load advances the check epoch",
		ws.workspace_generation() > old_generation)
	check_eq("replacement candidate restored its persisted validation",
		str(loaded_c1.validation), "clean")

	ws.apply_check_result(late_reply)
	check_eq("late pre-load reply cannot mutate the replacement candidate",
		str(loaded_c1.validation), "clean")
