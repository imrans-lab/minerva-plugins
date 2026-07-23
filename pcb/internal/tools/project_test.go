package tools

import (
	"context"
	"encoding/json"
	"fmt"
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

// pcb.serialize must fail closed on a null element in ANY of the five entity
// collections. JSON decodes a null into a ZERO-VALUED struct (a phantom entity),
// so the raw-JSON probe rejects it with invalid_board_structure rather than
// emitting it into canonical source (finding 019f8b7fb07e).
func TestSerializeRejectsNullEntity(t *testing.T) {
	const tmpl = `{"board":{"version":1,"name":"T","width_mm":40,"height_mm":30,` +
		`"components":%s,"nets":%s,"traces":%s,"vias":%s,"mounting_holes":%s}}`
	empty := "[]"
	null := "[null]"
	for _, tc := range []struct{ name, comps, nets, traces, vias, holes string }{
		{"component", null, empty, empty, empty, empty},
		{"net", empty, null, empty, empty, empty},
		{"trace", empty, empty, null, empty, empty},
		{"via", empty, empty, empty, null, empty},
		{"mounting_hole", empty, empty, empty, empty, null},
	} {
		t.Run(tc.name, func(t *testing.T) {
			args := json.RawMessage(fmt.Sprintf(tmpl, tc.comps, tc.nets, tc.traces, tc.vias, tc.holes))
			_, err := HandleSerialize(context.Background(), args)
			if err == nil {
				t.Fatalf("serialize accepted a null %s; want a fail-closed error", tc.name)
			}
			if !strings.Contains(err.Error(), "invalid_board_structure") {
				t.Fatalf("want invalid_board_structure, got: %v", err)
			}
		})
	}
}

// A present non-list entity collection is also invalid_board_structure (the probe
// mirrors the YAML path: a mapping/scalar where a sequence is required).
func TestSerializeRejectsNonListCollection(t *testing.T) {
	args := json.RawMessage(`{"board":{"version":1,"name":"T","width_mm":40,"height_mm":30,"components":[],"nets":[],"traces":{"net":"N1"}}}`)
	_, err := HandleSerialize(context.Background(), args)
	if err == nil || !strings.Contains(err.Error(), "invalid_board_structure") {
		t.Fatalf("want invalid_board_structure for non-list traces, got: %v", err)
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

// An unsupported schema version must fail closed at deserialize rather than be
// silently migrated (version 0/missing) or accepted (version 3). Migration is
// gated on version==1; everything else goes through Validate (Fable Round D, D3).
func TestDeserializeUnsupportedVersionFailsClosed(t *testing.T) {
	for _, yaml := range []string{
		"version: 0\nname: Z\nwidth_mm: 10\nheight_mm: 10\ncomponents: []\nnets: []\n",
		"version: 3\nid: board:0123456789abcdef0123456789abcdef\nname: T\nwidth_mm: 10\nheight_mm: 10\ncomponents: []\nnets: []\n",
		"name: NoVer\nwidth_mm: 10\nheight_mm: 10\ncomponents: []\nnets: []\n",
	} {
		args, _ := json.Marshal(map[string]string{"yaml": yaml})
		if _, err := HandleDeserialize(context.Background(), args); err == nil {
			t.Errorf("expected deserialize error for unsupported version, got nil\nyaml: %s", yaml)
		}
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

// End-to-end IPC proof for finding 019f8b7fbbd7: unknown YAML fields at the root
// AND nested inside a component must SURVIVE the real pcb.deserialize →
// pcb.serialize round trip. The direct Go YAML→Board→YAML path already preserved
// them via yaml:",inline"; the IPC path was broken because pcb.deserialize returns
// {"board": b} via encoding/json, which stripped every Extra (json:"-") before the
// host saw the board — so a later pcb.serialize could not restore them. The custom
// JSON marshalers inline Extra, closing that gap. This test drives the ACTUAL
// handlers, mirroring the wire shape: deserialize emits {board,...}; serialize
// consumes {board:<that JSON>}.
func TestIPCRoundTripPreservesUnknownYAMLFields(t *testing.T) {
	// version 1 so it migrates to v2 (mints ids) and passes Validate on serialize.
	// forward_compat_root (root) and forward_compat_pin (nested in a pin) are
	// unmodeled — they exist only via Extra inline.
	yaml := "version: 1\n" +
		"name: FC\nwidth_mm: 40\nheight_mm: 30\n" +
		"forward_compat_root: {source: architect, rev: 9}\n" +
		"components:\n" +
		"  - ref: U1\n    footprint: IC_DIP\n    x_mm: 1\n    y_mm: 2\n    rotation_deg: 0\n" +
		"    mpn: ATMEGA328P\n" +
		"    pins:\n      - number: '1'\n        x_mm: 0\n        y_mm: 0\n        signal_class: analog\n" +
		"nets: []\n"

	// Step 1: pcb.deserialize (YAML in → {board, warnings}).
	desArgs, _ := json.Marshal(map[string]string{"yaml": yaml})
	desOut, err := HandleDeserialize(context.Background(), desArgs)
	if err != nil {
		t.Fatalf("deserialize: %v", err)
	}
	var des struct {
		Board json.RawMessage `json:"board"`
	}
	if err := json.Unmarshal(desOut, &des); err != nil {
		t.Fatal(err)
	}
	// The unknown keys must be present in the JSON the host receives (the
	// previously-broken boundary): they were stripped before this fix.
	boardJSON := string(des.Board)
	if !strings.Contains(boardJSON, "forward_compat_root") {
		t.Fatalf("root unknown field stripped from deserialize JSON:\n%s", boardJSON)
	}
	if !strings.Contains(boardJSON, "mpn") || !strings.Contains(boardJSON, "signal_class") {
		t.Fatalf("nested unknown field stripped from deserialize JSON:\n%s", boardJSON)
	}

	// Step 2: pcb.serialize (the deserialized board back out → YAML).
	serArgs, _ := json.Marshal(map[string]json.RawMessage{"board": des.Board})
	serOut, err := HandleSerialize(context.Background(), serArgs)
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	var ser struct {
		YAML  string `json:"yaml"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(serOut, &ser); err != nil {
		t.Fatal(err)
	}
	if ser.Error != "" {
		t.Fatalf("serialize error: %s", ser.Error)
	}
	// The unknown fields survived the full IPC round trip into the re-emitted YAML.
	for _, want := range []string{"forward_compat_root", "source: architect", "mpn: ATMEGA328P", "signal_class: analog"} {
		if !strings.Contains(ser.YAML, want) {
			t.Fatalf("unknown field %q lost across IPC round trip:\n%s", want, ser.YAML)
		}
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
