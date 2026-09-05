extends SceneTree
## A sliver in the mesh must not become a speck on the drawing.
##
## The panes showing a direction draw the outline alone — the shaded surface is
## hidden there, which is why they are the panes an owner inspects a wall in.
## The outline pass calls an edge a feature when it BOUNDS the surface or when
## the two faces meeting there disagree. It decided "bounds the surface" by
## counting the normals it had collected, and it collects no normal from a
## triangle with no area: so the two neighbours of a zero-area sliver each
## looked like a boundary, and three short segments appeared in the middle of a
## flat face. In the shaded pane the surface covers them. In the ortho panes
## they are visible, and they move with the part, because they ARE part of it.
##
## MEASURED, not assumed. The tessellated mesh of a loft − loft hollow is
## manifold: 11,248 faces, every welded edge used by exactly two of them, no
## degenerate face, no duplicate. Cut that hollow in two with a box — the
## two-part shell the owner was looking at — and OCCT emits 2 zero-area
## triangles in 15,378, which the old rule turned into 5 spurious segments.
## Dozens of cuts (grille holes, wall cutouts, windows) scale that up.
##
## ORACLE. What would show this wrong: a mesh with a real hole in it that draws
## no boundary — the fix must silence slivers without silencing holes. Both
## cases are below, and the defect counts the panel now reports on every
## evaluation are the same walk's answer to "is this mesh sound?".
##
## Run:
##   cd <minerva>/src && godot --headless -s res://../../minerva-plugins/cad/tests/gd/test_ortho_speckles.gd

const ReferenceMeshes := preload("res://../../minerva-plugins/cad/ui/scripts/reference_meshes.gd")
const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const GRID := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"

## Plate: a 4x4 grid of quads in the z=0 plane, 5 mm pitch.
const CELLS := 4
const PITCH := 5.0

var _pass: int = 0
var _fail: int = 0


class _EditorStub extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== CAD Ortho Speckle Test (a sliver is not an edge) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s — %s" % [label, detail])


func _run() -> void:
	_check_sliver()
	_check_real_boundaries()
	await _check_panel_report()


# ---------------------------------------------------------------------------
# The speckle
# ---------------------------------------------------------------------------

func _check_sliver() -> void:
	# A flat sheet whose two halves are joined across a line of three collinear
	# points by a triangle with no area — the shape a boolean cut leaves in an
	# otherwise closed tessellation. The middle triangle carries the surface's
	# connectivity and nothing else.
	var sheet := _sheet_with_sliver()
	var positions: PackedVector3Array = sheet["positions"]

	var area_squared := (positions[1] - positions[0]).cross(positions[2] - positions[0]).length_squared()
	check("premise: the joining triangle has no area, so the pass has no "
			+ "normal to take from it",
			area_squared <= 0.000001, "|cross|^2 = %.12f" % area_squared)

	var torn_stats := {}
	var torn := ReferenceMeshes.feature_edge_segments(
		positions, sheet["without_sliver"], ReferenceMeshes.FEATURE_EDGE_ANGLE_DEGREES, torn_stats)
	check("premise: without that triangle the sheet is TORN along the line, "
			+ "and the outline says so — four rim edges plus the three of the tear",
			torn.size() / 2 == 7 and int(torn_stats.get("open_edges", 0)) == 7,
			"%d segments, stats %s" % [torn.size() / 2, str(torn_stats)])

	var stats := {}
	var segments := ReferenceMeshes.feature_edge_segments(
		positions, sheet["indices"], ReferenceMeshes.FEATURE_EDGE_ANGLE_DEGREES, stats)
	check("with it, the face is whole and the outline is the rim ALONE — the "
			+ "three segments across the middle were the speckle",
			segments.size() / 2 == 4 and _interior_segments(segments).is_empty(),
			"%d segments, interior %s" % [
				segments.size() / 2, str(_interior_segments(segments))])
	check("the same walk counts the sliver and reports a sound surface: no "
			+ "hole, nothing meeting three deep",
			int(stats.get("degenerate_faces", 0)) == 1
				and int(stats.get("open_edges", 0)) == 4
				and int(stats.get("non_manifold_edges", 0)) == 0,
			"stats = %s" % str(stats))


## Diamond sheet: P0, P1, P2 collinear along y=0; Q above, R below. Two real
## triangles above the line, one below, and a zero-area triangle on the line
## holding the halves together.
func _sheet_with_sliver() -> Dictionary:
	var positions := PackedVector3Array([
		Vector3(0, 0, 0),    # 0  P0
		Vector3(5, 0, 0),    # 1  P1
		Vector3(10, 0, 0),   # 2  P2
		Vector3(5, 5, 0),    # 3  Q
		Vector3(5, -5, 0),   # 4  R
	])
	var without := PackedInt32Array([
		0, 1, 3,
		1, 2, 3,
		0, 4, 2,
	])
	var with_sliver := PackedInt32Array(without)
	with_sliver.append_array([0, 1, 2])
	return {
		"positions": positions,
		"indices": with_sliver,
		"without_sliver": without,
	}


# ---------------------------------------------------------------------------
# What must still be drawn, and still be counted
# ---------------------------------------------------------------------------

func _check_real_boundaries() -> void:
	var plate := _plate()
	var positions: PackedVector3Array = plate["positions"]
	var indices: PackedInt32Array = plate["indices"]

	# Punch a hole: drop the two triangles of one interior cell.
	var holed := PackedInt32Array()
	var dropped := 0
	for t in range(indices.size() / 3):
		var centre := (positions[indices[t * 3]] + positions[indices[t * 3 + 1]]
			+ positions[indices[t * 3 + 2]]) / 3.0
		if centre.x > PITCH and centre.x < 2.0 * PITCH \
				and centre.y > PITCH and centre.y < 2.0 * PITCH:
			dropped += 1
			continue
		holed.append_array([indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]])
	var hole_stats := {}
	var hole_segments := ReferenceMeshes.feature_edge_segments(
		positions, holed, ReferenceMeshes.FEATURE_EDGE_ANGLE_DEGREES, hole_stats)
	check("premise: a cell really was removed from the middle of the plate",
			dropped == 2, "dropped %d triangles" % dropped)
	check("a HOLE is still drawn: four segments around it, inside the face — "
			+ "the rule silences slivers, not missing material",
			_interior_segments(hole_segments).size() / 2 == 4,
			"interior segments = %d" % (_interior_segments(hole_segments).size() / 2))
	check("and the evaluation can say it in numbers: the walk reports the "
			+ "open edges a hole leaves",
			int(hole_stats.get("open_edges", 0)) == 4 + _rim_edge_count(),
			"open_edges = %d, rim is %d" % [
				int(hole_stats.get("open_edges", 0)), _rim_edge_count()])

	# A closed box has no boundary at all, and its twelve edges are creases.
	var box := _box()
	var box_stats := {}
	var box_segments := ReferenceMeshes.feature_edge_segments(
		box["positions"], box["indices"], ReferenceMeshes.FEATURE_EDGE_ANGLE_DEGREES, box_stats)
	check("control: a closed box reports no defect and draws its twelve real "
			+ "edges — the rule did not go quiet everywhere",
			box_segments.size() / 2 == 12
				and int(box_stats.get("open_edges", 0)) == 0
				and int(box_stats.get("degenerate_faces", 0)) == 0
				and int(box_stats.get("duplicate_faces", 0)) == 0
				and int(box_stats.get("non_manifold_edges", 0)) == 0,
			"%d segments, stats %s" % [box_segments.size() / 2, str(box_stats)])

	# The same triangle twice — a doubled face renders as one and measures as two.
	var doubled := PackedInt32Array(box["indices"])
	doubled.append_array([box["indices"][0], box["indices"][1], box["indices"][2]])
	var doubled_stats := {}
	ReferenceMeshes.feature_edge_segments(
		box["positions"], doubled, ReferenceMeshes.FEATURE_EDGE_ANGLE_DEGREES, doubled_stats)
	check("a doubled face is counted as one duplicate, not as three "
			+ "non-manifold edges alone",
			int(doubled_stats.get("duplicate_faces", 0)) == 1
				and int(doubled_stats.get("non_manifold_edges", 0)) == 3,
			"stats = %s" % str(doubled_stats))


# ---------------------------------------------------------------------------
# What the panel says about the mesh it drew
# ---------------------------------------------------------------------------

func _check_panel_report() -> void:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	var panel: Node = packed.instantiate()
	root.add_child(panel)
	var editor := _EditorStub.new()
	editor.tab_title = "speckles"
	panel._on_panel_loaded({
		"plugin_id": "cad", "panel_name": "cad_panel",
		"host_api_version": "1", "editor": editor,
	})
	panel._apply_width_class(&"lg")
	await process_frame

	var mesh_root: Node = panel.get_node("%s/TopView/SubViewport/MeshRoot" % GRID)
	mesh_root.call("update_mesh", _box_mesh_data(), [])
	check("a sound solid says nothing about defects — a clean mesh has no "
			+ "report to make",
			panel._mesh_defects().is_empty(),
			"reported %s" % str(panel._mesh_defects()))

	mesh_root.call("update_mesh", _holed_box_mesh_data(), [])
	var defects: Dictionary = panel._mesh_defects()
	check("a solid with a face missing reports the hole, in the evaluation "
			+ "reply, without anyone asking for it",
			int(defects.get("open_edges", 0)) == 4 and defects.size() == 1,
			"reported %s" % str(defects))

	panel.free()


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

## A flat grid-triangulated plate in the z=0 plane.
func _plate() -> Dictionary:
	var positions := PackedVector3Array()
	for i in range(CELLS + 1):
		for j in range(CELLS + 1):
			positions.append(Vector3(float(i) * PITCH, float(j) * PITCH, 0.0))
	var indices := PackedInt32Array()
	for i in range(CELLS):
		for j in range(CELLS):
			var a := i * (CELLS + 1) + j
			indices.append_array([a, a + 1, a + CELLS + 1])
			indices.append_array([a + 1, a + CELLS + 2, a + CELLS + 1])
	return {"positions": positions, "indices": indices}


## Edges around the outside of the plate.
func _rim_edge_count() -> int:
	return 4 * CELLS


## A segment is interior when neither endpoint is on the outer boundary of the
## fixture it came from. Both fixtures span x,y in [0, span] with their rim on
## those lines, so one test serves both.
func _interior_segments(segments: PackedVector3Array,
		span: float = float(CELLS) * PITCH) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in range(0, segments.size(), 2):
		if _on_rim(segments[i], span) or _on_rim(segments[i + 1], span):
			continue
		out.append(segments[i])
		out.append(segments[i + 1])
	return out


func _on_rim(point: Vector3, span: float) -> bool:
	return is_zero_approx(point.x) or is_zero_approx(point.y) \
		or is_equal_approx(point.x, span) or is_equal_approx(point.y, span)


## A closed 10 mm box: eight corners, twelve triangles.
func _box() -> Dictionary:
	var positions := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(10, 10, 0), Vector3(0, 10, 0),
		Vector3(0, 0, 10), Vector3(10, 0, 10), Vector3(10, 10, 10), Vector3(0, 10, 10),
	])
	var indices := PackedInt32Array([
		0, 2, 1, 0, 3, 2,        # bottom
		4, 5, 6, 4, 6, 7,        # top
		0, 1, 5, 0, 5, 4,        # -Y
		1, 2, 6, 1, 6, 5,        # +X
		2, 3, 7, 2, 7, 6,        # +Y
		3, 0, 4, 3, 4, 7,        # -X
	])
	return {"positions": positions, "indices": indices}


## The same box in the panel's {vertices, faces} shape.
func _box_mesh_data() -> Dictionary:
	var box := _box()
	var vertices: Array = []
	for point in (box["positions"] as PackedVector3Array):
		vertices.append([point.x, point.y, point.z])
	var faces: Array = []
	var indices: PackedInt32Array = box["indices"]
	for t in range(indices.size() / 3):
		faces.append([indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]])
	return {"vertices": vertices, "faces": faces}


## The box with one face's two triangles missing: a four-edge hole.
func _holed_box_mesh_data() -> Dictionary:
	var data := _box_mesh_data()
	var faces: Array = data["faces"]
	faces.remove_at(1)
	faces.remove_at(0)
	data["faces"] = faces
	return data
