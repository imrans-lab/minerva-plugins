package tools

// Tests for the board-load enrichment's ADOPTION POLICY (WYSIWYG goal
// 019ff4a5a75a, gap G1) — which keys a load takes from the worker's
// resolve_best_effort reply, and which it must refuse.
//
// The policy is deliberately tested WITHOUT a live worker: resolvedByRef and
// adoptResolvedGeometry are pure over their inputs, and the bridge call they
// sit behind degrades on its own (attachFootprintGraphics never fails a load).
// Before these tests the enrichment had NO Go-side coverage at all — the
// original graphics-only adoption shipped untested, which is part of how the
// pad-dropping deferral could sit unnoticed while every loaded board rendered
// approximate pads behind a permanent badge.

import (
	"encoding/json"
	"testing"

	"github.com/imrans-lab/minerva-plugins/pcb/internal/board"
)

// resolveReply builds the worker reply shape resolvedByRef consumes.
func resolveReply(t *testing.T, components ...map[string]interface{}) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(map[string]interface{}{
		"board": map[string]interface{}{"components": components},
	})
	if err != nil {
		t.Fatalf("marshal reply: %v", err)
	}
	return raw
}

var padDict = map[string]interface{}{
	"number": "1", "type": "thru_hole", "shape": "circle",
	"position": map[string]float64{"x": 0, "y": 0},
	"size":     map[string]float64{"width": 1.6, "height": 1.6},
	"drill":    map[string]float64{"x": 0.8, "y": 0.8},
}

func TestResolvedByRefIndexesPadsOnlyWhenTheReplyMarksThemResolved(t *testing.T) {
	byRef := resolvedByRef(resolveReply(t,
		map[string]interface{}{
			"ref": "TP1", "has_pad_geometry": true,
			"graphics": []interface{}{map[string]interface{}{"kind": "circle"}},
			"pads":     []interface{}{padDict},
		},
		// The worker echoes a component's own INLINE pads through the resolve
		// even when its footprint did not resolve. Taking them would re-import
		// the caller's fallback data wearing a resolved label.
		map[string]interface{}{
			"ref": "U9", "has_pad_geometry": false,
			"pads": []interface{}{padDict},
		},
		// Nothing resolved at all -> omitted, so the adopter can distinguish
		// "resolved to nothing" from "not resolved".
		map[string]interface{}{"ref": "X1", "has_pad_geometry": false},
	))

	tp1, ok := byRef["TP1"]
	if !ok || !tp1.hasPadGeometry || len(tp1.pads) != 1 || len(tp1.graphics) != 1 {
		t.Fatalf("TP1 should index graphics AND resolved pads, got %+v", tp1)
	}
	if u9, ok := byRef["U9"]; ok && u9.hasPadGeometry {
		t.Fatalf("U9's unresolved inline pads were indexed as resolved: %+v", u9)
	}
	if _, ok := byRef["X1"]; ok {
		t.Fatalf("X1 resolved to nothing and must be omitted entirely")
	}
}

func TestAdoptionAttachesPadsAndMarkerTogether(t *testing.T) {
	b := &board.Board{Components: []board.Component{{Ref: "TP1"}}}
	n := adoptResolvedGeometry(b, map[string]resolvedComponent{
		"TP1": {
			graphics:       []interface{}{map[string]interface{}{"kind": "circle"}},
			pads:           []interface{}{padDict},
			hasPadGeometry: true,
		},
	})
	if n != 1 {
		t.Fatalf("attached = %d, want 1", n)
	}
	extra := b.Components[0].Extra
	if _, ok := extra["graphics"]; !ok {
		t.Fatalf("graphics not adopted")
	}
	if _, ok := extra["pads"]; !ok {
		t.Fatalf("pads not adopted — this is the deferral that left every "+
			"loaded board rendering fallback discs with no drill holes; got %v", extra)
	}
	if got, _ := extra["has_pad_geometry"].(bool); !got {
		t.Fatalf("has_pad_geometry not stamped alongside the adopted pads")
	}
}

func TestAdoptionNeverOverwritesAuthoredData(t *testing.T) {
	authored := []interface{}{map[string]interface{}{"number": "authored"}}
	b := &board.Board{Components: []board.Component{{
		Ref: "TP1",
		Extra: map[string]interface{}{
			"graphics": authored,
			"pads":     authored,
		},
	}}}
	n := adoptResolvedGeometry(b, map[string]resolvedComponent{
		"TP1": {
			graphics:       []interface{}{map[string]interface{}{"kind": "derived"}},
			pads:           []interface{}{padDict},
			hasPadGeometry: true,
		},
	})
	if n != 0 {
		t.Fatalf("attached = %d over authored data, want 0", n)
	}
	extra := b.Components[0].Extra
	got, _ := extra["pads"].([]interface{})
	if len(got) != 1 || got[0].(map[string]interface{})["number"] != "authored" {
		t.Fatalf("authored pads were overwritten: %v", got)
	}
	// THE LAUNDERING GUARD: has_pad_geometry asserts the pads ARE the
	// footprint's real geometry. Stamping it while keeping authored pads
	// would retire the badge on a component whose render is NOT resolved.
	if _, ok := extra["has_pad_geometry"]; ok {
		t.Fatalf("has_pad_geometry stamped over authored pads — badge laundering")
	}
}

func TestAdoptionIsPerKeyNotAllOrNothing(t *testing.T) {
	authoredGraphics := []interface{}{map[string]interface{}{"kind": "authored"}}
	b := &board.Board{Components: []board.Component{{
		Ref:   "TP1",
		Extra: map[string]interface{}{"graphics": authoredGraphics},
	}}}
	n := adoptResolvedGeometry(b, map[string]resolvedComponent{
		"TP1": {
			graphics:       []interface{}{map[string]interface{}{"kind": "derived"}},
			pads:           []interface{}{padDict},
			hasPadGeometry: true,
		},
	})
	if n != 1 {
		t.Fatalf("attached = %d, want 1 (pads adopted beside authored graphics)", n)
	}
	extra := b.Components[0].Extra
	if extra["graphics"].([]interface{})[0].(map[string]interface{})["kind"] != "authored" {
		t.Fatalf("authored graphics were overwritten")
	}
	if _, ok := extra["pads"]; !ok {
		t.Fatalf("pads should adopt independently of the graphics key")
	}
}

func TestAdoptionCarriesThePrintedDesignator(t *testing.T) {
	strokes := []interface{}{map[string]interface{}{
		"layer": "F.SilkS", "kind": "poly",
		"points": []interface{}{[]interface{}{0.0, -1.5}, []interface{}{0.5, -1.5}},
		"width":  0.15,
	}}
	byRef := resolvedByRef(resolveReply(t,
		// A silk-only footprint: designator + graphics, NO pads. It must still
		// be indexed (and adopted) — before refdes existed, "resolved to
		// nothing adoptable" and "silk-only" were indistinguishable.
		map[string]interface{}{
			"ref": "REV1", "has_pad_geometry": false,
			"graphics":        []interface{}{map[string]interface{}{"kind": "line"}},
			"refdes_graphics": strokes,
		},
	))
	rev1, ok := byRef["REV1"]
	if !ok || len(rev1.refdesGraphics) != 1 {
		t.Fatalf("silk-only component's designator strokes not indexed: %+v", rev1)
	}

	b := &board.Board{Components: []board.Component{{Ref: "REV1"}}}
	if n := adoptResolvedGeometry(b, byRef); n != 1 {
		t.Fatalf("attached = %d, want 1", n)
	}
	if _, ok := b.Components[0].Extra["refdes_graphics"]; !ok {
		t.Fatalf("refdes_graphics not adopted — the panel would keep showing "+
			"UI labels instead of the strokes the fab prints; got %v",
			b.Components[0].Extra)
	}
	if _, ok := b.Components[0].Extra["has_pad_geometry"]; ok {
		t.Fatalf("has_pad_geometry stamped on a pad-less component")
	}
}

func TestAdoptionCarriesTheComponentLevelResolvedFact(t *testing.T) {
	// The COMPONENT-level fact (bug 019ff4a9a0d7): a silk-only footprint
	// resolves with zero pads, so has_pad_geometry stays honestly false —
	// footprint_resolved is what lets the badge distinguish "resolved,
	// nothing left to resolve" from "fallback pins".
	byRef := resolvedByRef(resolveReply(t,
		map[string]interface{}{
			"ref": "LOGO1", "footprint_resolved": true,
			"has_pad_geometry": false,
			"graphics":         []interface{}{map[string]interface{}{"kind": "poly"}},
		},
		map[string]interface{}{"ref": "X1", "footprint_resolved": false},
	))
	if logo, ok := byRef["LOGO1"]; !ok || !logo.footprintResolved {
		t.Fatalf("resolved silk-only component's fact not indexed: %+v", byRef["LOGO1"])
	}
	if _, ok := byRef["X1"]; ok {
		t.Fatalf("an unresolved component with nothing adoptable must be omitted")
	}

	b := &board.Board{Components: []board.Component{{Ref: "LOGO1"}}}
	if n := adoptResolvedGeometry(b, byRef); n != 1 {
		t.Fatalf("attached = %d, want 1", n)
	}
	if got, _ := b.Components[0].Extra["footprint_resolved"].(bool); !got {
		t.Fatalf("footprint_resolved not adopted: %v", b.Components[0].Extra)
	}
}
