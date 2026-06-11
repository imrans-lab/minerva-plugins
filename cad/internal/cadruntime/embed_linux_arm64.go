//go:build linux && arm64

package cadruntime

import _ "embed"

//go:embed bundle/runtime-bundle-linux-arm64.tar.zst
var EmbeddedBundle []byte

//go:embed bundle/runtime-bundle-linux-arm64.sha256
var embeddedBundleSHA256Raw string
