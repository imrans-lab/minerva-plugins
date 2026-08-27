package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// ── panel IPC-channel parity ────────────────────────────────────────────────
//
// A scene panel may only speak on channels the manifest declares TWICE:
// Minerva's PluginScenePanelBroker registers ui.panels[i].ipc_channels, and it
// answers a request only if the channel is ALSO in the ui.ipc_messages
// allowlist the two lists must intersect. Miss either one and the broker
// replies permission_denied — silently, at runtime, in a panel nobody is
// running a suite against (bug 01a044a04f62: pcb.zone_fill was absent from
// both lists, so pours never came back live).
//
// This test closes that drift class by deriving the truth from the panel CODE
// rather than a hand-maintained list: it scans pcb/ui/*.gd for the channel
// name handed to each IPC send site and asserts every one appears in BOTH
// manifest lists. Add a channel to the panel and forget the manifest and this
// goes red; the reverse (manifest declaring a channel the panel does not yet
// use — pcb.collect_export / pcb.apply_export today) is deliberately allowed.

type panelIPCManifest struct {
	UI struct {
		Panels []struct {
			IPCChannels []string `json:"ipc_channels"`
		} `json:"panels"`
		IPCMessages []string `json:"ipc_messages"`
	} `json:"ui"`
}

// Send sites: every call whose FIRST argument is the channel name.
// _request_with_backend_ensure is the lazy-start wrapper every board round-trip
// goes through; request.emit is the raw broker signal underneath it; the
// panel's worker_check() forwards a caller-chosen channel from panel_tools.
var panelIPCSendCalls = []string{
	"_request_with_backend_ensure(",
	"request.emit(",
	"worker_check(",
}

var gdConstRe = regexp.MustCompile(`(?m)^\s*const\s+([A-Za-z_][A-Za-z0-9_]*)\s*:?=\s*"([^"]*)"`)

// blankGDComments replaces whole-line GDScript comments with empty lines so a
// prose mention of a call token cannot be mistaken for a send site, while byte
// offsets (and therefore the multi-line argument lookahead) stay intact.
func blankGDComments(src string) string {
	lines := strings.Split(src, "\n")
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			lines[i] = strings.Repeat(" ", len(line))
		}
	}
	return strings.Join(lines, "\n")
}

// panelIPCChannelsInFile returns the channel names sent from one .gd file:
// the first argument of each send call, resolved either as a direct string
// literal ("pcb.zone_fill") or through a file-local `const X := "…"` (the
// ping / start-backend channels are declared that way). A first argument that
// is a plain variable — worker_check's forwarded `channel` — carries no name
// to check and is skipped.
func panelIPCChannelsInFile(src string) []string {
	consts := map[string]string{}
	for _, m := range gdConstRe.FindAllStringSubmatch(src, -1) {
		consts[m[1]] = m[2]
	}
	src = blankGDComments(src)

	var found []string
	for _, call := range panelIPCSendCalls {
		for idx := 0; ; {
			at := strings.Index(src[idx:], call)
			if at < 0 {
				break
			}
			pos := idx + at + len(call)
			idx = pos
			// Skip whitespace, newlines and GDScript line continuations to
			// reach the first argument, which often sits on the next line.
			for pos < len(src) && strings.ContainsRune(" \t\r\n\\", rune(src[pos])) {
				pos++
			}
			if pos >= len(src) {
				break
			}
			if src[pos] == '"' {
				end := strings.IndexByte(src[pos+1:], '"')
				if end >= 0 {
					found = append(found, src[pos+1:pos+1+end])
				}
				continue
			}
			end := pos
			for end < len(src) && (src[end] == '_' || src[end] == '.' ||
				(src[end] >= '0' && src[end] <= '9') ||
				(src[end] >= 'a' && src[end] <= 'z') ||
				(src[end] >= 'A' && src[end] <= 'Z')) {
				end++
			}
			if name, ok := consts[src[pos:end]]; ok {
				found = append(found, name)
			}
		}
	}
	return found
}

func TestPanelIPCChannelsDeclaredInManifest(t *testing.T) {
	data, err := os.ReadFile("manifest.json")
	if err != nil {
		t.Fatalf("read manifest.json: %v", err)
	}
	var mf panelIPCManifest
	if err := json.Unmarshal(data, &mf); err != nil {
		t.Fatalf("parse manifest.json: %v", err)
	}
	if len(mf.UI.Panels) == 0 {
		t.Fatal("manifest declares no ui.panels — the scene panel's ipc_channels list is the broker's registration source")
	}
	registered := map[string]bool{}
	for _, c := range mf.UI.Panels[0].IPCChannels {
		registered[c] = true
	}
	allowed := map[string]bool{}
	for _, c := range mf.UI.IPCMessages {
		allowed[c] = true
	}

	gdFiles, err := filepath.Glob("ui/*.gd")
	if err != nil || len(gdFiles) == 0 {
		t.Fatalf("no ui/*.gd panel sources found (glob err %v)", err)
	}
	// channel name → the files that send on it, for a legible failure.
	senders := map[string][]string{}
	for _, path := range gdFiles {
		src, readErr := os.ReadFile(path)
		if readErr != nil {
			t.Fatalf("read %s: %v", path, readErr)
		}
		for _, ch := range panelIPCChannelsInFile(string(src)) {
			senders[ch] = append(senders[ch], filepath.Base(path))
		}
	}
	if len(senders) == 0 {
		t.Fatal("scanned ui/*.gd and found no IPC send sites — the scanner pattern has drifted from the panel code")
	}

	names := make([]string, 0, len(senders))
	for ch := range senders {
		names = append(names, ch)
	}
	sort.Strings(names)
	for _, ch := range names {
		if !registered[ch] {
			t.Errorf("panel sends on %q (%s) but ui.panels[0].ipc_channels does not register it — the broker will answer permission_denied",
				ch, strings.Join(senders[ch], ", "))
		}
		if !allowed[ch] {
			t.Errorf("panel sends on %q (%s) but the ui.ipc_messages allowlist omits it — the broker will answer permission_denied",
				ch, strings.Join(senders[ch], ", "))
		}
	}
	t.Logf("checked %d panel IPC channel(s) against both manifest lists: %v", len(names), names)
}
