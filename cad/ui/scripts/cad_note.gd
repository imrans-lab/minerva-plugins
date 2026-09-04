extends RefCounted
## cad_note.gd — the CAD panel's half of the three host note hooks.
##
## The host offers a plugin panel three duck-typed hooks (see Minerva's
## PluginScenePanelHost): build a note, restore a tab from one, and render the
## tab for a language model. This module owns all three payloads; CADPanel
## keeps only the wiring, because none of this is about the panel's widgets.
##
## WHAT A CAD NOTE IS. Not a picture of a model — the model's SOURCE, the file
## it came from, the reference meshes the evaluation named, and where the
## cameras were pointing. Opening the note re-evaluates the same source in a
## fresh tab and puts the view back, so the note is a bookmark into live work
## rather than a screenshot of finished work.
##
## THE PAYLOAD IS JSON. The host stringifies it (Note.create_plugin_data_note),
## so nothing structural may cross the boundary: no Vector3, no Transform3D, no
## AABB, no PackedStringArray. Everything here is String / float / bool / Array
## / Dictionary, and the restore half re-reads numbers with float()/int()
## because JSON.parse hands every number back as a float.
##
## THE VERSION IS A REFUSAL, NOT A HINT. restore() rejects any payload whose
## schema or version it does not know, loudly, so a note written by a future
## build fails visibly instead of half-restoring into a tab that looks right.
##
## WHY THE CAMERA IS APPLIED TWICE. Every evaluation auto-frames each pane
## (mesh_display._auto_frame retargets the OrbitCamera on the mesh it just
## received), so a camera applied before the restore's evaluation lands is
## overwritten by it. restore() therefore applies the camera immediately — the
## answer when the evaluation fails or never runs — and leaves the same camera
## parked on the panel as metadata, which the panel hands back to
## apply_pending_camera() once the evaluation has re-framed. The second
## application is the one that usually wins, and it happens exactly once.
##
## Off-tree note: no class_name — preloaded by relative path from CADPanel.gd.

const _ReferenceMeshes: Script = preload("reference_meshes.gd")

## Payload identity. `schema` names the shape and `version` its revision; a
## payload carrying neither is not ours, and one carrying a version we do not
## implement is refused rather than guessed at.
const SCHEMA: String = "cad.document"
const VERSION: int = 1

## The panes whose cameras ride in the note. In narrow layout every id resolves
## to the one visible pane, so saving all four costs one repeated camera and
## restoring all four is idempotent.
const SAVED_VIEWS: Array = ["iso", "top", "front", "right"]

## The pane the note's preview and the LLM's image come from. Iso is the only
## pane that shows the shaded solid (the ortho panes are x-rayed), so it is the
## one worth a picture.
const PREVIEW_VIEW: String = "iso"

## Where restore() parks the camera it wants re-applied after the evaluation
## that follows it. Panel metadata rather than a CADPanel field: the state
## belongs to this module's two-step, and nothing else in the panel reads it.
const PENDING_CAMERA_META: StringName = &"cad_note_pending_camera"


# ---------------------------------------------------------------------------
# Panel -> Note
# ---------------------------------------------------------------------------

## Build the plugin_data note for the tab `panel` is showing.
##
## A coroutine: the host awaits this hook precisely so a panel may yield a
## frame to get a picture. The annotation host captures on frame_post_draw, so
## a cold panel has no cached image until a frame has been drawn — we ask, wait
## a frame, and ask again. When there is still no image we omit preview_image
## entirely and the host backfills it with its own screenshot; the note is
## still plugin_data and still reopens.
static func build_note(ctx: Dictionary, panel: Node) -> Dictionary:
	var payload: Dictionary = build_payload(panel)
	var title: String = str(ctx.get("tab_title", ""))
	if title.is_empty():
		title = "CAD"
	var note: Dictionary = {
		"kind": "plugin_data",
		"title": title,
		"plugin_id": str(ctx.get("plugin_id", "cad")),
		"panel_name": str(ctx.get("panel_name", "cad_panel")),
		"payload": payload,
		"preview_alt_text": describe(panel, payload),
	}
	var image: Image = await capture_preview(panel)
	if image != null:
		note["preview_image"] = image
	return note


## The note's restorable state. Public so a test — or a later verb — can read
## exactly what the note carries without going through the host.
static func build_payload(panel: Node) -> Dictionary:
	return {
		"schema": SCHEMA,
		"version": VERSION,
		"source": _source_of(panel),
		"document_path": _document_path_of(panel),
		"cameras": cameras_of(panel),
		# The mesh() specs the last evaluation named, verbatim: name, path,
		# pose matrix, units and up. Carried so the reopened tab can mount its
		# references before the worker has answered, and so the note still
		# says what the document referred to when the worker is not running.
		"references": reference_specs(panel),
		"saved_at": Time.get_unix_time_from_system(),
	}


## Per-pane camera state, JSON-safe. Reads OrbitCamera's own accessors — this
## module adds no camera state of its own.
static func cameras_of(panel: Node) -> Dictionary:
	var out: Dictionary = {}
	for view in SAVED_VIEWS:
		var camera: Camera3D = _camera_for(panel, str(view))
		if camera == null:
			continue
		var state: Dictionary = {}
		if camera.has_method("get_debug_state"):
			state["view_preset"] = str(camera.get_debug_state().get("view_preset", ""))
		if camera.has_method("get_target"):
			state["target"] = _vec(camera.get_target())
		if camera.has_method("get_distance"):
			state["distance"] = float(camera.get_distance())
		if camera.has_method("get_yaw"):
			state["yaw"] = float(camera.get_yaw())
		if camera.has_method("get_pitch"):
			state["pitch"] = float(camera.get_pitch())
		if not state.is_empty():
			out[str(view)] = state
	return out


## The evaluation's own reference entries ({name, path, matrix, units, up}),
## JSON-safe and stripped of anything the mount does not read.
static func reference_specs(panel: Node) -> Array:
	var out: Array = []
	var raw: Variant = _state_of(panel).get("references", [])
	if not (raw is Array):
		return out
	for entry in raw as Array:
		if not (entry is Dictionary):
			continue
		var reference: Dictionary = entry
		var spec: Dictionary = {
			"name": str(reference.get("name", "")),
			"path": str(reference.get("path", "")),
			"units": str(reference.get("units", "")),
			"up": str(reference.get("up", "")),
			"matrix": _matrix_rows(reference.get("matrix", [])),
		}
		out.append(spec)
	return out


# ---------------------------------------------------------------------------
# Note -> Panel
# ---------------------------------------------------------------------------

## Rebuild a CAD tab from a payload this module wrote.
##
## Returns false — and says why in a warning — for anything it does not
## recognise, which is the host's cue to toast and leave the tab blank. A
## partially restored tab that looks plausible is the failure worth avoiding:
## the user would go on editing a document that is not the one they saved.
static func restore(payload: Dictionary, panel: Node) -> bool:
	var problem: String = validation_error(payload)
	if not problem.is_empty():
		push_warning("[cad] restore_from_note: %s" % problem)
		return false
	if panel == null or not panel.has_method("adopt_restored_document"):
		push_warning("[cad] restore_from_note: panel cannot adopt a document")
		return false

	var cameras: Dictionary = payload.get("cameras", {}) as Dictionary
	# Parked BEFORE the adopt: the evaluation the adopt starts re-frames every
	# pane, and this is what puts the user's view back afterwards.
	panel.set_meta(PENDING_CAMERA_META, cameras)

	panel.adopt_restored_document(
		str(payload.get("document_path", "")),
		str(payload.get("source", "")),
		_specs_from_payload(payload)
	)

	# The answer for a document that never evaluates — empty source, a dead
	# worker, an evaluation that errors. When one does land, the panel calls
	# apply_pending_camera() and this is applied again over the auto-frame.
	apply_cameras(panel, cameras)
	return true


## Why `payload` cannot be restored, or "" when it can. Split out from
## restore() so the refusal is one readable rule set rather than a ladder of
## early returns inside the side-effecting half.
static func validation_error(payload: Variant) -> String:
	if not (payload is Dictionary):
		return "payload is not a Dictionary"
	var d: Dictionary = payload as Dictionary
	var schema: String = str(d.get("schema", ""))
	if schema != SCHEMA:
		return "payload schema '%s' is not '%s'" % [schema, SCHEMA]
	# JSON.parse returns every number as a float, so read the version through
	# int() rather than comparing types.
	var version: int = int(d.get("version", 0))
	if version != VERSION:
		return "payload version %d is not %d — this note was written by a different build" % [
			version, VERSION]
	if not (d.get("source", "") is String):
		return "payload.source is not a String"
	if not (d.get("cameras", {}) is Dictionary):
		return "payload.cameras is not a Dictionary"
	return ""


## Apply saved per-pane camera state. Preset first: OrbitCamera.set_view_preset
## re-derives the whole transform (and switches projection), so setting it
## after the target/orbit would throw them away.
static func apply_cameras(panel: Node, cameras: Dictionary) -> void:
	for view in cameras.keys():
		var state_v: Variant = cameras[view]
		if not (state_v is Dictionary):
			continue
		var state: Dictionary = state_v as Dictionary
		var camera: Camera3D = _camera_for(panel, str(view))
		if camera == null:
			continue
		var preset: String = str(state.get("view_preset", ""))
		if not preset.is_empty() and camera.has_method("set_view_preset"):
			camera.set_view_preset(preset)
		if state.has("target") and camera.has_method("set_target"):
			camera.set_target(_to_vec(state.get("target")))
		if state.has("distance") and camera.has_method("set_distance"):
			camera.set_distance(float(state.get("distance", 0.0)))
		if camera.has_method("set_orbit"):
			camera.set_orbit(float(state.get("yaw", 0.0)), float(state.get("pitch", 0.0)))


## Re-apply the camera a restore parked, once, after the evaluation that
## followed it has auto-framed the panes. A no-op on every other evaluation.
static func apply_pending_camera(panel: Node) -> void:
	if panel == null or not panel.has_meta(PENDING_CAMERA_META):
		return
	var cameras_v: Variant = panel.get_meta(PENDING_CAMERA_META)
	panel.remove_meta(PENDING_CAMERA_META)
	if cameras_v is Dictionary:
		apply_cameras(panel, cameras_v as Dictionary)


# ---------------------------------------------------------------------------
# Panel -> LLM
# ---------------------------------------------------------------------------

## The canonical MultimodalPayload for chat injection: the iso pane as an
## image, and one text part describing what is in it.
##
## NOT a coroutine — the host does not await this hook, and a hook that yields
## would hand it a coroutine state instead of an Array. The image therefore
## comes from whatever the pane has already drawn; the text part is always
## produced, so a panel that cannot yet supply a picture still says something
## useful rather than nothing.
static func render_parts(panel: Node, _render_ctx: Dictionary = {}) -> Array:
	var parts: Array = []
	var image: Image = capture_now(panel, PREVIEW_VIEW)
	if image != null:
		parts.append({
			"type": "image",
			"image": image,
			"alt": describe(panel, {}),
		})
	parts.append({"type": "text", "text": summarise(panel)})
	return parts


## The whole document in prose: where it came from, what the last evaluation
## made of it, the bounds of the solid, every reference with its status and its
## bounds, and where the camera is. Millimetres throughout, matching the rest
## of the CAD surface.
static func summarise(panel: Node) -> String:
	var lines: PackedStringArray = PackedStringArray()
	var path: String = _document_path_of(panel)
	lines.append("CAD document: %s" % (path if not path.is_empty() else "(unsaved)"))
	lines.append("All coordinates are millimetres; bounds are axis-aligned.")
	lines.append(_evaluation_line(panel))

	var solid: AABB = solid_bounds(panel)
	if solid.size != Vector3.ZERO:
		lines.append("Solid bounds: %s" % _box(solid))
	else:
		lines.append("Solid bounds: none — this document evaluates to no solid.")

	var records: Array = _reference_records(panel)
	if records.is_empty():
		lines.append("References: none — the document names no mesh().")
	else:
		lines.append("References (%d):" % records.size())
		for entry in records:
			lines.append("  - %s" % _reference_line(entry as Dictionary))

	var camera_line: String = _camera_line(panel)
	if not camera_line.is_empty():
		lines.append(camera_line)

	var source: String = _source_of(panel)
	if not source.is_empty():
		lines.append("Source (.mcad):")
		lines.append(source)
	return "\n".join(lines)


## One line naming the document and what is in it — the note's alt text and the
## image part's alt. `payload` is optional and only used to avoid re-reading
## the panel when the caller already has one.
static func describe(panel: Node, payload: Dictionary = {}) -> String:
	var references: Array = payload.get("references", null) if payload.has("references") \
		else _reference_records(panel)
	var name: String = _document_path_of(panel).get_file()
	if name.is_empty():
		name = "unsaved CAD document"
	var solid: AABB = solid_bounds(panel)
	var extent: String = "no solid"
	if solid.size != Vector3.ZERO:
		extent = "%.1f x %.1f x %.1f mm" % [solid.size.x, solid.size.y, solid.size.z]
	return "CAD: %s — %s, %d reference mesh%s" % [
		name, extent, references.size(), "" if references.size() == 1 else "es"]


## Bounds of the evaluated solid, in millimetres, or a zero AABB when there is
## no solid.
##
## The worker emits vertices as [[x, y, z], ...] (evaluator.py); a flat float
## array is accepted too, because reading the mesh should not be the thing that
## breaks if that ever changes.
static func solid_bounds(panel: Node) -> AABB:
	var vertices: Variant = _mesh_data(panel).get("vertices", [])
	if not (vertices is Array) or (vertices as Array).is_empty():
		return AABB()
	var verts: Array = vertices as Array
	var lo: Vector3 = Vector3.ZERO
	var hi: Vector3 = Vector3.ZERO
	var have: bool = false
	if verts[0] is Array:
		for v in verts:
			if not (v is Array) or (v as Array).size() < 3:
				continue
			var p := Vector3(float(v[0]), float(v[1]), float(v[2]))
			lo = p if not have else lo.min(p)
			hi = p if not have else hi.max(p)
			have = true
	else:
		var count: int = verts.size() - (verts.size() % 3)
		for i in range(0, count, 3):
			var p2 := Vector3(float(verts[i]), float(verts[i + 1]), float(verts[i + 2]))
			lo = p2 if not have else lo.min(p2)
			hi = p2 if not have else hi.max(p2)
			have = true
	return AABB(lo, hi - lo) if have else AABB()


## How many vertices the solid actually has, counted the same way the bounds
## are. Reported rather than taken from the panel's last_eval, which divides a
## nested-triple array by three.
static func vertex_count(panel: Node) -> int:
	var vertices: Variant = _mesh_data(panel).get("vertices", [])
	if not (vertices is Array):
		return 0
	var verts: Array = vertices as Array
	if verts.is_empty():
		return 0
	return verts.size() if verts[0] is Array else int(verts.size() / 3)


# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

## The preview image for a note. Asks the annotation host, waits one drawn
## frame if it has nothing cached yet, and asks again. Returns null when there
## is still no picture — the host's own screenshot then stands in.
static func capture_preview(panel: Node) -> Image:
	var image: Image = capture_now(panel, PREVIEW_VIEW)
	if image != null:
		return image
	var tree: SceneTree = panel.get_tree() if panel != null else null
	if tree == null:
		return null
	# The host's capture is scheduled on frame_post_draw, so a frame has to be
	# drawn before it can have anything; a second is cheap insurance against
	# landing between the schedule and the draw.
	await tree.process_frame
	await tree.process_frame
	return capture_now(panel, PREVIEW_VIEW)


## A pane's pixels, synchronously, or null.
##
## Two routes to the same picture. The annotation host's per-frame cache is
## preferred: it is the one the snapshot verb and the overlay renderer already
## use, so a note shows what an agent's snapshot would. It answers null until a
## frame has been captured, so the fallback pulls the pane's SubViewport
## texture directly — the same call the host makes, made now instead of on the
## next frame_post_draw.
static func capture_now(panel: Node, view: String) -> Image:
	if panel == null:
		return null
	if panel.has_method("get_annotation_host"):
		var host: Object = panel.get_annotation_host()
		if host != null and host.has_method("render_view_to_image"):
			var cached: Image = host.render_view_to_image(view, Rect2()) as Image
			if cached != null:
				return cached
	var camera: Camera3D = _camera_for(panel, view)
	if camera == null:
		return null
	var viewport: Viewport = camera.get_viewport()
	if viewport == null:
		return null
	var texture: ViewportTexture = viewport.get_texture()
	return texture.get_image() if texture != null else null


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

static func _camera_for(panel: Node, view: String) -> Camera3D:
	if panel == null or not panel.has_method("get_view_camera"):
		return null
	return panel.get_view_camera(view) as Camera3D


## The panel's document facts, read in one call: {source, path, last_eval,
## mesh, references}. Empty for anything that is not a CAD panel, so every
## reader below degrades to "nothing known" rather than to an error.
static func _state_of(panel: Node) -> Dictionary:
	if panel == null or not panel.has_method("get_document_state"):
		return {}
	var state: Variant = panel.get_document_state()
	return state as Dictionary if state is Dictionary else {}


static func _source_of(panel: Node) -> String:
	return str(_state_of(panel).get("source", ""))


static func _document_path_of(panel: Node) -> String:
	return str(_state_of(panel).get("path", ""))


static func _active_view_of(panel: Node) -> String:
	if panel == null or not panel.has_method("get_view_state"):
		return PREVIEW_VIEW
	return str(panel.get_view_state().get("active_viewport_id", PREVIEW_VIEW))


static func _mesh_data(panel: Node) -> Dictionary:
	var mesh: Variant = _state_of(panel).get("mesh", {})
	return mesh as Dictionary if mesh is Dictionary else {}


## Every reference the last evaluation named, loaded or not — the reporting
## surface, so a failed reference is described rather than omitted.
static func _reference_records(panel: Node) -> Array:
	if panel == null or not panel.has_method("get_reference_status"):
		return []
	return panel.get_reference_status()


## Reference specs read back out of a parsed payload, with the numbers coerced:
## JSON.parse turns the pose matrix into nested float arrays, which is what
## reference_meshes.transform_from_matrix wants anyway, but a hand-built or
## truncated matrix must not reach it as strings.
static func _specs_from_payload(payload: Dictionary) -> Array:
	var raw: Variant = payload.get("references", [])
	if not (raw is Array):
		return []
	var out: Array = []
	for entry in raw as Array:
		if not (entry is Dictionary):
			continue
		var spec: Dictionary = entry as Dictionary
		out.append({
			"name": str(spec.get("name", "")),
			"path": str(spec.get("path", "")),
			"units": str(spec.get("units", "")),
			"up": str(spec.get("up", "")),
			"matrix": _matrix_rows(spec.get("matrix", [])),
		})
	return out


## A 4x4 row-major pose as plain nested floats. Anything that is not four rows
## of four numbers comes back empty, which transform_from_matrix reads as the
## identity — a reference at the origin rather than a reference at a garbage
## pose.
static func _matrix_rows(matrix: Variant) -> Array:
	if not (matrix is Array) or (matrix as Array).size() != 4:
		return []
	var rows: Array = []
	for row_v in matrix as Array:
		if not (row_v is Array) or (row_v as Array).size() != 4:
			return []
		var row: Array = []
		for value in row_v as Array:
			row.append(float(value))
		rows.append(row)
	return rows


static func _evaluation_line(panel: Node) -> String:
	var last_v: Variant = _state_of(panel).get("last_eval", {})
	var last: Dictionary = last_v as Dictionary if last_v is Dictionary else {}
	var status: String = str(last.get("status", "unknown"))
	if status == "ok":
		var shape: String = str(last.get("shape_name", ""))
		return "Last evaluation: ok%s — %d vertices, %d edges." % [
			" (shape '%s')" % shape if not shape.is_empty() else "",
			vertex_count(panel),
			int(last.get("edge_count", 0)),
		]
	var message: String = str(last.get("error_message", ""))
	if message.is_empty():
		return "Last evaluation: %s." % status
	return "Last evaluation: %s — %s" % [status, message]


static func _reference_line(record: Dictionary) -> String:
	var name: String = str(record.get("name", "?"))
	var status: String = str(record.get("status", _ReferenceMeshes.STATUS_OK))
	var path: String = str(record.get("resolved_path", ""))
	if path.is_empty():
		path = str(record.get("path", ""))
	if status != _ReferenceMeshes.STATUS_OK:
		var reason: String = str(record.get("reason", ""))
		return "%s (%s) — %s%s" % [
			name, path, status, ": %s" % reason if not reason.is_empty() else ""]
	var world: AABB = record.get("world_aabb", AABB())
	var local: AABB = record.get("local_aabb", AABB())
	var warning: String = str(record.get("warning", ""))
	return "%s (%s) — ok, %d triangles; world %s; local %s%s" % [
		name,
		path,
		int(record.get("triangle_count", 0)),
		_box(world),
		_box(local),
		"; %s" % warning if not warning.is_empty() else "",
	]


static func _camera_line(panel: Node) -> String:
	var view: String = _active_view_of(panel)
	var camera: Camera3D = _camera_for(panel, view)
	if camera == null or not camera.has_method("get_target"):
		return ""
	var preset: String = ""
	if camera.has_method("get_debug_state"):
		preset = str(camera.get_debug_state().get("view_preset", ""))
	return "Camera (%s pane, %s): looking at (%.1f, %.1f, %.1f) from %.1f mm away." % [
		view, preset,
		camera.get_target().x, camera.get_target().y, camera.get_target().z,
		camera.get_distance() if camera.has_method("get_distance") else 0.0,
	]


static func _box(box: AABB) -> String:
	var hi: Vector3 = box.position + box.size
	return "min (%.2f, %.2f, %.2f) max (%.2f, %.2f, %.2f)" % [
		box.position.x, box.position.y, box.position.z, hi.x, hi.y, hi.z]


static func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _to_vec(value: Variant) -> Vector3:
	if not (value is Array) or (value as Array).size() < 3:
		return Vector3.ZERO
	var a: Array = value as Array
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
