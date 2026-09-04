extends SceneTree
## Does the evaluated solid run into a reference mesh?
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## The fixture is a board built here with runtime CSG and baked — no mesh
## binary in the repository — and posed by a non-identity transform, so every
## reported point has to survive the round trip from the reference's own frame
## to the posed world and back. The "DSL solid" is a mesh dictionary in exactly
## the shape the worker emits ({vertices, faces}), built the same way, because
## the panel's own path from an evaluation to this check carries nothing else.
##
## Four solids are checked against ONE board, each of which breaks a different
## shortcut:
##
##   THROUGH   a shell on legs whose boss goes clean through the board. The
##             crossings are at the board's two faces and the run between them
##             is the board's own thickness, so both the point and the depth
##             are numbers the fixture wrote rather than numbers this code
##             recomputed.
##   CLEAR     the same shell lifted 0.1 mm. Nothing touches, and a check that
##             cannot report zero is useless: a false alarm on every
##             evaluation is a report an agent learns to skip.
##   SLIVER    a bar crossing the board with a 0.2 mm overlap and NO vertex of
##             either body inside the other. A vertex-in-body test — the
##             obvious implementation — reports nothing here. The suite proves
##             the premise numerically before it asserts the answer.
##   BURIED    a small cube wholly inside the board's material. It crosses no
##             face at all in either direction, and only ray parity sees it.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const MeshGauge := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")
const GeometryChecks := preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")

## Board: 80 x 60 in X and Y, 1.6 thick in Z, centred on its own origin, so its
## faces are at z = -0.8 and z = +0.8.
const BOARD := Vector3(80.0, 60.0, 1.6)
const BOARD_NODE := "board"
const BOARD_REFERENCE := "board"

## Where the board is posed in the world. Translation only: the arithmetic in
## every expectation below stays readable, and world-vs-local is still a real
## distinction that a wrong answer cannot pass by accident.
const POSE_ORIGIN := Vector3(100.0, 200.0, 300.0)

## The shell: a lid at z = 3..8 standing over the board on one boss.
const BOSS_CENTRE_XY := Vector2(10.0, 10.0)
const BOSS_RADIUS := 2.0
const BOSS_FACETS := 32
const LID := Vector3(20.0, 20.0, 5.0)
const LID_CENTRE_Z := 5.5
## The through boss reaches below the board's underside; the clear one stops
## 0.1 mm above its top face.
const BOSS_THROUGH_BOTTOM_Z := -1.2
const BOSS_CLEAR_BOTTOM_Z := 0.9

## The sliver bar: wider than the board in X, narrow in Y, overlapping the
## board's top face by 0.2 mm. Every one of its own corners is outside the
## board (|x| > 40) and every corner of the board is outside it (|y| > 5).
const BAR := Vector3(200.0, 10.0, 0.9)
const BAR_CENTRE_Z := 1.05
const SLIVER_OVERLAP_MM := 0.2

## The buried cube: 0.5 mm on a side at the board's centre, inside 1.6 mm of
## material.
const BURIED_EDGE := 0.5

const POINT_TOLERANCE_MM := 0.05

var _pass: int = 0
var _fail: int = 0
var _pose: Transform3D = Transform3D.IDENTITY


func _init() -> void:
	print("=== CAD Interference Test (solid vs reference) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_pose = Transform3D(Basis.IDENTITY, POSE_ORIGIN)

	var board: ArrayMesh = await _bake_board()
	check("fixture: the board baked to a mesh",
			board != null and board.get_surface_count() > 0,
			"bake_static_mesh returned nothing")

	var gauge := MeshGauge.new()
	gauge.name = "MeshGauge"
	root.add_child(gauge)
	var checks: RefCounted = GeometryChecks.new()
	checks.attach(root)
	await process_frame

	var built: int = gauge.build([{
		"mesh": board,
		"transform": _pose,
		"node": BOARD_NODE,
		"reference": BOARD_REFERENCE,
	}], "interference-fixture|v1")
	check("fixture: the posed board became one reference collider",
			built == 1, "built %d colliders" % built)
	checks.set_records([{
		"name": BOARD_REFERENCE,
		"pose": _pose,
		"world_aabb": _board_world_box(),
		"parts": [{
			"mesh": board,
			"transform": Transform3D.IDENTITY,
			"node_path": BOARD_NODE,
			"node": BOARD_NODE,
		}],
	}])

	await _check_solid_build(checks)
	await _check_through(gauge, checks)
	await _check_clear(gauge, checks)
	await _check_sliver(gauge, checks)
	await _check_buried(gauge, checks)
	await _check_scoping(gauge, checks)


# ---------------------------------------------------------------------------
# The solid's collider
# ---------------------------------------------------------------------------

func _check_solid_build(checks: RefCounted) -> void:
	var shell: Dictionary = await _shell_mesh(BOSS_THROUGH_BOTTOM_Z)
	check("fixture: the shell arrived as worker mesh data",
			(shell.get("vertices", []) as Array).size() > 0
				and (shell.get("faces", []) as Array).size() > 0,
			"vertices = %d, faces = %d" % [
				(shell.get("vertices", []) as Array).size(),
				(shell.get("faces", []) as Array).size()])

	var triangles: int = int(checks.build_solid(shell))
	check("solid: the evaluated mesh became a collider",
			triangles > 0, "built %d triangles" % triangles)
	check("solid: its edges were de-duplicated, not counted per triangle",
			int(checks.get_solid_edge_count()) > 0
				and int(checks.get_solid_edge_count()) < triangles * 3,
			"%d edges for %d triangles" % [
				int(checks.get_solid_edge_count()), triangles])

	# The solid changes on every evaluation and has no path to key a cache on,
	# so an identical mesh must STILL rebuild. A returned triangle count cannot
	# tell a rebuild from a cache hit; the generation can.
	var generation: int = int(checks.get_solid_generation())
	checks.build_solid(shell)
	checks.build_solid(shell)
	check("solid: the collider is rebuilt on every evaluation, never cached",
			int(checks.get_solid_generation()) == generation + 2,
			"generation %d -> %d" % [generation, int(checks.get_solid_generation())])

	check("solid: an evaluation with no geometry builds nothing",
			int(checks.build_solid({})) == 0,
			"an empty mesh produced a collider")


# ---------------------------------------------------------------------------
# THROUGH — a boss clean through the board
# ---------------------------------------------------------------------------

func _check_through(gauge: Node, checks: RefCounted) -> void:
	var report: Dictionary = await _check(gauge, checks, BOSS_THROUGH_BOTTOM_Z)
	var pairs: Array = report.get("pairs", []) as Array
	check("through: the check ran and found the collision",
			bool(report.get("checked", false)) and int(report.get("count", 0)) > 0,
			"report = %s" % str(report))
	check("through: the offender is named by reference and node",
			pairs.size() == 1
				and str((pairs[0] as Dictionary).get("reference", "")) == BOARD_REFERENCE
				and str((pairs[0] as Dictionary).get("node", "")) == BOARD_NODE,
			"pairs = %s" % str(pairs))

	# TRUTH: the boss's own vertical edges lie on a circle of radius 2 about
	# (10, 10) and the board's faces are at z = +/-0.8 in the board's frame.
	# Every crossing is therefore on one of those two rings, and the fixture
	# wrote all three numbers.
	var on_truth := 0
	var frames_agree := true
	var points: Array = []
	if pairs.size() > 0:
		points = (pairs[0] as Dictionary).get("points_mm", []) as Array
	for entry in points:
		var point: Dictionary = entry
		var world := _as_vector(point.get("world", []))
		var local := _as_vector(point.get("local", []))
		if (_pose * local).distance_to(world) > 1e-4:
			frames_agree = false
		var radius := Vector2(local.x, local.y).distance_to(BOSS_CENTRE_XY)
		var on_a_face: bool = absf(absf(local.z) - BOARD.z * 0.5) < POINT_TOLERANCE_MM
		if on_a_face and absf(radius - BOSS_RADIUS) < POINT_TOLERANCE_MM:
			on_truth += 1
	check("through: a crossing lands on the boss circle at a board face, to 0.05 mm",
			on_truth > 0,
			"%d of %d reported points matched the truth" % [on_truth, points.size()])
	check("through: every point is reported in BOTH frames, and they agree",
			points.size() > 0 and frames_agree,
			"points = %s" % str(points))

	var penetration := 0.0
	if pairs.size() > 0:
		penetration = float((pairs[0] as Dictionary).get("penetration_mm", 0.0))
	check("through: the penetration is the board's own thickness",
			absf(penetration - BOARD.z) < POINT_TOLERANCE_MM,
			"penetration_mm = %f, expected %f" % [penetration, BOARD.z])

	check("through: the report says nothing was skipped",
			str(report.get("sampling", "")).begins_with("none"),
			"sampling = %s" % str(report.get("sampling", "")))
	check("through: the crossings counted are at least the pairs reported",
			int(report.get("point_count", 0)) >= int(report.get("count", 0)),
			"point_count = %d, count = %d" % [
				int(report.get("point_count", 0)), int(report.get("count", 0))])

	var line: String = str(checks.status_line(report))
	check("through: the status line names the first offender",
			line.contains(BOARD_REFERENCE) and line.contains(BOARD_NODE),
			"status line = '%s'" % line)


# ---------------------------------------------------------------------------
# CLEAR — the same shell, 0.1 mm off the board
# ---------------------------------------------------------------------------

func _check_clear(gauge: Node, checks: RefCounted) -> void:
	var report: Dictionary = await _check(gauge, checks, BOSS_CLEAR_BOTTOM_Z)
	check("clear: a boss standing 0.1 mm off the board reports nothing",
			int(report.get("count", 0)) == 0
				and int(report.get("point_count", 0)) == 0,
			"report = %s" % str(report))
	check("clear: and that is an ANSWER, not a refusal to look",
			bool(report.get("checked", false)),
			"checked = %s" % str(report.get("checked", null)))
	check("clear: the previous evaluation's points did not survive into it",
			(report.get("pairs", []) as Array).is_empty(),
			"pairs = %s" % str(report.get("pairs", [])))


# ---------------------------------------------------------------------------
# SLIVER — a 0.2 mm overlap with no vertex inside either body
# ---------------------------------------------------------------------------

func _check_sliver(gauge: Node, checks: RefCounted) -> void:
	# The premise first: this fixture is only interesting if a vertex test
	# would miss it, and that is arithmetic the suite can do out loud.
	var bar_corner_inside := absf(BAR.x * 0.5) <= BOARD.x * 0.5
	var board_corner_inside := absf(BOARD.y * 0.5) <= BAR.y * 0.5
	var overlap := (BOARD.z * 0.5) - (BAR_CENTRE_Z - BAR.z * 0.5)
	check("sliver: the fixture overlaps by 0.2 mm with NO vertex inside either body",
			not bar_corner_inside and not board_corner_inside
				and absf(overlap - SLIVER_OVERLAP_MM) < 1e-6,
			"bar corner inside = %s, board corner inside = %s, overlap = %f" % [
				str(bar_corner_inside), str(board_corner_inside), overlap])

	var bar: Dictionary = await _bar_mesh()
	checks.build_solid(bar)
	var report: Dictionary = await _submit(gauge, checks, "", "")
	var pairs: Array = report.get("pairs", []) as Array
	var named := not pairs.is_empty() \
		and str((pairs[0] as Dictionary).get("node", "")) == BOARD_NODE
	check("sliver: the 0.2 mm overlap is still reported, on the board's node",
			int(report.get("count", 0)) > 0 and named,
			"report = %s" % str(report))


# ---------------------------------------------------------------------------
# BURIED — containment, which crosses no face at all
# ---------------------------------------------------------------------------

func _check_buried(gauge: Node, checks: RefCounted) -> void:
	var cube: Dictionary = await _buried_mesh()
	checks.build_solid(cube)
	var report: Dictionary = await _submit(gauge, checks, "", "")
	var pairs: Array = report.get("pairs", []) as Array
	check("buried: a solid wholly inside the board is reported by parity",
			int(report.get("count", 0)) > 0,
			"report = %s" % str(report))
	check("buried: and it says WHY — containment, not a crossing",
			not pairs.is_empty()
				and str((pairs[0] as Dictionary).get("note", "")).contains("inside"),
			"pairs = %s" % str(pairs))


# ---------------------------------------------------------------------------
# Scoping
# ---------------------------------------------------------------------------

func _check_scoping(gauge: Node, checks: RefCounted) -> void:
	var shell: Dictionary = await _shell_mesh(BOSS_THROUGH_BOTTOM_Z)
	checks.build_solid(shell)
	var named: Dictionary = await _submit(gauge, checks, BOARD_REFERENCE, BOARD_NODE)
	check("scope: the collision is still found when the right node is named",
			int(named.get("count", 0)) > 0, "report = %s" % str(named))

	checks.build_solid(shell)
	var other: Dictionary = await _submit(gauge, checks, "", "no-such-node")
	check("scope: a node filter that matches nothing reports nothing",
			int(other.get("count", 0)) == 0, "report = %s" % str(other))


# ---------------------------------------------------------------------------
# Driving the check
# ---------------------------------------------------------------------------

## Build the shell at the given boss depth and run the whole check on it, the
## way the panel does: rebuild the solid, then ask inside a physics step.
func _check(gauge: Node, checks: RefCounted, boss_bottom_z: float) -> Dictionary:
	var shell: Dictionary = await _shell_mesh(boss_bottom_z)
	checks.build_solid(shell)
	return await _submit(gauge, checks, "", "")


## The real submission path: mesh_gauge owns the physics step and hands the
## job back to the module, so this is the same call the panel makes.
func _submit(
	gauge: Node,
	checks: RefCounted,
	reference: String,
	node_filter: String
) -> Dictionary:
	var mask: int = int(gauge.mask_for(reference)) if not reference.is_empty() \
		else int(MeshGauge.ALL_LAYERS)
	return await gauge.submit("interference", {
		"module": checks,
		"mask": mask,
		"reference": reference,
		"node": node_filter,
	})


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

func _bake_board() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Board"
	var plate := CSGBox3D.new()
	plate.size = BOARD
	combiner.add_child(plate)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


## The shell: a lid over the board on one boss whose underside sits at
## `boss_bottom_z` in the BOARD's frame. Returned posed into the world, which
## is where an evaluated solid always lives.
func _shell_mesh(boss_bottom_z: float) -> Dictionary:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Shell"
	var lid := CSGBox3D.new()
	lid.size = LID
	lid.position = Vector3(BOSS_CENTRE_XY.x, BOSS_CENTRE_XY.y, LID_CENTRE_Z)
	combiner.add_child(lid)

	var boss := CSGCylinder3D.new()
	boss.radius = BOSS_RADIUS
	boss.sides = BOSS_FACETS
	boss.smooth_faces = false
	var top: float = LID_CENTRE_Z - LID.z * 0.5
	boss.height = top - boss_bottom_z
	# A CSG cylinder runs along its own +Y; a quarter turn about X takes that
	# to +Z, which is the CAD world's up and the axis the boss is drilled on.
	boss.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	boss.position = Vector3(
		BOSS_CENTRE_XY.x, BOSS_CENTRE_XY.y, (top + boss_bottom_z) * 0.5)
	combiner.add_child(boss)

	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return _mesh_data(baked, _pose)


## The sliver bar: wider than the board, narrow in Y, its underside 0.2 mm
## below the board's top face.
func _bar_mesh() -> Dictionary:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Bar"
	var bar := CSGBox3D.new()
	bar.size = BAR
	bar.position = Vector3(0.0, 0.0, BAR_CENTRE_Z)
	combiner.add_child(bar)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return _mesh_data(baked, _pose)


## A cube small enough to sit inside the board's 1.6 mm of material.
func _buried_mesh() -> Dictionary:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Buried"
	var cube := CSGBox3D.new()
	cube.size = Vector3(BURIED_EDGE, BURIED_EDGE, BURIED_EDGE)
	combiner.add_child(cube)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return _mesh_data(baked, _pose)


## An ArrayMesh in the shape the CAD worker emits: {vertices: [[x, y, z], ...],
## faces: [[i, j, k], ...]}, transformed into the world by `xform`.
func _mesh_data(mesh: ArrayMesh, xform: Transform3D) -> Dictionary:
	var vertices: Array = []
	var faces: Array = []
	for surface in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var raw: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var offset := vertices.size()
		for point in raw:
			var world: Vector3 = xform * point
			vertices.append([world.x, world.y, world.z])
		var indices := PackedInt32Array()
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
			indices = arrays[Mesh.ARRAY_INDEX]
		if indices.size() > 0:
			var i := 0
			while i + 2 < indices.size():
				faces.append([
					offset + indices[i], offset + indices[i + 1], offset + indices[i + 2]])
				i += 3
		else:
			var j := 0
			while j + 2 < raw.size():
				faces.append([offset + j, offset + j + 1, offset + j + 2])
				j += 3
	return {"vertices": vertices, "faces": faces}


## The board's world bounds, as the panel reports them on a reference record.
func _board_world_box() -> AABB:
	return AABB(_pose * (-BOARD * 0.5), BOARD)


func _as_vector(raw: Variant) -> Vector3:
	if raw is Array and (raw as Array).size() >= 3:
		var values: Array = raw
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3(1e9, 1e9, 1e9)


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass += 1
		print("  PASS  %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail != "" else ""])
