package session

import (
	"fmt"
	"strings"
	"time"
	"unicode"
)

// The chat's directive surface: the lines a user types that Council reads as
// instructions to ITSELF rather than as questions for the council.
//
// Two of them are what a question's option card sends back — the host does not
// report the label a user clicked, it sends the option's KEYSTROKE as an
// ordinary user turn (ChatPane.gd:2385-2391, :2399-2406) — and two are typed by
// hand: `/ask` aims a follow-up at one member, `/bench` reads the latest round.
//
// Every one of them ends in the same place an editor control does. `/ask`
// dispatches the run.start the panel's "Follow up" and "Ask about this" buttons
// dispatch (ui/src/js/app.js sendFollowUp), with the same payload, so the seat
// rules — one seat consulted, a claim answered by its author, a human seat
// never consulted — are the engine's single copy of those rules and not a
// second reading of them. `/bench` starts nothing at all: it reads the record
// the panel renders from.

const (
	SelectCouncilDirective = "/council "
	SelectSessionDirective = "/council-session "
	// AskDirective takes a member and a question; BenchDirective takes nothing.
	AskDirective   = "/ask "
	BenchDirective = "/bench"
)

// Directives returns every directive the turn reader understands, longest
// first: that is the order prefixes have to be tested in where one directive
// begins with another ("/council-session " begins with "/council"), and the
// reader tests those two in it. Anything that documents the chat surface checks
// itself against this rather than against a list of its own, and a directive
// added to the reader without being added here is a directive the help may not
// name.
func Directives() []string {
	return []string{SelectSessionDirective, SelectCouncilDirective, BenchDirective, AskDirective}
}

// directiveArgument recognizes a complete directive token, including missing
// arguments and Unicode whitespace. A mistyped command must reach its refusal
// path rather than become an ordinary question that starts a paid round.
func directiveArgument(text, directive string) (string, bool) {
	token := strings.TrimSpace(directive)
	if text == token {
		return "", true
	}
	head, rest := cutWord(text)
	if head == token {
		return strings.TrimSpace(rest), true
	}
	return "", false
}

func askArgument(text string) (string, bool) {
	return directiveArgument(text, AskDirective)
}

func benchArgument(text string) (string, bool) {
	return directiveArgument(text, BenchDirective)
}

// ---------------------------------------------------------------------------
// /ask — one member, one question
// ---------------------------------------------------------------------------

// askTarget is what a `/ask` line named: a seat, or an argument whose author the
// engine will resolve.
type askTarget struct {
	seatID  string
	claimID string
	// label is what the user called them, for a reply they can act on.
	label string
}

// chatAsk aims a follow-up at one member.
//
// The payload is byte-for-byte the panel's: a seat travels as
// addressed_seat_id + seat_ids, and an argument travels as addressed_claim_id
// ALONE. That last part is the claim-owner rule: run.start resolves a claim to
// the seat that made it and refuses a seat_ids naming anybody else, so a chat
// that never sends a seat beside a claim cannot aim somebody's argument at a
// different member.
func (s *chatScope) chatAsk(chatID, rest string, wait time.Duration) ChatTurnResult {
	route := s.routeChat(chatID)
	if route.foreign {
		return ChatTurnResult{Reply: s.foreignChatRefusal(chatID)}
	}
	if route.sessionID == "" {
		return ChatTurnResult{Reply: chatErrorf("%s", noConsultationRefusal)}
	}
	if rest == "" {
		// The roster travels with the refusal rather than a pointer to /bench:
		// a session whose round has not run yet has no bench to print, so
		// naming one would be advice that answers with nothing.
		return ChatTurnResult{Reply: chatErrorf("%s", strings.TrimSpace(
			"Name the member and say what to ask them: /ask <member> <question>. "+s.sessionRoster(route.sessionID)))}
	}

	target, question, refusal := s.resolveAsk(route.sessionID, rest)
	if refusal != "" {
		return ChatTurnResult{Reply: chatErrorf("%s", refusal)}
	}
	if question == "" {
		return ChatTurnResult{Reply: chatErrorf(
			"That line named %s and asked them nothing. Say what to ask: /ask %s <question>.", target.label, target.label)}
	}
	if length := questionLength(question); length > maxQuestionCharacters {
		return ChatTurnResult{Reply: overlongQuestion(length)}
	}
	// A round already running for this chat is reported, never joined by a
	// second one — the same rule a plain turn gets, for the same reason: the
	// host has no idea a turn is still in flight and let the user type again.
	if route.hasLive {
		return s.chatAwait(chatID, route.live, question, wait)
	}

	payload := map[string]any{
		"session_id": route.sessionID,
		"kind":       "follow_up",
		"prompt":     question,
	}
	if target.claimID != "" {
		payload["addressed_claim_id"] = target.claimID
	} else {
		payload["addressed_seat_id"] = target.seatID
		payload["seat_ids"] = []any{target.seatID}
	}
	return s.chatRound(chatID, route.sessionID, payload, wait, s.consultedNote(route.sessionID))
}

// consultedNote says who the round actually asked.
//
// It reads the seats off the RUN rather than off what the directive aimed at,
// because those are not always the same thing: an argument is routed to its
// author, and the engine is what decides who that is. Reporting the aim would
// be a second answer to a question the run has already answered.
func (s *chatScope) consultedNote(sessionID string) func(map[string]any) string {
	return func(payload map[string]any) string {
		var seats []string
		for _, x := range arr(payload["contributions"]) {
			seats = append(seats, s.seatLabel(sessionID, str(obj(x)["seat_id"])))
		}
		switch len(seats) {
		case 0:
			return ""
		case 1:
			return "Only " + seats[0] + " was consulted; nobody else on the bench was asked again."
		default:
			return "Only these members were consulted: " + strings.Join(seats, ", ") +
				". Nobody else on the bench was asked again."
		}
	}
}

// noConsultationRefusal is what `/ask` and `/bench` say in a chat that has no
// session. Both refuse with the way to start one, because a directive that
// silently opened a consultation would spend money the user did not ask to
// spend.
const noConsultationRefusal = "This chat has no Council consultation yet, so there is nobody to ask and no bench to read. " +
	"Ask your question here and Council will open one, or point this chat at a consultation that already exists with /council-session <session_id>."

// resolveAsk splits a `/ask` line into who it named and what it asked them.
//
// The name is matched by LONGEST leading run of words, because a display name
// has spaces in it ("Okonkwo (workshop essay)") and there is no separator to
// rely on. Every seat answers to three names — its seat id, its member id and
// the member's display name — and every claim in the session answers to its
// claim id. A name matching more than one seat, or none, is refused with the
// roster: guessing which member the user meant is the one thing this must not
// do.
func (s *Store) resolveAsk(sessionID, rest string) (askTarget, string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	session, _ := findByID(s.snapshot["sessions"], "session_id", sessionID)
	if session == nil {
		return askTarget{}, "", noConsultationRefusal
	}
	def := obj(session["definition_snapshot"])
	byName := map[string][]askTarget{}
	add := func(name string, target askTarget) {
		key := foldName(name)
		if key == "" {
			return
		}
		for _, held := range byName[key] {
			if held.seatID == target.seatID && held.claimID == target.claimID {
				return
			}
		}
		byName[key] = append(byName[key], target)
	}
	labels, displays := memberLabels(def), memberDisplayNames(def)
	for _, x := range arr(def["seats"]) {
		seat := obj(x)
		id := str(seat["seat_id"])
		target := askTarget{seatID: id, label: labels[id]}
		add(id, target)
		add(str(seat["member_id"]), target)
		// Both the display name as the member record spells it and the label a
		// reply prints, because the label carries a suffix ("(chair)") the user
		// reads and would reasonably type back.
		add(displays[str(seat["member_id"])], target)
		add(labels[id], target)
	}
	for _, r := range arr(session["runs"]) {
		run := obj(r)
		for _, c := range append(append([]any{}, arr(run["contributions"])...), synthesisOf(run)...) {
			contribution := obj(c)
			seatID := str(contribution["seat_id"])
			for _, x := range arr(contribution["claims"]) {
				claimID := str(obj(x)["claim_id"])
				add(claimID, askTarget{
					claimID: claimID,
					label:   fmt.Sprintf("the member that argued %s (%s)", claimID, labels[seatID]),
				})
			}
		}
	}

	// Longest wins: "Operator (you)" must beat "Operator" when both are names,
	// and a name is never allowed to swallow the question because the scan
	// stops at the last run of words that actually matched something.
	var (
		matched   []askTarget
		remainder string
		named     string
	)
	taken, tail := []string{}, rest
	for len(taken) < maxNameWords {
		word, next := cutWord(tail)
		if word == "" {
			break
		}
		taken, tail = append(taken, word), next
		// The name as typed, and the name with the punctuation a user puts
		// between it and their question ("/ask Costing, what changes?"). Only
		// the END is trimmed, so a display name that carries a comma of its own
		// still matches as written.
		name := strings.Join(taken, " ")
		for _, candidate := range []string{name, strings.TrimRight(name, " :,")} {
			if found := byName[foldName(candidate)]; len(found) > 0 {
				matched, remainder, named = found, tail, candidate
				break
			}
		}
	}
	switch {
	case len(matched) == 0:
		// Everything the scan tried, not just its first word: a user who typed
		// "Dr Okonkwo" needs to see that all of it was looked for and none of
		// it found, rather than a refusal about "Dr".
		return askTarget{}, "", fmt.Sprintf(
			"There is nobody called %q on this council, and no argument by that id. %s",
			strings.Join(taken, " "), rosterSentence(def))
	case len(matched) > 1:
		var ids []string
		for _, target := range matched {
			ids = append(ids, target.seatID)
		}
		return askTarget{}, "", fmt.Sprintf(
			"%q names more than one member here (%s), so Council will not guess which you meant. Ask again by seat id. %s",
			named, strings.Join(ids, ", "), rosterSentence(def))
	}
	return matched[0], strings.TrimSpace(strings.TrimLeft(remainder, ":,")), ""
}

// maxNameWords bounds how much of a `/ask` line may be read as a name. It is
// generous enough for the longest display name a member record allows to be
// worth typing and short enough that a mistyped name cannot consume the whole
// question before the scan gives up.
const maxNameWords = 8

// cutWord takes the first whitespace-separated word and returns the rest with
// its leading whitespace removed. It works on the ORIGINAL text rather than on
// a re-joined field list, so whatever spacing the user typed inside their
// question survives into the run's prompt.
func cutWord(text string) (string, string) {
	text = strings.TrimLeftFunc(text, unicode.IsSpace)
	if text == "" {
		return "", ""
	}
	if cut := strings.IndexFunc(text, unicode.IsSpace); cut >= 0 {
		return text[:cut], strings.TrimLeftFunc(text[cut:], unicode.IsSpace)
	}
	return text, ""
}

// foldName is how two names are compared: case and surrounding space are not
// something a user should have to reproduce.
func foldName(name string) string {
	return strings.ToLower(strings.TrimSpace(name))
}

// ---------------------------------------------------------------------------
// /bench — the latest round, attributed
// ---------------------------------------------------------------------------

// chatBench renders the latest round's contributions. It runs no command and
// starts nothing: the record already holds every word of it, and a directive
// that consulted somebody to answer "who is on the bench" would spend money to
// report what was already written down.
func (s *chatScope) chatBench(chatID, extra string) ChatReply {
	route := s.routeChat(chatID)
	if route.foreign {
		return s.foreignChatRefusal(chatID)
	}
	if route.sessionID == "" {
		return chatErrorf("%s", noConsultationRefusal)
	}
	text := s.benchText(route.sessionID)
	if text == "" {
		return chatErrorf("This chat's consultation is no longer in the open document. Reopen it and ask again.")
	}
	if extra != "" {
		text += "\n\n/bench takes no argument, so " + fmt.Sprintf("%q", extra) +
			" was not asked. Aim it at one member with /ask <member> <question>."
	}
	return ChatReply{Kind: ChatAnswer, Text: text}
}

// benchText derives the reply from the record under the engine's own lock.
func (s *Store) benchText(sessionID string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	session, _ := findByID(s.snapshot["sessions"], "session_id", sessionID)
	if session == nil {
		return ""
	}
	return renderBench(session)
}

// maxBenchClaimBytes bounds the claim text one reply carries. A round of five
// members each making several claims can run past what a chat message is worth
// reading, and the arguments themselves are in the editor — so claims are what
// gets dropped when the budget runs out, and every member still gets their line.
const maxBenchClaimBytes = 6000

// renderBench is the whole of `/bench`, over one session record.
//
// It is a separate derivation from the wrapper's context_text, and deliberately
// so: context_text hands a chat or an LLM the ARGUMENTS (question, state, the
// text of the complete contributions), while this is a roster — who answered,
// on what model, with what support labels and in what state. They report
// different things about the same run, and neither restates the other.
func renderBench(session map[string]any) string {
	lines := []string{
		"Council session: " + str(session["question"]),
		"Status: " + str(session["status"]),
	}
	runs := arr(session["runs"])
	if len(runs) == 0 {
		return strings.Join(append(lines, "",
			"No round has run yet, so there is nothing on the bench. Ask your question and the council will take it up."), "\n")
	}
	run := obj(runs[len(runs)-1])
	labels := memberLabels(obj(session["definition_snapshot"]))
	lines = append(lines, fmt.Sprintf("Latest round: %s (%s, %s), the newest of %d in this session.",
		str(run["run_id"]), str(run["kind"]), str(run["status"]), len(runs)))
	if prompt := str(run["prompt"]); prompt != "" {
		lines = append(lines, "Asked: "+prompt)
	}

	budget := maxBenchClaimBytes
	for _, x := range arr(run["contributions"]) {
		contribution := obj(x)
		seatID := str(contribution["seat_id"])
		model := str(contribution["model_id"])
		if model == "" {
			model = "model not recorded"
		}
		lines = append(lines, "", fmt.Sprintf("%s [%s] — %s — %s",
			labels[seatID], seatID, model, str(contribution["status"])))
		if message := str(obj(contribution["failure"])["message"]); message != "" {
			lines = append(lines, "  "+message)
		}
		claims := arr(contribution["claims"])
		for i, c := range claims {
			claim := obj(c)
			line := fmt.Sprintf("  [%s] %s  (%s)",
				str(claim["support"]), str(claim["text"]), str(claim["claim_id"]))
			if len(line) > budget {
				lines = append(lines, fmt.Sprintf("  %d more claim(s) — read them in the Council editor.", len(claims)-i))
				break
			}
			budget -= len(line)
			lines = append(lines, line)
		}
	}

	if len(synthesisOf(run)) > 0 {
		lines = append(lines, "", "The chair's synthesis of this round is the answer already in this chat.")
	}
	return strings.Join(append(lines, "",
		"Each argument in full, its sources and the side-by-side comparison are in the Council editor. "+
			"Ask one member again with /ask <member> <question>, or one argument by its claim id."), "\n")
}

// ---------------------------------------------------------------------------
// naming the bench
// ---------------------------------------------------------------------------

// memberDisplayNames is what each member calls itself, keyed by member id, with
// its id standing in when the record carries no display name.
func memberDisplayNames(def map[string]any) map[string]string {
	names := map[string]string{}
	for _, x := range arr(def["members"]) {
		member := obj(x)
		id := str(member["member_id"])
		if name := str(member["display_name"]); name != "" {
			names[id] = name
		} else {
			names[id] = id
		}
	}
	return names
}

// memberLabels is what each seat is CALLED in a reply, keyed by seat id: the
// member's display name, plus the one fact about the seat a reader needs beside
// it. A human seat carries it because it is the one seat no round will ever
// consult.
func memberLabels(def map[string]any) map[string]string {
	kindOf := map[string]string{}
	for _, x := range arr(def["members"]) {
		member := obj(x)
		kindOf[str(member["member_id"])] = str(member["kind"])
	}
	nameOf := memberDisplayNames(def)
	labels := map[string]string{}
	for _, x := range arr(def["seats"]) {
		seat := obj(x)
		memberID := str(seat["member_id"])
		label := nameOf[memberID]
		if label == "" {
			label = memberID
		}
		switch {
		case kindOf[memberID] == "human":
			label += " (you — never consulted)"
		case str(seat["role"]) == "chair":
			label += " (chair)"
		}
		labels[str(seat["seat_id"])] = label
	}
	return labels
}

// seatLabel names one seat of one session for a reply.
func (s *Store) seatLabel(sessionID, seatID string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	session, _ := findByID(s.snapshot["sessions"], "session_id", sessionID)
	if session == nil {
		return seatID
	}
	if label := memberLabels(obj(session["definition_snapshot"]))[seatID]; label != "" {
		return label
	}
	return seatID
}

// sessionRoster is the roster of the council one session pinned.
func (s *Store) sessionRoster(sessionID string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	session, _ := findByID(s.snapshot["sessions"], "session_id", sessionID)
	if session == nil {
		return ""
	}
	return rosterSentence(obj(session["definition_snapshot"]))
}

// rosterSentence lists who can be asked. Every refusal to guess carries it:
// "that is not a member here" without saying who is leaves the user typing
// names until one lands.
func rosterSentence(def map[string]any) string {
	labels := memberLabels(def)
	var seats []string
	for _, x := range arr(def["seats"]) {
		id := str(obj(x)["seat_id"])
		seats = append(seats, fmt.Sprintf("%s [%s]", labels[id], id))
	}
	if len(seats) == 0 {
		return "This council has no seats to ask."
	}
	return "The seats are: " + strings.Join(seats, "; ") + "."
}
