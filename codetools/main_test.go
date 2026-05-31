package main

import (
	"encoding/json"
	"testing"
)

// TestHandleInitialize checks the MCP initialize result carries our protocol
// version and server identity. No worker / python needed.
func TestHandleInitialize(t *testing.T) {
	resp := handleInitialize(json.RawMessage(`1`))
	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error)
	}
	raw, _ := json.Marshal(resp.Result)
	var got struct {
		ProtocolVersion string `json:"protocolVersion"`
		ServerInfo      struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"serverInfo"`
	}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if got.ProtocolVersion != protocolVersion {
		t.Errorf("protocolVersion = %q, want %q", got.ProtocolVersion, protocolVersion)
	}
	if got.ServerInfo.Name != serverName {
		t.Errorf("serverInfo.name = %q, want %q", got.ServerInfo.Name, serverName)
	}
}

// TestHandleToolsListExposesPing checks the registry surfaces exactly the
// namespaced health tool at the substrate phase.
func TestHandleToolsListExposesPing(t *testing.T) {
	initRegistry()
	resp := handleToolsList(json.RawMessage(`2`))
	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error)
	}
	raw, _ := json.Marshal(resp.Result)
	var got struct {
		Tools []struct {
			Name string `json:"name"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if len(got.Tools) != 1 {
		t.Fatalf("want 1 tool, got %d: %+v", len(got.Tools), got.Tools)
	}
	if got.Tools[0].Name != "minerva_codetools_ping" {
		t.Errorf("tool name = %q, want minerva_codetools_ping", got.Tools[0].Name)
	}
}
