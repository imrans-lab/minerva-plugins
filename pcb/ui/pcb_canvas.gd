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
## Bus tool (S3+S4, docket 019fb572b888): the pure mitered-offset/pitch module
## (S1+S2, already shipped and pinned by test_pcb_bus_geometry.gd — 83 checks,
## a standing pin this unit consumes and never edits). Zero imports itself, so
## preloading it here adds no further dependency weight.
const BusGeom := preload("model/pcb_bus_geometry.gd")
## The MCP tool surface (panel_tools.gd) is preloaded HERE too, for the bus
## tool only: bus_plan()/bus_commit_plan() (its static funcs) are the ONE
## shared implementation of "resolve per-net widths, compute offsets, run the
## inner-fold guard, create the traces, one save_to_history" — both
## _commit_bus below and minerva_pcb_route_bus_direct call the SAME two
## functions, so "the gesture and the tool agree on the same input" is true by
## construction rather than by two hand-synchronised copies. This is a NEW
## dependency edge (canvas -> panel_tools); the reverse edge does not exist
## (panel_tools.gd never references pcb_canvas.gd), so it introduces no cycle.
const _PanelToolsScript := preload("panel_tools.gd")

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
# (show_hint_labels RETIRED, HITL-6b — docket 019fdf553f: hint labels no
# longer render at all, owner ruling; "what's this" is the select/ask
# paradigm — minerva_pcb_get_selection. The 2026-07-17 toggle existed
# because 16 proposals' labels were unreadable clutter; the labels are gone
# now, so the toggle has nothing to toggle.)
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
## Draws authored cutouts (campaign 2 epoch B, U3) — openings through the WHOLE
## board, rendered hatched/darkened over the board rect (v1: no polygon-with-
## holes, see _draw_cutout). Sibling of show_zones — same "always true, no
## _VIEW_FLAGS entry" precedent, not a new omission.
var show_cutouts: bool = true
## Draws GHOST route candidates from the RoutingWorkspace (campaign 2 epoch C,
## unit 3 — DCR 019f7095c395 S3). Sibling of show_zones/show_cutouts — same
## "always true, no _VIEW_FLAGS entry" precedent, not a new omission.
##
## SEPARATE FROM show_traces on purpose: a reviewer comparing a proposal against
## the copper already on the board wants to hide one WITHOUT hiding the other.
## The per-layer filter (trace_layer_filter) still applies to candidate segments
## — see _candidate_segment_visible — because a ghost on a hidden layer would be
## copper the view says is not there.
var show_route_candidates: bool = true

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
## KIND_* below are the id strings that name the four lists in one place; every
## generic selection call takes one (see _selection_of / _entity_at).
##
## THE FULL EXTENSION CHECKLIST, written down because vias (item 019fbb96cf)
## proved the short version was not enough — a kind that joins _entity_at and
## nothing else selects and then cannot be acted on at all, silently. A new kind
## needs a constant, a list, and a case in EVERY one of these:
##   _selection_of      — the id list behind the kind (the choke point)
##   _entity_at         — the click pick, and its rung in the frozen ladder
##   _entity_anchor     — the point a drag snaps against
##   _capture_drag_origins / _apply_drag_delta — the move gesture (a kind that
##                        does not move says so THERE, in a comment, rather than
##                        being left out and looking like an oversight)
##   _is_entity_locked  — the lock rule, even when the answer is "no such concept"
##   _remove_entity     — the journalled remover behind Delete and the eraser
##   _entity_action_label — the per-entity noun, shared by the eraser's history
##                        label and the context menu's "Delete <entity>" item
##                        (B1u5): a kind missing here is deletable but unnameable
##   _update_context_menu_for_selection — the per-target right-click menu (B1u5);
##                        a kind absent there has no menu entry, which is now the
##                        ONLY discoverable way to delete a single entity
##   _delete_selection  — the LITERAL kind array it loops (it is not derived)
##   _end_selection_drag — the journal loops that COMMIT a move; a movable kind
##                        absent here moves live but records nothing (silent
##                        undo hole — cold-review B1u2 F1)
##   _finalize_box_selection — the marquee sweep (also not derived)
##   selection_count / _clear_selection / get_selected_* — the counts, the clear
##                        and the public read surface
##   the draw loop      — a selected entity with no halo is invisible feedback
## And, since B1u3, the two UNIFIED-SELECTION sites that are not per-kind at all:
##   _clear_selection_all / _delete_selection — they carry the ANNOTATION half of
##                        the same gesture; a board kind added without them still
##                        works, but a change to how the two halves combine has
##                        to land in both.
const KIND_COMPONENT := "component"
const KIND_TRACE := "trace"
const KIND_ZONE := "zone"
const KIND_VIA := "via"
## Campaign 2 epoch B, unit 3 — added at the END of every checklist site below,
## after KIND_VIA, per the checklist's own "a kind that joins _entity_at and
## nothing else selects and then cannot be acted on at all, silently" warning.
const KIND_CUTOUT := "cutout"
## Campaign 2 epoch C, unit 3 (DCR 019f7095c395 S3) — a ROUTE CANDIDATE from the
## RoutingWorkspace. Appended at the END like every kind before it.
##
## THE ONE KIND THAT IS NOT A BOARD ENTITY, and the checklist above is answered
## per-site with that in mind. A candidate is a DRAFT answer to a RouteTask: it
## lives in the workspace (pcb_routing_workspace.gd), not in `data`, it is not
## fabricable copper, and every verb that acts on one (Accept/Commit, Keep/Pin,
## Reject, Try-again, Edit) belongs to the workspace tool surface (C4a), NOT to
## this canvas's board gestures. So the checklist sites split cleanly in two:
##   * SELECT + DRAW + PICK — fully implemented here (that is this unit).
##   * MOVE / DELETE / LOCK — deliberately NOT implemented, each with its reason
##     stated at the site, exactly as vias and cutouts state theirs.
const KIND_CANDIDATE := "candidate"

var selected_components: Array[String] = []
var selected_trace_ids: Array[String] = []
var selected_zone_ids: Array[String] = []
var selected_via_ids: Array[String] = []
var selected_cutout_ids: Array[String] = []
## Selected route candidates (S3). Backed by a LIST like every other kind so
## _selection_of / _add_to_selection / _toggle_entity_selected work unchanged;
## the public read surface is get_selected_candidate_id() (singular) because the
## plain-click grammar makes this at most one in practice and the workspace
## verbs C4a will add each act on ONE candidate. A shift-click can still put two
## in here; that is harmless while no verb reads the list.
var selected_candidate_ids: Array[String] = []

# ── UNIVERSAL SELECT: the annotation half of the selection (B1u3, 019fbb9adc) ──
#
# This panel shows ONE Select, and it picks annotations as well as board
# entities. The annotation half does NOT live in a fifth id list here — it lives
# where it always has, on the AnnotationHost (core's multi-select set). What this
# canvas owns is the GESTURE: the click ladder, the marquee, Escape and Delete
# each ask the router below to do the annotation half of what they just did to
# the board half.
#
# The router is the PcbAnnotationHost, handed over by PCBPanel and duck-typed
# here on every call. Null router (headless fixtures, an older core that cannot
# arm the core transform tool passively) means every hook below is skipped and
# this canvas behaves exactly as it did before this unit.
#
# ORDER, decided and documented once — ANNOTATIONS CLAIM FIRST. See the claim
# rung in _handle_mouse_button for the reasoning and the tie rules.
var _annotation_router = null

## True between a claimed press and its release: the whole gesture belongs to the
## annotation tool, so hover, pan, selection-drag and marquee all stand down.
var _annotation_gesture: bool = false

## Screen-pixel travel a box-select must exceed before it sweeps ANNOTATIONS.
## Mirrors core AnnotationTransformTool.SELECT_DRAG_THRESHOLD_PX (3.0), and it is
## load-bearing rather than cosmetic: the annotation sweep matches kind.bounds()
## AABBs while the click pick matches kind.hit_test() INK, so a zero-travel
## "marquee" would select every annotation whose bounding box merely contains the
## click — including ones whose ink is nowhere near it. Below this threshold the
## release is a click, not a box, and the annotation half is left alone (which is
## also exactly core's own zero-travel marquee semantics).
const ANNOTATION_MARQUEE_TRAVEL_PX := 3.0

## Screen-pixel hit radius for a path-kind annotation's bend handle (station 6
## fix F1, docket 019fd104e1c6 / question 019fd10557c8). Mirrors core
## AnnotationTransformTool.HANDLE_HIT_RADIUS_DOC exactly, duplicated here for
## the same reason ANNOTATION_MARQUEE_TRAVEL_PX duplicates
## SELECT_DRAG_THRESHOLD_PX above: this off-tree script cannot reference core
## by class (parse-crash risk — see the file's own Round B note), so the
## constant is restated rather than shared.
const ANNOTATION_BEND_HIT_PX := 12.0

## Screen-pixel ink slack for the topmost-annotation walk in
## _route_hint_masks_claim (F1 fix, cold review station 7). Mirrors core
## AnnotationTransformTool._hit_test_topmost's own "8 screen px of slack" —
## duplicated here for the same off-tree reason ANNOTATION_BEND_HIT_PX and
## ANNOTATION_MARQUEE_TRAVEL_PX are: this script cannot reference core by
## class.
const ANNOTATION_HIT_SLACK_PX := 8.0
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

# ── Component ROTATE handles (owner HITL, docket 019fcb93d367) ────────────────
# The universal select's per-kind manipulation contract: components rotate (and
# translate via the existing drag) but never scale, so their selection chrome is
# corner ROTATE zones ONLY — the same ring-outside-the-corner geometry and the
# same orange as AnnotationTransformTool's rotate handles, so one gizmo language
# serves both halves of the select. Drag rotates the selection about the bbox
# centre. SNAP TIERS (owner-ruled, MS/Adobe-persona: PowerPoint right-click
# verbs + modifier-constrained handles, never EDA muscle memory): plain drag
# snaps 90° (board convention), Shift refines to 45°, Ctrl/Cmd frees to 1°.
# Ungrouped components live-preview each snapped step (direct set_rotation, no
# journal); rigid GROUPS apply once at release through the journalled
# rotate_group — their preview is the angle readout, not live geometry (a
# per-step rotate_group would spray journal entries into the single history
# step this gesture owes).
const _ROTATE_RING_INNER_PX := 8.0
const _ROTATE_RING_OUTER_PX := 26.0
const _ROTATE_HANDLE_COLOR := Color(1.0, 0.5, 0.0)

var _rotate_drag_active: bool = false
var _rotate_drag_center: Vector2 = Vector2.ZERO       # world (board mm)
var _rotate_drag_pointer_start: float = 0.0           # radians, at press
var _rotate_drag_applied: float = 0.0                 # degrees, snapped, live-applied to ungrouped comps
var _rotate_start_rotations: Dictionary = {}          # comp_id -> rotation° at press
var _rotate_drag_groups: Array[String] = []           # unlocked groups, applied at release

## Armed at press when the selection contains vias, fired ONCE on the first real
## motion of that gesture: vias do not move (see _capture_drag_origins), and a
## refusal nobody can see is indistinguishable from a bug. Armed at press but
## fired on MOTION deliberately — announcing at press would flash the status bar
## on every plain click on a via, which is a selection, not a refused drag.
## Cleared on release, so one gesture is at most one notice.
var _via_drag_notice_armed: bool = false
const _VIA_DRAG_NOTICE_PX := 3.0
## Cutout twin of the above (cold-review F3): cutouts do not drag either (see
## _capture_drag_origins), and a drag attempt on a cutout-only selection was
## silent — the exact "looks like a broken canvas" case the via notice exists
## to prevent. Reuses _VIA_DRAG_NOTICE_PX rather than a second identical
## 3.0-px constant.
var _cutout_drag_notice_armed: bool = false

var is_box_selecting: bool = false
var box_select_start: Vector2 = Vector2.ZERO
var box_select_end: Vector2 = Vector2.ZERO

## Space-drag pan (Photoshop / GraphicsEditor style): while Space is held, a
## left-drag pans the whole view instead of selecting.
var _space_pan_armed: bool = false

## General tool mode. SELECT is the single smart tool (click selects, drag a
## part moves it snap-aware, drag empty space box-selects; a component
## selection shows corner ROTATE handles — drag snaps 90°, Shift 45°,
## Ctrl/Cmd free — with R/Shift+R and the context menu's Rotate Right/Left
## as twins, docket 019fcb93d367); PAN drags the whole view. TRANSLATE/ROTATE are kept for
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
## click a pad to finish. It is NOT the Proposals-group trace tool — that one authors
## a route HINT for the router; this one authors the Trace entity itself. ERASER
## (item 019fb934827776) owns clicks the same way: each click deletes exactly the
## entity it hits (same pick _entity_at gives the Select tool), journalled as its
## OWN undo step (see _handle_eraser_click) — not the trash-can's batch. Clicking
## empty space, or a locked component/trace, deletes nothing and the tool STAYS
## ARMED (owner ruling); no drag-sweep deletion in v1.
## CUTOUT (campaign 2 epoch B, unit 3) is the zone-draw family's twin for board
## openings: click each corner, Enter/double-click closes, Esc/right-click
## cancels — reusing the SAME click-per-point grammar as ZONE_POUR/
## ZONE_KEEPOUT/TRACE, not a new one. APPENDED AT THE END, deliberately — see
## the enum's own doc above: PCBPanel.gd indexes per-mode status tables by this
## enum's raw int, so inserting anywhere but the end silently mislabels every
## tool after it (PCBPanel.gd's own status-table comment records a prior bug of
## exactly this class).
## BUS (campaign 2 epoch C, unit 5 — DCR 019fb572b888 S3+S4) turns the pure
## offset/pitch geometry (pcb_bus_geometry.gd, S1+S2) into copper. TWO PHASES
## under ONE ToolMode, not two modes — see the "Bus Authoring" region below for
## the full grammar:
##   PICKING (the resting state on arming) — click a pad or a trace to add
##     that pad/trace's net to an ORDERED list (T11: the order is the picker's
##     order, never re-sorted); click an already-listed net again to remove
##     it. Enter with 2+ nets picked starts the DRAWING phase.
##   DRAWING — the SAME click-per-point family TRACE uses: click places a
##     spine vertex, Enter/double-click commits, Esc/right-click cancels the
##     spine (back to PICKING, net list kept — a second Esc/right-click then
##     clears the net list too; the ladder set_tool_mode's own doc names).
## APPENDED AT THE END, same append-only rule as CUTOUT's own note above —
## PCBPanel.gd's raw-int status tables (_MODE_HINTS, _update_status's
## mode_names) both gain an entry for it.
enum ToolMode { NONE, SELECT, TRANSLATE, ROTATE, PAN, INSPECT_PIN, ZONE_POUR, ZONE_KEEPOUT, TRACE, ERASER, CUTOUT, BUS }
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
## The cutout tool's twin of the above ("needs 3 points", "cutout added",
## "cutout cancelled") — its own channel for the same reason zone_tool_message
## and trace_tool_message are separate from each other and from
## component_lock_changed: one channel per tool, all routed to the panel's
## single transient-status sink.
signal cutout_tool_message(text: String)
## The bus tool's twin of the above ("Bus: [...] — pick at least 1 more net",
## "Added bus: 3 traces on top", the inner-fold refusal) — its own channel,
## same reason as the three above.
signal bus_tool_message(text: String)
## The context menu's "Set trace width…" item asking the PANEL to reveal and focus
## its existing width SpinBox (B1u5, owner comment 962: the numeric editor already
## existed and was undiscoverable). A SIGNAL rather than a canvas-side dialog
## because there is no dialog anywhere in this panel — every numeric edit is an
## inline sidebar row, and the row already owns the no-op guard, the refusal
## routing and the single journalled set_trace_width call. The canvas must not
## grow a second way to set a width.
signal edit_trace_width_requested(trace_id: String)

## Duck-typed back-reference to the PcbAnnotationHost (set by PCBPanel), the
## SOLE source of pad/pin hit-test logic (host.pad_at / host.pin_info) — the
## canvas does no hit-testing of its own, only rendering + input plumbing.
var _pin_inspector_host = null

## ── ROUTING WORKSPACE (S3) ────────────────────────────────────────────────────
## Duck-typed refs to pcb_routing_workspace.gd and pcb_routing_cutover.gd, both
## handed over by PCBPanel through set_routing_workspace(). Null (headless
## fixtures, an older panel) means every candidate path below is inert and this
## canvas behaves exactly as it did before this unit.
##
## THE CUTOVER FLAG GATES THE WHOLE SURFACE. Nothing about candidates renders,
## hit-tests, selects or reaches the context menu unless the cutover coordinator
## says the "canvas" surface is workspace-authoritative
## (RoutingCutover.is_workspace_authoritative). Every surface still DEFAULTS to
## "annotation" — a bare canvas, a headless fixture and an unmounted panel are
## all inert, and flag off is still byte-identical behaviour, which is what the
## existing canvas suites prove. What changed at S5 is that the flip now has a
## PRODUCTION caller: PCBPanel._build_ui flips "canvas" immediately after the
## set_routing_workspace handoff below, because the workspace write path is real
## (propose lands candidates only; C4b retired the proposal annotation).
var _routing_workspace = null
var _routing_cutover = null

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

## ── Zone vertex editing (A5) ──────────────────────────────────────────────────
## Outline editing of a COMMITTED zone, on the SELECTED zone only. The grammar is
## ported from pcb_route_hint_kind.gd's BendHandleEditTool (drag a handle = move
## that vertex, click a segment = insert one there, right-click a handle = delete
## it) — the same gesture vocabulary, deliberately, so "edit the shape of a thing
## made of points" means one thing across both input surfaces. The CODE is not
## shared: that tool is an AnnotationAuthorTool driving annotations through
## annotation_modified over an overlay host; this is the board canvas mutating
## board entities through pcb_data with real journal + history. Nothing but the
## grammar transfers.
##
## Handles are drawn slightly larger than the in-progress polygon's vertex dots
## (ZONE_PREVIEW_VERTEX_RADIUS_PX) and hit generously outside their own radius —
## a drawn dot only has to be SEEN, a handle has to be GRABBED. Both radii are
## screen px (constant across zoom), like every other handle on this canvas.
const ZONE_VERTEX_HANDLE_RADIUS_PX := 4.0
const ZONE_VERTEX_HIT_PX := 9.0
## How near an edge a press must land to arm a vertex insertion. MUST MATCH the
## zone pick's own tolerance (_zone_at's 3.0 / zoom): the insertion is armed from
## that pick's result, so a wider radius here would arm against an edge the pick
## never considered. Also tighter than the handle radius, so a press near a corner
## is unambiguously the corner's.
const ZONE_EDGE_INSERT_HIT_PX := 3.0
## A press-release pair this close together is a TAP, not a drag — the same
## discrimination RIGHT_CLICK_THRESHOLD already makes for the context menu, at the
## same distance, reused as a named constant of its own because it now answers a
## second question (see _zone_edge_insert_candidate for why an edge press cannot
## simply insert on PRESS the way the annotation tool's does).
const ZONE_EDGE_TAP_PX := 5.0

## Live vertex drag. `_zone_vertex_drag_origin` is the pre-drag outline, captured
## once at press, so every motion frame writes `origin with one point replaced`
## rather than nudging live geometry — the same absolute-from-origin rule
## _drag_origins follows, and what makes Escape an exact revert.
var _zone_vertex_drag_id: String = ""
var _zone_vertex_drag_index: int = -1
var _zone_vertex_drag_origin: PackedVector2Array = PackedVector2Array()

## Armed edge-insertion, set at press and consumed (or discarded) at release.
## Empty ⇔ nothing armed. Keys: zone_id, index, point, press_pos, origin.
var _zone_edge_insert: Dictionary = {}

## ── Cutout authoring (campaign 2 epoch B, unit 3) ─────────────────────────────
## Openings through the WHOLE board (pcb/internal/board's Cutout struct — U2,
## already landed). CLONE of the zone-draw shape above, minus everything that
## does not apply: no net, no layer (a cutout has neither — see pcb_data.gd's
## Cutout Management doc), and NO VERTEX EDITING (v1 scope; the ~400-line zone
## vertex suite just above is zone-keyed and its absence here is deliberate,
## not an oversight — reusing it would need a generic (collection,id) refactor
## nothing in this round does). Cutouts also do NOT drag — see
## _capture_drag_origins, same deliberate-absence idiom as vias.
##
## Vertices placed so far, in board mm. Empty ⇔ no draw in progress.
var _cutout_points: PackedVector2Array = PackedVector2Array()
## Live rubber-band vertex (the cursor), only meaningful while drawing.
var _cutout_preview: Vector2 = Vector2.ZERO
var _cutout_has_preview: bool = false
## Alpha for the not-yet-committed closing edge — mirrors ZONE_PREVIEW_CLOSE_ALPHA.
const CUTOUT_PREVIEW_CLOSE_ALPHA := 0.35
const CUTOUT_PREVIEW_VERTEX_RADIUS_PX := 3.0

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

## ── Bus authoring (campaign 2 epoch C, unit 5 — DCR 019fb572b888 S3+S4) ───────
## PICKING state: nets picked so far, in CLICK ORDER (T11 — this order is what
## pcb_bus_geometry.cumulative_offsets assigns track position by; it is never
## re-sorted). _bus_net_refs is the parallel "picked from" ref (a pad ref like
## "U1.3" or "trace <id>") for the teach line only — nothing reads it for
## geometry. Both empty ⇔ nothing picked yet.
var _bus_nets: Array[String] = []
var _bus_net_refs: Array[String] = []
## DRAWING state. _bus_drawing is what actually distinguishes the two phases:
## _bus_spine_points is empty both before drawing starts AND for one instant
## after Enter starts it (before the first vertex lands), so the points array
## alone cannot tell PICKING from "just started drawing".
var _bus_drawing: bool = false
## Vertices placed so far, in board mm. Meaningful only while _bus_drawing.
var _bus_spine_points: PackedVector2Array = PackedVector2Array()
## Live rubber-band vertex (the cursor), only meaningful while _bus_drawing.
var _bus_preview: Vector2 = Vector2.ZERO
var _bus_has_preview: bool = false
## The copper layer every trace in this bus lands on. Frozen at the moment
## DRAWING starts (_start_bus_draw), the same "arm once, hold for the whole
## draw" rule _trace_layer freezes under — the preview is drawn in that
## layer's colour at the real per-net widths, so a layer-filter change
## mid-draw must not silently commit different copper from what is on screen.
var _bus_layer: String = ""
## PREVIEW-FRAME MEMO (cold review N4). _draw_bus_preview calls
## panel_tools.bus_plan on every redraw while drawing, and mouse motion queues
## one every tick (_handle_mouse_motion's BUS branch). bus_plan's per-net
## width resolution is O(nets × board traces) (bus_net_width walks
## get_traces_for_net for each net) — cheap for a handful of nets/traces, but
## nets and _bus_layer are FROZEN for the whole DRAWING phase (_start_bus_draw)
## and the board's own trace list cannot change mid-draw (nothing commits
## until Enter/double-click), so only the SPINE actually varies frame to
## frame. Recomputing the full plan — width lookup included — on every motion
## tick is pure waste past the first frame at an unchanged spine. Keyed on
## exactly what bus_plan's result depends on; _draw_bus_preview skips the call
## entirely when the key matches. Cleared on _reset_bus_tool so a stale cache
## is never read into a new arming.
var _bus_plan_cache_key: Array = []
var _bus_plan_cache: Dictionary = {}
## Alpha for the N ghost offset polylines shown while drawing — the same
## "not committed yet" value TRACE_PREVIEW_RUBBER_ALPHA and CANDIDATE_GHOST_ALPHA
## already use, reused rather than re-chosen, so a bus ghost, a trace rubber
## band and a route candidate all read as "proposed" the same way.
const BUS_GHOST_ALPHA := 0.45
## The raw spine's own rubber-band colour — pale, so the N coloured/net ghost
## polylines it centres stay the visually dominant thing on screen.
const BUS_SPINE_PREVIEW_COLOR := Color(0.85, 0.85, 0.85, 1.0)
## The spine's colour when the CURRENT geometry would trip the inner-fold
## guard (panel_tools.bus_plan's own refusal — see _draw_bus_preview) — shown
## live while drawing, not only after a failed commit, so "never commit
## self-overlapping copper" is visible before the user ever presses Enter.
const BUS_REFUSAL_COLOR := Color(1.0, 0.35, 0.25, 1.0)

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

## Cutouts (campaign 2 epoch B, unit 3). A near-black colour, deliberately
## outside both the copper palette AND the zone amber: a cutout is neither
## copper nor a copper warning, it is the ABSENCE of substrate. Drawn filled
## (dim) + crosshatched + outlined over the board rect (v1: no polygon-with-
## holes primitive in Godot — see _draw_cutout) rather than a true hole, so it
## reads as "the board is gone here" without claiming fab-accurate geometry.
## Reuses ZONE_HATCH_PITCH_MM/MIN_PX/MAX_PX/MAX_LINES and zone_hatch_width_px
## above — the pitch-clamp and line-cap logic is generic to _draw_polygon_hatch,
## not zone-specific, so a second copy would only be able to drift from it.
var cutout_color: Color = Color(0.02, 0.02, 0.02, 1.0)
var cutout_fill_alpha: float = 0.55
var cutout_hatch_alpha: float = 0.6
var cutout_outline_alpha: float = 0.9
var cutout_outline_width_px: float = 1.5

## ── GHOST STYLING for route candidates (S3) ───────────────────────────────────
##
## THE RULE, and it is a hard one (DCR 019f7095c395 S3): a candidate segment is
## ALWAYS drawn in its own REAL layer colour (_trace_layer_color), only at a
## reduced alpha. Disposition and validation are expressed in SEPARATE visual
## channels — an OUTLINE (pinned), a DASH (stale) and a MARKER (violating) — and
## NEVER by recolouring the stroke. Recolouring is what the old proposal render
## did (all-AI-cyan), and it is exactly why a reviewer could not tell F.Cu from
## B.Cu on a 16-proposal board (owner req 2026-07-17, recorded on the route-hint
## kind's render()). A ghost that is not its layer's colour is a lie about which
## side of the board the copper lands on.
##
## SELF-HIGHLIGHTING OVERLAP is a consequence, not a feature bolted on: each
## stroke RUN is its own draw_polyline call at CANDIDATE_GHOST_ALPHA, so two
## ghost runs crossing on the SAME layer composite to a visibly denser colour
## while a single pass stays faint. Do NOT "optimise" this into one batched
## polyline with pre-multiplied alpha — the accumulation IS the overlap signal.
## A "run" is a chain of CONSECUTIVE same-candidate/-layer/-width segments whose
## endpoints coincide, merged at DRAW TIME ONLY (_merged_candidate_stroke_items,
## docket 019fce3a9b6d): butt-ended per-segment rectangles left a wedge gap on
## the outside of every bend AND a double-alpha dot at every shared endpoint —
## both lies about continuous copper. Crossings are between NON-consecutive
## geometry, so merging chains removes neither accumulation signal.
const CANDIDATE_GHOST_ALPHA := 0.45
## Minimum ghost stroke, in screen px — the same floor _draw_single_trace applies
## to committed copper, so a hair-thin candidate stays visible when zoomed out.
const CANDIDATE_MIN_WIDTH_PX := 1.0
## PINNED outline (channel 1). A neutral casing stroke drawn UNDER the ghost, so
## the ghost's own layer colour is untouched — "pinned" reads as a cased line, not
## as a differently-coloured one. Width is the ghost width plus this margin.
var candidate_pinned_outline_color: Color = Color(0.95, 0.95, 0.85, 0.75)
const CANDIDATE_PINNED_OUTLINE_MARGIN_PX := 3.0
## STALE dash (channel 2), in screen px. Applied when validation == "stale" — the
## board moved under the candidate (base_board_revision mismatch, see
## RouteCandidate.is_stale_for_board_revision), so its geometry is no longer known
## to be answering the board on screen.
const CANDIDATE_STALE_DASH_PX := 6.0
## VIOLATING marker (channel 3): a small ring at each segment midpoint / via
## centre when validation is "violating" or "error". Marker colour is deliberately
## NOT a copper colour — it is a verdict about the geometry, not the geometry.
var candidate_violation_color: Color = Color(1.0, 0.35, 0.25, 0.95)
const CANDIDATE_MARKER_RADIUS_PX := 5.0
## Ghost via ring geometry (screen px floor, mirroring the committed-via draw).
const CANDIDATE_VIA_MIN_RADIUS_PX := 3.0
const CANDIDATE_VIA_RING_WIDTH_PX := 1.5
## Selection halo, reusing trace_selected_color exactly as the trace and via
## halos do — selection is a FOURTH channel and must not be confused with any
## disposition/validation channel above.
const CANDIDATE_SELECT_HALO_MARGIN_PX := 4.0
## Extra click slack for a ghost, in screen px on top of half the segment width.
## Larger than the committed trace's 3.0 px: a ghost is a working object the user
## is reviewing and repeatedly grabbing, and it competes with nothing above it in
## the ladder (see _entity_at).
const CANDIDATE_HIT_SLACK_PX := 4.0
## Minimum click radius for a ghost via, screen px — the via twin of the slack
## above, and the same shape as VIA_HIT_RADIUS_PX for committed vias.
const CANDIDATE_VIA_HIT_RADIUS_PX := 6.0

## Font
var font: Font
var font_size: int = 12

## Context menu — the ONE menu authority for the board surface (B1u5, owner
## ruling on 019fbb968e: "I expect right click to be a menu, with delete as an
## option"). Per-target items are added to THIS PopupMenu by
## _update_context_menu_for_selection; nothing on this canvas pops a second one.
var context_menu: PopupMenu = null
var context_menu_world_pos: Vector2 = Vector2.ZERO
var right_click_start_pos: Vector2 = Vector2.ZERO
const RIGHT_CLICK_THRESHOLD := 5.0  # Pixels — below this a right-click is a tap → context menu

## WHAT THE RIGHT-CLICK WAS AIMED AT, resolved once at PRESS and read at RELEASE.
##
## Resolved at press for the same reason context_menu_world_pos is WRITTEN at
## press: the menu pops on RELEASE, and the release position is allowed to differ
## from the press position by up to RIGHT_CLICK_THRESHOLD. Re-picking at release
## would let a 4 px drift hand the menu a different entity than the one the user
## pressed on — the menu would then act on something the press never touched.
## Both are written together, in the SAME branch, and are only ever read together.
##
## `_context_menu_target` is an [kind, id] pair in _entity_at's own shape (["",""]
## = empty space). `_context_menu_vertex` is _zone_vertex_hit's dictionary ({} =
## no handle under the cursor); it is kept SEPARATE because a vertex handle is not
## an entity in the frozen ladder — it is the same narrow, deliberate exception
## the left button already makes for it (see _begin_zone_vertex_drag).
var _context_menu_target: Array = ["", ""]
var _context_menu_vertex: Dictionary = {}
var _context_menu_edge_insert: Dictionary = {}

## A bend handle of the single-selected PATH-KIND ANNOTATION under the press,
## or {} on a miss (station 6 fix F1). Resolved and consumed on the SAME
## press/release split as _context_menu_vertex, for the same reason: the menu
## pops at RELEASE. {ann_id: String, index: int} on a hit.
##
## THIS IS THE ONLY DOORWAY to core AnnotationTransformTool's path-kind
## right-click-deletes-a-bend gesture (_try_delete_bend_at, UX1 station 6) on
## THIS canvas: the RIGHT mouse button never reaches the annotation router at
## all (see _handle_mouse_button's MOUSE_BUTTON_RIGHT branch — every right
## press here arms a pan/menu directly, it is never handed to
## annotation_pointer_down), so that core branch is dead code through this
## panel and the gesture has to be re-offered here, as a menu item — the
## SAME "one menu authority" deal BendHandleEditTool's own right-click doc
## already states ("DELIBERATELY NOT CONVERTED TO A MENU (B1u5, item
## 019fbb968e) ... precisely the 'one menu authority' the unit was ruled to
## preserve").
var _context_menu_annotation_bend: Dictionary = {}


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


## Losing the window or the control's focus ends any gesture in flight: the
## release that would have finished it will never arrive here (cold-review F7).
## Kept to the TRANSIENT flags — the selection and the view are not gesture state.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_FOCUS_EXIT:
		_zone_edge_insert = {}
		# A claimed annotation gesture is transient gesture state too (B1u3):
		# the release that would clear it is never coming, and a leaked flag
		# would send the NEXT press's motion into the annotation tool.
		_annotation_gesture = false
		# boundary run first-execution fix: opening the context menu ITSELF
		# steals focus — context_menu.popup() opens a Window, and the canvas
		# gets WM_WINDOW_FOCUS_OUT/FOCUS_EXIT while the menu is coming up.
		# Wiping the frozen right-press target here destroyed every deferred
		# menu action (Delete bend / Delete vertex / Insert vertex / Delete
		# <entity>) before its id_pressed handler could read it. Focus lost TO
		# OUR OWN OPEN MENU is not a dead gesture — the frozen target is
		# exactly what that menu exists to act on — so keep it while the menu
		# is visible. Every other reset site (next LEFT press, Escape,
		# _exit_tree, a focus loss with no menu open) is unchanged.
		if context_menu == null or not context_menu.visible:
			_reset_context_menu_target()


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
	# Same reason the drag state above is dropped: this node is REPARENTED, and a
	# half-finished vertex gesture must not resume against a stale outline.
	_reset_zone_vertex_drag()
	_zone_edge_insert = {}
	_annotation_gesture = false
	_reset_context_menu_target()


## Create the right-click context menu (component lock/unlock).
func _create_context_menu() -> void:
	context_menu = PopupMenu.new()
	context_menu.name = "ContextMenu"
	add_child(context_menu)
	context_menu.id_pressed.connect(_on_context_menu_pressed)


## Rebuild the context menu for what the right-press was aimed at.
##
## ONE MENU AUTHORITY (B1u5). Every board right-click ends here; there is no
## second popup system and no per-entity menu built elsewhere. Sections are added
## most-specific-first, because that is the order the press resolved them in:
##
##   1. VERTEX     — a handle of a selected zone (the A5 gesture's replacement)
##   2. EDGE       — an insertion point on a selected zone's outline
##   3. TARGET     — the entity the frozen ladder picked (trace/via/zone/component)
##   4. LOCK       — the pre-existing component lock/unlock section, UNCHANGED
##   5. GROUP      — the pre-existing A4 group/ungroup section, UNCHANGED
##
## EMPTY SPACE IS BYTE-IDENTICAL to what it was before this unit: with no vertex,
## no edge and no target, sections 1-3 add nothing at all and the lock/group logic
## below runs on exactly the inputs it always did, down to the "(no actions)" stub.
##
## Every item routes to the SAME journalled model call its direct gesture uses —
## _delete_zone_vertex, _insert_zone_vertex, _delete_picked_entity, and (for the
## width) the panel's own SpinBox handler. No menu action mutates the board by a
## path a gesture could not also take.
func _update_context_menu_for_selection() -> void:
	context_menu.clear()

	_add_context_menu_target_items()

	var has_lock_section := false
	var comp_under_cursor: String = _component_at(context_menu_world_pos)
	if not comp_under_cursor.is_empty() or not selected_components.is_empty():
		has_lock_section = true
		_context_menu_separate()
		# Rotate verbs (docket 019fcb93d367): the menu twin of the corner
		# rotate handles, phrased the way PowerPoint phrases them — the
		# secondary affordance for the maker persona; the handles are primary.
		context_menu.add_item("Rotate Right 90°", MENU_ID_ROTATE_CW)
		context_menu.add_item("Rotate Left 90°", MENU_ID_ROTATE_CCW)
		_context_menu_separate()
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
		_context_menu_separate()
		if can_group:
			context_menu.add_item("Group Selection (Ctrl+G)", 411)
		if can_ungroup:
			context_menu.add_item("Ungroup (Ctrl+Shift+G)", 412)

	if not has_lock_section and context_menu.item_count == 0:
		context_menu.add_item("(no actions)", 0)
		context_menu.set_item_disabled(context_menu.item_count - 1, true)


## Drop the right-press target. Called wherever the OTHER transient gesture flags
## are dropped — focus loss, _exit_tree, Escape and the next LEFT press — so the
## three fields never outlive the gesture that resolved them (cold-review B1u5 F5).
func _reset_context_menu_target() -> void:
	_context_menu_target = ["", ""]
	_context_menu_vertex = {}
	_context_menu_edge_insert = {}
	_context_menu_annotation_bend = {}


## A separator BETWEEN sections and never at the top — the rule the group section
## already applied inline, lifted out because a second section now needs it and
## two copies of "if item_count > 0" is how the first one drifts from the second.
func _context_menu_separate() -> void:
	if context_menu.item_count > 0:
		context_menu.add_separator()


## Menu ids. 4xx was already this menu's block (401/402/404 lock, 411/412 group);
## the per-target items claim 42x so an id alone says which section it came from.
const MENU_ID_DELETE_VERTEX := 421
const MENU_ID_INSERT_VERTEX := 422
const MENU_ID_SET_TRACE_WIDTH := 423
const MENU_ID_DELETE_TARGET := 424
## C4a — the route-candidate verb block (43x, kept apart from the 42x per-target
## BOARD block above because these mutate the routing WORKSPACE and never the
## board's entity set; the one that does touch copper, Commit, goes through the
## workspace's own transaction). See _add_candidate_menu_seam.
const MENU_ID_CANDIDATE_COMMIT := 430
const MENU_ID_CANDIDATE_PIN := 431
const MENU_ID_CANDIDATE_UNPIN := 432
const MENU_ID_CANDIDATE_REJECT := 433
const MENU_ID_CANDIDATE_TRY_AGAIN := 434
## Component transform section (docket 019fcb93d367) — 44x; 43x above belongs
## to the candidate verbs. PowerPoint's own right-click vocabulary ("Rotate
## Right 90°"), the convention the owner's maker persona actually knows.
const MENU_ID_ROTATE_CW := 441
const MENU_ID_ROTATE_CCW := 442
## Station 6 fix F1 (docket 019fd104e1c6, question 019fd10557c8) — the one
## doorway onto core's path-kind bend-delete gesture on this canvas; see
## _context_menu_annotation_bend's doc for why a menu item and not the
## gesture core itself offers.
const MENU_ID_DELETE_ANNOTATION_BEND := 443


## Sections 1-3 of the menu: what the press was actually aimed at.
##
## Reads ONLY the three fields resolved at press (_context_menu_vertex,
## _context_menu_edge_insert, _context_menu_target) — never re-picks from
## context_menu_world_pos, so this cannot disagree with what the press decided.
func _add_context_menu_target_items() -> void:
	if not data:
		return

	# 0. ANNOTATION BEND — a bend handle of the single-selected path-kind
	# annotation (station 6 fix F1). Checked, and RETURNED, first: an
	# annotation is not a board entity in the frozen ladder (_entity_at never
	# resolves one), so there is nothing in sections 1-3 below that could
	# describe the same point, and offering both would risk a "Delete <board
	# thing underneath>" item next to "Delete bend" for one press.
	if not _context_menu_annotation_bend.is_empty():
		context_menu.add_item("Delete bend", MENU_ID_DELETE_ANNOTATION_BEND)
		return

	# 1 + 2. The zone-outline pair. Mutually exclusive by construction (the press
	# only looks for an edge insertion when no handle was under the cursor), which
	# keeps "Delete vertex" and "Insert vertex here" from ever offering to do
	# opposite things at the same point.
	if not _context_menu_vertex.is_empty():
		# ENABLED EVEN AT THE MINIMUM, deliberately. The min-3 refusal is a
		# MESSAGE, not a missing item: a greyed-out entry says "not here" while the
		# refusal says WHY ("a zone outline needs at least 3 points"), which is the
		# answer the A5 gesture gave and the answer the owner is owed. The item
		# only ever appears when a handle really is under the cursor, so it is
		# never a dead entry either way.
		context_menu.add_item("Delete vertex", MENU_ID_DELETE_VERTEX)
	elif not _context_menu_edge_insert.is_empty():
		# The DISCOVERABLE half of the edge-tap gesture, which stays exactly as it
		# is (left-tap on a selected zone's edge). Same gate, same insertion point,
		# same journalled write — the menu is a second doorway onto one behaviour,
		# not a second behaviour.
		context_menu.add_item("Insert vertex here", MENU_ID_INSERT_VERTEX)

	# 3. The entity the frozen ladder picked.
	var kind := str(_context_menu_target[0])
	var target_id := str(_context_menu_target[1])
	if kind.is_empty():
		return
	_context_menu_separate()

	# ── C4a SEAM: route-candidate verbs ──────────────────────────────────────
	# A candidate takes the ONE existing menu authority (that is the point of
	# routing its rung through _entity_at at all), and then RETURNS — it must not
	# fall through to the board items below. "Delete route candidate" would be a
	# dead item: _remove_entity refuses KIND_CANDIDATE by design, so the entry
	# would look live, click cleanly and do nothing.
	#
	# What lands here in C4a: Accept/Commit, Keep/Pin, Reject, Try-again, Edit —
	# each calling a GATED workspace transition, none of them a board mutation.
	# This unit ships the seam, not the verbs, so the menu says exactly what the
	# press resolved (which candidate, in which state) and offers nothing it
	# cannot actually do. See _add_candidate_menu_seam.
	if kind == KIND_CANDIDATE:
		_add_candidate_menu_seam(target_id)
		return

	if kind == KIND_TRACE:
		# THE ENTRY POINT THE OWNER COULD NOT FIND (comment 962). The width editor
		# already existed as a sidebar row that only appears once exactly one trace
		# is selected — which is precisely the state a user who has not found it
		# cannot reach on purpose. The item selects the trace and asks the panel to
		# focus that row; it does not set a width itself.
		context_menu.add_item("Set trace width…", MENU_ID_SET_TRACE_WIDTH)

	context_menu.add_item(_entity_action_label("Delete", kind, target_id), MENU_ID_DELETE_TARGET)
	if _unit_locked(kind, target_id):
		# Locked (or locked-by-group): shown-but-disabled rather than hidden, so
		# the lock is visible as the reason instead of the entry silently missing.
		# The lock/unlock section directly below is how it gets undone.
		context_menu.set_item_disabled(context_menu.item_count - 1, true)


func _on_context_menu_pressed(id: int) -> void:
	if not data:
		return
	match id:
		MENU_ID_ROTATE_CW, MENU_ID_ROTATE_CCW:
			# The menu acts on what you clicked: a right-click on an UNSELECTED
			# component adopts it as the selection first, same rule as Lock.
			if selected_components.is_empty():
				var target: String = _component_at(context_menu_world_pos)
				if not target.is_empty():
					selected_components = [target]
			_rotate_selected(id == MENU_ID_ROTATE_CCW)
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
		MENU_ID_DELETE_VERTEX:  # B1u5 — A5's gesture, now an item
			_delete_zone_vertex(_context_menu_vertex)
		MENU_ID_INSERT_VERTEX:  # B1u5 — the edge-tap gesture, now also an item
			var ins := _context_menu_edge_insert
			if not ins.is_empty():
				_insert_zone_vertex(str(ins["zone_id"]), int(ins["index"]), ins["point"])
		MENU_ID_SET_TRACE_WIDTH:  # B1u5 — reveal the panel's existing width row
			_request_trace_width_edit(str(_context_menu_target[1]))
		MENU_ID_DELETE_TARGET:  # B1u5 — delete the entity the press picked
			_delete_picked_entity(str(_context_menu_target[0]), str(_context_menu_target[1]), "Delete")
		MENU_ID_DELETE_ANNOTATION_BEND:  # Station 6 fix F1 — the frozen bend hit
			_delete_annotation_bend(_context_menu_annotation_bend)
		# C4a — the route-candidate verbs. Every one resolves the candidate from
		# the FROZEN press target (never a re-pick), exactly like the board items.
		MENU_ID_CANDIDATE_COMMIT:
			_run_candidate_verb("commit", str(_context_menu_target[1]))
		MENU_ID_CANDIDATE_PIN:
			_run_candidate_verb("pin", str(_context_menu_target[1]))
		MENU_ID_CANDIDATE_UNPIN:
			_run_candidate_verb("unpin", str(_context_menu_target[1]))
		MENU_ID_CANDIDATE_REJECT:
			_run_candidate_verb("reject", str(_context_menu_target[1]))
		MENU_ID_CANDIDATE_TRY_AGAIN:
			_run_candidate_verb("try_again", str(_context_menu_target[1]))


## Commit the ONE bend delete the frozen press resolved (station 6 fix F1).
## Re-resolves ann/kind from the LIVE host rather than trusting stale
## snapshot data in `hit` — the press only froze WHICH annotation and WHICH
## index, exactly the same "re-fetch, don't cache the mutable part" discipline
## _delete_zone_vertex and _delete_picked_entity already follow for their own
## frozen targets. A no-op (empty hit, annotation gone, no longer a path kind,
## index now out of range) leaves the board untouched rather than erroring —
## the router or the annotation could plausibly have changed between the
## right-press and this release-triggered menu action.
func _delete_annotation_bend(hit: Dictionary) -> void:
	if hit.is_empty():
		return
	var router = _router_with("get_by_id")
	if router == null or not router.has_method("get_registry") \
			or not router.has_method("update_annotation"):
		return
	var ann_id := str(hit.get("ann_id", ""))
	var index := int(hit.get("index", -1))
	if ann_id.is_empty() or index < 0:
		return
	var ann: Dictionary = router.get_by_id(ann_id)
	if ann.is_empty():
		return
	var registry = router.get_registry()
	if registry == null:
		return
	var kind: AnnotationKind = registry.get_annotation_kind(StringName(str(ann.get("kind", ""))))
	if not _is_path_kind(kind):
		return
	var bends: Array = kind.bend_points(ann)
	if index >= bends.size():
		return
	# STALE-INDEX GUARD (Codex re-review on 019fd10557c8, P2): the menu froze
	# {ann_id, index, point} at right-press, but the annotation can move under
	# an OPEN menu — an agent edit over MCP, an undo — and then `index` names a
	# DIFFERENT bend. The frozen POINT is the identity check: if the live bend
	# at this index no longer sits where the user right-clicked it, deleting by
	# index would delete a bend they never aimed at — no-op instead. Epsilon is
	# TIGHT (0.001mm): the frozen value IS the bend's own centre captured at
	# right-press, so identity means float-noise equality — a handle-radius
	# tolerance would accept a different bend inserted nearby under the open
	# menu, the exact hazard this guard exists for.
	var frozen: Variant = hit.get("point", null)
	if frozen is Vector2:
		# TIGHT epsilon, not the handle radius (Codex re-review): the frozen
		# value IS the bend's own centre captured at right-press, so identity
		# means float-noise equality — a handle-radius tolerance (6mm at zoom
		# 2) would happily delete a DIFFERENT bend inserted nearby while the
		# menu sat open, which is the exact hazard this guard exists for.
		var live: Variant = bends[index]
		if not (live is Vector2):
			return
		if (live as Vector2).distance_to(frozen) > 0.001:
			return
	bends.remove_at(index)
	router.update_annotation(ann_id, kind.with_bend_points(ann, bends))
	queue_redraw()


## "Set trace width…": make the trace the WHOLE selection, then ask the panel to
## reveal and focus its width row.
##
## Selecting first is not a side effect, it is the mechanism: the row is driven by
## "exactly one trace selected" (_update_trace_rows), so a menu item that focused
## the row without selecting would focus a hidden control, and one that set a width
## without selecting would edit something the sidebar is not showing. Selecting is
## also the recoverable half — a mispicked trace is re-picked by clicking another,
## which is the whole reason the owner ruled for a menu (comment 945).
##
## ORDER: selection first, signal second. The panel rebuilds its property rows off
## selection_changed, so the row exists by the time the focus request arrives.
func _request_trace_width_edit(trace_id: String) -> void:
	if trace_id.is_empty() or data == null or data.get_trace(trace_id) == null:
		return
	# ONE selection_changed for one menu action (cold-review F6): the clear is
	# silenced and the single emit below covers both halves, so the panel rebuilds
	# its property rows once — against the final selection, not against the empty
	# one it passed through — and the row is populated by the time the focus
	# request goes out.
	_clear_selection(false)
	_add_to_selection(KIND_TRACE, trace_id)
	selection_changed.emit()
	queue_redraw()
	edit_trace_width_requested.emit(trace_id)


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

	# The cutout BASE render (fill+hatch+plain outline) draws immediately over
	# the board rect (v1: no polygon-with-holes primitive — see _draw_cutout),
	# ahead of everything else, so a cutout reads as "the substrate is gone
	# here" underneath the grid/components/copper that a well-formed board
	# never actually places inside one. Not gated on show_cutouts vs the
	# tool-in-progress split zones use below: there is no vertex-edit gesture
	# to protect from a hidden toggle (v1 has none), so the flag alone is
	# enough.
	#
	# The SELECTION HALO and the IN-PROGRESS PREVIEW are deliberately NOT drawn
	# here (cold-review F2) — both moved down to the zone-preview depth, below,
	# for the same reason the zone/trace previews sit there: a user must be
	# able to SEE the opening they are drawing (or the cutout they selected)
	# even over components and copper, and this early pass sits under all of
	# that.
	if show_cutouts:
		_draw_cutouts()

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

	# Cutout selection halo + in-progress preview (cold-review F2) sit at this
	# SAME depth, for the same reason the zone preview does: visible feedback
	# over components and copper. Neither is gated on show_cutouts, mirroring
	# the zone preview's own "hiding authored X must not blank out the one
	# being worked on right now" rule.
	_draw_cutout_halos()
	if tool_mode == ToolMode.CUTOUT:
		_draw_cutout_preview()

	if show_traces:
		_draw_traces()

	# ── GHOST ROUTE CANDIDATES (S3) ──────────────────────────────────────────
	# DEPTH, decided here once: ABOVE committed copper, BELOW the in-progress
	# tool previews. Both halves matter and both follow the zone/cutout/trace
	# preview convention established directly above and below this line.
	#  * ABOVE COPPER, because a candidate is what the user is REVIEWING right
	#    now, and a proposal hidden under the copper it is meant to replace is a
	#    proposal nobody can judge. It is drawn at reduced alpha precisely so
	#    sitting on top does not erase what is underneath.
	#  * BELOW THE TOOL PREVIEW, because the preview is what the user's HAND is
	#    doing this instant; nothing may cover that. Same reason the zone/cutout
	#    previews sit above their own committed geometry.
	# Gated on show_route_candidates, and NOT on show_traces — see the flag's own
	# note for why hiding copper must not also hide the proposal against it.
	if show_route_candidates:
		_draw_route_candidates()

	# The trace being drawn sits with the committed copper (same visual language,
	# same place in the stack) — and, like the zone preview above, is NOT gated on
	# show_traces: hiding authored copper must not blank out the trace the user is
	# drawing right now.
	if tool_mode == ToolMode.TRACE:
		_draw_trace_preview()

	# The bus tool's preview sits with the trace preview, at the SAME depth —
	# it is TOOL PREVIEW geometry (docket 019fb572b888 S4), not a workspace
	# candidate, even though it renders N ghost polylines the way
	# _draw_route_candidates does one. The distinction that matters is WHERE
	# in this stack it sits: ABOVE _draw_route_candidates (nothing may cover
	# what the user's hand is doing right now — see that call's own comment)
	# rather than gated with it.
	if tool_mode == ToolMode.BUS:
		_draw_bus_preview()

	if show_ratsnest:
		_draw_ratsnest()

	if is_box_selecting:
		_draw_selection_box()

	_draw_component_rotate_chrome()

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

	# Vias (on top of all traces) — which is also why the click ladder gives them
	# the tie against a trace running through them (see _entity_at).
	for via in data.vias:
		# ONE position parser, shared with the click pick and the marquee sweep
		# (PCBData.via_position), so what is drawn and what is hit can never drift
		# apart on a via whose stored position is a dict or a stringified Vector2.
		var pos: Vector2 = world_to_screen(PCBDataScript.via_position(via))

		var outer_radius: float = maxf((via.get("size", 0.8) / 2.0) * zoom, 2.0)
		var inner_radius: float = (via.get("drill", 0.4) / 2.0) * zoom

		var color := pad_copper_color
		var net = data.get_net(via.get("net_name", ""))
		if net:
			color = net.color

		# Selection halo — the trace idiom (_draw_single_trace), transposed to a
		# disc: a translucent ring of the shared selection colour UNDER the via,
		# so the via's own net colour still reads through. Drawn at the pick
		# radius, not the copper radius, so what is highlighted is what a click
		# would actually claim.
		var is_selected: bool = str(via.get("id", "")) in selected_via_ids
		if is_selected:
			var halo_radius: float = maxf(outer_radius, VIA_HIT_RADIUS_PX)
			draw_circle(pos, halo_radius + 3.0, Color(trace_selected_color, 0.25))
			draw_arc(pos, halo_radius + 3.0, 0.0, TAU, 24, trace_selected_color, 2.0)

		draw_circle(pos, outer_radius, color)
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
		_draw_zone_vertex_handles(str(zone.get("id", "")), screen_poly)
	else:
		draw_polyline(outline, Color(color, zone_outline_alpha), zone_outline_width_px)


## Vertex handles on the SELECTED zone's outline (A5).
##
## Same shape and colour language the selected TRACE already uses for its
## waypoints (draw_circle in trace_selected_color, see _draw_traces) — a selected
## polyline-ish entity shows its points, whatever kind it is — just a touch larger,
## because these are grabbable and a trace's are not yet.
##
## Drawn ONLY where the gesture actually exists (_zone_vertex_edit_active): with
## the eraser, a zone tool or the pin inspector armed, a handle would advertise a
## drag that click would never reach, since those tools own the click outright.
## The vertex mid-drag gets the drag colour so the one being moved is obvious in a
## dense outline.
func _draw_zone_vertex_handles(zone_id: String, screen_poly: PackedVector2Array) -> void:
	if not _zone_vertex_edit_active():
		return
	for i in screen_poly.size():
		var is_dragged: bool = _zone_vertex_drag_id == zone_id and _zone_vertex_drag_index == i
		draw_circle(screen_poly[i], ZONE_VERTEX_HANDLE_RADIUS_PX,
			component_selected_color if is_dragged else trace_selected_color)


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


## Draw all committed cutouts. Mirrors _draw_zones' shape (one pass, no
## kind-split — a cutout has only one kind, unlike a zone's pour/keepout pair).
func _draw_cutouts() -> void:
	if data.cutouts.is_empty():
		return
	for cutout in data.cutouts:
		_draw_cutout(cutout)


## Draw one cutout's BASE render only — fill + crosshatch + plain outline, no
## selection halo (see _draw_cutout_halos for that, and why it is split out).
## No layer filter (a cutout has no layer — see pcb_data.gd's Cutout Management
## doc) and no vertex handles (v1 scope: no vertex editing).
##
## FILLED + CROSSHATCHED + OUTLINED, in that order — see the cutout_color
## declaration for why this is a filled dim polygon plus a hatch rather than
## the zone keepout's hatch-only: a keepout is a WARNING over real copper, a
## cutout is the substrate itself being gone, and a flat fill reads as solidly
## "not there" in a way a sparse hatch alone would not. Crosshatched (mirrored
## in both directions) rather than the keepout's single diagonal, so the two
## read as visually distinct region kinds at a glance.
func _draw_cutout(cutout: Dictionary) -> void:
	var world_pts := PCBDataScript.zone_outline_points(cutout)
	if world_pts.size() < 3:
		return

	var screen_poly := PackedVector2Array()
	for p in world_pts:
		screen_poly.append(world_to_screen(p))

	draw_colored_polygon(screen_poly, Color(cutout_color, cutout_fill_alpha))
	var pitch: float = clampf(ZONE_HATCH_PITCH_MM * zoom, ZONE_HATCH_MIN_PX, ZONE_HATCH_MAX_PX)
	_draw_polygon_hatch(screen_poly, Color(cutout_color, cutout_hatch_alpha), pitch, zone_hatch_width_px, false)
	_draw_polygon_hatch(screen_poly, Color(cutout_color, cutout_hatch_alpha), pitch, zone_hatch_width_px, true)

	var outline := screen_poly.duplicate()
	outline.append(screen_poly[0])  # close the loop — an outline, not a polyline
	draw_polyline(outline, Color(cutout_color, cutout_outline_alpha), cutout_outline_width_px)


## Selection halo for every selected cutout — SPLIT OUT of _draw_cutout
## (cold-review F2). The base render above draws early (right after the board
## rect, "this substrate is gone" underneath everything a well-formed board
## never places inside a cutout anyway); the halo draws LATE, at the same
## depth _draw_zone_preview does (after components/mounting holes, alongside
## committed zones, before traces), because a selection highlight is feedback
## the user must be able to see even when the base render would otherwise sit
## under components/copper. No vertex handles here either — see the Cutout
## authoring block's doc for why v1 has no vertex editing.
func _draw_cutout_halos() -> void:
	if data.cutouts.is_empty() or selected_cutout_ids.is_empty():
		return
	for cutout in data.cutouts:
		if not (str(cutout.get("id", "")) in selected_cutout_ids):
			continue
		var world_pts := PCBDataScript.zone_outline_points(cutout)
		if world_pts.size() < 3:
			continue
		var screen_poly := PackedVector2Array()
		for p in world_pts:
			screen_poly.append(world_to_screen(p))
		var outline := screen_poly.duplicate()
		outline.append(screen_poly[0])
		# Same selection colour + emphasis every other board entity uses, so
		# "selected" reads identically across kinds.
		draw_polyline(outline, trace_selected_color, cutout_outline_width_px * 2.0)


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

			# Defensive: a lost release (focus stolen mid-gesture) can leave the
			# via-drag notice armed; a fresh press starts a fresh gesture, so the
			# stale arming ends here (cold-review B1u2 F2, same shape as the
			# context-menu target clear on the next line).
			_via_drag_notice_armed = false
			_cutout_drag_notice_armed = false
			# Same idiom for the right-press target (cold-review B1u5 F5): a LEFT
			# press means the next gesture is not the right-click that resolved
			# them, so they stop describing anything. Harmless today — only the
			# release→popup path reads them, and every popup follows a press that
			# rewrites all three — but a second reader would inherit stale values
			# silently, which is exactly how the via-drag notice bug happened.
			_reset_context_menu_target()

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

			# Cutout tool (campaign 2 epoch B, unit 3): each left-click places a
			# vertex; a double-click closes the polygon. Owns the click outright,
			# exactly like the zone tools above (it is the same click-per-point
			# family, minus a net/layer to arm).
			if tool_mode == ToolMode.CUTOUT:
				_handle_cutout_click(world_pos, event.double_click)
				return

			# Bus tool (campaign 2 epoch C, unit 5): PICKING clicks add/remove a
			# net; once DRAWING it is the same click-per-point family as the
			# tools above. Owns the click outright in BOTH phases.
			if tool_mode == ToolMode.BUS:
				_handle_bus_click(world_pos, event.double_click)
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

			# ── UNIVERSAL SELECT, rung 0: ANNOTATIONS (B1u3) ─────────────────
			# Annotations claim the press BEFORE any board entity, including the
			# zone-vertex handles below. Three reasons, all the same reason the
			# via rung sits above trace:
			#  * PAINT ORDER. The annotation overlay is a CHILD of this canvas,
			#    so every annotation is drawn on top of every board entity.
			#    "What you see on top is what you click."
			#  * ANNOTATIONS ARE FOREGROUND COMMENTARY. They exist to point AT
			#    board entities, so an annotation is almost always over one; put
			#    below the board ladder its rung would be nearly dead code.
			#  * THE CLAIM IS TIGHT, not greedy. It is kind.hit_test() ink plus
			#    8 screen px of slack, plus — for the ONE already-selected
			#    annotation — its gizmo and caption handles. Empty space is never
			#    claimed, so the marquee below is untouched.
			# TIE RULES, stated once: an annotation body over a component picks
			# the ANNOTATION; a zone vertex handle under annotation ink loses to
			# the annotation (both are handles-on-a-selected-thing, and the one
			# drawn on top wins); everything the annotation layer does not claim
			# reaches the board ladder byte-identically.
			# Arrives BEFORE _arm_zone_edge_insert too — an insertion armed from
			# a press the annotation layer took would fire on a release the zone
			# never saw.
			if _claim_annotation_press(event):
				return

			# Zone vertex handles (A5) are a NARROW, DELIBERATE EXCEPTION to the
			# frozen click ladder: on a handle hit the component and trace picks
			# below are skipped entirely, so a part sitting within
			# ZONE_VERTEX_HIT_PX of a selected pour's corner cannot be grabbed
			# until that pour is deselected. That is the standard handles-beat-
			# what-is-under-them convention, and it is scoped as tightly as it can
			# be: handles exist ONLY on an ALREADY-SELECTED zone, ONLY under the
			# Select family (_zone_vertex_edit_active), and ONLY within a vertex's
			# own radius. With no zone selected the ladder is untouched, and a
			# first click on any zone still just selects it.
			#
			# It has to be checked BEFORE the pick rather than after: a handle sits
			# ON the outline, which is exactly where _zone_at would re-pick the
			# already-selected zone and start a whole-zone move, so a handle
			# checked after the pick would be a handle no press could ever reach.
			if _begin_zone_vertex_drag(world_pos):
				queue_redraw()
				return

			# Component ROTATE handles (docket 019fcb93d367) — the same
			# handles-on-a-selected-thing convention as the zone vertices above:
			# they exist ONLY when the selection holds components, ONLY under
			# Select, and ONLY in the ring band outside the selection bbox's
			# corners (empty space that would otherwise start a box-select — the
			# narrowest possible steal, and a deliberate one: a handle you can
			# see must be a handle you can press).
			if _begin_component_rotate_drag(event.position):
				queue_redraw()
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

			# An EDGE press only ARMS an insertion (fired at release if the press
			# turns out to be a tap) and then falls through, because the same press
			# is also how a selected zone is dragged. It is armed FROM THE PICK
			# RESULT — after _entity_at, never before it — so an insertion can only
			# ever belong to a press the frozen ladder already resolved to that
			# zone. See _arm_zone_edge_insert for what went wrong when it armed on
			# proximity alone. Read BEFORE the selection branch below, so
			# "was it already selected" means what it says.
			_arm_zone_edge_insert(world_pos, event.position, hit_kind, hit_id, event.double_click)

			if event.double_click and hit_kind == KIND_COMPONENT:
				component_double_clicked.emit(hit_id)
			elif hit_kind.is_empty():
				if not event.shift_pressed:
					# BOTH halves (B1u3): the annotation layer already declined
					# this point, so an empty press is empty for the whole
					# panel — and the box-select this arms sweeps both halves,
					# so it has to start from a cleared state on both.
					_clear_selection_all()
				is_box_selecting = true
				box_select_start = event.position
				box_select_end = event.position
			else:
				if event.shift_pressed:
					_toggle_entity_selected(hit_kind, hit_id)
				elif not is_entity_selected(hit_kind, hit_id):
					# BOTH halves (B1u3): a plain board pick replaces the whole
					# panel selection, annotations included — the mirror of what
					# an annotation claim does to the board half, and what makes
					# this read as ONE selection rather than two that overlap.
					# Only on an entity that was NOT already selected: clicking
					# something already in the set starts a drag of that set and
					# must not edit it (the pre-existing rule, unchanged).
					_clear_selection_all()
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
			# A claimed annotation gesture owns its release outright, same as the
			# vertex drag below (B1u3). The tool's own release logic commits or
			# discards whatever it armed at press.
			if _annotation_gesture:
				_annotation_gesture = false
				var ann_router = _router_with("annotation_pointer_up")
				if ann_router != null:
					ann_router.annotation_pointer_up(
						event.position, MOUSE_BUTTON_LEFT, _annotation_mods(event))
				queue_redraw()
				return

			# A vertex drag owns the release outright: it never started a pan, a
			# selection drag or a box-select, so nothing else here concerns it.
			if not _zone_vertex_drag_id.is_empty():
				_end_zone_vertex_drag()
				queue_redraw()
				return

			# Same ownership rule for a rotate drag: journal the one history
			# step it owes and end the gesture.
			if _rotate_drag_active:
				_finish_component_rotate_drag()
				queue_redraw()
				return

			# One gesture is at most one via-drag (or cutout-drag) notice: whether
			# it fired or the press never travelled far enough, the arming ends
			# with the press.
			_via_drag_notice_armed = false
			_cutout_drag_notice_armed = false

			# Release a left-drag pan (Pan tool / Space-drag).
			if is_panning:
				is_panning = false
			if is_dragging_selection:
				_end_selection_drag()

			if is_box_selecting:
				is_box_selecting = false
				_finalize_box_selection()

			# AFTER the selection drag has committed (or committed nothing): an
			# armed edge insertion fires only when the gesture turned out to be a
			# tap that moved the zone not at all.
			_commit_zone_edge_insert(event.position)

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
			if tool_mode == ToolMode.CUTOUT and not _cutout_points.is_empty():
				_cancel_cutout_draw(true)
				return
			if tool_mode == ToolMode.BUS and (_bus_drawing or not _bus_nets.is_empty()):
				_cancel_bus_step(true)
				return
			# THE ONE RIGHT-PRESS PATH (B1u5). Every right-click that is not
			# cancelling a draw in progress arms a pan AND arms the menu; which of
			# the two happens is decided at release, by distance alone.
			#
			# A5's instant "right-click a vertex handle deletes it" branch USED to
			# sit here, above the pan arming, and returned outright. It is gone by
			# owner ruling ("I expect right click to be a menu, with delete as an
			# option"): a gesture that destroys geometry with no menu and no
			# modifier is not discoverable and not recoverable. The vertex is still
			# deletable from exactly the same press — it is now resolved into
			# _context_menu_vertex below and offered as a menu item, through the
			# same journalled _delete_zone_vertex call the gesture used.
			#
			# Two things follow from the removal, both intended: a right-DRAG that
			# starts on a handle now pans (it used to be swallowed), and the
			# _zone_vertex_right_consumed release-swallow flag no longer exists,
			# because no right press is consumed at press time any more.
			is_panning = true
			pan_start_mouse = event.position
			pan_start_offset = pan_offset
			right_click_start_pos = event.position
			context_menu_world_pos = world_pos
			# Resolve the menu's target HERE, beside the position it belongs to —
			# see the _context_menu_target declaration for why not at release.
			_context_menu_vertex = _zone_vertex_hit(world_pos)
			_context_menu_target = _entity_at(world_pos)
			# Station 6 fix F1: a path-kind annotation's bend handle, resolved
			# the same way — see _context_menu_annotation_bend's own doc.
			_context_menu_annotation_bend = _annotation_bend_hit_at(world_pos)
			# An edge insertion is only looked for when NO handle was hit: the
			# handle radius (9 px) is deliberately wider than the edge tolerance
			# (3 px) so "a press near a corner is unambiguously the corner's", and
			# that rule is worth exactly as much on the right button as the left.
			_context_menu_edge_insert = {} if not _context_menu_vertex.is_empty() \
					else _zone_edge_insert_candidate(
						world_pos, str(_context_menu_target[0]), str(_context_menu_target[1]))
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

	# A claimed annotation gesture owns the pointer for its whole life (B1u3),
	# for the same reason the zone vertex drag below does: it started no pan, no
	# selection drag and no marquee, and running the board hover chain underneath
	# it would fight the annotation gizmo for the cursor.
	if _annotation_gesture:
		var ann_router = _router_with("annotation_pointer_move")
		if ann_router != null:
			ann_router.annotation_pointer_move(event.position)
		return

	# A zone vertex drag owns the pointer while it runs: no hover update, no pan,
	# no selection drag, no marquee — it started none of them, and running the
	# hover chain under it would fight the handle for the cursor.
	if not _zone_vertex_drag_id.is_empty():
		_update_zone_vertex_drag(world_pos)
		return

	# A rotate drag owns the pointer for its whole life, same rule as the two
	# gestures above — it started no pan, no selection drag, no marquee.
	if _rotate_drag_active:
		_update_component_rotate_drag(event)
		return

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
	elif tool_mode == ToolMode.CUTOUT:
		# Rubber-band the edge from the last placed vertex to the cursor. Same
		# "the tool owns the surface" rule as the zone/trace branches above.
		if not hovered_component.is_empty():
			hovered_component = ""
			queue_redraw()
		if not _cutout_points.is_empty():
			_cutout_preview = _author_point(world_pos)
			_cutout_has_preview = true
			queue_redraw()
	elif tool_mode == ToolMode.BUS:
		# Same "the tool owns the surface" rule. Only DRAWING rubber-bands (a
		# spine segment to the cursor); PICKING has no line to draw yet — each
		# pick is a discrete click, not a polyline in progress.
		if not hovered_component.is_empty():
			hovered_component = ""
			queue_redraw()
		if _bus_drawing and not _bus_spine_points.is_empty():
			_bus_preview = _author_point(world_pos)
			_bus_has_preview = true
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

	# The via-drag refusal, announced once per gesture on the first REAL motion
	# (see _via_drag_notice_armed). Checked outside the is_dragging_selection
	# block on purpose: a selection of vias ONLY captures nothing, so that flag is
	# false and the drag the user is attempting would otherwise be completely
	# silent — which is the case that most looks like a broken canvas.
	if _via_drag_notice_armed \
			and (event.position - drag_start_mouse).length() >= _VIA_DRAG_NOTICE_PX:
		_via_drag_notice_armed = false
		var via_count := selected_via_ids.size()
		component_lock_changed.emit(
			"%d via%s stayed put — vias move with their copper, in the routing tools"
			% [via_count, "" if via_count == 1 else "s"])

	# The cutout-drag refusal (cold-review F3), same shape and threshold as
	# the via notice just above — one announce per gesture, on the first
	# real motion past the same 3px.
	if _cutout_drag_notice_armed \
			and (event.position - drag_start_mouse).length() >= _VIA_DRAG_NOTICE_PX:
		_cutout_drag_notice_armed = false
		var cutout_count := selected_cutout_ids.size()
		component_lock_changed.emit(
			"%d cutout%s stayed put — v1 has no cutout move (draw + delete only)"
			% [cutout_count, "" if cutout_count == 1 else "s"])

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

	# ── A LIVE ANNOTATION GESTURE OWNS Escape AND Delete (B1u3, cold review N2) ─
	# Same rule, and the same reason, as the zone-vertex drag further down: it is
	# the INNERMOST gesture, and the tool driving it has its own grammar for both
	# keys — Escape REVERTS the drag it started, Delete removes what it holds.
	# Without this the tool never hears either key in this panel: Escape would
	# clear both selections while the drag ran on to commit anyway, which is the
	# opposite of what Escape means on every other annotation surface.
	#
	# ORDER, decided: the tool first, and NEITHER selection is touched. Escape
	# here cancels the GESTURE and nothing else — exactly the carve-out the
	# vertex-drag branch below already makes ("cancelling it must not also wipe
	# the selection the handles belong to"). What you reverted stays selected, so
	# you can try the drag again. A SECOND Escape, with no gesture live, falls
	# through to the ordinary ladder and clears everything.
	# (In practice the board half is usually already empty here: a plain claim
	# replaces the whole panel selection at press time. The guarantee that
	# matters is the one this branch actually makes — Escape during a gesture is
	# a gesture-level cancel, never a selection-level one.)
	#
	# Consuming ENDS the gesture: the tool resets its own drag state in both
	# branches, so there is nothing left for the release to finish, and routing
	# further motion at a reverted (or deleted) target would be writing to a
	# gesture that no longer exists.
	if _annotation_gesture and event.keycode in [KEY_ESCAPE, KEY_DELETE, KEY_BACKSPACE]:
		# Echo gate (re-review nit): a held key auto-repeats, and the repeat
		# would fall through AFTER the first press consumed the gesture —
		# collapsing the deliberate two-Esc ladder into clear-all. Same gate
		# the overlay applies.
		if event.is_echo():
			return
		var ann_router = _router_with("annotation_key")
		if ann_router != null:
			# BACKSPACE is normalised to DELETE, the same normalisation
			# AnnotationOverlay applies (macOS labels Backspace "Delete"), so the
			# tool sees one keycode.
			var code: int = KEY_DELETE if event.keycode == KEY_BACKSPACE else event.keycode
			if bool(ann_router.annotation_key(code)):
				_annotation_gesture = false
				queue_redraw()
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
			# Closes an in-progress cutout — same grammar as the zone tools
			# above (this is the same click-per-point family).
			elif tool_mode == ToolMode.CUTOUT:
				_commit_cutout()
			# Bus tool: Enter is the PHASE TRANSITION (PICKING -> DRAWING, needs
			# 2+ nets picked) while picking, and the commit while drawing — the
			# same "Enter closes/advances" idiom every draw tool on this canvas
			# uses, just spanning two phases instead of one. Shift+Enter while
			# drawing PROPOSES instead (ghost candidates via bus_propose_plan,
			# docket 019fcac1509d) — same plan, resolved through the workspace
			# verbs rather than committed as copper.
			elif tool_mode == ToolMode.BUS:
				if _bus_drawing:
					_commit_bus(event.shift_pressed)
				else:
					_start_bus_draw()
		KEY_ESCAPE:
			# Escape disarms a pending edge insertion whatever else it goes on to
			# cancel (cold-review F1): Escape is advertised as the cancel for this
			# whole family of gestures, and the release that follows must not
			# resurrect an insertion the user just called off.
			_zone_edge_insert = {}
			# Same rule for a resolved right-press target (cold-review B1u5 F5).
			_reset_context_menu_target()
			# A vertex drag in progress is what Escape cancels FIRST OF ALL (A5):
			# it is the innermost gesture, nothing was journalled while it ran, and
			# cancelling it must not also wipe the selection the handles belong to.
			if not _zone_vertex_drag_id.is_empty():
				_cancel_zone_vertex_drag()
				return
			# Same innermost-gesture rule for a rotate drag: revert the previewed
			# rotation (nothing was journalled) and keep the selection.
			if _rotate_drag_active:
				_cancel_component_rotate_drag()
				return
			# A zone draw in progress is what Escape cancels FIRST — cancelling it
			# should not also wipe the user's component selection.
			if _is_zone_tool() and not _zone_points.is_empty():
				_cancel_zone_draw(true)
				return
			if tool_mode == ToolMode.TRACE and not _trace_points.is_empty():
				_cancel_trace_draw(true)
				return
			if tool_mode == ToolMode.CUTOUT and not _cutout_points.is_empty():
				_cancel_cutout_draw(true)
				return
			# Bus tool's TWO-STEP Esc ladder (docket 019fb572b888 S4): a spine in
			# progress is the innermost gesture, so it is what the first Esc
			# cancels — back to PICKING, net list kept, exactly like the
			# right-click branch above. Only once nothing is drawing does a
			# second Esc reach the net list itself. Both branches return, same
			# as every other tool's Esc handling in this match — falling
			# through to _clear_selection_all() below is reserved for "nothing
			# to cancel at this level".
			if tool_mode == ToolMode.BUS and (_bus_drawing or not _bus_nets.is_empty()):
				_cancel_bus_step(true)
				return
			if tool_mode == ToolMode.INSPECT_PIN:
				_exit_inspect_pin_mode()
			# Esc disarms the eraser (item 019fb934827776 — "Esc or choosing
			# another tool disarms"); an empty click deliberately does NOT (see
			# _handle_eraser_click), so this is the only click-free way out.
			elif tool_mode == ToolMode.ERASER:
				set_tool_mode(ToolMode.SELECT)
			# ONE Escape drops the whole selection — components, traces, zones and
			# vias, AND the annotations (B1u3). One Select, one Escape; leaving
			# an annotation halo lit after Escape is exactly the two-worlds
			# symptom this unit exists to remove.
			_clear_selection_all()
			queue_redraw()
		KEY_P:
			if event.shift_pressed:
				_toggle_inspect_pin_mode()
		KEY_R:
			# Keyboard twin of the corner rotate handles (docket 019fcb93d367).
			# Shift+R = counter-clockwise. Kept as an EXTRA, never the primary
			# affordance — the owner's persona (maker, MS/Adobe conventions, no
			# EDA muscle memory) discovers rotation through the handles and the
			# context menu, not a bare keybinding.
			_rotate_selected(event.shift_pressed)
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
		KIND_VIA:
			return selected_via_ids
		KIND_CUTOUT:
			return selected_cutout_ids
		KIND_CANDIDATE:
			return selected_candidate_ids
	var empty: Array[String] = []
	return empty


## Is this entity in the selection? Kind-blind membership test.
func is_entity_selected(kind: String, entity_id: String) -> bool:
	return entity_id in _selection_of(kind)


## Read-only snapshot of everything this canvas holds selected, by kind
## (HITL-6b, docket 019fdf5579 — the MCP "what's this" read behind
## minerva_pcb_get_selection). Arrays are duplicated — a caller must never
## mutate live selection state through this.
func selection_snapshot() -> Dictionary:
	return {
		"components": selected_components.duplicate(),
		"traces": selected_trace_ids.duplicate(),
		"vias": selected_via_ids.duplicate(),
		"zones": selected_zone_ids.duplicate(),
		"cutouts": selected_cutout_ids.duplicate(),
		"candidates": selected_candidate_ids.duplicate(),
	}


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
	elif kind == KIND_CANDIDATE:
		# C4a: a ghost carries no label and no inspector row, so selecting one
		# has to say what it is and what can be done to it. This is the ONE place
		# a candidate becomes selected, which is why the line is emitted here
		# rather than at each caller.
		_emit_candidate_teach_line(entity_id)
		# HITL-6b (docket 019fdf5579): the canvas ghost pick feeds the
		# workspace's ACTIVE candidate, so an MCP reader (workspace_get_active,
		# minerva_pcb_get_selection) sees what the human is pointing at —
		# "what's this?" is the fundamental deictic question of co-working,
		# and it was unanswerable while this selection stayed canvas-local.
		# Last-selected wins for a multi-select (active is a single focus).
		if _routing_workspace != null and _routing_workspace.has_method("set_active"):
			_routing_workspace.set_active(entity_id)


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
	elif kind == KIND_CANDIDATE:
		# HITL-6b (docket 019fdf5579): deselecting the ghost the workspace is
		# focused on clears that focus — an MCP reader must never see an
		# "active" candidate the human has already deselected.
		if _routing_workspace != null and _routing_workspace.has_method("set_active") \
				and str(_routing_workspace.active_candidate_id) == entity_id:
			_routing_workspace.set_active("")


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


## Total selected BOARD entities across the five board kinds.
##
## ROUTE CANDIDATES ARE DELIBERATELY NOT COUNTED (S3), and this is a decision, not
## an omission. This count is what has_selection() is built on, and has_selection()
## gates the board DELETE batch: counting a ghost here would open a begin_batch /
## end_batch pair that removes nothing and then report "Selection is locked —
## nothing deleted", which is a lie about a candidate that is neither locked nor
## deletable-by-this-gesture. A candidate's verbs are workspace verbs (C4a), so a
## selected ghost must leave every board-batch gate exactly where it found it.
## The same split already exists one function down: has_selection() is BOARD-ONLY
## while has_any_selection() speaks for the whole panel.
## The candidate selection is read through get_selected_candidate_id().
func selection_count() -> int:
	return selected_components.size() + selected_trace_ids.size() \
		+ selected_zone_ids.size() + selected_via_ids.size() + selected_cutout_ids.size()


func has_selection() -> bool:
	return selection_count() > 0


## Is ANYTHING selected in this panel — board entity or annotation (B1u3)?
##
## Separate from has_selection(), which stays BOARD-ONLY on purpose: it gates the
## board delete batch and every board-side caller, and widening it there would
## make an annotation-only selection open an empty undo batch. This one exists
## for the surfaces that speak for the whole panel — the trash button, which
## must be live when only an annotation is selected.
func has_any_selection() -> bool:
	if has_selection():
		return true
	var router = _router_with("selected_annotation_count")
	if router == null:
		return false
	return int(router.selected_annotation_count()) > 0


## Drop EVERY selected entity, whatever its kind. Deselect-only: the armed tool
## is untouched (owner ruling on 019fb59b5d86 — an empty click deselects, it does
## not disarm the tool).
## `announce` exists for ONE caller: a path that clears and then immediately
## selects something else owes the panel ONE selection_changed, not two (a second
## emit rebuilds every property row against a selection that already moved on —
## cold-review F6). Defaults to true, so every existing caller is unchanged.
func _clear_selection(announce := true) -> void:
	for comp_id in selected_components:
		component_deselected.emit(comp_id)
	selected_components.clear()
	selected_trace_ids.clear()
	selected_zone_ids.clear()
	selected_via_ids.clear()
	selected_cutout_ids.clear()
	# Candidates ARE cleared here even though they are not counted by
	# selection_count() (S3): "clear the selection" has to mean everything this
	# canvas is holding selected, or a plain click on a component would leave a
	# ghost lit — the two-worlds symptom the unified Select exists to remove. The
	# asymmetry with selection_count() is deliberate and documented there: this is
	# about what the canvas is SHOWING as selected, that one is about what a board
	# DELETE batch may act on.
	# HITL-6b (docket 019fdf5579): the workspace focus follows — clearing a
	# selection that held the active ghost clears the MCP-visible focus too.
	if _routing_workspace != null and _routing_workspace.has_method("set_active") \
			and str(_routing_workspace.active_candidate_id) in selected_candidate_ids:
		_routing_workspace.set_active("")
	selected_candidate_ids.clear()
	focused_component = ""
	# An armed edge insertion belongs to a SELECTED zone; with the selection gone
	# there is nothing for it to belong to (cold-review F1 — the deselect click
	# itself used to fire one). _commit_zone_edge_insert re-checks selection too;
	# this is the cheaper half of the same guarantee.
	_zone_edge_insert = {}
	if announce:
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

	# Vias sweep under the SAME rule the via click pick honours (_via_visible),
	# exactly as the three kinds above do. The visibility gate is applied HERE
	# rather than passed into the model as a per-via Callable — unlike traces and
	# zones, whose visibility is a per-entity question (which layer is this on),
	# a via's is board-wide (show_traces), so a callable would be one that ignores
	# its own argument. See _via_visible.
	if _via_visible():
		for via_id in data.get_vias_in_region(select_rect):
			_add_to_selection(KIND_VIA, via_id)

	# Cutouts sweep the SAME way vias do (campaign 2 epoch B, unit 3): the
	# gate is board-wide (show_cutouts, a cutout has no layer to be per-entity
	# about), so it is applied here rather than as a per-cutout Callable.
	if _cutout_visible():
		for cutout_id in data.cutouts_in_region(select_rect):
			_add_to_selection(KIND_CUTOUT, cutout_id)

	# ROUTE CANDIDATES ARE NOT SWEPT (S3), and this comment is the decision — the
	# extension checklist's "a kind that does not sweep says so THERE" rule.
	# The marquee is a BOARD-EDITING gesture: everything it collects is something
	# the next Delete/drag will act on as one batch. A candidate can be acted on by
	# neither, so sweeping ghosts in would only produce a selection whose members
	# silently refuse every gesture that follows — and a box drawn to grab three
	# components would quietly also grab the four proposals crossing them. The
	# click pick (_entity_at) is the one, deliberate way to select a ghost.
	_sweep_annotations(select_rect)

	selection_changed.emit()


## The ANNOTATION half of the one marquee (B1u3). Same box, same gesture, same
## release — a sweep over a component and an arrow selects both.
##
## THREE THINGS ARE DELIBERATE HERE, and each one is a trap if it is "tidied":
##
##  1. THE TRAVEL GATE. Board sweeps run on any release; the annotation sweep
##     needs real travel first. The board pick and the board sweep agree on
##     geometry, but the annotation pick uses kind.hit_test() INK while the
##     annotation sweep uses kind.bounds() AABBs (core's own documented marquee
##     grammar). A degenerate box therefore matches every annotation whose
##     bounding box merely CONTAINS the click — which would make a plain click on
##     empty board silently select a long diagonal arrow passing nowhere near it.
##     See ANNOTATION_MARQUEE_TRAVEL_PX.
##  2. THE ASYMMETRY ITSELF stays. Marquee-by-AABB is what every canvas does and
##     what core's annotation marquee has always done; there is no kind-level
##     rect-intersect API to do better, and inventing one here would make this
##     panel's marquee disagree with the annotation dock's.
##  3. ADDITIVE BY CONSTRUCTION, exactly like the board half above: a non-shift
##     press already cleared BOTH halves (see _clear_selection_all at the press
##     site), so this only ever adds, and shift+box extends a mixed selection for
##     free.
##
## Locked entities are swept in on the board side, deliberately (see this
## function's caller). Annotations have no lock concept at all, so there is
## nothing to mirror.
func _sweep_annotations(select_rect: Rect2) -> void:
	if (box_select_end - box_select_start).length() < ANNOTATION_MARQUEE_TRAVEL_PX:
		return
	var router = _router_with("annotations_in_world_rect")
	if router == null:
		return
	# Board-mm in, ids out. The AABBs behind this answer are zoom-ephemeral —
	# they are consumed inside this call and never stored.
	var picked: PackedStringArray = router.annotations_in_world_rect(select_rect)
	if picked.is_empty():
		return
	picked = _filter_masked_route_hints(picked, select_rect, router)
	if picked.is_empty():
		return
	var adder = _router_with("add_annotations_to_selection")
	if adder != null:
		adder.add_annotations_to_selection(picked)


## F1 box-select leg (cold review, station 7 fix round): bounds() — like
## hit_test() — has no host param, so it still reports the FULL corridor AABB
## for a markers-mode route hint, and the marquee sweep above uses that AABB
## verbatim (core's own documented marquee grammar; see this function's own
## doc, point 2 — there is no kind-level rect-intersect API to do better).
## Since bounds() itself cannot know the render mode, the mode-awareness has
## to be applied HERE, at the canvas sweep site: drop a picked route hint
## from the sweep unless the box ALSO reaches its visible ink (the marker
## discs — the same points _route_hint_masks_claim's click-level gate uses),
## so dragging a marquee across a hidden corridor does not scoop the hint up
## and pop it back to "full", the box-select twin of the click-level bug.
func _filter_masked_route_hints(ids: PackedStringArray, select_rect: Rect2, router) -> PackedStringArray:
	if not router.has_method("get_registry") or not router.has_method("get_by_id"):
		return ids
	var registry = router.get_registry()
	if registry == null:
		return ids
	var out := PackedStringArray()
	for id in ids:
		var ann: Dictionary = router.get_by_id(id)
		var kind: AnnotationKind = null
		if not ann.is_empty():
			kind = registry.get_annotation_kind(StringName(str(ann.get("kind", ""))))
		if kind != null and kind.has_method("_render_mode_for") and kind.has_method("_marker_points"):
			var mode: String = kind._render_mode_for(ann, router)
			# "none" (Epoch UX2 station 1): a consumed hint has NO visible ink
			# at all, so no marquee can ever reach it — drop unconditionally.
			if mode == "none":
				continue
			if mode == "markers":
				var reaches_ink := false
				for p in kind._marker_points(ann):
					if select_rect.has_point(p as Vector2):
						reaches_ink = true
						break
				if not reaches_ink:
					continue
		out.append(id)
	return out


## What the Select tool picks at `world_pos`, as [kind, id]; ["", ""] for empty
## space. The pick order is component, then VIA, then trace, then zone.
##
## THE VIA RUNG SITS ABOVE TRACE — the one deliberate decision this unit made
## about the ladder (item 019fbb96cf), and the reasoning is worth keeping:
##
##  * PAINT ORDER. Vias draw ON TOP of every trace (_draw_traces paints them last,
##    after the whole layer stack). "What you see on top is what you click" is the
##    rule every direct-manipulation surface keeps, and it is the rule the zone
##    vertex handles already keep on this canvas.
##  * A VIA IS ALWAYS UNDER A TRACE. Vias exist precisely where copper changes
##    layer, so essentially EVERY via has a trace passing through it. Below trace,
##    the via rung would be dead code — no click could ever reach it, which is a
##    worse outcome than any tie rule.
##  * THE VIA'S CLAIM IS TIGHT, not greedy. It reaches only its own disc (plus a
##    minimum click target, see _via_at), while a trace is claimable along its
##    whole length. So the trace loses ONLY inside the via disc and wins
##    everywhere else — including one via-radius further along the same copper.
##
## THE TIE RULE, stated once: a click inside the via's disc picks the VIA; the
## same trace, clicked anywhere outside that disc, picks the TRACE.
##
## Zones stay next-to-last, unchanged: a pour is the largest thing on the board
## and must never shadow the copper drawn over it. CUTOUTS ARE LAST (campaign 2
## epoch B, unit 3) for the same reason, one notch further: a cutout also hits
## like a filled region (see _cutout_at), and it must not steal a click from any
## more specific entity either.
##
## ── THE CANDIDATE RUNG SITS FIRST — ABOVE COMPONENT (campaign 2 epoch C, unit 3)
## The second deliberate ladder decision this file has made, stated in full for
## the same reason the via rung's was. The FULL panel order is now:
##
##     annotations  >  ROUTE CANDIDATES  >  component > via > trace > zone > cutout
##     └─ claimed before this function is ever called (_claim_annotation_press)
##
## Candidates sit BETWEEN the annotation rung and the component rung. Why there,
## and not either side of it:
##
##  * BELOW ANNOTATIONS. Annotations are foreground commentary drawn by an
##    overlay that is a CHILD of this canvas — they are literally on top of the
##    candidate ghosts, and "what you see on top is what you click" is the rule
##    every rung here already keeps. An annotation pointing AT a proposal must
##    still be grabbable.
##  * ABOVE EVERY BOARD ENTITY. A ghost is a WORKING OBJECT: it exists only while
##    a human is deciding about it, it is drawn above the committed copper (see
##    _draw), and the whole review gesture is "grab this proposal and act on it".
##    Board copper, by contrast, is settled — it is not what the user is reaching
##    for during a routing review. Put below the component rung, the candidate
##    rung would also be near-dead code for the same reason the via rung would
##    have been below trace: a route candidate for a net is drawn ACROSS the pads
##    of the components it connects, so most of the interesting clicks (the
##    endpoints) land on a component first.
##  * THE CLAIM IS TIGHT, not greedy. It is exact segment/via geometry plus a few
##    screen px of slack (CANDIDATE_HIT_SLACK_PX) — never a bounding box, never a
##    filled region. Empty board is never claimed, so the marquee, the box-select
##    and every board pick outside a ghost's own ink are untouched.
##
## THE TIE RULE, stated once: a click within a ghost's stroke picks the CANDIDATE;
## the component/via/trace under it, clicked anywhere outside that stroke, picks
## as it always did. And with the cutover flag off (the default — see
## _candidates_active) this rung returns "" unconditionally, so the ladder is
## byte-identical to what it was before this unit.
func _entity_at(world_pos: Vector2) -> Array:
	var candidate_id: String = _candidate_at(world_pos)
	if not candidate_id.is_empty():
		return [KIND_CANDIDATE, candidate_id]
	var comp_id: String = _component_at(world_pos)
	if not comp_id.is_empty():
		return [KIND_COMPONENT, comp_id]
	var via_id: String = _via_at(world_pos)
	if not via_id.is_empty():
		return [KIND_VIA, via_id]
	var trace_id: String = _trace_at(world_pos)
	if not trace_id.is_empty():
		return [KIND_TRACE, trace_id]
	var zone_id: String = _zone_at(world_pos)
	if not zone_id.is_empty():
		return [KIND_ZONE, zone_id]
	var cutout_id: String = _cutout_at(world_pos)
	if not cutout_id.is_empty():
		return [KIND_CUTOUT, cutout_id]
	return ["", ""]


## Minimum via click target, in SCREEN pixels of radius — divided by zoom at the
## point of use, the px-constants-through-the-zoom idiom this file already keeps
## for ZONE_VERTEX_HIT_PX and the 3.0/zoom trace tolerance. A 0.8mm via is a ~4px
## disc at a working zoom; without a floor it is a target nobody can hit, and
## with too generous a floor it starts stealing clicks from the trace it sits on.
## 6.0 (a 12px-wide target) is deliberately SMALLER than ZONE_VERTEX_HIT_PX (9.0):
## a vertex handle is a handle on an already-selected zone, while a via competes
## with the copper drawn through it.
const VIA_HIT_RADIUS_PX := 6.0


## Which via a click at `world_pos` picks, or "".
##
## VISIBILITY — the trap this pick exists to avoid (the same one _trace_at's note
## records for copper). Vias are drawn ONLY inside `if show_traces:` (see _draw),
## so with traces hidden there is no via on screen; a pick that ignored that would
## select copper the user cannot see. There is deliberately NO layer filter here:
## the via DRAW has none either (a via spans layers by definition), and the rule
## is "pick exactly what is drawn". If the draw ever gains a layer filter, this
## must gain the identical one — that is what _via_visible is for.
func _via_at(world_pos: Vector2) -> String:
	if not data or not _via_visible():
		return ""
	return data.get_via_at(world_pos, VIA_HIT_RADIUS_PX / zoom)


## Is a via drawable in the current view? The via twin of _trace_visible /
## _zone_visible, and the single source for BOTH the click pick and the box
## sweep. Takes no via argument because the rule is board-wide: vias ride the
## show_traces toggle (they are drawn inside _draw_traces) and carry no layer
## filter of their own.
func _via_visible() -> bool:
	return show_traces


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
		KIND_VIA:
			# A via IS a point, so its anchor is exact. It is answered here even
			# though a via never MOVES (see _capture_drag_origins): the anchor is
			# also the snap reference for a drag STARTED on a via whose selection
			# holds movable entities, and Vector2.ZERO there would translate the
			# whole selection to the board origin on the first motion frame.
			var via: Dictionary = data.get_via(entity_id)
			if not via.is_empty():
				return PCBDataScript.via_position(via)
		KIND_CUTOUT:
			# Answered for the SAME reason KIND_VIA is, immediately above, even
			# though a cutout never MOVES either (see _capture_drag_origins): a
			# drag started on a cutout inside a mixed selection still needs a snap
			# reference for whatever movable entities share the selection.
			var pts := PCBDataScript.zone_outline_points(data.get_cutout(entity_id))
			if not pts.is_empty():
				return pts[0]
		KIND_CANDIDATE:
			# Answered for the SAME reason KIND_VIA and KIND_CUTOUT are, even though
			# a candidate never MOVES either (see _capture_drag_origins): a drag
			# started on a ghost that shares a selection with movable board entities
			# still needs a real snap reference, and Vector2.ZERO would translate
			# that whole selection to the board origin on the first motion frame.
			# The anchor is the first point of the first drawn item — the same
			# "first point of the geometry" rule KIND_TRACE and KIND_ZONE use, read
			# from the SAME exact-geometry source the draw and the pick read
			# (candidate_draw_items — never waypoints, see INV-4).
			for item in candidate_draw_items():
				if str(item.get("candidate_id", "")) != entity_id:
					continue
				var item_pts: Array = item.get("points", [])
				if not item_pts.is_empty():
					return item_pts[0]
	return Vector2.ZERO


# ── Component rotate gesture (docket 019fcb93d367) ───────────────────────────

## World-space AABB over the selected components' bodies, Rect2() when none.
func _selected_components_bbox() -> Rect2:
	var rect := Rect2()
	var first := true
	for comp_id in selected_components:
		var comp = data.get_component(comp_id)
		if comp == null:
			continue
		var r: Rect2 = comp.get_bounding_rect()
		rect = r if first else rect.merge(r)
		first = false
	return rect if not first else Rect2()


## Press in a corner rotate zone → begin the gesture. False leaves the press
## for the pick/marquee ladder untouched. The zones only exist when the
## selection holds at least one ROTATABLE target (an ungrouped component or an
## unlocked group) — chrome for a selection that cannot rotate would be a lie.
func _begin_component_rotate_drag(screen_pos: Vector2) -> bool:
	if tool_mode != ToolMode.SELECT or data == null or selected_components.is_empty():
		return false
	var bbox := _selected_components_bbox()
	if bbox.size == Vector2.ZERO:
		return false
	var bbox_screen := Rect2(world_to_screen(bbox.position),
		world_to_screen(bbox.end) - world_to_screen(bbox.position))
	if bbox_screen.has_point(screen_pos):
		return false  # inside the bbox is the move-drag's territory
	var in_zone := false
	for corner in [bbox.position, Vector2(bbox.end.x, bbox.position.y),
			bbox.end, Vector2(bbox.position.x, bbox.end.y)]:
		var d := screen_pos.distance_to(world_to_screen(corner))
		if d >= _ROTATE_RING_INNER_PX and d <= _ROTATE_RING_OUTER_PX:
			in_zone = true
			break
	if not in_zone:
		return false

	_rotate_start_rotations = {}
	_rotate_drag_groups = []
	for comp_id in selected_components:
		var group_id: String = data.component_group_id(comp_id)
		if not group_id.is_empty():
			if not data.is_group_locked(group_id) and not _rotate_drag_groups.has(group_id):
				_rotate_drag_groups.append(group_id)
			continue
		var comp = data.get_component(comp_id)
		if comp:
			_rotate_start_rotations[comp_id] = float(comp.rotation)
	if _rotate_start_rotations.is_empty() and _rotate_drag_groups.is_empty():
		return false  # nothing rotatable (e.g. locked groups only)

	_rotate_drag_active = true
	_rotate_drag_center = bbox.get_center()
	_rotate_drag_pointer_start = (screen_pos - world_to_screen(_rotate_drag_center)).angle()
	_rotate_drag_applied = 0.0
	return true


## Snap tier for the CURRENT modifier state: 90° plain (board convention),
## 45° with Shift, 1° with Ctrl/Cmd — read live per motion event, so the tier
## can change mid-drag exactly like Adobe's constrain modifiers.
func _rotate_snap_step(event: InputEventWithModifiers) -> float:
	if event.ctrl_pressed or event.meta_pressed:
		return 1.0
	if event.shift_pressed:
		return 45.0
	return 90.0


func _update_component_rotate_drag(event: InputEventMouseMotion) -> void:
	var pointer_angle := (event.position - world_to_screen(_rotate_drag_center)).angle()
	var delta_deg := rad_to_deg(pointer_angle - _rotate_drag_pointer_start)
	var step := _rotate_snap_step(event)
	var target := roundf(delta_deg / step) * step
	if target != _rotate_drag_applied:
		_apply_rotate_preview(target - _rotate_drag_applied)
		_rotate_drag_applied = target
	queue_redraw()


## Live-preview a snapped delta on the UNGROUPED components only (direct
## set_rotation + changed signal, deliberately no journal entry — the release
## owes exactly one). Groups wait for release (see the state-block note).
func _apply_rotate_preview(delta_deg: float) -> void:
	for comp_id in _rotate_start_rotations:
		var comp = data.get_component(comp_id)
		if comp:
			comp.set_rotation(fposmod(comp.rotation + delta_deg, 360.0))
			data.component_changed.emit(comp_id)


func _finish_component_rotate_drag() -> void:
	_rotate_drag_active = false
	var net := fposmod(_rotate_drag_applied, 360.0)
	if is_zero_approx(net):
		# A no-op gesture reverts any float residue and journals nothing.
		_cancel_rotate_revert()
		queue_redraw()
		return
	var turned := 0
	for comp_id in _rotate_start_rotations:
		var comp = data.get_component(comp_id)
		if comp:
			data.record_change("rotate_component", {
				"component_id": comp_id,
				"old_rotation": _rotate_start_rotations[comp_id],
				"new_rotation": comp.rotation,
			})
			turned += 1
	for group_id in _rotate_drag_groups:
		turned += data.rotate_group(data.group_anchor_id(group_id), _rotate_drag_applied).size()
	if turned > 0:
		data.save_to_history("Rotate components")
	_rotate_start_rotations = {}
	_rotate_drag_groups = []
	queue_redraw()


func _cancel_component_rotate_drag() -> void:
	_rotate_drag_active = false
	_cancel_rotate_revert()
	_rotate_start_rotations = {}
	_rotate_drag_groups = []
	queue_redraw()


## Put every live-previewed component back exactly where the press found it.
func _cancel_rotate_revert() -> void:
	for comp_id in _rotate_start_rotations:
		var comp = data.get_component(comp_id)
		if comp:
			comp.set_rotation(_rotate_start_rotations[comp_id])
			data.component_changed.emit(comp_id)


## Selection chrome for rotatable component selections: quarter-arc rotate
## handles just OUTSIDE each bbox corner — the transform tool's orange, its
## ring geometry, and deliberately NOTHING else (no scale/edge handles: the
## absent affordances say "components don't scale"). During a drag, the live
## angle reads out beside the cursor.
func _draw_component_rotate_chrome() -> void:
	if tool_mode != ToolMode.SELECT or selected_components.is_empty():
		return
	var bbox := _selected_components_bbox()
	if bbox.size == Vector2.ZERO:
		return
	var tl := world_to_screen(bbox.position)
	var br := world_to_screen(bbox.end)
	var corners: Array = [tl, Vector2(br.x, tl.y), br, Vector2(tl.x, br.y)]
	# Each corner's arc faces OUTWARD — a quarter arc centred on the corner's
	# own diagonal direction, drawn mid-ring.
	var out_angles: Array = [PI * 1.25, PI * 1.75, PI * 0.25, PI * 0.75]
	var radius := (_ROTATE_RING_INNER_PX + _ROTATE_RING_OUTER_PX) * 0.5
	for i in corners.size():
		var c: Vector2 = corners[i]
		var mid: float = out_angles[i]
		draw_arc(c, radius, mid - 0.6, mid + 0.6, 12, _ROTATE_HANDLE_COLOR, 2.0, true)
	if _rotate_drag_active:
		var label := "%.0f°" % fposmod(_rotate_drag_applied, 360.0)
		var pos := get_local_mouse_position() + Vector2(14, -10)
		draw_string(ThemeDB.fallback_font, pos, label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, _ROTATE_HANDLE_COLOR)


## Begin a drag-move anchored on the entity under the cursor. The anchor is only
## the snap reference — what MOVES is the whole selection (_capture_drag_origins).
func _begin_selection_drag(kind: String, entity_id: String, screen_pos: Vector2) -> void:
	_drag_anchor_start = _entity_anchor(kind, entity_id)
	drag_start_mouse = screen_pos
	_capture_drag_origins()
	is_dragging_selection = not _drag_origins.is_empty()
	# Vias in the selection are about to be left behind by whatever this gesture
	# turns out to be — including "no gesture at all" when the selection is vias
	# only (nothing captured => is_dragging_selection false). Arm the notice for
	# BOTH cases here, at the one place a move gesture begins.
	_via_drag_notice_armed = not selected_via_ids.is_empty()
	_cutout_drag_notice_armed = not selected_cutout_ids.is_empty()


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
	# VIAS ARE DELIBERATELY NOT CAPTURED, and this comment is the decision, not a
	# note about an omission (item 019fbb96cf). A via is not free geometry: it is
	# the point where one net's copper changes layer, and the trace ends that meet
	# there are stored separately from it. Dragging the via alone would silently
	# detach it from its own copper and leave a board that looks routed and is
	# not. Moving a via therefore belongs to the routing tools, which can move the
	# trace ends with it — not to the generic select-and-drag gesture.
	#
	# Not being captured is ALSO the enforcement: _apply_drag_delta only ever
	# walks what is in here, so there is no second place a via could be moved
	# from, and no fourth loop below to forget. The refusal is announced by
	# _via_drag_notice_armed (see _begin_selection_drag) rather than being silent
	# — the same "select yes, act no" shape a locked component already has.
	# CUTOUTS ARE ALSO DELIBERATELY NOT CAPTURED (campaign 2 epoch B, unit 3),
	# the SAME idiom as vias just above, for an analogous reason: v1 ships DRAW
	# + DELETE only, with NO vertex editing and NO move (see the Cutout
	# authoring block's doc), so there is no gesture that legitimately changes
	# a cutout's outline after it is committed. Not being captured is the
	# enforcement here too: there is no fourth walk below to forget, and
	# _apply_drag_delta only ever touches what landed in _drag_origins.
	#
	# ROUTE CANDIDATES ARE ALSO DELIBERATELY NOT CAPTURED (S3), same idiom again,
	# and for the strongest reason of the three: a candidate is not this canvas's
	# geometry at all. It lives in the RoutingWorkspace, its edits are REVISION-
	# GUARDED (candidate_revision) and PATH-SCOPED (add_vertex / add_via /
	# reroute_span), and every one of them must mark the candidate stale and
	# re-run the draft check. A generic select-and-drag would translate the whole
	# route by a mouse delta behind the workspace's back, leaving a ghost whose
	# geometry no longer matches the revision the router validated. Candidate
	# geometry editing is C4a's, through the workspace's own gated verbs.
	# Not being captured is the enforcement here too — there is no sixth walk
	# below to forget, and _end_selection_drag journals only what was captured.
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

	# NO CANDIDATE LOOP, and the checklist requires saying why rather than leaving
	# the absence to be read as an oversight (S3): candidates are never captured
	# (_capture_drag_origins), so there is nothing here to journal — and there
	# could not be, because a candidate move is not a board change and has no
	# place in the board's undo history at all. Its edits are revision-guarded
	# workspace calls (C4a), journalled by the workspace, not by pcb_data.
	#
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
		KIND_VIA:
			# VIAS HAVE NO LOCK, and this case exists to SAY SO rather than to let
			# the fall-through below answer by accident (item 019fbb96cf). Checked
			# the same way KIND_ZONE's answer was: the via dict shape in
			# pcb_data.gd carries id/position/size/drill/net_name/from_layer/
			# to_layer and no "locked" key, and there is no via lock in the board
			# contract on either side of the wire. No lock concept was INVENTED
			# for this unit — a via is protected by the fact that it cannot be
			# dragged at all, which is a stronger guarantee than a lock flag.
			return false
		KIND_CUTOUT:
			# CUTOUTS HAVE NO LOCK, same idiom as KIND_VIA and KIND_ZONE above —
			# checked against the cutout dict shape (pcb_data.gd: id/outline only,
			# no "locked" key) and board.go's Cutout struct (no Locked field
			# either). A cutout is protected the same way a via is: it cannot be
			# dragged at all (see _capture_drag_origins).
			return false
		KIND_CANDIDATE:
			# CANDIDATES HAVE NO SELECTION LOCK, and this case exists to SAY SO —
			# the KIND_VIA / KIND_CUTOUT idiom above. There IS a `locked` flag on a
			# candidate's segment and via dicts (pcb_route_candidate.make_segment /
			# make_via), but it means something else entirely: it is the ROUTER's
			# "do not reroute this stretch" instruction, per-segment, consumed by
			# the routing verbs. Reporting it here would make an unrelated router
			# hint silently veto a UI gesture, and it is per-SEGMENT while this
			# question is per-ENTITY. A candidate is protected the way a via is —
			# it cannot be dragged or deleted through this canvas at all, which is
			# a stronger guarantee than a flag.
			return false
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
		KIND_VIA:
			# BY ID, never remove_via(index): that sibling is positional and every
			# removal shifts the vias after it, so a batch delete driven from a
			# selection would remove the wrong copper from the second entry on.
			# remove_via_by_id resolves the index fresh at the moment of removal
			# and journals a "remove_via" entry itself, exactly like the three
			# removers above — so this path needs no snapshot of its own (the
			# batch's end_batch, or the eraser's save_to_history, owns that).
			return data.remove_via_by_id(entity_id)
		KIND_CUTOUT:
			return data.remove_cutout(entity_id)
		KIND_CANDIDATE:
			# NEVER REMOVED THROUGH THIS PATH (S3), and the case is here to say so
			# rather than let the fall-through answer by accident. Discarding a
			# candidate is Reject — a WORKSPACE verb with its own legality gate
			# (RoutingWorkspace.reject → the disposition transition table), its own
			# task-lifecycle consequence (rejecting reopens the RouteTask) and its
			# own audit trail. Routing it through the board's journalled remover
			# would delete a draft as if it were copper, produce a board history
			# entry for something that was never on the board, and leave the task
			# closed with no answer. C4a owns the verb.
			#
			# ALL THREE callers are now blocked before they reach this line, and
			# this case is the backstop rather than the mechanism:
			# _delete_selection never loops KIND_CANDIDATE (see its literal kind
			# array), the context menu offers no Delete item for a candidate (it
			# offers the WORKSPACE verbs instead — see _add_candidate_menu_seam),
			# and the ERASER, which picks through _entity_at and so CAN resolve a
			# ghost, now stops at _handle_eraser_click with a VISIBLE notice
			# naming Reject as the verb that does it (C4a, chore 019fc179be76 —
			# the adjudication is written out there). Anything that still arrives
			# here is a caller that was not meant to, and gets a false.
			return false
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
	# ── ANNOTATION HALF FIRST (B1u3) ──────────────────────────────────────────
	# Runs BEFORE the board guard below, which returns early when only
	# annotations are selected — the "neither half silently skipped" rule.
	#
	# THE COMPOSITE BEHAVIOUR, decided and announced rather than hidden: the
	# board half goes as ONE journalled batch and ONE undo brings all of it back;
	# the annotation half is gone for good, because the annotation substrate has
	# no undo stack at all (this unit did not invent one, and a half-undo that
	# silently resurrects only the copper would be a worse lie than saying so).
	# The alternative — refusing to delete a mixed selection — was rejected: the
	# user asked for one selection, and a Delete that works on some of it and
	# refuses the rest is two worlds again.
	var ann_removed := 0
	var ann_deleter = _router_with("delete_selected_annotations")
	if ann_deleter != null:
		ann_removed = int(ann_deleter.delete_selected_annotations())

	if not data or not has_selection():
		if ann_removed > 0:
			component_lock_changed.emit(_annotation_delete_notice(ann_removed, 0))
			# Same reason the claim press emits: the trash button's enablement
			# feed is this signal, and it has just gone empty.
			selection_changed.emit()
			queue_redraw()
		return

	var removed := 0
	data.begin_batch()

	# THIS LITERAL ARRAY IS NOT DERIVED from the KIND_* constants — a kind missing
	# from it selects, highlights and then survives Delete, silently. It is listed
	# in the extension checklist at the top of this file for that reason.
	#
	# KIND_CANDIDATE IS DELIBERATELY ABSENT FROM IT (S3) — the one kind that is
	# meant to be missing, said out loud so it does not read as the exact bug the
	# comment above warns about. A candidate is not board geometry and Delete is
	# not its verb: discarding one is Reject, a gated workspace transition that
	# also reopens the RouteTask (see _remove_entity's KIND_CANDIDATE case). Until
	# C4a lands those verbs, Delete over a selected ghost does nothing at all,
	# which is the honest state — selection_count() excludes candidates precisely
	# so this path is not even entered on a candidate-only selection, and no
	# "nothing deleted" line is emitted about something that was never deletable.
	for kind in [KIND_COMPONENT, KIND_TRACE, KIND_ZONE, KIND_VIA, KIND_CUTOUT]:
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

	# One transient line per Delete, and the annotation half wins the slot when
	# there is one: "nothing deleted" would be a lie if annotations just went.
	if ann_removed > 0:
		component_lock_changed.emit(_annotation_delete_notice(ann_removed, removed))
	elif removed == 0:
		component_lock_changed.emit("Selection is locked — nothing deleted")

	_clear_selection()
	queue_redraw()


## The one place the no-undo asymmetry is spoken out loud. Routed through
## component_lock_changed, this panel's single transient-status pathway (the same
## one the via-drag refusal uses).
static func _annotation_delete_notice(ann_removed: int, board_removed: int) -> String:
	var line := "%d annotation%s deleted — annotations have no undo" \
		% [ann_removed, "" if ann_removed == 1 else "s"]
	if board_removed > 0:
		line += "; the %d board item%s undo as one step" \
			% [board_removed, "" if board_removed == 1 else "s"]
	return line


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
	# ── ERASER-ON-GHOST: A VISIBLE HOLD, NOT A DELETE (C4a, chore 019fc179be76)
	#
	# ADJUDICATED against the DCR vocabulary, and the answer is NOT "eraser =
	# Reject". Two reasons, both about contracts this file already makes:
	#
	#  1. The eraser's whole grammar is ONE JOURNALLED, UNDOABLE STEP — every
	#     other kind it touches goes through _delete_picked_entity's
	#     save_to_history, and the user's recourse is Ctrl+Z. Reject is TERMINAL
	#     in the disposition legality table (pcb_route_candidate.gd:
	#     "rejected" has NO outgoing transitions) and rides no board history
	#     bucket, so mapping the eraser onto it would let a tool that promises
	#     undo perform the one act in this surface that cannot be undone. That
	#     is worse than the silence it replaces, not better.
	#  2. A candidate is a DRAFT, not copper. The eraser is a board-editing tool;
	#     Reject is a workflow decision that also reopens a RouteTask. Giving one
	#     the other's meaning collapses a distinction the DCR draws on purpose.
	#
	# So the refusal STAYS a refusal — and stops being silent, which is the
	# actual defect the chore names. The notice says what was hit, why the
	# eraser will not take it, and the exact verb that will.
	if str(hit[0]) == KIND_CANDIDATE:
		trace_tool_message.emit("Route candidate %s is a draft, not copper — the eraser only removes board entities. Right-click it and choose Reject (that discards it and reopens its task)."
			% str(hit[1]))
		return
	_delete_picked_entity(str(hit[0]), str(hit[1]), "Erase")


## Delete ONE picked entity as its own journalled, undoable step. True if anything
## went. Shared by the ERASER (verb "Erase") and the context menu's per-target
## "Delete <entity>" item (verb "Delete", B1u5).
##
## ONE PATH, TWO DOORWAYS. The two gestures differ only in the word that lands in
## the undo history, so they share everything else: the lock rule, the whole-group
## rule, the journalled remover and the selection bookkeeping. Duplicating this for
## the menu is what cold-review N1 collapsed once already for the eraser and the
## trash can; it is not worth un-collapsing for a third caller.
##
## A locked (or locked-by-group) entity and an empty pick are both silent no-ops —
## the eraser's "empty click does nothing" ruling. The MENU never reaches that case
## for a lock, because it disables the item instead and says so on the face of it.
func _delete_picked_entity(hit_kind: String, hit_id: String, verb: String) -> bool:
	if not data or hit_kind.is_empty() or _unit_locked(hit_kind, hit_id):
		return false

	# A GROUPED component goes as a WHOLE UNIT (A4), matching what
	# minerva_pcb_delete_component does for the same component: the group is one
	# physical part, so removing one of its footprints and leaving the rest would
	# be a delete the user cannot mean. Still ONE undo step per click — the
	# begin_batch/end_batch pair _delete_selection uses, rather than this path's
	# single save_to_history, because several components are removed.
	var group_id: String = data.component_group_id(hit_id) if hit_kind == KIND_COMPONENT else ""
	if not group_id.is_empty():
		data.begin_batch()
		var erased: Array = data.remove_group(hit_id)
		data.end_batch("%s group (%d)" % [verb, erased.size()])
		var was_selected := false
		for member_id in erased:
			if is_entity_selected(KIND_COMPONENT, member_id):
				_remove_from_selection(KIND_COMPONENT, member_id)
				was_selected = true
		if was_selected:
			selection_changed.emit()
		queue_redraw()
		return true

	if not _remove_entity(hit_kind, hit_id):
		return false
	data.save_to_history(_entity_action_label(verb, hit_kind, hit_id))

	if is_entity_selected(hit_kind, hit_id):
		_remove_from_selection(hit_kind, hit_id)
		selection_changed.emit()
	queue_redraw()
	return true


## The per-entity noun, verb-first: "Erase trace", "Delete R1", "Delete via".
##
## ONE naming authority for two consumers that must not drift (B1u5): the eraser's
## history label and the context menu's "Delete <entity>" item text. A menu that
## said "Delete trace" while the undo entry said something else would be two names
## for one act. Named in the extension checklist at the top of this file — a kind
## missing a case here is deletable but unnameable, and falls back to the bare verb.
func _entity_action_label(verb: String, kind: String, entity_id: String) -> String:
	match kind:
		KIND_COMPONENT:
			# A GROUPED part names the GROUP, because that is what goes (A4 — the
			# whole-unit rule in _delete_picked_entity). "Delete R1" on a menu that
			# is about to remove four footprints is the one place the rule would be
			# invisible until after the click (cold-review F4); the undo label was
			# already honest, so this makes the two agree.
			var mates := _group_mates(entity_id)
			if not mates.is_empty():
				return "%s group (%d parts)" % [verb, mates.size() + 1]
			return "%s %s" % [verb, entity_id]
		KIND_TRACE:
			return "%s trace" % verb
		KIND_ZONE:
			return "%s zone" % verb
		KIND_VIA:
			return "%s via" % verb
		KIND_CUTOUT:
			return "%s cutout" % verb
		KIND_CANDIDATE:
			# Named here per the checklist even though NO delete path reaches a
			# candidate today (see _remove_entity / _delete_selection): the noun is
			# what a future workspace verb's label will read, and the checklist's
			# own warning is that a kind missing here is "deletable but unnameable".
			# A kind that is neither is still better named than not.
			return "%s route candidate" % verb
	return verb


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


## Which committed cutout a Select-tool click at `world_pos` picks, or "".
##
## ALWAYS the keepout-interior hit rule (per _zone_at's own vocabulary: a
## cutout renders filled, not outline-only, so it hits like one too) — unlike
## _zone_at there is no pour/keepout branch to choose between, a cutout has
## only the one shape.
##
## Routed through _cutout_visible() (cold-review F5), not the raw show_cutouts
## flag inline — the same discipline _trace_at/_zone_at already keep with
## their own _visible() twins, so a future per-entity gate on _cutout_visible
## cannot silently bypass this pick the way an inlined flag check would.
func _cutout_at(world_pos: Vector2) -> String:
	if not data or data.cutouts.is_empty() or not _cutout_visible():
		return ""
	var tol := 3.0 / zoom
	for cutout in data.cutouts:
		var cutout_id := str(cutout.get("id", ""))
		if cutout_id.is_empty():
			continue
		var pts := PCBDataScript.zone_outline_points(cutout)
		if pts.size() < 3:
			continue
		if Geometry2D.is_point_in_polygon(world_pos, pts) or _point_near_outline(world_pos, pts, tol):
			return cutout_id
	return ""


## Is a cutout drawable in the current view? The cutout twin of _zone_visible,
## but board-wide like _via_visible rather than per-entity — a cutout has no
## layer to filter on (see pcb_data.gd's Cutout Management doc), so the ONLY
## gate is the show_cutouts toggle.
func _cutout_visible() -> bool:
	return show_cutouts


#region Zone Vertex Editing (A5)

## Is the vertex-editing surface live right now?
##
## Every mode listed here OWNS THE CLICK outright (see _handle_mouse_button: the
## pin inspector, both zone tools, the trace tool, the cutout tool and the
## eraser each return before the Select grammar is reached; Pan turns a
## left-drag into a view pan). Drawing handles under one of them would
## advertise a gesture the click can never deliver, and the right-click delete
## would steal a press those tools do use. The SELECT family is what is left,
## which is exactly where zone selection came from.
##
## CUTOUT (campaign 2 epoch B, unit 3, cold-review F1) MUST be listed here: it
## owns the click exactly like TRACE/ERASER do (see _handle_mouse_button), but
## it is not a zone tool, so the old `not _is_zone_tool()` fallthrough answered
## true for it — zone vertex handles on a SELECTED zone would draw, hit-resolve
## and steal the click (placing a zone vertex instead of a cutout one) while
## the Cutout tool was armed.
## BUS (campaign 2 epoch C, unit 5) is listed for the IDENTICAL reason —
## exactly the B4-U3/F1 class the CUTOUT note above records: it owns the click
## outright in BOTH its phases (see _handle_mouse_button's BUS branch), and
## without this exclusion a zone vertex handle would draw (and, had the click
## reached this far, hit-resolve) UNDER an armed bus tool, advertising a drag
## the click ladder's early return would never let happen.
func _zone_vertex_edit_active() -> bool:
	if tool_mode == ToolMode.INSPECT_PIN or tool_mode == ToolMode.TRACE \
			or tool_mode == ToolMode.ERASER or tool_mode == ToolMode.PAN \
			or tool_mode == ToolMode.CUTOUT or tool_mode == ToolMode.BUS:
		return false
	return not _is_zone_tool()


## The vertex handle under `world_pos`, as {zone_id, index, points}, or {}.
##
## Walks SELECTED zones only, honouring _zone_visible — the SAME pair of rules
## _draw_zone applies before it draws any handles at all, so what is grabbable is
## exactly what is drawn (the discipline _zone_at and get_zones_in_region already
## share). Selection order breaks ties, so with two overlapping selected zones the
## first-selected wins, deterministically.
func _zone_vertex_hit(world_pos: Vector2) -> Dictionary:
	if not data or not _zone_vertex_edit_active():
		return {}
	var tol := ZONE_VERTEX_HIT_PX / zoom
	for zone_id in selected_zone_ids:
		var zone: Dictionary = data.get_zone(zone_id)
		if zone.is_empty() or not _zone_visible(zone):
			continue
		var pts := PCBDataScript.zone_outline_points(zone)
		for i in pts.size():
			if pts[i].distance_to(world_pos) <= tol:
				return {"zone_id": zone_id, "index": i, "points": pts}
	return {}


## Begin dragging a vertex handle; true when one was grabbed (the press is then
## consumed). Captures the WHOLE pre-drag outline, not just the one point, for the
## reason _capture_drag_origins captures whole geometries: every motion frame
## rewrites `origin with one point replaced`, so snapping cannot accumulate drift
## and Escape has the exact pre-drag outline to put back.
func _begin_zone_vertex_drag(world_pos: Vector2) -> bool:
	var hit := _zone_vertex_hit(world_pos)
	if hit.is_empty():
		return false
	_zone_vertex_drag_id = str(hit["zone_id"])
	_zone_vertex_drag_index = int(hit["index"])
	_zone_vertex_drag_origin = (hit["points"] as PackedVector2Array).duplicate()
	# A vertex drag is not a zone drag: drop anything the press might otherwise
	# have been about to do, so no second gesture runs underneath it.
	_zone_edge_insert = {}
	return true


## Live drag frame. Writes through set_zone_outline — the SILENT writer, which is
## correct here and only here: this runs once per mouse-move frame, and a
## journalling write would push one change entry (and one board_revision bump) per
## frame. The single journal entry is owed by _end_zone_vertex_drag.
##
## Snapped through _author_point, the one authoring-snap rule this canvas has: a
## vertex MOVED must land where a vertex PLACED would land, Ctrl/Cmd bypassing
## snap in both cases.
func _update_zone_vertex_drag(world_pos: Vector2) -> void:
	if _zone_vertex_drag_id.is_empty() or not data:
		return
	if data.get_zone(_zone_vertex_drag_id).is_empty():
		# The zone went away underneath the gesture (nothing on the interactive
		# paths can do this today, but an MCP edit or a reload could).
		_reset_zone_vertex_drag()
		return
	var moved := _zone_vertex_drag_origin.duplicate()
	moved[_zone_vertex_drag_index] = _author_point(world_pos)
	data.set_zone_outline(_zone_vertex_drag_id, moved)
	queue_redraw()


## Commit the drag as EXACTLY ONE journalled, undoable step — the same
## mutate-then-snapshot order and the same record_change-shaped entry
## _end_selection_drag writes for a whole-zone move (bug 019fb5ad791c: snapshot
## BEFORE the mutation and redo silently re-applies the pre-drag state).
##
## A drag that ended where it began journals NOTHING and takes no snapshot, the
## same no-op rule end_batch's _batch_touched gate gives the move gesture.
func _end_zone_vertex_drag() -> void:
	var zone_id := _zone_vertex_drag_id
	var index := _zone_vertex_drag_index
	var origin := _zone_vertex_drag_origin
	_reset_zone_vertex_drag()
	if zone_id.is_empty() or not data:
		return
	var now_pts := PCBDataScript.zone_outline_points(data.get_zone(zone_id))
	if now_pts.size() != origin.size() or index < 0 or index >= now_pts.size():
		return
	if now_pts[index] == origin[index]:
		return
	_journal_zone_outline_edit(zone_id, "move_vertex", index, origin.size(), now_pts.size())
	data.save_to_history("Move zone vertex")


## Escape mid-drag: put the captured outline back and journal nothing. Clean
## because the live writes were silent — no change entry, no history step and no
## board_revision bump was ever taken for them, so there is nothing to undo, only
## geometry to restore.
func _cancel_zone_vertex_drag() -> void:
	if _zone_vertex_drag_id.is_empty():
		return
	if data and not data.get_zone(_zone_vertex_drag_id).is_empty():
		data.set_zone_outline(_zone_vertex_drag_id, _zone_vertex_drag_origin)
	_reset_zone_vertex_drag()
	queue_redraw()


func _reset_zone_vertex_drag() -> void:
	_zone_vertex_drag_id = ""
	_zone_vertex_drag_index = -1
	_zone_vertex_drag_origin = PackedVector2Array()


## Where a new vertex would go on a CLOSED outline, as {index, point}, or {}.
##
## The polygon twin of pcb_route_hint_kind.nearest_bend_insertion: nearest point
## on any edge, and the array index the new vertex would occupy. Two differences
## follow from the geometry, not from taste — a zone outline is CLOSED (so the
## last->first edge is a real edge, and `% size` walks it) and every point is a
## vertex (so there is no anchor/destination offset: a hit on edge i inserts at
## i + 1, between its endpoints).
##
## The point is the PROJECTION onto the edge and is deliberately NOT snapped: an
## insertion must not change the shape it is inserting into. Snapping belongs to
## the DRAG that follows, which is how the user then moves the new vertex
## somewhere meaningful.
func _zone_edge_insertion(pts: PackedVector2Array, world_pos: Vector2, tol: float) -> Dictionary:
	if pts.size() < PCBDataScript.MIN_ZONE_OUTLINE_POINTS:
		return {}
	var best_dist := INF
	var best_point := Vector2.ZERO
	var best_edge := -1
	for i in pts.size():
		var closest := Geometry2D.get_closest_point_to_segment(world_pos, pts[i], pts[(i + 1) % pts.size()])
		var d := world_pos.distance_to(closest)
		if d < best_dist:
			best_dist = d
			best_point = closest
			best_edge = i
	if best_edge < 0 or best_dist > tol:
		return {}
	return {"index": best_edge + 1, "point": best_point}


## Arm — do NOT perform — an edge insertion for this press.
##
## THE ONE PLACE THIS GRAMMAR DIVERGES FROM BendHandleEditTool, and why: that tool
## inserts on PRESS, because on the annotation surface a press on a hint's segment
## means nothing else. Here the very same press is how a selected zone is
## DRAGGED (_begin_selection_drag anchors on the outline, since a pour hits like a
## path). Inserting on press would delete whole-zone dragging outright; dragging
## on press would make insertion unreachable. So the press arms both, and the
## RELEASE decides which one happened: a TAP inserts, a DRAG moves.
##
## ARMED FROM THE PICK, NOT FROM PROXIMITY (cold-review F1 — this is the fix for a
## real defect, recorded because the broken version looked reasonable). It used to
## run BEFORE _entity_at and arm on nearness to any selected zone's edge, with a
## radius twice the zone pick's. Nothing then tied the armed insertion to what the
## press was actually ABOUT, so three ordinary gestures silently reshaped copper:
## clicking a component sitting on a pour's border (the pick correctly chose the
## component — and the pour gained a vertex), clicking empty space just outside the
## edge to DESELECT (the zone was deselected AND grew a vertex, with its handles
## already gone), and shift-clicking a zone out of the selection. The old guard —
## "the outline is byte-identical at release" — proved only that the ZONE did not
## move, which is a far weaker claim than "this press was about the zone".
##
## So the gate is now the frozen ladder's own answer: the press must have resolved
## to KIND_ZONE, to THIS zone, and the zone must ALREADY have been selected (an
## unselected zone shows no handles, and its first click just selects it). The tap
## test at release then only has to answer "tap or drag", which is all it was ever
## able to answer. A double-click is refused outright — its second press would
## otherwise arm against the outline the first press just grew and insert a second
## vertex as a second undo step (cold-review F6).
##
## `origin` is still captured, now as a belt-and-braces check that the drag branch
## did not move the zone within the tap threshold (grid snapping can jump a zone
## whose first point is off-grid on a single motion frame).
func _arm_zone_edge_insert(world_pos: Vector2, screen_pos: Vector2, hit_kind: String, hit_id: String, is_double_click: bool) -> void:
	_zone_edge_insert = {}
	if is_double_click:
		return
	var candidate := _zone_edge_insert_candidate(world_pos, hit_kind, hit_id)
	if candidate.is_empty():
		return
	_zone_edge_insert = {
		"zone_id": candidate["zone_id"],
		"index": int(candidate["index"]),
		"point": candidate["point"],
		"press_pos": screen_pos,
		"origin": candidate["origin"],
	}


## WHERE — and WHETHER — a vertex insertion is legal for this pick, as
## {zone_id, index, point, origin} or {}.
##
## THE ONE GATE, shared by the left-button tap gesture (_arm_zone_edge_insert) and
## the right-button "Insert vertex here" menu item (B1u5). Both doorways must agree
## about what is insertable, so neither owns the rule: a menu that offered an
## insertion the gesture would have refused (or vice versa) is two behaviours
## wearing one name.
##
## The double-click refusal stays with the ARMING half — it is a property of the
## press sequence, not of the geometry, and a menu item has no second press to
## refuse.
func _zone_edge_insert_candidate(world_pos: Vector2, hit_kind: String, hit_id: String) -> Dictionary:
	if not data or not _zone_vertex_edit_active():
		return {}
	if hit_kind != KIND_ZONE or not is_entity_selected(KIND_ZONE, hit_id):
		return {}
	var zone: Dictionary = data.get_zone(hit_id)
	if zone.is_empty() or not _zone_visible(zone):
		return {}
	var pts := PCBDataScript.zone_outline_points(zone)
	# SAME tolerance the pick that got us here used (_zone_at's 3.0 / zoom). A
	# wider radius here would insert against an edge the pick never considered —
	# and for a KEEPOUT, whose interior hits, the pick can land far from any edge,
	# so this is also what stops an interior keepout click inserting a vertex on
	# whichever edge happened to be nearest.
	var insertion := _zone_edge_insertion(pts, world_pos, ZONE_EDGE_INSERT_HIT_PX / zoom)
	if insertion.is_empty():
		return {}
	return {
		"zone_id": hit_id,
		"index": int(insertion["index"]),
		"point": insertion["point"],
		"origin": pts,
	}


## Release half of the above: insert the vertex iff the gesture was a tap that left
## the outline exactly as it found it, on a zone that is STILL selected. ONE
## journalled, undoable step.
func _commit_zone_edge_insert(screen_pos: Vector2) -> void:
	var armed := _zone_edge_insert
	_zone_edge_insert = {}
	if armed.is_empty() or not data:
		return
	if screen_pos.distance_to(armed["press_pos"] as Vector2) >= ZONE_EDGE_TAP_PX:
		return
	var zone_id := str(armed["zone_id"])
	# Re-checked at RELEASE, not just at press: a shift-click toggles the zone out
	# of the selection between the two halves of the very same gesture, and a zone
	# with no handles showing must not be reshaped.
	if not is_entity_selected(KIND_ZONE, zone_id):
		return
	var origin: PackedVector2Array = armed["origin"]
	var pts := PCBDataScript.zone_outline_points(data.get_zone(zone_id))
	if pts != origin:
		# The press turned into a move after all (a snap jump inside the tap
		# threshold). That move is already journalled; do not stack an insertion
		# the user never asked for on top of it.
		return
	_insert_zone_vertex(zone_id, int(armed["index"]), armed["point"])


## THE journalled insertion write, shared by the edge-tap gesture above and the
## "Insert vertex here" menu item. True when the outline actually grew.
##
## Re-reads the live outline instead of trusting the caller's copy: the menu path's
## point was resolved at PRESS and the popup sits between then and now, so the
## array it was measured against is a snapshot, not the board.
func _insert_zone_vertex(zone_id: String, index: int, point: Vector2) -> bool:
	if not data:
		return false
	var pts := PCBDataScript.zone_outline_points(data.get_zone(zone_id))
	if index < 0 or index > pts.size():
		return false
	var grown := pts.duplicate()
	grown.insert(index, point)
	if not data.set_zone_outline(zone_id, grown):
		return false
	_journal_zone_outline_edit(zone_id, "insert_vertex", index, pts.size(), grown.size())
	data.save_to_history("Insert zone vertex")
	queue_redraw()
	return true


## "Delete vertex": drop one point from a zone outline. ONE journalled, undoable
## step. True when the outline actually shrank.
##
## THE MENU'S ITEM, not a gesture (B1u5). It was A5's right-click-a-handle gesture
## and it is now reached through _on_context_menu_pressed instead — same hit
## (_zone_vertex_hit, resolved at press), same refusal, same journal entry, same
## history label. Nothing about WHAT it does changed; only how it is asked for.
##
## REFUSES BELOW THE MINIMUM, VISIBLY (never silently): three points is a triangle
## and two is not a polygon at all — PCBData.MIN_ZONE_OUTLINE_POINTS, the same
## floor set_zone_outline and internal/board's Validate enforce. The refusal goes
## out on zone_tool_message, the channel the panel already routes to its status bar
## for every other zone refusal. Choosing a menu item and being told nothing at all
## would be worse than the gesture was, not better.
##
## Re-reads the live outline for the same reason _insert_zone_vertex does: `hit`
## was captured at press, and a popup stands between press and action.
func _delete_zone_vertex(hit: Dictionary) -> bool:
	if hit.is_empty() or not data:
		return false
	var zone_id := str(hit["zone_id"])
	var index := int(hit["index"])
	var pts := PCBDataScript.zone_outline_points(data.get_zone(zone_id))
	if index < 0 or index >= pts.size():
		return false
	if pts.size() <= PCBDataScript.MIN_ZONE_OUTLINE_POINTS:
		zone_tool_message.emit("A zone outline needs at least %d points — this one has %d." % [
			PCBDataScript.MIN_ZONE_OUTLINE_POINTS, pts.size()])
		return false
	var shrunk := pts.duplicate()
	shrunk.remove_at(index)
	if not data.set_zone_outline(zone_id, shrunk):
		return false
	_journal_zone_outline_edit(zone_id, "delete_vertex", index, pts.size(), shrunk.size())
	data.save_to_history("Delete zone vertex")
	queue_redraw()
	return true


## The ONE journal entry shape all three outline edits share. Built on move_zone's
## shape (_end_selection_drag) — zone_id, the point count, and the position that
## changed — plus the `op` that says which of the three gestures it was, so a
## journal reader can tell a vertex move from an insertion without diffing
## geometry. record_change is what bumps board_revision; the caller takes the
## history snapshot immediately after, mutate-then-snapshot.
func _journal_zone_outline_edit(zone_id: String, op: String, index: int, old_count: int, new_count: int) -> void:
	data.record_change("edit_zone_outline", {
		"zone_id": zone_id,
		"op": op,
		"vertex_index": index,
		"old_point_count": old_count,
		"point_count": new_count,
	})
	data.data_changed.emit()

#endregion


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
func _rotate_selected(ccw: bool = false) -> void:
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
			if ccw:
				comp.rotate_counterclockwise()
			else:
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
		turned += data.rotate_group(
			data.group_anchor_id(group_id), -90.0 if ccw else 90.0).size()

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
## state" rule. Silent by default: the user asked for another tool, so the
## abandoned draw is expected, not something to report. `announce_cancel` lets a
## caller opt into the OTHER house convention _cancel_zone_draw/_cancel_trace_draw
## already support for an explicit Esc/right-click cancel, for a transition that
## is not a plain tool switch — PCBPanel's re-click-disarm (item 5, 019fbbadd8f0)
## is exactly that: the user re-clicked the armed button as an explicit "get me
## out" gesture, so any abandoned polygon/trace is announced, not silently dropped.
##
## ORDER MATTERS when announce_cancel is true (cold review F1): the cancel call
## — and therefore its toast — is deliberately made AFTER tool_mode_changed.emit
## below, not before. tool_mode_changed is synchronous and PCBPanel's handler
## ends in an unconditional _update_status() that overwrites the status label
## with the standing text; emitting the cancel toast before that point gets it
## clobbered in the same call, before a frame ever renders (measured). Emitting
## it after means the toast lands on top of the just-refreshed standing text,
## which is what _show_transient_status's 2s-revert contract assumes. The
## "leaving a zone/trace tool" decision itself still reads the OUTGOING
## tool_mode, captured into locals before the reassignment below — by the time
## the cancel call runs, tool_mode already holds the new value, but nothing in
## _cancel_zone_draw/_cancel_trace_draw ever reads tool_mode, so this is safe.
##
## TWO STANDING GUARANTEES the emit window relies on (re-review N1/N2 — pin
## them here so a future edit re-checks): tool_mode_changed has exactly ONE
## listener repo-wide, and _sync_draw_arm_ui's in-window status write is safe
## only because the re-click disarm target is hardcoded SELECT. Adding a
## second listener, or a disarm target with in-progress draw state, re-opens
## the clobber/re-entrancy questions measured in cold review B1u4.
func set_tool_mode(mode: ToolMode, announce_cancel: bool = false) -> void:
	if tool_mode != mode:
		if tool_mode == ToolMode.INSPECT_PIN or mode == ToolMode.INSPECT_PIN:
			_clear_inspect_pin_selection()
		var leaving_zone_tool := _is_zone_tool()
		var leaving_trace_tool := tool_mode == ToolMode.TRACE
		var leaving_cutout_tool := tool_mode == ToolMode.CUTOUT
		var leaving_bus_tool := tool_mode == ToolMode.BUS
		# Leaving Select ends any annotation gesture in flight (B1u3) — the
		# universal Select is disarmed by the panel on this same transition, so
		# the release would arrive with nothing to receive it.
		_annotation_gesture = false
		tool_mode = mode
		tool_mode_changed.emit(mode)
		if leaving_zone_tool:
			_cancel_zone_draw(announce_cancel)
		if leaving_trace_tool:
			_cancel_trace_draw(announce_cancel)
		if leaving_cutout_tool:
			_cancel_cutout_draw(announce_cancel)
		if leaving_bus_tool:
			# Leaving the tool ENTIRELY discards BOTH halves of its state
			# (picks AND any in-progress spine) in one go — unlike the Esc
			# ladder's incremental peel (_cancel_bus_step), which exists so a
			# user mid-draw can back off one level without losing the net
			# order they already picked. A plain tool switch abandons all of
			# it, the same "switching modes clears in-progress state" rule
			# TRACE/CUTOUT/zone already follow.
			_reset_bus_tool(announce_cancel)
		queue_redraw()

#endregion


#region Pin Inspector (WC-1)

## Bind the PcbAnnotationHost (duck-typed) that owns pad_at()/pin_info() — the
## canvas never hit-tests pads itself, it only drives the host through it.
func set_pin_inspector_host(host) -> void:
	_pin_inspector_host = host


## Bind the annotation half of the unified Select (B1u3). `router` is the
## PcbAnnotationHost; PCBPanel wires it beside set_pin_inspector_host. Passing
## null (teardown, headless fixtures) restores board-only behavior.
func set_annotation_router(router) -> void:
	_annotation_router = router
	_annotation_gesture = false


## Duck-typed reach into the router. Returns null unless the router is alive AND
## advertises `method` — one guard, used by every hook, so a router that only
## half-implements the protocol degrades per-verb instead of erroring.
func _router_with(method: String):
	if _annotation_router == null:
		return null
	if _annotation_router is Object and not is_instance_valid(_annotation_router):
		return null
	if not _annotation_router.has_method(method):
		return null
	return _annotation_router


## The modifier mask an annotation tool expects, built from a mouse event.
## Mirrors AnnotationOverlay._mods_from_event — the tools' documented contract is
## the mask, and the canvas is standing in for the overlay here.
static func _annotation_mods(event: InputEventWithModifiers) -> int:
	var mods := 0
	if event.shift_pressed:
		mods |= KEY_MASK_SHIFT
	if event.ctrl_pressed:
		mods |= KEY_MASK_CTRL
	if event.alt_pressed:
		mods |= KEY_MASK_ALT
	if event.meta_pressed:
		mods |= KEY_MASK_META
	return mods


## Is the annotation layer claiming this LEFT press? True means the gesture has
## been handed over and the caller must return.
##
## A plain (non-shift) claim REPLACES the whole selection, so the board half is
## dropped here — that is what makes one Select feel like one Select rather than
## two selections that happen to share a button. A shift-claim edits set
## membership and leaves the board half alone, matching what shift does on either
## side taken separately.
func _claim_annotation_press(event: InputEventMouseButton) -> bool:
	var router = _router_with("annotation_claims_point")
	if router == null:
		return false
	# mods GO IN, not just out: the annotation layer declines a shift-press that
	# misses its ink, because a shift+box has to be swept by the canvas so it can
	# take BOTH halves. Handing the claim a bare position instead loses the board
	# half of every shift-drag that starts inside a selected annotation's gizmo
	# ring — a ~14px band around something already selected (cold review N1).
	var mods := _annotation_mods(event)
	if not bool(router.annotation_claims_point(event.position, mods)):
		return false

	# F1 (cold review, station 7 fix round): "what you see on top is what you
	# click" — rung 0's OWN justification, restated above — is exactly what
	# breaks if this claim is honored blind. A route hint whose _render_mode_for
	# has withheld its polyline ("markers": a live candidate owns that corridor;
	# "none": consumed — zero ink at all) still answers hit_test() as
	# if the whole corridor were drawn — AnnotationKind.hit_test() has no host
	# param (documented limitation, pcb_route_hint_kind.gd), so it cannot know
	# its own render mode. The router's claim above is therefore blind to it
	# too. So: a press the router just claimed, but that only landed ink on a
	# markers-mode hint's now-INVISIBLE corridor (not its visible marker discs
	# / label — the ink actually on screen), is declined here and falls through
	# to the board ladder below, so the candidate ghost actually drawn on top
	# takes the click instead of the hidden hint popping back to "full" via
	# selection and resurrecting the very route the candidate is superseding.
	if _route_hint_masks_claim(event.position):
		return false

	if not event.shift_pressed:
		_clear_selection()

	_annotation_gesture = true
	if event.double_click and _router_with("annotation_pointer_double_click") != null:
		router.annotation_pointer_double_click(event.position, MOUSE_BUTTON_LEFT, mods)
	elif _router_with("annotation_pointer_down") != null:
		router.annotation_pointer_down(event.position, MOUSE_BUTTON_LEFT, mods)
	# The PANEL's selection changed even though no board id list did: this is the
	# feed the trash button, the status bar and the property inspector live on,
	# and a Select that lights up half of them is the two-worlds symptom again.
	selection_changed.emit()
	queue_redraw()
	return true


## F1 gate (cold review, station 7 fix round): does the press at `screen_pos`
## land only on a pcb_route_hint's INVISIBLE corridor while that hint is
## rendering in "markers" mode (or "none" — a consumed hint, which masks
## unconditionally)? See _claim_annotation_press's
## own comment for why this has to be checked at all.
##
## Walks annotations topmost-first, testing kind.hit_test() ink — the SAME
## algorithm core AnnotationTransformTool._hit_test_topmost uses, which is also
## exactly what claims_point() falls back to for a plain click on an
## unselected annotation (the common case this finding names: clicking a
## candidate ghost sitting under a hint's hidden corridor). Stops at the FIRST
## ink hit — the topmost annotation is the only one whose claim could need
## masking here, same "what's on top wins" rule the rest of the ladder uses.
##
## Scope, stated honestly: this does not replicate claims_point()'s gizmo-zone
## or caption-handle branches — those only ever fire for the SINGLE
## already-selected annotation, and a selected hint never needs masking:
## selection renders "full" for every selectable hint, and the one mode that
## renders nothing ("none", consumed) can never BE selected —
## PcbAnnotationHost's selection veto refuses applied hints at every setter
## and deselects on the lifecycle flip (Epoch UX2 station 1, cold review F1).
func _route_hint_masks_claim(screen_pos: Vector2) -> bool:
	var router = _router_with("get_registry")
	if router == null or not router.has_method("get_annotations") \
			or not router.has_method("transform_screen_to_doc") \
			or not router.has_method("is_annotation_visible"):
		return false
	var registry = router.get_registry()
	if registry == null:
		return false
	var doc_pos: Vector2 = router.transform_screen_to_doc(screen_pos)
	var hit_threshold := ANNOTATION_HIT_SLACK_PX / maxf(zoom, 0.01)
	var annotations: Array = router.get_annotations()
	for i in range(annotations.size() - 1, -1, -1):
		var ann_v: Variant = annotations[i]
		if not (ann_v is Dictionary):
			continue
		var ann: Dictionary = ann_v
		if not router.is_annotation_visible(ann):
			continue
		var kind: AnnotationKind = registry.get_annotation_kind(StringName(str(ann.get("kind", ""))))
		if kind == null or not kind.hit_test(ann, doc_pos, hit_threshold):
			continue
		# Topmost ink hit — mask only if it is a route hint currently in a
		# markers mode AND the press missed its visible ink; anything else
		# (a different kind, or a "full" hint) is a legitimate claim.
		if kind.has_method("_render_mode_for") and kind.has_method("_visible_ink_hit"):
			var mode: String = kind._render_mode_for(ann, router)
			# "none" (Epoch UX2 station 1): a consumed hint draws nothing, so
			# EVERY press that lands on its (invisible) corridor falls through
			# to whatever is actually on screen beneath it.
			if mode == "none":
				return true
			if mode == "markers":
				return not bool(kind._visible_ink_hit(ann, doc_pos, hit_threshold, zoom))
		return false
	return false


## Duck-typed twin of core AnnotationTransformTool._is_path_kind (station 6
## fix F1). This off-tree script cannot preload/class-reference that tool
## (a dangling off-tree class reference is a parse error that deregisters the
## whole kind — see the file's own Round B note), so the gate is restated
## against the SAME three methods rather than shared. A kind that declares
## "path" without the full API degrades safely to "not path-eligible" here,
## exactly like core's own gate.
static func _is_path_kind(kind: AnnotationKind) -> bool:
	if kind == null:
		return false
	if kind.manipulation_profile() != "path":
		return false
	return kind.has_method("bend_points") \
		and kind.has_method("with_bend_points") \
		and kind.has_method("nearest_bend_insertion")


## Resolve a path-kind annotation's bend handle at `world_pos` (board mm) —
## station 6 fix F1. {} on ANY miss: no router, no exactly-one selection, the
## selection is not a path kind, or the press missed every handle. Only the
## SINGLE currently-selected annotation is considered — mirrors core's own
## gate (AnnotationTransformTool._is_path_kind is reached only from a
## single-selection branch) and BendHandleEditTool's _multi_selected rule:
## with more than one thing selected there is no unambiguous edit target.
func _annotation_bend_hit_at(world_pos: Vector2) -> Dictionary:
	var router = _router_with("get_selected_annotation_id")
	if router == null or not router.has_method("get_by_id") \
			or not router.has_method("get_registry") \
			or not router.has_method("selected_annotation_count"):
		return {}
	if router.selected_annotation_count() != 1:
		return {}
	var ann_id: String = router.get_selected_annotation_id()
	if ann_id.is_empty():
		return {}
	var ann: Dictionary = router.get_by_id(ann_id)
	if ann.is_empty():
		return {}
	var registry = router.get_registry()
	if registry == null:
		return {}
	var kind: AnnotationKind = registry.get_annotation_kind(StringName(str(ann.get("kind", ""))))
	if not _is_path_kind(kind):
		return {}

	var bends: Array = kind.bend_points(ann)
	# Same px→doc conversion core uses for HANDLE_HIT_RADIUS_DOC (divide the
	# screen-px constant by the live zoom) — `zoom` here IS what
	# PcbAnnotationHost.get_annotation_zoom() returns (it reads this same
	# field), so this is the identical radius core's own hit test computes.
	var handle_r := ANNOTATION_BEND_HIT_PX / maxf(zoom, 0.01)
	for i in range(bends.size()):
		var p: Variant = bends[i]
		if not p is Vector2:
			continue
		if world_pos.distance_to(p as Vector2) < handle_r:
			# The POINT rides along as the bend's identity for the deferred
			# menu action — an index alone can name a different bend by the
			# time the menu closes (see _delete_annotation_bend's guard).
			return {"ann_id": ann_id, "index": i, "point": p as Vector2}
	return {}


## Drop BOTH halves of the unified selection.
##
## The two GESTURE-level clears use this — Escape, and a plain press on empty
## space — because in this panel both mean "nothing is selected" and a stale
## annotation halo left behind by an Escape is the whole bug this closes.
## Board-internal and programmatic clears keep calling _clear_selection(), which
## stays board-only on purpose: a component selected through the MCP surface must
## not silently deselect the annotation the user is reading.
func _clear_selection_all() -> void:
	_clear_selection()
	var router = _router_with("clear_annotation_selection")
	if router != null:
		router.clear_annotation_selection()


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
##   DRAWING --Esc/right-click-->   cancel (announced)
##   DRAWING --tool switch-->       cancel (silent, unless the switch IS a
##                                  re-click disarm — see set_tool_mode's
##                                  announce_cancel)
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


## Discard the in-progress polygon. `announce` is false for a plain tool switch
## (the user already knows) and true for an explicit Esc/right-click cancel OR
## a re-click disarm (set_tool_mode's announce_cancel — that switch IS the
## explicit "get me out" the user asked for, not an incidental side effect of
## picking a different tool).
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


#region Cutout Authoring (campaign 2 epoch B, unit 3)

## Gesture — the SAME click-per-point family the zone tools use (see the
## _cutout_points declaration for what is deliberately absent):
##   DRAWING --left-click-->         place a vertex
##   DRAWING --double-click/Enter--> close the polygon, commit
##   DRAWING --Esc/right-click-->    cancel (announced)
##   DRAWING --tool switch-->        cancel (silent, unless the switch IS a
##                                   re-click disarm — see set_tool_mode's
##                                   announce_cancel)
##
## This tool AUTHORS A BOARD ENTITY (a Cutout in the model, which serializes
## into the board YAML), exactly like the zone tools — journals + snapshots
## like any other interactive board edit, and every refusal is fail-closed:
## see pcb_data.cutout_author_error for why an invalid cutout is worse than a
## refused gesture (it makes the WHOLE board unserializable).

func _handle_cutout_click(world_pos: Vector2, is_double_click: bool) -> void:
	# The second press of a physical double-click arrives AFTER the first has
	# already placed its vertex, so it closes the polygon instead of placing a
	# duplicate one on top of it. Mirrors _handle_zone_click exactly.
	if is_double_click:
		_commit_cutout()
		return
	_cutout_points.append(_author_point(world_pos))
	_cutout_has_preview = false
	queue_redraw()


## Close the in-progress polygon into a real cutout entity. HISTORY ORDER —
## snapshot AFTER the mutation, the same reasoning _commit_zone documents at
## length (bug 019fb5ad791c: a pre-mutation snapshot makes redo silently do
## nothing).
##
## create_cutout emits data_changed, which is what marks the tab dirty (PCBPanel
## relays it to content_changed) — there is no separate dirty flag to set.
##
## The commit toast NAMES the authorable-not-compilable caveat (cold-review F6)
## — the same line the MCP create_cutout tool's schema description carries —
## so a human drawing one learns it here, at the moment it matters, rather than
## discovering it only when a later Gerber/DRC export refuses the board.
func _commit_cutout() -> void:
	if not data or tool_mode != ToolMode.CUTOUT:
		return
	var refusal: String = data.cutout_author_error(_cutout_points.size())
	if not refusal.is_empty():
		# Keep the placed vertices: the fix for "needs 3 points" is another
		# click, not redrawing the whole outline.
		cutout_tool_message.emit(refusal)
		return

	var cutout: Dictionary = data.create_cutout(_cutout_points)
	if cutout.is_empty():
		# cutout_author_error already passed, so this is a model-side refusal we
		# did not anticipate. Report it rather than leaving a silent no-op behind.
		cutout_tool_message.emit("Cutout was refused by the board model — see the log.")
		return
	data.save_to_history("Add cutout")
	var point_count := _cutout_points.size()
	_reset_cutout_draw()
	cutout_tool_message.emit(
		"Added cutout (%d points) — authored only, not yet compiled: routing/DRC/Gerber export ignore it."
		% point_count)
	queue_redraw()


## Discard the in-progress polygon. `announce` mirrors _cancel_zone_draw's: false
## for a plain tool switch (the user already knows), true for an explicit
## Esc/right-click cancel or a re-click disarm.
func _cancel_cutout_draw(announce: bool) -> void:
	if _cutout_points.is_empty():
		return
	_reset_cutout_draw()
	if announce:
		cutout_tool_message.emit("Cutout cancelled.")
	queue_redraw()


func _reset_cutout_draw() -> void:
	_cutout_points = PackedVector2Array()
	_cutout_has_preview = false


## Draw the polygon being born, in the SAME visual language committed cutouts
## use (cutout_color, same outline width) so it reads as the cutout itself
## rather than a generic rubber band — mirrors _draw_zone_preview.
func _draw_cutout_preview() -> void:
	if _cutout_points.is_empty():
		return

	var screen_pts := PackedVector2Array()
	for p in _cutout_points:
		screen_pts.append(world_to_screen(p))
	var cursor_pt := world_to_screen(_cutout_preview) if _cutout_has_preview else Vector2.ZERO

	var open_path := screen_pts.duplicate()
	if _cutout_has_preview:
		open_path.append(cursor_pt)
	if open_path.size() >= 2:
		draw_polyline(open_path, Color(cutout_color, cutout_outline_alpha), cutout_outline_width_px)

	# The closing edge back to the first vertex is dimmer: it is where the
	# polygon WILL close, not an edge the user has drawn yet.
	var last_pt: Vector2 = open_path[open_path.size() - 1]
	if open_path.size() >= 3:
		draw_line(last_pt, screen_pts[0], Color(cutout_color, CUTOUT_PREVIEW_CLOSE_ALPHA), cutout_outline_width_px)

	for pt in screen_pts:
		draw_circle(pt, CUTOUT_PREVIEW_VERTEX_RADIUS_PX, Color(cutout_color, cutout_outline_alpha))

	if font != null:
		var label := "Cutout  ·  %d pts" % _cutout_points.size()
		draw_string(font, screen_pts[0] + Vector2(6.0, -6.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(cutout_color, cutout_outline_alpha))

#endregion


#region Trace Authoring (epoch 6 unit 5)

## Gesture (KiCad's route-a-track grammar, expressed in the same click-per-point
## family the zone tools use — one gesture grammar on this canvas, not three):
##   ARMED   --click a pad-->        start; net + layer frozen from that pad
##   DRAWING --left-click-->         place a waypoint
##   DRAWING --click ANY pad-->      finish at that pad's centre and commit
##   DRAWING --double-click/Enter--> finish at the last waypoint (dangling)
##   DRAWING --Esc/right-click-->    cancel (announced)
##   DRAWING --tool switch-->        cancel (silent, unless the switch IS a
##                                   re-click disarm — see set_tool_mode's
##                                   announce_cancel)
##
## This is the DIRECT-AUTHORING sibling of the Proposals-group trace tool, not a
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


## Discard the in-progress trace. `announce` is false for a plain tool switch
## (the user already knows) and true for an explicit Esc/right-click cancel OR
## a re-click disarm (set_tool_mode's announce_cancel — that switch IS the
## explicit "get me out" the user asked for, not an incidental side effect of
## picking a different tool).
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


#region Bus Authoring (campaign 2 epoch C, unit 5 — DCR 019fb572b888 S3+S4)

## Gesture, in two phases (S3 then S4):
##   PICKING --click a pad/trace-->     add that net to the ordered list
##   PICKING --click an ALREADY-LISTED net's pad/trace--> remove it
##   PICKING --Enter (2+ nets)-->       start DRAWING, freezing the layer
##   PICKING --Enter (< 2 nets)-->      refused (transient message, stays armed)
##   DRAWING --left-click-->            place a spine vertex
##   DRAWING --double-click/Enter-->    commit (needs >=2 spine points; see
##                                      the INNER-FOLD GUARD below)
##   DRAWING --Esc/right-click-->       cancel the SPINE ONLY, back to PICKING
##                                      with the net list kept (announced)
##   PICKING --Esc/right-click-->       (nothing drawing) clear the net list
##                                      (announced) — the ladder's second step
##   --tool switch-->                   cancel EVERYTHING, silently unless the
##                                      switch IS a re-click disarm (see
##                                      set_tool_mode's announce_cancel)
##
## This tool AUTHORS N BOARD ENTITIES (real Trace entities, same as Draw ▸
## Trace) in ONE undo step — see _commit_bus. It is the direct-authoring
## sibling of the router's route_bus(), not a UI on top of it: the router is
## never called (see pcb_bus_geometry.gd's own "why not reuse route_bus" note).
##
## THE GEOMETRY PIPELINE (bus_plan/bus_commit_plan, on panel_tools.gd — see the
## preload note at the top of this file) is the ONE implementation shared with
## minerva_pcb_route_bus_direct: per-net width resolution -> board clearance ->
## pitch_between (via BusGeom.cumulative_offsets) -> BusGeom.offset_polyline
## per net -> the INNER-FOLD GUARD (pcb_bus_geometry.gd:78-82's documented
## gap, assigned to this tool layer) -> N create_trace_entity calls -> ONE
## save_to_history. Both the live preview below and the eventual commit call
## bus_plan with the SAME inputs, so what is on screen when Enter is pressed
## is what commits, or refuses for the reason shown.


## Resolve a click to a net, trying a PAD first (reuses the trace tool's own
## lookup — same source of truth, same net-inheritance rule) then a TRACE
## (data.get_trace's net_name). {} on a miss.
func _bus_net_at(world_pos: Vector2) -> Dictionary:
	var pad_hit := _trace_pad_at(world_pos)
	if not pad_hit.is_empty():
		return {"net": str(pad_hit.get("net", "")), "ref": str(pad_hit.get("ref", ""))}
	if data == null:
		return {}
	var trace_id := _trace_at(world_pos)
	if not trace_id.is_empty():
		var trace = data.get_trace(trace_id)
		if trace != null:
			return {"net": str(trace.net_name), "ref": "trace %s" % trace_id}
	return {}


func _handle_bus_click(world_pos: Vector2, is_double_click: bool) -> void:
	if is_double_click and _bus_drawing:
		_commit_bus()
		return
	if not _bus_drawing:
		# The PICKING grammar has no double-click verb. A physical double-click
		# arrives as TWO press events (see the zone/trace/cutout tools' own
		# note on this) — the FIRST already performed the pick/remove-by-
		# reclick; without this guard the SECOND event would hit
		# _handle_bus_pick_click again and immediately toggle the same net
		# back off, silently netting to "nothing picked" on what looked like
		# one click to the user.
		if is_double_click:
			return
		_handle_bus_pick_click(world_pos)
		return
	# DRAWING: place a spine vertex, same shape as _handle_trace_click's
	# waypoint branch (this tool has no pad-to-finish shortcut — a spine ends
	# on Enter/double-click only, since it is not itself copper on a net).
	_bus_spine_points.append(_author_point(world_pos))
	_bus_has_preview = false
	queue_redraw()


## PICKING click: resolve the net, then toggle it in/out of the ordered list.
func _handle_bus_pick_click(world_pos: Vector2) -> void:
	var hit := _bus_net_at(world_pos)
	if hit.is_empty():
		bus_tool_message.emit("Click a pad or a trace — that is where a net comes from.")
		return
	var net := str(hit.get("net", ""))
	if net.is_empty():
		bus_tool_message.emit("%s is on no net." % str(hit.get("ref", "")))
		return

	var idx := _bus_nets.find(net)
	if idx != -1:
		# Click an already-listed net again to remove it (S3's own contract).
		_bus_nets.remove_at(idx)
		_bus_net_refs.remove_at(idx)
		bus_tool_message.emit("Removed %s from the bus (%d picked)." % [net, _bus_nets.size()])
		queue_redraw()
		return

	_bus_nets.append(net)
	_bus_net_refs.append(str(hit.get("ref", "")))
	var msg := "Bus: [%s] (%d picked)" % [_bus_nets_joined(), _bus_nets.size()]
	msg += " — Enter to draw the spine." if _bus_nets.size() >= 2 else " — pick at least 1 more net."
	bus_tool_message.emit(msg)
	queue_redraw()


func _bus_nets_joined() -> String:
	var parts := PackedStringArray()
	for net in _bus_nets:
		parts.append(net)
	return " → ".join(parts)


## PICKING -> DRAWING. Freezes the layer the same way _start_trace freezes
## _trace_layer — the preview below draws in that layer's colour at the real
## per-net widths, so a toolbar layer-filter change mid-draw cannot silently
## commit different copper from what is on screen.
func _start_bus_draw() -> void:
	if _bus_nets.size() < 2:
		bus_tool_message.emit("Pick at least 2 nets before drawing the spine (%d picked)." % _bus_nets.size())
		return
	var layer := trace_author_layer()
	if layer.is_empty():
		bus_tool_message.emit("This board declares no copper layer to draw the bus on.")
		return
	_bus_layer = layer
	_bus_drawing = true
	_bus_spine_points = PackedVector2Array()
	_bus_has_preview = false
	bus_tool_message.emit(
		"Spine for [%s] on %s — click vertices, Enter/dbl-click commits, Shift+Enter proposes ghosts (Esc cancels the spine)."
			% [_bus_nets_joined(), _bus_layer])
	queue_redraw()


## Turn the drawn spine into N real Trace entities, ONE undo step. Delegates
## the whole pipeline (widths -> offsets -> inner-fold guard -> create -> one
## save_to_history) to panel_tools.bus_plan/bus_commit_plan — see the region
## doc above for why this is the SAME call minerva_pcb_route_bus_direct makes.
## `propose` (Shift+Enter, docket 019fcac1509d): the same ok'd plan lands as
## workspace GHOST candidates via panel_tools.bus_propose_plan — the identical
## function minerva_pcb_workspace_propose_bus calls — instead of copper.
func _commit_bus(propose: bool = false) -> void:
	if not data or tool_mode != ToolMode.BUS or not _bus_drawing:
		return
	var plan: Dictionary = _PanelToolsScript.bus_plan(data, _bus_nets, _bus_spine_points, _bus_layer)
	if not bool(plan.get("ok", false)):
		# Keep the placed vertices AND the net list: the fix for "needs 2
		# points" or an inner-fold refusal is another click or a wider corner,
		# not redrawing the whole bus from scratch.
		bus_tool_message.emit(str(plan.get("error", "Bus was refused.")))
		return

	if propose:
		var out: Dictionary = _PanelToolsScript.bus_propose_plan(_routing_workspace, data, plan)
		if not bool(out.get("ok", false)):
			bus_tool_message.emit(str(out.get("error", "Bus proposal was refused.")))
			return
		var held: Array = out.get("holds", []) if out.get("holds", []) is Array else []
		var prop_summary := "Proposed bus: %d ghost traces on %s (%s) — accept/reject/pin in the workspace." % [
			int(out.get("proposed", 0)), _bus_layer, _bus_nets_joined()]
		if not held.is_empty():
			prop_summary += " %d net(s) held by a pinned candidate." % held.size()
		_reset_bus_tool(false)
		bus_tool_message.emit(prop_summary)
		queue_redraw()
		return

	var result: Dictionary = _PanelToolsScript.bus_commit_plan(
		data, plan, "Add bus (%d traces)" % _bus_nets.size())
	if not bool(result.get("ok", false)):
		bus_tool_message.emit(str(result.get("error", "Bus was refused by the board model.")))
		return

	var trace_ids: Array = result.get("trace_ids", [])
	var summary := "Added bus: %d traces on %s (%s)." % [
		trace_ids.size(), _bus_layer, _bus_nets_joined()]
	_reset_bus_tool(false)
	bus_tool_message.emit(summary)
	queue_redraw()


## The Esc/right-click LADDER (S4): peel ONE level per press. A spine in
## progress is the innermost gesture — cancelling it must not also throw away
## the net order the user already picked, which is the whole point of
## treating this as a ladder instead of one flat reset (that flat reset is
## _reset_bus_tool, reserved for actually leaving the tool — see
## set_tool_mode).
func _cancel_bus_step(announce: bool) -> void:
	if _bus_drawing:
		_bus_drawing = false
		_bus_spine_points = PackedVector2Array()
		_bus_has_preview = false
		_bus_layer = ""
		if announce:
			bus_tool_message.emit("Bus spine cancelled — net list kept (%d picked)." % _bus_nets.size())
		queue_redraw()
		return
	if not _bus_nets.is_empty():
		_bus_nets = []
		_bus_net_refs = []
		if announce:
			bus_tool_message.emit("Bus net picks cleared.")
		queue_redraw()


## Full reset — BOTH the net list and any in-progress spine. Used only when
## actually LEAVING the tool (set_tool_mode) or after a successful commit,
## never by the Esc ladder above (see _cancel_bus_step).
func _reset_bus_tool(announce: bool) -> void:
	var had_progress := _bus_drawing or not _bus_nets.is_empty()
	_bus_drawing = false
	_bus_spine_points = PackedVector2Array()
	_bus_has_preview = false
	_bus_layer = ""
	_bus_nets = []
	_bus_net_refs = []
	_bus_plan_cache_key = []
	_bus_plan_cache = {}
	if announce and had_progress:
		bus_tool_message.emit("Bus tool disarmed — picks and spine discarded.")


## Draw the bus being born: the raw spine as a rubber band (same visual
## language _draw_trace_preview uses), then the N per-net GHOST offset
## polylines bus_plan would commit — TOOL PREVIEW geometry, not a workspace
## candidate (see the region doc + this file's _draw for the depth this
## renders at). The spine tints BUS_REFUSAL_COLOR the instant the current
## geometry would trip the inner-fold guard, so the refusal is visible before
## Enter is ever pressed, not only after a failed commit.
func _draw_bus_preview() -> void:
	if not _bus_drawing:
		return

	var screen_pts := PackedVector2Array()
	for p in _bus_spine_points:
		screen_pts.append(world_to_screen(p))
	var cursor_pt := world_to_screen(_bus_preview) if _bus_has_preview else Vector2.ZERO

	var plan: Dictionary = {}
	if _bus_spine_points.size() >= 2:
		# Memo (N4): reuse last frame's plan when nothing it depends on moved
		# — see _bus_plan_cache_key's own doc for why only the spine actually
		# varies frame to frame during DRAWING.
		var cache_key: Array = [_bus_nets.duplicate(), _bus_spine_points.duplicate(), _bus_layer]
		if cache_key == _bus_plan_cache_key:
			plan = _bus_plan_cache
		else:
			plan = _PanelToolsScript.bus_plan(data, _bus_nets, _bus_spine_points, _bus_layer)
			_bus_plan_cache_key = cache_key
			_bus_plan_cache = plan
	var refused: bool = _bus_spine_points.size() >= 2 and not bool(plan.get("ok", false))
	var spine_color: Color = BUS_REFUSAL_COLOR if refused else BUS_SPINE_PREVIEW_COLOR

	var open_path := screen_pts.duplicate()
	if _bus_has_preview:
		open_path.append(cursor_pt)
	if open_path.size() >= 2:
		draw_polyline(open_path, spine_color, 1.0)
	for pt in screen_pts:
		draw_circle(pt, TRACE_PREVIEW_VERTEX_RADIUS_PX, spine_color)

	# N ghost offset polylines — only once the plan is valid (a refused plan
	# has no polylines to show; the tinted spine above already carries the
	# refusal). Net colour where the net has one, layer colour otherwise —
	# mirrors _draw_zone_preview's fallback.
	if bool(plan.get("ok", false)):
		var nets: Array = plan.get("nets", [])
		var widths: Array = plan.get("widths", [])
		var polylines: Array = plan.get("polylines", [])
		for i in range(nets.size()):
			var pts: PackedVector2Array = polylines[i]
			if pts.size() < 2:
				continue
			var ghost_color := _trace_layer_color(_bus_layer)
			var net_obj = data.get_net(str(nets[i])) if data else null
			if net_obj:
				ghost_color = net_obj.color
			var ghost_pts := PackedVector2Array()
			for p in pts:
				ghost_pts.append(world_to_screen(p))
			var width_px := maxf(float(widths[i]) * zoom, 1.0)
			draw_polyline(ghost_pts, Color(ghost_color, BUS_GHOST_ALPHA), width_px)

	if font != null and not screen_pts.is_empty():
		var label := "Bus [%s] @ %s  ·  %d pts" % [_bus_nets_joined(), _bus_layer, _bus_spine_points.size()]
		if refused:
			label += "  ·  %s" % str(plan.get("error", ""))
		draw_string(font, screen_pts[0] + Vector2(6.0, -6.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, spine_color)

#endregion


#region Route Candidates (S3 — DCR 019f7095c395)

## ── ONE GEOMETRY SOURCE FOR THREE CONSUMERS ───────────────────────────────────
##
## candidate_draw_items() below is the SINGLE derivation of what a route candidate
## looks like on this canvas. The draw path walks it, the click pick walks it, and
## the anchor lookup walks it. That is not tidiness — it is the unit's central
## correctness claim (rendered geometry == hit-test geometry == model geometry),
## and it is the only way to make that claim testable on an IMMEDIATE-MODE canvas,
## which has no child nodes to inspect after a frame. A test asserts on the data
## the draw path reads.
##
## ── INV-4: EXACT GEOMETRY, NEVER WAYPOINTS ────────────────────────────────────
## Every item is built from RouteCandidate.segments (each with its OWN layer,
## width and ordered points) and RouteCandidate.vias. The word "waypoint" does not
## appear anywhere in this region, and must not: waypoints are the FLATTENED,
## layer-losing polyline the route-HINT annotation kind carries
## (pcb_route_hint_kind.gd, whose fork now refuses candidate-sourced payloads —
## see the guard there). Flattening a candidate would hide the very layer changes
## a reviewer has to see before accepting. If a future edit needs a polyline for a
## candidate, it comes from a segment's points, not from a waypoint list.
##
## Points are in WORLD (board mm) — the model's own units, unconverted — so an
## item's geometry is bit-for-bit the candidate's geometry. The draw loop applies
## world_to_screen; the pick converts its tolerances the other way (the
## px-constants-through-the-zoom idiom this file already keeps).

## Bind the routing workspace + cutover coordinator (PCBPanel wires both). Passing
## null for either restores pre-S3 behaviour exactly.
##
## THE SIGNAL WIRING LIVES HERE, not in the panel, for the same reason set_data
## owns its own reconnects: this is the one place that knows which workspace
## instance is current, so it is the one place that can disconnect the previous
## one. Duck-typed throughout — a workspace missing a signal simply is not
## connected to it, and the surface degrades per-signal rather than erroring.
func set_routing_workspace(workspace, cutover = null) -> void:
	if _routing_workspace == workspace and _routing_cutover == cutover:
		return
	_disconnect_workspace_signals()
	_routing_workspace = workspace
	_routing_cutover = cutover
	_connect_workspace_signals()
	queue_redraw()


## The workspace signals whose payloads change what this canvas draws.
##
## WHY THESE FIVE, named rather than "everything the workspace emits":
##   candidate_added        — an ingest landed a new ghost (propose / re-propose)
##   candidate_changed      — a DISPOSITION moved (pin/unpin/reject/supersede/
##                            commit): the outline channel and the terminal filter
##                            both read it
##   candidate_removed      — the ghost is gone
##   validation_changed     — the STALE dash and the VIOLATING marker channels
##   ingest_task_held       — a pinned candidate held its task, so the batch
##                            landed FEWER ghosts than routes were requested; the
##                            frame that follows must show the pinned prior still
##                            standing rather than a phantom replacement
## transition_refused and task_state_changed are deliberately NOT here: neither
## changes a single pixel (a refused move left the value unchanged by contract,
## and task state is derived bookkeeping with no render of its own). Connecting
## them would buy a redraw per refusal and prove nothing.
const _WORKSPACE_REDRAW_SIGNALS := [
	"candidate_added", "candidate_changed", "candidate_removed",
	"validation_changed", "ingest_task_held",
]


func _connect_workspace_signals() -> void:
	if _routing_workspace == null:
		return
	for sig in _WORKSPACE_REDRAW_SIGNALS:
		if not _routing_workspace.has_signal(sig):
			continue
		if not _routing_workspace.is_connected(sig, _on_workspace_changed):
			_routing_workspace.connect(sig, _on_workspace_changed)


func _disconnect_workspace_signals() -> void:
	if _routing_workspace == null:
		return
	if _routing_workspace is Object and not is_instance_valid(_routing_workspace):
		_routing_workspace = null
		return
	for sig in _WORKSPACE_REDRAW_SIGNALS:
		if not _routing_workspace.has_signal(sig):
			continue
		if _routing_workspace.is_connected(sig, _on_workspace_changed):
			_routing_workspace.disconnect(sig, _on_workspace_changed)


## ONE handler for all five signals. Variadic-by-ignoring: every one of them
## carries between one and three String arguments, and none of them is read — the
## canvas re-derives the whole candidate set each frame anyway (immediate mode),
## so a per-id incremental redraw would be strictly more code for the same pixels.
func _on_workspace_changed(_a: String = "", _b: String = "", _c: String = "") -> void:
	queue_redraw()
	# F2 (cold review, station 7 fix round): pcb_route_hint_kind.render() now
	# depends on live-candidate state (its render-taxonomy gate), but that
	# render lives on the ANNOTATION overlay — a separate CanvasItem that only
	# redraws on ITS OWN annotations/selection/view signals, none of which a
	# workspace-only change (propose/reject/supersede) fires. Without this, a
	# reject left a route hint stuck in "markers" mode (no polyline — a live
	# candidate drew that corridor a moment ago) with the candidate now GONE
	# too: no visible representation of the route at all, until some unrelated
	# interaction (pan/zoom/select) happened to repaint the overlay. Reusing
	# view_changed here is the SAME poke pan/zoom/fit already use to reach the
	# overlay (PcbAnnotationHost relays it to the base AnnotationHost signal
	# AnnotationOverlay listens on) — no new seam, and a safe no-op if nothing
	# is listening (headless canvas, no panel wired).
	view_changed.emit()


## Is the candidate surface live? THE ONE GATE — every render, pick, anchor and
## menu path below asks this first.
##
## Three conditions, all required: a workspace to read, a cutover coordinator to
## ask, and that coordinator saying the "canvas" surface is workspace-authoritative
## (pcb_routing_cutover.gd). A MISSING cutover reads as OFF, not as ON: the
## coordinator's own rule is that an unrecognised surface can never be treated as
## migrated, and the same fail-safe applies to a canvas nobody wired one into.
##
## THE DEFAULT IS STILL OFF, which is why the existing suites remain the proof of
## "no behaviour change" for every unwired canvas: a fixture that builds a canvas
## without a coordinator, or with a fresh one, gets false here and the whole unit
## is inert. A canvas belonging to a MOUNTED PCBPanel gets true — C4a's write path
## landed and PCBPanel._build_ui flips "canvas" at the workspace handoff.
func _candidates_active() -> bool:
	if _routing_workspace == null or _routing_cutover == null:
		return false
	if _routing_workspace is Object and not is_instance_valid(_routing_workspace):
		return false
	if not _routing_cutover.has_method("is_workspace_authoritative"):
		return false
	return bool(_routing_cutover.is_workspace_authoritative("canvas"))


## Which dispositions put a candidate on the canvas at all.
##
## ONLY NON-TERMINAL CANDIDATES RENDER, and each exclusion is a decision:
##   proposed / pinned  — DRAW. These are the live drafts the human is judging.
##   superseded         — never. It is the historical record of a replaced
##                        generation; drawing it would put two answers to one
##                        task on screen and make the newer one unreadable where
##                        they overlap (and the overlap is total — a re-route of
##                        the same net covers the same ground).
##   rejected           — never. The user already said no; redrawing it is the
##                        canvas arguing with them.
##   committed          — never, AND THIS ONE IS THE TRAP: a committed candidate's
##                        copper IS on the board, drawn by _draw_traces from
##                        PCBData as REAL copper. Rendering the ghost too would
##                        DOUBLE-DRAW the same route — a brighter, thicker line
##                        that reads as a DRC-worthy overlap and is not one. The
##                        board is the display of a committed candidate.
const CANDIDATE_RENDERED_DISPOSITIONS := ["proposed", "pinned"]


## Is this candidate segment drawable in the current view? The candidate twin of
## _trace_visible / _zone_visible / _via_visible, and the SINGLE source for both
## the draw and the pick (which share candidate_draw_items, so they cannot drift).
##
## The per-layer filter applies for the reason _trace_at's note records for
## copper: a pick that ignored the view would select geometry the user cannot see.
## show_route_candidates is checked by the callers rather than here — the draw
## gates on it in _draw (beside every other show_* flag) and the pick gates on it
## in _candidate_at, exactly as show_traces is handled for copper.
func _candidate_segment_visible(layer: String) -> bool:
	return _layer_visible(_canonical_layer(layer))


## Is this candidate VIA drawable? Board-wide, like _via_visible: a via spans
## layers by definition, so there is no single layer to filter it on. Kept as its
## own named predicate rather than inlined `true` so that if the committed-via
## draw ever gains a filter, there is one obvious place to mirror it.
func _candidate_via_visible() -> bool:
	return true


## THE DERIVATION. Every ghost on this canvas, as flat draw records, in paint
## order (segments first, then vias — vias land on top, mirroring _draw_traces).
##
## Each item:
##   candidate_id  String   the owning candidate
##   item_kind     String   "segment" | "via"
##   item_id       String   the segment's / via's own stable id
##   layer         String   CANONICAL copper layer (segments) or the via's
##                          from_layer (vias) — the colour authority
##   points        Array    Array[Vector2] in BOARD MM. Segments: the segment's
##                          own ordered points, copied verbatim from the model.
##                          Vias: a single-element array holding the via centre,
##                          so every item has geometry in the same field and the
##                          pick/anchor walks do not have to branch to find it.
##   width         float    board mm — stroke width (segments) / diameter (vias)
##   color         Color    _trace_layer_color(layer) at CANDIDATE_GHOST_ALPHA
##   outlined      bool     disposition == "pinned"   (channel 1)
##   dashed        bool     validation  == "stale"    (channel 2)
##   marked        bool     validation in violating/error (channel 3)
##   selected      bool     in selected_candidate_ids (channel 4)
##
## RETURNS [] WHEN THE SURFACE IS OFF — the single gate, so no caller can forget
## it. A malformed segment (fewer than 2 points) is skipped rather than drawn as a
## degenerate stroke; a via with no position is skipped the same way.
func candidate_draw_items() -> Array:
	var items: Array = []
	if not _candidates_active():
		return items
	if not _routing_workspace.has_method("list_candidates"):
		return items

	for cand in _routing_workspace.list_candidates():
		if cand == null:
			continue
		if not (str(cand.disposition) in CANDIDATE_RENDERED_DISPOSITIONS):
			continue
		var cid := str(cand.candidate_id)
		var outlined: bool = str(cand.disposition) == "pinned"
		var validation := str(cand.validation)
		var dashed: bool = validation == "stale"
		var marked: bool = validation == "violating" or validation == "error"
		var selected: bool = cid in selected_candidate_ids

		for seg in cand.segments:
			if not (seg is Dictionary):
				continue
			var seg_dict: Dictionary = seg
			var layer := str(seg_dict.get("layer", "top"))
			if not _candidate_segment_visible(layer):
				continue
			var pts: Array = []
			for p in seg_dict.get("points", []):
				if p is Vector2:
					pts.append(p)
			if pts.size() < 2:
				continue
			items.append({
				"candidate_id": cid,
				"item_kind": "segment",
				"item_id": str(seg_dict.get("id", "")),
				"layer": layer,
				"points": pts,
				"width": float(seg_dict.get("width", 0.25)),
				"color": Color(_trace_layer_color(_canonical_layer(layer)), CANDIDATE_GHOST_ALPHA),
				"outlined": outlined,
				"dashed": dashed,
				"marked": marked,
				"selected": selected,
			})

		if not _candidate_via_visible():
			continue
		for via in cand.vias:
			if not (via is Dictionary):
				continue
			var via_dict: Dictionary = via
			var pos: Variant = via_dict.get("position", null)
			if not (pos is Vector2):
				continue
			# A via's colour comes from the layer it STARTS on — the same choice
			# the committed-via draw makes by taking the net colour rather than
			# inventing a two-tone disc. from_layer is where the reviewer's eye is
			# already travelling along the incoming segment.
			var from_layer := str(via_dict.get("from_layer", "top"))
			items.append({
				"candidate_id": cid,
				"item_kind": "via",
				"item_id": str(via_dict.get("id", "")),
				"layer": from_layer,
				"points": [pos as Vector2],
				"width": float(via_dict.get("diameter", 0.8)),
				"color": Color(_trace_layer_color(_canonical_layer(from_layer)), CANDIDATE_GHOST_ALPHA),
				"outlined": outlined,
				"dashed": dashed,
				"marked": marked,
				"selected": selected,
			})

	return items


## Endpoint-coincidence epsilon (board mm) for chaining consecutive candidate
## segments into one stroke run. The router splits a route at EXACT shared
## points, so this only has to absorb float noise — it must stay far below any
## real segment length or two distinct-but-close segments would fuse.
const CANDIDATE_RUN_CHAIN_EPSILON_MM := 0.0001


## DRAW-TIME merge of candidate segment items into stroke runs (docket
## 019fce3a9b6d). Consecutive segment items of the SAME candidate, layer and
## width whose endpoints coincide become ONE item whose points are the chained
## polyline — draw_polyline then joins the bends the way _draw_single_trace's
## whole-chain call does for committed copper, instead of leaving wedge gaps
## between butt-ended per-segment rectangles.
##
## DRAW ONLY: candidate_draw_items() stays per-segment for the pick and anchor
## walks (a run's point union is exactly its segments' point union, so nothing
## clickable moved). Via items and non-chaining segments pass through verbatim.
## The merged item drops item_id (a run spans several) — the draw path never
## reads it.
func _merged_candidate_stroke_items(items: Array) -> Array:
	var out: Array = []
	for item in items:
		var prev: Dictionary = out[out.size() - 1] if not out.is_empty() else {}
		if str(item["item_kind"]) == "segment" and not prev.is_empty() \
				and str(prev.get("item_kind", "")) == "segment" \
				and str(prev["candidate_id"]) == str(item["candidate_id"]) \
				and str(prev["layer"]) == str(item["layer"]) \
				and is_equal_approx(float(prev["width"]), float(item["width"])):
			var prev_pts: Array = prev["points"]
			var pts: Array = item["points"]
			if (prev_pts[prev_pts.size() - 1] as Vector2).distance_to(pts[0] as Vector2) \
					<= CANDIDATE_RUN_CHAIN_EPSILON_MM:
				var merged: Array = prev_pts.duplicate()
				for k in range(1, pts.size()):
					merged.append(pts[k])
				prev["points"] = merged
				continue
		var run: Dictionary = item.duplicate()
		run["points"] = (item["points"] as Array).duplicate()
		out.append(run)
	return out


## Paint every ghost. Immediate mode: no nodes are created, so what this function
## reads (candidate_draw_items, through the draw-time run merge) is the only
## thing a test can assert on.
func _draw_route_candidates() -> void:
	for item in _merged_candidate_stroke_items(candidate_draw_items()):
		if str(item["item_kind"]) == "via":
			_draw_candidate_via(item)
		else:
			_draw_candidate_segment(item)


## One ghost segment, in the four channels this unit defines. Order matters —
## halo, then outline, then stroke, then marker — because each later layer must
## stay legible over the earlier one.
func _draw_candidate_segment(item: Dictionary) -> void:
	var screen_pts := PackedVector2Array()
	for p in item["points"]:
		screen_pts.append(world_to_screen(p))
	if screen_pts.size() < 2:
		return
	var stroke_px: float = maxf(float(item["width"]) * zoom, CANDIDATE_MIN_WIDTH_PX)

	# Channel 4 — SELECTION. Same translucent halo the trace and via selections
	# use, in the same colour, so "selected" reads identically for every kind.
	if bool(item["selected"]):
		draw_polyline(screen_pts, Color(trace_selected_color, 0.3),
			stroke_px + CANDIDATE_SELECT_HALO_MARGIN_PX * 2.0)

	# Channel 1 — PINNED OUTLINE. A casing UNDER the stroke, never a recolour of
	# it (see the styling block's rule).
	if bool(item["outlined"]):
		draw_polyline(screen_pts, candidate_pinned_outline_color,
			stroke_px + CANDIDATE_PINNED_OUTLINE_MARGIN_PX)

	# THE GHOST ITSELF — always the layer colour, always at ghost alpha, one
	# draw call per segment so same-layer overlaps composite (see the styling
	# block). Channel 2 (STALE) changes the STROKE PATTERN only, not the colour.
	var color: Color = item["color"]
	if bool(item["dashed"]):
		for i in range(screen_pts.size() - 1):
			_draw_dashed_line(screen_pts[i], screen_pts[i + 1], color, stroke_px,
				CANDIDATE_STALE_DASH_PX)
	else:
		draw_polyline(screen_pts, color, stroke_px)

	# Channel 3 — VIOLATION MARKER at the segment's midpoint. A ring, not a fill:
	# it must say "look here" without hiding the copper it is about. The midpoint
	# is the CENTRE OF THE MIDDLE SUB-SEGMENT, not the average of the endpoints:
	# on an L-shaped route the average lands off the copper entirely, marking
	# empty board.
	if bool(item["marked"]):
		var mid_seg: int = int(floor(float(screen_pts.size() - 1) * 0.5))
		_draw_candidate_marker((screen_pts[mid_seg] + screen_pts[mid_seg + 1]) * 0.5)


## One ghost via — the same four channels, transposed to a disc, exactly as the
## committed-via draw transposes the trace idiom.
func _draw_candidate_via(item: Dictionary) -> void:
	var pos := world_to_screen(item["points"][0])
	var radius: float = maxf(float(item["width"]) * 0.5 * zoom, CANDIDATE_VIA_MIN_RADIUS_PX)

	if bool(item["selected"]):
		draw_circle(pos, radius + CANDIDATE_SELECT_HALO_MARGIN_PX,
			Color(trace_selected_color, 0.3))
	if bool(item["outlined"]):
		draw_arc(pos, radius + CANDIDATE_PINNED_OUTLINE_MARGIN_PX * 0.5, 0.0, TAU, 24,
			candidate_pinned_outline_color, CANDIDATE_VIA_RING_WIDTH_PX)

	# A RING, not a filled disc: a candidate via is a proposed hole, and a solid
	# disc at ghost alpha over committed copper reads as a pad that exists.
	# STALE (channel 2) breaks the ring into arcs — the disc's dash.
	var color: Color = item["color"]
	if bool(item["dashed"]):
		for k in range(6):
			var a0 := TAU * float(k) / 6.0
			draw_arc(pos, radius, a0, a0 + TAU / 12.0, 6, color, CANDIDATE_VIA_RING_WIDTH_PX)
	else:
		draw_arc(pos, radius, 0.0, TAU, 24, color, CANDIDATE_VIA_RING_WIDTH_PX)

	if bool(item["marked"]):
		_draw_candidate_marker(pos)


## Channel 3's mark, in one place so a segment's and a via's verdict look alike.
func _draw_candidate_marker(screen_pos: Vector2) -> void:
	draw_arc(screen_pos, CANDIDATE_MARKER_RADIUS_PX, 0.0, TAU, 16,
		candidate_violation_color, 2.0)


## Which candidate a click at `world_pos` picks, or "".
##
## EXACT GEOMETRY, THE SAME EXACT GEOMETRY THE DRAW USED — this walks
## candidate_draw_items(), so a ghost is clickable exactly where it is visible and
## nowhere else. Not a bounding box, not a flattened polyline, not waypoints.
##
## VIAS BEFORE SEGMENTS, for the reason _entity_at gives for the committed via
## rung: a candidate via sits ON the segments that meet there (that is what a via
## IS), so tested after them it could never be reached. Its claim is tight — its
## own disc plus a minimum click target — so a segment loses only inside that disc.
##
## Within each pass the LAST item wins, so the topmost ghost under the cursor is
## the one picked (items are in paint order — same "what you see on top is what
## you click" rule the whole ladder keeps).
func _candidate_at(world_pos: Vector2) -> String:
	if not show_route_candidates:
		return ""
	var items: Array = candidate_draw_items()
	if items.is_empty():
		return ""

	var via_hit := ""
	var seg_hit := ""
	for item in items:
		if str(item["item_kind"]) == "via":
			var centre: Vector2 = item["points"][0]
			var radius: float = maxf(float(item["width"]) * 0.5,
				CANDIDATE_VIA_HIT_RADIUS_PX / zoom)
			if centre.distance_to(world_pos) <= radius:
				via_hit = str(item["candidate_id"])
			continue
		# Point-to-SEGMENT distance against half the stroke width plus a fixed
		# screen-px slack divided by zoom — the px-constants-through-the-zoom
		# idiom used by the trace and vertex picks above.
		var tol: float = float(item["width"]) * 0.5 + CANDIDATE_HIT_SLACK_PX / zoom
		var pts: Array = item["points"]
		for i in range(pts.size() - 1):
			if _dist_point_to_segment(world_pos, pts[i], pts[i + 1]) <= tol:
				seg_hit = str(item["candidate_id"])
				break

	return via_hit if not via_hit.is_empty() else seg_hit


## Perpendicular distance from `p` to the SEGMENT ab (not the infinite line):
## the projection is clamped to [0,1] so the endpoints answer for anything past
## them. Static + local because the pick must not reach into the annotation kind
## for it (INV-4 keeps the two paths apart, helpers included).
static func _dist_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq <= 0.0:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## The selected route candidate's id, or "" — the public read surface named in the
## extension checklist. Singular by design (see selected_candidate_ids): every
## workspace verb C4a adds acts on ONE candidate, so this is the shape those verbs
## will read. The list itself stays available through get_selected_candidates()
## for the same reason every other kind exposes one.
func get_selected_candidate_id() -> String:
	return "" if selected_candidate_ids.is_empty() else selected_candidate_ids[0]


func get_selected_candidates() -> Array[String]:
	return selected_candidate_ids.duplicate()


## The context menu's candidate section — THE C4a SEAM, and deliberately not a
## menu of verbs that do nothing.
##
## What it adds today is ONE DISABLED IDENTITY LINE naming the candidate the press
## resolved and the state it is in ("Route candidate cand_3 — pinned, stale").
## That is information the user cannot otherwise get from a ghost, it is honest
## about there being no action yet, and it is one line to replace rather than a
## row of live-looking entries that silently no-op. Disabled-rather-than-absent is
## the same choice the locked-entity Delete item already makes here.
##
## ── THE VERBS (C4a) ───────────────────────────────────────────────────────────
## Commit · Pin (or Unpin) · Reject · Try again — the DCR's own vocabulary, in
## the DCR's own order. Each is ENABLED-OR-DISABLED by
## RoutingWorkspace.can_transition(id, <target>), so an illegal move is a greyed
## item the user can see the shape of rather than a refusal that arrives after
## the click; and each runs the workspace's OWN gated verb, so the menu and
## minerva_pcb_workspace_* cannot drift into different powers.
##
## PIN AND UNPIN ARE ONE SLOT, not two items one of which is always dead: a
## candidate is either pinned or it is not, so the slot shows the move that is
## available from where it stands.
##
## "TRY AGAIN" DOES THE HALF THE CANVAS OWNS, and says so. Try-again is
## "retire this answer and ask the question again"; retiring is a model
## transition (RoutingWorkspace.supersede — documented there as exactly the
## targeted Try-again) and the canvas performs it, which also REOPENS the task.
## The asking is a ROUTER RUN, which is asynchronous, panel-owned and not
## something a context menu can await — the panel's Propose button and
## minerva_pcb_workspace_reroute_route are the two doorways onto it. So the item
## does its half and the status line names the other half by name. That is a
## split, stated; it is not a silent no-op.
func _add_candidate_menu_seam(candidate_id: String) -> void:
	context_menu.add_item(_candidate_menu_label(candidate_id), 0)
	context_menu.set_item_disabled(context_menu.item_count - 1, true)
	if _routing_workspace == null or not _routing_workspace.has_method("can_transition"):
		return
	var cand = _routing_workspace.get_candidate(candidate_id)
	if cand == null:
		return
	var pinned: bool = str(cand.disposition) == "pinned"

	_context_menu_separate()
	_add_candidate_verb_item("Commit", MENU_ID_CANDIDATE_COMMIT, candidate_id, "committed")
	if pinned:
		_add_candidate_verb_item("Unpin", MENU_ID_CANDIDATE_UNPIN, candidate_id, "proposed")
	else:
		_add_candidate_verb_item("Pin", MENU_ID_CANDIDATE_PIN, candidate_id, "pinned")
	_add_candidate_verb_item("Reject", MENU_ID_CANDIDATE_REJECT, candidate_id, "rejected")
	_add_candidate_verb_item("Try again", MENU_ID_CANDIDATE_TRY_AGAIN, candidate_id, "superseded")


## One verb item, disabled when the legality table says the move is not
## available from where this candidate stands. Shown-but-disabled rather than
## hidden, the same choice the locked-entity Delete item makes: a missing item
## says nothing, a greyed one says "not from here".
##
## TWO conditions, and the second is not redundant. The legality table treats an
## IDENTITY move (x -> x) as LEGAL — deliberately, so a caller re-asserting a
## state need not guard its own writes — which would leave "Commit" live on an
## already-committed candidate and "Reject" live on a rejected one. Clicking
## Commit there would lay a SECOND full set of copper for one candidate.
## RoutingWorkspace.commit refuses that too, by name, so this is the outer of two
## guards rather than the only one; but an item whose only possible effect is to
## re-assert the state it is already in is a dead item, and it greys out.
func _add_candidate_verb_item(label: String, menu_id: int, candidate_id: String, target: String) -> void:
	context_menu.add_item(label, menu_id)
	var cand = _routing_workspace.get_candidate(candidate_id)
	var identity: bool = cand != null and str(cand.disposition) == target
	if identity or not _routing_workspace.can_transition(candidate_id, target):
		context_menu.set_item_disabled(context_menu.item_count - 1, true)


## Run ONE candidate verb and report the outcome on the status line.
##
## THE TWO DOORWAYS SHARE THE MODEL, NOT THE PROSE: this is the human's doorway
## and minerva_pcb_workspace_* is the agent's; both call the same workspace verb
## and both surface the same NAMED refusal code, but only this one turns it into
## a sentence. Nothing here mutates the board directly — Commit hands the whole
## transaction to RoutingWorkspace.commit, which owns the batch, the history
## snapshot and the disposition together (INV-1).
func _run_candidate_verb(verb: String, candidate_id: String) -> void:
	if not _candidates_active() or candidate_id.is_empty():
		return
	var cand = _routing_workspace.get_candidate(candidate_id)
	if cand == null:
		trace_tool_message.emit("Route candidate %s is no longer in the workspace." % candidate_id)
		queue_redraw()
		return

	if verb == "commit":
		if data == null:
			trace_tool_message.emit("No board to commit onto.")
			return
		var res: Dictionary = _routing_workspace.commit(candidate_id, data)
		if bool(res.get("ok", false)):
			trace_tool_message.emit("Committed %s as %d trace(s) and %d via(s) — one undo step reverts the copper AND the candidate."
				% [candidate_id, (res.get("trace_ids", []) as Array).size(),
					(res.get("via_ids", []) as Array).size()])
		else:
			trace_tool_message.emit("Commit refused (%s): %s"
				% [str(res.get("error", "unknown")), str(res.get("message", ""))])
		queue_redraw()
		return

	var applied := false
	match verb:
		"pin":
			applied = _routing_workspace.pin(candidate_id)
		"unpin":
			applied = _routing_workspace.unpin(candidate_id)
		"reject":
			applied = _routing_workspace.reject(candidate_id)
		"try_again":
			applied = _routing_workspace.supersede(candidate_id)
	if not applied:
		var err: Dictionary = _routing_workspace.last_transition_error \
			if _routing_workspace.last_transition_error is Dictionary else {}
		trace_tool_message.emit("%s refused (%s): %s is %s."
			% [verb.capitalize(), str(err.get("error", "transition_refused")),
				candidate_id, str(cand.disposition)])
		queue_redraw()
		return

	match verb:
		"pin":
			trace_tool_message.emit("Pinned %s — future routing routes around it. Its check still stands (pinning changes no copper)."
				% candidate_id)
		"unpin":
			trace_tool_message.emit("Unpinned %s — it is a plain draft again." % candidate_id)
		"reject":
			trace_tool_message.emit("Rejected %s — task %s is open again."
				% [candidate_id, str(cand.task_id)])
		"try_again":
			# The half-and-half is named out loud, per the seam's own contract.
			trace_tool_message.emit("Retired %s — task %s is open again. Run Propose (or minerva_pcb_workspace_reroute_route) for a new route."
				% [candidate_id, str(cand.task_id)])
	# Clear the selection of a candidate that just left the drawn set, so the
	# canvas is not holding a lit id for a ghost it no longer paints.
	if not (str(cand.disposition) in CANDIDATE_RENDERED_DISPOSITIONS) \
			and candidate_id in selected_candidate_ids:
		selected_candidate_ids.erase(candidate_id)
		selection_changed.emit()
	queue_redraw()


## The teach line shown when a candidate becomes the selection — the "status-line
## teach text while a candidate is selected" half of C4a's UI verbs.
##
## It goes out on trace_tool_message, the canvas's EXISTING teach channel
## (PCBPanel connects it to the status writer). That channel is transient by
## construction, so the line appears on selection and on every verb outcome
## rather than persisting for as long as the ghost stays lit; the persistent
## while-selected readout is keyed by ToolMode (PCBPanel._MODE_HINTS) and a
## candidate is a selection KIND, not a mode — wiring a selection-keyed
## persistent line needs a PCBPanel-side hook, which is outside this unit's
## fence. Filed rather than faked.
func _emit_candidate_teach_line(candidate_id: String) -> void:
	if not _candidates_active():
		return
	var cand = _routing_workspace.get_candidate(candidate_id)
	if cand == null:
		return
	trace_tool_message.emit("%s — right-click for Commit · %s · Reject · Try again."
		% [_candidate_menu_label(candidate_id),
			"Unpin" if str(cand.disposition) == "pinned" else "Pin"])


## "Route candidate cand_3 — pinned, stale". Falls back to the bare id when the
## workspace can no longer resolve it (a candidate removed between the press and
## the release), which is a label, never an error.
func _candidate_menu_label(candidate_id: String) -> String:
	if _routing_workspace == null or not _routing_workspace.has_method("get_candidate"):
		return "Route candidate %s" % candidate_id
	var cand = _routing_workspace.get_candidate(candidate_id)
	if cand == null:
		return "Route candidate %s" % candidate_id
	var state := str(cand.disposition)
	var validation := str(cand.validation)
	if validation != "unchecked" and validation != "clean":
		state += ", %s" % validation
	return "Route candidate %s — %s" % [candidate_id, state]

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


## The selected via ids (item 019fbb96cf). Completes the per-kind read surface —
## a caller that means vias must never be handed trace ids, and vice versa.
func get_selected_vias() -> Array[String]:
	return selected_via_ids.duplicate()


## The selected cutout ids (campaign 2 epoch B, unit 3). Completes the per-kind
## read surface the same way get_selected_vias does.
func get_selected_cutouts() -> Array[String]:
	return selected_cutout_ids.duplicate()


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
