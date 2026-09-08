package session

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/ipeerbhai/plugins/council/fixtures"
)

func TestAcknowledgedSnapshotsRemainReloadable(t *testing.T) {
	s, err := New()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := fixtures.FS.ReadFile("definition_workshop.json")
	if err != nil {
		t.Fatal(err)
	}
	var def map[string]any
	if err := json.Unmarshal(raw, &def); err != nil {
		t.Fatal(err)
	}
	def["purpose"] = strings.Repeat("x", 4000)
	for i := 0; i < 20; i++ {
		def["definition_id"] = fmt.Sprintf("budget-%d", i)
		before := s.Export()
		req, _ := json.Marshal(map[string]any{"schema_version": 1, "envelope": "request", "request_id": fmt.Sprintf("import-%d", i), "command": "definition.import", "base_revision": s.Revision(), "payload": map[string]any{"definition": def}})
		reply, err := s.Dispatch(req)
		if err != nil {
			t.Fatal(err)
		}
		if !reply.OK {
			if reply.Error.Code != CodePayloadTooLarge {
				t.Fatalf("unexpected refusal: %+v", reply.Error)
			}
			if !reflect.DeepEqual(before, s.Export()) {
				t.Fatal("rejected growth changed acknowledged state")
			}
			if i == 0 {
				t.Fatal("small snapshot was refused")
			}
			return
		}
		exported, _ := json.Marshal(s.Export())
		reopened, _ := New()
		if _, err := reopened.Load(exported); err != nil {
			t.Fatalf("acknowledged snapshot cannot reload: %v", err)
		}
	}
	t.Fatal("unbounded snapshot growth was accepted")
}

func TestLoadReservesInterruptedSnapshotGrowth(t *testing.T) {
	raw, err := fixtures.FS.ReadFile("project_snapshot.json")
	if err != nil {
		t.Fatal(err)
	}
	var snap map[string]any
	if err := json.Unmarshal(raw, &snap); err != nil {
		t.Fatal(err)
	}
	ses := obj(arr(snap["sessions"])[0])
	run := obj(arr(ses["runs"])[1])
	run["status"] = "pending"
	delete(run, "failure")
	con := obj(arr(run["contributions"])[0])
	con["status"] = "pending"
	delete(con, "failure")
	ses["status"] = "running"
	obj(arr(obj(arr(ses["runs"])[0])["contributions"])[0])["text"] = strings.Repeat("x", 32768)
	con["text"] = ""
	base, _ := json.Marshal(snap)
	padding := MaxEnvelopeBytes - len(base) - 8
	if padding < 0 || padding > 32768 {
		t.Fatalf("invalid near-limit fixture padding %d", padding)
	}
	con["text"] = strings.Repeat("x", padding)
	raw, _ = json.Marshal(snap)
	s, _ := New()
	if errs := s.registry.ValidateRecord("council_project_snapshot", raw); len(errs) > 0 {
		t.Fatalf("invalid fixture: %v", errs)
	}
	before := s.Export()
	if _, err := s.Load(raw); err == nil {
		t.Fatal("accepted snapshot that interruption expands past reload budget")
	}
	if !reflect.DeepEqual(before, s.Export()) {
		t.Fatal("refused load changed state")
	}
}
