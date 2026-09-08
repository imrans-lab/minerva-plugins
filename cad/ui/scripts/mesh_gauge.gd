## mesh_gauge.gd — the VERIFY half of measuring a foreign mesh.
##
## A fit is a hypothesis about geometry; this module is the physical test of
## it. Every triangle of every mounted reference becomes a collider, and the
## questions are asked the way a machinist asks them: does a pin of this size
## go in, does it go all the way through, and if it does not, where does it
## touch. The answers come from the physics server, so they are answers about
## the geometry that is actually there — not about the numbers a fit produced.
##
## SIX CONSTRAINTS ARE STRUCTURAL HERE, EACH ONE MEASURED BY ITS FAILURE:
##
## 1. QUERIES RUN FROM THE PHYSICS STEP. Minerva sets
##    physics/3d/run_on_separate_thread, and a space's direct state is only
##    reachable while the step is running. A tool handler therefore cannot ask
##    a question inline: it submits a job and awaits it. One job runs the WHOLE
##    of a find_holes pass inside a single step, because thousands of round
##    trips at one query per frame would take minutes.
##
## 2. backface_collision IS ON for every trimesh. A ray leaving a point inside
##    the material must report the wall it leaves through, or the parity that
##    tells inside from outside counts only half the surfaces.
##
## 3. EVERY SEARCH IS BOUNDED. Free space outside the part reads exactly like
##    free space inside a hole. An unbounded centring search on a hole near the
##    outline slides the gauge out through the edge of the board and reports a
##    centre in mid-air with an unbounded radius. Every search here is confined
##    to a multiple of the candidate's own radius.
##
## 4. EVERY QUERY IS A RAY. intersect_shape against a trimesh is not usable as
##    a volume test here: measured against a plate with a drilled hole, it
##    answers only for a query shape whose ORIGIN is within the query margin of
##    a triangle. A 1 mm box penetrating a face by 0.2 mm reports nothing, a
##    20 mm one reports nothing, a sphere sitting in the hole never finds the
##    wall it encloses whatever its radius, and a margin of exactly 0 reports
##    nothing at all. Rays are exact, so a gauge is tested by casting from its
##    axis out to its own surface: a ray that hits is a place the pin fouls,
##    and the shortest hit IS the largest pin that goes in — no bisection.
##
## 5. A COLLIDER IS A SURFACE, NOT A VOLUME. A gauge wholly inside solid
##    material reaches no wall, and that is indistinguishable from open air.
##    Inside and outside are told apart by the parity of the surfaces a ray
##    from the point crosses, and only then may a clear gauge be read as a fit.
##
## 6. ONE BODY PER COLLIDER, ONE LAYER PER REFERENCE UNTIL THE LAYERS RUN OUT.
##    Physics sees every body in the space, so a measurement asked about one
##    part uses its layer. References beyond Godot's 32 bits share the last
##    layer and exclude their peers by RID. Each MESH is nevertheless its own
##    body, because a ray query can only exclude whole bodies: two plates
##    resting face to face put two triangles at one point, and finding the
##    second one means re-casting with the first one's body excluded.
##
## The gauge frame lives in gauge_shapes.gd, the ray patterns one gauge is
## measured with in gauge_probe.gd and the ray-grid fallback's arithmetic in
## gauge_seed.gd; what is left here is the colliders, the job queue and the
## casts themselves.
##
## 7. THE EVALUATED SOLID IS IN ANOTHER WORLD. Its collider is rebuilt on
##    every evaluation and belongs to interference_world.gd, so a gauge that
##    asked only this space read a point buried in the part as open air and
##    answered "fits" everywhere. An unscoped gauge job therefore carries that
##    module and casts each ray into BOTH spaces, keeping the nearer hit. A
##    job scoped by reference= does not: that question is about one mounted
##    reference, and the part standing next to it is not an answer to it.
##
## The module is a Node so that it can own a physics step, and it holds its
## colliders in a SubViewport with its own World3D — the panel's four panes
## share Minerva's main world, and measurement colliders have no business in
## it. All coordinates in and out are WORLD millimetres (the posed CAD frame);
## posing and un-posing is the caller's job.
extends Node

const _Shapes: Script = preload("gauge_shapes.gd")
const _Seed: Script = preload("gauge_seed.gd")
const _Probe: Script = preload("gauge_probe.gd")

## A submitted job that has not run within this long is abandoned. Physics can
## stop stepping entirely — the panel closes, the host pauses — and an MCP call
## must fail with a reason rather than await forever.
const JOB_TIMEOUT_MS: int = 5000
## How far past a candidate's own extent a centring search may wander, as a
## multiple of the candidate radius. This is constraint 3 in one number.
const SEARCH_BOUND_FACTOR: float = 2.0
## Gauge length as a fraction of the candidate's axial extent: short enough not
## to foul the mouth of the hole, long enough to be a pin and not a disc.
const GAUGE_LENGTH_FRACTION: float = 0.6
## A gauge diameter within this fraction of the fit's inscribed prediction
## counts as confirming the fit.
const VERIFY_TOLERANCE_FRACTION: float = 0.05
## Half-width of the band a convex candidate's wall is looked for in, as a
## fraction of the candidate radius. Wide enough to swallow the tessellation
## of a faceted cylinder, narrow enough that a wall at the wrong radius misses.
## An inward ray must stop between r·(1−f) and r·(1+f). A faceted wall sits at
## r·cos(π/n)..r, so it is inside the band only for n ≥ 10 facets at f = 0.05;
## coarser bosses may verify or not depending on where the four rays land.
const WALL_PROBE_FRACTION: float = 0.05

## Ray-grid fallback pitch, used only when the fitter proposed nothing at all.
const SEED_PITCH_MM: float = 1.0

## Every collision layer at once: the mask an unscoped query uses.
const ALL_LAYERS: int = 0xFFFFFFFF
## The final bit is shared by overflow references; their bodies are then
## isolated by RID. Keeping dedicated layers for the first 31 preserves the
## hot path for ordinary documents and the mask_for() compatibility contract.
const MAX_REFERENCE_LAYERS: int = 32
## How far a crossing ray is nudged past a band of coincident faces before the
## next cast. Small enough that it cannot step over a wall, large enough that
## the ray makes progress.
const CROSSING_ADVANCE_MM: float = 0.0002
## Two hits this close together are at the same point and belong to one band.
const COINCIDENT_EPSILON_MM: float = 0.001
## Crossings counted before an inside/outside test gives up. A closed part with
## more than this many walls along one line is pathological; the test then says
## "not inside", which is the answer that cannot invent a refusal.
const MAX_CROSSINGS: int = 64
## Casts allowed per inside/outside ray. The short nudge means a cast can be
## spent re-finding a face already counted, so the cast count is bounded
## separately from the crossing count.
const MAX_CROSSING_CASTS: int = 256

signal job_finished


var _viewport: SubViewport = null
## Every collider body, in the order they were built. One per mesh.
var _bodies: Array = []
## Reference name -> collision layer. The final layer may name several
## references; run_now() adds RID exclusions only for that overflow case.
var _layers: Dictionary = {}
## Body instance id -> the BARE node path that body's mesh came from — the same
## string find_holes reports in `nodes`, the selection verbs report as `node`
## and a node= filter matches. Which reference it belongs to is a separate
## field, kept per body below.
var _body_nodes: Dictionary = {}
## Body instance id -> the reference name that body belongs to.
var _body_references: Dictionary = {}
## Bounds of every collider, in world millimetres. This is the reach an
## unbounded search is allowed and the length of an inside/outside ray.
var _bounds: AABB = AABB()
## Mask for the job currently running. Normally this is one dedicated layer;
## overflow references share the last layer and add _scope_exclude entries.
var _query_mask: int = ALL_LAYERS
## Body RIDs hidden from every ray in the job currently running. Jobs are
## serialised in one physics step, so one field keeps the deeply nested gauge
## queries honest without threading an exclude list through every helper.
var _scope_exclude: Array[RID] = []
## The EVALUATED SOLID's space and the module that owns it, for the job
## currently running, or null when the job carries none. See constraint 7.
var _solid_state: PhysicsDirectSpaceState3D = null
var _solid_checks: Object = null
## World bounds of that solid, merged into the reach of an unbounded search so
## a gauge standing outside the references' box is still measured against the
## part.
var _solid_bounds: AABB = AABB()
## Identity of the reference set the current colliders were built from, as
## the CALLER names it (the panel's file/stamp/pose digest).
var _digest: String = ""
## Identity of the BODIES the colliders were actually built from — mesh,
## transform, node and reference of each — computed here from the build's own
## input, so a check can ask whether the colliders describe the records it is
## holding without knowing how the caller labels a build.
var _bodies_digest: String = ""
var _shape_count: int = 0
## Increments once per ACTUAL rebuild. A caller cannot tell a cache hit from a
## rebuild by the returned shape count — both return the same number — so the
## generation is the only observable that distinguishes them.
var _generation: int = 0
var _queue: Array = []


func _ready() -> void:
	# An isolated world: its own physics space, nothing rendered, no picking.
	# The panel's panes share the main window's world and must stay clean.
	_viewport = SubViewport.new()
	_viewport.name = "GaugeWorld"
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(4, 4)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.physics_object_picking = false
	add_child(_viewport)

	set_physics_process(true)
	# A measurement is a question the host asked, not part of the simulation:
	# it must still be answered while the tree is paused, or a paused host
	# leaves an MCP call waiting for a physics step that never runs.
	process_mode = Node.PROCESS_MODE_ALWAYS


# ---------------------------------------------------------------------------
# Colliders
# ---------------------------------------------------------------------------

## Rebuild the collider set from `bodies`, a list of
## {mesh: Mesh, transform: Transform3D, node: String, reference: String} in
## WORLD millimetres. `digest` identifies the set: an identical digest is a
## no-op, which is what keeps a keystroke that only moves a pose from
## rebuilding 45 trimeshes.
##
## Each MESH gets its own StaticBody3D. Most references get a dedicated layer;
## references beyond 32 share the final layer and are isolated by RID.
func build(bodies: Array, digest: String) -> int:
	if digest == _digest and _shape_count > 0:
		return _shape_count
	clear()
	_generation += 1
	_bodies_digest = bodies_digest(bodies)
	if _viewport == null:
		return 0
	var have_bounds := false
	for entry in bodies:
		if not (entry is Dictionary):
			continue
		var body: Dictionary = entry
		var mesh: Mesh = body.get("mesh", null)
		if mesh == null:
			continue
		# glTF stores metres. Build the collider in world millimetres before
		# physics constructs its triangle acceleration structure; a 1000x
		# shape-owner scale leaves tiny local triangles below ray tolerances.
		var xform: Transform3D = body.get("transform", Transform3D.IDENTITY)
		var faces := mesh.get_faces()
		if faces.is_empty():
			continue
		for i in range(faces.size()):
			faces[i] = xform * faces[i]
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		# Without backface collision a gauge grows straight through the wall of
		# the hole it sits in and reports an unbounded radius.
		shape.backface_collision = true
		var node_name := str(body.get("node", ""))
		var reference := str(body.get("reference", node_name.get_slice("/", 0)))
		# The caller may name the node either bare or prefixed by its
		# reference; only the bare path is an identity a caller can also type.
		if not reference.is_empty() and node_name.begins_with(reference + "/"):
			node_name = node_name.substr(reference.length() + 1)
		var collider := _new_body(reference, node_name)
		var owner_id := collider.create_shape_owner(collider)
		collider.shape_owner_add_shape(owner_id, shape)
		var box := xform * mesh.get_aabb()
		_bounds = box if not have_bounds else _bounds.merge(box)
		have_bounds = true
		_shape_count += 1
	_digest = digest
	return _shape_count


## A new body for one mesh. Allocate a dedicated layer while one is available,
## then share the final layer; overflow peers are excluded by RID per job.
func _new_body(reference: String, node_name: String) -> StaticBody3D:
	if not _layers.has(reference):
		var index: int = mini(_layers.size(), MAX_REFERENCE_LAYERS - 1)
		_layers[reference] = 1 << index
	var collider := StaticBody3D.new()
	collider.name = "Collider_%d" % _bodies.size()
	# The body collides with nothing itself — it is only ever a query target.
	collider.collision_layer = int(_layers[reference])
	collider.collision_mask = 0
	_viewport.add_child(collider)
	_bodies.append(collider)
	_body_nodes[collider.get_instance_id()] = node_name
	_body_references[collider.get_instance_id()] = reference
	return collider


## Collision mask for direct callers and panel_tools. Overflow references share
## the final mask; submit(reference=...) disambiguates them by RID.
func mask_for(reference: String) -> int:
	if reference.is_empty() or not _layers.has(reference):
		return ALL_LAYERS
	return int(_layers[reference])


func clear() -> void:
	for entry in _bodies:
		# Validated before it is bound to a typed local: in the release
		# template a freed instance bound to StaticBody3D is a dangling pointer.
		if not (entry is StaticBody3D and is_instance_valid(entry)):
			continue
		var collider: StaticBody3D = entry
		var parent: Node = collider.get_parent()
		if parent != null:
			parent.remove_child(collider)
		collider.queue_free()
	_bodies.clear()
	_layers.clear()
	_body_nodes.clear()
	_body_references.clear()
	_bounds = AABB()
	_shape_count = 0
	_digest = ""
	_bodies_digest = ""


func is_built() -> bool:
	return _shape_count > 0


func get_digest() -> String:
	return _digest


## Digest of the bodies the current colliders were built from; compare with
## bodies_digest(bodies_from_records(records)) to know whether the colliders
## and a set of records describe the same geometry at the same poses.
func get_bodies_digest() -> String:
	return _bodies_digest


## The collider bodies a panel's reference records describe: every part of
## every record, its transform composed with the record's pose into WORLD
## millimetres, its node named by PATH under the reference (two branches of a
## foreign assembly may both hold a node called "Body"). The ONE derivation
## from records to bodies — the panel builds from it and a check digests from
## it, so the two cannot disagree about what a record's colliders are.
static func bodies_from_records(records: Array) -> Array:
	var bodies: Array = []
	for entry in records:
		if not (entry is Dictionary):
			continue
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var reference_name := str(record.get("name", ""))
		for part_entry in record.get("parts", []):
			var part: Dictionary = part_entry
			bodies.append({
				"mesh": part.get("mesh", null),
				"transform": pose * (part.get("transform", Transform3D.IDENTITY) as Transform3D),
				"node": "%s/%s" % [reference_name,
					str(part.get("node_path", part.get("node", "")))],
				"reference": reference_name,
			})
	return bodies


## Identity of a body list as build() reads it: the mesh OBJECT (a record's
## mesh is never rewritten, so the same mesh is the same geometry), its world
## transform, and the node under its reference, with the reference prefix
## stripped exactly as build() strips it, so a caller naming nodes bare and
## one naming them by path digest alike. Bodies build() would skip (no mesh)
## are skipped here too.
static func transform_identity(xform: Transform3D) -> String:
	# Variant encoding preserves every numeric component; display strings round.
	return var_to_bytes(xform).hex_encode()


static func bodies_digest(bodies: Array) -> String:
	var parts := PackedStringArray()
	for entry in bodies:
		if not (entry is Dictionary):
			continue
		var body: Dictionary = entry
		var mesh: Mesh = body.get("mesh", null)
		if mesh == null:
			continue
		var node_name := str(body.get("node", ""))
		var reference := str(body.get("reference", node_name.get_slice("/", 0)))
		if not reference.is_empty() and node_name.begins_with(reference + "/"):
			node_name = node_name.substr(reference.length() + 1)
		var xform: Transform3D = body.get("transform", Transform3D.IDENTITY)
		parts.append("%s@%s@%d@%s" % [reference, node_name,
			mesh.get_instance_id(), transform_identity(xform)])
	return "|".join(parts)


func get_shape_count() -> int:
	return _shape_count


## How many times the collider set has actually been rebuilt.
func get_generation() -> int:
	return _generation


# ---------------------------------------------------------------------------
# Job submission — constraint 1
# ---------------------------------------------------------------------------

## Ask a question and await the answer. The job body runs inside the next
## physics step, where the space's direct state is legal to touch.
##
## The wait is on the tree's idle frame rather than on job_finished, because
## job_finished is emitted by the physics step and the whole point of the
## timeout is to survive a physics step that never comes: a panel closed
## mid-call, or a host that stopped stepping. An MCP call must always return.
func submit(kind: String, args: Dictionary) -> Dictionary:
	if _viewport == null or not is_inside_tree():
		return {"error": "gauge is not in the scene tree; no physics step to run in"}
	var tree := get_tree()
	if tree == null:
		return {"error": "gauge has no scene tree; no physics step to run in"}
	var ticket := {"kind": kind, "args": args, "done": false, "result": {}}
	_queue.append(ticket)
	var deadline := Time.get_ticks_msec() + JOB_TIMEOUT_MS
	while not bool(ticket["done"]):
		if Time.get_ticks_msec() > deadline:
			_queue.erase(ticket)
			return {"error": "gauge job '%s' did not run within %d ms; the physics "
				% [kind, JOB_TIMEOUT_MS] + "step is not running"}
		await tree.process_frame
		if _viewport == null or not is_inside_tree():
			_queue.erase(ticket)
			return {"error": "the gauge left the scene tree while '%s' was pending" % kind}
	return ticket["result"]


func _physics_process(_delta: float) -> void:
	if _queue.is_empty():
		return
	var state := space_state()
	var pending := _queue
	_queue = []
	for entry in pending:
		var ticket: Dictionary = entry
		if state == null:
			ticket["result"] = {"error": "physics space unavailable"}
		else:
			ticket["result"] = run_now(state, str(ticket["kind"]), ticket["args"])
		ticket["done"] = true
	job_finished.emit()


## The space the colliders live in. Only legal to dereference during the
## physics step when physics runs on its own thread — which is why everything
## goes through submit(). Public so a headless script can drive the module
## directly from its own physics frame.
##
## find_world_3d(), not world_3d: `world_3d` is the explicitly ASSIGNED override
## and stays null for a viewport that made its own world through own_world_3d.
## Reading it there returns null and every measurement fails as "no space".
func space_state() -> PhysicsDirectSpaceState3D:
	if _viewport == null or not _viewport.is_inside_tree():
		return null
	var world := _viewport.find_world_3d()
	return world.direct_space_state if world != null else null


## Run one job with a space state already in hand. Every measurement lives
## here, so a headless caller with its own physics frame can use the whole
## surface without the queue.
##
## ONE SCOPING RULE: `mask` is the scope. ALL_LAYERS means the whole assembly,
## and then every body is fair game — a mating part obstructing a hole is
## exactly what an unscoped question is asking about. A narrower mask names
## one reference; `reference` then only disambiguates the bodies that share
## that mask's layer beyond the 32-layer ceiling. A reference name on an
## unscoped job is ignored, so a caller cannot half-scope a job by accident.
func run_now(state: PhysicsDirectSpaceState3D, kind: String, args: Dictionary) -> Dictionary:
	_query_mask = int(args.get("mask", ALL_LAYERS))
	_scope_exclude = _excluded_bodies(
		str(args.get("reference", "")), _query_mask)
	# Cleared for every job. Only the gauge takes the solid, and only inside
	# its own handler: the interference and fastener jobs carry the very same
	# module in `checks` and cast into its world themselves, so taking it here
	# would put the solid into every reference ray those checks make.
	_clear_solid_scope()
	match kind:
		"raycast":
			return _job_raycast(state, args)
		"gauge":
			return _job_gauge(state, args)
		"measure_holes":
			return _job_measure_holes(state, args)
		"measure_convex":
			return _job_measure_convex(state, args)
		"seed_grid":
			return _job_seed_grid(state, args)
		"interference", "fasteners":
			return _job_module(state, args)
	return {"error": "unknown gauge job '%s'" % kind}


## A job whose QUESTION belongs to another module and whose PHYSICS STEP
## belongs here. The module travels in the job and answers it with this
## space's state in hand — geometry_checks.gd queries the references here and
## the evaluated solid in a world of its own, and both are only legal to touch
## inside the step this queue owns. fastener_checks.gd asks the same way, and
## its job kind is separate only so a queued job says which question it is.
func _job_module(state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	var module: Object = args.get("module", null)
	if module == null or not is_instance_valid(module) \
			or not module.has_method("run_check"):
		return {"error": "the job carried no module able to run it"}
	return module.call("run_check", self, state, args)


# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

func _job_raycast(state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	var from: Vector3 = args.get("from", Vector3.ZERO)
	var to: Vector3 = args.get("to", Vector3.ZERO)
	var excluded: Array[RID] = []
	var node_filter := str(args.get("node", ""))
	var reference_filter := str(args.get("reference", ""))
	if not node_filter.is_empty():
		for body in _bodies:
			if str(_body_nodes.get(body.get_instance_id(), "")) != node_filter \
					or (not reference_filter.is_empty() \
						and str(_body_references.get(body.get_instance_id(), "")) != reference_filter):
				excluded.append(body.get_rid())
	var hit := _ray(state, from, to, excluded)
	if hit.is_empty():
		return {"hit": false}
	return {
		"hit": true,
		"position": hit["position"],
		"normal": hit["normal"],
		"node": _node_for(hit),
		"reference": _reference_for(hit),
		"distance": (hit["position"] as Vector3).distance_to(from),
	}


## The gauge verb: place a shape and report whether it fits, what it touched,
## and — when it fits — how much larger it could be before it stopped.
func _job_gauge(state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	_take_solid_scope(args)
	var at: Vector3 = args.get("at", Vector3.ZERO)
	var axis: Vector3 = _Shapes.unit(args.get("axis", Vector3.UP))
	var kind := str(args.get("shape", "cylinder"))
	var size: Vector3 = args.get("size", Vector3.ONE)
	if not _Shapes.is_supported(kind):
		return {"error": "unsupported gauge shape '%s'" % kind}

	var cast := _caster(state)
	var contacts: Array = _contacts(_Probe.fouls(cast, kind, size, at, axis))
	if contacts.is_empty():
		# A trimesh collider is a SURFACE, not a volume: a gauge buried in solid
		# material reaches no wall, which is exactly what open air looks like.
		# Parity along a ray separates the two.
		# A caller asking about ONE node's material passes node=; the parity
		# then counts only the crossings that body accounts for, so a
		# neighbour cannot vouch for a point inside itself.
		var inside := _inside_solid(state, at, str(args.get("node", "")))
		if inside < 0:
			return {"error": "cannot tell solid from air at %s: a ray from it "
				% str(at) + "crossed more surfaces than the crossing budget allows"}
		if inside > 0:
			return {
				"fits": false,
				# The skin of the material it is buried in, when the caller
				# asked for a witness. A gauge inside a wall thicker than
				# itself crosses no triangle, so the nearest surface is looked
				# for rather than collected from the rays that tested it — and
				# the containment probes, which fire thousands of these and
				# read only `reason`, do not pay for it.
				"contacts": _witness(cast, at) \
					if bool(args.get("witness", false)) else [],
				"clearance_mm": 0.0,
				"reason": "inside_solid",
			}
		# How much fatter a pin could be here. The bound is the caller's own
		# largest interesting diameter, or the whole scene when it gave none —
		# never an arbitrary multiple of the pin, which reports 1.5 mm of
		# clearance for a 1 mm pin standing in a 10 mm bore.
		var bound := float(args.get("max_radius_mm", 0.0))
		if bound <= 0.0:
			bound = maxf(size.x * 0.5, _search_bounds().size.length() * 0.5)
		# A gauge in open space reaches no wall, so the search bound is all
		# the run there is evidence for. That is a FLOOR, not a clearance: it
		# is reported under its own key so no caller can read the bound as a
		# measured distance to something.
		var grown: Dictionary = _Probe.free_air(cast, kind, size, at, axis, bound)
		var bounded := bool(grown["bounded"])
		var clearance := float(grown["clearance_mm"])
		var fitted_report := {
			"fits": true,
			"contacts": [],
			"clearance_bound_mm": bound,
			"clearance_bounded": bounded,
		}
		if bounded:
			fitted_report["clearance_mm"] = clearance
		else:
			fitted_report["clearance_at_least_mm"] = clearance
			fitted_report["reason"] = "no surface within the search bound: the "\
				+ "clearance is at least this much, not exactly this much"
		return fitted_report

	# Every contact came from a ray that ended on the geometry, so the point,
	# the node and the reference are the ray's own answer — nothing has to be
	# zipped or guessed.
	return {"fits": false, "contacts": contacts, "clearance_mm": 0.0}


## Verify and measure proposed hole candidates. Candidates arrive in WORLD
## millimetres from mesh_features.gd, already posed by the caller.
func _job_measure_holes(state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	var out: Array = []
	for entry in args.get("candidates", []):
		out.append(_verify_hole(state, entry as Dictionary))
	return {"holes": out}


func _job_measure_convex(state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	var out: Array = []
	for entry in args.get("candidates", []):
		out.append(_verify_convex(state, entry as Dictionary))
	return {"cylinders": out}


## The fallback when the fitter proposed nothing: a ray-grid seed pass. The
## grid arithmetic and the clustering live in gauge_seed.gd; the only physics
## in it is the question "does this ray hit anything", handed over as a call.
func _job_seed_grid(state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	var hits := func(from: Vector3, to: Vector3) -> bool:
		return not _ray(state, from, to).is_empty()
	return _Seed.seed_grid(
		args.get("bounds", AABB()),
		_Shapes.unit(args.get("axis", Vector3.UP)),
		float(args.get("pitch_mm", SEED_PITCH_MM)),
		hits)


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

## Refine a hole candidate's centre, measure the largest pin that fits, and ask
## whether the hole goes through. Everything is bounded to the candidate's own
## radius (constraint 3); a hole 3 mm from the outline stays put instead of
## sliding off the edge of the part.
func _verify_hole(state: PhysicsDirectSpaceState3D, candidate: Dictionary) -> Dictionary:
	var axis: Vector3 = _Shapes.unit(candidate.get("axis", Vector3.UP))
	var centre: Vector3 = candidate.get("center", Vector3.ZERO)
	var radius := float(candidate.get("radius_mm", 0.0))
	if radius <= 0.0:
		return _unverified(candidate, "candidate has no radius")
	var half_extent := float(candidate.get("half_extent_mm", radius))
	var bound := radius * SEARCH_BOUND_FACTOR
	var probe := maxf(0.02, radius * 0.25)
	var length := maxf(0.2, half_extent * 2.0 * GAUGE_LENGTH_FRACTION)

	var basis: Basis = _Shapes.basis_for_axis(axis)
	var cast := _caster(state)
	for _round in range(2):
		centre = _Probe.recentre(cast, centre, basis.x, probe, bound)
		centre = _Probe.recentre(cast, centre, basis.y, probe, bound)

	var fitted: Dictionary = _Probe.largest_radius(
		cast, centre, axis, length, probe, radius * 1.5)
	var through_report: Dictionary = _Probe.through(cast, centre, axis, half_extent)

	var predicted := float(candidate.get("inscribed_dia_mm", radius * 2.0))
	var fitted_radius := float(fitted["radius_mm"])
	var bounded := bool(fitted["bounded"])
	var gauge_dia := fitted_radius * 2.0
	var verified: bool = bounded and fitted_radius > 0.0 \
		and absf(gauge_dia - predicted) \
		<= maxf(0.02, predicted * VERIFY_TOLERANCE_FRACTION)

	var out := candidate.duplicate(true)
	out["center"] = centre
	out["axis"] = axis
	out["through"] = bool(through_report["through"])
	out["depth_mm"] = float(through_report["depth_mm"])
	out["verified"] = verified
	out["gauge_bounded"] = bounded
	if bounded:
		out["gauge_dia_mm"] = gauge_dia
	else:
		# No wall anywhere within the search bound: the pin is standing in open
		# air, so the bound is a floor on the diameter and not a diameter.
		out["gauge_dia_mm"] = 0.0
		out["gauge_dia_at_least_mm"] = gauge_dia
		out["reason"] = "no wall within the search bound; this is not a hole"
	out["source"] = str(candidate.get("source", "fit"))
	return out


## A boss is verified by CONTACT with its wall, not by solid material inside
## it. A trimesh collider is a surface, not a volume: a probe sitting inside a
## boss touches nothing at all, so "is there material at r-e" always answers
## no. The physical question that does discriminate is where the wall is — a
## probe straddling the fitted radius must touch it, and a probe standing off
## the radius by a clear margin must touch nothing. Sampled at four angles so
## a partial cylinder — a fillet, say — cannot pass as a full boss.
func _verify_convex(state: PhysicsDirectSpaceState3D, candidate: Dictionary) -> Dictionary:
	var axis: Vector3 = _Shapes.unit(candidate.get("axis", Vector3.UP))
	var centre: Vector3 = candidate.get("center", Vector3.ZERO)
	var radius := float(candidate.get("radius_mm", 0.0))
	var out := candidate.duplicate(true)
	if radius <= 0.0:
		out["verified"] = false
		out["reason"] = "candidate has no radius"
		return out

	var basis: Basis = _Shapes.basis_for_axis(axis)
	var epsilon := maxf(0.05, radius * WALL_PROBE_FRACTION)
	# One ray per angle, cast INWARD from clear air outside the claimed radius
	# towards the axis. Where it stops answers both questions at once: the wall
	# is at the claimed radius when the first surface it meets is there, and the
	# air outside is clear when there was no surface before it.
	var wall_contacts := 0
	var free_outside := 0
	for i in range(4):
		var angle := float(i) * PI * 0.5
		var radial: Vector3 = (basis.x * cos(angle) + basis.y * sin(angle)).normalized()
		var outside: Vector3 = centre + radial * (radius + epsilon * 3.0)
		var hit := _ray(state, outside, centre)
		if hit.is_empty():
			# Nothing at all along this radius: clear outside, but no wall.
			free_outside += 1
			continue
		var offset: Vector3 = (hit["position"] as Vector3) - centre
		var wall_at := (offset - axis * offset.dot(axis)).length()
		if absf(wall_at - radius) <= epsilon:
			wall_contacts += 1
		if wall_at <= radius + epsilon:
			free_outside += 1
	out["wall_contacts"] = wall_contacts
	out["free_outside"] = free_outside
	out["verified"] = wall_contacts >= 3 and free_outside >= 3
	if not bool(out["verified"]):
		out["reason"] = "wall contact at %d of 4 angles, clear outside at %d of 4" \
			% [wall_contacts, free_outside]
	out["source"] = str(candidate.get("source", "fit"))
	return out


## Is this point inside the material rather than in air? 1 for inside, 0 for
## air, -1 when the ray ran out of budget before it left the part and the
## question has no answer — a caller must refuse out loud rather than pick one.
##
## A closed surface is crossed an odd number of times by any ray from an
## interior point and an even number from an exterior one, and
## backface_collision means both faces of a wall are hit, so the parity holds in
## both directions.
##
## PARITY IS PER BODY. Two parts that overlap put four surfaces on one ray
## between a point inside their intersection and open air: even, and a single
## count calls that point air. Each reference is its own body, so each body's
## crossings are counted on their own and a point inside ANY of them is inside
## solid material.
##
## Two axes are cast because one ray can graze an edge and count a crossing
## twice or not at all; a third breaks the tie when they disagree. A part with
## no colliders, or an unbounded one, is never called inside.
func _inside_solid(state: PhysicsDirectSpaceState3D, point: Vector3,
		node_filter: String = "") -> int:
	var box := _search_bounds()
	if box.size.length_squared() <= 0.0:
		return 0
	var reach := box.size.length() + _Probe.THROUGH_PAD_MM
	var first := _parity_inside(state, point, Vector3.RIGHT, reach, node_filter)
	var second := _parity_inside(state, point, Vector3.BACK, reach, node_filter)
	if first < 0 or second < 0:
		return -1
	if first == second:
		return first
	return _parity_inside(state, point, Vector3.UP, reach, node_filter)


## One ray's verdict: 1 when any body's crossings are odd, 0 when none are,
## -1 when the crossing count did not complete. `node_filter`, when given,
## narrows the count to the bodies carrying that node path — the question then
## is "inside THIS node", which is not the same as "inside something".
func _parity_inside(
	state: PhysicsDirectSpaceState3D,
	point: Vector3,
	direction: Vector3,
	reach: float,
	node_filter: String = ""
) -> int:
	# The filter goes INTO the walk. Applied afterwards, an unrelated node in
	# the same reference — forty plates, eighty surfaces — exhausts the
	# crossing budget and the walk reports "could not count", so a target with
	# one clean crossing of its own comes back undecidable because of a body
	# nobody asked about.
	var counted := _crossings(state, point, direction, reach, node_filter)
	if not bool(counted.get("complete", false)):
		return -1
	for body_id in (counted["by_body"] as Dictionary).keys():
		if int((counted["by_body"] as Dictionary)[body_id]) % 2 == 1:
			return 1
	return 0


## Surfaces crossed by a ray leaving `from` along `direction` for `reach`
## millimetres, counted PER BODY: {"complete": bool, "by_body": {id: count}}.
## `complete` is false when the ray hit a budget before it left the geometry —
## the counts are then a truncated prefix and their parity means nothing.
##
## COINCIDENT FACES ARE TWO CROSSINGS. Two plates resting on each other put
## their shared face at one point, and material continues through it: counting
## it once flips the parity of everything beyond, and every point past the
## stack then reads as inside solid material.
##
## A nearest-hit ray cannot report both faces, and no nudge can reach the second
## one: any step forward from the hit point is already past a face at the very
## same coordinate. So a band is walked by EXCLUSION instead — each body found
## at the band's point is excluded and the ray re-cast from the same origin
## until nothing more lies there. That is why every mesh is its own body.
##
## The origin then moves to the band's point plus a fixed step — not by a
## running sum of distances, which at world coordinates in the hundreds of
## millimetres stops changing once the step is a fifth of a micrometre.
## `node_filter`, when given, narrows the count to the bodies carrying that
## node path: a hit on any other body is stepped past without counting toward
## the parity OR toward the crossing budget, because it is not part of the
## question being asked.
func _crossings(
	state: PhysicsDirectSpaceState3D,
	from: Vector3,
	direction: Vector3,
	reach: float,
	node_filter: String = ""
) -> Dictionary:
	var by_body := {}
	var total := 0
	var casts := 0
	var origin := from
	var band_point := from
	var in_band := false
	var exclude: Array[RID] = []
	# Triangles already counted in this band, so a face found twice — by the
	# exclusion walk and by a re-cast — is still one crossing.
	var counted: Array = []
	while total < MAX_CROSSINGS and casts < MAX_CROSSING_CASTS:
		if from.distance_to(origin) >= reach:
			return {"complete": true, "by_body": by_body}
		casts += 1
		var hit := _ray(state, origin, from + direction * reach, exclude)
		var beyond_band := hit.is_empty() \
			or (hit["position"] as Vector3).distance_to(band_point) > COINCIDENT_EPSILON_MM
		if in_band and beyond_band:
			# The band is exhausted. Step past it and start again with every
			# body back in play, so a body crossed here can be crossed again.
			origin = band_point + direction * CROSSING_ADVANCE_MM
			exclude.clear()
			counted.clear()
			in_band = false
			continue
		if hit.is_empty():
			return {"complete": true, "by_body": by_body}
		var point: Vector3 = hit["position"]
		if not in_band:
			band_point = point
			in_band = true
		# face_index is the triangle within a concave shape; it is absent for
		# shapes that have no faces, and then body-plus-shape is the identity.
		var body_id := int(hit.get("collider_id", 0))
		var identity := "%d:%d:%d" % [
			body_id,
			int(hit.get("shape", -1)),
			int(hit.get("face_index", -1)),
		]
		var mine := node_filter.is_empty() \
			or str(_body_nodes.get(body_id, "")) == node_filter
		if mine and not (identity in counted):
			counted.append(identity)
			by_body[body_id] = int(by_body.get(body_id, 0)) + 1
			total += 1
		var rid: RID = hit.get("rid", RID())
		if rid.is_valid() and not (rid in exclude):
			exclude.append(rid)
		else:
			# Nothing left to exclude at this point; stepping past the band is
			# the only way to make progress.
			origin = band_point + direction * CROSSING_ADVANCE_MM
			exclude.clear()
			counted.clear()
			in_band = false
	return {"complete": false, "by_body": by_body}


func _unverified(candidate: Dictionary, reason: String) -> Dictionary:
	var out := candidate.duplicate(true)
	out["verified"] = false
	out["reason"] = reason
	out["gauge_dia_mm"] = 0.0
	out["through"] = false
	out["depth_mm"] = 0.0
	return out


# ---------------------------------------------------------------------------
# Shapes and queries
# ---------------------------------------------------------------------------

## One ray. `exclude` holds the collision-object RIDs this cast must not see —
## the crossing walk uses it to reach the second of two coincident faces.
func _ray(
	state: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3,
	exclude: Array[RID] = []
) -> Dictionary:
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.collision_mask = _query_mask
	params.hit_from_inside = true
	params.hit_back_faces = true
	# Almost every gauge ray has no per-ray exclusions. Reuse the immutable
	# job-scope array on that hot path; only the coincident-face crossing walk
	# needs a merged copy of it.
	if exclude.is_empty():
		params.exclude = _scope_exclude
	else:
		var ignored: Array[RID] = _scope_exclude.duplicate()
		for rid in exclude:
			if rid.is_valid() and not (rid in ignored):
				ignored.append(rid)
		params.exclude = ignored
	var hit := state.intersect_ray(params)
	if _solid_state == null:
		return hit
	return _nearer(from, hit, _solid_hit(from, to, exclude))


## The rays of one job, as the Callable gauge_probe.gd and gauge_seed.gd take.
## `state` travels in the closure so the patterns never have to hold a space.
func _caster(state: PhysicsDirectSpaceState3D) -> Callable:
	return func(from: Vector3, to: Vector3) -> Dictionary:
		return _ray(state, from, to)


## The evaluated solid's answer to the same ray, or {} when the job carries no
## solid. Marked `solid` so a contact can say what it landed on: that body is
## in another space and belongs to no mounted reference, so the node and
## reference lookups here would report it as an unattributed hit.
##
## The crossing walk's per-ray exclusions are honoured by DROPPING the hit
## rather than by handing them to the query — interference_world casts its own
## rays and takes none — and the walk only ever excludes a body it has already
## counted, so discarding one it asked not to see is the same answer one cast
## later.
func _solid_hit(from: Vector3, to: Vector3, exclude: Array[RID]) -> Dictionary:
	if _solid_checks == null or not is_instance_valid(_solid_checks):
		return {}
	var hit: Dictionary = _solid_checks.call("solid_ray", _solid_state, from, to)
	if hit.is_empty():
		return {}
	var collider: Variant = hit.get("collider", null)
	if collider is CollisionObject3D \
			and ((collider as CollisionObject3D).get_rid() in exclude):
		return {}
	hit["solid"] = true
	return hit


## Of two hits on one ray, the one the ray reaches first. Either may be empty.
func _nearer(from: Vector3, first: Dictionary, second: Dictionary) -> Dictionary:
	if first.is_empty():
		return second
	if second.is_empty():
		return first
	var a := from.distance_squared_to(first["position"] as Vector3)
	var b := from.distance_squared_to(second["position"] as Vector3)
	return first if a <= b else second


## Take the evaluated solid into the running job, or leave it out.
##
## ONLY AN UNSCOPED JOB GETS IT. `reference` names one mounted reference and a
## narrower mask says the caller is asking about that part; answering with the
## solid standing beside it would be a different question. The containment
## probes in interference_containment.gd are all scoped, and carry no module
## anyway.
func _take_solid_scope(args: Dictionary) -> void:
	_clear_solid_scope()
	var checks: Object = args.get("checks", null)
	if checks == null or not is_instance_valid(checks) \
			or not str(args.get("reference", "")).is_empty() \
			or _query_mask != ALL_LAYERS:
		return
	var state: PhysicsDirectSpaceState3D = checks.call("solid_space")
	if state == null:
		return
	_solid_state = state
	_solid_checks = checks
	_solid_bounds = checks.call("get_solid_bounds") as AABB


## Leave the solid out of every ray until a gauge job takes it again.
func _clear_solid_scope() -> void:
	_solid_state = null
	_solid_checks = null
	_solid_bounds = AABB()


## Every surface an unbounded search may reach: the reference colliders and,
## when the job carries it, the evaluated solid. A gauge standing beside the
## part but outside the references' box needs the merged reach, or its search
## bound is a box that does not contain the thing it is measured against.
func _search_bounds() -> AABB:
	if _solid_bounds.size.length_squared() <= 0.0:
		return _bounds
	if _bounds.size.length_squared() <= 0.0:
		return _solid_bounds
	return _bounds.merge(_solid_bounds)


## The one contact of a BURIED gauge: the nearest surface of the body it is
## inside, marked `witness` because it is not a place the gauge fouled — no
## ray of its own reached anything — and a consumer counting contacts as
## fouls would otherwise read it as one.
func _witness(cast: Callable, at: Vector3) -> Array:
	var found := _contacts([_Probe.nearest(cast, at,
		_search_bounds().size.length() + _Probe.THROUGH_PAD_MM)])
	for entry in found:
		(entry as Dictionary)["witness"] = true
	return found


## Raw hits turned into the contacts a caller reads. Empty hits are dropped, so
## a lookup that found nothing does not become a contact at the origin.
func _contacts(hits: Array) -> Array:
	var out: Array = []
	for entry in hits:
		var hit: Dictionary = entry
		if not hit.is_empty():
			out.append(_contact(hit))
	return out


## One contact from one hit. `on` says which body answered — "solid" is the
## evaluated part in its own world, which has no node path and belongs to no
## mounted reference; a contact that did not say so would be read as an
## unattributed reference hit.
func _contact(hit: Dictionary) -> Dictionary:
	return {
		"point_mm": hit["position"],
		"node": _node_for(hit),
		"reference": _reference_for(hit),
		"on": "solid" if bool(hit.get("solid", false)) else "reference",
	}


## The bodies a scoped job must not see: every body of ANOTHER reference that
## sits on a layer inside the mask. Empty for an unscoped job (ALL_LAYERS is
## the assembly, by the rule above) and for a reference with a layer of its
## own; non-empty only where overflow references share the final layer, which
## is what carries the isolation past the 32 collision-layer limit.
func _excluded_bodies(reference: String, mask: int) -> Array[RID]:
	var excluded: Array[RID] = []
	if reference.is_empty() or mask == ALL_LAYERS:
		return excluded
	for entry in _bodies:
		var body := entry as StaticBody3D
		if body == null or not is_instance_valid(body):
			continue
		var body_reference := str(_body_references.get(body.get_instance_id(), ""))
		if body_reference != reference and (body.collision_layer & mask) != 0:
			excluded.append(body.get_rid())
	return excluded


## The node a query hit came from. One body holds one mesh, so the body IS the
## node and no shape index has to be resolved.
func _node_for(hit: Dictionary) -> String:
	if not hit.has("collider"):
		return ""
	var collider: Variant = hit["collider"]
	if not (collider is CollisionObject3D):
		return ""
	return str(_body_nodes.get((collider as Object).get_instance_id(), ""))


## The reference a query hit belongs to. It is a property of the BODY — one
## body per reference — and is reported beside the node path rather than being
## spliced into it, so `node` stays the one identity string every other verb
## uses.
func _reference_for(hit: Dictionary) -> String:
	if not hit.has("collider"):
		return ""
	var collider: Variant = hit["collider"]
	if not (collider is CollisionObject3D):
		return ""
	return str(_body_references.get((collider as Object).get_instance_id(), ""))
