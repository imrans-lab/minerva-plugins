// Command council-proof-plugin is the near-empty backend the Council wrapper
// proof needs in order to be installable.
//
// A godot_scene plugin must still declare a backend, and the host starts it
// before mounting the panel. The proof exercises the wrapper, the CefTexture
// surface and the native persistence hooks, none of which involve the backend,
// so this server answers the MCP handshake, reports no tools, and does nothing
// else. The real Council backend is separate work.
//
// Protocol: JSON-RPC 2.0 over stdin/stdout, one message per line. stdout
// carries only JSON-RPC; logging goes to stderr.
package main

import (
	"bufio"
	"encoding/json"
	"log"
	"os"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "council-proof"
	serverVersion   = "0.0.1"
)

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func main() {
	log.SetOutput(os.Stderr)
	log.SetPrefix("[council-proof] ")

	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	out := json.NewEncoder(os.Stdout)

	for in.Scan() {
		line := in.Bytes()
		if len(line) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			log.Printf("bad request: %v", err)
			continue
		}
		// A notification has no id and takes no reply.
		if len(req.ID) == 0 {
			continue
		}
		var reply response
		switch req.Method {
		case "initialize":
			reply = response{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
				"protocolVersion": protocolVersion,
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": serverName, "version": serverVersion},
			}}
		case "tools/list":
			reply = response{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{"tools": []any{}}}
		default:
			reply = response{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: -32601, Message: "method not found: " + req.Method}}
		}
		if err := out.Encode(reply); err != nil {
			log.Printf("write reply: %v", err)
		}
	}
	if err := in.Err(); err != nil {
		log.Printf("stdin: %v", err)
	}
}
