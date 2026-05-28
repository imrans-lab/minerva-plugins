//go:build darwin && arm64

package runtime

import _ "embed"

// EmbeddedBundle is the platform-specific tar.zst produced by
// scripts/build-python-runtime-bundle.sh and consumed by EnsureRuntime.
// One declaration per supported (GOOS, GOARCH) pair; build tags ensure
// only one is compiled per binary.
//
//go:embed bundle/runtime-bundle-macos-arm64.tar.zst
var EmbeddedBundle []byte

// embeddedBundleSHA256Raw is the hex sha256 of EmbeddedBundle, as written by
// the bundle builder. Trimmed in TrimmedEmbeddedSHA256() to strip the
// trailing newline that shasum/sha256sum emit.
//
//go:embed bundle/runtime-bundle-macos-arm64.sha256
var embeddedBundleSHA256Raw string
