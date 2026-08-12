package tools

// Host-owned library-chain injection (B7, docket 019ff7c02fd6).
//
// One wide test per helper, epoch style. What matters here is the TRUST
// BOUNDARY, not JSON plumbing: withLibraryChain and withPromoteRoots must
// OVERRIDE caller-supplied roots unconditionally (a caller-chosen library
// path would let an LLM compile against footprint bytes + a lock it authored,
// bypassing the bless gate; a caller-chosen promote root is a move-anywhere
// primitive), and the user layer must join the chain exactly when its lock
// exists on disk — presence is decided HERE, where absence is a fact, not a
// worker-side lock-load failure (which anti-shadowing correctly refuses).

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func decodeParams(t *testing.T, raw json.RawMessage) map[string]interface{} {
	t.Helper()
	var m map[string]interface{}
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("params not a JSON object: %v", err)
	}
	return m
}

func TestWithLibraryChain_HostOwnsEveryRoot(t *testing.T) {
	dataDir := t.TempDir()
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", dataDir)

	// --- No user lock on disk: wip_root forced, layer list EMPTY (not
	// absent — an empty list must still OVERRIDE a caller-supplied one). ----
	hostile := json.RawMessage(`{
		"board": {"name": "b"},
		"wip_root": "/tmp/attacker_wip",
		"library_layers": [{"name": "user", "root": "/tmp/attacker", "lockfile": "/tmp/attacker/lock.json"}]
	}`)
	m := decodeParams(t, withLibraryChain(hostile))
	if got, want := m["wip_root"], filepath.Join(dataDir, "library_wip"); got != want {
		t.Fatalf("wip_root = %v, want host-owned %v", got, want)
	}
	layers, ok := m["library_layers"].([]interface{})
	if !ok {
		t.Fatalf("library_layers missing or not a list: %v", m["library_layers"])
	}
	if len(layers) != 0 {
		t.Fatalf("no user lock exists, yet library_layers = %v (caller-supplied layers survived the override)", layers)
	}
	if m["board"] == nil {
		t.Fatalf("caller's own non-root params must pass through untouched")
	}

	// --- User lock appears (e.g. a promote earlier in the session): the SAME
	// call now injects the user layer, host-owned paths only. ---------------
	userRoot := filepath.Join(dataDir, "library_user")
	if err := os.MkdirAll(userRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	lock := filepath.Join(userRoot, "footprints.lock.json")
	if err := os.WriteFile(lock, []byte(`{"schema_version": 2, "entries": {}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	m = decodeParams(t, withLibraryChain(hostile))
	layers, _ = m["library_layers"].([]interface{})
	if len(layers) != 1 {
		t.Fatalf("user lock exists, want exactly the user layer, got %v", layers)
	}
	layer := layers[0].(map[string]interface{})
	if layer["name"] != "user" {
		t.Fatalf("layer name = %v, want user", layer["name"])
	}
	if got, want := layer["root"], filepath.Join(userRoot, "footprints"); got != want {
		t.Fatalf("layer root = %v, want %v", got, want)
	}
	if got := layer["lockfile"]; got != lock {
		t.Fatalf("layer lockfile = %v, want %v", got, lock)
	}

	// --- Malformed params pass through unchanged (the worker's own uniform
	// parse-error handling reports them, same contract as withWIPRoot). -----
	bad := json.RawMessage(`[1,2,3]`)
	if out := withLibraryChain(bad); string(out) != string(bad) {
		t.Fatalf("malformed params rewritten: %s", out)
	}
}

func TestWithPromoteRoots_ForcesBothEnds(t *testing.T) {
	dataDir := t.TempDir()
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", dataDir)

	hostile := json.RawMessage(`{"ref": "Lib:Part", "wip_root": "/tmp/x", "dest_root": "/etc"}`)
	m := decodeParams(t, withPromoteRoots(hostile))
	if got, want := m["wip_root"], filepath.Join(dataDir, "library_wip"); got != want {
		t.Fatalf("wip_root = %v, want host-owned %v", got, want)
	}
	if got, want := m["dest_root"], filepath.Join(dataDir, "library_user"); got != want {
		t.Fatalf("dest_root = %v, want host-owned %v", got, want)
	}
	if m["ref"] != "Lib:Part" {
		t.Fatalf("caller's ref must pass through, got %v", m["ref"])
	}
}

// TestInjectionHelpers_NullParamsCannotPanic is the seal for Codex 1173 F4:
// json.Unmarshal("null", &m) succeeds with m == nil, and before the shared
// decodeParamsObject helper the injectors' map assignment PANICKED the whole
// plugin on tools/call with arguments:null — which the broker does not
// schema-validate away. null now behaves exactly like absent params (an empty
// object the host keys are injected into), while genuinely malformed shapes
// (array, scalar) still pass through untouched for the worker's own uniform
// parse-error reporting. All four injectors ride the one helper, so all four
// are sealed here.
func TestInjectionHelpers_NullParamsCannotPanic(t *testing.T) {
	dataDir := t.TempDir()
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", dataDir)

	helpers := map[string]func(json.RawMessage) json.RawMessage{
		"withWIPRoot":       withWIPRoot,
		"withPromoteRoots":  withPromoteRoots,
		"withLibraryChain":  withLibraryChain,
		"withDefaultLibDir": withDefaultLibDir,
	}
	for name, helper := range helpers {
		// null → treated as an empty object; must not panic, must inject.
		out := helper(json.RawMessage(`null`))
		m := decodeParams(t, out)
		if len(m) == 0 {
			t.Errorf("%s(null): injected nothing (%s)", name, out)
		}
		// Malformed non-objects pass through unchanged.
		for _, bad := range []string{`[1,2]`, `"x"`, `7`} {
			if got := helper(json.RawMessage(bad)); string(got) != bad {
				t.Errorf("%s(%s): rewrote malformed params to %s", name, bad, got)
			}
		}
	}
}
