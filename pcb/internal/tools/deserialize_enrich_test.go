package tools

// Tests for the board-load enrichment's policy: which of the worker's
// resolve_best_effort answers reach the reply's `resolved` map, keyed by
// component ref, and which the board's own authored geometry keeps out.
//
// Tested WITHOUT a live worker: resolvedByRef and resolvedEnrichment are pure
// over their inputs, and the bridge call they sit behind degrades on its own
// (attachFootprintGraphics never fails a load).

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

var anchorDict = map[string]interface{}{
	"x_mm": 0.0, "y_mm": -1.5, "rotation_deg": 0.0, "size_mm": 1.0, "hidden": false,
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
		// Nothing resolved at all -> omitted, so the reply can distinguish
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

// THE ENRICHMENT RIDES BESIDE THE BOARD. Every resolved fact lands under the
// component's ref in the `resolved` map, the board itself is untouched, and
// pads travel with their marker: has_pad_geometry asserts "these pads are the
// footprint's real geometry", so it is stamped only beside pads this host
// resolved. A component that states a `pads` key owns its lands AND its
// artwork (the worker's FULL rule), so it receives neither resolved pads nor
// resolved graphics — even when it authored no graphics of its own; the
// anchor and the resolved fact still reach it.
func TestEnrichmentIsKeyedByRefAndNeverEntersTheBoard(t *testing.T) {
	authored := []board.Blob{{"number": "authored"}}
	b := &board.Board{Components: []board.Component{
		{Ref: "TP1"},
		{Ref: "J2", Pads: &authored, Graphics: []board.Blob{{"kind": "authored"}}},
		{Ref: "J3", Pads: &authored},
		{Ref: "X1"},
	}}
	before, _ := json.Marshal(b)

	resolved := resolvedEnrichment(b, map[string]resolvedComponent{
		"TP1": {
			graphics:          []interface{}{map[string]interface{}{"kind": "circle"}},
			pads:              []interface{}{padDict},
			hasPadGeometry:    true,
			refdesAnchor:      anchorDict,
			footprintResolved: true,
		},
		"J2": {
			graphics:          []interface{}{map[string]interface{}{"kind": "derived"}},
			pads:              []interface{}{padDict},
			hasPadGeometry:    true,
			footprintResolved: true,
		},
		"J3": {
			graphics:          []interface{}{map[string]interface{}{"kind": "derived"}},
			pads:              []interface{}{padDict},
			hasPadGeometry:    true,
			refdesAnchor:      anchorDict,
			footprintResolved: true,
		},
	})

	after, _ := json.Marshal(b)
	if string(before) != string(after) {
		t.Fatalf("the enrichment mutated the board:\n%s\n%s", before, after)
	}
	tp1 := resolved["TP1"]
	for _, key := range []string{"graphics", "pads", "has_pad_geometry", "refdes_anchor", "footprint_resolved"} {
		if _, ok := tp1[key]; !ok {
			t.Fatalf("TP1 lost %s: %v", key, tp1)
		}
	}
	j2 := resolved["J2"]
	for _, key := range []string{"graphics", "pads", "has_pad_geometry"} {
		if _, ok := j2[key]; ok {
			t.Fatalf("J2 authors its own %s and must not receive a resolved copy: %v", key, j2)
		}
	}
	if got, _ := j2["footprint_resolved"].(bool); !got {
		t.Fatalf("J2's component-level resolved fact was withheld with the geometry: %v", j2)
	}
	j3 := resolved["J3"]
	for _, key := range []string{"graphics", "pads", "has_pad_geometry"} {
		if _, ok := j3[key]; ok {
			t.Fatalf("J3 states a pads key and so owns its artwork too; it must not receive resolved %s: %v", key, j3)
		}
	}
	if _, ok := j3["refdes_anchor"]; !ok {
		t.Fatalf("J3's designator anchor was withheld with the geometry: %v", j3)
	}
	if _, ok := resolved["X1"]; ok {
		t.Fatalf("X1 was not resolved and must not appear: %v", resolved["X1"])
	}
}

// A silk-only footprint resolves with zero pads, so has_pad_geometry stays
// honestly false — footprint_resolved and the designator anchor are what let
// the panel distinguish "resolved, nothing left to resolve" from "fallback".
func TestSilkOnlyComponentCarriesAnchorAndFactWithoutPads(t *testing.T) {
	byRef := resolvedByRef(resolveReply(t,
		map[string]interface{}{
			"ref": "LOGO1", "footprint_resolved": true, "has_pad_geometry": false,
			"graphics":      []interface{}{map[string]interface{}{"kind": "poly"}},
			"refdes_anchor": anchorDict,
		},
	))
	b := &board.Board{Components: []board.Component{{Ref: "LOGO1"}}}
	logo := resolvedEnrichment(b, byRef)["LOGO1"]
	if len(logo) == 0 {
		t.Fatal("the silk-only component was not enriched at all")
	}
	if _, ok := logo["has_pad_geometry"]; ok {
		t.Fatalf("has_pad_geometry stamped on a pad-less component: %v", logo)
	}
	if got, _ := logo["footprint_resolved"].(bool); !got {
		t.Fatalf("footprint_resolved not carried: %v", logo)
	}
	if anchor, _ := logo["refdes_anchor"].(map[string]interface{}); anchor["y_mm"] != -1.5 {
		t.Fatalf("refdes_anchor not carried: %v", logo)
	}
}

// A DOCUMENT cannot assert a resolve. The keys a resolve derives
// (footprint_resolved, refdes_anchor, has_pad_geometry) are not board keys at
// all any more, so a file that carries one is refused by name rather than
// believed — and the pure-codec reply carries an empty `resolved` map, never
// a stale fact from the file.
func TestADocumentCannotCarryAResolvedFact(t *testing.T) {
	yaml := "version: 1\nname: Stale\nwidth_mm: 40\nheight_mm: 30\n" +
		"components:\n  - ref: J1\n    footprint: IC_DIP\n    x_mm: 1\n    y_mm: 2\n" +
		"    rotation_deg: 0\n    footprint_resolved: true\nnets: []\n"
	args, _ := json.Marshal(map[string]string{"yaml": yaml})
	if _, err := HandleDeserialize(context.Background(), args); err == nil {
		t.Fatal("a document carrying footprint_resolved was accepted")
	}

	clean := "version: 1\nname: Clean\nwidth_mm: 40\nheight_mm: 30\n" +
		"components:\n  - ref: J1\n    footprint: IC_DIP\n    x_mm: 1\n    y_mm: 2\n" +
		"    rotation_deg: 0\n    refdes_placement: {y_mm: -6.5}\nnets: []\n"
	args, _ = json.Marshal(map[string]string{"yaml": clean})
	out, err := HandleDeserialize(context.Background(), args)
	if err != nil {
		t.Fatalf("deserialize: %v", err)
	}
	var reply struct {
		Board struct {
			Components []map[string]interface{} `json:"components"`
		} `json:"board"`
		Resolved map[string]map[string]interface{} `json:"resolved"`
	}
	if err := json.Unmarshal(out, &reply); err != nil {
		t.Fatal(err)
	}
	if len(reply.Resolved) != 0 {
		t.Fatalf("the pure-codec arm invented a resolve: %v", reply.Resolved)
	}
	// The AUTHORED placement is board source and crosses the boundary intact.
	placement, _ := reply.Board.Components[0]["refdes_placement"].(map[string]interface{})
	if placement["y_mm"] != -6.5 {
		t.Fatalf("the authored designator placement did not cross the boundary: %v", reply.Board.Components[0])
	}
}
