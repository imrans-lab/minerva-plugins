extends SceneTree
## Geometry report boundary regressions: literal expectations, real cache and rays.
const Clearance = preload("res://../../minerva-plugins/cad/ui/scripts/clearance_client.gd")
const Gauge = preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")
const Geometry = preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")
const Fasteners = preload("res://../../minerva-plugins/cad/ui/scripts/fastener_checks.gd")
var passed := 0
var failed := 0

class SnapshotPanel extends RefCounted:
	var records: Array = []
	func get_reference_state() -> Array:
		return records

func _initialize() -> void:
	call_deferred("_run")

func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _mesh(size: Vector3 = Vector3.ONE) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = size
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
	return mesh

func _run() -> void:
	var c = Clearance.new()
	var pairs := [{"reference":"board", "node":"part", "min_mm":0.505, "bound_mm":0.495, "pass":true}]
	for metadata in [{}, {"tolerance_bounded":"true"}]:
		metadata["required_mm"] = 0.5
		var report: Dictionary = c._clearance_report(metadata, pairs, [], {"fresh":true}, true)
		check("missing or malformed bound cannot pass even with opt-in", not report["pass"] and not report["tolerance_bounded"])
	var mesh := _mesh()
	var a := Transform3D(Basis.IDENTITY, Vector3(300,0,0))
	var b := a
	b.origin.x += 0.001
	var first: Dictionary = c._blob_for({"reference":"board", "node":"part", "mesh":mesh, "xform":a})
	var second: Dictionary = c._blob_for({"reference":"board", "node":"part", "mesh":mesh, "xform":b})
	check("a one-micron move rebuilds triangles", first["digest"] != second["digest"])
	var scaled := a
	scaled.basis.x.x = 1.00000012
	var bodies := [{"mesh":mesh, "node":"part", "reference":"board", "transform":a}]
	var changed := bodies.duplicate(true)
	changed[0]["transform"] = scaled
	check("numerically distinct scales have distinct collider identities", Gauge.bodies_digest(bodies) != Gauge.bodies_digest(changed))
	var records := [{"name":"board", "pose":a, "parts":[{"mesh":mesh, "transform":Transform3D.IDENTITY, "node":"part"}]}]
	var panel := SnapshotPanel.new()
	var f = Fasteners.new()
	for kind in ["local_transform", "mesh", "pose"]:
		panel.records = records.duplicate(true)
		if kind == "local_transform":
			panel.records[0]["parts"][0]["transform"] = Transform3D(Basis.IDENTITY, Vector3(10,0,0))
		elif kind == "mesh":
			panel.records[0]["parts"][0]["mesh"] = _mesh(Vector3(2,2,2))
		else:
			panel.records[0]["pose"] = b
		check("both guards detect " + kind, not c._same_poses(records, panel.records) and not f._same_poses(records, panel))
	var gauge = Gauge.new()
	root.add_child(gauge)
	await process_frame
	# The target's next surface is 0.004 mm away; a sibling starts at 0.001.
	# The latter must not shorten the target's material run below 0.002 mm.
	gauge.build([
		{"mesh":_mesh(Vector3(0.002,1,1)), "transform":Transform3D(Basis.IDENTITY,Vector3(0.005,0,0)), "reference":"board", "node":"target"},
		{"mesh":_mesh(Vector3(0.002,1,1)), "transform":Transform3D(Basis.IDENTITY,Vector3(0.002,0,0)), "reference":"board", "node":"neighbour"},
	], "scoped-ray")
	var ray: Dictionary = await gauge.submit("interference", {"module":self})
	check("material run excludes a sibling node's nearer surface", absf(float(ray.get("run", 0.0)) - 0.004) < 0.00001)
	gauge.queue_free()
	await process_frame
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)

func run_check(gauge: Object, state: PhysicsDirectSpaceState3D, _args: Dictionary) -> Dictionary:
	var geometry = Geometry.new()
	return {"run":geometry._run_along(gauge, state, Vector3.ZERO, Vector3.RIGHT, int(gauge.mask_for("board")), "board", "target")}
