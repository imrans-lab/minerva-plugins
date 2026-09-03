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
	if b.Fabrication.MaskColour == nil || *b.Fabrication.MaskColour != "black" ||
		b.Fabrication.Finish == nil || *b.Fabrication.Finish != "ENIG" ||
		b.Fabrication.ThicknessMM == nil || *b.Fabrication.ThicknessMM != 1 {
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

// A PARTIALLY-STATED BLOCK IS LEGAL, and the pointer fields are what let the
// boundary say so while still refusing a blank one. With value-typed fields an
// omitted `finish` and `finish: ""` decode identically, so the validator would
// have to accept both or refuse both; here the first is nil and the second is a
// pointer to "".
func TestAPartiallyStatedFabricationBlockIsLegal(t *testing.T) {
	source := strings.Replace(fabricationBoardYAML,
		"    finish: ENIG\n    thickness_mm: 1\n", "", 1)
	b, err := UnmarshalYAML([]byte(source))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if err := Validate(b); err != nil {
		t.Fatalf("a board that stated only its colour was refused: %v", err)
	}
	if b.Fabrication.Finish != nil || b.Fabrication.ThicknessMM != nil {
		t.Fatalf("absent fields were invented: %+v", b.Fabrication)
	}
}

// THE VALUE RULES, on the side that had none. Python's board_schema refused a
// blank choice and a non-positive thickness from the day the block existed;
// this side declared the fields and judged nothing, so the two boundaries
// disagreed about the same document. Each case here has a committed
// cross-language vector too (pcb/spec/vectors/490..520); this suite is what
// says the refusal NAMES the field, which a vector's code alone does not.
func TestFabricationValuesAreRefusedByName(t *testing.T) {
	for _, tc := range []struct {
		name    string
		stated  string
		wantKey string
	}{
		{"blank finish", "    finish: \"\"\n", "fabrication.finish"},
		{"blank colour", "    mask_colour: \"   \"\n", "fabrication.mask_colour"},
		{"zero thickness", "    thickness_mm: 0\n", "fabrication.thickness_mm"},
		{"negative thickness", "    thickness_mm: -1.6\n", "fabrication.thickness_mm"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			source := strings.Replace(fabricationBoardYAML,
				"fabrication:\n    mask_colour: black\n    finish: ENIG\n    thickness_mm: 1\n",
				"fabrication:\n"+tc.stated, 1)
			b, err := UnmarshalYAML([]byte(source))
			if err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			err = Validate(b)
			if err == nil {
				t.Fatal("the value was accepted")
			}
			for _, want := range []string{unknownKeyCode, tc.wantKey} {
				if !strings.Contains(err.Error(), want) {
					t.Fatalf("refusal does not name %q: %s", want, err)
				}
			}
		})
	}
}

// A STATED ZERO MUST SURVIVE THE ROUND TRIP, which is the half of the rule a
// read-time check cannot make. With a value-typed omitempty field the 0 is
// indistinguishable from an absent key and is dropped on the way back out, so a
// document that must be refused re-serializes into one that must be accepted —
// a bad value laundered into a silent absence.
func TestAStatedZeroThicknessSurvivesReserialization(t *testing.T) {
	zero := 0.0
	b := &Board{Version: 1, Name: "Zero", WidthMM: 20, HeightMM: 20,
		Fabrication: &Fabrication{ThicknessMM: &zero}}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(out), "thickness_mm: 0") {
		t.Fatalf("a stated zero thickness vanished:\n%s", out)
	}
	again, err := UnmarshalYAML(out)
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if err := Validate(again); err == nil {
		t.Fatal("the re-read board no longer states the value it must be refused for")
	}
}
