package tools

import (
	"context"
	"encoding/json"
)

// CheckStructure describes a source-only critic; no live panel is required.
func CheckStructure() ToolSpec {
	return ToolSpec{
		Name:        "minerva_cad_check_structure",
		Description: "Check parsed .mcad source structure without building geometry. Returns {pass, findings:[{rule,line,message,fix}]} for repeated primitives/literals, holes without fit intent, literal radial allowances, and finishes on assembled copies. Each finding gives a concrete repair; this does not replace dimensional or fit checks.",
		InputSchema: json.RawMessage(`{"type":"object","properties":{"source":{"type":"string","description":"Complete .mcad DSL source"}},"required":["source"],"additionalProperties":false}`),
	}
}

// HandleCheckStructure preserves the caller's context and worker errors.
func HandleCheckStructure(ctx context.Context, worker WorkerCaller, params json.RawMessage) (json.RawMessage, error) {
	return worker.Call(ctx, "check_structure", params)
}
