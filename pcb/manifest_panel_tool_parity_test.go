package main

import (
	"encoding/json"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// ── panel-executed TOOL parity ──────────────────────────────────────────────
//
// A tool declared with "executor": "panel" is never registered with the Go
// broker (TestManifestBrokerParity covers only the backend-executor set). The
// Minerva host resolves args.editor_name to the live PCBPanel and calls
// PCBPanel.handle_tool, which forwards to pcb/ui/panel_tools.gd's dispatch
// match. So the registration a panel tool actually has is a `case` arm in that
// match — and nothing pinned the two lists together.
//
// The failure that leaves is silent and one-sided in both directions: a
// manifest entry with no arm is a tool an agent can see and call that falls
// through to the unknown-tool error, and an arm with no manifest entry is a
// verb that exists and is invisible. This test derives the second list from the
// panel CODE (not a hand-maintained copy) and asserts the sets are equal.

// panelToolCaseRe matches one dispatch arm: a bare `"minerva_pcb_*":` line, and
// the stacked-case form `"minerva_pcb_*",` that GDScript allows for arms that
// share a body.
var panelToolCaseRe = regexp.MustCompile(`(?m)^\s*"(minerva_pcb_[a-z0-9_]+)"\s*[:,]\s*$`)

func manifestPanelTools(t *testing.T) map[string]manifestTool {
	t.Helper()
	data, err := os.ReadFile("manifest.json")
	if err != nil {
		t.Fatalf("read manifest.json: %v", err)
	}
	var mf manifestFile
	if err := json.Unmarshal(data, &mf); err != nil {
		t.Fatalf("parse manifest.json: %v", err)
	}
	out := map[string]manifestTool{}
	for _, tool := range mf.Tools {
		if tool.Executor == "panel" {
			out[tool.Name] = tool
		}
	}
	return out
}

func panelToolDispatchArms(t *testing.T) map[string]bool {
	t.Helper()
	src, err := os.ReadFile("ui/panel_tools.gd")
	if err != nil {
		t.Fatalf("read ui/panel_tools.gd: %v", err)
	}
	// Comments in this file quote tool names in prose; blank them so a mention
	// cannot be mistaken for a dispatch arm.
	out := map[string]bool{}
	for _, m := range panelToolCaseRe.FindAllStringSubmatch(blankGDComments(string(src)), -1) {
		out[m[1]] = true
	}
	return out
}

func TestManifestPanelToolsAreDispatched(t *testing.T) {
	manifest := manifestPanelTools(t)
	arms := panelToolDispatchArms(t)
	if len(arms) == 0 {
		t.Fatal("scanned ui/panel_tools.gd and found no dispatch arms — the scanner pattern has drifted from the panel code")
	}

	var undispatched, undeclared []string
	for name := range manifest {
		if !arms[name] {
			undispatched = append(undispatched, name)
		}
	}
	for name := range arms {
		if _, ok := manifest[name]; !ok {
			undeclared = append(undeclared, name)
		}
	}
	sort.Strings(undispatched)
	sort.Strings(undeclared)
	if len(undispatched) > 0 {
		t.Errorf("manifest declares panel tool(s) panel_tools.gd does not dispatch (an agent can call them and gets the unknown-tool error): %v", undispatched)
	}
	if len(undeclared) > 0 {
		t.Errorf("panel_tools.gd dispatches tool(s) the manifest does not declare (they exist and no agent can see them): %v", undeclared)
	}
	t.Logf("checked %d panel-executed tool(s) against panel_tools.gd", len(manifest))
}

// TestSetRefdesSchema pins the argument surface of minerva_pcb_set_refdes: the
// five writable anchor fields plus the two envelope keys, no more, and the two
// facts a caller plans against — the size bound, and that an out-of-range value
// is REFUSED rather than clamped. The refusal BEHAVIOUR is pinned panel-side
// (pcb/tests/gd/test_part_geometry_contracts.gd section 5); what is pinned here
// is that the schema an agent reads before the plugin ever starts says the same
// thing the handler does.
func TestSetRefdesSchema(t *testing.T) {
	tool, ok := manifestPanelTools(t)["minerva_pcb_set_refdes"]
	if !ok {
		t.Fatal("manifest does not declare minerva_pcb_set_refdes as a panel tool")
	}
	var schema struct {
		Properties map[string]struct {
			Type        string `json:"type"`
			Description string `json:"description"`
		} `json:"properties"`
		Required []string `json:"required"`
	}
	if err := json.Unmarshal(tool.InputSchema, &schema); err != nil {
		t.Fatalf("parse input_schema: %v", err)
	}

	want := map[string]string{
		"editor_name":  "string",
		"component_id": "string",
		"x_mm":         "number",
		"y_mm":         "number",
		"rotation_deg": "number",
		"size_mm":      "number",
		"hidden":       "boolean",
	}
	for name, kind := range want {
		prop, present := schema.Properties[name]
		if !present {
			t.Errorf("input_schema omits %q", name)
			continue
		}
		if prop.Type != kind {
			t.Errorf("%q declares type %q, want %q", name, prop.Type, kind)
		}
	}
	for name := range schema.Properties {
		if _, expected := want[name]; !expected {
			t.Errorf("input_schema declares unexpected key %q", name)
		}
	}
	if got := strings.Join(schema.Required, ","); got != "editor_name,component_id" {
		t.Errorf("required = %q, want \"editor_name,component_id\" — every anchor field is optional so the verb can READ", got)
	}
	// The bound and the no-clamp promise both have to be visible to the agent
	// reading the schema, because the handler refuses on both.
	size := schema.Properties["size_mm"].Description
	for _, claim := range []string{"0.2", "10", "clamp"} {
		if !strings.Contains(size, claim) {
			t.Errorf("size_mm description omits %q: %s", claim, size)
		}
	}
	// The verb is only useful if a caller knows where the suggestion comes from.
	for _, claim := range []string{"gc9_silk_under_part", "gc9_silk_over_silk", "suggestion"} {
		if !strings.Contains(tool.Description, claim) {
			t.Errorf("description omits %q — the DRC row is what produces these arguments", claim)
		}
	}
}
