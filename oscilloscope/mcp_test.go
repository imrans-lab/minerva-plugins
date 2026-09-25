package main

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

func fixture(s *Server, n uint64) *Capture {
	settings := Settings{Rate: 200000, Samples: 8192, Probe: [2]int{1, 1}, Trigger: 1}
	raw := make([]byte, settings.Samples*2)
	for i := 0; i < settings.Samples; i++ {
		raw[2*i] = 125
		if i%2000 < 1000 {
			raw[2*i] = 207
		}
		raw[2*i+1] = 135
	}
	c := makeCapture(raw, settings, [2]float64{125, 135}, "test", n)
	c.ID = s.session + "-" + stringID(n)
	return c
}
func stringID(n uint64) string { b, _ := json.Marshal(n); return string(b) }
func invoke(t *testing.T, s *Server, name, args string) map[string]any {
	t.Helper()
	v, e := s.call(name, json.RawMessage(args))
	if e != nil {
		t.Fatal(name, e)
	}
	return v.(map[string]any)
}
func expectCode(t *testing.T, s *Server, name, args, code string) {
	t.Helper()
	_, e := s.call(name, json.RawMessage(args))
	if e == nil || toolError(e).Code != code {
		t.Fatalf("%s: expected %s got %v", name, code, e)
	}
}
func TestMCPRetainedEvidenceAndDisplay(t *testing.T) {
	s := newServer()
	c := fixture(s, 1)
	s.remember(c)
	r := invoke(t, s, "read", `{}`)
	b, _ := json.Marshal(r)
	if len(b) > 4096 || strings.Contains(string(b), "preview_v") || strings.Contains(string(b), "raw_interleaved") {
		t.Fatalf("not a compact summary (%d)", len(b))
	}
	if r["channels"].([]map[string]any)[0]["channel"] != 1 {
		t.Fatal("missing named channel")
	}
	invoke(t, s, "retain", `{"id":"`+c.ID+`","action":"pin"}`)
	for n := uint64(2); n < 30; n++ {
		s.remember(fixture(s, n))
	}
	r = invoke(t, s, "read", `{"id":"`+c.ID+`","channels":[1],"detail":"preview"}`)
	if len(r["channels"].([]map[string]any)) != 1 {
		t.Fatal("channel filtering")
	}
	invoke(t, s, "show_capture", `{"id":"`+c.ID+`","channel":1,"highlight":"cycle"}`)
	if s.displayed != c || s.running {
		t.Fatal("display state")
	}
	invoke(t, s, "retain", `{"id":"`+c.ID+`","action":"release"}`)
	invoke(t, s, "retain", `{"id":"`+c.ID+`","action":"release"}`)
	invoke(t, s, "stop", `{}`)
	if s.displayed != c {
		t.Fatal("Freeze lost selected evidence")
	}
	invoke(t, s, "read", `{"id":"`+c.ID+`"}`)
	for n := uint64(30); n < 38; n++ {
		next := fixture(s, n)
		s.remember(next)
		if e := s.pin(next); e != nil {
			t.Fatal(e)
		}
	}
	expectCode(t, s, "capture", `{}`, "PIN_LIMIT")
	if s.seq != 0 {
		t.Fatal("pin limit touched USB")
	}
	expectCode(t, s, "read", `{"id":"expired"}`, "CAPTURE_EXPIRED")
	for _, args := range []string{`{"detail":"raw","preview":true}`, `{"channels":[1,1]}`, `{"channels":[]}`, `{"detail":null}`, `{"sample_rate_hz":200000}`, `{"channels":[1.5]}`} {
		expectCode(t, s, "read", args, "INVALID_ARGUMENT")
	}
	// A new session cannot accidentally resolve an old evidence ID.
	other := newServer()
	other.remember(fixture(other, 1))
	expectCode(t, other, "read", `{"id":"`+c.ID+`"}`, "CAPTURE_EXPIRED")
}
func TestMCPSettingsAndQualityChecks(t *testing.T) {
	s := newServer()
	c := fixture(s, 1)
	s.remember(c)
	invoke(t, s, "configure", `{"probe_ch1":10}`)
	if s.settings.Confirmed[0] {
		t.Fatal("ratio inferred confirmation")
	}
	invoke(t, s, "configure", `{"probes":[{"channel":1,"confirmed":true}]}`)
	if !s.settings.Confirmed[0] {
		t.Fatal("explicit confirmation not applied")
	}
	before := s.settings
	for _, args := range []string{`{"sample_rate_hz":500000,"probes":[{"channel":2,"ratio":3}]}`, `{"probes":[{"channel":1,"confirmed":null}]}`, `{"probes":[{"ratio":10}]}`, `{"probes":[{"channel":1,"confirmed":true,"extra":3}]}`} {
		expectCode(t, s, "configure", args, "INVALID_ARGUMENT")
		if s.settings != before {
			t.Fatal("partial settings update")
		}
	}
	invoke(t, s, "configure", `{"probes":[{"channel":1,"ratio":1}]}`)
	if s.settings.Confirmed[0] {
		t.Fatal("ratio change retained stale confirmation")
	}
	if c.Settings.Probe[0] != 1 || c.Settings.Confirmed[0] {
		t.Fatal("capture mutated")
	}
	checks := `{"id":"` + c.ID + `","checks":[{"channel":1,"metric":"frequency_hz","target":100,"tolerance":{"kind":"relative_percent","value":2}},{"channel":1,"metric":"duty_percent","target":45,"tolerance":{"kind":"absolute","value":5}}]}`
	r := invoke(t, s, "evaluate", checks)
	if r["verdict"] != "pass" {
		t.Fatal(r)
	}
	r = invoke(t, s, "evaluate", `{"id":"`+c.ID+`","checks":[{"channel":1,"metric":"max_v","target":3.28,"tolerance":{"kind":"absolute","value":0.1}}]}`)
	if r["verdict"] != "inconclusive" {
		t.Fatal(r)
	}
	r = invoke(t, s, "evaluate", `{"id":"`+c.ID+`","checks":[{"channel":2,"metric":"frequency_hz","target":100,"tolerance":{"kind":"absolute","value":2}},{"channel":1,"metric":"frequency_hz","target":1000,"tolerance":{"kind":"absolute","value":2}}]}`)
	if r["verdict"] != "fail" {
		t.Fatal(r)
	}
	expectCode(t, s, "evaluate", `{"id":"`+c.ID+`","checks":[{"channel":1,"metric":"mean_v","target":0,"tolerance":{"kind":"relative_percent","value":2}}]}`, "INVALID_ARGUMENT")
	expectCode(t, s, "evaluate", `{"id":"`+c.ID+`","checks":[]}`, "INVALID_ARGUMENT")
}
func TestMCPDeadlineAndConcurrentReaders(t *testing.T) {
	s := newServer()
	s.remember(fixture(s, 1))
	s.op.Lock()
	done := make(chan error, 1)
	go func() { _, err := s.call("run", json.RawMessage(`{"timeout_ms":100}`)); done <- err }()
	// Read access remains available while USB ownership is held elsewhere.
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 10; j++ {
				if _, err := s.call("read", json.RawMessage(`{}`)); err != nil {
					t.Error(err)
				}
			}
		}()
	}
	wg.Wait()
	time.Sleep(150 * time.Millisecond)
	s.op.Unlock()
	err := <-done
	if err == nil || toolError(err).Code != "ACQUISITION_TIMEOUT" {
		t.Fatal(err)
	}
	if s.running || s.starting || s.seq != 0 {
		t.Fatal("expired run started acquisition")
	}
}
