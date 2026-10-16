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
	await _attach_document(rig, "shaft=cube(10,20,30)\nother=translate([100,0,0],cube(20,20,20))\nwhole=shaft+other\nwhole\n")
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
	panel._apply_width_class(&"lg")
	panel._active_viewport_id = "front"
	var projection: OptionButton = panel.get_node(
		"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/FrontView/ProjectionRow/ProjectionDropdown")
	projection.item_selected.emit(0)
	var wide: Dictionary = panel.get_viewports()
	var metadata: Dictionary = panel.snapshot_extra("active")
	var expected_keys := ["projection", "has_geometry", "vertex_count", "face_count", "bounding_box",
		"units", "source_version", "buffer_version", "evaluated_at", "stale"]
	check("wide snapshots expose pane slots, focused pixels and only the declared metadata",
		wide.size() == 5 and wide.has_all(["active", "iso", "top", "front", "right"])
		and wide.active == wide.front and metadata.size() == expected_keys.size()
		and metadata.has_all(expected_keys) and metadata.projection == "Perspective"
		and metadata.has_geometry and metadata.vertex_count > 0 and metadata.face_count > 0
		and metadata.units == "mm" and not metadata.stale, str(metadata))
	panel._apply_width_class(&"sm")
	var narrow: Dictionary = panel.get_viewports()
	check("narrow snapshots expose only the actual single viewport",
		narrow.size() == 1 and narrow.has("active")
		and narrow.active == panel.get_node("ResponsiveContainer/NarrowLayout/SingleView/SubViewport"), str(narrow))
	panel._apply_width_class(&"lg")
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
	var before: Dictionary = panel.get_evaluation_state().duplicate(true)
	args = locator.duplicate()
	args.merge({"part": "shaft", "format": "stl", "path": path, "wait_ms": 0,
		"require_source_version": JSON.parse_string(JSON.stringify(before.source_version))})
	var exported: Dictionary = await registry.handle_tool_call("minerva_cad_export", args)
	check("export starts a collectable backend job", exported.get("status") in ["pending", "completed"]
		and not str(exported.get("job_id", "")).is_empty(), str(exported))
	args["wait_ms"] = 20000
	var initial_complete: Dictionary = await registry.handle_tool_call("minerva_cad_export", args)
	check("an initial completed reply retains export operation provenance", initial_complete.get("status") == "completed"
		and initial_complete.get("provenance", {}).get("operation") == "export"
		and initial_complete.get("provenance", {}).get("format") == "stl"
		and initial_complete.get("provenance", {}).get("part") == "shaft", str(initial_complete))
	var unknown_args := args.duplicate()
	unknown_args["part"] = "no_such_part"
	unknown_args["path"] = directory.path_join("unknown.stl")
	var unknown: Dictionary = await registry.handle_tool_call("minerva_cad_export", unknown_args)
	while unknown.get("status") == "pending":
		unknown = await registry.handle_tool_call("minerva_cad_export", {
			"editor_name": rig.panel_name, "job_id": unknown.get("job_id", ""), "wait_ms": 1000})
	check("unknown part preserves a structured backend error instead of exporting the whole model",
		not unknown.get("success", true) and unknown.get("error", {}).get("kind") == "translate"
		and not FileAccess.file_exists(unknown_args.path), str(unknown))
	var blocked := directory.path_join("blocked.stl")
	var blocker := FileAccess.open(blocked, FileAccess.WRITE)
	if blocker != null:
		blocker.store_string("regular file blocks a child export path")
		blocker.close()
	args["path"] = blocked.path_join("out.stl")
	args["wait_ms"] = 0
	var failed_export: Dictionary = await registry.handle_tool_call("minerva_cad_export", args)
	var failed_id := str(failed_export.get("job_id", failed_export.get("error", {}).get("job_id", "")))
	panel.set_build_mode("manual")
	rig.buffer.apply_edit("part=cube(40,20,30)\npart\n")
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		exported = await registry.handle_tool_call("minerva_cad_export", {
			"editor_name": rig.panel_name, "job_id": exported.get("job_id", ""), "wait_ms": 1000})
		if exported.get("status") != "pending": break
	var library := preload("../../ui/scripts/reference_meshes.gd").new()
	var loaded = library.load_file(path, "mm", "z")
	check("part-only export retains its source provenance while collecting on a stale panel", exported.get("status") == "completed"
		and panel.evaluation_freshness().get("stale", false) and panel.snapshot_extra("active").stale
		and FileAccess.file_exists(path)
		and loaded.is_ok() and is_equal_approx(loaded.local_aabb.size.x, 10.0)
		and exported.get("source_digest") == str(before.source).sha256_text()
		and exported.get("source_version") == before.source_version, str(exported))
	while Time.get_ticks_msec() < deadline:
		failed_export = await registry.handle_tool_call("minerva_cad_export", {
			"editor_name": rig.panel_name, "job_id": failed_id, "wait_ms": 1000})
		if failed_export.get("status") != "pending": break
	var backend_error: Dictionary = await connection.call_tool("cad.export", {"job_id": failed_id})
	check("failed collection preserves the backend error object", failed_export.get("error") == backend_error.get("error")
		and failed_export.get("error", {}).get("kind") == "io"
		and failed_export.get("error", {}).get("status") == "failed"
		and failed_export.get("error", {}).get("job_id") == failed_id, str(failed_export))
	var missing: Dictionary = await registry.handle_tool_call("minerva_cad_export", {"job_id": exported.get("job_id", "")})
	check("job collection requires its editor locator", not missing.get("success", true), str(missing))
	_teardown(rig)
	connection.disconnect_from_server()
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(blocked)
