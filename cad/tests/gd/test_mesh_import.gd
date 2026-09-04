extends SceneTree
## The GUI "Import mesh…" action: a picked file becomes one line of .mcad
## source, written to the SAME DocumentBuffer the paired text editor shows.
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## The trap this action can fall into is invisible on screen: the panel renders
## the mesh, the text editor shows the old source, and the two only disagree
## when the file is saved. So the suite runs the REAL substrate wiring —
## Minerva's own PluginScenePanelBroker and DocumentBuffer, the real CADPanel
## scene — and attaches a second listener to the buffer standing in for the
## text editor's pull (Editor._on_buffer_text_changed does exactly this: assign
## the new text to its CodeEdit). If the import forked the document, that
## listener never sees the mesh() line.
##
## The mesh fixture is BUILT here and written to a temporary GLB. No mesh
## binary is checked in.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"

## Host classes, preloaded by path rather than by class_name: this script is
## parsed from outside Minerva's res:// tree, and the paths are pinned in
## tests/gd/REQUIRED_HOST_FILES so a host refactor fails by name.
const DocumentBufferScript := preload("res://Scripts/Services/Documents/DocumentBuffer.gd")
const PanelBrokerScript := preload("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd")
const MeshImport := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_import.gd")
const ReferenceMeshes := preload("res://../../minerva-plugins/cad/ui/scripts/reference_meshes.gd")

## The document the panel starts from. One binding, so the first generated name
## has something to avoid and the "exactly one line was added" check has a
## before-state to compare against.
const START_SOURCE := "part = cube(10, 10, 10)\n"

## The five MeshRoots a mount has to reach, written out here rather than read
## off the panel: a panel that quietly dropped a pane from its own list would
## still pass a check that used that list.
const MESH_ROOT_PATHS := [
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/TopView/SubViewport/MeshRoot",
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/FrontView/SubViewport/MeshRoot",
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/RightView/SubViewport/MeshRoot",
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/IsoView/SubViewport/MeshRoot",
	"ResponsiveContainer/NarrowLayout/SingleView/SubViewport/MeshRoot",
]

## Identity pose, as the worker reports it in `references[].matrix`.
const POSE_IDENTITY := [
	[1.0, 0.0, 0.0, 0.0],
	[0.0, 1.0, 0.0, 0.0],
	[0.0, 0.0, 1.0, 0.0],
	[0.0, 0.0, 0.0, 1.0],
]

var _pass: int = 0
var _fail: int = 0

var _scratch: String = ""
var _glb_path: String = ""
var _decoy_path: String = ""
var _document_path: String = ""
var _saved_later_path: String = ""


func _init() -> void:
	print("=== CAD GUI Mesh Import Test ===\n")
	await process_frame
	await _run()
	_cleanup()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_scratch = OS.get_user_data_dir()
	_glb_path = _scratch.path_join("cad_import_fixture.glb")
	_decoy_path = _scratch.path_join("cad_import_notes.txt")
	_document_path = _scratch.path_join("cad_import_doc.mcad")
	_saved_later_path = _scratch.path_join("cad_import_saved_as.mcad")

	check("fixture: the built scene wrote a GLB", _write_fixture_glb(_glb_path),
			"GLTFDocument could not write %s" % _glb_path)
	var notes := FileAccess.open(_decoy_path, FileAccess.WRITE)
	if notes != null:
		notes.store_string("not a mesh\n")
		notes.close()
	var document := FileAccess.open(_document_path, FileAccess.WRITE)
	if document != null:
		document.store_string(START_SOURCE)
		document.close()

	_test_the_panel_offers_the_action()
	await _test_import_writes_one_relative_line_to_the_shared_buffer()
	_test_an_unsaved_document_gets_an_absolute_path_and_a_warning()
	_test_the_path_rules_stand_on_their_own()


# ---------------------------------------------------------------------------
# The affordance itself — a GUI-only owner has to be able to reach this
# ---------------------------------------------------------------------------

func _test_the_panel_offers_the_action() -> void:
	var panel := _make_panel()
	if panel == null:
		return

	var wide_button := panel.get_node_or_null(
		"ResponsiveContainer/WideLayout/WideSidebar/ImportMeshButton") as Button
	check("gui: the wide layout carries an Import mesh button declared in the scene",
			wide_button != null and not wide_button.text.strip_edges().is_empty(),
			"button=%s" % str(wide_button))

	var narrow_button := panel.get_node_or_null(
		"ResponsiveContainer/NarrowLayout/ProjectionRow/ImportMeshButton") as Button
	check("gui: the narrow layout carries one too — the action is not lost on a small pane",
			narrow_button != null,
			"no ImportMeshButton in NarrowLayout/ProjectionRow")

	var dialog := panel.get_node_or_null("MeshImportDialog") as FileDialog
	var filters := dialog.filters if dialog != null else PackedStringArray()
	var filter_text := " ".join(filters)
	check("gui: the picker is a scene-declared FileDialog filtered to the loadable formats",
			dialog != null
				and dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE
				and dialog.access == FileDialog.ACCESS_FILESYSTEM
				and filter_text.contains("*.glb") and filter_text.contains("*.gltf"),
			"dialog=%s filters=%s" % [str(dialog), str(filters)])

	check("gui: the picker's choice reaches the import path (file_selected is wired)",
			dialog != null and dialog.file_selected.is_connected(panel._on_mesh_file_selected),
			"file_selected not connected to the panel's handler")

	# The button must actually reach the picker, and the picker must start
	# where a portable relative path can be written: beside the document.
	panel._document_path = _document_path
	if wide_button != null:
		wide_button.pressed.emit()
	check("gui: pressing the button opens the picker beside the document",
			dialog != null and dialog.visible
				and dialog.current_dir.simplify_path().trim_suffix("/") == _document_path.get_base_dir(),
			"visible=%s current_dir='%s'" % [
				str(dialog.visible) if dialog != null else "<no dialog>",
				str(dialog.current_dir) if dialog != null else "",
			])
	if dialog != null:
		dialog.hide()

	panel.free()


# ---------------------------------------------------------------------------
# THE ACCEPTANCE TEST: one buffer, one line, a relative path, an evaluation
# ---------------------------------------------------------------------------

func _test_import_writes_one_relative_line_to_the_shared_buffer() -> void:
	var panel := _make_panel()
	if panel == null:
		return

	# Real substrate: the broker Minerva uses, the buffer Minerva uses.
	var broker = PanelBrokerScript.new()
	broker.register_panel(panel, "cad", "cad_panel", PackedStringArray(["cad.evaluate"]))
	panel._on_panel_loaded({
		"plugin_id": "cad",
		"panel_name": "cad_panel",
		"broker": broker,
		"host_api_version": "1",
	})

	var buffer = DocumentBufferScript.new(_document_path, START_SOURCE)
	# The paired text editor, reduced to the one thing it does with the buffer:
	# pull the new text in (Editor._on_buffer_text_changed).
	var text_pane := CodeEdit.new()
	text_pane.text = buffer.text
	root.add_child(text_pane)
	buffer.text_changed.connect(func(new_text: String, _version: int) -> void:
		text_pane.text = new_text)

	# Everything the panel dispatches, so the evaluation can be observed
	# without a worker.
	var dispatched: Array = []
	panel.request.connect(func(channel: String, payload: Dictionary, _reply_id: String) -> void:
		dispatched.append({"channel": channel, "payload": payload}))

	broker.attach_buffer_to_panel("cad", "cad_panel", buffer)
	check("setup: the panel is attached to the document's buffer",
			panel._buffer_path == _document_path and panel._document_path == _document_path,
			"buffer_path='%s' document_path='%s'" % [panel._buffer_path, panel._document_path])

	var version_before: int = buffer.version
	var plan: Dictionary = panel.import_mesh_file(_glb_path)

	check("import: the picked file is accepted and named",
			bool(plan.get("ok", false)) and str(plan.get("name", "")) == "ref1",
			"plan=%s" % str(plan))
	check("import: the path is written RELATIVE to the saved document",
			str(plan.get("path", "")) == _glb_path.get_file()
				and not bool(plan.get("absolute", true)),
			"path='%s' absolute=%s" % [str(plan.get("path", "")), str(plan.get("absolute", true))])
	check("import: a saved document raises no warning",
			str(plan.get("warning", "")).is_empty(),
			"warning='%s'" % str(plan.get("warning", "")))

	check("buffer: exactly one mesh() line was added, at the end, leaving the source above it",
			buffer.text.begins_with(START_SOURCE)
				and buffer.text.count("mesh(") == 1
				and buffer.text.strip_edges().ends_with("mesh(\"%s\")" % _glb_path.get_file()),
			"buffer text was:\n%s" % buffer.text)
	check("buffer: the write is ONE edit on the existing buffer, not a rewrite",
			buffer.version == version_before + 1,
			"version %d -> %d" % [version_before, buffer.version])
	check("one document: the paired text pane shows the same source",
			text_pane.text == buffer.text,
			"text pane:\n%s\nbuffer:\n%s" % [text_pane.text, buffer.text])
	check("one document: the panel's own mirror is the buffer, not a private copy",
			panel._pending_dsl_text == buffer.text,
			"panel mirror:\n%s" % panel._pending_dsl_text)

	# The action has to make the world change on its own — the owner does not
	# type anything afterwards. Wait out the panel's typing debounce.
	dispatched.clear()
	await create_timer(0.6).timeout
	var evaluated_source := ""
	for entry in dispatched:
		if str(entry["channel"]) == "cad.evaluate":
			evaluated_source = str((entry["payload"] as Dictionary).get("source", ""))
	check("eval: the import dispatched an evaluation of the NEW source",
			evaluated_source == buffer.text,
			"dispatched %d messages; evaluate source was:\n%s" % [dispatched.size(), evaluated_source])

	# What the evaluation comes back with, mounted the way the panel mounts it.
	# The relative path in the line and the panel's document path have to agree
	# or nothing appears in the viewports.
	panel._mount_references([{
		"name": str(plan.get("name", "")),
		"path": str(plan.get("path", "")),
		"units": "m",
		"up": "y",
		"matrix": POSE_IDENTITY,
	}])
	var report: Dictionary = panel._reference_report
	check("world: the imported reference resolves and mounts in the viewports",
			int(report.get("mounted", 0)) == 1
				and (report.get("errors", PackedStringArray()) as PackedStringArray).is_empty(),
			"report=%s" % str(report))
	check("world: the reference is under every pane's MeshRoot, not just one",
			_mounted_reference_count(panel) == 5,
			"mounted under %d of 5 MeshRoots" % _mounted_reference_count(panel))

	# A second import must not shadow the first.
	var second: Dictionary = panel.import_mesh_file(_glb_path)
	check("second import: the new binding is ref2, and ref1 still stands",
			str(second.get("name", "")) == "ref2"
				and buffer.text.contains("ref1 = mesh(")
				and buffer.text.contains("ref2 = mesh("),
			"name='%s' buffer:\n%s" % [str(second.get("name", "")), buffer.text])
	check("second import: two lines, two references, nothing overwritten",
			buffer.text.count("mesh(") == 2 and buffer.version == version_before + 2,
			"mesh lines=%d version=%d" % [buffer.text.count("mesh("), buffer.version])

	# A file the loader cannot read is refused before anything is written.
	var refused_version: int = buffer.version
	var refused: Dictionary = panel.import_mesh_file(_decoy_path)
	check("guard: an unloadable format is refused by name and writes nothing",
			not bool(refused.get("ok", true))
				and str(refused.get("error", "")).contains(_decoy_path.get_file())
				and buffer.version == refused_version,
			"refused=%s version=%d" % [str(refused), buffer.version])

	broker.detach_buffer_from_panel("cad", "cad_panel")
	broker.unregister_panel("cad", "cad_panel")
	text_pane.free()
	panel.free()


# ---------------------------------------------------------------------------
# The anonymous document: absolute, warned about, and still right after Save-As
# ---------------------------------------------------------------------------

func _test_an_unsaved_document_gets_an_absolute_path_and_a_warning() -> void:
	var panel := _make_panel()
	if panel == null:
		return

	var broker = PanelBrokerScript.new()
	broker.register_panel(panel, "cad", "cad_panel", PackedStringArray(["cad.evaluate"]))
	panel._on_panel_loaded({
		"plugin_id": "cad",
		"panel_name": "cad_panel",
		"broker": broker,
		"host_api_version": "1",
	})

	# An editor created in memory: a buffer with no path, exactly what
	# minerva_create_plugin_editor attaches.
	var buffer = DocumentBufferScript.new("", START_SOURCE)
	broker.attach_buffer_to_panel("cad", "cad_panel", buffer)

	var plan: Dictionary = panel.import_mesh_file(_glb_path)
	check("unsaved: the path is absolute, because there is nothing to be relative to",
			str(plan.get("path", "")) == _glb_path and bool(plan.get("absolute", false)),
			"path='%s'" % str(plan.get("path", "")))
	check("unsaved: the owner is warned, on screen, not only in the log",
			not str(plan.get("warning", "")).is_empty()
				and panel._error_banner != null and panel._error_banner.visible
				and panel._error_banner_label.text.contains("Import mesh"),
			"warning='%s' banner_visible=%s text='%s'" % [
				str(plan.get("warning", "")),
				str(panel._error_banner.visible) if panel._error_banner != null else "<none>",
				panel._error_banner_label.text if panel._error_banner_label != null else "",
			])

	# A successful evaluation hides the error banner; the import notice must
	# outlive that, or the owner sees it for under a second.
	panel._hide_eval_error()
	check("unsaved: the warning survives the next successful evaluation",
			panel._error_banner != null and panel._error_banner.visible
				and panel._error_banner_label.text.contains("Import mesh"),
			"banner hidden by _hide_eval_error")

	# Save-As rebinds the buffer in place (it gains a path, nothing re-attaches);
	# the notice must let go then, or the banner is pinned forever.
	buffer.file_path = _saved_later_path
	panel._hide_eval_error()
	check("unsaved: once the buffer has a path the notice lets the banner hide",
			panel._error_banner == null or not panel._error_banner.visible,
			"banner still visible after the buffer gained a path")
	buffer.file_path = ""

	var line_after_import: String = buffer.text

	# Save-As: the buffer gets a path and the substrate re-attaches. The line
	# already written must not change, and must still find the file.
	var saved := FileAccess.open(_saved_later_path, FileAccess.WRITE)
	if saved != null:
		saved.store_string(buffer.text)
		saved.close()
	var saved_buffer = DocumentBufferScript.new(_saved_later_path, buffer.text)
	broker.attach_buffer_to_panel("cad", "cad_panel", saved_buffer)

	check("save-as: the line the import wrote is untouched by the save",
			saved_buffer.text == line_after_import
				and saved_buffer.text.contains("mesh(\"%s\")" % _glb_path),
			"after save-as:\n%s" % saved_buffer.text)

	panel._mount_references([{
		"name": str(plan.get("name", "")),
		"path": str(plan.get("path", "")),
		"units": "m",
		"up": "y",
		"matrix": POSE_IDENTITY,
	}])
	var report: Dictionary = panel._reference_report
	check("save-as: the absolute path still resolves — the reference is in the world",
			int(report.get("mounted", 0)) == 1
				and (report.get("errors", PackedStringArray()) as PackedStringArray).is_empty(),
			"report=%s" % str(report))

	broker.detach_buffer_from_panel("cad", "cad_panel")
	broker.unregister_panel("cad", "cad_panel")
	panel.free()


# ---------------------------------------------------------------------------
# The naming and path arithmetic, on its own
# ---------------------------------------------------------------------------

func _test_the_path_rules_stand_on_their_own() -> void:
	var beside := MeshImport.document_relative_path("/p/case/board.glb", "/p/case/case.mcad")
	check("paths: a mesh beside the document is just its filename",
			str(beside["path"]) == "board.glb" and not bool(beside["absolute"]),
			"got '%s'" % str(beside["path"]))

	var sibling := MeshImport.document_relative_path("/p/boards/main.glb", "/p/case/case.mcad")
	check("paths: a mesh in a sibling directory walks up and back down",
			str(sibling["path"]) == "../boards/main.glb",
			"got '%s'" % str(sibling["path"]))

	var elsewhere := MeshImport.document_relative_path("D:/scans/part.glb", "C:/work/case.mcad")
	check("paths: a mesh sharing no directory with the document stays absolute, with a warning",
			str(elsewhere["path"]) == "D:/scans/part.glb"
				and bool(elsewhere["absolute"])
				and not str(elsewhere["warning"]).is_empty(),
			"got '%s' warning '%s'" % [str(elsewhere["path"]), str(elsewhere["warning"])])

	# The name must dodge what the document already binds, however it got there.
	var hand_written := "part = cube(1, 1, 1)\nref1 = mesh(\"a.glb\")\n"
	check("naming: a name the source already binds is never reused",
			MeshImport.next_reference_name(hand_written) == "ref2",
			"got '%s'" % MeshImport.next_reference_name(hand_written))
	check("naming: a comparison is not a binding",
			not ("width" in MeshImport.bound_names("if width == 10:\n    part = cube(1, 1, 1)\n")),
			"bound names were %s" % str(MeshImport.bound_names("if width == 10:\n    part = cube(1, 1, 1)\n")))

	# A path is a string literal in the source; the quotes have to survive it.
	check("line: a quote or a backslash in the path is escaped, not left to end the literal",
			MeshImport.mesh_line("ref1", "C:\\meshes\\a.glb")
				== "ref1 = mesh(\"C:\\\\meshes\\\\a.glb\")",
			"got '%s'" % MeshImport.mesh_line("ref1", "C:\\meshes\\a.glb"))

	# POSIX allows a newline in a filename, and one line of DSL cannot carry
	# it. Writing it out either breaks the statement or injects a second one.
	var broken := MeshImport.plan_import(
			"", "/tmp/parts/evil\nref9 = mesh(\"other.glb\").glb", "/tmp/doc.mcad")
	check("line: a path containing a newline is refused, and writes nothing",
			not bool(broken.get("ok", true))
				and str(broken.get("error", "")).contains("line break")
				and str(broken.get("source", "x")).is_empty(),
			"plan=%s" % str(broken))

	check("line: a source with no trailing newline does not get the import glued onto it",
			MeshImport.append_line("part = cube(1, 1, 1)", "ref1 = mesh(\"a.glb\")")
				== "part = cube(1, 1, 1)\nref1 = mesh(\"a.glb\")\n",
			"got %s" % JSON.stringify(
				MeshImport.append_line("part = cube(1, 1, 1)", "ref1 = mesh(\"a.glb\")")))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Instantiate the real panel scene into the tree. A null return is reported
## once, as a failure, rather than crashing every later assertion.
func _make_panel() -> Node:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	var panel: Node = packed.instantiate() if packed != null else null
	check("setup: the CAD panel scene instantiates", panel != null,
			"could not instantiate %s" % PANEL_SCENE_PATH)
	if panel != null:
		root.add_child(panel)
	return panel


## How many of the five MeshRoots hold a mounted reference layer with geometry.
func _mounted_reference_count(panel: Node) -> int:
	var found := 0
	for mesh_root_path in MESH_ROOT_PATHS:
		var mesh_root := panel.get_node_or_null(mesh_root_path)
		if mesh_root == null:
			continue
		var layer := mesh_root.get_node_or_null(ReferenceMeshes.LAYER_NODE_NAME)
		if layer != null and layer.get_child_count() > 0:
			found += 1
	return found


## A one-box GLB, written with Godot's own exporter. Small on purpose: this
## suite is about the source line, not about geometry — test_reference_meshes.gd
## owns the conversion arithmetic.
func _write_fixture_glb(path: String) -> bool:
	var scene_root := Node3D.new()
	scene_root.name = "Scene"
	var box := BoxMesh.new()
	box.size = Vector3(0.01, 0.01, 0.01)
	var instance := MeshInstance3D.new()
	instance.name = "Box"
	instance.mesh = box
	scene_root.add_child(instance)
	instance.owner = scene_root

	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var err := document.append_from_scene(scene_root, state)
	if err == OK:
		err = document.write_to_filesystem(state, path)
	scene_root.free()
	return err == OK


func _cleanup() -> void:
	for path in [_glb_path, _decoy_path, _document_path, _saved_later_path]:
		if path != "" and FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func check(desc: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)
