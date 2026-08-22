extends RefCounted
## RoutingWorkspace — owns the set of RouteCandidates for a routing session plus
## the selection/pin state a routing UI needs. This is the FOUNDATION domain
## model (T1); canvas, verbs, worker calls and annotation wiring land in later
## tasks and are STUBBED here with correct signatures.
##
## ── Stable-id generation ──────────────────────────────────────────────────────
## Ids are workspace-scoped monotonic counters: "cand_1", "seg_1", "via_1". They
## are deterministic (no random/time) so tests are reproducible. from_dict()
## restores each counter to a HIGH-WATER MARK — the max of the stored counter and
## the largest numeric suffix actually present in the loaded ids — so ids minted
## after a load can never collide with loaded ones.
##
## ── C1 completion: what this file now OWNS ────────────────────────────────────
## 1. DISPOSITION LEGALITY. Every workflow verb (pin/unpin/reject/mark_committed
##    /ingest-supersede) funnels through _apply_disposition, which consults
##    PcbRouteCandidate's DISPOSITION_TRANSITIONS table and REFUSES an illegal
##    move with a named error (last_transition_error + transition_refused +
##    push_warning) instead of silently applying it. uncommit is the single
##    COMPENSATING exit from "committed" and does not go through the table.
## 2. ROUTE TASKS. `tasks` is the registry of routing JOBS (net + optional SPAN
##    scope) with an open/closed lifecycle DERIVED from the candidate set. A
##    PINNED active candidate HOLDS its task against batch ingest (the pin is
##    the user's keep-out); only a targeted verb retires it.
## 3. BOARD-REVISION STALENESS. rebase(rev) binds the workspace to a board
##    revision and marks candidates whose base_board_revision differs
##    validation="stale" (disposition preserved) — per candidate, not all.
##
## Off-tree plugin: NO class_name; relative preload + duck typing.

const _Self := preload("pcb_routing_workspace.gd")
const PcbRouteCandidate := preload("pcb_route_candidate.gd")
## Two points closer than this were AUTHORED to be the same point. The value
## is the connectivity kernel's own COPPER_COINCIDENT_EPS_MM (drc.py:76), for
## the same reason it gives: coincidence here is an authoring-identity
## question, not a clearance one.
##
## It cannot go lower. Vector2 is single-precision, so at real board
## coordinates (~75mm) one float32 ulp is already ~7.6e-6 mm — a threshold
## below that would fail to recognise two points the author wrote identically
## but that round-tripped through a float32 differently. It cannot sensibly go
## higher either: 1e-3 mm is a hundredth of the narrowest manufacturable
## trace, so nothing this collapses was ever going to be fabricated.
const COPPER_COINCIDENT_EPS_MM := 1e-3


## Drop consecutive points that are the same point, so a run of them collapses
## to the one point it draws. Returns the points that actually describe copper.
##
## A zero-length segment is not harmless geometry — it is UNCOMPILABLE. The
## worker refuses the whole board with trace_degenerate, which takes geometric
## DRC, the routing IR and promotion down with it, and the board stays that way
## until the trace is found and removed by hand.
static func drop_coincident_points(points: Array) -> Array:
	var out: Array = []
	for p in points:
		if not (p is Vector2):
			continue
		if out.is_empty() or (out[out.size() - 1] as Vector2).distance_to(p) > COPPER_COINCIDENT_EPS_MM:
			out.append(p)
	return out
const PcbRouteTask := preload("pcb_route_task.gd")
const PcbLayerStack := preload("pcb_layer_stack.gd")

## Emitted when a candidate is inserted.
signal candidate_added(id: String)
## Emitted when a candidate's disposition/geometry changes (pin/unpin/reject/edit).
signal candidate_changed(id: String)
## Emitted when a candidate is removed.
signal candidate_removed(id: String)
## Emitted when the active candidate changes.
signal active_candidate_changed(id: String)
## Emitted when a candidate's validation axis changes.
signal validation_changed(id: String)
## Emitted when a disposition move is REFUSED by the legality table. `error` is
## the named code from PcbRouteCandidate (unknown_disposition /
## terminal_disposition / illegal_disposition_transition / not_committed).
signal transition_refused(id: String, from: String, to: String, error: String)
## Emitted when a RouteTask's open/closed state changes.
signal task_state_changed(task_id: String, state: String)
## Emitted when an INGEST declines to replace a task's active candidate. Today
## the one reason is HOLD_PINNED — see the ingest policy on
## _create_candidate_for_route. The panel surfaces this ("task X held: pinned
## candidate kept") so a batch re-route that silently changed nothing for a task
## is never invisible.
signal ingest_task_held(task_id: String, held_candidate_id: String, reason: String)

## Named ingest-hold reason: the task's active candidate is PINNED, so the
## incoming batch candidate was not created.
const HOLD_PINNED := "pinned_candidate_held"

## Named ingest-hold reason (Epoch UX3, K7): the task's active candidate is
## FROZEN — settled geometry holds its task against batch ingest exactly as a
## pin does, and MORE: unlike a pin, even a targeted supersede is refused (the
## legality table has no frozen → superseded row). Unfreeze first.
const HOLD_FROZEN := "frozen_candidate_held"

## candidate_id -> RouteCandidate.
var candidates: Dictionary = {}
## task_id -> RouteTask. The registry of routing JOBS (the questions) beside the
## candidates (the answers). Populated by ingest via ensure_task(); a task's
## open/closed state is DERIVED from its candidates (see _refresh_task_state).
## Persisted (design intent: which nets/spans still need copper), and backfilled
## from the candidate set when loading a sidecar written before tasks existed.
var tasks: Dictionary = {}
## The candidate the UI is focused on ("" = none).
var active_candidate_id: String = ""
## Set of pinned candidate ids (Dictionary used as a set: id -> true).
var pinned: Dictionary = {}
## Set of FROZEN candidate ids (Epoch UX3, K7/K8) — the same derived-index
## pattern as `pinned` (see _sync_held_indexes): disposition is the authority,
## this is the O(1) read the keep-out wire and the UI consult.
var frozen: Dictionary = {}
## The finding the UI has selected ("" = none).
var selected_finding_id: String = ""

## Stored findings per candidate (candidate_id -> Array). Populated by validation
## in a later task; empty for now.
var _findings: Dictionary = {}

## Monotonic id counters (last-issued number; next id is counter+1).
var _cand_counter: int = 0
var _seg_counter: int = 0
var _via_counter: int = 0

## T2 (S2.2) idempotent-replace bookkeeping: task_key -> the CURRENT (non-
## superseded) candidate_id answering that task. In-memory only — NOT part of
## to_dict/load_from_dict (persistence is T2a; the shadow workspace lives in
## memory this round, so this index does not need to survive a save/load yet).
var _task_candidate: Dictionary = {}

## ── T2.3 shadow-parity CORRELATION (candidate ↔ annotation) ────────────────────
## The single record that ties a RouteCandidate to the annotation PROPOSAL it was
## dual-written alongside, so the two shadow stores can never be independently
## mutated into divergence:
##   candidate_id -> {
##     "annotation_id":       String,   # the proposal annotation this mirrors
##     "task_id":             String,   # candidate.task_id at correlation time
##     "generation":          int,      # candidate.generation at correlation time
##     "committed_trace_ids": Array,    # stable PCBData trace ids from commit
##     "committed_via_ids":   Array,    # stable PCBData via ids from commit
##     "prior_disposition":   String,   # disposition BEFORE commit (for uncommit)
##   }
## The committed_* ids live HERE (not on the candidate) because pcb_route_candidate
## .gd is out of this task's fence — and it keeps the ResolvedBoard-IR copper
## references in one durable place the sidecar already persists. Persisted through
## to_dict/to_sidecar_dict and restored in load_from_dict; _annotation_to_candidate
## is the derived reverse index (rebuilt on load, never serialised).
var correlations: Dictionary = {}
var _annotation_to_candidate: Dictionary = {}

## ── T2.4 draft-check coherence state (TRANSIENT — never persisted) ─────────────
## workspace_generation: a monotonic counter bumped on ANY candidate-set change
## (add/remove/ingest/supersede + disposition changes that alter the live set).
## It is the SECOND coherence token draft_check echoes (alongside board_token):
## if the set drifted between begin_check and apply_check_result, the generation
## differs and the whole reply is discarded. It is RUNTIME state — it starts at
## 0 on a fresh instance and ADVANCES when an existing instance loads another
## workspace, invalidating replies still in flight from the prior document. It is
## DELIBERATELY absent from to_dict/to_sidecar_dict (the durable sidecar guards
## coherence with the board fingerprint, not this process-local epoch).
var _workspace_generation: int = 0

## The current board coherence token (compute_board_fingerprint of the live
## board). The workspace is a pure model with no PCBData dependency, so the OWNER
## (PCBPanel) sets this before begin_check and keeps it current; begin_check
## stamps it into the request and apply_check_result compares the echoed value
## against it. Transient — never persisted.
var board_token: String = ""

## ── C1: the board REVISION this workspace is currently bound to ───────────────
## TRANSIENT, exactly like board_token above: the OWNER (PCBPanel) binds it, it
## is DELIBERATELY absent from to_dict/to_sidecar_dict, and it resets to 0 on a
## fresh session/load. Per-candidate staleness is `candidate.base_board_revision
## != board_revision` (PcbRouteCandidate.is_stale_for_board_revision).
##
## Ingest deliberately does NOT write this: staling the set is an explicit REBASE
## decision (rebase()), never a side effect of proposing a route — otherwise a
## multi-net propose at a newer revision would silently quarantine candidates the
## user never touched.
var board_revision: int = 0

## The HOLDS from the most recent ingest call (reset at the start of every
## ingest_routing_result / ingest_record): [{task_id, held_candidate_id, net,
## reason}, …]. Empty when the ingest replaced/created everything it was given.
var last_ingest_holds: Array = []

## How many segments the most recent geometry-building call dropped because
## their two ends were the same point. Reset at the start of each of the three
## (ingest_routing_result, ingest_record, sync_candidate_geometry), same
## per-call convention as last_ingest_holds above.
##
## Almost always 0: a router emitting a zero-length segment is a router bug.
## The count exists so the drop is REPORTABLE rather than silent — dropping is
## the right thing (that segment draws nothing, and committing it makes the
## whole board uncompilable), but doing it without a trace would hide the
## upstream bug that produced it.
var last_ingest_degenerate_segments: int = 0

## F4 (cold review, Epoch UX1 station 9): CONFLICTING routing_constraints
## found by _absorb_eager_tasks_for_merge during the most recent
## ingest_record call — reset at the START of every ingest_record, same
## per-call convention as last_ingest_holds above. [{task_ids, reason}, …],
## empty on the overwhelming common case (no merge happened, or the merge's
## absorbed tasks never conflicted). Since P1-A (Codex 1047) a conflict no
## longer DROPS anything — the constrained singletons survive un-absorbed
## and keep steering their own hints per-hint — but the merged task is left
## unconstrained, and that outcome still reaches the caller here: panel_
## tools.gd's _ingest_result_into_workspace reads this alongside
## last_ingest_holds and threads it into the reply as `constraint_conflicts`
## — a merge outcome visible only as a push_warning nobody outside the
## engine console ever sees was the defect this exists to close.
var last_ingest_constraint_conflicts: Array = []

## Codex 1047 fix round, verdict 6: the STRUCTURED records from the most recent
## load-time supersession reconciliation pass (panel_tools.gd's
## reconcile_superseded_waypoint_state — written by that pass, reset at its
## start, the same per-call convention as last_ingest_holds /
## last_ingest_constraint_conflicts above, and the same "structured record, not
## push_warning prose, is the supported contract" idiom F4 established for
## constraint conflicts). One entry per TORN two-store state the pass repaired:
## [{hint_id, task_id, action: "restamped_marker"|"released_stale_marker",
##   reason: "constraint_without_marker"|"marker_out_of_shape"|
##           "marker_without_constraint", constraint_revision?}, …]
## Empty on the overwhelming common case: the annotations sidecar and this
## workspace's sidecar loaded mutually consistent. TRANSIENT — deliberately
## absent from to_dict/to_sidecar_dict (it describes what THIS load repaired,
## not durable design state), and running the pass again on the repaired
## stores must leave it empty (the pass's own idempotence contract).
var last_load_reconciliation: Array = []

## The most recent REFUSED disposition move (empty when the last one was legal):
## {"candidate_id","from","to","error","verb"}. Kept so a UI/tool caller that
## only sees a `false` return can still report WHY without re-deriving it.
var last_transition_error: Dictionary = {}

## In-flight begin_check snapshot: candidate_id -> {"revision": int,
## "prior": String}. Captured when begin_check flips a candidate to "checking"
## so apply_check_result can (a) detect a per-candidate revision drift and
## (b) revert a discarded candidate to exactly the validation it had before.
var _pending_check: Dictionary = {}


## The current workspace generation (read-only accessor for the owner/tests).
func workspace_generation() -> int:
	return _workspace_generation


## Bump the generation on any candidate-set change. Kept private + called from
## every set-mutating op so a stale draft-check reply is always caught.
func _bump_generation() -> void:
	_workspace_generation += 1


# ── id minting ────────────────────────────────────────────────────────────────

func next_candidate_id() -> String:
	_cand_counter += 1
	return "cand_%d" % _cand_counter


func next_segment_id() -> String:
	_seg_counter += 1
	return "seg_%d" % _seg_counter


func next_via_id() -> String:
	_via_counter += 1
	return "via_%d" % _via_counter


# ── real ops (pure state) ─────────────────────────────────────────────────────

## Insert a candidate. Mints a candidate_id if absent, and mints seg_/via_ ids for
## any segment/via lacking one, so every stored entity has a stable workspace id.
## Emits candidate_added. Returns the candidate_id.
func add_candidate(candidate) -> String:
	if str(candidate.candidate_id).is_empty():
		candidate.candidate_id = next_candidate_id()
	for seg in candidate.segments:
		if seg is Dictionary and str(seg.get("id", "")).is_empty():
			seg["id"] = next_segment_id()
	for via in candidate.vias:
		if via is Dictionary and str(via.get("id", "")).is_empty():
			via["id"] = next_via_id()
	var id: String = candidate.candidate_id
	candidates[id] = candidate
	_sync_held_indexes(id, str(candidate.disposition))
	# Every candidate answers a task — keep the registry complete even for
	# hand-built candidates (ingest has already ensured its own task).
	var tid := str(candidate.task_id)
	if not tid.is_empty():
		ensure_task(tid, str(candidate.net))
		_refresh_task_state(tid)
	_bump_generation()  # candidate-set grew → any in-flight draft-check is stale
	candidate_added.emit(id)
	return id


func get_candidate(id: String):
	return candidates.get(id, null)


## All candidates (insertion order of the backing dict).
func list_candidates() -> Array:
	return candidates.values()


## Non-superseded candidates for a task_id — the task's CURRENT-generation
## set. A re-ingest for the same task (see ingest_routing_result's
## idempotent-replace) supersedes the prior candidate rather than removing
## it, so `candidates` can hold >1 entry per task; this is "how many are
## LIVE for this task" without callers re-deriving the disposition filter.
func candidates_for_task(task_id: String) -> Array:
	var out: Array = []
	for c in candidates.values():
		if str(c.task_id) == task_id and c.disposition != "superseded":
			out.append(c)
	return out


func remove_candidate(id: String) -> void:
	if not candidates.has(id):
		return
	var task_id := str(candidates[id].task_id)
	candidates.erase(id)
	pinned.erase(id)
	frozen.erase(id)
	_findings.erase(id)
	# Drop the correlation (both directions) so a removed candidate never leaves a
	# dangling annotation↔candidate link behind.
	var rec: Dictionary = correlations.get(id, {})
	var ann := str(rec.get("annotation_id", ""))
	if not ann.is_empty() and str(_annotation_to_candidate.get(ann, "")) == id:
		_annotation_to_candidate.erase(ann)
	correlations.erase(id)
	# The task survives the candidate (it is the question, not the answer) but
	# its derived state may have moved — e.g. removing the only committed
	# candidate reopens it. The task is NOT deleted even when its last candidate
	# goes: an unanswered task is exactly what "open" means.
	_refresh_task_state(task_id)
	_bump_generation()  # candidate-set shrank → any in-flight draft-check is stale
	if active_candidate_id == id:
		active_candidate_id = ""
		active_candidate_changed.emit("")
	candidate_removed.emit(id)


## Focus a candidate. Emits active_candidate_changed.
func set_active(id: String) -> void:
	active_candidate_id = id
	active_candidate_changed.emit(id)


# ── the ONE disposition write path (legality-gated) ───────────────────────────

## Move a candidate's disposition through the legality table. THE single funnel:
## every workflow verb below (pin/unpin/reject/mark_committed, and ingest's
## supersede) goes through here, so there is exactly one place that (a) consults
## PcbRouteCandidate.DISPOSITION_TRANSITIONS, (b) keeps the `pinned` index in
## sync, (c) refreshes the owning task's open/closed state, (d) bumps the
## workspace generation, and (e) emits.
##
## Returns true when applied. On refusal: the candidate is UNCHANGED, the named
## error is recorded in last_transition_error, transition_refused is emitted, a
## push_warning names the code, and false is returned — no silent clamp.
## `verb` is the caller's own name, carried into the error record for the UI.
func _apply_disposition(id: String, to: String, verb: String, from_transaction := false) -> bool:
	var c = get_candidate(id)
	if c == null:
		return false
	var from := str(c.disposition)
	# REENTRANCY GUARD (docket 019fd0ab6dd2, Codex re-review 1032):
	# "synchronous" does not mean "non-reentrant" — candidate_changed /
	# validation_changed handlers execute synchronously DURING commit_batch's
	# disposition phase, and a handler that calls pin/reject/supersede/… would
	# mutate a later batch member before the transaction reaches it, making
	# the phase-B refusal branch reachable through the public signal surface.
	# Every disposition move funnels through here, so ONE check makes the
	# policy: while a commit transaction is applying, every mutating verb that
	# is not the transaction's own call REFUSES BY NAME. The supported
	# contract for signal handlers during a commit is observe-and-redraw, not
	# mutate — this guard is that contract, enforced.
	if _commit_transaction_active and not from_transaction:
		_record_refusal(id, from, to, ERR_COMMIT_IN_PROGRESS, verb)
		return false
	var err: String = c.transition_to(to)
	if not err.is_empty():
		_record_refusal(id, from, to, err, verb)
		return false
	if from == to:
		# Identity no-op: nothing moved, so nothing to invalidate or announce
		# beyond keeping the derived indexes honest. The move was LEGAL, so the
		# error record clears exactly as it does on any other legal move (the
		# record means "the LAST move was refused", not "a move happened").
		last_transition_error = {}
		_sync_held_indexes(id, to)
		return true
	last_transition_error = {}
	_sync_held_indexes(id, to)
	_refresh_task_state(str(c.task_id))
	_bump_generation()  # the live set moved → any in-flight draft-check is stale
	# INV-2 (C4a), live-set half. A move ACROSS the live/terminal boundary
	# changes the set draft_check scores, so every candidate that is live
	# afterwards loses its verdict. A move WITHIN the live set (pin/unpin) does
	# not — see the rule on VERDICT_VALIDATIONS for why that is a decision and
	# not an omission.
	#
	# BATCH SUPPRESSION (docket 019fd0ab6dd2, Codex review P1): inside
	# commit_batch's disposition phase the pass is DEFERRED, not skipped —
	# member A's commit would otherwise stale members B..N of the same
	# approved batch and erase their findings mid-transaction. commit_batch
	# runs ONE _stale_live_verdicts() after every member has left the live
	# set, so exactly the candidates OUTSIDE the batch are staled, order-
	# independently. The flag is private and only ever set around that
	# synchronous phase (no awaits), so no other verb can observe it.
	if _is_live_disposition(from) != _is_live_disposition(to):
		if _defer_stale_pass:
			_deferred_stale_needed = true
		else:
			_stale_live_verdicts()
	candidate_changed.emit(id)
	return true


## Is this disposition one that keeps a candidate in the LIVE routing set? The
## single predicate behind live_candidate_ids() and the INV-2 boundary test, so
## the two can never disagree about what "live" means.
static func _is_live_disposition(disposition: String) -> bool:
	return not (disposition in ["superseded", "rejected", "committed"])


func _record_refusal(id: String, from: String, to: String, err: String, verb: String) -> void:
	last_transition_error = {
		"candidate_id": id, "from": from, "to": to, "error": err, "verb": verb,
	}
	push_warning("[RoutingWorkspace] %s refused: %s (%s -> %s) on %s" % [verb, err, from, to, id])
	transition_refused.emit(id, from, to, err)


## `pinned` and `frozen` are DERIVED indexes of the disposition axis, not
## independent stores — so a candidate that LEAVES the pinned/frozen
## disposition (superseded by a re-propose, rejected, committed, demoted) also
## leaves its held set. That matters beyond tidiness: the held sets are what
## future routing treats as keep-outs, and a superseded/committed candidate
## must stop acting as one.
func _sync_held_indexes(id: String, disposition: String) -> void:
	if disposition == "pinned":
		pinned[id] = true
	else:
		pinned.erase(id)
	if disposition == "frozen":
		frozen[id] = true
	else:
		frozen.erase(id)


## True iff `to` is a legal move for this candidate right now (UI verb gating).
func can_transition(id: String, to: String) -> bool:
	var c = get_candidate(id)
	if c == null:
		return false
	return c.can_transition_to(to)


## Pin a candidate: disposition=pinned (and the derived pinned-set entry).
## Returns false (with a named refusal) when the move is illegal.
func pin(id: String) -> bool:
	return _apply_disposition(id, "pinned", "pin")


## Unpin a candidate: revert disposition to proposed (drops the pinned entry).
## Unpinning an already-proposed candidate is a legal no-op; unpinning a
## terminal one (superseded/rejected/committed) is REFUSED — it would resurrect
## geometry that has left the live set.
func unpin(id: String) -> bool:
	return _apply_disposition(id, "proposed", "unpin")


func is_pinned(id: String) -> bool:
	return pinned.has(id)


## FREEZE a candidate (Epoch UX3, K7 — the missing loop verb): the user
## declares this geometry SETTLED. It stays a live draft (checked, rendered)
## but future routing treats it as fixed copper, batch ingest holds its task
## (HOLD_FROZEN), and — the teeth — reject/supersede/geometry-edit are refused
## while frozen. Legal from proposed and pinned.
func freeze(id: String) -> bool:
	return _apply_disposition(id, "frozen", "freeze")


## UNFREEZE a candidate: the deliberate demotion back to a plain draft
## (proposed). The ONLY way to make a frozen candidate rejectable/supersedable/
## editable again — destroying settled work is always this visible two-step.
func unfreeze(id: String) -> bool:
	return _apply_disposition(id, "proposed", "unfreeze")


func is_frozen(id: String) -> bool:
	return frozen.has(id)


## HELD (pinned + frozen) candidates in the wire shape route_bridge.
## existing_copper_with_pinned / ir_candidates.build_overlay accept — the SAME
## candidate language begin_check above already speaks (see _candidate_wire),
## reused rather than invented a second time (DCR finding 7, part 1: "the hold
## protects the CANDIDATE; it does not yet protect the SPACE"). A caller hands
## this straight through as the route request's `pinned_candidates` param and
## the router treats every one as fixed copper — an obstacle at keepout margin
## on another net, pathable-along on its own — so a future run routes AROUND a
## held candidate instead of through it.
##
## FROZEN candidates ride the SAME wire key (Epoch UX3, K8): "frozen geometry
## honored exactly as committed copper" is precisely what the worker already
## does with every entry in `pinned_candidates`, so the obstacle half of freeze
## is this one union — no second wire param, no worker change, no second code
## path that could drift from the proven one.
##
## `pinned`/`frozen` are DERIVED indexes of the disposition axis
## (_sync_held_indexes), so the union already excludes superseded/rejected/
## committed candidates: a routing run's keep-out set is exactly "what the user
## is still holding right now", never stale or dead geometry. Empty when
## nothing is held — the caller omits the `pinned_candidates` key entirely in
## that case (see panel_tools.gd _route_request_extra), which is what "no hold"
## already means to the worker.
func keepout_candidates_wire() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for held_set in [pinned, frozen]:
		for id in held_set:
			var cid := str(id)
			if seen.has(cid):
				continue
			seen[cid] = true
			var c = get_candidate(cid)
			if c == null:
				continue
			out.append(_candidate_wire(cid, c))
	return out


## TARGETED Try-again: supersede THIS candidate, by the user's explicit act on
## it. This is the verb that legally retires a PINNED candidate — batch ingest
## deliberately will not (see the ingest policy on _create_candidate_for_route):
## acting on a specific candidate is consent about that candidate; a whole-board
## re-route is not.
func supersede(id: String) -> bool:
	return _apply_disposition(id, "superseded", "supersede")


## Reject a candidate: disposition=rejected. Per the DCR, rejecting discards the
## candidate and REOPENS the task (handled by _refresh_task_state — the task
## returns to open unless some other candidate for it is committed).
func reject(id: String) -> bool:
	return _apply_disposition(id, "rejected", "reject")


# ── RouteTask registry: scope (net + optional span) + open/closed lifecycle ────
# A task is the QUESTION ("route net N", or "reroute just this span"); a
# candidate is an ANSWER. State is DERIVED from the answers, never stored
# free-standing, so the two can never disagree:
#
#   CLOSED ⇔ the task's current answer is committed copper: at least one
#            COMMITTED candidate AND no LIVE (proposed/pinned) one.
#   OPEN   ⇔ anything else — never routed, superseded/rejected only, or
#            committed-but-re-proposed (the user is asking again).
#
# Consequences that fall out for free, matching the DCR vocabulary: Accept
# closes the task; a board undo + uncommit reopens it; Reject reopens it
# (rejecting is not committing); Try-again keeps it open across the supersede.

## Get-or-create the task with this id. An existing task is returned untouched
## except that a still-unknown net/span is filled in (ingest learns the net; a
## legacy backfill may not have had the span). Never overwrites a known scope.
func ensure_task(task_id: String, net: String = "", span: Dictionary = {}):
	if task_id.is_empty():
		return null
	var t = tasks.get(task_id, null)
	if t == null:
		t = PcbRouteTask.new()
		t.task_id = task_id
		t.net = net
		t.span = span.duplicate(true)
		tasks[task_id] = t
		return t
	if str(t.net).is_empty() and not net.is_empty():
		t.net = net
	if (t.span as Dictionary).is_empty() and not span.is_empty():
		t.span = span.duplicate(true)
	return t


func get_task(task_id: String):
	return tasks.get(task_id, null)


func list_tasks() -> Array:
	return tasks.values()


## The task whose key attribution ("<net>|<hint_ids>[|span:...]", see
## _task_key/_task_key_hint_set) includes `hint_id` — station 9's (DCR
## 019fd095e694) propose-time lookup: "does the task this hint would answer
## already carry a routing_constraint", asked BEFORE any candidate exists (so
## a candidate's own task_id, available everywhere else, is not yet an
## option). Mirrors drop_empty_tasks_for_hint's own key-parsing rather than
## re-deriving the format a second place.
##
## F11 (cold review): the task whose key names `hint_id` as its ONLY hint
## (the exact singleton "<net>|hint_id" shape) is preferred over any task
## that merely MEMBERS `hint_id` among others (a merged multi-hint key) — an
## exact match is unambiguous ownership, a membership match is not, and the
## two should never both exist for one hint in practice (H3-1 absorption
## folds the singleton into the merge), but preferring the exact match keeps
## this lookup correct even if that invariant is ever violated, rather than
## depending on dict iteration order to happen to find the right one first.
## Membership is still returned as a FALLBACK when no exact singleton exists
## — H3-1 absorption keeps a hint attributed to at most one open task in
## practice, so that fallback is what ordinarily fires for a merged task's
## member hints. Returns null when `hint_id` names no task at all (the common
## case: most hints carry no corridor).
func task_for_hint(hint_id: String):
	if hint_id.is_empty():
		return null
	var fallback = null
	for tid in tasks:
		var hint_set: Array = _task_key_hint_set(str(tid))
		if hint_set.size() == 1 and str(hint_set[0]) == hint_id:
			return tasks[tid]
		if fallback == null and hint_id in hint_set:
			fallback = tasks[tid]
	return fallback


## F3 (cold review): the hint ids `task_id`'s own key names — [] for an
## unknown task_id or one with no hint attribution, [hint_id] for the common
## single-hint case, [hidA, hidB, ...] for a merged multi-hint task (H3-1
## absorption). Public wrapper over the private _task_key_hint_set parser so
## callers outside this file (panel_tools.gd's steering path — F3's
## multi_span_task refusal) never re-derive the "<net>|<hint_ids>[|span:...]"
## key format themselves.
func task_hint_ids(task_id: String) -> Array:
	return _task_key_hint_set(task_id)


## H2-1 (cold review, DCR 019fd095e694/docket 019fd057ea0b comment 1028's
## deletion-cascade precondition): drop every CANDIDATE-LESS task whose key
## names `hint_id` as its ONLY hint attribution — the shape
## minerva_pcb_add_route_intent's eager task takes ("net|hint_id"), or a
## merged multi-hint task that has collapsed back down to exactly this one
## hint after H3-1 absorption removed every other member. Called by
## PcbAnnotationHost when the pcb_route_hint annotation for `hint_id` is
## removed — deleting the connectivity object for a still-unanswered intent
## should not leave a dead task sitting in the workspace forever. A task any
## candidate has ever landed on is HISTORY, deleted annotation or not, and is
## left untouched — only the candidate-less placeholder disappears. Returns
## the dropped task ids.
func drop_empty_tasks_for_hint(hint_id: String) -> Array:
	var dropped: Array = []
	if hint_id.is_empty():
		return dropped
	for tid in tasks.keys().duplicate():
		var key := str(tid)
		var hints: Array = _task_key_hint_set(key)
		if hints.size() != 1 or str(hints[0]) != hint_id:
			continue
		if _task_has_any_candidate(key):
			continue
		tasks.erase(key)
		_task_candidate.erase(key)
		dropped.append(key)
	return dropped


## "open" / "closed", or "" when the task is unknown.
func task_state(task_id: String) -> String:
	var t = get_task(task_id)
	return str(t.state) if t != null else ""


func is_task_open(task_id: String) -> bool:
	return task_state(task_id) == "open"


func open_task_ids() -> Array:
	var out: Array = []
	for tid in tasks:
		if tasks[tid].is_open():
			out.append(str(tid))
	return out


func closed_task_ids() -> Array:
	var out: Array = []
	for tid in tasks:
		if not tasks[tid].is_open():
			out.append(str(tid))
	return out


## Re-derive one task's state from its candidates (see the section header).
## Emits task_state_changed ONLY on an actual change.
func _refresh_task_state(task_id: String) -> void:
	var t = get_task(task_id)
	if t == null:
		return
	var has_live := false
	var has_committed := false
	for id in candidates:
		var c = candidates[id]
		if str(c.task_id) != task_id:
			continue
		var d := str(c.disposition)
		# THE live predicate, not a re-enumeration (cold review, Epoch UX3
		# station 1, finding 1): a hand-listed pair here silently went stale
		# when "frozen" joined the live set — freezing the re-proposed answer
		# on a committed-then-reasked task flipped it CLOSED with settled work
		# outstanding. One predicate, every consumer.
		if d == "committed":
			has_committed = true
		elif _is_live_disposition(d):
			has_live = true
	var want := "closed" if (has_committed and not has_live) else "open"
	if str(t.state) == want:
		return
	t.state = want
	task_state_changed.emit(task_id, want)


## Re-derive EVERY task's state. For owners that mutated candidates in bulk.
func refresh_task_states() -> void:
	for tid in tasks:
		_refresh_task_state(str(tid))


## Set a candidate's validation axis + emit validation_changed. Leaves the
## disposition axis untouched (orthogonality is enforced in RouteCandidate).
func set_validation(id: String, value: String) -> void:
	var c = get_candidate(id)
	if c == null:
		return
	c.validation = value
	validation_changed.emit(id)


## Stored findings for a candidate (empty until a later task populates them).
func findings_for_candidate(id: String) -> Array:
	return _findings.get(id, [])


# ── T2.4 draft-check state machine (IPC-decoupled) ────────────────────────────
# The reusable NATIVE draft-check seam T5 depends on. It is split so it can be
# tested WITHOUT the worker: begin_check() builds a plain request payload and
# apply_check_result() consumes a plain reply dict. PCBPanel.check_draft() wires
# the two ends to the pcb.draft_check broker channel; here there is no IPC.
# ON-DEMAND only — no debounce/coalescing/cancellation/auto-recheck (that is T6).

## Candidate ids whose disposition keeps them in the LIVE routing set (i.e. NOT
## superseded/rejected/committed) — the default scope of a draft check.
func live_candidate_ids() -> Array:
	var out: Array = []
	for id in candidates:
		var c = candidates[id]
		if not _is_live_disposition(str(c.disposition)):
			continue
		out.append(str(id))
	return out


## Begin an ON-DEMAND draft check. Flips the target candidates to
## validation="checking" (emitting validation_changed), SNAPSHOTS each one's
## candidate_revision + prior validation (so a mismatched reply can be reverted
## exactly), and returns the request payload the worker's draft_check consumes:
##   {board_token, workspace_generation, candidates:[{candidate_id, net,
##    revision, segments:[{id,layer,width,points:[[x,y],…]}],
##    vias:[{id,position:[x,y],from_layer,to_layer}]}]}
## board_token comes from `board_token` (owner-set) and workspace_generation from
## the current counter — both are stamped so apply_check_result can discard a
## stale reply. `candidate_ids` empty ⇒ all live candidates.
##
## FROZEN candidates are ALWAYS in the check set (Epoch UX3, K9's frozen half:
## "draft DRC includes frozen geometry in the materialized board"). The worker's
## draft_check scores the COMPLETE overlay it is sent — candidates against the
## board AND against each other — so a scoped check that omitted a frozen
## candidate would silently miss a crossing with settled geometry. Appending
## them to an explicit subset (the default all-live path already carries them,
## frozen being live) closes that hole with the proven whole-set mechanism
## rather than a second "context copper" wire param.
func begin_check(candidate_ids: Array = []) -> Dictionary:
	# duplicate(): the frozen append below must never mutate the CALLER's array.
	var ids: Array = candidate_ids.duplicate() if not candidate_ids.is_empty() else live_candidate_ids()
	# FORCE-APPENDED frozen candidates whose verdict must NOT move (cold
	# review finding 4): a STALE frozen candidate joins the wire — its
	# geometry must still be in the overlay, or the scoped check misses a
	# crossing with settled copper — but it is sent as CONTEXT ONLY: no
	# snapshot, no flip to "checking", so apply_check_result's guard 3
	# (empty snapshot ⇒ skip) leaves its "stale" verdict standing. Overwriting
	# stale without the caller's include_stale consent is exactly what the
	# panel-side gate exists to prevent, and the append must not tunnel it.
	var context_only: Dictionary = {}
	if not candidate_ids.is_empty():
		for fid in frozen:
			if not (str(fid) in ids) and candidates.has(str(fid)):
				ids.append(str(fid))
				var fc = get_candidate(str(fid))
				if fc != null and str(fc.validation) == "stale":
					context_only[str(fid)] = true
	_pending_check = {}
	var out_candidates: Array = []
	for raw_id in ids:
		var cid := str(raw_id)
		var c = get_candidate(cid)
		if c == null:
			continue
		if not context_only.has(cid):
			_pending_check[cid] = {"revision": int(c.candidate_revision), "prior": str(c.validation)}
			set_validation(cid, "checking")  # emits validation_changed
		out_candidates.append(_candidate_wire(cid, c))
	return {
		"board_token": board_token,
		"workspace_generation": int(_workspace_generation),
		"candidates": out_candidates,
	}


## Apply a draft_check reply. GUARDS FIRST, then writes — a mismatched reply must
## NEVER mark a candidate clean:
##   1+2. WHOLE-REPLY discard if reply.board_token != current board_token OR
##        reply.workspace_generation != current _workspace_generation. Every
##        candidate begin_check set to "checking" is reverted to its snapshotted
##        prior validation; nothing is set clean/violating.
##   3.   PER-CANDIDATE discard if a candidate's CURRENT candidate_revision !=
##        the value snapshotted at begin_check (its geometry drifted mid-flight):
##        that candidate is reverted to its prior validation and skipped.
## Only on a FULL match is a candidate set clean/violating/error per the reply's
## per_candidate verdict, its findings stored (attributed by candidate_id), and
## validation_changed emitted. The workspace is the SOLE authoritative store of
## validation + findings (no parallel store).
## The last reply's geometric-indeterminate record, or {}. Held so consumers can
## SEE that a check did not reach a geometric verdict; a caller that only reads
## per-candidate validation would otherwise be told "clean" by the connectivity
## half and never learn the other half was skipped.
var _geometric_indeterminate: Dictionary = {}


## The reason the last check could not verify geometry, or {} when it could.
func geometric_indeterminate() -> Dictionary:
	return _geometric_indeterminate.duplicate(true)


func apply_check_result(reply: Dictionary) -> void:
	var reply_token := str(reply.get("board_token", ""))
	# workspace_generation round-trips through JSON as a float; int() normalises.
	var reply_gen := int(reply.get("workspace_generation", -1))

	# GUARD 1+2 — whole-reply coherence.
	if reply_token != board_token or reply_gen != _workspace_generation:
		_revert_pending()
		_pending_check = {}
		return

	# The diagnostic belongs to the same coherent reply as the verdicts. Writing
	# it before the whole-reply guards let a late result from an old board replace
	# the current check's reason — even though every candidate verdict in that
	# result was correctly discarded.
	var gi: Variant = reply.get("geometric_indeterminate")
	_geometric_indeterminate = (gi as Dictionary).duplicate(true) if gi is Dictionary else {}

	var per_candidate: Dictionary = reply.get("per_candidate", {}) if reply.get("per_candidate", {}) is Dictionary else {}
	var findings: Array = reply.get("findings", []) if reply.get("findings", []) is Array else []

	for raw_cid in per_candidate:
		var cid := str(raw_cid)
		var c = get_candidate(cid)
		if c == null:
			continue
		var snap: Dictionary = _pending_check.get(cid, {})
		# GUARD 3 — a candidate not in this check, or whose revision drifted after
		# begin_check, is left as it was (revert to prior); never marked clean.
		if snap.is_empty():
			continue
		if int(c.candidate_revision) != int(snap.get("revision", -1)):
			if str(c.validation) == "checking":
				set_validation(cid, str(snap.get("prior", "unchecked")))
			continue
		var verdict := str(per_candidate[raw_cid])
		var value := "clean"
		if verdict == "violating" or verdict == "clean" or verdict == "error":
			value = verdict
		else:
			value = "error"  # an unknown verdict is never trusted as clean
		# GEOMETRY COULD NOT BE VERIFIED ⇒ NOTHING IS CLEAN (Codex re-review
		# finding 2). The reply's connectivity half can still say "clean" while
		# the geometric half never ran — an unmodelable board, a compile that
		# refused. Trusting the connectivity verdict alone would put a green
		# tick on copper whose clearances nobody checked, which is the whole
		# false-clean this check exists to prevent. "error" is the honest state:
		# a check happened and did not reach a verdict.
		if _geometric_indeterminate and value == "clean":
			value = "error"
		set_validation(cid, value)
		_findings[cid] = _findings_for_subject(findings, cid)

	_pending_check = {}


## Revert every still-"checking" pending candidate to its snapshotted prior
## validation. Used on a whole-reply discard.
func _revert_pending() -> void:
	for cid in _pending_check:
		var c = get_candidate(str(cid))
		if c == null:
			continue
		if str(c.validation) == "checking":
			set_validation(str(cid), str((_pending_check[cid] as Dictionary).get("prior", "unchecked")))


## Findings from a draft_check reply that name `cid` among their subjects.
static func _findings_for_subject(findings: Array, cid: String) -> Array:
	var out: Array = []
	for f in findings:
		if not (f is Dictionary):
			continue
		for s in (f as Dictionary).get("subjects", []):
			if s is Dictionary and str((s as Dictionary).get("candidate_id", "")) == cid:
				out.append(f)
				break
	return out


## ONE candidate, wire-shaped: {candidate_id, net, revision, segments, vias} —
## the shape both begin_check (draft_check) and keepout_candidates_wire (routing
## keep-outs) hand to the worker, factored here so the two call sites can never
## drift into two different candidate languages.
func _candidate_wire(cid: String, c) -> Dictionary:
	return {
		"candidate_id": cid,
		"net": str(c.net),
		"revision": int(c.candidate_revision),
		"segments": _segments_wire(c),
		"vias": _vias_wire(c),
	}


## Serialise a candidate's segments to the draft_check wire shape: points as
## [[x,y],…] (JSON-friendly, mirrors route segment coordinates).
func _segments_wire(c) -> Array:
	var out: Array = []
	for seg in c.segments:
		if not (seg is Dictionary):
			continue
		var pts: Array = []
		for p in (seg as Dictionary).get("points", []):
			if p is Vector2:
				pts.append([p.x, p.y])
			elif p is Dictionary:
				pts.append([float((p as Dictionary).get("x", 0.0)), float((p as Dictionary).get("y", 0.0))])
		out.append({
			"id": str((seg as Dictionary).get("id", "")),
			"layer": str((seg as Dictionary).get("layer", "top")),
			"width": float((seg as Dictionary).get("width", 0.25)),
			"points": pts,
		})
	return out


## Serialise a candidate's vias to the draft_check wire shape: position as [x,y].
func _vias_wire(c) -> Array:
	var out: Array = []
	for via in c.vias:
		if not (via is Dictionary):
			continue
		var via_dict: Dictionary = via
		var pos = via_dict.get("position", Vector2.ZERO)
		var xy: Array = [0.0, 0.0]
		if pos is Vector2:
			xy = [pos.x, pos.y]
		elif pos is Dictionary:
			xy = [float((pos as Dictionary).get("x", 0.0)), float((pos as Dictionary).get("y", 0.0))]
		out.append({
			"id": str(via_dict.get("id", "")),
			"position": xy,
			"from_layer": str(via_dict.get("from_layer", "top")),
			"to_layer": str(via_dict.get("to_layer", "bottom")),
		})
	return out


# ── stub ops (signatures fixed now; bodies land in T2/T5/T7) ───────────────────
# Each is a real no-op placeholder that push_warnings — NOT a fake success — so a
# premature caller is visibly unimplemented rather than silently wrong.

## T2 (S2.2) — SHADOW-phase ingest. Translates a router reply into
## RouteCandidates and adds them via add_candidate (mints cand_/seg_/via_ ids).
## This is dual-write ALONGSIDE panel_tools.gd's _write_back_proposals — the
## annotation proposals it writes remain the UI's source of truth; this
## workspace is populated in parallel and drives nothing visible yet.
##
## router_reply: {"routes":[{"net":String, "segments":[{"start":[x,y]|Vector2,
##   "end":[x,y]|Vector2, "layer":"F.Cu"/"B.Cu"}], "vias":[[x,y], ...]}], ...} —
##   EXACTLY the shape panel_tools.gd's _write_back_proposals/_materialize_routes
##   read (see panel_tools.gd ~990/~1058). A via entry is POSITIONAL [x,y] (the
##   worker's public route() reply carries no from/to — a through-via always
##   spans PcbLayerStack.default_through_via_span(), same assumption
##   _materialize_routes makes); a {x_mm,y_mm}/{x,y}/{"position":...} dict is
##   also accepted defensively, mirroring panel_tools._via_position.
##
## source_hints: the Array of source route-hint annotation dicts the propose
##   call gathered (kind_payload.net_names/source_pins/dest_pins/width_mm).
##   Their ids become source_hint_ids (provenance); net_names/width_mm size
##   each candidate's segment width (falls back to 0.25mm, matching
##   _materialize_routes' own fallback); source_pins/dest_pins seed `endpoints`.
##
## board_revision: PCBData.board_revision AT INGEST TIME, passed as a plain int
##   (not the PCBData object) so this pure-model file stays decoupled from
##   pcb_data.gd — the caller (panel_tools.gd, which already resolves the board
##   via _get_data(host)) reads data.board_revision and hands the int in.
##
## ── IDEMPOTENT REPLACE (discussion gap d) ──────────────────────────────────
## Task-identity key: `net + "|" + sorted(source_hint_ids).join(",")`. Two
## ingests sharing the same net AND the same set of source-hint ids are the
## SAME task (a re-propose of the same corridor); a different net or a
## different hint set is a DIFFERENT task. source_hint_ids are chosen over an
## endpoint-derived key because they are already stable/deterministic
## (annotation ids) and available on every ingest call with no extra parsing.
##
## Re-ingesting the SAME task NEVER appends a duplicate: the prior CURRENT
## candidate for that task_key is flipped to disposition="superseded"
## (candidate_changed emitted) and a NEW candidate is added at
## generation = prior.generation + 1 (candidate_added emitted). The superseded
## candidate is kept (not removed) as an audit trail; candidates_for_task()
## (non-superseded) is what stays size-1 across re-proposes for that task — a
## DIFFERENT task adds a genuinely new, independent candidate.
##
## EXCEPTION — a PINNED active candidate HOLDS its task: the incoming candidate
## is not created and the task is reported in last_ingest_holds (+ the
## ingest_task_held signal). See the policy block in _create_candidate_for_route.
## The returned id array is therefore SHORTER than the reply's route list when
## any task was held — read last_ingest_holds to say which and why.
func ingest_routing_result(router_reply: Dictionary, source_hints: Array = [], base_board_revision: int = 0) -> Array:
	last_ingest_holds = []  # per-call: holds describe THIS ingest, not history
	last_ingest_degenerate_segments = 0  # per-call (see the field's own doc)
	var new_ids: Array = []
	for route in router_reply.get("routes", []):
		if not (route is Dictionary):
			continue
		var route_dict: Dictionary = route
		# A route may carry an optional SPAN scope (reroute-span): it selects the
		# task, so it is read per-route, not per-reply.
		var route_span: Dictionary = route_dict.get("span", {}) if route_dict.get("span", {}) is Dictionary else {}
		var new_id := _create_candidate_for_route(
			str(route_dict.get("net", "")),
			route_dict.get("segments", []),
			route_dict.get("vias", []),
			source_hints, base_board_revision, null, route_span)
		if not new_id.is_empty():
			new_ids.append(new_id)
	return new_ids


## T2.3 correlated single-route ingest. Builds EXACTLY the candidate
## ingest_routing_result would (same _create_candidate_for_route helper) from a
## NORMALIZED route record produced once by panel_tools._normalize_route_records
## — so the shadow candidate and the annotation projection derive from the SAME
## record, never two independent parses that can drift. Returns the candidate_id
## (empty when the record has no geometry). `record` carries net, segments (raw
## router shape), vias (raw), and source_hints (for width/hint/endpoint
## derivation — the identical inputs the annotation side used).
## docket 019fa109766f (Shape A, comment 869): `record.source_hint_ids` is
## ALREADY the correct per-route attribution — panel_tools._normalize_route_
## records stamps it from the worker's own per-route `hint_ids` (net_names +
## source_pins + dest_pins, docket 019f9c3a136c), never a net-name-only
## re-derivation. Passing it through as `explicit_hint_ids` is the fix: this
## is the ONLY caller that supplies it, so only THIS path stops recomputing a
## worse answer from raw `source_hints` (see _create_candidate_for_route).
## ingest_routing_result has no such stamp available and is left untouched.
func ingest_record(record: Dictionary, base_board_revision: int = 0) -> String:
	# Reentrancy guard (see _apply_disposition): a handler landing a NEW
	# candidate mid-commit would change the very live set the deferred INV-2
	# pass is about to score.
	if _commit_transaction_active:
		push_warning("[RoutingWorkspace] ingest_record refused: %s" % ERR_COMMIT_IN_PROGRESS)
		return ""
	last_ingest_holds = []  # per-call (see ingest_routing_result)
	last_ingest_degenerate_segments = 0  # per-call (see the field's own doc)
	last_ingest_constraint_conflicts = []  # per-call (see the field's own doc)
	var hints: Array = record.get("source_hints", []) if record.get("source_hints", []) is Array else []
	var explicit_hint_ids: Array = record.get("source_hint_ids", []) if record.get("source_hint_ids", []) is Array else []
	var span: Dictionary = record.get("span", {}) if record.get("span", {}) is Dictionary else {}
	var cid := _create_candidate_for_route(
		str(record.get("net", "")),
		record.get("segments", []) if record.get("segments", []) is Array else [],
		record.get("vias", []) if record.get("vias", []) is Array else [],
		hints, base_board_revision, explicit_hint_ids, span,
		float(record.get("width_override", 0.0)),
		str(record.get("task_key_override", "")),
		record.get("endpoints_override", []) if record.get("endpoints_override", []) is Array else [])
	# P1-B (Codex 1047): the record's generating-constraint provenance becomes
	# DURABLE candidate state, not just a reply stamp — the commit preflight's
	# staleness comparison (ERR_CONSTRAINT_STALE) reads it back from here, and
	# it round-trips through the sidecar with the rest of the candidate.
	if not cid.is_empty() and candidates.has(cid) and record.has("constraint_revision"):
		candidates[cid].constraint_revision = int(record.get("constraint_revision"))
	# UX4 station 10 (019fd0ab5af8): the worker's effective-rules width
	# provenance becomes DURABLE candidate state, same P1-B idiom as the
	# constraint stamp above — finer vocabulary than the ingest verdict
	# _create_candidate_for_route just recorded, so it wins when present.
	if not cid.is_empty() and candidates.has(cid) \
			and not str(record.get("effective_width_source", "")).is_empty():
		candidates[cid].width_source = str(record.get("effective_width_source"))
	return cid


## Create + add one RouteCandidate from a raw router route (net + raw segments +
## raw vias) and the propose call's source hints. The SOLE candidate-construction
## path — both bulk ingest_routing_result and correlated ingest_record funnel
## through it so a candidate is built identically no matter the entry point.
## Handles the idempotent-replace supersession bookkeeping. Returns the new
## candidate_id, or "" when the route has no geometry.
##
## `explicit_hint_ids` (docket 019fa109766f, Shape A): when it IS an Array
## (even empty — that is a legitimate "nothing answered this route" verdict,
## not "recompute"), it is the ALREADY-CORRECT per-route attribution
## ingest_record carries on its record, used VERBATIM for source_hint_ids/
## task_key and to select which hints seed endpoints/width — no net_names
## re-derivation, no blanket fallback. `null` (the default, and the only
## value ingest_routing_result ever passes — it has no such stamp available)
## means "no pre-resolved set": the legacy net_names-match-with-fallback path
## (_hint_ids_for_net / _endpoints_for_net / _width_for_net) runs exactly as
## it always has. That caller is deliberately left untouched by this docket.
##
## `span` (C1) is the OPTIONAL span scope of the task this route answers ({} ⇒
## whole-net). It participates in the task key, so a "reroute just this stretch"
## proposal gets its OWN task (and its own generation chain) instead of
## superseding the whole-net candidate — and re-proposing the SAME span
## supersedes exactly like a whole-net re-propose does.
## `width_override` (bus-propose, docket 019fcac1509d): a caller that already
## KNOWS its exact per-trace width — bus_propose_plan resolved each net's width
## from the board's own copper before any candidate existed — passes it here so
## a hintless record does not fall through to _width_from_hints' 0.25mm
## default (the exact stamped-default bug class of docket 019fa73a191e).
## 0.0 (the default) means "no override": every hint-derived path is unchanged.
## `task_key_override` + `endpoints_override` (DCR 01a022ab356c leg C): a
## hint-less reroute's answer attributes to [] — its derived key would be a
## phantom "net|" task beside the asking one, TWO live answers to one
## question. The caller that KNOWS which task asked (the reroute executor,
## which holds the prior candidate) pins the key and carries the terminals
## onto the fallback generation so it stays reroutable. Empty (the defaults)
## leaves every derived path byte-identical.
func _create_candidate_for_route(net: String, segs: Array, vias: Array, source_hints: Array, base_board_revision: int, explicit_hint_ids = null, span: Dictionary = {}, width_override: float = 0.0, task_key_override: String = "", endpoints_override: Array = []) -> String:
	if segs.is_empty() and vias.is_empty():
		return ""
	var via_span: Array = PcbLayerStack.default_through_via_span()

	var use_explicit: bool = explicit_hint_ids is Array
	var hint_ids: Array = []
	var attribution_hints: Array = []
	if use_explicit:
		hint_ids = (explicit_hint_ids as Array).duplicate()
		attribution_hints = _hints_by_ids(source_hints, hint_ids)
	else:
		# PER-NET attribution (T2a folds in docket #555): the task_key +
		# source_hint_ids are keyed on the hints that target THIS net, not the
		# GLOBAL propose hint set. A multi-net propose / a cross-net hint change
		# no longer shifts an unrelated net's task_key (which would leave a stale
		# duplicate). Only ingest_routing_result reaches this branch — see
		# _hint_ids_for_net below (docket 019fa109766f: its blanket fallback is
		# a known over-attribution for a pins-only hint, left alone here because
		# this caller has no production consumer and no per-route hint_ids to
		# read instead).
		hint_ids = _hint_ids_for_net(source_hints, net)
	var span_key := PcbRouteTask.span_key(span)
	var task_key := _task_key(net, hint_ids, span_key)
	if not task_key_override.is_empty():
		task_key = task_key_override
	# H3-1 (cold review, Epoch UX1 station 8 follow-up): before minting/reusing
	# task_key, absorb any still-open, CANDIDATE-LESS "eager" task whose OWN key
	# is a single-hint slice of THIS route's attribution — the shape
	# minerva_pcb_add_route_intent mints per intent ("net|hint_id", panel_tools.
	# _add_route_intent). Two open intents on one net can attribute to ONE
	# worker route (hint_ids.size() > 1 here): the merged key "net|hidA,hidB"
	# is never equal to either eager key "net|hidA" / "net|hidB", so without
	# this both eager tasks orphan forever AND a THIRD task mints for the real
	# answer. The singleton case (hint_ids == [h], task_key == "net|h") is
	# UNCHANGED: ensure_task's own get-or-create already reuses that exact
	# task, so the absorption loop below finds no OTHER task to fold in.
	if not tasks.has(task_key) and hint_ids.size() > 1:
		_absorb_eager_tasks_for_merge(task_key, net, span, hint_ids, span_key)
	# The task (the question) exists before its answer; state is derived after
	# the candidate lands (add_candidate → _refresh_task_state).
	ensure_task(task_key, net, span)
	var generation := 1
	var prior_id: String = str(_task_candidate.get(task_key, ""))
	if not prior_id.is_empty() and candidates.has(prior_id):
		var prior = candidates[prior_id]
		# ── PINNED PRIOR ⇒ HOLD THE TASK (do not replace) ────────────────────
		# DCR vocabulary: "Keep/Pin = ghost stays draft but future routing routes
		# AROUND it". A pin is the user's standing instruction that this stretch
		# of copper is settled — so a batch re-route must not quietly retire it.
		# The incoming candidate is NOT created; the pinned prior is untouched;
		# the skip is recorded + announced so the caller can say WHICH task was
		# held rather than silently reporting fewer routes.
		# The user CAN still retire it: supersede()/unpin() act on THAT candidate
		# (explicit consent), and the legality table allows pinned → superseded.
		# The distinction is batch-ingest vs targeted verb, not legal vs illegal.
		if str(prior.disposition) == "pinned":
			_record_ingest_hold(task_key, prior_id, net, HOLD_PINNED)
			return ""
		# ── FROZEN PRIOR ⇒ HOLD THE TASK (Epoch UX3, K7) ─────────────────────
		# Same shape as the pinned hold above, stronger meaning: frozen is
		# SETTLED, and unlike a pin there is no targeted supersede to retire it
		# (the legality table has no frozen → superseded row). The one path to
		# replacing settled geometry is unfreeze() first — a batch re-route can
		# never do that implicitly.
		if str(prior.disposition) == "frozen":
			_record_ingest_hold(task_key, prior_id, net, HOLD_FROZEN)
			return ""
		generation = int(prior.generation) + 1
		# Try-again supersedes the task's current answer — but ONLY when that
		# answer is still LIVE. A prior that already left the live set
		# (rejected/committed/superseded) is TERMINAL: superseding it would be an
		# illegal transition, and there is nothing to replace. The new candidate
		# still continues the generation chain (the question was asked again).
		if str(prior.disposition) == "proposed":
			_apply_disposition(prior_id, "superseded", "ingest_replace")

	var cand = PcbRouteCandidate.new()
	cand.task_id = task_key
	cand.net = net
	cand.generation = generation
	cand.base_board_revision = base_board_revision
	cand.source_hint_ids = _to_string_typed_array(hint_ids)

	var width: float
	var width_hints: Array
	if use_explicit:
		cand.endpoints = _endpoints_from_hints(attribution_hints)
		if cand.endpoints.is_empty() and not endpoints_override.is_empty():
			# Same {component, pin} dict shape _endpoints_from_hints emits —
			# the override IS a prior candidate's endpoints, carried forward.
			cand.endpoints = endpoints_override.duplicate(true)
		width = _width_from_hints(attribution_hints)
		width_hints = attribution_hints
	else:
		cand.endpoints = _endpoints_for_net(source_hints, net)
		width = _width_for_net(source_hints, net)
		width_hints = _hints_matching_net(source_hints, net)
	# WIDTH PROVENANCE (UX4 station 10, 019fd0ab5af8): record WHICH source
	# sized the copper, so _width_from_hints' silent 0.25mm fallback is
	# distinguishable from an authored 0.25mm at review. ingest_record
	# upgrades this to the worker's finer vocabulary when the route record
	# carried effective rules.
	cand.width_source = "hint" if _hints_supply_width(width_hints) else "default"
	if width_override > 0.0:
		width = width_override
		cand.width_source = "caller_option"

	for seg in segs:
		if not (seg is Dictionary):
			continue
		var seg_dict: Dictionary = seg
		var layer := PcbLayerStack.kicad_to_canon(seg_dict.get("layer", "F.Cu"))
		var pts: Array = drop_coincident_points(
			[_pt(seg_dict.get("start", [0, 0])), _pt(seg_dict.get("end", [0, 0]))])
		if pts.size() < 2:
			# A router that emitted start == end drew nothing. Keeping it would
			# put a zero-length segment on the board at commit and make the
			# board uncompilable; the rest of this route is unaffected.
			last_ingest_degenerate_segments += 1
			continue
		cand.add_segment(PcbRouteCandidate.make_segment("", layer, width, pts))

	for via in vias:
		var pos := _via_pt(via)
		cand.add_via(PcbRouteCandidate.make_via("", pos, via_span[0], via_span[1]))

	if cand.segments.is_empty() and cand.vias.is_empty():
		# Everything this route carried collapsed. Honour the documented
		# contract ("" when the route has no geometry) rather than adding a
		# ghost that draws nothing and can only ever be rejected;
		# last_ingest_degenerate_segments says why it vanished.
		return ""
	var new_id: String = add_candidate(cand)
	_task_candidate[task_key] = new_id
	return new_id


# ── T2.3 correlation (candidate ↔ annotation) + bridged legacy-mutation routing ──

## Record the bidirectional correlation between a candidate and the annotation
## proposal it was dual-written beside. Overwrites any prior link for either id
## (a re-propose mints a fresh candidate+annotation pair). Both lookup directions
## are then valid: candidate_for_annotation / annotation_for_candidate.
func correlate(candidate_id: String, annotation_id: String, task_id: String = "", generation: int = 0) -> void:
	if candidate_id.is_empty() or annotation_id.is_empty():
		return
	# Drop any stale reverse entry pointing at this candidate from a prior link.
	var prev: Dictionary = correlations.get(candidate_id, {})
	var prev_ann := str(prev.get("annotation_id", ""))
	if not prev_ann.is_empty() and str(_annotation_to_candidate.get(prev_ann, "")) == candidate_id:
		_annotation_to_candidate.erase(prev_ann)
	correlations[candidate_id] = {
		"annotation_id": annotation_id,
		"task_id": task_id,
		"generation": generation,
		"committed_trace_ids": prev.get("committed_trace_ids", []),
		"committed_via_ids": prev.get("committed_via_ids", []),
		"prior_disposition": prev.get("prior_disposition", ""),
		# C4a: the source hints a COMMIT consumed (recorded, never deleted — see
		# commit()'s contract). Carried across a re-correlate like the copper ids.
		"consumed_hint_ids": prev.get("consumed_hint_ids", []),
	}
	_annotation_to_candidate[annotation_id] = candidate_id


## candidate_id -> the correlated annotation id ("" if not bridged).
func annotation_for_candidate(candidate_id: String) -> String:
	return str((correlations.get(candidate_id, {}) as Dictionary).get("annotation_id", ""))


## annotation_id -> the correlated candidate id ("" if not bridged).
func candidate_for_annotation(annotation_id: String) -> String:
	return str(_annotation_to_candidate.get(annotation_id, ""))


## True iff this candidate has a correlated annotation.
func is_candidate_bridged(candidate_id: String) -> bool:
	return correlations.has(candidate_id) and not annotation_for_candidate(candidate_id).is_empty()


## True iff this annotation has a correlated candidate.
func is_annotation_bridged(annotation_id: String) -> bool:
	return not candidate_for_annotation(annotation_id).is_empty()


## Bridged ACCEPT (T2.3): the correlated candidate's geometry has just been
## materialized into PCBData as the given stable trace/via ids — flip the
## candidate to disposition="committed" so accepting an annotation proposal can
## NEVER leave its candidate live in the workspace, and RECORD the resulting
## copper ids (the ResolvedBoard IR references committed copper by these stable
## ids). Stashes the prior disposition so an undo can restore it (uncommit). The
## pure model does no board mutation itself — the annotation-authoritative accept
## path already did that; this only keeps the shadow candidate coherent.
func mark_committed(candidate_id: String, trace_ids: Array = [], via_ids: Array = [],
		from_transaction := false) -> bool:
	var c = get_candidate(candidate_id)
	if c == null:
		return false
	var prior := str(c.disposition)
	# LEGALITY FIRST: a candidate that cannot legally reach "committed" (already
	# superseded/rejected) must not have its copper ids recorded either — a
	# refused transition is never half-applied. `from_transaction` threads the
	# reentrancy-guard bypass for commit_batch's OWN phase-B calls (see
	# _apply_disposition's guard doc); every external caller leaves it false.
	if not _apply_disposition(candidate_id, "committed", "mark_committed", from_transaction):
		return false
	var rec: Dictionary = correlations.get(candidate_id, {})
	if prior != "committed":
		rec["prior_disposition"] = prior
	rec["committed_trace_ids"] = _to_string_array(trace_ids)
	rec["committed_via_ids"] = _to_string_array(via_ids)
	correlations[candidate_id] = rec
	if prior == "committed":
		# RE-COMMIT (identity move): _apply_disposition emits nothing for an
		# identity transition, but the committed copper ids DID just change and
		# committed_copper_ids() is read by the UI. The file's emit discipline is
		# "every observable mutation announces itself", so announce it here.
		# REFUSING instead would be wrong: the shipped code deliberately handles
		# a re-commit (it keeps the ORIGINAL prior_disposition rather than
		# stamping "committed" over it), i.e. re-commit is a supported call, not
		# a caller error. No _bump_generation(): the LIVE candidate set did not
		# move, and that counter exists only to invalidate in-flight draft checks.
		candidate_changed.emit(candidate_id)
	return true


## Stable ids of the copper a committed candidate produced (empty when not
## committed). {trace_ids, via_ids} — the ResolvedBoard-IR reference set.
func committed_copper_ids(candidate_id: String) -> Dictionary:
	var rec: Dictionary = correlations.get(candidate_id, {})
	return {
		"trace_ids": (rec.get("committed_trace_ids", []) as Array).duplicate(),
		"via_ids": (rec.get("committed_via_ids", []) as Array).duplicate(),
	}


## The source-hint ids a COMMIT consumed for this candidate (empty when it has
## not been committed). Recorded rather than acted on — see commit()'s contract
## for why no annotation is removed.
func consumed_hint_ids(candidate_id: String) -> Array:
	var rec: Dictionary = correlations.get(candidate_id, {})
	return (rec.get("consumed_hint_ids", []) as Array).duplicate()


## UNDO of a bridged accept (T2.3, GATE INV-1): the board undo has restored the
## pre-commit state (its traces AND vias — never orphaning vias, F1) — revert the
## candidate from committed back to its prior disposition and clear the recorded
## copper ids, so BOTH stores are coherent again (the candidate is live once more,
## matching a board that no longer holds its trace/vias). Returns true if a
## committed candidate was reverted.
func uncommit(candidate_id: String) -> bool:
	# Reentrancy guard (see _apply_disposition): uncommit bypasses the legality
	# funnel by design, so it carries the transaction check itself.
	if _commit_transaction_active:
		_record_refusal(candidate_id, "committed", "", ERR_COMMIT_IN_PROGRESS, "uncommit")
		return false
	var c = get_candidate(candidate_id)
	if c == null:
		return false
	if str(c.disposition) != "committed":
		return false
	var rec: Dictionary = correlations.get(candidate_id, {})
	var prior := str(rec.get("prior_disposition", "proposed"))
	# Clamp to a legal uncommit target: an absent/garbled/self-referential prior
	# falls back to "proposed" (the safe live state) rather than refusing — the
	# board undo already happened, so leaving the candidate committed would be
	# the INCOHERENT outcome.
	if not (prior in PcbRouteCandidate.UNCOMMIT_TARGETS):
		prior = "proposed"
	# The ONLY exit from "committed" — a COMPENSATING move, not a workflow verb,
	# so it goes through uncommit_to() rather than the legality table.
	var err: String = c.uncommit_to(prior)
	if not err.is_empty():
		_record_refusal(candidate_id, "committed", prior, err, "uncommit")
		return false
	rec["committed_trace_ids"] = []
	rec["committed_via_ids"] = []
	rec["prior_disposition"] = ""
	rec["consumed_hint_ids"] = []
	correlations[candidate_id] = rec
	last_transition_error = {}
	_sync_held_indexes(candidate_id, prior)
	_refresh_task_state(str(c.task_id))  # the copper is gone → the task reopens
	_bump_generation()
	# INV-2 (C4a), live-set half — stated here as well as in _apply_disposition
	# because uncommit deliberately does NOT go through the legality table (it is
	# the compensating half of a board undo). The candidate is live again and the
	# board just lost its copper, so every live verdict was scored against a
	# board and a set that no longer exist — INCLUDING this candidate's own,
	# which is why the rule is "every candidate live AFTERWARDS".
	_stale_live_verdicts()
	candidate_changed.emit(candidate_id)
	return true


## Bridged ADD-VIA route-through (T2.3): the correlated annotation's segments/vias
## have just been edited (a via inserted) — re-derive the candidate's geometry
## from that SAME updated raw route data so both stores stay identical, and bump
## candidate_revision (invalidates any in-flight draft check for it). Raw segments
## are the router `{start,end,layer}` shape; raw vias are positional [x,y] (the
## exact shapes _create_candidate_for_route already parses). Widths are preserved
## from the candidate's existing first segment. Returns true on success.
func sync_candidate_geometry(candidate_id: String, segs_raw: Array, vias_raw: Array) -> bool:
	var c = get_candidate(candidate_id)
	if c == null:
		return false
	# FROZEN lock (Epoch UX3, K7): the bridged annotation-edit path is a
	# geometry write like any other — without this gate it would be the back
	# door through which "settled" geometry silently reshapes. Same remedy as
	# add_via/move_junction: unfreeze first.
	if str(c.disposition) == "frozen":
		push_warning("[RoutingWorkspace] sync_candidate_geometry refused: %s is frozen (unfreeze first)" % candidate_id)
		return false
	last_ingest_degenerate_segments = 0  # per-call (see the field's own doc)
	var via_span: Array = PcbLayerStack.default_through_via_span()
	var width := 0.25
	if not c.segments.is_empty() and c.segments[0] is Dictionary:
		width = float((c.segments[0] as Dictionary).get("width", 0.25))

	var new_segments: Array = []
	for seg in segs_raw:
		if not (seg is Dictionary):
			continue
		var seg_dict: Dictionary = seg
		var layer := PcbLayerStack.kicad_to_canon(seg_dict.get("layer", "F.Cu"))
		var pts: Array = drop_coincident_points(
			[_pt(seg_dict.get("start", [0, 0])), _pt(seg_dict.get("end", [0, 0]))])
		if pts.size() < 2:
			last_ingest_degenerate_segments += 1
			continue
		var s := PcbRouteCandidate.make_segment(next_segment_id(), layer, width, pts)
		new_segments.append(s)

	var new_vias: Array = []
	for via in vias_raw:
		var pos := _via_pt(via)
		new_vias.append(PcbRouteCandidate.make_via(next_via_id(), pos, via_span[0], via_span[1]))

	c.segments = new_segments
	c.vias = new_vias
	c.candidate_revision = int(c.candidate_revision) + 1
	# INV-2, geometry half (C4a). This IS a geometry verb — it replaces the
	# candidate's whole segment/via set — so it stales exactly as add_via does,
	# and for a reason the bumped candidate_revision does NOT cover: that counter
	# only discards an IN-FLIGHT draft check (apply_check_result's guard 3). A
	# verdict that already LANDED is a stored "clean" on the candidate, and
	# nothing here would have moved it, so the bridged legacy Add-Via path
	# (panel_tools._add_via, which re-derives a correlated candidate's geometry
	# from an edited annotation) could carry a clean verdict onto copper that
	# just changed shape. No exception applies: unlike pin/unpin, this moves the
	# geometry itself.
	mark_stale(candidate_id)
	_bump_generation()
	candidate_changed.emit(candidate_id)
	return true


## Record + announce one ingest hold (see the pinned-prior policy above).
func _record_ingest_hold(task_id: String, held_candidate_id: String, net: String, reason: String) -> void:
	last_ingest_holds.append({
		"task_id": task_id, "held_candidate_id": held_candidate_id,
		"net": net, "reason": reason,
	})
	push_warning("[RoutingWorkspace] ingest held task '%s': %s (%s)" % [task_id, reason, held_candidate_id])
	ingest_task_held.emit(task_id, held_candidate_id, reason)


static func _to_string_array(arr: Array) -> Array:
	var out: Array = []
	for v in arr:
		out.append(str(v))
	return out


# ── ingest helpers (private) ────────────────────────────────────────────────

static func _hint_ids(source_hints: Array) -> Array:
	var out: Array = []
	for hint in source_hints:
		if hint is Dictionary:
			out.append(str((hint as Dictionary).get("id", "")))
	return out


## Hints whose kind_payload.net_names include `net` — the net_names-only match
## shared by the three legacy net-keyed helpers below. NET_NAMES-ONLY: a hint
## that names its net solely through source_pins/dest_pins (no net_names
## entry) never matches here. That is the known gap tracked as docket
## 019fa109766f; see _hint_ids_for_net for why it stays this way.
static func _hints_matching_net(source_hints: Array, net: String) -> Array:
	var out: Array = []
	for hint in source_hints:
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = (hint as Dictionary).get("kind_payload", {}) if (hint as Dictionary).get("kind_payload", {}) is Dictionary else {}
		var nets: Array = kp.get("net_names", []) if kp.get("net_names", []) is Array else []
		if net in nets:
			out.append(hint)
	return out


## Hints whose "id" is in `ids` — the explicit-attribution counterpart to
## _hints_matching_net, used by the ingest_record path (docket 019fa109766f):
## the caller already knows exactly which hints answered this route (worker
## per-route `hint_ids`), so no net_names re-derivation is needed or wanted.
static func _hints_by_ids(source_hints: Array, ids: Array) -> Array:
	var id_set: Dictionary = {}
	for i in ids:
		id_set[str(i)] = true
	var out: Array = []
	for hint in source_hints:
		if hint is Dictionary and id_set.has(str((hint as Dictionary).get("id", ""))):
			out.append(hint)
	return out


## Ids of the source hints whose kind_payload.net_names include `net` — the
## PER-NET provenance/attribution set. When NO hint names this net via
## net_names, falls back to the full hint set so a candidate is never left
## with empty provenance.
##
## NET_NAMES-ONLY, WITH BLANKET FALLBACK — used ONLY by the legacy bulk path
## ingest_routing_result, via _create_candidate_for_route's
## `explicit_hint_ids == null` branch. It over-attributes: a pins-only hint
## (net named solely through source_pins/dest_pins, net_names empty) falls
## through to "every selected hint" here exactly like every other unmatched
## hint would. This is docket 019fa109766f's defect, scoped down: the FIX
## does not touch this function. ingest_record (the production path) now
## supplies its own already-correct attribution as `explicit_hint_ids` and
## never calls this helper at all (see _create_candidate_for_route).
## ingest_routing_result has no production caller and no per-route hint_ids
## to read instead, so it is left exactly as it was — fixing it too would
## only turn test_workspace_ingest.gd's fixtures red for a fixture reason,
## not a defect reason (owner ruling, docket comment 869).
static func _hint_ids_for_net(source_hints: Array, net: String) -> Array:
	var matched := _hints_matching_net(source_hints, net)
	var ids: Array = []
	for hint in matched:
		ids.append(str((hint as Dictionary).get("id", "")))
	if ids.is_empty():
		return _hint_ids(source_hints)
	return ids


static func _to_string_typed_array(ids: Array) -> Array[String]:
	var out: Array[String] = []
	for id in ids:
		out.append(str(id))
	return out


## Deterministic task-identity key — see the ingest_routing_result contract doc.
## `span_key` (C1) is PcbRouteTask.span_key of the task's span scope and is
## APPENDED ONLY when non-empty, so every whole-net key ("<net>|<hint ids>") is
## byte-identical to what it was before spans existed — no key churn, no
## silently-duplicated tasks on upgrade.
static func _task_key(net: String, hint_ids: Array, span_key: String = "") -> String:
	var sorted_ids: Array = hint_ids.duplicate()
	sorted_ids.sort()
	var joined := ",".join(sorted_ids)
	var key := "%s|%s" % [net, joined]
	if not span_key.is_empty():
		key += "|span:%s" % span_key
	return key


## H3-1 absorption helper (cold review, Epoch UX1 station 8 follow-up — see
## the call site in _create_candidate_for_route for the full rationale).
## `task_key` is the about-to-be-created MERGED task key; `hint_ids` is its
## full (size > 1, checked by the caller) hint attribution. Folds in every
## still-open, CANDIDATE-LESS eager task keyed "net|h" for h in hint_ids —
## the shape minerva_pcb_add_route_intent mints per intent — into the merged
## task: creates/reuses it via ensure_task (never reimplemented), transfers a
## SOLITARY absorbed routing_constraint onto it (the merged task is freshly
## created here, so it never already carries one of its own), and on a
## CONFLICT (two absorbed tasks both constrained) keeps NEITHER and
## push_warns naming both task ids rather than guessing a winner — AND (F4,
## cold review) records the conflict onto last_ingest_constraint_conflicts,
## so the drop reaches the ingest_record caller's reply instead of living
## only in a push_warning nobody outside the engine console ever sees.
## Absorbed tasks are erased outright, never left as dead entries. A task any
## candidate has ever landed on is HISTORY and is never absorbed — the same
## rule drop_empty_tasks_for_hint (H2-1) applies to the deletion-cascade side.
func _absorb_eager_tasks_for_merge(task_key: String, net: String, span: Dictionary, hint_ids: Array, span_key: String) -> void:
	var to_absorb: Array = []
	var constrained: Array = []
	for h in hint_ids:
		var eager_key := _task_key(net, [str(h)], span_key)
		if eager_key == task_key:
			continue
		var t = tasks.get(eager_key, null)
		if t == null:
			continue
		if _task_has_any_candidate(eager_key):
			continue  # history — never absorbed
		to_absorb.append(eager_key)
		if t.is_constrained():
			constrained.append({"task_id": eager_key, "constraint": t.routing_constraint})
	if to_absorb.is_empty():
		return
	var merged = ensure_task(task_key, net, span)
	var kept_on_conflict: Dictionary = {}
	if constrained.size() == 1:
		merged.routing_constraint = (constrained[0]["constraint"] as Dictionary).duplicate(true)
	elif constrained.size() > 1:
		var names: Array = []
		for c in constrained:
			names.append(str(c["task_id"]))
			# P1-A (Codex 1047, consolidated review): a conflicting merge used
			# to keep NEITHER constraint AND erase both singleton tasks. For
			# station-12-seeded legacy hints that was a PERMANENT dead state:
			# both annotations stay stamped waypoints_superseded_by_constraint_
			# revision (edit-refused by the host), while panel_tools.gd's
			# seeding gate (H1-2 membership branch) refuses to ever re-seed a
			# hint that MEMBERS a merged task — superseded waypoints with no
			# surviving constraint steering anything. The refusal shape now:
			# the MERGED task stays unconstrained (there is genuinely no single
			# task-level winner), but the constrained SINGLETONS survive
			# un-absorbed — the task_constraints wire channel is per-hint
			# (owner_hint_id-gated, _task_constraints_for_hints), so each
			# surviving singleton keeps steering ITS OWN hint on the next
			# propose, and the supersession stamps stay truthful.
			kept_on_conflict[str(c["task_id"])] = true
		push_warning("[RoutingWorkspace] H3-1/P1-A: merge into task '%s' found CONFLICTING routing_constraints on %s — merged task left unconstrained, constrained singletons KEPT (Codex 1047 fix round)" % [task_key, ", ".join(names)])
		# F4: the same outcome, surfaced to the caller rather than only the
		# engine console — panel_tools.gd's _ingest_result_into_workspace
		# reads this per ingest_record call and threads it into the reply as
		# `constraint_conflicts`.
		last_ingest_constraint_conflicts.append({
			"task_ids": names, "reason": "conflicting_constraints_kept_on_singletons",
		})
	for tid in to_absorb:
		if kept_on_conflict.has(tid):
			continue
		tasks.erase(tid)
		_task_candidate.erase(tid)


## True iff any candidate — any disposition; committed/rejected/superseded
## count as HISTORY, not just the live ones — has ever named `task_key` as its
## task_id. The shared "is this task an empty placeholder or does it already
## have an answer" test both H3-1's absorption and H2-1's deletion cascade
## (drop_empty_tasks_for_hint) need.
func _task_has_any_candidate(task_key: String) -> bool:
	for id in candidates:
		if str(candidates[id].task_id) == task_key:
			return true
	return false


## Parse a task key's hint-id set out of "<net>|<hint_ids>[|span:...]" — the
## middle segment, comma-split; an empty segment (no hints attributed) parses
## to [], never [""].
static func _task_key_hint_set(task_key: String) -> Array:
	var parts: Array = task_key.split("|")
	if parts.size() < 2:
		return []
	var joined := str(parts[1])
	if joined.is_empty():
		return []
	return joined.split(",")


## Endpoints seeded from the matching source hints' pin references
## (kind_payload.source_pins/dest_pins, each "Component.Pin"). Positions are
## not resolved here (no board/pad lookup in this pure model) — component/pin
## identity is enough for provenance; a later task can enrich with position.
## NET_NAMES-ONLY match (via _hints_matching_net) — used ONLY by the legacy
## ingest_routing_result path. A pins-only hint never matches here (same gap
## as _hint_ids_for_net, docket 019fa109766f); ingest_record instead calls
## _endpoints_from_hints directly on its already-correct hint set.
static func _endpoints_for_net(source_hints: Array, net: String) -> Array:
	return _endpoints_from_hints(_hints_matching_net(source_hints, net))


## Endpoints from an EXPLICIT hint list — no net_names filtering, so a
## pins-only hint (net named only through source_pins/dest_pins) is not
## silently dropped. Shared extraction logic for both _endpoints_for_net
## (legacy, net-name-matched hints) and ingest_record's explicit-attribution
## path (docket 019fa109766f).
static func _endpoints_from_hints(hints: Array) -> Array:
	var out: Array = []
	for hint in hints:
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = (hint as Dictionary).get("kind_payload", {}) if (hint as Dictionary).get("kind_payload", {}) is Dictionary else {}
		for pin_ref in kp.get("source_pins", []):
			out.append(_pin_ref_to_endpoint(pin_ref))
		for pin_ref in kp.get("dest_pins", []):
			out.append(_pin_ref_to_endpoint(pin_ref))
	return out


static func _pin_ref_to_endpoint(pin_ref) -> Dictionary:
	var s := str(pin_ref)
	var idx := s.rfind(".")
	if idx < 0:
		return {"component": s, "pin": ""}
	return {"component": s.substr(0, idx), "pin": s.substr(idx + 1)}


## Widest authored trace width among the source hints that target `net`
## (mirrors panel_tools._width_for_net); falls back to 0.25mm — the same
## default _materialize_routes applies when no hint specifies a width — so a
## shadow candidate's width matches what would actually be committed.
## NET_NAMES-ONLY match (via _hints_matching_net) — used ONLY by the legacy
## ingest_routing_result path; a pins-only hint never matches here (same gap
## as _hint_ids_for_net, docket 019fa109766f). ingest_record instead calls
## _width_from_hints directly on its already-correct hint set.
static func _width_for_net(source_hints: Array, net: String) -> float:
	return _width_from_hints(_hints_matching_net(source_hints, net))


## Widest authored trace width from an EXPLICIT hint list — no net_names
## filtering. Falls back to 0.25mm — the same default _materialize_routes
## applies when no hint specifies a width. Shared extraction logic for both
## _width_for_net (legacy, net-name-matched hints) and ingest_record's
## explicit-attribution path (docket 019fa109766f).
static func _width_from_hints(hints: Array) -> float:
	var w := 0.0
	for hint in hints:
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = (hint as Dictionary).get("kind_payload", {}) if (hint as Dictionary).get("kind_payload", {}) is Dictionary else {}
		var hw := float(kp.get("width_mm", 0.0))
		if hw > w:
			w = hw
	if w <= 0.0:
		w = 0.25
	return w


## Did any hint actually AUTHOR a width? The provenance half of
## _width_from_hints (UX4 station 10): true = the value above came from a
## hint, false = it is the silent 0.25mm fallback.
static func _hints_supply_width(hints: Array) -> bool:
	for hint in hints:
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = (hint as Dictionary).get("kind_payload", {}) if (hint as Dictionary).get("kind_payload", {}) is Dictionary else {}
		if float(kp.get("width_mm", 0.0)) > 0.0:
			return true
	return false


## Coerce a [x, y] pair (Array/Vector2/{"x","y"} dict) to Vector2.
static func _pt(raw) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	if raw is Dictionary:
		var d: Dictionary = raw
		return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	return Vector2.ZERO


## A route's via entries are POSITIONAL [x,y] (mirrors panel_tools._via_position
## — SAME reply shape, independently read here since this pure model has no
## dependency on panel_tools.gd). Defensively also accepts {x_mm,y_mm}/{x,y}/
## {"position":...} dict shapes.
static func _via_pt(raw) -> Vector2:
	if raw is Dictionary:
		var d: Dictionary = raw
		if d.has("x_mm") and d.has("y_mm"):
			return Vector2(float(d.get("x_mm", 0.0)), float(d.get("y_mm", 0.0)))
		if d.has("x") and d.has("y"):
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		if d.has("position"):
			return _pt(d.get("position", [0, 0]))
		return Vector2.ZERO
	return _pt(raw)


# ══ C4a — THE VERB LAYER (S4, DCR 019f7095c395) ══════════════════════════════
#
# Three invariants live below. Each is stated where it is enforced, not only
# here, but the map is:
#
#   INV-1  commit() is ONE undoable transaction: candidate geometry -> real
#          copper, candidate -> committed, source hints recorded, in a single
#          board history step whose snapshot ALSO carries the workspace's
#          disposition layer (PCBData's eighth history bucket) so a board undo
#          restores BOTH stores.
#   INV-2  every candidate-mutating verb marks the invalidated verdicts
#          "stale" — see _stale_live_verdicts / _mark_stale and the rule stated
#          on VERDICT_VALIDATIONS.
#   INV-3  a via/layer EDIT is PATH-SCOPED: add_via() resolves the CONNECTED
#          PATH the click landed on out of the exact segment graph and never
#          touches a disconnected path of the same candidate. Degenerate
#          inserts (on an endpoint, on an existing via) are NAMED refusals.

## Validations that represent a REAL VERDICT — the only ones staleness can
## invalidate.
##
## THE INV-2 RULE, in one sentence: a verb marks "stale" exactly the candidates
## whose verdict it invalidated, and nothing else.
##   * GEOMETRY verbs (add_via, sync_candidate_geometry, a reroute's re-ingest)
##     stale the EDITED candidate — its own copper moved.
##   * LIVE-SET verbs (reject / commit / supersede / ingest-replace / uncommit)
##     stale every candidate that is LIVE AFTERWARDS, because draft_check is
##     SET-SCOPED (methods._draft_check runs drc over committed copper UNION
##     every live candidate's draft copper): a verdict named a set that no
##     longer holds. Stating it as "live afterwards" is what makes the rule
##     self-consistent in both directions — the departing candidate is terminal
##     and therefore excluded, and an UNCOMMITTED one is live again and
##     therefore included.
##   * pin / unpin stale NOTHING, and that is a decision rather than an
##     omission: pinning moves no geometry and does not change the set
##     draft_check scores (a pinned candidate is still live copper in the
##     check). It changes only what a FUTURE ROUTER RUN treats as keep-out
##     (route_bridge.existing_copper_with_pinned). Staling on pin would erase
##     the very check the user ran in order to decide to pin.
##   * "unchecked"/"stale" carry no verdict to lose, and "checking" is already
##     guarded by the workspace-generation token (apply_check_result discards a
##     reply whose generation moved) — so only these three are touched. Without
##     that filter a routine re-propose would stale every freshly-added
##     candidate for no reason, which is noise, not safety.
const VERDICT_VALIDATIONS := ["clean", "violating", "error"]

## Named refusal codes for the verb layer (the transition codes live on
## PcbRouteCandidate; these are the ones only a verb can produce).
const ERR_NO_CANDIDATE := "candidate_not_found"
const ERR_NO_BOARD := "board_unavailable"
const ERR_NO_GEOMETRY := "candidate_has_no_geometry"
const ERR_UNMODELABLE_SEGMENT := "unmodelable_segment"
const ERR_UNMODELABLE_VIA := "unmodelable_via"
const ERR_ILLEGAL_VIA_SPAN := "illegal_via_span"
const ERR_BOARD_WRITE := "board_write_failed"
const ERR_NOT_EDITABLE := "candidate_not_editable"
const ERR_ALREADY_COMMITTED := "already_committed"
const ERR_DUPLICATE_CANDIDATE := "duplicate_candidate_id"
const ERR_COMMIT_IN_PROGRESS := "commit_in_progress"
const ERR_VIA_NOT_PLACEABLE := "via_not_placeable"
const ERR_NO_SEGMENT_AT_POINT := "no_segment_at_point"
const ERR_DEGENERATE_AT_ENDPOINT := "degenerate_insert_at_endpoint"
const ERR_DEGENERATE_ON_VIA := "degenerate_insert_on_via"
const ERR_SEGMENT_LOCKED := "segment_locked"
const ERR_LAYER_MISMATCH := "from_layer_mismatch"
## add_via's `to_layer` names the layer the RUN CONTINUES ON past the via, and
## a run can only continue on copper. Distinct from ERR_ILLEGAL_VIA_SPAN, which
## now means only "this via would change nothing" — see add_via's own doc.
const ERR_CONTINUATION_NOT_COPPER := "continuation_layer_not_copper"
## Epoch UX1 station 10 (DCR 019fd095e694, docket 019fd057ea0b comments 1026/
## 1028): move_junction's own named refusals.
const ERR_CONSTRAINT_STALE := "constraint_stale_candidate"
const ERR_JUNCTION_NOT_FOUND := "junction_not_found"
## Epoch UX3, K7: the candidate is FROZEN — settled geometry refuses edits
## until an explicit unfreeze() demotes it back to a draft.
const ERR_FROZEN := "candidate_frozen"
const ERR_AMBIGUOUS_JUNCTION := "ambiguous_junction"
const ERR_DEGENERATE_RESULT := "degenerate_result"

## Coincidence epsilon for edit geometry, in board mm. Two points closer than
## this are the SAME point — which is what makes a split at an endpoint a
## degenerate (zero-length) insert rather than a legal one.
const EDIT_EPS_MM := 1.0e-4
## Floor for the "did the click land on this segment" tolerance, so a hair-thin
## candidate is still clickable. The real tolerance is half the segment's own
## width (its copper), which is the same rule the canvas pick uses.
const EDIT_MIN_TOL_MM := 0.05


## Mark ONE candidate's validation "stale" and DROP its stored findings.
##
## The findings go because a finding names SUBJECT IDENTITY (candidate_id +
## segment_id/via_id, see apply_check_result) and a verb that changed the set or
## the geometry may have destroyed those subjects. Keeping them would be keeping
## a claim about copper that is gone — the exact "stale findings render against
## new geometry" failure INV-2 exists to prevent, closed once at the store
## instead of at every future render site.
##
## rebase() deliberately does NOT drop findings: a board-revision change removes
## no subject — the candidate's own segments/vias are all still there — so its
## findings still describe things that exist. Different cause, different
## disposal.
func mark_stale(candidate_id: String) -> bool:
	var c = get_candidate(candidate_id)
	if c == null:
		return false
	if str(c.validation) == "stale":
		return false
	set_validation(candidate_id, "stale")  # emits validation_changed
	_findings.erase(candidate_id)
	return true


## INV-2, live-set half: stale every candidate that is LIVE right now and holds
## a real verdict. Called AFTER the move that changed the set. Returns the ids
## actually marked (already-stale/unchecked ones are skipped, so it is
## idempotent and emits no duplicate validation_changed).
func _stale_live_verdicts() -> Array:
	var marked: Array = []
	for id in live_candidate_ids():
		var c = get_candidate(str(id))
		if c == null or not (str(c.validation) in VERDICT_VALIDATIONS):
			continue
		if mark_stale(str(id)):
			marked.append(str(id))
	return marked


# ── INV-1: the composite COMMIT transaction ───────────────────────────────────

## Batch-scoped INV-2 deferral (docket 019fd0ab6dd2, Codex review P1). While
## true, _apply_disposition RECORDS that a live-boundary move wants the stale
## pass instead of running it; commit_batch fires the pass ONCE after every
## member has left the live set, so batch members never stale each other and
## exactly the outside candidates lose their verdicts. Set ONLY around
## commit_batch's synchronous disposition phase — never across an await, never
## by any other verb.
var _defer_stale_pass := false
var _deferred_stale_needed := false

## Reentrancy guard (Codex re-review on 019fd0bf2a04): true while commit_batch
## is writing copper or applying dispositions. Every disposition verb that is
## not the transaction's own call refuses with ERR_COMMIT_IN_PROGRESS while
## set (see _apply_disposition). Cleared BEFORE the deferred INV-2 stale pass
## and end_batch: by then the batch is fully applied and consistent, so a
## handler reacting to those emissions acts on exactly the state a
## single-commit handler always did.
var _commit_transaction_active := false


## Endpoint-coincidence epsilon (board mm) for chaining consecutive validated
## seg_plan entries into one trace. The router splits at EXACT shared points, so
## this only absorbs float noise — the same constant family as the canvas
## draw-time run merge (pcb_canvas.gd CANDIDATE_RUN_CHAIN_EPSILON_MM).
const _COMMIT_CHAIN_EPSILON_MM := 0.0001


## Merge consecutive seg_plan entries that share layer + width and whose
## endpoints coincide into single multi-point entries (docket 019fce6184c2).
## Consecutive-only, deliberately: seg_plan preserves the router's emission
## order, which is the route's walk order — a non-adjacent same-layer segment
## is a genuinely separate run (e.g. the far side of a via) and must stay its
## own trace. The merged entry keeps the FIRST segment's id (ids are only read
## by post-merge error messages).
static func _chain_seg_plan(seg_plan: Array) -> Array:
	var out: Array = []
	for plan in seg_plan:
		if not out.is_empty():
			var prev: Dictionary = out[out.size() - 1]
			var prev_pts: Array = prev["points"]
			var pts: Array = plan["points"]
			if str(prev["layer"]) == str(plan["layer"]) \
					and is_equal_approx(float(prev["width"]), float(plan["width"])) \
					and (prev_pts[prev_pts.size() - 1] as Vector2).distance_to(pts[0] as Vector2) \
						<= _COMMIT_CHAIN_EPSILON_MM:
				for k in range(1, pts.size()):
					prev_pts.append(pts[k])
				continue
		out.append({
			"id": str(plan["id"]),
			"layer": str(plan["layer"]),
			"width": float(plan["width"]),
			"points": (plan["points"] as Array).duplicate(),
		})
	return out

## Turn a candidate into real copper on `board` as ONE undoable step.
##
## WHAT "ONE STEP" MEANS HERE, precisely:
##   * every trace and via is written inside a single begin_batch/end_batch
##     pair, so PCBData performs exactly ONE save_to_history and ONE
##     board_revision bump for the whole commit (one Ctrl+Z reverts all of it);
##   * the candidate is marked committed INSIDE that batch, so the history
##     entry end_batch appends carries the POST-commit workspace layer;
##   * and attach_workspace_snapshot() stamps the PRE-commit workspace layer
##     onto the history entry that already represents the pre-commit BOARD.
##     That pairing is what makes undo-after-commit restore BOTH stores: undo
##     restores the PREVIOUS entry, so the pre-commit disposition has to be on
##     the PREVIOUS entry, and this is the moment we know it.
##
## ATOMICITY: ALL validation precedes ALL mutation. Every failure mode below is
## detected before begin_batch, so a refused commit leaves the board untouched,
## the disposition untouched and no history entry behind. The post-begin_batch
## rollback is defensive only (a board that accepted an add and then cannot find
## it) and is documented at its site.
##
## SOURCE HINTS are CONSUMED BY RECORD, not by deletion: the candidate's
## source_hint_ids are written onto its correlation as `consumed_hint_ids` and
## the task closes (derived). No annotation is removed. Deleting the hint
## annotations here would put an un-undoable side effect inside a step whose
## whole promise is that one Ctrl+Z reverts it — annotations are not board state
## and ride no history bucket — and the annotation store itself is what S5
## (C4b) retires. Provenance is not lost either way: source_hint_ids stays on
## the candidate.
##
## Returns {"ok": true, …} or {"ok": false, "error": <named code>, "message"}.
func commit(candidate_id: String, board = null) -> Dictionary:
	# Thin wrapper over commit_batch — ONE implementation of the composite
	# transaction (docket 019fd0ab6dd2). The reply is kept byte-compatible with
	# the pre-batch shape every existing caller and test reads.
	var batch: Dictionary = commit_batch([candidate_id], board)
	if not bool(batch.get("ok", false)):
		return batch
	var r: Dictionary = (batch.get("results", []) as Array)[0]
	return {
		"ok": true,
		"candidate_id": str(r["candidate_id"]),
		"task_id": str(r["task_id"]),
		"task_state": str(r["task_state"]),
		"trace_ids": r["trace_ids"],
		"via_ids": r["via_ids"],
		"consumed_hint_ids": r["consumed_hint_ids"],
		"validation_at_commit": str(r["validation_at_commit"]),
		"action": str(batch.get("action", "")),
	}


## P1-B (Codex 1047): the CURRENT constraint revision governing a candidate —
## the max across (a) the candidate's own task's constraint and (b) each
## source hint's owner-gated constraint via task_for_hint (the exact
## per-hint set _task_constraints_for_hints would emit on the next propose,
## which since P1-A may live on surviving singletons beside a merged task).
## -1 = nothing constrained governs this candidate. KNOWN LIMIT (documented
## in the Codex-1047 trail): the candidate's stamp is a single int (the
## revision methods.py threaded onto the route), so with MULTIPLE governing
## constraints the comparison is against the max — a lower-revision sibling
## advancing to a value still <= the stamped max is not flagged. Per-hint
## stamps end-to-end are post-boundary engine work.
func _governing_constraint_revision(c) -> int:
	var rev := -1
	var own = tasks.get(str(c.task_id), null)
	if own != null and own.is_constrained():
		rev = max(rev, int(own.routing_constraint.get("revision", 0)))
	for h in c.source_hint_ids:
		var t = task_for_hint(str(h))
		if t != null and t.is_constrained() \
				and str(t.routing_constraint.get("owner_hint_id", "")) == str(h):
			rev = max(rev, int(t.routing_constraint.get("revision", 0)))
	return rev


## The highest constraint_revision_floor among this candidate's governing
## tasks (Epoch UX2 station 2 follow-up, Codex 1049 finding 1). >0 means a
## constraint that once governed this candidate's tasks was CLEARED at that
## revision; 0 = no clear ever happened. Same task walk as
## _governing_constraint_revision above, reading the floor instead of the
## live constraint.
func _governing_constraint_floor(c) -> int:
	var floor_rev := 0
	var own = tasks.get(str(c.task_id), null)
	if own != null and "constraint_revision_floor" in own:
		floor_rev = max(floor_rev, int(own.constraint_revision_floor))
	for h in c.source_hint_ids:
		var t = task_for_hint(str(h))
		if t != null and "constraint_revision_floor" in t:
			floor_rev = max(floor_rev, int(t.constraint_revision_floor))
	return floor_rev


## Per-candidate PRE-FLIGHT: everything the commit transaction can refuse,
## checked before ANY mutation. Extracted verbatim from the single-candidate
## commit so batch and single share one set of refusals (docket 019fd0ab6dd2).
## Returns {ok:true, candidate, candidate_id, seg_plan, via_plan,
## validation_at_commit} or a _verb_error dict.
##
## validation_at_commit is CAPTURED HERE, before any batch member mutates the
## board — that is the whole point of batching: committing candidate 1 bumps
## the board revision and (correctly) stales the live set, but candidates 2..N
## of the SAME approved batch must report the verdict they actually carried at
## the decision moment, not the staleness their own batch-mate caused.
func _commit_preflight(candidate_id: String, board) -> Dictionary:
	var c = get_candidate(candidate_id)
	if c == null:
		return _verb_error(ERR_NO_CANDIDATE, "no candidate '%s' in this workspace" % candidate_id, candidate_id)
	# remove_trace / remove_via_by_id are REQUIRED up front (Codex review P2):
	# they are the rollback path's tools, and a board that can accept copper
	# but cannot take it back cannot honour the no-half-state claim — refuse
	# before writing rather than discovering it mid-fault.
	if board == null or not is_instance_valid(board) \
			or not board.has_method("begin_batch") or not board.has_method("end_batch") \
			or not board.has_method("new_trace") or not board.has_method("add_trace") \
			or not board.has_method("add_via") or not board.has_method("remove_trace") \
			or not board.has_method("remove_via_by_id"):
		return _verb_error(ERR_NO_BOARD,
			"no board to commit onto (a commit writes real copper and must be able to roll it back — it cannot run against the model alone)",
			candidate_id)

	# RE-COMMIT IS REFUSED, and it has to be refused HERE rather than left to the
	# legality table. An IDENTITY move (committed -> committed) is LEGAL by that
	# table, deliberately: mark_committed supports a re-commit because the
	# annotation-accept path may re-record the copper ids of a candidate that is
	# already committed, and refusing that would break a supported call. But THIS
	# verb WRITES COPPER. Running it twice would lay a second full set of traces
	# and vias for one candidate and then overwrite the recorded ids with the new
	# ones — the old copper orphaned on the board, unreachable by the undo that
	# only reverts the last step. So the composite transaction refuses by name
	# where the raw marker does not.
	if str(c.disposition) == "committed":
		return _verb_error(ERR_ALREADY_COMMITTED,
			"candidate '%s' is already committed — its copper is on the board; undo the commit (or uncommit it) before committing again"
				% candidate_id, candidate_id)

	# LEGALITY — the same table every other workflow verb consults, so
	# "commit an already-rejected candidate" is refused by name, before the
	# board is opened.
	var legality: String = PcbRouteCandidate.transition_error(str(c.disposition), "committed")
	if not legality.is_empty():
		_record_refusal(candidate_id, str(c.disposition), "committed", legality, "commit")
		return _verb_error(legality,
			"cannot commit a candidate whose disposition is '%s'" % str(c.disposition), candidate_id)

	# P1-B (Codex 1047): CONSTRAINT STALENESS. A steer (or a fresh station-12
	# seed) advances the governing task constraint; if the reroute that was
	# meant to answer it then FAILED, the still-live prior candidate was
	# generated against the OLD constraint. Committing it would silently land
	# copper the current steering explicitly moved away from — refuse by name,
	# before any mutation, same up-front discipline as every check above.
	# candidate.constraint_revision is the DURABLE generation stamp
	# (ingest_record); -1 (generated unconstrained / pre-provenance record)
	# is stale against ANY current constraint by the same rule.
	var governing := _governing_constraint_revision(c)
	if governing >= 0 and int(c.constraint_revision) < governing:
		return _verb_error(ERR_CONSTRAINT_STALE,
			"candidate '%s' was generated against constraint revision %d but the governing constraint has advanced to revision %d — re-propose/reroute under the current constraint (minerva_pcb_workspace_reroute_route), or remove it with reroute_route's clear_constraint:true, before committing"
				% [candidate_id, int(c.constraint_revision), governing], candidate_id)
	# CLEARED-CONSTRAINT STALENESS (Codex 1049 finding 1): with no live
	# constraint (governing -1) a candidate STAMPED with one (constraint_
	# revision >= 0, at or below a task's clear floor) was generated under a
	# corridor the user explicitly REMOVED — e.g. clear_constraint whose
	# router leg failed, leaving the prior constrained candidate live.
	# Committing it would land the very copper the clear moved away from.
	# A candidate generated unconstrained (stamp -1 / no key) — including
	# everything proposed AFTER the clear — commits freely: unguided is
	# exactly what the clear asked for.
	if governing < 0 and int(c.constraint_revision) >= 0:
		var cleared_floor := _governing_constraint_floor(c)
		if cleared_floor > 0 and int(c.constraint_revision) <= cleared_floor:
			return _verb_error(ERR_CONSTRAINT_STALE,
				"candidate '%s' was generated under constraint revision %d, but that constraint has since been CLEARED (clear_constraint) — its copper follows a corridor the user removed; re-propose (unguided) or reroute before committing"
					% [candidate_id, int(c.constraint_revision)], candidate_id)

	# GEOMETRY PRE-FLIGHT. Everything the board write needs, checked up front.
	if c.segments.is_empty() and c.vias.is_empty():
		return _verb_error(ERR_NO_GEOMETRY, "candidate '%s' carries no segments and no vias" % candidate_id, candidate_id)
	var seg_plan: Array = []
	for seg in c.segments:
		if not (seg is Dictionary):
			return _verb_error(ERR_UNMODELABLE_SEGMENT, "candidate '%s' holds a non-dictionary segment" % candidate_id, candidate_id)
		var seg_dict: Dictionary = seg
		# DISTINCT points, not just points. The old count admitted a segment
		# whose two points were the same point, which lands a zero-length
		# segment on the board and makes it uncompilable — the author then has
		# no working board and no verb that names what to remove.
		var pts: Array = drop_coincident_points(seg_dict.get("points", []))
		if pts.size() < 2:
			return _verb_error(ERR_UNMODELABLE_SEGMENT,
				"segment '%s' collapses to %d distinct point(s); copper needs at least two"
					% [str(seg_dict.get("id", "")), pts.size()], candidate_id)
		var w := float(seg_dict.get("width", 0.0))
		if w <= 0.0:
			return _verb_error(ERR_UNMODELABLE_SEGMENT,
				"segment '%s' declares width %s — zero-width copper is not copper"
					% [str(seg_dict.get("id", "")), str(w)], candidate_id)
		seg_plan.append({
			"id": str(seg_dict.get("id", "")),
			"layer": PcbLayerStack.kicad_to_canon(seg_dict.get("layer", "top")),
			"width": w, "points": pts,
		})
	# ONE TRACE PER CONTIGUOUS RUN, not per segment (docket 019fce6184c2). The
	# router emits a bend as two segments sharing an endpoint; materializing
	# each as its own 2-point trace fragments one piece of copper into N trace
	# identities — rendered as N butt-capped polylines with a wedge gap at
	# every shared corner (HITL-3: "outer corners disconnected"), promoted to
	# YAML as N entries where the canonical style is one multi-point polyline.
	# Chaining here, after per-segment validation, keeps the pre-flight errors
	# named per segment while the copper lands the way a human would draw it.
	seg_plan = _chain_seg_plan(seg_plan)
	var via_plan: Array = []
	for via in c.vias:
		if not (via is Dictionary):
			return _verb_error(ERR_UNMODELABLE_VIA, "candidate '%s' holds a non-dictionary via" % candidate_id, candidate_id)
		var via_dict: Dictionary = via
		if not (via_dict.get("position", null) is Vector2):
			return _verb_error(ERR_UNMODELABLE_VIA,
				"via '%s' has no usable position" % str(via_dict.get("id", "")), candidate_id)
		if not c.via_span_legal(via_dict):
			return _verb_error(ERR_ILLEGAL_VIA_SPAN,
				"via '%s' spans %s->%s, which is not a legal via span on this stack"
					% [str(via_dict.get("id", "")), str(via_dict.get("from_layer", "")),
						str(via_dict.get("to_layer", ""))], candidate_id)
		via_plan.append(via_dict)

	# A via proposed as an ENTITY has a stronger commit contract than a router
	# candidate's internal layer-change vias: the point itself must still be a
	# legal board placement. Proposal-time validation is not sufficient because
	# the board may have been resized, its nets may have changed, or a real via
	# may have landed while the ghost was waiting for review. Re-read the SAME
	# PCBData rule immediately before mutation so Accept can never turn a stale,
	# formerly-valid ghost into invalid copper.
	var junction_plan: Dictionary = {}
	if _is_standalone_via_candidate(c):
		if not board.has_method("resolve_via_target"):
			return _verb_error(ERR_NO_BOARD,
				"the board cannot validate a standalone via placement at commit time",
				candidate_id)
		var standalone: Dictionary = via_plan[0]
		var dims: Dictionary = _via_dimensions(standalone, board)
		var authored_net := str(standalone.get("authored_net", str(c.net)))
		var target: Dictionary = board.resolve_via_target(
			standalone["position"], float(dims["diameter"]), float(dims["drill"]),
			authored_net)
		if not bool(target.get("ok", false)):
			return _verb_error(ERR_VIA_NOT_PLACEABLE,
				str(target.get("error", "the via cannot be placed there")), candidate_id)
		var expected_trace := str(standalone.get("junction_trace_id", ""))
		var actual_trace := str(target.get("trace_id", ""))
		var actual_position: Vector2 = target.get("position", standalone["position"])
		if expected_trace != actual_trace \
				or actual_position.distance_to(standalone["position"]) > EDIT_EPS_MM \
				or str(target.get("net_name", authored_net)) != str(c.net):
			return _verb_error(ERR_VIA_NOT_PLACEABLE,
				"the board under standalone via candidate '%s' changed since it was proposed — move or re-propose it before commit"
					% candidate_id, candidate_id)
		if not actual_trace.is_empty():
			if not board.has_method("insert_trace_junction"):
				return _verb_error(ERR_NO_BOARD,
					"the board cannot materialize the trace junction this via proposal requires",
					candidate_id)
			junction_plan = {"trace_id": actual_trace, "position": actual_position}

	return {"ok": true, "candidate": c, "candidate_id": candidate_id,
		"seg_plan": seg_plan, "via_plan": via_plan,
		"junction_plan": junction_plan,
		"validation_at_commit": str(c.validation)}


## INV-1 ACROSS A BATCH (docket 019fd0ab6dd2): commit several candidates as ONE
## undoable step. Sequential single commits punished the reviewer for approving
## a batch — the first commit bumped the board revision and marked its CLEAN,
## just-set-checked siblings stale, so commits 2..N reported
## validation_at_commit "stale" on geometry nothing had invalidated but their
## own batch-mate. Here:
##   * ALL validation precedes ALL mutation, across the WHOLE batch — any
##     refusal (unknown id, duplicate id, illegal disposition, unmodelable
##     geometry) aborts before begin_batch with the board untouched;
##   * one begin_batch/end_batch pair — ONE history entry, ONE board_revision
##     bump, one Ctrl+Z reverting every batch member's copper AND disposition;
##   * validation_at_commit per member is the PRE-BATCH verdict (see
##     _commit_preflight's doc);
##   * mid-write board faults roll back EVERY batch member's copper written so
##     far (the accumulated id lists), not just the failing candidate's — the
##     no-half-state claim holds for the batch exactly as it held for one.
func commit_batch(candidate_ids: Array, board = null) -> Dictionary:
	# A commit inside a commit (a signal handler re-entering) is refused, not
	# nested — see _apply_disposition's reentrancy-guard doc.
	if _commit_transaction_active:
		return _verb_error(ERR_COMMIT_IN_PROGRESS,
			"a commit transaction is already applying; workspace verbs called from its signal handlers are refused")
	var ids: Array = []
	for cid in candidate_ids:
		ids.append(str(cid))
	if ids.is_empty():
		return _verb_error(ERR_NO_CANDIDATE, "commit_batch needs at least one candidate id")
	var seen: Dictionary = {}
	for cid in ids:
		# A duplicate inside one batch would be the same double-commit hazard
		# the single verb refuses (see the re-commit doc in _commit_preflight),
		# just spelled differently — refused under its OWN name (Codex review
		# P2): the candidate is not already committed, it is named twice, and
		# the error must say which mistake was made.
		if seen.has(cid):
			return _verb_error(ERR_DUPLICATE_CANDIDATE,
				"candidate '%s' appears more than once in one batch" % cid, cid)
		seen[cid] = true

	# ALL validation precedes ALL mutation — for the batch, not per member.
	var plans: Array = []
	for cid in ids:
		var pf: Dictionary = _commit_preflight(cid, board)
		if not bool(pf.get("ok", false)):
			return pf
		plans.append(pf)

	# Board validation above sees only REAL copper. Two standalone ghosts at the
	# same point would therefore both look valid during this all-up-front batch
	# preflight and then materialize as stacked vias. Proposal creation prevents
	# new duplicates, but persisted/legacy workspaces can still contain them, so
	# keep the transaction honest here as well. Preserve existing route-batch
	# semantics unless at least one side is the DCR's standalone via entity.
	var batch_via_error: Dictionary = _standalone_batch_via_error(plans)
	if not batch_via_error.is_empty():
		return batch_via_error

	# ── mutation, PHASE A: ALL copper, NO workspace state (Codex review P1) ───
	# Copper writes are the only step that can fail mid-batch (a board fault on
	# add_trace/add_via). Writing every member's copper BEFORE any disposition
	# moves means a phase-A rollback touches ONLY the board: no member has been
	# marked, no verdict staled, no correlation written — the workspace is
	# bitwise what it was before the call, so "refused batch left the workspace
	# untouched" is true by construction rather than by compensation.
	#
	# Bind FIRST so every history snapshot from here on carries bucket 8, then
	# pair the pre-commit workspace layer onto the entry the undo will land on.
	if board.has_method("bind_routing_workspace"):
		board.bind_routing_workspace(self)
	if board.has_method("attach_workspace_snapshot"):
		board.attach_workspace_snapshot()

	var all_trace_ids: Array = []
	var all_via_ids: Array = []
	var copper: Array = []  # per-plan {trace_ids, via_ids}, index-aligned with plans
	_commit_transaction_active = true
	board.begin_batch()
	for pf in plans:
		var c = pf["candidate"]
		var cid := str(pf["candidate_id"])
		var net := str(c.net)
		var trace_ids: Array = []
		var via_ids: Array = []
		for plan in pf["seg_plan"]:
			var trace = board.new_trace()
			trace.net_name = net
			trace.layer = str(plan["layer"])
			trace.width = float(plan["width"])
			for point in plan["points"]:
				trace.waypoints.append(point)
			board.add_trace(trace)
			var tid := str(trace.id)
			# Defensive only: pre-flight already proved this geometry is
			# modelable, so a board that accepted the add and then cannot find
			# it is a board fault, not a caller fault. Roll back EVERYTHING the
			# batch has written — earlier members included, and THIS id too
			# when the board minted one but lost the trace (Codex review P2:
			# the failing item must be in the rollback list, not just the
			# accepted ones).
			if tid.is_empty() or (board.has_method("get_trace") and board.get_trace(tid) == null):
				var rb_traces: Array = all_trace_ids + trace_ids
				if not tid.is_empty():
					rb_traces.append(tid)
				_commit_transaction_active = false
				return _rollback_commit(board, rb_traces, all_via_ids + via_ids,
					cid, "board refused a trace for segment '%s'" % str(plan["id"]))
			trace_ids.append(tid)
		var dr: Dictionary = board.design_rules if board.design_rules is Dictionary else {}
		for via_dict in pf["via_plan"]:
			var via_size := float(via_dict.get("diameter", 0.0))
			if via_size <= 0.0:
				via_size = float(dr.get("via_diameter_mm", 0.0))
			if via_size <= 0.0:
				via_size = 0.8
			var via_drill := float(via_dict.get("drill", 0.0))
			if via_drill <= 0.0:
				via_drill = float(dr.get("via_drill_mm", 0.0))
			if via_drill <= 0.0:
				via_drill = 0.4
			var vid := str(board.add_via({
				"position": via_dict.get("position"),
				"size": via_size,
				"drill": via_drill,
				"net_name": net,
				"from_layer": str(via_dict.get("from_layer", "top")),
				"to_layer": str(via_dict.get("to_layer", "bottom")),
			}))
			if vid.is_empty():
				# LIMITATION, acknowledged (Codex 1032): a board that INSERTS a
				# via and then returns an empty handle cannot be recovered by
				# id-list deletion — only a true board abort/snapshot could.
				# PCBData guarantees a non-empty id for an inserted via today,
				# so this branch only fires when nothing was inserted.
				_commit_transaction_active = false
				return _rollback_commit(board, all_trace_ids + trace_ids, all_via_ids + via_ids,
					cid, "board refused a via for '%s'" % str(via_dict.get("id", "")))
			via_ids.append(vid)
		all_trace_ids.append_array(trace_ids)
		all_via_ids.append_array(via_ids)
		copper.append({"trace_ids": trace_ids, "via_ids": via_ids})

	# ── mutation, PHASE B: dispositions, structurally non-failing ─────────────
	# Every transition was proved legal at pre-flight and this function is
	# synchronous (no awaits), so nothing can have changed a disposition in
	# between — mark_committed cannot refuse here except through a programming
	# error, and the defensive revert below exists only for that impossibility.
	# The INV-2 stale pass is DEFERRED (see _apply_disposition): member A's
	# commit must not stale members B..N of the same approved batch. After the
	# loop, ONE pass fires — batch members have all left the live set by then,
	# so exactly the candidates OUTSIDE the batch lose their verdicts.
	var results: Array = []
	_defer_stale_pass = true
	_deferred_stale_needed = false
	for i in range(plans.size()):
		var pf: Dictionary = plans[i]
		var c = pf["candidate"]
		var cid := str(pf["candidate_id"])
		var member_copper: Dictionary = copper[i]
		if not mark_committed(cid, member_copper["trace_ids"], member_copper["via_ids"], true):
			# Unreachable by construction — and the reentrancy guard now
			# ENFORCES the construction (a signal handler mutating a later
			# member is refused, see _apply_disposition), so this survives only
			# as the emergency path for a genuine programming error. Restore
			# every disposition this phase already moved — direct field
			# restore, deliberately bypassing the legality table because the
			# goal is the exact pre-batch state — then remove all copper.
			_defer_stale_pass = false
			_commit_transaction_active = false
			for j in range(i):
				var prev = plans[j]["candidate"]
				prev.disposition = str(correlations.get(str(plans[j]["candidate_id"]), {}).get("prior_disposition", "proposed"))
				_sync_held_indexes(str(plans[j]["candidate_id"]), str(prev.disposition))
				_refresh_task_state(str(prev.task_id))
				var bad_rec: Dictionary = correlations.get(str(plans[j]["candidate_id"]), {})
				bad_rec.erase("committed_trace_ids")
				bad_rec.erase("committed_via_ids")
				bad_rec.erase("prior_disposition")
				correlations[str(plans[j]["candidate_id"])] = bad_rec
			return _rollback_commit(board, all_trace_ids, all_via_ids,
				cid, "the candidate refused the committed transition after the copper was written")
		var rec: Dictionary = correlations.get(cid, {})
		rec["consumed_hint_ids"] = _to_string_array(c.source_hint_ids)
		correlations[cid] = rec
		results.append({
			"candidate_id": cid,
			"task_id": str(c.task_id),
			"net": str(c.net),
			"trace_ids": member_copper["trace_ids"],
			"via_ids": member_copper["via_ids"],
			"consumed_hint_ids": _to_string_array(c.source_hint_ids),
			"validation_at_commit": str(pf["validation_at_commit"]),
		})
	# Standalone proposals that intentionally targeted an existing trace become
	# explicit canonical junctions only after every candidate has transitioned
	# successfully. No failure branch remains beyond this point, so these
	# topology-only edits never need the copper rollback path.
	for pf in plans:
		var junction: Dictionary = pf.get("junction_plan", {})
		if not junction.is_empty():
			board.insert_trace_junction(
				str(junction.get("trace_id", "")), junction.get("position", Vector2.ZERO))
	_defer_stale_pass = false
	# Guard drops BEFORE the deferred stale pass and end_batch: the batch is
	# fully applied and consistent from here, so handlers reacting to the
	# remaining emissions act on exactly the state single-commit handlers
	# always did.
	_commit_transaction_active = false
	if _deferred_stale_needed:
		_deferred_stale_needed = false
		# The one INV-2 pass for the whole batch: members are terminal now, so
		# this stales exactly the live candidates OUTSIDE the batch.
		_stale_live_verdicts()

	# History label: the single-candidate wording is preserved verbatim for a
	# one-element batch so existing history/undo expectations stay intact.
	var action: String
	if results.size() == 1:
		var net0 := str((results[0] as Dictionary).get("net", ""))
		action = "Commit route candidate %s (%s)" % [str((results[0] as Dictionary)["candidate_id"]),
			net0 if not net0.is_empty() else "no net"]
	else:
		var nets: PackedStringArray = PackedStringArray()
		for r in results:
			var n := str((r as Dictionary).get("net", ""))
			if not n.is_empty() and not (n in nets):
				nets.append(n)
		action = "Commit %d route candidates (%s)" % [results.size(), ", ".join(nets)]
	board.end_batch(action)

	# task_state is DERIVED and read after the whole batch landed, so a batch
	# committing two generations' tasks reports each task's final state.
	for r in results:
		(r as Dictionary)["task_state"] = task_state(str((r as Dictionary)["task_id"]))

	return {"ok": true, "results": results, "committed_count": results.size(),
		"trace_ids": all_trace_ids, "via_ids": all_via_ids, "action": action}


## Undo the writes a failing commit already made, close the batch, and report.
## Named so the "no half-state" claim is a function, not a comment.
func _rollback_commit(board, trace_ids: Array, via_ids: Array, candidate_id: String, why: String) -> Dictionary:
	for tid in trace_ids:
		if board.has_method("remove_trace"):
			board.remove_trace(str(tid))
	for vid in via_ids:
		if board.has_method("remove_via_by_id"):
			board.remove_via_by_id(str(vid))
	# PCBData has no abort_batch, and adding one is outside this unit's fence
	# (pcb_data.gd is in fence for the history CODEC only), so the batch is
	# closed the only way it can be. Because the batch was touched, this leaves
	# ONE history entry describing a board identical to the one before it — a
	# redundant entry, never a wrong one. Unreachable in practice: the pre-flight
	# above proves the geometry before any of this runs.
	board.end_batch("Commit route candidate %s (rolled back)" % candidate_id)
	return _verb_error(ERR_BOARD_WRITE, why, candidate_id)


static func _verb_error(code: String, message: String, candidate_id: String = "") -> Dictionary:
	return {"ok": false, "error": code, "message": message, "candidate_id": candidate_id}


# ── INV-3: the PATH-SCOPED via/layer edit entry ───────────────────────────────

## True only for the DCR's via-as-entity candidate. Router candidates may also
## carry no trace segments in an unhappy/partial answer, but they retain task or
## source-hint provenance. The entity verb deliberately creates neither: its
## whole meaning is exactly one independent via at one point.
static func _is_standalone_via_candidate(candidate) -> bool:
	return candidate != null \
		and candidate.segments.is_empty() and candidate.vias.size() == 1 \
		and str(candidate.task_id).is_empty() and candidate.source_hint_ids.is_empty()


## Resolve the dimensions commit will actually write. Kept beside validation so
## the gate and materializer cannot disagree when a legacy candidate omitted its
## explicit diameter/drill and relies on board design-rule defaults.
static func _via_dimensions(via: Dictionary, board) -> Dictionary:
	var dr: Dictionary = board.design_rules if board.design_rules is Dictionary else {}
	var diameter := float(via.get("diameter", 0.0))
	if diameter <= 0.0:
		diameter = float(dr.get("via_diameter_mm", 0.0))
	if diameter <= 0.0:
		diameter = 0.8
	var drill := float(via.get("drill", 0.0))
	if drill <= 0.0:
		drill = float(dr.get("via_drill_mm", 0.0))
	if drill <= 0.0:
		drill = 0.4
	return {"diameter": diameter, "drill": drill}


## A live candidate via already claims this point even though it is not board
## copper yet. This closes the gap PCBData.via_author_error cannot see: two MCP
## calls made before either ghost is accepted. Terminal ghosts claim nothing;
## committed vias are already visible through the board rule.
func _candidate_via_error(position: Vector2, except_candidate_id: String = "") -> String:
	for candidate in candidates.values():
		if candidate == null or str(candidate.disposition) in ["superseded", "rejected", "committed"]:
			continue
		if not except_candidate_id.is_empty() and str(candidate.candidate_id) == except_candidate_id:
			continue
		for raw_via in candidate.vias:
			if not (raw_via is Dictionary):
				continue
			var via: Dictionary = raw_via
			var other_position = via.get("position", null)
			if not (other_position is Vector2):
				continue
			var claim := maxf(float(via.get("diameter", 0.8)) * 0.5, 0.05)
			if (other_position as Vector2).distance_to(position) <= claim:
				return "A proposed via already sits at (%.3f, %.3f) in candidate '%s'." \
					% [position.x, position.y, str(candidate.candidate_id)]
	return ""


## Cross-plan half of commit validation. All ordinary route candidates retain
## their established batch semantics; the extra placement gate applies when a
## standalone entity would overlap any other via in the same atomic approval.
static func _standalone_batch_via_error(plans: Array) -> Dictionary:
	for i in range(plans.size()):
		var left: Dictionary = plans[i]
		var left_candidate = left.get("candidate", null)
		for j in range(i + 1, plans.size()):
			var right: Dictionary = plans[j]
			var right_candidate = right.get("candidate", null)
			if not _is_standalone_via_candidate(left_candidate) \
					and not _is_standalone_via_candidate(right_candidate):
				continue
			for left_raw in left.get("via_plan", []):
				if not (left_raw is Dictionary) or not ((left_raw as Dictionary).get("position") is Vector2):
					continue
				var left_via: Dictionary = left_raw
				for right_raw in right.get("via_plan", []):
					if not (right_raw is Dictionary) or not ((right_raw as Dictionary).get("position") is Vector2):
						continue
					var right_via: Dictionary = right_raw
					var claim := maxf(maxf(float(left_via.get("diameter", 0.8)),
						float(right_via.get("diameter", 0.8))) * 0.5, 0.05)
					if (left_via["position"] as Vector2).distance_to(right_via["position"]) <= claim:
						var right_id := str(right.get("candidate_id", ""))
						return _verb_error(ERR_VIA_NOT_PLACEABLE,
							"standalone via candidate '%s' overlaps candidate '%s' in the same commit batch"
								% [str(left.get("candidate_id", "")), right_id], right_id)
	return {}

## Propose a VIA ON ITS OWN — a candidate carrying one via and no segments.
##
## DCR 01a0033a12a9 plus owner HITL clarification: a via in empty space is an
## independent entity, while a via physically touching an existing trace is an
## intentional junction. The latter snaps, inherits the trace net, and records
## the trace identity so Accept can materialize the bisection atomically.
##
## This is the Proposals-area twin of PCBData.add_via / minerva_pcb_place_via,
## completing the panel's two-area language: Tools place a REAL via, Proposals
## propose a GHOST via that Accept turns into copper. Vias-only candidates were
## already modelled — panel_tools.gd's candidate summariser reports "honest
## ZEROS" for a geometry-less candidate — so this creates no new shape, it
## reaches an existing one that nothing could previously produce.
##
## NO LAYER ARGUMENT, deliberately. A v1 via is a through via joining every
## copper layer, so there is nothing to choose; and which layer a RUN continues
## on is a routing decision that belongs to a trace verb, not to this one.
##
## `net` may be empty — an unassigned via is legitimate (the fiber-laser
## workflow orders via-only boards and lases copper against them later).
## Returns {ok:true, candidate_id, via_id, at} or {ok:false, error, message}.
func propose_via(position: Vector2, net: String = "", diameter: float = 0.8,
		drill: float = 0.4, board = null) -> Dictionary:
	if _commit_transaction_active:
		return _verb_error(ERR_COMMIT_IN_PROGRESS,
			"a commit transaction is applying; new candidates are refused from its signal handlers")
	if board == null or not is_instance_valid(board) or not board.has_method("resolve_via_target"):
		return _verb_error(ERR_NO_BOARD,
			"a standalone via proposal needs the live board's placement rule")
	var target: Dictionary = board.resolve_via_target(position, diameter, drill, net)
	var placement_error := "" if bool(target.get("ok", false)) \
		else str(target.get("error", "the via cannot be placed there"))
	var resolved_position: Vector2 = target.get("position", position)
	if placement_error.is_empty():
		placement_error = _candidate_via_error(resolved_position)
	if not placement_error.is_empty():
		return _verb_error(ERR_VIA_NOT_PLACEABLE, placement_error)

	var span: Array = PcbLayerStack.default_through_via_span()
	var c = PcbRouteCandidate.new()
	c.net = str(target.get("net_name", net))
	var via_id := next_via_id()
	var via: Dictionary = PcbRouteCandidate.make_via(
		via_id, resolved_position, str(span[0]), str(span[1]), diameter, drill)
	via["authored_net"] = net
	via["junction_trace_id"] = str(target.get("trace_id", ""))
	c.add_via(via)
	var cid := str(add_candidate(c))
	if cid.is_empty():
		return _verb_error(ERR_DUPLICATE_CANDIDATE, "the workspace refused the candidate")
	return {"ok": true, "candidate_id": cid, "via_id": via_id,
		"at": [resolved_position.x, resolved_position.y], "net_name": str(c.net),
		"trace_id": str(target.get("trace_id", "")),
		"snapped_to_trace": bool(target.get("snapped", false)),
		"from_layer": str(span[0]), "to_layer": str(span[1])}


## Insert a via into a candidate at `position`, flipping the run DOWNSTREAM of
## that point onto `to_layer`.
##
## `from_layer` is the layer the run ARRIVES on (it must match the copper under
## `position`, see the mismatch refusal below) and `to_layer` is the layer it
## CONTINUES on. Neither is the via's span: a v1 via is always a THROUGH via and
## its recorded span is always top<->bottom, at any stack depth. `to_layer` may
## therefore be any copper layer, inner ones included — which is the whole point
## of epoch NLC C1b — while the hole itself stays the only kind of hole this
## pipeline fabricates. The reply reports both, separately.
##
## THIS IS THE EDIT ENTRY INV-3 NAMES, and the whole point of it is the word
## PATH. A candidate for a multi-pad net can hold ≥2 DISCONNECTED copper paths
## (pcb_route_candidate.gd's own header says so, and forbids a connected-chain
## invariant). The router's flat-array hazard was exactly this: treating
## `segments` as one concatenated run, so an edit on path A re-layered path B.
## Here the affected set is derived from the SEGMENT GRAPH — endpoint adjacency
## over the exact points — and every segment outside the hit segment's connected
## component is returned in `untouched_segment_ids` untouched, which is what the
## GATE fixture asserts.
##
## DEGENERATE INSERTS ARE REFUSED, NOT CLAMPED. An insert exactly on a segment
## endpoint would split off a zero-length segment (copper with no length is not
## copper, and the worker's build_overlay refuses it too), and an insert on an
## existing via would stack two holes at one point. Both come back as named
## no-ops with the candidate untouched, rather than a silent nudge to a nearby
## legal point — a nudged via is copper the user did not ask for.
##
## Returns {"ok": true, …} or {"ok": false, "error": <named code>, "message"}.
func add_via(candidate_id: String, position: Vector2, from_layer: String, to_layer: String) -> Dictionary:
	# Reentrancy guard (see _apply_disposition): a geometry edit mid-commit
	# would mutate a member the transaction has already planned from.
	if _commit_transaction_active:
		return _verb_error(ERR_COMMIT_IN_PROGRESS,
			"a commit transaction is applying; candidate edits from its signal handlers are refused", candidate_id)
	var c = get_candidate(candidate_id)
	if c == null:
		return _verb_error(ERR_NO_CANDIDATE, "no candidate '%s' in this workspace" % candidate_id, candidate_id)
	# A terminal candidate is not an editing surface: superseded/rejected are
	# history, and committed is copper (edit the BOARD, not the ghost).
	if str(c.disposition) in PcbRouteCandidate.TERMINAL_DISPOSITIONS:
		return _verb_error(ERR_NOT_EDITABLE,
			"candidate '%s' is %s — a terminal candidate is a record, not a draft"
				% [candidate_id, str(c.disposition)], candidate_id)
	# FROZEN is live but LOCKED (Epoch UX3, K7): settled geometry acts as fixed
	# copper for routing, so letting it silently reshape would hollow out the
	# obstacle contract. Unfreeze first — refused by its own name, not
	# ERR_NOT_EDITABLE, because the remedy differs (a verb, not a re-propose).
	if str(c.disposition) == "frozen":
		return _verb_error(ERR_FROZEN,
			"candidate '%s' is frozen — settled geometry does not edit; unfreeze it first"
				% candidate_id, candidate_id)
	# `to_layer` IS THE LAYER THE RUN CONTINUES ON, NOT AN END OF THE VIA'S SPAN.
	# Those were the same thing while the stack was two layers deep and are not
	# the same thing now (epoch NLC C1b).
	#
	# Under the v1 THROUGH-VIA model there is nothing to author about the span:
	# methods.py _routes_to_vias states it outright — "a through via's RECORDED
	# span is top<->bottom at ANY stack depth — the via physically crosses the
	# whole board and joins every declared layer ... Only a blind/buried via
	# (explicitly out of scope v1) would need a real per-via span here." So the
	# via below is recorded with default_through_via_span() unconditionally, the
	# same span sync_candidate_geometry already writes for every via it creates.
	#
	# Testing the CONTINUATION layer with is_legal_via_span was the bug: that
	# predicate reads STACK_INDEX, which holds exactly {"top", "bottom"}, so it
	# refused every inner-layer continuation on every board — "I cannot propose
	# any via at all" in the N-layer HITL. It was answering "may a via SPAN
	# these two layers", which for a through via is not the question being
	# asked, and its answer for an inner layer is correctly NO.
	#
	# What remains to check is the continuation itself: copper, and different
	# from where the run already is. Membership of the board's DECLARED stack is
	# checked one level up, in the tool layer, which is what holds a board — a
	# workspace does not, and a check it cannot make is not a check it should
	# fake.
	# EMPTY REFUSED BEFORE CANONICALIZING. kicad_to_canon is the READ side and
	# maps "" to "top" with only a warning, so an unnamed continuation would
	# silently become the top layer — the exact silent-default class this epoch
	# exists to remove. The MCP tool layer already refuses empty, but this is the
	# model API and must not depend on its callers being careful.
	if str(to_layer).strip_edges().is_empty():
		return _verb_error(ERR_CONTINUATION_NOT_COPPER,
			"name the layer the run continues on — an unnamed continuation is not a default",
			candidate_id)
	# BOTH ENDS, not just the continuation (cold review 2, finding 8). from_layer
	# goes through the same read-side canonicalizer, so an empty one silently
	# became "top" and then MATCHED a top segment — succeeding exactly as if the
	# caller had named it. The guard above would have been half a guard.
	if str(from_layer).strip_edges().is_empty():
		return _verb_error(ERR_LAYER_MISMATCH,
			"name the layer the run arrives on — an unnamed from_layer is not a default",
			candidate_id)
	var canon_from := PcbLayerStack.kicad_to_canon(from_layer)
	var canon_to := PcbLayerStack.kicad_to_canon(to_layer)
	if not PcbLayerStack.is_copper(canon_to):
		return _verb_error(ERR_CONTINUATION_NOT_COPPER,
			"a run cannot continue on %s — name a copper layer (\"top\", \"bottom\", \"in1\".., or a KiCad copper name)"
				% [str(to_layer)], candidate_id)
	if canon_to == canon_from:
		return _verb_error(ERR_ILLEGAL_VIA_SPAN,
			"a via at this point would leave %s and arrive on %s — it changes nothing"
				% [canon_from, canon_to], candidate_id)

	# Refuse ON-VIA before looking for a segment: a click on an existing via is
	# a different mistake from a click on empty board, and must say so.
	#
	# TOLERANCE IS THE VIA'S OWN DISC, floored at EDIT_MIN_TOL_MM — the same
	# shape the segment hit uses (its own half-width, floored), because both
	# answer the same GESTURE question: what did the user click? A via is a
	# visible disc, and matching its mathematical centre to EDIT_EPS_MM (1e-4mm)
	# would let a click one hundredth of a millimetre off the middle of a via
	# fall through to the segment underneath and stack a second hole on it.
	# EDIT_EPS_MM stays where it answers a GEOMETRY question instead — endpoint
	# adjacency and the zero-length split — which is exact by nature.
	for via in c.vias:
		if via is Dictionary and (via as Dictionary).get("position", null) is Vector2:
			var via_dict: Dictionary = via
			var claim: float = maxf(float(via_dict.get("diameter", 0.0)) * 0.5, EDIT_MIN_TOL_MM)
			if ((via_dict["position"]) as Vector2).distance_to(position) <= claim:
				return _verb_error(ERR_DEGENERATE_ON_VIA,
					"there is already a via at %s (via '%s', claim %.3fmm)"
						% [str(position), str(via_dict.get("id", "")), claim],
					candidate_id)

	var hit: Dictionary = _segment_hit(c, position)
	if hit.is_empty():
		return _verb_error(ERR_NO_SEGMENT_AT_POINT,
			"no segment of candidate '%s' passes through %s" % [candidate_id, str(position)], candidate_id)
	var seg_index := int(hit["segment_index"])
	var hit_seg: Dictionary = c.segments[seg_index]
	# THE CALLER'S from_layer MUST BE THE LAYER THE COPPER IS ACTUALLY ON.
	# Without this the split silently RE-LAYERS the head onto whatever the caller
	# claimed, moving copper the user did not touch — a via insert would quietly
	# become a layer change of the upstream run. Refused rather than corrected to
	# the segment's real layer: a caller that named the wrong layer asked for
	# something else, and doing the right thing under a wrong request is how a
	# gesture ends up depending on the correction. Added BEFORE any gesture is
	# wired to this entry, so nothing can come to rely on the loose behaviour.
	var seg_layer := PcbLayerStack.kicad_to_canon(hit_seg.get("layer", "top"))
	if seg_layer != canon_from:
		return _verb_error(ERR_LAYER_MISMATCH,
			"segment '%s' is on %s, not the %s this via was asked to leave"
				% [str(hit_seg.get("id", "")), seg_layer, canon_from], candidate_id)
	if bool(hit_seg.get("locked", false)):
		return _verb_error(ERR_SEGMENT_LOCKED,
			"segment '%s' is locked" % str(hit_seg.get("id", "")), candidate_id)
	var at: Vector2 = hit["point"]
	for p in hit_seg.get("points", []):
		if p is Vector2 and (p as Vector2).distance_to(at) <= EDIT_EPS_MM:
			return _verb_error(ERR_DEGENERATE_AT_ENDPOINT,
				"%s is a vertex of segment '%s' — splitting there would produce a zero-length segment"
					% [str(at), str(hit_seg.get("id", ""))], candidate_id)

	# The connected path this click landed on, resolved BEFORE the split so the
	# answer is about the geometry the user clicked.
	var path_indices: Array = _connected_path_indices(c, seg_index)
	var untouched_ids: Array = []
	for i in range(c.segments.size()):
		if not (i in path_indices):
			untouched_ids.append(str((c.segments[i] as Dictionary).get("id", "")))

	# SPLIT. The head keeps the incoming layer and the segment's id (it is the
	# same copper the user was looking at); the tail is new copper on to_layer.
	var leg := int(hit["leg"])
	var pts: Array = []
	for p in hit_seg.get("points", []):
		if p is Vector2:
			pts.append(p)
	var head_pts: Array = pts.slice(0, leg + 1)
	head_pts.append(at)
	var tail_pts: Array = [at]
	tail_pts.append_array(pts.slice(leg + 1, pts.size()))
	var width := float(hit_seg.get("width", 0.25))
	var head := PcbRouteCandidate.make_segment(str(hit_seg.get("id", "")), canon_from, width, head_pts,
		bool(hit_seg.get("locked", false)))
	var tail := PcbRouteCandidate.make_segment(next_segment_id(), canon_to, width, tail_pts, false)
	c.segments[seg_index] = head
	c.segments.insert(seg_index + 1, tail)

	# LAYER-RUN TOGGLE, walked over the graph rather than the array. Seeded at
	# the TAIL and forbidden from crossing back through the HEAD, so the upstream
	# side keeps its layer; it only traverses segments still on `from_layer`, so
	# it stops at an existing via/layer change instead of flipping past one; and
	# it can never leave the connected component, so a disconnected path is
	# unreachable by construction, not by a filter someone can forget.
	var relayered: Array = [str(tail["id"])]
	for idx in _relayer_walk_indices(c, seg_index + 1, seg_index, canon_from):
		var s: Dictionary = c.segments[idx]
		s["layer"] = canon_to
		relayered.append(str(s.get("id", "")))

	# THE VIA'S OWN SPAN IS ALWAYS THE THROUGH SPAN — never canon_from->canon_to,
	# which since C1b describes the RUN, not the hole. Recording the run's
	# endpoints as the span is what made an inner-layer continuation look like a
	# blind/buried via to every downstream reader (commit's via_span_legal, the
	# emitter, DRC), and blind/buried is out of scope v1.
	var via_span: Array = PcbLayerStack.default_through_via_span()
	var via_id := next_via_id()
	c.add_via(PcbRouteCandidate.make_via(via_id, at, via_span[0], via_span[1]))
	c.candidate_revision = int(c.candidate_revision) + 1
	# INV-2, geometry half: this candidate's own copper moved, so its verdict is
	# gone. Its findings go with it (see mark_stale) — they name segment ids that
	# the split just changed the meaning of.
	mark_stale(candidate_id)
	_bump_generation()
	candidate_changed.emit(candidate_id)

	var path_ids: Array = []
	for i in path_indices:
		path_ids.append(str((c.segments[int(i)] as Dictionary).get("id", "")))
	return {
		"ok": true,
		"candidate_id": candidate_id,
		"via_id": via_id,
		"at": [at.x, at.y],
		# from_layer/to_layer describe THE RUN — where it arrived from and where
		# it continues. via_span describes THE HOLE, and is reported separately
		# and explicitly precisely because the two used to be one value: a
		# reader that assumes to_layer is where the via stops is now wrong, and
		# should see the span it actually got rather than infer it.
		"from_layer": canon_from,
		"to_layer": canon_to,
		"via_span": [str(via_span[0]), str(via_span[1])],
		"head_segment_id": str(head["id"]),
		"tail_segment_id": str(tail["id"]),
		"relayered_segment_ids": relayered,
		"untouched_segment_ids": untouched_ids,
		"candidate_revision": int(c.candidate_revision),
		"validation": str(c.validation),
	}


# ── Epoch UX1 station 10 (DCR 019fd095e694): JUNCTION IDENTITY, not a bend index ──
#
# Docket 019fd057ea0b comment 1026 (Codex, ratified by 1027/1028): "Do not use
# move_bend(candidate_id, bend_index, point) as the candidate API. Candidates
# can carry disconnected paths, and a bend is commonly the shared endpoint of
# multiple segment IDs. Use stable segment/vertex identity and atomically move
# every coincident endpoint in that junction, or introduce explicit junction
# identity. A flattened bend index would reintroduce the multi-path topology
# bug class." — the same INV-3 hazard add_via's own header names.
#
# So a "junction" here is not an index into any one segment's points array. It
# is EVERY point (segment endpoint, or via) across the WHOLE candidate that
# coincides with the caller's `point`, moved together, atomically, to `to`.

## Move every segment endpoint AND every via coincident with `point` (within
## EDIT_EPS_MM — the same tight coincidence epsilon _segments_adjacent uses,
## deliberately, so "coincident" means the same thing here as it does to the
## connected-path graph) to `to`. A via is included because it is a POINT
## OBJECT anchored exactly at the split it sits on (add_via's own `at`) — moving
## the junction and leaving its via behind would orphan a hole in copper that no
## longer touches it, the identical silent-corruption shape this station exists
## to close, just on the via side of the graph instead of the segment side.
##
## AMBIGUITY IS CANDIDATE-WIDE FOR SEGMENT ENDPOINTS, THEN VIA HITS ARE
## INTERSECTED WITH THE RESOLVED PATH (fix round, docket 019fd095e694 station
## 10 review, P3): every matching segment endpoint is first found across the
## WHOLE candidate (not seeded from one path), then grouped by connected-path
## membership via _connected_path_indices (add_via's own path-scoped
## derivation, reused verbatim rather than reimplemented). If those matches
## span MORE than one distinct connected path, this is refused BY NAME
## (ambiguous_junction) rather than silently acting on whichever path was
## found first — exactly the flattened-index failure mode 1026 warned against,
## just approached from "which point matched" instead of "which index was
## passed". In ordinary geometry two segments sharing an exact coincident
## endpoint are ALREADY one connected path (that coincidence IS
## _segments_adjacent's own definition), so this refusal's real target is
## float-noise near-misses — e.g. a router reply that went through a JSON
## round-trip and left two logically-separate junctions a few microns apart,
## each independently within tolerance of the caller's `point` but not of each
## other. Only once every segment match is confirmed to belong to ONE path
## does the move proceed. A hit VIA is NOT automatically co-moved just because
## its position is within EDIT_EPS_MM of `point` — it must ALSO be coincident
## (within EDIT_EPS_MM) with one of the resolved path's own matched endpoints,
## the same "does this actually belong to the junction we resolved" question
## the segment-ambiguity check answers, asked on the via side of the graph
## instead of the segment side (the earlier draft of this function collected
## via hits candidate-wide and moved every one of them unconditionally,
## bypassing this check — a via that merely sat within tolerance of `point`
## but belonged to a different, disconnected junction would have been dragged
## along with a path it does not touch). A via that fails that membership test
## is refused ambiguous_junction (it names a second, distinct junction the
## resolved path does not reach); a bare via hit with NO segment endpoint
## match at all (an isolated via, nothing coincident to resolve a path from)
## is refused junction_not_found — this verb identifies a junction from
## connected-path membership, and a via with no segment to anchor it to has no
## path to resolve.
##
## DEGENERATE RESULTS ARE REFUSED, NOT EMITTED (docket 019f9cc3245d — the same
## "no zero-length segment, ever" rule the router's own pathfinder enforces
## worker-side, and add_via's own on-endpoint check mirrors candidate-side).
## Simulated BEFORE any mutation: for every matched endpoint, would moving it
## to `to` make it coincide with its OWN segment's immediate neighbour point?
## If so, refused whole — nothing here is a partial apply. TWO MATCHED
## ENDPOINTS THAT ARE EACH OTHER'S NEIGHBOUR (fix round, P4a) are a special
## case of this, not an oversight: if a segment's point[i] and point[i-1] (or
## [i+1]) are BOTH in the moved set, they already sit within 2*EDIT_EPS_MM of
## each other (both matched `point` independently) — the leg between them is
## effectively the SAME junction already. Moving both to the identical `to`
## collapses that leg to EXACT zero length regardless of what `to` is, so this
## is refused unconditionally, not by comparing a neighbour's stale pre-move
## position against `to` (which is the wrong comparison once the neighbour is
## itself moving).
##
## EDIT != POLICY (docket 019fd057ea0b comment 1028): this touches ONLY this
## candidate's own geometry. It never reads or writes the candidate's task or
## its routing_constraint — a direct candidate edit must never silently become
## future router policy. A caller that wants THIS shape to survive a re-propose
## reroutes with preserve_shape_as_corridor:true (station 9), a deliberate,
## visible decision — not a side effect of moving a junction. NO AUTO-PIN
## either: moving a junction does not hold the candidate against ingest: pin is
## its own explicit verb.
##
## Returns {"ok": true, …} or {"ok": false, "error": <named code>, "message"}.
func move_junction(candidate_id: String, point: Vector2, to: Vector2, board = null) -> Dictionary:
	# Reentrancy guard (see _apply_disposition / add_via): a geometry edit mid-
	# commit would mutate a member the transaction has already planned from.
	if _commit_transaction_active:
		return _verb_error(ERR_COMMIT_IN_PROGRESS,
			"a commit transaction is applying; candidate edits from its signal handlers are refused", candidate_id)
	var c = get_candidate(candidate_id)
	if c == null:
		return _verb_error(ERR_NO_CANDIDATE, "no candidate '%s' in this workspace" % candidate_id, candidate_id)
	# A terminal candidate is not an editing surface: superseded/rejected are
	# history, and committed is copper (edit the BOARD, not the ghost) — the
	# exact rule add_via already enforces, mirrored verbatim.
	if str(c.disposition) in PcbRouteCandidate.TERMINAL_DISPOSITIONS:
		return _verb_error(ERR_NOT_EDITABLE,
			"candidate '%s' is %s — a terminal candidate is a record, not a draft"
				% [candidate_id, str(c.disposition)], candidate_id)
	# FROZEN lock — same rule and rationale as add_via's, mirrored verbatim.
	if str(c.disposition) == "frozen":
		return _verb_error(ERR_FROZEN,
			"candidate '%s' is frozen — settled geometry does not edit; unfreeze it first"
				% candidate_id, candidate_id)

	# ── 1. FIND every coincident endpoint, candidate-wide ──────────────────────
	var hit_seg_indices: Array = []      # distinct segment indices with >=1 hit
	var hit_endpoints: Array = []        # [{segment_index, point_index}], every hit
	for i in range(c.segments.size()):
		var seg = c.segments[i]
		if not (seg is Dictionary):
			continue
		var pts: Array = (seg as Dictionary).get("points", [])
		for pi in range(pts.size()):
			if pts[pi] is Vector2 and (pts[pi] as Vector2).distance_to(point) <= EDIT_EPS_MM:
				hit_endpoints.append({"segment_index": i, "point_index": pi})
				if not (i in hit_seg_indices):
					hit_seg_indices.append(i)

	var hit_via_indices: Array = []
	for vi in range(c.vias.size()):
		var via = c.vias[vi]
		if via is Dictionary and (via as Dictionary).get("position", null) is Vector2:
			if (((via as Dictionary)["position"]) as Vector2).distance_to(point) <= EDIT_EPS_MM:
				hit_via_indices.append(vi)

	if hit_seg_indices.is_empty() and hit_via_indices.is_empty():
		return _verb_error(ERR_JUNCTION_NOT_FOUND,
			"no segment endpoint or via of candidate '%s' is within %.4fmm of %s"
				% [candidate_id, EDIT_EPS_MM, str(point)], candidate_id)

	# A standalone via candidate is itself a movable point. It has no connected
	# path by design, so requiring segment membership here made the Universal
	# Select gesture arm and then refuse every via-only proposal. Resolve its
	# destination through the same context-aware board rule proposal creation
	# uses: empty space remains standalone; trace contact snaps and inherits net.
	if hit_seg_indices.is_empty() and _is_standalone_via_candidate(c):
		if hit_via_indices.size() != 1:
			return _verb_error(ERR_AMBIGUOUS_JUNCTION,
				"more than one via of candidate '%s' matches %s" % [candidate_id, str(point)],
				candidate_id)
		if board == null or not is_instance_valid(board) or not board.has_method("resolve_via_target"):
			return _verb_error(ERR_NO_BOARD,
				"moving a standalone via proposal needs the live board's placement rule",
				candidate_id)
		var vi := int(hit_via_indices[0])
		var standalone: Dictionary = c.vias[vi]
		var dims := _via_dimensions(standalone, board)
		var authored_net := str(standalone.get("authored_net", str(c.net)))
		var target: Dictionary = board.resolve_via_target(
			to, float(dims["diameter"]), float(dims["drill"]), authored_net)
		if not bool(target.get("ok", false)):
			return _verb_error(ERR_VIA_NOT_PLACEABLE,
				str(target.get("error", "the via cannot be moved there")), candidate_id)
		var target_position: Vector2 = target.get("position", to)
		var sibling_error := _candidate_via_error(target_position, candidate_id)
		if not sibling_error.is_empty():
			return _verb_error(ERR_VIA_NOT_PLACEABLE, sibling_error, candidate_id)
		standalone["position"] = target_position
		standalone["junction_trace_id"] = str(target.get("trace_id", ""))
		standalone["authored_net"] = authored_net
		c.net = str(target.get("net_name", authored_net))
		c.candidate_revision = int(c.candidate_revision) + 1
		mark_stale(candidate_id)
		_bump_generation()
		candidate_changed.emit(candidate_id)
		return {
			"ok": true, "candidate_id": candidate_id,
			"from": [point.x, point.y],
			"to": [target_position.x, target_position.y],
			"moved_segment_ids": [],
			"moved_via_ids": [str(standalone.get("id", ""))],
			"path_segment_ids": [], "net_name": str(c.net),
			"trace_id": str(target.get("trace_id", "")),
			"snapped_to_trace": bool(target.get("snapped", false)),
			"candidate_revision": int(c.candidate_revision),
			"validation": str(c.validation),
		}

	# ── 2. AMBIGUITY: every hit segment must resolve to the SAME connected path ─
	var resolved_path: Array = []
	for i in hit_seg_indices:
		var path: Array = _connected_path_indices(c, i)
		if resolved_path.is_empty():
			resolved_path = path
		elif path != resolved_path:
			return _verb_error(ERR_AMBIGUOUS_JUNCTION,
				"%s matches junctions on more than one disconnected path of candidate '%s' — move each path's junction separately, or supply a point that identifies only one"
					% [str(point), candidate_id], candidate_id)

	# ── 2b. VIA MEMBERSHIP (P3): a hit via co-moves ONLY when it is coincident
	# with an endpoint of the RESOLVED path — proximity to `point` alone is not
	# enough, or a via belonging to an entirely different junction that merely
	# happens to sit within EDIT_EPS_MM of the same query point would be dragged
	# along with copper it does not touch.
	if hit_seg_indices.is_empty():
		# A via-only hit: nothing coincident to resolve a connected path from,
		# so there is no junction here for this verb to identify.
		if not hit_via_indices.is_empty():
			return _verb_error(ERR_JUNCTION_NOT_FOUND,
				"%s is within %.4fmm of a via on candidate '%s' but no segment endpoint — move_junction identifies a junction from connected-path membership, and an isolated via has no path to resolve"
					% [str(point), EDIT_EPS_MM, candidate_id], candidate_id)
	else:
		for vi in hit_via_indices:
			var via: Dictionary = c.vias[vi]
			var via_pos: Vector2 = via.get("position", Vector2())
			var belongs := false
			for spec in hit_endpoints:
				if not (int(spec["segment_index"]) in resolved_path):
					continue
				var seg: Dictionary = c.segments[int(spec["segment_index"])]
				var pts: Array = seg.get("points", [])
				var endpoint: Vector2 = pts[int(spec["point_index"])]
				if endpoint.distance_to(via_pos) <= EDIT_EPS_MM:
					belongs = true
					break
			if not belongs:
				return _verb_error(ERR_AMBIGUOUS_JUNCTION,
					"via '%s' is within %.4fmm of %s but not coincident with the resolved path's own junction on candidate '%s' — it belongs to a separate junction; move each separately, or supply a point that identifies only one"
						% [str(via.get("id", "")), EDIT_EPS_MM, str(point), candidate_id], candidate_id)

	# ── 3. DEGENERACY: simulate BEFORE mutating — never a partial apply ────────
	# Index the moved set by (segment_index, point_index) so a neighbour check
	# can tell whether ITS neighbour is ALSO moving, not just where the
	# neighbour currently, pre-move, sits.
	var moved_point_keys: Dictionary = {}
	for spec in hit_endpoints:
		moved_point_keys["%d:%d" % [int(spec["segment_index"]), int(spec["point_index"])]] = true

	for spec in hit_endpoints:
		var seg: Dictionary = c.segments[int(spec["segment_index"])]
		var pts: Array = seg.get("points", [])
		var si := int(spec["segment_index"])
		var pi := int(spec["point_index"])
		if pi > 0:
			if moved_point_keys.has("%d:%d" % [si, pi - 1]):
				# The previous point is itself in the moved set: both matched
				# `point` independently, so pre-move they already sit within
				# 2*EDIT_EPS_MM of each other — the same junction. Moving both
				# to the identical `to` collapses this leg to EXACT zero length
				# unconditionally; `to`'s value cannot rescue it.
				return _verb_error(ERR_DEGENERATE_RESULT,
					"segment '%s' has both ends of a leg coincident with %s — moving them together would collapse it to zero length"
						% [str(seg.get("id", "")), str(point)], candidate_id)
			elif (pts[pi - 1] as Vector2).distance_to(to) <= EDIT_EPS_MM:
				return _verb_error(ERR_DEGENERATE_RESULT,
					"moving %s to %s would collapse segment '%s' to zero length"
						% [str(point), str(to), str(seg.get("id", ""))], candidate_id)
		if pi < pts.size() - 1:
			if moved_point_keys.has("%d:%d" % [si, pi + 1]):
				return _verb_error(ERR_DEGENERATE_RESULT,
					"segment '%s' has both ends of a leg coincident with %s — moving them together would collapse it to zero length"
						% [str(seg.get("id", "")), str(point)], candidate_id)
			elif (pts[pi + 1] as Vector2).distance_to(to) <= EDIT_EPS_MM:
				return _verb_error(ERR_DEGENERATE_RESULT,
					"moving %s to %s would collapse segment '%s' to zero length"
						% [str(point), str(to), str(seg.get("id", ""))], candidate_id)

	# ── 4. APPLY, atomically: every matched endpoint AND matched via moves ─────
	var moved_segment_ids: Array = []
	for spec in hit_endpoints:
		var seg: Dictionary = c.segments[int(spec["segment_index"])]
		var pts: Array = seg.get("points", [])
		pts[int(spec["point_index"])] = to
		seg["points"] = pts
		var sid := str(seg.get("id", ""))
		if not (sid in moved_segment_ids):
			moved_segment_ids.append(sid)

	var moved_via_ids: Array = []
	for vi in hit_via_indices:
		var via: Dictionary = c.vias[vi]
		via["position"] = to
		moved_via_ids.append(str(via.get("id", "")))

	c.candidate_revision = int(c.candidate_revision) + 1
	# INV-2, geometry half: this candidate's own copper moved, so its verdict is
	# gone (mirrors add_via's own reasoning — see mark_stale).
	mark_stale(candidate_id)
	_bump_generation()
	candidate_changed.emit(candidate_id)

	var path_ids: Array = []
	for i in resolved_path:
		path_ids.append(str((c.segments[int(i)] as Dictionary).get("id", "")))

	return {
		"ok": true,
		"candidate_id": candidate_id,
		"from": [point.x, point.y],
		"to": [to.x, to.y],
		"moved_segment_ids": moved_segment_ids,
		"moved_via_ids": moved_via_ids,
		"path_segment_ids": path_ids,
		"candidate_revision": int(c.candidate_revision),
		"validation": str(c.validation),
	}


## T7: insert a vertex into a candidate segment. STILL A STUB — C4a implements
## the VIA/layer edit entry (add_via above) because that is the one INV-3 names;
## the vertex drag and the routing gate are their own gestures and land with T7.
## Left as a warning-and-false placeholder rather than deleted: the signature is
## the contract the canvas edit tools will call.
func add_vertex(_candidate_id: String, _segment_id: String, _index: int, _position: Vector2) -> bool:
	push_warning("[RoutingWorkspace] add_vertex is a stub (T7)")
	return false


## T7: add a routing gate/keepout constraint. STUB (see add_vertex).
func add_gate(_candidate_id: String, _gate: Dictionary) -> bool:
	push_warning("[RoutingWorkspace] add_gate is a stub (T7)")
	return false


## T7: reroute one span of a candidate IN THE MODEL. STILL A STUB, and it must
## stay one until the ROUTER can answer a span question: agent_router scopes by
## WHOLE NET (route_bridge.parse_route_scope refuses a span outright rather than
## widening it), so there is no way to obtain replacement geometry for an
## interval. The MCP verb minerva_pcb_workspace_reroute_span therefore DEGRADES
## to a whole-route reroute and says so in its reply — see panel_tools.gd and
## docket 019fc155bc32. Implementing this half against a router that cannot
## honour it would be the silent widening the campaign exists to kill.
func reroute_span(_candidate_id: String, _segment_id: String) -> bool:
	push_warning("[RoutingWorkspace] reroute_span is a stub (T7 — the router has no span scope; see 019fc155bc32)")
	return false


## Segment ids of the connected path containing `segment_id` — the public read
## of the graph add_via scopes its edit to. Empty when the segment is unknown.
func connected_path_segment_ids(candidate_id: String, segment_id: String) -> Array:
	var c = get_candidate(candidate_id)
	if c == null:
		return []
	var seed_index := -1
	for i in range(c.segments.size()):
		if str((c.segments[i] as Dictionary).get("id", "")) == segment_id:
			seed_index = i
			break
	if seed_index < 0:
		return []
	var out: Array = []
	for i in _connected_path_indices(c, seed_index):
		out.append(str((c.segments[int(i)] as Dictionary).get("id", "")))
	return out


## Which segment (and which leg of it) `position` lands on, and where exactly.
## {} when nothing does. Tolerance is HALF THE SEGMENT'S OWN WIDTH — its copper
## — with a floor, the same rule the canvas pick uses; the closest hit wins so
## an overlap resolves deterministically.
func _segment_hit(c, position: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for i in range(c.segments.size()):
		if not (c.segments[i] is Dictionary):
			continue
		var seg: Dictionary = c.segments[i]
		var pts: Array = []
		for p in seg.get("points", []):
			if p is Vector2:
				pts.append(p)
		if pts.size() < 2:
			continue
		var tol: float = maxf(float(seg.get("width", 0.25)) * 0.5, EDIT_MIN_TOL_MM)
		for leg in range(pts.size() - 1):
			var proj := _project_on_segment(position, pts[leg], pts[leg + 1])
			var d: float = position.distance_to(proj)
			if d <= tol and d < best_d:
				best_d = d
				best = {"segment_index": i, "leg": leg, "point": proj}
	return best


## Closest point on the SEGMENT ab (not the infinite line) to p.
static func _project_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq <= 0.0:
		return a
	return a + ab * clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)


## Do these two segments share an endpoint (within EDIT_EPS_MM)? THE adjacency
## relation of the segment graph. Layer-agnostic on purpose: a via joins copper
## on two layers AT ONE POINT, so their endpoints coincide and the two sides are
## correctly one path.
static func _segments_adjacent(a: Dictionary, b: Dictionary) -> bool:
	for pa in a.get("points", []):
		if not (pa is Vector2):
			continue
		for pb in b.get("points", []):
			if pb is Vector2 and (pa as Vector2).distance_to(pb as Vector2) <= EDIT_EPS_MM:
				return true
	return false


## Indices of the connected component containing `seed_index` (endpoint adjacency).
func _connected_path_indices(c, seed_index: int) -> Array:
	var seen: Dictionary = {seed_index: true}
	var queue: Array = [seed_index]
	while not queue.is_empty():
		var cur: int = int(queue.pop_back())
		for i in range(c.segments.size()):
			if seen.has(i) or not (c.segments[i] is Dictionary):
				continue
			if _segments_adjacent(c.segments[cur], c.segments[i]):
				seen[i] = true
				queue.append(i)
	var out: Array = seen.keys()
	out.sort()
	return out


## Indices to re-layer: everything reachable from `start` WITHOUT passing
## through `blocked`, travelling only over segments still on `layer`. Excludes
## `start` itself (the caller already owns the tail).
func _relayer_walk_indices(c, start: int, blocked: int, layer: String) -> Array:
	var seen: Dictionary = {start: true, blocked: true}
	var queue: Array = [start]
	var out: Array = []
	while not queue.is_empty():
		var cur: int = int(queue.pop_back())
		for i in range(c.segments.size()):
			if seen.has(i) or not (c.segments[i] is Dictionary):
				continue
			var other: Dictionary = c.segments[i]
			if PcbLayerStack.kicad_to_canon(other.get("layer", "top")) != layer:
				continue  # a layer change already happened here — stop, do not flip past it
			if not _segments_adjacent(c.segments[cur], other):
				continue
			seen[i] = true
			out.append(i)
			queue.append(i)
	return out


# ── PCBData history BUCKET 8: the workspace disposition layer ─────────────────
#
# PCBData snapshots SEVEN board buckets (components, nets, traces, vias,
# mounting_holes, zones, cutouts). INV-1 needs an EIGHTH, because "undo the
# commit" has to mean "the copper goes AND the candidate is live again" — the
# two halves of one act.
#
# It is an OVERLAY, not a wholesale store, and that distinction is the whole
# design. A wholesale workspace snapshot would make undoing an UNRELATED board
# edit delete every candidate proposed since — the inverted twin of the trap the
# zones bucket's own comment records. So the snapshot carries only the
# DISPOSITION LAYER (disposition + the correlation's commit bookkeeping) keyed by
# candidate_id, and the restore touches only candidates named in it: a candidate
# that arrived after the snapshot is LEFT ALONE, because it is not board state
# and no board undo has anything to say about it.
#
# The board reaches these through a DUCK-TYPED delegate (PCBData.
# bind_routing_workspace) — pcb_data.gd preloads nothing from this file and
# knows only two method names, so the pure board model stays free of the routing
# model.

## The disposition layer of every candidate, for a history snapshot.
func snapshot_dispositions() -> Dictionary:
	var out: Dictionary = {}
	for id in candidates:
		var rec: Dictionary = correlations.get(id, {})
		out[str(id)] = {
			"disposition": str(candidates[id].disposition),
			"prior_disposition": str(rec.get("prior_disposition", "")),
			"committed_trace_ids": _to_string_array(rec.get("committed_trace_ids", []) if rec.get("committed_trace_ids", []) is Array else []),
			"committed_via_ids": _to_string_array(rec.get("committed_via_ids", []) if rec.get("committed_via_ids", []) is Array else []),
			"consumed_hint_ids": _to_string_array(rec.get("consumed_hint_ids", []) if rec.get("consumed_hint_ids", []) is Array else []),
		}
	return out


## Apply a snapshot taken by snapshot_dispositions(). Returns the ids that
## actually MOVED (an unchanged candidate is not reported and emits nothing).
##
## RESTORE IS NOT A WORKFLOW TRANSITION, so it writes through the RAW setter
## rather than the legality table — for the same reason load_from_dict does:
## reinstating a stored "committed"/"rejected" is not a move a user made, and
## running it through the table would refuse exactly the terminal states an undo
## most needs to reinstate. uncommit_to()'s contract is untouched by this; it
## remains the only WORKFLOW exit from committed.
##
## A restored candidate whose disposition moved is marked STALE: a board undo
## changed the copper underneath it, so any verdict it carried was scored
## against a board that no longer exists.
func restore_dispositions(snap: Dictionary) -> Array:
	var moved: Array = []
	for raw_id in snap:
		var cid := str(raw_id)
		var c = get_candidate(cid)
		if c == null:
			continue  # a candidate the snapshot knew and this workspace no longer has
		var entry: Dictionary = snap[raw_id] if snap[raw_id] is Dictionary else {}
		var want := str(entry.get("disposition", ""))
		if want.is_empty() or not (want in PcbRouteCandidate.DISPOSITIONS):
			continue
		var rec: Dictionary = correlations.get(cid, {})
		rec["prior_disposition"] = str(entry.get("prior_disposition", ""))
		rec["committed_trace_ids"] = _to_string_array(entry.get("committed_trace_ids", []) if entry.get("committed_trace_ids", []) is Array else [])
		rec["committed_via_ids"] = _to_string_array(entry.get("committed_via_ids", []) if entry.get("committed_via_ids", []) is Array else [])
		rec["consumed_hint_ids"] = _to_string_array(entry.get("consumed_hint_ids", []) if entry.get("consumed_hint_ids", []) is Array else [])
		correlations[cid] = rec
		if str(c.disposition) == want:
			continue
		c.set_disposition(want)  # RAW restore setter — see the doc above
		_sync_held_indexes(cid, want)
		mark_stale(cid)
		moved.append(cid)
		candidate_changed.emit(cid)
	if not moved.is_empty():
		_rebuild_task_index()
		refresh_task_states()
		_bump_generation()
	return moved


# ── serialisation ─────────────────────────────────────────────────────────────

func to_dict() -> Dictionary:
	var cand_out: Dictionary = {}
	for id in candidates:
		cand_out[id] = candidates[id].to_dict()
	var pinned_out: Array = []
	for id in pinned:
		pinned_out.append(id)
	var frozen_out: Array = []
	for id in frozen:
		frozen_out.append(id)
	return {
		"candidates": cand_out,
		"tasks": _tasks_out(),
		"active_candidate_id": active_candidate_id,
		"pinned": pinned_out,
		"frozen": frozen_out,
		"selected_finding_id": selected_finding_id,
		"correlations": _correlations_out(),
		"counters": {
			"candidate": _cand_counter,
			"segment": _seg_counter,
			"via": _via_counter,
		},
	}


## DURABLE serialisation for the on-disk routing sidecar (T2a). Identical to
## to_dict() MINUS the transient UI selection (active_candidate_id,
## selected_finding_id) — those are session state, not design intent, so they
## are NOT persisted (a fresh load starts with no active/selected). The pinned
## SET and the id counters ARE persisted: pinning is durable user intent, and
## the counters keep post-load ids from colliding with loaded ones. Round-trips
## back through load_from_dict (which defaults active/selected to "" when the
## keys are absent).
func to_sidecar_dict() -> Dictionary:
	var cand_out: Dictionary = {}
	for id in candidates:
		cand_out[id] = candidates[id].to_dict()
	var pinned_out: Array = []
	for id in pinned:
		pinned_out.append(id)
	# Freezing is durable user intent exactly as pinning is — a settlement that
	# evaporated on reload would betray K7's contract.
	var frozen_out: Array = []
	for id in frozen:
		frozen_out.append(id)
	return {
		"candidates": cand_out,
		# Tasks ARE durable: "which nets/spans still need copper" is design
		# intent, not session state (unlike active/selected, dropped below).
		"tasks": _tasks_out(),
		"pinned": pinned_out,
		"frozen": frozen_out,
		"correlations": _correlations_out(),
		"counters": {
			"candidate": _cand_counter,
			"segment": _seg_counter,
			"via": _via_counter,
		},
	}


## task_id -> task.to_dict() (JSON-safe; span Vector2s are {x,y}-ified there).
func _tasks_out() -> Dictionary:
	var out: Dictionary = {}
	for tid in tasks:
		out[str(tid)] = tasks[tid].to_dict()
	return out


## Deep-copy the correlation map for serialisation (JSON-safe: all values are
## String/int/Array-of-String already).
func _correlations_out() -> Dictionary:
	var out: Dictionary = {}
	for cid in correlations:
		out[cid] = (correlations[cid] as Dictionary).duplicate(true)
	return out


## Force EVERY candidate's validation axis to "stale" (disposition preserved).
## The coherence-quarantine signal: a loaded workspace whose board changed
## underneath it (fingerprint mismatch / unknown schema / missing token) is
## surfaced but never silently trusted — every candidate must be re-validated
## against the current board before it can be committed.
func mark_all_stale() -> void:
	for id in candidates:
		candidates[id].set_validation("stale")
		validation_changed.emit(str(id))


## ── PER-CANDIDATE staleness on a board-revision mismatch (C1) ─────────────────
## Candidate ids whose base_board_revision != `rev` — the candidates the board
## has moved out from under. Pure query, mutates nothing.
func stale_candidate_ids_for_revision(rev: int) -> Array:
	var out: Array = []
	for id in candidates:
		if candidates[id].is_stale_for_board_revision(rev):
			out.append(str(id))
	return out


## REBASE the workspace onto board revision `rev`: bind it, then mark every
## candidate generated against a DIFFERENT revision validation="stale".
##
## Three deliberate choices:
##   1. STALE, NOT ERROR. A rebased candidate is not wrong, it is UNVERIFIED
##      against this board — "error" would claim a verdict nobody computed.
##      "stale" is the existing quarantine signal (mark_all_stale, sidecar
##      fingerprint mismatch) and the same one the DRC path already understands.
##   2. DISPOSITION PRESERVED. Staleness is the VALIDATION axis; a pinned or
##      committed candidate keeps its disposition through a rebase (the two axes
##      are orthogonal — see RouteCandidate's header).
##   3. PER CANDIDATE, not blunt-force-all. Candidates already at `rev` are left
##      exactly as they are, so re-binding to the revision you are already on is
##      a no-op instead of quarantining freshly-checked work. (mark_all_stale
##      stays for the coarser sidecar-level "the whole board changed" case.)
## Returns the ids newly marked stale (already-stale ones are skipped, so this is
## idempotent and emits no duplicate validation_changed).
func rebase(rev: int) -> Array:
	board_revision = int(rev)
	var marked: Array = []
	for id in candidates:
		var c = candidates[id]
		if not c.is_stale_for_board_revision(board_revision):
			continue
		if str(c.validation) == "stale":
			continue
		set_validation(str(id), "stale")  # emits validation_changed
		marked.append(str(id))
	return marked


## `board_revision_hint` (C1): the CURRENT board revision the loaded workspace is
## being restored against. Default -1 means "unknown — do not rebase" (0 is a
## legitimate revision for a fresh board, so it cannot be the sentinel). When a
## caller passes a real revision, the load is followed by rebase(): candidates
## whose base_board_revision differs are marked validation="stale" with their
## dispositions preserved. The routing sidecar already threads a
## current_board_revision through load_into_workspace — wiring that argument
## through to here is the natural call site, and is left to the owner of that
## file (out of this unit's fence).
func load_from_dict(data: Dictionary, board_revision_hint: int = -1) -> void:
	# A load is a replacement of the workspace's identity, not a mutation within
	# the old one. Drop every check-local transient and advance the process-local
	# epoch BEFORE installing ids that may be identical to the prior document's.
	# Otherwise a late reply can match those reused ids/generation, or an old
	# geometric refusal can downgrade candidates belonging to the new document.
	_pending_check = {}
	_geometric_indeterminate = {}
	_bump_generation()
	candidates.clear()
	pinned.clear()
	frozen.clear()
	tasks.clear()
	_findings.clear()
	correlations.clear()
	_annotation_to_candidate.clear()

	var cand_data: Dictionary = data.get("candidates", {})
	for id in cand_data:
		candidates[id] = PcbRouteCandidate.from_dict(cand_data[id])

	# Tasks. Absent for any sidecar written before tasks existed — the backfill
	# below reconstructs them from the candidates, so an old file loads with a
	# complete, correctly-stated registry rather than an empty one. That is why
	# adding "tasks" needs no sidecar schema bump: old readers ignore the key,
	# new readers can do without it.
	var task_data: Dictionary = data.get("tasks", {}) if data.get("tasks", {}) is Dictionary else {}
	for tid in task_data:
		if task_data[tid] is Dictionary:
			var t = PcbRouteTask.from_dict(task_data[tid])
			t.task_id = str(tid)
			tasks[str(tid)] = t

	# Restore correlations + rebuild the derived reverse (annotation→candidate)
	# index. int()/str() normalise JSON round-trip types (generation is a float).
	var corr_data: Dictionary = data.get("correlations", {}) if data.get("correlations", {}) is Dictionary else {}
	for cid in corr_data:
		var rec: Dictionary = corr_data[cid] if corr_data[cid] is Dictionary else {}
		var ann := str(rec.get("annotation_id", ""))
		correlations[str(cid)] = {
			"annotation_id": ann,
			"task_id": str(rec.get("task_id", "")),
			"generation": int(rec.get("generation", 0)),
			"committed_trace_ids": _to_string_array(rec.get("committed_trace_ids", []) if rec.get("committed_trace_ids", []) is Array else []),
			"committed_via_ids": _to_string_array(rec.get("committed_via_ids", []) if rec.get("committed_via_ids", []) is Array else []),
			"prior_disposition": str(rec.get("prior_disposition", "")),
			# Absent in any sidecar written before C4a — an empty list is the
			# correct reading of "this file predates consumed-hint recording",
			# and it round-trips forward from here.
			"consumed_hint_ids": _to_string_array(rec.get("consumed_hint_ids", []) if rec.get("consumed_hint_ids", []) is Array else []),
		}
		if not ann.is_empty():
			_annotation_to_candidate[ann] = str(cid)

	active_candidate_id = str(data.get("active_candidate_id", ""))
	selected_finding_id = str(data.get("selected_finding_id", ""))

	for id in data.get("pinned", []):
		pinned[str(id)] = true
	for id in data.get("frozen", []):
		frozen[str(id)] = true
	# `pinned`/`frozen` are DERIVED from the disposition axis (see
	# _sync_held_indexes), so reconcile them after a load: a stored entry whose
	# candidate is gone or no longer holds that disposition is dropped, and a
	# held candidate missing from the stored set is added. A hand-edited or
	# partially-written sidecar can therefore never leave a phantom keep-out
	# behind — and a pre-freeze sidecar (no "frozen" key) reconstructs the set
	# from the dispositions alone, which is why the key needs no schema bump.
	for id in pinned.keys():
		var pc = candidates.get(id, null)
		if pc == null or str(pc.disposition) != "pinned":
			pinned.erase(id)
	for id in candidates:
		if str(candidates[id].disposition) == "pinned":
			pinned[str(id)] = true
	for id in frozen.keys():
		var fc = candidates.get(id, null)
		if fc == null or str(fc.disposition) != "frozen":
			frozen.erase(id)
	for id in candidates:
		if str(candidates[id].disposition) == "frozen":
			frozen[str(id)] = true

	# Restore counters to a HIGH-WATER MARK: max of the stored counter and the
	# largest numeric suffix present in loaded ids (int() tolerates JSON floats).
	var counters: Dictionary = data.get("counters", {})
	_cand_counter = int(counters.get("candidate", 0))
	_seg_counter = int(counters.get("segment", 0))
	_via_counter = int(counters.get("via", 0))
	for id in candidates:
		_cand_counter = maxi(_cand_counter, _suffix_num(str(id)))
		var c = candidates[id]
		for seg in c.segments:
			if seg is Dictionary:
				_seg_counter = maxi(_seg_counter, _suffix_num(str(seg.get("id", ""))))
		for via in c.vias:
			if via is Dictionary:
				_via_counter = maxi(_via_counter, _suffix_num(str(via.get("id", ""))))

	# Rebuild the in-memory idempotent-replace index from the loaded candidates
	# so a re-propose AFTER a load still supersedes (rather than duplicating) the
	# prior candidate for a task. _task_candidate is not itself persisted (T2's
	# contract), but it IS deterministically reconstructable from the loaded set.
	_rebuild_task_index()

	# Backfill any task a candidate references but the file did not carry, then
	# re-derive EVERY task's open/closed state from the loaded candidate set —
	# the state is derived, so it is never trusted from disk over the answers.
	for id in candidates:
		var c = candidates[id]
		var tid := str(c.task_id)
		if not tid.is_empty():
			ensure_task(tid, str(c.net))
	refresh_task_states()

	if board_revision_hint >= 0:
		rebase(board_revision_hint)


## Rebuild _task_candidate: task_key -> the CURRENT (non-superseded, highest-
## generation) candidate answering it. Deterministic over the loaded candidates.
func _rebuild_task_index() -> void:
	_task_candidate.clear()
	for id in candidates:
		var c = candidates[id]
		if c.disposition == "superseded":
			continue
		var tk := str(c.task_id)
		if tk.is_empty():
			continue
		var cur := str(_task_candidate.get(tk, ""))
		if cur.is_empty() or int(c.generation) >= int(candidates[cur].generation):
			_task_candidate[tk] = str(id)


static func from_dict(data: Dictionary, board_revision_hint: int = -1):
	var ws = _Self.new()
	ws.load_from_dict(data, board_revision_hint)
	return ws


## Trailing integer of an id like "cand_12" -> 12; 0 if none.
static func _suffix_num(id: String) -> int:
	var idx := id.rfind("_")
	if idx < 0 or idx + 1 >= id.length():
		return 0
	var tail := id.substr(idx + 1)
	if tail.is_valid_int():
		return int(tail)
	return 0
