extends AnnotationKind
## Read-only callout derived from source on the completed model.
const _Callout := preload("cad_callout.gd")
const _Layout := preload("cad_edge_label_layout.gd")
var host_ref: WeakRef

func bounds(annotation: Dictionary) -> Rect2:
	var host: Object = host_ref.get_ref() if host_ref != null else null
	if host == null:
		return Rect2()
	var world := preload("../scripts/CadPointAnchor.gd").vec3_from(annotation.get("anchor", {}).get("point", []))
	for pane: Dictionary in host.get_panes():
		var camera: Camera3D = pane.camera
		if camera.is_position_behind(world):
			continue
		var point := camera.unproject_position(world) + (pane.viewport_rect as Rect2).position
		if (pane.viewport_rect as Rect2).has_point(point):
			return Rect2(point - Vector2(4, 4), Vector2(8, 8))
	return Rect2()

func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var rect := bounds(annotation)
	return rect.has_area() and rect.grow(threshold).has_point(point)

func _init() -> void:
	name = &"cad_source_annotation"
	display_name = "Source annotation"
	schema_version = 2
	owning_plugin = &"cad"
	primitives_optional = true

func accepted_anchor_types() -> Array:
	return ["cad/model_point"]

func validate(annotation: Dictionary) -> Array:
	var point: Variant = annotation.get("anchor", {}).get("point", [])
	if not point is Array or point.size() != 3:
		return [{"field": "anchor.point", "message": "Expected model point [x,y,z]"}]
	for value in point:
		if not (value is int or value is float) or not is_finite(float(value)):
			return [{"field": "anchor.point", "message": "Coordinates must be finite"}]
	var record: Variant = annotation.get("kind_payload", {}).get("record", {})
	if not record is Dictionary:
		return [{"field": "kind_payload.record", "message": "Expected annotation record"}]
	if record.has("nominal_mm") and not (record.nominal_mm is int or record.nominal_mm is float):
		return [{"field": "nominal_mm", "message": "Expected numeric dimension"}]
	if record.has("deviations_mm"):
		var limits: Variant = record.deviations_mm
		if not limits is Array or limits.size() != 2:
			return [{"field": "deviations_mm", "message": "Expected two numeric deviations"}]
		for value in limits:
			if not (value is int or value is float) or not is_finite(float(value)):
				return [{"field": "deviations_mm", "message": "Expected finite deviations"}]
	return []

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var host: Object = ctx.host
	if host == null or not host.has_method("get_panes"):
		return
	var p: Array = annotation.anchor.point
	var world := Vector3(p[0], p[1], p[2])
	var payload: Dictionary = annotation.get("kind_payload", {})
	var record: Dictionary = payload.get("record", {})
	var title := str(record.get("id", "Note"))
	var body := str(record.get("text", ""))
	if record.has("nominal_mm"):
		title = "%s %s mm" % [str(record.get("dimension", "length")).capitalize(), str(record.nominal_mm)]
		if record.has("deviations_mm"):
			var deviations: Array = record.deviations_mm
			body += " Deviations: %s / %s mm" % [_signed(deviations[0]), _signed(deviations[1])]
	for pane: Dictionary in host.get_panes():
		var camera: Camera3D = pane.get("camera")
		if camera == null or camera.is_position_behind(world):
			continue
		var rect: Rect2 = pane.get("viewport_rect", Rect2())
		var start := camera.unproject_position(world) + rect.position
		if not rect.has_point(start):
			continue
		var layout: Dictionary = _Layout.get_layout(host, camera, rect, host.get_annotations())
		_Callout.draw(ctx, start, layout.get(str(annotation.id), start + Vector2(80,-40)), title, body, false)

static func _signed(value: float) -> String:
	return ("+" if value >= 0 else "") + str(value)
