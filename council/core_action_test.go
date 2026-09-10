package main

import (
	"reflect"
	"strings"
	"testing"

	"github.com/ipeerbhai/plugins/council/internal/session"
)

// TurnRock/Core actions as council members.
//
// Core has no static model list: its models are the live service actions of the
// running Core node, and an action is reached by the structured model_spec the
// host listed it with — never by name, because two services may expose an
// action of the same name and only the pair identifies one. These tests hold
// the whole of that path, from the catalogue read to the bytes on the wire,
// against the host contract in CapabilityBroker.gd and singleton_object.gd.
//
// The oracle for every assertion is named where it is made. The fake host is
// the one double: everything on the plugin's side of the pipe is the shipped
// backend.

const coreAction = "qwen3-8b"

// hintedCouncil is the two-advisor workshop council with a model hint on each
// advisor, which is what makes "this member was asked with that model"
// falsifiable — the seats differ only by what they were told and what they were
// asked with. seat-capacity is held by mem-okonkwo, the fixture's simulant; the
// council's human seat keeps its place and is never consulted.
func hintedCouncil(t *testing.T, costingHint, capacityHint string) map[string]any {
	t.Helper()
	definition := twoAdvisorCouncil(t)
	for _, x := range definition["members"].([]any) {
		member, _ := x.(map[string]any)
		switch str(member["member_id"]) {
		case "mem-costing":
			member["model_hint"] = costingHint
		case "mem-okonkwo":
			member["model_hint"] = capacityHint
		}
	}
	return definition
}

// specOf reads the model_spec off one recorded call, and says whether the call
// carried one at all. An absent spec and an empty one are different claims: the
// broker refuses a spec with no kind, so sending {} would break a call that
// works today.
func specOf(call map[string]any) (map[string]any, bool) {
	spec, ok := call["model_spec"].(map[string]any)
	return spec, ok
}

// requireCoreActionListed re-reads the host's catalogue through the tool that
// exists for it, and holds the reply to the one thing this whole feature turns
// on: a Core action reaches Council as an ordinary catalogue entry, under the
// turnrock provider, named by its action name. It also makes the read
// deterministic — the startup read runs on its own goroutine, and a round
// planned against a catalogue that had not landed yet would check nothing.
func requireCoreActionListed(t *testing.T, host *providerHost, id int) {
	t.Helper()
	body := host.tool(id, "minerva_council_models", map[string]any{})
	if known, _ := body["known"].(bool); !known {
		t.Fatalf("the host answered the catalogue, so it must be known: %v", body)
	}
	listed, _ := body["models"].([]any)
	for _, x := range listed {
		model, _ := x.(map[string]any)
		if str(model["provider_key"]) == "turnrock" && str(model["model_name"]) == coreAction {
			return
		}
	}
	t.Fatalf("the Core action must reach the catalogue as an ordinary model: %v", listed)
}

// A member on a Core action is consulted with the exact model_spec the host
// listed, and a member on an ordinary provider model is called exactly as
// before.
func TestACoreActionMemberIsAskedWithTheHostsOwnModelSpec(t *testing.T) {
	for _, mixedCase := range []bool{false, true} {
		name := "same_case"
		if mixedCase {
			name = "case_variant"
		}
		t.Run(name, func(t *testing.T) { assertCoreMemberSpec(t, mixedCase) })
	}
}

func assertCoreMemberSpec(t *testing.T, mixedCase bool) {
	t.Helper()
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)
	host.answerWith(benchAnswer)
	// Installed before initialize, because the backend reads the catalogue as
	// part of its startup handshake. Two services expose the SAME action name,
	// which Core allows: the name cannot pick between them, so the listing's
	// order has to — and the first is what both sides resolve to.
	specs := host.offerCoreAction(coreAction, "model-chat", "model-chat-gpu")
	if mixedCase {
		host.mu.Lock()
		host.models["turnrock"][1]["model_name"] = strings.ToUpper(coreAction)
		specs[1]["action_name"] = strings.ToUpper(coreAction)
		host.mu.Unlock()
	}

	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")
	// The catalogue is read on its own goroutine at startup, so it is re-read
	// here rather than waited on: the tool's own refresh is what makes the
	// listing this round is planned against a fact of this test.
	requireCoreActionListed(t, host, 2)
	// Costing is on the Core action; capacity is on an ordinary provider model
	// the fake host lists (providerHost's own catalogue).
	seedDefinition(t, host, store, 3, hintedCouncil(t, coreAction, "gpt-test"), "req-seed-core")

	const chatID = "chat-core"
	answer := host.turn(4, chatID, "Should the workshop take the recurring order?")
	if kind := str(answer["kind"]); kind != session.ChatAnswer {
		t.Fatalf("the round must produce an answer; got %v", answer)
	}

	calls := host.modelCalls()
	if len(calls) != 3 {
		t.Fatalf("two advisors and a chair make three calls, got %d", len(calls))
	}
	var core, provider map[string]any
	for _, call := range calls {
		system := systemOf(call)
		switch {
		case strings.Contains(system, "against the bench time it consumes"):
			core = call
		case strings.Contains(system, "chairing a council"):
			// The chair has no hint, so it takes the catalogue's first entry.
		default:
			provider = call
		}
	}
	if core == nil || provider == nil {
		t.Fatalf("both advisors must have been asked; the host saw %d calls", len(calls))
	}

	// The spec travels byte-for-byte. Council never reads inside it, so an
	// equality check is the whole contract: what the host listed is what the
	// host is handed back (CapabilityBroker.gd's core_action branch resolves
	// service_client_id + action_name).
	got, carried := specOf(core)
	if !carried {
		t.Fatalf("a member on a Core action must be called with model_spec; the call carried %v", core)
	}
	if !reflect.DeepEqual(got, specs[0]) {
		t.Errorf("model_spec must be the listing's own dictionary\n got  %v\n want %v", got, specs[0])
	}
	// The tie-break, stated as its own claim: with the name held twice, the
	// FIRST listed service is the one consulted — the host's rule for a
	// name-only Core choice (singleton_object.gd create_provider_for), which
	// Council matches by keeping the listing's order through a stable sort.
	if service := str(got["service_client_id"]); service != "model-chat" {
		t.Errorf("a name held by two services resolves to the first listed; got %q", service)
	}
	if reflect.DeepEqual(got, specs[1]) {
		t.Error("the second service's action must not be the one consulted")
	}
	// The name goes too, so a host log and a Council record agree about what was
	// asked for, but it is the spec that does the routing.
	if name := str(core["model"]); name != coreAction {
		t.Errorf("the call must still name the model it asked for, got %q", name)
	}

	// A provider model is called exactly as it was before this existed. An empty
	// object here would be refused by the broker as a spec with no kind.
	if _, carried := specOf(provider); carried {
		t.Errorf("a provider model must carry no model_spec at all, got %v", provider["model_spec"])
	}
	if name := str(provider["model"]); name != "gpt-test" {
		t.Errorf("the provider member is asked by name, got %q", name)
	}

	// What is RECORDED is what answered: the host's own name for the action,
	// which is not the name that was asked for. Oracle: CoreProvider.model_name
	// is "<service> (<action>)", which the fake host reproduces.
	run := lastRun(t, store, sessionBoundTo(t, store, chatID))
	var recorded string
	for _, x := range run["contributions"].([]any) {
		contribution, _ := x.(map[string]any)
		if str(contribution["seat_id"]) == "seat-costing" {
			recorded = str(contribution["model_id"])
		}
	}
	if want := "model-chat (" + coreAction + ")"; recorded != want {
		t.Errorf("the contribution records the model that answered; got %q, want %q", recorded, want)
	}
}

// A hint naming an action the host does not list is refused before the round
// exists, and the refusal names what does exist.
func TestAnUnlistedCoreActionIsRefusedBeforeAnythingIsSpent(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	store.SetClock(func() string { return "2026-01-01T00:00:00Z" })
	host := newProviderHost(t, store)
	host.answerWith(benchAnswer)
	host.offerCoreAction(coreAction)

	host.rpc(1, "initialize", map[string]any{})
	host.awaitCapability("host.chat_providers.register")
	requireCoreActionListed(t, host, 2)
	// definition.upsert does not check model hints — only member.upsert and
	// run.start do — so a whole council can arrive naming an action this host
	// has never heard of, which is exactly the import case.
	seedDefinition(t, host, store, 3, hintedCouncil(t, "qwen3-70b", "gpt-test"), "req-seed-unlisted")

	before := len(host.modelCalls())
	created := host.tool(4, "minerva_council_command", map[string]any{
		"request_id":    "req-session-unlisted",
		"command":       "session.create",
		"base_revision": store.Revision(),
		"payload": map[string]any{
			"session_id":    "ses-unlisted",
			"definition_id": "def-workshop-economics",
			"question":      "Should the workshop take the recurring order?",
			"chat_id":       "chat-unlisted",
		},
	})
	if ok, _ := created["ok"].(bool); !ok {
		t.Fatalf("session.create: %v", created)
	}
	started := host.tool(5, "minerva_council_command", map[string]any{
		"request_id":    "req-run-unlisted",
		"command":       "run.start",
		"base_revision": store.Revision(),
		"payload": map[string]any{
			"session_id": "ses-unlisted",
			"kind":       "initial_round",
			"prompt":     "Should the workshop take the recurring order?",
		},
	})
	if ok, _ := started["ok"].(bool); ok {
		t.Fatalf("a run naming a model the host does not have must be refused; got %v", started)
	}
	failure, _ := started["error"].(map[string]any)
	if code := str(failure["code"]); code != session.CodeModelUnavailable {
		t.Errorf("the refusal is %q, got %q", session.CodeModelUnavailable, code)
	}
	// Naming what exists is the difference between a refusal a user can act on
	// and one they can only report.
	if message := str(failure["message"]); !strings.Contains(message, coreAction) {
		t.Errorf("the refusal must name the models this host does have; got %q", message)
	}
	if after := len(host.modelCalls()); after != before {
		t.Errorf("nothing may be asked before the refusal; %d call(s) went out", after-before)
	}
	// "Before the run exists" is the claim, so the record is the oracle for it:
	// a refusal that had already written a run would leave a round somebody has
	// to cancel or read.
	if held := runCount(t, store, "ses-unlisted"); held != 0 {
		t.Errorf("the refusal must land before the run record is created; the session holds %d run(s)", held)
	}
}
