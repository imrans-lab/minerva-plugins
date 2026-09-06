// Package tools — cad.reference_pairs tool registration and handler.
//
// Exact minimum distance between REFERENCE meshes, pair by pair: the
// part-against-part question the clearance tool cannot ask, because that one
// measures the evaluated solid against a reference. Neither side is a B-Rep
// here, so no source is sent and no tessellation tolerance comes back; the
// blobs, their cache keys and the missing-key protocol are the clearance
// tool's. See worker/mcad_worker/reference_pairs.py.
//
// The MCP tool name is dotted (cad.reference_pairs) because it is also the
// panel's IPC channel name — channel name = MCP tool name. The worker method
// is "reference_pairs".
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// ReferencePairs is the MCP tool spec for cad.reference_pairs.
var ReferencePairs = ToolSpec{
	Name:        "cad.reference_pairs",
	Description: "Minimum distance between named reference nodes, pair by pair, exact for the two meshes. Returns {checked, pass, required_mm, pairs:[{a:{reference,node}, b:{reference,node}, min_mm, pass, point_a_mm, point_b_mm, overlap?, contact_points_mm?}], cache}. Targets whose geometry the worker has not cached come back as missing_keys with checked:false, for the caller to upload and ask again.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"required_mm": {"type": "number", "description": "the gap each pair is judged against, in millimetres; 0 only reports the distances"},
			"max_contacts": {"type": "number", "description": "contact points collected per overlapping pair"},
			"pairs": {
				"type": "array",
				"description": "[i, j] index pairs into targets; omitted, every pair whose references differ is measured",
				"items": {"type": "array", "items": {"type": "number"}}
			},
			"targets": {
				"type": "array",
				"description": "every reference node in scope, named once; a pair refers to them by index",
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
		"required": ["targets"]
	}`),
}

// HandleReferencePairs dispatches a reference-pair request to the worker via
// the bridge. The worker method name is "reference_pairs" (no cad. prefix).
func HandleReferencePairs(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "reference_pairs", params)
}
