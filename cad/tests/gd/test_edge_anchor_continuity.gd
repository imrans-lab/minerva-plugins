extends SceneTree
## Real worker topology feeds the actual edge authoring and resolution paths.
const Host := preload("res://../../minerva-plugins/cad/ui/CadAnnotationHost.gd")
const Tool := preload("res://../../minerva-plugins/cad/ui/tools/cad_edge_number_tool.gd")
const Records := preload("res://../../minerva-plugins/cad/ui/scripts/object_records.gd")
const LiveTools := preload("res://../../minerva-plugins/cad/ui/scripts/live_tools.gd")

const Kind := preload("res://../../minerva-plugins/cad/ui/kinds/cad_edge_number_kind.gd")
const Layout := preload("res://../../minerva-plugins/cad/ui/kinds/cad_edge_label_layout.gd")
# Record draw commands, using the same render facade as test_source_annotations.
class Drawing extends AnnotationRenderContext:
	var labels: Array[String] = []
	func draw_line(_a: Vector2, _b: Vector2, _color: Color, _width: float = 1.0) -> void:
		pass
	func draw_rect(_rect: Rect2, _color: Color, _filled: bool, _width: float = 1.0) -> void:
		pass
	func draw_polygon(_points: PackedVector2Array, _colors: PackedColorArray) -> void:
		pass
	func draw_string(_font: Font, _pos: Vector2, text: String, _color: Color, _size: int = 16) -> void:
		labels.append(text)

# Routing adapter only: the real tools and annotation host own all behavior.
class TestPanel extends RefCounted:
	var host: AnnotationHost
	func _init(value: AnnotationHost) -> void:
		host = value
	func get_annotation_host() -> AnnotationHost:
		return host

var failed: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var fixture_path: String = OS.get_environment("CAD_ANCHOR_FIXTURE")
	if fixture_path.is_empty():
		fixture_path = ProjectSettings.globalize_path("user://edge-anchor-fixture.json")
		OS.set_environment("CAD_ANCHOR_FIXTURE", fixture_path)
		var worker := ProjectSettings.globalize_path("res://../../minerva-plugins/cad/worker")
		var python: String = OS.get_environment("CAD_PYTHON")
		if python.is_empty():
			python = worker.path_join(".venv/Scripts/python.exe" if OS.get_name() == "Windows" else ".venv/bin/python")
		var output: Array = []
		var fixture_script := ProjectSettings.globalize_path("res://../../minerva-plugins/cad/tests/gd/edge_anchor_fixture.py")
		if OS.execute(python, [fixture_script], output, true) != 0:
			printerr("FAIL: real CAD worker fixture prerequisite: ", output)
			quit(1)
			return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(fixture_path))
	assert(not data.is_empty())
	var host := Host.new()
	var tool := Tool.new()
	tool._host = host
	host.set_edge_registry(data.before)
	var survivor: Dictionary = tool._build_annotation(int(data.survivor.id), Vector3.ZERO)
	var consumed: Dictionary = tool._build_annotation(int(data.consumed.id), Vector3.ZERO)
	assert(not host.add_annotation(survivor).is_empty())
	assert(not host.add_annotation(consumed).is_empty())
	var tools := LiveTools.new(TestPanel.new(host))
	var authored: Dictionary = await tools.handle("minerva_cad_annotate_edges", {"edge_ids": [int(data.survivor.id)]})
	var annotations: Array = host.get_annotations()
	var agent_annotation: Dictionary = annotations.back()
	host.set_edge_registry(data.after)
	var listing: Dictionary = await tools.handle("minerva_cad_list_user_labels", {})
	var labels: Array = listing.get("labels", [])
	var agent_resolved: Dictionary = host._resolve_edge_anchor(agent_annotation.anchor)
	check("agent tools author geometry and report the current survivor id or stale saved midpoint",
		bool(authored.get("success", false)) and agent_annotation.anchor.has("geometry")
		and not agent_resolved.stale and agent_resolved.edge_id == int(data.survivor_after.id)
		and labels.size() == 2 and labels[0].edge_id == int(data.survivor_after.id) and not labels[0].stale
		and labels[1].edge_id == -1 and labels[1].stale
		and vec(labels[1].midpoint).distance_to(vec(data.consumed.midpoint)) < 0.0001)
	var same: Dictionary = host._resolve_edge_anchor(survivor.anchor)
	var stale: Dictionary = host._resolve_edge_anchor(consumed.anchor)
	_check_label_presentation(host, tool, data)
	var midpoint := vec(data.survivor.midpoint)
	var remembered := vec(data.consumed.midpoint)
	var legacy: Dictionary = host._resolve_edge_anchor({"plugin": "cad", "type": "edge", "id": data.after[0].id})
	var ok: bool = not same.stale and same.edge_id == int(data.survivor_after.id) \
		and int(data.survivor.id) != same.edge_id and same.position.distance_to(midpoint) < 0.0001 \
		and stale.stale and stale.position.distance_to(remembered) < 0.0001 and not legacy.stale
	# An ambiguous signature must never pick the first entry, even at the old id.
	var ambiguous: Array = data.after.duplicate(true)
	var duplicate: Dictionary = data.survivor_after.duplicate(true)
	duplicate.id = 999
	ambiguous.append(duplicate)
	host.set_edge_registry(ambiguous)
	var unresolved: Dictionary = host._resolve_edge_anchor(survivor.anchor)
	ok = ok and unresolved.stale and unresolved.position.distance_to(midpoint) < 0.0001
	# Full-circle endpoints coincide; its registry midpoint is on the other side.
	host.set_edge_registry(data.circle)
	var circle: Dictionary = tool._build_annotation(int(data.circle_edge.id), Vector3.ZERO)
	var circle_resolved: Dictionary = host._resolve_edge_anchor(circle.anchor)
	ok = ok and not circle_resolved.stale \
		and circle_resolved.position.distance_to(vec(data.circle_edge.midpoint)) < 0.0001
	check("edge labels follow unique surviving geometry; consumed or ambiguous edges stay at saved midpoints; legacy and circles work", ok)
	# The neighboring point-anchor contract still resolves a surface arrow on
	# this same chamfered solid, with its geometry stamp and exact local point.
	var records: Array = Records.build({"shape_name": "part", "picking": {"part": data.mesh}}, [])
	assert(records.size() == 1)
	host.set_reference_records(records)
	var point := vec(data.mesh.vertices[0])
	var anchor: Dictionary = host.anchor_from_hit({"record": records[0], "node": "part",
		"local": point, "world": point, "normal": Vector3.UP})
	var arrow := {"kind": "cad_surface_arrow", "anchor": anchor}
	var attached: Dictionary = host.resolve_point_anchor(arrow.anchor)
	check("surface arrow retains its stamped point on the same model",
		anchor.has("geometry_stamp") and not attached.stale and attached.position.distance_to(point) < 0.0001)
	tool._host = null
	print("=== Results: %d passed, %d failed ===" % [5 - failed, failed])
	quit(1 if failed else 0)

func _check_label_presentation(host: Host, tool: Tool, data: Dictionary) -> void:
	var stored: Array = host.get_annotations()
	var survivor: Dictionary = stored[0]
	var consumed: Dictionary = stored[1]
	# A live edge now owns the consumed edge's old evaluation-local number.
	var consumed_record: Dictionary = data.consumed
	var consumed_number: float = consumed_record.id
	var replacement: Dictionary = tool._build_annotation(int(consumed_number), Vector3.ZERO)
	assert(not host.add_annotation(replacement).is_empty())
	stored = host.get_annotations()
	var live_replacement: Dictionary = stored.back()
	var viewport := SubViewport.new()
	viewport.size = Vector2i(512, 512)
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.position = Vector3(30, -30, 30)
	camera.look_at(Vector3.ZERO, Vector3(0, 0, 1))
	host.set_viewport_for("iso", viewport)
	host.set_camera_for("iso", camera)
	AnnotationHostRegistry.register("batch3_edge_labels", host)
	var rect := Rect2(0, 0, 512, 512)
	var positions: Dictionary = Layout.get_layout(host, camera, rect, stored)
	var stale_key: String = str(consumed.id)
	var replacement_key: String = str(live_replacement.id)
	var stale_position: Vector2 = positions.get(stale_key, Vector2.ZERO)
	var replacement_position: Vector2 = positions.get(replacement_key, Vector2.ZERO)
	var drawing := Drawing.new()
	drawing.host = host
	var kind := Kind.new()
	kind.render(drawing, consumed)
	var stale_bounds: Rect2 = kind.bounds(consumed)
	check("stale label draws ? and owns a layout slot apart from its reused old number",
		drawing.labels == ["?"] and positions.has(stale_key) and positions.has(replacement_key)
		and stale_position.distance_to(replacement_position) > 1.0
		and stale_bounds.get_center().distance_to(stale_position) < 0.01)
	drawing.labels.clear()
	kind.render(drawing, survivor)
	var survivor_record: Dictionary = data.survivor_after
	var current_number: float = survivor_record.id
	var current_id: int = int(current_number)
	var live_key: String = str(survivor.id)
	# Support the unchanged-base key as well, so this anti-case passes there.
	var has_live_position: bool = positions.has(live_key) or positions.has(current_id)
	var live_position: Vector2 = positions.get(live_key, positions.get(current_id, Vector2.ZERO))
	var live_bounds: Rect2 = kind.bounds(survivor)
	check("renumbered live label keeps its current title and slot; stale hit target survives",
		drawing.labels == [str(current_id)] and has_live_position
		and live_bounds.get_center().distance_to(live_position) < 0.01
		and stale_bounds.size.x > 0.0 and stale_bounds.size.y > 0.0
		and kind.hit_test(consumed, stale_bounds.get_center(), 0.0))
	AnnotationHostRegistry.deregister("batch3_edge_labels", host)
	viewport.free()

func vec(raw: Array) -> Vector3:
	return Vector3(raw[0], raw[1], raw[2])

func check(label: String, ok: bool) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failed += 1
