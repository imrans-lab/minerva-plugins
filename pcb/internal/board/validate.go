// Package board — shared canonical-board validation boundary.
//
// Validate is the schema-level gate the Go codec and the Python compiler must
// enforce IDENTICALLY (item 019f802ca3af, comment 629 — "K3 must not consume a
// v2 board through independently drifting validators"). It operates on a parsed
// Board and does NOT resolve footprints or geometry — that is the Python
// compiler's job. The committed cross-language vectors in pcb/spec/vectors/
// exercise this exact boundary on both sides; pcb/spec/board-v2.md is the human
// spec. The Python mirror is pcb/worker/pcb_worker/board_validate.py.
//
// Note on pin overrides: the Go codec rejects a malformed typed override at
// UNMARSHAL (a wrong-typed field cannot decode into PinOverride's pointer
// fields), so a Board that parses already has type-valid overrides. The Python
// mirror, parsing an untyped dict, re-checks override field types explicitly so
// the same vector is rejected on both sides.
package board

import "fmt"

// Validate enforces the shared boundary on a parsed Board:
//   - schema version must be 1 or 2;
//   - a v2 board carries a minted persistent id ("<kind>:<32 lowercase hex>") on
//     the board and on every trace/via/hole/zone. v1 has NO id requirement — it
//     is the ordinal-bridge era, before identity was minted;
//   - every zone (v1 or v2 — this rule is NOT version-gated, unlike identity)
//     has a structurally valid outline and names a net/layer that exists. See
//     validateZones.
//
// The error codes (unsupported_schema_version, unminted_persistent_id,
// duplicate_persistent_id) are the SAME strings the Python compiler and
// validator emit, so a vector's expected code matches verbatim on both sides.
// The zone-structural codes (invalid_zone_outline, zone_unknown_net,
// zone_unknown_layer) are NOT yet cross-checked against Python: the Python
// compiler refuses a board that declares one or more zones
// (compile_board.py:1836 — presence-AND-non-empty; `zones: []`/`zones: null`
// are skipped there) rather than validating zone content, so there is no
// Python-side zone validator yet to match strings with. The zone IDENTITY codes
// are Go-only for the same reason: board_validate.py's entity tuple does not
// include zones, so Go validates zone ids more eagerly than Python does. That
// asymmetry is fail-closed in the safe direction, but it is an asymmetry. A
// future round that teaches Python to accept zones should reuse these exact
// strings rather than inventing new ones, and should add zones to that tuple.
func Validate(b *Board) error {
	if b.Version != 1 && b.Version != 2 {
		return fmt.Errorf("unsupported_schema_version: version %d (want 1 or 2)", b.Version)
	}
	if err := validateZones(b); err != nil {
		return err
	}
	if b.Version < 2 {
		return nil
	}
	if !isMintedID("board", b.ID) {
		return fmt.Errorf("unminted_persistent_id: board id %q is not a minted \"board:<32hex>\" id", b.ID)
	}
	// Persistent ids must be minted AND unique WITHIN each entity domain. The
	// board id is global (a single value); trace/via/hole ids are unique among
	// their own kind. Uniqueness is per-domain, so trace:<hex> and via:<hex>
	// sharing a hex tail are DISTINCT ids (different prefixes) and both valid.
	// duplicate_persistent_id is the shared code the Python validator emits too
	// (finding 019f8b7fb07e, part 2).
	seenTrace := make(map[string]int, len(b.Traces))
	for i := range b.Traces {
		id := b.Traces[i].ID
		if !isMintedID("trace", id) {
			return fmt.Errorf("unminted_persistent_id: trace[%d] id %q is not minted", i, id)
		}
		if j, ok := seenTrace[id]; ok {
			return fmt.Errorf("duplicate_persistent_id: trace[%d] id %q duplicates trace[%d]", i, id, j)
		}
		seenTrace[id] = i
	}
	seenVia := make(map[string]int, len(b.Vias))
	for i := range b.Vias {
		id := b.Vias[i].ID
		if !isMintedID("via", id) {
			return fmt.Errorf("unminted_persistent_id: via[%d] id %q is not minted", i, id)
		}
		if j, ok := seenVia[id]; ok {
			return fmt.Errorf("duplicate_persistent_id: via[%d] id %q duplicates via[%d]", i, id, j)
		}
		seenVia[id] = i
	}
	seenHole := make(map[string]int, len(b.MountingHoles))
	for i := range b.MountingHoles {
		id := b.MountingHoles[i].ID
		if !isMintedID("hole", id) {
			return fmt.Errorf("unminted_persistent_id: hole[%d] id %q is not minted", i, id)
		}
		if j, ok := seenHole[id]; ok {
			return fmt.Errorf("duplicate_persistent_id: hole[%d] id %q duplicates hole[%d]", i, id, j)
		}
		seenHole[id] = i
	}
	seenZone := make(map[string]int, len(b.Zones))
	for i := range b.Zones {
		id := b.Zones[i].ID
		if !isMintedID("zone", id) {
			return fmt.Errorf("unminted_persistent_id: zone[%d] id %q is not minted", i, id)
		}
		if j, ok := seenZone[id]; ok {
			return fmt.Errorf("duplicate_persistent_id: zone[%d] id %q duplicates zone[%d]", i, id, j)
		}
		seenZone[id] = i
	}
	return nil
}

// validateZones enforces zone-specific structural rules that apply regardless
// of schema version (unlike the v2-only identity checks above, which have
// nothing to check on a v1 board): an authored outline must actually describe
// a polygon, and a zone's net/layer must reference something the board
// actually declares. This is new validation introduced with the Zone type
// itself — there is no pre-existing "a trace's net/layer must exist" check in
// this function to mirror, so this deliberately holds zones to a stricter bar
// than the entities already here.
func validateZones(b *Board) error {
	if len(b.Zones) == 0 {
		return nil
	}
	netNames := make(map[string]bool, len(b.Nets))
	for _, n := range b.Nets {
		netNames[n.Name] = true
	}
	knownLayers := make(map[string]bool, len(b.Layers))
	for _, l := range b.Layers {
		knownLayers[l] = true
	}
	for i, z := range b.Zones {
		if len(z.Outline) < 3 {
			return fmt.Errorf("invalid_zone_outline: zone[%d] outline has %d point(s), a polygon needs at least 3", i, len(z.Outline))
		}
		if z.Net == "" || !netNames[z.Net] {
			return fmt.Errorf("zone_unknown_net: zone[%d] net %q is not a declared net", i, z.Net)
		}
		if z.Layer == "" {
			return fmt.Errorf("zone_unknown_layer: zone[%d] names no layer", i)
		}
		// Only checked against the declared stack when the board declares one
		// at all (Board.Layers is optional) — a board with no explicit layer
		// list has nothing to validate a zone's layer name against.
		if len(b.Layers) > 0 && !knownLayers[z.Layer] {
			return fmt.Errorf("zone_unknown_layer: zone[%d] layer %q is not in the declared layer stack", i, z.Layer)
		}
	}
	return nil
}
