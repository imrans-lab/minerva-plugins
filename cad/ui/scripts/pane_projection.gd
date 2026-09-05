extends RefCounted
## Which way a pane looks at the part.
##
## One preset list and one selection behaviour, shared by the narrow layout's
## single pane and by every pane of the wide layout, so the two layouts cannot
## drift apart: the dropdown in a wide pane IS the narrow dropdown, pointed at
## that pane's camera.
##
## A SLOT is a place on screen ("iso", "top", "front", "right"); a PRESET is a
## direction to look from ("Top", "Bottom", …). The MCP verbs address slots, so
## a slot id never changes when the owner points it somewhere else — the pane
## reports its current preset instead.
##
## Choices live here for the life of the panel: the store is per slot, so
## switching to narrow layout and back leaves each pane where it was put.

## Preset per option, in dropdown order. The item id IS the index.
const OPTIONS: Array = [
	{"label": "Perspective", "preset": "Perspective"},
	{"label": "Top",         "preset": "Top"},
	{"label": "Bottom",      "preset": "Bottom"},
	{"label": "Front",       "preset": "Front"},
	{"label": "Back",        "preset": "Back"},
	{"label": "Left",        "preset": "Left"},
	{"label": "Right",       "preset": "Right"},
]

## Wide-layout slots and the direction each starts out looking from.
const WIDE_DEFAULTS: Dictionary = {
	"top": "Top",
	"front": "Front",
	"right": "Right",
	"iso": "Perspective",
}

## Where each wide pane's dropdown sits, relative to the panel.
const WIDE_PANE_PATHS: Dictionary = {
	"top": "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/TopView",
	"front": "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/FrontView",
	"right": "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/RightView",
	"iso": "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/IsoView",
}

var _panel: Node = null
var _preset_for: Dictionary = {}   # slot -> preset string
var _dropdowns: Dictionary = {}    # slot -> OptionButton


func _init(panel: Node) -> void:
	_panel = panel
	for slot in WIDE_DEFAULTS.keys():
		_preset_for[slot] = String(WIDE_DEFAULTS[slot])


## Fill a dropdown with the presets. Used for the wide panes and the narrow
## layout's own dropdown, so both offer exactly the same seven choices.
static func fill(dropdown: OptionButton) -> void:
	if dropdown == null:
		return
	dropdown.clear()
	for index in range(OPTIONS.size()):
		dropdown.add_item(String(OPTIONS[index]["label"]), index)


## The preset an option index selects; "Perspective" for anything out of range.
static func preset_at(index: int) -> String:
	if index < 0 or index >= OPTIONS.size():
		return "Perspective"
	return String(OPTIONS[index]["preset"])


## The option index showing `preset`, or 0 (Perspective).
static func index_of(preset: String) -> int:
	for index in range(OPTIONS.size()):
		if String(OPTIONS[index]["preset"]) == preset:
			return index
	return 0


## Find each wide pane's dropdown, fill it, show that pane's current preset and
## subscribe. Called once the panel's cameras are configured.
func attach_wide_panes() -> void:
	for slot in WIDE_PANE_PATHS.keys():
		var dropdown := _panel.get_node_or_null(
			String(WIDE_PANE_PATHS[slot]) + "/ProjectionRow/ProjectionDropdown") as OptionButton
		if dropdown == null:
			continue
		fill(dropdown)
		dropdown.select(index_of(String(_preset_for.get(slot, "Perspective"))))
		dropdown.item_selected.connect(_on_selected.bind(String(slot)))
		_dropdowns[slot] = dropdown


## The preset a slot is currently showing.
func preset_for(slot: String) -> String:
	return String(_preset_for.get(slot, "Perspective"))


## Every slot's current preset, for the introspection verbs.
func presets() -> Dictionary:
	return _preset_for.duplicate()


## Point a slot's camera at a preset and remember it. Also drives the dropdown,
## so an MCP-side or restored change shows in the pane's own control.
func apply(slot: String, preset: String) -> void:
	if not WIDE_DEFAULTS.has(slot):
		return
	_preset_for[slot] = preset
	var dropdown := _dropdowns.get(slot, null) as OptionButton
	if dropdown != null and dropdown.selected != index_of(preset):
		dropdown.select(index_of(preset))
	var camera: Camera3D = _panel.get_view_camera(slot)
	if camera != null and camera.has_method("set_view_preset"):
		camera.call("set_view_preset", preset)
	# A pane showing a direction is a drawing, not a model: the shaded mesh is
	# hidden there and the edge overlay is the whole picture.
	_panel._apply_mesh_visibility()


func _on_selected(index: int, slot: String) -> void:
	apply(slot, preset_at(index))
