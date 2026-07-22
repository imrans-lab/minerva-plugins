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
	// yaml.v3 silently coerces a whole-valued float ("2.0") into the int Version
	// field, so the codec alone would accept a version the Python validator (which
	// sees the float and rejects it) calls unsupported. Probe the raw version
	// scalar's tag and reject a non-integer, keeping the shared version-dispatch
	// boundary identical on both sides (item 019f802ca3af, comment 629).
	var probe struct {
		Version yaml.Node `yaml:"version"`
	}
	if err := yaml.Unmarshal(data, &probe); err == nil &&
		probe.Version.Kind == yaml.ScalarNode && probe.Version.Tag == "!!float" {
		return nil, fmt.Errorf("board: unmarshal yaml: unsupported_schema_version: "+
			"version scalar %q is not an integer", probe.Version.Value)
	}
	return &b, nil
}
