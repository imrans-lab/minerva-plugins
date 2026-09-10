package main

import (
	"strings"
	"testing"

	"github.com/ipeerbhai/plugins/council/internal/session"
)

// ---------------------------------------------------------------------------
// /ask and /bench
// ---------------------------------------------------------------------------

// TestCouncilChatAimsAtOneMemberAndReadsTheBench covers the two directives a
// user types by hand, on a council with TWO advisors — which is what makes
// "only one seat was consulted" a claim with something to be wrong about.
//
// The oracles, in order of use:
//
//   - the fake host's model calls, counted and attributed by the display name
//     in each call's system prompt (internal/session/prompt.go memberSystem);
//     a seat that was not asked has no call, and that is not observable from
//     the record afterwards.
//   - the advisor prompt itself, for what a follow-up carries: the question,
//     and nothing another member said.
//   - the RECORD, for /bench: every line of the reply is held against the
//     contributions the store exports.
func TestCouncilChatAimsAtOneMemberAndReadsTheBench(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)
	host.answerWith(benchAnswer)
	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")
	seedDefinition(t, host, store, 2, twoAdvisorCouncil(t), "req-seed")

	const chatID = "chat-bench"
	opened := host.turn(3, chatID, "How much capacity should the workshop hold?")
	if kind := str(opened["kind"]); kind != session.ChatAnswer {
		t.Fatalf("the opening round must answer: %v", opened)
	}
	sessionID := sessionBoundTo(t, store, chatID)
	if sessionID == "" {
		t.Fatal("the turn must leave a session bound to its chat")
	}
	// Two advisors and the chair. The human seat is on this council and is not
	// one of them: nothing prompts the local user, in chat or anywhere else.
	if calls := host.modelCalls(); len(calls) != 3 {
		t.Fatalf("two advisors plus the chair is three calls; the host saw %d", len(calls))
	}
	if asked := callsNaming(host.modelCalls(), "Operator (you)"); asked != 0 {
		t.Fatalf("a human-held seat is never consulted; the host saw %d call(s) to it", asked)
	}

	// -------------------------------------------------------------------
	// /ask <display name> — a name with spaces in it, and one seat asked
	// -------------------------------------------------------------------
	before := len(host.modelCalls())
	const focused = "what changes if the hard week is shorter?"
	// The comma is the punctuation a person puts between the name and the
	// question. It has to be read as a separator, not as part of either.
	aimed := host.turn(4, chatID, "/ask Okonkwo (workshop essay), "+focused)
	if kind := str(aimed["kind"]); kind != session.ChatAnswer {
		t.Fatalf("an aimed follow-up answers with the chair's revised synthesis: %v", aimed)
	}
	round := host.modelCalls()[before:]
	if len(round) != 2 {
		t.Fatalf("one advisor plus the chair is two calls; the round made %d", len(round))
	}
	if asked := callsNaming(round, "Costing"); asked != 0 {
		t.Fatalf("the other advisor must not be re-asked; the host saw %d call(s) to them", asked)
	}
	advisor := round[0]
	if !strings.Contains(systemOf(advisor), "Okonkwo (workshop essay)") {
		t.Fatalf("the follow-up must reach the member it named; it reached %q", systemOf(advisor))
	}
	if !strings.Contains(promptOf(advisor), focused) {
		t.Errorf("the addressed question must reach the member: %q", promptOf(advisor))
	}
	// The isolation rule holds from chat too: a member is never shown another
	// member's answer, and costingToken appears in exactly one member's reply.
	if strings.Contains(promptOf(advisor), costingToken) {
		t.Error("a follow-up must carry nothing another member said")
	}
	if !strings.Contains(str(aimed["text"]), "Only Okonkwo (workshop essay) was consulted") {
		t.Errorf("the reply must say plainly that one seat was consulted: %q", aimed["text"])
	}
	if runs := runCount(t, store, sessionID); runs != 2 {
		t.Fatalf("the directive is one round; the session holds %d", runs)
	}

	// -------------------------------------------------------------------
	// /bench — the latest round, read from the record, spending nothing
	// -------------------------------------------------------------------
	before = len(host.modelCalls())
	bench := host.turn(5, chatID, "/bench")
	if kind := str(bench["kind"]); kind != session.ChatAnswer {
		t.Fatalf("/bench answers from the record: %v", bench)
	}
	if now := len(host.modelCalls()); now != before {
		t.Fatalf("/bench consults nobody; the host saw %d new model call(s)", now-before)
	}
	text := str(bench["text"])
	// The oracle is the record: every attribution the reply makes is held
	// against the contribution it came from, rather than against a copy of the
	// expected string written here.
	last := lastRun(t, store, sessionID)
	for _, x := range last["contributions"].([]any) {
		contribution := x.(map[string]any)
		for label, value := range map[string]string{
			"seat":   str(contribution["seat_id"]),
			"model":  str(contribution["model_id"]),
			"status": str(contribution["status"]),
		} {
			if value == "" || !strings.Contains(text, value) {
				t.Errorf("/bench must carry each contribution's %s; %q is not in %q", label, value, text)
			}
		}
		claims, _ := contribution["claims"].([]any)
		if len(claims) == 0 {
			t.Fatal("this round's member answered with claims; the fixture is what makes the label assertion meaningful")
		}
		for _, c := range claims {
			claim := c.(map[string]any)
			if !strings.Contains(text, "["+str(claim["support"])+"]") {
				t.Errorf("/bench must label each claim source/inference/unknown; %q lacks %q", text, claim["support"])
			}
			if !strings.Contains(text, str(claim["text"])) {
				t.Errorf("/bench must carry the claim as recorded: %q", claim["text"])
			}
			if !strings.Contains(text, str(claim["claim_id"])) {
				t.Errorf("/bench must name each claim id; it is how one argument is asked about again: %q", text)
			}
		}
	}
	// The LATEST round, not every round. The first round consulted seat-costing
	// and this one did not, so its absence is the assertion.
	if strings.Contains(text, "seat-costing") {
		t.Errorf("/bench renders the latest round alone; it named a seat that round did not consult: %q", text)
	}
	if !strings.Contains(text, "Council editor") {
		t.Errorf("/bench must point at where the arguments can be inspected and compared: %q", text)
	}

	// Another session in the same document is another chat's consultation, and
	// nothing of it may appear here.
	const otherQuestion = "OTHER-SESSION-QUESTION-4b19"
	if kind := str(host.turn(6, "chat-elsewhere", otherQuestion)["kind"]); kind != session.ChatAnswer {
		t.Fatal("the second chat must open a session of its own")
	}
	again := str(host.turn(7, chatID, "/bench")["text"])
	if strings.Contains(again, otherQuestion) {
		t.Errorf("/bench reads this chat's session alone: %q", again)
	}

	// -------------------------------------------------------------------
	// /ask <claim id> — the claim-owner rule, from chat
	//
	// The claim was argued by seat-costing in the first round. The directive
	// names the ARGUMENT and no seat at all, so the seat that answers is the
	// one the engine resolves from the claim — never the member the previous
	// follow-up happened to address.
	// -------------------------------------------------------------------
	claimID, author := aClaimBy(t, store, sessionID, "seat-costing")
	before = len(host.modelCalls())
	about := host.turn(8, chatID, "/ask "+claimID+" is that still true at half demand?")
	if kind := str(about["kind"]); kind != session.ChatAnswer {
		t.Fatalf("asking about an argument answers: %v", about)
	}
	round = host.modelCalls()[before:]
	if len(round) != 2 {
		t.Fatalf("one advisor plus the chair is two calls; the round made %d", len(round))
	}
	if asked := callsNaming(round, "Okonkwo (workshop essay)"); asked != 0 {
		t.Fatalf("an argument is answered by its author alone; the host saw %d call(s) to another member", asked)
	}
	if !strings.Contains(systemOf(round[0]), "Costing") {
		t.Errorf("the claim's author must be the seat consulted; the call went to %q", systemOf(round[0]))
	}
	if got := str(lastRun(t, store, sessionID)["addressed_seat_id"]); got != author {
		t.Errorf("the run must record the claim's author as the seat addressed; got %q, want %q", got, author)
	}
}

// TestCouncilChatRefusesAMemberItCannotPlace covers every way `/ask` and
// `/bench` decline, because each of them is a refusal to guess or to spend.
//
// The council here seats two advisors sharing one display name, which is the
// ambiguity a user creates by naming two members the same thing; the oracle for
// every case is the host's model-call count, which must stay where it was.
func TestCouncilChatRefusesAMemberItCannotPlace(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)
	host.answerWith(benchAnswer)
	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")

	// A chat with no consultation refuses both directives, and says how one is
	// started. Before anything is seeded, because that is the state a user who
	// typed /bench first is actually in.
	for id, text := range map[int]string{9: "/ask somebody what now?", 10: "/bench"} {
		reply := host.turn(id, "chat-empty", text)
		if kind := str(reply["kind"]); kind != session.ChatError {
			t.Fatalf("%q in a chat with no session is a refusal: %v", text, reply)
		}
		if !strings.Contains(str(reply["text"]), "/council-session") {
			t.Errorf("%q must be refused with the way to start or point at a consultation: %q", text, reply["text"])
		}
	}

	definition := twoAdvisorCouncil(t)
	// Two members that call themselves the same thing. Council will not choose
	// between them, and the seat ids are how a user resolves it.
	for _, x := range definition["members"].([]any) {
		if member := x.(map[string]any); member["member_id"] == "mem-costing" {
			member["display_name"] = "Okonkwo (workshop essay)"
		}
	}
	seedDefinition(t, host, store, 2, definition, "req-seed")

	const chatID = "chat-refusals"
	if kind := str(host.turn(3, chatID, "How much capacity should the workshop hold?")["kind"]); kind != session.ChatAnswer {
		t.Fatal("the opening round must answer before a follow-up can be refused")
	}
	sessionID := sessionBoundTo(t, store, chatID)
	settled := len(host.modelCalls())

	cases := []struct {
		name  string
		turn  string
		wants []string
	}{{
		name: "a name nobody answers to",
		turn: "/ask Nobody what would you change?",
		// The roster is what makes the refusal actionable.
		wants: []string{"Nobody", "seat-capacity", "seat-costing"},
	}, {
		name:  "a name two members answer to",
		turn:  "/ask Okonkwo (workshop essay) which of you is it?",
		wants: []string{"more than one", "seat-capacity", "seat-costing"},
	}, {
		name: "a seat held by the local user",
		turn: "/ask seat-observed what did you see on the bench?",
		// The engine's own rule, reached through the same run.start the panel
		// sends: Council does not put words in a human member's mouth.
		wants: []string{"human member"},
	}, {
		name:  "a member named and nothing asked",
		turn:  "/ask seat-capacity",
		wants: []string{"asked them nothing"},
	}, {
		name: "the bare directive",
		// A turn is trimmed before the reader sees it, so this is the case a
		// prefix-only match would let through — as an ordinary question, buying
		// a full round of the bench with "/ask" as the question. The call count
		// below is what says it did not.
		turn:  "/ask",
		wants: []string{"/ask <member> <question>"},
	}}
	for id, tc := range cases {
		reply := host.turn(20+id, chatID, tc.turn)
		if kind := str(reply["kind"]); kind != session.ChatError {
			t.Errorf("%s: must be refused, got %v", tc.name, reply)
			continue
		}
		for _, want := range tc.wants {
			if !strings.Contains(str(reply["text"]), want) {
				t.Errorf("%s: the refusal must carry %q; got %q", tc.name, want, reply["text"])
			}
		}
	}
	if now := len(host.modelCalls()); now != settled {
		t.Errorf("a refusal spends nothing; the host saw %d new model call(s)", now-settled)
	}
	if runs := runCount(t, store, sessionID); runs != 1 {
		t.Errorf("a refused directive starts no round; the session holds %d", runs)
	}
}

// benchAnswer is the fake host's per-member reply. Members are told apart by
// the display name their system prompt carries, which is the only attribution
// on the wire (host.providers.chat sends messages and a model, never a seat).
func benchAnswer(args map[string]any) string {
	system := systemOf(args)
	switch {
	case strings.Contains(system, "chairing a council"):
		return modelAnswer("The two members disagree about which number describes the bench.",
			map[string]any{"support": "inference", "text": "They are measuring different weeks."})
	// Matched on the member's SCOPE rather than its display name: one test
	// deliberately gives two members the same name, and the answers still have
	// to tell them apart.
	case strings.Contains(system, "against the bench time it consumes"):
		return modelAnswer(costingToken+": the order earns 28 units of revenue for 40 units of bench time.",
			map[string]any{"support": "inference", "text": "The order costs twelve units of margin a month."},
			map[string]any{"support": "unknown", "text": "Whether the freed hours have a better use is not established."})
	default:
		return modelAnswer(capacityToken+": price it against the worst week.",
			sourceClaim("A recurring order removes the freedom to decline work.",
				"src-capacity-essay", 2, "anc-freedom"))
	}
}

// systemOf and promptOf read one recorded model call. The shape is the host's:
// {messages:[{role:"system"},{role:"user"}], model} (hostchat.go Generate).
func systemOf(args map[string]any) string { return messageOf(args, "system") }
func promptOf(args map[string]any) string { return messageOf(args, "user") }

func messageOf(args map[string]any, role string) string {
	messages, _ := args["messages"].([]any)
	for _, x := range messages {
		message, _ := x.(map[string]any)
		if str(message["role"]) == role {
			return str(message["content"])
		}
	}
	return ""
}

// callsNaming counts the recorded calls whose member is the one named.
func callsNaming(calls []map[string]any, display string) int {
	found := 0
	for _, call := range calls {
		if strings.Contains(systemOf(call), display) {
			found++
		}
	}
	return found
}

// twoAdvisorCouncil is the workshop fixture with a second advisor seated beside
// the first. Two advisors are what make "one seat was consulted" falsifiable;
// the fixture's human seat stays, because "never consulted" needs a human seat
// to be true about.
func twoAdvisorCouncil(t *testing.T) map[string]any {
	t.Helper()
	definition := workshopDefinition(t)
	definition["members"] = append(definition["members"].([]any), map[string]any{
		"member_id":       "mem-costing",
		"member_revision": 1,
		"kind":            "assistant",
		"display_name":    "Costing",
		"scope":           "What an order earns against the bench time it consumes.",
		"limitations":     "Has no material about this shop; it reasons from what it is told.",
		"grounding":       []any{},
	})
	definition["seats"] = append(definition["seats"].([]any), map[string]any{
		"seat_id":        "seat-costing",
		"member_id":      "mem-costing",
		"responsibility": "Argue the margin consequences.",
		"role":           "advisor",
	})
	return definition
}

func seedDefinition(t *testing.T, host *providerHost, store *session.Store, id int, definition map[string]any, requestID string) {
	t.Helper()
	reply := host.tool(id, "minerva_council_command", map[string]any{
		"request_id":    requestID,
		"command":       "definition.upsert",
		"base_revision": store.Revision(),
		"payload":       map[string]any{"definition": definition},
	})
	if ok, _ := reply["ok"].(bool); !ok {
		t.Fatalf("definition.upsert: %v", reply)
	}
}

// lastRun is the round /bench renders: the newest, because runs are appended.
func lastRun(t *testing.T, store *session.Store, sessionID string) map[string]any {
	t.Helper()
	runs, _ := sessionRecord(t, store, sessionID)["runs"].([]any)
	if len(runs) == 0 {
		t.Fatalf("session %q holds no run", sessionID)
	}
	run, _ := runs[len(runs)-1].(map[string]any)
	return run
}

// aClaimBy finds a claim one seat argued, and returns it with its author.
func aClaimBy(t *testing.T, store *session.Store, sessionID, seatID string) (string, string) {
	t.Helper()
	runs, _ := sessionRecord(t, store, sessionID)["runs"].([]any)
	for _, r := range runs {
		run, _ := r.(map[string]any)
		contributions, _ := run["contributions"].([]any)
		for _, x := range contributions {
			contribution, _ := x.(map[string]any)
			if str(contribution["seat_id"]) != seatID {
				continue
			}
			claims, _ := contribution["claims"].([]any)
			for _, c := range claims {
				claim, _ := c.(map[string]any)
				if id := str(claim["claim_id"]); id != "" {
					return id, seatID
				}
			}
		}
	}
	t.Fatalf("no claim by %s was recorded in session %s", seatID, sessionID)
	return "", ""
}
