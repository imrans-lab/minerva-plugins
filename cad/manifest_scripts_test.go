package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The host instantiates a godot_scene panel only when every script the scene
// references is in the manifest's ui.panels[].scripts whitelist. The dev lane
// skips that audit, so a script added to CADPanel.tscn and not to the manifest
// ships as a bundle whose panel never appears. This test is the gate.
//
// THE SCENE IS NOT THE WHOLE GRAPH. Most of the panel's code is reached by
// preload() from another script and never appears in the .tscn at all —
// rim_contact.gd shipped unwhitelisted that way and was caught by hand. So the
// walk starts at the scene's scripts AND the whitelist, and follows every
// preload()/load() string literal transitively; each plugin-local .gd it
// reaches has to be whitelisted too.
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
	for _, p := range m.UI.Panels {
		allowed := map[string]bool{}
		for _, s := range p.Scripts {
			allowed[filepath.ToSlash(filepath.Clean(s))] = true
		}
		// The scene's own script references seed the walk, together with
		// everything already whitelisted: a whitelisted script's preloads are
		// just as reachable at runtime as the scene's are.
		pending := []string{}
		for _, ref := range sceneScripts(t, p.Scene) {
			if !allowed[ref] {
				t.Errorf("%s references %s, not in manifest scripts[] for panel %q",
					p.Scene, ref, p.Scene)
			}
			pending = append(pending, ref)
		}
		for s := range allowed {
			pending = append(pending, s)
		}

		seen := map[string]bool{}
		for len(pending) > 0 {
			from := pending[len(pending)-1]
			pending = pending[:len(pending)-1]
			if seen[from] {
				continue
			}
			seen[from] = true
			for _, ref := range referencesFrom(t, from) {
				if strings.HasSuffix(ref, ".gd") && !allowed[ref] {
					t.Errorf("%s loads %s, not in manifest scripts[] for panel %q",
						from, ref, p.Scene)
					continue
				}
				pending = append(pending, ref)
			}
		}
	}
}

var (
	extResScript = regexp.MustCompile(`\[ext_resource type="Script" path="([^"]+)"`)
	loadLiteral  = regexp.MustCompile(`(?:^|[^A-Za-z0-9_])(?:pre)?load\("([^"]+)"\)`)
)

// The plugin-local scripts a .tscn references, plugin-root relative.
func sceneScripts(t *testing.T, scene string) []string {
	t.Helper()
	body, err := os.ReadFile(scene)
	if err != nil {
		t.Fatalf("scene %s: %v", scene, err)
	}
	out := []string{}
	for _, mm := range extResScript.FindAllStringSubmatch(string(body), -1) {
		if ref, ok := local(scene, mm[1]); ok {
			out = append(out, ref)
		}
	}
	return out
}

// What *from* pulls in at load time, plugin-root relative: the preload()/load()
// string literals of a script, or the script references of a scene. A file
// that cannot be read is a dangling reference and fails the test — a preload
// of a path that is not there is a panel that never instantiates.
func referencesFrom(t *testing.T, from string) []string {
	t.Helper()
	body, err := os.ReadFile(from)
	if err != nil {
		t.Errorf("%s is referenced but cannot be read: %v", from, err)
		return nil
	}
	if strings.HasSuffix(from, ".tscn") {
		return sceneScripts(t, from)
	}
	out := []string{}
	for _, mm := range loadLiteral.FindAllStringSubmatch(code(string(body)), -1) {
		if ref, ok := local(from, mm[1]); ok {
			out = append(out, ref)
		}
	}
	return out
}

// *body* with its GDScript comments removed. Every module in this plugin
// documents its consumers as `## Consumers: preload("scripts/x.gd")`, which
// reads as a load from the wrong directory; only code is a real reference.
// The scan tracks quotes so a `#` inside a string does not swallow the rest
// of the line.
func code(body string) string {
	out := make([]string, 0, 256)
	for _, line := range strings.Split(body, "\n") {
		quote := byte(0)
		cut := len(line)
		for i := 0; i < len(line); i++ {
			c := line[i]
			switch {
			case quote != 0:
				if c == '\\' {
					i++
				} else if c == quote {
					quote = 0
				}
			case c == '"' || c == '\'':
				quote = c
			case c == '#':
				cut = i
			}
			if cut != len(line) {
				break
			}
		}
		out = append(out, line[:cut])
	}
	return strings.Join(out, "\n")
}

// Resolve a reference made from *from* against the plugin root, and say
// whether it is the plugin's own to whitelist. A res:// path is the host's
// (or the plugin reaching out of its own tree), and an absolute path is not
// ours either.
func local(from string, ref string) (string, bool) {
	if ref == "" || filepath.IsAbs(ref) || strings.HasPrefix(ref, "res://") {
		return "", false
	}
	if strings.HasPrefix(ref, "user://") || strings.Contains(ref, "://") {
		return "", false
	}
	resolved := filepath.ToSlash(filepath.Clean(
		filepath.Join(filepath.Dir(from), ref)))
	if strings.HasPrefix(resolved, "..") {
		return "", false // out of the plugin tree; not ours to whitelist
	}
	return resolved, true
}
