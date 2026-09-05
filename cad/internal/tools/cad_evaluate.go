// Package tools — cad.evaluate tool registration and handler.
//
// Evaluate .mcad source: full pipeline (lex → parse → translate → tessellate).
// Returns {shape_name, body_count, mesh: {vertices, faces}, edges, references} for the panel
// to render. References are posed mesh() files the worker never opens.
// Uses the worker's last_program cache when the source matches a recently-
// evaluated program.
//
// The MCP tool name uses a dotted namespace (cad.evaluate) because it is
// also the IPC channel name in the panel's manifest ui.ipc_channels list —
// channel name = MCP tool name. The worker method, however, is "evaluate"
// (no namespace prefix); see worker/mcad_worker/methods.py:_evaluate.
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// Evaluate is the MCP tool spec for cad.evaluate.
var Evaluate = ToolSpec{
	Name:        "cad.evaluate",
	Description: "Evaluate .mcad DSL source and return the resulting mesh + edges. Returns {shape_name, body_count, mesh:{vertices,faces}, edges:[...], references:[{name,path,units,up,matrix}]}. body_count is the number of separate solid bodies in the result: a part written as two halves (part = bottom + lid) that do not touch is ONE shape of TWO bodies, and every check reads the whole shape. Uses the worker's last_program cache to skip re-tessellation when the source matches a recently-evaluated program.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"source": {"type": "string", "description": ".mcad DSL source code"}
		},
		"required": ["source"]
	}`),
}

// HandleEvaluate dispatches an evaluate request to the worker via the bridge.
// The worker method name is "evaluate" (no cad./mcad_ prefix).
// Parse/translate/occt errors are returned as data per design §8.2,
// not as MCP errors. Only internal/python errors propagate as Go errors.
func HandleEvaluate(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "evaluate", params)
}
