package main

import (
	"encoding/hex"
	"testing"
	"time"
)

// Raw packets captured from the owner's B41T+ on 2026-09-23 plus the
// encodings the reference clients agree on for the paths not yet captured.
func TestDecode(t *testing.T) {
	cases := []struct {
		raw, function, display string
		value                  float64
		flags                  []string
		overload               bool
	}{
		{"24f004000000", "V DC", "0.0000 V", 0, []string{"auto"}, false},
		{"24f004001500", "V DC", "0.0021 V", 0.0021, []string{"auto"}, false},
		{"24f004001e00", "V DC", "0.0030 V", 0.003, []string{"auto"}, false},
		// negative: sign bit set on 0x0015
		{"24f004001580", "V DC", "-0.0021 V", -0.0021, []string{"auto"}, false},
		// negative zero must read as zero, not -0
		{"24f004000080", "V DC", "0.0000 V", 0, []string{"auto"}, false},
		// resistance, kΩ, two decimals, hold + auto: fn=4 prefix=5 dec=2 -> w0 = 4<<6|5<<3|2 = 0x012a
		{"2a0105002c01", "Resistance", "3.00 kΩ", 3.0, []string{"hold", "auto"}, false},
		// overload via decimals==7
		{"27f004000000", "V DC", "OL", 0, []string{"auto"}, true},
	}
	at := time.Unix(0, 0)
	for _, c := range cases {
		pkt, _ := hex.DecodeString(c.raw)
		r, err := Decode(pkt, at)
		if err != nil {
			t.Fatalf("%s: %v", c.raw, err)
		}
		if r.Function != c.function || r.Display != c.display || r.Overload != c.overload {
			t.Errorf("%s: got %s %q ol=%v, want %s %q ol=%v", c.raw, r.Function, r.Display, r.Overload, c.function, c.display, c.overload)
		}
		if r.Value != c.value {
			t.Errorf("%s: value %v, want %v", c.raw, r.Value, c.value)
		}
		if len(r.Flags) != len(c.flags) {
			t.Errorf("%s: flags %v, want %v", c.raw, r.Flags, c.flags)
			continue
		}
		for i := range c.flags {
			if r.Flags[i] != c.flags[i] {
				t.Errorf("%s: flags %v, want %v", c.raw, r.Flags, c.flags)
			}
		}
	}
	if _, err := Decode([]byte{1, 2}, at); err == nil {
		t.Error("short packet must fail")
	}
}
