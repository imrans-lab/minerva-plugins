package tools

// Regression: board-by-path + digest (work item 01a0223ec9e271269fd664fcf90dd20b).
//
// The host broker caps panel→plugin request payloads at 64 KiB, and the three
// board-carrying channels all inlined O(board) documents: pcb.route and
// pcb.serialize sent the whole board dict, pcb.deserialize the whole YAML
// source. A real board (~153 KB serialized) made all three fail with
// payload_too_large. HandleSerialize additionally refuses OUTBOUND documents
// over board.MaxPayloadBytes, so serialize was capped in both directions.
//
// The fix moves oversized documents out of the capped pipe by reference:
//   - inbound (all three channels): {board_path, board_digest} — the handler
//     reads the file, verifies its sha256, and parses; digest is MANDATORY
//     (an unverified file read is refused by name, never trusted).
//   - outbound (serialize): an over-cap document lands in a temp file and the
//     reply carries {yaml_path, yaml_digest} instead of refusing.
//
// RED/GREEN contract: the NEW-ARM tests must fail before the arms exist —
// that proven red run is the regression baseline — while the precedence and
// small-document tests are unchanged-behavior invariants that must pass
// before AND after; a red baseline here is deliberately partial, never zero.
// The Python worker's route-side twin lives in
// pcb/worker/tests/test_board_by_path.py; the panel senders' twin in
// pcb/tests/gd/test_board_by_path.gd.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/imrans-lab/minerva-plugins/pcb/internal/board"
)

// minimalBoardJSON is the canonical Board JSON VALUE (what the "board" key
// carries inline), not a params envelope.
const minimalBoardJSON = `{"version":1,"name":"BP","width_mm":40,"height_mm":30,` +
	`"components":[{"ref":"U1","footprint":"IC_DIP","x_mm":1,"y_mm":2,"rotation_deg":0}],"nets":[]}`

func writeSnapshot(t *testing.T, name, content string) (path, digest string) {
	t.Helper()
	path = filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(content))
	return path, hex.EncodeToString(sum[:])
}

// oversizedBoardJSON returns a structurally-valid canonical board whose
// serialized YAML exceeds board.MaxPayloadBytes (the smart-remote-v2 class).
func oversizedBoardJSON() string {
	var comps []string
	for i := 0; i < 900; i++ {
		comps = append(comps, fmt.Sprintf(
			`{"ref":"R%d","footprint":"Resistor_SMD:R_0402_1005Metric","x_mm":%d.5,"y_mm":%d.25,"rotation_deg":90}`,
			i, i%80, i%60))
	}
	return `{"version":1,"name":"BIG","width_mm":90,"height_mm":100,"components":[` +
		strings.Join(comps, ",") + `],"nets":[]}`
}

// --- pcb.serialize: inbound board_path arm ---------------------------------

func TestSerializeAcceptsBoardPath(t *testing.T) {
	path, digest := writeSnapshot(t, "board.json", minimalBoardJSON)
	args := json.RawMessage(fmt.Sprintf(`{"board_path":%q,"board_digest":%q}`, path, digest))
	out, err := HandleSerialize(context.Background(), args)
	if err != nil {
		t.Fatalf("serialize by path: %v", err)
	}
	var r struct {
		YAML  string `json:"yaml"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if r.Error != "" {
		t.Fatalf("unexpected error result: %s", r.Error)
	}
	if !strings.Contains(r.YAML, "name: BP") || !strings.Contains(r.YAML, "ref: U1") {
		t.Fatalf("yaml missing expected content:\n%s", r.YAML)
	}
}

func TestSerializeBoardPathRequiresDigest(t *testing.T) {
	path, _ := writeSnapshot(t, "board.json", minimalBoardJSON)
	args := json.RawMessage(fmt.Sprintf(`{"board_path":%q}`, path))
	if _, err := HandleSerialize(context.Background(), args); err == nil ||
		!strings.Contains(err.Error(), "digest") {
		t.Fatalf("want a digest-required refusal, got: %v", err)
	}
}

func TestSerializeBoardPathDigestMismatchRefused(t *testing.T) {
	path, _ := writeSnapshot(t, "board.json", minimalBoardJSON)
	args := json.RawMessage(fmt.Sprintf(`{"board_path":%q,"board_digest":%q}`,
		path, strings.Repeat("0", 64)))
	if _, err := HandleSerialize(context.Background(), args); err == nil ||
		!strings.Contains(err.Error(), "digest") {
		t.Fatalf("want a digest-mismatch refusal, got: %v", err)
	}
}

func TestSerializeInlineBoardTakesPrecedence(t *testing.T) {
	// Both keys present -> the OLD arm resolves; the new arm is additive and
	// no current caller changes behavior (the bogus digest would refuse if
	// the path arm ran).
	path, _ := writeSnapshot(t, "board.json", minimalBoardJSON)
	args := json.RawMessage(fmt.Sprintf(
		`{"board":%s,"board_path":%q,"board_digest":%q}`,
		minimalBoardJSON, path, strings.Repeat("0", 64)))
	out, err := HandleSerialize(context.Background(), args)
	if err != nil {
		t.Fatalf("inline board must win over board_path: %v", err)
	}
	var r struct {
		YAML string `json:"yaml"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(r.YAML, "name: BP") {
		t.Fatalf("yaml missing expected content:\n%s", r.YAML)
	}
}

func TestSerializeBoardPathDigestCaseInsensitive(t *testing.T) {
	// Godot and Go hex-encode with different default cases; a casing
	// difference is not a mismatch (mirrors the Python twin).
	path, digest := writeSnapshot(t, "board.json", minimalBoardJSON)
	args := json.RawMessage(fmt.Sprintf(`{"board_path":%q,"board_digest":%q}`,
		path, strings.ToUpper(digest)))
	if _, err := HandleSerialize(context.Background(), args); err != nil {
		t.Fatalf("uppercase digest must verify: %v", err)
	}
}

func TestSerializeBoardPathMissingFileRefused(t *testing.T) {
	ghost := filepath.Join(t.TempDir(), "nope.json")
	args := json.RawMessage(fmt.Sprintf(`{"board_path":%q,"board_digest":%q}`,
		ghost, strings.Repeat("0", 64)))
	if _, err := HandleSerialize(context.Background(), args); err == nil ||
		!strings.Contains(err.Error(), "nope.json") {
		t.Fatalf("want a refusal naming the missing file, got: %v", err)
	}
}

func TestSerializeEmptySnapshotRefused(t *testing.T) {
	// A verified-but-empty snapshot refuses by name — it must never degrade
	// into the echoState project_file compatibility fallback.
	path, digest := writeSnapshot(t, "empty.json", "")
	args := json.RawMessage(fmt.Sprintf(`{"board_path":%q,"board_digest":%q}`, path, digest))
	if _, err := HandleSerialize(context.Background(), args); err == nil ||
		!strings.Contains(err.Error(), "empty") {
		t.Fatalf("want an empty-file refusal, got: %v", err)
	}
}

// --- pcb.serialize: outbound yaml_path arm ---------------------------------

func TestSerializeOversizedDocumentLandsByPath(t *testing.T) {
	args := json.RawMessage(`{"board":` + oversizedBoardJSON() + `}`)
	out, err := HandleSerialize(context.Background(), args)
	if err != nil {
		t.Fatalf("serialize oversized: %v", err)
	}
	var r struct {
		YAML       string `json:"yaml"`
		YAMLPath   string `json:"yaml_path"`
		YAMLDigest string `json:"yaml_digest"`
		Error      string `json:"error"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if r.Error == "payload_too_large" {
		t.Fatal("oversized document still refused payload_too_large; want a yaml_path reply")
	}
	if r.YAMLPath == "" || r.YAMLDigest == "" {
		t.Fatalf("want yaml_path + yaml_digest for an over-cap document, got: %s", out)
	}
	data, err := os.ReadFile(r.YAMLPath)
	if err != nil {
		t.Fatalf("read emitted yaml_path: %v", err)
	}
	if len(data) <= board.MaxPayloadBytes {
		t.Fatalf("by-path reply for a document that fit inline (%d bytes)", len(data))
	}
	sum := sha256.Sum256(data)
	if !strings.EqualFold(hex.EncodeToString(sum[:]), r.YAMLDigest) {
		t.Fatal("yaml_digest does not match emitted file bytes")
	}
	if !strings.Contains(string(data), "name: BIG") ||
		!strings.Contains(string(data), "ref: R899") {
		t.Fatal("emitted yaml missing expected content")
	}
}

func TestSerializeSmallDocumentStaysInline(t *testing.T) {
	args := json.RawMessage(`{"board":` + minimalBoardJSON + `}`)
	out, err := HandleSerialize(context.Background(), args)
	if err != nil {
		t.Fatal(err)
	}
	var r map[string]interface{}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if _, ok := r["yaml_path"]; ok {
		t.Fatal("small document must keep today's inline {yaml} reply shape")
	}
	if _, ok := r["yaml"]; !ok {
		t.Fatalf("inline yaml missing: %s", out)
	}
}

// --- pcb.deserialize: inbound board_path arm -------------------------------

func TestDeserializeAcceptsBoardPath(t *testing.T) {
	// The snapshot is YAML source — the deserialize-by-path case hands the
	// worker the on-disk board source without inlining it.
	yml := "version: 1\nname: BP\nwidth_mm: 40\nheight_mm: 30\ncomponents:\n" +
		"- ref: U1\n  footprint: IC_DIP\n  x_mm: 1\n  y_mm: 2\n  rotation_deg: 0\nnets: []\n"
	path, digest := writeSnapshot(t, "board.yaml", yml)
	args := json.RawMessage(fmt.Sprintf(`{"board_path":%q,"board_digest":%q}`, path, digest))
	out, err := HandleDeserialize(context.Background(), args)
	if err != nil {
		t.Fatalf("deserialize by path: %v", err)
	}
	var r struct {
		Board map[string]interface{} `json:"board"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if r.Board == nil || r.Board["name"] != "BP" {
		t.Fatalf("board missing or wrong: %s", out)
	}
}

func TestDeserializeAcceptsTheLiveBoardDict(t *testing.T) {
	// A panel holds a board dict, not a document; it hands that dict over
	// inline when small and as a JSON snapshot when large, and gets it back
	// through the same enrichment a YAML import gets.
	// The panel's wire shape: a v2 board with a part that owns its geometry
	// (pads + graphics, the keys the codec must carry through untouched).
	dict := `{"version":2,"id":"board:00000000000000000000000000000000","name":"BJ",` +
		`"width_mm":40,"height_mm":30,"layers":["top","bottom"],` +
		`"design_rules":{"clearance_mm":0.2,"trace_width_mm":0.3,"via_diameter_mm":0.8,"via_drill_mm":0.4},` +
		`"components":[{"ref":"R1","footprint":"Resistor_SMD:R_0805_2012Metric","value":"1k",` +
		`"x_mm":10,"y_mm":10,"rotation_deg":0,"layer":"top",` +
		`"pins":[{"number":"1","x_mm":-0.9125,"y_mm":0},{"number":"2","x_mm":0.9125,"y_mm":0}],` +
		`"pads":[{"number":"1","type":"smd","shape":"roundrect","position":{"x":-0.9125,"y":0},` +
		`"size":{"width":1.025,"height":1.4},"layers":["F.Cu","F.Mask","F.Paste"],"drill":{"x":0,"y":0}}],` +
		`"graphics":[{"kind":"line","layer":"F.SilkS","width":0.12,"start":{"x":-0.2,"y":-0.7},"end":{"x":0.2,"y":-0.7}}]}],` +
		`"nets":[],"traces":[],"vias":[],"zones":[]}`
	path, digest := writeSnapshot(t, "board.json", dict)
	for name, args := range map[string]string{
		"inline": `{"board":` + dict + `}`,
		"by-ref": fmt.Sprintf(`{"board_path":%q,"board_digest":%q}`, path, digest),
	} {
		out, err := HandleDeserialize(context.Background(), json.RawMessage(args))
		if err != nil {
			t.Fatalf("%s: deserialize board dict: %v", name, err)
		}
		var r struct {
			Board map[string]interface{} `json:"board"`
		}
		if err := json.Unmarshal(out, &r); err != nil {
			t.Fatal(err)
		}
		if r.Board == nil || r.Board["name"] != "BJ" {
			t.Fatalf("%s: board missing or wrong: %s", name, out)
		}
		comp := r.Board["components"].([]interface{})[0].(map[string]interface{})
		if _, ok := comp["pads"]; !ok {
			t.Fatalf("%s: the part's own pads did not survive the codec: %s", name, out)
		}
		if _, ok := comp["graphics"]; !ok {
			t.Fatalf("%s: the part's own graphics did not survive the codec: %s", name, out)
		}
	}
}

func TestDeserializeBoardPathRequiresDigest(t *testing.T) {
	path, _ := writeSnapshot(t, "board.yaml", "version: 1\nname: BP\n")
	args := json.RawMessage(fmt.Sprintf(`{"board_path":%q}`, path))
	if _, err := HandleDeserialize(context.Background(), args); err == nil ||
		!strings.Contains(err.Error(), "digest") {
		t.Fatalf("want a digest-required refusal, got: %v", err)
	}
}

func TestDeserializeBoardPathDigestMismatchRefused(t *testing.T) {
	path, _ := writeSnapshot(t, "board.yaml", "version: 1\nname: BP\n")
	args := json.RawMessage(fmt.Sprintf(`{"board_path":%q,"board_digest":%q}`,
		path, strings.Repeat("0", 64)))
	if _, err := HandleDeserialize(context.Background(), args); err == nil ||
		!strings.Contains(err.Error(), "digest") {
		t.Fatalf("want a digest-mismatch refusal, got: %v", err)
	}
}

func TestDeserializeInlineYAMLTakesPrecedence(t *testing.T) {
	path, _ := writeSnapshot(t, "board.yaml", "version: 1\nname: FILE\nwidth_mm: 1\nheight_mm: 1\ncomponents: []\nnets: []\n")
	inline := "version: 1\nname: INLINE\nwidth_mm: 1\nheight_mm: 1\ncomponents: []\nnets: []\n"
	envelope := map[string]interface{}{
		"yaml": inline, "board_path": path, "board_digest": strings.Repeat("0", 64),
	}
	raw, _ := json.Marshal(envelope)
	out, err := HandleDeserialize(context.Background(), raw)
	if err != nil {
		t.Fatalf("inline yaml must win over board_path: %v", err)
	}
	var r struct {
		Board map[string]interface{} `json:"board"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		t.Fatal(err)
	}
	if r.Board["name"] != "INLINE" {
		t.Fatalf("inline yaml did not take precedence: %s", out)
	}
}
