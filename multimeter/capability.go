package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync"
)

// inbound is any line the host writes: a request or notification (Method
// set) or a reply to one of our capability calls (Method empty).
type inbound struct {
	rpcRequest
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

// capReply is what a capability waiter receives; ok is false when stdin
// closed before the host answered.
type capReply struct {
	result json.RawMessage
	err    *rpcError
	ok     bool
}

// capRouter owns the plugin's side of host capability calls: it hands out
// request ids and delivers each reply to the goroutine waiting on that id.
type capRouter struct {
	mu      sync.Mutex
	seq     int
	pending map[string]chan capReply
	closed  bool
}

func (r *capRouter) register() (string, chan capReply) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.seq++
	id := fmt.Sprintf(`"cap-%d"`, r.seq)
	ch := make(chan capReply, 1)
	if r.closed {
		ch <- capReply{}
		return id, ch
	}
	if r.pending == nil {
		r.pending = map[string]chan capReply{}
	}
	r.pending[id] = ch
	return id, ch
}

func (r *capRouter) deliver(id string, reply capReply) {
	r.mu.Lock()
	ch, has := r.pending[id]
	delete(r.pending, id)
	r.mu.Unlock()
	if has {
		ch <- reply
	}
}

// forget drops a waiter that gave up; a reply that arrives later is ignored.
func (r *capRouter) forget(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.pending, id)
}

// closeAll fails every outstanding and future call once stdin is gone.
func (r *capRouter) closeAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
	for id, ch := range r.pending {
		ch <- capReply{}
		delete(r.pending, id)
	}
}

// requestQueue is an unbounded FIFO between the stdin reader and the
// dispatch loop. A nil entry stands for an unparseable line, so its error
// reply keeps its place in arrival order. The queue must never block the
// reader: a handler waiting on a capability reply would otherwise deadlock
// behind a queued request.
type requestQueue struct {
	mu     sync.Mutex
	cond   *sync.Cond
	items  []*rpcRequest
	closed bool
}

func newRequestQueue() *requestQueue {
	q := &requestQueue{}
	q.cond = sync.NewCond(&q.mu)
	return q
}

func (q *requestQueue) push(m *rpcRequest) {
	q.mu.Lock()
	q.items = append(q.items, m)
	q.mu.Unlock()
	q.cond.Signal()
}

func (q *requestQueue) close() {
	q.mu.Lock()
	q.closed = true
	q.mu.Unlock()
	q.cond.Broadcast()
}

// pop blocks for the next item; false once the queue is closed and empty.
func (q *requestQueue) pop() (*rpcRequest, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for len(q.items) == 0 && !q.closed {
		q.cond.Wait()
	}
	if len(q.items) == 0 {
		return nil, false
	}
	m := q.items[0]
	q.items[0] = nil
	q.items = q.items[1:]
	return m, true
}

// serve is the only stdin reader. Replies go straight to their capability
// waiter; requests are dispatched one at a time in arrival order, so a
// capability call from any goroutine gets its reply even while a tool runs.
func (s *server) serve(in io.Reader) error {
	queue := newRequestQueue()
	readErr := make(chan error, 1)
	go func() {
		defer queue.close()
		defer s.caps.closeAll()
		scanner := bufio.NewScanner(in)
		scanner.Buffer(make([]byte, 1<<20), 4<<20)
		for scanner.Scan() {
			line := scanner.Bytes()
			if len(line) == 0 {
				continue
			}
			var msg inbound
			if err := json.Unmarshal(line, &msg); err != nil {
				queue.push(nil)
				continue
			}
			if msg.Method == "" {
				s.caps.deliver(string(msg.ID), capReply{result: msg.Result, err: msg.Error, ok: true})
				continue
			}
			queue.push(&msg.rpcRequest)
		}
		readErr <- scanner.Err()
	}()
	for {
		msg, ok := queue.pop()
		if !ok {
			break
		}
		if msg == nil {
			s.fail(json.RawMessage("null"), -32700, "Parse error")
			continue
		}
		s.dispatch(msg)
	}
	return <-readErr
}

// callCapability asks the host for a capability and blocks until the reply
// with its id arrives or ctx ends. Safe from any goroutine, including a tool
// handler. Background callers pass a deadline so a host that never answers
// cannot strand them.
func (s *server) callCapability(ctx context.Context, capability string, args map[string]interface{}) (json.RawMessage, error) {
	id, reply := s.caps.register()
	s.send(map[string]interface{}{
		"jsonrpc": "2.0", "id": json.RawMessage(id), "method": "minerva/capability",
		"params": map[string]interface{}{"capability": capability, "args": args},
	})
	var r capReply
	select {
	case r = <-reply:
	case <-ctx.Done():
		s.caps.forget(id)
		return nil, fmt.Errorf("%s: %w", capability, ctx.Err())
	}
	if !r.ok {
		return nil, fmt.Errorf("stdin closed waiting for %s", capability)
	}
	if r.err != nil {
		return nil, fmt.Errorf("%s: %s", capability, r.err.Message)
	}
	return r.result, nil
}

// pickSavePath pops the host save dialog. Empty path means the user cancelled.
// No deadline: a person may take any time to choose.
func (s *server) pickSavePath(title, initial string) (string, error) {
	raw, err := s.callCapability(context.Background(), "host.dialogs.file_picker", map[string]interface{}{
		"mode": "save", "title": title, "initial_path": initial, "filters": []string{"*.csv"},
	})
	if err != nil {
		return "", err
	}
	var pick struct {
		Success      bool   `json:"success"`
		ErrorMessage string `json:"error_message"`
		Result       struct {
			Cancelled bool   `json:"cancelled"`
			Path      string `json:"path"`
		} `json:"result"`
	}
	if err := json.Unmarshal(raw, &pick); err != nil {
		return "", err
	}
	if !pick.Success {
		return "", fmt.Errorf("file picker: %s", pick.ErrorMessage)
	}
	if pick.Result.Cancelled {
		return "", nil
	}
	return pick.Result.Path, nil
}
