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
## THE SAME CONTACT IS ASKED WITH THE ROLES SWAPPED, because the check casts
## in two directions and each has its own copy of the contact-run gate. With
## the plate as the reference and the boss as the solid it is the SOLID-path
## copy that clears the rim chords (_cross_into_solid); the boss's own edges
## barely reach the plate, so the reference-path copy contributes nothing.
## Making the PLATE the solid puts its dense underside edges on the
## reference-cast path (_cross_into_references -> _drop_contact_runs), and
## there the chords are cleared by that copy alone: the boss's own crossings of
## the plate sit within TOUCH_EPSILON_MM of the edge start at these lifts and
## are already dropped as touches, so direction two contributes nothing to the
## swapped verdict either.
##
## THE SWAPPED SET ENDS TILTED for the same reason the unswapped one does. On
## an exactly coplanar swapped case both ends of a plate chord penetrate the
## rim, so the run is bounded whether or not the reference leg keeps the hits
## it discarded; only the tilt sends the chord out through the TOP FACE, whose
## hit no per-crossing test vouches for. That case is the falsifier for the
## reference leg's keep: drop the discarded hits there and the run measures on
## to the far end of the triangle, and the designed contact is reported.
##
## MUTATION THAT MUST TURN THE SWAPPED CASES RED: make _drop_contact_runs
## return `crossings` unchanged. The plate's underside chords over the boss
## rim straddle the rim wall and have boss material a probe step behind them,
## so every one of them is then reported and the two cleared lifts report a
## pair.
##
## THE SEATING FACE IS BORED. Every boss in a real enclosure carries a screw,
## and the pilot's mouth is in the face that seats — so the contact face is an
## annulus and the plane it shares with the board has a hole in it. A chord
## over that mouth is over nothing: no face is within the touch epsilon of it,
## and a gate that only asks "is this run lying in a face" reports the whole
## flush fit. The BORED boss is therefore asked at the same three lifts as the
## plain one, and its control is the same half-millimetre bite: a rule that
## cleared the mouth by clearing everything coplanar would clear that too.
##
## THE SWAPPED LIFTS BRACKET THE CONTACT TOLERANCE, NOT THE TOUCH EPSILON.
## They used to bracket the epsilon — 9e-5 mm inside the plate was a contact
## and 2e-4 mm inside was interference — and that pin was WRONG in the
## direction that matters: 2e-4 mm is the precision the physics hit positions
## themselves arrive in on a hundred-millimetre part, so the check was calling
## its own arithmetic noise an overlap — a seat at z = 0 reported crossing at
## z = -0.0003. The line
## between a designed fit and a part in the wrong place is
## expected_contacts.gd's CONTACT_TOLERANCE_MM, a hundredth of a millimetre,
## and rim_contact.gd now measures against it: a boss 2e-4 mm into the plate
## is a contact, one 0.02 mm in is not, and one 0.05 mm in is not either. The
## middle lift is what pins WHERE the threshold is — without it the tolerance
## could drift anywhere across that hundred-and-fifty-fold gap unseen. See
## test_rim_contact.gd, which is about that rule and this case's coaxial
## cousin.
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
## The screw pilot bored into the boss from its seating face: an M2.5 thread
## pilot, wider than the plate's grid pitch so its own rim is cut by underside
## edges the same way the boss's outer rim is. Blind, and shallower than the
## boss, so the bore has a floor and the body stays closed.
const BORE_RADIUS := 1.25
const BORE_DEPTH := 4.0
## The tilt a board arrives with. A modelled contact plane is coplanar to
## within float noise, not exactly: over this plate the underside then weaves
## a few hundredths of a micron either side of the boss's top face — every
## deviation inside TOUCH_EPSILON_MM (1e-4), so the whole face is still a
## contact, but the underside edges now cross the top face plane instead of
## lying in it. That crossing is what the exactly-coplanar fixture cannot
## make: the edge enters the boss through the rim wall and leaves through the
## TOP FACE, and the top-face hit is discarded (the edge straddles it by far
## less than the epsilon), so the rim crossing is left measuring its run out
## to the far end of the triangle — through the air past the boss.
## 4.5e-6 rad over a 24 mm plate is 5.4e-5 mm at the corners.
const BOARD_TILT_RAD := 4.5e-6
## The float noise a real coplanar face arrives with. Inside TOUCH_EPSILON_MM
## (1e-4), and the lift at which the false positive actually appears: at exact
## zero the per-crossing parity tests already clear the crossing, so a fixture
## built only on exact coplanarity measures nothing.
const FLUSH_LIFT_MM := 1e-5
## How far the control boss is driven INTO the plate.
const BITE_MM := 0.5

## The swapped fixture's lifts, either side of CONTACT_TOLERANCE_MM: the
## precision a coplanar pair actually arrives with, which is a contact, and a
## lift five times the tolerance, which is not.
const PRECISION_LIFT_MM := 2e-4
## Just past the contact tolerance, and five times past it. The pair brackets
## WHERE the threshold is, not merely that there is one: without the near
## case, CONTACT_TOLERANCE_MM could drift anywhere between 3e-4 and 0.05 and
## every assertion here would stay green.
const NEAR_TOLERANCE_LIFT_MM := 0.02
const REPORTED_LIFT_MM := 0.05

const REFERENCE_NAME := "board"
const NODE_PATH := "Assembly/Plate"
## The swapped fixture: the boss is the mounted reference, the plate the solid.
const BOSS_REFERENCE_NAME := "boss"
const BOSS_NODE_PATH := "Assembly/Boss"

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

	# --- the same contact through a bored seating face -----------------------
	# The boss as it is actually built: pilot-bored for the screw it carries,
	# so its top face is an annulus and the mouth of the bore is IN the plane
	# the board rests on. Underside chords now cross two rims, and the run
	# over the mouth lies in no face at all.
	var bored := _bored_boss_mesh(0.0)
	check("fixture: the bore's own rim is cut by the plate's underside edges "
			+ "too — the mouth is in the contact plane, not beside it",
			_underside_edges_crossing_the_rim(plate, BORE_RADIUS) > 0,
			"%d edges cross the bore rim"
				% _underside_edges_crossing_the_rim(plate, BORE_RADIUS))
	checks.build_solid(bored)
	var bored_flush: Dictionary = await _submit(gauge, checks)
	check("a bored boss seated exactly in the board's underside is a contact: "
			+ "the chord over the open mouth is not a penetration",
			bool(bored_flush.get("checked", false))
				and int(bored_flush.get("count", 0)) == 0
				and int(bored_flush.get("point_count", 0)) == 0,
			"report = %s" % str(bored_flush))

	checks.build_solid(_bored_boss_mesh(FLUSH_LIFT_MM))
	var bored_noisy: Dictionary = await _submit(gauge, checks)
	check("the same bored contact a hundred-thousandth of a millimetre out of "
			+ "plane — float noise, inside the touch epsilon — is still a "
			+ "contact, with no depth quoted across the bore",
			bool(bored_noisy.get("checked", false))
				and int(bored_noisy.get("count", 0)) == 0
				and int(bored_noisy.get("point_count", 0)) == 0
				and _penetration_of(bored_noisy) == 0.0,
			"report = %s" % str(bored_noisy))

	# THE CONTROL. Same bore, same rims, same chords over the same mouth: only
	# the half millimetre of lift differs. A rule that cleared the flush bore
	# by clearing everything in the contact plane clears this one too.
	checks.build_solid(_bored_boss_mesh(BITE_MM))
	var bored_bitten: Dictionary = await _submit(gauge, checks)
	check("the bored boss driven half a millimetre INTO the board is still "
			+ "interference, on the board's own node",
			bool(bored_bitten.get("checked", false))
				and int(bored_bitten.get("count", 0)) == 1
				and str(((bored_bitten.get("pairs", []) as Array)[0]
					as Dictionary).get("node", "")) == NODE_PATH,
			"report = %s" % str(bored_bitten))

	# --- the contact as a modeller actually delivers it ----------------------
	# Same boss, same plate, same triangulation: only the plate is tilted by
	# five microradians, so its underside is coplanar with the boss's top to
	# within float noise rather than exactly. Every underside edge over the
	# boss now enters through the rim wall and leaves through the top face,
	# and the top-face hit is the one no per-crossing test will vouch for.
	# ORACLE: the controls above, unchanged. A gate that clears this by
	# widening what counts as a contact clears the half-millimetre bite too;
	# one that reports it has lost the flush fit the board rests on.
	_mount_tilted_plate(gauge, checks)
	checks.build_solid(_boss_mesh(0.0))
	var tilted: Dictionary = await _submit(gauge, checks)
	check("a board tilted five microradians — coplanar with the boss's top to "
			+ "within float noise, the way one arrives from a modeller — is "
			+ "still a contact, with no depth quoted for it",
			bool(tilted.get("checked", false))
				and int(tilted.get("count", 0)) == 0
				and int(tilted.get("point_count", 0)) == 0
				and _penetration_of(tilted) == 0.0,
			"report = %s" % str(tilted))

	await _swapped_roles(gauge, checks)


## The same designed contact cast the other way: the boss is the mounted
## reference and the triangulated plate is the solid, so the plate's underside
## edges are what run over the rim and the reference-cast gate is what has to
## clear them.
func _swapped_roles(gauge: Node, checks: RefCounted) -> void:
	checks.build_solid(_solid_from(_grid_plate()))
	var built := _mount_boss(gauge, checks, FLUSH_LIFT_MM)
	check("fixture (swapped): the boss became the one reference collider, so "
			+ "the plate's edges are now the ones cast at it",
			built == 1, "built %d colliders" % built)

	var noisy: Dictionary = await _submit(gauge, checks)
	check("swapped: a boss a hundred-thousandth of a millimetre into the "
			+ "plate is a contact when the plate's edges are the ones cast",
			bool(noisy.get("checked", false))
				and int(noisy.get("count", 0)) == 0
				and int(noisy.get("point_count", 0)) == 0,
			"report = %s" % str(noisy))

	_mount_boss(gauge, checks, PRECISION_LIFT_MM)
	var inside: Dictionary = await _submit(gauge, checks)
	check("swapped: still a contact two ten-thousandths of a millimetre in — "
			+ "which is the precision the hit positions arrive in on a "
			+ "hundred-millimetre part",
			bool(inside.get("checked", false))
				and int(inside.get("count", 0)) == 0
				and int(inside.get("point_count", 0)) == 0,
			"report = %s" % str(inside))

	# The control that says the rule has a threshold rather than a habit: five
	# hundredths of a millimetre — five times the contact tolerance, and two
	# hundred times the lift above — and the same chords are an overlap again.
	_mount_boss(gauge, checks, REPORTED_LIFT_MM)
	var outside: Dictionary = await _submit(gauge, checks)
	check("swapped: a boss five hundredths of a millimetre in, past the "
			+ "contact tolerance, is interference on the boss's own node",
			bool(outside.get("checked", false))
				and int(outside.get("count", 0)) == 1
				and str(((outside.get("pairs", []) as Array)[0] as Dictionary)
					.get("node", "")) == BOSS_NODE_PATH,
			"report = %s" % str(outside))

	_mount_boss(gauge, checks, NEAR_TOLERANCE_LIFT_MM)
	var near: Dictionary = await _submit(gauge, checks)
	check("swapped: and interference already at two hundredths of a "
			+ "millimetre — twice the contact tolerance — so the threshold is "
			+ "pinned where it is and not merely known to exist",
			bool(near.get("checked", false))
				and int(near.get("count", 0)) == 1
				and str(((near.get("pairs", []) as Array)[0] as Dictionary)
					.get("node", "")) == BOSS_NODE_PATH,
			"report = %s" % str(near))

	_mount_boss(gauge, checks, BITE_MM)
	var bitten: Dictionary = await _submit(gauge, checks)
	check("swapped: the same boss half a millimetre into the plate is "
			+ "interference either way round",
			bool(bitten.get("checked", false))
				and int(bitten.get("count", 0)) == 1
				and str(((bitten.get("pairs", []) as Array)[0] as Dictionary)
					.get("node", "")) == BOSS_NODE_PATH,
			"report = %s" % str(bitten))

	# The modeller's contact on THIS leg. Exactly coplanar, both rim hits of a
	# plate chord penetrate and the run is bounded either way; it is the tilt
	# that makes the chord leave through the top face, and that exit is the hit
	# no per-crossing test vouches for. With the plate as the solid those
	# chords are cast at the reference, so this is the case that needs
	# _cross_into_references to KEEP its bound-only hits: without the exit the
	# run runs on to the far end of the triangle, through the air past the
	# boss, and the designed contact is reported as millimetres of overlap.
	# ORACLE: the two controls above, unchanged — the same lifts must still be
	# a contact and a bite.
	_mount_boss(gauge, checks, 0.0)
	checks.build_solid(_tilted_plate_solid())
	var tilted: Dictionary = await _submit(gauge, checks)
	check("swapped: a plate tilted five microradians onto the boss — coplanar "
			+ "to within float noise, the way one arrives from a modeller — is "
			+ "a contact when the plate's own edges are the ones cast",
			bool(tilted.get("checked", false))
				and int(tilted.get("count", 0)) == 0
				and int(tilted.get("point_count", 0)) == 0
				and _penetration_of(tilted) == 0.0,
			"report = %s" % str(tilted))


## Re-mount the plate as the sole reference, rotated by BOARD_TILT_RAD about
## Y. The rotation is about the origin, which is 1.2 mm from the boss's axis,
## so the underside plane crosses z = 0 INSIDE the rim — the edge weaves
## through the contact plane rather than lying in it. The world box is grown
## by a micron for the same reason the boss's is: AABB.intersects is exclusive
## and the edges this fixture is about lie in the box's own face.
func _mount_tilted_plate(gauge: Node, checks: RefCounted) -> void:
	var plate := _grid_plate()
	var tilt := Transform3D(Basis(Vector3(0.0, 1.0, 0.0), BOARD_TILT_RAD),
		Vector3.ZERO)
	gauge.build([{
		"mesh": plate,
		"transform": tilt,
		"node": NODE_PATH,
		"reference": REFERENCE_NAME,
	}], "flush-contact-tilted|v1")
	checks.set_records([{
		"name": REFERENCE_NAME,
		"pose": Transform3D.IDENTITY,
		"world_aabb": _plate_world_box().grow(0.001),
		"parts": [{
			"mesh": plate,
			"transform": tilt,
			"node_path": NODE_PATH,
			"node": NODE_PATH,
		}],
	}])


## Mount the boss as the sole reference at this lift, replacing whatever was
## mounted before. The digest carries the lift: an unchanged digest is a no-op
## build, and every lift here is a different body.
func _mount_boss(gauge: Node, checks: RefCounted, lift: float) -> int:
	var mesh := _mesh_from(_boss_mesh(lift))
	var built: int = gauge.build([{
		"mesh": mesh,
		"transform": Transform3D.IDENTITY,
		"node": BOSS_NODE_PATH,
		"reference": BOSS_REFERENCE_NAME,
	}], "flush-contact-swapped|lift=%.8f" % lift)
	checks.set_records([{
		"name": BOSS_REFERENCE_NAME,
		"pose": Transform3D.IDENTITY,
		"world_aabb": _boss_world_box(lift),
		"parts": [{
			"mesh": mesh,
			"transform": Transform3D.IDENTITY,
			"node_path": BOSS_NODE_PATH,
			"node": BOSS_NODE_PATH,
		}],
	}])
	return built


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


## The same boss with the screw pilot bored into its seating face: the top is
## an annulus between BORE_RADIUS and BOSS_RADIUS, the bore's wall runs down
## from that face and the bore has a floor, so the body stays closed. `lift`
## means what it does for the plain boss — the seating face, and with it the
## mouth of the bore, sits that far above the plate's underside.
func _bored_boss_mesh(lift: float) -> Dictionary:
	var vertices: Array = []
	var faces: Array = []
	var top := lift
	var bottom := lift - BOSS_HEIGHT
	var floor_z := lift - BORE_DEPTH
	var centre_bottom := vertices.size()
	vertices.append([BOSS_CENTRE.x, BOSS_CENTRE.y, bottom])
	var centre_floor := vertices.size()
	vertices.append([BOSS_CENTRE.x, BOSS_CENTRE.y, floor_z])
	var rim_top: Array = []
	var rim_bottom: Array = []
	var bore_top: Array = []
	var bore_floor: Array = []
	for facet in range(BOSS_FACETS):
		var angle := TAU * float(facet) / float(BOSS_FACETS)
		var outer := BOSS_CENTRE + Vector2(cos(angle), sin(angle)) * BOSS_RADIUS
		var inner := BOSS_CENTRE + Vector2(cos(angle), sin(angle)) * BORE_RADIUS
		rim_top.append(vertices.size())
		vertices.append([outer.x, outer.y, top])
		rim_bottom.append(vertices.size())
		vertices.append([outer.x, outer.y, bottom])
		bore_top.append(vertices.size())
		vertices.append([inner.x, inner.y, top])
		bore_floor.append(vertices.size())
		vertices.append([inner.x, inner.y, floor_z])
	for facet in range(BOSS_FACETS):
		var next := (facet + 1) % BOSS_FACETS
		# The seating face, an annulus wound the way the plain boss's disc is.
		faces.append([bore_top[facet], rim_top[facet], rim_top[next]])
		faces.append([bore_top[facet], rim_top[next], bore_top[next]])
		# Outer wall and bottom disc, unchanged from the plain boss.
		faces.append([rim_top[facet], rim_bottom[facet], rim_bottom[next]])
		faces.append([rim_top[facet], rim_bottom[next], rim_top[next]])
		faces.append([centre_bottom, rim_bottom[next], rim_bottom[facet]])
		# The bore: its wall faces the axis, so it is the outer wall's winding
		# reversed, and its floor faces up into the void the way the seat does.
		faces.append([bore_top[facet], bore_floor[next], bore_floor[facet]])
		faces.append([bore_top[facet], bore_top[next], bore_floor[next]])
		faces.append([centre_floor, bore_floor[facet], bore_floor[next]])
	return {"vertices": vertices, "faces": faces}


func _plate_world_box() -> AABB:
	return AABB(Vector3(-PLATE_SPAN * 0.5, -PLATE_SPAN * 0.5, 0.0),
		Vector3(PLATE_SPAN, PLATE_SPAN, PLATE_THICKNESS))


## The boss's world bounds, grown by a micron. The plate's underside edges lie
## exactly in the plane of the boss's top, and edges are culled against these
## bounds by AABB.intersects, which rejects boxes that only touch — an
## unpadded box would cull away the very edges this fixture is about.
func _boss_world_box(lift: float) -> AABB:
	return AABB(
		Vector3(BOSS_CENTRE.x - BOSS_RADIUS, BOSS_CENTRE.y - BOSS_RADIUS,
			lift - BOSS_HEIGHT),
		Vector3(BOSS_RADIUS * 2.0, BOSS_RADIUS * 2.0, BOSS_HEIGHT)
	).grow(0.001)


## The plate as the evaluated solid, tilted the same five microradians about Y
## through x = 0.75 — half a grid pitch off the plate's x = 0 grid line. An axis
## on a grid line leaves every underside chord wholly above or wholly inside
## the boss's top-face plane; half a pitch off, the chords straddle it and
## exit through the top face mid-edge. As the SOLID, those underside edges are
## cast at the reference, which is the leg the unswapped tilted case never
## reaches.
func _tilted_plate_solid() -> Dictionary:
	var tilt := Basis(Vector3(0.0, 1.0, 0.0), BOARD_TILT_RAD)
	var axis_offset := Vector3(0.75, 0.0, 0.0)
	var data := _solid_from(_grid_plate())
	var tilted: Array = []
	for entry in (data.get("vertices", []) as Array):
		var point: Array = entry
		var moved: Vector3 = tilt * (Vector3(
			float(point[0]), float(point[1]), float(point[2])) - axis_offset) + axis_offset
		tilted.append([moved.x, moved.y, moved.z])
	data["vertices"] = tilted
	return data


## An ArrayMesh from worker mesh data, for mounting a body that the unswapped
## fixture evaluates as the solid.
func _mesh_from(mesh_data: Dictionary) -> ArrayMesh:
	var vertices: Array = mesh_data.get("vertices", [])
	var soup := PackedVector3Array()
	for entry in (mesh_data.get("faces", []) as Array):
		var face: Array = entry
		for corner in [0, 1, 2]:
			var point: Array = vertices[int(face[corner])]
			soup.append(Vector3(float(point[0]), float(point[1]),
				float(point[2])))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = soup
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Worker mesh data from an ArrayMesh, the other way round. The soup's own
## duplicate corners are left alone: build_solid welds edges by position, so
## the collider and its edge list are the same either way.
func _solid_from(mesh: ArrayMesh) -> Dictionary:
	var arrays: Array = mesh.surface_get_arrays(0)
	var soup: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var vertices: Array = []
	var faces: Array = []
	var index := 0
	while index + 2 < soup.size():
		for corner in [0, 1, 2]:
			var point: Vector3 = soup[index + corner]
			vertices.append([point.x, point.y, point.z])
		faces.append([index, index + 1, index + 2])
		index += 3
	return {"vertices": vertices, "faces": faces}


# ---------------------------------------------------------------------------
# What the fixture asserts about itself
# ---------------------------------------------------------------------------

func _triangle_count(mesh: ArrayMesh) -> int:
	var arrays: Array = mesh.surface_get_arrays(0)
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


## Underside triangle edges with one end inside a rim of that radius about the
## boss's axis and the other outside it: the edges that cut the rim, which is
## what the old fixture had none of. The bore's rim is asked the same way.
func _underside_edges_crossing_the_rim(mesh: ArrayMesh,
		radius: float = BOSS_RADIUS) -> int:
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
			var inside_a: bool = Vector2(a.x, a.y).distance_to(BOSS_CENTRE) < radius
			var inside_b: bool = Vector2(b.x, b.y).distance_to(BOSS_CENTRE) < radius
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
