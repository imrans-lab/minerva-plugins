extends SceneTree
## The measurement VERBS, driven the way an LLM drives them.
##
## WHY THIS SUITE EXISTS SEPARATELY FROM test_mesh_measurement.gd
##
## That suite proves the physics and the fitting: it calls MeshFeatures and
## MeshGauge directly and checks the numbers. Nothing in it touches
## PanelTools.handle, and the verb layer is where the contract an agent
## actually depends on lives — every number in millimetres, in BOTH frames,
## with a residual where there is one, a status on every reply, and a named
## error rather than an empty result when the question was malformed. A verb
## that serialised only world coordinates, dropped `residual_mm`, or answered
## "count: 0" to a bad reference name would pass every assertion over there.
##
## THE FIXTURE IS A TWO-PLATE STACK, ON PURPOSE. A board exported from any
## real tool is many nodes — substrate, copper, mask — and one drill crosses
## all of them. Fitted per node, the four mounting holes of such a board come
## back as eight or twelve rows and the agent has to work out which are the
## same hole. Two plates with the same two holes through both is the smallest
## fixture that has that shape: the verb must answer TWO holes, each naming
## both plates.
##
## The stack is posed by a non-identity transform, so `local` and `world` are
## different numbers and a verb that reports one of them twice is caught.
##
## The panel is stood in for — CADPanel needs the plugin host and its
## autoloads — but nothing that produces a number is: the features, the gauge,
## the colliders and the verbs are the real ones.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const MeshFeatures := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_features.gd")
const MeshGauge := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")
const PanelTools := preload("res://../../minerva-plugins/cad/ui/panel_tools.gd")

## One plate: 40 x 30 in X and Z, 4 thick in Y, holes drilled along +Y.
const PLATE := Vector3(40.0, 4.0, 30.0)
const PLATE_AXIS := Vector3.UP
const FACETS := 64
const HOLE_DIA := 3.2
## Where the two drills are, in the plate's own XZ.
const HOLE_XZ := [Vector2(-12.0, -8.0), Vector2(12.0, 8.0)]
## The second plate sits directly on top of the first: the stack runs from
## y = -2 to y = +6 and each drill crosses both plates.
const PLATE_B_OFFSET := Vector3(0.0, 4.0, 0.0)
## A boss standing on the top face of the upper plate, so "find cylinders,
## convex" has something to find that "find holes" must not report.
const BOSS_DIA := 6.0
const BOSS_HEIGHT := 5.0
const BOSS_CENTRE := Vector3(0.0, 8.5, 0.0)

## Pose applied to the whole reference: rotate 90 degrees about Z, then
## translate. Nothing here is symmetric under it.
const POSE_ORIGIN := Vector3(100.0, 200.0, 300.0)

const CENTRE_TOLERANCE_MM := 0.05
const PIXEL_SIZE := Vector2i(400, 300)

var _pass: int = 0
var _fail: int = 0
var _pose: Transform3D = Transform3D.IDENTITY
var _panel: PanelStandIn = null


func _init() -> void:
	print("=== CAD Measurement Verb Envelope Test ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_pose = Transform3D(
		Basis(Vector3(0.0, 1.0, 0.0), Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0)),
		POSE_ORIGIN)

	var plate: ArrayMesh = await _bake_plate()
	var boss: ArrayMesh = await _bake_boss()
	check("fixture: the plate and the boss baked to meshes",
			plate != null and plate.get_surface_count() > 0
				and boss != null and boss.get_surface_count() > 0,
			"bake_static_mesh returned nothing")
	if plate == null or boss == null:
		return

	_panel = PanelStandIn.new()
	_panel.features = MeshFeatures.new()
	_panel.gauge = MeshGauge.new()
	_panel.gauge.name = "MeshGauge"
	_panel.record = {
		"name": "board",
		"path": "board.glb",
		"resolved_path": "/virtual/board.glb",
		"stamp": "content-digest-1",
		"units": "mm",
		"up": "z",
		"status": "ok",
		"reason": "",
		"pose": _pose,
		"local_aabb": AABB(Vector3(-20.0, -2.0, -15.0), Vector3(40.0, 13.0, 30.0)),
		"parts": [
			{"mesh": plate, "transform": Transform3D.IDENTITY, "node": "PlateA"},
			{"mesh": plate, "transform": Transform3D(Basis.IDENTITY, PLATE_B_OFFSET),
				"node": "PlateB"},
			{"mesh": boss, "transform": Transform3D(Basis.IDENTITY, BOSS_CENTRE),
				"node": "Boss"},
		],
		"node_bounds": [],
	}
	root.add_child(_panel)
	_panel.add_child(_panel.gauge)
	await process_frame

	await _test_find_holes_reports_one_row_per_drill_in_both_frames()
	await _test_find_cylinders_reports_the_boss_and_names_a_bad_reference()
	await _test_the_gauge_verb_answers_fits_and_says_where_it_touched()
	await _test_probe_turns_a_ray_into_a_position_in_both_frames()
	await _test_view_overlay_reports_a_scale_per_pane()
	await _test_a_node_filter_that_matches_nothing_is_an_error()
	await _test_a_second_reference_cannot_change_this_one_s_measurement()
	await _test_a_scaled_pose_reports_world_and_local_diameters()
	await _test_a_document_changing_under_a_measurement_is_marked_stale()

	_panel.queue_free()


# ---------------------------------------------------------------------------
# A node filter is a claim about the file
# ---------------------------------------------------------------------------

## `node="PlateZ"` filters the parts to nothing. Returning a successful "no
## holes" makes a typo indistinguishable from a plate with no holes in it, and
## the typo is by far the likelier of the two.
func _test_a_node_filter_that_matches_nothing_is_an_error() -> void:
	var reply: Dictionary = await PanelTools.handle(
			_panel, "minerva_cad_find_holes", {"node": "PlateZ"})
	check("find_holes: a node filter matching nothing is a named error listing the nodes",
			not bool(reply.get("success", true))
				and str(reply.get("error", "")).contains("PlateZ")
				and str(reply.get("error", "")).contains("PlateA")
				and not reply.has("holes"),
			"reply=%s" % str(reply))

	var real: Dictionary = await PanelTools.handle(
			_panel, "minerva_cad_find_holes", {"node": "PlateA", "min_dia_mm": 1.0})
	check("find_holes: a node filter that DOES match still measures that node",
			bool(real.get("success", false)) and (real.get("holes", []) as Array).size() == 2,
			"reply=%s" % str(real))


# ---------------------------------------------------------------------------
# Verification is physics, and physics sees everything in the space
# ---------------------------------------------------------------------------

## A second reference posed so that a bar runs down the middle of the board's
## first drill. Scoped to "board", the measurement must be exactly what it was
## before the bar existed; unscoped, the bar must actually be in the way — that
## control is what stops this test passing because the bar missed.
func _test_a_second_reference_cannot_change_this_one_s_measurement() -> void:
	var bar: ArrayMesh = await _bake_plug()
	var drill_local := Vector3(
			float((HOLE_XZ[0] as Vector2).x), 2.0, float((HOLE_XZ[0] as Vector2).y))
	_panel.extra = {
		"name": "plug",
		"path": "plug.glb",
		"resolved_path": "/virtual/plug.glb",
		"stamp": "content-digest-2",
		"units": "mm",
		"up": "z",
		"status": "ok",
		"reason": "",
		"pose": _pose,
		"local_aabb": AABB(drill_local - Vector3(1.0, 10.0, 1.0), Vector3(2.0, 20.0, 2.0)),
		"parts": [{
			"mesh": bar,
			"transform": Transform3D(Basis.IDENTITY, drill_local),
			"node": "Bar",
			"node_path": "Bar",
		}],
		"node_bounds": [],
	}
	_panel.digest = "verbs|v2-with-plug"

	var scoped: Dictionary = await PanelTools.handle(_panel, "minerva_cad_find_holes",
			{"reference": "board", "min_dia_mm": 1.0, "max_dia_mm": 8.0})
	var scoped_holes: Array = scoped.get("holes", [])
	var inscribed := HOLE_DIA * cos(PI / float(FACETS))
	var unchanged := scoped_holes.size() == HOLE_XZ.size()
	for entry in scoped_holes:
		var hole: Dictionary = entry
		if not bool(hole.get("verified", false)) \
				or absf(float(hole.get("gauge_dia_mm", 0.0)) - inscribed) > 0.05:
			unchanged = false
	check("find_holes reference=board: a bar through the drill belongs to another "
			+ "reference and does not touch the measurement",
			unchanged, "reply=%s" % str(scoped))

	var unscoped: Dictionary = await PanelTools.handle(_panel, "minerva_cad_find_holes",
			{"min_dia_mm": 1.0, "max_dia_mm": 8.0})
	var obstructed := false
	for entry in unscoped.get("holes", []):
		var hole: Dictionary = entry
		if str(hole.get("reference", "")) != "board":
			continue
		if float(hole.get("gauge_dia_mm", 0.0)) < inscribed - 0.05:
			obstructed = true
	check("control: with every reference in scope the bar IS in the way — the "
			+ "isolation above is doing work",
			obstructed, "reply=%s" % str(unscoped))

	# "PlateA" is a node of the board and of nothing else. With the plug also
	# mounted, a filter evaluated per reference and refused on the first miss
	# turns a perfectly good question into an error.
	var per_reference: Dictionary = await PanelTools.handle(_panel,
			"minerva_cad_find_holes", {"node": "PlateA", "min_dia_mm": 1.0})
	check("find_holes: a node in ONE of two mounted references is a match, not a typo",
			bool(per_reference.get("success", false))
				and (per_reference.get("holes", []) as Array).size() == 2,
			"reply=%s" % str(per_reference))

	_panel.extra = {}
	_panel.digest = "verbs|v1"


# ---------------------------------------------------------------------------
# A scaled pose
# ---------------------------------------------------------------------------

## scale([2,2,2], mesh(...)) makes the board twice the size in the world. The
## drill is then 2x its file diameter in world millimetres and 1x in local, and
## a report that scales positions but not lengths gets one of the two wrong.
func _test_a_scaled_pose_reports_world_and_local_diameters() -> void:
	var scaled_pose := Transform3D(_pose.basis.scaled(Vector3(2.0, 2.0, 2.0)), POSE_ORIGIN)
	_panel.record["pose"] = scaled_pose
	_panel.digest = "verbs|v3-scaled"

	var reply: Dictionary = await PanelTools.handle(_panel, "minerva_cad_find_holes",
			{"min_dia_mm": 1.0, "max_dia_mm": 16.0})
	var holes: Array = reply.get("holes", [])
	var hole: Dictionary = holes[0] if holes.size() > 0 else {}
	var local_lengths: Dictionary = hole.get("local", {})
	var inscribed := HOLE_DIA * cos(PI / float(FACETS))
	check("find_holes scale 2: the world gauge diameter is TWICE the file's",
			holes.size() == HOLE_XZ.size()
				and absf(float(hole.get("gauge_dia_mm", 0.0)) - inscribed * 2.0) < 0.1
				and absf(float(hole.get("scale", 0.0)) - 2.0) < 0.001,
			"reply=%s" % str(reply))
	check("find_holes scale 2: and the local one is the file's own, unscaled",
			absf(float(local_lengths.get("gauge_dia_mm", 0.0)) - inscribed) < 0.05,
			"local lengths: %s" % str(local_lengths))

	# min/max_dia_mm are world millimetres, like every reported length. At
	# scale 2 the 3.2 mm drill is a 6.4 mm hole in the world, so a ceiling of
	# 5 mm must exclude it and a ceiling of 8 mm must admit it. A filter
	# applied to the file's own diameters admits the drill under BOTH, which
	# is the same defect that lets max_dia_mm=8 admit a 16 mm world hole.
	var too_small: Dictionary = await PanelTools.handle(_panel, "minerva_cad_find_holes",
			{"min_dia_mm": 1.0, "max_dia_mm": 5.0})
	check("find_holes scale 2: a 5 mm ceiling excludes a hole that is 6.4 mm in the world",
			bool(too_small.get("success", false))
				and (too_small.get("holes", []) as Array).is_empty(),
			"reply=%s" % str(too_small))
	var admitted: Dictionary = await PanelTools.handle(_panel, "minerva_cad_find_holes",
			{"min_dia_mm": 1.0, "max_dia_mm": 8.0})
	check("find_holes scale 2: an 8 mm ceiling still admits it — the filter moved, "
			+ "it did not just tighten",
			(admitted.get("holes", []) as Array).size() == HOLE_XZ.size(),
			"reply=%s" % str(admitted))

	_panel.record["pose"] = _pose
	_panel.digest = "verbs|v1"


# ---------------------------------------------------------------------------
# The document moves while a verb waits
# ---------------------------------------------------------------------------

## A verb waits on the segmentation worker and on a physics step, and a DSL
## edit can land in between. The stand-in re-digests itself every frame while
## `churn` is on, which is a document that never settles: the verb must say
## so rather than hand back numbers for a pose the document no longer has.
## With the churn off the same call carries no such mark.
func _test_a_document_changing_under_a_measurement_is_marked_stale() -> void:
	_panel.churn = true
	var churned: Dictionary = await PanelTools.handle(_panel, "minerva_cad_find_holes",
			{"min_dia_mm": 1.0, "max_dia_mm": 8.0})
	check("find_holes: a reference set that changes under the verb comes back marked stale, with a reason",
			bool(churned.get("success", false))
				and bool(churned.get("stale", false))
				and not str(churned.get("stale_reason", "")).is_empty(),
			"reply=%s" % str(churned))
	_panel.churn = false
	_panel.digest = "verbs|v1"
	var settled: Dictionary = await PanelTools.handle(_panel, "minerva_cad_find_holes",
			{"min_dia_mm": 1.0, "max_dia_mm": 8.0})
	check("find_holes: a settled document is not marked stale",
			bool(settled.get("success", false)) and not settled.has("stale"),
			"reply=%s" % str(settled))


# ---------------------------------------------------------------------------
# minerva_cad_find_holes
# ---------------------------------------------------------------------------

func _test_find_holes_reports_one_row_per_drill_in_both_frames() -> void:
	var reply: Dictionary = await PanelTools.handle(
			_panel, "minerva_cad_find_holes", {"min_dia_mm": 1.0, "max_dia_mm": 8.0})

	check("find_holes: the reply is a success envelope in millimetres",
			bool(reply.get("success", false)) and str(reply.get("units", "")) == "mm",
			"reply=%s" % str(reply))

	var holes: Array = reply.get("holes", [])
	check("find_holes: one row per DRILL, not one per node the drill crosses",
			holes.size() == HOLE_XZ.size() and int(reply.get("count", -1)) == HOLE_XZ.size(),
			"got %d rows for %d drills through 2 plates: %s"
				% [holes.size(), HOLE_XZ.size(), str(holes)])
	if holes.size() != HOLE_XZ.size():
		return

	var both_plates := true
	var frames_ok := true
	var residual_ok := true
	var verified := 0
	var inverse := _pose.affine_inverse()
	for entry in holes:
		var hole: Dictionary = entry
		var nodes: Array = hole.get("nodes", [])
		if not (nodes.has("PlateA") and nodes.has("PlateB")):
			both_plates = false
		var centre: Dictionary = hole.get("center_mm", {})
		var world: Array = centre.get("world", [])
		var local: Array = centre.get("local", [])
		if world.size() != 3 or local.size() != 3:
			frames_ok = false
			continue
		var world_point := Vector3(float(world[0]), float(world[1]), float(world[2]))
		var local_point := Vector3(float(local[0]), float(local[1]), float(local[2]))
		# The local frame is the world one with the pose taken back off. A verb
		# that reported world twice, or forgot the pose, misses here.
		if (inverse * world_point).distance_to(local_point) > CENTRE_TOLERANCE_MM:
			frames_ok = false
		if world_point.distance_to(local_point) < 1.0:
			frames_ok = false
		var axis: Dictionary = hole.get("axis", {})
		if (axis.get("world", []) as Array).size() != 3 \
				or (axis.get("local", []) as Array).size() != 3:
			frames_ok = false
		if hole.get("residual_mm", null) == null:
			residual_ok = false
		if bool(hole.get("verified", false)):
			verified += 1

	check("find_holes: each row names every node its drill crosses",
			both_plates, "nodes: %s" % str(holes))
	check("find_holes: every position and axis comes back in world AND local millimetres",
			frames_ok, "rows: %s" % str(holes))
	check("find_holes: the fit residual reaches the verb",
			residual_ok, "rows: %s" % str(holes))
	check("find_holes: the gauge confirmed both drills",
			verified == HOLE_XZ.size(), "%d of %d verified" % [verified, HOLE_XZ.size()])

	# The local centres are the fixture's own numbers: the drills are at their
	# XZ positions and, merged across the stack, midway up it (y = +2).
	var matched := 0
	for entry in holes:
		var local: Array = (entry as Dictionary).get("center_mm", {}).get("local", [])
		if local.size() != 3:
			continue
		for xz in HOLE_XZ:
			var expected := Vector3(float((xz as Vector2).x), 2.0, float((xz as Vector2).y))
			if Vector3(float(local[0]), float(local[1]), float(local[2])) \
					.distance_to(expected) < CENTRE_TOLERANCE_MM:
				matched += 1
	check("find_holes: the local centres are the drills' own coordinates in the stack",
			matched == HOLE_XZ.size(),
			"%d of %d rows landed on a drill: %s" % [matched, HOLE_XZ.size(), str(holes)])

	check("find_holes: the merged row is as deep as the whole stack, and goes through",
			bool((holes[0] as Dictionary).get("through", false))
				and float((holes[0] as Dictionary).get("extent_mm", 0.0)) > 7.0,
			"row: %s" % str(holes[0]))

	# The boss is convex; a hole finder that reports it is reporting the
	# outside of a cylinder as the inside of one.
	var gauge_dias: Array = []
	for entry in holes:
		gauge_dias.append(float((entry as Dictionary).get("gauge_dia_mm", 0.0)))
	check("find_holes: the convex boss is not reported as a hole",
			gauge_dias.max() < BOSS_DIA - 1.0,
			"gauge diameters: %s" % str(gauge_dias))


# ---------------------------------------------------------------------------
# minerva_cad_find_cylinders
# ---------------------------------------------------------------------------

func _test_find_cylinders_reports_the_boss_and_names_a_bad_reference() -> void:
	var reply: Dictionary = await PanelTools.handle(
			_panel, "minerva_cad_find_cylinders", {"kind": "convex", "min_dia_mm": 4.0})
	var found: Array = reply.get("cylinders", [])
	var boss: Dictionary = found[0] if found.size() > 0 else {}
	check("find_cylinders convex: the boss is reported, in millimetres, as a convex form",
			bool(reply.get("success", false)) and str(reply.get("units", "")) == "mm"
				and found.size() == 1 and str(boss.get("form", "")) == "convex"
				and absf(float(boss.get("dia_mm", 0.0)) - BOSS_DIA) < 0.05,
			"reply=%s" % str(reply))
	check("find_cylinders convex: the boss verifies against the colliders",
			bool(boss.get("verified", false)),
			"boss row: %s" % str(boss))
	var boss_centre: Dictionary = boss.get("center_mm", {})
	check("find_cylinders convex: the boss position is in both frames too",
			(boss_centre.get("world", []) as Array).size() == 3
				and (boss_centre.get("local", []) as Array).size() == 3,
			"centre: %s" % str(boss_centre))

	# A misspelled reference is a question about something that is not there.
	# An empty result would read as "this board has no cylinders".
	var bad: Dictionary = await PanelTools.handle(
			_panel, "minerva_cad_find_cylinders", {"reference": "bored"})
	check("find_cylinders: an unmounted reference name is a named error, not count 0",
			not bool(bad.get("success", true))
				and str(bad.get("error", "")).contains("bored")
				and not bad.has("cylinders"),
			"reply=%s" % str(bad))


# ---------------------------------------------------------------------------
# minerva_cad_gauge
# ---------------------------------------------------------------------------

func _test_the_gauge_verb_answers_fits_and_says_where_it_touched() -> void:
	var drill_world: Vector3 = _pose * Vector3(
			float((HOLE_XZ[0] as Vector2).x), 2.0, float((HOLE_XZ[0] as Vector2).y))
	var axis_world: Vector3 = (_pose.basis * PLATE_AXIS).normalized()
	var inscribed := HOLE_DIA * cos(PI / float(FACETS))

	var fits: Dictionary = await PanelTools.handle(_panel, "minerva_cad_gauge", {
		"shape": "cylinder",
		"dia_mm": inscribed - 0.1,
		"length_mm": 6.0,
		"at_mm": [drill_world.x, drill_world.y, drill_world.z],
		"axis": [axis_world.x, axis_world.y, axis_world.z],
	})
	check("gauge verb: an undersize pin fits and reports no contacts",
			bool(fits.get("success", false)) and str(fits.get("units", "")) == "mm"
				and bool(fits.get("fits", false))
				and (fits.get("contacts", []) as Array).is_empty(),
			"reply=%s" % str(fits))

	var fouls: Dictionary = await PanelTools.handle(_panel, "minerva_cad_gauge", {
		"shape": "cylinder",
		"dia_mm": inscribed + 0.5,
		"length_mm": 6.0,
		"at_mm": [drill_world.x, drill_world.y, drill_world.z],
		"axis": [axis_world.x, axis_world.y, axis_world.z],
		"reference": "board",
	})
	var contacts: Array = fouls.get("contacts", [])
	var contact: Dictionary = contacts[0] if contacts.size() > 0 else {}
	var contact_point: Dictionary = contact.get("point_mm", {})
	check("gauge verb: an oversize pin does not fit and says where it touched, in both frames",
			not bool(fouls.get("fits", true)) and contacts.size() > 0
				and (contact_point.get("world", []) as Array).size() == 3
				and (contact_point.get("local", []) as Array).size() == 3
				and str(contact.get("reference", "")) == "board",
			"reply=%s" % str(fouls))

	# One identity string: the node a contact names is the bare path, the same
	# string find_holes puts in `nodes` and a node= filter takes. The reference
	# is a field of its own, never a prefix spliced onto the path.
	var named_bare := false
	for contact_entry in contacts:
		var touched: Dictionary = contact_entry
		if str(touched.get("node", "")) in ["PlateA", "PlateB"] \
				and str(touched.get("reference", "")) == "board":
			named_bare = true
	check("gauge verb: a contact names its node by the SAME string a node= filter "
			+ "takes, with the reference beside it rather than spliced into it",
			named_bare, "contacts: %s" % str(contacts))

	var bad_shape: Dictionary = await PanelTools.handle(
			_panel, "minerva_cad_gauge", {"shape": "cone", "dia_mm": 2.0})
	check("gauge verb: an unsupported shape is a named error, not a silent default",
			not bool(bad_shape.get("success", true))
				and str(bad_shape.get("error", "")).contains("cone"),
			"reply=%s" % str(bad_shape))


# ---------------------------------------------------------------------------
# minerva_cad_probe
# ---------------------------------------------------------------------------

func _test_probe_turns_a_ray_into_a_position_in_both_frames() -> void:
	# The stand-in aims the pane's centre pixel straight down the posed plate
	# axis at solid material, so the expected hit is the top of the stack.
	_panel.ray_local_target = Vector3(6.0, 0.0, 4.0)
	var hit: Dictionary = await PanelTools.handle(
			_panel, "minerva_cad_probe", {"px": [200, 150], "view": "top"})
	var position: Dictionary = hit.get("position_mm", {})
	var local: Array = position.get("local", [])
	check("probe: a ray onto the stack hits, in millimetres, in both frames",
			bool(hit.get("success", false)) and str(hit.get("units", "")) == "mm"
				and bool(hit.get("hit", false))
				and (position.get("world", []) as Array).size() == 3 and local.size() == 3,
			"reply=%s" % str(hit))
	check("probe: the local hit is the top face of the upper plate",
			local.size() == 3 and absf(float(local[1]) - 6.0) < 0.05,
			"local hit: %s" % str(local))
	check("probe: the hit names the reference and the node it landed on",
			str(hit.get("reference", "")) == "board"
				and str(hit.get("node", "")) == "PlateB",
			"reference='%s' node='%s'" % [
				str(hit.get("reference", "")), str(hit.get("node", ""))])

	var no_pixel: Dictionary = await PanelTools.handle(_panel, "minerva_cad_probe", {})
	check("probe: a call with no pixel is a named error",
			not bool(no_pixel.get("success", true))
				and str(no_pixel.get("error", "")).contains("px"),
			"reply=%s" % str(no_pixel))


# ---------------------------------------------------------------------------
# minerva_cad_view_overlay
# ---------------------------------------------------------------------------

func _test_view_overlay_reports_a_scale_per_pane() -> void:
	var reply: Dictionary = await PanelTools.handle(
			_panel, "minerva_cad_view_overlay", {"overlay": "grid+axes", "grid_mm": 5.0})
	var views: Array = reply.get("views", [])
	var first: Dictionary = views[0] if views.size() > 0 else {}
	check("view_overlay: the overlay is applied and each pane reports its own scale",
			bool(reply.get("success", false)) and str(reply.get("units", "")) == "mm"
				and str(reply.get("overlay", "")) == "grid+axes"
				and views.size() == 4
				and float(first.get("px_per_mm", 0.0)) > 0.0
				and int(first.get("width_px", 0)) == PIXEL_SIZE.x,
			"reply=%s" % str(reply))

	var bad: Dictionary = await PanelTools.handle(
			_panel, "minerva_cad_view_overlay", {"overlay": "sparkles"})
	check("view_overlay: an unknown overlay mode is refused by name",
			not bool(bad.get("success", true))
				and str(bad.get("error", "")).contains("overlay"),
			"reply=%s" % str(bad))


# ---------------------------------------------------------------------------
# The panel's side of the contract
# ---------------------------------------------------------------------------

## Everything PanelTools asks a panel for, and nothing else. The records, the
## features, the gauge and the colliders are real; only the scene the panel
## would own is stood in for.
class PanelStandIn extends Node:
	var record: Dictionary = {}
	## A second mounted reference, when the test needs one. Kept separate from
	## `record` so every existing assertion still runs against one reference.
	var extra: Dictionary = {}
	## Bumped whenever a test changes the geometry the colliders stand for.
	var digest: String = "verbs|v1"
	## While on, the digest changes every frame: a document being edited
	## faster than any verb can finish.
	var churn: bool = false
	var features: RefCounted = null
	var gauge: Node = null
	var pose: Transform3D = Transform3D.IDENTITY
	## Where the stand-in's pick ray is aimed, in the reference's local frame.
	var ray_local_target: Vector3 = Vector3.ZERO
	var overlay_mode: String = "none"

	func get_reference_state() -> Array:
		return [record] if extra.is_empty() else [record, extra]

	func get_reference_status() -> Array:
		return get_reference_state()

	func get_reference_digest() -> String:
		return digest

	func _process(_delta: float) -> void:
		if churn:
			digest = "verbs|churn-%d" % Engine.get_process_frames()

	func get_mesh_features() -> RefCounted:
		return features

	func get_mesh_gauge() -> Node:
		return gauge

	## The same composition CADPanel does: the pose onto the already-converted
	## part transform, so the gauge works entirely in world millimetres.
	func ensure_gauge_built() -> int:
		var bodies: Array = []
		for record_entry in get_reference_state():
			var mounted: Dictionary = record_entry
			var record_pose: Transform3D = mounted.get("pose", Transform3D.IDENTITY)
			var reference_name := str(mounted.get("name", ""))
			for entry in mounted.get("parts", []):
				var part: Dictionary = entry
				bodies.append({
					"mesh": part.get("mesh", null),
					"transform": record_pose
						* (part.get("transform", Transform3D.IDENTITY) as Transform3D),
					"node": "%s/%s" % [reference_name,
						str(part.get("node_path", part.get("node", "")))],
					"reference": reference_name,
				})
		return int(gauge.call("build", bodies, digest))

	func view_unavailable_reason(_view: String) -> String:
		return ""

	## A ray straight down the posed plate axis at a chosen local point. The
	## verb only needs a segment; producing it from a camera would test the
	## camera, not the verb.
	func get_pick_ray(_view: String, _pixel: Vector2) -> Dictionary:
		var record_pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var axis: Vector3 = (record_pose.basis * Vector3.UP).normalized()
		var target: Vector3 = record_pose * ray_local_target
		return {
			"from": target + axis * 50.0,
			"to": target - axis * 50.0,
			"width_px": PIXEL_SIZE.x,
			"height_px": PIXEL_SIZE.y,
		}

	func get_view_metrics(view: String) -> Dictionary:
		return {
			"view": view,
			"width_px": PIXEL_SIZE.x,
			"height_px": PIXEL_SIZE.y,
			"projection": "orthographic",
			"px_per_mm": 4.0,
			"origin_px": [200.0, 150.0],
		}

	func set_measurement_overlay(mode: String, grid_mm: float) -> Dictionary:
		overlay_mode = mode
		return {"mode": mode, "grid_mm": grid_mm, "lines": 24}


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

## One plate with both drills through it. Built with runtime CSG and baked, so
## no mesh binary is checked in and the geometry is the numbers above.
func _bake_plate() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Plate"
	var box := CSGBox3D.new()
	box.size = PLATE
	combiner.add_child(box)
	for xz in HOLE_XZ:
		var cutter := CSGCylinder3D.new()
		cutter.operation = CSGShape3D.OPERATION_SUBTRACTION
		cutter.radius = HOLE_DIA * 0.5
		cutter.height = PLATE.y * 4.0
		cutter.sides = FACETS
		cutter.smooth_faces = false
		cutter.position = Vector3(float((xz as Vector2).x), 0.0, float((xz as Vector2).y))
		combiner.add_child(cutter)
	return await _bake(combiner)


## The boss, centred on its own origin so the part transform places it.
func _bake_boss() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Boss"
	var post := CSGCylinder3D.new()
	post.radius = BOSS_DIA * 0.5
	post.height = BOSS_HEIGHT
	post.sides = FACETS
	post.smooth_faces = false
	combiner.add_child(post)
	return await _bake(combiner)


## A 2 mm square bar, long enough to run right through the stack. Narrower
## than the 3.2 mm drill, so it never touches the board — it only fills the
## middle of the hole, which is exactly where a gauge searches.
func _bake_plug() -> ArrayMesh:
	var combiner := CSGCombiner3D.new()
	combiner.name = "Plug"
	var bar := CSGBox3D.new()
	bar.size = Vector3(2.0, 20.0, 2.0)
	combiner.add_child(bar)
	return await _bake(combiner)


## CSG needs to be in the tree and processed once before it has geometry.
func _bake(combiner: CSGCombiner3D) -> ArrayMesh:
	root.add_child(combiner)
	await process_frame
	var baked: ArrayMesh = combiner.bake_static_mesh()
	combiner.queue_free()
	return baked


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
