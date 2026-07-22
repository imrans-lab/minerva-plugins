package board

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// Schema v2 adds persistent, mint-once entity identity (board/trace/via/hole
// `id`) and the typed Pin.Override sub-struct that deprecates inline pin
// geometry (item 019f802ca3af, Round A — contract shape only; the migration
// that MINTS ids and the compiler that REQUIRES them are later rounds). These
// tests pin the two contract invariants Round A must hold:
//   1. a v1 board (empty identity) still round-trips byte-clean — omitempty keeps
//      the new fields invisible, so the change is additive, not a v1 break;
//   2. a v2 board carries identity + override losslessly, with pointer semantics
//      that distinguish "unset" from "explicitly zero".

// A v1 board leaves every new v2 field empty; omitempty must keep them out of
// the emitted YAML entirely, so pre-migration boards are untouched.
func TestV1EmptyIdentityFieldsAreOmitted(t *testing.T) {
	b := &Board{
		Version: 1, Name: "V1", WidthMM: 10, HeightMM: 10,
		Components: []Component{{
			Ref: "U1", Footprint: "F",
			Pins: []Pin{{Number: "1"}},
		}},
		Nets:          []Net{{Name: "N", Pins: []string{"U1.1"}}},
		Traces:        []Trace{{Net: "N", Points: []Point{{XMM: 1, YMM: 1}, {XMM: 2, YMM: 2}}}},
		Vias:          []Via{{XMM: 5, YMM: 5}},
		MountingHoles: []Hole{{XMM: 1, YMM: 1, DiameterMM: 3}},
	}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// No entity emits an `id:` key and no pin emits `override:` — this board has
	// no annotations, so any `id:`/`override:` substring would be a leak.
	if strings.Contains(string(out), "id:") {
		t.Fatalf("v1 board emitted an id key (omitempty broken):\n%s", out)
	}
	if strings.Contains(string(out), "override:") {
		t.Fatalf("v1 board emitted an override key (omitempty broken):\n%s", out)
	}
}

// A v2 board round-trips identity + override deep-equal, the identity is present
// in the YAML, and override pointer semantics survive (set dims kept, unset dims
// stay nil, an override-less pin stays override-less).
func TestV2IdentityAndOverrideRoundTrip(t *testing.T) {
	drill := 0.9
	plated := false
	b1 := &Board{
		Version: 2, ID: "board:aaaa", Name: "V2", WidthMM: 10, HeightMM: 10,
		Components: []Component{{
			Ref: "U1", Footprint: "F",
			Pins: []Pin{
				{Number: "1", Override: &PinOverride{DrillMM: &drill, Plated: &plated}},
				{Number: "2"}, // deliberately no override
			},
		}},
		Nets:          []Net{{Name: "N", Pins: []string{"U1.1"}}},
		Traces:        []Trace{{ID: "trace:bbbb", Net: "N", Points: []Point{{XMM: 1, YMM: 1}, {XMM: 2, YMM: 2}}}},
		Vias:          []Via{{ID: "via:cccc", XMM: 5, YMM: 5}},
		MountingHoles: []Hole{{ID: "hole:dddd", XMM: 1, YMM: 1, DiameterMM: 3}},
	}
	out, err := MarshalYAML(b1)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	b2, err := UnmarshalYAML(out)
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !reflect.DeepEqual(b1, b2) {
		t.Fatalf("v2 identity/override round-trip not deep-equal:\n b1=%#v\n b2=%#v", b1, b2)
	}
	for _, want := range []string{"board:aaaa", "trace:bbbb", "via:cccc", "hole:dddd", "override:"} {
		if !strings.Contains(string(out), want) {
			t.Fatalf("expected %q in emitted v2 YAML:\n%s", want, out)
		}
	}
	// Pointer semantics: the set dimension survives, an untouched dimension stays
	// nil (not coerced to 0), and the override-less pin gains nothing.
	ov := b2.Components[0].Pins[0].Override
	if ov == nil || ov.DrillMM == nil || *ov.DrillMM != 0.9 {
		t.Fatalf("override drill_mm lost: %#v", ov)
	}
	if ov.Plated == nil || *ov.Plated != false {
		t.Fatalf("override plated lost: %#v", ov)
	}
	if ov.PadWidthMM != nil {
		t.Fatalf("unset override dimension must stay nil, got %v", *ov.PadWidthMM)
	}
	if b2.Components[0].Pins[1].Override != nil {
		t.Fatalf("override-less pin gained an override across round-trip")
	}
}

// The legacy .minpcb importer must route the source trace/via `id` into the
// modeled ID field, NOT the inline Extra map — a modeled field whose yaml name
// also sits in an inline map makes yaml.v3 panic on marshal (the collision this
// migration surfaced). Non-id passthrough (e.g. `locked`) still lands in Extra.
func TestLegacyTraceIdMapsToModeledField(t *testing.T) {
	b, warnings, err := ImportMinpcb(readFixture(t, "legacy_board.minpcb"))
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("unexpected warnings: %v", warnings)
	}
	if len(b.Traces) != 1 {
		t.Fatalf("traces: want 1, got %d", len(b.Traces))
	}
	tr := b.Traces[0]
	if tr.ID != "trace_1" {
		t.Errorf("legacy trace id not mapped to ID field: got %q", tr.ID)
	}
	if _, ok := tr.Extra["id"]; ok {
		t.Errorf("legacy trace id must not remain in Extra (yaml.v3 marshal collision): %#v", tr.Extra)
	}
	if tr.Extra["locked"] != false {
		t.Errorf("non-id trace passthrough (locked) lost from Extra: %#v", tr.Extra)
	}
	// The imported board must now marshal without the id/Extra collision panic.
	if _, err := MarshalYAML(b); err != nil {
		t.Fatalf("imported board failed to marshal: %v", err)
	}
}

// The via importer must route a legacy via `id` into the modeled ID field
// (the .minpcb fixture has no via id, so this drives importVias directly), and
// a NON-string legacy id must be preserved (stringified), never silently
// dropped — it cannot fall through to Extra without re-creating the yaml.v3
// inline-map collision. Non-id passthrough (e.g. `layers`) still lands in Extra.
func TestLegacyViaIdMapsToModeledFieldNotDropped(t *testing.T) {
	raw := json.RawMessage(`[
		{"position":{"x":1,"y":2},"size":0.8,"drill":0.4,"net_name":"VCC","id":"via_7","layers":["top","bottom"]},
		{"position":{"x":3,"y":4},"size":0.8,"drill":0.4,"id":5}
	]`)
	vias, err := importVias(raw)
	if err != nil {
		t.Fatalf("importVias: %v", err)
	}
	if len(vias) != 2 {
		t.Fatalf("vias: want 2, got %d", len(vias))
	}
	if vias[0].ID != "via_7" {
		t.Errorf("string via id not mapped to ID field: %q", vias[0].ID)
	}
	if _, ok := vias[0].Extra["id"]; ok {
		t.Errorf("via id must not remain in Extra (yaml.v3 collision): %#v", vias[0].Extra)
	}
	if vias[0].Extra["layers"] == nil {
		t.Errorf("non-id via passthrough (layers) lost from Extra: %#v", vias[0].Extra)
	}
	if vias[1].ID != "5" {
		t.Errorf("non-string via id dropped or not stringified: %q", vias[1].ID)
	}
	if _, ok := vias[1].Extra["id"]; ok {
		t.Errorf("stringified via id must not also sit in Extra: %#v", vias[1].Extra)
	}
	// A board carrying both must marshal without the collision panic.
	b := &Board{Version: 2, Name: "x", Components: []Component{}, Nets: []Net{}, Vias: vias}
	if _, err := MarshalYAML(b); err != nil {
		t.Fatalf("marshal board with imported vias: %v", err)
	}
}
