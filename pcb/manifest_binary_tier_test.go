package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Epoch GA-4 (docket 019f985bd921): what a marketplace user installs is BINARY
// tier — a prebuilt tarball; no Go toolchain, no Python, no on-machine compile.
// The tier used to be pinned by the ABSENCE of a setup block in this file,
// because the repo manifest was shipped verbatim in the tarball.
//
// That coupling is gone (2026-08-16). Minerva now records an install lane and
// never builds a stanza on the marketplace lane, and pcb.yml's pack step
// strips `setup` from the packed copy — so the repo manifest can declare how
// to build pcb from a checkout (source tier, dev installs) while the tarball
// stays binary tier. The guarantee is unchanged; only its enforcement point
// moved, so this test moved with it: the stanza is now allowed HERE and
// forbidden THERE, and the strip that separates them is itself asserted.
func TestManifestIsBinaryTier(t *testing.T) {
	raw, err := os.ReadFile("manifest.json")
	if err != nil {
		t.Fatalf("read manifest.json: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse manifest.json: %v", err)
	}

	// A stanza here is only safe while the pack step removes it. If someone
	// deletes the strip, the next release would carry a build recipe to hosts
	// that have no source to run it against — fail here instead.
	if _, ok := m["setup"]; ok {
		wf, err := os.ReadFile(filepath.Join("..", ".github", "workflows", "pcb.yml"))
		if err != nil {
			t.Fatalf("manifest carries a setup block but pcb.yml is unreadable: %v", err)
		}
		if !strings.Contains(string(wf), `m.pop('setup',None)`) {
			t.Fatalf("manifest carries a setup block (SOURCE tier) but pcb.yml's " +
				"pack step no longer strips it — the release tarball would ship a " +
				"build recipe to machines with no source and no toolchain")
		}
		// Compare against the command that WRITES the sums file (`> SHA256SUMS`),
		// not the bare word — that also appears in the pack step's comments.
		if strings.Index(string(wf), `m.pop('setup',None)`) > strings.Index(string(wf), "> SHA256SUMS") {
			t.Fatalf("pcb.yml strips setup AFTER SHA256SUMS is computed — the " +
				"checksum would not match the packed manifest")
		}
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
// lockfile, and because assembly_outputs loads its service profile from
// library/service-profiles at import — a bundle missing it cannot export at all; libraries.lock.json because minerva_pcb_fetch_libraries reads it
// via DefaultLockPath(pluginRoot); NOTICE.md because shipping the tarball
// redistributes KiCad-derived footprint definitions (DCR 019f761e item 7)
// and the inventory must travel with them; ui/ because the manifest declares
// godot_scene panels.
func TestPackagedDataFilesExist(t *testing.T) {
	for _, rel := range []string{
		filepath.Join("library", "footprints.lock.json"),
		filepath.Join("library", "profiles", "jlcpcb-4layer.json"),
		filepath.Join("library", "service-profiles", "jlcpcb-economic.json"),
		"libraries.lock.json",
		"NOTICE.md",
		filepath.Join("ui", "PCBPanel.gd"),
	} {
		if _, err := os.Stat(rel); err != nil {
			t.Errorf("packaging precondition missing: %s (%v)", rel, err)
		}
	}
}
