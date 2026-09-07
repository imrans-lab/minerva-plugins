extends "interference_containment.gd"
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
## A DESIGNED CONTACT IS NOT INTERFERENCE, and telling them apart takes three
## rules rather than one. A shell resting on a board shares a plane, and a
## check that calls that an error is a check the reader learns to ignore. The
## per-crossing tests below clear a hit within a tenth of a micrometre of a
## surface it never straddled; contact_runs.gd clears an edge RUNNING ALONG a
## face it never left; and rim_contact.gd clears the one neither can see — the
## rim of the bore in the seating face, where a wall of one body meets a face
## of the other squarely and the two still share no material. The last is
## measured against expected_contacts.gd's CONTACT_TOLERANCE_MM rather than
## the touch epsilon, because the touch epsilon is finer than the single
## precision the hit positions themselves arrive in.
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
##    the only side that caches (mesh_gauge, on its digest). A NAMED PART is
##    the exception, and it is one because it has a stamp: the digest of the
##    source that evaluates to that binding, which is what the collider is
##    cached under so three legs over one part weld it once.
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
## trip and not a ray walk, and lives further down the chain this script
## extends: clearance_client.gd (the verb and its jobs) over
## clearance_report.gd (the report fold) over clearance_blobs.gd (the mesh
## store the worker is handed). One object carries both halves, so the panel,
## panel_tools and fastener_checks each hold a single geometry-checks instance
## as they always have. The frame helpers both halves read live in
## clearance_blobs.gd, at the bottom of it.
##
## WHAT THIS FILE HOLDS. The walk: the verb and what it refuses, and the two
## directions of edge casting — the solid's edges into the references, the
## edges of every reference triangle that reaches the solid into the solid's
## own collider — with the per-crossing tests that tell a penetration from a
## designed contact. What it walks with is in the scripts it extends:
## interference_containment.gd (the overlap no edge crossing can see, the
## parity probes these tests share, and the plumbing of the rim rule both legs
## ask) over interference_world.gd (the solid's own physics world, the collider
## rebuilt each evaluation, the rays into it, the reservation that keeps one
## check running at a time, and the markers).
## Turning the crossings into the reply — the pairs, the penetration depths,
## the declared-contact accounting and the status line — is
## interference_report.gd, under both, whose state the walk writes.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: ui/cad_panel_scene.gd (the instance every evaluation runs)
## and ui/panel_tools.gd (minerva_cad_check_interference and the
## clearance verb the same object carries).


## The rule that tells a designed contact from a penetration when an edge runs
## ALONG a face instead of through it.
const _ContactRuns: Script = preload("contact_runs.gd")


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


## Crossings counted along one edge. An edge threading more walls than this is
## pathological; the crossings found still count as interference, and only the
## penetration measurement is given up.
const MAX_CROSSINGS_PER_EDGE: int = 16


## Every collision layer at once — the unscoped mask, matching mesh_gauge.
const ALL_LAYERS: int = 0xFFFFFFFF


# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

## Run the whole check for `panel` and return the report:
##
##   {pass, count, pairs: [{reference, node, points_mm: [{world, local}],
##    point_count, penetration_mm?}], point_count, sampling, casts, checked,
##    painted, expected_contacts?, excluded_count?}
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
##
## `args` may also carry expected_contacts= — the contacts the design MEANS to
## have, per pair. A crossing one of them covers is measured exactly as any
## other and then held out of `count` while the overlap it reaches stays
## inside the depth that declaration allows; every declaration is listed in
## the reply with what was measured for it, and one whose overlap ran deeper
## is reported as interference anyway. See scripts/expected_contacts.gd.
func check(panel: Object, args: Dictionary = {}) -> Dictionary:
	# An agent's verb call says so and takes a place in the bounded wait line
	# while a check runs; the panel's own per-evaluation check says nothing
	# and queues in the evaluation slot instead.
	var reservation := await reserve(not bool(args.get("on_demand", false)))
	var ticket := int(reservation.get("ticket", 0))
	if ticket == 0:
		return refused(reservation)
	var queued_ms := int(reservation.get("waited_ms", 0))
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
	# How long this call stood in the wait line before it could measure. A
	# reply that took a while must say which half of it was waiting.
	if queued_ms > 0:
		report["queued_ms"] = queued_ms
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
	_keep_part_report(panel, args, report)
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


## Keep a PART's interference report where the clearance check can find it.
##
## The document's own report rides in the last eval result, which is what the
## unscoped clearance check joins against. A part has no such home: it is
## evaluated for the duration of one verb call and its report would be thrown
## away, so the clearance leg of the same call would fall back to the
## DOCUMENT's report — measured against the union of every binding, in which
## a node buried nowhere near this half still reads as buried. That join is
## wrong rather than merely unavailable, so the part's own report is stored
## under the digest of the source that produced it and the joiner asks for
## that digest.
##
## ONLY AN UNSCOPED, UNDECLARED REPORT IS KEPT. A joiner reads a pair the
## report does not name as "no crossing there", so a report narrowed by
## reference= or node= would excuse every node it never looked at — and so
## would one carrying expected_contacts, whose declared pairs leave `pairs`
## for the declarations table. The slot is keyed by source digest alone, so a
## later call with different declarations, or none, would be handed that
## report and read a contained pair as clear. Declarations are per call; the
## cache holds only what is true of the shape whatever was declared.
func _keep_part_report(panel: Object, args: Dictionary,
		report: Dictionary) -> void:
	if str(args.get("source", "")).strip_edges().is_empty():
		return
	if not str(args.get("reference", "")).is_empty() \
			or not str(args.get("node", "")).is_empty():
		return
	var declared: Variant = args.get("expected_contacts", [])
	if declared is Array and not (declared as Array).is_empty():
		return
	if not bool(report.get("checked", false)):
		return
	# _PartCache is declared by clearance_report.gd, further down the chain
	# this script extends, which is the other half of the same join.
	_PartCache.put_interference(panel, str(report.get("source_digest", "")),
		report)


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

	# A declaration nobody can read is refused rather than dropped: an author
	# who mistyped a reference believes that pair is excused.
	var declared: Dictionary = _Expected.parse(args)
	if not (declared["errors"] as Array).is_empty():
		return _nothing("expected_contacts: %s"
			% ", ".join(PackedStringArray(declared["errors"] as Array)))

	var document: Dictionary = {}
	if panel.has_method("get_document_state"):
		document = panel.get_document_state()
	# A part-scoped check brings its own tessellation; otherwise the shape the
	# document evaluates to.
	var scoped_mesh: Dictionary = args.get("mesh", {}) as Dictionary
	var scoped_source := str(args.get("source", ""))
	if (scoped_mesh.get("faces", []) as Array).is_empty():
		scoped_mesh = document.get("mesh", {}) as Dictionary
	var part_scoped := not scoped_source.strip_edges().is_empty()
	if not part_scoped:
		scoped_source = str(document.get("source", ""))
	# A named part has a stamp — the digest of the source that evaluates to
	# it — so its collider is welded once and swapped back in for the legs
	# that follow. The document's own render target has none and rebuilds.
	var triangles := build_solid(scoped_mesh, ticket,
		_source_digest(scoped_source) if part_scoped else "")
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
		"expected": declared["entries"],
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
		reply["source_digest"] = _source_digest(scoped_source)
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
	_coverage_limited = false
	_undecided = []
	_expected = args.get("expected", []) as Array
	_declared = {}
	_declared_matched = {}
	_contacts = {}
	_rim_tests = 0
	_rim_crossing = {}
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
	_edges_total = get_solid_edge_count()
	_edges_reaching = 0
	_edges_cast = 0
	# The budget is spent on RAYS, so the walk runs to the end of the solid
	# whatever its size and an edge that cannot reach a reference costs a box
	# test. An edge past the budget is still counted, so the report can say
	# exactly how many were left rather than "at least this many".
	for i in range(_edges_total):
		var a := _solid_edges[i * 2]
		var b := _solid_edges[i * 2 + 1]
		if cull and not AABB(a, Vector3.ZERO).expand(b).intersects(reach):
			continue
		_edges_reaching += 1
		if _edges_cast >= max_solid_edge_casts:
			continue
		_edges_cast += 1
		var crossings := _cross_into_references(gauge, state, solid_state, a, b,
			mask, reference_scope, node_scope)
		for crossing in crossings:
			_absorb(pairs, crossing as Dictionary, node_scope)
		# The depth this one edge reached inside each node it crossed. Runs are
		# measured per EDGE: two crossings on different edges bound nothing.
		_absorb_runs(pairs, crossings, node_scope, "solid_edge")
	if _edges_reaching > _edges_cast:
		_limit(("%d of the %d solid edges that reach a reference were "
			+ "not cast; the first %d spent the ray budget")
			% [_edges_reaching - _edges_cast, _edges_reaching, _edges_cast], true)

	# Direction 2: the edges of every reference triangle that could reach the
	# solid, against the solid's own collider.
	if solid_state != null:
		_reference_edges_into_solid(gauge, state, solid_state, pairs,
			reference_scope, node_scope)

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


## The parity probe the contact-run rule needs for one crossing, chosen by the
## same newline-joined key the ray is.
func _reference_inside_for(
	key: String,
	gauge: Object,
	state: PhysicsDirectSpaceState3D
) -> Callable:
	var parts := key.split("\n")
	var reference_name: String = parts[0] if parts.size() > 0 else ""
	var node_path: String = parts[1] if parts.size() > 1 else ""
	return _reference_inside.bind(gauge, state, reference_name, node_path)


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
		ray_for: Callable, inside_for: Callable) -> Array:
	if crossings.is_empty():
		return crossings
	var out: Array = []
	for kept in _ContactRuns.penetrating_indices(a, b, crossings,
			TOUCH_EPSILON_MM, ray_for, inside_for, PARITY_SPHERE_MM):
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
	solid_state: PhysicsDirectSpaceState3D,
	a: Vector3,
	b: Vector3,
	mask: int,
	reference_scope: String,
	node_scope: String
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
		var penetrating := travelled > TOUCH_EPSILON_MM \
			and (length - travelled) > TOUCH_EPSILON_MM \
			and _straddles(a, b, point, hit) \
			and _penetrates_reference(gauge, state, point, direction, mask,
				str(hit.get("reference", "")), str(hit.get("node", "")))
		# The rim of a bore in a landing face passes every test above: the
		# crossing is square, and the material a probe step behind it is real.
		# Only shared material tells it from an overlap.
		if penetrating and _rim_touching_reference(gauge, state, solid_state,
				point, hit, direction, node_scope):
			penetrating = false
		# Every hit is kept, the discarded ones marked: a hit this edge did
		# not pass through is still the place it met the surface, and the
		# contact-run rule measures its runs BETWEEN surfaces. Dropping it
		# here would leave the next crossing measuring out to the edge's own
		# end, through the air past the rim.
		out.append({
			"point": point,
			"key": str(hit.get("reference", "")) + "\n"
				+ str(hit.get("node", "")),
			"node": str(hit.get("node", "")),
			"reference": str(hit.get("reference", "")),
			"distance": travelled,
			"bound_only": not penetrating,
		})
		var next := point + direction * CROSSING_ADVANCE_MM
		if a.distance_to(next) >= length:
			break
		cursor = next
	return _drop_contact_runs(a, b, out,
		_reference_ray_for.bind(gauge, state),
		_reference_inside_for.bind(gauge, state))


# ---------------------------------------------------------------------------
# Direction 2 — the references' edges against the solid
# ---------------------------------------------------------------------------

## Cast the edges of every reference triangle that overlaps the solid's bounds
## into the solid's own collider. The culling is two-stage — the part's box,
## then each triangle's — because a board is a hundred thousand triangles and
## only a handful of them are ever near the shell.
func _reference_edges_into_solid(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
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
						_limit("only the first %d reference triangles were examined"
							% MAX_REFERENCE_TRIANGLES, true)
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
						for point in _cross_into_solid(gauge, state, solid_state,
								start, edge[1] as Vector3, reference_name,
								node_path, node_scope):
							crossings.append({
								"point": point,
								"node": node_path,
								"reference": reference_name,
								"distance": start.distance_to(point),
							})
						for crossing in crossings:
							_absorb(pairs, crossing as Dictionary, node_scope)
						_absorb_runs(pairs, crossings, node_scope,
							"reference_edge")


## Where the segment a→b crosses the solid's surface, in order.
func _cross_into_solid(
	gauge: Object,
	state: PhysicsDirectSpaceState3D,
	solid_state: PhysicsDirectSpaceState3D,
	a: Vector3,
	b: Vector3,
	reference_name: String,
	node_path: String,
	node_scope: String
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
		# As on the reference leg: the hits that fail these tests stay on as
		# run boundaries, because the rim of a flush fit is usually crossed
		# once as a penetration and once as a hit no test will vouch for.
		var penetrating := travelled > TOUCH_EPSILON_MM \
			and (length - travelled) > TOUCH_EPSILON_MM \
			and _straddles(a, b, point, hit) \
			and _penetrates_solid(solid_state, point, direction)
		# The same rim rule as the reference leg, roles swapped: here the
		# crossed surface is the solid's and the body resting on it is the
		# reference node whose triangle this edge came from.
		if penetrating and _rim_touching_solid(gauge, state, solid_state,
				point, hit, direction, reference_name, node_path, node_scope):
			penetrating = false
		candidates.append({
			"point": point,
			"key": "",
			"bound_only": not penetrating,
		})
		var next := point + direction * CROSSING_ADVANCE_MM
		if a.distance_to(next) >= length:
			break
		cursor = next
	# Only one body here, so every crossing carries the same key and the ray
	# and the parity probe are the same ones whichever crossing asks for them.
	for kept in _ContactRuns.penetrating_indices(a, b, candidates,
			TOUCH_EPSILON_MM,
			func(_key: String) -> Callable: return _solid_hit.bind(solid_state),
			func(_key: String) -> Callable: return _solid_inside.bind(solid_state),
			PARITY_SPHERE_MM):
		out.append((candidates[kept] as Dictionary).get("point", Vector3.ZERO))
	return out
