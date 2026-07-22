package board

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// vectorExpect mirrors pcb/spec/vectors/<name>/expect.json.
type vectorExpect struct {
	Valid bool   `json:"valid"`
	Code  string `json:"code"`
}

const vectorsDir = "../../spec/vectors"

// minVectors is the committed floor — a drift/loss guard so a deleted or
// mis-globbed vector fails the suite instead of silently reducing coverage.
const minVectors = 14

// TestSharedValidationVectors runs every committed cross-language vector through
// the Go schema boundary (UnmarshalYAML + Validate) and asserts the outcome the
// vector declares. The IDENTICAL directory is asserted by the Python validator in
// pcb/worker/tests/test_board_v2_vectors.py; both suites passing over the same
// vectors is the anti-drift guarantee (item 019f802ca3af, comment 629).
//
// Two ways the boundary can fail closed: the codec rejects a structurally-invalid
// source at UnmarshalYAML (e.g. a wrong-typed override or version), or Validate
// rejects a parsed board (bad version range, unminted v2 id). Both count as
// "not valid"; Validate's error carries the same code string the vector declares.
func TestSharedValidationVectors(t *testing.T) {
	entries, err := os.ReadDir(vectorsDir)
	if err != nil {
		t.Fatalf("read vectors dir %q: %v", vectorsDir, err)
	}
	seen := 0
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		seen++
		name := e.Name()
		t.Run(name, func(t *testing.T) {
			dir := filepath.Join(vectorsDir, name)
			input, err := os.ReadFile(filepath.Join(dir, "input.yaml"))
			if err != nil {
				t.Fatalf("read input: %v", err)
			}
			raw, err := os.ReadFile(filepath.Join(dir, "expect.json"))
			if err != nil {
				t.Fatalf("read expect: %v", err)
			}
			var want vectorExpect
			if err := json.Unmarshal(raw, &want); err != nil {
				t.Fatalf("parse expect.json: %v", err)
			}

			b, uErr := UnmarshalYAML(input)
			if uErr != nil {
				if want.Valid {
					t.Fatalf("expected valid, but codec rejected at unmarshal: %v", uErr)
				}
				return // codec fail-closed is a legitimate rejection
			}
			vErr := Validate(b)
			if gotValid := vErr == nil; gotValid != want.Valid {
				t.Fatalf("valid=%v, want %v (validate err: %v)", gotValid, want.Valid, vErr)
			}
			if !want.Valid && want.Code != "" && vErr != nil {
				if !strings.Contains(vErr.Error(), want.Code) {
					t.Fatalf("error %q does not carry the shared code %q", vErr.Error(), want.Code)
				}
			}
		})
	}
	if seen < minVectors {
		t.Fatalf("ran %d vectors, expected at least %d — a committed vector was lost", seen, minVectors)
	}
}
