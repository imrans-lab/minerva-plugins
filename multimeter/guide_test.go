package main

import "testing"

func TestSlotFor(t *testing.T) {
	cases := []struct{ function, prefix, want string }{
		{"V DC", "", "V"}, {"V AC", "", "V"}, {"V DC", "m", "mV"},
		{"Resistance", "k", "OHM"}, {"Continuity", "", "OHM"}, {"Diode", "", "OHM"},
		{"Capacitance", "n", "CAP"}, {"Frequency", "k", "HZ"}, {"Duty cycle", "", "HZ"},
		{"Temperature", "", "TEMP"}, {"A DC", "µ", "uA"}, {"A AC", "m", "mA"}, {"A DC", "", "A"},
		{"NCV", "", ""},
	}
	for _, c := range cases {
		if got := slotFor(Reading{Function: c.function, Prefix: c.prefix}); got != c.want {
			t.Errorf("%s/%s: got %q want %q", c.function, c.prefix, got, c.want)
		}
	}
	for _, slot := range dialSlots[1:] {
		if _, ok := jackForSlot[slot]; !ok {
			t.Errorf("slot %s has no jack", slot)
		}
	}
}
