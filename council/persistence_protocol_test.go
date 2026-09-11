package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ipeerbhai/plugins/council/fixtures"
	"github.com/ipeerbhai/plugins/council/internal/contract"
	"github.com/ipeerbhai/plugins/council/internal/session"
)

// Persistence, migration and recovery, driven through the shipped protocol.
//
// This file is about what survives a process ending. Everything in the backend
// is process memory; the durable record is the snapshot the wrapper persists,
// and the seam between them is minerva_council_load_snapshot /
// minerva_council_export_snapshot. So every claim here is made by loading a
// document into a store and reading back what the engine then holds — never by
// reaching into engine state, which is exactly the state that does not survive.
//
// A "restart" in this file is a NEW session.Store with a NEW protocol loop and
// a NEW call counter. That is what a plugin restart leaves behind: nothing but
// the document.

// loadReportFor loads one snapshot through the real tool and returns the
// report, failing on a refusal — a load that was refused makes every assertion
// after it meaningless.
func loadReportFor(t *testing.T, host *fakeHost, id int, snapshot map[string]any) map[string]any {
	t.Helper()
	report, isError := host.call(id, "minerva_council_load_snapshot", map[string]any{"snapshot": snapshot})
	if isError {
		t.Fatalf("load was refused: %v", report)
	}
	return report
}

// reopenReportFor is the load the WRAPPER makes: a panel coming back to its own
// document. It is the only mode in which a later state already in the engine is
// recovered rather than replaced.
func reopenReportFor(t *testing.T, host *fakeHost, id int, snapshot map[string]any) map[string]any {
	t.Helper()
	report, isError := host.call(id, "minerva_council_load_snapshot", map[string]any{
		"snapshot": snapshot, "mode": "reopen"})
	if isError {
		t.Fatalf("reopen was refused: %v", report)
	}
	return report
}

func exportedSnapshot(t *testing.T, host *fakeHost, id int) map[string]any {
	t.Helper()
	exported, isError := host.call(id, "minerva_council_export_snapshot", map[string]any{})
	if isError {
		t.Fatalf("export: %v", exported)
	}
	snapshot, _ := exported["snapshot"].(map[string]any)
	if snapshot == nil {
		t.Fatalf("export carried no snapshot: %v", exported)
	}
	return snapshot
}

// runOf reads one run out of a snapshot by (session, run). Both ids are needed
// because a run id is only unique within its session.
func runOf(t *testing.T, snapshot map[string]any, sessionID, runID string) map[string]any {
	t.Helper()
	for _, s := range arrOf(snapshot["sessions"]) {
		record, _ := s.(map[string]any)
		if str(record["session_id"]) != sessionID {
			continue
		}
		for _, r := range arrOf(record["runs"]) {
			run, _ := r.(map[string]any)
			if str(run["run_id"]) == runID {
				return run
			}
		}
	}
	t.Fatalf("snapshot holds no run %q in session %q", runID, sessionID)
	return nil
}

func contributionStatuses(run map[string]any) map[string]string {
	statuses := map[string]string{}
	for _, c := range arrOf(run["contributions"]) {
		contribution, _ := c.(map[string]any)
		statuses[str(contribution["seat_id"])] = str(contribution["status"])
	}
	return statuses
}

func arrOf(v any) []any { a, _ := v.([]any); return a }

// newProjectID mints an identity for a document this test is standing up as a
// second project.
func newProjectID(t *testing.T) string {
	t.Helper()
	id, err := contract.NewProjectID()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// TestAnOlderDocumentIsMigratedOnFirstLoad is the migration acceptance test.
//
// Oracles, in order: the schema registry (the migrated document validates
// against today's council_project_snapshot, which the pre-migration one cannot);
// the load report, which names every step that rewrote the record; and the
// revision, which must move exactly once — a rewritten document is not the
// document that was handed in, and a document already current must load at its
// own revision or every reopen would dirty the project.
func TestAnOlderDocumentIsMigratedOnFirstLoad(t *testing.T) {
	schemas, err := contract.LoadRegistry()
	if err != nil {
		t.Fatal(err)
	}
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	host := newFakeHost(t, store)
	host.rpc(1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	host.notify("notifications/initialized")

	raw, err := fixtures.FS.ReadFile("migrations/snapshot_v0_pre_project_identity.json")
	if err != nil {
		t.Fatal(err)
	}
	var older map[string]any
	if err := json.Unmarshal(raw, &older); err != nil {
		t.Fatal(err)
	}

	// The control: this fixture is genuinely of an older shape. Without it a
	// migration that did nothing would pass everything below.
	if errs := schemas.ValidateRecord("council_project_snapshot", raw); len(errs) == 0 {
		t.Fatal("the migration fixture already satisfies today's schema, so it proves nothing")
	}
	if _, present := older["project_id"]; present {
		t.Fatal("the migration fixture already carries a project_id")
	}

	report := loadReportFor(t, host, 2, older)
	steps, _ := report["migrations"].([]any)
	if len(steps) != 2 {
		t.Fatalf("a v0 document without a project identity takes the ladder step and the fixup; the report named %v", report["migrations"])
	}
	if id := str(report["project_id"]); !strings.HasPrefix(id, "prj-") {
		t.Fatalf("the load report must name the identity that was minted, got %q", id)
	}

	migrated := exportedSnapshot(t, host, 3)
	encoded, err := json.Marshal(migrated)
	if err != nil {
		t.Fatal(err)
	}
	if errs := schemas.ValidateRecord("council_project_snapshot", encoded); len(errs) > 0 {
		t.Fatalf("the migrated document does not satisfy the contract:\n  %s", strings.Join(errs, "\n  "))
	}
	if got, want := int(numOf(migrated["snapshot_revision"])), int(numOf(older["snapshot_revision"]))+1; got != want {
		t.Fatalf("a rewritten document takes a new revision: got %d, wanted %d", got, want)
	}
	// Every nested record carries its own schema_version, and a document is only
	// migrated when all of them are: a session left at 0 would be refused by the
	// first command that revalidated it.
	for _, s := range arrOf(migrated["sessions"]) {
		if v := int(numOf(s.(map[string]any)["schema_version"])); v != contract.SnapshotSchemaVersion {
			t.Fatalf("a session came out of the migration at schema_version %d", v)
		}
	}

	// Loading the migrated form again is a no-op: no steps, no revision move,
	// and the SAME identity. An identity that were re-minted on each load would
	// make every reopen look like a different project to the chat router.
	second := loadReportFor(t, host, 4, migrated)
	if steps, _ := second["migrations"].([]any); len(steps) != 0 {
		t.Fatalf("a current document must migrate nothing, the report named %v", second["migrations"])
	}
	if got := int(numOf(second["snapshot_revision"])); got != int(numOf(migrated["snapshot_revision"])) {
		t.Fatalf("a document that was not rewritten must load at its own revision: %d vs %d",
			got, int(numOf(migrated["snapshot_revision"])))
	}
	if str(second["project_id"]) != str(migrated["project_id"]) {
		t.Fatalf("the project identity moved on reload: %q then %q",
			str(migrated["project_id"]), str(second["project_id"]))
	}

	// A document from a version this build does not have is refused, not
	// guessed at. The oracle is the refusal itself: nothing is loaded.
	newer := deepCopyJSON(t, migrated)
	newer["schema_version"] = float64(contract.SnapshotSchemaVersion + 1)
	refused, isError := host.call(5, "minerva_council_load_snapshot", map[string]any{"snapshot": newer})
	if !isError {
		t.Fatalf("a document from a newer schema must be refused, the load answered %v", refused)
	}
	if held := exportedSnapshot(t, host, 6); str(held["project_id"]) != str(migrated["project_id"]) {
		t.Fatal("a refused load replaced the document the engine was holding")
	}
}

func numOf(v any) float64 { f, _ := v.(float64); return f }

// TestSavedMidRunDocumentContinuesWithoutDuplicateCalls is the T09 acceptance
// path: save during a partial run, restart the backend, reopen, then continue
// explicitly — and spend nothing twice.
//
// Oracle: the fake host's recorded calls, which is the only place a duplicate
// model call is observable at all; plus the run record read back through the
// protocol, which says the interrupted work is a visible failure with a retry
// rather than something that resumed on its own.
func TestSavedMidRunDocumentContinuesWithoutDuplicateCalls(t *testing.T) {
	schemas, err := contract.LoadRegistry()
	if err != nil {
		t.Fatal(err)
	}

	// --- the first process: a round caught in flight and "saved" -----------
	first, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	held := make(chan struct{})
	var once sync.Once
	entered := make(chan struct{})
	models := &fakeModel{reply: func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		if call.SeatID == "seat-capacity" {
			once.Do(func() { close(entered) })
			<-held
		}
		return session.ModelReply{
			ModelID: "fake-model-a",
			Text:    modelAnswer("An answer from " + call.SeatID + "."),
		}, nil
	}}
	first.SetChatHost(models)
	host := newFakeHost(t, first)
	host.rpc(1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	host.notify("notifications/initialized")

	id := 1
	nextID := func() int { id++; return id }
	command := func(name string, payload map[string]any, waitSeconds int) map[string]any {
		t.Helper()
		callID := nextID()
		args := map[string]any{
			"request_id": fmt.Sprintf("r-%d-%s", callID, name),
			"command":    name,
			"payload":    payload,
		}
		if waitSeconds > 0 {
			args["wait_seconds"] = waitSeconds
		}
		switch name {
		case "snapshot.get", "source.fetch", "definition.export", "run.await":
		default:
			args["base_revision"] = first.Revision()
		}
		return host.command(callID, schemas, args)
	}

	var populated map[string]any
	if err := json.Unmarshal(readFixture(t, "workshop_complete.mcouncil"), &populated); err != nil {
		t.Fatal(err)
	}
	loadReportFor(t, host, nextID(), populated)
	payloadOf(t, command("session.create", map[string]any{
		"session_id":    "ses-interrupted",
		"definition_id": "def-workshop-economics",
		"question":      "Should the workshop take the recurring order?",
		"chat_id":       "chat-interrupted",
	}, 0))

	// The round outruns the command's own wait, which is what a partial run
	// looks like from the caller's side: it answers "running" and the round
	// carries on behind it.
	started := payloadOf(t, command("run.start", map[string]any{
		"session_id": "ses-interrupted",
		"kind":       "initial_round",
	}, 1))
	runID := str(started["run_id"])
	if status := str(started["status"]); status != "running" && status != "pending" {
		t.Fatalf("this section needs a round still in flight when the document is saved, got %q", status)
	}
	<-entered
	awaitContribution(t, first, "ses-interrupted", runID, "complete")

	// This is the document the panel persists on Ctrl+S while the round is
	// going: one seat answered, one is still out.
	saved := exportedSnapshot(t, host, nextID())
	savedRun := runOf(t, saved, "ses-interrupted", runID)
	statuses := contributionStatuses(savedRun)
	if statuses["seat-costing"] != "complete" || statuses["seat-capacity"] == "complete" {
		t.Fatalf("the saved document must hold one answered seat and one unanswered: %v", statuses)
	}
	close(held)

	// --- the restart: nothing but the document survives --------------------
	second, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	afterRestart := &fakeModel{reply: func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		return session.ModelReply{
			ModelID: "fake-model-b",
			Text:    modelAnswer("A second-process answer from " + call.SeatID + "."),
		}, nil
	}}
	second.SetChatHost(afterRestart)
	reopened := newFakeHost(t, second)
	reopened.rpc(1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	reopened.notify("notifications/initialized")
	restartID := 1
	nextRestartID := func() int { restartID++; return restartID }
	afterCommand := func(name string, payload map[string]any, waitSeconds int) map[string]any {
		t.Helper()
		callID := nextRestartID()
		args := map[string]any{
			"request_id": fmt.Sprintf("s-%d-%s", callID, name),
			"command":    name,
			"payload":    payload,
		}
		if waitSeconds > 0 {
			args["wait_seconds"] = waitSeconds
		}
		switch name {
		case "snapshot.get", "source.fetch", "definition.export", "run.await":
		default:
			args["base_revision"] = second.Revision()
		}
		return reopened.command(callID, schemas, args)
	}

	report := loadReportFor(t, reopened, nextRestartID(), saved)
	if demoted := int(numOf(report["runs_demoted"])); demoted != 1 {
		t.Fatalf("the run that was in flight must be demoted on reopen, runs_demoted=%v", report["runs_demoted"])
	}
	// A negative claim over a window: a resumption is something Load would do,
	// and Load has already returned. It cannot prove nothing ever starts.
	time.Sleep(100 * time.Millisecond)
	if calls, _ := afterRestart.recorded(); len(calls) != 0 {
		t.Fatalf("reopening a document must consult nobody; the fake saw %d calls", len(calls))
	}
	reloaded := runOf(t, exportedSnapshot(t, reopened, nextRestartID()), "ses-interrupted", runID)
	if str(reloaded["status"]) != "failed" {
		t.Fatalf("the interrupted run must be a visible failure, not a running one: %q", reloaded["status"])
	}
	if code := str(obj2(reloaded["failure"])["code"]); code != "interrupted" {
		t.Fatalf("the failure must say what happened to it, got %q", code)
	}
	if statuses := contributionStatuses(reloaded); statuses["seat-costing"] != "complete" {
		t.Fatalf("the answer that was already paid for must survive the restart: %v", statuses)
	}

	// --- the explicit continue --------------------------------------------
	// Nothing above this line spent anything. This is the user asking for it.
	retried := payloadOf(t, afterCommand("run.retry", map[string]any{
		"session_id": "ses-interrupted",
		"run_id":     runID,
	}, 25))
	rested(t, retried)

	calls, _ := afterRestart.recorded()
	// The oracle for "no duplicate model calls": the seat that answered before
	// the interruption is not in the list at all. A resume that re-ran the whole
	// round, or a retry that re-asked everybody, both show up here.
	for _, call := range calls {
		if call.SeatID == "seat-costing" {
			t.Fatalf("seat-costing answered before the restart and was consulted again; the round cost was paid twice: %v", call)
		}
	}
	if len(calls) != 2 {
		t.Fatalf("continuing an interrupted round is the unanswered seat plus the chair, the fake saw %d calls", len(calls))
	}
	final := exportedSnapshot(t, reopened, nextRestartID())
	if got := str(runOf(t, final, "ses-interrupted", str(retried["run_id"]))["status"]); got != "complete" && got != "partial" {
		t.Fatalf("the continued round must come to rest, got %q", got)
	}
}

func obj2(v any) map[string]any { m, _ := v.(map[string]any); return m }

// TestAPanelClosedMidRunRecoversItsContributions is the other half of the
// interruption story, and the one the interruption rule alone gets wrong.
//
// When the PANEL closes but the backend keeps running, the contributions that
// land afterwards exist in the engine and nowhere else — the wrapper was not
// there to persist them. Reopening hands the engine the record as it was BEFORE
// the round, and taking that record would throw the work away.
//
// Oracle: the snapshot the engine holds after the reopen. It must be the later
// state, and the load report must say so rather than leaving the wrapper to
// guess whether the record moved.
//
// The rule is deliberately only reachable in "reopen" mode, and the last
// section here is the control for that: a plain load replaces. The engine
// cannot separate a reopen from a file copy that merely lags behind — both
// carry the same identity and the same history — so the wrapper is what decides,
// by sending "reopen" only when nobody holds the engine (architecture.md §4.3).
// The paired assertion for that lives in the GD suite, section 9, where the
// lease exists.
func TestAPanelClosedMidRunRecoversItsContributions(t *testing.T) {
	schemas, err := contract.LoadRegistry()
	if err != nil {
		t.Fatal(err)
	}
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	models := &fakeModel{reply: func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		return session.ModelReply{ModelID: "fake", Text: modelAnswer("An answer from " + call.SeatID + ".")}, nil
	}}
	store.SetChatHost(models)
	host := newFakeHost(t, store)
	host.rpc(1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	host.notify("notifications/initialized")
	id := 1
	nextID := func() int { id++; return id }
	command := func(name string, payload map[string]any, waitSeconds int) map[string]any {
		t.Helper()
		callID := nextID()
		args := map[string]any{
			"request_id": fmt.Sprintf("c-%d-%s", callID, name),
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
		return host.command(callID, schemas, args)
	}

	var populated map[string]any
	if err := json.Unmarshal(readFixture(t, "workshop_complete.mcouncil"), &populated); err != nil {
		t.Fatal(err)
	}
	loadReportFor(t, host, nextID(), populated)
	payloadOf(t, command("session.create", map[string]any{
		"session_id":    "ses-closed-panel",
		"definition_id": "def-workshop-economics",
		"question":      "Should the workshop take the recurring order?",
		"chat_id":       "chat-closed-panel",
	}, 0))

	// What the panel had persisted at the moment it closed: the session, no run.
	beforeTheRound := exportedSnapshot(t, host, nextID())

	started := payloadOf(t, command("run.start", map[string]any{
		"session_id": "ses-closed-panel",
		"kind":       "initial_round",
	}, 25))
	rested(t, started)
	runID := str(started["run_id"])

	// The panel comes back and hands over the record it was holding, which is
	// two revisions behind and has no run in it at all.
	report := reopenReportFor(t, host, nextID(), beforeTheRound)
	if recovered, _ := report["recovered"].(bool); !recovered {
		t.Fatalf("reopening onto a later state of the same document must report a recovery: %v", report)
	}
	after := exportedSnapshot(t, host, nextID())
	run := runOf(t, after, "ses-closed-panel", runID)
	if len(arrOf(run["contributions"])) == 0 {
		t.Fatal("the recovered document holds no contributions; the round's work was thrown away")
	}
	if str(after["project_id"]) != str(beforeTheRound["project_id"]) {
		t.Fatal("a recovery must keep the identity of the document it recovered")
	}
	encoded, err := json.Marshal(after)
	if err != nil {
		t.Fatal(err)
	}
	if errs := schemas.ValidateRecord("council_project_snapshot", encoded); len(errs) > 0 {
		t.Fatalf("the recovered document is not a valid record:\n  %s", strings.Join(errs, "\n  "))
	}

	// The mode is the other half of the narrowness: a plain load means "hold
	// exactly this document" and must keep meaning that, or a caller replacing
	// the working record could silently be refused.
	loadReportFor(t, host, nextID(), beforeTheRound)
	if replaced := exportedSnapshot(t, host, nextID()); len(arrOf(runsOfSession(replaced, "ses-closed-panel"))) != 0 {
		t.Fatal("a plain load must replace the working document, recovery is the reopen path only")
	}
	reopenReportFor(t, host, nextID(), after)

	// The narrowness of the rule is the point: only a LATER state of the SAME
	// document is kept. Another project's record replaces it, because that is
	// the user opening something else and it must not inherit this one's work.
	other := deepCopyJSON(t, beforeTheRound)
	other["project_id"] = newProjectID(t)
	otherReport := reopenReportFor(t, host, nextID(), other)
	if recovered, _ := otherReport["recovered"].(bool); recovered {
		t.Fatal("a document from another project was mistaken for a later state of this one")
	}
	held := exportedSnapshot(t, host, nextID())
	if str(held["project_id"]) != str(other["project_id"]) {
		t.Fatalf("opening another project's document must replace the record: the engine holds %q",
			str(held["project_id"]))
	}
	// The sharper form: the round this engine ran must not appear in the record
	// of the project that never ran it.
	for _, s := range arrOf(held["sessions"]) {
		record, _ := s.(map[string]any)
		if str(record["session_id"]) == "ses-closed-panel" && len(arrOf(record["runs"])) != 0 {
			t.Fatal("another project's document was given this one's run")
		}
	}

	// And a document of the same project that is NOT an ancestor — a session
	// this engine never had — is a different history, so the caller's record
	// wins. The recovered document goes back in first: the check above left the
	// engine holding another project's record, and against that one this would
	// pass for the wrong reason.
	loadReportFor(t, host, nextID(), after)
	divergent := deepCopyJSON(t, after)
	divergent["project_id"] = str(beforeTheRound["project_id"])
	divergent["snapshot_revision"] = float64(1)
	for _, s := range arrOf(divergent["sessions"]) {
		record, _ := s.(map[string]any)
		if str(record["session_id"]) == "ses-closed-panel" {
			record["session_id"] = "ses-a-different-history"
			record["chat_binding"] = nil
			delete(record, "chat_binding")
		}
	}
	divergentReport := reopenReportFor(t, host, nextID(), divergent)
	if recovered, _ := divergentReport["recovered"].(bool); recovered {
		t.Fatal("a document holding a session this engine never had is not a later state of what it holds")
	}

	// -------------------------------------------------------------------
	// A reopen at the SAME revision, which is the case "not ahead" gets wrong.
	//
	// run.start mints a revision; each contribution commits its own as it
	// lands. So a panel that persists right after starting a round and closes
	// before the first answer arrives holds EXACTLY the revision the engine is
	// at. Treating that as "not a later state" replaces the document, and the
	// replacement cancels the live round and demotes it "interrupted" — the
	// user loses a round that was running perfectly well.
	//
	// Oracle: the round itself. It has to still be executing after the reopen,
	// which is shown by letting it finish and reading the contribution back.
	// -------------------------------------------------------------------
	blocked := make(chan struct{})
	var once sync.Once
	entered := make(chan struct{})
	models.configure(1, func(_ context.Context, call session.ModelCall) (session.ModelReply, error) {
		if call.Role == "advisor" {
			once.Do(func() { close(entered) })
			<-blocked
		}
		return session.ModelReply{ModelID: "fake", Text: modelAnswer("An answer from " + call.SeatID + ".")}, nil
	})
	loadReportFor(t, host, nextID(), beforeTheRound)
	payloadOf(t, command("session.create", map[string]any{
		"session_id":    "ses-same-revision",
		"definition_id": "def-workshop-economics",
		"question":      "Should the workshop take the recurring order?",
		"chat_id":       "chat-same-revision",
	}, 0))
	pending := payloadOf(t, command("run.start", map[string]any{
		"session_id": "ses-same-revision",
		"kind":       "initial_round",
	}, 1))
	if status := str(pending["status"]); status != "running" && status != "pending" {
		t.Fatalf("this section needs a round still in flight, got %q", status)
	}
	<-entered
	atStart := exportedSnapshot(t, host, nextID())
	// The control: this really is the equal-revision case, not the higher one
	// the rest of the test already covers.
	if int(numOf(atStart["snapshot_revision"])) != store.Revision() {
		t.Fatalf("this section needs the panel's copy to be AT the engine's revision: %d vs %d",
			int(numOf(atStart["snapshot_revision"])), store.Revision())
	}
	sameRevision := reopenReportFor(t, host, nextID(), atStart)
	if recovered, _ := sameRevision["recovered"].(bool); !recovered {
		t.Fatalf("a reopen at the document's own revision is the same document, not a replacement: %v", sameRevision)
	}
	close(blocked)
	awaitContribution(t, store, "ses-same-revision", str(pending["run_id"]), "complete")
	survived := runOf(t, exportedSnapshot(t, host, nextID()), "ses-same-revision", str(pending["run_id"]))
	if str(survived["status"]) == "failed" {
		t.Fatalf("the reopen killed a round that was running: %v", survived["failure"])
	}
	if len(arrOf(survived["contributions"])) == 0 {
		t.Fatal("the round that outlived the reopen produced nothing")
	}
}

// TestAChatCannotBeAdoptedIntoAnotherProjectAfterARestart is the durable half
// of the cross-project guard.
//
// T07 could refuse a foreign chat only while one process had seen both
// documents, because the evidence was a load-generation number in process
// memory. This asserts the guard survives a restart, and the mechanism it
// asserts is the one that makes that possible: the project identity is in the
// document, so loading the owning document rebuilds the routing table from the
// record rather than from anything the process remembered.
//
// Oracle: the host's own model-call log. A chat wrongly adopted starts a round,
// and a round is model calls; a refused one is a reply and nothing else.
func TestAChatCannotBeAdoptedIntoAnotherProjectAfterARestart(t *testing.T) {
	var populated map[string]any
	if err := json.Unmarshal(readFixture(t, "workshop_complete.mcouncil"), &populated); err != nil {
		t.Fatal(err)
	}

	// Two documents, two projects. Project B is a copy with its own identity and
	// no sessions — the user's other project, holding the same council.
	projectA := deepCopyJSON(t, populated)
	projectB := deepCopyJSON(t, populated)
	projectB["project_id"] = newProjectID(t)
	projectB["sessions"] = []any{}
	// The fixture's view points at a session this copy no longer has, and the
	// snapshot invariants refuse a view naming a session that does not exist.
	// Without this the load is REFUSED, project A stays resident, and every
	// assertion below silently exercises project A instead of the crossing.
	delete(projectB, "view")

	// --- the first process: a chat is routed into project A ---------------
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	host := newProviderHost(t, store)
	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")
	if body := host.tool(2, "minerva_council_load_snapshot", map[string]any{"snapshot": projectA}); body["ok"] == false {
		t.Fatalf("project A did not load: %v", body)
	}
	answered := host.turn(3, "chat-crossing", "What should the workshop do about the recurring order?")
	if kind := str(answered["kind"]); kind == ChatErrorKind {
		t.Fatalf("the first turn in a fresh chat opens a session here: %v", answered)
	}
	savedA := host.tool(4, "minerva_council_export_snapshot", map[string]any{})["snapshot"].(map[string]any)

	// --- the restart: a new process that has never seen either document ----
	restarted, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	next := newProviderHost(t, restarted)
	next.rpc(1, "initialize", map[string]any{})
	next.awaitCapability("host.chat_providers.register")

	// The user opens project A's document — which is what makes the binding
	// visible to this process at all — and then switches to project B.
	next.tool(2, "minerva_council_load_snapshot", map[string]any{"snapshot": savedA})
	next.tool(3, "minerva_council_load_snapshot", map[string]any{"snapshot": projectB})

	before := len(next.modelCalls())
	refused := next.turn(4, "chat-crossing", "And what about the second order?")
	if kind := str(refused["kind"]); kind != ChatErrorKind {
		t.Fatalf("a chat belonging to another project must be refused, not continued here: %v", refused)
	}
	if text := str(refused["text"]); !strings.Contains(text, "another project") {
		t.Fatalf("the refusal has to say what is wrong so the user can act on it: %q", text)
	}
	if after := len(next.modelCalls()); after != before {
		t.Fatalf("a refused chat turn must consult nobody; %d model calls were made", after-before)
	}
	held := next.tool(5, "minerva_council_export_snapshot", map[string]any{})["snapshot"].(map[string]any)
	if len(arrOf(held["sessions"])) != 0 {
		t.Fatalf("project B's document must be untouched by another project's chat: %v", held["sessions"])
	}

	// The same chat, back in its own project, still works: the guard refuses a
	// crossing, it does not strand the chat.
	next.tool(6, "minerva_council_load_snapshot", map[string]any{"snapshot": savedA})
	continued := next.turn(7, "chat-crossing", "And what about the second order?")
	if kind := str(continued["kind"]); kind == ChatErrorKind {
		t.Fatalf("the chat's own project must still answer it: %v", continued)
	}
}

// ChatErrorKind is the provider's error reply kind, named here so the
// assertions above read as the host contract rather than as a bare string.
const ChatErrorKind = session.ChatError

// TestARetainedNoteThatCannotBeResolvedStaysLinked covers the missing-artifact
// recovery state for notes.
//
// Oracle: the exported record. The reference is kept and flagged, never
// dropped — dropping it would lose the only link between a conclusion the user
// kept and the contribution it came from.
func TestARetainedNoteThatCannotBeResolvedStaysLinked(t *testing.T) {
	schemas, err := contract.LoadRegistry()
	if err != nil {
		t.Fatal(err)
	}
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	host := newFakeHost(t, store)
	host.rpc(1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	host.notify("notifications/initialized")
	id := 1
	nextID := func() int { id++; return id }
	command := func(name string, payload map[string]any) map[string]any {
		t.Helper()
		callID := nextID()
		args := map[string]any{
			"request_id": fmt.Sprintf("n-%d-%s", callID, name),
			"command":    name,
			"payload":    payload,
		}
		switch name {
		case "snapshot.get", "source.fetch", "definition.export", "run.await":
		default:
			args["base_revision"] = store.Revision()
		}
		return host.command(callID, schemas, args)
	}

	var populated map[string]any
	if err := json.Unmarshal(readFixture(t, "workshop_complete.mcouncil"), &populated); err != nil {
		t.Fatal(err)
	}
	loadReportFor(t, host, nextID(), populated)

	// The fixture's own completed round is the material: a contribution the user
	// would plausibly keep.
	run := runOf(t, populated, "ses-recurring-order", "run-1")
	var kept string
	for _, c := range arrOf(run["contributions"]) {
		contribution, _ := c.(map[string]any)
		if str(contribution["status"]) == "complete" {
			kept = str(contribution["contribution_id"])
			break
		}
	}
	if kept == "" {
		t.Fatal("the fixture holds no completed contribution to retain")
	}
	retained := payloadOf(t, command("outcome.retain", map[string]any{
		"session_id":      "ses-recurring-order",
		"run_id":          "run-1",
		"contribution_id": kept,
		"note_ref":        "note-0192cd",
		"note_label":      "Take the order only if the bench has no better use",
	}))
	outcomeID := str(retained["outcome_id"])

	marked := payloadOf(t, command("outcome.mark_missing", map[string]any{
		"session_id": "ses-recurring-order",
		"outcome_id": outcomeID,
		"missing":    true,
	}))
	if changed, _ := marked["changed"].(bool); !changed {
		t.Fatalf("the first report of a missing note changes the record: %v", marked)
	}
	snapshot := exportedSnapshot(t, host, nextID())
	outcome := outcomeIn(t, snapshot, "ses-recurring-order", outcomeID)
	note := obj2(outcome["note"])
	if missing, _ := note["missing"].(bool); !missing {
		t.Fatalf("the note must be flagged, got %v", note)
	}
	if str(note["ref"]) != "note-0192cd" {
		t.Fatalf("the reference must be kept, not dropped: %v", note)
	}
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if errs := schemas.ValidateRecord("council_project_snapshot", encoded); len(errs) > 0 {
		t.Fatalf("a document with an unresolved note is still a valid record:\n  %s", strings.Join(errs, "\n  "))
	}

	// Saying it twice moves nothing: an unresolved note re-reported on every
	// reopen would advance the revision under every other open view.
	before := store.Revision()
	again := payloadOf(t, command("outcome.mark_missing", map[string]any{
		"session_id": "ses-recurring-order",
		"outcome_id": outcomeID,
		"missing":    true,
	}))
	if changed, _ := again["changed"].(bool); changed {
		t.Fatalf("a repeated report must change nothing: %v", again)
	}
	if store.Revision() != before {
		t.Fatalf("a repeated report advanced the revision from %d to %d", before, store.Revision())
	}

	// And the note coming back clears the flag rather than leaving a permanent
	// mark on a reference that resolves perfectly well.
	payloadOf(t, command("outcome.mark_missing", map[string]any{
		"session_id": "ses-recurring-order",
		"outcome_id": outcomeID,
		"missing":    false,
	}))
	recovered := obj2(outcomeIn(t, exportedSnapshot(t, host, nextID()), "ses-recurring-order", outcomeID)["note"])
	if _, present := recovered["missing"]; present {
		t.Fatalf("a resolved note carries no missing flag at all: %v", recovered)
	}
}

func outcomeIn(t *testing.T, snapshot map[string]any, sessionID, outcomeID string) map[string]any {
	t.Helper()
	for _, s := range arrOf(snapshot["sessions"]) {
		record, _ := s.(map[string]any)
		if str(record["session_id"]) != sessionID {
			continue
		}
		for _, o := range arrOf(record["outcomes"]) {
			outcome, _ := o.(map[string]any)
			if str(outcome["outcome_id"]) == outcomeID {
				return outcome
			}
		}
	}
	t.Fatalf("session %q holds no outcome %q", sessionID, outcomeID)
	return nil
}

// runsOfSession reads one session's run list out of a snapshot.
func runsOfSession(snapshot map[string]any, sessionID string) any {
	for _, s := range arrOf(snapshot["sessions"]) {
		record, _ := s.(map[string]any)
		if str(record["session_id"]) == sessionID {
			return record["runs"]
		}
	}
	return nil
}
