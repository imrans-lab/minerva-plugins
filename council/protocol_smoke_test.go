package main

import (
	"encoding/json"
	"io"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ipeerbhai/plugins/council/fixtures"
	"github.com/ipeerbhai/plugins/council/internal/contract"
	"github.com/ipeerbhai/plugins/council/internal/session"
)

// fakeHost drives the real serve loop over a pair of pipes, the way Minerva
// drives the process over stdin/stdout. It is the only test double here: the
// protocol needs a peer, and everything on this side of the pipe — the loop,
// the registry, the engine, the schemas — is production code.
//
// It routes replies by id rather than reading them in order, because the loop
// it drives answers several requests at once: a Council round is a long
// tools/call, and the reads and cancels that make it bearable are answered
// while it runs. A harness that assumed one reply per request would be
// asserting a property the backend no longer has.
type fakeHost struct {
	t    *testing.T
	enc  *json.Encoder
	in   *io.PipeWriter
	done chan error

	mu      sync.Mutex
	waiting map[string]chan map[string]any
	// unaddressed carries the replies that answer no request of ours: the
	// null-id errors a malformed line draws.
	unaddressed chan map[string]any
}

func newFakeHost(t *testing.T, store *session.Store) *fakeHost {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	done := make(chan error, 1)
	go func() {
		err := serve(inR, outW, newRegistry(store), nil, nil)
		_ = outW.Close()
		done <- err
	}()
	h := &fakeHost{
		t:           t,
		enc:         json.NewEncoder(inW),
		in:          inW,
		done:        done,
		waiting:     map[string]chan map[string]any{},
		unaddressed: make(chan map[string]any, 8),
	}
	go h.route(json.NewDecoder(outR))
	return h
}

// route reads every response the backend writes and hands it to whoever is
// waiting on its id.
func (h *fakeHost) route(dec *json.Decoder) {
	for {
		var response map[string]any
		if err := dec.Decode(&response); err != nil {
			h.mu.Lock()
			for id, waiter := range h.waiting {
				close(waiter)
				delete(h.waiting, id)
			}
			h.mu.Unlock()
			return
		}
		key := ""
		if raw, ok := response["id"].(float64); ok {
			key = strconv.Itoa(int(raw))
		}
		h.mu.Lock()
		waiter, found := h.waiting[key]
		delete(h.waiting, key)
		h.mu.Unlock()
		if found {
			waiter <- response
			continue
		}
		select {
		case h.unaddressed <- response:
		default:
		}
	}
}

// await blocks for one reply, with a bound so a lost reply fails as itself
// rather than as the whole suite timing out.
func (h *fakeHost) await(waiter chan map[string]any, what string) map[string]any {
	h.t.Helper()
	select {
	case response, open := <-waiter:
		if !open {
			h.t.Fatalf("%s: the backend closed its stream without answering", what)
		}
		return response
	case <-time.After(60 * time.Second):
		h.t.Fatalf("%s: no reply within 60s", what)
		return nil
	}
}

// rpc sends one JSON-RPC request and returns the response it draws.
func (h *fakeHost) rpc(id int, method string, params map[string]any) map[string]any {
	h.t.Helper()
	waiter := make(chan map[string]any, 1)
	h.mu.Lock()
	h.waiting[strconv.Itoa(id)] = waiter
	h.mu.Unlock()

	msg := map[string]any{"jsonrpc": "2.0", "id": id, "method": method}
	if params != nil {
		msg["params"] = params
	}
	h.mu.Lock()
	err := h.enc.Encode(msg)
	h.mu.Unlock()
	if err != nil {
		h.t.Fatalf("%s: write: %v", method, err)
	}
	return h.await(waiter, method)
}

// notify sends a notification, which draws no reply.
func (h *fakeHost) notify(method string) {
	h.t.Helper()
	h.mu.Lock()
	defer h.mu.Unlock()
	if err := h.enc.Encode(map[string]any{"jsonrpc": "2.0", "method": method}); err != nil {
		h.t.Fatalf("%s: write: %v", method, err)
	}
}

// writeRaw sends a line that is not valid JSON, to exercise the parse-error
// path. Its answer carries a null id and so addresses no request of ours.
func (h *fakeHost) writeRaw(line string) map[string]any {
	h.t.Helper()
	h.mu.Lock()
	_, err := h.in.Write([]byte(line + "\n"))
	h.mu.Unlock()
	if err != nil {
		h.t.Fatalf("write raw: %v", err)
	}
	select {
	case response := <-h.unaddressed:
		return response
	case <-time.After(60 * time.Second):
		h.t.Fatal("no reply to a malformed line within 60s")
		return nil
	}
}

// call runs a tools/call and decodes the JSON body the tool returned, together
// with whether the result was flagged isError.
func (h *fakeHost) call(id int, name string, args map[string]any) (map[string]any, bool) {
	h.t.Helper()
	response := h.rpc(id, "tools/call", map[string]any{"name": name, "arguments": args})
	if response["error"] != nil {
		h.t.Fatalf("%s: protocol error %v", name, response["error"])
	}
	result, _ := response["result"].(map[string]any)
	content, _ := result["content"].([]any)
	if len(content) != 1 {
		h.t.Fatalf("%s: expected one content part, got %v", name, result["content"])
	}
	text, _ := content[0].(map[string]any)["text"].(string)
	var body map[string]any
	if err := json.Unmarshal([]byte(text), &body); err != nil {
		h.t.Fatalf("%s: tool body is not JSON: %v (%s)", name, err, text)
	}
	isError, _ := result["isError"].(bool)
	return body, isError
}

// command issues one protocol command through the tool door and checks that the
// reply is a well-formed envelope. The oracle is envelope.schema.json plus its
// invariants — the same validator the engine itself runs — so a reply shape
// that drifts from the contract fails here rather than in a panel.
func (h *fakeHost) command(id int, registry *contract.Registry, args map[string]any) map[string]any {
	h.t.Helper()
	body, isError := h.call(id, "minerva_council_command", args)
	if isError {
		h.t.Fatalf("command %v: transport error %v", args["command"], body["error"])
	}
	raw, err := json.Marshal(body)
	if err != nil {
		h.t.Fatal(err)
	}
	if errs := registry.ValidateRecord("council_envelope", raw); len(errs) > 0 {
		h.t.Fatalf("command %v: reply is not a valid envelope: %v", args["command"], errs)
	}
	return body
}

func revisionOf(t *testing.T, reply map[string]any) int {
	t.Helper()
	revision, ok := reply["snapshot_revision"].(float64)
	if !ok {
		t.Fatalf("reply carries no snapshot_revision: %v", reply)
	}
	return int(revision)
}

func mustFail(t *testing.T, reply map[string]any, code string) {
	t.Helper()
	if ok, _ := reply["ok"].(bool); ok {
		t.Fatalf("expected a failure with code %q, got a success: %v", code, reply)
	}
	failure, _ := reply["error"].(map[string]any)
	if got, _ := failure["code"].(string); got != code {
		t.Fatalf("expected error code %q, got %v", code, failure)
	}
}

// TestStdioProtocolEndToEnd proves the backend speaks the whole protocol over
// one live stdio stream: the handshake, the tool surface, a create/edit/read
// command sequence, idempotent replay, a stale-revision refusal, three kinds of
// malformed input, the acknowledged state the host persists, the interruption
// rule on reload, and a clean shutdown — with the server still answering after
// every fault.
//
// Oracles, none of them a golden string:
//   - the handshake reports serverVersion, which manifest.json pins (below);
//   - every command reply is validated against envelope.schema.json;
//   - the exported snapshot is validated against project_snapshot.schema.json
//     and its cross-field invariants;
//   - the council fed in is the shipped definition_workshop fixture, which the
//     contract tests already prove valid;
//   - the revision arithmetic is checked against the replies themselves, so the
//     test cannot pass by agreeing with a constant it also wrote.
func TestStdioProtocolEndToEnd(t *testing.T) {
	schemas, err := contract.LoadRegistry()
	if err != nil {
		t.Fatalf("load schemas: %v", err)
	}
	store, err := session.New()
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	// A fixed clock makes every minted record exactly comparable.
	store.SetClock(func() string { return time.Date(2026, 9, 8, 12, 0, 0, 0, time.UTC).Format("2006-01-02T15:04:05Z") })

	host := newFakeHost(t, store)

	// --- handshake -------------------------------------------------------
	initialize, _ := host.rpc(1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})["result"].(map[string]any)
	if initialize["protocolVersion"] != protocolVersion {
		t.Fatalf("initialize: protocolVersion %v", initialize["protocolVersion"])
	}
	info, _ := initialize["serverInfo"].(map[string]any)
	if info["name"] != serverName || info["version"] != serverVersion {
		t.Fatalf("initialize: serverInfo %v", info)
	}
	host.notify("notifications/initialized")

	// --- tools/list ------------------------------------------------------
	listed, _ := host.rpc(2, "tools/list", nil)["result"].(map[string]any)
	tools, _ := listed["tools"].([]any)
	if len(tools) == 0 {
		t.Fatal("tools/list returned nothing")
	}
	for _, entry := range tools {
		name, _ := entry.(map[string]any)["name"].(string)
		if !strings.HasPrefix(name, "minerva_council_") {
			t.Fatalf("tool %q does not carry the minerva_council_ prefix the host requires", name)
		}
	}

	if body, isError := host.call(3, "minerva_council_ping", map[string]any{"echo": "hello"}); isError || body["echo"] != "hello" {
		t.Fatalf("ping: %v", body)
	}

	// --- create: a council, then a session on it -------------------------
	var definition map[string]any
	raw, err := fixtures.FS.ReadFile("definition_workshop.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	if err := json.Unmarshal(raw, &definition); err != nil {
		t.Fatal(err)
	}
	definitionID, _ := definition["definition_id"].(string)

	base := store.Revision()
	upsert := host.command(4, schemas, map[string]any{
		"request_id":    "req-upsert",
		"command":       "definition.upsert",
		"base_revision": base,
		"payload":       map[string]any{"definition": definition},
	})
	if ok, _ := upsert["ok"].(bool); !ok {
		t.Fatalf("definition.upsert: %v", upsert)
	}
	if got := revisionOf(t, upsert); got != base+1 {
		t.Fatalf("an accepted mutation must advance the snapshot: %d -> %d", base, got)
	}

	created := host.command(5, schemas, map[string]any{
		"request_id":    "req-session",
		"command":       "session.create",
		"base_revision": revisionOf(t, upsert),
		"payload": map[string]any{
			"session_id":    "ses-smoke",
			"definition_id": definitionID,
			"question":      "Should the workshop take the recurring order?",
			"chat_id":       "chat-7",
		},
	})
	if ok, _ := created["ok"].(bool); !ok {
		t.Fatalf("session.create: %v", created)
	}

	// --- edit: start a run, then replay the same request_id ---------------
	started := host.command(6, schemas, map[string]any{
		"request_id":    "req-run",
		"command":       "run.start",
		"base_revision": revisionOf(t, created),
		"payload": map[string]any{
			"session_id":        "ses-smoke",
			"kind":              "follow_up",
			"addressed_seat_id": "seat-capacity",
			"prompt":            "What would the order cost in refusals?",
		},
	})
	if ok, _ := started["ok"].(bool); !ok {
		t.Fatalf("run.start: %v", started)
	}
	runID, _ := started["payload"].(map[string]any)["run_id"].(string)
	if runID == "" {
		t.Fatalf("run.start returned no run_id: %v", started)
	}
	// run.start consults the members before it answers, and this Store has no
	// chat host bound. The oracle is the record's own failure enum: a backend
	// with no route to a model says model_unavailable against the seat, and the
	// run rests failed rather than hanging or claiming an answer.
	if got, _ := started["payload"].(map[string]any)["status"].(string); got != "failed" {
		t.Fatalf("with no host bound the round must rest failed, got %q: %v", got, started["payload"])
	}
	startedContributions, _ := started["payload"].(map[string]any)["contributions"].([]any)
	if len(startedContributions) != 1 {
		t.Fatalf("the follow-up consults one seat, got %v", startedContributions)
	}
	firstFailure, _ := startedContributions[0].(map[string]any)["failure"].(map[string]any)
	if code, _ := firstFailure["code"].(string); code != session.CodeModelUnavailable {
		t.Fatalf("an unbound backend must report model_unavailable, got %v", firstFailure)
	}
	if _, present := started["payload"].(map[string]any)["synthesis"]; present {
		t.Fatalf("nobody answered, so there is nothing to synthesise: %v", started["payload"])
	}

	replayed := host.command(7, schemas, map[string]any{
		"request_id":    "req-run",
		"command":       "run.start",
		"base_revision": revisionOf(t, started),
		"payload":       map[string]any{"session_id": "ses-smoke", "kind": "initial_round"},
	})
	if flag, _ := replayed["replayed"].(bool); !flag {
		t.Fatalf("a repeated request_id must return the stored reply: %v", replayed)
	}
	if got, _ := replayed["payload"].(map[string]any)["run_id"].(string); got != runID {
		t.Fatalf("replay minted a second run: %q vs %q", got, runID)
	}
	if got := revisionOf(t, replayed); got != revisionOf(t, started) {
		t.Fatalf("replay advanced the snapshot: %d", got)
	}

	// --- stale: a command written against an older view is refused --------
	stale := host.command(8, schemas, map[string]any{
		"request_id":    "req-stale",
		"command":       "session.bind_chat",
		"base_revision": base,
		"payload":       map[string]any{"session_id": "ses-smoke", "chat_id": "chat-9"},
	})
	mustFail(t, stale, session.CodeStaleRevision)
	if got := revisionOf(t, stale); got != store.Revision() {
		t.Fatalf("a stale reply must carry the current revision so the view can re-read: %d", got)
	}
	if retryable, _ := stale["error"].(map[string]any)["retryable"].(bool); !retryable {
		t.Fatalf("a stale revision is retryable: %v", stale["error"])
	}

	// --- malformed: an unknown command, and a line that is not JSON -------
	unknown := host.command(9, schemas, map[string]any{
		"request_id": "req-unknown",
		"command":    "council.explode",
		"payload":    map[string]any{},
	})
	mustFail(t, unknown, session.CodeInternal)

	parseError := host.writeRaw("{ this is not json")
	failure, _ := parseError["error"].(map[string]any)
	if code, _ := failure["code"].(float64); int(code) != -32700 {
		t.Fatalf("a malformed line must be a JSON-RPC parse error, got %v", parseError)
	}

	// A line above the reader's limit is discarded and answered rather than
	// ending the loop. The assertion that matters is not the error code but the
	// fact that every later step below still gets a reply.
	oversize := host.writeRaw(strings.Repeat("a", maxLine+1))
	failure, _ = oversize["error"].(map[string]any)
	if code, _ := failure["code"].(float64); int(code) != -32600 {
		t.Fatalf("an oversized line must be an invalid-request error, got %v", oversize)
	}

	// --- refusal: a command whose result would break the contract ---------
	// outcome.retain does not itself check that the contribution belongs to the
	// run; the whole-snapshot validation does. So this is the one command that
	// reaches the commit gate with a record-valid change and an invalid result,
	// which is exactly the branch under test: the snapshot must be left alone.
	before := store.Revision()
	refused := host.command(10, schemas, map[string]any{
		"request_id":    "req-bad-outcome",
		"command":       "outcome.retain",
		"base_revision": before,
		"payload": map[string]any{
			"session_id":      "ses-smoke",
			"run_id":          runID,
			"contribution_id": "con-nope",
			"note_ref":        "note-1",
		},
	})
	mustFail(t, refused, session.CodeInternal)
	if got := revisionOf(t, refused); got != before {
		t.Fatalf("a refused command must not advance the snapshot: %d -> %d", before, got)
	}
	if store.Revision() != before {
		t.Fatalf("a refused command left the store at revision %d, want %d", store.Revision(), before)
	}
	afterRefusal := host.command(11, schemas, map[string]any{
		"request_id": "req-after-refusal",
		"command":    "snapshot.get",
		"payload":    map[string]any{},
	})
	kept, _ := afterRefusal["payload"].(map[string]any)["snapshot"].(map[string]any)
	keptSessions, _ := kept["sessions"].([]any)
	outcomes, _ := keptSessions[0].(map[string]any)["outcomes"].([]any)
	if len(outcomes) != 0 {
		t.Fatalf("the refused outcome was stored anyway: %v", outcomes)
	}

	// --- read: the snapshot the host would persist ------------------------
	read := host.command(12, schemas, map[string]any{
		"request_id": "req-read",
		"command":    "snapshot.get",
		"payload":    map[string]any{},
	})
	if ok, _ := read["ok"].(bool); !ok {
		t.Fatalf("snapshot.get: %v", read)
	}

	exported, isError := host.call(13, "minerva_council_export_snapshot", map[string]any{})
	if isError {
		t.Fatalf("export: %v", exported)
	}
	snapshot, _ := exported["snapshot"].(map[string]any)
	snapshotRaw, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if errs := schemas.ValidateRecord("council_project_snapshot", snapshotRaw); len(errs) > 0 {
		t.Fatalf("the acknowledged snapshot does not satisfy its own contract: %v", errs)
	}
	if int(snapshot["snapshot_revision"].(float64)) != store.Revision() {
		t.Fatalf("the exported snapshot is not at the acknowledged revision: %v", snapshot["snapshot_revision"])
	}

	// --- reload: work left in flight is demoted, never resumed ------------
	// The run above reached rest inside the command that started it, so nothing
	// in the exported document is in flight. An interrupted document is what a
	// killed process leaves behind — a run still saying "running" — and the
	// engine never persists one, so the test builds it from the record it just
	// exported. It is a valid council_project_snapshot; that is the point.
	interrupted := interruptedCopy(t, snapshot)
	restoredFrom := int(interrupted["snapshot_revision"].(float64))
	reloaded, isError := host.call(14, "minerva_council_load_snapshot", map[string]any{"snapshot": interrupted})
	if isError {
		t.Fatalf("load: %v", reloaded)
	}
	if demoted, _ := reloaded["runs_demoted"].(float64); demoted != 1 {
		t.Fatalf("the pending run must be demoted on load, got runs_demoted=%v", reloaded["runs_demoted"])
	}
	// Demotion rewrote the document, so it must not still claim the revision it
	// was restored at — otherwise two different snapshots share one revision.
	if got, _ := reloaded["snapshot_revision"].(float64); int(got) != restoredFrom+1 {
		t.Fatalf("a demoting load must advance the revision: restored %d, reported %v", restoredFrom, reloaded["snapshot_revision"])
	}
	status, isError := host.call(15, "minerva_council_status", map[string]any{})
	if isError {
		t.Fatalf("status: %v", status)
	}
	sessions, _ := status["sessions"].([]any)
	if len(sessions) != 1 {
		t.Fatalf("status: expected one session, got %v", sessions)
	}
	if got, _ := sessions[0].(map[string]any)["status"].(string); got != "partial" {
		t.Fatalf("a session whose run was interrupted must read partial, got %q", got)
	}

	// --- the shipped populated document loads through the real backend ----
	// This is the fixture the owner's live check opens. Loading it here proves
	// the same file the panel is pointed at is one this engine accepts, and the
	// round trip proves the architecture's corollary: a valid record loads
	// UNCHANGED and at the same revision, because with the derivation invariant
	// in force there is nothing left for rehydration to fix.
	var populated map[string]any
	if err := json.Unmarshal(readFixture(t, "workshop_complete.mcouncil"), &populated); err != nil {
		t.Fatalf("the populated fixture is not JSON: %v", err)
	}
	loadedPopulated, isError := host.call(16, "minerva_council_load_snapshot", map[string]any{"snapshot": populated})
	if isError {
		t.Fatalf("the populated .mcouncil fixture did not load: %v", loadedPopulated)
	}
	if demoted, _ := loadedPopulated["runs_demoted"].(float64); demoted != 0 {
		t.Fatalf("nothing in the populated fixture is in flight, so nothing may be demoted: %v", loadedPopulated)
	}
	if got, _ := loadedPopulated["snapshot_revision"].(float64); int(got) != int(populated["snapshot_revision"].(float64)) {
		t.Fatalf("a valid document must load at its own revision: %v vs %v", got, populated["snapshot_revision"])
	}
	if got, _ := loadedPopulated["sessions"].(float64); int(got) != 1 {
		t.Fatalf("the populated fixture holds one session, the backend read %v", loadedPopulated["sessions"])
	}
	roundTripped, isError := host.call(17, "minerva_council_export_snapshot", map[string]any{})
	if isError {
		t.Fatalf("export after loading the populated fixture: %v", roundTripped)
	}
	if !reflect.DeepEqual(roundTripped["snapshot"], any(populated)) {
		t.Fatal("the populated fixture did not survive load/export unchanged")
	}
	populatedStatus, isError := host.call(18, "minerva_council_status", map[string]any{})
	if isError {
		t.Fatalf("status after loading the populated fixture: %v", populatedStatus)
	}
	populatedSessions, _ := populatedStatus["sessions"].([]any)
	if len(populatedSessions) != 1 {
		t.Fatalf("expected one session, got %v", populatedSessions)
	}
	// The fixture's last run completed, so the derivation says complete. A
	// fixture whose stored status disagreed would already have been refused by
	// the load above; this checks the value a person will see in the panel.
	if got, _ := populatedSessions[0].(map[string]any)["status"].(string); got != "complete" {
		t.Fatalf("the populated fixture's session must read complete, got %q", got)
	}

	// --- shutdown ---------------------------------------------------------
	shutdown := host.rpc(19, "shutdown", nil)
	if result, _ := shutdown["result"].(map[string]any); result == nil {
		t.Fatalf("shutdown: %v", shutdown)
	}
	_ = host.in.Close()
	select {
	case err := <-host.done:
		if err != nil {
			t.Fatalf("serve returned an error on shutdown: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("serve did not return after shutdown")
	}
}

// readFixture reads one shipped example. The fixtures are the worked examples
// the architecture document points at, so a test that uses one is testing the
// thing a reader was told to expect.
func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := fixtures.FS.ReadFile(name)
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return raw
}

// interruptedCopy returns the document a killed process leaves behind: a run
// still claiming to be running, with the session status the derivation gives
// for it. It is built by hand because the engine never writes one — a run
// reaches rest inside the command that started it — and the interruption rule
// has to be tested against the state it exists for.
func interruptedCopy(t *testing.T, snapshot map[string]any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	var copied map[string]any
	if err := json.Unmarshal(raw, &copied); err != nil {
		t.Fatal(err)
	}
	sessions, _ := copied["sessions"].([]any)
	if len(sessions) == 0 {
		t.Fatal("no session to interrupt")
	}
	interruptedSession, _ := sessions[0].(map[string]any)
	runs, _ := interruptedSession["runs"].([]any)
	if len(runs) == 0 {
		t.Fatal("no run to interrupt")
	}
	run, _ := runs[len(runs)-1].(map[string]any)
	run["status"] = "running"
	delete(run, "failure")
	delete(run, "ended_at")
	for _, c := range run["contributions"].([]any) {
		contribution, _ := c.(map[string]any)
		contribution["status"] = "running"
		delete(contribution, "failure")
	}
	interruptedSession["status"] = "running"
	return copied
}
