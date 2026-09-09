extends "test_eval_await.gd"
const Watcher := preload("res://Scripts/Services/Watcher/FileWatcherService.gd")
var _reference_path := ""

func _run() -> void:
	_document_path = OS.get_user_data_dir().path_join("cad_dependencies.mcad")
	_reference_path = OS.get_user_data_dir().path_join("cad_dependency.glb")
	_write_box(2)
	var rig := _make_rig("cad_dependencies")
	if rig.is_empty():
		return
	var panel: Node = rig.panel
	# The worker is controlled by this test; reserved host requests still go
	# through the real broker and FileWatcherService.
	panel.request.connect(func(channel: String, payload: Dictionary, reply_id: String):
		if channel.begins_with("host.fs."):
			rig.broker.handle_scene_request(rig.panel_name, channel, payload, reply_id))
	await PanelTools.handle(panel, "minerva_cad_build", {"action": "set_mode", "mode": "manual"})
	_attach_document(rig, SOURCE)
	var answer := _worker_answer()
	answer.result["references"] = [{"name": "module", "path": _reference_path, "units": "mm", "up": "z",
		"matrix": [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]}]
	panel.build_latest()
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), answer)
	await process_frame
	check("painted dependencies subscribe through the host watcher", Watcher.get_instance().is_watched(_reference_path),
		str(panel.get_evaluation_state()))
	var original: Dictionary = panel.get_evaluation_state().dependencies
	var before := _evaluations(rig.dispatched).size()
	var loads: int = panel._reference_library.get_load_count()
	_write_box(4)
	# Direct consumer verification also catches changes between watcher ticks.
	panel.verify_dependencies()
	check("changed imported bytes make the evaluation stale without a DSL edit", panel.evaluation_freshness().stale
		and panel.build_status().build_required and rig.buffer.text == SOURCE, str(panel.evaluation_freshness()))
	await create_timer(0.35).timeout
	check("manual dependency changes retain geometry and do not compile", _evaluations(rig.dispatched).size() == before
		and panel._reference_library.get_load_count() == loads, str(panel.build_status()))
	panel.build_latest()
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), answer)
	await process_frame
	check("explicit rebuild replaces dependency snapshot and loads once for all panes", not panel.evaluation_freshness().stale
		and panel.get_evaluation_state().dependencies != original
		and panel._reference_library.get_load_count() == loads + 1, str(panel.get_evaluation_state().dependencies))
	DirAccess.remove_absolute(_reference_path)
	Watcher.get_instance().tick()
	check("host removal notification invalidates a missing import", panel.evaluation_freshness().stale,
		str(panel.evaluation_freshness()))
	_write_box(6)
	Watcher.get_instance().tick()
	await PanelTools.handle(panel, "minerva_cad_build", {"action": "set_mode", "mode": "automatic"})
	await create_timer(0.4).timeout
	check("automatic mode schedules a dependency rebuild", _evaluations(rig.dispatched).size() == before + 2,
		str(_evaluations(rig.dispatched)))
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), answer)
	await process_frame
	_teardown(rig)
	check("closing the panel releases its dependency watches", not Watcher.get_instance().is_watched(_reference_path), "")
	DirAccess.remove_absolute(_reference_path)

func _write_box(size_mm: float) -> void:
	var fixture := Node3D.new()
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * size_mm
	instance.mesh = mesh
	fixture.add_child(instance)
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_scene(fixture, state)
	if error == OK:
		error = document.write_to_filesystem(state, _reference_path)
	assert(error == OK, "Could not write generic dependency fixture")
	fixture.free()
