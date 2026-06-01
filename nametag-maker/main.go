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
// ---------------------------------------------------------------------------
// Tool input-schema builders (shared between nametag_generate and nametag_save).
// The host passes nested args through as objects ONLY if the schema declares
// their shape, so faces/columns/images must be described here.
// ---------------------------------------------------------------------------

func linesSchema() map[string]interface{} {
	return map[string]interface{}{
		"type":        "array",
		"description": `Stacked lines. {label,value} renders "Label: Value"; value-only renders the value alone (e.g. "9:30 Snack").`,
		"items": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"label": map[string]interface{}{"type": "string"},
				"value": map[string]interface{}{"type": "string"},
			},
		},
	}
}

// faceSchema describes one tag face (front or back): structured content
// (image_id + title + subtitle + columns of lines) OR a full-tag image.
func faceSchema(role string) map[string]interface{} {
	return map[string]interface{}{
		"type":        "object",
		"description": role + ": structured (image_id + title + subtitle + columns) OR a full-tag image (full_image_id).",
		"properties": map[string]interface{}{
			"image_id":   map[string]interface{}{"type": "string", "description": `Image id to show on a side ("icon" = the shared icon; or any id from images[]).`},
			"image_side": map[string]interface{}{"type": "string", "description": "left (default) or right."},
			"title":      map[string]interface{}{"type": "string", "description": "Big bold line (e.g. first name)."},
			"subtitle":   map[string]interface{}{"type": "string", "description": "Bold line under the title (e.g. last name)."},
			"columns": map[string]interface{}{
				"type":        "array",
				"description": "One or more columns of lines rendered side-by-side (e.g. a two-day schedule).",
				"items": map[string]interface{}{
					"type": "object",
					"properties": map[string]interface{}{
						"heading": map[string]interface{}{"type": "string", "description": "Optional bold column heading."},
						"lines":   linesSchema(),
					},
				},
			},
			"full_image_id": map[string]interface{}{"type": "string", "description": "If set, fill the tag with this image id (overrides the structured fields)."},
		},
	}
}

func rowsSchema() map[string]interface{} {
	return map[string]interface{}{
		"type":        "array",
		"description": "Tag rows. Classic: {name,class,group,room}. Detailed: {title,subtitle,lines}. Generic: {front,back} faces.",
		"items": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"name":     map[string]interface{}{"type": "string"},
				"class":    map[string]interface{}{"type": "string"},
				"group":    map[string]interface{}{"type": "string"},
				"room":     map[string]interface{}{"type": "string"},
				"title":    map[string]interface{}{"type": "string", "description": "Detailed: big bold line (e.g. first name)."},
				"subtitle": map[string]interface{}{"type": "string", "description": "Detailed: bold line under the title (e.g. last name)."},
				"lines":    linesSchema(),
				"front":    faceSchema("Front face for this tag (overrides the flat title/subtitle/lines)"),
				"back":     faceSchema("Back face for this tag (overrides the shared back)"),
			},
		},
	}
}

func imagesSchema() map[string]interface{} {
	return map[string]interface{}{
		"type":        "array",
		"description": "Extra named images (beyond the shared icon) that faces reference by id. Each: {id, png_base64 | path}.",
		"items": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"id":         map[string]interface{}{"type": "string"},
				"png_base64": map[string]interface{}{"type": "string"},
				"path":       map[string]interface{}{"type": "string", "description": "Absolute path, read on the backend via host.files.read."},
			},
		},
	}
}

// sharedProps are the input-schema properties common to both tools.
func sharedProps() map[string]interface{} {
	return map[string]interface{}{
		"rows":            rowsSchema(),
		"csv":             map[string]interface{}{"type": "string", "description": "Alternative to rows: CSV with headers Name, Class, Group #, Room Assignment."},
		"rows_path":       map[string]interface{}{"type": "string", "description": "Absolute path to a JSON file holding the rows array (same shape as rows), read on the backend — use instead of inline rows for large rosters."},
		"icon_png_base64": map[string]interface{}{"type": "string", "description": `Bare base64 PNG for the shared icon (image id "icon").`},
		"icon_path":       map[string]interface{}{"type": "string", "description": "Absolute path to a PNG icon, read on the backend (use instead of icon_png_base64 for large images)."},
		"images":          imagesSchema(),
		"back":            faceSchema("Shared back face drawn behind EVERY tag (e.g. a common schedule), aligned for duplex; a per-row back overrides it"),
		"back_mode":       map[string]interface{}{"type": "string", "description": `"same" (mirror front, reversible) or "blank" (front only). Default: same for classic, blank for detailed/faces.`},
		"back_offset_x":   map[string]interface{}{"type": "number", "description": "Duplex registration nudge (points), X axis."},
		"back_offset_y":   map[string]interface{}{"type": "number", "description": "Duplex registration nudge (points), Y axis."},
		"full_guides":     map[string]interface{}{"type": "boolean", "description": "Full bounding rectangle per tag instead of 4 corner-cut marks."},
		"icon_width_in":   map[string]interface{}{"type": "number", "description": "Icon/image width in inches. Default 0.40 (classic) / 1.0 (detailed)."},
		"layout":          map[string]interface{}{"type": "string", "description": "classic or detailed. Per-row front/back faces or a shared back also switch to the generic renderer."},
		"image_side":      map[string]interface{}{"type": "string", "description": "Flat-detailed front image side: left (default) or right."},
	}
}

func generateInputSchema() map[string]interface{} {
	return map[string]interface{}{"type": "object", "properties": sharedProps()}
}

func saveInputSchema() map[string]interface{} {
	props := sharedProps()
	props["path"] = map[string]interface{}{"type": "string", "description": "Absolute destination path. Provided → write directly (no dialog); omitted → save picker."}
	return map[string]interface{}{"type": "object", "properties": props}
}

func buildFromSheetInputSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object",
		"properties": map[string]interface{}{
			"rows_json": map[string]interface{}{"type": "string", "description": "JSON array of sheet row objects ({column: value}) — e.g. from minerva_get_spreadsheet_data. Passed as a STRING (columns are arbitrary per use case)."},
			"mapping": map[string]interface{}{
				"type":        "object",
				"description": "Which spreadsheet columns map onto each tag field.",
				"properties": map[string]interface{}{
					"title":    map[string]interface{}{"type": "string", "description": "Column for the tag's big bold name."},
					"subtitle": map[string]interface{}{"type": "string", "description": "Column for the subtitle line."},
					"lines": map[string]interface{}{
						"type":        "array",
						"description": "Detail lines: each is a fixed label + the column holding the value (empty values are omitted).",
						"items": map[string]interface{}{
							"type": "object",
							"properties": map[string]interface{}{
								"label":  map[string]interface{}{"type": "string"},
								"column": map[string]interface{}{"type": "string"},
							},
						},
					},
				},
			},
			"layout":             map[string]interface{}{"type": "string", "description": "classic or detailed (default detailed)."},
			"image_side":         map[string]interface{}{"type": "string", "description": "left (default) or right."},
			"back_mode":          map[string]interface{}{"type": "string", "description": `"blank" (default) or "same" (mirror front, reversible).`},
			"full_guides":        map[string]interface{}{"type": "boolean", "description": "Full box per tag instead of corner-cut marks."},
			"icon_width_in":      map[string]interface{}{"type": "number", "description": "Icon/image width in inches."},
			"out_path":           map[string]interface{}{"type": "string", "description": "Absolute destination path for the .mtags document."},
			"title":              map[string]interface{}{"type": "string", "description": "Document title."},
			"sheet_ref":          map[string]interface{}{"type": "string", "description": "Optional reference to the source spreadsheet (editor name or path)."},
			"preview_first_only": map[string]interface{}{"type": "boolean", "description": "Render the preview for only the FIRST tag (single-draft review); the .mtags still stores all rows."},
		},
	}
}

var toolList = []map[string]interface{}{
	{
		"name":        "nametag_generate",
		"description": "Generate a name-tag PDF via host.pdf.generate and return the bytes. Tags are 3-3/8 x 2-1/3 in (Avery 5395), 8 per Letter sheet, corner-cut marks. Layouts: classic (icon + name/class/room/group), detailed (image + big name + detail lines), or fully generic front/back faces. A shared `back` (or per-row back) draws a second side aligned for duplex (e.g. a schedule). Returns {bytes_b64, byte_size, page_count, content_type}.",
		"inputSchema": generateInputSchema(),
	},
	{
		"name":        "nametag_save",
		"description": "Like nametag_generate, but writes the PDF to disk on the backend (bytes never cross the 64 KiB webview channel). Pass `path` to write directly with no dialog; omit it for a save picker. Returns {saved, path, bytes_written, page_count}, or {saved:false, cancelled:true} on picker cancel.",
		"inputSchema": saveInputSchema(),
	},
	{
		"name":        "nametag_build_from_sheet",
		"description": "Build a .mtags nametag document from spreadsheet rows. The caller reads the sheet (minerva_get_spreadsheet_data) and passes rows_json + a column mapping; this deterministically maps columns → tag rows, renders a preview PDF (the first tag only when preview_first_only — the single-draft review), writes the preview + the .mtags to disk, and returns the .mtags path to open. The standard columns are just a suggestion — the mapping makes it work for any sheet.",
		"inputSchema": buildFromSheetInputSchema(),
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
	case "nametag_build_from_sheet":
		respondTool(client.enc, msg.ID, toolNametagBuildFromSheet(client, p.Arguments))
	case "nametag.render":
		respondTool(client.enc, msg.ID, toolNametagRender(client, p.Arguments))
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
