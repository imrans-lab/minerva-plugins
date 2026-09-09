package main

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/ipeerbhai/plugins/council/internal/session"
)

// Council's native chat provider: registering the entry, and the two tools the
// host dispatches turns and cancellations to.
//
// The host does not tell a plugin when a chat is created, selected or closed —
// the stdio channel carries no such notification (MCPServerConnection.gd:929-948
// lists every plugin-initiated method, and tools/call is the only traffic in
// the other direction). What it does do is pass chat_id on every generate and
// on every cancel, so the identity Council routes by arrives as a parameter on
// the very call that needs it. That is the whole reason this can be explicit.

const (
	// chatEntryID is the entry Council registers. It is stable, because the
	// host keys the entry "plugin:council:<entry_id>"
	// (PluginChatProviderRegistry.gd:39-40) and a chat remembers its provider
	// by that key across a restart (ServiceHistory.gd:361-371).
	chatEntryID = "council"

	// chatGenerateTool and chatCancelTool are the tools the entry names. The
	// broker refuses a tool that is not this plugin's own, matching the prefix
	// "minerva_council_" (CapabilityBroker.gd:3568-3577).
	chatGenerateTool = "minerva_council_chat_generate"
	chatCancelTool   = "minerva_council_chat_cancel"

	// chatEntryTimeoutSeconds is the per-call timeout Council DECLARES for its
	// entry. Without it the registry would use 600 s
	// (PluginChatProviderRegistry.gd:32); declaring 120 keeps the provider's
	// call_tool budget the same as every other tool call the host makes, so
	// nothing downstream is surprised by a Council turn.
	//
	// A caveat worth knowing: the effective value is
	// get_model_timeout(display_name) first, then this
	// (BaseProvider.gd:71-80), and Council's display name is its model_name
	// (PluginProvider.gd:71). A user who sets a per-model timeout called
	// "Council" overrides this, which is theirs to do.
	chatEntryTimeoutSeconds = 120

	// chatTurnWait is how long a turn may hold its reply. The margin below the
	// declared timeout is deliberate: a reply that arrives as the host stops
	// waiting is a reply nobody receives, so a round that is going to outrun
	// the budget says so with time to spare rather than being cut off.
	chatTurnWait = 90 * time.Second

	// chatDiscoveryTimeout bounds a catalogue read. It is 1 + N host round trips
	// — one provider listing plus one model listing per provider — so it is the
	// slower of the two startup calls and gets the longer budget.
	chatDiscoveryTimeout = 15 * time.Second

	// chatRegisterTimeout bounds the registration exchange alone. It is ONE
	// round trip against a local broker, and it has its own budget rather than
	// sharing the catalogue's: a host that is slow to enumerate models must not
	// be able to spend Council's registration deadline before it is asked for.
	chatRegisterTimeout = 10 * time.Second
)

// chatProvider owns Council's registration with the host.
type chatProvider struct {
	host  *stdioChatHost
	store *session.Store
}

// announce registers the chat entry and reads the host's model catalogue.
//
// **Registration goes first, on its own deadline, and the two never share one.**
// The catalogue is 1 + N host round trips, and a host slow to enumerate models
// at startup would otherwise spend the whole budget before registration was
// even attempted — so the failure mode of a slow catalogue would be Council
// never appearing in the chooser at all. That is invisible to the user: there
// is nothing to select and no error to read.
//
// Reading the catalogue second costs a much smaller thing, and one that says so
// out loud: a turn taken in the window before it lands has no list to check a
// model hint against, so the hint travels unchecked and an absent one falls
// back to the host's default route (session/models.go). Neither call's failure
// stops the other.
//
// It runs on every process start, which is what makes "re-registers on restart"
// true without a second mechanism: register is idempotent on
// (plugin_id, entry_id) and replaces the prior entry in place
// (PluginChatProviderRegistry.gd:58-59).
func (p *chatProvider) announce() {
	p.register()
	p.discoverModels()
}

// register puts Council in the provider chooser.
func (p *chatProvider) register() {
	ctx, cancel := context.WithTimeout(context.Background(), chatRegisterTimeout)
	defer cancel()
	if _, err := p.host.exchange(ctx, "host.chat_providers.register", map[string]any{
		"entry_id":      chatEntryID,
		"display_name":  "Council",
		"generate_tool": chatGenerateTool,
		"cancel_tool":   chatCancelTool,
		// newest_only: Council's own record is the transcript that matters, and
		// a session already carries the question and every contribution. Asking
		// the host for the full chat history would hand the members a second,
		// unversioned copy of the conversation that no citation could point at.
		"history_mode": "newest_only",
		"timeout_sec":  chatEntryTimeoutSeconds,
		"metadata":     map[string]any{"plugin_version": serverVersion},
	}); err != nil {
		log.Printf("could not register the Council chat provider: %v", err)
		return
	}
	log.Printf("registered the Council chat provider entry %q", chatEntryID)
}

// discoverModels reads the host's enabled models so a hint can be checked.
func (p *chatProvider) discoverModels() {
	ctx, cancel := context.WithTimeout(context.Background(), chatDiscoveryTimeout)
	defer cancel()
	if err := p.store.RefreshModels(ctx); err != nil {
		log.Printf("could not read the host's enabled models, so model hints will not be checked: %v", err)
		return
	}
	if models, _ := p.store.Models(); len(models) == 0 {
		log.Printf("the host reports no enabled models; a council cannot be consulted until one is enabled")
	}
}

// withdraw removes the entry on an orderly shutdown.
//
// The host already drops a plugin's entries when it stops or crashes
// (PluginManager.gd:220-221 connects plugin_stopped and plugin_crashed to
// drop_plugin), so this is not what keeps a dead Council out of the chooser. It
// is the orderly half of the same job: a backend told to shut down says so
// while it still can, and the bound wait means a host that has already stopped
// listening costs the exit a moment rather than hanging it.
func (p *chatProvider) withdraw() {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := p.host.exchange(ctx, "host.chat_providers.unregister",
		map[string]any{"entry_id": chatEntryID}); err != nil {
		log.Printf("could not withdraw the Council chat provider: %v", err)
	}
}

// registerChatTools adds the two tools the registered entry names.
//
// Their replies are NOT the {ok, error} shape the rest of the surface uses.
// The host parses content[0].text as the provider envelope and reads its "kind"
// (PluginProvider.gd:240-259, :194-221), and it never looks at isError — so a
// failure has to travel as {"kind":"error"} or it reaches the user as
// "unrecognised reply kind".
func registerChatTools(r *registry, store *session.Store) {
	r.register(toolSpec{
		Name: chatGenerateTool,
		Description: "Answer one turn of a native chat that has Council selected as its provider. The host calls this; it is not a tool to call by hand. " +
			"Arguments are {chat_id, text, entry_id}. The chat_id is the binding: it names the session this chat is consulting, and Council never infers a destination from whichever tab is focused. " +
			"A chat with no session opens one against the project's council (asking which, when the project holds more than one); a chat that already has one asks its question as a follow-up round. " +
			"Returns the chair's answer as {kind:\"answer\", text, prompt_tokens, completion_tokens}; a choice as {kind:\"question\", text, options}; a visible failure as {kind:\"error\", text}. " +
			"A round still deliberating when the reply is due answers rather than timing out, and says where to watch it.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"chat_id": {"type": "string", "description": "The host chat this turn belongs to. It is the session binding."},
				"text": {"type": "string", "description": "The newest user message."},
				"entry_id": {"type": "string", "description": "Which registered Council entry the host dispatched to."}
			},
			"required": ["chat_id", "text"]
		}`),
	}, func(args json.RawMessage) ([]byte, error) {
		var turn struct {
			ChatID  string `json:"chat_id"`
			Text    string `json:"text"`
			EntryID string `json:"entry_id"`
		}
		if err := json.Unmarshal(args, &turn); err != nil {
			return json.Marshal(session.ChatReply{Kind: session.ChatError,
				Text: "Council could not read that turn: " + err.Error()})
		}
		result := store.ChatTurnFor(session.ChatTurn{
			ChatID:  turn.ChatID,
			EntryID: turn.EntryID,
			Text:    turn.Text,
		}, chatTurnWait)
		if result.RunID != "" {
			log.Printf("chat %s ran %s/%s", turn.ChatID, result.SessionID, result.RunID)
		}
		return json.Marshal(result.Reply)
	})

	r.register(toolSpec{
		Name: chatCancelTool,
		Description: "Abandon the round the named chat last started. The host calls this when the user stops a turn; it carries only {chat_id} and is not awaited. " +
			"A cancel for a chat with nothing running, or for a round that has already stopped, is a success that changes nothing.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"chat_id": {"type": "string", "description": "The host chat whose round should stop."}
			},
			"required": ["chat_id"]
		}`),
	}, func(args json.RawMessage) ([]byte, error) {
		var call struct {
			ChatID string `json:"chat_id"`
		}
		if err := json.Unmarshal(args, &call); err != nil {
			return json.Marshal(session.ChatReply{Kind: session.ChatError,
				Text: "Council could not read that cancellation: " + err.Error()})
		}
		return json.Marshal(store.ChatCancelFor(call.ChatID))
	})
}
