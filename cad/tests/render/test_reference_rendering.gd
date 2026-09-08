extends SceneTree
## Pixel regression: imported glTF must remain visible beneath CAD overlays.
## Run with a rendering driver (e.g. xvfb-run godot --rendering-method gl_compatibility).
const PANEL := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const GRID := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
class EditorStub extends RefCounted:
	var tab_title := "reference-rendering"

var passed := 0
var failed := 0

func _init() -> void:
	await process_frame
	await run_checks()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(0 if failed == 0 and passed == 9 else 1)

func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("ok: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)

func settle() -> void:
	for i in range(5):
		await process_frame
	RenderingServer.force_draw(false)

func run_checks() -> void:
	root.size = Vector2i(1280, 900)
	var fixture := Node3D.new()
	var instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.02, 0.03, 0.01)
	instance.mesh = box
	fixture.add_child(instance)
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	var path := "user://reference-rendering.glb"
	var error := gltf.append_from_scene(fixture, state)
	if error == OK:
		error = gltf.write_to_filesystem(state, path)
	fixture.free()
	check("generated glTF fixture", error == OK)
	if error != OK:
		return
	var panel = load(PANEL).instantiate()
	root.add_child(panel)
	panel._on_panel_loaded({"plugin_id": "cad", "panel_name": "cad_panel",
		"host_api_version": "1", "editor": EditorStub.new()})
	panel._apply_width_class(&"lg")
	await settle()
	panel._document_path = ProjectSettings.globalize_path("user://fixture.mcad")
	panel._mount_references([{"name": "box", "path": ProjectSettings.globalize_path(path),
		"units": "m", "up": "y",
		"matrix": [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]}])
	for pane in ["TopView", "FrontView", "RightView", "IsoView"]:
		var viewport: SubViewport = panel.get_node(GRID + "/" + pane + "/SubViewport")
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.get_node("MeshRoot").update_mesh({})
	panel._push_mesh_to_geometry_overlays()
	panel._apply_mesh_visibility()
	await settle()
	for pane in ["TopView", "FrontView", "RightView", "IsoView"]:
		var viewport: SubViewport = panel.get_node(GRID + "/" + pane + "/SubViewport")
		check(pane + " uses its intended projection", viewport.get_camera_3d().projection ==
			(Camera3D.PROJECTION_PERSPECTIVE if pane == "IsoView" else Camera3D.PROJECTION_ORTHOGONAL))
		var layer: Node3D = viewport.get_node("MeshRoot/ReferenceRoot")
		var with_reference := viewport.get_texture().get_image()
		layer.visible = false
		await settle()
		var without_reference := viewport.get_texture().get_image()
		var changed := 0
		if with_reference != null and without_reference != null:
			for y in range(with_reference.get_height()):
				for x in range(with_reference.get_width()):
					if with_reference.get_pixel(x,y) != without_reference.get_pixel(x,y):
						changed += 1
		check(pane + " renders reference pixels (%d changed)" % changed, changed > 20)
		if with_reference != null:
			with_reference.save_png("user://" + pane + ".png")
		layer.visible = true
		await settle()
	panel.free()
	await process_frame
