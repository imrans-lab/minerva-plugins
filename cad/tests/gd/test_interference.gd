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
##   FLUSH     an open-topped cavity whose floor IS the board's underside, so
##             the board rests on it. Nothing overlaps, and the parity probe
##             that decides containment starts on the contact plane the two
##             bodies share unless the check moves it off.
##   PIN       a washer floating inside that cavity with a locating pin
##             standing through its hole. Every vertex the washer has is on a
##             rim of that hole and the probe inset is twice the rim's width,
##             so EVERY candidate lands in the hole — inside the pin, in no
##             material of the washer at all. A probe that is not verified to
##             be inside its own body reports the washer as buried in the
##             shell, which is the phantom the flush fixture's sibling exists
##             to catch.
##
## The board is posed by a TURNED transform — a yaw about the CAD world's up
## axis and a lean about x, plus a translation — so nothing here can pass by
## treating the pose as a translation or the hole axis as world z. Every
## expectation below is written in the board's own frame or as a length, both
## of which the pose leaves alone.
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

## Where the board is posed in the world, and how far it is turned: a yaw
## about +z (the CAD world's up) and a lean about +x. Every expectation is
## either in the board's own frame or a length, so the turn costs no
## arithmetic and a check that drops the basis fails all of them.
const POSE_ORIGIN := Vector3(100.0, 200.0, 300.0)
const POSE_YAW_DEG := 30.0
const POSE_LEAN_DEG := 20.0

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

## A box big enough to swallow the whole board: containment the other way
## round, which no edge crossing can see either.
const ENCLOSING := Vector3(120.0, 100.0, 12.0)

## The cavity: an open-topped shell whose floor's TOP face is the board's
## underside, so the board rests on it with no overlap at all. Walls 5 mm
## thick leave the board 5 mm of air on every side; the inner box runs past
## the outer one's top face, which is what leaves the shell open.
const CAVITY_OUTER := Vector3(100.0, 80.0, 20.0)
const CAVITY_INNER := Vector3(90.0, 70.0, 21.0)
const CAVITY_FLOOR_MM := 2.0
## The floor's top face, in the board's own frame: the board's underside.
const CAVITY_FLOOR_TOP_Z := -BOARD.z * 0.5

## The washer: a disc with a mounting hole big enough that its 2 mm rim is the
## ONLY place a vertex can be. It floats clear of the cavity floor, so nothing
## in this fixture touches anything and the answer rests on the probe alone.
const WASHER_OUTER_R := 22.0
const WASHER_INNER_R := 20.0
const WASHER_THICKNESS := 1.6
const WASHER_LIFT_MM := 0.2
const WASHER_REFERENCE := "washer"
const WASHER_NODE := "washer"
## The locating pin, standing on the cavity floor through the washer's hole
## with half a millimetre of air all round it.
const PIN_CLEARANCE_MM := 0.5
const PIN_R := WASHER_INNER_R - PIN_CLEARANCE_MM
const PIN_TOP_Z := 5.0
## Facets on every turned surface here. Fine enough that the polygon a cutter
## leaves and the polygon a pin presents still clear each other: at 64 sides a
## chord lies 0.12 percent inside its circle, two orders below the clearance.
const ROUND_FACETS := 64

## The pane the stand-in panel builds so the markers have somewhere to land.
## It is the first of panel_measurement.gd's MESH_ROOT_PATHS verbatim: the
## module looks for exactly these names and a typo here would silently pass.
const MESH_ROOT_PATH := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/TopView/SubViewport/MeshRoot"

## The neighbour: a solid pin FILLING the washer's hole as a second node of the
## SAME reference, with the same half-millimetre of air round it. Its material
## is where every probe the washer offers lands, so it is exactly the body that
## must not be allowed to vouch for the washer.
const NEIGHBOUR_PIN_R := WASHER_INNER_R - PIN_CLEARANCE_MM
const NEIGHBOUR_PIN_HEIGHT := 6.0
const RING_NODE := "Assembly/Ring"
const PIN_NODE := "Assembly/Pin"

## The layered stack. A parity ray leaves the cube from INSIDE the stack, so
## it only ever crosses the plates on ONE side of it — half the stack, two
## faces each. With the cube in the middle gap of 80 plates that is 39 plates
## above it and 78 crossings, more than mesh_gauge's own crossing budget (64),
## so the parity question cannot be answered at all. The span is wide enough
## that a ray tilted by the fixture's pose reaches the top of the stack
## instead of leaving through its side and finishing early.
const STACK_PLATES := 80
const STACK_PLATE_MM := 0.2
const STACK_PITCH_MM := 0.4
const STACK_SPAN := 60.0
## The plate no fixed probe step can be taken inside: four microns thick,
## which is less than the module's 0.005 mm ceiling and more than the 0.002 mm
## sphere its parity probe places.
const THIN_PLATE_MM := 0.004
const THIN_REFERENCE := "shim"
const THIN_NODE := "Assembly/Shim"
## The column through it: square, well clear of the plate's edges, and long
## enough that both its ends are outside the plate.
const COLUMN_MM := 4.0
const COLUMN_HEIGHT_MM := 6.0
## The tetrahedron over the same plate: its apex sits INSIDE the plate's four
## microns (the plate spans -0.002 to +0.002 in its own frame) and its base is
## well above, so every edge crossing the plate is leaving it.
##
## The base is NARROW on purpose. The probe steps along the EDGE, so a squat
## tetrahedron's oblique edges travel only a fraction of their length in z and
## a step of the full ceiling would still land inside the plate — the fixture
## would pass whether or not the run was measured backwards. At 0.5 mm across
## and 5 mm tall each edge is within half a degree of the plate's normal, so a
## ceiling-sized step lands 5 microns below a 4 micron plate: only a step
## measured from the material BEHIND the crossing stays inside it.
## Well off the plate's own triangulation: a baked box splits each face into
## two triangles across a diagonal through its centre, and a tetrahedron
## sitting on that diagonal is reported by the OTHER direction of the check —
## the plate's own edge cast into the solid — whether or not the probe here
## works at all. Placed here, the only thing that can report it is a kept
## crossing of its own edges.
const TETRA_CENTRE_XY := Vector2(13.0, 4.0)
const TETRA_APEX_Z := 0.0
const TETRA_TOP_Z := 5.0
const TETRA_SPAN_MM := 0.5

## The two identical blocks a buried cube is inside at the same time.
const BLOCK_A := "block_a"
const BLOCK_B := "block_b"
const BLOCK_NODE := "Assembly/Block"

const STACK_A := "stack_a"
const STACK_B := "stack_b"
const STACK_NODE := "Assembly/Plates"
## The cube parked in one gap: the gap is STACK_PITCH_MM - STACK_PLATE_MM =
## 0.2 mm tall and the cube is half of that, so it clears each plate by
## 0.05 mm — a thousand times the module's touch epsilon.
const GAP_CUBE_MM := 0.1
## Plate STACK_PLATES / 2 is centred on z = 0 (its top face at +0.1) and the
## next plate's underside is at +0.3; the middle of that gap is +0.2.
const GAP_CENTRE_Z := 0.2
const GAP_REFERENCE := "gap_cube"
const GAP_NODE := "Assembly/GapCube"

const POINT_TOLERANCE_MM := 0.05

var _pass: int = 0
var _fail: int = 0
var _pose: Transform3D = Transform3D.IDENTITY
## The reference records the panel would report for the board.
var _records: Array = []


func _init() -> void:
	print("=== CAD Interference Test (solid vs reference) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_pose = Transform3D(
		Basis(Vector3.BACK, deg_to_rad(POSE_YAW_DEG))
			* Basis(Vector3.RIGHT, deg_to_rad(POSE_LEAN_DEG)),
		POSE_ORIGIN)

	var board: ArrayMesh = await _bake_board()
	check("fixture: the board baked to a mesh",
			board != null and board.get_surface_count() > 0,
			"bake_static_mesh returned nothing")
	check("fixture: the pose TURNS the board as well as moving it, so a "
			+ "check that keeps only the translation cannot pass",
			not _pose.basis.is_equal_approx(Basis.IDENTITY)
				and absf(_pose.basis.determinant() - 1.0) < 1e-6,
			"basis = %s" % str(_pose.basis))

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
	_records = [{
		"name": BOARD_REFERENCE,
		"pose": _pose,
		"world_aabb": _board_world_box(),
		"parts": [{
			"mesh": board,
			"transform": Transform3D.IDENTITY,
			"node_path": BOARD_NODE,
			"node": BOARD_NODE,
		}],
	}]
	checks.set_records(_records)

	await _check_solid_build(checks)
	await _check_through(gauge, checks)
	await _check_clear(gauge, checks)
	await _check_sliver(gauge, checks)
	await _check_buried(gauge, checks)
	await _check_enclosed(gauge, checks)
	await _check_flush(gauge, checks)
	await _check_scoping(gauge, checks)
	await _check_supersession(gauge, checks)
	await _check_busy_refusal(gauge, checks)
	# From here on each check rebuilds the gauge and the records around its
	# own reference.
	await _check_thin_plate(gauge, checks)
	await _check_tetrahedron_in_thin_plate(gauge, checks)
	await _check_pin_through_hole(gauge, checks)
	await _check_undecidable_and_the_neighbouring_node(gauge, checks)
	await _check_layered_stack(gauge, checks)
	await _check_two_enclosing_references(gauge, checks)


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
# ENCLOSED — containment the other way round
# ---------------------------------------------------------------------------

func _check_enclosed(gauge: Node, checks: RefCounted) -> void:
	var box: Dictionary = await _enclosing_mesh()
	checks.build_solid(box)
	var report: Dictionary = await _submit(gauge, checks, "", "")
	var pairs: Array = report.get("pairs", []) as Array
	check("enclosed: a reference wholly inside the solid is reported by parity",
			int(report.get("count", 0)) > 0,
			"report = %s" % str(report))
	check("enclosed: and the note says which way round the containment is",
			not pairs.is_empty()
				and str((pairs[0] as Dictionary).get("note", ""))
					.contains("inside the solid"),
			"pairs = %s" % str(pairs))


# ---------------------------------------------------------------------------
# FLUSH — the designed contact, which must not read as containment
# ---------------------------------------------------------------------------

## A board sitting on the floor of its enclosure touches over a whole face.
## No edge crosses anything, so the check falls through to parity — and every
## vertex of the board's underside lies ON the floor, where a ray cast along
## that plane hits or misses by float luck. The answer this fixture must give
## is the one an agent can act on: nothing is wrong.
func _check_flush(gauge: Node, checks: RefCounted) -> void:
	var cavity: Dictionary = await _cavity_mesh()
	checks.build_solid(cavity)
	check("flush: the fixture really does ask the containment question — the "
			+ "board is inside the shell's bounds and its underside is the "
			+ "floor's top face",
			(checks.get_solid_bounds() as AABB).encloses(_board_world_box())
				and absf(CAVITY_FLOOR_TOP_Z + BOARD.z * 0.5) < 1e-9,
			"solid bounds = %s, board = %s" % [
				str(checks.get_solid_bounds()), str(_board_world_box())])

	var report: Dictionary = await _submit(gauge, checks, "", "")
	check("flush: a board resting on the cavity floor is a designed contact, "
			+ "not interference",
			bool(report.get("checked", false))
				and int(report.get("count", 0)) == 0
				and int(report.get("point_count", 0)) == 0,
			"report = %s" % str(report))


# ---------------------------------------------------------------------------
# A PLATE THINNER THAN THE PROBE STEP
# ---------------------------------------------------------------------------

## The crossing a fixed probe step steps clean over.
##
## Proving a crossing is a penetration and not a graze means finding material a
## short step off it — and a step taken at a FIXED distance walks straight
## through anything thinner than itself. A 0.004 mm plate is thinner than the
## module's own 0.005 mm ceiling, so both probes from a genuine crossing land
## in open air on either side of it, and a column driven clean through the
## plate reads as clean: no crossing kept, and neither body's box holds the
## other, so containment never runs either.
##
## THE FIXTURE IS THE SAME ONE-BOX-THROUGH-A-PLATE the through-boss case uses,
## at a thickness the probe cannot assume: the plate is 0.004 mm and the
## column is 4 mm square, so every side of the column crosses the plate's top
## and bottom faces squarely. The step has to be measured from the material
## that is actually there.
func _check_thin_plate(gauge: Node, checks: RefCounted) -> void:
	var plate: ArrayMesh = await _bake_thin_plate()
	var built: int = gauge.build([{
		"mesh": plate, "transform": _pose, "node": THIN_NODE,
		"reference": THIN_REFERENCE,
	}], "thin-plate-fixture|v1")
	var box := _posed_box(plate.get_aabb())
	_records = [{
		"name": THIN_REFERENCE,
		"pose": _pose,
		"world_aabb": box,
		"parts": [{"mesh": plate, "transform": Transform3D.IDENTITY,
			"node_path": THIN_NODE, "node": THIN_NODE}],
	}]
	checks.set_records(_records)
	checks.build_solid(await _column_mesh())

	check("thin plate: the fixture sits in the gap the fixed step left — "
			+ "thinner than the module's own probe ceiling and thicker than "
			+ "the sphere its parity probe places",
			built == 1
				and THIN_PLATE_MM < GeometryChecks.PENETRATION_PROBE_MM
				and THIN_PLATE_MM > GeometryChecks.PARITY_SPHERE_MM,
			"built=%d thickness=%f ceiling=%f sphere=%f" % [built,
				THIN_PLATE_MM, GeometryChecks.PENETRATION_PROBE_MM,
				GeometryChecks.PARITY_SPHERE_MM])

	var report: Dictionary = await _submit(gauge, checks, "", "")
	var pairs: Array = report.get("pairs", []) as Array
	var first: Dictionary = pairs[0] if not pairs.is_empty() else {}
	# A CROSSING, not containment: the column's edges go in one face of the
	# plate and out the other, which is the answer a stepped-over probe threw
	# away. Containment would have said so in its note.
	check("thin plate: a column driven through a 0.004 mm plate is reported "
			+ "as a crossing — the probe step is measured from the material "
			+ "that is there, not assumed",
			bool(report.get("checked", false))
				and int(report.get("count", 0)) == 1
				and str(first.get("node", "")) == THIN_NODE
				and int(first.get("point_count", 0)) >= 2
				and not str(first.get("note", "")).contains("inside"),
			"report = %s" % str(report))


## The other way an edge can meet a thin plate: only LEAVING it.
##
## A tetrahedron with one vertex inside the plate and the other three above it
## has edges that start in material and climb out. At the crossing, there is
## nothing ahead along the edge — it is leaving — so a run measured FORWARD
## alone finds no end to the material, keeps the full ceiling, and the
## backward probe lands under the plate rather than in it: a genuine
## penetration read as a graze. The run has to be measured on BOTH sides of
## the hit, and the step taken from the shorter one.
func _check_tetrahedron_in_thin_plate(gauge: Node, checks: RefCounted) -> void:
	checks.build_solid(await _tetrahedron_mesh())
	var report: Dictionary = await _submit(gauge, checks, "", "")
	var pairs: Array = report.get("pairs", []) as Array
	var first: Dictionary = pairs[0] if not pairs.is_empty() else {}
	# ALL THREE edges of the apex, and the count is the discriminator. Which
	# way round an edge is cast is the mesh's business, not the check's: an
	# edge cast DOWNWARD into the plate finds its far face ahead and is kept
	# even by a run measured forward only, while the same edge cast upward
	# finds nothing ahead, keeps the ceiling, and steps clean through a four
	# micron plate. Measuring both sides makes the answer the same either way
	# — three edges leave the apex, three crossings are kept — so a count of
	# three is the thing a forward-only measurement cannot produce.
	check("thin plate: a tetrahedron whose one buried vertex sits inside the "
			+ "plate is interference too, on ALL THREE of its edges — the run "
			+ "is measured on both sides of a crossing, not only ahead of it",
			bool(report.get("checked", false))
				and int(report.get("count", 0)) == 1
				and str(first.get("node", "")) == THIN_NODE
				and int(first.get("point_count", 0)) == 3
				and not str(first.get("note", "")).contains("inside"),
			"report = %s" % str(report))


## The tetrahedron: a wide base ABOVE the plate and a single apex poking down
## into its material, so every edge that meets the plate is on its way out.
func _tetrahedron_mesh() -> Dictionary:
	var here := TETRA_CENTRE_XY
	var apex := Vector3(here.x, here.y, TETRA_APEX_Z)
	var reach := TETRA_SPAN_MM
	var top := TETRA_TOP_Z
	var corners: Array = [
		apex,
		Vector3(here.x - reach, here.y - reach * 0.5, top),
		Vector3(here.x + reach, here.y - reach * 0.5, top),
		Vector3(here.x, here.y + reach, top),
	]
	var vertices: Array = []
	var faces: Array = []
	for corner in corners:
		var world: Vector3 = _pose * (corner as Vector3)
		vertices.append([world.x, world.y, world.z])
	for face in [[0, 1, 2], [0, 2, 3], [0, 3, 1], [1, 3, 2]]:
		faces.append(face)
	return {"vertices": vertices, "faces": faces}


## The plate: as wide as the board and THIN_PLATE_MM thick.
func _bake_thin_plate() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "ThinPlate"
	var plate := CSGBox3D.new()
	plate.size = Vector3(BOARD.x, BOARD.y, THIN_PLATE_MM)
	combiner.add_child(plate)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


## The column: a square post driven clean through the plate, well clear of its
## edges, so every crossing it makes is through the plate's faces.
func _column_mesh() -> Dictionary:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Column"
	var post := CSGBox3D.new()
	post.size = Vector3(COLUMN_MM, COLUMN_MM, COLUMN_HEIGHT_MM)
	combiner.add_child(post)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return _mesh_data(baked, _pose)


# ---------------------------------------------------------------------------
# PIN — the probe that must not answer for a body it is not inside
# ---------------------------------------------------------------------------

## A washer inside a shell, with a locating pin standing through its mounting
## hole: nothing touches, nothing crosses, so the verdict is the parity
## probe's alone. The fixture is built so that EVERY candidate probe is wrong:
## every vertex of a washer is on one of the two rims of its hole, and the
## module insets a candidate towards the body's centre by a quarter of the
## body's smallest world extent — here twice the rim's width — so every one of
## them lands in the hole, which is where the pin is. A probe that is not
## verified to lie inside its OWN body therefore reads "this node lies
## entirely inside the solid" about a washer that is merely threaded onto a
## pin, and the assertion below is 0.
func _check_pin_through_hole(gauge: Node, checks: RefCounted) -> void:
	var washer: ArrayMesh = await _bake_washer()
	var built: int = gauge.build([{
		"mesh": washer,
		"transform": _pose,
		"node": WASHER_NODE,
		"reference": WASHER_REFERENCE,
	}], "pin-fixture|v1")
	var box := _posed_box(washer.get_aabb())
	_records = [{
		"name": WASHER_REFERENCE,
		"pose": _pose,
		"world_aabb": box,
		"parts": [{
			"mesh": washer,
			"transform": Transform3D.IDENTITY,
			"node_path": WASHER_NODE,
			"node": WASHER_NODE,
		}],
	}]
	checks.set_records(_records)
	checks.build_solid(await _cavity_mesh(true))

	# The premise, in the module's own numbers: the inset step is wider than
	# the rim, and the washer is inside the shell's bounds — so the question
	# really is asked, and every vertex-derived probe really does land in the
	# hole rather than in the washer.
	var step: float = minf(box.size.x, minf(box.size.y, box.size.z)) \
		* GeometryChecks.PROBE_INSET_FRACTION
	check("pin: the fixture offers no probe that is inside the washer — its "
			+ "rim is 2.0 mm wide and the module insets by %.2f mm" % step,
			built == 1
				and step > WASHER_OUTER_R - WASHER_INNER_R
				and (checks.get_solid_bounds() as AABB).encloses(box),
			"built=%d step=%.3f solid bounds=%s washer=%s" % [
				built, step, str(checks.get_solid_bounds()), str(box)])

	var report: Dictionary = await _submit(gauge, checks, "", "")
	var undecided: Array = report.get("undecidable", []) as Array
	check("pin: a washer threaded onto a locating pin with 0.5 mm of air all "
			+ "round it is not reported as interference — and, having offered "
			+ "no probe of its own, comes back UNDECIDED rather than clean",
			bool(report.get("checked", false))
				and int(report.get("count", 0)) == 0
				and (report.get("pairs", []) as Array).is_empty()
				and undecided.size() == 1
				and str((undecided[0] as Dictionary).get("node", "")) == WASHER_NODE,
			"report = %s" % str(report))


# ---------------------------------------------------------------------------
# SUPERSESSION — two overlapping requests, one painter
# ---------------------------------------------------------------------------

## The module holds ONE solid collider and one marker set, so two checks in
## flight would answer each other's geometry — and, worse, a superseded check
## finishing late would repaint the crosses a newer clean evaluation had just
## cleared. The second request is therefore REFUSED while the first still
## holds the geometry, and the first, having been overtaken, may not paint.
##
## The stand-in panel is the smallest thing the module's panel contract
## accepts: the four accessors it reads and one pane for the markers. A real
## CADPanel would drag the whole scene, the worker IPC and the annotation host
## in for a question none of them take part in.
func _check_supersession(gauge: Node, checks: RefCounted) -> void:
	var through: Dictionary = await _shell_mesh(BOSS_THROUGH_BOTTOM_Z)
	var clear: Dictionary = await _shell_mesh(BOSS_CLEAR_BOTTOM_Z)
	var panel := _stand_in_panel(gauge)
	var mesh_root: Node = panel.get_node_or_null(MESH_ROOT_PATH)
	var replies: Array = []

	# A goes first and is NOT awaited: it is still waiting for its physics
	# step when B and then C arrive. B is displaced by C — one place in the
	# queue, and the newest document is the one worth checking — and C is the
	# evaluation that must end up measured and painted. Its solid INTERFERES,
	# so "painted" is a marker on screen and not the absence of one.
	panel.mesh_data = clear
	_collect(checks, panel, replies)
	panel.mesh_data = clear
	_collect(checks, panel, replies)
	panel.mesh_data = through
	_collect(checks, panel, replies)

	# Sample the markers when the first two replies have landed: if the
	# check that was running painted, or the displaced one did, the crosses
	# are on screen right here — an end-state assertion could not tell that
	# apart from C having painted them afterwards.
	var painted_before_the_newest := false
	var sampled := false
	for _frame in range(900):
		if replies.size() >= 2 and not sampled:
			sampled = true
			painted_before_the_newest = mesh_root != null \
				and mesh_root.get_node_or_null(GeometryChecks.MARKER_NODE_NAME) != null
		if replies.size() >= 3:
			break
		await process_frame

	var running := {}
	var displaced := {}
	var newest := {}
	for entry in replies:
		var reply: Dictionary = entry
		if int(reply.get("count", 0)) > 0:
			newest = reply
		elif bool(reply.get("checked", false)):
			running = reply
		else:
			displaced = reply

	check("queue: an evaluation arriving while a check runs is QUEUED, never "
			+ "refused — all three replies land, the one that was running "
			+ "measures its own document, and the NEWEST measures too",
			replies.size() == 3
				and bool(running.get("checked", false))
				and int(running.get("count", 0)) == 0
				and bool(newest.get("checked", false))
				and int(newest.get("count", 0)) > 0
				and not bool(newest.get("busy", false))
				and not bool(displaced.get("busy", false)),
			"replies = %s" % str(replies))
	check("queue: the one displaced in the queue stands down as superseded "
			+ "and measures nothing, and the newest is not superseded",
			bool(displaced.get("superseded", false))
				and not bool(displaced.get("checked", true))
				and int(displaced.get("count", -1)) == 0
				and bool(running.get("superseded", false))
				and not bool(newest.get("superseded", false)),
			"displaced = %s, running = %s, newest = %s" % [
				str(displaced), str(running.get("superseded", null)),
				str(newest.get("superseded", null))])
	check("queue: neither the overtaken check nor the displaced one painted",
			sampled and not painted_before_the_newest,
			"sampled = %s, painted = %s" % [
				str(sampled), str(painted_before_the_newest)])
	check("queue: the pane ends up showing the NEWEST evaluation's answer — "
			+ "its crossings, painted by the check that queued for them",
			mesh_root != null
				and mesh_root.get_node_or_null(GeometryChecks.MARKER_NODE_NAME) != null,
			"no marker survived the newest evaluation's own check")

	panel.queue_free()


# ---------------------------------------------------------------------------
# UNDECIDABLE — and the neighbour that must not answer for a node
# ---------------------------------------------------------------------------

## One fixture, two defects it is the only witness to.
##
## A washer and a locating pin, TWO NODES OF ONE REFERENCE, both swallowed by a
## solid block. The washer's rim is narrower than the module's own inset step,
## so every probe it offers lands in its hole — which is the PIN's material.
##
##   The neighbour must not vouch. A containment test scoped to the reference
##   and not to the node finds pin material under the probe and reports the
##   WASHER as buried in the solid, which is a claim about a body no probe
##   ever got inside.
##
##   A rejected probe is not a clean answer. With no probe of its own, the
##   washer's containment is UNDECIDED, and the report has to say so: the
##   washer really is inside the block here, so reporting nothing would be
##   reporting the wrong answer.
##
## The pin, which does offer probes inside itself, is still reported — the
## module answers what it can prove.
func _check_undecidable_and_the_neighbouring_node(gauge: Node, checks: RefCounted) -> void:
	var ring: ArrayMesh = await _bake_washer()
	var pin: ArrayMesh = await _bake_neighbour_pin()
	var built: int = gauge.build([
		{"mesh": ring, "transform": _pose, "node": RING_NODE,
			"reference": WASHER_REFERENCE},
		{"mesh": pin, "transform": _pose, "node": PIN_NODE,
			"reference": WASHER_REFERENCE},
	], "neighbour-fixture|v1")
	var ring_box := _posed_box(ring.get_aabb())
	_records = [{
		"name": WASHER_REFERENCE,
		"pose": _pose,
		"world_aabb": _posed_box(ring.get_aabb().merge(pin.get_aabb())),
		"parts": [
			{"mesh": ring, "transform": Transform3D.IDENTITY,
				"node_path": RING_NODE, "node": RING_NODE},
			{"mesh": pin, "transform": Transform3D.IDENTITY,
				"node_path": PIN_NODE, "node": PIN_NODE},
		],
	}]
	checks.set_records(_records)
	checks.build_solid(await _enclosing_mesh())

	var step: float = minf(ring_box.size.x, minf(ring_box.size.y, ring_box.size.z)) \
		* GeometryChecks.PROBE_INSET_FRACTION
	check(("neighbour: the fixture is two nodes of ONE reference, the washer "
			+ "wholly inside the block, and its %.2f mm inset step is wider "
			+ "than its 2.0 mm rim") % step,
			built == 2 and step > WASHER_OUTER_R - WASHER_INNER_R
				and (checks.get_solid_bounds() as AABB).encloses(ring_box),
			"built=%d step=%.3f bounds=%s ring=%s" % [built, step,
				str(checks.get_solid_bounds()), str(ring_box)])

	var report: Dictionary = await _submit(gauge, checks, "", "")
	var named := {}
	for entry in report.get("pairs", []):
		named[str((entry as Dictionary).get("node", ""))] = true
	check("neighbour: the pin's material does not vouch for the washer — no "
			+ "pair claims the washer lies inside the solid",
			bool(report.get("checked", false)) and not named.has(RING_NODE),
			"pairs = %s" % str(named.keys()))

	var undecided: Array = report.get("undecidable", []) as Array
	var about_ring := {}
	for entry in undecided:
		if str((entry as Dictionary).get("node", "")) == RING_NODE:
			about_ring = entry
	check("undecidable: the washer is reported as UNDECIDED with a reason, "
			+ "not left to read as clean",
			not about_ring.is_empty()
				and str(about_ring.get("reason", "")).length() > 20
				and str(about_ring.get("reference", "")) == WASHER_REFERENCE,
			"undecidable = %s" % str(undecided))

	check("undecidable: the banner says the answer is undecided rather than "
			+ "showing nothing at all",
			str(checks.status_line(report)).contains("undecided"),
			"status = '%s'" % str(checks.status_line(report)))

	# The node is the bare path the record carries — not the reference spliced
	# on to the front of it. Every filter, pair and hole record is keyed on
	# this string, so a prefix here would be a different node to all of them.
	check("neighbour: the pin, which does offer a probe inside itself, IS "
			+ "reported, under the record's own node path exactly",
			named.has(PIN_NODE),
			"pairs = %s" % str(named.keys()))


# ---------------------------------------------------------------------------
# BURIED IN TWO BODIES AT ONCE
# ---------------------------------------------------------------------------

## A solid inside two references is inside BOTH of them.
##
## Two identical blocks, mounted under two names, with a small cube buried in
## the material of each. "Is the solid inside this body" is a separate question
## per reference: answering it for the first one and returning leaves the
## second unreported, and the clearance join then passes its rows on an
## unsigned distance that is really a distance to a wall the cube is inside.
func _check_two_enclosing_references(gauge: Node, checks: RefCounted) -> void:
	var block: ArrayMesh = await _bake_solid_block()
	var built: int = gauge.build([
		{"mesh": block, "transform": _pose, "node": BLOCK_NODE,
			"reference": BLOCK_A},
		{"mesh": block, "transform": _pose, "node": BLOCK_NODE,
			"reference": BLOCK_B},
	], "two-blocks-fixture|v1")
	var box := _posed_box(block.get_aabb())
	_records = []
	for name in [BLOCK_A, BLOCK_B]:
		_records.append({
			"name": name,
			"pose": _pose,
			"world_aabb": box,
			"parts": [{"mesh": block, "transform": Transform3D.IDENTITY,
				"node_path": BLOCK_NODE, "node": BLOCK_NODE}],
		})
	checks.set_records(_records)
	checks.build_solid(await _buried_mesh())

	var report: Dictionary = await _submit(gauge, checks, "", "")
	var named := {}
	for entry in report.get("pairs", []):
		named[str((entry as Dictionary).get("reference", ""))] = \
			str((entry as Dictionary).get("node", ""))
	check("two blocks: the cube is reported as buried in BOTH references, "
			+ "each under its own node — not only in whichever was found first",
			built == 2 and bool(report.get("checked", false))
				and named.size() == 2
				and str(named.get(BLOCK_A, "")) == BLOCK_NODE
				and str(named.get(BLOCK_B, "")) == BLOCK_NODE,
			"pairs = %s" % str(report.get("pairs", [])))

	check("two blocks: nothing is left undecided — every enclosing reference "
			+ "was answered, so the doubt list is empty",
			(report.get("undecidable", []) as Array).is_empty(),
			"undecidable = %s" % str(report.get("undecidable", [])))


## A solid block big enough to swallow the buried cube whole.
func _bake_solid_block() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Block"
	var box := CSGBox3D.new()
	box.size = ENCLOSING
	combiner.add_child(box)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


# ---------------------------------------------------------------------------
# A PROBE THE GAUGE CANNOT DECIDE — and every reference it leaves open
# ---------------------------------------------------------------------------

## The parity test has a budget, and running out of it is not an answer.
##
## A stack of STACK_PLATES thin plates with a 0.1 mm cube parked in one of its
## gaps, touching nothing. Every ray leaving that cube crosses two faces per
## plate, which is more surfaces than mesh_gauge's crossing budget allows, so
## the gauge cannot tell solid from air there and says so. Treating that error
## as "not inside material" reports a cube that may well be buried as clean —
## the one answer the reader must never be given.
##
## The same stack is mounted TWICE, under two names, and both boxes hold the
## cube. The question "is the solid inside this body" was open for both, so
## both have to be listed: a reference left off, on the strength of another
## one having been checked, has its clearance rows passed on a distance
## nobody could sign.
func _check_layered_stack(gauge: Node, checks: RefCounted) -> void:
	var stack: ArrayMesh = await _bake_stack()
	var built: int = gauge.build([
		{"mesh": stack, "transform": _pose, "node": STACK_NODE,
			"reference": STACK_A},
		{"mesh": stack, "transform": _pose, "node": STACK_NODE,
			"reference": STACK_B},
	], "stack-fixture|v1")
	var box := _posed_box(stack.get_aabb())
	_records = []
	for name in [STACK_A, STACK_B]:
		_records.append({
			"name": name,
			"pose": _pose,
			"world_aabb": box,
			"parts": [{"mesh": stack, "transform": Transform3D.IDENTITY,
				"node_path": STACK_NODE, "node": STACK_NODE}],
		})
	checks.set_records(_records)
	checks.build_solid(await _gap_cube_mesh())

	var report: Dictionary = await _submit(gauge, checks, "", "")
	var undecided: Array = report.get("undecidable", []) as Array
	check("layers: a probe the gauge cannot decide — a ray that crosses more "
			+ "surfaces than its budget allows — leaves the answer UNDECIDED, "
			+ "never clean",
			built == 2 and bool(report.get("checked", false))
				and int(report.get("count", 0)) == 0
				and not undecided.is_empty()
				and str((undecided[0] as Dictionary).get("reason", ""))
					.contains("not decided"),
			"report = %s" % str(report))

	var named := {}
	for entry in undecided:
		named[str((entry as Dictionary).get("reference", ""))] = true
	check("layers: BOTH references whose bounds hold the solid are left "
			+ "open, not just the first one found",
			named.has(STACK_A) and named.has(STACK_B),
			"undecidable = %s" % str(undecided))

	# THE SAME QUESTION THE OTHER WAY ROUND. Now the stack is the SOLID and
	# the cube is the reference node: the probe is verified inside the cube's
	# own material, and the parity ray asking whether that point is inside the
	# solid runs out of budget among the layers. Reading that as "outside"
	# drops the node entirely — no pair, no doubt, nothing for the clearance
	# join to fail on — which is the one answer a node that may be buried
	# must never get.
	var cube: ArrayMesh = await _bake_gap_cube()
	var rebuilt: int = gauge.build([{
		"mesh": cube, "transform": _pose, "node": GAP_NODE,
		"reference": GAP_REFERENCE,
	}], "gap-cube-fixture|v1")
	_records = [{
		"name": GAP_REFERENCE,
		"pose": _pose,
		"world_aabb": _posed_box(cube.get_aabb()),
		"parts": [{"mesh": cube, "transform": Transform3D.IDENTITY,
			"node_path": GAP_NODE, "node": GAP_NODE}],
	}]
	checks.set_records(_records)
	checks.build_solid(_mesh_data(stack, _pose))

	var reversed_report: Dictionary = await _submit(gauge, checks, "", "")
	var reversed_doubt: Array = reversed_report.get("undecidable", []) as Array
	var about_cube := {}
	for entry in reversed_doubt:
		if str((entry as Dictionary).get("node", "")) == GAP_NODE:
			about_cube = entry
	check("layers: and the other direction — a reference node whose probe is "
			+ "inside its own material, with the parity ray into the solid "
			+ "out of budget, is UNDECIDED rather than quietly dropped",
			rebuilt == 1 and bool(reversed_report.get("checked", false))
				and int(reversed_report.get("count", 0)) == 0
				and not about_cube.is_empty()
				and str(about_cube.get("reference", "")) == GAP_REFERENCE,
			"report = %s" % str(reversed_report))


## The stack: STACK_PLATES plates of STACK_PLATE_MM, STACK_PITCH_MM apart, so
## the gaps between them are wider than the cube and every ray through the
## stack crosses more faces than the gauge will count.
func _bake_stack() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Stack"
	for index in range(STACK_PLATES):
		var plate := CSGBox3D.new()
		plate.size = Vector3(STACK_SPAN, STACK_SPAN, STACK_PLATE_MM)
		# Centred on the middle plate, so plate STACK_PLATES / 2 sits on z = 0
		# and the gap above it is the one the cube parks in.
		plate.position = Vector3(0.0, 0.0,
			STACK_PITCH_MM * float(index - STACK_PLATES / 2))
		combiner.add_child(plate)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


## The same cube as a REFERENCE mesh, for the direction where the stack is the
## solid and the cube is the node whose containment is asked about.
func _bake_gap_cube() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "GapCubeReference"
	var cube := CSGBox3D.new()
	cube.size = Vector3(GAP_CUBE_MM, GAP_CUBE_MM, GAP_CUBE_MM)
	cube.position = Vector3(0.0, 0.0, GAP_CENTRE_Z)
	combiner.add_child(cube)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


## The cube in the gap: small enough to clear both plates around it, so it
## touches nothing and the question is settled by parity alone — if parity can
## be read at all.
func _gap_cube_mesh() -> Dictionary:
	var combiner := CSGCombiner3D.new()
	combiner.name = "GapCube"
	var cube := CSGBox3D.new()
	cube.size = Vector3(GAP_CUBE_MM, GAP_CUBE_MM, GAP_CUBE_MM)
	# The middle plate's top face plus half the gap: dead centre of the gap.
	cube.position = Vector3(0.0, 0.0, GAP_CENTRE_Z)
	combiner.add_child(cube)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return _mesh_data(baked, _pose)


## The pin that fills the washer's hole: a disc of its own, radially clear of
## the washer by PIN_CLEARANCE_MM and taller than it.
func _bake_neighbour_pin() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Pin"
	var body := CSGCylinder3D.new()
	body.radius = NEIGHBOUR_PIN_R
	body.sides = ROUND_FACETS
	body.smooth_faces = false
	body.height = NEIGHBOUR_PIN_HEIGHT
	body.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	body.position = Vector3(0.0, 0.0,
		CAVITY_FLOOR_TOP_Z + WASHER_LIFT_MM + WASHER_THICKNESS * 0.5)
	combiner.add_child(body)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


# ---------------------------------------------------------------------------
# BUSY — the module is never taken away from a running check
# ---------------------------------------------------------------------------

## The interference check and the fastener check share ONE solid collider, one
## set of records and one cast counter, and they take them one at a time. A
## request that finds the holder still running past its window must be
## REFUSED: usurping the reservation lets the newcomer rebuild the collider the
## running job is casting against, which is a freed body under a live query and
## not merely a wrong number.
##
## The window is driven from the module's own variable rather than waited out,
## so the suite pins the REFUSAL and not the clock.
func _check_busy_refusal(gauge: Node, checks: RefCounted) -> void:
	var first: Dictionary = await checks.reserve()
	var held := int(first.get("ticket", 0))

	var second: Dictionary = await checks.reserve()
	check("busy: a request arriving while a check still holds the geometry is "
			+ "refused, and the refusal names the holder and its age",
			held != 0 and int(second.get("ticket", 0)) == 0
				and bool(second.get("busy", false))
				and int(second.get("holder_ticket", 0)) == held
				and int(second.get("holder_age_ms", -1)) >= 0,
			"first=%s second=%s" % [str(first), str(second)])

	var report: Dictionary = checks.refused(second)
	check("busy: the caller gets a `checked: false` answer that says busy — "
			+ "never a clean report",
			not bool(report.get("checked", true))
				and bool(report.get("busy", false))
				and str(report.get("reason", "")).contains("Retry"),
			"report = %s" % str(report))

	# Past the deadline the holder is not merely late, it is gone: mesh_gauge's
	# own job timeout has expired, and the walk that follows a job is
	# synchronous GDScript, which cannot be parked mid-way. The module is taken
	# back rather than stranded on a coroutine that will never release it —
	# and the dead holder's ticket goes inert, so its late release does not
	# hand the collider away from the check that owns it now.
	checks.reservation_timeout_ms = 0
	var reclaimer: Dictionary = await checks.reserve()
	var taken := int(reclaimer.get("ticket", 0))
	checks.release_reservation(held)
	check("reclaim: a holder that never releases is taken over after its "
			+ "deadline, and its own late release does nothing",
			taken != 0 and taken != held
				and not bool(checks.holds(held))
				and bool(checks.holds(taken)),
			"held=%d reclaimer=%s holds(held)=%s holds(taken)=%s" % [held,
				str(reclaimer), str(checks.holds(held)), str(checks.holds(taken))])

	# The dangerous moment: the reclaimed holder wakes up from the physics
	# await it was suspended in and tries to work. Every write it can make is
	# refused — rebuilding the collider would FREE a body the live check is
	# casting against, and running its job would answer with that check's
	# geometry and overwrite its counters.
	checks.reservation_timeout_ms = GeometryChecks.RESERVATION_TIMEOUT_MS
	var generation := int(checks.get_solid_generation())
	var refused_build := int(checks.build_solid(
		await _shell_mesh(BOSS_THROUGH_BOTTOM_Z), held))
	var stale: Dictionary = checks.run_check(gauge, null, {"ticket": held})
	check("reclaim: a holder that resumes after being reclaimed writes "
			+ "nothing — its rebuild is refused, the collider it would have "
			+ "freed is untouched, and its job answers without measuring",
			refused_build < 0
				and int(checks.get_solid_generation()) == generation
				and not bool(stale.get("checked", true))
				and str(stale.get("reason", "")).contains("reclaimed"),
			"build=%d generation %d -> %d stale=%s" % [refused_build,
				generation, int(checks.get_solid_generation()), str(stale)])

	# And the same refusal while the LIVE holder has merely aged: age decides
	# who owns the module only inside reserve(), so a stale age is never a
	# licence for a wrong ticket to free the collider before the transfer.
	checks.reservation_timeout_ms = 0
	var aged_generation := int(checks.get_solid_generation())
	var aged_build := int(checks.build_solid(
		await _shell_mesh(BOSS_THROUGH_BOTTOM_Z), 0))
	check("reclaim: a caller with the wrong ticket cannot free the collider "
			+ "just because the holder has aged past its window — only "
			+ "reserve() may hand the module over",
			aged_build < 0
				and int(checks.get_solid_generation()) == aged_generation,
			"build=%d generation %d -> %d" % [aged_build, aged_generation,
				int(checks.get_solid_generation())])
	checks.reservation_timeout_ms = GeometryChecks.RESERVATION_TIMEOUT_MS

	checks.release_reservation(taken)
	var after: Dictionary = await checks.reserve()
	check("reclaim: the reclaimer's own release frees the module for the next "
			+ "request",
			int(after.get("ticket", 0)) != 0, "after = %s" % str(after))
	checks.release_reservation(int(after.get("ticket", 0)))


## Start a check without awaiting it and park its reply in `into`.
func _collect(checks: RefCounted, panel: Node, into: Array) -> void:
	var reply: Dictionary = await checks.check(panel, {})
	into.append(reply)


## The four accessors geometry_checks.gd reads off a panel, and one pane.
class StandInPanel extends Node3D:
	var gauge: Node = null
	var records: Array = []
	var mesh_data: Dictionary = {}

	func get_mesh_gauge() -> Node:
		return gauge

	func ensure_gauge_built() -> int:
		return int(gauge.get_shape_count()) if gauge != null else 0

	func get_reference_state() -> Array:
		return records

	func get_document_state() -> Dictionary:
		return {"mesh": mesh_data}


func _stand_in_panel(gauge: Node) -> Node:
	var panel := StandInPanel.new()
	panel.name = "StandInPanel"
	panel.gauge = gauge
	panel.records = _records
	root.add_child(panel)
	var parent: Node = panel
	for segment in MESH_ROOT_PATH.split("/"):
		var node := Node3D.new()
		node.name = segment
		parent.add_child(node)
		parent = node
	return panel


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


## A box big enough to swallow the whole board.
func _enclosing_mesh() -> Dictionary:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Enclosing"
	var box := CSGBox3D.new()
	box.size = ENCLOSING
	combiner.add_child(box)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return _mesh_data(baked, _pose)


## The cavity shell: an open-topped box with the board's underside for a
## floor. The inner box runs past the outer one's top face, so the subtraction
## leaves the top open rather than a lid the board would be sealed under.
func _cavity_mesh(with_pin: bool = false) -> Dictionary:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Cavity"
	var outer := CSGBox3D.new()
	outer.size = CAVITY_OUTER
	outer.position = Vector3(0.0, 0.0,
		CAVITY_FLOOR_TOP_Z - CAVITY_FLOOR_MM + CAVITY_OUTER.z * 0.5)
	combiner.add_child(outer)
	var inner := CSGBox3D.new()
	inner.size = CAVITY_INNER
	inner.operation = CSGShape3D.OPERATION_SUBTRACTION
	inner.position = Vector3(0.0, 0.0, CAVITY_FLOOR_TOP_Z + CAVITY_INNER.z * 0.5)
	combiner.add_child(inner)
	if with_pin:
		# Added after the cutter, so the cavity cannot remove it: the pin is
		# the shell's own material standing on its floor.
		var pin := CSGCylinder3D.new()
		pin.radius = PIN_R
		pin.sides = ROUND_FACETS
		pin.smooth_faces = false
		pin.height = PIN_TOP_Z - CAVITY_FLOOR_TOP_Z
		# A CSG cylinder runs along its own +Y; a quarter turn about X takes
		# that to +Z, the axis a locating pin stands on.
		pin.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		pin.position = Vector3(0.0, 0.0, (PIN_TOP_Z + CAVITY_FLOOR_TOP_Z) * 0.5)
		combiner.add_child(pin)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return _mesh_data(baked, _pose)


## The washer: a disc with a hole so large that its every vertex sits on one of
## the two rims. That is the whole point of the shape — there is no face
## vertex to fall back on, so the probe has to be right rather than lucky.
func _bake_washer() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Washer"
	var disc := CSGCylinder3D.new()
	disc.radius = WASHER_OUTER_R
	disc.sides = ROUND_FACETS
	disc.smooth_faces = false
	disc.height = WASHER_THICKNESS
	disc.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	disc.position = Vector3(0.0, 0.0,
		CAVITY_FLOOR_TOP_Z + WASHER_LIFT_MM + WASHER_THICKNESS * 0.5)
	combiner.add_child(disc)
	var bore := CSGCylinder3D.new()
	bore.radius = WASHER_INNER_R
	bore.sides = ROUND_FACETS
	bore.smooth_faces = false
	bore.height = WASHER_THICKNESS * 4.0
	bore.operation = CSGShape3D.OPERATION_SUBTRACTION
	bore.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	bore.position = disc.position
	combiner.add_child(bore)
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


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
	return _posed_box(AABB(-BOARD * 0.5, BOARD))


## A local box in world millimetres. The pose TURNS its body, so the answer is
## the box around the eight posed corners and not the local box with its
## origin moved.
func _posed_box(local: AABB) -> AABB:
	var box := AABB()
	var seen := false
	for x in [local.position.x, local.position.x + local.size.x]:
		for y in [local.position.y, local.position.y + local.size.y]:
			for z in [local.position.z, local.position.z + local.size.z]:
				var corner: Vector3 = _pose * Vector3(x, y, z)
				box = AABB(corner, Vector3.ZERO) if not seen else box.expand(corner)
				seen = true
	return box


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
