package tools

import (
	"encoding/json"
	"testing"
)

func TestInspectInputSchemaIsValidJSON(t *testing.T) {
	var schema map[string]any
	if err := json.Unmarshal(Inspect.InputSchema, &schema); err != nil {
		t.Fatalf("Inspect input schema is invalid JSON: %v", err)
	}
}
