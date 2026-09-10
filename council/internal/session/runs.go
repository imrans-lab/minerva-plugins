package session

import (
	"fmt"
	"time"

	"github.com/ipeerbhai/plugins/council/internal/contract"
)

// The run commands: starting a bounded round, waiting for one, cancelling one,
// retrying the seats that did not answer, and keeping what came out of it.
//
// They live apart from the rest of the command set because they are the only
// ones that spend money. Every refusal here is a refusal to spend: a seat that
// was not named, a bench larger than the council allows, a session that has had
// its rounds, a limit a caller tried to raise.

// runKinds is the Run.kind enum a caller may ask for. run.start takes
// initial_round or follow_up; retry is minted by run.retry so a retry cannot be
// forged as a fresh round.
var runKinds = map[string]bool{"initial_round": true, "follow_up": true}

func cmdRunStart(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	kind := str(req.Payload["kind"])
	if kind == "" {
		kind = "initial_round"
	}
	if !runKinds[kind] {
		return nil, fail(CodeInternal, fmt.Sprintf("run kind %q must be initial_round or follow_up; a retry is started with run.retry", kind), false)
	}

	def := obj(session["definition_snapshot"])
	rules, f := readLimits(def, req.Payload)
	if f != nil {
		return nil, f
	}
	if f := checkRoundBudget(session, rules.RoundsPerSession); f != nil {
		return nil, f
	}

	prompt := str(req.Payload["prompt"])
	addressed := str(req.Payload["addressed_seat_id"])
	claimID := str(req.Payload["addressed_claim_id"])
	if claimID != "" {
		seat, f := seatThatMadeClaim(session, claimID)
		if f != nil {
			return nil, f
		}
		// A follow-up about an argument goes to whoever made it. Letting the
		// caller name a different seat would ask one member to answer for
		// another's reasoning.
		if addressed != "" && addressed != seat {
			return nil, fail(CodeInternal, fmt.Sprintf(
				"claim %q was made by seat %q, not %q; a follow-up about an argument is answered by the member that made it", claimID, seat, addressed), false)
		}
		addressed = seat
		kind = "follow_up"
		// The bench for a claim follow-up is that one seat. A seat_ids naming
		// anybody else would send the question to a member while telling them
		// the argument was their own.
		for _, x := range arr(req.Payload["seat_ids"]) {
			if str(x) != seat {
				return nil, fail(CodeInternal, fmt.Sprintf(
					"claim %q was made by seat %q, so this follow-up consults that seat alone; seat_ids named %q as well",
					claimID, seat, str(x)), false)
			}
		}
	}
	if kind == "follow_up" && addressed == "" && prompt == "" {
		return nil, fail(CodeInternal, "a follow-up must name either a seat or a prompt", false)
	}

	seats, f := selectSeats(session, req, addressed, rules.MembersPerRound)
	if f != nil {
		return nil, f
	}
	// Before the run exists, and so before anything can be spent or cancelled:
	// every model this round would ask for has to be one the host has enabled.
	if f := s.checkRunModels(session, obj(req.Payload["model_overrides"]), seats); f != nil {
		return nil, f
	}
	run, contributionIDs := s.newRun(session, req.RequestID, kind, prompt, addressed, seats)
	if claimID != "" {
		run["addressed_claim_id"] = claimID
	}
	if overrides := obj(req.Payload["model_overrides"]); len(overrides) > 0 {
		run["model_overrides"] = overrides
	}
	// The narrowing is stored on the run, not carried in the command: the round
	// is planned from the record, and a limit that lived only in the request
	// would be gone by the time it mattered.
	if narrowed := obj(req.Payload["limits"]); len(narrowed) > 0 {
		run["limits"] = narrowed
	}
	session["runs"] = append(arr(session["runs"]), run)
	session["status"] = contract.DeriveSessionStatus(session)
	bumpSession(session)

	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"run_id":           str(run["run_id"]),
		"kind":             kind,
		"status":           "pending",
		"seat_ids":         seatIDs(seats),
		"contribution_ids": contributionIDs,
	}, nil
}

// afterRunStart starts the round and waits a BOUNDED time for it, then answers
// with the run as it stands. Both run.start and run.retry use it: a retry is a
// run the user explicitly asked for, and leaving it pending would put the
// session in a state nothing was going to finish.
//
// The wait is bounded because the host is: it gives a tool call 120 seconds by
// default, and a reply held past that is a reply nobody receives. A round that
// outruns the wait keeps going on its own goroutine, and the caller reads it
// with run.await and stops it with run.cancel — both of which the backend can
// now answer, because a tools/call no longer blocks the protocol loop.
//
// The stored reply for this request_id is the state at the moment the command
// was answered, so a caller that lost the reply and repeats the command learns
// the run's id without starting a second round.
func afterRunStart(s *Store, req *Request, payload map[string]any) Reply {
	sessionID := str(payload["session_id"])
	runID := str(payload["run_id"])
	s.startRun(sessionID, runID, req.generation)
	s.awaitRun(sessionID, runID, req.waitFor(), req.generation)
	return s.readOutcome(req, sessionID, runID, true)
}

// seatThatMadeClaim resolves a claim id to the seat that argued it.
func seatThatMadeClaim(session map[string]any, claimID string) (string, *Failure) {
	for _, r := range arr(session["runs"]) {
		run := obj(r)
		for _, c := range append(append([]any{}, arr(run["contributions"])...), synthesisOf(run)...) {
			contribution := obj(c)
			for _, x := range arr(contribution["claims"]) {
				if str(obj(x)["claim_id"]) == claimID {
					return str(contribution["seat_id"]), nil
				}
			}
		}
	}
	return "", fail(CodeInternal, fmt.Sprintf("no claim %q was made in session %q", claimID, str(session["session_id"])), false)
}

// selectSeats decides who is consulted. The choice is explicit or it is the
// whole advisory bench; when the bench is larger than the round allows, the
// command is refused rather than silently narrowed — a user must see which
// members were left out before the round runs.
func selectSeats(session map[string]any, req *Request, addressed string, maxMembers int) ([]map[string]any, *Failure) {
	def := obj(session["definition_snapshot"])
	kindOf := map[string]string{}
	for _, x := range arr(def["members"]) {
		member := obj(x)
		kindOf[str(member["member_id"])] = str(member["kind"])
	}
	byID := map[string]map[string]any{}
	advisors := []map[string]any{}
	for _, x := range arr(def["seats"]) {
		seat := obj(x)
		byID[str(seat["seat_id"])] = seat
		if str(seat["role"]) == "chair" && kindOf[str(seat["member_id"])] == "human" {
			return nil, fail(CodeInternal, "This council has a human chair. Choose a model-backed chair before starting an automated round; Council cannot synthesize on the user's behalf.", false)
		}
		// A human member is the local user. Nothing prompts them, so they are
		// not part of the bench a round consults; their view reaches the
		// council as context or as a captured source, written by them.
		if str(seat["role"]) == "advisor" && kindOf[str(seat["member_id"])] != "human" {
			advisors = append(advisors, seat)
		}
	}

	var wanted []string
	for _, x := range arr(req.Payload["seat_ids"]) {
		wanted = append(wanted, str(x))
	}
	if len(wanted) == 0 && addressed != "" {
		wanted = []string{addressed}
	}

	selected := advisors
	if len(wanted) > 0 {
		selected = nil
		for _, id := range wanted {
			seat, ok := byID[id]
			if !ok {
				return nil, fail(CodeInternal, fmt.Sprintf("seat %q is not on this council", id), false)
			}
			if str(seat["role"]) == "chair" {
				return nil, fail(CodeInternal, "the chair synthesises the round and is not consulted as an advisor", false)
			}
			if kindOf[str(seat["member_id"])] == "human" {
				return nil, fail(CodeInternal, fmt.Sprintf(
					"seat %q is held by a human member, who is the local user; Council does not put words in their mouth. Add what they said as context or capture it as a source.", id), false)
			}
			selected = append(selected, seat)
		}
	}
	if len(selected) == 0 {
		return nil, fail(CodeInternal, "this council has no advisor seat a model can be asked to answer for", false)
	}
	if maxMembers > 0 && len(selected) > maxMembers {
		return nil, fail(CodeInternal, fmt.Sprintf(
			"%d seats were selected but this council allows %d per round; name the seats explicitly in seat_ids so the choice is visible",
			len(selected), maxMembers), false)
	}
	return selected, nil
}

// newRun builds a pending run with one pending contribution per consulted seat.
// Nothing is executed here: this build carries the state model, and executeRun
// fills these contributions in once the engine's lock is released.
func (s *Store) newRun(session map[string]any, requestID, kind, prompt, addressed string, seats []map[string]any) (map[string]any, []any) {
	taken := map[string]bool{}
	for _, x := range arr(session["runs"]) {
		run := obj(x)
		taken[str(run["run_id"])] = true
		for _, c := range append(append([]any{}, arr(run["contributions"])...), synthesisOf(run)...) {
			taken[str(obj(c)["contribution_id"])] = true
		}
	}
	memberRev := map[string]float64{}
	for _, x := range arr(obj(session["definition_snapshot"])["members"]) {
		member := obj(x)
		memberRev[str(member["member_id"])] = num(member["member_revision"])
	}

	contributions := []any{}
	ids := []any{}
	for _, seat := range seats {
		memberID := str(seat["member_id"])
		id := s.mintID("con", func(c string) bool { return taken[c] })
		taken[id] = true
		ids = append(ids, id)
		contributions = append(contributions, map[string]any{
			"contribution_id": id,
			"seat_id":         str(seat["seat_id"]),
			"member_id":       memberID,
			"member_revision": memberRev[memberID],
			"status":          "pending",
			"claims":          []any{},
		})
	}

	run := map[string]any{
		"run_id":        s.mintID("run", func(c string) bool { return taken[c] }),
		"request_id":    requestID,
		"kind":          kind,
		"status":        "pending",
		"started_at":    s.now(),
		"contributions": contributions,
	}
	if prompt != "" {
		run["prompt"] = prompt
	}
	if addressed != "" {
		run["addressed_seat_id"] = addressed
	}
	return run, ids
}

// ---------------------------------------------------------------------------
// waiting, cancelling, retrying
// ---------------------------------------------------------------------------

// cmdRunAwait reports a run's state. It is a read: it changes nothing, and the
// waiting itself happens in afterRunAwait with the engine lock released, so a
// second panel watching a run cannot stop the engine answering anybody else.
func cmdRunAwait(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	run, f := requireRun(session, req)
	if f != nil {
		return nil, f
	}
	return map[string]any{
		"session_id": str(session["session_id"]),
		"run_id":     str(run["run_id"]),
		"status":     str(run["status"]),
	}, nil
}

// afterRunAwait waits for the run on the envelope's own wait_seconds — the same
// bound run.start uses, so there is one answer to "how long may the backend
// hold a reply" rather than two that can drift apart. A run still going when
// the wait ends is reported as it stands, with resting:false, and the caller
// asks again.
func afterRunAwait(s *Store, req *Request, payload map[string]any) Reply {
	resting := s.awaitRun(str(payload["session_id"]), str(payload["run_id"]), req.waitFor(), req.generation)
	reply := s.readOutcome(req, str(payload["session_id"]), str(payload["run_id"]), false)
	if reply.OK {
		reply.Payload["resting"] = resting
	}
	return reply
}

// cmdRunCancel stops a run. It is deliberately tolerant of arriving late: the
// host's chat provider fires cancel_tool without awaiting it, so a cancel for a
// run that has already stopped is a success that moves nothing.
func cmdRunCancel(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	run, f := requireRun(session, req)
	if f != nil {
		return nil, f
	}
	status := str(run["status"])
	if status != "pending" && status != "running" {
		return map[string]any{
			"session_id": str(session["session_id"]),
			"run_id":     str(run["run_id"]),
			"status":     status,
			"changed":    false,
		}, nil
	}
	for _, x := range arr(run["contributions"]) {
		contribution := obj(x)
		switch str(contribution["status"]) {
		case "pending", "running":
			contribution["status"] = "cancelled"
		}
	}
	run["status"] = "cancelled"
	run["ended_at"] = s.now()
	run["failure"] = map[string]any{
		"code":      CodeCancelled,
		"message":   "The run was cancelled before it finished. Start it again to ask the same question.",
		"retryable": true,
	}
	session["status"] = contract.DeriveSessionStatus(session)
	bumpSession(session)

	// Stop the calls themselves. The record above is what the user sees; this
	// is what stops the spending. Anything already in flight lands on a run
	// that is no longer "running" and is recorded stale, never applied.
	if control := s.live[runKey(str(session["session_id"]), str(run["run_id"]))]; control != nil {
		control.cancel()
	}
	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"run_id":           str(run["run_id"]),
		"status":           "cancelled",
		"changed":          true,
	}, nil
}

// cmdRunRetry starts a fresh run over the seats the previous one did not
// answer. It never resumes the old run: the process that owned those calls is
// gone, and a retry the user asked for is the only thing that spends tokens.
//
// seat_ids narrows it further, which is how "retry just this one member" is
// expressed — a round that lost three members and only needs one of them back
// should not pay for the other two.
func cmdRunRetry(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	previous, f := requireRun(session, req)
	if f != nil {
		return nil, f
	}
	if status := str(previous["status"]); status == "pending" || status == "running" {
		return nil, fail(CodeInternal,
			fmt.Sprintf("run %q is still %s; cancel it before retrying", str(previous["run_id"]), status), false)
	}

	def := obj(session["definition_snapshot"])
	rules, f := readLimits(def, req.Payload)
	if f != nil {
		return nil, f
	}
	if f := checkRoundBudget(session, rules.RoundsPerSession); f != nil {
		return nil, f
	}

	wanted := map[string]bool{}
	for _, x := range arr(req.Payload["seat_ids"]) {
		wanted[str(x)] = true
	}
	byID := map[string]map[string]any{}
	for _, x := range arr(def["seats"]) {
		seat := obj(x)
		byID[str(seat["seat_id"])] = seat
	}
	var seats []map[string]any
	unanswered := map[string]bool{}
	for _, x := range arr(previous["contributions"]) {
		contribution := obj(x)
		if str(contribution["status"]) == "complete" {
			continue
		}
		seatID := str(contribution["seat_id"])
		unanswered[seatID] = true
		if len(wanted) > 0 && !wanted[seatID] {
			continue
		}
		if seat, ok := byID[seatID]; ok {
			seats = append(seats, seat)
		}
	}
	for id := range wanted {
		if !unanswered[id] {
			return nil, fail(CodeInternal, fmt.Sprintf(
				"seat %q answered run %q; a retry only re-asks the seats that did not", id, str(previous["run_id"])), false)
		}
	}
	if len(seats) == 0 {
		return nil, fail(CodeInternal,
			fmt.Sprintf("every seat in run %q answered; there is nothing to retry", str(previous["run_id"])), false)
	}
	// A retry inherits the previous run's overrides, so it is checked against
	// the catalogue as it stands now: a model that has since been disabled must
	// stop the retry rather than fail every seat in it.
	if f := s.checkRunModels(session, obj(previous["model_overrides"]), seats); f != nil {
		return nil, f
	}

	run, contributionIDs := s.newRun(session, req.RequestID, "retry", str(previous["prompt"]), str(previous["addressed_seat_id"]), seats)
	if claimID := str(previous["addressed_claim_id"]); claimID != "" {
		run["addressed_claim_id"] = claimID
	}
	if overrides := obj(previous["model_overrides"]); len(overrides) > 0 {
		run["model_overrides"] = overrides
	}
	if narrowed := obj(req.Payload["limits"]); len(narrowed) > 0 {
		run["limits"] = narrowed
	} else if inherited := obj(previous["limits"]); len(inherited) > 0 {
		run["limits"] = inherited
	}
	session["runs"] = append(arr(session["runs"]), run)
	session["status"] = contract.DeriveSessionStatus(session)
	bumpSession(session)
	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"run_id":           str(run["run_id"]),
		"retry_of":         str(previous["run_id"]),
		"status":           "pending",
		"seat_ids":         seatIDs(seats),
		"contribution_ids": contributionIDs,
	}, nil
}

// ---------------------------------------------------------------------------
// outcomes
// ---------------------------------------------------------------------------

// cmdOutcomeRetain links a conclusion the user kept to the note that holds it.
// The note is the durable artifact; this record is only the way back to the
// contribution it came from.
func cmdOutcomeRetain(s *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	run, f := requireRun(session, req)
	if f != nil {
		return nil, f
	}
	contributionID, f := need(req.Payload, "contribution_id")
	if f != nil {
		return nil, f
	}
	noteRef, f := need(req.Payload, "note_ref")
	if f != nil {
		return nil, f
	}
	note := map[string]any{"kind": "note", "ref": noteRef}
	if label := str(req.Payload["note_label"]); label != "" {
		note["label"] = label
	}
	taken := map[string]bool{}
	for _, x := range arr(session["outcomes"]) {
		taken[str(obj(x)["outcome_id"])] = true
	}
	outcome := map[string]any{
		"outcome_id":      s.mintID("out", func(c string) bool { return taken[c] }),
		"run_id":          str(run["run_id"]),
		"contribution_id": contributionID,
		"note":            note,
		"retained_at":     s.now(),
	}
	session["outcomes"] = append(arr(session["outcomes"]), outcome)
	bumpSession(session)
	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"outcome_id":       str(outcome["outcome_id"]),
	}, nil
}

// ---------------------------------------------------------------------------
// reporting a run
// ---------------------------------------------------------------------------

// readOutcome renders a run as it now stands. It is the reply shape both
// run.start and run.await answer with, so the two cannot describe the same run
// differently.
func (s *Store) readOutcome(req *Request, sessionID, runID string, remember bool) Reply {
	s.mu.Lock()
	defer s.mu.Unlock()
	requestID := req.RequestID
	if req.generation != s.generation {
		return errReply(requestID, s.revision(), fail(CodeStaleRevision, "The document was replaced while this request was in flight; re-read before retrying.", true))
	}
	session, _ := findByID(s.snapshot["sessions"], "session_id", sessionID)
	if session == nil {
		return errReply(requestID, s.revision(), fail(CodeInternal,
			fmt.Sprintf("session %q is no longer in this project; the document was replaced while the run was in flight", sessionID), true))
	}
	run, _ := findByID(session["runs"], "run_id", runID)
	if run == nil {
		return errReply(requestID, s.revision(), fail(CodeInternal,
			fmt.Sprintf("run %q is no longer in this project; the document was replaced while it was in flight", runID), true))
	}

	contributions := []any{}
	for _, x := range arr(run["contributions"]) {
		contribution := obj(x)
		entry := map[string]any{
			"contribution_id": str(contribution["contribution_id"]),
			"seat_id":         str(contribution["seat_id"]),
			"status":          str(contribution["status"]),
			"claims":          len(arr(contribution["claims"])),
		}
		if model := str(contribution["model_id"]); model != "" {
			entry["model_id"] = model
		}
		if usage := obj(contribution["usage"]); usage != nil {
			entry["usage"] = usage
		}
		if failure := obj(contribution["failure"]); failure != nil {
			entry["failure"] = failure
		}
		contributions = append(contributions, entry)
	}

	payload := map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"run_id":           str(run["run_id"]),
		"kind":             str(run["kind"]),
		"status":           str(run["status"]),
		"session_status":   str(session["status"]),
		"contributions":    contributions,
	}
	// How long one member gets, under the limits THIS run was started with. A
	// caller reading a round that is still going needs the number to know
	// whether waiting is reasonable, and a local model on a cold start is the
	// case where it is measured in minutes; deriving it here rather than in the
	// chat renderer keeps one answer to "how long".
	if rules, f := readLimits(obj(session["definition_snapshot"]), run); f == nil {
		payload["per_member_timeout_seconds"] = int(rules.MemberTimeout / time.Second)
	}
	if synthesis := obj(run["synthesis"]); synthesis != nil {
		payload["synthesis"] = deepCopy(synthesis)
	}
	if failure := obj(run["failure"]); failure != nil {
		payload["failure"] = failure
	}
	reply := okReply(requestID, s.revision(), payload)
	if remember {
		s.ledger[requestID] = reply
	}
	return reply
}

func requireRun(session map[string]any, req *Request) (map[string]any, *Failure) {
	id, f := need(req.Payload, "run_id")
	if f != nil {
		return nil, f
	}
	for _, x := range arr(session["runs"]) {
		if run := obj(x); str(run["run_id"]) == id {
			return run, nil
		}
	}
	return nil, fail(CodeInternal, fmt.Sprintf("run %q is not part of session %q", id, str(session["session_id"])), false)
}

func seatIDs(seats []map[string]any) []any {
	out := []any{}
	for _, seat := range seats {
		out = append(out, str(seat["seat_id"]))
	}
	return out
}

// cmdOutcomeMarkMissing records that a retained note could not be resolved —
// the user moved it, deleted it, or it belongs to a project that is not open —
// or that it has come back.
//
// The reference is KEPT either way. A note that cannot be resolved today is a
// recoverable state, and dropping the link would lose the only record of which
// contribution the conclusion came from; the flag is what lets the panel show
// the outcome as unresolved instead of showing a link that silently opens
// nothing. Resolving the note is the wrapper's job — it is the only side that
// can ask the host — so this command carries the answer rather than deriving it.
func cmdOutcomeMarkMissing(_ *Store, snap map[string]any, req *Request) (map[string]any, *Failure) {
	session, f := requireSession(snap, req)
	if f != nil {
		return nil, f
	}
	outcomeID, f := need(req.Payload, "outcome_id")
	if f != nil {
		return nil, f
	}
	outcome, _ := findByID(session["outcomes"], "outcome_id", outcomeID)
	if outcome == nil {
		return nil, fail(CodeInternal,
			fmt.Sprintf("session %q has no outcome %q", str(session["session_id"]), outcomeID), false)
	}
	missing, ok := req.Payload["missing"].(bool)
	if !ok {
		return nil, fail(CodeInternal, "payload field \"missing\" is required and must be a boolean", false)
	}
	note := obj(outcome["note"])
	if note == nil {
		return nil, fail(CodeInternal,
			fmt.Sprintf("outcome %q carries no note reference to mark", outcomeID), false)
	}
	if was, _ := note["missing"].(bool); was == missing {
		// Already saying this. Reported as unchanged so a repeated resolve
		// attempt does not advance the revision under every other open view.
		return map[string]any{
			"session_id":  str(session["session_id"]),
			"outcome_id":  outcomeID,
			"missing":     missing,
			"changed":     false,
			"note_ref":    str(note["ref"]),
			"note_kind":   str(note["kind"]),
			"description": "the note reference already said this",
		}, nil
	}
	if missing {
		note["missing"] = true
	} else {
		delete(note, "missing")
	}
	bumpSession(session)
	return map[string]any{
		"session_id":       str(session["session_id"]),
		"session_revision": int(num(session["session_revision"])),
		"outcome_id":       outcomeID,
		"missing":          missing,
		"changed":          true,
		"note_ref":         str(note["ref"]),
		"note_kind":        str(note["kind"]),
	}, nil
}
