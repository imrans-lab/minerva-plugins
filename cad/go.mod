module github.com/ipeerbhai/plugins/cad

go 1.25

require github.com/imrans-lab/minerva-plugins/shared v0.0.0

require github.com/klauspost/compress v1.20.0 // indirect

// Workspace dev pattern: the shared module is consumed from the sibling
// directory in this monorepo rather than a published version.
replace github.com/imrans-lab/minerva-plugins/shared => ../shared
