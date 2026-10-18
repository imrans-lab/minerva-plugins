# Sheets

Staging extraction of Minerva's spreadsheet editor. This plugin is not in the
marketplace or required-plugin list. The builtin remains active until the
separate cutover batch.

The source install uses Go to build `sheets-plugin`. Release archives carry the
backend and scene assets. The creation backend and empty panel are stubs in this
first slice and refuse spreadsheet operations with `sheets_staging`. The panel
claims no file formats and cannot save files. Persistence and imports arrive
with the spreadsheet domain.

The completed plugin will create initial content in two steps. A failure after opening
the tab leaves that tab visible and identifies it in the error.

Linked notes will be snapshots that reopen the sheet, without synchronization
in either direction. Nudge export will report `nudge_unavailable`. Undo history
across plugin live reload is deferred.
