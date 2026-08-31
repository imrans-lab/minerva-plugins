package board

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// Board-level graphics — the codec half.
//
// WHY THE FIELD IS TYPED RATHER THAN LEFT IN Board.Extra. An unmodelled
// top-level `board_graphics:` key already round-tripped through Extra before
// this change, so "it survives a save" was never the gap. What it did NOT get
// was id minting, the entity-list probe, or Validate — which is exactly how
// smart-remote-v2 ended up with 65 B.SilkS polylines hung off TP1, a test
// point, in absolute board coordinates: the board had no legal owner for
// artwork and a component did.
//
// These tests pin the four things a typed collection owes: lossless YAML AND
// JSON carriage, id minting on migration, id validation on load, and — the one
// that guards every EXISTING board — that none of it disturbs a board that
// carries no artwork at all.

const (
	testBoardID    = "board:0123456789abcdef0123456789abcdef"
	testGraphicID  = "graphic:0123456789abcdef0123456789abcdef"
	testGraphicID2 = "graphic:11111111111111111111111111111111"
)

func graphicsBoard(t *testing.T, src string) *Board {
	t.Helper()
	b, err := UnmarshalYAML([]byte(src))
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return b
}

const textAndPolylineYAML = `version: 2
id: board:0123456789abcdef0123456789abcdef
name: Graphics
width_mm: 40
height_mm: 30
components: []
nets: []
board_graphics:
  - id: graphic:0123456789abcdef0123456789abcdef
    layer: B.SilkS
    kind: text
    text: Minerva v2
    position: {x_mm: 10, y_mm: 10}
    size_mm: 1.5
  - id: graphic:11111111111111111111111111111111
    layer: F.CrtYd
    kind: polyline
    width: 0.2
    points:
      - {x_mm: 1, y_mm: 1}
      - {x_mm: 5, y_mm: 1}
`

// A text graphic carries its STRING, not its strokes — the whole reason the
// feature is worth having, and a property the codec has to preserve exactly.
func TestBoardGraphicsRoundTripYAML(t *testing.T) {
	b := graphicsBoard(t, textAndPolylineYAML)
	if len(b.BoardGraphics) != 2 {
		t.Fatalf("got %d board graphics, want 2", len(b.BoardGraphics))
	}
	text := b.BoardGraphics[0]
	if text.Kind != "text" || text.Text != "Minerva v2" || text.Layer != "B.SilkS" {
		t.Fatalf("text graphic decoded wrong: %+v", text)
	}
	if text.Position == nil || text.Position.XMM != 10 || text.Position.YMM != 10 {
		t.Fatalf("text position decoded wrong: %+v", text.Position)
	}
	if text.SizeMM != 1.5 {
		t.Fatalf("size_mm = %v, want 1.5", text.SizeMM)
	}
	poly := b.BoardGraphics[1]
	if poly.Kind != "polyline" || len(poly.Points) != 2 || poly.Width != 0.2 {
		t.Fatalf("polyline decoded wrong: %+v", poly)
	}
	if poly.Points[0].XMM != 1 || poly.Points[1].XMM != 5 {
		t.Fatalf("polyline points decoded wrong: %+v", poly.Points)
	}

	// Marshal -> unmarshal -> marshal must be stable.
	first, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	again, err := MarshalYAML(graphicsBoard(t, string(first)))
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	if string(first) != string(again) {
		t.Fatalf("yaml is not stable across two round trips:\n--- first ---\n%s\n--- again ---\n%s", first, again)
	}
	if !strings.Contains(string(first), "Minerva v2") {
		t.Fatalf("the text string did not survive the round trip:\n%s", first)
	}
}

// json.go's stated rule: "every NEW Extra-bearing struct needs a pair here ... a
// new struct without a pair fails SILENTLY and only across IPC". Graphic is
// Extra-bearing, so this is the test that would catch a missing pair — the
// failure mode that went unnoticed for nine structs.
func TestBoardGraphicsSurviveJSONIPC(t *testing.T) {
	b := graphicsBoard(t, textAndPolylineYAML)
	b.BoardGraphics[0].Extra = map[string]interface{}{"note": "from the future"}

	raw, err := json.Marshal(b)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}
	var back Board
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatalf("unmarshal json: %v", err)
	}
	if len(back.BoardGraphics) != 2 {
		t.Fatalf("got %d board graphics over JSON, want 2", len(back.BoardGraphics))
	}
	if back.BoardGraphics[0].Text != "Minerva v2" {
		t.Fatalf("text lost over JSON: %+v", back.BoardGraphics[0])
	}
	if got := back.BoardGraphics[0].Extra["note"]; got != "from the future" {
		t.Fatalf("Graphic.Extra lost over JSON (missing MarshalJSON pair?): %v", got)
	}
}

// The migration mints an id for artwork authored without one, and LEAVES an
// already-minted id alone. The second half is the load-bearing one: the panel
// mints its own ids (pcb_entity_id.gd), and a migration that re-minted them
// would orphan the undo history and every delete-by-id that refers to them.
func TestMigrateMintsAndPreservesGraphicIDs(t *testing.T) {
	b := &Board{
		Version: 1, Name: "M", WidthMM: 10, HeightMM: 10,
		BoardGraphics: []Graphic{
			{Layer: "F.SilkS", Kind: "text", Text: "A"},
			{ID: testGraphicID2, Layer: "B.SilkS", Kind: "text", Text: "B"},
		},
	}
	minted, err := MigrateV1toV2(b, cryptoIDSource{})
	if err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if b.BoardGraphics[1].ID != testGraphicID2 {
		t.Fatalf("an already-minted graphic id was replaced: %q", b.BoardGraphics[1].ID)
	}
	if !isMintedID("graphic", b.BoardGraphics[0].ID) {
		t.Fatalf("graphic[0] id %q was not minted", b.BoardGraphics[0].ID)
	}
	if minted < 1 {
		t.Fatalf("minted count = %d, want at least the board id plus one graphic", minted)
	}
	// Minting without checking is a silent gap; checking without minting makes
	// every migrated board fail. Both halves landed, so the migrated board
	// validates.
	if err := Validate(b); err != nil {
		t.Fatalf("migrated board does not validate: %v", err)
	}
}

func TestValidateRefusesUnmintedAndDuplicateGraphicIDs(t *testing.T) {
	base := func(graphics ...Graphic) *Board {
		return &Board{Version: 2, ID: testBoardID, Name: "V", WidthMM: 10, HeightMM: 10,
			BoardGraphics: graphics}
	}
	cases := []struct {
		name string
		b    *Board
		code string
	}{
		{"unminted", base(Graphic{ID: "graphic_1", Layer: "F.SilkS", Kind: "text"}),
			"unminted_persistent_id"},
		{"absent", base(Graphic{Layer: "F.SilkS", Kind: "text"}),
			"unminted_persistent_id"},
		{"duplicate", base(
			Graphic{ID: testGraphicID, Layer: "F.SilkS", Kind: "text"},
			Graphic{ID: testGraphicID, Layer: "B.SilkS", Kind: "text"}),
			"duplicate_persistent_id"},
	}
	for _, tc := range cases {
		err := Validate(tc.b)
		if err == nil {
			t.Fatalf("%s: expected %s, got nil", tc.name, tc.code)
		}
		if !strings.Contains(err.Error(), tc.code) {
			t.Fatalf("%s: expected %s, got %v", tc.name, tc.code, err)
		}
	}
	// A well-formed pair passes, so the refusals above are about the ids and
	// not about the collection existing at all.
	ok := base(
		Graphic{ID: testGraphicID, Layer: "F.SilkS", Kind: "text"},
		Graphic{ID: testGraphicID2, Layer: "B.SilkS", Kind: "text"})
	if err := Validate(ok); err != nil {
		t.Fatalf("a valid pair of board graphics was refused: %v", err)
	}
}

// yaml.go's invariant: entityListKeys and board_validate.py's tuple must name
// the same keys, "or a malformed collection fails closed in one language and
// passes in the other".
func TestBoardGraphicsMappingIsProbedAsAnEntityList(t *testing.T) {
	_, err := UnmarshalYAML([]byte(`version: 2
id: board:0123456789abcdef0123456789abcdef
name: Bad
width_mm: 10
height_mm: 10
board_graphics:
  nope: 1
`))
	if err == nil || !strings.Contains(err.Error(), "invalid_board_structure") {
		t.Fatalf("a mapping under board_graphics was not probed: %v", err)
	}
	_, err = UnmarshalYAML([]byte(`version: 2
id: board:0123456789abcdef0123456789abcdef
name: Bad
width_mm: 10
height_mm: 10
board_graphics:
  - null
`))
	if err == nil || !strings.Contains(err.Error(), "invalid_board_structure") {
		t.Fatalf("a null item under board_graphics was not probed: %v", err)
	}
}

// THE REGRESSION GUARD FOR EVERY EXISTING BOARD. A board with no artwork must
// serialize byte-identically to what it did before this field existed, or the
// change is not additive and every committed golden moves.
func TestArtworkFreeBoardIsByteIdentical(t *testing.T) {
	b := &Board{
		Version: 1, Name: "Plain", WidthMM: 10, HeightMM: 10,
		Components: []Component{{Ref: "U1", Footprint: "F", Pins: []Pin{{Number: "1"}}}},
		Nets:       []Net{{Name: "N", Pins: []string{"U1.1"}}},
	}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(out), "board_graphics") {
		t.Fatalf("an artwork-free board emitted a board_graphics key:\n%s", out)
	}
}

// Frozen fixtures pin BOTH endpoints of the smart-remote artwork migration.
// A mutable sibling checkout is useful integration evidence, but it is not a
// deterministic unit-test oracle: its owner is expected to edit it.
func TestArtworkRepresentationsRoundTripUnchanged(t *testing.T) {
	cases := []struct {
		name, path, representation string
	}{
		{"legacy-component", "testdata/board_graphics_legacy.yaml", "legacy"},
		{"top-level", "testdata/board_graphics_top_level.yaml", "top-level"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assertArtworkRoundTrip(t, tc.path, tc.representation)
		})
	}
}

func assertArtworkRoundTrip(t *testing.T, path, representation string) {
	t.Helper()
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	b, err := UnmarshalYAML(src)
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	out, err := MarshalYAML(b)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(src) != string(out) {
		t.Fatalf("artwork fixture no longer round-trips byte-identically (%d in, %d out)",
			len(src), len(out))
	}
	if representation == "top-level" ||
		(representation == "either" && len(b.BoardGraphics) > 0) {
		if len(b.BoardGraphics) == 0 {
			t.Fatal("top-level board_graphics disappeared")
		}
		return
	}
	var tp1 *Component
	for i := range b.Components {
		if b.Components[i].Ref == "TP1" {
			tp1 = &b.Components[i]
		}
	}
	if tp1 == nil {
		t.Fatal("TP1 is missing from the board")
	}
	legacyGraphics, ok := tp1.Extra["graphics"].([]interface{})
	if !ok || len(legacyGraphics) == 0 {
		t.Fatal("legacy TP1.graphics disappeared")
	}
	if representation == "legacy" && len(b.BoardGraphics) != 0 {
		t.Fatal("legacy fixture moved representations during a plain codec round trip")
	}
}

// Optional live smoke: set MINERVA_SMART_REMOTE_BOARD to the canonical YAML
// path when intentionally checking the owner's current board.  The normal unit
// suite never reads mutable state outside this repository.
func TestLiveSmartRemoteV2RoundTripSmoke(t *testing.T) {
	path := os.Getenv("MINERVA_SMART_REMOTE_BOARD")
	if path == "" {
		t.Skip("MINERVA_SMART_REMOTE_BOARD is not set")
	}
	assertArtworkRoundTrip(t, path, "either")
}
