extends AnnotationKind
## PCB plugin annotation kind: pcb_route_hint (walking-skeleton form).
##
## A route hint is an author's suggestion for how a net/trace should be routed:
## a labelled point (and optional waypoint polyline) on the board, on a named
## copper layer. This skeleton implements the minimum the substrate needs to
## register the kind, validate an envelope, and render a crude marker — the real
## multi-waypoint bus/single-trace geometry lands in a later round.
##
## Envelope shape (v2, must pass AnnotationV2Schema.validate_with_registry):
##   kind:    "pcb_route_hint"
##   anchor:  {plugin:"pcb", type:"board.point", id:{x,y}, snapshot:{position:[x,y]}}
##   kind_payload:
##     hint_type:  "waypoint" | "single_trace" | "bus"   (default "waypoint")
##     layer:      KiCAD layer, e.g. "F.Cu" / "B.Cu"      (default "F.Cu")
##     text:       author instruction body                (optional)
##     waypoints:  Array[[x_mm, y_mm]]                     (optional, board mm)
##
## Off-tree note: lives at C:/github/minerva-plugins/pcb/ui/kinds/, OUTSIDE
## Minerva's res:// tree. It MUST NOT declare a class_name — plugin-local
## class_names are unresolvable from the off-tree parser cache. Loaded via
## preload()/load() by PcbAnnotationHost.gd and the smoke test.

const _ANCHOR_TYPE := "pcb/board.point"

const _MARKER_RADIUS: float = 5.0
const _MARKER_COLOR := Color(0.25, 0.85, 0.80, 0.95)   # teal — legacy PCB route-hint hue
const _LABEL_COLOR := Color(0.92, 0.96, 0.98, 1.0)
const _WAYPOINT_COLOR := Color(0.60, 0.45, 0.90, 0.85) # purple
const _LABEL_FONT_SIZE: int = 12


func _init() -> void:
	name = &"pcb_route_hint"
	display_name = "Route Hint"
	schema_version = 1
	owning_plugin = &"pcb"
	primitives_optional = true
	default_payload = {"hint_type": "waypoint", "layer": "F.Cu", "text": "", "waypoints": []}


## Only the pcb/board.point anchor is accepted. Returning a non-empty list here
## is what makes AnnotationV2Schema.validate_with_registry pass the kind↔anchor
## compatibility check (the generic fallback table has no pcb_route_hint entry,
## so without this the envelope is rejected as kind_anchor_incompatible).
func accepted_anchor_types() -> Array:
	return [_ANCHOR_TYPE]


# ── Authoring ─────────────────────────────────────────────────────────────────

## Fresh instance per activation (AnnotationText pattern) so the toolbar can
## deactivate-then-reactivate without state leak. Without this override the
## toolbar shows no button for the kind (AnnotationToolbar only creates buttons
## for kinds whose author_ui() is non-null) — walking-skeleton finding W-13.
func author_ui() -> Object:
	return RouteHintAuthorTool.new()


## Click-to-author: one left click places a route hint at the clicked
## document-space point (board mm through the host transform — identity in the
## skeleton). Envelope construction is delegated to the host's
## build_route_hint_envelope so the toolbar path and the MCP/test path share
## one builder. Emits annotation_ready; the toolbar calls host.add_annotation.
class RouteHintAuthorTool:
	extends AnnotationAuthorTool

	var _host: AnnotationHost = null

	func on_activate(host: AnnotationHost) -> void:
		_host = host

	func on_deactivate() -> void:
		_host = null

	func on_pointer_down(pos: Vector2, button: int, _mods: int) -> bool:
		if button != MOUSE_BUTTON_LEFT:
			return false
		if _host == null or not _host.has_method("build_route_hint_envelope"):
			push_warning("[pcb_route_hint] author tool active without a pcb host; ignoring click")
			return false
		var envelope: Dictionary = _host.call("build_route_hint_envelope", pos.x, pos.y)
		annotation_ready.emit(envelope)
		return true


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
	if str(a.get("type", "")) != "board.point":
		errors.append({"field": "anchor.type", "message": "anchor.type must be 'board.point'"})

	var payload: Dictionary = annotation.get("kind_payload", {})
	var hint_type := str(payload.get("hint_type", "waypoint"))
	if hint_type not in ["waypoint", "single_trace", "bus"]:
		errors.append({"field": "kind_payload.hint_type", "message": "hint_type must be waypoint|single_trace|bus"})
	if payload.has("waypoints") and not (payload["waypoints"] is Array):
		errors.append({"field": "kind_payload.waypoints", "message": "waypoints must be an Array"})
	return errors


# ── Required rendering hooks ──────────────────────────────────────────────────

## Crude marker: a filled diamond at the anchor point + optional waypoint
## polyline + a text label. Coordinates are document-space (board mm); the
## substrate AnnotationOverlay applies the host transform before calling us, so
## PcbAnnotationHost's identity transform means doc == screen for the skeleton.
func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	if ctx == null:
		return
	var pos := _anchor_position(annotation)
	var payload: Dictionary = annotation.get("kind_payload", {})

	# Waypoint polyline (purple) if present.
	var waypoints: Variant = payload.get("waypoints", [])
	if waypoints is Array and (waypoints as Array).size() >= 2:
		var prev := _to_vec2(waypoints[0])
		for i in range(1, (waypoints as Array).size()):
			var cur := _to_vec2(waypoints[i])
			ctx.draw_line(prev, cur, _WAYPOINT_COLOR, 1.5)
			prev = cur

	# Diamond marker at the anchor.
	var d := _MARKER_RADIUS
	var diamond := PackedVector2Array([
		pos + Vector2(0, -d), pos + Vector2(d, 0),
		pos + Vector2(0, d), pos + Vector2(-d, 0),
	])
	var cols := PackedColorArray([_MARKER_COLOR, _MARKER_COLOR, _MARKER_COLOR, _MARKER_COLOR])
	ctx.draw_polygon(diamond, cols)

	# Label: layer + text.
	var font: Font = ThemeDB.fallback_font
	if font != null:
		var layer := str(payload.get("layer", "F.Cu"))
		var text := str(payload.get("text", ""))
		var label := layer if text.is_empty() else "%s · %s" % [layer, text]
		ctx.draw_string(font, pos + Vector2(d + 3.0, 4.0), label, _LABEL_COLOR, _LABEL_FONT_SIZE)


func bounds(annotation: Dictionary) -> Rect2:
	var pos := _anchor_position(annotation)
	var r := _MARKER_RADIUS
	var rect := Rect2(pos - Vector2(r, r), Vector2(r * 2.0, r * 2.0))
	# Grow to include waypoints so hit-testing covers the whole hint.
	var payload: Dictionary = annotation.get("kind_payload", {})
	var waypoints: Variant = payload.get("waypoints", [])
	if waypoints is Array:
		for wp in (waypoints as Array):
			rect = rect.expand(_to_vec2(wp))
	return rect


func primary_anchor_point(annotation: Dictionary) -> Vector2:
	return _anchor_position(annotation)


func summary(annotation: Dictionary) -> String:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var layer := str(payload.get("layer", "F.Cu"))
	var hint_type := str(payload.get("hint_type", "waypoint"))
	var text := str(payload.get("text", ""))
	var base := "Route hint (%s, %s)" % [hint_type, layer]
	return base if text.is_empty() else "%s: %s" % [base, text]


# ── Helpers ───────────────────────────────────────────────────────────────────

## Read the anchor's board-space point. Prefers anchor.id {x,y}; falls back to
## anchor.snapshot.position [x,y]. Both are board millimetres.
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


static func _to_vec2(raw: Variant) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	return Vector2.ZERO
