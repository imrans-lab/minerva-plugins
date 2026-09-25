// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"
)

// op serializes mutations and USB ownership. mu protects state only and is
// released during hardware I/O so readers never wait behind a USB transfer.
type Server struct {
	op                           sync.Mutex
	mu                           sync.Mutex
	out                          sync.Mutex
	hw                           Hardware
	settings                     Settings
	revision                     uint64
	running, starting, connected bool
	problem                      string
	lastError                    *ToolError
	seq                          uint64
	session                      string
	serial, calibration          string
	latest                       *Capture
	captures                     []*Capture
	pins                         map[string]*Capture
	displayed                    *Capture
	displayRevision              uint64
	displayChannel               int
	highlight                    string
	panel                        PanelReport
	stopping                     chan struct{}
}
type PanelReport struct {
	ID       string    `json:"id"`
	Revision uint64    `json:"revision"`
	Page     string    `json:"page"`
	Width    int       `json:"width"`
	Height   int       `json:"height"`
	Seen     time.Time `json:"seen_at"`
}

func newServer() *Server {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return &Server{settings: Settings{Rate: 200000, Samples: 8192, Probe: [2]int{1, 1}, Trigger: 1}, session: hex.EncodeToString(b), pins: map[string]*Capture{}, highlight: "none", stopping: make(chan struct{})}
}
func (s *Server) send(v any) {
	s.out.Lock()
	defer s.out.Unlock()
	_ = json.NewEncoder(os.Stdout).Encode(v)
}
func (s *Server) status() map[string]any {
	acquisition := "idle"
	if s.running {
		acquisition = "running"
	}
	if s.starting {
		acquisition = "starting"
	}
	if s.lastError != nil {
		acquisition = "error"
	}
	st := map[string]any{"success": true, "connected": s.connected, "running": s.running, "acquisition_state": acquisition, "error": s.problem, "last_error": s.lastError, "settings": s.settings, "settings_revision": s.revision, "model": "Hantek 6022BE"}
	st["latest_capture_id"] = nil
	st["latest_age_ms"] = nil
	if s.latest != nil {
		st["latest_capture_id"] = s.latest.ID
		t, _ := time.Parse(time.RFC3339Nano, s.latest.Timestamp)
		st["latest_age_ms"] = time.Since(t).Milliseconds()
	}
	st["displayed_capture_id"] = nil
	if c := s.displayCapture(); c != nil {
		st["displayed_capture_id"] = c.ID
	}
	return st
}
func (s *Server) displayCapture() *Capture {
	if s.displayed != nil {
		return s.displayed
	}
	return s.latest
}
func (s *Server) displayState() map[string]any {
	id := ""
	if c := s.displayCapture(); c != nil {
		id = c.ID
	}
	return map[string]any{"capture_id": id, "revision": s.displayRevision, "channel": s.displayChannel, "highlight": s.highlight, "mode": map[bool]string{true: "live", false: "frozen"}[s.running], "panel_report": s.panel, "panel_recent": !s.panel.Seen.IsZero() && time.Since(s.panel.Seen) < 5*time.Second, "render_confirmed": false}
}
func (s *Server) find(id string) (*Capture, error) {
	if id == "" {
		if s.latest != nil {
			return s.latest, nil
		}
		return nil, fault("NO_CAPTURE", "No capture yet.", false, "Call capture or run.")
	}
	if c := s.pins[id]; c != nil {
		return c, nil
	}
	if s.displayed != nil && s.displayed.ID == id {
		return s.displayed, nil
	}
	for _, c := range s.captures {
		if c.ID == id {
			return c, nil
		}
	}
	return nil, fault("CAPTURE_EXPIRED", "Capture is unavailable in this session.", false, "Acquire a new capture; pin evidence you need to retain.")
}
func (s *Server) remember(c *Capture) {
	s.latest = c
	s.captures = append(s.captures, c)
	if len(s.captures) > 16 {
		s.captures = s.captures[len(s.captures)-16:]
	}
}
func (s *Server) pin(c *Capture) error {
	if s.pins == nil {
		s.pins = map[string]*Capture{}
	}
	if s.pins[c.ID] != nil {
		return nil
	}
	if len(s.pins) >= 8 {
		return fault("PIN_LIMIT", "All 8 capture pins are in use.", false, "Release a pin with retain before acquiring another pinned capture.")
	}
	s.pins[c.ID] = c
	return nil
}
func (s *Server) retention(c *Capture) map[string]any {
	kind := "live_ring"
	if s.displayed == c {
		kind = "display"
	}
	if s.pins[c.ID] != nil {
		kind = "pinned"
	}
	return map[string]any{"kind": kind, "lifetime": "backend_session", "pinned_count": len(s.pins), "pin_limit": 8}
}
func (s *Server) acquire(ctx context.Context, settings Settings) (*Capture, error) {
	// Caller owns op. Hardware state is copied into public state only under mu.
	s.mu.Lock()
	connected := s.connected
	revision := s.revision
	s.mu.Unlock()
	var err error
	if !connected {
		err = s.hw.Open(ctx)
	}
	var raw []byte
	if err == nil {
		raw, err = s.hw.Capture(ctx, settings.Rate, settings.Samples)
	}
	if err == nil {
		err = ctx.Err()
	}
	if err != nil {
		s.hw.Close()
		s.mu.Lock()
		s.connected = false
		s.lastError = toolError(err)
		s.problem = s.lastError.Message
		s.mu.Unlock()
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.connected = true
	s.serial = s.hw.serial
	s.calibration = s.hw.calibration
	s.lastError = nil
	s.problem = ""
	s.seq++
	c := makeCapture(raw, settings, s.hw.zero, s.hw.calibration, s.seq)
	c.ID = fmt.Sprintf("%s-%d", s.session, s.seq)
	c.SettingsRevision = revision
	s.remember(c)
	return c, nil
}
func (s *Server) worker() {
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-s.stopping:
			return
		case <-tick.C:
			s.op.Lock()
			s.mu.Lock()
			running := s.running
			settings := s.settings
			s.mu.Unlock()
			if running {
				ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
				_, err := s.acquire(ctx, settings)
				cancel()
				if err != nil {
					s.mu.Lock()
					s.running = false
					s.displayed = s.latest
					s.displayRevision++
					s.mu.Unlock()
				}
			}
			s.op.Unlock()
		}
	}
}
func (s *Server) pinIDs() []string {
	ids := []string{}
	for id := range s.pins {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}
