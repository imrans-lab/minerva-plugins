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
## The gauge frame lives in gauge_shapes.gd and the ray-grid fallback's
## arithmetic in gauge_seed.gd; what is left here is the queries.
##
## The module is a Node so that it can own a physics step, and it holds its
## colliders in a SubViewport with its own World3D — the panel's four panes
## share Minerva's main world, and measurement colliders have no business in
## it. All coordinates in and out are WORLD millimetres (the posed CAD frame);
## posing and un-posing is the caller's job.
extends Node

const _Shapes: Script = preload("gauge_shapes.gd")
const _Seed: Script = preload("gauge_seed.gd")

## Contacts reported for one gauge. Contacts are for telling the caller where
## it fouled, not for a complete census.
const MAX_CONTACTS: int = 8
## Rays cast around a gauge's axis, and stations along it. A ray leaving the
## axis stops at the gauge's own surface, so 24 x 5 rays sample the wall of a
## pin. The radius they measure is the hole's INRADIUS to within the sagitta of
## one facet — 0.003 mm on a 5 mm bore cut in 64 facets.
const GAUGE_AZIMUTHS: int = 24
const GAUGE_STATIONS: int = 5
## Rings of cap rays: a gauge also fouls on what its ENDS run into, so each end
## is sampled from the axis and from two rings inside the gauge radius.
const CAP_RING_FRACTIONS: Array = [0.0, 0.55, 0.95]
## A submitted job that has not run within this long is abandoned. Physics can
## stop stepping entirely — the panel closes, the host pauses — and an MCP call
## must fail with a reason rather than await forever.
const JOB_TIMEOUT_MS: int = 5000
## How far past a candidate's own extent a centring search may wander, as a
## multiple of the candidate radius. This is constraint 3 in one number.
const SEARCH_BOUND_FACTOR: float = 2.0
## Clearance either side of a candidate when a ray is cast along its axis to
## ask whether the hole goes through.
const THROUGH_PAD_MM: float = 3.0
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
		var shape := mesh.create_trimesh_shape()
		if shape == null:
			continue
		# Without backface collision a gauge grows straight through the wall of
		# the hole it sits in and reports an unbounded radius.
		shape.backface_collision = true
		var node_name := str(body.get("node", ""))
		var reference := str(body.get("reference", node_name.get_slice("/", 0)))
		# The caller may name the node either bare or prefixed by its
		# reference; only the bare path is an identity a caller can also type.
		if not reference.is_empty() and node_name.begins_with(reference + "/"):
			node_name = node_name.substr(reference.length() + 1)
		var xform: Transform3D = body.get("transform", Transform3D.IDENTITY)
		var collider := _new_body(reference, node_name)
		var owner_id := collider.create_shape_owner(collider)
		collider.shape_owner_add_shape(owner_id, shape)
		collider.shape_owner_set_transform(owner_id, xform)
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
		var collider: StaticBody3D = entry
		if is_instance_valid(collider):
			collider.get_parent().remove_child(collider)
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
			mesh.get_instance_id(), str(xform)])
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
	var hit := _ray(state, from, to)
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
	var at: Vector3 = args.get("at", Vector3.ZERO)
	var axis: Vector3 = _Shapes.unit(args.get("axis", Vector3.UP))
	var kind := str(args.get("shape", "cylinder"))
	var size: Vector3 = args.get("size", Vector3.ONE)
	if not _Shapes.is_supported(kind):
		return {"error": "unsupported gauge shape '%s'" % kind}

	var contacts := _gauge_fouls(state, kind, size, at, axis)
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
				"contacts": [],
				"clearance_mm": 0.0,
				"reason": "inside_solid",
			}
		var clearance := 0.0
		# How much fatter a pin could be here. The bound is the caller's own
		# largest interesting diameter, or the whole reference when it gave
		# none — never an arbitrary multiple of the pin, which reports 1.5 mm
		# of clearance for a 1 mm pin standing in a 10 mm bore.
		var bound := float(args.get("max_radius_mm", 0.0))
		if bound <= 0.0:
			bound = maxf(size.x * 0.5, _bounds.size.length() * 0.5)
		# A pin in open space reaches no wall, so the search bound is all the
		# radial run there is evidence for. That is a FLOOR, not a clearance:
		# it is reported under its own key so no caller can read the bound as
		# a measured distance to something.
		var bounded := true
		if kind == "cylinder":
			var grown := _largest_radius(
				state, at, axis, size.y, size.x * 0.5, bound)
			bounded = bool(grown["bounded"])
			clearance = maxf(0.0, float(grown["radius_mm"]) - size.x * 0.5)
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
	for _round in range(2):
		centre = _recentre(state, centre, basis.x, probe, bound)
		centre = _recentre(state, centre, basis.y, probe, bound)

	var fitted := _largest_radius(state, centre, axis, length, probe, radius * 1.5)
	var through_report := _through(state, centre, axis, half_extent)

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
	if _bounds.size.length_squared() <= 0.0:
		return 0
	var reach := _bounds.size.length() + THROUGH_PAD_MM
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


## Slide the gauge along `direction` until it stops fitting either way, and
## return the midpoint of the free interval. Bounded, always.
func _recentre(
	state: PhysicsDirectSpaceState3D,
	centre: Vector3,
	direction: Vector3,
	probe_radius: float,
	bound: float
) -> Vector3:
	var forward := _free_run(state, centre, direction, probe_radius, bound)
	var backward := _free_run(state, centre, -direction, probe_radius, bound)
	return centre + direction * ((forward - backward) * 0.5)


## Largest distance the probe can be pushed along `direction` and still fit.
##
## One ray does it: the FIRST surface along that direction is where the probe's
## leading edge stops, so the run is that distance less the probe's own radius.
## Constraint 3 comes free — the run cannot jump the wall of the part and read
## the open air beyond as more room — and it is bounded by `bound` besides.
func _free_run(
	state: PhysicsDirectSpaceState3D,
	centre: Vector3,
	direction: Vector3,
	probe_radius: float,
	bound: float
) -> float:
	var reach := bound + probe_radius
	var hit := _ray(state, centre, centre + direction * reach)
	if hit.is_empty():
		return bound
	var distance := centre.distance_to(hit["position"] as Vector3)
	return clampf(distance - probe_radius, 0.0, bound)


## Largest gauge radius that still fits at `centre`, measured rather than
## searched: the shortest of the rays leaving the axis IS the radius, because a
## pin of that radius touches there and nothing smaller touches anywhere.
##
## Returns {"radius_mm", "bounded"}. `bounded` is false when NO ray met a
## surface within `upper`: the gauge stands in open space, `upper` is the search
## bound rather than a wall, and the radius is only a FLOOR — the caller must
## report it as "at least this much" and never as a measurement. `radius_mm` is
## 0.0 (bounded) when a pin of `lower` would already foul, which is the caller's
## signal that the candidate is not a hole at all.
func _largest_radius(
	state: PhysicsDirectSpaceState3D,
	centre: Vector3,
	axis: Vector3,
	length: float,
	lower: float,
	upper: float
) -> Dictionary:
	var nearest := upper
	var bounded := false
	for from in _stations(centre, axis, length):
		for direction in _radials(axis):
			var hit := _ray(state, from, from + direction * upper)
			if hit.is_empty():
				continue
			bounded = true
			nearest = minf(nearest, from.distance_to(hit["position"] as Vector3))
	if bounded and nearest < lower:
		return {"radius_mm": 0.0, "bounded": true}
	return {"radius_mm": nearest, "bounded": bounded}


## Does the hole go all the way through? A ray along the axis from clear air on
## one side to clear air on the other hits nothing in a through hole and hits
## the floor of a blind pocket. This is the one question a fitter cannot
## answer: the wall of a blind pocket is the same cylinder as the wall of a
## through hole.
func _through(
	state: PhysicsDirectSpaceState3D,
	centre: Vector3,
	axis: Vector3,
	half_extent: float
) -> Dictionary:
	var reach := half_extent + THROUGH_PAD_MM
	var low := centre - axis * reach
	var high := centre + axis * reach
	var forward := _ray(state, low, high)
	if forward.is_empty():
		return {"through": true, "depth_mm": half_extent * 2.0}
	var backward := _ray(state, high, low)
	var entry_low := centre - axis * half_extent
	var entry_high := centre + axis * half_extent
	var depth_from_low := ((forward["position"] as Vector3) - entry_low).dot(axis)
	var depth_from_high := 0.0
	if not backward.is_empty():
		depth_from_high = (entry_high - (backward["position"] as Vector3)).dot(axis)
	return {
		"through": false,
		"depth_mm": maxf(0.0, maxf(depth_from_low, depth_from_high)),
	}


# ---------------------------------------------------------------------------
# Shapes and queries
# ---------------------------------------------------------------------------

## Everywhere a gauge of this shape, standing at `centre` along `axis`, runs
## into mounted geometry. Empty means it fits.
##
## Every ray starts inside the gauge and ends on its surface, so a hit is a
## point the gauge's own volume covers — and the hit names the node and the
## reference it landed on, which is what a contact has to report.
func _gauge_fouls(
	state: PhysicsDirectSpaceState3D,
	kind: String,
	size: Vector3,
	centre: Vector3,
	axis: Vector3
) -> Array:
	var contacts: Array = []
	match kind:
		"cylinder":
			var radius := maxf(0.001, size.x * 0.5)
			var half := maxf(0.0005, size.y * 0.5)
			for from in _stations(centre, axis, size.y):
				_collect(state, from, _radials(axis), radius, contacts)
			# The ends. A pin also fouls on the floor of a pocket, and the axis
			# alone would miss a floor that only reaches part of the way in.
			for direction in [axis, -axis]:
				for start in _cap_origins(centre, axis, radius):
					_collect(state, start, [direction], half, contacts)
		"sphere":
			_collect(state, centre, _sphere_directions(), maxf(0.001, size.x * 0.5), contacts)
		"box":
			var basis: Basis = _Shapes.basis_for_axis(axis)
			for direction in _sphere_directions():
				var local: Vector3 = basis.inverse() * direction
				# The box's own surface along this direction: the shortest of
				# the three face distances, so the ray ends on the box.
				var reach := INF
				for component in [
					[local.x, size.x * 0.5], [local.y, size.y * 0.5], [local.z, size.z * 0.5]
				]:
					if absf(component[0]) > 0.0001:
						reach = minf(reach, absf(component[1] / component[0]))
				if reach < INF:
					_collect(state, centre, [direction], reach, contacts)
	return contacts


## Cast one ray per direction and record every one that lands on geometry.
func _collect(
	state: PhysicsDirectSpaceState3D,
	from: Vector3,
	directions: Array,
	reach: float,
	contacts: Array
) -> void:
	for direction in directions:
		if contacts.size() >= MAX_CONTACTS:
			return
		var hit := _ray(state, from, from + (direction as Vector3) * reach)
		if hit.is_empty():
			continue
		contacts.append({
			"point_mm": hit["position"],
			"node": _node_for(hit),
			"reference": _reference_for(hit),
		})


## Points along the gauge axis the wall rays are cast from.
func _stations(centre: Vector3, axis: Vector3, length: float) -> Array:
	if length <= 0.0:
		return [centre]
	var half := length * 0.5
	var out: Array = []
	for k in range(GAUGE_STATIONS):
		var t := -half + length * float(k) / float(GAUGE_STATIONS - 1)
		out.append(centre + axis * t)
	return out


## Unit directions around the axis, in the gauge's own frame.
func _radials(axis: Vector3) -> Array:
	var basis: Basis = _Shapes.basis_for_axis(axis)
	var out: Array = []
	for i in range(GAUGE_AZIMUTHS):
		var angle := TAU * float(i) / float(GAUGE_AZIMUTHS)
		out.append((basis.x * cos(angle) + basis.y * sin(angle)).normalized())
	return out



## Where the cap rays start: on the axis and on two rings inside the gauge
## radius, so a floor that only covers part of the pin is still found.
func _cap_origins(centre: Vector3, axis: Vector3, radius: float) -> Array:
	var out: Array = [centre]
	var radials := _radials(axis)
	for fraction in CAP_RING_FRACTIONS:
		if float(fraction) <= 0.0:
			continue
		var index := 0
		while index < radials.size():
			out.append(centre + (radials[index] as Vector3) * radius * float(fraction))
			# Every third azimuth: a ring is about catching a partial floor,
			# not about measuring it.
			index += 3
	return out


## A fixed 26-direction star: the six axes, the twelve edges and the eight
## corners of a cube. Enough to find any wall a compact gauge touches.
func _sphere_directions() -> Array:
	var out: Array = []
	for x in [-1.0, 0.0, 1.0]:
		for y in [-1.0, 0.0, 1.0]:
			for z in [-1.0, 0.0, 1.0]:
				var direction := Vector3(x, y, z)
				if direction.length_squared() > 0.0:
					out.append(direction.normalized())
	return out


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
	return state.intersect_ray(params)


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
