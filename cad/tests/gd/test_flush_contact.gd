extends SceneTree
## A boss holding up a board is a CONTACT, not an interference.
##
## THE CASE, AND WHY THE OLD FIXTURE MISSED IT
##
## The enclosure's bosses are what the board rests on: the boss's flat top and
## the board's underside are designed to be coplanar, and the check has always
## had a fixture for a designed flush fit — a box resting on a floor. That one
## passes for the wrong reason. A CSG box bakes to two triangles per face, so
## the floor's underside offers a diagonal and a perimeter, and nothing runs
## over the box's own rim.
##
## A REAL BOARD IS TRIANGULATED, so its underside is a mesh of small triangles
## and dozens of their edges pass over any boss beneath it. Each of those
## edges enters the boss's rim on one side and leaves on the other. Every
## per-crossing test agrees the chord is real — the edge does straddle the
## cylinder's side wall, and a point a step along it is genuinely inside the
## boss, by whatever the float error of the shared plane happens to be — so a
## four-millimetre "penetration" is reported across a boss that is exactly
## where it belongs, and an agent reading the report moves it away.
##
## THE FIXTURE IS THEREFORE A GRID-TRIANGULATED PLATE over a cylinder whose
## top face lies in the plate's underside. The grid pitch is finer than the
## boss, so its edges cross the rim; that is the property the old fixture
## lacked and the one this suite asserts before it asserts anything else.
##
## THE COPLANARITY IS FLOAT COPLANARITY. A board that arrives from the modeller
## does not sit at exactly z = 0 — the measured underside of the real one sits
## a fraction of a micron off it — so the fixture asks the question twice: the
## boss exactly in the plane, and the boss a hundredth of a micron... a
## hundred-thousandth of a millimetre INTO it, inside the check's own touch
## epsilon. Exact coplanarity is already cleared by the per-crossing parity
## tests; it is the LIFTED one that reproduces the report, and it is the one
## that turns red the moment the contact-run gate is taken out.
##
## THE CONTROL IS THE SAME BOSS RAISED 0.5 mm INTO THE PLATE. Nothing else
## changes — same mesh, same triangulation, same rim, same edges crossing it.
## If the rule that clears the flush case also clears this one it has not
## learned the difference between contact and overlap, it has just stopped
## reporting bosses.
##
## ORACLE: the pair of reports. The rule is wrong in one direction if the
## flush boss is still reported, and wrong in the other if the bitten one is
## not — the two differ by half a millimetre of lift and nothing else.
##
## THE DEPTH IS A THIRD CASE, not a property of the bitten one. A penetration
## depth is a RUN — one edge in and out again — and no single edge spans the
## half-millimetre disc, so the bite is reported WITHOUT a depth. The
## boss driven clean through the board is the control that says so honestly:
## there the run exists, and the depth is the board's thickness.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const GeometryChecks := preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")
const MeshGauge := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")

## The plate standing in for the board: its UNDERSIDE is at z = 0.
const PLATE_SPAN := 24.0
const PLATE_THICKNESS := 1.6
## Grid cells across the plate. The pitch (1.5 mm) has to be finer than the
## boss it sits over, or no triangle edge crosses the rim and the fixture is
## the old one again.
const PLATE_CELLS := 16

## The boss: a facetted cylinder whose flat top is the contact face.
const BOSS_RADIUS := 3.0
const BOSS_HEIGHT := 8.0
const BOSS_FACETS := 32
## Off the grid lines and off the origin, so the rim cuts cells rather than
## running along their edges.
const BOSS_CENTRE := Vector2(1.2, -5.0)
## The float noise a real coplanar face arrives with. Inside TOUCH_EPSILON_MM
## (1e-4), and the lift at which the false positive actually appears: at exact
## zero the per-crossing parity tests already clear the crossing, so a fixture
## built only on exact coplanarity measures nothing.
const FLUSH_LIFT_MM := 1e-5
## How far the control boss is driven INTO the plate.
const BITE_MM := 0.5

const REFERENCE_NAME := "board"
const NODE_PATH := "Assembly/Plate"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== CAD Flush Contact Test (a boss under a triangulated board) ===\n")
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
	var plate := _grid_plate()
	check("fixture: the plate is grid-triangulated, not two triangles a face",
			_triangle_count(plate) > PLATE_CELLS * PLATE_CELLS,
			"%d triangles" % _triangle_count(plate))
	check("fixture: its underside triangle edges really do cross the boss rim "
			+ "— the property the box-on-a-floor fixture never had",
			_underside_edges_crossing_the_rim(plate) > 0,
			"%d edges cross the rim" % _underside_edges_crossing_the_rim(plate))

	var gauge := MeshGauge.new()
	gauge.name = "MeshGauge"
	root.add_child(gauge)
	var checks: RefCounted = GeometryChecks.new()
	checks.attach(root)
	await process_frame

	var built: int = gauge.build([{
		"mesh": plate,
		"transform": Transform3D.IDENTITY,
		"node": NODE_PATH,
		"reference": REFERENCE_NAME,
	}], "flush-contact-fixture|v1")
	check("fixture: the plate became one reference collider",
			built == 1, "built %d colliders" % built)
	checks.set_records([{
		"name": REFERENCE_NAME,
		"pose": Transform3D.IDENTITY,
		"world_aabb": _plate_world_box(),
		"parts": [{
			"mesh": plate,
			"transform": Transform3D.IDENTITY,
			"node_path": NODE_PATH,
			"node": NODE_PATH,
		}],
	}])

	# --- the designed contact -----------------------------------------------
	checks.build_solid(_boss_mesh(0.0))
	var flush: Dictionary = await _submit(gauge, checks)
	check("a boss whose flat top is exactly coplanar with the board's "
			+ "underside is a designed contact, not interference",
			bool(flush.get("checked", false))
				and int(flush.get("count", 0)) == 0
				and int(flush.get("point_count", 0)) == 0,
			"report = %s" % str(flush))

	# The same contact as it actually arrives: coplanar to within float noise,
	# well inside the check's touch epsilon. THIS is the case that reproduces
	# the report — dozens of underside triangle edges cut the rim, each one a
	# millimetres-long chord that every per-crossing test calls real — and the
	# one that goes red when the contact-run gate is removed.
	checks.build_solid(_boss_mesh(FLUSH_LIFT_MM))
	var noisy: Dictionary = await _submit(gauge, checks)
	check("the same contact a hundred-thousandth of a millimetre out of plane "
			+ "— float noise, inside the touch epsilon — is still a contact, "
			+ "and its rim chords are not a four-millimetre penetration",
			bool(noisy.get("checked", false))
				and int(noisy.get("count", 0)) == 0
				and int(noisy.get("point_count", 0)) == 0,
			"report = %s" % str(noisy))

	# --- the control ---------------------------------------------------------
	checks.build_solid(_boss_mesh(BITE_MM))
	var bitten: Dictionary = await _submit(gauge, checks)
	check("the same boss driven half a millimetre INTO the board is "
			+ "interference, on the board's own node",
			bool(bitten.get("checked", false))
				and int(bitten.get("count", 0)) == 1
				and str(((bitten.get("pairs", []) as Array)[0] as Dictionary)
					.get("node", "")) == NODE_PATH,
			"report = %s" % str(bitten))
	# A depth is a RUN: two crossings of one edge, one in and one out. No edge
	# spans the half-millimetre disc — the board's underside edges enter the
	# boss's rim and stop inside it, and the boss's own side edges enter the
	# board and stop inside it — so the overlap is reported without a depth
	# rather than with the lateral chord, which is millimetres long and would
	# read as the depth of a far deeper bite.
	check("the half-millimetre overlap is reported without a depth: no "
			+ "single edge spans it, and the check quotes no run it did not "
			+ "measure",
			_penetration_of(bitten) == 0.0,
			"penetration = %s, report = %s"
				% [str(_penetration_of(bitten)), str(bitten)])

	# --- the depth control ---------------------------------------------------
	# Which is only honest if a depth still arrives when a run really is
	# there. The same boss driven clean through the board: its side edges go
	# in at the underside and out at the top face, and the run between those
	# two crossings is the board's own thickness.
	checks.build_solid(_boss_mesh(PLATE_THICKNESS + 1.0))
	var through: Dictionary = await _submit(gauge, checks)
	check("a boss driven clean through the board reports the depth it went "
			+ "in — the board's thickness, bounded by one edge's two crossings",
			bool(through.get("checked", false))
				and int(through.get("count", 0)) == 1
				and absf(_penetration_of(through) - PLATE_THICKNESS) < 0.05,
			"penetration = %s, report = %s"
				% [str(_penetration_of(through)), str(through)])


func _submit(gauge: Node, checks: RefCounted) -> Dictionary:
	return await gauge.submit("interference", {
		"module": checks,
		"mask": int(MeshGauge.ALL_LAYERS),
		"reference": "",
		"node": "",
	})


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

## A closed plate whose two big faces are a grid of triangles, spanning
## PLATE_SPAN square with its UNDERSIDE at z = 0. Built by hand rather than
## baked from CSG: the triangulation is the fixture, and CSG gives two
## triangles a face whatever the size.
func _grid_plate() -> ArrayMesh:
	var soup := PackedVector3Array()
	var half := PLATE_SPAN * 0.5
	var pitch := PLATE_SPAN / float(PLATE_CELLS)
	var top := PLATE_THICKNESS
	for ix in range(PLATE_CELLS):
		for iy in range(PLATE_CELLS):
			var x0 := -half + pitch * ix
			var x1 := x0 + pitch
			var y0 := -half + pitch * iy
			var y1 := y0 + pitch
			# Underside (z = 0) and top face, wound opposite ways.
			_quad(soup, Vector3(x0, y0, 0.0), Vector3(x1, y0, 0.0),
				Vector3(x1, y1, 0.0), Vector3(x0, y1, 0.0))
			_quad(soup, Vector3(x0, y1, top), Vector3(x1, y1, top),
				Vector3(x1, y0, top), Vector3(x0, y0, top))
	# The four sides, two triangles each: nothing runs along them.
	_quad(soup, Vector3(-half, -half, 0.0), Vector3(half, -half, 0.0),
		Vector3(half, -half, top), Vector3(-half, -half, top))
	_quad(soup, Vector3(half, half, 0.0), Vector3(-half, half, 0.0),
		Vector3(-half, half, top), Vector3(half, half, top))
	_quad(soup, Vector3(half, -half, 0.0), Vector3(half, half, 0.0),
		Vector3(half, half, top), Vector3(half, -half, top))
	_quad(soup, Vector3(-half, half, 0.0), Vector3(-half, -half, 0.0),
		Vector3(-half, -half, top), Vector3(-half, half, top))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = soup
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _quad(soup: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3,
		d: Vector3) -> void:
	soup.append(a)
	soup.append(b)
	soup.append(c)
	soup.append(a)
	soup.append(c)
	soup.append(d)


## The boss as worker mesh data: a facetted cylinder of BOSS_HEIGHT whose top
## face sits `lift` above the plate's underside. lift 0 is the designed
## contact; a positive lift drives it into the plate.
func _boss_mesh(lift: float) -> Dictionary:
	var vertices: Array = []
	var faces: Array = []
	var top := lift
	var bottom := lift - BOSS_HEIGHT
	var centre_top := vertices.size()
	vertices.append([BOSS_CENTRE.x, BOSS_CENTRE.y, top])
	var centre_bottom := vertices.size()
	vertices.append([BOSS_CENTRE.x, BOSS_CENTRE.y, bottom])
	var rim_top: Array = []
	var rim_bottom: Array = []
	for facet in range(BOSS_FACETS):
		var angle := TAU * float(facet) / float(BOSS_FACETS)
		var x: float = BOSS_CENTRE.x + BOSS_RADIUS * cos(angle)
		var y: float = BOSS_CENTRE.y + BOSS_RADIUS * sin(angle)
		rim_top.append(vertices.size())
		vertices.append([x, y, top])
		rim_bottom.append(vertices.size())
		vertices.append([x, y, bottom])
	for facet in range(BOSS_FACETS):
		var next := (facet + 1) % BOSS_FACETS
		faces.append([centre_top, rim_top[facet], rim_top[next]])
		faces.append([centre_bottom, rim_bottom[next], rim_bottom[facet]])
		faces.append([rim_top[facet], rim_bottom[facet], rim_bottom[next]])
		faces.append([rim_top[facet], rim_bottom[next], rim_top[next]])
	return {"vertices": vertices, "faces": faces}


func _plate_world_box() -> AABB:
	return AABB(Vector3(-PLATE_SPAN * 0.5, -PLATE_SPAN * 0.5, 0.0),
		Vector3(PLATE_SPAN, PLATE_SPAN, PLATE_THICKNESS))


# ---------------------------------------------------------------------------
# What the fixture asserts about itself
# ---------------------------------------------------------------------------

func _triangle_count(mesh: ArrayMesh) -> int:
	var arrays: Array = mesh.surface_get_arrays(0)
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


## Underside triangle edges with one end inside the boss rim and the other
## outside it: the edges that cut the rim, which is what the old fixture had
## none of.
func _underside_edges_crossing_the_rim(mesh: ArrayMesh) -> int:
	var arrays: Array = mesh.surface_get_arrays(0)
	var soup: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var crossing := 0
	var index := 0
	while index + 2 < soup.size():
		var corners := [soup[index], soup[index + 1], soup[index + 2]]
		index += 3
		if absf((corners[0] as Vector3).z) > 1e-9 \
				or absf((corners[1] as Vector3).z) > 1e-9 \
				or absf((corners[2] as Vector3).z) > 1e-9:
			continue
		for pair in [[0, 1], [1, 2], [2, 0]]:
			var a: Vector3 = corners[pair[0]]
			var b: Vector3 = corners[pair[1]]
			var inside_a: bool = Vector2(a.x, a.y).distance_to(BOSS_CENTRE) < BOSS_RADIUS
			var inside_b: bool = Vector2(b.x, b.y).distance_to(BOSS_CENTRE) < BOSS_RADIUS
			if inside_a != inside_b:
				crossing += 1
	return crossing


## The deepest run reported over every pair, or 0 when nothing was reported.
func _penetration_of(report: Dictionary) -> float:
	var deepest := 0.0
	for entry in (report.get("pairs", []) as Array):
		deepest = maxf(deepest,
			float((entry as Dictionary).get("penetration_mm", 0.0)))
	return deepest
