// Package tools — ping tool registration and handler.
//
// ping is a liveness handshake: it proves the backend process is up and
// answering tools/call without needing any worker or PCB logic. It echoes an
// optional caller-supplied string so round-trip integrity can be checked.
package tools

import (
	"context"
	"encoding/json"
)

// version is stamped by the server at registration time so the ping reply can
// report the running plugin version. Set via SetVersion before Register.
var version = "0.0.0"

// SetVersion records the plugin version reported by ping. Call once at
// startup before registering the tool.
func SetVersion(v string) {
	if v != "" {
		version = v
	}
}

// Ping is the MCP tool spec for ping.
var Ping = ToolSpec{
	Name:        "ping",
	Description: "Liveness handshake for the PCB plugin backend. Returns {ok, plugin, version, echo}; echoes the optional 'echo' string so callers can verify round-trip integrity.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"echo": {"type": "string", "description": "Optional string echoed back verbatim in the reply."}
		}
	}`),
}

// HandlePing answers a ping request directly (no worker). It tolerates
// missing/empty params and reflects the optional echo string.
func HandlePing(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	var a struct {
		Echo string `json:"echo"`
	}
	if len(params) > 0 {
		// Ignore parse errors: ping must succeed even on a malformed/empty arg
		// object so it stays a dependable liveness probe.
		_ = json.Unmarshal(params, &a)
	}
	reply := map[string]interface{}{
		"ok":      true,
		"plugin":  "pcb",
		"version": version,
		"echo":    a.Echo,
	}
	return json.Marshal(reply)
}
