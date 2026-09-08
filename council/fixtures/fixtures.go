// Package fixtures embeds the Council example records. They are test material
// first, but they double as the worked examples the architecture document
// points at, so they live in the plugin tree rather than under testdata.
package fixtures

import "embed"

//go:embed *.json invalid/*.json
var FS embed.FS
