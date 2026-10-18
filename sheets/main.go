// Command sheets-plugin serves the spreadsheet editor's backend creation tool.
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
)

//go:embed manifest.json
var manifestBytes []byte

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
	Result  json.RawMessage `json:"result"`
	Error   *rpcError       `json:"error"`
}

func serve(ctx context.Context, input io.ReadCloser, output io.WriteCloser) error {
	// Closing the actual pipes interrupts both a blocked Scan and Encode.
	stopClosing := context.AfterFunc(ctx, func() {
		for _, stream := range []io.Closer{input, output} {
			if err := stream.Close(); err != nil {
				log.Printf("close cancelled RPC stream: %v", err)
			}
		}
	})
	defer stopClosing()
	var manifest struct {
		Version string           `json:"version"`
		Tools   []map[string]any `json:"tools"`
	}
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		return fmt.Errorf("read embedded manifest: %w", err)
	}
	tools := make([]map[string]any, 0, 1)
	for _, tool := range manifest.Tools {
		if tool["executor"] == "backend" {
			tools = append(tools, map[string]any{"name": tool["name"], "description": tool["description"], "inputSchema": tool["input_schema"]})
		}
	}
	stream := newStream(input, output)
	// The host persists the real model via __panel_state. Sheets has no
	// backend-owned document state or sidecar files to serialize or export.
	projectReplies := map[string]string{
		"sheets.serialize":      `{"tab_state":{},"sidecar_paths":[]}`,
		"sheets.deserialize":    `{"ok":true}`,
		"sheets.collect_export": `{"files":[]}`,
		"sheets.apply_export":   `{"ok":true}`,
	}
	for stream.next(ctx) {
		var message request
		if err := json.Unmarshal(stream.current, &message); err != nil {
			if err := stream.write(ctx, map[string]any{"jsonrpc": "2.0", "id": nil, "error": map[string]any{"code": -32700, "message": "Invalid JSON"}}); err != nil {
				return err
			}
			continue
		}
		if len(message.ID) == 0 || string(message.ID) == "null" || message.Method == "" {
			continue
		}
		reply := map[string]any{"jsonrpc": "2.0", "id": message.ID}
		switch message.Method {
		case "initialize":
			reply["result"] = map[string]any{"protocolVersion": "2024-11-05", "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "sheets", "version": manifest.Version}}
		case "ping":
			reply["result"] = map[string]any{}
		case "tools/list":
			reply["result"] = map[string]any{"tools": tools}
		case "tools/call":
			var call struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			}
			if err := json.Unmarshal(message.Params, &call); err != nil {
				reply["error"] = map[string]any{"code": -32602, "message": "Invalid tool arguments"}
			} else if body, ok := projectReplies[call.Name]; ok {
				reply["result"] = map[string]any{"content": []map[string]any{{"type": "text", "text": body}}}
			} else if call.Name != "minerva_sheets_create_editor" {
				reply["error"] = map[string]any{"code": -32602, "message": "Unknown tool"}
			} else {
				stream.activeID = message.ID
				body := createEditor(ctx, stream, call.Arguments)
				stream.activeID = nil
				encoded, err := json.Marshal(body)
				if err != nil {
					return fmt.Errorf("encode creation result: %w", err)
				}
				reply["result"] = map[string]any{"isError": body["success"] != true,
					"content": []map[string]any{{"type": "text", "text": string(encoded)}}}
			}
		default:
			reply["error"] = map[string]any{"code": -32601, "message": "Method not found"}
		}
		if err := stream.write(ctx, reply); err != nil {
			return fmt.Errorf("write reply: %w", err)
		}
	}
	return stream.readError(ctx)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := serve(ctx, os.Stdin, os.Stdout); err != nil {
		log.Fatal(err)
	}
}
