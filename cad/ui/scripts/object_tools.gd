extends RefCounted
const Point := preload("CadPointAnchor.gd")
const Interaction := preload("object_interaction.gd")

static func handle(panel: Control, args: Dictionary) -> Dictionary:
	var action := str(args.get("action", "inspect"))
	var control: Control = panel._canvas_overlay
	var host: Object = panel.get_annotation_host()
	if action in ["undo", "redo"]:
		return control.undo(action == "redo")
	if action == "set_mode":
		var mode := str(args.get("mode", "select"))
		if mode not in ["select", "translate", "rotate", ""]:
			return error("Unknown object mode")
		control.set_mode(mode)
		return {"success": true, "mode": mode}
	if action == "inspect":
		var selected: Dictionary = panel.get_reference_selection()
		var placement: Dictionary = control.placement()
		var state: Dictionary = panel.get_evaluation_state()
		return {"success": true, "selected": wire(selected),
			"placement": {"editable": not placement.has("error"), "reason": placement.get("error", ""),
				"matrix": placement.get("matrix", [])},
			"source_location": {"path": state.get("path", ""), "binding": placement.get("binding", ""),
				"line": placement.get("source_line", 0)},
			"provenance": state.get("provenance", {}),
			"objects": panel._reference_selection.get_records().map(func(r: Dictionary): return str(r.name))}
	if bool(panel.evaluation_freshness().get("stale", false)):
		return error("Build latest source before editing placement or attachment.")
	if action == "select":
		var selected: Dictionary = panel.select_reference_node(str(args.get("object_id", "")), str(args.get("node", "")), args.get("point_mm"))
		if selected.is_empty():
			return error("Object or node is not in the displayed model")
		return {"success": true, "selected": wire(selected)}
	if action == "transform":
		return control.transform_object(control.placement(), str(args.get("operation", "translate")), int(args.get("axis", 0)), float(args.get("amount", 0)))
	if action not in ["attachment", "refine_attachment", "attach_arrow"]:
		return error("Unknown object action")
	var id := str(args.get("annotation_id", ""))
	var annotation: Dictionary = control.annotation(id)
	if annotation.is_empty():
		return error("Annotation not found")
	if action == "attachment":
		return {"success": true, "anchor": annotation.get("anchor", {}),
			"resolved": wire(host.resolve_point_anchor(annotation.get("anchor", {})))}
	var before := annotation.duplicate(true)
	if action == "attach_arrow":
		annotation = host.attach_surface_arrow(annotation)
		if annotation.kind != "cad_surface_arrow":
			return error("The arrow tip does not hit a model surface in this view.")
	else:
		if str(annotation.kind) != "cad_surface_arrow":
			return error("This is not a surface arrow; attach it before refining its point.")
		var raw: Variant = args.get("point_mm")
		if not valid_vector(raw):
			return error("point_mm must contain three finite object-local coordinates")
		var anchor: Dictionary = annotation.anchor
		var record := Point.record_named(host.get_reference_records(), str(anchor.get("reference", "")))
		if record.is_empty():
			return error("The attachment's object is no longer displayed.")
		var normal_raw: Variant = args.get("normal", anchor.get("normal", []))
		if not valid_vector(normal_raw):
			return error("normal must contain three finite object-local coordinates")
		var normal := Point.vec3_from(normal_raw).normalized()
		if normal.is_zero_approx():
			return error("A nonzero normal is required to verify the surface point.")
		var pose: Transform3D = record.pose
		var world: Vector3 = pose * Point.vec3_from(raw)
		var world_normal := (pose.basis.inverse().transposed() * normal).normalized()
		var hit: Dictionary = panel._reference_selection.pick([record], world - world_normal * 0.01, world + world_normal * 0.01)
		if hit.is_empty() or str(hit.node) != str(anchor.node):
			return error("That point is not on the named object's surface within 0.01 mm; supply the correct local point and normal.")
		if (hit.normal as Vector3).dot(world_normal) < 0.0:
			hit.normal = -hit.normal
		annotation.anchor = host.anchor_from_hit(hit)
		annotation.anchor["snapshot"] = {"position": [world.x, world.y]}
	annotation["updated_at"] = int(Time.get_unix_time_from_system())
	if not host.update_annotation(id, annotation):
		return error("Attachment update failed")
	control.remember({"kind": "annotation", "id": id, "before": before, "after": control.annotation(id)})
	return {"success": true, "anchor": control.annotation(id).anchor,
		"resolved": wire(host.resolve_point_anchor(annotation.anchor)), "undoable": true}

static func valid_vector(value: Variant) -> bool:
	if not value is Array or value.size() != 3:
		return false
	for item: Variant in value:
		if not (item is int or item is float) or not is_finite(float(item)):
			return false
	return true

static func wire(value: Variant) -> Variant:
	if value is Vector3:
		return Interaction.vec(value)
	if value is Vector2:
		return [value.x, value.y]
	if value is AABB:
		return {"min": Interaction.vec(value.position), "max": Interaction.vec(value.end)}
	if value is Dictionary:
		var out := {}
		for key: Variant in value:
			out[key] = wire(value[key])
		return out
	if value is Array:
		return value.map(wire)
	return value

static func error(message: String) -> Dictionary:
	return {"success": false, "error": message}
