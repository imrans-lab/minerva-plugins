package main

import (
	"context"
	"encoding/json"
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
	ctx    context.Context
	method string
	params json.RawMessage
	reply  chan workerReply
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
}

func newWorkerRunner(ctx context.Context, worker *bridge.Worker) *workerRunner {
	r := &workerRunner{ctx: ctx, worker: worker, queue: make(chan *workerTask, maxWorkerTasks), done: make(chan struct{})}
	go r.run()
	return r
}

func cancelledError(err error) *bridge.WorkerError {
	return &bridge.WorkerError{Kind: "cancelled", Message: err.Error()}
}

// workerTicket owns one reservation until Call transfers it to the pump.
// Ownership and release share the runner mutex with ordinary admission.
type workerTicket struct {
	runner *workerRunner
	bytes  int
	owned  bool
}

func (r *workerRunner) reserve(ctx context.Context, inputBytes int) (*workerTicket, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, cancelledError(err)
	}
	if r.stopped || r.ctx.Err() != nil {
		return nil, cancelledError(context.Canceled)
	}
	if r.count >= maxWorkerTasks || inputBytes > maxWorkerBytes-r.bytes {
		return nil, &bridge.WorkerError{Kind: "busy", Message: "CAD worker queue capacity reached; retry later"}
	}
	r.count++
	r.bytes += inputBytes
	return &workerTicket{runner: r, bytes: inputBytes, owned: true}, nil
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
	if len(params) != t.bytes {
		r.mu.Unlock()
		return nil, &bridge.WorkerError{Kind: "internal", Message: "CAD worker arguments changed after reservation"}
	}
	task := &workerTask{ctx: ctx, method: method, params: append(json.RawMessage(nil), params...), reply: make(chan workerReply, 1)}
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
	r.count--
	r.bytes -= len(task.params)
	task.params = nil
	r.mu.Unlock()
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
			var reply workerReply
			if r.worker == nil {
				reply.err = &bridge.WorkerError{Kind: "internal", Message: "CAD worker is unavailable"}
			} else {
				// Never pass the request context: bridge cancellation returns before
				// Python/OCCT stops, which would release serialization too early.
				reply.err = r.worker.Start(r.ctx)
				if reply.err == nil && task.ctx.Err() != nil {
					r.release(task)
					continue
				}
				if reply.err == nil {
					reply.result, reply.err = r.worker.Call(r.ctx, task.method, task.params)
				}
			}
			if task.ctx.Err() == nil {
				task.reply <- reply
			}
			r.release(task)
		}
	}
}

func (s *server) workerCalls() *workerRunner {
	s.runnerMu.Lock()
	defer s.runnerMu.Unlock()
	if s.runner == nil {
		s.runner = newWorkerRunner(s.ctx, s.worker)
	}
	return s.runner
}
