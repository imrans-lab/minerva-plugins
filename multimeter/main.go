// Command multimeter-plugin is the MultiMeter plugin MCP server for Minerva:
// it reads an OWON B41T+ digital multimeter over Bluetooth Low Energy and
// exposes it to the LLM as tools, to panels as events and state.
//
// Outer protocol: JSON-RPC 2.0 over stdin/stdout, one message per line.
// stdout carries only JSON-RPC; logs go to stderr. Readings arrive on a BLE
// goroutine, so every stdout write goes through one mutex.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/imrans-lab/minerva-plugins/shared/runtime"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "multimeter"
	serverVersion   = "0.2.0"
	pluginID        = "multimeter"
	eventReading    = "multimeter.reading"
	eventDial       = "multimeter.dial_changed"
	eventSettled    = "multimeter.reading_settled"
)

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type outResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

// server ties the stdout writer, the meter, the recorder and the change
// journal together.
type server struct {
	out      sync.Mutex
	enc      *json.Encoder
	caps     capRouter
	meter    *Meter
	recorder *Recorder
	guide    guideStore
	changes  edgeDetector
	watch    watchState
	dataDir  string
}

func (s *server) send(v interface{}) {
	s.out.Lock()
	defer s.out.Unlock()
	if err := s.enc.Encode(v); err != nil {
		log.Printf("write: %v", err)
	}
}

func (s *server) notify(method string, params interface{}) {
	s.send(map[string]interface{}{"jsonrpc": "2.0", "method": method, "params": params})
}

func (s *server) ok(id json.RawMessage, result interface{}) {
	s.send(outResponse{JSONRPC: "2.0", ID: id, Result: result})
}

func (s *server) fail(id json.RawMessage, code int, msg string) {
	s.send(outResponse{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: code, Message: msg}})
}

// respondTool wraps a tool result in the MCP content envelope. A result with
// success:false is also flagged isError so the host surfaces it.
func (s *server) respondTool(id json.RawMessage, result map[string]interface{}) {
	body, err := json.Marshal(result)
	if err != nil {
		s.fail(id, -32603, "marshal tool result: "+err.Error())
		return
	}
	env := map[string]interface{}{
		"content": []map[string]interface{}{{"type": "text", "text": string(body)}},
	}
	if ok, has := result["success"].(bool); has && !ok {
		env["isError"] = true
	}
	s.ok(id, env)
}

func toolErr(code, msg string) map[string]interface{} {
	return map[string]interface{}{"success": false, "error_code": code, "error_message": msg}
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

var toolList = []map[string]interface{}{
	{
		"name":        "status",
		"description": "Read minerva_plugin_help id=multimeter first. Connection state of the OWON B41T+ multimeter: connected, meter name and address, firmware/serial, the latest reading, any connection error, and whether a recording is running. The plugin scans and reconnects on its own; a disconnected status with an error names what to do.",
		"inputSchema": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}},
	},
	{
		"name":        "read",
		"description": "Read minerva_plugin_help id=multimeter first. The latest measurement from the meter: {value, unit, prefix, function, display, flags, overload, timestamp}. Value is in the displayed unit with prefix (e.g. value 3.0 with prefix k and unit Ω). Pass count > 1 to also get the last N readings oldest-first (up to 600, ~3 minutes) for trends. Returns not_connected when the meter is away.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"count": map[string]interface{}{"type": "number", "description": "How many recent readings to include in `history` (default 1 = latest only)."},
			},
		},
	},
	{
		"name":        "press",
		"description": "Read minerva_plugin_help id=multimeter first. Press one of the meter's front-panel buttons remotely: select (cycles the sub-function, e.g. V DC→V AC), range (manual/auto range), hold, rel (relative zero), hz (frequency/duty on AC functions), maxmin. long=true holds the button, which on the physical meter changes the action (e.g. long range returns to autorange). The rotary dial cannot be moved remotely.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"button": map[string]interface{}{"type": "string", "enum": []string{"select", "range", "hold", "rel", "hz", "maxmin"}},
				"long":   map[string]interface{}{"type": "boolean", "description": "Long press instead of a tap."},
			},
			"required": []string{"button"},
		},
	},
	{
		"name":        "guide_set",
		"description": "Read minerva_plugin_help id=multimeter first. Show the user how to set up the meter: the MultiMeter panel (open it once with minerva_plugin_open_panel plugin_id=multimeter) opens on its Meter view, a drawing of the meter face, and brings it to the front when a guide is set: the target dial slot, which jack the red lead goes in (black is always COM), and a one-line instruction such as 'red probe on the 3.3 V pin, black on ground'. The panel also draws the dial position the meter is on right now, so the user sees target versus actual. Slots: V (volts DC/AC, Select toggles AC), mV, OHM (ohms; Select cycles continuity and diode), HZ, CAP, TEMP, uA, mA, A. Current slots add a series-measurement warning automatically. Returns the guide and the live dial slot.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"slot":        map[string]interface{}{"type": "string", "enum": []string{"V", "mV", "OHM", "HZ", "CAP", "TEMP", "uA", "mA", "A"}},
				"instruction": map[string]interface{}{"type": "string", "description": "What to do with the probes, in the user's terms."},
				"warning":     map[string]interface{}{"type": "string", "description": "Optional safety line shown in amber."},
			},
			"required": []string{"slot", "instruction"},
		},
	},
	{
		"name":        "guide_clear",
		"description": "Read minerva_plugin_help id=multimeter first. Remove the current guide; the Meter view goes back to its live reference card.",
		"inputSchema": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}},
	},
	{
		"name":        "wait_for",
		"description": "Read minerva_plugin_help id=multimeter first. Block until the meter reports the wanted dial slot (default: the guide's slot) for settle_ms, or timeout_s passes (max 25; call again to keep waiting). nonzero=true also waits for a non-zero, non-overload reading, i.e. the probes are on something. Pass cursor (from changes, or an edge's seq) so what the user already did counts: if since that cursor the dial reached the slot (with nonzero: a value settled on it), wait_for answers at once with {matched, edge, reading} instead of waiting for it to happen again. Returns {matched, reading, waited_s} and, when not matched, the live dial slot so you can tell the user what the meter is actually on. The meter cannot see which jack a lead is in; if the reading stays zero on the right slot, ask about the leads and show the guide panel.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"slot":      map[string]interface{}{"type": "string", "enum": []string{"V", "mV", "OHM", "HZ", "CAP", "TEMP", "uA", "mA", "A"}},
				"nonzero":   map[string]interface{}{"type": "boolean"},
				"settle_ms": map[string]interface{}{"type": "number", "description": "How long the condition must hold (default 1000)."},
				"timeout_s": map[string]interface{}{"type": "number", "description": "Seconds to wait, 1-25 (default 20)."},
				"cursor":    map[string]interface{}{"type": "number", "description": "Journal cursor; an edge after it that already meets the condition is returned at once."},
			},
		},
	},
	{
		"name":        "changes",
		"description": "Read minerva_plugin_help id=multimeter first. What happened at the bench since you last looked, oldest first: the dial moved to a slot, a reading settled at a new value (held steady about a second; small wobble is not reported), the reading fell back to near zero (probes lifted, contact lost), OL (open circuit on OHM, over range elsewhere), HOLD or REL turned on or off, the meter connected or disconnected. The user keeps working while you are not answering, so after any pause call changes first, with the cursor from your previous call (omit it the first time), and keep the returned cursor for next time. Returns {edges: [{seq, kind, at, summary, slot, reading}], cursor}; missed > 0 means that many older edges fell out of the journal (it keeps the last 200); reset=true means the plugin restarted since your cursor, so every kept edge is returned.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"cursor": map[string]interface{}{"type": "number", "description": "The cursor from your previous changes call; omit or 0 for everything kept."},
			},
		},
	},
	{
		"name":        "watch_start",
		"description": "Read minerva_plugin_help id=multimeter first. Get woken when the user has done the next step, instead of blocking: set the guide (guide_set), call watch_start, then end your turn; when the condition is met, or timeout_s passes, one line saying what happened arrives in your terminal as a new message, and you then call changes with the returned cursor. Works only for an agent running in a Minerva terminal tab. condition: dial (the dial reaches slot; default the guide's slot), settled (a non-zero reading settles, on slot if given), any (anything changes at the bench). One watch at a time: calling watch_start again replaces the armed watch (the reply's replaced shows the old one). Returns {watching: {condition, slot, timeout_s, terminal, cursor}}.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"condition": map[string]interface{}{"type": "string", "enum": []string{"dial", "settled", "any"}},
				"slot":      map[string]interface{}{"type": "string", "enum": []string{"V", "mV", "OHM", "HZ", "CAP", "TEMP", "uA", "mA", "A"}},
				"timeout_s": map[string]interface{}{"type": "number", "description": "Seconds to watch before waking you with 'nothing happened' (default 600, max 3600)."},
				"terminal":  map[string]interface{}{"type": "string", "description": "Minerva terminal to wake: your $MINERVA_TERMINAL_ID or tab name. Omit to wake every terminal that is running an agent harness."},
				"cursor":    map[string]interface{}{"type": "number", "description": "Journal cursor from changes; if what you are watching for already happened after it and still holds, you are woken at once. Omit or pass 0 to count only what happens from now on; a cursor from before the plugin restarted is treated the same and reported as cursor_reset."},
			},
			"required": []string{"condition"},
		},
	},
	{
		"name":        "watch_stop",
		"description": "Read minerva_plugin_help id=multimeter first. Disarm the watch set by watch_start if it has not fired yet. Returns {stopped, watch}.",
		"inputSchema": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}},
	},
	{
		"name":        "record_start",
		"description": "Read minerva_plugin_help id=multimeter first. Start logging every reading to a CSV (timestamp, value, unit, function, flags, raw). Omit path to write into the plugin's data directory with a timestamped name. Returns the path. One recording at a time.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"path": map[string]interface{}{"type": "string", "description": "Absolute CSV path to write; default is <data dir>/recordings/<timestamp>.csv."},
			},
		},
	},
	{
		"name":        "record_export",
		"description": "Read minerva_plugin_help id=multimeter first. Copy the most recent recording (running or finished) to a path of the user's choosing. Pass path to write there directly; omit it to pop the host's save dialog. Returns {path, rows} or {cancelled: true}.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"path": map[string]interface{}{"type": "string", "description": "Absolute destination path for the CSV copy."},
			},
		},
	},
	{
		"name":        "record_stop",
		"description": "Read minerva_plugin_help id=multimeter first. Stop the running recording and return {path, rows, seconds}. Open the CSV with minerva_create_spreadsheet_editor to chart it.",
		"inputSchema": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}},
	},
}

func (s *server) callTool(id json.RawMessage, params json.RawMessage) {
	var p struct {
		Name string          `json:"name"`
		Args json.RawMessage `json:"arguments,omitempty"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		s.fail(id, -32700, "tools/call: parse params: "+err.Error())
		return
	}
	switch p.Name {
	case "status":
		st := s.meter.Status()
		st["success"] = true
		st["recording"] = s.recorder.Status()
		st["guide"] = s.guide.Get()
		st["dial"] = s.liveDial()
		s.respondTool(id, st)
	case "read":
		// Godot serialises every number as a float (2 arrives as 2.0).
		var a struct {
			Count float64 `json:"count"`
		}
		json.Unmarshal(p.Args, &a)
		st := s.meter.Status()
		last, has := st["last"]
		if !has {
			s.respondTool(id, toolErr("not_connected", fmt.Sprint(st["error"])))
			return
		}
		out := map[string]interface{}{"success": true, "connected": st["connected"], "reading": last}
		if a.Count > 1 {
			out["history"] = s.meter.Recent(int(a.Count))
		}
		s.respondTool(id, out)
	case "press":
		var a struct {
			Button string `json:"button"`
			Long   bool   `json:"long"`
		}
		json.Unmarshal(p.Args, &a)
		if err := s.meter.Press(a.Button, a.Long); err != nil {
			s.respondTool(id, toolErr("press_failed", err.Error()))
			return
		}
		s.respondTool(id, map[string]interface{}{"success": true, "button": a.Button, "long": a.Long})
	case "guide_set":
		s.respondTool(id, s.toolGuideSet(p.Args))
	case "guide_clear":
		s.guide.Clear()
		s.pushState()
		s.respondTool(id, map[string]interface{}{"success": true})
	case "wait_for":
		s.respondTool(id, s.toolWaitFor(p.Args))
	case "changes":
		var a struct {
			Cursor float64 `json:"cursor"`
		}
		json.Unmarshal(p.Args, &a)
		c := s.changes.Since(int(a.Cursor))
		out := map[string]interface{}{"success": true, "edges": c.Edges, "cursor": c.Cursor}
		if c.Missed > 0 {
			out["missed"] = c.Missed
		}
		if c.Reset {
			out["reset"] = true
		}
		s.respondTool(id, out)
	case "watch_start":
		s.respondTool(id, s.toolWatchStart(p.Args))
	case "watch_stop":
		s.respondTool(id, s.toolWatchStop())
	case "record_start":
		var a struct {
			Path string `json:"path"`
		}
		json.Unmarshal(p.Args, &a)
		if a.Path == "" {
			a.Path = filepath.Join(s.dataDir, "recordings", time.Now().Format("2006-01-02_150405")+".csv")
		}
		if err := s.recorder.Start(a.Path); err != nil {
			s.respondTool(id, toolErr("record_failed", err.Error()))
			return
		}
		s.pushState()
		s.respondTool(id, map[string]interface{}{"success": true, "path": a.Path})
	case "record_export":
		var a struct {
			Path string `json:"path"`
		}
		json.Unmarshal(p.Args, &a)
		s.respondTool(id, s.exportRecording(a.Path))
	case "record_stop":
		out, err := s.recorder.Stop()
		if err != nil {
			s.respondTool(id, toolErr("record_failed", err.Error()))
			return
		}
		s.pushState()
		out["success"] = true
		s.respondTool(id, out)
	default:
		s.fail(id, -32601, "tools/call: unknown tool: "+p.Name)
	}
}

// exportRecording copies the latest CSV to dest, asking the host for a
// destination when none is given.
func (s *server) exportRecording(dest string) map[string]interface{} {
	src := s.recorder.LastPath()
	if src == "" {
		return toolErr("no_recording", "nothing has been recorded yet")
	}
	if dest == "" {
		picked, err := s.pickSavePath("Save multimeter recording", filepath.Base(src))
		if err != nil {
			return toolErr("picker_failed", err.Error())
		}
		if picked == "" {
			return map[string]interface{}{"success": true, "cancelled": true}
		}
		dest = picked
	}
	in, err := os.Open(src)
	if err != nil {
		return toolErr("export_failed", err.Error())
	}
	defer in.Close()
	out, err := os.Create(dest)
	if err != nil {
		return toolErr("export_failed", err.Error())
	}
	defer out.Close()
	rows, err := copyCountingRows(out, in)
	if err != nil {
		return toolErr("export_failed", err.Error())
	}
	return map[string]interface{}{"success": true, "path": dest, "rows": rows}
}

// copyCountingRows copies a CSV and returns its data-row count (lines minus
// the header).
func copyCountingRows(dst io.Writer, src io.Reader) (int, error) {
	lines := 0
	r := bufio.NewReader(src)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			if _, werr := dst.Write(line); werr != nil {
				return 0, werr
			}
			lines++
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return 0, err
		}
	}
	if lines > 0 {
		lines--
	}
	return lines, nil
}

// pushState publishes the connection + recording snapshot for panels and
// minerva_plugin_state.
func (s *server) pushState() {
	st := s.meter.Status()
	delete(st, "last")
	st["recording"] = s.recorder.Status()
	st["guide"] = s.guide.Get()
	st["dial"] = s.liveDial()
	s.notify("minerva/plugin_state", map[string]interface{}{"state": st})
}

// onReading records one reading, publishes it, and publishes the dial-moved
// and reading-settled edges it produced as their own events.
func (s *server) onReading(r Reading) {
	s.recorder.Add(r)
	s.notify("minerva/plugin_event", map[string]interface{}{"event": eventReading, "payload": r})
	for _, e := range s.changes.Observe(r) {
		switch e.Kind {
		case EdgeDial:
			s.notify("minerva/plugin_event", map[string]interface{}{"event": eventDial, "payload": e})
			// The guide panel draws the live dial from plugin state.
			s.pushState()
		case EdgeSettled:
			s.notify("minerva/plugin_event", map[string]interface{}{"event": eventSettled, "payload": e})
		}
	}
}

func (s *server) dispatch(msg *rpcRequest) {
	isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"
	switch msg.Method {
	case "initialize":
		if isNotification {
			return
		}
		s.ok(msg.ID, map[string]interface{}{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]interface{}{},
			"serverInfo":      map[string]string{"name": serverName, "version": serverVersion},
		})
	case "notifications/initialized":
		s.pushState()
	case "tools/list":
		if isNotification {
			return
		}
		s.ok(msg.ID, map[string]interface{}{"tools": toolList})
	case "tools/call":
		if isNotification {
			return
		}
		s.callTool(msg.ID, msg.Params)
	case "shutdown":
		log.Printf("shutdown requested")
		os.Exit(0)
	default:
		if isNotification {
			return
		}
		s.fail(msg.ID, -32601, "Method not found: "+msg.Method)
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[multimeter-plugin] ")
	log.SetOutput(os.Stderr)

	s := &server{enc: json.NewEncoder(os.Stdout), recorder: &Recorder{}, dataDir: runtime.DataDir(pluginID)}
	s.meter = NewMeter(
		s.onReading,
		func() {
			s.changes.SetConnected(s.meter.Status()["connected"] == true, time.Now())
			s.pushState()
		},
	)
	// MULTIMETER_NO_BLE lets the MCP smoke and the decoder tests run on a
	// runner with no Bluetooth radio.
	if os.Getenv("MULTIMETER_NO_BLE") == "" {
		go s.meter.Run()
	}

	if err := s.serve(os.Stdin); err != nil {
		log.Printf("stdin read error: %v", err)
		os.Exit(1)
	}
}
