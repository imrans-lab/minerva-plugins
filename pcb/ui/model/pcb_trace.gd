extends RefCounted
## Represents a copper trace (routed connection) on the PCB.
##
## Off-tree port of Minerva src/Scripts/UI/Controls/PCBEditor/PCBTrace.gd — NO
## class_name; self-preload by relative path. Boundary to_board_dict()/
## from_board_dict() map net_name/waypoints/width → net/points/width_mm; id and
## locked ride in canonical Extra (mirrors pcb/internal/board/minpcb.go).

const _Self := preload("pcb_trace.gd")

## Unique identifier for this trace
var id: String = ""

## Net name this trace belongs to
var net_name: String = ""

## Waypoints defining the trace path (polyline in mm)
var waypoints: Array[Vector2] = []

## THE trace-width contract (A7, docket 019fb92f07e2). Declared on the entity
## that HAS a width so the three readers — the panel's width controls, the
## journalled model setter (pcb_data.set_trace_width) and the preference
## registry (pcb_prefs.key_registry) — share ONE rule instead of three copies of
## the same two numbers drifting apart.
##
## The bounds are SANITY RAILS, not fabrication rules — the same reasoning the
## width spin box was built with (PCBPanel.gd ~782): below 0.1 mm is finer than
## any hobby process etches, above 5 mm is a plane rather than a trace, and the
## real constraint is the fab's own spec, which this editor has no way to know.
const MIN_WIDTH_MM := 0.1
const MAX_WIDTH_MM := 5.0
## The width a trace has when nothing else says (also pcb_data's authored
## fallback, and the preference registry's default).
const DEFAULT_WIDTH_MM := 0.25

## Trace width in mm (common values: 0.15, 0.2, 0.25, 0.3, 0.5, 1.0)
var width: float = DEFAULT_WIDTH_MM

## Layer: "top", "bottom", or inner layer names
var layer: String = "top"

## Whether this trace is locked from editing
var locked: bool = false


## Why `width_mm` may not be written to a trace, or "" when it may.
##
## REFUSES out of range rather than clamping: this guards COPPER. A caller that
## asked for 40 mm asked for something that is not a trace, and silently laying
## 5 mm instead would be the editor inventing a fabrication decision. (The
## PREFERENCE store deliberately does the opposite — see pcb_prefs.set_value,
## which clamps a starting-point value into the range its control can express.)
static func width_error(width_mm: float) -> String:
	if not is_finite(width_mm):
		return "A trace width must be a finite number of millimetres."
	if width_mm <= 0.0:
		return "A trace width must be greater than zero — zero-width copper is not copper."
	if width_mm < MIN_WIDTH_MM or width_mm > MAX_WIDTH_MM:
		return "Trace width %.3f mm is outside the %.2f–%.2f mm range this editor authors." % [
			width_mm, MIN_WIDTH_MM, MAX_WIDTH_MM]
	return ""


## Add a waypoint to the trace
func add_waypoint(point: Vector2) -> void:
	waypoints.append(point)


## Insert a waypoint at a specific index
func insert_waypoint(index: int, point: Vector2) -> void:
	if index >= 0 and index <= waypoints.size():
		waypoints.insert(index, point)


## Remove a waypoint by index
func remove_waypoint(index: int) -> void:
	if index >= 0 and index < waypoints.size():
		waypoints.remove_at(index)


## Clear all waypoints
func clear_waypoints() -> void:
	waypoints.clear()


## Get the starting point of the trace
func get_start() -> Vector2:
	if waypoints.is_empty():
		return Vector2.ZERO
	return waypoints[0]


## Get the ending point of the trace
func get_end() -> Vector2:
	if waypoints.is_empty():
		return Vector2.ZERO
	return waypoints[waypoints.size() - 1]


## Calculate the total length of the trace
func get_length() -> float:
	if waypoints.size() < 2:
		return 0.0

	var total := 0.0
	for i in range(waypoints.size() - 1):
		total += waypoints[i].distance_to(waypoints[i + 1])
	return total


## Get the bounding rectangle of the trace
func get_bounding_rect() -> Rect2:
	if waypoints.is_empty():
		return Rect2()

	var min_pos := waypoints[0]
	var max_pos := waypoints[0]

	for point in waypoints:
		min_pos.x = minf(min_pos.x, point.x)
		min_pos.y = minf(min_pos.y, point.y)
		max_pos.x = maxf(max_pos.x, point.x)
		max_pos.y = maxf(max_pos.y, point.y)

	# Account for trace width
	var half_width := width / 2.0
	min_pos -= Vector2(half_width, half_width)
	max_pos += Vector2(half_width, half_width)

	return Rect2(min_pos, max_pos - min_pos)


## Check if a point is near this trace (within threshold distance)
func is_point_near(point: Vector2, threshold: float = 0.5) -> bool:
	var effective_threshold := threshold + width / 2.0

	for i in range(waypoints.size() - 1):
		var dist := _point_to_segment_distance(point, waypoints[i], waypoints[i + 1])
		if dist <= effective_threshold:
			return true

	return false


## Get the closest point on the trace to a given point
func get_closest_point(point: Vector2) -> Vector2:
	if waypoints.is_empty():
		return point

	if waypoints.size() == 1:
		return waypoints[0]

	var closest := waypoints[0]
	var min_dist := INF

	for i in range(waypoints.size() - 1):
		var segment_closest := _closest_point_on_segment(point, waypoints[i], waypoints[i + 1])
		var dist := point.distance_to(segment_closest)
		if dist < min_dist:
			min_dist = dist
			closest = segment_closest

	return closest


## Calculate distance from point to line segment
func _point_to_segment_distance(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> float:
	return point.distance_to(_closest_point_on_segment(point, seg_start, seg_end))


## Find the closest point on a line segment to a given point
func _closest_point_on_segment(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> Vector2:
	var seg := seg_end - seg_start
	var seg_len_sq := seg.length_squared()

	if seg_len_sq < 0.0001:
		return seg_start

	var t := clampf((point - seg_start).dot(seg) / seg_len_sq, 0.0, 1.0)
	return seg_start + t * seg


## Find the segment index closest to a point
func get_closest_segment_index(point: Vector2) -> int:
	if waypoints.size() < 2:
		return -1

	var best_idx := 0
	var min_dist := INF

	for i in range(waypoints.size() - 1):
		var dist := _point_to_segment_distance(point, waypoints[i], waypoints[i + 1])
		if dist < min_dist:
			min_dist = dist
			best_idx = i

	return best_idx


## Create a deep copy of this trace
func duplicate_trace():
	var copy := _Self.new()
	copy.id = id
	copy.net_name = net_name
	copy.width = width
	copy.layer = layer
	copy.locked = locked

	for wp in waypoints:
		copy.waypoints.append(wp)

	return copy


## Serialize to dictionary (legacy .minpcb shape)
func to_dict() -> Dictionary:
	var waypoints_arr: Array = []
	for wp in waypoints:
		waypoints_arr.append({"x": wp.x, "y": wp.y})

	return {
		"id": id,
		"net_name": net_name,
		"waypoints": waypoints_arr,
		"width": width,
		"layer": layer,
		"locked": locked
	}


## Deserialize from dictionary (legacy .minpcb shape)
func load_from_dict(data: Dictionary) -> void:
	id = data.get("id", "")
	net_name = data.get("net_name", "")
	width = data.get("width", DEFAULT_WIDTH_MM)
	layer = data.get("layer", "top")
	locked = data.get("locked", false)

	waypoints.clear()
	var waypoints_data: Array = data.get("waypoints", [])
	for wp_data in waypoints_data:
		if wp_data is Dictionary:
			waypoints.append(Vector2(wp_data.get("x", 0), wp_data.get("y", 0)))


## Create from dictionary (static constructor, legacy shape)
static func from_dict(data: Dictionary):
	var trace := _Self.new()
	trace.load_from_dict(data)
	return trace


# ── Canonical boundary (pcb/internal/board Trace) ─────────────────────────────

## Serialize to a canonical board-contract trace dict. waypoints → points
## [{x_mm,y_mm}]; id/locked ride in canonical Extra (mirrors minpcb.go).
func to_board_dict() -> Dictionary:
	var points: Array = []
	for wp in waypoints:
		points.append({"x_mm": wp.x, "y_mm": wp.y})
	return {
		"net": net_name,
		"layer": layer,
		"width_mm": width,
		"points": points,
		"id": id,
		"locked": locked,
	}


## Restore from a canonical board-contract trace dict.
func load_from_board_dict(data: Dictionary) -> void:
	id = str(data.get("id", ""))
	net_name = str(data.get("net", data.get("net_name", "")))
	width = float(data.get("width_mm", DEFAULT_WIDTH_MM))
	layer = str(data.get("layer", "top"))
	locked = data.get("locked", false)

	waypoints.clear()
	var points: Array = data.get("points", [])
	for p in points:
		if p is Dictionary:
			waypoints.append(Vector2(float(p.get("x_mm", 0.0)), float(p.get("y_mm", 0.0))))


## Create from a canonical board-contract trace dict (static constructor).
static func from_board_dict(data: Dictionary):
	var trace := _Self.new()
	trace.load_from_board_dict(data)
	return trace


## Get a human-readable description
func get_description() -> String:
	return "%s: %s on %s layer, %d segments, %.2fmm wide, %.2fmm long" % [
		id, net_name, layer, maxi(0, waypoints.size() - 1), width, get_length()
	]
