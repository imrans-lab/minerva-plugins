extends SceneTree
## Reference meshes in the CAD world — the load / convert / pose / display
## contract of ui/scripts/reference_meshes.gd.
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## The fixture is BUILT here and written to a temporary GLB with GLTFDocument.
## No mesh binary is checked in, and — more usefully — every number the test
## asserts is a number the test wrote, so the expected bounds below are
## literals rather than something recomputed with the loader's own arithmetic.
##
## The fixture is deliberately shaped like the file the panel will actually
## meet: a glTF exported from millimetre data, i.e. an inner node carrying a
## 0.001 scale with the real geometry beneath it. Three separate mistakes each
## fail loudly against it:
##   * a walk that reads a node's own transform without composing its parents
##     misses the 0.001 and reports the part 1000x too large;
##   * a loader that skips the Y-up -> Z-up conversion puts the part on the
##     wrong axes;
##   * a loader that mounts the file without the evaluation's pose leaves it
##     at the origin.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const ReferenceMeshes := preload("res://../../minerva-plugins/cad/ui/scripts/reference_meshes.gd")
const MeshDisplayScript := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_display.gd")
const OrbitCameraScript := preload("res://../../minerva-plugins/cad/ui/scripts/orbit_camera.gd")

const TOLERANCE_MM := 0.001

## The fixture, in the glTF file's own frame once the 0.001 root scale is
## undone — i.e. the millimetres the author was thinking in:
##   BoxA  2 x 4 x 6 centred at (10, 0, 0)      -> x[9, 11]  y[-2, 2]  z[-3, 3]
##   BoxB  2 x 2 x 2 centred at (0, 20, 5)      -> x[-1, 1]  y[19, 21] z[4, 6]
## Union: x[-1, 11]  y[-2, 21]  z[-3, 6]   (Y is up, because glTF)
##
## Converted to the CAD frame — millimetres already, Y-up -> Z-up sends
## (x, y, z) to (x, -z, y):
const EXPECTED_LOCAL_MIN := Vector3(-1.0, -6.0, -2.0)
const EXPECTED_LOCAL_MAX := Vector3(11.0, 3.0, 21.0)

## Posed by rotate 90 about Z then translate (100, 200, 300): the CAD-frame
## point (x, y, z) lands at (-y + 100, x + 200, z + 300).
const EXPECTED_WORLD_MIN := Vector3(97.0, 199.0, 298.0)
const EXPECTED_WORLD_MAX := Vector3(106.0, 211.0, 321.0)

## rotate([0, 0, 90]) then translate([100, 200, 300]), row-major, exactly as
## the worker reports it in `references[].matrix`.
const POSE_ROTATE_TRANSLATE := [
	[0.0, -1.0, 0.0, 100.0],
	[1.0, 0.0, 0.0, 200.0],
	[0.0, 0.0, 1.0, 300.0],
	[0.0, 0.0, 0.0, 1.0],
]

## A second pose, used to prove that re-posing does not re-read the file.
const POSE_TRANSLATE_ONLY := [
	[1.0, 0.0, 0.0, 5.0],
	[0.0, 1.0, 0.0, 0.0],
	[0.0, 0.0, 1.0, 0.0],
	[0.0, 0.0, 0.0, 1.0],
]

var _pass: int = 0
var _fail: int = 0
var _glb_path: String = ""
var _document_path: String = ""


func _init() -> void:
	print("=== CAD Reference Mesh Load/Convert/Pose Test ===\n")
	await process_frame
	_run()
	_cleanup()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	var scratch := OS.get_user_data_dir()
	_glb_path = scratch.path_join("cad_reference_fixture.glb")
	_document_path = scratch.path_join("cad_reference_fixture.mcad")

	var written := _write_fixture_glb(_glb_path, Vector3(2.0, 4.0, 6.0))
	check("fixture: the built scene wrote a GLB", written,
			"GLTFDocument could not write %s" % _glb_path)
	if not written:
		return

	_test_the_host_string_is_useless_for_a_glb()
	_test_geometry_lands_where_the_pose_says()
	_test_the_file_is_read_once_and_only_re_read_when_it_changes()
	_test_path_resolution()
	_test_a_missing_reference_is_reported_not_crashed()
	_test_feature_edges()
	_test_frame_conversion_arithmetic()
	_test_a_units_change_is_a_different_geometry_and_says_so()
	_test_a_gltf_is_stamped_with_the_files_it_names()
	_test_auto_framing_covers_the_reference()


# ---------------------------------------------------------------------------
# A .gltf is a manifest plus the files it names
# ---------------------------------------------------------------------------

## Unlike a GLB, a .gltf keeps its geometry in a separate .bin. Rewriting that
## .bin changes the mesh and leaves the JSON byte-for-byte identical, so a
## stamp taken over the .gltf alone serves the old geometry forever.
func _test_a_gltf_is_stamped_with_the_files_it_names() -> void:
	var scratch := OS.get_user_data_dir()
	var gltf_path := scratch.path_join("cad_reference_fixture.gltf")
	var written := _write_fixture_gltf(gltf_path, Vector3(2.0, 4.0, 6.0))
	check("gltf: the fixture wrote a .gltf with an external buffer", written,
			"GLTFDocument could not write %s" % gltf_path)
	if not written:
		return

	var buffers := _external_files_of(gltf_path)
	check("gltf: the manifest names at least one file beside itself",
			buffers.size() >= 1, "buffers: %s" % str(buffers))
	if buffers.is_empty():
		_remove_all([gltf_path])
		return

	var library = ReferenceMeshes.new()
	var parent := Node3D.new()
	root.add_child(parent)
	library.mount([_reference("board", gltf_path, POSE_TRANSLATE_ONLY)], _document_path, parent)
	var before: String = library.file_stamp(gltf_path)
	var json_before := FileAccess.get_sha256(gltf_path)

	# Rewrite ONLY the .bin, keeping its length so even the cheap identity is
	# unchanged apart from the content.
	var bin_path: String = str(buffers[0])
	var bytes := FileAccess.get_file_as_bytes(bin_path)
	for i in range(bytes.size()):
		bytes[i] = (int(bytes[i]) + 1) & 0xFF
	var handle := FileAccess.open(bin_path, FileAccess.WRITE)
	if handle != null:
		handle.store_buffer(bytes)
		handle.close()

	# Deliberately NOT clear_cache(): the point is that the SAME library, with
	# its stamp cache warm and the .gltf's own mtime and length untouched,
	# notices the side file.
	var after: String = library.file_stamp(gltf_path)
	check("gltf: the manifest itself did not change",
			FileAccess.get_sha256(gltf_path) == json_before,
			"the .gltf was rewritten too, so this proves nothing")
	check("gltf: rewriting the external buffer changes the stamp",
			after != before and not after.is_empty(),
			"stamp stayed '%s'" % before)

	var reads_before: int = library.get_load_count()
	library.mount([_reference("board", gltf_path, POSE_TRANSLATE_ONLY)], _document_path, parent)
	check("gltf: and the file is read again, so the panel does not serve stale geometry",
			library.get_load_count() > reads_before,
			"load count stayed at %d" % library.get_load_count())

	parent.free()
	_remove_all([gltf_path] + buffers)


# ---------------------------------------------------------------------------
# The host's raw_text is not a way to read a GLB
# ---------------------------------------------------------------------------

## Editor._load_plugin_scene_file hands a panel {file_path, raw_text} for every
## document, and FileAccess.get_file_as_string stops at the first NUL byte — a
## GLB yields five characters. This asserts the trap is real AND that the
## loader is unaffected, because it never takes text.
func _test_the_host_string_is_useless_for_a_glb() -> void:
	var host_text := FileAccess.get_file_as_string(_glb_path)
	var on_disk := FileAccess.open(_glb_path, FileAccess.READ)
	var byte_length := on_disk.get_length() if on_disk != null else 0
	if on_disk != null:
		on_disk.close()

	check("the host's raw_text for a GLB is a truncated stub, not the file",
			host_text.length() < 64 and byte_length > 1024,
			"raw_text was %d chars of a %d byte file" % [host_text.length(), byte_length])

	var library = ReferenceMeshes.new()
	var loaded = library.load_file(_glb_path)
	check("the loader reads the file itself and gets real geometry",
			loaded.is_ok() and loaded.parts.size() == 2,
			"error='%s' parts=%d" % [loaded.error, loaded.parts.size()])


# ---------------------------------------------------------------------------
# THE ACCEPTANCE TEST: units, up-axis, composed node transforms, pose
# ---------------------------------------------------------------------------

func _test_geometry_lands_where_the_pose_says() -> void:
	var library = ReferenceMeshes.new()
	var loaded = library.load_file(_glb_path)

	check("conversion: the reference's own bounds are CAD millimetres, Z-up",
			_aabb_matches(loaded.local_aabb, EXPECTED_LOCAL_MIN, EXPECTED_LOCAL_MAX),
			"got %s (a loader that drops the 0.001 root scale is 1000x out; "
				% str(loaded.local_aabb)
				+ "one that skips Y-up -> Z-up has the axes swapped)")

	var parent := Node3D.new()
	root.add_child(parent)
	var report: Dictionary = library.mount(
		[_reference("board", "cad_reference_fixture.glb", POSE_ROTATE_TRANSLATE)],
		_document_path,
		parent
	)

	var mount_errors: PackedStringArray = report.get("errors", PackedStringArray())
	check("mount: the reference is in the world",
			int(report.get("mounted", 0)) == 1 and mount_errors.is_empty(),
			"mounted=%s errors=%s" % [str(report.get("mounted", 0)), str(mount_errors)])

	var world: AABB = report.get("world_aabb", AABB())
	check("pose: the world bounds are the built bounds converted, rotated and translated",
			_aabb_matches(world, EXPECTED_WORLD_MIN, EXPECTED_WORLD_MAX),
			"got %s, expected min %s max %s" % [
				str(world), str(EXPECTED_WORLD_MIN), str(EXPECTED_WORLD_MAX),
			])

	# The mounted nodes must agree with the reported bounds — a report computed
	# from the cache while the scene shows something else would be worse than a
	# wrong number.
	var layer := parent.get_node_or_null(ReferenceMeshes.LAYER_NODE_NAME)
	check("mount: the layer holds one reference node",
			layer != null and layer.get_child_count() == 1,
			"layer=%s children=%d" % [str(layer), layer.get_child_count() if layer != null else -1])

	var shaded_instances := _mesh_instances(parent, ReferenceMeshes.SHADED_NODE_NAME)
	check("display: both mesh nodes of the multi-node file are instanced",
			shaded_instances.size() == 2,
			"found %d shaded MeshInstance3D" % shaded_instances.size())

	check("display: the scene-graph bounds match the reported bounds",
			_aabb_matches(_world_bounds(shaded_instances), EXPECTED_WORLD_MIN, EXPECTED_WORLD_MAX),
			"scene bounds %s" % str(_world_bounds(shaded_instances)))

	check("display: the file's own materials and textures come with it",
			_has_textured_surface(shaded_instances),
			"no surface material with an albedo_texture survived the round trip")

	var outline_instances := _mesh_instances(parent, ReferenceMeshes.OUTLINE_NODE_NAME)
	check("ortho: the reference carries a cached line outline",
			outline_instances.size() >= 1 and _is_line_mesh(outline_instances[0].mesh),
			"outline instances=%d" % outline_instances.size())

	check("the file's own lights are not brought into the CAD world",
			_find_light(parent) == null,
			"a Light3D from the glTF was instanced: %s" % str(_find_light(parent)))

	# Ortho panes are outline x-rays: the shaded bodies go, the outline stays.
	library.set_shaded_visible(parent, false)
	var reference_node: Node = layer.get_child(0) if layer != null and layer.get_child_count() > 0 else null
	var shaded_root: Node = null
	var outline_root: Node = null
	if reference_node != null:
		shaded_root = reference_node.get_node_or_null(ReferenceMeshes.SHADED_NODE_NAME)
		outline_root = reference_node.get_node_or_null(ReferenceMeshes.OUTLINE_NODE_NAME)
	check("ortho: hiding the shaded bodies leaves the outline visible",
			shaded_root != null and not shaded_root.visible
				and outline_root != null and outline_root.visible,
			"shaded.visible=%s outline.visible=%s" % [
				str(shaded_root.visible) if shaded_root != null else "<missing>",
				str(outline_root.visible) if outline_root != null else "<missing>",
			])

	parent.free()


# ---------------------------------------------------------------------------
# Load once; re-read only when the bytes change
# ---------------------------------------------------------------------------

func _test_the_file_is_read_once_and_only_re_read_when_it_changes() -> void:
	var library = ReferenceMeshes.new()
	var parent := Node3D.new()
	root.add_child(parent)

	var first: Dictionary = library.mount(
		[_reference("board", "cad_reference_fixture.glb", POSE_ROTATE_TRANSLATE)], _document_path, parent)
	check("cache: the first evaluation reads the file",
			library.get_load_count() == 1,
			"load count %d" % library.get_load_count())

	var second: Dictionary = library.mount(
		[_reference("board", "cad_reference_fixture.glb", POSE_TRANSLATE_ONLY)], _document_path, parent)
	check("cache: a new pose does NOT re-read the file",
			library.get_load_count() == 1,
			"load count rose to %d on a pose change" % library.get_load_count())

	check("cache: the new pose still moved the geometry",
			not _aabb_matches(
				second.get("world_aabb", AABB()),
				EXPECTED_WORLD_MIN,
				EXPECTED_WORLD_MAX),
			"re-posing left the bounds at %s — the pose is being cached with the file"
				% str(second.get("world_aabb", AABB())))
	check("cache: the second pose is the translation the DSL asked for",
			_aabb_matches(
				second.get("world_aabb", AABB()),
				EXPECTED_LOCAL_MIN + Vector3(5.0, 0.0, 0.0),
				EXPECTED_LOCAL_MAX + Vector3(5.0, 0.0, 0.0)),
			"got %s from the first report %s" % [
				str(second.get("world_aabb", AABB())), str(first.get("world_aabb", AABB())),
			])

	# The stamp that decides staleness must follow the file's CONTENT: the
	# rewrite below keeps the byte length and lands within the same second, so
	# a stamp built from mtime and size would serve the old board.
	var stamp: String = library.file_stamp(_glb_path)
	check("cache: the staleness stamp is the file's content digest",
			stamp == FileAccess.get_sha256(_glb_path),
			"stamp was '%s'" % stamp)

	# Rewrite the fixture with different geometry — the stamp changes and the
	# file must be read again.
	var rewritten := _write_fixture_glb(_glb_path, Vector3(20.0, 40.0, 60.0))
	check("fixture: the GLB was rewritten with different geometry", rewritten,
			"could not rewrite %s" % _glb_path)
	library.mount([_reference("board", "cad_reference_fixture.glb", POSE_TRANSLATE_ONLY)], _document_path, parent)
	check("cache: a changed file IS re-read",
			library.get_load_count() == 2,
			"load count %d — the panel would keep showing the old board"
				% library.get_load_count())

	library.mount([_reference("board", "cad_reference_fixture.glb", POSE_TRANSLATE_ONLY)], _document_path, parent)
	check("cache: an unchanged file is not re-read after a reload",
			library.get_load_count() == 2,
			"load count %d" % library.get_load_count())

	parent.free()
	# Put the original fixture back for anything that runs after this.
	_write_fixture_glb(_glb_path, Vector3(2.0, 4.0, 6.0))


# ---------------------------------------------------------------------------
# units= / up= are geometry, not decoration
# ---------------------------------------------------------------------------

## The unit and up-axis conversion is BAKED into the cached part transforms, so
## it is part of the identity of the geometry — not a display setting applied
## afterwards. Anything that caches on a reference (the panel's collider
## digest, the segmentation key) therefore has to key on units and up as well,
## or a units= edit shows the new geometry on screen while every measurement
## still answers about the old one. The record carries both so that a caller
## CAN key on them, and the same file under two unit declarations is two
## different loads with two different sizes.
func _test_a_units_change_is_a_different_geometry_and_says_so() -> void:
	var library = ReferenceMeshes.new()
	var parent := Node3D.new()
	root.add_child(parent)

	library.mount([_reference("board", "cad_reference_fixture.glb", POSE_TRANSLATE_ONLY)],
			_document_path, parent)
	var as_metres: Dictionary = _first_record(library)

	var millimetre_spec := _reference("board", "cad_reference_fixture.glb", POSE_TRANSLATE_ONLY)
	millimetre_spec["units"] = "mm"
	library.mount([millimetre_spec], _document_path, parent)
	var as_millimetres: Dictionary = _first_record(library)

	check("units: the record says which units and up-axis the geometry was converted from",
			str(as_metres.get("units", "")) == "m" and str(as_metres.get("up", "")) == "y"
				and str(as_millimetres.get("units", "")) == "mm",
			"metres record units='%s' up='%s', millimetre record units='%s'" % [
				str(as_metres.get("units", "")), str(as_metres.get("up", "")),
				str(as_millimetres.get("units", "")),
			])

	# The fixture is authored in metres, so reading it as millimetres shrinks
	# it by a thousand: the two mounts are not the same geometry, and a cache
	# key that ignores units would hand one of them the other's answer.
	var metre_box: AABB = as_metres.get("local_aabb", AABB())
	var millimetre_box: AABB = as_millimetres.get("local_aabb", AABB())
	check("units: reading the same file as mm instead of m is different geometry",
			metre_box.size.length() > 0.0
				and absf(metre_box.size.length() - millimetre_box.size.length() * 1000.0)
					< metre_box.size.length() * 0.001,
			"m bounds %s vs mm bounds %s" % [str(metre_box), str(millimetre_box)])

	check("units: a units= change is a real re-read, not a cache hit",
			library.get_load_count() == 2,
			"load count %d after mounting the same path under two unit declarations"
				% library.get_load_count())

	# The part transforms are what the colliders and the segmentation are built
	# from, so this is the value the panel's digest has to cover.
	var metre_parts: Array = as_metres.get("parts", [])
	var millimetre_parts: Array = as_millimetres.get("parts", [])
	var metre_first: Transform3D = (metre_parts[0] as Dictionary).get(
			"transform", Transform3D.IDENTITY) if metre_parts.size() > 0 else Transform3D.IDENTITY
	var millimetre_first: Transform3D = (millimetre_parts[0] as Dictionary).get(
			"transform", Transform3D.IDENTITY) if millimetre_parts.size() > 0 else Transform3D.IDENTITY
	check("units: the conversion is baked into the part transforms the gauge uses",
			metre_parts.size() == millimetre_parts.size() and metre_parts.size() > 0
				and not metre_first.is_equal_approx(millimetre_first),
			"m transform %s vs mm transform %s" % [str(metre_first), str(millimetre_first)])

	parent.free()


func _first_record(library) -> Dictionary:
	var records: Array = library.mounted_references()
	return records[0] if records.size() > 0 else {}


# ---------------------------------------------------------------------------
# Path resolution against the document
# ---------------------------------------------------------------------------

func _test_path_resolution() -> void:
	var library = ReferenceMeshes.new()

	var relative: Dictionary = library.resolve("meshes/board.glb", "/projects/case/case.mcad")
	check("paths: a relative path resolves against the .mcad that named it",
			str(relative["path"]) == "/projects/case/meshes/board.glb"
				and str(relative["error"]).is_empty(),
			"got '%s' error '%s'" % [str(relative["path"]), str(relative["error"])])

	var anonymous_relative: Dictionary = library.resolve("board.glb", "")
	check("paths: a relative path in an unsaved document is a named error",
			not str(anonymous_relative["error"]).is_empty()
				and str(anonymous_relative["path"]).is_empty(),
			"got path '%s' error '%s'" % [
				str(anonymous_relative["path"]), str(anonymous_relative["error"]),
			])

	var anonymous_absolute: Dictionary = library.resolve("/tmp/board.glb", "")
	check("paths: an unsaved document accepts an absolute path, with a warning",
			str(anonymous_absolute["path"]) == "/tmp/board.glb"
				and not str(anonymous_absolute["warning"]).is_empty()
				and str(anonymous_absolute["error"]).is_empty(),
			"path '%s' warning '%s' error '%s'" % [
				str(anonymous_absolute["path"]),
				str(anonymous_absolute["warning"]),
				str(anonymous_absolute["error"]),
			])


func _test_a_missing_reference_is_reported_not_crashed() -> void:
	var library = ReferenceMeshes.new()
	var parent := Node3D.new()
	root.add_child(parent)
	var report: Dictionary = library.mount(
		[_reference("gone", "no_such_board.glb", POSE_TRANSLATE_ONLY)], _document_path, parent)
	var errors: PackedStringArray = report.get("errors", PackedStringArray())
	check("failure: a missing reference file is reported by name, not silent",
			errors.size() == 1 and errors[0].contains("no_such_board.glb")
				and int(report.get("mounted", 0)) == 0,
			"errors=%s mounted=%s" % [str(errors), str(report.get("mounted", 0))])
	parent.free()


# ---------------------------------------------------------------------------
# The feature-edge extractor, shared with mesh_display.gd
# ---------------------------------------------------------------------------

func _test_feature_edges() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(10.0, 10.0, 10.0)
	var arrays: Array = box.get_mesh_arrays()
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices := PackedInt32Array()
	var raw_indices: Variant = arrays[Mesh.ARRAY_INDEX]
	if raw_indices is PackedInt32Array:
		indices = raw_indices
	else:
		for i in range(positions.size()):
			indices.append(i)

	var segments: PackedVector3Array = ReferenceMeshes.feature_edge_segments(positions, indices)
	check("outline: a box has exactly its twelve edges, not one per triangle",
			segments.size() == 24,
			"got %d endpoints (%d edges) — coincident corners are not being welded"
				% [segments.size(), int(segments.size() / 2)])

	var line_mesh: ArrayMesh = ReferenceMeshes.line_mesh_from_segments(segments, Color.RED)
	check("outline: the segments become a line mesh",
			line_mesh != null and _is_line_mesh(line_mesh),
			"line mesh was %s" % str(line_mesh))

	check("outline: no segments means no mesh, not an empty one",
			ReferenceMeshes.line_mesh_from_segments(PackedVector3Array(), Color.RED) == null,
			"an empty segment list produced a mesh")


func _test_frame_conversion_arithmetic() -> void:
	var to_cad: Transform3D = ReferenceMeshes.conversion_transform("", "", "board.glb")
	var up_metre := to_cad * Vector3(0.0, 1.0, 0.0)
	check("frame: one metre up the glTF Y axis is 1000 mm up the CAD Z axis",
			up_metre.distance_to(Vector3(0.0, 0.0, 1000.0)) < TOLERANCE_MM,
			"got %s" % str(up_metre))

	var inches: Transform3D = ReferenceMeshes.conversion_transform("in", "z", "part.obj")
	check("frame: a declared unit and up-axis override the format default",
			(inches * Vector3(1.0, 0.0, 0.0)).distance_to(Vector3(25.4, 0.0, 0.0)) < TOLERANCE_MM,
			"got %s" % str(inches * Vector3(1.0, 0.0, 0.0)))

	var pose: Transform3D = ReferenceMeshes.transform_from_matrix(POSE_ROTATE_TRANSLATE)
	check("frame: the worker's row-major 4x4 is read as rows, not columns",
			pose.origin.distance_to(Vector3(100.0, 200.0, 300.0)) < TOLERANCE_MM
				and (pose.basis * Vector3(1.0, 0.0, 0.0)).distance_to(Vector3(0.0, 1.0, 0.0))
					< TOLERANCE_MM,
			"origin %s, x axis %s" % [str(pose.origin), str(pose.basis * Vector3.RIGHT)])


# ---------------------------------------------------------------------------
# Auto-framing
# ---------------------------------------------------------------------------

## A document whose only geometry is a reference still has to be looked at:
## MeshDisplay must frame on the reference bounds when there is no solid.
func _test_auto_framing_covers_the_reference() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var camera = OrbitCameraScript.new()
	camera.name = "OrbitCamera"
	holder.add_child(camera)
	var display = MeshDisplayScript.new()
	display.name = "MeshRoot"
	holder.add_child(display)

	var reference_bounds := AABB(
		EXPECTED_WORLD_MIN, EXPECTED_WORLD_MAX - EXPECTED_WORLD_MIN)
	display.set_reference_aabb(reference_bounds)
	display.update_mesh({})

	check("framing: with no solid, the camera frames on the reference",
			camera.get_target().distance_to(reference_bounds.get_center()) < TOLERANCE_MM,
			"camera target %s, reference centre %s" % [
				str(camera.get_target()), str(reference_bounds.get_center()),
			])
	check("framing: the camera pulled back far enough to see it",
			camera.get_distance() > reference_bounds.size.length() * 0.5,
			"distance %f for a %s bounding box"
				% [camera.get_distance(), str(reference_bounds.size)])

	holder.free()


# ---------------------------------------------------------------------------
# Fixture construction
# ---------------------------------------------------------------------------

## Build a small textured, multi-node, light-carrying scene and write it out as
## a GLB. `box_a_size` is the only knob: changing it changes the bytes on disk,
## which is what the cache-staleness assertions need.
##
## The 0.001 scale on "Assembly" is not decoration — it is what a glTF exported
## from millimetre CAD data looks like, and it is the reason parent transforms
## have to be composed rather than read.
## The same fixture written as .gltf, which puts the geometry in a sibling
## .bin and the materials in sibling image files.
func _write_fixture_gltf(path: String, box_a_size: Vector3) -> bool:
	return _write_fixture_glb(path, box_a_size)


## The files a .gltf's JSON names outside itself, resolved beside it.
func _external_files_of(gltf_path: String) -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(gltf_path))
	if not (parsed is Dictionary):
		return []
	var base := gltf_path.get_base_dir()
	var out: Array = []
	for key in ["buffers", "images"]:
		for entry in (parsed as Dictionary).get(key, []):
			var uri := str((entry as Dictionary).get("uri", ""))
			if uri.is_empty() or uri.begins_with("data:"):
				continue
			var resolved := base.path_join(uri.uri_decode()).simplify_path()
			if not (resolved in out):
				out.append(resolved)
	return out


func _remove_all(paths: Array) -> void:
	for path in paths:
		if FileAccess.file_exists(str(path)):
			DirAccess.remove_absolute(str(path))


func _write_fixture_glb(path: String, box_a_size: Vector3) -> bool:
	var scene_root := Node3D.new()
	scene_root.name = "Scene"

	var assembly := Node3D.new()
	assembly.name = "Assembly"
	assembly.transform = Transform3D(Basis().scaled(Vector3(0.001, 0.001, 0.001)), Vector3.ZERO)
	scene_root.add_child(assembly)

	var box_a := BoxMesh.new()
	box_a.size = box_a_size
	box_a.material = _textured_material()
	var node_a := MeshInstance3D.new()
	node_a.name = "BoxA"
	node_a.mesh = box_a
	node_a.position = Vector3(10.0, 0.0, 0.0)
	assembly.add_child(node_a)

	var group := Node3D.new()
	group.name = "Group"
	group.position = Vector3(0.0, 20.0, 0.0)
	assembly.add_child(group)

	var box_b := BoxMesh.new()
	box_b.size = Vector3(2.0, 2.0, 2.0)
	var node_b := MeshInstance3D.new()
	node_b.name = "BoxB"
	node_b.mesh = box_b
	node_b.position = Vector3(0.0, 0.0, 5.0)
	group.add_child(node_b)

	var lamp := OmniLight3D.new()
	lamp.name = "Lamp"
	lamp.position = Vector3(0.0, 50.0, 0.0)
	assembly.add_child(lamp)

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


func _textured_material() -> StandardMaterial3D:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.5, 0.9))
	var material := StandardMaterial3D.new()
	material.albedo_texture = ImageTexture.create_from_image(image)
	material.albedo_color = Color(1.0, 1.0, 1.0)
	return material


## One entry of an evaluation's `references` array, exactly as the worker's
## MeshReference.to_dict emits it.
func _reference(reference_name: String, path: String, matrix: Array) -> Dictionary:
	return {
		"name": reference_name,
		"path": path,
		"units": "m",
		"up": "y",
		"matrix": matrix,
	}


func _cleanup() -> void:
	if _glb_path != "" and FileAccess.file_exists(_glb_path):
		DirAccess.remove_absolute(_glb_path)


# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

func _aabb_matches(box: AABB, expected_min: Vector3, expected_max: Vector3) -> bool:
	return box.position.distance_to(expected_min) < TOLERANCE_MM \
		and (box.position + box.size).distance_to(expected_max) < TOLERANCE_MM


## Every MeshInstance3D beneath a named container of every mounted reference.
func _mesh_instances(parent: Node3D, container_name: String) -> Array:
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


## Bounds of the given instances read back off the live scene graph, which is
## an independent path to the same answer as the mount report.
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


func _has_textured_surface(instances: Array) -> bool:
	for instance in instances:
		var mi: MeshInstance3D = instance
		if mi.mesh == null:
			continue
		for surface in range(mi.mesh.get_surface_count()):
			var material := mi.mesh.surface_get_material(surface)
			if material is BaseMaterial3D and (material as BaseMaterial3D).albedo_texture != null:
				return true
	return false


func _is_line_mesh(mesh: Mesh) -> bool:
	return mesh != null and mesh.get_surface_count() > 0 \
		and mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES


func _find_light(node: Node) -> Node:
	if node is Light3D:
		return node
	for child in node.get_children():
		var found := _find_light(child)
		if found != null:
			return found
	return null


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
