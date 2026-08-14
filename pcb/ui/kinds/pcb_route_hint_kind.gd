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

## Self-reference so NESTED classes below (ViaInsertTool, BendHandleEditTool,
## …) can reach this outer class's STATIC funcs. Off-tree rule forbids
## class_name here, and GDScript nested classes do NOT get implicit unqualified
## access to their outer class's members (verified empirically — an unqualified
## call from inside a nested class fails to parse with "Function not found in
## base self") — a self-preload constant is the standing workaround, same
## family of trick as every sibling file's PCBPanel.gd-style cross-file
## preload() consts.
const _Self := preload("pcb_route_hint_kind.gd")
const _PcbLayerStack := preload("../model/pcb_layer_stack.gd")

## Anchor-marker HIT-TEST slack, document-space (board mm). Kept for
## hit_test()'s zoom-less corridor sweep only — DRAWN marker size is
## _marker_geometry's job since HITL-6 (below).
const _MARKER_RADIUS: float = 1.25

## Endpoint-diamond sizing curve (HITL-6, docket 019fdf2b5918 — owner: "a bit
## too big… non-linear scale by zoom. At zoom out slightly larger than at
## zoom in. At high zoom, they should disappear — they block seeing if
## there's a bend at connection", which is exactly what HITL-6's 0.54mm
## GND jog hid). Base is CONSTANT SCREEN PX (so doc-space presence already
## grows as you zoom out), with a small extra boost at low zoom and a fade
## to NOTHING across the high-zoom band where pad geometry is legible ink of
## its own. The pre-HITL-6 maxf(1.25mm, 6px/zoom) did the OPPOSITE at the
## top end: the mm floor made markers ever larger on screen as you zoomed in.
const _MARKER_BASE_PX: float = 4.0
const _MARKER_BOOST_ZOOM: float = 4.0   # below this px/mm, up to +50% larger
const _MARKER_BOOST_FRAC: float = 0.5
const _MARKER_FADE_START_ZOOM: float = 8.0
const _MARKER_FADE_END_ZOOM: float = 16.0


## The curve, one place for render() AND _visible_ink_hit (the F1 contract:
## hit-test ink == drawn ink, so a faded-out marker also stops claiming
## clicks). Returns Vector2(doc_radius_mm, alpha); alpha 0.0 ⇒ the marker is
## not drawn at all at this zoom.
static func _marker_geometry(zoom: float) -> Vector2:
	var z := maxf(zoom, 0.001)
	if z >= _MARKER_FADE_END_ZOOM:
		return Vector2(0.0, 0.0)
	var px := _MARKER_BASE_PX \
		* (1.0 + _MARKER_BOOST_FRAC * clampf(1.0 - z / _MARKER_BOOST_ZOOM, 0.0, 1.0))
	var alpha := 1.0
	if z > _MARKER_FADE_START_ZOOM:
		alpha = clampf(1.0 - (z - _MARKER_FADE_START_ZOOM) \
			/ (_MARKER_FADE_END_ZOOM - _MARKER_FADE_START_ZOOM), 0.0, 1.0)
	return Vector2(px / z, alpha)

# (RETIRED, HITL-6b — docket 019fdf553f: on-canvas hint labels are gone
# entirely, owner ruling: "don't show them at all… use the select/asking
# paradigm". They rendered far from their geometry, overlapped, and were too
# long to read as belonging to anything. The knowledge lives in MCP — the
# annotation's summary/note/ref via annotations_list, workspace records, and
# minerva_pcb_get_selection. The labels_visible var, the canvas
# show_hint_labels toggle, and the host relay died with the ink.)

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

## Inner-copper hint strokes (epoch GA-1): per-layer distinct, CYCLED like the
## canvas' _INNER_TRACE_PALETTE, but in THIS surface's family — bright,
## semi-transparent proposal strokes — rather than the committed-trace palette
## (the magenta/green ruling deliberately separates proposal color from
## committed color; inner layers keep that separation). Before GA-1 every
## inner layer fell into the gray "other" bucket, so an In1.Cu proposal was
## indistinguishable from an unspecified-layer one.
const _INNER_HINT_PALETTE: Array[Color] = [
	Color(1.0, 0.75, 0.30, 0.95),   # amber-orange   — In1.Cu
	Color(0.35, 0.80, 1.0, 0.95),   # sky            — In2.Cu
	Color(1.0, 0.40, 0.45, 0.95),   # coral          — In3.Cu
	Color(0.70, 0.60, 1.0, 0.95),   # lavender       — In4.Cu
	Color(0.55, 0.95, 0.75, 0.95),  # mint           — In5.Cu
	Color(0.95, 0.90, 0.40, 0.95),  # yellow         — In6.Cu (then cycles)
]

## Via marker (U2, DCR 019f7095c395 Stage-1): amber ring, distinct from both
## layer colors and the AI cyan/human diamond anchor markers, so a
## layer-transition point on a proposal reads as an explicit via, not a
## silently-flattened joint.
const _COLOR_VIA := Color(1.0, 0.85, 0.2, 0.95)
const _VIA_MARKER_RADIUS_MM: float = 0.5
const _VIA_MARKER_MIN_PX: float = 4.0

## Superseded cue (Codex 1047 fix round, verdict 1): neutral gray slash drawn
## across each endpoint marker of a hint whose waypoints were superseded by a
## task-level routing constraint (station 12 marker). Gray on purpose — it must
## not read as a layer tint (magenta/green), AI authorship (cyan), a via
## (amber), or selection (yellow); it reads as "struck out". Since HITL-6b
## (labels retired) the slash is the ONLY superseded cue on canvas — the
## "superseded ·" text prefix died with the labels; the state stays readable
## via MCP (annotation kind_payload / minerva_pcb_get_selection). (A CONSUMED
## hint renders nothing at all — Epoch UX2 station 1 — so the two states can
## not be confused on canvas.)
const _COLOR_SUPERSEDED_CUE := Color(0.8, 0.8, 0.8, 0.9)

## Dimming factor for the superseded polyline stroke (markers/label use their
## own 0.5): visible enough to show what was authored, dim enough to never
## compete with the constraint-owned live geometry.
const _SUPERSEDED_STROKE_DIM: float = 0.4

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
	# NOTE: no "width_mm" key here (019fa73a191e) — this dict is currently DEAD
	# (AnnotationKind.default_payload is declared but read nowhere in either
	# Minerva core or this repo; grepped and confirmed), but width_mm now
	# defaults to ABSENT everywhere else in the route-hint chain
	# (PcbAnnotationHost.build_route_hint_envelope), so a stamped 0.25 here
	# would be an inconsistent trap for the next reader who wires this up.
	default_payload = {
		"hint_type": "waypoint",
		"detail_level": "guided",
		"layer": "F.Cu",
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
	# NOTE: no default width constant here (D9a-2) — width_mm is left unset
	# (null) on commit so precedence falls through to the board's
	# design_rules.defaults.trace_width_mm, same fix D9a applied one level up
	# in PcbAnnotationHost.build_route_hint_envelope. A stamped constant here
	# would silently overrule the board's authored default on every single-
	# trace gesture; there is no user-facing width picker in this tool, so
	# any non-null value here would be an unconditional stamp, not a choice.

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

		# ── TRUE INTENT for the bare pad→pad gesture (Epoch UX3 station 8a) ──
		# A zero-interior-waypoint pad→pad commit IS the connectivity intent
		# minerva_pcb_add_route_intent expresses — the old path minted a
		# look-alike single_trace hint with no eager RouteTask and no task-
		# owned constraint slot. Delegate to the ONE implementation through
		# the panel's own tool entry (no second minting path to drift): the
		# intent tool adds the annotation, mints the eager task ("NET|hint"),
		# and validates same-net-ness — its refusals (cross_net_pins,
		# pin_unresolvable) are ANSWERS the old path could never give, so a
		# refusal consumes the gesture with the reason narrated rather than
		# minting a doomed hint. Falls through to the legacy envelope only
		# when no panel/tool doorway exists (older host, headless kind test)
		# — parity preserved, never regressed. A WAYPOINT-carrying gesture
		# (interior not empty) keeps its guided-hint semantics untouched (8c).
		if interior.is_empty() and anchor_is_pad and not as_point and not dest_pad.is_empty():
			var intent_reply: Variant = _mint_intent_via_panel(
				source_pins[0], dest_pins[0])
			if intent_reply is Dictionary:
				var rd: Dictionary = intent_reply
				if bool(rd.get("success", false)):
					_toast_msg("Route intent %s minted for net %s (task %s) — Propose routes it."
						% [str(rd.get("hint_id", "")), str(rd.get("net", "")), str(rd.get("task_id", ""))])
				else:
					_toast_msg("Intent refused (%s): %s"
						% [str(rd.get("error", "unknown")), str(rd.get("note", ""))])
				_reset()
				return true

		var wp_arrays: Array = []
		for wp in interior:
			wp_arrays.append([(wp as Vector2).x, (wp as Vector2).y])

		var layer := "F.Cu"
		if _host.has_method("get_current_layer"):
			layer = str(_host.call("get_current_layer"))

		var envelope: Dictionary = _host.call(
			"build_route_hint_envelope", anchor_pos.x, anchor_pos.y, "", layer, "single_trace",
			wp_arrays, "human", "", null, source_pins, dest_pins)

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

	## Station 8a's delegation seam: run minerva_pcb_add_route_intent through
	## the panel's own tool entry. Returns the reply Dictionary, or null when
	## no doorway exists (older host/panel — the caller falls through to the
	## legacy envelope). handle_tool is a coroutine, but the intent tool's
	## whole path is synchronous, so the call completes without suspending
	## and hands back the Dictionary directly; anything else (an unexpected
	## suspension) reads as "no doorway" rather than a half-answer.
	func _mint_intent_via_panel(source_pin: String, dest_pin: String) -> Variant:
		if _host == null or not _host.has_method("get_panel"):
			return null
		var panel = _host.get_panel()
		if panel == null or not panel.has_method("handle_tool"):
			return null
		# No width here (HITL-7c removed the authoring picker): the intent
		# lands at the net-class default; width is edited per-hint afterward
		# from the hint's own context menu ("Set hint width…").
		var args: Dictionary = {"source_pin": source_pin, "dest_pin": dest_pin,
			"author": "human"}
		var reply: Variant = panel.handle_tool("minerva_pcb_add_route_intent", args)
		return reply if reply is Dictionary else null

	## Narration relay — same duck-typed toast seam ViaInsertTool uses.
	func _toast_msg(text: String) -> void:
		if _host != null and _host.has_method("show_toast"):
			_host.show_toast(text)
		elif _host != null and _host.has_method("get_panel"):
			var panel = _host.get_panel()
			if panel != null and panel.has_method("_show_transient_status"):
				panel._show_transient_status(text)

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

	## A8u1: this tool edits ONE hint — bend drag, bend insert, bend delete all
	## need a single unambiguous target. With a multi-selection there is no such
	## target, and silently picking the primary would edit an annotation the user
	## did not aim at. So the edit gestures DISARM and the tool falls back to
	## pure selection; draw_preview says so on-canvas instead of drawing handles.
	## Exactly one selected → every code path below is byte-identical to pre-A8u1.
	func _multi_selected() -> bool:
		# Duck-typed against the HOST INSTANCE, not AnnotationHost's new
		# static: a class_name reference to a member the running host lacks
		# is a PARSE error that unregisters the whole kind (measured, CI run
		# 30673225191 — hint pcb-plugin/off-tree-core-api-coupling). A host
		# predating the multi-select API can never hold a multi-selection,
		# so false is the truthful degraded answer, and every gesture below
		# then behaves exactly as it did against that host before A8u1.
		if _host == null or not _host.has_method("get_selected_annotation_ids"):
			return false
		return _host.get_selected_annotation_ids().size() > 1

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
			#
			# DELIBERATELY NOT CONVERTED TO A MENU (B1u5, item 019fbb968e).
			# The board canvas's right-click became a menu because it is the
			# canvas's ONE ambient gesture — anyone can right-click a pour without
			# having asked for anything. This is different in kind: it only fires
			# while this AUTHOR TOOL is armed from the annotation dock, where
			# right-click already means "cancel / no-op" in the two sibling tools
			# above, and the whole surface is a modal editing mode the user
			# explicitly entered. Converting it would need a SECOND popup owner on
			# the annotation overlay: this kind talks to the host, never to the
			# canvas, so it cannot reach pcb_canvas's context_menu without new
			# cross-surface plumbing — which is precisely the "one menu authority"
			# the unit was ruled to preserve. Left as a gesture, on purpose.
			if _multi_selected():
				return false
			var sel := _host.get_selected_annotation_id()
			if sel.is_empty():
				return false
			var ann := _find(sel)
			var kind := _kind()
			if ann.is_empty() or kind == null or str(ann.get("kind", "")) != "pcb_route_hint":
				return false
			# Codex 1047 fix round, verdict 3: a superseded hint's path is
			# LOCKED (path_editing_locked — the host refuses the write), so the
			# bend-delete gesture never arms against it; draw_preview shows why.
			if _path_locked(ann):
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
		# Multi-selection: skip the edit-target branches entirely and go straight
		# to selection, so a click re-targets a single hint and re-arms the tool.
		if not sel.is_empty() and not _multi_selected():
			var ann := _find(sel)
			var kind := _kind()
			# Codex 1047 fix round, verdict 3: the drag/insert gestures disarm
			# on a path-locked (superseded) hint exactly like the delete gesture
			# above — the click falls through to selection re-targeting instead,
			# the same fallback a multi-selection already takes. The host would
			# refuse the resulting write anyway; disarming here removes the
			# dead-end affordance BEFORE the user invests a drag in it.
			if not ann.is_empty() and kind != null and str(ann.get("kind", "")) == "pcb_route_hint" \
					and not _path_locked(ann):
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
		if _multi_selected():
			# Visible disarm: no handles drawn, and an on-canvas reason why.
			_Self.draw_disarm_notice(ctx, "Bend edit needs one hint — click one to edit")
			return
		var sel := _host.get_selected_annotation_id()
		if sel.is_empty():
			return
		var ann := _find(sel)
		var kind := _kind()
		if ann.is_empty() or kind == null or str(ann.get("kind", "")) != "pcb_route_hint":
			return
		# Codex 1047 fix round, verdict 3: the visible-feedback half of the
		# gesture disarm above — no handles are drawn for a path-locked
		# (superseded) hint (handles ARE the promise of an edit the host will
		# refuse), and the standing disarm notice says why and names the way
		# forward. The full tool pointer (minerva_pcb_hint_convert_to_detailed)
		# lives in the host's structured refusal / warning; the canvas keeps
		# the human phrasing, same idiom as the multi-select notice above.
		if _path_locked(ann):
			_Self.draw_disarm_notice(ctx,
				"Superseded route — waypoints locked; right-click: Reclaim waypoints (convert to detailed), or steer the route")
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

	## Codex 1047 fix round, verdict 3: the ONE lock predicate, reused — the
	## kind's own path_editing_locked (true iff the station-12 supersession
	## marker is present), the SAME hook core's AnnotationTransformTool probes
	## for its vertex-edit disarm, so every edit surface answers "may this
	## path be hand-edited?" from one place. has_method-guarded (off-tree
	## caution idiom) so a registry serving an older kind degrades to
	## "unlocked" — exactly the pre-verdict behavior.
	func _path_locked(ann: Dictionary) -> bool:
		var kind := _kind()
		return kind != null and kind.has_method("path_editing_locked") \
				and bool(kind.path_editing_locked(ann))

	func _select_route_hint_at(doc_pos: Vector2) -> bool:
		var registry := _host.get_registry()
		var annotations: Array = _host.get_annotations()
		var hit_threshold := _SELECT_HIT_PX / _zoom()
		for i in range(annotations.size() - 1, -1, -1):
			var ann: Dictionary = annotations[i]
			if str(ann.get("kind", "")) != "pcb_route_hint":
				continue
			# Epoch UX2 station 1 (cold review F2): a consumed hint's corridor
			# lies exactly under its committed copper — it renders nothing and
			# must not be pickable through that invisible geometry.
			if str(ann.get("lifecycle", "open")) == "applied":
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


## Manual via-insertion tool (U4, DCR 019f7095c395 Stage-2): the autorouter
## avoids vias by preferring single-layer detours, so a human resolves a
## collision by hand — click a point on a SELECTED proposal's route to split
## the segment there, insert a via, and flip the following run of segments to
## the opposite copper layer (a second via jumps back). Instantiated directly
## by PCBPanel's route-flow toolbar cluster ("Add Via" button /
## _new_route_flow_tool), same idiom as BendHandleEditTool right above — NOT
## wired to kind.author_ui() (this is a MANIPULATION tool over an EXISTING
## hint/proposal, not an authoring tool).
##
## Selection-first idiom, mirrors BendHandleEditTool exactly: only
## pcb_route_hint annotations are selectable while this tool is active. A
## left-click near a segment of the CURRENTLY SELECTED hint inserts a via
## there (ONE annotation_modified, so undo/redo + revision history — the
## same host.update_annotation() seam BendHandleEditTool uses — already work
## for free); a click that misses every segment of the selection instead
## re-targets selection (select a different hint, or clear it) — never both
## effects from one click. Escape clears the selection.
##
## The split+via+layer-run-toggle geometry itself is NOT reimplemented here —
## it lives once, as the outer class's static apply_via_at_point() (below,
## in the "Manual via insertion" section), shared verbatim with the MCP
## parity tool minerva_pcb_add_via (panel_tools.gd._add_via) so the canvas
## gesture and an agent's tool call produce byte-identical results.
class ViaInsertTool:
	extends AnnotationAuthorTool

	# Matches BendHandleEditTool's segment/select hit-test tolerances exactly
	# (screen px, converted to doc-space via zoom at hit-test time).
	const _SEGMENT_HIT_PX := 8.0
	const _SELECT_HIT_PX := 8.0

	var _host: AnnotationHost = null

	func on_activate(host: AnnotationHost) -> void:
		_host = host

	func on_deactivate() -> void:
		_host = null

	func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
		if _host == null:
			return false

		if mods == KEY_ESCAPE:
			_host.set_selected_annotation_id("")
			return true

		if button != MOUSE_BUTTON_LEFT:
			return false

		var doc_pos := _host.transform_screen_to_doc(pos)
		var seg_r := _SEGMENT_HIT_PX / _zoom()

		var sel := _host.get_selected_annotation_id()
		# Multi-selection: no unambiguous hint to insert a via into, so the
		# insert gesture disarms and the click re-targets selection instead
		# (same rule as BendHandleEditTool; see its _multi_selected doc).
		if not sel.is_empty() and not _multi_selected():
			var ann := _find(sel)
			# Codex 1047 fix round, verdict 3: the via-insert gesture disarms
			# on a path-locked (superseded) hint, same rule + same fallback as
			# BendHandleEditTool's gestures — the click re-targets selection
			# instead of arming an edit the supersession machinery owns.
			if not ann.is_empty() and str(ann.get("kind", "")) == "pcb_route_hint" \
					and not _path_locked(ann):
				var kp: Dictionary = ann.get("kind_payload", {})
				var result: Dictionary = _Self.apply_via_at_point(kp, doc_pos.x, doc_pos.y, seg_r)
				if bool(result.get("ok", false)):
					var new_ann := ann.duplicate(true)
					new_ann["kind_payload"] = result.get("kind_payload", kp)
					annotation_modified.emit(sel, new_ann)
					return true
				# The click LANDED on this hint and the insert refused on its
				# own terms — say why and consume it. Falling through to
				# candidate targeting here would read to the human as a click
				# that did nothing at all, which is how a refusal becomes
				# indistinguishable from a dead tool. A miss
				# ("no_segment_at_point") is NOT this case: the point was never
				# on this hint, so the fall-through below is still correct.
				if str(result.get("error_code", "")) == "unsupported_layer":
					_toast(str(result.get("error", "via insert refused")))
					return true

		# ── CANDIDATE TARGETING (Epoch UX3 station 6b) ────────────────────────
		# When no hint is the selection but a route CANDIDATE (ghost) is, the
		# tool targets the candidate instead of silently disarming: the click
		# routes through RoutingWorkspace.add_via — the SAME revision-guarded,
		# path-scoped verb minerva_pcb_workspace_edit_candidate's insert_via
		# op calls, never a parallel mutation path. The workspace resolves the
		# segment at the point itself and owns every refusal by name
		# (no_segment_at_point, degenerate inserts, candidate_frozen, …);
		# refusals surface on the panel status line through the host toast.
		# Hint-targeting above is UNCHANGED — a selected hint still wins.
		if sel.is_empty() and _insert_via_into_selected_candidate(doc_pos):
			return true

		# No via inserted (nothing selected, selection isn't a route hint, or the
		# click missed every segment of the selection's route) — fall back to
		# route-hint-only selection, same idiom as BendHandleEditTool.
		return _select_route_hint_at(doc_pos)

	## Visible disarm (A8u1) — mirrors BendHandleEditTool.draw_preview. This tool
	## had no preview before; it has one now solely to say why the click that
	## normally inserts a via is not going to. Codex 1047 fix round, verdict 3
	## added the second disarm reason: a path-locked (superseded) selection.
	func draw_preview(ctx: AnnotationRenderContext) -> void:
		if _host == null:
			return
		if _multi_selected():
			_Self.draw_disarm_notice(ctx, "Via insert needs one hint — click one to edit")
			return
		# Codex 1047 fix round, verdict 3: same visible-feedback seam as
		# BendHandleEditTool — the gesture above is disarmed for this
		# selection, and the notice says why (the full tool pointer lives in
		# the host's structured refusal; the canvas keeps the human phrasing).
		var sel := _host.get_selected_annotation_id()
		if sel.is_empty():
			return
		var ann := _find(sel)
		if not ann.is_empty() and str(ann.get("kind", "")) == "pcb_route_hint" and _path_locked(ann):
			_Self.draw_disarm_notice(ctx,
				"Superseded route — via insert disarmed; right-click: Reclaim waypoints (convert to detailed), or steer the route")

	# ── internal ──────────────────────────────────────────────────────────────

	## See BendHandleEditTool._multi_selected — same rule, same reason.
	func _multi_selected() -> bool:
		# Duck-typed against the HOST INSTANCE, not AnnotationHost's new
		# static: a class_name reference to a member the running host lacks
		# is a PARSE error that unregisters the whole kind (measured, CI run
		# 30673225191 — hint pcb-plugin/off-tree-core-api-coupling). A host
		# predating the multi-select API can never hold a multi-selection,
		# so false is the truthful degraded answer, and every gesture below
		# then behaves exactly as it did against that host before A8u1.
		if _host == null or not _host.has_method("get_selected_annotation_ids"):
			return false
		return _host.get_selected_annotation_ids().size() > 1

	func _zoom() -> float:
		if _host != null and _host.has_method("get_annotation_zoom"):
			return maxf(float(_host.get_annotation_zoom()), 0.01)
		return 1.0

	## Station 6b's candidate half: insert a via into the SELECTED ghost at
	## the clicked point, through the workspace's own gated verb. True when
	## the click was consumed (applied OR refused-with-notice — a refusal on
	## the targeted ghost is an answer, not a fall-through to selection).
	## False when there is no selected candidate to target (duck-typed,
	## degrades to the pre-station behavior against an older host/panel).
	func _insert_via_into_selected_candidate(doc_pos: Vector2) -> bool:
		if _host == null or not _host.has_method("get_panel"):
			return false
		var panel = _host.get_panel()
		if panel == null or not panel.has_method("get_selection_state") \
				or not panel.has_method("get_routing_workspace"):
			return false
		var workspace = panel.get_routing_workspace()
		if workspace == null or not workspace.has_method("add_via"):
			return false
		var state: Dictionary = panel.get_selection_state()
		var cands: Array = state.get("candidates", []) if state.get("candidates", []) is Array else []
		# One unambiguous ghost, the same rule the hint half applies to hints.
		if cands.size() != 1:
			return false
		var cid := str(cands[0])
		var c = workspace.get_candidate(cid)
		if c == null:
			return false
		# from_layer is the layer the run ARRIVES on — the workspace verb
		# validates it against the copper under the point (a miss refuses
		# no_segment_at_point, a wrong claim refuses from_layer_mismatch).
		var hit: Dictionary = workspace._segment_hit(c, doc_pos)
		var from_layer := "top"
		if not hit.is_empty():
			var seg_idx := int(hit.get("segment_index", 0))
			if seg_idx >= 0 and seg_idx < c.segments.size() and c.segments[seg_idx] is Dictionary:
				from_layer = str((c.segments[seg_idx] as Dictionary).get("layer", "top"))

		# THE CONTINUATION LAYER — where the run goes past the via, which since
		# C1b is a separate question from the via's span (always through). On a
		# two-layer run the opposite side is the ONLY answer, so the gesture may
		# pick it. On an inner-layer run there are several answers and this
		# canvas has no layer picker to ask with; that picker arrives with the
		# via TOOL (station C2), which is where a tool-vs-proposal parity
		# affordance belongs.
		#
		# NOT resolved from the toolbar's layer OptionButton, which drives
		# _canvas.trace_layer_filter — a VIEW filter. Letting a view control
		# silently choose where copper lands is the same class of surprise this
		# station exists to remove, and would make "what am I looking at" and
		# "what am I authoring" one setting.
		var to_layer := _continuation_for(from_layer)
		if to_layer.is_empty():
			_toast(("This run is on %s. A via here could continue on any copper layer, and the canvas "
				+ "has no layer picker yet — use minerva_pcb_workspace_edit_candidate "
				+ "(op:insert_via, to_layer:…) to say which. Nothing was changed.") % from_layer)
			return true
		var res: Dictionary = workspace.add_via(cid, doc_pos, from_layer, to_layer)
		if bool(res.get("ok", false)):
			_toast("Via inserted on %s — the following run flips to %s; its verdict is stale until the next Check."
				% [cid, to_layer])
		else:
			_toast("Via insert on %s refused (%s): %s"
				% [cid, str(res.get("error", "unknown")), str(res.get("message", ""))])
		return true

	## The layer a run continues on past a via when the gesture can work it out
	## ALONE, or "" when it cannot and must ask instead.
	##
	## Deliberately the same shape and the same refusal as the hint half's
	## _toggle_layer: only the outer pair has one unambiguous answer, and both
	## spellings of it are accepted because candidate segments carry canonical
	## ids while hint segments may carry either. Two small matchers rather than
	## one shared helper — these live in different classes over different data
	## models, and the hint half must ALSO preserve its caller's spelling, which
	## this one has no reason to do (a candidate is canonical by construction).
	func _continuation_for(from_layer: String) -> String:
		match from_layer.strip_edges().to_lower():
			"top", "f.cu":
				return "bottom"
			"bottom", "b.cu":
				return "top"
			_:
				return ""


	## Host toast → the panel status line (duck-typed; silent when absent).
	func _toast(text: String) -> void:
		if _host != null and _host.has_method("show_toast"):
			_host.show_toast(text)
		elif _host != null and _host.has_method("get_panel"):
			var panel = _host.get_panel()
			if panel != null and panel.has_method("_show_transient_status"):
				panel._show_transient_status(text)

	## See BendHandleEditTool._kind — same registry lookup, mirrored here
	## because these tool classes deliberately share no base beyond
	## AnnotationAuthorTool (Codex 1047 fix round, verdict 3).
	func _kind() -> AnnotationKind:
		if _host == null:
			return null
		var registry := _host.get_registry()
		if registry == null:
			return null
		return registry.get_annotation_kind(StringName("pcb_route_hint"))

	## See BendHandleEditTool._path_locked — same predicate, same reason
	## (Codex 1047 fix round, verdict 3).
	func _path_locked(ann: Dictionary) -> bool:
		var kind := _kind()
		return kind != null and kind.has_method("path_editing_locked") \
				and bool(kind.path_editing_locked(ann))

	func _select_route_hint_at(doc_pos: Vector2) -> bool:
		var registry := _host.get_registry()
		var annotations: Array = _host.get_annotations()
		var hit_threshold := _SELECT_HIT_PX / _zoom()
		for i in range(annotations.size() - 1, -1, -1):
			var ann: Dictionary = annotations[i]
			if str(ann.get("kind", "")) != "pcb_route_hint":
				continue
			# Epoch UX2 station 1 (cold review F2): a consumed hint's corridor
			# lies exactly under its committed copper — it renders nothing and
			# must not be pickable through that invisible geometry.
			if str(ann.get("lifecycle", "open")) == "applied":
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

	func _find(id: String) -> Dictionary:
		if _host == null:
			return {}
		for ann in _host.get_annotations():
			if ann is Dictionary and str((ann as Dictionary).get("id", "")) == id:
				return ann as Dictionary
		return {}


## Shared on-canvas notice for the single-target tools above (BendHandleEditTool,
## ViaInsertTool) when a multi-selection leaves them without an unambiguous edit
## target (A8u1). Pinned to the top-left of the viewport in SCREEN pixels — the
## disarm reason must be readable wherever the board is panned or zoomed to, and
## must not chase the selection around. ctx.from_screen maps back to document
## space so ctx.draw_string's own doc→screen mapping lands it where intended.
static func draw_disarm_notice(ctx: AnnotationRenderContext, text: String) -> void:
	ctx.draw_string(null, ctx.from_screen(Vector2(12.0, 22.0)), text,
		Color(1.0, 0.72, 0.22, 0.95), 13)


# ── Manual via insertion (U4, DCR 019f7095c395 Stage-2) ───────────────────────
#
# Shared by ViaInsertTool (canvas gesture, above) and the MCP parity tool
# minerva_pcb_add_via (panel_tools.gd._add_via) — ONE implementation, so a
# human's click and an agent's tool call always produce the same geometry.
# Reached from panel_tools.gd via a preload() of this script (off-tree,
# no class_name — same convention PCBPanel.gd's _PcbRouteHintKindScript uses).

## Split the kind_payload.segments entry nearest (x, y) into two at its
## projected point, append that point to kind_payload.vias, and recompute
## every segment's layer via the layer-run toggle (see
## _recompute_layer_runs below).
##
## Returns {ok:true, kind_payload: Dictionary (fresh — segments + vias
## updated, every other key preserved verbatim), via_count: int,
## segments: Array}, or a REFUSAL {ok:false, error: String, error_code: String}
## which is always a complete no-op — the caller must persist nothing.
##
## error_code lets callers tell the two refusals apart, because they mean
## opposite things to a click:
##   "no_segment_at_point" — the point missed this hint. A canvas gesture
##                           should keep looking (a candidate may be under the
##                           cursor); this is not an error the human caused.
##   "unsupported_layer"   — the point HIT, and the run is on a copper layer
##                           whose via span this payload cannot express (see
##                           _toggle_layer). The gesture must stop and SAY SO;
##                           falling through would leave the human's click
##                           looking like it did nothing.
static func apply_via_at_point(kind_payload: Dictionary, x: float, y: float, threshold_mm: float = _HIT_THRESHOLD_MM) -> Dictionary:
	var segments_raw: Variant = kind_payload.get("segments", [])
	var segments: Array = (segments_raw as Array).duplicate(true) if segments_raw is Array else []
	if segments.is_empty():
		return {"ok": false, "error": "proposal has no segments to split"}

	var click := Vector2(x, y)
	var best_idx := -1
	var best_dist := INF
	var best_point := Vector2.ZERO
	for i in range(segments.size()):
		var seg: Variant = segments[i]
		if not (seg is Dictionary):
			continue
		var a := _to_vec2((seg as Dictionary).get("start", [0, 0]))
		var b := _to_vec2((seg as Dictionary).get("end", [0, 0]))
		var proj := _project_on_segment(a, b, click)
		var d := proj.distance_to(click)
		if d < best_dist:
			best_dist = d
			best_idx = i
			best_point = proj

	if best_idx < 0 or best_dist > threshold_mm:
		return {"ok": false, "error_code": "no_segment_at_point",
			"error": "no route segment within %.2fmm of (%.3f, %.3f)" % [threshold_mm, x, y]}

	# The layer-run toggle always starts from the ORIGINAL first segment's
	# layer — captured before the split below, so it stays stable across
	# repeated via insertions (adding via #2 never changes where run #1 starts).
	var start_layer := "F.Cu"
	if segments[0] is Dictionary:
		start_layer = str((segments[0] as Dictionary).get("layer", "F.Cu"))

	var target: Dictionary = segments[best_idx]
	var a := _to_vec2(target.get("start", [0, 0]))
	var b := _to_vec2(target.get("end", [0, 0]))
	var target_layer := str(target.get("layer", start_layer))
	var seg1 := {"start": [a.x, a.y], "end": [best_point.x, best_point.y], "layer": target_layer}
	var seg2 := {"start": [best_point.x, best_point.y], "end": [b.x, b.y], "layer": target_layer}
	segments[best_idx] = seg1
	segments.insert(best_idx + 1, seg2)

	var vias_raw: Variant = kind_payload.get("vias", [])
	var vias: Array = (vias_raw as Array).duplicate(true) if vias_raw is Array else []
	vias.append([best_point.x, best_point.y])

	# AUTHORED LAYERS ARE CHECKED TOO, NOT JUST THE RUNNING ONE (cold review,
	# finding 1 — the defect C1a's guard did not actually close).
	#
	# _recompute_layer_runs OVERWRITES every segment's layer from the running
	# toggle value, so an authored layer is discarded before the toggle ever
	# sees it. Guarding only the running layer therefore missed the case that
	# matters most: a payload of [F.Cu, In1.Cu] starts on F.Cu, which IS
	# toggleable, so the walk proceeded and relabelled the In1.Cu run "B.Cu"
	# under a success reply. Exactly the silent relocation C1a exists to stop,
	# one door over — and epoch NLC C1b made that payload FIRST-CLASS DATA in
	# the same range (route_bridge now materializes authored per-segment layers
	# verbatim), so the shape is not hypothetical, it is the shape the worker
	# was taught to honour.
	#
	# Refused rather than honoured: with mixed authored layers there is no
	# unambiguous answer to "which layer does the tail continue on", and this
	# payload has no way to say. Choosing for the user is the guess this whole
	# station removes. A segment carrying NO layer key is not an authored
	# layer and is left to the start_layer default above.
	for seg_any in segments:
		if not (seg_any is Dictionary):
			continue
		var seg_d: Dictionary = seg_any
		if not seg_d.has("layer"):
			continue
		var authored := str(seg_d["layer"])
		if _toggle_layer(authored).is_empty():
			return {"ok": false, "error_code": "unsupported_layer",
				"error": ("this proposal already runs on %s, and a via records no span, so which "
					+ "copper layer the run continues on afterwards is unstated. Only the outer "
					+ "pair (F.Cu<->B.Cu, or top<->bottom) has one unambiguous answer. "
					+ "Nothing was changed.") % authored}

	# REFUSAL BEFORE MUTATION. `segments`/`vias` above are local duplicates, so
	# returning here leaves the caller's kind_payload untouched — the split and
	# the appended via never reach anything that persists.
	var recompute: Dictionary = _recompute_layer_runs(segments, vias, start_layer)
	if not bool(recompute.get("ok", false)):
		var stuck := str(recompute.get("layer", ""))
		return {"ok": false, "error_code": "unsupported_layer",
			"error": ("a via on a %s run cannot be placed from this proposal: the hint records "
				+ "a via as a bare point with no span, so which of the stack's other copper "
				+ "layers the run continues on is unstated. Only the outer pair "
				+ "(F.Cu<->B.Cu, or top<->bottom) has one unambiguous answer. "
				+ "Nothing was changed.") % stuck}

	var recomputed: Array = recompute.get("segments", [])
	var new_payload := kind_payload.duplicate(true)
	new_payload["segments"] = recomputed
	new_payload["vias"] = vias

	return {"ok": true, "kind_payload": new_payload, "via_count": vias.size(), "segments": recomputed}


## Position-match tolerance (board mm) used to decide whether a segment
## boundary sits AT a via — deliberately tight (split points are computed in
## the same call that appends the via, so they match exactly bar float noise;
## this is not a UI hit-test threshold).
const _VIA_EPS_MM: float = 0.01

## Pure recompute of every segment's layer from `vias` + `start_layer` — walks
## `segments` IN ORDER (they form a connected start→end chain), maintaining a
## "current layer" that begins at start_layer and TOGGLES each time a
## segment's start point lands on a via position. Order-independent in
## `vias` (membership is tested by proximity against every via, not by
## index) and idempotent (a pure function of its three inputs — calling it
## again with the same segments/vias/start_layer reproduces the same output).
## N vias on the path therefore produce N layer alternations: one via flips
## the tail to the opposite layer, a second flips it back, etc.
##
## FAILS CLOSED, and returns a STATUS rather than an Array so it can: the
## moment a crossing lands on a layer _toggle_layer cannot resolve, the whole
## recompute refuses and names that layer. It does NOT emit the segments it had
## already re-layered before the failure — a partial run is a board half-moved
## to another layer, which is worse than either outcome the caller chose
## between. Returns {"ok": true, "segments": Array} or
## {"ok": false, "layer": String} naming the layer it could not leave.
static func _recompute_layer_runs(segments: Array, vias: Array, start_layer: String) -> Dictionary:
	var via_points: Array = []
	for v in vias:
		via_points.append(_to_vec2(v))

	var current := start_layer
	var out: Array = []
	for i in range(segments.size()):
		if not (segments[i] is Dictionary):
			continue
		var seg: Dictionary = (segments[i] as Dictionary).duplicate(true)
		if i > 0:
			var seg_start := _to_vec2(seg.get("start", [0, 0]))
			for vp in via_points:
				if (vp as Vector2).distance_to(seg_start) <= _VIA_EPS_MM:
					var next_layer := _toggle_layer(current)
					if next_layer.is_empty():
						return {"ok": false, "layer": current}
					current = next_layer
					break
		seg["layer"] = current
		out.append(seg)
	return {"ok": true, "segments": out}


## The layer a run continues on after crossing a via, or "" when this function
## CANNOT KNOW — which every caller must treat as a refusal, never as a default.
##
## F.Cu <-> B.Cu, BY NAME, and nothing else. The `else "F.Cu"` this replaced
## answered every input it did not recognise with the top layer, so a via
## inserted on an In1.Cu run relabelled the whole downstream run "F.Cu" — the
## exact defect class agent_router.layers.canon_to_kicad had its own top-layer
## default deleted for (route_bridge.py:127-131: "a silently defaulted layer
## name puts copper on the wrong side of a board that then gets fabricated").
##
## A two-layer board's toggle is unambiguous: leaving F.Cu there is one place
## to go. On a 4-layer stack a through via leaving In1.Cu reaches F.Cu, In2.Cu
## AND B.Cu, and this payload carries nothing that says which — the hint's via
## is a bare [x, y] point with no span. Picking one is a GUESS, and a guess
## about which copper layer a trace lands on is not a thing this file is
## entitled to make. Returning "" hands that decision back up to a caller that
## can refuse out loud. Real per-via spans are epoch NLC station C1b; until
## then inner-layer runs refuse rather than lie.
##
## SPELLING-AGNOSTIC, and answers in the SPELLING IT WAS ASKED IN. Segments on
## this payload are written by more than one producer and _layer_color already
## treats the two vocabularies as equally valid (it reads them through
## PcbLayerStack.inner_index_any), so matching only the KiCad pair would refuse
## a legitimate "bottom" run and turn this guard into a regression.
##
## Deliberately NOT routed through PcbLayerStack.kicad_to_canon: that is the
## READ side and maps "" to "top" with a warning, which would reintroduce
## exactly the silent default being removed here — an empty layer name must
## refuse, not become the top layer. The pair is two entries; matching it here
## is cheaper than a helper that has to be safe for a different caller.
const _TOP_SPELLINGS: Array = ["f.cu", "top"]
const _BOTTOM_SPELLINGS: Array = ["b.cu", "bottom"]

static func _toggle_layer(layer: String) -> String:
	var low := layer.strip_edges().to_lower()
	if low in _TOP_SPELLINGS:
		return "B.Cu" if low == "f.cu" else "bottom"
	if low in _BOTTOM_SPELLINGS:
		return "F.Cu" if low == "b.cu" else "top"
	return ""


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

## Manipulation profile (universal select, docket 019fd09b209e): a route hint
## is a POLYLINE, not a box — scaling or rotating it is geometrically
## meaningless (there is no "corner" a waypoint chain has), so declaring
## "path" here tells AnnotationTransformTool to offer this kind's corners
## (bend_points/with_bend_points/nearest_bend_insertion, right above/below)
## through the SAME universal-select gizmo every other annotation uses,
## instead of the TRS scale/rotate handles. Per-kind contract: manipulation
## follows GEOMETRY class, not authorship or workflow-class. Translate (body
## drag) is unaffected — sliding the whole hint is still meaningful and stays
## on.
##
## The modal "Edit hint" toolbar tool (BendHandleEditTool, above) is NOT
## replaced by this — it remains for bend editing under its own
## hint-only selection semantics (selecting via that tool narrows selection to
## pcb_route_hint annotations only, which universal select does not do).
func manipulation_profile() -> String:
	return "path"


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
	# Map the polyline segment index into bend_points()-array space by COUNTING,
	# not by assuming full == [anchor, bends…, dest] (boundary run
	# first-execution fix): in the LEGACY full-path convention `waypoints`
	# already carries the anchor as its first element AND _waypoint_points()
	# prepends _anchor_position() unconditionally, so `full` is
	# [anchor, anchor, bends…, dest] there — two leading non-bend points, not
	# one — and the old "insert_at = i" mapping was off by one (an insert on the
	# last segment produced an out-of-range index and the edit was lost). The
	# bends always sit as one contiguous run ending one before the destination
	# (both storage conventions — see bend_points()/with_bend_points()), so the
	# number of leading non-bend points is size-derived:
	#   lead = full.size() - bend_count - 1 (the trailing destination).
	# Segment i spans full[i]..full[i+1]; a point inserted there goes before
	# full[i+1], i.e. bend index (i + 1) - lead, clamped to the valid 0..count
	# insertion range for the anchor-side segments that sit before any bend.
	var bend_count := bend_points(annotation).size()
	var lead := full.size() - bend_count - 1
	return {"point": best_point,
		"insert_at": clampi(best_seg + 1 - lead, 0, bend_count)}


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


# ── Render-taxonomy gate (Epoch UX1 station 7, docket 019fcb32b5 / epoch
# 019fd0ac09ea) ────────────────────────────────────────────────────────────────
#
# Owner ruling: a route hint whose task ALREADY has a live candidate, drawn as
# a full polyline, reads as a SECOND, competing route sitting right next to the
# candidate's own corridor on canvas — the intent is answered, so the hint's
# job from here is just to say "this is what that candidate is for", which
# endpoint markers + its label do without the visual collision. A consumed
# hint (lifecycle "applied" — a candidate built from it has already been
# committed to copper) renders NOTHING AT ALL (Epoch UX2 station 1, owner
# ruling: "once suggestions are applied, the real parts are what matter. The
# hints no longer need to exist in any visible form."): the annotation
# persists as an invisible record — citeable refs, provenance, sidecar — and
# commit-undo restores its ink for free because the mode is a pure lifecycle
# read over state that is never deleted. Selecting a hint wins back the full
# corridor — editing (bend-drag, via-insert) needs the whole path on screen —
# EXCEPT for applied hints, whose invisibility is unconditional.

## Pure decision: which render mode `annotation` gets, given `host` (duck-typed,
## may be null/incomplete — see _has_live_candidate below). Returns one of
## "none" | "full" | "markers" | "superseded". Consumed directly by
## render(); kept side-effect-free and host-optional so it is testable in
## isolation.
##
## Priority order (first match wins):
##  -2. lifecycle == "applied" (consumed)                         -> "none"
##  -1. kind_payload.waypoints_superseded_by_constraint_revision  -> "superseded"
##   0. host == null (headless / no host at all)                  -> "full"
##   1. selected — ANY selection-set membership, not just primary -> "full"
##   2. a live candidate's source_hint_ids names this hint        -> "markers"
##   3. otherwise — the hint is the route's sole representation   -> "full"
##
## Step -2 (Epoch UX2 station 1, owner-ruled Option A) outranks EVERYTHING —
## supersession, the host-null degrade, selection: "accepted state is
## invisible; the user sees real parts" is an UNCONDITIONAL invariant, and
## every conditional version of it leaves a leak path where consumed ink
## resurfaces (the exact bug class HITL-5 reported as "markers remain" /
## "parts seem ghosted"). Specifically:
##   * above "superseded": a superseded hint whose candidate later commits is
##     consumed — the slash-corridor is history-of-a-history, and real copper
##     now owns the geometry;
##   * above host-null: a pure lifecycle read needs no host (the same argument
##     that lets step -1 sit above step 0 — no PRE-lifecycle hint carries
##     "applied", so no legacy headless render changes), and a headless
##     overlay export must agree with the canvas about what accepted means;
##   * above selection: a consumed hint can never BE selected —
##     PcbAnnotationHost's selection veto refuses applied hints at every
##     setter and deselects on the lifecycle flip (cold review F1), canvas
##     claims are masked by the F1 gates (zero ink), and the bend/via tools
##     skip applied hints in their own pickers (F2). This rung is the belt
##     for any host that lacks the veto. Undo-restorability is the lifecycle
##     reconcile's job (applied↔open, both directions), not a render-time
##     affordance: the mode is a pure read, so the flip re-inks with no
##     cached state.
##
## Step -1 (Codex 1047 fix round, verdict 1) outranks EVERYTHING below,
## selection included, and deliberately sits ABOVE even the host-null degrade:
## the station-12 supersession marker means the hint's waypoints are INERT —
## routing authority moved to a task-level routing constraint, and the host
## REFUSES edits to those waypoints (PcbAnnotationHost's marker guard). Letting
## selection win "full" here (the pre-fix behavior) rendered the corridor at
## full authority and exposed vertex edit handles for geometry the host will
## refuse to write — an affordance that is a lie. The check is a pure
## kind_payload read needing no host at all, which is why it may sit above the
## step-0 reachability degrade without breaking that rule's promise: step 0
## exists so a headless render is byte-identical to PRE-station-7 rendering,
## and no pre-station-7 hint carries the (station-12) marker — a stamped hint
## has no "old behavior" to preserve. The marker vanishing (guided→detailed
## conversion strips it) restores the ordinary ladder purely from payload
## state — nothing here is cached.
##
## (Historical note: pre-UX2, step 0 sat above the then-"markers_dimmed"
## applied check so a headless render of an applied hint stayed "full" —
## cold review F4. Station 1's owner ruling supersedes that: applied is now
## invisible everywhere, headless included, for the reasons above.)
##
## Degrade rule: any missing hop in step 3's host→panel→workspace duck-typed
## walk (see _has_live_candidate) reads as "no live candidate", which falls
## through to step 4 — "full". A host predating get_panel()/get_routing_workspace()
## therefore renders EXACTLY as before this station too, never errors.
func _render_mode_for(annotation: Dictionary, host) -> String:
	if str(annotation.get("lifecycle", "open")) == "applied":
		return "none"
	if _is_superseded(annotation):
		return "superseded"
	var ann_id := str(annotation.get("id", ""))
	if host == null:
		return "full"
	if not ann_id.is_empty() and _is_selected(ann_id, host):
		return "full"
	if _has_live_candidate(ann_id, host):
		return "markers"
	return "full"


## True iff this hint carries the station-12 legacy-migration supersession
## marker: kind_payload.waypoints_superseded_by_constraint_revision, an int
## >= 1 naming the routing-constraint revision that now owns this route.
## Numeric-but-float is accepted (a payload that crossed a JSON boundary
## carries floats); 0 / negative / non-numeric values are NOT a marker —
## the stamp contract (panel_tools' migration writer) is int >= 1, and a
## malformed value must degrade to ordinary (unlocked) behavior rather than
## silently freezing a hint nobody actually stamped.
## (Codex 1047 fix round, verdict 1.)
static func _is_superseded(annotation: Dictionary) -> bool:
	var kp: Variant = annotation.get("kind_payload", {})
	if not (kp is Dictionary):
		return false
	var rev: Variant = (kp as Dictionary).get("waypoints_superseded_by_constraint_revision", null)
	if rev is int or rev is float:
		return int(rev) >= 1
	return false


## Duck-typed lock hook for core's AnnotationTransformTool (Codex 1047 fix
## round, verdict 1): true iff this annotation's path geometry must NOT be
## offered vertex-edit affordances (no BEND zone, no bend claims, no bend
## insert/delete). The transform tool probes this via has_method — a kind
## without the method is unlocked, so every other path kind keeps its default
## behavior. True exactly when the station-12 supersession marker is present:
## the host refuses waypoint writes on such a hint, so handles would promise
## an edit that can never land. Pure payload read — no cached state, so
## stripping the marker (guided→detailed conversion) unlocks immediately.
func path_editing_locked(annotation: Dictionary) -> bool:
	# Consumed hints (Epoch UX2 station 1) are locked too: the record of what
	# was asked for must not be editable after its copper landed — an edit
	# would falsify provenance, and the geometry is invisible anyway. (Second
	# fence: the selection veto in PcbAnnotationHost normally keeps a consumed
	# hint out of selection entirely.)
	return _is_superseded(annotation) \
		or str(annotation.get("lifecycle", "open")) == "applied"


## True iff `ann_id` is a member of the CURRENT selection (F3, cold review):
## a hint caught up in a multi-selection is still something the user is
## actively working with and needs its full corridor, not just markers — not
## just when it happens to be the lone/primary selection. Duck-typed against
## get_selected_annotation_ids() (the multi-select seam), with a fallback to
## primary-only get_selected_annotation_id() for a host predating it — the
## SAME fallback convention BendHandleEditTool._multi_selected uses above.
func _is_selected(ann_id: String, host) -> bool:
	if host.has_method("get_selected_annotation_ids"):
		var ids: Variant = host.get_selected_annotation_ids()
		if ids is Array or ids is PackedStringArray:
			for id in ids:
				if str(id) == ann_id:
					return true
		return false
	if host.has_method("get_selected_annotation_id"):
		return str(host.get_selected_annotation_id()) == ann_id
	return false


## True iff some candidate in the routing workspace's LIVE set (proposed/
## pinned — anything not superseded/rejected/committed) names `hint_id` in its
## source_hint_ids, i.e. this hint's routing intent is already answered by an
## on-canvas candidate corridor.
##
## Duck-typed host → panel → workspace, the SAME seam panel_tools.gd's
## _get_workspace(host) uses (host.get_panel() to reach the live PCBPanel).
## Off-tree rule: no class_name, so every hop is has_method-guarded — a host,
## panel, or workspace that predates the routing workspace (or a test double
## missing one of these methods) degrades to false rather than erroring.
func _has_live_candidate(hint_id: String, host) -> bool:
	if hint_id.is_empty() or host == null or not host.has_method("get_panel"):
		return false
	var panel = host.get_panel()
	if panel == null or not is_instance_valid(panel) or not panel.has_method("get_routing_workspace"):
		return false
	var workspace = panel.get_routing_workspace()
	if workspace == null or not workspace.has_method("live_candidate_ids") \
			or not workspace.has_method("get_candidate"):
		return false
	for cid in workspace.live_candidate_ids():
		var c = workspace.get_candidate(str(cid))
		if c == null:
			continue
		# F6 (cold review): a candidate object that doesn't carry
		# source_hint_ids at all is a degrade case, not a hard error — the
		# ONE hop in this walk that reads a member off `c` directly instead
		# of duck-typing through has_method first.
		if not ("source_hint_ids" in c):
			continue
		for hid in c.source_hint_ids:
			if str(hid) == hint_id:
				return true
	return false


## Diamond marker at `pos`, `radius` px, solid `color`. Factored out of render()
## so the full-polyline path and the intent-render (markers-only) path draw
## byte-identical ink from one call site each.
func _draw_endpoint_marker(ctx: AnnotationRenderContext, pos: Vector2, radius: float, color: Color) -> void:
	var diamond := PackedVector2Array([
		pos + Vector2(0, -radius), pos + Vector2(radius, 0),
		pos + Vector2(0, radius), pos + Vector2(-radius, 0),
	])
	var cols := PackedColorArray([color, color, color, color])
	ctx.draw_polygon(diamond, cols)


## Gray strike-through across an endpoint marker — the geometry-level
## "superseded" cue (Codex 1047 fix round, verdict 1; see
## _COLOR_SUPERSEDED_CUE's doc for why a slash and why gray). Drawn slightly
## wider than the diamond (1.4 × radius) so it visibly crosses OUT the marker
## rather than blending into its fill.
func _draw_superseded_slash(ctx: AnnotationRenderContext, pos: Vector2, radius: float) -> void:
	var r := radius * 1.4
	ctx.draw_line(pos + Vector2(-r, r), pos + Vector2(r, -r), _COLOR_SUPERSEDED_CUE, 1.5)


## The endpoint marker points drawn in "markers" mode: the
## anchor, plus the hint's other known endpoint (see _far_endpoint), when it
## has one. Single source of truth for render()'s intent-render branch AND
## _visible_ink_hit/pcb_canvas.gd's F1 claim gate, so all three agree on
## exactly what ink is on screen.
func _marker_points(annotation: Dictionary) -> Array:
	var pts: Array = [_anchor_position(annotation)]
	var far: Variant = _far_endpoint(annotation)
	if far != null:
		pts.append(far)
	return pts


## The hint's far/dest endpoint for marker purposes, independent of
## _waypoint_points()'s render-oriented fallback chain. H1 (cold review): a
## LEGACY segments-bearing hint (kind_payload.segments, no dest_point, no
## interior waypoints) has nothing past the anchor for _waypoint_points() to
## return, so fall back to the last segment's `end` — the same far point the
## per-segment render path already draws. null when nothing names one.
func _far_endpoint(annotation: Dictionary) -> Variant:
	var wp_pts := _waypoint_points(annotation)
	if wp_pts.size() >= 2:
		return wp_pts[wp_pts.size() - 1]
	var segments_raw: Variant = annotation.get("kind_payload", {}).get("segments", [])
	if segments_raw is Array and not (segments_raw as Array).is_empty():
		var last_seg: Variant = (segments_raw as Array).back()
		if last_seg is Dictionary and (last_seg as Dictionary).has("end"):
			return _to_vec2((last_seg as Dictionary)["end"])
	return null


## Visible-ink hit-test for the "markers" render mode (F1,
## cold review station 7 fix round): true iff `point` (document space) lands
## within `threshold` of the anchor/far-end marker disc, or inside the
## label's drawn rect — the ONLY ink those modes actually put on screen (see
## render()'s intent-render branch). `zoom` reproduces render()'s own
## marker curve (_marker_geometry) so this matches what is actually drawn at
## the current view, not a document-space-only approximation.
##
## Distinct from hit_test() (which sweeps the WHOLE corridor regardless of
## render mode, by design — see hit_test()'s own doc comment): this is the
## narrower probe pcb_canvas.gd's _claim_annotation_press / _sweep_annotations
## F1 gates use so a press or marquee that misses the visible ink can fall
## through to whatever candidate or board entity is actually drawn under it,
## instead of being swallowed by the hint's now-invisible corridor.
func _visible_ink_hit(annotation: Dictionary, point: Vector2, threshold: float, zoom: float) -> bool:
	# HITL-6 (docket 019fdf2b5918): sizing + visibility come from the ONE
	# curve render() draws with — a faded-out marker (alpha 0 at high zoom)
	# contributes no ink and therefore claims no clicks. Marker discs are the
	# ONLY hint ink since HITL-6b retired the labels (docket 019fdf553f).
	var geo := _marker_geometry(zoom)
	if geo.y <= 0.0:
		return false
	var effective := threshold + geo.x
	for p in _marker_points(annotation):
		if (p as Vector2).distance_to(point) <= effective:
			return true
	return false


# ── Required rendering hooks ──────────────────────────────────────────────────

## Waypoint polyline with a layer-tinted, width/zoom-aware stroke + a diamond
## marker at the anchor + a text label. Coordinates are document-space (board mm);
## the substrate AnnotationOverlay applies the host transform before calling us.
##
## Render-taxonomy gate (see block above): when _render_mode_for resolves to
## "markers" the polyline (and its via markers, which only
## make sense alongside the polyline) is withheld — a live candidate is
## already drawing that corridor — and this draws ENDPOINT MARKERS + the label
## only. "none" (consumed hint, Epoch UX2 station 1) draws nothing whatsoever.
## "full" (still the ONLY path when ctx.host is null/incomplete, applied
## lifecycle aside) is byte-identical to pre-station-7 rendering.
func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	if ctx == null:
		return
	# "none" (Epoch UX2 station 1): a consumed hint puts ZERO ink on screen —
	# no markers, no label. Checked before any other work; the annotation
	# itself persists (record/undo), only its rendering retires.
	var mode := _render_mode_for(annotation, ctx.host)
	if mode == "none":
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

	# HITL-6 (docket 019fdf2b5918): size + visibility from the shared curve —
	# smaller base, slightly larger zoomed out, GONE at high zoom, where a
	# diamond over the pad hides exactly the connection-point geometry
	# (HITL-6's 0.54mm GND jog) the reviewer needs to see.
	var marker_geo := _marker_geometry(ctx.zoom)
	var d := marker_geo.x
	var markers_on := marker_geo.y > 0.0
	var marker_color := AnnotationRenderContext.author_color("ai") if is_ai else stroke_color
	marker_color = Color(marker_color.r, marker_color.g, marker_color.b,
		marker_color.a * marker_geo.y)
	# "superseded" (Codex 1047 fix round, verdict 1) dims its markers — no
	# longer live authoring input, and its own branch below adds the dimmed
	# corridor + slash. (The consumed-hint "markers_dimmed" mode that shared
	# this dimming retired at Epoch UX2 station 1: applied renders "none".)
	# At marker-faded zooms the slash cue fades with its markers — the dimmed
	# corridor + the "superseded ·" label prefix still carry the state.
	if mode == "superseded":
		marker_color = Color(marker_color.r, marker_color.g, marker_color.b, marker_color.a * 0.5)

	if mode == "full":
		# Waypoint polyline. Lossless proposals (U2, DCR 019f7095c395 Stage-1) carry
		# kind_payload.segments — the route's EXACT per-segment geometry, each with
		# its own real layer — so a reviewer SEES a layer change before accepting
		# instead of the flattened `waypoints` polyline hiding it as one continuous
		# joint. Draw those per-segment (each in ITS layer's color) when present;
		# fall back to the single-color flattened polyline for hints/legacy
		# proposals that only carry `waypoints`. AI strokes stay dashed either way.
		#
		# ── INV-4 FENCE (campaign 2 epoch C, unit 3 — GATE 019f70f76c2f) ───────────
		# THE WAYPOINT FALLBACK BELOW SERVES ROUTE HINTS. IT MUST NEVER SERVE A ROUTE
		# CANDIDATE.
		#
		# The two things are different objects with different contracts:
		#   * A route HINT is a human's authored INSTRUCTION to the router — "go
		#     roughly this way". Its `waypoints` are a single flattened polyline on
		#     ONE named layer, and that is the whole truth about it. Flattening loses
		#     nothing, because there was never per-segment layer information to lose.
		#   * A route CANDIDATE is the router's ANSWER. Its truth is
		#     RouteCandidate.segments — independent entities, EACH with its own layer,
		#     width, id and ordered points, plus explicit vias where copper changes
		#     side. Flattening it into one polyline destroys exactly the information a
		#     reviewer needs before accepting: which side of the board the copper
		#     lands on, and where it changes.
		#
		# Candidates are therefore rendered, hit-tested and bounded by
		# pcb_canvas.gd's own exact-geometry path (candidate_draw_items /
		# _candidate_at / _entity_anchor), which reads segments and vias and contains
		# no waypoint read at all. This kind is not on that path.
		#
		# THE GUARD IS FAIL-CLOSED, not advisory: a payload that identifies itself as
		# candidate-sourced and yet carries no `segments` is a CONTRACT VIOLATION (a
		# candidate always has exact geometry — it is constructed from it), so the
		# polyline is REFUSED with a named warning rather than silently drawn as a
		# flattened lie. The marker and label still draw, so the annotation does not
		# vanish; what is withheld is the misleading stroke.
		var segments_raw: Variant = payload.get("segments", [])
		var per_segment: Array = (segments_raw as Array) if segments_raw is Array else []
		if not per_segment.is_empty():
			_draw_per_segment_polyline(ctx, per_segment, stroke_px, is_ai)
		elif _is_candidate_sourced(payload):
			push_warning("[pcb_route_hint] INV-4: refusing to render a candidate-sourced payload (%s) through the waypoint path — route candidates render from exact segments on the canvas, never from flattened waypoints" \
				% _candidate_marker_of(payload))
		else:
			var pts := _waypoint_points(annotation)
			if pts.size() >= 2:
				if is_ai:
					_draw_dashed_polyline(ctx, pts, stroke_color, stroke_px)
				else:
					ctx.draw_polyline(pts, stroke_color, stroke_px)

		# Via markers (U2): a small amber ring at each via position so a layer
		# change reads as an explicit, deliberate via — not a silent joint —
		# before the human accepts the proposal.
		var vias_raw: Variant = payload.get("vias", [])
		var via_list: Array = (vias_raw as Array) if vias_raw is Array else []
		for v in via_list:
			_draw_via_marker(ctx, _to_vec2(v))

		# Diamond marker at the anchor (AI keeps the substrate cyan so authorship
		# stays one-glance even though strokes are now layer-tinted).
		if markers_on:
			_draw_endpoint_marker(ctx, pos, d, marker_color)
	elif mode == "superseded":
		# Superseded render (Codex 1047 fix round, verdict 1): the station-12
		# marker says these waypoints are INERT — authority moved to a
		# task-level routing constraint, and the host refuses edits to them.
		# The ruling: never full-authority rendering, even selected — but a
		# user who selects a stamped hint must still see what they selected.
		# So: the legacy corridor as a heavily DIMMED solid polyline (visible
		# history, never a competitor to the constraint-owned live geometry),
		# dimmed endpoint markers, and a gray slash struck through each marker
		# as the unambiguous "superseded, not merely dimmed" cue (see
		# _COLOR_SUPERSEDED_CUE — the cue must survive labels being off). No
		# via markers: vias only make sense alongside a live-authority stroke.
		# Stamped hints are legacy WAYPOINT hints by construction (station 12
		# only stamps those), so the flattened _waypoint_points polyline is
		# the correct — and only — corridor geometry they carry.
		var ghost_pts := _waypoint_points(annotation)
		if ghost_pts.size() >= 2:
			var ghost := Color(stroke_color.r, stroke_color.g, stroke_color.b,
				stroke_color.a * _SUPERSEDED_STROKE_DIM)
			ctx.draw_polyline(ghost_pts, ghost, stroke_px)
		if markers_on:
			_draw_endpoint_marker(ctx, pos, d, marker_color)
			_draw_superseded_slash(ctx, pos, d)
			var far_end: Variant = _far_endpoint(annotation)
			if far_end != null:
				_draw_endpoint_marker(ctx, far_end, d, marker_color)
				_draw_superseded_slash(ctx, far_end, d)
	else:
		# Intent render ("markers"): no polyline, no via markers — a live
		# candidate already owns that ink. Mark BOTH ends so a withheld polyline
		# doesn't read as a headless pin: the anchor, plus the hint's other known
		# endpoint (H1: dest_point / last waypoint / a legacy segments-bearing
		# hint's own far end — see _far_endpoint), when it has one.
		if markers_on:
			_draw_endpoint_marker(ctx, pos, d, marker_color)
			var far: Variant = _far_endpoint(annotation)
			if far != null:
				_draw_endpoint_marker(ctx, far, d, marker_color)

	# (No label — retired at HITL-6b, docket 019fdf553f: they rendered far
	# from their geometry, overlapped, and read as noise. "What's this?" is
	# the select/ask paradigm's job — minerva_pcb_get_selection carries the
	# summary the label used to truncate. The superseded state's on-canvas
	# cue is the marker slash alone.)


## Path-based hit-test: distance to any polyline segment (not the AABB), plus the
## marker disc around the anchor. threshold is in document (board-mm) units.
##
## INV-4: this is a HINT surface. It reads _waypoint_points, and that is correct
## HERE — see the fence in render(). A route CANDIDATE is never picked through
## this function: candidates are hit-tested by pcb_canvas._candidate_at against
## exact segment/via geometry, on the canvas's own selection ladder, with no
## waypoint read anywhere in that path.
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


## INV-4: a HINT bounds, waypoint-derived and correctly so (see hit_test above).
## A candidate's extent is derived from its exact segments/vias
## (pcb_canvas.candidate_draw_items), never from here.
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

	# Interior waypoints ONLY (contract §5) — deliberately NOT
	# _waypoint_points().size(): that helper prepends the anchor (and appends
	# the cached dest_point, when present) so the RENDERER draws the full
	# source→dest polyline. Reusing it here as a count over-reports by one (or
	# two): a 4-bend hint would read "5 waypoints" and a bend-free pad-to-pad
	# hint would read "1 waypoint" instead of omitting the count. The summary
	# counts what a human means by "waypoints" — the bends they placed, not
	# the endpoints — independently of how the polyline is rendered.
	var raw_waypoints: Variant = payload.get("waypoints", [])
	var wp_count: int = (raw_waypoints as Array).size() if raw_waypoints is Array else 0
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
##     proposal annotations — retired S5/C4b, DCR 019f7095c395; a pre-cutover
##     .pcbskel may still carry one until migration drops it): `waypoints`
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


## Draw a route's EXACT per-segment geometry (U2): each segment in ITS OWN
## layer's color (F.Cu magenta / B.Cu green, via _layer_color), so a layer
## change is visible as a color change along the stroke rather than a hidden
## joint in a single flattened-color polyline. AI strokes stay dashed
## (reuses _draw_dashed_polyline per-segment); human strokes solid.
func _draw_per_segment_polyline(ctx: AnnotationRenderContext, segments: Array, width_px: float, is_ai: bool) -> void:
	for seg in segments:
		if not (seg is Dictionary):
			continue
		var s: Dictionary = seg as Dictionary
		var a := _to_vec2(s.get("start", [0, 0]))
		var b := _to_vec2(s.get("end", [0, 0]))
		var color := _layer_color(str(s.get("layer", "F.Cu")))
		if is_ai:
			_draw_dashed_polyline(ctx, PackedVector2Array([a, b]), color, width_px)
		else:
			ctx.draw_line(a, b, color, width_px)


## Amber ring at a via position (document space), zoom-floored like the
## anchor diamond so it stays visible zoomed far out.
func _draw_via_marker(ctx: AnnotationRenderContext, pos: Vector2) -> void:
	var r := maxf(_VIA_MARKER_RADIUS_MM, _VIA_MARKER_MIN_PX / maxf(ctx.zoom, 0.001))
	var segs := 12
	var pts := PackedVector2Array()
	for i in range(segs):
		var ang := TAU * float(i) / float(segs)
		pts.append(pos + Vector2(cos(ang), sin(ang)) * r)
	var cols := PackedColorArray()
	cols.resize(segs)
	cols.fill(_COLOR_VIA)
	ctx.draw_polygon(pts, cols)


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
			# Inner copper gets a per-layer cycled color (epoch GA-1); anything
			# that is not a copper layer at all keeps the gray "other" bucket.
			# inner_index_any is the SILENT spelling-agnostic lookup — this runs
			# in a draw loop, where a warning per frame is a hang, not a hint.
			var k := _PcbLayerStack.inner_index_any(layer)
			if k > 0:
				return _INNER_HINT_PALETTE[(k - 1) % _INNER_HINT_PALETTE.size()]
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
	# Dict-shaped points (e.g. a via emitted as {x_mm,y_mm}) — parity with
	# panel_tools._via_position so a dict via renders at its real position, not
	# the origin. The worker emits [x,y] today; this keeps the marker correct
	# if a dict shape ever reaches the renderer.
	if raw is Dictionary:
		var d: Dictionary = raw as Dictionary
		if d.has("x_mm") and d.has("y_mm"):
			return Vector2(float(d["x_mm"]), float(d["y_mm"]))
		if d.has("x") and d.has("y"):
			return Vector2(float(d["x"]), float(d["y"]))
		if d.has("position"):
			return _to_vec2(d.get("position", []))
	return Vector2.ZERO


## ── INV-4 support (see the fence in render()) ─────────────────────────────────
## The keys by which a kind_payload declares itself the shadow of a RoutingWorkspace
## candidate. Nothing writes them today — the dual-write correlation is kept in the
## workspace itself (RoutingWorkspace.correlate), not on the annotation — and that
## is precisely why the guard exists NOW: the day a writer stamps one of these on a
## proposal envelope, the flattened waypoint fallback must already be closed to it
## rather than quietly rendering a candidate as a single-layer polyline.
const _CANDIDATE_SOURCE_KEYS := ["candidate_id", "workspace_candidate_id"]


## True iff this payload claims to be a route CANDIDATE rather than a route HINT.
static func _is_candidate_sourced(payload: Dictionary) -> bool:
	for key in _CANDIDATE_SOURCE_KEYS:
		if not str(payload.get(key, "")).is_empty():
			return true
	return false


## Which marker made _is_candidate_sourced true — named in the refusal so the
## warning identifies the offending payload instead of just complaining.
static func _candidate_marker_of(payload: Dictionary) -> String:
	for key in _CANDIDATE_SOURCE_KEYS:
		var value := str(payload.get(key, ""))
		if not value.is_empty():
			return "%s=%s" % [key, value]
	return "unknown"


static func _dist_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)
