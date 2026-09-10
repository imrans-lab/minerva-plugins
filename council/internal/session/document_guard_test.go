package session

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestExpectedDocumentGuardsReadsWritesAndReplays(t *testing.T) {
	s := reviewStore(t)
	original := s.Export()
	expected := str(original["project_id"])
	command := map[string]any{"schema_version": 1, "envelope": "request", "request_id": "guarded-bind", "command": "session.bind_chat", "base_revision": s.Revision(), "expected_project_id": expected, "payload": map[string]any{"session_id": "ses-recurring-order", "chat_id": "chat-guarded"}}
	raw, _ := json.Marshal(command)
	reply, err := s.Dispatch(raw)
	if err != nil || !reply.OK {
		t.Fatalf("own document refused: %+v %v", reply, err)
	}
	command["expected_project_id"] = "prj-foreign"
	raw, _ = json.Marshal(command)
	reply, err = s.Dispatch(raw)
	if err != nil || reply.OK || reply.Replayed {
		t.Fatalf("wrong document reached ledger: %+v %v", reply, err)
	}
	// Equal IDs and revision cannot make a different project a valid destination.
	original["project_id"] = "prj-replacement"
	raw, _ = json.Marshal(original)
	if _, err = s.Load(raw); err != nil {
		t.Fatal(err)
	}
	before := s.Export()
	command["expected_project_id"] = expected
	raw, _ = json.Marshal(command)
	reply, err = s.Dispatch(raw)
	if err != nil || reply.OK || reply.Error.Code != CodeStaleRevision {
		t.Fatalf("foreign write accepted: %+v %v", reply, err)
	}
	if !reflect.DeepEqual(before, s.Export()) {
		t.Fatal("foreign record mutated")
	}
	delete(command, "base_revision")
	command["command"] = "snapshot.get"
	raw, _ = json.Marshal(command)
	reply, err = s.Dispatch(raw)
	if err != nil || reply.OK || reply.Payload != nil {
		t.Fatalf("foreign snapshot disclosed: %+v %v", reply, err)
	}
}
