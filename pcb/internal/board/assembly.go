// Package board — the per-component assembly block.
//
// `assembly` describes what an assembly house has to BUY and PLACE for a
// component: whether it is populated at all, what part it is, which house
// catalogue number stands for it, whether its lands get paste, and — for a
// synthetic component that stands for several identical physical parts — the
// designators those parts are actually placed under and, where the drawing's
// own body centre is not each part's, where each part's centre sits.
//
// # Two authored forms, one model
//
// The block was originally a bare scalar, `assembly: exclude`, marking board
// FURNITURE (a fiducial, a silk logo) that must never reach a BOM or CPL row.
// Boards in the field still carry it. The scalar is accepted by BOTH codecs and
// MIGRATED on the spot to the structured non-populated state (`populate:
// false`), so exactly one shape reaches every reader downstream and no consumer
// has to branch on the authored form. A migrated board re-emits in the
// structured form the next time it is serialized; that rewrite IS the
// migration.
//
// # Why the codecs are hand-written
//
//   - the legacy scalar has to decode into a struct, which neither codec does
//     on its own;
//   - unknown sub-keys REFUSE rather than being dropped. This block is the sole
//     source of part identity for an order, so `mpm: C123` silently vanishing
//     and reappearing later as "missing mpn" — or a mistyped `offset_mm` key
//     quietly placing a part at (0, 0) — is precisely the class of quiet wrong
//     answer the whole order path is built to refuse. The known-key set is
//     derived reflectively from the struct tags (knownJSONKeys, json.go), so a
//     field added below is known to both codecs with no list to hand-maintain.
//
// There is deliberately no inline `Extra` here, and therefore no marshal/
// unmarshal pair in json.go: an Extra map tagged `json:"-"` round-trips through
// YAML but vanishes across the JSON IPC boundary (json.go's opening comment),
// and a half-preserved order block is worse than a refused unknown key.
package board

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// assemblyErrCode is the shared refusal code every shape violation in this
// block carries, so a caller can recognize one without matching prose.
const assemblyErrCode = "invalid_component_assembly"

// LegacyAssemblyExclude is the pre-block scalar form of "this component is
// board furniture": no BOM row, no CPL row, no part identity required.
const LegacyAssemblyExclude = "exclude"

// Paste tokens. `auto` (the default when the key is absent) lets the compiler
// decide from the land type; `include` / `exclude` are the author overriding it.
const (
	PasteAuto    = "auto"
	PasteInclude = "include"
	PasteExclude = "exclude"
)

// ComponentAssembly is the order/assembly description of one component.
//
// Every field is optional at the CODEC boundary — a board mid-layout has not
// chosen its parts yet and must still load, serialize and route. What an
// assembly EXPORT requires is a separate, later gate that refuses by name; this
// type's job is to carry the author's answer losslessly, not to demand one.
type ComponentAssembly struct {
	// Populate is a POINTER because absent, true and false are three states
	// that must not collapse: absent means "nothing authored, assume it is
	// populated", and a plain bool with omitempty would marshal an authored
	// `false` away — turning a DNP part back into a populated one on the next
	// round trip. Same reasoning as DesignRules' zone minima.
	Populate     *bool  `json:"populate,omitempty" yaml:"populate,omitempty"`
	Manufacturer string `json:"manufacturer,omitempty" yaml:"manufacturer,omitempty"`
	MPN          string `json:"mpn,omitempty" yaml:"mpn,omitempty"`
	Package      string `json:"package,omitempty" yaml:"package,omitempty"`
	Comment      string `json:"comment,omitempty" yaml:"comment,omitempty"`

	// HouseParts maps a house id ("jlcpcb") to that house's catalogue number.
	// Keyed rather than a bare `lcsc` scalar so a second house is a new entry,
	// not a new field, and so a board states WHOSE number it is carrying.
	HouseParts map[string]string `json:"house_parts,omitempty" yaml:"house_parts,omitempty"`

	Paste string `json:"paste,omitempty" yaml:"paste,omitempty"`

	// Placements expands ONE authored component into the several identical
	// physical parts it stands for (a socket strip drawn once, soldered twice).
	// Absent means the ordinary case: one placement, at the component's own
	// position, under the component's own ref. The refs here are AUTHORED and
	// must be stable and unique board-wide — an exporter that invented them
	// would rename a part between two orders of the same design.
	//
	// A POINTER, for the same reason Populate is: absent and authored-empty are
	// two states that must not collapse. `placements: []` says "this drawing
	// stands for several parts" and then names none, which the export gate
	// refuses by name (assembly_empty_expansion); a plain slice with omitempty
	// would re-serialize that key away, so a board that had been through this
	// codec would export as an ordinary one-part component instead. Nil omits
	// the key, a non-nil pointer emits it — including when it points at an
	// empty list.
	Placements *[]AssemblyPlacement `json:"placements,omitempty" yaml:"placements,omitempty"`
}

// AssemblyPlacement is one physically placed instance of a component.
type AssemblyPlacement struct {
	Ref string `json:"ref" yaml:"ref"`
	// OffsetMM is measured in the PARENT COMPONENT's local frame, before the
	// parent's own rotation and side are applied. A pointer so an absent key
	// stays absent through both codecs rather than emitting a zero offset.
	OffsetMM *AssemblyOffset `json:"offset_mm,omitempty" yaml:"offset_mm,omitempty"`
	// AnchorMM is where THIS part's body centre sits relative to THIS
	// placement's own origin — the point a nozzle is told to centre on. Absent,
	// the compiler measures one anchor off the parent footprint and every
	// expanded part inherits it, which is only right when the drawing is the
	// part. A drawing that stands for several parts spread across it has one
	// body centre per part and none of them is the parent's, so each placement
	// states its own.
	//
	// Same frame as OffsetMM's result: the placement's local millimetres,
	// before the parent's rotation and side, which the compiler then composes.
	// A pointer for the same reason OffsetMM is one — an authored anchor of
	// (0, 0) is a real answer and must not re-serialize as an absent key.
	AnchorMM    *AssemblyOffset `json:"anchor_mm,omitempty" yaml:"anchor_mm,omitempty"`
	RotationDeg float64         `json:"rotation_deg,omitempty" yaml:"rotation_deg,omitempty"`
}

// AssemblyOffset is a millimetre point on a placement — the shape both
// `offset_mm` and `anchor_mm` take. The unit rides the KEY rather than each
// member, so the members are the bare axes. A Go unmarshaler is handed a value
// and not the key it hung under, so the refusals below name the pair of keys
// this shape serves rather than guessing at one of them.
type AssemblyOffset struct {
	X float64 `json:"x" yaml:"x"`
	Y float64 `json:"y" yaml:"y"`
}

// assemblyPointWhat labels this shape in a refusal. Both placement keys decode
// through the same type, so the label names both.
const assemblyPointWhat = "assembly placement point (offset_mm / anchor_mm)"

// UnmarshalYAML carries the block's unknown-key refusal INSIDE the point. A
// mistyped axis (`{xx: 22.86, y: 0}`) would otherwise leave x at its zero value
// and place the expanded part at its parent's origin — the same quiet wrong
// answer refusing an unknown outer key exists to prevent, one level down.
func (o *AssemblyOffset) UnmarshalYAML(node *yaml.Node) error {
	n := resolveAlias(node)
	if n == nil || n.Tag == "!!null" {
		return nil
	}
	if n.Kind != yaml.MappingNode {
		return fmt.Errorf(assemblyErrCode + ": " + assemblyPointWhat + " must be a mapping of x/y millimetres")
	}
	if err := refuseUnknownKeys(yamlMappingKeys(n), reflect.TypeOf(AssemblyOffset{}), assemblyPointWhat); err != nil {
		return err
	}
	type plain AssemblyOffset
	var q plain
	if err := n.Decode(&q); err != nil {
		return wrapAssemblyErr(err)
	}
	*o = AssemblyOffset(q)
	return nil
}

// UnmarshalJSON is the point's IPC-boundary twin of UnmarshalYAML.
func (o *AssemblyOffset) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &raw); err != nil {
		return fmt.Errorf(assemblyErrCode+": "+assemblyPointWhat+" must be an object of x/y millimetres: %w", err)
	}
	if err := refuseUnknownKeys(jsonObjectKeys(raw), reflect.TypeOf(AssemblyOffset{}), assemblyPointWhat); err != nil {
		return err
	}
	type plain AssemblyOffset
	var q plain
	if err := json.Unmarshal(trimmed, &q); err != nil {
		return wrapAssemblyErr(err)
	}
	*o = AssemblyOffset(q)
	return nil
}

// Populated reports whether this component is picked and placed. Nil-safe: a
// component with no assembly block at all is populated, which is what keeps a
// board that predates the block loading exactly as it always did.
func (a *ComponentAssembly) Populated() bool {
	if a == nil || a.Populate == nil {
		return true
	}
	return *a.Populate
}

// PlacementList is the authored expansion as a plain slice, nil-safe. Callers
// that only walk the placements use this; callers that have to tell an absent
// key from an authored-empty one read ExpansionAuthored instead.
func (a *ComponentAssembly) PlacementList() []AssemblyPlacement {
	if a == nil || a.Placements == nil {
		return nil
	}
	return *a.Placements
}

// ExpansionAuthored reports whether a `placements` LIST was authored at all,
// whatever its length — the distinction the pointer field exists to keep.
func (a *ComponentAssembly) ExpansionAuthored() bool {
	return a != nil && a.Placements != nil
}

// EmittedRefs returns the designators this component actually contributes to an
// assembly output: its placements' refs, or its own ref when it has none. An
// authored-empty expansion names the component's own ref here, which is exactly
// why the export gate refuses it rather than trusting this answer.
func (c *Component) EmittedRefs() []string {
	placements := c.Assembly.PlacementList()
	if len(placements) == 0 {
		return []string{c.Ref}
	}
	refs := make([]string, 0, len(placements))
	for _, p := range placements {
		refs = append(refs, p.Ref)
	}
	return refs
}

// fromLegacyScalar migrates the pre-block `assembly: exclude` form. Any other
// scalar refuses: a typo ("exlcude") reading as "not excluded" would land a
// fiducial in a BOM with a fabricated part number.
func (a *ComponentAssembly) fromLegacyScalar(v string) error {
	if v != LegacyAssemblyExclude {
		return fmt.Errorf(assemblyErrCode+": scalar assembly must be %q "+
			"(the pre-block furniture form, migrated to populate: false), got %q",
			LegacyAssemblyExclude, v)
	}
	no := false
	*a = ComponentAssembly{Populate: &no}
	return nil
}

// UnmarshalYAML accepts the mapping form and the legacy scalar.
func (a *ComponentAssembly) UnmarshalYAML(node *yaml.Node) error {
	n := resolveAlias(node)
	switch {
	case n == nil || n.Tag == "!!null":
		return nil
	case n.Kind == yaml.ScalarNode:
		return a.fromLegacyScalar(n.Value)
	case n.Kind != yaml.MappingNode:
		return fmt.Errorf(assemblyErrCode+": assembly must be a mapping "+
			"or the legacy %q scalar", LegacyAssemblyExclude)
	}
	if err := refuseUnknownKeys(yamlMappingKeys(n), reflect.TypeOf(ComponentAssembly{}), "assembly"); err != nil {
		return err
	}
	type plain ComponentAssembly
	var p plain
	if err := n.Decode(&p); err != nil {
		return wrapAssemblyErr(err)
	}
	*a = ComponentAssembly(p)
	return nil
}

// UnmarshalJSON is the IPC-boundary twin of UnmarshalYAML: the panel forwards
// whatever a board load produced, so the legacy scalar reaches this side too.
func (a *ComponentAssembly) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil
	}
	if trimmed[0] == '"' {
		var s string
		if err := json.Unmarshal(trimmed, &s); err != nil {
			return wrapAssemblyErr(err)
		}
		return a.fromLegacyScalar(s)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &raw); err != nil {
		return fmt.Errorf(assemblyErrCode+": assembly must be an object "+
			"or the legacy %q string: %w", LegacyAssemblyExclude, err)
	}
	if err := refuseUnknownKeys(jsonObjectKeys(raw), reflect.TypeOf(ComponentAssembly{}), "assembly"); err != nil {
		return err
	}
	type plain ComponentAssembly
	var p plain
	if err := json.Unmarshal(trimmed, &p); err != nil {
		return wrapAssemblyErr(err)
	}
	*a = ComponentAssembly(p)
	return nil
}

// UnmarshalYAML refuses an unknown placement key rather than dropping it — a
// mistyped `offset_mm` would otherwise place the part at the parent's origin.
func (p *AssemblyPlacement) UnmarshalYAML(node *yaml.Node) error {
	n := resolveAlias(node)
	if n == nil || n.Tag == "!!null" {
		return nil
	}
	if n.Kind != yaml.MappingNode {
		return fmt.Errorf(assemblyErrCode + ": assembly placement must be a mapping")
	}
	if err := refuseUnknownKeys(yamlMappingKeys(n), reflect.TypeOf(AssemblyPlacement{}), "assembly placement"); err != nil {
		return err
	}
	type plain AssemblyPlacement
	var q plain
	if err := n.Decode(&q); err != nil {
		return wrapAssemblyErr(err)
	}
	*p = AssemblyPlacement(q)
	return nil
}

// UnmarshalJSON is the placement's IPC-boundary twin of UnmarshalYAML.
func (p *AssemblyPlacement) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &raw); err != nil {
		return fmt.Errorf(assemblyErrCode+": assembly placement must be an object: %w", err)
	}
	if err := refuseUnknownKeys(jsonObjectKeys(raw), reflect.TypeOf(AssemblyPlacement{}), "assembly placement"); err != nil {
		return err
	}
	type plain AssemblyPlacement
	var q plain
	if err := json.Unmarshal(trimmed, &q); err != nil {
		return wrapAssemblyErr(err)
	}
	*p = AssemblyPlacement(q)
	return nil
}

// wrapAssemblyErr tags a decode failure with the block's refusal code — unless
// it is already tagged, which it is whenever the failure came from a nested
// placement that refused for itself. Prefixing unconditionally would stutter the
// code twice through one message.
func wrapAssemblyErr(err error) error {
	if strings.Contains(err.Error(), assemblyErrCode) {
		return err
	}
	return fmt.Errorf("%s: %w", assemblyErrCode, err)
}

// yamlMappingKeys lists a mapping node's keys in document order.
func yamlMappingKeys(n *yaml.Node) []string {
	keys := make([]string, 0, len(n.Content)/2)
	for i := 0; i+1 < len(n.Content); i += 2 {
		keys = append(keys, n.Content[i].Value)
	}
	return keys
}

// jsonObjectKeys lists a decoded object's keys in a stable order — Go map
// iteration is randomized, and which unknown key gets NAMED in the refusal must
// not vary between two runs on the same input.
func jsonObjectKeys(raw map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(raw))
	for k := range raw {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// refuseUnknownKeys rejects the first key that names no modeled field of t. The
// modeled set comes from the json tags (knownJSONKeys), which the yaml tags
// mirror field-for-field on both assembly structs — one set, both codecs.
func refuseUnknownKeys(keys []string, t reflect.Type, what string) error {
	known := knownJSONKeys(t)
	for _, k := range keys {
		if !known[k] {
			return fmt.Errorf(assemblyErrCode+": unknown %s field %q", what, k)
		}
	}
	return nil
}

// validateComponentAssembly checks one component's block. Called from Validate.
func validateComponentAssembly(c *Component, i int) error {
	a := c.Assembly
	if a == nil {
		return nil
	}
	switch a.Paste {
	case "", PasteAuto, PasteInclude, PasteExclude:
	default:
		return fmt.Errorf("invalid_component: components[%d] (%s) assembly.paste must be "+
			"%q, %q or %q when present, got %q", i, c.Ref,
			PasteAuto, PasteInclude, PasteExclude, a.Paste)
	}
	for house, part := range a.HouseParts {
		if house == "" || part == "" {
			return fmt.Errorf("invalid_component: components[%d] (%s) assembly.house_parts "+
				"carries an empty house id or part number (%q: %q)", i, c.Ref, house, part)
		}
	}
	placements := a.PlacementList()
	for j := range placements {
		p := &placements[j]
		if p.Ref == "" {
			return fmt.Errorf("invalid_component: components[%d] (%s) assembly.placements[%d] "+
				"has no ref — expanded designators are AUTHORED, never invented", i, c.Ref, j)
		}
		if math.IsNaN(p.RotationDeg) || math.IsInf(p.RotationDeg, 0) {
			return fmt.Errorf("invalid_component: components[%d] (%s) assembly.placements[%d] (%s) "+
				"rotation_deg is not finite", i, c.Ref, j, p.Ref)
		}
		for _, pair := range []struct {
			key   string
			point *AssemblyOffset
		}{{"offset_mm", p.OffsetMM}, {"anchor_mm", p.AnchorMM}} {
			if pair.point == nil {
				continue
			}
			for _, v := range []float64{pair.point.X, pair.point.Y} {
				if math.IsNaN(v) || math.IsInf(v, 0) {
					return fmt.Errorf("invalid_component: components[%d] (%s) assembly.placements[%d] (%s) "+
						"%s is not finite", i, c.Ref, j, p.Ref, pair.key)
				}
			}
		}
	}
	return nil
}

// validatePlacementRefUniqueness refuses a board where two physical parts would
// be placed under one designator.
//
// SCOPED TO PLACEMENT REFS ON PURPOSE. Component `ref` uniqueness has never been
// checked here, and widening the check to cover it would refuse boards that load
// today — a behavior change this rule does not need. What it does cover: two
// placements sharing a ref, and a placement ref colliding with some OTHER
// component's ref. A placement that reuses its OWN component's ref is fine (a
// single-instance expansion authored explicitly).
func validatePlacementRefUniqueness(b *Board) error {
	owner := make(map[string]int, len(b.Components))
	for i := range b.Components {
		if _, seen := owner[b.Components[i].Ref]; !seen {
			owner[b.Components[i].Ref] = i
		}
	}
	placed := make(map[string]int)
	for i := range b.Components {
		c := &b.Components[i]
		if c.Assembly == nil {
			continue
		}
		placements := c.Assembly.PlacementList()
		for j := range placements {
			ref := placements[j].Ref
			if prev, seen := placed[ref]; seen {
				return fmt.Errorf("duplicate_assembly_designator: components[%d] (%s) "+
					"assembly.placements[%d] ref %q is already placed by components[%d] (%s)",
					i, c.Ref, j, ref, prev, b.Components[prev].Ref)
			}
			if k, seen := owner[ref]; seen && k != i {
				return fmt.Errorf("duplicate_assembly_designator: components[%d] (%s) "+
					"assembly.placements[%d] ref %q is already the ref of components[%d]",
					i, c.Ref, j, ref, k)
			}
			placed[ref] = i
		}
	}
	return nil
}
