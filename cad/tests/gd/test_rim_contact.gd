extends SceneTree
## A BORE OVER A HOLE IS A SEAT, NOT A CRASH.
##
## THE CASE. Every screwed post in an enclosure lands on a plate that has a
## hole under it. The boss's flat top and the plate's underside are designed
## to be coplanar; the boss is bored for the screw and the plate is drilled
## for the same screw; and when the bore is the wider of the two — a clearance
## bore under a thread pilot — the whole seating annulus lands on plate
## material and the two rims are concentric circles lying IN the shared plane.
## The bodies share no volume at all.
##
## WHY EVERY EARLIER RULE PASSES IT THROUGH. The plate's underside edges run
## over the boss, and where one crosses the bore's rim the crossing is SQUARE:
## the edge straddles the cylindrical wall it hit, there is boss material a
## probe step behind it, and the runs either side of it are one over open
## material and one over the open mouth. The per-crossing tests
## (geometry_checks.gd) and the contact-run rule (contact_runs.gd) each ask a
## question the rim answers the wrong way, and the seat is reported as
## interference on a design that is exactly right.
##
## THE MEASUREMENT THAT NAMES THE FAULT. A boss whose seat is at z = 0 is
## reported crossing at z = -0.0003 mm — three ten-thousandths of a millimetre
## through a plane the two bodies share. That is not a design error, it is the
## precision the numbers
## arrive in: physics hit positions are single precision, so on a
## hundred-millimetre part they are already good to about a ten-thousandth of
## a millimetre, which is the check's whole touch epsilon. NOISE_LIFT_MM is
## that measured offset, and the exactly-coplanar case beside it is the
## control that shows the lift is what does it.
##
## THE RULE UNDER TEST is rim_contact.gd: overlap is SHARED MATERIAL, so the
## four quadrants around the crossing — each one CONTACT_TOLERANCE_MM clear of
## both surfaces — are asked whether any of them is inside both bodies.
##
## THREE CONTROLS, EACH DEFEATING A DIFFERENT CHEAP FIX.
##
## 1. THE SUNK BOSS. The same bored boss driven 0.2 mm into the plate. Its
##    crossings sit in the very same plane as the cleared ones — the plate's
##    underside — so a fix that dropped crossings lying in a shared face, or
##    that widened the touch epsilon until the noise fitted inside it, clears
##    this too. It must still be reported, and with a depth.
## 2. THE SPIGOT THAT CUTS. A boss whose bore is NARROWER than the plate's
##    hole, carrying a locating spigot up into that hole with a radius past
##    the hole's own — so the plate's material really is inside the boss's,
##    in four slivers 0.2 mm deep. No edge spans a sliver, so the overlap is
##    reported with NO depth: a fix that dropped every crossing it could not
##    put a depth on ("found by ray parity, not by a crossing") clears this
##    one. Its own control is the same spigot narrowed to clear the hole.
## 3. THE PLATE TOO THIN TO PROBE. Four microns thick, pierced by two. No
##    sample can be placed a hundredth of a millimetre inside a plate that
##    thin, so nothing may be cleared by failing to find material in it — a
##    fix that simply cleared everything shallower than the contact tolerance
##    reports this one clean, which is the one thing it must never do.
##
## AND THE DECLARATION. A region drawn round a seat grades it TOUCHING and
## certified — the bodies were shown to share no material, which is a
## measurement and not a chord — while the same region drawn round the sunk
## boss excuses nothing.
##
## ORACLE: the pairs of reports. Every cleared case has a control that differs
## from it by geometry and by nothing else — the same mesh, the same
## triangulation, the same rims, the same edges crossing them.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const GeometryChecks := preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")
const MeshGauge := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")
const ExpectedContacts := preload("res://../../minerva-plugins/cad/ui/scripts/expected_contacts.gd")

## The plate standing in for the board: UNDERSIDE at z = 0, grid-triangulated
## so its edges chord the boss's rims rather than running along them.
const PLATE_SPAN := 24.0
const PLATE_CELLS := 24
const PLATE_THICKNESS := 1.6
## The screw hole through it: the four grid cells around the origin, so the
## hole is exactly [-1, 1] square and its rim is on grid lines. Its farthest
## point from the axis is the corner, HOLE_HALF * sqrt(2) = 1.414 mm.
const HOLE_HALF := 1.0

## The boss under it, coaxial with the hole.
const BOSS_RADIUS := 4.5
const BOSS_HEIGHT := 5.0
const BOSS_FACETS := 48
## The M3 clearance bore of the real tray boss, WIDER than the hole's corners:
## the whole seating annulus lands on plate material and the plate's hole rim
## hangs over the open mouth.
const CLEAR_BORE_RADIUS := 1.91

## Three ten-thousandths of a millimetre: three times the check's touch
## epsilon, a hundredth of a screw thread, and the precision a hit position
## carries.
const NOISE_LIFT_MM := 3e-4
## How far the control boss is driven INTO the plate.
const SINK_MM := 0.2

## The spigot boss: a narrow bore with a locating spigot standing up into the
## plate's hole. At SPIGOT_RADIUS the spigot is past the hole's straight edges
## (HOLE_HALF) and inside its corners, so it cuts the plate in four slivers
## 0.2 mm deep; at SPIGOT_CLEAR_RADIUS it clears the hole entirely.
const SPIGOT_BORE_RADIUS := 0.6
const SPIGOT_RADIUS := 1.2
const SPIGOT_CLEAR_RADIUS := 0.9
const SPIGOT_HEIGHT := 1.0

## The draft a moulded or printed boss carries: its outer wall leans out on
## the way down, so the wall's normal is TEN DEGREES off the plate's underside
## normal instead of square to it. That is the angle at which the two axes the
## rim rule samples along have to be orthogonalized against each other — an
## offset along one of two oblique axes eats the clearance from the other, and
## the sample ends up a fraction of the tolerance from a surface it was meant
## to be one whole tolerance clear of.
const BOSS_DRAFT_DEG := 10.0

## The plate no probe fits inside, and the bite taken out of it. Both are
## smaller than the contact tolerance the rim rule measures with, which is the
## point: it may not clear what it cannot probe.
const THIN_PLATE_MM := 0.004
const THIN_SINK_MM := 0.002

const REFERENCE_NAME := "board"
const NODE_PATH := "Assembly/Plate"
## The swapped fixture: the boss is the mounted reference, the plate the solid.
const BOSS_REFERENCE_NAME := "boss"
const BOSS_NODE_PATH := "Assembly/Boss"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== CAD Rim Contact Test (a clearance bore over a screw hole) ===\n")
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
	var plate := _hole_plate(PLATE_THICKNESS)
	check("fixture: the plate's hole lies wholly INSIDE the boss's clearance "
			+ "bore — the coaxial seat the bug is about, where every crossing "
			+ "is a rim in the shared plane and nothing overlaps",
			HOLE_HALF * sqrt(2.0) < CLEAR_BORE_RADIUS,
			"hole corner %f vs bore %f"
				% [HOLE_HALF * sqrt(2.0), CLEAR_BORE_RADIUS])
	check("fixture: the plate's underside edges really do cut the bore's rim "
			+ "and the boss's outer rim — without that no crossing is made "
			+ "at all and the suite would pass on an empty question",
			_underside_edges_crossing(plate, CLEAR_BORE_RADIUS) > 0
				and _underside_edges_crossing(plate, BOSS_RADIUS) > 0,
			"%d cut the bore, %d cut the rim" % [
				_underside_edges_crossing(plate, CLEAR_BORE_RADIUS),
				_underside_edges_crossing(plate, BOSS_RADIUS)])

	var gauge := MeshGauge.new()
	gauge.name = "MeshGauge"
	root.add_child(gauge)
	var checks: RefCounted = GeometryChecks.new()
	checks.attach(root)
	await process_frame

	var built := _mount_plate(gauge, checks, plate, PLATE_THICKNESS, "v1")
	check("fixture: the plate became one reference collider",
			built == 1, "built %d colliders" % built)

	# --- the designed seat ---------------------------------------------------
	checks.build_solid(_bored_boss(0.0, CLEAR_BORE_RADIUS))
	var flush: Dictionary = await _submit(gauge, checks)
	check("a clearance bore seated exactly in the plate's underside, its "
			+ "mouth over the plate's own hole, is a designed contact",
			bool(flush.get("checked", false))
				and int(flush.get("count", 0)) == 0
				and int(flush.get("point_count", 0)) == 0,
			"report = %s" % str(flush))

	# THE REPRO. The same seat three ten-thousandths of a millimetre out,
	# which is the precision the hit positions arrive in and not a design
	# error.
	checks.build_solid(_bored_boss(NOISE_LIFT_MM, CLEAR_BORE_RADIUS))
	var noisy: Dictionary = await _submit(gauge, checks)
	check("the same seat three ten-thousandths of a millimetre out — past "
			+ "the touch epsilon and inside the precision the positions "
			+ "carry — is still a contact",
			bool(noisy.get("checked", false))
				and int(noisy.get("count", 0)) == 0
				and int(noisy.get("point_count", 0)) == 0
				and bool(noisy.get("pass", false)),
			"report = %s" % str(noisy))
	check("and the seat is REPORTED as a contact on the plate's node rather "
			+ "than silently dropped: the reader still sees where the two "
			+ "bodies met",
			int(noisy.get("contact_count", 0)) >= 1
				and _contact_nodes(noisy).has(NODE_PATH)
				and int(noisy.get("contact_point_count", 0)) > 0,
			"report = %s" % str(noisy))

	# --- control 1: the same boss sunk into the plate -------------------------
	checks.build_solid(_bored_boss(SINK_MM, CLEAR_BORE_RADIUS))
	var sunk: Dictionary = await _submit(gauge, checks)
	check("the same boss driven two tenths of a millimetre INTO the plate is "
			+ "interference on the plate's own node — its crossings lie in "
			+ "the very plane the cleared ones do, so nothing that clears by "
			+ "plane clears this",
			bool(sunk.get("checked", false))
				and int(sunk.get("count", 0)) == 1
				and str(_first_pair(sunk).get("node", "")) == NODE_PATH
				and not bool(sunk.get("pass", true)),
			"report = %s" % str(sunk))
	# The depth here is a LATERAL chord — an underside edge entering the boss's
	# outer wall and leaving it again — and so is far larger than the sink it
	# stands for. It is asserted only as evidence that a run was measured at
	# all; what the number means is interference_report.gd's business.
	check("and it is reported WITH a measured run, not as an overlap nobody "
			+ "could put a number on",
			_penetration_of(sunk) >= SINK_MM,
			"penetration = %s" % str(_penetration_of(sunk)))

	# --- control 2: the spigot that cuts the hole ----------------------------
	checks.build_solid(_spigot_boss(0.0, SPIGOT_CLEAR_RADIUS))
	var clears: Dictionary = await _submit(gauge, checks)
	check("a locating spigot standing up through the hole with clearance all "
			+ "round is a contact, seat and spigot alike",
			bool(clears.get("checked", false))
				and int(clears.get("count", 0)) == 0
				and int(clears.get("point_count", 0)) == 0,
			"report = %s" % str(clears))

	# THE FALSIFIER FOR "DROP WHAT HAS NO DEPTH". The same spigot widened past
	# the hole's straight edges: the plate's material is inside the boss's in
	# four slivers, no edge spans one, and the overlap therefore arrives with
	# no measured depth at all.
	checks.build_solid(_spigot_boss(0.0, SPIGOT_RADIUS))
	var cuts: Dictionary = await _submit(gauge, checks)
	check("the same spigot widened past the hole's own edge — its bore "
			+ "narrower than the hole, its wall inside the plate's material — "
			+ "is interference, seat still exactly coplanar",
			bool(cuts.get("checked", false))
				and int(cuts.get("count", 0)) == 1
				and str(_first_pair(cuts).get("node", "")) == NODE_PATH
				and not bool(cuts.get("pass", true)),
			"report = %s" % str(cuts))

	# --- the drafted seat: two oblique surfaces, not two square ones ---------
	checks.build_solid(_drafted_boss(NOISE_LIFT_MM))
	var drafted: Dictionary = await _submit(gauge, checks)
	check("a boss whose outer wall carries ten degrees of draft is a contact "
			+ "at the same seat: the two surfaces meeting at the rim are "
			+ "oblique, and the samples are still one whole tolerance clear "
			+ "of each of them",
			bool(drafted.get("checked", false))
				and int(drafted.get("count", 0)) == 0
				and int(drafted.get("point_count", 0)) == 0,
			"report = %s" % str(drafted))

	# --- control 3: the plate no probe fits inside ---------------------------
	var thin := _hole_plate(THIN_PLATE_MM)
	_mount_plate(gauge, checks, thin, THIN_PLATE_MM, "thin")
	checks.build_solid(_bored_boss(THIN_SINK_MM, CLEAR_BORE_RADIUS))
	var too_thin: Dictionary = await _submit(gauge, checks)
	check("a plate four microns thick, bitten by two, is still reported: no "
			+ "sample can be put a hundredth of a millimetre inside it, and "
			+ "nothing may be cleared by failing to find material in it",
			bool(too_thin.get("checked", false))
				and int(too_thin.get("count", 0)) >= 1,
			"report = %s" % str(too_thin))

	await _declarations(gauge, checks, plate)
	await _swapped_roles(gauge, checks, plate)


## What a region drawn round the seat is worth, and what it is not.
func _declarations(gauge: Node, checks: RefCounted, plate: ArrayMesh) -> void:
	_mount_plate(gauge, checks, plate, PLATE_THICKNESS, "declared")
	checks.build_solid(_bored_boss(NOISE_LIFT_MM, CLEAR_BORE_RADIUS))
	var seat: Dictionary = await _submit(gauge, checks, [_declaration()])
	var seat_rows: Array = seat.get("expected_contacts", []) as Array
	var graded: Dictionary = (seat_rows[0] as Dictionary) \
		if not seat_rows.is_empty() else {}
	check("a region drawn round the seat GRADES it — touching, certified, "
			+ "excusing no overlap — and the check still passes, because "
			+ "nothing was excused to make it pass",
			seat_rows.size() == 1
				and bool(graded.get("touching", false))
				and bool(graded.get("certified", false))
				and int(seat.get("excluded_count", 0)) == 0
				and bool(seat.get("pass", false))
				and not bool(seat.get("advisory", false))
				and (seat.get("expected_contacts_unmatched", []) as Array).is_empty(),
			"report = %s" % str(seat))

	# THE FALSIFIER FOR THE DECLARATION. The same region, the same node, the
	# same reference — over a boss that is 0.2 mm into the plate.
	checks.build_solid(_bored_boss(SINK_MM, CLEAR_BORE_RADIUS))
	var sunk: Dictionary = await _submit(gauge, checks, [_declaration()])
	check("the same declaration over the SUNK boss excuses nothing: the pair "
			+ "is reported carrying declared_intended and the check fails",
			int(sunk.get("count", 0)) == 1
				and bool(_first_pair(sunk).get("declared_intended", false))
				and int(sunk.get("excluded_count", 0)) == 0
				and not bool(sunk.get("pass", true)),
			"report = %s" % str(sunk))


## The same seat cast the other way round — the boss mounted as the reference
## and the plate evaluated as the solid — because the rule has a copy on each
## leg and only this fixture exercises the solid one.
func _swapped_roles(gauge: Node, checks: RefCounted, plate: ArrayMesh) -> void:
	_mount_boss(gauge, checks, NOISE_LIFT_MM)
	checks.build_solid(_solid_from(plate))
	var noisy: Dictionary = await _submit(gauge, checks)
	check("swapped: the same seat is a contact when the PLATE's edges are the "
			+ "ones cast at the boss — the rule's other copy agrees with it",
			bool(noisy.get("checked", false))
				and int(noisy.get("count", 0)) == 0
				and int(noisy.get("point_count", 0)) == 0,
			"report = %s" % str(noisy))

	_mount_boss(gauge, checks, SINK_MM)
	checks.build_solid(_solid_from(plate))
	var sunk: Dictionary = await _submit(gauge, checks)
	check("swapped: and the sunk boss is interference either way round, on "
			+ "the boss's own node",
			bool(sunk.get("checked", false))
				and int(sunk.get("count", 0)) == 1
				and str(_first_pair(sunk).get("node", "")) == BOSS_NODE_PATH,
			"report = %s" % str(sunk))


# ---------------------------------------------------------------------------
# Mounting and submitting
# ---------------------------------------------------------------------------

## Mount the plate as the sole reference. The world box is grown by a micron
## for the same reason the flush suite's is: the edges this fixture is about
## lie in the box's own face, and AABB.intersects rejects boxes that only
## touch.
func _mount_plate(gauge: Node, checks: RefCounted, plate: ArrayMesh,
		thickness: float, tag: String) -> int:
	var built: int = gauge.build([{
		"mesh": plate,
		"transform": Transform3D.IDENTITY,
		"node": NODE_PATH,
		"reference": REFERENCE_NAME,
	}], "rim-contact-plate|%s" % tag)
	checks.set_records([{
		"name": REFERENCE_NAME,
		"pose": Transform3D.IDENTITY,
		"world_aabb": AABB(
			Vector3(-PLATE_SPAN * 0.5, -PLATE_SPAN * 0.5, 0.0),
			Vector3(PLATE_SPAN, PLATE_SPAN, thickness)).grow(0.001),
		"parts": [{
			"mesh": plate,
			"transform": Transform3D.IDENTITY,
			"node_path": NODE_PATH,
			"node": NODE_PATH,
		}],
	}])
	return built


## Mount the bored boss as the sole reference at this lift, for the swapped
## fixture. The digest carries the lift: every lift is a different body.
func _mount_boss(gauge: Node, checks: RefCounted, lift: float) -> int:
	var mesh := _mesh_from(_bored_boss(lift, CLEAR_BORE_RADIUS))
	var built: int = gauge.build([{
		"mesh": mesh,
		"transform": Transform3D.IDENTITY,
		"node": BOSS_NODE_PATH,
		"reference": BOSS_REFERENCE_NAME,
	}], "rim-contact-swapped|lift=%.8f" % lift)
	checks.set_records([{
		"name": BOSS_REFERENCE_NAME,
		"pose": Transform3D.IDENTITY,
		"world_aabb": AABB(
			Vector3(-BOSS_RADIUS, -BOSS_RADIUS, lift - BOSS_HEIGHT),
			Vector3(BOSS_RADIUS * 2.0, BOSS_RADIUS * 2.0, BOSS_HEIGHT)
		).grow(0.001),
		"parts": [{
			"mesh": mesh,
			"transform": Transform3D.IDENTITY,
			"node_path": BOSS_NODE_PATH,
			"node": BOSS_NODE_PATH,
		}],
	}])
	return built


func _submit(gauge: Node, checks: RefCounted,
		expected: Array = []) -> Dictionary:
	return await gauge.submit("interference", {
		"module": checks,
		"mask": int(MeshGauge.ALL_LAYERS),
		"reference": "",
		"node": "",
		"expected": expected,
	})


## A declaration of the seat: the plate's node, in a box round the boss.
func _declaration() -> Dictionary:
	var reach := BOSS_RADIUS + 1.0
	var parsed: Dictionary = ExpectedContacts.parse({"expected_contacts": [{
		"reference": REFERENCE_NAME,
		"node": NODE_PATH,
		"region_mm": {
			"min_mm": [-reach, -reach, -1.0],
			"max_mm": [reach, reach, 1.0],
		},
		"why": "the board seats on this boss",
	}]})
	return (parsed["entries"] as Array)[0]


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

## The plate: a closed body whose two big faces are a grid of triangles, with
## the four central cells removed and walled to make the screw hole. Built by
## hand rather than baked from CSG, because the triangulation IS the fixture —
## a CSG plate bakes to two triangles a face and no edge ever crosses a rim.
func _hole_plate(thickness: float) -> ArrayMesh:
	var soup := PackedVector3Array()
	var half := PLATE_SPAN * 0.5
	var pitch := PLATE_SPAN / float(PLATE_CELLS)
	for ix in range(PLATE_CELLS):
		for iy in range(PLATE_CELLS):
			var x0 := -half + pitch * ix
			var x1 := x0 + pitch
			var y0 := -half + pitch * iy
			var y1 := y0 + pitch
			if x0 >= -HOLE_HALF and x1 <= HOLE_HALF \
					and y0 >= -HOLE_HALF and y1 <= HOLE_HALF:
				continue
			# Underside (z = 0) and top face, wound opposite ways.
			_quad(soup, Vector3(x0, y0, 0.0), Vector3(x1, y0, 0.0),
				Vector3(x1, y1, 0.0), Vector3(x0, y1, 0.0))
			_quad(soup, Vector3(x0, y1, thickness), Vector3(x1, y1, thickness),
				Vector3(x1, y0, thickness), Vector3(x0, y0, thickness))
	# The four outer sides, two triangles each: nothing runs along them.
	_quad(soup, Vector3(-half, -half, 0.0), Vector3(half, -half, 0.0),
		Vector3(half, -half, thickness), Vector3(-half, -half, thickness))
	_quad(soup, Vector3(half, half, 0.0), Vector3(-half, half, 0.0),
		Vector3(-half, half, thickness), Vector3(half, half, thickness))
	_quad(soup, Vector3(half, -half, 0.0), Vector3(half, half, 0.0),
		Vector3(half, half, thickness), Vector3(half, -half, thickness))
	_quad(soup, Vector3(-half, half, 0.0), Vector3(-half, -half, 0.0),
		Vector3(-half, -half, thickness), Vector3(-half, half, thickness))
	# The hole's own four walls, wound the other way: they face INTO the hole,
	# which is outwards from the plate's material.
	var edge := HOLE_HALF
	_quad(soup, Vector3(edge, -edge, 0.0), Vector3(-edge, -edge, 0.0),
		Vector3(-edge, -edge, thickness), Vector3(edge, -edge, thickness))
	_quad(soup, Vector3(-edge, edge, 0.0), Vector3(edge, edge, 0.0),
		Vector3(edge, edge, thickness), Vector3(-edge, edge, thickness))
	_quad(soup, Vector3(edge, edge, 0.0), Vector3(edge, -edge, 0.0),
		Vector3(edge, -edge, thickness), Vector3(edge, edge, thickness))
	_quad(soup, Vector3(-edge, -edge, 0.0), Vector3(-edge, edge, 0.0),
		Vector3(-edge, edge, thickness), Vector3(-edge, -edge, thickness))
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


## The tray boss: a tube, bored clean through, whose seating face sits `lift`
## above the plate's underside. A positive lift drives it into the plate.
func _bored_boss(lift: float, bore_radius: float) -> Dictionary:
	return _lathe([
		Vector2(bore_radius, lift),
		Vector2(BOSS_RADIUS, lift),
		Vector2(BOSS_RADIUS, lift - BOSS_HEIGHT),
		Vector2(bore_radius, lift - BOSS_HEIGHT),
	])


## The same boss with BOSS_DRAFT_DEG of draft on its outer wall: it widens on
## the way down, so the wall this seat's crossings land on is oblique to the
## plate's underside rather than square to it.
func _drafted_boss(lift: float) -> Dictionary:
	var flare := BOSS_HEIGHT * tan(deg_to_rad(BOSS_DRAFT_DEG))
	return _lathe([
		Vector2(CLEAR_BORE_RADIUS, lift),
		Vector2(BOSS_RADIUS, lift),
		Vector2(BOSS_RADIUS + flare, lift - BOSS_HEIGHT),
		Vector2(CLEAR_BORE_RADIUS, lift - BOSS_HEIGHT),
	])


## The same boss with a locating spigot standing up out of its seating face
## into the plate's hole, bored clean through both.
func _spigot_boss(lift: float, spigot_radius: float) -> Dictionary:
	return _lathe([
		Vector2(SPIGOT_BORE_RADIUS, lift + SPIGOT_HEIGHT),
		Vector2(spigot_radius, lift + SPIGOT_HEIGHT),
		Vector2(spigot_radius, lift),
		Vector2(BOSS_RADIUS, lift),
		Vector2(BOSS_RADIUS, lift - BOSS_HEIGHT),
		Vector2(SPIGOT_BORE_RADIUS, lift - BOSS_HEIGHT),
	])


## Sweep a closed (radius, z) profile about the z axis into worker mesh data.
## The profile is traversed so that each segment's outward side is on its
## left, which is what makes the swept faces face out of the material; the
## band for one segment is wound the way the flush suite's hand-built boss
## winds its own outer wall.
func _lathe(profile: Array) -> Dictionary:
	var vertices: Array = []
	var faces: Array = []
	var rings: Array = []
	for entry in profile:
		var point: Vector2 = entry
		var ring: Array = []
		for facet in range(BOSS_FACETS):
			var angle := TAU * float(facet) / float(BOSS_FACETS)
			ring.append(vertices.size())
			vertices.append([point.x * cos(angle), point.x * sin(angle),
				point.y])
		rings.append(ring)
	for index in range(profile.size()):
		var near: Array = rings[index]
		var far: Array = rings[(index + 1) % profile.size()]
		for facet in range(BOSS_FACETS):
			var next := (facet + 1) % BOSS_FACETS
			faces.append([near[facet], far[facet], far[next]])
			faces.append([near[facet], far[next], near[next]])
	return {"vertices": vertices, "faces": faces}


## An ArrayMesh from worker mesh data, for mounting a body the unswapped
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
## duplicate corners are left alone: build_solid welds edges by position.
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
# What the fixture and the reports say about themselves
# ---------------------------------------------------------------------------

## Underside triangle edges with one end inside a circle of that radius about
## the axis and the other outside it: the edges that cut that rim.
func _underside_edges_crossing(mesh: ArrayMesh, radius: float) -> int:
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
			var in_a: bool = Vector2(a.x, a.y).length() < radius
			var in_b: bool = Vector2(b.x, b.y).length() < radius
			if in_a != in_b:
				crossing += 1
	return crossing


func _first_pair(report: Dictionary) -> Dictionary:
	var pairs: Array = report.get("pairs", []) as Array
	return (pairs[0] as Dictionary) if not pairs.is_empty() else {}


## The nodes the report says the two bodies merely TOUCH on.
func _contact_nodes(report: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for entry in (report.get("contacts", []) as Array):
		out.append(str((entry as Dictionary).get("node", "")))
	return out


## The deepest run reported over every pair, or 0 when nothing was reported.
func _penetration_of(report: Dictionary) -> float:
	var deepest := 0.0
	for entry in (report.get("pairs", []) as Array):
		deepest = maxf(deepest,
			float((entry as Dictionary).get("penetration_mm", 0.0)))
	return deepest
