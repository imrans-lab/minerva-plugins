extends "test_eval_await.gd"
## End-to-end package check through the real broker, Go export jobs and Python.
const Files := preload("../../ui/scripts/package_files.gd")
const Library := preload("../../ui/scripts/reference_meshes.gd")

class Registry extends RefCounted:
	var definition
	var connection
	func get_db(): return self
	func get_by_id(_id: String): return definition
	func get_connection(_id: String): return connection

func _run() -> void:
	var directory := OS.get_user_data_dir().path_join("package-test-" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	var input := directory.path_join("input.gltf")
	var fixture := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.mesh.size = Vector3(2,2,2)
	mesh.position = Vector3(2,0,0)
	fixture.add_child(mesh)
	mesh.owner = fixture
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	var error := gltf.append_from_scene(fixture, state)
	if error == OK: error = gltf.write_to_filesystem(state, input)
	fixture.free()
	check("setup: reference glTF and external buffer written", error == OK, error_string(error))
	if error != OK: return
	var definition_script := load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var definition = definition_script.from_manifest("res://../../minerva-plugins/cad/manifest.json")
	definition.state = definition_script.get_script_constant_map().State.RUNNING
	var connection_script := load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var connection = connection_script.new("cad-package-test")
	connection.configure_stdio(ProjectSettings.globalize_path("res://../../minerva-plugins/cad/cad-plugin"), PackedStringArray())
	var connected: int = await connection.connect_to_server()
	check("setup: actual CAD backend connected", connected == OK, error_string(connected))
	if connected != OK: return
	var manager := Registry.new()
	manager.definition = definition
	manager.connection = connection
	var rig := _make_rig("cad_package_export")
	if rig.is_empty():
		connection.disconnect_from_server()
		return
	var panel: Node = rig.panel
	rig.broker.unregister_panel("cad", rig.panel_name)
	rig.broker.plugin_manager = manager
	rig.broker.register_panel(panel, "cad", rig.panel_name, PackedStringArray(["cad.evaluate", "cad.export", "cad.cancel_eval", "host.fs.watch", "host.fs.unwatch"]), "cad_panel")
	_document_path = directory.path_join("original.mcad")
	var source := 'solid=cube(2)\nref=mesh(%s,units="mm",up="z")\nsub=assembly([instance(solid,id="pin"),translate([5,0,0],instance(ref,id="board"))])\nscene=assembly([translate([20,0,0],instance(sub,id="module")),translate([0,10,0],instance(solid,id="spare"))])\nscene\n' % JSON.stringify(input)
	var requirements := JSON.stringify({"schema": "minerva.cad.validation/v1", "checks": []})
	Files.write_bytes(_document_path + ".checks.json", requirements.to_utf8_buffer())
	_attach_document(rig, source)
	var ready: Dictionary = await panel.await_evaluation(30000)
	check("source assembled by actual geometry worker", not ready.get("timed_out", false) and _status(panel) == "ok", str(ready).left(600))
	if _status(panel) != "ok":
		_teardown(rig)
		connection.disconnect_from_server()
		return
	var before: Dictionary = panel.get_evaluation_state().duplicate(true)
	var target := directory.path_join("portable")
	var result: Dictionary = await PanelTools.handle(panel, "minerva_cad_package", {"path": target, "wait_ms": 0})
	var deadline := Time.get_ticks_msec() + 60000
	while result.get("status") == "running" and Time.get_ticks_msec() < deadline:
		result = await PanelTools.handle(panel, "minerva_cad_package", {"action": "collect", "ticket": result.ticket, "wait_ms": 1000})
	check("package completes through explicit definition export jobs", result.get("status") == "completed", str(result))
	if result.get("status") == "completed":
		check("package preserves source bytes and displayed assembly", FileAccess.get_file_as_string(result.source_path) == source
			and rig.buffer.text == source and panel.get_evaluation_state() == before
			and FileAccess.get_file_as_string(target.path_join("model.mcad.checks.json")) == requirements, str(result))
		var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(result.manifest))
		check("package retains identities and shared definitions", manifest.assembly_export.instances.size() == 3
			and manifest.model.definitions.size() == 2, str(manifest.assembly_export))
		var library := Library.new()
		for path: String in library.dependency_paths(input):
			DirAccess.remove_absolute(path)
		var moved := directory.path_join("moved")
		check("package can move after its original dependencies disappear", DirAccess.rename_absolute(target, moved) == OK)
		var resolved := library.resolve(input, moved.path_join("model.mcad"))
		var reference = library.load_file(resolved.path, "mm", "z")
		check("unchanged absolute-path DSL resolves bundled geometry and side files", reference.is_ok(), str(resolved))
		var exported = library.load_file(moved.path_join("assembly.glb"))
		check("assembly export retains evaluated world placement and millimetres", exported.is_ok()
			and exported.local_aabb.position.is_equal_approx(Vector3(0,-1,-1))
			and exported.local_aabb.end.is_equal_approx(Vector3(28,12,2)), str(exported.local_aabb))
		var again: Dictionary = await PanelTools.handle(panel, "minerva_cad_package", {"action":"collect", "ticket": "package-" + JSON.stringify([target, source, "scene"]).sha256_text().left(24)})
		check("collection does not rewrite or regenerate a moved package", again == result and not DirAccess.dir_exists_absolute(target), str(again))
		var stale: Dictionary = await PanelTools.handle(panel, "minerva_cad_package", {"path": directory.path_join("stale")})
		check("stale preflight refuses before publishing and never claims a document", not stale.get("success", true)
			and not DirAccess.dir_exists_absolute(directory.path_join("stale")), str(stale))
		_document_path = moved.path_join("model.mcad")
		_attach_document(rig, FileAccess.get_file_as_string(_document_path))
		await panel.await_evaluation(30000)
		var regenerated: Dictionary = await PanelTools.handle(panel, "minerva_cad_package", {"path": directory.path_join("regenerated"), "wait_ms": 0})
		while regenerated.get("status") == "running" and Time.get_ticks_msec() < deadline:
			regenerated = await PanelTools.handle(panel, "minerva_cad_package", {"action":"collect", "ticket":regenerated.ticket, "wait_ms":1000})
		check("reopened package regenerates declared outputs without original assets or scripts", regenerated.get("status") == "completed", str(regenerated))
		if regenerated.get("status") == "completed":
			var second: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(regenerated.manifest))
			check("repackaging preserves bounded dependency paths", second.paths == manifest.paths, str(second.paths))
		var restored: Dictionary = await PanelTools.handle(panel, "minerva_cad_package", {"action":"restore_view"})
		check("package restores views through the existing model and camera mechanisms", restored.get("success", false), str(restored))
		await panel.await_evaluation(30000)
		var missing := Files.freeze(library, [{"path": directory.path_join("absent.glb")}], _document_path, directory.path_join("missing"))
		check("missing dependencies are explicit export failures", str(missing.get("error", "")).contains("missing"), str(missing))
	_teardown(rig)
	connection.disconnect_from_server()
