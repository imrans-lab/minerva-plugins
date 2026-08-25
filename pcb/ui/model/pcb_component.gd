extends RefCounted
## Represents a component on the PCB board (resistor, IC, switch, etc.)
##
## Off-tree port of Minerva src/Scripts/UI/Controls/PCBEditor/PCBComponent.gd.
## NO class_name (plugin lives outside res://; plugin-local class_names are
## unresolvable and break the off-tree parser cache). Siblings are reached via
## relative preload(); cross-file values are duck-typed.
##
## Boundary: to_board_dict()/from_board_dict() speak the canonical contract
## (ref/x_mm/y_mm/rotation_deg/pins[{number,x_mm,y_mm}]). Render detail
## (footprint_id/width/height/local_bounds/pads/color/…) is emitted as canonical
## component "Extra" — sibling keys, exactly the set pcb/internal/board/minpcb.go
## parks in Component.Extra. Internal to_dict()/from_dict() keep the legacy shape
## (undo snapshots + Round-B friction).

const _Self := preload("pcb_component.gd")

## Footprint types for visual rendering
enum FootprintType {
	RESISTOR,
	CAPACITOR,
	IC_DIP,
	IC_QFP,
	IC_BGA,
	SWITCH,
	CONNECTOR,
	LED,
	DIODE,
	TRANSISTOR,
	CRYSTAL,
	HEADER,
	MOUNTING_HOLE,
	MODULE,  # Large modules like ESP32 dev boards
	CUSTOM
}

## Unique identifier (e.g., "SW1", "U3", "R12")
var id: String = ""

## Component footprint type
var footprint: FootprintType = FootprintType.CUSTOM

## Origin/anchor position in mm (typically pin 1, following KiCAD convention)
var position: Vector2 = Vector2.ZERO

## Rotation in degrees (0, 90, 180, 270)
var rotation: float = 0.0

## Bounding box dimensions in mm
var width: float = 5.0
var height: float = 2.5

## The bounding box relative to the footprint origin/pin 1 (0,0)
## e.g. Rect2(-1.27, -1.27, 10, 5) means body starts 1.27mm before origin, extends right/down
var local_bounds: Rect2 = Rect2(-1.27, -1.27, 5.0, 2.5)

## Pin definitions: pin_name -> relative Vector2 offset from anchor (origin)
var pins: Dictionary = {}

## Canonical component keys this model does NOT represent (assembly, mpn, ...),
## preserved verbatim from load_from_board_dict and re-emitted by
## to_board_dict — the GDScript mirror of Go's Extra passthrough. Epoch CPN1
## found the loss live: `assembly: exclude` and `mpn` vanished across the
## first real promote.
var canonical_extra: Dictionary = {}

## Per-pin canonical extras keyed by pin number (drill_mm /
## annulus_diameter_mm / plated / pad_width_mm / pad_height_mm / name, ...) —
## same preservation contract as canonical_extra; see the pin-loading note in
## load_from_board_dict.
var pin_extra: Dictionary = {}

## Additional properties (value, package, manufacturer, etc.)
var properties: Dictionary = {}

## Layer: "top" or "bottom"
var layer: String = "top"

## Whether this component is locked (skipped during hit-testing)
var locked: bool = false

## Visual properties
var color: Color = Color(0.2, 0.6, 0.3, 1.0)
var label_visible: bool = true

## KiCAD footprint ID (e.g., "Button_Switch_SMD:SW_SPST_PTS645Sx43SMTR92")
var footprint_id: String = ""

## Detailed pad geometry from KiCAD footprint library
## Each pad is a Dictionary with keys:
##   number: String - Pad number/name
##   type: String - "smd", "thru_hole", or "np_thru_hole"
##   shape: String - "rect", "circle", "oval", "roundrect", "custom"
##   position: Vector2 - Position relative to component center (mm)
##   size: Vector2 - Pad size (width, height in mm)
##   drill: float - Drill diameter for through-holes (0 for SMD)
##   layers: Array[String] - Copper/mask layers
var pads: Array = []

## Whether pad geometry has been loaded from footprint library
var has_pad_geometry: bool = false

## The COMPONENT-level resolved fact (bug 019ff4a9a0d7), distinct from the
## PAD-level has_pad_geometry above: a silk-only footprint resolves with zero
## pads, so the pad marker alone cannot say "this component is resolved". Set
## by the worker's resolve success path only; absence means unresolved.
var footprint_resolved: bool = false

## Silk/courtyard graphics attached by the worker's footprint-RESOLVE step
## (pcb/worker/pcb_worker/resolve.py), in component-LOCAL mm coords (same
## frame as `pads[].position`). Each entry is a Dictionary:
##   layer: String  - "F.SilkS" or "F.CrtYd"
##   kind: String    - "line", "circle", "arc", or "poly"
##   width: float    - stroke width in mm
##   start/end: Vector2   (kind == "line")
##   center: Vector2, radius: float   (kind == "circle")
##   points: Array[Vector2], angle: float (optional)  (kind == "arc" or "poly")
var graphics: Array = []

## PRINTED reference designator — the worker-derived stroke-font glyphs the fab
## actually prints on silk (WYSIWYG goal 019ff4a5a75a, gap G2), in the SAME
## footprint-local frame as `graphics`, poly entries only. Kept SEPARATE from
## `graphics` on purpose, in both directions:
##   * inbound, the worker attaches it under its own key because the loose-dict
##     emitters consume comp["graphics"] and then synthesize the designator
##     themselves — merged strokes would print twice;
##   * outbound, to_board_dict must NOT carry it (derived, re-attached by every
##     load's resolve enrichment), while to_dict (panel state) does, so a
##     project restore keeps the printed designator without re-resolving.
var refdes_graphics: Array = []

## Bounding box center offset from footprint origin (for origin-based positioning)
## When has_pad_geometry is true, position = origin, visual center = position + bbox_center_offset
var bbox_center_offset: Vector2 = Vector2.ZERO


## ── Component groups (stage 1) ────────────────────────────────────────────────
## The `properties` key group membership rides in.
##
## PROPERTIES, NOT A NEW TOP-LEVEL FIELD — measured, not stylistic. The legacy
## .minpcb importer (pcb/internal/board/minpcb.go) walks every per-component key
## against `knownComponentFields` and emits
## `component %q: non-canonical field %q preserved as passthrough` for anything
## outside it (minpcb.go:250). `properties` IS in that set and is already carried
## whole, so a group id inside it rides every serialization path — to_dict,
## to_board_dict, the two load halves, undo snapshots, host_owned save/load —
## with no Go change and no per-component warning. A top-level `group_id` would
## have needed the Go map extended, which is out of this round's fence.
const GROUP_PROPERTY_KEY := "group_id"


## This component's group id, or "" when it belongs to no group.
func group_id() -> String:
	return str(properties.get(GROUP_PROPERTY_KEY, ""))


## Is this component a member of a group?
func is_grouped() -> bool:
	return not group_id().is_empty()


## Join a group, or leave one when `gid` is empty.
##
## Leaving ERASES the key rather than storing "": an ungrouped component must
## serialize exactly as it did before groups existed, so a board that was grouped
## and then ungrouped round-trips byte-identical to one that never was.
func set_group_id(gid: String) -> void:
	if gid.is_empty():
		properties.erase(GROUP_PROPERTY_KEY)
	else:
		properties[GROUP_PROPERTY_KEY] = gid


## Get the string name of this component's footprint enum (within-file enum
## access so cross-file callers never touch the enum directly — off-tree safe).
func get_footprint_name() -> String:
	return FootprintType.keys()[footprint]


## Get the canonical authored footprint identity. Library-qualified footprint
## refs live in footprint_id while the panel uses CUSTOM as its rendering enum;
## external formats must emit the authored ref, never that implementation bucket.
func get_canonical_footprint_name() -> String:
	if footprint == FootprintType.CUSTOM and not footprint_id.is_empty():
		return footprint_id
	return get_footprint_name()


## Set footprint enum from a string name; CUSTOM fallback for unknown names.
func set_footprint_by_name(fp_name: String) -> void:
	var idx := FootprintType.keys().find(fp_name)
	footprint = (idx as FootprintType) if idx >= 0 else FootprintType.CUSTOM


## Get the world-space position of a pin using rigid body transform
func get_pin_world_position(pin_name: String) -> Vector2:
	var local_pos: Vector2 = pins.get(pin_name, Vector2.ZERO)
	var xform := get_transform()
	return position + (xform * local_pos)


## Millimetres from `point` to pin `pin_name`'s COPPER: 0.0 anywhere on one of
## its lands, otherwise the gap to the nearest land edge. This is the measure a
## pad PICKER ranks and thresholds on — a click on a 6mm connector land is on
## that pad wherever it lands, which the distance to the pad's CENTRE cannot
## say, and on a board whose pads are not all one size that centre distance
## hands a big pad's own copper to whatever small pad happens to sit nearer.
##
## Never reports MORE than the centre distance, so it can only ever find a pin
## the centre measure also found: `pins[]` and `pads[].position` are two
## separate fields, and a pin whose footprint disagrees with itself must still
## be pickable at the position the rest of the model routes to.
func pin_copper_distance(pin_name: String, point: Vector2) -> float:
	return pin_copper_distance_from(position, get_transform(),
		get_pin_world_position(pin_name), lands_for_pin(pin_name), point)


## The lands of one pin — the `pads` entries carrying its number. A footprint
## may declare several for one electrical pin (a split thermal land), and none
## at all when it never resolved.
func lands_for_pin(pin_name: String) -> Array:
	var out: Array = []
	for pad in pads:
		if str((pad as Dictionary).get("number", "")) == pin_name:
			out.append(pad)
	return out


## The pad-picking rule itself, free of any component instance so a hit-test
## seam holding lands directly measures the same way. `origin`/`xform` are the
## frame the lands are placed in (a component's position / get_transform());
## `centre` is the pin's world position; `pin_lands` its `pads` entries.
static func pin_copper_distance_from(origin: Vector2, xform: Transform2D,
		centre: Vector2, pin_lands: Array, point: Vector2) -> float:
	var best := centre.distance_to(point)
	for land in pin_lands:
		best = minf(best, _land_distance(land as Dictionary, origin, xform, point))
	return best


## Millimetres from `point` to ONE land's copper, 0.0 inside it.
##
## SHAPES, and why the model differs from pcb_ratsnest's land of the same name:
## this is a POINTER measurement, so where the shape cannot be represented
## exactly it errs LARGE (a click on real copper must resolve to it), while the
## ratsnest errs small (copper merely near an island must not read as joined).
##   rect / roundrect / unknown — the oriented rectangle. The authored corner
##     radius is not carried in the model, and the rectangle contains every
##     roundrect of that size; the overhang is at most one corner radius, far
##     under the slack a picker already grants around a pad.
##   circle / oval — the exact stadium: the long-axis segment swollen by the
##     short half-axis, which is a disc when the two sizes are equal.
##
## ROTATION: a land's OFFSET turns with the component only, its BODY with the
## component's rotation and its own — same CW degree convention throughout (see
## get_transform), so the copper is measured where it is fabricated.
static func _land_distance(land: Dictionary, origin: Vector2,
		xform: Transform2D, point: Vector2) -> float:
	var half: Vector2 = (land.get("size", Vector2(1, 1)) as Vector2) * 0.5
	var land_pos: Vector2 = land.get("position", Vector2.ZERO)
	# Into the land's own frame: undo the component transform, then the land's
	# offset, then the land's own rotation. Placing a land turns it by
	# -rotation (CW, as get_transform does), so undoing that turns by +rotation.
	var in_footprint: Vector2 = (xform.affine_inverse() * (point - origin)) - land_pos
	var local := in_footprint.rotated(deg_to_rad(float(land.get("rotation", 0.0))))
	var shape := str(land.get("shape", "rect")).strip_edges().to_lower()
	if shape == "circle" or shape == "oval":
		var radius := minf(half.x, half.y)
		var extent := maxf(half.x, half.y) - radius
		var axis := Vector2(extent, 0.0) if half.x >= half.y else Vector2(0.0, extent)
		var to_axis := Vector2(maxf(absf(local.x) - axis.x, 0.0),
			maxf(absf(local.y) - axis.y, 0.0))
		return maxf(to_axis.length() - radius, 0.0)
	return Vector2(maxf(absf(local.x) - half.x, 0.0),
		maxf(absf(local.y) - half.y, 0.0)).length()


## Get the symbolic name for a pin number (from geometry import)
## Returns empty string if no name is defined
func get_pin_name(pin_number: String) -> String:
	for pad in pads:
		if str(pad.get("number", "")) == pin_number:
			var name = pad.get("name", "")
			if name != null and not str(name).is_empty():
				return str(name)
			break
	return ""


## Get the Transform2D for this component (rotation around anchor/origin)
func get_transform() -> Transform2D:
	# rotation is the canonical rotation_deg, which is defined KiCad-equivalent:
	# KiCad applies a footprint angle as R(radians(-angle)) in board space (its
	# angle is CW in the Y-down file frame). The worker matches this exactly
	# (gerber._rotate / route_bridge / kicad_io all use radians(-rotation_deg)),
	# so the panel MUST too — hence deg_to_rad(-rotation) — or pads/silk/pins
	# desync from the fab for 90/270 parts. Do NOT "fix" this to +rotation: if a
	# board's 90/270 parts land off their traces, the DATA has the wrong-sign
	# rotation (e.g. a stale pre-KiCad-convention negation at import), not this.
	return Transform2D(deg_to_rad(-rotation), Vector2.ZERO)


## Get local body polygon for drawing (4 corners relative to anchor)
func get_local_body_polygon() -> PackedVector2Array:
	return PackedVector2Array([
		local_bounds.position,  # Top-Left
		Vector2(local_bounds.end.x, local_bounds.position.y),  # Top-Right
		local_bounds.end,  # Bottom-Right
		Vector2(local_bounds.position.x, local_bounds.end.y)  # Bottom-Left
	])


## Load pad geometry from pcb-architect footprint-geometry output
## geometry: Dictionary with keys: pads, bounding_box, footprint_id,
##   has_pad_geometry (canonical resolved-vs-fallback marker; Stage 2 step 7).
##   The legacy key ``footprint_found`` is still accepted for older
##   pcb-architect output that predates the rename.
func load_pad_geometry(geometry: Dictionary) -> void:
	footprint_id = geometry.get("footprint_id", "")
	has_pad_geometry = geometry.get("has_pad_geometry", geometry.get("footprint_found", false))

	# Update bounding box from footprint data
	var bbox: Dictionary = geometry.get("bounding_box", {})
	if bbox.size() > 0:
		width = bbox.get("width", width)
		height = bbox.get("height", height)
		# Get the center offset (how far body center is from origin)
		var center_x: float = bbox.get("center_x", 0.0)
		var center_y: float = bbox.get("center_y", 0.0)
		bbox_center_offset = Vector2(center_x, center_y)

		# Calculate local_bounds: Rect2 relative to anchor (0,0)
		# If center is at (cx, cy), then top-left is at (cx - w/2, cy - h/2)
		local_bounds = Rect2(
			center_x - width / 2.0,
			center_y - height / 2.0,
			width,
			height
		)

	# Load pads
	pads.clear()
	var pads_data: Array = geometry.get("pads", [])
	for pad_data in pads_data:
		var pos_dict: Dictionary = pad_data.get("position", {})
		var size_dict: Dictionary = pad_data.get("size", {})

		# Robust drill parsing (handles float, dict, or null)
		var drill_raw = pad_data.get("drill")
		var drill_size := Vector2.ZERO
		if drill_raw is Dictionary:
			# Slot drill: {x, y} or {width, height}
			var dx := float(drill_raw.get("x", drill_raw.get("width", 0.0)))
			var dy := float(drill_raw.get("y", drill_raw.get("height", 0.0)))
			drill_size = Vector2(dx, dy)
		elif drill_raw != null and (drill_raw is float or drill_raw is int):
			var d := float(drill_raw)
			drill_size = Vector2(d, d)

		var pad := {
			"number": pad_data.get("number", ""),
			"name": pad_data.get("name", ""),  # Symbolic pin name from YAML
			"type": pad_data.get("type", "smd"),
			"shape": pad_data.get("shape", "rect"),
			"position": Vector2(pos_dict.get("x", 0), pos_dict.get("y", 0)),
			"size": Vector2(size_dict.get("width", 1), size_dict.get("height", 1)),
			# The pad's own rotation WITHIN the footprint, degrees, same CW
			# convention as the component's rotation_deg. Part of the pad's
			# shape: a 2.0x0.5 pad at rotation 90 is vertical, not horizontal.
			"rotation": float(pad_data.get("rotation", 0.0)),
			"drill": drill_size,  # Now Vector2 for slot support
			"layers": pad_data.get("layers", [])
		}
		pads.append(pad)

	# Also update pins dictionary for net connections (electrical pads only)
	pins.clear()
	for pad in pads:
		var num := str(pad.get("number", ""))
		var ptype := str(pad.get("type", "smd"))
		if num.is_empty():
			continue
		if ptype == "np_thru_hole":
			continue  # Mechanical hole: not an electrical pin
		pins[num] = pad.get("position", Vector2.ZERO)


## Parse a point from either the worker's native `[x, y]` array shape or the
## Godot round-trip `{x:, y:}` dict shape (defensive — `graphics` may arrive
## via either channel; see `_graphics_from_list`).
static func _point_from_any(v) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is Dictionary:
		return Vector2(float(v.get("x", 0.0)), float(v.get("y", 0.0)))
	return Vector2.ZERO


## Serialize the graphics array to a JSON-safe list (shared by to_dict/to_board_dict).
func _graphics_to_list() -> Array:
	var list := []
	for g in graphics:
		var kind: String = g.get("kind", "")
		var entry := {
			"layer": g.get("layer", ""),
			"kind": kind,
			"width": g.get("width", 0.0),
		}
		match kind:
			"line":
				var start: Vector2 = g.get("start", Vector2.ZERO)
				var end: Vector2 = g.get("end", Vector2.ZERO)
				entry["start"] = {"x": start.x, "y": start.y}
				entry["end"] = {"x": end.x, "y": end.y}
			"circle":
				var center: Vector2 = g.get("center", Vector2.ZERO)
				entry["center"] = {"x": center.x, "y": center.y}
				entry["radius"] = g.get("radius", 0.0)
			"arc", "poly":
				var pts_list := []
				for pt in g.get("points", []):
					var p: Vector2 = pt
					pts_list.append({"x": p.x, "y": p.y})
				entry["points"] = pts_list
				if g.has("angle"):
					entry["angle"] = g["angle"]
		list.append(entry)
	return list


## Serialize/deserialize the printed-designator strokes (poly-only). The dict
## shape matches graphics poly entries so a future merge stays trivial.
func _refdes_to_list() -> Array:
	var list := []
	for g in refdes_graphics:
		var pts_list := []
		for pt in g.get("points", []):
			var pv: Vector2 = pt
			pts_list.append({"x": pv.x, "y": pv.y})
		list.append({"layer": g.get("layer", "F.SilkS"), "kind": "poly",
			"points": pts_list, "width": g.get("width", 0.15)})
	return list


func _refdes_from_list(list_data: Array) -> void:
	refdes_graphics.clear()
	for g_data in list_data:
		if not (g_data is Dictionary):
			continue
		var pts: Array = []
		for pt_data in g_data.get("points", []):
			pts.append(_point_from_any(pt_data))
		if pts.size() < 2:
			continue
		refdes_graphics.append({
			"layer": str(g_data.get("layer", "F.SilkS")),
			"kind": "poly",
			"width": float(g_data.get("width", 0.15)) if g_data.get("width") != null else 0.15,
			"points": pts,
		})


## Deserialize a graphics list (shared by from_dict/from_board_dict) into
## `graphics`, normalizing points to Vector2 regardless of source shape
## (worker `[x,y]` arrays vs. round-tripped `{x:,y:}` dicts).
func _graphics_from_list(graphics_data: Array) -> void:
	graphics.clear()
	for g_data in graphics_data:
		if not (g_data is Dictionary):
			continue
		var kind: String = str(g_data.get("kind", ""))
		var entry := {
			"layer": str(g_data.get("layer", "")),
			"kind": kind,
			"width": float(g_data.get("width", 0.0)) if g_data.get("width") != null else 0.0,
		}
		match kind:
			"line":
				entry["start"] = _point_from_any(g_data.get("start", Vector2.ZERO))
				entry["end"] = _point_from_any(g_data.get("end", Vector2.ZERO))
			"circle":
				entry["center"] = _point_from_any(g_data.get("center", Vector2.ZERO))
				entry["radius"] = float(g_data.get("radius", 0.0))
			"arc", "poly":
				var pts: Array = []
				for pt_data in g_data.get("points", []):
					pts.append(_point_from_any(pt_data))
				entry["points"] = pts
				if g_data.has("angle") and g_data["angle"] != null:
					entry["angle"] = float(g_data["angle"])
		graphics.append(entry)


## Compute the axis-aligned bbox (component-LOCAL mm, same frame as
## `pads[].position`) of every `graphics` entry on the given layer
## ("F.CrtYd" / "F.SilkS"). Returns null when no entry on that layer exists,
## or the extent degenerates to zero width/height (a stray single-point
## entry, not real body geometry) — callers treat null as "no usable bounds
## on this layer, try the next fallback".
func _graphics_layer_bounds(layer_name: String):
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	var found := false
	for g in graphics:
		if str(g.get("layer", "")) != layer_name:
			continue
		match str(g.get("kind", "")):
			"line":
				var s: Vector2 = g.get("start", Vector2.ZERO)
				var e: Vector2 = g.get("end", Vector2.ZERO)
				min_p.x = minf(min_p.x, minf(s.x, e.x))
				min_p.y = minf(min_p.y, minf(s.y, e.y))
				max_p.x = maxf(max_p.x, maxf(s.x, e.x))
				max_p.y = maxf(max_p.y, maxf(s.y, e.y))
				found = true
			"circle":
				var c: Vector2 = g.get("center", Vector2.ZERO)
				var r: float = float(g.get("radius", 0.0))
				min_p.x = minf(min_p.x, c.x - r)
				min_p.y = minf(min_p.y, c.y - r)
				max_p.x = maxf(max_p.x, c.x + r)
				max_p.y = maxf(max_p.y, c.y + r)
				found = true
			"arc", "poly":
				for pt in g.get("points", []):
					var p: Vector2 = pt
					min_p.x = minf(min_p.x, p.x)
					min_p.y = minf(min_p.y, p.y)
					max_p.x = maxf(max_p.x, p.x)
					max_p.y = maxf(max_p.y, p.y)
					found = true
	if not found or max_p.x <= min_p.x or max_p.y <= min_p.y:
		return null
	return Rect2(min_p, max_p - min_p)


## Derive local_bounds (and width/height, kept in sync so label placement and
## other width/height readers agree) from the F.CrtYd graphics extent, falling
## back to the F.SilkS bbox when the footprint carries no courtyard. LOCAL
## frame, pre-rotation — `graphics` is already component-local mm, the same
## frame local_bounds lives in, so no transform is applied here.
## Returns true when a derived bounds was applied, false when `graphics` had
## neither layer (caller keeps whatever local_bounds it already computed).
func _derive_bounds_from_graphics() -> bool:
	var bounds = _graphics_layer_bounds("F.CrtYd")
	if bounds == null:
		bounds = _graphics_layer_bounds("F.SilkS")
	if bounds == null:
		return false
	local_bounds = bounds
	width = bounds.size.x
	height = bounds.size.y
	return true


## Get a pad's world-space position and size, accounting for component rotation
func get_pad_world_transform(pad: Dictionary) -> Dictionary:
	var rot_rad := deg_to_rad(rotation)
	var local_pos: Vector2 = pad.get("position", Vector2.ZERO)
	var local_size: Vector2 = pad.get("size", Vector2(1, 1))

	# Rotate position around component center
	var world_pos := position + local_pos.rotated(rot_rad)

	# For 90/270 rotation, swap width and height
	var world_size := local_size
	if int(rotation) % 180 == 90:
		world_size = Vector2(local_size.y, local_size.x)

	return {
		"position": world_pos,
		"size": world_size,
		"rotation": rotation
	}


## Get all pin world positions
func get_all_pin_positions() -> Dictionary:
	var result: Dictionary = {}
	for pin_name in pins:
		result[pin_name] = get_pin_world_position(pin_name)
	return result


## Get the bounding rectangle in world space
func get_bounding_rect() -> Rect2:
	# Use rigid body transform for consistent rotation
	var xform := get_transform()
	var local_poly := get_local_body_polygon()

	# Transform corners and find axis-aligned bounds
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)

	for corner in local_poly:
		var world_point: Vector2 = position + (xform * corner)
		min_pos.x = minf(min_pos.x, world_point.x)
		min_pos.y = minf(min_pos.y, world_point.y)
		max_pos.x = maxf(max_pos.x, world_point.x)
		max_pos.y = maxf(max_pos.y, world_point.y)

	return Rect2(min_pos, max_pos - min_pos)


## Check if a point is inside this component's bounding rect
func contains_point(point: Vector2) -> bool:
	return get_bounding_rect().has_point(point)


## Set position (for undo/redo support)
func set_position(new_pos: Vector2) -> void:
	position = new_pos


## Set rotation (constrained to 0, 90, 180, 270)
func set_rotation(degrees: float) -> void:
	rotation = snap_rotation(degrees)


## The model's SINGLE rotation-quantization authority: normalize into [0, 360)
## then snap to the nearest multiple of 90. Static so pcb_data.rotate_group can
## snap a rigid-body delta through the same rule bodies use — the two halves of
## a group rotation must never disagree (cold-review A4 finding 1).
static func snap_rotation(degrees: float) -> float:
	var normalized := fmod(degrees, 360.0)
	if normalized < 0:
		normalized += 360.0
	return roundf(normalized / 90.0) * 90.0


## Rotate clockwise by 90 degrees
func rotate_clockwise() -> void:
	set_rotation(rotation + 90.0)


## Rotate counter-clockwise by 90 degrees
func rotate_counterclockwise() -> void:
	set_rotation(rotation - 90.0)


## Initialize standard pin layout for common footprints
## KiCAD convention: Pin 1 at origin (0,0), body extends from there
func setup_standard_pins() -> void:
	pins.clear()

	match footprint:
		FootprintType.RESISTOR, FootprintType.CAPACITOR, FootprintType.DIODE, FootprintType.LED:
			# Two-terminal component, horizontal, pin 1 at origin
			width = 3.0
			height = 1.5
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(2.54, 0)
			local_bounds = Rect2(-0.5, -height / 2.0, width, height)
			bbox_center_offset = Vector2(1.27, 0)

		FootprintType.TRANSISTOR:
			# Three-terminal (TO-92 style), pin 1 at origin
			width = 3.0
			height = 2.0
			pins["B"] = Vector2(0, 0)
			pins["C"] = Vector2(1.27, 0)
			pins["E"] = Vector2(2.54, 0)
			local_bounds = Rect2(-0.5, -height / 2.0, width, height)
			bbox_center_offset = Vector2(1.27, 0)

		FootprintType.IC_DIP:
			# 8-pin DIP as default, pin 1 at origin (top-left)
			var row_spacing := 7.62
			var pins_per_side := 4
			var total_height := (pins_per_side - 1) * 2.54
			width = row_spacing + 2.54
			height = total_height + 2.54
			for i in range(pins_per_side):
				pins[str(i + 1)] = Vector2(0, i * 2.54)
				pins[str(8 - i)] = Vector2(row_spacing, i * 2.54)
			local_bounds = Rect2(-1.27, -1.27, width, height)
			bbox_center_offset = Vector2(row_spacing / 2.0, total_height / 2.0)

		FootprintType.SWITCH:
			# Simple push button, pin 1 at origin (top-left)
			width = 6.0
			height = 6.0
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(5.08, 0)
			pins["3"] = Vector2(0, 5.08)
			pins["4"] = Vector2(5.08, 5.08)
			local_bounds = Rect2(-0.5, -0.5, width, height)
			bbox_center_offset = Vector2(2.54, 2.54)

		FootprintType.CONNECTOR, FootprintType.HEADER:
			# 2-pin header as default, vertical, pin 1 at origin
			width = 2.54
			height = 2.54 + 2.54
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(0, 2.54)
			local_bounds = Rect2(-width / 2.0, -1.27, width, height)
			bbox_center_offset = Vector2(0, 1.27)

		FootprintType.MOUNTING_HOLE:
			# Mounting hole - single pin at origin
			width = 3.2
			height = 3.2
			pins["1"] = Vector2(0, 0)
			local_bounds = Rect2(-width / 2.0, -height / 2.0, width, height)
			bbox_center_offset = Vector2.ZERO

		FootprintType.MODULE:
			# Large module (like ESP32 dev board) - default 2x20 pins
			# Pin 1 at origin (top-left), body extends beyond pin rows
			var row_spacing := 22.86  # ~0.9" for dev boards
			var pins_per_side := 20
			var body_extension := 9.0  # Body extends beyond pins on each end
			var total_pin_height := (pins_per_side - 1) * 2.54
			width = row_spacing + 2.54
			height = total_pin_height + (body_extension * 2)
			for i in range(pins_per_side):
				pins[str(i + 1)] = Vector2(0, i * 2.54)
				pins[str(40 - i)] = Vector2(row_spacing, i * 2.54)
			local_bounds = Rect2(-1.27, -body_extension, width, height)
			bbox_center_offset = Vector2(row_spacing / 2.0, total_pin_height / 2.0)

		FootprintType.CRYSTAL:
			# Crystal oscillator, pin 1 at origin
			width = 5.0
			height = 2.0
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(4.0, 0)
			local_bounds = Rect2(-0.5, -height / 2.0, width, height)
			bbox_center_offset = Vector2(2.0, 0)

		_:
			# Default fallback
			width = 5.0
			height = 2.5
			pins["1"] = Vector2(0, 0)
			local_bounds = Rect2(-1.0, -height / 2.0, width, height)
			bbox_center_offset = Vector2(width / 2.0 - 1.0, 0)


## Setup a single-row header/connector with custom pin count
## KiCAD convention: Vertical orientation, pin 1 at origin (0,0), pins going down (+Y)
func setup_header_pins(pin_count: int, pin_names: Array = []) -> void:
	pins.clear()
	var spacing := 2.54  # Standard 0.1" spacing
	var total_length := (pin_count - 1) * spacing
	# Vertical orientation: width is narrow, height is long
	width = 2.54
	height = total_length + 2.54

	for i in range(pin_count):
		var pin_name: String
		if i < pin_names.size():
			pin_name = str(pin_names[i])
		else:
			pin_name = str(i + 1)
		# Pin 1 at origin (0, 0), subsequent pins going down (+Y)
		pins[pin_name] = Vector2(0, i * spacing)

	# local_bounds relative to pin 1 origin: body centered on X, extends down from pin 1
	local_bounds = Rect2(-width / 2.0, -1.27, width, height)
	# Calculate center offset from origin for compatibility
	bbox_center_offset = Vector2(0, total_length / 2.0)


## Setup a dual-row DIP with custom pin count (must be even)
## KiCAD convention: Pin 1 at origin (0,0) top-left, left side going down, right side going up
func setup_dip_pins(pin_count: int, row_spacing: float = 7.62) -> void:
	pins.clear()
	@warning_ignore("integer_division")
	var pins_per_side := pin_count / 2
	var spacing := 2.54
	var total_pin_height := (pins_per_side - 1) * spacing
	width = row_spacing + 2.54
	height = total_pin_height + 2.54

	for i in range(pins_per_side):
		# Left side: 1, 2, 3... going down from origin
		# Pin 1 at (0, 0), Pin 2 at (0, 2.54), etc.
		pins[str(i + 1)] = Vector2(0, i * spacing)
		# Right side: N, N-1, N-2... going up from bottom-right
		# Pin N at (row_spacing, 0), Pin N-1 at (row_spacing, 2.54), etc.
		pins[str(pin_count - i)] = Vector2(row_spacing, i * spacing)

	# local_bounds relative to pin 1 origin: extends right and down from origin
	local_bounds = Rect2(-1.27, -1.27, width, height)
	# Calculate center offset from origin
	bbox_center_offset = Vector2(row_spacing / 2.0, total_pin_height / 2.0)


## Setup a large module (ESP32 dev boards, etc.) with custom pin count
## KiCAD convention: Pin 1 at origin (0,0), body extends beyond pin rows
## row_spacing: distance between pin rows (default ~22.86mm for dev boards)
## body_extension: how much the body extends beyond pin rows on each end
func setup_module_pins(pin_count: int, row_spacing: float = 22.86, body_extension: float = 9.0) -> void:
	pins.clear()
	@warning_ignore("integer_division")
	var pins_per_side := pin_count / 2
	var spacing := 2.54
	var total_pin_height := (pins_per_side - 1) * spacing

	# Body dimensions - wider than DIP, extends beyond pins
	width = row_spacing + 2.54
	# Height: pin area + extension on both ends
	height = total_pin_height + (body_extension * 2)

	for i in range(pins_per_side):
		# Left side: 1, 2, 3... going down from origin
		pins[str(i + 1)] = Vector2(0, i * spacing)
		# Right side: N, N-1, N-2... going up from bottom-right
		pins[str(pin_count - i)] = Vector2(row_spacing, i * spacing)

	# local_bounds: body extends beyond pins
	# Top edge at -body_extension (above pin 1), bottom at total_pin_height + body_extension
	local_bounds = Rect2(-1.27, -body_extension, width, height)
	# Center offset from pin 1 origin
	bbox_center_offset = Vector2(row_spacing / 2.0, total_pin_height / 2.0)


## Generic pin layout for any footprint type.
## Works when none of the specialised methods (header, DIP, module) apply.
##   pin_count  – number of pads (>= 1)
##   pad_type   – "smd" or "tht" (affects pad/body sizing)
##   spacing    – centre-to-centre pin pitch in mm (default 2.54)
##   row_sp     – distance between dual rows in mm (default 7.62)
func setup_generic_pins(pin_count: int, pad_type: String = "tht", spacing: float = 2.54, row_sp: float = 7.62) -> void:
	pins.clear()

	var is_smd := (pad_type == "smd")
	# Pad body margin – THT pads are slightly larger than SMD
	var pad_margin := 1.0 if is_smd else 1.27

	if pin_count == 1:
		# Single centred pad (mounting-hole style)
		width = 3.2
		height = 3.2
		pins["1"] = Vector2(0, 0)
		local_bounds = Rect2(-width / 2.0, -height / 2.0, width, height)
		bbox_center_offset = Vector2.ZERO

	elif pin_count <= 3:
		# Inline horizontal row
		var total_length := (pin_count - 1) * spacing
		width = total_length + pad_margin * 2
		height = pad_margin * 2
		for i in range(pin_count):
			pins[str(i + 1)] = Vector2(i * spacing, 0)
		local_bounds = Rect2(-pad_margin, -height / 2.0, width, height)
		bbox_center_offset = Vector2(total_length / 2.0, 0)

	elif pin_count % 2 == 0:
		# Even pin count >= 4 → dual-row (DIP-like)
		@warning_ignore("integer_division")
		var pins_per_side := pin_count / 2
		var total_pin_height := (pins_per_side - 1) * spacing
		width = row_sp + pad_margin * 2
		height = total_pin_height + pad_margin * 2
		for i in range(pins_per_side):
			pins[str(i + 1)] = Vector2(0, i * spacing)
			pins[str(pin_count - i)] = Vector2(row_sp, i * spacing)
		local_bounds = Rect2(-pad_margin, -pad_margin, width, height)
		bbox_center_offset = Vector2(row_sp / 2.0, total_pin_height / 2.0)

	else:
		# Odd pin count >= 5 → single-row vertical (header-like)
		var total_length := (pin_count - 1) * spacing
		width = pad_margin * 2
		height = total_length + pad_margin * 2
		for i in range(pin_count):
			pins[str(i + 1)] = Vector2(0, i * spacing)
		local_bounds = Rect2(-width / 2.0, -pad_margin, width, height)
		bbox_center_offset = Vector2(0, total_length / 2.0)


## Setup custom size without changing pins
## Maintains origin-based positioning (body extends from near origin)
func set_size(new_width: float, new_height: float) -> void:
	width = new_width
	height = new_height
	# Update local_bounds - body starts slightly before origin, extends right/down
	# Use small margin (-1.27mm) to allow pin 1 to be inside the body
	local_bounds = Rect2(-1.27, -1.27, width, height)
	# Update center offset
	bbox_center_offset = Vector2(width / 2.0 - 1.27, height / 2.0 - 1.27)


## Create a deep copy of this component
func duplicate_component():
	var copy = _Self.new()
	copy.id = id
	copy.footprint = footprint
	copy.position = position
	copy.rotation = rotation
	copy.width = width
	copy.height = height
	copy.pins = pins.duplicate(true)
	copy.properties = properties.duplicate(true)
	copy.layer = layer
	copy.color = color
	copy.label_visible = label_visible
	copy.footprint_id = footprint_id
	copy.pads = pads.duplicate(true)
	copy.has_pad_geometry = has_pad_geometry
	copy.graphics = graphics.duplicate(true)
	copy.bbox_center_offset = bbox_center_offset
	copy.local_bounds = local_bounds
	copy.locked = locked
	# Canonical passthrough rides every copy path too — a duplicated component
	# that lost `assembly: exclude` or its pins' drill/annulus overrides would
	# be a different PART, silently (Codex review 1086 finding 3's class).
	copy.canonical_extra = canonical_extra.duplicate(true)
	copy.pin_extra = pin_extra.duplicate(true)
	return copy


## Serialize the pads array to a JSON-safe list (shared by to_dict/to_board_dict).
func _pads_to_list() -> Array:
	var pads_list := []
	for pad in pads:
		var pad_pos: Vector2 = pad.get("position", Vector2.ZERO)
		var pad_size: Vector2 = pad.get("size", Vector2(1, 1))
		var drill_val = pad.get("drill", Vector2.ZERO)
		var drill_dict: Dictionary
		if drill_val is Vector2:
			drill_dict = {"x": drill_val.x, "y": drill_val.y}
		else:
			# Legacy: float drill value
			var d := float(drill_val) if drill_val != null else 0.0
			drill_dict = {"x": d, "y": d}
		var entry := {
			"number": pad.get("number", ""),
			"type": pad.get("type", "smd"),
			"shape": pad.get("shape", "rect"),
			"position": {"x": pad_pos.x, "y": pad_pos.y},
			"size": {"width": pad_size.x, "height": pad_size.y},
			"drill": drill_dict,
			"layers": pad.get("layers", [])
		}
		# Emitted only when set, matching the worker's own omit-zero convention
		# for this key — an unrotated pad's serialized shape stays unchanged.
		var pad_rotation := float(pad.get("rotation", 0.0))
		if pad_rotation != 0.0:
			entry["rotation"] = pad_rotation
		pads_list.append(entry)
	return pads_list


## Deserialize a pads list (shared by from_dict/from_board_dict) into `pads`.
func _pads_from_list(pads_data: Array) -> void:
	pads.clear()
	for pad_data in pads_data:
		var pad_pos: Dictionary = pad_data.get("position", {})
		var pad_size: Dictionary = pad_data.get("size", {})
		# U4 (019f9509a54c): a resolved pad with no authored geometry now arrives
		# as size: {width: null, height: null} (worker no longer fabricates a
		# 1.0x1.0mm land — see pcb_worker/resolve.py::_pads_from_parsed). Dictionary
		# .get(key, default) only returns `default` when the KEY IS ABSENT; a
		# key present with a stored null value comes back as null, not 1 — so an
		# un-guarded Vector2(pad_size.get("width", 1), ...) would construct
		# Vector2(null, null) and error. Treat a null dimension as "no pad
		# geometry" the SAME way _pads_from_canonical_pins treats a bare
		# positional pin (no drill, no width/height): skip the render pad
		# entirely rather than inventing a size here too.
		var size_w = pad_size.get("width", 1)
		var size_h = pad_size.get("height", 1)
		if size_w == null or size_h == null:
			continue
		# Handle both legacy float drill and new Vector2 dict drill
		var drill_raw = pad_data.get("drill", 0.0)
		var drill_vec := Vector2.ZERO
		if drill_raw is Dictionary:
			drill_vec = Vector2(drill_raw.get("x", 0), drill_raw.get("y", 0))
		elif drill_raw is float or drill_raw is int:
			var d := float(drill_raw)
			drill_vec = Vector2(d, d)
		pads.append({
			"number": pad_data.get("number", ""),
			"type": pad_data.get("type", "smd"),
			"shape": pad_data.get("shape", "rect"),
			"position": Vector2(pad_pos.get("x", 0), pad_pos.get("y", 0)),
			"size": Vector2(size_w, size_h),
			# The pad's own rotation WITHIN the footprint, degrees, same CW
			# convention as the component's rotation_deg. Part of the pad's
			# shape: a 2.0x0.5 pad at rotation 90 is vertical, not horizontal.
			"rotation": float(pad_data.get("rotation", 0.0)),
			"drill": drill_vec,
			"layers": pad_data.get("layers", [])
		})


## Synthesize render pads from geometry-bearing canonical pins. Worker-authored
## boards express pad geometry ON the pins (drill_mm/annulus_diameter_mm for
## through-hole, pad_width_mm/pad_height_mm for SMD) and carry no separate `pads`
## array, so load_from_board_dict falls back here. Produces the same internal pad
## shape as _pads_from_list. When fit_body is true (the dict gave no width/height)
## the body box is fitted to the synthesized pad extents.
func _pads_from_canonical_pins(pin_list: Array, fit_body: bool) -> void:
	pads.clear()
	var copper_layer := "B.Cu" if layer == "bottom" else "F.Cu"
	var synthesized := false
	for pd in pin_list:
		if not (pd is Dictionary):
			continue
		var pos := Vector2(float(pd.get("x_mm", 0.0)), float(pd.get("y_mm", 0.0)))
		var drill := float(pd.get("drill_mm", 0.0))
		var annulus := float(pd.get("annulus_diameter_mm", 0.0))
		var pw := float(pd.get("pad_width_mm", 0.0))
		var ph := float(pd.get("pad_height_mm", 0.0))
		var pad := {
			"number": str(pd.get("number", "")),
			"name": str(pd.get("name", "")),
			"position": pos,
		}
		if drill > 0.0:
			var d := annulus if annulus > 0.0 else drill * 2.0
			# "thru_hole" (NOT "tht") — this is the pad's stored type field, whose
			# vocabulary is smd/thru_hole/np_thru_hole (see the pad-shape docstring
			# above). The canvas gates the drill-hole render on
			# pad_type in ["thru_hole","np_thru_hole"] (pcb_canvas _draw_component_pads);
			# emitting "tht" here left load_board THT pads rendering as solid discs
			# with no hole. "tht" is only the setup_generic_pins SIZING argument, not
			# a stored type. (Bug 019f75c24bd2.)
			pad["type"] = "thru_hole"
			pad["shape"] = "circle"
			pad["size"] = Vector2(d, d)
			pad["drill"] = Vector2(drill, drill)
			pad["layers"] = ["F.Cu", "B.Cu"]
		elif pw > 0.0 or ph > 0.0:
			pad["type"] = "smd"
			pad["shape"] = "rect"
			pad["size"] = Vector2(pw if pw > 0.0 else 1.0, ph if ph > 0.0 else 1.0)
			pad["drill"] = Vector2.ZERO
			pad["layers"] = [copper_layer]
		else:
			# Bare positional pin (no pad geometry) — no render pad.
			continue
		pads.append(pad)
		synthesized = true
	if synthesized:
		has_pad_geometry = true
		if fit_body:
			_fit_body_to_pads()


## Fit the body box (width/height/local_bounds/bbox_center_offset) to the current
## pad extents — used when a canonical board provided pad geometry but no explicit
## body dimensions (worker-authored boards).
func _fit_body_to_pads() -> void:
	if pads.is_empty():
		return
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for pad in pads:
		var pos: Vector2 = pad.get("position", Vector2.ZERO)
		var sz: Vector2 = pad.get("size", Vector2.ZERO)
		min_p.x = minf(min_p.x, pos.x - sz.x / 2.0)
		min_p.y = minf(min_p.y, pos.y - sz.y / 2.0)
		max_p.x = maxf(max_p.x, pos.x + sz.x / 2.0)
		max_p.y = maxf(max_p.y, pos.y + sz.y / 2.0)
	width = max_p.x - min_p.x
	height = max_p.y - min_p.y
	local_bounds = Rect2(min_p.x, min_p.y, width, height)
	bbox_center_offset = (min_p + max_p) * 0.5


## Serialize to dictionary (legacy .minpcb shape — undo snapshots + Round-B)
func to_dict() -> Dictionary:
	var pins_dict := {}
	for pin_name in pins:
		var pin_pos: Vector2 = pins[pin_name]
		pins_dict[pin_name] = {"x": pin_pos.x, "y": pin_pos.y}

	return {
		"id": id,
		"footprint": get_footprint_name(),
		"footprint_id": footprint_id,
		"position": {"x": position.x, "y": position.y},
		"rotation": rotation,
		"width": width,
		"height": height,
		"local_bounds": {"x": local_bounds.position.x, "y": local_bounds.position.y, "w": local_bounds.size.x, "h": local_bounds.size.y},
		"pins": pins_dict,
		"pads": _pads_to_list(),
		"has_pad_geometry": has_pad_geometry,
		"footprint_resolved": footprint_resolved,
		"graphics": _graphics_to_list(),
		"refdes_graphics": _refdes_to_list(),
		"bbox_center_offset": {"x": bbox_center_offset.x, "y": bbox_center_offset.y},
		"properties": properties.duplicate(),
		"layer": layer,
		"color": {"r": color.r, "g": color.g, "b": color.b, "a": color.a},
		"label_visible": label_visible,
		"locked": locked,
		# CANONICAL PASSTHROUGH ON THE LEGACY CODEC (Codex review 1086 finding 3).
		# This shape is not just the .minpcb file format — PCBData._serialize_
		# components uses it for UNDO HISTORY, and history round-trips
		# reconstruct components from it. Without these two keys an undo after
		# a canonical load silently erased `assembly: exclude`, `mpn`, and pin
		# drill/annulus overrides, and the next promote wrote that loss to the
		# design of record. Nested under one key each so they cannot collide
		# with a legacy field name.
		"canonical_extra": canonical_extra.duplicate(true),
		"pin_extra": pin_extra.duplicate(true)
	}


## Deserialize from dictionary (legacy .minpcb shape)
func load_from_dict(data: Dictionary) -> void:
	id = data.get("id", "")
	set_footprint_by_name(str(data.get("footprint", "CUSTOM")))
	footprint_id = data.get("footprint_id", "")

	var pos_data: Dictionary = data.get("position", {})
	position = Vector2(pos_data.get("x", 0), pos_data.get("y", 0))

	rotation = data.get("rotation", 0.0)
	width = data.get("width", 5.0)
	height = data.get("height", 2.5)

	# Load local_bounds or compute from width/height
	var bounds_data: Dictionary = data.get("local_bounds", {})
	if bounds_data.size() > 0:
		local_bounds = Rect2(
			bounds_data.get("x", -width / 2.0),
			bounds_data.get("y", -height / 2.0),
			bounds_data.get("w", width),
			bounds_data.get("h", height)
		)
	else:
		# Default: centered at anchor
		local_bounds = Rect2(-width / 2.0, -height / 2.0, width, height)

	pins.clear()
	var pins_data: Dictionary = data.get("pins", {})
	for pin_name in pins_data:
		var pin_pos_data: Dictionary = pins_data[pin_name]
		pins[pin_name] = Vector2(pin_pos_data.get("x", 0), pin_pos_data.get("y", 0))

	# Load pad geometry
	has_pad_geometry = data.get("has_pad_geometry", false)
	footprint_resolved = bool(data.get("footprint_resolved", false))
	var bbox_offset_data: Dictionary = data.get("bbox_center_offset", {})
	bbox_center_offset = Vector2(bbox_offset_data.get("x", 0), bbox_offset_data.get("y", 0))
	_pads_from_list(data.get("pads", []))
	_graphics_from_list(data.get("graphics", []))
	_refdes_from_list(data.get("refdes_graphics", []))

	# U1-render unit 2: when the snapshot gave no explicit size (no local_bounds,
	# no width/height Extra), replace the untouched default/centered bounds with
	# the real courtyard/silk extent. Explicit width/height or local_bounds in
	# `data` always wins — checked the same way as `data.has(...)` above, never
	# by comparing against a hardcoded default value.
	if bounds_data.is_empty() and not data.has("width") and not data.has("height"):
		_derive_bounds_from_graphics()

	properties = data.get("properties", {}).duplicate()
	layer = data.get("layer", "top")

	var color_data: Dictionary = data.get("color", {})
	if color_data.size() > 0:
		color = Color(
			color_data.get("r", 0.2),
			color_data.get("g", 0.6),
			color_data.get("b", 0.3),
			color_data.get("a", 1.0)
		)

	label_visible = data.get("label_visible", true)
	locked = data.get("locked", false)
	# Restore the canonical passthrough (Codex review 1086 finding 3) — the
	# write half is in to_dict(). Absent keys leave EMPTY dicts rather than
	# stale state: a legacy .minpcb that predates these fields genuinely has
	# no extras, and inheriting the previous component's would be worse than
	# having none.
	var ce = data.get("canonical_extra", {})
	canonical_extra = (ce as Dictionary).duplicate(true) if ce is Dictionary else {}
	var pe = data.get("pin_extra", {})
	pin_extra = (pe as Dictionary).duplicate(true) if pe is Dictionary else {}


## Create from dictionary (static constructor, legacy shape)
static func from_dict(data: Dictionary):
	var component := _Self.new()
	component.load_from_dict(data)
	return component


# ── Canonical boundary (pcb/internal/board Component) ─────────────────────────
# Canonical fields: ref / footprint / value / x_mm / y_mm / rotation_deg / layer
# / pins:[{number,x_mm,y_mm}]. Render detail is emitted as canonical "Extra"
# (sibling keys) — the exact set minpcb.go parks in Component.Extra so YAML
# round-trips it losslessly. Value is dual-written (canonical `value` + inside
# `properties`) mirroring minpcb.go, which extracts properties.value → Value AND
# still parks properties.

## Serialize to a canonical board-contract component dict.
func to_board_dict() -> Dictionary:
	var d := {
		"ref": id,
		"footprint": get_canonical_footprint_name(),
		"x_mm": position.x,
		"y_mm": position.y,
		"rotation_deg": rotation,
		"layer": layer,
	}
	var val := str(properties.get("value", ""))
	if not val.is_empty():
		d["value"] = val

	# Re-emit the preserved canonical extras (assembly, mpn, ...) — knowns win
	# on any collision, so a stale extra can never clobber a modeled field.
	for extra_key in canonical_extra:
		if not d.has(extra_key):
			d[extra_key] = canonical_extra[extra_key]

	# pins: name→offset map → sorted list of {number, x_mm, y_mm} + each pin's
	# preserved fab-geometry extras (drill_mm/annulus_diameter_mm/...).
	var pin_keys := pins.keys()
	pin_keys.sort()
	var pin_list := []
	for k in pin_keys:
		var p: Vector2 = pins[k]
		var pin_dict := {"number": str(k), "x_mm": p.x, "y_mm": p.y}
		var extras: Dictionary = pin_extra.get(str(k), {})
		for ek in extras:
			if not pin_dict.has(ek):
				pin_dict[ek] = extras[ek]
		pin_list.append(pin_dict)
	d["pins"] = pin_list

	# Canonical Extra (render detail — mirrors minpcb.go knownComponentFields).
	d["footprint_id"] = footprint_id
	d["width"] = width
	d["height"] = height
	d["local_bounds"] = {
		"x": local_bounds.position.x, "y": local_bounds.position.y,
		"w": local_bounds.size.x, "h": local_bounds.size.y}
	d["pads"] = _pads_to_list()
	d["has_pad_geometry"] = has_pad_geometry
	d["graphics"] = _graphics_to_list()
	d["bbox_center_offset"] = {"x": bbox_center_offset.x, "y": bbox_center_offset.y}
	d["properties"] = properties.duplicate()
	d["color"] = {"r": color.r, "g": color.g, "b": color.b, "a": color.a}
	d["label_visible"] = label_visible
	d["locked"] = locked
	return d


## Restore from a canonical board-contract component dict.
func load_from_board_dict(data: Dictionary) -> void:
	id = str(data.get("ref", data.get("id", "")))
	var authored_fp := str(data.get("footprint", "CUSTOM"))
	set_footprint_by_name(authored_fp)
	footprint_id = str(data.get("footprint_id", ""))
	# Read-side ref preservation (docket 019fcb32d81c / the 019fa9640ac1 hard
	# prerequisite): a canonical library ref ("Lib:Name") is no enum name, so
	# set_footprint_by_name maps it to CUSTOM — and without keeping the
	# authored string, to_board_dict could only ever hand the worker "CUSTOM",
	# which the hermetic compiler refuses. An explicit footprint_id from the
	# Extra round-trip wins; otherwise the authored ref IS the identity.
	if footprint_id.is_empty() and footprint == FootprintType.CUSTOM and authored_fp != "CUSTOM":
		footprint_id = authored_fp
	position = Vector2(float(data.get("x_mm", 0.0)), float(data.get("y_mm", 0.0)))
	rotation = float(data.get("rotation_deg", 0.0))
	layer = str(data.get("layer", "top"))
	width = float(data.get("width", 5.0))
	height = float(data.get("height", 2.5))

	var bounds_data: Dictionary = data.get("local_bounds", {})
	if bounds_data.size() > 0:
		local_bounds = Rect2(
			bounds_data.get("x", -width / 2.0),
			bounds_data.get("y", -height / 2.0),
			bounds_data.get("w", width),
			bounds_data.get("h", height))
	else:
		local_bounds = Rect2(-width / 2.0, -height / 2.0, width, height)

	# pins: canonical list of {number,x_mm,y_mm} → name→offset map. Every key
	# BEYOND number/x_mm/y_mm (drill_mm, annulus_diameter_mm, plated,
	# pad_width_mm, pad_height_mm, name, ...) is AUTHORED FAB GEOMETRY the
	# model does not represent — preserved per pin and re-emitted verbatim by
	# to_board_dict. Epoch CPN1 found the loss live: the coupon's TP1
	# min-annular override (drill 0.6 / annulus 0.96) silently reverted to the
	# library default across the first real promote, killing the witness the
	# board exists to carry.
	pins.clear()
	pin_extra.clear()
	var pin_list: Array = data.get("pins", [])
	for pd in pin_list:
		if pd is Dictionary:
			var pnum := str(pd.get("number", ""))
			pins[pnum] = Vector2(
				float(pd.get("x_mm", 0.0)), float(pd.get("y_mm", 0.0)))
			var extras := {}
			for k in (pd as Dictionary):
				if k not in ["number", "x_mm", "y_mm"]:
					extras[k] = pd[k]
			if not extras.is_empty():
				pin_extra[pnum] = extras

	has_pad_geometry = data.get("has_pad_geometry", false)
	footprint_resolved = bool(data.get("footprint_resolved", false))
	var bbox_offset_data: Dictionary = data.get("bbox_center_offset", {})
	bbox_center_offset = Vector2(bbox_offset_data.get("x", 0), bbox_offset_data.get("y", 0))
	# Render pads: editor-authored boards carry an explicit `pads` array (render
	# detail parked in canonical Extra). Worker-authored boards (the worker
	# canonical YAML) instead carry pad geometry ON the pins themselves and have
	# NO `pads` array — synthesize the render pads from that pin geometry so a
	# whole-board load (minerva_pcb_load_board) renders real pads, not
	# placeholders. Fit the body to the pads only when the dict gave no size.
	var explicit_pads: Array = data.get("pads", [])
	if not explicit_pads.is_empty():
		_pads_from_list(explicit_pads)
	else:
		_pads_from_canonical_pins(pin_list, not (data.has("width") or data.has("height")))
	_graphics_from_list(data.get("graphics", []))
	_refdes_from_list(data.get("refdes_graphics", []))

	# U1-render unit 2: when the board dict gave no explicit size (no
	# local_bounds, no width/height Extra — the same "not (data.has(...))"
	# check the pad-fit call above uses for `fit_body`), replace whatever got
	# computed above — the default-centered rect OR the _fit_body_to_pads()
	# pad-extent fit — with the real courtyard/silk extent. The courtyard is
	# the module's true footprint; pads/defaults are only fallbacks for when
	# nothing better is known, so this intentionally runs AFTER and can
	# override the pad-fit result. Explicit local_bounds/width/height in
	# `data` (checked identically) always wins and is never touched.
	if bounds_data.is_empty() and not data.has("width") and not data.has("height"):
		_derive_bounds_from_graphics()

	properties = (data.get("properties", {}) as Dictionary).duplicate()
	# `value` is derivative of properties.value (minpcb dual-write). Only adopt the
	# canonical scalar when properties itself did not carry it.
	if not properties.has("value") and data.has("value"):
		properties["value"] = str(data["value"])

	var color_data: Dictionary = data.get("color", {})
	if color_data.size() > 0:
		color = Color(
			color_data.get("r", 0.2),
			color_data.get("g", 0.6),
			color_data.get("b", 0.3),
			color_data.get("a", 1.0))
	label_visible = data.get("label_visible", true)
	locked = data.get("locked", false)

	# Preserve every canonical key this model has no field for (assembly, mpn,
	# future schema growth) — see canonical_extra's declaration. The known set
	# below is every key the reads above consumed; anything else is authored
	# design intent that must survive the round trip verbatim.
	canonical_extra.clear()
	var known := ["ref", "id", "footprint", "footprint_id", "x_mm", "y_mm",
		"rotation_deg", "layer", "width", "height", "local_bounds", "pads",
		"has_pad_geometry", "graphics", "bbox_center_offset", "properties",
		"color", "label_visible", "locked", "pins", "value"]
	for k in data:
		if k not in known:
			canonical_extra[k] = data[k]


## Create from a canonical board-contract component dict (static constructor).
static func from_board_dict(data: Dictionary):
	var component := _Self.new()
	component.load_from_board_dict(data)
	return component


## Get a human-readable description
func get_description() -> String:
	var value_str := ""
	if properties.has("value"):
		value_str = " (%s)" % properties["value"]
	return "%s%s - %s on %s layer" % [id, value_str, get_footprint_name(), layer]
