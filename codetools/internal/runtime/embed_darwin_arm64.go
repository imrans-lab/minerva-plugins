//go:build darwin && arm64

package runtime

import _ "embed"

//go:embed bundle/runtime-bundle-macos-arm64.tar.zst
var EmbeddedBundle []byte

//go:embed bundle/runtime-bundle-macos-arm64.sha256
var embeddedBundleSHA256Raw string
