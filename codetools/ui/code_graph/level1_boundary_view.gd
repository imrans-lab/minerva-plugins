extends Control
## Off-tree plugin script: NO class_name
## Level 1: Boundary view — dotted-border boxes with components inside,
## boundary-to-boundary arrows, internal component arrows.

const GraphDataScript = preload("graph_data.gd")
const AnnotationDataScript = preload("annotation_data.gd")

signal component_clicked(component_name: String, boundary_name: String)
signal component_inspected(node_data: Dictionary)
signal boundary_clicked(boundary_name: String)

var graph_data: GraphDataScript
var annotation_data: AnnotationDataScript  # shared reference for annotation indicators

# Layout: boundary positions (hand-placed or auto-computed)
var _boundary_rects: Dictionary = {}  # boundary_name -> Rect2
var _component_rects: Dictionary = {}  # component_id -> Rect2 (absolute)
var _hovered_boundary := ""
var _hovered_component := ""

# Camera
var _offset := Vector2.ZERO
var _zoom := 1.0
var _dragging := false
var _drag_start := Vector2.ZERO


func _ready() -> void:
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		if graph_data:
			_center_view()
		queue_redraw()


func load_graph(data: GraphDataScript) -> void:
	graph_data = data
	_compute_layout()
	# Center the layout in the viewport
	call_deferred("_center_view")
	queue_redraw()


func _center_view() -> void:
	if _boundary_rects.is_empty():
		return
	# Find bounding box of all boundaries
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	for bname: String in _boundary_rects:
		var rect: Rect2 = _boundary_rects[bname]
		min_pos.x = minf(min_pos.x, rect.position.x)
		min_pos.y = minf(min_pos.y, rect.position.y)
		max_pos.x = maxf(max_pos.x, rect.end.x)
		max_pos.y = maxf(max_pos.y, rect.end.y)
	var content_center: Vector2 = (min_pos + max_pos) / 2.0
	var content_size: Vector2 = max_pos - min_pos
	# Fit zoom to show all content with padding
	if content_size.x > 0 and content_size.y > 0 and size.x > 0:
		_zoom = minf(size.x / (content_size.x + 80.0), size.y / (content_size.y + 80.0))
		_zoom = clampf(_zoom, 0.3, 2.0)
	_offset = size / 2.0 - content_center * _zoom
	queue_redraw()


func _compute_layout() -> void:
	if not graph_data:
		return

	var boundaries: Dictionary = graph_data.get_boundaries()
	var boundary_names: Array = boundaries.keys()
	boundary_names.sort()

	# Auto-layout: arrange boundaries in a grid
	var col := 0
	var row := 0
	var max_cols := ceili(sqrt(float(boundary_names.size())))
	var cell_w := 340.0
	var cell_h := 320.0
	var pad := 40.0

	_boundary_rects.clear()
	_component_rects.clear()

	for bname: String in boundary_names:
		var bdata: Dictionary = boundaries[bname]
		var components: Array = []
		for node: Dictionary in bdata.nodes:
			if str(node.kind) == "class":
				components.append(node)

		# Size boundary based on component count
		var comp_count: int = maxi(components.size(), 1)
		var comp_cols: int = mini(comp_count, 2)
		var comp_rows: int = ceili(float(comp_count) / comp_cols)
		var bw: float = maxf(cell_w, comp_cols * 160.0 + 40.0)
		var bh: float = maxf(160.0, comp_rows * 80.0 + 60.0)

		var bx: float = pad + col * (cell_w + pad)
		var by: float = pad + row * (cell_h + pad)
		_boundary_rects[bname] = Rect2(bx, by, bw, bh)

		# Place components inside boundary
		var ci := 0
		for comp: Dictionary in components:
			var cx: int = ci % comp_cols
			var cy: int = ci / comp_cols
			var comp_x: float = bx + 20.0 + cx * 155.0
			var comp_y: float = by + 45.0 + cy * 75.0
			var comp_w := 140.0
			var comp_h := 60.0
			_component_rects[str(comp.id)] = Rect2(comp_x, comp_y, comp_w, comp_h)
			ci += 1

		col += 1
		if col >= max_cols:
			col = 0
			row += 1


func _draw() -> void:
	if not graph_data:
		return

	# Background
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.102, 0.102, 0.18))

	var boundaries: Dictionary = graph_data.get_boundaries()

	# ── Cross-boundary edges (draw first, behind boxes) ──
	var cross_edges: Array[Dictionary] = graph_data.get_cross_boundary_edges()
	# Aggregate by boundary pair
	var aggregated: Dictionary = {}  # "src->tgt" -> {count, types}
	for edge: Dictionary in cross_edges:
		var src_node: Dictionary = graph_data.get_node_by_id(str(edge.source))
		var tgt_node: Dictionary = graph_data.get_node_by_id(str(edge.target))
		if src_node.is_empty() or tgt_node.is_empty():
			continue
		var src_b: String = graph_data.get_boundary_for_file(str(src_node.file))
		var tgt_b: String = graph_data.get_boundary_for_file(str(tgt_node.file))
		var key: String = src_b + "->" + tgt_b
		if not aggregated.has(key):
			aggregated[key] = {"from": src_b, "to": tgt_b, "count": 0, "types": {}}
		aggregated[key].count += 1
		var etype: String = str(edge.type)
		aggregated[key].types[etype] = aggregated[key].types.get(etype, 0) + 1

	for key: String in aggregated:
		var agg: Dictionary = aggregated[key]
		var from_rect: Rect2 = _boundary_rects.get(agg.from, Rect2())
		var to_rect: Rect2 = _boundary_rects.get(agg.to, Rect2())
		if from_rect.size == Vector2.ZERO or to_rect.size == Vector2.ZERO:
			continue

		var from_center: Vector2 = _to_screen(from_rect.get_center())
		var to_center: Vector2 = _to_screen(to_rect.get_center())
		var dir: Vector2 = (to_center - from_center).normalized()

		# Connect from boundary edges
		var from_pt: Vector2 = _rect_edge_point(from_rect, dir)
		var to_pt: Vector2 = _rect_edge_point(to_rect, -dir)
		from_pt = _to_screen(from_pt)
		to_pt = _to_screen(to_pt)

		var thickness: float = clampf(float(agg.count) / 3.0, 2.0, 10.0) * _zoom
		# Dominant color from most common edge type
		var dominant_type := "calls"
		var max_count := 0
		for etype: String in agg.types:
			if int(agg.types[etype]) > max_count:
				max_count = int(agg.types[etype])
				dominant_type = etype
		var color: Color = graph_data.get_edge_color(dominant_type)
		color.a = 0.5

		# Shorten for arrowhead
		var edge_dir: Vector2 = (to_pt - from_pt).normalized()
		var arrow_size: float = 6.0 * _zoom
		var end_pt: Vector2 = to_pt - edge_dir * arrow_size

		draw_line(from_pt, end_pt, color, thickness)
		# Arrowhead
		var perp: Vector2 = Vector2(-edge_dir.y, edge_dir.x)
		draw_colored_polygon(PackedVector2Array([
			to_pt,
			to_pt - edge_dir * arrow_size + perp * arrow_size * 0.5,
			to_pt - edge_dir * arrow_size - perp * arrow_size * 0.5,
		]), color)

		# Label — offset perpendicular to the line so it doesn't overlap
		var mid: Vector2 = (from_pt + to_pt) / 2.0
		var perp_offset: Vector2 = Vector2(-edge_dir.y, edge_dir.x) * 12.0 * _zoom
		var type_names: PackedStringArray = PackedStringArray()
		for etype: String in agg.types:
			type_names.append(etype)
		var label: String = "%s (%d)" % [", ".join(type_names), agg.count]
		draw_string(ThemeDB.fallback_font, mid + perp_offset + Vector2(0, -4 * _zoom),
			label, HORIZONTAL_ALIGNMENT_CENTER, -1, int(11 * _zoom), Color(0.69, 0.69, 0.69))

	# ── Boundary boxes ──
	for bname: String in _boundary_rects:
		var rect: Rect2 = _boundary_rects[bname]
		var screen_rect: Rect2 = Rect2(_to_screen(rect.position), rect.size * _zoom)

		# Dotted border
		var border_color := Color(0.06, 0.2, 0.38)
		var fill_color := Color(0.06, 0.2, 0.38, 0.12)
		if bname == _hovered_boundary:
			border_color = Color(0.3, 0.67, 0.97)
			fill_color = Color(0.06, 0.2, 0.38, 0.25)

		draw_rect(screen_rect, fill_color)
		_draw_dashed_rect(screen_rect, border_color, 2.0 * _zoom)

		# Boundary label
		var label_pos: Vector2 = screen_rect.position + Vector2(14, 22) * _zoom
		draw_string(ThemeDB.fallback_font, label_pos, bname,
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(13 * _zoom), Color(0.494, 0.784, 0.89))

		# Stats
		var bdata: Dictionary = boundaries.get(bname, {})
		var file_count: int = bdata.get("files", []).size()
		var node_count: int = bdata.get("nodes", []).size()
		var stats_text: String = "%d files · %d symbols" % [file_count, node_count]
		draw_string(ThemeDB.fallback_font, label_pos + Vector2(0, 16) * _zoom, stats_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(10 * _zoom), Color(0.38, 0.38, 0.5))

	# ── Components inside boundaries ──
	for comp_id: String in _component_rects:
		var rect: Rect2 = _component_rects[comp_id]
		var screen_rect: Rect2 = Rect2(_to_screen(rect.position), rect.size * _zoom)
		var node: Dictionary = graph_data.get_node_by_id(comp_id)
		if node.is_empty():
			continue

		var comp_fill := Color(0.12, 0.24, 0.43, 0.4)
		var comp_border := Color(0.17, 0.29, 0.48)
		if comp_id == _hovered_component:
			comp_fill = Color(0.16, 0.31, 0.55, 0.5)
			comp_border = Color(0.3, 0.67, 0.97)

		draw_rect(screen_rect, comp_fill)
		draw_rect(screen_rect, comp_border, false, 1.5 * _zoom)

		# Component name
		var name_pos: Vector2 = screen_rect.position + Vector2(8, 16) * _zoom
		draw_string(ThemeDB.fallback_font, name_pos, str(node.name),
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(12 * _zoom), Color(0.878, 0.878, 0.878))

		# Kind
		draw_string(ThemeDB.fallback_font, name_pos + Vector2(0, 14) * _zoom,
			str(node.get("kind", "")),
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(11 * _zoom), Color(0.376, 0.376, 0.502))

		# Method count + file
		var method_count := 0
		var file_path: String = str(node.file)
		for n: Dictionary in graph_data.get_nodes_in_file(file_path):
			if str(n.kind) == "function":
				method_count += 1
		var info_text: String = "%d methods · %s" % [method_count, file_path.get_file()]
		draw_string(ThemeDB.fallback_font,
			screen_rect.position + Vector2(8, screen_rect.size.y - 6 * _zoom),
			info_text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(11 * _zoom), Color(0.19, 0.19, 0.25))

	# ── Annotation badges on components — count only annotations within symbol's line range ──
	if annotation_data:
		for comp_id: String in _component_rects:
			var node: Dictionary = graph_data.get_node_by_id(comp_id)
			if node.is_empty():
				continue
			var file_path: String = str(node.file)
			var sym_start: int = int(node.get("line_start", 0))
			var sym_end: int = int(node.get("line_end", 0))
			var ann_count := 0
			for ann: Dictionary in annotation_data.get_for_file(file_path):
				if int(ann.line_start) >= sym_start and int(ann.line_start) <= sym_end:
					ann_count += 1
			if ann_count > 0:
				var rect: Rect2 = _component_rects[comp_id]
				var badge_pos: Vector2 = _to_screen(Vector2(rect.position.x + rect.size.x - 8, rect.position.y + 4))
				var badge_r: float = 8.0 * _zoom
				var badge_color := Color(0.9, 0.6, 0.97, 0.7)
				draw_circle(badge_pos, badge_r, badge_color)
				draw_string(ThemeDB.fallback_font, badge_pos + Vector2(-3, 4) * _zoom,
					str(ann_count), HORIZONTAL_ALIGNMENT_CENTER, -1,
					int(9 * _zoom), Color(1, 1, 1, 0.9))

	# ── Internal edges (within boundaries, dashed) ──
	for bname: String in _boundary_rects:
		var components: Array[Dictionary] = graph_data.get_components_in_boundary(bname)
		for i in range(components.size()):
			for j in range(i + 1, components.size()):
				var ci: Dictionary = components[i]
				var cj: Dictionary = components[j]
				# Check if there are edges between these components' files
				var ci_file: String = str(ci.file)
				var cj_file: String = str(cj.file)
				var edge_count := 0
				for edge: Dictionary in graph_data.edges:
					var src: Dictionary = graph_data.get_node_by_id(str(edge.source))
					var tgt: Dictionary = graph_data.get_node_by_id(str(edge.target))
					if src.is_empty() or tgt.is_empty():
						continue
					if str(edge.type) == "contains":
						continue
					if (str(src.file) == ci_file and str(tgt.file) == cj_file) or \
					   (str(src.file) == cj_file and str(tgt.file) == ci_file):
						edge_count += 1
				if edge_count > 0:
					var ci_rect: Rect2 = _component_rects.get(str(ci.id), Rect2())
					var cj_rect: Rect2 = _component_rects.get(str(cj.id), Rect2())
					if ci_rect.size != Vector2.ZERO and cj_rect.size != Vector2.ZERO:
						var from_pt: Vector2 = _to_screen(ci_rect.get_center())
						var to_pt: Vector2 = _to_screen(cj_rect.get_center())
						var color := Color(0.3, 0.67, 0.97, 0.3)
						_draw_dashed_line(from_pt, to_pt, color, 1.5 * _zoom)


# ── Coordinate transforms ──

func _to_screen(world: Vector2) -> Vector2:
	return world * _zoom + _offset

func _to_world(screen: Vector2) -> Vector2:
	return (screen - _offset) / _zoom


# ── Drawing helpers ──

func _draw_dashed_rect(rect: Rect2, color: Color, width: float) -> void:
	var corners: PackedVector2Array = PackedVector2Array([
		rect.position,
		rect.position + Vector2(rect.size.x, 0),
		rect.position + rect.size,
		rect.position + Vector2(0, rect.size.y),
	])
	for i in range(4):
		_draw_dashed_line(corners[i], corners[(i + 1) % 4], color, width)


func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, width: float) -> void:
	var dir: Vector2 = to - from
	var dist: float = dir.length()
	if dist < 1.0:
		return
	dir = dir.normalized()
	var dash: float = 8.0 * _zoom
	var gap: float = 4.0 * _zoom
	var p := 0.0
	while p < dist:
		var end_p: float = minf(p + dash, dist)
		draw_line(from + dir * p, from + dir * end_p, color, width)
		p = end_p + gap


func _rect_edge_point(rect: Rect2, direction: Vector2) -> Vector2:
	## Find the point on a rectangle's edge in a given direction from center.
	var center: Vector2 = rect.get_center()
	var hw: float = rect.size.x / 2.0
	var hh: float = rect.size.y / 2.0
	if abs(direction.x) * hh > abs(direction.y) * hw:
		# Hit left or right edge
		var t: float = hw / abs(direction.x) if abs(direction.x) > 0.001 else 999.0
		return center + direction * t
	else:
		var t: float = hh / abs(direction.y) if abs(direction.y) > 0.001 else 999.0
		return center + direction * t


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
				var comp_hit: String = _hit_test_component(event.position)
				if comp_hit != "":
					var node: Dictionary = graph_data.get_node_by_id(comp_hit)
					var boundary: String = graph_data.get_boundary_for_file(str(node.file))
					if event.double_click:
						# Double-click: drill down
						component_clicked.emit(str(node.name), boundary)
					else:
						# Single-click: inspect
						component_inspected.emit(node)
					accept_event()
					return
				var boundary_hit: String = _hit_test_boundary(event.position)
				if boundary_hit != "":
					if event.double_click:
						boundary_clicked.emit(boundary_hit)
					accept_event()
					return
				_dragging = true
				_drag_start = event.position - _offset
			else:
				if _dragging:
					_dragging = false
					if event.position.distance_to(_drag_start + _offset) < 5.0:
						component_inspected.emit({})  # deselect
			accept_event()
	elif event is InputEventMouseMotion:
		if _dragging:
			_offset = event.position - _drag_start
			queue_redraw()
			accept_event()
		else:
			var old_comp: String = _hovered_component
			var old_boundary: String = _hovered_boundary
			_hovered_component = _hit_test_component(event.position)
			_hovered_boundary = _hit_test_boundary(event.position) if _hovered_component == "" else ""
			if _hovered_component != old_comp or _hovered_boundary != old_boundary:
				queue_redraw()


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var old_world: Vector2 = _to_world(screen_pos)
	_zoom = clampf(_zoom * factor, 0.2, 5.0)
	_offset = screen_pos - old_world * _zoom
	queue_redraw()


func _hit_test_component(screen_pos: Vector2) -> String:
	var world_pos: Vector2 = _to_world(screen_pos)
	for comp_id: String in _component_rects:
		var rect: Rect2 = _component_rects[comp_id]
		if rect.has_point(world_pos):
			return comp_id
	return ""


func _hit_test_boundary(screen_pos: Vector2) -> String:
	var world_pos: Vector2 = _to_world(screen_pos)
	for bname: String in _boundary_rects:
		var rect: Rect2 = _boundary_rects[bname]
		if rect.has_point(world_pos):
			return bname
	return ""
