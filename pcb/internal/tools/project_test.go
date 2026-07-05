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
