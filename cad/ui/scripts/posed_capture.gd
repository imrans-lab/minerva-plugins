extends RefCounted
## A picture from A STATED PLACE, and optionally CUT OPEN.
##
## Every other image verb reads the panes the owner left behind.
## minerva_cad_snapshot returns the last drawn frame of one of four fixed
## panes; minerva_cad_snapshot_fit reframes one of those panes without turning
## it. Neither can be asked to stand somewhere: nothing takes a yaw, a pitch or
## a direction. That is how three floorless STLs were exported — a missing
## floor is visible only from below, and no verb could put a camera there.
##
## So this verb takes the POSE as an argument. view="-z" stands under the part
## and looks up; {yaw_deg: 210, pitch_deg: -30} stands anywhere on the sphere.
## The pose convention is the panes' own (orbit_camera.gd): yaw rotates about
## world +Z with yaw=0 on the +X side, pitch is degrees above the XY plane, so
## +90 is straight down from above and -90 straight up from underneath.
##
## IT USES NO PANE AT ALL, which is the point. It builds a private World3D,
## mirrors the geometry into it, renders it in an offscreen viewport of its own
## and frees the lot. Consequences worth stating:
##
##   * There is no pane to be occluded, and no pane camera to inherit
##     "no frame has been drawn" from. When the main loop is not drawing —
##     an occluded or minimised window — the frame is FORCED
##     (RenderingServer.force_draw), which snapshot_fit cannot do because it
##     waits on the shared world the panes are drawing.
##   * An ortho pane's 2-D outline overlay is not in the world and so is not
##     in this picture. This verb draws the shaded solid, always.
##   * The mirrored world holds ONE copy of the solid. The shared world holds
##     one per pane on Perspective (each pane has its own MeshRoot), which is
##     why a section plane cannot be done there: cutting one copy leaves the
##     others whole and the cut invisible.
##
## THE SECTION IS A FRAGMENT DISCARD ON THE SOLID. section_plane={axis, offset_mm,
## keep} overrides the mirrored solid's material with a shader that discards
## every fragment on the unwanted side of the world plane, with backfaces drawn
## and their normals flipped so the inside of a wall is lit like a surface
## rather than a black hole. The override reaches the solid's own instance and
## nothing else, so the FEATURE-EDGE OVERLAY — a separate line mesh — is left
## out of the mirror while a section is active rather than drawing the
## discarded half's silhouette over the cut; the reply says so.
## REFERENCES ARE LEFT WHOLE: a reference is the part
## the solid is being checked against — the board inside the bay, the screw in
## the boss — and cutting it away would delete the very thing a section is
## opened to look at. The reply says so in section_plane.applies_to.
##
## Off-tree note: no class_name — preloaded by relative path from panel_tools.
##
## Consumers: ui/panel_tools.gd (minerva_cad_snapshot_posed).

## Bounds of the evaluated solid, and the framing, PNG and box-resolution rules
## minerva_cad_snapshot_fit already answers by — a posed capture differs in
## where the camera stands, not in what "fit" means or where a PNG goes.
const _FitCapture: Script = preload("fit_capture.gd")
## The five MeshRoots an evaluation pushes to. The mirror reads one of them.
const _PanelMeasurement: Script = preload("panel_measurement.gd")

## Field of view of the posed camera, degrees. Fixed rather than borrowed from
## a pane: the verb must answer identically whatever layout the owner is in,
## and the reply echoes it so the caller can reason about the projection.
const DEFAULT_FOV_DEG: float = 45.0
## Long edge of the returned PNG, and the aspect it is rendered at. There is no
## pane to take a size from.
const DEFAULT_MAX_EDGE: int = 1024
const RENDER_ASPECT: float = 4.0 / 3.0
## Samples per axis when asking whether a forced frame drew anything. A part
## framed to fill 90% of the frame cannot hide between lines this far apart.
const BLANK_PROBE_STEPS: int = 64
## The MeshRoot children that draw the solid's OUTLINE rather than the solid.
## They are line meshes in their own instances, so the section shader — which
## overrides the solid's own material — never reaches them: with a section
## active they would stand in front of the cut, drawing the silhouette of the
## half that was discarded. They are left out of the mirror instead.
const _OUTLINE_INSTANCE_NAMES: Array[String] = ["FeatureEdges", "EdgeLeaders"]
## Frames waited before the draw is forced. Two is what an offscreen viewport
## needs when the main loop is drawing normally; past that it is not drawing.
const DRAWN_FRAMES_NEEDED: int = 2
const MAX_WAIT_ITERATIONS: int = 8

## Named directions, as (yaw_deg, pitch_deg) in the panes' own convention.
## The name is where the camera STANDS, not the way it points: "-z" is under
## the part looking up, which is the view the floorless exports needed.
const NAMED_VIEWS: Dictionary = {
	"+x": Vector2(0.0, 0.0),
	"-x": Vector2(180.0, 0.0),
	"+y": Vector2(90.0, 0.0),
	"-y": Vector2(-90.0, 0.0),
	"+z": Vector2(0.0, 90.0),
	"-z": Vector2(0.0, -90.0),
	# The pane presets by name, so a caller can ask for what it sees on screen.
	"right": Vector2(0.0, 0.0),
	"left": Vector2(180.0, 0.0),
	"back": Vector2(90.0, 0.0),
	"front": Vector2(-90.0, 0.0),
	"top": Vector2(0.0, 90.0),
	"bottom": Vector2(0.0, -90.0),
	"under": Vector2(0.0, -90.0),
	# The iso pane's own default (orbit_camera.DEFAULT_YAW/PITCH), and the
	# same three-quarter view from underneath.
	"iso": Vector2(-45.0, 30.0),
	"iso-under": Vector2(-45.0, -30.0),
}

## Up vector for the camera. Straight down or straight up has no unique one, so
## those two take the plan views' screen-up (+Y), matching the Top/Bottom panes.
const WORLD_UP: Vector3 = Vector3(0.0, 0.0, 1.0)
const PLAN_UP: Vector3 = Vector3(0.0, 1.0, 0.0)
## |dir.z| past this counts as looking straight down or straight up.
const POLE_COSINE: float = 0.9995


# ---------------------------------------------------------------------------
# The verb
# ---------------------------------------------------------------------------

## minerva_cad_snapshot_posed — the evaluated solid from a stated pose, framed
## on `fit`, optionally cut by a section plane.
static func snapshot(panel, args: Dictionary) -> Dictionary:
	var pose := resolve_pose(args)
	if pose.has("error"):
		return _err(str(pose["error"]))

	var box_reply: Dictionary = _FitCapture.resolve_box(panel, args.get("fit", "solid"))
	if box_reply.has("error"):
		return _err(str(box_reply["error"]))
	var box: AABB = box_reply["box"]

	var section := resolve_section(args.get("section_plane", null))
	if section.has("error"):
		return _err(str(section["error"]))

	var max_edge := int(args.get("max_edge", DEFAULT_MAX_EDGE))
	if max_edge <= 0:
		max_edge = DEFAULT_MAX_EDGE
	var size := Vector2i(max_edge, maxi(int(round(float(max_edge) / RENDER_ASPECT)), 1))
	var margin := clampf(float(args.get("margin", _FitCapture.DEFAULT_MARGIN)),
		0.0, _FitCapture.MAX_MARGIN)

	var render := await _render(panel, box, pose, section, size, margin)
	# The pose is echoed whether the render worked or not: a caller that has
	# been refused still needs to know which way the camera was pointing to
	# ask a better question.
	var echo := _pose_payload(pose, render.get("camera", Transform3D()), box)
	if render.has("error"):
		var refusal := _err(str(render["error"]))
		refusal["pose"] = echo
		if render.has("drawn"):
			refusal["drawn"] = bool(render["drawn"])
		return refusal
	var image: Image = _FitCapture.downscale(render["image"], max_edge)

	var path_reply: Dictionary = _FitCapture.write_png(image,
		str(args.get("output_path", "")), "posed")
	if path_reply.has("error"):
		return _err(str(path_reply["error"]))

	var payload := {
		"units": "mm",
		"pose": echo,
		"fit": args.get("fit", "solid"),
		"fit_box_mm": [_vec(box.position), _vec(box.end)],
		"margin": margin,
		"width": image.get_width(),
		"height": image.get_height(),
		"content_type": "image/png",
		"mirrored_instances": int(render.get("mirrored", 0)),
	}
	if not section.is_empty():
		payload["section_plane"] = {
			"axis": str(section["axis"]),
			"offset_mm": float(section["offset_mm"]),
			"keep": str(section["keep"]),
			"applies_to": "solid",
			"edge_overlay": "hidden",
			"note": "References are rendered whole: a section is opened to see "
				+ "the solid AROUND a reference, and cutting the reference "
				+ "away would remove what the cut is for. The solid's own "
				+ "feature-edge overlay is HIDDEN while a section is active: "
				+ "the cut is a fragment discard on the solid's material and "
				+ "the outline is a separate line mesh, so it would draw the "
				+ "silhouette of the half that was cut away, floating over "
				+ "the cut face.",
		}
	payload.merge(path_reply)
	if bool(args.get("return_base64", false)):
		payload["image_base64"] = Marshalls.raw_to_base64(image.save_png_to_buffer())
	return _ok(payload)


# ---------------------------------------------------------------------------
# The pose
# ---------------------------------------------------------------------------

## What the caller asked to look from: {yaw_deg, pitch_deg, distance_mm,
## target (Vector3), has_target, view} or {error}.
##
## `view` names a direction and `pose` gives the angles; both together are
## legal, with the explicit angles winning, so "iso, but 20 degrees lower" is
## one call. Neither is an error rather than a default: a posed capture with no
## pose is a snapshot_fit, and answering it under this name would return a
## picture from a direction the caller never chose.
static func resolve_pose(args: Dictionary) -> Dictionary:
	var pose := {
		"view": "",
		"yaw_deg": 0.0,
		"pitch_deg": 0.0,
		"distance_mm": 0.0,
		"target": Vector3.ZERO,
		"has_target": false,
	}
	var stated := false

	var view := str(args.get("view", "")).strip_edges().to_lower()
	if not view.is_empty():
		if not NAMED_VIEWS.has(view):
			var names: Array = NAMED_VIEWS.keys()
			names.sort()
			return {"error": "view '%s' is not a direction; use one of %s, or "
				% [view, str(names)]
				+ "give pose={yaw_deg, pitch_deg}"}
		var angles: Vector2 = NAMED_VIEWS[view]
		pose["view"] = view
		pose["yaw_deg"] = angles.x
		pose["pitch_deg"] = angles.y
		stated = true

	var raw: Variant = args.get("pose", null)
	if raw != null:
		if not (raw is Dictionary):
			return {"error": "pose is {yaw_deg, pitch_deg, distance_mm?, target_mm?}"}
		var given: Dictionary = raw
		if given.has("yaw_deg"):
			pose["yaw_deg"] = float(given["yaw_deg"])
			stated = true
		if given.has("pitch_deg"):
			pose["pitch_deg"] = clampf(float(given["pitch_deg"]), -90.0, 90.0)
			stated = true
		if given.has("distance_mm"):
			var distance := float(given["distance_mm"])
			if distance <= 0.0:
				return {"error": "pose.distance_mm must be positive; omit it to "
					+ "let the fit choose the distance"}
			pose["distance_mm"] = distance
		if given.has("target_mm"):
			var target := _point(given["target_mm"])
			if target.has("error"):
				return target
			pose["target"] = target["point"]
			pose["has_target"] = true

	if not stated:
		return {"error": "a posed capture needs a pose: view='-z' (or +x -x +y "
			+ "-y +z iso iso-under, and the pane names) or "
			+ "pose={yaw_deg, pitch_deg}. Without one, use "
			+ "minerva_cad_snapshot_fit — it frames the pane you already have."}
	return pose


## Where the camera stands relative to what it looks at: the panes' own
## spherical convention (orbit_camera._apply_transform), so an agent that read
## minerva_cad_view_state's yaw and pitch can pass them straight back.
static func pose_direction(yaw_deg: float, pitch_deg: float) -> Vector3:
	var yaw := deg_to_rad(yaw_deg)
	var pitch := deg_to_rad(pitch_deg)
	return Vector3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch)).normalized()


## Aim `camera` from `pose` and put it where `box` fills the frame.
##
## The turning is the pose's; the distance is the framing's, because a caller
## who says "look at the underside" does not also want to compute how far back
## a 177 mm body has to be to fit in a 45-degree frame. pose.distance_mm and
## pose.target override each half of that when the caller does want it:
## with a target the camera aims exactly there and the fit only sets how far
## back, since sliding to centre the silhouette (what fit_capture does for a
## deep box) would aim it somewhere else.
static func place_camera(camera: Camera3D, box: AABB, pose: Dictionary,
		viewport_size: Vector2, margin: float) -> void:
	if camera == null:
		return
	var direction := pose_direction(float(pose["yaw_deg"]), float(pose["pitch_deg"]))
	var up := PLAN_UP if absf(direction.z) > POLE_COSINE else WORLD_UP
	var centre: Vector3 = box.get_center()
	camera.global_transform = Transform3D(
		Basis.looking_at(-direction, up), centre + direction)
	_FitCapture.frame(camera, box, viewport_size, margin)

	var target: Vector3 = pose["target"] if bool(pose["has_target"]) else centre
	var distance := camera.global_position.distance_to(centre)
	var stated := float(pose["distance_mm"])
	if stated > 0.0:
		# STATED MEANS STATED. The fit slides the camera sideways to centre a
		# deep box's silhouette, so nudging it along `direction` by the
		# difference would leave it a couple of millimetres off the distance
		# it was asked for while the reply claimed the round number. It is
		# re-placed from the target instead, which costs the slide and keeps
		# one distance true everywhere.
		camera.global_position = target + direction * stated
		camera.look_at(target, up)
		distance = stated
	elif bool(pose["has_target"]):
		camera.global_position = target + direction * distance
		camera.look_at(target, up)
	var reach := box.size.length()
	camera.near = maxf(0.01, distance * 0.01)
	camera.far = distance + reach * 2.0 + 1.0


## The pose as the reply states it: what was asked, and where that put the
## camera. Both, because "yaw 210, pitch -30" is not a place until it is
## resolved against a box, and a caller reasoning about what it is looking at
## needs the place.
static func _pose_payload(pose: Dictionary, camera: Transform3D, box: AABB) -> Dictionary:
	var direction := pose_direction(float(pose["yaw_deg"]), float(pose["pitch_deg"]))
	var target: Vector3 = pose["target"] if bool(pose["has_target"]) else box.get_center()
	var payload := {
		"yaw_deg": float(pose["yaw_deg"]),
		"pitch_deg": float(pose["pitch_deg"]),
		"stands_at_direction": _vec(direction),
		"look_direction": _vec(-direction),
		"target_mm": _vec(target),
		"fov_deg": DEFAULT_FOV_DEG,
		"convention": "yaw about world +Z from the +X side, pitch degrees above "
			+ "the XY plane; the pose is where the camera STANDS, so pitch -90 "
			+ "is under the part looking up",
	}
	if not str(pose["view"]).is_empty():
		payload["view"] = str(pose["view"])
	if camera != Transform3D():
		payload["camera_position_mm"] = _vec(camera.origin)
		payload["camera_forward"] = _vec(-camera.basis.z.normalized())
	return payload


# ---------------------------------------------------------------------------
# The section plane
# ---------------------------------------------------------------------------

## {axis: x|y|z, offset_mm: float, keep: "+"|"-"} → {plane, axis, offset_mm,
## keep}, {} for no section, or {error}.
##
## The stored plane always points at the half that is KEPT, so the shader has
## one rule: discard what is behind the normal.
static func resolve_section(raw: Variant) -> Dictionary:
	if raw == null:
		return {}
	if not (raw is Dictionary):
		return {"error": "section_plane is {axis: 'x'|'y'|'z', offset_mm: <mm>, "
			+ "keep: '+'|'-'}"}
	var given: Dictionary = raw
	if given.is_empty():
		return {}
	var axis := str(given.get("axis", "")).strip_edges().to_lower()
	var normal: Vector3
	match axis:
		"x":
			normal = Vector3(1.0, 0.0, 0.0)
		"y":
			normal = Vector3(0.0, 1.0, 0.0)
		"z":
			normal = Vector3(0.0, 0.0, 1.0)
		_:
			return {"error": "section_plane.axis must be 'x', 'y' or 'z'; got '%s'"
				% axis}
	if not given.has("offset_mm"):
		return {"error": "section_plane needs offset_mm — where along %s the cut is"
			% axis}
	var offset := float(given["offset_mm"])
	var keep := str(given.get("keep", "+")).strip_edges()
	if keep != "+" and keep != "-":
		return {"error": "section_plane.keep is '+' (keep the side above "
			+ "offset_mm) or '-' (below); got '%s'" % keep}
	var plane := Plane(normal, offset) if keep == "+" else Plane(-normal, -offset)
	return {"plane": plane, "axis": axis, "offset_mm": offset, "keep": keep}


## The shader behind the cut. World-space so the plane means the same thing the
## caller said it meant, whatever transform the instance carries.
## cull_disabled is what makes the inside of a wall visible at all once the
## outside of it is discarded; the backface normal flip makes those faces face
## the light, which under the panes' ambient-only environment changes nothing
## today and is there so a document lit by anything directional does not show
## its interior inside-out.
const SECTION_SHADER: String = """shader_type spatial;
render_mode cull_disabled;

uniform vec4 albedo : source_color = vec4(0.8, 0.8, 0.85, 1.0);
uniform vec3 section_normal = vec3(0.0, 0.0, 1.0);
uniform float section_offset = 0.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (dot(world_position, section_normal) < section_offset) {
		discard;
	}
	ALBEDO = albedo.rgb;
	ROUGHNESS = 0.65;
	METALLIC = 0.0;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
"""


## The section material for one solid, keeping the colour the panel gave it so
## a sectioned picture is the same part in the same colour, with a bite out.
static func section_material(source: Material, plane: Plane) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = SECTION_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	var albedo := Color(0.8, 0.8, 0.85)
	if source is BaseMaterial3D:
		albedo = (source as BaseMaterial3D).albedo_color
	material.set_shader_parameter("albedo", albedo)
	material.set_shader_parameter("section_normal", plane.normal)
	material.set_shader_parameter("section_offset", plane.d)
	return material


# ---------------------------------------------------------------------------
# The private world
# ---------------------------------------------------------------------------

## Draw the mirrored scene from a posed camera. {image, camera, mirrored} or
## {error, camera}.
static func _render(panel, box: AABB, pose: Dictionary, section: Dictionary,
		size: Vector2i, margin: float) -> Dictionary:
	if panel == null or not is_instance_valid(panel):
		return {"error": "the CAD panel is not available"}
	var source_root: Node3D = _mesh_root(panel)
	if source_root == null:
		return {"error": "this panel has no MeshRoot to mirror — nothing has "
			+ "been evaluated into it"}

	var world := World3D.new()
	world.environment = _source_environment(source_root)

	var offscreen := SubViewport.new()
	offscreen.size = size
	offscreen.world_3d = world
	offscreen.transparent_bg = false
	offscreen.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var mirror := Node3D.new()
	mirror.name = "PosedMirror"
	offscreen.add_child(mirror)
	var mirrored := _mirror_into(source_root, mirror,
		_solid_instance(source_root), section)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = DEFAULT_FOV_DEG
	offscreen.add_child(camera)
	panel.add_child(offscreen)
	camera.current = true
	place_camera(camera, box, pose, Vector2(size), margin)
	var placed := camera.global_transform

	var tree: SceneTree = panel.get_tree()
	var drawn_at_start := Engine.get_frames_drawn()
	var drawn := false
	for _iteration in range(MAX_WAIT_ITERATIONS):
		await tree.process_frame
		if not is_instance_valid(panel) or not is_instance_valid(offscreen):
			if is_instance_valid(offscreen):
				offscreen.queue_free()
			return {"error": "the CAD panel closed while the capture was rendering",
				"camera": placed}
		if Engine.get_frames_drawn() - drawn_at_start >= DRAWN_FRAMES_NEEDED:
			drawn = true
			break
	if not drawn:
		# THE OCCLUDED PATH. Nothing is drawn while the window is occluded or
		# minimised, so the counter above never moves and the loop spends its
		# whole budget. This camera is not a pane's — it has no last frame to
		# fall back on and no reason to inherit a pane's refusal — so the
		# frames are FORCED here instead. force_draw() draws without going
		# through the main loop, so it does not advance
		# Engine.get_frames_drawn(): there is nothing to re-test, and the two
		# calls are unconditional. swap_buffers stays false; the window is not
		# this verb's to repaint. UNVERIFIED IN A HEADLESS RUN — a build with
		# no rendering driver draws nothing either way, and the empty image
		# below is what that comes back as.
		for _forced in range(DRAWN_FRAMES_NEEDED):
			RenderingServer.force_draw(false)

	var image: Image = null
	var texture: ViewportTexture = offscreen.get_texture()
	if texture != null:
		image = texture.get_image()
	offscreen.queue_free()

	if image == null or image.is_empty():
		return {"error": "the posed render produced no pixels: this build is "
			+ "drawing nothing at all (a headless run has no rendering driver). "
			+ "The pose itself is in this reply.", "camera": placed}
	# AN IMAGE OF THE RIGHT SIZE IS NOT AN IMAGE OF ANYTHING. The forced path
	# reads the render target whether or not the driver put anything in it, and
	# a target that was allocated and never drawn reads back as one flat
	# colour — which travels as a PNG, and a caller cannot tell it from a
	# picture of a part that is out of frame. Only the forced path is asked:
	# a frame the main loop drew has been drawn by definition.
	if not drawn and _is_one_colour(image):
		return {"error": "the posed render was forced (nothing is drawing "
			+ "through the main loop — an occluded window, or a build with no "
			+ "rendering driver) and the render target came back a single "
			+ "flat colour, so nothing was drawn into it. The pose itself is "
			+ "in this reply.", "camera": placed, "drawn": false}
	return {"image": image, "camera": placed, "mirrored": mirrored}


## Is every pixel of this image the same colour? That is what an untouched
## render target reads back as. Sampled on a grid rather than walked: a 1024 x
## 768 target is 786,432 get_pixel calls, and a picture that differs anywhere
## differs at one of these long before the walk would finish.
static func _is_one_colour(image: Image) -> bool:
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return true
	var first := image.get_pixel(0, 0)
	var step_x := maxi(width / BLANK_PROBE_STEPS, 1)
	var step_y := maxi(height / BLANK_PROBE_STEPS, 1)
	var y := 0
	while y < height:
		var x := 0
		while x < width:
			if not image.get_pixel(x, y).is_equal_approx(first):
				return false
			x += step_x
		y += step_y
	return true


## Pick a shaded pane by presentation mode, independently of whether the
## document contains a generated solid or only imported references.
static func _mesh_root(panel) -> Node3D:
	if panel.has_method("get_query_mesh_root"):
		return panel.get_query_mesh_root()
	var fallback: Node3D = null
	for path in _PanelMeasurement.MESH_ROOT_PATHS:
		var root := panel.get_node_or_null(path) as Node3D
		if root == null:
			continue
		if fallback == null:
			fallback = root
		var camera := root.get_viewport().get_camera_3d()
		if camera != null and camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
			return root
	return fallback


## Each pane owns its world. The host viewport's environment is unrelated.
static func _source_environment(source_root: Node3D) -> Environment:
	var viewport := source_root.get_viewport()
	if viewport == null:
		return null
	var camera := viewport.get_camera_3d()
	if camera != null and camera.environment != null:
		return camera.environment
	var world := viewport.find_world_3d()
	return world.environment if world != null else null


## The MeshRoot's own solid instance, or null on a stand-in that has none.
static func _solid_instance(root: Node3D) -> MeshInstance3D:
	if root == null or not root.has_method("get_solid_instance"):
		return null
	return root.get_solid_instance() as MeshInstance3D


## Copy every visible mesh under `source` into `into`, flat, at its world
## transform. Flat and by reference: the Mesh resources are shared, nothing is
## re-tessellated, and no script under the source runs again — a duplicate() of
## the MeshRoot would re-run mesh_display._ready and build a second, empty set
## of instances. Returns how many were copied.
static func _mirror_into(source: Node3D, into: Node3D, solid: MeshInstance3D,
		section: Dictionary) -> int:
	var count := 0
	for node in _visual_instances(source):
		if not section.is_empty() \
				and _OUTLINE_INSTANCE_NAMES.has(str(node.name)):
			continue
		var copy := MeshInstance3D.new()
		copy.mesh = node.mesh
		copy.material_override = node.material_override
		copy.cast_shadow = node.cast_shadow
		into.add_child(copy)
		copy.global_transform = node.global_transform
		if not section.is_empty() and node == solid:
			var surface: Material = node.mesh.surface_get_material(0) \
				if node.mesh.get_surface_count() > 0 else null
			copy.material_override = section_material(surface, section["plane"])
		count += 1
	return count


## Every drawable mesh under `root`, the solid and its outline included.
static func _visual_instances(root: Node3D) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		for child in node.get_children():
			pending.append(child)
		var instance := node as MeshInstance3D
		if instance == null or instance.mesh == null:
			continue
		if not instance.visible or not instance.is_visible_in_tree():
			continue
		found.append(instance)
	return found


# ---------------------------------------------------------------------------
# Small shared shapes
# ---------------------------------------------------------------------------

static func _point(raw: Variant) -> Dictionary:
	if not (raw is Array) or (raw as Array).size() < 3:
		return {"error": "pose.target_mm is [x, y, z] in mm"}
	var values: Array = raw
	return {"point": Vector3(float(values[0]), float(values[1]), float(values[2]))}


static func _vec(point: Vector3) -> Array:
	return [point.x, point.y, point.z]


static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(message: String) -> Dictionary:
	return {"error": message, "success": false}
