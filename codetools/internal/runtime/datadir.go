// Package runtime — datadir.go: resolves the plugin's data directory.
//
// Plugin-agnostic by design. Takes pluginID as a parameter; never hardcodes
// "cad" or any other plugin identifier. When this package is extracted to
// pkg/pyembed/ later (per DCR 019e6a4bcb0c scope amendment), this function's
// signature stays stable.
package runtime

import (
	"os"
	"path/filepath"
	goruntime "runtime"
)

// DataDir returns the absolute path where the plugin should store its private
// data (extracted runtimes, caches, scratch).
//
// Resolution order:
//
//  1. MINERVA_PLUGIN_DATA_DIR env var (set by Minerva at plugin spawn).
//  2. Per-OS XDG-equivalent default:
//     - Linux/BSD: $XDG_DATA_HOME/Minerva/plugins/<id> or ~/.local/share/Minerva/plugins/<id>
//     - macOS:     ~/Library/Application Support/Minerva/plugins/<id>
//     - Windows:   %APPDATA%/Minerva/plugins/<id>
//
// The directory is NOT created here — callers create as needed.
func DataDir(pluginID string) string {
	if env := os.Getenv("MINERVA_PLUGIN_DATA_DIR"); env != "" {
		return env
	}
	base := defaultUserDataBase()
	return filepath.Join(base, "Minerva", "plugins", pluginID)
}

func defaultUserDataBase() string {
	switch goruntime.GOOS {
	case "windows":
		if v := os.Getenv("APPDATA"); v != "" {
			return v
		}
	case "darwin":
		if home := os.Getenv("HOME"); home != "" {
			return filepath.Join(home, "Library", "Application Support")
		}
	default: // linux + other unixes
		if v := os.Getenv("XDG_DATA_HOME"); v != "" {
			return v
		}
		if home := os.Getenv("HOME"); home != "" {
			return filepath.Join(home, ".local", "share")
		}
	}
	// Last-resort fallback for environments without HOME/APPDATA set
	// (containers, CI weirdness). Not ideal but better than panicking.
	return os.TempDir()
}
