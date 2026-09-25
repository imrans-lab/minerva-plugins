package main

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
)

func TestCaptureAndControlContract(t *testing.T) {
	settings := Settings{Rate: 200000, Samples: 8192, Probe: [2]int{1, 10}, Confirmed: [2]bool{true, false}, Trigger: 1}
	raw := make([]byte, settings.Samples*2)
	for i := 0; i < settings.Samples; i++ {
		raw[2*i] = 125
		if i%2000 < 1000 {
			raw[2*i] = 207
		}
		raw[2*i+1] = 135
	}
	c := makeCapture(raw, settings, [2]float64{125, 135}, "test zero", 1)
	m := c.Measurements[0]
	if m.Frequency == nil || math.Abs(*m.Frequency-100) > .1 || m.Duty == nil || math.Abs(*m.Duty-50) > .1 {
		t.Fatalf("timing: %+v", m)
	}
	if m.PeriodUS == nil || *m.PeriodUS != 10000 || m.Cycle == nil || m.Cycle.Start != 2000 || m.Cycle.End != 4000 || m.Cycle.Threshold != 1.64 {
		t.Fatalf("cycle evidence: %+v", m)
	}
	if m.Cycle.Start < c.PreviewStart || m.Cycle.End >= c.PreviewStart+len(c.Preview[0]) {
		t.Fatal("cycle outside preview")
	}
	if c.Measurements[1].Cycle != nil || c.Measurements[1].PeriodUS != nil {
		t.Fatal("flat channel has timing evidence")
	}
	if math.Abs(m.Vpp-3.28) > 1e-9 || m.Min != 0 || c.TriggerIndex < 0 {
		t.Fatalf("scaling or trigger: %+v", c)
	}
	if c.Measurements[1].Frequency != nil {
		t.Fatal("flat channel reported a frequency")
	}
	if len(c.Preview[0]) != 4096 {
		t.Fatal("preview size")
	}
	if _, e := json.Marshal(c); e != nil {
		t.Fatal(e)
	}
	s := &Server{settings: settings, latest: c, captures: []*Capture{c}}
	if _, e := s.call("configure", json.RawMessage(`{"sample_rate_hz":500000,"probe_ch1":3}`)); e == nil {
		t.Fatal("invalid setting accepted")
	}
	if s.settings != settings {
		t.Fatal("failed configure partially applied")
	}
	if _, e := s.call("configure", json.RawMessage(`{"sample_rate_hz":500000,"probe_ch1":10}`)); e != nil {
		t.Fatal(e)
	}
	if c.Settings.Probe[0] != 1 || c.Settings.Rate != 200000 {
		t.Fatal("capture settings mutated")
	}
	r, e := s.call("read", json.RawMessage(`{}`))
	if e != nil {
		t.Fatal(e)
	}
	if r.(Capture).Raw != nil {
		t.Fatal("default reply contains raw")
	}
	if _, e = s.call("read", json.RawMessage(`{"id":"expired"}`)); e == nil {
		t.Fatal("expired capture silently replaced")
	}
	// The short high-frequency waveform is explicitly under-sampled.
	for i := range raw {
		raw[i] = 125
		if i%8 < 4 {
			raw[i] = 207
		}
	}
	fast := makeCapture(raw, settings, [2]float64{125, 135}, "test", 2)
	if fast.Measurements[0].Frequency != nil {
		t.Fatal("undersampled timing reported")
	}
}
func TestFirmwareValidation(t *testing.T) {
	valid := ":03000000010203F7\n:00000001FF\n"
	records, e := parseFirmware(valid)
	if e != nil || len(records) != 1 {
		t.Fatalf("valid image: %v", e)
	}
	for _, bad := range []string{strings.Replace(valid, "F7", "F8", 1), ":00000001FF\n", strings.Split(valid, "\n")[0], valid + valid, ":03E6000001020311\n:00000001FF\n"} {
		if _, e := parseFirmware(bad); e == nil {
			t.Fatalf("bad firmware accepted: %q", bad)
		}
	}
}
