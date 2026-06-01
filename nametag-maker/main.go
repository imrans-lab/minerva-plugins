// Command nametag-maker-plugin is the Name Tags plugin MCP server for Minerva.
//
// Round 1 (backend spine): the bidirectional host-capability client (ported
// from the presentation plugin), the ported nametag layout, and a single tool
// — nametag_generate — which builds a host.pdf `Doc` and submits it to the
// host.pdf.generate capability. The UI panel and spreadsheet import land in
// later rounds.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
// Logging goes to stderr; stdout carries only JSON-RPC traffic.
//
// Capability re-entrancy contract (from Minerva broker): while the plugin is
// handling a tools/call, Minerva will NOT send another tools/call. So when a
// handler writes a minerva/capability request to stdout, the next line on
// stdin is guaranteed to be either (a) the matching response (correlated by
// id), or (b) stdin EOF. The synchronous read pattern below is safe under that
// guarantee.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "nametag-maker"
	serverVersion   = "0.0.1"

	// stdinBufferMax bounds a single inbound JSON line. host.pdf.generate
	// replies carry a base64 PDF (contract payload cap is 8 MB); allow headroom
	// for the base64 expansion (~4/3) plus the envelope.
	stdinBufferMax = 16 << 20 // 16 MB
)

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

// outResponse is what we WRITE to stdout (Result is interface{} so we can
// assemble nested maps without manually pre-marshaling).
type outResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

func okResponse(id json.RawMessage, result interface{}) outResponse {
	return outResponse{JSONRPC: "2.0", ID: id, Result: result}
}

func errResponse(id json.RawMessage, code int, msg string) outResponse {
	return outResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &rpcError{Code: code, Message: msg},
	}
}

func send(enc *json.Encoder, v interface{}) {
	if err := enc.Encode(v); err != nil {
		log.Printf("write response: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Host capability client (ported from presentation plugin)
// ---------------------------------------------------------------------------

// hostClient bundles the stdio handles + a request-id sequencer for host
// capability calls. Single-flight by design (see file header).
type hostClient struct {
	enc     *json.Encoder
	scanner *bufio.Scanner
	nextID  int
}

func newHostClient(enc *json.Encoder, scanner *bufio.Scanner) *hostClient {
	return &hostClient{enc: enc, scanner: scanner}
}

// callCapability sends a minerva/capability request and reads stdin until the
// matching response arrives. Returns (result, nil) on success or (nil,
// *rpcError) on transport failure. The result envelope mirrors the broker's
// success/failure dict — callers should still inspect result["success"].
func (c *hostClient) callCapability(capability string, args map[string]interface{}) (json.RawMessage, *rpcError) {
	c.nextID++
	id := fmt.Sprintf(`"cap-%d"`, c.nextID)

	paramsBytes, err := json.Marshal(map[string]interface{}{
		"capability": capability,
		"args":       args,
	})
	if err != nil {
		return nil, &rpcError{Code: -32603, Message: "marshal capability params: " + err.Error()}
	}

	wireReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      json.RawMessage(id),
		"method":  "minerva/capability",
		"params":  json.RawMessage(paramsBytes),
	}
	if err := c.enc.Encode(wireReq); err != nil {
		return nil, &rpcError{Code: -32603, Message: "encode capability request: " + err.Error()}
	}

	// Read stdin until matching id (or EOF). Per the re-entrancy contract the
	// next message MUST be the response — but defensively log and skip anything
	// else rather than blocking the whole plugin on a malformed inbound.
	for c.scanner.Scan() {
		line := c.scanner.Bytes()
		var resp rpcResponse
		if err := json.Unmarshal(line, &resp); err != nil {
			log.Printf("non-json line while waiting for capability response: %s", line)
			continue
		}
		if string(resp.ID) == id {
			if resp.Error != nil {
				return nil, resp.Error
			}
			return resp.Result, nil
		}
		log.Printf("unexpected message id %s while waiting for %s (skipped)", string(resp.ID), id)
	}
	if err := c.scanner.Err(); err != nil {
		return nil, &rpcError{Code: -32603, Message: "stdin read error: " + err.Error()}
	}
	return nil, &rpcError{Code: -32603, Message: "stdin closed waiting for capability response"}
}

// ---------------------------------------------------------------------------
// Tool registry
// ---------------------------------------------------------------------------

// toolFault is a structured failure from tool helpers.
type toolFault struct {
	Code string
	Msg  string
}

func failResult(f *toolFault) map[string]interface{} {
	return toolErr(f.Code, f.Msg)
}

// toolErr builds the standard failure map surfaced to the tool caller.
func toolErr(code, msg string) map[string]interface{} {
	return map[string]interface{}{
		"success":       false,
		"error_code":    code,
		"error_message": msg,
	}
}

// toolList is advertised via tools/list. Auto-prefix policy requires names to
// start with "minerva_<plugin_id>_" — but plugin ids with hyphens are
// normalized; the registered name here matches the task's nametag_generate
// and the host applies its own prefix.
var toolList = []map[string]interface{}{
	{
		"name":        "nametag_generate",
		"description": "Generate a duplex-printable name-tag PDF (cardstock 4×2, Letter) via host.pdf.generate. Provide tag data as `rows` ([{name,class,group,room}]) OR a `csv` string with headers Name/Class/Group #/Room Assignment, plus `icon_png_base64` (bare base64 PNG). Back side mirrors the front column-reversed for duplex registration. Returns {bytes_b64, byte_size, page_count, content_type}.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"rows": map[string]interface{}{
					"type":        "array",
					"description": "Tag rows. Each: {name, class, group, room}. Empty fields are omitted from the tag.",
					"items": map[string]interface{}{
						"type": "object",
						"properties": map[string]interface{}{
							"name":  map[string]interface{}{"type": "string"},
							"class": map[string]interface{}{"type": "string"},
							"group": map[string]interface{}{"type": "string"},
							"room":  map[string]interface{}{"type": "string"},
						},
					},
				},
				"csv": map[string]interface{}{
					"type":        "string",
					"description": "Alternative to rows: CSV text with headers Name, Class, Group #, Room Assignment.",
				},
				"icon_png_base64": map[string]interface{}{
					"type":        "string",
					"description": "Bare base64 PNG used as the per-tag icon (embedded once, referenced by every tag).",
				},
				"back_mode": map[string]interface{}{
					"type":        "string",
					"description": `"same" (default — mirror front onto back, column-reversed) or "blank" (front pages only).`,
				},
				"back_offset_x": map[string]interface{}{"type": "number", "description": "Registration nudge (points) applied to every back-page tag, X axis."},
				"back_offset_y": map[string]interface{}{"type": "number", "description": "Registration nudge (points) applied to every back-page tag, Y axis."},
				"full_guides":   map[string]interface{}{"type": "boolean", "description": "Draw a full bounding rectangle per tag instead of 4 corner marks."},
				"icon_width_in": map[string]interface{}{"type": "number", "description": "Icon width in inches. Default 0.40."},
			},
			"required": []string{"icon_png_base64"},
		},
	},
	{
		"name":        "nametag_save",
		"description": "Generate the name-tag PDF (same inputs as nametag_generate) and save it to a user-chosen location. Pops a save dialog, requests write permission for the picked path, and writes the PDF — all on the backend, so the PDF bytes never cross the webview IPC channel (which caps payloads at 64 KiB). Returns {saved:true, path, bytes_written, page_count}, or {saved:false, cancelled:true} if the user cancels, or {saved:false, error_code, error_message} on error.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"rows": map[string]interface{}{
					"type":        "array",
					"description": "Tag rows. Each: {name, class, group, room}. Empty fields are omitted from the tag.",
					"items": map[string]interface{}{
						"type": "object",
						"properties": map[string]interface{}{
							"name":  map[string]interface{}{"type": "string"},
							"class": map[string]interface{}{"type": "string"},
							"group": map[string]interface{}{"type": "string"},
							"room":  map[string]interface{}{"type": "string"},
						},
					},
				},
				"csv": map[string]interface{}{
					"type":        "string",
					"description": "Alternative to rows: CSV text with headers Name, Class, Group #, Room Assignment.",
				},
				"icon_png_base64": map[string]interface{}{
					"type":        "string",
					"description": "Bare base64 PNG used as the per-tag icon (embedded once, referenced by every tag).",
				},
				"back_mode": map[string]interface{}{
					"type":        "string",
					"description": `"same" (default — mirror front onto back, column-reversed) or "blank" (front pages only).`,
				},
				"back_offset_x": map[string]interface{}{"type": "number", "description": "Registration nudge (points) applied to every back-page tag, X axis."},
				"back_offset_y": map[string]interface{}{"type": "number", "description": "Registration nudge (points) applied to every back-page tag, Y axis."},
				"full_guides":   map[string]interface{}{"type": "boolean", "description": "Draw a full bounding rectangle per tag instead of 4 corner marks."},
				"icon_width_in": map[string]interface{}{"type": "number", "description": "Icon width in inches. Default 0.40."},
			},
			"required": []string{"icon_png_base64"},
		},
	},
}

// dispatchTool routes a tools/call by tool name.
func dispatchTool(client *hostClient, msg *rpcRequest) {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments,omitempty"`
	}
	if err := json.Unmarshal(msg.Params, &p); err != nil {
		send(client.enc, errResponse(msg.ID, -32700, "tools/call: parse params: "+err.Error()))
		return
	}

	switch p.Name {
	case "nametag_generate":
		respondTool(client.enc, msg.ID, toolNametagGenerate(client, p.Arguments))
	case "nametag_save":
		respondTool(client.enc, msg.ID, toolNametagSave(client, p.Arguments))
	default:
		send(client.enc, errResponse(msg.ID, -32601, "tools/call: unknown tool: "+p.Name))
	}
}

// respondTool wraps a tool result in the MCP content envelope and sends it back
// as the tools/call response, flagging isError when success is explicitly false.
func respondTool(enc *json.Encoder, id json.RawMessage, result map[string]interface{}) {
	body, err := json.Marshal(result)
	if err != nil {
		send(enc, errResponse(id, -32603, "marshal tool result: "+err.Error()))
		return
	}
	envelope := map[string]interface{}{
		"content": []map[string]interface{}{
			{"type": "text", "text": string(body)},
		},
	}
	if success, ok := result["success"].(bool); ok && !success {
		envelope["isError"] = true
	}
	send(enc, okResponse(id, envelope))
}

// ---------------------------------------------------------------------------
// Top-level dispatch
// ---------------------------------------------------------------------------

func dispatch(client *hostClient, msg *rpcRequest) {
	isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"

	switch msg.Method {
	case "initialize":
		if isNotification {
			return
		}
		send(client.enc, okResponse(msg.ID, map[string]interface{}{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]interface{}{},
			"serverInfo": map[string]string{
				"name":    serverName,
				"version": serverVersion,
			},
		}))

	case "notifications/initialized":
		log.Printf("notifications/initialized (no-op)")

	case "tools/list":
		if isNotification {
			return
		}
		send(client.enc, okResponse(msg.ID, map[string]interface{}{
			"tools": toolList,
		}))

	case "tools/call":
		if isNotification {
			return
		}
		dispatchTool(client, msg)

	case "shutdown":
		log.Printf("shutdown requested — exiting")
		os.Exit(0)

	default:
		if isNotification {
			log.Printf("unknown notification: %s (ignored)", msg.Method)
			return
		}
		log.Printf("unknown method: %s", msg.Method)
		send(client.enc, errResponse(msg.ID, -32601, "Method not found: "+msg.Method))
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[nametag-maker-plugin] ")
	log.SetOutput(os.Stderr)

	log.Printf("starting (pid=%d)", os.Getpid())

	enc := json.NewEncoder(os.Stdout)
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), stdinBufferMax)
	client := newHostClient(enc, scanner)

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

		dispatch(client, &msg)
	}

	if err := scanner.Err(); err != nil {
		log.Printf("stdin read error: %v", err)
		os.Exit(1)
	}
	log.Printf("stdin closed — exiting")
}
