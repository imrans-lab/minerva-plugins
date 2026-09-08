// Command council-plugin is the Council plugin's MCP backend for Minerva.
//
// Transport: JSON-RPC 2.0 over stdin/stdout, one message per line, exactly as
// every other Minerva stdio plugin. stdout carries protocol traffic and nothing
// else; all logging goes to stderr, where the host captures it.
//
// The backend owns no durable state. It holds the working copy of one Council
// snapshot, applies protocol commands to it, and returns the acknowledged
// revision in every reply so the native wrapper can persist the result. A
// snapshot that never reached the wrapper is lost when this process ends, which
// is why a run left in flight is demoted on load rather than resumed.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"

	"github.com/ipeerbhai/plugins/council/internal/session"
)

const (
	// protocolVersion is the MCP revision this server answers with. The host
	// initialises with a newer revision string and accepts this one, the same
	// way the cad and pcb backends do.
	protocolVersion = "2024-11-05"
	serverName      = "council"

	// serverVersion must equal the version in manifest.json; a test pins it.
	serverVersion = "0.1.0"

	// maxLine bounds one protocol line. It is generous next to the engine's own
	// transport budget so an oversized request is refused by the protocol with
	// a readable error rather than truncated by the reader. A line above it is
	// discarded and answered; it never ends the loop.
	maxLine = 4 << 20

	// readBuffer is the reader's working size. A message larger than it is
	// assembled across reads, up to maxLine.
	readBuffer = 64 << 10
)

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 envelopes
// ---------------------------------------------------------------------------

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func okResponse(id json.RawMessage, result any) rpcResponse {
	return rpcResponse{JSONRPC: "2.0", ID: id, Result: result}
}

func errResponse(id json.RawMessage, code int, message string) rpcResponse {
	return rpcResponse{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: code, Message: message}}
}

// toolResult renders a handler's JSON as an MCP tool result. A handler failure
// travels as content with isError set rather than as a JSON-RPC error, so the
// caller reads the explanation the same way it reads a success.
func toolResult(id json.RawMessage, body []byte, isError bool) rpcResponse {
	result := map[string]any{
		"content": []map[string]any{{"type": "text", "text": string(body)}},
	}
	if isError {
		result["isError"] = true
	}
	return okResponse(id, result)
}

// ---------------------------------------------------------------------------
// MCP methods
// ---------------------------------------------------------------------------

func handleInitialize(id json.RawMessage) rpcResponse {
	return okResponse(id, map[string]any{
		"protocolVersion": protocolVersion,
		"capabilities":    map[string]any{"tools": map[string]any{}},
		"serverInfo":      map[string]any{"name": serverName, "version": serverVersion},
	})
}

func handleToolsList(id json.RawMessage, reg *registry) rpcResponse {
	specs := reg.specs()
	listed := make([]map[string]any, 0, len(specs))
	for _, spec := range specs {
		listed = append(listed, map[string]any{
			"name":        spec.Name,
			"description": spec.Description,
			"inputSchema": spec.InputSchema,
		})
	}
	return okResponse(id, map[string]any{"tools": listed})
}

func handleToolsCall(id json.RawMessage, reg *registry, params json.RawMessage) rpcResponse {
	var call struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &call); err != nil {
		return errResponse(id, -32602, fmt.Sprintf("tools/call: parse params: %v", err))
	}
	handler, found := reg.lookup(call.Name)
	if !found {
		return errResponse(id, -32601, "method not found: "+call.Name)
	}
	body, err := handler(call.Arguments)
	if err != nil {
		failure, _ := json.Marshal(map[string]any{"ok": false, "error": err.Error()})
		return toolResult(id, failure, true)
	}
	return toolResult(id, body, false)
}

// ---------------------------------------------------------------------------
// serve
// ---------------------------------------------------------------------------

// serve runs the protocol loop until the input ends or a shutdown arrives. It
// takes its streams as parameters so a test can drive the real loop over pipes
// instead of asserting against a re-implementation of it.
func serve(in io.Reader, out io.Writer, reg *registry) error {
	enc := json.NewEncoder(out)
	reader := bufio.NewReaderSize(in, readBuffer)

	send := func(response rpcResponse) {
		if err := enc.Encode(response); err != nil {
			log.Printf("write response: %v", err)
		}
	}

	for {
		line, tooLong, err := readLine(reader)
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		if tooLong {
			// The message is gone, so there is no id to answer against. Say so
			// and keep serving: an oversized request must not take the backend
			// down with it.
			log.Printf("discarded a request above the %d byte line limit", maxLine)
			send(errResponse(json.RawMessage("null"), -32600,
				fmt.Sprintf("request exceeds the %d byte line limit and was discarded", maxLine)))
			continue
		}
		if len(line) == 0 {
			continue
		}
		var msg rpcRequest
		if err := json.Unmarshal(line, &msg); err != nil {
			send(errResponse(json.RawMessage("null"), -32700, "Parse error"))
			continue
		}
		// A notification carries no id and takes no reply.
		isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"

		switch msg.Method {
		case "initialize":
			if !isNotification {
				send(handleInitialize(msg.ID))
			}
		case "notifications/initialized":
			// No-op: the host sends it after our initialize result.
		case "tools/list":
			if !isNotification {
				send(handleToolsList(msg.ID, reg))
			}
		case "tools/call":
			if !isNotification {
				send(handleToolsCall(msg.ID, reg, msg.Params))
			}
		case "shutdown":
			if !isNotification {
				send(okResponse(msg.ID, map[string]any{"ok": true}))
			}
			log.Printf("shutdown requested — exiting")
			return nil
		default:
			if !isNotification {
				send(errResponse(msg.ID, -32601, "Method not found: "+msg.Method))
			}
		}
	}
}

// readLine reads one newline-terminated message. A line longer than maxLine is
// consumed to its end and discarded, and tooLong is reported instead, so the
// caller can answer the fault and carry on reading the stream in step.
func readLine(reader *bufio.Reader) (line []byte, tooLong bool, err error) {
	var buf []byte
	for {
		chunk, isPrefix, err := reader.ReadLine()
		if err != nil {
			return nil, false, err
		}
		if !tooLong && len(buf)+len(chunk) > maxLine {
			tooLong = true
			buf = nil
		}
		if !tooLong {
			buf = append(buf, chunk...)
		}
		if !isPrefix {
			return buf, tooLong, nil
		}
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[council-plugin] ")
	log.SetOutput(os.Stderr)

	store, err := session.New()
	if err != nil {
		// The schemas are embedded, so this can only fail on a build whose
		// contract package is broken. Say so and stop rather than serve a
		// backend that cannot validate anything.
		log.Fatalf("cannot load the Council schemas: %v", err)
	}
	reg := newRegistry(store)

	log.Printf("starting (pid=%d, version=%s)", os.Getpid(), serverVersion)
	if err := serve(os.Stdin, os.Stdout, reg); err != nil {
		log.Printf("stdin read error: %v", err)
		os.Exit(1)
	}
}
