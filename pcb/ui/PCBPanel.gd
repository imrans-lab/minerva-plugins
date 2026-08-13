extends MinervaPluginPanel

## Ownership marker for the panel-executed tool dispatcher: fallback-resolved
## panels (AnnotationHostRegistry path) aren't broker-keyed by editor name, so
## the dispatcher reads this duck-typed property to verify the calling tool's
## plugin owns this panel (fail-safe deny otherwise). HITL-caught 2026-07-16.
var plugin_id: String = "pcb"


## THE one type guard for Dictionary reads off worker replies (bug
## 019fa0f8d575, fixed epoch GA-6). GDScript hard-errors when a value of the
## wrong TYPE lands in a statically-typed var, and `.get(key, {})` defaults
## only on an ABSENT key — a JSON null/list/string at the key crashed the
## whole render. Every `var x: Dictionary = <reply>.get(...)` in this file
## goes through here; uniformity is the point, so apply it at any new site
## rather than re-deriving an inline ternary. `fallback` covers the rare
## site whose absent-key default is another Dictionary, not {}.
static func _dict_or_empty(v, fallback: Dictionary = {}) -> Dictionary:
	return v if v is Dictionary else fallback
## PCB editor panel — Round B (full board-editing UI port).
##
## Replaces the walking-skeleton crude renderer with the real ported canvas
## (pcb_canvas.gd) + the Round-A board model (model/pcb_data.gd & siblings) +
## a board-editing toolbar and status bar. The platform annotation dock (mounted
## via get_annotation_host()) owns annotation/route-hint authoring; NONE of that
## lives in this panel anymore.
##
## Off-tree class_name gotcha: this plugin lives OUTSIDE Minerva's res:// tree, so
## plugin-local class_names are unresolvable. This script declares NO class_name
## and preloads its siblings by relative path. It extends the CORE base
## MinervaPluginPanel (in res://, resolvable). Cross-file model refs are
## duck-typed (never typed AS a plugin script).
##
## Host integrations preserved VERBATIM from the skeleton (do not regress):
##   * _init builds the PcbAnnotationHost eagerly so get_annotation_host() is
##     valid the instant the platform queries it during mount.
##   * annotations_changed → content_changed relay, gated by _restoring (W-14).
##   * AnnotationHostRegistry register/deregister by editor tab title.
##   * _on_panel_save_request writes the annotation sidecar; _on_panel_load_request
##     captures file_path in BOTH document shapes (W-15) + loads the sidecar.

const _PcbAnnotationHostScript: Script = preload("PcbAnnotationHost.gd")
const _PcbDataScript: Script = preload("model/pcb_data.gd")
const _PcbComponentScript: Script = preload("model/pcb_component.gd")
const _PcbCanvasScript: Script = preload("pcb_canvas.gd")
const _LegacyAnnotationMigration: Script = preload("legacy_annotation_migration.gd")
const _PanelLayoutScript: Script = preload("panel_layout.gd")
const _PcbRouteHintKindScript: Script = preload("kinds/pcb_route_hint_kind.gd")
const _PanelToolsScript: Script = preload("panel_tools.gd")
## The ONE canonical layer contract (canonical id <-> KiCad copper name). The
## layer selector shows KiCad names and carries canonical ids — see
## _rebuild_layer_option. Declared with `:=` (NOT `: Script =`, unlike the
## instantiated-script consts above) so the parser keeps the GDScript class type
## and can resolve its static funcs — a `Script`-typed const cannot.
const PcbLayerStack := preload("model/pcb_layer_stack.gd")
## B2 (MCP parity round) — deployed-script-vintage stamp, surfaced by
## minerva_pcb_get_layout_state's `plugin_build` field. DESIGN CHOICE, and why
## the alternatives were rejected:
##   - git SHA: NOT available at runtime (no VCS metadata ships with a
##     deployed/packaged plugin; the round brief names this explicitly).
##   - reading pcb/manifest.json's "version" off disk: adds a FileAccess round
##     trip whose path is relative to wherever this off-tree script's file
##     happens to sit (dev source dir today per data_directory, but the
##     manifest's own docs describe host_owned/packaged layouts too) — fragile
##     for a fact whose only job is "did the human deploy the latest scripts".
##   - a hand-bumped const: what every other version-shaped fact in this
##     plugin already does (pcb_prefs.gd SCHEMA_VERSION, pcb_routing_sidecar.gd
##     SCHEMA_VERSION) — cheap, zero runtime dependency, and HONEST about what
##     it is: a marker the person editing this file bumps, not an
##     automatically-derived build id. Left stale, it under-reports rather than
##     lying forward (an old value never claims to be newer than it is).
## Bump this string whenever panel_tools.gd/PCBPanel.gd/pcb_data.gd change in
## a way worth distinguishing during an HITL "which script is actually
## running" deploy check. Format is free text; "<manifest version>+<round
## tag>" is the convention started here so it still roughly tracks
## manifest.json's own "version" (0.2.0) without reading it.
const PLUGIN_BUILD := "0.2.0+b2-mcp-parity"

## T2 (S2.2) strangler-fig SHADOW phase: the routing workspace is populated
## ALONGSIDE the existing annotation proposals on every propose (dual-write,
## see panel_tools.gd _dual_write_propose). It drives nothing visible yet —
## annotation proposals remain the UI's source of truth.
const _PcbRoutingWorkspaceScript: Script = preload("model/pcb_routing_workspace.gd")
## T2a: durable, versioned, crash-safe persistence for the routing workspace,
## with a board-coherence fingerprint. Wired beside the annotation sidecar in
## _on_panel_save_request / _on_panel_load_request.
const _PcbRoutingSidecarScript: Script = preload("model/pcb_routing_sidecar.gd")
## T2.3: the strangler-fig cutover coordinator — a per-surface authority latch
## ({canvas, inspector, verbs, mcp, persistence, drc}). In T2.3 every surface
## stays annotation-authoritative (mechanism only); T3/T5 flip individual
## surfaces once their write path is workspace-backed. Built beside the workspace.
const _PcbRoutingCutoverScript: Script = preload("model/pcb_routing_cutover.gd")
## Epoch UX4 (DCR 019fe07523ca S1): the staged-entity store — the draft layer
## for board entities (zones/cutouts), sibling of the routing workspace.
const _PcbStagedEntitiesScript: Script = preload("model/pcb_staged_entities.gd")
## Plugin-scoped preferences (A7, docket 019fb92f07e2). The panel reads the store
## for seeding and writes it when the human turns the width box; the MCP surface
## (panel_tools.gd) reaches the SAME process-wide store, which is why an agent's
## write shows up in this panel's controls.
const _PcbPrefsScript: Script = preload("model/pcb_prefs.gd")
## Trace-width bounds/default — the ONE contract, shared with the model setter
## and the preference registry (pcb_trace.gd).
const _PcbTraceScript: Script = preload("model/pcb_trace.gd")

## The overlay Control name Editor.gd mounts the platform AnnotationOverlay
## under (Editor.gd:855). The route-flow cluster reaches it by find_child on
## the canvas (get_annotation_overlay_parent's own target), the same lookup
## Editor.gd performs — see _find_annotation_overlay.
const _OVERLAY_NODE_NAME := "PlatformAnnotationOverlay"

## Default board handed to a fresh (anonymous) editor. A brand-new board is
## EMPTY (finding 4): no phantom parts the user never placed. Board name / size /
## grid are kept so the canvas has a valid frame to draw and snap against.
const _DEFAULT_BOARD := {
	"version": 1,
	"name": "Untitled",
	"width_mm": 60.0,
	"height_mm": 40.0,
	"grid_mm": 2.54,
	"components": [],
}

var _annotation_host: AnnotationHost = null

## Editor tab name under which we registered the host (for symmetric teardown).
var _registered_editor_name: String = ""

## Absolute board file path (host_owned). Empty for anonymous editors.
var _file_path: String = ""
## The CANONICAL YAML source this board was loaded from — set ONLY by
## load_board_from_yaml's path adoption, never by the editor's .pcbskel
## document flow (which also writes _file_path). Promotion's implicit target
## (cold review F2): the two flows sharing one variable is exactly what made
## "Promote overwrites a .pcbskel with YAML" reachable.
var _canonical_source_path: String = ""

## Board model (pcb_data.gd) — round-tripped by save/load, edited by the canvas.
var _data = null

## T2 (S2.2) shadow routing workspace (pcb_routing_workspace.gd). In-memory
## only this round (persistence is T2a) — built eagerly beside _data/
## _annotation_host so get_routing_workspace() is valid from construction,
## matching the _annotation_host eager-build convention below.
var _routing_workspace = null

## T2.3 cutover coordinator (pcb_routing_cutover.gd), built eagerly beside the
## workspace so get_routing_cutover() is valid from construction. Every surface
## starts annotation-authoritative; _build_ui flips "canvas" to workspace at the
## canvas handoff (S5 — see the flip site there for the criterion it asserts).
## An UNMOUNTED panel therefore still reports all-annotation-authoritative.
var _routing_cutover = null

## Epoch UX4 station 2: the staged-entity store (pcb_staged_entities.gd),
## built eagerly beside the routing workspace and BOUND to _data at
## construction (bucket 9 — unlike bucket 8's lazy verb-time binding in
## panel_tools._workspace_ctx, there is no fence between this store and the
## panel, so the panel is the natural one-time wiring point).
var _staged_entities = null

## ── DCR 019fd5fd9084: panel-owned board_health enrichment state ───────────────
#
# Two small pieces of PANEL truth that the worker cannot know and that ride
# every board_health reply (panel_tools._attach_board_health):
#
# 1. RENDER PREFLIGHT (DCR item 3, warn-only): the board_revision that was live
#    the last time a minerva_pcb_get_image capture actually SUCCEEDED. -1 means
#    "never rendered this session". board_health.preflight.rendered_this_revision
#    is derived by comparing this against the CURRENT board_revision — a standing
#    nudge ("you are proposing copper over a board you have not looked at"),
#    NEVER a refusal anywhere.
var _last_rendered_board_revision: int = -1

# 2. ASSEMBLY-STATE CACHE (DCR item 2): the most recent tri-state assembly
#    verdict {assembly:{status, findings, ...}, board_revision:<int at cache
#    time>} from ANY source — a routing reply's board_health.assembly, a
#    pcb.assembly_check round-trip (load-time / placement ops). {} = no cache.
#    _workspace_commit's acknowledgment gate consults this; a revision mismatch
#    makes it advisory-only (stale), never blocking — see panel_tools.gd's
#    decision table.
var _assembly_state: Dictionary = {}


## Stamp a successful get_image capture (panel_tools._get_image calls this
## through the host→panel duck-typed path). Takes the revision rather than
## reading _data directly so the stamp names the board that was actually
## captured, even if a caller races a mutation in between.
func note_render_captured(board_revision: int) -> void:
	_last_rendered_board_revision = board_revision


## The board_revision of the last successful capture (-1 = never). Read by
## panel_tools._attach_board_health for preflight.rendered_this_revision.
func get_last_rendered_board_revision() -> int:
	return _last_rendered_board_revision


## Feed the assembly-state cache (see _assembly_state above). `assembly` is the
## tri-state object verbatim ({status:"pass"|"findings"|"indeterminate", ...});
## board_revision is the revision the verdict was computed against.
func set_assembly_state(assembly: Dictionary, board_revision: int) -> void:
	_assembly_state = {
		"assembly": assembly.duplicate(true),
		"board_revision": board_revision,
	}


## The cached assembly state ({assembly, board_revision}) or {} when absent /
## invalidated. Callers judge freshness themselves against the live
## board_revision — the cache never pretends to be current.
func get_assembly_state() -> Dictionary:
	return _assembly_state


## Drop the cache outright (placement verbs call this the moment they mutate,
## BEFORE their own refresh round-trip — a refresh that fails must leave no
## stale verdict behind claiming to describe the new placement).
func invalidate_assembly_state() -> void:
	_assembly_state = {}


## The ported board canvas (custom-drawn Control child), built on mount.
var _canvas: Control = null

## Toolbar widgets (built on mount).
var _tool_buttons: Dictionary = {}   # ToolMode int -> Button
## UX4 S7: the Proposals-area DRAFT twins (ToolMode int -> Button) — same
## modes, different destination; _sync_tool_buttons lights exactly one family.
var _draft_tool_buttons: Dictionary = {}
var _layer_option: OptionButton = null
## Net picker for the zone tools (epoch 6 unit 4). Lives in the sidebar under the
## canvas-tools group and is only visible while a zone tool is armed — it is that
## tool's arming state, not a persistent board control.
var _zone_net_option: OptionButton = null
## Layer picker for the zone tools (epoch 6 boundary fix). Same rules as the net
## picker beside it: sidebar, Draw section, visible only while a zone tool is
## armed, rebuilt on every arm and on board load. Its "View layer" entry is the
## resting state and means "follow the toolbar layer filter" — the behaviour that
## was the ONLY behaviour before this control existed.
var _zone_layer_option: OptionButton = null
## Width box for the Draw ▸ Trace tool (epoch 6 boundary fix). Same arming rules
## again; it starts at the board's design-rule width, which is what the tool used
## unconditionally before there was any UI for it.
var _trace_width_spin: SpinBox = null
## OFC-5 (docket 019ff937a981): the authoring-width box is MENU-REVEALED, not
## standing — false until the canvas menu's "Set drawing width…" asks for it,
## dropped again whenever the Trace tool disarms. The owner's third
## width-in-context-menu ruling retired the always-visible control; the
## current width stays visible in the menu item's own label.
var _draw_width_revealed := false

## ── Zone re-property rows (A5) ────────────────────────────────────────────────
## Properties-section controls that EDIT THE SELECTED ZONE, as distinct from the
## two sidebar pickers above, which ARM THE TOOL that authors a NEW one. Separate
## control instances on purpose: the arming pickers carry a placeholder that means
## "not chosen yet" / "follow the view filter" — states a committed zone cannot be
## in — and sharing one widget between "what am I about to draw" and "what is this
## thing I selected" would make every rebuild of one clobber the other.
## They populate from the SAME sources (get_net_names, and the declared copper
## stack via _declared_copper_layer_choices, which the arming layer picker now
## calls too).
var _zone_prop_rows: VBoxContainer = null
var _zone_kind_row: HBoxContainer = null
var _zone_kind_value_label: Label = null
var _zone_prop_net_row: HBoxContainer = null
var _zone_prop_net_option: OptionButton = null
var _zone_prop_layer_row: HBoxContainer = null
var _zone_prop_layer_option: OptionButton = null
## WHICH zone the rows describe (""  = none). The zone twin of
## _offset_component_id, and read by the commit handlers so a selection change
## racing a dropdown cannot re-property a zone the user is no longer looking at.
var _zone_prop_zone_id: String = ""

## The selected TRACE's property row (A7, docket 019fb92f07e2) — one editable
## field, its width. Built in the same key-label + value-control shape as the
## zone rows above and shown/hidden by the same rule (exactly one selected trace,
## or it hides: with two selected there is no single width a box could show).
## A mixed component+trace+zone selection shows every half that applies, which is
## what the A5 restructure of _update_properties made possible.
var _trace_prop_rows: VBoxContainer = null
var _trace_prop_width_spin: SpinBox = null
## WHICH trace the row edits ("" = none) — the trace twin of _zone_prop_zone_id,
## for the same reason: a selection change racing a spin-box commit must not
## re-width a trace the user is no longer looking at.
var _trace_prop_trace_id: String = ""

var _board_size_label: Label = null
var _status_label: Label = null

## Responsive layout state (UI redesign round B). Modes resolve from the
## panel's OWN width via panel_layout.gd — wide/medium/narrow with hysteresis.
var _layout_mode: String = ""
var _drawer_open := false
var _sidebar: VBoxContainer = null
## The sidebar's actual row content, one level inside a ScrollContainer (B3b,
## docket 019fbbad9dac comment 970 — RCA measured RightSidebar's unscrolled
## min-height as the dominant term in the panel's 640px/718px-armed min-height
## floor). _sidebar itself stays the named "RightSidebar" node every external
## caller (tests, get_annotation_dock_parent's ancestor check) already expects;
## only what lives INSIDE it changed. Every add_child that used to target
## _sidebar directly now targets this instead.
var _sidebar_content: VBoxContainer = null
## The ScrollContainer wrapping _sidebar_content (B3b). Kept as a member — not
## just a _build_sidebar local — so the reveal path (_on_edit_trace_width_requested
## / _reveal_trace_width_spin, F3 cold review 2026-08-01, round 2) can
## explicitly scroll a specific row into view.
##
## follow_focus is ALSO set true here, for the general "keyboard Tab lands on
## a control the scroll then keeps visible" behavior a scrollable sidebar
## should have. It is NOT what fixes the trace-width reveal, and round 1's
## claim that it was measured load-bearing there was WRONG — corrected in
## round 2: that measurement was confounded by a same-frame ordering bug (see
## _reveal_trace_width_spin) that affected follow_focus's own internal
## scroll-on-focus exactly the same way it affected the explicit
## ensure_control_visible call. Once the reveal is properly DEFERRED one
## layout pass, ensure_control_visible alone reaches 31/31px visible at both
## reference panes (500px and 400px) with follow_focus removed entirely —
## verified by mutation. follow_focus is kept for the keyboard path, which
## this round did not build a test for.
var _sidebar_scroll: ScrollContainer = null
var _dock_parent: VBoxContainer = null
## Bottom strip slot for the annotation dock (medium/narrow — HITL note:
## 3-col wants the dock along the bottom; only wide keeps it in the sidebar).
var _bottom_dock_slot: VBoxContainer = null
var _view_menu_button: MenuButton = null
var _drawer_button: Button = null
var _export_button: Button = null

## Properties section (round C): field name -> value Label.
var _prop_labels: Dictionary = {}
var _properties_body: VBoxContainer = null
var _properties_collapse_btn: Button = null
var _properties_expanded := true

## Component-group rows (A4 stage 2). BOTH start hidden and only appear for a
## grouped component, so the Properties section on a board with no groups renders
## exactly the five rows it always did.
##   _group_row    — read-out: member count, anchor ref, locked marker.
##   _offset_row   — the editable X/Y offset of ONE member from its group anchor.
##                   Hidden for the anchor itself (it IS the origin).
var _group_row: HBoxContainer = null
var _group_value_label: Label = null
var _offset_row: HBoxContainer = null
var _offset_x_edit: LineEdit = null
var _offset_y_edit: LineEdit = null
## Which component the offset fields currently edit ("" when they are hidden).
var _offset_component_id: String = ""

## Pin Info section (WC-1 pin inspector). Hidden until a pin is selected;
## hides again on clear (canvas pin_selected({})).
var _inspect_pin_button: Button = null
## Trash-can (item 019fb92f8b83, delete half): a plain action button, NOT a
## radio tool — it never joins _tool_buttons/_toggle_tool_mode's mutual
## exclusion, it just fires _canvas._delete_selection() once. Enabled only
## while the selection is non-empty (_update_delete_button, driven off the
## canvas' selection_changed signal, the same wiring _update_status/
## _update_properties already use).
var _delete_button: Button = null
var _pin_info_section: VBoxContainer = null
var _pin_info_ref_label: Label = null
var _pin_info_value_label: Label = null
var _pin_info_members_label: Label = null

## In-panel route-flow toolbar cluster (WC-3, contract §5 — a conscious
## partial reversal of Round-B "no authoring in panel"). Buttons activate
## substrate AnnotationAuthorTools directly on the shared platform overlay;
## implementations remain ordinary AnnotationAuthorTools (see
## kinds/pcb_route_hint_kind.gd SingleTraceAuthorTool). kind_key -> Button.
var _route_flow_buttons: Dictionary = {}
var _route_flow_mode_label: Label = null
## Propose action button (C5) — a non-toggle act, NOT part of
## _route_flow_buttons' mutual-exclusion radio set.
var _propose_button: Button = null
var _check_button: Button = null
## HITL-7c: the per-hint width row (hidden until "Set hint width…" reveals
## it), the spin, its label, the BOUND hint id, and the programmatic-set
## reentrancy gate (loading a value must not write it back).
var _hint_width_row: HBoxContainer = null
var _hint_width_label: Label = null
var _hint_width_spin: SpinBox = null
var _hint_width_hint_id: String = ""
var _hint_width_setting := false
## kind_key of the cluster's own currently-active tool, or "" when none.
var _active_route_flow_kind: String = ""
## The tool instance the cluster itself activated (used to tell apart "the
## overlay's active tool changed because another surface — e.g. the dock's
## own AnnotationToolbar — took over" from "we changed it ourselves").
var _active_route_flow_tool: AnnotationAuthorTool = null
## The mounted platform AnnotationOverlay's active_tool_changed connection
## (so mutual exclusion also covers OTHER surfaces driving the same overlay,
## e.g. the annotation dock's per-kind buttons — contract: "activation is
## mutually exclusive").
var _overlay_tool_signal_bound: Control = null

## The tool the shared overlay currently holds, tracked off active_tool_changed
## so _sync_universal_select can tell OUR passive arm from another surface's.
var _overlay_active_tool: Object = null

## View-flag table shared by the wide-mode CheckButtons and the medium/narrow
## View menu (single source of truth: the canvas flags themselves).
const _VIEW_FLAGS := [
	["Grid", "show_grid"],
	["Ratsnest", "show_ratsnest"],
	["Labels", "show_labels"],
	["Traces", "show_traces"],
	["Silk", "show_silk"],
	["Courtyard", "show_courtyard"],
	# Epoch UX3 station 3 (docket 019fdf90662a): show_route_candidates shipped
	# as a canvas var with no control — the ghost surface gets the same View
	# toggle every other draw flag has.
	["Ghosts", "show_route_candidates"],
	# Epoch UX3 station 4 (K11, docket 019fdf916ce6): the DRC-witness overlay.
	["DRC witnesses", "show_drc_witnesses"],
	# WYSIWYG goal 019ff4a5a75a gap G4: the solder-mask overlay. Toggling it ON
	# triggers a worker refetch (see _on_view_menu_id_pressed) — the canvas only
	# ever draws what pcb.mask_view returned, never a local re-derivation.
	["Mask openings", "show_mask"],
]
const _VIEW_MENU_EXPORT_ID := 100
## Base id for the View menu's dynamic per-layer visibility section (epoch
## GA-1): the separator takes the base itself, layer items take base+1+stack
## index. Far above _VIEW_FLAGS' indices and _VIEW_MENU_EXPORT_ID so the three
## id families can never collide.
const _VIEW_MENU_LAYER_ID_BASE := 500

## True while restoring persisted state (board load OR annotation sidecar load).
## Suppresses the content_changed dirty relay so restoring never marks the tab
## dirty (W-14; carry-in 3b extends the gate to cover board load).
var _restoring := false

## Summary of the last one-shot legacy annotation migration ({migrated, warnings}).
## Populated by _run_legacy_migration; surfaced on the status bar and exposed for
## tests/telemetry via get_last_migration_summary().
var _last_migration: Dictionary = {"migrated": 0, "warnings": []}

## Count of legacy proposal annotations dropped on the most recent sidecar load
## (S5, C4b, DCR 019f7095c395 — see _drop_legacy_proposal_annotations). 0 when
## no drop has run (never loaded a sidecar, or nothing to drop). Exposed for
## tests/telemetry via get_last_legacy_proposals_dropped().
var _last_legacy_proposals_dropped := 0


func _init() -> void:
	# Build the host eagerly so get_annotation_host() is valid the instant the
	# platform queries it during mount (before _on_panel_loaded fires).
	_annotation_host = _PcbAnnotationHostScript.new()
	# Annotation mutations flip the tab's unsaved glyph via content_changed
	# (gap register W-14). Gated by _restoring: load_sidecar emits the same
	# signal and restoring saved state must not mark the tab dirty.
	# UX2 station 8 (docket 019fde57027c): every mutation ALSO schedules the
	# debounced sidecar auto-write — annotations are durable-by-default, the
	# way the docket treats writes; the BOARD file itself stays owner-saved.
	_annotation_host.annotations_changed.connect(func() -> void:
		if not _restoring:
			content_changed.emit()
			_schedule_sidecar_autosave())

	# T2 (S2.2): the shadow routing workspace, built eagerly alongside the
	# annotation host so get_routing_workspace() is valid immediately.
	_routing_workspace = _PcbRoutingWorkspaceScript.new()
	# Epoch UX3 station 3: the steady-state status readout now carries the
	# ghost tally (_ghost_status_summary), so every candidate-set or verdict
	# move refreshes it — the same lambda-relay idiom data_changed uses below.
	# _update_status is cheap and null-guards its own members, so wiring it
	# eagerly here (before the status label exists) is safe.
	_routing_workspace.candidate_added.connect(func(_id: String) -> void: _update_status())
	_routing_workspace.candidate_changed.connect(func(_id: String) -> void: _update_status())
	_routing_workspace.candidate_removed.connect(func(_id: String) -> void: _update_status())
	_routing_workspace.validation_changed.connect(func(_id: String) -> void: _update_status())

	# T2.3: the cutover coordinator, built eagerly beside the workspace. Every
	# surface defaults annotation-authoritative — nothing is cut over in T2.3.
	_routing_cutover = _PcbRoutingCutoverScript.new()

	# Epoch UX4 station 2: the staged store, eager like the workspace so
	# get_staged_store() is valid from construction. Bound to _data below
	# (after _data exists) — the bind is what turns on history bucket 9.
	_staged_entities = _PcbStagedEntitiesScript.new()

	# Build the board model and seed the default board WITHOUT dirtying the tab
	# (from_board_dict emits data_changed; gate it).
	_data = _PcbDataScript.new()
	_restoring = true
	_data.from_board_dict(_DEFAULT_BOARD.duplicate(true))
	_restoring = false
	# Carry-in 3b: relay model data_changed → content_changed (dirty glyph),
	# gated by _restoring so board load / seeding never dirties the tab.
	_data.data_changed.connect(func() -> void:
		if not _restoring:
			content_changed.emit()
			_schedule_mask_view_refresh())
	# Epoch UX4 station 2: bucket-9 binding — undo/redo now snapshots and
	# restores staged dispositions alongside the board (pcb_data.gd
	# bind_staged_store). Store mutations dirty the tab like every other
	# observable edit, same _restoring gate.
	_data.bind_staged_store(_staged_entities)
	# UX4 station 6 (DCR S9): store mutations ALSO join the sidecar-autosave
	# debounce — an MCP-staged entity is durable without Ctrl+S, the same
	# class HITL-4 closed for annotations. Gated by _restoring like the
	# annotation relay above (a sidecar LOAD emits changed too — F7).
	_staged_entities.changed.connect(func() -> void:
		if not _restoring:
			content_changed.emit()
			_schedule_sidecar_autosave())


func get_annotation_host() -> RefCounted:
	return _annotation_host


## Where the platform annotation overlay must mount (Editor.gd duck-types this).
## The host's view transform maps board-mm to CANVAS-local pixels, so the
## overlay has to share the canvas origin — parenting it to the whole panel
## would offset every pointer hit and rendered annotation by the toolbar row
## (see the warning at the canvas mount in _build_ui). Falls back to the panel
## when the canvas isn't built yet.
func get_annotation_overlay_parent() -> Control:
	if _canvas != null and is_instance_valid(_canvas):
		return _canvas
	return self


## The board model (pcb_data.gd) this panel edits. Exposed for MCP/tests.
func get_data():
	return _data


## T2 (S2.2): the shadow routing workspace (pcb_routing_workspace.gd), dual-
## written on every propose alongside the annotation proposals. Exposed for
## MCP/tests; not yet the UI's source of truth for anything (that lands in
## later tasks — see the file-level docstring).
func get_routing_workspace():
	return _routing_workspace


## Epoch UX4 station 2: the staged-entity store (pcb_staged_entities.gd),
## bucket-9-bound to _data at construction. Exposed for the composer, the
## canvas ghost pass, the review verbs, and MCP/tests (later stations).
func get_staged_store():
	return _staged_entities


# ── Epoch UX4 station 5: the staged review transactions (DCR S5, A1/A5) ───────
# The PANEL owns these — the canvas only announces (staged_verb_requested),
# the store only records, and the board only takes journalled writes. Accept's
# order is load-bearing (station-2 cold review F1): attach the pre-accept
# disposition layer, WRITE the board, STAMP accepted, THEN snapshot — so the
# accept history entry records "accepted" and redo restores it instead of
# reviving the ghost over the landed entity. Reject pairs with its own history
# entry for the same reason (F3: a bare stamp is silently reverted by undo of
# any unrelated edit).


## The ONE stage doorway (A8's one-branch rule): every authoring surface that
## lands a DRAFT (canvas commit sites, MCP propose twins — stations 7/8) calls
## THIS after build_*_payload, so the base-revision stamp and the store write
## cannot drift between doorways. Returns {ok, staged_id, entity_id} or
## {ok:false, error:<store refusal name>}.
func stage_built_payload(kind: String, payload: Dictionary, author: String = "human",
		note: String = "") -> Dictionary:
	if _staged_entities == null or _data == null:
		return {"ok": false, "error": "staged_store_unavailable"}
	var sid := str(_staged_entities.stage(kind, payload, author, int(_data.board_revision), note))
	if sid.is_empty():
		return {"ok": false, "error": str(_staged_entities.last_error.get("error", "stage_refused"))}
	return {"ok": true, "staged_id": sid, "entity_id": str(payload.get("id", ""))}


## Resolve a CANONICAL entity id to its LIVE store entry. {ok, sid, entry} or
## the named refusal ({ok:false, error:"staged_entry_not_found"} — terminal
## entries resolve to nothing, same rule the pick/point surfaces keep).
func _resolve_live_staged(entity_id: String) -> Dictionary:
	if _staged_entities == null or _data == null:
		return {"ok": false, "error": "staged_store_unavailable"}
	var sid := str(_staged_entities.staged_id_for_entity(entity_id))
	if sid.is_empty():
		return {"ok": false, "error": "staged_entry_not_found", "entity_id": entity_id}
	return {"ok": true, "sid": sid, "entry": _staged_entities.get_entry(sid)}


## The NAMED refusal this payload would get from add_*_payload against the
## CURRENT board ("" = it would land). Mirrors add_*_payload's own three gates
## (author re-validation, minted-id format, board-uniqueness) so the single
## accept can surface A5's named refusal and the batch can be all-or-nothing
## WITHOUT a dry-run write path on the model.
func _staged_payload_refusal(kind: String, payload: Dictionary) -> String:
	var pid := str(payload.get("id", ""))
	match kind:
		"zone":
			var outline: Array = payload.get("outline", []) if payload.get("outline", []) is Array else []
			var err: String = _data.zone_author_error(str(payload.get("net", "")),
				str(payload.get("layer", "")), outline.size(), str(payload.get("kind", "copper_pour")))
			if not err.is_empty():
				return err
			if not pid.begins_with("zone:"):
				return "payload id '%s' is not a minted zone id" % pid
			if not (_data.get_zone(pid) as Dictionary).is_empty():
				return "zone id '%s' is already on the board" % pid
		"cutout":
			var c_outline: Array = payload.get("outline", []) if payload.get("outline", []) is Array else []
			var c_err: String = _data.cutout_author_error(c_outline.size())
			if not c_err.is_empty():
				return c_err
			if not pid.begins_with("cutout:"):
				return "payload id '%s' is not a minted cutout id" % pid
			if not (_data.get_cutout(pid) as Dictionary).is_empty():
				return "cutout id '%s' is already on the board" % pid
		"placement":
			# SPIKE 019ff8615fbe: no board-duplicate half — accept applies a
			# move rather than adding an entity, so there is nothing on the
			# board to collide with; replay is refused by the store's terminal
			# disposition.
			var p_err: String = _data.placement_author_error(str(payload.get("component_id", "")))
			if not p_err.is_empty():
				return p_err
			# Codex 1182 F1: the pose validator runs at PREFLIGHT too — the
			# same check add_placement_payload gates on, so a torn sidecar
			# draft refuses here, where the batch is still all-or-nothing.
			var p_pose_err: String = _data.placement_pose_error(payload)
			if not p_pose_err.is_empty():
				return p_pose_err
			if not pid.begins_with("placement:"):
				return "payload id '%s' is not a minted placement id" % pid
		_:
			return "unknown staged kind '%s'" % kind
	return ""


## The one accept write per kind — the add_*_payload dispatch both accept
## paths share (single + batch), so a new staged kind lands in ONE place.
func _apply_staged_payload(kind: String, payload: Dictionary) -> Dictionary:
	match kind:
		"zone":
			return _data.add_zone_payload(payload)
		"cutout":
			return _data.add_cutout_payload(payload)
		"placement":
			return _data.add_placement_payload(payload)
	return {}


## ACCEPT one staged draft: replay the direct add verb with the STORED payload
## (id preserved — A1 byte-identical including identity), re-validated against
## the CURRENT board (A5 — drift surfaces as the direct verb's own refusal,
## returned here by name). One history entry; undo returns the entity to a
## ghost.
func accept_staged(entity_id: String) -> Dictionary:
	var pre := _resolve_live_staged(entity_id)
	if not bool(pre.get("ok", false)):
		_show_transient_status("Accept refused: %s" % str(pre.get("error", "")))
		return pre
	var entry: Dictionary = _dict_or_empty(pre.get("entry"))
	var kind := str(entry.get("kind", ""))
	var payload: Dictionary = _dict_or_empty(entry.get("payload"))
	var refusal := _staged_payload_refusal(kind, payload)
	if not refusal.is_empty():
		_show_transient_status("Accept refused: %s" % refusal)
		return {"ok": false, "error": "accept_refused", "entity_id": entity_id, "note": refusal}
	# P1 C2 (the parity principle): a placement accept is a MOVE, and the
	# direct-move verb already reports what a move does to copper — the same
	# pre-pin snapshot + dangling sweep runs here so BOTH accept doorways
	# (context menu and MCP) tell the same truth.
	var pre_pins: Dictionary = {}
	if kind == "placement":
		pre_pins = _PanelToolsScript._pre_transform_pins(_data,
			str(payload.get("component_id", "")))
	_data.attach_staged_snapshot()
	var landed: Dictionary = _apply_staged_payload(kind, payload)
	if landed.is_empty():
		# Unreachable after the pre-check above mirrors the add gates; kept as
		# an honest backstop rather than a stamp over a write that never was.
		return {"ok": false, "error": "accept_refused", "entity_id": entity_id,
			"note": "the board write was refused — see the model warning"}
	_staged_entities.stamp(str(pre.get("sid", "")), "accepted", "accept")
	_data.save_to_history("Accept staged %s" % kind)
	var out := {"ok": true, "entity_id": entity_id, "kind": kind}
	if kind == "placement":
		var to: Dictionary = _dict_or_empty(payload.get("to"))
		var moved_msg := "Accepted move: %s is now at (%.2f, %.2f)." % [
			str(payload.get("component_id", "")),
			float(to.get("x_mm", 0.0)), float(to.get("y_mm", 0.0))]
		var warnings: Array = _PanelToolsScript._dangling_copper_warnings(_data, pre_pins)
		if not warnings.is_empty():
			out["dangling_copper"] = warnings
			if _canvas != null and _canvas.has_method("set_disconnect_markers"):
				_canvas.set_disconnect_markers(warnings)
			var nets: Array[String] = []
			for w in warnings:
				var n := str((w as Dictionary).get("net", ""))
				if not (n in nets):
					nets.append(n)
			moved_msg += " %d net%s disconnected (%s) — copper does not follow parts; delete or reroute." % [
				nets.size(), "" if nets.size() == 1 else "s", ", ".join(nets)]
		_show_transient_status(moved_msg)
		return out
	_show_transient_status("Accepted staged %s %s — it is on the board now." % [kind, entity_id])
	return out


## REJECT one staged draft: terminal stamp PAIRED with its own history entry
## (the store's stamp() mandate) — undo of the reject revives the ghost; undo
## of anything else leaves the reject standing.
func reject_staged(entity_id: String) -> Dictionary:
	var pre := _resolve_live_staged(entity_id)
	if not bool(pre.get("ok", false)):
		_show_transient_status("Reject refused: %s" % str(pre.get("error", "")))
		return pre
	var kind := str((pre.get("entry", {}) as Dictionary).get("kind", "draft"))
	_data.attach_staged_snapshot()
	if not _staged_entities.reject(str(pre.get("sid", ""))):
		return {"ok": false, "error": str(_staged_entities.last_error.get("error", "reject_refused")),
			"entity_id": entity_id}
	_data.save_to_history("Reject staged %s" % kind)
	_show_transient_status("Rejected staged %s %s — the draft is discarded (undo brings it back)." % [kind, entity_id])
	return {"ok": true, "entity_id": entity_id, "kind": kind}


## FREEZE a staged placement's pose (epoch GA, K7 019fa6ed3f60). The doorway
## the store's freeze() was built for, and the transaction it REQUIRES: the
## store writes a disposition, and a disposition written without a paired
## history entry is a latent clobber — every later board snapshot carries the
## full disposition map, so undoing an unrelated edit would restore the
## pre-freeze value and silently THAW a settled pose. Mirrors reject_staged's
## attach → verb → save_to_history shape exactly, for that reason.
##
## Freezing settles the pose so a route candidate proposed against it cannot be
## invalidated by a later drag; the ghost stays live, renders, composes into
## draft DRC, and may still be accepted or rejected without unfreezing.
func freeze_staged(entity_id: String) -> Dictionary:
	return _set_staged_frozen(entity_id, true)


## UNFREEZE back to an editable pose. Same transaction obligation.
func unfreeze_staged(entity_id: String) -> Dictionary:
	return _set_staged_frozen(entity_id, false)


## The shared freeze/unfreeze transaction. One implementation so the two verbs
## cannot drift, and so the history pairing is written once rather than twice.
## An unpaired attach is harmless (it stamps the current entry with the
## disposition map as it actually is), which is why the attach may precede the
## store call exactly as it does in reject_staged.
func _set_staged_frozen(entity_id: String, want_frozen: bool) -> Dictionary:
	var verb := "freeze" if want_frozen else "unfreeze"
	var pre := _resolve_live_staged(entity_id)
	if not bool(pre.get("ok", false)):
		_show_transient_status("%s refused: %s" % [verb.capitalize(), str(pre.get("error", ""))])
		return pre
	var kind := str((pre.get("entry", {}) as Dictionary).get("kind", "draft"))
	var sid := str(pre.get("sid", ""))
	_data.attach_staged_snapshot()
	var landed: bool = _staged_entities.freeze(sid) if want_frozen else _staged_entities.unfreeze(sid)
	if not landed:
		return {"ok": false,
			"error": str(_staged_entities.last_error.get("error", "%s_refused" % verb)),
			"entity_id": entity_id}
	_data.save_to_history("%s staged %s" % [verb.capitalize(), kind])
	if want_frozen:
		_show_transient_status("Froze staged %s %s — its pose is settled; routes proposed against it stay valid." % [kind, entity_id])
	else:
		_show_transient_status("Unfroze staged %s %s — its pose is editable again." % [kind, entity_id])
	return {"ok": true, "entity_id": entity_id, "kind": kind, "frozen": want_frozen}


## BATCH accept — the batch-commit pattern (DCR S5): ALL-OR-NOTHING, refused
## by name per entity, and ONE history step for the lot, so a single undo
## returns every accepted entity to a ghost together.
func accept_staged_batch(entity_ids: Array) -> Dictionary:
	if _staged_entities == null or _data == null:
		return {"ok": false, "error": "staged_store_unavailable"}
	var resolved: Array = []
	var refusals: Array = []
	var seen: Dictionary = {}
	for eid in entity_ids:
		# Codex UX4 F3: a repeated member refuses at PREFLIGHT (the routing
		# batch's own rule, mirrored) — without this, [id, id] resolved twice,
		# landed once, refused once mid-write, and reported both as accepted.
		if seen.has(str(eid)):
			refusals.append({"entity_id": str(eid), "error": "duplicate_batch_member"})
			continue
		seen[str(eid)] = true
		var pre := _resolve_live_staged(str(eid))
		if not bool(pre.get("ok", false)):
			refusals.append({"entity_id": str(eid), "error": str(pre.get("error", ""))})
			continue
		var entry: Dictionary = _dict_or_empty(pre.get("entry"))
		var refusal := _staged_payload_refusal(str(entry.get("kind", "")), entry.get("payload", {}))
		if not refusal.is_empty():
			refusals.append({"entity_id": str(eid), "error": refusal})
			continue
		resolved.append({"sid": str(pre.get("sid", "")), "entry": entry, "entity_id": str(eid)})
	if not refusals.is_empty():
		return {"ok": false, "error": "batch_refused", "refusals": refusals,
			"note": "all-or-nothing: no draft was accepted"}
	if resolved.is_empty():
		return {"ok": false, "error": "empty_batch"}
	# P1 C2: one merged pre-pin snapshot across every placement member, so a
	# batch of moves reports its stranded copper exactly like a single one.
	var batch_pre_pins: Dictionary = {}
	for r in resolved:
		var r_entry: Dictionary = _dict_or_empty(r.get("entry"))
		if str(r_entry.get("kind", "")) == "placement":
			batch_pre_pins.merge(_PanelToolsScript._pre_transform_pins(_data,
				str((r_entry.get("payload", {}) as Dictionary).get("component_id", ""))))
	_data.attach_staged_snapshot()
	# Codex F3, second half: the reply counts LANDINGS, never intent — the
	# preflight makes a mid-write refusal unreachable, but if one ever fires
	# the count must not lie about it.
	var landed_count := 0
	var placements_landed := 0
	var midwrite_refusals: Array = []
	for r in resolved:
		var entry: Dictionary = _dict_or_empty(r.get("entry"))
		var kind := str(entry.get("kind", ""))
		var landed: Dictionary = _apply_staged_payload(kind, _dict_or_empty(entry.get("payload")))
		if landed.is_empty():
			push_warning("[PCBPanel] batch accept: unexpected refusal on %s" % str(r.get("entity_id", "")))
			midwrite_refusals.append(str(r.get("entity_id", "")))
			continue
		_staged_entities.stamp(str(r.get("sid", "")), "accepted", "accept")
		landed_count += 1
		if kind == "placement":
			placements_landed += 1
	_data.save_to_history("Accept %d staged drafts" % landed_count)
	# Codex 1182 F1, second half: if the "unreachable" mid-write refusal ever
	# fires, the reply must not dress a torn transaction as success — the
	# landings are journalled (one undo returns them), the reply says exactly
	# which members did not land, and ok is FALSE.
	if not midwrite_refusals.is_empty():
		_show_transient_status("Batch accept TORE: %d landed, %d refused mid-write — undo returns the landed ones." % [
			landed_count, midwrite_refusals.size()])
		return {"ok": false, "error": "batch_partial_failure",
			"accepted": landed_count, "refused_mid_write": midwrite_refusals,
			"placements": placements_landed,
			"note": "preflight admitted a member the write refused — the landed members are journalled as one step; undo reverts them"}
	var batch_out := {"ok": true, "accepted": landed_count, "placements": placements_landed}
	var batch_status := "Accepted %d staged drafts." % landed_count
	if not batch_pre_pins.is_empty():
		var batch_warnings: Array = _PanelToolsScript._dangling_copper_warnings(_data, batch_pre_pins)
		if not batch_warnings.is_empty():
			batch_out["dangling_copper"] = batch_warnings
			if _canvas != null and _canvas.has_method("set_disconnect_markers"):
				_canvas.set_disconnect_markers(batch_warnings)
			batch_status += " %d trace endpoint%s disconnected — see the markers." % [
				batch_warnings.size(), "" if batch_warnings.size() == 1 else "s"]
	_show_transient_status(batch_status)
	return batch_out


## The canvas menu's announcement lands here (wired in _build_ui).
func _on_staged_verb_requested(verb: String, entity_id: String) -> void:
	match verb:
		"accept":
			accept_staged(entity_id)
		"reject":
			reject_staged(entity_id)
		_:
			_show_transient_status("Unknown staged verb '%s'." % verb)


## T2.3: the cutover coordinator (pcb_routing_cutover.gd). Exposed for MCP/tests
## and for the surfaces that consult it. Post-S5 a MOUNTED panel reports the
## "canvas" surface workspace-authoritative (flipped in _build_ui) and every
## other surface annotation-authoritative; an unmounted one reports all
## annotation. Also the rollback door: get_routing_cutover().rollback("canvas").
func get_routing_cutover():
	return _routing_cutover


## Panel-executed MCP tool entry point (DCR 019f6c3d0e3d contract §2
## plugin-side convention; wave 1 C2 round docket 019f6c45f09e, wave 2 + core
## deletion C3 round docket 019f6c4604ba). PluginToolRegistry has already
## resolved args.editor_name -> this panel and verified ownership before
## calling here; panel_tools.gd owns EVERY tool body (moved verbatim from
## Minerva core's now-deleted MCPPcbPanelTools.gd — waves 1 and 2). An
## unrecognised tool_name returns {} so the dispatcher maps it to the
## structured tool_unhandled error.
##
## Always awaited: minerva_pcb_apply_route_hints awaits the router worker
## bridge, which makes panel_tools.gd's handle() a coroutine as a whole
## (Godot 4.6 landmine — once any branch awaits, the whole function is a
## coroutine). Awaiting unconditionally here is correct for every tool, sync
## or async: awaiting an already-resolved coroutine call is a no-op wait. The
## PluginToolRegistry dispatcher already awaits THIS call end-to-end (C1
## scenario E proved it).
func handle_tool(tool_name: String, args: Dictionary) -> Dictionary:
	return await _PanelToolsScript.handle(_annotation_host, tool_name, args)


# ── Mount / unmount ───────────────────────────────────────────────────────────

func _on_panel_loaded(ctx: Dictionary) -> void:
	_build_ui()

	# Register the host under the editor tab title so MCP annotation tools
	# (minerva_annotations_query / _render_overlay) can reach it by editor_name.
	var ed: Variant = ctx.get("editor", null)
	if ed != null and "tab_title" in ed and _annotation_host != null:
		var ed_name: String = str(ed.tab_title)
		if not ed_name.is_empty():
			AnnotationHostRegistry.register(ed_name, _annotation_host)
			_registered_editor_name = ed_name

	# Capture the file path (for sidecar resolution).
	_file_path = str(ctx.get("file_path", ""))
	if not _file_path.is_empty() and _annotation_host != null:
		_annotation_host.set_document_path(_file_path)

	# Reflect whatever board is currently loaded.
	_refresh_board_ui()
	_zoom_to_fit_deferred()


func _on_panel_unload() -> void:
	# Unbind the canvas so the host drops its signal connections before the
	# canvas is freed (symmetric with set_canvas in _build_ui).
	if _annotation_host != null and _annotation_host.has_method("set_canvas"):
		_annotation_host.set_canvas(null)
	# Release the passively-armed universal Select before the overlay goes with
	# the panel (B1u3) — symmetric with the arming in _sync_universal_select.
	if _annotation_host != null and _annotation_host.has_method("arm_universal_select"):
		_annotation_host.arm_universal_select(null, false)
	if _registered_editor_name != "":
		AnnotationHostRegistry.deregister(_registered_editor_name)
		_registered_editor_name = ""


# ── UI construction ───────────────────────────────────────────────────────────

## Build the toolbar and one framed workspace. The host gives panels the full
## rect; the workspace frame owns the canvas/sidebar, bottom dock, and status so
## those rows read as one surface instead of floating below the canvas border.
func _build_ui() -> void:
	var main_vbox := VBoxContainer.new()
	main_vbox.name = "MainVBox"
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_vbox)

	# Toolbar inside a horizontal scroll for overflow.
	var toolbar_scroll := ScrollContainer.new()
	toolbar_scroll.name = "ToolbarScroll"
	toolbar_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	toolbar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	toolbar_scroll.custom_minimum_size.y = 38
	main_vbox.add_child(toolbar_scroll)
	toolbar_scroll.add_child(_build_toolbar())

	# One visual boundary owns the complete workspace below the toolbar. The
	# previous CanvasContainer frame ended above BottomDockSlot + StatusBar,
	# which made those rows look as though they overflowed the editor even though
	# every control was correctly inside the panel's allocated rect.
	var workspace_frame := PanelContainer.new()
	workspace_frame.name = "WorkspaceFrame"
	workspace_frame.clip_contents = true
	workspace_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(workspace_frame)

	var workspace_vbox := VBoxContainer.new()
	workspace_vbox.name = "WorkspaceVBox"
	workspace_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace_frame.add_child(workspace_vbox)

	# Content row: canvas (majority share) + right sidebar (legacy layout clone).
	var content_hbox := HBoxContainer.new()
	content_hbox.name = "ContentHBox"
	content_hbox.clip_contents = true
	content_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace_vbox.add_child(content_hbox)

	# Canvas fills the middle. Its container clips but draws no second panel
	# frame; WorkspaceFrame above is the single visual boundary.
	var canvas_container := MarginContainer.new()
	canvas_container.name = "CanvasContainer"
	canvas_container.clip_contents = true
	canvas_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_hbox.add_child(canvas_container)

	_canvas = _PcbCanvasScript.new()
	_canvas.name = "PCBCanvas"
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# If an on-screen AnnotationOverlay is ever mounted here, it MUST be a child
	# of _canvas (same origin) — NOT canvas_container: the host's view transform
	# maps board-mm to canvas-LOCAL pixels and every marker must share that exact
	# local coordinate space.
	canvas_container.add_child(_canvas)
	_canvas.set_data(_data)

	# Bind the annotation host to the live canvas so route-hint markers track
	# board coordinates through zoom/pan and describe_point can read the board
	# model (gap register W-9). Duck-typed: a host without set_canvas simply
	# stays on identity transforms.
	if _annotation_host != null and _annotation_host.has_method("set_canvas"):
		_annotation_host.set_canvas(_canvas)
	if _annotation_host != null and _annotation_host.has_method("set_panel"):
		_annotation_host.set_panel(self)
	# WC-1 pin inspector: the canvas hit-tests through the host's pad_at/pin_info
	# (single source of truth — see PcbAnnotationHost.gd), never duplicating the
	# lookup locally.
	if _annotation_host != null and _canvas.has_method("set_pin_inspector_host"):
		_canvas.set_pin_inspector_host(_annotation_host)
	# UNIVERSAL SELECT (B1u3): the canvas owns the click for BOTH halves of the
	# selection and asks the host for the annotation half. Same duck-typed
	# handshake as the two bindings above.
	if _annotation_host != null and _canvas.has_method("set_annotation_router"):
		_canvas.set_annotation_router(_annotation_host)
	# S3 route-candidate rendering (DCR 019f7095c395): hand the canvas the routing
	# workspace it renders ghosts from, together with the cutover coordinator that
	# GATES the whole surface. Symmetric with the two bindings above and duck-typed
	# the same way. Both objects are built at construction (see _routing_workspace
	# / _routing_cutover), so neither can be null here.
	#
	# The canvas connects itself to the workspace's redraw-worthy signals inside
	# this call — it is the side that knows which workspace instance is current, so
	# it is the side that can disconnect a previous one.
	# UX4 station 4: the staged store handoff, symmetric with the workspace
	# binding below — the canvas draws the area ghosts from it and rides its
	# `changed` signal for redraw + selection pruning.
	if _canvas.has_method("set_staged_store"):
		# The stage doorway rides the same handoff (UX4 S7): a DRAFT-armed
		# commit calls back through stage_built_payload — the ONE stage entry
		# point — rather than writing the store from the canvas.
		_canvas.set_staged_store(_staged_entities, Callable(self, "stage_built_payload"))
	# UX4 station 5: the menu's Accept/Reject announcements → the panel-owned
	# transactions (the canvas never touches store or board itself).
	if _canvas.has_signal("staged_verb_requested"):
		_canvas.staged_verb_requested.connect(_on_staged_verb_requested)
	if _canvas.has_method("set_routing_workspace"):
		_canvas.set_routing_workspace(_routing_workspace, _routing_cutover)
		# ── THE CUTOVER FLIP (S5 / C4a-C4b, DCR 019f7095c395) ──────────────────
		# THE PRODUCTION FLIP SITE. Until this line existed, set_workspace_
		# authoritative had no production caller at all: the canvas surface stayed
		# annotation-authoritative forever, _candidates_active() was permanently
		# false, and — since C4b retired the proposal-annotation write-back — a
		# Propose produced NO visible geometry anywhere. The flag is the whole
		# gate, so the flip is the whole cutover.
		#
		# THE COORDINATOR'S OWN CRITERION, honored literally: "flips a surface to
		# workspace ONLY when the caller ASSERTS that this surface's WRITE path is
		# already workspace-backed" (pcb_routing_cutover.gd, "never flip on a
		# hope"). That assertion is TRUE here, and it is true UNCONDITIONALLY at
		# HEAD rather than being a hope about a future round:
		#   * propose WRITES to the workspace and only the workspace —
		#     panel_tools._propose_into_workspace / _workspace_propose both land
		#     candidates via RoutingWorkspace.ingest_record and write NO proposal
		#     annotation (S5; see their shared "no proposal annotation was
		#     written" reply note).
		#   * the canvas's own verbs write there too — _run_candidate_verb calls
		#     RoutingWorkspace.commit/pin/unpin/reject/supersede, and commit owns
		#     the board batch + history snapshot + disposition together (INV-1).
		#   * NOTHING writes candidate state to the annotation store any more;
		#     C4b's _drop_legacy_proposal_annotations removes the last remnant on
		#     load. So there is no store left for the read to diverge from — the
		#     precise divergence the "never flip on a hope" rule guards against.
		#
		# WHY HERE, AND WHY ONLY "canvas". Here, because the flip must be paired
		# with the handoff above: the canvas surface is only meaningfully
		# workspace-authoritative once the canvas actually HAS the workspace, and
		# both facts then arrive in one place that a rollback can undo in one
		# place. Only "canvas", because it is the ONLY surface any production code
		# reads (pcb_canvas._candidates_active is the sole is_workspace_
		# authoritative caller, and it asks for "canvas"). Flipping "verbs" /
		# "mcp" / "persistence" as well would assert migrations no reader consults
		# and no test pins — a hope by another name. Each stays a latch to be
		# flipped by whoever lands its reader.
		#
		# ROLLBACK is still one line and still safe: get_routing_cutover().
		# rollback("canvas") restores the pre-cutover canvas exactly, because the
		# gate is read live on every draw/pick/verb.
		if _routing_cutover != null:
			_routing_cutover.set_workspace_authoritative("canvas", true)
	# The platform mounts its AnnotationOverlay as a CHILD of this canvas, some
	# frames after the panel is built (Editor.gd). Arming the universal Select
	# needs that overlay to exist, so we watch for it arriving rather than
	# guessing a frame — and _sync_universal_select is idempotent, so a canvas
	# that gains other children costs one cheap re-check each.
	if not _canvas.child_entered_tree.is_connected(_on_canvas_child_entered):
		_canvas.child_entered_tree.connect(_on_canvas_child_entered)

	# Canvas → panel signal wiring.
	_canvas.tool_mode_changed.connect(_on_tool_mode_changed)
	_canvas.component_selected.connect(func(_id: String) -> void:
		_update_status(); _update_properties())
	_canvas.selection_changed.connect(func() -> void:
		_update_status(); _update_properties(); _update_delete_button())
	_canvas.component_lock_changed.connect(_on_component_lock_changed)
	_canvas.zoom_changed.connect(func(_z: float) -> void: _update_status())
	_canvas.pin_selected.connect(_on_pin_selected)
	_canvas.zone_tool_message.connect(_show_transient_status)
	_canvas.trace_tool_message.connect(_show_transient_status)
	# Epoch UX3 station 5: the canvas's steered-retry doorway — the router leg
	# is async and panel-owned, so the menu/gesture emits and this completes.
	_canvas.candidate_retry_requested.connect(_on_candidate_retry_requested)
	# Epoch UX3 station 7: the canvas's commit doorway — single AND batch ride
	# the gated tool; this panel owns the placement-acknowledge dialog.
	_canvas.candidate_commit_requested.connect(_on_candidate_commit_requested)
	# HITL-7c: "Set hint width…" reveals the per-hint width row.
	_canvas.edit_hint_width_requested.connect(_on_edit_hint_width_requested)
	_canvas.cutout_tool_message.connect(_show_transient_status)
	_canvas.bus_tool_message.connect(_show_transient_status)
	_canvas.edit_trace_width_requested.connect(_on_edit_trace_width_requested)
	_canvas.edit_draw_width_requested.connect(_on_edit_draw_width_requested)

	# Right sidebar (legacy layout clone): tool buttons + the platform
	# annotation dock (mounted by Minerva via get_annotation_dock_parent).
	content_hbox.add_child(_build_sidebar())

	# Bottom dock strip: the annotation dock lives HERE in medium/narrow
	# (full panel width under the canvas — HITL note 2026-07-13) and moves
	# into the sidebar slot only in wide mode. Whichever slot the dock pane
	# lands in, _sync_dock_pane_mode re-asserts the pane's internal
	# RIGHT/BOTTOM arrangement (deferred: the platform mount sets RIGHT after
	# parenting, so a same-frame correction would be overwritten).
	_bottom_dock_slot = VBoxContainer.new()
	_bottom_dock_slot.name = "BottomDockSlot"
	_bottom_dock_slot.size_flags_vertical = Control.SIZE_SHRINK_END
	workspace_vbox.add_child(_bottom_dock_slot)
	_bottom_dock_slot.child_entered_tree.connect(func(_n: Node) -> void:
		call_deferred("_sync_dock_pane_mode"))
	if _dock_parent != null:
		_dock_parent.child_entered_tree.connect(func(_n: Node) -> void:
			call_deferred("_sync_dock_pane_mode"))

	# Model → toolbar (board size label) refresh.
	_data.structure_changed.connect(_update_board_size_label)
	# Model → copper-layer pickers (epoch GA-1): the layer STACK is now a
	# mutable board property (set_board_layers, undoable), and undo/redo also
	# emit structure_changed — so every stack-mutation path re-derives the
	# toolbar filter and both zone pickers from the declared stack instead of
	# serving a picker built for a board that no longer exists.
	_data.structure_changed.connect(_rebuild_copper_layer_pickers)

	# Status bar. TRIM_ELLIPSIS is load-bearing, not cosmetic: an unclipped
	# Label's MINIMUM width is its full text width, and this label carries the
	# armed-tool gesture hint (933px measured at medium) — without overrun
	# handling it inflates the whole WorkspaceVBox→MainVBox chain past the
	# pane and drags every stretch-width row off-screen (bug: the pane clips,
	# nothing scrolls; hint pcb-plugin/label-min-width-inflates-panel). The
	# full untruncated text is mirrored into the tooltip by _set_status.
	_status_label = Label.new()
	_status_label.name = "StatusBar"
	_status_label.custom_minimum_size.y = 22
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.mouse_filter = Control.MOUSE_FILTER_PASS
	workspace_vbox.add_child(_status_label)

	# Smart Select is the resting tool (finding 5) — engaged by default so the
	# canvas is immediately click-to-select/drag-to-move without a mode hunt.
	_canvas.set_tool_mode(_PcbCanvasScript.ToolMode.SELECT)

	_update_board_size_label()
	_update_status()

	# Responsive layout: modes resolve from the panel's OWN width (Minerva's
	# 1/2/3-column layouts are all just widths from in here).
	if not resized.is_connected(_on_panel_resized):
		resized.connect(_on_panel_resized)
	_apply_layout_mode(_PanelLayoutScript.mode_for_width(size.x), true)


func _build_toolbar() -> HBoxContainer:
	var tb := HBoxContainer.new()
	tb.name = "Toolbar"
	tb.custom_minimum_size.y = 34

	# Narrow-mode drawer toggle (hidden outside narrow): slides the sidebar in
	# over a squeezed 3-col panel where it can't be permanently visible.
	_drawer_button = Button.new()
	_drawer_button.name = "SidebarDrawerButton"
	_drawer_button.text = "☰"
	_drawer_button.tooltip_text = _wrap_tooltip("Show/hide the tools sidebar")
	_drawer_button.toggle_mode = true
	_drawer_button.visible = false
	_drawer_button.pressed.connect(_on_drawer_toggled)
	tb.add_child(_drawer_button)

	# Zoom controls.
	var zoom_out := Button.new()
	zoom_out.text = "−"  # minus sign
	zoom_out.tooltip_text = _wrap_tooltip("Zoom out (-)")
	zoom_out.pressed.connect(func() -> void: _canvas._zoom_at(_canvas.size / 2, 0.8))
	tb.add_child(zoom_out)

	var zoom_fit := Button.new()
	var fit_icon := _load_icon("zoom_fit_24.png")
	if fit_icon != null:
		zoom_fit.icon = fit_icon
	else:
		zoom_fit.text = "Fit"
	zoom_fit.tooltip_text = _wrap_tooltip("Zoom to fit")
	zoom_fit.pressed.connect(func() -> void: _canvas.zoom_to_fit())
	tb.add_child(zoom_fit)

	var zoom_in := Button.new()
	zoom_in.text = "+"
	zoom_in.tooltip_text = _wrap_tooltip("Zoom in (+)")
	zoom_in.pressed.connect(func() -> void: _canvas._zoom_at(_canvas.size / 2, 1.2))
	tb.add_child(zoom_in)

	tb.add_child(VSeparator.new())

	# The compact View menu is the ONE view-flags surface at every width
	# (owner ruling 2026-08-01, bug 019fbb6242): the former wide-mode inline
	# CheckButton row overflowed the toolbar at every width in ~[880, 1250]
	# because the WIDE threshold was calibrated when the flag list was five
	# entries long and the list grew to seven. The menu carries every flag as
	# a checkable item, synced from the canvas each time it opens, plus
	# Export YAML (the inline Export button hides at narrow).
	_view_menu_button = MenuButton.new()
	_view_menu_button.name = "ViewMenuButton"
	_view_menu_button.text = "View"
	var popup := _view_menu_button.get_popup()
	for i in _VIEW_FLAGS.size():
		popup.add_check_item(_VIEW_FLAGS[i][0], i)
	popup.add_separator()
	popup.add_item("Export YAML…", _VIEW_MENU_EXPORT_ID)
	popup.about_to_popup.connect(_sync_view_menu_checks)
	popup.id_pressed.connect(_on_view_menu_id_pressed)
	tb.add_child(_view_menu_button)

	tb.add_child(VSeparator.new())

	# Layer selector (drives the canvas trace-layer filter).
	var layer_label := Label.new()
	layer_label.text = "Layer:"
	tb.add_child(layer_label)

	_layer_option = OptionButton.new()
	_layer_option.name = "LayerOption"
	_rebuild_layer_option()
	_layer_option.item_selected.connect(_on_layer_selected)
	tb.add_child(_layer_option)

	tb.add_child(VSeparator.new())

	# YAML export (routes through the Go pcb.serialize channel).
	_export_button = Button.new()
	_export_button.name = "ExportButton"
	_export_button.text = "Export YAML"
	_export_button.tooltip_text = _wrap_tooltip("Export YAML — serialize the board via the plugin backend")
	_export_button.pressed.connect(_on_export_yaml_pressed)
	tb.add_child(_export_button)

	# Spacer + board size label.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tb.add_child(spacer)

	_board_size_label = Label.new()
	_board_size_label.name = "BoardSizeLabel"
	tb.add_child(_board_size_label)

	return tb


## Shared tooltip-wrap mechanism (docket 019fb933d4a9, tooltip overflow fix).
## Godot's default tooltip popup sizes itself to raw tooltip_text with NO
## word-wrap, so anything past a few dozen characters runs off the edge of
## the screen instead of wrapping — there is no engine flag for this. The
## standard trick is to insert our OWN line breaks at word boundaries before
## the text ever reaches tooltip_text; the default tooltip Label honors "\n"
## exactly like any other Label, so no custom Control or _make_custom_tooltip
## override is needed (least invasive, and verifiable by inspecting this
## function's own output — no live app required).
##
## EVERY tooltip_text assignment in this file routes through this function,
## even short ones that are already under the wrap width — that is what makes
## this a MECHANISM rather than a one-off patch: the next tooltip anyone adds
## here, short or long, wraps automatically as long as it is assigned through
## this function too.
const _TOOLTIP_WRAP_CHARS := 60

static func _wrap_tooltip(text: String, max_chars: int = _TOOLTIP_WRAP_CHARS) -> String:
	if text.length() <= max_chars:
		return text
	var lines: PackedStringArray = []
	var current := ""
	for word in text.split(" "):
		if current.is_empty():
			current = word
		elif current.length() + 1 + word.length() <= max_chars:
			current += " " + word
		else:
			lines.append(current)
			current = word
	if not current.is_empty():
		lines.append(current)
	return "\n".join(lines)


func _add_tool_button(tb: Container, mode: int, text: String, tip: String, icon_file := "") -> void:
	var btn := Button.new()
	var icon := _load_icon(icon_file) if not icon_file.is_empty() else null
	if icon != null:
		# Icon-only (legacy look, and the narrow-column width saver); the
		# name stays discoverable via the tooltip.
		btn.icon = icon
	else:
		btn.text = text
	btn.tooltip_text = _wrap_tooltip(tip)
	btn.toggle_mode = true
	btn.pressed.connect(func() -> void: _toggle_tool_mode(mode))
	tb.add_child(btn)
	_tool_buttons[mode] = btn


## The draft twin of _add_tool_button (UX4 S7): SAME icon asset, GHOST-TINTED
## (icon color at ghost alpha — the one proposal design language, owner ruling
## 4), arming through _toggle_draft_tool. Named "<text>DraftButton" so the
## layout suite can tell the families apart.
const _DRAFT_ICON_TINT := Color(1.0, 1.0, 1.0, 0.55)


func _add_draft_tool_button(tb: Container, mode: int, text: String, tip: String, icon_file := "") -> void:
	var btn := Button.new()
	btn.name = "%sDraftButton" % text
	var icon := _load_icon(icon_file) if not icon_file.is_empty() else null
	if icon != null:
		btn.icon = icon
		for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
			btn.add_theme_color_override(state, _DRAFT_ICON_TINT)
	else:
		btn.text = text
		btn.modulate = _DRAFT_ICON_TINT
	btn.tooltip_text = _wrap_tooltip(tip)
	btn.toggle_mode = true
	btn.pressed.connect(func() -> void: _toggle_draft_tool(mode))
	tb.add_child(btn)
	_draft_tool_buttons[mode] = btn


## Sidebar section label — the 11px caption idiom shared by all three tool
## groups. Named "<text>GroupLabel" (e.g. ProposalsGroupLabel; a repo-wide grep
## 2026-08-01 found NO name lookups, so renaming a section is a text-only change)
## keep resolving.
func _add_group_label(text: String) -> void:
	var group_label := Label.new()
	group_label.name = text + "GroupLabel"
	group_label.text = text
	group_label.add_theme_font_size_override("font_size", 11)
	_sidebar_content.add_child(group_label)


## Loads an icon from the plugin's own assets dir (next to this script).
## Plugins live OUTSIDE res://, so preload() can't reach the PNGs — resolve the
## script's directory and load from the filesystem. Fail-safe: any miss returns
## null and callers fall back to a text button (never a blank one).
func _load_icon(fname: String) -> Texture2D:
	var script_ref: Script = get_script() as Script
	if script_ref == null or script_ref.resource_path.is_empty():
		return null
	var dir := script_ref.resource_path.get_base_dir()
	var path := ProjectSettings.globalize_path(dir.path_join("assets/icons").path_join(fname))
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


# ── Right sidebar (legacy layout clone) ────────────────────────────────────────

## Tools live in a wrap-capable flow (legacy FlowContainer pattern: buttons wrap
## to more rows as the column narrows instead of overflowing), followed by the
## mount point for the platform annotation dock (Tools/Annotate/list — round A
## hook), which fills the remaining height.
func _build_sidebar() -> VBoxContainer:
	_sidebar = VBoxContainer.new()
	_sidebar.name = "RightSidebar"
	_sidebar.custom_minimum_size.x = 120
	_sidebar.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# B3b height relief (docket 019fbbad9dac comment 970): RightSidebar's own
	# unscrolled row content was the dominant term in the panel's min-height
	# floor (measured 558px at rest / 636px with ZONE_POUR armed — nearly all
	# of WorkspaceFrame's 598/676px, which in turn drove the whole editor
	# column's 640/718px). A ScrollContainer's minimum size does NOT include
	# its child's content size (that is the entire point of the control), so
	# wrapping every row in one caps what RightSidebar can force onto its
	# ancestors regardless of how many picker rows a future armed tool adds —
	# the content simply scrolls in a short pane instead of pushing the whole
	# editor tab into overflow. horizontal_scroll_mode stays DISABLED so the
	# WIDTH behavior (driven by _sidebar.custom_minimum_size.x above + the
	# FlowContainers' own wrap) is byte-identical to before this change; only
	# the vertical axis is relieved.
	_sidebar_scroll = ScrollContainer.new()
	_sidebar_scroll.name = "RightSidebarScroll"
	_sidebar_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_sidebar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_sidebar_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sidebar_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# General "keyboard focus stays on screen" behavior for a scrollable
	# sidebar. NOT what fixes the trace-width reveal (see
	# _reveal_trace_width_spin, F3 round 2) — that path's own explicit
	# ensure_control_visible call, deferred one layout pass, is what reaches
	# 31/31px visible at both reference panes; verified by mutation that this
	# flag can be removed entirely once the reveal is properly deferred. Kept
	# for the keyboard-Tab path, which this round did not build a test for.
	_sidebar_scroll.follow_focus = true
	_sidebar.add_child(_sidebar_scroll)

	_sidebar_content = VBoxContainer.new()
	_sidebar_content.name = "RightSidebarContent"
	_sidebar_scroll.add_child(_sidebar_content)

	## Three labeled tool sections (docket 019fb5624e2e; sectioning corrected
	## per boundary bug 019fb5c74980): Select (navigation/inspection), Draw
	## (tools that author board entities), Hints (route-hint authoring for the
	## router). Each section is an 11px label ABOVE its flow so the label
	## unambiguously captions the group below it; HSeparator between sections.
	_add_group_label("Select")
	var tools_flow := FlowContainer.new()
	tools_flow.name = "ToolsFlow"
	_sidebar_content.add_child(tools_flow)

	# ONE smart Select tool + a Pan tool (Photoshop / GraphicsEditor style,
	# finding 5). Select does select + move + box-select + rotate; Pan drags
	# the whole view.
	_add_tool_button(tools_flow, _PcbCanvasScript.ToolMode.SELECT, "Select",
		"Select & move (S) — click to select, drag to move",
		"select_24.png")
	_add_tool_button(tools_flow, _PcbCanvasScript.ToolMode.PAN, "Pan",
		"Pan the view (drag anywhere)",
		"pan_24.png")

	# Pin inspector (WC-1) — a TRUE toggle (unlike the Select/Pan radio tools):
	# pressed arms INSPECT_PIN, pressed-again exits back to Select.
	_inspect_pin_button = Button.new()
	_inspect_pin_button.name = "InspectPinButton"
	var inspect_icon := _load_icon("inspect_pin_24.png")
	if inspect_icon != null:
		_inspect_pin_button.icon = inspect_icon
	else:
		_inspect_pin_button.text = "Pin"
	_inspect_pin_button.tooltip_text = _wrap_tooltip("Click a pin to see its info (Shift+P)")
	_inspect_pin_button.toggle_mode = true
	_inspect_pin_button.pressed.connect(_on_inspect_pin_button_pressed)
	tools_flow.add_child(_inspect_pin_button)
	_tool_buttons[_PcbCanvasScript.ToolMode.INSPECT_PIN] = _inspect_pin_button

	# Draw section (epoch 6 units 4+5; own section per boundary bug
	# 019fb5c74980): these tools author board ENTITIES — zones and traces that
	# serialize into the board YAML — a different altitude from the Select
	# tools above (which touch nothing) and the router Hints below (which
	# request copper rather than draw it). Two zone buttons rather than one
	# moded tool — the radio idiom _add_tool_button provides is exactly "one
	# of these is active".
	_sidebar_content.add_child(HSeparator.new())
	_add_group_label("Tools")
	var draw_flow := FlowContainer.new()
	draw_flow.name = "DrawFlow"
	_sidebar_content.add_child(draw_flow)

	_add_tool_button(draw_flow, _PcbCanvasScript.ToolMode.ZONE_POUR, "Pour",
		"Draw a copper pour (pick a net, click corners, Enter to close)", "pour_24.png")
	_add_tool_button(draw_flow, _PcbCanvasScript.ToolMode.ZONE_KEEPOUT, "Keepout",
		"Draw a keep-out region (click corners, Enter to close)", "keepout_24.png")

	# Trace drawing tool (epoch 6 unit 5). Same section and same reason as the
	# zone tools above: it authors a board ENTITY. It shares a name with the
	# Proposals-group Trace button below and that is deliberate — they draw the
	# same thing at two different altitudes — so the icon (solid pads vs the
	# hint's hollow ones) and tooltip carry the distinction outright: this one
	# IS the copper, that one is a request for copper.
	_add_tool_button(draw_flow, _PcbCanvasScript.ToolMode.TRACE, "Trace",
		"Draw copper directly (click a pad to start)", "trace_draw_24.png")

	# Cutout drawing tool (campaign 2 epoch B, unit 3). Same section and same
	# reason as Pour/Keepout/Trace above: it authors a board ENTITY (a Cutout,
	# an opening through the whole board). No net/layer arming control — a
	# cutout has neither (see pcb_data.gd's Cutout Management doc) — so unlike
	# the zone tools it needs no sidebar picker at all; _sync_draw_arm_ui's
	# is_zone_tool/is_pour_tool/is_trace_tool booleans all fall through false
	# for it.
	_add_tool_button(draw_flow, _PcbCanvasScript.ToolMode.CUTOUT, "Cutout",
		"Draw a board opening (click corners, Enter to close)", "cutout_24.png")

	# Bus tool (campaign 2 epoch C, unit 5, DCR 019fb572b888 S3+S4). Same
	# section and same reason as Pour/Keepout/Trace/Cutout above: it authors
	# board ENTITIES (N real Trace entities, one undo step). No sidebar
	# picker: unlike Pour's net picker, the net LIST is authored by clicking
	# pads/traces on the canvas itself (the S3 picker), not a widget — see
	# pcb_canvas.gd's Bus Authoring region.
	_add_tool_button(draw_flow, _PcbCanvasScript.ToolMode.BUS, "Bus",
		"Draw a parallel bus (pick nets by clicking pads; Enter commits, Shift+Enter proposes)", "bus_24.png")

	# Eraser (item 019fb934827776) + Delete/trash-can (item 019fb92f8b83) live
	# HERE, not in the Select section above (cold-review N3) — the section
	# comment's own taxonomy draws the line at "the Select tools above ...
	# touch nothing"; Eraser and Delete both mutate the board's entity list
	# (they are Draw's destructive twin — Draw adds entities, these remove
	# them), the same altitude as Pour/Keepout/Trace, not Select/Pan's
	# navigate-only altitude. The exclusion wiring is untouched: Eraser is
	# still just another _add_tool_button -> _toggle_tool_mode radio tool, and
	# Delete is still the same plain action button, both merely relocated to
	# this flow.
	_add_tool_button(draw_flow, _PcbCanvasScript.ToolMode.ERASER, "Eraser",
		"Click an entity to delete it (Esc to disarm)", "eraser_24.png")

	_delete_button = Button.new()
	_delete_button.name = "DeleteSelectionButton"
	# Icon with text fallback, same contract as _add_tool_button: a missing
	# asset yields a text button, never a blank one.
	var trash_icon := _load_icon("trash_24.png")
	if trash_icon != null:
		_delete_button.icon = trash_icon
	else:
		_delete_button.text = "Delete"
	_delete_button.tooltip_text = _wrap_tooltip("Delete the whole selection (Delete/Backspace)")
	_delete_button.disabled = true
	_delete_button.pressed.connect(func() -> void: _canvas._delete_selection())
	draw_flow.add_child(_delete_button)

	# The Draw tools' arming controls. Each is shown only while the tool it arms
	# is active, so the resting sidebar is unchanged.
	_zone_net_option = OptionButton.new()
	_zone_net_option.name = "ZoneNetOption"
	_zone_net_option.tooltip_text = _wrap_tooltip("Net for the pour being drawn")
	_zone_net_option.visible = false
	_rebuild_zone_net_option()
	_zone_net_option.item_selected.connect(_on_zone_net_selected)
	_sidebar_content.add_child(_zone_net_option)

	_zone_layer_option = OptionButton.new()
	_zone_layer_option.name = "ZoneLayerOption"
	_zone_layer_option.tooltip_text = _wrap_tooltip("Copper layer for the zone being drawn")
	_zone_layer_option.visible = false
	_rebuild_zone_layer_option()
	_zone_layer_option.item_selected.connect(_on_zone_layer_selected)
	_sidebar_content.add_child(_zone_layer_option)

	# Trace width. A SpinBox rather than a picker because width is continuous —
	# there is no list of legal widths to choose from, only the board's design
	# rule as a starting point. Bounds are sanity rails, not fabrication rules —
	# stated once, on the entity that has a width (pcb_trace.MIN/MAX_WIDTH_MM),
	# and shared with the model setter and the preference registry since A7.
	_trace_width_spin = SpinBox.new()
	_trace_width_spin.name = "TraceWidthSpin"
	_trace_width_spin.tooltip_text = _wrap_tooltip("Width of new traces, in mm (design-rule default)")
	_trace_width_spin.min_value = _PcbTraceScript.MIN_WIDTH_MM
	_trace_width_spin.max_value = _PcbTraceScript.MAX_WIDTH_MM
	_trace_width_spin.step = 0.05
	_trace_width_spin.suffix = "mm"
	_trace_width_spin.visible = false
	_trace_width_spin.value_changed.connect(_on_trace_width_changed)
	_sidebar_content.add_child(_trace_width_spin)

	_sidebar_content.add_child(HSeparator.new())
	_add_group_label("Proposals")

	var hints_flow := FlowContainer.new()
	hints_flow.name = "HintsFlow"
	_sidebar_content.add_child(hints_flow)

	# Route-flow toolbar cluster (WC-3, contract §5): a TRUE toggle per route
	# author tool, same idiom as the pin inspector button above. Only
	# single-trace lives here today (mutual exclusion via _route_flow_buttons
	# is already generic, so a future route-HINT tool can still join it).
	# STALE FORWARD-REFERENCE, CORRECTED (C5, campaign 2 epoch C unit 5, DCR
	# 019fb572b888): this comment used to promise a "Bus" button landing HERE,
	# in _route_flow_buttons. The bus tool that shipped is a DIRECT-copper
	# author (ToolMode.BUS, real Trace entities, no router involved) — the
	# same altitude as Pour/Keepout/Trace/Cutout, not the Proposals/route-hint
	# family this cluster is — so it is a Draw-flow radio button in
	# _tool_buttons (see _add_tool_button(draw_flow, ToolMode.BUS, "Bus", ...)
	# below), not a member of this table.
	var trace_btn := Button.new()
	trace_btn.name = "SingleTraceButton"
	var trace_icon := _load_icon("trace_24.png")
	if trace_icon != null:
		trace_btn.icon = trace_icon
	else:
		trace_btn.text = "Trace"
	trace_btn.tooltip_text = _wrap_tooltip("Draw a single-trace route hint (click pad, waypoints, pad)")
	trace_btn.toggle_mode = true
	trace_btn.pressed.connect(_on_single_trace_button_pressed)
	hints_flow.add_child(trace_btn)
	_route_flow_buttons["single_trace"] = trace_btn

	# Bend-handle editing tool (C4, docket 019f6c464ff0): select a committed
	# route hint, then drag/right-click/click its bend points to edit them.
	# Same TRUE-toggle idiom as the Trace button; shares mutual exclusion
	# with the rest of the cluster (and the canvas tool surface) for free —
	# see _activate_route_flow_tool.
	var edit_hint_btn := Button.new()
	edit_hint_btn.name = "EditHintButton"
	var edit_hint_icon := _load_icon("waypoint_24.png")
	if edit_hint_icon != null:
		edit_hint_btn.icon = edit_hint_icon
	else:
		edit_hint_btn.text = "Edit Hint"
	edit_hint_btn.tooltip_text = _wrap_tooltip("Edit a route hint's bend points")
	edit_hint_btn.toggle_mode = true
	edit_hint_btn.pressed.connect(_on_edit_hint_button_pressed)
	hints_flow.add_child(edit_hint_btn)
	_route_flow_buttons["edit_hint"] = edit_hint_btn

	# Manual via-insertion tool (U4, DCR 019f7095c395 Stage-2): select a
	# proposal, then click a point on its route to split the segment, add a
	# via, and flip the following run to the opposite copper layer. Same
	# TRUE-toggle idiom as Trace/Edit Hint above; shares mutual exclusion with
	# the rest of the cluster via _route_flow_buttons for free.
	var add_via_btn := Button.new()
	add_via_btn.name = "AddViaButton"
	var add_via_icon := _load_icon("via_24.png")
	if add_via_icon != null:
		add_via_btn.icon = add_via_icon
	else:
		add_via_btn.text = "Add Via"
	add_via_btn.tooltip_text = _wrap_tooltip("Insert a via on a selected proposal")
	add_via_btn.toggle_mode = true
	add_via_btn.pressed.connect(_on_add_via_button_pressed)
	hints_flow.add_child(add_via_btn)
	_route_flow_buttons["add_via"] = add_via_btn

	# Propose button (C5, docket 019f6c465fd8, deliverable 1): explicit-propose
	# UX — the router NEVER runs implicitly (product contract v2). This is a
	# non-toggle ACT button (not part of _route_flow_buttons' mutual-exclusion
	# radio set — it fires once and returns, it doesn't arm a drawing tool),
	# sitting beside the toggle tools for discoverability. Runs the SAME code
	# path as the panel tool minerva_pcb_apply_route_hints with commit=false —
	# see _on_propose_button_pressed.
	_propose_button = Button.new()
	_propose_button.name = "ProposeButton"
	var propose_icon := _load_icon("trace_icon_1_24.png")
	if propose_icon != null:
		_propose_button.icon = propose_icon
	else:
		_propose_button.text = "Propose"
	_propose_button.tooltip_text = _wrap_tooltip("Run the router over open route hints (board unchanged)")
	_propose_button.pressed.connect(_on_propose_button_pressed)
	hints_flow.add_child(_propose_button)

	# ── UX4 station 7 (DCR S7): the DRAFT authoring doorways ─────────────────
	# The owner's HITL-7 gap ("I can't propose bus, cut-out or keepout"),
	# answered where proposals live: the SAME four Draw tools, ghost-tinted,
	# arming with authoring_destination DRAFT — commits stage review ghosts
	# instead of writing the board. One gesture, two doorways; the commit-site
	# branch (pcb_canvas _commit_zone/_commit_cutout/_commit_bus) is the whole
	# difference (A8).
	var draft_flow := FlowContainer.new()
	draft_flow.name = "DraftFlow"
	_sidebar_content.add_child(draft_flow)
	_add_draft_tool_button(draft_flow, _PcbCanvasScript.ToolMode.ZONE_POUR, "Pour",
		"Propose a copper pour as a DRAFT (ghost for review — Accept lands it)", "pour_24.png")
	_add_draft_tool_button(draft_flow, _PcbCanvasScript.ToolMode.ZONE_KEEPOUT, "Keepout",
		"Propose a keep-out region as a DRAFT (ghost for review — Accept lands it)", "keepout_24.png")
	_add_draft_tool_button(draft_flow, _PcbCanvasScript.ToolMode.CUTOUT, "Cutout",
		"Propose a board opening as a DRAFT (ghost for review — Accept lands it)", "cutout_24.png")
	_add_draft_tool_button(draft_flow, _PcbCanvasScript.ToolMode.BUS, "Bus",
		"Propose a parallel bus (Enter lands ghost candidates for review, never copper)", "bus_24.png")
	# SPIKE 019ff8615fbe: the "Propose moves" mode toggle that briefly lived
	# here was REJECTED at the R2 feel session ("conflicts with universal
	# select") — proposing a move is now a one-shot arm on the component's
	# own context menu (pcb_canvas MENU_ID_COMPONENT_PROPOSE_MOVE).

	# Per-HINT width row (HITL-7c, docket 019fe0395764 — owner override of
	# station 8b's standing authoring picker: "feels disconnected from
	# anything; should be a right-click context menu option"). HIDDEN until
	# the selected hint's "Set hint width…" menu item reveals it, bound BY ID
	# to that hint; edits write kind_payload.width_mm through
	# update_annotation (0 = auto: the key is erased, net-class default
	# rules). The same reveal-and-focus idiom the trace-width item
	# established (comment 962 / BT-68).
	_hint_width_row = HBoxContainer.new()
	_hint_width_row.name = "HintWidthRow"
	_hint_width_row.visible = false
	_hint_width_label = Label.new()
	_hint_width_label.text = "Width"
	_hint_width_row.add_child(_hint_width_label)
	_hint_width_spin = SpinBox.new()
	_hint_width_spin.name = "HintWidthSpin"
	_hint_width_spin.min_value = 0.0
	_hint_width_spin.max_value = 5.0
	_hint_width_spin.step = 0.05
	_hint_width_spin.value = 0.0
	_hint_width_spin.tooltip_text = _wrap_tooltip("This hint's trace width in mm — 0 = auto (net class default)")
	_hint_width_spin.value_changed.connect(_on_hint_width_changed)
	_hint_width_row.add_child(_hint_width_spin)
	hints_flow.add_child(_hint_width_row)

	# Draft-DRC over the live ghosts (Epoch UX3 station 3, docket
	# 019fdf90662a): PCBPanel.check_draft shipped with NO UI caller — only the
	# MCP verb reached it, so a human could propose and commit without ever
	# seeing a verdict. Same code path as minerva_pcb_workspace_check.
	_check_button = Button.new()
	_check_button.name = "CheckButton"
	var check_icon := _load_icon("check_24.png")
	if check_icon != null:
		_check_button.icon = check_icon
	else:
		_check_button.text = "Check"
	_check_button.tooltip_text = _wrap_tooltip("Draft-DRC the live route proposals against the board and each other (board unchanged)")
	_check_button.pressed.connect(_on_check_button_pressed)
	hints_flow.add_child(_check_button)

	# PROMOTE (Epoch UX3 station 11, K13): the serialize-back verb, DRC-gated
	# — impossible on a dirty board, refusals listed in a dialog. The one
	# button that makes the live board the durable design of record.
	var promote_btn := Button.new()
	promote_btn.name = "PromoteButton"
	var promote_icon := _load_icon("promote_24.png")
	if promote_icon != null:
		promote_btn.icon = promote_icon
	else:
		promote_btn.text = "Promote"
	# Tooltip stays inside the BT-44 90-char budget; the dialog carries detail.
	promote_btn.tooltip_text = _wrap_tooltip("Write the board back to canonical YAML — allowed only when the full DRC gate passes")
	promote_btn.pressed.connect(_on_promote_button_pressed)
	hints_flow.add_child(promote_btn)

	# RouteFlowModeLabel removed (owner HITL 2026-07-30): its idle text
	# "Select" read as a duplicate section header under the real ones, and the
	# pressed state of the toggle buttons already shows the armed tool.
	# _route_flow_mode_label stays null; _update_route_flow_mode_label is
	# null-guarded, so every update site is a safe no-op.

	_sidebar_content.add_child(HSeparator.new())

	# Platform annotation dock mounts here (Editor duck-types
	# get_annotation_dock_parent — round A). Fills the remaining column.
	_dock_parent = VBoxContainer.new()
	_dock_parent.name = "AnnotationDockParent"
	_dock_parent.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sidebar_content.add_child(_dock_parent)

	_sidebar_content.add_child(HSeparator.new())
	_sidebar_content.add_child(_build_properties_section())

	_sidebar_content.add_child(HSeparator.new())
	_sidebar_content.add_child(_build_pin_info_section())

	return _sidebar


## Properties section (legacy clone): ID / Position / Rotation / Layer /
## Footprint of the single-selected component. Collapsible — wide mode expands
## it by default, medium collapses it (3-col width is precious); the selection
## summary also mirrors into the status bar either way.
func _build_properties_section() -> VBoxContainer:
	var section := VBoxContainer.new()
	section.name = "PropertiesSection"

	_properties_collapse_btn = Button.new()
	_properties_collapse_btn.name = "PropertiesHeader"
	_properties_collapse_btn.text = "Properties"
	_properties_collapse_btn.flat = true
	_properties_collapse_btn.toggle_mode = true
	_properties_collapse_btn.pressed.connect(func() -> void:
		_set_properties_expanded(not _properties_expanded))
	section.add_child(_properties_collapse_btn)

	_properties_body = VBoxContainer.new()
	_properties_body.name = "PropertiesBody"
	section.add_child(_properties_body)

	for field in ["ID", "Position", "Rotation", "Layer", "Footprint"]:
		var row := HBoxContainer.new()
		var key_label := Label.new()
		key_label.text = "%s:" % field
		key_label.custom_minimum_size.x = 60
		row.add_child(key_label)
		var value_label := Label.new()
		value_label.text = "-"
		value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		value_label.clip_text = true
		row.add_child(value_label)
		_prop_labels[field] = value_label
		_properties_body.add_child(row)

	_properties_body.add_child(_build_group_rows())
	_properties_body.add_child(_build_zone_rows())
	_properties_body.add_child(_build_trace_rows())
	return section


## The two component-group rows (A4 stage 2), built in the SAME key-label +
## value-control shape as the five rows above so the section reads as one thing.
##
## The offset fields are the panel's first EDITABLE property control; everything
## above them is a read-out. They commit on Enter (text_submitted) and on losing
## focus, and a refused or malformed edit snaps straight back to the model's
## value — the model, not the field, is what an offset IS.
func _build_group_rows() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "GroupRows"

	_group_row = HBoxContainer.new()
	_group_row.name = "GroupRow"
	_group_row.visible = false
	var group_key := Label.new()
	group_key.text = "Group:"
	group_key.custom_minimum_size.x = 60
	_group_row.add_child(group_key)
	_group_value_label = Label.new()
	_group_value_label.name = "GroupValue"
	_group_value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_group_value_label.clip_text = true
	_group_row.add_child(_group_value_label)
	box.add_child(_group_row)

	_offset_row = HBoxContainer.new()
	_offset_row.name = "OffsetRow"
	_offset_row.visible = false
	var offset_key := Label.new()
	offset_key.text = "Offset:"
	offset_key.custom_minimum_size.x = 60
	_offset_row.add_child(offset_key)
	_offset_x_edit = _build_offset_edit("OffsetX", "X mm")
	_offset_row.add_child(_offset_x_edit)
	_offset_y_edit = _build_offset_edit("OffsetY", "Y mm")
	_offset_row.add_child(_offset_y_edit)
	box.add_child(_offset_row)

	return box


func _build_offset_edit(edit_name: String, hint: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.name = edit_name
	edit.placeholder_text = hint
	edit.tooltip_text = _wrap_tooltip("%s offset from the group anchor, in mm" % hint)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size.x = 48
	edit.text_submitted.connect(func(_t: String) -> void: _commit_member_offset())
	edit.focus_exited.connect(_commit_member_offset)
	return edit


## The selected zone's property rows (A5), built in the SAME key-label +
## value-control shape as the component rows above and the group rows beside them,
## so the section still reads as one thing whichever kind is selected.
##
## KIND is a read-out, not a control. A pour and a keepout are different entities
## with different rules (a pour must name a net; a keepout must not carry one
## here), and "turn this pour into a keepout" is an authoring decision, not a
## property tweak — offering it as a dropdown would quietly strip a net.
##
## The NET row is POURS ONLY, hidden (not merely disabled) for a keepout — the
## exact rule, and the exact reasoning, the arming picker already follows: a
## visible control is a request for input, and asking for a net the model will
## refuse is the UI lying about the contract.
func _build_zone_rows() -> VBoxContainer:
	_zone_prop_rows = VBoxContainer.new()
	_zone_prop_rows.name = "ZoneRows"
	_zone_prop_rows.visible = false

	_zone_kind_row = HBoxContainer.new()
	_zone_kind_row.name = "ZoneKindRow"
	var kind_key := Label.new()
	kind_key.text = "Zone:"
	kind_key.custom_minimum_size.x = 60
	_zone_kind_row.add_child(kind_key)
	_zone_kind_value_label = Label.new()
	_zone_kind_value_label.name = "ZoneKindValue"
	_zone_kind_value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_kind_value_label.clip_text = true
	_zone_kind_row.add_child(_zone_kind_value_label)
	_zone_prop_rows.add_child(_zone_kind_row)

	_zone_prop_net_row = HBoxContainer.new()
	_zone_prop_net_row.name = "ZoneNetRow"
	var net_key := Label.new()
	net_key.text = "Net:"
	net_key.custom_minimum_size.x = 60
	_zone_prop_net_row.add_child(net_key)
	_zone_prop_net_option = OptionButton.new()
	_zone_prop_net_option.name = "ZonePropNetOption"
	_zone_prop_net_option.tooltip_text = _wrap_tooltip("Net this pour is tied to (declared nets only)")
	_zone_prop_net_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_prop_net_option.clip_text = true
	_zone_prop_net_option.item_selected.connect(_on_zone_prop_net_selected)
	_zone_prop_net_row.add_child(_zone_prop_net_option)
	_zone_prop_rows.add_child(_zone_prop_net_row)

	_zone_prop_layer_row = HBoxContainer.new()
	_zone_prop_layer_row.name = "ZoneLayerRow"
	var layer_key := Label.new()
	layer_key.text = "Layer:"
	layer_key.custom_minimum_size.x = 60
	_zone_prop_layer_row.add_child(layer_key)
	_zone_prop_layer_option = OptionButton.new()
	_zone_prop_layer_option.name = "ZonePropLayerOption"
	_zone_prop_layer_option.tooltip_text = _wrap_tooltip("Copper layer this zone sits on (declared stack only)")
	_zone_prop_layer_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zone_prop_layer_option.clip_text = true
	_zone_prop_layer_option.item_selected.connect(_on_zone_prop_layer_selected)
	_zone_prop_layer_row.add_child(_zone_prop_layer_option)
	_zone_prop_rows.add_child(_zone_prop_layer_row)

	return _zone_prop_rows


func _set_properties_expanded(expanded: bool) -> void:
	_properties_expanded = expanded
	if _properties_body != null:
		_properties_body.visible = expanded
	if _properties_collapse_btn != null:
		_properties_collapse_btn.button_pressed = expanded
		_properties_collapse_btn.text = "Properties" if expanded else "Properties…"


## MEASURED RESTRUCTURE (A5): this used to BLANK AND RETURN whenever no component
## was focused, so a zone-only selection could never reach any property row at
## all — the zone rows would have been dead UI. The component half is byte-for-byte
## what it was, only moved into an else-branch, and the zone half now runs on every
## update regardless of what the component half decided. Nothing about a
## component-only or empty selection changed.
func _update_properties() -> void:
	if _prop_labels.is_empty() or _canvas == null or _data == null:
		return
	var comp = _property_focus_component()
	if comp == null:
		for key in _prop_labels:
			(_prop_labels[key] as Label).text = "-"
		_hide_group_rows()
	else:
		_update_group_rows(comp)
		(_prop_labels["ID"] as Label).text = str(comp.id)
		(_prop_labels["Position"] as Label).text = "(%.1f, %.1f)" % [comp.position.x, comp.position.y]
		(_prop_labels["Rotation"] as Label).text = "%.0f°" % float(comp.rotation)
		(_prop_labels["Layer"] as Label).text = str(comp.layer)
		var fp := str(comp.footprint_id)
		if fp.is_empty() and "FootprintType" in _PcbComponentScript:
			fp = str(_PcbComponentScript.FootprintType.keys()[comp.footprint])
		(_prop_labels["Footprint"] as Label).text = fp
	_update_zone_rows()
	_update_trace_rows()


## Drive the zone re-property rows for the selected zone.
##
## EXACTLY ONE selected zone, or the rows hide — the same rule the component half
## applies to a multi-selection (_property_focus_component returns null for two
## loose parts): with two zones selected there is no single thing a dropdown could
## re-property. A mixed component+zone selection shows BOTH halves, which is
## honest: each describes what it says it describes.
func _update_zone_rows() -> void:
	if _zone_prop_rows == null:
		return
	var selected: Array = _canvas.get_selected_zones()
	if selected.size() != 1:
		_hide_zone_rows()
		return
	var zone_id := str(selected[0])
	var zone: Dictionary = _data.get_zone(zone_id)
	if zone.is_empty():
		_hide_zone_rows()
		return

	_zone_prop_zone_id = zone_id
	_zone_prop_rows.visible = true
	var kind: String = _data.zone_kind(zone)
	var is_keepout := kind == "keepout"
	_zone_kind_value_label.text = "keepout" if is_keepout else "copper pour"
	_zone_prop_net_row.visible = not is_keepout
	if not is_keepout:
		_rebuild_zone_prop_net_option(str(zone.get("net", "")))
	_rebuild_zone_prop_layer_option(str(zone.get("layer", "")))


func _hide_zone_rows() -> void:
	_zone_prop_zone_id = ""
	if _zone_prop_rows != null:
		_zone_prop_rows.visible = false


## The selected TRACE's property rows (A7). ONE row so far — its width — built in
## the same key-label + value-control shape as the zone rows above, with a
## SpinBox for the same reason the arming control uses one: width is continuous,
## so there is no list of legal values to pick from.
##
## Bounded by the SAME contract the model setter enforces (pcb_trace MIN/MAX),
## so a value the box can express is a value the board will accept — a control
## that could offer 40 mm and then be refused would be the UI lying about the
## contract, the rule the zone pickers already follow.
func _build_trace_rows() -> VBoxContainer:
	_trace_prop_rows = VBoxContainer.new()
	_trace_prop_rows.name = "TraceRows"
	_trace_prop_rows.visible = false

	var row := HBoxContainer.new()
	row.name = "TraceWidthRow"
	var key := Label.new()
	key.text = "Width:"
	key.custom_minimum_size.x = 60
	row.add_child(key)

	_trace_prop_width_spin = SpinBox.new()
	_trace_prop_width_spin.name = "TracePropWidthSpin"
	_trace_prop_width_spin.tooltip_text = _wrap_tooltip("Width of the selected trace, in mm (re-widens it)")
	_trace_prop_width_spin.min_value = _PcbTraceScript.MIN_WIDTH_MM
	_trace_prop_width_spin.max_value = _PcbTraceScript.MAX_WIDTH_MM
	_trace_prop_width_spin.step = 0.05
	_trace_prop_width_spin.suffix = "mm"
	_trace_prop_width_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trace_prop_width_spin.value_changed.connect(_on_trace_prop_width_changed)
	row.add_child(_trace_prop_width_spin)
	_trace_prop_rows.add_child(row)

	return _trace_prop_rows


## Drive the trace property row for the selected trace. EXACTLY ONE selected
## trace or the row hides — the same rule the zone half applies, and for the same
## reason: with two traces selected there is no single width a box could show.
func _update_trace_rows() -> void:
	if _trace_prop_rows == null:
		return
	var selected: Array = _canvas.get_selected_traces()
	if selected.size() != 1:
		_hide_trace_rows()
		return
	var trace_id := str(selected[0])
	var trace = _data.get_trace(trace_id)
	if trace == null:
		_hide_trace_rows()
		return
	_trace_prop_trace_id = trace_id
	_trace_prop_rows.visible = true
	# set_value_no_signal for the SAME reason the arming box uses it: assigning
	# would fire value_changed and commit the box's step-rounded number back onto
	# the trace, so merely SELECTING a 0.254 mm trace would silently re-width it
	# to 0.25 and push an undo step nobody asked for.
	_trace_prop_width_spin.set_value_no_signal(float(trace.width))


func _hide_trace_rows() -> void:
	_trace_prop_trace_id = ""
	if _trace_prop_rows != null:
		_trace_prop_rows.visible = false


## The canvas context menu's "Set trace width…" landing (B1u5, owner comment 962:
## the numeric editor already existed and nobody could find it).
##
## NO SECOND EDITOR — but it does more than reveal one row. It CLEARS THE PATH to
## the SpinBox built by _build_trace_rows and then focuses it, so the commit still
## runs through _on_trace_prop_width_changed, which owns the no-op guard (no dead
## undo step), the model's refusal string verbatim in the status bar, and the
## single journalled data.set_trace_width. A menu item that set a width itself
## would be a second mutation path onto the same field, with its own copy of all
## three rules to keep in step; there is also no dialog anywhere in this panel to
## put one in.
##
## CLEARING THE PATH IS THE WHOLE POINT, and getting it wrong reproduces the very
## complaint this item exists to answer (cold-review F1, empirically proven). The
## row's own `visible` flag is NOT enough: it lives inside _properties_body, which
## _apply_layout_mode COLLAPSES BY DEFAULT in the medium (3-column) tier
## (`_set_properties_expanded(wide)`), and the whole sidebar hides behind
## _drawer_open in narrow. A handler that only checked the row would leave the
## owner picking "Set trace width…" in a medium pane and seeing nothing happen at
## all — comment 962's bug, delivered by its own fix. So enclosures are opened
## first, in outside-in order (drawer, then section, then row); the row-visible
## test that used to sit here now lives in _reveal_trace_width_spin, one layout
## pass later (below).
##
## B3b (cold review F3, 2026-08-01) added a FOURTH enclosure this handler did not
## originally know about: RightSidebarScroll, the ScrollContainer the sidebar's
## rows now live inside (see _sidebar_scroll). Opening the drawer/section/row
## enclosures is not enough if the target row is still scrolled OUT of the
## viewport — is_visible_in_tree is true for a clipped-but-mounted control, so a
## same-frame grab_focus() would silently succeed on an invisible field (measured:
## 28px below the fold at the round's own 500px reference pane, fully hidden at
## 400px). ROUND 2 (cold review, same day): the FIRST fix attempt called
## ensure_control_visible in the SAME frame as the drawer/section expansion above
## and was STILL wrong — that call races the just-triggered expansion's own
## layout pass and clamps its scroll target short by exactly one row height
## (measured: pane 500px, the SpinBox landed with its top edge exactly ON the
## viewport's bottom edge — 0 of 31px actually visible, not the "fine" a
## boundary-touching Rect2.intersects() check wrongly reported). The fix is to
## DEFER the reveal one layout pass — call_deferred("_reveal_trace_width_spin"),
## the same idiom _sync_dock_pane_mode uses for the identical class of race — so
## ensure_control_visible runs against the POST-expansion layout instead of the
## pre-expansion one. Verified by mutation: 31/31px visible at BOTH reference
## panes with the deferred call; 0/31 at 500px (31/31 at 400px, the marginal case
## happens to survive there) when called same-frame instead.
##
## The canvas selects the trace BEFORE emitting, and selection_changed drives
## _update_properties, so the row is already populated by the time we get here. The
## re-drive below is the belt for that braces: if some future ordering change left
## the row stale, focusing a control showing another trace's width would be worse
## than a wasted call.
func _on_edit_trace_width_requested(trace_id: String) -> void:
	if _trace_prop_trace_id != trace_id:
		_update_trace_rows()
	if _trace_prop_rows == null or not _trace_prop_rows.visible:
		return

	# Outside in: drawer, then section. The drawer relayouts through
	# _apply_layout_mode(force), which leaves the expanded state alone on a forced
	# re-apply (`if mode_changed:` guards _set_properties_expanded there) — so this
	# order is safe today AND stays safe if that guard is ever relaxed, which the
	# reverse order would not.
	if _layout_mode == _PanelLayoutScript.MODE_NARROW and not _drawer_open:
		_on_drawer_toggled()
	if not _properties_expanded:
		_set_properties_expanded(true)

	if _trace_prop_width_spin == null:
		return
	# F3 ROUND 2 (cold review 2026-08-01): the scroll-reveal + focus is
	# DEFERRED one layout pass, same idiom _sync_dock_pane_mode uses
	# (call_deferred, see _build_ui's comment on it) for exactly the same
	# reason — a same-frame call races the drawer/section expansion just
	# triggered above. MEASURED root cause: ensure_control_visible() called
	# in the SAME frame as _set_properties_expanded(true)/_on_drawer_toggled()
	# clamps its scroll target against the PRE-expansion content height, short
	# by exactly one row (measured: pane 500, spin_y lands [468,499] against
	# viewport [50,468] — ZERO of 31px visible, the control flush against and
	# entirely BELOW the fold). One deferred call, after the just-triggered
	# expansion's own sort_children pass has run, targets the POST-expansion
	# layout and lands fully on-screen (measured: spin_y [437,468] — 31/31px
	# visible). See _reveal_trace_width_spin.
	call_deferred("_reveal_trace_width_spin")


## The deferred second half of _on_edit_trace_width_requested (F3 round 2):
## scrolls the SpinBox into view and focuses its LineEdit, one layout pass
## after the drawer/section enclosures were opened. Re-checks visibility
## itself rather than trusting the caller's frame — is_visible_in_tree can
## still be false if the drawer/section reveal was itself refused for some
## reason between the two calls (e.g. the panel was torn down mid-flight).
func _reveal_trace_width_spin() -> void:
	if _trace_prop_width_spin == null or not is_instance_valid(_trace_prop_width_spin):
		return
	var line_edit := _trace_prop_width_spin.get_line_edit()
	# grab_focus() on a control outside the tree is a hard engine error, and the
	# panel is legitimately un-mounted in the headless suites that drive this hook.
	# is_visible_in_tree (not .visible) because a focused control inside a hidden
	# ancestor is exactly the dead end above.
	if line_edit == null or not line_edit.is_inside_tree():
		return
	if not line_edit.is_visible_in_tree():
		return
	# Scroll the fourth enclosure open BEFORE focusing — a control can be
	# is_visible_in_tree() (not clipped by a hidden ancestor's .visible flag)
	# while still sitting outside the scroll viewport's current scroll offset.
	# _sidebar_scroll.follow_focus is also set true, but MEASURED as
	# insufficient alone for this programmatic path — this explicit call is
	# required alongside it (see _sidebar_scroll's own doc comment).
	if _sidebar_scroll != null:
		_sidebar_scroll.ensure_control_visible(_trace_prop_width_spin)
	line_edit.grab_focus()
	line_edit.select_all()


## Re-width the selected trace. ONE journalled, undoable step; the MODEL owns
## every rule that could refuse it (pcb_data.set_trace_width → pcb_trace.
## width_error) and its refusal string is what the user is shown, after which the
## box is re-read from the model — the board is the truth, the control is a view
## of it, the same contract the zone re-property rows keep.
##
## NO-OP EDITS MUST NOT REACH save_to_history (cold-review F3, the guard the zone
## handlers carry): SpinBox emits value_changed for a re-typed identical value,
## and set_trace_width returns "" for "no change needed" exactly as it does for a
## real write — so an unguarded commit would push a dead "Set trace width" step
## and the user's next Ctrl+Z would appear to do nothing.
func _on_trace_prop_width_changed(value: float) -> void:
	if _trace_prop_trace_id.is_empty() or _data == null:
		return
	var trace_id := _trace_prop_trace_id
	var trace = _data.get_trace(trace_id)
	if trace == null:
		return
	if is_equal_approx(float(trace.width), value):
		return
	var refusal: String = _data.set_trace_width(trace_id, value)
	if not refusal.is_empty():
		_show_transient_status(refusal)
		_update_properties()
		return
	_data.save_to_history("Set trace width")
	if _canvas != null:
		_canvas.queue_redraw()
	_update_properties()


## Populate the re-property net picker from the board's declared nets, selecting
## the pour's current one.
##
## Entry 0 is the same "Net…" placeholder carrying "" the arming picker uses, and
## it is here for the same reason: "this pour names no declared net" is a REAL
## state a loaded board can be in (a net deleted out from under it), and a picker
## that silently displayed some other net instead would be lying about the board.
## Choosing it is not a silent no-op either — set_zone_net refuses an empty net on
## a pour, visibly, which is exactly the message the user needs.
func _rebuild_zone_prop_net_option(current_net: String) -> void:
	if _zone_prop_net_option == null:
		return
	_zone_prop_net_option.clear()
	_zone_prop_net_option.add_item("Net…")
	_zone_prop_net_option.set_item_metadata(0, "")
	var names: Array = _data.get_net_names()
	names.sort()
	var selected := 0
	for net_name in names:
		var idx := _zone_prop_net_option.item_count
		_zone_prop_net_option.add_item(str(net_name))
		_zone_prop_net_option.set_item_metadata(idx, str(net_name))
		if str(net_name) == current_net:
			selected = idx
	_zone_prop_net_option.select(selected)


## Populate the re-property layer picker from the declared copper stack, selecting
## the zone's current layer.
##
## Re-derive every copper-layer picker from the board's declared stack (epoch
## GA-1). One handler on structure_changed rather than three ad-hoc calls, so a
## stack edit — MCP tool, dialog, or undo/redo — cannot refresh some pickers
## and strand others. The zone-properties picker rebuilds only while its pane
## is bound to a zone; _show_zone_properties owns that path.
func _rebuild_copper_layer_pickers() -> void:
	_rebuild_layer_option()
	_rebuild_zone_layer_option()


## NO placeholder entry, unlike the arming picker: "follow the view filter" is a
## meaningful answer for a zone about to be DRAWN and a meaningless one for a zone
## that already exists on a layer. A board that declares no copper layers gets a
## single disabled entry saying so, and the control goes disabled — the visible
## half of the fail-closed refusal set_zone_layer makes in the model.
func _rebuild_zone_prop_layer_option(current_layer: String) -> void:
	if _zone_prop_layer_option == null:
		return
	_zone_prop_layer_option.clear()
	var choices: Array = _declared_copper_layer_choices()
	if choices.is_empty():
		_zone_prop_layer_option.add_item("(board declares no layers)")
		_zone_prop_layer_option.set_item_metadata(0, "")
		_zone_prop_layer_option.select(0)
		_zone_prop_layer_option.disabled = true
		return
	_zone_prop_layer_option.disabled = false
	var canon_current := PcbLayerStack.kicad_to_canon(current_layer) if not current_layer.is_empty() else ""
	var selected := -1
	for choice in choices:
		var idx := _zone_prop_layer_option.item_count
		_zone_prop_layer_option.add_item(str(choice["label"]))
		_zone_prop_layer_option.set_item_metadata(idx, str(choice["canon"]))
		if str(choice["canon"]) == canon_current:
			selected = idx
	if selected < 0:
		# The zone sits on a layer this board does not declare (an off-contract
		# board, or one whose stack changed under it). Show the truth rather than
		# silently pointing at some other layer the zone is not on.
		_zone_prop_layer_option.add_item("%s (not declared)" % current_layer)
		_zone_prop_layer_option.set_item_metadata(_zone_prop_layer_option.item_count - 1, "")
		selected = _zone_prop_layer_option.item_count - 1
	_zone_prop_layer_option.select(selected)


## Re-property the selected pour's net. ONE journalled, undoable step; the MODEL
## owns every rule that could refuse it (undeclared net, keepout, off-stack layer
## — see pcb_data.set_zone_net), and its refusal string is what the user is shown.
## A refusal re-reads the model into the picker rather than leaving the chosen
## entry standing: the board is the truth, the dropdown is a view of it — the same
## contract _commit_member_offset keeps with the offset fields.
func _on_zone_prop_net_selected(index: int) -> void:
	if _zone_prop_zone_id.is_empty() or _data == null or _zone_prop_net_option == null:
		return
	var meta: Variant = _zone_prop_net_option.get_item_metadata(index)
	var chosen := str(meta) if meta != null else ""
	var zone_id := _zone_prop_zone_id
	# NO-OP PICKS MUST NOT REACH save_to_history (cold-review F3). Godot's
	# OptionButton emits item_selected for EVERY popup pick, including the entry
	# already showing, and set_zone_net returns "" for "no change needed" exactly
	# as it does for a real write — so opening the dropdown and re-picking the
	# current net would push a dead "Set zone net" step. The user's next Ctrl+Z
	# would then appear to do nothing, and the one after it would eat a real edit.
	if str(_data.get_zone(zone_id).get("net", "")) == chosen:
		return
	var refusal: String = _data.set_zone_net(zone_id, chosen)
	if not refusal.is_empty():
		_show_transient_status(refusal)
		_update_properties()
		return
	_data.save_to_history("Set zone net")
	if _canvas != null:
		_canvas.queue_redraw()
	_update_properties()


## Re-property the selected zone's copper layer. Same contract as the net handler
## above, and the same one-step-per-change history shape.
func _on_zone_prop_layer_selected(index: int) -> void:
	if _zone_prop_zone_id.is_empty() or _data == null or _zone_prop_layer_option == null:
		return
	var meta: Variant = _zone_prop_layer_option.get_item_metadata(index)
	var chosen := str(meta) if meta != null else ""
	var zone_id := _zone_prop_zone_id
	# Same no-op guard as the net handler above (cold-review F3). The comparison
	# is RAW stored value vs the picker's canonical id — deliberately, so a zone
	# storing a KiCad name never equals the canonical pick and "F.Cu" -> "top"
	# stays a real normalising write, not a no-op.
	var current := str(_data.get_zone(zone_id).get("layer", ""))
	if not chosen.is_empty() and current == chosen:
		return
	var refusal: String = _data.set_zone_layer(zone_id, chosen)
	if not refusal.is_empty():
		_show_transient_status(refusal)
		_update_properties()
		return
	_data.save_to_history("Set zone layer")
	if _canvas != null:
		_canvas.queue_redraw()
	_update_properties()


## The board's declared COPPER layers as [{label, canon}], KiCad label + canonical
## metadata. ONE list, two pickers: the zone ARMING picker and the zone
## RE-PROPERTY picker both build from it, so the layers you can draw on and the
## layers you can move a zone to can never drift apart. Lifted verbatim out of
## _rebuild_zone_layer_option, whose reasoning (copper only, KiCad presentation,
## canonical comparison) is stated there.
func _declared_copper_layer_choices() -> Array:
	var choices: Array = []
	var declared: Array = _data.layers if _data != null else ["top", "bottom"]
	for layer in declared:
		var raw := str(layer)
		if not PcbLayerStack.is_copper(raw):
			continue
		var canon := PcbLayerStack.kicad_to_canon(raw)
		var label := PcbLayerStack.canon_to_kicad(canon)
		if label.is_empty():
			label = raw
		choices.append({"label": label, "canon": canon})
	return choices


## WHICH component the Properties section describes.
##
## Selecting one component still means that component — unchanged, and the ONLY
## case a board with no groups can reach. A GROUP selection (A4) resolves to the
## member the user last clicked (the canvas' focused_component, Illustrator's key
## object), falling back to the anchor. A multi-select of LOOSE parts still
## resolves to null and still blanks the section, exactly as before.
func _property_focus_component():
	var sel: Array = _canvas.get_selected_components()
	if sel.size() == 1:
		return _data.get_component(sel[0])
	var group_id := _selected_group_id()
	if group_id.is_empty():
		return null
	var focused: String = str(_canvas.focused_component)
	if focused.is_empty() or not sel.has(focused):
		focused = str(_data.group_anchor_id(group_id))
	return _data.get_component(focused)


## The group id when the selection is EXACTLY one whole group, else "".
##
## "Exactly": every selected component carries the same non-empty group id AND the
## selection holds every member of it. Anything looser — two groups, a group plus
## a loose part — is a multi-selection and gets the blank section, because there is
## no single part whose offsets could be shown.
func _selected_group_id() -> String:
	var sel: Array = _canvas.get_selected_components()
	if sel.size() < 2:
		return ""
	var group_id: String = str(_data.component_group_id(sel[0]))
	if group_id.is_empty():
		return ""
	for comp_id in sel:
		if str(_data.component_group_id(comp_id)) != group_id:
			return ""
	if _data.group_member_ids(group_id).size() != sel.size():
		return ""
	return group_id


func _hide_group_rows() -> void:
	_offset_component_id = ""
	if _group_row != null:
		_group_row.visible = false
	if _offset_row != null:
		_offset_row.visible = false


## Drive the group read-out and the offset editor for the focused component.
##
## The offset fields are NOT overwritten while they have focus — otherwise a
## selection-changed relay firing mid-typing would rewrite the digits under the
## user's cursor. They go read-only (not hidden) when the group is locked, so the
## values stay legible while the whole-unit lock refuses edits.
func _update_group_rows(comp) -> void:
	if _group_row == null or _offset_row == null:
		return
	var group_id: String = str(comp.group_id())
	if group_id.is_empty():
		_hide_group_rows()
		return

	var members: Array = _data.group_member_ids(group_id)
	var locked: bool = _data.is_group_locked(group_id)
	_group_row.visible = true
	_group_value_label.text = "%d parts, anchor %s%s" % [
		members.size(), _data.group_anchor_id(group_id), " (locked)" if locked else ""]

	if _data.is_group_anchor(str(comp.id)):
		# The anchor IS the origin — it has no offset to edit. Moving it means
		# moving the whole group, which is what a drag does.
		_offset_component_id = ""
		_offset_row.visible = false
		return

	_offset_component_id = str(comp.id)
	_offset_row.visible = true
	var offset: Vector2 = _data.member_offset(_offset_component_id)
	if not _offset_x_edit.has_focus():
		_offset_x_edit.text = "%.3f" % offset.x
	if not _offset_y_edit.has_focus():
		_offset_y_edit.text = "%.3f" % offset.y
	_offset_x_edit.editable = not locked
	_offset_y_edit.editable = not locked


## Apply the typed offset to exactly the focused member.
##
## ONE history step, and the model owns every rule that could refuse it (unknown
## component, ungrouped, anchor, whole-unit lock, no actual change — see
## pcb_data.set_member_offset). A refusal or a malformed number re-reads the model
## into the fields rather than leaving the typed text standing: the board is the
## truth, the field is a view of it.
func _commit_member_offset() -> void:
	if _offset_component_id.is_empty() or _data == null:
		return
	var raw_x := _offset_x_edit.text.strip_edges()
	var raw_y := _offset_y_edit.text.strip_edges()
	if not raw_x.is_valid_float() or not raw_y.is_valid_float():
		_revert_offset_fields()
		return
	var component_id := _offset_component_id
	if not _data.set_member_offset(component_id, Vector2(raw_x.to_float(), raw_y.to_float())):
		_revert_offset_fields()
		return
	_data.save_to_history("Offset %s" % component_id)
	if _canvas != null:
		_canvas.queue_redraw()
	_update_properties()


## Snap both offset fields back to the model's value after a REFUSED commit.
## _update_group_rows deliberately skips a field that has keyboard focus (so it
## never clobbers live typing), but on the Enter path focus never leaves — the
## refused text would stand while the model holds the old value (cold-review A4
## note 3). After a refusal the typed text is exactly what must not stand, so
## write the fields unconditionally.
func _revert_offset_fields() -> void:
	_update_properties()
	if _offset_component_id.is_empty() or _data == null or _offset_row == null:
		return
	if not _offset_row.visible:
		return
	var offset: Vector2 = _data.member_offset(_offset_component_id)
	_offset_x_edit.text = "%.3f" % offset.x
	_offset_y_edit.text = "%.3f" % offset.y


## Pin Info section (WC-1, contract §3): Component.Pin + the display rule
## (geometry pin_name > net > "(unconnected)", via host.pin_display_name so the
## UI and MCP parity tool compute the SAME string) + net_members. Starts hidden.
func _build_pin_info_section() -> VBoxContainer:
	_pin_info_section = VBoxContainer.new()
	_pin_info_section.name = "PinInfoSection"
	_pin_info_section.visible = false

	var header := Label.new()
	header.name = "PinInfoHeader"
	header.text = "Pin Info"
	_pin_info_section.add_child(header)

	_pin_info_ref_label = Label.new()
	_pin_info_ref_label.name = "PinInfoRef"
	_pin_info_section.add_child(_pin_info_ref_label)

	_pin_info_value_label = Label.new()
	_pin_info_value_label.name = "PinInfoValue"
	_pin_info_section.add_child(_pin_info_value_label)

	_pin_info_members_label = Label.new()
	_pin_info_members_label.name = "PinInfoMembers"
	_pin_info_members_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_pin_info_section.add_child(_pin_info_members_label)

	return _pin_info_section


## Canvas pin_selected relay: {} clears + hides; a populated pin_info Dictionary
## shows "Component.Pin" + the display rule + net members.
func _on_pin_selected(info: Dictionary) -> void:
	if _pin_info_section == null:
		return
	if info.is_empty():
		_pin_info_section.visible = false
		return
	_pin_info_section.visible = true
	_pin_info_ref_label.text = str(info.get("ref", ""))
	var display := ""
	if _annotation_host != null and _annotation_host.has_method("pin_display_name"):
		display = _annotation_host.pin_display_name(info)
	_pin_info_value_label.text = display
	var members: Array = info.get("net_members", [])
	_pin_info_members_label.text = "Net members: %s" % (", ".join(members) if not members.is_empty() else "(none)")


## Toolbar toggle handler — a TRUE toggle, mirroring the canvas's Shift+P
## behaviour (contract §3): pressed arms INSPECT_PIN, un-pressed exits to Select.
func _on_inspect_pin_button_pressed() -> void:
	if _canvas == null or _inspect_pin_button == null:
		return
	if _inspect_pin_button.button_pressed:
		if _active_route_flow_tool != null:
			_deactivate_route_flow_tool()
		_canvas.set_tool_mode(_PcbCanvasScript.ToolMode.INSPECT_PIN)
	else:
		_canvas.set_tool_mode(_PcbCanvasScript.ToolMode.SELECT)
	_sync_tool_buttons(_canvas.tool_mode)


# ── Route-flow toolbar cluster (WC-3, contract §5) ────────────────────────────

## Locate the platform AnnotationOverlay mounted by Editor.gd — a duck-typed,
## by-name lookup under the canvas (get_annotation_overlay_parent's own
## target), mirroring Editor.gd's own `surface.find_child("PlatformAnnotation
## Overlay", true, false)` (Editor.gd:852). Returns null when the overlay
## hasn't been mounted yet (panel not hosted by the platform — e.g. some
## headless test fixtures that never build one).
func _find_annotation_overlay() -> Control:
	if _canvas == null or not is_instance_valid(_canvas):
		return null
	var found := _canvas.find_child(_OVERLAY_NODE_NAME, true, false)
	if found is Control:
		# Bind ONCE per overlay instance so mutual exclusion also covers other
		# surfaces (e.g. the dock's own AnnotationToolbar) driving the same
		# overlay — contract: "Tool activation is mutually exclusive."
		if _overlay_tool_signal_bound != found:
			var cb := Callable(self, "_on_overlay_active_tool_changed")
			if found.has_signal("active_tool_changed") and not found.active_tool_changed.is_connected(cb):
				found.active_tool_changed.connect(cb)
			_overlay_tool_signal_bound = found
		return found
	return null


func _on_single_trace_button_pressed() -> void:
	var btn: Button = _route_flow_buttons.get("single_trace", null)
	if btn == null:
		return
	if btn.button_pressed:
		_activate_route_flow_tool("single_trace")
	else:
		_deactivate_route_flow_tool()


## Edit-hint toggle handler (C4) — same pattern as _on_single_trace_button_pressed.
func _on_edit_hint_button_pressed() -> void:
	var btn: Button = _route_flow_buttons.get("edit_hint", null)
	if btn == null:
		return
	if btn.button_pressed:
		_activate_route_flow_tool("edit_hint")
	else:
		_deactivate_route_flow_tool()


## Add-via toggle handler (U4) — same pattern as _on_edit_hint_button_pressed.
func _on_add_via_button_pressed() -> void:
	var btn: Button = _route_flow_buttons.get("add_via", null)
	if btn == null:
		return
	if btn.button_pressed:
		_activate_route_flow_tool("add_via")
	else:
		_deactivate_route_flow_tool()


## Propose button handler (C5, docket 019f6c465fd8, deliverable 1): an
## explicit human ACT — this is the ONLY thing in this plugin that invokes the
## router besides the equivalent MCP tool call (deliverable 4: nothing else —
## not panel mount, not tool activation, not an annotation-change handler —
## ever reaches _apply_route_hints/route_board; see
## test_pcb_explicit_propose.gd scenario A). Calls through handle_tool(),
## PCBPanel's own plugin-side MCP entry point, with commit=false: the EXACT
## same code path minerva_pcb_apply_route_hints (commit absent/false) takes —
## one implementation, two entry points. Async (awaits the router bridge, same
## as _on_export_yaml_pressed's await ipc.await_reply pattern) so the UI thread
## is never blocked; the button stays interactive (no manual disable — a
## second click before the first resolves just re-runs propose, which is
## idempotent by construction: it only ever reads open hints and writes fresh
## proposal annotations).
func _on_propose_button_pressed() -> void:
	# Epoch UX3 station 5d: the button respects a HINT SELECTION — selected
	# open route hints scope the run (hint_ids), nothing selected keeps the
	# all-open behavior byte-identical. The scope is narrated so a user who
	# forgot a selection is told why only one net rerouted.
	var scoped: Array = _selected_open_hint_ids()
	var args: Dictionary = {"commit": false}
	if not scoped.is_empty():
		args["hint_ids"] = scoped
		_set_status("Proposing routes for %d selected hint%s…"
			% [scoped.size(), "" if scoped.size() == 1 else "s"])
	else:
		_set_status("Proposing routes…")
	var result: Dictionary = await handle_tool("minerva_pcb_apply_route_hints", args)

	if not bool(result.get("success", false)):
		if str(result.get("error", "")) == "pcb_backend_stopped":
			# Backend-stopped affordance (bug 019f6c1e0399): names the cause
			# AND the recovery action, exact wording is this round's call —
			# the structured machine shape (error/detail/recovery_hint) is
			# what panel_tools.gd's _router_unavailable already returns.
			_set_status("Routing needs the pcb backend — it's stopped. Start it from the Plugin Manager, then retry.")
		else:
			_set_status("Propose failed: %s" % str(result.get("note", result.get("error", "unknown error"))))
		return

	var n := int(result.get("proposed", 0))
	if n == 0:
		_set_status("Nothing to route — no open route hints.")
	else:
		_set_status("%d proposal%s%s" % [n, "" if n == 1 else "s", _drc_status_suffix(result)])


## The canvas's steered-retry completion (Epoch UX3 station 5): run the SAME
## reroute tool the agent calls (minerva_pcb_workspace_reroute_route) with the
## options the gesture/menu chose — {} plain retry, {"corridor": [[x,y],…]}
## corridor-steered, {"clear_constraint": true} clear-then-unguided — and
## narrate the outcome on the status line with the tool's own named errors.
## One implementation for both hands; the menu can never gain a power the
## tool lacks, or vice versa.
func _on_candidate_retry_requested(candidate_id: String, options: Dictionary) -> void:
	var args: Dictionary = {"candidate_id": candidate_id}
	if options.get("corridor", null) is Array:
		args["corridor"] = options.get("corridor")
	if bool(options.get("clear_constraint", false)):
		args["clear_constraint"] = true
	var result: Dictionary = await handle_tool("minerva_pcb_workspace_reroute_route", args)
	if _canvas != null:
		_canvas.queue_redraw()
	if not bool(result.get("success", false)):
		if str(result.get("error", "")) == "pcb_backend_stopped":
			_set_status("Retry needs the pcb backend — it's stopped. Start it from the Plugin Manager, then retry.")
		else:
			_set_status("Retry of %s refused (%s): %s" % [candidate_id,
				str(result.get("error", "unknown")),
				str(result.get("note", result.get("message", "")))])
		return
	# The reply's `candidates` array carries the fresh generation's records
	# (reroute names ONE fresh generation; `rerouted_candidate_id` is the
	# PRIOR). A successful call that landed nothing (task held, router found
	# no route) is narrated too — silence here would repeat the defect the
	# holds surface exists to close.
	var landed: Array = result.get("candidates", []) if result.get("candidates", []) is Array else []
	var how := "corridor-steered retry" if args.has("corridor") \
		else ("steering cleared, rerouted unguided" if args.has("clear_constraint") else "retry")
	if landed.is_empty():
		# NOT reply.note (cold review F5): the ingest layer's default note is
		# always present and reads "candidates landed…" even when zero did —
		# name the actual empty outcome, and the hold if one caused it.
		var holds: Array = result.get("holds", []) if result.get("holds", []) is Array else []
		var why := "the router landed no candidate for this task; the prior stands"
		if not holds.is_empty():
			why = "its task is HELD (%s) — release the hold first" \
				% str((holds[0] as Dictionary).get("reason", "held"))
		_set_status("%s of %s ran but landed no candidate — %s." % [how.capitalize(), candidate_id, why])
		return
	var new_id := str((landed[0] as Dictionary).get("candidate_id", ""))
	_set_status("%s: %s → %s. Review the new ghost, then Commit or Reject."
		% [how.capitalize(), candidate_id, new_id])


# ── station 7: commit through the gate, with the acknowledge dialog ───────────

## The refused-commit state awaiting the human's acknowledgment:
## {"candidate_ids": Array, "blocked": Array} — blocked entries are the tool's
## own records (single: blocking_findings; batch: blocked_members flattened).
## Empty when no acknowledgment is pending. Kept as data (not dialog-local)
## so headless tests can drive the confirm path without a mounted popup.
var _pending_ack_commit: Dictionary = {}
var _placement_dialog: ConfirmationDialog = null


## The canvas's commit doorway (station 7): run the SAME gated tool the agent
## calls, single or batch by arity — no new commit semantics, UI over the
## shipped verb only. A placement_blocker_unacknowledged refusal raises the
## acknowledge dialog; every other outcome narrates on the status line.
func _on_candidate_commit_requested(candidate_ids: Array) -> void:
	if candidate_ids.is_empty():
		return
	var args: Dictionary = {}
	if candidate_ids.size() == 1:
		args["candidate_id"] = str(candidate_ids[0])
	else:
		args["candidate_ids"] = candidate_ids
	var result: Dictionary = await handle_tool("minerva_pcb_workspace_commit", args)
	if _canvas != null:
		_canvas.queue_redraw()
	if bool(result.get("success", false)):
		_narrate_commit_success(candidate_ids, result)
		return
	if str(result.get("error", "")) == "placement_blocker_unacknowledged":
		# Normalise the two reply shapes into one dialog model: single carries
		# blocking_findings, batch carries blocked_members.
		var blocked: Array = []
		if result.get("blocked_members", null) is Array:
			blocked = result.get("blocked_members")
		elif result.get("blocking_findings", null) is Array:
			blocked = [{"candidate_id": str(candidate_ids[0]),
				"blocking_findings": result.get("blocking_findings")}]
		_pending_ack_commit = {"candidate_ids": candidate_ids, "blocked": blocked}
		_show_placement_ack_dialog()
		return
	_set_status("Commit refused (%s): %s" % [str(result.get("error", "unknown")),
		str(result.get("note", ""))])


## Confirm path: re-run the SAME call with acknowledge_placement:true — the
## reply's acknowledged_placement_findings then records the consent
## identically to the MCP path. Public-ish (no popup dependency) so the
## dialog's confirmed signal and a headless test drive the same seam.
func _confirm_placement_ack() -> void:
	if _pending_ack_commit.is_empty():
		return
	var ids: Array = _pending_ack_commit.get("candidate_ids", [])
	_pending_ack_commit = {}
	var args: Dictionary = {"acknowledge_placement": true}
	if ids.size() == 1:
		args["candidate_id"] = str(ids[0])
	else:
		args["candidate_ids"] = ids
	var result: Dictionary = await handle_tool("minerva_pcb_workspace_commit", args)
	if _canvas != null:
		_canvas.queue_redraw()
	if bool(result.get("success", false)):
		var acked: Array = result.get("acknowledged_placement_findings", []) \
			if result.get("acknowledged_placement_findings", []) is Array else []
		_narrate_commit_success(ids, result,
			"  •  %d placement finding(s) acknowledged" % acked.size() if not acked.is_empty() else "")
		return
	_set_status("Commit refused even with acknowledgment (%s): %s"
		% [str(result.get("error", "unknown")), str(result.get("note", ""))])


func _cancel_placement_ack() -> void:
	if _pending_ack_commit.is_empty():
		return
	var ids: Array = _pending_ack_commit.get("candidate_ids", [])
	_pending_ack_commit = {}
	_set_status("Commit cancelled — %d candidate(s) untouched; resolve the placement findings or acknowledge them to proceed."
		% ids.size())


## One sentence per outcome, shared by the direct and acknowledged paths.
func _narrate_commit_success(ids: Array, result: Dictionary, suffix: String = "") -> void:
	if ids.size() == 1:
		_set_status("Committed %s as %d trace(s) and %d via(s) — one undo step reverts the copper AND the candidate.%s"
			% [str(ids[0]), (result.get("trace_ids", []) as Array).size(),
				(result.get("via_ids", []) as Array).size(), suffix])
		return
	_set_status("Committed %d candidates as ONE undo step — Ctrl+Z reverts every member's copper and disposition.%s"
		% [ids.size(), suffix])


## The dialog itself: built lazily, listing each blocked member's findings —
## components, class and basis — with Acknowledge & Commit / Cancel. Skipped
## (state kept) when the panel is not in a tree; the pending state is the
## contract, the popup is its presentation.
func _show_placement_ack_dialog() -> void:
	var blocked: Array = _pending_ack_commit.get("blocked", [])
	var lines: Array = []
	for member in blocked:
		if not (member is Dictionary):
			continue
		var mcid := str((member as Dictionary).get("candidate_id", ""))
		for f in (member as Dictionary).get("blocking_findings", []):
			if not (f is Dictionary):
				continue
			var fd: Dictionary = f
			lines.append("• %s: %s — components %s%s" % [
				mcid, str(fd.get("class", fd.get("type", "finding"))),
				", ".join(_to_str_array(fd.get("components", []))),
				("" if str(fd.get("basis", "")).is_empty() else " (%s)" % str(fd.get("basis", "")))])
	var body := "Committing lays real copper against placement findings that are still open:\n\n%s\n\nAcknowledge them and commit anyway? The acknowledgment is recorded on the reply, exactly as the agent's acknowledge_placement flag would be." \
		% "\n".join(lines)
	_set_status("Commit needs placement acknowledgment — %d finding group(s); see dialog." % blocked.size())
	if not is_inside_tree():
		return
	if _placement_dialog == null:
		_placement_dialog = ConfirmationDialog.new()
		_placement_dialog.name = "PlacementAckDialog"
		_placement_dialog.ok_button_text = "Acknowledge & Commit"
		_placement_dialog.confirmed.connect(_confirm_placement_ack)
		_placement_dialog.canceled.connect(_cancel_placement_ack)
		add_child(_placement_dialog)
	_placement_dialog.dialog_text = body
	_placement_dialog.title = "Placement findings block this commit"
	_placement_dialog.popup_centered()


static func _to_str_array(raw) -> Array:
	var out: Array = []
	if raw is Array:
		for v in raw:
			out.append(str(v))
	return out


## The Check button's handler (Epoch UX3 station 3): run the set-scoped draft
## check over every live candidate and put the per-candidate verdict tally on
## the status line. check_draft owns the whole guarded round-trip (begin_check
## snapshot → worker → apply_check_result with its token/generation/revision
## guards); this handler only narrates the outcome. The validation channels
## (dash/marker) re-render on the same redraw.
func _on_check_button_pressed() -> void:
	if _routing_workspace == null:
		return
	var live: Array = _routing_workspace.live_candidate_ids()
	if live.is_empty():
		_set_status("Nothing to check — no live route proposals. Propose first.")
		return
	_set_status("Checking %d proposal%s…" % [live.size(), "" if live.size() == 1 else "s"])
	var result: Dictionary = await check_draft()
	if _canvas != null:
		_canvas.queue_redraw()
	if result.is_empty():
		# check_draft's contract: an empty dict means the worker hop could not
		# run and every candidate was reverted to its prior verdict — say so
		# rather than leave the "Checking…" line lying.
		_set_status("Draft check could not run (worker unavailable) — proposals keep their prior verdicts.")
		return
	var findings: int = (result.get("findings", []) as Array).size() \
		if result.get("findings", []) is Array else 0
	var tally := _ghost_status_summary()
	var findings_txt := "" if findings == 0 else "  •  %d finding%s — select a ghost for details" \
		% [findings, "" if findings == 1 else "s"]
	_set_status("Checked: %s%s" % [tally, findings_txt])


## One phrase for "what state are the ghosts in": "3 ghosts: 2 clean, 1 stale".
## Counts LIVE candidates only (terminal ones are history/board copper) by
## validation, naming only the states that are present, in a fixed order so
## the phrase is stable enough to assert on. "" when there are no live ghosts
## — callers append it conditionally.
func _ghost_status_summary() -> String:
	if _routing_workspace == null:
		return ""
	var live: Array = _routing_workspace.live_candidate_ids()
	if live.is_empty():
		return ""
	var counts: Dictionary = {}
	for cid in live:
		var c = _routing_workspace.get_candidate(str(cid))
		if c == null:
			continue
		var v := str(c.validation)
		counts[v] = int(counts.get(v, 0)) + 1
	var parts: Array = []
	for state in ["clean", "violating", "error", "stale", "checking", "unchecked"]:
		if counts.has(state):
			parts.append("%d %s" % [int(counts[state]), state])
	return "%d ghost%s: %s" % [live.size(), "" if live.size() == 1 else "s", ", ".join(parts)]


## Station 10a — the LLM's pointing finger: select ONE entity for the human
## through the SAME canvas choke points a click uses (clear + add + the
## candidate active-sync those choke points already perform), then announce
## it on the status line so the human's eye is drawn. kinds: component /
## trace / via / zone / cutout / candidate / annotation.
func point_at_entity(kind: String, id: String) -> Dictionary:
	if _canvas == null:
		return {"ok": false, "error": "no_canvas", "message": "pointing needs a live canvas"}
	if kind == "annotation":
		if _annotation_host == null or (_annotation_host.get_by_id(id) as Dictionary).is_empty():
			return {"ok": false, "error": "not_found", "message": "no annotation '%s'" % id}
		_canvas._clear_selection_all()
		_annotation_host.set_selected_annotation_ids(PackedStringArray([id]), id)
		_canvas.queue_redraw()
		_show_transient_status("Assistant points at annotation %s." % id)
		return {"ok": true}
	var canvas_kind := ""
	var exists := false
	match kind:
		"component":
			canvas_kind = _canvas.KIND_COMPONENT
			exists = _data != null and _data.get_component(id) != null
		"trace":
			canvas_kind = _canvas.KIND_TRACE
			exists = _data != null and _data.traces.has(id)
		"via":
			canvas_kind = _canvas.KIND_VIA
			if _data != null:
				for v in _data.vias:
					if v is Dictionary and str((v as Dictionary).get("id", "")) == id:
						exists = true
		"zone":
			canvas_kind = _canvas.KIND_ZONE
			exists = _data != null and not (_data.get_zone(id) as Dictionary).is_empty()
		"cutout":
			canvas_kind = _canvas.KIND_CUTOUT
			exists = _data != null and not (_data.get_cutout(id) as Dictionary).is_empty()
		"candidate":
			canvas_kind = _canvas.KIND_CANDIDATE
			exists = _routing_workspace != null and _routing_workspace.get_candidate(id) != null
		"staged":
			# UX4 S4: pointing at a staged draft — id is the CANONICAL payload
			# id, existence = a LIVE entry resolves to it (terminal entries are
			# not drawn, so pointing at one would light nothing).
			canvas_kind = _canvas.KIND_STAGED
			exists = _staged_entities != null \
				and not str(_staged_entities.staged_id_for_entity(id)).is_empty()
		_:
			return {"ok": false, "error": "unknown_kind",
				"message": "kind must be one of: component, trace, via, zone, cutout, candidate, staged, annotation"}
	if not exists:
		return {"ok": false, "error": "not_found", "message": "no %s '%s' on this board" % [kind, id]}
	_canvas._clear_selection_all()
	_canvas._add_to_selection(canvas_kind, id)
	_canvas.selection_changed.emit()
	_canvas.queue_redraw()
	_show_transient_status("Assistant points at %s %s." % [kind, id])
	return {"ok": true}


## HITL-7c: "Set hint width…" reveal — bind the row to THIS hint, load its
## current width (0 = no width_mm key = auto), show, and focus the field.
func _on_edit_hint_width_requested(hint_id: String) -> void:
	if _annotation_host == null or hint_id.is_empty():
		return
	var ann: Dictionary = _annotation_host.get_by_id(hint_id)
	if ann.is_empty():
		_show_transient_status("Hint %s is no longer on the board." % hint_id)
		return
	var kp: Dictionary = _dict_or_empty(ann.get("kind_payload"))
	_hint_width_hint_id = hint_id
	if _hint_width_label != null:
		_hint_width_label.text = "Width (%s)" % hint_id
	if _hint_width_spin != null:
		_hint_width_setting = true
		_hint_width_spin.value = float(kp.get("width_mm", 0.0))
		_hint_width_setting = false
	if _hint_width_row != null:
		_hint_width_row.visible = true
	call_deferred("_reveal_hint_width_spin")


## Deferred focus half — same one-layout-pass rule _reveal_trace_width_spin
## records (a same-frame ensure_control_visible races the reveal above).
func _reveal_hint_width_spin() -> void:
	if _hint_width_spin == null or not is_instance_valid(_hint_width_spin):
		return
	var line_edit := _hint_width_spin.get_line_edit()
	if line_edit == null or not line_edit.is_inside_tree() or not line_edit.is_visible_in_tree():
		return
	if _sidebar_scroll != null:
		_sidebar_scroll.ensure_control_visible(_hint_width_spin)
	line_edit.grab_focus()
	line_edit.select_all()


## Write the bound hint's width. 0 = auto: the key is ERASED (an absent key
## is the net-class default; a stored 0.0 would be an invisible sentinel —
## the D9a-2 rule). One update_annotation revision per change.
func _on_hint_width_changed(value: float) -> void:
	if _hint_width_setting or _hint_width_hint_id.is_empty() or _annotation_host == null:
		return
	var ann: Dictionary = _annotation_host.get_by_id(_hint_width_hint_id)
	if ann.is_empty():
		_show_transient_status("Hint %s is no longer on the board — width not applied." % _hint_width_hint_id)
		_hint_width_hint_id = ""
		if _hint_width_row != null:
			_hint_width_row.visible = false
		return
	var new_ann: Dictionary = ann.duplicate(true)
	var kp: Dictionary = _dict_or_empty(new_ann.get("kind_payload")).duplicate(true)
	if value > 0.0:
		kp["width_mm"] = value
	else:
		kp.erase("width_mm")
	new_ann["kind_payload"] = kp
	if _annotation_host.update_annotation(_hint_width_hint_id, new_ann):
		_show_transient_status("%s width → %s." % [_hint_width_hint_id,
			("%.2fmm" % value) if value > 0.0 else "auto (net class)"])
	else:
		_show_transient_status("Width update refused — %s's route is locked (see its own notice)." % _hint_width_hint_id)


## The Propose button's selection scope (station 5d): the ids of currently
## SELECTED annotations that are OPEN pcb_route_hints — the only annotations a
## propose run consumes. Anything else in the selection (components, closed
## hints, other kinds) contributes nothing, so a mixed selection scopes to
## exactly its routable part. Empty when nothing qualifying is selected.
func _selected_open_hint_ids() -> Array:
	var out: Array = []
	if _annotation_host == null or not _annotation_host.has_method("get_selected_annotation_ids") \
			or not _annotation_host.has_method("get_by_id"):
		return out
	for aid in _annotation_host.get_selected_annotation_ids():
		var ann: Dictionary = _annotation_host.get_by_id(str(aid))
		if ann.is_empty():
			continue
		if str(ann.get("kind", "")) != "pcb_route_hint":
			continue
		if str(ann.get("lifecycle", "open")) != "open":
			continue
		out.append(str(aid))
	return out


## DRC-at-propose (docket 019f6f1492e0) status-label suffix: BOTH scopes,
## concatenated but never blended (docket 019f98b24284 requirement 1/5) — the
## connectivity fragment and the geometric fragment are each self-contained
## (own leading " — ", own label), so a caller can find/assert either
## substring independently and neither can be read as the other's verdict.
## Extracted to a static func (no `self` reads) so the gd test suite can drive
## it with plain result dictionaries — no live PCBPanel/host required.
static func _drc_status_suffix(result: Dictionary) -> String:
	return _connectivity_status_suffix(result) + _completeness_status_suffix(result) \
		+ _geometric_status_suffix(result)


## Connectivity fragment. drc_summary is PROPOSAL-scoped {"scope":
## "connectivity", "clean": bool|null, "violation_count": int, "error"?:
## String, "baseline": {...}} — see pcb_worker.methods._attach_route_drc
## (docket 019f9cc386b6 added the partition; docket 019f9da15929 surfaces the
## `baseline` half here). null `clean` means the DRC engine itself faulted
## (never blocks propose — informs, never blocks); an absent/empty dict means
## the worker didn't run DRC at all (e.g. an older worker), in which case this
## fragment stays exactly as it was before (empty string).
##
## HONEST LABEL (019f958aa6db): this is the CONNECTIVITY/topology checker
## (drc.run_drc — pad centers + trace centerlines), NOT geometric copper DRC. It
## cannot verify a clearance/width/annular ring, so the chip must NOT imply a
## generic "DRC clean". We read scope (default "connectivity") and title-case it
## for the label so a clean connectivity pass reads "Connectivity clean", never
## the misleading bare "DRC clean".
##
## BASELINE (019f9da15929): `violation_count`/`clean` above answer "does
## ACCEPTING THIS introduce a violation?" — they are proposal-scoped, exactly
## like the geometric fragment's candidate-scoped `verdict`, and that part of
## this func is unchanged. `baseline` is the board's own pre-existing state
## (`methods.py` `_attach_route_drc`) and is appended as a parenthetical
## on the SAME chip (not a second " — " scope like the geometric fragment,
## because this is the connectivity scope's own pre-existing state, not a
## different question). See `_baseline_suffix` below for the absence trap.
static func _connectivity_status_suffix(result: Dictionary) -> String:
	var summary: Dictionary = _dict_or_empty(result.get("drc_summary"))
	if summary.is_empty():
		return ""
	var scope := str(summary.get("scope", "connectivity"))
	var label := scope.capitalize() if scope != "" else "Connectivity"
	var clean: Variant = summary.get("clean", null)
	var proposal_text: String
	if clean == null:
		proposal_text = "%s: unavailable" % label
	elif bool(clean):
		proposal_text = "%s clean" % label
	else:
		var count := int(summary.get("violation_count", 0))
		proposal_text = "%s: %d violation%s" % [label, count, "" if count == 1 else "s"]
	return " — %s%s" % [proposal_text, _baseline_suffix(summary)]


## Pre-existing-board-state parenthetical for the connectivity chip above.
## `summary["baseline"]` is {"clean": bool, "violation_count": int,
## "findings": [...]} when determinate, or {"clean": null, "error": str} —
## with NO `violation_count`/`findings` key — when the base run itself could
## not be completed (`methods.py` `_attach_route_drc`, the `base_error` branch).
## An absent/empty `baseline` dict (older
## worker that never emitted the partition) renders nothing, matching the
## fragment's own absent-summary behaviour.
##
## THE TRAP (project hint 019fa0e84932, docket 019f9da15929): `baseline` is
## present on BOTH the determinate and indeterminate top-level branches of
## _attach_route_drc, so merely checking `summary.has("baseline")` protects
## nothing — it is always there. What actually goes absent is ONE LEVEL DOWN:
## an indeterminate baseline carries no `violation_count` key at all, so
## `int(baseline.get("violation_count", 0))` would silently render "0
## pre-existing" for a board whose state could not be determined — a
## confident wrong answer for exactly the board that most needs a hedge. We
## therefore branch on `baseline["clean"] == null` FIRST, before ever reading
## a count — mirroring `methods.py` `_baseline_for_net`, which refuses to
## narrow an indeterminate baseline to an empty list for the same reason.
static func _baseline_suffix(summary: Dictionary) -> String:
	var baseline: Dictionary = _dict_or_empty(summary.get("baseline"))
	if baseline.is_empty():
		return ""
	if baseline.get("clean", null) == null:
		return " (pre-existing: unknown)"
	var count := int(baseline.get("violation_count", 0))
	# "none" rather than "0" so the determinate-empty and indeterminate answers
	# read as one vocabulary — "none" / "unknown" — instead of mixing a numeral
	# with a word. A user skimming "(pre-existing: 0)" beside a sibling chip
	# reading "(pre-existing: unknown)" can parse the word as a count; the two
	# are answers to the same question and should look like it. The count is
	# still a numeral whenever there IS one.
	if count == 0:
		return " (pre-existing: none)"
	return " (pre-existing: %d)" % count


## COMPLETENESS fragment (work item 019fd5fdfcdd, DCR 019fd5fd9084 — the F2
## renderer half): the connectivity chip above answers "does this proposal
## INTRODUCE a violation?"; it structurally cannot say "this net has no copper
## at all" (HITL-4's VCC_5V — the summary read clean while a whole net was
## unrouted). board_health carries the whole-board completeness verdict:
##   complete == true    -> render nothing; the chip stays exactly as it was
##                          (absent-key no-regression, same as every fragment).
##   complete == false   -> " · INCOMPLETE — N net(s) unrouted[, M fragmented]"
##                          from missing_copper (zero-copper nets) and partial
##                          (nets with SOME copper but disconnected pin groups).
##   complete == null    -> " · completeness indeterminate" — the check could
##                          not run; the same fail-closed hedge the geometric
##                          fragment renders for its own indeterminate, never
##                          silently read as complete.
## An absent/empty board_health (older worker, or a non-routing reply) renders
## nothing. Rendered between the connectivity and geometric fragments because
## completeness IS a connectivity-scope statement ("·" joins it to that chip
## rather than opening a new " — " scope), not a copper-geometry one.
static func _completeness_status_suffix(result: Dictionary) -> String:
	var health: Dictionary = _dict_or_empty(result.get("board_health"))
	if health.is_empty() or not health.has("complete"):
		return ""
	var complete: Variant = health.get("complete", null)
	if complete == null:
		return " · completeness indeterminate"
	if bool(complete):
		return ""
	var missing: Array = health.get("missing_copper", []) \
		if health.get("missing_copper", []) is Array else []
	var partial: Array = health.get("partial", []) \
		if health.get("partial", []) is Array else []
	var text := " · INCOMPLETE — %d net%s unrouted" % [
		missing.size(), "" if missing.size() == 1 else "s"]
	if not partial.is_empty():
		text += ", %d fragmented" % partial.size()
	return text


## GEOMETRIC copper fragment (docket 019f98b24284) — the complement that closes
## the gap left by the connectivity fragment above: a proposal routed through
## the CENTRE of a different-net pad reads "Connectivity clean" (centerlines
## never crossed) while the copper itself shorts. drc_geometric_summary is the
## candidate-scoped union from panel_tools._write_records_as_proposals — see
## pcb_worker methods.py _attach_route_geometric_drc / ir_candidates.py
## check_candidates module docstring for the three-way contract this reads:
##
##   verdict == "clean"       -> ok=True,  candidates introduce no violation
##   verdict == "violations"  -> ok=True,  candidates introduce >=1 violation
##   anything else            -> ok=False, the check could not run at all
##
## THE INDETERMINATE TRAP (requirement 2): the union deliberately carries NO
## `clean` key — only a 3-way `verdict` string — because a truthy/absent-key
## check is exactly how "could not verify" silently reads as "verified clean"
## in GDScript. Do not "simplify" this to `if summary.get("clean")`; there is
## no such key, and adding one back reintroduces the bug this surface exists
## to remove. `match` on the literal string is the fail-closed shape: only the
## literal "clean" string renders as clean, and both "indeterminate" and any
## future/unknown verdict fall through to the same "unavailable" branch as a
## faulted connectivity check — never counted as a violation, never as clean.
##
## An absent/empty summary (older worker that never attached
## drc_geometric_summary, or a route call that took the non-canonical path
## where the worker skips the attach entirely — methods.py `_route`) is a
## THIRD state again from "indeterminate": render nothing rather than invent a
## verdict the worker never computed (requirement 2/4).
##
## BASELINE EXCLUSION (requirement 4): the union's "findings"/"verdict" are
## already candidate-scoped by the worker — pre-existing board violations live
## under summary["baseline"] and are never read here, so a dirty fixture board
## (the real fixture carries 12) cannot make a clean proposal look dirty.
static func _geometric_status_suffix(result: Dictionary) -> String:
	var summary: Dictionary = _dict_or_empty(result.get("drc_geometric_summary"))
	if summary.is_empty():
		return ""
	var verdict := str(summary.get("verdict", "indeterminate"))
	match verdict:
		"clean":
			return " — Geometric clean"
		"violations":
			var count := (summary.get("findings", []) as Array).size()
			var who := _offending_nets(result)
			# Name the offender when we can. A batch line that says only "2
			# violations" leaves the user who must REJECT one proposal unable to
			# tell which — and rejecting the right one is the entire decision
			# this surface exists to inform (019f98b24284 requirement 3).
			if who != "":
				return " — Geometric: %d violation%s on %s" % [
					count, "" if count == 1 else "s", who]
			return " — Geometric: %d violation%s" % [count, "" if count == 1 else "s"]
		_:
			# Covers "indeterminate" AND any unrecognized verdict — fail closed,
			# never counted as clean, never counted as a violation (requirement 2).
			#
			# Carry the REASON. "unavailable" on its own is unactionable: the
			# error.kind vocabulary is small, stable and shared with the route
			# reply (parse | compile | unresolved_geometry | unsupported_geometry
			# | route | internal — see ir_candidates.candidate_indeterminate), and
			# it is the difference between "this board has geometry we cannot
			# model yet" and "something faulted". The free-text message is NOT
			# surfaced here: it can be an exception repr, which does not belong
			# in a one-line status label.
			var err: Dictionary = _dict_or_empty(summary.get("error"))
			var kind := str(err.get("kind", ""))
			if kind != "":
				return " — Geometric: unavailable (%s)" % kind
			return " — Geometric: unavailable"


## Comma-joined net names of the proposals whose OWN geometric verdict is
## "violations", for the batch status line. Reads `proposals[].drc_geometric`,
## stamped per proposal by panel_tools._write_records_as_proposals — the union's
## `per_candidate` is keyed `route[<i>]`, which is a wire-level index a human
## has no way to map back to anything on screen; the net name is what the canvas
## and the hint both label.
##
## Returns "" when nothing can be attributed (an older worker that stamped no
## per-proposal verdict, or a union-level indeterminate) so the caller falls back
## to the bare count rather than printing an empty "on ".
static func _offending_nets(result: Dictionary) -> String:
	var nets: Array[String] = []
	for p in (result.get("proposals", []) as Array):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var geo: Dictionary = _dict_or_empty((p as Dictionary).get("drc_geometric"))
		if str(geo.get("verdict", "")) != "violations":
			continue
		var net := str((p as Dictionary).get("net", ""))
		if net != "" and not nets.has(net):
			nets.append(net)
	if nets.is_empty():
		return ""
	# Cap the list: a status label that grows with the batch stops being
	# readable, and past a few names the user is going to open the list anyway.
	if nets.size() > 3:
		return ", ".join(nets.slice(0, 3)) + " +%d more" % (nets.size() - 3)
	return ", ".join(nets)


## New AnnotationAuthorTool instance for a route-flow cluster key. Deliberately
## bypasses kind.author_ui() (see SingleTraceAuthorTool's class doc) — the
## kind's author_ui() stays wired to the generic waypoint tool for the dock's
## own per-kind button.
func _new_route_flow_tool(kind_key: String) -> AnnotationAuthorTool:
	match kind_key:
		"single_trace":
			return _PcbRouteHintKindScript.SingleTraceAuthorTool.new()
		"edit_hint":
			return _PcbRouteHintKindScript.BendHandleEditTool.new()
		"add_via":
			return _PcbRouteHintKindScript.ViaInsertTool.new()
	return null


func _activate_route_flow_tool(kind_key: String) -> void:
	var overlay := _find_annotation_overlay()
	if overlay == null or _annotation_host == null:
		_set_status("Route tool unavailable — annotation overlay not mounted.")
		_untoggle_route_flow_buttons()
		return

	var tool := _new_route_flow_tool(kind_key)
	if tool == null:
		_untoggle_route_flow_buttons()
		return

	# Deactivate any route-flow tool WE previously activated (mutual exclusion
	# within the cluster; future WC-4 bus button shares this path). Done BEFORE
	# the dock clear below so the outgoing tool gets a proper on_deactivate()
	# instead of being silently nulled by that call's overlay null-bounce.
	_teardown_active_route_flow_tool()

	# Cross-surface mutual exclusion, dock half (bug 019fb64fb408, same family
	# as 019fb5e9c8ac): release any dock-armed annotation tool BEFORE this
	# function tracks/activates its own tool below — clearing after would let
	# the overlay's null-bounce reach _on_overlay_active_tool_changed and tear
	# the just-armed tool back down. _active_route_flow_tool is already null
	# by this point (teardown above), so this call's own null-bounce is a
	# harmless no-op against our tracking.
	_clear_dock_active_tool()

	# Cross-surface mutual exclusion (contract §5 / review must_fix): arming a
	# route-flow tool releases the canvas tool surface — Pan/Pin-Inspect drop
	# back to Select and their buttons un-press.
	if _canvas != null and _canvas.tool_mode != _PcbCanvasScript.ToolMode.SELECT:
		_canvas.set_tool_mode(_PcbCanvasScript.ToolMode.SELECT)
		_sync_tool_buttons(_canvas.tool_mode)

	tool.on_activate(_annotation_host)
	if not tool.annotation_ready.is_connected(_on_route_flow_annotation_ready):
		tool.annotation_ready.connect(_on_route_flow_annotation_ready)
	if not tool.cancelled.is_connected(_on_route_flow_cancelled):
		tool.cancelled.connect(_on_route_flow_cancelled)

	# Set tracking BEFORE handing to the overlay: set_active_tool below fires
	# active_tool_changed synchronously, and _on_overlay_active_tool_changed
	# must see a match (no self-reset).
	_active_route_flow_kind = kind_key
	_active_route_flow_tool = tool
	overlay.set_active_tool(tool)

	for k in _route_flow_buttons.keys():
		var b: Button = _route_flow_buttons[k]
		if is_instance_valid(b):
			b.set_pressed_no_signal(k == kind_key)
	_update_route_flow_mode_label(kind_key)


# ── Universal Select (B1u3, item 019fbb9adc) ──────────────────────────────────
#
# This panel offers ONE Select. The board canvas owns the click; the annotation
# half rides along through the PcbAnnotationHost router (see
# pcb_canvas.set_annotation_router). What this section owns is the ARMING: the
# core AnnotationTransformTool is armed PASSIVELY on the shared overlay whenever
# the canvas is in Select mode and no other surface holds the overlay.
#
# "Passively" means the overlay draws the tool and keeps every host wiring but
# stays transparent to the pointer, so the canvas keeps owning clicks — an
# ordinarily-armed tool flips the overlay to MOUSE_FILTER_STOP and Godot's gui
# walk ends there, accepted or not, which is why a tool cannot decline a click.
#
# EVERYTHING IS DUCK-TYPED. A core that cannot arm passively never gets a tool
# armed, the canvas router answers "no" to everything, and this panel behaves
# exactly as it did before this unit — with the dock's own Select still offered,
# because the older AnnotationToolbar ignores the tools_excluded capability too.

## Re-entrancy guard: arming/clearing the overlay emits active_tool_changed
## synchronously, and that handler calls back in here.
var _universal_select_syncing: bool = false


## The passively-armable tool instance, or null when the core cannot supply one.
func _universal_select_tool() -> Object:
	if _annotation_host == null or not _annotation_host.has_method("get_universal_select_tool"):
		return null
	return _annotation_host.get_universal_select_tool()


## Arm or release the universal Select to match the current state. Idempotent,
## and safe to call from any of the three edges that can change the answer:
## the canvas tool mode, the overlay's active tool, and the overlay's arrival.
func _sync_universal_select() -> void:
	if _universal_select_syncing:
		return
	if _annotation_host == null or not _annotation_host.has_method("arm_universal_select"):
		return
	var overlay := _find_annotation_overlay()
	if overlay == null:
		return
	# Armed only when the canvas is resting in Select AND nothing else holds the
	# overlay. A route-flow tool or a dock author tool is a deliberate mode; the
	# universal Select is what the panel falls back to when they let go.
	var ours := _universal_select_tool()
	var foreign := _overlay_active_tool != null and _overlay_active_tool != ours
	# Typed explicitly: _canvas is untyped (duck-typed plugin script), so the
	# tool_mode comparison yields a Variant and inference would refuse.
	var want: bool = _canvas != null \
		and _canvas.tool_mode == _PcbCanvasScript.ToolMode.SELECT \
		and _active_route_flow_tool == null \
		and not foreign
	_universal_select_syncing = true
	_annotation_host.arm_universal_select(overlay, want)
	_universal_select_syncing = false


## The overlay mounts as a child of the canvas after this panel is built; that
## arrival is the third edge _sync_universal_select watches.
func _on_canvas_child_entered(_node: Node) -> void:
	_sync_universal_select()


## Deactivates the cluster's own active tool (if any) and restores Select —
## contract §5: "deactivation restores Select." Does not touch the overlay's
## assignment when some OTHER surface is now driving it (cross-surface case;
## _on_overlay_active_tool_changed already reset our buttons for that).
func _deactivate_route_flow_tool() -> void:
	var overlay := _find_annotation_overlay()
	_teardown_active_route_flow_tool()
	if overlay != null:
		overlay.clear_active_tool()
	_untoggle_route_flow_buttons()
	_update_route_flow_mode_label("")


func _teardown_active_route_flow_tool() -> void:
	if _active_route_flow_tool == null:
		return
	if _active_route_flow_tool.annotation_ready.is_connected(_on_route_flow_annotation_ready):
		_active_route_flow_tool.annotation_ready.disconnect(_on_route_flow_annotation_ready)
	if _active_route_flow_tool.cancelled.is_connected(_on_route_flow_cancelled):
		_active_route_flow_tool.cancelled.disconnect(_on_route_flow_cancelled)
	_active_route_flow_tool.on_deactivate()
	_active_route_flow_tool = null
	_active_route_flow_kind = ""


func _untoggle_route_flow_buttons() -> void:
	for k in _route_flow_buttons.keys():
		var b: Button = _route_flow_buttons[k]
		if is_instance_valid(b) and b.button_pressed:
			b.set_pressed_no_signal(false)


## Also refreshes the status bar (docket 019fb933d4a9): the route-flow
## cluster's tools arm/disarm outside _canvas.tool_mode (they drive an
## AnnotationAuthorTool on the shared overlay, not the canvas tool surface —
## see the class doc above _MODE_HINTS), so _on_tool_mode_changed's own
## _update_status() call never fires for them. This is the one function every
## arm/disarm/cross-surface-takeover path already calls, so it is the natural
## single place to keep the status bar's armed-tool tag and gesture hint in
## step, the same way _sync_tool_buttons stays in step off tool_mode_changed.
func _update_route_flow_mode_label(kind_key: String) -> void:
	# DRY fix (cold review F7): _ROUTE_FLOW_LABELS (declared near _update_status,
	# below) is now the ONE authority for these three strings — this used to
	# carry its own match block producing the identical labels, so renaming one
	# tool meant remembering to edit two places ~10 lines apart in the same call
	# chain (the status-bar tag was the one that silently went stale).
	if _route_flow_mode_label != null:
		_route_flow_mode_label.text = str(_ROUTE_FLOW_LABELS.get(kind_key, "Select"))
	_update_status()


## Forwards a committed envelope to the host (same single call-site convention
## as AnnotationToolbar._on_annotation_ready) — the tool instance stays active
## for continuous tracing (no auto-deactivate on commit).
func _on_route_flow_annotation_ready(annotation: Dictionary) -> void:
	if _annotation_host != null:
		_annotation_host.add_annotation(annotation)


## A cancelled in-progress trace fully deactivates the cluster's tool
## (mirrors AnnotationToolbar._on_tool_cancelled's convention) — re-press the
## button to start drawing again.
func _on_route_flow_cancelled() -> void:
	_deactivate_route_flow_tool()


## Cross-surface mutual exclusion: when the shared overlay's active tool
## changes to something OTHER than what we last handed it (another surface,
## e.g. the dock's AnnotationToolbar, took over — or it was cleared from
## outside), drop our own button/label state without touching the overlay
## again (avoids a feedback loop).
func _on_overlay_active_tool_changed(tool: Object) -> void:
	_overlay_active_tool = tool
	# UNIVERSAL SELECT (B1u3): our own passive arm is not a cross-surface
	# takeover — it IS this panel's resting state, and running the teardown below
	# for it would untoggle the route-flow buttons and blank the mode label every
	# time Select re-arms.
	if tool != null and tool == _universal_select_tool():
		return
	# The overlay now holds something that is NOT our passive Select — another
	# surface's tool, or nothing at all. Either way, let the host forget it armed
	# anything, so a later disarm can never yank a tool we no longer own. This
	# runs BEFORE the route-flow early-out below on purpose: the commonest way
	# our tool gets cleared is _deactivate_route_flow_tool's unconditional
	# overlay.clear_active_tool() with no route tool active at all, which lands
	# here as tool == _active_route_flow_tool == null.
	if _annotation_host != null and _annotation_host.has_method("notify_universal_select_detached"):
		_annotation_host.notify_universal_select_detached()
	if tool == _active_route_flow_tool:
		_sync_universal_select()
		return
	_active_route_flow_tool = null
	_active_route_flow_kind = ""
	_untoggle_route_flow_buttons()
	_update_route_flow_mode_label("")
	# Reverse half of bug 019fb5e9c8ac: another surface (the dock's
	# AnnotationToolbar) armed a tool on the shared overlay — release the
	# canvas tool surface, mirroring _activate_route_flow_tool. A null tool
	# is a clear-out, not a takeover, and must not yank the canvas tool
	# (that path fires when WE clear the overlay while arming a canvas tool).
	if tool != null and _canvas != null \
			and _canvas.tool_mode != _PcbCanvasScript.ToolMode.SELECT:
		_canvas.set_tool_mode(_PcbCanvasScript.ToolMode.SELECT)
		_sync_tool_buttons(_canvas.tool_mode)
	# A clear-out hands the canvas surface back: re-arm the universal Select if
	# nothing else is holding the overlay now.
	_sync_universal_select()


## Where the platform annotation dock must mount (Editor.gd duck-types this —
## round A hook). Opting in makes this panel own the dock's responsive
## placement; the platform's editor-width RIGHT/BOTTOM logic is bypassed.
## Slot depends on the current mode: bottom strip in medium/narrow (HITL:
## 3-col wants the dock along the bottom), sidebar in wide.
func get_annotation_dock_parent() -> Control:
	var slot := _current_dock_slot()
	if slot != null and is_instance_valid(slot):
		return slot
	return null


func _current_dock_slot() -> Control:
	if _layout_mode == _PanelLayoutScript.MODE_WIDE:
		return _dock_parent
	return _bottom_dock_slot if _bottom_dock_slot != null else _dock_parent


## The mounted AnnotationDockPane, wherever it currently sits (duck-typed:
## the platform names it; we just look for its API in either slot).
func _find_dock_pane() -> Node:
	for slot in [_dock_parent, _bottom_dock_slot]:
		if slot == null or not is_instance_valid(slot):
			continue
		for child in slot.get_children():
			if child.has_method("set_dock_mode"):
				return child
	return null


## Moves the mounted dock pane into the current mode's slot and re-asserts its
## internal arrangement (RIGHT = column for the sidebar, BOTTOM = strip).
func _sync_dock_pane_mode() -> void:
	var pane := _find_dock_pane()
	if pane == null or not is_instance_valid(pane):
		return
	var slot := _current_dock_slot()
	if slot != null and pane.get_parent() != slot:
		pane.get_parent().remove_child(pane)
		slot.add_child(pane)
	var wide := _layout_mode == _PanelLayoutScript.MODE_WIDE
	if pane is Control:
		(pane as Control).size_flags_vertical = \
			Control.SIZE_EXPAND_FILL if wide else Control.SIZE_SHRINK_END
	# DockMode enum: RIGHT = 0, BOTTOM = 1 (AnnotationDockPane.gd) — read via
	# get() so a pane without the enum still duck-types safely.
	pane.set_dock_mode(0 if wide else 1)


# ── Per-hint revision undo/redo keyboard seam (C4 deliverable 2c) ─────────────

## Ctrl+Z / Ctrl+Shift+Z routes to per-hint revision undo/redo ONLY when a
## pcb_route_hint annotation is currently selected — otherwise the event is
## left unconsumed so it never collides with a future board-level undo
## binding (see below).
##
## Seam choice (reuse-scan finding): AnnotationOverlay._gui_input only
## special-cases Escape/Delete/Backspace/Enter via its pseudo-pointer
## convention (mods=KEY_ESCAPE/KEY_DELETE/KEY_ENTER through
## on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, mods)) — it does NOT
## forward Ctrl+Z at all, so no AnnotationAuthorTool ever sees it. Nor does
## pcb_canvas.gd's own _handle_key_input (it binds Delete/Escape/R/G/N/L/
## Home/+/-/S but no Ctrl+Z). PCBPanel currently wires NO board-level undo
## either (no Undo button, no Ctrl+Z handler anywhere in this plugin) — the
## legacy in-core Editor.gd:undo_action() match on Type.PCB is dead code for
## this off-tree plugin (its panel type is Type.PLUGIN_SCENE, which
## undo_action() does not match at all). So _unhandled_key_input on the
## panel Control is the first seam nothing else claims: it fires only when
## neither the overlay's nor the canvas's _gui_input consumed the key.
## Gating strictly on "a route hint is selected" keeps this mutually
## exclusive by construction with any future board-level Ctrl+Z binding —
## an edit with no hint selected simply falls through unconsumed.
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var ek: InputEventKey = event
	if not ek.pressed or ek.is_echo():
		return
	if ek.keycode != KEY_Z or not ek.ctrl_pressed:
		return
	if _annotation_host == null:
		return
	# A8u1: hint undo/redo is a SINGLE-hint revision stack (undo_hint_revision
	# takes one id). With a multi-selection there is no unambiguous target, so
	# Ctrl+Z disarms rather than silently rewinding whichever hint happens to be
	# primary. Exactly one selected → unchanged. The disarm is ANNOUNCED, not
	# silent: no board-level Ctrl+Z exists in this plugin (see the header above),
	# so falling through unconsumed would produce a dead key with no explanation —
	# the same thing draw_disarm_notice exists to prevent for bend/via.
	if _annotation_host.has_method("has_multi_selection") and _annotation_host.has_multi_selection():
		_show_transient_status("Hint undo needs one hint selected — %d are selected." \
			% _annotation_host.get_selected_annotation_ids().size())
		get_viewport().set_input_as_handled()
		return
	var sel_id: String = _annotation_host.get_selected_annotation_id()
	if sel_id.is_empty():
		return
	var ann: Dictionary = _annotation_host.get_by_id(sel_id)
	if str(ann.get("kind", "")) != "pcb_route_hint":
		return

	var result: Dictionary
	if ek.shift_pressed:
		result = _annotation_host.redo_hint_revision(sel_id)
	else:
		result = _annotation_host.undo_hint_revision(sel_id)
	if bool(result.get("ok", false)):
		get_viewport().set_input_as_handled()
		if _canvas != null:
			_canvas.queue_redraw()


# ── Responsive layout (round B) ────────────────────────────────────────────────

func _on_panel_resized() -> void:
	if _sidebar == null:
		return
	var mode: String = _PanelLayoutScript.mode_for_width(size.x, _layout_mode)
	if mode != _layout_mode:
		_apply_layout_mode(mode)


## Applies a layout mode. Visibility matrix (the View menu is the one
## view-flags surface at EVERY mode — owner ruling, bug 019fbb6242):
##   wide:   sidebar shown; Export button + board label inline.
##   medium: sidebar shown; board label → status.
##   narrow: sidebar behind the drawer toggle; Export lives in the View menu.
func _apply_layout_mode(mode: String, force := false) -> void:
	if mode == _layout_mode and not force:
		return
	var mode_changed := mode != _layout_mode
	var entering_narrow := mode == _PanelLayoutScript.MODE_NARROW \
		and _layout_mode != _PanelLayoutScript.MODE_NARROW
	_layout_mode = mode

	var narrow := mode == _PanelLayoutScript.MODE_NARROW
	var wide := mode == _PanelLayoutScript.MODE_WIDE

	if entering_narrow:
		_drawer_open = false  # drawer starts closed; canvas gets the width

	if _sidebar != null:
		var show_sidebar := (not narrow) or _drawer_open
		if _sidebar.visible and not show_sidebar and _dock_pane_in_sidebar():
			# Never hide the annotation toolbar with a live author tool — the
			# overlay would keep eating canvas clicks with no visible way out
			# (the dock pane enforces this for its own collapse; mirror it).
			# Only relevant when the dock actually sits in the sidebar — in
			# medium/narrow it lives in the always-visible bottom strip.
			_clear_dock_active_tool()
		_sidebar.visible = show_sidebar

	# Dock placement follows the mode (bottom in medium/narrow, sidebar in
	# wide) — move a mounted pane between slots.
	_sync_dock_pane_mode()
	if _drawer_button != null:
		_drawer_button.visible = narrow
		_drawer_button.button_pressed = _drawer_open
	# The View menu is unconditional at every mode (owner ruling, bug
	# 019fbb6242) — no inline-toggle sibling exists to sync or swap with; the
	# menu re-reads canvas flags on about_to_popup, so it can never go stale.
	if _export_button != null:
		_export_button.visible = not narrow
	if _board_size_label != null:
		_board_size_label.visible = wide
	# Properties default: expanded where width is generous, collapsed in the
	# 3-col medium tier (the status bar mirrors the selection either way).
	# Only on a REAL mode change — a force re-apply (drawer toggle) must not
	# clobber the user's manual expand/collapse choice.
	if mode_changed:
		_set_properties_expanded(wide)
	_update_status()


## Duck-typed: clears the active author tool on the mounted dock pane, AND
## the route-flow cluster's own tool. Three call sites: _apply_layout_mode
## (hidden-sidebar-eats-clicks hazard), _toggle_tool_mode (cross-surface
## exclusion, bug 019fb5e9c8ac — arming a canvas tool must release the dock),
## and _activate_route_flow_tool (bug 019fb64fb408 — arming a route-flow tool
## must release the dock too, called after that function's own teardown of
## any previously-armed route-flow tool so the outgoing tool still gets its
## on_deactivate() instead of a silent null-bounce).
func _clear_dock_active_tool() -> void:
	var pane := _find_dock_pane()
	if pane != null and pane.has_method("clear_active_tool"):
		pane.clear_active_tool()
	_deactivate_route_flow_tool()


func _dock_pane_in_sidebar() -> bool:
	var pane := _find_dock_pane()
	return pane != null and pane.get_parent() == _dock_parent


func _on_drawer_toggled() -> void:
	_drawer_open = not _drawer_open
	_apply_layout_mode(_layout_mode, true)


func _sync_view_menu_checks() -> void:
	if _view_menu_button == null or _canvas == null:
		return
	var popup := _view_menu_button.get_popup()
	for i in _VIEW_FLAGS.size():
		var idx := popup.get_item_index(i)
		if idx >= 0:
			popup.set_item_checked(idx, bool(_canvas.get(_VIEW_FLAGS[i][1])))
	_rebuild_view_menu_layer_eyes(popup)


## The per-layer visibility section of the View menu (epoch GA-1): one
## checkable "eye" per DECLARED copper layer, labelled with the KiCad name the
## selector uses. Rebuilt from the live stack on every about_to_popup — the
## same lazy-sync moment the static checks use — so a stack edit can never
## leave stale layer items behind. Items carry _VIEW_MENU_LAYER_ID_BASE +
## stack index; the whole section (separator included) is torn down and
## re-added each time, which is cheap at menu-open frequency.
func _rebuild_view_menu_layer_eyes(popup: PopupMenu) -> void:
	for i in range(popup.item_count - 1, -1, -1):
		if popup.get_item_id(i) >= _VIEW_MENU_LAYER_ID_BASE:
			popup.remove_item(i)
	if _data == null or _data.layers.is_empty():
		return
	popup.add_separator("Copper layers", _VIEW_MENU_LAYER_ID_BASE)
	for stack_index in _data.layers.size():
		var canon := str(_data.layers[stack_index])
		var label := PcbLayerStack.canon_to_kicad(canon)
		if label.is_empty():
			label = canon   # a non-copper declaration still gets an honest row
		var id: int = _VIEW_MENU_LAYER_ID_BASE + 1 + stack_index
		popup.add_check_item(label, id)
		popup.set_item_checked(popup.get_item_index(id),
			not _canvas.is_layer_hidden(canon))


func _on_view_menu_id_pressed(id: int) -> void:
	if id == _VIEW_MENU_EXPORT_ID:
		_on_export_yaml_pressed()
		return
	if _canvas != null and _data != null and id > _VIEW_MENU_LAYER_ID_BASE:
		var stack_index := id - _VIEW_MENU_LAYER_ID_BASE - 1
		if stack_index >= 0 and stack_index < _data.layers.size():
			var canon := str(_data.layers[stack_index])
			_canvas.set_layer_hidden(canon, not _canvas.is_layer_hidden(canon))
		return
	if _canvas == null or id < 0 or id >= _VIEW_FLAGS.size():
		return
	var flag: String = _VIEW_FLAGS[id][1]
	_canvas.set(flag, not bool(_canvas.get(flag)))
	if flag == "show_mask" and bool(_canvas.get(flag)):
		# Fetch on demand rather than on every load: the overlay is off by
		# default and the worker round-trip belongs to the person who asked.
		_refresh_mask_view()
	_canvas.queue_redraw()


## Structured layout state for MCP/tests — lets an agent verify responsive
## behavior as data instead of screenshots (LLM-ergonomics requirement).
##
## `plugin_build` (B2): a deployed-script-vintage stamp, PLUGIN_BUILD's own
## constant value read straight through — see that const's docs for why it is
## a hand-bumped marker rather than a git SHA (unavailable at runtime) or a
## manifest.json disk read (fragile path assumption for an off-tree script).
## It answers "which round's scripts is this running panel actually built
## from", the recurring HITL deploy-confusion question this round was asked
## to close, cheaply and honestly.
func get_layout_state() -> Dictionary:
	return {
		"mode": _layout_mode,
		"width": size.x,
		"sidebar_visible": _sidebar != null and _sidebar.visible,
		"drawer_open": _drawer_open,
		"view_menu_visible": _view_menu_button != null and _view_menu_button.visible,
		"properties_expanded": _properties_expanded,
		"dock_position": "sidebar" if _current_dock_slot() == _dock_parent else "bottom",
		"plugin_build": PLUGIN_BUILD,
	}


## Rebuild the layer selector from the board's declared stack.
##
## Epoch 6 unit 3b, owner ruling "layer presentation matches KiCad": the item
## LABEL is the KiCad copper name (F.Cu / In1.Cu / … / B.Cu) because that is what
## a PCB person reads, while the item METADATA stays the CANONICAL id ("top" /
## "in1" / "bottom") because that is what the canvas filter and the board model
## compare against (pcb_canvas._layer_visible is canonical-name equality). "All"
## stays first; the rest follow the board's declared order, which IS stack order
## (enforced by the validator, unit 3a).
func _rebuild_layer_option() -> void:
	if _layer_option == null:
		return
	_layer_option.clear()
	_layer_option.add_item("All")
	_layer_option.set_item_metadata(0, "all")
	var layers: Array = _data.layers if _data != null else ["top", "bottom"]
	for layer in layers:
		var raw := str(layer)
		# A valid board declares canonical ids, but fold a KiCad-named declaration
		# too so the metadata still MATCHES trace.layer instead of filtering to an
		# empty canvas. Non-copper names are left exactly as declared rather than
		# pushed through the copper mapping (which would error on them).
		var canon := raw
		var label := raw
		if PcbLayerStack.is_copper(raw):
			canon = PcbLayerStack.kicad_to_canon(raw)
			label = PcbLayerStack.canon_to_kicad(canon)
		# canon_to_kicad FAILS CLOSED (returns "" and push_error()s) on anything
		# it does not recognise. Show the raw declared name instead — a blank menu
		# entry is a layer the user cannot even name, which is worse than an
		# unfamiliar one.
		if label.is_empty():
			label = raw
		var idx := _layer_option.item_count
		_layer_option.add_item(label)
		_layer_option.set_item_metadata(idx, canon)
	_layer_option.select(0)


# ── Toolbar / canvas event handlers ───────────────────────────────────────────

func _toggle_tool_mode(mode: int) -> void:
	if _canvas == null:
		return
	# Cross-surface mutual exclusion (bug 019fb5e9c8ac): a canvas tool press
	# releases BOTH other tool surfaces — the route-flow cluster AND the
	# platform annotation dock. The old guard only released our own cluster,
	# so a dock-armed tool (e.g. annotation Select) stayed on the shared
	# overlay claiming every click, and Draw-tool clicks never landed.
	_clear_dock_active_tool()
	# Re-click disarm (item 5, 019fbbadd8f0, owner ruling): clicking the
	# ALREADY-armed radio button (Pan, Pour, Keepout, Trace, Eraser) is a
	# second explicit press on the same tool, not a request to re-arm it — it
	# disarms back to Select, the resting tool. Same OUTCOME the route-flow
	# cluster (_activate_route_flow_tool/_deactivate_route_flow_tool) and the
	# pin inspector (_toggle_inspect_pin_mode) already give on their own
	# surfaces — this brings the Tools/Select radio cluster in line with
	# them — but NOT the same mechanism: those two branch on the widget's
	# post-flip `button_pressed`, where this branches on `_canvas.tool_mode`,
	# the model state, which cannot be desynced by a stray button write (see
	# _sync_tool_buttons below, which does exactly such a write on every
	# call). A re-click on Select itself needs no special case — target is
	# already SELECT, and set_tool_mode's same-mode guard keeps that a no-op
	# exactly as it is today.
	# UX4 S7: "armed" now means armed AS DIRECT — the same mode armed as a
	# DRAFT (a Proposals-area toggle) is a different doorway, and pressing the
	# Tools button then means "switch this tool to direct", not "disarm".
	var was_armed: bool = _canvas.tool_mode == mode \
		and str(_canvas.authoring_destination) != _PcbCanvasScript.DEST_DRAFT
	var target: int = _PcbCanvasScript.ToolMode.SELECT if was_armed else mode
	# `was_armed` doubles as the announce flag: a disarm re-click is an
	# explicit "get me out" gesture, so any abandoned in-progress zone/trace
	# draw is announced, not silently discarded the way an ordinary
	# tool-to-tool switch discards one. set_tool_mode itself is responsible
	# for making that announce actually land AFTER the mode change settles
	# (cold review F1) — see its doc block.
	_canvas.set_tool_mode(target, was_armed)
	# A draft→direct switch of the SAME mode is a no-op for set_tool_mode (its
	# same-mode guard), so the destination reset must be explicit here.
	if not was_armed:
		_canvas.authoring_destination = _PcbCanvasScript.DEST_DIRECT
	_sync_tool_buttons(_canvas.tool_mode)


## The Proposals-area draft twin of _toggle_tool_mode (UX4 S7): arms the SAME
## canvas tool — the gestures are byte-identical — with authoring_destination
## DRAFT, re-asserted AFTER set_tool_mode (which resets every change to
## DIRECT). Re-click on the armed draft toggle disarms to Select, the standing
## radio rule; pressing it while the same mode is DIRECT-armed switches the
## destination without disturbing the tool.
func _toggle_draft_tool(mode: int) -> void:
	if _canvas == null:
		return
	_clear_dock_active_tool()
	var was_armed: bool = _canvas.tool_mode == mode \
		and str(_canvas.authoring_destination) == _PcbCanvasScript.DEST_DRAFT
	var target: int = _PcbCanvasScript.ToolMode.SELECT if was_armed else mode
	_canvas.set_tool_mode(target, was_armed)
	if not was_armed:
		_canvas.authoring_destination = _PcbCanvasScript.DEST_DRAFT
		# The teach line names the destination (S7): what a commit will do is
		# the ONE thing the two doorways disagree about.
		_show_transient_status("DRAFT armed — commits stage review ghosts; the board is untouched until Accept.")
	_sync_tool_buttons(_canvas.tool_mode)


func _sync_tool_buttons(mode: int) -> void:
	# UX4 S7: the radio shows WHICH DOORWAY armed the tool — the direct button
	# lights only for a direct arm, the draft toggle only for a draft arm.
	var draft: bool = _canvas != null \
		and str(_canvas.authoring_destination) == _PcbCanvasScript.DEST_DRAFT
	for m in _tool_buttons:
		(_tool_buttons[m] as Button).set_pressed_no_signal(m == mode and not draft)
	for m in _draft_tool_buttons:
		(_draft_tool_buttons[m] as Button).set_pressed_no_signal(m == mode and draft)


## Trash-can enablement (item 019fb92f8b83): live off the canvas' own
## selection_changed signal, the same feed _update_status/_update_properties
## already listen on — no separate polling, no separate state to drift.
func _update_delete_button() -> void:
	if _delete_button != null:
		# has_ANY_selection (B1u3): the trash empties the whole panel selection,
		# annotations included, so it must be live when only an annotation is
		# selected. Duck-typed for the same reason every other canvas call here
		# is — a canvas without the verb keeps the board-only answer.
		var live := false
		if _canvas != null:
			live = _canvas.has_any_selection() if _canvas.has_method("has_any_selection") \
				else _canvas.has_selection()
		_delete_button.disabled = not live


func _on_tool_mode_changed(mode: int) -> void:
	_sync_tool_buttons(mode)
	_sync_draw_arm_ui(mode)
	_update_status()
	# The universal Select is armed with the canvas's Select mode and released
	# with it (B1u3) — one tool, one arming, whichever route got us here (button,
	# keyboard, a programmatic set_tool_mode).
	_sync_universal_select()


## Show/hide the Draw tools' arming controls with the tool each one arms, and
## refresh them from the board on every arm (nets, layers and design rules can all
## change between arms). Hooked to tool_mode_changed rather than to the buttons,
## so every route into a Draw mode — button, keyboard, a programmatic
## set_tool_mode — arms the same way.
##
## Was _sync_zone_arm_ui until the epoch 6 boundary added a trace control; the
## rule is one function per CONCEPT ("show the arming controls for the armed
## tool"), not one per widget, so the trace width box joined it rather than
## growing a parallel sync with its own copy of the visibility logic.
## The NET picker is a POUR control, not a zone control (owner boundary ruling
## 2026-07-30, docket 019fb5ad6d20: "Keepouts don't need net connections"). It is
## hidden — not merely ignored — while Keepout is armed, because a visible picker
## is a request for input, and asking for a net the commit path will discard is
## the UI lying about the contract. The LAYER picker stays for both: a keepout is
## still a region on one copper layer.
func _sync_draw_arm_ui(mode: int) -> void:
	var is_pour_tool: bool = mode == _PcbCanvasScript.ToolMode.ZONE_POUR
	var is_zone_tool: bool = is_pour_tool \
		or mode == _PcbCanvasScript.ToolMode.ZONE_KEEPOUT
	# CUTOUT (campaign 2 epoch B, unit 3) arms none of the controls below —
	# stated here rather than left to fall through, so a reader does not read
	# the omission as unfinished work. A cutout has no net, no layer and no
	# width to pick (see pcb_data.gd's Cutout Management doc): is_pour_tool/
	# is_zone_tool/is_trace_tool all correctly evaluate false for it already,
	# with no widget-visibility line to add.
	# BUS (campaign 2 epoch C, unit 5) arms none of these either, same reason:
	# its net LIST is picked by clicking pads/traces on the canvas (S3), not a
	# sidebar widget, and its per-net widths auto-derive (pcb_canvas.gd's
	# _bus_net_width) rather than reading the trace-width box. is_pour_tool/
	# is_zone_tool/is_trace_tool all correctly evaluate false for it already.
	var is_trace_tool: bool = mode == _PcbCanvasScript.ToolMode.TRACE

	if _trace_width_spin != null:
		# OFC-5: no longer standing-visible with the tool — the reveal is the
		# menu's to grant and the disarm always takes it back.
		if not is_trace_tool:
			_draw_width_revealed = false
		_trace_width_spin.visible = is_trace_tool and _draw_width_revealed
		if is_trace_tool:
			_sync_trace_width_spin()

	if _zone_layer_option != null:
		_zone_layer_option.visible = is_zone_tool
		if is_zone_tool:
			_rebuild_zone_layer_option()

	if _zone_net_option == null:
		return
	_zone_net_option.visible = is_pour_tool
	if not is_pour_tool:
		return
	_rebuild_zone_net_option()
	if _data != null and _data.get_net_count() == 0:
		_show_transient_status("This board declares no nets — a copper pour needs one before it can be drawn.")
	elif _canvas != null and str(_canvas.zone_author_net).is_empty():
		_show_transient_status("Pick a net for the pour, then click its corners.")


## Rebuild the zone net picker from the board's declared nets. The first entry is
## a placeholder carrying "" so "no net chosen" is a REAL state the commit path
## can refuse, rather than an implicit selection of whichever net sorted first —
## a pour silently tied to the wrong net is copper on the wrong net.
func _rebuild_zone_net_option() -> void:
	if _zone_net_option == null:
		return
	var previous := str(_canvas.zone_author_net) if _canvas != null else ""
	_zone_net_option.clear()
	_zone_net_option.add_item("Net…")
	_zone_net_option.set_item_metadata(0, "")
	var names: Array = _data.get_net_names() if _data != null else []
	names.sort()
	var selected := 0
	for name in names:
		var idx := _zone_net_option.item_count
		_zone_net_option.add_item(str(name))
		_zone_net_option.set_item_metadata(idx, str(name))
		if str(name) == previous:
			selected = idx
	_zone_net_option.select(selected)
	# Keep the canvas's armed net and the widget in step: a net that vanished with
	# a board reload must not stay armed behind a placeholder.
	if _canvas != null and selected == 0:
		_canvas.zone_author_net = ""


func _on_zone_net_selected(index: int) -> void:
	if _canvas == null or _zone_net_option == null:
		return
	var meta: Variant = _zone_net_option.get_item_metadata(index)
	_canvas.zone_author_net = str(meta) if meta != null else ""


## Rebuild the zone layer picker from the board's declared stack.
##
## Structurally the net picker above and the toolbar's _rebuild_layer_option
## together: first entry is a placeholder carrying "" — but here "" is NOT "no
## choice made", it is the REAL and default choice "follow the view layer filter",
## which is what the zone tools did before this control existed. That is why it is
## labelled "View layer" rather than "Layer…" and why landing on it is not an
## error the commit path refuses.
##
## Labels are KiCad names and metadata is canonical, per the same owner ruling
## _rebuild_layer_option cites ("layer presentation matches KiCad"): F.Cu is what
## a PCB person reads, "top" is what zone.layer and PcbLayerStack compare against.
## COPPER ONLY — a zone is copper (or a keepout over copper), and the canvas
## refuses a non-copper override anyway, so offering a declared non-copper layer
## here would offer a choice that does nothing.
func _rebuild_zone_layer_option() -> void:
	if _zone_layer_option == null:
		return
	var previous := str(_canvas.zone_layer_override) if _canvas != null else ""
	_zone_layer_option.clear()
	_zone_layer_option.add_item("View layer")
	_zone_layer_option.set_item_metadata(0, "")
	# _declared_copper_layer_choices (A5) is where the copper-only / KiCad-label /
	# canonical-metadata rules below used to be spelled out inline; the zone
	# RE-PROPERTY picker needs the identical list, and two copies of "which layers
	# may a zone be on" is exactly one copy too many.
	var selected := 0
	for choice in _declared_copper_layer_choices():
		var idx := _zone_layer_option.item_count
		_zone_layer_option.add_item(str(choice["label"]))
		_zone_layer_option.set_item_metadata(idx, str(choice["canon"]))
		if str(choice["canon"]) == previous:
			selected = idx
	_zone_layer_option.select(selected)
	# Keep the canvas's armed layer and the widget in step: a layer that vanished
	# with a board reload must not stay armed behind the "View layer" entry.
	if _canvas != null and selected == 0:
		_canvas.zone_layer_override = ""


func _on_zone_layer_selected(index: int) -> void:
	if _canvas == null or _zone_layer_option == null:
		return
	var meta: Variant = _zone_layer_option.get_item_metadata(index)
	_canvas.zone_layer_override = str(meta) if meta != null else ""
	# The pour preview labels itself with the effective layer, so a live redraw is
	# what makes the choice visible mid-draw rather than only at commit.
	_canvas.queue_redraw()


## Point the width box at the width the trace tool would commit right now: the
## armed override if the user has set one, else the seeding order below.
##
## set_value_no_signal, NOT `value =` — assigning would fire value_changed and so
## write the box's own (step-rounded, range-clamped) number back as an explicit
## override the user never chose. A board whose design rule is 0.254 mm would
## silently start committing 0.25 mm. Leaving the override at 0.0 keeps
## "untouched" meaning "the board's rule, exactly", and the box is a display until
## the user actually turns it. The same clamp means a sub-0.1 mm design rule shows
## as 0.1 while still committing its true value — the display rounds, the commit
## does not.
func _sync_trace_width_spin() -> void:
	if _trace_width_spin == null:
		return
	var armed: float = float(_canvas.trace_width_override) if _canvas != null else 0.0
	if armed > 0.0:
		_trace_width_spin.set_value_no_signal(armed)
		return
	_trace_width_spin.set_value_no_signal(seeded_trace_width())


## SEEDING ORDER for the width box (owner ruling, A7 docket 019fb92f07e2):
##   1. the BOARD's design_rules.trace_width_mm, when it declares one — a board
##      that states its own trace width outranks anything the user preferred on
##      some other board. The board is a document; the preference is a habit.
##   2. the STORED preference, when the board declares no rule — the no-rule case
##      is exactly the gap a preference exists to fill.
##   3. the control's own default (pcb_trace.DEFAULT_WIDTH_MM, which is also
##      pcb_data.DEFAULT_TRACE_WIDTH_MM) when neither says anything.
##
## Step 2 turns on has_stored(), NOT on the preference's value: an unstored key
## reads back as the registry default, which would make "never chose one" and
## "chose 0.25" indistinguishable and collapse steps 2 and 3 into one. This
## EXTENDS pcb_data.authored_trace_width rather than forking it — that function
## already encodes board-rule-first, and design_rule_trace_width() (A7) is the
## same read with the "declared nothing" case still visible.
func seeded_trace_width() -> float:
	var rule: float = _data.design_rule_trace_width() if _data != null else 0.0
	if rule > 0.0:
		return rule
	var prefs = get_preferences()
	if prefs == null:
		return _PcbTraceScript.DEFAULT_WIDTH_MM
	# Drain BEFORE the has_stored branch: a corrupt prefs file loads as EMPTY
	# values, so has_stored() is false and a drain inside that branch would
	# never fire — the one path that generated the warning would be the one
	# path that never showed it (cold-review A7 F1).
	_drain_pref_warning()
	if prefs.has_stored(_PcbPrefsScript.KEY_TRACE_WIDTH):
		return prefs.get_float(_PcbPrefsScript.KEY_TRACE_WIDTH, _PcbTraceScript.DEFAULT_WIDTH_MM)
	return _PcbTraceScript.DEFAULT_WIDTH_MM


## OFC-5: the canvas menu's "Set drawing width…" landing. Same shape as
## _on_edit_trace_width_requested (menu reveals + focuses the ONE existing
## editor; commits keep flowing through _on_trace_width_changed, which owns
## the preference write and the override) — the sidebar box just stops being
## standing furniture.
func _on_edit_draw_width_requested() -> void:
	if _trace_width_spin == null:
		return
	_draw_width_revealed = true
	_trace_width_spin.visible = true
	_sync_trace_width_spin()
	# Deferred for the same measured reason _on_edit_trace_width_requested
	# defers (F3 round 2): a same-frame focus races the layout pass that the
	# visibility flip just queued.
	call_deferred("_reveal_draw_width_spin")


## The deferred second half of _on_edit_draw_width_requested — mirrors
## _reveal_trace_width_spin's guards (headless mounts legitimately never
## have the control in a visible tree).
func _reveal_draw_width_spin() -> void:
	if _trace_width_spin == null or not is_instance_valid(_trace_width_spin):
		return
	var line_edit := _trace_width_spin.get_line_edit()
	if line_edit == null or not line_edit.is_inside_tree():
		return
	if not line_edit.is_visible_in_tree():
		return
	if _sidebar_scroll != null:
		_sidebar_scroll.ensure_control_visible(_trace_width_spin)
	line_edit.grab_focus()
	line_edit.select_all()


func _on_trace_width_changed(value: float) -> void:
	if _canvas == null:
		return
	_canvas.trace_width_override = value
	# The width the human just chose IS the preference (A7). Only THIS control
	# writes it: the box arms the width of traces NOT YET DRAWN, which is exactly
	# what a "default trace width" preference means. The trace property row below
	# deliberately does NOT write it — re-widening one existing trace is an edit
	# to that trace, and letting it silently repoint the default would mean
	# inspecting an old 0.15 mm trace changed what every future trace looks like.
	# Seeding only consults the preference when the board declares no design rule,
	# so storing it on a board that HAS a rule is still worth doing: it is the
	# width this human wants on the next board that declares none.
	var prefs = get_preferences()
	if prefs != null:
		var res: Dictionary = prefs.set_value(_PcbPrefsScript.KEY_TRACE_WIDTH, value)
		if not bool(res.get("ok", false)):
			_show_transient_status(str(res.get("error", "Preference not stored.")))
		else:
			_drain_pref_warning()
	# The rubber-band preview draws at the armed width, so a mid-draw change is
	# visible immediately instead of only in the committed copper.
	_canvas.queue_redraw()


## The plugin-scoped preference store (pcb_prefs.gd). PROCESS-WIDE, not
## per-panel: a preference belongs to the plugin, so two open PCB tabs cannot
## hold two different ideas of the default trace width, and the MCP tool surface
## can read/write it whether or not a panel is mounted. Exposed for MCP/tests.
func get_preferences():
	return _PcbPrefsScript.shared()


## Show whatever the preference store last had to complain about (a corrupt file,
## an unwritable directory, an unreadable key) on the SAME transient status line
## refused traces and refused zone edits use. take_warning() consumes it, so a
## problem is reported once rather than on every seeding read.
func _drain_pref_warning() -> void:
	var prefs = get_preferences()
	if prefs != null and prefs.has_warning():
		_show_transient_status(prefs.take_warning())


## Apply a preference an AGENT wrote so the human's panel shows it immediately
## (A7 acceptance 4). Called through the host→panel back-reference
## (PcbAnnotationHost.get_panel) by panel_tools' minerva_pcb_set_preference —
## the same duck-typed path run_router/load_board already use.
##
## An explicit preference write is an ARMING act, not merely a stored number:
## it also sets the canvas' trace_width_override, so the next trace the human
## draws really is that wide even on a board whose design rule says otherwise
## (which is what "an agent pref write shows LIVE in the human's spin box" has
## to mean to be worth anything). Unknown keys never reach here — the tool
## validates against the store's registry first.
func apply_preference(key: String, value: Variant) -> void:
	if key != _PcbPrefsScript.KEY_TRACE_WIDTH:
		return
	var width := float(value)
	if _canvas != null:
		_canvas.trace_width_override = width
		_canvas.queue_redraw()
	if _trace_width_spin != null:
		_trace_width_spin.set_value_no_signal(width)


func _on_layer_selected(index: int) -> void:
	if _canvas == null or _layer_option == null:
		return
	var meta: Variant = _layer_option.get_item_metadata(index)
	_canvas.trace_layer_filter = str(meta) if meta != null else "all"
	_canvas.queue_redraw()


func _on_component_lock_changed(message: String) -> void:
	_show_transient_status(message)


## Show a message in the status bar, then fall back to the standing status after
## 2s. The ONE transient-status pathway — the component-lock channel and the zone
## tools' feedback channel both land here rather than each growing their own timer.
func _show_transient_status(message: String) -> void:
	_set_status(message)
	# Clear the transient message after 2s (guard: tree may be gone).
	if is_inside_tree():
		get_tree().create_timer(2.0).timeout.connect(func() -> void:
			if is_instance_valid(_status_label):
				_update_status())


## Backend lifecycle: lazy start-on-demand + process-identity verification
## (docket bug 019f6c1e0399). Godot-scene panels are host-executed independent
## of the plugin's own backend subprocess — PluginScenePanelBroker mounts this
## panel regardless of whether the Go backend is RUNNING (that's the whole
## bug: the panel opens and edits fine while the backend is stopped, and only
## the first IPC round-trip — export/route/load — discovers it). Rather than
## a blanket manifest autostart (which would spend a subprocess on every PCB
## plugin install, including sessions that never touch a routing/export
## action), every backend IPC call below goes through
## _request_with_backend_ensure: on a plugin_not_running reply it starts the
## backend and PROVES the connection it produced is actually "pcb" before
## retrying — see _verify_backend_identity for why a liveness flag is not
## enough.
##
## Lazy-start bridge: no host_capability exists for "start my own plugin" on
## CapabilityBroker's named dispatch table — the only reachable lever from a
## scene panel is capability:mcp.proxy:<tool>, which forwards verbatim to
## MinervaMCPServer (see CapabilityBroker._handle_mcp_proxy). This proxies
## minerva_plugin_start the same way the drive/movie-gen/3d-gen plugins already
## proxy their own host tools. Declared in manifest.json permissions +
## ui.ipc_messages + this panel's ipc_channels.
const _START_BACKEND_CHANNEL := "capability:mcp.proxy:minerva_plugin_start"
## Go-side in-process tool (internal/tools/ping.go, registered at server
## startup — answers directly, no worker hop) — NOT the Python worker's
## internal "ping" JSON-RPC method (worker/pcb_worker/methods.py), which is
## bridge-internal and never reaches Minerva's MCP surface. This is the one
## that's a real, dynamically-discovered MCP tool once the backend is running
## (confirmed by test_pcb_plugin_smoke.gd's Section B: "ping" appears in
## conn.list_tools()) and it echoes a caller-supplied string verbatim, which
## is exactly the round-trip identity primitive we need.
const _PING_CHANNEL := "ping"
const _BACKEND_PLUGIN_ID := "pcb"


## True only for the broker's plugin_not_running reply shape
## (PluginErrors.plugin_not_running: {success:false, error_code:
## "plugin_not_running", ...}) — matched by code AND by message substring, so
## ensure-and-retry still fires if PluginErrors' wording ever changes (same
## defensive match route_board's own plugin_not_running detection already used).
func _reply_says_plugin_not_running(reply: Dictionary) -> bool:
	if typeof(reply) != TYPE_DICTIONARY:
		return false
	var code := str(reply.get("error_code", ""))
	var msg := str(reply.get("error_message", ""))
	return code == "plugin_not_running" or msg.findn("not running") != -1


## PROCESS-IDENTITY check — deliberately NOT a liveness boolean. Sends a
## fresh, locally-generated nonce through the backend's "ping" tool and
## requires ALL THREE: ok==true, plugin=="pcb", AND echo==the exact nonce
## THIS call generated. Liveness alone (ok==true, or "a connection object
## exists") does not prove the round-trip that just happened reached the
## process we mean to talk to — a stale cached reply, a reply satisfying some
## OTHER in-flight request, or a differently-configured backend could all
## satisfy a bare ok==true check. Generating the nonce fresh per call (rather
## than reusing a fixed string) is what makes the comparison meaningful: only
## a live process that received THIS request and echoed it back, right now,
## passes.
func _verify_backend_identity(ipc, timeout_ms: int = 10000) -> bool:
	if ipc == null:
		return false
	var nonce := "pcb-identity-%d-%d" % [Time.get_ticks_usec(), randi()]
	var reply_id := "ping:%d" % Time.get_ticks_usec()
	request.emit(_PING_CHANNEL, {"echo": nonce}, reply_id)
	var reply: Dictionary = await ipc.await_reply(reply_id, timeout_ms)
	if typeof(reply) != TYPE_DICTIONARY or not bool(reply.get("success", false)):
		return false
	# Two levels of unwrap between here and HandlePing's raw {ok,plugin,
	# version,echo} body — confirmed against the REAL binary (Section C of
	# test_pcb_backend_lifecycle.gd), not assumed: main.go's dispatch()
	# ALWAYS wraps every tool's raw result as {ok:true, result:<raw>} before
	# it leaves the Go process (see main.go:347-349); _dispatch_to_plugin_backend
	# then sees that dict has an "ok" key and wraps it AGAIN via
	# PluginErrors.backend_success — so a scene panel calling any backend tool
	# (not just ping) sees {success, result:{ok, result:<raw>}}. This is the
	# SAME double-wrap route_board's own unwrap already contends with for
	# pcb.route (see its "worker envelope arrives one level deeper than the
	# direct-stdio path" comment) — ping is just the leaf case, since its
	# raw body IS the thing we compare, not a further worker envelope.
	var go_envelope: Variant = reply.get("result", {})
	if typeof(go_envelope) != TYPE_DICTIONARY:
		return false
	var body_variant: Variant = (go_envelope as Dictionary).get("result", {})
	if typeof(body_variant) != TYPE_DICTIONARY:
		return false
	var body: Dictionary = body_variant
	return bool(body.get("ok", false)) \
			and str(body.get("plugin", "")) == _BACKEND_PLUGIN_ID \
			and str(body.get("echo", "")) == nonce


## Lazy start-on-demand: ask the host to start the pcb backend (the only
## reachable bridge from a scene panel — see _START_BACKEND_CHANNEL), THEN
## prove via a fresh ping round-trip that the connection it produced is
## actually the pcb backend. minerva_plugin_start's own {ok:true} is never
## treated as sufficient by itself — it only reflects PluginManager's state
## flag flipping to RUNNING, not that this panel can actually reach and
## correctly identify the process over IPC.
func _start_and_verify_backend(ipc, timeout_ms: int = 30000) -> bool:
	if ipc == null:
		return false
	var reply_id := "%s:%d" % [_START_BACKEND_CHANNEL, Time.get_ticks_usec()]
	request.emit(_START_BACKEND_CHANNEL, {"id": _BACKEND_PLUGIN_ID}, reply_id)
	var start_reply: Dictionary = await ipc.await_reply(reply_id, timeout_ms)
	if typeof(start_reply) != TYPE_DICTIONARY or not bool(start_reply.get("success", false)):
		return false
	return await _verify_backend_identity(ipc)


## Wraps a single backend IPC round-trip with on-demand lazy start: send the
## request; if (and only if) the backend replies plugin_not_running, start it
## and verify its identity, then retry ONCE. Every existing call site's error
## handling (route_board / load_board_from_yaml / _on_export_yaml_pressed)
## already understands the raw broker reply shape unchanged by this wrapper —
## on any outcome other than a confirmed start+verify, the ORIGINAL
## plugin_not_running reply is returned verbatim so those call sites' own
## "pcb_backend_stopped" / "start via minerva_plugin_start" messaging still
## fires exactly as before for the caller to see.
func _request_with_backend_ensure(channel: String, payload: Dictionary, timeout_ms: int) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return {"success": false, "error_code": "worker_unavailable",
			"error_message": "plugin IPC channel not ready"}
	var reply_id := "%s:%d" % [channel, Time.get_ticks_usec()]
	request.emit(channel, payload, reply_id)
	var result: Dictionary = await ipc.await_reply(reply_id, timeout_ms)
	if not _reply_says_plugin_not_running(result):
		return result
	if not await _start_and_verify_backend(ipc):
		return result
	var retry_id := "%s:%d" % [channel, Time.get_ticks_usec()]
	request.emit(channel, payload, retry_id)
	return await ipc.await_reply(retry_id, timeout_ms)


## YAML export → pcb.serialize over the plugin IPC channel (carry-in 3a). The
## legacy PCBEditor.export_yaml() called the dropped to_yaml(); the canonical
## boundary + Go channel owns YAML now. 64KiB cap surfaces as payload_too_large
## → shown in the status bar (never crashes).
func _on_export_yaml_pressed() -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_set_status("YAML export unavailable — plugin IPC not ready.")
		return
	_set_status("Exporting YAML…")
	var result: Dictionary = await _request_with_backend_ensure(
			"pcb.serialize", {"board": _data.to_board_dict()}, 30000)

	if not bool(result.get("success", false)):
		var code := str(result.get("error_code", ""))
		var msg := str(result.get("error_message", ""))
		if code.findn("payload_too_large") != -1 or code.findn("too_large") != -1 or msg.findn("64") != -1:
			_set_status("YAML export failed: board exceeds the 64KiB IPC cap.")
		else:
			_set_status("YAML export failed: %s" % (msg if msg != "" else code))
		return

	# Success payload shape is owned by the Go side; surface a size hint if present.
	var payload: Variant = result.get("result", null)
	var yaml_text := ""
	if payload is Dictionary:
		yaml_text = str((payload as Dictionary).get("yaml", (payload as Dictionary).get("text", "")))
	elif payload is String:
		yaml_text = payload
	if yaml_text != "":
		_set_status("YAML exported (%d bytes)." % yaml_text.length())
	else:
		_set_status("YAML export complete.")


# ── Epoch UX3 station 11 (K13): GATED PROMOTION to canonical YAML ─────────────

## THE serialize-back verb — the standing loose end of every HITL: the live
## board (committed copper, moves) becomes the canonical YAML file, and it is
## IMPOSSIBLE without a passing full authoritative verdict (pcb.promote_check:
## connectivity DRC + geometric DRC + assembly, composed fail-closed worker-
## side). There is deliberately NO acknowledge-through here (S7): commit's
## placement gate takes consent because a draft is cheap to revert; a promoted
## file is the durable design of record, and the gate is the point.
##
## Path resolution (cold review F2 — the .pcbskel corruption BLOCKER):
## explicit arg wins; otherwise the CANONICAL SOURCE path — recorded ONLY by
## load_board_from_yaml's adoption (_canonical_source_path), NEVER the
## editor-flow _file_path, which the ordinary .pcbskel document flow also
## sets: falling back to it would truncate a JSON .pcbskel document with YAML
## the next open cannot parse. No canonical source ⇒ refuse by name. And a
## ".pcbskel" target is refused OUTRIGHT, explicit arg included — promotion
## writes canonical YAML, and there is no legitimate ask that spells a YAML
## write onto a .pcbskel.
##
## Post-promotion state, the station's recorded decisions: (c) the workspace
## is NOT mutated — committed candidates already ARE the canonical copper this
## file now carries, and their consumed-hint records stay consumed (audit);
## (d) the sidecars need no rewrite — their coherence guard is the BOARD
## fingerprint (compute_board_fingerprint of the live dict), and promotion
## changes the file, not the dict, so every fingerprint remains valid; the
## annotation sidecar already lives beside the adopted path.
##
## Reply on success: {success, path, digest_sha256, bytes, promote_check
## summary, census_delta? (component/net/trace/via count deltas vs the prior
## file, computed by deserializing it — absent when there was no prior file or
## it did not parse: prior_state notes why)}.
## `allow_copper_regression` (UX4 station 9, DCR S6 — owner ruling 1): the
## explicit override for the panel-side regression guard below. Default false:
## a promotion that would REMOVE copper a prior design of record had (per-net
## copper presence = traces ∪ zones ∪ netted vias — pours count, mirroring the
## census's own definition) or would drop components refuses by name until the
## caller confirms.
## CANONICAL-SOURCE HYGIENE (K2, epoch CPN1): the live board dict with
## DERIVED presentation state stripped, exactly as the gate + serializer must
## see it. Captured footprint graphics are attached at LOAD by the worker's
## footprint resolution (pcb.deserialize's graphics attach) — re-derivable
## library projections, never design intent — and through Go's Extra
## passthrough they would land VERBATIM in the canonical YAML. Found live in
## the coupon round: LOGO1's baked stroke text pushed the serialized source
## past the 60KiB payload cap, so the size ceiling accidentally caught the
## exact residue class K2 exists to forbid. The render-detail key set below
## is the full set to_board_dict emits for the HANDOFF path (see
## pcb_component.gd's "Canonical Extra (render detail)" block) — every one
## re-derivable from the locked footprint at load, none design intent; the
## first real promote shipped all of them into the corpus file via Go's
## Extra passthrough (K2 residue, found by inspection).
func _promote_stripped_board() -> Dictionary:
	var board: Dictionary = _data.to_board_dict()
	var render_detail_keys: Array = ["graphics", "pads", "local_bounds",
		"has_pad_geometry", "bbox_center_offset", "color", "label_visible",
		"locked", "width", "height", "footprint_id"]
	for comp in (board.get("components", []) as Array):
		if comp is Dictionary:
			for render_key in render_detail_keys:
				(comp as Dictionary).erase(render_key)
	for trace in (board.get("traces", []) as Array):
		if trace is Dictionary:
			(trace as Dictionary).erase("locked")
	return board


## The promote gate's WORKER ROUND-TRIP, shared verbatim by promote() (which
## gates on it) and board_check() (which only reports it — OFC-4). Returns
## {ok:true, gate:<verdict>} or {ok:false, reply:<the error dict the caller
## should return>}. A well-formed gate reply ALWAYS carries `promotable` — a
## dict without it is some other shape (F3's lesson) and reads as
## unavailable, never gated.
func run_promote_gate(board: Dictionary) -> Dictionary:
	var gate_raw: Dictionary = await _request_with_backend_ensure(
		"pcb.promote_check", {"board": board}, 60000)
	var gate: Dictionary = _unwrap_channel_reply(gate_raw)
	if gate.is_empty() or not gate.has("promotable"):
		return {"ok": false, "reply": {"success": false, "error": "promotion_check_unavailable",
			"note": "the promotion gate could not run — an unverifiable board does not promote (fail closed)"}}
	return {"ok": true, "gate": gate}


## OFC-4 (epoch 019ff9421d3f; ratification sheet C1/C3 — kill
## detection-by-refusal): the promote gate's READ half as a standalone,
## non-mutating census of the LIVE board. Same stripped snapshot, same
## pcb.promote_check verdict, no write and no gate semantics — the reply
## REPORTS the refusals promotion WOULD raise instead of raising them. This
## is the agent's free eyes on the live board; before it existed, post-accept
## damage was only visible by attempting a promote and reading the refusal.
func board_check() -> Dictionary:
	if _data == null:
		return {"success": false, "error": "no_board"}
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return {"success": false, "error": "worker_unavailable",
			"note": "the census needs the pcb backend (same worker the promote gate uses) — plugin IPC not ready"}
	# F3 (Codex OFC review 1188): the revision the snapshot describes, captured
	# BESIDE it. The gate await below can take up to 60s; a board edited in
	# flight makes the verdict describe a world that no longer exists, and a
	# "LIVE-BOARD CENSUS" must never present that as current — nor repaint
	# markers or feed caches from it.
	var checked_revision: int = int(_data.board_revision)
	var board: Dictionary = _promote_stripped_board()
	var gate_run: Dictionary = await run_promote_gate(board)
	if not bool(gate_run.get("ok", false)):
		return gate_run.get("reply", {"success": false, "error": "promotion_check_unavailable"})
	if _data == null or int(_data.board_revision) != checked_revision:
		return {"success": false, "error": "stale_census",
			"checked_board_revision": checked_revision,
			"current_board_revision": int(_data.board_revision) if _data != null else -1,
			"note": "the board changed while the census ran — the verdict describes revision %d, the board is now at %d; markers and caches were NOT touched. Re-run minerva_pcb_board_check." % [
				checked_revision, int(_data.board_revision) if _data != null else -1]}
	var gate: Dictionary = _dict_or_empty(gate_run.get("gate"))
	var reply: Dictionary = {
		"success": true,
		"promotable": bool(gate.get("promotable", false)),
		"refusals": gate.get("refusals", []),
		"connectivity": gate.get("connectivity", {}),
		"geometric": gate.get("geometric", {}),
		"assembly": gate.get("assembly", {}),
		"board_revision": checked_revision,
		# The declared copper stack (epoch GA-1): the census is the read agents
		# plan against, and what may be authored/routed is stack-dependent now.
		"layers": _data.layers.duplicate() if _data != null else [],
		"note": "read-only census — nothing was written, nothing was gated; these are the findings a promote would refuse on (empty refusals = it would pass)",
	}
	var advisory: Variant = gate.get("advisory", {})
	if advisory is Dictionary and not (advisory as Dictionary).is_empty():
		reply["advisory"] = advisory
	# F4 (Codex 1188): this census IS the authoritative assembly read — feed
	# the same cache workspace_commit's placement gate consults, at the
	# checked revision (a diagnostic cache write, not a board mutation).
	# Without it, an agent could board_check, SEE fresh findings, and commit
	# anyway because the gate's cache still said "never checked".
	var assembly: Variant = gate.get("assembly", {})
	if assembly is Dictionary and not (assembly as Dictionary).is_empty():
		set_assembly_state(assembly, checked_revision)
	# PARITY, narrowed honestly (F5, Codex 1188): only dangling_endpoint
	# findings become disconnect markers — that is the vocabulary the marker
	# channel actually renders (its self-heal looks for a trace endpoint on
	# the marker's net at the coordinate, and its label says "disconnected").
	# crossing / wrong_net_pad / layer_change_no_via findings ride the REPLY
	# with full fidelity; painting them as disconnects would be the panel
	# lying about what it knows. A clean census still clears healed markers.
	var markers: Array = []
	var conn: Variant = reply.get("connectivity", {})
	if conn is Dictionary:
		for f in ((conn as Dictionary).get("findings", []) as Array):
			if not (f is Dictionary):
				continue
			if str((f as Dictionary).get("type", "")) != "dangling_endpoint":
				continue
			var at: Variant = (f as Dictionary).get("at", null)
			if at is Array and (at as Array).size() >= 2:
				markers.append({
					"net": str((f as Dictionary).get("net", "")),
					"at": (at as Array).duplicate(),
					"message": "dangling endpoint on net '%s' at (%.2f, %.2f) — board_check census finding" % [
						str((f as Dictionary).get("net", "")),
						float((at as Array)[0]), float((at as Array)[1])],
				})
	if _canvas != null and _canvas.has_method("set_disconnect_markers"):
		_canvas.set_disconnect_markers(markers)
	return reply


func promote(explicit_path: String = "", allow_copper_regression: bool = false) -> Dictionary:
	if _data == null:
		return {"success": false, "error": "no_board"}
	# Path guards BEFORE the ipc guard: both are answerable without the
	# worker, and a caller with a bad target deserves the specific refusal
	# even when the backend is also down.
	var target := explicit_path.strip_edges()
	if target.is_empty():
		target = _canonical_source_path
	if target.is_empty():
		return {"success": false, "error": "no_target_path",
			"note": "no explicit path was given and this board was not loaded from a canonical YAML file (only minerva_pcb_load_board's path form adopts one) — pass path explicitly"}
	if target.get_extension().to_lower() == "pcbskel":
		return {"success": false, "error": "pcbskel_target", "path": target,
			"note": "promotion writes canonical YAML; writing it over a .pcbskel JSON document would destroy it — name a .yaml target"}
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return {"success": false, "error": "worker_unavailable",
			"note": "promotion needs the pcb backend for its DRC gate and serializer — plugin IPC not ready"}

	# ONE snapshot serves the gate AND the serializer below — the board must
	# not be re-derived across the gate's await (a user edit mid-gate would
	# split what was checked from what gets written).
	var board: Dictionary = _promote_stripped_board()

	# ── THE GATE, fail closed ────────────────────────────────────────────────
	var gate_run: Dictionary = await run_promote_gate(board)
	if not bool(gate_run.get("ok", false)):
		return gate_run.get("reply", {"success": false, "error": "promotion_check_unavailable"})
	var gate: Dictionary = _dict_or_empty(gate_run.get("gate"))
	if not bool(gate.get("promotable", false)):
		return {"success": false, "error": "promotion_gated",
			"refusals": gate.get("refusals", []),
			"connectivity": gate.get("connectivity", {}),
			"geometric": gate.get("geometric", {}),
			"assembly": gate.get("assembly", {}),
			"note": "promotion with correctness findings is impossible, not merely discouraged (K13, correctness-gated) — resolve the named findings and promote again; there is no acknowledge-through. Completeness is ADVISORY (owner ruling: promotion is granular)."}
	# UX4 station 9: the worker's advisory block (completeness — unrouted
	# nets) rides the reply and the status line; it never gates.
	var advisory: Dictionary = _dict_or_empty(gate.get("advisory"))

	# ── prior-file census, for the reply's what-changed ──────────────────────
	var census_delta: Dictionary = {}
	var prior_state := "absent"
	if FileAccess.file_exists(target):
		var prior_text := FileAccess.get_file_as_string(target)
		var prior_reply: Dictionary = _unwrap_channel_reply(
			await _request_with_backend_ensure("pcb.deserialize", {"yaml": prior_text}, 30000))
		var prior_board: Dictionary = _dict_or_empty(prior_reply.get("board"))
		if prior_board.is_empty():
			prior_state = "unreadable"
		else:
			prior_state = "parsed"
			census_delta = {
				"components": (board.get("components", []) as Array).size()
					- (prior_board.get("components", []) as Array).size(),
				"nets": (board.get("nets", []) as Array).size()
					- (prior_board.get("nets", []) as Array).size(),
				"traces": (board.get("traces", []) as Array).size()
					- (prior_board.get("traces", []) as Array).size(),
				"vias": (board.get("vias", []) as Array).size()
					- (prior_board.get("vias", []) as Array).size(),
			}
			# ── THE REGRESSION GUARD (UX4 station 9, DCR S6/A6) ──────────────
			# Granular promotion cuts both ways: promoting a PARTIAL board is
			# the owner's right, but silently WIPING copper the prior design
			# of record carried is the failure mode granularity invites — a
			# promote fired after "I rejected the GND candidate" must not
			# erase the GND pour the file already had. Per-net copper
			# presence mirrors the census's definition (traces ∪ zones ∪
			# netted vias — a pour COUNTS as copper). Component-count
			# regression rides the same guard. allow_copper_regression:true
			# (arg / dialog confirm) is the deliberate override.
			# GRANULARITY, ruled (Codex UX4 F2, owner-adjudicated): copper is
			# guarded at per-net PRESENCE — the DCR's own definition — not
			# per-entity identity, because trace edits are remove+add and an
			# identity compare would flag every legitimate reroute, teaching
			# users to always override. The KNOWN LIMIT is stated: removing
			# one of several traces on a net that keeps other copper is below
			# this guard's resolution. Components ARE identity-guarded (ref
			# SET, not count — refs are stable, so a swap that preserves the
			# count is still caught, with zero false positives).
			var prior_copper: Dictionary = _nets_with_copper(prior_board)
			var new_copper: Dictionary = _nets_with_copper(board)
			var regressed: Array = []
			for n in prior_copper:
				if not new_copper.has(n):
					regressed.append(str(n))
			regressed.sort()
			var removed_refs: Array = []
			var new_refs: Dictionary = {}
			for c in (board.get("components", []) as Array):
				if c is Dictionary:
					new_refs[str((c as Dictionary).get("ref", ""))] = true
			for c in (prior_board.get("components", []) as Array):
				if c is Dictionary and not new_refs.has(str((c as Dictionary).get("ref", ""))):
					removed_refs.append(str((c as Dictionary).get("ref", "")))
			removed_refs.sort()
			var comp_delta: int = int(census_delta.get("components", 0))
			if (not regressed.is_empty() or not removed_refs.is_empty()) \
					and not allow_copper_regression:
				return {"success": false, "error": "copper_regression",
					"regressed_nets": regressed,
					"removed_component_refs": removed_refs,
					"component_delta": comp_delta,
					"path": target,
					"note": "the prior design of record has copper/components this promotion would remove — pass allow_copper_regression:true (or confirm the dialog) to proceed deliberately"}

	# ── serialize + write ────────────────────────────────────────────────────
	var ser: Dictionary = await _request_with_backend_ensure(
		"pcb.serialize", {"board": board}, 30000)
	if not bool(ser.get("success", false)):
		return {"success": false, "error": "serialize_failed",
			"note": str(ser.get("error_message", ser.get("error_code", "")))}
	# UNWRAP the channel envelope exactly like the gate call above does
	# (CPN1 live find: the Go server wraps the handler's {yaml} as
	# {ok, result:{yaml}}, and the broker wraps THAT as {success, result:...} —
	# reading ser.result.yaml directly skips a layer and reported the promote
	# as "empty document" while 6KB of perfectly good YAML sat one level
	# deeper).
	var payload_dict: Dictionary = _unwrap_channel_reply(ser)
	var yaml_text := str(payload_dict.get("yaml", payload_dict.get("text", "")))
	if yaml_text.is_empty():
		# The serialize channel's REFUSALS are success-shaped ({error, bytes}
		# for payload_too_large) — surface them by name instead of the
		# misleading "empty document" this branch reported before CPN1.
		if str(payload_dict.get("error", "")) != "":
			return {"success": false,
				"error": str(payload_dict.get("error")),
				"bytes": int(payload_dict.get("bytes", 0)),
				"note": "pcb.serialize refused — nothing was written"}
		# Unwrap yielded nothing — surface whatever error the raw envelope
		# carried rather than a bare "empty document".
		var raw_result: Variant = ser.get("result", null)
		var inner_err := ""
		if raw_result is Dictionary:
			var e: Variant = (raw_result as Dictionary).get("error", "")
			inner_err = str((e as Dictionary).get("message", "")) if e is Dictionary else str(e)
		return {"success": false, "error": "serialize_failed",
			"note": inner_err if not inner_err.is_empty()
				else "pcb.serialize returned an empty document — nothing was written"}
	# ATOMIC tmp→rename (cold review F6): the design of record must never be
	# left half-truncated by a crash or full disk mid-write — the same
	# discipline the routing sidecar's writer already keeps.
	var tmp_path := target + ".promote.tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return {"success": false, "error": "write_failed", "path": target,
			"note": "could not open the temp file for writing (error %d)" % FileAccess.get_open_error()}
	f.store_string(yaml_text)
	var flush_err := f.get_error()
	f.close()
	if flush_err != OK:
		DirAccess.remove_absolute(tmp_path)
		return {"success": false, "error": "write_failed", "path": target,
			"note": "write to the temp file failed (error %d) — the target was not touched" % flush_err}
	var rename_err := DirAccess.rename_absolute(tmp_path, target)
	if rename_err != OK:
		DirAccess.remove_absolute(tmp_path)
		return {"success": false, "error": "write_failed", "path": target,
			"note": "atomic rename onto the target failed (error %d) — the target was not touched" % rename_err}

	var reply: Dictionary = {
		"path": target,
		"digest_sha256": yaml_text.sha256_text(),
		"bytes": yaml_text.length(),
		"prior_state": prior_state,
		"promote_check": {"promotable": true, "refusals": []},
	}
	if not census_delta.is_empty():
		reply["census_delta"] = census_delta
	# UX4 station 9: the advisory rides the success reply (absent when the
	# board is complete) + a staged-draft count so a caller knows review work
	# remains even though the promotion landed.
	if not advisory.is_empty():
		reply["advisory"] = advisory
	if _staged_entities != null and _staged_entities.staged_entries().size() > 0:
		reply["staged_drafts"] = _staged_entities.staged_entries().size()
	reply["success"] = true
	return reply


## Per-net copper presence — the CENSUS's own definition (traces ∪ zones ∪
## netted vias; a POUR counts as copper). The regression guard's read; static
## and board-dict-pure so the suite pins it headlessly.
static func _nets_with_copper(board: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for t in (board.get("traces", []) as Array):
		if t is Dictionary:
			var n := str((t as Dictionary).get("net", ""))
			if not n.is_empty():
				out[n] = true
	for z in (board.get("zones", []) as Array):
		if z is Dictionary:
			var zn := str((z as Dictionary).get("net", ""))
			if not zn.is_empty():
				out[zn] = true
	for v in (board.get("vias", []) as Array):
		if v is Dictionary:
			# Canonical dicts carry "net"; the GD model's via dicts carry
			# "net_name" — the guard reads whichever is present.
			var vn := str((v as Dictionary).get("net", (v as Dictionary).get("net_name", "")))
			if not vn.is_empty():
				out[vn] = true
	return out


## Unwrap the two envelope nestings the broker channels produce ({ok, result}
## worker envelope, possibly under {success, result}) into the inner result
## dict — {} when the reply is any failure shape. The same unwrap discipline
## board_health_check/_unwrap_draft_check apply, factored for promote's three
## channel hops.
static func _unwrap_channel_reply(reply: Dictionary) -> Dictionary:
	# FAILURE FIRST, result presence second (cold review F3): every LIVE
	# broker failure — the panel's own ipc-null reply and the host's
	# timeout/invalid replies — carries success:false with NO result key at
	# all. Guarding on `result is Dictionary` before reading `success` let
	# those fall through both unwrap layers and return VERBATIM as "the inner
	# result", so a 60s gate timeout read as a gated refusal with zero
	# refusals. Any explicit false is a failure regardless of shape.
	var layer: Dictionary = reply
	if layer.has("success"):
		if not bool(layer.get("success", false)):
			return {}
		if layer.get("result", null) is Dictionary:
			layer = layer.get("result")
	if layer.has("ok"):
		if not bool(layer.get("ok", false)):
			return {}
		return layer.get("result") if layer.get("result", null) is Dictionary else {}
	return layer


## The Promote button (station 11b): the same verb, refusals in a dialog that
## LISTS the gate's findings — informational only, no acknowledge-through.
func _on_promote_button_pressed() -> void:
	_set_status("Promotion gate: running full DRC + assembly…")
	var result: Dictionary = await promote()
	if bool(result.get("success", false)):
		var delta_txt := ""
		if result.get("census_delta", null) is Dictionary:
			var d: Dictionary = _dict_or_empty(result.get("census_delta"))
			delta_txt = "  •  Δ traces %+d, vias %+d" % [int(d.get("traces", 0)), int(d.get("vias", 0))]
		# UX4 station 9: the completeness ADVISORY on the success line — the
		# owner promoted a partial board on purpose; the status names what is
		# still unrouted rather than pretending done.
		var adv_txt := ""
		var completeness: Dictionary = _dict_or_empty(
			_dict_or_empty(result.get("advisory")).get("completeness"))
		if not completeness.is_empty():
			var missing: Array = completeness.get("missing_copper", [])
			adv_txt = "  •  ADVISORY: %d net(s) unrouted (%s)" % [missing.size(),
				", ".join(PackedStringArray(Array(missing.slice(0, 6).map(func(m): return str(m)))))]
		_set_status("PROMOTED → %s (%d bytes)%s%s" % [str(result.get("path", "")),
			int(result.get("bytes", 0)), delta_txt, adv_txt])
		return
	# UX4 station 9: the regression guard's dialog-confirm half — the named
	# refusal becomes a question, and ONLY an explicit confirm re-runs with
	# the override.
	if str(result.get("error", "")) == "copper_regression":
		var regressed: Array = result.get("regressed_nets", [])
		_set_status("Promotion held: copper regression (%d net(s)); see dialog." % regressed.size())
		if is_inside_tree():
			var confirm := ConfirmationDialog.new()
			confirm.name = "CopperRegressionDialog"
			confirm.title = "Promotion would remove copper"
			var removed_refs: Array = result.get("removed_component_refs", [])
			confirm.dialog_text = "The prior design of record has copper this promotion removes:\n\n%s%s\n\nPromote anyway? (The prior file is overwritten.)" % [
				"\n".join(PackedStringArray(Array(regressed.map(func(r): return "• net %s" % str(r))))),
				("\n• component(s) removed: %s" % ", ".join(PackedStringArray(Array(removed_refs.map(func(r): return str(r))))))
					if not removed_refs.is_empty() else ""]
			confirm.ok_button_text = "Promote anyway"
			add_child(confirm)
			confirm.confirmed.connect(func() -> void:
				_set_status("Promotion gate: re-running with regression override…")
				var forced: Dictionary = await promote("", true)
				if bool(forced.get("success", false)):
					_set_status("PROMOTED (regression confirmed) → %s" % str(forced.get("path", "")))
				else:
					_set_status("Promotion failed (%s): %s" % [str(forced.get("error", "")),
						str(forced.get("note", ""))]))
			confirm.visibility_changed.connect(func() -> void:
				if not confirm.visible:
					confirm.queue_free())
			confirm.popup_centered()
		return
	if str(result.get("error", "")) == "promotion_gated":
		var refusals: Array = result.get("refusals", [])
		_set_status("Promotion refused — %d gate failure(s); see dialog." % refusals.size())
		if is_inside_tree():
			var dialog := AcceptDialog.new()
			dialog.name = "PromotionGateDialog"
			dialog.title = "Promotion gate: the board is not clean"
			dialog.dialog_text = "K13 (correctness-gated): promotion with correctness findings is impossible. Completeness is advisory — a partial board promotes.\n\n%s\n\nResolve the findings (Check, witnesses, assembly) and promote again." \
				% "\n".join(PackedStringArray(Array(refusals.map(func(r): return "• %s" % str(r)))))
			add_child(dialog)
			dialog.popup_centered()
			dialog.visibility_changed.connect(func() -> void:
				if not dialog.visible:
					dialog.queue_free())
		return
	_set_status("Promotion failed (%s): %s" % [str(result.get("error", "unknown")),
		str(result.get("note", ""))])


## Router bridge (route-correction loop, agent-router child 019eb47eb567). Builds
## the worker `route` request from the LIVE board + the host's route-hint
## annotations and drives it over the plugin IPC channel the same way YAML export
## drives pcb.serialize. Returns the worker's {ok, result:{success, routes,
## unrouted, via_count, …}} envelope verbatim, or a structured worker_unavailable
## when the IPC channel is not ready / times out — the caller
## (host.run_router → MCPPcbPanelTools.minerva_pcb_apply_route_hints) turns that
## into failure-as-feedback rather than crashing.
##
## "pcb.route" is a declared broker channel (manifest.json ipc_channels) forwarded
## to the worker `route` method (internal/tools RouteChannel/HandleRouteChannel,
## bug 019f3815e9f9). The route-correction loop is LIVE; worker_unavailable is
## returned only when the IPC channel is genuinely not ready (panel not mounted).
## `extra` is optional: {"scope": <route_bridge.parse_route_scope shape>,
## "pinned_candidates": <route_bridge.existing_copper_with_pinned shape>} — the
## GD-side half of DCR finding 7 (worker route() shipped both params in C2;
## nothing on this side reached them). Keys are stamped onto `params` ONLY when
## `extra` supplies them, so every existing caller (there are several — grep
## `route_board(`/`run_router(`, all still passing one argument) gets the
## EXACT pre-existing {board, route_hints, selection} payload, byte-for-byte;
## an absent key is also already what the worker treats "unscoped run" /
## "no pinned overlay" to mean (see parse_route_scope / existing_copper_with_pinned
## docstrings), so this is additive, never a behavior change on its own.
## Epoch UX4 station 3 (DCR S3/A2): the board a route request carries. A
## DRAFT request (extra.draft_request — set by the candidate-producing
## callers: workspace propose, reroute, apply_route_hints commit=false) gets
## the COMPOSED effective draft board, so staged keepouts detour the ghosts;
## a direct-copper request (commit=true) routes against the REAL board only.
## draft_request is a PANEL-SIDE marker: route_board's params allow-list
## below never forwards it to the worker. Factored out of route_board so the
## headless suite can pin the composition decision without an IPC backend.
func _board_for_route_request(extra: Dictionary) -> Dictionary:
	var board: Dictionary = _data.to_board_dict()
	if bool(extra.get("draft_request", false)):
		return _PcbStagedEntitiesScript.effective_draft_board(board, _staged_entities, "route")
	return board


## F1 (Codex 1188): stamp route_board's compose-time draft context onto a
## SUCCESSFUL reply envelope — failures carry none (nothing landed, nothing
## to attribute). Top-level beside ok/result: panel-side metadata, never part
## of the worker's own result shape.
static func _with_draft_context(reply: Dictionary, ctx: Dictionary) -> Dictionary:
	if not ctx.is_empty() and bool(reply.get("ok", false)):
		reply["draft_context"] = ctx
	return reply


func route_board(selection: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null or _data == null:
		return {"ok": false, "error": {"kind": "worker_unavailable",
			"message": "plugin IPC channel not ready"}}
	# F1 (Codex OFC review 1188): the DRAFT CONTEXT — which ghost poses and
	# which board revision the composed request will carry — is captured HERE,
	# in the same synchronous stretch as the composition below (no await
	# between this line and _board_for_route_request), and attached to the
	# reply envelope. The ingest layers consume the reply's context and never
	# re-sample: a ghost rejected, retargeted, or newly staged while the
	# worker runs must not rewrite the provenance of copper that was routed
	# against the OLD world.
	var draft_context: Dictionary = {}
	if bool(extra.get("draft_request", false)):
		draft_context = {
			"board_revision": int(_data.board_revision),
			"draft_placements": _PanelToolsScript._live_placement_snapshot_from_store(_staged_entities),
		}
	var envelopes: Array = []
	if _annotation_host != null and _annotation_host.has_method("get_all_annotations"):
		for ann in _annotation_host.get_all_annotations():
			if ann is Dictionary and str((ann as Dictionary).get("kind", "")) == "pcb_route_hint":
				# Per-hint revision/redo history never leaves the editing
				# session (C4 deliverable 1 contract: "excluded from
				# route-request building") — strip before it reaches the
				# router worker over IPC.
				if _annotation_host.has_method("strip_hint_history"):
					envelopes.append(_annotation_host.strip_hint_history(ann as Dictionary))
				else:
					envelopes.append(ann)
	var params := {
		"board": _board_for_route_request(extra),
		"route_hints": envelopes,
		"selection": selection,
	}
	if extra.has("scope"):
		params["scope"] = extra["scope"]
	if extra.has("pinned_candidates"):
		params["pinned_candidates"] = extra["pinned_candidates"]
	# HITL-4 live bug (Codex 1047 epoch, found in the first post-boundary
	# owner round): this allow-list predates Epoch UX1 station 9, so the
	# task_constraints half of `extra` — the ONLY channel through which a
	# task's routing_constraint corridor reaches the router — was silently
	# dropped on the LIVE path. Every surrounding layer was tested against a
	# double of this function (panel_tools against RouterShim, route_bridge
	# against pytest fixtures), so both suites were green while production
	# steering was a no-op: candidates landed with no constraint_revision, no
	# adherence, and geometry that ignored the authored corridor.
	if extra.has("task_constraints"):
		params["task_constraints"] = extra["task_constraints"]
	var result: Dictionary = await _request_with_backend_ensure("pcb.route", params, 30000)
	# The worker returns {ok, result}; the host IPC wrapper may nest it under
	# "result"/"success" — normalise to the worker envelope the apply tool wants.
	if result.has("ok"):
		return _with_draft_context(result, draft_context)
	if bool(result.get("success", false)) and result.get("result", null) is Dictionary:
		var inner: Dictionary = _dict_or_empty(result.get("result"))
		# Live broker shape: MinervaIPC wraps the backend reply in
		# {success, result} while the Go side forwards the worker's own
		# {ok, result} envelope verbatim (HandleRouteChannel) — so the
		# worker envelope arrives one level deeper than the direct-stdio
		# path. Unwrap it rather than re-wrapping (HITL-2 live bug: the
		# apply tool read routes one level too high and proposed nothing).
		if inner.has("ok"):
			return _with_draft_context(inner, draft_context)
		return _with_draft_context({"ok": true, "result": inner}, draft_context)
	# Backend-stopped detection (C5, docket 019f6c465fd8, bug 019f6c1e0399):
	# when the pcb backend subprocess is not RUNNING,
	# PluginScenePanelBroker._dispatch_to_plugin_backend replies with
	# PluginErrors.plugin_not_running(plugin_id) — {success:false,
	# error_code:"plugin_not_running", error_message:"Plugin is not running"} —
	# verbatim (no "ok" key, so it falls through the two checks above). Tag it
	# distinctly from the generic worker_error fallback so panel_tools.gd's
	# _router_unavailable (and the Propose button) can surface a
	# human-actionable "start it" message instead of an opaque routing
	# failure. error_message is ALSO matched by substring (not just the code)
	# so a differently-worded future PluginErrors message still degrades
	# correctly.
	var code := str(result.get("error_code", ""))
	var msg := str(result.get("error_message", ""))
	if code == "plugin_not_running" or msg.findn("not running") != -1:
		return {"ok": false, "error": {"kind": "plugin_not_running",
			"message": msg if not msg.is_empty() else "Plugin is not running",
			"hint": "start via minerva_plugin_start"}}
	return {"ok": false, "error": {"kind": "worker_error",
		"message": str(result.get("error_message", result.get("error", "route failed")))}}


## Whole-board load (minerva_pcb_load_board): parse canonical YAML via the Go
## backend's pcb.deserialize channel, then rebuild the live board from the
## returned canonical dict in ONE call — replacing the multi-call add_component /
## connect_net / import_footprint_geometry / import_trace_geometry sequence.
## Async, mirroring the pcb.serialize / route_board await pattern. Returns
## {ok, result:{component_count, net_count, warnings}} or {ok:false, error:{…}}.
func load_board_from_yaml(yaml_text: String, source_path: String = "") -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null or _data == null:
		return {"ok": false, "error": {"kind": "worker_unavailable",
			"message": "plugin IPC channel not ready"}}
	var result: Dictionary = await _request_with_backend_ensure("pcb.deserialize", {"yaml": yaml_text}, 30000)

	# Unwrap the deserialize reply. HandleDeserialize returns {board, warnings};
	# the broker/worker path nests that under one or more {ok|success, result:{…}}
	# envelopes (the live shape is {ok, result:{board, warnings}}). Recurse through
	# `result` wrappers to the dict that directly carries `board`.
	var payload = _unwrap_to_board(result)
	if payload == null:
		var code := str(result.get("error_code", ""))
		var msg := str(result.get("error_message", result.get("error", "deserialize failed")))
		if code == "plugin_not_running" or msg.findn("not running") != -1:
			return {"ok": false, "error": {"kind": "plugin_not_running",
				"message": msg, "hint": "start via minerva_plugin_start"}}
		return {"ok": false, "error": {"kind": "worker_error", "message": msg}}

	var board: Dictionary = _dict_or_empty(payload.get("board"))
	var warnings: Array = payload.get("warnings", [])

	# Rebuild the live board (from_board_dict emits data_changed; suppress the
	# dirty relay for the whole load like the project-file restore path).
	_restoring = true
	_data.from_board_dict(board)

	# SIDECAR ADOPTION (Epoch UX2 station 8, docket 019fde57027c — the HITL-4
	# loss: annotations authored against a file-loaded canonical YAML lived
	# only in the panel host and died with the app, because no document path
	# was ever adopted and so no sidecar was ever written). When the load
	# names its on-disk source:
	#   * the panel adopts it as _file_path and the host's document path —
	#     the annotation auto-writer (see _schedule_sidecar_autosave) and the
	#     Ctrl+S flush now have a durable home;
	#   * an EXISTING <path>.annotations.json is restored (the read half
	#     always worked — it just never ran on this path);
	#   * no sidecar on disk keeps the LIVE annotations as they stand (a
	#     load_sidecar miss is a no-op) — first import must not wipe what was
	#     authored this session; the auto-writer persists them to the new
	#     home on the next mutation.
	var sidecar_restored := 0
	if not source_path.is_empty():
		var prior_path := _file_path
		# A DIFFERENT prior document (Codex 1049 finding 2): its annotations
		# and workspace state belong to IT, not to the incoming board.
		var switched := not prior_path.is_empty() and prior_path != source_path
		# Cold review F2: a mutation still inside the debounce window must be
		# flushed to its CURRENT home before the path (and possibly the whole
		# annotation list) changes under it — otherwise the pending timer
		# later writes a stale/replaced list, cementing the loss.
		if _sidecar_autosave_pending and _annotation_host != null and not prior_path.is_empty():
			_sidecar_autosave_pending = false
			_annotation_host.save_sidecar(prior_path)
		_file_path = source_path
		# The canonical-source record promotion's implicit target reads (F2)
		# — this assignment exists ONLY here, on the YAML-load adoption.
		_canonical_source_path = source_path
		if _annotation_host != null:
			_annotation_host.set_document_path(source_path)
			if AnnotationSidecar.has_sidecar(source_path):
				sidecar_restored = int(_annotation_host.load_sidecar(source_path))
			elif switched:
				# Codex 1049 finding 2: the previous document's annotations
				# must not attach to a board they were never authored
				# against. They are safe in the prior sidecar (the flush
				# above + the auto-writer keep it current).
				_annotation_host.clear_annotations_for_document_switch()
			elif not _annotation_host.get_annotations().is_empty():
				# Cold review F1: adoption alone must make the LIVE
				# annotations durable immediately — "the next mutation will
				# write them" is exactly the restart-loss window this
				# station closes (author → import-by-path → restart). Only
				# for a FIRST adoption (no prior document): this session's
				# unhomed annotations belong to the newly adopted file.
				_annotation_host.save_sidecar(source_path)
		# Cold review F3: the ROUTING sidecar's load half must ride the same
		# adoption, or the first Ctrl+S at the new path deletes/clobbers an
		# existing <source>.routing.json that was never read (save writes at
		# _file_path; zero candidates deletes the file). The fingerprint
		# coherence gate inside load_into_workspace already rejects a stale
		# sidecar for a changed board. On a SWITCH the workspace is RESET
		# first (Codex 1049 finding 2, routing half): the prior document's
		# candidates/tasks must not stay live over the new board when it has
		# no routing sidecar of its own.
		if _routing_workspace != null:
			if switched:
				_routing_workspace.load_from_dict({})
			# UX4 S9: the staged store rides the same load (drafts restore even
			# on quarantine; a missing sidecar RESETS a bound store so a
			# document switch drops the prior board's drafts). Inside the
			# _restoring gate — load_from_dict emits `changed` unconditionally.
			_PcbRoutingSidecarScript.load_into_workspace(
				source_path, _routing_workspace, _data.to_board_dict(), 0, _staged_entities)
	_restoring = false

	# Reflect the new board in the toolbar/status and frame it in the canvas —
	# _on_data_changed only queue_redraw()s, it does not refit, so mirror the
	# file-open path (which does exactly this) or the capture shows the stale view.
	_refresh_board_ui()
	_zoom_to_fit_deferred()

	# LOAD-TIME BOARD HEALTH (Epoch UX2 station 9, docket 019fde571300 —
	# subsuming work item 019fd5fe1241's assembly-only advisory): ONE
	# pcb.board_health round-trip over the DESERIALIZED board dict — the
	# enriched dict carrying the worker-attached courtyard graphics (the live
	# board's own to_board_dict() may not round-trip them) — yields the same
	# ledger a route reply carries: completeness census ("8 nets unrouted,
	# GND in 9 islands") + the tri-state assembly verdict, at open, before
	# any routing verb. The reply keeps the established `assembly` key (read
	# out of the ledger) AND attaches the full `board_health` with the same
	# panel enrichment the propose path applies (board_revision, preflight,
	# pin_groups int-normalization, cache feed — _attach_board_health).
	# DEGRADE: an old binary without the channel falls back to the plain
	# assembly_check round-trip — assembly still attaches, board_health is
	# simply absent. A failure NEVER blocks the load and is never silent.
	var assembly: Dictionary
	var load_result := {
		"component_count": _data.get_component_count(),
		"net_count": _data.nets.size(),
		"warnings": warnings,
	}
	var health_reply: Dictionary = await board_health_check(board)
	if bool(health_reply.get("ok", false)) and health_reply.get("result", null) is Dictionary:
		var health: Dictionary = _dict_or_empty(health_reply.get("result"))
		assembly = _PanelToolsScript._assembly_tri_state(
			{"ok": true, "result": health.get("assembly", {})})
		_PanelToolsScript._attach_board_health(
			_annotation_host, load_result, {"board_health": health})
	else:
		assembly = _PanelToolsScript._assembly_tri_state(await assembly_check(board))
	load_result["assembly"] = assembly
	set_assembly_state(assembly, int(_data.board_revision))

	if not source_path.is_empty():
		load_result["annotations_sidecar"] = "adopted"
		if sidecar_restored > 0:
			load_result["annotations_restored"] = sidecar_restored
	return {"ok": true, "result": load_result}


## Recursively unwrap broker/worker envelopes ({ok|success, result:{…}}) down to
## the dict that directly carries a `board` key. Returns that dict (board +
## warnings siblings) or null when no board is present.
func _unwrap_to_board(v) -> Variant:
	if not (v is Dictionary):
		return null
	if v.get("board", null) is Dictionary:
		return v
	if v.get("result", null) is Dictionary:
		return _unwrap_to_board(v.get("result"))
	return null


## On-demand routing draft-check (T2.4). Production wiring for the reusable NATIVE
## draft-check seam T5 depends on: computes the current board coherence token,
## has the routing workspace build the request (flipping the checked candidates
## to "checking"), forwards it over the DECLARED pcb.draft_check broker channel
## with the live board attached, awaits the worker reply, and hands it back to
## workspace.apply_check_result — which GUARDS on the echoed board_token +
## workspace_generation (+ per-candidate revision) before writing any verdict, so
## a stale reply can never mark a candidate clean. Async, mirroring the
## pcb.serialize / route_board await pattern.
##
## ON-DEMAND ONLY. Debounce/coalescing/cancellation/auto-recheck are T6.
##
## Like route_board's live worker hop, the full broker→worker round-trip does not
## run under the headless gd scaffold (no _MinervaIPC backend there); the seam is
## covered by the worker pytest (draft_check) + the gd state-machine test
## (begin_check/apply_check_result with a fake reply). When the IPC channel is not
## ready the checked candidates are reverted (apply_check_result discards an empty
## reply), never left stuck on "checking". Returns the draft_check result dict on
## success, or {} when the hop could not run.
func check_draft(candidate_ids: Array = []) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null or _data == null or _routing_workspace == null:
		if _routing_workspace != null:
			# Still flip+revert so a caller sees a coherent no-op, not stuck state.
			_routing_workspace.begin_check(candidate_ids)
			_routing_workspace.apply_check_result({})
		return {}

	# Board coherence token = the SAME fingerprint the durable sidecar guards
	# with, and it is computed from the CANONICAL board deliberately. The token
	# answers "is the real board still what this reply was scored against"; the
	# draft overlay is request-scoped and must never enter it, or the sidecar's
	# guard would compare against a fingerprint no persisted board can ever have.
	var board_dict: Dictionary = _data.to_board_dict()
	_routing_workspace.board_token = _PcbRoutingSidecarScript.compute_board_fingerprint(board_dict)

	var payload: Dictionary = _routing_workspace.begin_check(candidate_ids)
	var composed: Dictionary = draft_check_board()
	payload["board"] = composed
	# DRAFT-OVERLAY COHERENCE (epoch GA cold review, finding 3). The two guards
	# apply_check_result already runs cover the canonical board (board_token)
	# and the candidate set (workspace_generation) — NEITHER covers the staged
	# overlay, which became scored input the moment this method started sending
	# it. A ghost dragged while the worker is thinking would otherwise land a
	# verdict computed for a pose that no longer exists, and it would land it
	# as CLEAN: the exact false-clean K14 forbids. So fingerprint the composed
	# board before the hop and re-derive it after; any drift discards the whole
	# reply through the same revert path an unreachable worker takes.
	#
	# V2, NOT V1, and the difference is load-bearing (epoch GA re-review,
	# finding 1). The v1 subset has no zones key — its own successor's
	# docstring says so — while the composer's whole job for this purpose is to
	# append staged ZONES beside placements. Under v1 the guard would have been
	# real for a dragged placement and DECORATIVE for a staged or rejected
	# zone, i.e. blind to half the input class K9 named. Nothing constrains the
	# choice here: this token is request-local and only ever compared with
	# itself, unlike workspace.board_token above, which must stay v1 because it
	# is compared against the durable sidecar's own fingerprint.
	var draft_token: String = _PcbRoutingSidecarScript.compute_board_fingerprint_v2(composed)

	var reply_id := "pcb.draft_check:%d" % Time.get_ticks_usec()
	request.emit("pcb.draft_check", payload, reply_id)
	var result: Dictionary = await ipc.await_reply(reply_id, 30000)

	# Unwrap to the worker's draft_check result dict ({board_token,
	# workspace_generation, findings, per_candidate}). The broker may nest the
	# worker {ok, result} envelope one level deeper under {success, result}
	# (same shape route_board unwraps). apply_check_result guard-discards an
	# empty/mismatched reply, so a failed unwrap safely reverts the candidates.
	# The overlay guard, before the reply is allowed to write anything. Discard
	# is fail-safe and reuses apply_check_result's empty-reply path, which
	# reverts every candidate begin_check flipped to "checking" rather than
	# leaving them stuck.
	#
	# The fingerprint comparison is SELF-GUARDING, so there are no null clauses
	# here: draft_check_board() degrades to {} with no board and to the
	# canonical board with no store, and either way the re-derived hash cannot
	# equal a token taken when the state was different. An explicit
	# `_staged_entities == null` test would additionally have contradicted that
	# seam's documented degrade-don't-refuse contract (re-review note).
	if _PcbRoutingSidecarScript.compute_board_fingerprint_v2(draft_check_board()) != draft_token:
		_routing_workspace.apply_check_result({})
		return {}

	var inner: Dictionary = _unwrap_draft_check(result)
	_routing_workspace.apply_check_result(inner)
	return inner


## The board draft DRC scores: canonical geometry plus the LIVE staged overlay
## (staged and frozen placements, staged zones). This is K9's materialized
## proposal board (019fa6ed5e23) and it is a NAMED SEAM rather than an inline
## expression so the wiring itself is assertable — the cold review's finding 4
## was that composing correctly and actually SENDING the composition are two
## different claims, and only the first had a test.
##
## Request-scoped by contract: the result is sent and dropped, never serialized
## and never fed to any cache keyed to the real board (A9/K5). Fail-safe by
## construction — an absent store composes nothing and the caller degrades to
## the canonical board rather than refusing.
func draft_check_board() -> Dictionary:
	if _data == null:
		return {}
	var canonical: Dictionary = _data.to_board_dict()
	if _staged_entities == null:
		return canonical
	return _PcbStagedEntitiesScript.effective_draft_board(
		canonical, _staged_entities, "geometric")


## On-demand assembly advisory check (DCR 019fd5fd9084, work items
## 019fd5fe1241/019fd5fe2724). Drives the DECLARED pcb.assembly_check broker
## channel — which forwards to the Python worker's "assembly_check" method
## (internal/tools/worker_tools.go AssemblyCheckChannel) — with a canonical
## board dict, and normalizes the reply to the worker envelope {ok, result:
## {status, findings, indeterminate?, error?}} the same way route_board does
## for pcb.route. Callers (panel_tools' load/placement seams) convert failures
## to a tri-state {status:"indeterminate", error} via
## panel_tools._assembly_tri_state — an unreachable worker degrades to an
## honest "could not check", never a crash and never a silent pass.
## Async, mirroring the pcb.serialize / route_board await pattern.
## MCP selection read (HITL-6b, docket 019fdf5579): whatever the human has
## selected on the canvas right now, by kind, plus the routing workspace's
## active candidate — the seam behind minerva_pcb_get_selection, so "I've
## selected X — what is it?" is answerable. {} headless (no canvas mounted).
func get_selection_state() -> Dictionary:
	var out: Dictionary = {}
	if _canvas != null and _canvas.has_method("selection_snapshot"):
		out = _canvas.selection_snapshot()
	if _routing_workspace != null:
		out["active_candidate_id"] = str(_routing_workspace.active_candidate_id)
	return out


## Whole-board health without a routing run (Epoch UX2 station 9, docket
## 019fde571300): the pcb.board_health channel — census + assembly, the same
## object a route reply's board_health carries. Same envelope normalisation
## as assembly_check below.
func board_health_check(board: Dictionary) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return {"ok": false, "error": {"kind": "worker_unavailable",
			"message": "plugin IPC channel not ready"}}
	var result: Dictionary = await _request_with_backend_ensure(
		"pcb.board_health", {"board": board}, 30000)
	if result.has("ok"):
		return result
	if bool(result.get("success", false)) and result.get("result", null) is Dictionary:
		var inner: Dictionary = _dict_or_empty(result.get("result"))
		if inner.has("ok"):
			return inner
		return {"ok": true, "result": inner}
	return {"ok": false, "error": {"kind": "worker_error",
		"message": str(result.get("error_message", result.get("error", "board_health failed")))}}


## pcb.mask_view round-trip (WYSIWYG G4) — same channel idiom as
## board_health_check directly above.
func mask_view_check(board: Dictionary) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return {"ok": false, "error": {"kind": "worker_unavailable",
			"message": "plugin IPC channel not ready"}}
	var result: Dictionary = await _request_with_backend_ensure(
		"pcb.mask_view", {"board": board}, 30000)
	if result.has("ok"):
		return result
	if bool(result.get("success", false)) and result.get("result", null) is Dictionary:
		var inner: Dictionary = _dict_or_empty(result.get("result"))
		if inner.has("ok"):
			return inner
		return {"ok": true, "result": inner}
	return {"ok": false, "error": {"kind": "worker_error",
		"message": str(result.get("error_message", result.get("error", "mask_view failed")))}}


## Refetch the mask overlay from the worker and hand it to the canvas. The
## overlay is only ever what Projection.mask said — on ANY failure the canvas
## gets an empty set plus a visible note, never a stale set drawn as current
## (a KNOWN-INCOMPLETE aperture set shown as complete is the false-clean
## direction GC8 refuses a verdict over).
func _refresh_mask_view() -> void:
	if _canvas == null or _data == null:
		return
	var reply: Dictionary = await mask_view_check(_data.to_board_dict())
	if _canvas == null or not bool(_canvas.get("show_mask")):
		return  # toggled off (or panel torn down) while the worker ran
	if not bool(reply.get("ok", false)):
		var err: Dictionary = _dict_or_empty(reply.get("error"))
		_canvas.set_mask_view([], "unavailable — " + str(err.get("message", err.get("kind", "unknown"))))
		return
	var result: Dictionary = _dict_or_empty(reply.get("result"))
	var indeterminate: Array = result.get("indeterminate", [])
	var note := ""
	if not indeterminate.is_empty():
		note = "INCOMPLETE — %d entity/entities undetermined" % indeterminate.size()
	_canvas.set_mask_view(result.get("openings", []), note)


## Debounced refetch on board mutation, active only while the overlay is shown.
## Between the mutation and the refetch landing, the overlay is marked stale
## rather than silently drawn as current.
var _mask_view_refresh_pending := false
func _schedule_mask_view_refresh() -> void:
	if _canvas == null or not bool(_canvas.get("show_mask")):
		return
	_canvas.set_mask_view(_canvas.mask_openings, "stale — board changed, refreshing")
	if _mask_view_refresh_pending or not is_inside_tree():
		return
	_mask_view_refresh_pending = true
	get_tree().create_timer(0.5).timeout.connect(func() -> void:
		_mask_view_refresh_pending = false
		_refresh_mask_view())


func assembly_check(board: Dictionary) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return {"ok": false, "error": {"kind": "worker_unavailable",
			"message": "plugin IPC channel not ready"}}
	var result: Dictionary = await _request_with_backend_ensure(
		"pcb.assembly_check", {"board": board}, 30000)
	# Same envelope normalisation as route_board: direct worker {ok, result},
	# or the broker's {success, result:{ok, result}} double wrap.
	if result.has("ok"):
		return result
	if bool(result.get("success", false)) and result.get("result", null) is Dictionary:
		var inner: Dictionary = _dict_or_empty(result.get("result"))
		if inner.has("ok"):
			return inner
		return {"ok": true, "result": inner}
	var code := str(result.get("error_code", ""))
	var msg := str(result.get("error_message", ""))
	if code == "plugin_not_running" or msg.findn("not running") != -1:
		return {"ok": false, "error": {"kind": "plugin_not_running",
			"message": msg if not msg.is_empty() else "Plugin is not running",
			"hint": "start via minerva_plugin_start"}}
	return {"ok": false, "error": {"kind": "worker_error",
		"message": str(result.get("error_message", result.get("error", "assembly_check failed")))}}


## Dig the draft_check result dict out of whatever envelope the broker returned.
func _unwrap_draft_check(result: Dictionary) -> Dictionary:
	var r: Dictionary = result
	# Broker wrap: {success, result:{ok, result:{…}}} → step into the worker envelope.
	if r.has("result") and r.get("result") is Dictionary and (r.get("result") as Dictionary).has("ok"):
		r = r.get("result")
	# Worker envelope: {ok, result:{…}} → the inner result is what we want.
	if r.has("ok") and r.get("result") is Dictionary:
		r = r.get("result")
	# A well-formed draft_check result carries per_candidate; else treat as no-op.
	if r.has("per_candidate") or r.has("board_token"):
		return r
	return {}


# ── Status / board-size UI ────────────────────────────────────────────────────

func _update_board_size_label() -> void:
	if _board_size_label != null and _data != null:
		_board_size_label.text = "Board: %s×%smm" % [_data.board_width, _data.board_height]


## The ONE status-text writer: the label ellipsizes on overflow (see its
## build-site comment), so the tooltip always carries the full text — hover
## recovers whatever a narrow pane trimmed.
func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
		_status_label.tooltip_text = text


## While-armed gesture grammar (docket 019fb933d4a9): the teaching prose that
## used to live in the tool tooltips (now one clause each — see the
## _wrap_tooltip call sites) relocates HERE, not to a toast. This is a live
## status readout that stays visible for as long as the tool is armed, unlike
## _show_transient_status's 2s toast — the right lifetime for something a user
## needs to read while they work, not glance at once.
##
## Keyed by ToolMode; the route-flow cluster's tools (single_trace/edit_hint/
## add_via, WC-3/C4/U4) aren't in that enum — they arm an AnnotationAuthorTool
## on the shared overlay instead of driving _canvas.tool_mode — so they're
## looked up separately, off _active_route_flow_kind, below.
const _MODE_HINTS := {
	1: "Drag a part to move · drag empty to box-select · R rotates",     # SELECT
	5: "Click a pin to see its info",                                    # INSPECT_PIN
	6: "Pick a net below, click each corner, Enter/dbl-click to close",  # ZONE_POUR
	7: "Click each corner, Enter/dbl-click to close (no net needed)",    # ZONE_KEEPOUT
	8: "Click a pad to start, click waypoints, click a pad to finish",   # TRACE
	9: "Click an entity to delete it (Esc to disarm)",                   # ERASER
	10: "Click each corner, Enter/dbl-click to close (no net needed)",  # CUTOUT
	11: "Click pads/traces to pick nets (2+), Enter to draw the spine, then click vertices and Enter/dbl-click to commit",  # BUS
}
const _ROUTE_FLOW_LABELS := {
	"single_trace": "Single Trace",
	"edit_hint": "Edit Hint",
	"add_via": "Add Via",
}
const _ROUTE_FLOW_HINTS := {
	"single_trace": "Click a pad/point, waypoints, then a pad to finish",
	"edit_hint": "Drag a handle to move a bend, right-click to delete it",
	"add_via": "Click the proposal, then a point on its route to add a via",
}


func _update_status() -> void:
	if _status_label == null or _canvas == null or _data == null:
		return
	var sel: Array = _canvas.get_selected_components()
	# Indexed by ToolMode: NONE, SELECT, TRANSLATE, ROTATE, PAN, INSPECT_PIN,
	# ZONE_POUR, ZONE_KEEPOUT, TRACE, ERASER, CUTOUT, BUS. BUG FIX: this array
	# used to stop at 9 entries (through TRACE) while ToolMode.ERASER = 9 —
	# tm < size() was false for the eraser, so it silently got no mode tag at
	# all. ERASER is entry 9; CUTOUT (campaign 2 epoch B, unit 3) is entry 10;
	# BUS (campaign 2 epoch C, unit 5) is APPENDED as entry 11 —
	# ToolMode.BUS is the enum's new last member, so this stays correct
	# WITHOUT renumbering anything above it (see the enum's own append-only doc).
	var mode_names := ["", "Select", "Move", "Rotate", "Pan", "Inspect Pin", "Pour", "Keepout", "Trace", "Eraser", "Cutout", "Bus"]
	var mode_txt := ""
	var armed_hint := ""
	if _active_route_flow_kind != "":
		mode_txt = "  [%s]" % _ROUTE_FLOW_LABELS.get(_active_route_flow_kind, "")
		armed_hint = str(_ROUTE_FLOW_HINTS.get(_active_route_flow_kind, ""))
	else:
		var tm: int = _canvas.tool_mode
		if tm > 0 and tm < mode_names.size():
			mode_txt = "  [%s]" % mode_names[tm]
		armed_hint = str(_MODE_HINTS.get(tm, ""))
	var hint := "  •  wheel/pinch zoom · Pan tool or Space/right/middle-drag to pan"
	if not armed_hint.is_empty():
		hint = "  •  %s" % armed_hint
	# Below wide mode the toolbar's board-size label is hidden — carry it here
	# (unchanged). BUG FIX: the gesture hint above used to be blanked here too,
	# for EVERY non-wide mode — but a 3-col pane does not reliably land in any
	# one mode: mode selection is WIDTH-based (panel_layout.gd) and deliberately
	# hardware-dependent — on a large display a 3-col pane classifies WIDE, not
	# MEDIUM (owner ruling 019fbb7115: status quo px thresholds kept, "3 col is
	# probably good enough"; there is no single PRIMARY design-target width).
	# Blanking the hint at every non-wide width therefore hid the armed tool's
	# grammar at ordinary panel sizes, defeating the very teaching this round
	# moved here. Only NARROW (sidebar behind a drawer, toolbar folded into a
	# View menu — already the one mode that compacts every other secondary
	# readout) still drops it; MEDIUM keeps both the board size AND the hint.
	var board_txt := ""
	if _layout_mode != _PanelLayoutScript.MODE_WIDE:
		board_txt = "  •  %s×%smm" % [_data.board_width, _data.board_height]
	if _layout_mode == _PanelLayoutScript.MODE_NARROW:
		hint = ""
	# Epoch UX3 station 3 (docket 019fdf90662a): the steady-state readout
	# counted components but never candidates — the ghost tally joins it,
	# present only while live ghosts exist so the common no-proposals state is
	# byte-identical to before.
	var ghost_txt := ""
	var ghost_summary := _ghost_status_summary()
	if not ghost_summary.is_empty():
		ghost_txt = "  •  %s" % ghost_summary
	_set_status("%d parts, %d nets, %d traces  •  %d selected%s%s%s%s" % [
		_data.get_component_count(), _data.get_net_count(), _data.get_trace_count(),
		sel.size(), mode_txt, ghost_txt, board_txt, hint])


## Reflect the current model into the toolbar + canvas (after a load).
func _refresh_board_ui() -> void:
	_rebuild_layer_option()
	_rebuild_zone_net_option()
	# The Draw tools' other two arming controls follow the same load rule: a new
	# board brings its own layer stack and its own design-rule width, so neither a
	# stack entry nor a width left over from the previous board stays armed.
	# _rebuild_zone_layer_option drops a layer the new stack lacks by itself; the
	# width has no such membership test, so it is cleared outright and re-reads the
	# new board's design rule.
	_rebuild_zone_layer_option()
	if _canvas != null:
		_canvas.trace_width_override = 0.0
	_sync_trace_width_spin()
	_update_board_size_label()
	_update_status()
	if _canvas != null:
		_canvas.queue_redraw()


func _zoom_to_fit_deferred() -> void:
	if _canvas == null:
		return
	if _canvas.size.x > 0 and _canvas.size.y > 0:
		_canvas.zoom_to_fit()
	else:
		_canvas.resized.connect(_canvas.zoom_to_fit, CONNECT_ONE_SHOT)


# ── host_owned save/load (board doc + annotation sidecar) ──────────────────────

## Sidecar auto-write debounce (Epoch UX2 station 8, docket 019fde57027c).
## Owner decision point resolved by the rubric: durable-by-default auto-write
## (option a) beat tab-dirty-flag + save verb (option b) on the DURABILITY
## axis — HITL-4 lost three hand-authored annotations to a restart because
## the sidecar write only ran on Ctrl+S. The debounce bounds write
## amplification on busy boards: a mutation burst produces at most one write
## per window, and each write serializes the CURRENT list, so the last write
## of a burst carries the final state. The BOARD file stays owner-saved —
## only the annotation sidecar (cheap JSON beside the source) is automatic.
const _SIDECAR_AUTOSAVE_DEBOUNCE_S := 0.8
var _sidecar_autosave_pending: bool = false


## Write BOTH sidecars now (UX4 station 6, DCR S9): the annotation sidecar and
## the routing sidecar WITH the staged section. One flush body shared by the
## debounce, the pre-mount synchronous path and the teardown flush, so the
## three can never disagree about what "durable" includes.
func _flush_sidecars() -> void:
	if _file_path.is_empty():
		return
	if _annotation_host != null:
		_annotation_host.save_sidecar(_file_path)
	if _routing_workspace != null:
		_PcbRoutingSidecarScript.save_workspace(
			_file_path, _routing_workspace, _data.to_board_dict(),
			int(_data.board_revision), _staged_entities)


func _schedule_sidecar_autosave() -> void:
	if _annotation_host == null or _file_path.is_empty():
		return  # no durable home yet — adopted on save/load/path-load
	if not is_inside_tree():
		# No timer source before mount — write synchronously (rare: mutations
		# before the panel enters the tree). Durability outranks coalescing.
		_flush_sidecars()
		return
	if _sidecar_autosave_pending:
		return
	_sidecar_autosave_pending = true
	# No is_instance_valid(self) guard on purpose (cold review F4): a lambda
	# bound to a freed instance is silently dropped by the signal emission —
	# it never runs — so the guard was unreachable dead code.
	get_tree().create_timer(_SIDECAR_AUTOSAVE_DEBOUNCE_S).timeout.connect(func() -> void:
		_sidecar_autosave_pending = false
		if _annotation_host != null and not _file_path.is_empty():
			_flush_sidecars())


func _exit_tree() -> void:
	# Teardown flush: a pending debounced write must not die with the panel —
	# the exact "annotations die with the app" class this station closes.
	if _sidecar_autosave_pending and _annotation_host != null and not _file_path.is_empty():
		_sidecar_autosave_pending = false
		_flush_sidecars()

## Return the board's save state. Ctrl+S writes this Dict to the .pcbskel file as
## JSON (Editor.gd host_owned path). Canonical from now on (port rule 4): the
## returned shape is to_board_dict(). We ALSO flush annotations to the sidecar
## here — the platform does not auto-persist plugin-panel annotation sidecars
## (gap register C-15), so the panel owns that write.
func _on_panel_save_request() -> Dictionary:
	var board_dict: Dictionary = _data.to_board_dict()
	if _annotation_host != null and not _file_path.is_empty():
		_annotation_host.save_sidecar(_file_path)
	# T2a: flush the routing workspace to "<board_path>.routing.json" AFTER the
	# annotation sidecar. The fingerprint is computed from the CURRENT board_dict
	# (the exact fabrication doc we return, which carries NO routing state), so a
	# later load can tell whether this workspace still matches the board.
	# Save vs Save-As: on Save the sidecar rewrites at the same _file_path with a
	# matching fingerprint (candidates load clean next open); on Save-As _file_path
	# has already been updated to the new path by _on_panel_load_request's capture
	# (the host re-drives load with the new path) — but for a same-content Save-As
	# the recomputed fingerprint still matches, so candidates stay valid. Zero
	# candidates ⇒ the sidecar is deleted, never written empty.
	if _routing_workspace != null and not _file_path.is_empty():
		_PcbRoutingSidecarScript.save_workspace(
			_file_path, _routing_workspace, board_dict, int(_data.board_revision),
			_staged_entities)
	return board_dict


## Restore board state previously returned by _on_panel_save_request.
##
## Accepts BOTH shapes (port rule 4):
##   1. Canonical board dict (to_board_dict): {version, name, width_mm, height_mm,
##      grid_mm, components:[…canonical…], nets, traces, vias, design_rules}.
##   2. Legacy skeleton shape {version, kind:"pcbskel_board", board:{width_mm,
##      height_mm}, components:[{ref,x,y,w,h}]} — detected by the nested `board`
##      key and migrated to canonical before load.
##
## The host ALWAYS includes `file_path` (Editor.gd:1117), in BOTH the JSON-merged
## and the raw-text document shapes; we capture it either way (W-15 — the JSON
## branch previously dropped it, so live saves never knew where to write the
## sidecar).
func _on_panel_load_request(document: Dictionary) -> void:
	var doc := document

	# Capture file_path regardless of shape.
	var doc_path := str(document.get("file_path", ""))
	if not doc_path.is_empty():
		_file_path = doc_path

	# Raw-text shape: parse the body ourselves.
	if document.has("raw_text") and not document.has("board") and not document.has("width_mm"):
		var parsed: Variant = JSON.parse_string(str(document.get("raw_text", "")))
		if parsed is Dictionary:
			doc = parsed as Dictionary
		else:
			doc = {}

	# Restoring saved state — suppress the dirty relay for the whole load.
	_restoring = true
	if doc.has("board") and doc["board"] is Dictionary:
		# Legacy skeleton shape → migrate to canonical, then load.
		_data.from_board_dict(_migrate_skeleton_shape(doc))
	elif doc.has("width_mm") or doc.has("components") or doc.has("name"):
		# Canonical board dict.
		_data.from_board_dict(doc)
	# else: unknown/empty body — keep whatever board is already loaded.

	# Annotation persistence for this board file (restored, not edited).
	# Idempotency marker = sidecar presence (docket annotation child 019eb47e4e7e):
	#   * sidecar exists           → load it (already migrated, or authored fresh);
	#                                 NEVER re-migrate — the inline blobs, if the
	#                                 board still carries them, are stale duplicates.
	#   * no sidecar + legacy blobs → ONE-SHOT migrate the inline annotations /
	#                                 route_hints into v2 envelopes, then save the
	#                                 sidecar immediately so the data is durable.
	#   * no sidecar + no legacy    → nothing to load.
	#
	# Dirty-state decision (documented): migration runs INSIDE the _restoring gate,
	# so the migrated envelopes' annotations_changed signals do NOT dirty the tab —
	# migration is a restore-class operation, not a user edit. The board file itself
	# rewrites clean on the next save (to_board_dict() never emits annotations /
	# route_hints), so the inline blobs disappear naturally; the sidecar is the
	# source of truth from here on.
	if _annotation_host != null and not _file_path.is_empty():
		_annotation_host.set_document_path(_file_path)
		if AnnotationSidecar.has_sidecar(_file_path):
			_annotation_host.load_sidecar(_file_path)
		elif _has_legacy_annotation_blobs(doc):
			_run_legacy_migration(doc)
		# else: no sidecar, no legacy blobs — leave the host's list empty.
		# S5 migration notice (cheap-note fix, review): runs after EITHER branch
		# above, not just the sidecar one. A pre-cutover .minpcb's inline
		# route_hints blob is not KNOWN to ever carry proposal_for (that field
		# postdates the inline format), but nothing enforces that absence —
		# _has_legacy_annotation_blobs/_run_legacy_migration accept whatever
		# Dictionary shape the on-disk document happened to hold, and a
		# hand-edited or intermediate-format file could carry the key anyway.
		# Running the drop unconditionally after annotation loading closes that
		# gap defensively instead of trusting a shape guarantee no code enforces.
		_drop_legacy_proposal_annotations()

	# T2a: load the routing workspace sidecar, coherence-gated. Runs INSIDE the
	# _restoring gate (a restore, not a user edit). The fingerprint is recomputed
	# from the board we JUST loaded into _data; a mismatch (board changed under the
	# workspace — Save-As/copy/edit/crash-torn/ABA) marks ALL candidates stale
	# rather than trusting them. Missing sidecar → nothing to load; corrupt/
	# unknown-schema → quarantine, never a crashed load.
	if _routing_workspace != null and not _file_path.is_empty():
		# UX4 S9: staged drafts ride the same coherence-gated load (see the
		# path-adoption site for the quarantine/reset rules). Same _restoring
		# gate — the store's load emits `changed` unconditionally.
		_PcbRoutingSidecarScript.load_into_workspace(
			_file_path, _routing_workspace, _data.to_board_dict(), int(_data.board_revision),
			_staged_entities)

	# Codex 1047 fix round, verdict 6: deterministic load-time reconciliation
	# of the TWO supersession stores, run at the ONE point where both are in
	# memory — the annotations sidecar (loaded above) and the routing-workspace
	# sidecar (loaded just now). The legacy-waypoint constraint + marker pair
	# is written ordered but NOT atomically (two sidecar files — see
	# panel_tools.gd reconcile_superseded_waypoint_state's own doc for the
	# authority rule, the detail_level decision, and the structured record
	# shape published on workspace.last_load_reconciliation). Runs INSIDE the
	# _restoring gate: a repair is a restore-class bookkeeping act, never a
	# user edit — it must not dirty the tab (and, host-side, it never creates
	# an undo step). The repaired annotations are NOT force-saved here — the
	# pass re-derives the same outcome on every load (idempotent), and the
	# sidecar rewrites consistent on the next ordinary save.
	if _annotation_host != null and _routing_workspace != null:
		var reconciled: Array = _PanelToolsScript.reconcile_superseded_waypoint_state(
			_annotation_host, _routing_workspace)
		if not reconciled.is_empty():
			_set_status("Reconciled %d superseded-waypoint marker%s against the routing workspace (torn save repaired — see warnings)." % [
				reconciled.size(), "" if reconciled.size() == 1 else "s"])
	_restoring = false

	_refresh_board_ui()
	_zoom_to_fit_deferred()


## Run the one-shot legacy → sidecar migration through the annotation host, persist
## the result, and surface the count/warnings on the status bar. Caller guarantees
## _annotation_host + _file_path are set and no sidecar exists yet. Runs while
## _restoring is true so migrated envelopes never dirty the tab.
func _run_legacy_migration(doc: Dictionary) -> void:
	_last_migration = _LegacyAnnotationMigration.migrate(
		doc.get("annotations", {}), doc.get("route_hints", {}), _annotation_host)
	_annotation_host.save_sidecar(_file_path)
	var n := int(_last_migration.get("migrated", 0))
	var warns: Array = _last_migration.get("warnings", [])
	if warns.is_empty():
		_set_status("Migrated %d legacy annotation%s to sidecar." % [n, "" if n == 1 else "s"])
	else:
		_set_status("Migrated %d legacy annotation%s (%d warning%s)." % [
			n, "" if n == 1 else "s", warns.size(), "" if warns.size() == 1 else "s"])


## Summary of the most recent legacy migration ({migrated, warnings}). {0, []}
## when no migrating load has run. Exposed for tests / telemetry.
func get_last_migration_summary() -> Dictionary:
	return _last_migration


## S5 MIGRATION (C4b, DCR 019f7095c395): a .pcbskel sidecar saved before this
## cutover may still carry AI-authored proposal annotations
## (kind_payload.proposal_for) — the annotation-side propose/accept/reject
## machinery this round retires (see panel_tools.gd _propose_into_workspace).
##
## DECISION (documented drop, not a one-shot importer — see the C4b report for
## the full decider package): DROP the annotations, never import them into the
## routing workspace. Since the T2 shadow-write phase (well before this
## cutover) every propose already ALSO landed a correlated RoutingWorkspace
## candidate alongside the annotation, persisted in the SAME sidecar — so on
## any board saved with that machinery live, nothing is lost: the workspace
## half survives this drop untouched (loaded separately, above, via
## _PcbRoutingSidecarScript.load_into_workspace) and stays fully actionable
## through minerva_pcb_workspace_commit/_reject. Only a genuinely
## pre-shadow-phase board (annotation-only, no correlated candidate) loses the
## already-computed geometry — recoverable with one re-propose against the
## still-open source hint(s), which this drop deliberately leaves untouched:
## only the proposal_for-carrying annotation itself is removed, never the
## hint(s) it names. An importer was rejected because a proposal minted before
## U2 (lossless carry) is WAYPOINT-FLATTENED — no per-segment layer, no vias —
## and would mint a WRONG (silently single-layer, via-less) candidate; there is
## no way to tell a pre-U2 from a post-U2 proposal apart from an importer's own
## code without re-deriving the same fidelity check U2's fallback already
## performs, at which point it is no longer "one importer" but two.
##
## Runs inside the _restoring gate (a load-time cleanup, not a user edit) so it
## never dirties the tab. Silent when there is nothing to drop.
func _drop_legacy_proposal_annotations() -> void:
	if _annotation_host == null:
		return
	var dropped: Array = []
	for ann in _annotation_host.get_annotations():
		if not (ann is Dictionary):
			continue
		if str((ann as Dictionary).get("kind", "")) != "pcb_route_hint":
			continue
		var kp: Variant = (ann as Dictionary).get("kind_payload", {})
		if kp is Dictionary and (kp as Dictionary).has("proposal_for"):
			dropped.append(str((ann as Dictionary).get("id", "")))
	for id in dropped:
		_annotation_host.remove_annotation(id)
	_last_legacy_proposals_dropped = dropped.size()
	_last_legacy_drop_notice = ""
	if not dropped.is_empty():
		# The notice is KEPT on a mount-independent field (UX4 station 10,
		# HITL-3 nit 5): _set_status renders into _status_label, which is Nil
		# on an unmounted panel — the suite asserts the prose through the
		# field, not the widget.
		_last_legacy_drop_notice = "%d legacy route proposal%s dropped (pre-S5 cutover) — repropose from the open hint(s) via Propose or minerva_pcb_workspace_propose." % [
			dropped.size(), "" if dropped.size() == 1 else "s"]
		_set_status(_last_legacy_drop_notice)


## Count of legacy proposal annotations dropped on the most recent sidecar
## load. 0 when no drop has run (never loaded a sidecar, or nothing to drop).
## Exposed for tests / telemetry.
func get_last_legacy_proposals_dropped() -> int:
	return _last_legacy_proposals_dropped


## The drop's status prose, mount-independent (UX4 station 10, HITL-3 nit 5 —
## docket 019fce3ac3). "" when the most recent load dropped nothing.
var _last_legacy_drop_notice := ""


func get_last_legacy_drop_notice() -> String:
	return _last_legacy_drop_notice


## True when the loaded document still carries a NON-EMPTY inline annotations or
## route_hints blob (the one-shot migration trigger).
static func _has_legacy_annotation_blobs(doc: Dictionary) -> bool:
	return not _blob_empty(doc.get("annotations", null)) or not _blob_empty(doc.get("route_hints", null))


static func _blob_empty(v: Variant) -> bool:
	if v is Array:
		return (v as Array).is_empty()
	if v is Dictionary:
		return (v as Dictionary).is_empty()
	return true


## Migrate the legacy skeleton document {board:{width_mm,height_mm},
## components:[{ref,x,y,w,h}]} to a canonical board dict. Crude parts become
## canonical components sized by width/height with a single origin pin — lossy but
## the skeleton carried no pin/net data to lose.
func _migrate_skeleton_shape(doc: Dictionary) -> Dictionary:
	var board: Dictionary = _dict_or_empty(doc.get("board"))
	var canonical := {
		"version": 1,
		"name": "Untitled",
		"width_mm": float(board.get("width_mm", 100.0)),
		"height_mm": float(board.get("height_mm", 100.0)),
		"components": [],
	}
	for c in doc.get("components", []):
		if not c is Dictionary:
			continue
		canonical["components"].append({
			"ref": str(c.get("ref", "")),
			"x_mm": float(c.get("x", 0.0)),
			"y_mm": float(c.get("y", 0.0)),
			"rotation_deg": 0.0,
			"width": float(c.get("w", 4.0)),
			"height": float(c.get("h", 4.0)),
			"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
		})
	return canonical
