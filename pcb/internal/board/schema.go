// Package board — the POSITIVE schema walk.
//
// Every key a document may carry names a field on one of the structs in
// board.go, and the two parse boundaries (UnmarshalYAML, ProbeJSONBoard) refuse
// the first key that names none, with the entity and the key spelled out. The
// known-key set is read off the struct tags reflectively, so a field added to a
// struct is known to both boundaries with no list to hand-maintain — the same
// mechanism the assembly block has always used (refuseUnknownKeys).
//
// A type that owns its own decoding (an UnmarshalYAML method — the assembly
// block and its sub-structs) owns its own refusals too, so the walk stops at
// it rather than reporting the same key twice under two codes.
//
// Blob-typed fields are opaque by declaration: the KEY is known here, the
// contents are the consumer's contract, and the walk does not descend into
// them.
package board

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"
)

// unknownKeyCode is the shared structural refusal code, the one the Python
// validator uses for the same class of document. Naming a key the schema does
// not have is a shape problem, not a value problem.
const unknownKeyCode = "invalid_board_structure"

// fieldsByTag maps a struct type's tag names (json or yaml, the ",omitempty"
// suffix stripped) to the field they name. Memoized per (type, tag): the walk
// runs on every parse, reflection once per type.
var fieldCache sync.Map // string(tag)+type -> map[string]reflect.StructField

func fieldsByTag(t reflect.Type, tag string) map[string]reflect.StructField {
	cacheKey := tag + ":" + t.String()
	if v, ok := fieldCache.Load(cacheKey); ok {
		return v.(map[string]reflect.StructField)
	}
	fields := make(map[string]reflect.StructField)
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		if f.PkgPath != "" {
			continue // unexported: no codec touches it
		}
		name := strings.Split(f.Tag.Get(tag), ",")[0]
		if name == "-" {
			continue
		}
		if name == "" {
			name = f.Name // untagged: encoding/json emits the Go name
		}
		fields[name] = f
	}
	fieldCache.Store(cacheKey, fields)
	return fields
}

// knownJSONKeys is the set of json tag names modeled on struct type t — the
// single source of truth the assembly block's refuseUnknownKeys reads.
func knownJSONKeys(t reflect.Type) map[string]bool {
	keys := make(map[string]bool)
	for k := range fieldsByTag(t, "json") {
		keys[k] = true
	}
	return keys
}

var yamlUnmarshalerType = reflect.TypeOf((*yaml.Unmarshaler)(nil)).Elem()

// ownsItsDecoding reports whether t (or *t) implements yaml.Unmarshaler and so
// refuses its own unknown keys; the walk does not descend into it.
func ownsItsDecoding(t reflect.Type) bool {
	return t.Implements(yamlUnmarshalerType) || reflect.PtrTo(t).Implements(yamlUnmarshalerType)
}

// walkTarget classifies a field's type for the walk: the struct type to check
// keys against, and whether the value is a list of them or a map of them.
type walkTarget struct {
	elem   reflect.Type
	list   bool
	keyed  bool
	opaque bool
}

func targetOf(t reflect.Type) walkTarget {
	for t.Kind() == reflect.Ptr {
		t = t.Elem()
	}
	switch t.Kind() {
	case reflect.Struct:
		if ownsItsDecoding(t) {
			return walkTarget{opaque: true}
		}
		return walkTarget{elem: t}
	case reflect.Slice:
		e := t.Elem()
		for e.Kind() == reflect.Ptr {
			e = e.Elem()
		}
		if e.Kind() == reflect.Struct && !ownsItsDecoding(e) {
			return walkTarget{elem: e, list: true}
		}
	case reflect.Map:
		e := t.Elem()
		for e.Kind() == reflect.Ptr {
			e = e.Elem()
		}
		if e.Kind() == reflect.Struct && !ownsItsDecoding(e) {
			return walkTarget{elem: e, keyed: true}
		}
	}
	return walkTarget{opaque: true}
}

// entityLabel names one mapping for a refusal: the path so far plus the
// entity's own designator when it states one (ref, name, id or pin number).
func entityLabel(where string, designator string) string {
	if designator == "" {
		return where
	}
	return fmt.Sprintf("%s (%s)", where, designator)
}

// --- YAML ---

// refuseUnknownYAML walks a mapping node against struct type t and refuses the
// first key that names no field, recursing into nested structs, lists of
// structs and maps of structs. Shape mismatches (a scalar where a mapping was
// expected) are left to the typed decode, which owns that error.
func refuseUnknownYAML(n *yaml.Node, t reflect.Type, where string) error {
	n = resolveAlias(n)
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	fields := fieldsByTag(t, "yaml")
	for i := 0; i+1 < len(n.Content); i += 2 {
		key := n.Content[i].Value
		f, ok := fields[key]
		if !ok {
			return fmt.Errorf("%s: %s: unknown key %q", unknownKeyCode, where, key)
		}
		if err := refuseUnknownYAMLValue(n.Content[i+1], f.Type, where+"."+key); err != nil {
			return err
		}
	}
	return nil
}

func refuseUnknownYAMLValue(v *yaml.Node, ft reflect.Type, where string) error {
	target := targetOf(ft)
	if target.opaque {
		return nil
	}
	v = resolveAlias(v)
	if v == nil {
		return nil
	}
	switch {
	case target.list:
		if v.Kind != yaml.SequenceNode {
			return nil
		}
		for idx, item := range v.Content {
			label := entityLabel(fmt.Sprintf("%s[%d]", where, idx), yamlDesignator(item))
			if err := refuseUnknownYAML(item, target.elem, label); err != nil {
				return err
			}
		}
	case target.keyed:
		if v.Kind != yaml.MappingNode {
			return nil
		}
		for i := 0; i+1 < len(v.Content); i += 2 {
			label := fmt.Sprintf("%s[%s]", where, v.Content[i].Value)
			if err := refuseUnknownYAML(v.Content[i+1], target.elem, label); err != nil {
				return err
			}
		}
	default:
		return refuseUnknownYAML(v, target.elem, where)
	}
	return nil
}

// designatorKeys are the scalars an entity is known by, in precedence order.
var designatorKeys = []string{"ref", "name", "id", "number"}

// yamlDesignator is the designator scalar a mapping node states, or "".
func yamlDesignator(n *yaml.Node) string {
	for _, key := range designatorKeys {
		if s := nodeMapValue(n, key); s != nil && s.Kind == yaml.ScalarNode && s.Tag != "!!null" {
			return s.Value
		}
	}
	return ""
}

// --- JSON ---

// refuseUnknownJSON is the JSON-side twin of refuseUnknownYAML, run on the
// board dict the panel hands pcb.serialize / pcb.deserialize so a key the
// codec would refuse to LOAD is refused before it is ever WRITTEN.
func refuseUnknownJSON(raw json.RawMessage, t reflect.Type, where string) error {
	if len(raw) == 0 || isJSONNull(raw) {
		return nil
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil // not an object: the typed decode owns that error
	}
	fields := fieldsByTag(t, "json")
	for _, key := range jsonObjectKeys(obj) {
		f, ok := fields[key]
		if !ok {
			return fmt.Errorf("%s: %s: unknown key %q", unknownKeyCode, where, key)
		}
		if err := refuseUnknownJSONValue(obj[key], f.Type, where+"."+key); err != nil {
			return err
		}
	}
	return nil
}

func refuseUnknownJSONValue(raw json.RawMessage, ft reflect.Type, where string) error {
	target := targetOf(ft)
	if target.opaque || len(raw) == 0 || isJSONNull(raw) {
		return nil
	}
	switch {
	case target.list:
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil {
			return nil
		}
		for idx, item := range items {
			label := entityLabel(fmt.Sprintf("%s[%d]", where, idx), jsonDesignator(item))
			if err := refuseUnknownJSON(item, target.elem, label); err != nil {
				return err
			}
		}
	case target.keyed:
		var entries map[string]json.RawMessage
		if err := json.Unmarshal(raw, &entries); err != nil {
			return nil
		}
		for _, k := range jsonObjectKeys(entries) {
			if err := refuseUnknownJSON(entries[k], target.elem, fmt.Sprintf("%s[%s]", where, k)); err != nil {
				return err
			}
		}
	default:
		return refuseUnknownJSON(raw, target.elem, where)
	}
	return nil
}

// jsonDesignator is the designator string an object states, or "".
func jsonDesignator(raw json.RawMessage) string {
	var obj map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) != nil {
		return ""
	}
	for _, key := range designatorKeys {
		var s string
		if v, ok := obj[key]; ok && json.Unmarshal(v, &s) == nil && s != "" {
			return s
		}
	}
	return ""
}
