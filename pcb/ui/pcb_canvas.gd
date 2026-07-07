extends Control
## Renders and edits the PCB board — components, traces, vias, ratsnest, grid.
##
## ── Off-tree port note (Round B) ──────────────────────────────────────────────
## Ported from Minerva src/Scripts/UI/Controls/PCBEditor/PCBCanvas.gd (3013 lines)
## for the pcb plugin panel. This plugin lives OUTSIDE Minerva's res:// tree, so:
##   * NO class_name (plugin-local class_names are unresolvable off-tree and
##     corrupt the parser cache).
##   * Siblings reached via relative preload(); cross-file object refs (data,
##     components, traces) are DUCK-TYPED (never typed as a plugin script — that
##     crosses files and breaks the cache; and untyped vars keep := inference
##     working only when the RHS type is annotatable, so primitives stay typed).
##
## ── STRIPPED vs legacy ────────────────────────────────────────────────────────
## ALL annotation + route-hint authoring/drawing/picking is removed: the platform
## annotation dock (mounted via PCBPanel.get_annotation_host()) owns that story
## now. Gone: AnnotationMode/RouteHintMode/BusPhase enums + state, _draw_annotation*,
## _draw_route_hint*, _draw_*_preview, _handle_annotation_click, _handle_route_hint_click,
## pin-picking (_get_pin_at_position), the A/T/R/H/M/W/P/Shift+P shortcuts, the
## annotation/route-hint context-menu items, capture_to_image (MCP export lives in
## the worker), and the spatial index (unused by interactive editing).
##
## ── KEPT (board editing) ──────────────────────────────────────────────────────
## Component select / box-select / drag / rotate, trace + via rendering, trace
## selection + delete, ratsnest, grid, pad geometry rendering, component lock,
## zoom / pan, tool modes (Select/Translate/Rotate), a per-copper-layer trace
## filter (the toolbar's layer selector drives trace_layer_filter).

const PCBComponentScript := preload("model/pcb_component.gd")

## Signals
signal component_selected(component_id: String)
signal component_deselected(component_id: String)
signal component_moved(component_id: String, new_position: Vector2)
signal component_double_clicked(component_id: String)
@warning_ignore("unused_signal")
signal canvas_clicked(world_position: Vector2)
signal zoom_changed(new_zoom: float)
signal selection_changed()
signal component_lock_changed(message: String)
## Emitted whenever the board-mm↔screen mapping moves (pan, zoom, fit, center).
## PcbAnnotationHost relays this to its base view_changed so the annotation
## overlay re-renders route-hint markers at the new screen positions (gap W-9).
signal view_changed()

## Data reference (pcb_data.gd instance — duck-typed).
var data = null

## View state
var zoom: float = 4.0  # Pixels per mm (4 = 1mm = 4px)
var pan_offset: Vector2 = Vector2.ZERO
var min_zoom: float = 0.5
var max_zoom: float = 50.0

## Display options
var show_grid: bool = true
var show_ratsnest: bool = true
var show_traces: bool = true
var show_labels: bool = true
var show_pins: bool = true
var snap_to_grid: bool = true
var show_pads: bool = true
## Draws F.SilkS graphics resolved by the worker's footprint-RESOLVE step
## (component.graphics — see pcb_component.gd). Courtyard (F.CrtYd) stays off.
var show_silk: bool = true

## Copper-layer trace filter driven by the toolbar layer selector.
## "all" → both layers; "top" → non-bottom traces; "bottom" → bottom traces.
var trace_layer_filter: String = "all"

## Selection state
var selected_components: Array[String] = []
var hovered_component: String = ""

## Interaction state
var is_panning: bool = false
var pan_start_mouse: Vector2 = Vector2.ZERO
var pan_start_offset: Vector2 = Vector2.ZERO

var is_dragging_component: bool = false
var drag_component_id: String = ""
var drag_start_mouse: Vector2 = Vector2.ZERO
var drag_start_component_pos: Vector2 = Vector2.ZERO

var is_box_selecting: bool = false
var box_select_start: Vector2 = Vector2.ZERO
var box_select_end: Vector2 = Vector2.ZERO

## Space-drag pan (Photoshop / GraphicsEditor style): while Space is held, a
## left-drag pans the whole view instead of selecting.
var _space_pan_armed: bool = false

## General tool mode. SELECT is the single smart tool (click selects, drag a
## part moves it snap-aware, drag empty space box-selects, R rotates the
## selection); PAN drags the whole view. TRANSLATE/ROTATE are kept for
## back-compat with the tool_mode_changed contract but are no longer distinct
## toolbar tools — the smart SELECT tool subsumes both (finding 5).
enum ToolMode { NONE, SELECT, TRANSLATE, ROTATE, PAN }
var tool_mode: ToolMode = ToolMode.NONE
signal tool_mode_changed(mode: ToolMode)

## Trace selection state
var selected_trace_id: String = ""

## Colors
var board_color: Color = Color(0.15, 0.25, 0.15, 1.0)
var board_edge_color: Color = Color(0.4, 0.4, 0.4, 1.0)
var grid_color: Color = Color(0.25, 0.35, 0.25, 0.5)
var grid_major_color: Color = Color(0.3, 0.4, 0.3, 0.7)
var component_color: Color = Color(0.2, 0.6, 0.3, 1.0)
var component_selected_color: Color = Color(0.3, 0.8, 0.4, 1.0)
var component_hover_color: Color = Color(0.25, 0.7, 0.35, 1.0)
var pin_color: Color = Color(0.9, 0.75, 0.3, 1.0)
var label_color: Color = Color.WHITE
var trace_top_color: Color = Color(0.9, 0.3, 0.3, 1.0)   # Red for top layer (F.Cu)
var trace_bottom_color: Color = Color(0.3, 0.5, 0.9, 1.0) # Blue for bottom layer (B.Cu)
var trace_selected_color: Color = Color(1.0, 1.0, 0.3, 1.0)
var selection_box_color: Color = Color(0.3, 0.5, 0.8, 0.3)
var selection_border_color: Color = Color(0.4, 0.6, 0.9, 1.0)

## Pad colors (copper/solder appearance)
var pad_copper_color: Color = Color(0.85, 0.65, 0.3, 1.0)  # Copper/gold for THT
var pad_smd_color: Color = Color(0.75, 0.55, 0.25, 1.0)    # SMD pads
var drill_hole_color: Color = Color(0.08, 0.08, 0.08, 1.0) # Drill holes (match background)
var mounting_hole_color: Color = Color(0.2, 0.2, 0.2, 1.0) # Non-plated holes

## Silkscreen (F.SilkS) stroke color — light/white, matching real silk ink.
var silk_color: Color = Color(0.9, 0.9, 0.9, 1.0)
var silk_min_width_px: float = 1.0

## Font
var font: Font
var font_size: int = 12

## Context menu (component lock/unlock only — annotation/route-hint items stripped)
var context_menu: PopupMenu = null
var context_menu_world_pos: Vector2 = Vector2.ZERO
var right_click_start_pos: Vector2 = Vector2.ZERO
const RIGHT_CLICK_THRESHOLD := 5.0  # Pixels — below this a right-click is a tap → context menu


func _enter_tree() -> void:
	# Input config MUST be re-applied on every tree entry, not just once in
	# _ready. The editor reparents this panel into the annotation content row
	# AFTER mount (Editor._ensure_annotation_content_row); a reparent fires
	# _exit_tree then _enter_tree but NOT _ready. If mouse_filter is only set in
	# _ready it is left on IGNORE after the reparent and the canvas silently
	# swallows every mouse+keyboard event (draws fine, but zoom/pan/select all
	# dead — bug 019f39164c2e; the toolbar survives because Buttons don't
	# self-clear their filter on exit). Setting it here makes it reparent-safe.
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	clip_contents = true


func _ready() -> void:
	font = ThemeDB.fallback_font
	font_size = ThemeDB.fallback_font_size

	_create_context_menu()


func _exit_tree() -> void:
	if has_focus():
		release_focus()
	# NOTE: do NOT set mouse_filter = IGNORE here. This node is reparented (not
	# just freed) when the annotation dock mounts; leaving it IGNORE would make
	# the re-added canvas ignore all input. _enter_tree restores STOP on re-add.
	is_panning = false
	is_dragging_component = false
	is_box_selecting = false


## Create the right-click context menu (component lock/unlock).
func _create_context_menu() -> void:
	context_menu = PopupMenu.new()
	context_menu.name = "ContextMenu"
	add_child(context_menu)
	context_menu.id_pressed.connect(_on_context_menu_pressed)


## Rebuild the dynamic (lock) items of the context menu for the current cursor.
func _update_context_menu_for_selection() -> void:
	context_menu.clear()

	var has_lock_section := false
	var comp_under_cursor: String = data.get_component_at(context_menu_world_pos)
	if not comp_under_cursor.is_empty() or not selected_components.is_empty():
		has_lock_section = true
		if not comp_under_cursor.is_empty():
			context_menu.add_item("Lock %s (L)" % comp_under_cursor, 401)
		else:
			context_menu.add_item("Lock Component (L)", 401)

	var locked_under_cursor := _get_locked_component_at(context_menu_world_pos)
	if not locked_under_cursor.is_empty():
		has_lock_section = true
		context_menu.add_item("Unlock %s" % locked_under_cursor, 402)

	if _has_any_locked_components():
		context_menu.add_item("Unlock All Components (Shift+L)", 404)

	if not has_lock_section and context_menu.item_count == 0:
		context_menu.add_item("(no actions)", 0)
		context_menu.set_item_disabled(context_menu.item_count - 1, true)


func _on_context_menu_pressed(id: int) -> void:
	if not data:
		return
	match id:
		401:  # Lock component(s) — selected ones, or the one under cursor
			if not selected_components.is_empty():
				_lock_selected_components()
			else:
				var cursor_comp_id: String = data.get_component_at(context_menu_world_pos)
				if not cursor_comp_id.is_empty():
					var cursor_comp = data.get_component(cursor_comp_id)
					if cursor_comp:
						cursor_comp.locked = true
						component_lock_changed.emit("Locked %s" % cursor_comp_id)
						queue_redraw()
		402:  # Unlock the locked component under cursor
			var comp_id := _get_locked_component_at(context_menu_world_pos)
			if not comp_id.is_empty():
				var comp = data.get_component(comp_id)
				if comp:
					comp.locked = false
					component_lock_changed.emit("Unlocked %s" % comp_id)
					queue_redraw()
		404:  # Unlock all components
			_unlock_all_components()


func _show_context_menu(screen_pos: Vector2) -> void:
	if not context_menu:
		return
	_update_context_menu_for_selection()
	var global_pos := get_global_transform() * screen_pos
	context_menu.position = Vector2i(global_pos)
	context_menu.popup()


func _draw() -> void:
	if not data:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.1, 0.1, 0.1))
		return

	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.08, 0.08))

	_draw_board()

	if show_grid:
		_draw_grid()

	_draw_components()

	_draw_mounting_holes()

	if show_traces:
		_draw_traces()

	if show_ratsnest:
		_draw_ratsnest()

	if is_box_selecting:
		_draw_selection_box()


## Draw the PCB board outline
func _draw_board() -> void:
	var board_rect := Rect2(
		world_to_screen(Vector2.ZERO),
		Vector2(data.board_width, data.board_height) * zoom
	)
	draw_rect(board_rect, board_color)
	draw_rect(board_rect, board_edge_color, false, 2.0)


## Draw the alignment grid
func _draw_grid() -> void:
	var board_start := world_to_screen(Vector2.ZERO)
	var board_end := world_to_screen(Vector2(data.board_width, data.board_height))

	var grid_step: float = data.grid_size * zoom
	var major_interval := 10

	if grid_step < 3:
		return

	var start_x := board_start.x
	var end_x := board_end.x
	var start_y := board_start.y
	var end_y := board_end.y

	var x := start_x
	var line_count := 0
	while x <= end_x:
		var color := grid_major_color if line_count % major_interval == 0 else grid_color
		draw_line(Vector2(x, start_y), Vector2(x, end_y), color, 1.0)
		x += grid_step
		line_count += 1

	var y := start_y
	line_count = 0
	while y <= end_y:
		var color := grid_major_color if line_count % major_interval == 0 else grid_color
		draw_line(Vector2(start_x, y), Vector2(end_x, y), color, 1.0)
		y += grid_step
		line_count += 1


## Is a trace on `layer` visible under the current layer filter?
func _layer_visible(layer: String) -> bool:
	match trace_layer_filter:
		"top":
			return layer != "bottom"
		"bottom":
			return layer == "bottom"
		_:
			return true


## Draw all traces (bottom layer first, then top, then vias), honoring the filter.
func _draw_traces() -> void:
	for trace_id in data.traces:
		var trace = data.traces[trace_id]
		if trace.layer != "bottom":
			continue
		if not _layer_visible("bottom"):
			continue
		_draw_single_trace(trace, true)

	for trace_id in data.traces:
		var trace = data.traces[trace_id]
		if trace.layer == "bottom":
			continue
		if not _layer_visible(trace.layer):
			continue
		_draw_single_trace(trace, false)

	# Vias (on top of all traces).
	for via in data.vias:
		var pos_data = via.get("position", Vector2.ZERO)
		var pos: Vector2
		if pos_data is Vector2:
			pos = world_to_screen(pos_data)
		elif pos_data is Dictionary:
			pos = world_to_screen(Vector2(pos_data.get("x", 0), pos_data.get("y", 0)))
		else:
			continue

		var outer_radius: float = (via.get("size", 0.8) / 2.0) * zoom
		var inner_radius: float = (via.get("drill", 0.4) / 2.0) * zoom

		var color := pad_copper_color
		var net = data.get_net(via.get("net_name", ""))
		if net:
			color = net.color

		draw_circle(pos, maxf(outer_radius, 2.0), color)
		draw_circle(pos, maxf(inner_radius, 1.0), drill_hole_color)


## Draw a single trace with layer-appropriate styling
func _draw_single_trace(trace, is_bottom_layer: bool) -> void:
	if trace.waypoints.size() < 2:
		return

	var color := trace_bottom_color if is_bottom_layer else trace_top_color
	var is_selected: bool = (trace.id == selected_trace_id) and not selected_trace_id.is_empty()

	if is_selected:
		color = trace_selected_color

	var points: PackedVector2Array = []
	for wp in trace.waypoints:
		points.append(world_to_screen(wp))

	if points.size() >= 2:
		var trace_width = trace.width * zoom

		if is_selected:
			var glow_color := Color(trace_selected_color, 0.25)
			draw_polyline(points, glow_color, maxf(trace_width + 6.0, 4.0))

		draw_polyline(points, color, maxf(trace_width, 1.0))

		if is_selected:
			for pt in points:
				draw_circle(pt, 3.0, trace_selected_color)


## Draw ratsnest (unrouted net connections)
func _draw_ratsnest() -> void:
	for net_name in data.nets:
		var net = data.nets[net_name]
		if net.pins.size() < 2:
			continue

		var pin_data: Array = []
		for pin in net.pins:
			var comp_id: String = pin.get("component_id", "")
			var pin_name: String = pin.get("pin_name", "")
			var comp = data.get_component(comp_id)
			if comp:
				pin_data.append({
					"pos": comp.get_pin_world_position(pin_name),
					"comp_id": comp_id,
					"pin_name": pin_name
				})

		if pin_data.size() >= 2:
			var net_color = net.color
			net_color.a = 0.6

			for i in range(pin_data.size() - 1):
				var p1 := world_to_screen(pin_data[i]["pos"])
				var p2 := world_to_screen(pin_data[i + 1]["pos"])
				_draw_dashed_line(p1, p2, net_color, 1.5, 5.0)
				draw_circle(p1, 3.0, net_color)
				draw_circle(p2, 3.0, net_color)


## Draw all components
func _draw_components() -> void:
	for comp_id in data.components:
		var comp = data.components[comp_id]
		_draw_component(comp)


## Draw board-level mounting holes (structural — not components, not vias).
## Mirrors the via draw loop in _draw_traces(): resolves position (Vector2 or
## {x,y} dict), draws an outer rim in mounting_hole_color and an inner drill
## circle so it reads as a hole.
func _draw_mounting_holes() -> void:
	for hole in data.mounting_holes:
		var pos_data = hole.get("position", Vector2.ZERO)
		var pos: Vector2
		if pos_data is Vector2:
			pos = world_to_screen(pos_data)
		elif pos_data is Dictionary:
			pos = world_to_screen(Vector2(pos_data.get("x", 0), pos_data.get("y", 0)))
		else:
			continue

		var outer_radius: float = (hole.get("diameter", 3.2) / 2.0) * zoom
		var inner_radius: float = outer_radius * 0.8

		draw_circle(pos, maxf(outer_radius, 2.0), mounting_hole_color)
		draw_circle(pos, maxf(inner_radius, 1.0), drill_hole_color)


## Draw a single component using rigid body transform
func _draw_component(comp) -> void:
	var color: Color = comp.color
	if comp.id in selected_components:
		color = component_selected_color
	elif comp.id == hovered_component:
		color = component_hover_color

	if comp.locked:
		color.a = 0.4

	var xform: Transform2D = comp.get_transform()

	var local_poly: PackedVector2Array = comp.get_local_body_polygon()
	var screen_poly: PackedVector2Array = []
	for point in local_poly:
		var world_point: Vector2 = comp.position + (xform * point)
		screen_poly.append(world_to_screen(world_point))

	draw_colored_polygon(screen_poly, color)

	var outline_points: PackedVector2Array = screen_poly.duplicate()
	outline_points.append(screen_poly[0])
	draw_polyline(outline_points, color.darkened(0.3), 1.0)

	if comp.locked:
		_draw_locked_hatch(screen_poly)

	if show_silk and comp.graphics.size() > 0:
		_draw_component_silk(comp, xform)

	if show_pads and comp.has_pad_geometry and comp.pads.size() > 0:
		_draw_component_pads(comp, xform)
	elif show_pins:
		_draw_fallback_pins(comp, xform)

	if show_labels and comp.label_visible:
		var local_center: Vector2 = comp.local_bounds.get_center()
		var world_center: Vector2 = comp.position + (xform * local_center)
		var screen_center := world_to_screen(world_center)
		var label_pos := screen_center - Vector2(0, comp.height * zoom / 2 + 10)
		draw_string(font, label_pos, comp.id, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, label_color)


## Draw diagonal hatch lines over a locked component's screen polygon
func _draw_locked_hatch(screen_poly: PackedVector2Array) -> void:
	if screen_poly.size() < 3:
		return

	var min_pt := screen_poly[0]
	var max_pt := screen_poly[0]
	for pt in screen_poly:
		min_pt.x = minf(min_pt.x, pt.x)
		min_pt.y = minf(min_pt.y, pt.y)
		max_pt.x = maxf(max_pt.x, pt.x)
		max_pt.y = maxf(max_pt.y, pt.y)

	var hatch_color := Color(0.9, 0.4, 0.1, 0.35)
	var spacing := 8.0
	var diag := max_pt - min_pt
	var total := diag.x + diag.y

	var d := 0.0
	while d < total:
		var x0 := min_pt.x + d
		var y0 := min_pt.y
		var x1 := min_pt.x
		var y1 := min_pt.y + d

		if x0 > max_pt.x:
			y0 += x0 - max_pt.x
			x0 = max_pt.x
		if y1 > max_pt.y:
			x1 += y1 - max_pt.y
			y1 = max_pt.y

		if x0 >= min_pt.x and y0 <= max_pt.y and x1 <= max_pt.x and y1 >= min_pt.y:
			draw_line(Vector2(x0, y0), Vector2(x1, y1), hatch_color, 1.0)
		d += spacing


## Draw pads with accurate geometry from KiCAD footprint
func _draw_component_pads(comp, xform: Transform2D) -> void:
	var pad_rot: float = -comp.rotation

	for pad in comp.pads:
		var pad_type: String = pad.get("type", "smd")
		var pad_shape: String = pad.get("shape", "rect")
		var local_pos: Vector2 = pad.get("position", Vector2.ZERO)
		var pad_size: Vector2 = pad.get("size", Vector2(1, 1))

		var is_tht := pad_type in ["thru_hole", "np_thru_hole"]

		var world_pos: Vector2 = comp.position + (xform * local_pos)
		var screen_pos := world_to_screen(world_pos)
		var screen_size := pad_size * zoom

		var draw_color := pad_copper_color
		if pad_type == "smd":
			draw_color = pad_smd_color
		elif pad_type == "np_thru_hole":
			draw_color = mounting_hole_color

		match pad_shape:
			"rect":
				_draw_rect_pad(screen_pos, screen_size, pad_rot, draw_color)
			"circle":
				_draw_circle_pad(screen_pos, screen_size, draw_color)
			"oval":
				_draw_oval_pad(screen_pos, screen_size, pad_rot, draw_color)
			"roundrect":
				_draw_roundrect_pad(screen_pos, screen_size, pad_rot, draw_color)
			_:
				_draw_rect_pad(screen_pos, screen_size, pad_rot, draw_color)

		if is_tht:
			var drill_val = pad.get("drill", Vector2.ZERO)
			var drill_diameter: float = 0.0
			if drill_val is Vector2:
				drill_diameter = maxf(drill_val.x, drill_val.y)
			elif drill_val is float or drill_val is int:
				drill_diameter = float(drill_val)

			if drill_diameter <= 0.0:
				drill_diameter = minf(pad_size.x, pad_size.y)

			if drill_diameter > 0.0:
				var drill_radius := (drill_diameter * zoom) / 2.0
				draw_circle(screen_pos, maxf(drill_radius, 1.0), drill_hole_color)
				draw_arc(screen_pos, maxf(drill_radius, 1.0), 0, TAU, 16, Color(0.4, 0.4, 0.4, 0.6), 1.0)


## Draw F.SilkS graphics (component body outline, markings, etc.) attached by
## the worker's footprint-RESOLVE step (component.graphics, LOCAL mm coords).
## Transform convention MUST match _draw_component_pads EXACTLY — same `xform`
## (comp.get_transform(), KiCAD CW rotation) and the same
## `comp.position + (xform * local_point)` composition — so silk aligns with
## the copper it was resolved against. F.CrtYd (courtyard) is intentionally
## skipped; silk is the goal for this round.
func _draw_component_silk(comp, xform: Transform2D) -> void:
	for g in comp.graphics:
		if g.get("layer", "") != "F.SilkS":
			continue

		var kind: String = g.get("kind", "")
		var w: float = maxf(float(g.get("width", 0.15)) * zoom, silk_min_width_px)

		match kind:
			"line":
				var start: Vector2 = g.get("start", Vector2.ZERO)
				var end: Vector2 = g.get("end", Vector2.ZERO)
				var p0 := world_to_screen(comp.position + (xform * start))
				var p1 := world_to_screen(comp.position + (xform * end))
				draw_line(p0, p1, silk_color, w)

			"circle":
				var center: Vector2 = g.get("center", Vector2.ZERO)
				var radius: float = float(g.get("radius", 0.0))
				var center_screen := world_to_screen(comp.position + (xform * center))
				var radius_screen := radius * zoom
				if radius_screen > 0.0:
					draw_arc(center_screen, radius_screen, 0, TAU, 32, silk_color, w)

			"poly":
				var poly_points: PackedVector2Array = []
				for pt in g.get("points", []):
					var local_pt: Vector2 = pt
					poly_points.append(world_to_screen(comp.position + (xform * local_pt)))
				if poly_points.size() >= 2:
					draw_polyline(poly_points, silk_color, w)

			"arc":
				# The graphic carries 2-3 LOCAL points (start[,mid],end). A true
				# arc reconstruction from those is awkward in screen space (the
				# rotation/rounding makes center+angle derivation fiddly); a
				# polyline through the transformed points is an acceptable
				# stand-in per the round's brief — visually indistinguishable
				# for the small radii silk arcs typically use (pin-1 dots,
				# rounded corners).
				var arc_points: PackedVector2Array = []
				for pt in g.get("points", []):
					var local_pt: Vector2 = pt
					arc_points.append(world_to_screen(comp.position + (xform * local_pt)))
				if arc_points.size() >= 2:
					draw_polyline(arc_points, silk_color, w)


## Fallback pin rendering when pad geometry not available.
func _draw_fallback_pins(comp, xform: Transform2D) -> void:
	var is_mounting_hole: bool = comp.footprint == PCBComponentScript.FootprintType.MOUNTING_HOLE
	var is_tht_footprint: bool = comp.footprint in [
		PCBComponentScript.FootprintType.IC_DIP,
		PCBComponentScript.FootprintType.HEADER,
		PCBComponentScript.FootprintType.CONNECTOR,
		PCBComponentScript.FootprintType.MODULE,
	]
	var is_likely_tht: bool = comp.footprint in [
		PCBComponentScript.FootprintType.RESISTOR,
		PCBComponentScript.FootprintType.CAPACITOR,
		PCBComponentScript.FootprintType.DIODE,
		PCBComponentScript.FootprintType.LED,
		PCBComponentScript.FootprintType.TRANSISTOR,
		PCBComponentScript.FootprintType.SWITCH,
		PCBComponentScript.FootprintType.CRYSTAL,
	]

	if is_mounting_hole:
		var hole_diameter: float = comp.width
		var hole_radius: float = (hole_diameter * zoom) / 2.0

		for pin_name in comp.pins:
			var local_pin_pos: Vector2 = comp.pins[pin_name]
			var world_pin_pos: Vector2 = comp.position + (xform * local_pin_pos)
			var pin_screen := world_to_screen(world_pin_pos)

			var annulus_radius: float = hole_radius + (0.5 * zoom)
			draw_circle(pin_screen, maxf(annulus_radius, 2.0), mounting_hole_color)
			draw_circle(pin_screen, maxf(hole_radius, 1.5), drill_hole_color)
			draw_arc(pin_screen, maxf(hole_radius, 1.5), 0, TAU, 24, Color(0.5, 0.5, 0.5, 0.8), 1.5)

	elif is_tht_footprint or is_likely_tht:
		var pad_diameter := 1.7
		var drill_diameter := 1.0
		var pad_radius := (pad_diameter * zoom) / 2.0
		var drill_radius := (drill_diameter * zoom) / 2.0

		for pin_name in comp.pins:
			var local_pin_pos: Vector2 = comp.pins[pin_name]
			var world_pin_pos: Vector2 = comp.position + (xform * local_pin_pos)
			var pin_screen := world_to_screen(world_pin_pos)

			if pin_name == "1":
				var pad_size := Vector2(pad_diameter, pad_diameter) * zoom
				_draw_rect_pad(pin_screen, pad_size, -comp.rotation, pad_copper_color)
			else:
				draw_circle(pin_screen, maxf(pad_radius, 2.0), pad_copper_color)

			draw_circle(pin_screen, maxf(drill_radius, 1.0), drill_hole_color)
			draw_arc(pin_screen, maxf(drill_radius, 1.0), 0, TAU, 16, Color(0.4, 0.4, 0.4, 0.6), 1.0)

	else:
		var pad_size := 1.0
		var pad_radius := (pad_size * zoom) / 2.0

		for pin_name in comp.pins:
			var local_pin_pos: Vector2 = comp.pins[pin_name]
			var world_pin_pos: Vector2 = comp.position + (xform * local_pin_pos)
			var pin_screen := world_to_screen(world_pin_pos)
			draw_circle(pin_screen, maxf(pad_radius, 2.0), pad_smd_color)


## Draw rectangular pad (sharp corners)
func _draw_rect_pad(center: Vector2, pad_size: Vector2, pad_rotation: float, color: Color) -> void:
	var rect_points := _get_rotated_rect_points(center, pad_size, pad_rotation)
	draw_colored_polygon(rect_points, color)


## Draw circular pad
func _draw_circle_pad(center: Vector2, pad_size: Vector2, color: Color) -> void:
	var radius := maxf(pad_size.x, pad_size.y) / 2.0
	draw_circle(center, maxf(radius, 1.0), color)


## Draw oval pad (elongated circle)
func _draw_oval_pad(center: Vector2, pad_size: Vector2, pad_rotation: float, color: Color) -> void:
	var rot_rad := deg_to_rad(pad_rotation)

	if pad_size.x > pad_size.y:
		var radius := pad_size.y / 2.0
		var half_length := (pad_size.x - pad_size.y) / 2.0

		var rect_size := Vector2(half_length * 2, pad_size.y)
		var rect_points := _get_rotated_rect_points(center, rect_size, pad_rotation)
		draw_colored_polygon(rect_points, color)

		var offset := Vector2(half_length, 0).rotated(rot_rad)
		draw_circle(center - offset, maxf(radius, 1.0), color)
		draw_circle(center + offset, maxf(radius, 1.0), color)
	else:
		var radius := pad_size.x / 2.0
		var half_length := (pad_size.y - pad_size.x) / 2.0

		var rect_size := Vector2(pad_size.x, half_length * 2)
		var rect_points := _get_rotated_rect_points(center, rect_size, pad_rotation)
		draw_colored_polygon(rect_points, color)

		var offset := Vector2(0, half_length).rotated(rot_rad)
		draw_circle(center - offset, maxf(radius, 1.0), color)
		draw_circle(center + offset, maxf(radius, 1.0), color)


## Draw rounded rectangle pad (rectangle approximation)
func _draw_roundrect_pad(center: Vector2, pad_size: Vector2, pad_rotation: float, color: Color) -> void:
	var rect_points := _get_rotated_rect_points(center, pad_size, pad_rotation)
	draw_colored_polygon(rect_points, color)


## Get rotated rectangle points
func _get_rotated_rect_points(center: Vector2, rect_size: Vector2, rect_rotation: float) -> PackedVector2Array:
	var half_size := rect_size / 2.0
	var corners := [
		Vector2(-half_size.x, -half_size.y),
		Vector2(half_size.x, -half_size.y),
		Vector2(half_size.x, half_size.y),
		Vector2(-half_size.x, half_size.y)
	]

	var rot_rad := deg_to_rad(rect_rotation)
	var result: PackedVector2Array = []
	for corner in corners:
		result.append(center + corner.rotated(rot_rad))
	return result


## Draw selection box
func _draw_selection_box() -> void:
	var rect := Rect2(
		box_select_start.min(box_select_end),
		(box_select_end - box_select_start).abs()
	)
	draw_rect(rect, selection_box_color)
	draw_rect(rect, selection_border_color, false, 1.0)


## Draw a dashed line
func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, width: float, dash_length: float) -> void:
	var direction := (to - from).normalized()
	var distance := from.distance_to(to)
	var current := 0.0
	var drawing := true

	while current < distance:
		var segment_end := minf(current + dash_length, distance)
		if drawing:
			draw_line(
				from + direction * current,
				from + direction * segment_end,
				color,
				width
			)
		drawing = not drawing
		current = segment_end


#region Coordinate Transformation

## Convert world position (mm) to screen position (pixels)
func world_to_screen(world_pos: Vector2) -> Vector2:
	return (world_pos * zoom) + pan_offset + size / 2

## Convert screen position (pixels) to world position (mm)
func screen_to_world(screen_pos: Vector2) -> Vector2:
	return (screen_pos - pan_offset - size / 2) / zoom

#endregion


#region Input Handling

func _gui_input(event: InputEvent) -> void:
	if not is_inside_tree() or not data:
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventKey:
		_handle_key_input(event)
	elif event is InputEventPanGesture:
		_handle_pan_gesture(event)
	elif event is InputEventMagnifyGesture:
		_handle_magnify_gesture(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	var world_pos := screen_to_world(event.position)

	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			grab_focus()

			# Pan tool OR Space-drag: a left-drag pans the whole board view.
			# (Discoverability for finding 2 — a visible Pan tool + the familiar
			# Space+drag, alongside the existing right/middle-drag pan.)
			if tool_mode == ToolMode.PAN or _space_pan_armed:
				is_panning = true
				pan_start_mouse = event.position
				pan_start_offset = pan_offset
				return

			# Smart SELECT tool (the resting tool): click selects; click-drag on
			# a component moves it (snap-aware); click-drag on empty space
			# box-selects. One tool does select + move + box-select; R rotates.
			var hit_component: String = data.get_component_at(world_pos)

			if event.double_click and not hit_component.is_empty():
				component_double_clicked.emit(hit_component)
			elif not hit_component.is_empty():
				if event.shift_pressed:
					if hit_component not in selected_components:
						selected_components.append(hit_component)
						component_selected.emit(hit_component)
				elif hit_component not in selected_components:
					_clear_selection()
					selected_components.append(hit_component)
					component_selected.emit(hit_component)

				is_dragging_component = true
				drag_component_id = hit_component
				drag_start_mouse = event.position
				var comp = data.get_component(hit_component)
				if comp:
					drag_start_component_pos = comp.position
			else:
				# No component under cursor. Try a trace hit (so traces stay
				# selectable/deletable); otherwise begin a box-select.
				var hit_trace_id: String = data.get_trace_at(world_pos, 3.0 / zoom)
				if not hit_trace_id.is_empty():
					if not event.shift_pressed:
						_clear_selection()
					selected_trace_id = hit_trace_id
				else:
					if not event.shift_pressed:
						_clear_selection()
					selected_trace_id = ""
					is_box_selecting = true
					box_select_start = event.position
					box_select_end = event.position

			selection_changed.emit()
			queue_redraw()
		else:
			# Release a left-drag pan (Pan tool / Space-drag).
			if is_panning:
				is_panning = false
			if is_dragging_component:
				is_dragging_component = false
				if drag_component_id:
					var comp = data.get_component(drag_component_id)
					if comp and comp.position != drag_start_component_pos:
						data.save_to_history("Move " + drag_component_id)
						data.record_change("move_component", {
							"component_id": drag_component_id,
							"old_position": {"x": drag_start_component_pos.x, "y": drag_start_component_pos.y},
							"new_position": {"x": comp.position.x, "y": comp.position.y}
						})
						component_moved.emit(drag_component_id, comp.position)
				drag_component_id = ""

			if is_box_selecting:
				is_box_selecting = false
				_finalize_box_selection()

			queue_redraw()

	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			is_panning = true
			pan_start_mouse = event.position
			pan_start_offset = pan_offset
			right_click_start_pos = event.position
			context_menu_world_pos = world_pos
		else:
			is_panning = false
			if event.position.distance_to(right_click_start_pos) < RIGHT_CLICK_THRESHOLD:
				_show_context_menu(event.position)

	elif event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			is_panning = true
			pan_start_mouse = event.position
			pan_start_offset = pan_offset
		else:
			is_panning = false

	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom_at(event.position, 1.2)

	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom_at(event.position, 0.8)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var world_pos := screen_to_world(event.position)

	var new_hover: String = data.get_component_at(world_pos)
	if new_hover != hovered_component:
		hovered_component = new_hover
		queue_redraw()

	if is_panning:
		pan_offset = pan_start_offset + (event.position - pan_start_mouse)
		view_changed.emit()
		queue_redraw()

	if is_dragging_component and drag_component_id:
		var comp = data.get_component(drag_component_id)
		if comp:
			var new_pos: Vector2 = screen_to_world(event.position) - screen_to_world(drag_start_mouse) + drag_start_component_pos
			if snap_to_grid:
				new_pos = data.snap_to_grid(new_pos)
			comp.position = new_pos
			queue_redraw()

	if is_box_selecting:
		box_select_end = event.position
		queue_redraw()


func _handle_key_input(event: InputEventKey) -> void:
	# Space arms/disarms drag-pan on both key edges (before the pressed-only gate).
	if event.keycode == KEY_SPACE:
		_space_pan_armed = event.pressed
		return

	if not event.pressed:
		return

	match event.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			# Delete selected trace first, otherwise the selected components.
			if not selected_trace_id.is_empty():
				_delete_selected_trace()
			else:
				_delete_selected()
		KEY_ESCAPE:
			_clear_selection()
			selected_trace_id = ""
			queue_redraw()
		KEY_R:
			_rotate_selected()
		KEY_G:
			show_grid = not show_grid
			queue_redraw()
		KEY_N:
			show_ratsnest = not show_ratsnest
			queue_redraw()
		KEY_L:
			if event.shift_pressed:
				_unlock_all_components()
			elif not selected_components.is_empty():
				_lock_selected_components()
			else:
				show_labels = not show_labels
				queue_redraw()
		KEY_HOME:
			_center_view()
		KEY_PLUS, KEY_KP_ADD, KEY_EQUAL:
			_zoom_at(size / 2, 1.2)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom_at(size / 2, 0.8)
		KEY_S:
			set_tool_mode(ToolMode.SELECT)


## Trackpad two-finger scroll → pan the view (finding 1: "trackpad zoom does
## nothing" — many trackpads emit pan gestures, not wheel-button events).
func _handle_pan_gesture(event: InputEventPanGesture) -> void:
	pan_offset -= event.delta * 12.0
	view_changed.emit()
	queue_redraw()


## Trackpad pinch → zoom about the gesture point (finding 1).
func _handle_magnify_gesture(event: InputEventMagnifyGesture) -> void:
	if event.factor > 0.0:
		_zoom_at(event.position, event.factor)


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var world_before := screen_to_world(screen_pos)
	zoom = clampf(zoom * factor, min_zoom, max_zoom)
	var world_after := screen_to_world(screen_pos)
	pan_offset += (world_after - world_before) * zoom
	zoom_changed.emit(zoom)
	view_changed.emit()
	queue_redraw()


func _center_view() -> void:
	if not data:
		return
	pan_offset = Vector2.ZERO
	view_changed.emit()
	queue_redraw()


func _clear_selection() -> void:
	for comp_id in selected_components:
		component_deselected.emit(comp_id)
	selected_components.clear()
	selection_changed.emit()


func _finalize_box_selection() -> void:
	var world_start := screen_to_world(box_select_start.min(box_select_end))
	var world_end := screen_to_world(box_select_start.max(box_select_end))
	var select_rect := Rect2(world_start, world_end - world_start)

	var hits: Array = data.get_components_in_region(select_rect)
	for comp_id in hits:
		if comp_id not in selected_components:
			selected_components.append(comp_id)
			component_selected.emit(comp_id)

	selection_changed.emit()


func _delete_selected() -> void:
	if selected_components.is_empty():
		return

	data.save_to_history("Delete components")
	for comp_id in selected_components:
		data.remove_component(comp_id)

	selected_components.clear()
	selection_changed.emit()
	queue_redraw()


func _delete_selected_trace() -> void:
	if selected_trace_id.is_empty() or not data:
		return
	data.save_to_history("Delete trace")
	data.remove_trace(selected_trace_id)
	selected_trace_id = ""
	queue_redraw()


## Lock all currently selected components and clear selection.
func _lock_selected_components() -> void:
	if selected_components.is_empty():
		return

	var names: PackedStringArray = []
	for comp_id in selected_components:
		var comp = data.get_component(comp_id)
		if comp:
			comp.locked = true
			names.append(comp_id)

	selected_components.clear()
	selection_changed.emit()

	if names.size() == 1:
		component_lock_changed.emit("Locked %s" % names[0])
	elif names.size() > 1:
		component_lock_changed.emit("Locked %d components" % names.size())

	queue_redraw()


## Unlock all locked components.
func _unlock_all_components() -> void:
	if not data:
		return

	var count := 0
	for comp_id in data.components:
		var comp = data.components[comp_id]
		if comp.locked:
			comp.locked = false
			count += 1

	if count > 0:
		component_lock_changed.emit("Unlocked all (%d)" % count)
		queue_redraw()


func _rotate_selected() -> void:
	if selected_components.is_empty():
		return

	data.save_to_history("Rotate components")
	for comp_id in selected_components:
		var comp = data.get_component(comp_id)
		if comp:
			var old_rotation: float = comp.rotation
			comp.rotate_clockwise()
			data.record_change("rotate_component", {
				"component_id": comp_id,
				"old_rotation": old_rotation,
				"new_rotation": comp.rotation
			})
			data.component_changed.emit(comp_id)

	queue_redraw()


## Get a locked component at a world position (for unlock context menu).
func _get_locked_component_at(world_pos: Vector2) -> String:
	if not data:
		return ""
	for comp_id in data.components:
		var comp = data.components[comp_id]
		if comp.locked and comp.contains_point(world_pos):
			return comp_id
	return ""


## Check if any component is currently locked.
func _has_any_locked_components() -> bool:
	if not data:
		return false
	for comp_id in data.components:
		if data.components[comp_id].locked:
			return true
	return false


## Set the active tool mode. Emits tool_mode_changed on a real change.
func set_tool_mode(mode: ToolMode) -> void:
	if tool_mode != mode:
		tool_mode = mode
		tool_mode_changed.emit(mode)
		queue_redraw()

#endregion


#region Public API

## Set the PCB data model, wiring reactive redraws.
func set_data(new_data) -> void:
	if data:
		if data.data_changed.is_connected(_on_data_changed):
			data.data_changed.disconnect(_on_data_changed)
		if data.structure_changed.is_connected(_on_structure_changed):
			data.structure_changed.disconnect(_on_structure_changed)

	data = new_data

	if data:
		data.data_changed.connect(_on_data_changed)
		data.structure_changed.connect(_on_structure_changed)

	_center_view()
	queue_redraw()


## Get current selection.
func get_selected_components() -> Array[String]:
	return selected_components.duplicate()


## Select a component programmatically.
func select_component(component_id: String, add_to_selection: bool = false) -> void:
	if not add_to_selection:
		_clear_selection()

	if component_id not in selected_components and data.has_component(component_id):
		selected_components.append(component_id)
		component_selected.emit(component_id)
		selection_changed.emit()
		queue_redraw()


## Zoom to fit all components.
func zoom_to_fit() -> void:
	if not data or data.components.is_empty():
		_center_view()
		return

	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)

	for comp_id in data.components:
		var comp = data.components[comp_id]
		var bounds: Rect2 = comp.get_bounding_rect()
		min_pos.x = minf(min_pos.x, bounds.position.x)
		min_pos.y = minf(min_pos.y, bounds.position.y)
		max_pos.x = maxf(max_pos.x, bounds.end.x)
		max_pos.y = maxf(max_pos.y, bounds.end.y)

	var margin := 10.0
	min_pos -= Vector2(margin, margin)
	max_pos += Vector2(margin, margin)

	var content_size := max_pos - min_pos
	var content_center := (min_pos + max_pos) / 2.0

	if content_size.x <= 0.0 or content_size.y <= 0.0:
		_center_view()
		return

	var zoom_x := size.x / content_size.x
	var zoom_y := size.y / content_size.y
	zoom = minf(zoom_x, zoom_y)
	zoom = clampf(zoom, min_zoom, max_zoom)

	pan_offset = -content_center * zoom

	zoom_changed.emit(zoom)
	view_changed.emit()
	queue_redraw()


func _on_data_changed() -> void:
	queue_redraw()


func _on_structure_changed() -> void:
	queue_redraw()

#endregion
