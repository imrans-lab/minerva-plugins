package main

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/ipeerbhai/plugins/council/fixtures"
	"github.com/ipeerbhai/plugins/council/internal/session"
)

// Council as a chat provider, end to end over the shipped protocol loop: one
// turn, a continuation, the council choice, the cross-project refusal, the
// cancel path and the startup handshake. The host it runs against is
// provider_host_test.go, and every assertion below names the host behaviour it
// is an oracle for.
// ---------------------------------------------------------------------------
// the test
// ---------------------------------------------------------------------------

func TestCouncilAnswersAsAChatProvider(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)

	host.rpc(1, "initialize", map[string]any{})

	// -------------------------------------------------------------------
	// 1. Registration
	//
	// Oracle: CapabilityBroker._handle_host_chat_providers_register
	// (CapabilityBroker.gd:3544-3592). entry_id, display_name, generate_tool
	// and history_mode are required; history_mode must be one of two strings;
	// generate_tool and cancel_tool must carry this plugin's own tool prefix.
	// Anything this test lets through that the broker would refuse is a
	// registration that silently never happens on a real install.
	// -------------------------------------------------------------------
	registration := host.awaitCapability("host.chat_providers.register")
	for _, required := range []string{"entry_id", "display_name", "generate_tool", "history_mode"} {
		if str(registration.Args[required]) == "" {
			t.Errorf("the broker requires %q and refuses the registration without it: %v", required, registration.Args)
		}
	}
	if mode := str(registration.Args["history_mode"]); mode != "newest_only" && mode != "full" {
		t.Errorf("history_mode must be newest_only or full; got %q", mode)
	}
	for _, key := range []string{"generate_tool", "cancel_tool"} {
		if name := str(registration.Args[key]); !strings.HasPrefix(name, "minerva_council_") {
			t.Errorf("the broker refuses a %s outside this plugin's prefix; got %q", key, name)
		}
	}
	// The tools it names have to exist, or the entry is a dead end the user
	// only discovers by selecting Council and getting nothing.
	advertised := map[string]bool{}
	listed := host.rpc(2, "tools/list", map[string]any{})
	for _, x := range listed["result"].(map[string]any)["tools"].([]any) {
		advertised[str(x.(map[string]any)["name"])] = true
	}
	for _, key := range []string{"generate_tool", "cancel_tool"} {
		if name := str(registration.Args[key]); !advertised[name] {
			t.Errorf("the entry names %s=%q, which this backend does not advertise", key, name)
		}
	}
	// A turn must answer inside the entry's own declared budget. The registry
	// would otherwise use 600 s (PluginChatProviderRegistry.gd:32); what
	// matters either way is that Council's own wait is comfortably under
	// whatever it declared, because a reply that lands after the host stops
	// waiting is a reply nobody receives.
	declared, _ := registration.Args["timeout_sec"].(float64)
	if declared <= 0 {
		t.Errorf("the entry must declare its own timeout_sec; got %v", registration.Args["timeout_sec"])
	}
	if chatTurnWait >= time.Duration(declared)*time.Second {
		t.Errorf("a turn waits %s but the entry declared %vs; the reply would arrive after the host gave up", chatTurnWait, declared)
	}

	// -------------------------------------------------------------------
	// 2. Model discovery
	//
	// Oracle: CapabilityBroker.gd:565-576 — list_providers takes no args and
	// answers {providers:[{key, display}]}; list_models REQUIRES a "provider"
	// key and answers {provider, models:[{model_name, display}]}.
	// -------------------------------------------------------------------
	host.awaitCapability("host.models.list_providers")
	asked := map[string]bool{}
	for _, call := range host.capabilityCalls("host.models.list_models") {
		if str(call.Args["provider"]) == "" {
			t.Error("list_models is refused without a provider key")
		}
		asked[str(call.Args["provider"])] = true
	}
	if !asked["openai"] || !asked["anthropic"] {
		t.Errorf("every enabled provider must be listed before its models can be offered; asked %v", asked)
	}
	catalogue := host.tool(3, "minerva_council_models", map[string]any{})
	if known, _ := catalogue["known"].(bool); !known {
		t.Fatalf("the catalogue was read, so it must report known:true: %v", catalogue)
	}
	names := map[string]bool{}
	for _, x := range catalogue["models"].([]any) {
		entry := x.(map[string]any)
		names[str(entry["model_name"])] = true
		// The provider display, not the key, is what host.providers.chat
		// compares its own "provider" argument against
		// (CapabilityBroker.gd:2427-2432). Carrying only the key would make a
		// model two providers both offer unaddressable.
		if str(entry["provider_display"]) == "" {
			t.Errorf("a catalogue entry must carry the provider display name: %v", entry)
		}
	}
	if !names["gpt-test"] || !names["claude-test"] {
		t.Errorf("the catalogue must hold every enabled model; got %v", names)
	}

	// -------------------------------------------------------------------
	// 3. A model the host does not have is refused BEFORE anything is spent
	//
	// Oracle: the catalogue just read. The assertion that matters is the call
	// count: a refusal that happened after a round started would have cost the
	// user money to discover.
	// -------------------------------------------------------------------
	var definition map[string]any
	raw, err := fixtures.FS.ReadFile("definition_workshop.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &definition); err != nil {
		t.Fatal(err)
	}
	definitionID := str(definition["definition_id"])
	seeded := host.tool(4, "minerva_council_command", map[string]any{
		"request_id":    "req-def",
		"command":       "definition.upsert",
		"base_revision": store.Revision(),
		"payload":       map[string]any{"definition": definition},
	})
	if ok, _ := seeded["ok"].(bool); !ok {
		t.Fatalf("definition.upsert: %v", seeded)
	}

	refused := host.tool(5, "minerva_council_command", map[string]any{
		"request_id":    "req-bad-hint",
		"command":       "member.upsert",
		"base_revision": store.Revision(),
		"payload": map[string]any{
			"definition_id": definitionID,
			"member": map[string]any{
				"schema_version": 1, "record_kind": "council_member",
				"member_id": "mem-okonkwo", "kind": "simulant",
				"represents": "A workshop capacity planner",
				"model_hint": "gpt-nonexistent",
			},
		},
	})
	if ok, _ := refused["ok"].(bool); ok {
		t.Fatalf("a model the host does not have must be refused at member.upsert: %v", refused)
	}
	if code := str(refused["error"].(map[string]any)["code"]); code != session.CodeModelUnavailable {
		t.Errorf("an unavailable model is model_unavailable, not %q", code)
	}
	if message := str(refused["error"].(map[string]any)["message"]); !strings.Contains(message, "gpt-test") {
		t.Errorf("the refusal must name what the user CAN pick, so it is actionable: %q", message)
	}
	if calls := host.modelCalls(); len(calls) != 0 {
		t.Fatalf("a refused hint must consult nobody; the host saw %d model calls", len(calls))
	}

	// -------------------------------------------------------------------
	// 4. One turn: a chat with no session gets one, and the chair answers
	//
	// Oracle: PluginProvider._apply_result_to_bot (PluginProvider.gd:194-221).
	// kind "answer" puts text on the turn; any kind it does not know becomes
	// "unrecognised reply kind" in the user's face.
	// -------------------------------------------------------------------
	const chatA = "chat-project-a"
	answer := host.turn(6, chatA, "How much capacity should the workshop hold?")
	if kind := str(answer["kind"]); kind != session.ChatAnswer {
		t.Fatalf("a finished round answers; got kind %q (%v)", kind, answer)
	}
	if !strings.Contains(str(answer["text"]), "The bench answered.") {
		t.Errorf("the chair's synthesis must reach the chat: %q", answer["text"])
	}
	// Usage is copied onto the turn by the host, so a Council answer has to
	// carry what it cost rather than reporting nothing.
	if tokens, _ := answer["prompt_tokens"].(float64); tokens <= 0 {
		t.Errorf("the round's reported usage must reach the chat; got %v", answer["prompt_tokens"])
	}

	// The binding is in the durable record, not in a variable somewhere.
	sessionA := sessionBoundTo(t, store, chatA)
	if sessionA == "" {
		t.Fatal("the turn must leave a session bound to its chat_id; nothing else can route the next reply")
	}

	// Every model call named a model from the catalogue. "default" is the one
	// answer that must never appear: the host resolves it to a Core provider
	// that may have no service or action behind it
	// (CapabilityBroker.gd:2354-2361, ChatPane.gd:5244-5253).
	calls := host.modelCalls()
	if len(calls) == 0 {
		t.Fatal("the round consulted nobody")
	}
	for _, call := range calls {
		model := str(call["model"])
		if model == "default" || model == "" {
			t.Errorf("the engine must select a model explicitly; a call asked for %q", model)
		}
		if !names[model] {
			t.Errorf("a call asked for %q, which is not in the host's enabled catalogue", model)
		}
	}

	// -------------------------------------------------------------------
	// 5. Continuation stays in the same session
	// -------------------------------------------------------------------
	second := host.turn(7, chatA, "What would change if demand halved?")
	if kind := str(second["kind"]); kind != session.ChatAnswer {
		t.Fatalf("a follow-up answers too; got %v", second)
	}
	if again := sessionBoundTo(t, store, chatA); again != sessionA {
		t.Fatalf("a continuation must reuse the chat's session; %q became %q", sessionA, again)
	}
	if runs := runCount(t, store, sessionA); runs != 2 {
		t.Fatalf("two turns are two runs in one session; got %d", runs)
	}

	// -------------------------------------------------------------------
	// 6. Two chats in two projects do not cross-route
	//
	// Loading another document replaces the working snapshot. The chat above
	// is bound to a session that document does not hold, and the only safe
	// answer is a refusal: opening a fresh session here would write project
	// A's consultation into project B's record.
	// -------------------------------------------------------------------
	otherDocument, err := json.Marshal(map[string]any{
		"schema_version": 1, "record_kind": "council_project_snapshot",
		"snapshot_revision": 1, "definitions": []any{definition}, "sessions": []any{},
	})
	if err != nil {
		t.Fatal(err)
	}
	var restored map[string]any
	if err := json.Unmarshal(otherDocument, &restored); err != nil {
		t.Fatal(err)
	}
	loaded := host.tool(8, "minerva_council_load_snapshot", map[string]any{"snapshot": restored})
	if ok, _ := loaded["ok"].(bool); !ok {
		t.Fatalf("load: %v", loaded)
	}
	crossed := host.turn(9, chatA, "Are you still there?")
	if kind := str(crossed["kind"]); kind != session.ChatError {
		t.Fatalf("a chat bound to another document must be refused, not adopted; got %v", crossed)
	}
	if sessions := sessionCount(t, store); sessions != 0 {
		t.Fatalf("the refusal must create nothing; the document holds %d sessions", sessions)
	}

	// A chat this backend has never routed is new, and opens a session here.
	const chatB = "chat-project-b"
	fresh := host.turn(10, chatB, "What does this workshop cost to run?")
	if kind := str(fresh["kind"]); kind != session.ChatAnswer {
		t.Fatalf("a new chat in the open document must be served; got %v", fresh)
	}
	if sessionBoundTo(t, store, chatB) == "" {
		t.Error("the new chat must be bound to the session it opened")
	}
	if sessionBoundTo(t, store, chatA) != "" {
		t.Error("the refused chat must not have been given a session in this document")
	}
}

// TestCouncilChatOffersACouncilWhenTheProjectHoldsSeveral covers the one place
// Council answers a question with a question.
//
// Oracle: ChatPane._on_passthrough_question_answered (ChatPane.gd:2380-2391)
// and _passthrough_send_question_answer (:2399-2406). The host does NOT tell
// the plugin which label was clicked — it sends the option's KEYSTROKE as an
// ordinary user turn on that same chat. So an option is only usable if its
// keystroke carries the whole choice, and the test asserts exactly that by
// feeding the keystroke back as the next turn.
func TestCouncilChatOffersACouncilWhenTheProjectHoldsSeveral(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)
	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")

	var first map[string]any
	raw, err := fixtures.FS.ReadFile("definition_workshop.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &first); err != nil {
		t.Fatal(err)
	}
	second := map[string]any{}
	if err := json.Unmarshal(raw, &second); err != nil {
		t.Fatal(err)
	}
	second["definition_id"] = "def-second-council"
	second["name"] = "Second Council"

	for i, def := range []map[string]any{first, second} {
		reply := host.tool(2+i, "minerva_council_command", map[string]any{
			"request_id":    "req-def-" + strconv.Itoa(i),
			"command":       "definition.upsert",
			"base_revision": store.Revision(),
			"payload":       map[string]any{"definition": def},
		})
		if ok, _ := reply["ok"].(bool); !ok {
			t.Fatalf("definition.upsert: %v", reply)
		}
	}

	const chatID = "chat-ambiguous"
	const question = "Which capacity should we plan for?"
	asked := host.turn(5, chatID, question)
	if kind := str(asked["kind"]); kind != session.ChatQuestion {
		t.Fatalf("two councils and no choice is a question, not a guess; got %v", asked)
	}
	options, _ := asked["options"].([]any)
	if len(options) != 2 {
		t.Fatalf("every council in the project must be offered; got %v", asked["options"])
	}
	var chosen string
	for _, x := range options {
		option := x.(map[string]any)
		if str(option["label"]) == "" {
			t.Errorf("an option with no label is dropped by the host (ChatPane.gd:2319-2321): %v", option)
		}
		if str(option["keystroke"]) == "" {
			t.Errorf("an empty keystroke is never sent (ChatPane.gd:2389-2390), so the choice would do nothing: %v", option)
		}
		if str(option["label"]) == "Second Council" {
			chosen = str(option["keystroke"])
		}
	}
	if chosen == "" {
		t.Fatal("the second council was not offered by name")
	}
	if sessionCount(t, store) != 0 {
		t.Fatal("asking which council must not have opened a session")
	}

	// The click: the host sends the keystroke as the next user turn.
	answered := host.turn(6, chatID, chosen)
	if kind := str(answered["kind"]); kind != session.ChatAnswer {
		t.Fatalf("choosing a council runs the round; got %v", answered)
	}
	sessionID := sessionBoundTo(t, store, chatID)
	if sessionID == "" {
		t.Fatal("the chosen council's session must be bound to the chat")
	}
	// The user typed their question ONCE. It has to be the session's question,
	// not the directive they clicked afterwards.
	if got := questionOf(t, store, sessionID); got != question {
		t.Fatalf("the remembered question must open the session; got %q", got)
	}
	if got := definitionOf(t, store, sessionID); got != "def-second-council" {
		t.Fatalf("the session must run the council that was chosen; got %q", got)
	}

	// -------------------------------------------------------------------
	// /council-session: one chat has ONE session, and the binding MOVES
	//
	// Oracle: checkSnapshot's "one chat, one session" invariant, and the fact
	// that the provider routes by chat_id alone (PluginProvider.gd:107, :286).
	// If both sessions kept the id, which one a follow-up reached would be
	// decided by the order of an array — which is the bug this covers.
	// -------------------------------------------------------------------
	// A second chat, with its council chosen up front — the project still holds
	// two, so a bare question there would be answered with the same option card.
	picked := host.turn(7, "chat-other", session.SelectCouncilDirective+"def-workshop-economics")
	if kind := str(picked["kind"]); kind != session.ChatAnswer {
		t.Fatalf("choosing a council before asking anything must be acknowledged: %v", picked)
	}
	if sessionBoundTo(t, store, "chat-other") != "" {
		t.Error("choosing a council is not yet a consultation; no session should exist")
	}
	separate := host.turn(8, "chat-other", "A separate consultation.")
	if kind := str(separate["kind"]); kind != session.ChatAnswer {
		t.Fatalf("the second chat must be served: %v", separate)
	}
	otherSession := sessionBoundTo(t, store, "chat-other")
	if otherSession == "" || otherSession == sessionID {
		t.Fatalf("the second chat needs a session of its own; got %q beside %q", otherSession, sessionID)
	}

	moved := host.turn(9, chatID, session.SelectSessionDirective+otherSession)
	if kind := str(moved["kind"]); kind != session.ChatAnswer {
		t.Fatalf("selecting an existing session must succeed: %v", moved)
	}
	// The chat now names exactly one session, and it is the new one.
	if bound := sessionsCarrying(t, store, chatID); len(bound) != 1 || bound[0] != otherSession {
		t.Fatalf("one chat has one session; %q is carried by %v", chatID, bound)
	}
	// And the session it left keeps everything except the binding.
	if runCount(t, store, sessionID) == 0 {
		t.Error("releasing a binding must not touch the session's runs")
	}
	// The follow-up has to LAND there. Asserting the binding alone would not
	// catch a resolver that still reads the old session first.
	followed := host.turn(10, chatID, "And what follows from that?")
	if kind := str(followed["kind"]); kind != session.ChatAnswer {
		t.Fatalf("the follow-up must be answered: %v", followed)
	}
	if runCount(t, store, otherSession) != 2 {
		t.Fatalf("the follow-up must run on the session the chat was moved to; it has %d runs",
			runCount(t, store, otherSession))
	}

	// The other chat is now bound to nothing, and asking in it opens a fresh
	// session rather than silently rejoining the one it lost.
	if left := sessionBoundTo(t, store, "chat-other"); left != "" {
		t.Fatalf("chat-other lost its session to %q and must not still claim one; it claims %q", chatID, left)
	}
}

// sessionsCarrying reports every session recording this chat_id. It returns a
// list rather than the first hit precisely because the property under test is
// that the list is never longer than one.
func sessionsCarrying(t *testing.T, store *session.Store, chatID string) []string {
	t.Helper()
	var found []string
	for _, record := range sessionsOf(t, store) {
		binding, _ := record["chat_binding"].(map[string]any)
		if str(binding["chat_id"]) == chatID {
			found = append(found, str(record["session_id"]))
		}
	}
	return found
}

// TestCouncilChatCancelStopsTheRound drives the host's real cancel path: it
// carries only a chat_id (PluginProvider.gd:286) and is fire-and-forget, so the
// backend has to find the run from the chat alone and has to be tolerant of a
// cancel that arrives for something already finished.
func TestCouncilChatCancelStopsTheRound(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)
	host.holdChat()
	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")

	var definition map[string]any
	raw, err := fixtures.FS.ReadFile("definition_workshop.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &definition); err != nil {
		t.Fatal(err)
	}
	seeded := host.tool(2, "minerva_council_command", map[string]any{
		"request_id":    "req-def",
		"command":       "definition.upsert",
		"base_revision": store.Revision(),
		"payload":       map[string]any{"definition": definition},
	})
	if ok, _ := seeded["ok"].(bool); !ok {
		t.Fatalf("definition.upsert: %v", seeded)
	}

	const chatID = "chat-cancelled"
	// The turn is dispatched on its own goroutine because the failure under
	// test is a round that is STILL RUNNING: asserting after it returned would
	// only ever exercise the finished case.
	replies := make(chan map[string]any, 1)
	go func() { replies <- host.turn(3, chatID, "Take your time.") }()

	// Wait for the RUN, not just the session: session.create commits before
	// run.start does, and a cancel sent in that gap would find nothing because
	// there was nothing yet — a different bug from the one under test.
	sessionID, _ := awaitLiveRun(t, store, chatID)
	cancelled := host.tool(4, chatCancelTool, map[string]any{"chat_id": chatID})
	// Recorded, not asserted yet: the turn goroutine is still blocked inside
	// the gate, and a Fatal here would end the test with it stranded.
	cancelFailed := str(cancelled["kind"]) == session.ChatError
	host.openChat()

	reply := awaitTurn(t, replies)
	if cancelFailed {
		t.Fatalf("a cancel must not fail: %v", cancelled)
	}
	// The user asked to stop, so the turn must not come back as an answer
	// nobody wanted. The host has already resolved their turn with
	// "Request cancelled." by now (PluginProvider.gd:132-140); what matters
	// here is that Council's own record says cancelled.
	if kind := str(reply["kind"]); kind != session.ChatError {
		t.Errorf("a cancelled round is a visible failure, not an answer: %v", reply)
	}
	if status := sessionStatus(t, store, sessionID); status != "cancelled" {
		t.Errorf("the session must record the cancellation; got %q", status)
	}

	// A second cancel, for a run that has already stopped. The host fires this
	// without awaiting it, so it can and does arrive late.
	again := host.tool(5, chatCancelTool, map[string]any{"chat_id": chatID})
	if kind := str(again["kind"]); kind == session.ChatError {
		t.Errorf("a late cancel is a success that moves nothing: %v", again)
	}
}

// ---------------------------------------------------------------------------
// readers over the engine's own exported record
// ---------------------------------------------------------------------------

func sessionsOf(t *testing.T, store *session.Store) []map[string]any {
	t.Helper()
	var out []map[string]any
	list, _ := store.Export()["sessions"].([]any)
	for _, x := range list {
		record, _ := x.(map[string]any)
		out = append(out, record)
	}
	return out
}

func sessionBoundTo(t *testing.T, store *session.Store, chatID string) string {
	t.Helper()
	for _, record := range sessionsOf(t, store) {
		binding, _ := record["chat_binding"].(map[string]any)
		if str(binding["chat_id"]) == chatID {
			return str(record["session_id"])
		}
	}
	return ""
}

// awaitBoundSession waits for a turn to have created its session, which happens
// before the round it starts can finish.
func awaitBoundSession(t *testing.T, store *session.Store, chatID string) string {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if id := sessionBoundTo(t, store, chatID); id != "" {
			return id
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("no session was ever bound to %s", chatID)
	return ""
}

func sessionCount(t *testing.T, store *session.Store) int {
	t.Helper()
	return len(sessionsOf(t, store))
}

func sessionRecord(t *testing.T, store *session.Store, sessionID string) map[string]any {
	t.Helper()
	for _, record := range sessionsOf(t, store) {
		if str(record["session_id"]) == sessionID {
			return record
		}
	}
	t.Fatalf("session %q is not in the document", sessionID)
	return nil
}

func runCount(t *testing.T, store *session.Store, sessionID string) int {
	t.Helper()
	runs, _ := sessionRecord(t, store, sessionID)["runs"].([]any)
	return len(runs)
}

func questionOf(t *testing.T, store *session.Store, sessionID string) string {
	t.Helper()
	return str(sessionRecord(t, store, sessionID)["question"])
}

func definitionOf(t *testing.T, store *session.Store, sessionID string) string {
	t.Helper()
	snapshot, _ := sessionRecord(t, store, sessionID)["definition_snapshot"].(map[string]any)
	return str(snapshot["definition_id"])
}

func sessionStatus(t *testing.T, store *session.Store, sessionID string) string {
	t.Helper()
	return str(sessionRecord(t, store, sessionID)["status"])
}

// TestCouncilRegistersBeforeReadingTheModelCatalogueAndWithdrawsOnShutdown
// covers the whole life of the provider entry: it appears in the chooser, and
// it leaves again.
//
// The first half pins the ordering of the startup handshake, and the fact that
// the two calls do not share a deadline.
//
// The catalogue is 1 + N host round trips. If registration waited behind it on
// one budget, a host slow to enumerate models would leave Council out of the
// provider chooser entirely — a failure with no symptom a user could see, since
// there would be nothing to select and no error to read. A slow catalogue must
// cost only what it actually costs: hints going unchecked for a moment.
//
// The listings are held open for the whole assertion, so this cannot pass by
// racing: if registration ran second it would still be waiting when the wait
// below expires.
//
// The second half is the other end of the same promise, and the live check
// states it as "stop the Council plugin and Council disappears from the
// chooser". The host drops a dead plugin's entries by itself, so what is
// actually at stake here is the ORDERLY case: withdraw has to reach the host
// while the stream is still up, which means before serve returns. A withdraw
// issued after the reader stops is a call nobody receives, and the symptom
// would be an entry that survives a clean stop and answers nothing.
func TestCouncilRegistersBeforeReadingTheModelCatalogueAndWithdrawsOnShutdown(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	host := newProviderHost(t, store)
	host.holdModels()
	host.rpc(1, "initialize", map[string]any{})

	registration := host.awaitCapability("host.chat_providers.register")
	if str(registration.Args["entry_id"]) != chatEntryID {
		t.Fatalf("the entry registered while the catalogue was stalled must be Council's: %v", registration.Args)
	}
	// And it really was stalled — otherwise the ordering above proves nothing.
	if models, known := store.Models(); known || len(models) != 0 {
		t.Errorf("the catalogue was held open, so nothing should have been read yet; got %d models known=%v", len(models), known)
	}

	// Released, the catalogue lands on its own budget and the engine picks it up.
	host.openModels()
	arrived := false
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if _, known := store.Models(); known {
			arrived = true
			break
		}
		time.Sleep(2 * time.Millisecond)
	}
	if !arrived {
		t.Fatal("the catalogue never arrived after the host answered")
	}

	// --- the orderly stop -------------------------------------------------
	// The oracle is the host's own record of what reached it, and the ordering
	// is what makes it meaningful: serve must not have returned yet when the
	// unregister arrived, so the assertion is made against the calls the host
	// had received BEFORE it saw the loop end.
	if calls := host.capabilityCalls("host.chat_providers.unregister"); len(calls) != 0 {
		t.Fatalf("Council withdrew its entry before anyone asked it to stop: %v", calls)
	}
	if reply := host.rpc(2, "shutdown", map[string]any{}); reply == nil {
		t.Fatal("shutdown was not answered")
	}
	select {
	case err := <-host.done:
		if err != nil {
			t.Fatalf("serve returned an error on shutdown: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("serve did not return after shutdown")
	}
	withdrawn := host.capabilityCalls("host.chat_providers.unregister")
	if len(withdrawn) != 1 {
		t.Fatalf("an orderly shutdown withdraws the entry exactly once, the host saw %d calls", len(withdrawn))
	}
	if str(withdrawn[0].Args["entry_id"]) != chatEntryID {
		t.Errorf("the entry withdrawn is not the one registered: %v", withdrawn[0].Args)
	}
}

// TestCouncilChatDoesNotStartASecondRoundWhileOneIsRunning covers the double
// spend a chat provider invites: the host resolved the user's last turn with
// "still deliberating" and let them type again, and it has no idea a round is
// still in flight. A second run.start here would consult the whole bench twice
// over one question and produce two syntheses of it.
//
// The oracle is the host's model calls, counted as they ARRIVE rather than as
// they complete: a second round is visible as an extra call even though the
// gate never lets it finish.
func TestCouncilChatDoesNotStartASecondRoundWhileOneIsRunning(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)
	host.holdChat()
	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")
	seedWorkshopCouncil(t, host, store, 2)

	const chatID = "chat-impatient"
	firstTurn := make(chan map[string]any, 1)
	go func() { firstTurn <- host.turn(3, chatID, "How much capacity should the workshop hold?") }()

	sessionID, _ := awaitLiveRun(t, store, chatID)
	// The council's one advisor is now inside the gate, so the round cannot
	// rest and anything arriving next necessarily arrives mid-round.
	awaitModelCalls(t, host, 1)

	secondTurn := make(chan map[string]any, 1)
	go func() { secondTurn <- host.turn(4, chatID, "Actually, what about demand instead?") }()

	// A second round would send its own advisor call. Watch for one over a
	// window — the window is what makes the negative meaningful — and RECORD
	// rather than fail, because both turn goroutines are still inside the gate
	// and a Fatal here would strand them.
	extra := 0
	settle := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(settle) {
		if calls := host.modelCalls(); len(calls) != 1 {
			extra = len(calls)
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	host.openChat()
	first := awaitTurn(t, firstTurn)
	second := awaitTurn(t, secondTurn)
	if extra != 0 {
		t.Fatalf("a second turn must watch the running round, not start another; the host saw %d model calls", extra)
	}

	if kind := str(first["kind"]); kind != session.ChatAnswer {
		t.Fatalf("the first turn must answer once the round lands: %v", first)
	}
	// The user's second question was NOT asked. Saying so is the whole point:
	// a question silently dropped is worse than one visibly deferred.
	if kind := str(second["kind"]); kind != session.ChatAnswer {
		t.Fatalf("watching a round is an answer, not a failure: %v", second)
	}
	if !strings.Contains(str(second["text"]), "not") {
		t.Errorf("the reply must tell the user their new question was not asked: %q", second["text"])
	}
	if runs := runCount(t, store, sessionID); runs != 1 {
		t.Fatalf("two turns over one running round is ONE run; got %d", runs)
	}

	// Once the round is at rest the chat is free again, and the next question
	// does start a round of its own.
	third := host.turn(5, chatID, "Now ask that demand question properly.")
	if kind := str(third["kind"]); kind != session.ChatAnswer {
		t.Fatalf("a turn after the round rested must run: %v", third)
	}
	if runs := runCount(t, store, sessionID); runs != 2 {
		t.Fatalf("the next question is a second run; got %d", runs)
	}
}

// TestCouncilChatRefusesACouncilItCannotFind covers `/council <unknown-id>`.
// Falling through to "the only council there is" would consult a different
// bench and present its answer as the one the user chose.
func TestCouncilChatRefusesACouncilItCannotFind(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)
	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")
	seedWorkshopCouncil(t, host, store, 2)

	// Named and absent, with nothing pending: refused now, not remembered and
	// discovered at the start of the next question.
	refused := host.turn(3, "chat-typo", session.SelectCouncilDirective+"def-does-not-exist")
	if kind := str(refused["kind"]); kind != session.ChatError {
		t.Fatalf("an unknown council must be refused: %v", refused)
	}
	if !strings.Contains(str(refused["text"]), "def-does-not-exist") {
		t.Errorf("the refusal must name what was asked for: %q", refused["text"])
	}
	if sessionCount(t, store) != 0 {
		t.Fatal("a refused choice must open no session")
	}

	// And with a question pending, which is the path an option card takes.
	asked := host.turn(4, "chat-typo", "A question that needs a council.")
	if kind := str(asked["kind"]); kind != session.ChatAnswer {
		// One council in the project, so this runs rather than asking which.
		t.Fatalf("the project has one council, so the question runs: %v", asked)
	}
	if sessionCount(t, store) != 1 {
		t.Fatalf("the question opened its session on the council that exists; got %d sessions", sessionCount(t, store))
	}
}

// TestCouncilChatOptionsStayDistinctWhenCouncilsShareAName covers a host
// behaviour that silently loses a choice: ChatPane keys its option buttons by
// label and keeps only the first of a repeated one (ChatPane.gd:2322-2324), so
// two councils called the same thing would render as one button and one of them
// would be unreachable.
func TestCouncilChatOptionsStayDistinctWhenCouncilsShareAName(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)
	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")

	base := workshopDefinition(t)
	twin := workshopDefinition(t)
	twin["definition_id"] = "def-workshop-twin"
	twin["name"] = base["name"] // deliberately the same name
	for i, def := range []map[string]any{base, twin} {
		reply := host.tool(2+i, "minerva_council_command", map[string]any{
			"request_id":    "req-def-" + strconv.Itoa(i),
			"command":       "definition.upsert",
			"base_revision": store.Revision(),
			"payload":       map[string]any{"definition": def},
		})
		if ok, _ := reply["ok"].(bool); !ok {
			t.Fatalf("definition.upsert: %v", reply)
		}
	}

	asked := host.turn(4, "chat-ambiguous-names", "Which of you should answer?")
	if kind := str(asked["kind"]); kind != session.ChatQuestion {
		t.Fatalf("two councils is a question: %v", asked)
	}
	options, _ := asked["options"].([]any)
	if len(options) != 2 {
		t.Fatalf("both councils must be offered; got %v", asked["options"])
	}
	labels := map[string]bool{}
	for _, x := range options {
		option := x.(map[string]any)
		label := str(option["label"])
		if labels[label] {
			t.Fatalf("two options share the label %q, so the host would render one button and lose a council", label)
		}
		labels[label] = true
	}
	// The id is what makes them distinguishable, so it has to be in the label a
	// person reads — not only in the keystroke they cannot see.
	if !labels[str(base["name"])+" ("+str(base["definition_id"])+")"] {
		t.Errorf("a repeated name must be disambiguated by its definition_id; got %v", labels)
	}
}

// ---------------------------------------------------------------------------
// shared setup
// ---------------------------------------------------------------------------

func workshopDefinition(t *testing.T) map[string]any {
	t.Helper()
	raw, err := fixtures.FS.ReadFile("definition_workshop.json")
	if err != nil {
		t.Fatal(err)
	}
	var definition map[string]any
	if err := json.Unmarshal(raw, &definition); err != nil {
		t.Fatal(err)
	}
	return definition
}

func seedWorkshopCouncil(t *testing.T, host *providerHost, store *session.Store, id int) string {
	t.Helper()
	definition := workshopDefinition(t)
	reply := host.tool(id, "minerva_council_command", map[string]any{
		"request_id":    "req-seed",
		"command":       "definition.upsert",
		"base_revision": store.Revision(),
		"payload":       map[string]any{"definition": definition},
	})
	if ok, _ := reply["ok"].(bool); !ok {
		t.Fatalf("definition.upsert: %v", reply)
	}
	return str(definition["definition_id"])
}

// awaitLiveRun waits until the chat's session actually holds a run that is
// going somewhere.
//
// Waiting for the SESSION is not enough, and that was the bug in the first
// draft of these tests: session.create commits before run.start does, so a
// cancel sent on that signal could arrive before the run existed at all. The
// run is in the record from the moment run.start's mutation commits, which is
// the same instant the backend itself can first find it.
func awaitLiveRun(t *testing.T, store *session.Store, chatID string) (string, string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		for _, record := range sessionsOf(t, store) {
			binding, _ := record["chat_binding"].(map[string]any)
			if str(binding["chat_id"]) != chatID {
				continue
			}
			runs, _ := record["runs"].([]any)
			for _, r := range runs {
				run, _ := r.(map[string]any)
				switch str(run["status"]) {
				case "pending", "running":
					return str(record["session_id"]), str(run["run_id"])
				}
			}
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("no run for %s ever reached a live state", chatID)
	return "", ""
}

// awaitModelCalls waits until the host has been asked for at least n models.
func awaitModelCalls(t *testing.T, host *providerHost, n int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if len(host.modelCalls()) >= n {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("the host was never asked for %d model call(s); it saw %d", n, len(host.modelCalls()))
}

func awaitTurn(t *testing.T, replies <-chan map[string]any) map[string]any {
	t.Helper()
	select {
	case reply := <-replies:
		return reply
	case <-time.After(30 * time.Second):
		t.Fatal("a chat turn never returned")
		return nil
	}
}

// TestABrokerRefusalBecomesAVisibleMemberFailureThatCanBeRetried covers the
// failure a user actually meets on a first run: a provider with no key, a spent
// budget, a service that is not configured. The host declines BEFORE a model is
// reached, so nothing is wrong with the question and nothing about the answer
// explains it — the whole value of the path is that the record says which
// member could not be asked and that asking again is offered.
//
// It is driven through the shipped stdio adapter, so the refusal travels as the
// broker's own {"success": false, error_code, error_message} envelope rather
// than as a Go error invented here (CapabilityBroker.gd's PluginErrors.failure).
//
// Oracles:
//   - the contribution's own failure record: code model_unavailable, because
//     from the user's side there is a thing to fix and it is not the question;
//     and a message that still carries the host's words, because "the request
//     was refused" with no reason is not actionable;
//   - the run and session status, derived from the run set rather than written
//     by this path, which is what makes a partial round still useful;
//   - the chat turn itself, which must answer rather than error, because the
//     member that DID answer is worth reading;
//   - the retry's model calls, which must re-ask the refused seat and nobody
//     else — a retry that re-asked the whole bench would spend twice for one
//     missing answer.
func TestABrokerRefusalBecomesAVisibleMemberFailureThatCanBeRetried(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)
	host.answerWith(benchAnswer)

	// Matched on the member's scope, which is the only thing on the wire that
	// tells the seats apart (prompt.go memberSystem).
	const costingScope = "against the bench time it consumes"
	const brokerCode = "provider_key_missing"
	const brokerMessage = "OpenAI has no API key configured."
	// Installed and withdrawn through refuseWith, which the harness guards with
	// its own lock. A plain bool flipped by the test body and read here would be
	// a write on one goroutine and a read on the capability goroutine, ordered
	// only by whatever the pipe happened to synchronise — which is not something
	// this test should be relying on, and not something -race would keep
	// catching if the surrounding calls changed.
	host.refuseWith(func(args map[string]any) (string, string) {
		if strings.Contains(systemOf(args), costingScope) {
			return brokerCode, brokerMessage
		}
		return "", ""
	})

	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")
	seedDefinition(t, host, store, 2, twoAdvisorCouncil(t), "req-seed")

	const chatID = "chat-refused"
	answer := host.turn(3, chatID, "Should the workshop take the recurring order?")
	if kind := str(answer["kind"]); kind != session.ChatAnswer {
		t.Fatalf("a round that lost one member still has an answer to give; got %v", answer)
	}
	sessionID := sessionBoundTo(t, store, chatID)
	if sessionID == "" {
		t.Fatal("the turn must leave a session bound to its chat")
	}

	run := lastRun(t, store, sessionID)
	var refused, answered map[string]any
	for _, x := range run["contributions"].([]any) {
		contribution, _ := x.(map[string]any)
		switch str(contribution["seat_id"]) {
		case "seat-costing":
			refused = contribution
		case "seat-capacity":
			answered = contribution
		}
	}
	if refused == nil || answered == nil {
		t.Fatalf("both advisors must be recorded, whatever happened to them: %v", run["contributions"])
	}
	if status := str(refused["status"]); status != "failed" {
		t.Fatalf("a member the host would not ask reads failed, not %q", status)
	}
	failure, _ := refused["failure"].(map[string]any)
	if code := str(failure["code"]); code != session.CodeModelUnavailable {
		t.Errorf("a refusal before the model is reached is %q, got %q", session.CodeModelUnavailable, code)
	}
	// The host's own words survive the hop. Without them the user is told a
	// member failed and given nothing to act on.
	if message := str(failure["message"]); !strings.Contains(message, brokerCode) || !strings.Contains(message, brokerMessage) {
		t.Errorf("the failure must carry what the host said; got %q", message)
	}
	if str(answered["status"]) != "complete" {
		t.Errorf("the member that answered must be unaffected, got %q", answered["status"])
	}
	// Status is derived from the run set, so this is the derivation's answer to
	// "some members answered and some did not", not a label this path wrote.
	if status := str(run["status"]); status != "partial" {
		t.Errorf("a round that lost one member of two is partial, got %q", status)
	}
	if status := sessionStatus(t, store, sessionID); status != "partial" {
		t.Errorf("the session takes the last run's reading, got %q", status)
	}
	if failure["retryable"] != true {
		t.Error("a refusal the user can fix must be marked retryable, or the panel offers no way back")
	}

	// --- and asking again, once the key is there --------------------------
	host.refuseWith(nil)
	before := len(host.modelCalls())
	retried := host.tool(4, "minerva_council_command", map[string]any{
		"request_id":    "req-retry",
		"command":       "run.retry",
		"base_revision": store.Revision(),
		"payload":       map[string]any{"session_id": sessionID, "run_id": str(run["run_id"])},
	})
	if ok, _ := retried["ok"].(bool); !ok {
		t.Fatalf("run.retry: %v", retried)
	}
	after := host.modelCalls()[before:]
	seats := map[string]int{}
	for _, call := range after {
		system := systemOf(call)
		switch {
		case strings.Contains(system, "chairing a council"):
			seats["chair"]++
		case strings.Contains(system, costingScope):
			seats["costing"]++
		default:
			seats["capacity"]++
		}
	}
	if seats["costing"] != 1 || seats["capacity"] != 0 {
		t.Fatalf("a retry re-asks only the seats that did not answer; the host saw %v", seats)
	}
	if seats["chair"] != 1 {
		t.Errorf("the retry needs its own synthesis over the completed bench, got %d chair calls", seats["chair"])
	}
	if status := str(lastRun(t, store, sessionID)["status"]); status != "complete" {
		t.Fatalf("the retried round completed the bench, so it reads complete, got %q", status)
	}
}
