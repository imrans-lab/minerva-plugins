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
//     the board and on every trace/via/hole. v1 has NO id requirement — it is the
//     ordinal-bridge era, before identity was minted.
//
// The error codes (unsupported_schema_version, unminted_persistent_id,
// duplicate_persistent_id) are the SAME strings the Python compiler and
// validator emit, so a vector's expected code matches verbatim on both sides.
func Validate(b *Board) error {
	if b.Version != 1 && b.Version != 2 {
		return fmt.Errorf("unsupported_schema_version: version %d (want 1 or 2)", b.Version)
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
	return nil
}
