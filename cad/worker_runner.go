package main

import (
	"context"
	"encoding/json"
	"errors"
	"sync"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

const (
	maxWorkerTasks = 16
	maxWorkerBytes = 32 << 20
)

type workerReply struct {
	result json.RawMessage
	err    error
}

type workerTask struct {
	ctx          context.Context
	method       string
	params       json.RawMessage
	reply        chan workerReply
	epoch        uint64
	generation   uint64
	interruption *workerInterruption
	ticket       *workerTicket
}

type workerInterruption struct {
	nativeDone    chan struct{}
	done          chan struct{}
	generation    uint64
	replacement   uint64
	nativeStopped bool
	state         string
	err           error
}

// workerRunner is the sole caller/writer of the bridge. Caller cancellation
// abandons its reply, but only actual native completion releases the slot.
// The process lifetime also covers lazy startup and bridge crash recovery.
type workerRunner struct {
	ctx          context.Context
	worker       *bridge.Worker
	queue        chan *workerTask
	done         chan struct{}
	mu           sync.Mutex
	stopped      bool
	count, bytes int
	epoch        uint64
	active       *workerTask
	failure      error
}

func newWorkerRunner(ctx context.Context, worker *bridge.Worker) *workerRunner {
	r := &workerRunner{ctx: ctx, worker: worker, queue: make(chan *workerTask, maxWorkerTasks), done: make(chan struct{}), epoch: 1}
	go r.run()
	return r
}

func cancelledError(err error) *bridge.WorkerError {
	return &bridge.WorkerError{Kind: "cancelled", Message: err.Error()}
}

// workerTicket owns one reservation until Call transfers it to the pump.
// Ownership and release share the runner mutex with ordinary admission.
type workerTicket struct {
	runner    *workerRunner
	bytes     int
	owned     bool
	epoch     uint64
	completed bool
}

// A request captures its epoch on admission, including detached exports whose
// worker call is scheduled later with a background context.
type epochCaller struct {
	runner *workerRunner
	epoch  uint64
}

func (r *workerRunner) caller() epochCaller {
	r.mu.Lock()
	defer r.mu.Unlock()
	return epochCaller{runner: r, epoch: r.epoch}
}

func (c epochCaller) Call(ctx context.Context, method string, params json.RawMessage) (json.RawMessage, error) {
	ticket, err := c.runner.reserveEpoch(ctx, len(params), c.epoch)
	if err != nil {
		return nil, err
	}
	return ticket.Call(ctx, method, params)
}

func (r *workerRunner) reserve(ctx context.Context, inputBytes int) (*workerTicket, error) {
	return r.reserveEpoch(ctx, inputBytes, 0)
}

func (r *workerRunner) reserveEpoch(ctx context.Context, inputBytes int, epoch uint64) (*workerTicket, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, cancelledError(err)
	}
	if r.stopped || r.ctx.Err() != nil {
		return nil, cancelledError(context.Canceled)
	}
	if r.failure != nil {
		return nil, r.failure
	}
	if epoch != 0 && epoch != r.epoch {
		return nil, cancelledError(context.Canceled)
	}
	if r.count >= maxWorkerTasks || inputBytes > maxWorkerBytes-r.bytes {
		return nil, &bridge.WorkerError{Kind: "busy", Message: "CAD worker queue capacity reached; retry later"}
	}
	r.count++
	r.bytes += inputBytes
	return &workerTicket{runner: r, bytes: inputBytes, owned: true, epoch: r.epoch}, nil
}

func (t *workerTicket) bindEpoch() {
	t.runner.mu.Lock()
	t.epoch = t.runner.epoch
	t.runner.mu.Unlock()
}

func (t *workerTicket) releaseUnused() {
	r := t.runner
	r.mu.Lock()
	defer r.mu.Unlock()
	if t.owned {
		t.owned = false
		r.count--
		r.bytes -= t.bytes
	}
}

func (r *workerRunner) Call(ctx context.Context, method string, params json.RawMessage) (json.RawMessage, error) {
	ticket, err := r.reserve(ctx, len(params))
	if err != nil {
		return nil, err
	}
	return ticket.Call(ctx, method, params)
}

func (t *workerTicket) Call(ctx context.Context, method string, params json.RawMessage) (json.RawMessage, error) {
	defer t.releaseUnused()
	r := t.runner
	r.mu.Lock()
	if !t.owned {
		r.mu.Unlock()
		return nil, &bridge.WorkerError{Kind: "internal", Message: "CAD worker reservation already consumed"}
	}
	if err := ctx.Err(); err != nil {
		r.mu.Unlock()
		return nil, cancelledError(err)
	}
	if r.stopped || r.ctx.Err() != nil {
		r.mu.Unlock()
		return nil, cancelledError(context.Canceled)
	}
	if t.epoch != r.epoch {
		r.mu.Unlock()
		return nil, cancelledError(context.Canceled)
	}
	if r.failure != nil {
		r.mu.Unlock()
		return nil, r.failure
	}
	if len(params) != t.bytes {
		r.mu.Unlock()
		return nil, &bridge.WorkerError{Kind: "internal", Message: "CAD worker arguments changed after reservation"}
	}
	task := &workerTask{ctx: ctx, method: method, params: append(json.RawMessage(nil), params...), reply: make(chan workerReply, 1), epoch: t.epoch, ticket: t}
	// Capacity counts reservations, active and queued work, so send cannot block.
	// From this point only the pump releases the reservation, even if ctx ends.
	t.owned = false
	r.queue <- task
	r.mu.Unlock()

	select {
	case <-ctx.Done():
		return nil, cancelledError(ctx.Err())
	case <-r.ctx.Done():
		return nil, cancelledError(r.ctx.Err())
	case reply := <-task.reply:
		// Cancellation wins even when native completion was simultaneously ready.
		if err := ctx.Err(); err != nil {
			return nil, cancelledError(err)
		}
		return reply.result, reply.err
	}
}

func (r *workerRunner) release(task *workerTask) {
	r.mu.Lock()
	r.releaseLocked(task)
	r.mu.Unlock()
}

func (r *workerRunner) releaseLocked(task *workerTask) {
	task.ticket.completed = true
	r.count--
	r.bytes -= len(task.params)
	task.params = nil
}

// cancelEvaluation linearizes the fence while the control request is admitted.
// Startup and unrelated active methods never qualify for native interruption.
func (r *workerRunner) cancelEvaluation(ctx context.Context, ticket *workerTicket) (*workerInterruption, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if ticket != nil && ticket.completed {
		return nil, false
	}
	queuedCount := len(r.queue)
queuedScan:
	for i := 0; i < queuedCount; i++ {
		var queued *workerTask
		select {
		case queued = <-r.queue:
		default:
			break queuedScan
		}
		if queued.ctx == ctx && queued.method == "evaluate" {
			queued.reply <- workerReply{err: cancelledError(context.Canceled)}
			r.releaseLocked(queued)
		} else {
			r.queue <- queued
		}
	}
	task := r.active
	if task == nil || task.ctx != ctx || task.method != "evaluate" || task.generation == 0 {
		return nil, true
	}
	if task.interruption != nil {
		return task.interruption, true
	}
	stop := &workerInterruption{generation: task.generation, nativeDone: make(chan struct{}), done: make(chan struct{}), state: "retiring"}
	task.interruption = stop
	r.epoch++
	for {
		select {
		case queued := <-r.queue:
			queued.reply <- workerReply{err: cancelledError(context.Canceled)}
			r.releaseLocked(queued)
		default:
			go r.recoverWorker(stop)
			return stop, true
		}
	}
}

func (r *workerRunner) recoverWorker(stop *workerInterruption) {
	ctx, cancel := context.WithTimeout(r.ctx, bridge.OwnedRetirementTimeout)
	err := r.worker.RetireOwned(ctx, stop.generation)
	cancel()
	r.mu.Lock()
	stop.nativeStopped = r.worker.OwnedRetired(stop.generation)
	stop.err = err
	if err != nil {
		stop.state = "failed"
		r.failure = err
	} else {
		stop.state = "recovering"
	}
	close(stop.nativeDone)
	r.mu.Unlock()
	if err == nil {
		generation, startErr := r.worker.StartOwned(r.ctx)
		r.mu.Lock()
		stop.replacement, stop.err = generation, startErr
		if startErr != nil {
			stop.state = "failed"
			r.failure = &bridge.WorkerError{Kind: "recovery_failed", Message: startErr.Error()}
		} else {
			stop.state = "ready"
		}
		r.mu.Unlock()
	}
	close(stop.done)
}

func (r *workerRunner) interruptionResult(stop *workerInterruption) map[string]interface{} {
	if stop == nil {
		return map[string]interface{}{"native_stopped": false, "worker_state": "unchanged"}
	}
	<-stop.done
	r.mu.Lock()
	defer r.mu.Unlock()
	result := map[string]interface{}{"native_stopped": stop.nativeStopped,
		"worker_state": stop.state, "process_epoch": stop.generation, "replacement_epoch": stop.replacement}
	if stop.err != nil {
		kind := "recovery_failed"
		var workerErr *bridge.WorkerError
		if errors.As(stop.err, &workerErr) {
			kind = workerErr.Kind
		}
		result["error"] = map[string]string{"kind": kind, "message": stop.err.Error()}
	}
	return result
}

func (r *workerRunner) run() {
	defer close(r.done)
	defer func() {
		r.mu.Lock()
		r.stopped = true
		r.mu.Unlock()
		for {
			select {
			case task := <-r.queue:
				r.release(task)
			default:
				return
			}
		}
	}()
	for {
		select {
		case <-r.ctx.Done():
			return
		case task := <-r.queue:
			if r.ctx.Err() != nil {
				r.release(task)
				return
			}
			if task.ctx.Err() != nil {
				r.release(task)
				continue
			}
			r.mu.Lock()
			if task.epoch != r.epoch || r.failure != nil {
				err := r.failure
				if err == nil {
					err = cancelledError(context.Canceled)
				}
				task.reply <- workerReply{err: err}
				r.releaseLocked(task)
				r.mu.Unlock()
				continue
			}
			r.active = task
			r.mu.Unlock()
			var reply workerReply
			holdReservation := false
			var generation uint64
			if r.worker == nil {
				reply.err = &bridge.WorkerError{Kind: "internal", Message: "CAD worker is unavailable"}
			} else {
				// Never pass the request context: bridge cancellation returns before
				// Python/OCCT stops, which would release serialization too early.
				var startErr error
				generation, startErr = r.worker.StartOwned(r.ctx)
				reply.err = startErr
				r.mu.Lock()
				if reply.err == nil && task.ctx.Err() == nil && task.epoch == r.epoch {
					task.generation = generation
				} else if reply.err == nil {
					reply.err = cancelledError(context.Canceled)
				}
				r.mu.Unlock()
				if reply.err == nil {
					reply.result, reply.err = r.worker.CallOwned(r.ctx, generation, task.method, task.params)
				}
				if startErr != nil && generation != 0 && !r.worker.OwnedRetired(generation) {
					holdReservation = true
					r.mu.Lock()
					r.failure = startErr
					r.mu.Unlock()
				}
			}
			r.mu.Lock()
			stop := task.interruption
			// This is the completion/cancel first-wins boundary.
			r.active = nil
			task.ticket.completed = true
			r.mu.Unlock()
			if stop != nil {
				<-stop.nativeDone
				reply = workerReply{err: cancelledError(context.Canceled)}
			} else {
				var workerErr *bridge.WorkerError
				crashed := errors.As(reply.err, &workerErr) && workerErr.Kind == "crashed"
				if generation != 0 && (crashed || r.ctx.Err() != nil) {
					retireCtx, cancel := context.WithTimeout(context.Background(), bridge.OwnedRetirementTimeout)
					retireErr := r.worker.RetireOwned(retireCtx, generation)
					cancel()
					if retireErr != nil {
						r.mu.Lock()
						r.failure = retireErr
						r.mu.Unlock()
						holdReservation = !r.worker.OwnedRetired(generation)
					}
				}
			}
			if reply.err == nil && task.method == "evaluate" {
				reply.result, reply.err = evaluationEpoch(reply.result, generation)
			}
			if task.ctx.Err() == nil {
				task.reply <- reply
			}
			// A failed retirement retains both the process owner and its quota.
			if !holdReservation && (stop == nil || r.worker.OwnedRetired(stop.generation)) {
				r.release(task)
			}
			if stop != nil {
				<-stop.done
			}
		}
	}
}

func evaluationEpoch(result json.RawMessage, generation uint64) (json.RawMessage, error) {
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(result, &payload); err != nil {
		return nil, err
	}
	if payload == nil {
		return nil, &bridge.WorkerError{Kind: "internal", Message: "evaluate returned no object"}
	}
	provenance := make(map[string]interface{})
	if raw := payload["provenance"]; len(raw) != 0 {
		if err := json.Unmarshal(raw, &provenance); err != nil {
			return nil, err
		}
	}
	if provenance == nil {
		provenance = make(map[string]interface{})
	}
	provenance["process_epoch"] = generation
	encoded, err := json.Marshal(provenance)
	if err != nil {
		return nil, err
	}
	payload["provenance"] = encoded
	return json.Marshal(payload)
}

func (s *server) workerCalls() *workerRunner {
	s.runnerMu.Lock()
	defer s.runnerMu.Unlock()
	if s.runner == nil {
		s.runner = newWorkerRunner(s.ctx, s.worker)
	}
	return s.runner
}
