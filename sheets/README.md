# Sheets

Staging extraction of Minerva's spreadsheet editor. This plugin is not in the
marketplace or required-plugin list. The builtin remains active until the
separate cutover batch.

The source install uses Go to build `sheets-plugin`. Release archives carry the
backend and scene assets. An explicit source install opens `.minsheet`, CSV,
TSV and XLSX documents through the public panel SDK. Native saves and project
snapshots retain the spreadsheet model; project packages include source files.
Creation and panel MCP tools still refuse with `sheets_staging` until their
separate implementation slices. Imported-path Save retains the frozen builtin
hazard until B4; do not overwrite an imported source file during staging.

Run `scripts/check-private-imports.py HOST --self-test` for the shipped-resource
census. In an isolated container, `scripts/run-model-oracle.py HOST NEW_DIRECTORY`
builds a project with only the exact public panel SDK and checks frozen B0
spreadsheet models. The full-host source-install fixture separately covers host
services and project persistence, including fresh-profile package transfer.

The completed plugin will create initial content in two steps. A failure after opening
the tab leaves that tab visible and identifies it in the error.

Linked notes will be snapshots that reopen the sheet, without synchronization
in either direction. Nudge export will report `nudge_unavailable`. Undo history
across plugin live reload is deferred.
