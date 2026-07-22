package board

import (
	"fmt"
	"strings"
	"testing"
)

// counterSource is a deterministic IDSource: it mints "<type>:<n as 32 hex>",
// which is a well-formed minted shape, so re-running the migration over its
// output is a fixed point (idempotency test relies on this).
type counterSource struct{ n int }

func (c *counterSource) Mint(entityType string) (string, error) {
	c.n++
	return fmt.Sprintf("%s:%032x", entityType, c.n), nil
}

type failSource struct{}

func (failSource) Mint(string) (string, error) { return "", fmt.Errorf("entropy fault") }

func v1BoardWithChildren() *Board {
	return &Board{
		Version: 1, Name: "M", WidthMM: 10, HeightMM: 10,
		Components:    []Component{{Ref: "U1", Footprint: "F", Pins: []Pin{{Number: "1"}}}},
		Nets:          []Net{{Name: "N", Pins: []string{"U1.1"}}},
		Traces:        []Trace{{Net: "N", Points: []Point{{XMM: 1, YMM: 1}, {XMM: 2, YMM: 2}}}, {Net: "N", Points: []Point{{XMM: 3, YMM: 3}, {XMM: 4, YMM: 4}}}},
		Vias:          []Via{{XMM: 5, YMM: 5}},
		MountingHoles: []Hole{{XMM: 1, YMM: 1, DiameterMM: 3}},
	}
}

// The migration mints an id for the board and every trace/via/hole, and bumps
// the schema to v2. The mint count is exactly the number of id-bearing entities.
func TestMigrateMintsAndBumpsVersion(t *testing.T) {
	b := v1BoardWithChildren()
	n, err := MigrateV1toV2(b, &counterSource{})
	if err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if b.Version != 2 {
		t.Fatalf("version: want 2, got %d", b.Version)
	}
	wantMinted := 1 + len(b.Traces) + len(b.Vias) + len(b.MountingHoles) // board + children
	if n != wantMinted {
		t.Fatalf("minted count: want %d, got %d", wantMinted, n)
	}
	if !isMintedID("board", b.ID) {
		t.Errorf("board id not minted-shape: %q", b.ID)
	}
	for i, tr := range b.Traces {
		if !isMintedID("trace", tr.ID) {
			t.Errorf("trace[%d] id not minted-shape: %q", i, tr.ID)
		}
	}
	if !isMintedID("via", b.Vias[0].ID) {
		t.Errorf("via id not minted-shape: %q", b.Vias[0].ID)
	}
	if !isMintedID("hole", b.MountingHoles[0].ID) {
		t.Errorf("hole id not minted-shape: %q", b.MountingHoles[0].ID)
	}
	// Distinct entities get distinct ids.
	if b.Traces[0].ID == b.Traces[1].ID {
		t.Errorf("two traces share an id: %q", b.Traces[0].ID)
	}
}

// Running the migration twice is a fixed point: the second pass mints nothing
// and mutates no id. Idempotency is what makes re-deserialize safe.
func TestMigrateIdempotent(t *testing.T) {
	b := v1BoardWithChildren()
	if _, err := MigrateV1toV2(b, &counterSource{}); err != nil {
		t.Fatal(err)
	}
	before := b.ID + "|" + b.Traces[0].ID + "|" + b.Vias[0].ID + "|" + b.MountingHoles[0].ID
	n2, err := MigrateV1toV2(b, &counterSource{})
	if err != nil {
		t.Fatal(err)
	}
	if n2 != 0 {
		t.Fatalf("second migration minted %d ids, want 0", n2)
	}
	after := b.ID + "|" + b.Traces[0].ID + "|" + b.Vias[0].ID + "|" + b.MountingHoles[0].ID
	if before != after {
		t.Fatalf("idempotent migration changed ids:\n before=%s\n after =%s", before, after)
	}
}

// A legacy ordinal-shaped id (e.g. "trace_1", carried in from a .minpcb import)
// is NOT a minted id, so the migration must RE-MINT it — otherwise D1's
// global-uniqueness guarantee is false for legacy imports (Fable Round A note).
func TestMigrateReMintsLegacyOrdinalIds(t *testing.T) {
	b := v1BoardWithChildren()
	b.Traces[0].ID = "trace_1"
	b.Vias[0].ID = "via_legacy"
	n, err := MigrateV1toV2(b, &counterSource{})
	if err != nil {
		t.Fatal(err)
	}
	if b.Traces[0].ID == "trace_1" || !isMintedID("trace", b.Traces[0].ID) {
		t.Errorf("legacy trace id not re-minted: %q", b.Traces[0].ID)
	}
	if b.Vias[0].ID == "via_legacy" || !isMintedID("via", b.Vias[0].ID) {
		t.Errorf("legacy via id not re-minted: %q", b.Vias[0].ID)
	}
	// board + trace[0] + trace[1] + via + hole all needed minting.
	if n != 5 {
		t.Fatalf("minted count: want 5 (all unminted), got %d", n)
	}
}

// A board already carrying a well-formed minted id keeps it — the migration
// fills gaps, it does not churn valid identity.
func TestMigratePreservesWellFormedIds(t *testing.T) {
	b := v1BoardWithChildren()
	keep := "board:" + strings.Repeat("a", 32)
	b.ID = keep
	n, err := MigrateV1toV2(b, &counterSource{})
	if err != nil {
		t.Fatal(err)
	}
	if b.ID != keep {
		t.Errorf("well-formed board id churned: got %q, want %q", b.ID, keep)
	}
	// board id preserved → only the 2 traces + via + hole minted.
	if n != 4 {
		t.Fatalf("minted count: want 4 (board id preserved), got %d", n)
	}
}

// A mint failure must propagate (deserialize fails closed) rather than leaving a
// board with an empty/weak id.
func TestMigratePropagatesMintError(t *testing.T) {
	b := v1BoardWithChildren()
	if _, err := MigrateV1toV2(b, failSource{}); err == nil {
		t.Fatal("expected mint error to propagate, got nil")
	}
}

func TestIsMintedID(t *testing.T) {
	good := "trace:" + strings.Repeat("0", 32)
	cases := []struct {
		entity, id string
		want       bool
	}{
		{"trace", good, true},
		{"trace", "", false},
		{"trace", "trace_1", false},                          // legacy ordinal shape
		{"trace", "via:" + strings.Repeat("0", 32), false},   // wrong entity prefix
		{"trace", "trace:" + strings.Repeat("0", 31), false}, // too short
		{"trace", "trace:" + strings.Repeat("0", 33), false}, // too long
		{"trace", "trace:" + strings.Repeat("A", 32), false}, // uppercase hex rejected
		{"trace", "trace:" + strings.Repeat("g", 32), false}, // non-hex rejected
	}
	for _, c := range cases {
		if got := isMintedID(c.entity, c.id); got != c.want {
			t.Errorf("isMintedID(%q, %q) = %v, want %v", c.entity, c.id, got, c.want)
		}
	}
}
