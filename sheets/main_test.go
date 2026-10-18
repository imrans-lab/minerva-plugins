package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
)

type nopWriteCloser struct{ io.Writer }

func (nopWriteCloser) Close() error { return nil }

func TestProtocol(t *testing.T) {
	input := `{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"foreign_tool"}}
`
	var output bytes.Buffer
	if err := serve(context.Background(), io.NopCloser(strings.NewReader(input)), nopWriteCloser{&output}); err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(&output)
	var initialize, catalog, unknown map[string]json.RawMessage
	for _, reply := range []*map[string]json.RawMessage{&initialize, &catalog, &unknown} {
		if err := decoder.Decode(reply); err != nil {
			t.Fatal(err)
		}
	}
	if !bytes.Contains(initialize["result"], []byte(`"protocolVersion":"2024-11-05"`)) {
		t.Fatal("handshake did not advertise the supported protocol")
	}
	var listed struct{ Tools []struct{ Name string } }
	if err := json.Unmarshal(catalog["result"], &listed); err != nil {
		t.Fatal(err)
	}
	if len(listed.Tools) != 1 || listed.Tools[0].Name != "minerva_sheets_create_editor" {
		t.Fatalf("backend must own only create_editor: %s", catalog["result"])
	}
	if len(unknown["error"]) == 0 {
		t.Fatal("foreign tool did not refuse")
	}
}
