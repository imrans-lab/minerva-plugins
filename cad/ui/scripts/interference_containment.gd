extends "interference_world.gd"
## interference_containment.gd — the overlap no edge crossing can see.
##
## Two closed bodies overlap either by crossing each other's surfaces or by
## one lying wholly inside the other. The second case crosses nothing, so the
## edge walk in geometry_checks.gd finds nothing and only ray parity — an odd
## number of surfaces between a point and infinity means the point is buried —
## settles it. This script holds that pass: both directions of it, and the
## probes it is made of.
##
## A PROBE HAS TO EARN ITS ANSWER. A direction is asked only when the
## containing body's world box actually holds the other one; a candidate point
## is moved off the vertex it came from towards its own body's centre; and it
## is dropped while a surface of the OTHER body is within TOUCH_EPSILON_MM of
## it, so a designed flush contact is never settled by a ray cast along the
## plane the two bodies share. A body whose every candidate was rejected is
## recorded as undecidable rather than cleared.
##
## The rays go through mesh_gauge for the references — scoped by mask to a
## reference and by name to one of its nodes, so no neighbour can vouch for a
## probe — and through the solid's own space, which is
## interference_world.gd's, for the solid.
##
## THE RIM RULE'S PLUMBING IS HERE TOO, for the same reason: it is the only
## layer that holds both spaces' probes. rim_contact.gd owns the rule — a
## crossing where a wall of one body meets a face of the other is an overlap
## only if the two share material near it — and what is here is the probes it
## asks with, the budget it runs under, and what a verdict does. The walk that
## calls it is geometry_checks.gd's, on both cast directions.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: extended by scripts/geometry_checks.gd, whose walk calls
## _containment() when it found no crossing at all, whose per-crossing tests
## use the same parity probes, and whose two legs both ask the rim rule.


## The rule that tells them apart when the edge crosses the RIM of a bore in a
## landing face — the mouth the screw goes through, which every per-crossing
## test and the contact-run rule call a penetration because the crossing is
## square and the material behind it is real. It is not: the two bodies meet
## on the plane and share no volume.
const _RimContact: Script = preload("rim_contact.gd")


## Crossings the rim rule is asked about in one check. It is only ever asked
## about a crossing every cheaper test has already called a penetration, so a
## clean design spends a handful; a body genuinely buried in another produces
## thousands, and there the budget stops the walk from paying for a question
## whose answer cannot change (the pair is interference either way). Past it
## every crossing is KEPT and the report says it was truncated.
const MAX_RIM_TESTS: int = 512


## Contacts within this distance of a surface are the same surface: a designed
## flush fit, not an overlap. Float precision on a hundred-millimetre part is
## an order of magnitude finer than this.
const TOUCH_EPSILON_MM: float = 0.0001
## How far past a crossing the next cast starts. Large enough to clear the
## triangle just hit, small enough that it cannot step over a thin wall.
const CROSSING_ADVANCE_MM: float = 0.0002


## The gauge sphere the parity probe places, millimetres — its DIAMETER, which
## is what mesh_gauge reads a sphere's size as (its contact rays reach half of
## it). The probe sits at the middle of the material's run, so the sphere fits
## only when that run exceeds this diameter; material no thicker than it cannot
## be probed at all — the sphere touches a wall and the gauge reports a
## contact rather than "inside" — so a crossing through it is KEPT rather
## than cleared: unprovable is not clean.
const PARITY_SPHERE_MM: float = 0.002


## Casts allowed for one parity ray before it gives up and answers "unknown".
const MAX_PARITY_CASTS: int = 64
## Points tried as a parity probe before a direction gives up. Two things
## reject a candidate — a surface of the other body within TOUCH_EPSILON_MM of
## it, and a point that is not inside its own body — and a plate that is mostly
## mounting hole can reject a long run of them, so the list is longer than the
## handful one convex body would need.
const MAX_PROBE_POINTS: int = 16
## How far a probe is moved off its vertex, towards the centre of its own
## body's box, as a fraction of that box's smallest extent. Far enough to
## leave a contact plane, near enough to stay inside a 1.6 mm board.
const PROBE_INSET_FRACTION: float = 0.25
## The six axis directions a probe is tested along for a surface it is resting
## on. Both senses of each axis: a contact plane is only reached from one side.
const _PROBE_DIRECTIONS: Array[Vector3] = [
	Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD,
	Vector3.UP, Vector3.DOWN,
]


# ---------------------------------------------------------------------------
# Containment — the case no edge crossing can see
# ---------------------------------------------------------------------------

## One body wholly inside the other crosses nothing. Both directions are asked
## once: a point inside the solid's material against the references, and a
## point inside each reference part against the solid. With no crossings
## anywhere, one interior point settles it — the bodies are either wholly in
## or wholly out.
##
## THREE THINGS DECIDE WHICH POINT. A direction is only asked at all when the
## containing body's world box actually holds the other one, so a lid resting
## on a board is never asked whether the shell is inside the board. The point
## is then moved off a vertex towards its own body's centre and dropped while
## a surface of the OTHER body is still within TOUCH_EPSILON_MM of it, so a
## designed flush contact is never settled by a ray cast along the plane the
## two bodies share. And it is dropped again unless it is verifiably inside
## its OWN body: the step is a fraction of a world box and a body is not
## convex, so a vertex on the rim of a mounting hole insets INTO the hole —
## where a locating pin standing through that hole would read as a body the
## reference lies entirely inside — and the probe therefore has to be inside
## that node, not merely inside SOME node of the same reference. Every
## rejection tries the next point; only a verified point may answer.
##
## AND WHEN NO POINT ANSWERS. A body whose every candidate was rejected has
## not been cleared: the question was asked and nothing could answer it. It is
## recorded in `_undecided` and reported as undecidable, because a node that
## really is buried would otherwise be indistinguishable from one that is not.
func _containment(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	solid_state: PhysicsDirectSpaceState3D,
	pairs: Dictionary,
	mask: int,
	reference_scope: String,
	node_scope: String
) -> void:
	if _solid_edges.size() >= 2 and solid_state != null \
			and _reference_encloses_solid(reference_scope):
		# ONE QUESTION PER ENCLOSING NODE. Two bodies can both hold the solid —
		# two nodes of one reference, overlapping — and "is the solid inside
		# this one" is a different question for each: answering it for the
		# first and moving on leaves the second's clearance rows to pass on an
		# unsigned distance. Every candidate rejected is not a clean answer
		# either — the question was asked and nothing could answer it — so a
		# node nobody could settle is reported undecidable rather than left
		# silent.
		var enclosing_nodes := _enclosing_nodes(reference_scope)
		var answered := {}
		var tried := 0
		for probe in _probe_points(_solid_edges, _solid_bounds):
			tried += 1
			# Inside the SOLID's own material, or it says nothing about where
			# the solid is: an edge endpoint of a shell insets into the cavity
			# the shell encloses as readily as into its wall.
			if _parity_inside_solid(solid_state, probe) != 1:
				continue
			if _touches_references(gauge, state, mask, reference_scope, probe):
				continue
			for entry in enclosing_nodes:
				var candidate: Dictionary = entry
				var enclosing := str(candidate["reference"])
				var node_path := str(candidate["node"])
				var key := _pair_key(enclosing, node_path)
				if answered.has(key):
					continue
				var ref_mask := mask
				if not enclosing.is_empty():
					ref_mask = int(gauge.call("mask_for", enclosing))
				# The gauge's own parity test, reached through the smallest
				# gauge it will accept — a pin that touches nothing and still
				# does not fit is a pin buried in material — asked of ONE NODE
				# at a time, which is the only scope that can tell two
				# overlapping bodies of one reference apart.
				var verdict: Dictionary = gauge.call("run_now", state, "gauge", {
					"shape": "sphere",
					"size": Vector3(0.002, 0.0, 0.0),
					"at": probe,
					"mask": ref_mask,
					"reference": enclosing,
					"node": node_path,
				})
				_casts += 1
				# An ERROR is not an answer. The gauge says so when a ray
				# crossed more surfaces than its budget allows — a deeply
				# layered node — and treating that as "not inside" reports a
				# buried solid as clean. Leave this node open and try the next
				# probe.
				if verdict.has("error"):
					continue
				answered[key] = true
				if str(verdict.get("reason", "")) != "inside_solid":
					continue
				var named_node := node_path
				var named_reference := enclosing
				if named_node.is_empty():
					# A record with no parts to enumerate: the nearest surface
					# from the probe names what it is inside. This is the ONE
					# cast in the module that starts inside material, against
					# constraint 2 above, and it is safe precisely because it
					# is not a crossing test — every reference collider
					# carries backface_collision, so a ray leaving buried
					# material reports the wall it exits through.
					var reach := _scene_reach()
					var found: Dictionary = gauge.call("run_now", state, "raycast", {
						"from": probe,
						"to": probe + Vector3.RIGHT * reach,
						"mask": ref_mask,
						"reference": enclosing,
					})
					named_node = str(found.get("node", ""))
					named_reference = str(found.get("reference", enclosing))
				_absorb(pairs, {
					"point": probe,
					"node": named_node,
					"reference": named_reference,
					"distance": 0.0,
					"containment": "the solid lies entirely inside this node",
				}, node_scope)
			if answered.size() == enclosing_nodes.size():
				break
		for entry in enclosing_nodes:
			var candidate: Dictionary = entry
			if answered.has(_pair_key(str(candidate["reference"]),
					str(candidate["node"]))):
				continue
			_undecided.append({
				"reference": str(candidate["reference"]),
				"node": str(candidate["node"]),
				"reason": ("this body's bounds hold the whole solid, but "
					+ "none of the %d probe points taken from the solid's own "
					+ "edges could be verified inside its own material, so "
					+ "whether the solid is buried in it was not decided")
					% tried,
			})

	if solid_state == null:
		return
	for record_entry in _records:
		var record: Dictionary = record_entry
		var reference_name := str(record.get("name", ""))
		if not reference_scope.is_empty() and reference_name != reference_scope:
			continue
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		for part_entry in record.get("parts", []):
			var part: Dictionary = part_entry
			var mesh: Mesh = part.get("mesh", null)
			if mesh == null:
				continue
			var node_path := str(part.get("node_path", part.get("node", "")))
			if not _node_matches(node_path, node_scope):
				continue
			var xform: Transform3D = pose \
				* (part.get("transform", Transform3D.IDENTITY) as Transform3D)
			var box: AABB = _ReferenceMeshes.transform_aabb(xform, mesh.get_aabb())
			if not _solid_bounds.encloses(box):
				continue
			var candidates := _probe_points(_mesh_vertices(mesh, xform), box)
			var decided_node := false
			for probe in candidates:
				if _touches_solid(solid_state, probe):
					continue
				# Inside THIS NODE's own material, or it says nothing about
				# where the node is. A vertex on a mounting hole's rim insets
				# into the hole, and a pin standing through that hole — a
				# different node of the same reference — would otherwise vouch
				# for the probe and report this node as buried. An
				# undecidable probe is skipped the same way: it settles
				# nothing, and a node none of its probes can settle is
				# reported undecided below.
				if _inside_reference(
						gauge, state, probe, reference_name, node_path) != 1:
					continue
				# Is that verified point inside the SOLID? An error here — a
				# ray crossing more surfaces than the parity budget allows —
				# is not "outside": treating it as one reports a node that may
				# be buried in the solid as clean. Try the next probe; if none
				# of them can be read, the node is undecidable.
				var verdict := _parity_inside_solid(solid_state, probe)
				if verdict < 0:
					continue
				decided_node = true
				if verdict != 1:
					break
				_absorb(pairs, {
					"point": probe,
					"node": node_path,
					"reference": reference_name,
					"distance": 0.0,
					"containment": "this node lies entirely inside the solid",
				}, node_scope)
				break
			if not decided_node:
				_undecided.append({
					"reference": reference_name,
					"node": node_path,
					"reason": ("the solid's bounds hold this node, but none "
						+ "of its %d probe points could be verified inside "
						+ "its own material (every one landed in a hole, a "
						+ "cavity or on a face it shares with the solid), so "
						+ "whether it is buried in the solid was not decided")
						% candidates.size(),
				})


## EVERY body whose world box holds the whole solid, as {reference, node} —
## the bodies a containment question about the solid is ABOUT.
##
## PER NODE, not per reference. Two overlapping nodes of one reference both
## hold it and the question is open for both: parity scoped to the reference
## answers "inside something of this reference" and says nothing about which,
## so the second node's clearance rows would pass on a distance nobody could
## sign. A record whose parts carry no usable box falls back to one row for
## the reference itself, and an empty result falls back to the scope the
## caller asked with — a question that was asked always names something.
func _enclosing_nodes(reference_scope: String) -> Array:
	var out: Array = []
	for entry in _records:
		var record: Dictionary = entry
		var name := str(record.get("name", ""))
		if not reference_scope.is_empty() and name != reference_scope:
			continue
		var found := false
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		for part_entry in record.get("parts", []):
			var part: Dictionary = part_entry
			var mesh: Mesh = part.get("mesh", null)
			if mesh == null:
				continue
			var xform: Transform3D = pose \
				* (part.get("transform", Transform3D.IDENTITY) as Transform3D)
			if not _ReferenceMeshes.transform_aabb(xform, mesh.get_aabb()) \
					.encloses(_solid_bounds):
				continue
			out.append({"reference": name,
				"node": str(part.get("node_path", part.get("node", "")))})
			found = true
		if not found and _record_world_box(record).encloses(_solid_bounds):
			out.append({"reference": name, "node": ""})
	if out.is_empty():
		out.append({"reference": reference_scope, "node": ""})
	return out


## Could the solid be inside a reference at all? Only a reference whose world
## box holds the whole solid can contain it. Without this gate a shell over a
## board — whose box holds neither — is asked a parity question about a probe
## sitting on the contact plane, and answers it by float luck.
func _reference_encloses_solid(reference_scope: String) -> bool:
	for entry in _records:
		var record: Dictionary = entry
		if not reference_scope.is_empty() \
				and str(record.get("name", "")) != reference_scope:
			continue
		if _record_world_box(record).encloses(_solid_bounds):
			return true
	return false


## A reference's world bounds: the box the record carries, or the union of its
## parts' transformed mesh boxes when it carries none.
func _record_world_box(record: Dictionary) -> AABB:
	var world: AABB = record.get("world_aabb", AABB())
	if world.size.length_squared() > 0.0:
		return world
	var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
	var box := AABB()
	var have := false
	for part_entry in record.get("parts", []):
		var part: Dictionary = part_entry
		var mesh: Mesh = part.get("mesh", null)
		if mesh == null:
			continue
		var xform: Transform3D = pose \
			* (part.get("transform", Transform3D.IDENTITY) as Transform3D)
		var part_box: AABB = _ReferenceMeshes.transform_aabb(xform, mesh.get_aabb())
		box = part_box if not have else box.merge(part_box)
		have = true
	return box


## Probe points for a body, world millimetres: up to MAX_PROBE_POINTS of its
## own points, spread across the list rather than taken from one corner, each
## moved towards the centre of `box` so it is off any face it rests on.
func _probe_points(points: PackedVector3Array, box: AABB) -> PackedVector3Array:
	var out := PackedVector3Array()
	if points.is_empty():
		return out
	var step: int = maxi(1, points.size() / MAX_PROBE_POINTS)
	var index := 0
	while index < points.size() and out.size() < MAX_PROBE_POINTS:
		out.append(_inset(points[index], box))
		index += step
	return out


## `point` moved towards the centre of `box`, into the material of the body
## the box describes. The step is a quarter of the box's smallest extent, so a
## thin part keeps its probe inside itself; a point already nearer the centre
## than that becomes the centre.
func _inset(point: Vector3, box: AABB) -> Vector3:
	var centre := box.get_center()
	var step: float = minf(box.size.x, minf(box.size.y, box.size.z)) \
		* PROBE_INSET_FRACTION
	var toward := centre - point
	if step <= 0.0 or toward.length() <= step:
		return centre
	return point + toward.normalized() * step


## Every vertex of `mesh` in world millimetres.
func _mesh_vertices(mesh: Mesh, xform: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for surface in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		for vertex in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array):
			out.append(xform * vertex)
	return out


# ---------------------------------------------------------------------------
# The rim rule — the mouth of a bore in a landing face
# ---------------------------------------------------------------------------

## Is this crossing of a REFERENCE surface a rim touch rather than an overlap?
## The rule is rim_contact.gd's; what is here is the two spaces it needs, the
## budget, and what a verdict does — a proven touch is recorded as a contact,
## and a proven overlap closes the gate for the rest of that pair, whose
## crossings the rule can no longer change.
func _rim_touching_reference(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	solid_state: PhysicsDirectSpaceState3D,
	point: Vector3,
	hit: Dictionary,
	direction: Vector3,
	node_scope: String
) -> bool:
	if solid_state == null:
		return false
	var reference_name := str(hit.get("reference", ""))
	var node_path := str(hit.get("node", ""))
	if not _rim_gate_open(reference_name, node_path):
		return false
	var verdict: int = _RimContact.classify(
		point, hit.get("normal", Vector3.ZERO), direction,
		_solid_probe.bind(solid_state),
		_reference_inside.bind(gauge, state, reference_name, node_path),
		_solid_inside.bind(solid_state),
		_Expected.CONTACT_TOLERANCE_MM)
	return _rim_verdict(verdict, point, reference_name, node_path, node_scope)


## The same question with the roles swapped: the crossed surface is the
## solid's and the body resting on it is one node of one reference.
func _rim_touching_solid(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	solid_state: PhysicsDirectSpaceState3D,
	point: Vector3,
	hit: Dictionary,
	direction: Vector3,
	reference_name: String,
	node_path: String,
	node_scope: String
) -> bool:
	if not _rim_gate_open(reference_name, node_path):
		return false
	var verdict: int = _RimContact.classify(
		point, hit.get("normal", Vector3.ZERO), direction,
		_reference_probe.bind(gauge, state, reference_name, node_path),
		_solid_inside.bind(solid_state),
		_reference_inside.bind(gauge, state, reference_name, node_path),
		_Expected.CONTACT_TOLERANCE_MM)
	return _rim_verdict(verdict, point, reference_name, node_path, node_scope)


## May the rule be asked about a crossing of this pair? Not once the pair is
## known to overlap — every remaining crossing of it is interference whatever
## the rule says — and not past the budget, which is announced as a limit so
## the report reads TRUNCATED rather than clean.
func _rim_gate_open(reference_name: String, node_path: String) -> bool:
	if _rim_crossing.has(_pair_key(reference_name, node_path)):
		return false
	_rim_tests += 1
	if _rim_tests > MAX_RIM_TESTS:
		if _rim_tests == MAX_RIM_TESTS + 1:
			_limits.append(("the rim rule was asked about the first %d "
				+ "crossings; past that every crossing is reported without "
				+ "being asked whether the bodies merely meet there")
				% MAX_RIM_TESTS)
		return false
	return true


## What a verdict does. TOUCHING drops the crossing and records the contact,
## so a declaration can still grade it and a reader can still see where the
## bodies met. CROSSING closes the gate for the pair. UNPROVEN keeps the
## crossing and changes nothing: an answer the rule could not reach is not
## evidence that a part is clear.
func _rim_verdict(verdict: int, point: Vector3, reference_name: String,
		node_path: String, node_scope: String) -> bool:
	if verdict == _RimContact.Verdict.CROSSING:
		_rim_crossing[_pair_key(reference_name, node_path)] = true
		return false
	if verdict != _RimContact.Verdict.TOUCHING:
		return false
	_absorb_contact(point, reference_name, node_path, node_scope)
	return true


## One ray into the solid, in the argument order the rim rule's probe takes.
func _solid_probe(from: Vector3, to: Vector3,
		solid_state: PhysicsDirectSpaceState3D) -> Dictionary:
	return _solid_ray(solid_state, from, to)


## The same against ONE node of one reference, so no neighbour can stand in
## for the body this crossing is about. Empty when nothing was hit, so both
## probes answer the rule in one shape.
func _reference_probe(from: Vector3, to: Vector3, gauge: Object,
		state: PhysicsDirectSpaceState3D, reference_name: String,
		node_path: String) -> Dictionary:
	_casts += 1
	var hit: Dictionary = gauge.call("run_now", state, "raycast", {
		"from": from,
		"to": to,
		"mask": int(gauge.call("mask_for", reference_name)),
		"reference": reference_name,
		"node": node_path,
	})
	return hit if bool(hit.get("hit", false)) else {}


## Is this sample in the material of that one node? The contact-run rule's
## argument order — the point first — around _inside_reference's tri-state.
func _reference_inside(
	point: Vector3,
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	reference_name: String,
	node_path: String
) -> int:
	return _inside_reference(gauge, state, point, reference_name, node_path)


## Is this sample in the solid's material? The contact-run rule's argument
## order around _parity_inside_solid's tri-state.
func _solid_inside(
	point: Vector3,
	solid_state: PhysicsDirectSpaceState3D
) -> int:
	return _parity_inside_solid(solid_state, point)


## Is a surface of the solid within TOUCH_EPSILON_MM of `point`? Six rays, one
## along each axis: a contact plane is reached from one side only, so a probe
## resting on a floor is seen by the ray that goes down into it.
func _touches_solid(solid_state: PhysicsDirectSpaceState3D, point: Vector3) -> bool:
	var reach := _solid_bounds.size.length() + 10.0
	for direction in _PROBE_DIRECTIONS:
		var hit := _solid_ray(solid_state, point, point + direction * reach)
		if hit.is_empty():
			continue
		if point.distance_to(hit.get("position", Vector3.ZERO)) <= TOUCH_EPSILON_MM:
			return true
	return false


## Is `point` inside the material of ONE node of `reference_name`? 1 yes,
## 0 no, -1 undecidable — the same tri-state _parity_inside_solid gives for
## the solid, because the gauge answers with an error rather than a verdict
## when a parity ray crosses more surfaces than its budget allows, and an
## error collapsed to "outside" would clear a body nobody could read. The
## gauge's own parity test through the smallest gauge it will accept — a pin
## that touches nothing and still does not fit is a pin buried in material —
## scoped to that reference by mask and to that node by name, so neither a
## neighbouring reference nor a neighbouring node of the same one can vouch
## for a probe.
func _inside_reference(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	point: Vector3,
	reference_name: String,
	node_path: String
) -> int:
	_casts += 1
	var verdict: Dictionary = gauge.call("run_now", state, "gauge", {
		"shape": "sphere",
		"size": Vector3(PARITY_SPHERE_MM, 0.0, 0.0),
		"at": point,
		"mask": int(gauge.call("mask_for", reference_name)),
		"reference": reference_name,
		"node": node_path,
	})
	if verdict.has("error"):
		return -1
	return 1 if str(verdict.get("reason", "")) == "inside_solid" else 0


## The same question against the references, through the gauge's own space.
func _touches_references(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	mask: int,
	reference_scope: String,
	point: Vector3
) -> bool:
	var reach := _scene_reach()
	for direction in _PROBE_DIRECTIONS:
		_casts += 1
		var hit: Dictionary = gauge.call("run_now", state, "raycast", {
			"from": point,
			"to": point + direction * reach,
			"mask": mask,
			"reference": reference_scope,
		})
		if bool(hit.get("hit", false)) \
				and float(hit.get("distance", reach)) <= TOUCH_EPSILON_MM:
			return true
	return false


## Is `point` inside the solid's material? 1 yes, 0 no, -1 undecidable.
## Two rays that agree settle it; a third breaks a tie, which happens when one
## ray leaves along a surface it can neither enter nor leave cleanly.
func _parity_inside_solid(solid_state: PhysicsDirectSpaceState3D, point: Vector3) -> int:
	var reach := _solid_bounds.size.length() + 10.0
	var first := _solid_parity(solid_state, point, Vector3.RIGHT, reach)
	var second := _solid_parity(solid_state, point, Vector3.BACK, reach)
	if first < 0 or second < 0:
		return -1
	if first == second:
		return first
	return _solid_parity(solid_state, point, Vector3.UP, reach)


## Parity of the surfaces one ray crosses. The solid is a single closed body
## with no duplicated faces — unlike a stack of reference plates, where two
## coincident triangles are two crossings and mesh_gauge has to walk the band
## by exclusion — so counting nearest hits and stepping past each one is exact
## here.
func _solid_parity(
	solid_state: PhysicsDirectSpaceState3D,
	from: Vector3,
	direction: Vector3,
	reach: float
) -> int:
	var crossings := 0
	var origin := from
	var target := from + direction * reach
	for _cast in range(MAX_PARITY_CASTS):
		var hit := _solid_ray(solid_state, origin, target)
		if hit.is_empty():
			return crossings % 2
		var point: Vector3 = hit.get("position", Vector3.ZERO)
		crossings += 1
		var next := point + direction * CROSSING_ADVANCE_MM
		# The step must make progress in world coordinates; when it stops
		# doing so the count is a truncated prefix and its parity means
		# nothing.
		if from.distance_to(next) <= from.distance_to(origin):
			return -1
		origin = next
	return -1
