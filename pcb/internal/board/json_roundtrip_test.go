package board

import (
	"bytes"
	"encoding/json"
	"reflect"
	"testing"
)

// jsonRoundTrip marshals v, unmarshals into a fresh value of the same type, and
// returns the re-decoded value plus the marshaled bytes.
func jsonRoundTrip[T any](t *testing.T, v T) (T, []byte) {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var back T
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("unmarshal: %v (json=%s)", err, data)
	}
	return back, data
}

// A Board with Extra keys at the root AND nested (Component → Pin → PinOverride,
// plus Trace/Via/Hole/Net/DesignRules) must preserve every Extra key across a
// json.Marshal → json.Unmarshal cycle — the JSON boundary the IPC path uses.
func TestJSONRoundTripPreservesExtraNested(t *testing.T) {
	b := Board{
		Version:  2,
		ID:       "board:" + repeat32,
		Name:     "RT",
		WidthMM:  40,
		HeightMM: 30,
		DesignRules: DesignRules{
			ClearanceMM: 0.2,
			Extra:       map[string]interface{}{"copper_weight_oz": 2.0},
		},
		Components: []Component{{
			Ref:       "U1",
			Footprint: "IC_DIP",
			XMM:       1, YMM: 2,
			Extra: map[string]interface{}{"mpn": "ATMEGA328P", "dnp": true},
			Pins: []Pin{{
				Number: "1", XMM: 0, YMM: 0,
				Override: &PinOverride{
					Extra: map[string]interface{}{"finish": "ENIG"},
				},
				Extra: map[string]interface{}{"signal_class": "analog"},
			}},
		}},
		Nets: []Net{{
			Name: "GND", Pins: []string{"U1.1"},
			Extra: map[string]interface{}{"net_class": "power"},
		}},
		Traces: []Trace{{
			ID: "trace:" + repeat32, Net: "GND",
			Points: []Point{{XMM: 0, YMM: 0}, {XMM: 1, YMM: 1}},
			Extra:  map[string]interface{}{"impedance_ohm": 50.0},
		}},
		Vias: []Via{{
			ID: "via:" + repeat32, XMM: 5, YMM: 5,
			Extra: map[string]interface{}{"tented": true},
		}},
		MountingHoles: []Hole{{
			ID: "hole:" + repeat32, XMM: 9, YMM: 9, DiameterMM: 3.2,
			Plated: true, AnnulusMM: 3.6,
			Extra: map[string]interface{}{"standoff": "M3"},
		}},
		Extra: map[string]interface{}{"source_tool": "pcb-architect", "revision": 7.0},
	}

	back, _ := jsonRoundTrip(t, b)

	// Root extras survived.
	if back.Extra["source_tool"] != "pcb-architect" || back.Extra["revision"] != 7.0 {
		t.Fatalf("root Extra lost: %#v", back.Extra)
	}
	// Nested extras survived at every depth.
	if back.DesignRules.Extra["copper_weight_oz"] != 2.0 {
		t.Fatalf("DesignRules Extra lost: %#v", back.DesignRules.Extra)
	}
	comp := back.Components[0]
	if comp.Extra["mpn"] != "ATMEGA328P" || comp.Extra["dnp"] != true {
		t.Fatalf("Component Extra lost: %#v", comp.Extra)
	}
	pin := comp.Pins[0]
	if pin.Extra["signal_class"] != "analog" {
		t.Fatalf("Pin Extra lost: %#v", pin.Extra)
	}
	if pin.Override == nil || pin.Override.Extra["finish"] != "ENIG" {
		t.Fatalf("PinOverride Extra lost: %#v", pin.Override)
	}
	if back.Nets[0].Extra["net_class"] != "power" {
		t.Fatalf("Net Extra lost: %#v", back.Nets[0].Extra)
	}
	if back.Traces[0].Extra["impedance_ohm"] != 50.0 {
		t.Fatalf("Trace Extra lost: %#v", back.Traces[0].Extra)
	}
	if back.Vias[0].Extra["tented"] != true {
		t.Fatalf("Via Extra lost: %#v", back.Vias[0].Extra)
	}
	if back.MountingHoles[0].Extra["standoff"] != "M3" {
		t.Fatalf("Hole Extra lost: %#v", back.MountingHoles[0].Extra)
	}
	// The first-class authored annulus (finding 019f8dbb7104) round-trips as a
	// MODELED key, not via Extra (it must not leak into Extra on the way back).
	if back.MountingHoles[0].AnnulusMM != 3.6 {
		t.Fatalf("Hole AnnulusMM lost: %v", back.MountingHoles[0].AnnulusMM)
	}
	if _, leaked := back.MountingHoles[0].Extra["annulus_mm"]; leaked {
		t.Fatalf("annulus_mm leaked into Extra (should be a modeled key)")
	}

	// Full semantic round-trip (all modeled fields + extras) is identical.
	if !reflect.DeepEqual(b, back) {
		t.Fatalf("board not equal after JSON round trip\nwant %#v\ngot  %#v", b, back)
	}
}

// An Extra key that collides with a modeled json tag must NOT corrupt the
// modeled field: the modeled value wins, the Extra copy is dropped, and the key
// appears exactly once in the output.
func TestJSONMarshalCollisionModeledFieldWins(t *testing.T) {
	c := Component{
		Ref:       "R1",
		Footprint: "0402",
		XMM:       3, YMM: 4,
		// "ref" and "footprint" are modeled json tags — these Extra copies must
		// be dropped, never clobber the modeled values.
		Extra: map[string]interface{}{"ref": "HACKED", "footprint": "EVIL", "custom": "ok"},
	}
	data, err := json.Marshal(c)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// The key must appear exactly once (no duplicate emission).
	if n := bytes.Count(data, []byte(`"ref"`)); n != 1 {
		t.Fatalf(`"ref" appears %d times, want 1: %s`, n, data)
	}
	var back Component
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if back.Ref != "R1" || back.Footprint != "0402" {
		t.Fatalf("modeled field clobbered by Extra: ref=%q footprint=%q", back.Ref, back.Footprint)
	}
	// A colliding key must NOT leak back into Extra (it is a modeled tag).
	if _, present := back.Extra["ref"]; present {
		t.Fatalf("modeled tag leaked into Extra: %#v", back.Extra)
	}
	if back.Extra["custom"] != "ok" {
		t.Fatalf("non-colliding Extra lost: %#v", back.Extra)
	}
}

// Output must be deterministic: marshaling the same value twice yields
// byte-identical JSON (relied on for the pcb.serialize deterministic payload).
func TestJSONMarshalDeterministic(t *testing.T) {
	b := Board{
		Version: 2, ID: "board:" + repeat32, Name: "Det",
		WidthMM: 10, HeightMM: 10,
		Components: []Component{{Ref: "U1", Footprint: "F", Extra: map[string]interface{}{
			"z_last": 1.0, "a_first": 2.0, "m_mid": 3.0, "q": 4.0,
		}}},
		Nets: []Net{},
		Extra: map[string]interface{}{"zeta": 1.0, "alpha": 2.0, "mu": 3.0,
			// A nested-map Extra value — encoding/json sorts nested map keys too,
			// so a deeply-nested unknown object must ALSO be byte-stable (Fable
			// W4 note 3: the merge marshals a map[string]json.RawMessage, and the
			// RawMessage values here are themselves sorted-key objects).
			"nested": map[string]interface{}{"y": 1.0, "b": 2.0, "n": 3.0, "a": 4.0}},
	}
	first, err := json.Marshal(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for i := 0; i < 20; i++ {
		next, err := json.Marshal(b)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		if !bytes.Equal(first, next) {
			t.Fatalf("non-deterministic output:\n#1  %s\n#%d %s", first, i+2, next)
		}
	}
}

// An extra-free struct must decode to a nil Extra (not an empty map), so a board
// that carried no unknown fields stays byte-identical rather than gaining {}.
func TestJSONUnmarshalNilExtraWhenAbsent(t *testing.T) {
	back, _ := jsonRoundTrip(t, Net{Name: "N", Pins: []string{"U1.1"}})
	if back.Extra != nil {
		t.Fatalf("Extra should be nil when no unknown keys, got %#v", back.Extra)
	}
}

const repeat32 = "0123456789abcdef0123456789abcdef"
