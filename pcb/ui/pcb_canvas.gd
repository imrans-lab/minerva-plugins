extends Control
## Renders and edits the PCB board — components, traces, vias, ratsnest, grid.
##
## ── Off-tree port note (Round B) ──────────────────────────────────────────────
## Ported from Minerva src/Scripts/UI/Controls/PCBEditor/PCBCanvas.gd (3013 lines)
## for the pcb plugin panel. This plugin lives OUTSIDE Minerva's res:// tree, so:
##   * NO class_name (plugin-local class_names are unresolvable off-tree and
##     corrupt the parser cache).
##   * Siblings reached via relative preload(); cross-file object refs (data,
##     components, traces) are DUCK-TYPED (never typed as a plugin script — that
##     crosses files and breaks the cache; and untyped vars keep := inference
##     working only when the RHS type is annotatable, so primitives stay typed).
##
## ── STRIPPED vs legacy ────────────────────────────────────────────────────────
## ALL annotation + route-hint authoring/drawing/picking is removed: the platform
## annotation dock (mounted via PCBPanel.get_annotation_host()) owns that story
## now. Gone: AnnotationMode/RouteHintMode/BusPhase enums + state, _draw_annotation*,
## _draw_route_hint*, _draw_*_preview, _handle_annotation_click, _handle_route_hint_click,
## pin-picking (_get_pin_at_position), the A/T/R/H/M/W/P/Shift+P shortcuts, the
## annotation/route-hint context-menu items, capture_to_image (MCP export lives in
## the worker), and the spatial index (unused by interactive editing).
##
## ── KEPT (board editing) ──────────────────────────────────────────────────────
## Component select / box-select / drag / rotate, trace + via rendering, trace
## selection + delete, ratsnest, grid, pad geometry rendering, component lock,
## zoom / pan, tool modes (Select/Translate/Rotate), a per-copper-layer trace
## filter (the toolbar's layer selector drives trace_layer_filter).

const PCBComponentScript := preload("model/pcb_component.gd")
## T1.5: canonical layer contract (only _canonical_layer migrated here; layer
## filter/color/rendering internals are T3's territory and untouched).
const PcbLayerStack := preload("model/pcb_layer_stack.gd")
## Zone helpers (kind normalisation + outline decoding) are STATICS on the data
## script, so they are reached through the script rather than through the `data`
## instance. `data` is untyped here, so an instance call would resolve
## dynamically at every draw; and the two helpers are pure decoding of a zone
## dict, which belongs with the model that defines the dict's shape.
const PCBDataScript := preload("model/pcb_data.gd")

## Pad `type` values whose barrel goes THROUGH the board (plated and unplated).
## The one list: it gates the drill-hole render in _draw_component_pads AND the
## "this part still has lands on every copper layer" rule in _component_visibility.
const THT_PAD_TYPES: Array[String] = ["thru_hole", "np_thru_hole"]

## Signals
signal component_selected(component_id: String)
signal component_deselected(component_id: String)
signal component_moved(component_id: String, new_position: Vector2)
signal component_double_clicked(component_id: String)
@warning_ignore("unused_signal")
signal canvas_clicked(world_position: Vector2)
signal zoom_changed(new_zoom: float)
signal selection_changed()
signal component_lock_changed(message: String)
## Emitted whenever the board-mm↔screen mapping moves (pan, zoom, fit, center).
## PcbAnnotationHost relays this to its base view_changed so the annotation
## overlay re-renders route-hint markers at the new screen positions (gap W-9).
signal view_changed()
## WC-1 pin inspector (INSPECT_PIN mode). Emitted on a pin click with the host's
## pin_info() Dictionary, or {} to clear (click on empty space / mode switch /
## Escape). PCBPanel listens and drives the Pin Info section.
signal pin_selected(info: Dictionary)

## Data reference (pcb_data.gd instance — duck-typed).
var data = null

## View state
var zoom: float = 4.0  # Pixels per mm (4 = 1mm = 4px)
var pan_offset: Vector2 = Vector2.ZERO
var min_zoom: float = 0.5
var max_zoom: float = 50.0

## Display options
var show_grid: bool = true
var show_ratsnest: bool = true
var show_traces: bool = true
var show_labels: bool = true
## Route-hint/proposal summary labels (view flag). Setter relays to the
## annotation host so the pcb_route_hint kind can gate its label draw, then
## nudges the overlay via view_changed (owner req 2026-07-17: 16 proposals'
## labels are unreadable clutter without a toggle).
var show_hint_labels: bool = true:
	set(value):
		show_hint_labels = value
		if _pin_inspector_host != null and _pin_inspector_host.has_method("set_hint_labels_visible"):
			_pin_inspector_host.set_hint_labels_visible(value)
		view_changed.emit()
var show_pins: bool = true
var snap_to_grid: bool = true
var show_pads: bool = true
## Draws a warning badge on components rendered from FALLBACK pins rather than
## resolved footprint geometry (has_pad_geometry == false) — the visual mirror of
## the fab emitter failing closed on those same components (bug 019f7736b236 /
## hermetic-CAM Stage 2 step 4b). A badged component would NOT fabricate as-is.
## Mounting holes are exempt (they legitimately carry no pad geometry).
var show_unresolved_badges: bool = true
## Draws F.SilkS graphics resolved by the worker's footprint-RESOLVE step
## (component.graphics — see pcb_component.gd).
var show_silk: bool = true
## Draws F.CrtYd (courtyard) graphics from the same resolve step — the real
## module extent (also now what local_bounds is derived from, see
## pcb_component.gd _derive_bounds_from_graphics). Drawn dimmer/thinner than
## silk (courtyard_color/courtyard_min_width_px) so it reads as a reference
## outline, not a second body outline. Toggled from the panel's View menu
## (a _VIEW_FLAGS entry, like the other show_* flags here).
var show_courtyard: bool = true
## Draws authored zones — copper pours and keepouts (docket 019fb43113).
## Keepouts render as outline + diagonal hatch (a small warning region); pours
## render as OUTLINE ONLY — a whole-board pour's hatch buried every other layer
## in diagonal lines (owner HITL 2026-07-30), and the outline alone still says
## "a pour is authored here" without painting anything that reads as copper.
## Sibling of the show_* flags above so the panel's View menu can toggle it.
var show_zones: bool = true

## Copper-layer view filter driven by the toolbar layer selector. Holds "all" or
## a CANONICAL copper-layer id ("top" / "in1".."in30" / "bottom") — the selector
## shows KiCad names (F.Cu / In1.Cu / B.Cu) but carries the canonical id as item
## metadata, so nothing here has to parse a display string.
##
## "all" shows every layer; any other value scopes the view to THAT ONE layer —
## its traces, its zones, the components mounted on it, plus the through-hole
## lands of every part (a barrel pierces all copper). This is a whole-VIEW
## filter, not just a trace filter, since epoch 6 unit 3b.
## Setter emits view_changed so the annotation overlay re-renders — layer-keyed
## workflow annotations (route hints, WC-2 C3 fix 019f33d2c9bf) must appear /
## disappear with the same filter change that shows/hides the traces.
var trace_layer_filter: String = "all":
	set(value):
		if trace_layer_filter == value:
			return
		trace_layer_filter = value
		view_changed.emit()
		queue_redraw()

## ── SELECTION: ONE SET, THREE KINDS (item 019fb92f8b83) ───────────────────────
## The board selection is a single set that may span components, traces and
## zones at once. It is STORED as three id lists rather than one list of
## (kind, id) pairs because every consumer is already kind-specific — the draw
## loops ask "is this trace selected", the lock/rotate paths mean components,
## the panel's property inspector reads components — so a pair list would be
## unpacked back into these three at every use site.
##
## KIND_* below are the id strings that name the three lists in one place; every
## generic selection call takes one (see _selection_of / _entity_at). New kinds
## (vias, mounting holes) join by adding a constant, a list, and their cases in
## _selection_of / _entity_anchor / _capture_drag_origins / _apply_drag_delta.
const KIND_COMPONENT := "component"
const KIND_TRACE := "trace"
const KIND_ZONE := "zone"

var selected_components: Array[String] = []
var selected_trace_ids: Array[String] = []
var selected_zone_ids: Array[String] = []
var hovered_component: String = ""

## The component the user last CLICKED, when it is still selected — Illustrator's
## "key object" (A4 stage 2).
##
## Needed because selecting a group member selects the WHOLE group, so
## "the one component the user is working on" can no longer be inferred from a
## selection of size 1. The panel's offset editor asks this which member's offset
## to show; nothing about rendering, hit-testing or the selection set itself reads
## it. Cleared by _clear_selection, but NOT maintained on every removal path
## (shift-click toggle-out leaves it stale), so a consumer must re-validate
## against the live selection before trusting it — _property_focus_component does.
var focused_component: String = ""

## Interaction state
var is_panning: bool = false
var pan_start_mouse: Vector2 = Vector2.ZERO
var pan_start_offset: Vector2 = Vector2.ZERO

## Drag-move state. ONE gesture moves the WHOLE selection: the entity actually
## grabbed is the ANCHOR (it is what snaps to the grid), and every other selected
## entity is translated by the anchor's delta, so relative offsets survive
## snapping untouched.
##
## _drag_origins is the pre-drag geometry of every MOVABLE selected entity,
## captured once at press: {kind: {id: <Vector2 position | PackedVector2Array
## points>}}. Every motion frame re-applies `origin + delta` rather than nudging
## the live geometry, so snapping cannot accumulate drift and the release path has
## the true pre-drag state for the journal without a second snapshot.
var is_dragging_selection: bool = false
var _drag_anchor_start: Vector2 = Vector2.ZERO
var _drag_origins: Dictionary = {}
var drag_start_mouse: Vector2 = Vector2.ZERO

var is_box_selecting: bool = false
var box_select_start: Vector2 = Vector2.ZERO
var box_select_end: Vector2 = Vector2.ZERO

## Space-drag pan (Photoshop / GraphicsEditor style): while Space is held, a
## left-drag pans the whole view instead of selecting.
var _space_pan_armed: bool = false

## General tool mode. SELECT is the single smart tool (click selects, drag a
## part moves it snap-aware, drag empty space box-selects, R rotates the
## selection); PAN drags the whole view. TRANSLATE/ROTATE are kept for
## back-compat with the tool_mode_changed contract but are no longer distinct
## toolbar tools — the smart SELECT tool subsumes both (finding 5). INSPECT_PIN
## (WC-1) is the pin inspector: hover labels the nearest pad, click selects it
## (pin_selected), click empty clears, Escape/mode-switch clears + exits.
## Appended at the END so existing ToolMode-by-int callers (status bar mode
## names) never renumber. ZONE_POUR / ZONE_KEEPOUT (epoch 6 unit 4) are the zone
## drawing tools — click per vertex, double-click or Enter closes, Esc/right-click
## cancels; they AUTHOR board entities (unlike the hint tools, which author
## annotations), so they belong on this surface rather than the overlay's. TRACE
## (epoch 6 unit 5) is the same family for copper: click a pad, click waypoints,
## click a pad to finish. It is NOT the Hints-group trace tool — that one authors
## a route HINT for the router; this one authors the Trace entity itself. ERASER
## (item 019fb934827776) owns clicks the same way: each click deletes exactly the
## entity it hits (same pick _entity_at gives the Select tool), journalled as its
## OWN undo step (see _handle_eraser_click) — not the trash-can's batch. Clicking
## empty space, or a locked component/trace, deletes nothing and the tool STAYS
## ARMED (owner ruling); no drag-sweep deletion in v1.
enum ToolMode { NONE, SELECT, TRANSLATE, ROTATE, PAN, INSPECT_PIN, ZONE_POUR, ZONE_KEEPOUT, TRACE, ERASER }
var tool_mode: ToolMode = ToolMode.NONE
signal tool_mode_changed(mode: ToolMode)
## Transient user-facing feedback from the zone tools ("pick a net", "needs 3
## points", "zone added"). The panel routes it to the status bar. A separate
## signal from component_lock_changed so neither channel has to pretend to be the
## other.
signal zone_tool_message(text: String)
## The trace tool's twin of the above ("start on a pad", "trace added", the
## different-net warning). A separate signal for the same reason zone_tool_message
## is separate from component_lock_changed — one channel per tool, all routed to
## the panel's single transient-status sink, so no channel has to pretend to be
## another's.
signal trace_tool_message(text: String)

## Duck-typed back-reference to the PcbAnnotationHost (set by PCBPanel), the
## SOLE source of pad/pin hit-test logic (host.pad_at / host.pin_info) — the
## canvas does no hit-testing of its own, only rendering + input plumbing.
var _pin_inspector_host = null

## Hover state for the INSPECT_PIN nearest-pad label (native L1444 parity).
var _inspect_hover_label: String = ""
var _inspect_hover_screen_pos: Vector2 = Vector2.ZERO

## Trace / zone selection, SINGLE-PICK VIEW of the multi-set above.
##
## Both were plain single-id fields before mixed multi-select (019fb92f8b83).
## They are kept as computed properties over selected_trace_ids /
## selected_zone_ids so the pre-existing single-entity grammar keeps working
## verbatim: reading gives the first pick (or ""), and ASSIGNING replaces that
## kind's selection with the one id — which is exactly what `selected_zone_id =
## "zone:x"` and `selected_trace_id = ""` meant before. Nothing outside this file
## has to learn the new shape to keep behaving.
##
## Zone selection came in with docket 019fb5d9083a (delete slice): selection +
## Delete only — vertex editing and re-property stay with the parent item.
var selected_trace_id: String:
	get:
		return "" if selected_trace_ids.is_empty() else selected_trace_ids[0]
	set(value):
		selected_trace_ids.clear()
		if not value.is_empty():
			selected_trace_ids.append(value)

var selected_zone_id: String:
	get:
		return "" if selected_zone_ids.is_empty() else selected_zone_ids[0]
	set(value):
		selected_zone_ids.clear()
		if not value.is_empty():
			selected_zone_ids.append(value)

## ── Zone authoring (epoch 6 unit 4) ───────────────────────────────────────────
## The net a POUR is armed with, set by the panel's zone net picker. Empty means
## "not armed": a pour commit fails closed with a visible message rather than
## guessing a net.
##
## A KEEPOUT ignores this — it needs no net (owner boundary ruling 2026-07-30,
## docket 019fb5ad6d20: "Keepouts don't need net connections"; Go's validateZones
## and pcb_data.zone_author_error branch the same way, so a netless keepout
## validates and pcb.serialize's whole-board gate accepts it). The panel HIDES the
## net picker while the Keepout tool is armed, so this simply stays at whatever
## the last pour left here and the keepout commit passes "" regardless.
var zone_author_net: String = ""
## The copper layer a zone is armed to, set by the panel's zone layer picker.
## Empty — the resting state, the picker's "View layer" entry — means "follow the
## toolbar layer filter", which is exactly what the tools did before this control
## existed, so the default behaviour is unchanged. A canonical id ("top"/"in1"/
## "bottom") overrides the filter; see zone_author_layer.
var zone_layer_override: String = ""
## Default pour layer when the toolbar's layer filter is "all" — the classic
## ground-pour side. Surfaced as a constant so the panel's tooltip and the commit
## path name the SAME layer.
const ZONE_DEFAULT_LAYER := "bottom"
## Vertices placed so far, in board mm. Empty ⇔ no draw in progress.
var _zone_points: PackedVector2Array = PackedVector2Array()
## Live rubber-band vertex (the cursor), only meaningful while drawing.
var _zone_preview: Vector2 = Vector2.ZERO
var _zone_has_preview: bool = false
## Alpha for the not-yet-committed closing edge, so an in-progress polygon reads
## as open at the cursor and merely "about to close" at the origin.
const ZONE_PREVIEW_CLOSE_ALPHA := 0.35
const ZONE_PREVIEW_VERTEX_RADIUS_PX := 3.0

## ── Trace authoring (epoch 6 unit 5) ──────────────────────────────────────────
## Default copper layer when the toolbar's layer filter is "all". TOP, unlike the
## zone tools' "bottom": a pour under "All" wants the classic ground-pour side,
## while signal routing starts on the component side. Surfaced as a constant so
## the panel's tooltip and the commit path name the SAME layer.
const TRACE_DEFAULT_LAYER := "top"
## Pad capture radius for the trace tool, in board mm.
##
## DELIBERATELY TIGHTER than the pin inspector's 5 mm default (PcbAnnotationHost.
## pad_at's own default, contract §2). The inspector's hit is a READ — "tell me
## about the nearest pad" — where generosity costs nothing. Here a pad hit
## CONSUMES the click and ends the gesture, so a 5 mm radius would make it
## impossible to place a waypoint anywhere near a component. 1.27 mm is half a
## 0.1" pitch: inside it, the nearest pad is unambiguously the pad clicked.
const TRACE_PAD_SNAP_MM := 1.27
## Width in mm the trace tool is armed to, set by the panel's width box. 0.0 —
## the resting state — means "use the board's design rule"
## (pcb_data.authored_trace_width), which is what the tool did before this control
## existed, so the default behaviour is unchanged. See trace_author_width.
var trace_width_override: float = 0.0
## Waypoints placed so far, in board mm. Empty ⇔ no draw in progress.
var _trace_points: PackedVector2Array = PackedVector2Array()
## Arming snapshot, frozen when the FIRST pad is clicked and held for the whole
## draw. The net is inherited from that pad (KiCad-style — copper does not get to
## invent a net), and the layer is frozen alongside it rather than re-resolved at
## commit: the preview is drawn in that layer's trace colour at its real width, so
## changing the layer filter mid-draw must not silently commit a different trace
## from the one on screen.
var _trace_net: String = ""
var _trace_layer: String = ""
## "U1.22" — the starting pad, for the preview label and the commit message.
var _trace_start_ref: String = ""
## Live rubber-band point (the cursor), only meaningful while drawing.
var _trace_preview: Vector2 = Vector2.ZERO
var _trace_has_preview: bool = false
## Alpha for the not-yet-placed segment running to the cursor, so the committed
## polyline reads as drawn and the rubber band reads as proposed.
const TRACE_PREVIEW_RUBBER_ALPHA := 0.45
const TRACE_PREVIEW_VERTEX_RADIUS_PX := 3.0

## Colors
var board_color: Color = Color(0.15, 0.25, 0.15, 1.0)
var board_edge_color: Color = Color(0.4, 0.4, 0.4, 1.0)
var grid_color: Color = Color(0.25, 0.35, 0.25, 0.5)
var grid_major_color: Color = Color(0.3, 0.4, 0.3, 0.7)
var component_color: Color = Color(0.2, 0.6, 0.3, 1.0)
var component_selected_color: Color = Color(0.3, 0.8, 0.4, 1.0)
var component_hover_color: Color = Color(0.25, 0.7, 0.35, 1.0)
var pin_color: Color = Color(0.9, 0.75, 0.3, 1.0)
var label_color: Color = Color.WHITE
var trace_top_color: Color = Color(0.9, 0.3, 0.3, 1.0)   # Red for top layer (F.Cu)
var trace_bottom_color: Color = Color(0.3, 0.5, 0.9, 1.0) # Blue for bottom layer (B.Cu)
var trace_selected_color: Color = Color(1.0, 1.0, 0.3, 1.0)
var selection_box_color: Color = Color(0.3, 0.5, 0.8, 0.3)
var selection_border_color: Color = Color(0.4, 0.6, 0.9, 1.0)

## Pad colors (copper/solder appearance)
var pad_copper_color: Color = Color(0.85, 0.65, 0.3, 1.0)  # Copper/gold for THT
var pad_smd_color: Color = Color(0.75, 0.55, 0.25, 1.0)    # SMD pads
var drill_hole_color: Color = Color(0.08, 0.08, 0.08, 1.0) # Drill holes (match background)
var mounting_hole_color: Color = Color(0.2, 0.2, 0.2, 1.0) # Non-plated holes
## Amber warning badge for unresolved-footprint components (see show_unresolved_badges)
var unresolved_badge_color: Color = Color(0.95, 0.65, 0.1, 1.0)
## Warning-triangle half-height in screen px (constant across zoom) + its offset
## outside the component's top-right bbox corner. Bumped from 7 so the badge reads
## clearly (owner HITL 2026-07-19).
const UNRESOLVED_BADGE_SIZE := 11.0
const UNRESOLVED_BADGE_MARGIN := 3.0

## Silkscreen (F.SilkS) stroke color — light/white, matching real silk ink.
var silk_color: Color = Color(0.9, 0.9, 0.9, 1.0)
var silk_min_width_px: float = 1.0

## Courtyard (F.CrtYd) stroke — same ink family as silk but dimmed to ~40%
## alpha and drawn thinner, so it reads as a reference outline rather than
## competing with the silk body outline. Godot's draw_line/draw_polyline have
## no dash support, so "visually distinct" here means dimmer+thinner, not
## dashed.
var courtyard_color: Color = Color(0.9, 0.9, 0.9, 0.4)
var courtyard_min_width_px: float = 0.75

## Zones (docket 019fb43113). A keepout is a WARNING region — "no copper here" —
## so it gets its own amber-red, deliberately outside the copper palette
## (trace_top/bottom, pad_copper, net colours) rather than a member of it: a
## keepout is not copper and must never read as copper. A copper pour DOES take
## its net's colour (falling back to this muted copper-green when the net is
## unknown), so a GND pour reads as the same net as the GND traces.
##
## Both are drawn HATCHED and never filled. That is not decoration: the contract
## models the AUTHORED OUTLINE only (internal/board Zone), the actual filled
## copper is compiler work that does not exist yet, and the fab paths still
## refuse a board with zones outright. A solid fill would draw copper nobody has
## computed. Hatch is the honest rendering of "declared, not yet filled".
var zone_keepout_color: Color = Color(0.95, 0.45, 0.15, 1.0)
var zone_pour_fallback_color: Color = Color(0.45, 0.7, 0.5, 1.0)
var zone_outline_alpha: float = 0.85
var zone_hatch_alpha: float = 0.42
var zone_outline_width_px: float = 1.5
var zone_hatch_width_px: float = 1.0

## Hatch pitch is authored in BOARD MM so the hatch scales with the artwork the
## way copper does, then CLAMPED IN SCREEN PIXELS: below the floor a zoomed-out
## pour degenerates into a solid block of overdraw (and stops reading as
## hatched), above the ceiling a zoomed-in zone shows one or two stray lines and
## stops reading as a region at all.
const ZONE_HATCH_PITCH_MM := 1.6
const ZONE_HATCH_MIN_PX := 7.0
const ZONE_HATCH_MAX_PX := 26.0
## Hard ceiling on hatch lines per zone per frame. The pitch clamp plus the
## viewport-range clip below already bound this in every realistic view; this is
## the backstop that keeps a pathological board (a zone spanning metres) from
## turning one _draw() into an unbounded loop.
const ZONE_HATCH_MAX_LINES := 2000

## Font
var font: Font
var font_size: int = 12

## Context menu (component lock/unlock only — annotation/route-hint items stripped)
var context_menu: PopupMenu = null
var context_menu_world_pos: Vector2 = Vector2.ZERO
var right_click_start_pos: Vector2 = Vector2.ZERO
const RIGHT_CLICK_THRESHOLD := 5.0  # Pixels — below this a right-click is a tap → context menu


func _enter_tree() -> void:
	# Input config MUST be re-applied on every tree entry, not just once in
	# _ready. The editor reparents this panel into the annotation content row
	# AFTER mount (Editor._ensure_annotation_content_row); a reparent fires
	# _exit_tree then _enter_tree but NOT _ready. If mouse_filter is only set in
	# _ready it is left on IGNORE after the reparent and the canvas silently
	# swallows every mouse+keyboard event (draws fine, but zoom/pan/select all
	# dead — bug 019f39164c2e; the toolbar survives because Buttons don't
	# self-clear their filter on exit). Setting it here makes it reparent-safe.
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	clip_contents = true


func _ready() -> void:
	font = ThemeDB.fallback_font
	font_size = ThemeDB.fallback_font_size

	_create_context_menu()


func _exit_tree() -> void:
	if has_focus():
		release_focus()
	# NOTE: do NOT set mouse_filter = IGNORE here. This node is reparented (not
	# just freed) when the annotation dock mounts; leaving it IGNORE would make
	# the re-added canvas ignore all input. _enter_tree restores STOP on re-add.
	is_panning = false
	is_dragging_selection = false
	_drag_origins = {}
	is_box_selecting = false


## Create the right-click context menu (component lock/unlock).
func _create_context_menu() -> void:
	context_menu = PopupMenu.new()
	context_menu.name = "ContextMenu"
	add_child(context_menu)
	context_menu.id_pressed.connect(_on_context_menu_pressed)


## Rebuild the dynamic (lock) items of the context menu for the current cursor.
func _update_context_menu_for_selection() -> void:
	context_menu.clear()

	var has_lock_section := false
	var comp_under_cursor: String = _component_at(context_menu_world_pos)
	if not comp_under_cursor.is_empty() or not selected_components.is_empty():
		has_lock_section = true
		if not comp_under_cursor.is_empty():
			context_menu.add_item("Lock %s (L)" % comp_under_cursor, 401)
		else:
			context_menu.add_item("Lock Component (L)", 401)

	var locked_under_cursor := _get_locked_component_at(context_menu_world_pos)
	if not locked_under_cursor.is_empty():
		has_lock_section = true
		context_menu.add_item("Unlock %s" % locked_under_cursor, 402)

	if _has_any_locked_components():
		context_menu.add_item("Unlock All Components (Shift+L)", 404)

	# Group / Ungroup (A4). Each item appears ONLY when it would do something —
	# the same conditions _group_selection / _ungroup_selection themselves refuse
	# on — so a board with no groups and a single-part selection sees neither and
	# the menu is exactly what it was before groups existed.
	var can_group := selected_components.size() >= 2 and not _selection_is_one_group()
	var can_ungroup := _selection_has_group()
	if can_group or can_ungroup:
		if context_menu.item_count > 0:
			context_menu.add_separator()
		if can_group:
			context_menu.add_item("Group Selection (Ctrl+G)", 411)
		if can_ungroup:
			context_menu.add_item("Ungroup (Ctrl+Shift+G)", 412)

	if not has_lock_section and context_menu.item_count == 0:
		context_menu.add_item("(no actions)", 0)
		context_menu.set_item_disabled(context_menu.item_count - 1, true)


func _on_context_menu_pressed(id: int) -> void:
	if not data:
		return
	match id:
		401:  # Lock component(s) — selected ones, or the one under cursor
			if not selected_components.is_empty():
				_lock_selected_components()
			else:
				var cursor_comp_id: String = _component_at(context_menu_world_pos)
				if not cursor_comp_id.is_empty():
					var cursor_comp = data.get_component(cursor_comp_id)
					if cursor_comp:
						cursor_comp.locked = true
						component_lock_changed.emit("Locked %s" % cursor_comp_id)
						queue_redraw()
		402:  # Unlock the locked component under cursor
			var comp_id := _get_locked_component_at(context_menu_world_pos)
			if not comp_id.is_empty():
				var comp = data.get_component(comp_id)
				if comp:
					comp.locked = false
					component_lock_changed.emit("Unlocked %s" % comp_id)
					queue_redraw()
		404:  # Unlock all components
			_unlock_all_components()
		411:  # Group the selected components (A4)
			_group_selection()
		412:  # Dissolve the selection's group(s) (A4)
			_ungroup_selection()


func _show_context_menu(screen_pos: Vector2) -> void:
	if not context_menu:
		return
	_update_context_menu_for_selection()
	var global_pos := get_global_transform() * screen_pos
	context_menu.position = Vector2i(global_pos)
	context_menu.popup()


func _draw() -> void:
	if not data:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.1, 0.1, 0.1))
		return

	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.08, 0.08))

	_draw_board()

	if show_grid:
		_draw_grid()

	_draw_components()

	_draw_mounting_holes()

	# Zones sit ABOVE components and BELOW traces. Above components because the
	# whole point of the antenna keepout is that it overlaps U1's body — drawn
	# underneath, the component fill would hide exactly the region being warned
	# about. Below traces because a trace is routed copper and must stay the most
	# legible thing on the canvas — pours are outline-only and the keepout's
	# hatch is sparse enough to read through.
	if show_zones:
		_draw_zones()

	# The polygon being drawn sits with the committed zones (same layer of the
	# stack, same visual language) — but is NOT gated on show_zones: hiding
	# authored zones must not blank out the one the user is drawing right now.
	if _is_zone_tool():
		_draw_zone_preview()

	if show_traces:
		_draw_traces()

	# The trace being drawn sits with the committed copper (same visual language,
	# same place in the stack) — and, like the zone preview above, is NOT gated on
	# show_traces: hiding authored copper must not blank out the trace the user is
	# drawing right now.
	if tool_mode == ToolMode.TRACE:
		_draw_trace_preview()

	if show_ratsnest:
		_draw_ratsnest()

	if is_box_selecting:
		_draw_selection_box()

	if tool_mode == ToolMode.INSPECT_PIN and not _inspect_hover_label.is_empty():
		_draw_inspect_hover_label()


## Draw the PCB board outline
func _draw_board() -> void:
	var board_rect := Rect2(
		world_to_screen(Vector2.ZERO),
		Vector2(data.board_width, data.board_height) * zoom
	)
	draw_rect(board_rect, board_color)
	draw_rect(board_rect, board_edge_color, false, 2.0)


## Draw the alignment grid
func _draw_grid() -> void:
	var board_start := world_to_screen(Vector2.ZERO)
	var board_end := world_to_screen(Vector2(data.board_width, data.board_height))

	var grid_step: float = data.grid_size * zoom
	var major_interval := 10

	if grid_step < 3:
		return

	var start_x := board_start.x
	var end_x := board_end.x
	var start_y := board_start.y
	var end_y := board_end.y

	var x := start_x
	var line_count := 0
	while x <= end_x:
		var color := grid_major_color if line_count % major_interval == 0 else grid_color
		draw_line(Vector2(x, start_y), Vector2(x, end_y), color, 1.0)
		x += grid_step
		line_count += 1

	var y := start_y
	line_count = 0
	while y <= end_y:
		var color := grid_major_color if line_count % major_interval == 0 else grid_color
		draw_line(Vector2(start_x, y), Vector2(end_x, y), color, 1.0)
		y += grid_step
		line_count += 1


## Is geometry on the CANONICAL layer `layer` visible under the current filter?
##
## Epoch 6 unit 3b: canonical-name EQUALITY, replacing the old binary match that
## read "top" as "anything that is not bottom". That binary shape was wrong two
## ways: it made every inner layer render as top copper, and it is why a bottom
## view still drew top-only parts (child bug 019fb55dc7f5).
##
## `layer` must already be canonical — this is a draw-loop predicate, and the
## contract's normaliser push_warning()s on an oddball name, so normalising here
## would spray the log once per trace per frame. Callers holding an untrusted or
## KiCad-named layer normalise ONCE, outside the loop (see is_layer_visible and
## _draw_zone). An unrecognised name simply matches nothing but "all" — the
## fail-visible outcome, not a silent "always draw".
func _layer_visible(layer: String) -> bool:
	# "" is treated as "all" so a canvas whose filter was cleared rather than set
	# renders the whole board instead of going blank.
	if trace_layer_filter.is_empty() or trace_layer_filter == "all":
		return true
	return layer == trace_layer_filter


## PUBLIC layer-visibility probe for the annotation substrate (WC-2 C3 fix
## 019f33d2c9bf). PcbAnnotationHost.is_annotation_visible consults this so
## layer-keyed route hints follow the same filter as the traces. Accepts both
## the canvas's canonical layer ids ("top"/"in<k>"/"bottom") and the KiCAD copper
## names route-hint payloads carry ("F.Cu"/"In1.Cu"/"B.Cu").
func is_layer_visible(layer: String) -> bool:
	return _layer_visible(_canonical_layer(layer))


static func _canonical_layer(layer: String) -> String:
	# T1.5: delegates to the ONE canonical GD contract. The public probe above is
	# the normalisation boundary — everything past it compares canonical ids by
	# equality, so this is where an "F.Cu"/"B.Cu"/"In1.Cu" payload name (or a
	# stray capital) becomes something _layer_visible can match. kicad_to_canon
	# fails VISIBLE by design: an unknown name passes through lower-cased with a
	# warning rather than being silently defaulted onto a real layer.
	return PcbLayerStack.kicad_to_canon(layer)


## Navigation events relayed from the platform AnnotationOverlay while an
## annotation tool is active (WC-2 §1a — the overlay claims only LEFT/RIGHT
## for tools and forwards middle-button / wheel / pan-gesture / middle-drag
## motion here via PcbAnnotationHost.forward_navigation_input). The overlay
## shares the canvas origin, so event positions are already canvas-local;
## routing through the normal handlers gives identical pan/zoom behavior.
func handle_navigation_input(event: InputEvent) -> void:
	if not is_inside_tree() or not data:
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventPanGesture:
		_handle_pan_gesture(event)
	elif event is InputEventMagnifyGesture:
		_handle_magnify_gesture(event)


## The board's DECLARED copper stack, top-most entry first. Declared order IS
## stack order — the board validator enforces that (epoch 6 unit 3a: Go
## validateLayers / board_validate._check_layers, error invalid_layer_stack_order),
## so this reads the order rather than re-deriving one. Falls back to the 2-layer
## default when a board declares none (the same fallback pcb_data uses on load).
func _stack_layers() -> Array:
	if data != null and data.layers is Array and not data.layers.is_empty():
		return data.layers
	return ["top", "bottom"]


## Draw all traces (bottom-most copper first, top-most copper last, then vias),
## honoring the layer filter.
##
## Epoch 6 unit 3b: walks the board's declared stack instead of the two hardcoded
## "bottom" / "everything-else" passes, so an inner layer paints in ITS stack
## position and only when it (or "all") is selected. For the 2-layer stack this
## produces exactly the old order — bottom, then top.
func _draw_traces() -> void:
	# Bucket by layer ONCE: the stack walk below is then one pass over the board
	# rather than one full pass per declared layer.
	var by_layer := {}
	for trace_id in data.traces:
		var trace = data.traces[trace_id]
		var lid := str(trace.layer)
		if not by_layer.has(lid):
			by_layer[lid] = []
		by_layer[lid].append(trace)

	# Backwards through the declared stack: bottom-most copper paints first so
	# the top-most copper lands on top of it.
	var stack: Array = _stack_layers()
	for i in range(stack.size() - 1, -1, -1):
		var layer_id := str(stack[i])
		if not by_layer.has(layer_id):
			continue
		if _layer_visible(layer_id):
			for trace in by_layer[layer_id]:
				_draw_single_trace(trace, layer_id)
		by_layer.erase(layer_id)

	# Traces on a layer the board never declared (an out-of-stack or malformed
	# layer name). They are DRAWN, not dropped — hiding copper that exists would
	# be the silent failure — but last, above the declared stack, and still gated
	# by the filter. Under "all" this is exactly the pre-3b rendering.
	for undeclared_id in by_layer:
		if not _layer_visible(undeclared_id):
			continue
		for undeclared_trace in by_layer[undeclared_id]:
			_draw_single_trace(undeclared_trace, str(undeclared_id))

	# Vias (on top of all traces).
	for via in data.vias:
		var pos_data = via.get("position", Vector2.ZERO)
		var pos: Vector2
		if pos_data is Vector2:
			pos = world_to_screen(pos_data)
		elif pos_data is Dictionary:
			pos = world_to_screen(Vector2(pos_data.get("x", 0), pos_data.get("y", 0)))
		else:
			continue

		var outer_radius: float = (via.get("size", 0.8) / 2.0) * zoom
		var inner_radius: float = (via.get("drill", 0.4) / 2.0) * zoom

		var color := pad_copper_color
		var net = data.get_net(via.get("net_name", ""))
		if net:
			color = net.color

		draw_circle(pos, maxf(outer_radius, 2.0), color)
		draw_circle(pos, maxf(inner_radius, 1.0), drill_hole_color)


## Distinct hues for in1..in30 traces (work item 019fb59c2d17), cycled by stack
## number. Deliberately far from the top red / bottom blue and from each other
## at adjacent indices, so neighbouring inner layers never read as one layer.
const _INNER_TRACE_PALETTE: Array[Color] = [
	Color(0.85, 0.75, 0.2),   # in1  gold
	Color(0.75, 0.3, 0.85),   # in2  purple
	Color(0.25, 0.8, 0.65),   # in3  teal
	Color(0.9, 0.55, 0.25),   # in4  orange
	Color(0.55, 0.8, 0.3),    # in5  green
	Color(0.85, 0.4, 0.55),   # in6  rose
]


## Trace colour for a copper layer id: top and bottom keep their themeable
## vars; an inner layer draws from the fixed palette above. An undeclared or
## malformed layer name falls to the top colour, exactly as before the palette
## existed — colour is presentation, so this path stays permissive while the
## draw loop keeps the trace visible.
func _trace_layer_color(layer_id: String) -> Color:
	if layer_id == "bottom":
		return trace_bottom_color
	var k := PcbLayerStack.inner_layer_index(layer_id)
	if k > 0:
		return _INNER_TRACE_PALETTE[(k - 1) % _INNER_TRACE_PALETTE.size()]
	return trace_top_color


## Draw a single trace with layer-appropriate styling — colour comes from
## _trace_layer_color, so inner layers no longer borrow the top colour.
func _draw_single_trace(trace, layer_id: String) -> void:
	if trace.waypoints.size() < 2:
		return

	var color := _trace_layer_color(layer_id)
	var is_selected: bool = trace.id in selected_trace_ids

	if is_selected:
		color = trace_selected_color

	var points: PackedVector2Array = []
	for wp in trace.waypoints:
		points.append(world_to_screen(wp))

	if points.size() >= 2:
		var trace_width = trace.width * zoom

		if is_selected:
			var glow_color := Color(trace_selected_color, 0.25)
			draw_polyline(points, glow_color, maxf(trace_width + 6.0, 4.0))

		draw_polyline(points, color, maxf(trace_width, 1.0))

		if is_selected:
			for pt in points:
				draw_circle(pt, 3.0, trace_selected_color)


## Draw every authored zone — pours as closed outlines, keepouts as outline +
## hatch (see the show_zones note for why pours do not hatch). Never filled.
##
## Two passes so KEEPOUTS ALWAYS LAND ON TOP of pours, regardless of the order
## the board file happened to list them in: a keepout is a constraint on the
## pour, and its warning render must not sit under pour geometry.
func _draw_zones() -> void:
	if data.zones.is_empty():
		return
	for zone in data.zones:
		if not _is_keepout_zone(zone):
			_draw_zone(zone, false)
	for zone in data.zones:
		if _is_keepout_zone(zone):
			_draw_zone(zone, true)


func _is_keepout_zone(zone: Dictionary) -> bool:
	return PCBDataScript.zone_kind(zone) == "keepout"


## Draw one zone. `is_keepout` is passed in rather than re-derived so the two
## passes above and the colour choice here cannot disagree about a zone's kind.
func _draw_zone(zone: Dictionary, is_keepout: bool) -> void:
	# Layer filter: MIRRORS traces exactly — same _layer_visible() predicate, so
	# selecting "bottom" in the toolbar hides the top-layer keepout alongside the
	# top-layer traces and leaves the bottom-layer GND pour visible. Zone layer
	# names arrive canonical ("top"/"bottom") from the board contract, but they
	# are pushed through the shared kicad_to_canon mapping anyway so a zone
	# carrying an F.Cu/B.Cu name (or a stray capital) filters correctly instead
	# of falling through to "always visible".
	if not _layer_visible(PcbLayerStack.kicad_to_canon(str(zone.get("layer", "")))):
		return

	var world_pts := PCBDataScript.zone_outline_points(zone)
	if world_pts.size() < 3:
		return

	var screen_poly := PackedVector2Array()
	for p in world_pts:
		screen_poly.append(world_to_screen(p))

	var color := zone_keepout_color
	if not is_keepout:
		color = zone_pour_fallback_color
		var net = data.get_net(str(zone.get("net", "")))
		if net:
			color = net.color

	# ONLY keepouts hatch. A pour outline can legitimately span the whole board
	# (the smart-remote GND pour is the full 80x110 minus 0.5mm), and hatching it
	# covered every layer in diagonal lines — owner HITL 2026-07-30 ordered the
	# lines removed. The pour keeps its closed outline; honest-unfilled now reads
	# as "outlined, no copper drawn" rather than "hatched".
	if is_keepout:
		var pitch: float = clampf(ZONE_HATCH_PITCH_MM * zoom, ZONE_HATCH_MIN_PX, ZONE_HATCH_MAX_PX)
		_draw_polygon_hatch(screen_poly, Color(color, zone_hatch_alpha), pitch, zone_hatch_width_px, true)

	var outline := screen_poly.duplicate()
	outline.append(screen_poly[0])  # close the loop — an outline, not a polyline
	var is_selected: bool = str(zone.get("id", "")) in selected_zone_ids
	if is_selected:
		# Same selection colour + emphasis the trace pick uses, so "selected"
		# reads identically across board entities.
		draw_polyline(outline, trace_selected_color, zone_outline_width_px * 2.0)
	else:
		draw_polyline(outline, Color(color, zone_outline_alpha), zone_outline_width_px)


## Hatch a screen-space polygon with parallel diagonal lines, CLIPPED TO THE
## POLYGON (not to its bounding box — unlike _draw_locked_hatch, which only ever
## sees axis-aligned component rectangles where the two coincide; a zone outline
## is an arbitrary polygon and a bounding-box hatch would paint copper-clear
## regions as hatched).
##
## Method: the hatch family is the level sets of f(p) = p.x + p.y (or p.x - p.y
## when `mirrored`), which are lines at ±45°. For each level c, intersect with
## every polygon edge, sort the hits along the line, and stroke them in pairs —
## the standard even-odd scanline fill, run on a diagonal axis. Correct for
## concave outlines, not just convex ones.
func _draw_polygon_hatch(poly: PackedVector2Array, color: Color, pitch: float, width: float, mirrored: bool) -> void:
	if poly.size() < 3 or pitch <= 0.0:
		return

	var f_min := INF
	var f_max := -INF
	for p in poly:
		var f: float = (p.x - p.y) if mirrored else (p.x + p.y)
		f_min = minf(f_min, f)
		f_max = maxf(f_max, f)
	if not is_finite(f_min) or not is_finite(f_max):
		return

	# Clip the level range to what the viewport can actually show. A full-board
	# pour zoomed in is mostly off-screen; without this we would compute and
	# stroke thousands of lines nobody sees, every frame.
	var view_f_min := INF
	var view_f_max := -INF
	for corner: Vector2 in [Vector2.ZERO, Vector2(size.x, 0.0), Vector2(0.0, size.y), size]:
		var vf: float = (corner.x - corner.y) if mirrored else (corner.x + corner.y)
		view_f_min = minf(view_f_min, vf)
		view_f_max = maxf(view_f_max, vf)
	f_min = maxf(f_min, view_f_min)
	f_max = minf(f_max, view_f_max)
	if f_max <= f_min:
		return

	# Snap the first level to a multiple of the pitch in the level coordinate, so
	# the hatch is anchored to the geometry rather than to the zone's own bounds.
	# Neighbouring zones then share one continuous hatch grid instead of each
	# starting its own phase, and panning does not make the lines crawl.
	var c: float = ceilf(f_min / pitch) * pitch
	var lines := 0
	var hits: Array[Vector2] = []
	while c <= f_max and lines < ZONE_HATCH_MAX_LINES:
		lines += 1
		hits.clear()
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			var fa: float = (a.x - a.y) if mirrored else (a.x + a.y)
			var fb: float = (b.x - b.y) if mirrored else (b.x + b.y)
			if is_equal_approx(fa, fb):
				continue  # edge parallel to the hatch: contributes no crossing
			# Half-open on [min, max) — NOT on the edge's own direction. When a
			# hatch level lands exactly on a vertex, the edge-directional form
			# ("include t=0, exclude t=1") counts a local MAXIMUM vertex once
			# instead of zero times, flipping the even-odd parity and inverting
			# the fill for the rest of that line. Keying the half-open interval
			# to min/max makes the two edges meeting at a vertex agree: a
			# crossing vertex counts once, a touching vertex counts zero or two.
			# (Caught numerically on a concave outline before this shipped.)
			if c < minf(fa, fb) or c >= maxf(fa, fb):
				continue
			hits.append(a.lerp(b, (c - fa) / (fb - fa)))
		if hits.size() >= 2:
			# x increases monotonically along both hatch directions, so it is a
			# valid ordering parameter for either family.
			hits.sort_custom(func(u: Vector2, v: Vector2) -> bool: return u.x < v.x)
			var j := 0
			while j + 1 < hits.size():
				draw_line(hits[j], hits[j + 1], color, width)
				j += 2
		c += pitch


## Draw ratsnest (unrouted net connections)
func _draw_ratsnest() -> void:
	for net_name in data.nets:
		var net = data.nets[net_name]
		if net.pins.size() < 2:
			continue

		var pin_data: Array = []
		for pin in net.pins:
			var comp_id: String = pin.get("component_id", "")
			var pin_name: String = pin.get("pin_name", "")
			var comp = data.get_component(comp_id)
			if comp:
				pin_data.append({
					"pos": comp.get_pin_world_position(pin_name),
					"comp_id": comp_id,
					"pin_name": pin_name
				})

		if pin_data.size() >= 2:
			var net_color = net.color
			net_color.a = 0.6

			for i in range(pin_data.size() - 1):
				var p1 := world_to_screen(pin_data[i]["pos"])
				var p2 := world_to_screen(pin_data[i + 1]["pos"])
				_draw_dashed_line(p1, p2, net_color, 1.5, 5.0)
				draw_circle(p1, 3.0, net_color)
				draw_circle(p2, 3.0, net_color)


## How much of a component the current layer filter lets through. ONE rule,
## shared by the draw path (_draw_component) and the hit-test path
## (_component_at) — a user must not be able to click what is not drawn.
## NONE  = nothing at all (the part lives entirely on another copper layer)
## LANDS = only its through-hole lands (annular ring + drill)
## FULL  = everything (body, silk, courtyard, pads, badge, label)
enum CompVisibility { NONE, LANDS, FULL }


## Classify `comp` against the current layer filter (child bug 019fb55dc7f5).
##
## KiCad's rule, which the owner fixed as ours: a component's BODY belongs to the
## side it is mounted on, but a THROUGH-HOLE pad's barrel pierces EVERY copper
## layer, so its lands exist on every layer view. Therefore, viewing one layer:
##   * a part mounted on that layer          → FULL
##   * a part elsewhere WITH through-hole pads → LANDS (rings only, no body)
##   * a part elsewhere with only SMD pads    → NONE (this is the bug: a
##     top-only SMD part used to render in full on a bottom view)
## Under "all" every component is FULL, so nothing about the render changes.
##
## THT-ness is read from the pad's `type` field, NOT from pad["layers"]: `type`
## is populated on every pad path and is already what _draw_component_pads gates
## the drill render on, whereas pad["layers"] is only filled in by the canonical
## pin-synthesis path (pcb_component.gd) — footprint-resolved pads pass it
## through from the footprint and can carry [].
func _component_visibility(comp) -> CompVisibility:
	if _layer_visible(str(comp.layer)):
		return CompVisibility.FULL
	if not (comp.has_pad_geometry and comp.pads.size() > 0):
		return CompVisibility.NONE
	for pad in comp.pads:
		if str(pad.get("type", "smd")) in THT_PAD_TYPES:
			return CompVisibility.LANDS
	return CompVisibility.NONE


## Draw all components
func _draw_components() -> void:
	for comp_id in data.components:
		var comp = data.components[comp_id]
		_draw_component(comp)


## Draw board-level mounting holes (structural — not components, not vias).
## Mirrors the via draw loop in _draw_traces(): resolves position (Vector2 or
## {x,y} dict), draws an outer rim in mounting_hole_color and an inner drill
## circle so it reads as a hole.
func _draw_mounting_holes() -> void:
	for hole in data.mounting_holes:
		var pos_data = hole.get("position", Vector2.ZERO)
		var pos: Vector2
		if pos_data is Vector2:
			pos = world_to_screen(pos_data)
		elif pos_data is Dictionary:
			pos = world_to_screen(Vector2(pos_data.get("x", 0), pos_data.get("y", 0)))
		else:
			continue

		var outer_radius: float = (hole.get("diameter", 3.2) / 2.0) * zoom
		var inner_radius: float = outer_radius * 0.8

		draw_circle(pos, maxf(outer_radius, 2.0), mounting_hole_color)
		draw_circle(pos, maxf(inner_radius, 1.0), drill_hole_color)


## Draw a single component using rigid body transform, scoped by the layer filter
## (see _component_visibility for the rule). Draw ORDER is unchanged from before
## the filter existed — body, silk, courtyard, pads/pins, badge, label — so the
## "all" render is byte-for-byte the old one.
func _draw_component(comp) -> void:
	var visibility := _component_visibility(comp)
	if visibility == CompVisibility.NONE:
		return
	# Everything except the through-hole lands belongs to the side the part is
	# mounted on, so it is drawn only on that side's view.
	var body_visible := visibility == CompVisibility.FULL

	var xform: Transform2D = comp.get_transform()

	# Resolved footprint geometry vs the fallback pin renderer. The same
	# condition the fab emitter uses to fail closed (bug 019f7736b236): a
	# component WITHOUT real pad geometry is drawn from nominal fallback pins and
	# would not fabricate as-is — so it is badged (step 4b, canvas degrades).
	var has_real_pads: bool = comp.has_pad_geometry and comp.pads.size() > 0

	if body_visible:
		var color: Color = comp.color
		if comp.id in selected_components:
			color = component_selected_color
		elif comp.id == hovered_component:
			color = component_hover_color

		if comp.locked:
			color.a = 0.4

		var local_poly: PackedVector2Array = comp.get_local_body_polygon()
		var screen_poly: PackedVector2Array = []
		for point in local_poly:
			var world_point: Vector2 = comp.position + (xform * point)
			screen_poly.append(world_to_screen(world_point))

		draw_colored_polygon(screen_poly, color)

		var outline_points: PackedVector2Array = screen_poly.duplicate()
		outline_points.append(screen_poly[0])
		draw_polyline(outline_points, color.darkened(0.3), 1.0)

		if comp.locked:
			_draw_locked_hatch(screen_poly)

		if show_silk and comp.graphics.size() > 0:
			_draw_component_silk(comp, xform)

		if show_courtyard and comp.graphics.size() > 0:
			_draw_component_courtyard(comp, xform)

	if show_pads and has_real_pads:
		# LANDS: pass tht_only so the SMD pads of an other-side part are skipped
		# while its through-hole rings still draw. FULL passes false — every pad.
		_draw_component_pads(comp, xform, not body_visible)
	elif show_pins and body_visible:
		# Fallback pins are nominal, not real copper, and a LANDS component has
		# real pads by construction — so this branch is body-only.
		_draw_fallback_pins(comp, xform)

	if body_visible and show_unresolved_badges and not has_real_pads \
			and comp.footprint != PCBComponentScript.FootprintType.MOUNTING_HOLE:
		# _component_screen_poly is the same transform the body used above (and
		# what _get_tooltip probes), so badge draw and badge tooltip cannot
		# disagree about where the badge is.
		_draw_unresolved_badge(_component_screen_poly(comp))

	if body_visible and show_labels and comp.label_visible:
		var local_center: Vector2 = comp.local_bounds.get_center()
		var world_center: Vector2 = comp.position + (xform * local_center)
		var screen_center := world_to_screen(world_center)
		var label_pos := screen_center - Vector2(0, comp.height * zoom / 2 + 10)
		draw_string(font, label_pos, comp.id, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, label_color)


## Draw an amber warning triangle (with a "!") at the top-right of a component
## whose footprint did NOT resolve to real pad geometry — the visual counterpart
## of the fab emitter failing closed on that component (step 4b). Drawn as a
## triangle + strokes (no font dependency) so the "warning" reads unambiguously
## against a board of round pads/vias. Screen-space, so it stays a constant size
## regardless of zoom.
func _draw_unresolved_badge(screen_poly: PackedVector2Array) -> void:
	if screen_poly.size() < 3:
		return
	var center := _badge_center(screen_poly)
	var s := UNRESOLVED_BADGE_SIZE
	var tri := PackedVector2Array([
		center + Vector2(0.0, -s),            # top vertex
		center + Vector2(-s * 0.9, s * 0.6),  # bottom-left
		center + Vector2(s * 0.9, s * 0.6),   # bottom-right
	])
	draw_colored_polygon(tri, unresolved_badge_color)

	var dark := Color(0.15, 0.1, 0.0, 1.0)
	var outline := tri.duplicate()
	outline.append(tri[0])
	draw_polyline(outline, dark, 2.0)

	# Exclamation mark: a short stem + a dot, both dark, centred in the triangle.
	draw_line(center + Vector2(0.0, -s * 0.35), center + Vector2(0.0, s * 0.12), dark, 2.0)
	draw_circle(center + Vector2(0.0, s * 0.42), maxf(s * 0.11, 1.2), dark)


## Screen-space centre of a component's unresolved badge (just outside the
## top-right corner of its body bbox). Shared by the draw path AND the hover
## tooltip (_get_tooltip) so both agree on where the badge is.
func _badge_center(screen_poly: PackedVector2Array) -> Vector2:
	var min_pt := screen_poly[0]
	var max_pt := screen_poly[0]
	for pt in screen_poly:
		min_pt.x = minf(min_pt.x, pt.x)
		min_pt.y = minf(min_pt.y, pt.y)
		max_pt.x = maxf(max_pt.x, pt.x)
		max_pt.y = maxf(max_pt.y, pt.y)
	return Vector2(max_pt.x + UNRESOLVED_BADGE_MARGIN, min_pt.y - UNRESOLVED_BADGE_MARGIN)


## Component hit-test, layer-filter aware — the ONLY component pick the canvas
## should use. A user cannot click what is not drawn (child bug 019fb55dc7f5):
## with the view scoped to one copper layer, a part that renders NOTHING there
## must not select, drag, hover, or claim the context menu. A part still showing
## its through-hole lands stays pickable (its rings are on screen, and its body
## box is where those rings are).
##
## data.get_component_at() knows nothing about the view, so every call site goes
## through here instead of calling it directly.
func _component_at(world_pos: Vector2) -> String:
	if data == null:
		return ""
	var comp_id: String = data.get_component_at(world_pos)
	if comp_id.is_empty():
		return ""
	var comp = data.get_component(comp_id)
	if comp == null:
		return comp_id
	return "" if _component_visibility(comp) == CompVisibility.NONE else comp_id


## A component's body polygon in screen space (same transform _draw_component
## uses), for hover hit-testing without caching per-frame draw state.
func _component_screen_poly(comp) -> PackedVector2Array:
	var xform: Transform2D = comp.get_transform()
	var out: PackedVector2Array = []
	for point in comp.get_local_body_polygon():
		out.append(world_to_screen(comp.position + (xform * point)))
	return out


## Native hover tooltip explaining the amber unresolved-footprint badge. Returns
## "" everywhere except over a badge, so no tooltip shows elsewhere. Godot calls
## this on mouse-hover (mouse_filter is STOP); at_position is canvas-local px,
## the same space world_to_screen produces.
func _get_tooltip(at_position: Vector2) -> String:
	if not show_unresolved_badges or data == null:
		return ""
	var reach := UNRESOLVED_BADGE_SIZE + 3.0
	for comp_id in data.components:
		var comp = data.components[comp_id]
		if comp.has_pad_geometry and comp.pads.size() > 0:
			continue
		if comp.footprint == PCBComponentScript.FootprintType.MOUNTING_HOLE:
			continue
		var center := _badge_center(_component_screen_poly(comp))
		if absf(at_position.x - center.x) <= reach and absf(at_position.y - center.y) <= reach:
			return "%s — unresolved footprint\nPads are approximate (fallback pins); resolve the footprint before fabrication." % str(comp_id)
	return ""


## Draw diagonal hatch lines over a locked component's screen polygon
func _draw_locked_hatch(screen_poly: PackedVector2Array) -> void:
	if screen_poly.size() < 3:
		return

	var min_pt := screen_poly[0]
	var max_pt := screen_poly[0]
	for pt in screen_poly:
		min_pt.x = minf(min_pt.x, pt.x)
		min_pt.y = minf(min_pt.y, pt.y)
		max_pt.x = maxf(max_pt.x, pt.x)
		max_pt.y = maxf(max_pt.y, pt.y)

	var hatch_color := Color(0.9, 0.4, 0.1, 0.35)
	var spacing := 8.0
	var diag := max_pt - min_pt
	var total := diag.x + diag.y

	var d := 0.0
	while d < total:
		var x0 := min_pt.x + d
		var y0 := min_pt.y
		var x1 := min_pt.x
		var y1 := min_pt.y + d

		if x0 > max_pt.x:
			y0 += x0 - max_pt.x
			x0 = max_pt.x
		if y1 > max_pt.y:
			x1 += y1 - max_pt.y
			y1 = max_pt.y

		if x0 >= min_pt.x and y0 <= max_pt.y and x1 <= max_pt.x and y1 >= min_pt.y:
			draw_line(Vector2(x0, y0), Vector2(x1, y1), hatch_color, 1.0)
		d += spacing


## Draw pads with accurate geometry from KiCAD footprint.
##
## `tht_only` renders ONLY the through-hole lands, for a component whose body is
## on another copper layer than the one being viewed (see _component_visibility).
## Defaults false, so the full-render callers are unchanged.
func _draw_component_pads(comp, xform: Transform2D, tht_only: bool = false) -> void:
	var pad_rot: float = -comp.rotation

	for pad in comp.pads:
		var pad_type: String = pad.get("type", "smd")
		var pad_shape: String = pad.get("shape", "rect")
		var local_pos: Vector2 = pad.get("position", Vector2.ZERO)
		var pad_size: Vector2 = pad.get("size", Vector2(1, 1))

		var is_tht := pad_type in THT_PAD_TYPES

		# An SMD pad is copper on ONE side; it does not appear on any other
		# layer's view. A through-hole barrel pierces them all, so its land does.
		if tht_only and not is_tht:
			continue

		var world_pos: Vector2 = comp.position + (xform * local_pos)
		var screen_pos := world_to_screen(world_pos)
		var screen_size := pad_size * zoom

		var draw_color := pad_copper_color
		if pad_type == "smd":
			draw_color = pad_smd_color
		elif pad_type == "np_thru_hole":
			draw_color = mounting_hole_color

		match pad_shape:
			"rect":
				_draw_rect_pad(screen_pos, screen_size, pad_rot, draw_color)
			"circle":
				_draw_circle_pad(screen_pos, screen_size, draw_color)
			"oval":
				_draw_oval_pad(screen_pos, screen_size, pad_rot, draw_color)
			"roundrect":
				_draw_roundrect_pad(screen_pos, screen_size, pad_rot, draw_color)
			_:
				_draw_rect_pad(screen_pos, screen_size, pad_rot, draw_color)

		if is_tht:
			var drill_val = pad.get("drill", Vector2.ZERO)
			var drill_diameter: float = 0.0
			if drill_val is Vector2:
				drill_diameter = maxf(drill_val.x, drill_val.y)
			elif drill_val is float or drill_val is int:
				drill_diameter = float(drill_val)

			if drill_diameter <= 0.0:
				drill_diameter = minf(pad_size.x, pad_size.y)

			if drill_diameter > 0.0:
				var drill_radius := (drill_diameter * zoom) / 2.0
				draw_circle(screen_pos, maxf(drill_radius, 1.0), drill_hole_color)
				draw_arc(screen_pos, maxf(drill_radius, 1.0), 0, TAU, 16, Color(0.4, 0.4, 0.4, 0.6), 1.0)


## Draw one `comp.graphics` layer (component body outline, markings, courtyard,
## etc.) attached by the worker's footprint-RESOLVE step (component.graphics,
## LOCAL mm coords). Transform convention MUST match _draw_component_pads
## EXACTLY — same `xform` (comp.get_transform(), KiCAD CW rotation) and the
## same `comp.position + (xform * local_point)` composition — so the drawn
## layer aligns with the copper it was resolved against. Shared by
## _draw_component_silk (F.SilkS) and _draw_component_courtyard (F.CrtYd) so
## both layers walk the same geometry-kind handling.
func _draw_component_graphics_layer(comp, xform: Transform2D, layer_name: String, stroke_color: Color, min_width_px: float) -> void:
	for g in comp.graphics:
		if g.get("layer", "") != layer_name:
			continue

		var kind: String = g.get("kind", "")
		var w: float = maxf(float(g.get("width", 0.15)) * zoom, min_width_px)

		match kind:
			"line":
				var start: Vector2 = g.get("start", Vector2.ZERO)
				var end: Vector2 = g.get("end", Vector2.ZERO)
				var p0 := world_to_screen(comp.position + (xform * start))
				var p1 := world_to_screen(comp.position + (xform * end))
				draw_line(p0, p1, stroke_color, w)

			"circle":
				var center: Vector2 = g.get("center", Vector2.ZERO)
				var radius: float = float(g.get("radius", 0.0))
				var center_screen := world_to_screen(comp.position + (xform * center))
				var radius_screen := radius * zoom
				if radius_screen > 0.0:
					draw_arc(center_screen, radius_screen, 0, TAU, 32, stroke_color, w)

			"poly":
				var poly_points: PackedVector2Array = []
				for pt in g.get("points", []):
					var local_pt: Vector2 = pt
					poly_points.append(world_to_screen(comp.position + (xform * local_pt)))
				if poly_points.size() >= 2:
					draw_polyline(poly_points, stroke_color, w)

			"arc":
				# The graphic carries 2-3 LOCAL points (start[,mid],end). A true
				# arc reconstruction from those is awkward in screen space (the
				# rotation/rounding makes center+angle derivation fiddly); a
				# polyline through the transformed points is an acceptable
				# stand-in per the round's brief — visually indistinguishable
				# for the small radii silk/courtyard arcs typically use (pin-1
				# dots, rounded corners).
				var arc_points: PackedVector2Array = []
				for pt in g.get("points", []):
					var local_pt: Vector2 = pt
					arc_points.append(world_to_screen(comp.position + (xform * local_pt)))
				if arc_points.size() >= 2:
					draw_polyline(arc_points, stroke_color, w)


## Draw F.SilkS graphics (component body outline, markings, etc.). See
## _draw_component_graphics_layer for the transform/geometry contract.
func _draw_component_silk(comp, xform: Transform2D) -> void:
	_draw_component_graphics_layer(comp, xform, "F.SilkS", silk_color, silk_min_width_px)


## Draw F.CrtYd (courtyard) graphics — the module's true extent (also what
## pcb_component.gd derives local_bounds from when the board gave no explicit
## size). Dimmer/thinner than silk (courtyard_color/courtyard_min_width_px);
## gated by show_courtyard independently of show_silk.
func _draw_component_courtyard(comp, xform: Transform2D) -> void:
	_draw_component_graphics_layer(comp, xform, "F.CrtYd", courtyard_color, courtyard_min_width_px)


## Fallback pin rendering when pad geometry not available.
func _draw_fallback_pins(comp, xform: Transform2D) -> void:
	var is_mounting_hole: bool = comp.footprint == PCBComponentScript.FootprintType.MOUNTING_HOLE
	var is_tht_footprint: bool = comp.footprint in [
		PCBComponentScript.FootprintType.IC_DIP,
		PCBComponentScript.FootprintType.HEADER,
		PCBComponentScript.FootprintType.CONNECTOR,
		PCBComponentScript.FootprintType.MODULE,
	]
	var is_likely_tht: bool = comp.footprint in [
		PCBComponentScript.FootprintType.RESISTOR,
		PCBComponentScript.FootprintType.CAPACITOR,
		PCBComponentScript.FootprintType.DIODE,
		PCBComponentScript.FootprintType.LED,
		PCBComponentScript.FootprintType.TRANSISTOR,
		PCBComponentScript.FootprintType.SWITCH,
		PCBComponentScript.FootprintType.CRYSTAL,
	]

	if is_mounting_hole:
		var hole_diameter: float = comp.width
		var hole_radius: float = (hole_diameter * zoom) / 2.0

		for pin_name in comp.pins:
			var local_pin_pos: Vector2 = comp.pins[pin_name]
			var world_pin_pos: Vector2 = comp.position + (xform * local_pin_pos)
			var pin_screen := world_to_screen(world_pin_pos)

			var annulus_radius: float = hole_radius + (0.5 * zoom)
			draw_circle(pin_screen, maxf(annulus_radius, 2.0), mounting_hole_color)
			draw_circle(pin_screen, maxf(hole_radius, 1.5), drill_hole_color)
			draw_arc(pin_screen, maxf(hole_radius, 1.5), 0, TAU, 24, Color(0.5, 0.5, 0.5, 0.8), 1.5)

	elif is_tht_footprint or is_likely_tht:
		var pad_diameter := 1.7
		var drill_diameter := 1.0
		var pad_radius := (pad_diameter * zoom) / 2.0
		var drill_radius := (drill_diameter * zoom) / 2.0

		for pin_name in comp.pins:
			var local_pin_pos: Vector2 = comp.pins[pin_name]
			var world_pin_pos: Vector2 = comp.position + (xform * local_pin_pos)
			var pin_screen := world_to_screen(world_pin_pos)

			if pin_name == "1":
				var pad_size := Vector2(pad_diameter, pad_diameter) * zoom
				_draw_rect_pad(pin_screen, pad_size, -comp.rotation, pad_copper_color)
			else:
				draw_circle(pin_screen, maxf(pad_radius, 2.0), pad_copper_color)

			draw_circle(pin_screen, maxf(drill_radius, 1.0), drill_hole_color)
			draw_arc(pin_screen, maxf(drill_radius, 1.0), 0, TAU, 16, Color(0.4, 0.4, 0.4, 0.6), 1.0)

	else:
		var pad_size := 1.0
		var pad_radius := (pad_size * zoom) / 2.0

		for pin_name in comp.pins:
			var local_pin_pos: Vector2 = comp.pins[pin_name]
			var world_pin_pos: Vector2 = comp.position + (xform * local_pin_pos)
			var pin_screen := world_to_screen(world_pin_pos)
			draw_circle(pin_screen, maxf(pad_radius, 2.0), pad_smd_color)


## Draw rectangular pad (sharp corners)
func _draw_rect_pad(center: Vector2, pad_size: Vector2, pad_rotation: float, color: Color) -> void:
	var rect_points := _get_rotated_rect_points(center, pad_size, pad_rotation)
	draw_colored_polygon(rect_points, color)


## Draw circular pad
func _draw_circle_pad(center: Vector2, pad_size: Vector2, color: Color) -> void:
	var radius := maxf(pad_size.x, pad_size.y) / 2.0
	draw_circle(center, maxf(radius, 1.0), color)


## Draw oval pad (elongated circle)
func _draw_oval_pad(center: Vector2, pad_size: Vector2, pad_rotation: float, color: Color) -> void:
	var rot_rad := deg_to_rad(pad_rotation)

	if pad_size.x > pad_size.y:
		var radius := pad_size.y / 2.0
		var half_length := (pad_size.x - pad_size.y) / 2.0

		var rect_size := Vector2(half_length * 2, pad_size.y)
		var rect_points := _get_rotated_rect_points(center, rect_size, pad_rotation)
		draw_colored_polygon(rect_points, color)

		var offset := Vector2(half_length, 0).rotated(rot_rad)
		draw_circle(center - offset, maxf(radius, 1.0), color)
		draw_circle(center + offset, maxf(radius, 1.0), color)
	else:
		var radius := pad_size.x / 2.0
		var half_length := (pad_size.y - pad_size.x) / 2.0

		var rect_size := Vector2(pad_size.x, half_length * 2)
		var rect_points := _get_rotated_rect_points(center, rect_size, pad_rotation)
		draw_colored_polygon(rect_points, color)

		var offset := Vector2(0, half_length).rotated(rot_rad)
		draw_circle(center - offset, maxf(radius, 1.0), color)
		draw_circle(center + offset, maxf(radius, 1.0), color)


## Draw rounded rectangle pad (rectangle approximation)
func _draw_roundrect_pad(center: Vector2, pad_size: Vector2, pad_rotation: float, color: Color) -> void:
	var rect_points := _get_rotated_rect_points(center, pad_size, pad_rotation)
	draw_colored_polygon(rect_points, color)


## Get rotated rectangle points
func _get_rotated_rect_points(center: Vector2, rect_size: Vector2, rect_rotation: float) -> PackedVector2Array:
	var half_size := rect_size / 2.0
	var corners := [
		Vector2(-half_size.x, -half_size.y),
		Vector2(half_size.x, -half_size.y),
		Vector2(half_size.x, half_size.y),
		Vector2(-half_size.x, half_size.y)
	]

	var rot_rad := deg_to_rad(rect_rotation)
	var result: PackedVector2Array = []
	for corner in corners:
		result.append(center + corner.rotated(rot_rad))
	return result


## Draw selection box
func _draw_selection_box() -> void:
	var rect := Rect2(
		box_select_start.min(box_select_end),
		(box_select_end - box_select_start).abs()
	)
	draw_rect(rect, selection_box_color)
	draw_rect(rect, selection_border_color, false, 1.0)


## INSPECT_PIN nearest-pad hover label at the cursor (native L1444 parity).
func _draw_inspect_hover_label() -> void:
	var pos := _inspect_hover_screen_pos + Vector2(14, -14)
	var text_size := font.get_string_size(_inspect_hover_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var bg_rect := Rect2(pos + Vector2(-3, -text_size.y), text_size + Vector2(6, 4))
	draw_rect(bg_rect, Color(0.05, 0.05, 0.05, 0.85))
	draw_string(font, pos, _inspect_hover_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


## Draw a dashed line
func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, width: float, dash_length: float) -> void:
	var direction := (to - from).normalized()
	var distance := from.distance_to(to)
	var current := 0.0
	var drawing := true

	while current < distance:
		var segment_end := minf(current + dash_length, distance)
		if drawing:
			draw_line(
				from + direction * current,
				from + direction * segment_end,
				color,
				width
			)
		drawing = not drawing
		current = segment_end


#region Coordinate Transformation

## Convert world position (mm) to screen position (pixels)
func world_to_screen(world_pos: Vector2) -> Vector2:
	return (world_pos * zoom) + pan_offset + size / 2

## Convert screen position (pixels) to world position (mm)
func screen_to_world(screen_pos: Vector2) -> Vector2:
	return (screen_pos - pan_offset - size / 2) / zoom

#endregion


#region Input Handling

func _gui_input(event: InputEvent) -> void:
	if not is_inside_tree() or not data:
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventKey:
		_handle_key_input(event)
	elif event is InputEventPanGesture:
		_handle_pan_gesture(event)
	elif event is InputEventMagnifyGesture:
		_handle_magnify_gesture(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	var world_pos := screen_to_world(event.position)

	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			grab_focus()

			# Pin inspector (WC-1): click selects the nearest pad within radius,
			# or clears when empty space is clicked. Owns the click outright —
			# no select/drag/box-select fallthrough while the mode is active.
			if tool_mode == ToolMode.INSPECT_PIN:
				_handle_inspect_pin_click(world_pos)
				return

			# Zone tools (unit 4): each left-click places a vertex; a double-click
			# closes the polygon. Owns the click outright, exactly like the pin
			# inspector above — no select/drag/box-select fallthrough while a
			# region is being drawn.
			if _is_zone_tool():
				_handle_zone_click(world_pos, event.double_click)
				return

			# Trace tool (unit 5): first click must land on a pad (that is where
			# the net comes from), later clicks place waypoints or finish on a
			# pad. Owns the click outright, same as the two tools above.
			if tool_mode == ToolMode.TRACE:
				_handle_trace_click(world_pos, event.double_click)
				return

			# Eraser tool (item 019fb934827776): owns the click outright, exactly
			# like the three tools above — no select/drag/box-select fallthrough
			# while it is armed.
			if tool_mode == ToolMode.ERASER:
				_handle_eraser_click(world_pos)
				return

			# Pan tool OR Space-drag: a left-drag pans the whole board view.
			# (Discoverability for finding 2 — a visible Pan tool + the familiar
			# Space+drag, alongside the existing right/middle-drag pan.)
			if tool_mode == ToolMode.PAN or _space_pan_armed:
				is_panning = true
				pan_start_mouse = event.position
				pan_start_offset = pan_offset
				return

			# Smart SELECT tool (the resting tool): click selects; click-drag on
			# any SELECTED entity moves the whole selection (snap-aware); click-
			# drag on empty space box-selects. One tool does select + move +
			# box-select; R rotates.
			#
			# The grammar is now kind-blind (mixed multi-select, 019fb92f8b83):
			#   plain click on an entity  -> selection becomes exactly that entity
			#   shift-click on an entity  -> toggles it in/out of the selection
			#   click on empty space      -> deselect all, begin a box-select
			# The armed tool is NEVER disarmed by an empty click (owner ruling on
			# 019fb59b5d86) — that is why this branch only touches selection.
			var hit: Array = _entity_at(world_pos)
			var hit_kind: String = hit[0]
			var hit_id: String = hit[1]

			if event.double_click and hit_kind == KIND_COMPONENT:
				component_double_clicked.emit(hit_id)
			elif hit_kind.is_empty():
				if not event.shift_pressed:
					_clear_selection()
				is_box_selecting = true
				box_select_start = event.position
				box_select_end = event.position
			else:
				if event.shift_pressed:
					_toggle_entity_selected(hit_kind, hit_id)
				elif not is_entity_selected(hit_kind, hit_id):
					_clear_selection()
					_add_to_selection(hit_kind, hit_id)

				# A shift-click that REMOVED the entity must not then drag it;
				# anything still selected under the cursor anchors the move.
				if is_entity_selected(hit_kind, hit_id):
					# Remember WHICH component was clicked (A4) — with a group
					# selection this is the only thing that distinguishes one
					# member from another, and it is what the panel's offset
					# editor edits. Set only when the click leaves it selected.
					if hit_kind == KIND_COMPONENT:
						focused_component = hit_id
					_begin_selection_drag(hit_kind, hit_id, event.position)

			selection_changed.emit()
			queue_redraw()
		else:
			# Release a left-drag pan (Pan tool / Space-drag).
			if is_panning:
				is_panning = false
			if is_dragging_selection:
				_end_selection_drag()

			if is_box_selecting:
				is_box_selecting = false
				_finalize_box_selection()

			queue_redraw()

	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			# Right-click CANCELS an in-progress zone (same grammar as the
			# single-trace hint tool) instead of starting a pan / arming the
			# context menu. Only while actually drawing — with no polygon in
			# progress the zone tools leave right-drag panning alone.
			if _is_zone_tool() and not _zone_points.is_empty():
				_cancel_zone_draw(true)
				return
			if tool_mode == ToolMode.TRACE and not _trace_points.is_empty():
				_cancel_trace_draw(true)
				return
			is_panning = true
			pan_start_mouse = event.position
			pan_start_offset = pan_offset
			right_click_start_pos = event.position
			context_menu_world_pos = world_pos
		else:
			is_panning = false
			if event.position.distance_to(right_click_start_pos) < RIGHT_CLICK_THRESHOLD:
				_show_context_menu(event.position)

	elif event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			is_panning = true
			pan_start_mouse = event.position
			pan_start_offset = pan_offset
		else:
			is_panning = false

	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom_at(event.position, 1.2)

	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom_at(event.position, 0.8)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var world_pos := screen_to_world(event.position)

	# Pin inspector (WC-1) owns hover feedback instead of component hover; a
	# middle/right-drag pan still updates below via is_panning, unaffected by
	# this branch.
	if tool_mode == ToolMode.INSPECT_PIN:
		_update_inspect_hover(world_pos, event.position)
	elif _is_zone_tool():
		# Rubber-band the edge from the last placed vertex to the cursor. No
		# component hover while a zone tool is armed — the tool owns the surface,
		# so a highlight left over from before it was armed is dropped.
		if not hovered_component.is_empty():
			hovered_component = ""
			queue_redraw()
		if not _zone_points.is_empty():
			_zone_preview = _author_point(world_pos)
			_zone_has_preview = true
			queue_redraw()
	elif tool_mode == ToolMode.TRACE:
		# Rubber-band the segment from the last placed waypoint to the cursor.
		# Same "the tool owns the surface" rule as the zone branch above, so a
		# stale component highlight is dropped.
		if not hovered_component.is_empty():
			hovered_component = ""
			queue_redraw()
		if not _trace_points.is_empty():
			_trace_preview = _author_point(world_pos)
			_trace_has_preview = true
			queue_redraw()
	else:
		var new_hover: String = _component_at(world_pos)
		if new_hover != hovered_component:
			hovered_component = new_hover
			queue_redraw()

	if is_panning:
		pan_offset = pan_start_offset + (event.position - pan_start_mouse)
		view_changed.emit()
		queue_redraw()

	if is_dragging_selection:
		# The ANCHOR is what snaps; everything else in the selection takes the
		# anchor's delta verbatim, so a multi-entity move can never distort the
		# relative offsets the user arranged (snapping each member on its own
		# would). _snap_bypass_held() is read HERE, every frame, so pressing or
		# releasing Ctrl/Cmd mid-drag toggles snapping immediately (item
		# 019fb93185c8).
		var anchor_target: Vector2 = screen_to_world(event.position) - screen_to_world(drag_start_mouse) + _drag_anchor_start
		if snap_to_grid and not _snap_bypass_held():
			anchor_target = data.snap_to_grid(anchor_target)
		_apply_drag_delta(anchor_target - _drag_anchor_start)
		queue_redraw()

	if is_box_selecting:
		box_select_end = event.position
		queue_redraw()


func _handle_key_input(event: InputEventKey) -> void:
	# Space arms/disarms drag-pan on both key edges (before the pressed-only gate).
	if event.keycode == KEY_SPACE:
		_space_pan_armed = event.pressed
		return

	if not event.pressed:
		return

	# CTRL IS READ FIRST, and for KEY_G ONLY (A4). Bare G toggles the grid in the
	# match below and _handle_key_input never consulted a modifier for it, so
	# Ctrl+G would otherwise have toggled the grid while claiming to group.
	# Narrowed to this one keycode on purpose: swallowing every ctrl+<key> here
	# would silently change what Ctrl+R / Ctrl+S / Ctrl+L do today.
	# Cmd is accepted alongside Ctrl, the convention _snap_bypass_held and
	# _author_point already share.
	if event.keycode == KEY_G and (event.ctrl_pressed or event.meta_pressed):
		if event.shift_pressed:
			_ungroup_selection()
		else:
			_group_selection()
		return

	match event.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			# Batch-deletes the WHOLE mixed selection as ONE undo step (item
			# 019fb92f8b83) — no more per-kind priority (trace, then zone,
			# then components); see _delete_selection.
			_delete_selection()
		KEY_ENTER, KEY_KP_ENTER:
			# Closes an in-progress zone. Mirrors the single-trace hint tool's
			# Enter commit; the canvas also honours a real double-click (it,
			# unlike AnnotationOverlay, does receive the double_click flag).
			if _is_zone_tool():
				_commit_zone()
			# Ends an in-progress trace at its last waypoint — a dangling trace,
			# which the model and the board contract both allow (nothing requires
			# a trace to terminate on a pad).
			elif tool_mode == ToolMode.TRACE:
				_commit_trace()
		KEY_ESCAPE:
			# A zone draw in progress is what Escape cancels FIRST — cancelling it
			# should not also wipe the user's component selection.
			if _is_zone_tool() and not _zone_points.is_empty():
				_cancel_zone_draw(true)
				return
			if tool_mode == ToolMode.TRACE and not _trace_points.is_empty():
				_cancel_trace_draw(true)
				return
			if tool_mode == ToolMode.INSPECT_PIN:
				_exit_inspect_pin_mode()
			# Esc disarms the eraser (item 019fb934827776 — "Esc or choosing
			# another tool disarms"); an empty click deliberately does NOT (see
			# _handle_eraser_click), so this is the only click-free way out.
			elif tool_mode == ToolMode.ERASER:
				set_tool_mode(ToolMode.SELECT)
			# One call drops the whole mixed selection — components, traces and
			# zones alike (see _clear_selection).
			_clear_selection()
			queue_redraw()
		KEY_P:
			if event.shift_pressed:
				_toggle_inspect_pin_mode()
		KEY_R:
			_rotate_selected()
		KEY_G:
			show_grid = not show_grid
			queue_redraw()
		KEY_N:
			show_ratsnest = not show_ratsnest
			queue_redraw()
		KEY_L:
			if event.shift_pressed:
				_unlock_all_components()
			elif not selected_components.is_empty():
				_lock_selected_components()
			else:
				show_labels = not show_labels
				queue_redraw()
		KEY_HOME:
			_center_view()
		KEY_PLUS, KEY_KP_ADD, KEY_EQUAL:
			_zoom_at(size / 2, 1.2)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom_at(size / 2, 0.8)
		KEY_S:
			set_tool_mode(ToolMode.SELECT)


## Trackpad two-finger scroll → pan the view (finding 1: "trackpad zoom does
## nothing" — many trackpads emit pan gestures, not wheel-button events).
func _handle_pan_gesture(event: InputEventPanGesture) -> void:
	pan_offset -= event.delta * 12.0
	view_changed.emit()
	queue_redraw()


## Trackpad pinch → zoom about the gesture point (finding 1).
func _handle_magnify_gesture(event: InputEventMagnifyGesture) -> void:
	if event.factor > 0.0:
		_zoom_at(event.position, event.factor)


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var world_before := screen_to_world(screen_pos)
	zoom = clampf(zoom * factor, min_zoom, max_zoom)
	var world_after := screen_to_world(screen_pos)
	pan_offset += (world_after - world_before) * zoom
	zoom_changed.emit(zoom)
	view_changed.emit()
	queue_redraw()


func _center_view() -> void:
	if not data:
		return
	pan_offset = Vector2.ZERO
	view_changed.emit()
	queue_redraw()


#region Selection Set

## The backing id list for one entity kind — the ONE place a kind string is
## mapped to storage. Returns the live array (GDScript Arrays are references), so
## callers mutate the real selection through it. An unknown kind yields an empty
## throwaway rather than an error: every caller here passes a KIND_* constant,
## and a typo silently selecting the wrong kind would be worse than a no-op.
func _selection_of(kind: String) -> Array[String]:
	match kind:
		KIND_COMPONENT:
			return selected_components
		KIND_TRACE:
			return selected_trace_ids
		KIND_ZONE:
			return selected_zone_ids
	var empty: Array[String] = []
	return empty


## Is this entity in the selection? Kind-blind membership test.
func is_entity_selected(kind: String, entity_id: String) -> bool:
	return entity_id in _selection_of(kind)


## Add one entity to the selection (no-op if already in it).
##
## component_selected/component_deselected stay COMPONENT-ONLY: they are the
## panel's property-inspector feed, which only ever meant components. Every kind
## reports through selection_changed, which the caller emits ONCE per gesture
## rather than once per entity (a box-select of 40 parts is one selection change,
## not 40).
##
## SELECTING A GROUP MEMBER SELECTS THE WHOLE GROUP (A4). The expansion lives
## HERE, at the one choke point every add path already funnels through — the
## click pick, the box sweep (_finalize_box_selection), shift-click toggle-on and
## the public select_component() — so no caller has to remember to expand and none
## of them can disagree about what a group selection is. The recursion terminates
## on the is_entity_selected guard above (each member is added exactly once), and
## groups do not nest, so the depth is 1 regardless.
##
## An UNGROUPED component finds an empty group-mate list and this costs it one
## dictionary read: zero behaviour change on a board with no groups.
func _add_to_selection(kind: String, entity_id: String) -> void:
	if entity_id.is_empty() or is_entity_selected(kind, entity_id):
		return
	_selection_of(kind).append(entity_id)
	if kind == KIND_COMPONENT:
		component_selected.emit(entity_id)
		for member_id in _group_mates(entity_id):
			_add_to_selection(kind, member_id)


## The other members of this component's group ([] when it has none). Wrapped so
## the canvas asks the MODEL the membership question in exactly one place.
func _group_mates(component_id: String) -> Array[String]:
	var mates: Array[String] = []
	if not data:
		return mates
	var group_id: String = data.component_group_id(component_id)
	if group_id.is_empty():
		return mates
	for member_id in data.group_member_ids(group_id):
		if member_id != component_id:
			mates.append(member_id)
	return mates


func _remove_from_selection(kind: String, entity_id: String) -> void:
	var sel := _selection_of(kind)
	var idx := sel.find(entity_id)
	if idx < 0:
		return
	sel.remove_at(idx)
	if kind == KIND_COMPONENT:
		component_deselected.emit(entity_id)


## Shift-click semantics: in becomes out, out becomes in — for any kind.
##
## A GROUP toggles as a unit in BOTH directions (A4): _add_to_selection expands on
## the way in, so this expands on the way out too. Removing only the clicked
## member would leave the rest of the physical part selected — a state the click
## grammar can produce but no gesture can act on coherently.
##
## The removal expansion is spelled out here rather than pushed into
## _remove_from_selection deliberately: that helper is also the eraser's
## "the entity I just deleted is gone from the selection" call
## (_handle_eraser_click), which is about ONE entity and must stay that way.
func _toggle_entity_selected(kind: String, entity_id: String) -> void:
	if is_entity_selected(kind, entity_id):
		_remove_from_selection(kind, entity_id)
		if kind == KIND_COMPONENT:
			for member_id in _group_mates(entity_id):
				_remove_from_selection(kind, member_id)
	else:
		_add_to_selection(kind, entity_id)


## Total selected entities across all three kinds.
func selection_count() -> int:
	return selected_components.size() + selected_trace_ids.size() + selected_zone_ids.size()


func has_selection() -> bool:
	return selection_count() > 0


## Drop EVERY selected entity, whatever its kind. Deselect-only: the armed tool
## is untouched (owner ruling on 019fb59b5d86 — an empty click deselects, it does
## not disarm the tool).
func _clear_selection() -> void:
	for comp_id in selected_components:
		component_deselected.emit(comp_id)
	selected_components.clear()
	selected_trace_ids.clear()
	selected_zone_ids.clear()
	focused_component = ""
	selection_changed.emit()


## Sweep the marquee over ALL THREE kinds, each honouring the SAME visibility
## rule its single-click pick honours (_component_visibility for parts,
## _trace_visible for copper, _zone_visible for zones) — a box drawn over a layer
## view must never grab what that view does not draw.
##
## ADDITIVE by construction: a non-shift box-select already cleared the selection
## at press time, so this only ever adds — which is what makes shift+box extend an
## existing mixed selection for free.
##
## LOCKED COMPONENTS ARE SWEPT IN, deliberately and unchanged from before this
## unit: get_components_in_region never filtered them, and a locked part must stay
## selectable for the Unlock UI to reach it. The lock is enforced where it means
## something — the MOVE path skips locked entities (see _capture_drag_origins), so
## a locked part inside a dragged selection simply stays put.
func _finalize_box_selection() -> void:
	var world_start := screen_to_world(box_select_start.min(box_select_end))
	var world_end := screen_to_world(box_select_start.max(box_select_end))
	var select_rect := Rect2(world_start, world_end - world_start)

	for comp_id in data.get_components_in_region(select_rect):
		var hit_comp = data.get_component(comp_id)
		if hit_comp != null and _component_visibility(hit_comp) == CompVisibility.NONE:
			continue
		_add_to_selection(KIND_COMPONENT, comp_id)

	for trace_id in data.get_traces_in_region(select_rect, _trace_visible):
		_add_to_selection(KIND_TRACE, trace_id)

	for zone_id in data.get_zones_in_region(select_rect, _zone_visible):
		_add_to_selection(KIND_ZONE, zone_id)

	selection_changed.emit()


## What the Select tool picks at `world_pos`, as [kind, id]; ["", ""] for empty
## space. The PICK ORDER is unchanged from before mixed selection — component,
## then trace, then zone — so which entity a click claims never moved; only what
## the caller then does with it did.
func _entity_at(world_pos: Vector2) -> Array:
	var comp_id: String = _component_at(world_pos)
	if not comp_id.is_empty():
		return [KIND_COMPONENT, comp_id]
	var trace_id: String = _trace_at(world_pos)
	if not trace_id.is_empty():
		return [KIND_TRACE, trace_id]
	var zone_id: String = _zone_at(world_pos)
	if not zone_id.is_empty():
		return [KIND_ZONE, zone_id]
	return ["", ""]


## Which trace a click at `world_pos` picks, or "".
##
## MEASURED CORRECTION (this unit): the previous pick called data.get_trace_at()
## raw, so it was the ONE pick on this canvas that ignored visibility — a click
## could select copper on a filtered-out layer, or with traces hidden entirely,
## while _component_at and _zone_at both refused. That is now impossible: pick and
## box-sweep share _trace_visible, exactly as the zone pair share _zone_visible.
func _trace_at(world_pos: Vector2) -> String:
	if not data:
		return ""
	return data.get_trace_at(world_pos, 3.0 / zoom, _trace_visible)


## Is this trace drawable in the current view? The trace twin of
## _component_visibility / _zone_visible, and the single source for BOTH the
## click pick and the box sweep. Mirrors _draw_traces: the layer filter, plus the
## show_traces toggle (hidden copper must not be clickable copper).
func _trace_visible(trace) -> bool:
	return show_traces and _layer_visible(_canonical_layer(str(trace.layer)))


## Is this zone drawable in the current view? Same predicate _zone_at applies per
## zone, lifted out so the box sweep cannot drift from the click pick.
func _zone_visible(zone: Dictionary) -> bool:
	return show_zones and _layer_visible(PcbLayerStack.kicad_to_canon(str(zone.get("layer", ""))))

#endregion


#region Selection Drag-Move

## True while the no-snap modifier is held. Ctrl (or Cmd on a Mac) — BOTH keys,
## the convention _author_point established for authoring clicks, now shared with
## the drag-move (item 019fb93185c8, owner-ruled).
##
## Read from Input at the moment of use rather than off the InputEvent, for the
## reason _author_point states AND one more: a drag is a gesture, not an event.
## The modifier is consulted on every motion frame, so pressing or releasing it
## mid-drag toggles snapping right then — and holding it at PRESS time changes
## nothing about selection (shift-click add/remove is read off the event, as
## before), because press-time never asks this question.
func _snap_bypass_held() -> bool:
	return Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)


## The point that represents an entity's position: a component's origin, a
## trace's first waypoint, a zone's first outline point.
##
## Falls back to Vector2.ZERO for an unknown or geometry-less entity, which no
## real gesture can reach: the only caller anchors on what _entity_at returned,
## and a trace with under two waypoints or a zone with under three points cannot
## be hit by those picks in the first place.
func _entity_anchor(kind: String, entity_id: String) -> Vector2:
	match kind:
		KIND_COMPONENT:
			var comp = data.get_component(entity_id)
			return comp.position if comp != null else Vector2.ZERO
		KIND_TRACE:
			var trace = data.get_trace(entity_id)
			if trace != null and not trace.waypoints.is_empty():
				return trace.waypoints[0]
		KIND_ZONE:
			var pts := PCBDataScript.zone_outline_points(data.get_zone(entity_id))
			if not pts.is_empty():
				return pts[0]
	return Vector2.ZERO


## Begin a drag-move anchored on the entity under the cursor. The anchor is only
## the snap reference — what MOVES is the whole selection (_capture_drag_origins).
func _begin_selection_drag(kind: String, entity_id: String, screen_pos: Vector2) -> void:
	_drag_anchor_start = _entity_anchor(kind, entity_id)
	drag_start_mouse = screen_pos
	_capture_drag_origins()
	is_dragging_selection = not _drag_origins.is_empty()


## Snapshot the pre-drag geometry of every MOVABLE selected entity.
##
## LOCKED ENTITIES ARE SKIPPED HERE — this is where the lock is enforced for
## movement. A locked component (or trace: pcb_trace carries the same flag) may
## sit in the selection so the Unlock UI can still reach it, but it is never
## captured, so no delta is ever applied to it: drag a mixed selection and the
## locked members stay exactly where they are. Zones carry no lock in the board
## contract, so none is invented for them here.
##
## The lock IS now consulted by the delete paths too (adopted finding, A2
## review — see _delete_selection and _handle_eraser_click): a locked
## component or trace is skipped the same way it is skipped here.
## _delete_selected_zone below is the sole survivor of the three legacy
## single-kind delete functions (cold-review N2 deleted the other two as
## dead code); it is UNCHANGED and does not consult the lock (zones carry no
## lock concept, so there is nothing for it to consult) — it is no longer on
## the interactive Delete-key path, which now goes through _delete_selection
## exclusively, and survives only because test_zone_select_delete.gd calls it
## directly.
##
## Geometry is DUPLICATED, never referenced: waypoints/outline arrays are live
## model state, and a shared reference would make the "original" track the drag.
##
## GROUPS ARE GATED AS A UNIT (A4) — the second, different lock rule. The
## per-entity rule above lets a mixed selection drag its unlocked members and
## leave the locked ones behind; for a group that would tear one physical part in
## half, so _unit_locked() refuses EVERY member of a group with any locked member.
## Ungrouped components are untouched by it (see pcb_data.group_lock_blocks).
func _capture_drag_origins() -> void:
	_drag_origins = {}
	var comps := {}
	for comp_id in selected_components:
		var comp = data.get_component(comp_id)
		if comp != null and not _unit_locked(KIND_COMPONENT, comp_id):
			comps[comp_id] = comp.position
	var trace_pts := {}
	for trace_id in selected_trace_ids:
		var trace = data.get_trace(trace_id)
		if trace != null and not trace.locked and not trace.waypoints.is_empty():
			trace_pts[trace_id] = PackedVector2Array(trace.waypoints)
	var zone_pts := {}
	for zone_id in selected_zone_ids:
		var pts := PCBDataScript.zone_outline_points(data.get_zone(zone_id))
		if not pts.is_empty():
			zone_pts[zone_id] = pts
	if not comps.is_empty():
		_drag_origins[KIND_COMPONENT] = comps
	if not trace_pts.is_empty():
		_drag_origins[KIND_TRACE] = trace_pts
	if not zone_pts.is_empty():
		_drag_origins[KIND_ZONE] = zone_pts


## Translate every captured entity to `origin + delta`. ABSOLUTE from the
## captured origin, never incremental — an incremental nudge would accumulate the
## snap residue of every frame into a drift the user never asked for.
func _apply_drag_delta(delta: Vector2) -> void:
	for comp_id in _drag_origins.get(KIND_COMPONENT, {}):
		var comp = data.get_component(comp_id)
		if comp != null:
			comp.position = _drag_origins[KIND_COMPONENT][comp_id] + delta
	for trace_id in _drag_origins.get(KIND_TRACE, {}):
		data.set_trace_waypoints(trace_id, _translated(_drag_origins[KIND_TRACE][trace_id], delta))
	for zone_id in _drag_origins.get(KIND_ZONE, {}):
		data.set_zone_outline(zone_id, _translated(_drag_origins[KIND_ZONE][zone_id], delta))


static func _translated(points: PackedVector2Array, delta: Vector2) -> PackedVector2Array:
	var moved := PackedVector2Array()
	for p in points:
		moved.append(p + delta)
	return moved


## Finish a drag-move: journal each entity that actually moved, then take ONE
## history snapshot for the whole gesture.
##
## HISTORY SHAPE — the point of the whole unit. The geometry was already mutated
## during motion, so this is the mutate-then-snapshot order pcb_data documents
## (bug 019fb5ad791c): snapshot AFTER, or redo re-applies the pre-drag state and
## silently does nothing. begin_batch/end_batch is reused rather than a hand-rolled
## "loop then save_to_history", because that pair already means exactly "one
## save_to_history + one board_revision bump for everything inside" — so one undo
## restores every entity's pre-drag position, and a drag that moved nothing leaves
## _batch_touched false and snapshots NOTHING.
func _end_selection_drag() -> void:
	is_dragging_selection = false
	var moved_components: Array[String] = []
	var moved_total := 0

	data.begin_batch()

	for comp_id in _drag_origins.get(KIND_COMPONENT, {}):
		var comp = data.get_component(comp_id)
		var old_pos: Vector2 = _drag_origins[KIND_COMPONENT][comp_id]
		if comp == null or comp.position == old_pos:
			continue
		# Unchanged journal shape for a component move — the single-drag entry
		# every existing reader of the journal already parses.
		data.record_change("move_component", {
			"component_id": comp_id,
			"old_position": {"x": old_pos.x, "y": old_pos.y},
			"new_position": {"x": comp.position.x, "y": comp.position.y}
		})
		data.component_changed.emit(comp_id)
		component_moved.emit(comp_id, comp.position)
		moved_components.append(comp_id)
		moved_total += 1

	for trace_id in _drag_origins.get(KIND_TRACE, {}):
		var trace = data.get_trace(trace_id)
		var old_pts: PackedVector2Array = _drag_origins[KIND_TRACE][trace_id]
		if trace == null or trace.waypoints.is_empty() or trace.waypoints[0] == old_pts[0]:
			continue
		# move_trace / move_zone are new action names — no movement action existed
		# for either kind before this unit. Same shape as move_component, with the
		# entity's ANCHOR as the position (a polyline has no single point, and the
		# anchor is what the delta is defined against) plus the point count, so a
		# journal reader can tell a 2-point stub from a 40-bend route.
		data.record_change("move_trace", {
			"trace_id": trace_id,
			"old_position": {"x": old_pts[0].x, "y": old_pts[0].y},
			"new_position": {"x": trace.waypoints[0].x, "y": trace.waypoints[0].y},
			"point_count": old_pts.size()
		})
		data.trace_changed.emit(trace_id)
		moved_total += 1

	for zone_id in _drag_origins.get(KIND_ZONE, {}):
		var now_pts := PCBDataScript.zone_outline_points(data.get_zone(zone_id))
		var old_zone_pts: PackedVector2Array = _drag_origins[KIND_ZONE][zone_id]
		if now_pts.is_empty() or now_pts[0] == old_zone_pts[0]:
			continue
		data.record_change("move_zone", {
			"zone_id": zone_id,
			"old_position": {"x": old_zone_pts[0].x, "y": old_zone_pts[0].y},
			"new_position": {"x": now_pts[0].x, "y": now_pts[0].y},
			"point_count": old_zone_pts.size()
		})
		moved_total += 1

	# The label a single-component drag has always carried ("Move U1") survives
	# for the single-component case; anything else says how much it moved.
	var label := "Move selection (%d)" % moved_total
	if moved_total == 1 and moved_components.size() == 1:
		label = "Move " + moved_components[0]
	data.end_batch(label)

	# One data_changed for the gesture — the dirty-state feed the panel listens
	# on. Inside the batch it would have been the same signal; outside it, it is
	# emitted exactly once whether the drag moved one part or thirty.
	if moved_total > 0:
		data.data_changed.emit()

	_drag_origins = {}

#endregion


## Is this entity locked against deletion (and move)? Shared by
## _delete_selection and _handle_eraser_click (cold-review N1 — the same
## 3-way lock branch was duplicated between them) and kept beside
## _selection_of in the KIND_* idiom family, even though _capture_drag_origins
## does not itself call through here (it predates this helper and inlines the
## same rule for its own two kinds — left as-is, out of this unit's fence).
##
## Zones carry no lock concept in the board contract — checked against both
## the zone dict shape (pcb_data.gd: id/kind/outline/net/layer, no "locked"
## key) and board.go's `type Zone struct` (no Locked field) — so KIND_ZONE
## always reports unlocked.
func _is_entity_locked(kind: String, entity_id: String) -> bool:
	match kind:
		KIND_COMPONENT:
			var comp = data.get_component(entity_id)
			return comp != null and comp.locked
		KIND_TRACE:
			var trace = data.get_trace(entity_id)
			return trace != null and trace.locked
	return false


## THE WHOLE-UNIT LOCK — the second lock rule, and deliberately not the one above.
##
## _is_entity_locked answers "is THIS entity locked". This answers "is this entity
## unusable RIGHT NOW", which for a group member also means "is any of my
## group-mates locked" (pcb_data.group_lock_blocks). The two are kept as separate,
## separately-named helpers because the difference is the point: a mixed selection
## of loose parts drags/deletes its unlocked members and skips the locked ones,
## while a group is one physical part and does neither by halves.
##
## Every gesture that acts on components consults THIS one — drag
## (_capture_drag_origins), delete (_delete_selection), eraser
## (_handle_eraser_click), rotate (_rotate_selected) and the panel's offset edit
## (gated in the model itself). For an ungrouped component it is exactly
## _is_entity_locked, so nothing about a group-free board changes.
func _unit_locked(kind: String, entity_id: String) -> bool:
	if _is_entity_locked(kind, entity_id):
		return true
	return kind == KIND_COMPONENT and data != null and data.group_lock_blocks(entity_id)


## Remove one entity through its existing journalled remover, true if it was
## actually removed. Shared by _delete_selection and _handle_eraser_click —
## but ONLY the "does an entity of this kind still exist, and which single
## remove_* call clears it" question: the per-kind remove_component/
## remove_trace/remove_zone calls themselves are IRREDUCIBLE (different
## signatures, different model collections) and are not — and should not
## be — collapsed into one generic call (cold-review N1 judgement call).
func _remove_entity(kind: String, entity_id: String) -> bool:
	match kind:
		KIND_COMPONENT:
			if not data.has_component(entity_id):
				return false
			data.remove_component(entity_id)
			return true
		KIND_TRACE:
			if data.get_trace(entity_id) == null:
				return false
			data.remove_trace(entity_id)
			return true
		KIND_ZONE:
			return data.remove_zone(entity_id)
	return false


## Batch-delete the WHOLE mixed selection — components, traces and zones — as
## ONE undo step (item 019fb92f8b83, trash-can half; also the unified Delete/
## Backspace target — see _handle_key_input). Reuses the SAME begin_batch/
## end_batch idiom _end_selection_drag uses for the move gesture: every
## entity is removed through its existing journalled remover (_remove_entity,
## which is only a thin per-kind dispatch onto remove_component/remove_trace/
## remove_zone — no new removal path), then ONE save_to_history covers the
## lot, so a single undo restores everything. The outer walk is the ONE
## generic loop over KIND_COMPONENT/KIND_TRACE/KIND_ZONE via _selection_of —
## cold-review N1: this collapsed what were three near-identical hand-written
## loops (one per kind) into one, now that the per-kind lock check and
## removal call each live behind a single shared helper.
##
## LOCKED COMPONENTS/TRACES ARE SKIPPED (adopted finding, A2 review) — same
## semantics as the move path (_capture_drag_origins): a locked entity may
## sit in the selection, but it is never deleted. Zones are never locked (see
## _is_entity_locked), so every selected zone is removed regardless.
##
## A no-op selection (empty, or every member locked with no zone present)
## touches nothing: end_batch's own _batch_touched gate snapshots nothing —
## and, per cold-review N5, reports through the existing lock-feedback
## channel (component_lock_changed, the same one _lock_selected_components
## already uses) so an all-locked delete attempt isn't silent.
##
## After the batch, the WHOLE selection is cleared via _clear_selection() —
## including any locked member that survived, and regardless of whether
## anything was actually removed — DOCUMENTED CHOICE: "cleanly deselected"
## rather than "stays selected", matching every existing delete path's
## unconditional clear. Routing the clear through _clear_selection() (rather
## than clearing the three arrays inline) is cold-review N1 too: it is what
## makes every cleared component still emit component_deselected, exactly as
## a plain Escape-clear does.
func _delete_selection() -> void:
	if not data or not has_selection():
		return

	var removed := 0
	data.begin_batch()

	for kind in [KIND_COMPONENT, KIND_TRACE, KIND_ZONE]:
		for entity_id in _selection_of(kind):
			# _unit_locked, not _is_entity_locked (A4): a group with ANY locked
			# member refuses deletion whole, for the same reason it refuses to
			# drag by halves. Selection already expands to whole groups, so the
			# rest of this batch delete needs no group awareness at all.
			if _unit_locked(kind, entity_id):
				continue
			if _remove_entity(kind, entity_id):
				removed += 1

	data.end_batch("Delete selection (%d)" % removed)

	if removed == 0:
		component_lock_changed.emit("Selection is locked — nothing deleted")

	_clear_selection()
	queue_redraw()


## Eraser click (item 019fb934827776): pick exactly what the Select tool
## would pick (_entity_at), then delete THAT ONE entity as its own journalled
## change with its own history snapshot — deliberately NOT the
## begin_batch/end_batch idiom _delete_selection uses, since every click is
## its own undo step (three clicks on three kinds -> three separate undos, in
## reverse order).
##
## LOCKED COMPONENTS/TRACES ARE SKIPPED — _is_entity_locked, the same helper
## _delete_selection uses. A locked component in practice can never reach
## here anyway (data.get_component_at, behind _component_at/_entity_at,
## already skips locked components so clicks pass through to whatever is
## underneath); the trace check is the one that matters, since trace picking
## carries no such skip.
##
## Empty space, or a locked entity, is a no-op: no snapshot, no selection
## change, and — per the owner ruling this item shipped with — the tool
## STAYS ARMED either way (and stays SILENT either way — unlike the trash-
## can's all-locked case, an eraser miss is not reported; that is the
## "empty click does nothing" ruling itself, and a locked hit is just another
## kind of miss). There is no drag-sweep here by design (v1 scope).
func _handle_eraser_click(world_pos: Vector2) -> void:
	if not data:
		return
	var hit: Array = _entity_at(world_pos)
	var hit_kind: String = hit[0]
	var hit_id: String = hit[1]
	if hit_kind.is_empty() or _unit_locked(hit_kind, hit_id):
		return

	# A GROUPED component erases as a WHOLE UNIT (A4), matching what
	# minerva_pcb_delete_component does for the same component: the group is one
	# physical part, so erasing one of its footprints and leaving the rest would
	# be a delete the user cannot mean. Still ONE undo step per click — the
	# begin_batch/end_batch pair _delete_selection uses, rather than this path's
	# single save_to_history, because several components are removed.
	var group_id: String = data.component_group_id(hit_id) if hit_kind == KIND_COMPONENT else ""
	if not group_id.is_empty():
		data.begin_batch()
		var erased: Array = data.remove_group(hit_id)
		data.end_batch("Erase group (%d)" % erased.size())
		var was_selected := false
		for member_id in erased:
			if is_entity_selected(KIND_COMPONENT, member_id):
				_remove_from_selection(KIND_COMPONENT, member_id)
				was_selected = true
		if was_selected:
			selection_changed.emit()
		queue_redraw()
		return

	if not _remove_entity(hit_kind, hit_id):
		return
	data.save_to_history(_erase_label(hit_kind, hit_id))

	if is_entity_selected(hit_kind, hit_id):
		_remove_from_selection(hit_kind, hit_id)
		selection_changed.emit()
	queue_redraw()


## The eraser's per-click history label. Kept OFF _remove_entity (which the
## batch path shares and has no use for a per-entity label) — labels are
## eraser-only, so they live with its one caller.
func _erase_label(kind: String, entity_id: String) -> String:
	match kind:
		KIND_COMPONENT:
			return "Erase %s" % entity_id
		KIND_TRACE:
			return "Erase trace"
		KIND_ZONE:
			return "Erase zone"
	return "Erase"


## _delete_selected_zone is the LAST of what were three legacy single-kind
## delete paths (cold-review N2): _delete_selected and _delete_selected_trace
## are gone — the batch/eraser paths above superseded them and neither had
## any caller left once the Delete-key dispatch moved to _delete_selection.
## This one survives because test_zone_select_delete.gd calls it directly; if
## that caller ever goes away, this can fold into _delete_selection too.
func _delete_selected_zone() -> void:
	if selected_zone_ids.is_empty() or not data:
		return
	var removed := false
	for zone_id in selected_zone_ids:
		removed = data.remove_zone(zone_id) or removed
	if removed:
		data.save_to_history("Delete zone")
	selected_zone_ids.clear()
	selection_changed.emit()
	queue_redraw()


## Which committed zone a Select-tool click at `world_pos` picks, or "".
##
## Hit rules follow the RENDER language so what you see is what you can grab:
## a pour draws outline-only, so it hits like a path — near its outline; a
## keepout draws hatched ("filled"), so its interior hits too. Keepouts win
## ties because they render on top of pours (_draw_zones' two passes). A zone
## on a filtered-out layer, or with zones hidden entirely, never claims the
## click — same rule the pad/trace picks follow. Interior clicks on a pour
## deliberately fall through to box-select: the smart-remote GND pour spans
## nearly the whole board, and swallowing every interior click would kill
## box-selection everywhere.
func _zone_at(world_pos: Vector2) -> String:
	if not data or data.zones.is_empty() or not show_zones:
		return ""
	var tol := 3.0 / zoom
	var hit_pour := ""
	for zone in data.zones:
		var zone_id := str(zone.get("id", ""))
		if zone_id.is_empty():
			continue
		if not _zone_visible(zone):
			continue
		var pts := PCBDataScript.zone_outline_points(zone)
		if pts.size() < 3:
			continue
		if _is_keepout_zone(zone):
			if Geometry2D.is_point_in_polygon(world_pos, pts) or _point_near_outline(world_pos, pts, tol):
				return zone_id
		elif hit_pour.is_empty() and _point_near_outline(world_pos, pts, tol):
			hit_pour = zone_id
	return hit_pour


func _point_near_outline(p: Vector2, pts: PackedVector2Array, tol: float) -> bool:
	for i in pts.size():
		var closest := Geometry2D.get_closest_point_to_segment(p, pts[i], pts[(i + 1) % pts.size()])
		if p.distance_to(closest) <= tol:
			return true
	return false


## Lock all currently selected components and clear selection.
func _lock_selected_components() -> void:
	if selected_components.is_empty():
		return

	var names: PackedStringArray = []
	for comp_id in selected_components:
		var comp = data.get_component(comp_id)
		if comp:
			comp.locked = true
			names.append(comp_id)

	selected_components.clear()
	selection_changed.emit()

	if names.size() == 1:
		component_lock_changed.emit("Locked %s" % names[0])
	elif names.size() > 1:
		component_lock_changed.emit("Locked %d components" % names.size())

	queue_redraw()


## Unlock all locked components.
func _unlock_all_components() -> void:
	if not data:
		return

	var count := 0
	for comp_id in data.components:
		var comp = data.components[comp_id]
		if comp.locked:
			comp.locked = false
			count += 1

	if count > 0:
		component_lock_changed.emit("Unlocked all (%d)" % count)
		queue_redraw()


## Rotate the selected components 90° clockwise.
##
## TWO PATHS, deliberately (A4):
##
## UNGROUPED members take the ORIGINAL loop, unchanged line for line — including
## the fact that it consults NO lock at all. That missing lock check is a
## pre-existing defect (a locked loose part still turns under R); it is filed
## separately and is NOT fixed here, because "grouping changed how rotate treats
## my locked parts" would be a behaviour change smuggled in under this item.
##
## GROUPED members rotate as a RIGID BODY about the group anchor — positions orbit
## the anchor and each member's own rotation turns with it (pcb_data.rotate_group
## owns the geometry and the KiCad sign convention) — and ARE lock-gated by the
## whole-unit rule. Each group turns ONCE no matter how many of its members the
## selection holds (selection expands to whole groups, so it holds all of them).
##
## One save_to_history for the whole gesture either way, as before — now skipped
## entirely when nothing turned, so an all-locked refusal leaves no empty undo
## step behind.
func _rotate_selected() -> void:
	if selected_components.is_empty():
		return

	var group_ids: Array[String] = []
	var refused := 0
	var turned := 0

	for comp_id in selected_components:
		var group_id: String = data.component_group_id(comp_id)
		if not group_id.is_empty():
			if not group_ids.has(group_id):
				group_ids.append(group_id)
			continue
		var comp = data.get_component(comp_id)
		if comp:
			var old_rotation: float = comp.rotation
			comp.rotate_clockwise()
			data.record_change("rotate_component", {
				"component_id": comp_id,
				"old_rotation": old_rotation,
				"new_rotation": comp.rotation
			})
			data.component_changed.emit(comp_id)
			turned += 1

	for group_id in group_ids:
		if data.is_group_locked(group_id):
			refused += 1
			continue
		turned += data.rotate_group(data.group_anchor_id(group_id), 90.0).size()

	if turned > 0:
		data.save_to_history("Rotate components")
	elif refused > 0:
		component_lock_changed.emit("Group is locked — nothing rotated")

	queue_redraw()


## Group the selected components into ONE group (Ctrl+G / context menu).
##
## ONE history step: pcb_data.group_components journals a single
## `group_components` entry however many members it stamps, so a plain
## save_to_history — not the batch pair — is the right closing move.
##
## Re-adds the resulting members to the selection afterwards because a MERGE can
## pull in components that were not selected (grouping A+B when B was already
## grouped with C yields A+B+C), and what is selected after the gesture should be
## the group the user just made.
func _group_selection() -> void:
	if not data or selected_components.size() < 2:
		return
	var group_id: String = data.group_components(selected_components)
	if group_id.is_empty():
		return
	var members: Array = data.group_member_ids(group_id)
	data.save_to_history("Group %d components" % members.size())
	for member_id in members:
		_add_to_selection(KIND_COMPONENT, member_id)
	selection_changed.emit()
	queue_redraw()


## Dissolve the group(s) the selection touches (Ctrl+Shift+G / context menu).
## Positions are untouched; the members stay selected and become independently
## selectable again. ONE history step, same shape as _group_selection.
func _ungroup_selection() -> void:
	if not data or selected_components.is_empty():
		return
	var released: Array = data.ungroup_components(selected_components)
	if released.is_empty():
		return
	data.save_to_history("Ungroup %d components" % released.size())
	selection_changed.emit()
	queue_redraw()


## True when the selection is ALREADY exactly one group — the case where "Group
## Selection" would be a no-op (pcb_data.group_components returns "" for it), so
## the menu item is not offered.
func _selection_is_one_group() -> bool:
	if not data or selected_components.is_empty():
		return false
	var first: String = data.component_group_id(selected_components[0])
	if first.is_empty():
		return false
	for comp_id in selected_components:
		if data.component_group_id(comp_id) != first:
			return false
	return true


## True when the current selection has a group to dissolve — the enable rule the
## Ctrl+Shift+G context-menu item shares with _ungroup_selection.
func _selection_has_group() -> bool:
	if not data:
		return false
	for comp_id in selected_components:
		if not str(data.component_group_id(comp_id)).is_empty():
			return true
	return false


## Get a locked component at a world position (for unlock context menu).
func _get_locked_component_at(world_pos: Vector2) -> String:
	if not data:
		return ""
	for comp_id in data.components:
		var comp = data.components[comp_id]
		# Layer-filter aware, like the other picks: the context menu must not
		# offer to unlock a part the current layer view does not draw.
		if _component_visibility(comp) == CompVisibility.NONE:
			continue
		if comp.locked and comp.contains_point(world_pos):
			return comp_id
	return ""


## Check if any component is currently locked.
func _has_any_locked_components() -> bool:
	if not data:
		return false
	for comp_id in data.components:
		if data.components[comp_id].locked:
			return true
	return false


## Set the active tool mode. Emits tool_mode_changed on a real change.
## Entering OR leaving INSPECT_PIN clears any pin selection (contract §3:
## "switching modes clears selection") — one gate covers both directions.
##
## Leaving a zone tool discards any half-drawn polygon — and leaving the trace
## tool any half-drawn trace — under the same "switching modes clears in-progress
## state" rule. Silently: the user asked for another tool, so the abandoned draw
## is expected, not something to report.
func set_tool_mode(mode: ToolMode) -> void:
	if tool_mode != mode:
		if tool_mode == ToolMode.INSPECT_PIN or mode == ToolMode.INSPECT_PIN:
			_clear_inspect_pin_selection()
		if _is_zone_tool():
			_cancel_zone_draw(false)
		if tool_mode == ToolMode.TRACE:
			_cancel_trace_draw(false)
		tool_mode = mode
		tool_mode_changed.emit(mode)
		queue_redraw()

#endregion


#region Pin Inspector (WC-1)

## Bind the PcbAnnotationHost (duck-typed) that owns pad_at()/pin_info() — the
## canvas never hit-tests pads itself, it only drives the host through it.
func set_pin_inspector_host(host) -> void:
	_pin_inspector_host = host


## Toolbar toggle / Shift+P: arm INSPECT_PIN, or exit back to Select if already
## active (a true toggle, unlike the Select/Pan radio tools).
func _toggle_inspect_pin_mode() -> void:
	if tool_mode == ToolMode.INSPECT_PIN:
		_exit_inspect_pin_mode()
	else:
		set_tool_mode(ToolMode.INSPECT_PIN)


func _exit_inspect_pin_mode() -> void:
	set_tool_mode(ToolMode.SELECT)


## Click handling for INSPECT_PIN: nearest pad (host.pad_at, default 5mm radius
## per contract §2) → host.pin_info → pin_selected; a miss clears (empty dict).
func _handle_inspect_pin_click(world_pos: Vector2) -> void:
	var info := _lookup_pin_info(world_pos)
	pin_selected.emit(info)
	queue_redraw()


## Hover feedback: nearest-pad label at the cursor (native L1444 parity).
## Redraws only on an actual label change, not every motion event.
func _update_inspect_hover(world_pos: Vector2, screen_pos: Vector2) -> void:
	_inspect_hover_screen_pos = screen_pos
	var label := ""
	if _pin_inspector_host != null and _pin_inspector_host.has_method("pad_at"):
		var hit: Dictionary = _pin_inspector_host.pad_at(
			world_pos, 5.0, _inspectable_component_filter())
		if not hit.is_empty():
			label = "%s.%s" % [str(hit.get("component", "")), str(hit.get("pin", ""))]
	if label != _inspect_hover_label:
		_inspect_hover_label = label
		queue_redraw()


## host.pad_at → host.pin_info in one step; {} when the host is unbound, no pad
## is within radius, or pin_info can't resolve the hit (defensive — pad_at and
## pin_info are backed by the same live board model so this should not diverge).
func _lookup_pin_info(world_pos: Vector2) -> Dictionary:
	if _pin_inspector_host == null or not _pin_inspector_host.has_method("pad_at"):
		return {}
	var hit: Dictionary = _pin_inspector_host.pad_at(
		world_pos, 5.0, _inspectable_component_filter())
	if hit.is_empty():
		return {}
	if not _pin_inspector_host.has_method("pin_info"):
		return {}
	return _pin_inspector_host.pin_info(str(hit.get("component", "")), str(hit.get("pin", "")))


## Layer-view predicate for the pin inspector (bug 019fb59c1a89): a pad is
## hover/click-inspectable only when the current layer view draws its part.
## FULL and LANDS both pass — a THT part viewed from the other side shows its
## lands, and those lands are exactly what the inspector should still hit.
## NONE (an SMD-only part mounted on a hidden layer) does not. The 5.0 radius
## at the call sites is contract §2's default, restated because GDScript has
## no named arguments. MCP lookups deliberately do NOT use this predicate.
func _inspectable_component_filter() -> Callable:
	return func(comp_id: String) -> bool:
		if not data:
			return true
		var comp = data.get_component(comp_id)
		return comp != null and _component_visibility(comp) != CompVisibility.NONE


## Clears any live pin selection/hover (mode exit, mode switch, empty click).
func _clear_inspect_pin_selection() -> void:
	_inspect_hover_label = ""
	pin_selected.emit({})

#endregion


#region Zone Authoring (epoch 6 unit 4)

## Gesture (Illustrator shape-drawing family, matching the single-trace hint
## tool's grammar rather than inventing a second one):
##   ARMED   --left-click-->        place a vertex
##   DRAWING --double-click/Enter-> close and commit (needs ≥3 vertices)
##   DRAWING --Esc/right-click-->   cancel
##   DRAWING --tool switch-->       cancel (silently — see set_tool_mode)
##
## This tool AUTHORS A BOARD ENTITY (a Zone in the model, which serializes into
## the board YAML), unlike the hint tools which author annotations. That is why it
## lives on the canvas tool surface and journals + snapshots like any other
## interactive board edit, and why every refusal is fail-closed: see
## pcb_data.zone_author_error for why an invalid zone is worse than a refused
## gesture (it makes the WHOLE board unserializable).

func _is_zone_tool() -> bool:
	return tool_mode == ToolMode.ZONE_POUR or tool_mode == ToolMode.ZONE_KEEPOUT


## Zone kind the armed tool authors — the same two strings the render path
## normalises through PCBDataScript.zone_kind().
func _zone_tool_kind() -> String:
	return "keepout" if tool_mode == ToolMode.ZONE_KEEPOUT else "copper_pour"


## The canonical copper layer a new zone is placed on.
##
## The panel's zone LAYER picker names it outright when the user has chosen one —
## that choice is the whole point of the control, so it outranks everything below
## it (owner ruling, epoch 6 boundary: "I can't set the layer of a pour"). It is
## still checked for copper-ness rather than trusted: the override is a String set
## from outside this class, and copper is the only thing a zone may be poured on.
##
## With the picker left on "View layer" (override "", the resting state), the
## toolbar layer filter names it whenever it is scoped to one copper layer — the
## layer you are LOOKING at is the layer you are drawing on. Under "All" there is
## no such answer, so it falls back to ZONE_DEFAULT_LAYER ("bottom", the classic
## ground-pour side); the tool button's tooltip states that fallback outright so
## it is never a silent choice. Fails visible (returns "") when the board does not
## declare the fallback layer at all, rather than authoring copper onto a layer
## the board has never heard of.
##
## _draw_zone_preview's arming label calls THIS function, so the label always
## names the layer the commit will actually use, override or filter.
func zone_author_layer() -> String:
	if not zone_layer_override.is_empty() and PcbLayerStack.is_copper(zone_layer_override):
		return zone_layer_override
	return _author_layer(ZONE_DEFAULT_LAYER)


## The layer-from-filter rule shared by every copper-authoring tool on this
## canvas (unit 5 lifted it out of zone_author_layer verbatim rather than writing
## a second copy for traces). ONLY the "All" fallback differs between tools — a
## pour defaults to the ground side, a trace to the component side — so that is
## the one thing passed in.
func _author_layer(default_layer: String) -> String:
	if not trace_layer_filter.is_empty() and trace_layer_filter != "all" \
			and PcbLayerStack.is_copper(trace_layer_filter):
		return trace_layer_filter
	var declared: Array = data.layers if data else []
	if declared.is_empty() or default_layer in declared:
		return default_layer
	for layer in declared:
		if PcbLayerStack.is_copper(str(layer)):
			return str(layer)
	return ""


## Where an AUTHORING click lands, in board mm — the ONE snap rule for every
## drawing tool on this canvas (zone vertices AND trace waypoints; unit 6's
## boundary fix replaced the two identical per-tool copies with this).
##
## It does NOT snap like a component drag, and that is the point. Until the epoch
## 6 boundary both authoring tools called data.snap_to_grid() on the reasoning
## that "a pour corner on the same grid as the parts it surrounds is the useful
## default" — SUPERSEDED by owner ruling ("pours have poor granularity; snaps too
## far"). Parts must land on the placement pitch; a pour bend or a trace waypoint
## must land where the user pointed, and on a 2.54 mm grid the nearest legal point
## is up to 1.27 mm away. Authoring clicks now take the QUARTER grid
## (data.snap_author_point, 0.635 mm by default) instead.
##
## Ctrl (or Cmd on a Mac) held at click time bypasses snapping entirely, the
## standard "place it exactly there" modifier. Read from Input at the moment of
## the click rather than plumbed through the InputEvent: this is called from the
## click and motion handlers, whose events already carry the modifier state, but
## reading it here keeps ONE answer for both callers and both gestures — and a
## preview that used a different rule from the commit would be a lie. That read
## now lives in _snap_bypass_held(), shared with the drag-move's no-snap modifier
## (item 019fb93185c8) so authoring and moving cannot disagree about the key.
##
## Pad ENDPOINTS deliberately never come through here — a trace must meet the
## pad's actual centre (see _finish_trace_on_pad).
func _author_point(world_pos: Vector2) -> Vector2:
	if _snap_bypass_held():
		return world_pos
	if snap_to_grid and data:
		return data.snap_author_point(world_pos)
	return world_pos


func _handle_zone_click(world_pos: Vector2, is_double_click: bool) -> void:
	# The second press of a physical double-click arrives AFTER the first has
	# already placed its vertex, so it closes the polygon instead of placing a
	# duplicate one on top of it.
	if is_double_click:
		_commit_zone()
		return
	_zone_points.append(_author_point(world_pos))
	_zone_has_preview = false
	queue_redraw()


## Close the in-progress polygon into a real zone entity.
##
## HISTORY ORDER — one idiom, everywhere (bug 019fb5ad791c closed the split):
## _restore_state applies a snapshot wholesale and undo() steps to
## history[index - 1], so the snapshot a step carries must be the state AFTER
## that step. Snapshot BEFORE the mutation and undo still works (the previous
## snapshot is the pre-mutation state either way) but redo re-applies the
## pre-mutation state and silently does nothing. Measured, not assumed.
##
## create_zone emits data_changed, which is what marks the tab dirty (PCBPanel
## relays it to content_changed) — there is no separate dirty flag to set.
func _commit_zone() -> void:
	if not data or not _is_zone_tool():
		return
	var kind := _zone_tool_kind()
	# A keepout commits with NO net (owner ruling 2026-07-30) — see
	# zone_author_net. The picker's leftover selection is dropped rather than
	# quietly attached, so a keepout drawn after a pour is not net-scoped by
	# accident; net-scoped keepouts are expressible in the board contract but are
	# not something this tool can currently ask for.
	var net := "" if kind == "keepout" else zone_author_net
	var layer := zone_author_layer()
	var refusal: String = data.zone_author_error(net, layer, _zone_points.size(), kind)
	if not refusal.is_empty():
		# Keep the placed vertices: the fix for "pick a net" is to pick a net and
		# press Enter again, not to redraw the whole outline.
		zone_tool_message.emit(refusal)
		return

	var zone: Dictionary = data.create_zone(net, layer, _zone_points, kind)
	if zone.is_empty():
		# zone_author_error already passed, so this is a model-side refusal we did
		# not anticipate. Report it rather than leaving a silent no-op behind.
		zone_tool_message.emit("Zone was refused by the board model — see the log.")
		return
	data.save_to_history("Add %s" % ("keepout" if kind == "keepout" else "pour"))
	var point_count := _zone_points.size()
	_reset_zone_draw()
	# The net is named only when there is one — a netless keepout would otherwise
	# report "(, 3 points)", an empty slot that reads as a bug.
	zone_tool_message.emit("Added %s on %s (%s%d points)." % [
		"keepout" if kind == "keepout" else "pour", layer,
		"" if net.is_empty() else "%s, " % net, point_count])
	queue_redraw()


## Discard the in-progress polygon. `announce` is false for a tool switch (the
## user already knows) and true for an explicit Esc/right-click cancel.
func _cancel_zone_draw(announce: bool) -> void:
	if _zone_points.is_empty():
		return
	_reset_zone_draw()
	if announce:
		zone_tool_message.emit("Zone cancelled.")
	queue_redraw()


func _reset_zone_draw() -> void:
	_zone_points = PackedVector2Array()
	_zone_has_preview = false


## Draw the polygon being born, in the SAME visual language committed zones use
## (net colour for a pour, the keepout amber for a keepout, same outline width) so
## it reads as the zone itself rather than as a generic rubber band. Placed
## vertices get dots — the one thing a committed zone does not draw, because it is
## the one thing only an in-progress polygon has.
func _draw_zone_preview() -> void:
	if _zone_points.is_empty():
		return

	var is_keepout := tool_mode == ToolMode.ZONE_KEEPOUT
	var color := zone_keepout_color
	if not is_keepout:
		color = zone_pour_fallback_color
		var net = data.get_net(zone_author_net) if data else null
		if net:
			color = net.color

	var screen_pts := PackedVector2Array()
	for p in _zone_points:
		screen_pts.append(world_to_screen(p))
	var cursor_pt := world_to_screen(_zone_preview) if _zone_has_preview else Vector2.ZERO

	var open_path := screen_pts.duplicate()
	if _zone_has_preview:
		open_path.append(cursor_pt)
	if open_path.size() >= 2:
		draw_polyline(open_path, Color(color, zone_outline_alpha), zone_outline_width_px)

	# The closing edge back to the first vertex is dimmer: it is where the polygon
	# WILL close, not an edge the user has drawn yet.
	var last_pt: Vector2 = open_path[open_path.size() - 1]
	if open_path.size() >= 3:
		draw_line(last_pt, screen_pts[0], Color(color, ZONE_PREVIEW_CLOSE_ALPHA), zone_outline_width_px)

	for pt in screen_pts:
		draw_circle(pt, ZONE_PREVIEW_VERTEX_RADIUS_PX, Color(color, zone_outline_alpha))

	# Arming label at the origin vertex — what this polygon will BECOME, mirroring
	# the single-trace tool's "Single Trace from U1.3" preview label. Says the
	# layer explicitly so the "All → bottom" fallback is visible while drawing.
	if font != null:
		var layer := zone_author_layer()
		var label := "Keepout @ %s" % layer if is_keepout \
			else "Pour %s @ %s" % [zone_author_net if not zone_author_net.is_empty() else "(no net)", layer]
		label += "  ·  %d pts" % _zone_points.size()
		draw_string(font, screen_pts[0] + Vector2(6.0, -6.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(color, zone_outline_alpha))

#endregion


#region Trace Authoring (epoch 6 unit 5)

## Gesture (KiCad's route-a-track grammar, expressed in the same click-per-point
## family the zone tools use — one gesture grammar on this canvas, not three):
##   ARMED   --click a pad-->        start; net + layer frozen from that pad
##   DRAWING --left-click-->         place a waypoint
##   DRAWING --click ANY pad-->      finish at that pad's centre and commit
##   DRAWING --double-click/Enter--> finish at the last waypoint (dangling)
##   DRAWING --Esc/right-click-->    cancel
##   DRAWING --tool switch-->        cancel (silently — see set_tool_mode)
##
## This is the DIRECT-AUTHORING sibling of the Hints-group trace tool, not a
## replacement for it (owner ruling, umbrella docket 019fb5720368): that tool
## authors a route HINT the router consumes; this one authors the Trace entity
## itself — model, canvas and board YAML — bypassing the router entirely.
##
## Starting REQUIRES a pad hit, because a trace's net is INHERITED rather than
## chosen. That is why this tool has no net picker where the zone tools have one:
## pads are the only place on the board where "which net is this?" already has an
## answer, and copper that invents its own net answer is copper on the wrong net.

## Resolve a click to a pad and its net.
##
## Reuses the pin inspector's hit test — host.pad_at, the SOLE pad hit-test
## implementation (see the _pin_inspector_host declaration) — at a tighter radius
## (TRACE_PAD_SNAP_MM; see there for why). The net comes from
## data.find_net_for_pin rather than host.pin_info: pin_info is the same lookup
## plus net_members and trace_ids, work this path would build on every click and
## throw away. Same source of truth, one field of it.
##
## {} on a miss AND when no host is bound — with no hit test there is no pad, so
## the tool refuses to start rather than guessing a net.
func _trace_pad_at(world_pos: Vector2) -> Dictionary:
	if _pin_inspector_host == null or not _pin_inspector_host.has_method("pad_at"):
		return {}
	var hit: Dictionary = _pin_inspector_host.pad_at(world_pos, TRACE_PAD_SNAP_MM)
	if hit.is_empty():
		return {}
	var comp := str(hit.get("component", ""))
	var pin := str(hit.get("pin", ""))
	var pad_net := ""
	if data != null:
		pad_net = data.find_net_for_pin(comp, pin)
	return {
		"ref": "%s.%s" % [comp, pin],
		"position": hit.get("position", Vector2.ZERO),
		"net": pad_net,
	}


## The width a new trace is drawn and committed at, in mm.
##
## The panel's width box names it when the user has set one (owner question at
## the epoch 6 boundary: "how can I choose fatter traces than default?" — before
## this there was no UI at all, only design_rules.trace_width_mm). Otherwise the
## board's own design rule answers, exactly as it did before the control existed.
##
## ONE answer for both the preview and the commit path, which is the whole reason
## it is a function: _draw_trace_preview renders at this width, _commit_trace
## passes it to create_trace_entity, so what lands is what was on screen. The
## no-model branch is the preview's alone (commit returns early without `data`)
## and borrows PCBData's own default rather than repeating the number.
func trace_author_width() -> float:
	if trace_width_override > 0.0:
		return trace_width_override
	if data:
		return data.authored_trace_width()
	return PCBDataScript.DEFAULT_TRACE_WIDTH_MM


## The copper layer a new trace is placed on — the layer-filter rule shared with
## the zone tools, defaulting to TRACE_DEFAULT_LAYER ("top") under "All".
func trace_author_layer() -> String:
	return _author_layer(TRACE_DEFAULT_LAYER)


func _handle_trace_click(world_pos: Vector2, is_double_click: bool) -> void:
	# The second press of a physical double-click arrives AFTER the first has
	# already placed its waypoint, so it ends the trace there instead of stacking
	# a duplicate point on top of it.
	if is_double_click:
		_commit_trace()
		return

	var hit := _trace_pad_at(world_pos)

	if _trace_points.is_empty():
		_start_trace(hit)
		return

	if not hit.is_empty():
		_finish_trace_on_pad(hit)
		return

	_trace_append_point(_author_point(world_pos))
	_trace_has_preview = false
	queue_redraw()


## Append a point unless it lands on top of the previous one. Returns whether it
## was appended.
##
## Coincident points are zero-length segments — not copper, just geometry that
## every downstream consumer (length, DRC, Gerber) has to special-case. Two
## gestures produce them naturally and neither is a mistake worth punishing: grid
## snapping can round two nearby clicks onto the same intersection, and a second
## click on the pad the trace STARTED from would otherwise commit a whole
## zero-length trace. Dropping the duplicate turns that second case into a
## one-point trace, which the ≥2-points rule then refuses with a real message.
func _trace_append_point(point: Vector2) -> bool:
	if not _trace_points.is_empty() \
			and _trace_points[_trace_points.size() - 1].is_equal_approx(point):
		return false
	_trace_points.append(point)
	return true


## First click: adopt the pad's net + the current layer and place the start
## point at the pad's centre. Both refusals are transient messages, not silent
## no-ops — a tool that does nothing when clicked is indistinguishable from a
## broken one.
func _start_trace(hit: Dictionary) -> void:
	if hit.is_empty():
		trace_tool_message.emit("Start a trace on a pad — that is where its net comes from.")
		return
	var pad_net := str(hit.get("net", ""))
	if pad_net.is_empty():
		trace_tool_message.emit("Pad %s is on no net — a trace inherits its net from the pad it starts on."
			% str(hit.get("ref", "")))
		return
	var layer := trace_author_layer()
	if layer.is_empty():
		trace_tool_message.emit("This board declares no copper layer to draw a trace on.")
		return

	_trace_net = pad_net
	_trace_layer = layer
	_trace_start_ref = str(hit.get("ref", ""))
	_trace_points = PackedVector2Array([hit.get("position", Vector2.ZERO)])
	_trace_has_preview = false
	trace_tool_message.emit("Trace from %s (%s) on %s — click waypoints, click a pad to finish." % [
		_trace_start_ref, _trace_net, _trace_layer])
	queue_redraw()


## Finish on a pad: the trace ends at that pad's centre.
##
## NO SAME-NET ENFORCEMENT (owner ruling this round): DRC is the correctness net,
## not the drawing tool. A trace landing on a different net's pad is a short, and
## a short the user drew deliberately is still theirs to draw — but it is named
## out loud, both nets, rather than committed quietly.
func _finish_trace_on_pad(hit: Dictionary) -> void:
	_trace_append_point(hit.get("position", Vector2.ZERO))
	_trace_has_preview = false
	var end_net := str(hit.get("net", ""))
	var warning := ""
	if not end_net.is_empty() and end_net != _trace_net:
		warning = "ends on %s, which is on net %s, not %s — that is a short; DRC will flag it." % [
			str(hit.get("ref", "")), end_net, _trace_net]
	elif end_net.is_empty():
		warning = "ends on %s, which is on no net." % str(hit.get("ref", ""))
	_commit_trace(warning)


## Turn the in-progress polyline into a real Trace entity.
##
## HISTORY ORDER — snapshots AFTER the mutation, the MOVE idiom, for the reason
## spelled out at length in _commit_zone: _restore_state applies a snapshot
## wholesale and undo() steps to history[index - 1], so the snapshot a step
## carries must be the state AFTER that step. Ctrl+Z removes the trace and
## Ctrl+Shift+Z puts it back.
##
## create_trace_entity → add_trace emits data_changed, which is what marks the tab
## dirty (PCBPanel relays it to content_changed) and what repaints the canvas — so
## the committed trace appears through the ordinary _draw_traces path, with no
## special case for "just drawn". There is no separate dirty flag to set.
func _commit_trace(warning: String = "") -> void:
	if not data or tool_mode != ToolMode.TRACE:
		return
	var refusal: String = data.trace_author_error(_trace_net, _trace_layer, _trace_points.size())
	if not refusal.is_empty():
		# Keep the placed points: the fix for "needs 2 points" is another click,
		# not redrawing from scratch.
		trace_tool_message.emit(refusal)
		return

	# create_trace_entity's contract is unchanged: it reads a positive width as
	# explicit and falls back to authored_trace_width() on anything else. Passing
	# the resolved width keeps ONE place where the override is applied, and the
	# summary below then names the width the trace actually got.
	var width: float = trace_author_width()
	var trace = data.create_trace_entity(_trace_net, _trace_layer, _trace_points, width)
	if trace == null:
		# trace_author_error already passed, so this is a model-side refusal we did
		# not anticipate. Report it rather than leaving a silent no-op behind.
		trace_tool_message.emit("Trace was refused by the board model — see the log.")
		return
	data.save_to_history("Add trace")

	var summary := "Added trace on %s (%s, %d points, %.2f mm)." % [
		_trace_layer, _trace_net, _trace_points.size(), width]
	_reset_trace_draw()
	# ONE message, not two — the panel's transient status shows the latest, so a
	# separate warning emit would simply erase the confirmation (or be erased by
	# it). The warning is folded into the sentence instead.
	trace_tool_message.emit(summary if warning.is_empty() else "%s WARNING: it %s" % [summary, warning])
	queue_redraw()


## Discard the in-progress trace. `announce` is false for a tool switch (the user
## already knows) and true for an explicit Esc/right-click cancel.
func _cancel_trace_draw(announce: bool) -> void:
	if _trace_points.is_empty():
		return
	_reset_trace_draw()
	if announce:
		trace_tool_message.emit("Trace cancelled.")
	queue_redraw()


func _reset_trace_draw() -> void:
	_trace_points = PackedVector2Array()
	_trace_net = ""
	_trace_layer = ""
	_trace_start_ref = ""
	_trace_has_preview = false


## Draw the trace being born in the SAME visual language _draw_single_trace uses
## for committed copper — the layer's trace colour, the width it will actually
## commit at (trace_author_width) scaled by zoom — so it reads as the trace itself
## rather than as a generic rubber band, and so what lands on commit is what was
## on screen. The segment running to the cursor is dimmer: it is proposed, not
## placed.
func _draw_trace_preview() -> void:
	if _trace_points.is_empty():
		return

	# Same rule _draw_single_trace applies — one colour source for committed and
	# in-progress copper, per-layer palette included.
	var color := _trace_layer_color(str(_trace_layer))
	var width_px := maxf(trace_author_width() * zoom, 1.0)

	var screen_pts := PackedVector2Array()
	for p in _trace_points:
		screen_pts.append(world_to_screen(p))

	if screen_pts.size() >= 2:
		draw_polyline(screen_pts, color, width_px)
	if _trace_has_preview:
		draw_line(screen_pts[screen_pts.size() - 1], world_to_screen(_trace_preview),
			Color(color, TRACE_PREVIEW_RUBBER_ALPHA), width_px)

	# Placed waypoints get dots — the one thing a committed trace does not draw
	# (unless selected), because it is the one thing only an in-progress trace has.
	for pt in screen_pts:
		draw_circle(pt, TRACE_PREVIEW_VERTEX_RADIUS_PX, color)

	# Arming label at the start pad — what this polyline will BECOME, mirroring
	# the zone preview's label. Names the layer explicitly so the "All → top"
	# fallback is visible while drawing, not discovered afterwards.
	if font != null:
		var label := "Trace %s @ %s" % [_trace_net, _trace_layer]
		if not _trace_start_ref.is_empty():
			label = "Trace from %s (%s) @ %s" % [_trace_start_ref, _trace_net, _trace_layer]
		label += "  ·  %d pts" % _trace_points.size()
		draw_string(font, screen_pts[0] + Vector2(6.0, -6.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

#endregion


#region Public API

## Set the PCB data model, wiring reactive redraws.
func set_data(new_data) -> void:
	if data:
		if data.data_changed.is_connected(_on_data_changed):
			data.data_changed.disconnect(_on_data_changed)
		if data.structure_changed.is_connected(_on_structure_changed):
			data.structure_changed.disconnect(_on_structure_changed)

	data = new_data

	if data:
		data.data_changed.connect(_on_data_changed)
		data.structure_changed.connect(_on_structure_changed)

	_center_view()
	queue_redraw()


## Get current selection. Component-only by design — the panel's inspector and
## status bar have always meant components by "the selection". The other two
## kinds have their own getters below rather than being folded in here, because a
## caller that asked for components must never be handed trace ids.
func get_selected_components() -> Array[String]:
	return selected_components.duplicate()


## The selected trace ids (mixed multi-select, 019fb92f8b83).
func get_selected_traces() -> Array[String]:
	return selected_trace_ids.duplicate()


## The selected zone ids (mixed multi-select, 019fb92f8b83).
func get_selected_zones() -> Array[String]:
	return selected_zone_ids.duplicate()


## Select a component programmatically.
func select_component(component_id: String, add_to_selection: bool = false) -> void:
	if not add_to_selection:
		_clear_selection()

	if data.has_component(component_id) and not is_entity_selected(KIND_COMPONENT, component_id):
		_add_to_selection(KIND_COMPONENT, component_id)
		selection_changed.emit()
		queue_redraw()


## Zoom to fit all components.
func zoom_to_fit() -> void:
	if not data or data.components.is_empty():
		_center_view()
		return

	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)

	for comp_id in data.components:
		var comp = data.components[comp_id]
		var bounds: Rect2 = comp.get_bounding_rect()
		min_pos.x = minf(min_pos.x, bounds.position.x)
		min_pos.y = minf(min_pos.y, bounds.position.y)
		max_pos.x = maxf(max_pos.x, bounds.end.x)
		max_pos.y = maxf(max_pos.y, bounds.end.y)

	var margin := 10.0
	min_pos -= Vector2(margin, margin)
	max_pos += Vector2(margin, margin)

	var content_size := max_pos - min_pos
	var content_center := (min_pos + max_pos) / 2.0

	if content_size.x <= 0.0 or content_size.y <= 0.0:
		_center_view()
		return

	var zoom_x := size.x / content_size.x
	var zoom_y := size.y / content_size.y
	zoom = minf(zoom_x, zoom_y)
	zoom = clampf(zoom, min_zoom, max_zoom)

	pan_offset = -content_center * zoom

	zoom_changed.emit(zoom)
	view_changed.emit()
	queue_redraw()


## Center the view on a world-mm point at an explicit zoom (px/mm), clamped to
## [min_zoom, max_zoom]. Camera convention: world_to_screen = world*zoom +
## pan_offset + size/2, so the world point at the screen centre is
## -pan_offset/zoom; centring on `center_mm` therefore means
## pan_offset = -center_mm*zoom (identical to zoom_to_fit). Drives the MCP
## set_view tool so an agent — and the human watching — can pan/zoom the board.
func set_view_center_zoom(center_mm: Vector2, new_zoom: float) -> void:
	zoom = clampf(new_zoom, min_zoom, max_zoom)
	pan_offset = -center_mm * zoom
	zoom_changed.emit(zoom)
	view_changed.emit()
	queue_redraw()


## Multiply the current zoom by `factor` (clamped), keeping the world point at the
## screen centre fixed. factor > 1 zooms IN, < 1 zooms OUT.
func zoom_by(factor: float) -> void:
	if factor <= 0.0 or zoom == 0.0:
		return
	set_view_center_zoom(-pan_offset / zoom, zoom * factor)


## Frame an arbitrary world-mm rect to fill the viewport (with a small mm margin)
## — e.g. to inspect one component. Same fit math as zoom_to_fit, for a sub-region.
func frame_rect(bounds: Rect2, margin_mm: float = 2.0) -> void:
	var content := bounds.grow(margin_mm)
	if content.size.x <= 0.0 or content.size.y <= 0.0 or size.x <= 0.0 or size.y <= 0.0:
		return
	set_view_center_zoom(content.get_center(),
		minf(size.x / content.size.x, size.y / content.size.y))


## Current camera as plain data (for the set_view tool to report back): zoom
## (px/mm), the world-mm point at the screen centre, and the visible world-mm rect.
func get_view() -> Dictionary:
	var center_mm: Vector2 = (-pan_offset / zoom) if zoom != 0.0 else Vector2.ZERO
	var vis: Vector2 = (size / zoom) if zoom != 0.0 else Vector2.ZERO
	return {
		"zoom": zoom,
		"center_x_mm": center_mm.x,
		"center_y_mm": center_mm.y,
		"visible": {
			"x_mm": center_mm.x - vis.x / 2.0,
			"y_mm": center_mm.y - vis.y / 2.0,
			"width_mm": vis.x,
			"height_mm": vis.y,
		},
	}


## Render the board to an Image OFF-SCREEN — independent of which editor tab is
## focused or how the plugin panel is hosted. This is the get_image MCP capture
## path (bug 019f7876e3d4): it RESTORES the capture_to_image the native->plugin
## port wrongly stripped (see the "STRIPPED vs legacy" note at the top of this
## file — "MCP export lives in the worker" was incorrect). The prior replacement
## screenshotted the live window viewport and cropped, which returned only the
## editor background for a plugin-hosted / non-foreground panel.
##
## Builds a private SubViewport, renders a FRESH copy of this canvas over the SAME
## board data at the requested size, waits for the render to actually land
## (RenderingServer.frame_post_draw), then reads the texture. Honors width/height.
## fit=true frames the whole board; fit=false reproduces THIS canvas's current
## camera (the minerva_pcb_set_view detail) — the world point at the screen centre
## is -pan_offset/zoom regardless of viewport size, so copying zoom+pan_offset
## preserves centre+scale across the differing size. Returns null in a bare
## --headless run (no render target) or when detached, so the caller emits its
## graceful null envelope (test contract §1c).
func capture_to_image(width: int, height: int, fit: bool = true) -> Image:
	if DisplayServer.get_name() == "headless":
		return null
	if data == null or not is_inside_tree():
		return null
	var tree := get_tree()
	if tree == null:
		return null

	var viewport := SubViewport.new()
	viewport.size = Vector2i(maxi(width, 1), maxi(height, 1))
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	var copy = get_script().new()
	copy.size = Vector2(viewport.size)
	copy.data = data
	# Mirror the visible view options so the capture matches what the user sees.
	copy.show_grid = show_grid
	copy.show_ratsnest = show_ratsnest
	copy.show_traces = show_traces
	copy.show_labels = show_labels
	copy.show_pins = show_pins
	copy.show_pads = show_pads
	copy.show_silk = show_silk
	copy.show_courtyard = show_courtyard
	copy.show_unresolved_badges = show_unresolved_badges
	copy.snap_to_grid = snap_to_grid
	copy.trace_layer_filter = trace_layer_filter

	viewport.add_child(copy)
	add_child(viewport)

	if fit:
		_frame_board_for_capture(copy)
	else:
		copy.zoom = zoom
		copy.pan_offset = pan_offset

	copy.queue_redraw()
	# Yield ONE idle frame (process_frame fires even when the app is otherwise
	# idle) to reach a clean main-thread point, then FORCE a synchronous draw so
	# the offscreen viewport renders NOW. The previous code awaited
	# RenderingServer.frame_post_draw, which does NOT fire while the app is
	# idle/unfocused — so a 2nd/3rd capture stalled past the MCP timeout. force_draw
	# renders deterministically without depending on the throttled main loop.
	await tree.process_frame
	RenderingServer.force_draw(false)

	var img: Image = viewport.get_texture().get_image()

	viewport.remove_child(copy)
	copy.queue_free()
	remove_child(viewport)
	viewport.queue_free()
	return img


## Fit the whole board (+5% margin) into a capture copy sized to the offscreen
## viewport. Same math as zoom_to_fit, but against the COPY's size (the requested
## capture dims), not the on-screen canvas size.
func _frame_board_for_capture(copy) -> void:
	var min_pos := Vector2.ZERO
	var max_pos := Vector2(data.board_width, data.board_height)
	for comp_id in data.components:
		var b: Rect2 = data.components[comp_id].get_bounding_rect()
		min_pos.x = minf(min_pos.x, b.position.x)
		min_pos.y = minf(min_pos.y, b.position.y)
		max_pos.x = maxf(max_pos.x, b.end.x)
		max_pos.y = maxf(max_pos.y, b.end.y)
	var content := max_pos - min_pos
	var margin := content * 0.05
	min_pos -= margin
	max_pos += margin
	content = max_pos - min_pos
	if content.x <= 0.0 or content.y <= 0.0:
		return
	copy.zoom = clampf(minf(copy.size.x / content.x, copy.size.y / content.y),
		copy.min_zoom, copy.max_zoom)
	copy.pan_offset = -((min_pos + max_pos) / 2.0) * copy.zoom


func _on_data_changed() -> void:
	queue_redraw()


func _on_structure_changed() -> void:
	queue_redraw()

#endregion
