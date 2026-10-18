// Command sheets-plugin serves the spreadsheet editor's backend creation tool.
package main

import (
	"bufio"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
)

//go:embed manifest.json
var manifestBytes []byte

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

func serve(input io.Reader, output io.Writer) error {
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
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 16<<20)
	encoder := json.NewEncoder(output)
	for scanner.Scan() {
		var message request
		if err := json.Unmarshal(scanner.Bytes(), &message); err != nil {
			if err := encoder.Encode(map[string]any{"jsonrpc": "2.0", "id": nil, "error": map[string]any{"code": -32700, "message": "Invalid JSON"}}); err != nil {
				return err
			}
			continue
		}
		if len(message.ID) == 0 || string(message.ID) == "null" {
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
				Name string `json:"name"`
			}
			if err := json.Unmarshal(message.Params, &call); err != nil {
				reply["error"] = map[string]any{"code": -32602, "message": "Invalid tool arguments"}
			} else if call.Name != "minerva_sheets_create_editor" {
				reply["error"] = map[string]any{"code": -32602, "message": "Unknown tool"}
			} else {
				reply["result"] = map[string]any{"isError": true, "content": []map[string]any{{"type": "text", "text": `{"success":false,"error_code":"sheets_staging","error_message":"Spreadsheet creation is not available in this staging build."}`}}}
			}
		default:
			reply["error"] = map[string]any{"code": -32601, "message": "Method not found"}
		}
		if err := encoder.Encode(reply); err != nil {
			return fmt.Errorf("write reply: %w", err)
		}
	}
	return scanner.Err()
}

func main() {
	if err := serve(os.Stdin, os.Stdout); err != nil {
		log.Fatal(err)
	}
}
