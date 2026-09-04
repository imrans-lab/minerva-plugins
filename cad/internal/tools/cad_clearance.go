// Package tools — cad.clearance tool registration and handler.
//
// Exact minimum distance between the evaluated solid and each reference node
// the panel names, against a requested clearance. The panel supplies the DSL
// source (the worker tessellates it at the stated measurement tolerance) and
// one small binary blob per reference node, addressed by the SHA-256 of its
// array bytes; a blob already cached in the worker is named by that hash and
// not re-sent. See worker/mcad_worker/clearance.py for the blob layout and
// the reply shape.
//
// The MCP tool name is dotted (cad.clearance) because it is also the panel's
// IPC channel name — channel name = MCP tool name. The worker method is
// "clearance".
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// Clearance is the MCP tool spec for cad.clearance.
var Clearance = ToolSpec{
	Name: "cad.clearance",
	Description: "Minimum distance between the evaluated .mcad solid and each named reference node, exact for the two meshes. Returns {checked, pass, required_mm, tessellation_tolerance_mm, bound, pairs:[{reference,node,min_mm,solid_point_mm,reference_point_mm,pass,interference?}], cache}. Targets whose geometry the worker has not cached come back as missing_keys with checked:false, for the caller to upload and ask again.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"source": {"type": "string", "description": ".mcad DSL source; the solid is tessellated here at tolerance_mm"},
			"required_mm": {"type": "number", "description": "the clearance being asked for, in millimetres"},
			"tolerance_mm": {"type": "number", "description": "tessellation deviation used for the measurement; echoed in the reply as the error bar"},
			"angular_tolerance": {"type": "number", "description": "tessellation angular deviation"},
			"targets": {
				"type": "array",
				"description": "one entry per reference node to measure against",
				"items": {
					"type": "object",
					"properties": {
						"reference": {"type": "string"},
						"node": {"type": "string"},
						"key": {"type": "string", "description": "SHA-256 of the blob's array bytes; also the worker's cache key"},
						"path": {"type": "string", "description": "path to the mesh blob; omit when the key is already cached"}
					},
					"required": ["key"]
				}
			}
		},
		"required": ["source", "targets"]
	}`),
}

// HandleClearance dispatches a clearance request to the worker via the bridge.
// The worker method name is "clearance" (no cad./mcad_ prefix). A DSL that
// does not evaluate, a blob that cannot be read and a missing geometry backend
// are all returned as worker data errors, not as MCP errors.
func HandleClearance(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "clearance", params)
}
