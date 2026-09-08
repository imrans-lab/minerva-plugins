package tools

import (
	"context"
	"encoding/json"
	"github.com/imrans-lab/minerva-plugins/shared/bridge"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// ORACLE for this file: the worker call counter. A heavy export must be asked
// for ONCE however many times the caller comes back for it, and the caller
// must be told "running" rather than made to wait — an implementation that
// dispatched afresh on every call (today's behaviour) shows up here as a
// second count, and one that blocked shows up as a first call that does not
// return until the export is released.

func resetExportJobs(t *testing.T) {
	t.Helper()
	exportMu.Lock()
	exportJobs = map[string]*exportJob{}
	exportHandles = map[string]*exportJob{}
	exportMu.Unlock()
}

func exportArgs(path string) json.RawMessage {
	return json.RawMessage(`{"source":"part = box(10,10,10)\n","format":"stl","path":"` + path + `"}`)
}

// Pending is data, with a durable handle, not a worker failure.
func assertRunning(t *testing.T, res json.RawMessage, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	var r map[string]any
	if err := json.Unmarshal(res, &r); err != nil {
		t.Fatal(err)
	}
	if r["status"] != "pending" || r["job_id"] == "" || r["elapsed_ms"] == nil {
		t.Fatalf("bad pending reply: %s", res)
	}
}

func TestExportRunsDetachedAndIsCollectedByAskingAgain(t *testing.T) {
	resetExportJobs(t)
	prior := exportFirstReply
	exportFirstReply = 40 * time.Millisecond
	defer func() { exportFirstReply = prior }()

	release := make(chan struct{})
	var calls int32
	slow := func(_ context.Context, _ json.RawMessage) (json.RawMessage, error) {
		atomic.AddInt32(&calls, 1)
		<-release
		return json.RawMessage(`{"path":"/tmp/heavy.stl","bytes_written":9,"format":"stl"}`), nil
	}

	args := exportArgs("/tmp/heavy.stl")
	ctx := context.Background()

	// A first call on a heavy export answers inside the window, not after the
	// export: the stdio loop this handler sits on serves the panel too.
	started := time.Now()
	res, err := handleExportWith(ctx, args, slow)
	if waited := time.Since(started); waited > 5*time.Second {
		t.Fatalf("the first call blocked for %s — the export was not detached", waited)
	}
	assertRunning(t, res, err)

	// Asking again while it builds joins the same job rather than starting a
	// second export of the same document.
	res, err = handleExportWith(ctx, args, slow)
	assertRunning(t, res, err)
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("the worker was asked %d times for one export; expected 1", got)
	}

	// Once it lands, the same call collects the file.
	close(release)
	exportFirstReply = 5 * time.Second
	res, err = handleExportWith(ctx, args, slow)
	if err != nil {
		t.Fatalf("collecting the finished export failed: %v", err)
	}
	var payload struct {
		Path         string `json:"path"`
		BytesWritten int    `json:"bytes_written"`
	}
	if uerr := json.Unmarshal(res, &payload); uerr != nil {
		t.Fatalf("collected result is not the worker's payload: %v (%s)", uerr, res)
	}
	if payload.Path != "/tmp/heavy.stl" || payload.BytesWritten != 9 {
		t.Fatalf("collected the wrong payload: %s", res)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("collection cost an extra worker call (%d total); the job was re-dispatched", got)
	}

	// The job is spent: a later ask is a fresh export, not a second copy of
	// the old answer.
	fast := func(_ context.Context, _ json.RawMessage) (json.RawMessage, error) {
		atomic.AddInt32(&calls, 1)
		return json.RawMessage(`{"path":"/tmp/heavy.stl","bytes_written":11,"format":"stl"}`), nil
	}
	if _, err = handleExportWith(ctx, args, fast); err != nil {
		t.Fatalf("re-exporting after collection failed: %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Fatalf("expected a fresh export after collection (2 calls), got %d", got)
	}
}

func TestExportJobKeyDistinguishesRequests(t *testing.T) {
	same := exportJobKey(exportArgs("/tmp/a.stl"))
	if same != exportJobKey(exportArgs("/tmp/a.stl")) {
		t.Fatal("the same export must key the same, or a caller asking again starts a second build")
	}
	if same == exportJobKey(exportArgs("/tmp/b.stl")) {
		t.Fatal("two paths must key apart, or one export collects the other's file")
	}
	if same == exportJobKey(json.RawMessage(`{"source":"part = box(11,10,10)\n","format":"stl","path":"/tmp/a.stl"}`)) {
		t.Fatal("two sources must key apart, or an edited document collects the old geometry")
	}
}

// An export that fails is handed to its collector as an error, not swallowed
// into a running reply that never settles.
func TestExportFailureReachesTheCaller(t *testing.T) {
	resetExportJobs(t)
	boom := func(_ context.Context, _ json.RawMessage) (json.RawMessage, error) {
		return nil, &bridge.WorkerError{Kind: "translate", Message: "no 3D part produced"}
	}
	res, err := handleExportWith(context.Background(), exportArgs("/tmp/bad.stl"), boom)
	if res != nil {
		t.Fatalf("a failed export must return no result; got %s", res)
	}
	we, ok := err.(*bridge.WorkerError)
	if !ok || we.Kind != "translate" {
		t.Fatalf("expected the worker's translate error, got %v", err)
	}
	var id string
	if err := json.Unmarshal(we.Extra["job_id"], &id); err != nil {
		t.Fatal(err)
	}
	poll, _ := json.Marshal(map[string]any{"job_id": id})
	_, again := handleExportWith(context.Background(), poll, boom)
	if saved, ok := again.(*bridge.WorkerError); !ok || saved.Kind != "translate" {
		t.Fatalf("failure did not remain collectable: %v", again)
	}
	exportMu.Lock()
	exportHandles[id].finished = time.Now().Add(-exportJobKeep - time.Second)
	exportMu.Unlock()
	_, expired := handleExportWith(context.Background(), poll, boom)
	if refusal, ok := expired.(*bridge.WorkerError); !ok || refusal.Kind != "unknown_job" {
		t.Fatalf("expired handle reused: %v", expired)
	}
}

func TestExportHandleCollectionIsStable(t *testing.T) {
	resetExportJobs(t)
	release := make(chan struct{})
	calls := 0
	slow := func(_ context.Context, _ json.RawMessage) (json.RawMessage, error) {
		calls++
		<-release
		return json.RawMessage(`{"path":"/tmp/job.stl","bytes_written":12}`), nil
	}
	args := json.RawMessage(`{"source":"a=cube(2)\n","part":"a","format":"stl","path":"/tmp/job.stl","source_version":4,"wait_ms":0}`)
	pending, err := handleExportWith(context.Background(), args, slow)
	assertRunning(t, pending, err)
	var r map[string]any
	json.Unmarshal(pending, &r)
	poll, _ := json.Marshal(map[string]any{"job_id": r["job_id"], "wait_ms": 0})
	pending, err = handleExportWith(context.Background(), poll, slow)
	assertRunning(t, pending, err)
	close(release)
	collect, _ := json.Marshal(map[string]any{"job_id": r["job_id"], "wait_ms": 20000})
	first, err := handleExportWith(context.Background(), collect, slow)
	if err != nil {
		t.Fatal(err)
	}
	second, err := handleExportWith(context.Background(), poll, slow)
	if err != nil || string(first) != string(second) || calls != 1 {
		t.Fatalf("collection changed or rewrote: %s %s %v calls=%d", first, second, err, calls)
	}
	_, err = handleExportWith(context.Background(), json.RawMessage(`{"job_id":"absent"}`), slow)
	if err == nil {
		t.Fatal("unknown handle accepted")
	}
}

// ORACLE for the wait_ms cases below: the handler's OUTCOME CLASS for a given
// raw argument, which is observable without knowing how the argument is
// parsed. An accepted wait_ms yields no error and a reply carrying a job_id
// (pending or completed — both mean the export was dispatched); a refused one
// yields a WorkerError that names wait_ms and quotes the offending value, and
// leaves the worker uncalled. The inputs are the raw request bytes, in both
// the integer and the float spelling of the same value, because the host
// re-serializes arguments through a float-only JSON parser and either
// spelling can arrive on the wire.
func TestExportWaitMSAcceptsHostNumberSpellings(t *testing.T) {
	cases := []struct {
		name    string
		waitMS  string
		accept  bool
		mustSay string
	}{
		{name: "integer zero", waitMS: `0`, accept: true},
		{name: "float zero as the host spells it", waitMS: `0.0`, accept: true},
		{name: "negative zero", waitMS: `-0.0`, accept: true},
		{name: "float upper bound", waitMS: `20000.0`, accept: true},
		{name: "exponent spelling", waitMS: `1e3`, accept: true},
		{name: "null is absent", waitMS: `null`, accept: true},
		{name: "fractional", waitMS: `0.5`, accept: false, mustSay: "0.5"},
		{name: "negative", waitMS: `-1`, accept: false, mustSay: "-1"},
		{name: "above the bound", waitMS: `20001`, accept: false, mustSay: "20001"},
		{name: "above the bound as a float", waitMS: `20000.5`, accept: false, mustSay: "20000.5"},
		{name: "quoted number is not a number", waitMS: `"0"`, accept: false, mustSay: "number"},
		{name: "boolean", waitMS: `true`, accept: false, mustSay: "number"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resetExportJobs(t)
			prior := exportFirstReply
			exportFirstReply = 40 * time.Millisecond
			defer func() { exportFirstReply = prior }()

			var calls int32
			done := func(_ context.Context, _ json.RawMessage) (json.RawMessage, error) {
				atomic.AddInt32(&calls, 1)
				return json.RawMessage(`{"path":"/tmp/w.stl","bytes_written":4,"format":"stl"}`), nil
			}
			args := json.RawMessage(`{"source":"part = box(1,1,1)\n","format":"stl","path":"/tmp/` +
				tc.name + `.stl","wait_ms":` + tc.waitMS + `}`)

			res, err := handleExportWith(context.Background(), args, done)
			if !tc.accept {
				we, ok := err.(*bridge.WorkerError)
				if !ok {
					t.Fatalf("wait_ms %s was accepted (result %s, err %v); expected a refusal", tc.waitMS, res, err)
				}
				if !strings.Contains(we.Message, "wait_ms") || !strings.Contains(we.Message, tc.mustSay) {
					t.Fatalf("refusal of wait_ms %s is not descriptive: %q", tc.waitMS, we.Message)
				}
				if strings.Contains(we.Message, "invalid export arguments") {
					t.Fatalf("wait_ms %s got the opaque catch-all message", tc.waitMS)
				}
				if got := atomic.LoadInt32(&calls); got != 0 {
					t.Fatalf("a refused wait_ms still dispatched %d export(s)", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("wait_ms %s was refused: %v", tc.waitMS, err)
			}
			var r map[string]any
			if uerr := json.Unmarshal(res, &r); uerr != nil {
				t.Fatalf("wait_ms %s: reply is not an object: %v (%s)", tc.waitMS, uerr, res)
			}
			if id, _ := r["job_id"].(string); id == "" {
				t.Fatalf("wait_ms %s: reply carries no job handle: %s", tc.waitMS, res)
			}
		})
	}
}

// Both spellings of one source_version name the SAME export, so a caller who
// asks again while it builds joins the running job instead of starting a
// second copy of it — and two different versions still key apart.
func TestExportJobKeyNormalizesSourceVersionSpelling(t *testing.T) {
	body := `{"source":"a=cube(2)\n","format":"stl","path":"/tmp/v.stl","source_version":`
	asInt := exportJobKey(json.RawMessage(body + `4}`))
	asFloat := exportJobKey(json.RawMessage(body + `4.0}`))
	if asInt != asFloat {
		t.Fatal("4 and 4.0 keyed apart; the host's float spelling would start a second export")
	}
	if asInt == exportJobKey(json.RawMessage(body+`5}`)) {
		t.Fatal("two source versions must key apart, or one export collects the other's geometry")
	}
}

// A float wait_ms on the collection path bounds the wait like its integer
// twin: the handle stays collectable and the result is the worker's payload.
func TestExportCollectionAcceptsFloatWaitMS(t *testing.T) {
	resetExportJobs(t)
	release := make(chan struct{})
	var calls int32
	slow := func(_ context.Context, _ json.RawMessage) (json.RawMessage, error) {
		atomic.AddInt32(&calls, 1)
		<-release
		return json.RawMessage(`{"path":"/tmp/float.stl","bytes_written":7}`), nil
	}
	start := json.RawMessage(`{"source":"a=cube(3)\n","format":"stl","path":"/tmp/float.stl","wait_ms":0.0}`)
	pending, err := handleExportWith(context.Background(), start, slow)
	assertRunning(t, pending, err)

	var r map[string]any
	if uerr := json.Unmarshal(pending, &r); uerr != nil {
		t.Fatal(uerr)
	}
	poll := json.RawMessage(`{"job_id":"` + r["job_id"].(string) + `","wait_ms":0.0}`)
	polled, perr := handleExportWith(context.Background(), poll, slow)
	assertRunning(t, polled, perr)

	close(release)
	collect := json.RawMessage(`{"job_id":"` + r["job_id"].(string) + `","wait_ms":20000.0}`)
	res, err := handleExportWith(context.Background(), collect, slow)
	if err != nil {
		t.Fatalf("collecting with a float wait_ms failed: %v", err)
	}
	var payload struct {
		BytesWritten int    `json:"bytes_written"`
		Status       string `json:"status"`
	}
	if uerr := json.Unmarshal(res, &payload); uerr != nil {
		t.Fatal(uerr)
	}
	if payload.BytesWritten != 7 || payload.Status != "completed" {
		t.Fatalf("collected the wrong payload: %s", res)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("the export ran %d times; float wait_ms broke job joining", got)
	}
}
