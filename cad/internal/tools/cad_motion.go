package tools

import (
	"context"
	"encoding/json"
	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// Motion checks a declared translation path against explicit solid obstacles.
var Motion = ToolSpec{
	Name:        "cad.motion",
	Description: "Bounded translation-path clearance over cached B-Reps; adaptive interval certification, explicit unknown on incomplete coverage. No imported mesh motion or rotation.",
	InputSchema: json.RawMessage(`{"type": "object", "properties": {"source": {"type": "string"}, "selection": {"type": "string", "description": "Moving solid instance, group, or binding selector."}, "configuration": {"type": "string", "description": "Physical assembly configuration; presentation-only views are refused."}, "against": {"type": "array", "minItems": 1, "maxItems": 64, "items": {"type": "string"}, "description": "Explicit obstacle selectors. Objects outside this set are not checked."}, "path_mm": {"type": "array", "minItems": 2, "maxItems": 64, "items": {"type": "array", "minItems": 3, "maxItems": 3, "items": {"type": "number"}}, "description": "Piecewise-linear translation offsets from evaluated placement, in world millimetres. No rotations."}, "required_mm": {"type": "number", "minimum": 0, "description": "Minimum clearance throughout the path; default 0."}, "numeric_tolerance_mm": {"type": "number", "minimum": 1e-07, "maximum": 0.01, "description": "Kernel numerical allowance; default 0.000001 mm. Not manufacturing tolerance."}, "max_samples": {"type": "integer", "minimum": 2, "maximum": 512, "description": "Adaptive pose budget; default 64. Exhaustion gives unknown, never a sampled pass."}}, "required": ["source", "selection", "against", "path_mm"]}`),
}

func HandleMotion(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "motion", params)
}
