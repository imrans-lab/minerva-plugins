package readmodel

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// replay serves Docket tool replies recorded in testdata/w1_fixture.json,
// matched on the tool name and the exact arguments the loader sends.
type replay map[string]json.RawMessage

func loadReplay(t *testing.T) replay {
	t.Helper()
	raw, err := os.ReadFile("testdata/w1_fixture.json")
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Calls []struct {
			Tool  string          `json:"tool"`
			Args  map[string]any  `json:"args"`
			Reply json.RawMessage `json:"reply"`
		} `json:"calls"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	r := replay{}
	for _, c := range file.Calls {
		r[replayKey(c.Tool, c.Args)] = c.Reply
	}
	return r
}

func replayKey(tool string, args map[string]any) string {
	return tool + " " + string(mustJSON(args))
}

func (r replay) Call(_ context.Context, tool string, args map[string]any) (json.RawMessage, error) {
	reply, ok := r[replayKey(tool, args)]
	if !ok {
		return nil, fmt.Errorf("no recorded reply for %s", replayKey(tool, args))
	}
	return reply, nil
}

// index a reply's nodes by id, across page roots and nesting.
func byID(nodes []*Node, into map[string]*Node) map[string]*Node {
	for _, n := range nodes {
		into[n.ID] = n
		byID(n.Children, into)
	}
	return into
}

func build(t *testing.T, snap Snapshot, caller Caller, args string) Reply {
	t.Helper()
	q, ignored, err := ParseQuery(json.RawMessage(args))
	if err != nil {
		t.Fatal(err)
	}
	return Build(snap, caller, q, ignored)
}

const (
	objective = "docket:01a0dc037e2d7bce96c9ec889b03a605"
	taskW1T0  = "docket:01a0dc0608f97ffa8104157c604edc0a"
	unowned   = "docket:01a0dc871bfe7f56be7dc75e7ff184e4"
	blocked   = "docket:01a0dc872c3970f0ad4386915b090f5e"
	attempt   = "docket:01a0dc347a6c7fddb58851c17560980c"
	localPrin = "local:1000@da281b72"
	roleImpl  = attempt + "/role:implementer"
	actorImpl = roleImpl + "/actor:" + localPrin

	// A reviewer attempt held by a container principal, added to the recorded
	// set so a restricted view has something of its own to see.
	containerPrin    = "container:fixture-grant"
	containerAttempt = "docket:fixture-container-review"
)

// TestReadModelOverW1Fixture walks the W1 example set (KB docket:01a0dc3549bc
// section 7 plus the W1 T4 broken siblings) through the loader and the tree,
// then checks the restricted view, the unknown flag and the bounds.
func TestReadModelOverW1Fixture(t *testing.T) {
	records, err := Load(context.Background(), loadReplay(t), []string{"docket"})
	if err != nil {
		t.Fatal(err)
	}
	observed := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	snap := Snapshot{
		Records: append(records, Record{
			Project: "docket", ID: "fixture-container-review", Title: "ATTEMPT — reviewer",
			Status: "in_progress", Tags: []string{"wr:attempt", "role:reviewer"},
			Parent: unowned, AssignedTo: containerPrin,
		}),
		Sessions: []SessionEvidence{
			{Principal: containerPrin, Identity: "reviewer-1", Role: "reviewer", Liveness: "live", ObservedAt: observed},
		},
	}

	// --- Owner view: hand-walk of the fixture records. ---
	full := build(t, snap, Caller{Principal: "human:da281b72"}, `{}`)
	if full.Truncated || full.Scope != "full" {
		t.Fatalf("owner view: truncated=%v scope=%s", full.Truncated, full.Scope)
	}
	nodes := byID(full.Tree, map[string]*Node{})

	// --- Verb parity: a host-path minerva_orchview_tree call gets the page the panel builds. ---
	if verb, err := NewHistory().Tree(snap, json.RawMessage(`{}`)); err != nil ||
		string(mustJSON(verb.Reply)) != string(mustJSON(build(t, snap, Owner, `{}`))) {
		t.Errorf("minerva_orchview_tree and the panel differ over the fixture (err=%v)", err)
	}

	// Hand-walk. remaining = DONE WHEN bullets of tasks without outcome:accepted
	// (W1 KB section 3). W1 T0 is done but carries no outcome: tag, so its four
	// bullets remain; each fixture sibling has one bullet. The objective sums
	// its tasks: 4 + 1 + 1 = 6.
	walk := []struct {
		id                          string
		kind                        Kind
		parent                      string
		assignedTo                  string
		blocked, unowned, noOutcome bool
		remaining                   int
	}{
		{objective, KindObjective, "", "", false, false, false, 6},
		{taskW1T0, KindTask, objective, localPrin, false, false, true, 4},
		{unowned, KindTask, objective, "", false, true, false, 1},
		{blocked, KindTask, objective, localPrin, true, false, false, 1},
		{attempt, KindAttempt, taskW1T0, localPrin, false, false, false, 0},
		{containerAttempt, KindAttempt, unowned, containerPrin, false, false, false, 0},
	}
	for _, w := range walk {
		n := nodes[w.id]
		if n == nil {
			t.Fatalf("hand-walk: %s missing from the owner view", w.id)
		}
		if n.Kind != w.kind || n.Owner.AssignedTo != w.assignedTo || n.Blocked != w.blocked ||
			n.Unowned != w.unowned || n.OutcomeUnrecorded != w.noOutcome || n.RemainingTotal != w.remaining {
			t.Errorf("hand-walk %s: got kind=%s assigned=%q blocked=%v unowned=%v outcome_unrecorded=%v remaining=%d",
				w.id, n.Kind, n.Owner.AssignedTo, n.Blocked, n.Unowned, n.OutcomeUnrecorded, n.RemainingTotal)
		}
		if w.parent != "" && !hasChild(nodes[w.parent], w.id) {
			t.Errorf("hand-walk: %s is not under %s", w.id, w.parent)
		}
	}
	if got := nodes[blocked].Links; got == nil || got.BlockedBy != unowned {
		t.Errorf("blocked task should link blocked_by %s, got %+v", unowned, got)
	}
	if got := nodes[attempt].Stage; got.Status != "done" || got.Result != "completed" {
		t.Errorf("attempt stage: %+v", got)
	}
	if got := nodes[taskW1T0].Stage; got.Review != "requested" || got.Test != "not-run" || len(got.Deferred) != 1 {
		t.Errorf("task facts: %+v", got)
	}
	if got := nodes[taskW1T0].Remaining[0].Text; !strings.HasPrefix(got, "The KB article exists") {
		t.Errorf("first remaining criterion of W1 T0: %q", got)
	}
	if nodes[roleImpl] == nil || nodes[roleImpl].Title != "implementer" || !hasChild(nodes[roleImpl], actorImpl) {
		t.Errorf("attempt should carry role implementer → actor %s", localPrin)
	}

	// --- Unknown: an actor with no session evidence, and one whose host sent
	// a state the registry never defines. Neither may read as idle. ---
	if a := nodes[actorImpl].Activity; !a.Unknown || a.Liveness != "" || a.ObservedAt != "" {
		t.Errorf("actor without evidence must be unknown: %+v", a)
	}
	if a := nodes[taskW1T0].Activity; !a.Unknown {
		t.Errorf("task whose only actor is unknown must roll up unknown: %+v", a)
	}
	if a := nodes[containerAttempt+"/role:reviewer/actor:"+containerPrin].Activity; a.Unknown || a.Liveness != "live" {
		t.Errorf("container actor with a live session: %+v", a)
	}
	idle := snap
	idle.Sessions = append([]SessionEvidence{{Principal: localPrin, Identity: "x", Liveness: "idle", ObservedAt: observed}}, snap.Sessions...)
	withIdle := build(t, idle, Caller{Principal: "human:da281b72"}, `{}`)
	if a := byID(withIdle.Tree, map[string]*Node{})[actorImpl].Activity; !a.Unknown || a.Liveness != "" {
		t.Errorf("an undefined liveness must be unknown: %+v", a)
	}
	if strings.Contains(string(mustJSON(withIdle)), "idle") {
		t.Error("the reply must never carry an idle state")
	}

	// --- Restricted container view, with forged authority in the arguments. ---
	forged := fmt.Sprintf(`{"dispatch_id":%q,"caller":%q,"principal":"human:da281b72"}`, attempt, localPrin)
	scoped := build(t, snap, Caller{Principal: containerPrin, Restricted: true}, forged)
	plain := build(t, snap, Caller{Principal: containerPrin, Restricted: true}, `{}`)
	seen := byID(scoped.Tree, map[string]*Node{})
	for _, id := range []string{taskW1T0, blocked, attempt, actorImpl} {
		if seen[id] != nil {
			t.Errorf("container view leaked %s", id)
		}
	}
	if !seen[objective].Partial || !seen[unowned].Partial || seen[containerAttempt] == nil || seen[containerAttempt].Partial {
		t.Error("container view: objective and task should be partial ancestors of its own attempt")
	}
	if seen[objective].RemainingTotal != 1 {
		t.Errorf("container view counts only criteria it may see: %d", seen[objective].RemainingTotal)
	}
	if links := seen[unowned].Links; links != nil && len(links.Blocks) > 0 {
		t.Errorf("container view must not link to the hidden blocked task: %+v", links)
	}
	if scoped.Caller != containerPrin || strings.Join(scoped.IgnoredArguments, ",") != "caller,dispatch_id,principal" {
		t.Errorf("forged arguments must be ignored: caller=%s ignored=%v", scoped.Caller, scoped.IgnoredArguments)
	}
	scoped.IgnoredArguments = nil
	if string(mustJSON(scoped)) != string(mustJSON(plain)) {
		t.Error("a forged dispatch id changed the restricted view")
	}

	// --- Revision cursor: an unchanged read is cheap; a revision bump is seen. ---
	if again := build(t, snap, Caller{Principal: "human:da281b72"}, fmt.Sprintf(`{"since":%q}`, full.Cursor)); !again.Unchanged {
		t.Error("since=current cursor should report unchanged")
	}
	bumped := snap
	bumped.Records = append([]Record(nil), snap.Records...)
	for i := range bumped.Records {
		if bumped.Records[i].Key() == unowned {
			rev := *bumped.Records[i].Revision + 1
			bumped.Records[i].Revision = &rev
		}
	}
	if next := build(t, bumped, Caller{Principal: "human:da281b72"}, fmt.Sprintf(`{"since":%q}`, full.Cursor)); next.Unchanged || next.Cursor == full.Cursor {
		t.Error("a revision bump must change the cursor")
	}

	// --- Bounds: max_nodes pages the fixture; pages join to the whole tree. ---
	page1 := build(t, snap, Caller{Principal: "human:da281b72"}, `{"max_nodes":3}`)
	if !page1.Truncated || page1.NodesReturned != 3 || page1.Continuation == "" {
		t.Fatalf("max_nodes=3: truncated=%v returned=%d", page1.Truncated, page1.NodesReturned)
	}
	collected := byID(page1.Tree, map[string]*Node{})
	for token := page1.Continuation; token != ""; {
		page := build(t, snap, Caller{Principal: "human:da281b72"}, fmt.Sprintf(`{"max_nodes":3,"continuation":%q}`, token))
		for id := range byID(page.Tree, map[string]*Node{}) {
			if collected[id] != nil {
				t.Errorf("node %s returned on two pages", id)
			}
		}
		byID(page.Tree, collected)
		token = page.Continuation
	}
	if len(collected) != full.NodesTotal || len(nodes) != full.NodesTotal {
		t.Errorf("pages joined to %d nodes, full view has %d", len(collected), full.NodesTotal)
	}

	// --- Oversized: far more than 64 KiB of tree in one request. ---
	big := snap
	big.Records = append([]Record(nil), snap.Records...)
	bullet := "- " + strings.Repeat("criterion text ", 25) + "\n"
	for i := 0; i < 400; i++ {
		big.Records = append(big.Records, Record{
			Project: "docket", ID: fmt.Sprintf("bulk-%04d", i), Title: strings.Repeat("t", 200),
			Status: "open", Tags: []string{"wr:task"}, Parent: objective,
			Description: "GOAL\nx\n\nDONE WHEN\n" + strings.Repeat(bullet, 20),
		})
	}
	huge := build(t, big, Caller{Principal: "human:da281b72"}, `{"max_nodes":2000}`)
	if size := len(mustJSON(huge)); size > ReplyCap {
		t.Errorf("oversized request produced %d bytes, cap %d", size, ReplyCap)
	}
	if !huge.Truncated || huge.Continuation == "" || huge.NodesReturned >= huge.NodesTotal {
		t.Errorf("oversized request must truncate with a continuation: returned=%d total=%d", huge.NodesReturned, huge.NodesTotal)
	}
	rest := build(t, big, Caller{Principal: "human:da281b72"}, fmt.Sprintf(`{"max_nodes":2000,"continuation":%q}`, huge.Continuation))
	if rest.ContinuationReset || rest.NodesReturned == 0 || len(mustJSON(rest)) > ReplyCap {
		t.Errorf("continuation page: reset=%v returned=%d", rest.ContinuationReset, rest.NodesReturned)
	}
}

func hasChild(parent *Node, id string) bool {
	if parent == nil {
		return false
	}
	for _, c := range parent.Children {
		if c.ID == id {
			return true
		}
	}
	return false
}
