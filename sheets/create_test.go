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
