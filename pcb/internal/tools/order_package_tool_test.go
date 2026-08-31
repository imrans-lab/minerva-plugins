package tools

import (
	"encoding/json"
	"strings"
	"testing"
)

// The tool surface for the order package (task-cycle 12 B4, docket
// 01a0545d027a) and the reply keys the assembly tool used to drop.
//
// ORACLE for the dropped keys: not "the decoder has a field" but "a key the
// worker sends and the DESCRIPTION PROMISES reaches the caller". encoding/json
// discards unknown fields silently, so a promise in prose and an absent struct
// field is a lie no compiler catches — which is exactly what happened to
// unchecked_rules (promised by the B1 description, never decoded) and to the
// compile warnings.

func TestAssemblyReplyForwardsEveryPromisedList(t *testing.T) {
	raw := json.RawMessage(`{
		"files": {"b.csv": "h\r\nr\r\n", "c.csv": "h\r\nr\r\n"},
		"bom_file": "b.csv",
		"cpl_file": "c.csv",
		"excluded_components": ["R9"],
		"advisories": [{"code": "assembly_anchor_unmeasured", "component": "J2"}],
		"unchecked_rules": [{"code": "template_column_drift_resolution"}],
		"warnings": [{"severity": "WARNING", "code": "captured_geometry_not_emitted",
			"source_ref": {"entity_kind": "component", "entity_id": "U1"}}]
	}`)
	reply, err := decodeAssemblyPackage(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(reply.Advisories) != 1 {
		t.Errorf("advisories dropped: %d", len(reply.Advisories))
	}
	if len(reply.UncheckedRules) != 1 {
		t.Errorf("unchecked_rules dropped — the tool description promises them: %d", len(reply.UncheckedRules))
	}
	if len(reply.Warnings) != 1 {
		t.Errorf("compile warnings dropped: %d", len(reply.Warnings))
	}
	if !strings.Contains(string(reply.Warnings[0]), "U1") {
		t.Errorf("a warning must keep the component it is about: %s", reply.Warnings[0])
	}
}

// A reply that names a file it does not carry is a HALF PACKAGE, and it must
// refuse rather than emit an empty filename.
func TestAssemblyReplyRefusesAHalfPackage(t *testing.T) {
	for name, raw := range map[string]string{
		"no cpl named":    `{"files": {"b.csv": "h"}, "bom_file": "b.csv", "cpl_file": ""}`,
		"cpl not carried": `{"files": {"b.csv": "h"}, "bom_file": "b.csv", "cpl_file": "c.csv"}`,
	} {
		if _, err := decodeAssemblyPackage(json.RawMessage(raw)); err == nil {
			t.Errorf("%s: decoded a half package without complaint", name)
		}
	}
}

// PARITY IS THE CONTRACT. The panel's exporter chooser sends on this tool's own
// name as a panel-IPC channel, so there is ONE spec and ONE handler behind both
// the human's click and an agent's call. A second entry would be a second place
// for a refusal to be named.
func TestOrderPackageIsOneEntryForBothSurfaces(t *testing.T) {
	if OrderPackage.Name != "minerva_pcb_order_package" {
		t.Errorf("tool name = %q", OrderPackage.Name)
	}
	var schema struct {
		Properties map[string]json.RawMessage `json:"properties"`
	}
	if err := json.Unmarshal(OrderPackage.InputSchema, &schema); err != nil {
		t.Fatalf("input schema is not valid JSON: %v", err)
	}
	// Every argument the panel path and the document path actually send. A
	// missing property is a caller-visible gap, not a cosmetic one: the host
	// validates against this schema before the handler ever runs.
	for _, key := range []string{"yaml", "board", "profile", "out_dir", "overwrite", "source_path"} {
		if _, ok := schema.Properties[key]; !ok {
			t.Errorf("input schema declares no %q", key)
		}
	}
	// The refusal names the description promises must BE in the description —
	// an agent chooses how to react by matching on these, and a name only the
	// code knows is a name nobody can handle.
	for _, code := range []string{
		"assembly_not_compilable",
		"assembly_duplicate_designator",
		"assembly_service_side_unsupported",
		"assembly_service_fab_profile_mismatch",
	} {
		if !strings.Contains(OrderPackage.Description, code) {
			t.Errorf("description names no refusal %q", code)
		}
	}
	// The honest-outcome half: the third readiness state is never claimed here,
	// and the description has to say so or a caller will read a generated
	// package as an accepted one.
	if !strings.Contains(OrderPackage.Description, "order_page_verified is null every time") {
		t.Error("description does not state that order_page_verified is never set here")
	}
}
