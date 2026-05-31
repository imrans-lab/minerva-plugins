//go:build linux && amd64

package runtime

import _ "embed"

// EmbeddedBundle is the platform-specific tar.zst produced by
// scripts/build-python-runtime-bundle.sh and consumed by EnsureRuntime.
// One declaration per supported (GOOS, GOARCH) pair; build tags ensure
// exactly one is compiled per binary.
//
//go:embed bundle/runtime-bundle-linux-x86_64.tar.zst
var EmbeddedBundle []byte

//go:embed bundle/runtime-bundle-linux-x86_64.sha256
var embeddedBundleSHA256Raw string
