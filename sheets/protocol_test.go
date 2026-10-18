package main

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"reflect"
	"testing"
	"time"
)

func TestRequestsSurviveCapabilityWaitFIFO(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	host, plugin := net.Pipe()
	defer host.Close()
	done := make(chan error, 1)
	go func() { done <- serve(ctx, plugin, plugin) }()
	enc, dec := json.NewEncoder(host), newWireDecoder(host)
	send := func(value any) {
		t.Helper()
		if err := enc.Encode(value); err != nil {
			t.Fatal(err)
		}
	}
	fixture, err := os.ReadFile("tests/fixtures/tool-cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases struct{ Creation [][]json.RawMessage }
	if err := json.Unmarshal(fixture, &cases); err != nil {
		t.Fatal(err)
	}
	create := func(id int) map[string]any {
		return map[string]any{"jsonrpc": "2.0", "id": id, "method": "tools/call",
			"params": map[string]any{"name": "minerva_sheets_create_editor", "arguments": cases.Creation[0][1]}}
	}
	send(create(1))
	var first request
	if err := dec.Decode(&first); err != nil || first.Method != "minerva/capability" {
		t.Fatalf("first create did not suspend in a capability wait: %v", err)
	}
	send(map[string]any{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": map[string]any{"name": "sheets.serialize"}})
	send(create(3))
	send(map[string]any{"jsonrpc": "2.0", "id": 4, "method": "tools/list"})
	send(map[string]any{"jsonrpc": "2.0", "id": 5, "method": "ping"})
	send(map[string]any{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": map[string]any{"requestId": 5}})
	var cancelled request
	if err := dec.Decode(&cancelled); err != nil || string(cancelled.ID) != "5" || cancelled.Error == nil || cancelled.Error.Code != -32800 {
		t.Fatalf("queued cancellation lost: %#v %v", cancelled, err)
	}
	respond := func(message request) {
		var capability struct{ Capability string }
		if err := json.Unmarshal(message.Params, &capability); err != nil {
			t.Fatal(err)
		}
		result := map[string]any{"success": true, "editor_name": "Created tab"}
		if capability.Capability == "host.documents.list_open" {
			result = map[string]any{"documents": []any{}}
		}
		send(map[string]any{"jsonrpc": "2.0", "id": message.ID, "result": map[string]any{"success": true, "result": result}})
	}
	respond(first)
	var replies []string
	capabilities := 1
	for len(replies) != 4 {
		var message request
		if err := dec.Decode(&message); err != nil {
			t.Fatal(err)
		}
		if message.Method == "minerva/capability" {
			capabilities++
			respond(message)
			continue
		}
		if message.Error != nil || len(message.Result) == 0 {
			t.Fatalf("queued request failed: %#v", message)
		}
		replies = append(replies, string(message.ID))
	}
	if !reflect.DeepEqual(replies, []string{"1", "2", "3", "4"}) || capabilities != 4 {
		t.Fatalf("requests lost or reordered: replies=%v capabilities=%d", replies, capabilities)
	}
	if err := host.Close(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
