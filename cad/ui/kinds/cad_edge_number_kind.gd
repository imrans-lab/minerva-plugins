extends AnnotationKind
## CAD plugin annotation kind: cad_edge_number.
##
## Phase B2 form: an edge-anchored callout. The annotation carries a
## cad/edge anchor envelope and a world-space text-box offset; the renderer
## resolves the anchor live (so re-evaluation does not strand the callout)
## and draws a leader + auto-wrapped text box ONLY in the perspective pane.
## Ortho panes already show silhouette + selected-edge highlight; a callout
## there would be redundant and visually collide with the projection.
##
## Envelope shape:
##   anchor:  {plugin: "cad", type: "edge", id: <int>}
##   payload:
##     text:        String  (optional, default "") — user instruction body
##     box_offset:  Array[3] world-space Vector3 components — leader_end =
##                  anchor_position + box_offset
##
## Position access: the renderer calls host._resolve_edge_anchor(anchor)
## directly to get the Vector3 midpoint. Substrate's host.resolve_anchor()
## flattens to Vector2, which is correct for substrate consumers but loses
## the depth needed to project both leader endpoints through Camera3D. This
## is plugin-internal; the resolver is in the same plugin as the kind.
##
## Stale rendering: when the resolver returns null or stale=true, the leader
## and box are drawn with reduced alpha. No CAD-specific stale icon — kept
## minimal until a substrate-wide convention exists.
##
## Off-tree note: this file lives at ~/github/plugins/cad/, outside Minerva's
## res:// tree. It MUST NOT declare a class_name. preload() is used by
## CADPanel.gd and tests to load this script.

## Authoring tool — loaded lazily so the tool script can itself preload base classes.
const _CadEdgeNumberToolScript: Script = preload("../tools/cad_edge_number_tool.gd")

## Per-frame screen-space spread layout, shared across render() calls.
const _LayoutHelper: Script = preload("./cad_edge_label_layout.gd")

## Drag-stable start position cache for un-placed labels.
##
## Why this exists: AnnotationTransformTool passes the immutable
## _drag_start_annotation to transform_annotation each frame, but
## transform.origin is the CUMULATIVE delta from drag-start. So we need
## start_box_screen to be stable across all transform_annotation calls
## within a drag — otherwise the cumulative delta is added to a position
## that has already been mutated by previous frames in the same drag,
## compounding the motion ("label flies off, cursor lags far behind").
##
## The layout helper would normally provide start_box_screen, but it
## iterates host.get_annotations() which returns the LIVE list — by the
## second frame of a drag the live annotation has user_placed=true and a
## moved box_offset, so the helper returns the moved position rather than
## the original.
##
## Fix: cache by [ann_id, start_box_offset, camera_basis, camera_origin,
## viewport_rect]. Cache key is stable across a drag (start payload is
## immutable per substrate contract) and invalidates if the camera/viewport
## changes. Stale entries are tiny — leaving them is harmless.
##
## Used ONLY for un-placed labels in _resolve_perspective_ctx_for_annotation.
## Once a label becomes user_placed=true (after first drag completes), the
## user_placed branch back-projects payload.box_offset directly and the
## cache is bypassed.
static var _drag_start_box_screen_cache: Dictionary = {}

const _Callout := preload("cad_callout.gd")
const _BOX_WIDTH := _Callout._BOX_WIDTH

func _init() -> void:
	name = &"cad_edge_number"
	display_name = "Edge Number"
	schema_version = 2
	owning_plugin = &"cad"
	primitives_optional = true
	default_payload = {"text": "", "box_offset": [0.0, 0.0, 0.0]}
	# Load beside the installed script; plugin assets are outside the host import database.
	var icon_path: String = get_script().resource_path.get_base_dir().path_join("../icons/edge_number.svg")
	var icon_img := Image.load_from_file(ProjectSettings.globalize_path(icon_path))
	if icon_img != null:
		toolbar_icon = ImageTexture.create_from_image(icon_img)



# ── Payload compatibility (accept-old-on-read) ────────────────────────────────
#
# Conformant v2 envelopes store the kind's data under `kind_payload` (the shape
# AnnotationV2Schema requires). Legacy CAD envelopes authored before conformance
# (DCR 019dc0543da5) used `payload`. Cad_AnnotationHost normalizes payload→
# kind_payload on write and on load, but this kind renders BOTH shapes during the
# transition via the tolerant getter below so in-flight / un-normalized dicts
# (e.g. an envelope handed straight to render() by a test or an older sidecar
# read through a non-normalizing path) still draw.

## Read the kind's data slot tolerantly: prefer conformant `kind_payload`, fall
## back to the legacy `payload`. Returns {} when neither is a Dictionary.
static func _payload_of(annotation: Dictionary) -> Dictionary:
	var kp: Variant = annotation.get("kind_payload", null)
	if kp is Dictionary:
		return kp as Dictionary
	var p: Variant = annotation.get("payload", null)
	return (p as Dictionary) if p is Dictionary else {}


## Which slot to WRITE back to so an in-place edit does not desync the two
## shapes: `kind_payload` when the envelope already has it, else legacy `payload`.
static func _payload_key(annotation: Dictionary) -> String:
	return "kind_payload" if annotation.has("kind_payload") else "payload"


# ── Anchor compatibility ──────────────────────────────────────────────────────

## Anchor types this kind accepts. AnnotationV2Schema.validate_with_registry
## reads this so a cad/edge-anchored envelope passes the kind/anchor compat check
## (without it the schema falls back to _GENERIC_KIND_ANCHORS, which has no CAD
## entry, and rejects every cad_edge_number envelope as "accepts no anchors").
func accepted_anchor_types() -> Array:
	return ["cad/edge"]


# ── Validation ────────────────────────────────────────────────────────────────

func validate(annotation: Dictionary) -> Array:
	var errors: Array = []

	var anchor: Variant = annotation.get("anchor", null)
	if not (anchor is Dictionary):
		errors.append({"field": "anchor", "message": "anchor dict is required"})
		return errors
	var anchor_d: Dictionary = anchor as Dictionary
	if str(anchor_d.get("plugin", "")) != "cad":
		errors.append({"field": "anchor.plugin", "message": "anchor.plugin must be 'cad'"})
	if str(anchor_d.get("type", "")) != "edge":
		errors.append({"field": "anchor.type", "message": "anchor.type must be 'edge'"})
	if not anchor_d.has("id"):
		errors.append({"field": "anchor.id", "message": "anchor.id is required"})
	else:
		var id_val: Variant = anchor_d["id"]
		if not (id_val is int or id_val is float):
			errors.append({"field": "anchor.id", "message": "anchor.id must be an integer"})

	var payload: Dictionary = _payload_of(annotation)
	# payload.text is optional (defaults to ""); validate type when present.
	if payload.has("text") and not (payload["text"] is String):
		errors.append({"field": "payload.text", "message": "payload.text must be a string"})
	# payload.box_offset is optional (defaults to zero vector); validate when present.
	if payload.has("box_offset"):
		var off: Variant = payload["box_offset"]
		if not (off is Array) or (off as Array).size() != 3:
			errors.append({
				"field": "payload.box_offset",
				"message": "payload.box_offset must be an Array of 3 numbers",
			})

	return errors


# ── Required rendering ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var host: Variant = ctx.host if "host" in ctx else null
	if host == null:
		return
	if not host.has_method("get_panes"):
		return

	var anchor: Variant = _anchor_for_annotation(annotation)
	if not (anchor is Dictionary):
		return

	# Resolve anchor directly via the host's resolver to keep the Vector3.
	# Substrate's host.resolve_anchor() flattens to Vector2 (correct for
	# substrate consumers, wrong for our perspective Camera3D projection).
	if not host.has_method("_resolve_edge_anchor"):
		return
	var resolved: Variant = host._resolve_edge_anchor(anchor)
	if resolved == null:
		return
	if not (resolved is Dictionary):
		return
	var resolved_d: Dictionary = resolved as Dictionary

	var leader_start_world: Vector3 = resolved_d.get("position", Vector3.ZERO)
	var edge_id: int = int(resolved_d.get("edge_id", (anchor as Dictionary).get("id", -1)))
	var is_stale: bool = bool(resolved_d.get("stale", false))

	var payload: Dictionary = _payload_of(annotation)
	var text: String = str(payload.get("text", payload.get("label", "")))
	var box_offset := _vec3_from_payload(payload.get("box_offset", [0.0, 0.0, 0.0]))
	var leader_end_world: Vector3 = leader_start_world + box_offset

	# Filter to the perspective pane only.
	var panes: Array = host.get_panes()
	for pane in panes:
		if not (pane is Dictionary):
			continue
		var camera: Variant = (pane as Dictionary).get("camera", null)
		if camera == null or not camera.has_method("unproject_position"):
			continue
		if camera.projection != Camera3D.PROJECTION_PERSPECTIVE:
			continue

		var rect: Rect2 = (pane as Dictionary).get("viewport_rect", Rect2())
		var leader_start: Vector2 = camera.unproject_position(leader_start_world) + rect.position

		# Ask the layout helper for a per-frame, per-pane non-overlapping
		# screen position. Falls back to the legacy box_offset back-projection
		# when the helper has no entry for this edge_id (e.g. anchor failed
		# upstream or annotation list is being rebuilt).
		var leader_end: Vector2 = camera.unproject_position(leader_end_world) + rect.position
		if host.has_method("get_annotations"):
			var all_anns: Array = host.get_annotations()
			var layout: Dictionary = _LayoutHelper.get_layout(host, camera, rect, all_anns)
			if layout.has(edge_id):
				leader_end = layout[edge_id]
		_Callout.draw(ctx, leader_start, leader_end, str(edge_id), text, is_stale)


func bounds(annotation: Dictionary) -> Rect2:
	# Returns the on-screen rect of the LABEL BOX (not the leader anchor) in
	# panel-root coordinates. Resolved live via the perspective pane + layout
	# helper, same path render() uses. Returns Rect2() (zero size at origin)
	# only when the annotation can't be projected (no perspective pane,
	# anchor doesn't resolve, host not registered).
	#
	# Used by:
	#   - AnnotationTransformTool to position its 9 gizmo zones (center,
	#     corners, edges, rotate handles) — without this returning the actual
	#     box rect the gizmo collapsed to (0,0) and clicks anywhere "outside"
	#     it dispatched random scale/rotate ratios.
	#   - Substrate fallback consumers (summary, anchored_to lookup) — those
	#     accept Rect2() gracefully so the zero-size return for unprojectable
	#     annotations is still safe.
	return _resolve_box_rect_screen(annotation)


## Return the v2 cad/edge anchor for an annotation. Older agent-authored edge
## labels used payload.edge_id without an anchor; keep that shape renderable so
## live sessions created before the v2 migration do not silently disappear.
static func _anchor_for_annotation(annotation: Dictionary) -> Variant:
	var anchor: Variant = annotation.get("anchor", null)
	if anchor is Dictionary:
		return anchor
	var payload: Dictionary = _payload_of(annotation)
	if payload.has("edge_id"):
		return {
			"plugin": "cad",
			"type": "edge",
			"id": int(payload.get("edge_id", -1)),
		}
	return null


# ── Drag-to-move (substrate AnnotationTranslateTool) ──────────────────────────
#
# The kind opts into drag-and-drop by overriding hit_test (does the cursor sit
# over a label box?) and transform_annotation (apply a screen-space delta to
# payload.box_offset). The tool layer dispatches; we don't manage drag state.
#
# Coordinate notes: CadAnnotationHost identity-maps doc↔screen, so the `point`
# substrate hands us is panel-root screen-space — the same frame the layout
# helper publishes positions in. We resolve the box's current screen position
# the same way render() does: layout helper for un-placed labels (auto-spread),
# raw payload.box_offset back-projection for user-placed ones.

func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var rect := _resolve_box_rect_screen(annotation)
	if rect.size == Vector2.ZERO:
		return false
	return rect.grow(threshold).has_point(point)


## Apply a screen-space transform to the label's text-box position. Sets
## payload.user_placed=true so the auto-spread layout treats this box as a
## fixed obstacle (other labels move around it; this one stays put).
##
## Op filter: scale and rotate are no-ops for this kind. The substrate's
## AnnotationTransformTool dispatches all 9 zone types (translate, scale,
## axis-scale, rotate) but only translate is meaningful for a fixed-size
## edge callout — scaling would just stretch the text box, rotating would
## tilt the text. Returning the annotation unchanged for non-translate ops
## means the user can grab a scale/rotate handle harmlessly without the
## label moving in unrecoverable ways.
func transform_annotation(
		annotation: Dictionary,
		transform: Transform2D,
		operation: String = ""
) -> Dictionary:
	# Empty operation == legacy translate path (AnnotationTranslateTool, plus
	# any caller that doesn't pass an operation tag). Accept those alongside
	# the explicit "translate" tag emitted by AnnotationTransformTool's
	# Zone.INSIDE branch.
	if operation != "" and operation != "translate":
		return annotation.duplicate(true)

	var ctx := _resolve_perspective_ctx_for_annotation(annotation)
	if ctx.is_empty():
		# No perspective camera + anchor available — leave annotation untouched.
		return annotation.duplicate(true)

	var camera: Camera3D = ctx["camera"]
	var rect: Rect2 = ctx["viewport_rect"]
	var anchor_world: Vector3 = ctx["anchor_world"]
	var current_box_screen: Vector2 = ctx["box_screen"]

	# Apply the screen-space delta. Transform2D from the translate tool is a
	# pure translation in panel-root space (origin = drag delta).
	var new_box_screen: Vector2 = transform * current_box_screen

	# Back-project to a world-space leader_end at the same camera depth as the
	# anchor. Same algorithm as cad_edge_number_tool._compute_default_box_offset
	# (kept inline rather than imported to avoid an extra preload cycle).
	var new_box_offset := _back_project_to_world_offset(camera, rect, anchor_world, new_box_screen)

	var out := annotation.duplicate(true)
	var payload: Dictionary = _payload_of(out).duplicate(true)
	payload["box_offset"] = [new_box_offset.x, new_box_offset.y, new_box_offset.z]
	payload["user_placed"] = true
	out[_payload_key(out)] = payload
	return out


## Compute the on-screen rect for an annotation's text box, using the same
## resolution path render() uses. Returns Rect2() (zero size) when the box is
## not currently rendered (no perspective pane, anchor unresolvable, etc.) —
## callers should treat that as "not hittable".
func _resolve_box_rect_screen(annotation: Dictionary) -> Rect2:
	var ctx := _resolve_perspective_ctx_for_annotation(annotation)
	if ctx.is_empty():
		return Rect2()
	var center: Vector2 = ctx["box_screen"]
	# Use a conservative footprint covering the kind's actual draw size. The
	# real box can be larger when payload.text wraps to many lines, but the
	# title strip alone is enough for grab-handle hit-testing — and the
	# substrate caller adds its own threshold via grow().
	var size := Vector2(_BOX_WIDTH, 56.0)
	return Rect2(center - size * 0.5, size)


## Resolve the perspective pane + anchor + current box screen position for an
## annotation. Returns an empty Dictionary when any prerequisite is missing
## (no perspective camera, anchor not resolvable, host lacks methods).
##
## Returned keys: camera, viewport_rect, anchor_world, anchor_screen, box_screen.
func _resolve_perspective_ctx_for_annotation(annotation: Dictionary) -> Dictionary:
	var anchor: Variant = _anchor_for_annotation(annotation)
	if not (anchor is Dictionary):
		return {}
	# We need an AnnotationRenderContext-like host reference, but transform_/hit_
	# are called without a ctx — the substrate hands us only the annotation
	# itself. Reach the host via the static EditorRegistry so the kind can
	# self-resolve. Keeps the kind's interface compatible with the substrate
	# tool layer (which doesn't pass a ctx to manipulation calls).
	var host: Object = _find_host_for_annotation(annotation)
	if host == null:
		return {}
	if not host.has_method("get_panes") or not host.has_method("_resolve_edge_anchor"):
		return {}

	var resolved: Variant = host._resolve_edge_anchor(anchor)
	if not (resolved is Dictionary):
		return {}
	var resolved_d: Dictionary = resolved as Dictionary
	var anchor_world: Vector3 = resolved_d.get("position", Vector3.ZERO)
	var edge_id: int = int(resolved_d.get("edge_id", anchor.get("id", -1)))

	var panes: Array = host.get_panes()
	for pane in panes:
		if not (pane is Dictionary):
			continue
		var camera: Variant = (pane as Dictionary).get("camera", null)
		if camera == null or not (camera is Camera3D):
			continue
		var cam3 := camera as Camera3D
		if cam3.projection != Camera3D.PROJECTION_PERSPECTIVE:
			continue
		var rect: Rect2 = (pane as Dictionary).get("viewport_rect", Rect2())
		var anchor_screen: Vector2 = cam3.unproject_position(anchor_world) + rect.position

		# Determine current box screen position. user_placed labels: use
		# payload.box_offset directly (back-projected). Otherwise: ask the
		# layout helper, which is the source of truth for auto-spread.
		# Un-placed branch additionally caches the result keyed by start
		# state + camera so subsequent transform_annotation calls within a
		# drag see the same start_box_screen (see _drag_start_box_screen_cache
		# header for the substrate contract that makes this necessary).
		var payload: Dictionary = _payload_of(annotation)
		var user_placed: bool = bool(payload.get("user_placed", false))
		var box_screen: Vector2
		if user_placed:
			var box_offset := _vec3_from_payload(payload.get("box_offset", [0.0, 0.0, 0.0]))
			box_screen = cam3.unproject_position(anchor_world + box_offset) + rect.position
		else:
			var ann_id_str: String = str(annotation.get("id", ""))
			var start_offset_arr: Array = payload.get("box_offset", [0.0, 0.0, 0.0])
			var cache_key: Array = [
				ann_id_str,
				start_offset_arr,
				cam3.global_transform.basis,
				cam3.global_transform.origin,
				rect,
			]
			if ann_id_str != "" and _drag_start_box_screen_cache.has(cache_key):
				box_screen = _drag_start_box_screen_cache[cache_key]
			else:
				var all_anns: Array = host.get_annotations() if host.has_method("get_annotations") else []
				var layout: Dictionary = _LayoutHelper.get_layout(host, cam3, rect, all_anns)
				if layout.has(edge_id):
					box_screen = layout[edge_id]
				else:
					var box_offset2 := _vec3_from_payload(start_offset_arr)
					box_screen = cam3.unproject_position(anchor_world + box_offset2) + rect.position
				if ann_id_str != "":
					_drag_start_box_screen_cache[cache_key] = box_screen

		return {
			"camera": cam3,
			"viewport_rect": rect,
			"anchor_world": anchor_world,
			"anchor_screen": anchor_screen,
			"box_screen": box_screen,
		}
	return {}


## Locate the AnnotationHost that owns this annotation. The substrate keeps
## annotations in a host's _annotations array; we walk the registry to find
## the one whose list contains this annotation's id. Returns null when the
## annotation is orphaned (never registered, or already removed).
static func _find_host_for_annotation(annotation: Dictionary) -> Object:
	var ann_id: String = str(annotation.get("id", ""))
	if ann_id == "":
		return null
	# AnnotationHostRegistry exposes list_editor_names() + get_host() only;
	# walk by name. Empty list when no panels are open — caller treats null
	# host as "drag is not currently possible," same as a freed panel.
	for editor_name in AnnotationHostRegistry.list_editor_names():
		var h: AnnotationHost = AnnotationHostRegistry.get_host(str(editor_name))
		if h == null or not h.has_method("get_annotations"):
			continue
		for a in h.get_annotations():
			if a is Dictionary and str((a as Dictionary).get("id", "")) == ann_id:
				return h
	return null


## Back-project a screen-space target point to a world-space offset relative
## to anchor_world, at the anchor's camera depth. Mirrors the algorithm in
## cad_edge_number_tool._compute_default_box_offset.
static func _back_project_to_world_offset(
		camera: Camera3D,
		viewport_rect: Rect2,
		anchor_world: Vector3,
		target_screen_panel: Vector2
) -> Vector3:
	var cam_origin: Vector3 = camera.global_transform.origin
	var look_dir: Vector3 = -camera.global_transform.basis.z.normalized()
	var depth: float = look_dir.dot(anchor_world - cam_origin)
	if depth < 0.001:
		return Vector3.ZERO
	# Translate panel-root screen back to viewport-local before project_ray_*.
	var target_local: Vector2 = target_screen_panel - viewport_rect.position
	var ray_origin: Vector3 = camera.project_ray_origin(target_local)
	var ray_dir: Vector3 = camera.project_ray_normal(target_local)
	var dz: float = look_dir.dot(ray_dir)
	if abs(dz) < 0.001:
		return Vector3.ZERO
	var t: float = (depth - look_dir.dot(ray_origin - cam_origin)) / dz
	var world_target: Vector3 = ray_origin + ray_dir * t
	return world_target - anchor_world


# ── author_ui ────────────────────────────────────────────────────────────────

## Returns a fresh cad_edge_number_tool instance so the AnnotationToolbar can
## activate click-to-add authoring. Each call returns a NEW instance to avoid
## stale state leaking across deactivate/reactivate cycles.
func author_ui() -> Object:
	return _CadEdgeNumberToolScript.new()


# ── Private drawing helpers ───────────────────────────────────────────────────

static func _vec3_from_payload(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		return Vector3(float((raw as Array)[0]), float((raw as Array)[1]), float((raw as Array)[2]))
	return Vector3.ZERO
