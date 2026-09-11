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
	nearLimit := s.Export()
	nearLimit["definitions"] = []any{def}
	padSnapshot(t, nearLimit, 24000)
	nearRaw, _ := json.Marshal(nearLimit)
	if _, err := s.Load(nearRaw); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 12; i++ {
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
	padSnapshot(t, snap, 20000)
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

	// A document that is ALREADY over the hop on arrival is the other half of
	// the same ceiling, and the one a user meets: the file opens, and the only
	// thing they can act on is what the refusal says. So the assertion is the
	// message — the two byte counts and what the document holds — rather than
	// the fact of an error, which on its own would send them to a log.
	con["text"] = strings.Repeat("x", 32768)
	oversized, _ := json.Marshal(snap)
	if len(oversized) <= MaxEnvelopeBytes {
		t.Fatalf("the oversized fixture is only %d bytes, which the hop carries", len(oversized))
	}
	_, err = s.Load(oversized)
	if err == nil {
		t.Fatal("a document larger than the host's IPC hop was accepted")
	}
	for _, expected := range []string{
		fmt.Sprintf("%d bytes", len(oversized)),
		fmt.Sprintf("carries %d", MaxEnvelopeBytes),
		fmt.Sprintf("holds %d council(s)", len(arr(snap["definitions"]))),
		fmt.Sprintf("%d session(s)", len(arr(snap["sessions"]))),
	} {
		if !strings.Contains(err.Error(), expected) {
			t.Errorf("the refusal must say %q so it is actionable; got %q", expected, err.Error())
		}
	}
	if !reflect.DeepEqual(before, s.Export()) {
		t.Fatal("a refused oversized load changed state")
	}
}

// Fill with valid independent definitions, keeping a bounded final field for
// boundary tests. This scales with the production budget instead of 64 KiB.
func padSnapshot(t *testing.T, snap map[string]any, room int) {
	t.Helper()
	defs := arr(snap["definitions"])
	template := obj(defs[0])
	raw, _ := json.Marshal(snap)
	size := len(raw)
	for i := 0; ; i++ {
		if size >= MaxEnvelopeBytes-room {
			return
		}
		extra := deepCopy(template)
		extra["definition_id"] = fmt.Sprintf("padding-%d", i)
		extra["purpose"] = strings.Repeat("x", 4000)
		encoded, _ := json.Marshal(extra)
		size += len(encoded) + 1 // comma in the existing definitions array
		defs = append(defs, extra)
		snap["definitions"] = defs
	}
}
