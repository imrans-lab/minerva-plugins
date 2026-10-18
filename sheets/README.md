# Sheets

Staging extraction of Minerva's spreadsheet editor. This plugin is not in the
marketplace or required-plugin list. The builtin remains active until the
separate cutover batch.

The source install uses Go to build `sheets-plugin`. Release archives carry the
backend and scene assets. An explicit source install opens `.minsheet`, CSV,
TSV and XLSX documents through the public panel SDK. Native saves and project
snapshots retain the spreadsheet model; project packages include source files.
Panel MCP tools now edit data, styling, charts, filters and undo history. Editor
creation uses the host's public editor services. Snapshot notes reopen a copy of
the sheet; Nudge export reports `nudge_unavailable`. Valid MCP chart image capture retains the
builtin missing-canvas defect (`minerva:01a14e24b4c6`), targeted for the plugin in B4.
Raw canvas PNG capture is tested separately; MCP image export is not claimed. Imported-path Save retains the frozen builtin
hazard until B4; do not overwrite an imported source file during staging.

Run `scripts/check-private-imports.py HOST --self-test` for the shipped-resource
census. In an isolated container, `scripts/run-model-oracle.py HOST NEW_DIRECTORY`
builds a project with only the exact public panel SDK and checks frozen B0
spreadsheet models. The full-host source-install fixture separately covers host
services and project persistence, including fresh-profile package transfer.

The plugin creates initial content in two steps. A failure after opening
the tab leaves that tab visible and identifies it in the error.

Linked notes are snapshots that reopen the sheet, without synchronization
with the original tab in either direction. Undo history
across plugin live reload is deferred.
