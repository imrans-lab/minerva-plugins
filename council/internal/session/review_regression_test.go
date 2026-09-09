package session

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/ipeerbhai/plugins/council/fixtures"
)

type reviewHost struct{ answer func(ModelCall) ModelReply }

func (h reviewHost) Generate(_ context.Context, call ModelCall) (ModelReply, error) {
	return h.answer(call), nil
}

func reviewStore(t *testing.T) *Store {
	t.Helper()
	s, err := New()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := fixtures.FS.ReadFile("workshop_complete.mcouncil")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(raw); err != nil {
		t.Fatal(err)
	}
	return s
}
func prepareReviewRun(t *testing.T, s *Store, extra map[string]any) (Reply, command, *Request) {
	t.Helper()
	payload := map[string]any{"session_id": "ses-recurring-order"}
	for k, v := range extra {
		payload[k] = v
	}
	raw, _ := json.Marshal(map[string]any{"schema_version": 1, "envelope": "request", "request_id": "review-run", "command": "run.start", "base_revision": s.Revision(), "wait_seconds": 1, "payload": payload})
	reply, cmd, req, err := s.dispatchLocked(raw)
	if err != nil || !reply.OK {
		t.Fatalf("prepare run: %+v %v", reply, err)
	}
	return reply, cmd, req
}
func TestRejectedAsyncResultsReachReloadableRest(t *testing.T) {
	for _, kind := range []string{"members", "chair", "invalid-model"} {
		t.Run(kind, func(t *testing.T) {
			s := reviewStore(t)
			s.SetChatHost(reviewHost{answer: func(call ModelCall) ModelReply {
				if kind == "invalid-model" {
					return ModelReply{ModelID: strings.Repeat("m", 121), Text: "Answer"}
				}
				if kind == "members" {
					return ModelReply{Text: strings.Repeat("x", 32768)}
				}
				if call.Role == "chair" {
					raw, _ := json.Marshal(map[string]any{"answer": strings.Repeat("x", 32768), "claims": []any{map[string]any{"text": strings.Repeat("a", 8000), "support": "inference"}, map[string]any{"text": strings.Repeat("b", 8000), "support": "inference"}, map[string]any{"text": strings.Repeat("c", 8000), "support": "inference"}}})
					return ModelReply{Text: string(raw)}
				}
				return ModelReply{Text: "Accepted member answer"}
			}})
			reply, cmd, req := prepareReviewRun(t, s, nil)
			outcome := cmd.after(s, req, reply.Payload)
			if !outcome.OK {
				t.Fatalf("outcome: %+v", outcome)
			}
			if status := str(outcome.Payload["status"]); status == "running" || status == "pending" {
				t.Fatalf("executor finished but record is %s", status)
			}
			raw, _ := json.Marshal(s.Export())
			reopened, _ := New()
			if _, err := reopened.Load(raw); err != nil {
				t.Fatalf("cannot reopen: %v", err)
			}
			if kind == "chair" && !strings.Contains(string(raw), "Accepted member answer") {
				t.Fatal("lost accepted contributions")
			}
			if obj(outcome.Payload["failure"]) == nil {
				t.Fatal("rejected result has no visible failure")
			}
		})
	}
}
func TestDeferredRunDoesNotCrossLoadGeneration(t *testing.T) {
	s := reviewStore(t)
	reply, cmd, req := prepareReviewRun(t, s, nil)
	raw, _ := json.Marshal(s.Export()) // Same session/run/request IDs in replacement.
	if _, err := s.Load(raw); err != nil {
		t.Fatal(err)
	}
	before, _ := json.Marshal(s.Export())
	outcome := cmd.after(s, req, reply.Payload)
	if outcome.OK || outcome.Error.Code != CodeStaleRevision {
		t.Fatalf("old request accepted after load: %+v", outcome)
	}
	after, _ := json.Marshal(s.Export())
	if string(before) != string(after) {
		t.Fatal("old request modified replacement")
	}
	if _, ok := s.ledger[req.RequestID]; ok {
		t.Fatal("old request contaminated replacement ledger")
	}
}
func TestPromptBudgetAndDeliveredCitations(t *testing.T) {
	retained := section{label: "retained", body: "quote", anchors: map[string]bool{"a": true}}
	omitted := section{label: "omitted", body: strings.Repeat("x", 2000), droppable: true, anchors: map[string]bool{"b": true}}
	text, allowed := assemble([]section{retained, omitted}, 500)
	if len(text) > 500 || text == "" || !allowed["a"] || allowed["b"] {
		t.Fatalf("delivered citation set: %d %+v", len(text), allowed)
	}
	s := reviewStore(t)
	s.SetChatHost(reviewHost{answer: func(ModelCall) ModelReply { t.Error("over-budget call reached model"); return ModelReply{} }})
	user, _ := assemble([]section{{body: strings.Repeat("x", 2000)}}, 500)
	if _, err := s.generate(context.Background(), ModelCall{System: "identity", User: user}, 500); err == nil {
		t.Fatal("oversized required sections accepted")
	}
	if _, err := s.generate(context.Background(), ModelCall{System: strings.Repeat("s", 400), User: strings.Repeat("u", 400)}, 500); err == nil {
		t.Fatal("system prompt excluded from budget")
	}
	snapshot := s.Export()
	ses := obj(arr(snapshot["sessions"])[0])
	run := obj(arr(ses["runs"])[1])
	text, allowed = chairPrompt(ses, run, nil, 32768)
	if text == "" || len(allowed) == 0 {
		t.Fatal("fixture chair lost all supplied citations")
	}
	// Add an unconsulted source: its anchors must not become chair evidence.
	def := obj(ses["definition_snapshot"])
	def["sources"] = append(arr(def["sources"]), map[string]any{"source_id": "unseen", "source_revision": float64(1), "anchors": []any{map[string]any{"anchor_id": "secret"}}})
	_, allowed = chairPrompt(ses, run, nil, 32768)
	if allowed[citationKey("unseen", 1, "secret")] {
		t.Fatal("chair allowed unseen source")
	}
	// With a tiny budget, no retained member material means no citations.
	_, allowed = chairPrompt(ses, run, nil, 1024)
	if len(allowed) != 0 {
		t.Fatal("omitted chair evidence remained citable")
	}
}

func TestHumanChairRefusesAutomatedRound(t *testing.T) {
	s := reviewStore(t)
	snapshot := s.Export()
	ses := obj(arr(snapshot["sessions"])[0])
	def := obj(ses["definition_snapshot"])
	seat := chairSeatOf(def)
	chair, _ := findByID(def["members"], "member_id", str(seat["member_id"]))
	chair["kind"] = "human"
	chair["grounding"] = []any{}
	delete(chair, "model_hint")
	delete(chair, "represents")
	// Start with no old model-authored contributions for this human identity.
	ses["runs"] = []any{}
	ses["outcomes"] = []any{}
	ses["status"] = "draft"
	raw, _ := json.Marshal(snapshot)
	if _, err := s.Load(raw); err != nil {
		t.Fatal(err)
	}
	s.SetChatHost(reviewHost{answer: func(ModelCall) ModelReply {
		t.Error("model consulted for human-chaired round")
		return ModelReply{Text: "answer"}
	}})
	raw, _ = json.Marshal(map[string]any{"schema_version": 1, "envelope": "request", "request_id": "human-chair", "command": "run.start", "base_revision": s.Revision(), "payload": map[string]any{"session_id": str(ses["session_id"])}})
	reply, err := s.Dispatch(raw)
	if err != nil || reply.OK || !strings.Contains(reply.Error.Message, "human chair") {
		t.Fatalf("human chair not refused: %+v %v", reply, err)
	}
}
