// Package tools — cad.export tool registration and handler.
//
// Export the last 3D part produced by .mcad source to a file.
// Format is one of: "stl" (binary), "step"/"stp" (AP214), "3mf", "glb".
//
// Like cad.evaluate, the MCP tool name is the dotted "cad.export" (which is
// also the IPC channel name). The worker method is the bare verb "export"
// — see worker/mcad_worker/methods.py:_export.
//
// Exports run detached and are collected by job_id; legacy repeated requests
// still join the same in-flight job. Completed handles are stable for 15 minutes.
package tools

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// Export is the MCP tool spec for cad.export.
var Export = ToolSpec{
	Name: "cad.export",
	Description: "Export .mcad source, optionally a named solid binding. Formats: stl, step, stp, 3mf, glb. " +
		"Returns path, bytes_written, reused_evaluation, source_digest and source_version. " +
		"Slow work returns status=pending and job_id without error. Collect with job_id only; " +
		"wait_ms (0..20000) bounds waiting. Handles retain completed or failed results for 15 minutes; " +
		"repeated collection never rebuilds or rewrites. Source, part, format and path are pinned at start. " +
		"Legacy repeated source/format/path requests join an in-flight export. Paths resolve against home.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"source": {"type": "string"},
			"part": {"type": "string", "description": "Optional named solid binding; excludes references."},
			"source_version": {"type": "integer"},
			"document_id": {"type": "string"},
			"evaluation_provenance": {"type": "object"},
			"format": {"type": "string", "enum": ["stl", "step", "stp", "3mf", "glb"]},
			"path": {"type": "string"},
			"job_id": {"type": "string", "description": "Collect a previous export without resending source."},
			"wait_ms": {"type": "integer", "minimum": 0, "maximum": 20000}
		},
		"anyOf": [{"required": ["job_id"]}, {"required": ["source", "format", "path"]}]
	}`),
}

// exportFirstReply is how long the verb waits for an export before answering
// pending. A variable, not a constant, so a test can drive the handover
// without spending the window waiting for it; nothing in the plugin writes it.
var exportFirstReply = 20 * time.Second

// exportJobKeep is how long a finished export stays collectable. Far longer
// than any export, so only a job nobody came back for is ever swept.
const exportJobKeep = 15 * time.Minute

// exportJob is one detached export. done is closed when the worker has
// answered; result/err are then final and can be read by repeated collectors.
type exportJob struct {
	id       string
	key      string
	started  time.Time
	finished time.Time
	done     chan struct{}
	result   json.RawMessage
	err      error
}

var (
	exportMu       sync.Mutex
	exportJobs     = map[string]*exportJob{}
	exportHandles  = map[string]*exportJob{}
	exportSequence atomic.Uint64
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

	var args struct {
		JobID  string          `json:"job_id"`
		WaitMS json.RawMessage `json:"wait_ms"`
	}
	if err := json.Unmarshal(params, &args); err != nil {
		return nil, &bridge.WorkerError{Kind: "internal", Message: "invalid export arguments"}
	}
	wait := exportFirstReply
	if !jsonAbsent(args.WaitMS) {
		// jsonInt, not a Go int field: the host may spell an integer 0 as 0.0.
		ms, err := jsonInt(args.WaitMS)
		if err != nil {
			return nil, &bridge.WorkerError{Kind: "internal",
				Message: "wait_ms " + err.Error() + "; expected 0..20000 milliseconds, got " + string(args.WaitMS)}
		}
		if ms < 0 || ms > 20000 {
			return nil, &bridge.WorkerError{Kind: "internal",
				Message: "wait_ms must be 0..20000 milliseconds; got " + string(args.WaitMS)}
		}
		wait = time.Duration(ms) * time.Millisecond
	}
	var job *exportJob
	if args.JobID != "" {
		exportMu.Lock()
		sweepExportJobsLocked()
		job = exportHandles[args.JobID]
		exportMu.Unlock()
		if job == nil {
			return nil, &bridge.WorkerError{Kind: "unknown_job", Message: "unknown or expired export job"}
		}
	} else {
		key := exportJobKey(params)
		var fresh bool
		job, fresh = beginExportJob(key)
		if fresh {
			pinned := append(json.RawMessage(nil), params...)
			go func() {
				job.result, job.err = call(context.Background(), pinned)
				job.finished = time.Now()
				close(job.done)
			}()
		}
	}
	// A completed handle always wins over a zero-duration polling timer.
	select {
	case <-job.done:
		return collectExportJob(job.key, job)
	default:
	}
	select {
	case <-job.done:
		return collectExportJob(job.key, job)
	case <-ctx.Done():
		return nil, &bridge.WorkerError{Kind: "cancelled", Message: ctx.Err().Error()}
	case <-time.After(wait):
		return json.Marshal(map[string]any{"status": "pending", "job_id": job.id,
			"elapsed_ms": time.Since(job.started).Milliseconds()})
	}
}

// exportJobKey names an export by what it would produce. Two calls with the
// same source, format and path are the same export, which is what lets a
// caller collect a running one by simply asking again.
func exportJobKey(params json.RawMessage) string {
	var a struct {
		Source     string          `json:"source"`
		Part       string          `json:"part"`
		Version    json.RawMessage `json:"source_version"`
		Document   string          `json:"document_id"`
		Evaluation map[string]any  `json:"evaluation_provenance"`
		Format     string          `json:"format"`
		Path       string          `json:"path"`
	}
	sum := sha256.New()
	if err := json.Unmarshal(params, &a); err != nil {
		// Unparseable args are the worker's to refuse; key them verbatim so
		// two such calls still share one (fast) job.
		sum.Write(params)
	} else {
		// source_version is normalized rather than hashed as written, so the
		// host's 4 and 4.0 spellings of one version name the same export.
		keyed := struct {
			Source     string         `json:"source"`
			Part       string         `json:"part"`
			Version    *int64         `json:"source_version"`
			Document   string         `json:"document_id"`
			Evaluation map[string]any `json:"evaluation_provenance"`
			Format     string         `json:"format"`
			Path       string         `json:"path"`
		}{Source: a.Source, Part: a.Part, Format: a.Format, Path: a.Path, Document: a.Document, Evaluation: a.Evaluation}
		if !jsonAbsent(a.Version) {
			if v, err := jsonInt(a.Version); err == nil {
				keyed.Version = &v
			} else {
				// Not a version the worker will accept either; keep the
				// verbatim text in the key so the bad request still joins
				// itself rather than colliding with a valid one.
				sum.Write(a.Version)
			}
		}
		encoded, _ := json.Marshal(keyed)
		sum.Write(encoded)
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
	job := &exportJob{id: fmt.Sprintf("export-%d-%d", time.Now().UnixNano(), exportSequence.Add(1)), key: key, started: time.Now(), done: make(chan struct{})}
	exportHandles[job.id] = job
	exportJobs[key] = job
	return job, true
}

// Collection releases the legacy request key so another start can write again.
// The handle keeps the immutable result until expiry, without another write.
func collectExportJob(key string, job *exportJob) (json.RawMessage, error) {
	exportMu.Lock()
	if current, ok := exportJobs[key]; ok && current == job {
		delete(exportJobs, key)
	}
	exportMu.Unlock()
	if job.err != nil {
		if we, ok := job.err.(*bridge.WorkerError); ok {
			copyError := *we
			copyError.Extra = map[string]json.RawMessage{}
			for k, v := range we.Extra {
				copyError.Extra[k] = v
			}
			copyError.Extra["job_id"], _ = json.Marshal(job.id)
			copyError.Extra["status"] = json.RawMessage(`"failed"`)
			return nil, &copyError
		}
		return nil, job.err
	}
	var result map[string]any
	if err := json.Unmarshal(job.result, &result); err != nil {
		return nil, err
	}
	result["job_id"] = job.id
	result["status"] = "completed"
	return json.Marshal(result)
}

// sweepExportJobsLocked drops FINISHED jobs nobody collected. Caller holds
// exportMu. A job still running is kept however old it is: dropping it would
// let the next identical call set a second export of the same document going
// beside the first, which is the one thing this table exists to prevent.
func sweepExportJobsLocked() {
	now := time.Now()
	for id, job := range exportHandles {
		select {
		case <-job.done:
			if now.Sub(job.finished) > exportJobKeep {
				delete(exportHandles, id)
				if exportJobs[job.key] == job {
					delete(exportJobs, job.key)
				}
			}
		default:
		}
	}
}
