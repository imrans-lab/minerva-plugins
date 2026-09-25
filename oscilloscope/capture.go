// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"fmt"
	"math"
	"time"
)

type Settings struct {
	Rate      int     `json:"sample_rate_hz"`
	Samples   int     `json:"samples_per_channel"`
	Probe     [2]int  `json:"probe_ratio"`
	Confirmed [2]bool `json:"probe_confirmed"`
	Trigger   int     `json:"trigger_channel"`
}
type Cycle struct {
	Start     int     `json:"start_sample"`
	End       int     `json:"end_sample"`
	Threshold float64 `json:"threshold_v"`
}

type Measurement struct {
	PeriodUS  *float64 `json:"period_us"`
	Cycle     *Cycle   `json:"visible_cycle"`
	Min       float64  `json:"min_v"`
	Max       float64  `json:"max_v"`
	Vpp       float64  `json:"vpp_v"`
	Mean      float64  `json:"mean_v"`
	RMS       float64  `json:"rms_v"`
	Frequency *float64 `json:"frequency_hz"`
	Duty      *float64 `json:"duty_percent"`
	Clipped   bool     `json:"clipped"`
	Flags     []string `json:"quality_flags"`
}
type Capture struct {
	SettingsRevision   uint64         `json:"settings_revision"`
	Success            bool           `json:"success"`
	SettlingSamples    int            `json:"settling_samples_discarded"`
	ZeroADC            [2]float64     `json:"zero_adc"`
	VoltsPerCountAtBNC float64        `json:"volts_per_count_at_bnc"`
	ID                 string         `json:"id"`
	Timestamp          string         `json:"timestamp"`
	Settings           Settings       `json:"settings"`
	Calibration        string         `json:"calibration"`
	Measurements       [2]Measurement `json:"measurements"`
	TriggerIndex       int            `json:"trigger_index"`
	Raw                []byte         `json:"raw_interleaved_u8,omitempty"`
	Preview            [2][]float64   `json:"preview_v,omitempty"`
	PreviewStart       int            `json:"preview_start_sample"`
	PreviewStride      int            `json:"preview_stride"`
}

// Timing uses hysteresis and complete cycles only. Flat traces and undersampled
// edges have no frequency rather than a misleading numeric zero.
func measure(v []float64, raw []byte, rate int, confirmed bool) (m Measurement, first int) {
	// Godot validates JSON numeric round trips. Six decimal places exceed
	// this 8-bit instrument's precision and avoid binary-tail mismatches.
	defer func() {
		for _, p := range []*float64{&m.Min, &m.Max, &m.Vpp, &m.Mean, &m.RMS, m.Frequency, m.Duty, m.PeriodUS} {
			if p != nil {
				*p = math.Round(*p*1e6) / 1e6
			}
		}
	}()
	m.Flags = []string{}
	first = -1
	m.Min = math.Inf(1)
	m.Max = math.Inf(-1)
	for i, x := range v {
		m.Min = math.Min(m.Min, x)
		m.Max = math.Max(m.Max, x)
		m.Mean += x
		m.RMS += x * x
		if raw[i] <= 1 || raw[i] >= 254 {
			m.Clipped = true
		}
	}
	m.Mean /= float64(len(v))
	m.RMS = math.Sqrt(m.RMS / float64(len(v)))
	m.Vpp = m.Max - m.Min
	if !confirmed {
		m.Flags = append(m.Flags, "probe_attenuation_unconfirmed")
	}
	if m.Clipped {
		m.Flags = append(m.Flags, "input_clipped")
	}
	if m.Vpp < 0.15 {
		m.Flags = append(m.Flags, "no_clear_periodic_signal")
		return
	}
	rises := risingEdges(v, m.Min, m.Vpp)
	if len(rises) < 3 {
		m.Flags = append(m.Flags, "too_few_cycles")
		return
	}
	first = rises[0]
	period := float64(rises[len(rises)-1]-rises[0]) / float64(len(rises)-1)
	if period < 10 {
		m.Flags = append(m.Flags, "too_few_samples_per_cycle")
		return
	}
	for i := 1; i < len(rises); i++ {
		if math.Abs(float64(rises[i]-rises[i-1])-period) > math.Max(2, period*.1) {
			m.Flags = append(m.Flags, "irregular_period")
			return
		}
	}
	f := float64(rate) / period
	m.Frequency = &f
	periodUS := period * 1e6 / float64(rate)
	m.PeriodUS = &periodUS
	mid := (m.Min + m.Max) / 2
	highCount := 0
	for _, x := range v[rises[0]:rises[len(rises)-1]] {
		if x > mid {
			highCount++
		}
	}
	duty := float64(highCount) * 100 / float64(rises[len(rises)-1]-rises[0])
	m.Duty = &duty
	return
}

// Use the same hysteresis for timing measurements and visible cycle evidence.
func risingEdges(v []float64, min, vpp float64) []int {
	low, high := min+vpp*.35, min+vpp*.65
	armed := false
	var rises []int
	for i, x := range v {
		if x < low {
			armed = true
		}
		if armed && x > high {
			rises = append(rises, i)
			armed = false
		}
	}
	return rises
}

func makeCapture(raw []byte, settings Settings, zero [2]float64, cal string, seq uint64) *Capture {
	c := &Capture{Success: true, SettlingSamples: 512, ZeroADC: zero, VoltsPerCountAtBNC: 0.04, ID: fmt.Sprintf("%d-%d", time.Now().UnixMilli(), seq), Timestamp: time.Now().UTC().Format(time.RFC3339Nano), Settings: settings, Calibration: cal, Raw: raw, TriggerIndex: -1, PreviewStride: 1}
	var volts [2][]float64
	for ch := 0; ch < 2; ch++ {
		volts[ch] = make([]float64, len(raw)/2)
		adc := make([]byte, len(raw)/2)
		for i := range volts[ch] {
			adc[i] = raw[2*i+ch]
			volts[ch][i] = math.Round((float64(adc[i])-zero[ch])*.04*float64(settings.Probe[ch])*1e6) / 1e6
		}
		m, edge := measure(volts[ch], adc, settings.Rate, settings.Confirmed[ch])
		c.Measurements[ch] = m
		if ch == settings.Trigger-1 {
			c.TriggerIndex = edge
		}
	}
	// Preview preserves every sample in the first 4096 points after a rising
	// edge; tools expose full raw capture separately. No hidden decimation.
	start := 0
	if c.TriggerIndex >= 0 {
		start = c.TriggerIndex - 20
		if start < 0 {
			start = 0
		}
	}
	end := start + 4096
	if end > len(raw)/2 {
		end = len(raw) / 2
	}
	c.PreviewStart = start
	for ch := 0; ch < 2; ch++ {
		c.Preview[ch] = append([]float64(nil), volts[ch][start:end]...)
		m := &c.Measurements[ch]
		if m.Frequency != nil {
			rises := risingEdges(volts[ch], m.Min, m.Vpp)
			for i := 1; i < len(rises); i++ {
				if rises[i-1] >= start && rises[i] < end {
					m.Cycle = &Cycle{Start: rises[i-1], End: rises[i], Threshold: math.Round((m.Min+m.Max)/2*1e6) / 1e6}
					break
				}
			}
		}
	}
	return c
}
