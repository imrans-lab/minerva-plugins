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

// entityListKeys are the five top-level entity collections whose SHAPE is part
// of the shared validation boundary: each must be a YAML sequence (or absent /
// null == empty), and no item may be a null scalar. yaml.v3 would either reject
// a non-sequence with a native error that does NOT carry our shared code, or
// silently DROP a null list item before Validate ever sees it — both must fail
// closed with a code the cross-language vector runner can assert.
var entityListKeys = []string{"components", "nets", "traces", "vias", "mounting_holes"}

// overrideNumKeys mirrors _OVERRIDE_NUM_KEYS in board_validate.py — the typed
// pin-override fields that must decode as numbers.
var overrideNumKeys = []string{"drill_mm", "annulus_diameter_mm", "pad_width_mm", "pad_height_mm"}

// UnmarshalYAML parses YAML source into a Board. Unknown top-level and
// per-component keys are preserved via the structs' inline Extra maps rather
// than dropped.
//
// Before the typed decode it walks the raw yaml.Node tree (probeNodeTree) to
// reject, WITH the shared code string, cases the typed decode would either
// mishandle or report with a native, code-less error: a non-integer version
// (unsupported_schema_version), a non-sequence or null-item entity collection
// (invalid_board_structure), or a mistyped pin-override field
// (invalid_pin_override). Wrapping these at unmarshal is what lets the vector
// runner assert code parity on unmarshal-time rejections (finding 019f8b7fb07e,
// parts 3 & 4).
func UnmarshalYAML(data []byte) (*Board, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("board: unmarshal yaml: %w", err)
	}
	if err := probeNodeTree(&doc); err != nil {
		return nil, err
	}
	var b Board
	if err := yaml.Unmarshal(data, &b); err != nil {
		return nil, fmt.Errorf("board: unmarshal yaml: %w", err)
	}
	return &b, nil
}

// probeNodeTree inspects the raw document node for the structural / typed
// rejections the shared boundary owns, returning a code-bearing error for the
// first violation. A non-mapping or empty root is left to the typed decode.
func probeNodeTree(doc *yaml.Node) error {
	if doc.Kind != yaml.DocumentNode || len(doc.Content) == 0 {
		return nil
	}
	root := doc.Content[0]
	if root.Kind != yaml.MappingNode {
		return nil
	}

	// version-dispatch: the shared boundary requires an INTEGER version. yaml.v3
	// would either coerce a whole-valued float ("2.0") into the int field, or
	// reject a quoted/typed version ("'2'") with a native error that does not
	// carry our code. Reject any present, non-integer version scalar here with
	// unsupported_schema_version, matching the Python validator (which rejects
	// anything whose type is not int). An integer out of range (0, 3, …) parses
	// fine and is left to Validate. (item 019f802ca3af, comment 629.)
	if v := nodeMapValue(root, "version"); v != nil &&
		!(v.Kind == yaml.ScalarNode && v.Tag == "!!int") {
		return fmt.Errorf("board: unmarshal yaml: unsupported_schema_version: "+
			"version %q is not an integer", v.Value)
	}

	// Entity-collection shape + null-item rejection (parts 3 & 4). A present
	// collection must be a sequence (a null whole-collection is an empty list,
	// valid); no item may be a null scalar (yaml.v3 would drop it, vanishing a
	// canonical source entity to make the two parsers "agree" — rejected instead).
	for _, key := range entityListKeys {
		v := nodeMapValue(root, key)
		if v == nil || v.Tag == "!!null" {
			continue
		}
		if v.Kind != yaml.SequenceNode {
			return fmt.Errorf("board: unmarshal yaml: invalid_board_structure: "+
				"%q must be a list", key)
		}
		for idx, item := range v.Content {
			if resolveAlias(item).Tag == "!!null" {
				return fmt.Errorf("board: unmarshal yaml: invalid_board_structure: "+
					"%q[%d] is a null item", key, idx)
			}
		}
	}

	// Pin-override field types (part 4). The typed PinOverride pointer fields
	// cannot decode a mistyped value; catch it here with the shared code rather
	// than letting yaml.v3 surface a native, code-less TypeError. Mirrors
	// _override_problems in board_validate.py.
	comps := nodeMapValue(root, "components")
	if comps == nil || comps.Kind != yaml.SequenceNode {
		return nil
	}
	for _, comp := range comps.Content {
		pins := nodeMapValue(comp, "pins")
		if pins == nil || pins.Kind != yaml.SequenceNode {
			continue
		}
		for _, pin := range pins.Content {
			ov := nodeMapValue(pin, "override")
			if ov == nil || ov.Tag == "!!null" {
				continue
			}
			if ov.Kind != yaml.MappingNode {
				return fmt.Errorf("board: unmarshal yaml: invalid_pin_override: " +
					"override must be a mapping")
			}
			if err := probeOverride(ov); err != nil {
				return err
			}
		}
	}
	return nil
}

// probeOverride rejects a mistyped field within a pin override.
func probeOverride(ov *yaml.Node) error {
	for _, k := range overrideNumKeys {
		n := nodeMapValue(ov, k)
		if n == nil || n.Tag == "!!null" {
			continue
		}
		if n.Tag != "!!int" && n.Tag != "!!float" {
			return fmt.Errorf("board: unmarshal yaml: invalid_pin_override: "+
				"override %q must be a number", k)
		}
	}
	if p := nodeMapValue(ov, "plated"); p != nil && p.Tag != "!!null" && p.Tag != "!!bool" {
		return fmt.Errorf("board: unmarshal yaml: invalid_pin_override: " +
			"override \"plated\" must be a boolean")
	}
	return nil
}

// resolveAlias follows a YAML alias node to its anchored target. The typed
// decode resolves aliases, so the structural probe MUST too — else valid YAML the
// codec accepts (`version: *v`, `override: {drill_mm: *d}`) would false-reject
// with a shared code, both a regression and a Go/Python divergence.
func resolveAlias(n *yaml.Node) *yaml.Node {
	for n != nil && n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	return n
}

// nodeMapValue returns the alias-resolved value node for key in a mapping node,
// or nil. Both the mapping and the returned value are alias-resolved so the probe
// inspects the same resolved shape the typed decode sees.
func nodeMapValue(m *yaml.Node, key string) *yaml.Node {
	m = resolveAlias(m)
	if m == nil || m.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			return resolveAlias(m.Content[i+1])
		}
	}
	return nil
}
