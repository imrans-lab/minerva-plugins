package board

// Fabrication-stage validation and round-trip (DCR 01a0033a12a9 change 3).
//
// The stage is what the connectivity census reads to decide whether an
// unrouted net is a DEFECT or the entire point of the job, so the two things
// worth pinning here are (a) that an unknown token cannot travel — in either
// direction a silent default is wrong, and (b) that "vias_only" is not a mere
// synonym of "routing_deferred", which is only true while the board's own
// contents are checked against the declaration.
//
// Uses layers_validate_test.go's wantCode/wantValid helpers, same package.

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func stageBoard(stage string, traces ...Trace) *Board {
	return &Board{Version: 1, Name: "S", WidthMM: 20, HeightMM: 20,
		FabricationStage: stage, Traces: traces}
}

func TestFabricationStageAcceptsKnownTokens(t *testing.T) {
	// ABSENT is the default board and must stay valid — every board that
	// existed before this field.
	wantValid(t, stageBoard(""))
	wantValid(t, stageBoard(FabStageRouted))
	wantValid(t, stageBoard(FabStageRoutingDeferred))
	wantValid(t, stageBoard(FabStageViasOnly))
}

func TestFabricationStageRefusesUnknownToken(t *testing.T) {
	// A typo must NOT fall back to "routed" (which would re-report a via-only
	// board as a wall of defects) nor to a deferred stage (which would excuse a
	// board someone genuinely abandoned half-routed). It refuses.
	for _, bad := range []string{"vias-only", "viasonly", "VIAS_ONLY", "deferred", "unrouted"} {
		wantCode(t, stageBoard(bad), "invalid_fabrication_stage")
	}
}

func TestViasOnlyRefusesABoardThatHasTraces(t *testing.T) {
	// The declaration has to be TRUE. Without this the two deferred stages are
	// synonyms and the narrower one carries no information at all.
	b := stageBoard(FabStageViasOnly, Trace{Net: "N1", Layer: "top"})
	wantCode(t, b, "invalid_fabrication_stage")
	err := Validate(b)
	// The refusal must NAME the alternative, or the user is stuck holding a
	// board the tool refuses without saying what to declare instead.
	if !strings.Contains(err.Error(), FabStageRoutingDeferred) {
		t.Fatalf("refusal must point at %q, got %q", FabStageRoutingDeferred, err.Error())
	}
	// ...and the SAME board declaring the looser stage is fine, which is what
	// makes the refusal a routing decision rather than a dead end.
	wantValid(t, stageBoard(FabStageRoutingDeferred, Trace{Net: "N1", Layer: "top"}))
}

func TestRoutingIsDeferredIsTheOnePredicate(t *testing.T) {
	cases := map[string]bool{
		"":                      false,
		FabStageRouted:          false,
		FabStageRoutingDeferred: true,
		FabStageViasOnly:        true,
	}
	for stage, want := range cases {
		if got := stageBoard(stage).RoutingIsDeferred(); got != want {
			t.Fatalf("RoutingIsDeferred(%q) = %v, want %v", stage, got, want)
		}
	}
}

func TestFabricationStageYAMLRoundTrip(t *testing.T) {
	// A DECLARED stage survives a round trip...
	in := stageBoard(FabStageViasOnly)
	blob, err := yaml.Marshal(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(blob), "fabrication_stage: vias_only") {
		t.Fatalf("stage missing from YAML:\n%s", blob)
	}
	var out Board
	if err := yaml.Unmarshal(blob, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.FabricationStage != FabStageViasOnly {
		t.Fatalf("round-trip lost the stage: %q", out.FabricationStage)
	}

	// ...and an UNDECLARED one emits no key at all, so every existing board's
	// YAML — and every golden built from one — is byte-identical to before this
	// field existed. omitempty is load-bearing, not cosmetic.
	plain, err := yaml.Marshal(stageBoard(""))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(plain), "fabrication_stage") {
		t.Fatalf("undeclared stage must emit no key, got:\n%s", plain)
	}
}
