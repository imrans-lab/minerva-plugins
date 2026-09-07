package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// The host instantiates a godot_scene panel only when every script the scene
// references is in the manifest's ui.panels[].scripts whitelist. The dev lane
// skips that audit, so a script added to CADPanel.tscn and not to the manifest
// ships as a bundle whose panel never appears. This test is the gate.
func TestPanelSceneScriptsAreWhitelisted(t *testing.T) {
	raw, err := os.ReadFile("manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var m struct {
		UI struct {
			Panels []struct {
				Scene   string   `json:"entry_scene"`
				Scripts []string `json:"scripts"`
			} `json:"panels"`
		} `json:"ui"`
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if len(m.UI.Panels) == 0 {
		t.Fatal("manifest declares no ui.panels")
	}
	extRes := regexp.MustCompile(`\[ext_resource type="Script" path="([^"]+)"`)
	for _, p := range m.UI.Panels {
		allowed := map[string]bool{}
		for _, s := range p.Scripts {
			allowed[s] = true
		}
		scene, err := os.ReadFile(p.Scene)
		if err != nil {
			t.Fatalf("panel scene %s: %v", p.Scene, err)
		}
		for _, mm := range extRes.FindAllStringSubmatch(string(scene), -1) {
			ref := mm[1]
			if filepath.IsAbs(ref) || len(ref) > 6 && ref[:6] == "res://" {
				continue // a host-side script, not the plugin's to whitelist
			}
			rel := filepath.ToSlash(filepath.Join(filepath.Dir(p.Scene), ref))
			if !allowed[rel] {
				t.Errorf("%s references %s, not in manifest scripts[] for panel %q", p.Scene, rel, p.Scene)
			}
		}
	}
}
