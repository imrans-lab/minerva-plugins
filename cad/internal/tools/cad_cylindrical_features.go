// Package tools — cad.cylindrical_features tool registration and handler.
//
// The cylindrical surfaces of the evaluated .mcad solid, read straight off the
// OCCT B-Rep: axis, radius and axial extent with no tessellation error at all.
// The panel uses these as the axes of the solid's bosses and bores when it
// checks a fastener, and falls back to fitting the display tessellation only
// where the kernel has no cylindrical face for a feature.
//
// The MCP tool name is dotted (cad.cylindrical_features) because it is also
// the panel's IPC channel name — channel name = MCP tool name. The worker
// method is "cylindrical_features".
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// CylindricalFeatures is the MCP tool spec for cad.cylindrical_features.
var CylindricalFeatures = ToolSpec{
	Name:        "cad.cylindrical_features",
	Description: "Cylindrical surfaces of the evaluated .mcad solid, exact from the B-Rep. Returns {units, count, shape_name, cylinders:[{sense,radius_mm,dia_mm,axis:{origin_mm,direction},centre_mm,length_mm,sweep_deg,closed,faces,area_mm2}]}. sense concave is a bore or hole, convex is a boss, pin or outer wall; faces of one surface (a bore split at its seam) are merged into one entry and their sweeps summed, so closed:false is a fillet or a slot end rather than a hole.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"source": {"type": "string", "description": ".mcad DSL source; the part is translated here and its B-Rep read directly"},
			"sense": {"type": "string", "enum": ["any", "concave", "convex"], "description": "concave = bores and holes, convex = bosses and pins, any = both (default)"},
			"min_dia_mm": {"type": "number", "description": "smallest diameter to report, in millimetres"},
			"max_dia_mm": {"type": "number", "description": "largest diameter to report, in millimetres"},
			"closed_only": {"type": "boolean", "description": "report only features that sweep a full turn"}
		},
		"required": ["source"]
	}`),
}

// HandleCylindricalFeatures dispatches a feature request to the worker via the
// bridge. The worker method name is "cylindrical_features" (no cad./mcad_
// prefix). A DSL that does not evaluate, a document with no 3D part and a
// missing OCCT binding are all returned as worker data errors, not MCP errors.
func HandleCylindricalFeatures(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "cylindrical_features", params)
}
