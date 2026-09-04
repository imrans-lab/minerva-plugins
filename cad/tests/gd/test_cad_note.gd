extends SceneTree
## Save-to-note and back: the plugin_data payload, the restore that reopens a
## live CAD tab, and the multimodal rendering — ui/scripts/cad_note.gd, wired
## through the real CADPanel scene.
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## TWO PANELS, NOT ONE. The claim is not "a payload round-trips through a
## function" — it is "the tab I closed comes back". So the suite instantiates
## the real panel scene twice: one is set up and saved, then freed the way
## closing a tab frees it, and a second, untouched panel is restored from the
## note. Everything asserted afterwards is read off the SECOND panel, and the
## control assertion pins that its cameras were at their defaults first, so
## nothing can pass by having been true all along.
##
## THROUGH THE WIRE, NOT THROUGH MEMORY. The payload is passed through
## JSON.stringify → JSON.parse in exactly the wrapper Note.create_plugin_data_note
## writes, before it is restored. That is what the host really does, and it is
## what turns a Vector3 or a Transform3D that leaked into the payload into a
## visible failure rather than a silent one. A separate assertion walks the
## payload and refuses any value that is not a JSON-native type, so the leak is
## named rather than merely surviving as a string.
##
## NO WORKER. Nothing here evaluates: the panel's IPC helper is absent, so the
## evaluation a restore starts returns "ipc_unavailable" immediately and never
## draws. That is deliberate — it means the references and the camera the
## reopened tab shows came from the NOTE, which is the property under test.
## The auto-frame that a real evaluation would perform is simulated explicitly
## (a camera moved out from under the restore) so the two-step that survives it
## is pinned rather than assumed.
##
## THE FIXTURE is a single box written to a temporary GLB and declared
## units="mm" up="z", so the frame conversion is the identity: conversion has
## its own suite (test_reference_meshes.gd) and would only obscure the question
## here, which is whether the reference came back at all.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const CadNote := preload("res://../../minerva-plugins/cad/ui/scripts/cad_note.gd")
const ReferenceMeshes := preload("res://../../minerva-plugins/cad/ui/scripts/reference_meshes.gd")
const CAD_PANEL_SOURCE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.gd"

const TOLERANCE_MM := 0.01

## The document the saved tab is showing. Text, because the DSL source IS the
## document — the note carries this string and nothing else stands for it.
const DOCUMENT_SOURCE := """plate = box(40, 30, 4)
ref1 = mesh("block.glb")
translate(ref1, [100, 200, 300])
"""

## The fixture box, in the reference file's own frame (millimetres).
const BLOCK_LOCAL_MIN := Vector3(-20.0, -15.0, -2.0)
const BLOCK_LOCAL_MAX := Vector3(20.0, 15.0, 2.0)
## The same box after translate([100, 200, 300]).
const BLOCK_WORLD_MIN := Vector3(80.0, 185.0, 298.0)
const BLOCK_WORLD_MAX := Vector3(120.0, 215.0, 302.0)

## translate([100, 200, 300]), row-major, as the worker reports it.
const POSE_TRANSLATE := [
	[1.0, 0.0, 0.0, 100.0],
	[0.0, 1.0, 0.0, 200.0],
	[0.0, 0.0, 1.0, 300.0],
	[0.0, 0.0, 0.0, 1.0],
]

## The view the user left the saved tab in. Every number is off the OrbitCamera
## defaults (target ZERO, distance 300, yaw -45, pitch 30) so a restore that
## does nothing at all cannot pass.
const SAVED_TARGET := Vector3(12.0, 34.0, 56.0)
const SAVED_DISTANCE := 250.0
const SAVED_YAW := 17.0
const SAVED_PITCH := -23.0
## The top pane is left on its own preset, so a restore that copies one
## camera's state over every pane is caught.
const SAVED_TOP_PRESET := "Top"

## A solid, in the shape the worker actually emits: mesh.vertices is a list of
## [x, y, z] triples (worker/mcad/evaluator.py), not a flat float array.
const SOLID_VERTICES := [
	[0.0, 0.0, 0.0],
	[10.0, 0.0, 0.0],
	[10.0, 20.0, 0.0],
	[0.0, 20.0, 5.0],
]
const SOLID_MIN := Vector3(0.0, 0.0, 0.0)
const SOLID_MAX := Vector3(10.0, 20.0, 5.0)

var _pass: int = 0
var _fail: int = 0
var _glb_path: String = ""
var _document_path: String = ""
var _saving_panel: Node = null
var _reopened_panel: Node = null


func _init() -> void:
	print("=== CAD Note Round-Trip Test ===\n")
	await process_frame

	_glb_path = OS.get_user_data_dir().path_join("cad_note_block.glb")
	_document_path = OS.get_user_data_dir().path_join("cad_note_fixture.mcad")
	var written := _write_fixture_glb(_glb_path)
	check("setup: the fixture GLB is written", written,
			"GLTFDocument could not write %s" % _glb_path)
	if written:
		await _run()

	_cleanup()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_saving_panel = _instantiate_panel("setup: the saving panel instantiates")
	if _saving_panel == null:
		return
	_saving_panel.size = Vector2(1200.0, 800.0)
	await process_frame
	_prepare_saved_tab(_saving_panel)

	await _test_payload()
	await _test_round_trip()
	_test_pending_camera()
	_test_refusals()
	_test_render_for_llm()
	_test_counting()
	_test_panel_wiring()


# ---------------------------------------------------------------------------
# The payload
# ---------------------------------------------------------------------------

func _test_payload() -> void:
	print("\npayload:")
	var payload: Dictionary = CadNote.build_payload(_saving_panel)

	check("payload names its schema", str(payload.get("schema", "")) == CadNote.SCHEMA,
			"schema=%s" % str(payload.get("schema", "")))
	check("payload names its version", int(payload.get("version", 0)) == CadNote.VERSION,
			"version=%s" % str(payload.get("version", null)))
	check("payload carries the document source verbatim",
			str(payload.get("source", "")) == DOCUMENT_SOURCE,
			"got %d chars" % str(payload.get("source", "")).length())
	check("payload carries the document path",
			str(payload.get("document_path", "")) == _document_path,
			"path=%s" % str(payload.get("document_path", "")))

	var offender: String = _first_non_json_value(payload, "payload")
	check("every value in the payload is a JSON-native type", offender.is_empty(),
			offender)

	var cameras: Dictionary = payload.get("cameras", {}) as Dictionary
	var iso: Dictionary = cameras.get("iso", {}) as Dictionary
	var top: Dictionary = cameras.get("top", {}) as Dictionary
	check("payload carries every pane's camera, with the view the user left",
			cameras.size() == 4
			and _near(float(iso.get("distance", 0.0)), SAVED_DISTANCE)
			and _near(float(iso.get("yaw", 0.0)), SAVED_YAW)
			and _near(float(iso.get("pitch", 0.0)), SAVED_PITCH)
			and _to_vec(iso.get("target", [])).distance_to(SAVED_TARGET) < TOLERANCE_MM
			and str(top.get("view_preset", "")) == SAVED_TOP_PRESET,
			"cameras=%s" % str(cameras))

	var references: Array = payload.get("references", []) as Array
	var reference: Dictionary = references[0] as Dictionary if references.size() == 1 else {}
	var matrix: Variant = reference.get("matrix", [])
	check("payload carries the mesh() spec the evaluation named",
			str(reference.get("name", "")) == "ref1"
			and str(reference.get("path", "")) == _glb_path
			and str(reference.get("units", "")) == "mm"
			and str(reference.get("up", "")) == "z"
			and matrix is Array and (matrix as Array).size() == 4
			and _near(float((matrix[0] as Array)[3]), 100.0),
			"references=%s" % str(references))


# ---------------------------------------------------------------------------
# The round trip
# ---------------------------------------------------------------------------

func _test_round_trip() -> void:
	print("\nround trip:")
	# The note the host is handed, and the wrapper it stringifies.
	var note: Dictionary = await CadNote.build_note({
		"plugin_id": "cad",
		"panel_name": "cad_panel",
		"tab_title": "block.mcad",
	}, _saving_panel)
	check("the note the host receives is plugin_data addressed to this panel",
			str(note.get("kind", "")) == "plugin_data"
			and str(note.get("plugin_id", "")) == "cad"
			and str(note.get("panel_name", "")) == "cad_panel"
			and note.get("payload", null) is Dictionary
			and not str(note.get("preview_alt_text", "")).is_empty(),
			"note keys=%s" % str(note.keys()))

	var wire: String = JSON.stringify({
		"version": 1,
		"plugin_id": str(note.get("plugin_id", "")),
		"panel_name": str(note.get("panel_name", "")),
		"payload": note.get("payload", {}),
	})
	var parsed: Variant = JSON.parse_string(wire)
	check("the wrapper the host writes parses back to a Dictionary",
			parsed is Dictionary and (parsed as Dictionary).get("payload", null) is Dictionary,
			"wire=%s" % wire.substr(0, 200))
	if not (parsed is Dictionary):
		return
	var restored_payload: Dictionary = (parsed as Dictionary).get("payload", {}) as Dictionary

	# The tab is closed.
	root.remove_child(_saving_panel)
	_saving_panel.free()
	_saving_panel = null

	# The note is opened: a fresh panel, untouched.
	_reopened_panel = _instantiate_panel("setup: the reopening panel instantiates")
	if _reopened_panel == null:
		return
	_reopened_panel.size = Vector2(1200.0, 800.0)
	await process_frame

	var fresh_iso: Camera3D = _reopened_panel.get_view_camera("iso")
	check("control: the reopening panel starts at the camera defaults",
			fresh_iso != null
			and _near(fresh_iso.get_distance(), 300.0)
			and fresh_iso.get_target().distance_to(Vector3.ZERO) < TOLERANCE_MM,
			"distance=%s target=%s" % [
				str(fresh_iso.get_distance()) if fresh_iso != null else "no camera",
				str(fresh_iso.get_target()) if fresh_iso != null else "-"])

	check("the restore succeeds", CadNote.restore(restored_payload, _reopened_panel))

	var state: Dictionary = _reopened_panel.get_document_state()
	check("the reopened tab holds the same source text",
			str(state.get("source", "")) == DOCUMENT_SOURCE,
			"got %d chars" % str(state.get("source", "")).length())
	check("the reopened tab holds the same document path",
			str(state.get("path", "")) == _document_path,
			"path=%s" % str(state.get("path", "")))

	var iso: Camera3D = _reopened_panel.get_view_camera("iso")
	check("the reopened tab has an iso camera to restore", iso != null)
	if iso == null:
		return
	check("the reopened tab looks where the saved tab was looking",
			iso.get_target().distance_to(SAVED_TARGET) < TOLERANCE_MM
			and _near(iso.get_distance(), SAVED_DISTANCE)
			and _near(iso.get_yaw(), SAVED_YAW)
			and _near(iso.get_pitch(), SAVED_PITCH),
			"target=%s distance=%s yaw=%s pitch=%s" % [
				str(iso.get_target()), str(iso.get_distance()),
				str(iso.get_yaw()), str(iso.get_pitch())])
	check("the iso pane's projection preset came back",
			_preset_of(_reopened_panel, "iso") == "Perspective",
			"preset=%s" % _preset_of(_reopened_panel, "iso"))
	check("each pane got its OWN preset back, not the iso pane's",
			_preset_of(_reopened_panel, "top") == SAVED_TOP_PRESET,
			"top preset=%s" % _preset_of(_reopened_panel, "top"))

	var records: Array = _reopened_panel.get_reference_status()
	var record: Dictionary = records[0] as Dictionary if records.size() == 1 else {}
	check("the reference is mounted in the reopened tab, loaded and named",
			str(record.get("name", "")) == "ref1"
			and str(record.get("status", "")) == ReferenceMeshes.STATUS_OK,
			"records=%d status=%s" % [records.size(), str(record.get("status", ""))])

	var bounds: AABB = _live_reference_bounds(_reopened_panel)
	check("its geometry is really in the scene, at the pose the note saved",
			bounds.position.distance_to(BLOCK_WORLD_MIN) < TOLERANCE_MM
			and (bounds.position + bounds.size).distance_to(BLOCK_WORLD_MAX) < TOLERANCE_MM,
			"bounds=%s" % str(bounds))


# ---------------------------------------------------------------------------
# Surviving the auto-frame
# ---------------------------------------------------------------------------

func _test_pending_camera() -> void:
	print("\nthe camera survives the evaluation that follows the restore:")
	if _reopened_panel == null:
		return
	check("the restore parked a camera for after the evaluation",
			_reopened_panel.has_meta(CadNote.PENDING_CAMERA_META))

	# What update_mesh's auto-frame does to every pane: retarget and re-range.
	var iso: Camera3D = _reopened_panel.get_view_camera("iso")
	iso.set_target(Vector3(999.0, 999.0, 999.0))
	iso.set_distance(1000.0)
	check("control: an auto-frame moves the camera off the saved view",
			iso.get_target().distance_to(SAVED_TARGET) > 1.0)

	CadNote.apply_pending_camera(_reopened_panel)
	check("the saved view is put back after the auto-frame",
			iso.get_target().distance_to(SAVED_TARGET) < TOLERANCE_MM
			and _near(iso.get_distance(), SAVED_DISTANCE),
			"target=%s distance=%s" % [str(iso.get_target()), str(iso.get_distance())])

	iso.set_target(Vector3(999.0, 999.0, 999.0))
	CadNote.apply_pending_camera(_reopened_panel)
	check("it is applied once and only once — a later evaluation frames freely",
			not _reopened_panel.has_meta(CadNote.PENDING_CAMERA_META)
			and iso.get_target().distance_to(SAVED_TARGET) > 1.0,
			"target=%s" % str(iso.get_target()))


# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------

func _test_refusals() -> void:
	print("\nrefusals:")
	if _reopened_panel == null:
		return
	var good: Dictionary = CadNote.build_payload(_reopened_panel)

	var future: Dictionary = good.duplicate(true)
	future["version"] = CadNote.VERSION + 1
	check("a note from a later build is refused, not half-restored",
			not CadNote.restore(future, _reopened_panel))

	var foreign: Dictionary = good.duplicate(true)
	foreign["schema"] = "pcb.board"
	check("another plugin's payload is refused",
			not CadNote.restore(foreign, _reopened_panel))

	var malformed: Dictionary = good.duplicate(true)
	malformed["source"] = 17
	check("a payload whose source is not text is refused",
			not CadNote.restore(malformed, _reopened_panel))

	check("a refused restore leaves the open document alone",
			str(_reopened_panel.get_document_state().get("source", "")) == DOCUMENT_SOURCE)

	var why: String = CadNote.validation_error(future)
	check("the refusal says which version it saw",
			why.contains(str(CadNote.VERSION + 1)) and why.contains("version"),
			"why=%s" % why)


# ---------------------------------------------------------------------------
# Rendering for a language model
# ---------------------------------------------------------------------------

func _test_render_for_llm() -> void:
	print("\nrender_for_llm:")
	if _reopened_panel == null:
		return
	_reopened_panel._last_mesh_data = {"vertices": SOLID_VERTICES, "faces": [[0, 1, 2]]}

	var parts: Variant = _reopened_panel._on_panel_render_for_llm({})
	check("the hook returns an Array synchronously — the host does not await it",
			parts is Array, "got %s" % type_string(typeof(parts)))
	if not (parts is Array):
		return

	var text_parts: Array = _parts_of_type(parts as Array, "text")
	check("exactly one text part is produced", text_parts.size() == 1,
			"%d text parts" % text_parts.size())
	var text: String = str((text_parts[0] as Dictionary).get("text", "")) \
		if text_parts.size() == 1 else ""
	check("the text names the document and every reference in it",
			text.contains(_document_path) and text.contains("ref1")
			and text.contains(_glb_path),
			"text=%s" % text.substr(0, 300))
	check("each reference carries its status and its bounds",
			text.contains(ReferenceMeshes.STATUS_OK)
			and text.contains("185.00") and text.contains("120.00"),
			"text=%s" % text.substr(0, 300))

	# A document with no references at all still has something to say.
	_reopened_panel._mount_references([])
	var bare: Array = _reopened_panel._on_panel_render_for_llm({}) as Array
	var bare_text: Array = _parts_of_type(bare, "text")
	check("a document with no references still renders, and says so",
			bare_text.size() == 1
			and str((bare_text[0] as Dictionary).get("text", "")).contains("no mesh()"),
			"parts=%d" % bare.size())

	# The image half, against a panel whose capture surface answers. The real
	# host answers null until a frame has been captured, which a headless run
	# cannot promise; the contract it implements — "an Image, or null" — is
	# what the stand-in supplies.
	var stub: Node = _panel_with_image()
	root.add_child(stub)
	var lit: Array = CadNote.render_parts(stub, {})
	var images: Array = _parts_of_type(lit, "image")
	check("an image part carries the pane the capture surface handed over",
			images.size() == 1
			and (images[0] as Dictionary).get("image", null) is Image
			and ((images[0] as Dictionary)["image"] as Image).get_width() == 64,
			"%d image parts" % images.size())
	check("the image part is described in words as well",
			images.size() == 1
			and not str((images[0] as Dictionary).get("alt", "")).is_empty())
	root.remove_child(stub)
	stub.free()


# ---------------------------------------------------------------------------
# Reading the solid
# ---------------------------------------------------------------------------

func _test_counting() -> void:
	print("\nreading the worker's mesh:")
	if _reopened_panel == null:
		return
	_reopened_panel._last_mesh_data = {"vertices": SOLID_VERTICES, "faces": [[0, 1, 2]]}
	check("vertices are counted as the triples the worker emits, not as floats",
			CadNote.vertex_count(_reopened_panel) == SOLID_VERTICES.size(),
			"counted %d of %d" % [
				CadNote.vertex_count(_reopened_panel), SOLID_VERTICES.size()])
	var bounds: AABB = CadNote.solid_bounds(_reopened_panel)
	check("the solid's bounds are the bounds of those triples",
			bounds.position.distance_to(SOLID_MIN) < TOLERANCE_MM
			and (bounds.position + bounds.size).distance_to(SOLID_MAX) < TOLERANCE_MM,
			"bounds=%s" % str(bounds))


# ---------------------------------------------------------------------------
# The panel's wiring
# ---------------------------------------------------------------------------

## The panel half is four hooks and three accessors. Read as source, because
## the module is where the behaviour is and the panel is where the connection
## is — a connection that is either written down or is not.
func _test_panel_wiring() -> void:
	print("\npanel wiring:")
	var source: String = FileAccess.get_file_as_string(CAD_PANEL_SOURCE_PATH)
	check("CADPanel exposes what a note needs to read and to adopt",
			source.contains("func get_document_state()")
			and source.contains("func get_view_camera(")
			and source.contains("func adopt_restored_document("),
			"CADPanel.gd is %d chars" % source.length())
	check("all three note hooks delegate to the note module",
			source.contains("func _on_panel_create_note_request")
			and source.contains("func _on_panel_restore_from_note")
			and source.contains("func _on_panel_render_for_llm")
			and source.count("_CadNoteScript.") >= 4)
	check("the evaluation path re-applies a restore's camera",
			source.contains("_CadNoteScript.apply_pending_camera(self)"))
	check("undo and redo are deliberately absent",
			not source.contains("func _on_panel_undo_request")
			and not source.contains("func _on_panel_redo_request"))


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

func _instantiate_panel(description: String) -> Node:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	var panel: Node = packed.instantiate() if packed != null else null
	check(description, panel != null, "could not instantiate %s" % PANEL_SCENE_PATH)
	if panel != null:
		root.add_child(panel)
	return panel


## Put the saved tab into the state the user left it in: a document with a
## path, one mounted reference, and four panes pointed somewhere specific.
func _prepare_saved_tab(panel: Node) -> void:
	panel._document_path = _document_path
	panel._pending_dsl_text = DOCUMENT_SOURCE
	panel._mount_references([{
		"name": "ref1",
		"path": _glb_path,
		"units": "mm",
		"up": "z",
		"matrix": POSE_TRANSLATE,
	}])
	for view in ["iso", "top", "front", "right"]:
		var camera: Camera3D = panel.get_view_camera(view)
		if camera == null:
			continue
		if view == "top":
			camera.set_view_preset(SAVED_TOP_PRESET)
		camera.set_target(SAVED_TARGET)
		camera.set_distance(SAVED_DISTANCE)
		camera.set_orbit(SAVED_YAW, SAVED_PITCH)


## A minimal panel whose only job is to answer the capture surface's contract
## ("an Image, or null"), so the image half of render_for_llm can be asserted
## without depending on a headless run having drawn a frame. It stands in for
## the panel shell only — every other part of render_parts runs for real.
class CapturingPanel extends Node:
	var image: Image = null

	func get_annotation_host() -> Object:
		return self

	func render_view_to_image(_view: String, _rect: Rect2) -> Image:
		return image

	func get_document_state() -> Dictionary:
		return {}

	func get_reference_status() -> Array:
		return []


func _panel_with_image() -> Node:
	var stub := CapturingPanel.new()
	stub.image = Image.create(64, 48, false, Image.FORMAT_RGBA8)
	return stub


func _preset_of(panel: Node, view: String) -> String:
	var camera: Camera3D = panel.get_view_camera(view)
	if camera == null or not camera.has_method("get_debug_state"):
		return ""
	return str(camera.get_debug_state().get("view_preset", ""))


func _write_fixture_glb(path: String) -> bool:
	var scene_root := Node3D.new()
	scene_root.name = "Scene"
	var block_mesh := BoxMesh.new()
	block_mesh.size = BLOCK_LOCAL_MAX - BLOCK_LOCAL_MIN
	var block := MeshInstance3D.new()
	block.name = "Block"
	block.mesh = block_mesh
	block.position = (BLOCK_LOCAL_MIN + BLOCK_LOCAL_MAX) * 0.5
	scene_root.add_child(block)

	root.add_child(scene_root)
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var appended := document.append_from_scene(scene_root, state)
	var written := ERR_BUG
	if appended == OK:
		written = document.write_to_filesystem(state, path)
	root.remove_child(scene_root)
	scene_root.free()
	return appended == OK and written == OK


## Bounds of the mounted reference geometry, read off the live scene graph
## rather than out of the mount report — an independent path to the same
## answer, which a restore that reports a reference it did not mount fails.
func _live_reference_bounds(panel: Node) -> AABB:
	var layer: Node = panel.get_node_or_null(
		"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/IsoView/SubViewport/MeshRoot/"
		+ ReferenceMeshes.LAYER_NODE_NAME)
	var bounds := AABB()
	var have := false
	if layer == null:
		return bounds
	for instance in _mesh_instances(layer):
		var mi: MeshInstance3D = instance
		if mi.mesh == null or mi.mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES:
			continue
		var box: AABB = ReferenceMeshes.transform_aabb(mi.global_transform, mi.mesh.get_aabb())
		bounds = box if not have else bounds.merge(box)
		have = true
	return bounds


func _mesh_instances(node: Node) -> Array:
	var found: Array = []
	for child in node.get_children():
		if child is MeshInstance3D:
			found.append(child)
		found.append_array(_mesh_instances(child))
	return found


func _parts_of_type(parts: Array, wanted: String) -> Array:
	var out: Array = []
	for part in parts:
		if part is Dictionary and str((part as Dictionary).get("type", "")) == wanted:
			out.append(part)
	return out


## The first value in `value` that JSON cannot carry, named by its path, or "".
## Godot's JSON.stringify does not refuse a Vector3 or a Transform3D — it
## writes them as strings — so a payload that leaked one would round-trip and
## restore into nonsense. This is what makes the leak loud.
func _first_non_json_value(value: Variant, path: String) -> String:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return ""
		TYPE_ARRAY:
			for i in range((value as Array).size()):
				var inner := _first_non_json_value((value as Array)[i], "%s[%d]" % [path, i])
				if not inner.is_empty():
					return inner
			return ""
		TYPE_DICTIONARY:
			for key in (value as Dictionary).keys():
				if not (key is String):
					return "%s has a non-String key %s" % [path, str(key)]
				var inner2 := _first_non_json_value(
					(value as Dictionary)[key], "%s.%s" % [path, str(key)])
				if not inner2.is_empty():
					return inner2
			return ""
	return "%s is a %s, which JSON cannot carry" % [path, type_string(typeof(value))]


func _to_vec(raw: Variant) -> Vector3:
	if not (raw is Array) or (raw as Array).size() < 3:
		return Vector3.INF
	var a: Array = raw as Array
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _near(a: float, b: float) -> bool:
	return absf(a - b) < TOLERANCE_MM


func _cleanup() -> void:
	for panel in [_saving_panel, _reopened_panel]:
		if panel != null and is_instance_valid(panel):
			root.remove_child(panel)
			panel.free()
	if not _glb_path.is_empty() and FileAccess.file_exists(_glb_path):
		DirAccess.remove_absolute(_glb_path)


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
