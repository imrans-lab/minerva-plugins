extends "clearance_client.gd"
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
## THE OTHER HALF. Clearance — "by how much do they miss" — is a worker round
## trip and not a ray walk, and lives in clearance_client.gd, which this script
## extends: one object carries both halves, so the panel, panel_tools and
## fastener_checks each hold a single geometry-checks instance as they always
## have. The frame helpers both halves read live down there too.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/geometry_checks.gd") from CADPanel.gd.

const _Measurement: Script = preload("panel_measurement.gd")
const _ReferenceMeshes: Script = preload("reference_meshes.gd")
## The rule that tells a designed contact from a penetration when an edge runs
## ALONG a face instead of through it.
const _ContactRuns: Script = preload("contact_runs.gd")

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
## How far along the edge a crossing is probed to prove it PENETRATED rather
## than grazed. Two coplanar faces meet along shared boundary edges, and an
## edge of one body running in the other's surface crosses that boundary
## squarely — a knife-edge contact with no volume behind it. The probe steps
## off the crossing and asks whether there is material there.
##
## This is a CEILING, not the step. A body thinner than it — a 0.004 mm plate
## — would be stepped clean over, and a genuine crossing would read as a
## graze; so the run of material past the hit is measured first and the probe
## goes half of whatever is there. See _probe_step_mm.
const PENETRATION_PROBE_MM: float = 0.005
## The gauge sphere the parity probe places, millimetres — its DIAMETER, which
## is what mesh_gauge reads a sphere's size as (its contact rays reach half of
## it). The probe sits at the middle of the material's run, so the sphere fits
## only when that run exceeds this diameter; material no thicker than it cannot
## be probed at all — the sphere touches a wall and the gauge reports a
## contact rather than "inside" — so a crossing through it is KEPT rather
## than cleared: unprovable is not clean.
const PARITY_SPHERE_MM: float = 0.002
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
# The check
# ---------------------------------------------------------------------------

## Run the whole check for `panel` and return the report:
##
##   {count, pairs: [{reference, node, points_mm: [{world, local}], point_count,
##    penetration_mm?}], point_count, sampling, casts, checked, painted}
##
## `painted` says whether this reply's crossings are the ones on screen; it is
## false, with `paint_withheld`, when a newer evaluation queued while this
## check ran — that evaluation's check paints the pane instead.
##
## `count` is the number of interfering (reference, node) PAIRS; point_count is
## how many crossings were found. `checked` is false — with a `reason` — when
## there was nothing to compare: no solid, or no reference mounted.
##
## `args` may carry reference= and node= to narrow the question; the mask is
## derived from the reference here, so no caller has to know about layers.
func check(panel: Object, args: Dictionary = {}) -> Dictionary:
	# An agent's verb call says so and is refused while a check runs; the
	# panel's own per-evaluation check says nothing and queues.
	var reservation := await reserve(not bool(args.get("on_demand", false)))
	var ticket := int(reservation.get("ticket", 0))
	if ticket == 0:
		return refused(reservation)
	# The queue as it stood when this check was granted. An evaluation that
	# QUEUES behind this one from here on is the newer document, and the
	# moment it arrives this check's paint is revoked: it keeps its ticket
	# and finishes measuring — its answer is true about its own document —
	# but its crossings must not reach the screen, or an interfering old
	# document would stay painted until the queued clean one runs. Distinct
	# from the ticket on purpose: the ticket says who owns the collider, this
	# says whose answer the pane is waiting for.
	var arrivals_at_grant := _arrivals
	_marker_points = PackedVector3Array()
	var report := await _run(panel, args, ticket)
	if not holds(ticket):
		# Reclaimed while this check was awaiting a physics step: the module's
		# collider, records and counters belong to another check now. The
		# answer still goes back to this caller, and nothing else happens.
		return _superseded(report)
	release_reservation(ticket)
	# The run itself found its epoch mixed (the colliders were rebuilt under
	# it): nothing on screen may come from that.
	if bool(report.get("superseded", false)):
		return report
	# Only the newest request may paint. A superseded reply still goes back to
	# its own caller — it is a true answer about the geometry it was asked
	# about — but repainting from it would leave the previous evaluation's red
	# crosses on screen after a newer clean one cleared them.
	if ticket != _ticket:
		return _superseded(report)
	if _arrivals != arrivals_at_grant:
		report["painted"] = false
		report["paint_withheld"] = "a newer evaluation queued while this " \
			+ "check ran; its check paints the pane when it runs"
		return report
	_draw_markers(panel)
	report["painted"] = true
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

	# A COPY of the panel's records, never its live array: a re-pose rewrites
	# a record's pose in place, and the job that reads _records runs after an
	# await. The deep duplicate copies the dictionaries and their poses and
	# shares the meshes, which are never rewritten under a record.
	set_records((panel.get_reference_state() as Array).duplicate(true))
	# The colliders have to be the ones THESE records describe. A pose is
	# rewritten in place and the panel rebuilds lazily, so a check can begin
	# with the records already ahead of the gauge and nothing changing during
	# its wait: every guard that watches for a change sees none, the rays meet
	# the old geometry and the report is framed in the new pose. The gauge is
	# asked what it was built from; on a mismatch this module rebuilds it from
	# the records it holds — this is the per-evaluation path, and a rebuild
	# here is the same rebuild the panel's next measurement would make. It is
	# labelled by the records digest, because the panel's own label still
	# names the old poses and an identical label is a no-op to build(); the
	# panel relabels on its next ensure_gauge_built.
	var bodies: Array = _MeshGauge.bodies_from_records(_records)
	var colliders_rebuilt := false
	if str(gauge.call("get_bodies_digest")) != _MeshGauge.bodies_digest(bodies):
		if int(gauge.call("build", bodies, _MeshGauge.bodies_digest(bodies))) <= 0:
			return _nothing("the reference colliders could not be rebuilt at "
				+ "the current poses; there is nothing to run into")
		colliders_rebuilt = true
	# What this report is ABOUT, fixed before anything is awaited: the
	# reference poses as the gauge digests them — read back from the gauge,
	# so they are the colliders the rays are cast against, not a derivation
	# beside them — and the collider generation. The clearance join compares
	# both with the state it finds later, because a report about references
	# that have since moved or been rebuilt cannot say which nodes are buried
	# now.
	var records_digest := str(gauge.call("get_bodies_digest"))
	var gauge_generation := int(gauge.call("get_generation"))
	var reference_scope := str(args.get("reference", ""))
	var mask := ALL_LAYERS
	if not reference_scope.is_empty():
		mask = int(gauge.call("mask_for", reference_scope))
	# The synchronous phase ends here: everything above is straight-line
	# GDScript, and everything below waits on a physics step that mesh_gauge
	# times out on its own. The reclaim clock restarts so the two are not
	# added together.
	refresh_reservation(ticket)
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
	# THE COLLIDERS THE RAYS MET MUST BE THE ONES STAMPED ABOVE. The gauge is
	# shared: a newer evaluation re-poses its references and rebuilds it
	# before it queues here, and a measurement verb rebuilds it on demand, so
	# the physics step this check waited for can have cast against another
	# epoch's colliders while the records and the stamp are this one's. That
	# answer belongs to neither document, so it is superseded — the newest
	# evaluation is queued and re-measures anyway — and nothing is stamped or
	# painted from it.
	if bool(reply.get("checked", false)) \
			and (str(gauge.call("get_bodies_digest")) != records_digest
				or int(gauge.call("get_generation")) != gauge_generation):
		return _superseded(_nothing("the reference colliders were rebuilt "
			+ "while this check waited for its physics step, so its rays may "
			+ "have met another evaluation's geometry; the evaluation that "
			+ "rebuilt them is checked in its own right"))
	# Which solid, which reference poses and which colliders the report
	# describes. The clearance verb joins this report only when all three
	# match the state it is about to measure against, so a report about an
	# older document — or about references that have moved under the same
	# document — can neither mark a node as buried nor clear one.
	if bool(reply.get("checked", false)):
		reply["source_digest"] = _source_digest(str(document.get("source", "")))
		reply["records_digest"] = records_digest
		reply["gauge_generation"] = gauge_generation
		if colliders_rebuilt:
			reply["colliders_rebuilt"] = true
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

## Does the edge a→b actually pass THROUGH the surface this hit landed on?
##
## A face resting on a face is the case this exists for. Two coplanar faces
## share a plane, so every edge of either one lies in the other's surface and
## hits it all along its length, at points that are float luck rather than
## geometry — and so does an edge that merely starts on that shared plane and
## climbs away from it, which is what every side face of a seated part does.
## None of those is a penetration. A real crossing straddles the plane of the
## surface it crossed: one end of the edge is clear of it on one side, the
## other end clear of it on the other. Sides are compared by sign only, so a
## back-face hit — whose reported normal points the other way — reads the
## same as a front-face one.
func _straddles(a: Vector3, b: Vector3, point: Vector3, hit: Dictionary) -> bool:
	var normal: Vector3 = hit.get("normal", Vector3.ZERO)
	if normal.length_squared() <= 0.0:
		# No usable plane. An unanswerable question must not quietly become
		# "clean", so the hit stands.
		return true
	var unit := normal.normalized()
	var from_a := (a - point).dot(unit)
	var from_b := (b - point).dot(unit)
	return from_a * from_b < 0.0 \
		and absf(from_a) > TOUCH_EPSILON_MM \
		and absf(from_b) > TOUCH_EPSILON_MM


## Is there material of `node_path` a short step off this crossing, along the
## edge that made it? A crossing where neither step lands in material is the
## edge passing through the BOUNDARY of a face it is lying in — the shared rim
## of a designed flush fit — and there is no overlap behind it to measure.
func _penetrates_reference(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	point: Vector3,
	direction: Vector3,
	mask: int,
	reference_name: String,
	node_path: String
) -> bool:
	# How much material is actually there, along this edge, on BOTH sides of
	# the hit. Forward alone is not enough: an edge that only LEAVES material
	# — a tetrahedron with one vertex inside a four-micron plate and the rest
	# above it — sees no exit ahead, keeps the ceiling, and the backward probe
	# jumps clean through the plate.
	var forward := _run_along(gauge, state, point, direction, mask,
		reference_name, node_path)
	var backward := _run_along(gauge, state, point, -direction, mask,
		reference_name, node_path)
	var step := _probe_step(forward, backward)
	if step <= 0.0:
		# Too thin to place the parity sphere in on one side or the other.
		# The crossing stands: a body this check cannot probe is not a body it
		# may clear.
		return true
	for offset in [step, -step]:
		# 1 inside, 0 outside, -1 undecidable — and undecidable keeps the
		# crossing, exactly as the solid side does: a probe the gauge could
		# not read (a ray out of crossing budget in a layered node) is not
		# evidence that the edge merely grazed a rim.
		if _inside_reference(gauge, state, point + direction * offset,
				reference_name, node_path) != 0:
			return true
	return false


## How far the material runs from `point` along `direction`, up to the probe
## ceiling. The ceiling itself when nothing ends inside it — the run is at
## least that far, and the exact figure past it changes no decision.
func _run_along(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	point: Vector3,
	direction: Vector3,
	mask: int,
	reference_name: String,
	node_path: String
) -> float:
	_casts += 1
	var exit: Dictionary = gauge.call("run_now", state, "raycast", {
		"from": point + direction * TOUCH_EPSILON_MM,
		"to": point + direction * PENETRATION_PROBE_MM,
		"mask": mask,
		"reference": reference_name,
		"node": node_path,
	})
	if not bool(exit.get("hit", false)):
		return PENETRATION_PROBE_MM
	return float(exit.get("distance", PENETRATION_PROBE_MM)) + TOUCH_EPSILON_MM


## The step to probe with, given the material either side of the hit: half the
## SHORTER run, so the probe lands inside whichever side is thinner rather
## than through it. Zero when either side is too thin to place the parity
## sphere in — half the run is then no more than the sphere's radius, half of
## PARITY_SPHERE_MM — which is the caller's signal to keep the crossing.
func _probe_step(forward_mm: float, backward_mm: float) -> float:
	var shorter := minf(forward_mm, backward_mm)
	if shorter <= PARITY_SPHERE_MM:
		return 0.0
	if shorter >= PENETRATION_PROBE_MM:
		# Material runs at least the ceiling both ways: the ceiling is the
		# step, as it always was for a body thick enough to take it.
		return PENETRATION_PROBE_MM
	return shorter * 0.5


## The ray the contact-run rule needs for one crossing, chosen by the
## the "<reference>\n<node>" key (newline-joined) the crossing was recorded under.
func _reference_ray_for(
	key: String,
	gauge: Object,
	state: PhysicsDirectSpaceState3D
) -> Callable:
	var parts := key.split("\n")
	var reference_name: String = parts[0] if parts.size() > 0 else ""
	var node_path: String = parts[1] if parts.size() > 1 else ""
	return _reference_hit.bind(gauge, state, reference_name, node_path)


## One ray against ONE node of one reference, for the contact-run rule. The
## first hit's position, or null. Scoped to that node so a neighbouring body
## cannot vouch for a run.
func _reference_hit(
	from: Vector3,
	to: Vector3,
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	reference_name: String,
	node_path: String
) -> Variant:
	_casts += 1
	var hit: Dictionary = gauge.call("run_now", state, "raycast", {
		"from": from,
		"to": to,
		"mask": int(gauge.call("mask_for", reference_name)),
		"reference": reference_name,
		"node": node_path,
	})
	if not bool(hit.get("hit", false)):
		return null
	return hit.get("position", null)


## Drop the crossings that only bound a run LYING IN a face of the body they
## crossed — a designed flush fit whose shared rim this edge cut. The rays it
## costs are only spent on crossings everything else has already called a
## penetration.
func _drop_contact_runs(a: Vector3, b: Vector3, crossings: Array,
		ray_for: Callable) -> Array:
	if crossings.is_empty():
		return crossings
	var out: Array = []
	for kept in _ContactRuns.penetrating_indices(a, b, crossings,
			TOUCH_EPSILON_MM, ray_for):
		out.append(crossings[kept])
	return out


## The same, against the solid's own collider.
func _solid_hit(
	from: Vector3,
	to: Vector3,
	solid_state: PhysicsDirectSpaceState3D
) -> Variant:
	var hit := _solid_ray(solid_state, from, to)
	if hit.is_empty():
		return null
	return hit.get("position", null)


## The same question the other way round. An undecidable parity keeps the
## crossing: a probe that could not be read must not quietly clear a part.
func _penetrates_solid(
	solid_state: PhysicsDirectSpaceState3D,
	point: Vector3,
	direction: Vector3
) -> bool:
	var step := _probe_step(
		_solid_run_along(solid_state, point, direction),
		_solid_run_along(solid_state, point, -direction))
	if step <= 0.0:
		return true
	for offset in [step, -step]:
		if _parity_inside_solid(solid_state, point + direction * offset) != 0:
			return true
	return false


## _run_along, in the solid's own space.
func _solid_run_along(
	solid_state: PhysicsDirectSpaceState3D,
	point: Vector3,
	direction: Vector3
) -> float:
	var exit := _solid_ray(solid_state, point + direction * TOUCH_EPSILON_MM,
		point + direction * PENETRATION_PROBE_MM)
	if exit.is_empty():
		return PENETRATION_PROBE_MM
	return point.distance_to(exit.get("position", point)) + TOUCH_EPSILON_MM


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
			break
		var point: Vector3 = hit.get("position", Vector3.ZERO)
		var travelled := a.distance_to(point)
		# A crossing at either end of the edge is a touch, not a penetration:
		# a face resting on a face meets exactly there. Neither is a hit the
		# edge does not straddle — it lies in that surface, or climbs off it,
		# rather than passing through.
		if travelled > TOUCH_EPSILON_MM and (length - travelled) > TOUCH_EPSILON_MM \
				and _straddles(a, b, point, hit) \
				and _penetrates_reference(gauge, state, point, direction, mask,
					str(hit.get("reference", "")), str(hit.get("node", ""))):
			out.append({
				"point": point,
				"key": str(hit.get("reference", "")) + "\n"
					+ str(hit.get("node", "")),
				"node": str(hit.get("node", "")),
				"reference": str(hit.get("reference", "")),
				"distance": travelled,
			})
		var next := point + direction * CROSSING_ADVANCE_MM
		if a.distance_to(next) >= length:
			break
		cursor = next
	return _drop_contact_runs(a, b, out,
		_reference_ray_for.bind(gauge, state))


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
	var candidates: Array = []
	for _step in range(MAX_CROSSINGS_PER_EDGE):
		var hit := _solid_ray(solid_state, cursor, b)
		if hit.is_empty():
			break
		var point: Vector3 = hit.get("position", Vector3.ZERO)
		var travelled := a.distance_to(point)
		if travelled > TOUCH_EPSILON_MM and (length - travelled) > TOUCH_EPSILON_MM \
				and _straddles(a, b, point, hit) \
				and _penetrates_solid(solid_state, point, direction):
			candidates.append({"point": point, "key": ""})
		var next := point + direction * CROSSING_ADVANCE_MM
		if a.distance_to(next) >= length:
			break
		cursor = next
	# Only one body here, so every crossing carries the same key and the ray is
	# the same one whichever crossing asks for it.
	for kept in _ContactRuns.penetrating_indices(a, b, candidates,
			TOUCH_EPSILON_MM,
			func(_key: String) -> Callable: return _solid_hit.bind(solid_state)):
		out.append((candidates[kept] as Dictionary).get("point", Vector3.ZERO))
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
## one collision at a time. A node whose containment could not be decided is
## named too, WHETHER OR NOT anything else was found: an evaluation that
## reports a pin and stays silent about the washer beside it reads on screen
## as "the washer is fine", which is the one thing it does not know.
func status_line(report: Dictionary) -> String:
	var undecided: Array = report.get("undecidable", []) as Array
	var pairs: Array = report.get("pairs", []) as Array
	if int(report.get("count", 0)) <= 0 or pairs.is_empty():
		if not undecided.is_empty():
			var one: Dictionary = undecided[0]
			return "Interference: undecided for %s%s — %s." % [
				_undecided_name(one),
				_undecided_others(undecided),
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
	var open_tail := ""
	if not undecided.is_empty():
		open_tail = " %s%s undecided." % [
			_undecided_name(undecided[0]), _undecided_others(undecided)]
	return "Interference: the solid runs into %s/%s%s — %d point(s)%s.%s" % [
		str(first.get("reference", "")),
		str(first.get("node", "")),
		where,
		int(report.get("point_count", 0)),
		suffix,
		open_tail,
	]


## What to call an undecided entry on the banner: its node, or the reference
## when the record carried no node path.
func _undecided_name(one: Dictionary) -> String:
	var name := str(one.get("node", ""))
	return name if not name.is_empty() \
		else str(one.get("reference", "the reference"))


func _undecided_others(undecided: Array) -> String:
	return " (and %d other)" % (undecided.size() - 1) \
		if undecided.size() > 1 else ""


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


func _pose_for(reference_name: String) -> Transform3D:
	return _pose_in(_records, reference_name)


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
