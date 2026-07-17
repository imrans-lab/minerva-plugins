extends AnnotationKind
## PCB plugin annotation kind: pcb_route_hint (semantic-anchor round).
##
## A route hint is an author's suggestion for how a net/trace should be routed:
## an optional waypoint polyline on the board, on a named copper layer, from a
## source pad to a destination pad. It communicates intent ("route this corridor")
## and never becomes board state — pcb_interpret_route_hints reads it separately.
##
## Envelope shape (v2, must pass AnnotationV2Schema.validate_with_registry):
##   kind:    "pcb_route_hint"
##   anchor:  a pcb/board.point {plugin:"pcb", type:"board.point", id:{x,y}, …}
##            OR a pcb/pad       {plugin:"pcb", type:"pad", id:{component,pin}, …}
##   kind_payload:
##     hint_type:    "waypoint" | "single_trace" | "bus"   (default "waypoint")
##     detail_level: "sparse" | "guided" | "detailed"      (optional)
##     layer:        KiCAD layer, e.g. "F.Cu" / "B.Cu"      (default "F.Cu")
##     width_mm:     trace width in mm                       (optional, >0)
##     source_pins:  Array["U1.15", …]                       (optional)
##     dest_pins:    Array["J2.3", …]                        (optional)
##     text:         author instruction body                (optional)
##     waypoints:    Array[[x_mm, y_mm]]                     (optional, board mm)
##
## Envelope tolerance: the OLD skeleton payload (only hint_type/layer/text/
## waypoints) keeps validating and rendering — every new field is optional.
##
## Off-tree note: lives at C:/github/minerva-plugins/pcb/ui/kinds/, OUTSIDE
## Minerva's res:// tree. It MUST NOT declare a class_name — plugin-local
## class_names are unresolvable from the off-tree parser cache. Loaded via
## preload()/load() by PcbAnnotationHost.gd and the smoke test.

const _ANCHOR_TYPE_BOARD_POINT := "pcb/board.point"
const _ANCHOR_TYPE_PAD := "pcb/pad"

## Anchor-marker size: document-space (board mm), so it scales with board
## features instead of swallowing small parts (HITL-2 feedback: 5mm diamonds
## completely covered a 2.54mm-pitch header). Render keeps a small pixel
## floor so hints stay visible when zoomed far out.
const _MARKER_RADIUS: float = 1.25
const _MARKER_MIN_PX: float = 6.0

## View-flag: draw the per-hint summary label. Set by PcbAnnotationHost when
## the canvas's show_hint_labels toggle changes (default ON).
var labels_visible: bool = true
const _LABEL_COLOR := Color(0.92, 0.96, 0.98, 1.0)
const _LABEL_FONT_SIZE: int = 12

## Layer-tinted stroke hues (F.Cu vs B.Cu hue shift). Unknown layers → neutral.
## Human-hint palette (HITL-2 feedback): stays in the magenta/violet family so
## a committed hint NEVER reads as AI output — substrate cyan is reserved for
## AI authorship, and the old teal top-copper tint was indistinguishable from
## it on canvas. F.Cu matches the human preview color exactly (no color jump
## when a drawn hint commits). Distinct from real traces (red/blue), pads
## (copper/gold), and selection (yellow).
## Complementary layer pair (owner req 2026-07-17: magenta/violet were too
## close to separate visually). F.Cu keeps magenta (matches the human drawing
## preview — no color jump on commit); B.Cu takes its color-wheel complement,
## bright green (thin strokes stay distinct from the darker component fills).
const _COLOR_F_CU := Color(1.0, 0.5, 1.0, 0.95)      # magenta — top copper
const _COLOR_B_CU := Color(0.30, 1.0, 0.40, 0.95)    # green   — bottom copper (complement)
const _COLOR_OTHER := Color(0.85, 0.85, 0.85, 0.95)  # gray    — other/unspecified layer

## Path hit-test tolerance in document (board-mm) units, on top of stroke half-width.
const _HIT_THRESHOLD_MM: float = 0.6

const _VALID_HINT_TYPES := ["waypoint", "single_trace", "bus"]
const _VALID_DETAIL_LEVELS := ["sparse", "guided", "detailed"]

## The per-row "apply" action is a synchronous no-op pointer: real routing is an
## async worker round-trip that a sync run_action cannot await, so trace synthesis
## lives in the MCP tool minerva_pcb_apply_route_hints (agent-router child
## 019eb47eb567), which routes open hints → cyan proposals → committed traces.
const _APPLY_TODO := "use minerva_pcb_apply_route_hints to route + apply (async worker path)"


func _init() -> void:
	name = &"pcb_route_hint"
	display_name = "Route Hint"
	schema_version = 1
	owning_plugin = &"pcb"
	primitives_optional = true
	# Workflow-class (pcb-ui-native-cluster §4, WC-2): route hints are working
	# data for the routing loop, not review commentary. The review workbench
	# excludes them; WorkflowAnnotationList shows them; MCP reads are unchanged.
	workflow_class = true
	default_payload = {
		"hint_type": "waypoint",
		"detail_level": "guided",
		"layer": "F.Cu",
		"width_mm": 0.25,
		"source_pins": [],
		"dest_pins": [],
		"text": "",
		"waypoints": [],
	}


## A route hint anchors at a board point (freehand) OR at its source pad (the
## natural authored form). Returning a non-empty list is what makes
## AnnotationV2Schema.validate_with_registry pass the kind↔anchor compat check.
func accepted_anchor_types() -> Array:
	return [_ANCHOR_TYPE_BOARD_POINT, _ANCHOR_TYPE_PAD]


# ── Authoring (waypoint-click) ────────────────────────────────────────────────

## Fresh instance per activation (AnnotationText pattern) so the toolbar can
## deactivate-then-reactivate without state leak.
func author_ui() -> Object:
	return WaypointRouteHintAuthorTool.new()


## Waypoint-click authoring: each left click appends a waypoint (previewed via
## draw_preview); a double-click (a left click landing on the last waypoint)
## commits; Escape (via the mods channel — the only key AnnotationOverlay
## forwards to author tools) or right-click cancels, matching the arrow tool's
## cancel gestures. On commit the tool emits annotation_ready with a polyline
## route hint anchored at the FIRST waypoint — envelope construction is
## delegated to the host's build_route_hint_envelope so the toolbar path and
## the MCP/test path share one builder.
class WaypointRouteHintAuthorTool:
	extends AnnotationAuthorTool

	## Same-position epsilon (board mm) for double-click commit detection.
	const _COMMIT_EPSILON := 0.001

	var _host: AnnotationHost = null
	var _waypoints: Array = []       # Array[Vector2] in document (board-mm) space
	var _preview: Vector2 = Vector2.ZERO
	var _has_preview: bool = false

	func on_activate(host: AnnotationHost) -> void:
		_host = host
		_reset()

	func on_deactivate() -> void:
		# Clean reset on tool-switch WITHOUT emitting cancelled (arrow convention).
		_reset()
		_host = null

	func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
		# Escape (via mods channel) → cancel an in-progress path.
		if mods == KEY_ESCAPE:
			if not _waypoints.is_empty():
				_reset()
				cancelled.emit()
				return true
			return false

		# Right-click → cancel (consistency with the arrow author tool).
		if button == MOUSE_BUTTON_RIGHT:
			if not _waypoints.is_empty():
				_reset()
				cancelled.emit()
				return true
			return false

		if button != MOUSE_BUTTON_LEFT:
			return false
		if _host == null:
			return false

		var doc_pos: Vector2 = _host.transform_screen_to_doc(pos)

		# Double-click semantics: a left click landing on the last waypoint commits.
		if not _waypoints.is_empty():
			var last: Vector2 = _waypoints[_waypoints.size() - 1]
			if last.distance_to(doc_pos) <= _COMMIT_EPSILON:
				return _try_commit()

		_waypoints.append(doc_pos)
		_preview = doc_pos
		_has_preview = true
		return true

	func on_pointer_move(pos: Vector2) -> void:
		if _host == null or _waypoints.is_empty():
			return
		_preview = _host.transform_screen_to_doc(pos)
		_has_preview = true

	func draw_preview(ctx: AnnotationRenderContext) -> void:
		if ctx == null or _waypoints.is_empty():
			return
		var base := AnnotationRenderContext.author_color("human")
		var faded := Color(base.r, base.g, base.b, 0.5)
		for i in range(1, _waypoints.size()):
			ctx.draw_line(_waypoints[i - 1], _waypoints[i], faded, 1.0)
		if _has_preview:
			ctx.draw_line(_waypoints[_waypoints.size() - 1], _preview, faded, 1.0)

	func _try_commit() -> bool:
		if _waypoints.is_empty():
			return false
		if _host == null or not _host.has_method("build_route_hint_envelope"):
			push_warning("[pcb_route_hint] author tool active without a pcb host; ignoring commit")
			_reset()
			return false
		var first: Vector2 = _waypoints[0]
		var wp_arrays: Array = []
		for wp in _waypoints:
			wp_arrays.append([wp.x, wp.y])
		var envelope: Dictionary = _host.call(
			"build_route_hint_envelope", first.x, first.y, "", "F.Cu", "waypoint", wp_arrays, "human")
		_reset()
		annotation_ready.emit(envelope)
		return true

	func _reset() -> void:
		_waypoints = []
		_preview = Vector2.ZERO
		_has_preview = false

	## Test/introspection accessor — current in-progress waypoint count.
	func waypoint_count() -> int:
		return _waypoints.size()


## Single-trace authoring: full click-flow state machine (pcb-ui-native-cluster
## §5, WC-3 round; native parity PCBCanvas.gd@pre-cutover-2026-07-07 ~L2406
## click flow / ~L1378 live preview — re-implemented, not copied). Distinct
## from WaypointRouteHintAuthorTool above: that tool stays wired to
## kind.author_ui() (the dock's generic per-kind "Route Hint" button keeps
## waypoint-only authoring). This tool is instantiated directly by PCBPanel's
## dedicated route-flow toolbar cluster (see PCBPanel.gd
## _build_route_flow_cluster / _new_route_tool) and pushed onto the shared
## platform AnnotationOverlay — kind.author_ui() is intentionally NOT extended
## to return this tool, since a kind's author_ui() contract is one-tool-per-kind
## and the generic dock button must keep its existing (pre-WC-3) behavior.
##
## State machine (verbatim, contract §5):
##   IDLE --click pad--> DRAWING(source=pad)     # pad_at snap, radius 5mm
##   IDLE --click empty--> DRAWING(source=point)
##   DRAWING --click empty--> append waypoint
##   DRAWING --click pad--> commit(dest=pad)     # pad == source → CANCEL (self-ref)
##   DRAWING --double-click empty--> commit(dest=point)
##   DRAWING --right-click / Escape--> cancel
##
## Double-click gotcha (verified, contract §"known gotchas"): AnnotationOverlay
## ._gui_input does NOT forward InputEventMouseButton.double_click to tools —
## it decomposes every press into on_pointer_down(pos, button_index, mods),
## dropping the flag entirely (AnnotationOverlay.gd:187-201). A REAL physical
## double-click still works here because its two press events land at
## (near-)identical screen pixels: the first press's on_pointer_down "click
## empty" branch appends a waypoint at that doc-space point; the second
## press's on_pointer_down finds that new point within _COMMIT_EPSILON of
## itself and commits — the exact "click lands on the last placed point"
## technique WaypointRouteHintAuthorTool already uses above. A programmatic
## fallback (KEY_ENTER, forwarded via the same pseudo-pointer convention as
## Escape/Delete) is ALSO wired for callers that can't reproduce same-pixel
## double-click timing (tests, agents): commits dest=point at the last
## waypoint, or at the live preview position if no waypoint has been placed
## yet.
class SingleTraceAuthorTool:
	extends AnnotationAuthorTool

	## Same-position epsilon (board mm) for double-click / Enter commit
	## detection — matches WaypointRouteHintAuthorTool's constant exactly.
	const _COMMIT_EPSILON := 0.001
	# 2mm, not the native 5mm: on fine-pitch boards a 5mm commit radius
	# grabbed the destination pad while the user was still placing bends
	# nearby (HITL-2 feedback). 2mm ~= pad + comfortable margin.
	const _PAD_RADIUS_MM := 2.0
	const _DASH_LEN_MM := 2.0
	const _GAP_LEN_MM := 1.5
	const _DEFAULT_WIDTH_MM := 0.25

	var _host: AnnotationHost = null
	var _state: String = "idle"    # "idle" | "drawing"
	var _source: Dictionary = {}   # {type:"pad", component, pin, pos} | {type:"point", pos}
	var _waypoints: Array = []     # Array[Vector2] — interior waypoints placed so far
	var _preview: Vector2 = Vector2.ZERO
	var _has_preview: bool = false

	func on_activate(host: AnnotationHost) -> void:
		_host = host
		_reset()

	func on_deactivate() -> void:
		_reset()
		_host = null

	func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
		if mods == KEY_ESCAPE:
			return _cancel_if_drawing()
		if mods == KEY_ENTER:
			return _commit_via_enter()
		if button == MOUSE_BUTTON_RIGHT:
			return _cancel_if_drawing()
		if button != MOUSE_BUTTON_LEFT:
			return false
		if _host == null:
			return false

		var doc_pos: Vector2 = _host.transform_screen_to_doc(pos)
		var pad := _pad_at(doc_pos)

		if _state == "idle":
			if not pad.is_empty():
				_source = {"type": "pad", "component": str(pad.get("component", "")),
					"pin": str(pad.get("pin", "")), "pos": pad.get("position", doc_pos)}
			else:
				_source = {"type": "point", "pos": doc_pos}
			_state = "drawing"
			_waypoints = []
			_has_preview = false
			return true

		# DRAWING.
		if not pad.is_empty():
			if str(_source.get("type", "")) == "pad" \
					and str(_source.get("component", "")) == str(pad.get("component", "")) \
					and str(_source.get("pin", "")) == str(pad.get("pin", "")):
				# Self-reference: the same pad as the source → CANCEL (contract §5).
				_reset()
				cancelled.emit()
				return true
			return _commit(pad, Vector2.ZERO, false)   # commit(dest=pad)

		# Empty click — double-click-by-position detection (see class doc).
		var last: Vector2 = _waypoints[_waypoints.size() - 1] if not _waypoints.is_empty() \
			else (_source.get("pos", Vector2.ZERO) as Vector2)
		if last.distance_to(doc_pos) <= _COMMIT_EPSILON:
			return _commit({}, doc_pos, true)   # commit(dest=point)

		_waypoints.append(doc_pos)
		_preview = doc_pos
		_has_preview = true
		return true

	func on_pointer_move(pos: Vector2) -> void:
		if _host == null or _state != "drawing":
			return
		_preview = _host.transform_screen_to_doc(pos)
		_has_preview = true

	func draw_preview(ctx: AnnotationRenderContext) -> void:
		if ctx == null or _state != "drawing":
			return
		var pts: Array = [_source.get("pos", Vector2.ZERO)]
		for wp in _waypoints:
			pts.append(wp)
		if _has_preview:
			pts.append(_preview)
		if pts.size() < 2:
			return
		var color := AnnotationRenderContext.author_color("human")
		for i in range(1, pts.size()):
			_draw_dashed_segment(ctx, pts[i - 1], pts[i], color)

		var font: Font = ThemeDB.fallback_font
		if font != null:
			var label := "Single Trace"
			if str(_source.get("type", "")) == "pad":
				label = "Single Trace  from %s.%s" % [str(_source.get("component", "")), str(_source.get("pin", ""))]
			ctx.draw_string(font, (pts[0] as Vector2) + Vector2(6.0, -6.0), label, color, 12)

	# ── internal ──────────────────────────────────────────────────────────────

	func _cancel_if_drawing() -> bool:
		if _state == "drawing":
			_reset()
			cancelled.emit()
			return true
		return false

	## Enter fallback commit (see class doc: the double_click flag gotcha).
	func _commit_via_enter() -> bool:
		if _state != "drawing":
			return false
		if not _waypoints.is_empty():
			return _commit({}, _waypoints[_waypoints.size() - 1], true)
		if _has_preview:
			return _commit({}, _preview, true)
		return false

	## dest_pad: {} unless committing to a pad. dest_point/as_point: the
	## doc-space commit point when committing to a bare point.
	func _commit(dest_pad: Dictionary, dest_point: Vector2, as_point: bool) -> bool:
		if _host == null or not _host.has_method("build_route_hint_envelope"):
			push_warning("[pcb_route_hint] single-trace tool active without a pcb host; ignoring commit")
			_reset()
			return false

		# Interior waypoints only (contract §5) — when the commit point equals
		# the last appended waypoint (the double-click / Enter path both land
		# here), that entry IS the destination, not an interior point.
		var interior: Array = _waypoints.duplicate()
		if as_point and not interior.is_empty() \
				and (interior[interior.size() - 1] as Vector2).distance_to(dest_point) <= _COMMIT_EPSILON:
			interior.remove_at(interior.size() - 1)

		var source_pins: Array = []
		var dest_pins: Array = []
		var anchor_pos: Vector2 = _source.get("pos", Vector2.ZERO)
		var anchor_is_pad := str(_source.get("type", "")) == "pad"
		if anchor_is_pad:
			source_pins.append("%s.%s" % [str(_source.get("component", "")), str(_source.get("pin", ""))])
		if not as_point and not dest_pad.is_empty():
			dest_pins.append("%s.%s" % [str(dest_pad.get("component", "")), str(dest_pad.get("pin", ""))])

		var wp_arrays: Array = []
		for wp in interior:
			wp_arrays.append([(wp as Vector2).x, (wp as Vector2).y])

		var layer := "F.Cu"
		if _host.has_method("get_current_layer"):
			layer = str(_host.call("get_current_layer"))

		var envelope: Dictionary = _host.call(
			"build_route_hint_envelope", anchor_pos.x, anchor_pos.y, "", layer, "single_trace",
			wp_arrays, "human", "", _DEFAULT_WIDTH_MM, source_pins, dest_pins)

		# dest_point: a commit-time-resolved rendering/hit-test cache (NOT a
		# semantic waypoint — kind_payload.waypoints stays interior-only per
		# contract §5). Needed because AnnotationKind.hit_test()/bounds() have
		# no host parameter to resolve a dest_pins pad reference live — see
		# pcb_route_hint_kind.gd _waypoint_points()'s class doc for the full
		# rationale and the accepted staleness tradeoff.
		var dest_pos: Vector2 = dest_point
		if not as_point and not dest_pad.is_empty():
			dest_pos = dest_pad.get("position", dest_point)
		var kp: Dictionary = envelope.get("kind_payload", {})
		kp["dest_point"] = [dest_pos.x, dest_pos.y]
		envelope["kind_payload"] = kp

		# Semantic pad anchor when the SOURCE is a pad (contract §5): re-anchor
		# at the pad (same shape PcbAnnotationHost._resolve_pad expects) so the
		# marker tracks the live component through moves, instead of the bare
		# board.point default build_route_hint_envelope always produces.
		if anchor_is_pad:
			envelope["anchor"] = {
				"plugin": "pcb", "type": "pad",
				"id": {"component": str(_source.get("component", "")), "pin": str(_source.get("pin", ""))},
				"snapshot": {"position": [anchor_pos.x, anchor_pos.y]},
			}

		_reset()
		annotation_ready.emit(envelope)
		return true

	func _pad_at(doc_pos: Vector2) -> Dictionary:
		if _host == null or not _host.has_method("pad_at"):
			return {}
		return _host.pad_at(doc_pos, _PAD_RADIUS_MM)

	func _draw_dashed_segment(ctx: AnnotationRenderContext, a: Vector2, b: Vector2, color: Color) -> void:
		var seg := b - a
		var seg_len := seg.length()
		if seg_len < 0.0001:
			return
		var dir := seg / seg_len
		var step := _DASH_LEN_MM + _GAP_LEN_MM
		var dist := 0.0
		while dist < seg_len:
			var dash_end := minf(dist + _DASH_LEN_MM, seg_len)
			ctx.draw_line(a + dir * dist, a + dir * dash_end, color, 1.5)
			dist += step

	func _reset() -> void:
		_state = "idle"
		_source = {}
		_waypoints = []
		_preview = Vector2.ZERO
		_has_preview = false

	# ── Test/introspection accessors (state assertions, contract E2E-3/4) ──────

	func current_state() -> String:
		return _state

	func source_info() -> Dictionary:
		return _source.duplicate()

	func waypoint_count() -> int:
		return _waypoints.size()


## Bend-handle editing tool (C4 deliverable 3, docket 019f6c464ff0):
## instantiated directly by PCBPanel's route-flow toolbar cluster (see
## PCBPanel.gd's "Edit hint" button / _new_route_flow_tool), same idiom as
## SingleTraceAuthorTool above — NOT wired to kind.author_ui() (this is a
## MANIPULATION tool over an EXISTING hint, not an authoring tool).
##
## Selecting a pcb_route_hint (click on its rendered polyline/marker) shows
## drag handles on its interior bend points (bend_points(), outer class,
## below):
##   - DRAG a handle        → moves that bend. Live position is PREVIEW ONLY
##                             (draw_preview) during the drag — commits ONE
##                             annotation_modified on release. Deliberately
##                             NOT AnnotationTransformTool's per-pointer-move
##                             emission convention: that tool has no history
##                             to worry about, but here a per-frame commit
##                             would push a revision every mouse-move frame
##                             and blow the bounded stack for nothing.
##   - RIGHT-CLICK a handle → deletes that bend. ONE revision.
##   - CLICK a segment      → inserts a bend at the clicked point (snapped
##                             onto the segment). ONE revision.
##   - Escape                → cancels a drag in progress (nothing was
##                             committed mid-drag, so this is a silent
##                             reset, not a revert-emit) or clears selection
##                             when idle.
##   - Tool-switch (on_deactivate) → same silent reset; no partial commits
##                             ever reach the host.
##
## SCOPE: bend-level only. The anchor (source pad/point) and the destination
## are never touched by this tool.
##
## Selection is HOST state (mirrors AnnotationSelectTool) so it persists
## across a tool-switch away and back. Only pcb_route_hint annotations are
## selectable while this tool is active — a deliberate narrowing (this tool
## exists to edit hints, not as a general-purpose selector); clicking a
## non-hint annotation or empty space just clears the host selection.
class BendHandleEditTool:
	extends AnnotationAuthorTool

	const _HANDLE_HIT_PX := 10.0
	const _SEGMENT_HIT_PX := 8.0
	const _SELECT_HIT_PX := 8.0
	const _HANDLE_SIZE_PX := 7.0
	const _HANDLE_COLOR := Color(0.2, 0.9, 1.0, 0.95)
	const _DRAG_PREVIEW_COLOR := Color(1.0, 0.85, 0.2, 0.95)

	var _host: AnnotationHost = null
	var _dragging := false
	var _drag_hint_id: String = ""
	var _drag_bend_index := -1
	var _drag_start_bends: Array = []   # Array[Vector2] snapshot at drag start
	var _drag_live_point: Vector2 = Vector2.ZERO

	func on_activate(host: AnnotationHost) -> void:
		_host = host
		_reset_drag()

	func on_deactivate() -> void:
		# Silent reset — a drag in progress was never committed, so there is
		# nothing to revert on the host. Selection persists by design.
		_reset_drag()
		_host = null

	func _reset_drag() -> void:
		_dragging = false
		_drag_hint_id = ""
		_drag_bend_index = -1
		_drag_start_bends = []
		_drag_live_point = Vector2.ZERO

	func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
		if _host == null:
			return false

		if mods == KEY_ESCAPE:
			if _dragging:
				_reset_drag()
				return true
			_host.set_selected_annotation_id("")
			return true

		var doc_pos := _host.transform_screen_to_doc(pos)
		var zoom := _zoom()
		var handle_r := _HANDLE_HIT_PX / zoom
		var seg_r := _SEGMENT_HIT_PX / zoom

		if button == MOUSE_BUTTON_RIGHT:
			# Right-click a handle of the CURRENTLY SELECTED hint deletes that
			# bend. No selection / not a route hint / no handle hit → no-op
			# (let the host's own right-click handling, if any, proceed).
			var sel := _host.get_selected_annotation_id()
			if sel.is_empty():
				return false
			var ann := _find(sel)
			var kind := _kind()
			if ann.is_empty() or kind == null or str(ann.get("kind", "")) != "pcb_route_hint":
				return false
			var bends: Array = kind.bend_points(ann)
			var idx := _hit_bend(bends, doc_pos, handle_r)
			if idx < 0:
				return false
			bends.remove_at(idx)
			annotation_modified.emit(sel, kind.with_bend_points(ann, bends))
			return true

		if button != MOUSE_BUTTON_LEFT:
			return false

		var sel := _host.get_selected_annotation_id()
		if not sel.is_empty():
			var ann := _find(sel)
			var kind := _kind()
			if not ann.is_empty() and kind != null and str(ann.get("kind", "")) == "pcb_route_hint":
				var bends: Array = kind.bend_points(ann)
				var idx := _hit_bend(bends, doc_pos, handle_r)
				if idx >= 0:
					# Begin a drag — commits on release (on_pointer_up), never here.
					_dragging = true
					_drag_hint_id = sel
					_drag_bend_index = idx
					_drag_start_bends = bends.duplicate()
					_drag_live_point = bends[idx]
					return true
				var insertion: Dictionary = kind.nearest_bend_insertion(ann, doc_pos, seg_r)
				if not insertion.is_empty():
					var new_bends: Array = bends.duplicate()
					new_bends.insert(int(insertion.get("insert_at", 0)), insertion.get("point", doc_pos))
					annotation_modified.emit(sel, kind.with_bend_points(ann, new_bends))
					return true

		# No handle/segment hit on the current selection — fall back to
		# route-hint-only selection (see class doc).
		return _select_route_hint_at(doc_pos)

	func on_pointer_move(pos: Vector2) -> void:
		if not _dragging or _host == null:
			return
		_drag_live_point = _host.transform_screen_to_doc(pos)

	func on_pointer_up(_pos: Vector2, button: int, _mods: int) -> bool:
		if not _dragging:
			return false
		if button == MOUSE_BUTTON_LEFT:
			var kind := _kind()
			var ann := _find(_drag_hint_id)
			if kind != null and not ann.is_empty() \
					and _drag_bend_index >= 0 and _drag_bend_index < _drag_start_bends.size():
				var new_bends: Array = _drag_start_bends.duplicate()
				new_bends[_drag_bend_index] = _drag_live_point
				annotation_modified.emit(_drag_hint_id, kind.with_bend_points(ann, new_bends))
			_reset_drag()
			return true
		return false

	func draw_preview(ctx: AnnotationRenderContext) -> void:
		if _host == null:
			return
		var sel := _host.get_selected_annotation_id()
		if sel.is_empty():
			return
		var ann := _find(sel)
		var kind := _kind()
		if ann.is_empty() or kind == null or str(ann.get("kind", "")) != "pcb_route_hint":
			return
		var bends: Array = kind.bend_points(ann)
		var half := (_HANDLE_SIZE_PX / _zoom()) * 0.5
		for i in range(bends.size()):
			var p: Vector2 = bends[i]
			var color := _HANDLE_COLOR
			if _dragging and i == _drag_bend_index:
				p = _drag_live_point
				color = _DRAG_PREVIEW_COLOR
			ctx.draw_rect(Rect2(p - Vector2(half, half), Vector2(half * 2.0, half * 2.0)), color, true, 1.0)

	# ── internal ──────────────────────────────────────────────────────────────

	func _zoom() -> float:
		if _host != null and _host.has_method("get_annotation_zoom"):
			return maxf(float(_host.get_annotation_zoom()), 0.01)
		return 1.0

	func _select_route_hint_at(doc_pos: Vector2) -> bool:
		var registry := _host.get_registry()
		var annotations: Array = _host.get_annotations()
		var hit_threshold := _SELECT_HIT_PX / _zoom()
		for i in range(annotations.size() - 1, -1, -1):
			var ann: Dictionary = annotations[i]
			if str(ann.get("kind", "")) != "pcb_route_hint":
				continue
			if not _host.is_annotation_visible(ann):
				continue
			var kind: AnnotationKind = registry.get_annotation_kind(StringName("pcb_route_hint")) if registry != null else null
			if kind == null:
				continue
			if kind.hit_test(ann, doc_pos, hit_threshold):
				_host.set_selected_annotation_id(str(ann.get("id", "")))
				return true
		_host.set_selected_annotation_id("")
		return true

	func _hit_bend(bends: Array, doc_pos: Vector2, radius: float) -> int:
		for i in range(bends.size()):
			if (bends[i] as Vector2).distance_to(doc_pos) <= radius:
				return i
		return -1

	func _find(id: String) -> Dictionary:
		if _host == null:
			return {}
		for ann in _host.get_annotations():
			if ann is Dictionary and str((ann as Dictionary).get("id", "")) == id:
				return ann as Dictionary
		return {}

	func _kind() -> AnnotationKind:
		if _host == null:
			return null
		var registry := _host.get_registry()
		if registry == null:
			return null
		return registry.get_annotation_kind(StringName("pcb_route_hint"))


# ── Bend-handle geometry (C4 deliverable 3, docket 019f6c464ff0) ──────────────
#
# "Bend points" are the INTERIOR waypoints only — never the anchor/source and
# never the destination (SCOPE: bend-level editing; endpoint re-tie to a
# different pad is explicitly OUT of this round, follow-up filed). These
# normalize over the two coexisting kind_payload.waypoints storage
# conventions documented on _waypoint_points()'s class doc above (legacy
# full-path vs interior-only + dest_point), so BendHandleEditTool never has
# to know which convention a given hint uses.
#
# Called externally via the registry (kind.bend_points(ann), same pattern as
# kind.hit_test/kind.bounds) — not static, so BendHandleEditTool (a nested
# class with no implicit access to this outer script's members) reaches them
# through _host.get_registry().get_annotation_kind(&"pcb_route_hint").

## Interior bend points, in document (board-mm) space.
func bend_points(annotation: Dictionary) -> Array:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var raw: Variant = payload.get("waypoints", [])
	var wp: Array = (raw as Array) if raw is Array else []
	if payload.has("dest_point"):
		# Interior-only convention — every stored waypoint IS a bend.
		var out: Array = []
		for w in wp:
			out.append(_to_vec2(w))
		return out
	# Legacy full-path convention — first/last are anchor/destination.
	if wp.size() < 3:
		return []
	var out2: Array = []
	for i in range(1, wp.size() - 1):
		out2.append(_to_vec2(wp[i]))
	return out2


## Replace the interior bend points, preserving whichever storage convention
## `annotation` already uses. Returns a NEW, fully-duplicated annotation
## Dictionary (never mutates the input) with kind_payload.waypoints rebuilt —
## the anchor/destination the original waypoints array carried (legacy
## convention) are preserved verbatim.
func with_bend_points(annotation: Dictionary, new_bends: Array) -> Dictionary:
	var new_ann := annotation.duplicate(true)
	var payload: Dictionary = (new_ann.get("kind_payload", {}) as Dictionary).duplicate(true)
	var bend_arrays: Array = []
	for b in new_bends:
		bend_arrays.append([(b as Vector2).x, (b as Vector2).y])
	if payload.has("dest_point"):
		payload["waypoints"] = bend_arrays
	else:
		var raw: Variant = payload.get("waypoints", [])
		var wp: Array = (raw as Array) if raw is Array else []
		if wp.size() < 2:
			# No recorded anchor/dest to preserve (degenerate/empty hint).
			payload["waypoints"] = bend_arrays
		else:
			var out: Array = [wp[0]]
			out.append_array(bend_arrays)
			out.append(wp[wp.size() - 1])
			payload["waypoints"] = out
	new_ann["kind_payload"] = payload
	return new_ann


## Nearest point ON the full rendered polyline (anchor→bends→dest) to
## doc_pos, plus which bend_points()-array insertion index a new bend there
## would occupy (0 = before the first existing bend; bend_points().size() =
## append after the last). Returns {} when doc_pos is farther than
## `threshold` from every segment, or when the hint has fewer than 2
## rendered points (nothing to insert into).
func nearest_bend_insertion(annotation: Dictionary, doc_pos: Vector2, threshold: float) -> Dictionary:
	var full := _waypoint_points(annotation)
	if full.size() < 2:
		return {}
	var best_dist := INF
	var best_point := Vector2.ZERO
	var best_seg := -1
	for i in range(full.size() - 1):
		var a: Vector2 = full[i]
		var b: Vector2 = full[i + 1]
		var proj := _project_on_segment(a, b, doc_pos)
		var d := proj.distance_to(doc_pos)
		if d < best_dist:
			best_dist = d
			best_point = proj
			best_seg = i
	if best_seg < 0 or best_dist > threshold:
		return {}
	# full[0] is the anchor (not a bend); full[k] for k in 1..size-2 are
	# bends (== bend_points()[k-1]); full[-1] is the destination. Segment i
	# spans full[i]..full[i+1], so inserting there means "insert_at = i" in
	# bend_points()'s array (0-based, since bend_points()[0] == full[1]).
	return {"point": best_point, "insert_at": best_seg}


static func _project_on_segment(a: Vector2, b: Vector2, p: Vector2) -> Vector2:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return a
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t


# ── Validation (beyond the envelope schema) ──────────────────────────────────

func validate(annotation: Dictionary) -> Array:
	var errors: Array = []
	var anchor: Variant = annotation.get("anchor", null)
	if not (anchor is Dictionary):
		errors.append({"field": "anchor", "message": "anchor dict is required"})
		return errors
	var a: Dictionary = anchor as Dictionary
	if str(a.get("plugin", "")) != "pcb":
		errors.append({"field": "anchor.plugin", "message": "anchor.plugin must be 'pcb'"})
	var atype := str(a.get("type", ""))
	if atype not in ["board.point", "pad"]:
		errors.append({"field": "anchor.type", "message": "anchor.type must be 'board.point' or 'pad'"})

	var payload: Dictionary = annotation.get("kind_payload", {})

	var hint_type := str(payload.get("hint_type", "waypoint"))
	if hint_type not in _VALID_HINT_TYPES:
		errors.append({"field": "kind_payload.hint_type", "message": "hint_type must be waypoint|single_trace|bus"})

	# detail_level is optional; validate only when present (old skeletons omit it).
	if payload.has("detail_level"):
		var detail := str(payload["detail_level"])
		if detail not in _VALID_DETAIL_LEVELS:
			errors.append({"field": "kind_payload.detail_level", "message": "detail_level must be sparse|guided|detailed"})

	if payload.has("width_mm"):
		var w: Variant = payload["width_mm"]
		if not (w is float or w is int):
			errors.append({"field": "kind_payload.width_mm", "message": "width_mm must be a number"})
		elif float(w) < 0.0:
			errors.append({"field": "kind_payload.width_mm", "message": "width_mm must be >= 0"})

	for key in ["source_pins", "dest_pins", "waypoints"]:
		if payload.has(key) and not (payload[key] is Array):
			errors.append({"field": "kind_payload.%s" % key, "message": "%s must be an Array" % key})

	# Self-referencing rejection: a hint from a pad to itself is meaningless.
	var src: Array = _string_array(payload.get("source_pins", []))
	var dst: Array = _string_array(payload.get("dest_pins", []))
	if src.size() == 1 and dst.size() == 1 and not src[0].is_empty() and src[0] == dst[0]:
		errors.append({"field": "kind_payload.dest_pins", "message": "source and destination pin must differ"})

	return errors


# ── Required rendering hooks ──────────────────────────────────────────────────

## Waypoint polyline with a layer-tinted, width/zoom-aware stroke + a diamond
## marker at the anchor + a text label. Coordinates are document-space (board mm);
## the substrate AnnotationOverlay applies the host transform before calling us.
func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	if ctx == null:
		return
	var pos := _anchor_position(annotation)
	var payload: Dictionary = annotation.get("kind_payload", {})
	var layer := str(payload.get("layer", "F.Cu"))
	# AI-authored proposals (route-correction loop, 019eb47eb567) render in the
	# substrate's author cyan so a proposed route reads as distinct from a
	# human-authored (layer-tinted) hint at a glance. Human hints keep the
	# layer-tinted stroke.
	# Layer carries COLOR for every author (owner req 2026-07-17: with all AI
	# output cyan you cannot tell F.Cu from B.Cu on a 16-proposal review, and
	# zero-via boards LOOK like collisions). Authorship carries LINE STYLE
	# instead: AI = dashed stroke + substrate-cyan anchor marker, human =
	# solid stroke + layer-tinted marker.
	var stroke_color := _layer_color(layer)
	var author: Variant = annotation.get("author", null)
	var is_ai: bool = author is Dictionary and str((author as Dictionary).get("kind", "human")) == "ai"

	# Stroke width: width_mm scaled by zoom (pixels-per-mm), floored to 1px so a
	# hair-thin hint stays visible when zoomed out.
	var width_mm := float(payload.get("width_mm", 0.0))
	var stroke_px := 1.0
	if width_mm > 0.0:
		stroke_px = maxf(1.0, width_mm * ctx.zoom)

	# Waypoint polyline (layer-tinted) if present; AI strokes are dashed.
	var pts := _waypoint_points(annotation)
	if pts.size() >= 2:
		if is_ai:
			_draw_dashed_polyline(ctx, pts, stroke_color, stroke_px)
		else:
			ctx.draw_polyline(pts, stroke_color, stroke_px)

	# Diamond marker at the anchor (AI keeps the substrate cyan so authorship
	# stays one-glance even though strokes are now layer-tinted).
	if is_ai:
		pass  # marker color set below
	var marker_color := AnnotationRenderContext.author_color("ai") if is_ai else stroke_color
	var d := maxf(_MARKER_RADIUS, _MARKER_MIN_PX / maxf(ctx.zoom, 0.001))
	var diamond := PackedVector2Array([
		pos + Vector2(0, -d), pos + Vector2(d, 0),
		pos + Vector2(0, d), pos + Vector2(-d, 0),
	])
	var cols := PackedColorArray([marker_color, marker_color, marker_color, marker_color])
	ctx.draw_polygon(diamond, cols)

	# Label: the enriched summary — gated by the view flag (canvas
	# show_hint_labels → host relay → this instance property).
	if not labels_visible:
		return
	var font: Font = ThemeDB.fallback_font
	if font != null:
		ctx.draw_string(font, pos + Vector2(d + 3.0, 4.0), summary(annotation), _LABEL_COLOR, _LABEL_FONT_SIZE)


## Path-based hit-test: distance to any polyline segment (not the AABB), plus the
## marker disc around the anchor. threshold is in document (board-mm) units.
func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var effective := threshold + _HIT_THRESHOLD_MM + float(payload.get("width_mm", 0.0)) * 0.5

	# Marker disc around the anchor.
	if _anchor_position(annotation).distance_to(point) <= effective + _MARKER_RADIUS:
		return true

	# Swept distance to the waypoint polyline.
	var pts := _waypoint_points(annotation)
	for i in range(pts.size() - 1):
		if _dist_point_to_segment(point, pts[i], pts[i + 1]) <= effective:
			return true
	return false


func bounds(annotation: Dictionary) -> Rect2:
	var pos := _anchor_position(annotation)
	var r := _MARKER_RADIUS
	var rect := Rect2(pos - Vector2(r, r), Vector2(r * 2.0, r * 2.0))
	for wp in _waypoint_points(annotation):
		rect = rect.expand(wp)
	return rect


func primary_anchor_point(annotation: Dictionary) -> Vector2:
	return _anchor_position(annotation)


## Enriched one-line summary: "route hint U1.15→J2.3, F.Cu, 0.25mm, 4 waypoints".
## Empty parts are omitted gracefully; trailing text (if any) is appended.
func summary(annotation: Dictionary) -> String:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var parts: Array = []

	var head := "route hint"
	var src: Array = _string_array(payload.get("source_pins", []))
	var dst: Array = _string_array(payload.get("dest_pins", []))
	if not src.is_empty() and not dst.is_empty():
		head = "route hint %s→%s" % [src[0], dst[0]]
	parts.append(head)

	var layer := str(payload.get("layer", ""))
	if not layer.is_empty():
		parts.append(layer)

	var width_mm := float(payload.get("width_mm", 0.0))
	if width_mm > 0.0:
		parts.append(_fmt_mm(width_mm))

	var wp_count := _waypoint_points(annotation).size()
	if wp_count > 0:
		parts.append("%d waypoint%s" % [wp_count, "s" if wp_count != 1 else ""])

	var s := ", ".join(parts)
	var text := str(payload.get("text", ""))
	if not text.is_empty():
		s = "%s: %s" % [s, text]
	return s


# ── Per-row actions (workbench / apply-tool) ──────────────────────────────────

## "reject" resolves the hint (open→resolved per AnnotationLifecycle); "apply" is
## a no-op stub the agent-router child (019eb47eb567) will wire to trace synthesis.
func actions(annotation: Dictionary) -> Array:
	var lifecycle := str(annotation.get("lifecycle", "open"))
	var result: Array = []
	# apply/reject only make sense on an open hint.
	if lifecycle == "open":
		result.append({"id": "apply", "label": "Apply", "requires_lifecycle": "open"})
		result.append({"id": "reject", "label": "Reject", "requires_lifecycle": "open"})
	return result


## Called dry_run then commit by AnnotationApplyToolRunner. Returns {ok, …}.
func run_action(action_id: String, annotation: Dictionary, phase: String, host: AnnotationHost) -> Dictionary:
	match action_id:
		"reject":
			if phase == "dry_run":
				return {"ok": true, "status": "will resolve (reject) this route hint"}
			# commit — transition the hint to resolved via the host lifecycle path.
			var ann_id := str(annotation.get("id", ""))
			if host != null and host.has_method("update_annotation_lifecycle") and not ann_id.is_empty():
				var res: Dictionary = host.update_annotation_lifecycle(ann_id, "resolved")
				if bool(res.get("ok", false)):
					return {"ok": true, "status": "route hint rejected (resolved)"}
				return {"ok": false, "error": str(res.get("error", "lifecycle transition failed"))}
			return {"ok": false, "error": "host cannot transition lifecycle"}
		"apply":
			# TODO(019eb47eb567): agent-router child wires this to real trace synthesis.
			return {"ok": true, "status": _APPLY_TODO}
	return {"ok": false, "error": "unknown action '%s'" % action_id}


# ── Helpers ───────────────────────────────────────────────────────────────────

## Read the anchor's board-space point. Prefers anchor.id {x,y} (board.point);
## falls back to anchor.snapshot.position [x,y] (pad anchors carry {component,pin}
## in id, so the snapshot position is the authoritative board-mm point for them).
static func _anchor_position(annotation: Dictionary) -> Vector2:
	var anchor: Variant = annotation.get("anchor", null)
	if anchor is Dictionary:
		var id: Variant = (anchor as Dictionary).get("id", null)
		if id is Dictionary and (id as Dictionary).has("x") and (id as Dictionary).has("y"):
			return Vector2(float((id as Dictionary)["x"]), float((id as Dictionary)["y"]))
		var snap: Variant = (anchor as Dictionary).get("snapshot", null)
		if snap is Dictionary:
			return _to_vec2((snap as Dictionary).get("position", [0, 0]))
	return Vector2.ZERO


## The polyline points for render/hit-test/bounds. Two storage conventions
## coexist (discriminated by presence of kind_payload.dest_point, WC-3):
##
##   * Legacy full-path (hint_type "waypoint" AND AI-authored "single_trace"
##     proposals from MCPPcbPanelTools._write_back_proposals): `waypoints`
##     already carries EVERY point including source and dest
##     (WaypointRouteHintAuthorTool / the router's routed polyline both build
##     it that way) — used as-is.
##   * Interior-only (human-authored "single_trace" hints, contract §5 —
##     kind_payload.waypoints holds INTERIOR points only): reconstructed here
##     as anchor → interior waypoints → dest_point. dest_point is a
##     commit-time-resolved cache (not a semantic ref) purely for rendering/
##     hit-testing — AnnotationKind.hit_test()/bounds() have no host
##     parameter to re-resolve a dest_pins pad reference live, unlike the
##     anchor (which the base resolve_anchor path DOES track live). Accepted
##     limitation: if the dest pad moves after authoring, the drawn line stays
##     at its commit-time position until the hint is repaired/re-authored —
##     same staleness class as any other snapshot fallback in this file.
func _waypoint_points(annotation: Dictionary) -> PackedVector2Array:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var raw: Variant = payload.get("waypoints", [])
	var interior: Array = (raw as Array) if raw is Array else []
	var out := PackedVector2Array()

	if payload.has("dest_point"):
		out.append(_anchor_position(annotation))
		for wp in interior:
			out.append(_to_vec2(wp))
		out.append(_to_vec2(payload["dest_point"]))
		return out

	# No dest_point cache (e.g. MCP-authored before the host backfill, or a
	# dest-less waypoint hint): still start the polyline at the anchor so the
	# source pad connects to the first bend (HITL-caught: the first and last
	# segments of agent-authored hints never rendered).
	out.append(_anchor_position(annotation))
	for wp in interior:
		out.append(_to_vec2(wp))
	return out


## Dashed polyline in document space (AI-authored strokes). Dash geometry in
## board mm so it scales with zoom like the preview (2.0/1.5 per the author
## tools' _DASH_LEN_MM/_GAP_LEN_MM convention).
func _draw_dashed_polyline(ctx: AnnotationRenderContext, pts: PackedVector2Array, color: Color, width_px: float) -> void:
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var seg_len := a.distance_to(b)
		if seg_len <= 0.0001:
			continue
		var dir := (b - a) / seg_len
		var dist := 0.0
		while dist < seg_len:
			var dash_end := minf(dist + 2.0, seg_len)
			ctx.draw_line(a + dir * dist, a + dir * dash_end, color, width_px)
			dist = dash_end + 1.5


## Focus points for the overlay's selection markers (duck-typed hook): DRC
## violation sites carried on a flagged proposal, so selecting a "⚠ N" row
## rings each collision on the canvas (owner HITL 2026-07-17: "I can't tell
## which item the comment refers to").
func focus_points(annotation: Dictionary) -> Array:
	var out: Array = []
	var kp: Variant = annotation.get("kind_payload", {})
	if not (kp is Dictionary):
		return out
	var drc: Variant = (kp as Dictionary).get("drc", null)
	if not (drc is Dictionary):
		return out
	var violations: Variant = (drc as Dictionary).get("violations", [])
	if not (violations is Array):
		return out
	for v in violations:
		if v is Dictionary and (v as Dictionary).get("at", null) is Array:
			var at: Array = (v as Dictionary)["at"]
			if at.size() >= 2:
				out.append(Vector2(float(at[0]), float(at[1])))
	return out


static func _layer_color(layer: String) -> Color:
	match layer:
		"F.Cu":
			return _COLOR_F_CU
		"B.Cu":
			return _COLOR_B_CU
		_:
			return _COLOR_OTHER


## Format a mm width with no trailing zeros (0.25 → "0.25mm", 0.3 → "0.3mm").
## GDScript's format has no %g, so trim manually.
static func _fmt_mm(w: float) -> String:
	var s := "%.4f" % w
	s = s.rstrip("0").rstrip(".")
	return "%smm" % s


static func _string_array(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for v in (raw as Array):
			out.append(str(v))
	return out


static func _to_vec2(raw: Variant) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	return Vector2.ZERO


static func _dist_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)
