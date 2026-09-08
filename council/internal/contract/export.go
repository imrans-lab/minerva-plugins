package contract

import "encoding/json"

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
// includeContent decides whether the captured source bytes travel with the
// definition. Dropping them keeps an export small and avoids carrying material
// the user may not want to share; keeping them makes the export self-contained.
// Either way the inventory is present, so the receiving side can tell.
func ExportDefinition(def map[string]any, includeContent bool) (map[string]any, error) {
	raw, err := json.Marshal(def)
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	for _, s := range arr(out["sources"]) {
		source := obj(s)
		delete(source, "artifact")
		if !includeContent {
			delete(source, "payload")
		}
	}
	return out, nil
}
