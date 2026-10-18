package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

func TestCreationWire(t *testing.T) {
	fixture, err := os.ReadFile("tests/fixtures/tool-cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases struct{ Creation [][]json.RawMessage }
	if err := json.Unmarshal(fixture, &cases); err != nil {
		t.Fatal(err)
	}
	for index, name := range []string{"name", "CSV", "CSV file", "native file", "missing file", "provider not ready", "step two failure", "existing name"} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			host, plugin := net.Pipe()
			defer host.Close()
			done := make(chan error, 1)
			go func() { done <- serve(ctx, plugin, plugin) }()
			enc, dec := json.NewEncoder(host), newWireDecoder(host)
			if err := enc.Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
				"params": map[string]any{"name": "minerva_sheets_create_editor", "arguments": cases.Creation[index][1]}}); err != nil {
				t.Fatal(err)
			}
			var capabilities []string
			var body map[string]any
			for body == nil {
				var message request
				if err := dec.Decode(&message); err != nil {
					t.Fatal(err)
				}
				if message.Method == "" {
					var result struct{ Content []struct{ Text string } }
					if err := json.Unmarshal(message.Result, &result); err != nil {
						t.Fatal(err)
					}
					if len(result.Content) != 1 {
						t.Fatal("missing application result")
					}
					if err := json.Unmarshal([]byte(result.Content[0].Text), &body); err != nil {
						t.Fatal(err)
					}
					break
				}
				var capability struct {
					Capability string         `json:"capability"`
					Args       map[string]any `json:"args"`
				}
				if message.Method != "minerva/capability" {
					t.Fatalf("unexpected method %s", message.Method)
				}
				if err := json.Unmarshal(message.Params, &capability); err != nil {
					t.Fatal(err)
				}
				capabilities = append(capabilities, capability.Capability)
				result := map[string]any{"success": true, "editor_name": "Created tab", "plugin_id": "sheets"}
				if capability.Capability == "host.documents.list_open" {
					result = map[string]any{"documents": []any{}}
					if index == 7 {
						result["documents"] = []any{map[string]any{"editor_name": "Created CSV"}}
					}
				}
				if strings.HasSuffix(capability.Capability, "get_data") {
					if capability.Args["range"] != "A1" {
						t.Fatalf("import verification must be bounded: %#v", capability.Args)
					}
					result["used_row_count"] = 2
					result["used_column_count"] = 2
					result["row_count"] = 100
					result["column_count"] = 1
					result["allocated_column_count"] = 26
				}
				envelope := map[string]any{"success": true, "result": result}
				if index == 4 || index == 5 || (index == 6 && len(capabilities) == 3) {
					envelope = failure([]string{"file_not_found", "provider_not_ready", "capability_not_granted"}[index-4], "explicit host refusal")
				}
				if err := enc.Encode(map[string]any{"jsonrpc": "2.0", "id": message.ID, "result": envelope}); err != nil {
					t.Fatal(err)
				}
			}
			if index == 7 {
				if body["success"] != true || body["already_existed"] != true || body["editor_name"] != "Created CSV" {
					t.Fatalf("existing title was not preserved: %#v", body)
				}
			} else if index < 4 {
				if body["success"] != true || body["editor_name"] != "Created tab" {
					t.Fatalf("creation: %#v", body)
				}
				if index > 0 && body["rows_imported"] != float64(2) {
					t.Fatalf("missing independently verified imported rows: %#v", body)
				}
			} else if body["success"] != false {
				t.Fatalf("host refusal became success: %#v", body)
			}
			if index == 6 && (body["editor_name"] != "Created tab" || !strings.Contains(body["error_message"].(string), "Created tab")) {
				t.Fatalf("second-step failure must name the surviving tab: %#v", body)
			}
			wantCalls := []int{2, 4, 2, 2, 1, 1, 3, 1}[index]
			if len(capabilities) != wantCalls {
				t.Fatalf("unexpected operations after refusal: %v", capabilities)
			}
			if err := host.Close(); err != nil {
				t.Fatal(err)
			}
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestCancellationInterruptsBlockedInput(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	host, plugin := net.Pipe()
	defer host.Close()
	done := make(chan error, 1)
	go func() { done <- serve(ctx, plugin, plugin) }()
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancellation lost: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("blocked input ignored cancellation")
	}
}

func TestCancellationDuringCapabilityWait(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	host, plugin := net.Pipe()
	defer host.Close()
	done := make(chan error, 1)
	go func() { done <- serve(ctx, plugin, plugin) }()
	enc, dec := json.NewEncoder(host), newWireDecoder(host)
	if err := enc.Encode(map[string]any{"jsonrpc": "2.0", "id": 7, "method": "tools/call",
		"params": map[string]any{"name": "minerva_sheets_create_editor", "arguments": map[string]any{}}}); err != nil {
		t.Fatal(err)
	}
	var capability request
	if err := dec.Decode(&capability); err != nil {
		t.Fatal(err)
	}
	if capability.Method != "minerva/capability" {
		t.Fatal("creation did not reach its real capability wait")
	}
	if err := enc.Encode(map[string]any{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": map[string]any{"requestId": 7}}); err != nil {
		t.Fatal(err)
	}
	var reply request
	if err := dec.Decode(&reply); err != nil {
		t.Fatal(err)
	}
	if reply.Method != "" || !strings.Contains(string(reply.Result), "cancelled") {
		t.Fatalf("cancelled call continued orchestration: %s", reply.Result)
	}
	if err := host.Close(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestImportVerificationRefusals(t *testing.T) {
	for _, name := range []string{"ordinary error", "schema failure", "cancelled", "missing count", "fractional rows", "negative rows", "rows exceed allocation", "negative columns", "inconsistent empty", "empty allocation"} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			host, plugin := net.Pipe()
			defer host.Close()
			done := make(chan error, 1)
			go func() { done <- serve(ctx, plugin, plugin) }()
			enc, dec := json.NewEncoder(host), newWireDecoder(host)
			if err := enc.Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": map[string]any{
				"name": "minerva_sheets_create_editor", "arguments": map[string]any{"name": "Import", "file_path": "fixture.csv"}}}); err != nil {
				t.Fatal(err)
			}
			var calls []string
			for {
				var message request
				if err := dec.Decode(&message); err != nil {
					t.Fatal(err)
				}
				if message.Method == "" {
					var result struct{ Content []struct{ Text string } }
					if err := json.Unmarshal(message.Result, &result); err != nil {
						t.Fatal(err)
					}
					if len(result.Content) != 1 {
						t.Fatalf("missing refusal: %#v", message)
					}
					var body map[string]any
					if err := json.Unmarshal([]byte(result.Content[0].Text), &body); err != nil {
						t.Fatal(err)
					}
					if body["success"] != false || body["error_code"] != "import_verification_failed" || body["editor_name"] != "Surviving import" || len(calls) != 2 {
						t.Fatalf("verification must refuse without retry and retain editor identity: %#v calls=%v", body, calls)
					}
					break
				}
				var capability struct {
					Capability string         `json:"capability"`
					Args       map[string]any `json:"args"`
				}
				if message.Method != "minerva/capability" {
					t.Fatalf("unexpected method %s", message.Method)
				}
				if err := json.Unmarshal(message.Params, &capability); err != nil {
					t.Fatal(err)
				}
				calls = append(calls, capability.Capability)
				var envelope map[string]any
				switch len(calls) {
				case 1:
					if capability.Capability != "mcp.proxy:minerva_open_file" {
						t.Fatalf("unexpected first operation %s", capability.Capability)
					}
					envelope = map[string]any{"success": true, "result": map[string]any{"success": true, "editor_name": "Surviving import", "plugin_id": "sheets"}}
				case 2:
					if capability.Capability != "mcp.proxy:minerva_sheets_get_data" || capability.Args["range"] != "A1" {
						t.Fatalf("unexpected verification %#v", capability)
					}
					envelope = map[string]any{"success": false, "error_code": "cell_too_large", "used_row_count": 2, "used_column_count": 2, "row_count": 100, "column_count": 26, "allocated_column_count": 26}
					switch name {
					case "ordinary error":
						envelope["error_code"] = "read_failed"
					case "schema failure":
						envelope["error_code"] = "schema_mismatch"
					case "cancelled":
						envelope["error_code"] = "cancelled"
					case "missing count":
						delete(envelope, "used_column_count")
					case "fractional rows":
						envelope["used_row_count"] = 2.5
					case "negative rows":
						envelope["used_row_count"] = -1
					case "rows exceed allocation":
						envelope["used_row_count"] = 101
					case "negative columns":
						envelope["used_column_count"] = -1
					case "inconsistent empty":
						envelope["used_row_count"] = 0
					case "empty allocation":
						envelope["used_row_count"], envelope["used_column_count"], envelope["row_count"] = 0, 0, 0
					}
				default:
					t.Fatalf("verification retried a mutation: %v", calls)
				}
				if err := enc.Encode(map[string]any{"jsonrpc": "2.0", "id": message.ID, "result": envelope}); err != nil {
					t.Fatal(err)
				}
			}
			if err := host.Close(); err != nil {
				t.Fatal(err)
			}
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		})
	}
}
