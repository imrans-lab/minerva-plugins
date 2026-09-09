package main

import (
	"encoding/json"
	"io"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ipeerbhai/plugins/council/fixtures"
	"github.com/ipeerbhai/plugins/council/internal/session"
)

// Council as a chat provider, end to end over the shipped protocol loop.
//
// The one thing standing in for something real here is Minerva itself: this
// file is a host that speaks the host's side of the wire — it answers
// minerva/capability for register, unregister, the two model listings and
// host.providers.chat, and it dispatches tools/call the way
// MCPServerConnection does. Everything on the other side of that pipe is the
// shipped backend: serve, the reader, the tool registry, the command engine,
// the schemas, the round driver and the chat routing.
//
// Every assertion below names the host behaviour it is an oracle for, because
// this whole surface is a contract with code that lives in another repository
// and cannot be linked against.

// ---------------------------------------------------------------------------
// the harness
// ---------------------------------------------------------------------------

// capabilityCall is one request the backend made of the host.
type capabilityCall struct {
	Capability string
	Args       map[string]any
}

// providerHost drives the real serve loop AND answers the capability requests
// that come back up the same stream. It is the only double in this file.
type providerHost struct {
	t    *testing.T
	enc  *json.Encoder
	in   *io.PipeWriter
	done chan error

	mu      sync.Mutex
	waiting map[string]chan map[string]any
	calls   []capabilityCall

	// providers and models are what the host says it has enabled. Shape from
	// SingletonObject.list_enabled_providers / list_enabled_models
	// (singleton_object.gd:2058-2091).
	providers []map[string]any
	models    map[string][]map[string]any

	// gate, when non-nil, holds every host.providers.chat call until it is
	// closed. It is how a round can be caught mid-flight and cancelled, or held
	// running while something else is asserted about it.
	gate chan struct{}
	// modelsGate does the same for the two catalogue listings, so the startup
	// handshake can be held mid-flight.
	modelsGate chan struct{}
	// chatCalls records the arguments of every model call. It is recorded
	// BEFORE the gate, so a round that should never have started is visible as
	// a call that arrived rather than only as one that completed.
	chatCalls []map[string]any
}

func newProviderHost(t *testing.T, store *session.Store) *providerHost {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	chat := &stdioChatHost{}
	store.SetChatHost(chat)
	store.SetModelCatalog(&hostModelCatalog{host: chat})
	provider := &chatProvider{host: chat, store: store}

	done := make(chan error, 1)
	go func() {
		err := serve(inR, outW, newRegistry(store), chat, provider)
		_ = outW.Close()
		done <- err
	}()

	h := &providerHost{
		t:       t,
		enc:     json.NewEncoder(inW),
		in:      inW,
		done:    done,
		waiting: map[string]chan map[string]any{},
		providers: []map[string]any{
			{"key": "openai", "display": "OpenAI"},
			{"key": "anthropic", "display": "Anthropic"},
		},
		models: map[string][]map[string]any{
			"openai":    {{"model_name": "gpt-test", "display": "GPT Test"}},
			"anthropic": {{"model_name": "claude-test", "display": "Claude Test"}},
		},
	}
	go h.route(json.NewDecoder(outR))
	t.Cleanup(func() { _ = inW.Close() })
	return h
}

// route is the host's stdout drain. It classifies by shape exactly as
// MCPServerConnection does: a message carrying a method is the plugin asking
// the host something (MCPServerConnection.gd:929-948 routes
// "minerva/capability" there), and one carrying only an id is a reply to a
// tools/call this test made.
func (h *providerHost) route(dec *json.Decoder) {
	for {
		var message map[string]any
		if err := dec.Decode(&message); err != nil {
			h.mu.Lock()
			for id, waiter := range h.waiting {
				close(waiter)
				delete(h.waiting, id)
			}
			h.mu.Unlock()
			return
		}
		if method, _ := message["method"].(string); method == "minerva/capability" {
			// On its own goroutine, because the real host runs capability
			// handlers concurrently with everything else — and because a
			// handler that blocks (the gate below) must not stop this drain
			// from delivering the tool reply that will release it.
			go h.answerCapability(message)
			continue
		}
		key := ""
		if raw, ok := message["id"].(float64); ok {
			key = strconv.Itoa(int(raw))
		}
		h.mu.Lock()
		waiter, found := h.waiting[key]
		delete(h.waiting, key)
		h.mu.Unlock()
		if found {
			waiter <- message
		}
	}
}

// answerCapability plays CapabilityBroker: it records the call and replies with
// the broker's own double envelope — {"success": true, "result": {...}} sitting
// inside the JSON-RPC result (CapabilityBroker.gd's PluginErrors.success).
func (h *providerHost) answerCapability(message map[string]any) {
	params, _ := message["params"].(map[string]any)
	capability, _ := params["capability"].(string)
	args, _ := params["args"].(map[string]any)

	h.mu.Lock()
	h.calls = append(h.calls, capabilityCall{Capability: capability, Args: args})
	gate, modelsGate := h.gate, h.modelsGate
	h.mu.Unlock()

	var body map[string]any
	switch capability {
	case "host.chat_providers.register":
		// PluginChatProviderRegistry.make_key: "plugin:<plugin_id>:<entry_id>".
		body = map[string]any{
			"key":          "plugin:council:" + str(args["entry_id"]),
			"entry_id":     args["entry_id"],
			"display_name": args["display_name"],
		}
	case "host.chat_providers.unregister":
		body = map[string]any{"entry_id": args["entry_id"], "removed": true}
	case "host.models.list_providers":
		if modelsGate != nil {
			<-modelsGate
		}
		h.mu.Lock()
		body = map[string]any{"providers": h.providers}
		h.mu.Unlock()
	case "host.models.list_models":
		if modelsGate != nil {
			<-modelsGate
		}
		key := str(args["provider"])
		h.mu.Lock()
		body = map[string]any{"provider": key, "models": h.models[key]}
		h.mu.Unlock()
	case "host.providers.chat":
		// Recorded before the wait: the question a caller asks of this is "did
		// a call arrive", and a gated call that never completes has still
		// arrived.
		h.mu.Lock()
		h.chatCalls = append(h.chatCalls, args)
		h.mu.Unlock()
		if gate != nil {
			<-gate
		}
		body = map[string]any{
			"model": str(args["model"]),
			"choices": []map[string]any{
				{"message": map[string]any{"content": modelAnswer("The bench answered.")}},
			},
			"usage": map[string]any{"prompt_tokens": 11, "completion_tokens": 5},
		}
	default:
		h.write(map[string]any{"jsonrpc": "2.0", "id": message["id"], "result": map[string]any{
			"success":       false,
			"error_code":    "unknown_capability",
			"error_message": "Unknown capability '" + capability + "'",
		}})
		return
	}
	h.write(map[string]any{"jsonrpc": "2.0", "id": message["id"],
		"result": map[string]any{"success": true, "result": body}})
}

// holdChat and holdModels install a gate under the lock. They are setters
// rather than plain field writes because route reads the gates from another
// goroutine, and the suite is run with -race.
func (h *providerHost) holdChat() chan struct{} {
	gate := make(chan struct{})
	h.mu.Lock()
	h.gate = gate
	h.mu.Unlock()
	return gate
}

func (h *providerHost) holdModels() chan struct{} {
	gate := make(chan struct{})
	h.mu.Lock()
	h.modelsGate = gate
	h.mu.Unlock()
	return gate
}

func (h *providerHost) write(message map[string]any) {
	h.mu.Lock()
	defer h.mu.Unlock()
	_ = h.enc.Encode(message)
}

// rpc sends one request and waits for its reply.
func (h *providerHost) rpc(id int, method string, params map[string]any) map[string]any {
	h.t.Helper()
	key := strconv.Itoa(id)
	waiter := make(chan map[string]any, 1)
	h.mu.Lock()
	h.waiting[key] = waiter
	h.mu.Unlock()
	h.write(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	select {
	case response, open := <-waiter:
		if !open {
			h.t.Fatalf("%s: the backend closed the stream before answering", method)
		}
		return response
	case <-time.After(20 * time.Second):
		h.t.Fatalf("%s: no reply in 20s", method)
		return nil
	}
}

// tool calls one MCP tool and returns its parsed body.
func (h *providerHost) tool(id int, name string, args map[string]any) map[string]any {
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
	return body
}

// turn dispatches one chat turn the way PluginProvider does: chat_id, text and
// entry_id, and nothing else (PluginProvider.gd:106-113).
func (h *providerHost) turn(id int, chatID, text string) map[string]any {
	h.t.Helper()
	return h.tool(id, chatGenerateTool, map[string]any{
		"chat_id": chatID, "text": text, "entry_id": chatEntryID,
	})
}

func (h *providerHost) capabilityCalls(name string) []capabilityCall {
	h.mu.Lock()
	defer h.mu.Unlock()
	var found []capabilityCall
	for _, call := range h.calls {
		if call.Capability == name {
			found = append(found, call)
		}
	}
	return found
}

func (h *providerHost) modelCalls() []map[string]any {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]map[string]any{}, h.chatCalls...)
}

// awaitCapability waits for the backend's startup handshake to reach the host.
// It is a wait rather than an assertion because announce runs on its own
// goroutine so the initialize reply is not held behind two host round trips.
func (h *providerHost) awaitCapability(name string) capabilityCall {
	h.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if calls := h.capabilityCalls(name); len(calls) > 0 {
			return calls[0]
		}
		time.Sleep(2 * time.Millisecond)
	}
	h.t.Fatalf("the backend never called %s", name)
	return capabilityCall{}
}

func str(v any) string { s, _ := v.(string); return s }

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
	gate := host.holdChat()
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

	sessionID := awaitBoundSession(t, store, chatID)
	cancelled := host.tool(4, chatCancelTool, map[string]any{"chat_id": chatID})
	if kind := str(cancelled["kind"]); kind == session.ChatError {
		t.Fatalf("a cancel must not fail: %v", cancelled)
	}
	close(gate)

	select {
	case reply := <-replies:
		// The user asked to stop, so the turn must not come back as an answer
		// nobody wanted. The host has already resolved their turn with
		// "Request cancelled." by now (PluginProvider.gd:132-140); what matters
		// here is that Council's own record says cancelled.
		if kind := str(reply["kind"]); kind != session.ChatError {
			t.Errorf("a cancelled round is a visible failure, not an answer: %v", reply)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the cancelled turn never returned")
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

// TestCouncilRegistersBeforeReadingTheModelCatalogue pins the ordering of the
// startup handshake, and the fact that the two calls do not share a deadline.
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
func TestCouncilRegistersBeforeReadingTheModelCatalogue(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	host := newProviderHost(t, store)
	modelsGate := host.holdModels()
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
	close(modelsGate)
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if _, known := store.Models(); known {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("the catalogue never arrived after the host answered")
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
	gate := host.holdChat()
	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")
	seedWorkshopCouncil(t, host, store, 2)

	const chatID = "chat-impatient"
	firstTurn := make(chan map[string]any, 1)
	go func() { firstTurn <- host.turn(3, chatID, "How much capacity should the workshop hold?") }()

	sessionID := awaitBoundSession(t, store, chatID)
	// The council's one advisor is now inside the gate, so the round cannot
	// rest and anything arriving next necessarily arrives mid-round.
	awaitModelCalls(t, host, 1)

	secondTurn := make(chan map[string]any, 1)
	go func() { secondTurn <- host.turn(4, chatID, "Actually, what about demand instead?") }()

	// A second round would send its own advisor call. Watch for one: the window
	// is what makes the negative meaningful, and a call that arrives later than
	// this still shows up in the run count below.
	settle := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(settle) {
		if calls := host.modelCalls(); len(calls) != 1 {
			t.Fatalf("a second turn must watch the running round, not start another; the host saw %d model calls", len(calls))
		}
		time.Sleep(5 * time.Millisecond)
	}

	close(gate)
	first := awaitTurn(t, firstTurn)
	second := awaitTurn(t, secondTurn)

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
