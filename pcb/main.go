// Command pcb-plugin is the PCB Editor plugin MCP server for Minerva.
//
// Protocol: JSON-RPC 2.0 over stdin/stdout, one message per line — the same
// transport Minerva uses for every stdio MCP plugin (see cad/main.go for the
// worker-backed sibling). The inner protocol (Go ↔ Python worker) uses
// length-prefixed framing via the shared bridge and is separate.
//
// This build implements:
//   - initialize handshake
//   - tools/list → [ping, pcb.*, minerva_pcb_validate, minerva_pcb_generate,
//     minerva_pcb_check_libraries, minerva_pcb_check_bom, ...]
//   - tools/call → in-process tools answered directly; minerva_pcb_* worker
//     tools lazily spawn the Python worker (python -m pcb_worker) via the
//     shared bridge (circuit breaker + graceful shutdown come free).
//   - notifications/initialized + any other notification → ignored gracefully
//   - shutdown → graceful worker shutdown, then exit 0
//
// All logging goes to stderr; stdout carries only JSON-RPC responses.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/imrans-lab/minerva-plugins/pcb/internal/pcbruntime"
	"github.com/imrans-lab/minerva-plugins/pcb/internal/tools"
	"github.com/imrans-lab/minerva-plugins/shared/bridge"
	sharedruntime "github.com/imrans-lab/minerva-plugins/shared/runtime"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "pcb"
	// MUST bump in lockstep with manifest.json's version: this is the
	// PluginVersion sharedruntime.PythonPath uses as the extracted-runtime
	// CACHE KEY, so a manifest-only bump would ship a new bundle that
	// cache-hits the old extracted runtime. Pinned by
	// TestServerVersionMatchesManifest.
	serverVersion = "0.4.1"

	// workerModule is the python module the worker runs as (python -m <module>).
	workerModule = "pcb_worker"

	// workerShutdownTimeout is the graceful window on plugin shutdown before
	// SIGTERM (mirrors CAD).
	workerShutdownTimeout = 2 * time.Second
)

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 envelope types
// ---------------------------------------------------------------------------

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"` // null/absent for notifications
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func okResponse(id json.RawMessage, result interface{}) rpcResponse {
	return rpcResponse{JSONRPC: "2.0", ID: id, Result: result}
}

func errResponse(id json.RawMessage, code int, msg string) rpcResponse {
	return rpcResponse{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: code, Message: msg}}
}

// stdoutMu serialises every write to stdout (the JSON-RPC response path and the
// host.notify path both target os.Stdout).
var stdoutMu sync.Mutex

func send(enc *json.Encoder, v interface{}) {
	stdoutMu.Lock()
	defer stdoutMu.Unlock()
	if err := enc.Encode(v); err != nil {
		log.Printf("pcb-plugin: write response: %v", err)
	}
}

// ---------------------------------------------------------------------------
// host.notify — Minerva toast pipe (mirrors CAD)
// ---------------------------------------------------------------------------

type notifyParams struct {
	Level   string      `json:"level"`
	Message string      `json:"message"`
	Details interface{} `json:"details,omitempty"`
}

type hostNotify struct {
	JSONRPC string       `json:"jsonrpc"`
	Method  string       `json:"method"`
	Params  notifyParams `json:"params"`
}

var (
	notifyOut = io.Writer(os.Stdout)
	notifyEnc *json.Encoder
)

func emitHostNotify(level, message string, details interface{}) {
	if message == "" {
		return
	}
	stdoutMu.Lock()
	defer stdoutMu.Unlock()
	if notifyEnc == nil {
		notifyEnc = json.NewEncoder(notifyOut)
	}
	n := hostNotify{
		JSONRPC: "2.0",
		Method:  "host.notify",
		Params:  notifyParams{Level: level, Message: message, Details: details},
	}
	if err := notifyEnc.Encode(n); err != nil {
		log.Printf("pcb-plugin: emitHostNotify: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Worker + tool registry
// ---------------------------------------------------------------------------

var (
	worker   *bridge.Worker
	registry *tools.Registry
)

// pluginRoot is resolved once in main() and reused by initWorker (Python
// interpreter / worker dir resolution) and initRegistry (libraries.lock.json
// location for the minerva_pcb_fetch_libraries / minerva_pcb_library_status
// tools).
var pluginRoot string

// initWorker resolves the Python interpreter and constructs the Worker. The
// worker is NOT spawned here — spawning is lazy (first minerva_pcb_* tool
// call). Binary tier (epoch GA-4): the embedded PBS bundle is tier 1; in a
// dev tree the embed is a zero-byte placeholder (see internal/pcbruntime),
// which PythonPath treats as not-bundled and falls through to the dev tiers:
// <worker>/.venv, then python3 on PATH.
func initWorker() {
	workerDir := sharedruntime.WorkerScriptDir(pluginRoot)

	pythonPath, err := sharedruntime.PythonPath(sharedruntime.PythonPathRequest{
		EmbeddedBundle: pcbruntime.EmbeddedBundle,
		EmbeddedSHA256: pcbruntime.EmbeddedSHA256,
		WorkerDir:      workerDir,
		PluginID:       serverName,
		PluginVersion:  serverVersion,
	})
	if err != nil {
		log.Printf("pcb-plugin: WARNING: %v — minerva_pcb_* worker tools will fail until a .venv exists or python3 is on PATH", err)
		emitHostNotify("error",
			"PCB plugin: Python interpreter not found — minerva_pcb_validate/generate/check_* will fail",
			map[string]string{"detail": err.Error(), "fix": "Create a .venv in the plugin worker/ dir (pip install -e .) or put python3 on PATH"})
		pythonPath = ""
	}
	log.Printf("pcb-plugin: worker dir=%s, python=%s", workerDir, pythonPath)

	w := bridge.New(pythonPath, workerDir, workerModule)
	// Marketplace installs run the worker from inside the extracted bundle's
	// site-packages, where pcb_worker's source-tree-relative data lookups
	// (library/footprints, library/profiles — footprints.DEFAULT_LIBRARY_ROOT
	// et al.) would resolve into the bundle instead of the plugin dir the
	// tarball actually ships library/ in. The Go side is the one place that
	// KNOWS the plugin root, so it states it; the worker's path constants
	// honor this env override before falling back to the source-tree layout.
	w.ExtraEnv = []string{"MINERVA_PCB_ROOT=" + pluginRoot}
	w.StderrCallback = func(line string) {
		if isCriticalStderrLine(line) {
			emitHostNotify("error", "PCB worker: "+line, nil)
		}
	}
	worker = w
}

// pluginRootDir returns the directory of the running executable (the plugin
// root — contains manifest.json and worker/).
func pluginRootDir() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("os.Executable: %w", err)
	}
	return filepath.Dir(filepath.Clean(exe)), nil
}

// initRegistry registers all MCP tools. Called once at startup.
func initRegistry() {
	tools.SetVersion(serverVersion)
	tools.SetPluginRoot(pluginRoot)
	tools.SetNotifier(emitHostNotify)
	registry = tools.NewRegistry()

	// In-process tools (no worker) — adapted to the worker-threaded signature.
	registry.Register(tools.Ping, tools.WrapInProcess(tools.HandlePing))
	// Project channels declared in manifest ui.ipc_channels/ipc_messages. Every
	// declared channel MUST have a same-named backend tool or the broker returns
	// permission_denied (gap register A-7).
	registry.Register(tools.Serialize, tools.WrapInProcess(tools.HandleSerialize))
	// pcb.deserialize is the BOARD-LOAD path, so it registers the worker-aware
	// HandleDeserializeResolved: the same in-process codec plus a best-effort
	// footprint-graphics attach, so components arrive carrying the silk/courtyard
	// outlines the panel renderer already knows how to draw (unit 019fb430750a).
	// The enrichment degrades to the plain codec on any worker fault, so this
	// path keeps working exactly as before when the worker is unavailable.
	registry.Register(tools.Deserialize, tools.HandleDeserializeResolved)
	registry.Register(tools.CollectExport, tools.WrapInProcess(tools.HandleCollectExport))
	registry.Register(tools.ApplyExport, tools.WrapInProcess(tools.HandleApplyExport))
	// Library-data fetch/status — in-process (no Python worker involved), the
	// Go-side network fetcher (pcb/internal/libraries/). See docs/libraries.md.
	registry.Register(tools.FetchLibraries, tools.WrapInProcess(tools.HandleFetchLibraries))
	registry.Register(tools.LibraryStatus, tools.WrapInProcess(tools.HandleLibraryStatus))

	// Worker-backed tools — lazily spawn python -m pcb_worker via the bridge.
	registry.Register(tools.Validate, tools.HandleValidate)
	registry.Register(tools.Generate, tools.HandleGenerate)
	registry.Register(tools.Gerbers, tools.HandleGerbers)
	registry.Register(tools.DRC, tools.HandleDRC)
	registry.Register(tools.DRCGeometric, tools.HandleDRCGeometric)
	registry.Register(tools.Resolve, tools.HandleResolve)
	registry.Register(tools.Normalize, tools.HandleNormalize)
	registry.Register(tools.LockLibraries, tools.HandleLockLibraries)
	registry.Register(tools.CheckLibraries, tools.HandleCheckLibraries)
	registry.Register(tools.CheckBOM, tools.HandleCheckBOM)
	// minerva_pcb_export_assembly — pre-assembly BOM+CPL package (D0-5, docket
	// 019fc2f8b903). Two worker calls (assembly_bom then assembly_cpl) behind
	// one MCP tool; see worker_tools.go's HandleExportAssembly doc comment.
	registry.Register(tools.ExportAssembly, tools.HandleExportAssembly)
	// pcb.route is a dotted panel-IPC channel (like pcb.serialize/...), not an
	// LLM-facing pcb_* tool name — but unlike the in-process project channels,
	// it forwards to the Python worker's "route" method (see worker_tools.go),
	// so it registers here in the worker-backed section, not WrapInProcess'd.
	registry.Register(tools.RouteChannel, tools.HandleRouteChannel)
	// pcb.draft_check — same dotted panel-IPC channel shape as pcb.route,
	// forwarding to the worker's "draft_check" method (T2.4). See worker_tools.go.
	registry.Register(tools.DraftCheckChannel, tools.HandleDraftCheckChannel)
	// pcb.assembly_check — same dotted panel-IPC channel shape again,
	// forwarding to the worker's "assembly_check" method (DCR 019fd5fd9084,
	// work items 019fd5fe1241/019fd5fe2724). See worker_tools.go.
	registry.Register(tools.AssemblyCheckChannel, tools.HandleAssemblyCheckChannel)
	// pcb.board_health — whole-board health (census + assembly) without a
	// routing run (Epoch UX2 station 9). See worker_tools.go.
	registry.Register(tools.BoardHealthChannel, tools.HandleBoardHealthChannel)
	registry.Register(tools.MaskViewChannel, tools.HandleMaskViewChannel)
	registry.Register(tools.FabPreviewChannel, tools.HandleFabPreviewChannel)
	// Rendered-bless surface (S3/B2, docket 019ff5687b99) — the library trust
	// boundary: stage a .kicad_mod into the WIP layer, render the fact
	// table + SVG a human blesses against, record the verdict. All three
	// forward to the worker with wip_root forced to <data dir>/library_wip
	// (see worker_tools.go's withWIPRoot).
	registry.Register(tools.FootprintStage, tools.HandleFootprintStage)
	registry.Register(tools.FootprintReport, tools.HandleFootprintReport)
	registry.Register(tools.FootprintBless, tools.HandleFootprintBless)
	// minerva_pcb_footprint_promote (B7, docket 019ff7c02fd6) — the bless
	// gate's exit door: a blessed WIP part moves whole into the durable user
	// layer at <data dir>/library_user, both roots host-forced (see
	// worker_tools.go's withPromoteRoots).
	registry.Register(tools.FootprintPromote, tools.HandleFootprintPromote)
	// minerva_pcb_acquire_footprint (S4/B3, docket 019ff5689732) — the ON-DEMAND
	// half of the same surface: Go fetches one official KiCad footprint from the
	// release tag pinned in libraries.lock.json, the worker stages + auto-blesses
	// it through the B2 machinery above. Worker-backed (it ends in a w.Call), even
	// though its first half is in-process network work.
	registry.Register(tools.AcquireFootprint, tools.HandleAcquireFootprint)
	// minerva_pcb_import_footprint (B4, docket 019ff568b56b) — the ARBITRARY-source
	// half: a git rev, a URL, or a vendor-export zip on disk. Same Go-reads /
	// worker-stages split as acquire above, and the one difference that matters —
	// it cannot auto-bless, so every imported part waits for a human verdict.
	registry.Register(tools.ImportFootprint, tools.HandleImportFootprint)
	// pcb.promote_check — the K13 promotion gate: full connectivity +
	// geometric DRC + assembly, one fail-closed verdict (Epoch UX3 station
	// 11). See worker_tools.go.
	registry.Register(tools.PromoteCheckChannel, tools.HandlePromoteCheckChannel)
}

// ---------------------------------------------------------------------------
// MCP handler functions
// ---------------------------------------------------------------------------

func handleInitialize(id json.RawMessage) rpcResponse {
	log.Printf("pcb-plugin: initialize")
	return okResponse(id, map[string]interface{}{
		"protocolVersion": protocolVersion,
		"capabilities":    map[string]interface{}{},
		"serverInfo": map[string]string{
			"name":    serverName,
			"version": serverVersion,
		},
	})
}

func handleToolsList(id json.RawMessage) rpcResponse {
	log.Printf("pcb-plugin: tools/list")
	specs := registry.Specs()
	type mcpTool struct {
		Name        string          `json:"name"`
		Description string          `json:"description"`
		InputSchema json.RawMessage `json:"inputSchema"`
	}
	mcpTools := make([]mcpTool, len(specs))
	for i, s := range specs {
		mcpTools[i] = mcpTool{Name: s.Name, Description: s.Description, InputSchema: s.InputSchema}
	}
	return okResponse(id, map[string]interface{}{"tools": mcpTools})
}

// workerBackedTools is a TEST-SIDE assertion helper, not a runtime envelope
// gate: handleToolsCall below wraps EVERY successful dispatch in the same
// {ok:true, result:...} envelope and every worker error in the same
// {ok:false, error:...} envelope, unconditionally, regardless of whether the
// tool name appears here — this map is never read from handleToolsCall or
// anywhere else in the production path. Its only reader is
// TestWorkerBackedToolsHaveSchemas (main_test.go), which uses it as an
// allowlist of "this tool should carry a real (non-empty) input schema and
// description" — i.e. the worker-dispatched tools, as opposed to ping (an
// in-process health check with a trivial schema by design). Cold review
// (docket 019fa486b408) verified this by mutation: reverting a key here back
// to a stale pre-rename name, with the broker spec and manifest both correct,
// left the entire test suite green — proof this map does not gate anything
// a caller of tools/call would observe.
//
// pcb.route is included here even though it's a dotted panel-IPC channel name
// (like pcb.serialize/deserialize/collect_export/apply_export), not an
// LLM-facing pcb_* tool name: those other dotted channels stay OUT of this map
// because they're genuinely in-process (Go-native board codec / echo
// passthroughs, never touch the worker), so they fail the map's literal
// invariant ("dispatch to the Python worker"). pcb.route does dispatch to the
// worker (HandleRouteChannel calls w.Call(ctx, "route", params)), so it
// satisfies that invariant regardless of its dotted name — membership here
// tracks worker-dispatch, not naming convention.
var workerBackedTools = map[string]bool{
	"minerva_pcb_validate":        true,
	"minerva_pcb_generate":        true,
	"minerva_pcb_gerbers":         true,
	"minerva_pcb_drc":             true,
	"minerva_pcb_drc_geometric":   true,
	"minerva_pcb_resolve":         true,
	"minerva_pcb_normalize":       true,
	"minerva_pcb_check_libraries": true,
	"minerva_pcb_check_bom":       true,
	"minerva_pcb_export_assembly": true,
	// Rendered-bless surface (S3/B2) — all three dispatch to the worker's
	// footprint_stage/footprint_report/footprint_bless methods.
	"minerva_pcb_footprint_stage":  true,
	"minerva_pcb_footprint_report": true,
	"minerva_pcb_footprint_bless":  true,
	// minerva_pcb_acquire_footprint (S4/B3) ends in a w.Call to the worker's
	// footprint_acquire_store method, so it satisfies this map's worker-dispatch
	// invariant — the in-process HTTPS fetch that precedes the call is the half
	// that CANNOT live in the worker (network code is Go-only here), not a
	// reason to treat the tool as in-process.
	"minerva_pcb_acquire_footprint": true,
	"pcb.route":                     true,
	"pcb.draft_check":               true,
	// pcb.assembly_check dispatches to the worker (HandleAssemblyCheckChannel
	// calls w.Call(ctx, "assembly_check", params)) — same membership rationale
	// as pcb.route/pcb.draft_check above: worker-dispatch, not naming.
	"pcb.assembly_check": true,
	// pcb.board_health dispatches to the worker's "board_health" method
	// (Epoch UX2 station 9) — same rationale.
	"pcb.board_health": true,
	// pcb.promote_check dispatches to the worker's "promote_check" method
	// (Epoch UX3 station 11, K13) — same rationale.
	"pcb.promote_check": true,
}

func handleToolsCall(id json.RawMessage, params json.RawMessage) rpcResponse {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return errResponse(id, -32700, fmt.Sprintf("tools/call: parse params: %v", err))
	}

	log.Printf("pcb-plugin: tools/call: %s", p.Name)

	// Use context.Background() (not a per-call timeout ctx): the bridge threads
	// the call ctx into exec.CommandContext when it lazily spawns the worker, so
	// a per-call cancel/timeout would KILL the long-lived shared worker and force
	// a cold respawn on the next call. The worker.ready spawn deadline
	// (bridge.readyTimeout, 60s) still bounds startup; the worker methods are
	// fast pure functions over YAML. This mirrors CAD's default tool path.
	ctx := context.Background()

	result, err, found := registry.Dispatch(ctx, worker, p.Name, p.Arguments)
	if !found {
		return errResponse(id, -32601, fmt.Sprintf("method not found: %s", p.Name))
	}

	if err != nil {
		// Worker errors are surfaced as MCP tool result content (isError) so the
		// LLM can inspect them, preserving the {ok:false, error} envelope shape;
		// only non-worker (protocol) errors become JSON-RPC errors.
		var we *bridge.WorkerError
		if asWorkerErr(err, &we) {
			level, msg := workerErrorToast(p.Name, we)
			emitHostNotify(level, msg, we)
			errEnvelope := map[string]interface{}{"ok": false, "error": we}
			errJSON, _ := json.Marshal(errEnvelope)
			return okResponse(id, map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": string(errJSON)},
				},
				"isError": true,
			})
		}
		return errResponse(id, -32603, fmt.Sprintf("tool error: %v", err))
	}

	// Wrap the raw result in {ok:true, result:<result>} so the panel-side decoder
	// is symmetric with the error path. Mirrors cad/main.go.
	successEnvelope := map[string]interface{}{"ok": true, "result": json.RawMessage(result)}
	envelopeJSON, _ := json.Marshal(successEnvelope)
	return okResponse(id, map[string]interface{}{
		"content": []map[string]interface{}{
			{"type": "text", "text": string(envelopeJSON)},
		},
	})
}

// asWorkerErr checks whether err is a *bridge.WorkerError and, if so, sets target.
func asWorkerErr(err error, target **bridge.WorkerError) bool {
	if we, ok := err.(*bridge.WorkerError); ok {
		*target = we
		return true
	}
	return false
}

// workerErrorToast maps a WorkerError to a (level, message) toast pair.
func workerErrorToast(toolName string, we *bridge.WorkerError) (level, message string) {
	switch we.Kind {
	case "crashed", "python", "internal":
		return "error", fmt.Sprintf("PCB plugin [%s]: worker error (%s) — %s", toolName, we.Kind, we.Message)
	case "parse", "io":
		return "warning", fmt.Sprintf("PCB plugin [%s]: %s — %s", toolName, we.Kind, we.Message)
	case "timeout":
		return "warning", fmt.Sprintf("PCB plugin [%s]: request timed out — %s", toolName, we.Message)
	case "cancelled":
		return "info", ""
	default:
		return "error", fmt.Sprintf("PCB plugin [%s]: worker error (%s) — %s", toolName, we.Kind, we.Message)
	}
}

// criticalStderrPrefixes flag critical Python-worker stderr lines to toast.
var criticalStderrPrefixes = []string{
	"FATAL:",
	"ERROR:",
	"ModuleNotFoundError:",
	"ImportError:",
	"RuntimeError:",
	"Traceback (most recent call last):",
}

func isCriticalStderrLine(line string) bool {
	trimmed := strings.TrimSpace(line)
	for _, prefix := range criticalStderrPrefixes {
		if strings.HasPrefix(trimmed, prefix) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

func dispatch(enc *json.Encoder, msg *rpcRequest) {
	isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"

	switch msg.Method {
	case "initialize":
		if isNotification {
			return
		}
		send(enc, handleInitialize(msg.ID))

	case "notifications/initialized":
		log.Printf("pcb-plugin: notifications/initialized (no-op)")

	case "tools/list":
		if isNotification {
			return
		}
		send(enc, handleToolsList(msg.ID))

	case "tools/call":
		if isNotification {
			return
		}
		send(enc, handleToolsCall(msg.ID, msg.Params))

	case "shutdown":
		log.Printf("pcb-plugin: shutdown requested — shutting down worker")
		if worker != nil {
			worker.Shutdown(workerShutdownTimeout)
		}
		log.Printf("pcb-plugin: exiting")
		os.Exit(0)

	default:
		if isNotification {
			log.Printf("pcb-plugin: unknown notification: %s (ignored)", msg.Method)
			return
		}
		log.Printf("pcb-plugin: unknown method: %s", msg.Method)
		send(enc, errResponse(msg.ID, -32601, "Method not found: "+msg.Method))
	}
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[pcb-plugin] ")
	log.SetOutput(os.Stderr)

	log.Printf("starting (pid=%d)", os.Getpid())

	root, err := pluginRootDir()
	if err != nil {
		log.Printf("pcb-plugin: WARNING: cannot determine plugin root: %v", err)
		root = "."
	}
	pluginRoot = root

	initRegistry()
	initWorker()

	enc := json.NewEncoder(os.Stdout)
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var msg rpcRequest
		if err := json.Unmarshal(line, &msg); err != nil {
			log.Printf("JSON parse error: %v", err)
			send(enc, errResponse(json.RawMessage("null"), -32700, "Parse error"))
			continue
		}
		dispatch(enc, &msg)
	}

	if err := scanner.Err(); err != nil {
		log.Printf("stdin read error: %v", err)
		if worker != nil {
			worker.Shutdown(workerShutdownTimeout)
		}
		os.Exit(1)
	}
	log.Printf("stdin closed — exiting")
	if worker != nil {
		worker.Shutdown(workerShutdownTimeout)
	}
}
