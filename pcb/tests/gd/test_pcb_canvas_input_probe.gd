extends SceneTree
## PCB canvas LIVE-input probe (docket 019f39164c2e).
##
## Run: godot --headless --path src --script test/test_pcb_canvas_input_probe.gd
##
## The headless panel-UI suite drives model/hooks and never exercises _gui_input,
## so it passes while the live panel is deaf to the mouse (findings 1/2/3:
## wheel-zoom, pan, box-select all dead). This probe mounts the REAL panel in a
## REAL Window viewport and pushes synthetic InputEventMouseButton / MouseMotion
## through Viewport.push_input — the same path the OS uses — then asserts the
## canvas actually zoomed / panned / began a box-select. It reproduces BOTH the
## bare panel AND the live condition (the platform AnnotationOverlay mounted as a
## sibling over the canvas by Editor._mount_annotation_dock_for_surface) so a
## regression in either seam is caught here instead of only in a human's hands.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const DRIVER_PATH := "res://test/helpers/plugin_panel_driver.gd"

var _pass := 0
var _fail := 0


class FakeEditor extends RefCounted:
	var tab_title: String = "Probe Tab"
	var associated_object: Variant = ""


func _board_with_part() -> Dictionary:
	return {
		"version": 1, "name": "Probe", "width_mm": 60.0, "height_mm": 40.0, "grid_mm": 2.54,
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 30.0, "y_mm": 20.0, "rotation_deg": 0.0,
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}, {"number": "8", "x_mm": 7.62, "y_mm": 0.0}]},
		],
	}


func _init() -> void:
	print("=== PCB Canvas Input Probe ===\n")
	await process_frame

	var root_win := get_root()
	root_win.size = Vector2i(900, 700)

	await _probe_bare()
	await _probe_with_overlay()
	await _probe_full_live_mount()
	await _probe_reparent_after_mount()
	await _probe_select_tool_boxselect()
	await _probe_pan_tool_and_gestures()
	await _probe_right_click_context_menu()
	await _probe_armed_mount_topology()
	await _probe_armed_gesture_ownership()
	await _probe_armed_shift_marquee_both_halves()
	await _probe_armed_escape_ladder()
	await _probe_armed_mixed_delete()
	await _probe_tool_family_exclusion()
	await _probe_locked_component_drag()
	await _probe_drag_emits_data_changed_once()
	await _probe_trace_pick_honours_layer_visibility()
	await _probe_eraser_per_click_snapshots()
	await _probe_via_delete_journal_shape()
	await _probe_via_over_trace_tie_rule()
	await _probe_via_bearing_drag()
	# Campaign-2 boundary GAP block (G1 — the snap-bypass grammar).
	await _probe_snap_bypass_drag()
	await _probe_snap_bypass_authoring()
	_probe_empty_default_board()
	_assert_sections_met_their_floors()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


## Mount the panel, load a board, force layout. Returns [panel, canvas].
func _mount_panel() -> Array:
	var panel = load(PANEL_PATH).new()
	get_root().add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size = Vector2(900, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_board_with_part())
	# Let containers lay out so the canvas gets a real rect.
	for _i in range(4):
		await process_frame
	var canvas = panel._canvas
	return [panel, canvas]


func _canvas_center_global(canvas) -> Vector2:
	var r: Rect2 = canvas.get_global_rect()
	return r.position + r.size * 0.5


func _push_wheel(pos: Vector2, up: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _push_button(pos: Vector2, btn: int, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _push_motion(pos: Vector2, btn_mask: int) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_mask = btn_mask
	get_root().push_input(ev, true)


func _run_input_asserts(label: String, panel, canvas) -> void:
	check("%s: canvas has a non-zero rect" % label, canvas.size.x > 1 and canvas.size.y > 1,
			"canvas.size=%s global_rect=%s" % [str(canvas.size), str(canvas.get_global_rect())])

	var center := _canvas_center_global(canvas)

	# 1. Wheel zoom. Reset to mid-range first so we test the INPUT path, not the
	#    min/max clamp (zoom_to_fit on a tiny board can pin zoom at max_zoom).
	canvas.zoom = 4.0
	var z0: float = canvas.zoom
	_push_wheel(center, true)
	await process_frame
	check("%s: wheel-up changed zoom (finding 1)" % label, canvas.zoom != z0,
			"zoom %.3f -> %.3f" % [z0, canvas.zoom])
	var z1: float = canvas.zoom
	_push_wheel(center, false)
	await process_frame
	check("%s: wheel-down changed zoom" % label, canvas.zoom != z1,
			"zoom %.3f -> %.3f" % [z1, canvas.zoom])

	# 2. Right-drag pan.
	var pan0: Vector2 = canvas.pan_offset
	_push_button(center, MOUSE_BUTTON_RIGHT, true)
	_push_motion(center + Vector2(40, 25), MOUSE_BUTTON_MASK_RIGHT)
	await process_frame
	var panned: bool = canvas.pan_offset != pan0
	_push_button(center + Vector2(40, 25), MOUSE_BUTTON_RIGHT, false)
	check("%s: right-drag panned the view (finding 2)" % label, panned,
			"pan %s -> %s" % [str(pan0), str(canvas.pan_offset)])

	# 2b. Middle-drag pan.
	var pan1: Vector2 = canvas.pan_offset
	_push_button(center, MOUSE_BUTTON_MIDDLE, true)
	_push_motion(center + Vector2(-30, 20), MOUSE_BUTTON_MASK_MIDDLE)
	await process_frame
	var panned_mid: bool = canvas.pan_offset != pan1
	_push_button(center + Vector2(-30, 20), MOUSE_BUTTON_MIDDLE, false)
	check("%s: middle-drag panned the view" % label, panned_mid,
			"pan %s -> %s" % [str(pan1), str(canvas.pan_offset)])

	# 3. Box-select on empty space.
	# Click an empty corner (world far from the part), drag out a box.
	var empty_pt: Vector2 = canvas.get_global_rect().position + Vector2(20, 20)
	_push_button(empty_pt, MOUSE_BUTTON_LEFT, true)
	await process_frame
	var began_box: bool = canvas.is_box_selecting
	_push_motion(empty_pt + Vector2(60, 60), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	_push_button(empty_pt + Vector2(60, 60), MOUSE_BUTTON_LEFT, false)
	check("%s: left-drag on empty began a box-select (finding 3)" % label, began_box,
			"is_box_selecting stayed false")


func _probe_bare() -> void:
	_begin_section("_probe_bare", 6)
	print("-- BARE panel (no annotation overlay) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	await _run_input_asserts("bare", panel, canvas)
	panel.queue_free()
	await process_frame


## Reproduce the LIVE mount: Editor._mount_annotation_dock_for_surface adds a
## platform AnnotationOverlay as a child of the panel root, covering the canvas.
## Idle (no active tool) it MUST pass pointer events through to the canvas.
func _probe_with_overlay() -> void:
	_begin_section("_probe_with_overlay", 7)
	print("\n-- panel WITH platform AnnotationOverlay sibling (live condition) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]

	var overlay := AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.add_child(overlay)
	overlay.set_host(panel.get_annotation_host())
	for _i in range(3):
		await process_frame

	check("overlay is idle (MOUSE_FILTER_IGNORE)", overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"mouse_filter=%d" % overlay.mouse_filter)
	await _run_input_asserts("overlay", panel, canvas)
	panel.queue_free()
	await process_frame


## Faithful reproduction of Editor._mount_annotation_dock_for_surface: the panel
## is reparented into an AnnotationContentRow HBox, a real AnnotationDockPane is
## added as a sibling, and the AnnotationOverlay is a child of the panel. Dock
## RIGHT mode (wide viewport). This is the closest headless replica of the live
## tab a user drives.
func _probe_full_live_mount() -> void:
	_begin_section("_probe_full_live_mount", 6)
	print("\n-- FULL live mount (content-row + real AnnotationDockPane + overlay) --")
	var panel = load(PANEL_PATH).new()
	var row := HBoxContainer.new()
	row.name = "AnnotationContentRow"
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.size = Vector2(900, 700)
	get_root().add_child(row)
	row.add_child(panel)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_board_with_part())

	var host: RefCounted = panel.get_annotation_host()
	var dock := AnnotationDockPane.new()
	dock.name = "AnnotationDockPane"
	row.add_child(dock)
	dock.set_host(host)
	dock.set_dock_mode(AnnotationDockPane.DockMode.RIGHT)

	var overlay := AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.add_child(overlay)
	overlay.set_host(host)
	if dock.has_signal("active_tool_changed"):
		dock.active_tool_changed.connect(Callable(overlay, "set_active_tool"))

	for _i in range(5):
		await process_frame

	var canvas = panel._canvas
	await _run_input_asserts("full", panel, canvas)
	row.queue_free()
	await process_frame


## REGRESSION GUARD for bug 019f39164c2e: the real editor builds the panel under
## one parent (_on_panel_loaded runs), THEN reparents it into the annotation
## content row (Editor._ensure_annotation_content_row). That reparent fires the
## canvas's _exit_tree/_enter_tree WITHOUT re-running _ready. If input config is
## only set in _ready, the reparented canvas is left MOUSE_FILTER_IGNORE and
## swallows all input (draws fine — the exact "buttons work, canvas dead" bug the
## earlier probes MISSED because they built the canvas after the final add).
## This probe reproduces the mount→reparent order and asserts input survives.
func _probe_reparent_after_mount() -> void:
	_begin_section("_probe_reparent_after_mount", 8)
	print("\n-- Reparent-after-mount (bug 019f39164c2e regression guard) --")
	var first_parent := Control.new()
	first_parent.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	first_parent.size = Vector2(900, 700)
	get_root().add_child(first_parent)

	# 1. Build the panel + canvas UNDER the first parent (as the plugin host does).
	var panel = load(PANEL_PATH).new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	first_parent.add_child(panel)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_board_with_part())
	for _i in range(3):
		await process_frame

	var canvas = panel._canvas
	check("canvas STOP before reparent", canvas.mouse_filter == Control.MOUSE_FILTER_STOP,
			"mouse_filter=%d" % canvas.mouse_filter)

	# 2. Reparent the panel into an AnnotationContentRow (as the dock mount does).
	#    This fires the canvas _exit_tree → _enter_tree.
	first_parent.remove_child(panel)
	var row := HBoxContainer.new()
	row.name = "AnnotationContentRow"
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.size = Vector2(900, 700)
	get_root().add_child(row)
	row.add_child(panel)
	var overlay := AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.add_child(overlay)
	overlay.set_host(panel.get_annotation_host())
	for _i in range(5):
		await process_frame

	# 3. After the reparent the canvas MUST still accept input.
	check("canvas STOP after reparent (not left IGNORE)",
			canvas.mouse_filter == Control.MOUSE_FILTER_STOP,
			"mouse_filter=%d — the reparent left it IGNORE" % canvas.mouse_filter)
	await _run_input_asserts("reparented", panel, canvas)
	row.queue_free()
	first_parent.queue_free()
	await process_frame


## With the Select tool_mode ACTIVE (toolbar Select pressed), a left-drag on
## empty space must still produce a box-select. Pre-fix this fails: the tool
## click short-circuits and box-select is unreachable in any tool mode.
func _probe_select_tool_boxselect() -> void:
	_begin_section("_probe_select_tool_boxselect", 2)
	print("\n-- Select-tool box-select + click-drag move (finding 3/5) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]

	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	await process_frame

	var origin: Vector2 = canvas.get_global_rect().position
	var empty_pt := origin + Vector2(20, 20)
	_push_button(empty_pt, MOUSE_BUTTON_LEFT, true)
	await process_frame
	var began_box: bool = canvas.is_box_selecting
	_push_motion(empty_pt + Vector2(80, 80), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	_push_button(empty_pt + Vector2(80, 80), MOUSE_BUTTON_LEFT, false)
	await process_frame
	check("SELECT tool: empty left-drag begins a box-select (finding 3)", began_box,
			"is_box_selecting stayed false with Select tool active")

	# Click-drag on the component moves it (smart tool, finding 5).
	var comp = panel.get_data().get_component("U1")
	var start_pos: Vector2 = comp.position
	var comp_screen: Vector2 = canvas.get_global_transform() * canvas.world_to_screen(start_pos)
	_push_button(comp_screen, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_motion(comp_screen + Vector2(canvas.zoom * 5.0, 0), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	var moved: bool = comp.position != start_pos
	_push_button(comp_screen + Vector2(canvas.zoom * 5.0, 0), MOUSE_BUTTON_LEFT, false)
	check("SELECT tool: click-drag on a component moves it (finding 5)", moved,
			"component stayed at %s" % str(start_pos))

	panel.queue_free()
	await process_frame


## Pan tool (left-drag), Space-drag pan, and trackpad pan-gesture (finding 1/2).
func _probe_pan_tool_and_gestures() -> void:
	_begin_section("_probe_pan_tool_and_gestures", 3)
	print("\n-- Pan tool + Space-drag + trackpad pan gesture (finding 1/2) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var center := _canvas_center_global(canvas)

	# Pan tool: a plain left-drag pans (no box-select).
	canvas.set_tool_mode(canvas.ToolMode.PAN)
	await process_frame
	var p0: Vector2 = canvas.pan_offset
	_push_button(center, MOUSE_BUTTON_LEFT, true)
	_push_motion(center + Vector2(35, 20), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	var pan_tool_worked: bool = canvas.pan_offset != p0 and not canvas.is_box_selecting
	_push_button(center + Vector2(35, 20), MOUSE_BUTTON_LEFT, false)
	check("Pan tool: left-drag pans (finding 2 discoverability)", pan_tool_worked,
			"pan %s -> %s box=%s" % [str(p0), str(canvas.pan_offset), str(canvas.is_box_selecting)])

	# Space-drag pan in the Select tool.
	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	await process_frame
	var space_ev := InputEventKey.new()
	space_ev.keycode = KEY_SPACE
	space_ev.pressed = true
	get_root().push_input(space_ev, true)
	await process_frame
	var p1: Vector2 = canvas.pan_offset
	_push_button(center, MOUSE_BUTTON_LEFT, true)
	_push_motion(center + Vector2(-25, 15), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	var space_pan: bool = canvas.pan_offset != p1 and not canvas.is_box_selecting
	_push_button(center + Vector2(-25, 15), MOUSE_BUTTON_LEFT, false)
	check("Space-drag pans while Select tool active", space_pan,
			"pan %s -> %s box=%s" % [str(p1), str(canvas.pan_offset), str(canvas.is_box_selecting)])

	# Trackpad pan gesture → view pans.
	var p2: Vector2 = canvas.pan_offset
	var pg := InputEventPanGesture.new()
	pg.position = center
	pg.delta = Vector2(4, 3)
	get_root().push_input(pg, true)
	await process_frame
	check("trackpad pan-gesture pans the view (finding 1)", canvas.pan_offset != p2,
			"pan %s -> %s" % [str(p2), str(canvas.pan_offset)])

	panel.queue_free()
	await process_frame


## RIGHT-CLICK IS A MENU (B1u5, docket 019fbb968e — owner: "I expect right click
## to be a menu, with delete as an option").
##
## This probe exists because the change it guards is a REMOVAL. A5 deleted a zone
## vertex on right-PRESS, before any menu; the ruling retired that gesture. A
## headless suite can prove the menu path works, but only a real press through
## Viewport.push_input can prove the OLD path is no longer wired up underneath it —
## which is the half that actually changed.
func _probe_right_click_context_menu() -> void:
	_begin_section("_probe_right_click_context_menu", 6)
	print("\n-- right-click is a menu, not a delete (B1u5) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]

	var data = panel.get_data()
	data.zones.append({
		"id": "zone:probe", "net": "GND", "layer": "top", "kind": "copper_pour",
		"outline": [
			{"x_mm": 6.0, "y_mm": 6.0}, {"x_mm": 26.0, "y_mm": 6.0},
			{"x_mm": 26.0, "y_mm": 26.0}, {"x_mm": 6.0, "y_mm": 26.0},
		],
	})
	canvas.selected_zone_ids.append("zone:probe")
	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	# Pin the view rather than inheriting zoom_to_fit's: the handle has to land
	# inside the canvas rect for the press to reach _gui_input at all, and a fitted
	# view that changes with the fixture board would make that a coin toss.
	canvas.zoom = 8.0
	canvas.pan_offset = Vector2.ZERO
	await process_frame

	var origin: Vector2 = canvas.get_global_rect().position
	var handle: Vector2 = origin + canvas.world_to_screen(Vector2(6.0, 6.0))

	# A right-click TAP on a vertex handle: press and release in the same place.
	_push_button(handle, MOUSE_BUTTON_RIGHT, true)
	await process_frame
	var outline_after_press: int = data.get_zone("zone:probe")["outline"].size()
	check("right-PRESS on a vertex handle no longer deletes it (A5 retired)",
			outline_after_press == 4, "outline is %d points" % outline_after_press)

	_push_button(handle, MOUSE_BUTTON_RIGHT, false)
	await process_frame
	check("the outline is still intact after the release too",
			data.get_zone("zone:probe")["outline"].size() == 4)
	check("the context menu popped instead",
			canvas.context_menu != null and canvas.context_menu.visible,
			"items=%d vertex=%s handle_local=%s (negative = the press never landed on the canvas)" % [
				(canvas.context_menu.item_count if canvas.context_menu != null else -1),
				str(canvas._context_menu_vertex), str(handle - origin)])

	var has_delete_vertex := false
	if canvas.context_menu != null:
		for i in canvas.context_menu.item_count:
			if canvas.context_menu.get_item_text(i) == "Delete vertex":
				has_delete_vertex = true
	check("and it carries Delete vertex", has_delete_vertex)

	if canvas.context_menu != null:
		canvas.context_menu.hide()

	# "Set trace width…" with Properties COLLAPSED — the cold-review F1 case, in a
	# REALLY MOUNTED panel, which is the only place is_visible_in_tree and
	# has_focus mean anything. The headless suite proves the flags flip; this
	# proves the SpinBox the owner has to type into is actually on screen and
	# actually holding the caret.
	var trace = load("res://../../minerva-plugins/pcb/ui/model/pcb_trace.gd").new()
	trace.net_name = "VCC"
	trace.layer = "top"
	trace.width = 0.25
	var wps: Array[Vector2] = [Vector2(8.0, 8.0), Vector2(24.0, 8.0)]
	trace.waypoints = wps
	data.add_trace(trace)
	var trace_ids: Array = data.get_trace_ids()
	if trace_ids.is_empty():
		check("probe fixture produced a trace to width-edit", false)
	else:
		panel._set_properties_expanded(false)
		canvas._request_trace_width_edit(str(trace_ids[0]))
		await process_frame
		var spin = panel._trace_prop_width_spin
		check("collapsed Properties: the width SpinBox ends up VISIBLE IN TREE",
				spin != null and spin.is_visible_in_tree(),
				"spin=%s visible_in_tree=%s properties_expanded=%s" % [
					str(spin != null), str(spin != null and spin.is_visible_in_tree()),
					str(panel._properties_expanded)])
		check("…and holding focus, ready to type",
				spin != null and spin.get_line_edit().has_focus())

	panel.queue_free()
	await process_frame


## A brand-new (anonymous) panel's default board is EMPTY (finding 4).
func _probe_empty_default_board() -> void:
	_begin_section("_probe_empty_default_board", 1)
	print("\n-- fresh panel default board is empty (finding 4) --")
	var panel = load(PANEL_PATH).new()
	check("default board has zero components (no phantom U1/R1)",
			panel.get_data().get_component_count() == 0,
			"got %d" % panel.get_data().get_component_count())
	panel.free()


# ── ARMED-PATH PROBES (campaign 2 boundary: BT-62, 57, 58, 59, 60) ────────────
#
# WHY THIS SECTION EXISTS AT ALL — BT-62.
#
# Every probe above mounts the platform AnnotationOverlay as a SIBLING of the
# canvas (a child of the panel root). Editor.gd does not: it asks the surface
# where the overlay belongs (`surface.get_annotation_overlay_parent()`,
# Editor.gd:857-868) and PCBPanel answers with the CANVAS (PCBPanel.gd:355).
# That single level of nesting is load-bearing, because PCBPanel finds the
# overlay again by searching UNDER THE CANVAS (`_find_annotation_overlay`,
# PCBPanel.gd:1838) and `_sync_universal_select` returns early when the search
# misses — so on the sibling topology the universal Select is NEVER ARMED and
# every armed-world routing rung (`_claim_annotation_press`, the annotation
# marquee sweep, the Escape ladder, the mixed Delete) is dead code the probe
# cannot reach. The suite was green on all of it by not running it.
# See docket hint `pcb-plugin/input-probe-overlay-mount-mismatch`.
#
# The mount below is the aligned one. Everything after it is only observable
# because of it.

## Board with a part AND clear empty space at the top-left corner, so a marquee
## can start on genuinely empty board.
func _armed_board() -> Dictionary:
	return _board_with_part()


## A core-generic 2d_arrow envelope anchored at board-mm (x, y).
##
## FIXTURE TRAP, measured: kind "text" with a `pcb/none` anchor is REFUSED by the
## v2 schema (`kind_anchor_incompatible`) and add_annotation_v2 returns "" — a
## silent empty host that would make every assertion below vacuously green.
## `2d_arrow` + `core/canvas.point` is the combination this host advertises
## (same as test_pcb_workflow_kinds.gd's own fixture).
func _arrow_env(x: float, y: float, summary: String) -> Dictionary:
	return {
		"id": "", "kind": "2d_arrow", "schema_version": 2,
		"anchor": {"plugin": "core", "type": "canvas.point", "id": {"x": x, "y": y},
			"snapshot": {"position": [x, y]}},
		"kind_payload": {},
		"primitives": [{"kind": "arrow", "from": [x - 2.0, y - 2.0], "to": [x, y]}],
		"lifecycle": "open", "author": {"kind": "human"},
		"view_context": "pcb", "visible_in_views": ["all"],
		"summary": summary,
	}


## Mount the panel with the overlay parented where Editor.gd parents it, and let
## the panel arm the universal Select. Returns [panel, canvas, host, overlay].
## The view is PINNED (zoom/pan) for the same reason the context-menu probe pins
## it: a fitted view that moves with the fixture makes every screen coordinate a
## coin toss.
func _mount_panel_armed() -> Array:
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var host = panel.get_annotation_host()

	var overlay := AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.get_annotation_overlay_parent().add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.set_host(host)
	for _i in range(4):
		await process_frame

	canvas.zoom = 8.0
	canvas.pan_offset = Vector2.ZERO
	await process_frame
	return [panel, canvas, host, overlay]


## Global (viewport) position of a board-mm point.
func _global_of(canvas, world: Vector2) -> Vector2:
	return canvas.get_global_rect().position + canvas.world_to_screen(world)


func _push_button_mods(pos: Vector2, btn: int, pressed: bool, shift: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	ev.shift_pressed = shift
	get_root().push_input(ev, true)


func _push_key(keycode: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	get_root().push_input(ev, true)


## The arrow's own geometry, read out of the HOST's stored envelope — a
## representation the canvas never writes and the tool only writes through the
## annotation substrate.
func _arrow_payload(host, ann_id: String) -> Dictionary:
	for a in host.get_annotations():
		if a is Dictionary and str((a as Dictionary).get("id", "")) == ann_id:
			var d: Dictionary = (a as Dictionary).duplicate(true)
			# created_at/updated_at are wall-clock; comparing them would make
			# "payload unchanged" a clock assertion.
			d.erase("updated_at")
			d.erase("created_at")
			return d
	return {}


## BT-62 — the topology pin itself.
##
## ORACLE (a different representation from the code's own predicate): the panel's
## own overlay lookup and the host's armed flag, both of which are *state owned by
## two other objects* than the test's mount call. The test does not assert
## "I called add_child on the canvas"; it asserts that the two consumers which
## have to find that overlay actually do.
func _probe_armed_mount_topology() -> void:
	_begin_section("_probe_armed_mount_topology", 7)
	print("\n-- ARMED mount topology (BT-62) --")
	var pcho := await _mount_panel_armed()
	var panel = pcho[0]
	var canvas = pcho[1]
	var host = pcho[2]
	var overlay = pcho[3]

	check("BT-62: Editor.gd's overlay parent for this panel IS the canvas",
			panel.get_annotation_overlay_parent() == canvas,
			"got %s" % str(panel.get_annotation_overlay_parent()))
	check("BT-62: the panel's own _find_annotation_overlay resolves the mount",
			panel._find_annotation_overlay() == overlay,
			"found=%s (sibling mount returns null and silently disarms everything)"
					% str(panel._find_annotation_overlay()))
	check("BT-62: the universal Select is ARMED on this topology",
			host.is_universal_select_armed(),
			"is_universal_select_armed()=false — the armed world is unreachable")
	check("BT-62: …and armed PASSIVELY, so the canvas keeps owning clicks",
			overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"mouse_filter=%d (STOP would end Godot's gui walk at the overlay)"
					% overlay.mouse_filter)
	check("BT-62: the canvas holds the router",
			canvas._annotation_router != null)

	# The armed path is only worth arming if a real press reaches it. One
	# end-to-end press on annotation ink, asserted through the HOST's selection
	# set — not through any canvas flag.
	var ann_id: String = host.add_annotation_v2(_arrow_env(10.0, 10.0, "probe arrow"))
	check("BT-62 fixture: the arrow envelope was accepted", ann_id != "",
			"add_annotation_v2 returned empty — check the anchor/kind pairing")
	await process_frame
	var g := _global_of(canvas, Vector2(10.0, 10.0))
	_push_button(g, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_button(g, MOUSE_BUTTON_LEFT, false)
	await process_frame
	check("BT-62: a real press on annotation ink selects it through the armed path",
			host.get_selected_annotation_ids().has(ann_id),
			"selected=%s" % str(host.get_selected_annotation_ids()))

	panel.queue_free()
	await process_frame


## BT-57 — press-time gesture ownership is sticky across move and up.
##
## ORACLE: the MUTATION THAT LANDED, not a router flag. A press that starts on
## annotation ink and ends over a component must move the ANNOTATION and leave the
## component's SERIALIZED position untouched — two stores, one gesture. A router
## that re-resolved ownership per motion would hand the drag to the board world
## partway across and move U1 instead (or as well).
func _probe_armed_gesture_ownership() -> void:
	_begin_section("_probe_armed_gesture_ownership", 6)
	print("\n-- ARMED: press-time gesture ownership is sticky (BT-57) --")
	var pcho := await _mount_panel_armed()
	var panel = pcho[0]
	var canvas = pcho[1]
	var host = pcho[2]
	var data = panel.get_data()

	var ann_id: String = host.add_annotation_v2(_arrow_env(10.0, 10.0, "sticky"))
	check("BT-57 fixture: arrow stored", ann_id != "")
	await process_frame

	var before_ann := _arrow_payload(host, ann_id)
	var before_board: Dictionary = data.to_board_dict()

	var start := _global_of(canvas, Vector2(10.0, 10.0))
	var over_part := _global_of(canvas, Vector2(30.0, 20.0))
	_push_button(start, MOUSE_BUTTON_LEFT, true)
	await process_frame
	check("BT-57: the press was claimed by the annotation world",
			canvas._annotation_gesture, "_annotation_gesture stayed false")
	# Cross into board space in two motions — a per-motion re-resolve would flip
	# ownership on the first one that lands over the component.
	_push_motion(start + (over_part - start) * 0.5, MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	_push_motion(over_part, MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	check("BT-57: ownership is still the annotation world mid-drag",
			canvas._annotation_gesture)
	_push_button(over_part, MOUSE_BUTTON_LEFT, false)
	await process_frame

	var after_ann := _arrow_payload(host, ann_id)
	var after_board: Dictionary = data.to_board_dict()
	check("BT-57: the ANNOTATION is what moved", after_ann != before_ann,
			"annotation payload identical after a drag that crossed the board")
	check("BT-57: the board is byte-identical — the release landed in the ink world",
			after_board == before_board,
			"serialized board changed: a component moved under a claimed gesture")
	check("BT-57: and the gesture ended on release", not canvas._annotation_gesture)

	panel.queue_free()
	await process_frame


## BT-58 — shift+box over ring+board selects BOTH halves.
##
## ORACLE: the UNION of two independently owned id sets — the AnnotationHost's
## selection set and the canvas's board id list. Neither is derived from the
## other, and the router being mods-blind (the would-have-shipped N1 bug) loses
## the board half while the ink half still looks fine.
##
## Fixture shape published to nudge c2-epochB/boundary.bt58-fixture for the core
## half (BT-61).
func _probe_armed_shift_marquee_both_halves() -> void:
	_begin_section("_probe_armed_shift_marquee_both_halves", 4)
	print("\n-- ARMED: shift+box takes ring AND board (BT-58) --")
	var pcho := await _mount_panel_armed()
	var panel = pcho[0]
	var canvas = pcho[1]
	var host = pcho[2]

	var ann_id: String = host.add_annotation_v2(_arrow_env(10.0, 10.0, "ring half"))
	check("BT-58 fixture: arrow stored", ann_id != "")
	await process_frame

	# Empty corner → past both entities. Travel is far beyond
	# ANNOTATION_MARQUEE_TRAVEL_PX so the release is a BOX, not a click.
	var from := _global_of(canvas, Vector2(4.0, 4.0))
	var to := _global_of(canvas, Vector2(36.0, 26.0))
	_push_button_mods(from, MOUSE_BUTTON_LEFT, true, true)
	await process_frame
	check("BT-58: the empty shift-press armed a box", canvas.is_box_selecting)
	_push_motion(to, MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	_push_button_mods(to, MOUSE_BUTTON_LEFT, false, true)
	await process_frame

	check("BT-58: the BOARD half of the union is selected",
			canvas.selected_components.has("U1"),
			"selected_components=%s (a mods-blind router loses this half)"
					% str(canvas.selected_components))
	check("BT-58: the ANNOTATION half of the union is selected",
			host.get_selected_annotation_ids().has(ann_id),
			"selected annotations=%s" % str(host.get_selected_annotation_ids()))

	panel.queue_free()
	await process_frame


## BT-59 — Escape mid-drag reverts the annotation payload and leaves BOTH
## selections alone; a second Escape empties both sets.
##
## ORACLE: pre-drag payload equality read from the host's stored envelope, plus
## the two set sizes, asserted as a TWO-STEP sequence. An Escape that clears
## everything on step 1 reds on the set sizes; an Escape that reverts the payload
## but also drops the board half reds on the "untouched" leg alone.
func _probe_armed_escape_ladder() -> void:
	_begin_section("_probe_armed_escape_ladder", 10)
	print("\n-- ARMED: two-step Escape ladder (BT-59) --")
	var pcho := await _mount_panel_armed()
	var panel = pcho[0]
	var canvas = pcho[1]
	var host = pcho[2]

	var ann_id: String = host.add_annotation_v2(_arrow_env(10.0, 10.0, "esc"))
	check("BT-59 fixture: arrow stored", ann_id != "")
	await process_frame

	# MEASURED GRAMMAR (finding, recorded rather than wished away): the core
	# AnnotationTransformTool only DRAGS an annotation that is already selected
	# (on_pointer_down falls to _begin_drag through the gizmo zones, and shift is
	# always membership-editing, never a drag). So a drag press is necessarily a
	# PLAIN press, and _claim_annotation_press's non-shift branch runs
	# _clear_selection() on the board half at PRESS time — by design, documented
	# on that function. There is therefore no reachable state in which a board
	# selection is live during an annotation drag. The board leg below is pinned
	# to what the PRESS left, which is the honest statement; the load-bearing leg
	# of this oracle is the annotation count.
	var ink := _global_of(canvas, Vector2(10.0, 10.0))
	var part := _global_of(canvas, Vector2(30.0, 20.0))
	_push_button(part, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_button(part, MOUSE_BUTTON_LEFT, false)
	await process_frame
	check("BT-59 fixture: the board half is selected before the ink press",
			canvas.selected_components.has("U1"), str(canvas.selected_components))

	# Click 1 selects the annotation (and, per the claim contract, replaces the
	# board half). Click 2 is the one that drags it.
	_push_button(ink, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_button(ink, MOUSE_BUTTON_LEFT, false)
	await process_frame
	check("BT-59: the plain claim press is what dropped the board half, not Escape",
			canvas.selected_components.is_empty(),
			"selected_components=%s" % str(canvas.selected_components))
	check("BT-59 fixture: the annotation is selected and draggable",
			host.selected_annotation_count() == 1,
			"count=%d" % host.selected_annotation_count())

	var before := _arrow_payload(host, ann_id)
	_push_button(ink, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_motion(ink + Vector2(48, 32), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	check("BT-59 fixture: a drag is live and the payload has actually moved",
			_arrow_payload(host, ann_id) != before,
			"nothing moved — the revert assertion below would be vacuous")
	var board_at_drag: Array = canvas.selected_components.duplicate()

	canvas.grab_focus()
	_push_key(KEY_ESCAPE)
	await process_frame
	check("BT-59 step 1: Escape reverted the annotation payload",
			_arrow_payload(host, ann_id) == before,
			"payload still moved after Escape")
	check("BT-59 step 1: the ANNOTATION selection is untouched",
			host.selected_annotation_count() == 1,
			"count=%d — the first Escape is a GESTURE cancel, not a selection clear"
					% host.selected_annotation_count())
	check("BT-59 step 1: the BOARD selection is exactly what the press left it",
			canvas.selected_components == board_at_drag,
			"board %s -> %s" % [str(board_at_drag), str(canvas.selected_components)])

	# Release the (now dead) button so the second Escape runs with no gesture.
	_push_button(ink + Vector2(48, 32), MOUSE_BUTTON_LEFT, false)
	await process_frame
	canvas.grab_focus()
	_push_key(KEY_ESCAPE)
	await process_frame
	check("BT-59 step 2: the second Escape empties the ANNOTATION set",
			host.selected_annotation_count() == 0,
			"count=%d" % host.selected_annotation_count())
	check("BT-59 step 2: …and the BOARD set",
			canvas.selected_components.is_empty(),
			"selected_components=%s" % str(canvas.selected_components))

	panel.queue_free()
	await process_frame


## BT-60 — mixed Delete: the board half is ONE journalled batch that undo restores
## exactly, the annotation half is gone from the SIDECAR ON DISK and does not come
## back. The asymmetry is asserted deliberately, because it is announced.
##
## ORACLE: two different stores — pcb_data's history/journal, and the annotation
## sidecar JSON re-read from disk — plus the announced notice text.
func _probe_armed_mixed_delete() -> void:
	_begin_section("_probe_armed_mixed_delete", 9)
	print("\n-- ARMED: mixed Delete + the announced undo asymmetry (BT-60) --")
	var pcho := await _mount_panel_armed()
	var panel = pcho[0]
	var canvas = pcho[1]
	var host = pcho[2]
	var data = panel.get_data()

	var doc_path := "user://bt60_probe_board.pcbskel"
	host.set_document_path(doc_path)

	var ann_id: String = host.add_annotation_v2(_arrow_env(10.0, 10.0, "doomed"))
	check("BT-60 fixture: arrow stored", ann_id != "")
	await process_frame
	host.save_sidecar(doc_path)
	check("BT-60 fixture: the sidecar carries the annotation before Delete",
			_sidecar_has_id(doc_path, ann_id),
			"sidecar did not contain %s" % ann_id)

	# Mixed selection: board component + annotation.
	var part := _global_of(canvas, Vector2(30.0, 20.0))
	_push_button(part, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_button(part, MOUSE_BUTTON_LEFT, false)
	await process_frame
	var ink := _global_of(canvas, Vector2(10.0, 10.0))
	_push_button_mods(ink, MOUSE_BUTTON_LEFT, true, true)
	await process_frame
	_push_button_mods(ink, MOUSE_BUTTON_LEFT, false, true)
	await process_frame
	check("BT-60 fixture: both halves selected",
			canvas.selected_components.has("U1") and host.selected_annotation_count() == 1,
			"board=%s ann=%d" % [str(canvas.selected_components), host.selected_annotation_count()])

	var notices: Array[String] = []
	canvas.component_lock_changed.connect(func(msg: String) -> void: notices.append(msg))

	var hist_before: int = data.history.size()
	var comps_before: Array = (data.to_board_dict().get("components", []) as Array).duplicate(true)

	canvas.grab_focus()
	_push_key(KEY_DELETE)
	await process_frame

	check("BT-60: the board half went as exactly ONE history step",
			data.history.size() - hist_before == 1,
			"history delta=%d" % (data.history.size() - hist_before))
	check("BT-60: the component is gone from the serialized board",
			(data.to_board_dict().get("components", []) as Array).is_empty(),
			"components=%s" % str(data.to_board_dict().get("components", [])))
	check("BT-60: the annotation is gone from the host",
			not host.get_selected_annotation_ids().has(ann_id)
					and _find_ann(host, ann_id).is_empty())
	check("BT-60: the asymmetry was ANNOUNCED, not silent",
			notices.size() > 0 and notices[notices.size() - 1].contains("no undo"),
			"notices=%s" % str(notices))

	# Undo restores EXACTLY the board half.
	data.undo()
	await process_frame
	check("BT-60: undo restores the board half value-wise",
			(data.to_board_dict().get("components", []) as Array) == comps_before,
			"restored=%s" % str(data.to_board_dict().get("components", [])))

	# …and the annotation does NOT come back. Re-flush the sidecar (the panel's
	# own save path) and read the FILE — a store the board journal cannot touch.
	host.save_sidecar(doc_path)
	check("BT-60: the annotation stays gone from the sidecar on disk",
			not _sidecar_has_id(doc_path, ann_id),
			"undo resurrected the annotation, contradicting the announced asymmetry")

	panel.queue_free()
	await process_frame


# ── GESTURE / SELECTION PROBES (BT-01…04, 07, 52, 54, 55) ─────────────────────

## BT-01 — three-direction tool exclusion (canvas tools ↔ route-flow cluster ↔
## dock/overlay annotation tool).
##
## ORACLE: a STATE TRIPLE read from three different owners — the canvas's own
## `tool_mode`, the panel's Button widgets' `button_pressed`, and the overlay's
## active tool object — never the return value of the setter that was just
## called.
func _probe_tool_family_exclusion() -> void:
	_begin_section("_probe_tool_family_exclusion", 8)
	print("\n-- three-direction tool exclusion (BT-01) --")
	var pcho := await _mount_panel_armed()
	var panel = pcho[0]
	var canvas = pcho[1]
	var overlay = pcho[3]

	# ── direction 1: a CANVAS tool press releases the other two families ──────
	panel._on_single_trace_button_pressed_for_test() if panel.has_method(
			"_on_single_trace_button_pressed_for_test") else _arm_route_flow(panel, "single_trace")
	await process_frame
	check("BT-01 fixture: a route-flow tool is armed",
			panel._active_route_flow_tool != null,
			"route-flow arming unavailable in this fixture")

	panel._toggle_tool_mode(canvas.ToolMode.PAN)
	await process_frame
	check("BT-01 dir1: canvas tool armed (owner: the canvas)",
			canvas.tool_mode == canvas.ToolMode.PAN, "tool_mode=%d" % canvas.tool_mode)
	check("BT-01 dir1: the route-flow tool object is gone (owner: the panel)",
			panel._active_route_flow_tool == null)
	check("BT-01 dir1: …and its DOCK BUTTON is un-pressed (owner: the widget)",
			not _any_route_flow_pressed(panel),
			"a route-flow button is still latched: %s" % _route_flow_pressed_names(panel))

	# ── direction 2: a ROUTE-FLOW arm releases the canvas tool surface ────────
	_arm_route_flow(panel, "single_trace")
	await process_frame
	check("BT-01 dir2: a route-flow arm dropped the canvas tool back to Select",
			canvas.tool_mode == canvas.ToolMode.SELECT, "tool_mode=%d" % canvas.tool_mode)
	check("BT-01 dir2: …and the canvas tool BUTTON is un-pressed",
			not _canvas_tool_button_pressed(panel, canvas.ToolMode.PAN),
			"the Pan button is still latched while a route tool is armed")

	# ── direction 3: a FOREIGN (dock) tool on the shared overlay releases the
	#    route-flow cluster. The overlay is the third owner.
	var foreign := AnnotationTransformTool.new()
	overlay.set_active_tool(foreign)
	await process_frame
	check("BT-01 dir3: a foreign overlay tool tore down the route-flow tool",
			panel._active_route_flow_tool == null,
			"panel still tracks its own tool while another surface holds the overlay")
	check("BT-01 dir3: …and un-pressed its buttons",
			not _any_route_flow_pressed(panel), _route_flow_pressed_names(panel))
	overlay.clear_active_tool()

	panel.queue_free()
	await process_frame


func _arm_route_flow(panel, key: String) -> void:
	var btn: Button = panel._route_flow_buttons.get(key, null)
	if btn == null:
		return
	btn.set_pressed_no_signal(true)
	match key:
		"single_trace": panel._on_single_trace_button_pressed()
		"edit_hint": panel._on_edit_hint_button_pressed()
		"add_via": panel._on_add_via_button_pressed()


func _any_route_flow_pressed(panel) -> bool:
	for k in panel._route_flow_buttons.keys():
		var b: Button = panel._route_flow_buttons[k]
		if is_instance_valid(b) and b.button_pressed:
			return true
	return false


func _route_flow_pressed_names(panel) -> String:
	var names: Array[String] = []
	for k in panel._route_flow_buttons.keys():
		var b: Button = panel._route_flow_buttons[k]
		if is_instance_valid(b) and b.button_pressed:
			names.append(str(k))
	return str(names)


func _canvas_tool_button_pressed(panel, mode: int) -> bool:
	var b: Button = panel._tool_buttons.get(mode, null)
	return b != null and is_instance_valid(b) and b.button_pressed


## BT-02 — a LOCKED component is selectable but never moves.
##
## ORACLE: the SERIALIZED position out of to_board_dict() (not comp.position, the
## field the drag path itself writes), plus a non-empty selection set. Both legs
## matter: a lock that also blocked selection would be an over-correction and reds
## on the second leg.
##
## MEASURED FINDING, recorded here rather than papered over: a locked component
## is NOT click-selectable at all — pcb_data.get_component_at() skips locked
## components outright (model/pcb_data.gd:303), so a press on one lands on empty
## board. "Selectable" is therefore true only through the MARQUEE, and the only
## reachable drag of a locked part is a MIXED selection anchored on an unlocked
## one. That is what this probe drives; a click-anchored version would be testing
## an unreachable gesture.
func _probe_locked_component_drag() -> void:
	_begin_section("_probe_locked_component_drag", 3)
	print("\n-- locked components select but never move (BT-02) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var data = panel.get_data()
	data.get_component("U1").locked = true
	# A second, UNLOCKED part to anchor the drag on.
	var u2 = load("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd").new()
	u2.id = "U2"
	u2.position = Vector2(45.0, 20.0)
	data.add_component(u2)
	canvas.zoom = 8.0
	canvas.pan_offset = Vector2.ZERO
	await process_frame

	var before: Variant = _serialized_component(data, "U1")
	var u2_before: Variant = _serialized_component(data, "U2")
	canvas._clear_selection()
	canvas._add_to_selection(canvas.KIND_COMPONENT, "U1")
	canvas._add_to_selection(canvas.KIND_COMPONENT, "U2")
	await process_frame

	var g := _global_of(canvas, Vector2(45.0, 20.0))
	_push_button(g, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_motion(g + Vector2(60, 40), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	_push_motion(g + Vector2(120, 80), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	_push_button(g + Vector2(120, 80), MOUSE_BUTTON_LEFT, false)
	await process_frame

	check("BT-02: the locked part is still SELECTED after the gesture",
			canvas.selected_components.has("U1"),
			"selected=%s — a lock that blocks selection is an over-correction"
					% str(canvas.selected_components))
	check("BT-02 fixture: the UNLOCKED anchor moved (the comparison is not vacuous)",
			_serialized_component(data, "U2") != u2_before)
	check("BT-02: …and the locked part's SERIALIZED position is unchanged",
			_serialized_component(data, "U1") == before,
			"%s -> %s" % [str(before), str(_serialized_component(data, "U1"))])

	panel.queue_free()
	await process_frame


func _serialized_component(data, ref: String) -> Variant:
	for c in (data.to_board_dict().get("components", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("ref", "")) == ref:
			return c
	return null


## BT-03 — one data_changed per drag GESTURE, however many motion frames it had.
##
## ORACLE: a signal-count observer attached to the MODEL before the gesture. The
## count is owned by the signal bus, not by the canvas.
func _probe_drag_emits_data_changed_once() -> void:
	_begin_section("_probe_drag_emits_data_changed_once", 2)
	print("\n-- one data_changed per drag gesture (BT-03) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var data = panel.get_data()
	canvas.zoom = 8.0
	canvas.pan_offset = Vector2.ZERO
	await process_frame

	var hits: Array[int] = [0]
	data.data_changed.connect(func() -> void: hits[0] += 1)

	var g := _global_of(canvas, Vector2(30.0, 20.0))
	_push_button(g, MOUSE_BUTTON_LEFT, true)
	await process_frame
	for step in [20, 40, 60, 80]:
		_push_motion(g + Vector2(step, step), MOUSE_BUTTON_MASK_LEFT)
		await process_frame
	_push_button(g + Vector2(80, 80), MOUSE_BUTTON_LEFT, false)
	await process_frame

	check("BT-03: the part actually moved (the count below is not vacuous)",
			data.get_component("U1").position != Vector2(30.0, 20.0))
	check("BT-03: data_changed fired EXACTLY once for a 4-motion drag",
			hits[0] == 1, "count=%d" % hits[0])

	panel.queue_free()
	await process_frame


## BT-04 — the trace SINGLE-PICK honours layer visibility.
##
## ORACLE: the returned entity ID at a point where two traces overlap, one on a
## filtered-out layer. An id compare, not a boolean: "did it refuse" cannot tell a
## visibility filter from a broken hit test.
func _probe_trace_pick_honours_layer_visibility() -> void:
	_begin_section("_probe_trace_pick_honours_layer_visibility", 4)
	print("\n-- trace pick honours layer visibility (BT-04) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var data = panel.get_data()

	var top_id := _add_trace(data, "top", "VCC", [Vector2(8.0, 8.0), Vector2(24.0, 8.0)])
	var bot_id := _add_trace(data, "bottom", "GND", [Vector2(8.0, 8.0), Vector2(24.0, 8.0)])
	check("BT-04 fixture: two coincident traces on different layers",
			top_id != "" and bot_id != "" and top_id != bot_id)

	canvas.trace_layer_filter = "all"
	var both: String = canvas._trace_at(Vector2(16.0, 8.0))
	check("BT-04 baseline: unfiltered, the pick returns one of the two",
			both == top_id or both == bot_id, "got %s" % both)

	canvas.trace_layer_filter = "top"
	check("BT-04: with 'bottom' hidden the pick returns the TOP trace id",
			canvas._trace_at(Vector2(16.0, 8.0)) == top_id,
			"got %s, expected %s" % [canvas._trace_at(Vector2(16.0, 8.0)), top_id])
	canvas.trace_layer_filter = "bottom"
	check("BT-04: with 'top' hidden the pick returns the BOTTOM trace id",
			canvas._trace_at(Vector2(16.0, 8.0)) == bot_id,
			"got %s, expected %s" % [canvas._trace_at(Vector2(16.0, 8.0)), bot_id])

	panel.queue_free()
	await process_frame


func _add_trace(data, layer: String, net: String, pts: Array) -> String:
	var trace = load("res://../../minerva-plugins/pcb/ui/model/pcb_trace.gd").new()
	trace.net_name = net
	trace.layer = layer
	trace.width = 0.25
	var wps: Array[Vector2] = []
	for p in pts:
		wps.append(p as Vector2)
	trace.waypoints = wps
	# add_trace returns void and mints the id onto the object itself.
	data.add_trace(trace)
	return str(trace.id)


## BT-07 — the eraser snapshots PER CLICK and is never batched.
##
## ORACLE: history length delta per click (1 per click, N after N clicks), then N
## undos restoring in REVERSE order — the order asserted by the id sequence, which
## a "snapshot before mutation" bug silently breaks (the 019fb5ad79 class).
func _probe_eraser_per_click_snapshots() -> void:
	_begin_section("_probe_eraser_per_click_snapshots", 6)
	print("\n-- eraser: one snapshot per click, unbatched (BT-07) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var data = panel.get_data()

	var ids: Array[String] = []
	ids.append(_add_trace(data, "top", "N1", [Vector2(8.0, 8.0), Vector2(24.0, 8.0)]))
	ids.append(_add_trace(data, "top", "N2", [Vector2(8.0, 14.0), Vector2(24.0, 14.0)]))
	ids.append(_add_trace(data, "top", "N3", [Vector2(8.0, 20.0), Vector2(24.0, 20.0)]))
	canvas.set_tool_mode(canvas.ToolMode.ERASER)
	canvas.zoom = 8.0
	canvas.pan_offset = Vector2.ZERO
	await process_frame

	# Baseline snapshot so the THIRD undo has somewhere to land — without it the
	# reverse-order leg can only ever prove two steps (measured).
	data.save_to_history("baseline")
	var hist0: int = data.history.size()
	var journal0: int = data.change_journal.size()
	var ys := [8.0, 14.0, 20.0]
	for i in 3:
		var g := _global_of(canvas, Vector2(16.0, ys[i]))
		_push_button(g, MOUSE_BUTTON_LEFT, true)
		await process_frame
		_push_button(g, MOUSE_BUTTON_LEFT, false)
		await process_frame
		check("BT-07: history delta is exactly %d after %d eraser click(s)" % [i + 1, i + 1],
				data.history.size() - hist0 == i + 1,
				"delta=%d" % (data.history.size() - hist0))

	check("BT-07: the journal grew per click too (not one batched entry)",
			data.change_journal.size() - journal0 >= 3,
			"journal delta=%d" % (data.change_journal.size() - journal0))
	check("BT-07 fixture: all three traces are gone", data.get_trace_ids().is_empty(),
			"remaining=%s" % str(data.get_trace_ids()))

	# Undo three times: the traces come back in REVERSE deletion order. Asserting
	# the id sequence — not just the count — is what catches a snapshot taken
	# BEFORE the mutation, which restores the wrong generation each step.
	var restored: Array[String] = []
	for i in 3:
		data.undo()
		var now: Array = data.get_trace_ids()
		for t in now:
			if not restored.has(str(t)):
				restored.append(str(t))
	check("BT-07: three undos restore in reverse deletion order",
			restored == [ids[2], ids[1], ids[0]],
			"restored=%s expected=%s" % [str(restored), str([ids[2], ids[1], ids[0]])])

	panel.queue_free()
	await process_frame


## BT-52 — via delete journal/history shape: +1 journal per single delete, +N
## journal per N-entity batch, but +1 HISTORY per batch.
##
## ORACLE: TWO counters (change_journal length and history length). The +N/+1
## asymmetry is the whole point — either counter alone passes a mutation that
## breaks the other.
func _probe_via_delete_journal_shape() -> void:
	_begin_section("_probe_via_delete_journal_shape", 5)
	print("\n-- via delete: journal +N, history +1 per batch (BT-52) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var data = panel.get_data()

	for i in 4:
		data.add_via({"id": "via_%d" % i, "position": Vector2(10.0 + i * 4.0, 30.0),
				"net_name": "GND", "size": 0.8})
	canvas.zoom = 8.0
	canvas.pan_offset = Vector2.ZERO
	await process_frame

	# 1. single delete through the canvas selection path.
	canvas._clear_selection()
	canvas._add_to_selection(canvas.KIND_VIA, "via_0")
	var j0: int = data.change_journal.size()
	var h0: int = data.history.size()
	canvas._delete_selection()
	check("BT-52 single: journal +1", data.change_journal.size() - j0 == 1,
			"delta=%d" % (data.change_journal.size() - j0))
	check("BT-52 single: history +1", data.history.size() - h0 == 1,
			"delta=%d" % (data.history.size() - h0))

	# 2. batch of three.
	canvas._clear_selection()
	for vid in ["via_1", "via_2", "via_3"]:
		canvas._add_to_selection(canvas.KIND_VIA, vid)
	var j1: int = data.change_journal.size()
	var h1: int = data.history.size()
	canvas._delete_selection()
	check("BT-52 batch: journal +3 (one entry per entity)",
			data.change_journal.size() - j1 == 3,
			"delta=%d" % (data.change_journal.size() - j1))
	check("BT-52 batch: history +1 (one undo step for the batch)",
			data.history.size() - h1 == 1,
			"delta=%d" % (data.history.size() - h1))
	check("BT-52: all four vias are gone", data.vias.is_empty(),
			"remaining=%d" % data.vias.size())

	panel.queue_free()
	await process_frame


## BT-54 — the via/trace tie rule, asserted as IDS at two probe points.
##
## ORACLE: the entity id `_entity_at` returns inside the via disc versus one via
## radius further along the SAME copper. Never pixels, never a boolean.
func _probe_via_over_trace_tie_rule() -> void:
	_begin_section("_probe_via_over_trace_tie_rule", 2)
	print("\n-- via-over-trace tie rule (BT-54) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var data = panel.get_data()

	var trace_id := _add_trace(data, "top", "GND", [Vector2(8.0, 30.0), Vector2(40.0, 30.0)])
	data.add_via({"id": "via_tie", "position": Vector2(20.0, 30.0), "net_name": "GND",
			"size": 2.0})
	canvas.zoom = 8.0
	canvas.pan_offset = Vector2.ZERO
	await process_frame

	var inside: Array = canvas._entity_at(Vector2(20.0, 30.0))
	check("BT-54: a pick INSIDE the via disc returns the VIA id",
			str(inside[0]) == canvas.KIND_VIA and str(inside[1]) == "via_tie",
			"got %s/%s" % [str(inside[0]), str(inside[1])])

	var outside: Array = canvas._entity_at(Vector2(34.0, 30.0))
	check("BT-54: the SAME copper one radius away returns the TRACE id",
			str(outside[0]) == canvas.KIND_TRACE and str(outside[1]) == trace_id,
			"got %s/%s (expected trace %s)" % [str(outside[0]), str(outside[1]), trace_id])

	panel.queue_free()
	await process_frame


## BT-55 — a via-bearing drag: vias hold still while the components move, AND the
## anchor still snaps.
##
## ORACLE: the PAIR — serialized via positions compared against serialized
## component positions in one gesture, plus the snapped landing point. A
## zero-fallthrough for vias holds the vias but breaks mixed-selection anchor
## snapping, which only the third leg catches (review F3).
func _probe_via_bearing_drag() -> void:
	_begin_section("_probe_via_bearing_drag", 4)
	print("\n-- via-bearing drag: vias hold, anchor still snaps (BT-55) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var data = panel.get_data()
	data.add_via({"id": "via_hold", "position": Vector2(12.0, 30.0), "net_name": "GND",
			"size": 0.8})
	canvas.zoom = 8.0
	canvas.pan_offset = Vector2.ZERO
	await process_frame

	var via_before: Dictionary = _serialized_via(data, "via_hold")
	check("BT-55 fixture: the via serializes", not via_before.is_empty())

	# Mixed selection: the component is the drag ANCHOR, the via rides along.
	canvas._clear_selection()
	canvas._add_to_selection(canvas.KIND_COMPONENT, "U1")
	canvas._add_to_selection(canvas.KIND_VIA, "via_hold")
	var g := _global_of(canvas, Vector2(30.0, 20.0))
	_push_button(g, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_motion(g + Vector2(97, 61), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	_push_button(g + Vector2(97, 61), MOUSE_BUTTON_LEFT, false)
	await process_frame

	var comp_after: Vector2 = data.get_component("U1").position
	check("BT-55: the COMPONENT moved", comp_after != Vector2(30.0, 20.0),
			"component stayed put — the comparison below would be vacuous")
	check("BT-55: the VIA is byte-identical", _serialized_via(data, "via_hold") == via_before,
			"%s -> %s" % [str(via_before), str(_serialized_via(data, "via_hold"))])
	# The anchor snapping leg: the landing point is on the grid, which a
	# zero-fallthrough anchor (via chosen as anchor, delta forced to zero) breaks.
	# `grid_size` is the MODEL's property; `grid_mm` is only the SERIALIZATION
	# key (pcb_data.to_board_dict). The first draft of this leg read `grid_mm`
	# off the model, which is a runtime error — and a script error mid-`await`
	# aborts the WHOLE test function, so this leg silently never ran while the
	# suite still reported a clean total (D1 oracle-integrity review, finding 1).
	var grid: float = data.grid_size
	check("BT-55: the anchor landed ON the snap grid",
			is_equal_approx(fposmod(comp_after.x, grid), 0.0)
					or is_equal_approx(fposmod(comp_after.x, grid), grid),
			"x=%f grid=%f" % [comp_after.x, grid])

	panel.queue_free()
	await process_frame


func _serialized_via(data, via_id: String) -> Dictionary:
	for v in (data.to_board_dict().get("vias", []) as Array):
		if v is Dictionary and str((v as Dictionary).get("id", "")) == via_id:
			return v as Dictionary
	return {}


func _find_ann(host, ann_id: String) -> Dictionary:
	for a in host.get_annotations():
		if a is Dictionary and str((a as Dictionary).get("id", "")) == ann_id:
			return a as Dictionary
	return {}


## Raw sidecar read: the JSON file the panel writes, parsed here rather than
## asked of the host.
func _sidecar_has_id(doc_path: String, ann_id: String) -> bool:
	var p: String = AnnotationSidecar.sidecar_path_for(doc_path)
	if not FileAccess.file_exists(p):
		return false
	var txt := FileAccess.get_file_as_string(p)
	return txt.contains(ann_id)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)


# ── G1. THE SNAP-BYPASS GRAMMAR (campaign-2 boundary gap) ────────────────────
#
# WHY THIS SECTION EXISTS. Campaign 2's second promise is "Illustrator grammar"
# — selection, deletion, grouping, width AND SNAP. The Ctrl/Cmd snap-bypass was
# owner-ruled (cmt 936) and shipped across epochs A/B, and the completeness
# critic measured that it had ZERO automated coverage: only C2-CHECK 3 (a
# perceptual bless) and BT-55's incidental "the anchor is on the grid" leg,
# which asserts the OPPOSITE case. The modifier itself — the whole feature —
# was untested.
#
# ONE production predicate serves both halves of the grammar (pcb_canvas.gd
# `_snap_bypass_held()`, read live from Input rather than off the event, so it
# can be toggled mid-gesture), and TWO call sites consume it:
#   * the drag-move anchor        (_handle_mouse_motion, snap_to_grid path)
#   * the authoring click         (_author_point, snap_author_point path)
# Both are pinned below, because the two are separately deletable — which is
# exactly the HALF mutation.
#
# ORACLE: SERIALIZED positions (to_board_dict) against HAND-COMPUTED expected
# values written as literals here. Nothing in the assertions calls
# data.snap_to_grid()/snap_author_point() to build its own expectation — that
# would be the code grading its own homework, and a snapper that quietly
# changed its rounding would stay green forever.
#
# Fixture arithmetic, worked out by hand at zoom 8 (1 mm = 8 px), pan 0:
#   drag   U1 (30, 20) + (97, 61) px = +(12.125, 7.625) mm  -> (42.125, 27.625)
#          snapped on the 2.54 grid:  round(16.5846)=17 -> 43.18
#                                     round(10.8760)=11 -> 27.94
#   author quarter grid = 2.54 * 0.25 = 0.635 mm
#          10.3 -> round(16.2205)=16 -> 10.16
#          20.4 -> round(32.1260)=32 -> 20.32
#          20.5 -> round(32.2835)=32 -> 20.32
# The pixel delta and the click points are chosen so the snapped and un-snapped
# answers differ on BOTH axes; a fixture that landed on the grid by luck would
# make the whole section vacuous.

const SNAP_GRID_MM := 2.54
## Un-snapped landing point of the drag below (exact pointer delta).
const DRAG_FREE := Vector2(42.125, 27.625)
## Snapped landing point of the SAME drag.
const DRAG_SNAPPED := Vector2(43.18, 27.94)
## The three authoring clicks, as pointed.
const AUTHOR_FREE := [Vector2(10.3, 10.3), Vector2(20.4, 10.3), Vector2(20.4, 20.5)]
## The same three on the quarter grid.
const AUTHOR_SNAPPED := [Vector2(10.16, 10.16), Vector2(20.32, 10.16), Vector2(20.32, 20.32)]


## Hold (or release) the no-snap modifier the way the OS does: through the Input
## singleton, because `_snap_bypass_held()` reads Input.is_key_pressed and not
## the InputEvent. Input.parse_input_event is the supported way to make
## is_key_pressed report a key in a headless run (measured on this scaffold).
##
## ALWAYS released in the same function that pressed it: Input state is
## process-global, so a leaked Ctrl would silently un-snap every later probe.
func _set_ctrl(down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_CTRL
	ev.physical_keycode = KEY_CTRL
	ev.pressed = down
	Input.parse_input_event(ev)
	await process_frame


## Run one press/move/release drag of U1 by `delta_px` and return its SERIALIZED
## position. `ctrl` decides whether the no-snap modifier is held for the motion.
func _drag_u1(canvas, data, delta_px: Vector2, ctrl: bool) -> Vector2:
	canvas._clear_selection()
	canvas._add_to_selection(canvas.KIND_COMPONENT, "U1")
	var g := _global_of(canvas, Vector2(30.0, 20.0))
	_push_button(g, MOUSE_BUTTON_LEFT, true)
	await process_frame
	if ctrl:
		await _set_ctrl(true)
	_push_motion(g + delta_px, MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	_push_button(g + delta_px, MOUSE_BUTTON_LEFT, false)
	await process_frame
	if ctrl:
		await _set_ctrl(false)
	var ser: Variant = _serialized_component(data, "U1")
	if not (ser is Dictionary):
		return Vector2(NAN, NAN)
	return Vector2(float((ser as Dictionary).get("x_mm", NAN)),
			float((ser as Dictionary).get("y_mm", NAN)))


## G1a — the DRAG half. Ctrl held during the motion lands the part exactly at the
## pointer delta; the identical drag without it lands on the placement grid.
func _probe_snap_bypass_drag() -> void:
	_begin_section("G1a snap-bypass drag", 6)
	print("\n-- G1a: Ctrl bypasses the drag-move snap (campaign promise 2) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var data = panel.get_data()
	canvas.zoom = 8.0
	canvas.pan_offset = Vector2.ZERO
	await process_frame

	check("G1a fixture: the canvas is in its snapping default",
			canvas.snap_to_grid,
			"snap_to_grid is off — every assertion below would be vacuous")
	check("G1a fixture: no modifier is stuck down before the gesture",
			not Input.is_key_pressed(KEY_CTRL) and not Input.is_key_pressed(KEY_META))

	var delta_px := Vector2(97, 61)
	var free_landing: Vector2 = await _drag_u1(canvas, data, delta_px, true)
	check("G1a: WITH Ctrl the part lands exactly at the pointer delta (%s)"
			% str(DRAG_FREE),
			free_landing.is_equal_approx(DRAG_FREE), "landed %s" % str(free_landing))
	check("G1a: …and that landing is genuinely OFF the placement grid",
			not is_equal_approx(fposmod(free_landing.x, SNAP_GRID_MM), 0.0)
			and not is_equal_approx(fposmod(free_landing.x, SNAP_GRID_MM), SNAP_GRID_MM),
			"x=%f grid=%f" % [free_landing.x, SNAP_GRID_MM])

	# Put it back and run the IDENTICAL gesture with no modifier.
	data.get_component("U1").position = Vector2(30.0, 20.0)
	await process_frame
	var snapped_landing: Vector2 = await _drag_u1(canvas, data, delta_px, false)
	check("G1a: WITHOUT Ctrl the SAME drag lands snapped (%s)" % str(DRAG_SNAPPED),
			snapped_landing.is_equal_approx(DRAG_SNAPPED),
			"landed %s" % str(snapped_landing))
	check("G1a: the two landings differ on BOTH axes (the modifier does something)",
			not is_equal_approx(free_landing.x, snapped_landing.x)
			and not is_equal_approx(free_landing.y, snapped_landing.y),
			"%s vs %s" % [str(free_landing), str(snapped_landing)])

	panel.queue_free()
	await process_frame


## G1b — the AUTHORING half, through a real tool path (the cutout tool's three
## clicks + closing double-click). Same modifier, different consumer and a
## different (quarter) grid.
##
## This leg is what makes the HALF mutation partial: restoring the snap inside
## `_author_point` while leaving the drag-move bypass alone reds G1b and leaves
## G1a green.
func _probe_snap_bypass_authoring() -> void:
	_begin_section("G1b snap-bypass authoring", 6)
	print("\n-- G1b: Ctrl bypasses the AUTHORING snap too (one rule, two consumers) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var data = panel.get_data()
	await process_frame

	check("G1b fixture: the canvas is in its snapping default", canvas.snap_to_grid)

	# --- no modifier: the quarter grid.
	canvas.set_tool_mode(canvas.ToolMode.CUTOUT)
	for p in AUTHOR_FREE:
		canvas._handle_cutout_click(p, false)
	canvas._handle_cutout_click(AUTHOR_FREE[2], true)
	var snapped_outline: Array = _first_cutout_outline(data)
	check("G1b fixture: the un-modified draw committed a 3-point cutout",
			snapped_outline.size() == 3, str(snapped_outline))
	check("G1b: WITHOUT Ctrl every authored point sits on the quarter grid (%s)"
			% str(AUTHOR_SNAPPED),
			_outline_matches(snapped_outline, AUTHOR_SNAPPED), str(snapped_outline))

	# --- same three clicks, Ctrl held.
	data.cutouts.clear()
	await _set_ctrl(true)
	canvas.set_tool_mode(canvas.ToolMode.CUTOUT)
	for p in AUTHOR_FREE:
		canvas._handle_cutout_click(p, false)
	canvas._handle_cutout_click(AUTHOR_FREE[2], true)
	await _set_ctrl(false)
	var free_outline: Array = _first_cutout_outline(data)
	check("G1b fixture: the Ctrl draw committed a 3-point cutout too",
			free_outline.size() == 3, str(free_outline))
	check("G1b: WITH Ctrl every authored point stands exactly where it was clicked (%s)"
			% str(AUTHOR_FREE),
			_outline_matches(free_outline, AUTHOR_FREE), str(free_outline))
	check("G1b: the two outlines really differ (the modifier does something)",
			not _outline_matches(free_outline, AUTHOR_SNAPPED),
			"%s == the snapped list" % str(free_outline))

	panel.queue_free()
	await process_frame


## The first cutout's SERIALIZED outline, as [{x_mm, y_mm}, …].
func _first_cutout_outline(data) -> Array:
	var board: Dictionary = data.to_board_dict()
	var cuts: Array = board.get("cutouts", [])
	if cuts.is_empty() or not (cuts[0] is Dictionary):
		return []
	return (cuts[0] as Dictionary).get("outline", [])


## Serialized outline vs a hand-written point list.
func _outline_matches(outline: Array, expected: Array) -> bool:
	if outline.size() != expected.size():
		return false
	for i in range(expected.size()):
		if not (outline[i] is Dictionary):
			return false
		var d: Dictionary = outline[i]
		var got := Vector2(float(d.get("x_mm", NAN)), float(d.get("y_mm", NAN)))
		if not got.is_equal_approx(expected[i]):
			return false
	return true


# ── D1-2. SECTION REGISTRY WITH PER-SECTION ASSERTION FLOORS ─────────────────
#
# Ported from test_pcb_panel_model.gd:894-906, with the addition the D1
# oracle-integrity review asked for: a plain registry only catches a section
# that produced ZERO assertions, and the failure this file actually had
# (BT-55's third leg, a `data.grid_mm` runtime error) aborted a probe PARTWAY —
# the section still produced assertions, so a plain registry would have shrugged.
#
# Each section therefore declares the number of assertions it was authored with
# and the guard asserts a FLOOR (>=), not equality: adding an assertion is free,
# LOSING one — which is what a mid-`await` script error looks like — is red.
# When you deliberately remove an assertion, lower the floor in the same commit.
var _section_marks: Array = []


func _begin_section(label: String, expected: int) -> void:
	_section_marks.append({"label": label, "at": _pass + _fail, "expect": expected})


## Called LAST, from _init, so an abort inside any one probe cannot skip it.
func _assert_sections_met_their_floors() -> void:
	print("\n-- section registry: every probe produced the assertions it declares --")
	var short: Array = []
	for i in range(_section_marks.size()):
		var mark: Dictionary = _section_marks[i]
		var next_at: int = int(_section_marks[i + 1]["at"]) if i + 1 < _section_marks.size() \
				else _pass + _fail
		var produced: int = next_at - int(mark["at"])
		print("     %-44s produced %3d (floor %3d)" % [str(mark["label"]), produced,
				int(mark["expect"])])
		if produced < int(mark["expect"]):
			short.append("%s produced %d, floor %d" % [str(mark["label"]), produced,
					int(mark["expect"])])
	check("no probe fell below its assertion floor (%s)" % str(short), short.is_empty())
	check("every registered probe declared itself (%d)" % _section_marks.size(),
			_section_marks.size() == _EXPECTED_SECTIONS)


const _EXPECTED_SECTIONS := 23
