// Package cadruntime holds the CAD plugin's embedded Python runtime bundle.
//
// The plugin-agnostic extraction / path-resolution machinery lives in
// github.com/imrans-lab/minerva-plugins/shared/runtime. This package supplies only the
// CAD-specific go:embed'd bundle bytes (one embed_<triple>.go per supported
// platform) and their checksum, which main.go feeds into
// sharedruntime.PythonPath.
package cadruntime

import "strings"

// EmbeddedSHA256 is the trimmed hex sha256 of EmbeddedBundle. Computed once
// at package init from the platform-specific embed_<triple>.go's raw string
// (which carries a trailing newline from shasum / sha256sum output).
var EmbeddedSHA256 = strings.TrimSpace(embeddedBundleSHA256Raw)
