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
## THAT WAS NOT THE END OF IT. A sliver with a LITTLE area has a normal, and it
## points anywhere: the seam where a post meets a lofted dome is triangulated
## with such slivers, and the dihedral test drew a fragment at each of them —
## arcs of dots that read as holes in the mesh. Guessing edges from
## triangle normals is the wrong question to ask about a solid the worker built
## from a B-Rep, so the solid's outline is now drawn from the worker's edge
## list: one polyline per numbered edge. The tessellation walk stays for the
## reference meshes, which have no edge list, and for the defect counts.
##
## ORACLE for that: a flat plate whose middle cell is triangulated around a
## vertex lifted two hundredths of a millimetre draws a star in the middle of a
## face that has no such feature. Drawn from the plate's four edges, it cannot.
##
## Run:
##   cd <minerva>/src && godot --headless -s res://../../minerva-plugins/cad/tests/gd/test_ortho_speckles.gd

const ReferenceMeshes := preload("res://../../minerva-plugins/cad/ui/scripts/reference_meshes.gd")
const EdgeOutline := preload("res://../../minerva-plugins/cad/ui/scripts/edge_outline.gd")
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
	_check_chain_from_a_curved_edge()
	_check_short_edges_far_from_the_origin()
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
# A curved edge is one line, not a scatter
# ---------------------------------------------------------------------------

## The seam where a post meets a dome is a curve. The worker samples it into a
## chord polyline; the outline must come back as that ONE chain, in order, with
## every segment carrying the seam's edge id. A pass that dropped the polyline
## and fell back to the two endpoints would draw a straight line across the
## dome; one that lost the ordering would draw a scatter.
func _check_chain_from_a_curved_edge() -> void:
	var arc := _arc_polyline(7)
	var outline: Dictionary = EdgeOutline.segments_from_edges([
		{"id": 41, "kind": "curve", "start": arc[0], "end": arc[arc.size() - 1],
			"polyline": arc},
	])
	var segments: PackedVector3Array = outline["segments"]
	var ids: PackedInt32Array = outline["edge_ids"]
	var chained := true
	for i in range(2, segments.size(), 2):
		if not segments[i].is_equal_approx(segments[i - 1]):
			chained = false
	check("a sampled curve is drawn as one connected chain of its own points, "
			+ "in order — six chords for seven samples",
			segments.size() / 2 == 6 and chained
				and segments[0].is_equal_approx(_as_vector3(arc[0]))
				and segments[segments.size() - 1].is_equal_approx(
					_as_vector3(arc[arc.size() - 1])),
			"%d segments, chained %s" % [segments.size() / 2, str(chained)])
	check("and every one of them names the edge it belongs to",
			ids.size() == segments.size() / 2 and _distinct_ids(ids) == [41]
				and int(outline["edges"]) == 1,
			"ids = %s, edges = %s" % [str(ids), str(outline["edges"])])


# ---------------------------------------------------------------------------
# Short edges a long way from the origin
# ---------------------------------------------------------------------------

## A part is modelled where it sits, not always at the origin, and Vector3's
## is_equal_approx scales its tolerance with the coordinates: a hundred metres
## out that tolerance is a whole millimetre, so the two ends of a
## half-millimetre edge compare EQUAL and every short edge of the part is
## dropped as a dot. What survives is a partial outline that looks like a
## modelling mistake. The skip has to be an absolute length.
func _check_short_edges_far_from_the_origin() -> void:
	var origin := Vector3(100000.0, 100000.0, 0.0)
	var thickness := 0.5
	var registry := _box_registry(origin, Vector3(thickness, 10.0, 10.0))
	var outline: Dictionary = EdgeOutline.segments_from_edges(registry)
	var segments: PackedVector3Array = outline["segments"]
	var shortest := INF
	for i in range(0, segments.size(), 2):
		shortest = minf(shortest, segments[i].distance_to(segments[i + 1]))
	check("a thin box 100 m from the origin keeps ALL twelve of its edges, "
			+ "the four half-millimetre ones included",
			int(outline["edges"]) == 12 and segments.size() == 24
				and absf(shortest - thickness) < 0.05,
			"%d edges, %d segments, shortest %.4f mm" % [
				int(outline["edges"]), segments.size() / 2, shortest])

	# The other side of the same rule: an absolute epsilon must still drop the
	# thing the pass exists for.
	var with_dot: Array = registry.duplicate()
	var point: Array = _as_triple(origin)
	with_dot.append({"id": 99, "kind": "straight",
		"start": point, "end": point, "polyline": [point, point]})
	var drawn: Dictionary = EdgeOutline.segments_from_edges(with_dot)
	check("and an entry out there that really is a point still draws nothing",
			int(drawn["edges"]) == 12
				and (drawn["segments"] as PackedVector3Array).size() == 24,
			"%d edges, %d segments" % [int(drawn["edges"]),
				(drawn["segments"] as PackedVector3Array).size() / 2])


## The twelve straight edges of an axis-aligned box, as the worker's edge
## registry has them.
func _box_registry(origin: Vector3, size: Vector3) -> Array:
	var corners: Array = []
	for i in range(8):
		corners.append(origin + Vector3(
			size.x if (i & 1) != 0 else 0.0,
			size.y if (i & 2) != 0 else 0.0,
			size.z if (i & 4) != 0 else 0.0))
	var pairs := [
		[0, 1], [1, 3], [3, 2], [2, 0],
		[4, 5], [5, 7], [7, 6], [6, 4],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]
	var registry: Array = []
	for i in range(pairs.size()):
		var start: Array = _as_triple(corners[int(pairs[i][0])])
		var end: Array = _as_triple(corners[int(pairs[i][1])])
		registry.append({
			"id": i + 1, "kind": "straight",
			"start": start, "end": end, "polyline": [start, end],
		})
	return registry


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

	# The speckle in its smallest form: a flat plate with one sliver in it.
	# Nothing about the PART changed; the tessellation did.
	var starred := _plate_with_a_lifted_centre()
	mesh_root.call("update_mesh", starred, [])
	check("premise: guessing the outline from triangle normals puts a star in "
			+ "the middle of a face that has no feature there",
			_interior_segments(_drawn_segments(mesh_root)).size() > 0
				and str(mesh_root.call("get_outline_source")) == "tessellation",
			"%d interior segments, source %s" % [
				_interior_segments(_drawn_segments(mesh_root)).size() / 2,
				str(mesh_root.call("get_outline_source"))])

	mesh_root.call("update_mesh", starred, _plate_edge_registry())
	var drawn := _drawn_segments(mesh_root)
	var drawn_ids: PackedInt32Array = mesh_root.call("get_outline_edge_ids")
	check("drawn from the part's own edges instead, the SAME tessellation "
			+ "outlines the plate's four sides and nothing else",
			_interior_segments(drawn).is_empty() and drawn.size() / 2 == 4
				and str(mesh_root.call("get_outline_source")) == "brep",
			"%d segments, %d interior, source %s" % [
				drawn.size() / 2, _interior_segments(drawn).size() / 2,
				str(mesh_root.call("get_outline_source"))])
	check("and every segment on screen can be traced to the edge id the "
			+ "annotate and fillet tools use — no line belongs to nothing",
			drawn_ids.size() == drawn.size() / 2
				and _distinct_ids(drawn_ids) == [1, 2, 3, 4],
			"%d ids for %d segments: %s" % [
				drawn_ids.size(), drawn.size() / 2, str(drawn_ids)])

	# Box with two through-hole rims: fourteen edges, twelve of them straight.
	var box_with_holes := _box_with_holes_registry()
	mesh_root.call("update_mesh", _box_mesh_data(), box_with_holes)
	check("on a box with holes the drawing accounts for the whole edge list: "
			+ "as many outlined edges as the worker reported",
			int(mesh_root.call("get_outlined_edge_count")) == box_with_holes.size()
				and int(mesh_root.call("get_outlined_edge_count")) == 14
				and int(panel._outline_report().get("edges", 0)) == 14,
			"outlined %d of %d, report %s" % [
				int(mesh_root.call("get_outlined_edge_count")),
				box_with_holes.size(), str(panel._outline_report())])

	panel.free()


## The line segments the display is actually drawing, read back off the mesh it
## built — what is on screen, not what a counter says.
func _drawn_segments(mesh_root: Node) -> PackedVector3Array:
	var instance := mesh_root.get_node_or_null("FeatureEdges") as MeshInstance3D
	if instance == null or instance.mesh == null:
		return PackedVector3Array()
	var arrays: Array = (instance.mesh as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return vertices


func _distinct_ids(ids: PackedInt32Array) -> Array:
	var seen := {}
	for id in ids:
		seen[id] = true
	var out: Array = seen.keys()
	out.sort()
	return out


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


## The plate, with one interior cell re-triangulated as a fan around an added
## vertex placed 0.05 mm from the cell's left side and lifted 0.05 mm out of
## the plane. That makes ONE thin triangle whose normal is 45 degrees off the
## plate while its three neighbours stay flat — a sliver with area, which is
## what OCCT leaves along a boolean seam on a curved face, and what the
## dihedral test cannot tell from a real crease.
func _plate_with_a_lifted_centre() -> Dictionary:
	var plate := _plate()
	var positions: PackedVector3Array = plate["positions"]
	var indices: PackedInt32Array = plate["indices"]

	# The cell whose corners are (5,5), (5,10), (10,5) and (10,10).
	var a := 1 * (CELLS + 1) + 1
	var b := a + 1
	var c := a + CELLS + 1
	var d := a + CELLS + 2
	var cell := [a, b, c, d]
	var kept := PackedInt32Array()
	for t in range(indices.size() / 3):
		var corners := [indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]]
		if cell.has(corners[0]) and cell.has(corners[1]) and cell.has(corners[2]):
			continue
		kept.append_array(corners)

	var centre := positions.size()
	positions.append(Vector3(PITCH + 0.05, 1.5 * PITCH, 0.05))
	for pair in [[a, b], [b, d], [d, c], [c, a]]:
		kept.append_array([int(pair[0]), int(pair[1]), centre])

	var vertices: Array = []
	for point in positions:
		vertices.append([point.x, point.y, point.z])
	var faces: Array = []
	for t in range(kept.size() / 3):
		faces.append([kept[t * 3], kept[t * 3 + 1], kept[t * 3 + 2]])
	return {"vertices": vertices, "faces": faces}


## What the worker would say the plate's edges are: its four sides, each a
## straight edge sampled as its two ends.
func _plate_edge_registry() -> Array:
	var span := float(CELLS) * PITCH
	var corners := [
		[0.0, 0.0, 0.0], [span, 0.0, 0.0], [span, span, 0.0], [0.0, span, 0.0],
	]
	var registry: Array = []
	for i in range(4):
		var start: Array = corners[i]
		var end: Array = corners[(i + 1) % 4]
		registry.append({
			"id": i + 1, "kind": "straight",
			"start": start, "end": end, "polyline": [start, end],
		})
	return registry


## A box with two through holes, as the worker's edge list has it: the box's
## twelve straight edges plus the two hole rims, each rim a sampled circle.
func _box_with_holes_registry() -> Array:
	var box := _box()
	var positions: PackedVector3Array = box["positions"]
	var pairs := [
		[0, 1], [1, 2], [2, 3], [3, 0],
		[4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]
	var registry: Array = []
	for i in range(pairs.size()):
		var start: Array = _as_triple(positions[int(pairs[i][0])])
		var end: Array = _as_triple(positions[int(pairs[i][1])])
		registry.append({
			"id": i + 1, "kind": "straight",
			"start": start, "end": end, "polyline": [start, end],
		})
	for rim in range(2):
		var circle := _circle_polyline(Vector3(5.0, 5.0, 10.0 * float(rim)), 2.0, 12)
		registry.append({
			"id": pairs.size() + rim + 1, "kind": "circle",
			"start": circle[0], "end": circle[circle.size() - 1],
			"polyline": circle,
		})
	return registry


## `count` points along a quarter turn of radius 10 in the z=0 plane.
func _arc_polyline(count: int) -> Array:
	var points: Array = []
	for i in range(count):
		var angle := (PI * 0.5) * float(i) / float(count - 1)
		points.append([10.0 * cos(angle), 10.0 * sin(angle), 0.0])
	return points


## A closed circle as a polyline: `segments` chords, first point repeated last.
func _circle_polyline(centre: Vector3, radius: float, segments: int) -> Array:
	var points: Array = []
	for i in range(segments + 1):
		var angle := TAU * float(i) / float(segments)
		points.append([
			centre.x + radius * cos(angle), centre.y + radius * sin(angle), centre.z,
		])
	return points


func _as_triple(point: Vector3) -> Array:
	return [point.x, point.y, point.z]


func _as_vector3(triple: Array) -> Vector3:
	return Vector3(float(triple[0]), float(triple[1]), float(triple[2]))
