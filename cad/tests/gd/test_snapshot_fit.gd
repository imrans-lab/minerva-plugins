extends SceneTree
## The picture is framed on the part, and the owner's view does not move.
##
## THE DEFECT. Every evaluation auto-frames each pane at 2.5x the solid's
## bounding-SPHERE radius (mesh_display._auto_frame), which for a tall thin
## body puts the camera far enough back that it fills about a fifth of the
## frame — and the owner then orbits it wherever they like. A vision model
## handed that snapshot is reading a part a few dozen pixels across.
##
## THE FIX under test is fit_capture.gd: a camera of its own, put where the
## requested box fills the frame, in an offscreen viewport, so the pane's
## camera never moves.
##
## THE ORACLE IS THE PROJECTION, NOT THE PIXELS. Headless draws no frames at
## all (test_snapshot_capture.gd shows the same), so there is no rasteriser to
## measure a silhouette in. What decides whether the framing is right is where
## the box's eight corners LAND, and Camera3D.unproject_position answers that
## exactly, using Godot's own projection matrix — the same matrix the renderer
## would use. A framing that is wrong about the fov axis, about the aspect, or
## about the box's extent along a camera axis moves those corners, and this
## measures them. The same measurement taken through the pane's own
## auto-framed camera is what the fitted one is compared against, so the suite
## shows the defect as well as the fix.
##
## AND THE PANE IS LEFT ALONE. The whole verb is run against the live panel;
## it refuses (headless never draws the offscreen frame) and the iso pane's
## camera is compared field by field with what it was before the call. Moving
## the pane camera and putting it back would pass a transform check by luck
## and still be wrong — it would invalidate the outline cache in
## ortho_silhouette.gd, which is keyed on exactly that transform — so the
## capture is built to never touch it, and the comparison is of the whole
## camera, not only its position.
##
## Run:
##   cd <minerva>/src && godot --headless -s res://../../minerva-plugins/cad/tests/gd/test_snapshot_fit.gd

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const GRID := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
const _FitCapture: Script = preload("res://../../minerva-plugins/cad/ui/scripts/fit_capture.gd")

## The rev-3 enclosure body the report was made about: 98 x 177 mm and 25 mm
## deep, sitting on the origin plane.
const BODY_MIN := Vector3(-49.0, -88.5, 0.0)
const BODY_SIZE := Vector3(98.0, 177.0, 25.0)

## What a fitted capture must fill of the axis it binds on. The margin is 5%
## per side of that axis, so 1/1.05 ≈ 0.952 is the target and this is the
## floor under it.
const MIN_BINDING_FILL := 0.90
## What the pane's own auto-framed camera leaves the body filling. The frame
## it picks is 2.5x the bounding SPHERE radius, which for a body far from
## cubic is most of the frame spent on air; this is the ceiling under it.
const MAX_UNFITTED_FILL := 0.55

var _pass: int = 0
var _fail: int = 0


class _EditorStub extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== CAD Snapshot Fit Test (framed on the part, pane untouched) ===\n")
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

	# The scene, pushed the way an evaluation pushes it: update_mesh auto-frames
	# each pane, so the pane cameras end up exactly where the owner finds them.
	var body := AABB(BODY_MIN, BODY_SIZE)
	var mesh_data := _box_mesh(body)
	for slot in ["TopView", "FrontView", "RightView", "IsoView"]:
		var mesh_root: Node = panel.get_node_or_null("%s/%s/SubViewport/MeshRoot" % [GRID, slot])
		if mesh_root != null:
			mesh_root.call("update_mesh", mesh_data, [])
	panel._last_mesh_data = mesh_data
	await process_frame

	var iso: Camera3D = panel.get_view_camera("iso")
	var iso_viewport: SubViewport = panel.get_node("%s/IsoView/SubViewport" % GRID)
	var pane_size := Vector2(iso_viewport.size)
	check("fixture: the iso pane holds a perspective camera over a %.0f x %.0f mm "
			% [BODY_SIZE.x, BODY_SIZE.y]
			+ "body, in a %.0f x %.0f pane" % [pane_size.x, pane_size.y],
			iso != null and iso.projection == Camera3D.PROJECTION_PERSPECTIVE
				and pane_size.x > 0.0 and pane_size.y > 0.0
				and _FitCapture.resolve_box(panel, "solid").get("box", AABB()) == body,
			"camera %s, pane %s" % [str(iso), str(pane_size)])
	if iso == null:
		return

	# ── The defect, measured ──────────────────────────────────────────────
	var unfitted := _fill(iso, body)
	check("the pane's own auto-framed camera leaves the body filling under "
			+ "%d%% of either axis — 2.5x the bounding-sphere radius is most "
			% int(MAX_UNFITTED_FILL * 100.0)
			+ "of the frame spent on air",
			maxf(unfitted.x, unfitted.y) < MAX_UNFITTED_FILL,
			"filled %.3f x %.3f of the pane" % [unfitted.x, unfitted.y])

	# ── The fix, measured the same way ────────────────────────────────────
	var fitted_rig := _rig(iso, Vector2i(400, 300), Camera3D.PROJECTION_PERSPECTIVE)
	var fitted: Camera3D = fitted_rig[1]
	_FitCapture.frame(fitted, body, Vector2(400.0, 300.0), 0.05)
	var filled := _fill(fitted, body)
	check("fit='solid' fills at least %d%% of the axis it binds on, in a "
			% int(MIN_BINDING_FILL * 100.0)
			+ "perspective pane",
			maxf(filled.x, filled.y) >= MIN_BINDING_FILL,
			"filled %.3f x %.3f" % [filled.x, filled.y])
	check("and nothing is cut off: every corner of the box projects inside the "
			+ "frame, so the 5% margin is air and not overshoot",
			_inside(fitted, body) and filled.x <= 1.0 and filled.y <= 1.0,
			"filled %.3f x %.3f, corners inside = %s"
				% [filled.x, filled.y, str(_inside(fitted, body))])

	# The same box under an ORTHOGRAPHIC camera: `size` is the vertical extent
	# under KEEP_HEIGHT and the horizontal one under KEEP_WIDTH, and framing to
	# the wrong one is a picture with the part half out of it.
	var ortho_rig := _rig(iso, Vector2i(400, 300), Camera3D.PROJECTION_ORTHOGONAL)
	var ortho: Camera3D = ortho_rig[1]
	_FitCapture.frame(ortho, body, Vector2(400.0, 300.0), 0.05)
	var ortho_filled := _fill(ortho, body)
	check("an orthographic camera is framed to the same rule and clips nothing",
			maxf(ortho_filled.x, ortho_filled.y) >= MIN_BINDING_FILL
				and _inside(ortho, body),
			"filled %.3f x %.3f, corners inside = %s"
				% [ortho_filled.x, ortho_filled.y, str(_inside(ortho, body))])

	_free_rig(fitted_rig)
	_free_rig(ortho_rig)

	# ── What `fit` may name ───────────────────────────────────────────────
	var corners: Array = [[10.0, -4.0, 2.0], [-6.0, 8.0, -3.0]]
	var boxed: Dictionary = _FitCapture.resolve_box(panel, corners)
	check("fit as two corners is a box whichever order they are given in",
			boxed.get("box", AABB()) == AABB(Vector3(-6.0, -4.0, -3.0),
				Vector3(16.0, 12.0, 5.0)),
			str(boxed))
	var missing: Dictionary = _FitCapture.resolve_box(panel, "reference:no_such_part")
	check("fit on a reference that is not mounted is refused, and the refusal "
			+ "names what IS mounted rather than leaving the caller guessing",
			missing.has("error") and str(missing["error"]).contains("no_such_part")
				and str(missing["error"]).contains("mounted"),
			str(missing))
	var nonsense: Dictionary = _FitCapture.resolve_box(panel, "the big one")
	check("a fit that is neither 'solid', a reference nor a box is refused with "
			+ "the three forms spelled out",
			nonsense.has("error") and str(nonsense["error"]).contains("solid")
				and str(nonsense["error"]).contains("reference:"),
			str(nonsense))

	# ── An ortho pane is refused, not answered with a different picture ───
	var top_refusal: Dictionary = await _FitCapture.snapshot(panel,
		{"view": "top", "fit": "solid"})
	check("a pane looking from a direction is refused: its picture is the "
			+ "outline drawn in the pane, which an offscreen render of the "
			+ "world does not have",
			not bool(top_refusal.get("success", false))
				and str(top_refusal.get("error", "")).contains("Perspective"),
			str(top_refusal))

	# ── The pane the owner is looking at is untouched ─────────────────────
	var before_transform := iso.global_transform
	var before_fov := iso.fov
	var before_size := iso.size
	var before_near := iso.near
	var before_far := iso.far
	var reply: Dictionary = await _FitCapture.snapshot(panel,
		{"view": "iso", "fit": "solid"})
	check("the iso pane's camera is the SAME camera after a fitted capture — "
			+ "transform, fov, ortho size and both clip planes — so neither the "
			+ "owner's view nor the outline cache keyed on that transform moves",
			iso.global_transform == before_transform and iso.fov == before_fov
				and iso.size == before_size and iso.near == before_near
				and iso.far == before_far,
			"was %s / fov %.3f, now %s / fov %.3f"
				% [str(before_transform), before_fov,
					str(iso.global_transform), iso.fov])
	check("and with no frame drawn anywhere (headless, or an occluded window) "
			+ "it says so instead of waiting for one that never comes",
			not bool(reply.get("success", false))
				and str(reply.get("error", "")).contains("no frame was drawn"),
			str(reply))

	# The capture's offscreen viewport is queue_free()d; let that flush before
	# the panel it hangs under is freed outright.
	await process_frame
	panel.free()
	await process_frame
	await process_frame


# ---------------------------------------------------------------------------
# Measuring a framing
# ---------------------------------------------------------------------------

## What fraction of each axis of `camera`'s viewport the box's projected
## bounds span.
func _fill(camera: Camera3D, box: AABB) -> Vector2:
	var points := _projected(camera, box)
	if points.is_empty():
		return Vector2.ZERO
	var low := points[0]
	var high := points[0]
	for point in points:
		low = low.min(point)
		high = high.max(point)
	var frame_size := camera.get_viewport().get_visible_rect().size
	if frame_size.x <= 0.0 or frame_size.y <= 0.0:
		return Vector2.ZERO
	return Vector2((high.x - low.x) / frame_size.x, (high.y - low.y) / frame_size.y)


## Whether every corner lands inside the frame.
func _inside(camera: Camera3D, box: AABB) -> bool:
	var frame_rect := camera.get_viewport().get_visible_rect()
	for point in _projected(camera, box):
		if not frame_rect.has_point(point):
			return false
	return true


func _projected(camera: Camera3D, box: AABB) -> PackedVector2Array:
	var points := PackedVector2Array()
	for corner in range(8):
		var world := box.get_endpoint(corner)
		if camera.is_position_behind(world):
			continue
		points.append(camera.unproject_position(world))
	return points


## An offscreen viewport with a camera pointing the way `source` points — the
## same starting state fit_capture builds before it frames.
func _rig(source: Camera3D, size: Vector2i, projection: int) -> Array:
	var viewport := SubViewport.new()
	viewport.size = size
	var camera := Camera3D.new()
	camera.projection = projection
	camera.fov = source.fov
	camera.keep_aspect = source.keep_aspect
	viewport.add_child(camera)
	root.add_child(viewport)
	camera.global_transform = Transform3D(source.global_transform.basis, Vector3.ZERO)
	camera.current = true
	return [viewport, camera]


func _free_rig(rig: Array) -> void:
	(rig[0] as SubViewport).free()


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

func _panel() -> Node:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	if packed == null:
		return null
	var panel: Node = packed.instantiate()
	root.add_child(panel)
	var editor := _EditorStub.new()
	editor.tab_title = "snapshot_fit"
	panel._on_panel_loaded({
		"plugin_id": "cad",
		"panel_name": "cad_panel",
		"host_api_version": "1",
		"editor": editor,
	})
	return panel


## The eight corners of `box` as a closed-enough mesh in the panel's own
## {vertices, faces} shape: the bounds are what every reader here wants.
func _box_mesh(box: AABB) -> Dictionary:
	var vertices: Array = []
	for corner in range(8):
		var point := box.get_endpoint(corner)
		vertices.append([point.x, point.y, point.z])
	var faces: Array = [
		[0, 1, 3], [0, 3, 2], [4, 6, 7], [4, 7, 5],
		[0, 4, 5], [0, 5, 1], [2, 3, 7], [2, 7, 6],
		[0, 2, 6], [0, 6, 4], [1, 5, 7], [1, 7, 3],
	]
	return {"vertices": vertices, "faces": faces}
