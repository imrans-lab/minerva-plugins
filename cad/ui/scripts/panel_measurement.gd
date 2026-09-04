extends RefCounted
## The panel's reference and measurement bookkeeping.
##
## The panel's part in measuring a foreign mesh is only ever bookkeeping: it
## knows which references are mounted, where they are posed and which modules
## hold the geometry. The fitting lives in mesh_features.gd and every physical
## question is answered by mesh_gauge.gd from inside a physics step. This
## module is the middle: it mounts what an evaluation named, keeps the identity
## the colliders are keyed on, spreads the measurement overlay over the panes,
## and answers the two questions a pixel can ask — how big is a millimetre here,
## and what does this pixel point at.
##
## Which pane is which camera lives here too, because every answer below is
## taken through one of them — and so does per-pane mesh visibility, because
## the ortho x-ray rule applies to the reference meshes and the evaluated solid
## together.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/panel_measurement.gd")

## Every MeshRoot an evaluation has to reach — the four wide-layout panes and
## the narrow layout's single pane. One list, because the mesh push, the
## reference mount and the ortho x-ray toggle must never disagree about which
## panes exist.
const MESH_ROOT_PATHS: Array = [
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/TopView/SubViewport/MeshRoot",
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/FrontView/SubViewport/MeshRoot",
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/RightView/SubViewport/MeshRoot",
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/IsoView/SubViewport/MeshRoot",
	"ResponsiveContainer/NarrowLayout/SingleView/SubViewport/MeshRoot",
]


## The panel that owns this module. Read through duck typing (its reference
## library, its gauge and its cameras) — never typed, off-tree.
var _panel: Object = null


func _init(panel: Object) -> void:
	_panel = panel


## Build the gauge's colliders for the currently mounted references, if the set
## has changed since they were last built. Returns the collider count.
##
## Every part is handed over in WORLD millimetres — the pose composed onto the
## already-converted part transform — so every number the gauge returns is a
## world coordinate and nothing downstream has to know about the CAD frame
## conversion at all.
func ensure_gauge_built() -> int:
	if _panel._mesh_gauge == null:
		return 0
	var bodies: Array = []
	for entry in _panel.get_reference_state():
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var reference_name := str(record.get("name", ""))
		for part_entry in record.get("parts", []):
			var part: Dictionary = part_entry
			bodies.append({
				"mesh": part.get("mesh", null),
				"transform": pose * (part.get("transform", Transform3D.IDENTITY) as Transform3D),
				# The node PATH, not the leaf name: two branches of a foreign
				# assembly may both hold a node called "Body", and a contact
				# attributed to the wrong one of them is a wrong answer.
				"node": "%s/%s" % [reference_name,
					str(part.get("node_path", part.get("node", "")))],
				"reference": reference_name,
			})
	return int(_panel._mesh_gauge.call("build", bodies, _panel._reference_digest))


## Identity of the mounted reference set: which files, at which content stamp,
## in which pose. Colliders and segmentation are keyed on it.
func _compute_digest() -> String:
	var parts := PackedStringArray()
	for entry in _panel.get_reference_state():
		var record: Dictionary = entry
		# units and up are baked into the converted part transforms, so a
		# digest without them lets a units= edit keep stale colliders.
		parts.append("%s@%s@%s@%s@%s" % [
			str(record.get("resolved_path", "")),
			str(record.get("stamp", "")),
			str(record.get("units", "")),
			str(record.get("up", "")),
			str(record.get("pose", Transform3D.IDENTITY)),
		])
	return "|".join(parts)


## Mount the evaluation's reference meshes under every MeshRoot and hand each
## MeshDisplay the world bounds so auto-framing covers them.
func mount_references(references: Array) -> void:
	_panel._reference_report = {}
	_panel._last_references = references
	if _panel._reference_library == null:
		return
	var mesh_roots: Array = []
	for path in MESH_ROOT_PATHS:
		var mesh_root := _panel.get_node_or_null(path) as Node3D
		if mesh_root != null:
			mesh_roots.append(mesh_root)
	_panel._reference_report = _panel._reference_library.mount_all(
		references, _panel._document_path, mesh_roots)
	# The colliders are rebuilt lazily, on the next measurement: a pose edit
	# arrives on every keystroke and building 45 trimeshes costs a quarter of
	# a second. The digest below is what decides whether that rebuild is real
	# work or a no-op.
	_panel._reference_digest = _compute_digest()
	if _panel._reference_selection != null:
		_panel._reference_selection.set_records(_panel.get_reference_state())
	var world_aabb: AABB = _panel._reference_report.get("world_aabb", AABB())
	for mesh_root in mesh_roots:
		if mesh_root.has_method("set_reference_aabb"):
			mesh_root.call("set_reference_aabb", world_aabb)
	for warning in _panel._reference_report.get("warnings", PackedStringArray()):
		push_warning("[CADPanel] reference mesh: %s" % warning)
	for problem in _panel._reference_report.get("errors", PackedStringArray()):
		push_warning("[CADPanel] reference mesh: %s" % problem)


## Draw the measurement overlay in every pane and report the scale of each one.
## The overlay is scene geometry, so the host's own snapshot verb picks it up
## with no changes: the LLM turns the grid on, then takes the picture it was
## going to take anyway, and now the picture has a ruler in it.
func set_measurement_overlay(mode: String, grid_mm: float) -> Dictionary:
	var bounds := AABB()
	var have_bounds := false
	for path in MESH_ROOT_PATHS:
		var mesh_root: Node = _panel.get_node_or_null(path)
		if mesh_root == null or not mesh_root.has_method("set_measurement_overlay"):
			continue
		if not have_bounds:
			bounds = _overlay_bounds(mesh_root)
			have_bounds = true
	var drawn := {}
	for path in MESH_ROOT_PATHS:
		var mesh_root: Node = _panel.get_node_or_null(path)
		if mesh_root != null and mesh_root.has_method("set_measurement_overlay"):
			drawn = mesh_root.call("set_measurement_overlay", mode, grid_mm, bounds)
	return drawn


## Bounds to spread the overlay over: the references plus whatever the solid
## occupies, falling back to the reference bounds alone.
func _overlay_bounds(mesh_root: Object) -> AABB:
	var bounds := AABB()
	if mesh_root.has_method("get_reference_aabb"):
		bounds = mesh_root.call("get_reference_aabb")
	var world_aabb: AABB = _panel._reference_report.get("world_aabb", AABB())
	if world_aabb.size.length() > 0.0:
		bounds = world_aabb if bounds.size.length() <= 0.0 else bounds.merge(world_aabb)
	return bounds


## Millimetres-to-pixels for one pane, so a snapshot can be read as a drawing.
## Orthographic panes have one constant scale; the iso pane is a perspective
## projection and has none, which is reported as a null rather than as a lie.
func get_view_metrics(view: String) -> Dictionary:
	var refusal := view_unavailable_reason(view)
	if not refusal.is_empty():
		return {"error": refusal, "view": view}
	var camera := camera_for_view(view)
	if camera == null:
		return {"error": "no camera for view '%s'" % view}
	var viewport := camera.get_viewport()
	var size: Vector2i = viewport.size if viewport != null else Vector2i.ZERO
	var metrics := {
		"view": view,
		"width_px": size.x,
		"height_px": size.y,
		"projection": "orthographic" if camera.projection == Camera3D.PROJECTION_ORTHOGONAL \
			else "perspective",
		"px_per_mm": null,
		"origin_px": null,
	}
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL and size.y > 0 and camera.size > 0.0:
		# One CAD world unit is one millimetre, so the camera's own ortho
		# height in world units is the height of the pane in millimetres.
		metrics["px_per_mm"] = float(size.y) / camera.size
	if size.y > 0:
		var origin := camera.unproject_position(Vector3.ZERO)
		metrics["origin_px"] = [origin.x, origin.y]
	return metrics


## The world-space ray under a pixel of one pane, for turning a click or a
## snapshot coordinate into a question about the geometry. Pixels are in the
## pane's own viewport, top-left origin — the same coordinates a snapshot of
## that pane has, before any max_edge downscale the host applies.
func get_pick_ray(view: String, pixel: Vector2) -> Dictionary:
	var refusal := view_unavailable_reason(view)
	if not refusal.is_empty():
		return {"error": refusal}
	var camera := camera_for_view(view)
	if camera == null:
		return {"error": "no camera for view '%s'" % view}
	var viewport := camera.get_viewport()
	var size: Vector2i = viewport.size if viewport != null else Vector2i.ZERO
	if size.x <= 0 or size.y <= 0:
		return {"error": "pane '%s' has no rendered size" % view}
	if pixel.x < 0.0 or pixel.y < 0.0 or pixel.x >= float(size.x) or pixel.y >= float(size.y):
		return {"error": "pixel %s is outside the %dx%d pane" % [str(pixel), size.x, size.y]}
	var origin := camera.project_ray_origin(pixel)
	var direction := camera.project_ray_normal(pixel)
	# Far enough to cross any part a CAD document holds, and bounded so the
	# ray is a segment the physics server can answer about.
	var reach := maxf(camera.far, 10000.0)
	return {
		"from": origin,
		"to": origin + direction * reach,
		"width_px": size.x,
		"height_px": size.y,
	}


## Why a named pane cannot be addressed, or "" when it can. Narrow layout has
## a single pane showing whichever preset the dropdown is on, so handing back
## that camera for "top" would answer a question about one pane with another
## pane's geometry — the right label over the wrong numbers. Snapshot already
## refuses here; measurement refuses for the same reason.
func view_unavailable_reason(view: String) -> String:
	if view.is_empty() or view == "active" or view == "single":
		return ""
	if _panel._narrow_layout != null and _panel._narrow_layout.visible:
		return ("the panel is in narrow layout and renders one pane only "
			+ "(currently '%s'); ask for view \"active\", or widen the panel "
			+ "to address '%s' separately") % [_panel._current_projection_preset(), view]
	return ""


## Camera for a named pane. "active" means whatever the user is looking at,
## which in narrow layout is the only pane that renders at all.
func camera_for_view(view: String) -> Camera3D:
	if view.is_empty() or view == "active" or view == "single":
		return camera_for_active_viewport()
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	match view:
		"top":
			return _panel.get_node_or_null(grid + "/TopView/SubViewport/OrbitCamera") as Camera3D
		"front":
			return _panel.get_node_or_null(grid + "/FrontView/SubViewport/OrbitCamera") as Camera3D
		"right":
			return _panel.get_node_or_null(grid + "/RightView/SubViewport/OrbitCamera") as Camera3D
		"iso":
			return _panel.get_node_or_null(grid + "/IsoView/SubViewport/OrbitCamera") as Camera3D
	return null


## Hide the shaded mesh in ortho-only panes (Top/Front/Right; narrow non-
## perspective) so the edge overlay is the only visualisation. Iso /
## Perspective keeps the mesh visible for shaded 3-D context.
func apply_mesh_visibility() -> void:
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	# Wide-layout panes: Top/Front/Right hide mesh; Iso shows it.
	_set_pane_mesh_visible(grid + "/TopView/SubViewport/MeshRoot", false)
	_set_pane_mesh_visible(grid + "/FrontView/SubViewport/MeshRoot", false)
	_set_pane_mesh_visible(grid + "/RightView/SubViewport/MeshRoot", false)
	_set_pane_mesh_visible(grid + "/IsoView/SubViewport/MeshRoot", true)
	# Narrow single view: hide mesh unless the projection is Perspective.
	var single_path := "ResponsiveContainer/NarrowLayout/SingleView/SubViewport/MeshRoot"
	var preset: String = _panel._current_projection_preset()
	_set_pane_mesh_visible(single_path, preset == "Perspective")


## Toggle the MeshInstance3D inside a MeshRoot. Found by the well-known child
## name "MeshInstance" set in mesh_display.gd._ready(). Reference meshes follow
## the same rule: shaded in the perspective pane, outline-only in the orthos.
func _set_pane_mesh_visible(mesh_root_path: String, visible_flag: bool) -> void:
	var mesh_root: Node = _panel.get_node_or_null(mesh_root_path)
	if mesh_root == null:
		return
	var mi := mesh_root.get_node_or_null("MeshInstance")
	if mi != null and "visible" in mi:
		mi.visible = visible_flag
	if _panel._reference_library != null and mesh_root is Node3D:
		_panel._reference_library.set_shaded_visible(mesh_root as Node3D, visible_flag)


## Public introspection surface backing minerva_cad_view_state, reached through
## CADPanel.get_view_state(). Surfaces layout/camera state the panel already
## tracks — width_class (which ResponsiveContainer breakpoint is active),
## active_viewport_id (which pane
## an agent's minerva_cad_snapshot view="active" would capture), the
## narrow-mode projection dropdown selection, and the active pane's camera
## orientation/zoom (OrbitCamera's own get_target/get_distance/get_yaw/
## get_pitch/get_debug_state — no new camera state was added for this tool).
func view_state() -> Dictionary:
	var cam: Camera3D = camera_for_active_viewport()
	var camera_state: Variant = null
	if cam != null:
		camera_state = {
			"view_preset": String(cam.get_debug_state().get("view_preset", "")) if cam.has_method("get_debug_state") else "",
			"target": _vec3(cam.get_target()) if cam.has_method("get_target") else null,
			"distance": cam.get_distance() if cam.has_method("get_distance") else null,
			"yaw": cam.get_yaw() if cam.has_method("get_yaw") else null,
			"pitch": cam.get_pitch() if cam.has_method("get_pitch") else null,
		}
	return {
		"width_class": String(_panel._responsive.width_class) if _panel._responsive != null else "",
		"is_narrow_layout": _panel._narrow_layout.visible if _panel._narrow_layout != null else false,
		"active_viewport_id": _panel._active_viewport_id,
		"projection_preset": _panel._current_projection_preset(),
		"camera": camera_state,
	}


## Resolve the Camera3D backing the currently-active pane: the single
## narrow-mode camera when narrow layout is visible, otherwise the wide-mode
## camera matching the panel's active viewport id (falls back to the iso camera
## for any id that isn't top/front/right — mirrors the panel's lower-cased
## projection ids and its wide-mode camera map).
func camera_for_active_viewport() -> Camera3D:
	if _panel._narrow_layout != null and _panel._narrow_layout.visible:
		return _panel._single_view_camera
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	match _panel._active_viewport_id:
		"top":
			return _panel.get_node_or_null(grid + "/TopView/SubViewport/OrbitCamera") as Camera3D
		"front":
			return _panel.get_node_or_null(grid + "/FrontView/SubViewport/OrbitCamera") as Camera3D
		"right":
			return _panel.get_node_or_null(grid + "/RightView/SubViewport/OrbitCamera") as Camera3D
		_:
			return _panel.get_node_or_null(grid + "/IsoView/SubViewport/OrbitCamera") as Camera3D


## Vector3 -> [x, y, z] (JSON-safe; MCP results are JSON-encoded downstream).
func _vec3(v: Vector3) -> Array:
	return [v.x, v.y, v.z]
