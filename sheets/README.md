# Sheets

Staging extraction of Minerva's spreadsheet editor. This plugin is not in the
marketplace or required-plugin list. The builtin remains active until the
separate cutover batch.

The source install uses Go to build `sheets-plugin`. Release archives carry the
backend and scene assets. The backend owns editor creation; editing tools run
on the live panel. Native files remain `.minsheet` version 1.

Creation with initial content is a two-step operation. A failure after opening
the tab leaves that tab visible and identifies it in the error.

Linked notes are snapshots that reopen the sheet; they do not stay synchronized
in either direction. Nudge export reports `nudge_unavailable`. Undo history
across plugin live reload is deferred.
