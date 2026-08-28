extends MenuButton
## The PCB panel's OPTIONS menu — the control strip's second menu, sibling of
## View, and the one surface for the rules a board is drawn under.
##
## ── WHAT IS IN HERE, AND WHOSE IT IS ─────────────────────────────────────────
## Two kinds of setting sit in this menu, and the split is the whole design:
##
##   BOARD state, which travels with the YAML and which the worker enforces:
##     the allowed trace directions (`design_rules.allowed_trace_angles_deg`),
##     the default trace width, via diameter and drill, the clearance, and the
##     drawing-grid pitch (`grid_mm`). Editing one is a journalled, undoable
##     board change — the SAME model mutator the MCP verb calls.
##
##   Per-USER preferences, which are habits and belong to the person drawing:
##     the three snap toggles (grid / land / angle). They persist in the plugin
##     preference store and are the same values the preference verbs read.
##
## The angle set is board state and not a view flag because a rule the tool
## snapped to but the board did not carry would be advice, not a rule: the
## worker's gc12 check reads the same key and flags every trace that breaks it,
## agent-routed ones included.
##
## ── ONE PATH FOR THE MENU AND THE VERB ───────────────────────────────────────
## `read_state` and `apply` are static and take the model, not the panel. The
## menu below calls them and so does `panel_tools._board_rules`, so a human's
## click and `minerva_pcb_board_rules` are the same operation by construction
## rather than by two implementations that agree today.
##
## Off-tree plugin: NO class_name; reached by relative preload.

const PcbTraceAngles := preload("model/pcb_trace_angles.gd")
const PcbPrefs := preload("model/pcb_prefs.gd")
const PcbTrace := preload("model/pcb_trace.gd")

## Menu id families. Each range is closed and disjoint so `_on_id_pressed` can
## dispatch by range without an ordering trap. The base is above the View menu's
## own families (which reach 1000+ for the fab-preview picker) so a stray id can
## never be routed by the wrong menu.
const MENU_ID_BASE := 2000
const _ID_MODE_BASE := MENU_ID_BASE + 1      # + index into OFFERED_MODES
const _ID_MODE_CUSTOM := MENU_ID_BASE + 9    # the read-only "board declares…" row
const _ID_RULE_BASE := MENU_ID_BASE + 20     # + index into _RULE_ROWS
const _ID_SNAP_BASE := MENU_ID_BASE + 40     # + index into _SNAP_ROWS

## The numeric board rules this menu edits, in menu order:
## [label, key, min_mm, max_mm]. `key` is a DESIGN_RULE_KEYS entry, or
## `grid_mm`, which is board state but not a design rule (see PCBData).
const _RULE_ROWS := [
	["Trace width", "trace_width_mm", PcbTrace.MIN_WIDTH_MM, PcbTrace.MAX_WIDTH_MM],
	["Via diameter", "via_diameter_mm", 0.05, 5.0],
	["Via drill", "via_drill_mm", 0.05, 5.0],
	["Clearance", "clearance_mm", 0.02, 5.0],
	["Grid pitch", "grid_mm", 0.05, 5.08],
]

## The per-user snap toggles, in menu order: [label, preference key].
const _SNAP_ROWS := [
	["Snap to grid", PcbPrefs.KEY_SNAP_GRID],
	["Snap to pads and trace ends", PcbPrefs.KEY_SNAP_LAND],
	["Snap to allowed angles", PcbPrefs.KEY_SNAP_ANGLE],
]

## The rule key that is not a design rule. Kept as a constant because three
## places have to agree on the spelling.
const GRID_KEY := "grid_mm"

## A sentence for the panel's transient status line — a refusal, or the
## confirmation of a change. The menu never writes the status bar itself.
signal status_message(text: String)

## The panel this menu reads and writes through. Duck-typed (`get_data`,
## `get_preferences`), so a headless fixture can bind a stub.
var _panel = null

## The one numeric editor, built on first use and reused by every rule row.
## A PopupMenu cannot host a SpinBox, and four standing spin boxes in the
## sidebar would be furniture for settings that are changed once a board.
var _value_dialog: AcceptDialog = null
var _value_spin: SpinBox = null
## The `_RULE_ROWS` entry the dialog is currently editing.
var _value_row: Array = []


func _init() -> void:
	name = "OptionsMenuButton"
	text = "Options"
	tooltip_text = "Trace angles, board design rules and snapping"


func _ready() -> void:
	var popup := get_popup()
	if not popup.about_to_popup.is_connected(_rebuild):
		popup.about_to_popup.connect(_rebuild)
	if not popup.id_pressed.is_connected(_on_id_pressed):
		popup.id_pressed.connect(_on_id_pressed)


## Bind the panel whose board and preferences this menu edits.
func bind(panel) -> void:
	_panel = panel


# ── The shared state surface: ONE read and ONE write, menu and verb alike ─────

## The whole Options block, as data.
##
## `design_rules` reports 0.0 for a rule the board does not declare — the same
## "0.0 means the board says nothing" reading `design_rule_trace_width` already
## uses, so a caller can tell an authored 0.25 from a fallback. `effective`
## carries what the tools will actually use, which for a silent board is the
## resolved fallback, so a reader never has to re-derive one.
static func read_state(data, prefs) -> Dictionary:
	var angles: Array[float] = []
	var rules: Dictionary = {}
	var grid := 0.0
	for row in _RULE_ROWS:
		if str(row[1]) != GRID_KEY:
			rules[str(row[1])] = 0.0
	if data != null and is_instance_valid(data):
		angles = data.design_rule_trace_angles()
		for key in rules:
			rules[key] = float((data.design_rules as Dictionary).get(key, 0.0))
		grid = float(data.grid_size)
	rules[GRID_KEY] = grid
	var snaps: Dictionary = {}
	for row in _SNAP_ROWS:
		snaps[str(row[1])] = _snap_enabled(prefs, str(row[1]))
	return {
		"trace_angle_mode": PcbTraceAngles.mode_for_angles(angles),
		"allowed_trace_angles_deg": angles,
		"offered_modes": PcbTraceAngles.OFFERED_MODES.duplicate(),
		"design_rules": rules,
		"snaps": snaps,
	}


## Apply any subset of the Options block. Returns
## `{ok, error, changed:[names], state:{…}}`.
##
## VALIDATED WHOLE, THEN APPLIED WHOLE, the discipline `view_state` established:
## a bad angle set or an out-of-range width changes nothing at all and names
## what was wrong, rather than leaving half a write on the board. The board
## half of a real change is exactly ONE undo step whatever its size, so a menu
## edit and an agent edit both undo in one keystroke.
static func apply(data, prefs, changes: Dictionary) -> Dictionary:
	var board_writes: Array = []      # [[kind, key, value]]
	var pref_writes: Array = []       # [[key, bool]]

	# ── validate ────────────────────────────────────────────────────────────
	if changes.has("trace_angle_mode") or changes.has("allowed_trace_angles_deg"):
		if changes.has("trace_angle_mode") and changes.has("allowed_trace_angles_deg"):
			return _refuse("Pass trace_angle_mode OR allowed_trace_angles_deg, not both — "
				+ "a mode IS an angle set, and two spellings of the same rule could disagree.")
		var wanted: Array
		if changes.has("trace_angle_mode"):
			var mode := str(changes["trace_angle_mode"])
			if not mode in PcbTraceAngles.OFFERED_MODES:
				return _refuse("Unknown trace_angle_mode \"%s\". Known modes: %s." % [
					mode, ", ".join(PcbTraceAngles.OFFERED_MODES)])
			wanted = PcbTraceAngles.angles_for_mode(mode)
		else:
			var checked: Dictionary = PcbTraceAngles.validate(changes["allowed_trace_angles_deg"])
			if not bool(checked.get("ok", false)):
				return _refuse(str(checked["error"]))
			wanted = checked["angles"]
		board_writes.append(["angles", "allowed_trace_angles_deg", wanted])

	for row in _RULE_ROWS:
		var key := str(row[1])
		if not changes.has(key):
			continue
		var raw: Variant = changes[key]
		if raw is bool or not (raw is float or raw is int):
			return _refuse("%s must be a number of millimetres." % key)
		var value := float(raw)
		var refusal := _rule_range_error(row, value)
		if not refusal.is_empty():
			return _refuse(refusal)
		board_writes.append(["grid" if key == GRID_KEY else "rule", key, value])

	for row in _SNAP_ROWS:
		var key := str(row[1])
		if not changes.has(key):
			continue
		if not (changes[key] is bool):
			return _refuse("%s is true/false." % key)
		pref_writes.append([key, bool(changes[key])])

	if not board_writes.is_empty() and (data == null or not is_instance_valid(data)):
		return _refuse("No board is open, so its design rules cannot be set.")

	# ── apply ───────────────────────────────────────────────────────────────
	var changed: Array[String] = []
	var board_changed := false
	for write in board_writes:
		var kind := str(write[0])
		var key := str(write[1])
		var before: Variant = _board_value(data, kind, key)
		var refusal := ""
		match kind:
			"angles":
				refusal = data.set_design_rule_trace_angles(write[2])
			"grid":
				refusal = data.set_grid_size(float(write[2]))
			_:
				refusal = data.set_design_rule(key, float(write[2]))
		if not refusal.is_empty():
			# The validation pass above should have caught everything the model
			# refuses; a refusal here means the two disagree, and reporting it
			# verbatim is how that is found rather than hidden.
			return _refuse(refusal)
		if _board_value(data, kind, key) != before:
			changed.append(key)
			board_changed = true
	if board_changed:
		data.save_to_history("Set board rules")

	for write in pref_writes:
		var key := str(write[0])
		if prefs == null:
			return _refuse("The PCB preference store is not available.")
		var res: Dictionary = prefs.set_value(key, bool(write[1]))
		if not bool(res.get("ok", false)):
			return _refuse(str(res.get("error", "Preference not stored.")))
		if bool(res.get("changed", false)):
			changed.append(key)

	return {"ok": true, "error": "", "changed": changed,
		"state": read_state(data, prefs)}


## Is one snap toggle on? The reader every surface uses, so a missing store
## reads as "on" — the behaviour this editor has always had — rather than
## silently disabling a snap because a preference file could not be opened.
static func _snap_enabled(prefs, key: String) -> bool:
	if prefs == null:
		return true
	return prefs.get_bool(key, true)


static func _refuse(message: String) -> Dictionary:
	return {"ok": false, "error": message, "changed": [] as Array[String], "state": {}}


static func _rule_range_error(row: Array, value: float) -> String:
	if not is_finite(value) or value <= 0.0:
		return "%s must be a positive, finite number of millimetres." % str(row[1])
	if value < float(row[2]) or value > float(row[3]):
		return "%s must be within %.2f-%.2f mm; got %.4f." % [
			str(row[1]), float(row[2]), float(row[3]), value]
	return ""


static func _board_value(data, kind: String, key: String) -> Variant:
	match kind:
		"angles":
			return data.design_rule_trace_angles()
		"grid":
			return float(data.grid_size)
		_:
			return float((data.design_rules as Dictionary).get(key, 0.0))


# ── The menu itself ──────────────────────────────────────────────────────────

## Rebuilt from live state on every open, the same lazy-sync moment the View
## menu uses: the rows carry current VALUES in their labels, so a stale row
## would be a wrong number on screen rather than a missing checkmark.
func _rebuild() -> void:
	var popup := get_popup()
	popup.clear()
	var state := read_state(_data(), _prefs())

	popup.add_separator("Trace angles", MENU_ID_BASE)
	var mode := str(state["trace_angle_mode"])
	for i in PcbTraceAngles.OFFERED_MODES.size():
		var offered: String = PcbTraceAngles.OFFERED_MODES[i]
		popup.add_radio_check_item(str(PcbTraceAngles.MODE_LABELS[offered]), _ID_MODE_BASE + i)
		popup.set_item_checked(popup.get_item_index(_ID_MODE_BASE + i), mode == offered)
	if mode == PcbTraceAngles.MODE_CUSTOM:
		# The board declares a set this menu cannot express. Shown, disabled, and
		# named — a menu that silently reported the nearest offered mode would be
		# claiming a rule the board does not carry.
		popup.add_radio_check_item("Custom: %s°" % _angle_list(state["allowed_trace_angles_deg"]),
			_ID_MODE_CUSTOM)
		popup.set_item_checked(popup.get_item_index(_ID_MODE_CUSTOM), true)
		popup.set_item_disabled(popup.get_item_index(_ID_MODE_CUSTOM), true)

	popup.add_separator("Board design rules", MENU_ID_BASE + 10)
	var rules: Dictionary = state["design_rules"]
	for i in _RULE_ROWS.size():
		var row: Array = _RULE_ROWS[i]
		var value := float(rules.get(str(row[1]), 0.0))
		var shown := "%.2f mm" % value if value > 0.0 else "not declared"
		popup.add_item("%s… (%s)" % [str(row[0]), shown], _ID_RULE_BASE + i)
		popup.set_item_disabled(popup.get_item_index(_ID_RULE_BASE + i), _data() == null)

	popup.add_separator("Snapping", MENU_ID_BASE + 30)
	var snaps: Dictionary = state["snaps"]
	for i in _SNAP_ROWS.size():
		var row: Array = _SNAP_ROWS[i]
		popup.add_check_item(str(row[0]), _ID_SNAP_BASE + i)
		popup.set_item_checked(popup.get_item_index(_ID_SNAP_BASE + i),
			bool(snaps.get(str(row[1]), true)))


func _on_id_pressed(id: int) -> void:
	if id >= _ID_SNAP_BASE and id < _ID_SNAP_BASE + _SNAP_ROWS.size():
		var key := str(_SNAP_ROWS[id - _ID_SNAP_BASE][1])
		var now: bool = _snap_enabled(_prefs(), key)
		_run({key: not now})
		return
	if id >= _ID_RULE_BASE and id < _ID_RULE_BASE + _RULE_ROWS.size():
		_open_value_dialog(_RULE_ROWS[id - _ID_RULE_BASE])
		return
	if id >= _ID_MODE_BASE and id < _ID_MODE_BASE + PcbTraceAngles.OFFERED_MODES.size():
		_run({"trace_angle_mode": PcbTraceAngles.OFFERED_MODES[id - _ID_MODE_BASE]})
		return


## Run one change through the shared `apply` and report the outcome. The menu
## has no write path of its own — this is the only place it mutates anything.
func _run(changes: Dictionary) -> void:
	var result := apply(_data(), _prefs(), changes)
	if not bool(result.get("ok", false)):
		status_message.emit(str(result.get("error", "")))
		return
	var changed: Array = result.get("changed", [])
	if changed.is_empty():
		return
	status_message.emit(_confirmation(result))


## The sentence a successful change writes to the status line. Names the RULE
## rather than the click, because the same sentence is true when an agent made
## the change through the verb.
func _confirmation(result: Dictionary) -> String:
	var state: Dictionary = result.get("state", {})
	var changed: Array = result.get("changed", [])
	if changed.has("allowed_trace_angles_deg"):
		var mode := str(state.get("trace_angle_mode", ""))
		return "Trace angles: %s." % str(PcbTraceAngles.MODE_LABELS.get(mode, mode))
	var first := str(changed[0])
	for row in _SNAP_ROWS:
		if str(row[1]) == first:
			var on: bool = bool((state.get("snaps", {}) as Dictionary).get(first, true))
			return "%s: %s." % [str(row[0]), "on" if on else "off"]
	var rules: Dictionary = state.get("design_rules", {})
	return "%s set to %.2f mm." % [first, float(rules.get(first, 0.0))]


# ── The one numeric editor ───────────────────────────────────────────────────

func _open_value_dialog(row: Array) -> void:
	if _data() == null:
		return
	_value_row = row
	_ensure_value_dialog()
	_value_spin.min_value = float(row[2])
	_value_spin.max_value = float(row[3])
	var current := float((read_state(_data(), _prefs())["design_rules"] as Dictionary)
		.get(str(row[1]), 0.0))
	# set_value_no_signal for the reason every other spin box in this panel uses
	# it: assigning fires value_changed, and merely OPENING the editor would then
	# commit the box's step-rounded number back onto the board.
	_value_spin.set_value_no_signal(current if current > 0.0 else float(row[2]))
	_value_dialog.title = "%s (%s)" % [str(row[0]), str(row[1])]
	_value_dialog.popup_centered()


func _ensure_value_dialog() -> void:
	if _value_dialog != null and is_instance_valid(_value_dialog):
		return
	_value_dialog = AcceptDialog.new()
	_value_dialog.name = "OptionsValueDialog"
	_value_dialog.ok_button_text = "Set"
	_value_dialog.add_cancel_button("Cancel")
	_value_spin = SpinBox.new()
	_value_spin.name = "OptionsValueSpin"
	_value_spin.step = 0.01
	_value_spin.suffix = "mm"
	_value_spin.custom_minimum_size.x = 140
	_value_dialog.add_child(_value_spin)
	_value_dialog.confirmed.connect(_on_value_confirmed)
	add_child(_value_dialog)


func _on_value_confirmed() -> void:
	if _value_row.is_empty() or _value_spin == null:
		return
	_run({str(_value_row[1]): float(_value_spin.value)})


func _angle_list(angles) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for a in angles:
		parts.append("%g" % float(a))
	return ", ".join(parts)


func _data():
	if _panel == null or not is_instance_valid(_panel) or not _panel.has_method("get_data"):
		return null
	return _panel.get_data()


func _prefs():
	if _panel == null or not is_instance_valid(_panel) or not _panel.has_method("get_preferences"):
		return null
	return _panel.get_preferences()
