package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/ipeerbhai/plugins/council/fixtures"
	"github.com/ipeerbhai/plugins/council/internal/contract"
	"github.com/ipeerbhai/plugins/council/internal/session"
)

// The material below is written for this test. It stands in for a note the user
// captured in project A, and nothing about it is quoted from anywhere.
const (
	privateNote = "The bench is booked eleven days ahead and the jig for the small brackets is worn. " +
		"Anything promised past the eleventh day is promised against a machine that is already late."
	privateQuote = "Anything promised past the eleventh day is promised against a machine that is already late."
	// The half of the note that was never anchored: an export must not carry it
	// even when the excerpt beside it travels as inventory.
	privateUnquoted = "the jig for the small brackets is worn"

	// A note that says the same sentence twice. An anchor on it can only be
	// placed by the caller, and the placement has to survive an export and a
	// repair or the citation moves to the wrong occurrence.
	doubledNote = "The jig is worn. Replace the jig before the next run. " +
		"The bracket order can wait a week, but nothing else can. Replace the jig before the next run."
	doubledQuote = "Replace the jig before the next run."

	revisedEssay = "A bench has one throughput, and every promise made against it is a promise against the same hours. " +
		"A recurring order removes the freedom to refuse the next one, and that is the thing being sold. " +
		"Price the loss of the refusal."
	revisedQuote = "A recurring order removes the freedom to refuse the next one, and that is the thing being sold."
)

func sha256Of(text string) string {
	sum := sha256.Sum256([]byte(text))
	return "sha256:" + hex.EncodeToString(sum[:])
}

// payloadOf returns a successful reply's payload and fails the test on a reply
// that refused the command.
func payloadOf(t *testing.T, reply map[string]any) map[string]any {
	t.Helper()
	if ok, _ := reply["ok"].(bool); !ok {
		t.Fatalf("expected a successful reply, got %v", reply["error"])
	}
	payload, _ := reply["payload"].(map[string]any)
	return payload
}

// refusalSaying asserts a refusal whose message names the reason, so a command
// that fails for an unrelated reason cannot pass as the one under test.
func refusalSaying(t *testing.T, reply map[string]any, fragment string) {
	t.Helper()
	if ok, _ := reply["ok"].(bool); ok {
		t.Fatalf("expected a refusal mentioning %q, got a success: %v", fragment, reply["payload"])
	}
	message, _ := reply["error"].(map[string]any)["message"].(string)
	if !strings.Contains(message, fragment) {
		t.Fatalf("expected a refusal mentioning %q, got %q", fragment, message)
	}
}

func findRecord(list any, idField, id string) map[string]any {
	entries, _ := list.([]any)
	for _, x := range entries {
		record, _ := x.(map[string]any)
		if got, _ := record[idField].(string); got == id {
			return record
		}
	}
	return nil
}

// TestGroundedMemberLifecycleOverTheProtocol drives the whole grounding story
// over the real stdio protocol, in one pass, against a live engine: capture
// user text as a source, build a simulant identity on it before it holds any
// seat, run a round, capture a changed source, adopt it explicitly, and export
// the council for another project.
//
// Oracles, none of them a golden string:
//   - every reply is validated against envelope.schema.json and the whole
//     snapshot against project_snapshot.schema.json plus its invariants, which
//     is what refuses an unknown grounding revision and an ungrounded simulant;
//   - the engine's content_hash is compared against sha256 computed here, and
//     every anchor span is compared against the captured text it indexes;
//   - the pinning claim is checked against the session's own embedded
//     definition after the project definition has moved on;
//   - the leak claim is a sweep of the exported bytes for project A's question,
//     session id, chat id, note id and unselected material.
//
// Unknown citation anchors are covered by the record contract
// (fixtures/invalid/session_citation_unknown_anchor.json); what this test adds
// is the command-level half — a grounding reference to a revision that does not
// exist is refused before it can be cited at all.
func TestGroundedMemberLifecycleOverTheProtocol(t *testing.T) {
	schemas, err := contract.LoadRegistry()
	if err != nil {
		t.Fatalf("load schemas: %v", err)
	}
	store, err := session.New()
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	store.SetClock(func() string { return time.Date(2026, 9, 8, 12, 0, 0, 0, time.UTC).Format("2006-01-02T15:04:05Z") })
	host := newFakeHost(t, store)
	host.rpc(1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	host.notify("notifications/initialized")

	var definition map[string]any
	raw, err := fixtures.FS.ReadFile("definition_workshop.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	if err := json.Unmarshal(raw, &definition); err != nil {
		t.Fatal(err)
	}
	definitionID, _ := definition["definition_id"].(string)

	id := 1
	run := func(command string, payload map[string]any) map[string]any {
		t.Helper()
		id++
		// The request_id is the idempotency key, so it comes from the same
		// deterministic counter as the JSON-RPC id: a clock-derived key could
		// collide on a fast machine and turn a real command into a replay.
		args := map[string]any{
			"request_id": fmt.Sprintf("g-%d-%s", id, command),
			"command":    command,
			"payload":    payload,
		}
		// base_revision is the classification: a read must not carry one.
		switch command {
		case "snapshot.get", "source.fetch", "definition.export":
		default:
			args["base_revision"] = store.Revision()
		}
		return host.command(id, schemas, args)
	}

	payloadOf(t, run("definition.upsert", map[string]any{"definition": definition}))

	// --- capture: user text becomes a source revision ---------------------
	captured := payloadOf(t, run("source.capture", map[string]any{
		"definition_id": definitionID,
		"source_id":     "src-private-notes",
		"title":         "Bench booking notes (fixture text)",
		"locator":       "note: bench booking notes",
		"content_type":  "text/markdown",
		"artifact":      map[string]any{"kind": "note", "ref": "note-private-bench", "label": "bench booking notes"},
		"text":          privateNote,
		"excerpts":      []any{map[string]any{"anchor_id": "anc-eleventh-day", "quote": privateQuote}},
	}))
	if got, _ := captured["source_revision"].(float64); int(got) != 1 {
		t.Fatalf("the first capture of a source is revision 1, got %v", captured["source_revision"])
	}
	if got, _ := captured["content_hash"].(string); got != sha256Of(privateNote) {
		t.Fatalf("the engine hashed the captured text as %q", got)
	}
	if repaired, _ := captured["repaired"].(bool); repaired {
		t.Error("a new capture is not a repair")
	}

	fetched := payloadOf(t, run("source.fetch", map[string]any{
		"definition_id": definitionID,
		"source_id":     "src-private-notes",
	}))
	source, _ := fetched["source"].(map[string]any)
	inline, _ := source["payload"].(map[string]any)["inline"].(string)
	anchor, _ := source["anchors"].([]any)[0].(map[string]any)
	start, end := int(anchor["start"].(float64)), int(anchor["end"].(float64))
	if inline[start:end] != privateQuote {
		t.Fatalf("the derived anchor span %d..%d does not contain the excerpt", start, end)
	}

	// An excerpt the engine cannot place is refused rather than guessed at.
	refusalSaying(t, run("source.capture", map[string]any{
		"definition_id": definitionID,
		"source_id":     "src-unplaceable",
		"title":         "Unplaceable",
		"text":          privateNote,
		"excerpts":      []any{map[string]any{"anchor_id": "anc-nope", "quote": "a sentence that is not in the text"}},
	}), "does not appear in the captured text")

	// An excerpt the engine could place in two ways is refused rather than
	// placed in one of them.
	refusalSaying(t, run("source.capture", map[string]any{
		"definition_id": definitionID,
		"source_id":     "src-doubled",
		"title":         "A note that repeats itself (fixture text)",
		"text":          doubledNote,
		"excerpts":      []any{map[string]any{"anchor_id": "anc-second-telling", "quote": doubledQuote}},
	}), "appears more than once")

	// Naming the occurrence is how the caller resolves it, and that placement
	// is the anchor from then on.
	secondTelling := strings.LastIndex(doubledNote, doubledQuote)
	doubled := payloadOf(t, run("source.capture", map[string]any{
		"definition_id": definitionID,
		"source_id":     "src-doubled",
		"title":         "A note that repeats itself (fixture text)",
		"text":          doubledNote,
		"excerpts": []any{map[string]any{
			"anchor_id": "anc-second-telling",
			"quote":     doubledQuote,
			"start":     secondTelling,
			"end":       secondTelling + len(doubledQuote),
		}},
	}))
	if got, _ := doubled["source_revision"].(float64); int(got) != 1 {
		t.Fatalf("the first capture of src-doubled is revision 1, got %v", doubled["source_revision"])
	}

	// --- upsert: a record the caller already built -------------------------
	//
	// source.upsert is the other door onto the same shelf, and it exists for a
	// caller that has the record already — an import, a migration, a page that
	// derived the spans itself. What separates it from capture is that nothing
	// is derived here: the anchors are the caller's placement and the engine
	// stores them as given. The oracle is the fetched record compared with the
	// bytes that were sent, on the ONE case where a derivation would differ —
	// a quote that appears twice, pinned to the FIRST occurrence, which capture
	// refuses to guess at (above) and upsert must not silently move.
	firstTelling := strings.Index(doubledNote, doubledQuote)
	built := map[string]any{
		"source_id":       "src-doubled",
		"source_revision": 2,
		"title":           "A note that repeats itself, placed by the caller (fixture text)",
		"locator":         "note: doubled",
		"captured_at":     "2026-09-08T12:00:00Z",
		"content_hash":    sha256Of(doubledNote),
		"payload": map[string]any{
			"content_type": "text/plain",
			"byte_length":  len(doubledNote),
			"content_hash": sha256Of(doubledNote),
			"inline":       doubledNote,
		},
		"anchors": []any{map[string]any{
			"anchor_id": "anc-first-telling",
			"quote":     doubledQuote,
			"start":     firstTelling,
			"end":       firstTelling + len(doubledQuote),
		}},
	}
	upserted := payloadOf(t, run("source.upsert", map[string]any{
		"definition_id": definitionID,
		"source":        deepCopyJSON(t, built),
	}))
	if got, _ := upserted["source_revision"].(float64); int(got) != 2 {
		t.Fatalf("upsert stored the revision the caller named, expected 2, got %v", upserted["source_revision"])
	}
	// Capturing material changes the council, whichever door it came through.
	if got, _ := upserted["definition_revision"].(float64); int(got) <= 0 {
		t.Fatalf("upsert must advance the definition, got %v", upserted["definition_revision"])
	}

	back := payloadOf(t, run("source.fetch", map[string]any{
		"definition_id":   definitionID,
		"source_id":       "src-doubled",
		"source_revision": 2,
	}))
	asStored, _ := back["source"].(map[string]any)
	storedAnchor, _ := asStored["anchors"].([]any)[0].(map[string]any)
	if int(storedAnchor["start"].(float64)) != firstTelling {
		t.Fatalf("upsert re-derived the anchor to %v; the caller pinned the first telling at %d",
			storedAnchor["start"], firstTelling)
	}
	if kept, _ := asStored["payload"].(map[string]any)["inline"].(string); kept != doubledNote {
		t.Fatal("upsert did not store the payload it was given")
	}

	// A revision is a capture and never an edit, so the pair cannot be reused:
	// a past contribution has to stay inspectable against the bytes it read.
	refusalSaying(t, run("source.upsert", map[string]any{
		"definition_id": definitionID,
		"source":        deepCopyJSON(t, built),
	}), "never an edit of an old one")

	// The commit path validates the whole snapshot, so a record whose declared
	// hash does not describe the bytes beside it is refused here rather than
	// becoming a source whose citations resolve against something else.
	lying := deepCopyJSON(t, built)
	lying["source_revision"] = 3
	lying["payload"].(map[string]any)["inline"] = doubledNote + " And one more sentence."
	refusalSaying(t, run("source.upsert", map[string]any{
		"definition_id": definitionID,
		"source":        lying,
	}), "content_hash")

	// And a council that is not in this project is named as such, rather than
	// the material landing somewhere it was not meant for.
	refusalSaying(t, run("source.upsert", map[string]any{
		"definition_id": "def-not-here",
		"source":        deepCopyJSON(t, built),
	}), "is not in this project")

	// --- identity: a member exists before it holds a seat -----------------
	simulant := map[string]any{
		"member_id":    "mem-bench",
		"kind":         "simulant",
		"display_name": "Bench notes",
		"represents":   "the shop's own booking notes, read as one voice",
		"scope":        "What the bench is already committed to, as recorded in one set of booking notes.",
		"limitations":  "One week of notes about one machine. Says nothing about price, customers, or any other machine.",
		"grounding":    []any{map[string]any{"source_id": "src-private-notes", "source_revision": 1}},
	}
	created := payloadOf(t, run("member.upsert", map[string]any{
		"definition_id": definitionID,
		"member":        deepCopyJSON(t, simulant),
	}))
	if rev, _ := created["member_revision"].(float64); int(rev) != 1 {
		t.Fatalf("a new member starts at revision 1, got %v", created["member_revision"])
	}
	if seated, _ := created["seated"].(bool); seated {
		t.Error("a new member holds no seat until one is assigned; identity is not a seat")
	}

	// A cosmetic edit is not a new member: an old answer is still that
	// member's answer.
	renamed := deepCopyJSON(t, simulant)
	renamed["display_name"] = "Bench notes (booking log)"
	after := payloadOf(t, run("member.upsert", map[string]any{"definition_id": definitionID, "member": renamed}))
	if rev, _ := after["member_revision"].(float64); int(rev) != 1 {
		t.Errorf("renaming a member advanced its revision to %v", after["member_revision"])
	}
	// Narrowing what it may speak to is a different member to consult.
	narrowed := deepCopyJSON(t, renamed)
	narrowed["scope"] = "What the bench is committed to this week only."
	after = payloadOf(t, run("member.upsert", map[string]any{"definition_id": definitionID, "member": narrowed}))
	if rev, _ := after["member_revision"].(float64); int(rev) != 2 {
		t.Errorf("changing a member's scope must advance its revision, got %v", after["member_revision"])
	}

	// A resend of the identity already stored is not an edit: it must not
	// advance the council or stale every open view.
	settledAfterNarrowing := store.Revision()
	resent := payloadOf(t, run("member.upsert", map[string]any{"definition_id": definitionID, "member": deepCopyJSON(t, narrowed)}))
	if changed, _ := resent["changed"].(bool); changed {
		t.Error("re-sending an unchanged member reported a change")
	}
	if store.Revision() != settledAfterNarrowing {
		t.Errorf("re-sending an unchanged member moved the snapshot to %d", store.Revision())
	}
	if rev, _ := resent["member_revision"].(float64); int(rev) != 2 {
		t.Errorf("a resend must report the revision that stands, got %v", rev)
	}

	// Grounding that names a capture which does not exist is refused here,
	// rather than surfacing later as a citation nobody can resolve.
	ungrounded := deepCopyJSON(t, narrowed)
	ungrounded["grounding"] = []any{map[string]any{"source_id": "src-private-notes", "source_revision": 9}}
	refusalSaying(t, run("member.upsert", map[string]any{"definition_id": definitionID, "member": ungrounded}), "unknown source revision")

	// A simulant with nothing behind it is not a member, it is an assertion.
	empty := deepCopyJSON(t, narrowed)
	empty["grounding"] = []any{}
	refusalSaying(t, run("member.upsert", map[string]any{"definition_id": definitionID, "member": empty}), "simulant")

	// --- a run pins what it read ------------------------------------------
	const question = "Should the workshop take the recurring order?"
	payloadOf(t, run("session.create", map[string]any{
		"session_id":    "ses-ground",
		"definition_id": definitionID,
		"question":      question,
		"chat_id":       "chat-alpha",
	}))
	started := payloadOf(t, run("run.start", map[string]any{
		"session_id": "ses-ground",
		"kind":       "initial_round",
		"seat_ids":   []any{"seat-capacity"},
	}))
	runID, _ := started["run_id"].(string)

	// --- the source changes, and nothing follows it on its own ------------
	updated := payloadOf(t, run("source.capture", map[string]any{
		"definition_id": definitionID,
		"source_id":     "src-capacity-essay",
		"title":         "What a bench can actually hold (revised)",
		"author":        "R. Okonkwo",
		"locator":       "note: Workshop capacity essay",
		"text":          revisedEssay,
		"excerpts":      []any{map[string]any{"anchor_id": "anc-refusal", "quote": revisedQuote}},
	}))
	if got, _ := updated["source_revision"].(float64); int(got) != 3 {
		t.Fatalf("a new capture takes the next revision after 2, got %v", updated["source_revision"])
	}

	adopted := payloadOf(t, run("member.adopt_source", map[string]any{
		"definition_id": definitionID,
		"member_id":     "mem-okonkwo",
		"source_id":     "src-capacity-essay",
	}))
	if got, _ := adopted["previous_source_revision"].(float64); int(got) != 2 {
		t.Errorf("adopting must report what the member was reading, got %v", adopted["previous_source_revision"])
	}
	if got, _ := adopted["source_revision"].(float64); int(got) != 3 {
		t.Errorf("adopting with no revision named takes the newest capture, got %v", adopted["source_revision"])
	}
	if got, _ := adopted["member_revision"].(float64); int(got) != 3 {
		t.Errorf("re-grounding must advance member_revision, got %v", adopted["member_revision"])
	}
	// Adopting what the member already reads changes nothing and must not
	// invalidate every open view.
	settled := store.Revision()
	again := payloadOf(t, run("member.adopt_source", map[string]any{
		"definition_id": definitionID,
		"member_id":     "mem-okonkwo",
		"source_id":     "src-capacity-essay",
	}))
	if changed, _ := again["changed"].(bool); changed || store.Revision() != settled {
		t.Errorf("a second adopt of the same revision moved the snapshot to %d", store.Revision())
	}

	// --- the old run is still inspectable ---------------------------------
	snapshot, _ := payloadOf(t, run("snapshot.get", map[string]any{}))["snapshot"].(map[string]any)
	project := findRecord(snapshot["definitions"], "definition_id", definitionID)
	live := findRecord(project["members"], "member_id", "mem-okonkwo")
	if rev, _ := live["member_revision"].(float64); int(rev) != 3 {
		t.Errorf("the project's member is at revision %v after adopting", live["member_revision"])
	}

	stored := findRecord(snapshot["sessions"], "session_id", "ses-ground")
	pinned := stored["definition_snapshot"].(map[string]any)
	consulted := findRecord(pinned["members"], "member_id", "mem-okonkwo")
	if rev, _ := consulted["member_revision"].(float64); int(rev) != 2 {
		t.Errorf("the run's own copy of the member moved to revision %v; a past answer must stay attributable to what it was", consulted["member_revision"])
	}
	grounding, _ := consulted["grounding"].([]any)
	if got, _ := grounding[0].(map[string]any)["source_revision"].(float64); int(got) != 2 {
		t.Errorf("the run's grounding followed the new capture to revision %v", got)
	}
	pinnedSource := findRecord(pinned["sources"], "source_id", "src-capacity-essay")
	if got, _ := pinnedSource["source_revision"].(float64); int(got) != 2 {
		t.Errorf("the run's embedded source is revision %v", got)
	}
	pinnedText, _ := pinnedSource["payload"].(map[string]any)["inline"].(string)
	if pinnedText == revisedEssay {
		t.Error("the revised essay reached a run that never read it")
	}
	storedRun := findRecord(stored["runs"], "run_id", runID)
	contribution, _ := storedRun["contributions"].([]any)[0].(map[string]any)
	if rev, _ := contribution["member_revision"].(float64); int(rev) != 2 {
		t.Errorf("the contribution is attributed to member revision %v", rev)
	}

	// Both captures remain readable, which is what "inspectable" means.
	old := payloadOf(t, run("source.fetch", map[string]any{
		"definition_id":   definitionID,
		"source_id":       "src-capacity-essay",
		"source_revision": 2,
	}))
	if got, _ := old["source"].(map[string]any)["payload"].(map[string]any)["inline"].(string); got == revisedEssay {
		t.Error("fetching revision 2 returned the revised material")
	}
	newest := payloadOf(t, run("source.fetch", map[string]any{
		"definition_id": definitionID,
		"source_id":     "src-capacity-essay",
	}))
	if got, _ := newest["source"].(map[string]any)["payload"].(map[string]any)["inline"].(string); got != revisedEssay {
		t.Error("fetching with no revision must return the newest capture")
	}

	// --- export: what leaves the project ----------------------------------
	exported := payloadOf(t, run("definition.export", map[string]any{
		"definition_id":      definitionID,
		"include_content":    true,
		"include_source_ids": []any{"src-capacity-essay"},
	}))
	portable, _ := exported["definition"].(map[string]any)
	portableRaw, err := json.Marshal(portable)
	if err != nil {
		t.Fatal(err)
	}
	if errs := schemas.ValidateRecord("council_definition", portableRaw); len(errs) > 0 {
		t.Fatalf("the exported council does not satisfy its own contract: %v", errs)
	}
	text := string(portableRaw)
	for _, leak := range []string{question, "ses-ground", "chat-alpha", "note-private-bench", "note-capacity-essay", privateNote, privateUnquoted} {
		if strings.Contains(text, leak) {
			t.Errorf("the exported council carries project A content: %q", leak)
		}
	}
	// The withheld source is still visible as an inventory entry naming the
	// material it stood for, so the receiving project can say what is missing.
	withheld := findRecord(portable["sources"], "source_id", "src-private-notes")
	if withheld == nil || withheld["payload"] != nil {
		t.Fatalf("the unselected source must appear without its content: %v", withheld)
	}
	if got, _ := withheld["content_hash"].(string); got != sha256Of(privateNote) {
		t.Errorf("the withheld inventory entry lost the hash of the material it stood for: %q", got)
	}
	if quote, _ := withheld["anchors"].([]any)[0].(map[string]any)["quote"].(string); quote != privateQuote {
		t.Error("the withheld source lost the excerpt a citation points at")
	}

	// --- project B: import, see what is missing, repair it -----------------
	storeB, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	storeB.SetClock(func() string { return time.Date(2026, 9, 9, 9, 0, 0, 0, time.UTC).Format("2006-01-02T15:04:05Z") })
	hostB := newFakeHost(t, storeB)
	imported := payloadOf(t, hostB.command(1, schemas, map[string]any{
		"request_id":    "b-import",
		"command":       "definition.import",
		"base_revision": storeB.Revision(),
		"payload":       map[string]any{"definition": portable},
	}))
	// One entry per withheld CAPTURE, not per source: src-doubled travelled as
	// two revisions and each is a distinct set of bytes a citation can point at,
	// so an import that collapsed them would leave one of them unrepairable.
	missing, _ := imported["sources_without_content"].([]any)
	named := map[string]int{}
	for _, x := range missing {
		id, _ := x.(map[string]any)["source_id"].(string)
		named[id]++
	}
	if len(missing) != 3 || named["src-private-notes"] != 1 || named["src-doubled"] != 2 {
		t.Fatalf("an import must name every capture it could not bring: %v", missing)
	}

	// The caller-placed anchor survived export and import as inventory: a
	// re-derivation anywhere on that path would have moved it to the other
	// telling of the same sentence.
	var carried map[string]any
	for _, x := range portable["sources"].([]any) {
		entry, _ := x.(map[string]any)
		id, _ := entry["source_id"].(string)
		revision, _ := entry["source_revision"].(float64)
		if id == "src-doubled" && int(revision) == 2 {
			carried = entry
		}
	}
	if carried == nil {
		t.Fatal("the caller-placed capture did not travel in the export at all")
	}
	carriedAnchor, _ := carried["anchors"].([]any)[0].(map[string]any)
	if got, _ := carriedAnchor["start"].(float64); int(got) != firstTelling {
		t.Errorf("the exported inventory moved the caller's anchor to %v, not %d", carriedAnchor["start"], firstTelling)
	}

	// Material that is not what the inventory recorded is not a repair.
	refusalSaying(t, hostB.command(2, schemas, map[string]any{
		"request_id":    "b-repair-wrong",
		"command":       "source.capture",
		"base_revision": storeB.Revision(),
		"payload": map[string]any{
			"definition_id":   definitionID,
			"source_id":       "src-private-notes",
			"source_revision": 1,
			"text":            privateNote + " And one more sentence nobody captured.",
		},
	}), "different material")

	repaired := payloadOf(t, hostB.command(3, schemas, map[string]any{
		"request_id":    "b-repair",
		"command":       "source.capture",
		"base_revision": storeB.Revision(),
		"payload": map[string]any{
			"definition_id":   definitionID,
			"source_id":       "src-private-notes",
			"source_revision": 1,
			"text":            privateNote,
			"artifact":        map[string]any{"kind": "note", "ref": "note-b-bench", "label": "bench notes (project B)"},
		},
	}))
	if flag, _ := repaired["repaired"].(bool); !flag {
		t.Fatalf("supplying the recorded material must repair the inventory entry, not mint a revision: %v", repaired)
	}
	if got, _ := repaired["source_revision"].(float64); int(got) != 1 {
		t.Errorf("a repair keeps the revision it repaired, got %v", got)
	}

	restored := payloadOf(t, hostB.command(4, schemas, map[string]any{
		"request_id": "b-fetch",
		"command":    "source.fetch",
		"payload":    map[string]any{"definition_id": definitionID, "source_id": "src-private-notes"},
	}))
	restoredSource, _ := restored["source"].(map[string]any)
	restoredText, _ := restoredSource["payload"].(map[string]any)["inline"].(string)
	restoredAnchor, _ := restoredSource["anchors"].([]any)[0].(map[string]any)
	rs, re := int(restoredAnchor["start"].(float64)), int(restoredAnchor["end"].(float64))
	if restoredText[rs:re] != privateQuote {
		t.Errorf("the repaired anchor span %d..%d does not contain the excerpt it names", rs, re)
	}

	// A repair of material that says the same sentence twice keeps the
	// occurrence the capture chose. The span travelled in the inventory, so
	// nothing has to be re-derived; re-deriving it would have refused this
	// source as ambiguous even though the hash proves the bytes are the same.
	repairedDoubled := payloadOf(t, hostB.command(5, schemas, map[string]any{
		"request_id":    "b-repair-doubled",
		"command":       "source.capture",
		"base_revision": storeB.Revision(),
		"payload": map[string]any{
			"definition_id":   definitionID,
			"source_id":       "src-doubled",
			"source_revision": 1,
			"text":            doubledNote,
		},
	}))
	if flag, _ := repairedDoubled["repaired"].(bool); !flag {
		t.Fatalf("a repeated sentence must not stop a hash-proven repair: %v", repairedDoubled)
	}
	// Naming the revision is how a past contribution is read against the bytes
	// it actually saw. Omitting it answers with the NEWEST capture instead —
	// here the caller-placed revision 2, which sits on the other telling — so
	// the two fetches are also the oracle for that distinction.
	doubledBack := payloadOf(t, hostB.command(6, schemas, map[string]any{
		"request_id": "b-fetch-doubled",
		"command":    "source.fetch",
		"payload":    map[string]any{"definition_id": definitionID, "source_id": "src-doubled", "source_revision": 1},
	}))
	doubledAnchor, _ := doubledBack["source"].(map[string]any)["anchors"].([]any)[0].(map[string]any)
	if got := int(doubledAnchor["start"].(float64)); got != secondTelling {
		t.Errorf("the repair moved the anchor from %d to %d; a citation now points at the other telling", secondTelling, got)
	}
	newestDoubled := payloadOf(t, hostB.command(7, schemas, map[string]any{
		"request_id": "b-fetch-doubled-newest",
		"command":    "source.fetch",
		"payload":    map[string]any{"definition_id": definitionID, "source_id": "src-doubled"},
	}))
	newestCapture, _ := newestDoubled["source"].(map[string]any)
	if got, _ := newestCapture["source_revision"].(float64); int(got) != 2 {
		t.Fatalf("a fetch with no revision must answer with the newest capture, got revision %v", newestCapture["source_revision"])
	}
	newestAnchor, _ := newestCapture["anchors"].([]any)[0].(map[string]any)
	if got, _ := newestAnchor["start"].(float64); int(got) != firstTelling {
		t.Errorf("the newest capture's anchor is at %v; the caller placed it at %d", newestAnchor["start"], firstTelling)
	}
}

// deepCopyJSON copies a record through JSON so a test can edit one field of a
// payload it has already sent without reaching into the engine's state.
func deepCopyJSON(t *testing.T, value map[string]any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}
