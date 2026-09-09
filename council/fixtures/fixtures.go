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
// migrations/ holds documents in shapes this build no longer writes. They are
// not valid against today's schemas — that is the point of them — so they live
// in their own directory rather than beside the examples the round-trip test
// sweeps.
//
//go:embed *.json invalid/*.json migrations/*.json *.mcouncil
var FS embed.FS
