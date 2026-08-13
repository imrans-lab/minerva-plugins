package board

import (
	"bytes"
	"reflect"
	"strings"
	"testing"
)

// DEFERRED TEST Z1 (docket 019fb06e0c51, authored at epoch GA-5): a Zone
// round-trips through canonical YAML without loss. The general round-trip
// tests predate the Zone struct and carry no zone at all, so a serializer
// that dropped or defaulted any zone field would pass them.
//
// The fixture is the item's named discriminator: TWO zones differing in
// EVERY field — a field the codec cross-wires between them (or collapses to
// a default) cannot survive the deep-equal.
const zoneYAML = `version: 1
name: ZoneRT
width_mm: 30
height_mm: 20
layers: [top, bottom]
components: []
nets:
  - name: GND
    pins: []
  - name: VCC
    pins: []
zones:
  - id: "zone:00000000000000000000000000000001"
    net: GND
    layer: top
    clearance_mm: 0.25
    outline:
      - {x_mm: 2, y_mm: 2}
      - {x_mm: 12, y_mm: 2}
      - {x_mm: 12, y_mm: 9}
  - id: "zone:00000000000000000000000000000002"
    kind: keepout
    layer: bottom
    outline:
      - {x_mm: 14, y_mm: 4}
      - {x_mm: 26, y_mm: 4}
      - {x_mm: 26, y_mm: 16}
      - {x_mm: 14, y_mm: 16}
`

func TestZoneRoundTripsThroughCanonicalYAML(t *testing.T) {
	b1, err := UnmarshalYAML([]byte(zoneYAML))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(b1.Zones) != 2 {
		t.Fatalf("fixture must parse both zones, got %d", len(b1.Zones))
	}

	// Field-by-field on the parse, so a round-trip equality of two WRONG
	// values cannot pass.
	pour, keep := b1.Zones[0], b1.Zones[1]
	if pour.ID != "zone:00000000000000000000000000000001" ||
		pour.Kind != "" || pour.Net != "GND" || pour.Layer != "top" ||
		pour.ClearanceMM != 0.25 || len(pour.Outline) != 3 {
		t.Fatalf("pour parsed wrong: %#v", pour)
	}
	if keep.Kind != "keepout" || keep.Net != "" || keep.Layer != "bottom" ||
		keep.ClearanceMM != 0 || len(keep.Outline) != 4 {
		t.Fatalf("keepout parsed wrong: %#v", keep)
	}
	if pour.Outline[2] != (Point{XMM: 12, YMM: 9}) {
		t.Fatalf("outline point lost: %#v", pour.Outline)
	}

	out1, err := MarshalYAML(b1)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	b2, err := UnmarshalYAML(out1)
	if err != nil {
		t.Fatalf("unmarshal round-trip: %v", err)
	}
	if !reflect.DeepEqual(b1, b2) {
		t.Fatalf("zone round-trip not deep-equal.\n b1=%#v\n b2=%#v",
			b1.Zones, b2.Zones)
	}

	// The keepout's ABSENT net must stay absent (omitempty is the owner
	// ruling: `net: ""` reads like a net named empty-string).
	if strings.Contains(string(out1), `net: ""`) {
		t.Fatalf("keepout's absent net serialized as an empty string:\n%s", out1)
	}

	// Byte determinism WITH zones present — the general determinism test's
	// fixture carries none.
	out2, err := MarshalYAML(b2)
	if err != nil {
		t.Fatalf("marshal again: %v", err)
	}
	if !bytes.Equal(out1, out2) {
		t.Fatalf("marshal not byte-deterministic with zones present")
	}
}
