// Package tools — cad.export tool registration and handler.
//
// Export the last 3D part produced by .mcad source to a file.
// Format is one of: "stl" (binary), "step"/"stp" (AP214), "3mf", "glb".
//
// Like cad.evaluate, the MCP tool name is the dotted "cad.export" (which is
// also the IPC channel name). The worker method is the bare verb "export"
// — see worker/mcad_worker/methods.py:_export.
//
// AN EXPORT THAT MUST BUILD RUNS DETACHED. The worker reuses the part the
// panel's last evaluation built when the source matches, and that export is
// a file write. When it does not match — the buffer was edited and not yet
// evaluated — the export translates the whole DSL, which on a lofted shell of
// ~60 booleans is minutes: far past the window an MCP client gives a tool
// call, and past the point where the plugin's own stdio loop may sit blocked
// (main.go dispatches one request at a time, so a handler that waits for the
// worker also stops the panel's evaluations being read). So the handler waits
// only exportFirstReply and then answers "running"; the work carries on in a
// goroutine and the SAME call, made again with the same source, format and
// path, collects it. The job key is the request itself — there is no ticket
// to carry, which is what lets a caller wait on a slow export without the
// host learning a new argument.
package tools

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// Export is the MCP tool spec for cad.export.
var Export = ToolSpec{
	Name: "cad.export",
	Description: "Export the last 3D part produced by .mcad source to a file. " +
		"Returns {path, bytes_written, format, reused_evaluation}. " +
		"Supported formats: \"stl\" (binary STL — build123d default), " +
		"\"step\" or \"stp\" (STEP AP214 — OCCT default schema), " +
		"\"3mf\" (build123d Mesher), " +
		"\"glb\" (minimal binary glTF, one node named after the part, written " +
		"in the glTF frame of metres and Y-up so mesh(\"that.glb\") mounts it back " +
		"at the same size and pose). " +
		"Path is absolute as-is; ~-prefixed paths are expanded; bare relative " +
		"paths resolve against the user's home directory. " +
		"Source the panel has already evaluated is exported from the part that " +
		"evaluation built (reused_evaluation true) and costs only the file write. " +
		"Source that must be built runs detached: if it is still building after " +
		"about 20 s the call answers kind=running with elapsed_ms and nothing is " +
		"written yet — call cad.export AGAIN with the same source, format and path " +
		"to collect the finished export. " +
		"Errors are returned as data: kind=running (still building, ask again), " +
		"kind=parse|translate (bad DSL), " +
		"kind=mesh_invalid (3MF only — the part is not a closed manifold solid; " +
		"the message names the defect class and count from the last evaluation, " +
		"and STL/STEP still export it), " +
		"kind=io (disk write failed), kind=internal (bad params).",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"source": {"type": "string", "description": ".mcad DSL source code"},
			"format": {"type": "string", "enum": ["stl", "step", "stp", "3mf", "glb"], "description": "Output format. STL is binary. GLB is the only one mesh() can read back."},
			"path": {"type": "string", "description": "Absolute, ~-prefixed, or bare relative path. Bare relative resolves against the user's home directory."}
		},
		"required": ["source", "format", "path"]
	}`),
}

// exportFirstReply is how long the verb waits for an export before answering
// "running". A variable, not a constant, so a test can drive the handover
// without spending the window waiting for it; nothing in the plugin writes it.
var exportFirstReply = 20 * time.Second

// exportJobKeep is how long a finished export stays collectable. Far longer
// than any export, so only a job nobody came back for is ever swept.
const exportJobKeep = 15 * time.Minute

// exportJob is one detached export. done is closed when the worker has
// answered; result/err are then final and are handed to exactly one collector.
type exportJob struct {
	started time.Time
	done    chan struct{}
	result  json.RawMessage
	err     error
}

var (
	exportMu   sync.Mutex
	exportJobs = map[string]*exportJob{}
)

// HandleExport dispatches an export request to the worker via the bridge.
// The worker method name is "export" (no cad./mcad_ prefix).
// DSL/IO errors are returned as data per design §8.2; only internal/python
// errors propagate as Go errors.
func HandleExport(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return handleExportWith(ctx, params, func(callCtx context.Context, p json.RawMessage) (json.RawMessage, error) {
		return w.Call(callCtx, "export", p)
	})
}

// handleExportWith is HandleExport with the worker call passed in, so the job
// lifecycle can be exercised without a live Python subprocess.
func handleExportWith(ctx context.Context, params json.RawMessage,
	call func(context.Context, json.RawMessage) (json.RawMessage, error)) (json.RawMessage, error) {

	key := exportJobKey(params)
	job, fresh := beginExportJob(key)
	if fresh {
		// context.Background(), NOT ctx: the job outlives the call that
		// started it by design, and a request-scoped context would cancel the
		// export the moment this handler answers "running".
		go func() {
			job.result, job.err = call(context.Background(), params)
			close(job.done)
		}()
	}

	select {
	case <-job.done:
		return collectExportJob(key, job)
	case <-ctx.Done():
		return nil, &bridge.WorkerError{Kind: "cancelled", Message: ctx.Err().Error()}
	case <-time.After(exportFirstReply):
		return nil, exportRunningError(job)
	}
}

// exportJobKey names an export by what it would produce. Two calls with the
// same source, format and path are the same export, which is what lets a
// caller collect a running one by simply asking again.
func exportJobKey(params json.RawMessage) string {
	var a struct {
		Source string `json:"source"`
		Format string `json:"format"`
		Path   string `json:"path"`
	}
	sum := sha256.New()
	if err := json.Unmarshal(params, &a); err != nil {
		// Unparseable args are the worker's to refuse; key them verbatim so
		// two such calls still share one (fast) job.
		sum.Write(params)
	} else {
		fmt.Fprintf(sum, "%q\n%q\n%q\n", a.Source, a.Format, a.Path)
	}
	return hex.EncodeToString(sum.Sum(nil))
}

// beginExportJob returns the job for key, and whether it is new. An existing
// job — running or finished — is joined rather than started again, so a
// caller asking twice never sets a second copy of the same export going.
func beginExportJob(key string) (*exportJob, bool) {
	exportMu.Lock()
	defer exportMu.Unlock()
	sweepExportJobsLocked()
	if job, ok := exportJobs[key]; ok {
		return job, false
	}
	job := &exportJob{started: time.Now(), done: make(chan struct{})}
	exportJobs[key] = job
	return job, true
}

// collectExportJob hands back a finished job's answer and drops it from the
// table. An export is spent on collection: asking again writes the file
// again, which is what a caller who asks again means.
func collectExportJob(key string, job *exportJob) (json.RawMessage, error) {
	exportMu.Lock()
	if current, ok := exportJobs[key]; ok && current == job {
		delete(exportJobs, key)
	}
	exportMu.Unlock()
	return job.result, job.err
}

// exportRunningError is the answer for an export still being built. It is an
// error envelope, not a result: NOTHING has been written yet, and a reply
// shaped like a success would report a path with no file behind it.
func exportRunningError(job *exportJob) error {
	waited := time.Since(job.started)
	elapsed, _ := json.Marshal(waited.Milliseconds())
	return &bridge.WorkerError{
		Kind: "running",
		Message: fmt.Sprintf(
			"the export is still building after %.1f s — this source has not "+
				"been evaluated, so the whole DSL is being translated, which on "+
				"a large lofted shell is minutes of geometry. Nothing has been "+
				"written yet and nothing has failed: call cad.export again with "+
				"the same source, format and path to collect the file when it lands.",
			waited.Seconds()),
		Extra: map[string]json.RawMessage{
			"status":     json.RawMessage(`"running"`),
			"elapsed_ms": json.RawMessage(elapsed),
		},
	}
}

// sweepExportJobsLocked drops FINISHED jobs nobody collected. Caller holds
// exportMu. A job still running is kept however old it is: dropping it would
// let the next identical call set a second export of the same document going
// beside the first, which is the one thing this table exists to prevent.
func sweepExportJobsLocked() {
	now := time.Now()
	for key, job := range exportJobs {
		select {
		case <-job.done:
			if now.Sub(job.started) > exportJobKeep {
				delete(exportJobs, key)
			}
		default:
		}
	}
}
