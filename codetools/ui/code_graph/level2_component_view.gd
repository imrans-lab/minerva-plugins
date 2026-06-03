extends Control
## Off-tree plugin script: NO class_name
## Level 2: Component drill-in — spatial node graph with pre-computed positions.
## Shows symbols within a boundary/component with external callers faded.

const GraphDataScript = preload("graph_data.gd")
const AnnotationDataScript = preload("annotation_data.gd")

signal symbol_clicked(node_data: Dictionary)  # double-click: drill to Level 3
signal symbol_inspected(node_data: Dictionary)  # single-click: show in inspector
signal annotate_requested(node_data: Dictionary)  # ctrl+click: add annotation
signal back_requested()

var graph_data: GraphDataScript
var annotation_data: AnnotationDataScript
var boundary_filter := ""  # show only this boundary, empty = all

var _visible_nodes: Array[Dictionary] = []
var _visible_edges: Array[Dictionary] = []
var _external_nodes: Array[Dictionary] = []
var _internal_ids: Dictionary = {}  # id -> true

var _selected_id := ""
var _hovered_id := ""
var _highlighted: Dictionary = {}

# Camera
var _offset := Vector2.ZERO
var _zoom := 1.0
var _dragging := false
var _drag_start := Vector2.ZERO
var _drag_node_id := ""
var _drag_node_offset := Vector2.ZERO


func _ready() -> void:
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		if graph_data:
			_center_view()
		queue_redraw()


func load_graph(data: GraphDataScript, boundary: String = "") -> void:
	graph_data = data
	boundary_filter = boundary
	_rebuild()
	call_deferred("_center_view")
	queue_redraw()


func _center_view() -> void:
	if _visible_nodes.is_empty():
		return
	# Compute bounding box of all internal (visible) nodes
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	for node: Dictionary in _visible_nodes:
		if not node.has("x") or not node.has("y"):
			continue
		var nx: float = float(node.x)
		var ny: float = float(node.y)
		min_pos.x = minf(min_pos.x, nx)
		min_pos.y = minf(min_pos.y, ny)
		max_pos.x = maxf(max_pos.x, nx)
		max_pos.y = maxf(max_pos.y, ny)
	if min_pos.x == INF:
		return
	var content_center: Vector2 = (min_pos + max_pos) / 2.0
	var content_size: Vector2 = max_pos - min_pos
	# Fit zoom to show all content with padding
	if content_size.x > 0 and content_size.y > 0 and size.x > 0:
		_zoom = minf(size.x / (content_size.x + 120.0), size.y / (content_size.y + 120.0))
		_zoom = clampf(_zoom, 0.2, 4.0)
	elif size.x > 0:
		_zoom = 1.0
	_offset = size / 2.0 - content_center * _zoom
	queue_redraw()


func _rebuild() -> void:
	_visible_nodes.clear()
	_visible_edges.clear()
	_external_nodes.clear()
	_internal_ids.clear()

	if not graph_data:
		return

	# Collect internal nodes (in the filtered boundary)
	for node: Dictionary in graph_data.get_visible_nodes():
		if boundary_filter == "" or graph_data.get_boundary_for_file(str(node.file)) == boundary_filter:
			_visible_nodes.append(node)
			_internal_ids[str(node.id)] = true

	# Collect edges where at least one end is internal
	for edge: Dictionary in graph_data.edges:
		var src_in: bool = _internal_ids.has(str(edge.source))
		var tgt_in: bool = _internal_ids.has(str(edge.target))
		if src_in or tgt_in:
			_visible_edges.append(edge)
			# Track external nodes
			if not src_in:
				var src: Dictionary = graph_data.get_node_by_id(str(edge.source))
				if not src.is_empty():
					_external_nodes.append(src)
					_internal_ids[str(src.id)] = false  # mark as external
			if not tgt_in:
				var tgt: Dictionary = graph_data.get_node_by_id(str(edge.target))
				if not tgt.is_empty():
					_external_nodes.append(tgt)
					_internal_ids[str(tgt.id)] = false


func _draw() -> void:
	if not graph_data:
		return

	draw_rect(Rect2(Vector2.ZERO, size), Color(0.102, 0.102, 0.18))

	var all_nodes: Array[Dictionary] = []
	all_nodes.append_array(_visible_nodes)
	all_nodes.append_array(_external_nodes)
	var has_hl: bool = not _highlighted.is_empty()

	# ── Edges ──
	for edge: Dictionary in _visible_edges:
		var src: Dictionary = graph_data.get_node_by_id(str(edge.source))
		var tgt: Dictionary = graph_data.get_node_by_id(str(edge.target))
		if src.is_empty() or tgt.is_empty():
			continue
		if not src.has("x") or not tgt.has("x"):
			continue

		var spos: Vector2 = _to_screen(Vector2(float(src.x), float(src.y)))
		var tpos: Vector2 = _to_screen(Vector2(float(tgt.x), float(tgt.y)))

		var is_external: bool = _internal_ids.get(str(edge.source), true) == false or _internal_ids.get(str(edge.target), true) == false
		var both_hl: bool = _highlighted.has(str(edge.source)) and _highlighted.has(str(edge.target))

		var color: Color = graph_data.get_edge_color(str(edge.type))
		color.a = 0.12 if is_external else 0.25
		if has_hl and not both_hl:
			color.a = 0.03
		elif has_hl and both_hl:
			color.a = 0.5 if is_external else 0.7

		var w: float = (2.0 if (has_hl and both_hl) else 1.0) * _zoom
		var dash: bool = graph_data.is_dashed_edge(str(edge.type))

		var dir: Vector2 = tpos - spos
		var dist: float = dir.length()
		if dist < 1.0:
			continue
		dir = dir.normalized()
		var tr: float = graph_data.get_node_radius(tgt) * _zoom
		var arrow_sz: float = 4.0 * _zoom
		var end_pos: Vector2 = tpos - dir * (tr + arrow_sz)

		if dash:
			_draw_dashed_line(spos, end_pos, color, w)
		else:
			draw_line(spos, end_pos, color, w)

		# Arrowhead
		if dist > tr + arrow_sz + 2.0:
			var perp: Vector2 = Vector2(-dir.y, dir.x)
			draw_colored_polygon(PackedVector2Array([
				end_pos + dir * arrow_sz,
				end_pos + perp * arrow_sz * 0.5,
				end_pos - perp * arrow_sz * 0.5,
			]), color)

	# ── Nodes ──
	for node: Dictionary in all_nodes:
		if not node.has("x") or not node.has("y"):
			continue

		var pos: Vector2 = _to_screen(Vector2(float(node.x), float(node.y)))
		var r: float = graph_data.get_node_radius(node) * _zoom
		var is_external: bool = _internal_ids.get(str(node.id), true) == false
		var is_sel: bool = str(node.id) == _selected_id
		var is_hl: bool = _highlighted.has(str(node.id))
		var dimmed: bool = has_hl and not is_hl

		var color: Color = graph_data.get_kind_color(str(node.get("kind", "")))
		var fill_alpha: float = 0.3 if is_external else 1.0
		if dimmed:
			fill_alpha = 0.08
		elif is_hl:
			fill_alpha = 0.5 if is_external else 1.0
			color = color.lightened(0.15)

		color.a = fill_alpha
		draw_circle(pos, r, color)

		# Stroke
		var stroke_color: Color = Color(0.91, 0.27, 0.38) if is_sel else (Color.WHITE if node.get("is_entry_point", false) else color.darkened(0.3))
		var stroke_w: float = (3.0 if is_sel else 1.5) * _zoom
		if dimmed:
			stroke_color.a = 0.08
		draw_arc(pos, r, 0, TAU, 32, stroke_color, stroke_w)

		# Label: show for external, selected, or highlighted
		if is_external or is_sel or is_hl:
			var label_alpha: float = 0.1 if dimmed else (0.4 if is_external else 0.8)
			var font_size: int = int((11.0 if is_external else 12.0) * _zoom)
			var label_color := Color(0.69, 0.69, 0.69, label_alpha)
			draw_string(ThemeDB.fallback_font, pos + Vector2(r + 3, 3) * _zoom,
				str(node.name), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, label_color)

		# Annotation badge — count only annotations within this symbol's line range
		if annotation_data and not dimmed:
			var file_path: String = str(node.get("file", ""))
			var sym_start: int = int(node.get("line_start", 0))
			var sym_end: int = int(node.get("line_end", 0))
			var ann_count := 0
			for ann: Dictionary in annotation_data.get_for_file(file_path):
				if int(ann.line_start) >= sym_start and int(ann.line_start) <= sym_end:
					ann_count += 1
			if ann_count > 0:
				# Badge sits at top-right edge of the node circle (r is already zoom-scaled)
				var badge_r: float = 5.0 * _zoom
				var badge_pos: Vector2 = pos + Vector2(r - badge_r * 0.3, -(r - badge_r * 0.3))
				draw_circle(badge_pos, badge_r, Color(0.9, 0.6, 0.97, 0.9))
				draw_string(ThemeDB.fallback_font,
					badge_pos + Vector2(-3, 3) * _zoom,
					str(ann_count), HORIZONTAL_ALIGNMENT_CENTER, -1,
					int(8 * _zoom), Color(1, 1, 1, 0.95))


func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, width: float) -> void:
	var dir: Vector2 = to - from
	var dist: float = dir.length()
	if dist < 1.0:
		return
	dir = dir.normalized()
	var dash: float = 4.0 * _zoom
	var gap: float = 3.0 * _zoom
	var p := 0.0
	while p < dist:
		var end_p: float = minf(p + dash, dist)
		draw_line(from + dir * p, from + dir * end_p, color, width)
		p = end_p + gap


# ── Transforms ──

func _to_screen(world: Vector2) -> Vector2:
	return world * _zoom + _offset

func _to_world(screen: Vector2) -> Vector2:
	return (screen - _offset) / _zoom


# ── Input ──

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(event.position, 1.1)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.0 / 1.1)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var hit: String = _hit_test(event.position)
				if hit != "":
					var node: Dictionary = graph_data.get_node_by_id(hit)
					if event.double_click:
						symbol_clicked.emit(node)
					elif event.ctrl_pressed:
						annotate_requested.emit(node)
					else:
						_select(hit)
						symbol_inspected.emit(node)
						_drag_node_id = hit
						_drag_node_offset = Vector2(float(node.x), float(node.y)) - _to_world(event.position)
				else:
					_dragging = true
					_drag_start = event.position - _offset
			else:
				if _drag_node_id != "":
					_drag_node_id = ""
				elif _dragging:
					_dragging = false
					# If barely moved, treat as click-away (deselect)
					if event.position.distance_to(_drag_start + _offset) < 5.0:
						_selected_id = ""
						_highlighted.clear()
						symbol_inspected.emit({})  # empty = deselect
						queue_redraw()
			accept_event()
	elif event is InputEventMouseMotion:
		if _drag_node_id != "":
			var node: Dictionary = graph_data.get_node_by_id(_drag_node_id)
			if not node.is_empty():
				var new_pos: Vector2 = _to_world(event.position) + _drag_node_offset
				node["x"] = new_pos.x
				node["y"] = new_pos.y
				queue_redraw()
			accept_event()
		elif _dragging:
			_offset = event.position - _drag_start
			queue_redraw()
			accept_event()
		else:
			var hit: String = _hit_test(event.position)
			if hit != _hovered_id:
				_hovered_id = hit
				if _selected_id == "":
					if hit != "":
						_highlight(hit)
					else:
						_highlighted.clear()
				queue_redraw()


func _select(id: String) -> void:
	_selected_id = id
	_highlight(id)
	queue_redraw()

func _highlight(id: String) -> void:
	_highlighted.clear()
	_highlighted[id] = true
	var edges: Dictionary = graph_data.get_edges_for_node(id)
	for e: Dictionary in edges.incoming:
		_highlighted[str(e.source)] = true
	for e: Dictionary in edges.outgoing:
		_highlighted[str(e.target)] = true

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var old_world: Vector2 = _to_world(screen_pos)
	_zoom = clampf(_zoom * factor, 0.1, 8.0)
	_offset = screen_pos - old_world * _zoom
	queue_redraw()

func _hit_test(screen_pos: Vector2) -> String:
	var all_nodes: Array[Dictionary] = []
	all_nodes.append_array(_visible_nodes)
	all_nodes.append_array(_external_nodes)
	for i in range(all_nodes.size() - 1, -1, -1):
		var node: Dictionary = all_nodes[i]
		if not node.has("x") or not node.has("y"):
			continue
		var pos: Vector2 = _to_screen(Vector2(float(node.x), float(node.y)))
		var r: float = graph_data.get_node_radius(node) * _zoom
		if screen_pos.distance_to(pos) <= r + 3.0:
			return str(node.id)
	return ""
