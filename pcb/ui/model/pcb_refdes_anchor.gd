extends RefCounted
## WHERE a component prints its reference designator, as an editable anchor.
##
## The read/validate/measure half of `minerva_pcb_set_refdes`. Kept off
## panel_tools.gd (a god file that gets dispatch wiring only) because all three
## jobs here are real logic with their own rules:
##
##   * READ    — the component's effective anchor, complete, never a half dict.
##   * VALIDATE — VALIDATED WHOLE, THEN APPLIED WHOLE, the discipline
##     `minerva_pcb_view_state` and `minerva_pcb_board_rules` established: a
##     misspelled key or an out-of-range size changes NOTHING and is refused BY
##     NAME. Nothing here clamps. A clamp turns "you asked for something
##     impossible" into "you got something you did not ask for", and the caller
##     is an agent that will then report the value it sent.
##   * MEASURE — the BOARD-FRAME box of the designator strokes, which is the
##     only way a caller that just moved a label can see where it landed
##     without re-deriving the placement transform itself.
##
## The anchor is footprint-LOCAL millimetres in the component's own frame — the
## same `{x_mm, y_mm, rotation_deg, size_mm, hidden}` shape the worker's resolve
## puts on the wire (worker/pcb_worker/refdes_anchor.py) and the same one
## PcbComponent.refdes_anchor re-strokes the label from.
##
## Off-tree note: no class_name (this file lives outside Minerva's res:// tree);
## preloaded by relative path, like every other pcb/ui/model/*.gd.

## The five writable fields, and nothing else. An argument outside this set is
## a typo or a field from another verb, and either way silently ignoring it
## would leave the caller believing a write happened.
const ANCHOR_KEYS: Array[String] = [
	"x_mm", "y_mm", "rotation_deg", "size_mm", "hidden"]

## Cap height bounds, mm. The floor is below any fab's printable legend and the
## ceiling is far past any designator, so these refuse only nonsense (a zero, a
## negative, a metres-for-millimetres slip) rather than second-guessing taste.
const MIN_SIZE_MM := 0.2
const MAX_SIZE_MM := 10.0

## Anchor coordinates are footprint-LOCAL, so they are bounded by "somewhere on
## a plausible part", not by the board. A value past this is an author who meant
## board coordinates, and telling them so is more useful than drawing a label a
## metre away.
const MAX_OFFSET_MM := 500.0

const _PcbComponentScript := preload("pcb_component.gd")


## The component's effective anchor, always complete. An unmeasured component
## (nothing has resolved it) reads the same defaults its renderer draws at, so
## a caller never has to know which half was missing.
static func read_anchor(comp) -> Dictionary:
	var stored: Dictionary = comp.refdes_anchor
	return {
		"x_mm": float(stored.get("x_mm", 0.0)),
		"y_mm": float(stored.get("y_mm", _PcbComponentScript.REFDES_DEFAULT_Y_MM)),
		"rotation_deg": float(stored.get("rotation_deg", 0.0)),
		"size_mm": float(stored.get("size_mm", _PcbComponentScript.REFDES_DEFAULT_SIZE_MM)),
		"hidden": bool(stored.get("hidden", false)),
	}


## Validate a whole write against the current anchor.
##
## Returns `{"ok": true, "anchor": {...}, "placement": {...}, "changed": [...]}`
## or `{"ok": false, "error": "..."}`.
##
## The two dicts are deliberately different halves. `anchor` is the EFFECTIVE
## value — the current anchor with the write laid over it, every field present —
## and is what gets drawn. `placement` holds ONLY the fields this caller sent,
## which is what may be AUTHORED: storing the merged dict instead would freeze
## whatever the derivation happened to answer into the board the first time
## somebody hid a label. `changed` lists only the fields whose value actually
## moved, so a caller can tell "applied" from "already there".
##
## `args` is the raw tool argument dict; `skip` names the envelope keys that are
## not anchor fields (editor_name, component_id) so an unknown-key refusal can
## still be exact.
static func validate(comp, args: Dictionary, skip: Array[String]) -> Dictionary:
	var current: Dictionary = read_anchor(comp)
	var next: Dictionary = current.duplicate()
	var sent: Dictionary = {}
	var changed: Array[String] = []
	for raw_key in args:
		var key := str(raw_key)
		if skip.has(key):
			continue
		if not ANCHOR_KEYS.has(key):
			return _refuse("Unknown key \"%s\". Writable fields: %s." % [
				key, ", ".join(ANCHOR_KEYS)])
		var value: Variant = args[key]
		var checked: Dictionary = _check(key, value)
		if not bool(checked["ok"]):
			return checked
		next[key] = checked["value"]
		sent[key] = checked["value"]
	for key in ANCHOR_KEYS:
		if next[key] != current[key]:
			changed.append(key)
	return {"ok": true, "anchor": next, "placement": sent, "changed": changed}


static func _check(key: String, value: Variant) -> Dictionary:
	if key == "hidden":
		if not (value is bool):
			return _refuse("hidden must be true or false, got %s." % _shown(value))
		return {"ok": true, "value": value}
	if not _is_number(value):
		return _refuse("%s must be a number in millimetres, got %s." % [key, _shown(value)])
	var number := float(value)
	if not is_finite(number):
		return _refuse("%s must be finite, got %s." % [key, _shown(value)])
	if key == "size_mm":
		if number < MIN_SIZE_MM or number > MAX_SIZE_MM:
			return _refuse("size_mm must be between %s and %s mm (cap height), got %s. It is not clamped." % [
				MIN_SIZE_MM, MAX_SIZE_MM, number])
	elif key == "x_mm" or key == "y_mm":
		if absf(number) > MAX_OFFSET_MM:
			return _refuse("%s is a FOOTPRINT-LOCAL offset and must be within +/-%s mm, got %s. Board coordinates do not belong here." % [
				key, MAX_OFFSET_MM, number])
	return {"ok": true, "value": number}


## The BOARD-FRAME box of the designator INK: `{min_x_mm, min_y_mm, max_x_mm,
## max_y_mm, width_mm, height_mm}`, or an empty dict when the designator draws
## nothing (hidden, or an unnamed component).
##
## Measured off `refdes_graphics` — the strokes the canvas actually draws —
## through the component's ONE footprint-local -> board transform
## (PcbComponent.get_transform), so the box turns and mirrors with the part
## exactly as the ink does. Deriving it from the anchor and the font metrics
## instead would be a second placement implementation to keep in step.
##
## Those strokes are CENTRELINES, so the box is grown by half a stroke on every
## side: the caller asking "where did my label land" is asking about printed
## ink, and a centreline box understates it by 0.075 mm all round. Growing after
## the transform is exact because the transform only turns and mirrors — it
## never scales — so a half-width is the same distance in either frame.
static func board_bounds(comp) -> Dictionary:
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	var xform: Transform2D = comp.get_transform()
	var found := false
	for entry in comp.refdes_graphics:
		var stroke: Dictionary = entry
		for raw_point in (stroke.get("points", []) as Array):
			var board: Vector2 = comp.position + xform * (raw_point as Vector2)
			min_p = min_p.min(board)
			max_p = max_p.max(board)
			found = true
	if not found:
		return {}
	var half := 0.5 * _PcbComponentScript.REFDES_STROKE_WIDTH_MM
	min_p -= Vector2(half, half)
	max_p += Vector2(half, half)
	return {
		"min_x_mm": min_p.x, "min_y_mm": min_p.y,
		"max_x_mm": max_p.x, "max_y_mm": max_p.y,
		"width_mm": max_p.x - min_p.x, "height_mm": max_p.y - min_p.y,
	}


static func _is_number(value: Variant) -> bool:
	# JSON.parse hands every number back as a float, so int is here for a
	# GDScript caller rather than for the wire. bool is excluded deliberately:
	# `true` is not a millimetre.
	return (value is float or value is int) and not (value is bool)


static func _shown(value: Variant) -> String:
	return "%s (%s)" % [str(value), type_string(typeof(value))]


static func _refuse(message: String) -> Dictionary:
	return {"ok": false, "error": message}
