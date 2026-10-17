extends SceneTree
## Real offscreen PNGs through the production posed-capture owner, in Xvfb.
const Capture: Script = preload("res://../../minerva-plugins/cad/ui/scripts/posed_capture.gd")
var failed: int = 0

class GeometryFixture extends Node3D:
	func get_query_mesh_root() -> Node3D:
		return self

func _init() -> void:
	await process_frame
	var geometry := GeometryFixture.new()
	root.add_child(geometry)
	var solid := MeshInstance3D.new()
	solid.mesh = BoxMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.ORANGE
	solid.material_override = material
	geometry.add_child(solid)
	await process_frame
	var bad: Dictionary = await Capture.snapshot(geometry, {"yaw_deg": -70, "pitch_deg": 12})
	var good: Dictionary = await Capture.snapshot(geometry, {"pose": {"yaw_deg": -70, "pitch_deg": 12},
		"fit": [[-1, -1, -1], [1, 1, 1]], "max_edge": 64,
		"output_path": "user://hitl2-nested.png"})
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://../../minerva-plugins/cad/manifest.json"))
	var schema: Dictionary = {}
	for tool: Dictionary in manifest["tools"]:
		if tool["name"] == "minerva_cad_snapshot_posed":
			schema = tool["input_schema"]
	var pose_schema: Dictionary = schema["properties"]["pose"]
	check("top-level pose fields get actionable guidance; documented nested pose captures",
		bad.get("success") == false and "inside pose" in str(bad.get("error", ""))
		and good.get("success") == true and FileAccess.file_exists(str(good.get("path", "")))
		and pose_schema.get("additionalProperties", true) == false
		and not "pitch_deg" in pose_schema.get("required", [])
		and schema["properties"]["fit"].has("anyOf"))
	var iso: Dictionary = await Capture.snapshot(geometry, {"view": "iso",
		"fit": [[-1, -1, -1], [1, 1, 1]], "max_edge": 64,
		"output_path": "user://hitl2-iso.png"})
	check("view iso without pose still captures",
		iso.get("success") == true and FileAccess.file_exists(str(iso.get("path", ""))))
	print("CAPTURE_RECEIPTS: ", JSON.stringify({"bad": bad, "nested": good, "iso": iso}))
	geometry.free()
	print("=== Results: %d passed, %d failed ===" % [2 - failed, failed])
	quit(1 if failed else 0)

func check(label: String, ok: bool) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failed += 1
