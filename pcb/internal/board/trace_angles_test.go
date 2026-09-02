package board

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// design_rules.allowed_trace_angles_deg is a TYPED field on both codecs, and
// the three states it can be in are three DIFFERENT boards.
//
// THE ORACLE IS THE AUTHORED SOURCE, not the struct: the four directions a
// board declares must come back as those four numbers, survive a second trip
// byte-for-byte, and reach the JSON boundary the plugin IPC uses. The other two
// states are the same rule read from the other side — an ABSENT key is free
// routing and must stay absent, and an authored EMPTY LIST is malformed and
// must stay an empty list, because the codec quietly turning `[]` into absence
// is exactly the invisible fail-open (a board asks for a direction constraint
// and silently gets none) that the compiler's bad_trace_angles refusal exists
// to prevent.
func TestAllowedTraceAnglesRoundTripsTypedAbsentAndEmpty(t *testing.T) {
	const src = `version: 2
name: angles
width_mm: 40
height_mm: 30
layers: [top, bottom]
design_rules:
  clearance_mm: 0.2
  allowed_trace_angles_deg: [0, 45, 90, 135]
components: []
`
	const anglesLine = "  allowed_trace_angles_deg: [0, 45, 90, 135]\n"
	want := []float64{0, 45, 90, 135}

	b, err := UnmarshalYAML([]byte(src))
	if err != nil {
		t.Fatalf("unmarshal yaml: %v", err)
	}
	if b.DesignRules.AllowedTraceAnglesDeg == nil {
		t.Fatal("the declared angles decoded as absent")
	}
	if !reflect.DeepEqual(*b.DesignRules.AllowedTraceAnglesDeg, want) {
		t.Fatalf("typed angles = %v, want %v", *b.DesignRules.AllowedTraceAnglesDeg, want)
	}
	first, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal yaml: %v", err)
	}
	if !bytes.Contains(first, []byte("allowed_trace_angles_deg:")) {
		t.Fatalf("marshalled YAML dropped the key:\n%s", first)
	}
	again, err := UnmarshalYAML(first)
	if err != nil {
		t.Fatalf("re-unmarshal yaml: %v", err)
	}
	if again.DesignRules.AllowedTraceAnglesDeg == nil ||
		!reflect.DeepEqual(*again.DesignRules.AllowedTraceAnglesDeg, want) {
		t.Fatalf("angles after two trips = %v, want %v",
			again.DesignRules.AllowedTraceAnglesDeg, want)
	}
	second, err := MarshalYAML(again)
	if err != nil {
		t.Fatalf("re-marshal yaml: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Fatalf("the second YAML trip is not byte-equal:\nfirst:\n%s\nsecond:\n%s",
			first, second)
	}

	// The JSON codec (the plugin IPC boundary) carries the same key.
	raw, err := json.Marshal(b)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}
	if !bytes.Contains(raw, []byte(`"allowed_trace_angles_deg":[0,45,90,135]`)) {
		t.Fatalf("JSON dropped or reshaped the key: %s", raw)
	}
	var viaJSON Board
	if err := json.Unmarshal(raw, &viaJSON); err != nil {
		t.Fatalf("unmarshal json: %v", err)
	}
	if viaJSON.DesignRules.AllowedTraceAnglesDeg == nil ||
		!reflect.DeepEqual(*viaJSON.DesignRules.AllowedTraceAnglesDeg, want) {
		t.Fatalf("angles after a JSON trip = %v, want %v",
			viaJSON.DesignRules.AllowedTraceAnglesDeg, want)
	}

	// FREE MODE — the same source with the one line removed. No key in, no key
	// out, on BOTH codecs.
	freeSrc := strings.Replace(src, anglesLine, "", 1)
	if freeSrc == src {
		t.Fatal("the free-mode source still carries the angles line")
	}
	free, err := UnmarshalYAML([]byte(freeSrc))
	if err != nil {
		t.Fatalf("unmarshal free-mode yaml: %v", err)
	}
	if free.DesignRules.AllowedTraceAnglesDeg != nil {
		t.Fatalf("a board declaring no angles decoded %v",
			*free.DesignRules.AllowedTraceAnglesDeg)
	}
	freeYAML, err := MarshalYAML(free)
	if err != nil {
		t.Fatalf("marshal free-mode yaml: %v", err)
	}
	if bytes.Contains(freeYAML, []byte("allowed_trace_angles_deg")) {
		t.Fatalf("free mode grew the key in YAML:\n%s", freeYAML)
	}
	freeJSON, err := json.Marshal(free)
	if err != nil {
		t.Fatalf("marshal free-mode json: %v", err)
	}
	if bytes.Contains(freeJSON, []byte("allowed_trace_angles_deg")) {
		t.Fatalf("free mode grew the key in JSON: %s", freeJSON)
	}

	// MALFORMED — an authored empty list is a refusal downstream, so it has to
	// still BE an empty list after the round trip. Erasing it here would hand
	// the compiler a free-routing board and the refusal would never fire.
	emptySrc := strings.Replace(src, anglesLine,
		"  allowed_trace_angles_deg: []\n", 1)
	empty, err := UnmarshalYAML([]byte(emptySrc))
	if err != nil {
		t.Fatalf("unmarshal empty-list yaml: %v", err)
	}
	if empty.DesignRules.AllowedTraceAnglesDeg == nil {
		t.Fatal("an authored empty angle list decoded as an absent key — the " +
			"malformed board would read as free routing")
	}
	if got := *empty.DesignRules.AllowedTraceAnglesDeg; len(got) != 0 {
		t.Fatalf("an authored empty angle list decoded as %v", got)
	}
	emptyYAML, err := MarshalYAML(empty)
	if err != nil {
		t.Fatalf("marshal empty-list yaml: %v", err)
	}
	if !bytes.Contains(emptyYAML, []byte("allowed_trace_angles_deg: []")) {
		t.Fatalf("the authored empty list did not survive the trip:\n%s", emptyYAML)
	}
}
