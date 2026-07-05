// Package libraries fetches, verifies, and reports on the KiCAD library-data
// subset check_libraries/check_bom read (pcb/docs/libraries.md). The library
// DATA itself is never checked into this repo (no-FCIB policy) — only this
// lock manifest (URLs + sha256 + size) and this code are. Data lands under
// DefaultDir() at runtime, fetched on demand by the pcb_fetch_libraries tool.
package libraries

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	sharedruntime "github.com/imrans-lab/minerva-plugins/shared/runtime"
)

// Entry is one lock-manifest entry: a single file fetched from a pinned URL,
// verified by sha256, and written to destDir/Dest.
type Entry struct {
	// Name is a human-readable identifier (also the dedup key in reports).
	Name string `json:"name"`
	// Kind is "symbol_lib" or "footprint" — informational only.
	Kind string `json:"kind"`
	// Dest is the path (using "/" separators in the JSON, converted to the
	// host's separator on use) relative to destDir this entry is written to.
	// Preserves the KiCad "<Lib>.pretty/<Name>.kicad_mod" / "<Lib>.kicad_sym"
	// shape check_libraries/check_bom expect (pcb/worker/pcb_worker/libcheck.py).
	Dest string `json:"dest"`
	// URL is the pinned, tag-scoped source URL (immutable per KiCAD release tag).
	URL string `json:"url"`
	// SHA256 is the expected hex-encoded sha256 of the fetched bytes.
	SHA256 string `json:"sha256"`
	// SizeBytes is the expected size, recorded at lock-generation time.
	// Informational (used for progress/reporting) — verification is by
	// sha256, not size.
	SizeBytes int64 `json:"size_bytes"`
}

// Lock is the parsed libraries.lock.json manifest.
type Lock struct {
	SchemaVersion int    `json:"schema_version"`
	Tag           string `json:"tag"`
	GeneratedAt   string `json:"generated_at"`
	Source        struct {
		SymbolsRepo    string `json:"symbols_repo"`
		FootprintsRepo string `json:"footprints_repo"`
	} `json:"source"`
	Entries []Entry `json:"entries"`
}

// LoadLock parses a libraries.lock.json file.
func LoadLock(lockPath string) (*Lock, error) {
	data, err := os.ReadFile(lockPath)
	if err != nil {
		return nil, fmt.Errorf("libraries.LoadLock: read %s: %w", lockPath, err)
	}
	var lock Lock
	if err := json.Unmarshal(data, &lock); err != nil {
		return nil, fmt.Errorf("libraries.LoadLock: parse %s: %w", lockPath, err)
	}
	if len(lock.Entries) == 0 {
		return nil, fmt.Errorf("libraries.LoadLock: %s has no entries", lockPath)
	}
	for i, e := range lock.Entries {
		if e.Name == "" || e.Dest == "" || e.URL == "" || e.SHA256 == "" {
			return nil, fmt.Errorf("libraries.LoadLock: entry %d missing a required field (name/dest/url/sha256)", i)
		}
	}
	return &lock, nil
}

// DestPath returns the absolute filesystem path for an entry under destDir,
// converting the lock's "/"-separated Dest to the host separator.
func (e Entry) DestPath(destDir string) string {
	return filepath.Join(destDir, filepath.FromSlash(e.Dest))
}

// DefaultLockPath returns the conventional lock-manifest path relative to the
// plugin root (the directory containing manifest.json / the pcb-plugin binary).
func DefaultLockPath(pluginRoot string) string {
	return filepath.Join(pluginRoot, "libraries.lock.json")
}

// DefaultDir returns the directory library data is fetched into: the plugin's
// data directory (resolved the same way every other plugin data path is —
// shared/runtime.DataDir, which honors MINERVA_PLUGIN_DATA_DIR) with a
// "libraries" subdirectory. Not created here — callers create as needed.
func DefaultDir() string {
	return filepath.Join(sharedruntime.DataDir("pcb"), "libraries")
}
