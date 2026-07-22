// Package board — deterministic JSON marshalers that INLINE each struct's
// `Extra` map (forward-compat unmodeled fields) into the JSON object.
//
// # Why this file exists (finding 019f8b7fbbd7)
//
// Every Extra field is tagged `json:"-"` (board.go) because encoding/json has no
// native inline support. That made the Board contract's "unknown fields survive
// losslessly" promise TRUE for the direct Go YAML→Board→YAML path (yaml.v3 honors
// `yaml:",inline"`) but FALSE across the real plugin IPC round trip: pcb.deserialize
// returns `{"board": b}` via encoding/json, silently STRIPPING every Extra key
// before the host sees the board, and a later pcb.serialize rebuilds Board from
// that already-lossy JSON — the extras are gone.
//
// Fix (owner choice a): custom MarshalJSON/UnmarshalJSON on the 9 Extra-bearing
// structs that inline Extra into the JSON object, so the JSON boundary is as
// lossless as the YAML one. YAML behavior is unchanged — the `yaml:",inline"` tag
// still governs YAML; these methods add nothing to that path.
//
// # Invariants
//
//   - Modeled fields ALWAYS win: an Extra key equal to a modeled json tag is
//     dropped, never emitted twice and never allowed to clobber the modeled value.
//   - Deterministic output: the merged object is built as a map and marshaled by
//     encoding/json, which sorts map keys lexically — byte-identical every time.
//   - Extra is set to nil (not an empty map) when a decoded object has no unknown
//     keys, so an extra-free struct stays extra-free.
//   - Nesting composes for free: each nested struct carries its own methods, so
//     encoding/json invokes them recursively — no hand-rolled nested handling.
//
// The 9 method pairs are thin wrappers over three shared helpers
// (knownJSONKeys / mergeExtra / splitExtra) — DRY is a review gate here.
package board

import (
	"encoding/json"
	"reflect"
	"strings"
	"sync"
)

// knownKeyCache memoizes the modeled-json-tag set per struct type so reflection
// runs once per type, not once per marshal.
var knownKeyCache sync.Map // reflect.Type -> map[string]bool

// knownJSONKeys returns the set of json tag names modeled on struct type t
// (the ",omitempty" suffix stripped, `json:"-"` fields — including Extra — and
// untagged fields skipped). This is the single source of truth for "which keys
// belong to a modeled field", used by both the collision guard on marshal and
// the split on unmarshal, so the 9 structs never hand-maintain key lists.
func knownJSONKeys(t reflect.Type) map[string]bool {
	if v, ok := knownKeyCache.Load(t); ok {
		return v.(map[string]bool)
	}
	keys := make(map[string]bool)
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		if f.PkgPath != "" {
			continue // unexported field: encoding/json never marshals it
		}
		tag := f.Tag.Get("json")
		name := strings.Split(tag, ",")[0]
		if name == "-" {
			continue // json:"-" (e.g. Extra): not marshaled, must not be a known key
		}
		if name == "" {
			// Untagged, or a name-less `,omitempty`: encoding/json emits the field
			// under its Go field NAME, so it IS a modeled key. Without this a future
			// untagged exported field would silently leak into Extra and double-emit
			// (Fable W4 note 1).
			keys[f.Name] = true
			continue
		}
		keys[name] = true
	}
	knownKeyCache.Store(t, keys)
	return keys
}

// mergeExtra merges the Extra map into an already-marshaled base object,
// producing deterministic bytes. A key that names a modeled field (in known) or
// is already present in base is dropped — the modeled field always wins. Output
// is a marshaled map[string]json.RawMessage, whose keys encoding/json sorts
// lexically, guaranteeing byte-identical results across calls.
func mergeExtra(base []byte, extra map[string]interface{}, known map[string]bool) ([]byte, error) {
	if len(extra) == 0 {
		return base, nil
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(base, &obj); err != nil {
		return nil, err
	}
	for k, v := range extra {
		if known[k] {
			continue // modeled key wins — never let Extra clobber it
		}
		if _, exists := obj[k]; exists {
			continue
		}
		raw, err := json.Marshal(v)
		if err != nil {
			return nil, err
		}
		obj[k] = raw
	}
	return json.Marshal(obj)
}

// splitExtra decodes data as a JSON object and returns every key that is NOT a
// modeled json tag, decoded to interface{}. Returns nil (not an empty map) when
// no unknown keys are present, so an extra-free struct keeps a nil Extra.
func splitExtra(data []byte, known map[string]bool) (map[string]interface{}, error) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(data, &obj); err != nil {
		return nil, err
	}
	var extra map[string]interface{}
	for k, raw := range obj {
		if known[k] {
			continue
		}
		var v interface{}
		if err := json.Unmarshal(raw, &v); err != nil {
			return nil, err
		}
		if extra == nil {
			extra = make(map[string]interface{})
		}
		extra[k] = v
	}
	return extra, nil
}

// --- Board ---

func (b Board) MarshalJSON() ([]byte, error) {
	type alias Board // an alias has no methods → no infinite recursion
	base, err := json.Marshal(alias(b))
	if err != nil {
		return nil, err
	}
	return mergeExtra(base, b.Extra, knownJSONKeys(reflect.TypeOf(Board{})))
}

func (b *Board) UnmarshalJSON(data []byte) error {
	type alias Board
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	*b = Board(a)
	extra, err := splitExtra(data, knownJSONKeys(reflect.TypeOf(Board{})))
	if err != nil {
		return err
	}
	b.Extra = extra
	return nil
}

// --- DesignRules ---

func (d DesignRules) MarshalJSON() ([]byte, error) {
	type alias DesignRules
	base, err := json.Marshal(alias(d))
	if err != nil {
		return nil, err
	}
	return mergeExtra(base, d.Extra, knownJSONKeys(reflect.TypeOf(DesignRules{})))
}

func (d *DesignRules) UnmarshalJSON(data []byte) error {
	type alias DesignRules
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	*d = DesignRules(a)
	extra, err := splitExtra(data, knownJSONKeys(reflect.TypeOf(DesignRules{})))
	if err != nil {
		return err
	}
	d.Extra = extra
	return nil
}

// --- Component ---

func (c Component) MarshalJSON() ([]byte, error) {
	type alias Component
	base, err := json.Marshal(alias(c))
	if err != nil {
		return nil, err
	}
	return mergeExtra(base, c.Extra, knownJSONKeys(reflect.TypeOf(Component{})))
}

func (c *Component) UnmarshalJSON(data []byte) error {
	type alias Component
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	*c = Component(a)
	extra, err := splitExtra(data, knownJSONKeys(reflect.TypeOf(Component{})))
	if err != nil {
		return err
	}
	c.Extra = extra
	return nil
}

// --- Pin ---

func (p Pin) MarshalJSON() ([]byte, error) {
	type alias Pin
	base, err := json.Marshal(alias(p))
	if err != nil {
		return nil, err
	}
	return mergeExtra(base, p.Extra, knownJSONKeys(reflect.TypeOf(Pin{})))
}

func (p *Pin) UnmarshalJSON(data []byte) error {
	type alias Pin
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	*p = Pin(a)
	extra, err := splitExtra(data, knownJSONKeys(reflect.TypeOf(Pin{})))
	if err != nil {
		return err
	}
	p.Extra = extra
	return nil
}

// --- PinOverride ---

func (o PinOverride) MarshalJSON() ([]byte, error) {
	type alias PinOverride
	base, err := json.Marshal(alias(o))
	if err != nil {
		return nil, err
	}
	return mergeExtra(base, o.Extra, knownJSONKeys(reflect.TypeOf(PinOverride{})))
}

func (o *PinOverride) UnmarshalJSON(data []byte) error {
	type alias PinOverride
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	*o = PinOverride(a)
	extra, err := splitExtra(data, knownJSONKeys(reflect.TypeOf(PinOverride{})))
	if err != nil {
		return err
	}
	o.Extra = extra
	return nil
}

// --- Hole ---

func (h Hole) MarshalJSON() ([]byte, error) {
	type alias Hole
	base, err := json.Marshal(alias(h))
	if err != nil {
		return nil, err
	}
	return mergeExtra(base, h.Extra, knownJSONKeys(reflect.TypeOf(Hole{})))
}

func (h *Hole) UnmarshalJSON(data []byte) error {
	type alias Hole
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	*h = Hole(a)
	extra, err := splitExtra(data, knownJSONKeys(reflect.TypeOf(Hole{})))
	if err != nil {
		return err
	}
	h.Extra = extra
	return nil
}

// --- Net ---

func (n Net) MarshalJSON() ([]byte, error) {
	type alias Net
	base, err := json.Marshal(alias(n))
	if err != nil {
		return nil, err
	}
	return mergeExtra(base, n.Extra, knownJSONKeys(reflect.TypeOf(Net{})))
}

func (n *Net) UnmarshalJSON(data []byte) error {
	type alias Net
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	*n = Net(a)
	extra, err := splitExtra(data, knownJSONKeys(reflect.TypeOf(Net{})))
	if err != nil {
		return err
	}
	n.Extra = extra
	return nil
}

// --- Trace ---

func (t Trace) MarshalJSON() ([]byte, error) {
	type alias Trace
	base, err := json.Marshal(alias(t))
	if err != nil {
		return nil, err
	}
	return mergeExtra(base, t.Extra, knownJSONKeys(reflect.TypeOf(Trace{})))
}

func (t *Trace) UnmarshalJSON(data []byte) error {
	type alias Trace
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	*t = Trace(a)
	extra, err := splitExtra(data, knownJSONKeys(reflect.TypeOf(Trace{})))
	if err != nil {
		return err
	}
	t.Extra = extra
	return nil
}

// --- Via ---

func (v Via) MarshalJSON() ([]byte, error) {
	type alias Via
	base, err := json.Marshal(alias(v))
	if err != nil {
		return nil, err
	}
	return mergeExtra(base, v.Extra, knownJSONKeys(reflect.TypeOf(Via{})))
}

func (v *Via) UnmarshalJSON(data []byte) error {
	type alias Via
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	*v = Via(a)
	extra, err := splitExtra(data, knownJSONKeys(reflect.TypeOf(Via{})))
	if err != nil {
		return err
	}
	v.Extra = extra
	return nil
}
