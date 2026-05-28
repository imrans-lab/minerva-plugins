// Package runtime resolves the path of the Python interpreter and worker
// entrypoint for the CAD worker subprocess.
//
// Priority order (production → dev fallback):
//
//  1. Extracted embedded PBS runtime under <data_dir>/runtime/<plugin_version>/
//     (the path resolved by EnsureRuntime / EmbeddedBundle). This is the path
//     marketplace-installed plugins use.
//
//  2. <workerDir>/.venv/bin/python (POSIX) or <workerDir>\.venv\Scripts\python.exe
//     (Windows). Convenience for developers who keep a venv in the cad/worker/
//     dir for `python -m mcad_worker` iteration.
//
//  3. `python3` on $PATH. Last-resort dev fallback.
//
// See Docs/design/Go-python-bridge-design.md §6 for the design contract.
package runtime

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"strings"
)

// EmbeddedSHA256 is the trimmed hex sha256 of EmbeddedBundle. Computed once
// at package init from the platform-specific embed_<triple>.go's raw string
// (which carries a trailing newline from shasum / sha256sum output).
var EmbeddedSHA256 = strings.TrimSpace(embeddedBundleSHA256Raw)

// PythonPath returns the absolute path to the python interpreter to use for
// spawning the worker subprocess. See package comment for priority order.
//
// pluginID + pluginVersion locate the per-plugin extracted runtime under the
// data directory (e.g. <data>/plugins/<pluginID>/runtime/<pluginVersion>/).
// workerDir is the cad/worker source tree used for the dev-mode venv fallback.
//
// The first successful tier wins. Returns a wrapped error only if all three
// tiers fail. ErrPlatformNotBundled from the embedded-tier is suppressed in
// favor of trying the venv / PATH fallbacks — callers in production binaries
// should never reach those fallbacks (a real bundle is always embedded), but
// developers running un-bundled builds rely on them.
func PythonPath(workerDir, pluginID, pluginVersion string) (string, error) {
	// Tier 1: extracted embedded runtime.
	req := EnsureRuntimeRequest{
		EmbeddedBundle: EmbeddedBundle,
		EmbeddedSHA256: EmbeddedSHA256,
		PluginID:       pluginID,
		PluginVersion:  pluginVersion,
		DataDir:        DataDir(pluginID),
	}
	if root, err := EnsureRuntime(req); err == nil {
		return RuntimePython(root), nil
	}
	// (Embedded tier failure intentionally falls through to dev fallbacks.
	// main.go's host.notify path surfaces a toast on the failure path.)

	// Tier 2: dev venv next to the worker source.
	if workerDir != "" {
		if p := venvPython(workerDir); p != "" {
			return p, nil
		}
	}

	// Tier 3: system python3 on PATH.
	p, err := exec.LookPath("python3")
	if err != nil {
		return "", fmt.Errorf(
			"no embedded runtime extracted, no .venv at %s, and python3 not on PATH: %w "+
				"(production builds embed PBS — see Docs/design/Go-python-bridge-design.md §6)",
			workerDir, err)
	}
	return p, nil
}

// RuntimePython returns the absolute path to the python interpreter inside
// an extracted runtime root. Handles OS-specific layout (PBS Unix vs Windows).
func RuntimePython(runtimeRoot string) string {
	if goruntime.GOOS == "windows" {
		return filepath.Join(runtimeRoot, "python.exe")
	}
	return filepath.Join(runtimeRoot, "bin", "python3")
}

// venvPython returns the path to a venv-managed Python interpreter under
// <workerDir>/.venv if it exists and is executable, otherwise "".
func venvPython(workerDir string) string {
	var candidate string
	if goruntime.GOOS == "windows" {
		candidate = filepath.Join(workerDir, ".venv", "Scripts", "python.exe")
	} else {
		candidate = filepath.Join(workerDir, ".venv", "bin", "python")
	}
	info, err := os.Stat(candidate)
	if err != nil || info.IsDir() {
		return ""
	}
	return candidate
}

// WorkerScriptDir returns the directory containing the python worker
// entrypoint module for dev-mode (the venv path expects mcad_worker to be
// discoverable here). In production (extracted-runtime path), the worker
// source lives inside the bundle's site-packages and is found via PYTHONHOME
// — bridge.Worker.Start adjusts cmd.Dir accordingly in that case (see W1c).
func WorkerScriptDir(pluginRoot string) string {
	return filepath.Join(pluginRoot, "worker")
}

// IsExtractedRuntimePath reports whether p points at an interpreter inside
// an extracted runtime tree (heuristic: the parent of bin/ has
// manifest.sha256). bridge.Worker.Start uses this to decide whether to apply
// the production env-strip / PYTHONHOME wiring versus the dev-mode passthrough.
func IsExtractedRuntimePath(p string) bool {
	if p == "" {
		return false
	}
	// p like <root>/bin/python3 (Unix) or <root>/python.exe (Windows).
	dir := filepath.Dir(p)
	if filepath.Base(dir) == "bin" {
		dir = filepath.Dir(dir)
	}
	manifestPath := filepath.Join(dir, "manifest.sha256")
	if info, err := os.Stat(manifestPath); err == nil && !info.IsDir() {
		return true
	}
	return false
}

// RuntimeRoot returns the runtime tree root for an interpreter path produced
// by RuntimePython() / PythonPath() in production mode. Returns "" if p is
// not under an extracted runtime tree.
func RuntimeRoot(p string) string {
	if !IsExtractedRuntimePath(p) {
		return ""
	}
	dir := filepath.Dir(p)
	if filepath.Base(dir) == "bin" {
		return filepath.Dir(dir)
	}
	return dir
}
