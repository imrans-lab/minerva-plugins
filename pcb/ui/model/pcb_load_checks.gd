extends RefCounted
## WHAT THE LOAD-TIME CHECKS COULD NOT DETERMINE, in words for a human.
##
## Off-tree module — NO class_name, reached by relative preload. Every function
## is STATIC and pure: the load reply in, one line out.
##
## THE PROBLEM. Opening a board runs checks (assembly advisory, board_drc,
## completeness) whose honest third answer is INDETERMINATE — "this could not be
## measured", which is neither a pass nor a finding. That verdict reaches an
## agent in the MCP reply and reached nobody else. For an owner who works from
## the GUI, a check that is honest only in JSON is indistinguishable from a
## check that passed, so an unmeasured board looks like a clean one. Fail-open,
## by omission.
##
## GENERAL, NOT PER-CHECK. The scan below is driven by the SHAPE of an
## indeterminate verdict, not by a list of check names: any object in the reply
## carrying `status` or `verdict` == "indeterminate", and any non-empty
## `indeterminate` list, is reported under the key path it was found at. A check
## added later is surfaced the day it starts answering, with no edit here — the
## alternative is a per-check allow-list that silently omits whatever nobody
## remembered to add.
##
## THE VERDICT IS NEVER RESTATED, only located. The reply's own words for WHY
## are carried when it supplies them (`error`, `reason`), so the line cannot
## drift from what the check actually said.

## Keys whose string value is a check verdict.
const _VERDICT_KEYS: Array = ["status", "verdict"]

## The one verdict this module exists to surface.
const INDETERMINATE := "indeterminate"

## How deep the scan walks. The load reply nests at most a few levels
## (result -> board_health -> assembly), and a bound keeps a cyclic or
## pathological payload from walking forever.
const _MAX_DEPTH := 6


## Every indeterminate a load reply carries, as one sentence each, in the order
## they were found. Empty when every check answered.
static func indeterminate_notes(load_result: Dictionary) -> PackedStringArray:
	var notes := PackedStringArray()
	_scan(load_result, "", 0, notes)
	return notes


## The held status-bar lead for a load reply, or "" when nothing was
## indeterminate. It LEADS the line because the status label ellipsizes on
## overflow — the tooltip carries the rest.
static func status_lead(load_result: Dictionary) -> String:
	var notes := indeterminate_notes(load_result)
	if notes.is_empty():
		return ""
	return "CHECK INDETERMINATE: %s  •  " % "  •  ".join(notes)


static func _scan(node: Variant, path: String, depth: int,
		notes: PackedStringArray) -> void:
	if depth > _MAX_DEPTH:
		return
	if node is Array:
		for i in (node as Array).size():
			_scan((node as Array)[i], "%s[%d]" % [path, i], depth + 1, notes)
		return
	if not (node is Dictionary):
		return
	var dict: Dictionary = node
	for key in _VERDICT_KEYS:
		if str(dict.get(key, "")) == INDETERMINATE:
			notes.append(_note(_name_for(path), dict))
			break
	# A populated `indeterminate` list is the OTHER shape the same fact takes:
	# the check as a whole answered, but named entities it could not judge.
	var undetermined: Variant = dict.get(INDETERMINATE)
	if undetermined is Array and not (undetermined as Array).is_empty():
		notes.append("%s could not judge %d item(s)" % [
			_name_for(path), (undetermined as Array).size()])
	for key in dict:
		var child: Variant = dict[key]
		if child is Dictionary or child is Array:
			var child_path := str(key) if path.is_empty() else "%s.%s" % [path, str(key)]
			_scan(child, child_path, depth + 1, notes)


## The check's own words for why, when it supplied any.
static func _note(name: String, verdict: Dictionary) -> String:
	for key in ["error", "reason", "message"]:
		var why := str(verdict.get(key, ""))
		if not why.is_empty():
			return "%s — %s" % [name, why]
	return "%s could not be determined" % name


## The last path segment reads as the check's name ("board_health.assembly" ->
## "assembly"); an unnamed root is the load itself.
static func _name_for(path: String) -> String:
	if path.is_empty():
		return "load check"
	var parts := path.split(".")
	return parts[parts.size() - 1]
