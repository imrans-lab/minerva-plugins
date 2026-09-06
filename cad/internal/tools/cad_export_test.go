package tools

import (
	"context"
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
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
	exportMu.Unlock()
}

func exportArgs(path string) json.RawMessage {
	return json.RawMessage(`{"source":"part = box(10,10,10)\n","format":"stl","path":"` + path + `"}`)
}

// assertRunning asserts the reply is the "still building" envelope: no result
// and a running error that says how long it has been going.
func assertRunning(t *testing.T, res json.RawMessage, err error) {
	t.Helper()
	if res != nil {
		t.Fatalf("a running export must write nothing and return no result; got %s", res)
	}
	we, ok := err.(*bridge.WorkerError)
	if !ok {
		t.Fatalf("expected a *bridge.WorkerError, got %T (%v)", err, err)
	}
	if we.Kind != "running" {
		t.Fatalf("expected kind=running, got kind=%q message=%q", we.Kind, we.Message)
	}
	if _, has := we.Extra["elapsed_ms"]; !has {
		t.Fatalf("a running reply must say how long it has been building; extra=%v", we.Extra)
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
}
