extends "../gd/test_eval_await.gd"
const QueryContext := preload("../../ui/scripts/query_context.gd")
const Capture := preload("../../ui/scripts/posed_capture.gd")

func _run() -> void:
	root.size = Vector2i(1280, 900)
	_document_path = OS.get_user_data_dir().path_join("scoped-capture.mcad")
	var rig := _make_rig("scoped_capture")
	if rig.is_empty():
		return
	var panel: Node = rig.panel
	_attach_document(rig, SOURCE)
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), _worker_answer())
	await process_frame
	var fixture := Node3D.new()
	var instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(12, 20, 8)
	instance.mesh = box
	fixture.add_child(instance)
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	var path := OS.get_user_data_dir().path_join("scoped-capture.glb")
	var error := gltf.append_from_scene(fixture, state)
	if error == OK:
		error = gltf.write_to_filesystem(state, path)
	fixture.free()
	check("generated reference fixture", error == OK, str(error))
	var references := [{"name": "module/board", "path": path, "units": "mm", "up": "z",
		"matrix": [[1,0,0,80],[0,1,0,15],[0,0,1,5],[0,0,0,1]]}]
	var before: Dictionary = panel.get_evaluation_state().duplicate(true)
	var context := QueryContext.new()
	panel.add_child(context)
	context.setup(panel, before, {"mesh": {"vertices": [], "faces": []}, "model": {
		"configuration": "detached", "selection": "instance:module/board", "physical": false}}, references)
	check("private references use their selected pose", context.get_reference_state().size() == 1
		and context.get_reference_state()[0].world_aabb.get_center().is_equal_approx(Vector3(80,15,5)), str(context.report))
	var reply: Dictionary = await Capture.snapshot(context, {"view": "iso", "fit": "reference:module/board",
		"max_edge": 320, "output_path": OS.get_user_data_dir().path_join("scoped-reference-capture.png")})
	check("private reference-only capture renders pixels", reply.get("success", false) and reply.get("mirrored_instances", 0) > 0, str(reply))
	var loaded := Image.load_from_file(OS.get_user_data_dir().path_join("scoped-reference-capture.png"))
	check("capture contains geometry rather than a blank frame", loaded != null and not loaded.is_empty() and not Capture._is_one_colour(loaded), str(reply))
	check("capture leaves source and active solid unchanged", rig.buffer.text == SOURCE and panel.get_evaluation_state() == before
		and panel.get_reference_state().is_empty(), str(panel.get_evaluation_state()))
	context.queue_free()
	await process_frame
	_teardown(rig)
