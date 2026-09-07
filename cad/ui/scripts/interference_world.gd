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
## A NAMED PART IS THE ONE THING THAT CAN BE. A part-scoped check evaluates
## one binding of the document and knows the digest of the source that
## produced it, so the shape HAS a stamp; build_solid takes it as cache_key
## and swaps a body already built for that exact source back into the world.
## Three checks over one part therefore weld once — get_solid_builds() counts
## the welds, get_solid_generation() counts the changes, and the two differ
## by exactly the swaps. The document's own render target passes no key and
## keeps rebuilding.
##
## ONE CHECK AT A TIME, and the reservation here is what says so. That
## collider, the records and the cast counters are a single set of module
## state, so a second check running against them would hand a queued job the
## other one's geometry — and freeing a body under a live physics query is a
## crash, not a wrong number. A grant takes a ticket; an evaluation queues one
## deep and stands down when a newer one arrives; a verb takes a place in a
## bounded wait line and is refused as busy only past that bound or past its
## own wait budget; a holder past its deadline is reclaimed in reserve() and
## nowhere else, so a coroutine that wakes late finds holds() false and
## writes nothing.
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


## Named shapes whose collider is kept ready to swap back in. A part-scoped
## check_design over four parts wants all four alive at once — the three legs
## walk them in the same order — and a shell's ConcavePolygonShape3D is real
## memory, so the bound is a few parts and not a document's worth.
const MAX_CACHED_SOLIDS: int = 6


## How long a request will queue behind a running check: mesh_gauge's
## JOB_TIMEOUT_MS (5 s, after which a queued job gives up) plus a margin for
## the walk that FOLLOWS the step — a hundred thousand reference triangles
## inside one physics frame. Past it the new request is REFUSED as busy; the
## module is never taken away from a holder that may still be casting.
const RESERVATION_TIMEOUT_MS: int = 8000


## Verb calls that may stand in the wait line at once, and how long one of
## them may stand there.
##
## A VERB WAITS RATHER THAN BOUNCING. Five check verbs fired at one panel used
## to have four of them come straight back `busy`, and an agent that has to
## re-ask four times inside one tool window mostly does not get to: the calls
## time out at its client and the panel looks hung. So a verb takes a place in
## line and is granted the moment the holder releases, which for a check that
## is nearly done is a frame or two. The line is BOUNDED because an unbounded
## one is the same hang wearing a queue: past the bound, and past the time one
## caller may spend in it, the answer is still `busy` — with `waited_ms`, so
## the caller can tell a refusal from a wait that ran out.
const MAX_QUEUED_VERBS: int = 4
const VERB_QUEUE_TIMEOUT_MS: int = 15000


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
## Increments whenever the collider the rays meet CHANGES — a rebuild or a
## swap out of the part cache alike. Every epoch guard in the chain compares
## it to decide whether its answer describes one state of the document.
var _solid_generation: int = 0
## Increments only when the triangles were actually welded and shaped. The
## observable that separates a rebuild from a swap: three checks over one
## part move the generation three times and this once.
var _solid_builds: int = 0
## Colliders built for a NAMED shape — source digest -> {body, faces, edges,
## bounds, triangles} — so a part checked by three legs in a row is welded
## once. Only the current entry's body is a child of the viewport; the rest
## are held out of the tree, which is why they are freed here and nowhere
## else. The document's own render target is never cached (empty key).
var _solid_cache: Dictionary = {}
## Cache keys, least recently mounted first. The eviction order.
var _cache_order: Array[String] = []
## Which cached shape is in the world now, or "" for one built without a key.
var _current_key: String = ""

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
## Verb calls standing in the wait line right now. Bounded: five agents firing
## five verbs at one panel must not all sit there, and the fifth is better
## served by "retry" than by a wait its own client will time out inside.
var _verbs_waiting: int = 0
## The bound, and how long one waiter may stand there. Both are variables so
## a suite can drive a full line and a give-up without spending the window;
## nothing in the panel ever writes them.
var max_queued_verbs: int = MAX_QUEUED_VERBS
var verb_queue_timeout_ms: int = VERB_QUEUE_TIMEOUT_MS

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
## REBUILDS UNLESS THE CALLER NAMES THE SHAPE. With no `cache_key` — the
## document's own render target, which changes on every keystroke and has no
## stamp to key a cache on — it always rebuilds, because a cache there would
## answer this evaluation's question with the last one's geometry. A
## PART-SCOPED caller has a stamp: the digest of the source that evaluates to
## that binding. Naming it swaps a collider already built for that exact
## source back into the world instead of welding and re-shaping the same
## triangles, which is what makes three checks over one part cost one build.
## A key is a source digest, so a document that changed produces a different
## key and the stale bodies age out of the bound below.
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
func build_solid(mesh_data: Dictionary, ticket: int = 0,
		cache_key: String = "") -> int:
	if _in_flight and ticket != _holder:
		return -1
	_solid_faces = PackedVector3Array()
	_solid_edges = PackedVector3Array()
	_solid_bounds = AABB()
	_detach_solid_body()
	if _viewport == null:
		return 0
	if not cache_key.is_empty() and _kept_solid_is_live(cache_key):
		return _mount_cached_solid(cache_key)

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
	_solid_builds += 1
	_current_key = cache_key
	if not cache_key.is_empty():
		_keep_solid(cache_key, triangles)
	return triangles


## How many times the solid's collider has actually been rebuilt.
func get_solid_generation() -> int:
	return _solid_generation


## How many times the triangles were actually welded and shaped — a swap out
## of the cache does not count. The observable that separates "the collider
## changed" from "the collider was built".
func get_solid_builds() -> int:
	return _solid_builds


## Take the current body out of the world, keeping it alive when it belongs to
## a cached shape and freeing it when it does not. A body left in the world
## would answer the next check's rays as if it were this document's geometry.
func _detach_solid_body() -> void:
	if _solid_body != null and is_instance_valid(_solid_body):
		if _solid_body.get_parent() != null:
			_solid_body.get_parent().remove_child(_solid_body)
		if not _cached_body(_current_key, _solid_body):
			_solid_body.queue_free()
	_solid_body = null
	_current_key = ""


## Is this body the one the cache holds under `key`? A body that is not is
## nobody's but the caller's, and must be freed with the rebuild.
func _cached_body(key: String, body: StaticBody3D) -> bool:
	if key.is_empty() or not _solid_cache.has(key):
		return false
	return (_solid_cache[key] as Dictionary).get("body", null) == body


## Is there still a body to swap in under `key`? An entry whose body has gone
## is dropped here, so the caller falls through and welds the shape again
## rather than reporting a document with no solid geometry in it.
func _kept_solid_is_live(key: String) -> bool:
	if not _solid_cache.has(key):
		return false
	var body: StaticBody3D = (_solid_cache[key] as Dictionary).get("body", null)
	if body != null and is_instance_valid(body):
		return true
	_solid_cache.erase(key)
	_cache_order.erase(key)
	return false


## Put the shape built for `key` back into the world without touching a
## triangle. The generation still moves: the collider the rays meet IS a
## different one, and every epoch guard in the chain reads that number to
## decide whether its answer describes one state of the document.
func _mount_cached_solid(key: String) -> int:
	var kept: Dictionary = _solid_cache[key]
	var body: StaticBody3D = kept["body"]
	_solid_faces = kept["faces"]
	_solid_edges = kept["edges"]
	_solid_bounds = kept["bounds"]
	_solid_body = body
	_viewport.add_child(body)
	_solid_generation += 1
	_current_key = key
	# Most recently used goes to the back, so the bound below evicts the
	# binding nobody has asked about for longest.
	_cache_order.erase(key)
	_cache_order.append(key)
	return int(kept["triangles"])


## Keep the shape just built under `key`, evicting the least recently used
## once the bound is reached. The evicted body is freed here — it is out of
## the world already, since only the current one is ever a child.
func _keep_solid(key: String, triangles: int) -> void:
	_solid_cache[key] = {
		"body": _solid_body,
		"faces": _solid_faces,
		"edges": _solid_edges,
		"bounds": _solid_bounds,
		"triangles": triangles,
	}
	_cache_order.erase(key)
	_cache_order.append(key)
	while _cache_order.size() > MAX_CACHED_SOLIDS:
		var evicted := str(_cache_order.pop_front())
		if evicted == _current_key:
			# The shape in the world is never the one evicted: freeing it
			# would take the collider out from under the check that just
			# built it. It goes to the back and the next one out is the
			# genuinely oldest.
			_cache_order.append(evicted)
			continue
		var kept: Dictionary = _solid_cache.get(evicted, {}) as Dictionary
		_solid_cache.erase(evicted)
		var body: StaticBody3D = kept.get("body", null)
		if body != null and is_instance_valid(body):
			body.queue_free()


## The panel is going away. The cached bodies are held OUT of the tree, so
## nothing else would ever free them; the blob store below this in the chain
## still gets its own turn.
func release() -> void:
	release_solids()
	super.release()


## Drop every cached shape, keeping the one currently in the world — that one
## is a child of the viewport and dies with it.
func release_solids() -> void:
	for key in _solid_cache.keys():
		var kept: Dictionary = _solid_cache[key]
		var body: StaticBody3D = kept.get("body", null)
		if body != null and is_instance_valid(body) and body != _solid_body:
			body.queue_free()
	_solid_cache.clear()
	_cache_order.clear()


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
	var waiting_since := Time.get_ticks_msec()
	var in_line := false
	while _in_flight:
		var age := Time.get_ticks_msec() - _holder_since
		if age >= reservation_timeout_ms:
			# The holder is past its window: reclaimed here, and nowhere else.
			break
		if not queued:
			var waited := Time.get_ticks_msec() - waiting_since
			# JOIN THE LINE ONCE. A verb that has already taken a place keeps
			# it until it is granted or gives up; a verb arriving to a full
			# line is refused at once, because a queue nobody bounds is a
			# hang with extra steps.
			if not in_line:
				if tree == null:
					return _busy(waited, age,
						"this module has no scene tree to wait a frame in")
				if _verbs_waiting >= max_queued_verbs:
					return _busy(waited, age,
						"the wait line for this panel's geometry already has "
						+ "%d call(s) in it" % _verbs_waiting)
				_verbs_waiting += 1
				in_line = true
			if waited >= verb_queue_timeout_ms:
				_verbs_waiting -= 1
				return _busy(waited, age,
					"this call queued for %d ms and the line did not clear"
					% waited)
			# Evaluations have the right of way: the panel wants the newest
			# document checked and painted, and a verb is a question that can
			# afford to be a frame later.
			await tree.process_frame
			continue
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
	if in_line:
		_verbs_waiting -= 1
	if arrival != 0 and _pending == arrival:
		_pending = 0
	_ticket += 1
	var ticket := _ticket
	_in_flight = true
	_holder = ticket
	_holder_since = Time.get_ticks_msec()
	# How long this caller stood in the line. It travels into the reply so a
	# call that took a while says why, rather than looking like a slow check.
	return {"ticket": ticket, "waited_ms": Time.get_ticks_msec() - waiting_since}


## The refusal a verb gets when it cannot be let in: the line is full, the
## module has no tree to wait a frame in, or the caller stood in it for as
## long as it may. `waited_ms` is what it spent, so a caller can tell a
## straight refusal from one that queued and gave up.
func _busy(waited_ms: int, holder_age_ms: int, why: String) -> Dictionary:
	return {
		"ticket": 0,
		"busy": true,
		"holder_ticket": _holder,
		"holder_age_ms": holder_age_ms,
		"waited_ms": waited_ms,
		"reason": ("check %d has held this panel's geometry for %d ms and has "
			+ "not finished; %s. Running a second check now would hand it the "
			+ "other one's collider — retry in a moment.")
			% [_holder, holder_age_ms, why],
	}


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
		# What the caller spent standing in the line before being refused.
		# Zero means it was never let in at all.
		report["queued_ms"] = int(reservation.get("waited_ms", 0))
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
