// Package tools — pcb_fetch_libraries / pcb_library_status: the in-process
// (no Python worker) MCP tools fronting the Go-side library-data fetcher
// (pcb/internal/libraries/). See docs/libraries.md for the full contract.
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/pcb/internal/libraries"
)

// pluginRoot is set once at startup (main.go) so these handlers can find
// libraries.lock.json without threading a path through every call. Mirrors
// tools.SetVersion's pattern (ping.go).
var pluginRoot = "."

// SetPluginRoot records the plugin's root directory (containing manifest.json
// and libraries.lock.json). Call once at startup before any tool dispatch.
func SetPluginRoot(root string) {
	if root != "" {
		pluginRoot = root
	}
}

// notifier, if set via SetNotifier, receives (level, message, details) toasts
// — the same host.notify pipe main.go wires the worker's stderr callback to.
// nil-safe: notify() below is a no-op until SetNotifier is called.
var notifier func(level, message string, details interface{})

// SetNotifier records the host.notify emitter. Call once at startup.
func SetNotifier(fn func(level, message string, details interface{})) {
	notifier = fn
}

func notify(level, message string, details interface{}) {
	if notifier != nil {
		notifier(level, message, details)
	}
}

// ---- pcb_fetch_libraries ---------------------------------------------------

var FetchLibraries = ToolSpec{
	Name: "pcb_fetch_libraries",
	Description: "Fetch the curated KiCAD symbol/footprint library subset (pcb/libraries.lock.json) " +
		"that pcb_check_libraries/pcb_check_bom read. Downloads each locked entry, verifies it by " +
		"sha256, and skips entries already present+verified (safe to re-run). Args: none. Returns " +
		"{tag, fetched:[names], skipped:[names], failed:[{name,reason}]}. Requires network access; " +
		"never partially writes a corrupted/mismatched file (atomic temp+rename, reject on sha " +
		"mismatch). Run this once (or after refreshing pcb/libraries.lock.json) before relying on " +
		"real footprint/symbol checks — see pcb_library_status to check what's already fetched.",
	InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
}

func HandleFetchLibraries(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	lockPath := libraries.DefaultLockPath(pluginRoot)
	destDir := libraries.DefaultDir()

	notify("info", "PCB plugin: fetching KiCAD library data subset...", map[string]string{"dest": destDir})

	result, err := libraries.FetchAll(lockPath, destDir, func(event string, detail map[string]interface{}) {
		switch event {
		case "failed":
			notify("warning", "PCB plugin: library fetch entry failed", detail)
		case "summary":
			notify("info", "PCB plugin: library fetch complete", detail)
		}
	})
	if err != nil {
		return nil, err
	}
	return json.Marshal(result)
}

// ---- pcb_library_status -----------------------------------------------------

var LibraryStatus = ToolSpec{
	Name: "pcb_library_status",
	Description: "Report whether the KiCAD library-data subset (pcb/libraries.lock.json) has been " +
		"fetched and verified. Args: none. Returns {present, version_tag, entries_verified, " +
		"total_entries, missing:[names]}. present:false (or a non-empty missing[]) means " +
		"pcb_check_libraries/pcb_check_bom will report missing_data:true — run pcb_fetch_libraries " +
		"to fix. Never fails: an absent lock file or data directory reports present:false rather " +
		"than erroring.",
	InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
}

func HandleLibraryStatus(_ context.Context, _ json.RawMessage) (json.RawMessage, error) {
	lockPath := libraries.DefaultLockPath(pluginRoot)
	destDir := libraries.DefaultDir()

	st, err := libraries.GetStatus(lockPath, destDir)
	if err != nil {
		// A missing/malformed lock file is a plugin packaging problem, not a
		// per-user data problem — still never crash the tool call: report it
		// as an unpresent, zero-entry status rather than a protocol error.
		return json.Marshal(libraries.Status{Present: false, Missing: []string{}})
	}
	return json.Marshal(st)
}
