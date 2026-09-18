extends "res://Scripts/Services/Annotations/kinds/AnnotationArrow.gd"
## Keep ordinary arrow captions and drawing, projecting only the attachment.
var host_ref: WeakRef
var interaction_pane := ""

func _init() -> void:
	name = &"cad_surface_arrow"
	display_name = "Surface arrow"
	owning_plugin = &"cad"
	schema_version = 2

func accepted_anchor_types() -> Array:
	return ["cad/point"]

func author_ui() -> Object:
	# The regular arrow gesture supplies its tip; the host ray-picks it.
	return super.author_ui()

func projected(annotation: Dictionary, pane: Dictionary) -> Dictionary:
	var host: Object = host_ref.get_ref() if host_ref != null else null
	if host == null:
		return {}
	var resolved: Variant = host.resolve_point_anchor(annotation.get("anchor", {}))
	if not resolved is Dictionary:
		return {}
	var camera: Camera3D = pane.camera
	var world: Vector3 = resolved.position
	if camera.is_position_behind(world):
		return {}
	var rect: Rect2 = pane.viewport_rect
	var tip := camera.unproject_position(world) + rect.position
	if not rect.has_point(tip):
		return {}
	var copy := annotation.duplicate(true)
	if bool(resolved.get("stale", false)):
		copy.kind_payload["label"] = "[stale attachment] " + str(copy.kind_payload.get("label", ""))
	var offset: Array = annotation.get("kind_payload", {}).get("tail_offset", [-100, -50])
	copy["primitives"] = [{"kind": "arrow", "from": [tip.x + offset[0], tip.y + offset[1]], "to": [tip.x, tip.y]}]
	copy.kind_payload.erase("endpoint_a")
	copy.kind_payload.erase("endpoint_b")
	return copy

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var host: Object = host_ref.get_ref() if host_ref != null else null
	if host == null:
		return
	for pane: Dictionary in host.get_panes():
		var copy := projected(annotation, pane)
		if not copy.is_empty():
			super.render(ctx, copy)

func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var host: Object = host_ref.get_ref() if host_ref != null else null
	if host != null:
		if not host.get_panes().any(func(pane: Dictionary): return str(pane.name) == interaction_pane):
			interaction_pane = ""
		for pane: Dictionary in host.get_panes():
			var copy := projected(annotation, pane)
			if not copy.is_empty() and super.hit_test(copy, point, threshold):
				interaction_pane = str(pane.name)
				return true
	return false

func bounds(annotation: Dictionary) -> Rect2:
	var host: Object = host_ref.get_ref() if host_ref != null else null
	if host != null:
		if not host.get_panes().any(func(pane: Dictionary): return str(pane.name) == interaction_pane):
			interaction_pane = ""
		for pane: Dictionary in host.get_panes():
			if not interaction_pane.is_empty() and str(pane.name) != interaction_pane:
				continue
			var copy := projected(annotation, pane)
			if not copy.is_empty():
				return super.bounds(copy)
	return Rect2()

func endpoints_any(ctx: AnnotationRenderContext, annotation: Dictionary) -> Array:
	var host: Object = host_ref.get_ref() if host_ref != null else null
	if host != null:
		if not host.get_panes().any(func(pane: Dictionary): return str(pane.name) == interaction_pane):
			interaction_pane = ""
		for pane: Dictionary in host.get_panes():
			if not interaction_pane.is_empty() and str(pane.name) != interaction_pane:
				continue
			var copy := projected(annotation, pane)
			if not copy.is_empty():
				return super.endpoints_any(ctx, copy)
	return []

func describe_target_point(annotation: Dictionary, _base_pos: Vector2, _host: AnnotationHost) -> String:
	var anchor: Dictionary = annotation.get("anchor", {})
	return "%s/%s at local %s mm" % [anchor.get("reference", ""), anchor.get("node", ""), str(anchor.get("local", []))]

func transform_annotation(annotation: Dictionary, transform: Transform2D, operation: String = "") -> Dictionary:
	# Moving a 2D callout changes its layout, never silently its 3D attachment.
	var copy := annotation.duplicate(true)
	var offset: Array = copy.kind_payload.get("tail_offset", [-100, -50])
	var endpoints := endpoints_any(null, annotation)
	var head: Vector2 = endpoints[1] if endpoints.size() == 2 else Vector2.ZERO
	var shifted := transform * (head + Vector2(offset[0], offset[1])) - head
	copy.kind_payload["tail_offset"] = [shifted.x, shifted.y]
	if operation == "":
		return copy
	return copy
