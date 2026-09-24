package main

import (
	"fmt"
	"math"
	"sync"
	"time"
)

// EdgeKind names one kind of bench event in the change journal.
type EdgeKind string

const (
	EdgeConnected    EdgeKind = "connected"
	EdgeDisconnected EdgeKind = "disconnected"
	EdgeDial         EdgeKind = "dial"
	EdgeSettled      EdgeKind = "settled"
	EdgeContactLost  EdgeKind = "contact_lost"
	EdgeOverload     EdgeKind = "overload"
	EdgeHoldOn       EdgeKind = "hold_on"
	EdgeHoldOff      EdgeKind = "hold_off"
	EdgeRelOn        EdgeKind = "rel_on"
	EdgeRelOff       EdgeKind = "rel_off"
)

// Edge is one thing that happened at the bench, as an LLM reads it.
type Edge struct {
	Seq     int       `json:"seq"`
	Kind    EdgeKind  `json:"kind"`
	At      time.Time `json:"at"`
	Summary string    `json:"summary"`
	Slot    string    `json:"slot,omitempty"`
	Reading *Reading  `json:"reading,omitempty"`
}

// A reading settles when every reading over the last settleTime spans no
// more than max(settleBandCounts display counts, settleBandRel of the value),
// so a noisy but stationary signal settles at its centre; one second is 2-3 readings at the meter's rate
// and matches wait_for's default settle. A settled value is an edge only when
// it moves more than max(changeCounts, changeRel) from the last reported one,
// a gap wider than the band so a wobbling probe that re-settles nearby stays
// quiet, while a slow drift still reports once it adds up. A reading within
// zeroCounts of zero is a floating input (the owner's meter idles at 21-30
// counts on V with the probes apart); on OHM a floating input reads OL
// instead, so near zero there is a real short.
const (
	settleTime       = time.Second
	settleBandCounts = 5
	settleBandRel    = 0.005
	changeCounts     = 20
	changeRel        = 0.02
	zeroCounts       = 50
	journalSize      = 200
)

// journal keeps the last journalSize edges with increasing sequence numbers.
// Numbering starts at the run's start time in Unix milliseconds (exact in a
// float64, and far ahead of any earlier run's edge count), so a cursor below
// base comes from an earlier run. Other goroutines learn of new edges
// through Changed.
type journal struct {
	mu      sync.Mutex
	edges   []Edge
	base    int // seq of the run's first edge minus one
	head    int
	changed chan struct{}
}

// seed fixes base on first use; callers hold mu.
func (j *journal) seed() {
	if j.base == 0 {
		j.base = int(time.Now().UnixMilli())
		j.head = j.base
	}
}

func (j *journal) add(e Edge) Edge {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.seed()
	j.head++
	e.Seq = j.head
	if len(j.edges) == journalSize {
		copy(j.edges, j.edges[1:])
		j.edges = j.edges[:journalSize-1]
	}
	j.edges = append(j.edges, e)
	if j.changed != nil {
		close(j.changed)
		j.changed = nil
	}
	return e
}

// Changes is the reply to "what happened after cursor". Missed counts edges
// that fell out of the journal before the caller asked; Reset means the
// cursor is not from this run of the plugin, so every retained edge is
// returned. Cursor 0 asks for everything without flagging a reset.
type Changes struct {
	Edges  []Edge
	Cursor int
	Missed int
	Reset  bool
}

func (j *journal) since(cursor int) Changes {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.seed()
	out := Changes{Edges: []Edge{}, Cursor: j.head}
	if cursor < j.base || cursor > j.head {
		out.Reset = cursor != 0
		cursor = j.base
	}
	if len(j.edges) > 0 && j.edges[0].Seq > cursor+1 {
		out.Missed = j.edges[0].Seq - cursor - 1
	}
	for _, e := range j.edges {
		if e.Seq > cursor {
			out.Edges = append(out.Edges, e)
		}
	}
	return out
}

// Changed returns a channel that closes when the next edge is added.
func (j *journal) Changed() <-chan struct{} {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.changed == nil {
		j.changed = make(chan struct{})
	}
	return j.changed
}

// edgeDetector turns the reading stream and connection changes into edges.
// The zero value is ready to use; every method is safe from any goroutine.
// Readings are judged by their own timestamps, never the wall clock.
type edgeDetector struct {
	mu        sync.Mutex
	journal   journal
	connected bool
	seen      bool   // a reading arrived since the last connect
	slot      string // slotLabel of the last reading
	flags     map[string]bool

	window []Reading // current run (same function and class), trimmed to settleTime

	settled     Reading // last settled reading, the baseline for the next edge
	haveSettled bool
}

// Since returns the edges after cursor and the cursor to pass next time.
func (d *edgeDetector) Since(cursor int) Changes { return d.journal.since(cursor) }

// Changed returns a channel that closes when the next edge is recorded.
func (d *edgeDetector) Changed() <-chan struct{} { return d.journal.Changed() }

// SetConnected records a connect or disconnect; repeats are ignored.
func (d *edgeDetector) SetConnected(on bool, at time.Time) []Edge {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.setConnected(nil, on, at)
}

func (d *edgeDetector) setConnected(out []Edge, on bool, at time.Time) []Edge {
	if on == d.connected {
		return out
	}
	d.connected = on
	if on {
		return append(out, d.journal.add(Edge{Kind: EdgeConnected, At: at, Summary: "Meter connected"}))
	}
	d.seen, d.slot, d.flags = false, "", nil
	d.resetSettle()
	return append(out, d.journal.add(Edge{Kind: EdgeDisconnected, At: at, Summary: "Meter disconnected: it was turned off, went out of range, or its Bluetooth went to sleep"}))
}

func (d *edgeDetector) resetSettle() {
	d.window, d.haveSettled = nil, false
}

// Observe feeds one reading and returns the edges it produced, if any.
// Readings while disconnected are ignored: stragglers from a dropped link
// (the notify callback races the reconnect loop), and the first readings of
// a new link, which the meter subscribes to before it flags itself connected.
func (d *edgeDetector) Observe(r Reading) []Edge {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.connected {
		return nil
	}
	var out []Edge
	emit := func(kind EdgeKind, summary string) {
		rc := r
		out = append(out, d.journal.add(Edge{Kind: kind, At: r.Timestamp, Summary: summary, Slot: r.Slot, Reading: &rc}))
	}

	if label := slotLabel(r); !d.seen || label != d.slot {
		summary := fmt.Sprintf("Dial is on %s (%s)", label, r.Function)
		if d.seen {
			summary = fmt.Sprintf("Dial moved from %s to %s (%s)", d.slot, label, r.Function)
		}
		d.seen, d.slot = true, label
		d.resetSettle()
		emit(EdgeDial, summary)
	}

	if d.flags == nil {
		d.flags = map[string]bool{}
	}
	for _, f := range []struct {
		name    string
		on, off EdgeKind
		onText  string
		offText string
	}{
		{"hold", EdgeHoldOn, EdgeHoldOff, "HOLD on: the display is frozen at " + r.Display, "HOLD off: readings are live again"},
		{"rel", EdgeRelOn, EdgeRelOff, "REL on: readings now show the difference from the value when REL was pressed", "REL off: readings are absolute again"},
	} {
		on := hasFlag(r, f.name)
		if on == d.flags[f.name] {
			continue
		}
		d.flags[f.name] = on
		if f.name == "rel" {
			d.resetSettle()
		}
		if on {
			emit(f.on, f.onText)
		} else {
			emit(f.off, f.offText)
		}
	}

	if at, ok := d.track(r); ok {
		if kind, summary, ok := d.settle(at); ok {
			emit(kind, summary)
		}
	}
	return out
}

// track adds r to the steadiness window and, while the window has held
// steady for settleTime, returns the reading nearest its centre. settle is
// idempotent for an unchanged state, so it runs on every steady window and
// a slow drift is still caught once it passes the change threshold.
func (d *edgeDetector) track(r Reading) (Reading, bool) {
	if n := len(d.window); n > 0 && (d.window[n-1].Function != r.Function || classify(d.window[n-1]) != classify(r)) {
		d.window = nil
	}
	d.window = append(d.window, r)
	// Keep one reading at or before the window start so the span covers settleTime.
	for len(d.window) > 1 && !d.window[1].Timestamp.After(r.Timestamp.Add(-settleTime)) {
		d.window = d.window[1:]
	}
	if r.Timestamp.Sub(d.window[0].Timestamp) < settleTime {
		return Reading{}, false
	}
	lo, hi := baseValue(r), baseValue(r)
	for _, w := range d.window {
		lo, hi = math.Min(lo, baseValue(w)), math.Max(hi, baseValue(w))
	}
	centre := (lo + hi) / 2
	band := math.Max(settleBandCounts*resolution(r), settleBandRel*math.Abs(centre))
	if classify(r) == classValue && hi-lo > band {
		return Reading{}, false
	}
	best := r
	for _, w := range d.window {
		if math.Abs(baseValue(w)-centre) < math.Abs(baseValue(best)-centre) {
			best = w
		}
	}
	return best, true
}

// settle records r as the settled state and says whether that is an edge.
func (d *edgeDetector) settle(r Reading) (EdgeKind, string, bool) {
	prev, had := d.settled, d.haveSettled
	c := classify(r)
	switch {
	case c == classOverload:
		d.settled, d.haveSettled = r, true
		if had && prev.Overload {
			return "", "", false
		}
		if r.Slot == "OHM" {
			return EdgeOverload, "OL on OHM: open circuit (probes apart or the part is open)", true
		}
		return EdgeOverload, fmt.Sprintf("OL on %s: the input is over range", slotLabel(r)), true
	case c == classOpen:
		d.settled, d.haveSettled = r, true
		if had && classify(prev) == classValue {
			return EdgeContactLost, fmt.Sprintf("Reading fell back to %s from %s: probes lifted or contact lost", r.Display, prev.Display), true
		}
		return "", "", false
	case !had || classify(prev) != classValue || prev.Function != r.Function || movedBeyondThreshold(prev, r):
		d.settled, d.haveSettled = r, true
		return EdgeSettled, fmt.Sprintf("Settled at %s (%s)", r.Display, r.Function), true
	}
	// Within the threshold: keep the old baseline so a slow drift still adds up.
	return "", "", false
}

type readingClass int

const (
	classValue readingClass = iota
	classOpen
	classOverload
)

func classify(r Reading) readingClass {
	switch {
	case r.Overload:
		return classOverload
	case r.Slot != "OHM" && math.Abs(r.Value)*math.Pow10(r.decimals) <= zeroCounts:
		return classOpen
	}
	return classValue
}

func movedBeyondThreshold(prev, r Reading) bool {
	threshold := math.Max(changeCounts*resolution(r), changeRel*math.Abs(baseValue(prev)))
	return math.Abs(baseValue(r)-baseValue(prev)) > threshold
}

var prefixScale = map[string]float64{"n": 1e-9, "µ": 1e-6, "m": 1e-3, "k": 1e3, "M": 1e6, "G": 1e9}

// baseValue is the reading in its unprefixed unit, so autorange steps
// (999 Ω to 1.001 kΩ) compare as the same quantity.
func baseValue(r Reading) float64 {
	if s, ok := prefixScale[r.Prefix]; ok {
		return r.Value * s
	}
	return r.Value
}

// resolution is one display count in the unprefixed unit.
func resolution(r Reading) float64 {
	return baseValue(Reading{Value: math.Pow10(-r.decimals), Prefix: r.Prefix})
}

func hasFlag(r Reading, name string) bool {
	for _, f := range r.Flags {
		if f == name {
			return true
		}
	}
	return false
}

// slotLabel names the dial position; functions with no slot (NCV, hFE) use
// the function name.
func slotLabel(r Reading) string {
	if r.Slot != "" {
		return r.Slot
	}
	return r.Function
}

// holdsNow is lastMatch for the present, whatever the journal kept: the
// dial is on slot right now or, with nonzero, a non-zero value is settled
// there (any slot when slot is empty) and the latest reading is still a
// value, as wait_for's live path requires. The edge it returns only
// describes that state; it is not in the journal.
func (d *edgeDetector) holdsNow(slot string, nonzero bool) (Edge, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	n := len(d.window)
	if !d.connected || n == 0 {
		return Edge{}, false
	}
	last := d.window[n-1]
	if !nonzero {
		if slotLabel(last) != slot {
			return Edge{}, false
		}
		return Edge{Kind: EdgeDial, At: last.Timestamp, Slot: last.Slot, Reading: &last}, true
	}
	r := d.settled
	if !d.haveSettled || classify(r) != classValue || r.Value == 0 || classify(last) != classValue ||
		last.Value == 0 || last.Slot != r.Slot || (slot != "" && r.Slot != slot) {
		return Edge{}, false
	}
	return Edge{Kind: EdgeSettled, At: r.Timestamp, Slot: r.Slot, Reading: &r}, true
}

// lastMatch finds the newest edge after cursor showing the dial on slot or,
// with nonzero, a non-zero value settled on it (on any slot when slot is
// empty), provided no later edge has undone it: a disconnect or dial move,
// and for nonzero also a later settled, contact_lost or overload edge.
func (d *edgeDetector) lastMatch(cursor int, slot string, nonzero bool) (Edge, bool) {
	var match Edge
	found := false
	for _, e := range d.Since(cursor).Edges {
		switch {
		case (slot == "" || e.Slot == slot) && ((!nonzero && e.Kind == EdgeDial) || (nonzero && e.Kind == EdgeSettled && e.Reading.Value != 0)):
			match, found = e, true
		case e.Kind == EdgeDisconnected || e.Kind == EdgeDial:
			found = false
		case nonzero && (e.Kind == EdgeSettled || e.Kind == EdgeContactLost || e.Kind == EdgeOverload):
			found = false
		}
	}
	return match, found
}
