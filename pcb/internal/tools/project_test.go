package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestSerializeBoardToYAML(t *testing.T) {
	args := json.RawMessage(`{"board":{"version":1,"name":"T","width_mm":40,"height_mm":30,"components":[{"ref":"U1","footprint":"IC_DIP","x_mm":1,"y_mm":2,"rotation_deg":0}],"nets":[]}}`)
	out, err := HandleSerialize(context.Background(), args)
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	var r struct {
		YAML  string `json:"yaml"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if r.Error != "" {
		t.Fatalf("unexpected error result: %s", r.Error)
	}
	if !strings.Contains(r.YAML, "name: T") || !strings.Contains(r.YAML, "ref: U1") {
		t.Fatalf("yaml missing expected content:\n%s", r.YAML)
	}
}

func TestDeserializeYAMLToBoard(t *testing.T) {
	yaml := "version: 1\nname: T\nwidth_mm: 40\nheight_mm: 30\ncomponents:\n  - ref: U1\n    footprint: IC_DIP\n    x_mm: 1\n    y_mm: 2\n    rotation_deg: 0\nnets: []\n"
	args, _ := json.Marshal(map[string]string{"yaml": yaml})
	out, err := HandleDeserialize(context.Background(), args)
	if err != nil {
		t.Fatalf("deserialize: %v", err)
	}
	var r struct {
		Board    map[string]interface{} `json:"board"`
		Warnings []string               `json:"warnings"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if r.Board["name"] != "T" {
		t.Fatalf("board name: want T, got %v", r.Board["name"])
	}
	if r.Warnings == nil {
		t.Fatalf("warnings must be present (empty slice), got nil")
	}
}

// Deserializing a sub-v2 board migrates it: the returned board is v2, every
// trace/via/hole plus the board itself carries a minted "type:<32 hex>" id, and
// a migration warning is surfaced (design decision D3 — mint at deserialize).
func TestDeserializeMigratesV1BoardToV2(t *testing.T) {
	yaml := "version: 1\nname: Mig\nwidth_mm: 40\nheight_mm: 30\n" +
		"components:\n  - ref: U1\n    footprint: IC_DIP\n    x_mm: 1\n    y_mm: 2\n    rotation_deg: 0\n" +
		"nets: []\n" +
		"traces:\n  - net: N\n    points:\n      - {x_mm: 1, y_mm: 1}\n      - {x_mm: 2, y_mm: 2}\n" +
		"vias:\n  - {x_mm: 5, y_mm: 5, drill_mm: 0.4, diameter_mm: 0.8}\n"
	args, _ := json.Marshal(map[string]string{"yaml": yaml})
	out, err := HandleDeserialize(context.Background(), args)
	if err != nil {
		t.Fatalf("deserialize: %v", err)
	}
	var r struct {
		Board    map[string]interface{} `json:"board"`
		Warnings []string               `json:"warnings"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	// version bumped to 2 (JSON numbers decode as float64).
	if v, _ := r.Board["version"].(float64); v != 2 {
		t.Fatalf("version: want 2, got %v", r.Board["version"])
	}
	if id, _ := r.Board["id"].(string); !strings.HasPrefix(id, "board:") || len(id) != len("board:")+32 {
		t.Fatalf("board id not minted: %q", r.Board["id"])
	}
	traces, _ := r.Board["traces"].([]interface{})
	if len(traces) != 1 {
		t.Fatalf("traces: want 1, got %#v", r.Board["traces"])
	}
	tr, _ := traces[0].(map[string]interface{})
	if id, _ := tr["id"].(string); !strings.HasPrefix(id, "trace:") || len(id) != len("trace:")+32 {
		t.Fatalf("trace id not minted: %q", tr["id"])
	}
	foundWarn := false
	for _, w := range r.Warnings {
		if strings.Contains(w, "v1→v2") {
			foundWarn = true
		}
	}
	if !foundWarn {
		t.Fatalf("migration warning not surfaced: %#v", r.Warnings)
	}
}

// A board that is already v2 is not re-migrated: no id churn, no warning.
func TestDeserializeDoesNotReMigrateV2(t *testing.T) {
	id := "board:" + strings.Repeat("a", 32)
	yaml := "version: 2\nid: " + id + "\nname: V2\nwidth_mm: 10\nheight_mm: 10\ncomponents: []\nnets: []\n"
	args, _ := json.Marshal(map[string]string{"yaml": yaml})
	out, err := HandleDeserialize(context.Background(), args)
	if err != nil {
		t.Fatalf("deserialize: %v", err)
	}
	var r struct {
		Board    map[string]interface{} `json:"board"`
		Warnings []string               `json:"warnings"`
	}
	_ = json.Unmarshal(out, &r)
	if got, _ := r.Board["id"].(string); got != id {
		t.Fatalf("v2 board id churned: got %q, want %q", got, id)
	}
	for _, w := range r.Warnings {
		if strings.Contains(w, "v1→v2") {
			t.Fatalf("v2 board should not emit a migration warning: %#v", r.Warnings)
		}
	}
}

// End-to-end: importing a legacy .minpcb through pcb.deserialize must MINT
// persistent ids — even for a legacy trace whose ordinal-shaped id ("trace_1")
// the importer carried into the ID field, and even if the file lies about its
// version. Proves the composed importer→migration path, not just the units.
func TestDeserializeMinpcbMintsIdsAndClampsVersion(t *testing.T) {
	// version:2 is a lie — a .minpcb is a pre-v2 legacy source; the importer must
	// clamp to v1 so the mint still fires over its ordinal ids.
	minpcb := `{"version":2,"board_name":"Leg","board_width":10,"board_height":10,` +
		`"components":{"R1":{"id":"R1","footprint":"RESISTOR","position":{"x":1,"y":1},"rotation":0}},` +
		`"nets":{"N":{"pins":[]}},` +
		`"traces":{"trace_1":{"id":"trace_1","net_name":"N","waypoints":[{"x":1,"y":1},{"x":2,"y":2}],"width":0.25}}}`
	args, _ := json.Marshal(map[string]json.RawMessage{"minpcb_json": json.RawMessage(minpcb)})
	out, err := HandleDeserialize(context.Background(), args)
	if err != nil {
		t.Fatalf("deserialize minpcb: %v", err)
	}
	var r struct {
		Board    map[string]interface{} `json:"board"`
		Warnings []string               `json:"warnings"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if v, _ := r.Board["version"].(float64); v != 2 {
		t.Fatalf("version: want 2 (migrated), got %v", r.Board["version"])
	}
	traces, _ := r.Board["traces"].([]interface{})
	if len(traces) != 1 {
		t.Fatalf("traces: want 1, got %#v", r.Board["traces"])
	}
	tr, _ := traces[0].(map[string]interface{})
	id, _ := tr["id"].(string)
	if id == "trace_1" || !strings.HasPrefix(id, "trace:") || len(id) != len("trace:")+32 {
		t.Fatalf("legacy ordinal trace id not re-minted: %q", id)
	}
}

func TestDeserializeMinpcbJSON(t *testing.T) {
	minpcb := `{"version":1,"board_name":"Leg","board_width":10,"board_height":10,"components":{"R1":{"id":"R1","footprint":"RESISTOR","position":{"x":1,"y":1},"rotation":0}},"nets":{},"annotations":{"a1":{"id":"a1","type":"TEXT","text":"hi"}}}`
	args, _ := json.Marshal(map[string]json.RawMessage{"minpcb_json": json.RawMessage(minpcb)})
	out, err := HandleDeserialize(context.Background(), args)
	if err != nil {
		t.Fatalf("deserialize minpcb: %v", err)
	}
	var r struct {
		Board    map[string]interface{} `json:"board"`
		Warnings []string               `json:"warnings"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if r.Board["name"] != "Leg" {
		t.Fatalf("imported board name: want Leg, got %v", r.Board["name"])
	}
	anns, ok := r.Board["annotations"].([]interface{})
	if !ok || len(anns) != 1 {
		t.Fatalf("annotation passthrough lost: %#v", r.Board["annotations"])
	}
}

// A double-encoded minpcb_json (JSON string) must still parse.
func TestDeserializeMinpcbJSONAsString(t *testing.T) {
	minpcb := `{"version":1,"board_name":"Str","board_width":5,"board_height":5,"components":{},"nets":{}}`
	args, _ := json.Marshal(map[string]string{"minpcb_json": minpcb})
	out, err := HandleDeserialize(context.Background(), args)
	if err != nil {
		t.Fatalf("deserialize minpcb string: %v", err)
	}
	var r struct {
		Board map[string]interface{} `json:"board"`
	}
	_ = json.Unmarshal(out, &r)
	if r.Board["name"] != "Str" {
		t.Fatalf("string-encoded minpcb not parsed: %#v", r.Board)
	}
}

// No board/yaml/minpcb → project_file {state} echo fallback (compat).
func TestSerializeFallsBackToStateEcho(t *testing.T) {
	args := json.RawMessage(`{"state":{"foo":"bar"}}`)
	out, err := HandleSerialize(context.Background(), args)
	if err != nil {
		t.Fatal(err)
	}
	var r map[string]interface{}
	_ = json.Unmarshal(out, &r)
	if r["ok"] != true {
		t.Fatalf("expected echo ok, got %#v", r)
	}
}

// Non-empty but unparseable params must ERROR — never silently fall through to
// the {state} echo and return ok (cold-review fix 2).
func TestMalformedParamsReturnError(t *testing.T) {
	malformed := json.RawMessage(`{"board": {unterminated`)
	if _, err := HandleSerialize(context.Background(), malformed); err == nil {
		t.Error("HandleSerialize: expected error for malformed params, got nil")
	}
	if _, err := HandleDeserialize(context.Background(), malformed); err == nil {
		t.Error("HandleDeserialize: expected error for malformed params, got nil")
	}
	// Empty params remain valid (echo fallback, no error).
	if _, err := HandleSerialize(context.Background(), nil); err != nil {
		t.Errorf("HandleSerialize: empty params should echo, got error: %v", err)
	}
	if _, err := HandleDeserialize(context.Background(), nil); err != nil {
		t.Errorf("HandleDeserialize: empty params should echo, got error: %v", err)
	}
}

func TestSerializePayloadTooLarge(t *testing.T) {
	// Build a board whose YAML exceeds the cap via many nets.
	var sb strings.Builder
	sb.WriteString(`{"board":{"version":1,"name":"Big","width_mm":100,"height_mm":100,"components":[],"nets":[`)
	for i := 0; i < 4000; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"name":"NET_ABCDEFGHIJKLMNOP_`)
		sb.WriteString(strings.Repeat("x", 8))
		sb.WriteString(`","pins":["U1.1","U2.2","U3.3"]}`)
	}
	sb.WriteString(`]}}`)

	out, err := HandleSerialize(context.Background(), json.RawMessage(sb.String()))
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	var r struct {
		Error string `json:"error"`
		Bytes int    `json:"bytes"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if r.Error != "payload_too_large" {
		t.Fatalf("want payload_too_large, got %#v", r)
	}
	if r.Bytes == 0 {
		t.Errorf("expected non-zero byte count in error")
	}
}
