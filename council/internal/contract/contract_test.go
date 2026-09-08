package contract

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/ipeerbhai/plugins/council/fixtures"
)

// hostIPCRequestCap is the host's pluginIPC payload limit
// (PluginWebviewBroker.gd / PluginScenePanelBroker.gd, 65536). Any envelope
// Council sends in one message has to fit under it.
const hostIPCRequestCap = 65536

func registry(t *testing.T) *Registry {
	t.Helper()
	r, err := LoadRegistry()
	if err != nil {
		t.Fatalf("load schemas: %v", err)
	}
	return r
}

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := fixtures.FS.ReadFile(name)
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return raw
}

// TestValidFixturesRoundTrip is the acceptance test for the record contract:
// every shipped example validates against its schema AND its invariants, and
// survives a decode/encode/decode cycle unchanged. The oracle is the schema
// set plus deep equality of the decoded forms — no golden strings, so
// reformatting a fixture cannot fail the test and a dropped field cannot pass
// it.
func TestValidFixturesRoundTrip(t *testing.T) {
	r := registry(t)
	entries, err := fixtures.FS.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		name := e.Name()
		t.Run(name, func(t *testing.T) {
			raw := readFixture(t, name)
			var first any
			if err := json.Unmarshal(raw, &first); err != nil {
				t.Fatalf("decode: %v", err)
			}
			kind, err := KindOf(first)
			if err != nil {
				t.Fatalf("classify: %v", err)
			}
			if errs := r.ValidateRecord(kind, raw); len(errs) > 0 {
				t.Fatalf("expected a valid %s, got:\n  %s", kind, strings.Join(errs, "\n  "))
			}

			reencoded, err := json.Marshal(first)
			if err != nil {
				t.Fatalf("re-encode: %v", err)
			}
			var second any
			if err := json.Unmarshal(reencoded, &second); err != nil {
				t.Fatalf("re-decode: %v", err)
			}
			if !reflect.DeepEqual(first, second) {
				t.Fatalf("round trip changed the record")
			}
			if errs := r.ValidateRecord(kind, reencoded); len(errs) > 0 {
				t.Fatalf("round-tripped record no longer validates:\n  %s", strings.Join(errs, "\n  "))
			}
		})
		seen++
	}
	if seen == 0 {
		t.Fatal("no fixtures found; the embed pattern is wrong")
	}
}

// TestInvalidFixturesAreRejected checks that each way of getting a Council
// record wrong is actually caught, and caught for the stated reason. The
// oracle is fixtures/invalid/cases.json, which names the expected complaint
// for each broken record.
func TestInvalidFixturesAreRejected(t *testing.T) {
	r := registry(t)
	var cases []struct {
		File   string `json:"file"`
		Record string `json:"record"`
		Expect string `json:"expect"`
	}
	if err := json.Unmarshal(readFixture(t, "invalid/cases.json"), &cases); err != nil {
		t.Fatalf("decode case index: %v", err)
	}
	if len(cases) == 0 {
		t.Fatal("the invalid-case index is empty")
	}
	for _, c := range cases {
		t.Run(c.File, func(t *testing.T) {
			errs := r.ValidateRecord(c.Record, readFixture(t, "invalid/"+c.File))
			if len(errs) == 0 {
				t.Fatalf("expected rejection mentioning %q, but the record validated", c.Expect)
			}
			if !strings.Contains(strings.ToLower(strings.Join(errs, "\n")), strings.ToLower(c.Expect)) {
				t.Fatalf("expected a complaint mentioning %q, got:\n  %s", c.Expect, strings.Join(errs, "\n  "))
			}
		})
	}
}

// TestDefinitionExportCarriesNoSessionData is the leak test for the reuse
// requirement: exporting a council for use in another project must not carry
// the first project's question, transcript, notes, or chat. The oracle is the
// definition schema's closed object set plus a sweep for every field name that
// only exists on session-side records.
func TestDefinitionExportCarriesNoSessionData(t *testing.T) {
	r := registry(t)
	var snapshot map[string]any
	if err := json.Unmarshal(readFixture(t, "project_snapshot.json"), &snapshot); err != nil {
		t.Fatal(err)
	}
	sessions := arr(snapshot["sessions"])
	if len(sessions) == 0 {
		t.Fatal("the snapshot fixture has no session to export from")
	}
	// An export takes the definition, never the session that used it, and
	// strips this project's artifact identities on the way out.
	def := obj(obj(sessions[0])["definition_snapshot"])
	portable, err := ExportDefinition(def, true)
	if err != nil {
		t.Fatal(err)
	}
	exported, err := json.Marshal(portable)
	if err != nil {
		t.Fatal(err)
	}
	if errs := r.ValidateRecord("council_definition", exported); len(errs) > 0 {
		t.Fatalf("the exported definition does not validate:\n  %s", strings.Join(errs, "\n  "))
	}
	forbidden := []string{
		"question", "chat_binding", "chat_id", "origin_message_id",
		"runs", "run_id", "contribution_id", "synthesis", "outcomes",
		"artifact", "context_snapshot", "session_id",
	}
	text := string(exported)
	for _, f := range forbidden {
		if strings.Contains(text, "\""+f+"\":") {
			t.Errorf("exported definition carries session-side field %q", f)
		}
	}
	// The source inventory must survive, or an import cannot report what is
	// missing. The in-project definition it came from keeps its note link.
	if len(arr(portable["sources"])) == 0 {
		t.Error("exported definition dropped the source inventory")
	}
	if obj(arr(def["sources"])[0])["artifact"] == nil {
		t.Error("exporting must not mutate the in-project definition")
	}
	// Dropping the content still leaves the inventory behind.
	lean, err := ExportDefinition(def, false)
	if err != nil {
		t.Fatal(err)
	}
	leanSource := obj(arr(lean["sources"])[0])
	if leanSource["payload"] != nil {
		t.Error("a content-free export still carries the captured payload")
	}
	if leanSource["title"] == nil || len(arr(leanSource["anchors"])) == 0 {
		t.Error("a content-free export must still name the source and its anchors")
	}
	leanRaw, err := json.Marshal(lean)
	if err != nil {
		t.Fatal(err)
	}
	if errs := r.ValidateRecord("council_definition", leanRaw); len(errs) > 0 {
		t.Fatalf("a content-free export does not validate:\n  %s", strings.Join(errs, "\n  "))
	}
}

// TestInterruptedRunsAreNotResumed pins the money-losing rule: a snapshot
// restored with a run still marked running comes back as a visible failure
// with a retry, never as work in progress. The oracle is the post-condition —
// no run or contribution is left in a live state, and the record still
// validates.
func TestInterruptedRunsAreNotResumed(t *testing.T) {
	r := registry(t)
	var snapshot map[string]any
	if err := json.Unmarshal(readFixture(t, "project_snapshot.json"), &snapshot); err != nil {
		t.Fatal(err)
	}
	// Put the fixture back into the state a crash would leave behind.
	session := obj(arr(snapshot["sessions"])[0])
	session["status"] = "running"
	run := obj(arr(session["runs"])[0])
	run["status"] = "running"
	delete(run, "ended_at")
	delete(run, "failure")
	for _, c := range arr(run["contributions"]) {
		contribution := obj(c)
		contribution["status"] = "running"
		delete(contribution, "failure")
	}

	if n := RehydrateOnLoad(snapshot); n != 1 {
		t.Fatalf("expected 1 interrupted run to be demoted, got %d", n)
	}
	if got := str(run["status"]); got != "failed" {
		t.Errorf("run status = %q, want failed", got)
	}
	if got := str(session["status"]); got != "partial" {
		t.Errorf("session status = %q, want partial", got)
	}
	for i, c := range arr(run["contributions"]) {
		if s := str(obj(c)["status"]); s == "pending" || s == "running" {
			t.Errorf("contribution %d left live in state %q", i, s)
		}
	}
	if !obj(run["failure"])["retryable"].(bool) {
		t.Error("an interrupted run must be retryable")
	}

	reencoded, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if errs := r.ValidateRecord("council_project_snapshot", reencoded); len(errs) > 0 {
		t.Fatalf("rehydrated snapshot no longer validates:\n  %s", strings.Join(errs, "\n  "))
	}

	// Rehydrating twice changes nothing: load is idempotent.
	if n := RehydrateOnLoad(snapshot); n != 0 {
		t.Errorf("second rehydrate demoted %d runs; load must be idempotent", n)
	}

	// A session can be left saying "running" with every run already terminal.
	// The status describes the session, so it is demoted even though there is
	// nothing to demote it for.
	session["status"] = "running"
	if n := RehydrateOnLoad(snapshot); n != 0 {
		t.Errorf("expected no demotable runs, got %d", n)
	}
	if got := str(session["status"]); got != "partial" {
		t.Errorf("session with no live runs left in state %q, want partial", got)
	}
}

// TestInlineLimitIsDerivedFromTheHostIPCCap pins the transport assumption the
// protocol rests on. InlineLimit is deliberately half the host's pluginIPC
// request cap, so a payload plus the envelope around it fits even when the host
// counts the cap in UTF-16 code units rather than bytes. Changing either number
// without re-deriving the other is the failure this catches.
func TestInlineLimitIsDerivedFromTheHostIPCCap(t *testing.T) {
	if InlineLimit*2 != hostIPCRequestCap {
		t.Fatalf("InlineLimit %d is no longer half the host cap %d; re-derive it", InlineLimit, hostIPCRequestCap)
	}
}
