// Command cad-plugin is the CAD plugin MCP server for Minerva.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
// This is the same transport used by the hello_scene Python plugin and by
// all Minerva MCP plugins.  The inner protocol (Go ↔ Python worker) uses
// length-prefixed framing (bridge §3) and is separate.
//
// Round 2 implements:
//   - initialize handshake
//   - tools/list → [mcad_validate]
//   - tools/call mcad_validate → lazily spawns Python worker, calls validate
//   - notifications/initialized → no-op
//   - shutdown → graceful worker shutdown, then exit 0
//
// All logging goes to stderr; stdout carries only JSON-RPC responses.
package main

import (
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

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
	sharedruntime "github.com/imrans-lab/minerva-plugins/shared/runtime"
	"github.com/ipeerbhai/plugins/cad/internal/cadruntime"
	"github.com/ipeerbhai/plugins/cad/internal/tools"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "cad"
	serverVersion   = "0.3.22"

	// workerModule is the python module the worker is launched as
	// (`python -m <workerModule>`). Passed to bridge.New.
	workerModule = "mcad_worker"

	// workerShutdownTimeout is how long we give the worker on plugin shutdown
	// before SIGTERM kicks in (§5).
	workerShutdownTimeout = 2 * time.Second
)

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 envelope types (outer / MCP protocol)
// ---------------------------------------------------------------------------

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"` // null for notifications
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

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

func okResponse(id json.RawMessage, result interface{}) rpcResponse {
	return rpcResponse{JSONRPC: "2.0", ID: id, Result: result}
}

func errResponse(id json.RawMessage, code int, msg string) rpcResponse {
	return rpcResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &rpcError{Code: code, Message: msg},
	}
}

// stdoutMu serialises every write to stdout. Both the main JSON-RPC response
// path (send) and the stderr-pump-driven notify path (emitHostNotify) target
// os.Stdout. Without this mutex two goroutines can interleave bytes — line
// atomicity on os.Stdout is only POSIX-guaranteed for pipes ≤ PIPE_BUF, which
// the host (Minerva) may capture as a regular file or socket.
var stdoutMu sync.Mutex

func send(enc *json.Encoder, v interface{}) {
	stdoutMu.Lock()
	defer stdoutMu.Unlock()
	if err := enc.Encode(v); err != nil {
		log.Printf("cad-plugin: write response: %v", err)
	}
}

// ---------------------------------------------------------------------------
// host.notify — Minerva toast pipe
// ---------------------------------------------------------------------------

// notifyParams is the params payload for the host.notify notification.
type notifyParams struct {
	Level   string      `json:"level"`
	Message string      `json:"message"`
	Details interface{} `json:"details,omitempty"`
}

// hostNotify is the JSON-RPC 2.0 notification envelope (no id field).
type hostNotify struct {
	JSONRPC string       `json:"jsonrpc"`
	Method  string       `json:"method"`
	Params  notifyParams `json:"params"`
}

// notifyOut is the writer used to emit host.notify messages. It is set to
// os.Stdout in main() so tests can redirect it to a buffer.
var notifyOut = io.Writer(os.Stdout)

// notifyEnc is a lazily-initialised encoder that targets notifyOut. Tests
// replace this after overriding notifyOut.
var notifyEnc *json.Encoder

// emitHostNotify writes a host.notify JSON-RPC 2.0 notification to stdout so
// Minerva can display it as a toast. level must be "info", "warning", or "error".
// details may be nil. The call is a no-op if message is empty.
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
		Params: notifyParams{
			Level:   level,
			Message: message,
			Details: details,
		},
	}
	if err := notifyEnc.Encode(n); err != nil {
		log.Printf("cad-plugin: emitHostNotify: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Server-owned worker, tool registry and evaluation registrations
// ---------------------------------------------------------------------------

type evaluation struct {
	ctx    context.Context
	cancel context.CancelFunc
}

type server struct {
	ctx    context.Context
	cancel context.CancelFunc

	runnerMu                         sync.Mutex
	runner                           *workerRunner
	tasks                            sync.WaitGroup
	admissionMu                      sync.Mutex
	requestCount, requestBytes       int
	collectionCount, collectionBytes int

	worker     *bridge.Worker
	registry   *tools.Registry
	inflightMu sync.Mutex
	// inflight maps request_id to its current evaluation cancellation.
	inflight map[string]*evaluation
}

func newServer() *server {
	ctx, cancel := context.WithCancel(context.Background())
	return &server{ctx: ctx, cancel: cancel, inflight: make(map[string]*evaluation)}
}

// initWorker resolves the Python interpreter path and constructs the Worker.
// Called once at startup; the worker is NOT yet spawned (lazy per §2).
func (s *server) initWorker() {
	// Determine the plugin root (directory containing this binary / manifest.json).
	pluginRoot, err := pluginRootDir()
	if err != nil {
		log.Printf("cad-plugin: WARNING: cannot determine plugin root: %v", err)
		pluginRoot = "."
	}
	workerDir := sharedruntime.WorkerScriptDir(pluginRoot)

	pythonPath, err := sharedruntime.PythonPath(sharedruntime.PythonPathRequest{
		EmbeddedBundle: cadruntime.EmbeddedBundle,
		EmbeddedSHA256: cadruntime.EmbeddedSHA256,
		WorkerDir:      workerDir,
		// A manifest/source install creates worker/.venv from this checkout.
		// Prefer it over a same-version embedded-runtime cache so reinstalling
		// actually runs the worker source beside the rebuilt wrapper. Release
		// tarballs ship no worker tree and therefore fall through to the embed.
		PreferVenv:    true,
		PluginID:      serverName,
		PluginVersion: serverVersion,
	})
	if err != nil {
		log.Printf("cad-plugin: WARNING: %v — mcad_validate will fail until python3 is on PATH or .venv exists", err)
		emitHostNotify("error",
			"CAD plugin: Python interpreter not found — mcad_validate and mcad_list_edges will fail",
			map[string]string{"detail": err.Error(), "fix": "Install python3 or create a .venv in the plugin worker directory"})
		// Still create a Worker with an empty path so Call returns a clean error.
		pythonPath = ""
	}
	log.Printf("cad-plugin: worker dir=%s, python=%s", workerDir, pythonPath)

	w := bridge.New(pythonPath, workerDir, workerModule)
	// Attach the stderr callback so critical worker stderr lines surface as toasts.
	w.StderrCallback = func(line string) {
		if isCriticalStderrLine(line) {
			emitHostNotify("error", "CAD worker: "+line, nil)
		}
	}
	s.worker = w
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

// initRegistry registers all MCP tools. Called once at startup.
func (s *server) initRegistry() {
	s.registry = tools.NewRegistry()
	s.registry.Register(tools.Validate, tools.HandleValidate)
	s.registry.Register(tools.ListEdges, tools.HandleListEdges)
	s.registry.Register(tools.Evaluate, tools.HandleEvaluate)
	s.registry.Register(tools.Export, tools.HandleExport)
	s.registry.Register(tools.Clearance, tools.HandleClearance)
	s.registry.Register(tools.CylindricalFeatures, tools.HandleCylindricalFeatures)
	s.registry.Register(tools.Material, tools.HandleMaterial)
	s.registry.Register(tools.Motion, tools.HandleMotion)
	s.registry.Register(tools.ReferencePairs, tools.HandleReferencePairs)
	// cad.cancel_eval is registered here so it appears in tools/list, but its
	// handler is intercepted in handleToolsCall before registry dispatch (it
	// needs access to the server-level inflight map). The registry handler
	// is a stub that returns method-not-found if the dispatcher path is ever
	// reached — that should never happen.
	s.registry.Register(tools.CancelEval, handleCancelEvalRegistryStub)
}

// handleCancelEvalRegistryStub is a guard that should never run in practice —
// handleToolsCall intercepts cad.cancel_eval before registry dispatch. If it
// does run, returning a clear error makes the misrouting visible.
func handleCancelEvalRegistryStub(_ context.Context, _ tools.WorkerCaller, _ json.RawMessage) (json.RawMessage, error) {
	return nil, fmt.Errorf("cad.cancel_eval reached registry dispatch (should be intercepted in handleToolsCall)")
}

// ---------------------------------------------------------------------------
// Inflight cad.evaluate tracking — used by cad.cancel_eval.
// ---------------------------------------------------------------------------

// beginEvaluateCancellable parses request_id from a cad.evaluate args payload
// (if present) and registers a cancellable context under that key.
//
// Returns the derived context and the registered key (empty string if no
// request_id was supplied — in that case cancellation is unavailable for the
// request, but the call still proceeds with the parent context).
func (s *server) beginEvaluateCancellable(parent context.Context, args json.RawMessage) (context.Context, string, error) {
	var a struct {
		RequestID string `json:"request_id"`
	}
	// Tolerate missing/non-object args — old callers don't pass request_id.
	if len(args) > 0 {
		if err := json.Unmarshal(args, &a); err != nil {
			return parent, "", nil
		}
	}
	if a.RequestID == "" {
		return parent, "", nil
	}

	ctx, cancel := context.WithCancel(parent)
	s.inflightMu.Lock()
	// If a prior eval somehow left a stale entry under the same request_id,
	// cancel it before overwriting (defensive — request_ids are usec-keyed
	// and unique in practice, but a re-entrant panel bug shouldn't leak).
	if prior, ok := s.inflight[a.RequestID]; ok {
		prior.cancel()
	}
	s.inflight[a.RequestID] = &evaluation{ctx: ctx, cancel: cancel}
	s.inflightMu.Unlock()
	return ctx, a.RequestID, nil
}

// endEvaluateCancellable removes only this registration. Completion and cancel
// linearize under inflightMu; a canceled or replaced request cannot publish a
// late result, and its cleanup cannot erase a newer duplicate registration.
func (s *server) endEvaluateCancellable(ctx context.Context, key string) bool {
	if key == "" {
		return ctx.Err() == nil
	}
	s.inflightMu.Lock()
	defer s.inflightMu.Unlock()
	if current, ok := s.inflight[key]; ok && current.ctx == ctx {
		valid := ctx.Err() == nil
		// Cancel before delete to release any goroutine still awaiting the
		// derived context. Cancelling an already-cancelled CancelFunc is a no-op.
		current.cancel()
		delete(s.inflight, key)
		return valid
	}
	return false
}

// handleCancelEval looks up the inflight entry for the supplied request_id
// and cancels it. Unknown request_ids return ok=true with cancelled=false so
// the panel can fire-and-forget.
func (s *server) handleCancelEval(id json.RawMessage, args json.RawMessage) rpcResponse {
	var a struct {
		RequestID string `json:"request_id"`
	}
	if err := json.Unmarshal(args, &a); err != nil {
		return errResponse(id, -32602, fmt.Sprintf("cad.cancel_eval: parse args: %v", err))
	}
	if a.RequestID == "" {
		return errResponse(id, -32602, "cad.cancel_eval: request_id is required")
	}

	cancelled := false
	s.inflightMu.Lock()
	if current, ok := s.inflight[a.RequestID]; ok {
		current.cancel()
		delete(s.inflight, a.RequestID)
		cancelled = true
	}
	s.inflightMu.Unlock()

	log.Printf("cad-plugin: cancel_eval request_id=%s cancelled=%v", a.RequestID, cancelled)

	envelope := map[string]interface{}{
		"ok":         true,
		"request_id": a.RequestID,
		"cancelled":  cancelled,
	}
	envelopeJSON, _ := json.Marshal(envelope)
	return okResponse(id, map[string]interface{}{
		"content": []map[string]interface{}{
			{"type": "text", "text": string(envelopeJSON)},
		},
	})
}

// workerFailureResponse renders a worker/spawn failure the way the panel and
// the LLM expect: an error toast plus an {ok:false, error} envelope carried as
// an isError tool result, so panel-side decoders read worker_payload.ok /
// .error uniformly with the success path. Non-WorkerError failures stay MCP
// protocol errors.
func workerFailureResponse(id json.RawMessage, toolName string, err error) rpcResponse {
	var we *bridge.WorkerError
	if !asWorkerErr(err, &we) {
		return errResponse(id, -32603, fmt.Sprintf("tool error: %v", err))
	}
	// Surface spawn/crash errors (kind: crashed, python, internal) as error
	// toasts; validation failures (kind: parse, translate, occt) as warnings.
	toastLevel, toastMsg := workerErrorToast(toolName, we)
	emitHostNotify(toastLevel, toastMsg, we)
	errEnvelope := map[string]interface{}{"ok": false, "error": we}
	errJSON, _ := json.Marshal(errEnvelope)
	return okResponse(id, map[string]interface{}{
		"content": []map[string]interface{}{
			{"type": "text", "text": string(errJSON)},
		},
		"isError": true,
	})
}

// ---------------------------------------------------------------------------
// MCP handler functions
// ---------------------------------------------------------------------------

func handleInitialize(id json.RawMessage) rpcResponse {
	log.Printf("cad-plugin: initialize")
	return okResponse(id, map[string]interface{}{
		"protocolVersion": protocolVersion,
		"capabilities":    map[string]interface{}{},
		"serverInfo": map[string]string{
			"name":    serverName,
			"version": serverVersion,
		},
	})
}

func (s *server) handleToolsList(id json.RawMessage) rpcResponse {
	log.Printf("cad-plugin: tools/list")
	specs := s.registry.Specs()
	// Build the MCP tools array: each entry has name, description, inputSchema.
	type mcpTool struct {
		Name        string          `json:"name"`
		Description string          `json:"description"`
		InputSchema json.RawMessage `json:"inputSchema"`
	}
	mcpTools := make([]mcpTool, len(specs))
	for i, s := range specs {
		mcpTools[i] = mcpTool{
			Name:        s.Name,
			Description: s.Description,
			InputSchema: s.InputSchema,
		}
	}
	return okResponse(id, map[string]interface{}{
		"tools": mcpTools,
	})
}

// prepareToolsCall runs on the reader before scheduling, so a following
// cancel cannot overtake evaluation registration. Its closure owns cleanup.
func (s *server) prepareToolsCall(id json.RawMessage, params json.RawMessage) (func() rpcResponse, error) {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, fmt.Errorf("tools/call: parse params: %w", err)
	}
	if len(p.Arguments) > maxPayloadBytes {
		return nil, fmt.Errorf("tools/call: arguments exceed 8 MiB payload limit")
	}
	ctx, key := s.ctx, ""
	runner := s.workerCalls()
	var caller tools.WorkerCaller = runner
	var ticket *workerTicket
	if p.Name == "cad.evaluate" {
		var err error
		// HandleEvaluate forwards these exact arguments in one worker Call.
		// Reserve actual capacity before replacing/canceling a prior request.
		ticket, err = runner.reserve(ctx, len(p.Arguments))
		if err != nil {
			return nil, err
		}
		caller = ticket
		ctx, key, err = s.beginEvaluateCancellable(ctx, p.Arguments)
		if err != nil {
			ticket.releaseUnused()
			return nil, err
		}
	}
	return func() rpcResponse {
		if ticket != nil {
			defer ticket.releaseUnused()
		}
		return s.handleToolsCall(ctx, caller, id, p.Name, p.Arguments, key)
	}, nil
}

func (s *server) handleToolsCall(ctx context.Context, caller tools.WorkerCaller, id json.RawMessage, toolName string, args json.RawMessage, key string) rpcResponse {
	log.Printf("cad-plugin: tools/call: %s", toolName)
	if toolName == "cad.cancel_eval" {
		return s.handleCancelEval(id, args)
	}
	var result json.RawMessage
	var err error
	found := true
	if ctx.Err() != nil {
		err = cancelledError(ctx.Err())
	} else {
		result, err, found = s.registry.Dispatch(ctx, caller, toolName, args)
	}
	// Finalize identity before emitting success, errors or error notifications.
	// A later cancel sees a completed registration and returns cancelled=false.
	if !s.endEvaluateCancellable(ctx, key) {
		return workerFailureResponse(id, toolName, cancelledError(context.Canceled))
	}
	if !found {
		return errResponse(id, -32601, fmt.Sprintf("method not found: %s", toolName))
	}

	if err != nil {
		// Worker errors are returned as MCP tool result content (not MCP errors)
		// so the LLM can inspect them. Only internal/protocol errors become MCP errors.
		return workerFailureResponse(id, toolName, err)
	}

	// Wrap the raw result in {ok: true, result: <result>} so the panel-side
	// decoder is symmetric with the error path (which uses {ok: false, error}).
	// bridge.Worker.Call strips the worker's {ok, result} wrapper on success,
	// so we re-wrap here before forwarding to MCP.
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

// workerErrorToast maps a WorkerError to a (level, message) pair for toast
// display. Spawn/crash errors surface at "error"; validation failures at
// "warning" so the user can act without alarm. A kind whose message is
// already a complete sentence about the geometry is passed through as it
// stands rather than being prefixed with a category the user cannot use.
func workerErrorToast(toolName string, we *bridge.WorkerError) (level, message string) {
	switch we.Kind {
	case "crashed", "python", "internal":
		return "error", fmt.Sprintf("CAD plugin [%s]: worker error (%s) — %s", toolName, we.Kind, we.Message)
	case "parse", "translate", "occt":
		return "warning", fmt.Sprintf("CAD plugin [%s]: validation failed (%s) — %s", toolName, we.Kind, we.Message)
	case "mesh_invalid":
		// A 3MF the writer refused. The message already names the defect
		// class, its count and the part, so it goes to the user verbatim:
		// "worker error" told the owner nothing they could act on.
		return "warning", fmt.Sprintf("CAD plugin [%s]: %s", toolName, we.Message)
	case "busy":
		return "warning", fmt.Sprintf("CAD plugin [%s]: %s", toolName, we.Message)
	case "timeout":
		return "warning", fmt.Sprintf("CAD plugin [%s]: request timed out — %s", toolName, we.Message)
	case "cancelled":
		// Cancellation is expected; no toast needed. Return empty to suppress.
		return "info", ""
	default:
		return "error", fmt.Sprintf("CAD plugin [%s]: worker error (%s) — %s", toolName, we.Kind, we.Message)
	}
}

// criticalStderrPrefixes are line prefixes that indicate a critical problem in
// the Python worker's stderr stream and should be surfaced as toast errors.
// Lines that do NOT match any prefix are forwarded to the Go process's stderr
// as-is (for the Activity log) but are NOT toasted.
//
// Design call on cold-start progress (build123d import, OCCT init):
//   - Cold-start INFO/progress lines are intentionally NOT toasted — they are
//     expected during first-use and would be noisy.
//   - Only lines matching these prefixes become toasts; everything else is
//     stderr-only (visible in the Activity log, not in toasts).
var criticalStderrPrefixes = []string{
	"FATAL:",
	"ERROR:",
	"ModuleNotFoundError:",
	"ImportError:",
	"RuntimeError:",
	"Traceback (most recent call last):",
}

// isCriticalStderrLine returns true if line matches the critical filter.
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

func (s *server) dispatch(enc *json.Encoder, msg *rpcRequest) bool {
	isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"
	if msg.Method == "shutdown" {
		log.Printf("cad-plugin: shutdown requested — stopping worker")
		return false
	}
	if msg.Method == "notifications/initialized" {
		log.Printf("cad-plugin: notifications/initialized (no-op)")
		return true
	}
	if isNotification {
		return true
	}
	switch msg.Method {
	case "initialize":
		send(enc, handleInitialize(msg.ID))
	case "tools/list":
		send(enc, s.handleToolsList(msg.ID))
	case "tools/call":
		// Control cancellation is inline and never consumes worker/task admission.
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(msg.Params, &p); err != nil {
			send(enc, errResponse(msg.ID, -32700, fmt.Sprintf("tools/call: parse params: %v", err)))
			return true
		}
		if p.Name == "cad.cancel_eval" {
			if len(p.Arguments) > maxPayloadBytes {
				send(enc, errResponse(msg.ID, -32602, "arguments exceed 8 MiB payload limit"))
			} else {
				send(enc, s.handleCancelEval(msg.ID, p.Arguments))
			}
			return true
		}
		// Reserve before registration, so refused requests cannot replace an eval.
		collection := false
		if p.Name == "cad.export" {
			var a struct {
				JobID string `json:"job_id"`
			}
			if err := json.Unmarshal(p.Arguments, &a); err == nil {
				collection = a.JobID != ""
			}
		}
		size := len(msg.Params) + len(msg.ID)
		if !s.admitRequest(size, collection) {
			send(enc, errResponse(msg.ID, -32000, "CAD request capacity reached; retry later"))
			return true
		}
		call, err := s.prepareToolsCall(msg.ID, msg.Params)
		if err != nil {
			s.releaseRequest(size, collection)
			var we *bridge.WorkerError
			if asWorkerErr(err, &we) {
				send(enc, workerFailureResponse(msg.ID, p.Name, err))
			} else {
				send(enc, errResponse(msg.ID, -32602, err.Error()))
			}
			return true
		}
		s.tasks.Add(1)
		go func() {
			defer s.tasks.Done()
			defer s.releaseRequest(size, collection)
			send(enc, call())
		}()
	default:
		send(enc, errResponse(msg.ID, -32601, "Method not found: "+msg.Method))
	}
	return true
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	// Logging goes to stderr only; stdout is reserved for JSON-RPC responses.
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[cad-plugin] ")
	log.SetOutput(os.Stderr)

	log.Printf("starting (pid=%d)", os.Getpid())

	// Initialize the tool registry and worker (lazy spawn) at startup.
	s := newServer()
	s.initRegistry()
	s.initWorker()

	enc := json.NewEncoder(os.Stdout)
	readErr := s.serve(s.ctx, os.Stdin, enc)
	shutdownCtx, stopShutdown := context.WithTimeout(context.Background(), serverShutdownTimeout)
	defer stopShutdown()
	if err := s.shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
	if readErr != nil {
		log.Printf("stdin read error: %v", readErr)
		os.Exit(1)
	}
	log.Printf("stdin closed or shutdown requested — exiting")
}
