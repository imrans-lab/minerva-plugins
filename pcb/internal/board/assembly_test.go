package board

import (
	"encoding/json"
	"strings"
	"testing"
)

// fullAssemblyBoard is a board whose one component states EVERY assembly field
// and a two-instance expansion. It is the fixture behind the round-trip oracle:
// any field or placement ref that a codec drops shows up as a mismatch here.
func fullAssemblyBoard() *Board {
	yes := true
	return &Board{
		Version: 1, Name: "assembly", WidthMM: 60, HeightMM: 40,
		Components: []Component{
			{Ref: "R1", Footprint: "R_0805", XMM: 5, YMM: 5},
			{
				Ref: "J1S", Footprint: "PinSocket_1x07", XMM: 20, YMM: 10,
				Assembly: &ComponentAssembly{
					Populate:     &yes,
					Manufacturer: "Sullins",
					MPN:          "PPTC071LFBN-RC",
					Package:      "PinSocket_1x07_P2.54mm",
					Comment:      "1x7 2.54mm socket strip",
					HouseParts:   map[string]string{"jlcpcb": "C41376161"},
					Paste:        PasteExclude,
					Placements: []AssemblyPlacement{
						{Ref: "J1S_A", OffsetMM: &AssemblyOffset{X: 0, Y: 0}, RotationDeg: 0},
						{Ref: "J1S_B", OffsetMM: &AssemblyOffset{X: 22.86, Y: 0}, RotationDeg: 180},
					},
				},
			},
		},
	}
}

// assertFullAssembly re-checks every authored field on a board that has been
// through a codec. Written as one function so the YAML and JSON arms cannot
// drift into checking different subsets.
func assertFullAssembly(t *testing.T, where string, b *Board) {
	t.Helper()
	if b.Components[0].Assembly != nil {
		t.Fatalf("%s: a component with no assembly block gained one: %+v", where, b.Components[0].Assembly)
	}
	a := b.Components[1].Assembly
	if a == nil {
		t.Fatalf("%s: the assembly block was dropped entirely", where)
	}
	if a.Populate == nil || !*a.Populate {
		t.Fatalf("%s: populate lost (an authored true must survive, not be omitempty'd away): %+v", where, a.Populate)
	}
	if a.Manufacturer != "Sullins" || a.MPN != "PPTC071LFBN-RC" ||
		a.Package != "PinSocket_1x07_P2.54mm" || a.Comment != "1x7 2.54mm socket strip" {
		t.Fatalf("%s: an identity field was dropped or altered: %+v", where, a)
	}
	if a.HouseParts["jlcpcb"] != "C41376161" {
		t.Fatalf("%s: house_parts lost: %+v", where, a.HouseParts)
	}
	if a.Paste != PasteExclude {
		t.Fatalf("%s: paste lost: %q", where, a.Paste)
	}
	if len(a.Placements) != 2 {
		t.Fatalf("%s: expected 2 placements, got %d", where, len(a.Placements))
	}
	if a.Placements[0].Ref != "J1S_A" || a.Placements[1].Ref != "J1S_B" {
		t.Fatalf("%s: a placement REF was dropped or renamed: %+v", where, a.Placements)
	}
	if a.Placements[1].OffsetMM == nil || a.Placements[1].OffsetMM.X != 22.86 ||
		a.Placements[1].OffsetMM.Y != 0 || a.Placements[1].RotationDeg != 180 {
		t.Fatalf("%s: a placement transform was dropped: %+v", where, a.Placements[1])
	}
	// The zero-valued transform is the trap: an omitempty'd 0 offset must not
	// come back as a MISSING offset that a later reader defaults differently.
	if a.Placements[0].OffsetMM == nil || a.Placements[0].OffsetMM.X != 0 ||
		a.Placements[0].OffsetMM.Y != 0 {
		t.Fatalf("%s: the authored zero offset did not survive: %+v", where, a.Placements[0])
	}
}

// TestStructuredAssemblyRoundTripsBothCodecs is the schema oracle: promote
// (marshal) → deserialize (unmarshal) → load must not drop an assembly field or
// a placement ref, on EITHER boundary. The YAML arm is the document a promote
// writes; the JSON arm is the pcb.serialize / pcb.deserialize IPC pipe the panel
// actually holds a board over.
func TestStructuredAssemblyRoundTripsBothCodecs(t *testing.T) {
	b := fullAssemblyBoard()
	if err := Validate(b); err != nil {
		t.Fatalf("the fully-authored fixture must validate: %v", err)
	}

	y, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("MarshalYAML: %v", err)
	}
	yBack, err := UnmarshalYAML(y)
	if err != nil {
		t.Fatalf("UnmarshalYAML:\n%s\n%v", string(y), err)
	}
	assertFullAssembly(t, "YAML", yBack)

	j, err := json.Marshal(b)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	var jBack Board
	if err := json.Unmarshal(j, &jBack); err != nil {
		t.Fatalf("json.Unmarshal:\n%s\n%v", string(j), err)
	}
	assertFullAssembly(t, "JSON", &jBack)

	// Cross-boundary, the way a real promote runs: panel JSON in, canonical
	// YAML out, back through the load path. A field that survives each codec
	// alone but not the pair is the failure this arm catches.
	crossed, err := MarshalYAML(&jBack)
	if err != nil {
		t.Fatalf("MarshalYAML after the JSON hop: %v", err)
	}
	crossBack, err := UnmarshalYAML(crossed)
	if err != nil {
		t.Fatalf("UnmarshalYAML after the JSON hop: %v", err)
	}
	assertFullAssembly(t, "JSON→YAML", crossBack)
}

// TestBoardWithoutAssemblyIsUntouched is the other half of "loads exactly as it
// does today": a board that never heard of the block gains nothing, and its
// emitted document carries no assembly key at all.
func TestBoardWithoutAssemblyIsUntouched(t *testing.T) {
	const src = `version: 1
name: plain
width_mm: 20
height_mm: 15
components:
  - {ref: R1, footprint: R_0805, x_mm: 5, y_mm: 5}
`
	b, err := UnmarshalYAML([]byte(src))
	if err != nil {
		t.Fatalf("UnmarshalYAML: %v", err)
	}
	if err := Validate(b); err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if b.Components[0].Assembly != nil {
		t.Fatalf("an absent block must stay absent, got %+v", b.Components[0].Assembly)
	}
	y, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("MarshalYAML: %v", err)
	}
	if strings.Contains(string(y), "assembly") {
		t.Fatalf("a board with no assembly data grew an assembly key:\n%s", string(y))
	}
}

// TestAssemblyRefusesRatherThanDropping pins the refusals that keep this block
// from lying quietly: an unknown sub-key (a typo'd identity field), an unknown
// placement key (a typo'd offset silently placing the part at its parent's
// origin), a paste token outside the closed set, an unauthored placement ref,
// and two physical parts claiming one designator.
func TestAssemblyRefusesRatherThanDropping(t *testing.T) {
	head := "version: 1\nname: refuse\nwidth_mm: 20\nheight_mm: 15\ncomponents:\n"

	decodeCases := []struct{ name, body string }{
		{"unknown assembly field", "  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {mpm: C123}}\n"},
		{"unknown placement field", "  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {placements: [{ref: R1_A, offset: {x: 1, y: 0}}]}}\n"},
		{"assembly is a list", "  - {ref: R1, x_mm: 1, y_mm: 1, assembly: [populate]}\n"},
	}
	for _, c := range decodeCases {
		_, err := UnmarshalYAML([]byte(head + c.body))
		if err == nil || !strings.Contains(err.Error(), "invalid_component_assembly") {
			t.Errorf("%s: want invalid_component_assembly, got %v", c.name, err)
		}
	}

	validateCases := []struct{ name, body, code string }{
		{"paste outside the closed set",
			"  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {paste: maybe}}\n", "invalid_component"},
		{"placement with no ref",
			"  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {placements: [{offset_mm: {x: 1, y: 0}}]}}\n",
			"invalid_component"},
		{"two placements share a designator",
			"  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {placements: [{ref: X}, {ref: X}]}}\n",
			"duplicate_assembly_designator"},
		{"a placement takes another component's ref",
			"  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {placements: [{ref: R2}]}}\n" +
				"  - {ref: R2, x_mm: 5, y_mm: 1}\n",
			"duplicate_assembly_designator"},
	}
	for _, c := range validateCases {
		b, err := UnmarshalYAML([]byte(head + c.body))
		if err != nil {
			t.Errorf("%s: expected a clean decode, got %v", c.name, err)
			continue
		}
		err = Validate(b)
		if err == nil || !strings.Contains(err.Error(), c.code) {
			t.Errorf("%s: want %s, got %v", c.name, c.code, err)
		}
	}

	// The control: a placement reusing its OWN component's ref is a legal
	// single-instance expansion, not a collision.
	b, err := UnmarshalYAML([]byte(head + "  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {placements: [{ref: R1}]}}\n"))
	if err != nil {
		t.Fatalf("self-named placement decode: %v", err)
	}
	if err := Validate(b); err != nil {
		t.Fatalf("a placement reusing its own component ref must validate: %v", err)
	}
}

// TestEmittedRefsIsTheDesignatorSource pins the one accessor downstream outputs
// read: a component with no expansion emits its own ref, one with an expansion
// emits the AUTHORED refs and never its own.
func TestEmittedRefsIsTheDesignatorSource(t *testing.T) {
	b := fullAssemblyBoard()
	if got := b.Components[0].EmittedRefs(); len(got) != 1 || got[0] != "R1" {
		t.Fatalf("a plain component emits its own ref, got %v", got)
	}
	got := b.Components[1].EmittedRefs()
	if len(got) != 2 || got[0] != "J1S_A" || got[1] != "J1S_B" {
		t.Fatalf("an expanded component emits its authored refs, got %v", got)
	}
}
