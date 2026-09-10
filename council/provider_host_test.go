package main

import (
	"encoding/json"
	"io"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/ipeerbhai/plugins/council/internal/session"
)

// The host side of the wire, shared by every chat-provider test in this package.
//
// The one thing standing in for something real here is Minerva itself: this is
// a host that answers minerva/capability for register, unregister, the two
// model listings and host.providers.chat, and dispatches tools/call the way
// MCPServerConnection does. Everything on the other side of the pipe is the
// shipped backend: serve, the reader, the tool registry, the command engine,
// the schemas, the round driver and the chat routing.
//
// Every assertion built on it names the host behaviour it is an oracle for,
// because this whole surface is a contract with code that lives in another
// repository and cannot be linked against.

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
	gate       chan struct{}
	gateOpen   bool
	modelsOpen bool

	// finished is closed when the test ends, and over stops any goroutine still
	// in flight from logging afterwards. Both are needed: a helper called from
	// a turn goroutine must stop WAITING when the test is over (finished) and
	// must not touch *testing.T once it has (over), which panics.
	finished chan struct{}
	failMu   sync.Mutex
	over     bool
	// modelsGate does the same for the two catalogue listings, so the startup
	// handshake can be held mid-flight.
	modelsGate chan struct{}
	// chatCalls records the arguments of every model call. It is recorded
	// BEFORE the gate, so a round that should never have started is visible as
	// a call that arrived rather than only as one that completed.
	chatCalls []map[string]any

	// refuseFor, when a test installs one, turns a model call into a BROKER
	// refusal instead of an answer: the {"success": false, error_code,
	// error_message} envelope the host sends when it declines before a model is
	// reached — no key, no budget, a provider that is not configured. It is the
	// failure a user actually meets, and it looks nothing like a model that
	// answered badly. An empty code means "answer this one normally".
	refuseFor func(args map[string]any) (code string, message string)

	// answerFor, when a test installs one, decides what each model call
	// answers from the call itself. The default answers every member the same
	// way; a test that asserts on WHO answered what has to tell them apart, and
	// the system prompt is the only thing on the wire that names the member
	// (internal/session/prompt.go memberSystem, synthesis.go chairSystem).
	answerFor func(args map[string]any) string
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
	h.finished = make(chan struct{})
	go h.route(json.NewDecoder(outR))
	// Order matters. Gates are released first so a capability handler blocked
	// inside one returns and the turn goroutine waiting on it can finish;
	// finished then unblocks anything still waiting on a reply; and only after
	// that is logging closed off, because a helper that logs after the test has
	// completed panics the whole run rather than failing one test.
	t.Cleanup(func() {
		h.release()
		close(h.finished)
		_ = inW.Close()
		h.failMu.Lock()
		h.over = true
		h.failMu.Unlock()
	})
	return h
}

// fail records a harness failure from ANY goroutine.
//
// Never Fatalf: it only stops the goroutine that calls it, so a turn goroutine
// would carry on into assertions with no result. Never after the test is over:
// testing panics on a log from a goroutine outliving its test, which takes down
// every other test in the package with it.
func (h *providerHost) fail(format string, args ...any) {
	h.failMu.Lock()
	defer h.failMu.Unlock()
	if h.over {
		return
	}
	h.t.Errorf(format, args...)
}

// release opens any gate this test installed, so nothing is left blocked in a
// capability handler when the test ends.
func (h *providerHost) release() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.gate != nil && !h.gateOpen {
		h.gateOpen = true
		close(h.gate)
	}
	if h.modelsGate != nil && !h.modelsOpen {
		h.modelsOpen = true
		close(h.modelsGate)
	}
}

// openChat and openModels release a gate from the test body. They go through
// the same bookkeeping release() uses so the cleanup cannot close a channel
// twice.
func (h *providerHost) openChat() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.gate != nil && !h.gateOpen {
		h.gateOpen = true
		close(h.gate)
	}
}

func (h *providerHost) openModels() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.modelsGate != nil && !h.modelsOpen {
		h.modelsOpen = true
		close(h.modelsGate)
	}
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
		answerFor, refuseFor := h.answerFor, h.refuseFor
		h.mu.Unlock()
		if gate != nil {
			<-gate
		}
		if refuseFor != nil {
			if code, reason := refuseFor(args); code != "" {
				h.write(map[string]any{"jsonrpc": "2.0", "id": message["id"], "result": map[string]any{
					"success":       false,
					"error_code":    code,
					"error_message": reason,
				}})
				return
			}
		}
		content := modelAnswer("The bench answered.")
		if answerFor != nil {
			content = answerFor(args)
		}
		body = map[string]any{
			"model": str(args["model"]),
			"choices": []map[string]any{
				{"message": map[string]any{"content": content}},
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
func (h *providerHost) holdChat() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.gate = make(chan struct{})
	h.gateOpen = false
}

func (h *providerHost) holdModels() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.modelsGate = make(chan struct{})
	h.modelsOpen = false
}

// refuseWith installs a per-call broker refusal, under the lock for the same
// reason answerWith is.
func (h *providerHost) refuseWith(refuse func(args map[string]any) (string, string)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.refuseFor = refuse
}

// answerWith installs a per-call answer. Set under the lock, like the gates,
// because the capability handler reads it from another goroutine.
func (h *providerHost) answerWith(answer func(args map[string]any) string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.answerFor = answer
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
			h.fail("%s: the backend closed the stream before answering", method)
			return nil
		}
		return response
	case <-h.finished:
		// The test is over and this goroutine is on its way out. Saying
		// anything now would panic the package.
		return nil
	case <-time.After(20 * time.Second):
		h.fail("%s: no reply in 20s", method)
		return nil
	}
}

// tool calls one MCP tool and returns its parsed body.
func (h *providerHost) tool(id int, name string, args map[string]any) map[string]any {
	h.t.Helper()
	response := h.rpc(id, "tools/call", map[string]any{"name": name, "arguments": args})
	if response == nil {
		return nil
	}
	if response["error"] != nil {
		h.fail("%s: protocol error %v", name, response["error"])
		return nil
	}
	result, _ := response["result"].(map[string]any)
	content, _ := result["content"].([]any)
	if len(content) != 1 {
		h.fail("%s: expected one content part, got %v", name, result["content"])
		return nil
	}
	text, _ := content[0].(map[string]any)["text"].(string)
	var body map[string]any
	if err := json.Unmarshal([]byte(text), &body); err != nil {
		h.fail("%s: tool body is not JSON: %v (%s)", name, err, text)
		return nil
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
