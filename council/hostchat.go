package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"

	"github.com/ipeerbhai/plugins/council/internal/session"
)

// stdioChatHost reaches the host's models over the plugin's own stdio pair.
//
// The mechanism is the one every Minerva backend uses for a host capability: a
// JSON-RPC REQUEST written to stdout with method "minerva/capability", and the
// host's answer arriving on stdin correlated by id. There is no second socket
// and no callback; the plugin's one stream carries traffic in both directions.
//
// The host runs any number of requests in flight at once — panel IPC, MCP tool
// dispatch and a provider's cancel are independent coroutines — and its own
// stdout drain already routes replies by id. So this adapter does the same on
// its side: an exchange registers a channel under its id, writes its request,
// and waits. The reader goroutine in serve delivers by id.
//
// Three properties follow, and each of them is the fix for a way this could go
// wrong. Exchanges do not serialise, so a round may run as many calls at once
// as the council allows. A waiting exchange can be ABANDONED, because it is
// waiting on a channel rather than inside a Read, so a member's timeout reaches
// the call that is actually waiting. And an abandoned exchange is harmless: its
// late reply finds no pending entry and is dropped, so nothing desyncs and no
// answer can be handed to the wrong member.
type stdioChatHost struct {
	mu      sync.Mutex
	out     *stdoutWriter
	nextID  int
	pending map[string]chan []byte
	// gone is set once the host's stream ends. It turns every later call into a
	// clear refusal instead of a wait for a stream that will never speak again.
	gone bool
}

// bind attaches the adapter to the protocol loop's stdout door. Until it is
// called the adapter reports that it has no route, which is what a Store gets
// if a build ever forgets to bind one.
func (h *stdioChatHost) bind(out *stdoutWriter) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.out = out
	h.pending = map[string]chan []byte{}
}

// deliver hands one response to the exchange waiting on its id. It reports
// false when nothing is waiting, which is the ordinary fate of a reply to a
// call that already timed out.
func (h *stdioChatHost) deliver(id string, line []byte) bool {
	h.mu.Lock()
	waiter, waiting := h.pending[id]
	h.mu.Unlock()
	if !waiting {
		return false
	}
	select {
	case waiter <- append([]byte(nil), line...):
	default:
		// A second response carrying an id that already has its answer. The
		// exchange is served either way, and blocking here would stop the one
		// reader for every other exchange and for the protocol loop with it —
		// so the duplicate is dropped and said out loud.
		log.Printf("dropped a duplicate response for id %s", id)
	}
	return true
}

// closed fails every waiting exchange when the host's stream ends.
func (h *stdioChatHost) closed() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.gone = true
	for id, waiter := range h.pending {
		close(waiter)
		delete(h.pending, id)
	}
}

// capabilityReply is the host's envelope, which sits INSIDE the JSON-RPC
// result: success carries a second "result" object, failure carries the code
// and message flat beside success:false. Shape from
// CapabilityBroker.gd's own reply construction.
type capabilityReply struct {
	Success      bool            `json:"success"`
	Result       json.RawMessage `json:"result"`
	ErrorCode    string          `json:"error_code"`
	ErrorMessage string          `json:"error_message"`
}

// chatResult is the OpenAI-shaped body host.providers.chat answers with. Only
// the fields Council records are read; anything else the host adds is ignored
// rather than refused.
type chatResult struct {
	Model   string `json:"model"`
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     *int `json:"prompt_tokens"`
		CompletionTokens *int `json:"completion_tokens"`
	} `json:"usage"`
}

// Generate carries one assembled call to a host model.
func (h *stdioChatHost) Generate(ctx context.Context, call session.ModelCall) (session.ModelReply, error) {
	if err := ctx.Err(); err != nil {
		return session.ModelReply{}, err
	}

	model := call.Model
	if model == "" {
		// The broker resolves "default" to the provider the user actually has,
		// which is the only model id that is correct on every install.
		model = "default"
	}
	args := map[string]any{
		"messages": []map[string]any{
			{"role": "system", "content": call.System},
			{"role": "user", "content": call.User},
		},
		"model": model,
	}
	// max_tokens is deliberately not sent. The broker forwards it to the
	// provider untranslated and at least one backend refuses the request
	// outright, so a token cap here would turn a working council into a failing
	// one. Council bounds what it SENDS with max_prompt_bytes, and bounds what
	// it waits for with the per-member timeout and the run budget.

	raw, err := h.exchange(ctx, "host.providers.chat", args)
	if err != nil {
		return session.ModelReply{}, err
	}
	var result chatResult
	if err := json.Unmarshal(raw, &result); err != nil {
		return session.ModelReply{}, session.HostFailure(session.CodeModelError,
			"the host's chat reply could not be read: "+err.Error())
	}
	if len(result.Choices) == 0 {
		return session.ModelReply{}, session.HostFailure(session.CodeModelError,
			"the host's chat reply carried no choices, so no answer was produced")
	}
	reply := session.ModelReply{
		ModelID: result.Model,
		Text:    result.Choices[0].Message.Content,
	}
	// Usage is recorded only when the host reported it: an absent figure is not
	// the same claim as a zero one.
	if result.Usage.PromptTokens != nil || result.Usage.CompletionTokens != nil {
		reply.UsageReported = true
		if result.Usage.PromptTokens != nil {
			reply.PromptTokens = *result.Usage.PromptTokens
		}
		if result.Usage.CompletionTokens != nil {
			reply.CompletionTokens = *result.Usage.CompletionTokens
		}
	}
	return reply, nil
}

// exchange registers one pending call, writes its request, and waits for the
// reader to deliver the reply — or gives up when the caller's context expires.
//
// Giving up costs nothing: the entry is removed, and a reply that arrives
// afterwards finds nothing waiting and is dropped by the reader. That is the
// whole reason the pending map exists rather than a shared read.
func (h *stdioChatHost) exchange(ctx context.Context, capability string, args map[string]any) (json.RawMessage, error) {
	h.mu.Lock()
	if h.out == nil {
		h.mu.Unlock()
		return nil, session.HostFailure(session.CodeModelUnavailable,
			"the Council backend is not attached to a host transport, so no model can be reached")
	}
	if h.gone {
		h.mu.Unlock()
		return nil, session.HostFailure(session.CodeModelUnavailable,
			"the host's connection to the Council backend has ended, so no model can be reached")
	}
	h.nextID++
	id := fmt.Sprintf("cap-%d", h.nextID)
	waiter := make(chan []byte, 1)
	h.pending[id] = waiter
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(h.pending, id)
		h.mu.Unlock()
	}()

	params, err := json.Marshal(map[string]any{"capability": capability, "args": args})
	if err != nil {
		return nil, session.HostFailure(session.CodeInternal, "could not build the capability request: "+err.Error())
	}
	if err := h.out.write(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  "minerva/capability",
		"params":  json.RawMessage(params),
	}); err != nil {
		return nil, session.HostFailure(session.CodeModelUnavailable,
			"the capability request could not be sent to the host: "+err.Error())
	}

	var line []byte
	select {
	case received, open := <-waiter:
		if !open {
			return nil, session.HostFailure(session.CodeModelUnavailable,
				"the host closed the connection while Council was waiting for a model")
		}
		line = received
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	var message struct {
		Result json.RawMessage `json:"result"`
		Error  *rpcError       `json:"error"`
	}
	if err := json.Unmarshal(line, &message); err != nil {
		return nil, session.HostFailure(session.CodeModelError,
			"the host's reply was not a JSON-RPC response: "+err.Error())
	}
	if message.Error != nil {
		return nil, session.HostFailure(session.CodeModelUnavailable, message.Error.Message)
	}
	var envelope capabilityReply
	if err := json.Unmarshal(message.Result, &envelope); err != nil {
		return nil, session.HostFailure(session.CodeModelError,
			"the host's capability envelope could not be read: "+err.Error())
	}
	if !envelope.Success {
		return nil, session.HostFailure(codeForBrokerError(envelope.ErrorCode),
			strings.TrimSpace(envelope.ErrorCode+" "+envelope.ErrorMessage))
	}
	return envelope.Result, nil
}

// codeForBrokerError maps the host's refusal onto one of the record's visible
// failure states. Anything the broker refuses before a model is reached is
// "unavailable" from the user's side — there is a thing to fix, and it is not
// the question they asked.
func codeForBrokerError(code string) string {
	switch {
	case code == "":
		return session.CodeModelError
	case strings.Contains(code, "denied"),
		strings.Contains(code, "permission"),
		strings.Contains(code, "budget"),
		strings.Contains(code, "key"),
		strings.Contains(code, "unavailable"),
		strings.Contains(code, "not_found"):
		return session.CodeModelUnavailable
	}
	return session.CodeModelError
}
