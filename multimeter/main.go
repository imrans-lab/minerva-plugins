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
	serverVersion   = "0.1.0"
	pluginID        = "multimeter"
	eventReading    = "multimeter.reading"
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

// server ties the stdout writer, the meter and the recorder together.
type server struct {
	out      sync.Mutex
	enc      *json.Encoder
	meter    *Meter
	recorder *Recorder
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
		"description": "Connection state of the OWON B41T+ multimeter: connected, meter name and address, firmware/serial, the latest reading, any connection error, and whether a recording is running. The plugin scans and reconnects on its own; a disconnected status with an error names what to do.",
		"inputSchema": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}},
	},
	{
		"name":        "read",
		"description": "The latest measurement from the meter: {value, unit, prefix, function, display, flags, overload, timestamp}. Value is in the displayed unit with prefix (e.g. value 3.0 with prefix k and unit Ω). Pass count > 1 to also get the last N readings oldest-first (up to 600, ~3 minutes) for trends. Returns not_connected when the meter is away.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"count": map[string]interface{}{"type": "number", "description": "How many recent readings to include in `history` (default 1 = latest only)."},
			},
		},
	},
	{
		"name":        "press",
		"description": "Press one of the meter's front-panel buttons remotely: select (cycles the sub-function, e.g. V DC→V AC), range (manual/auto range), hold, rel (relative zero), hz (frequency/duty on AC functions), maxmin. long=true holds the button, which on the physical meter changes the action (e.g. long range returns to autorange). The rotary dial cannot be moved remotely.",
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
		"name":        "record_start",
		"description": "Start logging every reading to a CSV (timestamp, value, unit, function, flags, raw). Omit path to write into the plugin's data directory with a timestamped name. Returns the path. One recording at a time.",
		"inputSchema": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"path": map[string]interface{}{"type": "string", "description": "Absolute CSV path to write; default is <data dir>/recordings/<timestamp>.csv."},
			},
		},
	},
	{
		"name":        "record_stop",
		"description": "Stop the running recording and return {path, rows, seconds}. Open the CSV with minerva_create_spreadsheet_editor to chart it.",
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

// pushState publishes the connection + recording snapshot for panels and
// minerva_plugin_state.
func (s *server) pushState() {
	st := s.meter.Status()
	delete(st, "last")
	st["recording"] = s.recorder.Status()
	s.notify("minerva/plugin_state", map[string]interface{}{"state": st})
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
		func(r Reading) {
			s.recorder.Add(r)
			s.notify("minerva/plugin_event", map[string]interface{}{"event": eventReading, "payload": r})
		},
		s.pushState,
	)
	// MULTIMETER_NO_BLE lets the MCP smoke and the decoder tests run on a
	// runner with no Bluetooth radio.
	if os.Getenv("MULTIMETER_NO_BLE") == "" {
		go s.meter.Run()
	}

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 4<<20)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var msg rpcRequest
		if err := json.Unmarshal(line, &msg); err != nil {
			s.fail(json.RawMessage("null"), -32700, "Parse error")
			continue
		}
		s.dispatch(&msg)
	}
	if err := scanner.Err(); err != nil {
		log.Printf("stdin read error: %v", err)
		os.Exit(1)
	}
}
