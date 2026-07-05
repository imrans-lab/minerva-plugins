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

// ---------------------------------------------------------------------------
// Tool registration
// ---------------------------------------------------------------------------

// TestInitRegistryRegistersWorkerTools asserts the worker round wired the four
// worker-backed pcb_* tools alongside the pre-existing in-process tools, under
// the exact names the manifest/broker and LLM expect.
func TestInitRegistryRegistersWorkerTools(t *testing.T) {
	initRegistry()
	got := map[string]bool{}
	for _, s := range registry.Specs() {
		got[s.Name] = true
	}
	want := []string{
		// in-process (unchanged from the scaffold)
		"ping", "pcb.serialize", "pcb.deserialize", "pcb.collect_export", "pcb.apply_export",
		// in-process — library-data fetch/status (this round)
		"pcb_fetch_libraries", "pcb_library_status",
		// worker-backed (prior round)
		"pcb_validate", "pcb_generate", "pcb_check_libraries", "pcb_check_bom",
	}
	for _, name := range want {
		if !got[name] {
			t.Errorf("tool %q not registered; registry has %v", name, got)
		}
	}
	if len(registry.Specs()) != len(want) {
		t.Errorf("registry tool count = %d, want %d", len(registry.Specs()), len(want))
	}
}

// TestWorkerBackedToolsHaveSchemas guards against a worker tool being registered
// with an empty input schema (which the MCP client would reject).
func TestWorkerBackedToolsHaveSchemas(t *testing.T) {
	initRegistry()
	for _, s := range registry.Specs() {
		if workerBackedTools[s.Name] {
			if len(s.InputSchema) == 0 || s.Description == "" {
				t.Errorf("worker tool %q missing schema/description", s.Name)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// End-to-end stdio smoke (spawns the real pcb-plugin binary + Python worker)
// ---------------------------------------------------------------------------

// TestPCBWorkerStdioSmoke builds pcb-plugin, spawns it, performs the MCP
// handshake, and calls pcb_validate on the canonical spike board through the
// real Python worker (python -m pcb_worker).
//
// Worker-venv bootstrapping (dev machines): the worker needs its deps (pyyaml,
// plus the pcb_worker package on sys.path) available to whatever `python3` the
// bridge resolves. This test SKIPS cleanly unless one of these is true:
//   - env PCB_WORKER_PYTHON_DIR names a directory containing a python3 that has
//     pcb_worker + pyyaml importable (it is prepended to PATH for the spawn); or
//   - python3 is already on PATH with those deps.
//
// To enable locally: create a venv OUTSIDE the repo, `pip install -e pcb/worker`
// into it, then run:
//
//	PCB_WORKER_PYTHON_DIR=/path/to/venv/Scripts go test ./... -run StdioSmoke
func TestPCBWorkerStdioSmoke(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test; -short")
	}

	// Compose the spawn PATH: prepend PCB_WORKER_PYTHON_DIR if provided.
	spawnPath := os.Getenv("PATH")
	if dir := os.Getenv("PCB_WORKER_PYTHON_DIR"); dir != "" {
		spawnPath = dir + string(os.PathListSeparator) + spawnPath
	}
	if !python3Available(spawnPath) {
		t.Skip("no python3 with pcb_worker deps found — set PCB_WORKER_PYTHON_DIR " +
			"to a venv/Scripts (or bin) dir whose python3 has `pip install -e pcb/worker`; see test doc")
	}

	// Build the plugin binary INTO the module root, so its derived plugin root
	// (dir of the executable) is this module dir where the real worker/ source
	// lives — dev mode chdirs the worker to <root>/worker. Cleaned up after.
	binName := "pcb-plugin-test"
	if runtime.GOOS == "windows" {
		binName += ".exe"
	}
	binPath, err := filepath.Abs(binName)
	if err != nil {
		t.Fatalf("abs bin path: %v", err)
	}
	defer os.Remove(binPath)
	build := exec.Command("go", "build", "-o", binPath, ".")
	build.Stdout, build.Stderr = os.Stdout, os.Stderr
	if err := build.Run(); err != nil {
		t.Fatalf("go build: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, binPath)
	env := os.Environ()
	// Replace PATH with the composed spawn PATH so the plugin's bridge resolves
	// the intended python3.
	for i, e := range env {
		if len(e) >= 5 && (e[:5] == "PATH=" || e[:5] == "Path=") {
			env[i] = "PATH=" + spawnPath
		}
	}
	cmd.Env = env

	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("start pcb-plugin: %v", err)
	}
	defer func() { _ = stdin.Close(); _ = cmd.Wait() }()

	br := bufio.NewReader(stdout)
	enc := json.NewEncoder(stdin)
	readResp := func() (map[string]any, error) {
		line, err := br.ReadBytes('\n')
		if err != nil {
			return nil, fmt.Errorf("read: %w", err)
		}
		var m map[string]any
		return m, json.Unmarshal(line, &m)
	}

	// initialize
	_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": map[string]any{}})
	if _, err := readResp(); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})

	// tools/call pcb_validate on the spike board.
	board, err := os.ReadFile(filepath.Join("spikes", "gerber", "board.yaml"))
	if err != nil {
		t.Fatalf("read spike board: %v", err)
	}
	_ = enc.Encode(map[string]any{
		"jsonrpc": "2.0", "id": 2, "method": "tools/call",
		"params": map[string]any{"name": "pcb_validate", "arguments": map[string]any{"yaml": string(board)}},
	})

	var vresp map[string]any
	for {
		resp, err := readResp()
		if err != nil {
			t.Fatalf("tools/call read: %v", err)
		}
		if f, ok := resp["id"].(float64); ok && f == 2 {
			vresp = resp
			break
		}
		t.Logf("ignored intermediate: %v", resp)
	}
	if vresp["error"] != nil {
		t.Fatalf("pcb_validate JSON-RPC error: %v", vresp["error"])
	}

	// Unwrap MCP envelope → {ok, result:{ok, errors, warnings}}.
	env2 := unwrapMCP(t, vresp)
	if env2["ok"] != true {
		t.Fatalf("pcb_validate outer ok != true: %v", env2)
	}
	inner, _ := env2["result"].(map[string]any)
	if inner["ok"] != true {
		t.Fatalf("spike board should validate clean; got: %v", inner)
	}
	t.Logf("STDIO SMOKE PASS: pcb_validate result = %v", inner)

	_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": 3, "method": "shutdown"})
	_, _ = io.Copy(io.Discard, br)
}

// python3Available reports whether a `python3` on the given PATH can import
// pcb_worker and yaml. It scans pathEnv in order (so a prepended venv wins,
// exactly as the bridge's own exec.LookPath("python3") resolves it) before
// falling back to the process PATH.
func python3Available(pathEnv string) bool {
	p := scanForPython3(pathEnv)
	if p == "" {
		var err error
		if p, err = exec.LookPath("python3"); err != nil {
			return false
		}
	}
	cmd := exec.Command(p, "-c", "import pcb_worker, yaml")
	cmd.Env = append(os.Environ(), "PATH="+pathEnv)
	cmd.Dir = "worker" // pcb_worker resolves from the worker/ dir in dev mode
	return cmd.Run() == nil
}

func scanForPython3(pathEnv string) string {
	name := "python3"
	if runtime.GOOS == "windows" {
		name = "python3.exe"
	}
	for _, dir := range filepath.SplitList(pathEnv) {
		if dir == "" {
			continue
		}
		cand := filepath.Join(dir, name)
		if info, err := os.Stat(cand); err == nil && !info.IsDir() {
			return cand
		}
	}
	return ""
}

func unwrapMCP(t *testing.T, resp map[string]any) map[string]any {
	t.Helper()
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
	return env
}
