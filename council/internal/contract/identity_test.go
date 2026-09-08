package contract

import (
	"encoding/json"
	"testing"

	"github.com/ipeerbhai/plugins/council/fixtures"
)

func TestSessionIdentitiesAreUnambiguous(t *testing.T) {
	registry, err := LoadRegistry()
	if err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"run", "contribution", "outcome"} {
		t.Run(kind, func(t *testing.T) {
			raw, err := fixtures.FS.ReadFile("project_snapshot.json")
			if err != nil {
				t.Fatal(err)
			}
			var snap map[string]any
			if err := json.Unmarshal(raw, &snap); err != nil {
				t.Fatal(err)
			}
			ses := obj(arr(snap["sessions"])[0])
			runs := arr(ses["runs"])
			switch kind {
			case "run":
				ses["outcomes"] = []any{}
				obj(runs[1])["run_id"] = obj(runs[0])["run_id"]
			case "contribution":
				obj(arr(obj(runs[0])["contributions"])[1])["contribution_id"] = obj(arr(obj(runs[0])["contributions"])[0])["contribution_id"]
			case "outcome":
				ses["outcomes"] = append(arr(ses["outcomes"]), arr(ses["outcomes"])[0])
			}
			raw, _ = json.Marshal(snap)
			if errs := registry.ValidateRecord("council_project_snapshot", raw); len(errs) == 0 {
				t.Fatal("accepted duplicate " + kind + " identity")
			}
		})
	}
}
