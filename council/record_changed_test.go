package main

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/ipeerbhai/plugins/council/fixtures"
	"github.com/ipeerbhai/plugins/council/internal/contract"
	"github.com/ipeerbhai/plugins/council/internal/session"
)

// awaitNotice takes the next notification the backend wrote — a message with a
// method and no id — or fails by name.
func (h *fakeHost) awaitNotice(what string) map[string]any {
	h.t.Helper()
	select {
	case notice := <-h.notices:
		return notice
	case <-time.After(30 * time.Second):
		h.t.Fatalf("%s: the backend announced nothing within 30s", what)
		return nil
	}
}

// noNotice asserts that nothing is announced in `window`. The window is short
// because the claim is about a command that must not announce at all, not about
// how fast one that does gets there.
func (h *fakeHost) noNotice(what string, window time.Duration) {
	h.t.Helper()
	select {
	case notice := <-h.notices:
		h.t.Fatalf("%s: the backend announced %v", what, notice)
	case <-time.After(window):
	}
}

// recordChange reads a record-changed notification into the two fields that
// carry its whole meaning, failing if it is not one.
func recordChange(t *testing.T, notice map[string]any) (string, int) {
	t.Helper()
	if notice["method"] != "minerva/plugin_event" {
		t.Fatalf("notification is not a plugin event: %v", notice)
	}
	if _, hasID := notice["id"]; hasID {
		t.Fatalf("a notification carries no id, and the host would try to answer one: %v", notice)
	}
	params, _ := notice["params"].(map[string]any)
	if params["event"] != recordChangedEvent {
		t.Fatalf("notification names event %v, not %s", params["event"], recordChangedEvent)
	}
	payload, _ := params["payload"].(map[string]any)
	project, _ := payload["project_id"].(string)
	revision, ok := payload["snapshot_revision"].(float64)
	if !ok {
		t.Fatalf("notification carries no snapshot_revision: %v", payload)
	}
	return project, int(revision)
}

// TestACommitWithNoPanelAnnouncesTheDocumentThatMoved proves the change signal
// the wrapper's convergence hangs on: a mutation applied through the tool door
// — nobody's panel in the exchange, which is what a chat turn and an MCP call
// are — puts a `minerva/plugin_event` on the real stdio stream naming the
// document that moved and the revision it moved to, and a read announces
// nothing.
//
// Oracles, none of them a constant this test also wrote:
//   - the project_id asserted is the one minerva_council_load_snapshot itself
//     reported for the document it loaded;
//   - the revision asserted is the one the command's own reply envelope carried,
//     so the notification cannot pass by agreeing with a number in this file;
//   - the second document's notification is checked against the second load's
//     project_id, so a signal that named "whatever was last loaded" rather than
//     the document that committed would fail here;
//   - the envelope shape is checked against envelope.schema.json through
//     host.command, as everywhere else.
func TestACommitWithNoPanelAnnouncesTheDocumentThatMoved(t *testing.T) {
	schemas, err := contract.LoadRegistry()
	if err != nil {
		t.Fatalf("load schemas: %v", err)
	}
	store, err := session.New()
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	host := newFakeHost(t, store)
	host.rpc(1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})

	first, sessionID := loadDocument(t, host, 2, "prj-signal-one")

	// A read moves nothing, so it must announce nothing. Without this the test
	// would pass for a backend that simply announced on every call.
	read := host.command(3, schemas, map[string]any{
		"request_id": "req-read", "command": "snapshot.get", "payload": map[string]any{},
	})
	if ok, _ := read["ok"].(bool); !ok {
		t.Fatalf("snapshot.get: %v", read)
	}
	host.noNotice("a read", 250*time.Millisecond)

	// THE MUTATION WITH NO PANEL. session.bind_chat is the cheapest command
	// that commits; a chat turn and a direct tool call reach the same commit.
	bound := host.command(4, schemas, map[string]any{
		"request_id":    "req-bind",
		"command":       "session.bind_chat",
		"base_revision": revisionOf(t, read),
		"payload":       map[string]any{"session_id": sessionID, "chat_id": "chat-signal"},
	})
	if ok, _ := bound["ok"].(bool); !ok {
		t.Fatalf("session.bind_chat: %v", bound)
	}
	project, revision := recordChange(t, host.awaitNotice("a mutation with no panel"))
	if project != first {
		t.Fatalf("the signal named document %q; the engine moved %q", project, first)
	}
	if revision != revisionOf(t, bound) {
		t.Fatalf("the signal named revision %d; the command's own reply says %d",
			revision, revisionOf(t, bound))
	}

	// ANOTHER DOCUMENT. The engine holds one at a time, so the signal has to
	// name the document that committed rather than "the panel that last spoke".
	second, secondSession := loadDocument(t, host, 5, "prj-signal-two")
	if second == first {
		t.Fatalf("the two fixtures share a project identity (%s), so this section proves nothing", second)
	}
	host.noNotice("a load", 250*time.Millisecond)

	elsewhere := host.command(6, schemas, map[string]any{
		"request_id":    "req-bind-two",
		"command":       "session.bind_chat",
		"base_revision": store.Revision(),
		"payload":       map[string]any{"session_id": secondSession, "chat_id": "chat-elsewhere"},
	})
	if ok, _ := elsewhere["ok"].(bool); !ok {
		t.Fatalf("session.bind_chat on the second document: %v", elsewhere)
	}
	project, revision = recordChange(t, host.awaitNotice("a mutation on the second document"))
	if project != second {
		t.Fatalf("the signal named document %q; the engine moved %q", project, second)
	}
	if revision != revisionOf(t, elsewhere) {
		t.Fatalf("the signal named revision %d; the command's own reply says %d",
			revision, revisionOf(t, elsewhere))
	}
}

// loadDocument hands the backend the shipped project snapshot under its own
// project identity, the way a panel seeds the engine, and returns the
// project_id the LOAD REPORTED — which is what makes it an oracle rather than
// an echo of the fixture — together with the session the caller can mutate.
func loadDocument(t *testing.T, host *fakeHost, id int, projectID string) (string, string) {
	t.Helper()
	raw, err := fixtures.FS.ReadFile("project_snapshot.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var record map[string]any
	if err := json.Unmarshal(raw, &record); err != nil {
		t.Fatal(err)
	}
	record["project_id"] = projectID
	sessions, _ := record["sessions"].([]any)
	if len(sessions) == 0 {
		t.Fatal("the fixture holds no session to bind")
	}
	first, _ := sessions[0].(map[string]any)
	sessionID, _ := first["session_id"].(string)
	delete(record, "view")

	body, isError := host.call(id, "minerva_council_load_snapshot",
		map[string]any{"snapshot": record, "mode": "replace"})
	if isError {
		t.Fatalf("load: %v", body)
	}
	loaded, _ := body["project_id"].(string)
	if loaded == "" || sessionID == "" {
		t.Fatalf("load reported no project_id, or the fixture no session: %v", body)
	}
	return loaded, sessionID
}
