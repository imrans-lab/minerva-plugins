extends AnnotationKind
## PCB plugin annotation kind: pcb_route_hint (semantic-anchor round).
##
## A route hint is an author's suggestion for how a net/trace should be routed:
## an optional waypoint polyline on the board, on a named copper layer, from a
## source pad to a destination pad. It communicates intent ("route this corridor")
## and never becomes board state — pcb_interpret_route_hints reads it separately.
##
## Envelope shape (v2, must pass AnnotationV2Schema.validate_with_registry):
##   kind:    "pcb_route_hint"
##   anchor:  a pcb/board.point {plugin:"pcb", type:"board.point", id:{x,y}, …}
##            OR a pcb/pad       {plugin:"pcb", type:"pad", id:{component,pin}, …}
##   kind_payload:
##     hint_type:    "waypoint" | "single_trace" | "bus"   (default "waypoint")
##     detail_level: "sparse" | "guided" | "detailed"      (optional)
##     layer:        KiCAD layer, e.g. "F.Cu" / "B.Cu"      (default "F.Cu")
##     width_mm:     trace width in mm                       (optional, >0)
##     source_pins:  Array["U1.15", …]                       (optional)
##     dest_pins:    Array["J2.3", …]                        (optional)
##     text:         author instruction body                (optional)
##     waypoints:    Array[[x_mm, y_mm]]                     (optional, board mm)
##
## Envelope tolerance: the OLD skeleton payload (only hint_type/layer/text/
## waypoints) keeps validating and rendering — every new field is optional.
##
## Off-tree note: lives at C:/github/minerva-plugins/pcb/ui/kinds/, OUTSIDE
## Minerva's res:// tree. It MUST NOT declare a class_name — plugin-local
## class_names are unresolvable from the off-tree parser cache. Loaded via
## preload()/load() by PcbAnnotationHost.gd and the smoke test.

const _ANCHOR_TYPE_BOARD_POINT := "pcb/board.point"
const _ANCHOR_TYPE_PAD := "pcb/pad"

const _MARKER_RADIUS: float = 5.0
const _LABEL_COLOR := Color(0.92, 0.96, 0.98, 1.0)
const _LABEL_FONT_SIZE: int = 12

## Layer-tinted stroke hues (F.Cu vs B.Cu hue shift). Unknown layers → neutral.
const _COLOR_F_CU := Color(0.25, 0.85, 0.80, 0.95)   # teal   — top copper
const _COLOR_B_CU := Color(0.95, 0.55, 0.25, 0.95)   # amber  — bottom copper (hue-shifted)
const _COLOR_OTHER := Color(0.70, 0.55, 0.90, 0.95)  # violet — other/unspecified layer

## Path hit-test tolerance in document (board-mm) units, on top of stroke half-width.
const _HIT_THRESHOLD_MM: float = 0.6

const _VALID_HINT_TYPES := ["waypoint", "single_trace", "bus"]
const _VALID_DETAIL_LEVELS := ["sparse", "guided", "detailed"]

## The per-row "apply" action is a synchronous no-op pointer: real routing is an
## async worker round-trip that a sync run_action cannot await, so trace synthesis
## lives in the MCP tool minerva_pcb_apply_route_hints (agent-router child
## 019eb47eb567), which routes open hints → cyan proposals → committed traces.
const _APPLY_TODO := "use minerva_pcb_apply_route_hints to route + apply (async worker path)"


func _init() -> void:
	name = &"pcb_route_hint"
	display_name = "Route Hint"
	schema_version = 1
	owning_plugin = &"pcb"
	primitives_optional = true
	default_payload = {
		"hint_type": "waypoint",
		"detail_level": "guided",
		"layer": "F.Cu",
		"width_mm": 0.25,
		"source_pins": [],
		"dest_pins": [],
		"text": "",
		"waypoints": [],
	}


## A route hint anchors at a board point (freehand) OR at its source pad (the
## natural authored form). Returning a non-empty list is what makes
## AnnotationV2Schema.validate_with_registry pass the kind↔anchor compat check.
func accepted_anchor_types() -> Array:
	return [_ANCHOR_TYPE_BOARD_POINT, _ANCHOR_TYPE_PAD]


# ── Authoring (waypoint-click) ────────────────────────────────────────────────

## Fresh instance per activation (AnnotationText pattern) so the toolbar can
## deactivate-then-reactivate without state leak.
func author_ui() -> Object:
	return WaypointRouteHintAuthorTool.new()


## Waypoint-click authoring: each left click appends a waypoint (previewed via
## draw_preview); a double-click (a left click landing on the last waypoint)
## commits; Escape (via the mods channel — the only key AnnotationOverlay
## forwards to author tools) or right-click cancels, matching the arrow tool's
## cancel gestures. On commit the tool emits annotation_ready with a polyline
## route hint anchored at the FIRST waypoint — envelope construction is
## delegated to the host's build_route_hint_envelope so the toolbar path and
## the MCP/test path share one builder.
class WaypointRouteHintAuthorTool:
	extends AnnotationAuthorTool

	## Same-position epsilon (board mm) for double-click commit detection.
	const _COMMIT_EPSILON := 0.001

	var _host: AnnotationHost = null
	var _waypoints: Array = []       # Array[Vector2] in document (board-mm) space
	var _preview: Vector2 = Vector2.ZERO
	var _has_preview: bool = false

	func on_activate(host: AnnotationHost) -> void:
		_host = host
		_reset()

	func on_deactivate() -> void:
		# Clean reset on tool-switch WITHOUT emitting cancelled (arrow convention).
		_reset()
		_host = null

	func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
		# Escape (via mods channel) → cancel an in-progress path.
		if mods == KEY_ESCAPE:
			if not _waypoints.is_empty():
				_reset()
				cancelled.emit()
				return true
			return false

		# Right-click → cancel (consistency with the arrow author tool).
		if button == MOUSE_BUTTON_RIGHT:
			if not _waypoints.is_empty():
				_reset()
				cancelled.emit()
				return true
			return false

		if button != MOUSE_BUTTON_LEFT:
			return false
		if _host == null:
			return false

		var doc_pos: Vector2 = _host.transform_screen_to_doc(pos)

		# Double-click semantics: a left click landing on the last waypoint commits.
		if not _waypoints.is_empty():
			var last: Vector2 = _waypoints[_waypoints.size() - 1]
			if last.distance_to(doc_pos) <= _COMMIT_EPSILON:
				return _try_commit()

		_waypoints.append(doc_pos)
		_preview = doc_pos
		_has_preview = true
		return true

	func on_pointer_move(pos: Vector2) -> void:
		if _host == null or _waypoints.is_empty():
			return
		_preview = _host.transform_screen_to_doc(pos)
		_has_preview = true

	func draw_preview(ctx: AnnotationRenderContext) -> void:
		if ctx == null or _waypoints.is_empty():
			return
		var base := AnnotationRenderContext.author_color("human")
		var faded := Color(base.r, base.g, base.b, 0.5)
		for i in range(1, _waypoints.size()):
			ctx.draw_line(_waypoints[i - 1], _waypoints[i], faded, 1.0)
		if _has_preview:
			ctx.draw_line(_waypoints[_waypoints.size() - 1], _preview, faded, 1.0)

	func _try_commit() -> bool:
		if _waypoints.is_empty():
			return false
		if _host == null or not _host.has_method("build_route_hint_envelope"):
			push_warning("[pcb_route_hint] author tool active without a pcb host; ignoring commit")
			_reset()
			return false
		var first: Vector2 = _waypoints[0]
		var wp_arrays: Array = []
		for wp in _waypoints:
			wp_arrays.append([wp.x, wp.y])
		var envelope: Dictionary = _host.call(
			"build_route_hint_envelope", first.x, first.y, "", "F.Cu", "waypoint", wp_arrays, "human")
		_reset()
		annotation_ready.emit(envelope)
		return true

	func _reset() -> void:
		_waypoints = []
		_preview = Vector2.ZERO
		_has_preview = false

	## Test/introspection accessor — current in-progress waypoint count.
	func waypoint_count() -> int:
		return _waypoints.size()


# ── Validation (beyond the envelope schema) ──────────────────────────────────

func validate(annotation: Dictionary) -> Array:
	var errors: Array = []
	var anchor: Variant = annotation.get("anchor", null)
	if not (anchor is Dictionary):
		errors.append({"field": "anchor", "message": "anchor dict is required"})
		return errors
	var a: Dictionary = anchor as Dictionary
	if str(a.get("plugin", "")) != "pcb":
		errors.append({"field": "anchor.plugin", "message": "anchor.plugin must be 'pcb'"})
	var atype := str(a.get("type", ""))
	if atype not in ["board.point", "pad"]:
		errors.append({"field": "anchor.type", "message": "anchor.type must be 'board.point' or 'pad'"})

	var payload: Dictionary = annotation.get("kind_payload", {})

	var hint_type := str(payload.get("hint_type", "waypoint"))
	if hint_type not in _VALID_HINT_TYPES:
		errors.append({"field": "kind_payload.hint_type", "message": "hint_type must be waypoint|single_trace|bus"})

	# detail_level is optional; validate only when present (old skeletons omit it).
	if payload.has("detail_level"):
		var detail := str(payload["detail_level"])
		if detail not in _VALID_DETAIL_LEVELS:
			errors.append({"field": "kind_payload.detail_level", "message": "detail_level must be sparse|guided|detailed"})

	if payload.has("width_mm"):
		var w: Variant = payload["width_mm"]
		if not (w is float or w is int):
			errors.append({"field": "kind_payload.width_mm", "message": "width_mm must be a number"})
		elif float(w) < 0.0:
			errors.append({"field": "kind_payload.width_mm", "message": "width_mm must be >= 0"})

	for key in ["source_pins", "dest_pins", "waypoints"]:
		if payload.has(key) and not (payload[key] is Array):
			errors.append({"field": "kind_payload.%s" % key, "message": "%s must be an Array" % key})

	# Self-referencing rejection: a hint from a pad to itself is meaningless.
	var src: Array = _string_array(payload.get("source_pins", []))
	var dst: Array = _string_array(payload.get("dest_pins", []))
	if src.size() == 1 and dst.size() == 1 and not src[0].is_empty() and src[0] == dst[0]:
		errors.append({"field": "kind_payload.dest_pins", "message": "source and destination pin must differ"})

	return errors


# ── Required rendering hooks ──────────────────────────────────────────────────

## Waypoint polyline with a layer-tinted, width/zoom-aware stroke + a diamond
## marker at the anchor + a text label. Coordinates are document-space (board mm);
## the substrate AnnotationOverlay applies the host transform before calling us.
func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	if ctx == null:
		return
	var pos := _anchor_position(annotation)
	var payload: Dictionary = annotation.get("kind_payload", {})
	var layer := str(payload.get("layer", "F.Cu"))
	# AI-authored proposals (route-correction loop, 019eb47eb567) render in the
	# substrate's author cyan so a proposed route reads as distinct from a
	# human-authored (layer-tinted) hint at a glance. Human hints keep the
	# layer-tinted stroke.
	var stroke_color := _layer_color(layer)
	var author: Variant = annotation.get("author", null)
	if author is Dictionary and str((author as Dictionary).get("kind", "human")) == "ai":
		stroke_color = AnnotationRenderContext.author_color("ai")

	# Stroke width: width_mm scaled by zoom (pixels-per-mm), floored to 1px so a
	# hair-thin hint stays visible when zoomed out.
	var width_mm := float(payload.get("width_mm", 0.0))
	var stroke_px := 1.0
	if width_mm > 0.0:
		stroke_px = maxf(1.0, width_mm * ctx.zoom)

	# Waypoint polyline (layer-tinted) if present.
	var pts := _waypoint_points(annotation)
	if pts.size() >= 2:
		ctx.draw_polyline(pts, stroke_color, stroke_px)

	# Diamond marker at the anchor.
	var d := _MARKER_RADIUS
	var diamond := PackedVector2Array([
		pos + Vector2(0, -d), pos + Vector2(d, 0),
		pos + Vector2(0, d), pos + Vector2(-d, 0),
	])
	var cols := PackedColorArray([stroke_color, stroke_color, stroke_color, stroke_color])
	ctx.draw_polygon(diamond, cols)

	# Label: the enriched summary (endpoints, layer, width, waypoint count).
	var font: Font = ThemeDB.fallback_font
	if font != null:
		ctx.draw_string(font, pos + Vector2(d + 3.0, 4.0), summary(annotation), _LABEL_COLOR, _LABEL_FONT_SIZE)


## Path-based hit-test: distance to any polyline segment (not the AABB), plus the
## marker disc around the anchor. threshold is in document (board-mm) units.
func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var effective := threshold + _HIT_THRESHOLD_MM + float(payload.get("width_mm", 0.0)) * 0.5

	# Marker disc around the anchor.
	if _anchor_position(annotation).distance_to(point) <= effective + _MARKER_RADIUS:
		return true

	# Swept distance to the waypoint polyline.
	var pts := _waypoint_points(annotation)
	for i in range(pts.size() - 1):
		if _dist_point_to_segment(point, pts[i], pts[i + 1]) <= effective:
			return true
	return false


func bounds(annotation: Dictionary) -> Rect2:
	var pos := _anchor_position(annotation)
	var r := _MARKER_RADIUS
	var rect := Rect2(pos - Vector2(r, r), Vector2(r * 2.0, r * 2.0))
	for wp in _waypoint_points(annotation):
		rect = rect.expand(wp)
	return rect


func primary_anchor_point(annotation: Dictionary) -> Vector2:
	return _anchor_position(annotation)


## Enriched one-line summary: "route hint U1.15→J2.3, F.Cu, 0.25mm, 4 waypoints".
## Empty parts are omitted gracefully; trailing text (if any) is appended.
func summary(annotation: Dictionary) -> String:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var parts: Array = []

	var head := "route hint"
	var src: Array = _string_array(payload.get("source_pins", []))
	var dst: Array = _string_array(payload.get("dest_pins", []))
	if not src.is_empty() and not dst.is_empty():
		head = "route hint %s→%s" % [src[0], dst[0]]
	parts.append(head)

	var layer := str(payload.get("layer", ""))
	if not layer.is_empty():
		parts.append(layer)

	var width_mm := float(payload.get("width_mm", 0.0))
	if width_mm > 0.0:
		parts.append(_fmt_mm(width_mm))

	var wp_count := _waypoint_points(annotation).size()
	if wp_count > 0:
		parts.append("%d waypoint%s" % [wp_count, "s" if wp_count != 1 else ""])

	var s := ", ".join(parts)
	var text := str(payload.get("text", ""))
	if not text.is_empty():
		s = "%s: %s" % [s, text]
	return s


# ── Per-row actions (workbench / apply-tool) ──────────────────────────────────

## "reject" resolves the hint (open→resolved per AnnotationLifecycle); "apply" is
## a no-op stub the agent-router child (019eb47eb567) will wire to trace synthesis.
func actions(annotation: Dictionary) -> Array:
	var lifecycle := str(annotation.get("lifecycle", "open"))
	var result: Array = []
	# apply/reject only make sense on an open hint.
	if lifecycle == "open":
		result.append({"id": "apply", "label": "Apply", "requires_lifecycle": "open"})
		result.append({"id": "reject", "label": "Reject", "requires_lifecycle": "open"})
	return result


## Called dry_run then commit by AnnotationApplyToolRunner. Returns {ok, …}.
func run_action(action_id: String, annotation: Dictionary, phase: String, host: AnnotationHost) -> Dictionary:
	match action_id:
		"reject":
			if phase == "dry_run":
				return {"ok": true, "status": "will resolve (reject) this route hint"}
			# commit — transition the hint to resolved via the host lifecycle path.
			var ann_id := str(annotation.get("id", ""))
			if host != null and host.has_method("update_annotation_lifecycle") and not ann_id.is_empty():
				var res: Dictionary = host.update_annotation_lifecycle(ann_id, "resolved")
				if bool(res.get("ok", false)):
					return {"ok": true, "status": "route hint rejected (resolved)"}
				return {"ok": false, "error": str(res.get("error", "lifecycle transition failed"))}
			return {"ok": false, "error": "host cannot transition lifecycle"}
		"apply":
			# TODO(019eb47eb567): agent-router child wires this to real trace synthesis.
			return {"ok": true, "status": _APPLY_TODO}
	return {"ok": false, "error": "unknown action '%s'" % action_id}


# ── Helpers ───────────────────────────────────────────────────────────────────

## Read the anchor's board-space point. Prefers anchor.id {x,y} (board.point);
## falls back to anchor.snapshot.position [x,y] (pad anchors carry {component,pin}
## in id, so the snapshot position is the authoritative board-mm point for them).
static func _anchor_position(annotation: Dictionary) -> Vector2:
	var anchor: Variant = annotation.get("anchor", null)
	if anchor is Dictionary:
		var id: Variant = (anchor as Dictionary).get("id", null)
		if id is Dictionary and (id as Dictionary).has("x") and (id as Dictionary).has("y"):
			return Vector2(float((id as Dictionary)["x"]), float((id as Dictionary)["y"]))
		var snap: Variant = (anchor as Dictionary).get("snapshot", null)
		if snap is Dictionary:
			return _to_vec2((snap as Dictionary).get("position", [0, 0]))
	return Vector2.ZERO


## The polyline points for render/hit-test/bounds: the explicit waypoints when
## present, else the single anchor point.
func _waypoint_points(annotation: Dictionary) -> PackedVector2Array:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var raw: Variant = payload.get("waypoints", [])
	var out := PackedVector2Array()
	if raw is Array:
		for wp in (raw as Array):
			out.append(_to_vec2(wp))
	if out.is_empty():
		out.append(_anchor_position(annotation))
	return out


static func _layer_color(layer: String) -> Color:
	match layer:
		"F.Cu":
			return _COLOR_F_CU
		"B.Cu":
			return _COLOR_B_CU
		_:
			return _COLOR_OTHER


## Format a mm width with no trailing zeros (0.25 → "0.25mm", 0.3 → "0.3mm").
## GDScript's format has no %g, so trim manually.
static func _fmt_mm(w: float) -> String:
	var s := "%.4f" % w
	s = s.rstrip("0").rstrip(".")
	return "%smm" % s


static func _string_array(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for v in (raw as Array):
			out.append(str(v))
	return out


static func _to_vec2(raw: Variant) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	return Vector2.ZERO


static func _dist_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)
