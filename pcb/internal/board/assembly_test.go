package board

import (
	"encoding/json"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
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
					Placements: &[]AssemblyPlacement{
						// A's anchor states an authored ZERO x — the axis a
						// value-typed field would omitempty away.
						{Ref: "J1S_A", OffsetMM: &AssemblyOffset{X: 0, Y: 0},
							AnchorMM: &AssemblyOffset{X: 0, Y: 7.62}, RotationDeg: 0},
						// B authors no anchor at all: absent must stay absent,
						// or every board would start carrying one.
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
	placements := a.PlacementList()
	if len(placements) != 2 {
		t.Fatalf("%s: expected 2 placements, got %d", where, len(placements))
	}
	if placements[0].Ref != "J1S_A" || placements[1].Ref != "J1S_B" {
		t.Fatalf("%s: a placement REF was dropped or renamed: %+v", where, placements)
	}
	if placements[1].OffsetMM == nil || placements[1].OffsetMM.X != 22.86 ||
		placements[1].OffsetMM.Y != 0 || placements[1].RotationDeg != 180 {
		t.Fatalf("%s: a placement transform was dropped: %+v", where, placements[1])
	}
	// The zero-valued transform is the trap: an omitempty'd 0 offset must not
	// come back as a MISSING offset that a later reader defaults differently.
	if placements[0].OffsetMM == nil || placements[0].OffsetMM.X != 0 ||
		placements[0].OffsetMM.Y != 0 {
		t.Fatalf("%s: the authored zero offset did not survive: %+v", where, placements[0])
	}
	// THE ANCHOR IS AN ASSEMBLY FIELD, so losing it across a round trip is the
	// same hard gate every field above is under — and it is the field most able
	// to be lost quietly, because the board still compiles, still gerbers and
	// still passes every order gate with the parent's anchor inherited in its
	// place. Its x is an authored 0 for the same reason the offset's is.
	if placements[0].AnchorMM == nil || placements[0].AnchorMM.X != 0 ||
		placements[0].AnchorMM.Y != 7.62 {
		t.Fatalf("%s: the authored placement anchor did not survive: %+v", where, placements[0])
	}
	// And the other half: a placement that authored NO anchor must not gain one,
	// or the parent-measured anchor it is entitled to would be overwritten by a
	// zero pair the author never wrote.
	if placements[1].AnchorMM != nil {
		t.Fatalf("%s: a placement with no authored anchor grew one: %+v", where, placements[1])
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
	// Exactly ONE anchor_mm in the document: the authored one is written and the
	// unauthored one is not invented. A value-typed field would emit both (Go's
	// json omitempty never omits a struct) and a reader would then be told the
	// second strip's centre is its own origin.
	if n := strings.Count(string(y), "anchor_mm"); n != 1 {
		t.Fatalf("want exactly 1 anchor_mm in the emitted document, got %d:\n%s", n, string(y))
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
	if n := strings.Count(string(j), "anchor_mm"); n != 1 {
		t.Fatalf("want exactly 1 anchor_mm on the JSON hop, got %d: %s", n, string(j))
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
		// The NESTED typo: the outer key is spelled right, so nothing above
		// catches it, and x defaults to 0 — the part lands on its parent's
		// origin rather than 22.86 mm away.
		{"unknown offset_mm axis", "  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {placements: [{ref: R1_A, offset_mm: {xx: 22.86, y: 0}}]}}\n"},
		{"offset_mm is a scalar", "  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {placements: [{ref: R1_A, offset_mm: 22.86}]}}\n"},
		// The anchor decodes through the same point type, so it inherits both
		// refusals: a mistyped axis accepted with x defaulted to 0 would anchor
		// the part on its own origin instead of its body centre.
		{"unknown anchor_mm axis", "  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {placements: [{ref: R1_A, anchor_mm: {xx: 0, y: 26.67}}]}}\n"},
		{"anchor_mm is a scalar", "  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {placements: [{ref: R1_A, anchor_mm: 26.67}]}}\n"},
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
		{"non-finite anchor_mm",
			"  - {ref: R1, x_mm: 1, y_mm: 1, assembly: {placements: [{ref: R1_A, anchor_mm: {x: .inf, y: 0}}]}}\n",
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

// TestNestedOffsetTypoRefusesOnBothCodecs is the nested half of the
// unknown-key rule, on the boundary the panel actually holds a board over. The
// outer `offset_mm` key is spelled correctly, so the placement's own key check
// passes; only the axis is wrong, and an accepted `{xx: …}` would leave X at 0
// and emit the expanded part at its parent's origin.
func TestNestedOffsetTypoRefusesOnBothCodecs(t *testing.T) {
	const src = `{"ref":"R1","footprint":"R_0805","assembly":{"placements":[{"ref":"R1_A","offset_mm":{"xx":22.86,"y":0}}]}}`
	var c Component
	err := json.Unmarshal([]byte(src), &c)
	if err == nil || !strings.Contains(err.Error(), "invalid_component_assembly") {
		t.Fatalf("JSON: want invalid_component_assembly for a mistyped axis, got %v (decoded %+v)", err, c.Assembly)
	}
	if !strings.Contains(err.Error(), "xx") {
		t.Fatalf("JSON: the refusal must NAME the key that was not understood, got %v", err)
	}
}

// TestAuthoredEmptyExpansionSurvivesBothCodecs is the migration-boundary half
// of the empty-expansion fault. `placements: []` is a REFUSAL the export gate
// owns (assembly_empty_expansion), and it can only refuse a fault that is still
// on the board: a codec that re-serialized the key away would hand the exporter
// an ordinary one-part component and the order would ship silently wrong.
//
// The three arms are the three hops a real board makes: the YAML document a
// promote writes, the JSON pipe the panel holds it over, and the pair.
func TestAuthoredEmptyExpansionSurvivesBothCodecs(t *testing.T) {
	const src = `version: 1
name: empty-expansion
width_mm: 20
height_mm: 15
components:
  - {ref: R1, footprint: R_0805, x_mm: 5, y_mm: 5, assembly: {mpn: C25804, placements: []}}
`
	b, err := UnmarshalYAML([]byte(src))
	if err != nil {
		t.Fatalf("UnmarshalYAML: %v", err)
	}
	assertAuthoredEmpty := func(where string, b *Board) {
		t.Helper()
		a := b.Components[0].Assembly
		if a == nil || !a.ExpansionAuthored() {
			t.Fatalf("%s: the authored-empty expansion was erased; assembly=%+v", where, a)
		}
		if len(a.PlacementList()) != 0 {
			t.Fatalf("%s: an empty expansion gained placements: %+v", where, a.PlacementList())
		}
	}
	assertAuthoredEmpty("decode", b)

	y, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("MarshalYAML: %v", err)
	}
	if !strings.Contains(string(y), "placements") {
		t.Fatalf("the re-emitted document dropped the authored key:\n%s", string(y))
	}
	yBack, err := UnmarshalYAML(y)
	if err != nil {
		t.Fatalf("UnmarshalYAML round two: %v", err)
	}
	assertAuthoredEmpty("YAML", yBack)

	j, err := json.Marshal(b)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if !strings.Contains(string(j), `"placements":[]`) {
		t.Fatalf("the JSON hop dropped the authored key: %s", string(j))
	}
	var jBack Board
	if err := json.Unmarshal(j, &jBack); err != nil {
		t.Fatalf("json.Unmarshal: %v", err)
	}
	assertAuthoredEmpty("JSON", &jBack)

	crossed, err := MarshalYAML(&jBack)
	if err != nil {
		t.Fatalf("MarshalYAML after the JSON hop: %v", err)
	}
	crossBack, err := UnmarshalYAML(crossed)
	if err != nil {
		t.Fatalf("UnmarshalYAML after the JSON hop: %v", err)
	}
	assertAuthoredEmpty("JSON→YAML", crossBack)

	// The control: a board with NO placements key must not grow one, or every
	// ordinary component would start carrying an empty list.
	plain, err := UnmarshalYAML([]byte(`version: 1
name: plain
width_mm: 20
height_mm: 15
components:
  - {ref: R1, footprint: R_0805, x_mm: 5, y_mm: 5, assembly: {mpn: C25804}}
`))
	if err != nil {
		t.Fatalf("UnmarshalYAML (plain): %v", err)
	}
	py, err := MarshalYAML(plain)
	if err != nil {
		t.Fatalf("MarshalYAML (plain): %v", err)
	}
	if strings.Contains(string(py), "placements") {
		t.Fatalf("an absent expansion grew a placements key:\n%s", string(py))
	}
}

// identityHomesYAML authors the SAME two identity fields in all three homes,
// every value a digit string with a leading zero — the shape YAML-1.1 resolves
// as octal (`0603` -> 387, `0402` -> 258, `0201` -> 129). Around them ride
// passthrough keys of every other shape the inline Extra map can carry, so a
// fix that reached past the identity keys shows up here as a changed neighbour.
const identityHomesYAML = `version: 1
name: identity-homes
width_mm: 20
height_mm: 20
components:
    - ref: R1
      footprint: R_0603
      x_mm: 1
      y_mm: 1
      rotation_deg: 0
      assembly:
        mpn: 0201
        package: 0603
      mpn: 0201
      package: 0603
      properties:
        mpn: 0201
        package: 0603
        note: keep me
        qty: 4
        ratio: 1.25
        flag: true
        blank:
        nested:
            a: 1
            b:
                - 1
                - 2
      lot_code: 0777
`

// A Go SAVE must not rewrite an authored identity value. The oracle: a board
// authoring `package: 0603` / `mpn: 0201` in each of the three homes comes back
// from a round trip carrying the digits the author wrote — never 387 or 129,
// the numbers YAML resolution produces from them. Before this, the two
// pre-block homes came back renumbered and the file on disk was overwritten,
// which is why the Python reader's refusal alone was only half a fix.
func TestGoRoundTripKeepsAuthoredIdentityTextInAllThreeHomes(t *testing.T) {
	b, err := UnmarshalYAML([]byte(identityHomesYAML))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, gone := range []string{"387", "129", "258"} {
		if strings.Contains(string(out), gone) {
			t.Fatalf("a resolved number (%s) reached the file — the authored "+
				"text was rewritten:\n%s", gone, out)
		}
	}

	back, err := UnmarshalYAML(out)
	if err != nil {
		t.Fatalf("re-unmarshal: %v", err)
	}
	c := back.Components[0]
	if c.Assembly == nil || c.Assembly.Package != "0603" || c.Assembly.MPN != "0201" {
		t.Fatalf("assembly block home lost the authored text: %+v", c.Assembly)
	}
	if c.Extra["package"] != "0603" || c.Extra["mpn"] != "0201" {
		t.Fatalf("top-level scalar home lost the authored text: %#v", c.Extra)
	}
	props, ok := c.Extra["properties"].(map[string]interface{})
	if !ok {
		t.Fatalf("properties did not survive as a mapping: %#v", c.Extra["properties"])
	}
	if props["package"] != "0603" || props["mpn"] != "0201" {
		t.Fatalf("properties home lost the authored text: %#v", props)
	}
}

// The identity repair must not reach any OTHER key riding the same inline
// passthrough — that map carries arbitrary author data, and silently changing
// one of those would be a worse bug than the one being fixed. Every non-identity
// value below keeps the type and value the untyped decode gives it, INCLUDING
// `lot_code: 0777`, which still resolves to 511: only the four identity names
// are treated as text, and the scope of the repair is exactly that fact.
func TestIdentityTextRepairLeavesEveryOtherPassthroughKeyAlone(t *testing.T) {
	b, err := UnmarshalYAML([]byte(identityHomesYAML))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	c := b.Components[0]
	if c.Extra["lot_code"] != 511 {
		t.Fatalf("a non-identity passthrough key changed meaning: %#v", c.Extra["lot_code"])
	}
	props, ok := c.Extra["properties"].(map[string]interface{})
	if !ok {
		t.Fatalf("properties did not survive as a mapping: %#v", c.Extra["properties"])
	}
	for key, want := range map[string]interface{}{
		"note": "keep me", "qty": 4, "ratio": 1.25, "flag": true, "blank": nil,
	} {
		if got := props[key]; got != want {
			t.Fatalf("passthrough %q changed: got %#v (%T), want %#v", key, got, got, want)
		}
	}
	nested, ok := props["nested"].(map[string]interface{})
	if !ok || nested["a"] != 1 {
		t.Fatalf("a nested passthrough mapping was flattened or lost: %#v", props["nested"])
	}
	seq, ok := nested["b"].([]interface{})
	if !ok || len(seq) != 2 || seq[0] != 1 || seq[1] != 2 {
		t.Fatalf("a nested passthrough sequence was lost: %#v", nested["b"])
	}
	// The full key set is the real proof of "nothing dropped": name it.
	for _, key := range []string{"mpn", "package", "properties", "lot_code"} {
		if _, present := c.Extra[key]; !present {
			t.Fatalf("passthrough key %q was dropped: %#v", key, c.Extra)
		}
	}
	for _, key := range []string{"mpn", "package", "note", "qty", "ratio", "flag",
		"blank", "nested"} {
		if _, present := props[key]; !present {
			t.Fatalf("properties key %q was dropped: %#v", key, props)
		}
	}
}

// A board whose identity values are already quoted — what the docs tell an
// author to write — must survive a round trip BYTE for byte, or the codec would
// churn a file every time it opened one.
func TestQuotedIdentityBoardRoundTripsByteStable(t *testing.T) {
	const quoted = `version: 1
name: quoted-identity
width_mm: 20
height_mm: 20
design_rules: {}
components:
    - ref: R1
      footprint: R_0603
      x_mm: 1
      y_mm: 1
      rotation_deg: 0
      assembly:
        mpn: "0201"
        package: "0603"
      mpn: "0201"
      package: "0603"
      properties:
        mpn: "0201"
        package: "0603"
nets: []
`
	b, err := UnmarshalYAML([]byte(quoted))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(out) != quoted {
		t.Fatalf("a quoted board did not round-trip byte-stable:\n--- got ---\n%s"+
			"--- want ---\n%s", out, quoted)
	}
}

// A null identity value means "not authored in this home" and must stay null:
// turning it into the empty string would stop the precedence fold from falling
// through to the next home, which is the behaviour docs/board-yaml.md promises.
func TestNullIdentityValueStaysNull(t *testing.T) {
	const src = `version: 1
name: null-identity
width_mm: 20
height_mm: 20
components:
    - ref: R1
      footprint: R_0603
      x_mm: 1
      y_mm: 1
      package:
      properties:
        mpn:
`
	b, err := UnmarshalYAML([]byte(src))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	c := b.Components[0]
	if v, present := c.Extra["package"]; !present || v != nil {
		t.Fatalf("a null top-level identity value changed: %#v", c.Extra)
	}
	props, _ := c.Extra["properties"].(map[string]interface{})
	if v, present := props["mpn"]; !present || v != nil {
		t.Fatalf("a null properties identity value changed: %#v", props)
	}
}

// WHEN THE REPAIR CANNOT RUN IT SAYS SO. preserveIdentityText needs the source
// node tree and the decoded board to line up component-for-component; where
// they do not it leaves every value exactly as the untyped decode left it,
// which IS the renumbering above. Bailing quietly made that outcome
// indistinguishable from a clean pass, so the pass now hands its caller a
// warning per component it could not walk, and UnmarshalYAMLWithWarnings puts
// it on the deserialize reply's warnings list.
func TestIdentityRepairReportsWhenItCannotRun(t *testing.T) {
	var doc yaml.Node
	if err := yaml.Unmarshal([]byte(identityHomesYAML), &doc); err != nil {
		t.Fatalf("unmarshal node tree: %v", err)
	}
	var b Board
	if err := yaml.Unmarshal([]byte(identityHomesYAML), &b); err != nil {
		t.Fatalf("unmarshal board: %v", err)
	}

	// The lined-up case is silent — a warning on every load would train a
	// reader to ignore the one that matters.
	if w := preserveIdentityText(&b, &doc); len(w) != 0 {
		t.Fatalf("a document that lines up must warn about nothing: %v", w)
	}

	// One more decoded component than the document has nodes: the pass cannot
	// tell which node describes which component, so it runs over none of them.
	skewed := b
	skewed.Components = append(append([]Component{}, b.Components...), Component{Ref: "R2"})
	warnings := preserveIdentityText(&skewed, &doc)
	if len(warnings) == 0 {
		t.Fatal("a shape mismatch fell back to the renumbering silently")
	}
	if !strings.Contains(warnings[0], "identity text was not preserved") ||
		!strings.Contains(warnings[0], "0603") {
		t.Errorf("the warning must name what was lost and what it costs: %q", warnings[0])
	}

	// A component whose source node is not a mapping is named INDIVIDUALLY —
	// the rest of the board is still repaired, so a whole-document warning
	// would overstate the damage.
	var scalarDoc yaml.Node
	if err := yaml.Unmarshal([]byte(identityHomesYAML), &scalarDoc); err != nil {
		t.Fatalf("unmarshal node tree: %v", err)
	}
	comps := nodeMapValue(scalarDoc.Content[0], "components")
	comps.Content[0] = &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "R1"}
	warnings = preserveIdentityText(&b, &scalarDoc)
	if len(warnings) != 1 || !strings.Contains(warnings[0], "components[0]") ||
		!strings.Contains(warnings[0], "R1") {
		t.Errorf("a non-mapping component node must be named: %v", warnings)
	}
}
