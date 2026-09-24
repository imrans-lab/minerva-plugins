package main

import (
	"encoding/hex"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// The OWON B41T+ notifies one 6-byte packet per reading on characteristic
// 0xFFF4: three little-endian uint16 words.
//
//	word0  bits 6-9 function, bits 3-5 SI prefix, bits 0-2 decimal places (7 = overload)
//	word1  status flag bits (hold, rel, auto, low battery, min, max, overload, max/min)
//	word2  sign-magnitude value: bit 15 sign, bits 0-14 digits
//
// Confirmed against luissantos/multimeter_gui and jtcash/OwonB41T, and against
// live captures from the owner's meter (see decode_test.go).

const packetLen = 6

var functions = []struct{ name, unit string }{
	{"V DC", "V"}, {"V AC", "V"}, {"A DC", "A"}, {"A AC", "A"},
	{"Resistance", "Ω"}, {"Capacitance", "F"}, {"Frequency", "Hz"}, {"Duty cycle", "%"},
	{"Temperature", "°C"}, {"Temperature", "°F"}, {"Diode", "V"}, {"Continuity", "Ω"},
	{"hFE", ""}, {"NCV", ""},
}

var prefixes = []string{"%", "n", "µ", "m", "", "k", "M", "G"}

var flagNames = []string{"hold", "rel", "auto", "low_battery", "min", "max", "overload", "maxmin"}

// Reading is one decoded measurement. Value is in the displayed unit
// (prefix applied by the caller if a base-unit number is wanted).
type Reading struct {
	Timestamp time.Time `json:"timestamp"`
	Function  string    `json:"function"`
	Unit      string    `json:"unit"`
	Prefix    string    `json:"prefix"`
	Value     float64   `json:"value"`
	Display   string    `json:"display"`
	Overload  bool      `json:"overload"`
	Flags     []string  `json:"flags"`
	Raw       string    `json:"raw"`
	Slot      string    `json:"slot"` // rotary-dial position this reading implies, see guide.go
}

// Decode turns one notification packet into a Reading.
func Decode(pkt []byte, at time.Time) (Reading, error) {
	if len(pkt) < packetLen {
		return Reading{}, fmt.Errorf("packet too short: %d bytes", len(pkt))
	}
	w0 := uint16(pkt[0]) | uint16(pkt[1])<<8
	w1 := uint16(pkt[2]) | uint16(pkt[3])<<8
	w2 := uint16(pkt[4]) | uint16(pkt[5])<<8

	fn := int(w0>>6) & 0xF
	if fn >= len(functions) {
		return Reading{}, fmt.Errorf("unknown function code %d", fn)
	}
	r := Reading{
		Timestamp: at,
		Function:  functions[fn].name,
		Unit:      functions[fn].unit,
		Prefix:    prefixes[(w0>>3)&7],
		Flags:     []string{},
		Raw:       hex.EncodeToString(pkt[:packetLen]),
	}
	// Duty cycle carries its unit as the "%" prefix slot; fold it into the unit.
	if r.Unit == "%" {
		r.Prefix = ""
	}
	for i, name := range flagNames {
		if w1&(1<<i) != 0 {
			r.Flags = append(r.Flags, name)
		}
	}
	decimals := int(w0 & 7)
	if decimals == 7 || w1&(1<<6) != 0 {
		// JSON has no infinity, so an overload carries value 0 and the flag.
		r.Overload = true
		r.Value = 0
		r.Display = "OL"
		r.Slot = slotFor(r)
		return r, nil
	}
	digits := float64(w2 & 0x7FFF)
	if w2&0x8000 != 0 && digits != 0 {
		digits = -digits
	}
	r.Value = digits / math.Pow10(decimals)
	r.Display = strings.TrimSpace(strconv.FormatFloat(r.Value, 'f', decimals, 64) + " " + r.Prefix + r.Unit)
	r.Slot = slotFor(r)
	return r, nil
}
