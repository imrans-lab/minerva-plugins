package board

import (
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// The positive schema, walked end to end: ONE mistyped key on every entity
// kind the walk covers is refused naming that entity and that key, on the YAML
// boundary and on the JSON boundary alike, and the same document with the
// stray keys removed round-trips byte-stable. The byte equality is what makes
// the refusal claim honest — a walk that refused everything would pass the
// first half.
const schemaBoardYAML = `version: 2
id: board:0123456789abcdef0123456789abcdef
name: schema
width_mm: 40
height_mm: 30
layers:
    - top
    - bottom
design_rules:
    clearance_mm: 0.2
    rule_profile: jlcpcb-2layer
library_lock:
    R_0603:
        sha256: abc
components:
    - ref: R1
      footprint: R_0603
      x_mm: 1
      y_mm: 1
      rotation_deg: 0
      pins:
        - number: "1"
          x_mm: 0
          y_mm: 0
          override:
            drill_mm: 0.6
          roles:
            - strapping
      refdes_placement:
        y_mm: -3
      group_id: g1
nets:
    - name: GND
      pins:
        - R1.1
traces:
    - id: trace:0123456789abcdef0123456789abcdef
      net: GND
      points:
        - x_mm: 0
          y_mm: 0
        - x_mm: 1
          y_mm: 1
vias:
    - id: via:0123456789abcdef0123456789abcdef
      x_mm: 2
      y_mm: 2
zones:
    - id: zone:0123456789abcdef0123456789abcdef
      net: GND
      layer: top
      outline:
        - x_mm: 0
          y_mm: 0
        - x_mm: 5
          y_mm: 0
        - x_mm: 5
          y_mm: 5
cutouts:
    - id: cutout:0123456789abcdef0123456789abcdef
      outline:
        - x_mm: 10
          y_mm: 10
        - x_mm: 12
          y_mm: 10
        - x_mm: 12
          y_mm: 12
mounting_holes:
    - id: hole:0123456789abcdef0123456789abcdef
      x_mm: 3
      y_mm: 3
      diameter_mm: 3
board_graphics:
    - id: graphic:0123456789abcdef0123456789abcdef
      layer: F.SilkS
      kind: text
      text: hello
`

// strayKeys lists, per entity, a fixture edit that plants one unknown key and
// the label + key the refusal must name.
var strayKeys = []struct {
	old, new, label, key string
}{
	{"height_mm: 30\n", "height_mm: 30\ncolour: red\n", "board", "colour"},
	// The drawing pitch used to be a board field. It is session state now, and a
	// board that still carries one is refused rather than quietly tolerated.
	{"height_mm: 30\n", "height_mm: 30\ngrid_mm: 2.54\n", "board", "grid_mm"},
	{"    clearance_mm: 0.2\n", "    clearance_mm: 0.2\n    clearence_mm: 0.3\n", "board.design_rules", "clearence_mm"},
	{"        sha256: abc\n", "        sha256: abc\n        shaa: def\n", "board.library_lock[R_0603]", "shaa"},
	{"      rotation_deg: 0\n", "      rotation_deg: 0\n      properties: {}\n", "board.components[0] (R1)", "properties"},
	{"      refdes_placement:\n        y_mm: -3\n", "      refdes_placement:\n        y_mm: -3\n        hiddden: true\n", "board.components[0] (R1).refdes_placement", "hiddden"},
	{"          y_mm: 0\n          override:\n", "          y_mm: 0\n          signal_class: analog\n          override:\n", "board.components[0] (R1).pins[0] (1)", "signal_class"},
	{"            drill_mm: 0.6\n", "            drill_mm: 0.6\n            finish: ENIG\n", "board.components[0] (R1).pins[0] (1).override", "finish"},
	{"        - R1.1\n", "        - R1.1\n      is_power_net: true\n", "board.nets[0] (GND)", "is_power_net"},
	{"      net: GND\n      points:\n", "      net: GND\n      locked: false\n      points:\n", "board.traces[0] (trace:0123456789abcdef0123456789abcdef)", "locked"},
	{"      x_mm: 2\n      y_mm: 2\n", "      x_mm: 2\n      y_mm: 2\n      layers: [top, bottom]\n", "board.vias[0] (via:0123456789abcdef0123456789abcdef)", "layers"},
	{"      diameter_mm: 3\n", "      diameter_mm: 3\n      colour: red\n", "board.mounting_holes[0] (hole:0123456789abcdef0123456789abcdef)", "colour"},
	{"      net: GND\n      layer: top\n", "      net: GND\n      layer: top\n      priority: 1\n", "board.zones[0] (zone:0123456789abcdef0123456789abcdef)", "priority"},
	{"        - x_mm: 12\n          y_mm: 12\n", "        - x_mm: 12\n          y_mm: 12\n      depth_mm: 1\n", "board.cutouts[0] (cutout:0123456789abcdef0123456789abcdef)", "depth_mm"},
	{"      text: hello\n", "      text: hello\n      note: later\n", "board.board_graphics[0] (graphic:0123456789abcdef0123456789abcdef)", "note"},
}

func TestEveryEntityRefusesAnUnknownKeyByName(t *testing.T) {
	for _, tc := range strayKeys {
		if strings.Count(schemaBoardYAML, tc.old) != 1 {
			t.Fatalf("fixture anchor %q is not unique", tc.old)
		}
		src := strings.Replace(schemaBoardYAML, tc.old, tc.new, 1)
		want := fmt.Sprintf("%s: unknown key %q", tc.label, tc.key)

		_, err := UnmarshalYAML([]byte(src))
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("YAML: stray %q on %s: got %v, want a refusal containing %q", tc.key, tc.label, err, want)
		}

		// The JSON boundary sees the same document as the panel would send it.
		var loose map[string]interface{}
		if err := yaml.Unmarshal([]byte(src), &loose); err != nil {
			t.Fatalf("loose decode: %v", err)
		}
		raw, err := json.Marshal(loose)
		if err != nil {
			t.Fatalf("marshal loose: %v", err)
		}
		if err := ProbeJSONBoard(raw); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("JSON: stray %q on %s: got %v, want a refusal containing %q", tc.key, tc.label, err, want)
		}
	}

	// The clean document is accepted on both boundaries and round-trips
	// byte-stable through the YAML codec.
	b, err := UnmarshalYAML([]byte(schemaBoardYAML))
	if err != nil {
		t.Fatalf("the clean fixture must load: %v", err)
	}
	if err := Validate(b); err != nil {
		t.Fatalf("the clean fixture must validate: %v", err)
	}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(out) != schemaBoardYAML {
		t.Fatalf("the clean fixture did not round-trip byte-stable:\n--- got ---\n%s--- want ---\n%s", out, schemaBoardYAML)
	}
	if b.DesignRules.RuleProfile != "jlcpcb-2layer" || b.Components[0].GroupID != "g1" ||
		len(b.Components[0].Pins[0].Roles) != 1 ||
		b.Components[0].RefdesPlacement == nil || b.Components[0].RefdesPlacement.YMM == nil {
		t.Fatalf("a typed key did not reach its field: %+v", b.Components[0])
	}
	raw, _ := json.Marshal(b)
	if err := ProbeJSONBoard(raw); err != nil {
		t.Fatalf("the codec's own JSON encoding must pass the JSON walk: %v", err)
	}
}

// An authored empty `pads: []` is a real answer (zero lands, board-owned
// geometry) and must survive a round trip as a present key, while an absent
// key stays absent — the presence IS the FULL/PARTIAL declaration.
func TestEmptyPadsListRoundTripsAsPresent(t *testing.T) {
	src := strings.Replace(schemaBoardYAML, "          roles:\n            - strapping\n",
		"          roles:\n            - strapping\n      pads: []\n", 1)
	b, err := UnmarshalYAML([]byte(src))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if b.Components[0].Pads == nil || len(*b.Components[0].Pads) != 0 {
		t.Fatalf("pads: [] did not decode as an authored empty list: %#v", b.Components[0].Pads)
	}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(out) != src {
		t.Fatalf("pads: [] did not round-trip:\n%s", out)
	}
}

// The YAML walk reads yaml tags and the JSON walk reads json tags; the two
// boundaries agree only while every struct tags each field identically.
func TestYAMLAndJSONTagsAgreeOnEveryWalkedStruct(t *testing.T) {
	seen := map[reflect.Type]bool{}
	var check func(t reflect.Type)
	check = func(st reflect.Type) {
		if seen[st] {
			return
		}
		seen[st] = true
		y, j := fieldsByTag(st, "yaml"), fieldsByTag(st, "json")
		if !reflect.DeepEqual(keysOf(y), keysOf(j)) {
			t.Errorf("%s: yaml keys %v != json keys %v", st, keysOf(y), keysOf(j))
		}
		for _, f := range y {
			if target := targetOf(f.Type); !target.opaque {
				check(target.elem)
			}
		}
	}
	check(reflect.TypeOf(Board{}))
	if len(seen) < 12 {
		t.Fatalf("the walk covered only %d struct types; the schema has more entities than that", len(seen))
	}
}

func keysOf(m map[string]reflect.StructField) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// A map whose values are POINTERS to structs is walked like a map of structs:
// the pointer is a spelling, not a boundary, and a field that hid behind one
// would be the untyped bag this walk exists to remove.
func TestMapOfPointerStructsIsWalked(t *testing.T) {
	type inner struct {
		Real int `json:"real" yaml:"real"`
	}
	type outer struct {
		Entries map[string]*inner `json:"entries" yaml:"entries"`
	}
	var node yaml.Node
	if err := yaml.Unmarshal([]byte("entries:\n  k:\n    real: 1\n    bogus: 2\n"), &node); err != nil {
		t.Fatalf("yaml: %v", err)
	}
	want := `entries[k]: unknown key "bogus"`
	err := refuseUnknownYAML(node.Content[0], reflect.TypeOf(outer{}), "outer")
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("YAML walk did not descend through the pointer: %v", err)
	}
	err = refuseUnknownJSON(json.RawMessage(`{"entries":{"k":{"real":1,"bogus":2}}}`), reflect.TypeOf(outer{}), "outer")
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("JSON walk did not descend through the pointer: %v", err)
	}
}
