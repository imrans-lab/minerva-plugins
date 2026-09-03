package board

import (
	"strings"
	"testing"
)

// The ordered appearance on the Go side: the block round-trips, a board that
// states nothing keeps its bytes, and an unknown key inside the block is
// refused naming the entity and the key.
//
// The last claim is the one worth an explicit test even though nothing in
// schema.go was written for it: the walk reads its known keys off the struct
// tags, so declaring the field is supposed to be enough. This asserts that the
// mechanism actually reaches a NESTED pointer-to-struct, which is a shape no
// other board field had before.

const fabricationBoardYAML = `version: 2
id: board:0123456789abcdef0123456789abcdef
name: appearance
width_mm: 40
height_mm: 30
design_rules:
    clearance_mm: 0.2
fabrication:
    mask_colour: black
    finish: ENIG
    thickness_mm: 1
components: []
nets: []
`

func TestFabricationBlockRoundTrips(t *testing.T) {
	b, err := UnmarshalYAML([]byte(fabricationBoardYAML))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if b.Fabrication == nil {
		t.Fatal("fabrication block was dropped")
	}
	if b.Fabrication.MaskColour != "black" || b.Fabrication.Finish != "ENIG" ||
		b.Fabrication.ThicknessMM != 1 {
		t.Fatalf("fabrication not carried: %+v", b.Fabrication)
	}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(out), "mask_colour: black") {
		t.Fatalf("re-marshalled board lost the choice:\n%s", out)
	}
}

// THE COMPATIBILITY CLAIM on this side: a board that names no appearance must
// emit no `fabrication` key at all, so its YAML is byte-identical to what it
// was before the block existed. Pointer + omitempty is what buys that, and a
// future change to a value type would break it silently.
func TestABoardWithNoAppearanceEmitsNoFabricationKey(t *testing.T) {
	source := strings.Replace(fabricationBoardYAML,
		"fabrication:\n    mask_colour: black\n    finish: ENIG\n    thickness_mm: 1\n",
		"", 1)
	b, err := UnmarshalYAML([]byte(source))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if b.Fabrication != nil {
		t.Fatalf("a silent board invented an appearance: %+v", b.Fabrication)
	}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(out), "fabrication") {
		t.Fatalf("silent board emitted a fabrication key:\n%s", out)
	}
}

// `mask_color` is the realistic typo — American spelling of the key we chose.
// Accepting it would leave the board green while its author believed it black,
// which is exactly the silent-substitution the positive schema exists to stop.
func TestAnUnknownFabricationKeyIsRefusedByName(t *testing.T) {
	source := strings.Replace(fabricationBoardYAML,
		"mask_colour: black", "mask_color: black", 1)
	_, err := UnmarshalYAML([]byte(source))
	if err == nil {
		t.Fatal("an unknown key inside fabrication was accepted")
	}
	msg := err.Error()
	for _, want := range []string{unknownKeyCode, "board.fabrication", "mask_color"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("refusal does not name %q: %s", want, msg)
		}
	}
}
