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
## 2. backface_collision IS ON for every trimesh. With it off, Jolt lets a
##    gauge grow straight through the wall of the hole it is sitting in and
##    reports an unbounded radius. Minerva runs Godot Physics today, where the
##    default happens to be harmless — the flag is set so that a switch to Jolt
##    cannot silently corrupt measurement.
##
## 3. EVERY SEARCH IS BOUNDED. Free space outside the part reads exactly like
##    free space inside a hole. An unbounded centring search on a hole near the
##    outline slides the gauge out through the edge of the board and reports a
##    centre in mid-air with an unbounded radius. Every search here is confined
##    to a multiple of the candidate's own radius.
##
## 4. THE GAUGE IS A CONVEX PRISM, NOT A CYLINDER. Under Godot Physics a
##    CylinderShape3D sitting in solid material can report no overlap at all;
##    it only behaves where the wall's own vertices fall inside it, i.e. inside
##    a hole. A prism is 10-15x the cost and always right. The prism is built
##    around the gauge circle (its inradius is the gauge radius), so the prism
##    contains the pin it stands for: a prism that fits proves the pin fits.
##
## 5. A COLLIDER IS A SURFACE, NOT A VOLUME. A gauge wholly inside solid
##    material crosses no triangle, so intersect_shape reports nothing and the
##    answer is indistinguishable from open air. Inside and outside are told
##    apart by the parity of the surfaces a ray from the point crosses, and
##    only then may an empty overlap be read as a fit.
##
## 6. ONE BODY PER REFERENCE, ON ITS OWN COLLISION LAYER. Physics sees every
##    body in the space, so a measurement asked about one part would otherwise
##    be shrunk by a second part that happens to pass through the hole. The
##    layer is the only place that scope can be enforced.
##
## The shapes a gauge is made of live in gauge_shapes.gd and the ray-grid
## fallback's arithmetic in gauge_seed.gd; what is left here is the queries.
##
## The module is a Node so that it can own a physics step, and it holds its
## colliders in a SubViewport with its own World3D — the panel's four panes
## share Minerva's main world, and measurement colliders have no business in
## it. All coordinates in and out are WORLD millimetres (the posed CAD frame);
## posing and un-posing is the caller's job.
extends Node

const _Shapes: Script = preload("gauge_shapes.gd")
const _Seed: Script = preload("gauge_seed.gd")

## Most overlaps reported for one query. Contacts are for telling the caller
## where it fouled, not for a complete census.
const MAX_HITS: int = 8
## Centring and radius searches use this many bisection steps. 14 steps take
## any bounded interval to under a ten-thousandth of it.
const BISECTION_STEPS: int = 14
## Samples marched outward before a centring bisection starts. Bisection alone
## assumes free space is contiguous, and it is not: past the outline of the
## part the gauge is free again, so a probe that fits at the far end of the
## bound may have crossed a wall to get there. Marching first bounds the
## bisection by the FIRST blocked sample instead of trusting the far end.
const CONTINUITY_SAMPLES: int = 8
## Radius of the point query used to name the body a contact point lies on.
## Large enough to catch the surface the contact was generated from, small
## enough that it cannot reach a different body.
const CONTACT_ATTRIBUTION_MM: float = 0.05
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
## The straddle spans r·(1−f)..r·(1+f). A faceted wall sits at r·cos(π/n)..r, so
## the wall is inside the straddle only for n ≥ 10 facets at f = 0.05; coarser
## bosses may verify or not depending on where the four samples land.
const WALL_PROBE_FRACTION: float = 0.05

## Ray-grid fallback pitch, used only when the fitter proposed nothing at all.
const SEED_PITCH_MM: float = 1.0

## Every collision layer at once: the mask a query uses when the caller named
## no reference and every mounted body is fair game.
const ALL_LAYERS: int = 0xFFFFFFFF
## Physics gives 32 layers. A document with more references than that shares
## the last bit between the overflow, which loses the isolation for those
## references but never mis-measures a reference that has a bit of its own.
const MAX_REFERENCE_LAYERS: int = 32
## How far a crossing ray is nudged past the face it just hit before the next
## cast. It is deliberately SMALLER than COINCIDENT_EPSILON_MM: two plates
## stacked face to face put two triangles at the same point and both are real
## crossings, so the nudge must not step over the second one.
const CROSSING_ADVANCE_MM: float = 0.0002
## Two hits this close together are at the same point. Within one such band a
## crossing is counted once per distinct triangle (body plus shape index), so
## coincident faces count twice and a face found again by the short nudge
## counts once.
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
## Reference name -> the StaticBody3D holding that reference's colliders. One
## body per reference, because a collision LAYER is a property of a body: it is
## what lets a measurement scoped to one reference ignore a second part that
## happens to pass through the hole being measured.
var _bodies: Dictionary = {}
## Reference name -> the single layer bit its body sits on.
var _layers: Dictionary = {}
## Body instance id -> {shape owner id: node path}, for attributing contacts.
## The path is the BARE node path — the same string find_holes reports in
## `nodes`, the selection verbs report as `node` and a node= filter matches.
## Which reference it belongs to is a separate field, kept per body below.
var _owner_names: Dictionary = {}
## Body instance id -> the reference name that body holds.
var _body_references: Dictionary = {}
## Bounds of every collider, in world millimetres. This is the reach an
## unbounded search is allowed and the length of an inside/outside ray.
var _bounds: AABB = AABB()
## The layer mask the job currently running may see. Jobs run one at a time
## inside one physics step, so a field is enough and every query reads it
## instead of carrying a mask through eight levels of bisection.
var _query_mask: int = ALL_LAYERS
## Identity of the reference set the current colliders were built from.
var _digest: String = ""
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
## Each reference gets its own StaticBody3D on its own collision layer. A
## measurement asked about one reference then queries with that reference's
## mask, and a second part crossing the hole cannot shrink the answer.
func build(bodies: Array, digest: String) -> int:
	if digest == _digest and _shape_count > 0:
		return _shape_count
	clear()
	_generation += 1
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
		var collider := _body_for(reference)
		var xform: Transform3D = body.get("transform", Transform3D.IDENTITY)
		var owner_id := collider.create_shape_owner(collider)
		collider.shape_owner_add_shape(owner_id, shape)
		collider.shape_owner_set_transform(owner_id, xform)
		var names: Dictionary = _owner_names[collider.get_instance_id()]
		names[owner_id] = node_name
		var box := xform * mesh.get_aabb()
		_bounds = box if not have_bounds else _bounds.merge(box)
		have_bounds = true
		_shape_count += 1
	_digest = digest
	return _shape_count


## The body holding one reference's colliders, created on its own layer the
## first time that reference is seen.
func _body_for(reference: String) -> StaticBody3D:
	if _bodies.has(reference):
		return _bodies[reference]
	var collider := StaticBody3D.new()
	collider.name = "Colliders_%d" % _bodies.size()
	# Bit per reference, saturating on the last one; the body collides with
	# nothing itself — it is only ever the target of a query.
	var index: int = mini(_bodies.size(), MAX_REFERENCE_LAYERS - 1)
	collider.collision_layer = 1 << index
	collider.collision_mask = 0
	_viewport.add_child(collider)
	_bodies[reference] = collider
	_layers[reference] = collider.collision_layer
	_owner_names[collider.get_instance_id()] = {}
	_body_references[collider.get_instance_id()] = reference
	return collider


## The query mask that isolates one reference's colliders. A name that is empty
## or not mounted gets every layer: the caller that cares whether the name is
## real refuses it before it asks a question, and a mask that matched nothing
## would answer "it fits" about an empty space.
func mask_for(reference: String) -> int:
	if reference.is_empty() or not _layers.has(reference):
		return ALL_LAYERS
	return int(_layers[reference])


func clear() -> void:
	for key in _bodies.keys():
		var collider: StaticBody3D = _bodies[key]
		if is_instance_valid(collider):
			collider.get_parent().remove_child(collider)
			collider.queue_free()
	_bodies.clear()
	_layers.clear()
	_owner_names.clear()
	_body_references.clear()
	_bounds = AABB()
	_shape_count = 0
	_digest = ""


func is_built() -> bool:
	return _shape_count > 0


func get_digest() -> String:
	return _digest


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
func space_state() -> PhysicsDirectSpaceState3D:
	if _viewport == null:
		return null
	var world := _viewport.world_3d
	return world.direct_space_state if world != null else null


## Run one job with a space state already in hand. Every measurement lives
## here, so a headless caller with its own physics frame can use the whole
## surface without the queue.
func run_now(state: PhysicsDirectSpaceState3D, kind: String, args: Dictionary) -> Dictionary:
	# `mask` scopes the whole job to one reference's colliders. It is a field
	# rather than an argument because every query below it — eight levels of
	# bisection deep — would otherwise have to carry it.
	_query_mask = int(args.get("mask", ALL_LAYERS))
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
	return {"error": "unknown gauge job '%s'" % kind}


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
	var shape: Shape3D = _Shapes.shape_for(kind, size)
	if shape == null:
		return {"error": "unsupported gauge shape '%s'" % kind}
	var xform := Transform3D(_Shapes.basis_for_axis(axis) as Basis, at)

	var hits := _overlaps(state, shape, xform)
	if hits.is_empty():
		# A trimesh collider is a SURFACE, not a volume: a gauge buried in solid
		# material crosses no triangle and overlaps nothing, which is exactly
		# what open air looks like. Parity along a ray separates the two.
		if _inside_solid(state, at):
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
		if kind == "cylinder":
			var grown := _largest_radius(
				state, at, axis, size.y, size.x * 0.5, bound)
			clearance = maxf(0.0, grown - size.x * 0.5)
		return {
			"fits": true,
			"contacts": [],
			"clearance_mm": clearance,
			"clearance_bound_mm": bound,
		}

	# Each contact is attributed by its own point query. collide_shape's pairs
	# and intersect_shape's bodies are different lists in unrelated orders, so
	# zipping them by index would name the wrong node; a contact whose point
	# query finds nothing is reported with an empty node rather than a guess.
	var contacts: Array = []
	for point in _contact_points(state, shape, xform):
		var named := _names_at(state, point)
		contacts.append({
			"point_mm": point,
			"node": str(named.get("node", "")),
			"reference": str(named.get("reference", "")),
		})
	if contacts.is_empty():
		# No contact geometry came back, only the bodies. Then the only honest
		# position is the query's own, and it is the gauge's, not a touch point.
		for hit in hits:
			contacts.append({
				"point_mm": at,
				"node": _node_for(hit),
				"reference": _reference_for(hit),
				"at_gauge_centre": true,
			})
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
		centre = _recentre(state, centre, basis.x, axis, probe, length, bound)
		centre = _recentre(state, centre, basis.y, axis, probe, length, bound)

	var fitted := _largest_radius(state, centre, axis, length, probe, radius * 1.5)
	var through_report := _through(state, centre, axis, half_extent)

	var predicted := float(candidate.get("inscribed_dia_mm", radius * 2.0))
	var gauge_dia := fitted * 2.0
	var verified: bool = fitted > 0.0 and absf(gauge_dia - predicted) \
		<= maxf(0.02, predicted * VERIFY_TOLERANCE_FRACTION)

	var out := candidate.duplicate(true)
	out["center"] = centre
	out["axis"] = axis
	out["gauge_dia_mm"] = gauge_dia
	out["through"] = bool(through_report["through"])
	out["depth_mm"] = float(through_report["depth_mm"])
	out["verified"] = verified
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
	# Straddling probe: centred ON the fitted radius, so it reaches from
	# radius-epsilon to radius+epsilon and cannot miss a wall that is there.
	var straddle := SphereShape3D.new()
	straddle.radius = epsilon
	# Standoff probe: the same size, moved out by two epsilon, so its nearest
	# point is a clear epsilon outside the fitted radius.
	var standoff := SphereShape3D.new()
	standoff.radius = epsilon
	var wall_contacts := 0
	var free_outside := 0
	for i in range(4):
		var angle := float(i) * PI * 0.5
		var radial: Vector3 = (basis.x * cos(angle) + basis.y * sin(angle)).normalized()
		var on_wall: Vector3 = centre + radial * radius
		var outside: Vector3 = centre + radial * (radius + epsilon * 3.0)
		if not _overlaps(state, straddle, Transform3D(Basis.IDENTITY, on_wall)).is_empty():
			wall_contacts += 1
		if _overlaps(state, standoff, Transform3D(Basis.IDENTITY, outside)).is_empty():
			free_outside += 1
	out["wall_contacts"] = wall_contacts
	out["free_outside"] = free_outside
	out["verified"] = wall_contacts >= 3 and free_outside >= 3
	if not bool(out["verified"]):
		out["reason"] = "wall contact at %d of 4 angles, clear outside at %d of 4" \
			% [wall_contacts, free_outside]
	out["source"] = str(candidate.get("source", "fit"))
	return out


## Is this point inside the material rather than in air? A closed surface is
## crossed an odd number of times by any ray from an interior point and an even
## number from an exterior one, and backface_collision means both faces of a
## wall are hit, so the parity holds in both directions.
##
## Two axes are cast because one ray can graze an edge and count a crossing
## twice or not at all; a third breaks the tie when they disagree. A part with
## no colliders, or an unbounded one, is never called inside.
func _inside_solid(state: PhysicsDirectSpaceState3D, point: Vector3) -> bool:
	if _bounds.size.length_squared() <= 0.0:
		return false
	var reach := _bounds.size.length() + THROUGH_PAD_MM
	var first := _crossings(state, point, Vector3.RIGHT, reach) % 2 == 1
	var second := _crossings(state, point, Vector3.BACK, reach) % 2 == 1
	if first == second:
		return first
	return _crossings(state, point, Vector3.UP, reach) % 2 == 1


## Surfaces crossed by a ray leaving `from` along `direction` for `reach`
## millimetres.
##
## COINCIDENT FACES ARE TWO CROSSINGS. Two plates resting on each other put
## their shared face at one point, and material continues through it: skipping
## past both with one nudge counts one crossing and flips the parity of
## everything beyond. So the ray advances by less than the coincidence
## epsilon and the hits inside one such band are deduplicated by triangle —
## body instance plus shape index — which counts two stacked plates twice and
## the same triangle, re-found by the short nudge, once.
func _crossings(
	state: PhysicsDirectSpaceState3D,
	from: Vector3,
	direction: Vector3,
	reach: float
) -> int:
	var count := 0
	var casts := 0
	var origin := from
	var remaining := reach
	# The triangles already counted at `band_point`, cleared as soon as a hit
	# lands outside that point's epsilon band.
	var band_point := from
	var counted: Array = []
	while remaining > 0.0 and count < MAX_CROSSINGS and casts < MAX_CROSSING_CASTS:
		casts += 1
		var hit := _ray(state, origin, origin + direction * remaining)
		if hit.is_empty():
			break
		var point: Vector3 = hit["position"]
		if point.distance_to(band_point) > COINCIDENT_EPSILON_MM:
			counted.clear()
			band_point = point
		# face_index is the triangle within a concave shape; it is absent for
		# shapes that have no faces, and then body-plus-shape is the identity.
		var identity := "%d:%d:%d" % [
			int(hit.get("collider_id", 0)),
			int(hit.get("shape", -1)),
			int(hit.get("face_index", -1)),
		]
		if not (identity in counted):
			counted.append(identity)
			count += 1
		var step := point.distance_to(origin) + CROSSING_ADVANCE_MM
		origin += direction * step
		remaining -= step
	return count


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
	axis: Vector3,
	probe_radius: float,
	length: float,
	bound: float
) -> Vector3:
	var forward := _free_run(state, centre, direction, axis, probe_radius, length, bound)
	var backward := _free_run(state, centre, -direction, axis, probe_radius, length, bound)
	return centre + direction * ((forward - backward) * 0.5)


## Largest distance the probe can be pushed along `direction` and still fit,
## searched by bisection inside [0, bound].
func _free_run(
	state: PhysicsDirectSpaceState3D,
	centre: Vector3,
	direction: Vector3,
	axis: Vector3,
	probe_radius: float,
	length: float,
	bound: float
) -> float:
	var shape: ConvexPolygonShape3D = _Shapes.prism(probe_radius, length)
	if not _fits(state, shape, centre, axis):
		return 0.0
	# March outward first (constraint 3 again, in its subtler form): the far
	# end of the bound can be free because it is OUTSIDE the part, and a plain
	# bisection would then report the whole bound as free space. The run
	# returned here is continuous with the starting point down to the marching
	# pitch, and the bisection only refines the wall between two samples.
	var lo := 0.0
	var hi := -1.0
	var step := bound / float(CONTINUITY_SAMPLES)
	for i in range(1, CONTINUITY_SAMPLES + 1):
		var sample := step * float(i)
		if _fits(state, shape, centre + direction * sample, axis):
			lo = sample
		else:
			hi = sample
			break
	if hi < 0.0:
		return bound
	for _i in range(BISECTION_STEPS):
		var mid := (lo + hi) * 0.5
		if _fits(state, shape, centre + direction * mid, axis):
			lo = mid
		else:
			hi = mid
	return lo


## Largest gauge radius that still fits at `centre`, by bisection. Monotonic:
## a bigger pin never fits where a smaller one did not.
func _largest_radius(
	state: PhysicsDirectSpaceState3D,
	centre: Vector3,
	axis: Vector3,
	length: float,
	lower: float,
	upper: float
) -> float:
	if not _fits(state, _Shapes.prism(lower, length) as Shape3D, centre, axis):
		return 0.0
	var lo := lower
	var hi := upper
	for _i in range(BISECTION_STEPS):
		var mid := (lo + hi) * 0.5
		if _fits(state, _Shapes.prism(mid, length) as Shape3D, centre, axis):
			lo = mid
		else:
			hi = mid
	return lo


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

func _fits(
	state: PhysicsDirectSpaceState3D,
	shape: Shape3D,
	centre: Vector3,
	axis: Vector3
) -> bool:
	return _overlaps(
		state, shape, Transform3D(_Shapes.basis_for_axis(axis) as Basis, centre)).is_empty()


func _overlaps(state: PhysicsDirectSpaceState3D, shape: Shape3D, xform: Transform3D) -> Array:
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = xform
	params.margin = 0.0
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.collision_mask = _query_mask
	return state.intersect_shape(params, MAX_HITS)


func _contact_points(
	state: PhysicsDirectSpaceState3D,
	shape: Shape3D,
	xform: Transform3D
) -> PackedVector3Array:
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = xform
	params.margin = 0.0
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.collision_mask = _query_mask
	var raw := state.collide_shape(params, MAX_HITS)
	# collide_shape reports pairs: the point on the query shape, then the point
	# on the collider. The second of each pair is the one on the geometry.
	var points := PackedVector3Array()
	var index := 1
	while index < raw.size():
		points.append(raw[index])
		index += 2
	return points


func _ray(state: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.collision_mask = _query_mask
	params.hit_from_inside = true
	params.hit_back_faces = true
	return state.intersect_ray(params)


## The node and reference whose surface a single point lies on, found by a small
## sphere query at that point. Both are empty when nothing is within
## CONTACT_ATTRIBUTION_MM, which is a truthful "unattributed" and not a wrong
## name.
func _names_at(state: PhysicsDirectSpaceState3D, point: Vector3) -> Dictionary:
	var probe := SphereShape3D.new()
	probe.radius = CONTACT_ATTRIBUTION_MM
	var near := _overlaps(state, probe, Transform3D(Basis.IDENTITY, point))
	if near.is_empty():
		return {"node": "", "reference": ""}
	return {"node": _node_for(near[0]), "reference": _reference_for(near[0])}


## The node a query hit came from. The hit names both the body and the shape
## index within it, and the owner map is kept per body, so the same shape index
## on two references cannot be confused.
func _node_for(hit: Dictionary) -> String:
	if not hit.has("shape") or not hit.has("collider"):
		return ""
	var collider: Variant = hit["collider"]
	if not (collider is CollisionObject3D):
		return ""
	var names: Dictionary = _owner_names.get((collider as Object).get_instance_id(), {})
	var owner_id := (collider as CollisionObject3D).shape_find_owner(int(hit["shape"]))
	return str(names.get(owner_id, ""))


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
