package board

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// isJSONNull reports whether a raw JSON value is the literal null. An absent
// mapping key yields a nil RawMessage, which callers handle separately.
func isJSONNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

// ProbeJSONBoard is the JSON-side sibling of probeNodeTree (the YAML path). It
// rejects the structural violations the shared boundary owns but that a typed
// json.Unmarshal silently ERASES: encoding/json decodes a `"traces":[null]`
// element into a ZERO-VALUED struct (not a dropped item, as yaml.v3 would), so
// board.Validate — which runs on the already-parsed struct — can no longer tell a
// null item from a legitimately minimal one, and a phantom zero entity would
// round-trip into canonical source. The pcb.serialize channel therefore probes
// the RAW board JSON here first, across ALL five entity collections, emitting the
// SAME invalid_board_structure code the YAML path and the Python validator use
// (finding 019f8b7fb07e). A whole-collection null (`"traces":null`) is an empty
// list (valid); a present non-array collection, or any null element, is rejected.
func ProbeJSONBoard(raw json.RawMessage) error {
	if len(bytes.TrimSpace(raw)) == 0 || isJSONNull(raw) {
		return nil
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		// Not a JSON object — leave the typed decode to surface the parse error.
		return nil
	}
	for _, key := range entityListKeys {
		v, ok := top[key]
		if !ok || isJSONNull(v) {
			continue
		}
		var items []json.RawMessage
		if err := json.Unmarshal(v, &items); err != nil {
			return fmt.Errorf("invalid_board_structure: %q must be a list", key)
		}
		for idx, item := range items {
			if isJSONNull(item) {
				return fmt.Errorf("invalid_board_structure: %q[%d] is a null item", key, idx)
			}
		}
	}
	return probeJSONDesignRules(top["design_rules"])
}

// probeJSONDesignRules is the JSON-side sibling of the design-rule type probe
// in UnmarshalYAML: a zone-fill minimum that is not a JSON number gets the
// shared invalid_design_rule code rather than encoding/json's own decode
// error. A null value is "unset"; a design_rules that is not an object is left
// to the typed decode, which owns that shape.
func probeJSONDesignRules(raw json.RawMessage) error {
	if raw == nil || isJSONNull(raw) {
		return nil
	}
	var rules map[string]json.RawMessage
	if err := json.Unmarshal(raw, &rules); err != nil {
		return nil
	}
	for _, key := range designRuleNumKeys {
		v, ok := rules[key]
		if !ok || isJSONNull(v) {
			continue
		}
		// Decode as a bare value and demand a number TOKEN: json.Number on
		// its own would also accept a quoted numeric string ("0.15").
		dec := json.NewDecoder(bytes.NewReader(v))
		dec.UseNumber()
		var any interface{}
		if err := dec.Decode(&any); err != nil {
			return fmt.Errorf("invalid_design_rule: design_rules.%s must be a number", key)
		}
		if _, isNumber := any.(json.Number); !isNumber {
			return fmt.Errorf("invalid_design_rule: design_rules.%s must be a number", key)
		}
	}
	return nil
}
