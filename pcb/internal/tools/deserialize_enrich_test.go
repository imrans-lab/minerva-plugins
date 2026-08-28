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

// THE DESIGNATOR TRAVELS AS AN ANCHOR, NOT AS A PICTURE.
// Pre-anchor replies carried the rendered strokes, adoption was absent-only,
// and a board saved with a component's strokes handed them straight back on
// the next load — so a part copied from another drew the SOURCE's designator
// for the rest of the board's life. What is adopted now is where the footprint
// prints its reference; the renderer strokes the component's own ref there.
//
// Oracle: a document that arrives carrying strokes must lose them, and must
// come back out carrying the anchor this host's resolve just measured.
func TestAdoptionCarriesTheDesignatorAnchorAndDropsSavedStrokes(t *testing.T) {
	anchor := map[string]interface{}{
		"x_mm": 0.0, "y_mm": -1.5, "rotation_deg": 0.0,
		"size_mm": 1.0, "hidden": false,
	}
	byRef := resolvedByRef(resolveReply(t,
		// A silk-only footprint: designator anchor + graphics, NO pads. It
		// must still be indexed (and adopted) — before refdes existed,
		// "resolved to nothing adoptable" and "silk-only" were
		// indistinguishable.
		map[string]interface{}{
			"ref": "REV1", "has_pad_geometry": false,
			"graphics":      []interface{}{map[string]interface{}{"kind": "line"}},
			"refdes_anchor": anchor,
		},
	))
	rev1, ok := byRef["REV1"]
	if !ok || len(rev1.refdesAnchor) != 5 {
		t.Fatalf("silk-only component's designator anchor not indexed: %+v", rev1)
	}

	// The board as an OLD document delivers it: someone else's strokes, under
	// this component's ref.
	b := &board.Board{Components: []board.Component{{Ref: "REV1",
		Extra: map[string]interface{}{"refdes_graphics": []interface{}{
			map[string]interface{}{
				"layer": "F.SilkS", "kind": "poly",
				"points": []interface{}{
					[]interface{}{0.0, -1.5}, []interface{}{0.5, -1.5}},
				"width": 0.15,
			}}}}}}
	dropDerivedComponentKeys(b)
	if n := adoptResolvedGeometry(b, byRef); n != 1 {
		t.Fatalf("attached = %d, want 1", n)
	}
	if _, ok := b.Components[0].Extra["refdes_graphics"]; ok {
		t.Fatalf("the document's saved designator strokes survived the load — "+
			"a copied part would go on drawing the ref it was copied from; got %v",
			b.Components[0].Extra)
	}
	got, _ := b.Components[0].Extra["refdes_anchor"].(map[string]interface{})
	if len(got) != 5 || got["y_mm"] != -1.5 {
		t.Fatalf("refdes_anchor not adopted — the panel would draw every "+
			"designator at the default anchor; got %v", b.Components[0].Extra)
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

// A DOCUMENT'S OWN footprint_resolved is not evidence about THIS host. Boards
// saved before the flag became session state carry it, and adoption is
// absent-only — so without the drop the flag survives a load on a machine
// whose library cannot supply the ref, the panel's wire trim believes it, and
// the worker is handed a component with no lands and no way to resolve any.
//
// Oracle: the same board through the same enrichment, once where the resolve
// answers for the ref and once where it does not. The flag must follow the
// RESOLVE, not the document.
func TestDeserializeDropsTheDocumentsOwnResolvedFlag(t *testing.T) {
	docBoard := func() *board.Board {
		return &board.Board{Components: []board.Component{
			{Ref: "J1", Extra: map[string]interface{}{"footprint_resolved": true}},
		}}
	}

	// No resolve behind it: the flag the document carried must not survive.
	stale := docBoard()
	dropDerivedComponentKeys(stale)
	adoptResolvedGeometry(stale, map[string]resolvedComponent{})
	if _, ok := stale.Components[0].Extra["footprint_resolved"]; ok {
		t.Fatalf("a saved footprint_resolved survived a load this host never resolved: %v",
			stale.Components[0].Extra)
	}

	// This host's own resolve answers for the ref: the flag is stamped back.
	live := docBoard()
	dropDerivedComponentKeys(live)
	byRef := resolvedByRef(resolveReply(t,
		map[string]interface{}{"ref": "J1", "footprint_resolved": true},
	))
	if n := adoptResolvedGeometry(live, byRef); n != 1 {
		t.Fatalf("attached = %d, want 1", n)
	}
	if got, _ := live.Components[0].Extra["footprint_resolved"].(bool); !got {
		t.Fatalf("this host's own resolve did not restamp the fact: %v",
			live.Components[0].Extra)
	}
}

// dropDerivedComponentKeys touches nothing else and tolerates a nil board and a
// nil Extra map — it runs on every deserialize, including the pure-codec arm.
func TestDropDerivedComponentKeysLeavesEverythingElseAlone(t *testing.T) {
	dropDerivedComponentKeys(nil)

	b := &board.Board{Components: []board.Component{
		{Ref: "J1", Extra: map[string]interface{}{
			"footprint_resolved": true,
			"pads":               []interface{}{map[string]interface{}{"number": "1"}},
			"has_pad_geometry":   true,
		}},
		{Ref: "J2"}, // nil Extra
	}}
	dropDerivedComponentKeys(b)

	if _, ok := b.Components[0].Extra["footprint_resolved"]; ok {
		t.Fatalf("flag not dropped: %v", b.Components[0].Extra)
	}
	if _, ok := b.Components[0].Extra["pads"]; !ok {
		t.Fatalf("the board's own lands were dropped with the flag: %v",
			b.Components[0].Extra)
	}
	if got, _ := b.Components[0].Extra["has_pad_geometry"].(bool); !got {
		t.Fatalf("has_pad_geometry disturbed: %v", b.Components[0].Extra)
	}
	if b.Components[1].Extra != nil {
		t.Fatalf("a nil Extra map was materialised: %v", b.Components[1].Extra)
	}
}
