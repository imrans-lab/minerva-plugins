// Command pcb-plugin is the PCB Editor plugin MCP server for Minerva.
//
// Protocol: JSON-RPC 2.0 over stdin/stdout, one message per line — the same
// transport Minerva uses for every stdio MCP plugin (see cad/main.go for the
// worker-backed sibling). The inner protocol (Go ↔ Python worker) uses
// length-prefixed framing via the shared bridge and is separate.
//
// This build implements:
//   - initialize handshake
//   - tools/list → [ping, pcb.*, pcb_validate, pcb_generate,
//     pcb_check_libraries, pcb_check_bom]
//   - tools/call → in-process tools answered directly; pcb_* tools lazily spawn
//     the Python worker (python -m pcb_worker) via the shared bridge (circuit
//     breaker + graceful shutdown come free).
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

	"github.com/imrans-lab/minerva-plugins/pcb/internal/tools"
	"github.com/imrans-lab/minerva-plugins/shared/bridge"
	sharedruntime "github.com/imrans-lab/minerva-plugins/shared/runtime"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "pcb"
	serverVersion   = "0.2.0"

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
// location for the pcb_fetch_libraries / pcb_library_status tools).
var pluginRoot string

// initWorker resolves the Python interpreter and constructs the Worker. The
// worker is NOT spawned here — spawning is lazy (first pcb_* tool call). This
// plugin has no embedded PBS bundle yet, so PythonPath falls through to the dev
// tiers: <worker>/.venv, then python3 on PATH.
func initWorker() {
	workerDir := sharedruntime.WorkerScriptDir(pluginRoot)

	pythonPath, err := sharedruntime.PythonPath(sharedruntime.PythonPathRequest{
		EmbeddedBundle: nil, // no embedded runtime this round — dev fallbacks only
		EmbeddedSHA256: "",
		WorkerDir:      workerDir,
		PluginID:       serverName,
		PluginVersion:  serverVersion,
	})
	if err != nil {
		log.Printf("pcb-plugin: WARNING: %v — pcb_* worker tools will fail until a .venv exists or python3 is on PATH", err)
		emitHostNotify("error",
			"PCB plugin: Python interpreter not found — pcb_validate/generate/check_* will fail",
			map[string]string{"detail": err.Error(), "fix": "Create a .venv in the plugin worker/ dir (pip install -e .) or put python3 on PATH"})
		pythonPath = ""
	}
	log.Printf("pcb-plugin: worker dir=%s, python=%s", workerDir, pythonPath)

	w := bridge.New(pythonPath, workerDir, workerModule)
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
	registry.Register(tools.Deserialize, tools.WrapInProcess(tools.HandleDeserialize))
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
	registry.Register(tools.Resolve, tools.HandleResolve)
	registry.Register(tools.CheckLibraries, tools.HandleCheckLibraries)
	registry.Register(tools.CheckBOM, tools.HandleCheckBOM)
	// pcb.route is a dotted panel-IPC channel (like pcb.serialize/...), not an
	// LLM-facing pcb_* tool name — but unlike the in-process project channels,
	// it forwards to the Python worker's "route" method (see worker_tools.go),
	// so it registers here in the worker-backed section, not WrapInProcess'd.
	registry.Register(tools.RouteChannel, tools.HandleRouteChannel)
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

// workerBackedTools is the set of tool names that dispatch to the Python worker
// and therefore return the worker's {ok, result|error} envelope shape.
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
	"pcb_validate":        true,
	"pcb_generate":        true,
	"pcb_gerbers":         true,
	"pcb_drc":             true,
	"pcb_resolve":         true,
	"pcb_check_libraries": true,
	"pcb_check_bom":       true,
	"pcb.route":           true,
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
