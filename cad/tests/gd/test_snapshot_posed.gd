extends SceneTree
## Can the agent stand where it needs to stand, and cut the part open?
##
## THE DEFECT. Every image verb read the panes as the owner left them:
## minerva_cad_snapshot returns the last drawn frame of one of four fixed panes
## and minerva_cad_snapshot_fit reframes one of those panes without turning it.
## No verb took a yaw, a pitch, a direction or a target — so nothing could look
## UNDER a part, and three floorless STL exports shipped, because a missing
## floor is visible only from below.
##
## THE FIX under test is scripts/posed_capture.gd (minerva_cad_snapshot_posed):
## a camera placed from a stated pose in a private world of mirrored geometry,
## with an optional section plane that discards the solid's fragments on one
## side of it.
##
## THE ORACLE IS A CPU RASTERISER, and it has to be. Headless draws no frames
## (test_snapshot_capture.gd and test_snapshot_fit.gd both live with that), so
## there is no GPU picture to measure. What the GPU would do to this fixture is
## not in doubt, though: for each pixel a ray, the nearest triangle it meets,
## and — with a section — the nearest one on the KEPT side of the plane, which
## is exactly what the shader's `discard` leaves behind. So the suite drives
## the PRODUCTION pose and section code (resolve_pose, place_camera,
## resolve_section) and rasterises what those put in front of the camera. A
## pose that does not turn the camera, or a plane resolved to the wrong side,
## moves these pixels.
##
## WHAT A SECTION CANNOT DO, AND SO IS NOT ASSERTED. "A pixel that is
## background without the section becomes solid-coloured with it" cannot
## happen: a clip plane only REMOVES material, so a ray that
## met nothing still meets nothing. What a section really exposes is a
## different SURFACE at a pixel that was already solid — the enclosed cavity in
## this fixture, which no unsectioned view of an opaque solid can show at all.
## That is what is measured below, along with the material the cut removed.
##
## Run:
##   cd <minerva>/src && godot --headless -s res://../../minerva-plugins/cad/tests/gd/test_snapshot_posed.gd

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const GRID := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
const _PosedCapture: Script = preload("res://../../minerva-plugins/cad/ui/scripts/posed_capture.gd")

## The fixture: a 40 x 40 x 20 mm block with a 16 x 16 x 8 mm cavity sealed
## inside it, standing on a 24 x 24 x 6 mm foot. The cavity is the interior
## feature — invisible from every direction until something cuts the block
## open. The foot is the UNDERSIDE feature: the whole of it is hidden from
## above and from every elevation, which is the shape of the defect that let
## three floorless exports through.
const BLOCK := AABB(Vector3(-20.0, -20.0, 0.0), Vector3(40.0, 40.0, 20.0))
const CAVITY := AABB(Vector3(-8.0, -8.0, 6.0), Vector3(16.0, 16.0, 8.0))
const FOOT := AABB(Vector3(-12.0, -12.0, -6.0), Vector3(24.0, 24.0, 6.0))
const SURFACE_OUTER := 0
const SURFACE_CAVITY := 1
const SURFACE_FOOT := 2

## A pixel is the surface in front of it AND how far away it is, at quarter-
## millimetre steps: a picture in which a face moved towards the camera is a
## different picture, and comparing surface ids alone would call two mirrored
## views of a symmetric block identical when the shading would not be.
const DEPTH_STEPS_PER_MM := 4
const DEPTH_RANGE := 10000

## The rasterised frame. Small on purpose: the oracle is about which surface is
## in front of which pixel, not about a pretty picture.
const FRAME_W := 48
const FRAME_H := 36

var _pass: int = 0
var _fail: int = 0


class _EditorStub extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== CAD Posed Snapshot Test (stand anywhere, cut it open) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s — %s" % [label, detail])


func _run() -> void:
	var panel := _panel()
	if panel == null:
		check("setup: the CAD panel instantiates", false, PANEL_SCENE_PATH)
		return
	panel._apply_width_class(&"lg")
	await process_frame
	await process_frame

	var mesh_data := _fixture_mesh()
	for slot in ["TopView", "FrontView", "RightView", "IsoView"]:
		var mesh_root: Node = panel.get_node_or_null("%s/%s/SubViewport/MeshRoot" % [GRID, slot])
		if mesh_root != null:
			mesh_root.call("update_mesh", mesh_data, [])
	panel._last_mesh_data = mesh_data
	await process_frame

	var triangles := _fixture_triangles()
	check("fixture: a %.0f mm block with a sealed cavity and an underside foot, "
			% BLOCK.size.x + "pushed to the panes",
			triangles.size() == 36 and panel.get_view_camera("iso") != null,
			"%d triangles" % triangles.size())

	# ── The pose is an ARGUMENT, and a missing one is not a default ───────
	var no_pose: Dictionary = _PosedCapture.resolve_pose({})
	check("a posed capture with no pose is refused, and the refusal names "
			+ "minerva_cad_snapshot_fit — answering from some default direction "
			+ "would be a picture the caller never chose",
			no_pose.has("error") and str(no_pose["error"]).contains("snapshot_fit"),
			str(no_pose))
	var bad_view: Dictionary = _PosedCapture.resolve_pose({"view": "underneath"})
	check("an unknown direction is refused with the directions there are",
			bad_view.has("error") and str(bad_view["error"]).contains("-z"),
			str(bad_view))
	var under: Dictionary = _PosedCapture.resolve_pose({"view": "-z"})
	check("view='-z' is a camera standing BELOW the part looking up — pitch "
			+ "-90 in the panes' own convention, not a look direction of -z",
			not under.has("error") and is_equal_approx(float(under["pitch_deg"]), -90.0)
				and _PosedCapture.pose_direction(0.0, -90.0).is_equal_approx(
					Vector3(0.0, 0.0, -1.0)),
			str(under))
	check("yaw is pinned, not just present: yaw 90 stands on +Y and yaw 0 on "
			+ "+X, so a sign flip in the spherical placement is a different "
			+ "picture and not a silent mirror",
			_PosedCapture.pose_direction(90.0, 0.0).is_equal_approx(
					Vector3(0.0, 1.0, 0.0))
				and _PosedCapture.pose_direction(0.0, 0.0).is_equal_approx(
					Vector3(1.0, 0.0, 0.0)),
			"yaw 90 -> %s, yaw 0 -> %s"
				% [str(_PosedCapture.pose_direction(90.0, 0.0)),
					str(_PosedCapture.pose_direction(0.0, 0.0))])
	var front: Dictionary = _PosedCapture.resolve_pose({"view": "front"})
	check("and the named views are pinned to the panes they are named after: "
			+ "'front' is the Front pane's own camera at -Y looking toward +Y",
			not front.has("error")
				and _PosedCapture.pose_direction(float(front["yaw_deg"]),
					float(front["pitch_deg"])).is_equal_approx(
					Vector3(0.0, -1.0, 0.0)),
			str(front))
	var mixed: Dictionary = _PosedCapture.resolve_pose(
		{"view": "iso", "pose": {"pitch_deg": -30.0}})
	check("view and pose together are 'iso, but from 30 degrees below': the "
			+ "named view sets the yaw, the explicit angle wins on the pitch",
			not mixed.has("error")
				and is_equal_approx(float(mixed["yaw_deg"]), -45.0)
				and is_equal_approx(float(mixed["pitch_deg"]), -30.0),
			str(mixed))

	# ── A pose is a DIFFERENT PICTURE, which a fifth fixed pane is not ────
	var rig := _rig()
	var frames: Dictionary = {}
	for named in ["+z", "-z", "iso"]:
		frames[named] = _render(rig, _PosedCapture.resolve_pose({"view": named}),
			triangles, null)
	check("looking from below ('-z') shows the foot and is not the same picture "
			+ "as looking from above ('+z') — the picture no pane could take, "
			+ "and the one a missing floor is only visible in",
			_differs(frames["-z"], frames["+z"]) > 0.2,
			"%.3f of pixels differ" % _differs(frames["-z"], frames["+z"]))
	check("and neither is the same picture as the iso angle",
			_differs(frames["-z"], frames["iso"]) > 0.2
				and _differs(frames["+z"], frames["iso"]) > 0.2,
			"-z/iso %.3f, +z/iso %.3f" % [_differs(frames["-z"], frames["iso"]),
				_differs(frames["+z"], frames["iso"])])

	# "The underside of the tail bay from 30 degrees" — the ask a fifth fixed
	# pane cannot answer. It must differ from every pane the panel HAS.
	var asked: Dictionary = _PosedCapture.resolve_pose(
		{"pose": {"yaw_deg": 210.0, "pitch_deg": -30.0}})
	var asked_frame := _render(rig, asked, triangles, null)
	var nearest := 1.0
	var worst := ""
	for view in ["top", "front", "right", "iso"]:
		var pane: Camera3D = panel.get_view_camera(view)
		if pane == null:
			continue
		var pane_frame := _rasterise(pane, triangles, null)
		var difference := _differs(asked_frame, pane_frame)
		if difference < nearest:
			nearest = difference
			worst = view
	check("yaw 210, pitch -30 — 'the underside from 30 degrees' — is a picture "
			+ "no fixed pane draws: it differs from all four of them",
			nearest > 0.15, "closest pane was %s at %.3f" % [worst, nearest])

	# ── The reply says where it stood, even when it cannot draw ───────────
	var reply: Dictionary = await _PosedCapture.snapshot(panel,
		{"pose": {"yaw_deg": 210.0, "pitch_deg": -30.0}, "fit": "solid"})
	var echo: Dictionary = reply.get("pose", {})
	check("the reply echoes the pose it used — the angles, where that put the "
			+ "camera and which way it looked — so the caller can reason about "
			+ "what it is seeing rather than guessing",
			echo.has("yaw_deg") and echo.has("camera_position_mm")
				and echo.has("look_direction")
				and is_equal_approx(float(echo.get("pitch_deg", 0.0)), -30.0)
				and float((echo.get("camera_position_mm", [0.0, 0.0, 0.0]) as Array)[2])
					< BLOCK.position.z,
			str(reply))
	check("and a headless build's refusal is about pixels, NOT about a pane "
			+ "having drawn no frame: this camera is not a pane's and does not "
			+ "inherit that refusal",
			not str(reply.get("error", "")).contains("no frame was drawn"),
			str(reply))

	# ── The section plane ────────────────────────────────────────────────
	check("section_plane with no axis is refused with the three keys spelled out",
			(_PosedCapture.resolve_section({"offset_mm": 10.0}) as Dictionary)
				.has("error"),
			str(_PosedCapture.resolve_section({"offset_mm": 10.0})))
	check("section_plane with no offset_mm is refused: an axis alone does not "
			+ "say where the cut is",
			(_PosedCapture.resolve_section({"axis": "z"}) as Dictionary).has("error"),
			str(_PosedCapture.resolve_section({"axis": "z"})))
	check("keep must be '+' or '-'",
			(_PosedCapture.resolve_section(
				{"axis": "z", "offset_mm": 10.0, "keep": "up"}) as Dictionary)
				.has("error"), "")
	var keep_plus: Dictionary = _PosedCapture.resolve_section(
		{"axis": "z", "offset_mm": 10.0, "keep": "+"})
	var keep_minus: Dictionary = _PosedCapture.resolve_section(
		{"axis": "z", "offset_mm": 10.0, "keep": "-"})
	check("the resolved plane always points at the half that is KEPT, so the "
			+ "shader has one rule: '+' keeps z above 10, '-' keeps z below it",
			(keep_plus["plane"] as Plane).is_point_over(Vector3(0.0, 0.0, 15.0))
				and not (keep_plus["plane"] as Plane).is_point_over(Vector3(0.0, 0.0, 5.0))
				and (keep_minus["plane"] as Plane).is_point_over(Vector3(0.0, 0.0, 5.0))
				and not (keep_minus["plane"] as Plane).is_point_over(Vector3(0.0, 0.0, 15.0)),
			"%s / %s" % [str(keep_plus), str(keep_minus)])

	# Cut the block in half at mid-height and look down into it.
	var above: Dictionary = _PosedCapture.resolve_pose({"view": "+z"})
	var section: Dictionary = _PosedCapture.resolve_section(
		{"axis": "z", "offset_mm": BLOCK.position.z + BLOCK.size.z * 0.5, "keep": "-"})
	var whole := _render(rig, above, triangles, null)
	var cut := _render(rig, above, triangles, section["plane"])
	check("a section at half height changes the picture",
			_differs(whole, cut) > 0.2,
			"%.3f of pixels differ" % _differs(whole, cut))
	var exposed := _exposed_surface(whole, cut, SURFACE_CAVITY)
	check("and what it exposes is the INTERIOR: pixels that showed the block's "
			+ "outer skin now show the sealed cavity's wall, which no view of "
			+ "an opaque solid can reach without a cut",
			exposed > 0.02, "%.3f of pixels became cavity" % exposed)
	check("the cut only removes material — no pixel goes from background to "
			+ "solid, which is what a clip plane can and cannot do",
			_gained(whole, cut) == 0, "%d pixels gained" % _gained(whole, cut))

	# The same plane kept the other way is the other half: what the cut
	# removed, and nothing that it left.
	var opposite := _render(rig, above, triangles,
		(_PosedCapture.resolve_section({"axis": "z",
			"offset_mm": BLOCK.position.z + BLOCK.size.z * 0.5,
			"keep": "+"}) as Dictionary)["plane"])
	check("keep='+' is the complementary half, not the same picture",
			_differs(cut, opposite) > 0.2,
			"%.3f of pixels differ" % _differs(cut, opposite))

	# ── What a section does to the OUTLINE, and what a forced frame is worth ──
	# Both are about the private world rather than about the pixels the
	# rasteriser above stands in for, so they are asked of the two production
	# helpers that decide them.
	var source := Node3D.new()
	root.add_child(source)
	var solid := MeshInstance3D.new()
	solid.mesh = BoxMesh.new()
	source.add_child(solid)
	var outline := MeshInstance3D.new()
	outline.name = "FeatureEdges"
	outline.mesh = BoxMesh.new()
	source.add_child(outline)
	await process_frame

	var whole_mirror := Node3D.new()
	root.add_child(whole_mirror)
	var mirrored_whole: int = _PosedCapture._mirror_into(source, whole_mirror,
		solid, {})
	var cut_mirror := Node3D.new()
	root.add_child(cut_mirror)
	var mirrored_cut: int = _PosedCapture._mirror_into(source, cut_mirror, solid,
		_PosedCapture.resolve_section({"axis": "z", "offset_mm": 0.0,
			"keep": "-"}) as Dictionary)
	check("the section is a fragment discard on the SOLID's material, so the "
			+ "feature-edge overlay — a separate line mesh the override never "
			+ "reaches — is left out of the mirrored world while a section is "
			+ "active, instead of drawing the discarded half's silhouette "
			+ "over the cut",
			mirrored_whole == 2 and mirrored_cut == 1,
			"whole = %d, cut = %d" % [mirrored_whole, mirrored_cut])
	whole_mirror.free()
	cut_mirror.free()
	source.free()

	var blank := Image.create_empty(64, 48, false, Image.FORMAT_RGBA8)
	blank.fill(Color(0.1, 0.1, 0.12, 1.0))
	var drawn_image := Image.create_empty(64, 48, false, Image.FORMAT_RGBA8)
	drawn_image.fill(Color(0.1, 0.1, 0.12, 1.0))
	drawn_image.set_pixel(32, 24, Color(1.0, 0.0, 0.0, 1.0))
	check("a render target that was allocated and never drawn into reads back "
			+ "as one flat colour, and is told from a real frame — the forced "
			+ "path replies drawn:false on the first rather than calling a "
			+ "picture of nothing a success",
			_PosedCapture._is_one_colour(blank)
				and not _PosedCapture._is_one_colour(drawn_image),
			"blank = %s, drawn = %s" % [
				str(_PosedCapture._is_one_colour(blank)),
				str(_PosedCapture._is_one_colour(drawn_image))])

	_free_rig(rig)
	await process_frame
	panel.free()
	await process_frame
	await process_frame


# ---------------------------------------------------------------------------
# The rasteriser
# ---------------------------------------------------------------------------

## Place a camera from `pose` the way the verb does, then rasterise it.
func _render(rig: Array, pose: Dictionary, triangles: Array,
		plane: Variant) -> PackedInt32Array:
	var camera: Camera3D = rig[1]
	_PosedCapture.place_camera(camera, _solid_box(), pose,
		Vector2(FRAME_W, FRAME_H), 0.05)
	return _rasterise(camera, triangles, plane)


## The surface in front of each pixel: SURFACE_OUTER, SURFACE_CAVITY, or -1 for
## background. With a `plane`, a hit on the discarded side is not a hit —
## the fragment shader's `discard`, done with rays.
func _rasterise(camera: Camera3D, triangles: Array,
		plane: Variant) -> PackedInt32Array:
	var frame := PackedInt32Array()
	frame.resize(FRAME_W * FRAME_H)
	var basis := camera.global_transform.basis
	var forward := -basis.z.normalized()
	var aspect := float(FRAME_W) / float(FRAME_H)
	var tangent := tan(deg_to_rad(camera.fov) * 0.5)
	var half_height := camera.size * 0.5
	for y in range(FRAME_H):
		for x in range(FRAME_W):
			var ndc_x := 2.0 * (float(x) + 0.5) / float(FRAME_W) - 1.0
			var ndc_y := 1.0 - 2.0 * (float(y) + 0.5) / float(FRAME_H)
			var origin := camera.global_position
			var direction := forward
			if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
				origin += basis.x.normalized() * ndc_x * half_height * aspect \
					+ basis.y.normalized() * ndc_y * half_height
			else:
				direction = (basis * Vector3(ndc_x * tangent * aspect,
					ndc_y * tangent, -1.0)).normalized()
			frame[y * FRAME_W + x] = _nearest(origin, direction, triangles, plane)
	return frame


## The surface the ray meets first and how far away it is, packed into one
## pixel value, or -1 for background.
func _nearest(origin: Vector3, direction: Vector3, triangles: Array,
		plane: Variant) -> int:
	var best := INF
	var surface := -1
	for entry in triangles:
		var triangle: Array = entry
		var hit: Variant = Geometry3D.ray_intersects_triangle(origin, direction,
			triangle[0], triangle[1], triangle[2])
		if hit == null:
			continue
		var point: Vector3 = hit
		if plane != null and not (plane as Plane).is_point_over(point):
			continue
		var distance := origin.distance_to(point)
		if distance < best:
			best = distance
			surface = int(triangle[3])
	if surface < 0:
		return -1
	return surface * DEPTH_RANGE + clampi(
		int(round(best * DEPTH_STEPS_PER_MM)), 0, DEPTH_RANGE - 1)


## The surface a packed pixel shows, or -1.
func _surface_of(pixel: int) -> int:
	return -1 if pixel < 0 else pixel / DEPTH_RANGE


## Fraction of pixels that are not the same in both frames.
func _differs(left: PackedInt32Array, right: PackedInt32Array) -> float:
	var changed := 0
	for index in range(left.size()):
		if left[index] != right[index]:
			changed += 1
	return float(changed) / float(maxi(left.size(), 1))


## Fraction of pixels showing `surface` in `cut` that showed something else in
## `whole` — the interior the section exposed.
func _exposed_surface(whole: PackedInt32Array, cut: PackedInt32Array,
		surface: int) -> float:
	var exposed := 0
	for index in range(whole.size()):
		if _surface_of(cut[index]) == surface and _surface_of(whole[index]) != surface:
			exposed += 1
	return float(exposed) / float(maxi(whole.size(), 1))


## Pixels that were background and became solid. A clip plane cannot do this.
func _gained(whole: PackedInt32Array, cut: PackedInt32Array) -> int:
	var gained := 0
	for index in range(whole.size()):
		if whole[index] < 0 and cut[index] >= 0:
			gained += 1
	return gained


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

## An offscreen viewport with a perspective camera, the same starting state
## posed_capture builds before it places one.
func _rig() -> Array:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(FRAME_W, FRAME_H)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = _PosedCapture.DEFAULT_FOV_DEG
	viewport.add_child(camera)
	root.add_child(viewport)
	camera.current = true
	return [viewport, camera]


func _free_rig(rig: Array) -> void:
	(rig[0] as SubViewport).free()


## The block and its sealed cavity as [a, b, c, surface_id] triangles.
func _fixture_triangles() -> Array:
	var triangles: Array = []
	triangles.append_array(_box_triangles(BLOCK, SURFACE_OUTER))
	triangles.append_array(_box_triangles(CAVITY, SURFACE_CAVITY))
	triangles.append_array(_box_triangles(FOOT, SURFACE_FOOT))
	return triangles


## Everything there is to frame on.
func _solid_box() -> AABB:
	return BLOCK.merge(FOOT)


func _box_triangles(box: AABB, surface: int) -> Array:
	var corners: Array = []
	for index in range(8):
		corners.append(box.get_endpoint(index))
	var faces: Array = [
		[0, 1, 3], [0, 3, 2], [4, 6, 7], [4, 7, 5],
		[0, 4, 5], [0, 5, 1], [2, 3, 7], [2, 7, 6],
		[0, 2, 6], [0, 6, 4], [1, 5, 7], [1, 7, 3],
	]
	var triangles: Array = []
	for face in faces:
		triangles.append([corners[face[0]], corners[face[1]], corners[face[2]],
			surface])
	return triangles


## The same geometry in the panel's own {vertices, faces} shape.
func _fixture_mesh() -> Dictionary:
	var vertices: Array = []
	var faces: Array = []
	for box in [BLOCK, CAVITY, FOOT]:
		var base: int = vertices.size()
		for index in range(8):
			var point: Vector3 = (box as AABB).get_endpoint(index)
			vertices.append([point.x, point.y, point.z])
		for face in [[0, 1, 3], [0, 3, 2], [4, 6, 7], [4, 7, 5],
				[0, 4, 5], [0, 5, 1], [2, 3, 7], [2, 7, 6],
				[0, 2, 6], [0, 6, 4], [1, 5, 7], [1, 7, 3]]:
			faces.append([base + face[0], base + face[1], base + face[2]])
	return {"vertices": vertices, "faces": faces}


func _panel() -> Node:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	if packed == null:
		return null
	var panel: Node = packed.instantiate()
	root.add_child(panel)
	var editor := _EditorStub.new()
	editor.tab_title = "snapshot_posed"
	panel._on_panel_loaded({
		"plugin_id": "cad",
		"panel_name": "cad_panel",
		"host_api_version": "1",
		"editor": editor,
	})
	return panel
