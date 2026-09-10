// Package presets holds the councils Council ships with.
//
// A preset is an ordinary council_definition record and nothing else: it is
// validated by the same schemas, imported by the same definition.import command
// and edited by the same panel as a council a user assembled by hand. There is
// no preset format, no preset loader and no preset-only field — a shipped
// council is a starting point, not a species.
//
// One number in every shipped council is arithmetic rather than taste, and JSON
// has nowhere to say so: run_budget_seconds is sized as
// (waves + chair + 1) x per_member_timeout_seconds, where waves is
// ceil(max_members_per_round / max_concurrent_members). The allowance is 300
// seconds because a free local model on TurnRock/Core can spend minutes loading
// before its first token, and the spare wave is there to keep the two limits
// from being confused for one another. A budget set to the exact worst case
// expires while the last members are still inside their own allowance, and
// every one of them is then recorded as timed out — a member blamed for a limit
// the ROUND ran out of, which is the wrong thing to go and raise.
//
// The files are the single source. The backend embeds them here for
// minerva_council_presets, and ui/build.mjs inlines the same bytes into
// ui/panel.html so the editor can offer them with no round trip; neither copy is
// edited by hand, and TestShippedPresetsAreImportableCouncils holds them to the
// contract.
package presets

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"sort"
)

//go:embed *.json
var FS embed.FS

// Preset is one shipped council, kept as the raw record so the caller writes
// exactly the bytes on disk into definition.import rather than a re-serialised
// approximation of them.
type Preset struct {
	// File is the name in this directory, which is the preset's stable handle.
	File string
	// DefinitionID is the record's own id. It is a NAME, not a claim on the
	// project: importing gives the copy a fresh definition_id, so the same
	// preset can be started twice.
	DefinitionID string
	Name         string
	Purpose      string
	// Definition is the record as stored, ready to hand to definition.import.
	Definition json.RawMessage
}

// All returns every shipped preset, ordered by file name so a caller, a page and
// a test see the same list in the same order.
func All() ([]Preset, error) {
	names, err := fs.Glob(FS, "*.json")
	if err != nil {
		return nil, err
	}
	sort.Strings(names)
	out := make([]Preset, 0, len(names))
	for _, name := range names {
		raw, err := FS.ReadFile(name)
		if err != nil {
			return nil, err
		}
		var head struct {
			DefinitionID string `json:"definition_id"`
			Name         string `json:"name"`
			Purpose      string `json:"purpose"`
			RecordKind   string `json:"record_kind"`
		}
		if err := json.Unmarshal(raw, &head); err != nil {
			return nil, fmt.Errorf("preset %s: %w", name, err)
		}
		if head.RecordKind != "council_definition" {
			return nil, fmt.Errorf("preset %s: record_kind is %q, and a preset is a council_definition", name, head.RecordKind)
		}
		out = append(out, Preset{
			File:         name,
			DefinitionID: head.DefinitionID,
			Name:         head.Name,
			Purpose:      head.Purpose,
			Definition:   json.RawMessage(raw),
		})
	}
	return out, nil
}
