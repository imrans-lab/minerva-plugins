// Package schemas embeds the Council JSON Schemas so that the backend, the
// wrapper and the tests all validate against one copy of them. The .json files
// beside this one are the schemas themselves and are also shipped as plugin
// assets; nothing may hold a second, hand-maintained transcription of them.
package schemas

import "embed"

//go:embed *.json
var FS embed.FS

// Names of the schema documents, in dependency order. Every $ref resolves
// within this set.
const (
	Common            = "common.schema.json"
	CouncilDefinition = "council_definition.schema.json"
	Session           = "session.schema.json"
	ProjectSnapshot   = "project_snapshot.schema.json"
	Envelope          = "envelope.schema.json"
)
