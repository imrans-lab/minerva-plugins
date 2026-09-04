class_name Cad_CADPanel
extends MinervaPluginPanel

## Ownership marker for the panel-executed tool dispatcher: fallback-resolved
## panels (AnnotationHostRegistry path) aren't broker-keyed by editor name, so
## the dispatcher reads this duck-typed property to verify the calling tool's
## plugin owns this panel (fail-safe deny otherwise). HITL-caught 2026-07-16.
var plugin_id: String = "cad"
## CAD editor panel — Round 2 layout integration.
##
## Cycle 2 R2 adopts platform widgets:
##   * ResponsiveContainer wraps the panel content. width_class drives a
##     stack-style swap between WideLayout (4-view + sidebar HSplit) and
##     NarrowLayout (single-view + projection dropdown + tools).
##   * The platform AnnotationDockPane (auto-mounted via get_annotation_host())
##     provides annotation tooling. CADPanel owns only the CAD-specific edge
##     geometry inspector tree in the wide sidebar.
##
## Off-tree class_name gotcha:
##   This plugin lives at ~/github/plugins/cad/, OUTSIDE Minerva's res:// tree,
##   so Godot's parser cache cannot statically resolve plugin or platform
##   class_names from typed field declarations in this file. Fields whose
##   types are platform classes (ResponsiveContainer) are typed with the
##   platform BASE class (Container) or kept untyped, and assigned via
##   preload(...).new(). Property access and signal subscription works via
##   duck typing.

const _DEBUG_EDGE_PICK: bool = true

const _CadAnnotationHostScript: Script = preload("CadAnnotationHost.gd")
const _ResponsiveContainerScript: Script = preload("res://Scripts/UI/Controls/responsive_container.gd")
const _BuiltinKindsScript: Script = preload("res://Scripts/Services/Annotations/BuiltinKinds.gd")
const _CadEdgeNumberKindScript: Script = preload("kinds/cad_edge_number_kind.gd")

## Panel-executed MCP tool surface (executor: "panel", DCR 019f6c3d0e3d C6 —
## see handle_tool() below and panel_tools.gd's doc comment for the contract).
const _PanelToolsScript: Script = preload("panel_tools.gd")
## Foreign mesh files named by mesh() in the source: loading, unit/up-axis
## conversion, pose and mounting all live here. The panel only wires it up.
const _ReferenceMeshesScript: Script = preload("scripts/reference_meshes.gd")
## The three host note hooks — plugin_data payload, restore and the
## LLM rendering — live here; the panel below is wiring only.
const _CadNoteScript: Script = preload("scripts/cad_note.gd")
## Name, path and line text for the GUI "Import mesh…" action. Text authoring
## only — the import writes DSL, it never holds geometry of its own.
const _MeshImportScript: Script = preload("scripts/mesh_import.gd")
## Measurement: propose candidates by fitting primitives to a reference mesh,
## then verify and measure them against physics colliders. Both are pure
## modules; the panel only holds them and hands them the mounted references.
## Which reference node the user is pointing at: the per-pane click nodes, the
## sidebar list, the selection itself and the point anchors made from it.
const _ReferenceSelectionScript: Script = preload("scripts/reference_selection.gd")
const _MeshFeaturesScript: Script = preload("scripts/mesh_features.gd")
const _MeshGaugeScript: Script = preload("scripts/mesh_gauge.gd")

## Every MeshRoot an evaluation has to reach — the four wide-layout panes and
## the narrow layout's single pane. One list, because the mesh push, the
## reference mount and the ortho x-ray toggle must never disagree about which
## panes exist.
const _MESH_ROOT_PATHS: Array = [
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/TopView/SubViewport/MeshRoot",
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/FrontView/SubViewport/MeshRoot",
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/RightView/SubViewport/MeshRoot",
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/IsoView/SubViewport/MeshRoot",
	"ResponsiveContainer/NarrowLayout/SingleView/SubViewport/MeshRoot",
]

# ── Node references (set in _ready) ────────────────────────────────────────

## ResponsiveContainer wrapping both layouts. Typed Container (base class) so
## the parser doesn't try to resolve ResponsiveContainer from off-tree.
var _responsive: Container = null

## Wide-layout (4-view + sidebar) and narrow-layout (single-view) roots.
var _wide_layout: Control = null
var _narrow_layout: Control = null

## SubViewportContainers for the four CAD views in WIDE layout.
var _top_view_container: SubViewportContainer = null
var _front_view_container: SubViewportContainer = null
var _right_view_container: SubViewportContainer = null
var _iso_view_container: SubViewportContainer = null

## Single SubViewportContainer used in NARROW layout. Its OrbitCamera's preset
## is updated by the projection dropdown.
## Camera typed as Camera3D (base) — OrbitCamera class_name is plugin-local and
## not resolvable from off-tree. set_view_preset() called via duck typing.
var _single_view_container: SubViewportContainer = null
var _single_view_camera: Camera3D = null

## Projection dropdown used to switch the single-view camera preset.
var _projection_dropdown: OptionButton = null

## Wide-layout sidebar (edge geometry inspector tree).
var _wide_sidebar: VBoxContainer = null

## Currently active viewport id, one of: "top","front","right","iso" (wide mode)
## or "perspective","top","bottom","front","back","left","right" (narrow mode).
## In wide mode the canvas is overlaid on the Iso quadrant by default.
var _active_viewport_id: String = "iso"

## Full-rect overlay Control that spans all 4 SubViewportContainers.
## mouse_filter=IGNORE so all clicks pass through to SubViewports.
## Used as panel_root reference so host.get_panes() can compute panel-relative rects.
var _canvas_overlay: Control = null

# ── Annotation substrate ────────────────────────────────────────────────────

var _annotation_registry: AnnotationRegistry = null
var _annotation_host: AnnotationHost = null  # actual class is Cad_AnnotationHost

## Editor name under which we registered our host with AnnotationHostRegistry.
var _registered_editor_name: String = ""

# ── Plugin context ──────────────────────────────────────────────────────────

var _ctx: Dictionary = {}

# ── Buffer-canonical (paired_dsl) state ─────────────────────────────────────
# DCR 019dfa66 §T6: when render_mode=paired_dsl, the panel receives DSL text
# via the substrate's platform-reserved channels (attach_buffer / text_changed
# / detach_buffer) instead of reading it off disk. The panel debounces rapid
# text_changed pushes, cancels any in-flight cad.evaluate via cad.cancel_eval,
# and re-issues evaluate with a fresh request_id.

var _buffer_path: String = ""
## Where the .mcad being edited lives on disk, or "" for an editor that has
## never been saved. mesh() paths are resolved against it.
var _document_path: String = ""
var _buffer_version: int = -1
var _pending_dsl_text: String = ""
var _inflight_request_id: String = ""

## Debounce timer for text_changed → evaluate. Created lazily on first
## text_changed receipt so the panel doesn't pay the Timer cost in the legacy
## (non-paired_dsl) path.
var _eval_debounce_timer: Timer = null
const _EVAL_DEBOUNCE_SEC: float = 0.25

# ── Edge enumeration / overlay state ────────────────────────────────────────

## Per-pane Cad_GeometryOverlay refs. Map view_id (str) → Control.
var _geometry_overlays: Dictionary = {}

## Last-known edge registry (Array of edge dicts). Built either from the IPC
## mcad_list_edges reply or synthesised from the stub cube in _ready().
var _edge_registry: Array = []

## Last-known mesh data (passed to EdgeOverlay so it can rebuild silhouettes
## on camera moves).
var _last_mesh_data: Dictionary = {}

## Loads, converts and caches the mesh files the source references. One library
## per panel: the cache is keyed by path, so all five panes share every read.
var _reference_library: RefCounted = null
## Outcome of the last mount: {world_aabb, warnings, errors, mounted}.
var _reference_report: Dictionary = {}
## The mesh() specs the last mount was given ({name, path, matrix, units, up}),
## verbatim. A note carries these so a reopened tab shows its references before
## the worker has answered.
var _last_references: Array = []
## Warning from the last GUI mesh import that must survive evaluations.
var _import_notice: String = ""
## Segmentation and primitive fitting over the loaded references (RefCounted),
## and the physics gauge that verifies what it proposes (a child Node).
var _mesh_features: RefCounted = null
var _mesh_gauge: Node = null
## Identity of the reference set the gauge's colliders were last built from.
var _reference_digest: String = ""

## Reference-node selection (scripts/reference_selection.gd). Owns the click
## picking, the sidebar list and the selection the MCP verbs read back.
var _reference_selection: RefCounted = null

## Scene nodes behind the GUI import action: the file picker and the button in
## each layout. Both buttons run the same handler.
var _mesh_import_dialog: FileDialog = null
var _import_buttons: Array[Button] = []

## What the last import decided, for the panel's own reporting:
## {ok, line, name, path, absolute, warning, error}. Empty until one runs.
var _last_import: Dictionary = {}

## Last-known evaluation result, surfaced via _on_panel_save_request so
## minerva_doc_read after a write exposes whether the worker actually
## accepted the DSL. Shape:
##   {status: "empty"|"pending"|"ok"|"error"|"cancelled"|"timeout",
##    error_kind?: String, error_message?: String, shape_name?: String,
##    request_id?: String, ts?: int}
##
## "empty" = panel just opened, no DSL evaluated yet.
## "pending" = evaluate dispatched, awaiting worker reply.
## "ok" = worker returned a mesh; panel is rendering it.
## "error" = worker rejected the DSL (kind/message available).
## "cancelled" = preempted by a newer evaluate (transient; not user-visible).
## "timeout" = worker didn't reply within the 30s budget.
var _last_eval_result: Dictionary = {"status": "empty"}

## Error banner shown over the 3D views when an evaluation fails (W8 / RCA
## 019e46b5). Built in _ready; visibility is driven by _evaluate_and_render.
var _error_banner: PanelContainer = null
var _error_banner_label: Label = null

## Tree node in the wide sidebar listing all edges. Built in _ready().
var _edge_tree: Tree = null

## Map edge_id → TreeItem so we can sync selection both directions.
var _edge_tree_items: Dictionary = {}

## Re-entrancy guard for tree → panel selection routing.
var _suppress_tree_selection: bool = false

## Projection dropdown options (id → preset string accepted by orbit_camera).
const _PROJECTION_OPTIONS: Array = [
	{"id": 0, "label": "Perspective", "preset": "Perspective"},
	{"id": 1, "label": "Top",         "preset": "Top"},
	{"id": 2, "label": "Bottom",      "preset": "Bottom"},
	{"id": 3, "label": "Front",       "preset": "Front"},
	{"id": 4, "label": "Back",        "preset": "Back"},
	{"id": 5, "label": "Left",        "preset": "Left"},
	{"id": 6, "label": "Right",       "preset": "Right"},
]


# ── Godot lifecycle ─────────────────────────────────────────────────────────

func _ready() -> void:
	# ── Wire layout container references ───────────────────────────────────
	_responsive = $ResponsiveContainer as Container
	_wide_layout = $ResponsiveContainer/WideLayout as Control
	_narrow_layout = $ResponsiveContainer/NarrowLayout as Control
	_wide_sidebar = $ResponsiveContainer/WideLayout/WideSidebar as VBoxContainer

	# ── Wide-layout viewport containers ────────────────────────────────────
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	_top_view_container   = get_node(grid + "/TopView")   as SubViewportContainer
	_front_view_container = get_node(grid + "/FrontView") as SubViewportContainer
	_right_view_container = get_node(grid + "/RightView") as SubViewportContainer
	_iso_view_container   = get_node(grid + "/IsoView")   as SubViewportContainer

	# Configure each OrbitCamera to its view preset (wide mode).
	var top_cam: Camera3D   = get_node(grid + "/TopView/SubViewport/OrbitCamera")
	var front_cam: Camera3D = get_node(grid + "/FrontView/SubViewport/OrbitCamera")
	var right_cam: Camera3D = get_node(grid + "/RightView/SubViewport/OrbitCamera")
	# IsoView camera stays at "Perspective" default — no call needed.
	if top_cam != null:
		top_cam.set_view_preset("Top")
		top_cam.set_show_helpers(false)
	if front_cam != null:
		front_cam.set_view_preset("Front")
		front_cam.set_show_helpers(false)
	if right_cam != null:
		right_cam.set_view_preset("Right")
		right_cam.set_show_helpers(false)

	# ── Narrow-layout single viewport ──────────────────────────────────────
	_single_view_container = $ResponsiveContainer/NarrowLayout/SingleView as SubViewportContainer
	_single_view_camera = $ResponsiveContainer/NarrowLayout/SingleView/SubViewport/OrbitCamera as Camera3D

	# ── Projection dropdown ────────────────────────────────────────────────
	_projection_dropdown = $ResponsiveContainer/NarrowLayout/ProjectionRow/ProjectionDropdown as OptionButton
	_projection_dropdown.clear()
	for opt in _PROJECTION_OPTIONS:
		_projection_dropdown.add_item(opt["label"], opt["id"])
	_projection_dropdown.select(0)  # Perspective by default
	_projection_dropdown.item_selected.connect(_on_projection_selected)

	# ── "Import mesh…" — the GUI half of mesh() authoring ──────────────────
	_wire_mesh_import()

	# Mesh is intentionally empty until a .mcad source is evaluated by the
	# worker and pushed in via the future DSL→mesh bridge. Showing a stub
	# cube here was misleading because it implied the panel had geometry
	# without DSL backing it; the empty state is the honest state.

	_reference_library = _ReferenceMeshesScript.new()
	_mesh_features = _MeshFeaturesScript.new()
	# The gauge is a Node: it owns a physics step, because Minerva runs physics
	# on its own thread and a space is only reachable from inside one.
	_mesh_gauge = _MeshGaugeScript.new()
	_mesh_gauge.name = "MeshGauge"
	add_child(_mesh_gauge)

	# ── Annotation substrate ───────────────────────────────────────────────
	_annotation_registry = AnnotationRegistry.new()
	# Register built-in 2D kinds (arrow, text, region, polyline, highlight,
	# measure_distance, measure_angle, measure_radius). CAD-specific 3-D kinds
	# are a later grandchild (`019dd017d9df`).
	_BuiltinKindsScript.register_all(_annotation_registry)
	# Register cad_edge_number: numbered callout bubbles for LLM/user edge disambiguation.
	_annotation_registry.register_annotation_kind(_CadEdgeNumberKindScript.new())

	_annotation_host = _CadAnnotationHostScript.new()
	_annotation_host._registry = _annotation_registry

	# ── Register SubViewports with the host so render_content_to_image can
	# capture the correct pane for AI vision composites. The mapping is
	# layout-dependent (wide vs narrow share the "top"/"front"/"right" ids,
	# but they refer to different SubViewports). _register_host_viewports()
	# is re-called on every width-class transition so the active map always
	# matches the visible layout.
	_register_host_viewports(false)  # wide by default; corrected below in _apply_width_class

	# ── Build panel-root overlay Control spanning all SubViewportContainers ──
	# Used as the panel_root reference so host.get_panes() can compute
	# panel-relative rects for multi-pane annotation projection. The platform's
	# PlatformAnnotationOverlay (auto-mounted via get_annotation_host()) handles
	# all annotation drawing; this Control is purely a coordinate anchor.
	_canvas_overlay = Control.new()
	_canvas_overlay.name = "AnnotationCanvasOverlay"
	_canvas_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas_overlay.z_index = 1
	add_child(_canvas_overlay)

	# ── Evaluation-error banner ───────────────────────────────────────────
	# When cad.evaluate fails (timeout / worker error / connection lost) the
	# 3D views render nothing; without this banner that empty render is silent
	# — the user-facing symptom of RCA 019e46b5. A dedicated full-rect Control
	# layer hosts a top-anchored banner so the PanelContainer's single-child
	# layout does not stretch the banner across the whole panel.
	var _error_layer := Control.new()
	_error_layer.name = "EvalErrorLayer"
	_error_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_error_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_error_layer.z_index = 2
	add_child(_error_layer)

	_error_banner = PanelContainer.new()
	_error_banner.name = "EvalErrorBanner"
	_error_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_error_banner.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_error_banner.visible = false
	var _banner_style := StyleBoxFlat.new()
	_banner_style.bg_color = Color(0.5, 0.12, 0.12, 0.96)
	_banner_style.content_margin_left = 10.0
	_banner_style.content_margin_right = 10.0
	_banner_style.content_margin_top = 6.0
	_banner_style.content_margin_bottom = 6.0
	_error_banner.add_theme_stylebox_override("panel", _banner_style)
	_error_layer.add_child(_error_banner)

	_error_banner_label = Label.new()
	_error_banner_label.name = "EvalErrorLabel"
	_error_banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_banner_label.add_theme_color_override("font_color", Color(1, 0.9, 0.9))
	_error_banner.add_child(_error_banner_label)

	if _annotation_host.has_method("set_panel_root"):
		_annotation_host.set_panel_root(_canvas_overlay)
	_annotation_host.set_active_viewport(_active_viewport_id)

	# ── Geometry overlay wiring (one Cad_GeometryOverlay per SubViewport) ────
	# Resolve and store refs to all five EdgeOverlayRoot Control nodes that
	# already live in the .tscn under each SubViewport.
	_geometry_overlays["top"]   = get_node_or_null(grid + "/TopView/SubViewport/EdgeOverlayRoot")
	_geometry_overlays["front"] = get_node_or_null(grid + "/FrontView/SubViewport/EdgeOverlayRoot")
	_geometry_overlays["right"] = get_node_or_null(grid + "/RightView/SubViewport/EdgeOverlayRoot")
	_geometry_overlays["iso"]   = get_node_or_null(grid + "/IsoView/SubViewport/EdgeOverlayRoot")
	_geometry_overlays["single"] = get_node_or_null(
		"ResponsiveContainer/NarrowLayout/SingleView/SubViewport/EdgeOverlayRoot")

	# ── Reference-node selection: click picking + sidebar + point anchors ──
	_reference_selection = _ReferenceSelectionScript.new()
	_reference_selection.attach(self)

	# ── Wide-mode sidebar: edge Tree + Prev/Next/Clear buttons ─────────────
	_build_edge_sidebar()
	_render_edge_tree(_edge_registry)

	# ── Connect ResponsiveContainer width-class signal & apply initial mode
	_responsive.width_class_changed.connect(_on_width_class_changed)
	# Apply the initial layout state so the canvas is correctly placed
	# even before the first resize transition fires.
	_apply_width_class(_responsive.width_class)


func get_annotation_host() -> RefCounted:
	return _annotation_host


## Panel-executed MCP tool entry point (executor: "panel",
## Docs/design/panel-executed-tools.md §2 "Plugin-side convention"). The
## PluginToolRegistry dispatcher resolves args.editor_name to this live
## panel and calls this method directly — no subprocess involved. All tool
## bodies live in panel_tools.gd (mirrors pcb/ui/PCBPanel.gd's forward).
## Measurement verbs ask the physics server questions and physics runs on its
## own thread, so the answer arrives a step later: the dispatcher awaits this
## method, and this method awaits the tool body.
func handle_tool(tool_name: String, args: Dictionary) -> Dictionary:
	var result: Variant = await _PanelToolsScript.handle(self, tool_name, args)
	return result if result is Dictionary else {}


## Public introspection surface backing minerva_cad_view_state (panel_tools.gd).
## Surfaces layout/camera state the panel already tracks — width_class (which
## ResponsiveContainer breakpoint is active), active_viewport_id (which pane
## an agent's minerva_cad_snapshot view="active" would capture), the
## narrow-mode projection dropdown selection, and the active pane's camera
## orientation/zoom (OrbitCamera's own get_target/get_distance/get_yaw/
## get_pitch/get_debug_state — no new camera state was added for this tool).
func get_view_state() -> Dictionary:
	var cam: Camera3D = _camera_for_active_viewport()
	var camera_state: Variant = null
	if cam != null:
		camera_state = {
			"view_preset": String(cam.get_debug_state().get("view_preset", "")) if cam.has_method("get_debug_state") else "",
			"target": _vec3_to_array(cam.get_target()) if cam.has_method("get_target") else null,
			"distance": cam.get_distance() if cam.has_method("get_distance") else null,
			"yaw": cam.get_yaw() if cam.has_method("get_yaw") else null,
			"pitch": cam.get_pitch() if cam.has_method("get_pitch") else null,
		}
	return {
		"width_class": String(_responsive.width_class) if _responsive != null else "",
		"is_narrow_layout": _narrow_layout.visible if _narrow_layout != null else false,
		"active_viewport_id": _active_viewport_id,
		"projection_preset": _current_projection_preset(),
		"camera": camera_state,
	}


## Resolve the Camera3D backing the currently-active pane: the single
## narrow-mode camera when narrow layout is visible, otherwise the wide-mode
## camera matching _active_viewport_id (falls back to the iso camera for any
## id that isn't top/front/right — mirrors _projection_preset_to_viewport_id's
## lower-cased ids and _register_host_viewports' wide-mode camera map).
func _camera_for_active_viewport() -> Camera3D:
	if _narrow_layout != null and _narrow_layout.visible:
		return _single_view_camera
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	match _active_viewport_id:
		"top":
			return get_node_or_null(grid + "/TopView/SubViewport/OrbitCamera") as Camera3D
		"front":
			return get_node_or_null(grid + "/FrontView/SubViewport/OrbitCamera") as Camera3D
		"right":
			return get_node_or_null(grid + "/RightView/SubViewport/OrbitCamera") as Camera3D
		_:
			return get_node_or_null(grid + "/IsoView/SubViewport/OrbitCamera") as Camera3D


## Vector3 -> [x, y, z] (JSON-safe; MCP results are JSON-encoded downstream).
func _vec3_to_array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


# ── Measurement surface (backs the minerva_cad_* measurement verbs) ─────────
#
# The panel's part in measuring a foreign mesh is only ever bookkeeping: it
# knows which references are mounted, where they are posed and which modules
# hold the geometry. The fitting lives in mesh_features.gd and every physical
# question is answered by mesh_gauge.gd from inside a physics step.


## The references the last evaluation mounted, with their poses, their cached
## converted parts and their per-node bounds. Empty before the first
## evaluation, or when the document names no mesh().
func get_reference_state() -> Array:
	if _reference_library == null:
		return []
	return _reference_library.mounted_references()


## Every reference the last evaluation named, loaded or not, with its status
## and the reason for it. get_reference_state() is the geometry surface and
## holds only the ones that loaded; this is the reporting surface.
func get_reference_status() -> Array:
	if _reference_library == null:
		return []
	return _reference_library.reference_records()


## Everything a note needs to know about the document this tab is showing:
## the DSL source, the file it came from, the last evaluation's verdict, the
## mesh the worker returned and the mesh() specs it named. One accessor because
## cad_note.gd is the only reader and it wants them together.
func get_document_state() -> Dictionary:
	return {
		"source": _current_source(),
		"path": _document_path,
		"last_eval": _last_eval_result,
		"mesh": _last_mesh_data,
		"references": _last_references,
	}


## The camera behind a named pane ("iso"/"top"/"front"/"right"/"active"). Its
## viewport is that pane's SubViewport, which is where a capture comes from.
func get_view_camera(view: String) -> Camera3D:
	return _camera_for_view(view)


## Take on a document, its path and its reference set from a note restore.
## Mounting the references here rather than waiting for the evaluation means a
## reopened note shows its foreign geometry immediately — and correctly, since
## the path is set first and relative mesh() paths resolve against it.
func adopt_restored_document(document_path: String, source: String, references: Array) -> void:
	# No DocumentBuffer is attached to a restored tab: the note is a snapshot,
	# and _buffer_path stays empty so nothing pretends one is. If the owner
	# later opens the same .mcad in the text editor, that attach wins.
	_document_path = document_path
	_import_notice = ""
	_pending_dsl_text = source
	if _annotation_host != null and _annotation_host.has_method("set_document_source"):
		_annotation_host.set_document_source(document_path, source)
	_mount_references(references)
	if not source.strip_edges().is_empty():
		_evaluate_with_request_id(source)


func get_mesh_features() -> RefCounted:
	return _mesh_features


func get_mesh_gauge() -> Node:
	return _mesh_gauge


## Build the gauge's colliders for the currently mounted references, if the set
## has changed since they were last built. Returns the collider count.
##
## Every part is handed over in WORLD millimetres — the pose composed onto the
## already-converted part transform — so every number the gauge returns is a
## world coordinate and nothing downstream has to know about the CAD frame
## conversion at all.
func ensure_gauge_built() -> int:
	if _mesh_gauge == null:
		return 0
	var bodies: Array = []
	for entry in get_reference_state():
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var reference_name := str(record.get("name", ""))
		for part_entry in record.get("parts", []):
			var part: Dictionary = part_entry
			bodies.append({
				"mesh": part.get("mesh", null),
				"transform": pose * (part.get("transform", Transform3D.IDENTITY) as Transform3D),
				# The node PATH, not the leaf name: two branches of a foreign
				# assembly may both hold a node called "Body", and a contact
				# attributed to the wrong one of them is a wrong answer.
				"node": "%s/%s" % [reference_name,
					str(part.get("node_path", part.get("node", "")))],
				"reference": reference_name,
			})
	return int(_mesh_gauge.call("build", bodies, _reference_digest))


func get_reference_digest() -> String:
	return _reference_digest


## The user's last click on a reference node, or {} — read by
## minerva_cad_get_selected_reference.
func get_reference_selection() -> Dictionary:
	if _reference_selection == null:
		return {}
	return _reference_selection.get_selection()


## Select a reference node by name (and optionally a point in its own frame),
## the MCP half of clicking one. Returns {} when it is not mounted.
func select_reference_node(reference: String, node_name: String, local_point: Variant = null) -> Dictionary:
	if _reference_selection == null:
		return {}
	return _reference_selection.select(reference, node_name, local_point, "mcp")


## Draw the measurement overlay in every pane and report the scale of each one.
## The overlay is scene geometry, so the host's own snapshot verb picks it up
## with no changes: the LLM turns the grid on, then takes the picture it was
## going to take anyway, and now the picture has a ruler in it.
func set_measurement_overlay(mode: String, grid_mm: float) -> Dictionary:
	var bounds := AABB()
	var have_bounds := false
	for path in _MESH_ROOT_PATHS:
		var mesh_root := get_node_or_null(path)
		if mesh_root == null or not mesh_root.has_method("set_measurement_overlay"):
			continue
		if not have_bounds:
			bounds = _overlay_bounds(mesh_root)
			have_bounds = true
	var drawn := {}
	for path in _MESH_ROOT_PATHS:
		var mesh_root := get_node_or_null(path)
		if mesh_root != null and mesh_root.has_method("set_measurement_overlay"):
			drawn = mesh_root.call("set_measurement_overlay", mode, grid_mm, bounds)
	return drawn


## Bounds to spread the overlay over: the references plus whatever the solid
## occupies, falling back to the reference bounds alone.
func _overlay_bounds(mesh_root: Object) -> AABB:
	var bounds := AABB()
	if mesh_root.has_method("get_reference_aabb"):
		bounds = mesh_root.call("get_reference_aabb")
	var world_aabb: AABB = _reference_report.get("world_aabb", AABB())
	if world_aabb.size.length() > 0.0:
		bounds = world_aabb if bounds.size.length() <= 0.0 else bounds.merge(world_aabb)
	return bounds


## Millimetres-to-pixels for one pane, so a snapshot can be read as a drawing.
## Orthographic panes have one constant scale; the iso pane is a perspective
## projection and has none, which is reported as a null rather than as a lie.
func get_view_metrics(view: String) -> Dictionary:
	var refusal := view_unavailable_reason(view)
	if not refusal.is_empty():
		return {"error": refusal, "view": view}
	var camera := _camera_for_view(view)
	if camera == null:
		return {"error": "no camera for view '%s'" % view}
	var viewport := camera.get_viewport()
	var size: Vector2i = viewport.size if viewport != null else Vector2i.ZERO
	var metrics := {
		"view": view,
		"width_px": size.x,
		"height_px": size.y,
		"projection": "orthographic" if camera.projection == Camera3D.PROJECTION_ORTHOGONAL \
			else "perspective",
		"px_per_mm": null,
		"origin_px": null,
	}
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL and size.y > 0 and camera.size > 0.0:
		# One CAD world unit is one millimetre, so the camera's own ortho
		# height in world units is the height of the pane in millimetres.
		metrics["px_per_mm"] = float(size.y) / camera.size
	if size.y > 0:
		var origin := camera.unproject_position(Vector3.ZERO)
		metrics["origin_px"] = [origin.x, origin.y]
	return metrics


## The world-space ray under a pixel of one pane, for turning a click or a
## snapshot coordinate into a question about the geometry. Pixels are in the
## pane's own viewport, top-left origin — the same coordinates a snapshot of
## that pane has, before any max_edge downscale the host applies.
func get_pick_ray(view: String, pixel: Vector2) -> Dictionary:
	var refusal := view_unavailable_reason(view)
	if not refusal.is_empty():
		return {"error": refusal}
	var camera := _camera_for_view(view)
	if camera == null:
		return {"error": "no camera for view '%s'" % view}
	var viewport := camera.get_viewport()
	var size: Vector2i = viewport.size if viewport != null else Vector2i.ZERO
	if size.x <= 0 or size.y <= 0:
		return {"error": "pane '%s' has no rendered size" % view}
	if pixel.x < 0.0 or pixel.y < 0.0 or pixel.x >= float(size.x) or pixel.y >= float(size.y):
		return {"error": "pixel %s is outside the %dx%d pane" % [str(pixel), size.x, size.y]}
	var origin := camera.project_ray_origin(pixel)
	var direction := camera.project_ray_normal(pixel)
	# Far enough to cross any part a CAD document holds, and bounded so the
	# ray is a segment the physics server can answer about.
	var reach := maxf(camera.far, 10000.0)
	return {
		"from": origin,
		"to": origin + direction * reach,
		"width_px": size.x,
		"height_px": size.y,
	}


## Why a named pane cannot be addressed, or "" when it can. Narrow layout has
## a single pane showing whichever preset the dropdown is on, so handing back
## that camera for "top" would answer a question about one pane with another
## pane's geometry — the right label over the wrong numbers. Snapshot already
## refuses here; measurement refuses for the same reason.
func view_unavailable_reason(view: String) -> String:
	if view.is_empty() or view == "active" or view == "single":
		return ""
	if _narrow_layout != null and _narrow_layout.visible:
		return ("the panel is in narrow layout and renders one pane only "
			+ "(currently '%s'); ask for view \"active\", or widen the panel "
			+ "to address '%s' separately") % [_current_projection_preset(), view]
	return ""


## Camera for a named pane. "active" means whatever the user is looking at,
## which in narrow layout is the only pane that renders at all.
func _camera_for_view(view: String) -> Camera3D:
	if view.is_empty() or view == "active" or view == "single":
		return _camera_for_active_viewport()
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	match view:
		"top":
			return get_node_or_null(grid + "/TopView/SubViewport/OrbitCamera") as Camera3D
		"front":
			return get_node_or_null(grid + "/FrontView/SubViewport/OrbitCamera") as Camera3D
		"right":
			return get_node_or_null(grid + "/RightView/SubViewport/OrbitCamera") as Camera3D
		"iso":
			return get_node_or_null(grid + "/IsoView/SubViewport/OrbitCamera") as Camera3D
	return null


# ── Plugin platform lifecycle hooks (override MinervaPluginPanel virtuals) ──

func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx

	var ed: Variant = ctx.get("editor", null)
	if ed != null and "tab_title" in ed and _annotation_host != null:
		var ed_name: String = str(ed.tab_title)
		if not ed_name.is_empty():
			AnnotationHostRegistry.register(ed_name, _annotation_host)
			_registered_editor_name = ed_name

	if _annotation_host != null and not _annotation_host.selection_changed.is_connected(_on_host_selection_changed):
		_annotation_host.selection_changed.connect(_on_host_selection_changed)


func _on_panel_unload() -> void:
	if _annotation_host != null and _annotation_host.selection_changed.is_connected(_on_host_selection_changed):
		_annotation_host.selection_changed.disconnect(_on_host_selection_changed)

	# Symmetric teardown for the AnnotationHostRegistry entry.
	if _registered_editor_name != "":
		AnnotationHostRegistry.deregister(_registered_editor_name)
		_registered_editor_name = ""

	_cancel_inflight_eval_if_any()


# ── Buffer-canonical (paired_dsl) reception ─────────────────────────────────
# DCR 019dfa66 §T6. The substrate broker pushes platform-reserved channels
# directly to the panel root via Control.receive(channel, payload). The three
# channels are non-allowlisted (they bypass ipc_channels) — see PluginScenePanelBroker.

## Receive a platform-reserved channel push from the substrate broker.
## Channels: attach_buffer / text_changed / detach_buffer.
func receive(channel: String, payload: Dictionary) -> void:
	match channel:
		"attach_buffer":
			_buffer_path = str(payload.get("path", ""))
			if not _buffer_path.is_empty():
				_document_path = _buffer_path
				_import_notice = ""
			_buffer_version = int(payload.get("version", 0))
			var text: String = str(payload.get("text", ""))
			_pending_dsl_text = text
			# Mirror into the host so MCP introspection has fresh source.
			if _annotation_host != null and _annotation_host.has_method("set_document_source"):
				_annotation_host.set_document_source(_buffer_path, text)
			# Initial render is immediate (no debounce) so the panel paints
			# something as soon as the buffer attaches. Empty/whitespace
			# buffers are skipped — the worker would emit a parse warning,
			# producing a toast on every fresh-empty .mcad open.
			if not text.strip_edges().is_empty():
				_evaluate_with_request_id(text)
		"text_changed":
			_buffer_version = int(payload.get("version", 0))
			var text2: String = str(payload.get("text", ""))
			_pending_dsl_text = text2
			if _annotation_host != null and _annotation_host.has_method("set_document_source"):
				_annotation_host.set_document_source(_buffer_path, text2)
			_start_eval_debounce()
		"detach_buffer":
			_cancel_inflight_eval_if_any()
			# Stop any pending debounce so we don't fire an evaluate against
			# the now-empty _pending_dsl_text after the buffer detaches.
			if _eval_debounce_timer != null:
				_eval_debounce_timer.stop()
			_buffer_path = ""
			_buffer_version = -1
			_pending_dsl_text = ""


## Issue a fresh cad.evaluate with a unique request_id, cancelling any prior
## in-flight evaluate first so the worker doesn't waste cycles on stale text.
func _evaluate_with_request_id(text: String) -> void:
	_cancel_inflight_eval_if_any()
	var rid: String = "eval_%d" % Time.get_ticks_usec()
	# fire-and-await — supersession check inside _evaluate_and_render handles
	# the race where this call completes after a newer one has already landed.
	_evaluate_and_render(text, rid)


## Cancel the current in-flight cad.evaluate (if any) by emitting cad.cancel_eval.
## The worker sees its context cancellation and returns kind=cancelled.
func _cancel_inflight_eval_if_any() -> void:
	if _inflight_request_id == "":
		return
	# Emit fire-and-forget — we don't need a reply correlation for the ack.
	# Empty reply_id signals the IPC helper to drop the response.
	request.emit("cad.cancel_eval", {"request_id": _inflight_request_id}, "")
	_inflight_request_id = ""


## Lazily create the debounce timer and (re)start it. Each text_changed
## resets the timer; the timer fires _on_eval_debounce_timeout once the user
## stops typing for _EVAL_DEBOUNCE_SEC seconds.
func _start_eval_debounce() -> void:
	if _eval_debounce_timer == null:
		_eval_debounce_timer = Timer.new()
		_eval_debounce_timer.one_shot = true
		_eval_debounce_timer.wait_time = _EVAL_DEBOUNCE_SEC
		_eval_debounce_timer.timeout.connect(_on_eval_debounce_timeout)
		add_child(_eval_debounce_timer)
	_eval_debounce_timer.stop()
	_eval_debounce_timer.start()


func _on_eval_debounce_timeout() -> void:
	# Empty/whitespace buffer → cancel any in-flight, but skip dispatching a
	# fresh evaluate (the worker would parse-error, surfacing a toast on
	# every keystroke that empties the buffer).
	if _pending_dsl_text.strip_edges().is_empty():
		_cancel_inflight_eval_if_any()
		return
	_evaluate_with_request_id(_pending_dsl_text)


# ── GUI mesh import ─────────────────────────────────────────────────────────
# The owner picks a mesh file and the panel appends `refN = mesh("path")` to
# the document's own source. Everything the action produces is DSL text, so the
# pose verbs, undo, save and an LLM reading the file all keep working on it —
# and the MCP parity for this action is minerva_doc_write, not a new verb.
#
# The write goes to the DocumentBuffer the substrate attached, which is the one
# the paired text editor is showing. Writing anywhere else — _pending_dsl_text
# alone, a fresh buffer, the file on disk — forks the document in two.

## Resolve the scene's import controls and connect them. Called from _ready.
func _wire_mesh_import() -> void:
	_mesh_import_dialog = $MeshImportDialog as FileDialog
	if _mesh_import_dialog != null:
		# Filters come from the loader's own format list, so nothing can be
		# loadable without being pickable (or the other way round).
		_mesh_import_dialog.filters = _MeshImportScript.dialog_filters()
		if not _mesh_import_dialog.file_selected.is_connected(_on_mesh_file_selected):
			_mesh_import_dialog.file_selected.connect(_on_mesh_file_selected)

	_import_buttons.clear()
	for button_path in [
		"ResponsiveContainer/WideLayout/WideSidebar/ImportMeshButton",
		"ResponsiveContainer/NarrowLayout/ProjectionRow/ImportMeshButton",
	]:
		var button := get_node_or_null(button_path) as Button
		if button == null:
			continue
		if not button.pressed.is_connected(_on_import_mesh_pressed):
			button.pressed.connect(_on_import_mesh_pressed)
		_import_buttons.append(button)


func _on_import_mesh_pressed() -> void:
	if _mesh_import_dialog == null:
		return
	# Open beside the document, which is where a portable relative path can be
	# written; an unsaved document has nowhere to start from.
	if not _document_path.is_empty():
		_mesh_import_dialog.current_dir = _document_path.get_base_dir()
	_mesh_import_dialog.popup_centered_ratio(0.7)


func _on_mesh_file_selected(path: String) -> void:
	import_mesh_file(path)


## Append one `refN = mesh("path")` line for `absolute_path` to the document
## and re-evaluate. Public because the file dialog is not the only caller worth
## having: this is the whole action, and it takes a path.
##
## Returns the import plan — {ok, line, name, path, absolute, warning, error}.
func import_mesh_file(absolute_path: String) -> Dictionary:
	var plan: Dictionary = _MeshImportScript.plan_import(
		_current_source(), absolute_path, _document_path)
	_last_import = plan

	if not bool(plan.get("ok", false)):
		var problem: String = str(plan.get("error", ""))
		push_warning("[CADPanel] import mesh: %s" % problem)
		_show_eval_error("Import mesh — %s" % problem)
		return plan

	_apply_source_edit(str(plan["source"]))

	var warning: String = str(plan.get("warning", ""))
	if not warning.is_empty():
		# Same banner as an evaluation error: it is the panel's one visible
		# message surface, and the next evaluation clears it.
		push_warning("[CADPanel] import mesh: %s" % warning)
		_import_notice = "Import mesh — %s" % warning
		_show_eval_error(_import_notice)
	return plan


## The source as the document currently holds it. The attached buffer wins over
## the panel's mirror: an edit made in the text editor a moment ago is in the
## buffer before the panel's debounce has run.
func _current_source() -> String:
	var buffer: Object = _shared_buffer()
	if buffer != null and "text" in buffer:
		return str(buffer.text)
	return _pending_dsl_text


## Write `new_source` back to the document and start an evaluation.
##
## The buffer's apply_edit bumps its version and fires text_changed, which the
## paired text editor and this panel both receive — one document, two views.
## When no buffer is attached (a panel driven by _on_panel_load_request's
## `source` shape) the panel's own mirror is all there is.
func _apply_source_edit(new_source: String) -> void:
	var buffer: Object = _shared_buffer()
	if buffer != null and buffer.has_method("apply_edit"):
		# The buffer's text_changed push comes back through receive(), which
		# records the text and starts the debounce; doing it here too would
		# evaluate twice.
		buffer.apply_edit(new_source)
		return
	_pending_dsl_text = new_source
	if _annotation_host != null and _annotation_host.has_method("set_document_source"):
		_annotation_host.set_document_source(_buffer_path, new_source)
	# The ordinary typing path: one debounce, one evaluate, whether the text
	# came from the keyboard, from MCP or from here.
	_start_eval_debounce()


## The DocumentBuffer the substrate attached to this panel, or null. Typed
## Object because DocumentBuffer is a host class_name and this script lives
## outside Minerva's res:// tree.
func _shared_buffer() -> Object:
	var broker: Object = _ctx.get("broker", null) as Object
	if broker == null or not broker.has_method("get_attached_buffer"):
		return null
	var panel_name: String = str(_ctx.get("panel_name", ""))
	if panel_name.is_empty():
		return null
	return broker.get_attached_buffer(plugin_id, panel_name)


# ── Save/load contract (overrides MinervaPluginPanel virtuals) ──────────────

func _on_panel_save_request() -> Dictionary:
	# Include the current DSL source so doc_read on an open editor (whether
	# anonymous or path-bound) returns useful content. _pending_dsl_text is the
	# panel's authoritative source — kept in sync by attach_buffer / text_changed
	# (path-bound) and by _on_panel_load_request's `source` branch (anonymous).
	#
	# `last_eval` exposes the worker's most recent verdict on the DSL so MCP
	# callers can verify a doc_write actually rendered. Status values:
	# empty / pending / ok / error / cancelled / timeout. See _last_eval_result
	# decl for the full shape.
	#
	# TODO(later): include annotations + camera states.
	return {
		"version": 1,
		"source": _pending_dsl_text,
		"last_eval": _last_eval_result.duplicate(true),
	}


## Synchronous-apply hook: replaces the current source with `document.source`,
## cancels any in-flight evaluate, skips the text_changed debounce, awaits the
## worker's reply, and returns the resulting last_eval to the caller.
##
## Used by minerva_doc_write so the agent gets eval status (ok / error /
## timeout / cancelled) in the tool reply instead of polling. Mirrors
## _on_panel_load_request's `source` shape on input.
##
## Returns {ok: bool, last_eval: Dictionary}. ok mirrors last_eval.status == "ok".
func _on_panel_apply_sync(document: Dictionary) -> Dictionary:
	var src: String = str(document.get("source", ""))
	_pending_dsl_text = src
	if _annotation_host != null and _annotation_host.has_method("set_document_source"):
		_annotation_host.set_document_source(_buffer_path, src)

	if src.strip_edges().is_empty():
		_last_eval_result = {
			"status": "empty",
			"ts": Time.get_unix_time_from_system(),
		}
		return {"ok": true, "last_eval": _last_eval_result.duplicate(true)}

	# Race guard: when minerva_create_plugin_editor mounts a fresh paired_dsl
	# panel and the agent's first minerva_doc_write fires immediately after,
	# _MinervaIPC may not be queryable yet — the helper is attached as a
	# child of the panel root during broker.register_panel, but tree-mount
	# timing inside Editor.create_plugin_scene → instantiate_into can leave
	# get_node_or_null returning null on the very next request. Wait one
	# process frame and re-check; if still missing, fall back to the
	# debounce-driven async eval rather than failing the agent's call.
	if get_node_or_null("_MinervaIPC") == null:
		await get_tree().process_frame
	if get_node_or_null("_MinervaIPC") == null:
		# Helper still not reachable — let the existing text_changed → debounce
		# path carry this eval (the buffer.apply_edit upstream of this call has
		# already fired text_changed, which started the debounce timer). Surface
		# "pending" so the agent knows to verify via doc_read once the worker
		# replies. Don't cancel the in-flight or stop the debounce here — those
		# are exactly the things we want to leave running.
		_last_eval_result = {
			"status": "pending",
			"ts": Time.get_unix_time_from_system(),
		}
		return {"ok": true, "last_eval": _last_eval_result.duplicate(true)}

	# Helper is ready — synchronous eval as originally intended. Cancel any
	# in-flight + skip the debounce so the MCP caller gets a tight request →
	# response round-trip without a competing debounced eval landing late.
	_cancel_inflight_eval_if_any()
	if _eval_debounce_timer != null:
		_eval_debounce_timer.stop()

	var rid: String = "eval_sync_%d" % Time.get_ticks_usec()
	await _evaluate_and_render(src, rid)
	var status: String = str(_last_eval_result.get("status", ""))
	return {
		"ok": status == "ok",
		"last_eval": _last_eval_result.duplicate(true),
	}


func _on_panel_load_request(document: Dictionary) -> void:
	# Two load shapes are accepted:
	#  1. {source: "<DSL text>"} — in-memory DSL, used for anonymous editors
	#     created via minerva_create_plugin_editor + minerva_doc_write. No disk
	#     read; the panel just evaluates the supplied text.
	#  2. {file_path: "<absolute path>"} — disk-backed .mcad file (the host
	#     dispatches this when an .mcad is opened via File → Open).
	#
	# When BOTH are present, `source` wins (caller is forcing a new in-memory
	# version on top of a path-bound editor; tab will dirty until Save-As).
	if document.has("source"):
		var src: String = str(document.get("source", ""))
		_pending_dsl_text = src
		# No file path yet for anonymous editors; pass empty so MCP introspection
		# knows the source is unbacked. set_document_source still wires up the
		# panel's source-of-truth for annotations etc.
		if _annotation_host != null and _annotation_host.has_method("set_document_source"):
			_annotation_host.set_document_source(_buffer_path, src)
		if not src.strip_edges().is_empty():
			_evaluate_with_request_id(src)
		return

	# Round 3: live `.mcad` → CAD panel pipeline. The host loads the file path
	# from the editor; we read the DSL text off disk and round-trip it through
	# the worker's `evaluate` method. The reply carries {shape_name, mesh, edges}
	# which we push to all 5 MeshDisplay instances + the edge overlays + the
	# sidebar Tree.
	var file_path: String = str(document.get("file_path", ""))
	if file_path.is_empty():
		return

	var fa := FileAccess.open(file_path, FileAccess.READ)
	if fa == null:
		push_warning(
			"[CADPanel] _on_panel_load_request: cannot open '%s' (err=%d)"
			% [file_path, FileAccess.get_open_error()]
		)
		return
	var dsl_text: String = fa.get_as_text()
	fa.close()
	_document_path = file_path
	_import_notice = ""

	# Push document source into host so MCP can read it without IPC.
	if _annotation_host != null and _annotation_host.has_method("set_document_source"):
		_annotation_host.set_document_source(file_path, dsl_text)

	_pending_dsl_text = dsl_text
	_evaluate_and_render(dsl_text)


## Round-trip a DSL string through the worker's evaluate method and update the
## panel state (meshes, edges, sidebar) with the result. Centralised so a future
## bottom-split editor (`019dd0211893`) can call the same path on save/run.
##
## paired_dsl callers pass a request_id so cad.cancel_eval can cancel the
## in-flight evaluate when a newer text_changed arrives. The post-await
## supersession check drops stale results so a slow eval that finishes after
## a newer one has already landed doesn't clobber the panel state.
func _evaluate_and_render(dsl_text: String, request_id: String = "") -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_last_eval_result = {
			"status": "error",
			"error_kind": "ipc_unavailable",
			"error_message": "MinervaIPC helper not attached; cannot dispatch cad.evaluate",
			"request_id": request_id,
			"ts": Time.get_unix_time_from_system(),
		}
		push_warning("[CADPanel] _evaluate_and_render: MinervaIPC helper not attached; cannot dispatch cad.evaluate")
		_show_eval_error("CAD evaluation unavailable — the panel's IPC helper is not attached.")
		return

	var reply_id := "cad.evaluate:" + str(Time.get_ticks_usec())
	var args: Dictionary = {"source": dsl_text}
	if request_id != "":
		args["request_id"] = request_id
		_inflight_request_id = request_id
	# Mark pending BEFORE the await so a same-tick doc_read sees pending, not
	# stale prior result.
	_last_eval_result = {
		"status": "pending",
		"request_id": request_id,
		"ts": Time.get_unix_time_from_system(),
	}
	# A fresh evaluate supersedes any prior failure — clear a stale banner.
	_hide_eval_error()
	request.emit("cad.evaluate", args, reply_id)

	# 90s timeout: build123d cold-start on macOS ARM takes >30s in practice
	# (Python module import + cadquery-ocp dylib first-launch caching +
	# Gatekeeper scans on every nested arm64 binary). The previous 30s value
	# was too tight; warm-start evals complete in <1s so the headroom only
	# costs us when something is genuinely broken.
	var result: Dictionary = await ipc.await_reply(reply_id, 90000)

	# Supersession: if a newer evaluate started while we were awaiting, drop
	# this result. The newer evaluate set _inflight_request_id to its own id;
	# our cancel_eval may have already triggered the worker's cancellation,
	# in which case `result` is a worker error kind=cancelled.
	if request_id != "" and _inflight_request_id != request_id:
		# Don't overwrite _last_eval_result — the newer evaluate owns it.
		return
	if request_id != "":
		_inflight_request_id = ""

	if not bool(result.get("success", false)):
		var err_code: String = str(result.get("error_code", "unknown"))
		var err_msg: String = str(result.get("error_message", ""))
		# IPC-layer timeout surfaces as success=false with a timeout-ish code.
		var st: String = "timeout" if err_code.findn("timeout") != -1 else "error"
		_last_eval_result = {
			"status": st,
			"error_kind": err_code,
			"error_message": err_msg,
			"request_id": request_id,
			"ts": Time.get_unix_time_from_system(),
		}
		push_warning(
			"[CADPanel] cad.evaluate transport failure: %s — %s"
			% [err_code, err_msg]
		)
		var _what: String = "timed out" if st == "timeout" else "failed"
		_show_eval_error("CAD evaluation %s: %s" % [_what,
			err_msg if err_msg != "" else err_code])
		return

	# PluginScenePanelBroker wraps the worker payload in PluginErrors.success(),
	# so the visible shape is:
	#   result = {success:true, result: <worker_payload>}
	# where <worker_payload> is the raw worker dict {ok, result|error}.
	var worker_payload: Dictionary = result.get("result", {})
	if not (worker_payload is Dictionary):
		_last_eval_result = {
			"status": "error",
			"error_kind": "missing_worker_payload",
			"error_message": "cad.evaluate reply had no Dictionary payload",
			"request_id": request_id,
			"ts": Time.get_unix_time_from_system(),
		}
		push_warning("[CADPanel] cad.evaluate: missing worker payload")
		_show_eval_error("CAD evaluation failed — the worker reply was malformed.")
		return

	if not bool(worker_payload.get("ok", false)):
		# Worker may emit `error` as either a structured dict {kind, message} or a
		# bare string for older/parse-stage error paths. Defend against both.
		var err_var: Variant = worker_payload.get("error", {})
		var err: Dictionary = err_var if err_var is Dictionary else {}
		var kind: String = str(err.get("kind", "unknown"))
		var msg: String = str(err.get("message", err_var if err_var is String else ""))
		# kind=cancelled is the expected outcome of cad.cancel_eval — a newer
		# evaluate raced past this one. Silent return; no toast.
		if kind == "cancelled":
			_last_eval_result = {
				"status": "cancelled",
				"error_kind": kind,
				"request_id": request_id,
				"ts": Time.get_unix_time_from_system(),
			}
			return
		_last_eval_result = {
			"status": "error",
			"error_kind": kind,
			"error_message": msg,
			"request_id": request_id,
			"ts": Time.get_unix_time_from_system(),
		}
		push_warning("[CADPanel] cad.evaluate worker error [%s]: %s" % [kind, msg])
		_show_eval_error("CAD evaluation failed (%s): %s" % [kind,
			msg if msg != "" else "no detail provided"])
		return

	var eval_result: Dictionary = worker_payload.get("result", {}) as Dictionary
	var mesh_data: Dictionary = eval_result.get("mesh", {}) as Dictionary
	var edges_var: Variant = eval_result.get("edges", [])
	var edges: Array = edges_var if edges_var is Array else []
	if _DEBUG_EDGE_PICK:
		print("[edge-pick] eval-response eval_result.keys=%s edges_var.type=%s edges.size=%d mesh.keys=%s" % [
			str(eval_result.keys()),
			str(typeof(edges_var)),
			edges.size(),
			str(mesh_data.keys()),
		])

	# Mount the referenced mesh files first: update_mesh auto-frames, and the
	# frame has to cover the references as well as the solid.
	var references_var: Variant = eval_result.get("references", [])
	_mount_references(references_var if references_var is Array else [])

	# Push mesh into all 5 MeshDisplay instances. The MeshRoot Node3D in each
	# SubViewport has scripts/mesh_display.gd attached, exposing update_mesh().
	for path in _MESH_ROOT_PATHS:
		var mr := get_node_or_null(path)
		if mr != null and mr.has_method("update_mesh"):
			mr.call("update_mesh", mesh_data, edges)

	# Update panel state and re-push edge overlays + sidebar tree.
	_last_mesh_data = mesh_data
	_edge_registry = edges
	# Mirror into host so MCP introspection tools can read without reaching into the panel.
	if _annotation_host != null:
		if _annotation_host.has_method("set_mesh_data"):
			_annotation_host.set_mesh_data(mesh_data)
		if _annotation_host.has_method("set_edge_registry"):
			_annotation_host.set_edge_registry(edges)
	_push_mesh_to_geometry_overlays()
	_render_edge_tree(_edge_registry)
	# Re-apply mesh visibility (ortho panes hide the shaded mesh; iso shows it).
	_apply_mesh_visibility()
	# update_mesh auto-framed every pane just now. A note restore's saved view
	# outranks that framing, and is applied here exactly once.
	_CadNoteScript.apply_pending_camera(self)

	# Mark the eval as ok so minerva_doc_read can verify success after a write.
	# shape_name comes straight from the worker (the named output the DSL
	# bound — e.g. the last assigned shape variable).
	_last_eval_result = {
		"status": "ok",
		"shape_name": str(eval_result.get("shape_name", "")),
		# Vertices arrive as a flat float array; 3 entries per vertex.
		"vertex_count": int(float((mesh_data.get("vertices", []) as Array).size()) / 3.0),
		"edge_count": edges.size(),
		"reference_count": int(_reference_report.get("mounted", 0)),
		"references": _reference_report.get("statuses", []),
		"request_id": request_id,
		"ts": Time.get_unix_time_from_system(),
	}
	# Render succeeded — clear any error banner left by a prior failed evaluate.
	_hide_eval_error()
	# A reference that could not be loaded — or that was too big to outline —
	# is not an evaluation failure: the solid is on screen and correct. It
	# still has to be said out loud, or the board the user expected is simply
	# missing with no explanation. The lines name the reference and the reason.
	var reference_lines: PackedStringArray = _reference_report.get(
		"status_lines", PackedStringArray())
	if not reference_lines.is_empty():
		_show_eval_error("Reference mesh: %s" % "\n".join(reference_lines))


## Show the evaluation-error banner with a human-readable message. Called from
## _evaluate_and_render's failure paths so a failed render is never silent
## (the empty-render symptom of RCA 019e46b5).
func _show_eval_error(message: String) -> void:
	if _error_banner_label != null:
		_error_banner_label.text = message
	if _error_banner != null:
		_error_banner.visible = true


## Hide the evaluation-error banner — a fresh evaluate started, or one succeeded.
## An import notice outlives evaluations: it stays until the buffer has a path.
## Save-As rebinds the attached buffer in place rather than re-attaching it, so
## the path is read from the buffer here, not from an attach event.
func _hide_eval_error() -> void:
	if not _import_notice.is_empty():
		var buffer: Object = _shared_buffer()
		var buffer_path: Variant = buffer.get("file_path") if buffer != null else null
		if buffer_path is String and not (buffer_path as String).is_empty():
			_import_notice = ""
		else:
			_show_eval_error(_import_notice)
			return
	if _error_banner != null:
		_error_banner.visible = false


# ── Width-class handling ────────────────────────────────────────────────────

## Called whenever the ResponsiveContainer crosses a breakpoint.
func _on_width_class_changed(new_class: StringName) -> void:
	_apply_width_class(new_class)


## Apply the layout for the given width class. Idempotent.
##   xs / sm  → narrow (single view + projection dropdown)
##   md / lg / xl → wide (4-view 2×2 grid + edge-tree sidebar)
##
## WideLayout sizing: each viewport column has a 300 px minimum (.tscn) and
## WideSidebar has a 220 px minimum, so the layout fits any panel width
## ≥ 820 px. That covers all of MD (≥ 768) in the realistic case where the
## substrate AnnotationDockPane is open (dock RIGHT activates at editor width
## ≥ 1024 and consumes ~260 px, leaving the CAD plugin ~764+ px). NarrowLayout
## kicks in below MD, where 4 ortho panes simply can't be useful.
func _apply_width_class(cls: StringName) -> void:
	var is_narrow := (
		cls == _ResponsiveContainerScript.CLASS_XS
		or cls == _ResponsiveContainerScript.CLASS_SM
	)

	if _wide_layout != null:
		_wide_layout.visible = not is_narrow
	if _narrow_layout != null:
		_narrow_layout.visible = is_narrow

	# Reparent the canvas to the appropriate viewport container.
	_reparent_canvas(is_narrow)

	# Re-register SubViewports with the host so render_content_to_image
	# captures the visible layout's panes (the "top"/"front"/"right" ids
	# overlap between layouts but resolve to different SubViewports).
	_register_host_viewports(is_narrow)

	# Ortho x-ray for the narrow single view depends on the current dropdown selection.
	_apply_mesh_visibility()


## Populate Cad_AnnotationHost's viewport map for the active layout. Called
## from _ready() (initial state) and _apply_width_class() (transitions).
func _register_host_viewports(is_narrow: bool) -> void:
	if _annotation_host == null:
		return
	# Resolve cameras used in wide mode.
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	var iso_cam: Camera3D   = get_node_or_null(grid + "/IsoView/SubViewport/OrbitCamera")   as Camera3D
	var top_cam: Camera3D   = get_node_or_null(grid + "/TopView/SubViewport/OrbitCamera")   as Camera3D
	var front_cam: Camera3D = get_node_or_null(grid + "/FrontView/SubViewport/OrbitCamera") as Camera3D
	var right_cam: Camera3D = get_node_or_null(grid + "/RightView/SubViewport/OrbitCamera") as Camera3D
	if is_narrow:
		var single_vp: SubViewport = _single_view_container.get_node("SubViewport") as SubViewport
		# In narrow mode every projection id (incl. "iso") resolves to the
		# single SubViewport whose camera preset the dropdown drives.
		for proj in ["perspective", "top", "bottom", "front", "back", "left", "right", "iso"]:
			_annotation_host.set_viewport_for(proj, single_vp)
		# Register the single-view camera under the active viewport id.
		if _annotation_host.has_method("set_camera_for"):
			for proj in ["perspective", "top", "bottom", "front", "back", "left", "right", "iso"]:
				_annotation_host.set_camera_for(proj, _single_view_camera)
		# Register the single container for all narrow-mode pane ids so
		# viewport_rect computation finds the right container.
		if _annotation_host.has_method("set_container_for"):
			for proj in ["perspective", "top", "bottom", "front", "back", "left", "right", "iso"]:
				_annotation_host.set_container_for(proj, _single_view_container)
	else:
		var iso_vp: SubViewport   = _iso_view_container.get_node("SubViewport") as SubViewport
		var top_vp: SubViewport   = _top_view_container.get_node("SubViewport") as SubViewport
		var front_vp: SubViewport = _front_view_container.get_node("SubViewport") as SubViewport
		var right_vp: SubViewport = _right_view_container.get_node("SubViewport") as SubViewport
		_annotation_host.set_viewport_for("iso", iso_vp)
		_annotation_host.set_viewport_for("top", top_vp)
		_annotation_host.set_viewport_for("front", front_vp)
		_annotation_host.set_viewport_for("right", right_vp)
		# Register per-pane cameras for multi-pane annotation projection (Round 2a-Unit2).
		if _annotation_host.has_method("set_camera_for"):
			_annotation_host.set_camera_for("iso", iso_cam)
			_annotation_host.set_camera_for("top", top_cam)
			_annotation_host.set_camera_for("front", front_cam)
			_annotation_host.set_camera_for("right", right_cam)
		# Register per-pane containers for viewport_rect computation (Round 2b-α Unit 1).
		if _annotation_host.has_method("set_container_for"):
			_annotation_host.set_container_for("iso",   _iso_view_container)
			_annotation_host.set_container_for("top",   _top_view_container)
			_annotation_host.set_container_for("front", _front_view_container)
			_annotation_host.set_container_for("right", _right_view_container)
		# Narrow-only ids unset in wide mode (they'd be unreachable anyway).
		for proj in ["perspective", "bottom", "back", "left"]:
			_annotation_host.set_viewport_for(proj, null)
			if _annotation_host.has_method("set_camera_for"):
				_annotation_host.set_camera_for(proj, null)
			if _annotation_host.has_method("set_container_for"):
				_annotation_host.set_container_for(proj, null)


## Update the active viewport id when the layout changes.
##
## Round 2b-α Unit 1: the canvas is permanently parented to _canvas_overlay
## (a full-rect Control above ALL SubViewportContainers), so we no longer
## reparent it on wide↔narrow transitions. We only update the host's active
## viewport id so MCP queries and render_content_to_image target the right pane.
## (Previously this method moved the canvas between iso and single-view containers;
## that approach caused leaders for non-iso panes to draw at wrong positions.)
func _reparent_canvas(narrow: bool) -> void:
	if narrow:
		_active_viewport_id = _projection_preset_to_viewport_id(_current_projection_preset())
	else:
		_active_viewport_id = "iso"
	if _annotation_host != null and _annotation_host.has_method("set_active_viewport"):
		_annotation_host.set_active_viewport(_active_viewport_id)


# ── Projection dropdown handling (narrow mode) ──────────────────────────────

## Called when the user picks an item from the narrow-layout projection
## dropdown. Updates the single-view camera preset.
func _on_projection_selected(index: int) -> void:
	if _single_view_camera == null:
		return
	var preset: String = "Perspective"
	if index >= 0 and index < _PROJECTION_OPTIONS.size():
		preset = String(_PROJECTION_OPTIONS[index]["preset"])
	_single_view_camera.set_view_preset(preset)
	# Update the host's active viewport id so MCP queries get the right context.
	_active_viewport_id = _projection_preset_to_viewport_id(preset)
	if _annotation_host != null and _annotation_host.has_method("set_active_viewport"):
		_annotation_host.set_active_viewport(_active_viewport_id)
	# Update the single-view geometry overlay camera and toggle mesh visibility.
	var single_ov: Control = _geometry_overlays.get("single", null) as Control
	if single_ov != null and single_ov.has_method("set_camera"):
		single_ov.call("set_camera", _single_view_camera)
	_apply_mesh_visibility()


## Return the preset string ("Perspective", "Top", ...) currently selected in
## the dropdown. Defaults to "Perspective" if the dropdown is missing/unset.
func _current_projection_preset() -> String:
	if _projection_dropdown == null:
		return "Perspective"
	var idx: int = _projection_dropdown.selected
	if idx < 0 or idx >= _PROJECTION_OPTIONS.size():
		return "Perspective"
	return String(_PROJECTION_OPTIONS[idx]["preset"])


## Map an orbit-camera preset string to the lower-case viewport-id used by
## Cad_AnnotationHost.get_view_context().
func _projection_preset_to_viewport_id(preset: String) -> String:
	return preset.to_lower()


# ── Edge overlay / sidebar wiring ───────────────────────────────────────────

## Build the wide-mode edge Tree under WideSidebar.
## Three buttons (Prev / Next / Clear) sit beneath the tree.
func _build_edge_sidebar() -> void:
	if _wide_sidebar == null:
		return

	var hr := HSeparator.new()
	hr.name = "EdgeSidebarSeparator"
	_wide_sidebar.add_child(hr)

	var label := Label.new()
	label.name = "EdgeSidebarHeader"
	label.text = "Edge Markers"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wide_sidebar.add_child(label)

	_edge_tree = Tree.new()
	_edge_tree.name = "EdgeTree"
	_edge_tree.focus_mode = Control.FOCUS_NONE
	_edge_tree.hide_root = true
	_edge_tree.columns = 3
	_edge_tree.set_column_title(0, "id")
	_edge_tree.set_column_title(1, "len/r")
	_edge_tree.set_column_title(2, "kind")
	_edge_tree.set_column_titles_visible(true)
	_edge_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edge_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_edge_tree.custom_minimum_size = Vector2(0, 180)
	_edge_tree.item_selected.connect(_on_edge_tree_item_selected)
	_wide_sidebar.add_child(_edge_tree)

	var btn_row := HBoxContainer.new()
	btn_row.name = "EdgeButtons"
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wide_sidebar.add_child(btn_row)

	var prev_btn := Button.new()
	prev_btn.text = "Prev"
	prev_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prev_btn.pressed.connect(_on_prev_edge_pressed)
	btn_row.add_child(prev_btn)

	var next_btn := Button.new()
	next_btn.text = "Next"
	next_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	next_btn.pressed.connect(_on_next_edge_pressed)
	btn_row.add_child(next_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_btn.pressed.connect(_on_clear_edge_pressed)
	btn_row.add_child(clear_btn)


## Populate the edge Tree from the current edge_registry.
func _render_edge_tree(edges: Array) -> void:
	if _edge_tree == null:
		return
	_edge_tree.clear()
	_edge_tree_items.clear()
	var root := _edge_tree.create_item()
	if edges.is_empty():
		var empty_item := _edge_tree.create_item(root)
		empty_item.set_text(0, "")
		empty_item.set_text(1, "(no edges)")
		empty_item.set_text(2, "")
		return
	# Sort by edge id ascending.
	var sorted: Array = edges.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("id", 0)) < int(b.get("id", 0))
	)
	for edge_info in sorted:
		if not (edge_info is Dictionary):
			continue
		var edge_id := int(edge_info.get("id", 0))
		var kind := str(edge_info.get("kind", "straight"))
		var measure_text := ""
		if kind == "circle":
			measure_text = "%.1f" % float(edge_info.get("radius", 0.0))
		else:
			measure_text = "%.1f" % float(edge_info.get("length", 0.0))
		var item := _edge_tree.create_item(root)
		item.set_text(0, str(edge_id))
		item.set_metadata(0, edge_id)
		item.set_text(1, measure_text)
		item.set_text(2, kind)
		_edge_tree_items[edge_id] = item


## Push the current mesh data + per-pane cameras to every Cad_GeometryOverlay.
## Called whenever a new mesh arrives from the DSL→mesh bridge.
func _push_mesh_to_geometry_overlays() -> void:
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	var view_cameras := {
		"top":   get_node_or_null(grid + "/TopView/SubViewport/OrbitCamera") as Camera3D,
		"front": get_node_or_null(grid + "/FrontView/SubViewport/OrbitCamera") as Camera3D,
		"right": get_node_or_null(grid + "/RightView/SubViewport/OrbitCamera") as Camera3D,
		"iso":   get_node_or_null(grid + "/IsoView/SubViewport/OrbitCamera") as Camera3D,
		"single": _single_view_camera,
	}
	for ov_id in _geometry_overlays.keys():
		var ov: Control = _geometry_overlays[ov_id] as Control
		if _DEBUG_EDGE_PICK:
			print("[edge-pick] connect ov_id=%s ov=%s script=%s" % [
				ov_id,
				str(ov),
				str(ov.get_script()) if ov != null else "<null-node>",
			])
		if ov == null:
			continue
		if ov.has_method("set_mesh_data"):
			ov.call("set_mesh_data", _last_mesh_data)
		var cam: Camera3D = view_cameras.get(ov_id, null)
		if ov.has_method("set_camera"):
			ov.call("set_camera", cam)
		if ov.has_method("set_edge_registry"):
			ov.call("set_edge_registry", _edge_registry)
		# Connect the overlay's pick signal to the panel's selection handler.
		# Idempotent — repeated _push_mesh_to_geometry_overlays() calls
		# (re-evaluate, layout swap) MUST NOT stack callbacks.
		var has_sig: bool = ov.has_signal("edge_selected")
		var already: bool = has_sig and ov.edge_selected.is_connected(_on_edge_selected)
		if has_sig and not already:
			ov.edge_selected.connect(_on_edge_selected)
		if _DEBUG_EDGE_PICK:
			print("[edge-pick]   has_signal=%s already_connected=%s mouse_filter=%s" % [
				str(has_sig),
				str(already),
				str(ov.mouse_filter),
			])
	_apply_mesh_visibility()


## Hide the shaded mesh in ortho-only panes (Top/Front/Right; narrow non-
## perspective) so the edge overlay is the only visualisation. Iso /
## Perspective keeps the mesh visible for shaded 3-D context.
func _apply_mesh_visibility() -> void:
	var grid := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
	# Wide-layout panes: Top/Front/Right hide mesh; Iso shows it.
	_set_pane_mesh_visible(grid + "/TopView/SubViewport/MeshRoot", false)
	_set_pane_mesh_visible(grid + "/FrontView/SubViewport/MeshRoot", false)
	_set_pane_mesh_visible(grid + "/RightView/SubViewport/MeshRoot", false)
	_set_pane_mesh_visible(grid + "/IsoView/SubViewport/MeshRoot", true)
	# Narrow single view: hide mesh unless the projection is Perspective.
	var single_path := "ResponsiveContainer/NarrowLayout/SingleView/SubViewport/MeshRoot"
	var preset := _current_projection_preset()
	_set_pane_mesh_visible(single_path, preset == "Perspective")


## Toggle the MeshInstance3D inside a MeshRoot. Found by the well-known child
## name "MeshInstance" set in mesh_display.gd._ready(). Reference meshes follow
## the same rule: shaded in the perspective pane, outline-only in the orthos.
func _set_pane_mesh_visible(mesh_root_path: String, visible_flag: bool) -> void:
	var mesh_root := get_node_or_null(mesh_root_path)
	if mesh_root == null:
		return
	var mi := mesh_root.get_node_or_null("MeshInstance")
	if mi != null and "visible" in mi:
		mi.visible = visible_flag
	if _reference_library != null and mesh_root is Node3D:
		_reference_library.set_shaded_visible(mesh_root as Node3D, visible_flag)


## Identity of the mounted reference set: which files, at which content stamp,
## in which pose. Colliders and segmentation are keyed on it.
func _compute_reference_digest() -> String:
	var parts := PackedStringArray()
	for entry in get_reference_state():
		var record: Dictionary = entry
		# units and up are baked into the converted part transforms, so a
		# digest without them lets a units= edit keep stale colliders.
		parts.append("%s@%s@%s@%s@%s" % [
			str(record.get("resolved_path", "")),
			str(record.get("stamp", "")),
			str(record.get("units", "")),
			str(record.get("up", "")),
			str(record.get("pose", Transform3D.IDENTITY)),
		])
	return "|".join(parts)


## Mount the evaluation's reference meshes under every MeshRoot and hand each
## MeshDisplay the world bounds so auto-framing covers them.
func _mount_references(references: Array) -> void:
	_reference_report = {}
	_last_references = references
	if _reference_library == null:
		return
	var mesh_roots: Array = []
	for path in _MESH_ROOT_PATHS:
		var mesh_root := get_node_or_null(path) as Node3D
		if mesh_root != null:
			mesh_roots.append(mesh_root)
	_reference_report = _reference_library.mount_all(references, _document_path, mesh_roots)
	# The colliders are rebuilt lazily, on the next measurement: a pose edit
	# arrives on every keystroke and building 45 trimeshes costs a quarter of
	# a second. The digest below is what decides whether that rebuild is real
	# work or a no-op.
	_reference_digest = _compute_reference_digest()
	if _reference_selection != null:
		_reference_selection.set_records(get_reference_state())
	var world_aabb: AABB = _reference_report.get("world_aabb", AABB())
	for mesh_root in mesh_roots:
		if mesh_root.has_method("set_reference_aabb"):
			mesh_root.call("set_reference_aabb", world_aabb)
	for warning in _reference_report.get("warnings", PackedStringArray()):
		push_warning("[CADPanel] reference mesh: %s" % warning)
	for problem in _reference_report.get("errors", PackedStringArray()):
		push_warning("[CADPanel] reference mesh: %s" % problem)


## Push a new edge selection to the host and geometry overlays, then sync the tree.
## Single entry point for all callers (overlay clicks, Prev/Next, Clear).
func _select_edge(edge_id: int) -> void:
	if _annotation_host != null:
		_annotation_host.set_selected_edge_id(edge_id)
	for ov_id in _geometry_overlays.keys():
		var ov: Control = _geometry_overlays[ov_id] as Control
		if ov != null and ov.has_method("set_selected_edge"):
			ov.call("set_selected_edge", edge_id)
	_update_tree_selection()


func _on_edge_selected(edge_id: int) -> void:
	if _DEBUG_EDGE_PICK:
		print("[edge-pick] CADPanel._on_edge_selected edge_id=%d" % edge_id)
	_select_edge(edge_id)


func _on_edge_tree_item_selected() -> void:
	if _suppress_tree_selection or _edge_tree == null:
		return
	var item: TreeItem = _edge_tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if meta == null:
		return
	var edge_id := int(meta)
	if _annotation_host != null:
		_annotation_host.set_selected_edge_id(edge_id)
	for ov_id in _geometry_overlays.keys():
		var ov: Control = _geometry_overlays[ov_id] as Control
		if ov != null and ov.has_method("set_selected_edge"):
			ov.call("set_selected_edge", edge_id)


## Called when the host emits selection_changed (annotation selection). Also
## called directly after edge selection changes so the tree row stays current.
func _on_host_selection_changed(_annotation_id: String = "") -> void:
	_update_tree_selection()


## Update the tree's highlighted row to match the host's current edge selection.
## Reads from host; writes no panel-local state.
func _update_tree_selection() -> void:
	if _edge_tree == null or _annotation_host == null:
		return
	var edge_id: int = _annotation_host.get_selected_edge_id()
	_suppress_tree_selection = true
	if edge_id != -1 and _edge_tree_items.has(edge_id):
		var item: TreeItem = _edge_tree_items[edge_id]
		_edge_tree.set_selected(item, 0)
		_edge_tree.scroll_to_item(item, true)
	else:
		_edge_tree.deselect_all()
	_suppress_tree_selection = false


func _on_prev_edge_pressed() -> void:
	_step_selected_edge(-1)


func _on_next_edge_pressed() -> void:
	_step_selected_edge(1)


func _on_clear_edge_pressed() -> void:
	_select_edge(-1)


func _step_selected_edge(delta: int) -> void:
	var ids: Array = []
	for edge_info in _edge_registry:
		if edge_info is Dictionary:
			ids.append(int(edge_info.get("id", 0)))
	ids.sort()
	var current_id: int = -1
	if _annotation_host != null:
		current_id = _annotation_host.get_selected_edge_id()
	if ids.is_empty():
		_select_edge(-1)
		return
	if current_id == -1:
		_select_edge(ids[0] if delta >= 0 else ids[ids.size() - 1])
		return
	var idx := ids.find(current_id)
	if idx == -1:
		_select_edge(ids[0])
		return
	var next_idx := posmod(idx + delta, ids.size())
	_select_edge(ids[next_idx])


# ── Host note hooks ─────────────────────────────────────────────────────────
#
# Four duck-typed hooks the host calls on this scene (Minerva's
# PluginScenePanelHost holds the contract):
#
#   _on_panel_inject_toggle_changed(enabled) — fire-and-forget acknowledgement.
#   _on_panel_create_note_request(ctx)       — AWAITED; returns the note. A
#       plugin_data note, so opening it reopens a live CAD tab rather than
#       showing a dead screenshot. Returning null would fall back to exactly
#       that screenshot.
#   _on_panel_restore_from_note(payload)     — NOT awaited; returns a bool.
#   _on_panel_render_for_llm(ctx)            — NOT awaited; returns the
#       canonical MultimodalPayload. It must not be a coroutine: the host does
#       not await it and would receive a coroutine state instead of an Array.
#
# Undo and redo are deliberately absent. The panel keeps no history of its own
# — the DSL text is the document and the paired text editor owns its undo — so
# implementing the hooks would put two undo stacks on one document.
#
# All four payloads live in scripts/cad_note.gd; what follows is wiring.

## Tracks whether the user has the inject toggle on. The note itself does not
## depend on it: Save-to-Note and chat injection both want the same document.
var _inject_enabled: bool = false


func _on_panel_inject_toggle_changed(enabled: bool) -> void:
	_inject_enabled = enabled


func _on_panel_create_note_request(ctx: Dictionary) -> Variant:
	return await _CadNoteScript.build_note(ctx, self)


func _on_panel_restore_from_note(payload: Dictionary) -> bool:
	return _CadNoteScript.restore(payload, self)


func _on_panel_render_for_llm(render_ctx: Dictionary) -> Array:
	return _CadNoteScript.render_parts(self, render_ctx)
