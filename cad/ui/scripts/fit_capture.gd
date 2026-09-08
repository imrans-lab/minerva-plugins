extends RefCounted
## A picture FRAMED ON SOMETHING, rather than on wherever the pane's camera
## happens to be sitting.
##
## minerva_cad_snapshot captures the pane as the owner has it, and the owner
## has it pulled back far enough to work in: a 98 x 177 mm body fills about a
## fifth of the frame, and a grille hole is two pixels. A vision model reading
## that picture is reading nothing. The camera COULD be flown in first, but
## that is a second round trip and it moves what the owner is looking at.
##
## So this verb renders the same scene from a camera of its own, put where the
## requested box fills the frame, and throws that camera away afterwards. The
## pane's camera is never touched, which is what keeps two things true at once:
## the owner's view does not jump, and the ortho outline cache in
## ortho_silhouette.gd — keyed on the pane camera's transform — is not
## invalidated by a capture that had nothing to do with it.
##
## Each live pane owns its World3D because it mounts its own mesh copy.
## The offscreen viewport shares only the requested pane's world, including
## its references and lighting; other panes and documents remain isolated.
##
## WHAT IT CANNOT DO. A pane showing a DIRECTION (Top/Front/Right/…) draws its
## picture as a 2-D outline in a Control inside the pane, over a blueprint fill
## that hides the shaded mesh. That overlay belongs to the pane's own canvas,
## not to the world, so an offscreen render of an ortho pane would be the
## shaded mesh and not the drawing the owner sees. Such a pane is refused with
## the reason rather than answered with a different picture under its name.
##
## Off-tree note: no class_name — preloaded by relative path from panel_tools.
##
## Consumers: ui/panel_tools.gd (minerva_cad_snapshot_fit).

## Bounds of the evaluated solid, read the one way the panel reads them.
const _CadNote: Script = preload("cad_note.gd")

## Fraction of the frame left as air around the fitted box, per side of the
## binding axis. 5% keeps the silhouette off the edge without wasting pixels.
const DEFAULT_MARGIN: float = 0.05
const MAX_MARGIN: float = 0.5
## Long edge of the returned PNG, matching minerva_cad_snapshot's own default.
const DEFAULT_MAX_EDGE: int = 1024
## Where a capture goes when the caller names no path.
const DEFAULT_DIR: String = "user://cad_snapshots"
## Main-loop iterations spent waiting for the offscreen viewport to be drawn
## before the verb gives up and says why. Nothing is drawn at all while the
## window is occluded or minimised, or in a headless run: waiting on
## RenderingServer.frame_post_draw there is waiting forever.
const MAX_WAIT_ITERATIONS: int = 120
## Drawn frames the offscreen viewport needs before its target holds this
## scene: the frame in flight when it was mounted may not include it.
const DRAWN_FRAMES_NEEDED: int = 2


# ---------------------------------------------------------------------------
# The verb
# ---------------------------------------------------------------------------

## minerva_cad_snapshot_fit — the named pane, framed on `fit`.
static func snapshot(panel, args: Dictionary) -> Dictionary:
	var view := str(args.get("view", "active")).strip_edges().to_lower()
	if view.is_empty():
		view = "active"
	var refusal: String = panel.view_unavailable_reason(view)
	if not refusal.is_empty():
		return _err(refusal)

	var source: Camera3D = panel.get_view_camera(view)
	if source == null:
		return _err("no camera for view '%s'" % view)
	# The projection is the pane's own answer to "am I a drawing or a render",
	# and unlike the preset name it is right for view="active" in either layout.
	if source.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return _err(
			"pane '%s' is looking from %s, and a pane showing a direction draws "
			% [view, str(panel.get_pane_preset(view))]
			+ "its outline in the pane itself, not in the world — an offscreen "
			+ "render of it would be the shaded mesh and not the drawing you "
			+ "see. Fit a pane on Perspective, or take an unfitted "
			+ "minerva_cad_snapshot of this one."
		)

	var box_reply := resolve_box(panel, args.get("fit", "solid"))
	if box_reply.has("error"):
		return _err(str(box_reply["error"]))
	var box: AABB = box_reply["box"]

	var margin := clampf(float(args.get("margin", DEFAULT_MARGIN)), 0.0, MAX_MARGIN)
	var image_reply := await _render(panel, source, box, margin)
	if image_reply.has("error"):
		return _err(str(image_reply["error"]))
	var image: Image = image_reply["image"]

	var max_edge := int(args.get("max_edge", DEFAULT_MAX_EDGE))
	if max_edge <= 0:
		max_edge = DEFAULT_MAX_EDGE
	image = downscale(image, max_edge)

	var path_reply := write_png(image, str(args.get("output_path", "")),
		"fit_%s" % view)
	if path_reply.has("error"):
		return _err(str(path_reply["error"]))

	var payload := {
		"units": "mm",
		"view": view,
		"view_preset": str(panel.get_pane_preset(view)).to_lower(),
		"fit": args.get("fit", "solid"),
		"fit_box_mm": [_vec(box.position), _vec(box.end)],
		"margin": margin,
		"width": image.get_width(),
		"height": image.get_height(),
		"content_type": "image/png",
	}
	payload.merge(path_reply)
	if bool(args.get("return_base64", false)):
		payload["image_base64"] = Marshalls.raw_to_base64(image.save_png_to_buffer())
	return _ok(payload)


# ---------------------------------------------------------------------------
# What to frame on
# ---------------------------------------------------------------------------

## The world box a `fit` argument names: {box: AABB} or {error: String}.
##
## "solid"                the evaluated solid's bounds.
## "reference:<name>"     one mounted reference's world bounds.
## [[x0,y0,z0],[x1,y1,z1]]  two opposite corners, in millimetres, either order.
static func resolve_box(panel, fit: Variant) -> Dictionary:
	if fit is Array:
		var corners: Array = fit
		if corners.size() != 2:
			return {"error": "fit as a box is [[x0,y0,z0], [x1,y1,z1]] in mm"}
		var lo_reply := _corner(corners[0])
		if lo_reply.has("error"):
			return lo_reply
		var hi_reply := _corner(corners[1])
		if hi_reply.has("error"):
			return hi_reply
		var lo: Vector3 = lo_reply["point"]
		var hi: Vector3 = hi_reply["point"]
		var box := AABB(lo.min(hi), (hi - lo).abs())
		if box.size.length() <= 0.0:
			return {"error": "fit box has no extent — the two corners are the same point"}
		return {"box": box}

	var spec := str(fit).strip_edges()
	if spec.is_empty() or spec == "solid":
		var solid: AABB = _CadNote.solid_bounds(panel)
		if solid.size.length() <= 0.0:
			return {"error": "fit='solid' but the document has evaluated no solid yet"}
		return {"box": solid}

	if spec.begins_with("reference:"):
		var wanted := spec.substr("reference:".length()).strip_edges()
		var names: Array = []
		for entry in _records(panel):
			var record: Dictionary = entry
			var name := str(record.get("name", ""))
			names.append(name)
			if name == wanted:
				var bounds: AABB = record.get("world_aabb", AABB())
				if bounds.size.length() <= 0.0:
					return {"error": "reference '%s' is mounted but bounds nothing" % wanted}
				return {"box": bounds}
		return {"error": "no mounted reference named '%s' (mounted: %s)"
			% [wanted, str(names)]}

	return {"error": "fit must be 'solid', 'reference:<name>' or "
		+ "[[x0,y0,z0], [x1,y1,z1]]; got '%s'" % spec}


# ---------------------------------------------------------------------------
# Where the camera has to stand
# ---------------------------------------------------------------------------

## Put `camera` where `box` fills a `viewport_size` frame with `margin` air on
## the binding axis, WITHOUT turning it: the picture is taken from the same
## direction the pane is looking, only closer.
##
## PERSPECTIVE IS FITTED ON THE PROJECTED CORNERS, NOT THE BOX. A camera aimed
## at the centre of a deep box magnifies the near corner and shrinks the far
## one, so the silhouette sits off-centre in the frame and the near corner
## binds while most of the other side is air — a box as deep as it is wide
## fills barely half the frame that way. The camera is therefore also SLID
## across its own right/up axes (never turned) until the projected silhouette
## is centred, and only then pulled in until it binds.
##
## The box's half-extent along a camera axis is the sum of its own half-sizes
## projected onto that axis, which is what makes this correct for a camera
## looking at the box from any angle and not only down an axis.
##
## Godot's fov (and a camera's ortho `size`) is the VERTICAL angle under the
## default KEEP_HEIGHT and the horizontal one under KEEP_WIDTH; both are
## handled, because getting it wrong would frame a wide pane to the wrong axis.
static func frame(camera: Camera3D, box: AABB, viewport_size: Vector2, margin: float) -> void:
	if camera == null or viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var basis := camera.global_transform.basis
	var right := basis.x.normalized()
	var up := basis.y.normalized()
	var forward := -basis.z.normalized()
	var half := box.size * 0.5
	var half_width := _extent_along(half, right)
	var half_height := _extent_along(half, up)
	var half_depth := _extent_along(half, forward)
	var aspect := viewport_size.x / viewport_size.y
	var pad := 1.0 + maxf(margin, 0.0)
	var centre := box.get_center()

	var distance: float
	# How far the camera slides along its own right and up axes to centre the
	# silhouette. An orthographic picture is centred already.
	var slide := Vector2.ZERO
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		var height := maxf(half_height, half_width / aspect) * 2.0 * pad
		var vertical: bool = camera.keep_aspect == Camera3D.KEEP_HEIGHT
		camera.size = maxf(height if vertical else height * aspect, 0.001)
		# An ortho camera's distance changes nothing about the picture; it
		# only has to stand clear of the box so near-plane clipping cannot
		# eat the front of it.
		distance = half_depth * 2.0 + camera.size
	else:
		var tangent := tan(deg_to_rad(maxf(camera.fov, 1.0)) * 0.5)
		var tan_vertical := tangent if camera.keep_aspect == Camera3D.KEEP_HEIGHT \
			else tangent / aspect
		var tan_horizontal := tan_vertical * aspect
		var fit := _fit_perspective(box, centre, right, up, forward,
			tan_horizontal, tan_vertical, half_depth, pad)
		slide = Vector2(fit.x, fit.y)
		distance = fit.z

	camera.global_position = centre - forward * distance \
		+ right * slide.x + up * slide.y
	camera.near = maxf(0.01, (distance - half_depth) * 0.01)
	camera.far = distance + half_depth * 2.0 + 1.0


## Half-extent of a box of half-sizes `half` along a unit `axis`.
static func _extent_along(half: Vector3, axis: Vector3) -> float:
	return absf(axis.x * half.x) + absf(axis.y * half.y) + absf(axis.z * half.z)


## How many halvings the two searches spend: one on the slide that centres an
## axis, one on the distance. Both are cheap — a pass is eight divisions — and
## fixed, so a fit costs the same on every box.
const CENTRE_PASSES: int = 28
const DISTANCE_PASSES: int = 40


## The camera placement for a perspective fit, as (slide right, slide up,
## distance). The framing is read off the box's eight CORNERS at their own
## depths, which is the only place a perspective camera's picture can be
## measured: the box's half-extents describe a plane through its centre and
## say nothing about what stands in front of that plane.
##
## The projected extent shrinks monotonically as the camera backs off, so the
## closest distance that still holds every corner is bisected between a floor
## that keeps the near face in front of the lens and a reach known to fit.
## Every candidate is judged with the silhouette re-centred, so the answer is
## the closest the camera can stand, and not the closest it can stand while
## aiming at a point the picture is not centred on.
static func _fit_perspective(box: AABB, centre: Vector3, right: Vector3,
		up: Vector3, forward: Vector3, tan_horizontal: float,
		tan_vertical: float, half_depth: float, pad: float) -> Vector3:
	var corners: Array[Vector3] = []
	for index in range(8):
		var offset: Vector3 = box.get_endpoint(index) - centre
		corners.append(Vector3(offset.dot(right), offset.dot(up),
			offset.dot(forward)))
	# The near face has to stand clear of the lens whatever else is asked.
	var near_limit := half_depth * 1.05 + 0.001
	# A reach that certainly fits: every corner's lateral offset taken at the
	# depth of the NEAREST one.
	var far_limit := near_limit
	for corner in corners:
		far_limit = maxf(far_limit,
			absf(corner.x) * pad / tan_horizontal + half_depth)
		far_limit = maxf(far_limit,
			absf(corner.y) * pad / tan_vertical + half_depth)
	var low := near_limit
	var high := far_limit
	for _pass in range(DISTANCE_PASSES):
		var middle := (low + high) * 0.5
		if _fit_span(corners, middle, tan_horizontal, tan_vertical).z * pad > 1.0:
			low = middle
		else:
			high = middle
	var fit := _fit_span(corners, high, tan_horizontal, tan_vertical)
	return Vector3(fit.x, fit.y, high)


## The projected half-extent of the corners at `distance`, with the camera
## slid to centre them: (slide right, slide up, half-extent in frame halves).
## One is the frame edge.
static func _fit_span(corners: Array[Vector3], distance: float,
		tan_horizontal: float, tan_vertical: float) -> Vector3:
	var reaches: Array[float] = []
	var across: Array[float] = []
	var along: Array[float] = []
	for corner in corners:
		reaches.append(maxf(distance + corner.z, 0.001))
		across.append(corner.x)
		along.append(corner.y)
	var horizontal := _centre_axis(across, reaches, tan_horizontal)
	var vertical := _centre_axis(along, reaches, tan_vertical)
	return Vector3(horizontal.x, vertical.x, maxf(horizontal.y, vertical.y))


## The slide along ONE camera axis that leaves the projected corners centred,
## and the half-extent they then span: (slide, half-extent).
##
## Sliding trades one side of the frame for the other, and the near corners
## move several times faster than the far ones — the reaches differ by the
## depth of the box — so the balance point is bisected rather than stepped
## towards. The offsets themselves bracket it: at the smallest, every corner
## is on one side; at the largest, every corner is on the other.
static func _centre_axis(offsets: Array[float], reaches: Array[float],
		tangent: float) -> Vector2:
	var low := INF
	var high := -INF
	for offset in offsets:
		low = minf(low, offset)
		high = maxf(high, offset)
	var slide := (low + high) * 0.5
	var extent := 0.0
	for _pass in range(CENTRE_PASSES):
		slide = (low + high) * 0.5
		var over := 0.0
		var under := 0.0
		for index in range(offsets.size()):
			var value := (offsets[index] - slide) / (reaches[index] * tangent)
			over = maxf(over, value)
			under = maxf(under, -value)
		extent = maxf(over, under)
		if over > under:
			low = slide
		else:
			high = slide
	return Vector2(slide, extent)


# ---------------------------------------------------------------------------
# The offscreen render
# ---------------------------------------------------------------------------

## Draw the pane's world from a fitted copy of its camera, in a viewport of
## the pane's own size that nothing displays. Returns {image} or {error}.
static func _render(panel, source: Camera3D, box: AABB, margin: float) -> Dictionary:
	var pane: Viewport = source.get_viewport()
	if pane == null:
		return {"error": "the pane's camera is not in a viewport"}
	var rect := pane.get_visible_rect()
	var size := Vector2i(int(rect.size.x), int(rect.size.y))
	if size.x <= 0 or size.y <= 0:
		return {"error": "the pane has no size to render at"}

	var offscreen := SubViewport.new()
	offscreen.size = size
	# Share the requested pane's isolated scene, not the host window's world.
	offscreen.world_3d = pane.find_world_3d()
	offscreen.transparent_bg = pane.transparent_bg
	offscreen.msaa_3d = pane.msaa_3d
	offscreen.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var camera := Camera3D.new()
	camera.projection = source.projection
	camera.keep_aspect = source.keep_aspect
	camera.fov = source.fov
	camera.size = source.size
	camera.environment = source.environment
	camera.attributes = source.attributes
	offscreen.add_child(camera)
	panel.add_child(offscreen)
	camera.global_transform = Transform3D(source.global_transform.basis, Vector3.ZERO)
	camera.current = true
	frame(camera, box, Vector2(size), margin)

	var drawn_at_start := Engine.get_frames_drawn()
	var tree: SceneTree = panel.get_tree()
	var drawn := false
	for _iteration in range(MAX_WAIT_ITERATIONS):
		await tree.process_frame
		if not is_instance_valid(panel) or not is_instance_valid(offscreen):
			if is_instance_valid(offscreen):
				offscreen.queue_free()
			return {"error": "the CAD panel closed while the capture was rendering"}
		if Engine.get_frames_drawn() - drawn_at_start >= DRAWN_FRAMES_NEEDED:
			drawn = true
			break

	var image: Image = null
	if drawn:
		var texture: ViewportTexture = offscreen.get_texture()
		if texture != null:
			image = texture.get_image()
	offscreen.queue_free()

	if not drawn:
		return {"error": "no frame was drawn in %d main-loop iterations, so the "
			% MAX_WAIT_ITERATIONS
			+ "fitted view was never rendered — the Minerva window is most "
			+ "likely occluded or minimised. minerva_cad_snapshot reads the "
			+ "pane's last drawn frame and answers without one."}
	if image == null or image.is_empty():
		return {"error": "the offscreen render produced no pixels"}
	return {"image": image}


## Shrink an image to a long edge of `max_edge`, or hand it back untouched.
## Public: the posed capture returns pictures by the same rules.
static func downscale(image: Image, max_edge: int) -> Image:
	var long_edge := maxi(image.get_width(), image.get_height())
	if long_edge <= max_edge:
		return image
	var scale := float(max_edge) / float(long_edge)
	var resized: Image = image.duplicate() as Image
	resized.resize(int(image.get_width() * scale), int(image.get_height() * scale),
		Image.INTERPOLATE_BILINEAR)
	return resized


## Write the PNG where minerva_cad_snapshot writes its own, and by the same
## rules: res:// refused, ~ expanded, parent directory created. `label` names
## the file when the caller named no path. Public: the posed capture writes its
## pictures the same way, and a second copy of these rules would be a second
## answer to "where did my snapshot go".
static func write_png(image: Image, requested: String, label: String) -> Dictionary:
	var path := requested.strip_edges()
	if path.begins_with("res://"):
		return {"error": "output_path under res:// is rejected (read-only on "
			+ "exported builds). Use an absolute path, ~-prefixed, or user://."}
	if path.is_empty():
		var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
		path = "%s/%s_%s.%s.png" % [DEFAULT_DIR, label, stamp,
			str(Time.get_ticks_msec() % 1000).pad_zeros(3)]
	elif path == "~" or path.begins_with("~/"):
		var home := OS.get_environment("HOME")
		if not home.is_empty():
			path = home + path.substr(1)
	var globalized := ProjectSettings.globalize_path(path)
	var parent := globalized.get_base_dir()
	if not parent.is_empty():
		DirAccess.make_dir_recursive_absolute(parent)
	var failure := image.save_png(path)
	if failure != OK:
		return {"error": "failed to write PNG to %s (err=%d)" % [path, failure]}
	return {"path": path, "absolute_path": globalized}


# ---------------------------------------------------------------------------
# Small shared shapes
# ---------------------------------------------------------------------------

static func _corner(raw: Variant) -> Dictionary:
	if not (raw is Array) or (raw as Array).size() < 3:
		return {"error": "a fit box corner is [x, y, z] in mm"}
	var values: Array = raw
	return {"point": Vector3(float(values[0]), float(values[1]), float(values[2]))}


static func _vec(point: Vector3) -> Array:
	return [point.x, point.y, point.z]


static func _records(panel) -> Array:
	if panel == null or not panel.has_method("get_reference_state"):
		return []
	return panel.get_reference_state()


static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(message: String) -> Dictionary:
	return {"error": message, "success": false}
