// Package board — v1→v2 identity mint-and-write migration.
//
// Schema v2 (item 019f802ca3af) gives Board/Trace/Via/Hole a persistent,
// mint-once opaque id (see board.go). This file owns the one-time migration that
// assigns those ids to a v1 board and bumps it to v2. It is deliberately scoped
// to IDENTITY only:
//
//   - Identity is self-contained — a mint needs nothing but the entity kind, so
//     it belongs in Go, next to the contract it stamps.
//   - Pin-geometry AUTHORITY (fold deprecated inline pad geometry into the typed
//     override, dropping what merely restates the locked footprint) needs the
//     resolved FOOTPRINT, which lives in the Python worker, not here. That fold
//     is Round C (the v2 compiler), the language that owns footprint data. A v2
//     board may still carry inline pin geometry after this migration; the v2
//     compiler is the authority-enforcement point.
//
// Trigger (design decision D3, ratified): the migration runs at pcb.deserialize
// of a sub-v2 board and emits a warning; the resulting v2 board is persisted on
// the host's next pcb.serialize. Serialize itself never mints — it writes what it
// is given.
package board

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

// mintedIDBytes is the entropy width of a minted id: 128 bits → 32 hex chars.
const mintedIDBytes = 16

// IDSource mints fresh opaque entity ids ("<entityType>:<32 hex>"). It is an
// interface so production uses crypto-random entropy while tests inject a
// deterministic counter — the migration must not depend on ambient randomness
// for its correctness to be testable.
type IDSource interface {
	Mint(entityType string) (string, error)
}

// cryptoIDSource mints ids from crypto/rand — the production source. A mint is a
// one-time write, so 128 bits of entropy makes collision across independently
// migrated boards negligible (this is what lets persisted ids SUBSUME the old
// board-namespacing rule; design decision D1).
type cryptoIDSource struct{}

func (cryptoIDSource) Mint(entityType string) (string, error) {
	var buf [mintedIDBytes]byte
	if _, err := rand.Read(buf[:]); err != nil {
		// crypto/rand failing is an unrecoverable entropy fault; surface it so
		// deserialize fails closed rather than minting a weak/empty id.
		return "", fmt.Errorf("board: mint %s id: %w", entityType, err)
	}
	return entityType + ":" + hex.EncodeToString(buf[:]), nil
}

// DefaultIDSource is the production crypto-random mint source.
func DefaultIDSource() IDSource { return cryptoIDSource{} }

// isMintedID reports whether id is a well-formed minted id for entityType —
// exactly "<entityType>:<32 lowercase hex>". Anything else (empty, a legacy
// ordinal-shaped id like "trace_1" carried in from a .minpcb import, or a
// foreign shape) is treated as UNMINTED and will be re-minted, so D1's
// global-uniqueness guarantee holds even for legacy imports (Fable Round A note).
func isMintedID(entityType, id string) bool {
	prefix := entityType + ":"
	if len(id) != len(prefix)+2*mintedIDBytes {
		return false
	}
	if id[:len(prefix)] != prefix {
		return false
	}
	for _, c := range id[len(prefix):] {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// MigrateV1toV2 mints a persistent id for the board and every trace/via/hole
// that lacks a well-formed minted id, then bumps the board to schema v2. It
// returns the number of ids minted.
//
// The migration is IDEMPOTENT: a board already carrying minted ids is unchanged
// (zero mints), and a partially-minted board only fills the gaps. A non-minted
// id (empty or legacy-shaped) is REPLACED — the pre-v2 ids were never stable
// identity, so re-minting is the one-time cost of gaining it. It does NOT touch
// pin geometry (see the package doc: that authority fold is Round C).
func MigrateV1toV2(b *Board, mint IDSource) (int, error) {
	minted := 0
	ensure := func(entityType string, id *string) error {
		if isMintedID(entityType, *id) {
			return nil
		}
		fresh, err := mint.Mint(entityType)
		if err != nil {
			return err
		}
		*id = fresh
		minted++
		return nil
	}

	if err := ensure("board", &b.ID); err != nil {
		return minted, err
	}
	for i := range b.Traces {
		if err := ensure("trace", &b.Traces[i].ID); err != nil {
			return minted, err
		}
	}
	for i := range b.Vias {
		if err := ensure("via", &b.Vias[i].ID); err != nil {
			return minted, err
		}
	}
	for i := range b.MountingHoles {
		if err := ensure("hole", &b.MountingHoles[i].ID); err != nil {
			return minted, err
		}
	}
	b.Version = 2
	return minted, nil
}
