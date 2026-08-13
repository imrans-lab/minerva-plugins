// Package pcbruntime holds the pcb plugin's embedded Python runtime bundle.
//
// The plugin-agnostic extraction / path-resolution machinery lives in
// github.com/imrans-lab/minerva-plugins/shared/runtime. This package supplies
// only the pcb-specific go:embed'd bundle bytes (one embed_<triple>.go per
// supported platform) and their checksum, which main.go feeds into
// sharedruntime.PythonPath.
//
// UNLIKE cad/internal/cadruntime, the bundle/ dir carries COMMITTED
// zero-byte placeholder files: an empty EmbeddedBundle makes
// sharedruntime.PythonPath return ErrPlatformNotBundled and fall through to
// the dev tiers (worker/.venv, then python3 on PATH), so a fresh checkout
// compiles and tests without ever running the bundle script. The CI package
// job overwrites the placeholders with real bundles before go build; the
// >100MB binary-size assertion is what stops a release built from
// placeholders.
package pcbruntime

import "strings"

// EmbeddedSHA256 is the trimmed hex sha256 of EmbeddedBundle. Computed once
// at package init from the platform-specific embed_<triple>.go's raw string
// (which carries a trailing newline from shasum / sha256sum output). Empty
// when this platform's bundle is a placeholder.
var EmbeddedSHA256 = strings.TrimSpace(embeddedBundleSHA256Raw)
