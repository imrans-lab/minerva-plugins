package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// fakeHost drives the plugin over the real stdio protocol: it writes lines
// to the plugin's stdin and reads the plugin's stdout.
type fakeHost struct {
	t     *testing.T
	toIn  *io.PipeWriter
	lines chan map[string]json.RawMessage
}

func startPlugin(t *testing.T) (*server, *fakeHost) {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &server{
		enc:      json.NewEncoder(outW),
		recorder: &Recorder{},
		dataDir:  t.TempDir(),
		meter:    NewMeter(func(Reading) {}, func() {}),
	}
	go s.serve(inR)
	h := &fakeHost{t: t, toIn: inW, lines: make(chan map[string]json.RawMessage, 64)}
	go func() {
		sc := bufio.NewScanner(outR)
		for sc.Scan() {
			var m map[string]json.RawMessage
			if json.Unmarshal(sc.Bytes(), &m) == nil {
				h.lines <- m
			}
		}
	}()
	t.Cleanup(func() { inW.Close(); outW.Close() })
	return s, h
}

func (h *fakeHost) write(format string, a ...interface{}) {
	h.t.Helper()
	if _, err := fmt.Fprintf(h.toIn, format+"\n", a...); err != nil {
		h.t.Fatalf("write to plugin: %v", err)
	}
}

// next returns the next plugin message that is not a notification.
func (h *fakeHost) next(what string) map[string]json.RawMessage {
	h.t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case m := <-h.lines:
			if _, has := m["id"]; has {
				return m
			}
		case <-deadline:
			h.t.Fatalf("plugin wedged waiting for %s", what)
		}
	}
}

func (h *fakeHost) expectCapability(capability string) string {
	h.t.Helper()
	m := h.next("capability request " + capability)
	var p struct {
		Capability string `json:"capability"`
	}
	if err := json.Unmarshal(m["params"], &p); err != nil {
		h.t.Fatalf("capability params: %v in %v", err, m)
	}
	if string(m["method"]) != `"minerva/capability"` || p.Capability != capability {
		h.t.Fatalf("want capability %s, got %v", capability, m)
	}
	return string(m["id"])
}

// expectTool reads the response to tools/call id and returns its decoded
// tool result.
func (h *fakeHost) expectTool(id int) map[string]interface{} {
	h.t.Helper()
	return h.toolResult(h.next(fmt.Sprintf("tool response %d", id)), id)
}

// toolResult decodes m as the response to tools/call id.
func (h *fakeHost) toolResult(m map[string]json.RawMessage, id int) map[string]interface{} {
	h.t.Helper()
	if string(m["id"]) != fmt.Sprint(id) {
		h.t.Fatalf("want response to %d, got %v", id, m)
	}
	var env struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(m["result"], &env); err != nil || len(env.Content) != 1 {
		h.t.Fatalf("tool %d: bad envelope %v", id, m)
	}
	var out map[string]interface{}
	if err := json.Unmarshal([]byte(env.Content[0].Text), &out); err != nil {
		h.t.Fatalf("tool %d: result text: %v", id, err)
	}
	return out
}

// A capability call from a background goroutine stays outstanding while the
// host sends tool calls, one of which makes its own capability call. The
// host answers the two capability calls in reverse order; each caller must
// get its own reply and every tool call must still be answered.
func TestCapabilityFromAnyGoroutine(t *testing.T) {
	s, h := startPlugin(t)
	dir := t.TempDir()

	type outcome struct {
		raw json.RawMessage
		err error
	}
	background := make(chan outcome, 1)
	go func() {
		raw, err := s.callCapability(context.Background(), "test.background", map[string]interface{}{})
		background <- outcome{raw, err}
	}()
	bgID := h.expectCapability("test.background")

	h.write(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"status","arguments":{}}}`)
	if st := h.expectTool(1); st["success"] != true {
		t.Fatalf("status: %v", st)
	}

	// record_export without a path asks the host for a save path from inside
	// the handler, so two capability calls are now outstanding.
	h.write(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"record_start","arguments":{"path":%q}}}`, filepath.Join(dir, "rec.csv"))
	h.expectTool(2)
	h.write(`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"record_stop","arguments":{}}}`)
	h.expectTool(3)
	h.write(`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"record_export","arguments":{}}}`)
	pickID := h.expectCapability("host.dialogs.file_picker")
	if pickID == bgID {
		t.Fatalf("two outstanding capability calls share id %s", pickID)
	}

	dest := filepath.Join(dir, "export.csv")
	h.write(`{"jsonrpc":"2.0","id":%s,"result":{"success":true,"result":{"cancelled":false,"path":%q}}}`, pickID, dest)
	if ex := h.expectTool(4); ex["success"] != true || ex["path"] != dest {
		t.Fatalf("record_export: %v", ex)
	}
	if _, err := os.Stat(dest); err != nil {
		t.Fatalf("export file: %v", err)
	}
	select {
	case o := <-background:
		t.Fatalf("background caller got a reply meant for someone else: %s %v", o.raw, o.err)
	default:
	}

	h.write(`{"jsonrpc":"2.0","id":%s,"result":{"marker":"background"}}`, bgID)
	select {
	case o := <-background:
		var got struct {
			Marker string `json:"marker"`
		}
		if o.err != nil {
			t.Fatalf("background call: %v", o.err)
		}
		if err := json.Unmarshal(o.raw, &got); err != nil {
			t.Fatalf("background reply %s: %v", o.raw, err)
		}
		if got.Marker != "background" {
			t.Fatalf("background reply: %s %v", o.raw, o.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("background capability call never got its reply")
	}
}
