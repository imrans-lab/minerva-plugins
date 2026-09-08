// worker_lifetime_test.go — the worker subprocess must outlive any single
// cad.evaluate.
//
// The panel's close-and-reopen of the paired .mcad tabs lands as: one
// cad.evaluate carrying a request_id ends (cancelled by the closing panel, or
// simply finished), then the reopened panel issues a fresh cad.evaluate. The
// second one must come back with a real verdict — never kind=crashed.
//
// These tests drive handleToolsCall against a stub worker written in Python,
// so the real bridge process lifetime (spawn, stdin/stdout framing, kill on
// context cancellation) is exercised without OCCT. They SKIP when no python3
// is on PATH.

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// stubWorkerSource is a minimal mcad_worker that speaks the bridge framing
// protocol. A request-start notification and release file let the test cancel
// an evaluation while it is actually executing. stub_fail=true
// yields a python error naming the shape, exactly like a failing source.
const stubWorkerSource = `
import json, os, sys, time
from pathlib import Path

def read_frame():
    length = -1
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.rstrip(b"\r\n")
        if line == b"":
            break
        name, _, value = line.partition(b": ")
        if name.lower() == b"content-length":
            length = int(value)
    if length < 0:
        return None
    return json.loads(sys.stdin.buffer.read(length))

def write_frame(obj):
    body = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(
        b"Content-Length: %d\r\nContent-Type: application/json; charset=utf-8\r\n\r\n"
        % len(body)
    )
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()

# Deliberately cold startup: longer than the old test's 150 ms cancel timer.
time.sleep(0.25)
write_frame({"method": "worker.ready", "params": {}})

while True:
    req = read_frame()
    if req is None:
        break
    if req.get("method") == "shutdown":
        write_frame({"id": req["id"], "ok": True, "result": {}})
        break
    params = req.get("params") or {}
    gate = os.environ.get("STUB_RELEASE_FILE")
    if gate and params.get("request_id") != "eval_reopened":
        print("stub.request_started", file=sys.stderr, flush=True)
        deadline = time.monotonic() + 15
        while not Path(gate).exists():
            if time.monotonic() > deadline:
                raise RuntimeError("test did not release evaluation")
            time.sleep(0.01)
    if params.get("stub_fail"):
        write_frame({"id": req["id"], "ok": False, "error": {
            "kind": "python",
            "message": "'NoneType' object has no attribute 'NbNodes' while tessellating 'shell'",
        }})
    else:
        write_frame({"id": req["id"], "ok": True, "result": {"shape_name": "shell"}})
`

// useStubWorker points the package-level worker and registry at a stub python
// worker in a temp dir and restores them afterwards.
func useStubWorker(t *testing.T) {
	t.Helper()

	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 not on PATH — stub worker unavailable")
	}

	// `python -m mcad_worker` with cmd.Dir = workerDir (bridge dev mode) puts
	// the module on sys.path via the cwd, so a package dir is all it takes.
	dir := t.TempDir()
	pkg := filepath.Join(dir, workerModule)
	if err := os.MkdirAll(pkg, 0o755); err != nil {
		t.Fatalf("mkdir stub worker package: %v", err)
	}
	if err := os.WriteFile(filepath.Join(pkg, "__init__.py"), nil, 0o644); err != nil {
		t.Fatalf("write stub __init__.py: %v", err)
	}
	if err := os.WriteFile(filepath.Join(pkg, "__main__.py"), []byte(stubWorkerSource), 0o644); err != nil {
		t.Fatalf("write stub __main__.py: %v", err)
	}

	prevWorker, prevRegistry := worker, registry
	initRegistry()
	worker = bridge.New(python, dir, workerModule)
	t.Cleanup(func() {
		worker.Shutdown(workerShutdownTimeout)
		worker, registry = prevWorker, prevRegistry
	})
}

// callEvaluate drives one cad.evaluate through the real MCP entry point and
// returns the {ok, result|error} envelope the panel would decode.
func callEvaluate(t *testing.T, requestID string, fail bool) (ok bool, kind string) {
	t.Helper()

	args := map[string]interface{}{
		"source":     "shell = box(10, 10, 10)",
		"request_id": requestID,
		"stub_fail":  fail,
	}
	argsJSON, err := json.Marshal(args)
	if err != nil {
		t.Fatalf("marshal args: %v", err)
	}
	params, err := json.Marshal(map[string]interface{}{
		"name":      "cad.evaluate",
		"arguments": json.RawMessage(argsJSON),
	})
	if err != nil {
		t.Fatalf("marshal params: %v", err)
	}

	resp := handleToolsCall(json.RawMessage(`1`), params)
	return decodeEnvelope(t, resp)
}

// decodeEnvelope pulls {ok, error.kind} out of an MCP tool result.
func decodeEnvelope(t *testing.T, resp rpcResponse) (bool, string) {
	t.Helper()

	raw, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal response: %v", err)
	}
	var shape struct {
		Error  *struct{ Message string } `json:"error"`
		Result struct {
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
		} `json:"result"`
	}
	if err := json.Unmarshal(raw, &shape); err != nil {
		t.Fatalf("unmarshal response: %v\nraw: %s", err, raw)
	}
	if shape.Error != nil {
		t.Fatalf("cad.evaluate returned an MCP protocol error: %s", shape.Error.Message)
	}
	if len(shape.Result.Content) == 0 {
		t.Fatalf("cad.evaluate returned no content: %s", raw)
	}
	var envelope struct {
		OK    bool `json:"ok"`
		Error *struct {
			Kind    string `json:"kind"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(shape.Result.Content[0].Text), &envelope); err != nil {
		t.Fatalf("unmarshal worker envelope: %v\nraw: %s", err, shape.Result.Content[0].Text)
	}
	if envelope.Error != nil {
		return envelope.OK, envelope.Error.Kind
	}
	return envelope.OK, ""
}

// TestReopenAfterInflightEvalIsNotCrashed is the acceptance test for the
// close-and-reopen bug: whatever ends the previous panel's evaluate, the
// reopened panel's FIRST evaluate must answer ok or with a worker verdict —
// never kind=crashed / "worker stdout closed unexpectedly".
//
// Both endings the panel can produce are covered: an evaluate cancelled
// mid-flight (cad.cancel_eval, as the closing panel emits) and one that simply
// runs to completion. Cancellation waits until the worker is genuinely busy.
func TestReopenAfterInflightEvalIsNotCrashed(t *testing.T) {
	if testing.Short() {
		t.Skip("spawns a worker subprocess; -short")
	}

	cases := []struct {
		name            string
		cancelMidflight bool
		fail            bool
	}{
		// The reported reproduction: a failing source, panel closed while it runs.
		{name: "cancelled_failing_eval", cancelMidflight: true, fail: true},
		// The same close against a source that is merely slow.
		{name: "cancelled_slow_eval", cancelMidflight: true, fail: false},
		// The panel closed just after the eval landed — no cancel is emitted,
		// but the request's context is released all the same.
		{name: "completed_eval", cancelMidflight: false, fail: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			useStubWorker(t)
			resetInflight(t)

			requestID := fmt.Sprintf("eval_%s", tc.name)
			release := func() {}
			cancelDone := make(chan struct{})
			if tc.cancelMidflight {
				gate := filepath.Join(t.TempDir(), "release")
				release = func() {
					if err := os.WriteFile(gate, nil, 0o600); err != nil {
						t.Errorf("release stub evaluation: %v", err)
					}
				}
				t.Cleanup(release)
				worker.ExtraEnv = []string{"STUB_RELEASE_FILE=" + gate}
				started := make(chan struct{}, 1)
				worker.StderrCallback = func(line string) {
					if line == "stub.request_started" {
						started <- struct{}{}
					}
				}
				// Drive the panel close concurrently with evaluation. The worker
				// cannot reply until we have observed cancellation and release it.
				go func() {
					defer close(cancelDone)
					select {
					case <-started:
						args, _ := json.Marshal(map[string]string{"request_id": requestID})
						handleCancelEval(json.RawMessage(`2`), args)
					case <-time.After(10 * time.Second):
						t.Error("worker did not start evaluation before watchdog expired")
					}
				}()
			} else {
				close(cancelDone)
			}

			firstOK, firstKind := callEvaluate(t, requestID, tc.fail)
			<-cancelDone
			release()
			if tc.cancelMidflight && firstKind != "cancelled" {
				t.Fatalf("first eval: want kind=cancelled after cad.cancel_eval, got ok=%v kind=%q", firstOK, firstKind)
			}

			// The reopened panel's FIRST evaluate, issued immediately after.
			secondOK, secondKind := callEvaluate(t, "eval_reopened", false)
			if secondKind == "crashed" {
				t.Fatalf("reopened panel's first eval crashed (%q) — the worker was killed with the previous request", secondKind)
			}
			if !secondOK {
				t.Fatalf("reopened panel's first eval: want ok, got kind=%q", secondKind)
			}
		})
	}
}
