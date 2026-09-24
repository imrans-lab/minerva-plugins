package main

import (
	"encoding/json"
	"sync"
	"time"
)

// Dial slots on the B41T+ rotary switch, clockwise from OFF. A reading maps
// to the slot the dial must be on to produce it, which is how the guide
// panel shows "you are here" and how wait_for knows the user turned the dial.
var dialSlots = []string{"OFF", "V", "mV", "OHM", "HZ", "CAP", "TEMP", "uA", "mA", "A"}

// slotFor derives the dial slot from a decoded reading. The mV position is
// the only one the packet does not name outright: it reports V with a
// milli prefix, which the V position never does.
func slotFor(r Reading) string {
	switch r.Function {
	case "V DC", "V AC":
		if r.Prefix == "m" {
			return "mV"
		}
		return "V"
	case "Resistance", "Continuity", "Diode":
		return "OHM"
	case "Capacitance":
		return "CAP"
	case "Frequency", "Duty cycle":
		return "HZ"
	case "Temperature":
		return "TEMP"
	case "A DC", "A AC":
		switch r.Prefix {
		case "µ":
			return "uA"
		case "m":
			return "mA"
		}
		return "A"
	}
	return ""
}

// Jacks along the bottom edge, left to right, and which one the red lead
// uses for each slot. COM always takes the black lead.
var jackForSlot = map[string]string{
	"V": "VOHM", "mV": "VOHM", "OHM": "VOHM", "HZ": "VOHM", "CAP": "VOHM",
	"TEMP": "MAUA", "uA": "MAUA", "mA": "MAUA", "A": "20A",
}

// Guide is what the LLM asked the user to do, mirrored into plugin state
// for the guide panel.
type Guide struct {
	Slot        string `json:"slot"`
	RedJack     string `json:"red_jack"`
	Instruction string `json:"instruction"`
	Warning     string `json:"warning,omitempty"`
	SetAt       string `json:"set_at"`
}

type guideStore struct {
	mu    sync.Mutex
	guide *Guide
}

func (g *guideStore) Set(guide Guide) {
	g.mu.Lock()
	defer g.mu.Unlock()
	guide.SetAt = time.Now().Format(time.RFC3339)
	g.guide = &guide
}

func (g *guideStore) Clear() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.guide = nil
}

func (g *guideStore) Get() *Guide {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.guide
}

// toolGuideSet validates the target and records it.
func (s *server) toolGuideSet(args json.RawMessage) map[string]interface{} {
	var a struct {
		Slot        string `json:"slot"`
		Instruction string `json:"instruction"`
		Warning     string `json:"warning"`
	}
	json.Unmarshal(args, &a)
	jack, ok := jackForSlot[a.Slot]
	if !ok {
		return toolErr("bad_slot", "slot must be one of V, mV, OHM, HZ, CAP, TEMP, uA, mA, A")
	}
	if a.Warning == "" && (a.Slot == "uA" || a.Slot == "mA" || a.Slot == "A") {
		a.Warning = "Current is measured in series. Never put the leads across a voltage source in this mode: the fuse blows."
	}
	s.guide.Set(Guide{Slot: a.Slot, RedJack: jack, Instruction: a.Instruction, Warning: a.Warning})
	s.pushState()
	return map[string]interface{}{"success": true, "guide": s.guide.Get(), "live": s.liveDial()}
}

// toolWaitFor blocks until the meter reports the wanted slot (default: the
// guide's slot), optionally also a settled non-zero reading, or the timeout
// passes. With a cursor, a journal edge after it that already meets the
// condition answers at once. The timeout stays under the host's MCP
// deadline; callers re-invoke for longer waits.
func (s *server) toolWaitFor(args json.RawMessage) map[string]interface{} {
	var a struct {
		Slot     string   `json:"slot"`
		NonZero  bool     `json:"nonzero"`
		SettleMs float64  `json:"settle_ms"`
		Timeout  float64  `json:"timeout_s"`
		Cursor   *float64 `json:"cursor"`
	}
	json.Unmarshal(args, &a)
	if a.Slot == "" {
		if g := s.guide.Get(); g != nil {
			a.Slot = g.Slot
		}
	}
	if _, ok := jackForSlot[a.Slot]; !ok {
		return toolErr("bad_slot", "no slot given and no guide is set")
	}
	if a.Cursor != nil {
		if e, ok := s.changes.lastMatch(int(*a.Cursor), a.Slot, a.NonZero); ok {
			return map[string]interface{}{"success": true, "matched": true, "edge": e, "reading": e.Reading, "waited_s": 0}
		}
	}
	if a.Timeout <= 0 || a.Timeout > 25 {
		a.Timeout = 20
	}
	if a.SettleMs <= 0 {
		a.SettleMs = 1000
	}
	deadline := time.Now().Add(time.Duration(a.Timeout * float64(time.Second)))
	var since time.Time
	start := time.Now()
	for {
		st := s.meter.Status()
		if last, has := st["last"].(Reading); has && slotFor(last) == a.Slot && (!a.NonZero || (last.Value != 0 && !last.Overload)) {
			if since.IsZero() {
				since = time.Now()
			}
			if time.Since(since) >= time.Duration(a.SettleMs*float64(time.Millisecond)) {
				return map[string]interface{}{"success": true, "matched": true, "reading": last, "waited_s": time.Since(start).Seconds()}
			}
		} else {
			since = time.Time{}
		}
		if time.Now().After(deadline) {
			out := map[string]interface{}{"success": true, "matched": false, "waited_s": time.Since(start).Seconds(), "live": s.liveDial()}
			if last, has := st["last"]; has {
				out["reading"] = last
			}
			return out
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// liveDial is the slot the meter is on right now, or OFF when it is away.
func (s *server) liveDial() map[string]interface{} {
	st := s.meter.Status()
	if last, has := st["last"].(Reading); has && st["connected"] == true {
		return map[string]interface{}{"slot": slotFor(last), "function": last.Function, "prefix": last.Prefix}
	}
	return map[string]interface{}{"slot": "OFF", "function": "", "prefix": ""}
}
