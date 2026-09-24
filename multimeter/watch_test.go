package main

import (
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// pluginEvent is one minerva/plugin_event notification as the host sees it.
type pluginEvent struct {
	Event   string `json:"event"`
	Payload struct {
		Kind string `json:"kind"`
	} `json:"payload"`
}

// untilRequest returns the next plugin message that carries an id (a
// response or a capability request) and the plugin events sent before it.
func (h *fakeHost) untilRequest(what string) (map[string]json.RawMessage, []pluginEvent) {
	h.t.Helper()
	var events []pluginEvent
	deadline := time.After(5 * time.Second)
	for {
		select {
		case m := <-h.lines:
			if _, has := m["id"]; has {
				return m, events
			}
			if string(m["method"]) == `"minerva/plugin_event"` {
				var ev pluginEvent
				json.Unmarshal(m["params"], &ev)
				events = append(events, ev)
			}
		case <-deadline:
			h.t.Fatalf("plugin wedged waiting for %s", what)
		}
	}
}

// quiet fails if the plugin sends a response or capability request within d.
func (h *fakeHost) quiet(what string, d time.Duration) {
	h.t.Helper()
	deadline := time.After(d)
	for {
		select {
		case m := <-h.lines:
			if _, has := m["id"]; has {
				h.t.Fatalf("%s: unexpected message %v", what, m)
			}
		case <-deadline:
			return
		}
	}
}

// expectNotify reads the next message as a minerva_terminal_notify request
// and checks it with checkNotify.
func (h *fakeHost) expectNotify(to, mustContain string) (string, string) {
	h.t.Helper()
	m, _ := h.untilRequest("notify to " + to)
	return h.checkNotify(m, to, mustContain)
}

// checkNotify checks m is a minerva_terminal_notify request to to whose line
// keeps the notify contract, and returns its request id and line.
func (h *fakeHost) checkNotify(m map[string]json.RawMessage, to, mustContain string) (string, string) {
	h.t.Helper()
	var p struct {
		Capability string `json:"capability"`
		Args       struct {
			To   string `json:"to"`
			Text string `json:"text"`
			From string `json:"from"`
		} `json:"args"`
	}
	json.Unmarshal(m["params"], &p)
	if p.Capability != notifyTerminal || p.Args.To != to {
		h.t.Fatalf("want notify to %s, got %v", to, m)
	}
	text := p.Args.Text
	if n := len([]rune(text)); n == 0 || n > notifyMaxText || strings.ContainsAny(text, "\r\n") ||
		!strings.Contains(text, "minerva_multimeter_changes") || !strings.Contains(text, mustContain) || p.Args.From == "" {
		h.t.Fatalf("notify line breaks the contract or misses %q: from %q, %q", mustContain, p.Args.From, text)
	}
	return string(m["id"]), text
}

// reply answers capability request id; result must be one line of JSON.
func (h *fakeHost) reply(id, result string) {
	h.t.Helper()
	h.write(`{"jsonrpc":"2.0","id":%s,"result":%s}`, id, result)
}

// A watch driven over the real stdio wire, with the test as the host.
//
// Oracle: a settled watch armed with no terminal and no slot ignores a
// reading settled at zero (a shorted OHM input) and, fed a probe settling at
// 3.29 V, sends exactly one terminal-list request and then one notify per
// live harness tab (not the shell tab, not the dead one), in list order;
// every line is one line of at most 400 characters that names
// minerva_multimeter_changes; a held receipt is offered again, and a tab
// that stays held gets exactly notifyAttempts offers, then nothing more. A
// watch with a terminal and a short timeout notifies that terminal once with
// "nothing happened" and no list request, then nothing more. A replaced then
// stopped watch notifies nobody when its edge arrives. A dial watch armed
// while the dial is already on its slot notifies once with no new edge. A host that never
// answers the list call costs one request: the watch gives up at the
// deadline, sends nothing more, and a late answer changes nothing. The dial
// move and the settle also go out as their declared plugin events.
func TestWatchWakesHarnessTerminals(t *testing.T) {
	savedDelay, savedDeadline := notifyRetryDelay, hostCallDeadline
	notifyRetryDelay, hostCallDeadline = 20*time.Millisecond, 5*time.Second
	t.Cleanup(func() { notifyRetryDelay, hostCallDeadline = savedDelay, savedDeadline })

	s, h := startPlugin(t)
	at := time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)
	feed := func(raws ...string) {
		t.Helper()
		for _, raw := range raws {
			pkt, _ := hex.DecodeString(raw)
			r, err := Decode(pkt, at)
			if err != nil {
				t.Fatalf("%s: %v", raw, err)
			}
			s.onReading(r)
			at = at.Add(400 * time.Millisecond)
		}
	}
	const auto = 4
	vdc := func(counts int) string { return encodePacket(0, 4, 3, auto, counts) }
	floatingV := []string{"24f004001500", "24f004001e00", "24f004000000"}
	ohmOL := encodePacket(4, 6, 7, auto, 0)
	ohmShort := encodePacket(4, 4, 2, auto, 0) // 0.00 Ω: settles at zero
	hasEvent := func(events []pluginEvent, name, kind string) bool {
		for _, ev := range events {
			if ev.Event == name && ev.Payload.Kind == kind {
				return true
			}
		}
		return false
	}

	s.changes.SetConnected(true, at)
	h.write(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"watch_start","arguments":{"condition":"settled","timeout_s":60}}}`)
	m, _ := h.untilRequest("watch_start reply")
	if res := h.toolResult(m, 1); res["success"] != true || res["replaced"] != nil {
		t.Fatalf("watch_start: %v", res)
	}

	// The watcher gets time to act on the 0 Ω settle before the dial move
	// undoes it, so a watch that fires on a zero settle fails here.
	feed(ohmShort, ohmShort, ohmShort, ohmShort)
	h.quiet("after a settle at zero", 300*time.Millisecond)
	feed(floatingV...)
	feed(vdc(3290), vdc(3291), vdc(3289), vdc(3292), vdc(3290), vdc(3291), vdc(3289), vdc(3292))
	list, events := h.untilRequest("terminal list")
	if !hasEvent(events, eventDial, "dial") || !hasEvent(events, eventSettled, "settled") {
		t.Errorf("dial and settled events should precede the watch firing: %+v", events)
	}
	var lp struct {
		Capability string `json:"capability"`
	}
	json.Unmarshal(list["params"], &lp)
	if lp.Capability != notifyTerminalList {
		t.Fatalf("want the terminal list first, got %v", list)
	}
	h.reply(string(list["id"]), `{"success":true,"result":{"success":true,"count":4,"terminals":[`+
		`{"id":"t1","name":"Bench","harness":"claude","alive":true},`+
		`{"id":"t2","name":"Shell","foreground_process":"zsh","alive":true},`+
		`{"id":"t3","name":"Review","harness":"codex","alive":true},`+
		`{"id":"t4","name":"Old","harness":"claude","alive":false}]}}`)
	// The notify tool's held receipt is a failure, flattened by the proxy.
	const held = `{"success":false,"status":"held","hold_reason":"human_typing","error_code":"mcp_tool_error","error_message":"a person typed. Send again in a moment."}`
	const written = `{"success":true,"result":{"success":true,"status":"written"}}`

	id, first := h.expectNotify("t1", "3.29")
	h.reply(id, held)
	id, again := h.expectNotify("t1", "3.29")
	if again != first {
		t.Errorf("retry changed the line: %q then %q", first, again)
	}
	h.reply(id, written)
	for i := 0; i < notifyAttempts; i++ {
		id, _ = h.expectNotify("t3", "3.29")
		h.reply(id, held)
	}
	h.quiet("after the settle watch was delivered", 300*time.Millisecond)

	h.write(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"watch_start","arguments":{"condition":"dial","slot":"OHM","timeout_s":1,"terminal":"t1"}}}`)
	m, _ = h.untilRequest("watch_start reply")
	if res := h.toolResult(m, 2); res["success"] != true || res["replaced"] != nil {
		t.Fatalf("watch_start after the first fired: %v", res)
	}
	id, _ = h.expectNotify("t1", "nothing happened")
	h.reply(id, written)
	h.quiet("after the timeout", 1500*time.Millisecond)

	h.write(`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"watch_start","arguments":{"condition":"any","terminal":"t1"}}}`)
	m, _ = h.untilRequest("watch_start reply")
	h.toolResult(m, 3)
	h.write(`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"watch_start","arguments":{"condition":"dial","slot":"OHM","terminal":"t1"}}}`)
	m, _ = h.untilRequest("watch_start reply")
	if res := h.toolResult(m, 4); res["replaced"] == nil || res["replaced"].(map[string]interface{})["condition"] != "any" {
		t.Errorf("second watch_start should report the replaced watch: %v", res)
	}
	h.write(`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"watch_stop","arguments":{}}}`)
	m, _ = h.untilRequest("watch_stop reply")
	if res := h.toolResult(m, 5); res["stopped"] != true {
		t.Errorf("watch_stop: %v", res)
	}
	feed(ohmOL, ohmOL, ohmOL, ohmOL)
	h.quiet("after watch_stop", 300*time.Millisecond)

	// The dial is already on OHM when the watch is armed: it fires from the
	// live state with no new edge.
	h.write(`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"watch_start","arguments":{"condition":"dial","slot":"OHM","terminal":"t1"}}}`)
	// The notify may overtake the tool reply, so take both in either order.
	first7, _ := h.untilRequest("watch_start reply or notify")
	second7, _ := h.untilRequest("watch_start reply or notify")
	if string(first7["id"]) != "7" {
		first7, second7 = second7, first7
	}
	h.toolResult(first7, 7)
	id, _ = h.checkNotify(second7, "t1", "the dial reached OHM")
	h.reply(id, written)
	h.quiet("after the live-state watch", 300*time.Millisecond)

	// Every earlier delivery has finished, so no goroutine reads the deadline
	// while it changes.
	hostCallDeadline = 300 * time.Millisecond
	h.write(`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"watch_start","arguments":{"condition":"any"}}}`)
	m, _ = h.untilRequest("watch_start reply")
	h.toolResult(m, 6)
	feed(floatingV...)
	list, _ = h.untilRequest("unanswered terminal list")
	json.Unmarshal(list["params"], &lp)
	if lp.Capability != notifyTerminalList {
		t.Fatalf("want the terminal list, got %v", list)
	}
	h.quiet("while the list call times out", 800*time.Millisecond)
	h.reply(string(list["id"]), `{"success":true,"result":{"success":true,"terminals":[{"id":"t1","harness":"claude","alive":true}]}}`)
	h.quiet("after a late list reply", 300*time.Millisecond)
}
