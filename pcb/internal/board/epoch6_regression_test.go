package board

// Regression guards for the epoch-6 HITL fix batch (owner ruling amendment of
// 2026-07-30: regressions for HITL-found defects are filed as docket test
// items and authored where automatable).
//
//   - TestValidateZonesKeepoutNetless — docket 019fb64f22b3: a keepout zone is
//     netless (owner ruling "Keepouts don't need net connections", shipped at
//     85f90ed); a NAMED net on a keepout is still checked; a pour still
//     requires a declared net. Python parity lives in
//     worker/tests/test_epoch6_regressions.py — the two validators must agree.

import (
	"strings"
	"testing"
)

func zoneFixtureBoard(z Zone) *Board {
	return &Board{
		Version: 1,
		Nets:    []Net{{Name: "GND"}},
		Layers:  []string{"top", "bottom"},
		Zones:   []Zone{z},
	}
}

func triangleOutline() []Point {
	return []Point{{XMM: 0, YMM: 0}, {XMM: 10, YMM: 0}, {XMM: 0, YMM: 10}}
}

func TestValidateZonesKeepoutNetless(t *testing.T) {
	cases := []struct {
		name    string
		zone    Zone
		wantErr string // "" = valid
	}{
		{"keepout with no net is valid",
			Zone{Kind: ZoneKindKeepout, Layer: "top", Outline: triangleOutline()}, ""},
		{"keepout with a declared net stays valid",
			Zone{Kind: ZoneKindKeepout, Net: "GND", Layer: "top", Outline: triangleOutline()}, ""},
		{"keepout naming an undeclared net is still checked",
			Zone{Kind: ZoneKindKeepout, Net: "NOPE", Layer: "top", Outline: triangleOutline()}, "zone_unknown_net"},
		{"pour with no net is refused",
			Zone{Kind: ZoneKindCopperPour, Layer: "top", Outline: triangleOutline()}, "zone_unknown_net"},
		{"unknown kind is refused before the net rule",
			Zone{Kind: "exclusion", Net: "GND", Layer: "top", Outline: triangleOutline()}, "invalid_zone_kind"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateZones(zoneFixtureBoard(tc.zone))
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("expected valid, got %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("expected error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}
