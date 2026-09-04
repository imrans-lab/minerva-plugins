extends RefCounted
## geometry_checks.gd — does the evaluated solid run into anything?
##
## An enclosure is designed AGAINST foreign geometry: a board, a connector, a
## screw. The question that matters on every keystroke is not "how big is that
## hole" but "does my shell clip the board" — and an LLM iterating on the DSL
## has no eyes, so the answer has to arrive with the evaluation rather than
## being asked for. Every evaluation runs this check; the report rides in the
## eval result, the points are drawn in the panes, and
## minerva_cad_check_interference asks the same question on demand.
##
## THE TEST, AND WHY IT IS COMPLETE FOR CLOSED MESHES
##
## Two closed bodies overlap if and only if either (a) a triangle of one
## crosses a triangle of the other, or (b) one lies entirely inside the other.
## The intersection of two non-coplanar triangles is a segment whose endpoints
## each lie on an EDGE of one of them, so (a) is found by casting every edge of
## the solid as a segment against the reference colliders, and every edge of an
## overlapping reference triangle against a collider built from the solid.
## Both directions are needed: a shell whose boss pokes into a board has solid
## edges crossing board faces; a board post standing through a large flat shell
## face has reference edges crossing solid faces and no solid edge crossing
## anything. (b) crosses no edge at all and is closed by ray parity — an odd
## number of surfaces between a point and infinity means the point is buried.
##
## Contacts closer than a tenth of a micrometre are reported as TOUCHING, not
## as interference: a shell resting on a board shares a plane, and a check that
## calls a designed contact an error is a check the reader learns to ignore.
##
## THREE CONSTRAINTS, EACH ONE MEASURED BY ITS FAILURE
##
## 1. RAYS ONLY. intersect_shape and intersect_point against a trimesh do not
##    answer here (see mesh_gauge.gd's constraint 4); intersect_ray does. Every
##    question below is a ray.
## 2. RAYS START OUTSIDE. Each cast begins at a point on an edge of one body
##    and runs to the other end of that edge, so no ray is ever launched from a
##    synthetic origin buried in material — hit_from_inside does not apply to
##    concave shapes, and a ray that starts inside a wall reports nothing.
## 3. THE SOLID'S COLLIDER IS REBUILT EVERY EVALUATION. The DSL solid changes
##    on every keystroke and has no path to key a cache on; the references are
##    the only side that caches (mesh_gauge, on its digest).
##
## WHERE IT RUNS. Inside mesh_gauge's physics step, through its job queue: a
## space's direct state may only be dereferenced there. The gauge dispatches
## the "interference" job straight back to this module (`run_check`), so both
## spaces — the references' world and this module's own solid world — are
## queried inside one step.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/geometry_checks.gd") from CADPanel.gd.

const _Measurement: Script = preload("panel_measurement.gd")
const _ReferenceMeshes: Script = preload("reference_meshes.gd")

## Child of a MeshRoot holding the red crosses. Freed and rebuilt on every
## check, so a clean evaluation clears the previous one's markers.
const MARKER_NODE_NAME: String = "InterferenceMarkers"
## Nothing else in the scene is this colour: references are grey outlines, the
## solid is amber, a missing reference is orange.
const MARKER_COLOR: Color = Color(0.95, 0.12, 0.12, 1.0)
## Arm length of one marker cross, in millimetres. Small enough to point at a
## feature rather than cover it.
const MARKER_ARM_MM: float = 1.5
## Markers drawn at most. A shell buried in a board can produce thousands of
## crossings and drawing them all says nothing more than drawing two hundred.
const MAX_MARKERS: int = 200

## Contacts within this distance of a surface are the same surface: a designed
## flush fit, not an overlap. Float precision on a hundred-millimetre part is
## an order of magnitude finer than this.
const TOUCH_EPSILON_MM: float = 0.0001
## How far past a crossing the next cast starts. Large enough to clear the
## triangle just hit, small enough that it cannot step over a thin wall.
const CROSSING_ADVANCE_MM: float = 0.0002
## Crossings counted along one edge. An edge threading more walls than this is
## pathological; the crossings found still count as interference, and only the
## penetration measurement is given up.
const MAX_CROSSINGS_PER_EDGE: int = 16
## Casts allowed for one parity ray before it gives up and answers "unknown".
const MAX_PARITY_CASTS: int = 64
## Points listed per interfering pair. The pair's own point_count is the whole
## number; this bounds what travels in the reply.
const MAX_POINTS_PER_PAIR: int = 8

## Edges of the solid cast in one check, and reference triangles examined.
## Both are ceilings on a pathological document, not a sampling scheme: when
## either is hit the report says so in `sampling` and the count is a floor.
const MAX_SOLID_EDGES: int = 60000
const MAX_REFERENCE_TRIANGLES: int = 400000

## Every collision layer at once — the unscoped mask, matching mesh_gauge.
const ALL_LAYERS: int = 0xFFFFFFFF


## The solid's own physics world. Its collider is rebuilt per evaluation, so it
## must not share the gauge's space: a stale solid body in the space the
## measurement verbs query would answer their rays as if it were geometry.
var _viewport: SubViewport = null
var _solid_body: StaticBody3D = null
## Triangle corners of the solid, world millimetres, three entries per face.
var _solid_faces: PackedVector3Array = PackedVector3Array()
## Unique edges of the solid, two entries per edge, world millimetres.
var _solid_edges: PackedVector3Array = PackedVector3Array()
var _solid_bounds: AABB = AABB()
## Increments on every actual solid rebuild — the observable that proves the
## collider is not cached across evaluations.
var _solid_generation: int = 0

## The reference records the running check was started with: name, pose and
## converted parts. Snapshotted before the job is submitted, because the
## document may change while the job waits for a physics step.
var _records: Array = []
## Points the last check found, world millimetres, for the markers.
var _marker_points: PackedVector3Array = PackedVector3Array()
## Ray casts spent by the running check — reported, because the cost of this
## check is the one thing a per-evaluation feature has to be honest about.
var _casts: int = 0
## Ceilings the running check hit, in prose.
var _limits: PackedStringArray = PackedStringArray()


## The reference records this check runs against — {name, pose, parts} as the
## panel reports them. Snapshotted before the job is submitted, because the
## document may change while the job waits for a physics step.
func set_records(records: Array) -> void:
	_records = records


## Give the module a home in the scene tree. The solid's world hangs off
## `host`, so it lives and dies with the panel.
func attach(host: Node) -> void:
	if host == null or _viewport != null:
		return
	_viewport = SubViewport.new()
	_viewport.name = "InterferenceWorld"
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(4, 4)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.physics_object_picking = false
	host.add_child(_viewport)


# ---------------------------------------------------------------------------
# The solid's collider
# ---------------------------------------------------------------------------

## Rebuild the solid's collider, its edge list and its bounds from the worker's
## mesh — {vertices: [[x, y, z], ...], faces: [[i, j, k], ...]} in CAD
## millimetres, which is also the world frame: the evaluated solid is never
## posed. Returns the triangle count.
##
## ALWAYS rebuilds. The mesh changes on every evaluation and there is no path
## or stamp to key a cache on, so a cache here would answer this evaluation's
## question with the last one's geometry.
func build_solid(mesh_data: Dictionary) -> int:
	_solid_faces = PackedVector3Array()
	_solid_edges = PackedVector3Array()
	_solid_bounds = AABB()
	if _solid_body != null and is_instance_valid(_solid_body):
		_solid_body.get_parent().remove_child(_solid_body)
		_solid_body.queue_free()
	_solid_body = null
	if _viewport == null:
		return 0

	var raw_vertices: Array = mesh_data.get("vertices", []) as Array
	var raw_faces: Array = mesh_data.get("faces", []) as Array
	if raw_vertices.is_empty() or raw_faces.is_empty():
		return 0

	var vertices := PackedVector3Array()
	vertices.resize(raw_vertices.size())
	for i in range(raw_vertices.size()):
		vertices[i] = _vector(raw_vertices[i])
	_solid_bounds = AABB(vertices[0], Vector3.ZERO)
	for point in vertices:
		_solid_bounds = _solid_bounds.expand(point)

	# Edges are de-duplicated by their vertex pair so a shared edge is cast
	# once rather than twice. The key packs the pair into one integer, which
	# only works while the mesh has fewer vertices than the packing base.
	var packable := vertices.size() < 1000000
	var seen := {}
	var triangles := 0
	for entry in raw_faces:
		if not (entry is Array) or (entry as Array).size() < 3:
			continue
		var face: Array = entry
		var a := int(face[0])
		var b := int(face[1])
		var c := int(face[2])
		if a < 0 or b < 0 or c < 0 \
				or a >= vertices.size() or b >= vertices.size() or c >= vertices.size():
			continue
		_solid_faces.append(vertices[a])
		_solid_faces.append(vertices[b])
		_solid_faces.append(vertices[c])
		triangles += 1
		for pair in [[a, b], [b, c], [c, a]]:
			var lo: int = mini(int(pair[0]), int(pair[1]))
			var hi: int = maxi(int(pair[0]), int(pair[1]))
			if packable:
				var key := lo * 1000000 + hi
				if seen.has(key):
					continue
				seen[key] = true
			_solid_edges.append(vertices[lo])
			_solid_edges.append(vertices[hi])
	if triangles == 0:
		return 0

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(_solid_faces)
	# A ray leaving the material of the solid must report the wall it leaves
	# through, or parity counts only half the surfaces.
	shape.backface_collision = true
	_solid_body = StaticBody3D.new()
	_solid_body.name = "SolidCollider"
	_solid_body.collision_layer = 1
	_solid_body.collision_mask = 0
	var owner_id := _solid_body.create_shape_owner(_solid_body)
	_solid_body.shape_owner_add_shape(owner_id, shape)
	_viewport.add_child(_solid_body)
	_solid_generation += 1
	return triangles


## How many times the solid's collider has actually been rebuilt.
func get_solid_generation() -> int:
	return _solid_generation


func get_solid_bounds() -> AABB:
	return _solid_bounds


func get_solid_edge_count() -> int:
	return int(_solid_edges.size() / 2)


# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

## Run the whole check for `panel` and return the report:
##
##   {count, pairs: [{reference, node, points_mm: [{world, local}], point_count,
##    penetration_mm?}], point_count, sampling, casts, checked}
##
## `count` is the number of interfering (reference, node) PAIRS; point_count is
## how many crossings were found. `checked` is false — with a `reason` — when
## there was nothing to compare: no solid, or no reference mounted.
##
## `args` may carry reference= and node= to narrow the question; the mask is
## derived from the reference here, so no caller has to know about layers.
func check(panel: Object, args: Dictionary = {}) -> Dictionary:
	_marker_points = PackedVector3Array()
	var report := await _run(panel, args)
	_draw_markers(panel)
	return report


func _run(panel: Object, args: Dictionary) -> Dictionary:
	if panel == null or not is_instance_valid(panel):
		return _nothing("the CAD panel is gone")
	var document: Dictionary = {}
	if panel.has_method("get_document_state"):
		document = panel.get_document_state()
	var triangles := build_solid(document.get("mesh", {}) as Dictionary)
	if triangles <= 0:
		return _nothing("the evaluation produced no solid geometry to check")

	var gauge: Node = panel.get_mesh_gauge() if panel.has_method("get_mesh_gauge") else null
	if gauge == null or not is_instance_valid(gauge) or not gauge.is_inside_tree():
		return _nothing("the measurement gauge is not available on this panel")
	if int(panel.ensure_gauge_built()) <= 0:
		return _nothing("no reference mesh is mounted; there is nothing to run into")

	set_records(panel.get_reference_state())
	var reference_scope := str(args.get("reference", ""))
	var mask := ALL_LAYERS
	if not reference_scope.is_empty():
		mask = int(gauge.call("mask_for", reference_scope))
	# The reply is the module's own report, or the gauge's {error: ...} when the
	# physics step it needs never came.
	return await gauge.call("submit", "interference", {
		# mesh_gauge dispatches the job back here rather than knowing what an
		# interference check is: it owns the physics step, this module owns
		# the question.
		"module": self,
		"mask": mask,
		"reference": reference_scope,
		"node": str(args.get("node", "")),
	})


## The job body, run by mesh_gauge inside its physics step with the reference
## space's direct state in hand. `state` is the references' space; the solid's
## own space is this module's.
func run_check(gauge: Object, state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	_casts = 0
	_limits = PackedStringArray()
	var mask := int(args.get("mask", ALL_LAYERS))
	var reference_scope := str(args.get("reference", ""))
	var node_scope := str(args.get("node", ""))
	var solid_state := _solid_space()
	var pairs := {}

	# Direction 1: every edge of the solid against the reference colliders.
	# An edge whose own box cannot reach any reference is skipped before it
	# costs a ray — a shell parked beside the board is the common case, and
	# it should cost a box test per edge rather than a cast.
	var reach := _reference_bounds(reference_scope)
	var cull := reach.size.length_squared() > 0.0
	var edge_count := get_solid_edge_count()
	var edge_limit := mini(edge_count, MAX_SOLID_EDGES)
	if edge_limit < edge_count:
		_limits.append("only %d of the solid's %d edges were cast"
			% [edge_limit, edge_count])
	for i in range(edge_limit):
		var a := _solid_edges[i * 2]
		var b := _solid_edges[i * 2 + 1]
		if cull and not AABB(a, Vector3.ZERO).expand(b).intersects(reach):
			continue
		var crossings := _cross_into_references(gauge, state, a, b, mask, reference_scope)
		for crossing in crossings:
			_absorb(pairs, crossing as Dictionary, node_scope)
		# The depth this one edge reached inside each node it crossed. Runs are
		# measured per EDGE: two crossings on different edges bound nothing.
		_absorb_runs(pairs, crossings, node_scope)

	# Direction 2: the edges of every reference triangle that could reach the
	# solid, against the solid's own collider.
	if solid_state != null:
		_reference_edges_into_solid(solid_state, pairs, reference_scope, node_scope)

	# Containment: two bodies that overlap without a single edge crossing are
	# one inside the other, and only parity sees that.
	if pairs.is_empty():
		_containment(gauge, state, solid_state, pairs, mask, reference_scope, node_scope)

	return _report(pairs)


# ---------------------------------------------------------------------------
# Direction 1 — the solid's edges against the references
# ---------------------------------------------------------------------------

## Every surface the segment a→b crosses, in order, as
## {point, node, reference, distance}. The walk re-casts from just past each
## hit, so an edge that goes in one face and out another reports both — which
## is what makes a penetration depth measurable.
func _cross_into_references(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	a: Vector3,
	b: Vector3,
	mask: int,
	reference_scope: String
) -> Array:
	var out: Array = []
	var length := a.distance_to(b)
	if length <= TOUCH_EPSILON_MM:
		return out
	var direction := (b - a) / length
	var cursor := a
	for _step in range(MAX_CROSSINGS_PER_EDGE):
		_casts += 1
		var hit: Dictionary = gauge.call("run_now", state, "raycast", {
			"from": cursor,
			"to": b,
			"mask": mask,
			"reference": reference_scope,
		})
		if not bool(hit.get("hit", false)):
			return out
		var point: Vector3 = hit.get("position", Vector3.ZERO)
		var travelled := a.distance_to(point)
		# A crossing at either end of the edge is a touch, not a penetration:
		# a face resting on a face meets exactly there.
		if travelled > TOUCH_EPSILON_MM and (length - travelled) > TOUCH_EPSILON_MM:
			out.append({
				"point": point,
				"node": str(hit.get("node", "")),
				"reference": str(hit.get("reference", "")),
				"distance": travelled,
			})
		var next := point + direction * CROSSING_ADVANCE_MM
		if a.distance_to(next) >= length:
			return out
		cursor = next
	return out


# ---------------------------------------------------------------------------
# Direction 2 — the references' edges against the solid
# ---------------------------------------------------------------------------

## Cast the edges of every reference triangle that overlaps the solid's bounds
## into the solid's own collider. The culling is two-stage — the part's box,
## then each triangle's — because a board is a hundred thousand triangles and
## only a handful of them are ever near the shell.
func _reference_edges_into_solid(
	solid_state: PhysicsDirectSpaceState3D,
	pairs: Dictionary,
	reference_scope: String,
	node_scope: String
) -> void:
	var examined := 0
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
			if not _ReferenceMeshes.transform_aabb(xform, mesh.get_aabb()) \
					.intersects(_solid_bounds):
				continue
			for surface in range(mesh.get_surface_count()):
				if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
					continue
				var arrays: Array = mesh.surface_get_arrays(surface)
				if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
					continue
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices := PackedInt32Array()
				if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
					indices = arrays[Mesh.ARRAY_INDEX]
				var corners: int = indices.size() if indices.size() > 0 else vertices.size()
				var triangle := 0
				while triangle * 3 + 2 < corners:
					if examined >= MAX_REFERENCE_TRIANGLES:
						_limits.append("only the first %d reference triangles were examined"
							% MAX_REFERENCE_TRIANGLES)
						return
					examined += 1
					var a: Vector3
					var b: Vector3
					var c: Vector3
					if indices.size() > 0:
						a = xform * vertices[indices[triangle * 3]]
						b = xform * vertices[indices[triangle * 3 + 1]]
						c = xform * vertices[indices[triangle * 3 + 2]]
					else:
						a = xform * vertices[triangle * 3]
						b = xform * vertices[triangle * 3 + 1]
						c = xform * vertices[triangle * 3 + 2]
					triangle += 1
					var box := AABB(a, Vector3.ZERO).expand(b).expand(c)
					if not box.intersects(_solid_bounds):
						continue
					for edge in [[a, b], [b, c], [c, a]]:
						var start: Vector3 = edge[0]
						var crossings: Array = []
						for point in _cross_into_solid(solid_state, start, edge[1] as Vector3):
							crossings.append({
								"point": point,
								"node": node_path,
								"reference": reference_name,
								"distance": start.distance_to(point),
							})
						for crossing in crossings:
							_absorb(pairs, crossing as Dictionary, node_scope)
						_absorb_runs(pairs, crossings, node_scope)


## Where the segment a→b crosses the solid's surface, in order.
func _cross_into_solid(
	solid_state: PhysicsDirectSpaceState3D,
	a: Vector3,
	b: Vector3
) -> Array:
	var out: Array = []
	var length := a.distance_to(b)
	if length <= TOUCH_EPSILON_MM:
		return out
	var direction := (b - a) / length
	var cursor := a
	for _step in range(MAX_CROSSINGS_PER_EDGE):
		var hit := _solid_ray(solid_state, cursor, b)
		if hit.is_empty():
			return out
		var point: Vector3 = hit.get("position", Vector3.ZERO)
		var travelled := a.distance_to(point)
		if travelled > TOUCH_EPSILON_MM and (length - travelled) > TOUCH_EPSILON_MM:
			out.append(point)
		var next := point + direction * CROSSING_ADVANCE_MM
		if a.distance_to(next) >= length:
			return out
		cursor = next
	return out


# ---------------------------------------------------------------------------
# Containment — the case no edge crossing can see
# ---------------------------------------------------------------------------

## One body wholly inside the other crosses nothing. Both directions are asked
## once: a vertex of the solid inside a reference's material, and a vertex of
## each reference part inside the solid's. With no crossings anywhere, one
## vertex settles it — the bodies are either wholly in or wholly out.
func _containment(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	solid_state: PhysicsDirectSpaceState3D,
	pairs: Dictionary,
	mask: int,
	reference_scope: String,
	node_scope: String
) -> void:
	if _solid_edges.size() >= 2:
		var probe: Vector3 = _solid_edges[0]
		# The gauge's own parity test, reached through the smallest gauge it
		# will accept: a pin that touches nothing and still does not fit is a
		# pin buried in material.
		var verdict: Dictionary = gauge.call("run_now", state, "gauge", {
			"shape": "sphere",
			"size": Vector3(0.002, 0.0, 0.0),
			"at": probe,
			"mask": mask,
			"reference": reference_scope,
		})
		_casts += 1
		if str(verdict.get("reason", "")) == "inside_solid":
			# Parity says "inside something" without saying inside WHAT, so the
			# nearest surface from the probe names the offender.
			var reach := _scene_reach()
			var named: Dictionary = gauge.call("run_now", state, "raycast", {
				"from": probe,
				"to": probe + Vector3.RIGHT * reach,
				"mask": mask,
				"reference": reference_scope,
			})
			_absorb(pairs, {
				"point": probe,
				"node": str(named.get("node", "")),
				"reference": str(named.get("reference", reference_scope)),
				"distance": 0.0,
				"containment": "the solid lies entirely inside this node",
			}, node_scope)
			return

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
			var vertex := _first_vertex(mesh, xform)
			if _parity_inside_solid(solid_state, vertex) != 1:
				continue
			_absorb(pairs, {
				"point": vertex,
				"node": node_path,
				"reference": reference_name,
				"distance": 0.0,
				"containment": "this node lies entirely inside the solid",
			}, node_scope)


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


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

## Fold one crossing into its (reference, node) pair. `node_scope` drops
## crossings on other nodes; the pair carries the points in the order they were
## found.
func _absorb(pairs: Dictionary, crossing: Dictionary, node_scope: String) -> void:
	var node_path := str(crossing.get("node", ""))
	if not _node_matches(node_path, node_scope):
		return
	var pair: Dictionary = _pair_for(pairs, str(crossing.get("reference", "")), node_path)
	var point: Vector3 = crossing.get("point", Vector3.ZERO)
	pair["point_count"] = int(pair["point_count"]) + 1
	var points: Array = pair["points"]
	if points.size() < MAX_POINTS_PER_PAIR:
		points.append(point)
	if _marker_points.size() < MAX_MARKERS:
		_marker_points.append(point)
	if crossing.has("containment"):
		pair["note"] = str(crossing["containment"])


## How deep ONE edge went inside each node it crossed. The crossings of a given
## node along one edge alternate in and out, so consecutive pairs of them bound
## a run inside that node and the longest run is the penetration.
##
## It is a LOWER BOUND and is reported as one: the deepest point of an overlap
## need not lie on an edge of either body. An odd number of crossings means an
## endpoint of the edge is buried, and bounds no run at all — that case is
## still interference, just without a depth.
func _absorb_runs(pairs: Dictionary, crossings: Array, node_scope: String) -> void:
	var by_node := {}
	for entry in crossings:
		var crossing: Dictionary = entry
		var node_path := str(crossing.get("node", ""))
		if not _node_matches(node_path, node_scope):
			continue
		var key := "%s\n%s" % [str(crossing.get("reference", "")), node_path]
		if not by_node.has(key):
			by_node[key] = []
		(by_node[key] as Array).append(float(crossing.get("distance", 0.0)))
	for key in by_node.keys():
		var distances: Array = by_node[key]
		if distances.size() < 2 or not pairs.has(key):
			continue
		var pair: Dictionary = pairs[key]
		var index := 0
		while index + 1 < distances.size():
			pair["penetration_mm"] = maxf(float(pair["penetration_mm"]),
				float(distances[index + 1]) - float(distances[index]))
			index += 2


func _pair_for(pairs: Dictionary, reference_name: String, node_path: String) -> Dictionary:
	var key := "%s\n%s" % [reference_name, node_path]
	if not pairs.has(key):
		pairs[key] = {
			"reference": reference_name,
			"node": node_path,
			"points": [],
			"point_count": 0,
			"penetration_mm": 0.0,
			"note": "",
		}
	return pairs[key]


func _report(pairs: Dictionary) -> Dictionary:
	var out: Array = []
	var total := 0
	for key in pairs.keys():
		var pair: Dictionary = pairs[key]
		var pose := _pose_for(str(pair["reference"]))
		var points: Array = []
		for point in (pair["points"] as Array):
			points.append({
				"world": _vec(point),
				"local": _vec(pose.affine_inverse() * point),
			})
		var entry := {
			"reference": pair["reference"],
			"node": pair["node"],
			"points_mm": points,
			"point_count": int(pair["point_count"]),
		}
		if float(pair["penetration_mm"]) > 0.0:
			entry["penetration_mm"] = float(pair["penetration_mm"])
			entry["penetration_note"] = "the deepest run of one body's edge " \
				+ "inside the other; a lower bound on the penetration"
		if not str(pair["note"]).is_empty():
			entry["note"] = str(pair["note"])
		total += int(pair["point_count"])
		out.append(entry)
	var sampling := "none: every edge of the solid and every edge of every " \
		+ "reference triangle overlapping it was cast"
	if not _limits.is_empty():
		sampling = "TRUNCATED — %s; the counts are floors" % ", ".join(_limits)
	return {
		"checked": true,
		"units": "mm",
		"count": out.size(),
		"point_count": total,
		"pairs": out,
		"sampling": sampling,
		"casts": _casts,
	}


## A report for a question that could not be asked. `checked` false with a
## reason is not the same answer as "no interference", and a reader that
## cannot tell them apart will trust a check that never ran.
func _nothing(reason: String) -> Dictionary:
	return {
		"checked": false,
		"units": "mm",
		"count": 0,
		"point_count": 0,
		"pairs": [],
		"reason": reason,
		"casts": 0,
	}


## One line for the panel's status banner, or "" when there is nothing to say.
## It names the FIRST offender rather than summarising: an enclosure is fixed
## one collision at a time.
func status_line(report: Dictionary) -> String:
	var pairs: Array = report.get("pairs", []) as Array
	if int(report.get("count", 0)) <= 0 or pairs.is_empty():
		return ""
	var first: Dictionary = pairs[0]
	var where := ""
	var points: Array = first.get("points_mm", []) as Array
	if not points.is_empty():
		var world: Array = (points[0] as Dictionary).get("world", []) as Array
		if world.size() >= 3:
			where = " at (%.2f, %.2f, %.2f) mm" % [
				float(world[0]), float(world[1]), float(world[2])]
	var suffix := ""
	if int(report.get("count", 0)) > 1:
		suffix = " (and %d other node(s))" % (int(report.get("count", 0)) - 1)
	return "Interference: the solid runs into %s/%s%s — %d point(s)%s." % [
		str(first.get("reference", "")),
		str(first.get("node", "")),
		where,
		int(report.get("point_count", 0)),
		suffix,
	]


# ---------------------------------------------------------------------------
# Markers
# ---------------------------------------------------------------------------

## Draw a red cross at every point the last check found, in every pane. The
## node is freed first, so a clean evaluation clears the previous one's
## markers without anything having to remember they were drawn.
func _draw_markers(panel: Object) -> void:
	if panel == null or not is_instance_valid(panel):
		return
	var segments := PackedVector3Array()
	for point in _marker_points:
		for axis in range(3):
			var arm := Vector3.ZERO
			arm[axis] = MARKER_ARM_MM
			segments.append(point - arm)
			segments.append(point + arm)
	for path in _Measurement.MESH_ROOT_PATHS:
		var mesh_root := panel.get_node_or_null(path) as Node3D
		if mesh_root == null:
			continue
		var existing := mesh_root.get_node_or_null(MARKER_NODE_NAME)
		if existing != null:
			mesh_root.remove_child(existing)
			existing.queue_free()
		if segments.is_empty():
			continue
		var mesh: ArrayMesh = _ReferenceMeshes.line_mesh_from_segments(segments, MARKER_COLOR)
		if mesh == null:
			continue
		var instance := MeshInstance3D.new()
		instance.name = MARKER_NODE_NAME
		instance.mesh = mesh
		mesh_root.add_child(instance)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## The solid's space. Only legal to dereference during the physics step, which
## is where every caller below runs.
##
## find_world_3d(), not world_3d: `world_3d` is the explicitly ASSIGNED
## override and stays null for a viewport that made its own world.
func _solid_space() -> PhysicsDirectSpaceState3D:
	if _viewport == null or not _viewport.is_inside_tree():
		return null
	var world := _viewport.find_world_3d()
	return world.direct_space_state if world != null else null


func _solid_ray(
	solid_state: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3
) -> Dictionary:
	if solid_state == null or from.distance_to(to) <= 0.0:
		return {}
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.hit_from_inside = true
	params.hit_back_faces = true
	_casts += 1
	return solid_state.intersect_ray(params)


## Does this node path answer to the filter? A filter is either the PATH from
## the file root (one node) or a bare leaf name (every node carrying it) —
## the same rule every other measurement verb's node= follows.
func _node_matches(node_path: String, filter: String) -> bool:
	if filter.is_empty():
		return true
	return node_path == filter or node_path.get_file() == filter


func _pose_for(reference_name: String) -> Transform3D:
	for entry in _records:
		var record: Dictionary = entry
		if str(record.get("name", "")) == reference_name:
			return record.get("pose", Transform3D.IDENTITY)
	return Transform3D.IDENTITY


## World bounds of the references in scope, or an empty box when the records
## do not carry them — in which case nothing may be culled by them.
func _reference_bounds(reference_scope: String) -> AABB:
	var box := AABB()
	var have := false
	for entry in _records:
		var record: Dictionary = entry
		if not reference_scope.is_empty() \
				and str(record.get("name", "")) != reference_scope:
			continue
		var world: AABB = record.get("world_aabb", AABB())
		if world.size.length_squared() <= 0.0:
			# One reference without bounds means the union is not the whole
			# scene, and culling against it would silently skip that
			# reference. Nothing is culled rather than something missed.
			return AABB()
		box = world if not have else box.merge(world)
		have = true
	return box


## The longest ray worth casting: everything mounted, plus the solid.
func _scene_reach() -> float:
	var box := _solid_bounds
	for entry in _records:
		var record: Dictionary = entry
		var world: AABB = record.get("world_aabb", AABB())
		if world.size.length_squared() > 0.0:
			box = box.merge(world)
	return box.size.length() + 10.0


## The first vertex of a mesh, in world millimetres. Any vertex will do: with
## no edge crossing anywhere, every vertex of the part is on the same side.
func _first_vertex(mesh: Mesh, xform: Transform3D) -> Vector3:
	for surface in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.size() > 0:
			return xform * vertices[0]
	return xform.origin


func _vector(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		var values: Array = raw
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.ZERO


func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]
