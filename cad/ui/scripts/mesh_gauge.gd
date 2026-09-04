## mesh_gauge.gd — the VERIFY half of measuring a foreign mesh.
##
## A fit is a hypothesis about geometry; this module is the physical test of
## it. Every triangle of every mounted reference becomes a collider, and the
## questions are asked the way a machinist asks them: does a pin of this size
## go in, does it go all the way through, and if it does not, where does it
## touch. The answers come from the physics server, so they are answers about
## the geometry that is actually there — not about the numbers a fit produced.
##
## FOUR CONSTRAINTS ARE STRUCTURAL HERE, EACH ONE MEASURED BY ITS FAILURE:
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
## The module is a Node so that it can own a physics step, and it holds its
## colliders in a SubViewport with its own World3D — the panel's four panes
## share Minerva's main world, and measurement colliders have no business in
## it. All coordinates in and out are WORLD millimetres (the posed CAD frame);
## posing and un-posing is the caller's job.
extends Node

## Sides of the gauge prism. Higher is a better circle and a slower query; at
## 48 the prism is within 0.2% of the cylinder it stands for.
const PRISM_SIDES: int = 48
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

## Ray-grid fallback, used only when the fitter proposed nothing at all.
const SEED_PITCH_MM: float = 1.0
## A missing ray whose neighbours this far away all hit is inside an enclosed
## opening rather than off the edge of the part.
const SEED_NEIGHBOUR_CELLS: int = 4

signal job_finished


var _viewport: SubViewport = null
var _body: StaticBody3D = null
## Shape owner id -> the mesh node the shape came from, for attributing contacts.
var _owner_names: Dictionary = {}
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

	_body = StaticBody3D.new()
	_body.name = "ReferenceColliders"
	_viewport.add_child(_body)
	set_physics_process(true)
	# A measurement is a question the host asked, not part of the simulation:
	# it must still be answered while the tree is paused, or a paused host
	# leaves an MCP call waiting for a physics step that never runs.
	process_mode = Node.PROCESS_MODE_ALWAYS


# ---------------------------------------------------------------------------
# Colliders
# ---------------------------------------------------------------------------

## Rebuild the collider set from `bodies`, a list of
## {mesh: Mesh, transform: Transform3D, node: String} in WORLD millimetres.
## `digest` identifies the set: an identical digest is a no-op, which is what
## keeps a keystroke that only moves a pose from rebuilding 45 trimeshes.
func build(bodies: Array, digest: String) -> int:
	if digest == _digest and _shape_count > 0:
		return _shape_count
	clear()
	_generation += 1
	if _body == null:
		return 0
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
		var owner_id := _body.create_shape_owner(_body)
		_body.shape_owner_add_shape(owner_id, shape)
		_body.shape_owner_set_transform(
			owner_id, body.get("transform", Transform3D.IDENTITY))
		_owner_names[owner_id] = str(body.get("node", ""))
		_shape_count += 1
	_digest = digest
	return _shape_count


func clear() -> void:
	if _body != null:
		for owner_id in _body.get_shape_owners():
			_body.shape_owner_clear_shapes(int(owner_id))
			_body.remove_shape_owner(int(owner_id))
	_owner_names.clear()
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
		"distance": (hit["position"] as Vector3).distance_to(from),
	}


## The gauge verb: place a shape and report whether it fits, what it touched,
## and — when it fits — how much larger it could be before it stopped.
func _job_gauge(state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	var at: Vector3 = args.get("at", Vector3.ZERO)
	var axis: Vector3 = _unit(args.get("axis", Vector3.UP))
	var kind := str(args.get("shape", "cylinder"))
	var size: Vector3 = args.get("size", Vector3.ONE)
	var shape := _shape_for(kind, size)
	if shape == null:
		return {"error": "unsupported gauge shape '%s'" % kind}
	var xform := Transform3D(_basis_for_axis(axis), at)

	var hits := _overlaps(state, shape, xform)
	if hits.is_empty():
		var clearance := 0.0
		if kind == "cylinder":
			# How much fatter a pin could be here, bounded so a gauge in open
			# air does not report the size of the room.
			var grown := _largest_radius(
				state, at, axis, size.y, size.x * 0.5, size.x * 2.0)
			clearance = maxf(0.0, grown - size.x * 0.5)
		return {"fits": true, "contacts": [], "clearance_mm": clearance}

	# Each contact is attributed by its own point query. collide_shape's pairs
	# and intersect_shape's bodies are different lists in unrelated orders, so
	# zipping them by index would name the wrong node; a contact whose point
	# query finds nothing is reported with an empty node rather than a guess.
	var contacts: Array = []
	for point in _contact_points(state, shape, xform):
		contacts.append({"point_mm": point, "node": _node_at(state, point)})
	if contacts.is_empty():
		# No contact geometry came back, only the bodies. Then the only honest
		# position is the query's own, and it is the gauge's, not a touch point.
		for hit in hits:
			contacts.append({"point_mm": at, "node": _node_for(hit), "at_gauge_centre": true})
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


## The fallback when the fitter proposed nothing: a Monte-Carlo shape-diameter
## seed. Rays on a grid down the given axis; a miss whose neighbours all hit is
## inside an opening rather than off the edge of the part. Clusters of such
## cells become seeds a normal gauge search can refine.
func _job_seed_grid(state: PhysicsDirectSpaceState3D, args: Dictionary) -> Dictionary:
	var bounds: AABB = args.get("bounds", AABB())
	var axis := _unit(args.get("axis", Vector3.UP))
	var pitch := float(args.get("pitch_mm", SEED_PITCH_MM))
	if bounds.size.length() <= 0.0 or pitch <= 0.0:
		return {"seeds": []}

	var basis := _basis_for_axis(axis)
	var u := basis.x
	var v := basis.y
	var centre := bounds.get_center()
	var reach := bounds.size.length()
	var half := reach * 0.5 + THROUGH_PAD_MM

	var extent_u := _extent_along(bounds, u) * 0.5 + pitch
	var extent_v := _extent_along(bounds, v) * 0.5 + pitch
	var cols := int(ceil(extent_u * 2.0 / pitch)) + 1
	var rows := int(ceil(extent_v * 2.0 / pitch)) + 1
	if cols * rows > 250000:
		return {"seeds": [], "error": "seed grid too large; raise pitch_mm"}

	var hit_grid := {}
	for c in range(cols):
		for r in range(rows):
			var p := centre \
				+ u * (-extent_u + float(c) * pitch) \
				+ v * (-extent_v + float(r) * pitch)
			var from := p + axis * half
			var to := p - axis * half
			hit_grid[Vector2i(c, r)] = not _ray(state, from, to).is_empty()

	var enclosed := {}
	for key in hit_grid.keys():
		var cell: Vector2i = key
		if bool(hit_grid[cell]):
			continue
		if _neighbours_hit(hit_grid, cell):
			enclosed[cell] = true

	var seeds: Array = []
	while not enclosed.is_empty():
		var start: Vector2i = enclosed.keys()[0]
		var cluster: Array = []
		var frontier: Array = [start]
		enclosed.erase(start)
		while not frontier.is_empty():
			var cell: Vector2i = frontier.pop_back()
			cluster.append(cell)
			for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var next: Vector2i = cell + step
				if enclosed.has(next):
					enclosed.erase(next)
					frontier.append(next)
		var sum := Vector2.ZERO
		for cell in cluster:
			sum += Vector2(float((cell as Vector2i).x), float((cell as Vector2i).y))
		var mean := sum / float(cluster.size())
		var seed_point := centre \
			+ u * (-extent_u + mean.x * pitch) \
			+ v * (-extent_v + mean.y * pitch)
		seeds.append({
			"center": seed_point,
			"axis": axis,
			"radius_hint_mm": sqrt(float(cluster.size())) * pitch * 0.5,
			"cells": cluster.size(),
		})
	return {"seeds": seeds}


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

## Refine a hole candidate's centre, measure the largest pin that fits, and ask
## whether the hole goes through. Everything is bounded to the candidate's own
## radius (constraint 3); a hole 3 mm from the outline stays put instead of
## sliding off the edge of the part.
func _verify_hole(state: PhysicsDirectSpaceState3D, candidate: Dictionary) -> Dictionary:
	var axis := _unit(candidate.get("axis", Vector3.UP))
	var centre: Vector3 = candidate.get("center", Vector3.ZERO)
	var radius := float(candidate.get("radius_mm", 0.0))
	if radius <= 0.0:
		return _unverified(candidate, "candidate has no radius")
	var half_extent := float(candidate.get("half_extent_mm", radius))
	var bound := radius * SEARCH_BOUND_FACTOR
	var probe := maxf(0.02, radius * 0.25)
	var length := maxf(0.2, half_extent * 2.0 * GAUGE_LENGTH_FRACTION)

	var basis := _basis_for_axis(axis)
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
	var axis := _unit(candidate.get("axis", Vector3.UP))
	var centre: Vector3 = candidate.get("center", Vector3.ZERO)
	var radius := float(candidate.get("radius_mm", 0.0))
	var out := candidate.duplicate(true)
	if radius <= 0.0:
		out["verified"] = false
		out["reason"] = "candidate has no radius"
		return out

	var basis := _basis_for_axis(axis)
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
		var radial := (basis.x * cos(angle) + basis.y * sin(angle)).normalized()
		var on_wall := centre + radial * radius
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
	var shape := _prism(probe_radius, length)
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
	if not _fits(state, _prism(lower, length), centre, axis):
		return 0.0
	var lo := lower
	var hi := upper
	for _i in range(BISECTION_STEPS):
		var mid := (lo + hi) * 0.5
		if _fits(state, _prism(mid, length), centre, axis):
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

## The gauge prism for a pin of `radius`. The polygon's INRADIUS is the gauge
## radius, so the prism contains the cylinder it stands for and a prism that
## fits proves the pin fits — the error is one-sided and under 0.2% at 48
## sides. A prism built the other way round would over-report every hole.
func _prism(radius: float, length: float) -> ConvexPolygonShape3D:
	var circumradius := radius / cos(PI / float(PRISM_SIDES))
	var points := PackedVector3Array()
	var half := length * 0.5
	for i in range(PRISM_SIDES):
		var angle := TAU * float(i) / float(PRISM_SIDES)
		var x := cos(angle) * circumradius
		var y := sin(angle) * circumradius
		points.append(Vector3(x, y, -half))
		points.append(Vector3(x, y, half))
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	return shape


func _shape_for(kind: String, size: Vector3) -> Shape3D:
	match kind:
		"cylinder":
			# size.x is the diameter, size.y the length.
			return _prism(maxf(0.001, size.x * 0.5), maxf(0.001, size.y))
		"box":
			var box := BoxShape3D.new()
			box.size = size
			return box
		"sphere":
			var sphere := SphereShape3D.new()
			sphere.radius = maxf(0.001, size.x * 0.5)
			return sphere
	return null


## Basis whose Z is `axis`: the frame every gauge shape is built in.
func _basis_for_axis(axis: Vector3) -> Basis:
	var z := _unit(axis)
	var reference := Vector3.UP if absf(z.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var x := reference.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


func _fits(
	state: PhysicsDirectSpaceState3D,
	shape: Shape3D,
	centre: Vector3,
	axis: Vector3
) -> bool:
	return _overlaps(state, shape, Transform3D(_basis_for_axis(axis), centre)).is_empty()


func _overlaps(state: PhysicsDirectSpaceState3D, shape: Shape3D, xform: Transform3D) -> Array:
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = xform
	params.margin = 0.0
	params.collide_with_bodies = true
	params.collide_with_areas = false
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
	params.hit_from_inside = true
	params.hit_back_faces = true
	return state.intersect_ray(params)


## The node whose surface a single point lies on, found by a small sphere query
## at that point. Empty when nothing is within CONTACT_ATTRIBUTION_MM, which is
## a truthful "unattributed" and not a wrong name.
func _node_at(state: PhysicsDirectSpaceState3D, point: Vector3) -> String:
	var probe := SphereShape3D.new()
	probe.radius = CONTACT_ATTRIBUTION_MM
	var near := _overlaps(state, probe, Transform3D(Basis.IDENTITY, point))
	if near.is_empty():
		return ""
	return _node_for(near[0])


func _node_for(hit: Dictionary) -> String:
	if _body == null or not hit.has("shape"):
		return ""
	var owner_id := _body.shape_find_owner(int(hit["shape"]))
	return str(_owner_names.get(owner_id, ""))


func _neighbours_hit(grid: Dictionary, cell: Vector2i) -> bool:
	for step in [
		Vector2i(SEED_NEIGHBOUR_CELLS, 0),
		Vector2i(-SEED_NEIGHBOUR_CELLS, 0),
		Vector2i(0, SEED_NEIGHBOUR_CELLS),
		Vector2i(0, -SEED_NEIGHBOUR_CELLS),
	]:
		var neighbour: Vector2i = cell + step
		if not grid.has(neighbour) or not bool(grid[neighbour]):
			return false
	return true


static func _extent_along(bounds: AABB, direction: Vector3) -> float:
	return absf(bounds.size.x * direction.x) \
		+ absf(bounds.size.y * direction.y) \
		+ absf(bounds.size.z * direction.z)


static func _unit(value: Variant) -> Vector3:
	var v: Vector3 = value if value is Vector3 else Vector3.UP
	return v.normalized() if v.length_squared() > 0.0 else Vector3.UP
