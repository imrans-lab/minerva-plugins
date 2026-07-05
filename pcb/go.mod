module github.com/imrans-lab/minerva-plugins/pcb

go 1.22

require (
	github.com/imrans-lab/minerva-plugins/shared v0.0.0
	gopkg.in/yaml.v3 v3.0.1
)

require github.com/klauspost/compress v1.17.11 // indirect

// Workspace dev pattern: the shared module is consumed from the sibling
// directory in this monorepo rather than a published version.
replace github.com/imrans-lab/minerva-plugins/shared => ../shared
