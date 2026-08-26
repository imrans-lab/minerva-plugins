extends RefCounted
## Board-level undo/redo: the ONE seam every surface steps the board's history
## through — the panel's Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y, the Minerva host's
## ribbon Undo/Redo hooks, and the minerva_pcb_undo / minerva_pcb_redo verbs.
##
## PCBData owns the history (save_to_history / undo / redo / can_undo /
## can_redo); this module adds what a surface needs on top of a bare bool: the
## LABEL of the step that moved, the depth left in each direction, and the one
## status sentence, so three callers cannot drift on how a step is named.
##
## Off-tree plugin: reached by preload, typed by base class.

## The key gesture `event` asks for: "undo" (Ctrl+Z), "redo" (Ctrl+Shift+Z or
## Ctrl+Y), or "" for any other key. Cmd stands in for Ctrl on macOS.
static func key_action(event: InputEventKey) -> String:
	if not event.pressed or event.is_echo():
		return ""
	if not (event.ctrl_pressed or event.meta_pressed):
		return ""
	if event.keycode == KEY_Z:
		return "redo" if event.shift_pressed else "undo"
	if event.keycode == KEY_Y and not event.shift_pressed:
		return "redo"
	return ""


## Revert the most recent history step. Returns {ok, action, undo_depth,
## redo_depth} — `action` is the label the step was recorded under, the depths
## are what is left AFTER the move — or {ok:false, error} when there is nothing
## to undo. `data` is the PCBData model.
static func undo(data) -> Dictionary:
	if data == null or not data.can_undo():
		return _refusal("nothing_to_undo", "Nothing to undo.")
	# The snapshot at history_index is the state AFTER the step being reverted,
	# so its label names that step.
	var label: String = _label_at(data, data.history_index)
	if not data.undo():
		return _refusal("nothing_to_undo", "Nothing to undo.")
	return _applied("undo", label, data)


## Re-apply the most recently undone step. Same reply shape as undo().
static func redo(data) -> Dictionary:
	if data == null or not data.can_redo():
		return _refusal("nothing_to_redo", "Nothing to redo.")
	if not data.redo():
		return _refusal("nothing_to_redo", "Nothing to redo.")
	# After the move history_index sits ON the re-applied step's snapshot.
	return _applied("redo", _label_at(data, data.history_index), data)


## The depths without moving: {undo_depth, redo_depth, can_undo, can_redo}.
static func depths(data) -> Dictionary:
	if data == null:
		return {"undo_depth": 0, "redo_depth": 0, "can_undo": false, "can_redo": false}
	var undo_depth: int = maxi(0, int(data.history_index))
	var redo_depth: int = maxi(0, data.history.size() - 1 - int(data.history_index))
	return {"undo_depth": undo_depth, "redo_depth": redo_depth,
		"can_undo": undo_depth > 0, "can_redo": redo_depth > 0}


## The status-line sentence for an applied step: what moved, and how much
## history is left in that direction.
static func status_line(result: Dictionary) -> String:
	if not bool(result.get("ok", false)):
		return str(result.get("message", result.get("error", "")))
	var kind: String = str(result.get("kind", "undo"))
	var verb: String = "Undid" if kind == "undo" else "Redid"
	var left: int = int(result.get("undo_depth" if kind == "undo" else "redo_depth", 0))
	var noun: String = "undo" if kind == "undo" else "redo"
	return "%s \"%s\" — %d more to %s." % [verb, str(result.get("action", "")), left, noun]


static func _label_at(data, index: int) -> String:
	if index < 0 or index >= data.history.size():
		return ""
	return str((data.history[index] as Dictionary).get("action", ""))


static func _applied(kind: String, label: String, data) -> Dictionary:
	var out: Dictionary = depths(data)
	out["ok"] = true
	out["kind"] = kind
	out["action"] = label
	return out


static func _refusal(code: String, message: String) -> Dictionary:
	return {"ok": false, "error": code, "message": message}
