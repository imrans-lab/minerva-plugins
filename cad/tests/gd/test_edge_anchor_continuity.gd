extends SceneTree
## Real worker topology feeds the actual edge authoring and resolution paths.
const Host := preload("res://../../minerva-plugins/cad/ui/CadAnnotationHost.gd")
const Tool := preload("res://../../minerva-plugins/cad/ui/tools/cad_edge_number_tool.gd")
const Records := preload("res://../../minerva-plugins/cad/ui/scripts/object_records.gd")
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
	host.set_edge_registry(data.after)
	var same: Dictionary = host._resolve_edge_anchor(survivor.anchor)
	var stale: Dictionary = host._resolve_edge_anchor(consumed.anchor)
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
	print("=== Results: %d passed, %d failed ===" % [2 - failed, failed])
	quit(1 if failed else 0)

func vec(raw: Array) -> Vector3:
	return Vector3(raw[0], raw[1], raw[2])

func check(label: String, ok: bool) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failed += 1
