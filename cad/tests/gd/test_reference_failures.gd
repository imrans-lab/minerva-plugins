extends SceneTree
## What a reference does when the file is not there, is not what it claims to
## be, or is too big — the failure and size contract of
## ui/scripts/reference_meshes.gd and of the minerva_cad_references verb.
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## Every broken file is MADE here out of a good one: a valid GLB is written,
## then truncated to produce a file whose header survives and whose body does
## not, and a paragraph of text is written under a .glb name to produce a file
## whose extension lies. No binary is checked in, and the failures are the
## failures the importer actually produces rather than ones an assertion
## imagines.
##
## The size ceilings are exercised through the library's instance limits
## (outline_triangle_budget / max_triangles / max_file_bytes), which exist so
## that this logic can be tested against a fixture a test can build — the
## shipped constants would need a quarter-gigabyte file to reach. The arithmetic
## and the messages under test are the same either way; only the numbers move.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const ReferenceMeshes := preload("res://../../minerva-plugins/cad/ui/scripts/reference_meshes.gd")
const PanelTools := preload("res://../../minerva-plugins/cad/ui/panel_tools.gd")

const TOLERANCE_MM := 0.001

## The good fixture: two boxes under a 0.001 assembly scale, in metres/Y-up,
## exactly as a glTF exported from millimetre data arrives.
##   BoxA 2 x 4 x 6 at (10, 0, 0), BoxB 2 x 2 x 2 at (0, 20, 5)
## Converted to the CAD frame (millimetres, Y-up -> Z-up):
const EXPECTED_LOCAL_MIN := Vector3(-1.0, -6.0, -2.0)
const EXPECTED_LOCAL_MAX := Vector3(11.0, 3.0, 21.0)
## Two BoxMeshes, 12 triangles each. The number every size message is made of.
const EXPECTED_TRIANGLES := 24

## translate([100, 200, 300]), row-major, as the worker reports it.
const POSE_TRANSLATE := [
	[1.0, 0.0, 0.0, 100.0],
	[0.0, 1.0, 0.0, 200.0],
	[0.0, 0.0, 1.0, 300.0],
	[0.0, 0.0, 0.0, 1.0],
]
## A second, different pose, so a marker's position can be shown to come from
## the document rather than from the origin by accident.
const POSE_MARKER := [
	[1.0, 0.0, 0.0, -50.0],
	[0.0, 1.0, 0.0, 400.0],
	[0.0, 0.0, 1.0, 0.0],
	[0.0, 0.0, 0.0, 1.0],
]

var _pass: int = 0
var _fail: int = 0
var _scratch: String = ""
var _document_path: String = ""
var _good_glb: String = ""
var _truncated_glb: String = ""
var _text_glb: String = ""
var _text_obj: String = ""
var _sphere_glb: String = ""


func _init() -> void:
	print("=== CAD Reference Failure / Size Test ===\n")
	await process_frame
	await _run()
	_cleanup()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_scratch = OS.get_user_data_dir()
	_document_path = _scratch.path_join("failure_fixture.mcad")
	_good_glb = _scratch.path_join("cad_failure_good.glb")
	_truncated_glb = _scratch.path_join("cad_failure_truncated.glb")
	_text_glb = _scratch.path_join("cad_failure_notes.glb")
	_text_obj = _scratch.path_join("cad_failure_notes.obj")
	_sphere_glb = _scratch.path_join("cad_failure_sphere.glb")

	var built := _write_box_glb(_good_glb) and _write_sphere_glb(_sphere_glb)
	check("fixture: the good GLB and the dense GLB were written", built,
			"GLTFDocument could not write the fixtures")
	if not built:
		return
	_truncate(_good_glb, _truncated_glb, 200)
	_write_text(_text_glb, "This is a note, not a mesh. It is named .glb anyway.\n")
	_write_text(_text_obj, "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")

	_test_every_failure_reports_and_marks_itself()
	_test_a_later_good_evaluation_clears_the_marker()
	_test_the_size_ceilings()
	await _test_the_verb_carries_the_status()
	_test_an_unresolvable_path_is_a_status_like_any_other()


# ---------------------------------------------------------------------------
# The taxonomy, the markers, and the reference that still works
# ---------------------------------------------------------------------------

## One mount carrying every failure shape at once, plus a good reference, so
## the claim under test is not "a bad file reports" but "a bad file reports and
## the rest of the document is unaffected".
func _test_every_failure_reports_and_marks_itself() -> void:
	var library = ReferenceMeshes.new()
	var parent := Node3D.new()
	root.add_child(parent)

	var report: Dictionary = library.mount([
		_reference("board", _good_glb.get_file(), POSE_TRANSLATE),
		_reference("cut_off", _truncated_glb.get_file(), POSE_MARKER),
		_reference("prose", _text_glb.get_file(), POSE_MARKER),
		_reference("gone", "cad_failure_absent.glb", POSE_MARKER),
		_reference("wavefront", _text_obj.get_file(), POSE_MARKER),
	], _document_path, parent)

	check("one reference loaded and four failed",
			int(report.get("mounted", 0)) == 1 and int(report.get("marked", 0)) == 4,
			"mounted=%s marked=%s" % [str(report.get("mounted", 0)), str(report.get("marked", 0))])

	var statuses: Array = report.get("statuses", [])
	check("every reference the document named is reported, in that order",
			statuses.size() == 5 and _names(statuses) == [
				"board", "cut_off", "prose", "gone", "wavefront",
			],
			"got %s" % str(_names(statuses)))

	check("a truncated GLB is unreadable and the reason names the file",
			_status_is(statuses, "cut_off", "unreadable", _truncated_glb.get_file()),
			"got %s" % str(_record(statuses, "cut_off")))

	check("a text file wearing a .glb extension is unreadable, not empty geometry",
			_status_is(statuses, "prose", "unreadable", _text_glb.get_file()),
			"got %s — GLTFDocument reports this as an error code or as a null "
				% str(_record(statuses, "prose"))
				+ "scene depending on how far it parses; both must report")

	check("a file that is not there is 'missing' and the reason names it",
			_status_is(statuses, "gone", "missing", "cad_failure_absent.glb"),
			"got %s" % str(_record(statuses, "gone")))

	check("a format this loader does not read is 'unsupported' and says so",
			_status_is(statuses, "wavefront", "unsupported", ".obj"),
			"got %s" % str(_record(statuses, "wavefront")))

	var layer := parent.get_node_or_null(ReferenceMeshes.LAYER_NODE_NAME)
	check("the world holds a node for all five references, not just the one that worked",
			layer != null and layer.get_child_count() == 5,
			"children=%d" % (layer.get_child_count() if layer != null else -1))

	var shaded := _instances_under(parent, ReferenceMeshes.SHADED_NODE_NAME)
	check("the reference that loaded is unaffected by the four that did not",
			shaded.size() == 2 and _aabb_matches(
				_world_bounds(shaded),
				EXPECTED_LOCAL_MIN + Vector3(100.0, 200.0, 300.0),
				EXPECTED_LOCAL_MAX + Vector3(100.0, 200.0, 300.0)),
			"shaded instances=%d bounds=%s" % [shaded.size(), str(_world_bounds(shaded))])

	var markers := _instances_under(parent, ReferenceMeshes.MARKER_NODE_NAME)
	check("each failed reference is drawn as a wireframe marker",
			markers.size() == 4 and _all_line_meshes(markers),
			"markers=%d line-meshes=%s" % [markers.size(), str(_all_line_meshes(markers))])

	var half := ReferenceMeshes.MARKER_SIZE_MM * 0.5
	var one_marker: Array = [markers[0]] if not markers.is_empty() else []
	check("a marker stands at the pose the document asked for, not at the origin",
			_aabb_matches(
				_world_bounds(one_marker),
				Vector3(-50.0, 400.0, 0.0) - Vector3.ONE * half,
				Vector3(-50.0, 400.0, 0.0) + Vector3.ONE * half),
			"marker bounds %s" % str(_world_bounds(one_marker)))

	var world: AABB = report.get("world_aabb", AABB())
	check("the framing bounds cover the markers as well as the geometry",
			world.has_point(Vector3(-50.0, 400.0, 0.0))
				and world.has_point(Vector3(100.0, 200.0, 300.0)),
			"world_aabb=%s" % str(world))

	check("the geometry surface holds only what loaded; the status surface holds everything",
			library.mounted_references().size() == 1
				and library.reference_records().size() == 5,
			"mounted=%d records=%d" % [
				library.mounted_references().size(), library.reference_records().size(),
			])

	var lines: PackedStringArray = report.get("status_lines", PackedStringArray())
	check("there is one status line per failure and each names its reference and its file",
			lines.size() == 4
				and _line_for(lines, "cut_off").contains(_truncated_glb.get_file())
				and _line_for(lines, "prose").contains(_text_glb.get_file())
				and _line_for(lines, "gone").contains("cad_failure_absent.glb")
				and _line_for(lines, "wavefront").contains(".obj"),
			"lines=%s" % str(lines))

	var errors: PackedStringArray = report.get("errors", PackedStringArray())
	check("the four failures are also on the error list the panel already reads",
			errors.size() == 4,
			"errors=%s" % str(errors))

	parent.free()


# ---------------------------------------------------------------------------
# The marker is not sticky
# ---------------------------------------------------------------------------

## The acceptance's last clause: fix the path, evaluate again, and the marker
## goes. Mounting the same parent twice is exactly what a re-evaluation does.
func _test_a_later_good_evaluation_clears_the_marker() -> void:
	var library = ReferenceMeshes.new()
	var parent := Node3D.new()
	root.add_child(parent)

	library.mount(
		[_reference("board", "cad_failure_absent.glb", POSE_TRANSLATE)],
		_document_path, parent)
	var before := _instances_under(parent, ReferenceMeshes.MARKER_NODE_NAME).size()

	library.mount(
		[_reference("board", _good_glb.get_file(), POSE_TRANSLATE)],
		_document_path, parent)

	check("a marker appears while the path is wrong and is gone once it is right",
			before == 1
				and _instances_under(parent, ReferenceMeshes.MARKER_NODE_NAME).is_empty(),
			"before=%d after=%d" % [
				before, _instances_under(parent, ReferenceMeshes.MARKER_NODE_NAME).size(),
			])

	check("the corrected reference brings its geometry with it",
			_instances_under(parent, ReferenceMeshes.SHADED_NODE_NAME).size() == 2
				and library.mounted_references().size() == 1,
			"shaded=%d mounted=%d" % [
				_instances_under(parent, ReferenceMeshes.SHADED_NODE_NAME).size(),
				library.mounted_references().size(),
			])

	parent.free()


# ---------------------------------------------------------------------------
# Size: the measured numbers, the warning, the refusal
# ---------------------------------------------------------------------------

func _test_the_size_ceilings() -> void:
	var library = ReferenceMeshes.new()
	var loaded = library.load_file(_good_glb, "m", "y")
	check("the loader counts the triangles it actually read",
			loaded.triangle_count == EXPECTED_TRIANGLES,
			"got %d, expected %d (two BoxMeshes, 12 triangles each)" % [
				loaded.triangle_count, EXPECTED_TRIANGLES,
			])
	check("a mesh inside every ceiling keeps its outline and says nothing",
			loaded.is_ok() and not loaded.outlines_skipped
				and not loaded.outlines.is_empty() and loaded.warning.is_empty(),
			"skipped=%s outlines=%d warning='%s'" % [
				str(loaded.outlines_skipped), loaded.outlines.size(), loaded.warning,
			])

	# The byte ceiling: refused without the importer ever seeing the path.
	var byte_capped = ReferenceMeshes.new()
	byte_capped.max_file_bytes = 64
	var refused_bytes = byte_capped.load_file(_good_glb, "m", "y")
	check("a file over the byte ceiling is refused, stating both numbers",
			refused_bytes.status == ReferenceMeshes.STATUS_OVERSIZE
				and refused_bytes.error.contains(str(refused_bytes.byte_size))
				and refused_bytes.error.contains("64")
				and refused_bytes.parts.is_empty(),
			"status=%s error='%s'" % [refused_bytes.status, refused_bytes.error])

	# The triangle ceiling: refused after the native parse, stating the count.
	var triangle_capped = ReferenceMeshes.new()
	triangle_capped.max_triangles = 10
	var refused_triangles = triangle_capped.load_file(_good_glb, "m", "y")
	check("a mesh over the triangle ceiling is refused, stating the measured count",
			refused_triangles.status == ReferenceMeshes.STATUS_OVERSIZE
				and refused_triangles.error.contains(str(EXPECTED_TRIANGLES))
				and refused_triangles.error.contains("10")
				and refused_triangles.parts.is_empty(),
			"status=%s error='%s'" % [refused_triangles.status, refused_triangles.error])

	# A refusal is cached, but not across a change of the limit that caused it.
	triangle_capped.max_triangles = ReferenceMeshes.MAX_TRIANGLES
	var allowed_now = triangle_capped.load_file(_good_glb, "m", "y")
	check("raising the ceiling loads the file the old ceiling refused",
			allowed_now.is_ok() and allowed_now.parts.size() == 2,
			"status=%s error='%s' parts=%d" % [
				allowed_now.status, allowed_now.error, allowed_now.parts.size(),
			])

	# The outline budget: loads, renders, warns, keeps no outline.
	var budgeted = ReferenceMeshes.new()
	budgeted.outline_triangle_budget = 10
	var over_budget = budgeted.load_file(_good_glb, "m", "y")
	check("a mesh over the outline budget still loads, and the warning states both numbers",
			over_budget.is_ok() and over_budget.outlines_skipped
				and over_budget.outlines.is_empty()
				and over_budget.warning.contains(str(EXPECTED_TRIANGLES))
				and over_budget.warning.contains("10"),
			"ok=%s skipped=%s outlines=%d warning='%s'" % [
				str(over_budget.is_ok()), str(over_budget.outlines_skipped),
				over_budget.outlines.size(), over_budget.warning,
			])

	var parent := Node3D.new()
	root.add_child(parent)
	var report: Dictionary = budgeted.mount(
		[_reference("dense", _good_glb.get_file(), POSE_TRANSLATE)], _document_path, parent)
	check("the budgeted body is on screen shaded, with no ortho outline and no marker",
			_instances_under(parent, ReferenceMeshes.SHADED_NODE_NAME).size() == 2
				and _instances_under(parent, ReferenceMeshes.OUTLINE_NODE_NAME).is_empty()
				and _instances_under(parent, ReferenceMeshes.MARKER_NODE_NAME).is_empty(),
			"shaded=%d outline=%d markers=%d" % [
				_instances_under(parent, ReferenceMeshes.SHADED_NODE_NAME).size(),
				_instances_under(parent, ReferenceMeshes.OUTLINE_NODE_NAME).size(),
				_instances_under(parent, ReferenceMeshes.MARKER_NODE_NAME).size(),
			])

	var statuses: Array = report.get("statuses", [])
	var lines: PackedStringArray = report.get("status_lines", PackedStringArray())
	check("a budgeted reference stays 'ok' but still gets a status line of its own",
			int(report.get("mounted", 0)) == 1
				and str(_record(statuses, "dense").get("status", "")) == "ok"
				and bool(_record(statuses, "dense").get("outlines_skipped", false))
				and lines.size() == 1 and lines[0].contains("dense"),
			"statuses=%s lines=%s" % [str(statuses), str(lines)])
	parent.free()

	# Over the outline budget the mesh still loads and renders, only the
	# ortho x-ray is skipped, and the warning carries the measured count. A
	# timing comparison would be noise at millisecond resolution on this
	# fixture; the observable is the skipped outline and the number.
	var full = ReferenceMeshes.new()
	var full_loaded = full.load_file(_sphere_glb, "m", "y")
	var skipped = ReferenceMeshes.new()
	skipped.outline_triangle_budget = 10
	var skipped_loaded = skipped.load_file(_sphere_glb, "m", "y")
	check("over the outline budget the mesh loads, the outline is skipped, and the warning states the count",
			full_loaded.is_ok() and skipped_loaded.is_ok()
				and not full_loaded.outlines_skipped and skipped_loaded.outlines_skipped
				and skipped_loaded.warning.contains(str(skipped_loaded.triangle_count))
				and full_loaded.triangle_count > 1000,
			"full skipped=%s skipped skipped=%s warning='%s' over %d triangles" % [
				str(full_loaded.outlines_skipped), str(skipped_loaded.outlines_skipped),
				skipped_loaded.warning, full_loaded.triangle_count,
			])


# ---------------------------------------------------------------------------
# The MCP surface
# ---------------------------------------------------------------------------

## The verb is what an LLM sees, so the status has to reach it. The panel is
## the one thing this suite cannot build — CADPanel needs the plugin host and
## its autoloads — so a two-method stand-in supplies the panel's side of the
## contract while the records themselves come from a real library that really
## read the real fixtures.
class PanelStandIn extends Node:
	var library: RefCounted = null

	func get_reference_state() -> Array:
		return library.mounted_references()

	func get_reference_status() -> Array:
		return library.reference_records()


func _test_the_verb_carries_the_status() -> void:
	var library = ReferenceMeshes.new()
	var parent := Node3D.new()
	root.add_child(parent)
	library.mount([
		_reference("board", _good_glb.get_file(), POSE_TRANSLATE),
		_reference("gone", "cad_failure_absent.glb", POSE_MARKER),
	], _document_path, parent)

	var panel := PanelStandIn.new()
	panel.library = library
	root.add_child(panel)
	# handle() is a coroutine because the measurement verbs await a physics
	# step; _references does not, so this await resolves without suspending.
	var payload: Dictionary = await PanelTools.handle(panel, "minerva_cad_references", {})
	var references: Array = payload.get("references", [])

	check("minerva_cad_references lists the failed reference alongside the good one",
			references.size() == 2 and int(payload.get("failed", -1)) == 1
				and _names(references) == ["board", "gone"],
			"payload=%s" % str(payload))

	check("the verb carries references[i].status and a reason that names the file",
			str(_record(references, "board").get("status", "")) == "ok"
				and str(_record(references, "gone").get("status", "")) == "missing"
				and str(_record(references, "gone").get("reason", "")).contains(
					"cad_failure_absent.glb")
				and int(_record(references, "board").get("triangle_count", 0))
					== EXPECTED_TRIANGLES,
			"board=%s gone=%s" % [
				str(_record(references, "board")), str(_record(references, "gone")),
			])

	panel.free()
	parent.free()


# ---------------------------------------------------------------------------
# A path that never became a file
# ---------------------------------------------------------------------------

## A relative mesh() in a document that has never been saved has nothing to be
## relative to. That is a failure of the source, not of the file, and it gets
## the same treatment: a status, a reason, and a marker where the body would be.
func _test_an_unresolvable_path_is_a_status_like_any_other() -> void:
	var library = ReferenceMeshes.new()
	var parent := Node3D.new()
	root.add_child(parent)
	var report: Dictionary = library.mount(
		[_reference("board", "boards/panel.glb", POSE_MARKER)], "", parent)
	var statuses: Array = report.get("statuses", [])

	check("a relative path in an unsaved document is 'unresolved', not 'missing'",
			int(report.get("mounted", 0)) == 0 and int(report.get("marked", 0)) == 1
				and _status_is(statuses, "board", "unresolved", "boards/panel.glb"),
			"report=%s" % str(statuses))

	check("it is marked in the world like any other failure",
			_instances_under(parent, ReferenceMeshes.MARKER_NODE_NAME).size() == 1,
			"markers=%d" % _instances_under(parent, ReferenceMeshes.MARKER_NODE_NAME).size())

	parent.free()


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

## Two boxes under a 0.001 assembly scale — a glTF exported from millimetre
## data, which is the shape the panel actually meets.
func _write_box_glb(path: String) -> bool:
	var scene_root := Node3D.new()
	scene_root.name = "Scene"

	var assembly := Node3D.new()
	assembly.name = "Assembly"
	assembly.transform = Transform3D(Basis().scaled(Vector3(0.001, 0.001, 0.001)), Vector3.ZERO)
	scene_root.add_child(assembly)

	var box_a := BoxMesh.new()
	box_a.size = Vector3(2.0, 4.0, 6.0)
	var node_a := MeshInstance3D.new()
	node_a.name = "BoxA"
	node_a.mesh = box_a
	node_a.position = Vector3(10.0, 0.0, 0.0)
	assembly.add_child(node_a)

	var box_b := BoxMesh.new()
	box_b.size = Vector3(2.0, 2.0, 2.0)
	var node_b := MeshInstance3D.new()
	node_b.name = "BoxB"
	node_b.mesh = box_b
	node_b.position = Vector3(0.0, 20.0, 5.0)
	assembly.add_child(node_b)

	return _write_scene(scene_root, path)


## A denser body, so the cost of the feature-edge pass is measurable against
## the cost of skipping it.
func _write_sphere_glb(path: String) -> bool:
	var scene_root := Node3D.new()
	scene_root.name = "Scene"
	var sphere := SphereMesh.new()
	sphere.radial_segments = 64
	sphere.rings = 48
	sphere.radius = 0.02
	sphere.height = 0.04
	var node := MeshInstance3D.new()
	node.name = "Ball"
	node.mesh = sphere
	scene_root.add_child(node)
	return _write_scene(scene_root, path)


func _write_scene(scene_root: Node3D, path: String) -> bool:
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


## A GLB whose header is intact and whose body is not — the file a copy
## interrupted halfway leaves behind.
func _truncate(source: String, destination: String, keep_bytes: int) -> void:
	var input := FileAccess.open(source, FileAccess.READ)
	if input == null:
		return
	var head := input.get_buffer(keep_bytes)
	input.close()
	var output := FileAccess.open(destination, FileAccess.WRITE)
	if output == null:
		return
	output.store_buffer(head)
	output.close()


func _write_text(path: String, text: String) -> void:
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle == null:
		return
	handle.store_string(text)
	handle.close()


func _reference(reference_name: String, path: String, matrix: Array) -> Dictionary:
	return {
		"name": reference_name,
		"path": path,
		"units": "m",
		"up": "y",
		"matrix": matrix,
	}


func _cleanup() -> void:
	for path in [_good_glb, _truncated_glb, _text_glb, _text_obj, _sphere_glb]:
		if path != "" and FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

func _names(records: Array) -> Array:
	var out: Array = []
	for entry in records:
		out.append(str((entry as Dictionary).get("name", "")))
	return out


func _record(records: Array, wanted: String) -> Dictionary:
	for entry in records:
		var record: Dictionary = entry
		if str(record.get("name", "")) == wanted:
			return record
	return {}


func _status_is(records: Array, wanted: String, status: String, mentions: String) -> bool:
	var record := _record(records, wanted)
	return str(record.get("status", "")) == status \
		and str(record.get("reason", "")).contains(mentions)


func _line_for(lines: PackedStringArray, reference_name: String) -> String:
	for line in lines:
		if line.begins_with(reference_name):
			return line
	return ""


func _aabb_matches(box: AABB, expected_min: Vector3, expected_max: Vector3) -> bool:
	return box.position.distance_to(expected_min) < TOLERANCE_MM \
		and (box.position + box.size).distance_to(expected_max) < TOLERANCE_MM


## Every MeshInstance3D beneath a named container of every mounted reference.
func _instances_under(parent: Node3D, container_name: String) -> Array:
	var found: Array = []
	var layer := parent.get_node_or_null(ReferenceMeshes.LAYER_NODE_NAME)
	if layer == null:
		return found
	for reference_node in layer.get_children():
		var container := reference_node.get_node_or_null(container_name)
		if container == null:
			continue
		for child in container.get_children():
			if child is MeshInstance3D:
				found.append(child)
	return found


## Bounds read back off the live scene graph — an independent path to the same
## answer as the mount report.
func _world_bounds(instances: Array) -> AABB:
	var bounds := AABB()
	var have := false
	for instance in instances:
		var mi: MeshInstance3D = instance
		if mi.mesh == null:
			continue
		var box: AABB = ReferenceMeshes.transform_aabb(mi.global_transform, mi.mesh.get_aabb())
		bounds = box if not have else bounds.merge(box)
		have = true
	return bounds


func _all_line_meshes(instances: Array) -> bool:
	for instance in instances:
		var mi: MeshInstance3D = instance
		if mi.mesh == null or mi.mesh.get_surface_count() == 0:
			return false
		if mi.mesh.surface_get_primitive_type(0) != Mesh.PRIMITIVE_LINES:
			return false
	return true


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
