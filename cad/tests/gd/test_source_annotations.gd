extends "test_eval_await.gd"
## Exercise derived overlays through the real panel, broker and shared annotation substrate.
const SourceKind := preload("res://../../minerva-plugins/cad/ui/kinds/cad_source_annotation_kind.gd")

class Drawing extends AnnotationRenderContext:
	var leaders: Array[Vector2] = []
	var labels: Array[String] = []
	func draw_line(a: Vector2, _b: Vector2, _color: Color, _width: float = 1.0) -> void:
		leaders.append(a)
	func draw_rect(_rect: Rect2, _color: Color, _filled: bool, _width: float = 1.0) -> void:
		pass
	func draw_polygon(_points: PackedVector2Array, _colors: PackedColorArray) -> void:
		pass
	func draw_string(_font: Font, _pos: Vector2, text: String, _color: Color, _size: int = 16) -> void:
		labels.append(text)

func _run() -> void:
	root.size = Vector2i(1280, 900)
	_document_path = OS.get_user_data_dir().path_join("cad_source_annotation_test.mcad")
	var rig := _make_rig("cad_source_annotations")
	if rig.is_empty():
		return
	var panel: Node = rig.panel
	panel._apply_width_class(&"lg")
	await PanelTools.handle(panel, "minerva_cad_build", {"action": "set_mode", "mode": "manual"})
	_attach_document(rig, SOURCE)
	var answer := _worker_answer()
	answer.result["annotations"] = [{"id": "hole", "at_mm": [5,5,5], "text": "Fit requirement",
		"dimension": "diameter", "nominal_mm": 4, "deviations_mm": [0,0.2]}]
	panel.build_latest()
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), answer)
	await process_frame
	var host: Object = panel._annotation_host
	var annotations: Array = host.get_annotations()
	check("build creates one source overlay", annotations.size() == 1, str(annotations))
	if annotations.is_empty():
		_teardown(rig)
		return
	var overlay: Dictionary = annotations[0]
	check("source overlay retains completed model provenance", overlay.id == "source:hole"
		and overlay.kind_payload.provenance == panel.evaluation_freshness().provenance, str(overlay))
	check("source overlays cannot be edited, deleted or authored independently",
		not host.update_annotation(overlay.id, overlay) and not host.remove_annotation(overlay.id)
		and host.add_annotation(overlay) == "", str(host.get_annotations()))
	var drawing := Drawing.new()
	drawing.host = host
	SourceKind.new().render(drawing, overlay)
	check("source overlay draws a leader in all four panes", drawing.leaders.size() == 4, str(drawing.leaders))
	var panes: Array = host.get_panes()
	for i in range(mini(panes.size(), drawing.leaders.size())):
		var rect: Rect2 = panes[i].viewport_rect
		check("leader projects inside pane " + str(i), rect.has_point(drawing.leaders[i]), str(rect))
	check("dimensional callouts display nominal and signed limits", drawing.labels.has("Diameter 4 mm")
		and " ".join(drawing.labels).contains("+0.0 / +0.2 mm"), str(drawing.labels))
	# A saved host list can include derived records; loading it must never make
	# those records editable copies. Separately authored discussion stays intact.
	var discussion := overlay.duplicate(true)
	discussion.id = "discussion"
	discussion.kind = "2d_text"
	host.set_annotations([discussion, overlay])
	panel.build_latest()
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), answer)
	await process_frame
	check("rebuild and restore replace overlays without duplicating discussion", host.get_annotations().size() == 2,
		str(host.get_annotations()))
	rig.buffer.apply_edit(BROKEN_SOURCE)
	panel.build_latest()
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), _worker_error())
	await process_frame
	check("failed build preserves the completed source overlay", host.get_annotations().size() == 2
		and _status(panel) == "error", str(host.get_annotations()))
	var malformed := answer.duplicate(true)
	malformed.result.annotations[0].at_mm = []
	panel.build_latest()
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), malformed)
	await process_frame
	check("malformed annotation reply rejects build and retains overlays", host.get_annotations().size() == 2
		and _status(panel) == "error", str(panel._last_eval_result))
	rig.buffer.apply_edit(EDITED_SOURCE)
	panel.build_latest()
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), _worker_answer())
	await process_frame
	check("successful removal clears only source overlays", host.get_annotations().size() == 1
		and host.get_annotations()[0].id == "discussion", str(host.get_annotations()))
	_teardown(rig)
