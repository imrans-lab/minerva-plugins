// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"fmt"
	"reflect"
)

// Validate the advertised tool contract before any state change. JSON numbers
// from Minerva can contain .0, so integral float64 values are accepted.
func validateSchema(v any, s map[string]any, path string) error {
	if v == nil {
		return invalid(path + " cannot be null.")
	}
	switch s["type"] {
	case "object":
		obj, ok := v.(map[string]any)
		if !ok {
			return invalid(path + " must be an object.")
		}
		props := s["properties"].(map[string]any)
		if req, ok := s["required"].([]string); ok {
			for _, key := range req {
				if _, ok := obj[key]; !ok {
					return invalid(path + " requires " + key)
				}
			}
		}
		for key, value := range obj {
			child, ok := props[key]
			if !ok {
				return invalid(path + " has unexpected field " + key)
			}
			if err := validateSchema(value, child.(map[string]any), path+"."+key); err != nil {
				return err
			}
		}
	case "array":
		values, ok := v.([]any)
		if !ok {
			return invalid(path + " must be an array.")
		}
		for _, value := range values {
			if err := validateSchema(value, s["items"].(map[string]any), path+"[]"); err != nil {
				return err
			}
		}
		if min, ok := s["minItems"].(int); ok && len(values) < min {
			return invalid(path + " has too few items.")
		}
		if max, ok := s["maxItems"].(int); ok && len(values) > max {
			return invalid(path + " has too many items.")
		}
	case "string":
		if _, ok := v.(string); !ok {
			return invalid(path + " must be a string.")
		}
	case "boolean":
		if _, ok := v.(bool); !ok {
			return invalid(path + " must be a boolean.")
		}
	case "integer", "number":
		n, ok := v.(float64)
		if !ok {
			return invalid(path + " must be numeric.")
		}
		if s["type"] == "integer" && !whole(n) {
			return invalid(path + " must be an integer.")
		}
		if min, ok := s["minimum"].(int); ok && n < float64(min) {
			return invalid(path + " is below minimum.")
		}
		if max, ok := s["maximum"].(int); ok && n > float64(max) {
			return invalid(path + " exceeds maximum.")
		}
	}
	if enum, ok := s["enum"]; ok {
		values := reflect.ValueOf(enum)
		match := false
		for i := 0; i < values.Len(); i++ {
			if fmt.Sprint(v) == fmt.Sprint(values.Index(i).Interface()) {
				match = true
			}
		}
		if !match {
			return invalid(path + " is not a supported value.")
		}
	}
	return nil
}
