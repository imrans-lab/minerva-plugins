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
	"reflect"
	"runtime"
	"strings"
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
		// worker-backed — fabrication output (prior round)
		"pcb_gerbers",
		// worker-backed — connectivity/topology check (pad centers + trace
		// centerlines; NOT geometric — that is pcb_drc_geometric)
		"pcb_drc",
		// worker-backed — geometric copper DRC over the ResolvedBoard IR
		"pcb_drc_geometric",
		// worker-backed — footprint resolve: attach silk/courtyard graphics
		"pcb_resolve",
		// worker-backed — source normalize: fold inline geometry to typed
		// overrides (W8.4 / SB6; exposes the worker "normalize" method, follow-up
		// 019f8c0b7194).
		"pcb_normalize",
		// worker-backed — dotted panel-IPC channel forwarding to the worker's
		// "route" method (this round; docket 019f3815e9f9)
		"pcb.route",
		// worker-backed — native draft-check seam (T2.4, commit 7f5060b;
		// routing DCR 019f7095c395). Was missing from this assertion, leaving
		// the suite red; restored here (docket 019f7abf9c8e).
		"pcb.draft_check",
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

	// tools/call pcb_gerbers on the same spike board → expect fabrication files.
	_ = enc.Encode(map[string]any{
		"jsonrpc": "2.0", "id": 3, "method": "tools/call",
		"params": map[string]any{"name": "pcb_gerbers", "arguments": map[string]any{
			"yaml": string(board), "name": "board"}},
	})
	var gresp map[string]any
	for {
		resp, err := readResp()
		if err != nil {
			t.Fatalf("pcb_gerbers read: %v", err)
		}
		if f, ok := resp["id"].(float64); ok && f == 3 {
			gresp = resp
			break
		}
		t.Logf("ignored intermediate: %v", resp)
	}
	if gresp["error"] != nil {
		t.Fatalf("pcb_gerbers JSON-RPC error: %v", gresp["error"])
	}
	genv := unwrapMCP(t, gresp)
	if genv["ok"] != true {
		t.Fatalf("pcb_gerbers outer ok != true: %v", genv)
	}
	gres, _ := genv["result"].(map[string]any)
	gfiles, _ := gres["files"].(map[string]any)
	// Six Gerber layers + PTH + NPTH for the spike board (has one NPTH hole).
	for _, want := range []string{"board-F_Cu.gbr", "board-B_Cu.gbr", "board-F_Mask.gbr",
		"board-B_Mask.gbr", "board-F_SilkS.gbr", "board-Edge_Cuts.gbr",
		"board-PTH.drl", "board-NPTH.drl"} {
		if _, ok := gfiles[want]; !ok {
			t.Fatalf("pcb_gerbers missing %q; got keys %v", want, keysOf(gfiles))
		}
	}
	t.Logf("STDIO SMOKE PASS: pcb_gerbers returned %d files", len(gfiles))

	_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": 4, "method": "shutdown"})
	_, _ = io.Copy(io.Discard, br)
}

// ---------------------------------------------------------------------------
// Cross-language e2e round-trip capstone (W8.4 / SB6)
// ---------------------------------------------------------------------------

// pluginConn wraps a spawned pcb-plugin binary + its framed-stdio MCP session,
// exposing a single call() that drives tools/call and unwraps the MCP envelope.
type pluginConn struct {
	t   *testing.T
	enc *json.Encoder
	br  *bufio.Reader
	id  int
}

// startPlugin builds pcb-plugin into the module root (so its derived plugin root
// finds the real worker/ dir), spawns it with the python3-capable PATH, and
// completes the initialize + notifications/initialized handshake. It SKIPS the
// test (via the same guard as TestPCBWorkerStdioSmoke) when no python3 with the
// worker deps is available. Returns the connection and a cleanup func.
func startPlugin(t *testing.T, binName string) (*pluginConn, func()) {
	t.Helper()
	if testing.Short() {
		t.Skip("integration test; -short")
	}
	spawnPath := os.Getenv("PATH")
	if dir := os.Getenv("PCB_WORKER_PYTHON_DIR"); dir != "" {
		spawnPath = dir + string(os.PathListSeparator) + spawnPath
	}
	if !python3Available(spawnPath) {
		t.Skip("no python3 with pcb_worker deps found — set PCB_WORKER_PYTHON_DIR " +
			"to a venv/Scripts (or bin) dir whose python3 has `pip install -e pcb/worker`; see test doc")
	}

	if runtime.GOOS == "windows" {
		binName += ".exe"
	}
	binPath, err := filepath.Abs(binName)
	if err != nil {
		t.Fatalf("abs bin path: %v", err)
	}
	build := exec.Command("go", "build", "-o", binPath, ".")
	build.Stdout, build.Stderr = os.Stdout, os.Stderr
	if err := build.Run(); err != nil {
		t.Fatalf("go build: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	cmd := exec.CommandContext(ctx, binPath)
	env := os.Environ()
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

	c := &pluginConn{t: t, enc: json.NewEncoder(stdin), br: bufio.NewReader(stdout)}

	// initialize + notifications/initialized handshake.
	_ = c.enc.Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": map[string]any{}})
	c.id = 1
	if _, err := c.readID(1); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	_ = c.enc.Encode(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})

	cleanup := func() {
		_ = c.enc.Encode(map[string]any{"jsonrpc": "2.0", "id": 999, "method": "shutdown"})
		_, _ = io.Copy(io.Discard, c.br)
		_ = stdin.Close()
		cancel()
		_ = cmd.Wait()
		_ = os.Remove(binPath)
	}
	return c, cleanup
}

// readID reads framed responses until one with a matching numeric id arrives,
// skipping intermediate host.notify frames (which carry no id).
func (c *pluginConn) readID(want int) (map[string]any, error) {
	for {
		line, err := c.br.ReadBytes('\n')
		if err != nil {
			return nil, fmt.Errorf("read: %w", err)
		}
		var m map[string]any
		if err := json.Unmarshal(line, &m); err != nil {
			return nil, fmt.Errorf("decode %q: %w", line, err)
		}
		if f, ok := m["id"].(float64); ok && int(f) == want {
			return m, nil
		}
		c.t.Logf("ignored intermediate frame: %v", m)
	}
}

// call drives tools/call for name/arguments and returns the unwrapped MCP
// envelope {ok, result:...}. Fails the test on a JSON-RPC error.
func (c *pluginConn) call(name string, args map[string]any) map[string]any {
	c.t.Helper()
	c.id++
	id := c.id
	_ = c.enc.Encode(map[string]any{
		"jsonrpc": "2.0", "id": id, "method": "tools/call",
		"params": map[string]any{"name": name, "arguments": args},
	})
	resp, err := c.readID(id)
	if err != nil {
		c.t.Fatalf("%s read: %v", name, err)
	}
	if resp["error"] != nil {
		c.t.Fatalf("%s JSON-RPC error: %v", name, resp["error"])
	}
	return unwrapMCP(c.t, resp)
}

// e2eV1Board is a minimal v1 canonical board: one component on the real seed
// footprint Espressif:ESP32-S3-DevKitC (so it resolves + compiles), whose pin
// "1" carries a DIVERGENT inline drill_mm (1.0) — the footprint's own pad "1"
// drill is 0.8. That authored deviation is what the whole round-trip tracks.
const e2eV1Board = `
version: 1
name: e2e_capstone
width_mm: 20
height_mm: 20
grid_mm: 1.0
layers: [top, bottom]
origin: {x_mm: 0, y_mm: 0}
design_rules: {clearance_mm: 0.2, trace_width_mm: 0.25, via_diameter_mm: 0.8, via_drill_mm: 0.4}
components:
  - ref: U1
    footprint: Espressif:ESP32-S3-DevKitC
    x_mm: 10
    y_mm: 10
    rotation_deg: 0
    layer: top
    pins:
      - {number: "1", x_mm: 0, y_mm: 0, drill_mm: 1.0}
`

// TestPCBNormalizeCrossLanguageRoundTrip is the W8.4 (=SB6) e2e parity capstone.
// It drives deserialize (Go) → pcb_normalize (Python) → serialize/deserialize
// (Go) → pcb_gerbers (Python) through the REAL plugin binary + worker, proving
// an authored fabrication deviation survives the cross-language round-trip as a
// typed override, reaches the Gerber/Excellon bytes, is idempotent under a
// second normalize, and preserves fab semantics vs the un-migrated original.
func TestPCBNormalizeCrossLanguageRoundTrip(t *testing.T) {
	c, cleanup := startPlugin(t, "pcb-plugin-e2e")
	defer cleanup()

	// --- 1. pcb.deserialize (Go): v1 board → v2 (minted ids, version 2). -----
	dEnv := c.call("pcb.deserialize", map[string]any{"yaml": e2eV1Board})
	if dEnv["ok"] != true {
		t.Fatalf("deserialize outer ok != true: %v", dEnv)
	}
	dRes := asMap(t, dEnv["result"], "deserialize.result")
	boardV2 := asMap(t, dRes["board"], "deserialize board")
	if v, _ := boardV2["version"].(float64); v != 2 {
		t.Fatalf("deserialized board version = %v, want 2", boardV2["version"])
	}
	if id, _ := boardV2["id"].(string); id == "" {
		t.Fatalf("deserialized v2 board has no minted id: %v", boardV2)
	}
	// Pre-normalize the pin still carries loose inline drill_mm (Go migration
	// mints ids but does NOT fold inline geometry).
	origPin := firstPin(t, boardV2)
	if origPin["drill_mm"] == nil {
		t.Fatalf("expected inline drill_mm on the un-normalized v2 pin; got %v", origPin)
	}

	// --- 2. pcb_normalize (Python): v2 board → override, inline gone. --------
	nEnv := c.call("pcb_normalize", map[string]any{"board": boardV2})
	if nEnv["ok"] != true {
		t.Fatalf("pcb_normalize outer ok != true: %v", nEnv)
	}
	nRes := asMap(t, nEnv["result"], "normalize.result")
	if nRes["ok"] != true {
		t.Fatalf("normalize inner ok != true: %v", nRes)
	}
	normBoard := asMap(t, nRes["board"], "normalized board")
	normPin := firstPin(t, normBoard)
	ov := asMap(t, normPin["override"], "normalized pin override")
	if got, _ := ov["drill_mm"].(float64); got != 1.0 {
		t.Fatalf("override drill_mm = %v, want the AUTHORED 1.0", ov["drill_mm"])
	}
	if normPin["drill_mm"] != nil || normPin["annulus_diameter_mm"] != nil {
		t.Fatalf("loose inline fab keys survived normalize: %v", normPin)
	}

	// --- 3. serialize (Go) → v2 YAML → deserialize (Go): override survives. --
	sEnv := c.call("pcb.serialize", map[string]any{"board": normBoard})
	sRes := asMap(t, sEnv["result"], "serialize.result")
	yml, _ := sRes["yaml"].(string)
	if yml == "" {
		t.Fatalf("serialize returned no yaml: %v", sRes)
	}
	d2Env := c.call("pcb.deserialize", map[string]any{"yaml": yml})
	d2Res := asMap(t, d2Env["result"], "deserialize2.result")
	rtPin := firstPin(t, asMap(t, d2Res["board"], "round-trip board"))
	rtOv := asMap(t, rtPin["override"], "round-trip pin override")
	if got, _ := rtOv["drill_mm"].(float64); got != 1.0 {
		t.Fatalf("override drill_mm did NOT survive the Go YAML round-trip: got %v", rtPin)
	}
	t.Logf("CROSS-LANG DURABILITY: override drill_mm=1.0 survived serialize→deserialize")

	// --- 4. pcb_gerbers (Python) on normalized: authored deviation in bytes. -
	gNormFiles := gerberFiles(t, c, normBoard)
	pth, _ := gNormFiles["brd-PTH.drl"].(string)
	if pth == "" {
		t.Fatalf("normalized gerbers missing brd-PTH.drl; keys %v", keysOf(gNormFiles))
	}
	// The authored 1.0mm drill emits a C1.000 Excellon tool; the footprint
	// default (0.8) would NOT — this proves the deviation reaches fab bytes.
	if !strings.Contains(pth, "C1.000") {
		t.Fatalf("normalized PTH lacks the authored 1.0mm drill tool (C1.000):\n%s", pth)
	}
	t.Logf("FAB-BYTES: authored 1.0mm drill (C1.000) present in normalized Excellon")

	// --- 5. Idempotence: a second normalize is a no-op. ----------------------
	n2Env := c.call("pcb_normalize", map[string]any{"board": normBoard})
	n2Res := asMap(t, n2Env["result"], "normalize2.result")
	normBoard2 := asMap(t, n2Res["board"], "twice-normalized board")
	if !reflect.DeepEqual(normBoard2, normBoard) {
		t.Fatalf("normalize is NOT idempotent: second pass changed the board")
	}
	t.Logf("IDEMPOTENT: second pcb_normalize == first")

	// --- 6. Fab parity: gerbers(normalized) == gerbers(original v2 inline). ---
	gOrigFiles := gerberFiles(t, c, boardV2)
	if !reflect.DeepEqual(gOrigFiles, gNormFiles) {
		diffs := []string{}
		for k, v := range gOrigFiles {
			if !reflect.DeepEqual(v, gNormFiles[k]) {
				diffs = append(diffs, k)
			}
		}
		t.Fatalf("fab parity broken — normalize changed fab output; differing files: %v", diffs)
	}
	t.Logf("FAB PARITY: gerbers(normalized) byte-equal to gerbers(original inline v2)")
}

// gerberFiles calls pcb_gerbers on board (name "brd") and returns the files map.
func gerberFiles(t *testing.T, c *pluginConn, board map[string]any) map[string]any {
	t.Helper()
	env := c.call("pcb_gerbers", map[string]any{"board": board, "name": "brd"})
	if env["ok"] != true {
		t.Fatalf("pcb_gerbers outer ok != true: %v", env)
	}
	res := asMap(t, env["result"], "gerbers.result")
	return asMap(t, res["files"], "gerbers files")
}

// firstPin returns component[0].pins[0] as a map.
func firstPin(t *testing.T, board map[string]any) map[string]any {
	t.Helper()
	comps, ok := board["components"].([]any)
	if !ok || len(comps) == 0 {
		t.Fatalf("board has no components: %v", board)
	}
	comp := asMap(t, comps[0], "component[0]")
	pins, ok := comp["pins"].([]any)
	if !ok || len(pins) == 0 {
		t.Fatalf("component has no pins: %v", comp)
	}
	return asMap(t, pins[0], "pin[0]")
}

// asMap asserts v is a JSON object.
func asMap(t *testing.T, v any, what string) map[string]any {
	t.Helper()
	m, ok := v.(map[string]any)
	if !ok {
		t.Fatalf("%s is not an object: %v", what, v)
	}
	return m
}

func keysOf(m map[string]any) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	return ks
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
