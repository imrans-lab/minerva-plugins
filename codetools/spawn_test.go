// spawn_test.go — P1.1 functional gate (no stubs).
//
// Builds the REAL codetools-plugin binary and drives a full MCP handshake +
// minerva_codetools_ping over stdio, asserting the call round-trips through a
// real Python worker and returns pong=true with the echo preserved.
//
// Tier-agnostic: uses the embedded PBS bundle when one is staged (Tier 1),
// otherwise the Go shim falls through to system python3 (Tier 3). The binary
// is built into the module dir so the Tier-3 worker cwd (<plugin>/worker)
// resolves codetools_worker. go:embed requires SOME bundle file to compile —
// if `go build` errors with a missing bundle, run:
//
//	scripts/dev-make-placeholder-bundle.sh
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func hostBundleTriple() string {
	switch runtime.GOOS + "/" + runtime.GOARCH {
	case "darwin/arm64":
		return "macos-arm64"
	case "darwin/amd64":
		return "macos-amd64"
	case "linux/amd64":
		return "linux-x86_64"
	case "windows/amd64":
		return "windows-x86_64"
	}
	return ""
}

func TestPingRoundTrip(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test; -short")
	}

	// Decide whether we can run a worker at all: a real embedded bundle (Tier 1)
	// or system python3 (Tier 3). A sub-1KB bundle is a dev placeholder that
	// deliberately fails extraction and falls through to python3.
	triple := hostBundleTriple()
	realBundle := false
	if triple != "" {
		p := filepath.Join("internal", "runtime", "bundle", "runtime-bundle-"+triple+".tar.zst")
		if info, err := os.Stat(p); err == nil && info.Size() >= 1024 {
			realBundle = true
		}
	}
	if !realBundle {
		if _, err := exec.LookPath("python3"); err != nil {
			t.Skip("no embedded bundle staged and no system python3 — cannot run the worker")
		}
	}

	// Build into the module dir so pluginRoot resolves worker/ as a sibling.
	binName := "codetools-plugin.testbin"
	if runtime.GOOS == "windows" {
		binName += ".exe"
	}
	build := exec.Command("go", "build", "-o", binName, ".")
	build.Stdout, build.Stderr = os.Stdout, os.Stderr
	if err := build.Run(); err != nil {
		t.Fatalf("go build: %v (run scripts/dev-make-placeholder-bundle.sh if go:embed reports a missing bundle)", err)
	}
	binPath, err := filepath.Abs(binName)
	if err != nil {
		t.Fatalf("abs bin path: %v", err)
	}
	defer os.Remove(binPath)

	dataDir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, binPath)
	cmd.Env = append(os.Environ(), "MINERVA_PLUGIN_DATA_DIR="+dataDir)
	cmd.Stderr = os.Stderr // forward worker stderr for failure diagnosis
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start binary: %v", err)
	}
	defer func() {
		_ = stdin.Close()
		_ = cmd.Wait()
	}()

	br := bufio.NewReader(stdout)
	enc := json.NewEncoder(stdin)

	readResp := func() map[string]any {
		line, err := br.ReadBytes('\n')
		if err != nil {
			t.Fatalf("read response: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal(line, &m); err != nil {
			t.Fatalf("decode %q: %v", string(line), err)
		}
		return m
	}
	readID := func(want float64) map[string]any {
		for {
			m := readResp()
			if id, ok := m["id"].(float64); ok && id == want {
				return m
			}
			t.Logf("ignored intermediate: %v", m)
		}
	}

	// 1) initialize
	if err := enc.Encode(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": map[string]any{},
	}); err != nil {
		t.Fatalf("encode initialize: %v", err)
	}
	if r := readID(1); r["error"] != nil {
		t.Fatalf("initialize error: %v", r["error"])
	}

	// 2) initialized notification (no response)
	_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})

	// 3) tools/call minerva_codetools_ping — first call lazily spawns the worker.
	if err := enc.Encode(map[string]any{
		"jsonrpc": "2.0", "id": 2, "method": "tools/call",
		"params": map[string]any{
			"name":      "minerva_codetools_ping",
			"arguments": map[string]any{"echo": "hi"},
		},
	}); err != nil {
		t.Fatalf("encode ping: %v", err)
	}
	resp := readID(2)
	if resp["error"] != nil {
		t.Fatalf("FUNCTIONAL FAIL: ping JSON-RPC error: %v", resp["error"])
	}

	// Unwrap MCP envelope: result.content[0].text → {ok:true, result:{...}}.
	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("missing result: %v", resp)
	}
	content, ok := result["content"].([]any)
	if !ok || len(content) == 0 {
		t.Fatalf("missing content: %v", result)
	}
	first, _ := content[0].(map[string]any)
	text, _ := first["text"].(string)
	var env map[string]any
	if err := json.Unmarshal([]byte(text), &env); err != nil {
		t.Fatalf("decode envelope %q: %v", text, err)
	}
	if env["ok"] != true {
		t.Fatalf("FUNCTIONAL FAIL: envelope ok != true: %v", env)
	}
	inner, ok := env["result"].(map[string]any)
	if !ok {
		t.Fatalf("missing inner result: %v", env)
	}
	if inner["pong"] != true {
		t.Fatalf("FUNCTIONAL FAIL: pong != true: %v", inner)
	}
	if inner["echo"] != "hi" {
		t.Errorf("echo = %v, want \"hi\"", inner["echo"])
	}
	t.Logf("FUNCTIONAL PASS: ping round-trip via real worker: %v", inner)

	// 4) graceful shutdown
	_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": 3, "method": "shutdown"})
}
