// SPDX-License-Identifier: GPL-3.0-or-later
package main

import "math"

type Tolerance struct {
	Kind  string   `json:"kind"`
	Value *float64 `json:"value"`
}
type Check struct {
	Channel   float64   `json:"channel"`
	Metric    string    `json:"metric"`
	Target    *float64  `json:"target"`
	Tolerance Tolerance `json:"tolerance"`
}

func metric(m Measurement, key string) *float64 {
	switch key {
	case "frequency_hz":
		return m.Frequency
	case "duty_percent":
		return m.Duty
	case "period_us":
		return m.PeriodUS
	case "min_v":
		return &m.Min
	case "max_v":
		return &m.Max
	case "vpp_v":
		return &m.Vpp
	case "mean_v":
		return &m.Mean
	case "rms_v":
		return &m.RMS
	}
	return nil
}
func timingMetric(key string) bool {
	return key == "frequency_hz" || key == "duty_percent" || key == "period_us"
}
func round6(v float64) float64 { return math.Round(v*1e6) / 1e6 }
func bounds(c Check) (float64, float64) {
	t := *c.Tolerance.Value
	if c.Tolerance.Kind == "relative_percent" {
		t = math.Abs(*c.Target) * t / 100
	}
	return round6(*c.Target - t), round6(*c.Target + t)
}
func validateChecks(checks []Check) error {
	if len(checks) == 0 || len(checks) > 32 {
		return invalid("Provide1..32 checks.")
	}
	for _, c := range checks {
		if c.Channel != 1 && c.Channel != 2 {
			return invalid("Check channel must be1 or2.")
		}
		switch c.Metric {
		case "frequency_hz", "duty_percent", "period_us", "min_v", "max_v", "vpp_v", "mean_v", "rms_v":
		default:
			return invalid("Unknown metric.")
		}
		if c.Target == nil || c.Tolerance.Value == nil {
			return invalid("Check requires target and tolerance.value.")
		}
		if c.Tolerance.Kind != "absolute" && c.Tolerance.Kind != "relative_percent" {
			return invalid("Tolerance kind must be absolute or relative_percent.")
		}
		if math.IsNaN(*c.Target) || math.IsInf(*c.Target, 0) || math.Abs(*c.Target) > 1e12 || math.IsNaN(*c.Tolerance.Value) || math.IsInf(*c.Tolerance.Value, 0) || *c.Tolerance.Value < 0 || *c.Tolerance.Value > 1e6 {
			return invalid("Target magnitude must be <=1e12; tolerance must be0..1e6.")
		}
		if c.Tolerance.Kind == "relative_percent" && *c.Target == 0 {
			return invalid("Use absolute tolerance for a zero target.")
		}
		lo, hi := bounds(c)
		if math.Abs(lo) > 1e12 || math.Abs(hi) > 1e12 {
			return invalid("Resolved bounds must have magnitude <=1e12.")
		}
	}
	return nil
}
func evaluate(c *Capture, checks []Check) map[string]any {
	results := []map[string]any{}
	overall := "pass"
	for _, check := range checks {
		m := c.Measurements[int(check.Channel)-1]
		v := metric(m, check.Metric)
		lo, hi := bounds(check)
		verdict := "pass"
		reasons := []string{}
		if timingMetric(check.Metric) {
			if v == nil {
				for _, flag := range m.Flags {
					if flag != "probe_attenuation_unconfirmed" && flag != "input_clipped" {
						reasons = append(reasons, flag)
					}
				}
				if len(reasons) == 0 {
					reasons = append(reasons, "timing_unavailable")
				}
			}
		} else {
			if !c.Settings.Confirmed[int(check.Channel)-1] {
				reasons = append(reasons, "probe_attenuation_unconfirmed")
			}
			if m.Clipped {
				reasons = append(reasons, "input_clipped")
			}
		}
		if len(reasons) > 0 || v == nil {
			verdict = "inconclusive"
		} else if *v < lo || *v > hi {
			verdict = "fail"
		}
		if verdict == "fail" {
			overall = "fail"
		} else if verdict == "inconclusive" && overall != "fail" {
			overall = "inconclusive"
		}
		results = append(results, map[string]any{"channel": int(check.Channel), "metric": check.Metric, "measured": v, "target": check.Target, "lower": lo, "upper": hi, "verdict": verdict, "reasons": reasons})
	}
	return map[string]any{"success": true, "id": c.ID, "verdict": overall, "checks": results, "bounds_decimal_places": 6}
}
