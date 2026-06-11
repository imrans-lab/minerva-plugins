// Command pcb-plugin is the PCB Editor plugin MCP server for Minerva.
//
// Protocol: JSON-RPC 2.0 over stdin/stdout, one message per line — the same
// transport Minerva uses for every stdio MCP plugin (see cad/main.go for the
// worker-backed sibling).
//
// Round 1 (this scaffold) implements:
//   - initialize handshake
//   - tools/list → [ping]
//   - tools/call ping → answered directly in-process (no worker)
//   - notifications/initialized + any other notification → ignored gracefully
//   - shutdown → exit 0
//
// There is deliberately NO Python worker and NO shared/bridge import this round
// — the worker round adds bridge.New, a worker dir, and worker-backed tools. The
// internal/tools registry mirrors cad/internal/tools so that addition is a slot-
// in, not a reshape. See FINDING in the round report: the dispatch loop below is
// intentionally byte-similar to cad/main.go; extracting a shared/ MCP-router is a
// future call, deferred so the second consumer (this file) can first prove the
// pattern is stable.
//
// All logging goes to stderr; stdout carries only JSON-RPC responses.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"

	"github.com/imrans-lab/minerva-plugins/pcb/internal/tools"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "pcb"
	serverVersion   = "0.1.0"
)

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 envelope types
// ---------------------------------------------------------------------------

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"` // null/absent for notifications
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  interface{} `json:"result,omitempty"`
	Error   *rpcError   `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func okResponse(id json.RawMessage, result interface{}) rpcResponse {
	return rpcResponse{JSONRPC: "2.0", ID: id, Result: result}
}

func errResponse(id json.RawMessage, code int, msg string) rpcResponse {
	return rpcResponse{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: code, Message: msg}}
}

func send(enc *json.Encoder, v interface{}) {
	if err := enc.Encode(v); err != nil {
		log.Printf("pcb-plugin: write response: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Tool registry
// ---------------------------------------------------------------------------

var registry *tools.Registry

// initRegistry registers all MCP tools. Called once at startup.
func initRegistry() {
	tools.SetVersion(serverVersion)
	registry = tools.NewRegistry()
	registry.Register(tools.Ping, tools.HandlePing)
}

// ---------------------------------------------------------------------------
// MCP handler functions
// ---------------------------------------------------------------------------

func handleInitialize(id json.RawMessage) rpcResponse {
	log.Printf("pcb-plugin: initialize")
	return okResponse(id, map[string]interface{}{
		"protocolVersion": protocolVersion,
		"capabilities":    map[string]interface{}{},
		"serverInfo": map[string]string{
			"name":    serverName,
			"version": serverVersion,
		},
	})
}

func handleToolsList(id json.RawMessage) rpcResponse {
	log.Printf("pcb-plugin: tools/list")
	specs := registry.Specs()
	type mcpTool struct {
		Name        string          `json:"name"`
		Description string          `json:"description"`
		InputSchema json.RawMessage `json:"inputSchema"`
	}
	mcpTools := make([]mcpTool, len(specs))
	for i, s := range specs {
		mcpTools[i] = mcpTool{Name: s.Name, Description: s.Description, InputSchema: s.InputSchema}
	}
	return okResponse(id, map[string]interface{}{"tools": mcpTools})
}

func handleToolsCall(id json.RawMessage, params json.RawMessage) rpcResponse {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return errResponse(id, -32700, fmt.Sprintf("tools/call: parse params: %v", err))
	}

	log.Printf("pcb-plugin: tools/call: %s", p.Name)

	result, err, found := registry.Dispatch(context.Background(), p.Name, p.Arguments)
	if !found {
		return errResponse(id, -32601, fmt.Sprintf("method not found: %s", p.Name))
	}
	if err != nil {
		return errResponse(id, -32603, fmt.Sprintf("tool error: %v", err))
	}

	// Wrap the raw result in {ok: true, result: <result>} so the panel-side
	// decoder is symmetric with the eventual error path. Mirrors cad/main.go.
	successEnvelope := map[string]interface{}{"ok": true, "result": json.RawMessage(result)}
	envelopeJSON, _ := json.Marshal(successEnvelope)
	return okResponse(id, map[string]interface{}{
		"content": []map[string]interface{}{
			{"type": "text", "text": string(envelopeJSON)},
		},
	})
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

func dispatch(enc *json.Encoder, msg *rpcRequest) {
	// Notifications have a null or absent id. Per JSON-RPC 2.0, no response is
	// sent for notifications.
	isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"

	switch msg.Method {
	case "initialize":
		if isNotification {
			return
		}
		send(enc, handleInitialize(msg.ID))

	case "notifications/initialized":
		log.Printf("pcb-plugin: notifications/initialized (no-op)")

	case "tools/list":
		if isNotification {
			return
		}
		send(enc, handleToolsList(msg.ID))

	case "tools/call":
		if isNotification {
			return
		}
		send(enc, handleToolsCall(msg.ID, msg.Params))

	case "shutdown":
		log.Printf("pcb-plugin: shutdown requested — exiting")
		os.Exit(0)

	default:
		if isNotification {
			log.Printf("pcb-plugin: unknown notification: %s (ignored)", msg.Method)
			return
		}
		log.Printf("pcb-plugin: unknown method: %s", msg.Method)
		send(enc, errResponse(msg.ID, -32601, "Method not found: "+msg.Method))
	}
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[pcb-plugin] ")
	log.SetOutput(os.Stderr)

	log.Printf("starting (pid=%d)", os.Getpid())

	initRegistry()

	enc := json.NewEncoder(os.Stdout)
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var msg rpcRequest
		if err := json.Unmarshal(line, &msg); err != nil {
			log.Printf("JSON parse error: %v", err)
			send(enc, errResponse(json.RawMessage("null"), -32700, "Parse error"))
			continue
		}
		dispatch(enc, &msg)
	}

	if err := scanner.Err(); err != nil {
		log.Printf("stdin read error: %v", err)
		os.Exit(1)
	}
	log.Printf("stdin closed — exiting")
}
