// Package board — YAML codec for the canonical board-source contract.
//
// Marshal/Unmarshal are thin, deterministic wrappers over gopkg.in/yaml.v3.
// yaml.v3 emits struct fields in declaration order and sorts map/inline keys,
// so MarshalYAML(b) is a pure function of b — the property the pcb.serialize
// channel relies on.
package board

import (
	"fmt"

	"gopkg.in/yaml.v3"
)

// MaxPayloadBytes is the serialized-source ceiling the pcb.serialize channel
// enforces. Minerva's plugin IPC transport caps a single message at 64 KiB
// (gap register A-8); we refuse at ~60 KiB rather than emit a payload the
// broker will truncate mid-document. See ErrPayloadTooLarge.
const MaxPayloadBytes = 60 * 1024

// MarshalYAML renders a Board to canonical, deterministic YAML source.
func MarshalYAML(b *Board) ([]byte, error) {
	out, err := yaml.Marshal(b)
	if err != nil {
		return nil, fmt.Errorf("board: marshal yaml: %w", err)
	}
	return out, nil
}

// UnmarshalYAML parses YAML source into a Board. Unknown top-level and
// per-component keys are preserved via the structs' inline Extra maps rather
// than dropped.
func UnmarshalYAML(data []byte) (*Board, error) {
	var b Board
	if err := yaml.Unmarshal(data, &b); err != nil {
		return nil, fmt.Errorf("board: unmarshal yaml: %w", err)
	}
	return &b, nil
}
