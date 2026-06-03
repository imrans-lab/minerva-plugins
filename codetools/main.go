// Command codetools-plugin is the Code Tools plugin MCP server for Minerva.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line — the
// same transport every Minerva MCP plugin speaks. The inner protocol (Go ↔
// Python worker) uses length-prefixed framing (bridge §3) and is separate.
//
// P1.1 is the SUBSTRATE skeleton only: it exposes a single health tool,
// minerva_codetools_ping, that round-trips through the embedded Python worker
// to prove the stdio → Go → bridge → Python path end to end. No subsystem
// logic (files / code-visualizer / code-probe) lives here yet — later phases
// register their tools against this same registry + worker.
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
	"sync"
	"time"

	"github.com/imrans-lab/minerva-plugins/codetools/internal/bridge"
	"github.com/imrans-lab/minerva-plugins/codetools/internal/runtime"
	"github.com/imrans-lab/minerva-plugins/codetools/internal/tools"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "codetools"
	serverVersion   = "0.1.0"

	// workerModule is the python package the Go shim spawns (`python -m <module>`).
	workerModule = "codetools_worker"

	// workerShutdownTimeout is how long we give the worker on plugin shutdown
	// before SIGTERM kicks in (bridge §5).
	workerShutdownTimeout = 2 * time.Second
)

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 envelope types (outer / MCP protocol)
// ---------------------------------------------------------------------------

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"` // null/absent for notifications
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  interface{} `json:"result,omitempty"`
	Error   *rpcError   `json:"error,omitempty"`
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

// stdoutMu serialises every write to stdout. Both the JSON-RPC response path
// (send) and the host.notify path (emitHostNotify) target os.Stdout; without
// this mutex two goroutines can interleave bytes (line atomicity on os.Stdout
// is only POSIX-guaranteed for pipes ≤ PIPE_BUF, and Minerva may capture our
// stdout as a socket).
var stdoutMu sync.Mutex

func send(enc *json.Encoder, v interface{}) {
	stdoutMu.Lock()
	defer stdoutMu.Unlock()
	if err := enc.Encode(v); err != nil {
		log.Printf("codetools-plugin: write response: %v", err)
	}
}

// ---------------------------------------------------------------------------
// host.notify — Minerva toast pipe
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

// notifyOut is the writer used to emit host.notify messages. Set to os.Stdout
// in main(); tests can redirect it to a buffer.
var notifyOut = io.Writer(os.Stdout)
var notifyEnc *json.Encoder

// emitHostNotify writes a host.notify JSON-RPC 2.0 notification to stdout so
// Minerva can display it as a toast. level must be "info", "warning", or
// "error". No-op when message is empty.
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
		log.Printf("codetools-plugin: emitHostNotify: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Global worker + tool registry
// ---------------------------------------------------------------------------

var (
	worker   *bridge.Worker
	registry *tools.Registry
)

// initRegistry registers all MCP tools. Called once at startup. P1.1 shipped
// the health tool; P1.3 adds the 9 code-visualizer tools (vendored code-magic
// behind the unified envelope). Later phases append files/code-probe here.
func initRegistry() {
	registry = tools.NewRegistry()
	registry.Register(tools.Ping, tools.HandlePing)

	// P1.3 — code-visualizer (vendored @9cc9403).
	registry.Register(tools.Query, tools.HandleQuery)
	registry.Register(tools.GetContext, tools.HandleGetContext)
	registry.Register(tools.StaleCheck, tools.HandleStaleCheck)
	registry.Register(tools.GetDiff, tools.HandleGetDiff)
	registry.Register(tools.Analyze, tools.HandleAnalyze)
	registry.Register(tools.SetDescription, tools.HandleSetDescription)
	registry.Register(tools.DescribeSymbol, tools.HandleDescribeSymbol)
	registry.Register(tools.SetTags, tools.HandleSetTags)
	registry.Register(tools.Undescribed, tools.HandleUndescribed)

	// P1.4 — full code graph with precomputed layout positions.
	registry.Register(tools.GetGraph, tools.HandleGetGraph)
}

// initWorker resolves the Python interpreter and constructs the Worker. Called
// once at startup; the worker is NOT spawned yet (lazy, bridge §2).
func initWorker() {
	pluginRoot, err := pluginRootDir()
	if err != nil {
		log.Printf("codetools-plugin: WARNING: cannot determine plugin root: %v", err)
		pluginRoot = "."
	}
	workerDir := runtime.WorkerScriptDir(pluginRoot)

	pythonPath, err := runtime.PythonPath(workerDir, serverName, serverVersion)
	if err != nil {
		log.Printf("codetools-plugin: WARNING: %v — tools will fail until python3 is on PATH or .venv exists", err)
		emitHostNotify("error",
			"Code Tools plugin: Python interpreter not found — tools will fail",
			map[string]string{"detail": err.Error(), "fix": "Reinstall the plugin or ensure python3 is available"})
		pythonPath = ""
	}
	log.Printf("codetools-plugin: worker dir=%s, python=%s", workerDir, pythonPath)

	w := bridge.New(pythonPath, workerDir, workerModule)
	w.StderrCallback = func(line string) {
		// Surface only clearly-critical worker stderr as toasts; everything
		// else stays on stderr (Activity log).
		if isCriticalStderrLine(line) {
			emitHostNotify("error", "Code Tools worker: "+line, nil)
		}
	}
	worker = w
}

// pluginRootDir returns the directory of the running executable, which by
// convention is the plugin root (contains manifest.json and worker/).
func pluginRootDir() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("os.Executable: %w", err)
	}
	return filepath.Dir(filepath.Clean(exe)), nil
}

// ---------------------------------------------------------------------------
// MCP handler functions
// ---------------------------------------------------------------------------

func handleInitialize(id json.RawMessage) rpcResponse {
	log.Printf("codetools-plugin: initialize")
	return okResponse(id, map[string]interface{}{
		"protocolVersion": protocolVersion,
		"capabilities":    map[string]interface{}{},
		"serverInfo":      map[string]string{"name": serverName, "version": serverVersion},
	})
}

func handleToolsList(id json.RawMessage) rpcResponse {
	log.Printf("codetools-plugin: tools/list")
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

func handleToolsCall(id json.RawMessage, params json.RawMessage) rpcResponse {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return errResponse(id, -32700, fmt.Sprintf("tools/call: parse params: %v", err))
	}
	log.Printf("codetools-plugin: tools/call: %s", p.Name)

	result, err, found := registry.Dispatch(context.Background(), worker, p.Name, p.Arguments)
	if !found {
		return errResponse(id, -32601, fmt.Sprintf("method not found: %s", p.Name))
	}
	if err != nil {
		// Worker errors come back as MCP tool-result content (not MCP errors)
		// so the model can inspect them; only protocol/internal errors become
		// MCP errors.
		if we, ok := err.(*bridge.WorkerError); ok {
			// Toast only LIFECYCLE failures (crash/internal) — they're health
			// signals. Ordinary tool-level errors already travel back in the
			// result envelope; toasting every one would spam the user.
			if we.Kind == "crashed" || we.Kind == "internal" {
				emitHostNotify("error",
					fmt.Sprintf("Code Tools [%s]: worker %s — %s", p.Name, we.Kind, we.Message), nil)
			}
			// PROVISIONAL P1.1 error envelope: {ok:false, error:{kind,message}}.
			// Deliberately drops the worker's traceback/details (kept on stderr
			// via the bridge stderr pump) so unbounded internal data never reaches
			// the model. P1.2 introduces the CANONICAL unified result envelope +
			// router and owns this shape — do not entrench this ad-hoc one.
			errJSON, _ := json.Marshal(map[string]interface{}{
				"ok":    false,
				"error": map[string]string{"kind": we.Kind, "message": we.Message},
			})
			return okResponse(id, map[string]interface{}{
				"content": []map[string]interface{}{{"type": "text", "text": string(errJSON)}},
				"isError": true,
			})
		}
		return errResponse(id, -32603, fmt.Sprintf("tool error: %v", err))
	}

	// The worker result is the P1.2 unified envelope. Wrap it transport-side as
	// {ok:true, result:<envelope>}. A handler-level failure comes back as an
	// envelope with status=="error" (still a successful CALL) — mirror that onto
	// the MCP isError flag so the host's one documented error signal (isError)
	// never disagrees with the envelope's status.
	envelopeJSON, _ := json.Marshal(map[string]interface{}{"ok": true, "result": json.RawMessage(result)})
	var probe struct {
		Status string `json:"status"`
	}
	_ = json.Unmarshal(result, &probe)
	mcp := map[string]interface{}{
		"content": []map[string]interface{}{{"type": "text", "text": string(envelopeJSON)}},
	}
	if probe.Status == "error" {
		mcp["isError"] = true
	}
	return okResponse(id, mcp)
}

// criticalStderrPrefixes mark worker stderr lines worth surfacing as toasts.
var criticalStderrPrefixes = []string{
	"FATAL:", "ERROR:", "ModuleNotFoundError:", "ImportError:",
	"RuntimeError:", "Traceback (most recent call last):",
}

func isCriticalStderrLine(line string) bool {
	for _, prefix := range criticalStderrPrefixes {
		if len(line) >= len(prefix) && line[:len(prefix)] == prefix {
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
		log.Printf("codetools-plugin: notifications/initialized (no-op)")
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
		log.Printf("codetools-plugin: shutdown requested — shutting down worker")
		if worker != nil {
			worker.Shutdown(workerShutdownTimeout)
		}
		log.Printf("codetools-plugin: exiting")
		os.Exit(0)
	default:
		if isNotification {
			log.Printf("codetools-plugin: unknown notification: %s (ignored)", msg.Method)
			return
		}
		log.Printf("codetools-plugin: unknown method: %s", msg.Method)
		send(enc, errResponse(msg.ID, -32601, "Method not found: "+msg.Method))
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[codetools-plugin] ")
	log.SetOutput(os.Stderr)
	log.Printf("starting (pid=%d)", os.Getpid())

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
