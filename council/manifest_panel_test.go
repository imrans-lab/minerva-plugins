package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"github.com/ipeerbhai/plugins/council/internal/session"
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

// The manifest is what the HOST advertises. PluginToolRegistry builds the tool
// surface Minerva exposes from manifest.tools, not from a tools/list handshake,
// so a tool the backend answers and the manifest omits is unreachable and a
// tool the manifest declares and the backend does not answer is a dead entry in
// the tool list. The chat provider makes this load-bearing rather than tidy:
// the registered entry names generate_tool and cancel_tool, and the broker
// refuses a name that is not one of this plugin's own declared tools
// (CapabilityBroker.gd:3568-3577).
//
// It also pins the three identity fields the install depends on — the id and
// version the backend reports back at initialize, and the setup step whose
// output has to be the file the backend stanza starts. Those drift silently:
// an install that builds one binary and looks for another fails at start with
// nothing in it that names the manifest.
func TestManifestAdvertisesExactlyTheToolsTheBackendAnswers(t *testing.T) {
	var m struct {
		ID      string `json:"id"`
		Version string `json:"version"`
		Backend struct {
			Entrypoint string `json:"entrypoint"`
		} `json:"backend"`
		Tools []struct {
			Name        string          `json:"name"`
			Description string          `json:"description"`
			Executor    string          `json:"executor"`
			InputSchema json.RawMessage `json:"input_schema"`
		} `json:"tools"`
		Setup struct {
			Steps []struct {
				Type   string `json:"type"`
				Output string `json:"output"`
			} `json:"steps"`
		} `json:"setup"`
		Permissions struct {
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
	if m.Version != serverVersion {
		t.Errorf("manifest version %q but the server reports %q", m.Version, serverVersion)
	}
	if m.ID != serverName {
		t.Errorf("manifest id %q but the server reports %q", m.ID, serverName)
	}
	// The setup stanza is a promise that a clean checkout produces the
	// entrypoint. If the two names drift, the install builds one file and looks
	// for another.
	if len(m.Setup.Steps) != 1 || m.Setup.Steps[0].Type != "go_build" {
		t.Fatalf("expected one go_build setup step, got %v", m.Setup.Steps)
	}
	if "./"+m.Setup.Steps[0].Output != m.Backend.Entrypoint {
		t.Errorf("the build produces %q but the backend starts %q", m.Setup.Steps[0].Output, m.Backend.Entrypoint)
	}

	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}

	declared := map[string]string{}
	declaredSchema := map[string]any{}
	for _, tool := range m.Tools {
		if tool.Description == "" {
			t.Errorf("tool %q is advertised with no description; that is what a caller reads", tool.Name)
		}
		// Every Council tool is answered by the backend process. A tool marked
		// for the panel would be dispatched into the scene instead, which has
		// no handler for one.
		if tool.Executor != "" && tool.Executor != "backend" {
			t.Errorf("tool %q declares executor %q; Council answers every tool in its backend", tool.Name, tool.Executor)
		}
		declared[tool.Name] = tool.Description
		var schema any
		if err := json.Unmarshal(tool.InputSchema, &schema); err != nil {
			t.Fatalf("tool %q: input_schema is not JSON: %v", tool.Name, err)
		}
		declaredSchema[tool.Name] = schema
	}

	answered := map[string]bool{}
	for _, spec := range newRegistry(store).specs() {
		answered[spec.Name] = true
		description, present := declared[spec.Name]
		if !present {
			t.Errorf("the backend answers %q and the manifest does not declare it, so the host never offers it", spec.Name)
			continue
		}
		if description != spec.Description {
			t.Errorf("tool %q: the manifest describes it differently from the backend, and the manifest is what a caller sees", spec.Name)
		}
		var live any
		if err := json.Unmarshal(spec.InputSchema, &live); err != nil {
			t.Fatalf("tool %q: the backend's input schema is not JSON: %v", spec.Name, err)
		}
		if !reflect.DeepEqual(live, declaredSchema[spec.Name]) {
			t.Errorf("tool %q: the manifest's input_schema differs from the one the backend advertises", spec.Name)
		}
	}
	for name := range declared {
		if !answered[name] {
			t.Errorf("the manifest declares %q, which this backend does not answer; the host would offer a tool that fails", name)
		}
	}

	// The two tools the chat entry names must be among them, and the grants
	// the registration and the model listings need must be declared: the
	// broker fails closed on an undeclared capability
	// (CapabilityBroker.gd:271-285), and host.chat_providers.unregister is
	// gated on the REGISTER grant rather than one of its own
	// (CapabilityBroker.gd:261-267).
	for _, name := range []string{chatGenerateTool, chatCancelTool} {
		if !answered[name] {
			t.Errorf("the chat entry names %q, which the backend does not answer", name)
		}
	}
	granted := map[string]bool{}
	for _, capability := range m.Permissions.HostCapabilities {
		granted[capability] = true
	}
	for _, required := range []string{
		"host.providers.chat",
		"host.chat_providers.register",
		"host.models.list_providers",
		"host.models.list_models",
	} {
		if !granted[required] {
			t.Errorf("permissions.host_capabilities must declare %q or the broker refuses the call", required)
		}
	}
}
