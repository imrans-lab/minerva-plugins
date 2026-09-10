package main

import (
	"log"
	"sync"

	"github.com/ipeerbhai/plugins/council/internal/session"
)

// recordChangedEvent is the name the host fans out to every live Council panel.
// It is declared in manifest.json under `events`; an undeclared name still
// reaches the panels but PluginEventBroker warns about it on every emission.
const recordChangedEvent = "council.record_changed"

// recordNotifier turns "the engine advanced a document" into the one message
// that lets the panel owning that document find out.
//
// WHY THIS EXISTS. A chat turn and an MCP tool call commit through the same
// engine as a panel's own command, but with no panel in the exchange. The
// wrapper holds the durable record, so an advance nobody tells it about is an
// advance that is not in the file the user saves. The notification carries no
// record and no authority — only which document moved and to what revision —
// and the panel that owns that document reads the snapshot back through its own
// ordinary exchange (architecture.md §5.5).
//
// WHY IT COALESCES, AND WHY IT WRITES FROM ITS OWN GOROUTINE. record() is
// called by the engine with the store lock held: it must never block, or a
// commit would be held behind the host draining stdout. So it only records the
// newest revision per document and wakes the writer. Collapsing a burst is
// safe precisely because the message says nothing about content — a panel told
// once about the newest revision reads exactly what a panel told five times
// would have — and it keeps a round of several contributions from putting a
// line on stdout per member.
type recordNotifier struct {
	mu      sync.Mutex
	writer  *stdoutWriter
	pending map[string]int
	wake    chan struct{}
}

func newRecordNotifier() *recordNotifier {
	return &recordNotifier{pending: map[string]int{}, wake: make(chan struct{}, 1)}
}

// bind hands the notifier the process's one stdout door and starts the single
// goroutine that writes through it. done releases that goroutine when the
// protocol loop returns.
func (n *recordNotifier) bind(writer *stdoutWriter, done <-chan struct{}) {
	n.mu.Lock()
	n.writer = writer
	n.mu.Unlock()
	go n.pump(done)
}

// record is the engine's observer. It runs under the store lock, so everything
// it does is bounded: take a short lock, keep the highest revision seen for
// this document, and wake the writer without waiting for it.
func (n *recordNotifier) record(projectID string, revision int) {
	if projectID == "" {
		// A document with no durable identity is one no panel can recognise as
		// its own, so there is nobody to tell.
		return
	}
	n.mu.Lock()
	if n.pending[projectID] < revision {
		n.pending[projectID] = revision
	}
	n.mu.Unlock()
	select {
	case n.wake <- struct{}{}:
	default:
		// A wake is already queued; the drain below will see this entry too.
	}
}

func (n *recordNotifier) pump(done <-chan struct{}) {
	for {
		select {
		case <-done:
			return
		case <-n.wake:
		}
		for _, notice := range n.drain() {
			if err := n.writer.write(notice); err != nil {
				log.Printf("write record-changed notification: %v", err)
			}
		}
	}
}

// drain takes everything waiting and renders it as host notifications.
func (n *recordNotifier) drain() []any {
	n.mu.Lock()
	defer n.mu.Unlock()
	notices := make([]any, 0, len(n.pending))
	for project, revision := range n.pending {
		notices = append(notices, map[string]any{
			"jsonrpc": "2.0",
			"method":  "minerva/plugin_event",
			"params": map[string]any{
				"event": recordChangedEvent,
				"payload": map[string]any{
					"project_id":        project,
					"snapshot_revision": revision,
				},
			},
		})
	}
	clear(n.pending)
	return notices
}

// observe wires a store to this notifier. Declared here so the one place that
// knows what the signal means also names where it comes from.
func (n *recordNotifier) observe(store *session.Store) {
	store.SetRecordObserver(n.record)
}
