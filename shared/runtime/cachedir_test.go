package runtime

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCacheDir_SitsBesideTheExtractedRuntime is the "one root, not two" oracle.
// It extracts a REAL runtime (the synthetic bundle from extract_test.go) and
// then resolves the cache, and asserts the two land in the same per-user data
// directory. If someone later re-resolves the cache from os.UserCacheDir or a
// second hand-rolled per-OS walk, the shared parent disappears and this fails.
func TestCacheDir_SitsBesideTheExtractedRuntime(t *testing.T) {
	dataDir := t.TempDir()
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", dataDir)

	bundle, sum := makeSyntheticBundle(t)
	runtimeRoot, err := EnsureRuntime(EnsureRuntimeRequest{
		EmbeddedBundle: bundle,
		EmbeddedSHA256: sum,
		PluginID:       "testplug",
		PluginVersion:  "1.2.3",
		DataDir:        DataDir("testplug"),
	})
	if err != nil {
		t.Fatalf("EnsureRuntime: %v", err)
	}

	cacheDir, err := EnsureCacheDir("testplug")
	if err != nil {
		t.Fatalf("EnsureCacheDir: %v", err)
	}

	// The cache is a CHILD of the directory the runtime tree lives under —
	// <data>/cache beside <data>/runtime/<version>.
	if got, want := filepath.Dir(cacheDir), dataDir; got != want {
		t.Errorf("cache parent = %q, want the data dir %q", got, want)
	}
	runtimeParent := filepath.Dir(filepath.Dir(runtimeRoot)) // strip <version>/runtime
	if runtimeParent != dataDir {
		t.Fatalf("test premise broken: runtime parent = %q, want %q", runtimeParent, dataDir)
	}
	if filepath.Dir(cacheDir) != runtimeParent {
		t.Errorf("cache %q and runtime %q do not share a per-user root", cacheDir, runtimeRoot)
	}

	// EnsureCacheDir must actually have created it, and CacheDir must agree
	// with what EnsureCacheDir returned (pure path vs created path).
	if info, err := os.Stat(cacheDir); err != nil || !info.IsDir() {
		t.Errorf("cache dir %q not created: err=%v", cacheDir, err)
	}
	if CacheDir("testplug") != cacheDir {
		t.Errorf("CacheDir = %q, EnsureCacheDir = %q — must agree",
			CacheDir("testplug"), cacheDir)
	}

	// Idempotent: a second call on an existing tree is not an error, and a
	// deleted tree is rebuilt. Both are the "safe to delete at any moment"
	// promise, checked rather than asserted in a comment.
	if _, err := EnsureCacheDir("testplug"); err != nil {
		t.Errorf("second EnsureCacheDir: %v", err)
	}
	if err := os.RemoveAll(cacheDir); err != nil {
		t.Fatalf("RemoveAll: %v", err)
	}
	if _, err := EnsureCacheDir("testplug"); err != nil {
		t.Errorf("EnsureCacheDir after deletion: %v", err)
	}
	if info, err := os.Stat(cacheDir); err != nil || !info.IsDir() {
		t.Errorf("cache dir not rebuilt after deletion: err=%v", err)
	}
}

// TestCacheDir_DefaultIsOffRepoAndOffBundle pins the production resolution
// (no MINERVA_PLUGIN_DATA_DIR override): the cache must land under the user's
// per-OS home base, and must NOT land inside the source tree the test runs
// from or beside the running executable, which stands in for the installed
// bundle. All three home variables are set so this holds on whichever platform
// the test runs — Linux reads XDG_DATA_HOME, macOS HOME, Windows APPDATA.
func TestCacheDir_DefaultIsOffRepoAndOffBundle(t *testing.T) {
	home := t.TempDir()
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", "")
	t.Setenv("XDG_DATA_HOME", home)
	t.Setenv("HOME", home)
	t.Setenv("APPDATA", home)

	got := CacheDir("pcb")
	if !filepath.IsAbs(got) {
		t.Fatalf("CacheDir = %q, want an absolute path", got)
	}
	if !strings.HasPrefix(got, home+string(os.PathSeparator)) {
		t.Errorf("CacheDir = %q, want it under the per-user home base %q", got, home)
	}
	if filepath.Base(got) != CacheSubdir {
		t.Errorf("CacheDir = %q, want it to end in %q so its disposability is legible", got, CacheSubdir)
	}
	if !strings.Contains(got, "pcb") {
		t.Errorf("CacheDir = %q, want the plugin id in the path", got)
	}

	// Off-repo: the test's working directory is inside the checkout.
	repo, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if within(got, repo) {
		t.Errorf("CacheDir = %q is inside the source tree %q — regenerable data must never land in a repository", got, repo)
	}

	// Off-bundle: the running executable stands in for the installed plugin
	// tree, which a reinstall replaces.
	exe, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}
	if within(got, filepath.Dir(exe)) {
		t.Errorf("CacheDir = %q is inside the executable's dir %q — a reinstall would erase it", got, filepath.Dir(exe))
	}
}

// within reports whether path is dir itself or lives beneath it.
func within(path, dir string) bool {
	rel, err := filepath.Rel(dir, path)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator))
}
