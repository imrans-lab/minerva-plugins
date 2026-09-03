// Package runtime — cachedir.go: resolves the plugin's regenerable-data cache.
//
// Plugin-agnostic by design, like datadir.go. Takes pluginID as a parameter;
// never hardcodes a plugin identifier.
//
// # WHAT THIS IS FOR
//
// One place per user for data the plugin FETCHED or DERIVED and can always
// rebuild — vendor downloads, expensive renders, parsed intermediates. It is
// deliberately not a repository (committing regenerable binaries is forbidden)
// and not the installed bundle (a reinstall replaces that tree, so anything
// written there is lost).
//
// # WHY IT HANGS OFF DataDir AND NOT os.UserCacheDir
//
// A second per-user root is the failure this exists to prevent: two roots
// eventually disagree about which one a given machine is using. DataDir is
// already THE per-user, per-OS directory for this plugin — the extracted
// Python runtime lives at <DataDir>/runtime/<version>/ — so the cache is its
// sibling at <DataDir>/cache/ rather than a freshly resolved OS cache path.
//
// HONEST SEMANTICS: DataDir is the platform DATA directory (XDG_DATA_HOME,
// ~/Library/Application Support, %APPDATA%), NOT the platform cache directory.
// So "safe to delete at any moment" is a promise THIS package makes, through
// the subtree's name and the contract below. It does not come from the
// platform convention, and no OS housekeeping will ever clean this up.
//
// THE CONTRACT
//
//   - Nothing under CacheDir is a source of truth. A missing entry is
//     refetched or recomputed.
//   - Deleting the whole subtree at any moment leaves the plugin working.
//   - Callers namespace their entries by tenant, so one tenant's data cannot
//     collide with another's.
//   - An unavailable or unwritable cache degrades to no caching, with a
//     report. It is never fatal.
//
// Anything that IS a source of truth (user libraries, authored boards) belongs
// under DataDir directly, beside cache/, never inside it.
package runtime

import (
	"fmt"
	"os"
	"path/filepath"
)

// CacheSubdir is the DataDir-relative name of the cache subtree. The name is
// load-bearing: it is what tells a human poking around their data directory
// that this tree is disposable.
const CacheSubdir = "cache"

// CacheDir returns the absolute path of the plugin's regenerable-data cache:
// <DataDir(pluginID)>/cache. See the package comment for the contract.
//
// Pure path construction — the directory is neither created nor checked here.
// Use EnsureCacheDir when you need it to exist.
func CacheDir(pluginID string) string {
	return filepath.Join(DataDir(pluginID), CacheSubdir)
}

// EnsureCacheDir returns CacheDir(pluginID) after making sure it exists.
//
// It reports an error rather than degrading, because the caller is the one
// that decides what "no cache" means for it — the pcb plugin, for instance,
// simply omits the environment variable so the worker sees no cache at all.
//
// Deliberately NOT a writability probe. The tree can be deleted or chmod'd at
// any moment after this returns, so a startup probe would be a snapshot that
// lies for the rest of the process's life. The authoritative check is the
// tenant-level directory creation at the moment of use, which must degrade to
// no caching on failure.
func EnsureCacheDir(pluginID string) (string, error) {
	dir := CacheDir(pluginID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("cache dir %s: %w", dir, err)
	}
	return dir, nil
}
