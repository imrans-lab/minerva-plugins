package contract

import (
	"encoding/json"
	"fmt"
	"sort"
)

// ExportDefinition produces the portable form of a council definition.
//
// A definition held inside a project may point at that project's notes: a
// source captured from a note carries the note's identity so the panel can open
// it. Those identities are meaningless — and leaky — in another project, so the
// export strips every artifact reference and leaves the inventory entry behind:
// title, author, locator, capture time, hash and anchors. An import can then
// say exactly which material it could not find instead of quietly presenting an
// ungrounded member as grounded.
//
// includeContent decides whether captured source bytes travel at all, and
// selected names which sources they travel for. Inclusion is a deliberate act
// per source: a council often mixes material the user is happy to share with
// notes they are not, and a single all-or-nothing switch makes the cautious
// choice cost the whole grounding. A nil selection with includeContent means
// every source travels; an empty non-nil selection means none does.
//
// Naming sources while includeContent is false is a contradiction and is
// refused rather than answered by withholding them: the caller asked for
// material to travel, and an export that quietly carries none of it is exactly
// the ungrounded-looking-grounded artifact this function exists to prevent.
//
// The inventory is present either way, so the receiving side can always tell
// what it is missing, and the content_hash on each source says exactly which
// material would repair it.
//
// It returns the ids whose content travelled and the ids withheld, so a caller
// can show the user what is actually leaving the project rather than asserting
// it.
func ExportDefinition(def map[string]any, includeContent bool, selected []string) (portable map[string]any, included, withheld []string, err error) {
	raw, err := json.Marshal(def)
	if err != nil {
		return nil, nil, nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, nil, nil, err
	}

	// Naming sources to include while including no content at all is a
	// contradiction, and the harmless-looking answer — withhold them anyway —
	// is the dangerous one: the user chose material to share and would be
	// handed an export that quietly shares none of it.
	if !includeContent && len(selected) > 0 {
		named := append([]string(nil), selected...)
		sort.Strings(named)
		return nil, nil, nil, fmt.Errorf(
			"include_content is false but %v were named for inclusion; either include their content or name nothing", named)
	}

	known := map[string]bool{}
	for _, s := range arr(out["sources"]) {
		known[str(obj(s)["source_id"])] = true
	}
	wanted := map[string]bool{}
	if selected != nil {
		var unknown []string
		for _, id := range selected {
			if !known[id] {
				unknown = append(unknown, id)
				continue
			}
			wanted[id] = true
		}
		// A typo in the selection would otherwise ship an export the user
		// believes is grounded and which silently is not.
		if len(unknown) > 0 {
			sort.Strings(unknown)
			return nil, nil, nil, fmt.Errorf("these sources are not in this council: %v", unknown)
		}
	}

	// Selection is per source, not per capture: every revision of a chosen
	// source travels, so an old contribution can still be read against the
	// bytes it was actually grounded in.
	included, withheld = []string{}, []string{}
	listed := map[string]bool{}
	for _, s := range arr(out["sources"]) {
		source := obj(s)
		delete(source, "artifact")
		id := str(source["source_id"])
		keep := includeContent && (selected == nil || wanted[id])
		if !keep {
			delete(source, "payload")
		}
		if listed[id] {
			continue
		}
		listed[id] = true
		if keep {
			included = append(included, id)
		} else {
			withheld = append(withheld, id)
		}
	}
	return out, included, withheld, nil
}
