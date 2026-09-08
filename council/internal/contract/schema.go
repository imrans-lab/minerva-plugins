// Package contract validates Council records against the shipped JSON Schemas
// and against the cross-field invariants the schemas cannot express.
//
// The validator implements the subset of JSON Schema the Council schemas
// actually use: type, const, enum, minimum/maximum, minLength/maxLength,
// pattern, properties, required, additionalProperties:false, items/minItems,
// oneOf, and $ref into a "$defs" table of the same or another shipped schema.
// Anything outside that subset is a load error rather than a silent pass, so a
// schema cannot quietly grow a constraint that nothing checks.
package contract

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"

	"github.com/ipeerbhai/plugins/council/schemas"
)

// knownKeywords is the whole vocabulary this validator honours. A schema
// keyword outside it is rejected at load time.
var knownKeywords = map[string]bool{
	"$schema": true, "$id": true, "$defs": true, "$ref": true,
	"title": true, "description": true, "format": true, "default": true,
	"type": true, "const": true, "enum": true,
	"minimum": true, "maximum": true,
	"minLength": true, "maxLength": true, "pattern": true,
	"properties": true, "required": true, "additionalProperties": true,
	"items": true, "minItems": true,
	"oneOf": true,
}

// Registry holds the loaded schema documents, keyed by file name.
type Registry struct {
	docs     map[string]map[string]any
	patterns map[string]*regexp.Regexp
}

// LoadRegistry parses every embedded schema and checks that each keyword used
// is one this validator implements.
func LoadRegistry() (*Registry, error) {
	r := &Registry{docs: map[string]map[string]any{}, patterns: map[string]*regexp.Regexp{}}
	entries, err := schemas.FS.ReadDir(".")
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".json") {
			continue
		}
		raw, err := schemas.FS.ReadFile(name)
		if err != nil {
			return nil, err
		}
		var doc map[string]any
		if err := json.Unmarshal(raw, &doc); err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		r.docs[name] = doc
	}
	for name, doc := range r.docs {
		if err := r.auditKeywords(name, doc, "#"); err != nil {
			return nil, err
		}
	}
	return r, nil
}

// auditKeywords walks a schema document and fails on any keyword the validator
// would otherwise ignore.
func (r *Registry) auditKeywords(file string, node any, path string) error {
	m, ok := node.(map[string]any)
	if !ok {
		return nil
	}
	// "$defs" and "properties" hold subschemas keyed by arbitrary names, so
	// their keys are not keywords.
	for k, v := range m {
		switch k {
		case "$defs", "properties":
			sub, _ := v.(map[string]any)
			for name, s := range sub {
				if err := r.auditKeywords(file, s, path+"/"+k+"/"+name); err != nil {
					return err
				}
			}
			continue
		case "required", "enum", "type", "const", "$schema", "$id", "$ref",
			"title", "description", "format", "default",
			"minimum", "maximum", "minLength", "maxLength", "pattern", "minItems":
			continue
		case "items", "additionalProperties":
			if err := r.auditKeywords(file, v, path+"/"+k); err != nil {
				return err
			}
			continue
		case "oneOf":
			arr, _ := v.([]any)
			for i, s := range arr {
				if err := r.auditKeywords(file, s, fmt.Sprintf("%s/oneOf/%d", path, i)); err != nil {
					return err
				}
			}
			continue
		}
		if !knownKeywords[k] {
			return fmt.Errorf("%s%s: schema keyword %q is not implemented by this validator", file, path, k)
		}
	}
	return nil
}

// resolve follows a $ref of the form "file.schema.json#/$defs/Name" or
// "#/$defs/Name" relative to the document the reference appeared in.
func (r *Registry) resolve(fromFile, ref string) (string, map[string]any, error) {
	file, pointer, _ := strings.Cut(ref, "#")
	if file == "" {
		file = fromFile
	}
	doc, ok := r.docs[file]
	if !ok {
		return "", nil, fmt.Errorf("$ref %q: no such schema", ref)
	}
	if pointer == "" {
		return file, doc, nil
	}
	node := any(doc)
	for _, seg := range strings.Split(strings.TrimPrefix(pointer, "/"), "/") {
		m, ok := node.(map[string]any)
		if !ok {
			return "", nil, fmt.Errorf("$ref %q: not an object at %q", ref, seg)
		}
		node, ok = m[seg]
		if !ok {
			return "", nil, fmt.Errorf("$ref %q: no member %q", ref, seg)
		}
	}
	m, ok := node.(map[string]any)
	if !ok {
		return "", nil, fmt.Errorf("$ref %q: target is not a schema", ref)
	}
	return file, m, nil
}

func (r *Registry) compile(pat string) (*regexp.Regexp, error) {
	if re, ok := r.patterns[pat]; ok {
		return re, nil
	}
	re, err := regexp.Compile(pat)
	if err != nil {
		return nil, err
	}
	r.patterns[pat] = re
	return re, nil
}

// Validate checks value against the named schema document. Errors are returned
// sorted by path so a failing fixture reports the same list every run.
func (r *Registry) Validate(schemaFile string, value any) []string {
	doc, ok := r.docs[schemaFile]
	if !ok {
		return []string{fmt.Sprintf("no such schema %q", schemaFile)}
	}
	var errs []string
	r.check(schemaFile, doc, value, "", &errs)
	sort.Strings(errs)
	return errs
}

func (r *Registry) check(file string, schema map[string]any, value any, path string, errs *[]string) {
	fail := func(format string, args ...any) {
		at := path
		if at == "" {
			at = "(root)"
		}
		*errs = append(*errs, at+": "+fmt.Sprintf(format, args...))
	}

	if ref, ok := schema["$ref"].(string); ok {
		nextFile, target, err := r.resolve(file, ref)
		if err != nil {
			fail("%v", err)
			return
		}
		r.check(nextFile, target, value, path, errs)
		return
	}

	if c, ok := schema["const"]; ok && !equalJSON(c, value) {
		fail("expected const %v, got %v", c, value)
		return
	}
	if raw, ok := schema["enum"].([]any); ok {
		matched := false
		for _, cand := range raw {
			if equalJSON(cand, value) {
				matched = true
				break
			}
		}
		if !matched {
			fail("value %v is not in enum %v", value, raw)
			return
		}
	}
	if variants, ok := schema["oneOf"].([]any); ok {
		hits := 0
		var closest []string
		for _, v := range variants {
			sub, _ := v.(map[string]any)
			var probe []string
			r.check(file, sub, value, path, &probe)
			if len(probe) == 0 {
				hits++
				continue
			}
			// Keep the near miss so the caller learns WHY nothing matched
			// rather than only that nothing did.
			if closest == nil || len(probe) < len(closest) {
				closest = probe
			}
		}
		if hits != 1 {
			fail("matched %d oneOf variants, expected exactly 1", hits)
			*errs = append(*errs, closest...)
		}
		return
	}

	switch want, _ := schema["type"].(string); want {
	case "object":
		obj, ok := value.(map[string]any)
		if !ok {
			fail("expected object, got %T", value)
			return
		}
		props, _ := schema["properties"].(map[string]any)
		for _, req := range toStrings(schema["required"]) {
			if _, present := obj[req]; !present {
				fail("missing required property %q", req)
			}
		}
		allowExtra := true
		if ap, ok := schema["additionalProperties"].(bool); ok {
			allowExtra = ap
		}
		keys := make([]string, 0, len(obj))
		for k := range obj {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			sub, known := props[k].(map[string]any)
			if !known {
				if !allowExtra {
					fail("additional property %q is not permitted", k)
				}
				continue
			}
			r.check(file, sub, obj[k], path+"/"+k, errs)
		}
	case "array":
		arr, ok := value.([]any)
		if !ok {
			fail("expected array, got %T", value)
			return
		}
		if min, ok := schema["minItems"].(float64); ok && float64(len(arr)) < min {
			fail("expected at least %d items, got %d", int(min), len(arr))
		}
		if item, ok := schema["items"].(map[string]any); ok {
			for i, v := range arr {
				r.check(file, item, v, fmt.Sprintf("%s/%d", path, i), errs)
			}
		}
	case "string":
		s, ok := value.(string)
		if !ok {
			fail("expected string, got %T", value)
			return
		}
		if min, ok := schema["minLength"].(float64); ok && float64(len([]rune(s))) < min {
			fail("shorter than minLength %d", int(min))
		}
		if max, ok := schema["maxLength"].(float64); ok && float64(len([]rune(s))) > max {
			fail("longer than maxLength %d", int(max))
		}
		if pat, ok := schema["pattern"].(string); ok {
			re, err := r.compile(pat)
			if err != nil {
				fail("bad pattern %q: %v", pat, err)
				return
			}
			if !re.MatchString(s) {
				fail("does not match pattern %s", pat)
			}
		}
	case "integer", "number":
		n, ok := value.(float64)
		if !ok {
			fail("expected %s, got %T", want, value)
			return
		}
		if want == "integer" && n != math.Trunc(n) {
			fail("expected integer, got %v", n)
		}
		if min, ok := schema["minimum"].(float64); ok && n < min {
			fail("below minimum %v", min)
		}
		if max, ok := schema["maximum"].(float64); ok && n > max {
			fail("above maximum %v", max)
		}
	case "boolean":
		if _, ok := value.(bool); !ok {
			fail("expected boolean, got %T", value)
		}
	case "":
		// No type keyword: only the assertions already applied above bind.
	default:
		fail("unsupported type %q in schema", want)
	}
}

func toStrings(v any) []string {
	arr, _ := v.([]any)
	out := make([]string, 0, len(arr))
	for _, s := range arr {
		if str, ok := s.(string); ok {
			out = append(out, str)
		}
	}
	return out
}

// equalJSON compares two decoded JSON values for the const/enum keywords,
// where only scalars appear.
func equalJSON(a, b any) bool {
	return fmt.Sprintf("%v|%T", a, a) == fmt.Sprintf("%v|%T", b, b)
}
