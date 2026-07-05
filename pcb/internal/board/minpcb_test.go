package board

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return data
}

// The canonical legacy fixture must import with ZERO warnings and no data loss.
func TestImportLegacyBoardZeroWarnings(t *testing.T) {
	b, warnings, err := ImportMinpcb(readFixture(t, "legacy_board.minpcb"))
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected zero warnings, got %d: %v", len(warnings), warnings)
	}

	if b.Name != "Blinky" {
		t.Errorf("name: want Blinky, got %q", b.Name)
	}
	if b.WidthMM != 40 || b.HeightMM != 30 {
		t.Errorf("board size: want 40x30, got %gx%g", b.WidthMM, b.HeightMM)
	}
	if b.GridMM != 2.54 {
		t.Errorf("grid: want 2.54, got %g", b.GridMM)
	}

	// components sorted by id: R1, U1
	if len(b.Components) != 2 {
		t.Fatalf("components: want 2, got %d", len(b.Components))
	}
	r1 := b.Components[0]
	if r1.Ref != "R1" {
		t.Errorf("component[0].ref: want R1, got %q", r1.Ref)
	}
	if r1.Value != "330" {
		t.Errorf("R1.value: want 330 (from properties.value), got %q", r1.Value)
	}
	if r1.XMM != 10 || r1.YMM != 5 {
		t.Errorf("R1 position: want (10,5), got (%g,%g)", r1.XMM, r1.YMM)
	}
	if len(r1.Pins) != 2 || r1.Pins[0].Number != "1" {
		t.Errorf("R1 pins malformed: %#v", r1.Pins)
	}
	// render-only legacy fields carried in Extra, not dropped, not warned.
	if _, ok := r1.Extra["pads"]; !ok {
		t.Errorf("R1.pads not preserved in Extra")
	}
	if _, ok := r1.Extra["color"]; !ok {
		t.Errorf("R1.color not preserved in Extra")
	}
	if b.Components[1].RotationDeg != 90 {
		t.Errorf("U1 rotation: want 90, got %g", b.Components[1].RotationDeg)
	}

	// nets sorted: GND, VCC — pins flattened to "Ref.Pad".
	if len(b.Nets) != 2 {
		t.Fatalf("nets: want 2, got %d", len(b.Nets))
	}
	if b.Nets[0].Name != "GND" || b.Nets[1].Name != "VCC" {
		t.Errorf("nets not sorted: %q, %q", b.Nets[0].Name, b.Nets[1].Name)
	}
	vcc := b.Nets[1]
	if len(vcc.Pins) != 2 || vcc.Pins[0] != "U1.8" || vcc.Pins[1] != "R1.1" {
		t.Errorf("VCC pins: want [U1.8 R1.1], got %v", vcc.Pins)
	}
	if vcc.Extra["is_power_net"] != true {
		t.Errorf("VCC is_power_net not preserved: %#v", vcc.Extra)
	}

	// traces
	if len(b.Traces) != 1 {
		t.Fatalf("traces: want 1, got %d", len(b.Traces))
	}
	tr := b.Traces[0]
	if tr.Net != "VCC" || tr.WidthMM != 0.25 || len(tr.Points) != 3 {
		t.Errorf("trace malformed: %#v", tr)
	}

	// vias
	if len(b.Vias) != 1 {
		t.Fatalf("vias: want 1, got %d", len(b.Vias))
	}
	if b.Vias[0].XMM != 15 || b.Vias[0].DrillMM != 0.4 || b.Vias[0].DiameterMM != 0.8 {
		t.Errorf("via malformed: %#v", b.Vias[0])
	}

	// opaque passthrough intact
	if len(b.Annotations) != 1 || b.Annotations[0]["id"] != "ann_000042" {
		t.Errorf("annotation passthrough lost: %#v", b.Annotations)
	}
	if b.Annotations[0]["text"] != "route this first" {
		t.Errorf("annotation content lost: %#v", b.Annotations[0])
	}
	if len(b.RouteHints) != 1 || b.RouteHints[0]["id"] != "rhint_000007" {
		t.Errorf("route_hint passthrough lost: %#v", b.RouteHints)
	}
}

// After import, the board must survive serialization to YAML and back.
func TestImportedBoardSurvivesYAMLRoundTrip(t *testing.T) {
	b, _, err := ImportMinpcb(readFixture(t, "legacy_board.minpcb"))
	if err != nil {
		t.Fatal(err)
	}
	yml, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	b2, err := UnmarshalYAML(yml)
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	// Structural preservation (numeric JSON→YAML type identity is not asserted;
	// see docs/board-yaml.md). Key content must persist.
	if b2.Name != b.Name || len(b2.Components) != len(b.Components) ||
		len(b2.Nets) != len(b.Nets) || len(b2.Traces) != len(b.Traces) ||
		len(b2.Annotations) != len(b.Annotations) || len(b2.RouteHints) != len(b.RouteHints) {
		t.Fatalf("structure changed across YAML round-trip:\n pre=%#v\n post=%#v", b, b2)
	}
	if b2.Annotations[0]["id"] != "ann_000042" {
		t.Errorf("annotation id lost across YAML round-trip")
	}
}

// The warnings mechanism must flag genuinely unrecognized fields (while still
// preserving them losslessly in Extra).
func TestImportWarnsOnUnknownFields(t *testing.T) {
	b, warnings, err := ImportMinpcb(readFixture(t, "legacy_board_unknown.minpcb"))
	if err != nil {
		t.Fatal(err)
	}
	if len(warnings) == 0 {
		t.Fatal("expected warnings for unknown fields, got none")
	}
	// unknown top-level key preserved
	if _, ok := b.Extra["future_feature_flags"]; !ok {
		t.Errorf("unknown top-level key not preserved in Board.Extra: %#v", b.Extra)
	}
	// unknown component field preserved
	if len(b.Components) != 1 {
		t.Fatalf("components: want 1, got %d", len(b.Components))
	}
	if _, ok := b.Components[0].Extra["solder_paste_ratio"]; !ok {
		t.Errorf("unknown component field not preserved in Extra: %#v", b.Components[0].Extra)
	}
	// unknown net field preserved (and known metadata still mapped)
	if len(b.Nets) != 1 {
		t.Fatalf("nets: want 1, got %d", len(b.Nets))
	}
	if _, ok := b.Nets[0].Extra["impedance_target_ohm"]; !ok {
		t.Errorf("unknown net field not preserved in Extra: %#v", b.Nets[0].Extra)
	}
	if b.Nets[0].Extra["is_power_net"] != true {
		t.Errorf("known net metadata (is_power_net) lost: %#v", b.Nets[0].Extra)
	}
	if len(b.Nets[0].Pins) != 1 || b.Nets[0].Pins[0] != "C1.1" {
		t.Errorf("net pins not mapped: %#v", b.Nets[0].Pins)
	}
	// unknown trace field preserved (and known fields still mapped)
	if len(b.Traces) != 1 {
		t.Fatalf("traces: want 1, got %d", len(b.Traces))
	}
	if _, ok := b.Traces[0].Extra["teardrop_style"]; !ok {
		t.Errorf("unknown trace field not preserved in Extra: %#v", b.Traces[0].Extra)
	}
	if b.Traces[0].Net != "VCC" || b.Traces[0].WidthMM != 0.25 || len(b.Traces[0].Points) != 2 {
		t.Errorf("trace known fields regressed: %#v", b.Traces[0])
	}

	var sawRoot, sawComp, sawNet, sawTrace bool
	for _, w := range warnings {
		if strings.Contains(w, "future_feature_flags") {
			sawRoot = true
		}
		if strings.Contains(w, "solder_paste_ratio") {
			sawComp = true
		}
		if strings.Contains(w, "impedance_target_ohm") {
			sawNet = true
		}
		if strings.Contains(w, "teardrop_style") {
			sawTrace = true
		}
	}
	if !sawRoot {
		t.Errorf("no warning for unknown top-level field; warnings=%v", warnings)
	}
	if !sawComp {
		t.Errorf("no warning for unknown component field; warnings=%v", warnings)
	}
	if !sawNet {
		t.Errorf("no warning for unknown net field; warnings=%v", warnings)
	}
	if !sawTrace {
		t.Errorf("no warning for unknown trace field; warnings=%v", warnings)
	}
}

func TestImportMalformedJSONReturnsError(t *testing.T) {
	if _, _, err := ImportMinpcb([]byte("{ not valid json")); err == nil {
		t.Error("expected error for malformed json, got nil")
	}
}
