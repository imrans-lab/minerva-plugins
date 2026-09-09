// Package fixtures embeds the Council example records. They are test material
// first, but they double as the worked examples the architecture document
// points at, so they live in the plugin tree rather than under testdata.
package fixtures

import "embed"

// The .mcouncil entry is the populated example document: the same record kind
// as the .json snapshots, carrying the extension the panel opens, so the live
// check can point a person at a file Minerva will actually open and the
// contract tests still hold it to the schemas.
//
//go:embed *.json invalid/*.json *.mcouncil
var FS embed.FS
