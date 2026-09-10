package session

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/ipeerbhai/plugins/council/internal/contract"
)

// This file runs one bounded round: it plans the calls, makes them under the
// council's own limits, and writes each result into the snapshot.
//
// Two properties shape everything here.
//
// The engine holds its lock only to read a plan and to commit a result, never
// across a model call. A round that held the lock would make cancel, a second
// panel's read, and the whole rest of the protocol wait on a model, and a run
// that could not be cancelled while it ran would be the one state the user most
// needs out of.
//
// A result is applied only if the run is still the one that asked for it. The
// handle a round is started with is the identity: a run that was cancelled, a
// snapshot that has been replaced by Load, or a second attempt at the same seat
// all leave a reply with nowhere to land, and the engine drops it rather than
// letting an old answer overwrite newer state.

// runKey identifies one run. It is (session, run) and not the run id alone,
// because a run id is only unique WITHIN a session — the invariants require no
// more, and newRun mints against that session's ids. Two sessions holding a
// "run-1" is ordinary, and a handle keyed on the id alone would let one
// session's round cancel the other's and answer questions about it.
func runKey(sessionID, runID string) string {
	return sessionID + "\x00" + runID
}

// runControl is the engine's live handle on one executing run. Its identity —
// the pointer — is what a landing result is checked against, so a result from a
// superseded generation cannot match however the ids line up.
type runControl struct {
	cancel context.CancelFunc
	done   chan struct{}
}

// plannedCall is one consultation, assembled and ready to send.
type plannedCall struct {
	call ModelCall
	// allowed is the citation set this member may draw on: exactly the anchors
	// in the source revisions it is grounded in. It travels with the call
	// because it is also the oracle for reading the reply.
	allowed map[string]bool
}

// runPlan is everything executeRun needs, read out of the snapshot in one
// locked step so the round is planned against one consistent revision.
type runPlan struct {
	calls   []plannedCall
	rules   limits
	control *runControl
	ctx     context.Context
	cancel  context.CancelFunc
}

// startRun takes the pending run to "running", registers the handle the round
// is tracked by, and hands execution to a background goroutine.
//
// It returns once the run is REGISTERED, not once it is finished, which is what
// lets the command that started it wait on the run rather than race it: by the
// time this returns, AwaitRun can see the round.
func (s *Store) startRun(sessionID, runID string, generation uint64) {
	plan, ok := s.planRun(sessionID, runID, generation)
	if !ok {
		return
	}
	go s.executeRun(plan, sessionID, runID)
}

// executeRun is the whole of a run's life after it has been planned. It runs on
// its own goroutine with the engine lock released, so reads, run.await and
// run.cancel are all answered while it works.
func (s *Store) executeRun(plan runPlan, sessionID, runID string) {
	defer plan.cancel()
	defer close(plan.control.done)
	defer s.forgetRun(sessionID, runID, plan.control)

	// The semaphore is the concurrency limit. It bounds what the round has in
	// flight at any instant; the number of calls is already bounded by the
	// seats the run was created over.
	slots := make(chan struct{}, plan.rules.Concurrent)
	var wg sync.WaitGroup
	for _, planned := range plan.calls {
		wg.Add(1)
		go func(planned plannedCall) {
			defer wg.Done()
			select {
			case slots <- struct{}{}:
			case <-plan.ctx.Done():
				// The run's budget or a cancel arrived before this member was
				// ever dialled. Report it against the contribution rather than
				// leaving it pending forever.
				s.applyMemberResult(plan.control, sessionID, runID, planned, ModelReply{}, plan.ctx.Err())
				return
			}
			defer func() { <-slots }()

			callCtx, cancelCall := context.WithTimeout(plan.ctx, plan.rules.MemberTimeout)
			defer cancelCall()
			reply, err := s.generate(callCtx, planned.call, plan.rules.PromptBytes)
			s.applyMemberResult(plan.control, sessionID, runID, planned, reply, err)
		}(planned)
	}
	wg.Wait()

	// The chair is inside the run budget too: run_budget_seconds bounds the
	// whole round, synthesis included.
	s.synthesise(plan.ctx, plan.control, sessionID, runID, plan.rules)
}

// planRun takes the pending run to "running", assembles every call from the
// snapshot as it stands, and registers the control the results are checked
// against. It reports false when there is nothing to run — a run somebody
// cancelled before it started, or one a replaced snapshot no longer holds.
func (s *Store) planRun(sessionID, runID string, generation uint64) (runPlan, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if generation != s.generation {
		return runPlan{}, false
	}
	session, _ := findByID(s.snapshot["sessions"], "session_id", sessionID)
	if session == nil {
		return runPlan{}, false
	}
	run, _ := findByID(session["runs"], "run_id", runID)
	if run == nil || str(run["status"]) != "pending" {
		return runPlan{}, false
	}
	def := obj(session["definition_snapshot"])
	// The run record carries its own narrowing, so a round is planned under the
	// limits the run was started with rather than under whatever the council
	// says today.
	rules, f := readLimits(def, run)
	if f != nil {
		return runPlan{}, false
	}
	// An adapter that can only carry so many calls at once is the real ceiling.
	// Clamping here rather than letting members queue inside it matters: a
	// member's timeout is armed when it takes a slot, so one that waited in the
	// adapter would spend its whole allowance queueing and expire without ever
	// having been asked.
	if limiter, ok := s.chat.(ConcurrencyLimiter); ok {
		if carried := limiter.Concurrency(); carried > 0 && carried < rules.Concurrent {
			rules.Concurrent = carried
		}
	}

	var calls []plannedCall
	for _, x := range arr(run["contributions"]) {
		contribution := obj(x)
		seat, _ := findByID(def["seats"], "seat_id", str(contribution["seat_id"]))
		member, _ := findByID(def["members"], "member_id", str(contribution["member_id"]))
		if seat == nil || member == nil {
			continue
		}
		grounding := groundingSections(def, member)
		advisorModel, advisorProvider, advisorSpec := s.modelFor(run, str(seat["seat_id"]), member)
		system := memberSystem(member, seat)
		user, allowed := advisorPrompt(session, run, grounding, rules.PromptBytes-len(system))
		calls = append(calls, plannedCall{
			call: ModelCall{
				RunID:          runID,
				ContributionID: str(contribution["contribution_id"]),
				SeatID:         str(seat["seat_id"]),
				MemberID:       str(member["member_id"]),
				MemberRevision: int(num(member["member_revision"])),
				Role:           "advisor",
				Model:          advisorModel,
				Provider:       advisorProvider,
				ModelSpec:      advisorSpec,
				System:         system,
				User:           user,
			},
			allowed: allowed,
		})
	}

	// The run moves to "running" before a single call goes out, so a crash
	// between here and the first result still leaves a record the interruption
	// rule can demote.
	if f := s.commit(func(snap map[string]any) *Failure {
		return markRunning(snap, sessionID, runID)
	}); f != nil {
		s.failResult(sessionID, runID, f)
		return runPlan{}, false
	}

	ctx, cancel := context.WithTimeout(context.Background(), rules.RunBudget)
	control := &runControl{cancel: cancel, done: make(chan struct{})}
	s.live[runKey(sessionID, runID)] = control
	return runPlan{calls: calls, rules: rules, control: control, ctx: ctx, cancel: cancel}, true
}

func markRunning(snap map[string]any, sessionID, runID string) *Failure {
	session, _ := findByID(snap["sessions"], "session_id", sessionID)
	if session == nil {
		return fail(CodeInternal, "the session went away while its run was starting", false)
	}
	run, _ := findByID(session["runs"], "run_id", runID)
	if run == nil {
		return fail(CodeInternal, "the run went away while it was starting", false)
	}
	run["status"] = "running"
	for _, x := range arr(run["contributions"]) {
		contribution := obj(x)
		if str(contribution["status"]) == "pending" {
			contribution["status"] = "running"
		}
	}
	session["status"] = contract.DeriveSessionStatus(session)
	bumpSession(session)
	return nil
}

// advisorPrompt is what one member is sent. It carries the question, the shared
// context snapshot, this member's own grounding, and — on a follow-up — what
// this member itself said before. It never carries another member's answer.
func advisorPrompt(session, run map[string]any, grounding []section, maxBytes int) (string, map[string]bool) {
	question := str(session["question"])
	sections := []section{{
		label: "The question",
		body:  question,
	}}
	if context := str(obj(session["context_snapshot"])["inline"]); context != "" {
		sections = append(sections, section{
			label:     "Context selected for this consultation",
			body:      context,
			droppable: true,
		})
	}
	sections = append(sections, grounding...)

	if str(run["kind"]) != "initial_round" {
		if prompt := str(run["prompt"]); prompt != "" {
			sections = append(sections, section{
				label: "What you are being asked now",
				body:  prompt,
			})
		}
		if quoted := addressedArgument(session, run); quoted != "" {
			sections = append(sections, section{
				label: "The argument you are being asked about — your own, from an earlier round",
				body:  quoted,
			})
		}
		if earlier := earlierAnswer(session, run); earlier != "" {
			sections = append(sections, section{
				label:     "What you said earlier in this session",
				body:      earlier,
				droppable: true,
			})
		}
	}

	sections = append(sections, section{label: "How to answer", body: replyContract})
	return assemble(sections, maxBytes)
}

// addressedArgument returns the claim a follow-up names. A follow-up about an
// argument is routed to the member that made it, so the claim is always this
// member's own and quoting it here shows no other member's work.
func addressedArgument(session, run map[string]any) string {
	claimID := str(run["addressed_claim_id"])
	if claimID == "" {
		return ""
	}
	for _, r := range arr(session["runs"]) {
		for _, c := range contributionsOf(obj(r)) {
			for _, x := range arr(obj(c)["claims"]) {
				claim := obj(x)
				if str(claim["claim_id"]) == claimID {
					return fmt.Sprintf("(%s) %s", str(claim["support"]), str(claim["text"]))
				}
			}
		}
	}
	return ""
}

// earlierAnswer is this seat's most recent completed contribution in this
// session, so a follow-up does not start from nothing.
func earlierAnswer(session, run map[string]any) string {
	seatID := str(run["addressed_seat_id"])
	if seatID == "" {
		return ""
	}
	text := ""
	for _, r := range arr(session["runs"]) {
		earlier := obj(r)
		if str(earlier["run_id"]) == str(run["run_id"]) {
			break
		}
		for _, c := range contributionsOf(earlier) {
			contribution := obj(c)
			if str(contribution["seat_id"]) == seatID && str(contribution["status"]) == "complete" {
				text = str(contribution["text"])
			}
		}
	}
	return text
}

// contributionsOf lists a run's member contributions. The synthesis is a
// Contribution too but is not one of them: it is the chair's reading of the
// round, and treating it as a member answer would let it be quoted back to a
// member as their own.
func contributionsOf(run map[string]any) []any {
	return arr(run["contributions"])
}

// ---------------------------------------------------------------------------
// landing a result
// ---------------------------------------------------------------------------

// applyMemberResult writes one member's answer into the snapshot, or records
// why there is none.
//
// The control pointer is the whole of the staleness check. If the run the
// engine is currently tracking under this id is not this one — because Load
// replaced the document, or because this round already finished and another
// started — the reply has nowhere to land and is dropped without touching
// anything.
func (s *Store) applyMemberResult(control *runControl, sessionID, runID string, planned plannedCall, reply ModelReply, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.live[runKey(sessionID, runID)] != control {
		return
	}
	f := s.commit(func(snap map[string]any) *Failure {
		session, _ := findByID(snap["sessions"], "session_id", sessionID)
		if session == nil {
			return fail(CodeInternal, "the session is gone", false)
		}
		run, _ := findByID(session["runs"], "run_id", runID)
		if run == nil {
			return fail(CodeInternal, "the run is gone", false)
		}
		contribution, _ := findByID(run["contributions"], "contribution_id", planned.call.ContributionID)
		if contribution == nil {
			return fail(CodeInternal, "the contribution is gone", false)
		}

		// The run has left "running": cancelled, or already finished. A reply
		// that still arrives is recorded with full attribution as "stale" and
		// changes nothing else — not the run, not the session, not the
		// synthesis. An error at this point is not news and is dropped.
		if str(run["status"]) != "running" {
			if err != nil {
				return unchanged
			}
			// The failure already recorded against this seat stays: the round
			// really did fail it, and the late text is added beside that rather
			// than in place of it.
			previous := contribution["failure"]
			writeAnswer(contribution, "stale", planned, reply, s.claimMinter(session))
			if previous != nil {
				contribution["failure"] = previous
			}
			bumpSession(session)
			return nil
		}

		if err != nil {
			contribution["status"] = statusForError(err)
			contribution["failure"] = failureForError(err, str(contribution["seat_id"]))
		} else {
			writeAnswer(contribution, "complete", planned, reply, s.claimMinter(session))
		}
		session["status"] = contract.DeriveSessionStatus(session)
		bumpSession(session)
		return nil
	})
	if f != nil && f != unchanged {
		s.failResult(sessionID, runID, f)
	}
}

// writeAnswer records what a model said: the text, the model that produced it,
// what it cost, and the claims read out of it under this member's own citation
// set.
func writeAnswer(contribution map[string]any, status string, planned plannedCall, reply ModelReply, mint func() string) {
	parsed := parseReply(reply.Text)
	contribution["status"] = status
	contribution["text"] = answerText(parsed, reply.Text)
	contribution["claims"] = buildClaims(parsed, planned.allowed, mint)
	if reply.ModelID != "" {
		contribution["model_id"] = reply.ModelID
	} else if planned.call.Model != "" {
		contribution["model_id"] = planned.call.Model
	}
	if reply.UsageReported {
		contribution["usage"] = map[string]any{
			"prompt_tokens":     float64(reply.PromptTokens),
			"completion_tokens": float64(reply.CompletionTokens),
		}
	}
	delete(contribution, "failure")
}

// claimMinter issues claim ids that are unique within a session, so a citation
// or a follow-up can name one argument without ambiguity.
func (s *Store) claimMinter(session map[string]any) func() string {
	taken := map[string]bool{}
	for _, r := range arr(session["runs"]) {
		run := obj(r)
		all := append(append([]any{}, arr(run["contributions"])...), synthesisOf(run)...)
		for _, c := range all {
			for _, x := range arr(obj(c)["claims"]) {
				taken[str(obj(x)["claim_id"])] = true
			}
		}
	}
	return func() string {
		id := s.mintID("clm", func(candidate string) bool { return taken[candidate] })
		taken[id] = true
		return id
	}
}

func synthesisOf(run map[string]any) []any {
	if synthesis := obj(run["synthesis"]); synthesis != nil {
		return []any{synthesis}
	}
	return nil
}

// statusForError and failureForError turn one call's error into the visible
// state the record carries. A cancelled call and an exhausted budget are
// different things to a user, so they are different codes with different
// sentences.
func statusForError(err error) string {
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	return "failed"
}

func failureForError(err error, seatID string) map[string]any {
	switch {
	case errors.Is(err, context.Canceled):
		return map[string]any{
			"code":      CodeCancelled,
			"message":   fmt.Sprintf("The consultation of %s was cancelled before it answered.", seatID),
			"retryable": true,
		}
	case errors.Is(err, context.DeadlineExceeded):
		return map[string]any{
			"code":      CodeTimeout,
			"message":   fmt.Sprintf("%s did not answer inside this council's time limit.", seatID),
			"retryable": true,
		}
	}
	return map[string]any{
		"code":      failureCodeOf(err),
		"message":   truncateMessage(fmt.Sprintf("%s could not be consulted: %v", seatID, err)),
		"retryable": true,
	}
}

// truncateMessage keeps a failure inside the schema's 2000-character ceiling.
// A message from a host that quoted a whole request back must not be the reason
// a snapshot is refused.
func truncateMessage(message string) string {
	const max = 2000
	if len(message) <= max {
		return message
	}
	return message[:max-3] + "..."
}

// forgetRun drops the engine's handle on a finished run, but only if it is
// still the one being tracked: a Load that replaced the document has already
// installed a different world, and clearing its entry would be this round
// reaching into it.
func (s *Store) forgetRun(sessionID, runID string, control *runControl) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := runKey(sessionID, runID)
	if s.live[key] == control {
		delete(s.live, key)
	}
}

func (s *Store) chatHost() ChatHost {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.chat
}

// AwaitRun blocks until the run has reached a resting state, or until the
// timeout expires. It reports whether the run is resting.
//
// "Resting" is read from the RECORD, not from whether the engine holds a live
// handle. The two are not the same for a moment: the command that creates a run
// commits it as "pending" and only then plans it, so a third party's run.await
// arriving in that window would find no handle and, on the handle alone, answer
// resting:true about a run that has not started.
//
// The alternative — registering the handle inside the same commit — was not
// taken. A handle is execution state, not snapshot state, and putting it inside
// the mutation would register it for a change the contract can still refuse,
// which would either break the one commit path or make it undo engine state on
// its way out. Reading the record instead leaves that path untouched and makes
// "resting" mean the one thing a caller can also see for itself.
//
// A run the snapshot does not hold at all is resting: a caller asking about a
// run that finished, or whose document was replaced, deserves an answer rather
// than a timeout.
func (s *Store) AwaitRun(sessionID, runID string, timeout time.Duration) bool {
	s.mu.Lock()
	generation := s.generation
	s.mu.Unlock()
	return s.awaitRun(sessionID, runID, timeout, generation)
}

func (s *Store) awaitRun(sessionID, runID string, timeout time.Duration, generation uint64) bool {
	deadline := time.Now().Add(timeout)
	for {
		s.mu.Lock()
		control := s.live[runKey(sessionID, runID)]
		live := generation == s.generation && s.runIsLive(sessionID, runID)
		s.mu.Unlock()
		if !live {
			return true
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return false
		}
		if control != nil {
			select {
			case <-control.done:
				// Look again rather than answering: the record is what the
				// caller is told about, and the handle going away is only the
				// engine's own bookkeeping.
				continue
			case <-time.After(remaining):
				return false
			}
		}
		// The record says the run has not started and no handle exists yet, so
		// the command that created it has not reached planRun. That window is
		// microseconds wide; look again shortly rather than build a second
		// signal for it.
		wait := 2 * time.Millisecond
		if remaining < wait {
			wait = remaining
		}
		time.Sleep(wait)
	}
}

// runIsLive reports whether the snapshot still holds this run in a state that
// is going somewhere. It looks inside the named session and nowhere else: a run
// id belongs to its session, and answering from another session's run of the
// same name is how a round gets reported finished before it has started.
// The caller holds the lock.
func (s *Store) runIsLive(sessionID, runID string) bool {
	session, _ := findByID(s.snapshot["sessions"], "session_id", sessionID)
	if session == nil {
		return false
	}
	run, _ := findByID(session["runs"], "run_id", runID)
	if run == nil {
		return false
	}
	status := str(run["status"])
	return status == "pending" || status == "running"
}

// cancelLive stops every run this engine is executing. Load calls it: the
// document those runs belong to is being replaced, and a call still in flight
// against it must not be able to write into the one that takes its place.
// The caller holds the lock.
func (s *Store) cancelLive() {
	for id, control := range s.live {
		control.cancel()
		delete(s.live, id)
	}
}

// summariseMissing names the seats that did not answer and why, in one line per
// seat. It is what a partial run's failure says, and what the chair is told is
// missing.
func summariseMissing(run map[string]any) []string {
	var missing []string
	for _, x := range arr(run["contributions"]) {
		contribution := obj(x)
		if str(contribution["status"]) == "complete" {
			continue
		}
		reason := str(obj(contribution["failure"])["message"])
		if reason == "" {
			reason = "no answer was recorded."
		}
		missing = append(missing, fmt.Sprintf("%s: %s", str(contribution["seat_id"]), reason))
	}
	return missing
}

// worstCode picks the failure code a partial run reports. A timeout is the one
// a user acts on differently from the rest, so it wins; otherwise the first
// recorded code stands, and model_error is the fallback when a contribution
// failed without one.
func worstCode(run map[string]any) string {
	code := ""
	for _, x := range arr(run["contributions"]) {
		contribution := obj(x)
		if str(contribution["status"]) == "complete" {
			continue
		}
		got := str(obj(contribution["failure"])["code"])
		if got == CodeTimeout {
			return CodeTimeout
		}
		if code == "" && got != "" {
			code = got
		}
	}
	if code == "" {
		return CodeModelError
	}
	return code
}

func joinLines(lines []string) string {
	return strings.Join(lines, " ")
}
