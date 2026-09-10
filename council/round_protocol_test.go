package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ipeerbhai/plugins/council/internal/contract"
	"github.com/ipeerbhai/plugins/council/internal/session"
)

// fakeModel is the double for most of this test, and it stands in for exactly
// one thing: a live model, which is nondeterministic, costs money, and is not
// present under `go test`. Everything on this side of it — the protocol loop,
// the tool registry, the command engine, the schemas, the invariants, the round
// driver, the prompt builder and the reply reader — is the shipped code, and
// the last section replaces even this one with the real stdio adapter answered
// by a canned host reply.
//
// It is also the instrument. Because every call passes through it, the test can
// assert on what each member was actually sent, how many calls a round cost,
// and how many were in flight at once; none of those are observable from the
// record afterwards, and all of them are properties the round is supposed to
// have.
type fakeModel struct {
	mu       sync.Mutex
	calls    []session.ModelCall
	inFlight int
	peak     int

	// reply answers one call. Each section of the test installs its own. It
	// takes the context so a section can decide whether to honour it: a member
	// that times out honours it, and a reply already in flight at the host when
	// the user cancels deliberately does not.
	reply func(ctx context.Context, call session.ModelCall) (session.ModelReply, error)

	// holdUntil makes a call wait until this many are in flight at once, so the
	// concurrency limit is measured rather than assumed. The wait is bounded:
	// a round that is less concurrent than expected fails on the peak
	// assertion, it does not hang the suite.
	holdUntil int
}

func (f *fakeModel) Generate(ctx context.Context, call session.ModelCall) (session.ModelReply, error) {
	f.mu.Lock()
	f.calls = append(f.calls, call)
	f.inFlight++
	if f.inFlight > f.peak {
		f.peak = f.inFlight
	}
	hold := f.holdUntil
	answer := f.reply
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		f.inFlight--
		f.mu.Unlock()
	}()

	// Only the member calls are held. The chair runs alone after them, and
	// making it wait for company it can never have would just be a delay.
	deadline := time.Now().Add(2 * time.Second)
	for hold > 1 && call.Role == "advisor" {
		f.mu.Lock()
		reached := f.inFlight >= hold
		f.mu.Unlock()
		if reached || time.Now().After(deadline) {
			break
		}
		time.Sleep(time.Millisecond)
	}
	return answer(ctx, call)
}

// configure installs a section's reply function and resets the instrument, so
// each section counts only its own calls.
func (f *fakeModel) configure(holdUntil int, reply func(ctx context.Context, call session.ModelCall) (session.ModelReply, error)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = nil
	f.peak = 0
	f.holdUntil = holdUntil
	f.reply = reply
}

func (f *fakeModel) recorded() ([]session.ModelCall, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]session.ModelCall{}, f.calls...), f.peak
}

// rested fails unless the run reached a resting state inside the command's own
// wait. run.start and run.retry answer within wait_seconds and a round that
// outruns that keeps going in the background, so every assertion that counts
// the fake's calls or reads a contribution has to know the round finished —
// otherwise it is reading a record that is still moving, and it fails as a
// puzzling count rather than as the thing that went wrong.
func rested(t *testing.T, payload map[string]any) map[string]any {
	t.Helper()
	switch status, _ := payload["status"].(string); status {
	case "pending", "running":
		t.Fatalf("the round had not finished when the command answered, so nothing below it can be read: %v", payload)
	}
	return payload
}

// callTo returns the single recorded call for one seat, failing if there is not
// exactly one: "the follow-up reached the right member" is only true if it also
// reached nobody else.
func callTo(t *testing.T, calls []session.ModelCall, seatID string) session.ModelCall {
	t.Helper()
	var found []session.ModelCall
	for _, call := range calls {
		if call.SeatID == seatID {
			found = append(found, call)
		}
	}
	if len(found) != 1 {
		t.Fatalf("expected exactly one call to %s, got %d", seatID, len(found))
	}
	return found[0]
}

// modelAnswer renders a reply in the shape the engine asks members for.
func modelAnswer(answer string, claims ...map[string]any) string {
	if claims == nil {
		claims = []map[string]any{}
	}
	raw, err := json.Marshal(map[string]any{"answer": answer, "claims": claims})
	if err != nil {
		panic(err)
	}
	return string(raw)
}

func sourceClaim(text, sourceID string, revision int, anchorID string) map[string]any {
	return map[string]any{
		"support": "source",
		"text":    text,
		"citations": []map[string]any{
			{"source_id": sourceID, "source_revision": revision, "anchor_id": anchorID},
		},
	}
}

// The tokens below appear in exactly one member's answer each. They are the
// isolation oracle: if one shows up in another member's prompt, that member was
// shown work it must not have seen.
const (
	costingToken  = "COSTING-ANSWER-9f2a"
	capacityToken = "CAPACITY-ANSWER-31c7"
)

// TestBoundedRoundDrivenByAFakeHost is the engine's wide test. It drives real
// protocol envelopes into the real backend over a real stdio pipe, with the
// model calls answered by the instrument above, and asserts the properties a
// bounded round is supposed to have.
//
// Oracles, stated per section, none of them a golden string:
//   - what each member was sent, recorded by the fake, checked for the shared
//     context, its own grounding, and the ABSENCE of every other member's text;
//   - the fake's call count, which is what "bounded" and "nothing loops" mean;
//   - the fake's peak concurrency, against the council's own limit;
//   - the run record read back through the protocol, validated against
//     session.schema.json and its invariants on every commit by the engine
//     itself, so a shape this test does not check is still not permitted;
//   - for the partial round, the engine's own labelling claim, which the model
//     did not write and cannot omit;
//   - for the superseded round, byte equality of the exported snapshot against
//     the document that replaced it.
func TestBoundedRoundDrivenByAFakeHost(t *testing.T) {
	schemas, err := contract.LoadRegistry()
	if err != nil {
		t.Fatalf("load schemas: %v", err)
	}
	store, err := session.New()
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	store.SetClock(func() string { return time.Date(2026, 9, 8, 12, 0, 0, 0, time.UTC).Format("2006-01-02T15:04:05Z") })
	models := &fakeModel{reply: func(context.Context, session.ModelCall) (session.ModelReply, error) {
		return session.ModelReply{}, fmt.Errorf("no reply configured for this section")
	}}
	store.SetChatHost(models)

	host := newFakeHost(t, store)
	host.rpc(1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	host.notify("notifications/initialized")

	// The protocol loop answers several requests at once now, so this test
	// issues some of them concurrently and the id counter is shared.
	var ids sync.Mutex
	id := 1
	nextID := func() int {
		ids.Lock()
		defer ids.Unlock()
		id++
		return id
	}
	commandWaiting := func(name string, payload map[string]any, waitSeconds int) map[string]any {
		t.Helper()
		id := nextID()
		args := map[string]any{
			"request_id": fmt.Sprintf("r-%d-%s", id, name),
			"command":    name,
			"payload":    payload,
		}
		if waitSeconds > 0 {
			args["wait_seconds"] = waitSeconds
		}
		switch name {
		case "snapshot.get", "source.fetch", "definition.export", "run.await":
		default:
			args["base_revision"] = store.Revision()
		}
		return host.command(id, schemas, args)
	}
	command := func(name string, payload map[string]any) map[string]any {
		t.Helper()
		return commandWaiting(name, payload, 0)
	}

	// --- the council: the shipped populated document ----------------------
	// Using the fixture the live check opens means the engine is exercised
	// against the same council a person will see, and a fixture that stopped
	// being loadable would fail here.
	var populated map[string]any
	if err := json.Unmarshal(readFixture(t, "workshop_complete.mcouncil"), &populated); err != nil {
		t.Fatal(err)
	}
	if _, isError := host.call(nextID(), "minerva_council_load_snapshot", map[string]any{"snapshot": populated}); isError {
		t.Fatal("the populated fixture did not load")
	}

	// A human seat is added before any session is created, so the session's own
	// embedded snapshot holds it. The human member is the local user: nothing
	// prompts them, and the bench must not include them.
	definition := deepCopyJSON(t, populated["definitions"].([]any)[0].(map[string]any))
	definition["definition_revision"] = definition["definition_revision"].(float64) + 1
	definition["members"] = append(definition["members"].([]any), map[string]any{
		"member_id":       "mem-operator",
		"member_revision": float64(1),
		"kind":            "human",
		"display_name":    "Operator (you)",
		"scope":           "The local user, contributing observed facts about the actual shop.",
		"limitations":     "Cannot speak for the customer.",
		"grounding":       []any{},
	})
	definition["seats"] = append(definition["seats"].([]any), map[string]any{
		"seat_id":        "seat-observed",
		"member_id":      "mem-operator",
		"responsibility": "Supply observed facts about the shop.",
		"role":           "advisor",
	})
	payloadOf(t, command("definition.upsert", map[string]any{"definition": definition}))

	const question = "Should the workshop take the recurring 40-unit order at 0.7x price?"
	const selectedContext = "Observed: the bench cleared 52 units last month and 31 in the week the jig was re-set."
	payloadOf(t, command("session.create", map[string]any{
		"session_id":    "ses-engine",
		"definition_id": "def-workshop-economics",
		"question":      question,
		"chat_id":       "chat-engine",
		"context_snapshot": map[string]any{
			"content_type": "text/plain",
			"byte_length":  len(selectedContext),
			"content_hash": sha256Of(selectedContext),
			"inline":       selectedContext,
		},
	}))

	// A seat held by the local user is not a seat a model answers for. Naming
	// one is refused, and the default bench leaves it out — which is what the
	// call count in section 1 measures: three advisor seats, two model calls.
	humanSeat := command("run.start", map[string]any{
		"session_id": "ses-engine",
		"seat_ids":   []any{"seat-observed"},
	})
	refusalSaying(t, humanSeat, "held by a human member")

	// -------------------------------------------------------------------
	// 1. An independent initial round
	//
	// Oracle: the prompts the fake recorded. Each advisor must have the shared
	// context and its OWN grounding, and neither the other advisor's answer nor
	// the contributions already stored in the fixture's other session. The
	// chair, and only the chair, sees both answers.
	// -------------------------------------------------------------------
	models.configure(2, func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		switch call.SeatID {
		case "seat-costing":
			return session.ModelReply{
				ModelID: "fake-model-a", PromptTokens: 900, CompletionTokens: 120, UsageReported: true,
				Text: modelAnswer(costingToken+": at 0.7x the order earns 28 units of revenue for 40 units of bench time.",
					map[string]any{"support": "inference", "text": "The order costs twelve units of margin a month."},
					map[string]any{"support": "unknown", "text": "Whether the freed hours have a better use is not established."}),
			}, nil
		case "seat-capacity":
			return session.ModelReply{
				ModelID: "fake-model-b", PromptTokens: 1400, CompletionTokens: 200, UsageReported: true,
				Text: modelAnswer(capacityToken+": price it against the worst week and as the sale of the right to refuse.",
					sourceClaim("A recurring order removes the freedom to decline work.",
						"src-capacity-essay", 2, "anc-freedom"),
					// A citation to an anchor this member IS grounded in.
					sourceClaim("Capacity is what the hard week clears.",
						"src-capacity-letter", 1, "anc-hard-week")),
			}, nil
		case "seat-chair":
			return session.ModelReply{
				ModelID: "fake-model-chair", PromptTokens: 3000, CompletionTokens: 300, UsageReported: true,
				Text: modelAnswer("The two members disagree about which number describes the bench.",
					map[string]any{"support": "inference", "text": "Costing reads capacity as the month's total; capacity reads it as the worst week."}),
			}, nil
		}
		return session.ModelReply{}, fmt.Errorf("unexpected seat %q", call.SeatID)
	})

	first := rested(t, payloadOf(t, command("run.start", map[string]any{"session_id": "ses-engine"})))
	calls, peak := models.recorded()

	if len(calls) != 3 {
		t.Fatalf("a two-advisor round plus the chair is three calls, the fake saw %d", len(calls))
	}
	if peak != 2 {
		t.Fatalf("this council allows two concurrent members and there were two to ask; peak in flight was %d", peak)
	}
	costing := callTo(t, calls, "seat-costing")
	capacity := callTo(t, calls, "seat-capacity")
	chair := callTo(t, calls, "seat-chair")

	for _, call := range []session.ModelCall{costing, capacity} {
		whole := call.System + "\n" + call.User
		if !strings.Contains(whole, question) {
			t.Fatalf("%s was not sent the question", call.SeatID)
		}
		if !strings.Contains(whole, selectedContext) {
			t.Fatalf("%s was not sent the selected context snapshot", call.SeatID)
		}
		if strings.Contains(whole, costingToken) && call.SeatID != "seat-costing" {
			t.Fatalf("%s was shown another member's answer", call.SeatID)
		}
		if strings.Contains(whole, capacityToken) && call.SeatID != "seat-capacity" {
			t.Fatalf("%s was shown another member's answer", call.SeatID)
		}
		// The fixture's other session holds finished contributions. None of
		// them belongs in this round's prompts either.
		if strings.Contains(whole, "worst week, not the average one") {
			t.Fatalf("%s was shown a contribution from another session", call.SeatID)
		}
	}
	// Grounding is per member and pinned. The simulant gets the captured essay;
	// the functional advisor, which is grounded in nothing, gets no source at all.
	if !strings.Contains(capacity.User, "removal of the freedom to say no") {
		t.Fatal("the simulant was not sent the material it is grounded in")
	}
	if strings.Contains(costing.User, "removal of the freedom to say no") {
		t.Fatal("a member grounded in nothing was sent somebody else's source")
	}
	if !strings.Contains(chair.User, costingToken) || !strings.Contains(chair.User, capacityToken) {
		t.Fatal("the chair must read every answer it is synthesising")
	}
	if !strings.Contains(chair.System, "Do not resolve it into a single voice") {
		t.Fatal("this council preserves disagreement and the chair was not told so")
	}

	// The record: statuses, attribution, usage, and the citations that survived.
	if got, _ := first["status"].(string); got != "complete" {
		t.Fatalf("every member answered and the chair spoke, so the run is complete; got %q", got)
	}
	if got, _ := first["session_status"].(string); got != "complete" {
		t.Fatalf("the session status is derived from the run set; got %q", got)
	}
	synthesis, _ := first["synthesis"].(map[string]any)
	if synthesis == nil {
		t.Fatal("a complete run carries the chair's synthesis")
	}
	if got, _ := synthesis["model_id"].(string); got != "fake-model-chair" {
		t.Fatalf("the synthesis must be attributed to the model that produced it, got %q", got)
	}
	for _, raw := range first["contributions"].([]any) {
		entry := raw.(map[string]any)
		if got, _ := entry["status"].(string); got != "complete" {
			t.Fatalf("%v did not complete: %v", entry["seat_id"], entry)
		}
		usage, _ := entry["usage"].(map[string]any)
		if usage == nil {
			t.Fatalf("%v recorded no usage, but the host reported it", entry["seat_id"])
		}
		if entry["seat_id"] == "seat-capacity" {
			if got, _ := usage["prompt_tokens"].(float64); int(got) != 1400 {
				t.Fatalf("usage was not recorded as the host reported it: %v", usage)
			}
			if got, _ := entry["model_id"].(string); got != "fake-model-b" {
				t.Fatalf("the answer is attributed to %q, not the model that produced it", got)
			}
		}
	}

	// A round narrowed to one concurrent member proves the ceiling rather than
	// only that concurrency happens at all: two seats are consulted and the
	// fake must never see both at once.
	models.configure(1, func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		return session.ModelReply{ModelID: "fake-model-a", Text: modelAnswer("One at a time.")}, nil
	})
	rested(t, payloadOf(t, command("run.start", map[string]any{
		"session_id": "ses-engine",
		"limits":     map[string]any{"max_concurrent_members": 1},
	})))
	if calls, peak := models.recorded(); peak != 1 {
		t.Fatalf("a round narrowed to one concurrent member reached %d in flight over %d calls", peak, len(calls))
	}

	// -------------------------------------------------------------------
	// 2. A follow-up aimed at one argument
	//
	// Oracle: the claim id comes out of the record just written, and the fake
	// must record exactly one member call — to the seat that made that claim —
	// whose prompt quotes it.
	// -------------------------------------------------------------------
	snapshot := payloadOf(t, command("snapshot.get", map[string]any{}))["snapshot"].(map[string]any)
	claimID, claimText := firstSourceClaim(t, snapshot, "ses-engine", "seat-capacity")

	models.configure(1, func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		return session.ModelReply{ModelID: "fake-model-b", Text: modelAnswer("A premium of about a third would buy the refusals back.")}, nil
	})
	followUp := rested(t, payloadOf(t, command("run.start", map[string]any{
		"session_id":         "ses-engine",
		"addressed_claim_id": claimID,
		"prompt":             "What premium would buy those refusals back?",
	})))
	calls, _ = models.recorded()
	if len(calls) != 2 {
		t.Fatalf("a follow-up to one member is one member call plus the chair, the fake saw %d", len(calls))
	}
	addressed := callTo(t, calls, "seat-capacity")
	if !strings.Contains(addressed.User, claimText) {
		t.Fatal("the follow-up did not quote the argument it was about")
	}
	if !strings.Contains(addressed.User, "What premium would buy those refusals back?") {
		t.Fatal("the follow-up did not carry the focused question")
	}
	if got, _ := followUp["kind"].(string); got != "follow_up" {
		t.Fatalf("naming a claim makes the run a follow-up, got %q", got)
	}

	// A follow-up that names a claim AND the wrong seat is refused rather than
	// asking one member to answer for another's reasoning.
	misrouted := command("run.start", map[string]any{
		"session_id":         "ses-engine",
		"addressed_claim_id": claimID,
		"addressed_seat_id":  "seat-costing",
	})
	refusalSaying(t, misrouted, "is answered by the member that made it")

	// -------------------------------------------------------------------
	// 3. One member times out, and the round is still useful
	//
	// Oracle: the timed-out seat's failure code, the run's own status, and the
	// engine's labelling claim on the synthesis — which the chair's reply does
	// not contain, so a model cannot leave it out.
	// -------------------------------------------------------------------
	// The timeout is the engine's, not the fake's: the run narrows the
	// per-member limit to one second and this seat simply waits for the
	// deadline the engine set.
	models.configure(1, func(ctx context.Context, call session.ModelCall) (session.ModelReply, error) {
		if call.SeatID == "seat-capacity" {
			<-ctx.Done()
			return session.ModelReply{}, ctx.Err()
		}
		return session.ModelReply{ModelID: "fake-model-a", Text: modelAnswer("Only the arithmetic, then.")}, nil
	})
	partial := rested(t, payloadOf(t, command("run.start", map[string]any{
		"session_id": "ses-engine",
		"limits":     map[string]any{"per_member_timeout_seconds": 1},
	})))
	if got, _ := partial["status"].(string); got != "partial" {
		t.Fatalf("a round that lost a member is partial, got %q: %v", got, partial)
	}
	if got, _ := partial["failure"].(map[string]any)["code"].(string); got != session.CodeTimeout {
		t.Fatalf("the run's failure must name the timeout, got %v", partial["failure"])
	}
	partialSynthesis, _ := partial["synthesis"].(map[string]any)
	if partialSynthesis == nil {
		t.Fatal("a partial round still synthesises what it has; that is the point of it")
	}
	labelled := false
	for _, raw := range partialSynthesis["claims"].([]any) {
		claim := raw.(map[string]any)
		text, _ := claim["text"].(string)
		if claim["support"] == "unknown" && strings.Contains(text, "This round is partial") && strings.Contains(text, "seat-capacity") {
			labelled = true
		}
	}
	if !labelled {
		t.Fatalf("the engine must label a partial round and name the seat that is missing: %v", partialSynthesis["claims"])
	}
	partialRunID, _ := partial["run_id"].(string)

	// -------------------------------------------------------------------
	// 4. Retrying just the member that failed
	//
	// Oracle: the fake's calls. A retry narrowed to one seat consults that seat
	// and nobody else — a round that lost one member must not be paid for twice
	// over — and the seats that answered are never re-asked.
	// -------------------------------------------------------------------
	models.configure(1, func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		return session.ModelReply{ModelID: "fake-model-b", Text: modelAnswer("Answering on the second ask.")}, nil
	})
	retried := rested(t, payloadOf(t, command("run.retry", map[string]any{
		"session_id": "ses-engine",
		"run_id":     partialRunID,
		"seat_ids":   []any{"seat-capacity"},
	})))
	if got, _ := retried["status"].(string); got != "complete" {
		t.Fatalf("the retried seat answered, so the retry is complete; got %q: %v", got, retried)
	}
	calls, _ = models.recorded()
	if len(calls) != 2 {
		t.Fatalf("a retry of one seat is one member call plus the chair, the fake saw %d", len(calls))
	}
	callTo(t, calls, "seat-capacity")
	for _, call := range calls {
		if call.SeatID == "seat-costing" {
			t.Fatal("a retry re-asked a member that had already answered")
		}
	}
	// A retry that names a seat which DID answer is refused rather than
	// quietly spending on it again.
	answered := command("run.retry", map[string]any{
		"session_id": "ses-engine",
		"run_id":     partialRunID,
		"seat_ids":   []any{"seat-costing"},
	})
	refusalSaying(t, answered, "a retry only re-asks the seats that did not")

	// run.await on a run that is already at rest answers immediately with what
	// it produced, rather than waiting out its timeout.
	awaited := payloadOf(t, command("run.await", map[string]any{
		"session_id": "ses-engine",
		"run_id":     retried["run_id"].(string),
	}))
	if resting, _ := awaited["resting"].(bool); !resting {
		t.Fatalf("run.await must report a finished run as resting: %v", awaited)
	}

	// -------------------------------------------------------------------
	// 5. Cancellation, and the reply that arrives afterwards
	//
	// This goes through the real loop, over the real pipe. The host runs any
	// number of requests at once and so does the backend now: run.start is a
	// long tools/call, and run.cancel is another arriving while it is still
	// running. That interleaving IS the thing under test.
	//
	// Oracles: an ordinary read answered mid-round (so the round is provably
	// not blocking the loop); the run's status and the contribution's. The late
	// reply is recorded 'stale' with full attribution, per the state model, and
	// changes nothing else — no synthesis appears and the run stays cancelled.
	// -------------------------------------------------------------------
	release := make(chan struct{})
	entered := make(chan struct{})
	var once sync.Once
	models.configure(1, func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		once.Do(func() { close(entered) })
		// Deliberately ignores the context: this is a reply already in flight
		// at the host when the user cancels, which is the case the suppression
		// rule exists for.
		<-release
		return session.ModelReply{ModelID: "fake-model-b", Text: modelAnswer("A late answer nobody is waiting for.")}, nil
	})

	startReply := make(chan map[string]any, 1)
	go func() {
		startReply <- command("run.start", map[string]any{
			"session_id":        "ses-engine",
			"kind":              "follow_up",
			"addressed_seat_id": "seat-capacity",
			"prompt":            "One more thing.",
		})
	}()
	<-entered

	// A read, answered while the round is still running. Before the loop
	// dispatched handlers concurrently this could not have been answered at
	// all, and everything below it would have deadlocked.
	midRound := payloadOf(t, command("snapshot.get", map[string]any{}))
	if midRound["snapshot"] == nil {
		t.Fatal("a read arriving mid-round must be answered")
	}

	// run.await on a round that has NOT finished must say so. It is the same
	// question the record answers — "is this run going anywhere" — and answering
	// it from the engine's live handle instead would report a run that has been
	// committed but not yet planned as already at rest.
	liveRunID := runningRunID(t, store, "ses-engine")
	stillGoing := payloadOf(t, commandWaiting("run.await", map[string]any{
		"session_id": "ses-engine",
		"run_id":     liveRunID,
	}, 1))
	if resting, _ := stillGoing["resting"].(bool); resting {
		t.Fatalf("a run that has not finished is not resting: %v", stillGoing)
	}
	if got, _ := stillGoing["status"].(string); got != "running" {
		t.Fatalf("the run under way must read running, got %q", got)
	}

	cancelled := payloadOf(t, command("run.cancel", map[string]any{
		"session_id": "ses-engine",
		"run_id":     liveRunID,
	}))
	if got, _ := cancelled["status"].(string); got != "cancelled" {
		t.Fatalf("run.cancel: %v", cancelled)
	}
	close(release)
	finished := <-startReply
	if ok, _ := finished["ok"].(bool); !ok {
		t.Fatalf("run.start must still answer after its run was cancelled: %v", finished["error"])
	}
	finishedPayload := rested(t, payloadOf(t, finished))
	if got, _ := finishedPayload["status"].(string); got != "cancelled" {
		t.Fatalf("a cancelled run stays cancelled, got %q", got)
	}
	if _, present := finishedPayload["synthesis"]; present {
		t.Fatal("a cancelled round must not be synthesised")
	}
	// The late reply lands AFTER run.start answered: cancelling put the run at
	// rest, so the command that started it stopped waiting there. run.await
	// would answer just as promptly and for the same reason, so the arrival is
	// waited for against the record itself.
	cancelledRunID := finishedPayload["run_id"].(string)
	late := awaitContribution(t, store, "ses-engine", cancelledRunID, "stale")
	if text, _ := late["text"].(string); text == "" {
		t.Fatal("a stale contribution is recorded with full attribution, text included")
	}
	afterLate := payloadOf(t, command("run.await", map[string]any{
		"session_id": "ses-engine",
		"run_id":     cancelledRunID,
	}))
	if got, _ := afterLate["status"].(string); got != "cancelled" {
		t.Fatalf("a late reply must not move the run, got %q", got)
	}
	if _, present := afterLate["synthesis"]; present {
		t.Fatal("a late reply must not produce a synthesis for a cancelled round")
	}
	if got, _ := afterLate["session_status"].(string); got != "cancelled" {
		t.Fatalf("the session follows its last run, got %q", got)
	}

	// -------------------------------------------------------------------
	// 6. A superseded generation cannot touch the document that replaced it
	//
	// Oracle: byte equality. The snapshot the engine holds after the late reply
	// lands must be exactly the document that was loaded over the run, with the
	// reply nowhere in it.
	// -------------------------------------------------------------------
	release = make(chan struct{})
	entered = make(chan struct{})
	var onceAgain sync.Once
	models.configure(1, func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		onceAgain.Do(func() { close(entered) })
		<-release
		return session.ModelReply{ModelID: "fake-model-b", Text: modelAnswer("An answer for a document that is gone.")}, nil
	})
	supersededReply := make(chan map[string]any, 1)
	go func() {
		supersededReply <- command("run.start", map[string]any{
			"session_id":        "ses-engine",
			"kind":              "follow_up",
			"addressed_seat_id": "seat-capacity",
			"prompt":            "And another.",
		})
	}()
	<-entered
	replacedWhileRunning, isError := host.call(nextID(), "minerva_council_load_snapshot", map[string]any{"snapshot": populated})
	if isError {
		t.Fatalf("load while a run was in flight: %v", replacedWhileRunning)
	}
	close(release)
	abandoned := <-supersededReply
	if ok, _ := abandoned["ok"].(bool); ok {
		t.Fatalf("a run whose document was replaced has no outcome to report: %v", abandoned["payload"])
	}
	exported, isError := host.call(nextID(), "minerva_council_export_snapshot", map[string]any{})
	if isError {
		t.Fatalf("export: %v", exported)
	}
	if !reflect.DeepEqual(exported["snapshot"], any(populated)) {
		t.Fatal("a reply from a superseded run changed the document that replaced it")
	}

	// -------------------------------------------------------------------
	// 7. Nothing resumes, and nothing loops
	//
	// Oracle: the fake's call count across a load of an interrupted document.
	// A run that was in flight when the process went away must produce a
	// visible failure and not one single model call.
	//
	// This is a negative assertion over a window, and the window is a 100 ms
	// sleep. It cannot prove that nothing will ever start; it proves that
	// nothing starts promptly, which is what a resumption would do — the
	// interruption rule runs inside Load. A resume introduced on a timer longer
	// than this would slip past it.
	// -------------------------------------------------------------------
	models.configure(1, func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		t.Errorf("a restored document consulted %s on its own", call.SeatID)
		return session.ModelReply{}, fmt.Errorf("should not happen")
	})
	interrupted := interruptedCopy(t, populated)
	restored, isError := host.call(nextID(), "minerva_council_load_snapshot", map[string]any{"snapshot": interrupted})
	if isError {
		t.Fatalf("load an interrupted document: %v", restored)
	}
	if demoted, _ := restored["runs_demoted"].(float64); demoted != 1 {
		t.Fatalf("the in-flight run must be demoted, got runs_demoted=%v", restored["runs_demoted"])
	}
	time.Sleep(100 * time.Millisecond)
	if calls, _ := models.recorded(); len(calls) != 0 {
		t.Fatalf("a restored document must spend nothing on its own; the fake saw %d calls", len(calls))
	}

	// -------------------------------------------------------------------
	// 8. The limits are the council's, and a run may only narrow them
	//
	// Oracle: the refusal messages, and the fact that no call is made.
	// -------------------------------------------------------------------
	models.configure(1, func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		t.Errorf("a refused run consulted %s", call.SeatID)
		return session.ModelReply{}, fmt.Errorf("should not happen")
	})
	widened := command("run.start", map[string]any{
		"session_id": "ses-recurring-order",
		"limits":     map[string]any{"run_budget_seconds": 9000},
	})
	refusalSaying(t, widened, "may narrow a limit and never widen it")
	unknownLimit := command("run.start", map[string]any{
		"session_id": "ses-recurring-order",
		"limits":     map[string]any{"max_thinking": 3},
	})
	refusalSaying(t, unknownLimit, "is not one this council has")
	human := command("run.start", map[string]any{
		"session_id": "ses-recurring-order",
		"seat_ids":   []any{"seat-chair"},
	})
	refusalSaying(t, human, "the chair synthesises the round")
	if calls, _ := models.recorded(); len(calls) != 0 {
		t.Fatalf("a refused run must consult nobody; the fake saw %d calls", len(calls))
	}

	// -------------------------------------------------------------------
	// 9. A round that outruns its wait, read with run.await
	//
	// This is the half of the transport ruling nothing above reaches. Every
	// section so far used the default wait and the round finished inside it, so
	// run.start could be read as "blocks until done". It is not: it answers
	// within wait_seconds and the round keeps going behind it, which is what
	// keeps a long council under the host's own 120 s call_tool budget.
	//
	// Oracles, all of them read from the record rather than from timing:
	//   - run.start's own reply, which must say the run is still going;
	//   - run.await's resting flag, false while the round is in flight and true
	//     once it is not, with the finished contributions and the synthesis in
	//     the same payload;
	//   - the fake's call count across the whole section, which is what makes
	//     "the reply came back early" different from "a second round started";
	//   - the refusals, which are the classification: run.await is a READ, so a
	//     base_revision on it is refused the way one is on snapshot.get.
	//
	// It is also the re-entrancy proof. The await below is a second tools/call
	// arriving while the first round is executing; an adapter that answered
	// requests strictly in order would not answer it until the round ended, and
	// the resting:false assertion would fail as a timeout rather than pass.
	//
	// The members are held on a GATE rather than a sleep. A sleep would make
	// "the round is still going when the wait expires" a race between two
	// durations, and the test could then flake in either direction — green
	// because the machine was slow, red because it was fast. With a gate the
	// round provably cannot finish before the test opens it, so every assertion
	// below rests on the record and none of them rests on timing.
	// -------------------------------------------------------------------
	slowRelease := make(chan struct{})
	models.configure(2, func(ctx context.Context, _ session.ModelCall) (session.ModelReply, error) {
		// Honouring the context matters: a member that ignored cancellation
		// would outlive the test rather than fail it.
		select {
		case <-slowRelease:
		case <-ctx.Done():
			return session.ModelReply{}, ctx.Err()
		}
		return session.ModelReply{
			ModelID: "fake-model-slow", PromptTokens: 10, CompletionTokens: 4, UsageReported: true,
			Text: modelAnswer("Answered after the wait had already elapsed."),
		}, nil
	})

	slowStart := payloadOf(t, commandWaiting("run.start", map[string]any{"session_id": "ses-recurring-order"}, 1))
	slowRunID, _ := slowStart["run_id"].(string)
	if slowRunID == "" {
		t.Fatalf("run.start must name the run it set going even when it cannot report the answer: %v", slowStart)
	}
	switch status, _ := slowStart["status"].(string); status {
	case "pending", "running":
	default:
		t.Fatalf("no member can have answered while the gate is shut; run.start said %q", status)
	}

	// A read carries no base_revision. The engine classifies by command, so a
	// caller that sent one would be telling it this changes the document.
	refusalSaying(t, host.command(nextID(), schemas, map[string]any{
		"request_id":    "await-with-base",
		"command":       "run.await",
		"base_revision": store.Revision(),
		"payload":       map[string]any{"session_id": "ses-recurring-order", "run_id": slowRunID},
	}), "base_revision")

	// Still going, and saying so rather than waiting forever.
	watching := payloadOf(t, commandWaiting("run.await", map[string]any{
		"session_id": "ses-recurring-order", "run_id": slowRunID,
	}, 1))
	if resting, _ := watching["resting"].(bool); resting {
		t.Fatalf("run.await reported the round at rest while the members were still held: %v", watching)
	}

	// And now let go. The same command, given room, answers with the finished
	// round — which is what makes it a way to READ a run rather than a second
	// way to start one. The chair is behind the same gate, so opening it here
	// releases the whole remaining round.
	close(slowRelease)
	settled := payloadOf(t, commandWaiting("run.await", map[string]any{
		"session_id": "ses-recurring-order", "run_id": slowRunID,
	}, 10))
	if resting, _ := settled["resting"].(bool); !resting {
		t.Fatalf("run.await did not reach rest inside ten seconds: %v", settled)
	}
	if status, _ := settled["status"].(string); status != "complete" {
		t.Fatalf("the round finished as %q, not complete: %v", status, settled)
	}
	if settled["synthesis"] == nil {
		t.Error("a completed round read through run.await must carry the chair's synthesis")
	}
	for _, x := range settled["contributions"].([]any) {
		contribution, _ := x.(map[string]any)
		if status, _ := contribution["status"].(string); status != "complete" {
			t.Errorf("%v was left at %q by a round the await says is at rest", contribution["seat_id"], status)
		}
	}
	// Two advisors and the chair, once. A run.start that had restarted the
	// round when its wait expired, or an await that had started one of its own,
	// shows up here and nowhere else.
	if calls, _ := models.recorded(); len(calls) != 3 {
		t.Fatalf("the whole section is one round: two advisors and the chair, the fake saw %d calls", len(calls))
	}

	// A run the document does not hold is answered, not waited on: the caller
	// asking about a run that finished into a replaced document deserves a
	// reply rather than a timeout.
	refusalSaying(t, commandWaiting("run.await", map[string]any{
		"session_id": "ses-recurring-order", "run_id": "run-that-never-was",
	}, 1), "run-that-never-was")

	// -------------------------------------------------------------------
	// 10. The real adapter: a host that answers, and a host that does not
	//
	// Everything above answered through the fake. This section replaces it with
	// the shipped stdioChatHost, driven by the shipped reader, so the
	// capability wire format is exercised rather than assumed: the request goes
	// out as a real minerva/capability line, and the answer comes back as the
	// double-wrapped envelope CapabilityBroker builds — {"success": true,
	// "result": {…}} inside the JSON-RPC result.
	//
	// The adapter's streams are a separate pipe pair from the protocol pipe
	// above. In the backend they are one stdin and one stdout; separating them
	// here keeps the canned host answering capability calls without also having
	// to be a protocol peer. The reader, the routing and the adapter are the
	// real ones.
	// -------------------------------------------------------------------
	answers, answersIn := io.Pipe()
	requestsOut, requestsIn := io.Pipe()
	adapter := &stdioChatHost{}
	adapter.bind(&stdoutWriter{enc: json.NewEncoder(requestsIn)})
	adapterDone := make(chan struct{})
	defer close(adapterDone)
	// The reader is the shipped one, so the classification under test is the
	// production classification: a line with no method is a response and is
	// routed to the exchange waiting on its id.
	strays := readStdin(bufio.NewReader(answers), adapterDone, adapter)
	go func() {
		for range strays {
			t.Error("a capability reply was mistaken for a protocol request")
		}
	}()

	// The canned host: read each capability request and answer it with the id
	// it carried. Shape oracle: CapabilityBroker.gd's success reply, and
	// host.providers.chat's OpenAI-shaped body.
	const cannedText = "The canned host answered."
	go func() {
		dec := json.NewDecoder(requestsOut)
		for {
			var outgoing struct {
				ID     string `json:"id"`
				Method string `json:"method"`
			}
			if err := dec.Decode(&outgoing); err != nil {
				return
			}
			if outgoing.Method != "minerva/capability" {
				t.Errorf("the adapter sent %q, not a capability request", outgoing.Method)
				return
			}
			body, err := json.Marshal(map[string]any{
				"jsonrpc": "2.0",
				"id":      outgoing.ID,
				"result": map[string]any{
					"success": true,
					"result": map[string]any{
						"model": "m",
						"choices": []map[string]any{
							{"message": map[string]any{"content": modelAnswer(cannedText)}},
						},
						"usage": map[string]any{"prompt_tokens": 7, "completion_tokens": 3},
					},
				},
			})
			if err != nil {
				return
			}
			if _, err := answersIn.Write(append(body, '\n')); err != nil {
				return
			}
		}
	}()

	store.SetChatHost(adapter)
	cannedRun := rested(t, payloadOf(t, command("run.start", map[string]any{
		"session_id": "ses-recurring-order",
		"seat_ids":   []any{"seat-capacity"},
	})))
	if got, _ := cannedRun["status"].(string); got != "complete" {
		t.Fatalf("the canned host answered, so the run is complete; got %q: %v", got, cannedRun)
	}
	real := cannedRun["contributions"].([]any)[0].(map[string]any)
	if got, _ := real["model_id"].(string); got != "m" {
		t.Fatalf("model_id must come from the host's reply, got %q", got)
	}
	usage, _ := real["usage"].(map[string]any)
	if prompt, _ := usage["prompt_tokens"].(float64); int(prompt) != 7 {
		t.Fatalf("prompt_tokens must be recorded as the host reported them, got %v", usage)
	}
	if completion, _ := usage["completion_tokens"].(float64); int(completion) != 3 {
		t.Fatalf("completion_tokens must be recorded as the host reported them, got %v", usage)
	}
	synthesised, _ := cannedRun["synthesis"].(map[string]any)
	if text, _ := synthesised["text"].(string); text != cannedText {
		t.Fatalf("the answer text must survive the capability envelope, got %q", text)
	}

	// A host that accepts the call and goes quiet costs the member its timeout,
	// not the round. Before the reader was a goroutine routing by id, the
	// adapter was blocked inside a Read no context could reach, so the member's
	// timeout did not apply to the one call actually waiting.
	//
	// Dispatched on a goroutine and awaited with a deadline, because the failure
	// under test is a HANG: measuring elapsed time after the call returned would
	// only ever run in the passing case.
	silentAdapter := &stdioChatHost{}
	silentAdapter.bind(&stdoutWriter{enc: json.NewEncoder(io.Discard)})
	store.SetChatHost(silentAdapter)

	stalledReplies := make(chan map[string]any, 1)
	go func() {
		stalledReplies <- command("run.start", map[string]any{
			"session_id": "ses-recurring-order",
			"seat_ids":   []any{"seat-capacity"},
			"limits":     map[string]any{"per_member_timeout_seconds": 1},
		})
	}()
	var stalledRun map[string]any
	select {
	case reply := <-stalledReplies:
		stalledRun = rested(t, payloadOf(t, reply))
	case <-time.After(15 * time.Second):
		t.Fatal("a stalled host must cost the member its one-second timeout, not the round: run.start never returned")
	}
	stalledContribution := stalledRun["contributions"].([]any)[0].(map[string]any)
	if got, _ := stalledContribution["failure"].(map[string]any)["code"].(string); got != session.CodeTimeout {
		t.Fatalf("a host that never answers is a timeout against the seat, got %v", stalledContribution["failure"])
	}
	// The one seat consulted did not answer, so there is nothing to synthesise
	// and the RUN is failed. The SESSION reads partial, because members were
	// dispatched and earlier rounds stand — that is the derivation, not a
	// special case.
	if got, _ := stalledRun["status"].(string); got != "failed" {
		t.Fatalf("no member answered, so the run failed; got %q", got)
	}
	if got, _ := stalledRun["session_status"].(string); got != "partial" {
		t.Fatalf("the session reads partial once members have been dispatched; got %q", got)
	}
	// Abandoning an exchange costs nothing beyond that call: the adapter keeps
	// working, because a late reply finds no pending entry and is dropped.
	if _, err := silentAdapter.exchange(cancelledContext(), "host.providers.chat", map[string]any{}); err == nil {
		t.Fatal("an exchange on a cancelled context must not succeed")
	}
}

// cancelledContext is a context that has already expired, for asserting that a
// call which cannot proceed refuses rather than waits.
func cancelledContext() context.Context {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	return ctx
}

// firstSourceClaim returns the id and text of the first claim a seat argued in
// a session, so a follow-up can be aimed at a real argument rather than at an
// id the test invented.
func firstSourceClaim(t *testing.T, snapshot map[string]any, sessionID, seatID string) (string, string) {
	t.Helper()
	for _, s := range snapshot["sessions"].([]any) {
		record := s.(map[string]any)
		if record["session_id"] != sessionID {
			continue
		}
		for _, r := range record["runs"].([]any) {
			run := r.(map[string]any)
			for _, c := range run["contributions"].([]any) {
				contribution := c.(map[string]any)
				if contribution["seat_id"] != seatID {
					continue
				}
				for _, cl := range contribution["claims"].([]any) {
					claim := cl.(map[string]any)
					if claim["support"] == "source" {
						return claim["claim_id"].(string), claim["text"].(string)
					}
				}
			}
		}
	}
	t.Fatalf("no source claim by %s in %s", seatID, sessionID)
	return "", ""
}

// awaitContribution waits for one of a run's contributions to reach a status,
// reading the engine's own exported record. It exists because a late reply
// lands after the command that started the round has already answered: cancel
// puts the run at rest, so nothing that waits on the RUN can also be waiting on
// the reply still in flight behind it.
func awaitContribution(t *testing.T, store *session.Store, sessionID, runID, want string) map[string]any {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	var seen []string
	for time.Now().Before(deadline) {
		for _, s := range store.Export()["sessions"].([]any) {
			record := s.(map[string]any)
			if record["session_id"] != sessionID {
				continue
			}
			for _, r := range record["runs"].([]any) {
				run := r.(map[string]any)
				if run["run_id"] != runID {
					continue
				}
				seen = nil
				for _, c := range run["contributions"].([]any) {
					contribution := c.(map[string]any)
					status, _ := contribution["status"].(string)
					seen = append(seen, status)
					if status == want {
						return contribution
					}
				}
			}
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("no contribution of %s reached %q; statuses were %v", runID, want, seen)
	return nil
}

// runningRunID finds the run one session is currently executing, by reading the
// engine's own exported state rather than by guessing an id. It is scoped to a
// session for the same reason the engine's own handles are: a run id is unique
// within its session and two sessions can both hold a "run-1".
func runningRunID(t *testing.T, store *session.Store, sessionID string) string {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for _, s := range store.Status()["sessions"].([]any) {
			record := s.(map[string]any)
			if record["session_id"] != sessionID {
				continue
			}
			for _, r := range record["runs"].([]any) {
				run := r.(map[string]any)
				if run["status"] == "running" {
					return run["run_id"].(string)
				}
			}
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("no run in %s reached the running state", sessionID)
	return ""
}
