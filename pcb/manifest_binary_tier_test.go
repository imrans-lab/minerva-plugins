package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// Epoch GA-4 (docket 019f985bd921): the manifest is BINARY tier — defined by
// the ABSENCE of a setup block (the host installs a prebuilt tarball; no Go
// toolchain, no Python, no on-machine compile). These assertions pin the tier
// and the packaging preconditions the release tarball depends on, so a
// regression fails a Go test instead of a marketplace user's first install.
func TestManifestIsBinaryTier(t *testing.T) {
	raw, err := os.ReadFile("manifest.json")
	if err != nil {
		t.Fatalf("read manifest.json: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse manifest.json: %v", err)
	}

	if _, ok := m["setup"]; ok {
		t.Fatalf("manifest carries a setup block — that is the SOURCE tier; " +
			"the binary tier ships prebuilt tarballs and must not ask the " +
			"user's machine for go/python toolchains")
	}

	// release_targets must agree with pcb.yml's package matrix and with
	// regen_registry.py's known-target vocabulary — a mismatch either 404s a
	// download URL or silently drops a platform from the registry.
	want := []string{"linux-x86_64", "linux-arm64", "macos-universal", "windows-x86_64"}
	got, _ := m["release_targets"].([]any)
	if len(got) != len(want) {
		t.Fatalf("release_targets = %v, want %v", got, want)
	}
	for i, w := range want {
		if got[i] != w {
			t.Fatalf("release_targets[%d] = %v, want %q (full: %v)", i, got[i], w, got)
		}
	}

	backend, _ := m["backend"].(map[string]any)
	if backend == nil || backend["entrypoint"] != "./pcb-plugin" {
		t.Fatalf("backend.entrypoint must be ./pcb-plugin (the packed binary), got %v", backend)
	}
}

// serverVersion is the extracted-runtime CACHE KEY (PluginVersion in
// sharedruntime.PythonPath): a manifest-only version bump would ship a new
// bundle that cache-hits the OLD extracted runtime, so users would run the
// previous Python worker under the new Go binary. Cold GA-4 review finding 2
// — cad carries this exact skew latent; pcb pins it.
func TestServerVersionMatchesManifest(t *testing.T) {
	raw, err := os.ReadFile("manifest.json")
	if err != nil {
		t.Fatalf("read manifest.json: %v", err)
	}
	var m struct {
		Version string `json:"version"`
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse manifest.json: %v", err)
	}
	if serverVersion != m.Version {
		t.Fatalf("main.go serverVersion %q != manifest.json version %q — "+
			"bump them in lockstep (serverVersion is the runtime-extraction "+
			"cache key)", serverVersion, m.Version)
	}
}

// The files the pack step ships beside the binary. Each is load-bearing:
// library/ because compilation is hermetic and fails closed without the seed
// lockfile; libraries.lock.json because minerva_pcb_fetch_libraries reads it
// via DefaultLockPath(pluginRoot); NOTICE.md because shipping the tarball
// redistributes KiCad-derived footprint definitions (DCR 019f761e item 7)
// and the inventory must travel with them; ui/ because the manifest declares
// godot_scene panels.
func TestPackagedDataFilesExist(t *testing.T) {
	for _, rel := range []string{
		filepath.Join("library", "footprints.lock.json"),
		filepath.Join("library", "profiles", "jlcpcb-4layer.json"),
		"libraries.lock.json",
		"NOTICE.md",
		filepath.Join("ui", "PCBPanel.gd"),
	} {
		if _, err := os.Stat(rel); err != nil {
			t.Errorf("packaging precondition missing: %s (%v)", rel, err)
		}
	}
}
