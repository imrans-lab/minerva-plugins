extends SceneTree
## STL as a reference format — ui/scripts/stl_reader.gd through the reference
## library.
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## cad_export has always written STL, and mesh() refused to read one, so a
## stand-in authored in the DSL could not be mounted as a reference. The fixture
## here is therefore the file the plugin itself produces: a box, written twice —
## once as binary STL and once as ASCII — by this test, byte by byte. Nothing is
## checked in, and every bound asserted below is a literal the test wrote rather
## than a number recomputed with the reader's own arithmetic.
##
## The three mistakes the fixture is shaped to catch:
##   * a reader that sniffs for the leading "solid" calls the binary file ASCII
##     (its 80-byte header here deliberately begins with "solid"), reads no
##     triangles and mounts nothing;
##   * a reader that keeps the per-facet normal instead of recomputing it
##     shades the box inside out — the fixture's stored normals are zero;
##   * a library that applies the glTF frame (metres, Y-up) to an STL reports
##     the box 1000x small and on the wrong axes.
##
## ORACLE. An independent observation that would show the fix wrong: open the
## same two files in any mesh viewer and measure the box. It is 2 x 4 x 6 mm
## with its minimum corner at the origin; if the panel says anything else, the
## conversion here is wrong, whatever this suite reports.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const ReferenceMeshes := preload("res://../../minerva-plugins/cad/ui/scripts/reference_meshes.gd")
const MeshImport := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_import.gd")

const TOLERANCE_MM := 0.001

## The box the fixture writes, in the file's own numbers.
const BOX_MIN := Vector3(0.0, 0.0, 0.0)
const BOX_MAX := Vector3(2.0, 4.0, 6.0)

## Read as millimetres, Z-up — the STL default — the CAD-frame bounds are the
## file's own numbers unchanged.
const EXPECTED_LOCAL_MIN := Vector3(0.0, 0.0, 0.0)
const EXPECTED_LOCAL_MAX := Vector3(2.0, 4.0, 6.0)

## translate([100, 200, 300]), row-major, as the worker reports it.
const POSE_TRANSLATE := [
	[1.0, 0.0, 0.0, 100.0],
	[0.0, 1.0, 0.0, 200.0],
	[0.0, 0.0, 1.0, 300.0],
	[0.0, 0.0, 0.0, 1.0],
]

var _pass: int = 0
var _fail: int = 0
var _paths: Array = []
var _document_path: String = ""


func _init() -> void:
	print("=== CAD STL Reference Test ===\n")
	await process_frame
	_run()
	_cleanup()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	var scratch := OS.get_user_data_dir()
	_document_path = scratch.path_join("cad_stl_fixture.mcad")
	var binary_path: String = scratch.path_join("cad_stl_fixture.stl")
	var ascii_path: String = scratch.path_join("cad_stl_ascii_fixture.stl")
	_paths = [binary_path, ascii_path]

	check("fixture: the binary STL was written",
			_write_binary_stl(binary_path), "could not write %s" % binary_path)
	check("fixture: the ASCII STL was written",
			_write_ascii_stl(ascii_path), "could not write %s" % ascii_path)

	_test_the_panel_declares_stl_loadable()
	_test_a_binary_stl_mounts_in_millimetres(binary_path)
	_test_an_ascii_stl_reads_the_same_box(ascii_path)
	_test_an_undeclared_unit_is_millimetres_and_says_so(binary_path)
	_test_a_declared_unit_is_honoured(binary_path)


func _test_the_panel_declares_stl_loadable() -> void:
	check("import: the file picker offers .stl",
			MeshImport.SUPPORTED_EXTENSIONS.has("stl"),
			"SUPPORTED_EXTENSIONS = %s" % str(MeshImport.SUPPORTED_EXTENSIONS))
	check("library: the loader accepts .stl",
			ReferenceMeshes.SUPPORTED_EXTENSIONS.has("stl"),
			"SUPPORTED_EXTENSIONS = %s" % str(ReferenceMeshes.SUPPORTED_EXTENSIONS))


func _test_a_binary_stl_mounts_in_millimetres(path: String) -> void:
	var library = ReferenceMeshes.new()
	var loaded = library.load_file(path, "mm", "z")

	check("binary: the file loaded",
			loaded.error.is_empty(), "error: %s" % loaded.error)
	check("binary: the box is 12 triangles",
			loaded.triangle_count == 12,
			"triangle_count = %d (a reader that took the 'solid' header for "
				% loaded.triangle_count + "ASCII finds none)")
	check("binary: the reference's own bounds are the millimetres the file holds",
			_aabb_matches(loaded.local_aabb, EXPECTED_LOCAL_MIN, EXPECTED_LOCAL_MAX),
			"got %s (a loader applying the glTF frame is 1000x small and Y-up)"
				% str(loaded.local_aabb))
	check("binary: the part is named after the file",
			loaded.parts.size() == 1
				and str((loaded.parts[0] as Dictionary).get("node", ""))
					== "cad_stl_fixture",
			"parts = %s" % str(loaded.parts))

	var parent := Node3D.new()
	root.add_child(parent)
	var report: Dictionary = library.mount(
		[_reference("stand_in", path, POSE_TRANSLATE, "mm", true)],
		_document_path,
		parent
	)
	check("binary: the reference is in the world",
			int(report.get("mounted", 0)) == 1,
			"mounted=%s errors=%s" % [
				str(report.get("mounted", 0)), str(report.get("errors", [])),
			])
	check("binary: the world bounds are the box at its pose",
			_aabb_matches(
				report.get("world_aabb", AABB()),
				EXPECTED_LOCAL_MIN + Vector3(100.0, 200.0, 300.0),
				EXPECTED_LOCAL_MAX + Vector3(100.0, 200.0, 300.0)),
			"got %s" % str(report.get("world_aabb", AABB())))
	parent.queue_free()


func _test_an_ascii_stl_reads_the_same_box(path: String) -> void:
	var library = ReferenceMeshes.new()
	var loaded = library.load_file(path, "mm", "z")
	check("ascii: the file loaded",
			loaded.error.is_empty(), "error: %s" % loaded.error)
	check("ascii: the same 12 triangles",
			loaded.triangle_count == 12,
			"triangle_count = %d" % loaded.triangle_count)
	check("ascii: the same bounds as the binary file",
			_aabb_matches(loaded.local_aabb, EXPECTED_LOCAL_MIN, EXPECTED_LOCAL_MAX),
			"got %s" % str(loaded.local_aabb))
	check("ascii: the part is named after the solid the file declares",
			loaded.parts.size() == 1
				and str((loaded.parts[0] as Dictionary).get("node", ""))
					== "stand_in",
			"parts = %s" % str(loaded.parts))


## An STL states no units. Loading it as millimetres is the only useful default,
## but a file authored in inches then mounts at 1/25.4 of its size with every
## clearance measured against it quietly wrong — so the default is reported.
func _test_an_undeclared_unit_is_millimetres_and_says_so(path: String) -> void:
	var library = ReferenceMeshes.new()
	var parent := Node3D.new()
	root.add_child(parent)
	var report: Dictionary = library.mount(
		[_reference("stand_in", path, POSE_TRANSLATE, "mm", false)],
		_document_path,
		parent
	)
	var warnings: PackedStringArray = report.get("warnings", PackedStringArray())
	var said := false
	for line in warnings:
		if str(line).contains("millimetres") and str(line).contains("units="):
			said = true
	check("units: an STL mounted without units= is warned about", said,
			"warnings = %s" % str(warnings))
	check("units: it is still mounted, in millimetres",
			_aabb_matches(
				report.get("world_aabb", AABB()),
				EXPECTED_LOCAL_MIN + Vector3(100.0, 200.0, 300.0),
				EXPECTED_LOCAL_MAX + Vector3(100.0, 200.0, 300.0)),
			"got %s" % str(report.get("world_aabb", AABB())))
	parent.queue_free()


func _test_a_declared_unit_is_honoured(path: String) -> void:
	var library = ReferenceMeshes.new()
	var loaded = library.load_file(path, "in", "z")
	check("units: units=\"in\" scales the same file by 25.4",
			_aabb_matches(
				loaded.local_aabb,
				EXPECTED_LOCAL_MIN * 25.4,
				EXPECTED_LOCAL_MAX * 25.4),
			"got %s" % str(loaded.local_aabb))


# ---------------------------------------------------------------------------
# Fixture writers — the bytes are authored here, so the file is the test
# ---------------------------------------------------------------------------

## The 12 triangles of an axis-aligned box, wound outward.
func _box_triangles() -> Array:
	var a := BOX_MIN
	var b := BOX_MAX
	var corners := [
		Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z),
		Vector3(b.x, b.y, a.z), Vector3(a.x, b.y, a.z),
		Vector3(a.x, a.y, b.z), Vector3(b.x, a.y, b.z),
		Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z),
	]
	var quads := [
		[0, 3, 2, 1],  # -Z
		[4, 5, 6, 7],  # +Z
		[0, 1, 5, 4],  # -Y
		[2, 3, 7, 6],  # +Y
		[0, 4, 7, 3],  # -X
		[1, 2, 6, 5],  # +X
	]
	var out: Array = []
	for quad in quads:
		out.append([corners[quad[0]], corners[quad[1]], corners[quad[2]]])
		out.append([corners[quad[0]], corners[quad[2]], corners[quad[3]]])
	return out


## A binary STL whose 80-byte header deliberately begins with "solid": the
## reader must decide on the file's LENGTH, not on that word.
func _write_binary_stl(path: String) -> bool:
	var triangles := _box_triangles()
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle == null:
		return false
	var header := PackedByteArray()
	header.resize(80)
	header.fill(0)
	var word := "solid trap".to_utf8_buffer()
	for i in range(word.size()):
		header[i] = word[i]
	handle.store_buffer(header)
	handle.store_32(triangles.size())
	for triangle in triangles:
		# The stored normal is zero: a reader that trusts it rather than
		# recomputing shades the box with no lighting at all.
		for _axis in range(3):
			handle.store_float(0.0)
		for corner in triangle:
			handle.store_float((corner as Vector3).x)
			handle.store_float((corner as Vector3).y)
			handle.store_float((corner as Vector3).z)
		handle.store_16(0)
	handle.close()
	return FileAccess.file_exists(path)


func _write_ascii_stl(path: String) -> bool:
	var lines := PackedStringArray(["solid stand_in"])
	for triangle in _box_triangles():
		lines.append("  facet normal 0 0 0")
		lines.append("    outer loop")
		for corner in triangle:
			var v: Vector3 = corner
			lines.append("      vertex %f %f %f" % [v.x, v.y, v.z])
		lines.append("    endloop")
		lines.append("  endfacet")
	lines.append("endsolid stand_in")
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle == null:
		return false
	handle.store_string("\n".join(lines) + "\n")
	handle.close()
	return FileAccess.file_exists(path)


## One entry of an evaluation's `references` array, as MeshReference.to_dict
## emits it. `units_declared` is what says whether the author chose the units
## or the worker filled in the format's default.
func _reference(
	reference_name: String,
	path: String,
	matrix: Array,
	units: String,
	units_declared: bool
) -> Dictionary:
	return {
		"name": reference_name,
		"path": path,
		"units": units,
		"units_declared": units_declared,
		"up": "z",
		"matrix": matrix,
	}


func _cleanup() -> void:
	for path in _paths:
		if FileAccess.file_exists(str(path)):
			DirAccess.remove_absolute(str(path))


func _aabb_matches(box: AABB, expected_min: Vector3, expected_max: Vector3) -> bool:
	return box.position.distance_to(expected_min) < TOLERANCE_MM \
		and (box.position + box.size).distance_to(expected_max) < TOLERANCE_MM


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
