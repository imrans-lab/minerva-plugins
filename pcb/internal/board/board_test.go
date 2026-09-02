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
// they are typed fields, so the pcb.deserialize IPC reply that
// minerva_pcb_load_board depends on carries them.
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

func TestUnknownTopLevelKeyIsRefusedByName(t *testing.T) {
	src := canonicalYAML + "experimental_zone: {enabled: true}\n"
	_, err := UnmarshalYAML([]byte(src))
	if err == nil {
		t.Fatal("an unknown top-level key was accepted")
	}
	if !strings.Contains(err.Error(), "invalid_board_structure") ||
		!strings.Contains(err.Error(), `"experimental_zone"`) {
		t.Fatalf("refusal does not carry the code and the key: %v", err)
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

// TestLegacyAssemblyScalarMigratesAndStillRoundTrips is the "loads exactly as
// it does today" half of the schema change: a board authored with the pre-block
// `assembly: exclude` scalar must keep loading, keep meaning "no BOM/CPL row",
// and reach every reader in the ONE structured shape — through BOTH codecs,
// since the panel forwards over JSON what a YAML load produced.
//
// It also pins the fail-closed half: a typo'd scalar refuses rather than
// travelling as "not excluded" and landing a fiducial in a BOM.
func TestLegacyAssemblyScalarMigratesAndStillRoundTrips(t *testing.T) {
	const src = `version: 1
name: furniture
width_mm: 20
height_mm: 15
components:
  - {ref: C1, footprint: C_0805, x_mm: 5, y_mm: 5}
  - {ref: FID1, footprint: FID, x_mm: 2, y_mm: 2, assembly: exclude}
`
	b, err := UnmarshalYAML([]byte(src))
	if err != nil {
		t.Fatalf("legacy scalar must still load: %v", err)
	}
	if err := Validate(b); err != nil {
		t.Fatalf("migrated legacy board must validate: %v", err)
	}
	if b.Components[0].Assembly != nil {
		t.Fatalf("a component with no assembly key must stay nil, got %+v", b.Components[0].Assembly)
	}
	if !b.Components[0].Assembly.Populated() {
		t.Fatalf("a component with no assembly block is populated")
	}
	fid := b.Components[1].Assembly
	if fid == nil || fid.Populate == nil || *fid.Populate {
		t.Fatalf("scalar exclude must migrate to populate:false, got %+v", fid)
	}
	if fid.Populated() {
		t.Fatalf("migrated furniture must not report as populated")
	}

	// The migration is what gets written back: re-emitted structured, and the
	// structured form loads to the same state.
	y, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("MarshalYAML: %v", err)
	}
	if strings.Contains(string(y), "assembly: exclude") {
		t.Fatalf("migrated board re-emitted the legacy scalar:\n%s", string(y))
	}
	back, err := UnmarshalYAML(y)
	if err != nil {
		t.Fatalf("re-load of the migrated document: %v", err)
	}
	if back.Components[1].Assembly.Populated() {
		t.Fatalf("re-load lost the migrated populate:false")
	}

	// The JSON/IPC boundary migrates the same scalar the same way.
	var c Component
	if err := json.Unmarshal([]byte(`{"ref":"FID1","assembly":"exclude"}`), &c); err != nil {
		t.Fatalf("JSON legacy scalar: %v", err)
	}
	if c.Assembly.Populated() {
		t.Fatalf("JSON scalar exclude did not migrate: %+v", c.Assembly)
	}

	// A typo is a refusal on both codecs, never "not excluded".
	if _, err := UnmarshalYAML([]byte(strings.Replace(src, "exclude", "exlcude", 1))); err == nil ||
		!strings.Contains(err.Error(), "invalid_component_assembly") {
		t.Fatalf("YAML typo token must refuse with invalid_component_assembly, got %v", err)
	}
	var typo Component
	if err := json.Unmarshal([]byte(`{"ref":"FID1","assembly":"exlcude"}`), &typo); err == nil ||
		!strings.Contains(err.Error(), "invalid_component_assembly") {
		t.Fatalf("JSON typo token must refuse with invalid_component_assembly, got %v", err)
	}
}

// TestZoneMinimaRoundTripAndUnsetDistinction pins what the *float64 fields buy
// over plain float64s: an AUTHORED 0 island area survives both codecs as a
// stated policy, while an unset key stays absent so the compiler's derived
// default still applies. The two states are separately meaningful, and 0 is the
// only value where they would collapse.
func TestZoneMinimaRoundTripAndUnsetDistinction(t *testing.T) {
	thickness, island := 0.2, 0.0
	b := &Board{
		Version: 1, Name: "minima", WidthMM: 20, HeightMM: 15,
		DesignRules: DesignRules{
			ZoneMinThicknessMM:   &thickness,
			ZoneMinIslandAreaMM2: &island,
		},
	}
	if err := Validate(b); err != nil {
		t.Fatalf("a positive thickness with a zero island area must validate: %v", err)
	}

	y, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("MarshalYAML: %v", err)
	}
	if !strings.Contains(string(y), "zone_min_island_area_mm2: 0") {
		t.Fatalf("YAML dropped an authored zero island area:\n%s", string(y))
	}
	back, err := UnmarshalYAML(y)
	if err != nil {
		t.Fatalf("UnmarshalYAML: %v", err)
	}
	if back.DesignRules.ZoneMinIslandAreaMM2 == nil ||
		*back.DesignRules.ZoneMinIslandAreaMM2 != 0 {
		t.Fatalf("YAML round trip lost the authored zero: %+v", back.DesignRules)
	}
	if back.DesignRules.ZoneMinThicknessMM == nil ||
		*back.DesignRules.ZoneMinThicknessMM != 0.2 {
		t.Fatalf("YAML round trip lost the thickness: %+v", back.DesignRules)
	}

	// The IPC boundary keeps both.
	j, err := json.Marshal(b.DesignRules)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	var d DesignRules
	if err := json.Unmarshal(j, &d); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if d.ZoneMinIslandAreaMM2 == nil || *d.ZoneMinIslandAreaMM2 != 0 ||
		d.ZoneMinThicknessMM == nil || *d.ZoneMinThicknessMM != 0.2 {
		t.Fatalf("JSON dropped a zone minimum: %s", string(j))
	}

	// UNSET is a third state, distinct from either number: the key is absent
	// from the source and the pointer comes back nil, so the compiler derives
	// the default rather than reading an accidental 0.
	bare, err := UnmarshalYAML([]byte("version: 1\nname: bare\nwidth_mm: 20\nheight_mm: 15\n"))
	if err != nil {
		t.Fatalf("UnmarshalYAML bare: %v", err)
	}
	if bare.DesignRules.ZoneMinThicknessMM != nil ||
		bare.DesignRules.ZoneMinIslandAreaMM2 != nil {
		t.Fatalf("absent keys must stay unset: %+v", bare.DesignRules)
	}
	if err := Validate(bare); err != nil {
		t.Fatalf("a board stating no minima must validate: %v", err)
	}
	out, err := MarshalYAML(bare)
	if err != nil {
		t.Fatalf("MarshalYAML bare: %v", err)
	}
	if strings.Contains(string(out), "zone_min_") {
		t.Fatalf("unset minima must not be synthesized into source:\n%s", string(out))
	}
}

// A zone-fill minimum arriving over the JSON channel as a string or a bool is
// refused with the shared code, the same answer the YAML path gives; a number,
// an authored zero and a null all pass the probe (null is "unset").
func TestProbeJSONDesignRulesSharedCode(t *testing.T) {
	refused := []string{
		`{"design_rules":{"zone_min_thickness_mm":"wide"}}`,
		`{"design_rules":{"zone_min_island_area_mm2":true}}`,
		`{"design_rules":{"zone_min_thickness_mm":"0.15"}}`,
		`{"design_rules":{"zone_min_thickness_mm":[1]}}`,
	}
	for _, src := range refused {
		err := ProbeJSONBoard(json.RawMessage(src))
		if err == nil || !strings.HasPrefix(err.Error(), "invalid_design_rule") {
			t.Fatalf("%s: want invalid_design_rule, got %v", src, err)
		}
	}
	accepted := []string{
		`{"design_rules":{"zone_min_thickness_mm":0.15,"zone_min_island_area_mm2":0}}`,
		`{"design_rules":{"zone_min_thickness_mm":null}}`,
		`{"design_rules":null}`,
		`{}`,
	}
	for _, src := range accepted {
		if err := ProbeJSONBoard(json.RawMessage(src)); err != nil {
			t.Fatalf("%s: want nil, got %v", src, err)
		}
	}
}
