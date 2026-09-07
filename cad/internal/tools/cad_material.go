// Package tools — cad.material tool registration and handler.
//
// Is the evaluated solid actually HERE? Every other check measures the solid
// against a reference — interference, clearance, fasteners — and air violates
// none of them, so a tray whose floor had been subtracted away passed all
// three. This asks about the material itself, at a point or along a ray, and
// the worker answers from the B-Rep with OCCT's solid classifier: no
// tessellation, no bounding box, no parity count.
//
// The MCP tool name is dotted (cad.material) because it is also the panel's
// IPC channel name — channel name = MCP tool name. The worker method is
// "material". The panel-facing verb is minerva_cad_material, declared in
// manifest.json with executor "panel".
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// Material is the MCP tool spec for cad.material.
var Material = ToolSpec{
	Name:        "cad.material",
	Description: "Is the evaluated .mcad solid present at a world point, and how thick is it along a ray. at_mm=[x,y,z] returns {mode:\"point\", inside, state, body, body_index, nearest_surface_mm, nearest_point_mm}; from_mm + direction_mm returns {mode:\"ray\", segments:[{entry_mm,exit_mm,thickness_mm,entry_point_mm,exit_point_mm,body,body_index}], total_thickness_mm, started_inside, surface_crossings, unbounded}. Containment is BRepClass3d_SolidClassifier on the B-Rep itself; the ray's face intersections are candidate boundaries only and each interval is decided by classifying its midpoint, so a coincident-face seam cannot flip a parity count. Millimetres in the solid's own frame, which is the panel's world frame.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"source": {"type": "string", "description": ".mcad DSL source; the part is translated here and its B-Rep classified directly"},
			"at_mm": {"type": "array", "items": {"type": "number"}, "description": "[x, y, z] world point — the point form"},
			"from_mm": {"type": "array", "items": {"type": "number"}, "description": "[x, y, z] world point the ray starts at — the ray form"},
			"direction_mm": {"type": "array", "items": {"type": "number"}, "description": "[dx, dy, dz] the way the ray points; normalised by the worker"},
			"max_distance_mm": {"type": "number", "description": "how far along the ray to walk, millimetres (default 10000)"},
			"tolerance_mm": {"type": "number", "description": "how close to a face counts as ON it rather than in or out (default 1e-7)"}
		},
		"required": ["source"]
	}`),
}

// HandleMaterial dispatches a material probe to the worker via the bridge. The
// worker method name is "material" (no cad./mcad_ prefix). A DSL that does not
// evaluate, a document with no closed solid and a missing OCCT binding are all
// returned as worker data errors, not as MCP errors.
func HandleMaterial(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "material", params)
}
