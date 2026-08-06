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
## T1.5: the ONE canonical layer contract (top/bottom <-> F.Cu/B.Cu).
const PcbLayerStack := preload("model/pcb_layer_stack.gd")

## Storage: Array of v2 envelope Dictionaries.
var _annotations: Array = []

## Per-hint revision history (C4 deliverable 1, docket 019f6c464ff0): the
## tracked kind_payload fields for a pcb_route_hint (waypoints/layer/
## width_mm/detail_level). Bounded stacks carried as TOP-LEVEL envelope
## fields (siblings of kind_payload, not nested inside it) — deliberate:
## kind_payload is "the kind's own domain data" (sent verbatim to the router
## worker, read verbatim by summary()), so keeping history OUT of it means
## summary() (which only reads named kind_payload keys) never has to
## special-case it, and PCBPanel.route_board()/panel_tools.gd's route-
## request builders only need one strip step (strip_hint_history below)
## instead of scrubbing inside a nested dict everywhere kind_payload is read.
const _HINT_HISTORY_FIELDS := ["waypoints", "layer", "width_mm", "detail_level"]
const HINT_HISTORY_CAP := 25
const _REVISION_KEY := "revision_stack"
const _REDO_KEY := "redo_stack"

## Set true only while undo_hint_revision()/redo_hint_revision() are applying
## a restored snapshot through update_annotation() — suppresses the auto-push
## in _apply_hint_history so a restore is never itself recorded as a new edit
## (that would make undo un-undo-able).
var _suppress_hint_history := false

## Codex 1047 fix round, verdict 3: the STRUCTURED reason the most recent
## update_annotation() call was refused for POLICY reasons — {} whenever the
## last update succeeded, or failed for a non-policy reason (unknown id).
## update_annotation's bool return stays (three shipped callers switch on it);
## this field is the additive side channel a caller that wants MORE than the
## bool reads immediately after a false return. Written ONLY by the
## _refuses_superseded_waypoint_edit refusal path, cleared at the START of
## every update_annotation call so it can never describe a stale earlier
## refusal. Consumed duck-typed (host.get("last_update_refusal")) by core's
## MCPAnnotationTools._annotations_update, which previously collapsed this
## refusal into a dishonest {"error": "not_found"}.
var last_update_refusal: Dictionary = {}

## Codex 1047 fix round, verdict 4: set true only for the duration of the
## single update_annotation() call a host-sanctioned marker strip performs.
## There are exactly TWO sanctioned strip paths, both funnelled through
## _strip_superseded_state: release_superseded_waypoints() (the verdict-4
## conversion — an undoable user-level act) and, since verdict 6,
## reconcile_strip_superseded_marker() (load-time reconciliation of a
## marker-without-constraint torn state — pure bookkeeping). While set,
## _reinject_superseded_marker is a no-op (the strip is the point, not an
## accident to be repaired) and _refuses_superseded_waypoint_edit stands down
## (belt-and-braces; neither strip ever changes waypoints, but a sanctioned
## strip must not be refusable by the machinery it is dismantling).
var _bypass_superseded_release := false

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
		# Left as-is on purpose: it still describes the one built-in tool this
		# host's annotations answer to. What changed (B1u3) is WHERE that tool is
		# offered — see tools_excluded.
		"tools": ["select"],
		# THE DOCK MUST NOT OFFER ITS OWN SELECT HERE (B1u3, universal select).
		# This panel shows exactly one Select, on the board canvas, and it picks
		# annotations AND board entities through one ladder; a second Select in
		# the annotation dock would be a second, half-blind selection mode
		# sitting next to it.
		#
		# It has to be an EXCLUSION, not an empty allow-list: AnnotationToolbar
		# treats an empty "tools" array as ALLOW-ALL, so "tools": [] would SHOW
		# the button. An older core that does not read this key simply keeps its
		# dock Select — which is precisely the two-tool world this panel had
		# before, and the right thing to degrade to.
		"tools_excluded": ["select"],
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


## The bound panel, or null (duck-typed getter, C3 round docket 019f6c4604ba —
## defense-in-depth). PluginToolRegistry._handle_panel_tool_call's fallback
## panel-resolution path (contract §2.2 step 2, when the scene-panel broker
## doesn't know an editor_name) calls AnnotationHostRegistry.get_host(name)
## then duck-types host.get_panel() to reach the live PCBPanel. Without this
## getter that fallback silently misses for pcb even though the primary
## broker path already resolves it in production — this closes the gap so
## the fallback is live too, not just the happy path.
func get_panel():
	return _panel


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
## `extra` (DCR finding 7 — scope/pinned_candidates) passes straight through to
## PCBPanel.route_board, which is the only thing that reads it; omitted here it
## defaults to {}, reproducing the pre-existing call exactly.
func run_router(selection: Dictionary, extra: Dictionary = {}) -> Dictionary:
	if _panel != null and is_instance_valid(_panel) and _panel.has_method("route_board"):
		return await _panel.route_board(selection, extra)
	return {"ok": false, "error": {"kind": "worker_unavailable",
		"message": "no panel bound — router broker unreachable (headless / before mount)"}}


## Whole-board load bridge (minerva_pcb_load_board). Forwards to the panel, which
## owns the broker `request` signal for pcb.deserialize + from_board_dict — same
## host→panel duck-typed path as run_router.
func load_board(yaml_text: String) -> Dictionary:
	if _panel != null and is_instance_valid(_panel) and _panel.has_method("load_board_from_yaml"):
		return await _panel.load_board_from_yaml(yaml_text)
	return {"ok": false, "error": {"kind": "worker_unavailable",
		"message": "no panel bound — pcb.deserialize broker unreachable (headless / before mount)"}}


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


## Layer-keyed visibility (WC-2 C3 fix, bug 019f33d2c9bf): a WORKFLOW-class
## annotation carrying kind_payload.layer follows the canvas's live layer
## filter — hiding B.Cu hides bottom-layer route hints from rendering AND
## hit-testing (the substrate consults this in AnnotationOverlay._draw and in
## every manipulation-tool hit loop). Review annotations, hints without a
## layer, and headless hosts (no canvas) are always visible. UI-only: MCP
## reads and the stored list are unaffected.
func is_annotation_visible(annotation: Dictionary) -> bool:
	if _registry == null:
		return true
	var kind: AnnotationKind = _registry.get_annotation_kind(StringName(str(annotation.get("kind", ""))))
	if kind == null or not kind.workflow_class:
		return true
	var payload: Variant = annotation.get("kind_payload", {})
	if not payload is Dictionary:
		return true
	var layer := str((payload as Dictionary).get("layer", ""))
	if layer.is_empty():
		return true
	if _canvas == null or not is_instance_valid(_canvas) or not _canvas.has_method("is_layer_visible"):
		return true
	return bool(_canvas.is_layer_visible(layer))


## The board-layer a freshly-authored route hint should carry (WC-3 contract
## §5, "current layer"). Derived from the canvas's live trace_layer_filter (the
## same OptionButton the human drives, PCBPanel.gd _on_layer_selected) so a
## human authoring while the view is scoped to one layer gets a hint on THAT
## layer, not a stale default.
##
## Epoch 6 unit 3b: ANY canonical copper filter designates the active layer, not
## just top/bottom. The old code compared the filter against the two literals
## "top"/"bottom", so authoring under an inner-layer view (In1.Cu) silently fell
## through to the F.Cu default — a route hint landing on the wrong copper without
## saying so. The mapping is delegated to the ONE contract, which now knows
## in1..in30, so the guard is "is this a copper layer at all?" instead of a
## hardcoded pair.
##
## "all" and no canvas bound (headless) mean NO single active layer, and keep the
## F.Cu fallback (the pcb_route_hint kind's own default) — deliberately unchanged
## behaviour: with every layer shown there is nothing better to infer, and
## refusing to author would be worse than authoring on the default side.
func get_current_layer() -> String:
	if _canvas == null or not is_instance_valid(_canvas) or not ("trace_layer_filter" in _canvas):
		return "F.Cu"
	var filter := str(_canvas.trace_layer_filter)
	if not PcbLayerStack.is_copper(filter):
		return "F.Cu"
	return PcbLayerStack.canon_to_kicad(filter)


## Clear-by-author (pcb-ui-native-cluster §5 / WC-3 deliverable 3): removes
## every WORKFLOW-class annotation (route hints) whose author.kind matches
## author_kind — "human", "ai", or "all" (both). Review-class annotations
## (arrows/text/etc.) are never touched; this is the host-side filter behind
## the workflow listing's clear-by-author context menu. Returns the number of
## annotations removed. A no-op removal (0) does not emit annotations_changed
## (mirrors remove_annotation's single-signal-per-real-change discipline).
func clear_annotations_by_author(author_kind: String) -> int:
	if author_kind not in ["human", "ai", "all"]:
		return 0
	var kept: Array = []
	var removed := 0
	for ann in _annotations:
		if not (ann is Dictionary):
			kept.append(ann)
			continue
		var a: Dictionary = ann
		var kind: AnnotationKind = _registry.get_annotation_kind(StringName(str(a.get("kind", "")))) if _registry != null else null
		var is_workflow := kind != null and kind.workflow_class
		var author: Variant = a.get("author", null)
		var a_kind := str((author as Dictionary).get("kind", "human")) if author is Dictionary else "human"
		var matches := author_kind == "all" or a_kind == author_kind
		if is_workflow and matches:
			removed += 1
			if get_selected_annotation_id() == str(a.get("id", "")):
				set_selected_annotation_id("")
			continue
		kept.append(a)
	if removed > 0:
		_annotations = kept
		annotations_changed.emit()
	return removed


## RETIRED (S5, C4b, DCR 019f7095c395): accept_annotation_proposal /
## reject_annotation_proposal — the duck-typed verb pair core's
## WorkflowAnnotationList checked for (has_method) to offer per-row Accept/
## Reject on any AI-authored workflow annotation. DCR finding 4: that
## inference (author.kind=="ai" ⇒ offer Accept/Reject) is wrong for an
## agent-authored SOURCE hint, which is intent/commentary, not a proposal —
## core's inference itself is out of fence this epoch (WorkflowAnnotationList.gd
## is core), so the fix is pcb opting OUT of the duck-typed pair entirely: with
## both methods gone, `_host.has_method(_ACCEPT_METHOD)` is false and no pcb
## row — hint or (formerly) proposal — ever grows the buttons. A landed
## workspace candidate is resolved via minerva_pcb_workspace_commit/_reject or
## the canvas candidate menu instead (see panel_tools.gd
## _propose_into_workspace).


## Navigation pass-through target (WC-2 §1a): the platform AnnotationOverlay
## forwards middle-button / wheel / pan-gesture / middle-drag-motion events
## here while an annotation tool is active; we relay to the canvas's existing
## pan/zoom handling. Overlay and canvas share an origin, so positions are
## already canvas-local. No canvas bound (headless) → no-op.
func forward_navigation_input(event: InputEvent) -> void:
	if _canvas == null or not is_instance_valid(_canvas):
		return
	if _canvas.has_method("handle_navigation_input"):
		_canvas.handle_navigation_input(event)


# ── UNIVERSAL SELECT router (B1u3, item 019fbb9adc) ───────────────────────────
#
# This panel offers ONE Select. The board canvas owns the click and asks the
# verbs below whether the annotation layer claims it; when it does, the canvas
# drives the CORE AnnotationTransformTool through them for the whole gesture.
# Nothing here re-implements annotation selection — every verb delegates to the
# core tool or to AnnotationHost's own multi-select API.
#
# WHY THE CANVAS OWNS THE CLICK and not the overlay: an armed tool flips
# AnnotationOverlay to MOUSE_FILTER_STOP, and Godot's gui walk ENDS at a STOP
# control whether or not the event was accepted — so an overlay-armed tool
# cannot decline a click and let the board have it. Routing the other way would
# mean forwarding the canvas's entire input surface (right-click menu, pan,
# every key binding) through the overlay. Instead the tool is armed PASSIVELY
# (AnnotationOverlay.set_active_tool(tool, true)): it draws, it owns the
# selection visual, its caption editor still parents to the overlay, but the
# overlay stays transparent and the canvas keeps the pointer.
#
# EVERY core member touched here is duck-typed with has_method. A core without
# the passive-pointer arming never gets a tool armed at all, every verb below
# returns its empty answer, and the panel degrades to exactly the two-tool world
# it had before this unit (the dock keeps its own Select — see get_capabilities).
# This is the off-tree rule from hint pcb-plugin/off-tree-core-api-coupling: a
# class_name reference to a member the running core lacks is a PARSE error that
# takes the whole script down, so nothing here names a new core symbol.

## Core script path for the ONE manipulation tool. load()ed at runtime, never
## preload()ed and never named by class_name: a missing file must degrade to
## "no universal select", not to a parse error that unloads this host.
const _TRANSFORM_TOOL_PATH := "res://Scripts/Services/Annotations/kinds/AnnotationTransformTool.gd"

## The single passively-armed AnnotationTransformTool instance, or null when the
## running core cannot supply one. Built once and reused: it carries the caption
## editor and the drag snapshots, so churning it per arm would drop an edit.
var _select_tool: AnnotationAuthorTool = null

## The AnnotationOverlay we armed, while we are the one that armed it.
var _select_overlay: Control = null

## True only between arm_universal_select(on) and its matching disarm. Cleared
## without touching the overlay by notify_universal_select_detached() when some
## OTHER surface takes the overlay over, so a later disarm can never yank a tool
## we no longer own.
var _select_armed: bool = false


## The tool instance, or null on a core that cannot provide one.
func get_universal_select_tool() -> Object:
	if _select_tool != null:
		return _select_tool
	var script: Variant = load(_TRANSFORM_TOOL_PATH)
	if script == null or not (script is Script):
		return null
	var made: Variant = (script as Script).new()
	if not (made is AnnotationAuthorTool):
		return null
	_select_tool = made
	return _select_tool


## Arm (or release) the universal Select tool on `overlay`, passively.
## Idempotent in both directions. A core whose overlay does not advertise
## passive-pointer support is left completely alone.
func arm_universal_select(overlay: Control, on: bool) -> void:
	if on:
		if _select_armed:
			return
		if overlay == null or not is_instance_valid(overlay):
			return
		if not overlay.has_method("supports_passive_pointer") \
				or not bool(overlay.supports_passive_pointer()):
			return
		var tool := get_universal_select_tool()
		if tool == null or not tool.has_method("claims_point"):
			return
		tool.on_activate(self)
		overlay.set_active_tool(tool, true)
		_select_overlay = overlay
		_select_armed = true
		return

	if not _select_armed:
		return
	_select_armed = false
	if _select_overlay != null and is_instance_valid(_select_overlay) \
			and _select_overlay.has_method("clear_active_tool"):
		_select_overlay.clear_active_tool()
	_select_overlay = null
	if _select_tool != null:
		_select_tool.on_deactivate()


## Another surface (the dock toolbar, the route-flow cluster) replaced or cleared
## our tool on the shared overlay. Forget the arming WITHOUT touching the overlay
## — it belongs to whoever armed it now.
func notify_universal_select_detached() -> void:
	if not _select_armed:
		return
	_select_armed = false
	_select_overlay = null
	if _select_tool != null:
		_select_tool.on_deactivate()


func is_universal_select_armed() -> bool:
	return _select_armed


## The armed tool, or null — every verb below funnels through this so a
## disarmed/degraded panel answers "no" uniformly.
func _armed_tool() -> Object:
	if not _select_armed or _select_tool == null:
		return null
	return _select_tool


## Repaint the overlay after a routed gesture. Drags that emit
## annotation_modified redraw via annotations_changed, but a marquee-less
## gizmo press, a rotate arc mid-drag and the caption notice have no model
## change to ride on.
func _redraw_overlay() -> void:
	if _select_overlay != null and is_instance_valid(_select_overlay):
		_select_overlay.queue_redraw()


## Does the annotation layer claim a LEFT press at `canvas_pos` (canvas-local
## pixels)? The canvas asks this at the TOP of its Select ladder.
##
## `mods` is the modifier mask and MUST be passed through: the tool's answer
## branches on shift (a shift-press off the ink is a marquee press, and the
## marquee belongs to the canvas so it can sweep BOTH halves). Sending 0 here
## would hand the annotation layer shift+box gestures it then resolves as an
## annotation-only marquee.
func annotation_claims_point(canvas_pos: Vector2, mods: int = 0) -> bool:
	var tool := _armed_tool()
	if tool == null or not tool.has_method("claims_point"):
		return false
	return bool(tool.claims_point(canvas_pos, mods))


func annotation_pointer_down(canvas_pos: Vector2, button: int, mods: int) -> bool:
	var tool := _armed_tool()
	if tool == null:
		return false
	var consumed := bool(tool.on_pointer_down(canvas_pos, button, mods))
	_redraw_overlay()
	return consumed


## Double-click leg, mirroring AnnotationOverlay's own order: the opt-in
## on_pointer_double_click hook first, and a tool that declines it falls straight
## through to the ordinary press.
func annotation_pointer_double_click(canvas_pos: Vector2, button: int, mods: int) -> bool:
	var tool := _armed_tool()
	if tool == null:
		return false
	if tool.has_method("on_pointer_double_click") \
			and bool(tool.on_pointer_double_click(canvas_pos, button, mods)):
		_redraw_overlay()
		return true
	return annotation_pointer_down(canvas_pos, button, mods)


## Pseudo-pointer KEY channel — the SAME convention AnnotationOverlay uses for
## Escape/Delete/Enter: the keycode rides in the mods slot of a pointer-down at
## Vector2.ZERO. Returns true when the tool consumed it.
##
## This is what makes the tool's own Escape grammar reachable in this panel:
## mid-drag Escape REVERTS the drag (every other panel does), rather than the
## canvas quietly clearing selections while the drag runs on to commit.
func annotation_key(keycode: int) -> bool:
	var tool := _armed_tool()
	if tool == null:
		return false
	var consumed := bool(tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, keycode))
	_redraw_overlay()
	return consumed


func annotation_pointer_move(canvas_pos: Vector2) -> void:
	var tool := _armed_tool()
	if tool == null:
		return
	tool.on_pointer_move(canvas_pos)
	_redraw_overlay()


func annotation_pointer_up(canvas_pos: Vector2, button: int, mods: int) -> void:
	var tool := _armed_tool()
	if tool == null:
		return
	tool.on_pointer_up(canvas_pos, button, mods)
	_redraw_overlay()


## The marquee half. `rect` is BOARD-MM (the canvas's world space), which is this
## host's document space verbatim — no conversion, and none wanted.
##
## Returns ids only. The AABBs this is computed from are zoom-ephemeral (kinds
## size part of their footprint in screen px and divide by the live view zoom),
## so nothing derived from them is cached here or anywhere upstream.
func annotations_in_world_rect(rect: Rect2) -> PackedStringArray:
	var tool := _armed_tool()
	if tool == null or not tool.has_method("annotations_intersecting"):
		return PackedStringArray()
	return tool.annotations_intersecting(rect)


## Union `ids` into the annotation selection. Additive by construction, matching
## the board marquee: a plain (non-shift) press already cleared both halves at
## press time, so a sweep only ever adds — which is what makes shift+box extend
## a mixed board/annotation selection for free.
## LATE-BOUND multi-select access. These wrap the A8u1 base-class API through
## has_method + call() because a BARE self-call to an inherited-but-new base
## member is PARSE-resolved against whatever AnnotationHost the running core
## ships — on a pre-A8u1 core it is "Function not found in base self" and this
## whole script fails to load, taking every dependent suite with it (CI run
## 30689717389; hint pcb-plugin/off-tree-core-api-coupling, variant 2). On an
## old core the selection set degrades to empty = the single-id world.
func _selected_ids_compat() -> PackedStringArray:
	if has_method("get_selected_annotation_ids"):
		var ids: Variant = call("get_selected_annotation_ids")
		if ids is PackedStringArray:
			return ids
	return PackedStringArray()


func _set_selected_ids_compat(ids: PackedStringArray, primary: String = "") -> void:
	if has_method("set_selected_annotation_ids"):
		call("set_selected_annotation_ids", ids, primary)


func add_annotations_to_selection(ids: PackedStringArray) -> void:
	if ids.is_empty():
		return
	var result := _selected_ids_compat()
	for id in ids:
		if not result.has(id):
			result.append(id)
	# Primary = the topmost annotation this sweep sat on (document order).
	_set_selected_ids_compat(result, ids[ids.size() - 1])
	_redraw_overlay()


func clear_annotation_selection() -> void:
	if _selected_ids_compat().is_empty():
		return
	_set_selected_ids_compat(PackedStringArray())
	_redraw_overlay()


func selected_annotation_count() -> int:
	return _selected_ids_compat().size()


## Delete every selected annotation and return how many went. THERE IS NO UNDO
## for this half — the annotation substrate has no undo stack at all — which is
## why the canvas announces the count rather than deleting silently.
func delete_selected_annotations() -> int:
	var doomed := _selected_ids_compat()
	if doomed.is_empty():
		return 0
	for id in doomed:
		remove_annotation(id)
	_set_selected_ids_compat(PackedStringArray())
	_redraw_overlay()
	return doomed.size()


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
## Precedence:  pad ("pad:U1.3") → via ("via:GND@(50.8, 86.6)") →
##              component ("component:U3") → trace ("trace:GND") →
##              fallback ("canvas.point (x.x, y.y) mm").
## Stamped into annotation["anchored_to"] by AnnotationHost._stamp_anchor on
## add/update; surfaced by minerva_annotations_list via AnnotationSchema.
##
## Via outranks component and trace (owner HITL, docket 019fcb06e8d0): a via is a
## POINT entity like a pad — an annotation head landing inside its disc means
## the via, not the copper run it happens to stitch. Before this tier existed,
## "Remove this via" resolved to "trace:GND" and the agent had to re-derive
## the target from raw geometry. Pad stays first: a pad carries the more
## specific pin identity, and the two rarely overlap.
func describe_point(doc_pos: Vector2) -> String:
	var data = _board_data()
	if data == null:
		return _canvas_point_label(doc_pos)

	# 1. pad — a specific pin/pad of a component.
	var pad_ref := _pad_at(doc_pos)
	if not pad_ref.is_empty():
		return "pad:" + pad_ref

	# 2. via — a point entity; label by net (falling back to via id), with the
	# position so N same-net stitching vias stay distinguishable in the string
	# form (anchor_detail carries the exact id).
	var via_id := str(data.get_via_at(doc_pos, _VIA_HIT_MIN_RADIUS_MM))
	if not via_id.is_empty():
		var via: Dictionary = data.get_via(via_id)
		var via_net := str(via.get("net_name", ""))
		var via_pos: Vector2 = data.via_position(via)
		return "via:%s@(%.1f, %.1f)" % [
			via_net if not via_net.is_empty() else via_id, via_pos.x, via_pos.y]

	# 3. component — inside a component body but not on a pad.
	var comp_id := str(data.get_component_at(doc_pos))
	if not comp_id.is_empty():
		return "component:" + comp_id

	# 4. trace — on a routed trace; label by its net (falling back to trace id).
	var trace_id := str(data.get_trace_at(doc_pos, _TRACE_HIT_THRESHOLD_MM))
	if not trace_id.is_empty():
		var trace = data.get_trace(trace_id)
		var net_name := str(trace.net_name) if trace != null else ""
		return "trace:" + (net_name if not net_name.is_empty() else trace_id)

	# 5. fallback — a bare board point.
	return _canvas_point_label(doc_pos)


## Minimum click/anchor slack for the via tier: a hair over this board's common
## 0.4mm via radius so an annotation head placed by eye still lands the via,
## but far under _PAD_HIT_RADIUS_MM so a via 5mm away never claims a point.
## get_via_at maxf's this with each via's true radius, so larger vias keep
## their full disc.
const _VIA_HIT_MIN_RADIUS_MM := 0.5


## Structured anchor resolution for ONE annotation (LLM ergonomics, docket
## 019fcafd) — the machine-readable twin of describe_point's string. Called
## duck-typed by minerva_annotations_list on live hosts; returns {} when the
## anchor point resolves to nothing (the entry simply omits anchor_detail).
## Same tier order as describe_point; every hit carries the entity id, net
## (when it has one), position (board mm) and distance_mm from the anchor
## point, so an agent can verify the resolution instead of trusting it.
func describe_anchor_detail(annotation: Dictionary) -> Dictionary:
	var data = _board_data()
	if data == null or _registry == null:
		return {}
	var kind = _registry.get_annotation_kind(StringName(str(annotation.get("kind", ""))))
	if kind == null:
		return {}
	var point: Vector2 = kind.primary_anchor_point(annotation)

	var pad_hit := pad_at(point, _PAD_HIT_RADIUS_MM)
	if not pad_hit.is_empty():
		var pad_pos: Vector2 = pad_hit.get("position", Vector2.ZERO)
		return {
			"kind": "pad",
			"id": "%s.%s" % [str(pad_hit.get("component", "")), str(pad_hit.get("pin", ""))],
			"position": [pad_pos.x, pad_pos.y],
			"distance_mm": snappedf(pad_pos.distance_to(point), 0.001),
		}

	var via_id := str(data.get_via_at(point, _VIA_HIT_MIN_RADIUS_MM))
	if not via_id.is_empty():
		var via: Dictionary = data.get_via(via_id)
		var via_pos: Vector2 = data.via_position(via)
		return {
			"kind": "via",
			"id": via_id,
			"net": str(via.get("net_name", "")),
			"position": [via_pos.x, via_pos.y],
			"distance_mm": snappedf(via_pos.distance_to(point), 0.001),
		}

	var comp_id := str(data.get_component_at(point))
	if not comp_id.is_empty():
		return {"kind": "component", "id": comp_id, "distance_mm": 0.0}

	var trace_id := str(data.get_trace_at(point, _TRACE_HIT_THRESHOLD_MM))
	if not trace_id.is_empty():
		var trace = data.get_trace(trace_id)
		return {
			"kind": "trace",
			"id": trace_id,
			"net": str(trace.net_name) if trace != null else "",
		}

	return {}


func _canvas_point_label(doc_pos: Vector2) -> String:
	return "canvas.point (%.1f, %.1f) mm" % [doc_pos.x, doc_pos.y]


## Nearest pin/pad of any component within _PAD_HIT_RADIUS_MM of doc_pos.
## Returns "<component_id>.<pin_name>" or "" when nothing is close enough.
## Thin wrapper over the public pad_at() lookup (WC-1 pin inspector round) — the
## precedence-tier-1 hit test used to be duplicated inline here; now there is one
## hit-test implementation, reused by describe_point, the canvas inspector, and
## the MCP parity tool.
func _pad_at(doc_pos: Vector2) -> String:
	var hit := pad_at(doc_pos, _PAD_HIT_RADIUS_MM)
	if hit.is_empty():
		return ""
	return "%s.%s" % [str(hit.get("component", "")), str(hit.get("pin", ""))]


## PUBLIC, side-effect-free pad lookup (WC-1 pin inspector, contract §2). Nearest
## pad within radius_mm of doc_pos wins; ties break deterministically by
## (component, pin) lexicographic order (never insertion-order-dependent).
## Returns {} on miss, else {component: String, pin: String, position: Vector2
## (board mm, the live pin world position)}.
##
## component_filter (bug 019fb59c1a89): optional Callable(comp_id: String) ->
## bool applied BEFORE the distance sort, so a filtered-out pad never shadows a
## visible one. The canvas inspector passes its layer-view predicate; MCP
## callers (describe_point, the parity tool) pass nothing and stay
## view-independent by design.
func pad_at(doc_pos: Vector2, radius_mm: float = 5.0,
		component_filter: Callable = Callable()) -> Dictionary:
	var data = _board_data()
	if data == null:
		return {}
	var candidates: Array = []
	for comp_id in data.components:
		if component_filter.is_valid() and not component_filter.call(str(comp_id)):
			continue
		var comp = data.components[comp_id]
		for pin_name in comp.pins:
			var world_pin: Vector2 = comp.get_pin_world_position(pin_name)
			var d := world_pin.distance_to(doc_pos)
			if d <= radius_mm:
				candidates.append({
					"component": str(comp_id), "pin": str(pin_name),
					"position": world_pin, "dist": d,
				})
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(a["dist"], b["dist"]):
			return a["dist"] < b["dist"]
		if a["component"] != b["component"]:
			return a["component"] < b["component"]
		return a["pin"] < b["pin"])
	var best: Dictionary = candidates[0]
	return {"component": best["component"], "pin": best["pin"], "position": best["position"]}


## PUBLIC, side-effect-free pin-detail lookup (WC-1 pin inspector, contract §2).
## {} on an unknown component/pin, else {ref: "Component.Pin", pin_name: String
## (footprint geometry name via pcb_component.get_pin_name, "" if none),
## net: String ("" if unconnected), net_members: [other "Component.Pin" refs on
## the same net], trace_ids: [String], trace_count: int}.
##
## trace_ids: traces on the pin's net whose start or end waypoint lands on the
## pad (within _PAD_HIT_RADIUS_MM — traces are drawn pad-snapped, so this is a
## tolerance, not a second hit-test system).
func pin_info(component: String, pin: String) -> Dictionary:
	var data = _board_data()
	if data == null:
		return {}
	var comp = data.get_component(component)
	if comp == null or not comp.pins.has(pin):
		return {}

	var pin_name: String = comp.get_pin_name(pin)
	var net: String = data.find_net_for_pin(component, pin)

	var net_members: Array = []
	if not net.is_empty():
		var net_obj = data.get_net(net)
		if net_obj != null:
			for member in net_obj.pins:
				var m_comp := str((member as Dictionary).get("component_id", ""))
				var m_pin := str((member as Dictionary).get("pin_name", ""))
				if m_comp == component and m_pin == pin:
					continue
				net_members.append("%s.%s" % [m_comp, m_pin])

	var trace_ids: Array = []
	if not net.is_empty():
		var pad_pos: Vector2 = comp.get_pin_world_position(pin)
		for trace in data.get_traces_for_net(net):
			if trace == null:
				continue
			var start: Vector2 = trace.get_start()
			var end: Vector2 = trace.get_end()
			if start.distance_to(pad_pos) <= _PAD_HIT_RADIUS_MM or end.distance_to(pad_pos) <= _PAD_HIT_RADIUS_MM:
				trace_ids.append(str(trace.id))

	return {
		"ref": "%s.%s" % [component, pin],
		"pin_name": pin_name,
		"net": net,
		"net_members": net_members,
		"trace_ids": trace_ids,
		"trace_count": trace_ids.size(),
	}


## Native-parity display rule (contract §2): footprint geometry pin_name wins
## over net; an unconnected pin reads "(unconnected)". Shared by the panel's Pin
## Info section AND minerva_pcb_pin_info (MCP) so READ ≡ what the UI shows —
## one rule, not two copies that can drift.
func pin_display_name(info: Dictionary) -> String:
	var pin_name := str(info.get("pin_name", ""))
	if not pin_name.is_empty():
		return pin_name
	var net := str(info.get("net", ""))
	if not net.is_empty():
		return net
	return "(unconnected)"


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


## Accessor for the bound canvas (the PCB view Control) so the panel-tool surface
## can drive the camera (minerva_pcb_set_view) without reaching into a private
## field. Null when the panel is detached/headless.
func get_canvas():
	return _canvas


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
	_backfill_route_hint_dest_point(stored)
	_annotations.append(stored)
	annotations_changed.emit()
	return ann_id


## Base-API alias so callers using AnnotationHost.add_annotation() work.
func add_annotation(annotation: Dictionary) -> String:
	return add_annotation_v2(annotation)


## RETIRED (S5, C4b, DCR 019f7095c395): is_annotation_superseded — supersession
## existed only to hide a hint answered by a live PROPOSAL ANNOTATION (same
## routed geometry, drawn twice otherwise). Proposals no longer exist as
## annotations (see panel_tools.gd _propose_into_workspace) and route hints
## are never superseded by anything else, so this duck-typed hook (core's
## WorkflowAnnotationList consulted it via has_method) is removed rather than
## kept as a permanently-false stub — "everything proposal-shaped goes". A
## pre-S5 .pcbskel may still carry legacy proposal annotations with a stale
## kind_payload.proposal_for; those are dropped at load time with a notice
## (PCBPanel.gd), never read by this host once loaded.


## View-flag relay (canvas show_hint_labels → kind label gate). The kind's
## render() has no host/canvas access, so the flag lives on the kind instance
## in THIS host's registry.
func set_hint_labels_visible(visible: bool) -> void:
	if _registry == null:
		return
	var kind = _registry.get_annotation_kind(&"pcb_route_hint")
	if kind != null and "labels_visible" in kind:
		kind.labels_visible = visible


## MCP-authored route hints carry dest_pins but no dest_point (the render/
## hit-test cache the author tools stamp at commit). Resolve dest_pins[0] to
## its live pad position at write time so agent-authored hints render their
## full polyline (HITL-caught: first/last segments missing). Tool-authored
## envelopes already carry dest_point and are left untouched.
func _backfill_route_hint_dest_point(stored: Dictionary) -> void:
	if str(stored.get("kind", "")) != "pcb_route_hint":
		return
	var kp: Variant = stored.get("kind_payload", {})
	if not (kp is Dictionary) or kp.has("dest_point"):
		return
	var dests: Variant = kp.get("dest_pins", [])
	if not (dests is Array) or dests.is_empty():
		return
	var ref := str(dests[0])
	var dot := ref.rfind(".")
	if dot < 0:
		return
	var data = get_board_data()
	if data == null:
		return
	var comp = data.components.get(ref.left(dot), null)
	if comp == null or not comp.has_method("get_pin_world_position"):
		return
	var pos: Vector2 = comp.get_pin_world_position(ref.substr(dot + 1))
	kp["dest_point"] = [pos.x, pos.y]
	stored["kind_payload"] = kp


## Build a conformant pcb_route_hint envelope (no id — add_annotation_v2 assigns
## one). x_mm/y_mm are board millimetres. Shared by add_route_hint_at (MCP/test
## path) and the kind's RouteHintAuthorTool (toolbar click-to-author path).
##
## width_mm is Variant, NOT float, and defaults to null (019fa73a191e): a
## GDScript float cannot be null, so a typed `float = 0.25` default had no way
## to express "the author did not pick a width" — every hint, however
## authored, stamped an explicit 0.25mm that OUTRANKS the board's own
## design_rules.defaults.trace_width_mm in the routing precedence chain
## (agent_router/router.py's "caller_or_hint" beats "board_rules"), discarding
## a dimension the board actually stated. When width_mm is null here, the key
## is omitted from kind_payload entirely, so an unwidened hint gesture falls
## through to the board's own rule downstream instead of a UI-invented one.
## Do NOT use 0.0 as a "no width" sentinel — pcb_route_hint_kind.gd's render
## (:1114) and summary (:1214) logic both key off `width_mm > 0.0`, so a
## stored 0.0 and an absent key are visually and observably identical, which
## would make this exact defect undetectable again.
func build_route_hint_envelope(
		x_mm: float,
		y_mm: float,
		text: String = "",
		layer: String = "F.Cu",
		hint_type: String = "waypoint",
		waypoints: Array = [],
		author_kind: String = "human",
		detail_level: String = "",
		width_mm: Variant = null,
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
	var kind_payload := {
		"hint_type": hint_type,
		"detail_level": detail_level,
		"layer": layer,
		"source_pins": source_pins.duplicate(),
		"dest_pins": dest_pins.duplicate(),
		"text": text,
		"waypoints": waypoints,
	}
	if width_mm != null:
		kind_payload["width_mm"] = width_mm
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
		"kind_payload": kind_payload,
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


## THE mutate-with-history seam (C4 deliverable 1): both the canvas
## manipulation-tool path (AnnotationOverlay._on_tool_annotation_modified,
## which every AnnotationAuthorTool subclass — the bend-handle edit tool
## included — routes through when it emits annotation_modified) and the MCP
## update path (MCPAnnotationTools._annotations_update calls
## host.update_annotation(target_id, existing) directly) already funnel
## through this ONE method. Hooking history here — rather than adding a
## separate "mutate_with_history" entry point — means neither caller has to
## opt in, so an agent's minerva_annotations_update edit and a human's
## bend-drag are captured identically (reliability: no seam an editor can
## bypass; see _apply_hint_history below).
func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
	# Codex 1047 fix round, verdict 3: every call starts with a clean slate —
	# the refusal record below describes THIS call or nothing.
	last_update_refusal = {}
	for i in range(_annotations.size()):
		if _annotations[i] is Dictionary and str(_annotations[i].get("id", "")) == annotation_id:
			var old: Dictionary = _annotations[i]
			# Epoch UX1 station 12 (DCR 019fd095e694, docket 019fd057ea0b
			# comment 1028: "never accept an edit that cannot affect
			# routing"): refuse BEFORE any mutation — see
			# _refuses_superseded_waypoint_edit's own doc.
			if _refuses_superseded_waypoint_edit(old, new_annotation):
				# Codex 1047 fix round, verdict 3: the refusal is now NAMED,
				# not just a bool + push_warning — a caller (live MCP, a panel
				# surface) reads last_update_refusal right after the false
				# return and can surface the reason and BOTH exits: steer the
				# constraint, or reclaim the waypoints by converting the hint
				# to 'detailed' (minerva_pcb_hint_convert_to_detailed,
				# verdict 4's named operation).
				last_update_refusal = {
					"error": "waypoints_superseded",
					"hint_id": annotation_id,
					"constraint_revision": int(_hint_payload_of(old).get(
						"waypoints_superseded_by_constraint_revision", 0)),
					"note": "kind_payload.waypoints on this hint is superseded by its task's "
						+ "routing_constraint — routing no longer reads the hint's own waypoints, "
						+ "so this edit could never affect copper. Steer the route in the live "
						+ "editor via minerva_pcb_workspace_reroute_route (`corridor` or "
						+ "`preserve_shape_as_corridor`), or reclaim manual waypoint control with "
						+ "minerva_pcb_hint_convert_to_detailed (clears the task constraint and "
						+ "converts this hint to 'detailed' so its waypoints are editable and "
						+ "routed as-drawn).",
				}
				push_warning(("[PcbAnnotationHost] refused waypoints edit on pcb_route_hint '%s' — " +
					"its kind_payload.waypoints_superseded_by_constraint_revision marker means " +
					"this field is inert for routing; the task's routing_constraint is the real " +
					"channel now — steer it via minerva_pcb_workspace_reroute_route's `corridor` " +
					"or `preserve_shape_as_corridor` argument, or reclaim the waypoints with " +
					"minerva_pcb_hint_convert_to_detailed") % annotation_id)
				return false
			var updated := new_annotation.duplicate(true)
			updated["id"] = annotation_id
			# H2-1 (fix round, station 12): the marker is HOST-OWNED state, not
			# editor-authored data — re-arm it on `updated` before it is stored.
			# Must run AFTER the refusal check (which still needs to see `old`
			# carry the marker so a same-call waypoints-change-plus-marker-drop
			# is caught) and BEFORE _apply_hint_history/storage, unconditionally
			# — including the _suppress_hint_history undo/redo path (H2-2),
			# which is exactly what lets a restored pre-seed snapshot re-arm
			# the guard for the NEXT edit. See _reinject_superseded_marker's
			# own doc.
			_reinject_superseded_marker(old, updated)
			_apply_hint_history(old, updated)
			# Re-stamp anchored_to so it reflects the current board (a component
			# may have moved under the marker since it was authored).
			AnnotationHost._stamp_anchor(updated, self)
			_backfill_route_hint_dest_point(updated)
			_annotations[i] = updated
			annotations_changed.emit()
			return true
	return false


# ── Per-hint revision history (C4 deliverable 1) ──────────────────────────────

## Carries/updates the pcb_route_hint revision+redo stacks across an
## update_annotation() call. No-op for every other kind. When one of the
## tracked fields actually changed, pushes `old`'s PRIOR payload onto the
## bounded revision stack (cap HINT_HISTORY_CAP, oldest dropped) and clears
## the redo stack (a fresh edit invalidates whatever was undone past this
## point — standard undo/redo semantics). When nothing tracked changed (e.g.
## a lifecycle-only MCP patch), the existing stacks are carried forward
## unchanged so they are never silently dropped. While
## _suppress_hint_history is set (undo_hint_revision/redo_hint_revision
## restoring a snapshot), this is a deliberate no-op — the caller has already
## computed and stamped the correct stacks onto `updated` itself.
func _apply_hint_history(old: Dictionary, updated: Dictionary) -> void:
	if str(old.get("kind", "")) != "pcb_route_hint":
		return
	if _suppress_hint_history:
		return
	var old_payload := _hint_payload_of(old)
	var new_payload := _hint_payload_of(updated)
	if _hint_payload_changed(old_payload, new_payload):
		var revisions := _hint_stack_of(old, _REVISION_KEY)
		revisions.append(old_payload.duplicate(true))
		if revisions.size() > HINT_HISTORY_CAP:
			revisions.pop_front()
		updated[_REVISION_KEY] = revisions
		updated[_REDO_KEY] = []
	else:
		updated[_REVISION_KEY] = _hint_stack_of(old, _REVISION_KEY)
		updated[_REDO_KEY] = _hint_stack_of(old, _REDO_KEY)


## Restore the previous kind_payload for a pcb_route_hint (undo), pushing the
## CURRENT payload onto the redo stack. Returns {ok:true, kind_payload:
## <restored>} on success, or {ok:false, error:"not_found"|"not_a_route_hint"
## |"no_prior_revision"} — never crashes. Shared by the panel's Ctrl+Z-while-
## selected UI seam (PCBPanel._unhandled_key_input) and the panel-executed
## MCP tool minerva_pcb_hint_undo (C4 deliverable 2).
func undo_hint_revision(id: String) -> Dictionary:
	return _shift_hint_revision(id, _REVISION_KEY, _REDO_KEY)


## Redo counterpart of undo_hint_revision — restores the most recently undone
## payload, pushing the current payload back onto the revision (undo) stack.
func redo_hint_revision(id: String) -> Dictionary:
	return _shift_hint_revision(id, _REDO_KEY, _REVISION_KEY)


## Shared undo/redo engine: pop the last snapshot off `from_key`'s stack,
## apply it as the hint's new kind_payload, and push the payload it replaced
## onto `to_key`'s stack (bounded, oldest dropped). Goes through
## update_annotation() (with _suppress_hint_history set) so every other
## side effect of a normal update — anchor re-stamp, annotations_changed,
## sidecar-dirty relay — stays IDENTICAL between a human edit, an agent edit,
## and an undo/redo of either.
func _shift_hint_revision(id: String, from_key: String, to_key: String) -> Dictionary:
	var idx := _find_annotation_index(id)
	if idx < 0:
		return {"ok": false, "error": "not_found"}
	var ann: Dictionary = _annotations[idx]
	if str(ann.get("kind", "")) != "pcb_route_hint":
		return {"ok": false, "error": "not_a_route_hint"}

	var from_stack := _hint_stack_of(ann, from_key)
	if from_stack.is_empty():
		return {"ok": false, "error": "no_prior_revision" if from_key == _REVISION_KEY else "no_redo_available"}
	var restored_payload: Dictionary = (from_stack.pop_back() as Dictionary).duplicate(true)

	var to_stack := _hint_stack_of(ann, to_key)
	to_stack.append(_hint_payload_of(ann).duplicate(true))
	if to_stack.size() > HINT_HISTORY_CAP:
		to_stack.pop_front()

	var updated := ann.duplicate(true)
	updated["kind_payload"] = restored_payload
	updated["updated_at"] = int(Time.get_unix_time_from_system())
	updated[from_key] = from_stack
	updated[to_key] = to_stack

	_suppress_hint_history = true
	var ok := update_annotation(id, updated)
	_suppress_hint_history = false
	if not ok:
		return {"ok": false, "error": "update_failed"}
	return {"ok": true, "kind_payload": restored_payload}


## Route-request envelopes never carry per-hint edit-history bookkeeping (C4
## deliverable 1 contract: "excluded from route-request building") — it's
## editing-session state, not routing input, and would bloat/risk the 64KiB
## IPC payload cap after a long editing session. PCBPanel.route_board() calls
## this for every pcb_route_hint envelope it hands to the router worker.
## Single source of truth for the two history keys' names (kept here, not
## duplicated in the panel).
func strip_hint_history(ann: Dictionary) -> Dictionary:
	var out := ann.duplicate(true)
	out.erase(_REVISION_KEY)
	out.erase(_REDO_KEY)
	return out


func _find_annotation_index(id: String) -> int:
	for i in range(_annotations.size()):
		if _annotations[i] is Dictionary and str((_annotations[i] as Dictionary).get("id", "")) == id:
			return i
	return -1


func _hint_payload_of(ann: Dictionary) -> Dictionary:
	var p: Variant = ann.get("kind_payload", {})
	return p if p is Dictionary else {}


func _hint_stack_of(ann: Dictionary, key: String) -> Array:
	var s: Variant = ann.get(key, null)
	if s is Array:
		return (s as Array).duplicate(true)
	return []


static func _hint_payload_changed(a: Dictionary, b: Dictionary) -> bool:
	for f in _HINT_HISTORY_FIELDS:
		if JSON.stringify(a.get(f, null)) != JSON.stringify(b.get(f, null)):
			return true
	return false


## Epoch UX1 station 12 (DCR 019fd095e694, docket 019fd057ea0b comment 1028
## "never accept an edit that cannot affect routing"): true iff `old` is a
## pcb_route_hint whose kind_payload already carries
## waypoints_superseded_by_constraint_revision (stamped by
## panel_tools.gd's _seed_legacy_waypoint_constraints — station 12's legacy
## seed — or station 9's _stamp_waypoints_superseded for a live steer; ONE
## marker, one meaning regardless of which channel wrote the constraint that
## made the field inert) AND `new_annotation` CHANGES kind_payload.waypoints
## relative to `old`.
##
## Once that marker exists, panel_tools.gd's route_bridge.hints_to_router
## OVERRIDES kind_payload.waypoints outright with the task's
## routing_constraint (that function's own doc: the constraint's corridor
## REPLACES the hint's waypoints, never merged) — so an edit to the waypoints
## array literally cannot change what gets routed. Accepting it anyway would
## be the same silent-input failure class comment 1028 exists to close: an
## editor sees the edit "succeed" and reasonably believes it steers routing,
## when nothing downstream will ever read the new value again.
##
## Only a WAYPOINTS change is refused. Every other field on the SAME
## superseded hint — note, text, lifecycle, layer, … — passes through
## unaffected; this is not a freeze on the annotation, only on the one field
## that no longer means anything. A 'detailed' hint never carries this marker
## (station 12 never seeds one — its waypoints ARE consumed, literally, by
## the bridge's as-drawn path — see _seed_legacy_waypoint_constraints' own
## doc), so this guard never fires for it: it bypasses this mechanism by
## construction, unconditionally, same as it bypasses seeding.
func _refuses_superseded_waypoint_edit(old: Dictionary, new_annotation: Dictionary) -> bool:
	# H2-2 (fix round, station 12): undo_hint_revision/redo_hint_revision
	# (_shift_hint_revision) route their snapshot restore through this SAME
	# update_annotation() call, with _suppress_hint_history set for its
	# duration — deliberately, so a restore is never itself recorded as a new
	# edit (see _apply_hint_history's own doc). A restored PRIOR payload can
	# legitimately carry different waypoints than the current (superseded)
	# payload — that IS the undo, not an editor trying to sneak a steering
	# change past the guard — so it must never be refused here. update_
	# annotation's H2-1 re-injection (see _reinject_superseded_marker) still
	# runs on this same call and puts the marker back onto the restored
	# annotation whenever `old` carried one, so the guard RE-ARMS immediately
	# after: the undo itself always succeeds, but a fresh waypoints edit
	# following it is refused again exactly as before the undo.
	if _suppress_hint_history:
		return false
	# Codex 1047 fix round, verdict 4: release_superseded_waypoints() is the
	# ONE host-sanctioned strip of the marker — its single update must not be
	# refusable (belt-and-braces: the release never changes waypoints, so this
	# guard would not fire anyway, but the release's contract is "cannot be
	# refused by the supersession machinery it is dismantling").
	if _bypass_superseded_release:
		return false
	if str(old.get("kind", "")) != "pcb_route_hint":
		return false
	var old_kp: Dictionary = _hint_payload_of(old)
	if not old_kp.has("waypoints_superseded_by_constraint_revision"):
		return false
	var new_kp: Dictionary = _hint_payload_of(new_annotation)
	var old_wp: Variant = old_kp.get("waypoints", [])
	var new_wp: Variant = new_kp.get("waypoints", [])
	return JSON.stringify(old_wp) != JSON.stringify(new_wp)


## H2-1 (cold review, fix round — DCR 019fd095e694 station 12):
## waypoints_superseded_by_constraint_revision is HOST-OWNED state — it
## records a fact about THIS host's own workspace (a task now carries a
## routing_constraint that overrides this hint's waypoints), not something an
## editor authors or should be able to author away. An incoming `updated`
## payload that simply OMITS the marker `old` already carried — whether by
## accident (a partial-payload caller, e.g. an MCP patch that round-trips
## only the fields it means to touch) or by a deliberate two-step bypass
## (first an update that drops the marker with waypoints left untouched,
## legally passing _refuses_superseded_waypoint_edit since only WAYPOINTS
## changes are checked, THEN a second update that changes waypoints against
## an annotation that no longer appears superseded) — must not be able to
## erase it. Re-injecting it here, unconditionally, on every update_
## annotation call closes both: the accidental strip is simply restored, and
## the deliberate two-step bypass never gets a marker-less annotation to
## stage its second step against, because THIS call already put it back.
##
## No-op when `old` is not a pcb_route_hint, carries no marker to begin with,
## or `updated` already names one explicitly (a caller that DELIBERATELY sets
## a different revision number — e.g. this station's own re-stamp after a
## fresh steer — is never overridden by a stale re-injection).
##
## Codex 1047 fix round, verdict 4+5 additions:
##   - While _bypass_superseded_release is set (release_superseded_waypoints'
##     single sanctioned update), this whole function is a no-op — the strip
##     IS the operation, not an accident to repair.
##   - The verdict-5 offline-lock keys (_locked_fields/_lock_reason, stamped
##     beside the marker by panel_tools._stamp_waypoints_superseded so core's
##     OFFLINE sidecar-update path can refuse locked-field patches) are
##     host-owned for exactly the marker's own reason, and ride the same
##     re-injection: a marker-preserving update that dropped only the lock
##     keys would otherwise save a sidecar whose offline protection silently
##     vanished. They are restored whenever `old` carried the marker and
##     `updated` omits them — handled SEPARATELY from the marker's own
##     already-named early-out, so a caller keeping the marker but dropping a
##     lock key still gets the lock key back.
func _reinject_superseded_marker(old: Dictionary, updated: Dictionary) -> void:
	if _bypass_superseded_release:
		return
	if str(old.get("kind", "")) != "pcb_route_hint":
		return
	var old_kp: Dictionary = _hint_payload_of(old)
	if not old_kp.has("waypoints_superseded_by_constraint_revision"):
		return
	var new_kp: Dictionary = _hint_payload_of(updated).duplicate(true)
	var patched := false
	if not new_kp.has("waypoints_superseded_by_constraint_revision"):
		new_kp["waypoints_superseded_by_constraint_revision"] = old_kp["waypoints_superseded_by_constraint_revision"]
		patched = true
	# Verdict 5: the offline-lock keys ride the marker (see the doc above).
	for lock_key in ["_locked_fields", "_lock_reason"]:
		if old_kp.has(lock_key) and not new_kp.has(lock_key):
			var v: Variant = old_kp[lock_key]
			new_kp[lock_key] = (v as Array).duplicate(true) if v is Array else v
			patched = true
	if patched:
		updated["kind_payload"] = new_kp


## Codex 1047 fix round, verdict 4: the ONE host-sanctioned strip of the
## station-12 supersession marker — the annotation-side half of the
## guided→detailed conversion (panel_tools._hint_convert_to_detailed owns the
## workspace-side half: clearing the task's routing_constraint FIRST, or
## refusing by name when the constraint is not singly owned; this method never
## reads the workspace at all, deliberately — a torn marker-only state, where
## the constraint is already gone, must still be releasable).
##
## Performs ONE update_annotation call with _bypass_superseded_release set, so
## the H2-1 re-injection guard does not put the marker straight back and the
## edit-refusal guard cannot fire: strips
## waypoints_superseded_by_constraint_revision plus the verdict-5 offline-lock
## keys (_locked_fields/_lock_reason), and sets kind_payload.detail_level =
## "detailed" — the level station 12's seeder and the render taxonomy both
## already treat as "waypoints are the literal, as-drawn routing input" (the
## seeder's own `detailed` gate is what makes the conversion durable: a later
## propose never re-seeds/re-stamps this hint).
##
## UNDOABILITY DECISION (deliberate, per the fix-round brief): the conversion
## IS one user-visible history step — _suppress_hint_history is NOT set, so
## _apply_hint_history pushes the prior payload (marker, lock keys and
## 'guided' detail_level included) onto the hint's revision stack, exactly
## like any other explicit edit. Rationale: unlike the bookkeeping stamp
## (which suppresses history because nobody "did" it), converting is an
## explicit user/agent-level act and Ctrl+Z/minerva_pcb_hint_undo should be
## able to take it back. KNOWN ASYMMETRY, on purpose: undoing the conversion
## restores only the ANNOTATION side (the marker returns via the snapshot;
## the re-injection seam then keeps it armed) — the cleared task constraint
## is NOT resurrected, because the workspace has no history seam for
## constraints. That leaves the documented marker-only torn state, which has
## TWO named recoveries: re-running the conversion (via _hint_convert_to_
## detailed's torn-state branch) completes the release again immediately, and
## — Codex 1047 fix round, verdict 6 — the next board LOAD repairs it
## deterministically (panel_tools.gd reconcile_superseded_waypoint_state
## strips the stale marker through reconcile_strip_superseded_marker below,
## PRESERVING the restored 'guided' detail_level so the seeder resumes the
## guided flow on the next propose — see that pass's own doc for the rule).
##
## Returns {ok:true} on success, or {ok:false, error:
## "not_found"|"not_a_route_hint"|"update_failed"} — never crashes.
func release_superseded_waypoints(hint_id: String) -> Dictionary:
	return _strip_superseded_state(hint_id, true, false)


## Codex 1047 fix round, verdict 6: the LOAD-TIME RECONCILIATION strip — the
## second (and only other) host-sanctioned removal of the supersession marker
## + verdict-5 offline-lock keys, used exclusively by panel_tools.gd's
## reconcile_superseded_waypoint_state for the marker-without-constraint torn
## state (marker present on the loaded annotation while no owner-attributed
## task constraint governs the hint — the workspace store is authoritative,
## the marker is derived, so a marker the workspace cannot back is stale).
##
## Differs from release_superseded_waypoints on exactly the two axes that
## make it BOOKKEEPING rather than a user-level conversion:
##   - detail_level is PRESERVED as found, never forced to "detailed".
##     Reconciliation cannot know whether the tear came from a crash between
##     the two seeding writes (pre-torn intent: guided) or from an undo of a
##     conversion (undo restored the pre-conversion payload wholesale,
##     detail_level "guided" included) — and BOTH shapes carry the
##     detail_level that describes the pre-torn intent, so preserving it is
##     the deterministic rule that is honest in every reachable case: a
##     'guided' hint resumes guided seeding on the next propose (waypoints
##     intact, the seeder rebuilds constraint + marker), and nothing ever
##     invents a 'detailed' claim nobody made.
##   - _suppress_hint_history is set for the single update, so the repair
##     never becomes an undoable history step (nobody "did" it — same
##     rationale as the stamp path, whose marker/lock writes stay out of
##     history because they touch no _HINT_HISTORY_FIELDS entry; the
##     suppression here is belt-and-braces on top of that same property).
##
## No-op by contract when the hint carries neither the marker nor a lock key
## ({ok:true, changed:false}) so the reconciliation pass stays idempotent
## without special-casing. Never crashes.
func reconcile_strip_superseded_marker(hint_id: String) -> Dictionary:
	return _strip_superseded_state(hint_id, false, true)


## Shared body of the two sanctioned strips above (Codex 1047 fix round,
## verdicts 4+6 — ONE implementation so the bypass-flag discipline can never
## drift between them). `set_detailed` is the conversion's detail_level
## promotion; `bookkeeping` routes the update through the history-suppression
## seam. Both strips run their single update_annotation call with
## _bypass_superseded_release set, so the H2-1 re-injection guard does not put
## the marker straight back and the edit-refusal guard cannot fire.
func _strip_superseded_state(hint_id: String, set_detailed: bool, bookkeeping: bool) -> Dictionary:
	var ann: Dictionary = get_by_id(hint_id)
	if ann.is_empty():
		return {"ok": false, "error": "not_found"}
	if str(ann.get("kind", "")) != "pcb_route_hint":
		return {"ok": false, "error": "not_a_route_hint"}
	var updated := ann.duplicate(true)
	var kp: Dictionary = _hint_payload_of(updated).duplicate(true)
	var had_superseded_state: bool = kp.has("waypoints_superseded_by_constraint_revision") \
		or kp.has("_locked_fields") or kp.has("_lock_reason")
	if bookkeeping and not had_superseded_state:
		# Reconciliation's idempotence contract: nothing to strip is a clean
		# no-op, never a phantom write (the release path deliberately still
		# writes in this case — it must land detail_level "detailed" even on
		# a hint whose marker is already gone, see its own doc).
		return {"ok": true, "changed": false}
	kp.erase("waypoints_superseded_by_constraint_revision")
	kp.erase("_locked_fields")
	kp.erase("_lock_reason")
	if set_detailed:
		kp["detail_level"] = "detailed"
	updated["kind_payload"] = kp
	updated["updated_at"] = int(Time.get_unix_time_from_system())
	_bypass_superseded_release = true
	if bookkeeping:
		_suppress_hint_history = true
	var ok := update_annotation(hint_id, updated)
	if bookkeeping:
		_suppress_hint_history = false
	_bypass_superseded_release = false
	if not ok:
		return {"ok": false, "error": "update_failed"}
	return {"ok": true, "changed": true}


func update(annotation: Dictionary) -> void:
	var annotation_id := str(annotation.get("id", ""))
	if not annotation_id.is_empty():
		update_annotation(annotation_id, annotation)


func remove_annotation(annotation_id: String) -> bool:
	for i in range(_annotations.size()):
		if _annotations[i] is Dictionary and str(_annotations[i].get("id", "")) == annotation_id:
			var removed_kind := str((_annotations[i] as Dictionary).get("kind", ""))
			_annotations.remove_at(i)
			# Base contract: removing the selected annotation clears selection.
			if get_selected_annotation_id() == annotation_id:
				set_selected_annotation_id("")
			annotations_changed.emit()
			# H2-1 (cold review, DCR 019fd095e694/docket 019fd057ea0b comment
			# 1028's deletion-cascade precondition): removing a pcb_route_hint's
			# connectivity object cascades to its still-unanswered eager task —
			# see RoutingWorkspace.drop_empty_tasks_for_hint's own doc. A task
			# with a candidate is history and stays regardless of this removal.
			if removed_kind == "pcb_route_hint":
				_cascade_drop_empty_tasks_for_hint(annotation_id)
			return true
	return false


## H2-1's duck-typed seam: host → panel → workspace, the SAME hop
## _has_live_candidate (pcb_route_hint_kind.gd) and _get_workspace
## (panel_tools.gd) already use. Null-safe/headless-safe at every link — a
## host with no panel, a panel predating get_routing_workspace(), or a
## workspace predating drop_empty_tasks_for_hint all degrade to a no-op
## rather than erroring; a test double supplying only what it needs (e.g.
## test_workspace_tools.gd's stub panels) is exactly what this is for.
func _cascade_drop_empty_tasks_for_hint(hint_id: String) -> void:
	var panel = get_panel()
	if panel == null or not is_instance_valid(panel) or not panel.has_method("get_routing_workspace"):
		return
	var workspace = panel.get_routing_workspace()
	if workspace == null or not workspace.has_method("drop_empty_tasks_for_hint"):
		return
	workspace.drop_empty_tasks_for_hint(hint_id)


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
