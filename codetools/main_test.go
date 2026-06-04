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

// TestHandleToolsListExposesRegisteredTools checks tools/list returns every
// registered tool: the substrate ping plus the 9 code-visualizer tools added
// in P1.3, and the get_graph tool added in P1.4. Asserting names (not just
// count) catches an accidental rename or missing Register call.
func TestHandleToolsListExposesRegisteredTools(t *testing.T) {
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
	want := []string{
		"minerva_codetools_ping",
		// P1.3 — code-visualizer (vendored @9cc9403)
		"minerva_codetools_query",
		"minerva_codetools_get_context",
		"minerva_codetools_stale_check",
		"minerva_codetools_get_diff",
		"minerva_codetools_analyze",
		"minerva_codetools_set_description",
		"minerva_codetools_describe_symbol",
		"minerva_codetools_set_tags",
		"minerva_codetools_undescribed",
		// P1.4 — full code graph with precomputed layout
		"minerva_codetools_get_graph",
		// P2.1 — file primitives
		"minerva_codetools_glob",
		"minerva_codetools_grep",
		"minerva_codetools_bash",
		"minerva_codetools_cwd",
		// P3.2 — code-probe (vendored sightline)
		"minerva_codetools_explore",
		"minerva_codetools_inspect",
		"minerva_codetools_validate",
	}
	if len(got.Tools) != len(want) {
		t.Fatalf("want %d tools, got %d: %+v", len(want), len(got.Tools), got.Tools)
	}
	seen := make(map[string]bool, len(got.Tools))
	for _, t := range got.Tools {
		seen[t.Name] = true
	}
	for _, name := range want {
		if !seen[name] {
			t.Errorf("missing registered tool: %s", name)
		}
	}
}
