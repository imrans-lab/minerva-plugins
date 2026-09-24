package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

// encodePacket builds a meter packet as hex: function index, prefix index,
// decimals, flag bits, counts.
func encodePacket(fn, prefix, dec int, flags uint16, counts int) string {
	w0 := uint16(fn<<6 | prefix<<3 | dec)
	w2 := uint16(counts)
	return hex.EncodeToString([]byte{byte(w0), byte(w0 >> 8), byte(flags), byte(flags >> 8), byte(w2), byte(w2 >> 8)})
}

// A bench session replayed as packets through Decode, 400 ms apart (the
// meter's rate), stamped with their own times. The V floating packets are
// live captures from the owner's meter; the rest use the same encoding.
//
// Oracle: the session yields exactly the listed edges in order; the probe
// wobbling around 3.29 V (including a stretch that re-settles at 3.31 V)
// adds nothing after the first settled edge; asking again with the returned
// cursor returns nothing; wait_for with a cursor answers from the journal
// only while no later edge has undone the match; a reading after a
// disconnect adds nothing; a cursor from another run is flagged reset; the
// journal keeps only journalSize edges and counts the rest as missed.
// Sequence numbers are checked relative to the run's first edge.
func TestJournalFromReadings(t *testing.T) {
	s := &server{}
	d := &s.changes
	at := time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)

	const auto, holdAuto = 4, 5
	vdc := func(counts int, flags uint16) string { return encodePacket(0, 4, 3, flags, counts) } // x.xxx V
	floatingMV := []string{encodePacket(0, 3, 2, auto, 12), encodePacket(0, 3, 2, auto, 15), encodePacket(0, 3, 2, auto, 9)}
	floatingV := []string{"24f004001500", "24f004001e00", "24f004000000"}
	ohmOL := encodePacket(4, 6, 7, auto, 0)

	feed := func(raws ...string) {
		t.Helper()
		for _, raw := range raws {
			pkt, _ := hex.DecodeString(raw)
			r, err := Decode(pkt, at)
			if err != nil {
				t.Fatalf("%s: %v", raw, err)
			}
			d.Observe(r)
			at = at.Add(400 * time.Millisecond)
		}
	}
	repeat := func(n int, raws ...string) []string {
		var out []string
		for i := 0; i < n; i++ {
			out = append(out, raws...)
		}
		return out
	}
	var base int // seq of the run's first edge minus one
	waitFor := func(args string) (Edge, bool) {
		t.Helper()
		out := s.toolWaitFor(json.RawMessage(args))
		e, ok := out["edge"].(Edge)
		return e, ok && out["matched"] == true
	}
	expect := func(what string, got Changes, cursor int, kinds ...EdgeKind) {
		t.Helper()
		cursor += base
		var names []string
		for _, e := range got.Edges {
			names = append(names, string(e.Kind)+" "+e.Slot+": "+e.Summary)
		}
		if len(got.Edges) != len(kinds) || got.Cursor != cursor {
			t.Fatalf("%s: cursor %d (want %d), edges:\n%s\nwant kinds %v", what, got.Cursor, cursor, strings.Join(names, "\n"), kinds)
		}
		for i, k := range kinds {
			if got.Edges[i].Kind != k {
				t.Fatalf("%s: edge %d is %s, want %s; edges:\n%s", what, i, got.Edges[i].Kind, k, strings.Join(names, "\n"))
			}
		}
	}

	// Floating on mV, dial to V (still floating), probe onto a 3.29 V rail
	// through one in-between reading, wobble, a stretch at 3.31 V, back to
	// 3.29 V, then probes off.
	d.SetConnected(true, at)
	feed(repeat(2, floatingMV...)...)
	feed(repeat(2, floatingV...)...)
	feed(vdc(1204, auto))
	feed(repeat(2, vdc(3290, auto), vdc(3291, auto), vdc(3289, auto), vdc(3292, auto))...)
	feed(repeat(2, vdc(3310, auto), vdc(3309, auto), vdc(3311, auto))...)
	feed(repeat(2, vdc(3290, auto), vdc(3288, auto), vdc(3291, auto))...)
	feed(vdc(804, auto))
	feed(repeat(2, floatingV...)...)

	first := d.Since(0)
	base = first.Edges[0].Seq - 1
	expect("session", first, 5, EdgeConnected, EdgeDial, EdgeDial, EdgeSettled, EdgeContactLost)
	if first.Reset || first.Missed != 0 {
		t.Errorf("cursor 0 is not a reset: %+v", first)
	}
	if e := first.Edges[1]; e.Slot != "mV" {
		t.Errorf("first dial edge: %+v", e)
	}
	if e := first.Edges[2]; e.Slot != "V" || !strings.Contains(e.Summary, "from mV to V") {
		t.Errorf("second dial edge: %+v", e)
	}
	if e := first.Edges[3]; e.Reading == nil || e.Reading.Value < 3.285 || e.Reading.Value > 3.295 {
		t.Errorf("settled edge should carry a ~3.29 V reading: %+v", e)
	}
	if body, err := json.Marshal(first.Edges[3]); err != nil || !strings.Contains(string(body), `"kind":"settled"`) {
		t.Errorf("edge JSON: %s %v", body, err)
	}
	expect("same cursor again", d.Since(first.Cursor), 5)

	// The dial is still on V, but the settled value was undone by contact_lost.
	if e, ok := waitFor(`{"slot":"V","cursor":0}`); !ok || e.Seq != base+3 {
		t.Errorf("wait_for V after the session: %+v %v, want edge %d", e, ok, base+3)
	}
	if e, ok := d.lastMatch(0, "V", true); ok {
		t.Errorf("nonzero on V matched %+v after contact was lost", e)
	}

	// Probes back on with HOLD pressed, then the dial to OHM with the leads
	// apart (OL) and HOLD released, then the meter drops off and one late
	// packet straggles in.
	woke := d.Changed()
	feed(repeat(2, vdc(3290, holdAuto), vdc(3291, holdAuto))...)
	if e, ok := waitFor(`{"slot":"V","nonzero":true,"cursor":0}`); !ok || e.Seq != base+7 {
		t.Errorf("wait_for nonzero V: %+v %v, want edge %d", e, ok, base+7)
	}
	feed(repeat(4, ohmOL)...)
	if e, ok := waitFor(fmt.Sprintf(`{"slot":"OHM","cursor":%d}`, first.Cursor)); !ok || e.Seq != base+8 {
		t.Errorf("wait_for OHM: %+v %v, want edge %d", e, ok, base+8)
	}
	if e, ok := d.lastMatch(0, "V", false); ok {
		t.Errorf("V matched %+v after the dial moved to OHM", e)
	}
	d.SetConnected(false, at)
	feed(ohmOL)
	if e, ok := d.lastMatch(0, "OHM", false); ok {
		t.Errorf("OHM matched %+v after the meter disconnected", e)
	}
	select {
	case <-woke:
	default:
		t.Error("Changed channel did not close when edges were added")
	}
	expect("after cursor", d.Since(first.Cursor), 11,
		EdgeHoldOn, EdgeSettled, EdgeDial, EdgeHoldOff, EdgeOverload, EdgeDisconnected)

	// Cursors from another run: one below this run's numbering, one above it.
	all := []EdgeKind{EdgeConnected, EdgeDial, EdgeDial, EdgeSettled, EdgeContactLost,
		EdgeHoldOn, EdgeSettled, EdgeDial, EdgeHoldOff, EdgeOverload, EdgeDisconnected}
	for _, stale := range []int{5, base + 999} {
		got := d.Since(stale)
		expect(fmt.Sprintf("cursor %d from another run", stale), got, 11, all...)
		if !got.Reset {
			t.Errorf("cursor %d from another run: reset not set", stale)
		}
	}

	for i := 0; i < journalSize; i++ {
		d.journal.add(Edge{Kind: EdgeDial})
	}
	if got := d.Since(0); len(got.Edges) != journalSize || got.Missed != 11 || got.Reset || got.Cursor != base+11+journalSize {
		t.Errorf("full journal: %d edges, missed %d, reset %v, cursor %d", len(got.Edges), got.Missed, got.Reset, got.Cursor-base)
	}
	if got := d.Since(5); !got.Reset || got.Missed != 11 || len(got.Edges) != journalSize {
		t.Errorf("full journal, cursor from another run: reset %v, missed %d, %d edges", got.Reset, got.Missed, len(got.Edges))
	}
}
