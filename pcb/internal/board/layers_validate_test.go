package board

// Layer-stack validation tests (epoch GA-1). validateLayers itself shipped in
// epoch 6 with NO Go tests (the fallout was filed, 019fb59164b6); GA-1 makes
// the stack load-bearing — the Python compiler now RESOLVES a declared stack
// instead of refusing depth — so the four shape codes and the two new
// copper-entity membership codes (validateCopperEntityLayers) are pinned here,
// on the same first-violation-wins terms board_validate.py mirrors. The
// cross-language vectors (spec/vectors/320..340) cover the flagship cases;
// these unit tests cover the full refusal matrix vectors would bloat on.

import (
	"strings"
	"testing"
)

func layerBoard(layers ...string) *Board {
	return &Board{Version: 1, Name: "L", WidthMM: 20, HeightMM: 20, Layers: layers}
}

func wantCode(t *testing.T, b *Board, code string) {
	t.Helper()
	err := Validate(b)
	if err == nil {
		t.Fatalf("expected %s, got valid", code)
	}
	if !strings.HasPrefix(err.Error(), code+":") {
		t.Fatalf("expected code %s, got %q", code, err.Error())
	}
}

func wantValid(t *testing.T, b *Board) {
	t.Helper()
	if err := Validate(b); err != nil {
		t.Fatalf("expected valid, got %q", err.Error())
	}
}

func TestValidateLayersShapes(t *testing.T) {
	// The absent declaration is the 2-layer default and validates.
	wantValid(t, layerBoard())
	wantValid(t, layerBoard("top", "bottom"))
	wantValid(t, layerBoard("top", "in1", "in2", "bottom"))
	// KiCad's full 32-copper stack is the deepest legal declaration.
	full := []string{"top"}
	for k := 1; k <= MaxInnerLayers; k++ {
		full = append(full, "in"+itoa(k))
	}
	full = append(full, "bottom")
	wantValid(t, layerBoard(full...))

	wantCode(t, layerBoard("top", "inner1", "bottom"), "invalid_layer_name")
	wantCode(t, layerBoard("top", "in0", "bottom"), "invalid_layer_name")
	wantCode(t, layerBoard("top", "in01", "bottom"), "invalid_layer_name")
	wantCode(t, layerBoard("top", "in31", "bottom"), "invalid_layer_name")
	wantCode(t, layerBoard("top", "In1.Cu", "bottom"), "invalid_layer_name")
	wantCode(t, layerBoard("top", "top", "bottom"), "duplicate_layer")
	wantCode(t, layerBoard("top"), "incomplete_layer_stack")
	wantCode(t, layerBoard("in1", "in2"), "incomplete_layer_stack")
	wantCode(t, layerBoard("bottom", "top"), "invalid_layer_stack_order")
	wantCode(t, layerBoard("top", "bottom", "in1"), "invalid_layer_stack_order")
	// Contiguity: a gap asserts a layer the board refuses to name.
	wantCode(t, layerBoard("top", "in2", "bottom"), "invalid_layer_stack_order")
	wantCode(t, layerBoard("top", "in1", "in3", "bottom"), "invalid_layer_stack_order")
	wantCode(t, layerBoard("top", "in2", "in1", "bottom"), "invalid_layer_stack_order")
}

func itoa(k int) string {
	// strconv-free tiny helper keeps the imports minimal for a test file.
	if k < 10 {
		return string(rune('0' + k))
	}
	return string(rune('0'+k/10)) + string(rune('0'+k%10))
}

func TestCopperEntityLayerMembership(t *testing.T) {
	stack := []string{"top", "in1", "bottom"}

	// A trace on a declared inner layer is valid; off-stack refuses.
	onStack := layerBoard(stack...)
	onStack.Traces = []Trace{{Net: "N", Layer: "in1",
		Points: []Point{{XMM: 1, YMM: 1}, {XMM: 2, YMM: 2}}}}
	wantValid(t, onStack)

	offStack := layerBoard(stack...)
	offStack.Traces = []Trace{{Net: "N", Layer: "in3",
		Points: []Point{{XMM: 1, YMM: 1}, {XMM: 2, YMM: 2}}}}
	wantCode(t, offStack, "trace_unknown_layer")

	// KiCad spelling is refused literally, the zone-membership rule exactly:
	// the canonical contract stores canonical ids.
	kicadSpelled := layerBoard(stack...)
	kicadSpelled.Traces = []Trace{{Net: "N", Layer: "F.Cu",
		Points: []Point{{XMM: 1, YMM: 1}, {XMM: 2, YMM: 2}}}}
	wantCode(t, kicadSpelled, "trace_unknown_layer")

	// Via endpoints: each half checked, from before to.
	badFrom := layerBoard(stack...)
	badFrom.Vias = []Via{{XMM: 5, YMM: 5, DrillMM: 0.4, DiameterMM: 0.8,
		FromLayer: "in9", ToLayer: "bottom"}}
	wantCode(t, badFrom, "via_unknown_layer")

	badTo := layerBoard(stack...)
	badTo.Vias = []Via{{XMM: 5, YMM: 5, DrillMM: 0.4, DiameterMM: 0.8,
		FromLayer: "top", ToLayer: "in9"}}
	wantCode(t, badTo, "via_unknown_layer")

	// EMPTY layer fields stay legal (omitempty; pre-GA-1 boards rely on the
	// downstream defaults) — presence is what makes a name checkable.
	emptyFields := layerBoard(stack...)
	emptyFields.Traces = []Trace{{Net: "N",
		Points: []Point{{XMM: 1, YMM: 1}, {XMM: 2, YMM: 2}}}}
	emptyFields.Vias = []Via{{XMM: 5, YMM: 5, DrillMM: 0.4, DiameterMM: 0.8}}
	wantValid(t, emptyFields)

	// NO declared stack — nothing to check against; any name passes here
	// (the documented zone-precedent fail-open; the compiler's resolved-stack
	// membership still governs downstream).
	undeclared := layerBoard()
	undeclared.Traces = []Trace{{Net: "N", Layer: "in7",
		Points: []Point{{XMM: 1, YMM: 1}, {XMM: 2, YMM: 2}}}}
	wantValid(t, undeclared)

	// Order: a broken STACK reports the stack code, not a derived membership
	// code — layers validate first, the load-bearing ordering Validate pins.
	brokenBoth := layerBoard("bottom", "top")
	brokenBoth.Traces = []Trace{{Net: "N", Layer: "in3",
		Points: []Point{{XMM: 1, YMM: 1}, {XMM: 2, YMM: 2}}}}
	wantCode(t, brokenBoth, "invalid_layer_stack_order")
}
