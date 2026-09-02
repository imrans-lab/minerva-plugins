extends RefCounted
## THE PANEL'S SESSION STATE for one board — the facts that describe how THIS
## editor is looking at the board rather than what the board IS.
##
## WHY IT IS NOT IN THE BOARD. The canonical dict (PCBData.to_board_dict) is the
## design of record: it is what the worker routes, what DRC judges, what promote
## writes and what a fab reads. A drawing-grid pitch and a "don't let me drag
## this part" flag are none of those things — they change nothing about the
## copper, and a board file that carried them would assert one editor's habits
## at every other machine that ever opens it.
##
## WHERE IT LIVES, and how it is keyed to the board. It rides the SAME payload
## the panel already returns from _on_panel_save_request, under one reserved key
## (SESSION_KEY) beside the board's own keys — the host stores that payload as
## the tab's `__panel_state` in the .minproj AND writes it as the tab's
## .pcbskel document, so the state comes back on a project reopen and on a plain
## file reopen alike. The keying is the host's: that payload belongs to ONE tab
## showing ONE board file. Inside the block, each entry names the entity it
## describes (a component ref), so a lock for a part the board no longer has is
## simply not applied.
##
## The block is stripped BEFORE PCBData.from_board_dict sees the document —
## that loader refuses any root key the design schema does not have, which is
## exactly the guarantee that keeps this state out of the design.
##
## Off-tree note: lives OUTSIDE Minerva's res:// tree, so NO class_name —
## preloaded by relative path, the convention every pcb/ui/*.gd file follows.

## Reserved key the block rides under. Double-underscored so it cannot collide
## with a board field: the design schema has no such name and never will.
const SESSION_KEY := "__panel_session"

## Block schema. An unknown version is IGNORED rather than guessed at — losing a
## grid pitch is nothing; misreading one into the wrong field is a defect.
const VERSION := 1


## Capture the panel's session state for `data` (a PCBData).
static func capture(data) -> Dictionary:
	var locked_refs: Array = []
	var refs: Array = data.components.keys()
	refs.sort()  # deterministic: an unchanged board must save byte-identically
	for ref in refs:
		if data.components[ref].locked:
			locked_refs.append(str(ref))
	return {
		"version": VERSION,
		"grid_mm": data.grid_size,
		"locked_components": locked_refs,
	}


## Apply a previously captured block to `data`. Silent and total: every value is
## re-validated (the block is read back from a file a human can edit), and an
## entry naming a component this board does not have is skipped.
##
## Writes the fields DIRECTLY rather than through PCBData's journalled setters
## — a restore is not a user edit, so it must not land in the change journal or
## the undo history.
static func apply(data, session: Dictionary) -> void:
	if int(session.get("version", 0)) != VERSION:
		return

	# Same rule PCBData.set_grid_size enforces: a non-positive or non-finite
	# pitch would leave the authoring snap unusable, so it is refused, not
	# clamped. Absent ⇒ whatever the document load already established stands.
	var pitch := float(session.get("grid_mm", 0.0))
	if is_finite(pitch) and pitch > 0.0:
		data.grid_size = pitch

	# Locks are stated in FULL: the block lists every locked part, so a part
	# absent from it is unlocked. Anything else would make an unlock unsavable.
	var locked_refs: Array = session.get("locked_components", []) \
		if session.get("locked_components") is Array else []
	for ref in data.components:
		data.components[ref].locked = false
	for ref in locked_refs:
		var comp = data.components.get(str(ref))
		if comp != null:
			comp.locked = true


## The session block carried by `document`, or {} when it carries none.
static func extract(document: Dictionary) -> Dictionary:
	var block: Variant = document.get(SESSION_KEY)
	return block if block is Dictionary else {}

