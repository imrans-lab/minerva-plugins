package session

import (
	"context"
	"fmt"
	"strings"

	"github.com/ipeerbhai/plugins/council/internal/contract"
)

// The chair reads the round and writes the answer the user sees. Three rules
// hold it in place, and each of them is a thing the engine does rather than a
// thing the chair is asked to promise:
//
//   - it runs over the results that exist, never over the results that were
//     hoped for, so one member timing out costs the round that member and not
//     the answer;
//   - a round that lost a member is labelled as such by the engine, in a claim
//     the chair did not write and cannot omit;
//   - it is the only call that sees the whole bench.

// chairPlan is the synthesis call, assembled under the lock.
type chairPlan struct {
	planned plannedCall
	missing []string
	// finishNow is set when there is nothing to synthesise, and carries the
	// failure the run rests on.
	finishNow *Failure
}

// synthesise closes the run: chair call, synthesis record, final status.
func (s *Store) synthesise(parent context.Context, control *runControl, sessionID, runID string, rules limits) {
	plan, ok := s.planSynthesis(control, sessionID, runID, rules)
	if !ok {
		return
	}
	if plan.finishNow != nil {
		s.commitRunOutcome(control, sessionID, runID, nil, ModelReply{}, plan)
		return
	}

	if err := s.markDispatched(control, sessionID, runID, plan.planned.call, int(rules.MemberTimeout.Seconds())); err != nil {
		s.commitRunOutcome(control, sessionID, runID, err, ModelReply{}, plan)
		return
	}
	ctx, cancel := context.WithTimeout(parent, rules.MemberTimeout)
	defer cancel()
	reply, err := s.generate(ctx, plan.planned.call, rules.PromptBytes)
	s.commitRunOutcome(control, sessionID, runID, err, reply, plan)
}

// planSynthesis reads the finished round and builds the chair's call. It
// reports false when the run is no longer this engine's to finish — cancelled,
// or belonging to a snapshot that has been replaced.
func (s *Store) planSynthesis(control *runControl, sessionID, runID string, rules limits) (chairPlan, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.live[runKey(sessionID, runID)] != control {
		return chairPlan{}, false
	}
	session, _ := findByID(s.snapshot["sessions"], "session_id", sessionID)
	if session == nil {
		return chairPlan{}, false
	}
	run, _ := findByID(session["runs"], "run_id", runID)
	if run == nil || str(run["status"]) != "running" {
		// A cancelled run is already at rest and already carries the failure
		// that says so. Synthesising it would be answering a question the user
		// withdrew.
		return chairPlan{}, false
	}

	def := obj(session["definition_snapshot"])
	chairSeat := chairSeatOf(def)
	if chairSeat == nil {
		return chairPlan{finishNow: fail(CodeInternal,
			"this council has no chair seat, so the round cannot be synthesised", false)}, true
	}
	chair, _ := findByID(def["members"], "member_id", str(chairSeat["member_id"]))
	if chair == nil {
		return chairPlan{finishNow: fail(CodeInternal,
			"the chair's seat names a member this council does not hold", false)}, true
	}

	missing := summariseMissing(run)
	answered := 0
	for _, x := range arr(run["contributions"]) {
		if str(obj(x)["status"]) == "complete" {
			answered++
		}
	}
	if answered == 0 {
		return chairPlan{missing: missing, finishNow: fail(worstCode(run),
			"No member answered, so there is nothing to synthesise. "+joinLines(missing), true)}, true
	}

	system := chairSystem(chair, chairSeat, def)
	user, allowed := chairPrompt(session, run, missing, rules.PromptBytes-len(system))
	chairModel, chairProvider, chairSpec := s.modelFor(run, str(chairSeat["seat_id"]), chair)
	return chairPlan{
		missing: missing,
		planned: plannedCall{
			call: ModelCall{
				RunID:             runID,
				ContributionID:    s.mintContributionID(session),
				SeatID:            str(chairSeat["seat_id"]),
				MemberID:          str(chair["member_id"]),
				MemberRevision:    int(num(chair["member_revision"])),
				Role:              "chair",
				Model:             chairModel,
				Provider:          chairProvider,
				ModelSpec:         chairSpec,
				GenerationOptions: obj(chair["generation_options"]),
				System:            system,
				User:              user,
			},
			allowed: allowed,
		},
	}, true
}

func chairSeatOf(def map[string]any) map[string]any {
	for _, x := range arr(def["seats"]) {
		if seat := obj(x); str(seat["role"]) == "chair" {
			return seat
		}
	}
	return nil
}

// mintContributionID issues an id no contribution in this session already uses.
// The caller holds the lock.
func (s *Store) mintContributionID(session map[string]any) string {
	taken := map[string]bool{}
	for _, r := range arr(session["runs"]) {
		run := obj(r)
		for _, c := range append(append([]any{}, arr(run["contributions"])...), synthesisOf(run)...) {
			taken[str(obj(c)["contribution_id"])] = true
		}
	}
	return s.mintID("con", func(candidate string) bool { return taken[candidate] })
}

func chairSystem(chair, seat, def map[string]any) string {
	var b strings.Builder
	fmt.Fprintf(&b, "You are %q, chairing a council: %s\n", str(chair["display_name"]), str(seat["responsibility"]))
	b.WriteString("You add no position of your own. Everything you write must trace to a member's contribution below.\n")
	if obj(def["deliberation"])["preserve_disagreement"] == true {
		b.WriteString("Where members disagree substantively, report the disagreement and who holds which position. Do not resolve it into a single voice, and do not present a majority as a consensus.\n")
	}
	b.WriteString("Where the round is incomplete, say what is missing rather than writing around the gap.")
	return b.String()
}

// chairPrompt gives the chair the round: every completed contribution in full,
// with its claims and citations, and a plain statement of who did not answer.
func chairPrompt(session, run map[string]any, missing []string, maxBytes int) (string, map[string]bool) {
	def := obj(session["definition_snapshot"])
	sections := []section{{label: "The question", body: str(session["question"])}}
	if prompt := str(run["prompt"]); prompt != "" {
		sections = append(sections, section{label: "The focused question this round asked", body: prompt})
	}
	if context := str(obj(session["context_snapshot"])["inline"]); context != "" {
		sections = append(sections, section{
			label:     "Context selected for this consultation",
			body:      context,
			droppable: true,
		})
	}

	for _, x := range arr(run["contributions"]) {
		contribution := obj(x)
		if str(contribution["status"]) != "complete" {
			continue
		}
		seat, _ := findByID(def["seats"], "seat_id", str(contribution["seat_id"]))
		member, _ := findByID(def["members"], "member_id", str(contribution["member_id"]))
		allowed := map[string]bool{}
		var b strings.Builder
		b.WriteString(str(contribution["text"]))
		if claims := arr(contribution["claims"]); len(claims) > 0 {
			b.WriteString("\n\nTheir claims:\n")
			for _, c := range claims {
				claim := obj(c)
				fmt.Fprintf(&b, "  [%s] (%s) %s", str(claim["claim_id"]), str(claim["support"]), str(claim["text"]))
				for _, ci := range arr(claim["citations"]) {
					citation := obj(ci)
					allowed[citationKey(str(citation["source_id"]), int(num(citation["source_revision"])), str(citation["anchor_id"]))] = true
					fmt.Fprintf(&b, " — cites %s", citationKey(
						str(citation["source_id"]), int(num(citation["source_revision"])), str(citation["anchor_id"])))
				}
				b.WriteString("\n")
			}
		}
		sections = append(sections, section{
			anchors:   allowed,
			label:     fmt.Sprintf("%s (%s, %s) said", str(member["display_name"]), str(seat["seat_id"]), str(member["kind"])),
			body:      strings.TrimRight(b.String(), "\n"),
			droppable: true,
		})
	}

	if len(missing) > 0 {
		sections = append(sections, section{
			label: "Members who did not answer",
			body:  strings.Join(missing, "\n") + "\nThis round is incomplete. Say so in your answer, and do not speak for these seats.",
		})
	}
	sections = append(sections, section{label: "How to answer", body: replyContract})
	return assemble(sections, maxBytes)
}

// commitRunOutcome writes the synthesis and brings the run to rest.
//
// The three resting states it can write are the three the record model has for
// a round that ran: complete when every member answered and the chair spoke,
// partial when something is missing but there is still an answer, and failed
// when there is nothing to show.
func (s *Store) commitRunOutcome(control *runControl, sessionID, runID string, callErr error, reply ModelReply, plan chairPlan) {
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
		if str(run["status"]) != "running" {
			return unchanged
		}
		run["ended_at"] = s.now()

		switch {
		case plan.finishNow != nil:
			run["status"] = "failed"
			run["failure"] = failureRecord(plan.finishNow)
		case callErr != nil:
			// The members answered and the chair did not. That is a partial
			// round with everything the members said intact, not a lost one.
			run["status"] = "partial"
			run["failure"] = map[string]any{
				"code":      failureCodeOf(callErr),
				"message":   truncateMessage(fmt.Sprintf("The members answered but the chair could not synthesise the round: %v", callErr)),
				"retryable": true,
			}
		default:
			synthesis := map[string]any{
				"contribution_id": plan.planned.call.ContributionID,
				"seat_id":         plan.planned.call.SeatID,
				"member_id":       plan.planned.call.MemberID,
				"member_revision": float64(plan.planned.call.MemberRevision),
				"status":          "pending",
				"claims":          []any{},
			}
			writeAnswer(synthesis, "complete", plan.planned, reply, s.claimMinter(session))
			if len(plan.missing) > 0 {
				// The engine's own label, not the chair's. A partial round must
				// say it is partial even when the model wrote as though it were
				// not, so this claim is appended after the reply is read and is
				// not something a model can leave out.
				claims := arr(synthesis["claims"])
				claims = append(claims, map[string]any{
					"claim_id": s.claimMinter(session)(),
					"support":  "unknown",
					"text": truncateClaim(fmt.Sprintf(
						"This round is partial: %d of %d consulted members did not answer, so anything they would have contributed is not established here. %s",
						len(plan.missing), len(arr(run["contributions"])), joinLines(plan.missing))),
					"citations": []any{},
				})
				synthesis["claims"] = claims
			}
			if strings.TrimSpace(str(synthesis["text"])) == "" {
				// A complete contribution must carry text, and the chair
				// answering with nothing is a failure of the round, not a
				// record to store.
				run["status"] = "partial"
				run["failure"] = map[string]any{
					"code":      CodeModelError,
					"message":   "The chair returned an empty answer, so the round has member contributions but no synthesis.",
					"retryable": true,
				}
				break
			}
			run["synthesis"] = synthesis
			if len(plan.missing) > 0 {
				run["status"] = "partial"
				run["failure"] = map[string]any{
					"code":      worstCode(run),
					"message":   truncateMessage("The round was synthesised without every member. " + joinLines(plan.missing)),
					"retryable": true,
				}
			} else {
				run["status"] = "complete"
				delete(run, "failure")
			}
		}

		session["status"] = contract.DeriveSessionStatus(session)
		bumpSession(session)
		return nil
	})
	if f != nil && f != unchanged {
		s.failResult(sessionID, runID, f)
	}
}

func failureRecord(f *Failure) map[string]any {
	return map[string]any{
		"code":      f.Code,
		"message":   truncateMessage(f.Message),
		"retryable": f.Retryable,
	}
}

// truncateClaim keeps the engine's own claim inside the schema's ceiling for
// claim text.
func truncateClaim(text string) string {
	if len(text) <= contract.ClaimTextLimit {
		return text
	}
	return text[:contract.ClaimTextLimit-3] + "..."
}
