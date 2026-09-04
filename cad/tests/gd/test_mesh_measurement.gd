extends SceneTree
## Measuring a foreign mesh: propose by fitting, verify by gauging.
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## The fixture is a plate built here with runtime CSG and baked to a mesh — no
## mesh binary in the repository, and every expected number is one the test
## wrote rather than one recomputed with the code under test.
##
## The plate is deliberately NOT lying in the CAD floor plane: its normal is
## +Y, the axis Godot's CSG cylinders default to, while the CAD world is Z-up.
## A detector with any preferred axis fails the whole suite on the first hole,
## not just on the tilted one.
##
## It carries five holes and a boss, each of which breaks a different shortcut:
##
##   H1, H2   plain through holes, 64-gon walls. The circumscribed circle
##            through their vertices is 3.2 mm and the pin that actually goes
##            in is 3.2*cos(pi/64) = 3.1985. An implementation that reports one
##            number for "the diameter" is wrong about one of them.
##   H3       1.9 mm from the outline. An unbounded centring search slides the
##            gauge out through the edge of the plate — free space outside the
##            part reads exactly like free space inside a hole — and reports a
##            centre in mid-air.
##   H4       drilled 30 degrees off the plate normal. An axis-aligned detector
##            misses it; a detector that finds it but reports the plate normal
##            as its axis fails the gauge test on the fitted axis.
##   H5       a blind pocket, 2 mm deep in a 4 mm plate. Its wall is the same
##            cylinder as a through hole's: NOTHING in the fit distinguishes
##            them, and only the ray test does.
##   B1       a convex boss, so "find cylinders" cannot mean "find holes".
##
## The whole fixture is then posed by a non-identity transform before it is
## gauged, so every reported position has to survive the round trip from the
## reference's own frame to the posed world and back.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const MeshFeatures := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_features.gd")
const MeshGauge := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")

## Plate: 60 x 40 in X and Z, 4 thick in Y. Its faces are at y = -2 and y = +2.
const PLATE := Vector3(60.0, 4.0, 40.0)
const PLATE_NORMAL := Vector3.UP
const FACETS := 64

## Every hole: local centre (the midpoint of its wall), axis, the diameter of
## the circle its 64 vertices lie on and whether it goes through. These are the
## numbers the fixture was built from, written out rather than derived, so a
## wrong answer cannot agree with them by construction — and the cutter that
## makes each hole is placed FROM these numbers, so the fixture and the
## expectation cannot drift apart.
const HOLES := [
	{
		"name": "H1 through",
		"center": Vector3(-20.0, 0.0, -10.0),
		"axis": Vector3(0.0, 1.0, 0.0),
		"dia": 3.2,
		"through": true,
	},
	{
		"name": "H2 through",
		"center": Vector3(20.0, 0.0, 10.0),
		"axis": Vector3(0.0, 1.0, 0.0),
		"dia": 3.2,
		"through": true,
	},
	{
		"name": "H3 near the outline",
		"center": Vector3(26.5, 0.0, 0.0),
		"axis": Vector3(0.0, 1.0, 0.0),
		"dia": 3.2,
		"through": true,
	},
	{
		# A rotation of +30 degrees about Z takes the cutter's own +Y to
		# (-sin 30, cos 30, 0): the sign is part of the geometry, and the
		# fixture derives its rotation from THIS vector so the two agree by
		# construction. The centre is unchanged by the tilt because the cutter
		# turns about its own origin, which sits on the plate's mid-plane.
		"name": "H4 tilted 30 degrees",
		"center": Vector3(0.0, 0.0, 10.0),
		"axis": Vector3(-0.5, 0.8660254, 0.0),
		"dia": 4.0,
		"through": true,
	},
	{
		# 4 mm of cutter dropped onto the top face of a 4 mm plate: the floor
		# is left at y = 0, so the centre of the 2 mm wall is at y = +1.
		"name": "H5 blind pocket",
		"center": Vector3(-20.0, 1.0, 12.0),
		"axis": Vector3(0.0, 1.0, 0.0),
		"dia": 5.0,
		"through": false,
		"depth": 2.0,
	},
]

## The boss: a 6 mm cylinder standing 5 mm proud of the top face.
const BOSS_CENTER := Vector3(10.0, 4.5, -12.0)
const BOSS_DIA := 6.0

## Pose applied to the whole fixture before it is gauged: rotate 90 degrees
## about Z, then translate. Row-major, as the worker reports it.
const POSE_BASIS_ROWS := [
	[0.0, -1.0, 0.0],
	[1.0, 0.0, 0.0],
	[0.0, 0.0, 1.0],
]
const POSE_ORIGIN := Vector3(100.0, 200.0, 300.0)

const CENTRE_TOLERANCE_MM := 0.01
const GAUGE_TOLERANCE_MM := 0.03

var _pass: int = 0
var _fail: int = 0
var _pose: Transform3D = Transform3D.IDENTITY


func _init() -> void:
	print("=== CAD Mesh Measurement Test (propose -> verify) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_pose = Transform3D(
		Basis(
			Vector3(POSE_BASIS_ROWS[0][0], POSE_BASIS_ROWS[1][0], POSE_BASIS_ROWS[2][0]),
			Vector3(POSE_BASIS_ROWS[0][1], POSE_BASIS_ROWS[1][1], POSE_BASIS_ROWS[2][1]),
			Vector3(POSE_BASIS_ROWS[0][2], POSE_BASIS_ROWS[1][2], POSE_BASIS_ROWS[2][2])
		),
		POSE_ORIGIN
	)

	var baked: ArrayMesh = await _bake_fixture()
	check("fixture: the CSG plate baked to a mesh",
			baked != null and baked.get_surface_count() > 0,
			"bake_static_mesh returned nothing")
	if baked == null or baked.get_surface_count() == 0:
		return

	var local_parts: Array = [
		{"mesh": baked, "transform": Transform3D.IDENTITY, "node": "plate"},
	]
	var candidates := _check_proposal(local_parts)
	await _check_concurrent_segmentation(local_parts)
	await _check_gauge(baked, candidates)
	await _check_coincident_faces()


# ---------------------------------------------------------------------------
# PROPOSE — segmentation and fitting, no physics
# ---------------------------------------------------------------------------

## Returns the concave cylinder candidates, matched to the fixture's holes in
## the fixture's own order, so the gauge half can reuse the pairing.
func _check_proposal(local_parts: Array) -> Array:
	var features := MeshFeatures.new()
	var analysis: Dictionary = features.features_for("fixture|v1", local_parts)
	var all: Array = analysis.get("candidates", [])

	check("segmentation: the plate produced triangles",
			int(analysis.get("triangles", 0)) > 100,
			"triangles = %d" % int(analysis.get("triangles", 0)))

	# Asking twice must not segment twice: the cost is paid per file, not per
	# question, and the counter increments only where the work happens.
	features.features_for("fixture|v1", local_parts)
	check("segmentation: a second request is served from the cache",
			int(features.get_analysis_count()) == 1,
			"analysis count = %d" % int(features.get_analysis_count()))

	var concave: Array = MeshFeatures.concave_cylinders(all, 1.0, 7.0, 0.6)
	check("fit: exactly the five holes are proposed as concave cylinders",
			concave.size() == HOLES.size(),
			"proposed %d concave cylinders, expected %d" % [concave.size(), HOLES.size()])

	var convex: Array = []
	var planes := 0
	for entry in all:
		var candidate: Dictionary = entry
		if str(candidate.get("kind", "")) == "plane":
			planes += 1
		elif str(candidate.get("form", "")) == "convex":
			convex.append(candidate)
	check("fit: the plate's flat faces are proposed as planes",
			planes >= 2, "found %d planes" % planes)
	check("fit: the boss is proposed as a convex cylinder of the right size",
			convex.size() == 1 and absf(float((convex[0] as Dictionary)
				.get("dia_mm", 0.0)) - BOSS_DIA) < CENTRE_TOLERANCE_MM,
			"convex candidates: %s" % str(convex))

	var matched: Array = []
	for hole_entry in HOLES:
		var hole: Dictionary = hole_entry
		var expected_center: Vector3 = hole["center"]
		var best: Dictionary = _nearest(concave, expected_center)
		matched.append(best)
		var found_center: Vector3 = best.get("center", Vector3(1e6, 1e6, 1e6))
		check("fit %s: centre in the reference's own frame" % str(hole["name"]),
				found_center.distance_to(expected_center) < CENTRE_TOLERANCE_MM,
				"got %s, expected %s" % [str(found_center), str(expected_center)])
		check("fit %s: fitted (circumscribed) diameter" % str(hole["name"]),
				absf(float(best.get("dia_mm", 0.0)) - float(hole["dia"])) < CENTRE_TOLERANCE_MM,
				"got %f, expected %f" % [float(best.get("dia_mm", 0.0)), float(hole["dia"])])
		check("fit %s: axis, to within a degree" % str(hole["name"]),
				absf((best.get("axis", Vector3.ZERO) as Vector3)
					.normalized().dot((hole["axis"] as Vector3).normalized())) > 0.99985,
				"got %s, expected %s" % [str(best.get("axis", Vector3.ZERO)), str(hole["axis"])])

	var h1: Dictionary = matched[0]
	check("fit: the wall's facet count is reported, not smoothed away",
			int(h1.get("facets", 0)) == FACETS,
			"facets = %d, expected %d" % [int(h1.get("facets", 0)), FACETS])
	var inscribed_expected := 3.2 * cos(PI / float(FACETS))
	check("fit: the inscribed diameter is smaller than the fitted one and is reported",
			float(h1.get("inscribed_dia_mm", 0.0)) < float(h1.get("dia_mm", 0.0))
				and absf(float(h1.get("inscribed_dia_mm", 0.0)) - inscribed_expected) < 0.002,
			"inscribed = %f, expected %f" % [
				float(h1.get("inscribed_dia_mm", 0.0)), inscribed_expected])
	check("fit: the residual is small enough to justify calling the wall a cylinder",
			float(h1.get("residual_mm", 1.0)) < 0.01,
			"residual = %f" % float(h1.get("residual_mm", 1.0)))

	var tilted: Dictionary = matched[3]
	var tilt := rad_to_deg(acos(clampf(absf(
		(tilted.get("axis", Vector3.UP) as Vector3).normalized().dot(PLATE_NORMAL)), 0.0, 1.0)))
	check("fit: the tilted hole is NOT axis-aligned — an axis-aligned detector misses it",
			absf(tilt - 30.0) < 1.0,
			"tilt from the plate normal = %f degrees" % tilt)

	var blind: Dictionary = matched[4]
	check("fit: the fit alone says nothing about whether a hole goes through",
			not blind.has("through"),
			"the fitter volunteered a through flag: %s" % str(blind))

	# The same plate, mirrored. A negative-determinant transform reverses the
	# handedness of every triangle it moves, and the fitter reads the sense of
	# a cylinder off the winding: without a compensating flip the five holes
	# come back as bosses and the boss comes back as a hole.
	var mirrored_parts: Array = [{
		"mesh": (local_parts[0] as Dictionary)["mesh"],
		"transform": Transform3D(Basis.from_scale(Vector3(-1.0, 1.0, 1.0)), Vector3.ZERO),
		"node": "plate",
	}]
	var mirrored: Dictionary = MeshFeatures.analyze(mirrored_parts)
	var mirrored_concave: Array = MeshFeatures.concave_cylinders(
			mirrored.get("candidates", []), 1.0, 7.0, 0.6)
	var mirrored_convex := 0
	for entry in mirrored.get("candidates", []):
		if str((entry as Dictionary).get("form", "")) == "convex":
			mirrored_convex += 1
	check("mirror: a mirrored copy still reports its five holes as CONCAVE",
			mirrored_concave.size() == HOLES.size(),
			"mirrored gave %d concave cylinders, expected %d"
				% [mirrored_concave.size(), HOLES.size()])
	check("mirror: and its boss as CONVEX — the sense is not inverted with the winding",
			mirrored_convex == 1,
			"mirrored gave %d convex cylinders, expected 1" % mirrored_convex)

	# The same plate with every triangle wound the OTHER way, moved by an
	# ordinary transform that reverses nothing. Godot's own sources all wind
	# clockwise seen from outside, so a fitter that assumes that order reads
	# every normal backwards here and reports the five holes as bosses. Only a
	# fitter that measures the winding — the sign of the part's own signed
	# volume — still calls them holes.
	var reversed_parts: Array = [{
		"mesh": _reversed_winding((local_parts[0] as Dictionary)["mesh"] as ArrayMesh),
		"transform": Transform3D.IDENTITY,
		"node": "plate",
	}]
	var reversed: Dictionary = MeshFeatures.analyze(reversed_parts)
	var reversed_concave: Array = MeshFeatures.concave_cylinders(
			reversed.get("candidates", []), 1.0, 7.0, 0.6)
	var reversed_convex := 0
	for entry in reversed.get("candidates", []):
		if str((entry as Dictionary).get("form", "")) == "convex":
			reversed_convex += 1
	check("winding: an inward-wound file still reports its five holes as CONCAVE",
			reversed_concave.size() == HOLES.size(),
			"reversed winding gave %d concave cylinders, expected %d"
				% [reversed_concave.size(), HOLES.size()])
	check("winding: and its boss as CONVEX",
			reversed_convex == 1,
			"reversed winding gave %d convex cylinders, expected 1" % reversed_convex)

	return matched


## The same geometry with the corner order of every triangle reversed. Only
## vertices and indices are carried over: the normals of the original would
## contradict the new winding, and nothing under test reads them.
func _reversed_winding(mesh: ArrayMesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	for surface in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var indices := PackedInt32Array()
		var raw_index: Variant = arrays[Mesh.ARRAY_INDEX]
		if raw_index is PackedInt32Array and (raw_index as PackedInt32Array).size() >= 3:
			indices = (raw_index as PackedInt32Array).duplicate()
		else:
			for i in range(verts.size()):
				indices.append(i)
		var triangle := 0
		while triangle * 3 + 2 < indices.size():
			var swap := indices[triangle * 3 + 1]
			indices[triangle * 3 + 1] = indices[triangle * 3 + 2]
			indices[triangle * 3 + 2] = swap
			triangle += 1
		var built: Array = []
		built.resize(Mesh.ARRAY_MAX)
		built[Mesh.ARRAY_VERTEX] = verts
		built[Mesh.ARRAY_INDEX] = indices
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, built)
	return out


## Two verbs asking about the same file before either has an answer must
## share one worker task: the second awaits the first's result instead of
## segmenting again. Both calls are started without being awaited, so they
## are in flight together; the collector below gathers their replies.
func _check_concurrent_segmentation(local_parts: Array) -> void:
	var features := MeshFeatures.new()
	var replies: Array = []
	_collect_async(features, "fixture|concurrent", local_parts, replies)
	_collect_async(features, "fixture|concurrent", local_parts, replies)
	var deadline := Time.get_ticks_msec() + 30000
	while replies.size() < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	var same := replies.size() == 2 \
			and int((replies[0] as Dictionary).get("triangles", 0)) > 100 \
			and int((replies[0] as Dictionary).get("triangles", 0)) \
				== int((replies[1] as Dictionary).get("triangles", -1))
	check("segmentation: two concurrent requests for one file segment it ONCE and both get the answer",
			same and int(features.get_analysis_count()) == 1,
			"replies = %d, analysis count = %d" % [replies.size(), int(features.get_analysis_count())])


func _collect_async(features: RefCounted, key: String, parts: Array, into: Array) -> void:
	var reply: Dictionary = await features.features_for_async(
		key, parts, MeshFeatures.DEFAULT_REGION_ANGLE_DEG, self)
	into.append(reply)


# ---------------------------------------------------------------------------
# VERIFY — the physics gauge
# ---------------------------------------------------------------------------

func _check_gauge(baked: ArrayMesh, matched: Array) -> void:
	var gauge := MeshGauge.new()
	gauge.name = "MeshGauge"
	root.add_child(gauge)
	await process_frame

	var bodies: Array = [{"mesh": baked, "transform": _pose, "node": "plate"}]
	var built: int = gauge.build(bodies, "fixture|v1")
	check("gauge: the posed reference became one collider",
			built == 1, "built %d colliders" % built)
	# build() returns the same shape count whether it rebuilt or answered from
	# the digest, so the count cannot tell the two apart. The generation can:
	# it moves only when colliders are actually created.
	var generation_after_build: int = int(gauge.get_generation())
	var rebuilt: int = gauge.build(bodies, "fixture|v1")
	check("gauge: the same reference set is not rebuilt",
			rebuilt == 1 and str(gauge.get_digest()) == "fixture|v1"
				and int(gauge.get_generation()) == generation_after_build,
			"rebuild returned %d with digest '%s', generation %d -> %d" % [
				rebuilt, str(gauge.get_digest()), generation_after_build,
				int(gauge.get_generation())])
	check("gauge: a DIFFERENT reference set does rebuild",
			gauge.build(bodies, "fixture|v2") == 1
				and int(gauge.get_generation()) == generation_after_build + 1,
			"generation stayed at %d after a new digest" % int(gauge.get_generation()))
	gauge.build(bodies, "fixture|v1")

	# Pose the candidates the way the panel does before handing them over: the
	# gauge works entirely in the posed world.
	var posed: Array = []
	for entry in matched:
		var candidate: Dictionary = (entry as Dictionary).duplicate(true)
		candidate["center"] = _pose * (candidate.get("center", Vector3.ZERO) as Vector3)
		candidate["axis"] = (_pose.basis
			* (candidate.get("axis", Vector3.UP) as Vector3)).normalized()
		posed.append(candidate)

	var measured: Dictionary = await gauge.submit("measure_holes", {"candidates": posed})
	var holes: Array = measured.get("holes", [])
	check("gauge: every proposed hole came back measured",
			holes.size() == HOLES.size(),
			"measured %d of %d" % [holes.size(), HOLES.size()])
	if holes.size() != HOLES.size():
		return

	var through_count := 0
	var inverse := _pose.affine_inverse()
	for i in range(HOLES.size()):
		var hole: Dictionary = HOLES[i]
		var report: Dictionary = holes[i]
		var world_center: Vector3 = report.get("center", Vector3.ZERO)
		var expected_world: Vector3 = _pose * (hole["center"] as Vector3)
		check("gauge %s: refined centre in the posed world" % str(hole["name"]),
				world_center.distance_to(expected_world) < CENTRE_TOLERANCE_MM,
				"got %s, expected %s" % [str(world_center), str(expected_world)])
		check("gauge %s: the same point un-posed is the local centre" % str(hole["name"]),
				(inverse * world_center).distance_to(hole["center"] as Vector3)
					< CENTRE_TOLERANCE_MM,
				"un-posed to %s" % str(inverse * world_center))
		var expected_gauge := float(hole["dia"]) * cos(PI / float(FACETS))
		check("gauge %s: the pin that fits is within a facet chord of the drill" % str(hole["name"]),
				absf(float(report.get("gauge_dia_mm", 0.0)) - expected_gauge)
					< GAUGE_TOLERANCE_MM,
				"gauged %f, expected %f" % [
					float(report.get("gauge_dia_mm", 0.0)), expected_gauge])
		if bool(report.get("through", false)):
			through_count += 1

	check("gauge: four holes go through and the blind pocket does not",
			through_count == 4 and not bool((holes[4] as Dictionary).get("through", true)),
			"through count = %d" % through_count)

	# Godot exposes only 32 collision-layer bits. The target deliberately lands
	# after 32 other references and a blocker occupies the old saturated layer;
	# reference scoping must still exclude that blocker by RID.
	var many_bodies: Array = []
	var blocker := BoxMesh.new()
	blocker.size = Vector3(2.0, 20.0, 2.0)
	for i in range(31):
		many_bodies.append({
			"mesh": blocker,
			"transform": Transform3D(Basis.IDENTITY, Vector3(10000.0 + i * 100.0, 0.0, 0.0)),
			"node": "far-%d" % i,
			"reference": "far-%d" % i,
		})
	var first_hole_world: Vector3 = _pose * (HOLES[0]["center"] as Vector3)
	many_bodies.append({
		"mesh": blocker,
		"transform": Transform3D(_pose.basis, first_hole_world),
		"node": "blocker",
		"reference": "overflow-blocker",
	})
	many_bodies.append({
		"mesh": baked,
		"transform": _pose,
		"node": "plate",
		"reference": "target",
	})
	gauge.build(many_bodies, "fixture|over-32-references")
	# The mask is the scope; the name only tells the two references sharing
	# the final layer apart. Both travel, exactly as panel_tools sends them.
	var isolated: Dictionary = await gauge.submit("measure_holes", {
		"candidates": [posed[0]],
		"mask": gauge.mask_for("target"),
		"reference": "target",
	})
	var isolated_holes: Array = isolated.get("holes", [])
	check("gauge: reference scoping stays isolated beyond 32 mounted references",
			isolated_holes.size() == 1
				and bool((isolated_holes[0] as Dictionary).get("verified", false))
				and float((isolated_holes[0] as Dictionary).get("gauge_dia_mm", 0.0)) > 3.0,
			"scoped result = %s" % str(isolated))
	# Control: the same job unscoped (every layer, name still attached) must
	# be shrunk by the blocker — otherwise the isolation above proved nothing.
	var assembly: Dictionary = await gauge.submit("measure_holes", {
		"candidates": [posed[0]],
		"reference": "target",
	})
	var assembly_holes: Array = assembly.get("holes", [])
	check("gauge: unscoped, the overflow blocker IS in the way — the name alone scopes nothing",
			assembly_holes.size() == 1
				and float((assembly_holes[0] as Dictionary).get("gauge_dia_mm", 0.0)) < 3.0,
			"unscoped result = %s" % str(assembly))
	gauge.build(bodies, "fixture|v1")
	var pocket_depth := float(HOLES[4]["depth"])
	check("gauge: the blind pocket's depth is measured, not assumed",
			absf(float((holes[4] as Dictionary).get("depth_mm", 0.0)) - pocket_depth) < 0.1,
			"depth = %f" % float((holes[4] as Dictionary).get("depth_mm", 0.0)))

	# The hole 1.9 mm from the outline: an unbounded search escapes through the
	# edge of the plate and lands outside it entirely.
	var near_edge: Vector3 = inverse * ((holes[2] as Dictionary).get("center", Vector3.ZERO))
	check("gauge: the hole near the outline stayed inside the plate",
			absf(near_edge.x) < PLATE.x * 0.5 and absf(near_edge.z) < PLATE.z * 0.5,
			"centre escaped to %s" % str(near_edge))

	# A gauge one size too large fouls the wall and says where.
	var h1_world: Vector3 = _pose * (HOLES[0]["center"] as Vector3)
	var h1_axis: Vector3 = (_pose.basis * (HOLES[0]["axis"] as Vector3)).normalized()
	var oversize: Dictionary = await gauge.submit("gauge", {
		"shape": "cylinder",
		"size": Vector3(3.2 * cos(PI / float(FACETS)) + 0.3, 2.0, 0.0),
		"at": h1_world,
		"axis": h1_axis,
	})
	check("gauge: a pin one size too large does not fit",
			not bool(oversize.get("fits", true)), "oversize gauge reported a fit")
	check("gauge: it reports where it touched, on the plate",
			(oversize.get("contacts", []) as Array).size() > 0,
			"no contacts reported for the oversize gauge")

	# The tilted hole: right size, right axis fits; right size, plate normal
	# does not. This is the assertion an axis-aligned implementation fails.
	var tilted_world: Vector3 = _pose * (HOLES[3]["center"] as Vector3)
	var tilted_axis: Vector3 = (_pose.basis * (HOLES[3]["axis"] as Vector3)).normalized()
	var tilted_dia := 4.0 * cos(PI / float(FACETS)) - 0.05
	var on_axis: Dictionary = await gauge.submit("gauge", {
		"shape": "cylinder",
		"size": Vector3(tilted_dia, 2.0, 0.0),
		"at": tilted_world,
		"axis": tilted_axis,
	})
	check("gauge: the tilted hole takes its pin on the fitted axis",
			bool(on_axis.get("fits", false)), "the pin did not fit on the fitted axis")
	var off_axis: Dictionary = await gauge.submit("gauge", {
		"shape": "cylinder",
		"size": Vector3(tilted_dia, 2.0, 0.0),
		"at": tilted_world,
		"axis": (_pose.basis * PLATE_NORMAL).normalized(),
	})
	check("gauge: the same pin does NOT fit along the plate normal",
			not bool(off_axis.get("fits", true)),
			"the pin fitted along the wrong axis, so the axis is not being used")

	# The boss, verified the other way round: the wall is where the candidate
	# says it is, and there is nothing just outside it. Three candidates go in
	# together so the check discriminates in BOTH directions — a verifier that
	# always says true fails on the second and third as surely as a verifier
	# that always says false fails on the first.
	var boss_axis: Vector3 = (_pose.basis * PLATE_NORMAL).normalized()
	var real_boss := {
		"kind": "cylinder",
		"form": "convex",
		"center": _pose * BOSS_CENTER,
		"axis": boss_axis,
		"radius_mm": BOSS_DIA * 0.5,
		"dia_mm": BOSS_DIA,
	}
	# Same place, radius 1.5 mm too large: the wall is not there, and the
	# probe straddling the claimed radius touches nothing.
	var wrong_radius := (real_boss as Dictionary).duplicate(true)
	wrong_radius["radius_mm"] = BOSS_DIA * 0.5 + 1.5
	wrong_radius["dia_mm"] = BOSS_DIA + 3.0
	# The right size, standing in clear air 20 mm off the end of the plate.
	var empty_air := (real_boss as Dictionary).duplicate(true)
	empty_air["center"] = _pose * (BOSS_CENTER + Vector3(0.0, 0.0, 40.0))
	var bosses: Dictionary = await gauge.submit(
		"measure_convex", {"candidates": [real_boss, wrong_radius, empty_air]})
	var boss_reports: Array = bosses.get("cylinders", [])
	check("gauge: the boss's wall is found at the fitted radius, with clear air outside it",
			boss_reports.size() == 3
				and bool((boss_reports[0] as Dictionary).get("verified", false)),
			"boss verification: %s" % str(bosses))
	check("gauge: a boss candidate 1.5 mm too fat does NOT verify",
			boss_reports.size() == 3
				and not bool((boss_reports[1] as Dictionary).get("verified", true)),
			"an oversize boss candidate verified: %s" % str(boss_reports))
	check("gauge: a boss candidate standing in empty air does NOT verify",
			boss_reports.size() == 3
				and not bool((boss_reports[2] as Dictionary).get("verified", true)),
			"a boss candidate in empty air verified: %s" % str(boss_reports))

	# A ray at a known place hits the top face at a known height.
	var probe_local := Vector3(5.0, 0.0, 5.0)
	var probe_from: Vector3 = _pose * (probe_local + PLATE_NORMAL * 20.0)
	var probe_to: Vector3 = _pose * (probe_local - PLATE_NORMAL * 20.0)
	var probe: Dictionary = await gauge.submit(
		"raycast", {"from": probe_from, "to": probe_to})
	var probe_local_hit: Vector3 = inverse * (probe.get("position", Vector3.ZERO) as Vector3)
	check("probe: a ray onto solid plate hits the top face at y = +2",
			bool(probe.get("hit", false)) and absf(probe_local_hit.y - 2.0) < 0.05,
			"hit %s -> local %s" % [str(probe.get("hit", false)), str(probe_local_hit)])
	check("probe: the hit is attributed to the node it came from",
			str(probe.get("node", "")) == "plate",
			"attributed to '%s'" % str(probe.get("node", "")))

	# A gauge buried in solid material. The colliders are a SURFACE, not a
	# volume: a pin inside the plate crosses no triangle and overlaps nothing,
	# which is exactly what open air looks like to intersect_shape. A point
	# 16 mm along -Z from the plate centre is solid — every hole and the boss
	# are elsewhere — so a fit reported here is the failure this asserts on.
	var solid_local := Vector3(0.0, 0.0, -16.0)
	var buried: Dictionary = await gauge.submit("gauge", {
		"shape": "sphere",
		"size": Vector3(1.0, 0.0, 0.0),
		"at": _pose * solid_local,
		"axis": (_pose.basis * PLATE_NORMAL).normalized(),
	})
	check("gauge: a pin wholly INSIDE the material does not fit, and says why",
			not bool(buried.get("fits", true))
				and str(buried.get("reason", "")) == "inside_solid",
			"buried gauge reported %s" % str(buried))

	# Clearance is bounded by the part, not by the pin. A 1 mm pin standing in
	# the 5 mm blind pocket has nearly 2 mm of radial room; a search capped at
	# twice the pin's own diameter can only ever report 1.5.
	var pocket_world: Vector3 = _pose * (HOLES[4]["center"] as Vector3)
	var roomy: Dictionary = await gauge.submit("gauge", {
		"shape": "cylinder",
		"size": Vector3(1.0, 1.0, 0.0),
		"at": pocket_world,
		"axis": (_pose.basis * (HOLES[4]["axis"] as Vector3)).normalized(),
	})
	var pocket_clearance := 5.0 * cos(PI / float(FACETS)) * 0.5 - 0.5
	check("gauge: clearance is searched to the part's own extent, not to a multiple of the pin",
			bool(roomy.get("fits", false))
				and absf(float(roomy.get("clearance_mm", 0.0)) - pocket_clearance) < 0.05
				and float(roomy.get("clearance_bound_mm", 0.0)) > 10.0,
			"clearance %f (expected %f), bound %f" % [
				float(roomy.get("clearance_mm", 0.0)), pocket_clearance,
				float(roomy.get("clearance_bound_mm", 0.0))])

	# The same pin in OPEN SPACE, 200 mm off the plate along its normal. No
	# ray meets anything, so the only number available is the search bound
	# itself — which is a floor on the room there is, not a measurement of it.
	# Reporting it as clearance_mm would say "there is exactly this much room"
	# about a place where nothing was found at all.
	var open_air: Vector3 = _pose * (Vector3(0.0, 200.0, 0.0))
	var unbounded: Dictionary = await gauge.submit("gauge", {
		"shape": "cylinder",
		"size": Vector3(1.0, 1.0, 0.0),
		"at": open_air,
		"axis": (_pose.basis * PLATE_NORMAL).normalized(),
	})
	var floor_mm := float(unbounded.get("clearance_bound_mm", 0.0)) - 0.5
	check("gauge: in open space the search bound is reported as a FLOOR, not as a radius",
			bool(unbounded.get("fits", false))
				and not bool(unbounded.get("clearance_bounded", true))
				and not unbounded.has("clearance_mm")
				and absf(float(unbounded.get("clearance_at_least_mm", 0.0)) - floor_mm) < 0.01
				and floor_mm > 0.0,
			"open-space gauge reported %s" % str(unbounded))

	# The fallback path, exercised on its own: a ray grid finds holes with no
	# fit at all — and finds FEWER of them, which is exactly why it is the
	# fallback and not the proposal. Of the five holes it can seed at most four:
	#   H5 is blind, so its cells are not misses at all and it is never seeded;
	#   H3 is 1.9 mm from the outline, which puts its CENTRE 3.5 mm in — so the
	#      neighbour test 4 mm away refuses the outer cells of its cluster (they
	#      look off the edge) and keeps the inner ones, and the seed comes back
	#      pulled towards the middle of the plate rather than not at all;
	#   H4 is tilted, so its clear vertical channel is only 1.7 mm wide and
	#      whether a 1 mm grid samples it at all is a matter of alignment.
	# H1 and H2 are always seeded. A run that seeds MORE than four has started
	# calling the outside world a hole, which the next check tests directly.
	var seeded: Dictionary = await gauge.submit("seed_grid", {
		"bounds": _world_bounds(),
		"axis": (_pose.basis * PLATE_NORMAL).normalized(),
		"pitch_mm": 1.0,
	})
	var seeds: Array = seeded.get("seeds", [])
	var seed_locals: Array = []
	for entry in seeds:
		seed_locals.append(inverse * ((entry as Dictionary).get("center", Vector3.ZERO) as Vector3))
	check("fallback: the ray grid seeds the plain through holes and nothing spurious",
			seeds.size() >= 2 and seeds.size() <= 4,
			"seeded %d clusters at %s" % [seeds.size(), str(seed_locals)])
	var all_near := seeds.size() > 0
	for entry in seeds:
		var seed: Dictionary = entry
		var seed_local: Vector3 = inverse * (seed.get("center", Vector3.ZERO) as Vector3)
		var nearest := 1.0e6
		for i in range(4):
			var expected: Vector3 = HOLES[i]["center"]
			nearest = minf(nearest, Vector2(seed_local.x - expected.x,
				seed_local.z - expected.z).length())
		if nearest > 1.0:
			all_near = false
	check("fallback: every seed lands on a hole, not on the outline",
			all_near, "a seed was more than 1 mm from every through-hole centre")

	gauge.queue_free()


# ---------------------------------------------------------------------------
# COINCIDENT FACES — two plates resting on each other
# ---------------------------------------------------------------------------

## Two plates that share a face put two triangles at the same point, and
## material continues through both: the parity of a ray crossing them is
## unchanged, so a point beyond them is still outside. A crossing counter that
## steps past both with one nudge counts one, and every point beyond the stack
## reads as INSIDE — which makes the gauge refuse to fit in open air.
##
## The fixture is two such stacks, one shared face perpendicular to X and one
## perpendicular to Z, placed so that the X ray and the Z ray from the test
## point each cross one of them. Parity votes two axes against a third, so a
## fixture with only one stack is rescued by the tiebreaker and proves nothing.
func _check_coincident_faces() -> void:
	var gauge := MeshGauge.new()
	gauge.name = "CoincidentGauge"
	root.add_child(gauge)
	await process_frame

	# A 4 mm plate, 20 x 20 in the other two axes. Two of them face to face
	# make one stack; the second stack is the same mesh turned a quarter turn.
	var plate := BoxMesh.new()
	plate.size = Vector3(4.0, 20.0, 20.0)
	var quarter := Basis(Vector3.UP, PI * 0.5)
	var bodies: Array = [
		# Stack across X, at z = -20: faces at x = 0, 4 (shared) and 8.
		{"mesh": plate, "transform": Transform3D(Basis.IDENTITY, Vector3(2.0, 0.0, -20.0)),
			"node": "XLower", "reference": "stack"},
		{"mesh": plate, "transform": Transform3D(Basis.IDENTITY, Vector3(6.0, 0.0, -20.0)),
			"node": "XUpper", "reference": "stack"},
		# Stack across Z, at x = -20: faces at z = 0, 4 (shared) and 8.
		{"mesh": plate, "transform": Transform3D(quarter, Vector3(-20.0, 0.0, 2.0)),
			"node": "ZLower", "reference": "stack"},
		{"mesh": plate, "transform": Transform3D(quarter, Vector3(-20.0, 0.0, 6.0)),
			"node": "ZUpper", "reference": "stack"},
	]
	var built: int = gauge.build(bodies, "coincident|v1")
	check("coincident: the four plates became four colliders",
			built == 4, "built %d colliders" % built)

	# Inside the lower plate of the X stack. Solid either way the crossings are
	# counted, so this is the control that says the fixture is closed material.
	var inside: Dictionary = await gauge.submit("gauge", {
		"shape": "sphere",
		"size": Vector3(1.0, 0.0, 0.0),
		"at": Vector3(2.0, 0.0, -20.0),
		"axis": Vector3.UP,
	})
	check("coincident: a pin inside one plate of the stack is refused as inside_solid",
			not bool(inside.get("fits", true))
				and str(inside.get("reason", "")) == "inside_solid",
			"reply=%s" % str(inside))

	# Open air. Its +X ray crosses the X stack (two faces, the shared pair,
	# two faces) and its +Z ray crosses the Z stack the same way: four
	# crossings each, even, outside. Counting the shared pair once makes both
	# three — odd — and the pin is refused in empty space.
	var air: Dictionary = await gauge.submit("gauge", {
		"shape": "sphere",
		"size": Vector3(1.0, 0.0, 0.0),
		"at": Vector3(-20.0, 0.0, -20.0),
		"axis": Vector3.UP,
	})
	check("coincident: a pin in AIR beyond two shared faces still fits — the "
			+ "coincident triangles were counted twice",
			bool(air.get("fits", false)) and not air.has("reason"),
			"reply=%s" % str(air))

	gauge.queue_free()


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

## Build the plate with runtime CSG and bake it to a mesh. CSG needs to be in
## the tree and processed once before it has any geometry to bake.
func _bake_fixture() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Fixture"

	var plate := CSGBox3D.new()
	plate.size = PLATE
	combiner.add_child(plate)

	for entry in HOLES:
		var hole: Dictionary = entry
		var cutter := CSGCylinder3D.new()
		cutter.operation = CSGShape3D.OPERATION_SUBTRACTION
		cutter.radius = float(hole["dia"]) * 0.5
		cutter.sides = FACETS
		cutter.smooth_faces = false
		if bool(hole["through"]):
			cutter.height = 20.0
			cutter.position = Vector3(
				float((hole["center"] as Vector3).x),
				0.0,
				float((hole["center"] as Vector3).z))
			var axis: Vector3 = (hole["axis"] as Vector3).normalized()
			if axis.dot(PLATE_NORMAL) < 0.9999:
				# The tilted hole. A CSG cylinder runs along its own +Y, and a
				# rotation of theta about Z takes +Y to (-sin theta, cos theta,
				# 0); solving that for the declared axis is the only place the
				# tilt is decided, so the cutter cannot disagree with the
				# constant the assertions are written against.
				cutter.rotation = Vector3(0.0, 0.0, atan2(-axis.x, axis.y))
		else:
			# The blind pocket: 4 tall, sitting on the top face, so it removes
			# the upper 2 mm of the plate and leaves a floor at y = 0.
			cutter.height = 4.0
			cutter.position = Vector3(
				float((hole["center"] as Vector3).x),
				PLATE.y * 0.5,
				float((hole["center"] as Vector3).z))
		combiner.add_child(cutter)

	var boss := CSGCylinder3D.new()
	boss.operation = CSGShape3D.OPERATION_UNION
	boss.radius = BOSS_DIA * 0.5
	boss.height = 5.0
	boss.sides = FACETS
	boss.smooth_faces = false
	boss.position = BOSS_CENTER
	combiner.add_child(boss)

	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


func _world_bounds() -> AABB:
	var half := PLATE * 0.5
	var box := AABB(_pose * Vector3(-half.x, -half.y, -half.z), Vector3.ZERO)
	for i in range(8):
		var corner := Vector3(
			half.x if (i & 1) != 0 else -half.x,
			half.y if (i & 2) != 0 else -half.y,
			half.z if (i & 4) != 0 else -half.z
		)
		box = box.expand(_pose * corner)
	return box


func _nearest(candidates: Array, target: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := 1.0e9
	for entry in candidates:
		var candidate: Dictionary = entry
		var distance: float = (candidate.get("center", Vector3.ZERO) as Vector3) \
			.distance_to(target)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


func check(desc: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)
