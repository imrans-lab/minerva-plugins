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
## WHAT IT COSTS. The whole job runs inside ONE physics step, so its cost is a
## stall and not a slowdown, and the reply carries `casts` and `elapsed_ms` so
## nobody has to guess at it. The bound is: one ray per solid edge whose own box
## reaches a reference (up to MAX_CROSSINGS_PER_EDGE casts for an edge that
## keeps crossing), plus three per reference triangle whose box overlaps the
## solid's, plus two or three parity rays when nothing crossed. Everything else
## — the reference triangles that fail the box test, the solid edges parked away
## from every reference — costs an AABB test and no ray at all.
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
const _WorkerReply: Script = preload("worker_reply.gd")

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

## How long a request will queue behind a running check: mesh_gauge's
## JOB_TIMEOUT_MS (5 s, after which a queued job gives up) plus a margin for
## the walk that FOLLOWS the step — a hundred thousand reference triangles
## inside one physics frame. Past it the new request is REFUSED as busy; the
## module is never taken away from a holder that may still be casting.
const RESERVATION_TIMEOUT_MS: int = 8000


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
## Nodes whose containment question could not be answered, as
## {reference, node, reason}. A rejected probe is not a clean node.
var _undecided: Array = []
## Wall clock of the running check, microseconds.
var _started_us: int = 0

## Requests made, ever. The module holds ONE solid collider and one set of
## counters, so two checks in flight would answer each other's geometry: a
## request takes the next ticket, waits for any running check, and is abandoned
## if a newer one arrived while it waited. Only the newest ticket may draw.
var _ticket: int = 0
var _in_flight: bool = false
## How long a queued request waits before refusing, in milliseconds. Read from
## the variable rather than the constant so a suite can drive the refusal
## without spending the whole window waiting for it; nothing in the panel ever
## writes it.
var reservation_timeout_ms: int = RESERVATION_TIMEOUT_MS
## When the running reservation was granted, in engine milliseconds. The
## holder's AGE is what a queued request refuses on, and what the refusal
## reports.
var _holder_since: int = 0
## The ticket the running reservation was taken with. Only that ticket's
## release frees the module.
var _holder: int = 0

## Emitted when a check releases the module. Waited on by a request that found
## one already running.
signal check_finished


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
##
## `ticket` is the reservation the caller holds. Rebuilding FREES the current
## collider, so while ANY reservation is out the caller must be its holder —
## refused (-1) otherwise, with no exception for a holder that has aged past
## its window. Age decides one thing only, and it is decided in one place:
## reserve() reclaims a stale reservation and hands the module to a new
## ticket. Until that transfer happens the old holder may still be inside a
## physics query, and a freed RID under a running query is a crash, not a
## wrong number. With no reservation out (a suite driving the module directly)
## ticket 0 is the caller and the rebuild goes ahead.
func build_solid(mesh_data: Dictionary, ticket: int = 0) -> int:
	if _in_flight and ticket != _holder:
		return -1
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
	var reservation := await reserve()
	var ticket := int(reservation.get("ticket", 0))
	if ticket == 0:
		return refused(reservation)
	_marker_points = PackedVector3Array()
	var report := await _run(panel, args, ticket)
	if not holds(ticket):
		# Reclaimed while this check was awaiting a physics step: the module's
		# collider, records and counters belong to another check now. The
		# answer still goes back to this caller, and nothing else happens.
		return _superseded(report)
	release_reservation(ticket)
	# Only the newest request may paint. A superseded reply still goes back to
	# its own caller — it is a true answer about the geometry it was asked
	# about — but repainting from it would leave the previous evaluation's red
	# crosses on screen after a newer clean one cleared them.
	if ticket != _ticket:
		return _superseded(report)
	_draw_markers(panel)
	return report


## Take the module for one check and hand back the ticket it holds.
##
## ONE check at a time. build_solid, the collider and the counters are module
## state, so a second request arriving while the first waits for a physics step
## would hand the queued job the other request's geometry. A request that was
## itself overtaken while it queued gets ticket 0 and must stand down without
## touching anything.
##
## Public because the fastener check borrows the same solid collider and the
## same world: it is a second question about the one body this module owns, and
## a second owner of that body is exactly what the ticket exists to prevent.
## Every granted reservation must be released BY ITS OWN TICKET.
##
## Returns {ticket: <non-zero>} when the module is taken, and {ticket: 0,
## busy: true, holder_ticket, holder_age_ms, reason} when it is not.
##
## A LIVE HOLDER IS REFUSED, NOT OVERTAKEN. The records, the cast counters and
## the solid's collider are module state: a second job mutating them frees the
## body the running one is casting against, which is a freed collider under a
## live physics query and not merely a wrong number. So a request arriving
## while the holder is inside its window comes straight back as busy, naming
## the holder and its age, and the caller retries.
##
## A HOLDER PAST THE DEADLINE IS RECLAIMED. reservation_timeout_ms is
## mesh_gauge's own job timeout plus the margin for the walk that follows it,
## so a holder older than that has either returned or died: its physics job
## has timed out inside the gauge, and the walk that follows is synchronous
## GDScript, which cannot be parked mid-way across an await. The reservation is
## taken back rather than left to strand the panel forever on a coroutine that
## will never release it.
##
## THE RECLAIMED TICKET GOES INERT. release_reservation and every path that
## mutates module state on a reservation's behalf check that the caller is
## still the holder, so a dead holder that resumes late releases nothing,
## paints nothing and writes nothing.
func reserve() -> Dictionary:
	_ticket += 1
	var ticket := _ticket
	if _in_flight:
		var age := Time.get_ticks_msec() - _holder_since
		if age < reservation_timeout_ms:
			return {
				"ticket": 0,
				"busy": true,
				"holder_ticket": _holder,
				"holder_age_ms": age,
				"reason": ("check %d has held this panel's geometry for %d ms "
					+ "and has not finished; running a second check now would "
					+ "hand it the other one's collider. Retry in a moment.")
					% [_holder, age],
			}
	_in_flight = true
	_holder = ticket
	_holder_since = Time.get_ticks_msec()
	return {"ticket": ticket}


## Is `ticket` still the reservation this module is running? False for a
## holder that was reclaimed after its deadline — which is the one thing a
## coroutine resuming from an await has to ask before it touches anything.
func holds(ticket: int) -> bool:
	return _in_flight and ticket == _holder


## Release the reservation `ticket` took, and wake whoever is queued behind it.
## A ticket that is not the holder's — a reservation that was reclaimed after
## its deadline — has nothing to release: clearing the flag would hand the
## module's collider away from the check that owns it now.
func release_reservation(ticket: int) -> void:
	if not _in_flight or ticket != _holder:
		return
	_in_flight = false
	_holder = 0
	_holder_since = 0
	check_finished.emit()


## The tree the module's own viewport lives in, or null before attach().
func _tree() -> SceneTree:
	if _viewport != null and _viewport.is_inside_tree():
		return _viewport.get_tree()
	return null


## The report for a reservation that was not granted: a `checked: false`
## answer carrying the holder it lost to, so the caller can retry rather than
## read an empty report as a clean one. Public because the fastener check
## reserves the same module and owes its caller the same answer.
func refused(reservation: Dictionary) -> Dictionary:
	var report := _nothing(str(reservation.get("reason", "the check could "
		+ "not take the panel's geometry")))
	if bool(reservation.get("busy", false)):
		report["busy"] = true
		report["holder_ticket"] = int(reservation.get("holder_ticket", 0))
		report["holder_age_ms"] = int(reservation.get("holder_age_ms", 0))
		return report
	return _superseded(report)


## Mark a reply as describing a question that has been overtaken. The caller
## gets its answer; nothing on screen comes from it.
func _superseded(report: Dictionary) -> Dictionary:
	report["superseded"] = true
	report["superseded_reason"] = "a newer evaluation or verb call started " \
		+ "before this check finished; the panel shows that one"
	return report


## The ticket of the most recent request. Only a check holding it may draw.
func get_ticket() -> int:
	return _ticket


func _run(panel: Object, args: Dictionary, ticket: int = 0) -> Dictionary:
	if panel == null or not is_instance_valid(panel):
		return _nothing("the CAD panel is gone")
	# The cheap refusals first. Building the solid's collider costs a
	# ConcavePolygonShape3D over every triangle the worker returned, and a
	# document with no mesh() in it would pay that on every keystroke for a
	# question that has no second body to ask about.
	var gauge: Node = panel.get_mesh_gauge() if panel.has_method("get_mesh_gauge") else null
	if gauge == null or not is_instance_valid(gauge) or not gauge.is_inside_tree():
		return _nothing("the measurement gauge is not available on this panel")
	if int(panel.ensure_gauge_built()) <= 0:
		return _nothing("no reference mesh is mounted; there is nothing to run into")

	var document: Dictionary = {}
	if panel.has_method("get_document_state"):
		document = panel.get_document_state()
	var triangles := build_solid(document.get("mesh", {}) as Dictionary, ticket)
	if triangles < 0:
		return _nothing("another check holds this panel's geometry; nothing "
			+ "was measured")
	if triangles == 0:
		return _nothing("the evaluation produced no solid geometry to check")

	set_records(panel.get_reference_state())
	var reference_scope := str(args.get("reference", ""))
	var mask := ALL_LAYERS
	if not reference_scope.is_empty():
		mask = int(gauge.call("mask_for", reference_scope))
	# The reply is the module's own report, or the gauge's {error: ...} when the
	# physics step it needs never came.
	var reply: Dictionary = await gauge.call("submit", "interference", {
		# mesh_gauge dispatches the job back here rather than knowing what an
		# interference check is: it owns the physics step, this module owns
		# the question.
		"module": self,
		# The job runs AFTER an await, which is where a reclaimed holder wakes
		# up. run_check refuses to write anything on a ticket that is no
		# longer the holder's.
		"ticket": ticket,
		"mask": mask,
		"reference": reference_scope,
		"node": str(args.get("node", "")),
	})
	# Which solid the report describes. The clearance verb joins this report
	# only when the digest matches the source it is about to measure against,
	# so a report about an older document can never mark a node as buried.
	if bool(reply.get("checked", false)):
		reply["source_digest"] = _source_digest(str(document.get("source", "")))
	return reply


## The job body, run by mesh_gauge inside its physics step with the reference
## space's direct state in hand. `state` is the references' space; the solid's
## own space is this module's.
func run_check(gauge: Object, state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	# Everything below writes module state. A job whose reservation was
	# reclaimed while it queued for this physics step is answering about
	# another check's collider, so it writes nothing and says so. Ticket 0 is
	# a caller driving the module directly, which owns it by definition.
	var ticket := int(args.get("ticket", 0))
	if ticket != 0 and not holds(ticket):
		return _nothing("this check's reservation was reclaimed before its "
			+ "physics step came; another check owns the panel's geometry")
	_started_us = Time.get_ticks_usec()
	_casts = 0
	_limits = PackedStringArray()
	_undecided = []
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
		# ONE QUESTION PER ENCLOSING REFERENCE. Two bodies can both hold the
		# solid, and "is the solid inside this one" is a different question
		# for each of them: answering it for the first and returning leaves
		# the second's clearance rows to pass on an unsigned distance. Every
		# candidate rejected is not a clean answer either — the question was
		# asked and nothing could answer it — so a reference nobody could
		# settle is reported undecidable rather than left silent.
		var enclosing_names := _enclosing_references(reference_scope)
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
			for enclosing in enclosing_names:
				if answered.has(enclosing):
					continue
				var ref_mask := mask
				if not enclosing.is_empty():
					ref_mask = int(gauge.call("mask_for", enclosing))
				# The gauge's own parity test, reached through the smallest
				# gauge it will accept — a pin that touches nothing and still
				# does not fit is a pin buried in material — asked of ONE
				# reference at a time.
				var verdict: Dictionary = gauge.call("run_now", state, "gauge", {
					"shape": "sphere",
					"size": Vector3(0.002, 0.0, 0.0),
					"at": probe,
					"mask": ref_mask,
					"reference": enclosing,
				})
				_casts += 1
				# An ERROR is not an answer. The gauge says so when a ray
				# crossed more surfaces than its budget allows — a deeply
				# layered reference — and treating that as "not inside"
				# reports a buried solid as clean. Leave this reference open
				# and try the next probe.
				if verdict.has("error"):
					continue
				answered[enclosing] = true
				if str(verdict.get("reason", "")) != "inside_solid":
					continue
				# Parity says "inside something" without saying inside WHAT,
				# so the nearest surface from the probe names the offender.
				#
				# This is the ONE cast in the module that starts inside
				# material, against constraint 2 above. It is safe precisely
				# because it is not a crossing test: every reference collider
				# carries backface_collision, so a ray leaving buried material
				# reports the wall it exits through, and that wall's body is
				# the node the solid is buried in — which is all this ray is
				# asked for.
				var reach := _scene_reach()
				var named: Dictionary = gauge.call("run_now", state, "raycast", {
					"from": probe,
					"to": probe + Vector3.RIGHT * reach,
					"mask": ref_mask,
					"reference": enclosing,
				})
				_absorb(pairs, {
					"point": probe,
					"node": str(named.get("node", "")),
					"reference": str(named.get("reference", enclosing)),
					"distance": 0.0,
					"containment": "the solid lies entirely inside this node",
				}, node_scope)
			if answered.size() == enclosing_names.size():
				break
		for enclosing in enclosing_names:
			if answered.has(enclosing):
				continue
			_undecided.append({
				"reference": enclosing,
				"node": "",
				"reason": ("this reference's bounds hold the whole solid, but "
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
				# for the probe and report this node as buried.
				if not _inside_reference(
						gauge, state, probe, reference_name, node_path):
					continue
				decided_node = true
				if _parity_inside_solid(solid_state, probe) != 1:
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


## EVERY reference whose world box holds the whole solid — the records a
## containment question about the solid is ABOUT. Two nested boxes both hold
## it and the question is open for both; answering it for the first one only
## leaves the other's rows to pass on a distance nobody could sign. Falls back
## to the scope the caller asked with, so a question that was asked always
## names something.
func _enclosing_references(reference_scope: String) -> PackedStringArray:
	var out := PackedStringArray()
	for entry in _records:
		var record: Dictionary = entry
		var name := str(record.get("name", ""))
		if not reference_scope.is_empty() and name != reference_scope:
			continue
		if _record_world_box(record).encloses(_solid_bounds):
			out.append(name)
	if out.is_empty():
		out.append(reference_scope)
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


## Is `point` inside the material of ONE node of `reference_name`? The gauge's
## own parity test through the smallest gauge it will accept — a pin that
## touches nothing and still does not fit is a pin buried in material — scoped
## to that reference by mask and to that node by name, so neither a neighbouring
## reference nor a neighbouring node of the same one can vouch for a probe.
func _inside_reference(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	point: Vector3,
	reference_name: String,
	node_path: String
) -> bool:
	_casts += 1
	var verdict: Dictionary = gauge.call("run_now", state, "gauge", {
		"shape": "sphere",
		"size": Vector3(0.002, 0.0, 0.0),
		"at": point,
		"mask": int(gauge.call("mask_for", reference_name)),
		"reference": reference_name,
		"node": node_path,
	})
	return str(verdict.get("reason", "")) == "inside_solid"


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
		var key := _pair_key(str(crossing.get("reference", "")), node_path)
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


## The key a (reference, node) pair is folded under. Shared with the clearance
## join, which has to look a pair up by the same name the interference report
## filed it under.
func _pair_key(reference_name: String, node_path: String) -> String:
	return "%s\n%s" % [reference_name, node_path]


func _pair_for(pairs: Dictionary, reference_name: String, node_path: String) -> Dictionary:
	var key := _pair_key(reference_name, node_path)
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
		# A node here was NOT cleared: its containment could not be decided.
		# Reporting it beside the pairs is what keeps "no interference" an
		# answer about geometry rather than about the probes that failed.
		"undecidable": _undecided,
		"undecidable_note": ("containment is decided from a probe verified "
			+ "inside its own body; a node listed here offered none, so it is "
			+ "neither clean nor reported as interfering"),
		"sampling": sampling,
		"casts": _casts,
		"elapsed_ms": float(Time.get_ticks_usec() - _started_us) / 1000.0,
		# The cost of a per-evaluation check is part of its answer: a reader
		# deciding whether to keep it on can only do that with the bound.
		"cost": "one ray per solid edge whose box reaches a reference, three "
			+ "per overlapping reference triangle, and two or three parity "
			+ "rays when nothing crossed; everything else is an AABB test",
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
		"undecidable": [],
		"reason": reason,
		"casts": 0,
		"elapsed_ms": 0.0,
	}


## One line for the panel's status banner, or "" when there is nothing to say.
## It names the FIRST offender rather than summarising: an enclosure is fixed
## one collision at a time.
func status_line(report: Dictionary) -> String:
	var pairs: Array = report.get("pairs", []) as Array
	if int(report.get("count", 0)) <= 0 or pairs.is_empty():
		# Nothing ran into anything, but a node whose containment could not be
		# decided must not read on screen as a clean answer.
		var undecided: Array = report.get("undecidable", []) as Array
		if not undecided.is_empty():
			var one: Dictionary = undecided[0]
			var name := str(one.get("node", ""))
			if name.is_empty():
				name = str(one.get("reference", "the reference"))
			return "Interference: undecided for %s%s — %s." % [
				name,
				" (and %d other)" % (undecided.size() - 1) \
					if undecided.size() > 1 else "",
				str(one.get("reason", "")),
			]
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


## The solid's space, for a module borrowing this one's collider. Same rule as
## every query here: only legal to dereference inside the physics step.
func solid_space() -> PhysicsDirectSpaceState3D:
	return _solid_space()


## One ray against the solid's collider, counted into this check's cast total.
## Public for the same reason solid_space() is.
func solid_ray(
	solid_state: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3
) -> Dictionary:
	return _solid_ray(solid_state, from, to)


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
	return _pose_in(_records, reference_name)


## The pose a named reference carries in `records`. Split out so the clearance
## path can work from its own snapshot rather than the module's.
func _pose_in(records: Array, reference_name: String) -> Transform3D:
	for entry in records:
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


func _vector(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		var values: Array = raw
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.ZERO


func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


# ---------------------------------------------------------------------------
# Clearance — how much air is there?
# ---------------------------------------------------------------------------
#
# Interference answers "do these touch"; clearance answers "by how much do
# they miss", which is the number a wall thickness is edited against. It is a
# different computation and it does not belong in the ray walk above: the
# minimum distance between two meshes is a minimum over TRIANGLE PAIRS, and no
# number of rays finds the gap between two triangle interiors. The worker owns
# it, over a swept-sphere BVH (python-fcl), and answers exactly.
#
# WHAT THIS SIDE OWNS. The panel is the only thing that knows what a reference
# is: which file, in which units, posed by which matrix. So it hands the worker
# triangles already in world millimetres and gets back numbers it re-frames
# into each reference's own coordinates. The worker never opens a mesh file.
#
# WHY A FILE AND NOT THE MESSAGE. A panel→plugin IPC payload is capped at
# 64 KiB by the host broker (PluginScenePanelBroker.MAX_PAYLOAD_BYTES); a
# 130k-triangle board's arrays are megabytes. The arrays therefore travel as a
# small binary blob written next to the user's cache, named by the SHA-256 of
# its own array bytes, and the message carries only hashes. A reference the
# worker has already seen is named and not re-sent — which is what makes the
# per-evaluation cost a hash lookup rather than a megabyte.

## Tessellation deviation the measurement asks for, in millimetres. The
## display mesh is tessellated for looking at; a clearance is quoted with this
## number as its error bar, so the check asks for its own, tighter one.
const CLEARANCE_TOLERANCE_MM: float = 0.01
## The worker tessellates the solid and may build a 130k-triangle tree on the
## first call. Later calls are milliseconds.
const CLEARANCE_TIMEOUT_MS: int = 60000

## Mesh blob format, read by worker/mcad_worker/clearance.py. Little-endian:
## magic, uint32 version, uint32 vertex count, uint32 triangle count, then
## float32[3V] world millimetres and uint32[3F] indices. Godot's
## `to_byte_array()` is native order, which is little-endian on every target
## the plugin ships to.
const BLOB_MAGIC: String = "MCADMESH"
const BLOB_VERSION: int = 1
const BLOB_DIR_NAME: String = "minerva-cad-clearance"

## The host caps a panel-to-plugin payload at 64 KiB
## (PluginScenePanelBroker.MAX_PAYLOAD_BYTES), measured as the JSON length of
## the payload it receives. The margin covers the difference between the
## caller's stringification and the broker's — float formatting need not agree
## byte for byte — and a request over the cap is refused by the host as
## payload_too_large, which says nothing about clearances.
const IPC_PAYLOAD_LIMIT_BYTES: int = 65536
const IPC_PAYLOAD_MARGIN_BYTES: int = 2048

## What this panel has extracted, keyed by reference/node. Each entry holds the
## digest, the pose it was extracted under and the mesh it came from, so an
## unchanged reference is not walked again on the next evaluation.
var _blobs: Dictionary = {}
## Directory the blobs are written to. Overridable so a suite can keep its
## files out of the user's cache.
var _blob_dir: String = ""
## Digests a clearance call now in flight has named, by how many calls name
## them. The sweep keeps these whatever the current document hashes to.
var _pinned_digests: Dictionary = {}


## Where the mesh blobs are written. The user's cache directory by default:
## the files are derived data, addressed by content hash, and a lost cache
## costs one re-upload.
func set_blob_dir(path: String) -> void:
	_blob_dir = path


## Each panel gets its OWN subdirectory. Blobs are content-addressed, so two
## panels showing the same board write identical bytes to identical names —
## but the sweep below knows only about THIS module's references, so a shared
## directory would let one document's check delete another's blobs mid-read.
## The cost of isolation: a directory left behind by a crashed session is not
## reclaimed by any peer; only its own panel ever deletes it.
func get_blob_dir() -> String:
	if _blob_dir.is_empty():
		var base := OS.get_cache_dir()
		if base.is_empty():
			base = OS.get_user_data_dir()
		_blob_dir = base.path_join(BLOB_DIR_NAME) \
			.path_join("panel-%d" % get_instance_id())
	return _blob_dir


## Delete this panel's blob directory. Called when the panel goes away: the
## sweep only ever runs during an upload, so without this a closed document's
## blobs would sit in the cache until some later document happened to write
## over the same directory — which, now that each panel owns its own, would
## never happen.
func release() -> void:
	# The pins outlive their call only when a measurement's coroutine died
	# holding them; the panel going away is the last chance to drop them.
	_pinned_digests.clear()
	var directory := get_blob_dir()
	_blobs.clear()
	if not DirAccess.dir_exists_absolute(directory):
		return
	for name in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(name))
	DirAccess.remove_absolute(directory)


## minerva_cad_check_clearance — the minimum distance between the solid and
## every reference node in scope, against `required_mm`.
##
## `args`: required_mm (mandatory), reference=, node=, tolerance_mm=.
##
## The reply is the worker's, re-framed:
##
##   {checked, units, pass, required_mm, tessellation_tolerance_mm, bound,
##    pairs: [{reference, node, min_mm, pass, solid_point_mm,
##             reference_point_mm: {world, local}, interference?, note?}],
##    solid_triangles, cache, engine, interference_join}
##
## sorted by min_mm, closest first. `solid_point_mm` is a bare world triple
## because the evaluated solid is never posed — its own frame IS the world.
## `checked: false` with a `reason` is not the same answer as "everything
## clears"; a reader that cannot tell them apart trusts a check that never ran.
##
## A mesh-to-mesh distance is UNSIGNED, so a node buried in the solid's
## material comes back from the worker as a positive surface-to-surface gap.
## The latest interference report for this same source is joined in for exactly
## that case: a node it names is reported at 0 with the interference flag and
## does not pass. `interference_join` says whether that report was available.
func check_clearance(panel: Object, args: Dictionary = {}) -> Dictionary:
	if panel == null or not is_instance_valid(panel):
		return _no_clearance("the CAD panel is gone")
	var required_mm := float(args.get("required_mm", 0.0))
	if required_mm <= 0.0:
		return _no_clearance("a clearance check needs required_mm: the "
			+ "distance you want between the solid and everything else")
	var tolerance_mm := float(args.get("tolerance_mm", CLEARANCE_TOLERANCE_MM))
	if tolerance_mm <= 0.0:
		return _no_clearance("tolerance_mm must be greater than zero")

	var document: Dictionary = {}
	if panel.has_method("get_document_state"):
		document = panel.get_document_state()
	var source := str(document.get("source", ""))
	if source.strip_edges().is_empty():
		return _no_clearance("there is no DSL source to evaluate a solid from")

	# The records are a LOCAL, never the module's _records: an interference
	# check that has been submitted to mesh_gauge but has not yet had its
	# physics step reads _records when it runs, and a clearance call landing in
	# that window would replace the geometry underneath it. The two entry
	# points share this module; they must not share its state.
	var records: Array = []
	if panel.has_method("get_reference_state"):
		records = panel.get_reference_state()
	var reference_scope := str(args.get("reference", ""))
	var node_scope := str(args.get("node", ""))
	var parts := _scoped_parts(records, reference_scope, node_scope)
	if parts.is_empty():
		return _no_clearance("no reference mesh is in scope; there is "
			+ "nothing to measure a clearance against")

	var targets: Array = []
	for entry in parts:
		var part: Dictionary = entry
		var blob := _blob_for(part)
		if blob.is_empty():
			continue
		targets.append({
			"reference": part["reference"],
			"node": part["node"],
			"key": blob["digest"],
		})
	if targets.is_empty():
		return _no_clearance("the references in scope carry no triangles")

	var head := {
		"source": source,
		"required_mm": required_mm,
		"tolerance_mm": tolerance_mm,
	}
	var plan := _batch_targets(head, targets)
	if plan.has("error"):
		return _no_clearance(str(plan["error"]))

	# The keys this call names are pinned for as long as it runs. Two calls
	# share _blobs and the blob directory, so a reference re-posed between one
	# call's two attempts would otherwise let the other's sweep delete the file
	# the retry names — a single-shot "could not read" with nothing wrong.
	var pinned := _pin(plan["batches"] as Array)
	var report := await _measure(panel, head, plan["batches"] as Array, records,
		_buried_pairs(document, source))
	_unpin(pinned)
	return report


## Ask every batch and fold the replies into one report. Split out so the pin
## its caller takes is dropped on every path out of the measurement.
func _measure(panel: Object, head: Dictionary, batches: Array, records: Array,
		buried: Dictionary) -> Dictionary:
	var envelope: Dictionary = {}
	var raw_pairs: Array = []
	for batch_entry in batches:
		var batch: Array = batch_entry
		var reply := await _ask_batch(panel, head, batch)
		if reply.has("error"):
			return _no_clearance(str(reply["error"]))
		if not bool(reply.get("checked", false)):
			return _no_clearance(str(reply.get("reason", "the clearance check "
				+ "did not run and gave no reason")))
		envelope = reply
		raw_pairs.append_array(reply.get("pairs", []) as Array)
	return _clearance_report(envelope, raw_pairs, records, buried)


## Hold the digests of every target in `batches` against the sweep, and hand
## back the list to drop again.
func _pin(batches: Array) -> PackedStringArray:
	var held := PackedStringArray()
	for batch_entry in batches:
		for target_entry in (batch_entry as Array):
			var digest := str((target_entry as Dictionary).get("key", ""))
			_pinned_digests[digest] = int(_pinned_digests.get(digest, 0)) + 1
			held.append(digest)
	return held


func _unpin(held: PackedStringArray) -> void:
	for digest in held:
		var remaining := int(_pinned_digests.get(digest, 0)) - 1
		if remaining > 0:
			_pinned_digests[digest] = remaining
		else:
			_pinned_digests.erase(digest)


## One batch of targets, uploading the geometry the worker turns out not to
## have. A key the worker has not seen (first call, or its cache turned over)
## is answered with the list rather than an error: write those blobs and ask
## once more. Only once — a second miss on freshly written files is a fault,
## not a race, and retrying forever would hide it.
func _ask_batch(panel: Object, head: Dictionary, batch: Array) -> Dictionary:
	var reply := await _ask_worker(panel, _request(head, batch))
	if reply.has("error"):
		return reply
	var missing: Array = reply.get("missing_keys", []) as Array
	if missing.is_empty():
		return reply
	if not _upload(missing):
		return {"error": "could not write the reference geometry to "
			+ get_blob_dir() + " for the worker to read"}
	# The batches were sized as if every target carried its path, so stamping
	# them on cannot push this request past the cap.
	for entry in batch:
		var target: Dictionary = entry
		if str(target["key"]) in missing:
			target["path"] = _blob_path(str(target["key"]))
	reply = await _ask_worker(panel, _request(head, batch))
	if reply.has("error"):
		return reply
	if not (reply.get("missing_keys", []) as Array).is_empty():
		return {"error": "the worker could not read the reference geometry "
			+ "this panel wrote to " + get_blob_dir()}
	return reply


func _request(head: Dictionary, targets: Array) -> Dictionary:
	var payload := head.duplicate()
	payload["targets"] = targets
	return payload


## Split `targets` into requests that each fit the host's channel cap.
##
## Nothing bounds how many nodes a reference has, and each target costs a
## 64-character hash plus an absolute path — a few hundred nodes is a request
## the host refuses as payload_too_large, which tells the reader nothing about
## clearance. Sizing uses the WITH-PATH form of every target, which is the
## largest a request ever gets, so the retry inside `_ask_batch` is safe by
## construction rather than by luck.
##
## Returns {batches: [[target, ...], ...]} or {error: reason}. The only way to
## fail is a single target that does not fit alone, which a target cannot
## cause — it is the DSL source sharing the payload.
func _batch_targets(head: Dictionary, targets: Array) -> Dictionary:
	var limit := IPC_PAYLOAD_LIMIT_BYTES - IPC_PAYLOAD_MARGIN_BYTES
	# BYTES, not characters: the host's cap is on the encoded message, and a
	# DSL with multibyte identifiers or comments in it measures shorter than
	# it travels.
	var head_size := _byte_size(_request(head, []))
	var batches: Array = []
	var current: Array = []
	var size := head_size
	for entry in targets:
		var target: Dictionary = entry
		# +1 for the comma the array separator costs.
		var cost := _byte_size(_sized(target)) + 1
		if head_size + cost > limit:
			return {"error": ("the clearance request for node '%s' does not "
				+ "fit the host's %d byte channel limit on its own — the DSL "
				+ "source is too long to measure against a reference")
				% [str(target.get("node", "")), IPC_PAYLOAD_LIMIT_BYTES]}
		if size + cost > limit:
			batches.append(current)
			current = []
			size = head_size
		current.append(target)
		size += cost
	if not current.is_empty():
		batches.append(current)
	return {"batches": batches}


## What one JSON value costs on the wire, in UTF-8 bytes.
func _byte_size(value: Variant) -> int:
	return JSON.stringify(value).to_utf8_buffer().size()


## A target at its largest: the form the retry sends, carrying the blob path.
func _sized(target: Dictionary) -> Dictionary:
	var out := target.duplicate()
	out["path"] = _blob_path(str(target.get("key", "")))
	return out


func _blob_path(digest: String) -> String:
	return get_blob_dir().path_join(digest + ".mcadmesh")


## Re-frame the worker's replies into one report: every reported point gains
## the coordinates of the reference's OWN frame beside the world ones, because
## those are the numbers that get written back into the DSL. `envelope` is the
## last batch's scalar fields (they are the request's own parameters, so every
## batch agrees on them); `raw_pairs` is every batch's pairs together, which
## have to be re-sorted because each batch only sorted its own.
func _clearance_report(envelope: Dictionary, raw_pairs: Array,
		records: Array, buried: Dictionary) -> Dictionary:
	var overlapping: Dictionary = buried.get("nodes", {})
	var undecided: Dictionary = buried.get("undecided", {})
	var undecided_references: Dictionary = buried.get("undecided_references", {})
	var pairs: Array = []
	for entry in raw_pairs:
		var raw: Dictionary = entry
		var pair := {
			"reference": str(raw.get("reference", "")),
			"node": str(raw.get("node", "")),
			"min_mm": float(raw.get("min_mm", 0.0)),
			"pass": bool(raw.get("pass", false)),
		}
		if overlapping.has(_pair_key(pair["reference"], pair["node"])):
			# The worker measured surface to surface and found air between two
			# faces; the interference check found this node crossing the solid
			# or buried in it. There is no gap to quote, and the realising
			# points describe a distance that is not the answer.
			pair["min_mm"] = 0.0
			pair["pass"] = false
			pair["interference"] = true
			pair["note"] = "the interference check found this node crossing " \
				+ "the solid or lying inside it; a mesh-to-mesh distance is " \
				+ "unsigned and cannot see material a node is already inside"
			pairs.append(pair)
			continue
		var doubt := ""
		if undecided.has(_pair_key(pair["reference"], pair["node"])):
			doubt = str(undecided[_pair_key(pair["reference"], pair["node"])])
		elif undecided_references.has(pair["reference"]):
			doubt = str(undecided_references[pair["reference"]])
		if not doubt.is_empty():
			# The distance is real and is reported; what is not known is which
			# SIDE of the surface it was measured from. A pass here would be a
			# guess, so the row states the doubt and fails.
			pair["pass"] = false
			pair["containment_undecidable"] = true
			pair["note"] = "containment undecidable: %s" % doubt
		if raw.has("solid_point_mm") and raw.has("reference_point_mm"):
			var pose := _pose_in(records, pair["reference"])
			var reference_point := _vector(raw["reference_point_mm"])
			pair["solid_point_mm"] = _vec(_vector(raw["solid_point_mm"]))
			pair["reference_point_mm"] = {
				"world": _vec(reference_point),
				"local": _vec(pose.affine_inverse() * reference_point),
			}
		if bool(raw.get("interference", false)):
			pair["interference"] = true
		if not str(raw.get("note", "")).is_empty() and not pair.has("note"):
			pair["note"] = str(raw["note"])
		pairs.append(pair)
	pairs.sort_custom(func(a, b): return float((a as Dictionary)["min_mm"]) \
		< float((b as Dictionary)["min_mm"]))
	var verdict := true
	for entry in pairs:
		if not bool((entry as Dictionary)["pass"]):
			verdict = false
	return {
		"checked": true,
		"units": "mm",
		"pass": verdict,
		"required_mm": float(envelope.get("required_mm", 0.0)),
		"tessellation_tolerance_mm":
			float(envelope.get("tessellation_tolerance_mm", 0.0)),
		"bound": str(envelope.get("bound", "")),
		"solid_triangles": int(envelope.get("solid_triangles", 0)),
		"engine": str(envelope.get("engine", "")),
		"cache": envelope.get("cache", {}),
		"interference_join": _join_note(buried),
		"pairs": pairs,
	}


## The (reference, node) pairs the panel's latest interference report names as
## crossing the solid or lying inside it, keyed the way a clearance pair is.
##
## The interference check runs on every evaluation and rides in the panel's
## last eval result, so the answer is already there; asking again would rebuild
## the solid's collider for a question that has been answered.
##
## Returns {fresh, nodes: {key: true}, undecided: {key: reason},
## undecided_references: {reference: reason}}.
## `fresh` is false when no report describes the source about to be measured —
## the reply then says the join was unavailable rather than implying the
## distances are signed.
##
## UNDECIDED NODES TRAVEL TOO. A node whose containment the interference check
## could not settle is exactly the node whose unsigned distance cannot be
## trusted: if it IS buried, the gap the worker measured is the distance to the
## wall it is inside. Passing such a node on its measured number is the same
## blind spot the join exists to close, so it is carried through and the pair
## says so.
func _buried_pairs(document: Dictionary, source: String) -> Dictionary:
	var out := {"fresh": false, "nodes": {}, "undecided": {},
		"undecided_references": {}}
	var last_eval: Variant = document.get("last_eval", {})
	if not (last_eval is Dictionary):
		return out
	var report: Variant = (last_eval as Dictionary).get("interference", {})
	if not (report is Dictionary):
		return out
	var interference: Dictionary = report
	if not bool(interference.get("checked", false)):
		return out
	if str(interference.get("source_digest", "")) != _source_digest(source):
		return out
	out["fresh"] = true
	var nodes: Dictionary = out["nodes"]
	for entry in (interference.get("pairs", []) as Array):
		var pair: Dictionary = entry
		nodes[_pair_key(str(pair.get("reference", "")), str(pair.get("node", "")))] = true
	var undecided: Dictionary = out["undecided"]
	var references: Dictionary = out["undecided_references"]
	for entry in (interference.get("undecidable", []) as Array):
		var row: Dictionary = entry
		var reason := str(row.get("reason",
			"the interference check could not decide it"))
		var node_path := str(row.get("node", ""))
		if node_path.is_empty():
			# The other direction: the SOLID may be inside this reference and
			# no probe could settle it. It names no node, so it doubts every
			# node of that reference — a hollow shell buried in one body would
			# otherwise collect a full set of positive, passing distances.
			references[str(row.get("reference", ""))] = reason
			continue
		undecided[_pair_key(str(row.get("reference", "")), node_path)] = reason
	return out


## What the join contributed, in one sentence, so the reply is readable
## without the reader knowing the interference check exists.
func _join_note(buried: Dictionary) -> String:
	if not bool(buried.get("fresh", false)):
		return "no interference report describes this source, so none was " \
			+ "joined: a mesh-to-mesh distance is unsigned, and a node buried " \
			+ "in the solid's material reads as a positive gap"
	var count: int = (buried.get("nodes", {}) as Dictionary).size()
	var undecided: int = (buried.get("undecided", {}) as Dictionary).size() \
		+ (buried.get("undecided_references", {}) as Dictionary).size()
	var doubt := ""
	if undecided > 0:
		doubt = ("; %d node(s) whose containment that report could not decide "
			+ "keep their measured distance but do NOT pass, because an "
			+ "unsigned distance cannot say which side of the surface it was "
			+ "measured from") % undecided
	if count == 0:
		return "the latest interference report for this source found no " \
			+ "overlap, so every distance below is between two surfaces " \
			+ "with air in between" + doubt
	return ("%d node(s) the latest interference report for this source found "
		% count + "overlapping the solid are reported at 0 rather than at "
		+ "their unsigned surface-to-surface distance") + doubt


## SHA-256 of the DSL source, hex. Carried on the interference report so a
## clearance check can tell whether that report describes the solid it is
## about to measure against.
func _source_digest(source: String) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(source.to_utf8_buffer())
	return hasher.finish().hex_encode()


## One line for the status banner, naming the tightest gap. A clearance is
## quoted with its error bar or not at all.
func clearance_status_line(report: Dictionary) -> String:
	if not bool(report.get("checked", false)):
		return ""
	var pairs: Array = report.get("pairs", []) as Array
	if pairs.is_empty():
		return ""
	var first: Dictionary = pairs[0]
	var verdict := "clears" if bool(report.get("pass", false)) else "TOO CLOSE"
	return "Clearance %s: %s/%s is %.3f mm from the solid (need %.3f, " \
		% [verdict, str(first.get("reference", "")), str(first.get("node", "")),
			float(first.get("min_mm", 0.0)), float(report.get("required_mm", 0.0))] \
		+ "tessellated to %.3f mm)." % float(report.get("tessellation_tolerance_mm", 0.0))


func _no_clearance(reason: String) -> Dictionary:
	return {
		"checked": false,
		"units": "mm",
		"pass": false,
		"reason": reason,
		"pairs": [],
	}


## Send one clearance request through the panel's IPC helper and unwrap the
## host's two envelopes down to the worker's own result. Returns {error: ...}
## for every layer that can fail, so the caller has one shape to read.
func _ask_worker(panel: Object, payload: Dictionary) -> Dictionary:
	if not panel.has_method("call_backend"):
		return {"error": "this panel cannot reach the CAD worker"}
	var envelope: Dictionary = await panel.call_backend(
		"cad.clearance", payload, CLEARANCE_TIMEOUT_MS)
	return _WorkerReply.unwrap(envelope, "clearance")


# ---------------------------------------------------------------------------
# Mesh blobs
# ---------------------------------------------------------------------------

## The reference parts a scoped clearance question covers, as
## {reference, node, mesh, xform, pose}. Same node= rule as every other verb.
func _scoped_parts(records: Array, reference_scope: String,
		node_scope: String) -> Array:
	var out: Array = []
	for record_entry in records:
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
			out.append({
				"reference": reference_name,
				"node": node_path,
				"mesh": mesh,
				"xform": pose * (part.get("transform", Transform3D.IDENTITY) as Transform3D),
			})
	return out


## The blob for one part — {digest, body, vertices, triangles} — extracting it
## only when the mesh or its pose has changed since the last check. A board is
## a hundred thousand triangles and re-walking it on every keystroke would cost
## more than the measurement it feeds.
func _blob_for(part: Dictionary) -> Dictionary:
	var mesh: Mesh = part["mesh"]
	var xform: Transform3D = part["xform"]
	var slot := "%s\n%s" % [str(part["reference"]), str(part["node"])]
	var cached: Dictionary = _blobs.get(slot, {}) as Dictionary
	if not cached.is_empty() \
			and int(cached.get("mesh_id", 0)) == int(mesh.get_instance_id()) \
			and (cached.get("xform", Transform3D.IDENTITY) as Transform3D) \
				.is_equal_approx(xform):
		return cached
	var blob := _extract_blob(mesh, xform)
	if blob.is_empty():
		_blobs.erase(slot)
		return {}
	blob["mesh_id"] = int(mesh.get_instance_id())
	blob["xform"] = xform
	_blobs[slot] = blob
	return blob


## Every triangle of `mesh`, transformed into world millimetres, packed into
## the blob body and hashed. Returns {} for a mesh with no triangles.
func _extract_blob(mesh: Mesh, xform: Transform3D) -> Dictionary:
	var points := PackedFloat32Array()
	var indices := PackedInt32Array()
	var vertex_count := 0
	for surface in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var base := vertex_count
		for vertex in vertices:
			var world: Vector3 = xform * vertex
			points.append(world.x)
			points.append(world.y)
			points.append(world.z)
		vertex_count += vertices.size()
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
			var source: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for index in source:
				indices.append(base + index)
		else:
			# An unindexed surface is a triangle soup: the vertices are the
			# corners, in order.
			for i in range(vertices.size()):
				indices.append(base + i)
	var triangles := int(indices.size() / 3)
	if triangles <= 0 or vertex_count <= 0:
		return {}
	indices.resize(triangles * 3)

	var body := points.to_byte_array()
	body.append_array(indices.to_byte_array())
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(body)
	return {
		"digest": hasher.finish().hex_encode(),
		"body": body,
		"vertices": vertex_count,
		"triangles": triangles,
	}


## Write the blobs for `keys` where the worker can read them, and sweep away
## the ones nothing points at any more. Returns false if any write failed.
func _upload(keys: Array) -> bool:
	var directory := get_blob_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK \
			and not DirAccess.dir_exists_absolute(directory):
		return false
	var wanted := {}
	for entry in _blobs.values():
		wanted[str((entry as Dictionary).get("digest", ""))] = true
	for digest in _pinned_digests.keys():
		wanted[str(digest)] = true
	for key in keys:
		var digest := str(key)
		var blob := _blob_with_digest(digest)
		if blob.is_empty():
			return false
		var path := _blob_path(digest)
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			return false
		file.store_buffer(BLOB_MAGIC.to_utf8_buffer())
		file.store_32(BLOB_VERSION)
		file.store_32(int(blob["vertices"]))
		file.store_32(int(blob["triangles"]))
		file.store_buffer(blob["body"] as PackedByteArray)
		file.close()
	_sweep(directory, wanted)
	return true


## Delete blobs in `directory` that no live reference hashes to and no call in
## flight has pinned. Content-addressed files never go stale, they only pile
## up; this keeps the directory the size of the document rather than the size
## of the session.
func _sweep(directory: String, wanted: Dictionary) -> void:
	var names := DirAccess.get_files_at(directory)
	for name in names:
		if not name.ends_with(".mcadmesh"):
			continue
		if wanted.has(name.get_basename()):
			continue
		DirAccess.remove_absolute(directory.path_join(name))


func _blob_with_digest(digest: String) -> Dictionary:
	for entry in _blobs.values():
		var blob: Dictionary = entry
		if str(blob.get("digest", "")) == digest:
			return blob
	return {}
