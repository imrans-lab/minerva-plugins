package contract

import (
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/ipeerbhai/plugins/council/fixtures"
	"github.com/ipeerbhai/plugins/council/schemas"
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
		// .mcouncil is the extension Minerva opens a Council document under; the
		// record inside it is a council_project_snapshot like any other, and it
		// is held to the same contract here.
		if e.IsDir() || !(strings.HasSuffix(e.Name(), ".json") || strings.HasSuffix(e.Name(), ".mcouncil")) {
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

// propertyNames collects every property name a schema document declares, at
// any depth. It is how the leak test gets its oracle from the schemas instead
// of from a hand-written list that would go stale the first time a session
// grows a field.
func propertyNames(doc map[string]any, into map[string]bool) {
	for key, value := range doc {
		if key == "properties" {
			for name, sub := range obj(value) {
				into[name] = true
				propertyNames(obj(sub), into)
			}
			continue
		}
		switch v := value.(type) {
		case map[string]any:
			propertyNames(v, into)
		case []any:
			for _, item := range v {
				propertyNames(obj(item), into)
			}
		}
	}
}

// recordKeys collects every object key in a decoded record, at any depth. The
// leak sweep asks which fields an export actually has, so it reads keys and
// never the values they hold.
func recordKeys(value any, into map[string]bool) {
	switch v := value.(type) {
	case map[string]any:
		for key, sub := range v {
			into[key] = true
			recordKeys(sub, into)
		}
	case []any:
		for _, item := range v {
			recordKeys(item, into)
		}
	}
}

// TestDefinitionExportCarriesNoSessionData is the leak test for the reuse
// requirement: exporting a council for use in another project must not carry
// the first project's question, transcript, notes, outcomes or chat, and must
// not carry material the user did not choose to include.
//
// The oracle is the schemas themselves. Every property name declared by
// session.schema.json or project_snapshot.schema.json and NOT declared by
// council_definition.schema.json or common.schema.json is a session-side or
// project-side key, and none of them may appear in the export. Adding a field
// to a session therefore extends this test on its own.
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
	portable, included, withheld, err := ExportDefinition(def, true, nil)
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
	if len(included) != 1 || len(withheld) != 0 {
		t.Errorf("a full export must report every source as included, got included=%v withheld=%v", included, withheld)
	}

	sessionSide := map[string]bool{}
	propertyNames(r.docs[schemas.Session], sessionSide)
	propertyNames(r.docs[schemas.ProjectSnapshot], sessionSide)
	portableSide := map[string]bool{}
	propertyNames(r.docs[schemas.CouncilDefinition], portableSide)
	propertyNames(r.docs[schemas.Common], portableSide)

	forbidden := []string{}
	for name := range sessionSide {
		if !portableSide[name] {
			forbidden = append(forbidden, name)
		}
	}
	sort.Strings(forbidden)
	if len(forbidden) < 10 {
		t.Fatalf("the schema sweep found only %d session-side keys (%v); the oracle is not reading the schemas", len(forbidden), forbidden)
	}
	// artifact IS a definition property, so the sweep cannot catch it: a note
	// id is portable-looking and still meaningless in another project.
	forbidden = append(forbidden, "artifact")
	// The sweep is over the decoded keys, not over the bytes: a captured source
	// may itself be text about JSON, and a substring search would read the
	// user's material as structure.
	present := map[string]bool{}
	recordKeys(portable, present)
	for _, f := range forbidden {
		if present[f] {
			t.Errorf("exported definition carries the project-side field %q", f)
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

	// Dropping the content still leaves the inventory behind — including the
	// hash, which is what lets the receiving project recognise the material if
	// it is supplied later.
	lean, _, leanWithheld, err := ExportDefinition(def, false, nil)
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
	if str(leanSource["content_hash"]) == "" {
		t.Error("a content-free export must still say which material it stood for")
	}
	if len(leanWithheld) != 1 {
		t.Errorf("a content-free export must report the source as withheld, got %v", leanWithheld)
	}
	leanRaw, err := json.Marshal(lean)
	if err != nil {
		t.Fatal(err)
	}
	if errs := r.ValidateRecord("council_definition", leanRaw); len(errs) > 0 {
		t.Fatalf("a content-free export does not validate:\n  %s", strings.Join(errs, "\n  "))
	}

	// Selection is per source. An empty (but present) selection is the
	// inventory-only export; an unknown id is refused rather than silently
	// shipping an export the user believes is grounded.
	firstSource := str(obj(arr(def["sources"])[0])["source_id"])
	none, noneIncluded, _, err := ExportDefinition(def, true, []string{})
	if err != nil {
		t.Fatal(err)
	}
	if len(noneIncluded) != 0 || obj(arr(none["sources"])[0])["payload"] != nil {
		t.Error("an empty selection must carry no source content")
	}
	if _, _, _, err := ExportDefinition(def, true, []string{"src-not-here"}); err == nil {
		t.Error("a selection naming a source this council does not hold must be refused")
	}
	// Naming sources to include while excluding all content is a contradiction,
	// and answering it by silently withholding the named material is how an
	// export the user believes is grounded gets shipped.
	if _, _, _, err := ExportDefinition(def, false, []string{firstSource}); err == nil {
		t.Error("naming sources to include with include_content false must be refused")
	}
	picked, pickedIncluded, _, err := ExportDefinition(def, true, []string{firstSource})
	if err != nil {
		t.Fatal(err)
	}
	if len(pickedIncluded) != 1 || obj(arr(picked["sources"])[0])["payload"] == nil {
		t.Errorf("a selected source must carry its content, got included=%v", pickedIncluded)
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
	// The session status is derived from the run set: a resting session reports
	// the outcome of its last run. run-2 failed after collecting contributions,
	// so demoting the older run-1 leaves the session reading "partial". run-1
	// itself still reports the interruption.
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
	// The status is re-derived from the runs, so it is corrected even though
	// there is nothing to demote it for.
	session["status"] = "running"
	if n := RehydrateOnLoad(snapshot); n != 0 {
		t.Errorf("expected no demotable runs, got %d", n)
	}
	if got := str(session["status"]); got != "partial" {
		t.Errorf("session with no live runs left in state %q, want partial", got)
	}
}

// TestInlineLimitIsDerivedFromTheHostIPCCap pins the transport assumption the
// protocol rests on. v0.1 moves a whole snapshot across the host's pluginIPC
// hop, so no single free-text field may be allowed to fill it: InlineLimit is
// half the host cap, and every free-text ceiling in the schemas is that same
// number. Typing a different number into a schema is the failure this catches —
// the limit is derived in one place and asserted here, never maintained twice.
func TestInlineLimitIsDerivedFromTheHostIPCCap(t *testing.T) {
	if InlineLimit*2 != hostIPCRequestCap {
		t.Fatalf("InlineLimit %d is no longer half the host cap %d; re-derive it", InlineLimit, hostIPCRequestCap)
	}

	r := registry(t)
	// Every free-text ceiling in the schemas is one of the two named constants,
	// and the engine truncates to the same constant before it writes. A schema
	// the engine does not agree with is a ceiling the engine would discover by
	// being refused after a model had already been paid for.
	ceilings := []struct {
		schema  string
		pointer []string
		want    int
		named   string
	}{
		{schemas.Session, []string{"$defs", "Contribution", "properties", "text"}, InlineLimit, "InlineLimit"},
		{schemas.CouncilDefinition, []string{"$defs", "Anchor", "properties", "quote"}, InlineLimit, "InlineLimit"},
		{schemas.Session, []string{"$defs", "Claim", "properties", "text"}, ClaimTextLimit, "ClaimTextLimit"},
		{schemas.Session, []string{"properties", "question"}, ClaimTextLimit, "ClaimTextLimit"},
		{schemas.Session, []string{"$defs", "Run", "properties", "prompt"}, ClaimTextLimit, "ClaimTextLimit"},
	}
	for _, ft := range ceilings {
		node, err := r.lookup(ft.schema, ft.pointer)
		if err != nil {
			t.Errorf("%s %v: %v", ft.schema, ft.pointer, err)
			continue
		}
		got, ok := node["maxLength"].(float64)
		if !ok {
			t.Errorf("%s %v: no maxLength; every free-text field carries a named ceiling", ft.schema, ft.pointer)
			continue
		}
		if int(got) != ft.want {
			t.Errorf("%s %v: maxLength %d, want %s %d", ft.schema, ft.pointer, int(got), ft.named, ft.want)
		}
	}
}
