package session

import (
	"encoding/json"
	"fmt"

	"github.com/ipeerbhai/plugins/council/internal/contract"
)

// Every acknowledged snapshot must remain reloadable, including the failure
// records added when pending work is interrupted. Use the same transformation
// as Load rather than estimating record sizes or maintaining a second schema.
func checkSnapshotBudget(snapshot map[string]any) error {
	raw, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	largest := len(raw)
	restored := deepCopy(snapshot)
	if contract.RehydrateOnLoad(restored) > 0 {
		restored["snapshot_revision"] = num(restored["snapshot_revision"]) + 1
		raw, err = json.Marshal(restored)
		if err != nil {
			return err
		}
		if len(raw) > largest {
			largest = len(raw)
		}
	}
	if largest > MaxEnvelopeBytes {
		return fmt.Errorf("Council needs %d bytes to save and reopen this snapshot, including interruption records; v0.1 permits %d. This change was not applied. Reduce the content or use a separate Council document", largest, MaxEnvelopeBytes)
	}
	return nil
}
