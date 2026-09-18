extends "test_eval_await.gd"
const ObjectRecords := preload("res://../../minerva-plugins/cad/ui/scripts/object_records.gd")
const ObjectTools := preload("res://../../minerva-plugins/cad/ui/scripts/object_tools.gd")
const PointAnchor := preload("res://../../minerva-plugins/cad/ui/scripts/CadPointAnchor.gd")

func _run() -> void:
	root.size = Vector2i(1280, 900)
	var rig := _make_rig("cad_object_annotations")
	if rig.is_empty():
		return
	var panel: Node = rig.panel
	var host: Object = panel.get_annotation_host()
	var mesh := {"vertices": [[0,0,0], [12,0,0], [0,12,0]], "faces": [[0,1,2]]}
	var result := {"shape_name": "plate", "picking": {"plate": mesh}}
	var records := ObjectRecords.build(result, [])
	panel._reference_selection.set_records(records)
	var hit: Dictionary = panel._reference_selection.pick(records, Vector3(3,3,10), Vector3(3,3,-10))
	check("native triangle pick reports the definition", not hit.is_empty() and hit.node == "plate", str(hit))
	if hit.is_empty():
		_teardown(rig)
		return
	panel._reference_selection.select_hit(hit)
	check("selection shares identity and local normal", panel.get_reference_selection().object_id == "plate"
		and panel.get_reference_selection().normal.is_equal_approx(Vector3(0,0,1)), str(panel.get_reference_selection()))
	var anchor: Dictionary = host.anchor_from_hit(hit)
	check("surface anchor records identity and geometry stamp", anchor.reference == "plate" and anchor.has("geometry_stamp"), str(anchor))
	var moved: Array = records.duplicate(true)
	moved[0].pose.origin = Vector3(10,0,0)
	var resolved: Dictionary = PointAnchor.resolve(anchor, moved)
	check("attachment follows placement in object coordinates", resolved.position.is_equal_approx(Vector3(13,3,0)) and not resolved.stale, str(resolved))
	moved[0].stamp = "changed geometry"
	check("changed geometry marks the attachment stale", PointAnchor.resolve(anchor, moved).stale, "")
	check("missing object marks the attachment stale", PointAnchor.resolve(anchor, []).stale, "")
	var pane: Dictionary = host.get_panes()[0]
	var camera = pane.camera
	var before: float = camera.get_distance()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = (pane.viewport_rect as Rect2).get_center()
	host.forward_navigation_input(wheel)
	check("annotation navigation reaches its pane camera", camera.get_distance() < before, str(camera.get_distance()))
	var envelope := {"kind": "cad_surface_arrow", "schema_version": 2, "anchor": anchor,
		"kind_payload": {"label": "hole here", "tail_offset": [-60,-30]},
		"primitives": [{"kind":"arrow", "from":[0,0], "to":[10,10]}]}
	var id: String = host.add_annotation(envelope)
	check("surface arrow validates and stores", not id.is_empty(), str(host.get_annotations()))
	var after: Dictionary = panel._canvas_overlay.annotation(id)
	check("stored arrow retains exact local point", after.get("anchor", {}).get("local", []) == [3.0,3.0,0.0], str(after))
	_teardown(rig)
