// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"encoding/json"
	"strings"
	"time"
)

func (s *Server) call(name string, raw json.RawMessage) (any, error) {
	name = strings.TrimPrefix(name, "minerva_oscilloscope_")
	a, err := parseArgs(name, raw)
	if err != nil {
		return nil, err
	}
	// Pure state reads and telemetry need no USB/mutation lock.
	if name == "status" || name == "read" || name == "evaluate" || name == "save" || name == "panel_sync" {
		s.mu.Lock()
		switch name {
		case "status":
			r := s.status()
			for _, include := range a.Include {
				switch include {
				case "retention":
					r["retention"] = map[string]any{"pinned_ids": s.pinIDs(), "pin_limit": 8, "ring_limit": 16, "lifetime": "backend_session"}
				case "display":
					r["display"] = s.displayState()
				case "capabilities":
					r["capabilities"] = map[string]any{"rates_hz": []int{100000, 200000, 500000, 1000000}, "samples_per_channel": 8192, "channels": []int{1, 2}, "probe_ratios": []int{1, 10}, "input_range_at_bnc_v": []int{-5, 5}, "coupling": "DC", "captures_have_gaps": true, "gain_calibration": "nominal", "serial": s.serial, "calibration": s.calibration, "firmware": "0210"}
				}
			}
			s.mu.Unlock()
			return r, nil
		case "panel_sync":
			s.panel = PanelReport{a.ID, uint64(a.Revision), a.Page, int(a.Width), int(a.Height), time.Now().UTC()}
			s.mu.Unlock()
			return map[string]any{"success": true}, nil
		default:
			c, e := s.find(a.ID)
			if e != nil {
				s.mu.Unlock()
				return nil, e
			}
			retention := s.retention(c)
			s.mu.Unlock()
			if name == "evaluate" {
				return evaluate(c, a.Checks), nil
			}
			if name == "save" {
				r, e := saveCapture(c)
				if e != nil {
					return nil, fault("SAVE_FAILED", e.Error(), false, "Check writable storage and available disk space.")
				}
				return r, nil
			}
			return response(c, a, retention), nil
		}
	}
	timeout := 8000.0
	if a.Timeout != nil {
		timeout = *a.Timeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Millisecond)
	defer cancel()
	s.op.Lock()
	defer s.op.Unlock()
	s.mu.Lock()
	switch name {
	case "configure":
		next, e := configureSettings(s.settings, a)
		if e != nil {
			s.mu.Unlock()
			return nil, e
		}
		s.settings = next
		s.revision++
		r := s.status()
		s.mu.Unlock()
		return r, nil
	case "retain":
		if a.Action == "release" {
			delete(s.pins, a.ID)
			r := map[string]any{"success": true, "id": a.ID, "pinned": false, "pinned_count": len(s.pins)}
			s.mu.Unlock()
			return r, nil
		}
		c, e := s.find(a.ID)
		if e == nil {
			e = s.pin(c)
		}
		if e != nil {
			s.mu.Unlock()
			return nil, e
		}
		r := map[string]any{"success": true, "id": c.ID, "retention": s.retention(c)}
		s.mu.Unlock()
		return r, nil
	case "stop":
		// Repeated Freeze keeps an explicitly selected older capture.
		if s.running || s.displayed == nil {
			s.displayed = s.latest
			s.displayRevision++
			s.highlight = "none"
		}
		s.running = false
		r := s.status()
		s.mu.Unlock()
		return r, nil
	case "show_capture":
		c, e := s.find(a.ID)
		if e != nil {
			s.mu.Unlock()
			return nil, e
		}
		ch := 1
		if a.Channel != nil {
			ch = int(*a.Channel)
		}
		highlight := a.Highlight
		if highlight == "" {
			highlight = "none"
		}
		s.running = false
		s.displayed = c
		s.displayChannel = ch
		s.highlight = highlight
		s.displayRevision++
		available := highlight == "none" || c.Measurements[ch-1].Cycle != nil
		r := map[string]any{"success": true, "id": c.ID, "running": false, "display": s.displayState(), "highlight_available": available}
		if !available {
			r["highlight_reason"] = "No valid complete cycle is visible in this preview."
		}
		s.mu.Unlock()
		return r, nil
	case "run", "capture":
		settings := s.settings
		if a.Settings != nil {
			settings, err = applyTiming(settings, *a.Settings)
			if err != nil {
				s.mu.Unlock()
				return nil, err
			}
		}
		pinned := name == "capture" && (a.Pin == nil || *a.Pin)
		if pinned && len(s.pins) >= 8 {
			s.mu.Unlock()
			return nil, fault("PIN_LIMIT", "All8 capture pins are in use.", false, "Release a pin before capture, or explicitly use pin:false.")
		}
		if name == "run" {
			s.running = false
			s.starting = true
		}
		s.mu.Unlock()
		var c *Capture
		if err = ctx.Err(); err == nil {
			c, err = s.acquire(ctx, settings)
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		s.starting = false
		if err != nil {
			if name == "run" {
				s.running = false
			}
			s.lastError = toolError(err)
			s.problem = s.lastError.Message
			return nil, s.lastError
		}
		if pinned {
			_ = s.pin(c)
		}
		if name == "run" {
			s.running = true
			s.displayed = nil
			s.highlight = "none"
			s.displayRevision++
			r := s.status()
			r["capture_id"] = c.ID
			return r, nil
		}
		// A one-shot while frozen becomes the displayed capture; live state is preserved.
		if !s.running {
			s.displayed = c
			s.highlight = "none"
			s.displayRevision++
		}
		return response(c, a, s.retention(c)), nil
	}
	s.mu.Unlock()
	return nil, invalid("Unknown tool.")
}
