extends RefCounted
## Scene controls and one per-user preference. Layout rules receive measured
## dimensions; the panel retains ownership of viewport/capture transitions.

const _Policy: Script = preload("layout_policy.gd")
const _BuildControls: Script = preload("build_controls.gd")
const PREFERENCE_PATH: String = "user://cad-layout.cfg"
const GRID_PATH: String = "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"

var _owner: WeakRef
var _preference: String = "auto"
var _preference_error: String = ""
var _sidebar_width: float = 0.0
var _pending: bool = false
var _decision: Dictionary = {}


func _init(panel: Control) -> void:
	_owner = weakref(panel)


func wire() -> void:
	var panel: Control = _owner.get_ref()
	var config := ConfigFile.new()
	var error: Error = config.load(PREFERENCE_PATH)
	if error == OK:
		_preference = _Policy.preference(str(config.get_value("layout", "mode", "auto")))
	elif error != ERR_FILE_NOT_FOUND:
		_preference_error = "CAD layout preference could not be read: %s" % error_string(error)
		push_warning(_preference_error)
	for path: String in _BuildControls.ROWS:
		var button: OptionButton = panel.get_node(path + "/LayoutChoice")
		button.item_selected.connect(_on_selected)
	panel._responsive.resized.connect(queue_refresh)
	panel._wide_sidebar.resized.connect(queue_refresh)
	panel._wide_sidebar.minimum_size_changed.connect(queue_refresh)
	panel._wide_layout.minimum_size_changed.connect(queue_refresh)
	panel._wide_layout.dragged.connect(_on_split_dragged)
	panel._wide_layout.sort_children.connect(_on_split_sorted)
	var content: Control = panel.get_node(GRID_PATH).get_parent()
	content.resized.connect(queue_refresh)
	_sync_buttons(panel)
	queue_refresh()


func _on_selected(index: int) -> void:
	if index < 0 or index >= _Policy.MODES.size():
		return
	_preference = _Policy.MODES[index]
	var config := ConfigFile.new()
	config.set_value("layout", "mode", _preference)
	var error: Error = config.save(PREFERENCE_PATH)
	_preference_error = "" if error == OK else \
		"CAD layout preference could not be saved: %s" % error_string(error)
	if not _preference_error.is_empty():
		push_warning(_preference_error)
	var panel: Control = _owner.get_ref()
	_sync_buttons(panel)
	queue_refresh()


func _sync_buttons(panel: Control) -> void:
	for path: String in _BuildControls.ROWS:
		var button: OptionButton = panel.get_node(path + "/LayoutChoice")
		button.select(_Policy.MODES.find(_preference))
		button.tooltip_text = "CAD layout: Auto follows the available pane size; " \
			+ "Single view or Four views stays selected through resizes." \
			+ ("\n" + _preference_error if not _preference_error.is_empty() else "")


func _on_split_dragged(_offset: int) -> void:
	queue_refresh()


## Sample allocations only after the split has fitted both children. A parent
## resize may notify us before that deferred sort, while their sizes disagree.
func _on_split_sorted() -> void:
	var panel: Control = _owner.get_ref()
	if panel == null or not is_instance_valid(panel):
		return
	var split: SplitContainer = panel._wide_layout
	var content: Control = panel.get_node(GRID_PATH).get_parent()
	var sidebar: Control = panel._wide_sidebar
	if split.visible and content.size.x > 0.0:
		_sidebar_width = maxf(sidebar.get_combined_minimum_size().x,
			split.size.x - content.size.x - _split_gap(split, content, sidebar))
	queue_refresh()


## The split owns its themed grabber gap, including collapsed/touch modes.
func _split_gap(split: SplitContainer, content: Control, sidebar: Control) -> float:
	return maxf(0.0, split.get_minimum_size().x
		- content.get_combined_minimum_size().x - sidebar.get_combined_minimum_size().x)


func queue_refresh() -> void:
	if _pending:
		return
	_pending = true
	call_deferred("_refresh")


func _refresh() -> void:
	_pending = false
	var panel: Control = _owner.get_ref()
	if panel == null or not is_instance_valid(panel):
		return
	var sidebar: Control = panel._wide_sidebar
	var split: SplitContainer = panel._wide_layout
	var grid: GridContainer = panel.get_node(GRID_PATH)
	var gaps := Vector2(grid.get_theme_constant("h_separation"),
		grid.get_theme_constant("v_separation"))
	var content: Control = grid.get_parent()
	var split_gap: float = _split_gap(split, content, sidebar)
	# Retain the last coherent allocation while wide is hidden or awaiting a
	# sort. Never combine a newly resized split with its old content bounds.
	_sidebar_width = maxf(_sidebar_width, sidebar.get_combined_minimum_size().x)
	var was_single: bool = bool(_decision.get("is_single", false))
	_decision = _Policy.choose(_preference, panel._responsive.size,
		_sidebar_width, split_gap, gaps, was_single)
	panel._apply_layout(bool(_decision["is_single"]))


func state() -> Dictionary:
	var out: Dictionary = _decision.duplicate(true)
	var panel: Control = _owner.get_ref()
	if panel == null or not is_instance_valid(panel):
		return out
	out["panel_px"] = [panel.size.x, panel.size.y]
	var grid: Control = panel.get_node(GRID_PATH)
	out["grid_px"] = [grid.size.x, grid.size.y]
	var pane: Control = panel._single_view_container
	if not panel._narrow_layout.visible:
		var panes: Dictionary = {"top": panel._top_view_container,
			"front": panel._front_view_container, "right": panel._right_view_container,
			"iso": panel._iso_view_container}
		pane = panes.get(panel._active_viewport_id, panel._iso_view_container)
	out["active_pane_px"] = [pane.size.x, pane.size.y]
	out["preference_error"] = _preference_error
	return out
