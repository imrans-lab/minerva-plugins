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
//   - a declared layer stack names only canonical copper layers, in stack
//     order, with no duplicates and no gaps. See validateLayers;
//   - every zone (v1 or v2 — this rule is NOT version-gated, unlike identity)
//     has a structurally valid outline and names a net/layer that exists. See
//     validateZones.
//
// The error codes (unsupported_schema_version, unminted_persistent_id,
// duplicate_persistent_id) are the SAME strings the Python compiler and
// validator emit, so a vector's expected code matches verbatim on both sides.
// The layer-stack codes (invalid_layer_name, duplicate_layer,
// incomplete_layer_stack, invalid_layer_stack_order) are likewise mirrored
// verbatim by board_validate.py's _check_layers — unlike the zone codes below,
// they went in on both sides in the same change (epoch 6 unit 3a).
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
	// Layers BEFORE zones: a zone's layer is checked for MEMBERSHIP in the
	// declared stack, so validating the stack itself first means a board with a
	// broken stack reports the stack error rather than a confusing
	// zone_unknown_layer derived from it.
	if err := validateLayers(b); err != nil {
		return err
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

// MaxInnerLayers caps the canonical inner-copper range at KiCad's own copper
// stack: 32 layers = F.Cu + In1.Cu..In30.Cu + B.Cu. Every canonical name this
// contract accepts therefore HAS a KiCad alias. Mirrored by MAX_INNER_LAYERS in
// worker/agent_router/layers.py and ui/model/pcb_layer_stack.gd.
const MaxInnerLayers = 30

// innerLayerIndex returns k for the canonical inner-copper layer name "in<k>",
// and 0 for anything else. k must be 1..MaxInnerLayers and written WITHOUT a
// leading zero ("in01" is not a layer): one layer, one spelling, so a declared
// name can never compare unequal to itself when a zone or trace references it.
func innerLayerIndex(name string) int {
	if len(name) < 3 || name[:2] != "in" {
		return 0
	}
	digits := name[2:]
	if digits[0] == '0' {
		return 0
	}
	k := 0
	for i := 0; i < len(digits); i++ {
		c := digits[i]
		if c < '0' || c > '9' {
			return 0
		}
		k = k*10 + int(c-'0')
		if k > MaxInnerLayers {
			return 0
		}
	}
	return k
}

// validateLayers enforces the canonical copper-stack contract on an OPTIONAL
// `layers` list. A board that declares none is untouched (the historical
// default is a 2-layer top/bottom board, and nothing here invents one).
//
// The rules, and why the list is not merely a set:
//
//   - The list ORDER *IS* the physical stack order — top first, bottom last,
//     inners in index order between them. Nothing in the codec sorts or dedupes
//     it, so the authored order is what every consumer sees; a stack listed out
//     of order is a different board, not the same board written differently.
//   - Names are canonical copper ids only: "top", "bottom", "in1".."in30"
//     (KiCad F.Cu / B.Cu / In<k>.Cu — see worker/agent_router/layers.py, the
//     canon<->KiCad source of truth). "inner1", "F.Cu" and "Edge.Cuts" are not
//     canonical stack entries.
//   - Inners must be CONTIGUOUS from in1. A gap ("in1, in3") would assert a
//     physical layer that the board refuses to name, and it would make the
//     KiCad alias of the layer BELOW the gap ambiguous — In3.Cu by name but the
//     second inner by position. Contiguity is what keeps name and position the
//     same fact.
//
// Inner layers are AUTHORABLE, NOT FABRICABLE: this validator accepts a 4-layer
// stack, and the Python compiler still refuses to build anything but exactly
// ["top","bottom"] (compile_board._require_two_layer), exactly as zones are
// authorable-and-refused. See docs/board-yaml.md "Layer stack".
func validateLayers(b *Board) error {
	if len(b.Layers) == 0 {
		return nil
	}
	seen := make(map[string]int, len(b.Layers))
	for i, l := range b.Layers {
		if l != "top" && l != "bottom" && innerLayerIndex(l) == 0 {
			return fmt.Errorf("invalid_layer_name: layers[%d] %q is not a canonical copper layer (want \"top\", \"bottom\", or \"in<k>\" with 1 <= k <= %d)", i, l, MaxInnerLayers)
		}
		if j, ok := seen[l]; ok {
			return fmt.Errorf("duplicate_layer: layers[%d] %q duplicates layers[%d]", i, l, j)
		}
		seen[l] = i
	}
	if _, ok := seen["top"]; !ok {
		return fmt.Errorf("incomplete_layer_stack: declared layers %v have no \"top\" layer", b.Layers)
	}
	if _, ok := seen["bottom"]; !ok {
		return fmt.Errorf("incomplete_layer_stack: declared layers %v have no \"bottom\" layer", b.Layers)
	}
	// Both outer layers are present and unique, so the list is at least 2 long
	// and the slice below is safe.
	if b.Layers[0] != "top" {
		return fmt.Errorf("invalid_layer_stack_order: layers[0] is %q, but the list order is the stack order and must start at \"top\"", b.Layers[0])
	}
	last := len(b.Layers) - 1
	if b.Layers[last] != "bottom" {
		return fmt.Errorf("invalid_layer_stack_order: layers[%d] is %q, but the list order is the stack order and must end at \"bottom\"", last, b.Layers[last])
	}
	for i, l := range b.Layers[1:last] {
		want := fmt.Sprintf("in%d", i+1)
		if l != want {
			return fmt.Errorf("invalid_layer_stack_order: layers[%d] is %q, want %q — inner layers are contiguous from \"in1\" in stack order", i+1, l, want)
		}
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
