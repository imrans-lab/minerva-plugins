extends VBoxContainer
## The sidebar section for a PAD selection.
##
## The Pin Info section above it answers "what is this ONE pin". This one
## answers the three questions asked with pads selected:
##
##   which pins are these?   one pad ROW per selected pad — net, side, roles —
##                           the same rows minerva_pcb_get_selection hands a
##                           caller, so the human and the caller are reading the
##                           same sentence.
##   what is free?           the component's pins on no net, filterable by side
##                           ("free pins on the west column of U1S"), each
##                           carrying the roles that make it a bad idea
##                           (strapping, uart_console, …).
##   move it                 "Move net to…" a pin of the same component, and
##                           "Swap nets" between exactly two selected pads.
##                           Each is ONE undo step; the section never touches
##                           the model itself — it emits the request and
##                           PCBPanel runs the same pcb_net_membership op the
##                           MCP verbs run.
##
## Built in code rather than as a .tscn on purpose: every section of this
## sidebar is code-built, the panel has no sub-scene precedent to follow, and
## its GD suites mount PCBPanel.gd standalone (a plugin-directory .tscn is not
## reachable through res:// from there).
##
## Off-tree script — NO class_name, reached by relative preload.

const _PcbPadRow := preload("model/pcb_pad_row.gd")

## The human picked a destination for the selected pad's net.
signal move_net_requested(from_ref: String, to_ref: String)
## The human asked to exchange the nets of the two selected pads.
signal swap_nets_requested(ref_a: String, ref_b: String)

const _SIDE_CHOICES: Array[String] = ["", "north", "east", "south", "west"]

var _pads_label: Label = null
var _free_label: Label = null
var _side_filter: OptionButton = null
var _move_target: OptionButton = null
var _move_button: Button = null
var _swap_button: Button = null

## The live selection this section is describing, and the board it reads.
var _refs: Array = []
var _data = null


func _init() -> void:
	name = "PinSelectionSection"
	visible = false

	var header := Label.new()
	header.name = "PinSelectionHeader"
	header.text = "Pin Selection"
	header.add_theme_font_size_override("font_size", 11)
	add_child(header)

	_pads_label = Label.new()
	_pads_label.name = "PinSelectionPads"
	_pads_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	add_child(_pads_label)

	_side_filter = OptionButton.new()
	_side_filter.name = "PinSelectionSideFilter"
	for side in _SIDE_CHOICES:
		_side_filter.add_item("free pins: any side" if side.is_empty() else "free pins: %s" % side)
	_side_filter.select(0)
	_side_filter.item_selected.connect(func(_i: int) -> void: _refresh())
	add_child(_side_filter)

	_free_label = Label.new()
	_free_label.name = "PinSelectionFreePins"
	_free_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	add_child(_free_label)

	_move_target = OptionButton.new()
	_move_target.name = "PinSelectionMoveTarget"
	add_child(_move_target)

	_move_button = Button.new()
	_move_button.name = "PinSelectionMoveButton"
	_move_button.text = "Move net to…"
	_move_button.tooltip_text = "Move this pin's net onto the chosen pin of the same component (one undo step)"
	_move_button.pressed.connect(_on_move_pressed)
	add_child(_move_button)

	_swap_button = Button.new()
	_swap_button.name = "PinSelectionSwapButton"
	_swap_button.text = "Swap nets"
	_swap_button.tooltip_text = "Exchange the nets of the two selected pins (one undo step)"
	_swap_button.pressed.connect(_on_swap_pressed)
	add_child(_swap_button)


## Re-describe the section against the live board and the canvas's pad
## selection. An empty selection hides the whole section — a pad selection is
## the only thing it has anything to say about.
func update_for(data, refs: Array) -> void:
	_data = data
	_refs = refs.duplicate()
	_refresh()


func _refresh() -> void:
	if _refs.is_empty() or _data == null:
		visible = false
		return
	visible = true

	var rows: Array = _PcbPadRow.rows_for_refs(_data, _refs)
	var lines := PackedStringArray()
	for raw in rows:
		var pad: Dictionary = raw
		var net := str(pad.get("net", ""))
		var roles: Array = pad.get("roles", [])
		lines.append("%s — %s — %s side%s" % [
			str(pad.get("ref", "")),
			net if not net.is_empty() else "(no net)",
			str(pad.get("side", "?")),
			"" if roles.is_empty() else " — " + ", ".join(PackedStringArray(roles)),
		])
	_pads_label.text = "\n".join(lines)

	_refresh_free_pins(rows)
	_refresh_actions(rows)


## "free pins on <REF>" for the component the selection belongs to, under the
## side filter. A selection spanning two components has no single component to
## answer for, and says so rather than picking one.
func _refresh_free_pins(rows: Array) -> void:
	var comp_id := _single_component(rows)
	if comp_id.is_empty():
		_free_label.text = "Free pins: select pads on ONE component to list them."
		_side_filter.disabled = true
		return
	_side_filter.disabled = false
	var comp = _data.get_component(comp_id)
	var side: String = _SIDE_CHOICES[clampi(_side_filter.selected, 0, _SIDE_CHOICES.size() - 1)]
	var free: Array = _PcbPadRow.free_pins(_data, comp, side)
	if free.is_empty():
		_free_label.text = "Free pins on %s%s: (none)" % [
			comp_id, "" if side.is_empty() else " (%s)" % side]
		return
	var names := PackedStringArray()
	for raw in free:
		var pad: Dictionary = raw
		var roles: Array = pad.get("roles", [])
		names.append(str(pad.get("pin", "")) if roles.is_empty() \
			else "%s (%s)" % [str(pad.get("pin", "")), ", ".join(PackedStringArray(roles))])
	_free_label.text = "Free pins on %s%s: %s" % [
		comp_id, "" if side.is_empty() else " (%s)" % side, ", ".join(names)]


## Move needs exactly one selected pad and a destination on its own component;
## Swap needs exactly two. Both buttons say why they are off by being off — the
## selection IS the argument, so there is nothing else to explain.
func _refresh_actions(rows: Array) -> void:
	var comp_id := _single_component(rows)
	_move_target.clear()
	var can_move := rows.size() == 1 and not comp_id.is_empty()
	if can_move:
		var source := str((rows[0] as Dictionary).get("pin", ""))
		for raw in _PcbPadRow.rows_for_component(_data, _data.get_component(comp_id)):
			var pad: Dictionary = raw
			var pin := str(pad.get("pin", ""))
			if pin == source:
				continue
			var net := str(pad.get("net", ""))
			_move_target.add_item("%s — %s" % [pin, net if not net.is_empty() else "free"])
			_move_target.set_item_metadata(_move_target.item_count - 1, str(pad.get("ref", "")))
	# Pre-select the first destination: a button that does nothing until the
	# human has opened the dropdown once reads as broken, not as unset.
	if _move_target.item_count > 0:
		_move_target.select(0)
	_move_target.disabled = not can_move or _move_target.item_count == 0
	_move_button.disabled = _move_target.disabled
	_swap_button.disabled = rows.size() != 2


## The component every selected pad belongs to, or "" when they disagree.
func _single_component(rows: Array) -> String:
	var comp_id := ""
	for raw in rows:
		var here := str((raw as Dictionary).get("component", ""))
		if comp_id.is_empty():
			comp_id = here
		elif here != comp_id:
			return ""
	return comp_id


func _on_move_pressed() -> void:
	if _refs.size() != 1 or _move_target.selected < 0:
		return
	var target := str(_move_target.get_item_metadata(_move_target.selected))
	if not target.is_empty():
		move_net_requested.emit(str(_refs[0]), target)


func _on_swap_pressed() -> void:
	if _refs.size() != 2:
		return
	swap_nets_requested.emit(str(_refs[0]), str(_refs[1]))
