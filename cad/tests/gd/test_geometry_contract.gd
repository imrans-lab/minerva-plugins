extends SceneTree
## Geometry report boundary regressions: literal expectations, real cache and rays.
const Clearance = preload("res://../../minerva-plugins/cad/ui/scripts/clearance_client.gd")
const Gauge = preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")
const Geometry = preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")
const Fasteners = preload("res://../../minerva-plugins/cad/ui/scripts/fastener_checks.gd")
var passed := 0
var failed := 0

## The frame budget every awaited job gets. Long enough for a physics answer,
## short enough that a coroutine which never resumes ends the suite.
const TIMEOUT_FRAMES := 600

class SnapshotPanel extends RefCounted:
	var records: Array = []
	func get_reference_state() -> Array:
		return records

## A panel whose worker answers one canned clearance reply, wrapped in the two
## envelopes call_backend() really returns (broker, then worker).
class ReplyPanel extends RefCounted:
	var reply: Dictionary = {}
	func call_backend(_method: String, _payload: Dictionary,
			_timeout_ms: int = 30000) -> Dictionary:
		# Awaited by the caller, so it yields once like the real IPC round trip.
		await (Engine.get_main_loop() as SceneTree).process_frame
		return {"success": true, "result": {"ok": true, "result": reply}}

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
	await _check_measure_refuses_unbounded_metadata()
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
	# Bounded like every other suite's await: a job that never answers fails
	# the check instead of parking the SceneTree forever.
	var rays: Array = []
	_collect_ray(gauge, rays)
	for _frame in range(TIMEOUT_FRAMES):
		if not rays.is_empty():
			break
		await process_frame
	var ray: Dictionary = rays[0] if not rays.is_empty() else {}
	check("material run excludes a sibling node's nearer surface", absf(float(ray.get("run", 0.0)) - 0.004) < 0.00001)
	gauge.queue_free()
	await process_frame
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)

## `_clearance_report` is only half the tolerance_bounded contract: the field
## arrives from the WORKER, so `_measure` has to refuse a reply that does not
## carry it as a bool before any pair reaches the grader. A reply whose flag is
## the string "true" must come back checked:false with a reason naming the
## field — a report that is checked, or one that passes, would show a
## non-bool being read as truthy somewhere between the two.
func _check_measure_refuses_unbounded_metadata() -> void:
	var c = Clearance.new()
	var panel := ReplyPanel.new()
	var pairs := [{"reference":"board", "node":"part", "min_mm":0.505,
		"bound_mm":0.495, "pass":true}]
	var batches := [[{"key":"digest", "reference":"board", "node":"part"}]]
	var head := {"required_mm":0.5, "tessellation_tolerance_mm":0.01}

	panel.reply = {"checked":true, "tolerance_bounded":"true", "pairs":pairs,
		"tessellation_tolerance_mm":0.01}
	var refused: Dictionary = await c._measure(panel, head, batches, [],
		{"fresh":true}, true)
	panel.reply = {"checked":true, "tolerance_bounded":true, "pairs":pairs,
		"tessellation_tolerance_mm":0.01}
	var answered: Dictionary = await c._measure(panel, head, batches, [],
		{"fresh":true}, true)
	check("a worker reply whose tolerance_bounded is not a bool is refused by name, never passed",
		not bool(refused.get("checked", true))
			and not bool(refused.get("pass", true))
			and str(refused.get("reason", "")).contains("tolerance_bounded")
			and (refused.get("pairs", []) as Array).is_empty()
			and bool(answered.get("checked", false)))


func _collect_ray(gauge: Object, into: Array) -> void:
	var ray: Dictionary = await gauge.submit("interference", {"module":self})
	into.append(ray)


func run_check(gauge: Object, state: PhysicsDirectSpaceState3D, _args: Dictionary) -> Dictionary:
	var geometry = Geometry.new()
	return {"run":geometry._run_along(gauge, state, Vector3.ZERO, Vector3.RIGHT, int(gauge.mask_for("board")), "board", "target")}
