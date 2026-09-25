// SPDX-License-Identifier: GPL-3.0-or-later
// Oscilloscope's single acquisition worker owns USB. Panel and MCP controls
// share the same mutex-protected settings and immutable capture snapshots.
package main

import (
	"bufio"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"github.com/google/gousb"
	"log"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Server struct {
	mu        sync.Mutex
	out       sync.Mutex
	hw        Hardware
	settings  Settings
	running   bool
	connected bool
	problem   string
	seq       uint64
	latest    *Capture
	captures  []*Capture
	stopping  chan struct{}
}

func (s *Server) send(v any) {
	s.out.Lock()
	defer s.out.Unlock()
	if e := json.NewEncoder(os.Stdout).Encode(v); e != nil {
		log.Print(e)
	}
}
func (s *Server) status() map[string]any {
	st := map[string]any{"success": true, "connected": s.connected, "running": s.running, "error": s.problem, "model": "Hantek 6022BE", "settings": s.settings, "serial": s.hw.serial, "calibration": s.hw.calibration, "firmware": "0210", "trigger": "software rising edge; acquisitions have gaps", "input_range_at_bnc_v": []int{-5, 5}}
	if s.latest != nil {
		c := *s.latest
		c.Raw = nil
		c.Preview = [2][]float64{}
		st["latest"] = c
	}
	return st
}
func (s *Server) acquire() error {
	if !s.connected {
		if e := s.hw.Open(); e != nil {
			return e
		}
		s.connected = true
	}
	raw, e := s.hw.Capture(s.settings.Rate, s.settings.Samples)
	if e != nil {
		s.hw.Close()
		s.connected = false
		return e
	}
	s.seq++
	s.latest = makeCapture(raw, s.settings, s.hw.zero, s.hw.calibration, s.seq)
	s.captures = append(s.captures, s.latest)
	if len(s.captures) > 16 {
		s.captures = s.captures[len(s.captures)-16:]
	}
	s.problem = ""
	return nil
}
func (s *Server) worker() {
	timer := time.NewTicker(250 * time.Millisecond)
	defer timer.Stop()
	for {
		select {
		case <-s.stopping:
			return
		case <-timer.C:
			s.mu.Lock()
			if s.running {
				if e := s.acquire(); e != nil {
					s.problem = e.Error()
					s.running = false
				}
			}
			s.mu.Unlock()
		}
	}
}
func schema(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props, "additionalProperties": false}
}
func toolsList() []map[string]any {
	descriptions := map[string]string{
		"status":    "Connection, acquisition state, current settings and latest measurements. Read minerva_plugin_help id=oscilloscope. Voltages require confirmed physical probe attenuation.",
		"configure": "Set sample rate (100000, 200000, 500000, 1000000), probe ratios (1 or 10) and software trigger channel (1 or 2). Setting a probe ratio confirms its physical switch setting. Both channels always acquired; hardware range is ±5 V at BNC.",
		"run":       "Start repeated finite two-channel captures. Loads bundled firmware into RAM if needed. No EEPROM writes. Captures have gaps; cannot promise every glitch is observed.",
		"stop":      "Stop repeated acquisition; retain the last waveform.",
		"capture":   "Acquire one new two-channel waveform and return its ID, settings, measurements and preview; does not change Run/Stop state.",
		"read":      "Read retained capture by id (or latest). Default measurements only; preview=true returns up to 4096 consecutive samples per channel; raw=true returns full base64 interleaved ADC bytes. Last 16 retained.",
		"save":      "Save a retained capture to the plugin user-data directory as JSON (settings, calibration, raw bytes, measurements) and CSV. Returns paths. No arbitrary path writes.",
	}
	names := []string{"status", "configure", "run", "stop", "capture", "read", "save"}
	var out []map[string]any
	for _, name := range names {
		props := map[string]any{}
		if name == "configure" {
			props = map[string]any{"sample_rate_hz": map[string]any{"type": "integer", "enum": []int{100000, 200000, 500000, 1000000}}, "probe_ch1": map[string]any{"type": "integer", "enum": []int{1, 10}}, "probe_ch2": map[string]any{"type": "integer", "enum": []int{1, 10}}, "trigger_channel": map[string]any{"type": "integer", "enum": []int{1, 2}}}
		}
		if name == "read" || name == "save" {
			props["id"] = map[string]any{"type": "string"}
		}
		if name == "read" {
			props["preview"] = map[string]any{"type": "boolean"}
			props["raw"] = map[string]any{"type": "boolean"}
		}
		out = append(out, map[string]any{"name": name, "description": descriptions[name], "inputSchema": schema(props)})
	}
	return out
}
func (s *Server) call(name string, args json.RawMessage) (any, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var a struct {
		Rate    *float64 `json:"sample_rate_hz"`
		Probe1  *float64 `json:"probe_ch1"`
		Probe2  *float64 `json:"probe_ch2"`
		Trigger *float64 `json:"trigger_channel"`
		ID      string   `json:"id"`
		Preview bool     `json:"preview"`
		Raw     bool     `json:"raw"`
	}
	if len(args) > 0 {
		dec := json.NewDecoder(strings.NewReader(string(args)))
		dec.DisallowUnknownFields()
		if e := dec.Decode(&a); e != nil {
			return nil, e
		}
	}
	switch strings.TrimPrefix(name, "minerva_oscilloscope_") {
	case "status":
		return s.status(), nil
	case "configure":
		next := s.settings
		if a.Rate != nil {
			if _, ok := rates[int(*a.Rate)]; !ok || math.Trunc(*a.Rate) != *a.Rate {
				return nil, fmt.Errorf("unsupported sample rate")
			}
			next.Rate = int(*a.Rate)
		}
		for ch, p := range []*float64{a.Probe1, a.Probe2} {
			if p != nil {
				if *p != 1 && *p != 10 {
					return nil, fmt.Errorf("probe ratio must be 1 or 10")
				}
				next.Probe[ch] = int(*p)
				next.Confirmed[ch] = true
			}
		}
		if a.Trigger != nil {
			if *a.Trigger != 1 && *a.Trigger != 2 {
				return nil, fmt.Errorf("trigger channel must be 1 or 2")
			}
			next.Trigger = int(*a.Trigger)
		}
		s.settings = next
		return s.status(), nil
	case "run":
		s.running = true
		s.problem = ""
		return s.status(), nil
	case "stop":
		s.running = false
		return s.status(), nil
	case "capture":
		if e := s.acquire(); e != nil {
			s.problem = e.Error()
			return nil, e
		}
		c := *s.latest
		c.Raw = nil
		return c, nil
	case "read", "save":
		c := s.latest
		if a.ID != "" {
			c = nil
			for _, candidate := range s.captures {
				if candidate.ID == a.ID {
					c = candidate
					break
				}
			}
		}
		if c == nil {
			return nil, fmt.Errorf("capture not available; run or capture first (last 16 retained)")
		}
		if strings.HasSuffix(name, "save") {
			return saveCapture(c)
		}
		result := *c
		if !a.Raw {
			result.Raw = nil
		}
		if !a.Preview {
			result.Preview = [2][]float64{}
		}
		return result, nil
	default:
		return nil, fmt.Errorf("unknown tool %q", name)
	}
}
func saveCapture(c *Capture) (any, error) {
	root, e := os.UserConfigDir()
	if e != nil {
		return nil, e
	}
	dir := filepath.Join(root, "Minerva", "oscilloscope", "captures")
	if e = os.MkdirAll(dir, 0700); e != nil {
		return nil, e
	}
	path := filepath.Join(dir, c.ID)
	data, e := json.MarshalIndent(c, "", "  ")
	if e != nil {
		return nil, e
	}
	if e = os.WriteFile(path+".json", data, 0600); e != nil {
		return nil, e
	}
	f, e := os.OpenFile(path+".csv", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if e != nil {
		return nil, e
	}
	w := csv.NewWriter(f)
	_ = w.Write([]string{"time_s", "ch1_v", "ch2_v", "ch1_adc_u8", "ch2_adc_u8"})
	for i := 0; i < len(c.Raw)/2; i++ {
		_ = w.Write([]string{fmt.Sprintf("%.9f", float64(i)/float64(c.Settings.Rate)), fmt.Sprintf("%.6f", (float64(c.Raw[i*2])-c.ZeroADC[0])*c.VoltsPerCountAtBNC*float64(c.Settings.Probe[0])), fmt.Sprintf("%.6f", (float64(c.Raw[i*2+1])-c.ZeroADC[1])*c.VoltsPerCountAtBNC*float64(c.Settings.Probe[1])), fmt.Sprint(c.Raw[i*2]), fmt.Sprint(c.Raw[i*2+1])})
	}
	w.Flush()
	err := w.Error()
	closeErr := f.Close()
	if err != nil {
		return nil, err
	}
	if closeErr != nil {
		return nil, closeErr
	}
	return map[string]any{"success": true, "id": c.ID, "json_path": path + ".json", "csv_path": path + ".csv"}, nil
}
func main() {
	log.SetOutput(os.Stderr)
	if len(os.Args) == 2 && os.Args[1] == "--check-usb" {
		ctx := gousb.NewContext()
		if e := ctx.Close(); e != nil {
			log.Fatal(e)
		}
		fmt.Fprintln(os.Stderr, "USB library initialization OK")
		return
	}
	s := &Server{settings: Settings{Rate: 200000, Samples: 8192, Probe: [2]int{1, 1}, Trigger: 1}, stopping: make(chan struct{})}
	go s.worker()
	defer func() { close(s.stopping); s.mu.Lock(); defer s.mu.Unlock(); s.hw.Close() }()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	for scanner.Scan() {
		var r struct {
			JSONRPC string          `json:"jsonrpc"`
			ID      json.RawMessage `json:"id"`
			Method  string          `json:"method"`
			Params  json.RawMessage `json:"params"`
		}
		if e := json.Unmarshal(scanner.Bytes(), &r); e != nil {
			s.send(map[string]any{"jsonrpc": "2.0", "id": nil, "error": map[string]any{"code": -32700, "message": e.Error()}})
			continue
		}
		if len(r.ID) == 0 || string(r.ID) == "null" {
			continue
		}
		var result any
		var err error
		switch r.Method {
		case "initialize":
			result = map[string]any{"protocolVersion": "2024-11-05", "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]string{"name": "oscilloscope", "version": "0.1.1"}}
		case "ping":
			result = map[string]any{}
		case "tools/list":
			result = map[string]any{"tools": toolsList()}
		case "tools/call":
			var p struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			}
			err = json.Unmarshal(r.Params, &p)
			var body any
			if err == nil {
				body, err = s.call(p.Name, p.Arguments)
			}
			bad := err != nil
			if bad {
				body = map[string]any{"success": false, "error": err.Error()}
				err = nil
			}
			text, e := json.Marshal(body)
			if e != nil {
				err = e
			} else {
				result = map[string]any{"content": []map[string]any{{"type": "text", "text": string(text)}}, "isError": bad}
			}
		default:
			err = fmt.Errorf("unknown method %s", r.Method)
		}
		reply := map[string]any{"jsonrpc": "2.0", "id": r.ID}
		if err != nil {
			reply["error"] = map[string]any{"code": -32601, "message": err.Error()}
		} else {
			reply["result"] = result
		}
		s.send(reply)
	}
}
