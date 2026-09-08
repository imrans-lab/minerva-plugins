package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The manifest is what the host mounts the panel from, and every claim in it is
// checkable without Godot. The host resolves entry_scene, preloads each declared
// script, and then AUDITS the scene: a script the scene references and the
// manifest does not declare makes the panel refuse to instantiate, and the user
// sees a diagnostic placeholder instead of Council. The dev lane and the
// marketplace lane both go through that audit, so a manifest that has drifted
// from the files is a dead panel, not a warning.
//
// This is the small version of cad/manifest_scripts_test.go, whose walk is
// transitive because that panel's graph is large. Council's is four scripts and
// one scene, so the same properties are asserted directly.
func TestManifestDeclaresExactlyThePanelThatExists(t *testing.T) {
	var m struct {
		UI struct {
			IPCMessages []string `json:"ipc_messages"`
			Panels      []struct {
				Name        string   `json:"name"`
				Kind        string   `json:"kind"`
				Scene       string   `json:"entry_scene"`
				Scripts     []string `json:"scripts"`
				IPCChannels []string `json:"ipc_channels"`
				SaveMode    string   `json:"save_mode"`
				Extensions  []string `json:"file_extensions"`
			} `json:"panels"`
		} `json:"ui"`
		EditorItems []struct {
			Panel string `json:"panel"`
		} `json:"editor_items"`
		Capabilities []string `json:"capabilities"`
		Permissions  struct {
			HostCapabilities []string `json:"host_capabilities"`
		} `json:"permissions"`
	}
	raw, err := os.ReadFile("manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if len(m.UI.Panels) != 1 {
		t.Fatalf("expected exactly one panel, got %d", len(m.UI.Panels))
	}
	panel := m.UI.Panels[0]

	// host_owned_save is validated at install time against the panel: the hooks
	// have to be declared, the panel has to own a file extension, and it has to
	// be a godot_scene saving host_owned. A capability the panel cannot back
	// fails the install, not the first save.
	if panel.Kind != "godot_scene" || panel.SaveMode != "host_owned" || len(panel.Extensions) == 0 {
		t.Errorf("panel %q must be a godot_scene with host_owned save and a file extension; got kind=%q save_mode=%q extensions=%v",
			panel.Name, panel.Kind, panel.SaveMode, panel.Extensions)
	}

	declared := map[string]bool{}
	for _, script := range panel.Scripts {
		declared[filepath.ToSlash(filepath.Clean(script))] = true
		if _, err := os.Stat(script); err != nil {
			t.Errorf("manifest declares script %s, which is not in the plugin: %v", script, err)
		}
	}

	// Everything the scene and the declared scripts pull in at load time has to
	// be declared too. That is the audit's rule, and it is transitive here only
	// because the graph is one scene deep.
	for _, ref := range loadedBy(t, panel.Scene) {
		if !declared[ref] {
			t.Errorf("%s references %s, which the manifest does not declare", panel.Scene, ref)
		}
	}
	for script := range declared {
		for _, ref := range loadedBy(t, script) {
			if strings.HasSuffix(ref, ".gd") && !declared[ref] {
				t.Errorf("%s loads %s, which the manifest does not declare", script, ref)
			}
		}
	}

	// The panel's channels are checked against the manifest allowlist at parse
	// time; a channel in one list and not the other is refused at install.
	allowed := map[string]bool{}
	for _, message := range m.UI.IPCMessages {
		allowed[message] = true
	}
	for _, channel := range panel.IPCChannels {
		if !allowed[channel] {
			t.Errorf("panel channel %q is not in ui.ipc_messages", channel)
		}
	}

	// The one host capability the panel calls: the chat handoff. It is a grant,
	// so a missing declaration is a permission denial at the moment a user
	// presses the button.
	if !contains(m.Permissions.HostCapabilities, "mcp.proxy:minerva_send_message") {
		t.Error("the panel sends a selection to a bound chat and needs the mcp.proxy:minerva_send_message grant")
	}
	if !contains(m.UI.IPCMessages, "capability:mcp.proxy:minerva_send_message") {
		t.Error("a capability channel still has to be in ui.ipc_messages; the broker checks it there too")
	}

	// The page itself, which the panel stages and loads as a file:// URL.
	if _, err := os.Stat(filepath.Join("ui", "panel.html")); err != nil {
		t.Errorf("the panel's page is missing: %v", err)
	}

	for _, item := range m.EditorItems {
		if item.Panel != panel.Name {
			t.Errorf("editor item names panel %q, which is not declared", item.Panel)
		}
	}
}

var (
	sceneScript = regexp.MustCompile(`\[ext_resource type="Script" path="([^"]+)"`)
	loadCall    = regexp.MustCompile(`(?:^|[^A-Za-z0-9_])(?:pre)?load\("([^"]+)"\)`)
	extendsFile = regexp.MustCompile(`(?m)^extends\s+"([^"]+)"`)
)

// The plugin-local files `from` pulls in at load time, as plugin-root-relative
// paths. A reference that cannot be read fails the test: a preload of a path
// that is not there is a panel that never instantiates.
func loadedBy(t *testing.T, from string) []string {
	t.Helper()
	body, err := os.ReadFile(from)
	if err != nil {
		t.Errorf("%s is referenced but cannot be read: %v", from, err)
		return nil
	}
	patterns := []*regexp.Regexp{loadCall, extendsFile}
	if strings.HasSuffix(from, ".tscn") {
		patterns = []*regexp.Regexp{sceneScript}
	}
	out := []string{}
	for _, re := range patterns {
		for _, match := range re.FindAllStringSubmatch(string(body), -1) {
			// res:// is a host path, not a plugin file; everything else is
			// relative to the referring file.
			if strings.HasPrefix(match[1], "res://") {
				continue
			}
			out = append(out, filepath.ToSlash(filepath.Clean(
				filepath.Join(filepath.Dir(from), match[1]))))
		}
	}
	return out
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
