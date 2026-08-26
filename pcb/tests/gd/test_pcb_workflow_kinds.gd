extends SceneTree
## PCB workflow-kind substrate E2E-2 (WC-2, docket 019f6a892ea4).
##
## Run: godot --headless --path . --script test/test_pcb_workflow_kinds.gd
## (run from the Minerva worktree's src/ directory)
##
## Scenario (owner-blessed): "Workflow hints don't clutter review — and agents
## stay sighted." A board carries one review arrow + one F.Cu route hint + one
## B.Cu route hint.
##   A) Review annotations panel/model lists ONLY the arrow.
##   B) Workflow (route-hint) listing shows ONLY the two hints, kind-grouped.
##   C) MCP annotations_list/query return all THREE (separation is UI-only).
##   D) Human hides the B.Cu layer → the B.Cu hint vanishes from canvas
##      rendering AND hit-testing; the F.Cu hint + arrow are unaffected.
##      *** C3 red→green (bug 019f33d2c9bf): the two assertions marked
##      "[C3 red->green]" below FAIL on the pre-WC-2 substrate (no
##      is_annotation_visible hook — the hidden hint stayed clickable and
##      rendered) and PASS after it. ***
##   E) MCP still returns all three while B.Cu is hidden.
##   F) Sidecar save → clear → reload; A–E still hold.
## Plus the annotations_add host-registry regression (bug 019f6a8d1391):
## MCP add with kind pcb_route_hint + a valid editor_name now succeeds.
##
## REUSE SCAN: mount/fixture/input conventions copied from
## test_pcb_pin_inspector.gd (real PCBPanel boot headless, real input via
## get_root().push_input(), MCP via MODULE.new(null).handle()). Rendering is
## asserted through the substrate visibility predicate + real hit-test clicks,
## NOT pixel probes (pcb_get_image is null headless — see contract §1c).

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const ANN_MODULE := preload("res://Scripts/Services/MCP/Modules/MCPAnnotationTools.gd")
const _WorkflowListScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/WorkflowAnnotationList.gd")
const _WorkbenchScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationWorkbench.gd")
const _SidebarModelScript := preload("res://Scripts/Services/Annotations/AnnotationSidebarModel.gd")

const EDITOR_NAME := "WorkflowKindsProbe"
const SIDECAR_DOC := "user://wc2_e2e2_board.minpcb"

var _pass := 0
var _fail := 0

var panel = null
var canvas = null
var host = null
var data = null
var ann_tools = null

var overlay: AnnotationOverlay = null
# R4/chore 019fb6632a4e: AnnotationSelectTool no longer exists in core —
# owner-ratified chore 019fb59b34ee deleted it (and its 3 siblings) outright
# after commit 38ea58cf ("promote AnnotationTransformTool as THE select tool;
# press-drag selects and moves") folded click-to-select semantics into
# AnnotationTransformTool ("OUTSIDE / no selection → select semantics
# (hit-test annotations)" — see its own class doc). This left the reference a
# hard parse error (Identifier "AnnotationSelectTool" not declared), failing
# the WHOLE script to load. AnnotationTransformTool is the direct, currently
# supported replacement; same on_activate(host)/on_deactivate() interface.
# Same fix already applied in test_pcb_single_trace_tool.gd (round B5u1).
var select_tool: AnnotationTransformTool = null
var workbench = null
var workflow_list = null

var arrow_id := ""
var fcu_id := ""
var bcu_id := ""

# Board-mm placements — pairwise >30mm apart so the generous doc-space hit
# thresholds (8mm slack + 5mm marker) can never cross-match.
const ARROW_AT := Vector2(50.0, 30.0)
const FCU_AT := Vector2(20.0, 15.0)
const BCU_AT := Vector2(80.0, 45.0)


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB Workflow Kinds E2E-2 ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	_seed_annotations()
	await process_frame

	await _test_a_review_surface_excludes_workflow()
	_test_b_workflow_listing()
	await _test_c_mcp_sees_all_three()
	await _test_d_layer_visibility()   # C3 red→green lives here
	await _test_e_mcp_unchanged_while_hidden()
	await _test_f_sidecar_round_trip()
	await _test_mcp_add_regression()
	# Runs LAST and adds its own extra hint (see the test's own doc for why):
	# every test above this line depends on the fixture's exact annotation
	# counts (A-F assert the original 3; the ADD regression asserts before/
	# before+1 and workflow-listing==3), so a G that mutated state earlier
	# would silently break those hard-coded counts.
	await _test_g_universal_select_path_bend_editing()
	# Runs after G for the same reason G runs after everything else: it adds
	# its own fixture hint too, so anything depending on G's exact
	# post-conditions has to come first. G's own (d) is also what arms the
	# real universal-select tool this test needs — see H's own doc.
	await _test_h_canvas_real_input_path()
	# Runs after H for the same fixture-mutation reason: it flips a hint's
	# lifecycle (and restores it), so it must not run before the count-pinned
	# tests above.
	await _test_i_consumed_filter()
	# Runs LAST of all: it adopts a document path on the panel, which arms the
	# UX2 station-8 auto-writer for every later mutation — earlier tests
	# assume no sidecar exists unless they wrote one themselves.
	await _test_j_sidecar_autosave()
	await _test_k_get_selection()

	_cleanup_sidecar()
	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture (test_pcb_pin_inspector.gd conventions) ──────────────────

func _mount() -> bool:
	panel = load(PANEL_PATH).new()
	if panel == null:
		return false
	get_root().add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size = Vector2(900, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})

	host = panel.get_annotation_host()
	data = panel.get_data()
	if host == null or data == null:
		return false

	_build_fixture_board(data)

	for _i in range(4):
		await process_frame

	canvas = panel._canvas
	if canvas == null:
		return false

	# Deterministic view: board center at canvas center, fixed 4 px/mm — every
	# board-mm point used below maps to a stable, on-canvas pixel (we do NOT
	# depend on zoom_to_fit's content-bbox heuristics; see the pin-inspector
	# test's cautionary note).
	canvas.zoom = 4.0
	canvas.pan_offset = -Vector2(data.board_width, data.board_height) / 2.0 * canvas.zoom
	canvas.queue_redraw()
	await process_frame

	# Real substrate overlay + Select tool, mounted exactly where the platform
	# mounts it (get_annotation_overlay_parent shares the canvas origin).
	overlay = AnnotationOverlay.new()
	panel.get_annotation_overlay_parent().add_child(overlay)
	overlay.set_host(host)
	select_tool = AnnotationTransformTool.new()
	select_tool.on_activate(host)
	overlay.set_active_tool(select_tool)
	await process_frame

	# Review workbench + workflow listing, both bound to the same live host.
	workbench = _WorkbenchScript.new()
	get_root().add_child(workbench)
	workbench.set_host(host)
	workflow_list = _WorkflowListScript.new()
	get_root().add_child(workflow_list)
	workflow_list.set_host(host)
	await process_frame

	ann_tools = ANN_MODULE.new(null)  # server=null — handle() is server-free.
	return true


func _build_fixture_board(d) -> void:
	d.board_width = 100.0
	d.board_height = 60.0

	var u1 = d.new_component()
	u1.id = "U1"
	u1.position = Vector2(30.0, 30.0)
	u1.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u1)

	var u2 = d.new_component()
	u2.id = "U2"
	u2.position = Vector2(70.0, 30.0)
	u2.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u2)


func _seed_annotations() -> void:
	# One REVIEW arrow (core generic 2d_arrow, core/canvas.point anchor — the
	# combination the host capabilities advertise) + two workflow route hints.
	arrow_id = host.add_annotation_v2({
		"id": "",
		"kind": "2d_arrow",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "canvas.point",
			"id": {"x": ARROW_AT.x, "y": ARROW_AT.y},
			"snapshot": {"position": [ARROW_AT.x, ARROW_AT.y]},
		},
		"kind_payload": {},
		"primitives": [{"kind": "arrow", "from": [ARROW_AT.x - 2.0, ARROW_AT.y - 2.0], "to": [ARROW_AT.x, ARROW_AT.y]}],
		"lifecycle": "open",
		"author": {"kind": "human"},
		"view_context": "pcb",
		"visible_in_views": ["all"],
		"summary": "review arrow: check this footprint",
	})
	fcu_id = host.add_route_hint_at(FCU_AT.x, FCU_AT.y, "top corridor", "F.Cu", "waypoint",
		[[FCU_AT.x, FCU_AT.y], [FCU_AT.x + 8.0, FCU_AT.y]])
	bcu_id = host.add_route_hint_at(BCU_AT.x, BCU_AT.y, "bottom corridor", "B.Cu", "waypoint",
		[[BCU_AT.x, BCU_AT.y], [BCU_AT.x + 8.0, BCU_AT.y]])

	check("fixture: arrow stored", not arrow_id.is_empty())
	check("fixture: F.Cu hint stored", not fcu_id.is_empty())
	check("fixture: B.Cu hint stored", not bcu_id.is_empty())
	check("fixture: host holds exactly 3 annotations", host.get_annotations().size() == 3,
		"count=%d" % host.get_annotations().size())


# ── input helpers (copied convention from test_pcb_pin_inspector.gd) ─────────

func _push_button(pos: Vector2, btn: int, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _world_to_root_screen(world_pos: Vector2) -> Vector2:
	return canvas.get_global_transform() * canvas.world_to_screen(world_pos)


## Real substrate click: press+release LEFT at a board-mm point, routed through
## the viewport so the AnnotationOverlay (mouse_filter STOP while the Select
## tool is active) receives it exactly as production input.
func _click_world(world_pos: Vector2) -> void:
	var pt := _world_to_root_screen(world_pos)
	_push_button(pt, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_button(pt, MOUSE_BUTTON_LEFT, false)
	await process_frame


## Duck-typed host visibility probe. On the PRE-WC-2 substrate the hook does
## not exist → defaults to true, which is exactly what makes assertion D2 red.
func _host_visible(annotation_id: String) -> bool:
	var ann: Dictionary = host.get_by_id(annotation_id)
	if ann.is_empty():
		return false
	if not host.has_method("is_annotation_visible"):
		return true
	return bool(host.is_annotation_visible(ann))


func _workbench_row_count() -> int:
	var rows := 0
	for child in workbench._entries_list.get_children():
		if not child.is_queued_for_deletion():
			rows += 1
	return rows


# ── A. review surface excludes workflow annotations ─────────────────────────

func _test_a_review_surface_excludes_workflow() -> void:
	print("-- A: review workbench/model list ONLY the arrow --")
	workbench.refresh()
	await process_frame

	check("A: workbench shows exactly 1 review row", _workbench_row_count() == 1,
		"rows=%d" % _workbench_row_count())

	var model = _SidebarModelScript.new()
	model.set_kind_registry(host.get_registry())
	model.set_annotations(host.get_annotations())
	var visible: Array = model.get_visible_annotations()
	check("A: sidebar model lists exactly 1 annotation", visible.size() == 1,
		"size=%d" % visible.size())
	check("A: the listed annotation is the arrow",
		visible.size() == 1 and str((visible[0] as Dictionary).get("id", "")) == arrow_id,
		"got %s" % str(visible))

	# Guard: exclusion comes from the workflow_class kind flag, not data loss —
	# without a kind registry the model still sees all three.
	var unfiltered = _SidebarModelScript.new()
	unfiltered.set_annotations(host.get_annotations())
	check("A: without a kind registry the model sees all 3 (flag-driven exclusion)",
		unfiltered.get_visible_annotations().size() == 3,
		"size=%d" % unfiltered.get_visible_annotations().size())


# ── B. workflow listing shows ONLY the hints ─────────────────────────────────

func _test_b_workflow_listing() -> void:
	print("-- B: workflow listing shows ONLY the two route hints --")
	workflow_list.refresh()
	var listing: Array = workflow_list.get_listing()
	check("B: exactly 2 workflow entries", listing.size() == 2, "size=%d" % listing.size())
	var ids := []
	var kinds_ok := true
	for entry in listing:
		ids.append(str((entry as Dictionary).get("id", "")))
		if str((entry as Dictionary).get("kind", "")) != "pcb_route_hint":
			kinds_ok = false
	check("B: both entries are pcb_route_hint (kind-grouped)", kinds_ok, "got %s" % str(listing))
	check("B: entries are the two hints", fcu_id in ids and bcu_id in ids, "ids=%s" % str(ids))
	check("B: the arrow is NOT in the workflow listing", not (arrow_id in ids), "ids=%s" % str(ids))


# ── C. MCP read surfaces see all three (separation is UI-only) ───────────────

func _test_c_mcp_sees_all_three() -> void:
	print("-- C: MCP annotations_list/query return all THREE --")
	await _assert_mcp_sees_three("C")


func _assert_mcp_sees_three(tag: String) -> void:
	var listed: Dictionary = await ann_tools.handle("minerva_annotations_list", {"editor_name": EDITOR_NAME})
	check("%s: annotations_list ok" % tag, bool(listed.get("ok", listed.get("success", false))), str(listed))
	check("%s: annotations_list count == 3" % tag, int(listed.get("count", -1)) == 3,
		"count=%s" % str(listed.get("count")))

	var queried: Dictionary = await ann_tools.handle("minerva_annotations_query", {"editor_name": EDITOR_NAME})
	check("%s: annotations_query ok" % tag, bool(queried.get("ok", false)), str(queried))
	check("%s: annotations_query count == 3" % tag, int(queried.get("count", -1)) == 3,
		"count=%s" % str(queried.get("count")))


# ── D. layer-keyed visibility (C3 repro, red→green) ─────────────────────────

func _test_d_layer_visibility() -> void:
	print("-- D: hiding B.Cu hides the bottom hint from canvas + hit-testing (C3) --")

	# Sanity while everything is visible: a real click selects the B.Cu hint.
	var bcu_screen := _world_to_root_screen(BCU_AT)
	check("D: B.Cu click point is on-canvas (sanity)",
		canvas.get_global_rect().has_point(bcu_screen), "pt=%s rect=%s" % [str(bcu_screen), str(canvas.get_global_rect())])
	await _click_world(BCU_AT)
	check("D: with all layers shown, clicking the B.Cu hint selects it",
		host.get_selected_annotation_id() == bcu_id,
		"selected='%s'" % host.get_selected_annotation_id())
	host.set_selected_annotation_id("")

	# Simulate the HUMAN hiding B.Cu: shut its eye, the View menu's per-layer
	# checkbox (_on_view_menu_id_pressed calls exactly this). The toolbar Layer
	# chooser is NOT this gesture — it moves the working layer and leaves the
	# view alone.
	canvas.set_layer_hidden("bottom", true)
	await process_frame
	check("D: B.Cu is now hidden", not bool(canvas.is_layer_visible("bottom")))
	check("D: and hiding it did not move where copper is authored",
		str(canvas.working_layer) == "top", "working='%s'" % str(canvas.working_layer))

	# [C3 red->green] Canvas-rendering gate: the overlay render loop consults
	# this exact host predicate (AnnotationOverlay._draw skips invisible
	# annotations). Pre-WC-2 the hook doesn't exist → defaults visible → FAIL.
	check("D: [C3 red->green] hidden-layer hint reports NOT visible to the canvas",
		not _host_visible(bcu_id))
	check("D: F.Cu hint stays visible", _host_visible(fcu_id))
	check("D: review arrow stays visible", _host_visible(arrow_id))

	# [C3 red->green] Hit-testing gate: a real click AT the hidden hint must not
	# select it. Pre-WC-2 the Select tool hit-tested hidden annotations → FAIL.
	await _click_world(BCU_AT)
	check("D: [C3 red->green] clicking the hidden B.Cu hint does NOT select it",
		host.get_selected_annotation_id() != bcu_id and host.get_selected_annotation_id() == "",
		"selected='%s'" % host.get_selected_annotation_id())

	# Unaffected neighbours: both still fully clickable.
	await _click_world(FCU_AT)
	check("D: F.Cu hint still selectable by click",
		host.get_selected_annotation_id() == fcu_id,
		"selected='%s'" % host.get_selected_annotation_id())
	await _click_world(ARROW_AT)
	check("D: review arrow still selectable by click",
		host.get_selected_annotation_id() == arrow_id,
		"selected='%s'" % host.get_selected_annotation_id())
	host.set_selected_annotation_id("")

	# The hidden hint REMAINS in both listings — layer visibility is a canvas
	# concern, not a data or listing concern.
	workflow_list.refresh()
	check("D: workflow listing still shows both hints while B.Cu is hidden",
		workflow_list.get_listing().size() == 2,
		"size=%d" % workflow_list.get_listing().size())


# ── E. MCP unchanged while a layer is hidden ─────────────────────────────────

func _test_e_mcp_unchanged_while_hidden() -> void:
	print("-- E: MCP still returns all three while B.Cu is hidden --")
	await _assert_mcp_sees_three("E")


# ── F. sidecar round-trip preserves A–E ──────────────────────────────────────

func _test_f_sidecar_round_trip() -> void:
	print("-- F: sidecar save → clear → reload, A–E still hold --")

	var err: int = host.save_sidecar(SIDECAR_DOC)
	check("F: save_sidecar OK", err == OK, "err=%d" % err)

	host.set_annotations([])
	await process_frame
	check("F: cleared — host empty", host.get_annotations().size() == 0)
	workflow_list.refresh()
	check("F: cleared — workflow listing empty", workflow_list.get_listing().size() == 0)

	var loaded: int = host.load_sidecar(SIDECAR_DOC)
	check("F: load_sidecar restored 3 annotations", loaded == 3, "loaded=%d" % loaded)
	await process_frame

	# A again.
	workbench.refresh()
	await process_frame
	check("F/A: workbench still shows exactly 1 review row", _workbench_row_count() == 1,
		"rows=%d" % _workbench_row_count())

	# B again.
	workflow_list.refresh()
	var listing: Array = workflow_list.get_listing()
	var ids := []
	for entry in listing:
		ids.append(str((entry as Dictionary).get("id", "")))
	check("F/B: workflow listing shows both hints again", listing.size() == 2 and fcu_id in ids and bcu_id in ids,
		"ids=%s" % str(ids))

	# C/E again.
	await _assert_mcp_sees_three("F/C")

	# D again — the layer filter is still "top", so the reloaded B.Cu hint must
	# come back hidden (visibility derives from live view state, not stored state).
	check("F/D: reloaded B.Cu hint is still hidden", not _host_visible(bcu_id))
	check("F/D: reloaded F.Cu hint is still visible", _host_visible(fcu_id))
	host.set_selected_annotation_id("")
	await _click_world(BCU_AT)
	check("F/D: clicking the reloaded hidden hint still does not select it",
		host.get_selected_annotation_id() == "",
		"selected='%s'" % host.get_selected_annotation_id())
	await _click_world(FCU_AT)
	check("F/D: reloaded F.Cu hint still selectable",
		host.get_selected_annotation_id() == fcu_id,
		"selected='%s'" % host.get_selected_annotation_id())
	host.set_selected_annotation_id("")


# ── annotations_add host-registry regression (bug 019f6a8d1391) ──────────────

func _test_mcp_add_regression() -> void:
	print("-- MCP regression: annotations_add accepts plugin kind via host registry --")

	var before: int = host.get_annotations().size()
	var env: Dictionary = host.build_route_hint_envelope(40.0, 50.0, "agent corridor", "F.Cu")
	# MCP path stamps id/created_at itself (v1 envelope validator wants RFC3339
	# strings, not the builder's unix ints) — submit the agent-authored shape.
	env.erase("id")
	env.erase("created_at")
	env.erase("updated_at")

	var added: Dictionary = await ann_tools.handle("minerva_annotations_add",
		{"editor_name": EDITOR_NAME, "annotation": env})
	check("ADD: pcb_route_hint via editor_name succeeds (was rejected pre-fix)",
		bool(added.get("success", added.get("ok", false))) and not added.has("errors"), str(added))
	check("ADD: a non-empty annotation id came back",
		not str(added.get("id", "")).is_empty(), str(added))
	check("ADD: host annotation count incremented", host.get_annotations().size() == before + 1,
		"count=%d (was %d)" % [host.get_annotations().size(), before])

	# The global-registry fallback still rejects garbage kinds.
	var bogus: Dictionary = await ann_tools.handle("minerva_annotations_add",
		{"editor_name": EDITOR_NAME, "annotation": {"kind": "no_such_kind", "view_context": "pcb"}})
	check("ADD: unknown kind is still rejected", not bool(bogus.get("ok", true)) and bogus.has("errors"),
		str(bogus))

	# And the new hint joins the workflow listing (UI partition stays coherent).
	workflow_list.refresh()
	check("ADD: workflow listing now shows 3 hints", workflow_list.get_listing().size() == 3,
		"size=%d" % workflow_list.get_listing().size())


# ── G. universal select offers bend handles on a "path"-profile kind ─────────
# (UX1 station 6, docket 019fd09b209e). The modal "Edit hint" toolbar tool
# (BendHandleEditTool, pcb_route_hint_kind.gd) already exercises this exact
# bend API under its own hint-only selection semantics (see
# test_pcb_hint_refine_loop.gd) — this proves the SAME api/host commit path
# now also works through the shared universal-select AnnotationTransformTool
# (`select_tool`, already mounted in _mount()), which is the whole point of
# the round: no separate modal tool is needed to move/insert/delete a bend.
#
# Drives select_tool directly (position = canvas.world_to_screen(world_pos),
# matching PcbAnnotationHost.transform_screen_to_doc's "overlay-local pixels"
# contract) rather than through push_input/_click_world: on_pointer_move has
# no InputEventMouseMotion equivalent in that helper, and driving the tool
# directly is the exact idiom the core suite (test_annotation_transform_tool.gd)
# already uses for drag gestures. The tool's own annotation_modified signal is
# still connected to the REAL overlay (set_active_tool wired it in _mount()),
# so every commit below goes through the production host.update_annotation
# path — including the per-hint revision-history push (C4, docket
# 019f6c464ff0) BendHandleEditTool's drag also produces, asserted below via
# kind_payload.revision_stack growth.

const HINT_G_ANCHOR := Vector2(90.0, 50.0)
const HINT_G_BEND1  := Vector2(90.0, 58.0)
const HINT_G_BEND2  := Vector2(82.0, 58.0)
const HINT_G_DEST   := Vector2(82.0, 50.0)


func _hint_g_revision_count(ann: Dictionary) -> int:
	# TOP-LEVEL, not kind_payload (Codex re-review on 019fd10557c8):
	# PcbAnnotationHost.update_annotation pushes the prior kind_payload onto
	# the ANNOTATION's revision_stack — reading it off kind_payload always
	# returned zero, which made every "revision count grew" assertion in G a
	# guaranteed failure at the boundary run.
	var stack: Variant = ann.get("revision_stack", [])
	return (stack as Array).size() if stack is Array else 0


func _test_g_universal_select_path_bend_editing() -> void:
	print("-- G: universal select offers bend handles on pcb_route_hint (path profile) --")

	# Legacy full-path waypoints convention (build_route_hint_envelope's
	# default): [anchor, bend, bend, dest] → bend_points() returns the 2
	# interior points (see pcb_route_hint_kind.gd bend_points() doc).
	var hint_g_id: String = host.add_route_hint_at(
		HINT_G_ANCHOR.x, HINT_G_ANCHOR.y, "bend-edit probe", "F.Cu", "waypoint",
		[[HINT_G_ANCHOR.x, HINT_G_ANCHOR.y], [HINT_G_BEND1.x, HINT_G_BEND1.y],
			[HINT_G_BEND2.x, HINT_G_BEND2.y], [HINT_G_DEST.x, HINT_G_DEST.y]])
	check("G: fixture hint stored", not hint_g_id.is_empty())

	var kind: AnnotationKind = host.get_registry().get_annotation_kind(&"pcb_route_hint")
	check("G: pcb_route_hint kind resolved", kind != null)
	if kind == null:
		return

	check("G: pcb_route_hint.manipulation_profile() == 'path'",
		kind.manipulation_profile() == "path", "got '%s'" % kind.manipulation_profile())
	check("G: select_tool accepts the real kind as path-eligible", select_tool._is_path_kind(kind))

	host.set_selected_annotation_id(hint_g_id)
	check("G: fixture hint selected", host.get_selected_annotation_id() == hint_g_id)

	var before_ann: Dictionary = host.get_by_id(hint_g_id)
	var before_bends: Array = kind.bend_points(before_ann)
	check("G: fixture starts with 2 interior bends", before_bends.size() == 2,
		"size=%d" % before_bends.size())
	var before_revisions := _hint_g_revision_count(before_ann)

	# ── (c) bend drag: ONE commit, moved point, ONE revision pushed ───────────
	var press_screen: Vector2 = canvas.world_to_screen(HINT_G_BEND1)
	check("G: press on bend[0]'s screen position arms a BEND drag",
		select_tool.on_pointer_down(press_screen, MOUSE_BUTTON_LEFT, 0))
	check("G: select_tool armed Zone.BEND",
		select_tool._active_zone == AnnotationTransformTool.Zone.BEND,
		"zone=%s" % str(select_tool._active_zone))

	var dragged_to := Vector2(88.0, 56.0)
	var dragged_to_screen: Vector2 = canvas.world_to_screen(dragged_to)
	select_tool.on_pointer_move(dragged_to_screen)
	var mid_drag_ann: Dictionary = host.get_by_id(hint_g_id)
	check("G: host annotation UNCHANGED mid-drag (preview only, real host too)",
		(kind.bend_points(mid_drag_ann)[0] as Vector2) == (before_bends[0] as Vector2))

	select_tool.on_pointer_up(dragged_to_screen, MOUSE_BUTTON_LEFT, 0)
	var after_drag_ann: Dictionary = host.get_by_id(hint_g_id)
	var after_drag_bends: Array = kind.bend_points(after_drag_ann)
	check("G: still 2 bends after the drag", after_drag_bends.size() == 2,
		"size=%d" % after_drag_bends.size())
	if after_drag_bends.size() == 2:
		var moved: Vector2 = after_drag_bends[0]
		check("G: dragged bend landed at the release position",
			moved.distance_to(dragged_to) < 0.01, "moved=%s" % str(moved))
		check("G: the OTHER bend is untouched",
			(after_drag_bends[1] as Vector2).distance_to(HINT_G_BEND2) < 0.01)
	check("G: exactly ONE revision pushed by the drag",
		_hint_g_revision_count(after_drag_ann) == before_revisions + 1,
		"count=%d" % _hint_g_revision_count(after_drag_ann))

	# ── (d) right-click a bend handle → THE CANVAS MENU, not a direct tool
	# gesture (station 6 fix F1, docket 019fd104e1c6 — Codex review, docket
	# 019fd10557c8 comment 1034).
	#
	# REWORKED. The ORIGINAL assertion here drove
	# `select_tool.on_pointer_down(bend2_screen, MOUSE_BUTTON_RIGHT, 0)`
	# directly — core AnnotationTransformTool DOES have a right-click-deletes-
	# a-bend branch (_try_delete_bend_at), so that call "passed", but it
	# exercised a gesture pcb_canvas can never actually reach in production:
	# the canvas's RIGHT mouse button never calls into the annotation router
	# at ALL (see pcb_canvas.gd _handle_mouse_button's MOUSE_BUTTON_RIGHT
	# branch — every right press there arms a pan/menu directly, never
	# annotation_pointer_down). The assertion was passing "artificially".
	#
	# The REAL path is the canvas's OWN context menu (F1's "Delete bend"
	# item), and it IS reachable in this harness: `canvas` is the real
	# production pcb_canvas instance and its `_annotation_router` is already
	# wired to `host` (panel._build_ui() did that in _mount()). What stood in
	# the way is the harness's OWN `overlay`, mounted ACTIVE (non-passive,
	# mouse_filter STOP) for letters A-G's plain-click tests — an active
	# overlay sits ON TOP of the canvas at the same screen rect and absorbs
	# EVERY mouse button, including right-clicks, before pcb_canvas's own
	# _gui_input ever runs (AnnotationOverlay._gui_input handles
	# MOUSE_BUTTON_RIGHT unconditionally). So: release the harness's tool and
	# re-arm PASSIVELY through the REAL host entry point
	# (PcbAnnotationHost.arm_universal_select) — the exact topology
	# PCBPanel._sync_universal_select sets up in production. This flip holds
	# for the rest of this script's run (nothing after this point depends on
	# the old active wiring); the new canvas-input test (H) below relies on
	# it too.
	overlay.clear_active_tool()
	host.arm_universal_select(overlay, true)
	check("G: universal select is armed PASSIVELY on the real overlay",
		host.is_universal_select_armed() and overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"armed=%s filter=%d" % [str(host.is_universal_select_armed()), overlay.mouse_filter])
	# REBIND (Codex re-review P1): clear_active_tool DISCONNECTED the harness's
	# own select_tool from annotation_modified — every direct-tool call below
	# must go through the HOST-VENDED tool the arming just wired, or the host
	# can never observe the edit and the assertions fail deterministically.
	select_tool = host.get_universal_select_tool()
	check("G: rebound to the armed host-vended tool", select_tool != null)

	# A REAL right-press+release, through get_root().push_input — the same
	# idiom test_pcb_canvas_input_probe.gd's own "RIGHT-CLICK IS A MENU"
	# probe uses (that file already proves PopupMenu.popup() works headless).
	var bend2_root: Vector2 = _world_to_root_screen(HINT_G_BEND2)
	_push_button(bend2_root, MOUSE_BUTTON_RIGHT, true)
	await process_frame
	_push_button(bend2_root, MOUSE_BUTTON_RIGHT, false)
	await process_frame
	check("G: right-click on the remaining bend handle pops the REAL context menu",
		canvas.context_menu != null and canvas.context_menu.visible,
		"items=%d bend_hit=%s" % [
			(canvas.context_menu.item_count if canvas.context_menu != null else -1),
			str(canvas._context_menu_annotation_bend)])
	var has_delete_bend := false
	if canvas.context_menu != null:
		for i in canvas.context_menu.item_count:
			if canvas.context_menu.get_item_text(i) == "Delete bend":
				has_delete_bend = true
	check("G: …and it carries 'Delete bend'", has_delete_bend)

	# Fire the handler the SAME way the real popup does — through its
	# id_pressed signal (_create_context_menu wires _on_context_menu_pressed
	# to it) — rather than simulating a raw pixel click INSIDE the live
	# popup's own item list, which no suite in this codebase attempts
	# (test_pcb_canvas_input_probe.gd's own menu probe stops at "the item is
	# present" plus a manual .hide(), and never clicks an item via real
	# input either). This is the "assert the menu item presence + its
	# handler effect directly" fallback the round's own instructions name,
	# used for JUST the handler-firing step — the item's PRESENCE above came
	# from the fully real press.
	if canvas.context_menu != null:
		canvas.context_menu.hide()
		canvas.context_menu.id_pressed.emit(canvas.MENU_ID_DELETE_ANNOTATION_BEND)

	var after_delete_ann: Dictionary = host.get_by_id(hint_g_id)
	var after_delete_bends: Array = kind.bend_points(after_delete_ann)
	check("G: 1 bend remains after delete", after_delete_bends.size() == 1,
		"size=%d" % after_delete_bends.size())
	check("G: exactly TWO revisions pushed so far",
		_hint_g_revision_count(after_delete_ann) == before_revisions + 2,
		"count=%d" % _hint_g_revision_count(after_delete_ann))

	# ── (e) click the path (not a handle) inserts a bend, ONE more revision ──
	# Midpoint of the remaining segment moved_bend1(88,56) -> dest(82,50):
	# (85,53). >4mm from both endpoints, well clear of the 12px/4.0zoom=3mm
	# handle radius, so this can only land as an insert, never a handle hit.
	var insert_at_world := Vector2(85.0, 53.0)
	var insert_screen: Vector2 = canvas.world_to_screen(insert_at_world)
	var insert_consumed := select_tool.on_pointer_down(insert_screen, MOUSE_BUTTON_LEFT, 0)
	check("G: segment click is consumed (insert)", insert_consumed)
	check("G: insert did not leave select_tool mid-drag", not select_tool._dragging)
	var after_insert_ann: Dictionary = host.get_by_id(hint_g_id)
	var after_insert_bends: Array = kind.bend_points(after_insert_ann)
	check("G: 2 bends after insert", after_insert_bends.size() == 2,
		"size=%d" % after_insert_bends.size())
	if after_insert_bends.size() == 2:
		check("G: inserted point sits at the segment midpoint",
			(after_insert_bends[1] as Vector2).distance_to(insert_at_world) < 0.01)
	check("G: exactly THREE revisions pushed in total",
		_hint_g_revision_count(after_insert_ann) == before_revisions + 3,
		"count=%d" % _hint_g_revision_count(after_insert_ann))

	host.set_selected_annotation_id("")


# ── H. universal select through the REAL pcb_canvas input path ──────────────
# (station 6 fix F3, docket 019fd10557c8 comment 1034). G above drives
# select_tool directly; this test drives the CANVAS instead — real
# InputEventMouseButton via get_root().push_input -> pcb_canvas._gui_input ->
# _handle_mouse_button -> _claim_annotation_press ->
# host.annotation_claims_point / annotation_pointer_down — the same
# production topology PCBPanel._sync_universal_select sets up, now reachable
# because G's own (d) flipped `overlay` passive and armed `host` for real
# (host.arm_universal_select). Runs AFTER G on purpose, same reason G runs
# after everything else: it adds its own fixture hint and would otherwise
# perturb A-F/G's hard-coded counts.
#
# NON-UNIT ZOOM (2.0) — deliberately different from every earlier letter's
# fixed 4.0, so a probe/press pair that only agreed by coincidence at an
# integer px/mm ratio would be caught.
#
# THE PROBE/PRESS MIRROR CONTRACT: for each of the four press classes, this
# calls host.annotation_claims_point(canvas_local_pos, 0) — the SAME query
# pcb_canvas._claim_annotation_press makes internally, at the SAME
# canvas-local pixel position _handle_mouse_button would receive — as a
# PREDICTION, then drives the identical point through a REAL
# InputEventMouseButton and checks the prediction against what the real
# dispatch actually did. claimed ⇔ consumed: a predicted claim leaves the
# fixture selected and arms the tool's matching zone (or, for the segment
# case, commits the insert immediately — that gesture has no drag to arm); a
# predicted decline means the press falls through to the board ladder, whose
# own empty-click branch clears the annotation half (every point below also
# misses every OTHER fixture's ink, so "declined" here always means "board
# saw an empty click", never "board hit something else instead").

const HINT_H_ANCHOR := Vector2(5.0, 38.0)
const HINT_H_BEND1  := Vector2(5.0, 53.0)
const HINT_H_BEND2  := Vector2(25.0, 53.0)
const HINT_H_DEST   := Vector2(25.0, 38.0)
## Nearest point of the fixture's own bounds Rect2(5,38,20,15) is its corner
## (25,38) — 35.1mm away, far past the 6mm handle radius zoom=2.0 gives (12px
## / 2.0). ARROW_AT(50,30)/FCU_AT(20,15)/BCU_AT(80,45) (module-level consts,
## _seed_annotations) are all ≥22mm away too — comfortably past every other
## fixture's own ink-hit slack (8px / 2.0 = 4mm).
const HINT_H_OUTSIDE := Vector2(60.0, 55.0)


func _test_h_canvas_real_input_path() -> void:
	print("-- H: universal select through the REAL pcb_canvas input path (F3) --")

	# Non-unit zoom, pan recomputed the same way _mount() centres the board
	# at its own (different) fixed zoom.
	canvas.zoom = 2.0
	canvas.pan_offset = -Vector2(data.board_width, data.board_height) / 2.0 * canvas.zoom
	canvas.queue_redraw()
	await process_frame

	var hint_h_id: String = host.add_route_hint_at(
		HINT_H_ANCHOR.x, HINT_H_ANCHOR.y, "canvas-input probe", "F.Cu", "waypoint",
		[[HINT_H_ANCHOR.x, HINT_H_ANCHOR.y], [HINT_H_BEND1.x, HINT_H_BEND1.y],
			[HINT_H_BEND2.x, HINT_H_BEND2.y], [HINT_H_DEST.x, HINT_H_DEST.y]])
	check("H: fixture hint stored", not hint_h_id.is_empty())
	var kind: AnnotationKind = host.get_registry().get_annotation_kind(&"pcb_route_hint")
	check("H: pcb_route_hint kind resolved", kind != null)
	if kind == null:
		return

	# The REAL, host-vended tool (G's (d) armed it on `host` for real) — NOT
	# the harness's own `select_tool`, which is a separate instance never
	# wired to the canvas at all.
	var real_tool = host.get_universal_select_tool()
	check("H: host vends the real universal-select tool", real_tool != null)
	if real_tool == null:
		return

	# ── (1) press ON A BEND HANDLE ───────────────────────────────────────────
	host.set_selected_annotation_id(hint_h_id)
	var bend_local: Vector2 = canvas.world_to_screen(HINT_H_BEND1)
	var bend_claimed: bool = host.annotation_claims_point(bend_local, 0)
	check("H: probe predicts the bend handle is claimed", bend_claimed)
	var bend_root: Vector2 = _world_to_root_screen(HINT_H_BEND1)
	_push_button(bend_root, MOUSE_BUTTON_LEFT, true)
	await process_frame
	check("H: claimed ⇔ consumed — a real press on the handle arms Zone.BEND",
		bend_claimed == (real_tool._active_zone == AnnotationTransformTool.Zone.BEND
			and real_tool._drag_bend_index == 0),
		"zone=%s idx=%d" % [str(real_tool._active_zone), real_tool._drag_bend_index])
	check("H: fixture stays selected through a claimed press",
		host.get_selected_annotation_id() == hint_h_id)
	_push_button(bend_root, MOUSE_BUTTON_LEFT, false)
	await process_frame
	# Zero-travel release (fix F4): the gesture was claimed and consumed, but
	# a press-release with no motion between them must not commit ANYTHING —
	# count alone would stay 2 even after an unintended move (Codex re-review),
	# so assert the COORDINATE and the revision history too.
	var h_after_click: Dictionary = host.get_by_id(hint_h_id)
	check("H: no-move bend click emits no revision (F4)",
		kind.bend_points(h_after_click).size() == 2
			and (kind.bend_points(h_after_click)[0] as Vector2).distance_to(HINT_H_BEND1) < 0.001
			and (h_after_click.get("revision_stack", []) as Array).is_empty(),
		"bend0=%s revs=%d" % [str(kind.bend_points(h_after_click)[0]),
			(h_after_click.get("revision_stack", []) as Array).size()])

	# STATIONARY OFF-CENTRE press (the F4 re-review defect): a motionless click
	# 4-11px from the handle centre is a VALID hit, and the guard must measure
	# pointer TRAVEL — comparing release-to-centre would read this as a "drag"
	# and jump the bend to the pointer. Offset 2mm world at zoom 2.0 = 4px,
	# inside the 12px/2.0=6mm hit radius, outside the 3px travel threshold's
	# reach of the centre.
	var off_centre_root: Vector2 = _world_to_root_screen(HINT_H_BEND1 + Vector2(2.0, 0.0))
	_push_button(off_centre_root, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_button(off_centre_root, MOUSE_BUTTON_LEFT, false)
	await process_frame
	var h_after_off: Dictionary = host.get_by_id(hint_h_id)
	check("H: stationary OFF-CENTRE click does not jump the bend",
		(kind.bend_points(h_after_off)[0] as Vector2).distance_to(HINT_H_BEND1) < 0.001
			and (h_after_off.get("revision_stack", []) as Array).is_empty(),
		"bend0=%s revs=%d" % [str(kind.bend_points(h_after_off)[0]),
			(h_after_off.get("revision_stack", []) as Array).size()])

	# ── (2) press INSIDE bounds only — no handle, no segment — translate ────
	host.set_selected_annotation_id(hint_h_id)
	var inside_world := Vector2(15.0, 40.0)
	var inside_local: Vector2 = canvas.world_to_screen(inside_world)
	var inside_claimed: bool = host.annotation_claims_point(inside_local, 0)
	check("H: probe predicts the bounds interior is claimed", inside_claimed)
	var inside_root: Vector2 = _world_to_root_screen(inside_world)
	_push_button(inside_root, MOUSE_BUTTON_LEFT, true)
	await process_frame
	check("H: claimed ⇔ consumed — a real press inside bounds arms Zone.INSIDE",
		inside_claimed == (real_tool._active_zone == AnnotationTransformTool.Zone.INSIDE),
		"zone=%s" % str(real_tool._active_zone))
	check("H: fixture stays selected", host.get_selected_annotation_id() == hint_h_id)
	_push_button(inside_root, MOUSE_BUTTON_LEFT, false)
	await process_frame

	# ── (3) press ON THE PATH (a segment, not a handle) — insertion ─────────
	host.set_selected_annotation_id(hint_h_id)
	var seg_world: Vector2 = (HINT_H_BEND1 + HINT_H_BEND2) / 2.0  # midpoint, (15, 53)
	var seg_local: Vector2 = canvas.world_to_screen(seg_world)
	var seg_claimed: bool = host.annotation_claims_point(seg_local, 0)
	check("H: probe predicts the segment is claimed", seg_claimed)
	var before_bends: int = kind.bend_points(host.get_by_id(hint_h_id)).size()
	var seg_root: Vector2 = _world_to_root_screen(seg_world)
	_push_button(seg_root, MOUSE_BUTTON_LEFT, true)
	await process_frame
	var after_bends: int = kind.bend_points(host.get_by_id(hint_h_id)).size()
	check("H: claimed ⇔ consumed — a real press on the segment inserts a bend immediately (no drag armed)",
		seg_claimed == (after_bends == before_bends + 1),
		"before=%d after=%d" % [before_bends, after_bends])
	_push_button(seg_root, MOUSE_BUTTON_LEFT, false)
	await process_frame

	# ── (4) press OUTSIDE everything ─────────────────────────────────────────
	host.set_selected_annotation_id(hint_h_id)
	var outside_local: Vector2 = canvas.world_to_screen(HINT_H_OUTSIDE)
	var outside_claimed: bool = host.annotation_claims_point(outside_local, 0)
	check("H: probe predicts empty space is NOT claimed", not outside_claimed)
	var outside_root: Vector2 = _world_to_root_screen(HINT_H_OUTSIDE)
	_push_button(outside_root, MOUSE_BUTTON_LEFT, true)
	await process_frame
	# BOTH expected outcomes asserted DIRECTLY (Codex re-review P1: the old
	# claimed==cleared equality inverted — claimed is false and cleared is
	# true, so the mirror phrasing evaluated false==true and failed).
	check("H: outside press is NOT claimed", not outside_claimed)
	check("H: outside press cleared the annotation selection",
		host.get_selected_annotation_id() == "",
		"selected='%s'" % host.get_selected_annotation_id())
	_push_button(outside_root, MOUSE_BUTTON_LEFT, false)
	await process_frame

	# ── (5) STALE MENU IDENTITY (Codex re-review on 019fd10557c8, P2): a bend
	# inserted BEFORE the frozen index while the menu sits open shifts every
	# index — the delete must no-op rather than remove a bend the user never
	# aimed at. The guard's identity check is the frozen POINT at a tight
	# epsilon, so the shifted neighbour (well inside the old handle-radius
	# tolerance) must NOT pass for the aimed bend.
	host.set_selected_annotation_id(hint_h_id)
	var bend2_root: Vector2 = _world_to_root_screen(HINT_H_BEND2)
	_push_button(bend2_root, MOUSE_BUTTON_RIGHT, true)
	await process_frame
	_push_button(bend2_root, MOUSE_BUTTON_RIGHT, false)
	await process_frame
	# The FROZEN INDEX is captured dynamically, never hardcoded (Codex: H3's
	# earlier midpoint insert already shifted BEND2's index once — a literal
	# here would assert the wrong element and fail; dynamic capture also keeps
	# H5 immune to any future mutation upstream in this test).
	var frozen_index := int(canvas._context_menu_annotation_bend.get("index", -1))
	check("H5: menu froze the aimed bend (by point, index captured dynamically)",
		not canvas._context_menu_annotation_bend.is_empty() and frozen_index >= 0
			and (canvas._context_menu_annotation_bend.get("point", Vector2.INF) as Vector2)
				.distance_to(HINT_H_BEND2) < 0.001,
		"frozen=%s" % str(canvas._context_menu_annotation_bend))
	# Mutate WHILE the menu is open: insert a bend AT the frozen index, 1mm
	# from BEND2 — inside the 6mm handle radius the old guard accepted, far
	# outside the tight epsilon — shifting the aimed bend to frozen_index + 1.
	var h_live: Dictionary = host.get_by_id(hint_h_id)
	var shifted: Array = kind.bend_points(h_live).duplicate()
	shifted.insert(frozen_index, HINT_H_BEND2 + Vector2(1.0, 0.0))
	host.update_annotation(hint_h_id, kind.with_bend_points(h_live, shifted))
	var count_before_delete: int = kind.bend_points(host.get_by_id(hint_h_id)).size()
	canvas.context_menu.id_pressed.emit(canvas.MENU_ID_DELETE_ANNOTATION_BEND)
	await process_frame
	var h_after_stale: Dictionary = host.get_by_id(hint_h_id)
	check("H5: stale-index delete is a NO-OP (count unchanged)",
		kind.bend_points(h_after_stale).size() == count_before_delete,
		"count=%d expected=%d" % [kind.bend_points(h_after_stale).size(), count_before_delete])
	check("H5: the aimed bend survives at frozen_index + 1",
		(kind.bend_points(h_after_stale)[frozen_index + 1] as Vector2)
			.distance_to(HINT_H_BEND2) < 0.001)
	if canvas.context_menu.visible:
		canvas.context_menu.hide()

	host.set_selected_annotation_id("")


# ── I. consumed-record filter (Epoch UX2 station 1) ──────────────────────────

## The dock half of "applied intents render nothing": lifecycle "applied"
## workflow annotations are hidden from the day-to-day listing behind a
## "Show consumed (N)" toggle. The record is browsable on opt-in, never
## deleted, and flipping the lifecycle back (the commit-undo reconcile path)
## restores the row with the toggle untouched.
func _test_i_consumed_filter() -> void:
	print("-- I: consumed-record filter (show-consumed toggle) --")
	workflow_list.refresh()
	var before: int = workflow_list.get_listing().size()
	var consumed_before: int = workflow_list.consumed_count()
	check("I: filter defaults OFF", not bool(workflow_list.get_show_consumed()))

	var res: Dictionary = host.update_annotation_lifecycle(fcu_id, "applied")
	check("I: lifecycle flip to applied accepted", bool(res.get("ok", false)),
		"res=%s" % str(res))
	workflow_list.refresh()
	await process_frame

	var listing: Array = workflow_list.get_listing()
	var ids := []
	for entry in listing:
		ids.append(str((entry as Dictionary).get("id", "")))
	check("I: consumed hint leaves the default listing", not (fcu_id in ids),
		"ids=%s" % str(ids))
	check("I: listing shrank by exactly 1", listing.size() == before - 1,
		"size=%d before=%d" % [listing.size(), before])
	check("I: consumed_count sees the hidden record", workflow_list.consumed_count() == consumed_before + 1,
		"count=%d" % workflow_list.consumed_count())
	check("I: toggle control is visible once a consumed record exists",
		workflow_list._consumed_toggle != null and workflow_list._consumed_toggle.visible)
	check("I: toggle label carries the count",
		workflow_list._consumed_toggle.text == "Show consumed (%d)" % (consumed_before + 1),
		"text=%s" % workflow_list._consumed_toggle.text)

	# Opt-in: the record comes back, marked with its lifecycle, same #index
	# discipline as every other row.
	workflow_list.set_show_consumed(true)
	var revealed: Array = workflow_list.get_listing()
	var revealed_entry := {}
	for entry in revealed:
		if str((entry as Dictionary).get("id", "")) == fcu_id:
			revealed_entry = entry
	check("I: show-consumed reveals the record", not revealed_entry.is_empty())
	check("I: revealed listing back to full size", revealed.size() == before,
		"size=%d before=%d" % [revealed.size(), before])
	check("I: revealed entry carries lifecycle applied",
		str(revealed_entry.get("lifecycle", "")) == "applied")

	workflow_list.set_show_consumed(false)
	check("I: toggle off hides it again",
		workflow_list.get_listing().size() == before - 1)

	# The undo path: applied -> open (what the commit-undo lifecycle reconcile
	# does) restores the row with the filter still on default.
	host.update_annotation_lifecycle(fcu_id, "open")
	workflow_list.refresh()
	await process_frame
	var restored: Array = workflow_list.get_listing()
	var restored_ids := []
	for entry in restored:
		restored_ids.append(str((entry as Dictionary).get("id", "")))
	check("I: applied->open flip restores the row (undo pin)", fcu_id in restored_ids)
	check("I: consumed_count back to baseline", workflow_list.consumed_count() == consumed_before,
		"count=%d" % workflow_list.consumed_count())
	check("I: toggle hidden again when no consumed records remain",
		workflow_list._consumed_toggle == null or not workflow_list._consumed_toggle.visible
			or consumed_before > 0)


# ── J. sidecar auto-write (Epoch UX2 station 8) ──────────────────────────────

## The durable-by-default half of docket 019fde57027c: once the panel has a
## document path, every annotation mutation schedules a debounced sidecar
## write — no Ctrl+S needed (HITL-4 lost three hand-authored annotations to a
## restart because the write only ran on save). Also pins the teardown flush:
## a pending debounced write survives panel exit.
func _test_j_sidecar_autosave() -> void:
	print("-- J: sidecar auto-write, debounced + teardown flush (UX2 station 8) --")
	var sidecar_path := SIDECAR_DOC + ".annotations.json"
	if FileAccess.file_exists(sidecar_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar_path))

	panel._file_path = SIDECAR_DOC
	host.set_document_path(SIDECAR_DOC)

	var auto_id: String = host.add_route_hint_at(5.0, 5.0, "autosave probe", "F.Cu",
		"waypoint", [[5.0, 5.0], [9.0, 5.0]])
	check("J: probe hint stored", not auto_id.is_empty())
	check("J: nothing on disk inside the debounce window",
		not FileAccess.file_exists(sidecar_path))

	await create_timer(1.2).timeout
	check("J: sidecar auto-written after the debounce (no save request ran)",
		FileAccess.file_exists(sidecar_path))
	var data: Dictionary = AnnotationSidecar.read_sidecar(SIDECAR_DOC)
	var ids := []
	for ann in data.get("annotations", []):
		ids.append(str((ann as Dictionary).get("id", "")))
	check("J: auto-written sidecar carries the probe annotation", auto_id in ids)

	# Teardown flush: a mutation whose debounce window has NOT elapsed still
	# lands, because _exit_tree flushes the pending write synchronously.
	host.update_annotation_lifecycle(auto_id, "applied")
	check("J: flush precondition — a write is pending", panel._sidecar_autosave_pending)
	panel._exit_tree()
	var flushed: Dictionary = AnnotationSidecar.read_sidecar(SIDECAR_DOC)
	var flushed_lifecycle := ""
	for ann in flushed.get("annotations", []):
		if str((ann as Dictionary).get("id", "")) == auto_id:
			flushed_lifecycle = str((ann as Dictionary).get("lifecycle", ""))
	check("J: pending write flushed on exit (mutation on disk without the debounce)",
		flushed_lifecycle == "applied")
	check("J: flush cleared the pending flag (idempotent with the real exit)",
		not panel._sidecar_autosave_pending)


# ── K. minerva_pcb_get_selection — the deictic read (HITL-6b) ────────────────

## docket 019fdf5579: "I've selected X — what is it?" answered in ONE call for
## every entity kind. Against the REAL panel dispatch, real canvas selection
## state, real host annotation selection, real workspace candidate.
func _test_k_get_selection() -> void:
	print("-- K: minerva_pcb_get_selection — every kind, one deictic read (HITL-6b) --")

	# Empty selection is an ANSWER.
	canvas._clear_selection()
	host.set_selected_annotation_id("")
	var empty: Dictionary = await panel.handle_tool("minerva_pcb_get_selection",
		{"editor_name": EDITOR_NAME})
	check("K: empty selection succeeds", bool(empty.get("success", false)), str(empty))
	check("K: empty selection count 0", int(empty.get("count", -1)) == 0)
	check("K: empty selection carries the note", not str(empty.get("note", "")).is_empty())

	# A component + an annotation + a ghost, all selected at once.
	canvas._add_to_selection(canvas.KIND_COMPONENT, "U1")
	host.set_selected_annotation_id(fcu_id)
	var ws = panel.get_routing_workspace()
	var probe_cid: String = str(ws.ingest_record({
		"net": "K_NET",
		"segments": [{"start": [3.0, 3.0], "end": [8.0, 3.0], "layer": "F.Cu"}],
		"vias": [], "width": 0.3, "source_hint_ids": [fcu_id], "source_hints": [],
	}, 0))
	canvas._add_to_selection(canvas.KIND_CANDIDATE, probe_cid)

	var reply: Dictionary = await panel.handle_tool("minerva_pcb_get_selection",
		{"editor_name": EDITOR_NAME})
	check("K: mixed selection succeeds", bool(reply.get("success", false)), str(reply))
	var by_kind := {}
	for entry in reply.get("selection", []):
		by_kind[str((entry as Dictionary).get("kind", ""))] = entry
	check("K: component entry present", by_kind.has("component"))
	if by_kind.has("component"):
		var ce: Dictionary = by_kind["component"]
		check("K: component id", str(ce.get("id", "")) == "U1")
		check("K: component carries its position", absf(float(ce.get("x", 0.0)) - 30.0) < 0.001)
	check("K: annotation entry present", by_kind.has("annotation"))
	if by_kind.has("annotation"):
		var ae: Dictionary = by_kind["annotation"]
		check("K: annotation id is the selected hint", str(ae.get("id", "")) == fcu_id)
		check("K: annotation kind named", str(ae.get("annotation_kind", "")) == "pcb_route_hint")
	check("K: candidate entry present (the ghost)", by_kind.has("candidate"))
	if by_kind.has("candidate"):
		var ke: Dictionary = by_kind["candidate"]
		check("K: ghost id", str(ke.get("id", "")) == probe_cid)
		check("K: ghost carries its net", str(ke.get("net", "")) == "K_NET")
		check("K: ghost carries quality metrics", ke.has("bend_count"))
		check("K: ghost carries the source intent note",
			(ke.get("source_intent_notes", []) as Array).size() == 1
			and str((ke.get("source_intent_notes", []) as Array)[0]) == "top corridor")
	check("K: the ghost pick fed active_candidate_id (the HITL-6b seam)",
		str(reply.get("active_candidate_id", "")) == probe_cid)

	# Cleanup: release everything K selected.
	canvas._clear_selection()
	host.set_selected_annotation_id("")
	check("K: clear released the workspace focus too", str(ws.active_candidate_id) == "")


# ── cleanup + assertion helper ────────────────────────────────────────────────

func _cleanup_sidecar() -> void:
	var sidecar_path := SIDECAR_DOC + ".annotations.json"
	if FileAccess.file_exists(sidecar_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar_path))


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)
