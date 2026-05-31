//go:build darwin && amd64

package runtime

import _ "embed"

//go:embed bundle/runtime-bundle-macos-amd64.tar.zst
var EmbeddedBundle []byte

//go:embed bundle/runtime-bundle-macos-amd64.sha256
var embeddedBundleSHA256Raw string
