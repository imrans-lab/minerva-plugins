extends "interference_report.gd"
## interference_world.gd — the solid's own physics world, and the ticket that
## guards it.
##
## The evaluated solid is not in the panel's scene: its collider lives in a
## SubViewport with a world of its own, hung off the panel by attach(). A
## stale solid body in the space the measurement verbs query would answer
## their rays as if it were geometry, so the two worlds stay apart, and every
## ray into this one is cast through solid_space() and solid_ray() — only ever
## inside the physics step, where a direct space state may be dereferenced.
##
## THE COLLIDER IS REBUILT EVERY EVALUATION. The DSL solid changes on every
## keystroke and has no path or stamp to key a cache on. build_solid welds the
## mesh's positions so a triangle soup is not cast twice per shared edge,
## keeps the unique edges the walk casts and the bounds every cull tests
## against, and bumps a generation that proves nothing was cached across.
##
## ONE CHECK AT A TIME, and the reservation here is what says so. That
## collider, the records and the cast counters are a single set of module
## state, so a second check running against them would hand a queued job the
## other one's geometry — and freeing a body under a live physics query is a
## crash, not a wrong number. A grant takes a ticket; an evaluation queues one
## deep and stands down when a newer one arrives; a verb is refused as busy; a
## holder past its deadline is reclaimed in reserve() and nowhere else, so a
## coroutine that wakes late finds holds() false and writes nothing.
##
## The markers are here too, because they are drawn from this module's own
## crossings into the panel's mesh roots: the node is freed and rebuilt on
## every check, so a clean evaluation clears the last one's crosses without
## anything having to remember they were drawn.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: extended by scripts/interference_containment.gd, which
## scripts/geometry_checks.gd extends. reserve(), refused(), build_solid(),
## solid_space() and solid_ray() are also called by scripts/fastener_checks.gd,
## which borrows this one solid collider rather than building a second.


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


## Rays spent on the solid's own edges in one check, and reference triangles
## examined. Both are ceilings on a pathological document, not a sampling
## scheme: when either is hit the report says so in `sampling` and the count
## is a floor.
##
## THE EDGE CEILING BOUNDS CASTS, NOT THE WALK. An edge whose box cannot reach
## any reference costs one AABB test and no ray, so the walk always runs to
## the END of the solid and only edges that actually reach a reference draw on
## the budget. A hundred-thousand-edge shell whose roof stands clear of
## everything inside it is therefore cast in full — a ceiling on the walk
## would have stopped in the middle of the roof and called the answer a floor.
const MAX_SOLID_EDGES: int = 60000
const MAX_REFERENCE_TRIANGLES: int = 400000


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

## Rays the check may spend on solid edges. Read from the variable rather
## than the constant so a suite can drive the ceiling without generating a
## hundred thousand edges; nothing in the panel ever writes it.
var max_solid_edge_casts: int = MAX_SOLID_EDGES

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
## When the running reservation's CURRENT PHASE started, in engine
## milliseconds. The holder's age is measured from here, and a check has two
## phases with different clocks: the synchronous one (build the solid, fit,
## pair — no awaits, so no other coroutine can be running) and the physics
## one, which mesh_gauge times out on its own. refresh_reservation() restarts
## the clock at the boundary, so a big solid that takes its time building
## cannot be reclaimed out from under a job that is only about to start.
var _holder_since: int = 0
## The one queued evaluation, or 0. A newer arrival takes this slot and the
## ticket it displaced stands down: the panel wants the NEWEST document
## checked, not every document checked in turn.
var _pending: int = 0
## Arrivals at the queue, ever. It orders waiters against each other and has
## nothing to do with the ticket, which only a granted reservation gets. It
## is also the "newest arrival" marker check() reads at paint time: a running
## check whose grant predates the latest arrival has been overtaken by a
## newer document and paints nothing.
var _arrivals: int = 0
## The ticket the running reservation was taken with. Only that ticket's
## release frees the module.
var _holder: int = 0

## Emitted when a check releases the module. Waited on by a request that found
## one already running.
signal check_finished


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

	# Edges are de-duplicated by the POSITIONS they join, not by the indices:
	# a baked or worker-supplied mesh is usually a triangle soup in which two
	# triangles sharing an edge each carry their own copies of its two
	# vertices, so an index-keyed pair never collides and every edge would be
	# cast twice. Positions are welded exactly — a pair that misses only
	# duplicates a ray, never changes an answer.
	var welded := {}
	var weld_of := PackedInt32Array()
	weld_of.resize(vertices.size())
	for i in range(vertices.size()):
		var point := vertices[i]
		if not welded.has(point):
			welded[point] = welded.size()
		weld_of[i] = int(welded[point])
	# The key packs the welded pair into one integer, which only works while
	# the mesh has fewer distinct positions than the packing base.
	var packable := welded.size() < 1000000
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
			var lo: int = mini(weld_of[int(pair[0])], weld_of[int(pair[1])])
			var hi: int = maxi(weld_of[int(pair[0])], weld_of[int(pair[1])])
			if packable:
				var key := lo * 1000000 + hi
				if seen.has(key):
					continue
				seen[key] = true
			_solid_edges.append(vertices[int(pair[0])])
			_solid_edges.append(vertices[int(pair[1])])
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
# The reservation
# ---------------------------------------------------------------------------

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
## Returns {ticket: <non-zero>} when the module is taken, and a ticket of 0
## with a reason when it is not.
##
## TWO KINDS OF CALLER, and they want opposite things. An EVALUATION must not
## be refused: the panel checks every evaluation and paints the result, so a
## check dropped because an older one was still running leaves the newest
## document unchecked and the last evaluation's crosses on screen. It QUEUES
## (`queued`), and there is one place in that queue: a newer evaluation
## arriving takes it and the one it displaced stands down as superseded, which
## is correct — nobody wants a report about the document before last. A VERB
## asked for by an agent is the opposite: it is a question about now, it has a
## caller who can ask again, and a wait it cannot see is worse than an answer
## that says retry. It gets `busy`.
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
func reserve(queued: bool = false) -> Dictionary:
	# NO TICKET UNTIL THE RESERVATION IS GRANTED. The ticket is what says
	# which check may paint, so handing one to a request that is about to be
	# refused makes the check still running look overtaken: it finishes with
	# valid geometry and paints nothing, and the panel keeps the last
	# evaluation's crosses. Waiting in the queue takes an ARRIVAL number
	# instead, which orders the queue and nothing else.
	var arrival := 0
	var tree := _tree()
	while _in_flight:
		var age := Time.get_ticks_msec() - _holder_since
		if age >= reservation_timeout_ms:
			# The holder is past its window: reclaimed here, and nowhere else.
			break
		if not queued:
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
		# One place in the queue. A newer evaluation takes it, and this one
		# stands down rather than measuring a document that has moved on.
		if arrival == 0:
			_arrivals += 1
			arrival = _arrivals
		_pending = arrival
		if tree != null:
			await tree.process_frame
		else:
			await check_finished
		if _pending != arrival:
			return {
				"ticket": 0,
				"superseded": true,
				"reason": "a newer evaluation arrived while this check waited "
					+ "for the panel's geometry; that one is being checked",
			}
	if arrival != 0 and _pending == arrival:
		_pending = 0
	_ticket += 1
	var ticket := _ticket
	_in_flight = true
	_holder = ticket
	_holder_since = Time.get_ticks_msec()
	return {"ticket": ticket}


## Restart the holder's clock. Called at the boundary between a check's
## synchronous phase and the physics job it is about to submit: past this
## point mesh_gauge's own JOB_TIMEOUT_MS bounds the wait, and the reclaim
## deadline should be measured against THAT rather than against however long
## the solid took to build. Ignored for anyone but the holder.
func refresh_reservation(ticket: int) -> void:
	if not holds(ticket):
		return
	_holder_since = Time.get_ticks_msec()


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
	# Whoever is queued wakes on the next idle frame and takes it.
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
	# Displaced in the queue by a newer evaluation: its answer is the one the
	# panel wants, and this reply says why there is nothing here.
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
