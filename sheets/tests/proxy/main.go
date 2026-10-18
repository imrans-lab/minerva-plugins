// This test-only Go backend probes the real host-to-panel capability route.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
)

func run(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	encoder := json.NewEncoder(output)
	for scanner.Scan() {
		var message struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params struct {
				Arguments map[string]any `json:"arguments"`
			} `json:"params"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &message); err != nil {
			return err
		}
		if len(message.ID) == 0 {
			continue
		}
		var result any
		switch message.Method {
		case "initialize":
			result = map[string]any{"protocolVersion": "2024-11-05", "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]string{"name": "sheets-proxy-fixture", "version": "1.0.0"}}
		case "tools/list":
			result = map[string]any{"tools": []map[string]any{{"name": "probe", "description": "Test the host capability route", "inputSchema": map[string]any{"type": "object"}}}}
		case "tools/call":
			if err := encoder.Encode(map[string]any{"jsonrpc": "2.0", "id": "sheets-capability", "method": "minerva/capability", "params": map[string]any{"capability": "mcp.proxy:minerva_sheets_probe", "args": message.Params.Arguments}}); err != nil {
				return err
			}
			if !scanner.Scan() {
				return fmt.Errorf("host closed without a capability response")
			}
			var response struct {
				ID     string         `json:"id"`
				Result map[string]any `json:"result"`
			}
			if err := json.Unmarshal(scanner.Bytes(), &response); err != nil {
				return err
			}
			if response.ID != "sheets-capability" {
				return fmt.Errorf("unexpected capability response id %q", response.ID)
			}
			body, err := json.Marshal(response.Result)
			if err != nil {
				return err
			}
			result = map[string]any{"isError": response.Result["success"] != true, "content": []map[string]any{{"type": "text", "text": string(body)}}}
		default:
			// A method-not-found discovery reply selects Minerva's legacy profile.
			if err := encoder.Encode(map[string]any{"jsonrpc": "2.0", "id": message.ID, "error": map[string]any{"code": -32601, "message": "Method not found"}}); err != nil {
				return err
			}
			continue
		}
		if err := encoder.Encode(map[string]any{"jsonrpc": "2.0", "id": message.ID, "result": result}); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		log.Fatal(err)
	}
}
