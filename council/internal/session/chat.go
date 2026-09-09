package session

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Council as a native chat provider.
//
// The host hands one turn to the registered generate tool as
// {chat_id, text, entry_id} (PluginProvider.gd:106-113) and expects back one of
// three shapes: answer, question with options, or error
// (PluginProvider.gd:194-221). Cancellation arrives at the registered
// cancel_tool carrying ONLY {chat_id} (PluginProvider.gd:286).
//
// chat_id is therefore the whole of the binding, and it is a parameter rather
// than an ambient: there is no code path here that could learn which tab is
// focused, and none that guesses. A chat maps to exactly one session, the map
// is the session's own chat_binding in the durable record, and a chat this
// document does not own is refused rather than adopted.
//
// Everything below is expressed as ordinary protocol commands run through
// Dispatch. That is deliberate: a chat turn gets the same validation, the same
// idempotency ledger, the same revision checks and the same bounded waiting as
// a turn driven from the panel, and there is one engine rather than two.

// Reply kinds, from PluginProvider.gd's own match.
const (
	ChatAnswer   = "answer"
	ChatQuestion = "question"
	ChatError    = "error"
)

// Directives are what a question's options send back. The host does not return
// the label a user clicked: it sends the option's KEYSTROKE as an ordinary user
// turn (ChatPane.gd:2385-2391, :2399-2406), so an option's keystroke is a line
// of text Council will read next turn, and these are the two it understands.
//
// They are exported because they are part of Council's chat surface: anything
// building an option, in this process or in the panel, has to spell them the
// same way the reader does.
const (
	SelectCouncilDirective = "/council "
	SelectSessionDirective = "/council-session "
)

// ChatTurn is one turn handed over by the host's chat provider.
type ChatTurn struct {
	ChatID  string
	EntryID string
	Text    string
}

// ChatOption is one choice offered back to the user. Label is what the button
// says; Keystroke is what the host sends as the next user turn when it is
// clicked, so it carries the whole of the choice.
type ChatOption struct {
	Label     string `json:"label"`
	Keystroke string `json:"keystroke"`
}

// ChatReply is the provider envelope. The field names are the host's.
type ChatReply struct {
	Kind             string       `json:"kind"`
	Text             string       `json:"text"`
	Options          []ChatOption `json:"options,omitempty"`
	PromptTokens     int          `json:"prompt_tokens,omitempty"`
	CompletionTokens int          `json:"completion_tokens,omitempty"`
}

func chatErrorf(format string, args ...any) ChatReply {
	return ChatReply{Kind: ChatError, Text: fmt.Sprintf(format, args...)}
}

// chatRun is the run one chat's last turn started, so the host's cancel — which
// carries only a chat_id — can reach it.
type chatRun struct {
	sessionID string
	runID     string
}

// ChatTurnResult reports what a turn did, for the tool layer's log. The reply
// is what the user sees; these are what the backend did to produce it.
type ChatTurnResult struct {
	Reply     ChatReply
	SessionID string
	RunID     string
}

// ChatTurnFor answers one provider turn.
//
// wait bounds how long the reply is held. It must be under the timeout the
// registered entry declared, because a reply held past it is a reply nobody
// receives; a round that outruns it keeps running and the answer says so rather
// than timing out silently.
func (s *Store) ChatTurnFor(turn ChatTurn, wait time.Duration) ChatTurnResult {
	chatID := strings.TrimSpace(turn.ChatID)
	if !idPattern.MatchString(chatID) {
		return ChatTurnResult{Reply: chatErrorf(
			"Council was handed a chat identity it cannot record (%q). Nothing was consulted.", turn.ChatID)}
	}
	text := strings.TrimSpace(turn.Text)
	if text == "" {
		return ChatTurnResult{Reply: chatErrorf("There was no question in that turn, so nobody was consulted.")}
	}

	// A directive is a choice the user made on a previous turn's option card.
	// It is handled before anything else, because it is an answer to Council
	// rather than a question for the council.
	if rest, found := strings.CutPrefix(text, SelectSessionDirective); found {
		return ChatTurnResult{Reply: s.chatSelectSession(chatID, strings.TrimSpace(rest))}
	}
	if rest, found := strings.CutPrefix(text, SelectCouncilDirective); found {
		return s.chatSelectCouncil(chatID, strings.TrimSpace(rest), wait)
	}

	if len(text) > maxQuestionBytes {
		return ChatTurnResult{Reply: chatErrorf(
			"That question is %d characters and a Council session records at most %d. Shorten it, or bring the material in as a source.",
			len(text), maxQuestionBytes)}
	}

	// A round already running for this chat is reported, never joined by a
	// second one. The host has no idea a turn is still in flight — it resolved
	// the user's last turn with "still deliberating" and let them type again —
	// so without this a user who asks twice pays for two full benches and gets
	// two syntheses of the same question.
	if active, live := s.liveRunFor(chatID); live {
		return s.chatAwait(chatID, active, text, wait)
	}

	sessionID, owned := s.sessionForChat(chatID)
	if sessionID != "" {
		return s.chatFollowUp(chatID, sessionID, text, wait)
	}
	if !owned {
		// This chat was routed against a document that is no longer loaded.
		// Starting a fresh session here would put one project's consultation
		// into another project's record, which is the one thing the binding
		// exists to prevent.
		return ChatTurnResult{Reply: chatErrorf(
			"This chat belongs to a Council session in another project's document (project %s), not the one currently open. Reopen that Council document and ask again, or start a new chat for this one.",
			s.chatOwner(chatID))}
	}
	return s.chatOpenSession(chatID, "", text, wait)
}

// maxQuestionBytes is session.schema.json's own ceiling on question. Checking
// it here turns a schema rejection the user cannot read into a sentence that
// says what to do.
const maxQuestionBytes = 8000

// ChatCancelFor stops whatever the named chat last started.
//
// The host fires cancel_tool without awaiting it and has already resolved the
// user's turn by the time it arrives (PluginProvider.gd:270-286), so this is
// tolerant by design: a cancel for a chat with no run, or for a run that has
// already stopped, is a success that moves nothing.
func (s *Store) ChatCancelFor(chatID string) ChatReply {
	s.mu.Lock()
	active, running := s.chatRuns[strings.TrimSpace(chatID)]
	s.mu.Unlock()
	if !running {
		return ChatReply{Kind: ChatAnswer, Text: "There was nothing running for this chat."}
	}
	reply := s.chatCommand("run.cancel", map[string]any{
		"session_id": active.sessionID,
		"run_id":     active.runID,
	}, true, nil)
	if !reply.OK {
		return chatErrorf("The round could not be cancelled: %s", reply.Error.Message)
	}
	return ChatReply{Kind: ChatAnswer, Text: "The round was cancelled. Nothing further will be spent on it."}
}

// ---------------------------------------------------------------------------
// the three routes a turn can take
// ---------------------------------------------------------------------------

// chatOpenSession starts a consultation in a chat that has none. definitionID
// may be empty, in which case the council is chosen — or asked for.
func (s *Store) chatOpenSession(chatID, definitionID, question string, wait time.Duration) ChatTurnResult {
	definitionID, options, refusal := s.chooseCouncil(chatID, definitionID)
	if refusal != "" {
		return ChatTurnResult{Reply: chatErrorf("%s", refusal)}
	}
	if definitionID == "" {
		if len(options) == 0 {
			return ChatTurnResult{Reply: chatErrorf(
				"This project has no council to consult yet. Open a Council editor, assemble one, and ask again.")}
		}
		// The question is remembered against the chat so the option the user
		// clicks can carry the choice alone. Without this the user would have
		// to type their question a second time.
		s.rememberQuestion(chatID, question)
		return ChatTurnResult{Reply: ChatReply{
			Kind:    ChatQuestion,
			Text:    "This project holds more than one council. Which should consider that question?",
			Options: options,
		}}
	}

	sessionID := s.mintSessionID()
	created := s.chatCommand("session.create", map[string]any{
		"session_id":    sessionID,
		"definition_id": definitionID,
		"question":      question,
		"chat_id":       chatID,
	}, true, nil)
	if !created.OK {
		return ChatTurnResult{Reply: chatErrorf("The consultation could not be opened: %s", created.Error.Message)}
	}
	s.forgetQuestion(chatID)
	// Claimed for this document from here on, whatever the round does next: the
	// binding is in the record now, and the routing table has to agree with it
	// even if the round is refused.
	s.noteChat(chatID)
	return s.chatRound(chatID, sessionID, map[string]any{
		"session_id": sessionID,
		"kind":       "initial_round",
	}, wait)
}

// chatFollowUp continues an existing consultation. The whole advisory bench is
// consulted again unless the user aimed the question at somebody, which is what
// the panel's "Ask about this" does with a claim id.
func (s *Store) chatFollowUp(chatID, sessionID, prompt string, wait time.Duration) ChatTurnResult {
	return s.chatRound(chatID, sessionID, map[string]any{
		"session_id": sessionID,
		"kind":       "follow_up",
		"prompt":     prompt,
	}, wait)
}

// chatAwait watches the round this chat already has going, instead of starting
// another one.
//
// unsent is the question the user typed this turn. It is NOT asked: sending it
// would run a second bench over the same session while the first is still
// spending, and Council starts nothing the user did not ask for twice. The
// reply says so plainly, because a question silently dropped is worse than one
// visibly deferred.
func (s *Store) chatAwait(chatID string, active chatRun, unsent string, wait time.Duration) ChatTurnResult {
	seconds := waitSecondsFor(wait)
	reply := s.chatCommand("run.await", map[string]any{
		"session_id": active.sessionID,
		"run_id":     active.runID,
	}, false, &seconds)
	if !reply.OK {
		// The run is gone — a document replaced under it, most likely. Drop the
		// handle so the next turn is free to start a fresh round.
		s.forgetChatRun(chatID)
		return ChatTurnResult{
			SessionID: active.sessionID,
			Reply:     chatErrorf("The round this chat was waiting on could not be read: %s", reply.Error.Message),
		}
	}
	rendered := s.settleRound(chatID, reply.Payload)
	if unsent != "" && !restingStatus(str(reply.Payload["status"])) {
		rendered.Text += "\n\nYour new question has NOT been asked — the council is still on the previous one, and starting a second round would consult the whole bench twice. Ask it again once this round lands."
	} else if unsent != "" {
		rendered.Text += "\n\nThat round has now finished, so your new question was not part of it. Ask it again and the council will take it up."
	}
	return ChatTurnResult{
		SessionID: active.sessionID,
		RunID:     active.runID,
		Reply:     rendered,
	}
}

// chatSelectCouncil handles "/council <definition_id>": the option a user
// clicked when Council asked which council should take their question.
func (s *Store) chatSelectCouncil(chatID, definitionID string, wait time.Duration) ChatTurnResult {
	if definitionID == "" {
		return ChatTurnResult{Reply: chatErrorf("That choice named no council.")}
	}
	question := s.recallQuestion(chatID)
	if question == "" {
		// Nothing pending: the user picked a council before asking anything.
		// It is checked here rather than remembered and discovered later, so a
		// mistyped id is answered now instead of at the start of their next
		// question.
		if _, _, refusal := s.chooseCouncil(chatID, definitionID); refusal != "" {
			return ChatTurnResult{Reply: chatErrorf("%s", refusal)}
		}
		// Remembering the choice is what makes their next plain message open a
		// session with it rather than ask again.
		s.rememberCouncil(chatID, definitionID)
		return ChatTurnResult{Reply: ChatReply{
			Kind: ChatAnswer,
			Text: "That council will take the next question you ask in this chat.",
		}}
	}
	return s.chatOpenSession(chatID, definitionID, question, wait)
}

// chatSelectSession handles "/council-session <session_id>": it points this
// chat at a consultation that already exists, naming it by id.
//
// The binding MOVES. A chat has one session, so if this chat was continuing
// another one, that session loses its binding and keeps everything else; the
// engine enforces that in session.bind_chat and the snapshot invariants refuse
// a document where it is not true.
func (s *Store) chatSelectSession(chatID, sessionID string) ChatReply {
	if sessionID == "" {
		return chatErrorf("That choice named no session.")
	}
	bound := s.chatCommand("session.bind_chat", map[string]any{
		"session_id": sessionID,
		"chat_id":    chatID,
	}, true, nil)
	if !bound.OK {
		return chatErrorf("That session could not be bound to this chat: %s", bound.Error.Message)
	}
	s.forgetQuestion(chatID)
	s.noteChat(chatID)
	return ChatReply{
		Kind: ChatAnswer,
		Text: "This chat now continues that consultation. Ask your follow-up and the council will take it up from where it left off.",
	}
}

// ---------------------------------------------------------------------------
// running a round for a chat turn
// ---------------------------------------------------------------------------

// chatRound starts a round and renders it as a provider reply.
func (s *Store) chatRound(chatID, sessionID string, payload map[string]any, wait time.Duration) ChatTurnResult {
	seconds := waitSecondsFor(wait)
	reply := s.chatCommand("run.start", payload, true, &seconds)
	if !reply.OK {
		return ChatTurnResult{
			SessionID: sessionID,
			Reply:     chatErrorf("The council could not be consulted: %s", reply.Error.Message),
		}
	}
	runID := str(reply.Payload["run_id"])
	s.rememberRun(chatID, sessionID, runID)
	return ChatTurnResult{
		SessionID: sessionID,
		RunID:     runID,
		Reply:     s.settleRound(chatID, reply.Payload),
	}
}

// waitSecondsFor renders a wait for the envelope, inside the bound the schema
// already enforces so one place decides how long a chat turn may be held.
func waitSecondsFor(wait time.Duration) int {
	seconds := int(wait / time.Second)
	if seconds < 1 {
		return 1
	}
	if seconds > MaxWaitSeconds {
		return MaxWaitSeconds
	}
	return seconds
}

// settleRound renders a run and releases the chat's handle once the round is at
// rest.
//
// The handle does two jobs, and both end together: it is what a cancel carrying
// only a chat_id reaches, and it is what stops the next turn starting a second
// round over the same question. Once the round rests there is nothing to cancel
// and nothing to collide with, so a later cancel truthfully answers "nothing
// was running" and the next question starts a round of its own.
func (s *Store) settleRound(chatID string, payload map[string]any) ChatReply {
	if restingStatus(str(payload["status"])) {
		s.forgetChatRun(chatID)
	}
	return renderRound(payload)
}

// restingStatus reports whether a run has stopped moving. The two live states
// are named rather than the five resting ones, so a status added to the enum
// later is treated as resting — which releases a handle early at worst, and
// never holds a chat's next question behind a run that is not going anywhere.
func restingStatus(status string) bool {
	switch status {
	case "pending", "running":
		return false
	}
	return true
}

// renderRound turns run.start's reply into what the chat shows.
//
// A round that is still going is an ANSWER and not an error: the work is not
// lost, it is just not finished, and the user needs to be told where to watch
// it rather than shown a failure that did not happen.
func renderRound(payload map[string]any) ChatReply {
	status := str(payload["status"])
	prompt, completion := usageOf(payload)
	switch status {
	case "pending", "running":
		return ChatReply{
			Kind: ChatAnswer,
			Text: fmt.Sprintf(
				"The council is still deliberating (run %s). This turn is not lost: the members' answers and the chair's synthesis appear in the Council editor as they land. Asking again in this chat REPORTS this round's progress rather than starting a second one — hold your next question until this lands, or stop the turn to cancel.",
				str(payload["run_id"])),
			PromptTokens:     prompt,
			CompletionTokens: completion,
		}
	case "complete", "partial":
		synthesis := obj(payload["synthesis"])
		text := strings.TrimSpace(str(synthesis["text"]))
		if text == "" {
			text = "The chair produced no text for this round. The members' contributions are in the Council editor."
		}
		if note := unfinishedNote(payload); note != "" {
			text += "\n\n" + note
		}
		return ChatReply{
			Kind:             ChatAnswer,
			Text:             text + "\n\nEach member's own argument, with its sources, is in the Council editor.",
			PromptTokens:     prompt,
			CompletionTokens: completion,
		}
	}
	// cancelled or failed: the run carries the reason, and it is the reason the
	// user should see rather than a generic one written here.
	message := str(obj(payload["failure"])["message"])
	if message == "" {
		message = "The round ended without an answer."
	}
	return ChatReply{
		Kind:             ChatError,
		Text:             message,
		PromptTokens:     prompt,
		CompletionTokens: completion,
	}
}

// unfinishedNote names the seats that did not answer. A partial round must say
// who is missing in the chat itself: the synthesis already carries an unknown
// claim about them, but the user reading only this reply would otherwise take a
// partial answer for a whole one.
func unfinishedNote(payload map[string]any) string {
	var missing []string
	for _, x := range arr(payload["contributions"]) {
		contribution := obj(x)
		if str(contribution["status"]) != "complete" {
			missing = append(missing, fmt.Sprintf("%s (%s)",
				str(contribution["seat_id"]), str(contribution["status"])))
		}
	}
	if len(missing) == 0 {
		return ""
	}
	return "Not every member answered: " + strings.Join(missing, ", ") +
		". Retry those seats from the Council editor to complete the round."
}

// usageOf totals what the round reported. The host copies these onto the chat
// turn, so a Council answer costs what it actually cost rather than nothing.
func usageOf(payload map[string]any) (int, int) {
	prompt, completion := 0, 0
	add := func(usage map[string]any) {
		prompt += int(num(usage["prompt_tokens"]))
		completion += int(num(usage["completion_tokens"]))
	}
	for _, x := range arr(payload["contributions"]) {
		add(obj(obj(x)["usage"]))
	}
	add(obj(obj(payload["synthesis"])["usage"]))
	return prompt, completion
}

// ---------------------------------------------------------------------------
// the chat routing table
// ---------------------------------------------------------------------------

// sessionForChat resolves a chat to the session it is bound to in the loaded
// document. At most one session can carry a given chat_id — checkSnapshot
// refuses a document where two do — so the first match is the only match, and
// this is a lookup rather than a choice.
//
// The second value reports whether this chat may open a session here at all:
// false means Council has routed it before, against a document that belongs to
// another project, so continuing it here would put one project's consultation
// into another project's record.
//
// The judgement is made against PROJECT IDENTITY, which is durable, rather than
// against the load generation, which is not. A binding found in the loaded
// document is stamped with the project it was made in, so a session carried
// into another project by an import still says whose chat it is; and the
// routing table this consults is rebuilt from every document the process loads
// (adoptChatRoutes), so a plugin restart no longer erases the guard.
func (s *Store) sessionForChat(chatID string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	project := str(s.snapshot["project_id"])
	for _, x := range arr(s.snapshot["sessions"]) {
		record := obj(x)
		binding := obj(record["chat_binding"])
		if str(binding["chat_id"]) != chatID {
			continue
		}
		// A binding stamped with another project's id came in with a session
		// that was imported or copied. The chat is that project's, and this
		// document is not where its follow-ups belong.
		if owner := str(binding["project_id"]); owner != "" && owner != project {
			return "", false
		}
		s.chatProject[chatID] = project
		return str(record["session_id"]), true
	}
	owner, known := s.chatProject[chatID]
	return "", !known || owner == project
}

// adoptChatRoutes rebuilds the chat routing table from the document just
// loaded. Every binding in it is durable evidence of which project owns that
// chat, so the guard is RECOVERED from the record rather than remembered across
// a restart. The caller holds the lock.
func (s *Store) adoptChatRoutes() {
	project := str(s.snapshot["project_id"])
	for _, x := range arr(s.snapshot["sessions"]) {
		binding := obj(obj(x)["chat_binding"])
		chatID := str(binding["chat_id"])
		if chatID == "" {
			continue
		}
		// The binding's own stamp wins: it names the project the chat was routed
		// into, which is not necessarily the document now holding the session.
		if owner := str(binding["project_id"]); owner != "" {
			s.chatProject[chatID] = owner
			continue
		}
		s.chatProject[chatID] = project
	}
	s.pruneChatRoutes()
}

// projectID is the identity of the document currently loaded. The caller holds
// the lock.
func (s *Store) projectID() string {
	return str(s.snapshot["project_id"])
}

// chooseCouncil picks the council a new session runs, or reports the choices.
//
// The order is: what the user already chose for this chat, then the only
// council there is. Anything else is a question — a project with two councils
// has no correct guess, and guessing is what the binding rules forbid.
func (s *Store) chooseCouncil(chatID, requested string) (string, []ChatOption, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	definitions := arr(s.snapshot["definitions"])
	present := func(id string) bool {
		record, _ := findByID(s.snapshot["definitions"], "definition_id", id)
		return record != nil
	}
	if requested != "" {
		if present(requested) {
			return requested, nil, ""
		}
		// A council NAMED and not found is refused rather than quietly replaced
		// by whichever one the project happens to hold. The user asked for
		// something specific; falling through would consult a different bench
		// and present its answer as though it were the one they chose.
		return "", nil, fmt.Sprintf(
			"There is no council %q in the open document. It may have been renamed, deleted, or it belongs to another project. Ask your question again to see the councils this project holds.",
			requested)
	}
	// A council remembered from an earlier turn is NOT refused when it has since
	// gone: the user did not name it this turn, so falling through to the
	// ordinary choice is the right answer rather than an error about a choice
	// they have forgotten making.
	if chosen := s.chatCouncil[chatID]; chosen != "" && present(chosen) {
		return chosen, nil, ""
	}
	if len(definitions) == 1 {
		return str(obj(definitions[0])["definition_id"]), nil, ""
	}
	return "", councilOptions(definitions), ""
}

// councilOptions renders one option per council.
//
// Labels must be DISTINCT. ChatPane keys its buttons by label and keeps only
// the first of a repeated one (ChatPane.gd:2322-2324), so two councils sharing
// a name would appear as a single button and one of them would be unreachable.
// A repeated name therefore carries its id, and a council with no name at all
// is shown by id — an unlabelled option is dropped outright (:2319-2321).
func councilOptions(definitions []any) []ChatOption {
	seen := map[string]int{}
	for _, x := range definitions {
		seen[str(obj(x)["name"])]++
	}
	options := []ChatOption{}
	for _, x := range definitions {
		record := obj(x)
		id := str(record["definition_id"])
		label := str(record["name"])
		if label == "" {
			label = id
		} else if seen[str(record["name"])] > 1 {
			label = label + " (" + id + ")"
		}
		options = append(options, ChatOption{
			Label:     label,
			Keystroke: SelectCouncilDirective + id,
		})
	}
	return options
}

// mintSessionID issues the id a chat-opened session is recorded under. Every
// other session id is minted by the wrapper and arrives in a payload; a chat
// turn has no wrapper in the loop, so the engine mints this one.
func (s *Store) mintSessionID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.mintID("ses", func(candidate string) bool {
		record, _ := findByID(s.snapshot["sessions"], "session_id", candidate)
		return record != nil
	})
}

func (s *Store) rememberRun(chatID, sessionID, runID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.chatRuns[chatID] = chatRun{sessionID: sessionID, runID: runID}
	s.chatProject[chatID] = s.projectID()
	s.pruneChatRoutes()
}

// liveRunFor reports the round this chat has going, if it still has one. The
// handle is removed as soon as a round comes to rest, so its presence IS the
// claim that something is still running.
//
// A handle whose session is not in the document now loaded is dropped here
// rather than reported. Load cancels the runs it replaces but the handles
// outlive it, and reporting one would answer the first turn after a project
// switch with "that round could not be read" instead of the cross-project
// refusal that actually explains what happened.
func (s *Store) liveRunFor(chatID string) (chatRun, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	active, live := s.chatRuns[chatID]
	if !live {
		return chatRun{}, false
	}
	if record, _ := findByID(s.snapshot["sessions"], "session_id", active.sessionID); record == nil {
		delete(s.chatRuns, chatID)
		return chatRun{}, false
	}
	return active, true
}

func (s *Store) forgetChatRun(chatID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.chatRuns, chatID)
}

func (s *Store) noteChat(chatID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.chatProject[chatID] = s.projectID()
	s.pruneChatRoutes()
}

// maxChatsRemembered bounds the cross-project guard.
const maxChatsRemembered = 4096

// pruneChatRoutes keeps the guard from growing without limit over a long
// session. The caller holds the lock.
//
// It drops entries belonging to other projects first, and only then thins the
// current one. That order is what makes the bound safe to have: a dropped entry
// degrades exactly one chat to "Council cannot place this chat", and the next
// load of the document that owns it puts the entry back, because the routing
// table is rebuilt from bindings rather than accumulated. Reaching the bound at
// all takes thousands of distinct chats inside one backend process.
func (s *Store) pruneChatRoutes() {
	if len(s.chatProject) <= maxChatsRemembered {
		return
	}
	project := s.projectID()
	for chatID, owner := range s.chatProject {
		if owner != project {
			delete(s.chatProject, chatID)
		}
	}
	for chatID := range s.chatProject {
		if len(s.chatProject) <= maxChatsRemembered {
			break
		}
		delete(s.chatProject, chatID)
	}
}

func (s *Store) rememberQuestion(chatID, question string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.chatPending[chatID] = question
}

func (s *Store) recallQuestion(chatID string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.chatPending[chatID]
}

func (s *Store) forgetQuestion(chatID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.chatPending, chatID)
}

func (s *Store) rememberCouncil(chatID, definitionID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.chatCouncil[chatID] = definitionID
}

// ---------------------------------------------------------------------------
// running protocol commands on the chat's behalf
// ---------------------------------------------------------------------------

// chatCommand runs one protocol command as if a client had sent it.
//
// Going through Dispatch rather than reaching into the snapshot is the point:
// the schema check, the idempotency ledger, the revision check, the deferred
// waiting stage and the single write path are all the ones a panel gets, so a
// chat turn cannot reach a state the protocol would have refused.
//
// A mutating command reads the revision and then sends it, which can lose a
// race with a panel writing at the same moment. That is retried once — the
// second read is after the other writer committed — and a second loss is
// reported rather than looped.
func (s *Store) chatCommand(command string, payload map[string]any, mutating bool, wait *int) Reply {
	var last Reply
	for attempt := 0; attempt < 2; attempt++ {
		request := map[string]any{
			"schema_version": SchemaVersion,
			"envelope":       "request",
			"request_id":     s.nextChatRequestID(),
			"command":        command,
			"payload":        payload,
		}
		if mutating {
			request["base_revision"] = s.Revision()
		}
		if wait != nil {
			request["wait_seconds"] = *wait
		}
		raw, err := json.Marshal(request)
		if err != nil {
			return errReply("chat", 0, fail(CodeInternal, "could not build the command: "+err.Error(), false))
		}
		reply, err := s.Dispatch(raw)
		if err != nil {
			return errReply("chat", 0, fail(CodeInternal, err.Error(), false))
		}
		last = reply
		if reply.OK || reply.Error == nil || reply.Error.Code != CodeStaleRevision {
			return reply
		}
	}
	return last
}

// nextChatRequestID mints the idempotency key for one chat-driven command. It
// is minted rather than derived from the turn because two identical questions
// in one chat are two consultations, not a replay of one.
func (s *Store) nextChatRequestID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.chatSeq++
	return fmt.Sprintf("chat-%d", s.chatSeq)
}

// chatOwner names the project a chat was routed into, for a refusal the user
// can act on. Empty when this process cannot place it.
func (s *Store) chatOwner(chatID string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	owner := s.chatProject[chatID]
	if owner == "" {
		return "unknown"
	}
	return owner
}
