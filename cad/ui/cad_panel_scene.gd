extends MinervaPluginPanel

## cad_panel_scene.gd — the CAD panel's scene half: the panes it draws in,
## the annotation host they feed, and the modules that answer questions about
## the geometry once it is there.
##
## This is the BASE of the panel script: ui/CADPanel.gd extends it and holds
## the other half — the document, its buffer and the evaluations it runs.
## Inheritance rather than a handle, because both halves are the one node the
## scene instantiates and the host calls its hooks on. The dependency runs one
## way: the document half reads the panes, the modules and the mesh push that
## live here, and nothing here reaches back up.
##
## Layout — platform widgets:
##   * ResponsiveContainer wraps the panel content. width_class drives a
##     stack-style swap between WideLayout (4-view + sidebar HSplit) and
##     NarrowLayout (single-view + projection dropdown + tools).
##   * The platform AnnotationDockPane (auto-mounted via get_annotation_host())
##     provides annotation tooling. CADPanel owns only the CAD-specific edge
##     geometry inspector tree in the wide sidebar.
##
## Off-tree class_name gotcha:
##   This plugin lives at ~/github/minerva-plugins/cad/, OUTSIDE Minerva's res:// tree,
##   so Godot's parser cache cannot statically resolve plugin or platform
##   class_names from typed field declarations in this file. Fields whose
##   types are platform classes (ResponsiveContainer) are typed with the
##   platform BASE class (Container) or kept untyped, and assigned via
##   preload(...).new(). Property access and signal subscription works via
##   duck typing.

## Ownership marker for the panel-executed tool dispatcher: fallback-resolved
## panels (AnnotationHostRegistry path) aren't broker-keyed by editor name, so
## the dispatcher reads this duck-typed property to verify the calling tool's
## plugin owns this panel (fail-safe deny otherwise).
var plugin_id: String = "cad"

const _CadAnnotationHostScript: Script = preload("CadAnnotationHost.gd")
const _ResponsiveContainerScript: Script = preload("res://Scripts/UI/Controls/responsive_container.gd")
const _BuiltinKindsScript: Script = preload("res://Scripts/Services/Annotations/BuiltinKinds.gd")
const _CadEdgeNumberKindScript: Script = preload("kinds/cad_edge_number_kind.gd")

## Panel-executed MCP tool surface (executor: "panel" —
## see handle_tool() below and panel_tools.gd's doc comment for the contract).
const _PanelToolsScript: Script = preload("panel_tools.gd")
## Foreign mesh files named by mesh() in the source: loading, unit/up-axis
## conversion, pose and mounting all live here. The panel only wires it up.
const _ReferenceMeshesScript: Script = preload("scripts/reference_meshes.gd")
## The three host note hooks — plugin_data payload, restore and the
## LLM rendering — live here; the panel below is wiring only.
const _CadNoteScript: Script = preload("scripts/cad_note.gd")
## The GUI "Import mesh…" action — the file picker, the button in each layout,
## and the `refN = mesh("path")` line the picked file becomes.
const _MeshImportUiScript: Script = preload("scripts/mesh_import_ui.gd")
## Measurement: propose candidates by fitting primitives to a reference mesh,
## then verify and measure them against physics colliders. Both are pure
## modules; the panel only holds them and hands them the mounted references.
## Which reference node the user is pointing at: the per-pane click nodes, the
## sidebar list, the selection itself and the point anchors made from it.
## The per-panel store of evaluated parts; this panel drops its own slot when
## the tab closes.
const _PartCache: Script = preload("scripts/part_cache.gd")
const _ReferenceSelectionScript: Script = preload("scripts/reference_selection.gd")
const _MeshFeaturesScript: Script = preload("scripts/mesh_features.gd")
const _MeshGaugeScript: Script = preload("scripts/mesh_gauge.gd")
## The wide sidebar's edge tree, its buttons, and the fan-out of an edge
## selection to the annotation host and the per-pane geometry overlays.
const _EdgeSidebarScript: Script = preload("scripts/edge_sidebar.gd")
## Which direction each pane looks from: the preset list, the per-pane
## dropdowns and the store that keeps a pane where it was put
## (scripts/pane_projection.gd).
const _PaneProjectionScript: Script = preload("scripts/pane_projection.gd")
## Reference mounting and every measurement the panel is asked to bookkeep:
## the collider digest, the overlay, the per-pane scale and the pick ray.
const _PanelMeasurementScript: Script = preload("scripts/panel_measurement.gd")
## Where the evaluated solid runs into a mounted reference. Asked on every
## evaluation, not only when a verb asks (scripts/geometry_checks.gd).
const _GeometryChecksScript: Script = preload("scripts/geometry_checks.gd")
## Whether a screw will actually go in: coaxiality, a clear path, engagement
## and head seating, per screw (scripts/fastener_checks.gd). Asked for, not
## carried by every evaluation — it costs a B-Rep read in the worker.
const _FastenerChecksScript: Script = preload("scripts/fastener_checks.gd")

## Verbose tracing of the edge pick path. Owned by the sidebar module, which
## prints the other half of it.
const _DEBUG_EDGE_PICK: bool = _EdgeSidebarScript.DEBUG_EDGE_PICK

## Every MeshRoot an evaluation has to reach — the four wide-layout panes and
## the narrow layout's single pane. Owned by the measurement module, because
## the mesh push here, the reference mount and the ortho x-ray toggle must
## never disagree about which panes exist.
const _MESH_ROOT_PATHS: Array = _PanelMeasurementScript.MESH_ROOT_PATHS

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
## Segmentation and primitive fitting over the loaded references (RefCounted),
## and the physics gauge that verifies what it proposes (a child Node).
var _mesh_features: RefCounted = null
var _mesh_gauge: Node = null
## Identity of the reference set the gauge's colliders were last built from.
var _reference_digest: String = ""

## Interference between the evaluated solid and the references
## (scripts/geometry_checks.gd). It owns the solid's own collider world.
var _geometry_checks: RefCounted = null

## Fastener checking (scripts/fastener_checks.gd). It borrows the solid
## collider _geometry_checks owns rather than building a second one.
var _fastener_checks: RefCounted = null

## Reference-node selection (scripts/reference_selection.gd). Owns the click
## picking, the sidebar list and the selection the MCP verbs read back.
var _reference_selection: RefCounted = null

## The GUI "Import mesh…" action: the picker, the buttons and the one line it
## appends to the document (scripts/mesh_import_ui.gd).
var _mesh_import_ui: RefCounted = null


## The report banner along the BOTTOM of the panel (scripts/eval_banner.gd on
## the EvalBanner node of the scene): a failed evaluation, a reference that
## would not load, the interference the check found. It owns the stamp that
## says which evaluation a report belongs to and the per-report dismissal;
## _evaluate_and_render only tells it what to say.
@onready var _eval_banner: PanelContainer = $EvalBannerLayer/EvalBanner

## The wide sidebar's edge inspector and the edge selection it drives
## (scripts/edge_sidebar.gd).
var _edge_sidebar: RefCounted = null

## Reference mounting, the collider digest, the measurement overlay and the
## per-pane mesh visibility (scripts/panel_measurement.gd).
var _measurement: RefCounted = null

## Per-pane projection: the preset list, the dropdowns and the choices
## (scripts/pane_projection.gd). Both layouts read the same list from it.
var _pane_projection: RefCounted = null


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
	_pane_projection = _PaneProjectionScript.new(self)
	_projection_dropdown = $ResponsiveContainer/NarrowLayout/ProjectionRow/ProjectionDropdown as OptionButton
	_PaneProjectionScript.fill(_projection_dropdown)
	_projection_dropdown.select(0)  # Perspective by default
	_projection_dropdown.item_selected.connect(_on_projection_selected)
	# The same dropdown, once per wide pane, driving that pane's camera.
	_pane_projection.attach_wide_panes()

	# ── "Import mesh…" — the GUI half of mesh() authoring ──────────────────
	_mesh_import_ui = _MeshImportUiScript.new()
	_mesh_import_ui.attach(self)

	# Mesh is intentionally empty until a .mcad source is evaluated by the
	# worker and pushed in via the future DSL→mesh bridge. Showing a stub
	# cube here was misleading because it implied the panel had geometry
	# without DSL backing it; the empty state is the honest state.

	_measurement = _PanelMeasurementScript.new(self)
	_reference_library = _ReferenceMeshesScript.new()
	_mesh_features = _MeshFeaturesScript.new()
	# The gauge is a Node: it owns a physics step, because Minerva runs physics
	# on its own thread and a space is only reachable from inside one.
	_mesh_gauge = _MeshGaugeScript.new()
	_mesh_gauge.name = "MeshGauge"
	add_child(_mesh_gauge)
	# The solid's colliders hang off the panel in a world of their own, so a
	# mesh rebuilt on every keystroke never reaches the measurement space.
	_geometry_checks = _GeometryChecksScript.new()
	_geometry_checks.attach(self)
	_fastener_checks = _FastenerChecksScript.new()

	# ── Annotation substrate ───────────────────────────────────────────────
	_annotation_registry = AnnotationRegistry.new()
	# Register built-in 2D kinds (arrow, text, region, polyline, highlight,
	# measure_distance, measure_angle, measure_radius). CAD-specific 3-D kinds
	# are a later grandchild (`019dd017d9df`).
	_BuiltinKindsScript.register_all(_annotation_registry)
	# Register cad_edge_number: numbered callout bubbles for LLM/user edge disambiguation.
	_annotation_registry.register_annotation_kind(_CadEdgeNumberKindScript.new())
	_annotation_registry.register_annotation_kind(preload("kinds/cad_source_annotation_kind.gd").new())

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

	if _annotation_host.has_method("set_panel_root"):
		_annotation_host.set_panel_root(_canvas_overlay)
	# The host is registered under this editor's TAB TITLE, so it is what the
	# panel-tool dispatcher resolves a per-editor editor_name through; the
	# scene-panel broker only knows the one manifest panel name.
	if _annotation_host.has_method("set_panel"):
		_annotation_host.set_panel(self)
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
	_edge_sidebar = _EdgeSidebarScript.new()
	_edge_sidebar.attach(self, _wide_sidebar)
	_edge_sidebar.render(_edge_registry)

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


## Public introspection surface backing minerva_cad_view_state (panel_tools.gd),
## and the note preview's choice of pane. Layout and camera state the panel
## already tracks; the module that owns the panes assembles it.
func get_view_state() -> Dictionary:
	return _measurement.view_state()

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


## The camera behind a named pane ("iso"/"top"/"front"/"right"/"active"). Its
## viewport is that pane's SubViewport, which is where a capture comes from.
func get_view_camera(view: String) -> Camera3D:
	return _measurement.camera_for_view(view)


## Defects the outline pass counted in the solid it just drew, or {} when it
## found none. Open edges are holes in the surface, non-manifold edges are
## faces meeting three deep, degenerate faces have no area and duplicates are
## the same triangle twice — each of them makes a mesh render or measure in a
## way the B-Rep does not predict.
func _mesh_defects() -> Dictionary:
	var mesh_root: Node = get_node_or_null(_MESH_ROOT_PATHS[0])
	if mesh_root == null or not mesh_root.has_method("get_mesh_stats"):
		return {}
	var stats: Dictionary = mesh_root.call("get_mesh_stats")
	var reported := {}
	for field in ["open_edges", "non_manifold_edges", "degenerate_faces", "duplicate_faces"]:
		var count: int = int(stats.get(field, 0))
		if count > 0:
			reported[field] = count
	return reported


## Where the outline the panes draw came from: {source, edges, segments}.
## `source` is "brep" when it was drawn from the worker's edge registry —
## every segment then belongs to a numbered edge — and "tessellation" when it
## was inferred from triangle normals, which is what speckles a boolean seam.
func _outline_report() -> Dictionary:
	var mesh_root: Node = get_node_or_null(_MESH_ROOT_PATHS[0])
	if mesh_root == null or not mesh_root.has_method("get_outline_source"):
		return {}
	return {
		"source": str(mesh_root.call("get_outline_source")),
		"edges": int(mesh_root.call("get_outlined_edge_count")),
		"segments": int(mesh_root.call("get_feature_edge_count")),
	}


## The direction a pane is currently looking from ("Top", "Bottom", …) as its
## own dropdown shows it. A slot id ("iso"/"top"/"front"/"right") is a place on
## screen and does not change when the owner points that pane elsewhere, so the
## verbs that address slots report this alongside.
func get_pane_preset(slot: String) -> String:
	if _narrow_layout != null and _narrow_layout.visible:
		return _current_projection_preset()
	if _pane_projection == null:
		return ""
	return _pane_projection.preset_for(slot)


## Every wide pane's current preset, keyed by slot.
func get_pane_presets() -> Dictionary:
	return _pane_projection.presets() if _pane_projection != null else {}


## Closing the tab has to take the annotation host's pending frame captures off
## RenderingServer. That singleton outlives every panel, and a one-shot that
## never fired — the tab closed first, or no frame was ever drawn — would leave
## a Callable bound to a dead host on its signal, which kills the process in the
## servers' own shutdown long afterwards.
##
## It also releases the clearance check's blob directory: those files are
## derived data in the user's cache, swept only while a check is running, so
## the panel that wrote them is the only thing that knows when they stop
## mattering.
func _exit_tree() -> void:
	if _annotation_host != null and _annotation_host.has_method("drop_pending_captures"):
		_annotation_host.drop_pending_captures()
	if _geometry_checks != null and _geometry_checks.has_method("release"):
		_geometry_checks.release()
	# The evaluated parts and their interference reports live in a static
	# store keyed by panel, which sweeps a dead slot only when another panel
	# touches it — so the last tab to close has to drop its own.
	_PartCache.forget(self)


func get_mesh_features() -> RefCounted:
	return _mesh_features


func get_mesh_gauge() -> Node:
	return _mesh_gauge

## Build the gauge's colliders for the currently mounted references, if the set
## has changed since they were last built. Returns the collider count.
func ensure_gauge_built() -> int:
	return _measurement.ensure_gauge_built()

func get_reference_digest() -> String:
	return _reference_digest


## Where the evaluated solid meets a mounted reference. Every evaluation asks
## this without being told to; `args` may carry reference= and node= to narrow
## it, which is what minerva_cad_check_interference passes through.
func check_interference(args: Dictionary = {}) -> Dictionary:
	if _geometry_checks == null:
		return {"error": "interference checking is not available on this panel"}
	return await _geometry_checks.check(self, args)


## How much air is there between the evaluated solid and each reference node?
## `args` carries required_mm (mandatory) plus reference=/node=/tolerance_mm=,
## which is what minerva_cad_check_clearance passes through. Unlike the
## interference check this one is asked for, not run on every evaluation: it
## re-tessellates the solid at a measurement tolerance in the worker, which
## can outlast the caller's window — hence ticket=, which collects a
## measurement an earlier call left running.
func check_clearance(args: Dictionary = {}) -> Dictionary:
	if _geometry_checks == null:
		return {"error": "clearance checking is not available on this panel"}
	return await _geometry_checks.check_clearance(self, args)


## How close do the REFERENCES come to each other? `args` carries reference=
## and against= (or reference="all-pairs") plus required_mm=, which is what
## minerva_cad_check_clearance and minerva_cad_check_interference pass through
## when the question is part-against-part rather than solid-against-part.
## Neither side is the evaluated solid, so nothing is tessellated and the
## measurement is over the reference meshes the panel already holds.
func check_reference_pairs(args: Dictionary = {}) -> Dictionary:
	if _geometry_checks == null:
		return {"error": "reference measurement is not available on this panel"}
	return await _geometry_checks.check_reference_pairs(self, args)


## Will these screws go in? `args` carries screw={dia_mm,length_mm,head_dia_mm}
## and the reference holes to pair against, which is what
## minerva_cad_check_fasteners passes through after running find_holes. Like
## the clearance check this one is asked for, not run on every evaluation: it
## reads the solid's B-Rep in the worker.
func check_fasteners(args: Dictionary = {}) -> Dictionary:
	if _fastener_checks == null:
		return {"error": "fastener checking is not available on this panel"}
	return await _fastener_checks.check(self, args)


func get_geometry_checks() -> RefCounted:
	return _geometry_checks


func get_fastener_checks() -> RefCounted:
	return _fastener_checks


## The user's last click on a reference node, or {} — read by
## minerva_cad_get_selected_reference.
func get_reference_selection() -> Dictionary:
	if _reference_selection == null:
		return {}
	return _reference_selection.get_selection()


## Fired whenever the answer get_annotation_tool_status() would give may have
## changed — the reference selection was made, cleared or went stale, by a
## click, the sidebar or the MCP verb. The host reads the status only when
## the armed tool changes; this is the panel's side of asking it to read
## again, so a selection made while a tool stays armed clears the warning.
signal annotation_tool_status_changed

## Duck-typed hook used by Minerva's annotation-tool bridge. An armed overlay
## owns pointer input, so a user who has not selected the foreign surface yet
## needs an actionable warning in the annotation dock (visible in every CAD
## layout), not only instructions in the wide reference sidebar.
func get_annotation_tool_status(tool: Object) -> String:
	if tool == null or get_reference_state().is_empty():
		return ""
	var selection := get_reference_selection()
	if not selection.is_empty() and not bool(selection.get("stale", false)):
		return ""
	return "Reference clicks are unavailable while an annotation tool is armed. " \
		+ "Turn the tool off, click the reference point, then arm it again."


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
	return _measurement.set_measurement_overlay(mode, grid_mm)


## Millimetres-to-pixels for one pane, so a snapshot can be read as a drawing.
func get_view_metrics(view: String) -> Dictionary:
	return _measurement.get_view_metrics(view)


## The world-space ray under a pixel of one pane, for turning a click or a
## snapshot coordinate into a question about the geometry.
func get_pick_ray(view: String, pixel: Vector2) -> Dictionary:
	return _measurement.get_pick_ray(view, pixel)


## Why a named pane cannot be addressed, or "" when it can.
func view_unavailable_reason(view: String) -> String:
	return _measurement.view_unavailable_reason(view)


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
	# The pane ids survive the layout change but the SubViewports behind them
	# do not, so anything captured from the outgoing layout is a picture of a
	# pane that no longer exists.
	if _annotation_host.has_method("invalidate_captures"):
		_annotation_host.invalidate_captures()
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
		# Register per-pane cameras for multi-pane annotation projection .
		if _annotation_host.has_method("set_camera_for"):
			_annotation_host.set_camera_for("iso", iso_cam)
			_annotation_host.set_camera_for("top", top_cam)
			_annotation_host.set_camera_for("front", front_cam)
			_annotation_host.set_camera_for("right", right_cam)
		# Register per-pane containers for viewport_rect computation .
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
## The canvas is permanently parented to _canvas_overlay
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
	var preset: String = _PaneProjectionScript.preset_at(index)
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
	return _PaneProjectionScript.preset_at(_projection_dropdown.selected)


## Map an orbit-camera preset string to the lower-case viewport-id used by
## Cad_AnnotationHost.get_view_context().
func _projection_preset_to_viewport_id(preset: String) -> String:
	return preset.to_lower()

## Hide the shaded mesh in ortho-only panes (Top/Front/Right; narrow non-
## perspective) so the edge overlay is the only visualisation. Iso /
## Perspective keeps the mesh visible for shaded 3-D context.
func _apply_mesh_visibility() -> void:
	_measurement.apply_mesh_visibility()

## Mount the evaluation's reference meshes under every MeshRoot and hand each
## MeshDisplay the world bounds so auto-framing covers them.
func _mount_references(references: Array) -> void:
	_measurement.mount_references(references)


## Push the current mesh data + per-pane cameras to every Cad_GeometryOverlay.
## Called whenever a new mesh arrives from the DSL→mesh bridge.
func _push_mesh_to_geometry_overlays() -> void:
	_edge_sidebar.push_to_overlays()


func _on_edge_selected(edge_id: int) -> void:
	if _DEBUG_EDGE_PICK:
		print("[edge-pick] CADPanel._on_edge_selected edge_id=%d" % edge_id)
	_edge_sidebar.select_edge(edge_id)


## Called when the host emits selection_changed (annotation selection). Also
## called directly after edge selection changes so the tree row stays current.
func _on_host_selection_changed(_annotation_id: String = "") -> void:
	_edge_sidebar.update_tree_selection()


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
