package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/codetools/internal/bridge"
)

// Ping is the substrate health tool. It round-trips through the Python worker
// (proving stdio → Go → bridge → Python) and echoes back worker/runtime info.
// Namespaced minerva_codetools_* per the Code Tools tool convention.
var Ping = ToolSpec{
	Name:        "minerva_codetools_ping",
	Description: "Health check: round-trips through the Code Tools Python worker and returns worker/runtime info. Optional 'echo' string is returned verbatim.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"echo": {"type": "string", "description": "Optional value echoed back by the worker."}
		},
		"additionalProperties": false
	}`),
}

// HandlePing forwards the call to the worker's "ping" method. The worker is
// lazily spawned by bridge.Worker.Call on first use.
func HandlePing(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "ping", params)
}
