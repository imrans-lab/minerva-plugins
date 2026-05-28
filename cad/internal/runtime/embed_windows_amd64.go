//go:build windows && amd64

package runtime

import _ "embed"

//go:embed bundle/runtime-bundle-windows-x86_64.tar.zst
var EmbeddedBundle []byte

//go:embed bundle/runtime-bundle-windows-x86_64.sha256
var embeddedBundleSHA256Raw string
