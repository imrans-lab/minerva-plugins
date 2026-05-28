package runtime

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/klauspost/compress/zstd"
)

// makeSyntheticBundle builds an in-memory tar.zst containing:
//   - bin/python3 (a fake script with mode 0o755)
//   - lib/python3.12/site-packages/build123d/__init__.py (text)
//   - manifest.sha256 covering both
//
// Returns the bundle bytes + their sha256-hex.
func makeSyntheticBundle(t *testing.T) (bundle []byte, sum string) {
	t.Helper()

	// Files (rel-path → mode, content).
	files := []struct {
		path    string
		mode    int64
		content string
	}{
		{"bin/python3", 0o755, "#!/bin/sh\necho fake-python\n"},
		{"lib/python3.12/site-packages/build123d/__init__.py", 0o644, "__version__ = '0.10.0'\n"},
	}

	// Compute file sha256s for manifest.
	manifestLines := ""
	hashes := map[string]string{}
	for _, f := range files {
		h := sha256.Sum256([]byte(f.content))
		hex := hex.EncodeToString(h[:])
		hashes[f.path] = hex
		manifestLines += fmt.Sprintf("%s  %s\n", hex, f.path)
	}

	// Assemble tar entries (sorted to match the bundle script's portable
	// `find | sort | tar -T -` invariant; manifest.sha256 is excluded from
	// the manifest itself).
	var tarBuf bytes.Buffer
	tw := tar.NewWriter(&tarBuf)
	writeEntry := func(name string, mode int64, body string) {
		hdr := &tar.Header{
			Name:     name,
			Mode:     mode,
			Size:     int64(len(body)),
			Typeflag: tar.TypeReg,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatalf("tar header: %v", err)
		}
		if _, err := tw.Write([]byte(body)); err != nil {
			t.Fatalf("tar body: %v", err)
		}
	}
	for _, f := range files {
		writeEntry(f.path, f.mode, f.content)
	}
	writeEntry("manifest.sha256", 0o644, manifestLines)
	if err := tw.Close(); err != nil {
		t.Fatalf("tar close: %v", err)
	}

	// zstd-compress.
	var zBuf bytes.Buffer
	zw, err := zstd.NewWriter(&zBuf)
	if err != nil {
		t.Fatalf("zstd writer: %v", err)
	}
	if _, err := zw.Write(tarBuf.Bytes()); err != nil {
		t.Fatalf("zstd write: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zstd close: %v", err)
	}
	bundle = zBuf.Bytes()
	h := sha256.Sum256(bundle)
	sum = hex.EncodeToString(h[:])
	return bundle, sum
}

func TestEnsureRuntime_ColdCache(t *testing.T) {
	dataDir := t.TempDir()
	bundle, sum := makeSyntheticBundle(t)

	req := EnsureRuntimeRequest{
		EmbeddedBundle: bundle,
		EmbeddedSHA256: sum,
		PluginID:       "testplug",
		PluginVersion:  "1.2.3",
		DataDir:        dataDir,
	}
	root, err := EnsureRuntime(req)
	if err != nil {
		t.Fatalf("EnsureRuntime: %v", err)
	}
	wantRoot := filepath.Join(dataDir, "runtime", "1.2.3")
	if root != wantRoot {
		t.Errorf("root = %q, want %q", root, wantRoot)
	}
	// Expected files present and matching synthetic content.
	if _, err := os.Stat(filepath.Join(root, "bin", "python3")); err != nil {
		t.Errorf("bin/python3 missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "manifest.sha256")); err != nil {
		t.Errorf("manifest.sha256 missing: %v", err)
	}
	// File mode preserved for the executable.
	info, err := os.Stat(filepath.Join(root, "bin", "python3"))
	if err != nil {
		t.Fatalf("stat bin/python3: %v", err)
	}
	if info.Mode().Perm()&0o100 == 0 {
		t.Errorf("bin/python3 not executable: mode=%v", info.Mode())
	}
}

func TestEnsureRuntime_WarmCache(t *testing.T) {
	dataDir := t.TempDir()
	bundle, sum := makeSyntheticBundle(t)
	req := EnsureRuntimeRequest{
		EmbeddedBundle: bundle, EmbeddedSHA256: sum,
		PluginID: "testplug", PluginVersion: "1.0.0", DataDir: dataDir,
	}

	// Cold extract.
	root1, err := EnsureRuntime(req)
	if err != nil {
		t.Fatalf("cold: %v", err)
	}
	// Mark the extracted dir with a sentinel file so we can detect re-extract.
	sentinel := filepath.Join(root1, ".warm-test-sentinel")
	if err := os.WriteFile(sentinel, []byte("present"), 0o644); err != nil {
		t.Fatalf("sentinel write: %v", err)
	}

	// Second call should be a cache hit (manifest.sha256 valid) and NOT
	// re-extract — sentinel survives.
	root2, err := EnsureRuntime(req)
	if err != nil {
		t.Fatalf("warm: %v", err)
	}
	if root1 != root2 {
		t.Errorf("roots differ: %q vs %q", root1, root2)
	}
	if _, err := os.Stat(sentinel); err != nil {
		t.Errorf("warm cache re-extracted (sentinel lost): %v", err)
	}
}

func TestEnsureRuntime_TamperDetect(t *testing.T) {
	dataDir := t.TempDir()
	bundle, sum := makeSyntheticBundle(t)
	req := EnsureRuntimeRequest{
		EmbeddedBundle: bundle, EmbeddedSHA256: sum,
		PluginID: "testplug", PluginVersion: "1.0.0", DataDir: dataDir,
	}

	root, err := EnsureRuntime(req)
	if err != nil {
		t.Fatalf("first: %v", err)
	}
	// Corrupt the python file in-place.
	pyPath := filepath.Join(root, "bin", "python3")
	if err := os.WriteFile(pyPath, []byte("not the original content"), 0o755); err != nil {
		t.Fatalf("corrupt: %v", err)
	}

	// Cache validation should reject (sha mismatch in manifest), prompting
	// re-extract. After EnsureRuntime returns, the file should be back to
	// original content.
	if _, err := EnsureRuntime(req); err != nil {
		t.Fatalf("second EnsureRuntime: %v", err)
	}
	got, err := os.ReadFile(pyPath)
	if err != nil {
		t.Fatalf("read after re-extract: %v", err)
	}
	if !bytes.Equal(got, []byte("#!/bin/sh\necho fake-python\n")) {
		t.Errorf("post-re-extract content = %q, want fake-python script", got)
	}
}

func TestEnsureRuntime_BadEmbeddedSHA(t *testing.T) {
	dataDir := t.TempDir()
	bundle, _ := makeSyntheticBundle(t)
	req := EnsureRuntimeRequest{
		EmbeddedBundle: bundle,
		EmbeddedSHA256: "0000000000000000000000000000000000000000000000000000000000000000",
		PluginID:       "testplug", PluginVersion: "1.0.0", DataDir: dataDir,
	}
	if _, err := EnsureRuntime(req); err == nil {
		t.Fatal("expected sha mismatch error, got nil")
	}
	// Ensure nothing was extracted.
	if entries, _ := os.ReadDir(filepath.Join(dataDir, "runtime", "1.0.0")); len(entries) != 0 {
		t.Errorf("partial extract on sha-mismatch: %d entries", len(entries))
	}
}

func TestEnsureRuntime_EmptyBundle(t *testing.T) {
	dataDir := t.TempDir()
	req := EnsureRuntimeRequest{
		EmbeddedBundle: nil,
		EmbeddedSHA256: "",
		PluginID:       "testplug", PluginVersion: "1.0.0", DataDir: dataDir,
	}
	_, err := EnsureRuntime(req)
	if err == nil {
		t.Fatal("expected ErrPlatformNotBundled, got nil")
	}
	if !errors.Is(err, ErrPlatformNotBundled) {
		t.Errorf("err = %v, want ErrPlatformNotBundled", err)
	}
}

func TestEnsureRuntime_RequiredFields(t *testing.T) {
	bundle, sum := makeSyntheticBundle(t)
	cases := []struct {
		name string
		req  EnsureRuntimeRequest
	}{
		{"no pluginID", EnsureRuntimeRequest{EmbeddedBundle: bundle, EmbeddedSHA256: sum, PluginVersion: "1", DataDir: "/tmp/x"}},
		{"no pluginVersion", EnsureRuntimeRequest{EmbeddedBundle: bundle, EmbeddedSHA256: sum, PluginID: "p", DataDir: "/tmp/x"}},
		{"no dataDir", EnsureRuntimeRequest{EmbeddedBundle: bundle, EmbeddedSHA256: sum, PluginID: "p", PluginVersion: "1"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := EnsureRuntime(tc.req); err == nil {
				t.Errorf("expected required-field error, got nil")
			}
		})
	}
}

func TestEnsureRuntime_PathEscape(t *testing.T) {
	// Build a bundle whose tar header tries to escape with "../evil"
	dataDir := t.TempDir()
	var tarBuf bytes.Buffer
	tw := tar.NewWriter(&tarBuf)
	body := "pwned"
	hdr := &tar.Header{Name: "../evil", Mode: 0o644, Size: int64(len(body)), Typeflag: tar.TypeReg}
	if err := tw.WriteHeader(hdr); err != nil {
		t.Fatalf("tar header: %v", err)
	}
	if _, err := tw.Write([]byte(body)); err != nil {
		t.Fatalf("tar body: %v", err)
	}
	tw.Close()

	var zBuf bytes.Buffer
	zw, _ := zstd.NewWriter(&zBuf)
	zw.Write(tarBuf.Bytes())
	zw.Close()
	evilBundle := zBuf.Bytes()
	h := sha256.Sum256(evilBundle)

	req := EnsureRuntimeRequest{
		EmbeddedBundle: evilBundle,
		EmbeddedSHA256: hex.EncodeToString(h[:]),
		PluginID:       "testplug", PluginVersion: "1.0.0", DataDir: dataDir,
	}
	if _, err := EnsureRuntime(req); err == nil {
		t.Fatal("expected path-escape rejection, got nil")
	}
	// Ensure the malicious file was NOT written outside the runtime dir.
	if _, err := os.Stat(filepath.Join(dataDir, "evil")); err == nil {
		t.Error("path-escape succeeded: evil file created outside extract dir")
	}
}

func TestDataDir_EnvOverride(t *testing.T) {
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", "/explicit/path")
	got := DataDir("anything")
	if got != "/explicit/path" {
		t.Errorf("DataDir = %q, want /explicit/path", got)
	}
}

func TestDataDir_FallbackContainsPluginID(t *testing.T) {
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", "")
	got := DataDir("myplugin")
	if got == "" {
		t.Fatal("DataDir returned empty")
	}
	// The fallback path should mention the plugin id.
	if !filepath.IsAbs(got) {
		t.Errorf("DataDir = %q, expected absolute path", got)
	}
	// Last path element should be the plugin id.
	if filepath.Base(got) != "myplugin" {
		t.Errorf("DataDir base = %q, want myplugin", filepath.Base(got))
	}
}

func TestRuntimePython(t *testing.T) {
	// goruntime constant tells us which path shape to expect.
	p := RuntimePython("/some/root")
	// On Unix it's <root>/bin/python3; on Windows <root>/python.exe.
	if p == "" {
		t.Fatal("RuntimePython returned empty")
	}
	if filepath.Dir(p) == "/some/root" || filepath.Dir(p) == "/some/root/bin" {
		// OK on both Windows and Unix
	} else {
		t.Errorf("unexpected RuntimePython path: %q", p)
	}
}

func TestIsExtractedRuntimePath(t *testing.T) {
	tmp := t.TempDir()
	// Build a fake extracted layout: <tmp>/bin/python3 first WITHOUT manifest.
	if err := os.MkdirAll(filepath.Join(tmp, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	pyPath := filepath.Join(tmp, "bin", "python3")
	if err := os.WriteFile(pyPath, []byte("fake"), 0o755); err != nil {
		t.Fatal(err)
	}
	// No manifest yet → not detected as extracted runtime.
	if IsExtractedRuntimePath(pyPath) {
		t.Error("IsExtractedRuntimePath = true with no manifest.sha256, want false")
	}
	// Now add manifest.sha256 — should be detected.
	if err := os.WriteFile(filepath.Join(tmp, "manifest.sha256"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !IsExtractedRuntimePath(pyPath) {
		t.Error("IsExtractedRuntimePath = false with manifest present, want true")
	}
	if got := RuntimeRoot(pyPath); got != tmp {
		t.Errorf("RuntimeRoot = %q, want %q", got, tmp)
	}
}
