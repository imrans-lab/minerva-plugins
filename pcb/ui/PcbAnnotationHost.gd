extends AnnotationHost
## AnnotationHost for the PCB plugin panel (walking-skeleton form).
##
## Produces v2 annotation envelopes that pass
## AnnotationV2Schema.validate_with_registry — the envelope shape is copied from
## the ONLY conformant reference host, Minerva core's TextEditorAnnotationHost
## (NOT CadAnnotationHost, which emits `payload` instead of `kind_payload`, omits
## lifecycle/visible_in_views/summary, and never validates — gap register C-32).
##
## Anchor type handled: pcb/board.point
##   anchor.id                 = {x: mm, y: mm}   (board millimetres)
##   anchor.snapshot.position  = [x_mm, y_mm]
##
## Sidecar file: <board_path>.annotations.json (via core AnnotationSidecar).
##
## Off-tree note: lives at C:/github/minerva-plugins/pcb/ui/, OUTSIDE Minerva's
## res:// tree. It MUST NOT declare a class_name (plugin-local class_names are
## unresolvable off-tree). Extends the core AnnotationHost class (which IS in
## res:// and resolvable). Loaded via preload()/load() by PCBPanel.gd and tests.

signal annotations_changed()

const _ANN_ID_PREFIX := "ann_"
const _ANCHOR_TYPE := "pcb/board.point"
const _SCHEMA := preload("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")
const _PcbRouteHintKindScript: Script = preload("kinds/pcb_route_hint_kind.gd")

## Storage: Array of v2 envelope Dictionaries.
var _annotations: Array = []

## Monotonic id counter for generated envelope ids.
var _id_counter: int = 0

## Per-host kind registry (built-in kinds + pcb_route_hint).
var _registry: AnnotationRegistry = null

## Board document path (for sidecar resolution). Empty for anonymous editors.
var _document_path: String = ""

## Live board canvas (pcb_canvas.gd Control, duck-typed) — the source of the
## board-mm↔screen pan/zoom transform and the board data model. Null when the
## host runs headless / before mount, in which case every transform is identity
## and describe_point falls back to a bare board point (never crashes).
var _canvas = null

## Optional panel back-reference (duck-typed). Not required by the transforms —
## the canvas carries pan/zoom AND the data model — but kept as a fallback data
## source for describe_point and for future panel-level state needs.
var _panel = null

## Board-mm proximity for a pad/pin hit in describe_point (precedence tier 1).
const _PAD_HIT_RADIUS_MM := 1.0

## Board-mm proximity for a trace hit in describe_point (precedence tier 3).
## ~half a typical 0.25 mm trace; is_point_near adds width/2 on top.
const _TRACE_HIT_THRESHOLD_MM := 0.3


func _init() -> void:
	super._init()
	register_anchor_resolver(_ANCHOR_TYPE, Callable(self, "_resolve_board_point"))
	_registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(_registry)
	_registry.register_annotation_kind(_PcbRouteHintKindScript.new())


# ── AnnotationHost overrides ──────────────────────────────────────────────────

func get_registry() -> AnnotationRegistry:
	return _registry


func get_capabilities() -> Dictionary:
	return {
		"kinds": ["pcb_route_hint"],
		"tools": ["select"],
		"anchor_types": [_ANCHOR_TYPE],
		"lifecycle": {
			"resolve": true,
			"reopen": true,
			"delete": true,
			"repair": false,
			"apply": false,
		},
		"authoring": {
			"add": true,
			"domain_pickers": false,
		},
		"panes": false,
		"body_views": false,
		"filters": ["all", "open", "applied", "resolved", "broken"],
	}


func get_document_identity() -> Dictionary:
	return {
		"kind": "pcb",
		"path": _document_path,
		"display_name": _document_path.get_file() if not _document_path.is_empty() else "PCB",
		"save_policy": "sidecar",
	}


func get_view_context() -> String:
	# Walking skeleton: one flat "pcb" context. Layer-aware "pcb:F.Cu" sub-context
	# is a platform gap (register C-23) deferred to a later round.
	return "pcb"


func set_document_path(path: String) -> void:
	_document_path = path


# ── Board-space transforms (bound to the live canvas) ─────────────────────────
#
# Fixes gap-register W-9: route-hint markers must track board coordinates through
# zoom/pan. The ported canvas (pcb_canvas.gd) maps board-mm → canvas-local pixels
# as  screen = board_mm * zoom + pan_offset + size/2  (its world_to_screen). We
# expose that exact affine as a Transform2D so AnnotationOverlay renders markers
# at their board-mm positions under any zoom/pan and inverse-maps pointer input
# back to board-mm for click-to-author. No bound canvas → identity (headless).
#
# View-context note: get_view_context() stays flat "pcb" here; the layer-aware
# "pcb:F.Cu" sub-context is platform item 019f33d2c9bf, not this round.

## Bind the live board canvas (duck-typed). PCBPanel calls this from _build_ui
## once the canvas exists, and set_canvas(null) on teardown. Connects the canvas
## pan/zoom/resize notifications so the annotation overlay re-renders (via the
## base view_changed signal) whenever the board view moves — the redraw poke.
func set_canvas(canvas) -> void:
	if _canvas == canvas:
		return
	_disconnect_canvas()
	_canvas = canvas
	_connect_canvas()
	# The transform just changed wholesale; ask the overlay to re-render.
	view_changed.emit()


## Optional panel back-reference used as a fallback data source (duck-typed).
func set_panel(panel) -> void:
	_panel = panel


func _connect_canvas() -> void:
	if _canvas == null or not is_instance_valid(_canvas):
		return
	# The canvas emits view_changed on pan/zoom/fit/center; resized is the
	# built-in Control signal (size feeds the transform's size/2 term).
	if _canvas.has_signal("view_changed") and not _canvas.view_changed.is_connected(_on_canvas_view_changed):
		_canvas.view_changed.connect(_on_canvas_view_changed)
	if _canvas.has_signal("resized") and not _canvas.resized.is_connected(_on_canvas_view_changed):
		_canvas.resized.connect(_on_canvas_view_changed)


func _disconnect_canvas() -> void:
	if _canvas == null or not is_instance_valid(_canvas):
		return
	if _canvas.has_signal("view_changed") and _canvas.view_changed.is_connected(_on_canvas_view_changed):
		_canvas.view_changed.disconnect(_on_canvas_view_changed)
	if _canvas.has_signal("resized") and _canvas.resized.is_connected(_on_canvas_view_changed):
		_canvas.resized.disconnect(_on_canvas_view_changed)


## Canvas pan/zoom/resize → base view_changed so AnnotationOverlay redraws.
func _on_canvas_view_changed() -> void:
	view_changed.emit()


## The live board-mm → canvas-local-pixel affine, or identity when no canvas is
## bound. Mirrors pcb_canvas.world_to_screen exactly.
func _live_view_transform() -> Transform2D:
	if _canvas == null or not is_instance_valid(_canvas):
		return Transform2D.IDENTITY
	var z := float(_canvas.zoom)
	var origin: Vector2 = (_canvas.pan_offset as Vector2) + (_canvas.size as Vector2) / 2.0
	return Transform2D(Vector2(z, 0.0), Vector2(0.0, z), origin)


## Board-mm → screen (overlay-local pixels).
func transform_doc_to_screen(p: Vector2) -> Vector2:
	return _live_view_transform() * p


## Screen (overlay-local pixels) → board-mm.
func transform_screen_to_doc(p: Vector2) -> Vector2:
	return _live_view_transform().affine_inverse() * p


## Affine DOCUMENT(board-mm) → screen used by AnnotationOverlay for render +
## inverse pointer mapping.
func get_annotation_view_transform() -> Transform2D:
	return _live_view_transform()


## Screen-pixels-per-board-mm scale hint (kinds size strokes/glyphs off it).
func get_annotation_zoom() -> float:
	if _canvas == null or not is_instance_valid(_canvas):
		return 1.0
	return float(_canvas.zoom)


## Resolve the live board data model (pcb_data.gd), preferring the canvas's model
## and falling back to the panel's. Null when neither is wired (headless).
func _board_data():
	if _canvas != null and is_instance_valid(_canvas) and "data" in _canvas and _canvas.data != null:
		return _canvas.data
	if _panel != null and is_instance_valid(_panel) and _panel.has_method("get_data"):
		return _panel.get_data()
	return null


# ── Semantic hit-testing (describe_point) ─────────────────────────────────────

## Return a semantic identifier for whatever is at board-mm point doc_pos.
## Precedence:  pad ("pad:U1.3") → component ("component:U3") →
##              trace ("trace:GND") → fallback ("canvas.point (x.x, y.y) mm").
## Stamped into annotation["anchored_to"] by AnnotationHost._stamp_anchor on
## add/update; surfaced by minerva_annotations_list via AnnotationSchema.
func describe_point(doc_pos: Vector2) -> String:
	var data = _board_data()
	if data == null:
		return _canvas_point_label(doc_pos)

	# 1. pad — a specific pin/pad of a component.
	var pad_ref := _pad_at(data, doc_pos)
	if not pad_ref.is_empty():
		return "pad:" + pad_ref

	# 2. component — inside a component body but not on a pad.
	var comp_id := str(data.get_component_at(doc_pos))
	if not comp_id.is_empty():
		return "component:" + comp_id

	# 3. trace — on a routed trace; label by its net (falling back to trace id).
	var trace_id := str(data.get_trace_at(doc_pos, _TRACE_HIT_THRESHOLD_MM))
	if not trace_id.is_empty():
		var trace = data.get_trace(trace_id)
		var net_name := str(trace.net_name) if trace != null else ""
		return "trace:" + (net_name if not net_name.is_empty() else trace_id)

	# 4. fallback — a bare board point.
	return _canvas_point_label(doc_pos)


func _canvas_point_label(doc_pos: Vector2) -> String:
	return "canvas.point (%.1f, %.1f) mm" % [doc_pos.x, doc_pos.y]


## Nearest pin/pad of any component within _PAD_HIT_RADIUS_MM of doc_pos.
## Returns "<component_id>.<pin_name>" or "" when nothing is close enough.
func _pad_at(data, doc_pos: Vector2) -> String:
	var best_ref := ""
	var best_dist := _PAD_HIT_RADIUS_MM
	for comp_id in data.components:
		var comp = data.components[comp_id]
		for pin_name in comp.pins:
			var world_pin: Vector2 = comp.get_pin_world_position(pin_name)
			var d := world_pin.distance_to(doc_pos)
			if d <= best_dist:
				best_dist = d
				best_ref = "%s.%s" % [comp_id, pin_name]
	return best_ref


# ── Compositing (LLM vision) ──────────────────────────────────────────────────

## Capture the board canvas (a custom-drawn Control, NOT a SubViewport) so
## render_overlay(include_document=true) can composite the board beneath the
## annotation layer. Technique: crop the parent viewport's frame to the canvas's
## global rect (the Hello-host pattern — valid here because the canvas draws its
## content directly; the SubViewport/CEF caveat does not apply). Synchronous, so
## the returned frame is one render behind on the very first call; adequate for a
## board that redraws on every view change. Headless / detached → null (safe).
func render_content_to_image(_viewport_rect: Rect2) -> Image:
	if _canvas == null or not is_instance_valid(_canvas):
		return null
	if not _canvas.is_inside_tree():
		return null
	var vp: Viewport = _canvas.get_viewport()
	if vp == null:
		return null
	var tex: ViewportTexture = vp.get_texture()
	if tex == null:
		return null
	var img: Image = tex.get_image()
	if img == null:
		return null
	var gr: Rect2 = _canvas.get_global_rect()
	var crop := Rect2i(gr.position, gr.size)
	crop = crop.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	if crop.size.x <= 0 or crop.size.y <= 0:
		return img
	return img.get_region(crop)


# ── Envelope authoring (conformant v2, TextEditorAnnotationHost pattern) ──────

## Add a v2 envelope. Assigns an id if missing, validates against the registry,
## stores + emits. Returns the assigned id, or "" on validation failure.
func add_annotation_v2(envelope: Dictionary) -> String:
	var stored := envelope.duplicate(true)
	var ann_id: String = str(stored.get("id", ""))
	if ann_id.is_empty():
		_id_counter += 1
		ann_id = "%s%04x" % [_ANN_ID_PREFIX, _id_counter]
		stored["id"] = ann_id
	var schema = _SCHEMA.new()
	var result = schema.validate_with_registry(stored, _registry)
	if result.has_errors():
		push_warning("[PcbAnnotationHost] add_annotation_v2: validation errors: %s" % str(result.to_error_dicts()))
		return ""
	# Stamp AFTER validation (mirrors CadAnnotationHost) so the conformance gate
	# never sees the anchored_to key: kind.primary_anchor_point → describe_point →
	# anchored_to (e.g. "pad:U1.3"). No-op when the registry/kind is missing.
	AnnotationHost._stamp_anchor(stored, self)
	_annotations.append(stored)
	annotations_changed.emit()
	return ann_id


## Base-API alias so callers using AnnotationHost.add_annotation() work.
func add_annotation(annotation: Dictionary) -> String:
	return add_annotation_v2(annotation)


## Build a conformant pcb_route_hint envelope (no id — add_annotation_v2 assigns
## one). x_mm/y_mm are board millimetres. Shared by add_route_hint_at (MCP/test
## path) and the kind's RouteHintAuthorTool (toolbar click-to-author path).
func build_route_hint_envelope(
		x_mm: float,
		y_mm: float,
		text: String = "",
		layer: String = "F.Cu",
		hint_type: String = "waypoint",
		waypoints: Array = [],
		author_kind: String = "human") -> Dictionary:
	if author_kind != "ai":
		author_kind = "human"
	var now := int(Time.get_unix_time_from_system())
	var summary_text := "Route hint (%s, %s)" % [hint_type, layer]
	if not text.is_empty():
		summary_text = "%s: %s" % [summary_text, text]
	return {
		"id": "",
		"kind": "pcb_route_hint",
		"schema_version": 2,
		"anchor": {
			"plugin": "pcb",
			"type": "board.point",
			"id": {"x": x_mm, "y": y_mm},
			"snapshot": {
				"position": [x_mm, y_mm],
			},
		},
		"kind_payload": {
			"hint_type": hint_type,
			"layer": layer,
			"text": text,
			"waypoints": waypoints,
		},
		"lifecycle": "open",
		"author": {"kind": author_kind},
		"view_context": "pcb",
		"visible_in_views": ["all"],
		"summary": summary_text,
		"created_at": now,
		"updated_at": now,
	}


## Build + store a conformant pcb_route_hint envelope at a board point.
## x_mm/y_mm are board millimetres. Returns the assigned id, or "" on failure.
func add_route_hint_at(
		x_mm: float,
		y_mm: float,
		text: String = "",
		layer: String = "F.Cu",
		hint_type: String = "waypoint",
		waypoints: Array = [],
		author_kind: String = "human") -> String:
	return add_annotation_v2(build_route_hint_envelope(
			x_mm, y_mm, text, layer, hint_type, waypoints, author_kind))


# ── Store adapters (used by MCPAnnotationTools) ───────────────────────────────

func get_annotations() -> Array:
	return _annotations


func get_all_annotations() -> Array:
	return _annotations


func get_all() -> Array:
	return _annotations


func get_by_id(annotation_id: String) -> Dictionary:
	for ann in _annotations:
		if ann is Dictionary and str((ann as Dictionary).get("id", "")) == annotation_id:
			return (ann as Dictionary).duplicate(true)
	return {}


func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
	for i in range(_annotations.size()):
		if _annotations[i] is Dictionary and str(_annotations[i].get("id", "")) == annotation_id:
			var updated := new_annotation.duplicate(true)
			updated["id"] = annotation_id
			# Re-stamp anchored_to so it reflects the current board (a component
			# may have moved under the marker since it was authored).
			AnnotationHost._stamp_anchor(updated, self)
			_annotations[i] = updated
			annotations_changed.emit()
			return true
	return false


func update(annotation: Dictionary) -> void:
	var annotation_id := str(annotation.get("id", ""))
	if not annotation_id.is_empty():
		update_annotation(annotation_id, annotation)


func remove_annotation(annotation_id: String) -> bool:
	for i in range(_annotations.size()):
		if _annotations[i] is Dictionary and str(_annotations[i].get("id", "")) == annotation_id:
			_annotations.remove_at(i)
			annotations_changed.emit()
			return true
	return false


func set_annotations(list: Array) -> void:
	_annotations = []
	for ann in list:
		if ann is Dictionary:
			_annotations.append((ann as Dictionary).duplicate(true))
	# Re-stamp anchored_to on every loaded entry so the values reflect the live
	# board (mirrors Cad/Hello set_annotations → refresh_all_anchors).
	AnnotationHost.refresh_all_anchors(_annotations, self)
	annotations_changed.emit()


# ── Anchor resolver ───────────────────────────────────────────────────────────

## Board points are static in the skeleton, so a route hint is never stale.
func _resolve_board_point(anchor: Dictionary) -> Dictionary:
	var pos := Vector2.ZERO
	var id: Variant = anchor.get("id", null)
	if id is Dictionary and (id as Dictionary).has("x") and (id as Dictionary).has("y"):
		pos = Vector2(float((id as Dictionary)["x"]), float((id as Dictionary)["y"]))
	else:
		var snap: Variant = anchor.get("snapshot", {})
		if snap is Dictionary:
			var p: Variant = (snap as Dictionary).get("position", [0, 0])
			if p is Array and (p as Array).size() >= 2:
				pos = Vector2(float((p as Array)[0]), float((p as Array)[1]))
	return {"position": pos, "bounds": Rect2(pos, Vector2.ZERO), "stale": false, "view_metadata": {}}


# ── Sidecar persistence (core AnnotationSidecar) ──────────────────────────────

## Write the current annotations to <path>.annotations.json. Zero annotations
## deletes the sidecar (AnnotationSidecar contract). Returns an Error code.
func save_sidecar(path: String) -> int:
	var schema = _SCHEMA.new()
	var serialized: Array = []
	for ann in _annotations:
		if ann is Dictionary:
			serialized.append(schema.serialize(ann as Dictionary))
	var data := {
		"substrate_version": 1,
		"document": {"path": path.get_file(), "kind": "pcbskel"},
		"annotations": serialized,
		"unknown_kinds": [],
	}
	return AnnotationSidecar.write_sidecar(path, data)


## Load annotations from <path>.annotations.json, replacing the current list.
## Missing sidecar is a no-op (leaves the list empty). Returns the count loaded.
func load_sidecar(path: String) -> int:
	var data := AnnotationSidecar.read_sidecar(path)
	if data.is_empty():
		return 0
	var raw: Array = data.get("annotations", [])
	var schema = _SCHEMA.new()
	_annotations = []
	var max_seq := 0
	for ann in raw:
		if not ann is Dictionary:
			continue
		var restored := schema.deserialize(ann as Dictionary)
		_annotations.append(restored)
		var ann_id := str(restored.get("id", ""))
		if ann_id.begins_with(_ANN_ID_PREFIX):
			var hex := ann_id.substr(_ANN_ID_PREFIX.length())
			if hex.is_valid_hex_number():
				max_seq = max(max_seq, hex.hex_to_int())
	if max_seq > _id_counter:
		_id_counter = max_seq
	annotations_changed.emit()
	return _annotations.size()
