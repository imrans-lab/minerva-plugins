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
## Semantic anchor types resolved live against the board model (this round).
const _ANCHOR_TYPE_PAD := "pcb/pad"
const _ANCHOR_TYPE_COMPONENT := "pcb/component"
const _ANCHOR_TYPE_NET := "pcb/net"
const _ANCHOR_TYPE_TRACE := "pcb/trace"
const _SCHEMA := preload("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")
const _PcbRouteHintKindScript: Script = preload("kinds/pcb_route_hint_kind.gd")
## Spatial reasoning (nearest/relative/NL-move) for the panel-local MCP tools.
## Bridge-only: MCPPcbPanelTools (Minerva core, off-tree) reaches it via
## get_spatial_index() duck-typed, never by class.
const _PcbSpatialIndexScript: Script = preload("model/pcb_spatial_index.gd")

## Storage: Array of v2 envelope Dictionaries.
var _annotations: Array = []

## Monotonic id counter for generated envelope ids.
var _id_counter: int = 0

## Per-host kind registry (built-in kinds + pcb_route_hint).
var _registry: AnnotationRegistry = null

## Per-host v2 anchor registry (validate/summary/repair for the pcb/* anchors).
## This is the DOCUMENTED repair path: MCPAnnotationTools.repair_anchor and the
## sidebar model reach it via host.get_anchor_registry().repair(anchor, host).
var _anchor_registry: AnnotationAnchorRegistry = null

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

## Lazily-built spatial index (pcb_spatial_index.gd) for the panel-local MCP
## bridge (see get_spatial_index). Rebuilt when the bound board model changes.
var _spatial_index = null

## Board-mm proximity for a pad/pin hit in describe_point (precedence tier 1).
const _PAD_HIT_RADIUS_MM := 1.0

## Board-mm proximity for a trace hit in describe_point (precedence tier 3).
## ~half a typical 0.25 mm trace; is_point_near adds width/2 on top.
const _TRACE_HIT_THRESHOLD_MM := 0.3


func _init() -> void:
	super._init()
	# Position resolvers (base resolve_anchor dispatches by "plugin/type" key). Each
	# returns {position, bounds, stale, view_metadata}; stale=true + snapshot
	# fallback when the target element no longer exists on the board.
	register_anchor_resolver(_ANCHOR_TYPE, Callable(self, "_resolve_board_point"))
	register_anchor_resolver(_ANCHOR_TYPE_PAD, Callable(self, "_resolve_pad"))
	register_anchor_resolver(_ANCHOR_TYPE_COMPONENT, Callable(self, "_resolve_component"))
	register_anchor_resolver(_ANCHOR_TYPE_NET, Callable(self, "_resolve_net"))
	register_anchor_resolver(_ANCHOR_TYPE_TRACE, Callable(self, "_resolve_trace"))

	_registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(_registry)
	_registry.register_annotation_kind(_PcbRouteHintKindScript.new())

	# Anchor registry: validate/summary/repair adapters for the pcb/* anchors. One
	# adapter delegates back to the host's semantic dispatch (single code path); it
	# is registered under every pcb anchor type so the platform repair surface can
	# reach it by (plugin, type).
	_anchor_registry = AnnotationAnchorRegistry.new()
	var adapter := _PcbAnchorResolver.new(self)
	for atype in ["board.point", "pad", "component", "net", "trace"]:
		_anchor_registry.register("pcb", atype, adapter)


# ── AnnotationHost overrides ──────────────────────────────────────────────────

func get_registry() -> AnnotationRegistry:
	return _registry


## The v2 anchor registry (validate/summary/repair for pcb/* anchors). Non-null
## so the platform repair surface (MCPAnnotationTools.repair_anchor, the sidebar
## model) can retarget a stale pcb anchor via the documented path.
func get_anchor_registry() -> Object:
	return _anchor_registry


func get_capabilities() -> Dictionary:
	return {
		# Reflects reality: the per-host registry carries the core generic 2d_*
		# kinds (BuiltinKinds.register_all) PLUS the one pcb domain kind. Generic
		# annotations author through the core kinds — no pcb-namespaced duplicates.
		"kinds": ["pcb_route_hint", "2d_arrow", "2d_text", "2d_region", "2d_polyline"],
		"tools": ["select"],
		"anchor_types": [
			_ANCHOR_TYPE, _ANCHOR_TYPE_PAD, _ANCHOR_TYPE_COMPONENT,
			_ANCHOR_TYPE_NET, _ANCHOR_TYPE_TRACE, "core/canvas.point",
		],
		"lifecycle": {
			"resolve": true,
			"reopen": true,
			"delete": true,
			"repair": true,
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


# ── Panel-local MCP bridge (MCPPcbPanelTools, Minerva core) ───────────────────
#
# The single duck-typed gateway the off-tree core module reaches through. The
# host is what AnnotationHostRegistry vends by editor tab title, so the panel
# structural tools (add/move/rotate/delete component, connect net, board resize,
# CSV/geometry round-trip, queries) resolve the board model + spatial index HERE
# rather than reaching the panel by class. Mutations run against the returned
# model API so journal + undo + the data_changed dirty relay come for free. The
# core module NEVER references pcb_data/pcb_component/pcb_spatial_index by
# class — it only calls the objects these accessors return.

## The live board model (pcb_data.gd), or null when nothing is wired (headless
## before mount). Core add/query tools reach the model exclusively through this.
func get_board_data():
	return _board_data()


## Lazily-built spatial index (pcb_spatial_index.gd) bound to the live board
## model, or null when no model is available. Rebuilt if the underlying model
## instance changes. Backs the describe_component / spatial_query / move_relative
## panel-local tools (the plugin owns the NL/relative reasoning; core orchestrates
## the mutation through get_board_data()).
func get_spatial_index():
	var data = _board_data()
	if data == null:
		return null
	if _spatial_index == null or _spatial_index.data != data:
		_spatial_index = _PcbSpatialIndexScript.new(data)
	return _spatial_index


## Router bridge (route-correction loop, agent-router child 019eb47eb567). The
## core apply tool (MCPPcbPanelTools.minerva_pcb_apply_route_hints) reaches the
## worker `route` method through HERE — the host is what AnnotationHostRegistry
## vends, so the async worker hop resolves off the same host the tool already
## holds. We forward to the panel, which owns the broker `request` signal + the
## _MinervaIPC reply channel (the same path _on_export_yaml_pressed uses for
## pcb.serialize). No panel bound (headless / before mount) → a structured
## worker_unavailable so the caller degrades to failure-as-feedback instead of
## crashing. Async: awaits the panel's broker round-trip.
##
## FINDING (DCR 019dc140): making this live end-to-end needs one out-of-fence
## step — the "pcb.route" broker channel is not declared in manifest.json
## ipc_channels (only pcb.serialize/deserialize/collect_export/apply_export are),
## and the worker `route` method is otherwise reachable only via a Go MCP tool
## (internal/tools/worker_tools.go), neither of which is in this round's fence.
## The in-fence half (host→panel→broker request) is wired and ready.
func run_router(selection: Dictionary) -> Dictionary:
	if _panel != null and is_instance_valid(_panel) and _panel.has_method("route_board"):
		return await _panel.route_board(selection)
	return {"ok": false, "error": {"kind": "worker_unavailable",
		"message": "no panel bound — router broker unreachable (headless / before mount)"}}


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
		author_kind: String = "human",
		detail_level: String = "",
		width_mm: float = 0.25,
		source_pins: Array = [],
		dest_pins: Array = []) -> Dictionary:
	if author_kind != "ai":
		author_kind = "human"
	if detail_level.is_empty():
		detail_level = _derive_detail_level(waypoints.size())
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
			"detail_level": detail_level,
			"layer": layer,
			"width_mm": width_mm,
			"source_pins": source_pins.duplicate(),
			"dest_pins": dest_pins.duplicate(),
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


## Route-hint detail level, auto-derived from waypoint count (sparse ≤1, guided
## 2–3, detailed ≥4). Matches the legacy PCBRouteHint auto-derivation.
static func _derive_detail_level(waypoint_count: int) -> String:
	if waypoint_count <= 1:
		return "sparse"
	if waypoint_count <= 3:
		return "guided"
	return "detailed"


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
			# Base contract: removing the selected annotation clears selection.
			if get_selected_annotation_id() == annotation_id:
				set_selected_annotation_id("")
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


# ── Anchor position resolvers (base resolve_anchor dispatches here) ───────────
#
# Contract: each returns {position: Vector2, bounds: Rect2, stale: bool,
# view_metadata: Dict}. `stale: true` is the platform's staleness flag — the
# base AnnotationHost.resolve_anchor / AnnotationResolveCache pass it to
# AnnotationOverlay, which sets ctx.is_stale and calls kind.render_broken (badge
# at the snapshot position). There is NO automatic lifecycle mutation from a
# stale resolve — moving an annotation to lifecycle "stale"/"broken" is an
# explicit act (update_annotation_lifecycle, or the repair surface via
# get_anchor_registry().repair). When the target element is gone we fall back to
# anchor.snapshot.position and flag stale so the marker renders in place.

## Board points are static — a board.point anchor is never stale.
func _resolve_board_point(anchor: Dictionary) -> Dictionary:
	var id: Variant = anchor.get("id", null)
	if id is Dictionary and (id as Dictionary).has("x") and (id as Dictionary).has("y"):
		return _resolve_result(Vector2(float((id as Dictionary)["x"]), float((id as Dictionary)["y"])), false)
	return _resolve_result(_snapshot_pos(anchor), false)


## pcb/pad — id {component, pin} → live pin world position (rotation-correct via
## component.get_pin_world_position). Stale when component or pin is gone.
func _resolve_pad(anchor: Dictionary) -> Dictionary:
	var comp = _pad_component(anchor)
	if comp != null:
		var pin := str((anchor.get("id", {}) as Dictionary).get("pin", ""))
		return _resolve_result(comp.get_pin_world_position(pin), false)
	return _resolve_result(_snapshot_pos(anchor), true)


## pcb/component — id "U3" → component origin position. Stale when gone.
func _resolve_component(anchor: Dictionary) -> Dictionary:
	var data = _board_data()
	if data != null:
		var comp = data.get_component(str(anchor.get("id", "")))
		if comp != null:
			return _resolve_result(comp.position, false)
	return _resolve_result(_snapshot_pos(anchor), true)


## pcb/net — id "GND" → nearest point across the net's trace geometry to the
## snapshot position (multi-geometry). Stale when the net has no live geometry.
func _resolve_net(anchor: Dictionary) -> Dictionary:
	var data = _board_data()
	var snap := _snapshot_pos(anchor)
	# A net's live geometry is its traces (net objects are implicit — a trace can
	# reference a net_name without a matching net entry). Stale when no trace
	# geometry exists to point at.
	if data != null:
		var traces: Array = data.get_traces_for_net(str(anchor.get("id", "")))
		if not traces.is_empty():
			return _resolve_result(_nearest_point_on_traces(traces, snap), false)
	return _resolve_result(snap, true)


## pcb/trace — id trace-id String OR {net, segment} → a representative point on
## the trace (segment midpoint when a segment index is given, else its start).
func _resolve_trace(anchor: Dictionary) -> Dictionary:
	var trace = _find_trace(anchor.get("id", null))
	if trace != null:
		return _resolve_result(_trace_point(trace, anchor.get("id", null)), false)
	return _resolve_result(_snapshot_pos(anchor), true)


func _resolve_result(pos: Vector2, stale: bool) -> Dictionary:
	return {"position": pos, "bounds": Rect2(pos, Vector2.ZERO), "stale": stale, "view_metadata": {}}


func _snapshot_pos(anchor: Dictionary) -> Vector2:
	var snap: Variant = anchor.get("snapshot", {})
	if snap is Dictionary:
		var p: Variant = (snap as Dictionary).get("position", null)
		if p is Array and (p as Array).size() >= 2:
			return Vector2(float((p as Array)[0]), float((p as Array)[1]))
	return Vector2.ZERO


## Live component for a pcb/pad anchor, or null when the component/pin is gone.
func _pad_component(anchor: Dictionary):
	var data = _board_data()
	var id: Variant = anchor.get("id", null)
	if data == null or not (id is Dictionary):
		return null
	var comp = data.get_component(str((id as Dictionary).get("component", "")))
	if comp == null:
		return null
	if not comp.pins.has(str((id as Dictionary).get("pin", ""))):
		return null
	return comp


## Nearest point to `target` across a set of trace objects (their closest-point
## helper handles each polyline). Returns `target` unchanged for empty input.
func _nearest_point_on_traces(traces: Array, target: Vector2) -> Vector2:
	var best := target
	var best_dist := INF
	for trace in traces:
		if trace == null:
			continue
		var cp: Vector2 = trace.get_closest_point(target)
		var d := cp.distance_to(target)
		if d < best_dist:
			best_dist = d
			best = cp
	return best


## Resolve a pcb/trace anchor id to a live trace object, or null.
## id forms: "trace_3" (String) | {trace_id: "trace_3"} | {net: "GND", segment?}.
func _find_trace(id: Variant):
	var data = _board_data()
	if data == null:
		return null
	if id is String:
		return data.get_trace(id as String)
	if id is Dictionary:
		var d: Dictionary = id
		if d.has("trace_id"):
			return data.get_trace(str(d["trace_id"]))
		if d.has("net"):
			var traces: Array = data.get_traces_for_net(str(d["net"]))
			if not traces.is_empty():
				return traces[0]
	return null


## A representative point on a trace: the midpoint of segment `id.segment` when a
## segment index is supplied and valid, else the trace's start waypoint.
func _trace_point(trace, id: Variant) -> Vector2:
	var wps: Array = trace.waypoints
	if id is Dictionary and (id as Dictionary).has("segment"):
		var idx := int((id as Dictionary)["segment"])
		if idx >= 0 and idx + 1 < wps.size():
			return (wps[idx] + wps[idx + 1]) * 0.5
	if not wps.is_empty():
		return wps[0]
	return Vector2.ZERO


# ── Semantic anchor summary / validate / repair (documented repair path) ──────
#
# These back the AnnotationAnchorRegistry adapter (_PcbAnchorResolver). One dispatch
# per concern keeps a single source of truth; the adapter and any direct caller
# share it. Existence checks are gated on a live board model so headless callers
# (no canvas) validate SHAPE only and never false-negative.

## Anchor-level summary, e.g. "pad U1.3" / "component U3" / "net GND" / "trace GND".
func anchor_summary(anchor: Dictionary) -> String:
	var id: Variant = anchor.get("id", null)
	match str(anchor.get("type", "")):
		"pad":
			if id is Dictionary:
				return "pad %s.%s" % [str((id as Dictionary).get("component", "?")), str((id as Dictionary).get("pin", "?"))]
			return "pad %s" % str(id)
		"component":
			return "component %s" % str(id)
		"net":
			return "net %s" % str(id)
		"trace":
			return "trace %s" % _trace_net_label(anchor)
		"board.point":
			var p := _snapshot_pos(anchor)
			if id is Dictionary and (id as Dictionary).has("x"):
				p = Vector2(float((id as Dictionary)["x"]), float((id as Dictionary)["y"]))
			return "board point (%.1f, %.1f) mm" % [p.x, p.y]
	return "%s %s" % [str(anchor.get("type", "?")), str(id)]


## A trace anchor's net label (net name via the live trace, falling back to the
## anchor id's net, then the raw id).
func _trace_net_label(anchor: Dictionary) -> String:
	var trace = _find_trace(anchor.get("id", null))
	if trace != null and not str(trace.net_name).is_empty():
		return str(trace.net_name)
	var id: Variant = anchor.get("id", null)
	if id is Dictionary and (id as Dictionary).has("net"):
		return str((id as Dictionary)["net"])
	return str(id)


## Semantic validation beyond the common shape: the referenced element exists.
## Returns an Array of error strings (empty = valid). Existence is only asserted
## when a live board model is present.
func anchor_validate(anchor: Dictionary) -> Array:
	var errors: Array = []
	var data = _board_data()
	var id: Variant = anchor.get("id", null)
	match str(anchor.get("type", "")):
		"pad":
			if not (id is Dictionary) or not (id as Dictionary).has("component") or not (id as Dictionary).has("pin"):
				errors.append("pad id must be {component, pin}")
			elif data != null:
				var comp = data.get_component(str((id as Dictionary)["component"]))
				if comp == null:
					errors.append("pad component '%s' not found" % str((id as Dictionary)["component"]))
				elif not comp.pins.has(str((id as Dictionary)["pin"])):
					errors.append("pad pin '%s' not found on '%s'" % [str((id as Dictionary)["pin"]), str((id as Dictionary)["component"])])
		"component":
			if str(id).is_empty():
				errors.append("component id must be a non-empty string")
			elif data != null and data.get_component(str(id)) == null:
				errors.append("component '%s' not found" % str(id))
		"net":
			if str(id).is_empty():
				errors.append("net id must be a non-empty string")
			elif data != null and not data.has_net(str(id)) and (data.get_traces_for_net(str(id)) as Array).is_empty():
				errors.append("net '%s' not found (no net entry and no trace geometry)" % str(id))
		"trace":
			if data != null and _find_trace(id) == null:
				errors.append("trace '%s' not found" % str(id))
		"board.point":
			if not (id is Dictionary) or not (id as Dictionary).has("x") or not (id as Dictionary).has("y"):
				errors.append("board.point id must be {x, y}")
	return errors


## Repair an anchor by re-locating its target. Returns a refreshed anchor Dict
## (snapshot.position updated to the live position) when the target still exists,
## or null when it is gone — the caller (repair surface) treats null as broken.
func anchor_repair(anchor: Dictionary) -> Variant:
	var resolved := resolve_anchor(anchor)
	if bool(resolved.get("stale", false)):
		return null
	var pos: Vector2 = resolved.get("position", Vector2.ZERO)
	var out := anchor.duplicate(true)
	var snap: Dictionary = (out.get("snapshot", {}) as Dictionary).duplicate(true) if out.get("snapshot", null) is Dictionary else {}
	snap["position"] = [pos.x, pos.y]
	out["snapshot"] = snap
	return out


## Repair a WHOLE route-hint annotation. For a hint with source_pins/dest_pins,
## EVERY endpoint pad must still exist — a missing endpoint marks the annotation
## broken rather than silently re-anchoring. On success re-locates the anchor.
##
## Returns {ok, broken, reason?, missing?, anchor?}.
func repair_route_hint(annotation: Dictionary) -> Dictionary:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var missing: Array = []
	for key in ["source_pins", "dest_pins"]:
		var refs: Variant = payload.get(key, [])
		if refs is Array:
			for ref in (refs as Array):
				if not _pin_ref_exists(str(ref)):
					missing.append(str(ref))
	if not missing.is_empty():
		return {
			"ok": false,
			"broken": true,
			"missing": missing,
			"reason": "missing endpoint(s): %s" % ", ".join(missing),
		}
	var repaired: Variant = anchor_repair(annotation.get("anchor", {}))
	if repaired == null:
		return {"ok": false, "broken": true, "reason": "anchor target no longer exists"}
	return {"ok": true, "broken": false, "anchor": repaired}


## True when "U1.15"-form pad reference resolves to a live component+pin. When no
## board model is bound, treats the reference as present (cannot disprove it).
func _pin_ref_exists(ref: String) -> bool:
	var data = _board_data()
	if data == null:
		return true
	var idx := ref.rfind(".")
	if idx < 0:
		return data.get_component(ref) != null
	var comp = data.get_component(ref.left(idx))
	if comp == null:
		return false
	return comp.pins.has(ref.substr(idx + 1))


## Thin AnnotationAnchorRegistry adapter — delegates validate/summary/repair to the
## host's semantic dispatch so there is one source of truth. Registered under every
## pcb anchor type. Duck-typed methods (the registry checks has_method).
class _PcbAnchorResolver:
	extends RefCounted

	var _host = null

	func _init(host) -> void:
		_host = host

	func validate(anchor: Dictionary) -> Array:
		return _host.anchor_validate(anchor)

	func summary(anchor: Dictionary, _host_arg: Object) -> String:
		return _host.anchor_summary(anchor)

	func repair(anchor: Dictionary, _host_arg: Object) -> Variant:
		return _host.anchor_repair(anchor)


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
