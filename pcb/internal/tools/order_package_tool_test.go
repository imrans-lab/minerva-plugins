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

// The unchecked_rules entry is the SHAPE THE WORKER SENDS — {id, reason}, the
// rows a service profile authors and service_profile.py forwards verbatim — not
// the {code, message} every other finding carries. A fixture written in the
// wrong shape is a fixture that passes over a consumer reading the wrong keys.
func TestAssemblyReplyForwardsEveryPromisedList(t *testing.T) {
	raw := json.RawMessage(`{
		"files": {"b.csv": "h\r\nr\r\n", "c.csv": "h\r\nr\r\n"},
		"bom_file": "b.csv",
		"cpl_file": "c.csv",
		"excluded_components": ["R9"],
		"advisories": [{"code": "assembly_anchor_unmeasured", "component": "J2"}],
		"unchecked_rules": [{"id": "order_quantity_2_to_50_pcs",
			"reason": "quantity is an order-form choice, not board data"}],
		"warnings": [{"severity": "WARNING", "code": "captured_geometry_not_emitted",
			"source_ref": {"entity_kind": "component", "entity_id": "U1"}}]
	}`)
	reply, err := decodeAssemblyPackage(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	// DECODING IS HALF. The name of this test is "forwards", so it drives the
	// forwarding step too and reads the keys back out of the JSON the caller is
	// handed — a struct field that never reaches the reply is the same silent
	// drop as a field that was never declared.
	out, err := assemblyReplyJSON(reply, "jlcpcb-economic",
		assemblyOutputSummary{Filename: "b.csv", Rows: 1},
		assemblyOutputSummary{Filename: "c.csv", Rows: 1})
	if err != nil {
		t.Fatalf("forward: %v", err)
	}
	var forwarded struct {
		Profile            string            `json:"profile"`
		ExcludedComponents []string          `json:"excluded_components"`
		Advisories         []json.RawMessage `json:"advisories"`
		UncheckedRules     []json.RawMessage `json:"unchecked_rules"`
		Warnings           []json.RawMessage `json:"warnings"`
	}
	if err := json.Unmarshal(out, &forwarded); err != nil {
		t.Fatalf("the forwarded reply is not valid JSON: %v", err)
	}
	if forwarded.Profile != "jlcpcb-economic" {
		t.Errorf("profile = %q", forwarded.Profile)
	}
	if len(forwarded.ExcludedComponents) != 1 {
		t.Errorf("excluded_components dropped: %d", len(forwarded.ExcludedComponents))
	}
	if len(forwarded.Advisories) != 1 {
		t.Errorf("advisories dropped: %d", len(forwarded.Advisories))
	}
	if len(forwarded.UncheckedRules) != 1 {
		t.Fatalf("unchecked_rules dropped — the tool description promises them: %d", len(forwarded.UncheckedRules))
	}
	// Both halves of the entry, so a reshaping in transit fails here rather
	// than reaching a consumer that renders blank bullets.
	for _, want := range []string{"order_quantity_2_to_50_pcs", "order-form choice"} {
		if !strings.Contains(string(forwarded.UncheckedRules[0]), want) {
			t.Errorf("an unchecked rule must keep %q: %s", want, forwarded.UncheckedRules[0])
		}
	}
	if len(forwarded.Warnings) != 1 {
		t.Fatalf("compile warnings dropped: %d", len(forwarded.Warnings))
	}
	if !strings.Contains(string(forwarded.Warnings[0]), "U1") {
		t.Errorf("a warning must keep the component it is about: %s", forwarded.Warnings[0])
	}
}

// A list the worker did not send stays ABSENT rather than arriving empty: a
// caller distinguishes "there were none" from "the tool forgot to ask" by the
// key's presence, so forwarding an empty array would be a claim of its own.
func TestAssemblyReplyOmitsListsTheWorkerDidNotSend(t *testing.T) {
	reply, err := decodeAssemblyPackage(json.RawMessage(
		`{"files": {"b.csv": "h", "c.csv": "h"}, "bom_file": "b.csv", "cpl_file": "c.csv"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	out, err := assemblyReplyJSON(reply, "", assemblyOutputSummary{}, assemblyOutputSummary{})
	if err != nil {
		t.Fatalf("forward: %v", err)
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(out, &keys); err != nil {
		t.Fatalf("the forwarded reply is not valid JSON: %v", err)
	}
	for _, absent := range []string{"advisories", "unchecked_rules", "warnings", "excluded_components"} {
		if _, ok := keys[absent]; ok {
			t.Errorf("%q was forwarded as an empty list", absent)
		}
	}
	if string(keys["profile"]) != `"jlc"` {
		t.Errorf("an omitted profile must default to the worker's own: %s", keys["profile"])
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
	for _, key := range []string{"yaml", "board", "board_path", "board_digest",
		"profile", "out_dir", "overwrite", "source_path"} {
		if _, ok := schema.Properties[key]; !ok {
			t.Errorf("input schema declares no %q", key)
		}
	}
	// The by-reference arm is the ONLY one that earns a git revision, so it has
	// to be reachable: an undeclared board_path is refused by the host's schema
	// validation before the handler runs, which would leave every package's
	// provenance permanently unavailable.
	for _, phrase := range []string{"worker-read", "caller-asserted"} {
		if !strings.Contains(OrderPackage.Description, phrase) {
			t.Errorf("description does not tell a caller about %q provenance", phrase)
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
