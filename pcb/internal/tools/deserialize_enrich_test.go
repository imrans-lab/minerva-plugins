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
	"context"
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
//
// The stale arm goes through the PUBLIC channel — HandleDeserialize, the
// pure-codec entry every board load funnels through — rather than calling the
// drop directly, so removing the call from handleDeserialize turns it red.
func TestDeserializeDropsTheDocumentsOwnResolvedFlag(t *testing.T) {
	docBoard := func() *board.Board {
		return &board.Board{Components: []board.Component{
			{Ref: "J1", Extra: map[string]interface{}{"footprint_resolved": true}},
		}}
	}

	// A DOCUMENT saved with the flag, loaded with no resolve behind it: the
	// channel's own reply must not carry the flag back out.
	yaml := "version: 1\nname: Stale\nwidth_mm: 40\nheight_mm: 30\n" +
		"components:\n  - ref: J1\n    footprint: IC_DIP\n    x_mm: 1\n    y_mm: 2\n" +
		"    rotation_deg: 0\n    footprint_resolved: true\nnets: []\n"
	args, _ := json.Marshal(map[string]string{"yaml": yaml})
	out, err := HandleDeserialize(context.Background(), args)
	if err != nil {
		t.Fatalf("deserialize: %v", err)
	}
	var reply struct {
		Board struct {
			Components []map[string]interface{} `json:"components"`
		} `json:"board"`
	}
	if err := json.Unmarshal(out, &reply); err != nil {
		t.Fatal(err)
	}
	if len(reply.Board.Components) != 1 {
		t.Fatalf("want one component back, got %d", len(reply.Board.Components))
	}
	if _, ok := reply.Board.Components[0]["footprint_resolved"]; ok {
		t.Fatalf("pcb.deserialize handed back a saved footprint_resolved this host "+
			"never resolved: %v", reply.Board.Components[0])
	}

	// This host's own resolve answers for the ref: the flag is stamped back.
	// The adoption half has no public seam without a live worker, so it stays a
	// direct call over the same board shape.
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

// A SAVED designator anchor must not outlive the rule that produced it. The
// anchor is derived from the footprint (its authored reference text, else its
// courtyard), so a document saved by an older resolve carries an older
// derivation — and adoption is absent-only, so without the drop the stale value
// would win over the fresh one forever.
//
// Oracle: the y the resolve returned, which differs from the y the document
// carried; only a board that lost its saved key can show it.
func TestStaleDocumentAnchorLosesToThisHostsResolve(t *testing.T) {
	byRef := resolvedByRef(resolveReply(t,
		map[string]interface{}{
			"ref": "SW2", "has_pad_geometry": false,
			"refdes_anchor": map[string]interface{}{
				"x_mm": 0.0, "y_mm": -3.625, "rotation_deg": 0.0,
				"size_mm": 1.0, "hidden": false,
			},
		},
	))
	// The document as an older host saved it: the pre-courtyard default anchor.
	b := &board.Board{Components: []board.Component{{Ref: "SW2",
		Extra: map[string]interface{}{"refdes_anchor": map[string]interface{}{
			"x_mm": 0.0, "y_mm": -1.5, "rotation_deg": 0.0,
			"size_mm": 1.0, "hidden": false,
		}}}}}
	dropDerivedComponentKeys(b)
	if n := adoptResolvedGeometry(b, byRef); n != 1 {
		t.Fatalf("attached = %d, want 1", n)
	}
	got, _ := b.Components[0].Extra["refdes_anchor"].(map[string]interface{})
	if got["y_mm"] != -3.625 {
		t.Fatalf("the document's stale anchor survived the load — the panel "+
			"would draw SW2's designator inside the switch body; got %v", got)
	}
}

// THE AUTHORED PLACEMENT IS BOARD SOURCE and must cross this boundary
// untouched, beside its DERIVED sibling, which must not.
//
// The two keys look alike on purpose — same five fields, same footprint-local
// frame — and telling them apart is the whole contract. `refdes_placement` is
// what a person SET, so deleting it deletes a decision; `refdes_anchor` is what
// some machine's resolve COMPUTED from it, so keeping a saved one lets a stale
// library outvote this host.
//
// Oracle: the y the DOCUMENT authored (-6.5), which no derivation on this host
// produces, against the stale y the same document also carried (-1.5), which
// this host's resolve replaced with -6.5 because it honoured the authored key.
func TestAuthoredDesignatorPlacementCrossesTheBoundaryAndTheDerivedOneDoesNot(t *testing.T) {
	authored := map[string]interface{}{
		"x_mm": 0.0, "y_mm": -6.5, "rotation_deg": 0.0,
		"size_mm": 1.2, "hidden": false,
	}
	// The document: an authored placement plus a STALE effective anchor saved
	// by an older host, which had never seen the authored key.
	b := &board.Board{Components: []board.Component{{Ref: "SW2",
		Extra: map[string]interface{}{
			"refdes_placement": authored,
			"refdes_anchor": map[string]interface{}{
				"x_mm": 0.0, "y_mm": -1.5, "rotation_deg": 0.0,
				"size_mm": 1.0, "hidden": false,
			},
		}}}}

	// What the worker sends back once it has honoured the authored key: the
	// effective anchor EQUALS the placement.
	byRef := resolvedByRef(resolveReply(t, map[string]interface{}{
		"ref": "SW2", "has_pad_geometry": false,
		"footprint_resolved": true,
		"refdes_anchor": map[string]interface{}{
			"x_mm": 0.0, "y_mm": -6.5, "rotation_deg": 0.0,
			"size_mm": 1.2, "hidden": false,
		},
	}))

	dropDerivedComponentKeys(b)
	kept, ok := b.Components[0].Extra["refdes_placement"].(map[string]interface{})
	if !ok || kept["y_mm"] != -6.5 || kept["size_mm"] != 1.2 {
		t.Fatalf("the authored placement was dropped at the deserialize "+
			"boundary — the one thing on this component somebody actually "+
			"chose; got %v", b.Components[0].Extra)
	}
	if _, stale := b.Components[0].Extra["refdes_anchor"]; stale {
		t.Fatalf("the stale effective anchor survived the drop: %v",
			b.Components[0].Extra)
	}

	// The board that goes to the resolve must still state the authored key,
	// or the worker has nothing to honour. This is the exact encoding
	// attachFootprintGraphics sends.
	wire, err := json.Marshal(b)
	if err != nil {
		t.Fatalf("marshal board for resolve: %v", err)
	}
	var sent struct {
		Components []map[string]interface{} `json:"components"`
	}
	if err := json.Unmarshal(wire, &sent); err != nil {
		t.Fatalf("unmarshal wire board: %v", err)
	}
	if _, ok := sent.Components[0]["refdes_placement"]; !ok {
		t.Fatalf("the authored placement did not reach the worker: %s", wire)
	}

	if n := adoptResolvedGeometry(b, byRef); n != 1 {
		t.Fatalf("attached = %d, want 1", n)
	}
	got, _ := b.Components[0].Extra["refdes_anchor"].(map[string]interface{})
	if got["y_mm"] != -6.5 || got["size_mm"] != 1.2 {
		t.Fatalf("the wire anchor does not equal the authored placement — the "+
			"panel would draw the designator somewhere the fab will not print "+
			"it; got %v", got)
	}
	if again, _ := b.Components[0].Extra["refdes_placement"].(map[string]interface{}); again["y_mm"] != -6.5 {
		t.Fatalf("adoption disturbed the authored placement: %v",
			b.Components[0].Extra)
	}
}

// The two keys must stay on opposite sides of the derived list. A one-line
// slip here is silent: the placement would simply stop reaching the fab, and
// every other test in this file would still pass.
func TestTheAuthoredPlacementIsNotADerivedKey(t *testing.T) {
	for _, k := range board.DerivedComponentKeys {
		if k == "refdes_placement" {
			t.Fatalf("refdes_placement is listed as derived — the deserialize " +
				"boundary would delete every designator anyone has ever placed")
		}
	}
	var found bool
	for _, k := range board.DerivedComponentKeys {
		if k == "refdes_anchor" {
			found = true
		}
	}
	if !found {
		t.Fatalf("refdes_anchor left the derived list — a document's stale " +
			"effective anchor would outvote this host's own resolve")
	}
}
