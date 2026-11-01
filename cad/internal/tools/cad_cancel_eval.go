// Package tools — cad.cancel_eval tool registration.
//
// cancel_eval is a control-plane tool that cancels an in-flight cad.evaluate
// keyed by request_id. The handler logic lives in main.go (it needs access to
// the evaluation registrations maintained at the server
// level), so this file only declares the spec. main.go intercepts cancel_eval
// in its dispatcher before delegating to the tool registry.
package tools

import "encoding/json"

// CancelEval is the MCP tool spec for cad.cancel_eval.
//
// Channel name = MCP tool name = manifest.ipc_channels entry.
// Args: {request_id: string} — the request_id passed in the original
// cad.evaluate args. Calling cancel_eval with an unknown request_id is a
// no-op (returns ok=true) so the panel can fire-and-forget when superseding.
var CancelEval = ToolSpec{
	Name:        "cad.cancel_eval",
	Description: "Cancel cad.evaluate by request_id. Queued cancellation never kills unrelated work. An active evaluation interrupts its exact native worker generation, cancels older queued worker calls, verifies process/I/O retirement, and eagerly starts one replacement. Later explicit requests retain their bounded queue admission. Unknown or completed request_id is a no-op. Returns request_cancelled, cancelled, native_stopped and worker_state; failure retains the real owner and refuses replacement. Caller cancellation alone does not prove native stop or readiness. Completed export artifacts survive.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"request_id": {"type": "string", "description": "request_id of the in-flight cad.evaluate to cancel"}
		},
		"required": ["request_id"]
	}`),
}
