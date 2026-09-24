package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"
)

// A watch lets an agent end its turn and be woken when the bench changes: it
// waits on the change journal and, when its condition is met or its timeout
// passes, types one self-contained line into agent terminals through
// Minerva's minerva_terminal_notify. One watch is armed at a time; arming
// another replaces it.

// WatchCondition names what a watch waits for.
type WatchCondition string

const (
	WatchDial    WatchCondition = "dial"    // the dial reaches Slot
	WatchSettled WatchCondition = "settled" // a non-zero reading settles (on Slot, when set)
	WatchAny     WatchCondition = "any"     // any journal edge
)

const (
	watchDefaultTimeout = 10 * time.Minute
	watchMaxTimeout     = time.Hour
	notifyFrom          = "multimeter"
	notifyMaxText       = 400
	notifyTerminalList  = "mcp.proxy:minerva_terminal_list"
	notifyTerminal      = "mcp.proxy:minerva_terminal_notify"
)

// Delivery pacing. A "held" receipt means a dialog or a person typing owns
// the tab, so the line is offered again a few times and then dropped. Each
// host call has its own deadline so an unanswered call cannot strand the
// delivery goroutine. Variables so the wire test can run in milliseconds.
var (
	notifyAttempts   = 4
	notifyRetryDelay = 3 * time.Second
	hostCallDeadline = 30 * time.Second
)

// watchSpec is one armed watch as watch_start accepted it.
type watchSpec struct {
	Condition WatchCondition `json:"condition"`
	Slot      string         `json:"slot,omitempty"`
	TimeoutS  float64        `json:"timeout_s"`
	Terminal  string         `json:"terminal,omitempty"`
	Cursor    int            `json:"cursor"`
}

type armedWatch struct {
	spec   watchSpec
	cancel context.CancelFunc
}

// watchState holds the armed watch, if any. A watch notifies only if it
// still holds the slot when it fires, and swap and release decide that under
// one lock: once watch_stop or watch_start has displaced a watch it never
// notifies, and once a watch has fired, stopping or replacing it no longer
// cuts off its delivery.
type watchState struct {
	mu  sync.Mutex
	cur *armedWatch
}

// swap installs next (nil to disarm) and cancels the watch it displaces.
func (w *watchState) swap(next *armedWatch) *armedWatch {
	w.mu.Lock()
	defer w.mu.Unlock()
	prev := w.cur
	w.cur = next
	if prev != nil {
		prev.cancel()
	}
	return prev
}

// release takes a firing watch out of the slot and reports whether it still
// held it; false means it was stopped or replaced and must stay silent.
func (w *watchState) release(a *armedWatch) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.cur != a {
		return false
	}
	w.cur = nil
	return true
}

// watchMatch returns the edge that fires the watch. dial and settled judge
// as wait_for does (lastMatch): the newest match after the cursor that no
// later edge undid, so the line never claims a state the meter has left;
// failing that, the meter already in that state (holdsNow), so a person who
// finished the step before the watch was armed is not left waiting. any
// fires on the first edge after the cursor.
func (s *server) watchMatch(w watchSpec) (Edge, bool) {
	if w.Condition == WatchDial || w.Condition == WatchSettled {
		nonzero := w.Condition == WatchSettled
		if e, ok := s.changes.lastMatch(w.Cursor, w.Slot, nonzero); ok {
			return e, true
		}
		return s.changes.holdsNow(w.Slot, nonzero)
	}
	if edges := s.changes.Since(w.Cursor).Edges; len(edges) > 0 {
		return edges[0], true
	}
	return Edge{}, false
}

// describe says what the watch waits for, in words for the woken agent.
func (w watchSpec) describe() string {
	switch w.Condition {
	case WatchDial:
		return "the dial to reach " + w.Slot
	case WatchSettled:
		if w.Slot != "" {
			return "a non-zero reading to settle on " + w.Slot
		}
		return "a non-zero reading to settle"
	}
	return "any change at the bench"
}

// toolWatchStart validates and arms a watch, replacing any armed one.
func (s *server) toolWatchStart(args json.RawMessage) map[string]interface{} {
	var a struct {
		Condition WatchCondition `json:"condition"`
		Slot      string         `json:"slot"`
		TimeoutS  float64        `json:"timeout_s"`
		Terminal  string         `json:"terminal"`
		Cursor    *float64       `json:"cursor"`
	}
	json.Unmarshal(args, &a)
	spec := watchSpec{Condition: a.Condition, Slot: a.Slot, Terminal: strings.TrimSpace(a.Terminal)}
	switch a.Condition {
	case WatchDial:
		if spec.Slot == "" {
			if g := s.guide.Get(); g != nil {
				spec.Slot = g.Slot
			}
		}
		if _, ok := jackForSlot[spec.Slot]; !ok {
			return toolErr("bad_slot", "condition dial needs a slot (V, mV, OHM, HZ, CAP, TEMP, uA, mA, A) or a guide set with guide_set")
		}
	case WatchSettled:
		if _, ok := jackForSlot[spec.Slot]; spec.Slot != "" && !ok {
			return toolErr("bad_slot", "slot must be one of V, mV, OHM, HZ, CAP, TEMP, uA, mA, A")
		}
	case WatchAny:
		spec.Slot = ""
	default:
		return toolErr("bad_condition", "condition must be dial, settled or any")
	}
	timeout := time.Duration(a.TimeoutS * float64(time.Second))
	if timeout <= 0 {
		timeout = watchDefaultTimeout
	}
	if timeout > watchMaxTimeout {
		timeout = watchMaxTimeout
	}
	spec.TimeoutS = timeout.Seconds()
	// Without a usable cursor only what happens from now on counts. Cursor 0
	// and a cursor from another run would otherwise replay every kept edge
	// and fire at once.
	spec.Cursor = s.changes.Since(0).Cursor
	cursorReset := false
	if a.Cursor != nil && *a.Cursor != 0 {
		if s.changes.Since(int(*a.Cursor)).Reset {
			cursorReset = true
		} else {
			spec.Cursor = int(*a.Cursor)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	armed := &armedWatch{spec: spec, cancel: cancel}
	prev := s.watch.swap(armed)
	go s.runWatch(ctx, armed, timeout)

	out := map[string]interface{}{
		"success":  true,
		"watching": spec,
		"next":     "End your turn now. One line will arrive in your terminal when this happens or the timeout passes; then call changes with this cursor.",
	}
	if prev != nil {
		out["replaced"] = prev.spec
	}
	if cursorReset {
		out["cursor_reset"] = true
	}
	return out
}

// toolWatchStop disarms the watch that has not fired yet, if any.
func (s *server) toolWatchStop() map[string]interface{} {
	prev := s.watch.swap(nil)
	if prev == nil {
		return map[string]interface{}{"success": true, "stopped": false}
	}
	return map[string]interface{}{"success": true, "stopped": true, "watch": prev.spec}
}

// runWatch waits until the watch's condition is met or its timeout passes,
// then delivers one line. The journal's Changed channel is taken before each
// look so no edge slips between the look and the wait. ctx ends only when
// swap displaces the watch, and swap clears the slot under the same lock
// release reads, so release alone decides whether a firing watch speaks,
// whichever of the edge, the timer and ctx won the race.
func (s *server) runWatch(ctx context.Context, a *armedWatch, timeout time.Duration) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		changed := s.changes.Changed()
		if e, ok := s.watchMatch(a.spec); ok {
			s.fire(a, edgeLine(a.spec, e))
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			s.fire(a, timeoutLine(a.spec, timeout))
			return
		case <-changed:
		}
	}
}

func (s *server) fire(a *armedWatch, line string) {
	if s.watch.release(a) {
		s.deliverNotify(a.spec, line)
	}
}

func edgeLine(w watchSpec, e Edge) string {
	what := e.Summary
	switch {
	case e.Reading == nil:
	case e.Kind == EdgeDial:
		what = fmt.Sprintf("the dial reached %s (%s)", slotLabel(*e.Reading), e.Reading.Function)
	case e.Kind == EdgeSettled:
		what = fmt.Sprintf("reading settled at %s (%s) with the dial on %s", e.Reading.Display, e.Reading.Function, slotLabel(*e.Reading))
	}
	return notifyLine(what, fmt.Sprintf("Call minerva_multimeter_changes with cursor %d for the full sequence.", w.Cursor))
}

func timeoutLine(w watchSpec, timeout time.Duration) string {
	return notifyLine(fmt.Sprintf("nothing happened in %s while waiting for %s", spokenDuration(timeout), w.describe()),
		fmt.Sprintf("Call minerva_multimeter_changes with cursor %d to see the bench, or minerva_multimeter_watch_start to keep waiting.", w.Cursor))
}

func spokenDuration(d time.Duration) string {
	n, unit := d.Minutes(), "minute"
	if d < time.Minute {
		n, unit = d.Seconds(), "second"
	}
	if n != 1 {
		unit += "s"
	}
	return strconv.FormatFloat(n, 'f', -1, 64) + " " + unit
}

// notifyLine builds "Multimeter update: <what>. <tail>" within
// minerva_terminal_notify's contract: one line of at most notifyMaxText
// characters with no control characters. Only what is shortened, so the
// tail telling the reader what to call next always survives.
func notifyLine(what, tail string) string {
	const prefix = "Multimeter update: "
	clean := func(t string) string {
		return strings.Map(func(r rune) rune {
			if r < 0x20 || r == 0x7f {
				return ' '
			}
			return r
		}, t)
	}
	what, tail = clean(what), clean(tail)
	room := notifyMaxText - len([]rune(prefix+". "+tail))
	if runes := []rune(what); len(runes) > room {
		what = string(runes[:room-3]) + "..."
	}
	return prefix + what + ". " + tail
}

// proxyReply is the host's answer to an mcp.proxy capability: the tool's
// own result under result on success; on failure the tool's fields are
// flattened beside success:false, which is where a held notify puts status.
type proxyReply struct {
	Success      bool            `json:"success"`
	ErrorMessage string          `json:"error_message"`
	Status       string          `json:"status"`
	HoldReason   string          `json:"hold_reason"`
	Result       json.RawMessage `json:"result"`
}

func (s *server) callProxy(capability string, args map[string]interface{}) (proxyReply, error) {
	ctx, cancel := context.WithTimeout(context.Background(), hostCallDeadline)
	defer cancel()
	var reply proxyReply
	raw, err := s.callCapability(ctx, capability, args)
	if err != nil {
		return reply, err
	}
	if err := json.Unmarshal(raw, &reply); err != nil {
		return reply, fmt.Errorf("%s: reply %s: %v", capability, raw, err)
	}
	return reply, nil
}

// harnessTerminals lists Minerva's terminals and returns the id of every
// live one with an agent harness in the foreground.
func (s *server) harnessTerminals() ([]string, error) {
	reply, err := s.callProxy(notifyTerminalList, map[string]interface{}{})
	if err != nil {
		return nil, err
	}
	if !reply.Success {
		return nil, fmt.Errorf("terminal list: %s", reply.ErrorMessage)
	}
	var list struct {
		Terminals []struct {
			ID      string `json:"id"`
			Harness string `json:"harness"`
			Alive   *bool  `json:"alive"`
		} `json:"terminals"`
	}
	if err := json.Unmarshal(reply.Result, &list); err != nil {
		return nil, fmt.Errorf("terminal list: %s: %v", reply.Result, err)
	}
	var ids []string
	for _, t := range list.Terminals {
		if t.ID != "" && t.Harness != "" && (t.Alive == nil || *t.Alive) {
			ids = append(ids, t.ID)
		}
	}
	return ids, nil
}

// deliverNotify sends text to the watch's terminal or, when none was given,
// to every harness terminal, one after another. Outcomes are logged: the
// agent the line was for is asleep, so there is nobody else to tell.
func (s *server) deliverNotify(w watchSpec, text string) {
	targets := []string{w.Terminal}
	if w.Terminal == "" {
		ids, err := s.harnessTerminals()
		if err != nil {
			log.Printf("watch: %v", err)
			return
		}
		if len(ids) == 0 {
			log.Printf("watch: no terminal is running an agent harness; dropped %q", text)
			return
		}
		targets = ids
	}
	for _, to := range targets {
		s.notifyTerminal(to, text)
	}
}

// notifyTerminal offers text to one terminal, retrying while it is held.
func (s *server) notifyTerminal(to, text string) {
	args := map[string]interface{}{"to": to, "text": text, "from": notifyFrom}
	for attempt := 1; attempt <= notifyAttempts; attempt++ {
		reply, err := s.callProxy(notifyTerminal, args)
		if err != nil {
			log.Printf("watch: notify %s: %v", to, err)
			return
		}
		status := reply.Status
		if status == "" && len(reply.Result) > 0 {
			var receipt struct {
				Status string `json:"status"`
			}
			json.Unmarshal(reply.Result, &receipt)
			status = receipt.Status
		}
		if status != "held" {
			if !reply.Success {
				log.Printf("watch: notify %s refused: %s", to, reply.ErrorMessage)
			} else if status != "written" && status != "queued" && status != "dispatched" {
				log.Printf("watch: notify %s: status %q", to, status)
			}
			return
		}
		if attempt == notifyAttempts {
			log.Printf("watch: notify %s still held (%s) after %d attempts; dropped", to, reply.HoldReason, attempt)
			return
		}
		time.Sleep(notifyRetryDelay)
	}
}
