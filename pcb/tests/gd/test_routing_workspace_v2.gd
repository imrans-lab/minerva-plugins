extends SceneTree
## C1 (S2 completion) — routing-workspace V2 model tests: DISPOSITION LEGALITY,
## RouteTask SPAN scope + open/closed lifecycle, and PER-CANDIDATE staleness on
## a board-revision mismatch.
##
## ── UN-PARKED at the epoch-C boundary (Station 1, un-park + execute) ───────────
## Moved from pcb/tests/pending/ into pcb/tests/gd/ and added to EXPECTED_SUITES
## — it now runs as part of the normal run-gd-tests.sh sweep.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the
## live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_routing_workspace_v2.gd
##
## ── WHAT IS DELIBERATELY NOT HERE ─────────────────────────────────────────────
## UNDO-AFTER-COMMIT fixtures land in C4a. RoutingWorkspace.commit() — the
## composite board transaction — is still a T5 STUB (it push_warnings and returns
## false), so there is no board-level commit to undo yet. The commit fixtures
## below use mark_committed(), the SHIPPED correlation-side commit marker, and
## assert only model-side coherence (disposition + task state + copper-id
## bookkeeping). The board-transaction half (one snapshot, one undo restoring
## traces AND vias) is C4a's, beside the seven-item history codec.
##
## Coverage (10 groups):
##   1. Legality MATRIX: every legal ordered pair, and every illegal one, from
##      PcbRouteCandidate.DISPOSITION_TRANSITIONS — hand-enumerated below.
##   2. Refusal CONTRACT at the workspace: named error, value UNCHANGED, signal
##      + last_transition_error recorded, no generation bump.
##   3. committed is TERMINAL for workflow verbs; uncommit is the one
##      COMPENSATING exit and only to a legal uncommit target.
##   4. SPAN scope: span_key determinism, whole-net vs span task identity,
##      span round-trip, span re-propose supersedes only its own task.
##   5. TASK lifecycle: ingest opens, commit closes, uncommit/reject reopen,
##      re-propose keeps open; tasks persist; legacy sidecars backfill.
##   6. STALE on base-board-revision mismatch: per candidate, validation-only,
##      disposition preserved, idempotent; load_from_dict's revision hint.
##   7. GATE fixture — multi-pad net (3 pins, >=2 DISCONNECTED copper paths) at
##      MODEL level, carried intact through pin -> commit -> uncommit -> rebase.
##   8. DELIBERATE NON-PERSISTENCE of _workspace_generation / board_token /
##      board_revision: they RESET after a round-trip. Asserting that they
##      SURVIVE would encode a wrong oracle — they are transient by design.
##   9. Traps: id counters restore to a HIGH-WATER MARK (ids are sparse, never
##      dense) and JSON hands whole numbers back as float.
##  10. INGEST vs PINNED: a batch re-route HOLDS a task whose active candidate is
##      pinned (named, queryable, announced — the pin is a keep-out); a TARGETED
##      verb (supersede/unpin) still retires it. Both sides asserted.
##
## NUMERIC-COMPARISON RULE for this file: every numeric assertion is normalised
## with int()/float() before comparing, and NO assertion compares whole
## containers (Dictionary/Array) whose values may have crossed a JSON boundary.
## GDScript's container equality is type-strict about the int/float distinction
## that JSON erases, so a container compare is a coin-flip oracle; a normalised
## field compare is not.

const PcbRouteTask := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_task.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")
const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")

var _pass := 0
var _fail := 0

# Signal recorders.
var _rec_refused: Array = []
var _rec_task_state: Array = []
var _rec_changed: Array = []
var _rec_held: Array = []


func _init() -> void:
	print("=== RoutingWorkspace V2 (C1: legality + span + stale) Tests ===\n")
	_run_legality_matrix()
	_run_refusal_contract()
	_run_committed_terminal_and_uncommit()
	_run_span_scope()
	_run_task_lifecycle()
	_run_stale_on_revision_mismatch()
	_run_gate_multipad()
	_run_transient_not_persisted()
	_run_id_high_water_and_json_floats()
	_run_ingest_vs_pinned()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── assertion helpers (same idiom as the shipped workspace suites) ─────────────

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

## A candidate parked in `state` WITHOUT going through the legality gate. This
## uses the RAW setter (set_disposition), which is documented as the restore/load
## path precisely because it does set-membership only — it is the one legitimate
## way to construct an arbitrary "from" state for a matrix test.
func _candidate_in(state: String):
	var c = PcbRouteCandidate.new()
	c.set_disposition(state)
	return c


func _hint(id: String, net: String) -> Dictionary:
	return {"id": id, "kind_payload": {"net_names": [net], "width_mm": 0.3}}


## One-route reply, one segment: ingest mints cand_1 / seg_1.
func _one_route(net: String, x_end: float = 5.0) -> Dictionary:
	return {"routes": [{
		"net": net,
		"segments": [{"start": [0.0, 0.0], "end": [x_end, 0.0], "layer": "F.Cu"}],
		"vias": [],
	}]}


# ── 1. legality matrix ────────────────────────────────────────────────────────

## HAND-DERIVED from PcbRouteCandidate.DISPOSITION_TRANSITIONS:
##   proposed   -> pinned, superseded, rejected, committed        (4 legal)
##   pinned     -> proposed, superseded, rejected, committed      (4 legal)
##   superseded -> (none)                                          terminal
##   rejected   -> (none)                                          terminal
##   committed  -> (none) except the uncommit compensating exit    terminal
## Plus the 5 IDENTITY pairs (x -> x), which are legal no-ops.
## => 4 + 4 + 5 = 13 legal ordered pairs out of 5 x 5 = 25.
## => 12 illegal ordered pairs, ALL of them leaving a terminal state:
##      superseded -> {proposed, pinned, rejected, committed}   (4)
##      rejected   -> {proposed, pinned, superseded, committed} (4)
##      committed  -> {proposed, pinned, superseded, rejected}  (4)
const _LEGAL_PAIRS := [
	["proposed", "proposed"], ["proposed", "pinned"], ["proposed", "superseded"],
	["proposed", "rejected"], ["proposed", "committed"],
	["pinned", "pinned"], ["pinned", "proposed"], ["pinned", "superseded"],
	["pinned", "rejected"], ["pinned", "committed"],
	["superseded", "superseded"], ["rejected", "rejected"], ["committed", "committed"],
]

const _ILLEGAL_PAIRS := [
	["superseded", "proposed"], ["superseded", "pinned"],
	["superseded", "rejected"], ["superseded", "committed"],
	["rejected", "proposed"], ["rejected", "pinned"],
	["rejected", "superseded"], ["rejected", "committed"],
	["committed", "proposed"], ["committed", "pinned"],
	["committed", "superseded"], ["committed", "rejected"],
]


func _run_legality_matrix() -> void:
	print("-- 1. legality matrix: 13 legal / 12 illegal ordered pairs --")
	check_eq("hand-derived legal pair count", _LEGAL_PAIRS.size(), 13)
	check_eq("hand-derived illegal pair count", _ILLEGAL_PAIRS.size(), 12)
	check_eq("legal + illegal cover the whole 5x5 matrix",
		_LEGAL_PAIRS.size() + _ILLEGAL_PAIRS.size(),
		PcbRouteCandidate.DISPOSITIONS.size() * PcbRouteCandidate.DISPOSITIONS.size())

	# EVERY legal pair: transition_error is "" and transition_to applies it.
	for pair in _LEGAL_PAIRS:
		var from: String = pair[0]
		var to: String = pair[1]
		check_eq("legal %s -> %s reports no error" % [from, to],
			PcbRouteCandidate.transition_error(from, to), "")
		var c = _candidate_in(from)
		check("legal %s -> %s applied" % [from, to], c.transition_to(to).is_empty())
		check_eq("legal %s -> %s left the candidate in %s" % [from, to, to], c.disposition, to)

	# EVERY illegal pair: named error AND the value is UNCHANGED (never
	# half-applied). All 12 leave a terminal state, so all 12 report
	# "terminal_disposition" — a state-shaped verdict, not a generic refusal.
	for pair in _ILLEGAL_PAIRS:
		var from: String = pair[0]
		var to: String = pair[1]
		var err: String = PcbRouteCandidate.transition_error(from, to)
		check_eq("illegal %s -> %s named error" % [from, to],
			err, PcbRouteCandidate.ERR_TERMINAL_DISPOSITION)
		var c = _candidate_in(from)
		check_eq("illegal %s -> %s refused with the same code" % [from, to],
			c.transition_to(to), PcbRouteCandidate.ERR_TERMINAL_DISPOSITION)
		check_eq("illegal %s -> %s left the value UNCHANGED" % [from, to], c.disposition, from)

	# The two LIVE states have a FULL fan-out — their only refusal is an
	# out-of-set value, which is reported as unknown BEFORE any legality verdict
	# (so a typo is never mis-reported as a workflow violation).
	for live in ["proposed", "pinned"]:
		check_eq("%s -> 'bogus' is unknown_disposition" % live,
			PcbRouteCandidate.transition_error(live, "bogus"),
			PcbRouteCandidate.ERR_UNKNOWN_DISPOSITION)
	check_eq("'bogus' -> proposed is unknown_disposition (unknown wins over terminal)",
		PcbRouteCandidate.transition_error("bogus", "proposed"),
		PcbRouteCandidate.ERR_UNKNOWN_DISPOSITION)

	# can_transition_to mirrors the table exactly.
	var live_c = _candidate_in("proposed")
	check("proposed can_transition_to committed", live_c.can_transition_to("committed"))
	var dead_c = _candidate_in("rejected")
	check("rejected cannot_transition_to proposed", not dead_c.can_transition_to("proposed"))


# ── 2. refusal contract at the workspace ──────────────────────────────────────

func _on_refused(id: String, from: String, to: String, error: String) -> void:
	_rec_refused.append({"id": id, "from": from, "to": to, "error": error})


func _on_changed(id: String) -> void:
	_rec_changed.append(id)


func _run_refusal_contract() -> void:
	print("-- 2. refusal contract: named error, unchanged value, signal, no bump --")
	_rec_refused.clear()
	_rec_changed.clear()
	var ws = PcbRoutingWorkspace.new()
	ws.transition_refused.connect(_on_refused)
	ws.candidate_changed.connect(_on_changed)

	var ids: Array = ws.ingest_routing_result(_one_route("N1"), [_hint("h1", "N1")], 3)
	var cid: String = str(ids[0])
	check_eq("ingest minted cand_1", cid, "cand_1")

	# Legal: proposed -> rejected.
	check("reject on a proposed candidate succeeds", ws.reject(cid))
	check_eq("reject applied", ws.get_candidate(cid).disposition, "rejected")
	check("last_transition_error cleared on a legal move", ws.last_transition_error.is_empty())

	# Illegal: rejected -> pinned. Refused, named, recorded, announced, INERT.
	var gen_before: int = int(ws.workspace_generation())
	var changed_before: int = _rec_changed.size()
	check("pin on a rejected candidate is REFUSED", not ws.pin(cid))
	check_eq("value unchanged after refusal", ws.get_candidate(cid).disposition, "rejected")
	check_eq("last_transition_error names the code",
		str(ws.last_transition_error.get("error", "")),
		PcbRouteCandidate.ERR_TERMINAL_DISPOSITION)
	check_eq("last_transition_error names the verb", str(ws.last_transition_error.get("verb", "")), "pin")
	check_eq("last_transition_error names the candidate", str(ws.last_transition_error.get("candidate_id", "")), cid)
	check_eq("transition_refused fired once", _rec_refused.size(), 1)
	check_eq("refusal signal carries from", str((_rec_refused[0] as Dictionary).get("from", "")), "rejected")
	check_eq("refusal signal carries to", str((_rec_refused[0] as Dictionary).get("to", "")), "pinned")
	check_eq("a REFUSED move does not bump the workspace generation",
		int(ws.workspace_generation()), gen_before)
	check_eq("a REFUSED move emits no candidate_changed", _rec_changed.size(), changed_before)

	# can_transition is the UI-facing probe for exactly this gating.
	check("can_transition(rejected -> pinned) is false", not ws.can_transition(cid, "pinned"))

	# Unknown candidate ids refuse without crashing and without a phantom record.
	check("pin on an unknown candidate returns false", not ws.pin("cand_does_not_exist"))
	check_eq("...and leaves NO phantom record (it still names the real refusal)",
		str(ws.last_transition_error.get("candidate_id", "")), cid)
	check_eq("...and fires no extra transition_refused", _rec_refused.size(), 1)

	# IDENTITY move: legal, applied as a no-op, and NOT announced as a change.
	var ids2: Array = ws.ingest_routing_result(_one_route("N2"), [_hint("h2", "N2")], 3)
	var cid2: String = str(ids2[0])
	var gen2: int = int(ws.workspace_generation())
	var changed2: int = _rec_changed.size()
	check("unpin on an already-proposed candidate is a legal no-op", ws.unpin(cid2))
	check_eq("no-op left the disposition alone", ws.get_candidate(cid2).disposition, "proposed")
	check_eq("no-op did not bump the generation", int(ws.workspace_generation()), gen2)
	check_eq("no-op emitted no candidate_changed", _rec_changed.size(), changed2)
	# The record means "the LAST move was refused" — a legal identity move
	# clears it exactly like any other legal move (its own doc says so).
	check("an identity no-op CLEARS last_transition_error", ws.last_transition_error.is_empty())


# ── 3. committed terminality + the uncommit compensating exit ─────────────────

func _run_committed_terminal_and_uncommit() -> void:
	print("-- 3. committed is terminal for workflow verbs; uncommit is the one exit --")
	var ws = PcbRoutingWorkspace.new()
	var cid: String = str(ws.ingest_routing_result(_one_route("N1"), [_hint("h1", "N1")], 3)[0])

	check("pin before commit succeeds", ws.pin(cid))
	check("candidate is in the pinned set", ws.is_pinned(cid))
	check("mark_committed succeeds from pinned", ws.mark_committed(cid, ["t1"], ["v1"]))
	check_eq("disposition is committed", ws.get_candidate(cid).disposition, "committed")
	# `pinned` is DERIVED from the disposition: committed copper must stop acting
	# as a draft keep-out for future routing.
	check("committing drops the candidate from the pinned set", not ws.is_pinned(cid))

	# Every workflow verb is refused on committed copper.
	check("pin on committed is refused", not ws.pin(cid))
	check("unpin on committed is refused", not ws.unpin(cid))
	check("reject on committed is refused", not ws.reject(cid))
	check_eq("committed survived all three refusals", ws.get_candidate(cid).disposition, "committed")

	# The recorded copper ids are intact (a refused verb touches nothing).
	var copper: Dictionary = ws.committed_copper_ids(cid)
	check_eq("committed trace ids intact", (copper.get("trace_ids", []) as Array).size(), 1)
	check_eq("committed via ids intact", (copper.get("via_ids", []) as Array).size(), 1)

	# uncommit — the COMPENSATING exit — restores the PRE-COMMIT disposition
	# (pinned here, because that is what it was) and clears the copper ids.
	check("uncommit succeeds", ws.uncommit(cid))
	check_eq("uncommit restored the pre-commit disposition", ws.get_candidate(cid).disposition, "pinned")
	check("uncommit restored the derived pinned-set entry", ws.is_pinned(cid))
	var after: Dictionary = ws.committed_copper_ids(cid)
	check_eq("uncommit cleared trace ids", (after.get("trace_ids", []) as Array).size(), 0)
	check_eq("uncommit cleared via ids", (after.get("via_ids", []) as Array).size(), 0)
	check("candidate is live again", cid in ws.live_candidate_ids())

	# uncommit is not a general undo: it refuses on a non-committed candidate.
	check("uncommit on a non-committed candidate is refused", not ws.uncommit(cid))

	# The uncommit target set is exactly the two live dispositions — the model
	# can never "uncommit" into a terminal state.
	check_eq("UNCOMMIT_TARGETS size", PcbRouteCandidate.UNCOMMIT_TARGETS.size(), 2)
	check("UNCOMMIT_TARGETS has proposed", "proposed" in PcbRouteCandidate.UNCOMMIT_TARGETS)
	check("UNCOMMIT_TARGETS has pinned", "pinned" in PcbRouteCandidate.UNCOMMIT_TARGETS)
	var raw = PcbRouteCandidate.new()
	raw.set_disposition("committed")
	check_eq("uncommit_to a terminal target is refused",
		raw.uncommit_to("superseded"), PcbRouteCandidate.ERR_ILLEGAL_TRANSITION)
	check_eq("refused uncommit_to left it committed", raw.disposition, "committed")
	var live = PcbRouteCandidate.new()
	check_eq("uncommit_to on a non-committed candidate is named not_committed",
		live.uncommit_to("proposed"), PcbRouteCandidate.ERR_NOT_COMMITTED)

	# ── RE-COMMIT (identity move) is supported AND announced ─────────────────
	# The disposition does not move, but the recorded copper ids DO — and
	# committed_copper_ids() is read by the UI, so the change must emit. (The
	# shipped model deliberately supports re-commit: it keeps the ORIGINAL
	# prior_disposition rather than stamping "committed" over it.)
	_rec_changed.clear()
	ws.candidate_changed.connect(_on_changed)
	check("re-commit the (now pinned) candidate", ws.mark_committed(cid, ["t1"], ["v1"]))
	var emits_after_first: int = _rec_changed.size()
	check_eq("the real pinned -> committed move emitted once", emits_after_first, 1)
	check("mark_committed AGAIN (identity) succeeds", ws.mark_committed(cid, ["t1", "t2"], []))
	check_eq("identity re-commit ANNOUNCED the copper-id change",
		_rec_changed.size(), emits_after_first + 1)
	var recommitted: Dictionary = ws.committed_copper_ids(cid)
	check_eq("identity re-commit updated the trace ids", (recommitted.get("trace_ids", []) as Array).size(), 2)
	check_eq("identity re-commit cleared the via ids", (recommitted.get("via_ids", []) as Array).size(), 0)
	check_eq("disposition still committed", ws.get_candidate(cid).disposition, "committed")
	# The ORIGINAL pre-commit disposition survived the re-commit, so an undo
	# still lands on "pinned" rather than on a self-referential "committed".
	check("uncommit after a re-commit", ws.uncommit(cid))
	check_eq("...restores the ORIGINAL pre-commit disposition", ws.get_candidate(cid).disposition, "pinned")


# ── 4. span scope ─────────────────────────────────────────────────────────────

func _run_span_scope() -> void:
	print("-- 4. span scope: key determinism, task identity, round-trip --")

	# HAND-DERIVED: span_key sorts the segment ids, so selection ORDER cannot
	# change the identity of the interval.
	var span_a: Dictionary = PcbRouteTask.make_span("cand_1", ["seg_7", "seg_2"], Vector2(1, 0), Vector2(4, 0))
	var span_b: Dictionary = PcbRouteTask.make_span("cand_1", ["seg_2", "seg_7"], Vector2(1, 0), Vector2(4, 0))
	check_eq("span_key is sorted + deterministic", PcbRouteTask.span_key(span_a), "cand_1:seg_2,seg_7")
	check_eq("span_key is order-independent", PcbRouteTask.span_key(span_b), PcbRouteTask.span_key(span_a))
	check_eq("the EMPTY span (whole-net) keys to the empty string", PcbRouteTask.span_key({}), "")
	# A span on a different base candidate is a different interval.
	check("span_key discriminates the base candidate",
		PcbRouteTask.span_key(PcbRouteTask.make_span("cand_2", ["seg_2", "seg_7"], Vector2(1, 0), Vector2(4, 0)))
		!= PcbRouteTask.span_key(span_a))

	# Task round-trip carries span + state; Vector2 anchors survive as Vector2.
	var t = PcbRouteTask.new()
	t.task_id = "task_span"
	t.net = "N5"
	t.span = span_a
	t.set_state("closed")
	var t2 = PcbRouteTask.from_dict(t.to_dict())
	check_eq("task round-trip keeps the state axis", t2.state, "closed")
	check("task round-trip keeps span scoping", t2.is_span_scoped())
	check_eq("task round-trip keeps the base candidate", str(t2.span.get("candidate_id", "")), "cand_1")
	check_eq("task round-trip keeps 2 segment ids", (t2.span.get("segment_ids", []) as Array).size(), 2)
	check("task round-trip restores the from anchor as Vector2", t2.span.get("from") is Vector2)
	check_eq("task round-trip from anchor value", t2.span.get("from"), Vector2(1, 0))
	check_eq("task round-trip to anchor value", t2.span.get("to"), Vector2(4, 0))
	# An out-of-set state falls back to the safe default rather than sticking.
	var t3 = PcbRouteTask.new()
	t3.set_state("halfway")
	check_eq("an invalid state is refused; 'open' stands", t3.state, "open")
	check("a fresh task is whole-net scoped", not t3.is_span_scoped())

	# ── task identity: whole-net vs span ─────────────────────────────────────
	# HAND-DERIVED task keys for net "N9" with the single hint "hint_s":
	#   whole-net : "N9|hint_s"
	#   span      : "N9|hint_s|span:cand_1:seg_1"
	# The whole-net key is byte-identical to what it was before spans existed —
	# the span suffix is appended ONLY when the span is non-empty.
	var ws = PcbRoutingWorkspace.new()
	var hints := [_hint("hint_s", "N9")]
	var whole_id: String = str(ws.ingest_routing_result(_one_route("N9"), hints, 1)[0])
	check_eq("whole-net ingest minted cand_1", whole_id, "cand_1")
	check_eq("whole-net task key unchanged by the span feature",
		str(ws.get_candidate(whole_id).task_id), "N9|hint_s")

	var span_reply: Dictionary = _one_route("N9", 3.0)
	(span_reply["routes"][0] as Dictionary)["span"] = PcbRouteTask.make_span(
		whole_id, ["seg_1"], Vector2(0, 0), Vector2(3, 0))
	var span_cand_id: String = str(ws.ingest_routing_result(span_reply, hints, 1)[0])
	check_eq("span ingest lands on its OWN task key",
		str(ws.get_candidate(span_cand_id).task_id), "N9|hint_s|span:cand_1:seg_1")
	# The span proposal must NOT supersede the whole-net candidate: different
	# question, different task, independent generation chain.
	check_eq("the whole-net candidate is untouched by a span propose",
		ws.get_candidate(whole_id).disposition, "proposed")
	check_eq("span candidate starts at generation 1", int(ws.get_candidate(span_cand_id).generation), 1)
	check_eq("two tasks now exist", ws.list_tasks().size(), 2)
	var span_task = ws.get_task("N9|hint_s|span:cand_1:seg_1")
	check("the span task recorded its scope", span_task != null and span_task.is_span_scoped())
	check("the whole-net task is NOT span scoped", not ws.get_task("N9|hint_s").is_span_scoped())

	# Re-proposing the SAME span supersedes only within that span's own task.
	var span_cand_2: String = str(ws.ingest_routing_result(span_reply, hints, 2)[0])
	check_eq("span re-propose supersedes the prior SPAN candidate",
		ws.get_candidate(span_cand_id).disposition, "superseded")
	check_eq("span re-propose bumps the generation", int(ws.get_candidate(span_cand_2).generation), 2)
	check_eq("the whole-net candidate is STILL untouched",
		ws.get_candidate(whole_id).disposition, "proposed")
	check_eq("the span task still has exactly 1 live candidate",
		ws.candidates_for_task("N9|hint_s|span:cand_1:seg_1").size(), 1)


# ── 5. task open/closed lifecycle ─────────────────────────────────────────────

func _on_task_state(task_id: String, state: String) -> void:
	_rec_task_state.append({"task_id": task_id, "state": state})


func _run_task_lifecycle() -> void:
	print("-- 5. task lifecycle: ingest opens, commit closes, uncommit/reject reopen --")
	_rec_task_state.clear()
	var ws = PcbRoutingWorkspace.new()
	ws.task_state_changed.connect(_on_task_state)

	var hints := [_hint("h1", "N1")]
	var cid: String = str(ws.ingest_routing_result(_one_route("N1"), hints, 1)[0])
	var tid: String = str(ws.get_candidate(cid).task_id)   # HAND-DERIVED: "N1|h1"
	check_eq("ingest created the task", tid, "N1|h1")
	check_eq("a freshly ingested task is OPEN", ws.task_state(tid), "open")
	check("open_task_ids lists it", tid in ws.open_task_ids())
	check_eq("the task learned its net", str(ws.get_task(tid).net), "N1")

	# Try-again: supersede + new generation. The QUESTION stays open throughout.
	var cid2: String = str(ws.ingest_routing_result(_one_route("N1", 7.0), hints, 1)[0])
	check_eq("re-propose superseded the prior answer", ws.get_candidate(cid).disposition, "superseded")
	check_eq("the task is still OPEN across a re-propose", ws.task_state(tid), "open")
	check_eq("no task_state_changed fired for a re-propose", _rec_task_state.size(), 0)

	# Accept: the task CLOSES (its current answer is committed copper).
	check("mark_committed succeeds", ws.mark_committed(cid2, ["t1"], []))
	check_eq("commit CLOSED the task", ws.task_state(tid), "closed")
	check("closed_task_ids lists it", tid in ws.closed_task_ids())
	check("open_task_ids no longer lists it", not (tid in ws.open_task_ids()))
	check_eq("exactly one task_state_changed so far", _rec_task_state.size(), 1)
	check_eq("...and it announced closed", str((_rec_task_state[0] as Dictionary).get("state", "")), "closed")

	# Board undo + uncommit: the task REOPENS (the copper is gone).
	check("uncommit succeeds", ws.uncommit(cid2))
	check_eq("uncommit REOPENED the task", ws.task_state(tid), "open")
	check_eq("two task_state_changed now", _rec_task_state.size(), 2)

	# Reject: per the DCR, reject discards the candidate and REOPENS the task.
	# It is already open here, so the assertion is that reject never CLOSES it.
	check("reject succeeds", ws.reject(cid2))
	check_eq("the task stays OPEN after a reject", ws.task_state(tid), "open")
	# NB: candidates_for_task() filters SUPERSEDED only (its shipped contract),
	# so the rejected candidate is still in it — the LIVE set is the right
	# oracle for "does this task have an answer".
	var live_for_task := 0
	for lid in ws.live_candidate_ids():
		if str(ws.get_candidate(str(lid)).task_id) == tid:
			live_for_task += 1
	check_eq("no LIVE candidate remains for the task", live_for_task, 0)
	check("the task survives its last answer (a question with no answer is open)",
		ws.get_task(tid) != null)

	# Closed is DERIVED, so a commit followed by a fresh propose reopens: the
	# user is asking the question again even though copper exists.
	var ws2 = PcbRoutingWorkspace.new()
	var a: String = str(ws2.ingest_routing_result(_one_route("N2"), [_hint("h2", "N2")], 1)[0])
	var t2: String = str(ws2.get_candidate(a).task_id)
	ws2.mark_committed(a, ["t9"], [])
	check_eq("task closed after commit", ws2.task_state(t2), "closed")
	ws2.ingest_routing_result(_one_route("N2", 9.0), [_hint("h2", "N2")], 2)
	check_eq("a re-propose over committed copper REOPENS the task", ws2.task_state(t2), "open")
	check_eq("the committed candidate was NOT superseded (terminal, nothing to replace)",
		ws2.get_candidate(a).disposition, "committed")

	# ── persistence: tasks are durable; a legacy sidecar backfills ────────────
	var durable: Dictionary = ws2.to_sidecar_dict()
	check("to_sidecar_dict carries tasks", durable.has("tasks"))
	var reloaded = PcbRoutingWorkspace.from_dict(durable)
	check_eq("tasks round-trip", reloaded.list_tasks().size(), ws2.list_tasks().size())
	check_eq("task state is RE-DERIVED from the loaded candidates (open)",
		reloaded.task_state(t2), "open")

	# Legacy: a workspace dict written BEFORE tasks existed has no "tasks" key.
	# The registry must be backfilled from the candidates, not left empty.
	var legacy: Dictionary = ws2.to_sidecar_dict()
	legacy.erase("tasks")
	var legacy_ws = PcbRoutingWorkspace.from_dict(legacy)
	check_eq("legacy sidecar backfills the task registry", legacy_ws.list_tasks().size(), 1)
	check_eq("backfilled task keeps its id", str(legacy_ws.list_tasks()[0].task_id), t2)
	check_eq("backfilled task state derived as open", legacy_ws.task_state(t2), "open")


# ── 6. stale on base-board-revision mismatch ──────────────────────────────────

func _run_stale_on_revision_mismatch() -> void:
	print("-- 6. per-candidate stale on a base-revision mismatch --")
	var ws = PcbRoutingWorkspace.new()
	var cid: String = str(ws.ingest_routing_result(_one_route("N1"), [_hint("h1", "N1")], 7)[0])
	check_eq("candidate stamped with the ingest revision",
		int(ws.get_candidate(cid).base_board_revision), 7)
	check_eq("validation starts unchecked", ws.get_candidate(cid).validation, "unchecked")

	# The candidate is a keeper: pin it, so the disposition axis has something
	# to preserve across the rebase.
	check("pin succeeds", ws.pin(cid))
	ws.set_validation(cid, "clean")

	# Same revision: NOT stale. Re-binding to the revision you are already on
	# must not quarantine freshly-checked work.
	var none: Array = ws.rebase(7)
	check_eq("rebase to the SAME revision marks nothing", none.size(), 0)
	check_eq("validation untouched", ws.get_candidate(cid).validation, "clean")
	check_eq("workspace bound to revision 7", int(ws.board_revision), 7)

	# Different revision: stale (NOT error), disposition preserved.
	var marked: Array = ws.rebase(8)
	check_eq("rebase to a DIFFERENT revision marks exactly this candidate", marked.size(), 1)
	check_eq("...and names it", str(marked[0]), cid)
	check_eq("mismatch marks validation STALE (not error)", ws.get_candidate(cid).validation, "stale")
	check_eq("mismatch PRESERVES the disposition axis", ws.get_candidate(cid).disposition, "pinned")
	check("the candidate is still pinned", ws.is_pinned(cid))
	check_eq("base_board_revision is NOT rewritten (the candidate is still based on 7)",
		int(ws.get_candidate(cid).base_board_revision), 7)

	# Idempotent: a second rebase re-marks nothing.
	check_eq("rebase is idempotent", ws.rebase(8).size(), 0)

	# PER CANDIDATE, not blunt-force-all: a candidate ingested AT revision 8 is
	# left alone while the revision-7 one stays stale.
	var fresh: String = str(ws.ingest_routing_result(_one_route("N2"), [_hint("h2", "N2")], 8)[0])
	check_eq("a candidate at the bound revision is not stale-marked",
		ws.get_candidate(fresh).validation, "unchecked")
	check_eq("rebase(8) still leaves the fresh candidate alone", ws.rebase(8).size(), 0)
	check_eq("the older candidate is still stale", ws.get_candidate(cid).validation, "stale")

	# The pure query agrees with what rebase acted on.
	var q: Array = ws.stale_candidate_ids_for_revision(8)
	check_eq("stale_candidate_ids_for_revision finds exactly the old candidate", q.size(), 1)
	check_eq("...and it is the revision-7 one", str(q[0]), cid)
	check("candidate-level predicate agrees", ws.get_candidate(cid).is_stale_for_board_revision(8))
	check("candidate-level predicate is false at its own revision",
		not ws.get_candidate(cid).is_stale_for_board_revision(7))

	# LOADING against a different board revision: the hint drives the rebase.
	var dict: Dictionary = ws.to_sidecar_dict()
	var loaded_no_hint = PcbRoutingWorkspace.from_dict(dict)
	check_eq("loading WITHOUT a revision hint rebases nothing (fresh candidate stays unchecked)",
		loaded_no_hint.get_candidate(fresh).validation, "unchecked")
	var loaded_hinted = PcbRoutingWorkspace.from_dict(dict, 99)
	check_eq("loading against revision 99 stales the revision-8 candidate",
		loaded_hinted.get_candidate(fresh).validation, "stale")
	check_eq("...and preserves its disposition", loaded_hinted.get_candidate(fresh).disposition, "proposed")
	check_eq("...and the pinned candidate keeps its pin", loaded_hinted.get_candidate(cid).disposition, "pinned")
	check_eq("the loaded workspace is bound to the hinted revision", int(loaded_hinted.board_revision), 99)


# ── 7. GATE fixture: multi-pad net, >=2 disconnected paths, at model level ─────

## HAND-DERIVED 3-pin fixture for net "N7" (GATE INV-3 shape).
##   PATH 1 — pin A -> pin B, changing layer at (10,0):
##     seg 1  top    (0,0)   -> (10,0)
##     seg 2  bottom (10,0)  -> (10,5)
##     via    at (10,0), top<->bottom  (the layer change)
##   PATH 2 — pin C, an INDEPENDENT stretch that touches neither of the above:
##     seg 3  top    (50,50) -> (60,50)
## => 3 segments, 2 layers, 1 via, and TWO disconnected copper paths. The model
## must never merge these into one chain (that assumption is what bit the
## router). Expected after ingest: segments.size() == 3, vias.size() == 1,
## layers ["top","bottom","top"] (F.Cu/B.Cu canonicalised by PcbLayerStack).
func _multipad_reply() -> Dictionary:
	return {"routes": [{
		"net": "N7",
		"segments": [
			{"start": [0.0, 0.0], "end": [10.0, 0.0], "layer": "F.Cu"},
			{"start": [10.0, 0.0], "end": [10.0, 5.0], "layer": "B.Cu"},
			{"start": [50.0, 50.0], "end": [60.0, 50.0], "layer": "F.Cu"},
		],
		"vias": [[10.0, 0.0]],
	}]}


func _layers_of(c) -> Array:
	var out: Array = []
	for s in c.segments:
		out.append(str((s as Dictionary).get("layer", "")))
	return out


func _run_gate_multipad() -> void:
	print("-- 7. GATE: 3-pin multi-pad net, >=2 DISCONNECTED paths, model level --")
	var ws = PcbRoutingWorkspace.new()
	var cid: String = str(ws.ingest_routing_result(_multipad_reply(), [_hint("h7", "N7")], 4)[0])
	var c = ws.get_candidate(cid)

	check_eq("3 segments ingested (no chain merge)", c.segments.size(), 3)
	check_eq("1 via ingested", c.vias.size(), 1)
	check_eq("segment layers preserved per segment", _layers_of(c), ["top", "bottom", "top"])
	# The two paths genuinely do not touch: path 2's start shares no endpoint
	# with path 1's segments.
	var p2_start: Vector2 = (c.segments[2] as Dictionary).get("points")[0]
	var p1_end: Vector2 = (c.segments[1] as Dictionary).get("points")[1]
	check("path 2 is DISCONNECTED from path 1", p2_start != p1_end)
	check_eq("path 2 start is the hand-derived point", p2_start, Vector2(50, 50))

	# Segment ids are minted per segment — three independent entities.
	var seg_ids: Array = []
	for s in c.segments:
		seg_ids.append(str((s as Dictionary).get("id", "")))
	check_eq("three distinct segment ids", seg_ids, ["seg_1", "seg_2", "seg_3"])
	check_eq("the via got its own id", str((c.vias[0] as Dictionary).get("id", "")), "via_1")
	check("the via span is legal (top<->bottom)", c.all_via_spans_legal())

	# The disconnected topology survives the whole disposition lifecycle.
	check("pin the multi-pad candidate", ws.pin(cid))
	check("commit it", ws.mark_committed(cid, ["t1", "t2", "t3"], ["v1"]))
	check_eq("its task closed", ws.task_state(str(c.task_id)), "closed")
	check_eq("still 3 segments after commit", ws.get_candidate(cid).segments.size(), 3)
	check("uncommit it", ws.uncommit(cid))
	check_eq("its task reopened", ws.task_state(str(c.task_id)), "open")
	check_eq("still 3 segments after uncommit", ws.get_candidate(cid).segments.size(), 3)
	check_eq("segment layers still per-segment", _layers_of(ws.get_candidate(cid)), ["top", "bottom", "top"])

	# A rebase stales the CANDIDATE (one verdict for the whole candidate), and
	# leaves every segment and via in place — staleness never edits geometry.
	check_eq("rebase stales the multi-pad candidate", ws.rebase(5).size(), 1)
	check_eq("stale marking left all 3 segments", ws.get_candidate(cid).segments.size(), 3)
	check_eq("stale marking left the via", ws.get_candidate(cid).vias.size(), 1)
	check_eq("disposition preserved through the rebase", ws.get_candidate(cid).disposition, "pinned")

	# Round-trip: the disconnected shape survives serialisation.
	var reloaded = PcbRoutingWorkspace.from_dict(ws.to_sidecar_dict())
	var rc = reloaded.get_candidate(cid)
	check_eq("round-trip keeps 3 segments", rc.segments.size(), 3)
	check_eq("round-trip keeps per-segment layers", _layers_of(rc), ["top", "bottom", "top"])
	check_eq("round-trip keeps the via", rc.vias.size(), 1)
	check_eq("round-trip keeps the pin", rc.disposition, "pinned")


# ── 8. transient state is DELIBERATELY not persisted ──────────────────────────

func _run_transient_not_persisted() -> void:
	print("-- 8. _workspace_generation / board_token / board_revision RESET on load --")
	var ws = PcbRoutingWorkspace.new()
	ws.ingest_routing_result(_one_route("N1"), [_hint("h1", "N1")], 5)
	ws.board_token = "fingerprint-abc"
	ws.rebase(11)
	check("workspace_generation advanced in this session", int(ws.workspace_generation()) > 0)
	check_eq("board_token set", ws.board_token, "fingerprint-abc")
	check_eq("board_revision bound", int(ws.board_revision), 11)

	# The DURABLE shape must not carry any of the three.
	var durable: Dictionary = ws.to_sidecar_dict()
	for key in ["board_token", "workspace_generation", "_workspace_generation", "board_revision"]:
		check("to_sidecar_dict omits '%s'" % key, not durable.has(key))
	var full: Dictionary = ws.to_dict()
	for key in ["board_token", "workspace_generation", "_workspace_generation", "board_revision"]:
		check("to_dict omits '%s'" % key, not full.has(key))

	# ORACLE NOTE: the correct expectation is that these RESET, not that they
	# survive. They are runtime coherence tokens — a generation that survived a
	# load would let a pre-load draft-check reply be accepted against a
	# post-load candidate set, which is exactly the confusion the token exists
	# to prevent. A test asserting survival would encode the wrong contract.
	var loaded = PcbRoutingWorkspace.from_dict(durable)
	check_eq("workspace_generation RESETS to 0 on load", int(loaded.workspace_generation()), 0)
	check_eq("board_token RESETS to empty on load", loaded.board_token, "")
	check_eq("board_revision RESETS to 0 on load", int(loaded.board_revision), 0)
	check_eq("...while the candidates themselves DID survive", loaded.candidates.size(), 1)

	# Same for the derived reverse index and the transient UI selection, which
	# the shipped model already treats this way — asserted here so a future
	# "make it all persist" refactor trips this suite.
	check("to_sidecar_dict omits active_candidate_id", not durable.has("active_candidate_id"))
	check("to_sidecar_dict omits selected_finding_id", not durable.has("selected_finding_id"))


# ── 9. traps: high-water ids (SPARSE, never dense) + JSON floats ──────────────

func _run_id_high_water_and_json_floats() -> void:
	print("-- 9. traps: sparse ids restore to a HIGH-WATER MARK; JSON ints are floats --")
	# HAND-BUILT stored shape with SPARSE ids and a stale counter block, and
	# every int written as a JSON FLOAT (4.0 / 2.0) — exactly what a disk
	# round-trip produces. No "tasks" key: this is a legacy sidecar.
	var stored := {
		"candidates": {
			"cand_5": {
				"candidate_id": "cand_5", "task_id": "N1|h", "net": "N1",
				"generation": 2.0, "base_board_revision": 4.0, "candidate_revision": 0.0,
				"disposition": "proposed", "validation": "unchecked",
				"segments": [{"id": "seg_12", "layer": "top", "width": 0.3,
					"points": [{"x": 0.0, "y": 0.0}, {"x": 1.0, "y": 0.0}], "locked": false}],
				"vias": [], "source_hint_ids": ["h"], "endpoints": [],
			},
			"cand_9": {
				"candidate_id": "cand_9", "task_id": "N1|h", "net": "N1",
				"generation": 1.0, "base_board_revision": 4.0, "candidate_revision": 0.0,
				"disposition": "committed", "validation": "clean",
				"segments": [], "vias": [], "source_hint_ids": ["h"], "endpoints": [],
			},
		},
		"pinned": [],
		"counters": {"candidate": 0.0, "segment": 0.0, "via": 0.0},
	}
	var ws = PcbRoutingWorkspace.from_dict(stored)

	# HAND-DERIVED: the stored counters are 0, but the largest suffix actually
	# present is cand_9 / seg_12 — so the next ids are cand_10 and seg_13. Ids
	# are SPARSE (there is no cand_1..cand_4); nothing may assume otherwise.
	check_eq("candidate counter high-waters to the largest SCANNED suffix",
		ws.next_candidate_id(), "cand_10")
	check_eq("segment counter high-waters to the largest SCANNED suffix",
		ws.next_segment_id(), "seg_13")

	# int() normalisation: a float 4.0 from JSON must compare equal to int 4.
	var c5 = ws.get_candidate("cand_5")
	check_eq("base_board_revision loaded as int", typeof(c5.base_board_revision), TYPE_INT)
	check_eq("...with the right value", int(c5.base_board_revision), 4)
	check("not stale against its own revision (4.0 == 4 after the cast)",
		not c5.is_stale_for_board_revision(4))
	check("stale against a different revision", c5.is_stale_for_board_revision(5))
	check_eq("generation loaded as int", int(c5.generation), 2)

	# The legality gate works on SPARSE ids exactly as on dense ones.
	check("pin works on cand_5", ws.pin("cand_5"))
	check_eq("cand_5 is pinned", ws.get_candidate("cand_5").disposition, "pinned")
	check("reject on the COMMITTED cand_9 is refused (terminal), sparse id and all",
		not ws.reject("cand_9"))
	check_eq("cand_9 unchanged", ws.get_candidate("cand_9").disposition, "committed")

	# Task backfill on a legacy load: the task exists, and its derived state is
	# OPEN because cand_5 (live) outranks cand_9 (committed) — a task whose
	# question has been asked again is open even though copper exists.
	check_eq("legacy load backfilled exactly one task", ws.list_tasks().size(), 1)
	check_eq("backfilled task id", str(ws.list_tasks()[0].task_id), "N1|h")
	check_eq("derived state is open (a live candidate exists)", ws.task_state("N1|h"), "open")

	# Rebase over sparse ids marks the right ones and nothing else.
	var marked: Array = ws.rebase(6)
	check_eq("rebase marked both revision-4 candidates", marked.size(), 2)
	check_eq("cand_5 stale", ws.get_candidate("cand_5").validation, "stale")
	check_eq("cand_9 stale", ws.get_candidate("cand_9").validation, "stale")
	check_eq("cand_5 disposition preserved through the rebase",
		ws.get_candidate("cand_5").disposition, "pinned")
	check_eq("cand_9 disposition preserved through the rebase",
		ws.get_candidate("cand_9").disposition, "committed")


# ── 10. batch ingest HOLDS a pinned task; a targeted verb retires it ──────────
# The DCR's pin is a KEEP-OUT ("future routing routes AROUND it"), so a batch
# re-route must not quietly retire it. The distinction under test is
# BATCH-INGEST (no consent about this candidate ⇒ hold) vs TARGETED VERB (the
# user acting on THIS candidate ⇒ legal supersede). Both sides are asserted.

func _on_held(task_id: String, held_id: String, reason: String) -> void:
	_rec_held.append({"task_id": task_id, "held_candidate_id": held_id, "reason": reason})


func _run_ingest_vs_pinned() -> void:
	print("-- 10. ingest holds a pinned task; targeted supersede/unpin retires it --")
	_rec_held.clear()
	var ws = PcbRoutingWorkspace.new()
	ws.ingest_task_held.connect(_on_held)
	var hints := [_hint("h1", "N1")]
	var cid: String = str(ws.ingest_routing_result(_one_route("N1"), hints, 1)[0])
	var tid: String = str(ws.get_candidate(cid).task_id)   # HAND-DERIVED: "N1|h1"
	check("pin the candidate", ws.pin(cid))

	# ── SIDE A: batch ingest over a pinned task ──────────────────────────────
	var ids2: Array = ws.ingest_routing_result(_one_route("N1", 9.0), hints, 2)
	check_eq("batch ingest created NO candidate for the held task", ids2.size(), 0)
	check_eq("the pinned candidate is UNTOUCHED", ws.get_candidate(cid).disposition, "pinned")
	check("...and is still in the pinned (keep-out) set", ws.is_pinned(cid))
	check_eq("the workspace still holds exactly 1 candidate", ws.list_candidates().size(), 1)
	check_eq("the hold is queryable", ws.last_ingest_holds.size(), 1)
	var hold: Dictionary = ws.last_ingest_holds[0]
	check_eq("hold names the task", str(hold.get("task_id", "")), tid)
	check_eq("hold names the held candidate", str(hold.get("held_candidate_id", "")), cid)
	check_eq("hold names the net", str(hold.get("net", "")), "N1")
	check_eq("hold carries the NAMED reason", str(hold.get("reason", "")), PcbRoutingWorkspace.HOLD_PINNED)
	check_eq("hold announced exactly once", _rec_held.size(), 1)
	check_eq("...with the same reason on the signal",
		str((_rec_held[0] as Dictionary).get("reason", "")), PcbRoutingWorkspace.HOLD_PINNED)
	check_eq("the held task stays OPEN", ws.task_state(tid), "open")

	# A MULTI-NET batch: the held task is skipped, every other net still lands.
	var multi := {"routes": [
		{"net": "N1", "segments": [{"start": [0.0, 0.0], "end": [4.0, 0.0], "layer": "F.Cu"}], "vias": []},
		{"net": "N2", "segments": [{"start": [0.0, 0.0], "end": [6.0, 0.0], "layer": "F.Cu"}], "vias": []},
	]}
	var hints_multi := [_hint("h1", "N1"), _hint("h2", "N2")]
	var ids3: Array = ws.ingest_routing_result(multi, hints_multi, 3)
	check_eq("the UNHELD net still landed", ids3.size(), 1)
	check_eq("...and it is net N2", str(ws.get_candidate(str(ids3[0])).net), "N2")
	check_eq("exactly one hold for this call", ws.last_ingest_holds.size(), 1)
	check_eq("holds are PER CALL, not accumulated",
		str((ws.last_ingest_holds[0] as Dictionary).get("net", "")), "N1")
	check_eq("two holds announced in total so far", _rec_held.size(), 2)

	# ── SIDE B: targeted Try-again on THAT candidate ─────────────────────────
	check("supersede() on a pinned candidate is LEGAL (targeted verb)", ws.supersede(cid))
	check_eq("the pinned candidate retired", ws.get_candidate(cid).disposition, "superseded")
	check("...and left the pinned keep-out set", not ws.is_pinned(cid))
	var ids4: Array = ws.ingest_routing_result(_one_route("N1", 11.0), hints, 4)
	check_eq("the next ingest now creates the replacement", ids4.size(), 1)
	check_eq("no hold this time", ws.last_ingest_holds.size(), 0)
	# HAND-DERIVED: the retired pin was generation 1, so its replacement is 2.
	check_eq("generation chained past the retired pin",
		int(ws.get_candidate(str(ids4[0])).generation), 2)

	# UNPIN is the other targeted route back to a replaceable task.
	var ws2 = PcbRoutingWorkspace.new()
	var b_hints := [_hint("h3", "N3")]
	var b: String = str(ws2.ingest_routing_result(_one_route("N3"), b_hints, 1)[0])
	check("pin it", ws2.pin(b))
	check_eq("held while pinned",
		ws2.ingest_routing_result(_one_route("N3", 8.0), b_hints, 2).size(), 0)
	check("unpin it", ws2.unpin(b))
	var ids5: Array = ws2.ingest_routing_result(_one_route("N3", 8.0), b_hints, 3)
	check_eq("after unpin the batch ingest replaces normally", ids5.size(), 1)
	check_eq("the unpinned prior was superseded", ws2.get_candidate(b).disposition, "superseded")
	check_eq("no hold recorded once nothing is pinned", ws2.last_ingest_holds.size(), 0)
