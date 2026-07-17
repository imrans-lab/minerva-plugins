package board

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// TestSMDPadDimsSurviveJSONMarshal guards the board-load gap: pad_width_mm /
// pad_height_mm on an SMD pin must survive a YAML->Board->JSON round-trip. They
// were previously parked in Pin.Extra (json:"-") and silently dropped on JSON
// marshal, which lost SMD pad dimensions over the pcb.deserialize IPC reply that
// minerva_pcb_load_board depends on.
func TestSMDPadDimsSurviveJSONMarshal(t *testing.T) {
	yamlSrc := "version: 1\nname: SMD\nwidth_mm: 10\nheight_mm: 10\n" +
		"components:\n  - ref: SW1\n    footprint: SWITCH\n    x_mm: 5\n    y_mm: 5\n    rotation_deg: 0\n" +
		"    pins:\n      - {number: A, x_mm: -3, y_mm: 0, pad_width_mm: 2, pad_height_mm: 2}\n" +
		"nets: []\n"
	b, err := UnmarshalYAML([]byte(yamlSrc))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	p := b.Components[0].Pins[0]
	if p.PadWidthMM != 2 || p.PadHeightMM != 2 {
		t.Fatalf("YAML did not bind SMD pad dims to first-class fields: %+v", p)
	}
	out, err := json.Marshal(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !bytes.Contains(out, []byte("pad_width_mm")) || !bytes.Contains(out, []byte("pad_height_mm")) {
		t.Fatalf("SMD pad dims dropped on JSON marshal:\n%s", out)
	}
}

// canonicalYAML is a hand-written source in the canonical contract, exercising
// every top-level section including the opaque annotations / route_hints. It is
// the anchor for the round-trip property: parsing it yields a Board whose
// interface{} values are already yaml-native, so re-marshaling is a fixed point.
const canonicalYAML = `version: 1
name: Blinky
width_mm: 40
height_mm: 30
grid_mm: 2.54
layers:
    - top
    - bottom
design_rules:
    clearance_mm: 0.2
    trace_width_mm: 0.25
    via_diameter_mm: 0.8
    via_drill_mm: 0.4
components:
    - ref: R1
      footprint: Resistor_SMD:R_0805_2012Metric
      value: "330"
      x_mm: 10
      y_mm: 5
      rotation_deg: 0
      layer: top
      pins:
        - number: "1"
          x_mm: 0
          y_mm: 0
        - number: "2"
          x_mm: 2.54
          y_mm: 0
    - ref: U1
      footprint: IC_DIP
      value: NE555
      x_mm: 20
      y_mm: 12
      rotation_deg: 90
      layer: top
nets:
    - name: VCC
      pins:
        - U1.8
        - R1.1
    - name: GND
      pins:
        - U1.1
traces:
    - net: VCC
      layer: top
      width_mm: 0.25
      points:
        - x_mm: 10
          y_mm: 5
        - x_mm: 20
          y_mm: 12
vias:
    - x_mm: 15
      y_mm: 8
      drill_mm: 0.4
      diameter_mm: 0.8
      net: VCC
annotations:
    - id: ann_000042
      type: ARROW
      text: route this first
      author: human
annotations_note: kept opaque
route_hints:
    - id: rhint_000007
      hint_type: SINGLE_TRACE
      source_pins:
        - R1.1
      dest_pins:
        - U1.8
`

func TestRoundTripFromYAMLDeepEqual(t *testing.T) {
	b1, err := UnmarshalYAML([]byte(canonicalYAML))
	if err != nil {
		t.Fatalf("unmarshal canonical: %v", err)
	}
	out, err := MarshalYAML(b1)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	b2, err := UnmarshalYAML(out)
	if err != nil {
		t.Fatalf("unmarshal round-trip: %v", err)
	}
	if !reflect.DeepEqual(b1, b2) {
		t.Fatalf("round-trip not deep-equal.\n b1=%#v\n b2=%#v", b1, b2)
	}
	// Annotations passthrough must survive intact.
	if len(b2.Annotations) != 1 || b2.Annotations[0]["id"] != "ann_000042" {
		t.Fatalf("annotation passthrough lost: %#v", b2.Annotations)
	}
	if len(b2.RouteHints) != 1 || b2.RouteHints[0]["id"] != "rhint_000007" {
		t.Fatalf("route_hint passthrough lost: %#v", b2.RouteHints)
	}
}

func TestRoundTripFromModelDeepEqual(t *testing.T) {
	b1 := &Board{
		Version:  1,
		Name:     "Model",
		WidthMM:  50,
		HeightMM: 25,
		GridMM:   1.27,
		Layers:   []string{"top", "bottom"},
		Origin:   &Point{XMM: 0, YMM: 0},
		DesignRules: DesignRules{
			ClearanceMM: 0.2, TraceWidthMM: 0.25,
		},
		Components: []Component{
			{
				Ref: "U1", Footprint: "IC_DIP", Value: "NE555",
				XMM: 20, YMM: 12, RotationDeg: 90, Layer: "top",
				Pins: []Pin{{Number: "1", XMM: 0, YMM: 0}},
			},
		},
		Nets:   []Net{{Name: "GND", Pins: []string{"U1.1"}}},
		Traces: []Trace{{Net: "GND", Layer: "top", WidthMM: 0.25, Points: []Point{{XMM: 1, YMM: 1}}}},
		Vias:   []Via{{XMM: 5, YMM: 5, DrillMM: 0.4, DiameterMM: 0.8}},
		// Blob values chosen to round-trip stably through interface{}:
		// strings, bool, int, and a non-integer float.
		Annotations: []Blob{{"id": "ann_1", "text": "hi", "flag": true, "count": 3, "weight": 1.5}},
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
		t.Fatalf("round-trip not deep-equal.\n b1=%#v\n b2=%#v", b1, b2)
	}
}

func TestDeterministicOutput(t *testing.T) {
	b, err := UnmarshalYAML([]byte(canonicalYAML))
	if err != nil {
		t.Fatal(err)
	}
	first, _ := MarshalYAML(b)
	for i := 0; i < 20; i++ {
		next, _ := MarshalYAML(b)
		if !bytes.Equal(first, next) {
			t.Fatalf("marshal not deterministic on iteration %d", i)
		}
	}

	// Permuted input: the same logical board with keys in a different order
	// (including inside the opaque annotation blob and the unknown top-level
	// key) must marshal to byte-identical YAML — struct fields fix the field
	// order and yaml.v3 sorts map/inline keys.
	const permutedYAML = `route_hints:
    - source_pins:
        - R1.1
      dest_pins:
        - U1.8
      hint_type: SINGLE_TRACE
      id: rhint_000007
annotations_note: kept opaque
annotations:
    - author: human
      text: route this first
      type: ARROW
      id: ann_000042
vias:
    - net: VCC
      diameter_mm: 0.8
      drill_mm: 0.4
      y_mm: 8
      x_mm: 15
traces:
    - points:
        - y_mm: 5
          x_mm: 10
        - y_mm: 12
          x_mm: 20
      width_mm: 0.25
      layer: top
      net: VCC
nets:
    - pins:
        - U1.8
        - R1.1
      name: VCC
    - pins:
        - U1.1
      name: GND
components:
    - layer: top
      rotation_deg: 0
      y_mm: 5
      x_mm: 10
      value: "330"
      footprint: Resistor_SMD:R_0805_2012Metric
      ref: R1
      pins:
        - y_mm: 0
          x_mm: 0
          number: "1"
        - y_mm: 0
          x_mm: 2.54
          number: "2"
    - layer: top
      rotation_deg: 90
      y_mm: 12
      x_mm: 20
      value: NE555
      footprint: IC_DIP
      ref: U1
design_rules:
    via_drill_mm: 0.4
    via_diameter_mm: 0.8
    trace_width_mm: 0.25
    clearance_mm: 0.2
layers:
    - top
    - bottom
grid_mm: 2.54
height_mm: 30
width_mm: 40
name: Blinky
version: 1
`
	bp, err := UnmarshalYAML([]byte(permutedYAML))
	if err != nil {
		t.Fatalf("unmarshal permuted: %v", err)
	}
	permOut, err := MarshalYAML(bp)
	if err != nil {
		t.Fatalf("marshal permuted: %v", err)
	}
	if !bytes.Equal(first, permOut) {
		t.Fatalf("permuted input did not marshal byte-identical.\n canonical:\n%s\n permuted:\n%s", first, permOut)
	}
}

func TestUnknownTopLevelKeySurvives(t *testing.T) {
	src := canonicalYAML + "experimental_zone: {enabled: true}\n"
	b, err := UnmarshalYAML([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := b.Extra["experimental_zone"]; !ok {
		t.Fatalf("unknown top-level key not captured in Extra: %#v", b.Extra)
	}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(out), "experimental_zone") {
		t.Fatalf("unknown key dropped on re-marshal:\n%s", out)
	}
}

func TestMalformedYAMLReturnsError(t *testing.T) {
	cases := []string{
		"::: not yaml :::",
		"components: [unterminated",
		"\t\ttabs: are: illegal",
	}
	for _, c := range cases {
		if _, err := UnmarshalYAML([]byte(c)); err == nil {
			t.Errorf("expected error for malformed input %q, got nil", c)
		}
	}
}
