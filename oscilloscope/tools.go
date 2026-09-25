// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"encoding/json"
	"io"
	"math"
	"strings"
)

func schema(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props, "additionalProperties": false}
}
func integer(values ...int) map[string]any {
	s := map[string]any{"type": "integer"}
	if len(values) > 0 {
		s["enum"] = values
	}
	return s
}
func textEnum(values ...string) map[string]any {
	s := map[string]any{"type": "string"}
	if len(values) > 0 {
		s["enum"] = values
	}
	return s
}
func array(items any) map[string]any                            { return map[string]any{"type": "array", "items": items} }
func required(s map[string]any, names ...string) map[string]any { s["required"] = names; return s }
func toolsList() []map[string]any {
	timeout := integer()
	timeout["minimum"] = 100
	timeout["maximum"] = 15000
	timeout["default"] = 8000
	channel := integer(1, 2)
	channels := array(channel)
	channels["uniqueItems"] = true
	channels["minItems"] = 1
	channels["maxItems"] = 2
	timing := schema(map[string]any{"sample_rate_hz": integer(100000, 200000, 500000, 1000000), "trigger_channel": channel})
	probe := schema(map[string]any{"channel": channel, "ratio": integer(1, 10), "confirmed": map[string]any{"type": "boolean"}})
	required(probe, "channel")
	check := schema(map[string]any{"channel": channel, "metric": textEnum("frequency_hz", "duty_percent", "period_us", "min_v", "max_v", "vpp_v", "mean_v", "rms_v"), "target": map[string]any{"type": "number"}, "tolerance": required(schema(map[string]any{"kind": textEnum("absolute", "relative_percent"), "value": map[string]any{"type": "number", "minimum": 0}}), "kind", "value")})
	required(check, "channel", "metric", "target", "tolerance")
	defs := []struct {
		name, desc string
		props      map[string]any
		req        []string
	}{
		{"status", "Read-only compact state. Optional capabilities, retention and display include limits, pinned IDs, selection and panel-reported viewport. Never opens USB.", map[string]any{"include": array(textEnum("capabilities", "retention", "display"))}, nil},
		{"configure", "Atomically change persistent settings. Probe ratio does NOT confirm the physical switch: use probes[].confirmed=true only after the user confirms it. confirmed=false clears confirmation. Changes affect future captures only.", map[string]any{"sample_rate_hz": integer(100000, 200000, 500000, 1000000), "trigger_channel": channel, "probes": array(probe), "probe_ch1": integer(1, 10), "probe_ch2": integer(1, 10)}, nil},
		{"capture", "Acquire fresh measurements in one call. Default detail=summary, pin=true (8 pins max; release via retain; lost on backend restart), timeout=8000ms. Both channels physically acquired; channels filters output only. Temporary timing settings do not change persistent settings or Run/Freeze state. Captures have gaps.", map[string]any{"settings": timing, "channels": channels, "detail": textEnum("summary", "preview", "raw"), "pin": map[string]any{"type": "boolean", "default": true}, "timeout_ms": timeout}, nil},
		{"read", "Read-only retained capture; default latest summary. An explicit unavailable ID fails, never falls back. Preview: <=4096 consecutive samples/channel; raw: base64 interleaved ADC (both channels). Legacy preview/raw booleans retained; cannot combine with detail.", map[string]any{"id": textEnum(), "channels": channels, "detail": textEnum("summary", "preview", "raw"), "preview": map[string]any{"type": "boolean"}, "raw": map[string]any{"type": "boolean"}}, nil},
		{"retain", "Pin or release a capture idempotently. Pinned captures survive the 16-item live ring until release/backend restart. At most8 pins; displayed capture has a separate reference.", map[string]any{"id": textEnum(), "action": textEnum("pin", "release")}, []string{"id", "action"}},
		{"run", "Start/resume continuous finite captures. Returns success only after fresh acquisition. Timeout or failure leaves acquisition stopped; never schedules a delayed start. Returns a compact status and capture ID. Native USB discovery/close may extend deadline cleanup.", map[string]any{"timeout_ms": timeout}, nil},
		{"stop", "Freeze: idempotently stop acquisition and retain the completed displayed/latest capture. No acquisition. Returns frozen capture ID, null if none.", map[string]any{}, nil},
		{"show_capture", "Freeze acquisition and select exact retained evidence on Scope, optionally highlighting cycle/HIGH. Does not reacquire. Selection is shared with the panel; panel_report is telemetry, not guaranteed rendered acknowledgement. Open panel via Minerva plugin_open_panel if needed.", map[string]any{"id": textEnum(), "channel": channel, "highlight": textEnum("none", "cycle", "high")}, []string{"id"}},
		{"evaluate", "Read-only expectation checks against one capture: pass/fail/inconclusive and bounds. Absolute tolerance uses metric units (duty uses percentage points); relative_percent of target magnitude; zero relative target invalid. Unconfirmed/clipped voltage and invalid timing are inconclusive.", map[string]any{"id": textEnum(), "checks": array(check)}, []string{"id", "checks"}},
		{"save", "Save exact evidence JSON+CSV under plugin-owned directory; no USB or arbitrary path writes. Supply id; omitted id supported for legacy latest-capture callers only.", map[string]any{"id": textEnum()}, nil},
		{"panel_sync", "Panel telemetry only: report displayed ID, applied display revision, page and viewport. Does not change acquisition or selected capture. Intended for the plugin panel, not proof of human observation.", map[string]any{"id": textEnum(), "revision": integer(), "page": textEnum("scope", "measurements", "settings"), "width": integer(), "height": integer()}, []string{"id", "revision", "page", "width", "height"}},
	}
	out := []map[string]any{}
	for _, d := range defs {
		sc := schema(d.props)
		if len(d.req) > 0 {
			required(sc, d.req...)
		}
		out = append(out, map[string]any{"name": d.name, "description": d.desc, "inputSchema": sc})
	}
	return out
}

type TimingArgs struct {
	Rate    *float64 `json:"sample_rate_hz"`
	Trigger *float64 `json:"trigger_channel"`
}
type ProbeArg struct {
	Channel   float64  `json:"channel"`
	Ratio     *float64 `json:"ratio"`
	Confirmed *bool    `json:"confirmed"`
}
type Args struct {
	TimingArgs
	Probe1    *float64    `json:"probe_ch1"`
	Probe2    *float64    `json:"probe_ch2"`
	Probes    []ProbeArg  `json:"probes"`
	ID        string      `json:"id"`
	Include   []string    `json:"include"`
	Channels  []float64   `json:"channels"`
	Detail    string      `json:"detail"`
	Preview   *bool       `json:"preview"`
	Raw       *bool       `json:"raw"`
	Pin       *bool       `json:"pin"`
	Timeout   *float64    `json:"timeout_ms"`
	Settings  *TimingArgs `json:"settings"`
	Action    string      `json:"action"`
	Channel   *float64    `json:"channel"`
	Highlight string      `json:"highlight"`
	Checks    []Check     `json:"checks"`
	Revision  float64     `json:"revision"`
	Page      string      `json:"page"`
	Width     float64     `json:"width"`
	Height    float64     `json:"height"`
}

func parseArgs(name string, raw json.RawMessage) (a Args, err error) {
	if len(raw) == 0 {
		raw = json.RawMessage(`{}`)
	}
	var keys map[string]json.RawMessage
	if e := json.Unmarshal(raw, &keys); e != nil || keys == nil {
		return a, invalid("Arguments must be an object.")
	}
	var sc map[string]any
	for _, t := range toolsList() {
		if t["name"] == name {
			sc = t["inputSchema"].(map[string]any)
		}
	}
	if sc == nil {
		return a, invalid("Unknown tool.")
	}
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return a, invalid(err.Error())
	}
	if err := validateSchema(value, sc, "arguments"); err != nil {
		return a, err
	}
	props := sc["properties"].(map[string]any)
	for k, v := range keys {
		if _, ok := props[k]; !ok {
			return a, invalid("Unexpected argument: " + k)
		}
		if string(v) == "null" {
			return a, invalid("Null argument: " + k)
		}
	}
	if req, ok := sc["required"].([]string); ok {
		for _, k := range req {
			if _, ok := keys[k]; !ok {
				return a, invalid("Missing argument: " + k)
			}
		}
	}
	d := json.NewDecoder(strings.NewReader(string(raw)))
	d.DisallowUnknownFields()
	if e := d.Decode(&a); e != nil {
		return a, invalid(e.Error())
	}
	if e := d.Decode(new(any)); e != io.EOF {
		return a, invalid("Unexpected trailing JSON.")
	}
	if a.ID == "" {
		if _, ok := keys["id"]; ok && name != "panel_sync" {
			return a, invalid("id must not be empty.")
		}
	}
	if a.Detail != "" && a.Detail != "summary" && a.Detail != "preview" && a.Detail != "raw" {
		return a, invalid("Unknown detail.")
	}
	if a.Detail != "" && (a.Preview != nil || a.Raw != nil) {
		return a, invalid("Do not combine detail and legacy preview/raw flags.")
	}
	if _, ok := keys["detail"]; ok && a.Detail == "" {
		return a, invalid("detail must not be empty.")
	}
	if a.Timeout != nil && (!whole(*a.Timeout) || *a.Timeout < 100 || *a.Timeout > 15000) {
		return a, invalid("timeout_ms must be an integer100..15000.")
	}
	if _, ok := keys["channels"]; ok && len(a.Channels) == 0 {
		return a, invalid("channels must contain1 or2.")
	}
	seen := map[float64]bool{}
	for _, ch := range a.Channels {
		if (ch != 1 && ch != 2) || seen[ch] {
			return a, invalid("channels must be unique1/2.")
		}
		seen[ch] = true
	}
	for _, inc := range a.Include {
		if inc != "capabilities" && inc != "retention" && inc != "display" {
			return a, invalid("Unknown include.")
		}
	}
	if a.Channel != nil && *a.Channel != 1 && *a.Channel != 2 {
		return a, invalid("channel must be1 or2.")
	}
	if name == "retain" && a.Action != "pin" && a.Action != "release" {
		return a, invalid("action must be pin or release.")
	}
	if a.Highlight != "" && a.Highlight != "none" && a.Highlight != "cycle" && a.Highlight != "high" {
		return a, invalid("Unknown highlight.")
	}
	if name == "evaluate" {
		if e := validateChecks(a.Checks); e != nil {
			return a, e
		}
	}
	if name == "panel_sync" {
		if a.Page != "scope" && a.Page != "measurements" && a.Page != "settings" {
			return a, invalid("Unknown page.")
		}
		for _, v := range []float64{a.Revision, a.Width, a.Height} {
			if !whole(v) || v < 0 || v > 9007199254740991 {
				return a, invalid("Invalid panel telemetry.")
			}
		}
		if a.Width > 32768 || a.Height > 32768 {
			return a, invalid("Invalid viewport size.")
		}
	}
	return a, nil
}
func whole(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) && math.Trunc(v) == v }
func applyTiming(next Settings, a TimingArgs) (Settings, error) {
	if a.Rate != nil {
		if !whole(*a.Rate) {
			return next, invalid("Invalid sample rate.")
		}
		if _, ok := rates[int(*a.Rate)]; !ok {
			return next, invalid("Unsupported sample rate.")
		}
		next.Rate = int(*a.Rate)
	}
	if a.Trigger != nil {
		if *a.Trigger != 1 && *a.Trigger != 2 {
			return next, invalid("trigger_channel must be1 or2.")
		}
		next.Trigger = int(*a.Trigger)
	}
	return next, nil
}
func configureSettings(current Settings, a Args) (Settings, error) {
	next, err := applyTiming(current, a.TimingArgs)
	if err != nil {
		return current, err
	}
	seen := map[int]bool{}
	for i, p := range []*float64{a.Probe1, a.Probe2} {
		if p != nil {
			if *p != 1 && *p != 10 {
				return current, invalid("Probe ratio must be1 or10.")
			}
			seen[i+1] = true
			if next.Probe[i] != int(*p) {
				next.Confirmed[i] = false
			}
			next.Probe[i] = int(*p)
		}
	}
	for _, p := range a.Probes {
		if p.Channel != 1 && p.Channel != 2 {
			return current, invalid("Probe channel must be1 or2.")
		}
		ch := int(p.Channel)
		if seen[ch] {
			return current, invalid("Duplicate probe channel.")
		}
		seen[ch] = true
		if p.Ratio == nil && p.Confirmed == nil {
			return current, invalid("Probe needs ratio or confirmed.")
		}
		if p.Ratio != nil {
			if *p.Ratio != 1 && *p.Ratio != 10 {
				return current, invalid("Probe ratio must be1 or10.")
			}
			if next.Probe[ch-1] != int(*p.Ratio) {
				next.Confirmed[ch-1] = false
			}
			next.Probe[ch-1] = int(*p.Ratio)
		}
		if p.Confirmed != nil {
			next.Confirmed[ch-1] = *p.Confirmed
		}
	}
	return next, nil
}
func response(c *Capture, a Args, retention map[string]any) map[string]any {
	detail := a.Detail
	if detail == "" {
		detail = "summary"
	}
	if a.Preview != nil && *a.Preview {
		detail = "preview"
	}
	if a.Raw != nil && *a.Raw {
		detail = "raw"
	}
	result := map[string]any{"success": true, "id": c.ID, "timestamp": c.Timestamp, "settings": c.Settings, "settings_revision": c.SettingsRevision, "duration_us": float64(c.Settings.Samples) * 1e6 / float64(c.Settings.Rate), "calibration": c.Calibration, "retention": retention, "trigger_index": c.TriggerIndex, "settling_samples_discarded": c.SettlingSamples, "preview_start_sample": c.PreviewStart, "preview_stride": c.PreviewStride, "zero_adc": c.ZeroADC, "volts_per_count_at_bnc": c.VoltsPerCountAtBNC}
	channels := a.Channels
	if len(channels) == 0 {
		channels = []float64{1, 2}
	}
	records := []map[string]any{}
	for _, v := range channels {
		ch := int(v)
		r := map[string]any{"channel": ch, "measurement": c.Measurements[ch-1]}
		if detail == "preview" {
			r["preview_v"] = c.Preview[ch-1]
			r["preview_sample_count"] = len(c.Preview[ch-1])
		}
		records = append(records, r)
	}
	result["channels"] = records
	if detail == "raw" {
		result["raw_interleaved_u8"] = c.Raw
		result["raw_encoding"] = "base64_u8_interleaved_ch1_ch2"
	}
	// Legacy flags request the original indexed shape as well.
	if a.Preview != nil || a.Raw != nil {
		result["measurements"] = c.Measurements
		if a.Preview != nil && *a.Preview {
			result["preview_v"] = c.Preview
		}
	}
	return result
}
