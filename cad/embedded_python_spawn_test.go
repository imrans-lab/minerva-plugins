// embedded_python_spawn_test.go — W1c Layer 2 verification gate.
//
// Builds the cad-plugin binary with the embedded PBS python bundle, spawns
// it under an isolated MINERVA_PLUGIN_DATA_DIR with a scrubbed env, performs
// the MCP handshake, calls mcad_validate with a known-good source, and
// asserts the worker reports ok=true.
//
// This is the W1c done-gate per DCR 019e6a4bcb0c. Proves end-to-end that:
//   - go:embed wired the bundle into the binary (binary size > 100MB).
//   - EnsureRuntime extracts the bundle on first spawn.
//   - bridge.Worker.buildEnv() sets PYTHONHOME / PYTHONPATH correctly.
//   - cmd.Dir fix means worker spawn doesn't fail on the missing
//     <plugin>/worker/ dir that marketplace installs lack.
//   - mcad_worker dispatcher framing + validate method round-trip works.
//
// SKIPs cleanly when the bundle for the host platform isn't staged
// (developer hasn't run scripts/build-python-runtime-bundle.sh). The SKIP
// message tells the developer exactly what to run.

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// hostBundleTriple returns the bundle naming triple for the current host,
// or "" if the host platform isn't a supported bundle target.
func hostBundleTriple() string {
	switch runtime.GOOS + "/" + runtime.GOARCH {
	case "darwin/arm64":
		return "macos-arm64"
	case "darwin/amd64":
		return "macos-amd64"
	case "linux/amd64":
		return "linux-x86_64"
	case "linux/arm64":
		return "linux-arm64"
	case "windows/amd64":
		return "windows-x86_64"
	}
	return ""
}

// TestEmbeddedPythonSpawn is the W1c Layer 2 gate.
func TestEmbeddedPythonSpawn(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test; -short")
	}

	triple := hostBundleTriple()
	if triple == "" {
		t.Skipf("unsupported host: %s/%s", runtime.GOOS, runtime.GOARCH)
	}

	// Bundle path is relative to the cad/ module root (where this test lives).
	bundlePath := filepath.Join("internal", "runtime", "bundle", "runtime-bundle-"+triple+".tar.zst")
	if info, err := os.Stat(bundlePath); err != nil || info.Size() < 1024 {
		t.Skipf("bundle missing/empty at %s — run: scripts/build-python-runtime-bundle.sh cad %s", bundlePath, triple)
	}

	// Build the cad-plugin binary with the embedded bundle.
	binDir := t.TempDir()
	binName := "cad-plugin-test"
	if runtime.GOOS == "windows" {
		binName += ".exe"
	}
	binPath := filepath.Join(binDir, binName)
	buildCmd := exec.Command("go", "build", "-o", binPath, ".")
	buildCmd.Stdout = os.Stdout
	buildCmd.Stderr = os.Stderr
	if err := buildCmd.Run(); err != nil {
		t.Fatalf("go build: %v", err)
	}

	// Assert binary embedded the bundle (size sanity).
	info, err := os.Stat(binPath)
	if err != nil {
		t.Fatalf("stat built binary: %v", err)
	}
	if info.Size() < 100*1024*1024 {
		t.Fatalf("binary too small (%d bytes) — go:embed likely consumed an empty/missing bundle", info.Size())
	}
	t.Logf("built cad-plugin: %d MB", info.Size()/(1024*1024))

	// Spawn the binary with a scrubbed env. MINERVA_PLUGIN_DATA_DIR points
	// at a fresh temp dir so EnsureRuntime extracts fresh (cold cache).
	dataDir := t.TempDir()
	t.Logf("data dir: %s", dataDir)

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, binPath)
	// Strict env. No PYTHONHOME / VIRTUAL_ENV / CONDA_* — host python must
	// NOT contaminate this spawn. PATH limited to system bins.
	cmd.Env = []string{
		"MINERVA_PLUGIN_DATA_DIR=" + dataDir,
		"PATH=/usr/bin:/bin",
		"HOME=" + os.Getenv("HOME"),
		"USERPROFILE=" + os.Getenv("USERPROFILE"),
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	cmd.Stderr = os.Stderr // forward worker stderr for debugging on failure

	if err := cmd.Start(); err != nil {
		t.Fatalf("start cad-plugin: %v", err)
	}
	defer func() {
		_ = stdin.Close()
		_ = cmd.Wait()
	}()

	br := bufio.NewReader(stdout)
	encoder := json.NewEncoder(stdin)

	// Read one line, decode as JSON-RPC response.
	readResponse := func() (map[string]any, error) {
		line, err := br.ReadBytes('\n')
		if err != nil {
			return nil, fmt.Errorf("read line: %w", err)
		}
		var resp map[string]any
		if err := json.Unmarshal(line, &resp); err != nil {
			return nil, fmt.Errorf("decode line %q: %w", string(line), err)
		}
		return resp, nil
	}

	// 1) initialize
	if err := encoder.Encode(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "initialize",
		"params":  map[string]any{},
	}); err != nil {
		t.Fatalf("initialize encode: %v", err)
	}
	initResp, err := readResponse()
	if err != nil {
		t.Fatalf("initialize response: %v", err)
	}
	if initResp["error"] != nil {
		t.Fatalf("initialize error envelope: %v", initResp["error"])
	}

	// 2) notifications/initialized (no response)
	if err := encoder.Encode(map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/initialized",
	}); err != nil {
		t.Fatalf("notif encode: %v", err)
	}

	// 3) tools/call mcad_validate with `result = sphere(5)`
	// First call triggers cold-start: extract bundle (a few seconds), spawn
	// worker, build123d import, OCCT init (a few seconds). 90s budget.
	if err := encoder.Encode(map[string]any{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      "mcad_validate",
			"arguments": map[string]any{"source": "result = sphere(5)"},
		},
	}); err != nil {
		t.Fatalf("tools/call encode: %v", err)
	}

	// The plugin may emit host.notify messages before our response — read
	// until we see id=2.
	var validateResp map[string]any
	for {
		resp, err := readResponse()
		if err != nil {
			t.Fatalf("tools/call read: %v", err)
		}
		if id, ok := resp["id"]; ok {
			// JSON numbers decode to float64; id was 2.
			if f, isFloat := id.(float64); isFloat && f == 2 {
				validateResp = resp
				break
			}
		}
		// Notification or unrelated; log and keep reading.
		t.Logf("ignored intermediate: %v", resp)
	}

	if validateResp["error"] != nil {
		t.Fatalf("LAYER 2 FAIL: mcad_validate JSON-RPC error: %v", validateResp["error"])
	}

	// Unwrap MCP envelope: result.content[0].text → JSON-encoded {ok, result|error}.
	result, ok := validateResp["result"].(map[string]any)
	if !ok {
		t.Fatalf("missing result in %v", validateResp)
	}
	content, ok := result["content"].([]any)
	if !ok || len(content) == 0 {
		t.Fatalf("missing content in %v", result)
	}
	first, ok := content[0].(map[string]any)
	if !ok {
		t.Fatalf("content[0] not a map: %T", content[0])
	}
	textRaw, ok := first["text"].(string)
	if !ok {
		t.Fatalf("content[0].text not a string: %T", first["text"])
	}

	var envelope map[string]any
	if err := json.Unmarshal([]byte(textRaw), &envelope); err != nil {
		t.Fatalf("decode envelope %q: %v", textRaw, err)
	}

	if envelope["ok"] != true {
		t.Fatalf("LAYER 2 FAIL: mcad_validate ok != true; envelope=%v", envelope)
	}
	t.Logf("LAYER 2 PASS: mcad_validate result = %v", envelope)

	// 4) graceful shutdown
	_ = encoder.Encode(map[string]any{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "shutdown",
	})

	// Give the binary a moment to exit cleanly; drain any final output.
	_, _ = io.Copy(io.Discard, br)
}
