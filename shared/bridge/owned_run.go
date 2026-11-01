package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"
)

// OwnedRetirementTimeout bounds an interruption's process and I/O retirement.
// Actual native CPU-stop latency still requires platform acceptance evidence.
const OwnedRetirementTimeout = 2 * time.Second

// StartOwned starts or reuses a worker whose identity remains owned until its
// process and I/O have retired. CAD uses this stricter lifecycle; the legacy
// Start/Call contract remains available to other consumers.
func (w *Worker) StartOwned(ctx context.Context) (uint64, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if run := w.run; run != nil {
		if run.retireErr != nil {
			return run.generation, run.retireErr
		}
		if run.retireC != nil && !channelClosed(run.retireC) {
			return run.generation, &WorkerError{Kind: "retirement_unverified", Message: "worker retirement is still in progress"}
		}
		if run.retiring || !w.isAliveLocked() {
			var exitErr *exec.ExitError
			if channelClosed(run.exitC) && run.waitErr != nil && !errors.As(run.waitErr, &exitErr) {
				run.retireErr = &WorkerError{Kind: "retirement_unverified", Message: fmt.Sprintf("reap worker: %v", run.waitErr), cause: run.waitErr}
				return run.generation, run.retireErr
			}
			if !runRetired(run) {
				return run.generation, &WorkerError{Kind: "retirement_unverified", Message: "previous worker still owns process or I/O resources"}
			}
			w.retiredGeneration = run.generation
			w.run = nil
		}
	}
	err := w.startModeLocked(ctx, true)
	if w.run == nil {
		return 0, err
	}
	return w.run.generation, err
}

// CallOwned sends only to the exact previously started generation. It never
// lazily spawns a worker after a cancellation or crash.
func (w *Worker) CallOwned(ctx context.Context, generation uint64, method string, params json.RawMessage) (json.RawMessage, error) {
	if generation == 0 {
		return nil, &WorkerError{Kind: "internal", Message: "missing owned worker generation"}
	}
	return w.call(ctx, generation, method, params)
}

func channelClosed(ch <-chan struct{}) bool {
	select {
	case <-ch:
		return true
	default:
		return false
	}
}

// runRetired requires Worker.mu. EOF alone is deliberately insufficient.
func runRetired(run *workerRun) bool {
	if !channelClosed(run.exitC) || !channelClosed(run.doneC) ||
		!channelClosed(run.stderrC) || run.writers != 0 {
		return false
	}
	var exitErr *exec.ExitError
	return run.waitErr == nil || errors.As(run.waitErr, &exitErr)
}

// OwnedRetired reports proof of retirement, including all pipe owners. An
// owner may disappear only after that proof on the owned lifecycle.
func (w *Worker) OwnedRetired(generation uint64) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.run != nil && w.run.generation == generation {
		return runRetired(w.run)
	}
	return generation != 0 && generation <= w.retiredGeneration
}

// ShutdownOwned verifies the same retirement proof during CAD server teardown;
// it never writes a shutdown frame behind native work on a blocked stdin.
func (w *Worker) ShutdownOwned(ctx context.Context) error {
	w.mu.Lock()
	run := w.run
	w.mu.Unlock()
	if run == nil {
		return nil
	}
	return w.RetireOwned(ctx, run.generation)
}

// RetireOwned fences one generation before signalling it directly. Closing
// its pipes wakes a blocked write without depending on Python's dispatcher.
// A failure retains the actual run and prevents StartOwned from replacing it.
func (w *Worker) RetireOwned(ctx context.Context, generation uint64) error {
	w.mu.Lock()
	run := w.run
	if run == nil || run.generation != generation {
		if generation != 0 && generation <= w.retiredGeneration {
			w.mu.Unlock()
			return nil
		}
		w.mu.Unlock()
		return &WorkerError{Kind: "interrupt_failed", Message: "target worker generation is no longer owned"}
	}
	if run.retireC != nil {
		done := run.retireC
		w.mu.Unlock()
		select {
		case <-done:
			w.mu.Lock()
			err := run.retireErr
			w.mu.Unlock()
			return err
		case <-ctx.Done():
			return &WorkerError{Kind: "retirement_unverified", Message: ctx.Err().Error(), cause: ctx.Err()}
		}
	}
	run.retiring = true
	run.retireC = make(chan struct{})
	if run.writers == 0 {
		close(run.writersC)
	}
	w.failInflightLocked(run, "cancelled", "worker generation interrupted")
	w.mu.Unlock()

	var retirementErr error
	if !channelClosed(run.exitC) {
		if err := terminateProcessGroup(run.cmd.Process, sigKill); err != nil && !errors.Is(err, os.ErrProcessDone) {
			retirementErr = fmt.Errorf("signal worker generation %d: %w", generation, err)
		}
	}
	for _, pipe := range []io.Closer{run.stdin, run.stdoutPipe, run.stderrPipe} {
		if err := pipe.Close(); err != nil && !errors.Is(err, os.ErrClosed) {
			retirementErr = errors.Join(retirementErr, fmt.Errorf("close worker pipe: %w", err))
		}
	}
	for _, done := range []<-chan struct{}{run.exitC, run.doneC, run.stderrC, run.writersC} {
		select {
		case <-done:
		case <-ctx.Done():
			retirementErr = errors.Join(retirementErr, fmt.Errorf("wait for worker process and I/O retirement: %w", ctx.Err()))
		}
	}
	w.mu.Lock()
	// ExitError describes the expected process termination. Other Wait errors
	// can describe a failure to reap or retire I/O and remain visible.
	var exitErr *exec.ExitError
	if run.waitErr != nil && !errors.As(run.waitErr, &exitErr) {
		retirementErr = errors.Join(retirementErr, fmt.Errorf("reap worker: %w", run.waitErr))
	}
	if retirementErr != nil {
		run.retireErr = &WorkerError{Kind: "retirement_unverified", Message: retirementErr.Error(), cause: retirementErr}
	}
	close(run.retireC)
	err := run.retireErr
	w.mu.Unlock()
	return err
}
