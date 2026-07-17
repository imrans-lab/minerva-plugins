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

const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== RoutingWorkspace draft-check (T2.4) Tests ===\n")
	_run_begin_check()
	_run_apply_match()
	_run_mismatch_stale_token()
	_run_mismatch_stale_generation()
	_run_mismatch_revision_drift()
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
