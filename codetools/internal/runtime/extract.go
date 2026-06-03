// Package runtime — extract.go: 3-tier embedded runtime lookup + atomic extract.
//
// Plugin-agnostic by design. When a second python-embedded plugin needs the
// same scaffolding, mechanical-move this file to pkg/pyembed/ and update
// import paths in cad/. Do not add plugin-specific behavior here; parameterize
// via EnsureRuntimeRequest instead.
//
// See Docs/design/Go-python-bridge-design.md §6 for the design contract.
package runtime

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/klauspost/compress/zstd"
)

// ErrPlatformNotBundled is returned by EnsureRuntime when EmbeddedBundle is
// empty (e.g., running on a platform whose go:embed target was missing).
// Defensive: with the matrix-build scope (post-amendment 2026-05-27) this
// should never fire in production builds — all 5 supported targets ship a
// real bundle. Returned in dev/test contexts where the bundle file isn't
// staged.
var ErrPlatformNotBundled = errors.New("embedded python runtime not bundled for this platform")

// EnsureRuntimeRequest carries everything EnsureRuntime needs. All fields
// are required.
type EnsureRuntimeRequest struct {
	// EmbeddedBundle is the go:embed'd tar.zst bytes (from embed_<triple>.go).
	EmbeddedBundle []byte
	// EmbeddedSHA256 is the hex-encoded sha256 of EmbeddedBundle, used for
	// post-extract tamper detection. Compared against sha256(EmbeddedBundle).
	EmbeddedSHA256 string
	// PluginID, e.g. "cad". Used in path construction; never affects logic.
	PluginID string
	// PluginVersion, e.g. "0.1.1". Cache key — version bumps trigger
	// re-extract into a new dir, preserving previous version for rollback
	// (GC of old versions is out of scope for v1; see design §6).
	PluginVersion string
	// DataDir is the absolute plugin data directory, e.g. the value returned
	// by DataDir(PluginID). The runtime is extracted to
	// <DataDir>/runtime/<PluginVersion>/.
	DataDir string
}

// EnsureRuntime implements design §6's 3-tier lookup:
//
//  1. Cache hit — <DataDir>/runtime/<PluginVersion>/ exists with a valid
//     manifest.sha256 inside it.
//  2. (Future: prebundled fallback under res:// — not in v1.)
//  3. Extract embedded tarball.
//
// Returns the absolute runtime root path on success. The python interpreter
// inside is at RuntimePython(<runtimeRoot>).
//
// Errors:
//   - ErrPlatformNotBundled if EmbeddedBundle is empty (no embed for this OS/arch).
//   - Wrapped error for sha mismatch, IO failure, or corrupt tarball.
//
// Safe to call concurrently — uses temp-dir-then-rename for atomicity.
// A racing second caller may end up doing redundant work (extract into its
// own tmp dir, then find target already populated), but the result is correct.
func EnsureRuntime(req EnsureRuntimeRequest) (string, error) {
	if req.PluginID == "" || req.PluginVersion == "" || req.DataDir == "" {
		return "", fmt.Errorf("EnsureRuntime: PluginID, PluginVersion, DataDir all required")
	}

	target := filepath.Join(req.DataDir, "runtime", req.PluginVersion)

	// Tier 1: cache hit? Require BOTH a self-consistent manifest AND that the
	// extraction came from the CURRENT embedded bundle. The version-keyed path
	// alone is not enough: a rebuilt same-version bundle (e.g. a worker .py
	// change with no version bump) must invalidate a stale extraction.
	if ok, _ := manifestValid(target); ok && sourceBundleMatches(target, req.EmbeddedSHA256) {
		return target, nil
	}

	// Tier 3: extract embedded.
	if len(req.EmbeddedBundle) == 0 {
		return "", ErrPlatformNotBundled
	}

	// Verify embed integrity (caller-supplied checksum must match the bytes).
	if req.EmbeddedSHA256 != "" {
		sum := sha256.Sum256(req.EmbeddedBundle)
		got := hex.EncodeToString(sum[:])
		want := strings.TrimSpace(req.EmbeddedSHA256)
		if !strings.EqualFold(got, want) {
			return "", fmt.Errorf("EnsureRuntime: embedded bundle sha mismatch (got %s, want %s)", got, want)
		}
	}

	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return "", fmt.Errorf("EnsureRuntime: mkdir %s: %w", filepath.Dir(target), err)
	}

	// Extract to a tmp sibling, then rename atomically.
	tmp, err := os.MkdirTemp(filepath.Dir(target), fmt.Sprintf(".tmp-extract-%d-", os.Getpid()))
	if err != nil {
		return "", fmt.Errorf("EnsureRuntime: mktemp: %w", err)
	}
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.RemoveAll(tmp)
		}
	}()

	if err := extractTarZst(req.EmbeddedBundle, tmp); err != nil {
		return "", fmt.Errorf("EnsureRuntime: extract: %w", err)
	}

	// Post-extract: verify manifest.sha256 covers what we wrote.
	if ok, err := manifestValid(tmp); err != nil {
		return "", fmt.Errorf("EnsureRuntime: post-extract verify: %w", err)
	} else if !ok {
		return "", fmt.Errorf("EnsureRuntime: manifest.sha256 missing or empty post-extract")
	}

	// Stamp the source bundle sha so a later EnsureRuntime can tell a
	// same-version-but-rebuilt bundle apart from this extraction and re-extract.
	if req.EmbeddedSHA256 != "" {
		stamp := filepath.Join(tmp, sourceBundleStampName)
		if err := os.WriteFile(stamp, []byte(strings.TrimSpace(req.EmbeddedSHA256)+"\n"), 0o644); err != nil {
			return "", fmt.Errorf("EnsureRuntime: write source-bundle stamp: %w", err)
		}
	}

	// If target already exists (stale partial or race winner), clear it so
	// the rename succeeds. Design §6 mentions keeping prior version for
	// rollback — out of scope for v1 (cache hit at top of function covers
	// the common case of "user re-runs after upgrade and now wants old").
	if _, statErr := os.Stat(target); statErr == nil {
		if err := os.RemoveAll(target); err != nil {
			return "", fmt.Errorf("EnsureRuntime: remove stale %s: %w", target, err)
		}
	}

	if err := os.Rename(tmp, target); err != nil {
		return "", fmt.Errorf("EnsureRuntime: rename %s -> %s: %w", tmp, target, err)
	}
	cleanup = false
	return target, nil
}

// sourceBundleStampName records, inside an extracted runtime, the sha256 of the
// bundle it came from. EnsureRuntime Tier-1 reads it to detect a stale cache.
const sourceBundleStampName = "source-bundle.sha256"

// sourceBundleMatches reports whether the runtime at dir was extracted from a
// bundle whose sha matches want. An empty want (integrity check disabled) keeps
// the legacy version-only behavior; a missing stamp (extracted by an older
// build) is a miss so we re-extract rather than serve a stale same-version cache.
func sourceBundleMatches(dir, want string) bool {
	if want == "" {
		return true
	}
	b, err := os.ReadFile(filepath.Join(dir, sourceBundleStampName))
	if err != nil {
		return false
	}
	return strings.EqualFold(strings.TrimSpace(string(b)), strings.TrimSpace(want))
}

// extractTarZst decompresses zstd-encoded tarball bytes and extracts every
// entry under outDir. Refuses path-escape attempts.
func extractTarZst(data []byte, outDir string) error {
	zr, err := zstd.NewReader(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("zstd reader: %w", err)
	}
	defer zr.Close()
	tr := tar.NewReader(zr)

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("tar header: %w", err)
		}

		// Validate path: no .. escapes, no absolute paths.
		cleanName := filepath.Clean(hdr.Name)
		if strings.HasPrefix(cleanName, "..") || filepath.IsAbs(cleanName) {
			return fmt.Errorf("tar entry escapes outDir: %s", hdr.Name)
		}
		dst := filepath.Join(outDir, cleanName)

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(dst, os.FileMode(hdr.Mode)&0o777); err != nil {
				return fmt.Errorf("mkdir %s: %w", dst, err)
			}
		case tar.TypeReg, tar.TypeRegA:
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return fmt.Errorf("mkdir parent of %s: %w", dst, err)
			}
			f, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(hdr.Mode)&0o777)
			if err != nil {
				return fmt.Errorf("create %s: %w", dst, err)
			}
			if _, err := io.Copy(f, tr); err != nil {
				_ = f.Close()
				return fmt.Errorf("write %s: %w", dst, err)
			}
			if err := f.Close(); err != nil {
				return fmt.Errorf("close %s: %w", dst, err)
			}
		case tar.TypeSymlink:
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return fmt.Errorf("mkdir parent of symlink %s: %w", dst, err)
			}
			// Some bundles ship symlinks (PBS .dylib aliases on macOS, etc.).
			// We trust the bundle build to keep targets inside the runtime tree.
			if err := os.Symlink(hdr.Linkname, dst); err != nil {
				return fmt.Errorf("symlink %s -> %s: %w", dst, hdr.Linkname, err)
			}
		case tar.TypeXGlobalHeader, tar.TypeXHeader:
			// pax extended headers — informational, skipped.
		default:
			// Block devices, FIFOs, etc. — shouldn't appear in a python
			// runtime bundle; skip silently.
		}
	}
}

// manifestValid reads <dir>/manifest.sha256 and verifies every listed file's
// content sha against the recorded value. Returns:
//   - (true, nil) if all checksums match.
//   - (false, nil) if manifest.sha256 doesn't exist (treated as cache miss).
//   - (false, err) on any IO or mismatch failure (treated as corruption).
//
// Manifest format (one entry per line):
//
//	<sha256-hex>  <relative-path>
//
// Two spaces between hash and path (the format produced by `shasum -a 256`
// and `sha256sum`).
func manifestValid(dir string) (bool, error) {
	manifestPath := filepath.Join(dir, "manifest.sha256")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("read manifest: %w", err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Format: "<sha256-hex>  <relative-path>"
		parts := strings.SplitN(line, "  ", 2)
		if len(parts) != 2 {
			return false, fmt.Errorf("malformed manifest line: %q", line)
		}
		wantSum := strings.TrimSpace(parts[0])
		relPath := strings.TrimSpace(parts[1])
		if relPath == "" {
			continue
		}
		rel := filepath.Clean(strings.TrimPrefix(relPath, "./"))
		absPath := filepath.Join(dir, rel)
		f, err := os.Open(absPath)
		if err != nil {
			return false, fmt.Errorf("manifest file %s: %w", rel, err)
		}
		h := sha256.New()
		if _, err := io.Copy(h, f); err != nil {
			_ = f.Close()
			return false, fmt.Errorf("hash %s: %w", rel, err)
		}
		_ = f.Close()
		gotSum := hex.EncodeToString(h.Sum(nil))
		if !strings.EqualFold(gotSum, wantSum) {
			return false, fmt.Errorf("sha mismatch for %s: got %s want %s", rel, gotSum, wantSum)
		}
	}
	return true, nil
}
