package contract

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

// Versioned migration of a stored Council document.
//
// A document is durable state living in a user's project, so a build that
// reads one either understands its shape or refuses it. `schema_version` is the
// declaration of that shape, and this file is the ladder that carries an older
// document up to the shape this build speaks. It runs in Store.Load BEFORE
// validation, because an older document is not expected to satisfy today's
// schema — that is what makes it older.
//
// Two kinds of step, and the difference matters:
//
//   - A LADDER step moves a document from one schema_version to the next. It
//     exists forever once written: a document written by any shipped build must
//     keep its route to the present.
//   - A FIXUP runs at the current version and fills in something a document of
//     this version may legitimately lack — a field introduced without a version
//     bump because absence is unambiguous. Every fixup is idempotent, so a
//     document that already has the value is left exactly as it is (and reports
//     no migration, which is what keeps a valid record loading at its own
//     revision).
//
// A document from a NEWER version is refused rather than guessed at. Council
// has one durable record and truncating it would be silent.

// SnapshotSchemaVersion is the record format this build writes. It is the
// version every migrated document ends at.
const SnapshotSchemaVersion = 1

type migrationStep struct {
	name  string
	from  int
	to    int
	apply func(snapshot map[string]any)
}

// ladder is ordered by `from`. v0 is the pre-release shape: records that
// carried no explicit schema_version at all, from before the version field was
// part of the contract.
var ladder = []migrationStep{
	{
		name: "v0→v1: every record declares the schema version it was written for",
		from: 0,
		to:   1,
		apply: func(snapshot map[string]any) {
			stampSchemaVersion(snapshot, 1)
		},
	},
}

type migrationFixup struct {
	name string
	// apply reports whether it changed the document. A fixup that changed
	// nothing is not reported as a migration. A fixup that cannot be applied
	// fails the load: half a migration is not a document.
	apply func(snapshot map[string]any) (bool, error)
}

// fixups run after the ladder, at SnapshotSchemaVersion.
var fixups = []migrationFixup{
	{
		name:  "mint the durable project identity",
		apply: mintProjectID,
	},
}

// MigrateSnapshot brings a stored snapshot up to the shape this build speaks,
// in place, and returns the name of every step that changed something.
//
// An empty result means the document was already current: nothing was
// rewritten, so the caller keeps its revision. A non-empty one means the
// document that comes out is not the one that went in, which costs a revision
// for the same reason a demotion does (§4.3).
func MigrateSnapshot(snapshot map[string]any) ([]string, error) {
	if snapshot == nil {
		return nil, fmt.Errorf("there is no document to migrate")
	}
	version := int(num(snapshot["schema_version"]))
	if version > SnapshotSchemaVersion {
		return nil, fmt.Errorf(
			"this Council document declares schema_version %d and this build reads %d; it was written by a newer Council and is not changed here",
			version, SnapshotSchemaVersion)
	}
	applied := []string{}
	for version < SnapshotSchemaVersion {
		step, found := stepFrom(version)
		if !found {
			return nil, fmt.Errorf(
				"this Council document declares schema_version %d and this build has no migration from it", version)
		}
		step.apply(snapshot)
		snapshot["schema_version"] = float64(step.to)
		applied = append(applied, step.name)
		version = step.to
	}
	for _, fixup := range fixups {
		changed, err := fixup.apply(snapshot)
		if err != nil {
			return nil, err
		}
		if changed {
			applied = append(applied, fixup.name)
		}
	}
	return applied, nil
}

func stepFrom(version int) (migrationStep, bool) {
	for _, step := range ladder {
		if step.from == version {
			return step, true
		}
	}
	return migrationStep{}, false
}

// ProjectID is the durable identity of one Council document. It is minted once,
// when the document is first loaded by a build that has this field, and never
// changes afterwards: it is what lets a chat routed against one project be
// recognised as belonging to it by a backend process that has never seen the
// other project's document, and what lets a reopened panel be told apart from a
// panel opening something else entirely (§5.5).
//
// It is random rather than derived. A name, a path or a hash would collide the
// moment a user copied a document or renamed a project, and a collision here
// merges two projects' chat routing.
func NewProjectID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		// crypto/rand does not fail on the platforms Council ships to. If it
		// ever does there is no safe fallback: a guessable or repeatable
		// identity merges two projects' chat routing, which is the one thing
		// this value exists to prevent. So the load is refused and says why.
		return "", fmt.Errorf("could not mint a project identity: %w", err)
	}
	return "prj-" + hex.EncodeToString(buf), nil
}

// mintProjectID gives a document that has none a project identity. Documents
// written before the field existed are the ones that need it, and they need it
// exactly once.
func mintProjectID(snapshot map[string]any) (bool, error) {
	if id := str(snapshot["project_id"]); id != "" {
		return false, nil
	}
	id, err := NewProjectID()
	if err != nil {
		return false, err
	}
	snapshot["project_id"] = id
	return true, nil
}

// stampSchemaVersion writes `version` onto the snapshot and onto every record
// nested inside it — a session, a definition, an embedded definition snapshot.
// Each carries its own schema_version, so a document is only migrated when all
// of them are.
func stampSchemaVersion(value any, version int) {
	switch typed := value.(type) {
	case map[string]any:
		if _, isRecord := typed["record_kind"]; isRecord {
			typed["schema_version"] = float64(version)
		}
		for _, child := range typed {
			stampSchemaVersion(child, version)
		}
	case []any:
		for _, child := range typed {
			stampSchemaVersion(child, version)
		}
	}
}
