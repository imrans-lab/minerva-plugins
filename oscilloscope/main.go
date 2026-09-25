// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bufio"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"github.com/google/gousb"
	"log"
	"os"
	"path/filepath"
)

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
	s := newServer()
	go s.worker()
	defer func() { close(s.stopping); s.op.Lock(); defer s.op.Unlock(); s.hw.Close() }()
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
			result = map[string]any{"protocolVersion": "2024-11-05", "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]string{"name": "oscilloscope", "version": "0.2.0"}}
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
			if err != nil {
				err = invalid(err.Error())
			}
			var body any
			if err == nil {
				body, err = s.call(p.Name, p.Arguments)
			}
			bad := err != nil
			if bad {
				body = map[string]any{"success": false, "error": toolError(err)}
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
