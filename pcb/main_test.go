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
	"sort"
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
		// in-process — library-data fetch/status (this round). Only NAME
		// RESOLUTION is asserted for minerva_pcb_fetch_libraries here and in
		// TestManifestBrokerParity/TestManifestInputSchemaMatchesBroker below —
		// it performs a REAL network fetch with sha256 verification, so it is
		// deliberately never invoked (Dispatch'd) from go test (acceptance 4,
		// docket 019fa486b408 comment 832).
		"minerva_pcb_fetch_libraries", "minerva_pcb_library_status",
		// worker-backed (prior round)
		"minerva_pcb_validate", "minerva_pcb_generate", "minerva_pcb_check_libraries", "minerva_pcb_check_bom",
		// worker-backed — fabrication output (prior round)
		"minerva_pcb_gerbers",
		// worker-backed — connectivity/topology check (pad centers + trace
		// centerlines; NOT geometric — that is minerva_pcb_drc_geometric)
		"minerva_pcb_drc",
		// worker-backed — geometric copper DRC over the ResolvedBoard IR
		"minerva_pcb_drc_geometric",
		// worker-backed — footprint resolve: attach silk/courtyard graphics
		"minerva_pcb_resolve",
		// worker-backed — source normalize: fold inline geometry to typed
		// overrides (W8.4 / SB6; exposes the worker "normalize" method, follow-up
		// 019f8c0b7194).
		"minerva_pcb_normalize",
		// worker-backed — K20's library pin (DCR 019ffc52c358), forwarding to
		// the worker's "lock_libraries" method.
		"minerva_pcb_lock_libraries",
		// worker-backed — pre-assembly BOM+CPL package (D0-5, docket
		// 019fc2f8b903): exposes the worker's assembly_package method — both
		// CSVs from one compilation.
		"minerva_pcb_export_assembly",
		// worker-backed — the rendered-bless surface (S3/B2, docket
		// 019ff5687b99): the library TRUST BOUNDARY. Stage a .kicad_mod into
		// the WIP layer, render the fact table + SVG a human blesses it
		// against, record the verdict. These carry the full minerva_pcb_
		// prefix (LLM-facing tools, not dotted panel-IPC channels), so they
		// are also counted by TestManifestBrokerParity.
		"minerva_pcb_footprint_stage",
		"minerva_pcb_footprint_report",
		"minerva_pcb_footprint_bless",
		// worker-backed — on-demand acquisition of ONE official KiCad footprint
		// (S4/B3, docket 019ff5689732). Its first half is an in-process HTTPS
		// fetch (network code is Go-only in this plugin), but it ENDS in a
		// w.Call to the worker's footprint_acquire_store, which stages and
		// auto-blesses through the B2 machinery above. Like
		// minerva_pcb_fetch_libraries, only NAME RESOLUTION is asserted here —
		// invoking it would hit gitlab.com.
		"minerva_pcb_acquire_footprint",
		// worker-backed — promotion out of the WIP layer (LIB2 B7, docket
		// 019ff7c02fd6): a blessed staged part moves whole into the durable
		// user library layer, both roots host-forced (withPromoteRoots).
		"minerva_pcb_footprint_promote",
		// worker-backed — arbitrary-source import (LIB2 B4, docket
		// 019ff568b56b): a git rev, a URL, or a vendor-export zip on disk.
		// Like minerva_pcb_acquire_footprint its first half is in-process (a
		// fetch, a clone, or a zip read), and like it it ENDS in a w.Call —
		// here to footprint_import_store, which stages UNBLESSED. Only NAME
		// RESOLUTION is asserted here; invoking it would reach whatever
		// address the arguments named.
		"minerva_pcb_import_footprint",
		// worker-backed — dotted panel-IPC channel forwarding to the worker's
		// "route" method (this round; docket 019f3815e9f9). NOT renamed by
		// round D0-expose (019fa486b408) — dotted panel-IPC channels are a
		// separate namespace from the LLM-facing minerva_pcb_* tool names.
		"pcb.route",
		// worker-backed — native draft-check seam (T2.4, commit 7f5060b;
		// routing DCR 019f7095c395). Was missing from this assertion, leaving
		// the suite red; restored here (docket 019f7abf9c8e). Also NOT renamed
		// — dotted panel-IPC channel, same as pcb.route above.
		"pcb.draft_check",
		// worker-backed — on-demand assembly advisory seam (DCR 019fd5fd9084,
		// work items 019fd5fe1241/019fd5fe2724), forwarding to the worker's
		// "assembly_check" method. Dotted panel-IPC channel, same namespace
		// note as pcb.route/pcb.draft_check above.
		"pcb.assembly_check",
		// worker-backed — whole-board health (census + assembly) without a
		// routing run (Epoch UX2 station 9, docket 019fde571300), forwarding
		// to the worker's "board_health" method. Same channel idiom.
		"pcb.board_health",
		// worker-backed — the K13 promotion gate (Epoch UX3 station 11,
		// docket 019fdf91b3ac): connectivity + geometric DRC + assembly in
		// one fail-closed verdict, forwarding to the worker's
		// "promote_check" method. Same channel idiom.
		"pcb.promote_check",
		// worker-backed — the panel's solder-mask overlay (WYSIWYG goal
		// 019ff4a5a75a, gap G4), forwarding to the worker's "mask_view"
		// method: Projection.mask verbatim, the same openings GC8 checks
		// and the Gerber emitter flashes. Same channel idiom.
		"pcb.mask_view",
		// worker-backed — the compiled copper of every pour, forwarding to the
		// worker's "zone_fill" method: the regions a pour actually conducts as,
		// for the surface that answers what a plane already joins. Same channel
		// idiom.
		"pcb.zone_fill",
		// worker-backed — the EXACT fabrication preview (WYSIWYG goal
		// 019ff4a5a75a, gap G5; DCR 019ffc52b455; K27), forwarding to the
		// worker's "fab_preview" method: the production emission path, read
		// back by gerbonara rather than by the gerber_writer that produced
		// it, so the preview is an independent read of the shipped bytes.
		// Same channel idiom.
		"pcb.fab_preview",
		// worker-backed — ONE library footprint's lands and silk, forwarding
		// to the worker's "footprint_geometry" method: what add-by-library-ref
		// places, resolved through the same chain a compile uses. Same channel
		// idiom.
		"pcb.footprint_geometry",
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
// handshake, and calls minerva_pcb_validate on the canonical spike board through the
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

	// tools/call minerva_pcb_validate on the spike board.
	board, err := os.ReadFile(filepath.Join("spikes", "gerber", "board.yaml"))
	if err != nil {
		t.Fatalf("read spike board: %v", err)
	}
	_ = enc.Encode(map[string]any{
		"jsonrpc": "2.0", "id": 2, "method": "tools/call",
		"params": map[string]any{"name": "minerva_pcb_validate", "arguments": map[string]any{"yaml": string(board)}},
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
		t.Fatalf("minerva_pcb_validate JSON-RPC error: %v", vresp["error"])
	}

	// Unwrap MCP envelope → {ok, result:{ok, errors, warnings}}.
	env2 := unwrapMCP(t, vresp)
	if env2["ok"] != true {
		t.Fatalf("minerva_pcb_validate outer ok != true: %v", env2)
	}
	inner, _ := env2["result"].(map[string]any)
	if inner["ok"] != true {
		t.Fatalf("spike board should validate clean; got: %v", inner)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_validate result = %v", inner)

	// tools/call minerva_pcb_gerbers on the same spike board → expect fabrication files.
	_ = enc.Encode(map[string]any{
		"jsonrpc": "2.0", "id": 3, "method": "tools/call",
		"params": map[string]any{"name": "minerva_pcb_gerbers", "arguments": map[string]any{
			"yaml": string(board), "name": "board"}},
	})
	var gresp map[string]any
	for {
		resp, err := readResp()
		if err != nil {
			t.Fatalf("minerva_pcb_gerbers read: %v", err)
		}
		if f, ok := resp["id"].(float64); ok && f == 3 {
			gresp = resp
			break
		}
		t.Logf("ignored intermediate: %v", resp)
	}
	if gresp["error"] != nil {
		t.Fatalf("minerva_pcb_gerbers JSON-RPC error: %v", gresp["error"])
	}
	genv := unwrapMCP(t, gresp)
	if genv["ok"] != true {
		t.Fatalf("minerva_pcb_gerbers outer ok != true: %v", genv)
	}
	gres, _ := genv["result"].(map[string]any)
	gfiles, _ := gres["files"].(map[string]any)
	// Six Gerber layers + PTH + NPTH for the spike board (has one NPTH hole).
	for _, want := range []string{"board-F_Cu.gbr", "board-B_Cu.gbr", "board-F_Mask.gbr",
		"board-B_Mask.gbr", "board-F_SilkS.gbr", "board-Edge_Cuts.gbr",
		"board-PTH.drl", "board-NPTH.drl"} {
		if _, ok := gfiles[want]; !ok {
			t.Fatalf("minerva_pcb_gerbers missing %q; got keys %v", want, keysOf(gfiles))
		}
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_gerbers returned %d files", len(gfiles))

	// tools/call minerva_pcb_drc_geometric on the spike board → the geometric UNION must
	// arrive under result. REGRESSION GUARD: the worker method must wrap the union
	// as {ok:true, result:<union>}; a bare top-level union surfaces as result:null
	// over this bridge (in-process worker tests skip the bridge and could not see
	// it). Assert result is a non-null object carrying the union's scope + verdict.
	_ = enc.Encode(map[string]any{
		"jsonrpc": "2.0", "id": 5, "method": "tools/call",
		"params": map[string]any{"name": "minerva_pcb_drc_geometric", "arguments": map[string]any{
			"yaml": string(board)}},
	})
	var dgresp map[string]any
	for {
		resp, err := readResp()
		if err != nil {
			t.Fatalf("minerva_pcb_drc_geometric read: %v", err)
		}
		if f, ok := resp["id"].(float64); ok && f == 5 {
			dgresp = resp
			break
		}
		t.Logf("ignored intermediate: %v", resp)
	}
	if dgresp["error"] != nil {
		t.Fatalf("minerva_pcb_drc_geometric JSON-RPC error: %v", dgresp["error"])
	}
	dgenv := unwrapMCP(t, dgresp)
	if dgenv["ok"] != true {
		t.Fatalf("minerva_pcb_drc_geometric outer ok != true: %v", dgenv)
	}
	dgres, ok := dgenv["result"].(map[string]any)
	if !ok || dgres == nil {
		t.Fatalf("minerva_pcb_drc_geometric result must be the geometric union, got null/non-object: %v", dgenv["result"])
	}
	if dgres["scope"] != "geometric" || dgres["verdict"] == nil {
		t.Fatalf("minerva_pcb_drc_geometric result missing union fields (scope/verdict): %v", dgres)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_drc_geometric verdict = %v", dgres["verdict"])

	// tools/call pcb_route on the same spike board → ROUND E (019f783860c8).
	// Canonical routing now compiles the board and routes the ResolvedBoard IR, so
	// this crosses the bridge that the Round C envelope bug hid in: a route reply
	// must arrive either as a real proposal under result, or as a structured
	// fail-closed error — never as ok:true with a null result.
	_ = enc.Encode(map[string]any{
		"jsonrpc": "2.0", "id": 6, "method": "tools/call",
		"params": map[string]any{"name": "pcb.route", "arguments": map[string]any{
			"yaml": string(board)}},
	})
	var rresp map[string]any
	for {
		resp, err := readResp()
		if err != nil {
			t.Fatalf("pcb_route read: %v", err)
		}
		if f, ok := resp["id"].(float64); ok && f == 6 {
			rresp = resp
			break
		}
		t.Logf("ignored intermediate: %v", resp)
	}
	if rresp["error"] != nil {
		t.Fatalf("pcb_route JSON-RPC error: %v", rresp["error"])
	}
	renv := unwrapMCP(t, rresp)
	if renv["ok"] == true {
		rres, ok := renv["result"].(map[string]any)
		if !ok || rres == nil {
			t.Fatalf("pcb_route ok:true must carry a proposal object, got null/non-object: %v", renv["result"])
		}
		if _, ok := rres["routes"]; !ok {
			t.Fatalf("pcb_route result missing routes: %v", rres)
		}
		t.Logf("STDIO SMOKE PASS: pcb_route success = %v", rres["success"])
	} else {
		// Fail-closed is a legitimate outcome (the spike board may carry accepted
		// copper or geometry the grid cannot model) — but it must be ATTRIBUTED and
		// must propose nothing.
		rerr, ok := renv["error"].(map[string]any)
		if !ok || rerr["kind"] == nil || rerr["message"] == nil {
			t.Fatalf("pcb_route fail-closed reply must carry error.kind + message: %v", renv)
		}
		if _, has := renv["result"]; has {
			t.Fatalf("pcb_route must propose NOTHING when it fails closed: %v", renv)
		}
		t.Logf("STDIO SMOKE PASS: pcb_route failed closed, kind = %v", rerr["kind"])
	}

	_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": 4, "method": "shutdown"})
	_, _ = io.Copy(io.Discard, br)
}

// TestPCBWorkerStdioSmoke_RemainingTools closes the round D0-expose gap flagged
// by cold review: TestPCBWorkerStdioSmoke (above) only ever dispatched
// minerva_pcb_validate/gerbers/drc_geometric (+ pcb.route) over stdio — the
// other six worker-backed tools (generate, drc, resolve, check_libraries,
// check_bom, library_status) were only NAME-checked via registry.Specs(),
// which proves registration but not that the broker can actually dispatch and
// envelope-wrap a real call. This test calls each of the six over the real
// stdio transport, through the real Python worker, and asserts a shape
// appropriate to it — a rich, discriminating shape for generate/drc/resolve,
// and the documented DEGENERATE-but-envelope-correct shape for
// check_libraries/check_bom/library_status (no library data has been
// fetched — MINERVA_PLUGIN_DATA_DIR is pinned to a fresh empty temp dir so
// that degenerate shape is deterministic regardless of what a prior manual
// `minerva_pcb_fetch_libraries` run may have left on this machine's default
// plugin data dir).
//
// minerva_pcb_fetch_libraries remains the ONE tool this whole test file never
// dispatches: it performs a real network fetch with sha256 verification, so
// invoking it from `go test` would be neither cheap nor deterministic. Its
// name resolution alone is checked (TestInitRegistryRegistersWorkerTools,
// TestManifestBrokerParity) — same carve-out documented there.
func TestPCBWorkerStdioSmoke_RemainingTools(t *testing.T) {
	emptyDataDir := t.TempDir()
	c, cleanup := startPluginWithEnv(t, "pcb-plugin-remaining", []string{
		"MINERVA_PLUGIN_DATA_DIR=" + emptyDataDir,
	})
	defer cleanup()

	board, err := os.ReadFile(filepath.Join("spikes", "gerber", "board.yaml"))
	if err != nil {
		t.Fatalf("read spike board: %v", err)
	}
	yamlArgs := map[string]any{"yaml": string(board)}

	// --- minerva_pcb_generate: real KiCad file text, not merely a non-error. ---
	genEnv := c.call("minerva_pcb_generate", map[string]any{"yaml": string(board), "name": "board"})
	if genEnv["ok"] != true {
		t.Fatalf("minerva_pcb_generate outer ok != true: %v", genEnv)
	}
	genRes := asMap(t, genEnv["result"], "generate.result")
	genFiles := asMap(t, genRes["files"], "generate.files")
	for _, want := range []string{"board.kicad_pcb", "board.kicad_sch", "board.kicad_pro"} {
		if _, ok := genFiles[want]; !ok {
			t.Fatalf("minerva_pcb_generate missing %q; got keys %v", want, keysOf(genFiles))
		}
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_generate returned %d files", len(genFiles))

	// --- minerva_pcb_drc: connectivity/topology findings+counts shape. --------
	// DISCRIMINATING (cold-review adversary S4): findings[]/counts{} alone is a
	// shape minerva_pcb_drc_geometric ALSO satisfies, so a handler misbinding
	// (drc wired to HandleDRCGeometric) would slip past a check that only
	// looked for those two keys — the exact survivor the adversary found.
	// pcb_worker.drc._run_drc's return literal (methods.py/drc.py) carries
	// scope:"connectivity" and counts keyed by wrong_net_pad/crossing/
	// dangling_endpoint/layer_change_no_via, and NEVER a "verdict" key.
	// pcb_worker.drc_geometric's return literal carries scope:"geometric",
	// ALWAYS a "verdict" key, and counts keyed by gc1_trace_width/gc2_.../etc.
	// So scope=="connectivity" + a wrong_net_pad counts key + the absence of
	// "verdict" together pin this to the CONNECTIVITY checker specifically —
	// wiring minerva_pcb_drc to the geometric handler flips scope to
	// "geometric", drops wrong_net_pad from counts, and adds "verdict", so
	// every one of these three assertions would fail, not just one.
	drcEnv := c.call("minerva_pcb_drc", yamlArgs)
	if drcEnv["ok"] != true {
		t.Fatalf("minerva_pcb_drc outer ok != true: %v", drcEnv)
	}
	drcRes := asMap(t, drcEnv["result"], "drc.result")
	if _, ok := drcRes["findings"].([]any); !ok {
		t.Fatalf("minerva_pcb_drc result missing findings[] array: %v", drcRes)
	}
	counts, ok := drcRes["counts"].(map[string]any)
	if !ok {
		t.Fatalf("minerva_pcb_drc result missing counts{} object: %v", drcRes)
	}
	if drcRes["scope"] != "connectivity" {
		t.Fatalf("minerva_pcb_drc result scope != \"connectivity\" (got %v) — this is the geometric DRC's shape, not the connectivity checker's; check for a handler misbinding", drcRes["scope"])
	}
	if _, hasWrongNetPad := counts["wrong_net_pad"]; !hasWrongNetPad {
		t.Fatalf("minerva_pcb_drc counts missing the connectivity-only key \"wrong_net_pad\" (got %v) — this is the geometric DRC's counts shape (gc1_trace_width/gc2_.../etc), not the connectivity checker's", counts)
	}
	if _, hasVerdict := drcRes["verdict"]; hasVerdict {
		t.Fatalf("minerva_pcb_drc result carries a \"verdict\" key (%v) — only the geometric DRC's union ever carries verdict; the connectivity checker never does", drcRes["verdict"])
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_drc scope=%v findings=%v counts=%v", drcRes["scope"], drcRes["findings"], drcRes["counts"])

	// --- minerva_pcb_resolve: silk/courtyard graphics attached + stats. -------
	resolveEnv := c.call("minerva_pcb_resolve", yamlArgs)
	if resolveEnv["ok"] != true {
		t.Fatalf("minerva_pcb_resolve outer ok != true: %v", resolveEnv)
	}
	resolveRes := asMap(t, resolveEnv["result"], "resolve.result")
	if resolveRes["ok"] != true {
		t.Fatalf("minerva_pcb_resolve inner ok != true: %v", resolveRes)
	}
	_ = asMap(t, resolveRes["board"], "resolve.board")
	resolveStats := asMap(t, resolveRes["stats"], "resolve.stats")
	if _, ok := resolveStats["components"]; !ok {
		t.Fatalf("minerva_pcb_resolve stats missing components: %v", resolveStats)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_resolve stats=%v", resolveStats)

	// --- minerva_pcb_check_libraries: DEGENERATE (no lib_dir fetched) but the
	// documented degenerate shape, not merely non-error — checked:0,
	// missing:[], missing_data:true, hint naming the fetch tool by its real
	// (renamed) name. ---------------------------------------------------------
	clEnv := c.call("minerva_pcb_check_libraries", yamlArgs)
	if clEnv["ok"] != true {
		t.Fatalf("minerva_pcb_check_libraries outer ok != true: %v", clEnv)
	}
	clRes := asMap(t, clEnv["result"], "check_libraries.result")
	if clRes["ok"] != true {
		t.Fatalf("minerva_pcb_check_libraries inner ok != true: %v", clRes)
	}
	if clRes["missing_data"] != true {
		t.Fatalf("minerva_pcb_check_libraries missing_data != true (isolated empty data dir): %v", clRes)
	}
	if checked, _ := clRes["checked"].(float64); checked != 0 {
		t.Fatalf("minerva_pcb_check_libraries checked != 0: %v", clRes)
	}
	hint, _ := clRes["hint"].(string)
	if !strings.Contains(hint, "minerva_pcb_fetch_libraries") {
		t.Fatalf("minerva_pcb_check_libraries hint does not name minerva_pcb_fetch_libraries: %q", hint)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_check_libraries degenerate shape confirmed, hint=%q", hint)

	// --- minerva_pcb_check_bom: real items extracted even with no lib_dir; ----
	// missing_data still true (degenerate half), but part_count/items are the
	// rich half this tool always produces regardless of library data.
	cbEnv := c.call("minerva_pcb_check_bom", yamlArgs)
	if cbEnv["ok"] != true {
		t.Fatalf("minerva_pcb_check_bom outer ok != true: %v", cbEnv)
	}
	cbRes := asMap(t, cbEnv["result"], "check_bom.result")
	if cbRes["ok"] != true {
		t.Fatalf("minerva_pcb_check_bom inner ok != true: %v", cbRes)
	}
	if partCount, _ := cbRes["part_count"].(float64); partCount <= 0 {
		t.Fatalf("minerva_pcb_check_bom part_count <= 0 (spike board has components): %v", cbRes)
	}
	if cbRes["missing_data"] != true {
		t.Fatalf("minerva_pcb_check_bom missing_data != true (isolated empty data dir): %v", cbRes)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_check_bom part_count=%v", cbRes["part_count"])

	// --- minerva_pcb_library_status: DEGENERATE present:false, deterministic
	// because MINERVA_PLUGIN_DATA_DIR points at a fresh empty temp dir. --------
	lsEnv := c.call("minerva_pcb_library_status", map[string]any{})
	if lsEnv["ok"] != true {
		t.Fatalf("minerva_pcb_library_status outer ok != true: %v", lsEnv)
	}
	lsRes := asMap(t, lsEnv["result"], "library_status.result")
	if lsRes["present"] != false {
		t.Fatalf("minerva_pcb_library_status present != false (expected degenerate — isolated empty data dir): %v", lsRes)
	}
	if ev, _ := lsRes["entries_verified"].(float64); ev != 0 {
		t.Fatalf("minerva_pcb_library_status entries_verified != 0: %v", lsRes)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_library_status degenerate shape confirmed, result=%v", lsRes)
}

// TestPCBWorkerStdioSmoke_ErrorEnvelope closes cold-review adversary S5: no
// prior test ever dispatched a FAILING worker call over stdio, so a
// mutation that replaced the failure envelope with a bogus shape and flipped
// isError to false left the whole suite green. An agent hits this path more
// than any other under failure (malformed input, a board that won't parse),
// so it needs real coverage, not an inference from the success-path tests.
//
// Malformed YAML is not a contrived edge case here — see the durable hint
// minerva-plugins/pcb-bridge-wire-ok-is-worker-top-level-ok: minerva_pcb_generate
// (like drc/gerbers/drc_geometric/resolve/normalize/check_libraries/check_bom)
// propagates a BoardParseError as a TOP-LEVEL {"ok": False, "error": {"kind":
// "parse", ...}} dict, and that top-level "ok" IS the bridge wire-level
// Response.OK (shared/bridge/protocol.go) — a genuine bridge.WorkerError, not
// merely an app-level {ok:false} nested inside a successful dispatch. This
// exercises the SAME isError:true / asWorkerErr path main.go's handleToolsCall
// uses for a crashed worker, a timeout, or any other protocol-level fault.
//
// DELIBERATELY NOT minerva_pcb_validate: that tool catches BoardParseError
// itself and reports it as VALIDATION DATA — {"ok":true, "result":{"ok":false,
// "errors":[...]}} — by design ("the LLM inner loop wants it as {ok, errors}",
// methods.py's own comment on _validate). A malformed-yaml call to
// minerva_pcb_validate never sets isError at all, so it would not exercise
// this path — confirmed live before settling on minerva_pcb_generate instead.
func TestPCBWorkerStdioSmoke_ErrorEnvelope(t *testing.T) {
	c, cleanup := startPlugin(t, "pcb-plugin-error-envelope")
	defer cleanup()

	c.id++
	id := c.id
	_ = c.enc.Encode(map[string]any{
		"jsonrpc": "2.0", "id": id, "method": "tools/call",
		"params": map[string]any{"name": "minerva_pcb_generate", "arguments": map[string]any{
			"yaml": "][ this is not valid YAML or a valid board",
		}},
	})
	resp, err := c.readID(id)
	if err != nil {
		t.Fatalf("minerva_pcb_generate (malformed yaml) read: %v", err)
	}
	if resp["error"] != nil {
		t.Fatalf("minerva_pcb_generate (malformed yaml) unexpected JSON-RPC error (want a tool-result isError, not a protocol error): %v", resp["error"])
	}

	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("minerva_pcb_generate (malformed yaml) missing result: %v", resp)
	}
	if result["isError"] != true {
		t.Fatalf("minerva_pcb_generate (malformed yaml) result.isError != true: %v", result)
	}

	env := unwrapMCP(t, resp)
	if env["ok"] != false {
		t.Fatalf("minerva_pcb_generate (malformed yaml) envelope ok != false: %v", env)
	}
	errObj, ok := env["error"].(map[string]any)
	if !ok {
		t.Fatalf("minerva_pcb_generate (malformed yaml) envelope missing error{} object: %v", env)
	}
	if kind, _ := errObj["kind"].(string); kind == "" {
		t.Fatalf("minerva_pcb_generate (malformed yaml) error.kind is empty/absent: %v", errObj)
	}
	if msg, _ := errObj["message"].(string); msg == "" {
		t.Fatalf("minerva_pcb_generate (malformed yaml) error.message is empty/absent: %v", errObj)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_generate error envelope confirmed — isError=true, ok=false, error.kind=%v", errObj["kind"])
}

// TestPCBWorkerStdioSmoke_DeclaredSchemaArgsOnly closes cold-review adversary
// S1 (a declared input_schema property silently renamed on BOTH the Go spec
// and the manifest, e.g. yaml -> source_yaml — TestManifestInputSchemaMatchesBroker
// compares the two sides to EACH OTHER, so an internally-consistent lie about
// what the worker actually accepts passes it every time) and S3 (two tools'
// input_schemas swapped identically on both sides — same blind spot).
//
// This is a BEHAVIORAL test: for every agent-facing tool except
// minerva_pcb_fetch_libraries (real network fetch — see the existing
// carve-out; a schema mis-binding in this area has been observed to trigger a
// live 19-file fetch inside `go test`, which this test must never risk), it
// reads the tool's DECLARED schema (via the broker's registered ToolSpec —
// identical to the manifest's per TestManifestInputSchemaMatchesBroker) and
// builds the call's arguments using ONLY property names that schema actually
// declares. If the schema no longer declares the property this test knows how
// to fill (currently "yaml" and "name" — every one of these tools accepts
// board content via "yaml", and generate/gerbers additionally take "name"),
// the constructed call carries no board content at all, and the worker's
// _load() fails closed — a genuine dispatch failure, not a shape check.
//
// KNOWN LIMITATION (same spirit as the schema-equality vacuity note): this
// cannot distinguish two schemas that differ ONLY in an optional property this
// test doesn't populate either way (e.g. swapping minerva_pcb_check_bom's
// schema with minerva_pcb_normalize's — both declare "yaml", differing only
// in "lib_dir", which this test never supplies) — both sides would still
// dispatch successfully under either schema. It reliably catches a rename or
// swap that removes the "yaml" property this test relies on to carry any
// content at all, which is the S1/S3 scenario as specified.
//
// INNER ok MUST BE CHECKED TOO — a live run caught this: minerva_pcb_validate
// does NOT surface a missing/unparseable board as a bridge-level failure (see
// the durable hint minerva-plugins/pcb-bridge-wire-ok-is-worker-top-level-ok
// — _validate deliberately catches BoardParseError and reports it as
// {"ok":true, "result":{"ok":false, "errors":[...]}}, "validation data" by
// design). So calling minerva_pcb_validate with an EMPTY args map (which is
// exactly what happens when the "yaml" property has been renamed out from
// under this test) still comes back with the OUTER envelope's ok:true — the
// outer check alone would have silently passed a schema lie for this one
// tool. Whenever the result carries its own nested "ok" key, that must be
// true as well.
func TestPCBWorkerStdioSmoke_DeclaredSchemaArgsOnly(t *testing.T) {
	// The inner-ok check below makes this sweep sensitive to the ambient
	// plugin data dir: minerva_pcb_check_libraries reports ok:false when a
	// FETCHED library set exists that simply does not carry the spike board's
	// footprint names (R_0805/C_0805/TH_TestPoint) — a correct answer about
	// the board, not a schema lie. Pinning an empty data dir gives every
	// library-backed tool its documented "nothing fetched yet" degenerate
	// shape (ok:true, missing_data:true), so this sweep measures schema
	// binding only, identically on a dev machine and on a clean checkout.
	// The shipped seed layer lives under MINERVA_PCB_ROOT, not the data dir,
	// so minerva_pcb_footprint_report still resolves knownValues["ref"].
	c, cleanup := startPluginWithEnv(t, "pcb-plugin-schema-args", []string{
		"MINERVA_PLUGIN_DATA_DIR=" + t.TempDir(),
	})
	defer cleanup()

	board, err := os.ReadFile(filepath.Join("spikes", "gerber", "board.yaml"))
	if err != nil {
		t.Fatalf("read spike board: %v", err)
	}

	// Values this test knows how to supply, keyed by the EXACT declared
	// property name. Only properties present in a tool's OWN declared schema
	// are included in that tool's call — a renamed/removed "yaml" property
	// means no board content goes out at all.
	//
	// "ref" (LIB1 B2): a real SEED footprint ref, so the read-only bless
	// surface (minerva_pcb_footprint_report) dispatches meaningfully through
	// this sweep — it resolves R_0805 from the shipped layer and renders it.
	// NOTE "name" doubles as a legacy ref alias on the bless handlers
	// (params.get("ref") or params.get("name")); "ref" wins where both are
	// declared because the handlers read it first.
	knownValues := map[string]any{
		"yaml": string(board),
		"name": "board",
		"ref":  "R_0805",
	}

	specs := agentFacingBrokerSpecs(t)
	names := make([]string, 0, len(specs))
	for name := range specs {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		if name == "minerva_pcb_fetch_libraries" {
			// Real network fetch with sha256 verification — never invoke from
			// go test (same carve-out as every other test in this file).
			continue
		}
		if name == "minerva_pcb_acquire_footprint" {
			// Same network carve-out: this tool's FIRST act is an outbound
			// HTTPS fetch of the ref from gitlab.com. Its fetch layer is
			// exercised hermetically by internal/libraries/acquire_test.go
			// (httptest, redirect/oversize/markup refusals) and its worker
			// half by worker/tests/test_footprint_acquire.py.
			continue
		}
		if name == "minerva_pcb_import_footprint" {
			// Both carve-outs at once (LIB2 B4). It is a WRITE tool on the
			// bless surface — a "successful" sweep dispatch would stage into
			// the ambient plugin data dir's WIP layer — AND its first act
			// reaches whatever address the arguments name, which for this
			// sweep's known values is nothing at all: with no source_kind it
			// is a NAMED refusal every time, by design. Its read half is
			// exercised hermetically by internal/libraries/import_test.go
			// (httptest redirect/oversize/content-type battery, zip-slip,
			// local-repo git flow) and its worker half by
			// worker/tests/test_footprint_import.py.
			continue
		}
		if name == "minerva_pcb_footprint_stage" || name == "minerva_pcb_footprint_bless" ||
			name == "minerva_pcb_footprint_promote" {
			// WRITE tools on the bless surface (LIB1 B2 + LIB2 B7's promote).
			// Dispatching them with only this sweep's known values is a NAMED
			// refusal every time, by design: stage refuses without
			// kicad_mod_text + provenance fields, and bless/promote refuse a
			// ref nothing has staged (promote additionally only moves a
			// BLESSED one) —
			// and a "successful" sweep dispatch would MUTATE the ambient
			// plugin data dir's WIP layer, which a read-only smoke must not.
			// Same shape as the export_assembly carve-out above. Exercised
			// end-to-end (stage→report→bless→resolve, tiering, artifact
			// binding) by worker/tests/test_bless.py; the read half of the
			// surface stays IN this sweep via minerva_pcb_footprint_report
			// with knownValues["ref"].
			continue
		}
		if name == "minerva_pcb_export_assembly" {
			// This test's knownValues can only supply "yaml"/"name" — the spike
			// board (spikes/gerber/board.yaml) carries no "mpn" on any
			// component, and the default profile ("jlc") REQUIRES mpn for every
			// part (AssemblyIdentityError, by design — see D0-5, docket
			// 019fc2f8b903). Dispatching this tool with only yaml/name against
			// that board is a NAMED refusal every time, correctly — not a
			// dispatch failure this generic sweep should flag. Exercised
			// properly (happy path + both refusal shapes) by
			// TestPCBWorkerStdioSmoke_ExportAssembly instead.
			continue
		}
		spec := specs[name]
		var schema map[string]any
		if err := json.Unmarshal(spec.InputSchema, &schema); err != nil {
			t.Errorf("%s: declared input_schema is not valid JSON: %v", name, err)
			continue
		}
		props, _ := schema["properties"].(map[string]any)
		args := map[string]any{}
		for propName := range props {
			if v, ok := knownValues[propName]; ok {
				args[propName] = v
			}
		}

		env := c.call(name, args)
		if env["ok"] != true {
			t.Errorf("%s: dispatch using ONLY its declared-schema keys (%v) failed — "+
				"declared schema may not match what the worker actually consumes: %v",
				name, args, env)
			continue
		}
		// Some tools (minerva_pcb_validate) absorb a missing/unparseable board
		// into a nested {"ok":false,...} result rather than a bridge-level
		// failure — see the comment above this test. Whenever the result is a
		// map carrying its own "ok" key, it must be true too, or a renamed
		// property that this test failed to populate would pass unnoticed.
		if result, isMap := env["result"].(map[string]any); isMap {
			if innerOK, has := result["ok"]; has && innerOK != true {
				t.Errorf("%s: dispatch using ONLY its declared-schema keys (%v) reported inner ok=false — "+
					"declared schema may not match what the worker actually consumes: %v",
					name, args, result)
				continue
			}
		}
		t.Logf("STDIO SMOKE PASS: %s dispatched cleanly using only its declared schema keys %v", name, args)
	}
}

// ---------------------------------------------------------------------------
// minerva_pcb_export_assembly (D0-5, docket 019fc2f8b903)
// ---------------------------------------------------------------------------

// TestPCBWorkerStdioSmoke_ExportAssembly is the dispatch-level test for the
// new minerva_pcb_export_assembly tool: happy path (both CSVs written, row
// counts matching C8's own hand-derived seals — see
// worker/tests/test_assembly_outputs.py), identity-refusal passthrough
// (missing mpn, naming the component), and unknown-house refusal (naming the
// house id) — all through the REAL plugin binary + worker, over stdio,
// exactly like every other tool's coverage in this file.
//
// Uses the COMPILABLE assembly fixture (worker/tests/testdata/assembly_boards/
// assembly_resolved.yaml), NOT the shared spikes/gerber/board.yaml spike
// board — that board carries no "mpn" on any component and would refuse
// under every assembly-capable profile (see the carve-out comment in
// TestPCBWorkerStdioSmoke_DeclaredSchemaArgsOnly above).
//
// Both CSVs are now derived from ONE strict compilation of the board, the same
// compilation the gerbers come from, so the fixture has to be a board that
// compiles. Its uncompilable twin (assembly_fixture.yaml) is exercised below
// as the named-refusal subcase — it is a board a house could never build that
// the retired raw-dict path emitted clean CSVs for anyway.
func TestPCBWorkerStdioSmoke_ExportAssembly(t *testing.T) {
	c, cleanup := startPlugin(t, "pcb-plugin-export-assembly")
	defer cleanup()

	fixturePath := filepath.Join("worker", "tests", "testdata", "assembly_boards", "assembly_resolved.yaml")
	fixture, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatalf("read assembly fixture: %v", err)
	}
	uncompilablePath := filepath.Join("worker", "tests", "testdata", "assembly_boards", "assembly_fixture.yaml")
	uncompilable, err := os.ReadFile(uncompilablePath)
	if err != nil {
		t.Fatalf("read uncompilable assembly fixture: %v", err)
	}

	// --- happy path: both files written, row counts match C8's seals -------
	// (2 grouped BOM rows: the 0805 resistor group x2 refs + the diode; the
	// resistors group because the fixture authors `package` on BOTH of them,
	// so both print the same Footprint cell; 3 CPL rows: one per
	// POPULATED component — the fixture's fiducial and coupon text are board
	// furniture and contribute no row — hand-derived in
	// worker/tests/test_assembly_outputs.py).
	outDir := t.TempDir()
	env := c.call("minerva_pcb_export_assembly", map[string]any{
		"yaml": string(fixture), "name": "afix", "out_dir": outDir,
	})
	if env["ok"] != true {
		t.Fatalf("minerva_pcb_export_assembly (happy path) ok != true: %v", env)
	}
	res := asMap(t, env["result"], "export_assembly.result")
	if res["profile"] != "jlc" {
		t.Fatalf("minerva_pcb_export_assembly profile != \"jlc\" (default): %v", res["profile"])
	}
	bom := asMap(t, res["bom"], "export_assembly.bom")
	cpl := asMap(t, res["cpl"], "export_assembly.cpl")
	if bom["filename"] != "afix-bom-jlc.csv" {
		t.Fatalf("minerva_pcb_export_assembly bom.filename = %v, want afix-bom-jlc.csv", bom["filename"])
	}
	if cpl["filename"] != "afix-cpl-jlc.csv" {
		t.Fatalf("minerva_pcb_export_assembly cpl.filename = %v, want afix-cpl-jlc.csv", cpl["filename"])
	}
	if rows, _ := bom["rows"].(float64); rows != 2 {
		t.Fatalf("minerva_pcb_export_assembly bom.rows = %v, want 2 (R_0805 group + diode)", bom["rows"])
	}
	if rows, _ := cpl["rows"].(float64); rows != 3 {
		t.Fatalf("minerva_pcb_export_assembly cpl.rows = %v, want 3 (R1, R2, D1)", cpl["rows"])
	}

	// The tool's own row-count claim alone is exactly what a FULL mutation
	// ("returns success without writing") or a HALF mutation ("writes BOM not
	// CPL") would leave untouched — the real red-line proof reads the files
	// BACK OFF DISK independently, never trusting the reply's numbers alone.
	bomPath, _ := bom["path"].(string)
	cplPath, _ := cpl["path"].(string)
	if bomPath == "" || cplPath == "" {
		t.Fatalf("minerva_pcb_export_assembly missing written paths: bom=%v cpl=%v", bom, cpl)
	}
	bomBytes, err := os.ReadFile(bomPath)
	if err != nil {
		t.Fatalf("minerva_pcb_export_assembly bom file not written at %s: %v", bomPath, err)
	}
	cplBytes, err := os.ReadFile(cplPath)
	if err != nil {
		t.Fatalf("minerva_pcb_export_assembly cpl file not written at %s: %v", cplPath, err)
	}
	if !strings.Contains(string(bomBytes), "LCSC Part #") {
		t.Fatalf("minerva_pcb_export_assembly bom file missing JLC header: %q", string(bomBytes))
	}
	if !strings.Contains(string(cplBytes), "Rotation") {
		t.Fatalf("minerva_pcb_export_assembly cpl file missing JLC header: %q", string(cplBytes))
	}
	if got := onDiskDataRowCount(string(bomBytes)); got != 2 {
		t.Fatalf("minerva_pcb_export_assembly bom file on disk has %d data rows, want 2", got)
	}
	if got := onDiskDataRowCount(string(cplBytes)); got != 3 {
		t.Fatalf("minerva_pcb_export_assembly cpl file on disk has %d data rows, want 3", got)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_export_assembly happy path — bom=%v cpl=%v", bom, cpl)

	// --- identity refusal passthrough: missing mpn names the component -----
	// Mirrors worker/tests/test_methods.py::test_assembly_bom_missing_identity_is_named_refusal
	// exactly (same replace-first-occurrence mutation of the same fixture) —
	// removes ONLY R1's mpn — the one inside its structured assembly block, at
	// six-space indent; R2 authors its own as a pre-block top-level scalar at
	// four — so the message naming "R1" specifically is a real assertion, not a
	// coincidence of every component losing its mpn at once.
	noIdentity := mustMutateFixture(t, string(fixture), "      mpn: C25804\n", "")
	idEnv := c.call("minerva_pcb_export_assembly", map[string]any{"yaml": noIdentity})
	if idEnv["ok"] != false {
		t.Fatalf("minerva_pcb_export_assembly (missing mpn) ok != false: %v", idEnv)
	}
	idErr := asMap(t, idEnv["error"], "export_assembly identity-refusal error")
	if idErr["kind"] != "assembly" {
		t.Fatalf("minerva_pcb_export_assembly (missing mpn) error.kind = %v, want \"assembly\"", idErr["kind"])
	}
	idMsg, _ := idErr["message"].(string)
	if !strings.Contains(idMsg, "R1") || !strings.Contains(idMsg, "mpn") {
		t.Fatalf("minerva_pcb_export_assembly (missing mpn) message does not name the component/field verbatim: %q", idMsg)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_export_assembly identity refusal — %q", idMsg)

	// --- unknown-house refusal -----------------------------------------------
	houseEnv := c.call("minerva_pcb_export_assembly", map[string]any{
		"yaml": string(fixture), "profile": "acme",
	})
	if houseEnv["ok"] != false {
		t.Fatalf("minerva_pcb_export_assembly (unknown house) ok != false: %v", houseEnv)
	}
	houseErr := asMap(t, houseEnv["error"], "export_assembly unknown-house error")
	if houseErr["kind"] != "assembly" {
		t.Fatalf("minerva_pcb_export_assembly (unknown house) error.kind = %v, want \"assembly\"", houseErr["kind"])
	}
	houseMsg, _ := houseErr["message"].(string)
	if !strings.Contains(houseMsg, "acme") {
		t.Fatalf("minerva_pcb_export_assembly (unknown house) message does not name the house id verbatim: %q", houseMsg)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_export_assembly unknown-house refusal — %q", houseMsg)

	// --- UNCOMPILABLE BOARD: named refusal, zero artifacts ------------------
	//
	// The deliberate capability regression, at the tool boundary. This fixture
	// declares pins 0.05mm off their library pads, names a footprint no library
	// supplies, and omits two required via rules; the raw-dict emitter produced
	// a clean BOM and CPL for it anyway, which is the two-boards-in-one-order
	// defect the cutover closes. It must now refuse under its OWN kind, name
	// the pads and the footprint that blocked the compile, and leave nothing on
	// disk — never a traceback, never a partial CSV.
	//
	// This subcase also carries the HALF-WRITE property: a refusal is
	// all-or-nothing. HandleExportAssembly computes both CSVs before writing
	// either, so no out_dir file survives a refusal from either worker call.
	uncompilableDir := t.TempDir()
	uncEnv := c.call("minerva_pcb_export_assembly", map[string]any{
		"yaml": string(uncompilable), "name": "unc", "out_dir": uncompilableDir,
	})
	if uncEnv["ok"] != false {
		t.Fatalf("minerva_pcb_export_assembly (uncompilable board) ok != false: %v", uncEnv)
	}
	uncErr := asMap(t, uncEnv["error"], "export_assembly uncompilable-board error")
	if uncErr["kind"] != "assembly_not_compilable" {
		t.Fatalf("minerva_pcb_export_assembly (uncompilable board) error.kind = %v, want \"assembly_not_compilable\"", uncErr["kind"])
	}
	blocked, ok := uncErr["blocked_by"].([]any)
	if !ok || len(blocked) == 0 {
		t.Fatalf("minerva_pcb_export_assembly (uncompilable board) error carries no blocked_by list: %v", uncErr)
	}
	blockedIDs := make(map[string]bool, len(blocked))
	for _, b := range blocked {
		entry := asMap(t, b, "export_assembly blocked_by entry")
		if entry["code"] == "" {
			t.Fatalf("minerva_pcb_export_assembly blocked_by entry has no code: %v", entry)
		}
		if id, _ := entry["entity_id"].(string); id != "" {
			blockedIDs[id] = true
		}
	}
	for _, want := range []string{"R1.1", "R1.2", "R2.1", "R2.2", "D1"} {
		if !blockedIDs[want] {
			t.Fatalf("minerva_pcb_export_assembly (uncompilable board) blocked_by does not name %q: %v", want, blocked)
		}
	}
	entries, err := os.ReadDir(uncompilableDir)
	if err != nil {
		t.Fatalf("read uncompilableDir: %v", err)
	}
	if len(entries) != 0 {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Fatalf("minerva_pcb_export_assembly (uncompilable board) left stray file(s) on disk: %v — a refusal must leave zero artifacts", names)
	}
	t.Logf("STDIO SMOKE PASS: minerva_pcb_export_assembly refuses an uncompilable board by name, zero artifacts — %v", uncErr["message"])
}

// ---------------------------------------------------------------------------
// Fixture mutation: line-ending agnostic, and FAIL-CLOSED on a no-op
// ---------------------------------------------------------------------------

// replaceOnceLF applies ONE literal substitution to a committed fixture's
// text, after normalizing both the source and the pattern to LF, and returns
// an ERROR when the pattern matches nothing. A test that mutates a fixture is
// asserting something about the MUTATED board; a substitution that quietly
// matched nothing turns that assertion into an assertion about the ORIGINAL
// board, which is how a green-looking test proves the opposite of what it
// claims.
//
// WINDOWS CI BREAK THIS EXISTS FOR — run 30773825956, job "pcb test
// (windows-latest)", TestPCBWorkerStdioSmoke_ExportAssembly, 2026-08:
//
//	Linux/macOS/oracle green, Windows red. The identity-refusal subcase
//	expected ok:false and got ok:true with a REAL export attached
//	({bom:{filename:board-bom-jlc.csv rows:2}, cpl:{... rows:3}, profile:jlc}
//	— no "path" fields, because that subcase passes no out_dir, so the shape
//	was the tool's normal no-write shape, NOT a stale/misrouted reply). Cause:
//	the GitHub Windows runner checks out with git's Windows default
//	core.autocrlf, so assembly_fixture.yaml arrived CRLF. os.ReadFile is
//	byte-exact, so strings.Replace(..., "    mpn: C25804\n", "", 1) — an
//	LF-terminated pattern — matched nothing against "...C25804\r\n". The
//	"missing mpn" board therefore still carried all three mpns, the worker
//	correctly exported it, and the test read that correct success as a
//	regression. The worker was never wrong: verified live in the venv, the
//	genuinely-mutated board refuses ("component 'R1' is missing required
//	identity field(s) mpn"), so the Linux pass was earned, not accidental.
//	The pcb/.gitattributes added alongside this helper removes the CRLF at
//	its source; this helper is the fail-closed backstop for the general case
//	(fixture edited, pattern gone stale) on any platform.
//
// The Python side of the same fixture is immune by construction and needs no
// equivalent: worker/tests/test_assembly_outputs.py mutates the PARSED dict
// (del board["components"][0]["mpn"]), and pathlib.read_text() normalizes
// newlines anyway.
func replaceOnceLF(src, old, new string) (string, error) {
	lf := strings.ReplaceAll(src, "\r\n", "\n")
	oldLF := strings.ReplaceAll(old, "\r\n", "\n")
	if !strings.Contains(lf, oldLF) {
		return "", fmt.Errorf("fixture mutation matched nothing: pattern %q is not present "+
			"(fixture edited out from under the test, or a line-ending/whitespace mismatch) — "+
			"refusing to hand back an UNMUTATED fixture, which would silently assert against the wrong board", old)
	}
	return strings.Replace(lf, oldLF, new, 1), nil
}

// mustMutateFixture is replaceOnceLF with a no-op treated as a test failure.
func mustMutateFixture(t *testing.T, src, old, new string) string {
	t.Helper()
	out, err := replaceOnceLF(src, old, new)
	if err != nil {
		t.Fatalf("%v", err)
	}
	return out
}

// TestReplaceOnceLF pins the mechanism of the Windows break documented on
// replaceOnceLF, platform-independently: the same mutation must produce the
// same board from an LF and from a CRLF checkout of the fixture, and a
// pattern that matches nothing must be an ERROR rather than a pass-through of
// the original. Runs everywhere, needs no plugin binary or worker, and fails
// on the pre-fix code (plain strings.Replace) for the CRLF case.
func TestReplaceOnceLF(t *testing.T) {
	fixture, err := os.ReadFile(filepath.Join("worker", "tests", "testdata", "assembly_boards", "assembly_fixture.yaml"))
	if err != nil {
		t.Fatalf("read assembly fixture: %v", err)
	}
	lf := strings.ReplaceAll(string(fixture), "\r\n", "\n")
	crlf := strings.ReplaceAll(lf, "\n", "\r\n")

	// Sanity: the CRLF copy really is the byte-different thing a Windows
	// checkout produces — otherwise the case below is vacuous.
	if crlf == lf {
		t.Fatalf("CRLF copy is identical to the LF fixture — the case this test exists for cannot be exercised")
	}

	const pattern = "    mpn: C25804\n"

	fromLF, err := replaceOnceLF(lf, pattern, "")
	if err != nil {
		t.Fatalf("replaceOnceLF on LF fixture: %v", err)
	}
	fromCRLF, err := replaceOnceLF(crlf, pattern, "")
	if err != nil {
		t.Fatalf("replaceOnceLF on CRLF fixture (the Windows checkout shape): %v", err)
	}
	if fromLF != fromCRLF {
		t.Fatalf("CRLF checkout produced a DIFFERENT board than the LF checkout — mutation is not line-ending agnostic")
	}
	// The mutation must have actually removed an mpn, not merely returned
	// something: 3 mpn keys in, 2 out.
	if got, want := strings.Count(fromLF, "mpn:"), 2; got != want {
		t.Fatalf("mutated board has %d mpn keys, want %d — the substitution did not remove R1's mpn", got, want)
	}
	if fromLF == lf {
		t.Fatalf("mutated board is identical to the fixture — a no-op mutation was handed back as a success")
	}

	// A stale/absent pattern must be a refusal, never the original text.
	if _, err := replaceOnceLF(lf, "    mpn: NOT_IN_THIS_FIXTURE\n", ""); err == nil {
		t.Fatalf("replaceOnceLF returned no error for a pattern that matches nothing — a no-op mutation must fail closed")
	}
}

// onDiskDataRowCount is the test-side row counter, deliberately a SEPARATE
// implementation from internal/tools's (unexported, package-private) row
// counter — reading the produced files back independently, rather than
// reusing the tool's own counting code, is what makes the on-disk assertions
// above a real mutation guard instead of a tautology.
func onDiskDataRowCount(content string) int {
	lines := strings.Split(strings.TrimRight(content, "\r\n"), "\n")
	n := 0
	for _, l := range lines {
		if strings.TrimRight(l, "\r") != "" {
			n++
		}
	}
	if n == 0 {
		return 0
	}
	return n - 1
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
	return startPluginWithEnv(t, binName, nil)
}

// startPluginWithEnv is startPlugin plus extraEnv ("KEY=VALUE" entries)
// appended to the spawned process's environment (last-wins, so an entry here
// overrides one already in os.Environ()). Added so a caller can pin
// MINERVA_PLUGIN_DATA_DIR to an isolated, guaranteed-empty temp directory —
// needed by the minerva_pcb_check_libraries/check_bom/library_status
// dispatch checks below, whose "no data fetched yet" degenerate-shape
// assertions would otherwise be at the mercy of whatever a prior
// minerva_pcb_fetch_libraries run (from manual dev use, not from this test
// suite, which never invokes it) left on this machine's default plugin data
// dir.
func startPluginWithEnv(t *testing.T, binName string, extraEnv []string) (*pluginConn, func()) {
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
	env = append(env, extraEnv...)
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
// It drives deserialize (Go) → minerva_pcb_normalize (Python) → serialize/deserialize
// (Go) → minerva_pcb_gerbers (Python) through the REAL plugin binary + worker, proving
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

	// --- 2. minerva_pcb_normalize (Python): v2 board → override, inline gone. --------
	nEnv := c.call("minerva_pcb_normalize", map[string]any{"board": boardV2})
	if nEnv["ok"] != true {
		t.Fatalf("minerva_pcb_normalize outer ok != true: %v", nEnv)
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

	// --- 4. minerva_pcb_gerbers (Python) on normalized: authored deviation in bytes. -
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
	n2Env := c.call("minerva_pcb_normalize", map[string]any{"board": normBoard})
	n2Res := asMap(t, n2Env["result"], "normalize2.result")
	normBoard2 := asMap(t, n2Res["board"], "twice-normalized board")
	if !reflect.DeepEqual(normBoard2, normBoard) {
		t.Fatalf("normalize is NOT idempotent: second pass changed the board")
	}
	t.Logf("IDEMPOTENT: second minerva_pcb_normalize == first")

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

// gerberFiles calls minerva_pcb_gerbers on board (name "brd") and returns the files map.
func gerberFiles(t *testing.T, c *pluginConn, board map[string]any) map[string]any {
	t.Helper()
	env := c.call("minerva_pcb_gerbers", map[string]any{"board": board, "name": "brd"})
	if env["ok"] != true {
		t.Fatalf("minerva_pcb_gerbers outer ok != true: %v", env)
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
