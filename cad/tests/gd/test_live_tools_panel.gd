extends "test_eval_await.gd"
## One real panel/registry/broker/backend flow for the migrated live tools.

class BackendRegistry extends RefCounted:
	var definition: PluginDefinition
	var connection: Object
	func get_db() -> RefCounted: return self
	func get_by_id(_id: String) -> PluginDefinition: return definition
	func get_connection(_id: String) -> Object: return connection

func _run() -> void:
	create_timer(90.0).timeout.connect(func() -> void: quit(1))
	var directory := OS.get_user_data_dir().path_join("live-tools-contract")
	DirAccess.make_dir_recursive_absolute(directory)
	_document_path = directory.path_join("box.mcad")
	var definition: PluginDefinition = PluginDefinition.from_manifest(
		"res://../../minerva-plugins/cad/manifest.json")
	definition.state = PluginDefinition.State.RUNNING
	var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new("cad-live-tools")
	connection.configure_stdio(ProjectSettings.globalize_path(
		"res://../../minerva-plugins/cad/cad-plugin"), PackedStringArray())
	var connected: int = await connection.connect_to_server()
	check("source-built CAD backend connects", connected == OK, error_string(connected))
	if connected != OK: return
	var manager := BackendRegistry.new()
	manager.definition = definition
	manager.connection = connection
	var rig := _make_rig("cad_live_tools")
	if rig.is_empty():
		connection.disconnect_from_server()
		return
	var panel: Node = rig.panel
	rig.broker.unregister_panel("cad", rig.panel_name)
	rig.broker.plugin_manager = manager
	rig.broker.register_panel(panel, "cad", rig.panel_name,
		PackedStringArray(["cad.evaluate", "cad.export", "cad.cancel_eval"]), "cad_panel")
	await _attach_document(rig, "part=cube(10,20,30)\npart\n")
	var ready: Dictionary = await panel.await_evaluation(30000)
	check("real geometry reaches the CAD panel", not ready.get("timed_out", false)
		and _status(panel) == "ok", str(ready).left(600))
	if _status(panel) != "ok":
		_teardown(rig)
		connection.disconnect_from_server()
		return
	var registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd").new()
	registry.scene_panel_broker = rig.broker
	var registered: Dictionary = registry.register_plugin_tools("cad", definition.tools)
	check("the actual manifest tools register through the host", not registered.has("error"), str(registered))
	var locator := {"editor_name": rig.panel_name}
	var mesh: Dictionary = await registry.handle_tool_call("minerva_cad_get_mesh_info", locator)
	var edges: Dictionary = await registry.handle_tool_call("minerva_cad_list_edges", locator)
	check("mesh and edge inspection read the evaluated box", mesh.get("has_geometry", false)
		and int(mesh.get("vertex_count", 0)) > 0 and not edges.get("edges", []).is_empty(), str([mesh, edges]))
	if edges.get("edges", []).is_empty():
		_teardown(rig)
		connection.disconnect_from_server()
		return
	var edge_id := int(edges.edges[0].id)
	var args := locator.duplicate()
	args["edge_id"] = edge_id
	var edge: Dictionary = await registry.handle_tool_call("minerva_cad_get_edge", args)
	var host: AnnotationHost = panel.get_annotation_host()
	host.call("set_selected_edge_id", edge_id)
	var selected: Dictionary = await registry.handle_tool_call("minerva_cad_get_selected_edge", locator)
	check("edge lookup and selected edge agree with the real host", edge.get("edge", {}).get("id") == edge_id
		and selected.get("selected_edge_id") == edge_id, str([edge, selected]))
	args = locator.duplicate()
	args["edge_ids"] = [edge_id]
	args["group_id"] = "contract"
	var annotated: Dictionary = await registry.handle_tool_call("minerva_cad_annotate_edges", args)
	check("annotation tool creates a live edge anchor", annotated.get("created_edge_ids") == [edge_id], str(annotated))
	host.add_annotation({"kind": "cad_edge_number", "schema_version": 2,
		"author": {"kind": "human"}, "anchor": {"plugin": "cad", "type": "edge", "id": edge_id},
		"payload": {"text": "user intent", "group_id": "human", "box_offset": [0,0,0]}})
	var labels: Dictionary = await registry.handle_tool_call("minerva_cad_list_user_labels", locator)
	check("user label listing excludes the agent label", labels.get("count") == 1
		and labels.labels[0].text == "user intent", str(labels))
	args = locator.duplicate()
	args["group_id"] = "contract"
	var cleared: Dictionary = await registry.handle_tool_call("minerva_cad_clear_edge_annotations", args)
	check("group clear preserves the human annotation", cleared.get("cleared_count") == 1
		and host.get_annotations().size() == 1, str(cleared))
	var path := directory.path_join("box.stl")
	args = locator.duplicate()
	args.merge({"format": "stl", "path": path, "wait_ms": 0})
	var exported: Dictionary = await registry.handle_tool_call("minerva_cad_export", args)
	check("export starts a collectable backend job", exported.get("status") in ["pending", "completed"]
		and not str(exported.get("job_id", "")).is_empty(), str(exported))
	panel.set_build_mode("manual")
	rig.buffer.apply_edit("part=cube(40,20,30)\npart\n")
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		exported = await registry.handle_tool_call("minerva_cad_export", {
			"editor_name": rig.panel_name, "job_id": exported.get("job_id", ""), "wait_ms": 1000})
		if exported.get("status") != "pending": break
	check("collection succeeds while the panel is stale and writes a real STL", exported.get("status") == "completed"
		and panel.evaluation_freshness().get("stale", false) and FileAccess.file_exists(path)
		and FileAccess.get_file_as_bytes(path).size() > 84, str(exported))
	var missing: Dictionary = await registry.handle_tool_call("minerva_cad_export", {"job_id": exported.get("job_id", "")})
	check("job collection requires its editor locator", not missing.get("success", true), str(missing))
	_teardown(rig)
	connection.disconnect_from_server()
	DirAccess.remove_absolute(path)
