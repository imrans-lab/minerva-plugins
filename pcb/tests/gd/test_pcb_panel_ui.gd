extends SceneTree
## PCB panel UI test (Round B of the panel port).
##
## Run: godot --headless --path src --script test/test_pcb_panel_ui.gd
##
## Drives the ported PCB panel (minerva-plugins/pcb/ui/PCBPanel.gd) HEADLESSLY via
## the plugin_panel_driver helper — exercising the panel-hook contract, the board
## model wiring, the dirty (content_changed) relay, and the annotation-host
## registration lifecycle. Interactive canvas behavior (selection, drag, rotate,
## trace draw, zoom/pan, grid snap, toolbar buttons, YAML export) CANNOT be
## asserted headlessly — that is the HITL debt and is NOT faked here.
##
## Off-tree scripts are load()ed at runtime (res:// == src/, so
## res://../../minerva-plugins == C:/github/minerva-plugins).

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const DRIVER_PATH := "res://test/helpers/plugin_panel_driver.gd"
## The shared bus plan — the ORACLE the held-lead test below reads its expected
## words, class and finding count out of. See _test_bus_refusal_is_held.
const PANEL_TOOLS_PATH := "res://../../minerva-plugins/pcb/ui/panel_tools.gd"

var _pass_count: int = 0
var _fail_count: int = 0
var _driver = null


## Minimal editor stand-in: PCBPanel._on_panel_loaded reads ctx.editor.tab_title
## via `"tab_title" in ed` + property access.
class FakeEditor extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== PCB Panel UI Test ===\n")
	await process_frame

	_driver = load(DRIVER_PATH).new()
	check("plugin_panel_driver loads", _driver != null)
	var probe: Variant = _driver.load_panel(PANEL_PATH) if _driver != null else null
	check("PCBPanel script loads + instantiates off-tree", probe != null)
	if _driver == null or probe == null:
		_finish()
		return
	_driver.free_panel(probe)

	_test_canonical_load_and_save()
	_test_legacy_skeleton_migration()
	_test_content_changed_dirty_relay()
	_test_annotation_host_registration()
	_test_trace_context_menu()
	_test_cutover_flip_on_boot()
	await _test_reclick_disarm()
	await _test_reclick_triple_agreement()
	await _test_first_click_and_cross_tool_unchanged()
	await _test_width_menu_focus_at_every_tier()
	await _test_check_button_and_ghost_readout()
	await _test_propose_selection_scope_and_retry_narration()
	await _test_intent_parity_and_width_picker()
	await _test_promote_headless_fail_closed()
	await _test_bus_phase_badge()
	await _test_bus_refusal_is_held()
	await _test_board_undo_redo()
	await _test_selection_drag_threshold()

	_finish()


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Representative canonical board dict (to_board_dict shape) ──────────────────

func _canonical_board() -> Dictionary:
	return {
		"version": 1,
		"name": "UITestBoard",
		"width_mm": 50.0,
		"height_mm": 40.0,
		"grid_mm": 2.54,
		"design_rules": {"clearance_mm": 0.2},
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 20.0, "y_mm": 12.0, "rotation_deg": 90.0,
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}, {"number": "8", "x_mm": 7.62, "y_mm": 0.0}]},
			{"ref": "R1", "footprint": "RESISTOR", "x_mm": 34.0, "y_mm": 6.0, "rotation_deg": 0.0,
				"value": "10k",
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}, {"number": "2", "x_mm": 2.54, "y_mm": 0.0}]},
		],
		"nets": [
			{"name": "VCC", "pins": ["U1.8", "R1.1"]},
		],
		"traces": [
			{"net": "VCC", "layer": "top", "width_mm": 0.25,
				"points": [{"x_mm": 10.0, "y_mm": 5.0}, {"x_mm": 20.0, "y_mm": 12.0}]},
		],
		"vias": [],
	}


# ── Tests ─────────────────────────────────────────────────────────────────────

## Canonical board dict loads → model populated; save returns a canonical dict.
func _test_canonical_load_and_save() -> void:
	print("-- canonical board dict load → model populated; save → canonical dict --")
	var board_dir: String = _driver.make_temp_board_dir("pcb_panel_ui")
	var board_path := board_dir + "/canonical.pcbskel"
	_driver.cleanup_sidecar(board_path)

	var panel: Variant = _driver.load_panel(PANEL_PATH)
	_driver.drive_load_merged(panel, board_path, _canonical_board())

	var data: Variant = panel.get_data()
	check("panel exposes a board model after load", data != null)
	if data != null:
		check("model has both components (U1, R1)", data.get_component_count() == 2)
		check("model kept the VCC net", data.has_net("VCC"))
		check("model kept the routed trace", data.get_trace_count() == 1)
		check("U1 canonical fields survived (pos + rotation)",
				data.get_component("U1") != null
				and data.get_component("U1").position == Vector2(20.0, 12.0)
				and data.get_component("U1").rotation == 90.0)
		check("R1 value survived (10k)",
				data.get_component("R1") != null
				and data.get_component("R1").properties.get("value", "") == "10k")

	var saved: Dictionary = _driver.drive_save(panel)
	check("save returns canonical board dict (width_mm/height_mm/grid_mm)",
			saved.has("width_mm") and saved.has("height_mm") and saved.has("grid_mm"))
	check("save components is a list (canonical), not id-map",
			saved.get("components", null) is Array and (saved["components"] as Array).size() == 2)
	check("save does NOT emit the legacy nested 'board' key", not saved.has("board"),
			"saved keys: %s" % str(saved.keys()))
	check("save does NOT emit annotations/route_hints (dock owns them)",
			not saved.has("annotations") and not saved.has("route_hints"))

	_driver.cleanup_sidecar(board_path)
	_driver.cleanup_board_file(board_path)
	_driver.free_panel(panel)


## Legacy skeleton shape {board:{…}, components:[{ref,x,y,w,h}]} still loads
## (migration path).
func _test_legacy_skeleton_migration() -> void:
	print("\n-- legacy skeleton-shape document still loads (migration) --")
	var board_dir: String = _driver.make_temp_board_dir("pcb_panel_ui")
	var board_path := board_dir + "/legacy.pcbskel"
	_driver.cleanup_sidecar(board_path)

	var panel: Variant = _driver.load_panel(PANEL_PATH)
	_driver.drive_load_merged(panel, board_path, {
		"version": 1,
		"kind": "pcbskel_board",
		"board": {"width_mm": 60.0, "height_mm": 40.0},
		"components": [
			{"ref": "U1", "x": 8.0, "y": 8.0, "w": 16.0, "h": 16.0},
			{"ref": "J1", "x": 6.0, "y": 30.0, "w": 20.0, "h": 6.0},
		],
	})

	var data: Variant = panel.get_data()
	check("legacy board size migrated (60x40)",
			data != null and data.board_width == 60.0 and data.board_height == 40.0)
	check("legacy components migrated (U1, J1)",
			data != null and data.get_component_count() == 2
			and data.get_component("U1") != null and data.get_component("J1") != null)
	check("legacy component position migrated (U1 @ 8,8)",
			data != null and data.get_component("U1") != null
			and data.get_component("U1").position == Vector2(8.0, 8.0))

	# A canonical save after migration must be canonical (no nested 'board').
	var saved: Dictionary = _driver.drive_save(panel)
	check("migrated board saves canonical (no nested 'board')",
			saved.has("width_mm") and not saved.has("board"))

	_driver.cleanup_sidecar(board_path)
	_driver.cleanup_board_file(board_path)
	_driver.free_panel(panel)


## Model mutation flips content_changed; restoring a saved board does NOT.
func _test_content_changed_dirty_relay() -> void:
	print("\n-- model mutation flips content_changed; load does not (restoring gate) --")
	var board_dir: String = _driver.make_temp_board_dir("pcb_panel_ui")
	var board_path := board_dir + "/dirty.pcbskel"
	_driver.cleanup_sidecar(board_path)

	var panel: Variant = _driver.load_panel(PANEL_PATH)
	var spy := {"count": 0}
	panel.content_changed.connect(func() -> void: spy.count += 1)

	# Load a board — the _restoring gate must suppress the dirty relay.
	_driver.drive_load_merged(panel, board_path, _canonical_board())
	check("load does NOT flip content_changed (restoring gate)", spy.count == 0,
			"got %d emits during load" % spy.count)

	# Mutate via the model API → content_changed must fire (dirty glyph).
	var data: Variant = panel.get_data()
	data.move_component("U1", Vector2(25.0, 15.0))
	check("model mutation flips content_changed (dirty)", spy.count >= 1,
			"got %d emits after move_component" % spy.count)

	# Authoring an annotation via the host must also flip content_changed.
	var before: int = spy.count
	panel.get_annotation_host().add_route_hint_at(3.0, 3.0, "dirty hint")
	check("annotation authoring flips content_changed", spy.count > before,
			"count before=%d after=%d" % [before, spy.count])

	_driver.cleanup_sidecar(board_path)
	_driver.cleanup_board_file(board_path)
	_driver.free_panel(panel)


## The panel registers its annotation host by editor tab title on mount and
## deregisters on unload (the MCP-reach seam).
func _test_annotation_host_registration() -> void:
	print("\n-- annotation host registered on load / deregistered on unload --")
	AnnotationHostRegistry._reset_for_test()

	var panel: Variant = _driver.load_panel(PANEL_PATH)
	var ed := FakeEditor.new()
	ed.tab_title = "PCB UI Test Tab"
	panel._on_panel_loaded({"editor": ed, "file_path": ""})

	var host: Variant = panel.get_annotation_host()
	check("host registered under the editor tab title on mount",
			AnnotationHostRegistry.get_host("PCB UI Test Tab") == host)
	check("editor tab title listed in registry",
			"PCB UI Test Tab" in AnnotationHostRegistry.list_editor_names())

	panel._on_panel_unload()
	check("host deregistered on unload",
			AnnotationHostRegistry.get_host("PCB UI Test Tab") == null)

	AnnotationHostRegistry._reset_for_test()
	_driver.free_panel(panel)


## The TRACE context menu (B1u5, docket 019fbb968e — owner comment 962: the width
## editor already existed and was undiscoverable).
##
## Pins the canvas→panel half of the item: "Set trace width…" must SELECT the trace
## and REVEAL the panel's existing width row — not set a width itself. That is what
## keeps the no-op guard, the model refusal string and the single journalled
## set_trace_width call in one place instead of two.
func _test_trace_context_menu() -> void:
	print("\n-- trace right-click: Set trace width… + Delete trace (B1u5) --")
	var panel: Variant = _driver.load_panel(PANEL_PATH)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_canonical_board())

	var canvas: Variant = panel._canvas
	var data: Variant = panel.get_data()
	var trace_id: String = str(data.get_trace_ids()[0])
	canvas._create_context_menu()

	# What the right-press would have resolved on the trace.
	canvas.context_menu_world_pos = Vector2(15.0, 8.5)
	canvas._context_menu_vertex = {}
	canvas._context_menu_edge_insert = {}
	canvas._context_menu_target = [canvas.KIND_TRACE, trace_id]
	canvas._update_context_menu_for_selection()
	check("trace menu offers Set trace width…", _menu_has(canvas, "Set trace width…"))
	check("trace menu offers Delete trace", _menu_has(canvas, "Delete trace"))
	check("trace menu does NOT offer vertex items",
			not _menu_has(canvas, "Delete vertex") and not _menu_has(canvas, "Insert vertex here"))

	# Set trace width… → the trace becomes the whole selection and the row appears.
	canvas._on_context_menu_pressed(canvas.MENU_ID_SET_TRACE_WIDTH)
	check("Set trace width… selects exactly that trace",
			canvas.get_selected_traces().size() == 1
			and str(canvas.get_selected_traces()[0]) == trace_id)
	check("…and the panel's width row is now showing that trace",
			panel._trace_prop_rows != null and panel._trace_prop_rows.visible
			and panel._trace_prop_trace_id == trace_id,
			"visible=%s id=%s" % [
				str(panel._trace_prop_rows != null and panel._trace_prop_rows.visible),
				panel._trace_prop_trace_id])

	# The commit still runs through the ROW's handler — one journalled step, and a
	# repeat of the same value must not push a second (the dead-undo-step guard).
	var before: int = data.change_journal.size()
	panel._on_trace_prop_width_changed(0.4)
	check("the row's handler is what re-widens the trace",
			is_equal_approx(float(data.get_trace(trace_id).width), 0.4))
	check("…journalled exactly once", data.change_journal.size() == before + 1,
			"journal grew by %d" % (data.change_journal.size() - before))
	panel._on_trace_prop_width_changed(0.4)
	check("a no-op re-commit adds no dead undo step",
			data.change_journal.size() == before + 1)

	# Delete trace, through the same journalled remover the eraser uses.
	canvas._context_menu_target = [canvas.KIND_TRACE, trace_id]
	canvas._on_context_menu_pressed(canvas.MENU_ID_DELETE_TARGET)
	check("Delete trace removes it", data.get_trace(trace_id) == null)
	check("…and undo brings it back", data.undo() and data.get_trace(trace_id) != null)

	# THE FIX FOR COLD-REVIEW F1, at every tier. "Set trace width…" has to CLEAR
	# THE PATH to the row, not just set the row's own visible flag: medium
	# collapses Properties by default and narrow hides the sidebar behind the
	# drawer, so a handler that only checked the row would land the owner back in
	# comment 962 — the item does nothing visible — in two tiers out of three.
	var layout = load("res://../../minerva-plugins/pcb/ui/panel_layout.gd")
	for mode in [layout.MODE_WIDE, layout.MODE_MEDIUM, layout.MODE_NARROW]:
		panel._apply_layout_mode(mode, true)
		panel._set_properties_expanded(false)  # the medium default, forced everywhere
		canvas._context_menu_target = [canvas.KIND_TRACE, trace_id]
		canvas._on_context_menu_pressed(canvas.MENU_ID_SET_TRACE_WIDTH)
		check("%s: Set trace width… expands the Properties section" % mode,
				panel._properties_expanded
				and panel._properties_body != null and panel._properties_body.visible,
				"expanded=%s body_visible=%s" % [
					str(panel._properties_expanded),
					str(panel._properties_body != null and panel._properties_body.visible)])
		check("%s: …and the width row itself is showing" % mode,
				panel._trace_prop_rows.visible and panel._trace_prop_trace_id == trace_id)
		if mode == layout.MODE_NARROW:
			check("narrow: …and the drawer is opened so the sidebar is on screen",
					panel._drawer_open and panel._sidebar != null and panel._sidebar.visible,
					"drawer_open=%s sidebar_visible=%s" % [
						str(panel._drawer_open),
						str(panel._sidebar != null and panel._sidebar.visible)])

	# The other three targets name themselves, and a LOCKED one is shown-but-
	# disabled rather than missing (so the lock is the visible reason).
	data.vias.append({"id": "via_1", "position": Vector2(12.0, 9.0), "size": 0.8,
			"drill": 0.4, "net_name": "VCC", "from_layer": "top", "to_layer": "bottom"})
	canvas._context_menu_target = [canvas.KIND_VIA, "via_1"]
	canvas._update_context_menu_for_selection()
	check("via menu offers Delete via", _menu_has(canvas, "Delete via"))
	canvas._on_context_menu_pressed(canvas.MENU_ID_DELETE_TARGET)
	check("Delete via removes it", data.find_via_index("via_1") < 0)

	canvas._context_menu_target = [canvas.KIND_COMPONENT, "R1"]
	canvas.context_menu_world_pos = Vector2(34.0, 6.0)
	canvas._update_context_menu_for_selection()
	check("component menu names the part in its Delete item", _menu_has(canvas, "Delete R1"))
	check("…and still reaches the pre-existing Lock item",
			_menu_has(canvas, "Lock R1 (L)") or _menu_has(canvas, "Lock Component (L)"))
	data.get_component("R1").locked = true
	canvas._update_context_menu_for_selection()
	check("a locked target's Delete is shown but disabled",
			_menu_disabled(canvas, "Delete R1"))
	data.get_component("R1").locked = false

	# GROUPED target: the item must say what the click will actually do, since
	# _delete_picked_entity removes the WHOLE group (cold-review F4).
	data.group_components(["U1", "R1"])
	canvas._context_menu_target = [canvas.KIND_COMPONENT, "R1"]
	canvas._update_context_menu_for_selection()
	check("a grouped target's Delete names the GROUP, not the one part",
			_menu_has(canvas, "Delete group (2 parts)") and not _menu_has(canvas, "Delete R1"))

	_driver.free_panel(panel)


func _menu_disabled(canvas: Variant, text: String) -> bool:
	for i in canvas.context_menu.item_count:
		if canvas.context_menu.get_item_text(i) == text:
			return canvas.context_menu.is_item_disabled(i)
	return false


func _menu_has(canvas: Variant, text: String) -> bool:
	for i in canvas.context_menu.item_count:
		if canvas.context_menu.get_item_text(i) == text:
			return true
	return false


# ──────────────────────────────────────────────────────────────────────────────

func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)


# ── Epoch-C boundary G1: the cutover flag has a PRODUCTION flip ───────────────
#
# THE DEFECT THIS PINS, stated as it was found: nothing in production ever called
# RoutingCutover.set_workspace_authoritative. The canvas surface therefore stayed
# annotation-authoritative forever, pcb_canvas._candidates_active() was
# permanently false, and every candidate path it gates (candidate_draw_items,
# _candidate_at through the _entity_at ladder, _run_candidate_verb,
# _emit_candidate_teach_line) was dead. Combined with C4b retiring the proposal
# ANNOTATION write-back, a Propose at that HEAD landed a real candidate in the
# workspace and rendered NOTHING, anywhere — the routing HITL session could not
# run at all.
#
# WHY THIS SUITE OWNS IT. The existing candidate coverage
# (test_candidate_canvas.gd) proves the canvas draws once a cutover is flipped —
# but it flips the coordinator ITSELF, in the fixture, so it passes identically
# whether or not production ever flips one. Only a REAL BOOTED PANEL can tell
# those two worlds apart, and the panel-boot suite is here. That is the whole
# delta: no assertion below constructs a cutover or calls a flip.
#
# TWO LEGS, deliberately:
#   1. the GATE — _candidates_active() is TRUE on a freshly booted panel's canvas
#      (the flag itself, read where production reads it);
#   2. the RENDER — a candidate ingested through THE PANEL'S OWN workspace
#      produces non-empty candidate_draw_items(), i.e. the geometry actually
#      reaches the paint path. Leg 1 alone would still pass if the wiring between
#      panel and canvas were broken; leg 2 alone would not name the flag.
#
# The candidate is ingested through the panel's workspace rather than a
# stand-in, so the object under assertion is the one _build_ui handed the canvas.
func _test_cutover_flip_on_boot() -> void:
	print("\n-- G1: booting the panel flips the canvas cutover, and ghosts render --")
	var panel: Variant = _driver.load_panel(PANEL_PATH)

	# BEFORE the mount hook: still all-annotation-authoritative. This is not a
	# formality — it pins that the flip is the MOUNT's doing (paired with the
	# workspace handoff) and not an unconditional _init side effect, which is
	# exactly what keeps a bare, unmounted panel inert.
	var cutover_pre: Variant = panel.get_routing_cutover()
	check("G1: an UNMOUNTED panel is still all-annotation-authoritative",
			cutover_pre != null and cutover_pre.all_annotation_authoritative())

	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_canonical_board())

	var canvas: Variant = panel._canvas
	var cutover: Variant = panel.get_routing_cutover()
	check("G1 fixture: the booted panel built a canvas", canvas != null)
	check("G1 fixture: the booted panel exposes a cutover coordinator", cutover != null)
	if canvas == null or cutover == null:
		_driver.free_panel(panel)
		return

	# LEG 1 — THE GATE, read exactly where production reads it.
	check("G1: the panel flipped the 'canvas' surface to workspace-authoritative",
			cutover.is_workspace_authoritative("canvas"),
			"authority=%s" % str(cutover.authority("canvas")))
	check("G1: _candidates_active() is TRUE on a booted panel's canvas "
			+ "(false here = a Propose renders nothing, anywhere)",
			canvas._candidates_active())

	# ONLY "canvas" is claimed. The other surfaces have no production reader, so
	# flipping them would assert a migration nothing consults — pinned so a later
	# blanket flip has to argue with a test rather than slip through.
	check("G1: 'verbs' surface is NOT flipped (no production reader)",
			not cutover.is_workspace_authoritative("verbs"))
	check("G1: 'persistence' surface is NOT flipped (no production reader)",
			not cutover.is_workspace_authoritative("persistence"))

	# LEG 2 — THE RENDER, end to end through the panel's OWN workspace.
	var ws: Variant = panel.get_routing_workspace()
	check("G1 fixture: the booted panel exposes a routing workspace", ws != null)
	if ws == null:
		_driver.free_panel(panel)
		return
	check("G1 baseline: an empty workspace draws no ghosts",
			canvas.candidate_draw_items().is_empty(),
			"%d items" % canvas.candidate_draw_items().size())

	var new_ids: Array = ws.ingest_routing_result(
			{"routes": [{
				"net": "N7",
				"segments": [
					{"start": [0.0, 0.0], "end": [10.0, 0.0], "layer": "F.Cu"},
					{"start": [10.0, 0.0], "end": [10.0, 5.0], "layer": "B.Cu"},
				],
				"vias": [[10.0, 0.0]],
			}]},
			[{"id": "h7", "kind_payload": {"net_names": ["N7"], "width_mm": 0.3}}],
			int(panel.get_data().board_revision))
	check("G1 fixture: the panel's workspace really ingested a candidate",
			new_ids.size() == 1 and not str(new_ids[0]).is_empty(), str(new_ids))

	var items: Array = canvas.candidate_draw_items()
	check("G1: the ingested candidate REACHES THE PAINT PATH "
			+ "(candidate_draw_items non-empty)",
			not items.is_empty(), "%d items" % items.size())
	check("G1: 2 segments + 1 via, from the panel's own workspace",
			items.size() == 3, "%d items" % items.size())
	check("G1: every draw item belongs to the ingested candidate",
			_all_items_for(items, str(new_ids[0])))

	# And the rollback door still closes the surface on a live panel — the flip
	# is a latch, not a one-way door (the cutover contract's own promise).
	cutover.rollback("canvas")
	check("G1: rollback('canvas') closes the surface again on a LIVE panel",
			canvas.candidate_draw_items().is_empty(),
			"%d items" % canvas.candidate_draw_items().size())

	_driver.free_panel(panel)


## True iff every draw item names `candidate_id` as its owner.
func _all_items_for(items: Array, candidate_id: String) -> bool:
	for it in items:
		if str(it.get("candidate_id", "")) != candidate_id:
			return false
	return not items.is_empty()


# ── Campaign 2 boundary: BT-63, BT-64, BT-65, BT-68 ───────────────────────────
#
# DELTA DISCIPLINE. 9b887e9 pinned the width-menu REVEAL at all three layout
# tiers (visibility of the row + the drawer). BT-68's delta is the FOCUS half —
# the leg the first fix missed — which needs a panel that is really IN THE TREE,
# so these mount rather than using the off-tree driver.
#
# BT-63/64/65 (re-click disarm, item 019fbbadd8f0) had no coverage in this suite.


## A panel mounted in the real tree, so is_visible_in_tree() and has_focus()
## mean something.
func _mount_panel_in_tree(width: float = 1100.0) -> Variant:
	var panel: Variant = load(PANEL_PATH).new()
	get_root().add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(width, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_canonical_board())
	for _i in range(6):
		await process_frame
	return panel


## BT-63 — re-clicking an ARMED tool mid-polygon disarms to Select AND says so.
##
## ORACLE: the rendered STATUS LABEL TEXT read AT CALL RETURN. Asserting the
## zone_tool_message signal alone passes falsely — the standing status refresh
## (_update_status, driven off tool_mode_changed) runs after the cancel and would
## clobber the cancel line. That clobbering IS the shipped bug this pins, so the
## label is the only representation that can see it.
func _test_reclick_disarm() -> void:
	print("\n-- BT-63: re-click mid-polygon disarms, and the LABEL says so --")
	var panel: Variant = await _mount_panel_in_tree()
	var canvas: Variant = panel._canvas

	panel._toggle_tool_mode(canvas.ToolMode.ZONE_POUR)
	await process_frame
	check("BT-63 fixture: the pour tool is armed",
			canvas.tool_mode == canvas.ToolMode.ZONE_POUR)

	# Place two corners so there is a polygon in flight to abandon.
	canvas._zone_points = PackedVector2Array([Vector2(4, 4), Vector2(12, 4)])
	check("BT-63 fixture: a polygon is in flight", canvas._zone_points.size() == 2)

	var messages: Array = []
	canvas.zone_tool_message.connect(func(t: String) -> void: messages.append(t))

	panel._toggle_tool_mode(canvas.ToolMode.ZONE_POUR)   # the RE-click
	var label_at_return: String = str(panel._status_label.text)

	check("BT-63: the re-click disarmed back to SELECT",
			canvas.tool_mode == canvas.ToolMode.SELECT, "tool_mode=%d" % canvas.tool_mode)
	check("BT-63: …and the in-flight polygon was dropped",
			canvas._zone_points.is_empty(), "%d points left" % canvas._zone_points.size())
	check("BT-63: …and the cancel was emitted at all",
			messages.size() == 1 and messages[0] == "Zone cancelled.", str(messages))
	check("BT-63: …and the STATUS LABEL still carries it AT CALL RETURN "
			+ "(signal-only assertions pass while this is wrong)",
			label_at_return.contains("Zone cancelled"),
			"label=%s" % label_at_return)

	panel.queue_free()
	await process_frame


## BT-64 — the re-click triple: mode, buttons, hint. All six radios.
##
## ORACLE: THREE independently owned readings — the canvas enum, the panel's
## Button widgets, and the _MODE_HINTS table lookup that feeds the status bar.
func _test_reclick_triple_agreement() -> void:
	print("\n-- BT-64: re-click each radio → mode/buttons/hint agree --")
	var panel: Variant = await _mount_panel_in_tree()
	var canvas: Variant = panel._canvas
	var P := load(PANEL_PATH)

	for mode in panel._tool_buttons.keys():
		var m := int(mode)
		if m == canvas.ToolMode.SELECT:
			continue   # Select IS the resting tool; a re-click is a documented no-op.
		panel._toggle_tool_mode(m)
		await process_frame
		check("BT-64: mode %d arms" % m, canvas.tool_mode == m)
		panel._toggle_tool_mode(m)   # re-click
		await process_frame

		check("BT-64 (1/3) mode %d: the ENUM disarmed to SELECT" % m,
				canvas.tool_mode == canvas.ToolMode.SELECT, "tool_mode=%d" % canvas.tool_mode)
		var pressed: Array = []
		for k in panel._tool_buttons.keys():
			if (panel._tool_buttons[k] as Button).button_pressed:
				pressed.append(int(k))
		check("BT-64 (2/3) mode %d: exactly the SELECT BUTTON is pressed" % m,
				pressed == [int(canvas.ToolMode.SELECT)], "pressed=%s" % str(pressed))
		check("BT-64 (3/3) mode %d: the status HINT is SELECT's" % m,
				str(panel._status_label.text).contains(str(P._MODE_HINTS[canvas.ToolMode.SELECT])),
				"label=%s" % str(panel._status_label.text))

	panel.queue_free()
	await process_frame


## BT-65 — the FIRST click and CROSS-TOOL switches are untouched by the re-click
## feature (was_armed == false on both).
##
## ORACLE: a full state DICT compared against the pre-feature behaviour — arming
## a tool from Select, and switching tool→tool, must both leave the requested
## tool armed, not collapse to Select.
func _test_first_click_and_cross_tool_unchanged() -> void:
	print("\n-- BT-65: first-click + cross-tool paths unchanged --")
	var panel: Variant = await _mount_panel_in_tree()
	var canvas: Variant = panel._canvas

	panel._toggle_tool_mode(canvas.ToolMode.SELECT)
	await process_frame
	panel._toggle_tool_mode(canvas.ToolMode.PAN)
	await process_frame
	check("BT-65: a FIRST click on a tool arms it (does not disarm instantly)",
			_tool_state(panel, canvas) == {"mode": int(canvas.ToolMode.PAN),
					"pressed": [int(canvas.ToolMode.PAN)]},
			"state=%s" % str(_tool_state(panel, canvas)))

	panel._toggle_tool_mode(canvas.ToolMode.ERASER)   # cross-tool switch
	await process_frame
	check("BT-65: a CROSS-TOOL switch lands on the new tool, not SELECT",
			_tool_state(panel, canvas) == {"mode": int(canvas.ToolMode.ERASER),
					"pressed": [int(canvas.ToolMode.ERASER)]},
			"state=%s" % str(_tool_state(panel, canvas)))

	panel._toggle_tool_mode(canvas.ToolMode.ERASER)   # NOW a re-click
	await process_frame
	check("BT-65: only the SAME-tool re-click disarms",
			canvas.tool_mode == canvas.ToolMode.SELECT)

	panel.queue_free()
	await process_frame


func _tool_state(panel: Variant, canvas: Variant) -> Dictionary:
	var pressed: Array = []
	for k in panel._tool_buttons.keys():
		if (panel._tool_buttons[k] as Button).button_pressed:
			pressed.append(int(k))
	pressed.sort()
	return {"mode": int(canvas.tool_mode), "pressed": pressed}


## BT-68 — "Set trace width…" at EVERY layout tier: the SpinBox ends up both
## VISIBLE IN TREE and HOLDING FOCUS.
##
## ORACLE: two properties, at all three tiers. 9b887e9 pins the row's `visible`
## flag and the drawer; visibility alone is what the first fix satisfied while
## the caret was still nowhere — the medium tier (Properties collapsed by
## default) being the dead end. Reveal assertions are taken AFTER deferred frames
## per hint pcb-plugin/scroll-reveal-needs-deferred-frame.
func _test_width_menu_focus_at_every_tier() -> void:
	print("\n-- BT-68: width menu → SpinBox visible AND focused, all three tiers --")
	var panel: Variant = await _mount_panel_in_tree()
	var canvas: Variant = panel._canvas
	var data: Variant = panel.get_data()
	var trace_id: String = str(data.get_trace_ids()[0])
	canvas._create_context_menu()
	var layout = load("res://../../minerva-plugins/pcb/ui/panel_layout.gd")

	for mode in [layout.MODE_WIDE, layout.MODE_MEDIUM, layout.MODE_NARROW]:
		panel._apply_layout_mode(mode, true)
		panel._set_properties_expanded(false)      # the collapsed medium default
		panel._drawer_open = false
		for _i in range(4):
			await process_frame

		canvas._context_menu_target = [canvas.KIND_TRACE, trace_id]
		canvas._on_context_menu_pressed(canvas.MENU_ID_SET_TRACE_WIDTH)
		# The reveal defers one layout pass on purpose (hint
		# pcb-plugin/scroll-reveal-needs-deferred-frame) — assert after it lands.
		for _i in range(6):
			await process_frame

		var spin: Variant = panel._trace_prop_width_spin
		check("BT-68 %s: the width SpinBox is VISIBLE IN TREE" % mode,
				spin != null and spin.is_visible_in_tree(),
				"spin=%s expanded=%s drawer=%s" % [str(spin != null),
						str(panel._properties_expanded), str(panel._drawer_open)])
		check("BT-68 %s: …and it HOLDS FOCUS, ready to type" % mode,
				spin != null and spin.get_line_edit().has_focus(),
				"focus_owner=%s" % str(panel.get_viewport().gui_get_focus_owner()))

	panel.queue_free()
	await process_frame


# ── Epoch UX3 station 3 (docket 019fdf90662a): Check button + ghost readout ───
# check_draft had NO UI caller and the status bar counted parts but never
# ghosts. Asserted headlessly: the button exists in the Proposals flow, the
# no-candidates press narrates rather than no-ops, the headless press (no IPC
# backend) reverts to prior verdicts AND says so, the steady-state readout
# carries the tally exactly while live ghosts exist, and the Ghosts view flag
# joined the one View-menu table.

func _test_check_button_and_ghost_readout() -> void:
	print("-- UX3-5: Check button, ghost status tally, Ghosts view flag --")
	# MOUNTED: the button/status assertions read UI that only exists after
	# _on_panel_loaded's _build_ui — bare load_panel builds no tree.
	var panel: Variant = await _mount_panel_in_tree()

	var check_btn: Variant = panel.find_child("CheckButton", true, false)
	check("a CheckButton exists in the sidebar", check_btn != null)
	var propose_btn: Variant = panel.find_child("ProposeButton", true, false)
	check("…in the same Proposals flow as Propose",
		check_btn != null and propose_btn != null
		and check_btn.get_parent() == propose_btn.get_parent())

	# View flag (c): the ONE view-flags table gained the ghost surface.
	var flags: Array = panel._VIEW_FLAGS
	var ghost_row: Array = []
	for row in flags:
		if str(row[1]) == "show_route_candidates":
			ghost_row = row
	check("_VIEW_FLAGS carries show_route_candidates", not ghost_row.is_empty())
	check("…labelled Ghosts", not ghost_row.is_empty() and str(ghost_row[0]) == "Ghosts")

	# No candidates: the press must SAY there is nothing, not silently no-op.
	await panel._on_check_button_pressed()
	var status: Variant = panel.find_child("StatusBar", true, false)
	check("status bar exists", status != null)
	check("no-candidates press narrates ('Nothing to check')",
		status != null and str(status.text).contains("Nothing to check"))

	# Seed one live candidate directly in the workspace (the same direct-drive
	# every workspace suite uses) and read the tally.
	var ws: Variant = panel.get_routing_workspace()
	check("panel exposes the routing workspace", ws != null)
	var reply := {"routes": [{"net": "N1",
		"segments": [{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"}],
		"vias": []}]}
	var hints := [{"id": "h1", "kind_payload": {"net_names": ["N1"], "width_mm": 0.3}}]
	var ids: Array = ws.ingest_routing_result(reply, hints, 1)
	check("seeded one live candidate", ids.size() == 1)

	check("ghost summary reads '1 ghost: 1 unchecked'",
		str(panel._ghost_status_summary()) == "1 ghost: 1 unchecked",
		"got '%s'" % str(panel._ghost_status_summary()))
	panel._update_status()
	check("the steady-state readout carries the tally",
		status != null and str(status.text).contains("1 ghost: 1 unchecked"))

	# Headless press over a live candidate: no IPC backend exists, so
	# check_draft's contract is revert-to-prior + an honest status line —
	# never a candidate stuck on "checking" and never a fake verdict.
	await panel._on_check_button_pressed()
	check("headless check reverts the candidate to its prior verdict",
		str(ws.get_candidate(str(ids[0])).validation) == "unchecked")
	check("…and the status line says the worker was unavailable",
		status != null and str(status.text).contains("could not run"))

	# A verdict written by the model (a later real check) flows into the tally.
	ws.set_validation(str(ids[0]), "clean")
	check("verdict flows into the summary",
		str(panel._ghost_status_summary()) == "1 ghost: 1 clean")

	# The tally leaves when the last live candidate does (reject is terminal).
	ws.reject(str(ids[0]))
	check("no live ghosts -> empty summary (readout returns to its old shape)",
		str(panel._ghost_status_summary()) == "")

	_driver.free_panel(panel)


# ── Epoch UX3 station 5d: Propose button respects the hint selection ──────────
# Selected OPEN pcb_route_hints scope the run; everything else in a mixed
# selection contributes nothing; no selection keeps all-open. Plus the retry
# handler's headless refusal narration (5a's panel half, named errors echoed).

func _test_propose_selection_scope_and_retry_narration() -> void:
	print("-- UX3-1: propose selection scope + retry refusal narration --")
	# MOUNTED for the same _build_ui reason as the Check-button group above.
	var panel: Variant = await _mount_panel_in_tree()
	var host: Variant = panel.get_annotation_host()
	host.set_panel(panel)

	# Seed one OPEN route hint + select it.
	var env: Dictionary = host.build_route_hint_envelope(
		0.0, 0.0, "", "F.Cu", "waypoint", [[0.0, 0.0], [5.0, 0.0]], "human")
	var open_id: String = str(host.add_annotation_v2(env))
	host.set_selected_annotation_ids(PackedStringArray([open_id]))
	var scoped: Array = panel._selected_open_hint_ids()
	check("a selected open route hint scopes the propose",
		scoped.size() == 1 and str(scoped[0]) == open_id)

	# A non-open hint in the selection contributes nothing.
	var ann: Dictionary = host.get_by_id(open_id)
	ann["lifecycle"] = "applied"
	host.update_annotation(open_id, ann)
	check("an applied hint no longer scopes",
		(panel._selected_open_hint_ids() as Array).is_empty())

	# Empty selection → empty scope (the all-open default path).
	host.set_selected_annotation_ids(PackedStringArray([]))
	check("no selection ⇒ empty scope", (panel._selected_open_hint_ids() as Array).is_empty())

	# Retry handler, headless: an unknown candidate refuses BY NAME and the
	# status line echoes it — the narration contract, no backend needed.
	await panel._on_candidate_retry_requested("cand_nope", {})
	var status: Variant = panel.find_child("StatusBar", true, false)
	check("retry refusal is narrated with the tool's named error",
		status != null and str(status.text).contains("refused")
		and str(status.text).contains("cand_nope"))

	_driver.free_panel(panel)


# ── Epoch UX3 station 8 + HITL-7c: intent parity + per-hint width menu ────────
# (a) the bare pad→pad gesture delegates to minerva_pcb_add_route_intent (ONE
# implementation: eager task, same-net validation, same reply); (b) HITL-7c
# (docket 019fe0395764, owner override of the station-8b authoring picker):
# width is edited PER HINT from its context menu — the hidden HintWidthRow
# binds by id, writes kind_payload.width_mm through update_annotation, 0
# erases the key (auto); an explicit envelope width_mm arg is the only
# authoring-time stamping path.

func _test_intent_parity_and_width_picker() -> void:
	print("-- UX3-4 + HITL-7c: pad→pad mints a TRUE intent; per-hint width menu --")
	var panel: Variant = await _mount_panel_in_tree()
	var host: Variant = panel.get_annotation_host()
	host.set_panel(panel)
	var ws: Variant = panel.get_routing_workspace()
	var canvas: Variant = panel._canvas

	# ── (b) authoring: NO picker fallback anywhere ───────────────────────────
	var env_h: Dictionary = host.build_route_hint_envelope(1.0, 1.0, "", "F.Cu", "waypoint",
		[[1.0, 1.0], [2.0, 2.0]], "human")
	check("HITL-7c: a human envelope with no width arg carries NO width_mm",
		not (env_h.get("kind_payload", {}) as Dictionary).has("width_mm"))
	var env_explicit: Dictionary = host.build_route_hint_envelope(1.0, 1.0, "", "F.Cu", "waypoint",
		[[1.0, 1.0]], "human", "", 0.7)
	check("an explicit width argument still stamps",
		is_equal_approx(float((env_explicit.get("kind_payload", {}) as Dictionary).get("width_mm", 0.0)), 0.7))
	check("the panel no longer exposes an authoring-default width",
		not panel.has_method("get_hint_authoring_width"))

	# ── (a) the delegation seam mints a TRUE intent (width-free) ─────────────
	# _canonical_board wires net VCC = U1.8 + R1.1.
	var kind_script: Variant = load("res://../../minerva-plugins/pcb/ui/kinds/pcb_route_hint_kind.gd")
	var tool: Variant = kind_script.SingleTraceAuthorTool.new()
	tool.on_activate(host)
	var reply: Variant = tool._mint_intent_via_panel("U1.8", "R1.1")
	check("the delegation returns the intent tool's reply", reply is Dictionary)
	var hint_id := ""
	if reply is Dictionary:
		var rd: Dictionary = reply
		check("…success", bool(rd.get("success", false)))
		check_eq_str("…net resolved from the pins", str(rd.get("net", "")), "VCC")
		hint_id = str(rd.get("hint_id", ""))
		check("…a hint was minted", not hint_id.is_empty())
		check_eq_str("…the eager task uses the ingest key format",
			str(rd.get("task_id", "")), "VCC|%s" % hint_id)
		check("…the eager task EXISTS in the workspace",
			ws.get_task(str(rd.get("task_id", ""))) != null)
		var ann: Dictionary = host.get_by_id(hint_id)
		check("…the intent annotation carries NO waypoints (a true intent)",
			((ann.get("kind_payload", {}) as Dictionary).get("waypoints", [1]) as Array).is_empty())
		check("…and lands at the net-class default (no width_mm — HITL-7c)",
			not (ann.get("kind_payload", {}) as Dictionary).has("width_mm"))

	# ── (b') the context-menu width flow, end to end ─────────────────────────
	var row: Variant = panel.find_child("HintWidthRow", true, false)
	check("the per-hint width row exists and starts HIDDEN",
		row != null and not (row as Control).visible)
	host.set_selected_annotation_ids(PackedStringArray([hint_id]))
	check_eq_str("the press-time resolver names the selected hint",
		str(canvas._selected_route_hint_id()), hint_id)
	canvas._create_context_menu()
	canvas._context_menu_target = ["", ""]
	canvas._context_menu_route_hint = canvas._selected_route_hint_id()
	canvas._update_context_menu_for_selection()
	var labels: Array = []
	for i in range(canvas.context_menu.item_count):
		labels.append(canvas.context_menu.get_item_text(i))
	check("the menu offers Set hint width…", "Set hint width…" in labels)
	# The menu item's emit → panel handler binds and reveals the row.
	canvas.edit_hint_width_requested.emit(hint_id)
	check("the row is revealed and bound",
		(row as Control).visible and str(panel._hint_width_hint_id) == hint_id)
	# A spin change writes THIS hint's width, one revision.
	panel._hint_width_spin.value = 0.45
	var after: Dictionary = host.get_by_id(hint_id)
	check("the width landed on the hint's payload",
		is_equal_approx(float((after.get("kind_payload", {}) as Dictionary).get("width_mm", 0.0)), 0.45))
	# 0 = auto: the key is ERASED, never a 0.0 sentinel (D9a-2 rule).
	panel._hint_width_spin.value = 0.0
	var cleared: Dictionary = host.get_by_id(hint_id)
	check("width 0 erases the key (auto = net-class default)",
		not (cleared.get("kind_payload", {}) as Dictionary).has("width_mm"))

	# A pin with no net refuses BY NAME — the answer the legacy look-alike
	# path could never give.
	var refused: Variant = tool._mint_intent_via_panel("U1.1", "R1.1")
	check("a netless pin refuses by name",
		refused is Dictionary and not bool((refused as Dictionary).get("success", true))
		and str((refused as Dictionary).get("error", "")) == "pin_unresolvable")

	tool.on_deactivate()
	_driver.free_panel(panel)


## String check_eq twin (this suite's check() takes desc/cond/detail).
func check_eq_str(desc: String, actual: String, expected: String) -> void:
	check("%s (expected '%s', got '%s')" % [desc, expected, actual], actual == expected)


# ── Epoch UX3 station 11: the promotion verb, headless half ───────────────────
# The full gate needs the live worker (pytest tests/test_promote_check.py owns
# the verdict composition); what is assertable here: the button exists, the
# verb FAILS CLOSED with no backend (worker_unavailable — an unverifiable
# board never promotes), and the channel-reply unwrap discipline.

func _test_promote_headless_fail_closed() -> void:
	print("-- UX3-10: Promote button + headless fail-closed + unwrap discipline --")
	var panel: Variant = await _mount_panel_in_tree()

	var btn: Variant = panel.find_child("PromoteButton", true, false)
	check("the Proposals flow carries the Promote button", btn != null)
	# HITL-7d (docket 019fe03963df): Check and Promote carry icons like every
	# sibling button (text stays the load-failure fallback only).
	check("Promote has its icon", btn != null and (btn as Button).icon != null)
	var check_btn2: Variant = panel.find_child("CheckButton", true, false)
	check("Check has its icon", check_btn2 != null and (check_btn2 as Button).icon != null)

	# Path guards answer BEFORE the ipc guard — the specific refusal wins even
	# with the backend down (cold review F8's coverage gap, closed).
	var no_path: Dictionary = await panel.promote("")
	check_eq_str("no adopted canonical source + no arg ⇒ no_target_path",
		str(no_path.get("error", "")), "no_target_path")
	var skel: Dictionary = await panel.promote("/tmp/board.pcbskel")
	check_eq_str("a .pcbskel target refuses OUTRIGHT (the F2 corruption guard)",
		str(skel.get("error", "")), "pcbskel_target")

	var res: Dictionary = await panel.promote("/tmp/should_never_be_written.yaml")
	check("headless promote fails CLOSED", not bool(res.get("success", true)))
	check_eq_str("…named worker_unavailable (the gate could not run)",
		str(res.get("error", "")), "worker_unavailable")
	check("…and wrote nothing", not FileAccess.file_exists("/tmp/should_never_be_written.yaml"))

	# Unwrap discipline: only a fully-ok envelope yields the inner result.
	# The failure rows use the LIVE broker shapes (cold review F3): every real
	# failure carries success:false with NO result key at all.
	check("unwrap: ok chain yields the inner dict",
		str(panel._unwrap_channel_reply({"success": true,
			"result": {"ok": true, "result": {"x": 1}}})) == str({"x": 1}))
	check("unwrap: the LIVE resultless timeout shape yields {}",
		(panel._unwrap_channel_reply({"success": false, "error_code": "timeout",
			"error_message": "timed out", "reply_id": "r1"}) as Dictionary).is_empty())
	check("unwrap: the panel's own ipc-null failure shape yields {}",
		(panel._unwrap_channel_reply({"success": false,
			"error_code": "ipc_unavailable"}) as Dictionary).is_empty())
	check("unwrap: worker failure yields {}",
		(panel._unwrap_channel_reply({"ok": false, "error": {"kind": "x"}}) as Dictionary).is_empty())

	_driver.free_panel(panel)


# ── The Bus tool's PHASE BADGE ────────────────────────────────────────────────
#
# The bus gesture has three phases and its toolbar button is icon-only, so
# nothing on the toolbar said which phase was live. The canvas's two reports
# both fail a user who looks away: the status line is wiped on the next status
# refresh, and the canvas teach line is anchored to the last picked pad, which
# pans off screen. The badge is painted on the button itself.
#
# ORACLE: WHAT THE NEXT CLICK DOES. The badge's step is read against the phase
# established BEHAVIOURALLY — a click clear of the pads either adds a net
# (SOURCES) or places a spine vertex (PATH), and a pad click either picks a net
# or lands a target — measured on the canvas's own gesture buffers, which no
# badge code writes. Reading the badge back against _bus_phase would only
# re-assert the assignment the badge was handed.
#
# The two failures it exists to cure get their own oracles: the status label is
# refreshed (the same call the 2s transient timer makes) and the board is panned
# until the picked pads leave the viewport, and the badge is read again after
# each.

const BADGE_SRC_A := Vector2(10.0, 10.0)
const BADGE_SRC_B := Vector2(10.0, 14.0)
const BADGE_TGT_A := Vector2(60.0, 10.0)
const BADGE_PATH_1 := Vector2(25.0, 25.0)
const BADGE_PATH_2 := Vector2(45.0, 25.0)


## Two nets, two pads each, pads far apart and far clear of the path vertices
## above — the smallest board the bus tool will path at all (it refuses a net
## with no second pad to run to).
func _bus_badge_board() -> Dictionary:
	return {
		"version": 1, "name": "BusBadgeBoard", "width_mm": 80.0, "height_mm": 40.0,
		"grid_mm": 2.54,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.3, "trace_width_mm": 0.2},
		"components": [
			_badge_part("U1", BADGE_SRC_A), _badge_part("U2", BADGE_SRC_B),
			_badge_part("V1", BADGE_TGT_A), _badge_part("V2", Vector2(60.0, 14.0)),
		],
		"nets": [
			{"name": "NA", "pins": ["U1.1", "V1.1"]},
			{"name": "NB", "pins": ["U2.1", "V2.1"]},
		],
	}


## One part, one pin, pin 1 at the component origin — so the component's own
## placement IS the pad's world position.
func _badge_part(ref: String, at: Vector2) -> Dictionary:
	return {"ref": ref, "footprint": "IC_DIP", "x_mm": at.x, "y_mm": at.y,
		"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]}


## The objects listening on a button's `draw` signal. Identified by object
## rather than by method name: the painter is connected through a .bind(), and
## get_object() is defined for a bound callable where the method name is not
## dependably readable back off one.
func _draw_listeners(btn: Button) -> Array:
	var out: Array = []
	for c in btn.get_signal_connection_list("draw"):
		out.append(((c as Dictionary)["callable"] as Callable).get_object())
	return out


## Every tool button in either family EXCEPT the two Bus doorways.
func _non_bus_tool_buttons(panel: Variant, bus_mode: int) -> Array:
	var out: Array = []
	for family in [panel._tool_buttons, panel._draft_tool_buttons]:
		for mode in (family as Dictionary).keys():
			if int(mode) != bus_mode:
				out.append((family as Dictionary)[mode] as Button)
	return out


## For each phase in turn: the index of the badge's single ACTIVE pip, or -1
## when the badge does not mark exactly one pip out of exactly `phases`. A list
## oracle, so the whole badge vocabulary is read in one assertion.
func _badge_active_indices(P: Variant, btn_size: Vector2, phases: int) -> Array:
	var out: Array = []
	for step in range(phases):
		var pips: Array = P.bus_badge_pips(btn_size, step, phases)
		var active: Array = []
		for i in range(pips.size()):
			if str((pips[i] as Dictionary)["state"]) == "active":
				active.append(i)
		out.append(int(active[0]) if active.size() == 1 and pips.size() == phases else -1)
	return out


func _test_bus_phase_badge() -> void:
	print("\n-- the Bus button's badge names the live phase, with no timer --")
	var panel: Variant = await _mount_panel_in_tree()
	var canvas: Variant = panel._canvas
	var P := load(PANEL_PATH)
	panel.get_data().from_board_dict(_bus_badge_board())
	# Authored points land exactly where clicked, so the vertices below stay the
	# measured distance clear of every pad.
	canvas.snap_to_grid = false
	await process_frame

	var direct_btn: Button = panel._tool_buttons[canvas.ToolMode.BUS]
	var draft_btn: Button = panel._draft_tool_buttons[canvas.ToolMode.BUS]
	var trace_btn: Button = panel._tool_buttons[canvas.ToolMode.TRACE]

	check("badge fixture: the Bus button has a real laid-out rect (%s)" % str(direct_btn.size),
			direct_btn.size.x >= 20.0 and direct_btn.size.y >= 20.0)
	check("badge: with no bus armed there is no phase to show",
			panel.bus_phase_step() == -1, "step=%d" % panel.bus_phase_step())
	check("badge: Draw ▸ Bus has exactly one painter on it, and it is the panel",
			_draw_listeners(direct_btn) == [panel], str(_draw_listeners(direct_btn)))
	check("badge: Draft ▸ Bus carries the SAME badge — one gesture, one set of phases",
			_draw_listeners(draft_btn) == [panel], str(_draw_listeners(draft_btn)))
	var badged_elsewhere: Array = []
	for other in _non_bus_tool_buttons(panel, int(canvas.ToolMode.BUS)):
		if not _draw_listeners(other as Button).is_empty():
			badged_elsewhere.append((other as Button).name)
	check("badge: no OTHER tool button is painted — the badge belongs to the "
			+ "three-phase tool, not to the toolbar",
			badged_elsewhere.is_empty(), str(badged_elsewhere))
	check("badge: the Bus button still measures exactly like an unbadged icon "
			+ "sibling — the badge is painted, never laid out",
			direct_btn.get_combined_minimum_size() == trace_btn.get_combined_minimum_size(),
			"bus=%s trace=%s" % [str(direct_btn.get_combined_minimum_size()),
				str(trace_btn.get_combined_minimum_size())])

	# ── The gesture, phase by phase, each read against what the click did ──────
	panel._toggle_tool_mode(canvas.ToolMode.BUS)
	await process_frame
	check("badge fixture: the Draw ▸ Bus doorway is the pressed one",
			direct_btn.button_pressed and not draft_btn.button_pressed)
	check("badge: armed and untouched, the badge marks the FIRST phase",
			panel.bus_phase_step() == 0, "step=%d" % panel.bus_phase_step())

	canvas._handle_bus_click(BADGE_SRC_A, false)
	canvas._handle_bus_click(BADGE_SRC_B, false)
	check("oracle (SOURCES): with the badge on phase 1, pad clicks added NETS and "
			+ "placed no spine vertex — the SOURCES verb",
			canvas._bus_nets.size() == 2 and canvas._bus_spine_points.is_empty(),
			"nets=%s spine=%d" % [str(canvas._bus_nets), canvas._bus_spine_points.size()])
	check("badge: picking a net does not advance the phase",
			panel.bus_phase_step() == 0, "step=%d" % panel.bus_phase_step())

	canvas._handle_bus_click(BADGE_PATH_1, false)
	check("oracle (PATH): the clear-board click became the path's FIRST VERTEX "
			+ "instead of a third net pick",
			canvas._bus_spine_points.size() == 1 and canvas._bus_nets.size() == 2,
			"spine=%d nets=%d" % [canvas._bus_spine_points.size(), canvas._bus_nets.size()])
	check("badge: …and the badge moved to the SECOND phase with it",
			panel.bus_phase_step() == 1, "step=%d" % panel.bus_phase_step())
	canvas._handle_bus_click(BADGE_PATH_2, false)
	check("oracle (PATH): a second clear click places another vertex — still pathing",
			canvas._bus_spine_points.size() == 2, "spine=%d" % canvas._bus_spine_points.size())
	check("badge: …and the badge is still on the second phase",
			panel.bus_phase_step() == 1, "step=%d" % panel.bus_phase_step())

	canvas._handle_bus_click(BADGE_TGT_A, false)
	check("oracle (TARGETS): the pad click LANDED A TARGET rather than a vertex",
			canvas._bus_target_refs[0] == "V1.1" and canvas._bus_spine_points.size() == 2,
			"targets=%s spine=%d" % [str(canvas._bus_target_refs), canvas._bus_spine_points.size()])
	check("badge: …and the badge marks the LAST phase",
			panel.bus_phase_step() == 2, "step=%d" % panel.bus_phase_step())

	# ── It does not expire, and it is not anchored to the board ───────────────
	var label_before: String = str(panel._status_label.text)
	panel._update_status()          # exactly what the 2s transient timer calls
	await process_frame
	check("badge: the status line's phase words are wiped by the same refresh the "
			+ "2s transient timer fires — and the badge is not",
			label_before != str(panel._status_label.text) and panel.bus_phase_step() == 2,
			"before=%s after=%s step=%d" % [label_before, str(panel._status_label.text),
				panel.bus_phase_step()])
	# THE LANE MAPPING lives on this standing line (the badge is three pips on
	# a 24px icon and cannot carry text): NA landed on V1.1, NB still open.
	check("status: the standing line lists every lane in pick order with its ending",
			str(panel._status_label.text).contains("lanes: 1 NA  U1.1 → V1.1 · 2 NB  U2.1 → open"),
			str(panel._status_label.text))
	check("status: …and the tooltip carries the same mapping untrimmed",
			str(panel._status_label.tooltip_text).contains("1 NA  U1.1 → V1.1"),
			str(panel._status_label.tooltip_text))
	canvas.pan_offset += Vector2(100000.0, 100000.0)
	await process_frame
	var pad_screen: Vector2 = canvas.world_to_screen(BADGE_SRC_A)
	check("badge: the picked pads (and the teach line anchored to them) are off "
			+ "screen, and the badge still names the phase",
			not Rect2(Vector2.ZERO, canvas.size).has_point(pad_screen)
				and panel.bus_phase_step() == 2,
			"pad at %s, canvas %s, step=%d" % [str(pad_screen), str(canvas.size),
				panel.bus_phase_step()])

	# ── The Esc ladder peels one phase, and the badge peels with it ───────────
	canvas._cancel_bus_step(false)
	check("oracle (ladder): Esc cleared the targets and KEPT the path",
			canvas._bus_target_refs[0] == "" and canvas._bus_spine_points.size() == 2,
			"targets=%s spine=%d" % [str(canvas._bus_target_refs), canvas._bus_spine_points.size()])
	check("badge: …and the badge went back to the second phase, not to the first",
			panel.bus_phase_step() == 1, "step=%d" % panel.bus_phase_step())

	# ── Both doorways, and disarming ──────────────────────────────────────────
	panel._toggle_draft_tool(canvas.ToolMode.BUS)
	await process_frame
	check("badge: switching doorway mid-gesture moves the badge to the pressed "
			+ "button and keeps the phase the gesture is in",
			draft_btn.button_pressed and not direct_btn.button_pressed
				and panel.bus_phase_step() == 1, "step=%d" % panel.bus_phase_step())
	panel._toggle_draft_tool(canvas.ToolMode.BUS)      # the re-click disarms
	await process_frame
	check("badge: disarming leaves no phase to show, on either doorway",
			panel.bus_phase_step() == -1 and not draft_btn.button_pressed
				and not direct_btn.button_pressed, "step=%d" % panel.bus_phase_step())

	# ── The badge's own vocabulary ────────────────────────────────────────────
	var phases: int = int(canvas.BusPhase.size())
	check("badge: one pip per phase, and the tool still has 3 (%d)" % phases,
			phases == 3 and P.bus_badge_pips(direct_btn.size, 0, phases).size() == phases)
	check("badge: exactly one pip is ACTIVE, at the live phase's own index, for "
			+ "every phase in turn",
			_badge_active_indices(P, direct_btn.size, phases) == [0, 1, 2],
			str(_badge_active_indices(P, direct_btn.size, phases)))
	var inside := true
	for step in range(phases):
		for pip in P.bus_badge_pips(direct_btn.size, step, phases):
			var c: Vector2 = (pip as Dictionary)["centre"]
			inside = inside and Rect2(Vector2.ZERO, direct_btn.size).has_point(c)
	check("badge: every pip lands inside the button's own rect, so it can never "
			+ "mark a neighbouring tool", inside, "button %s" % str(direct_btn.size))

	panel.queue_free()
	await process_frame


# ── The Bus tool's REFUSAL, said out loud ─────────────────────────────────────
#
# The tool already KNEW its live plan was refused — it tinted the spine and
# printed the reason in a small on-canvas label. Both marks sit at the spine's
# first vertex, which pans off screen, so the refusal can be visible while its
# reason is not.
#
# So the reason goes where the user already looks, and STAYS: the panel's
# standing status line (not the 2s transient sink — a refusal that expires is a
# refusal nobody reads) and the phase badge's colour.
#
# AND IT SAYS WHICH KIND OF "no" IT IS. A plan that breaks a rule but has
# geometry COMMITS on the finish gesture; only a plan with no geometry writes
# nothing. One word for both would teach the user that the commit is broken, so
# the lead reads the plan's own `buildable` flag and finding count, not just its
# words. The badge keeps ONE colour for both: it says "read the line", and the
# line says which.
#
# ORACLE: THE SHARED PLAN'S OWN WORDS AND FLAGS. panel_tools.bus_plan — the one
# function the gesture, both MCP verbs and the commit all call — is asked to
# plan the SAME fixture geometry directly, and its error string, its `buildable`
# flag and its finding count are what the canvas, the panel accessors and the
# rendered status label are each held to. The refusal RULES are not being tested
# here (test_bus_breakout_geometry.gd and test_pcb_bus_geometry.gd own those);
# what is tested is that the words reach the user, stay reachable, and describe
# what the finish gesture will actually do.

## A second path vertex 0.1mm from the first. The badge board's two 0.2mm nets
## at 0.3mm clearance ride lanes at ±0.25mm, so a 0.1mm spine segment is
## shorter than the widest offset and the inner track would fold back on
## itself — bus_plan's inner-fold FINDING, reached while still PATHING. It is
## bad-but-buildable, so this fixture is also the "will land with findings"
## class the held lead has to distinguish.
const BADGE_FOLD := Vector2(25.1, 25.0)


func _test_bus_refusal_is_held() -> void:
	print("\n-- a flagged bus plan is named in the status line, and HELD there --")
	var panel: Variant = await _mount_panel_in_tree()
	var canvas: Variant = panel._canvas
	var P := load(PANEL_PATH)
	var PT := load(PANEL_TOOLS_PATH)
	panel.get_data().from_board_dict(_bus_badge_board())
	canvas.snap_to_grid = false
	await process_frame

	check("refusal: with no bus armed the panel has no refusal to report",
			panel.bus_refusal_text() == "", panel.bus_refusal_text())

	# Every crossing the canvas announces, in order — the edge-triggered feed
	# the panel's two surfaces repaint off.
	var announced: Array = []
	canvas.bus_refusal_changed.connect(func(refused: bool) -> void: announced.append(refused))

	panel._toggle_tool_mode(canvas.ToolMode.BUS)
	await process_frame
	canvas._handle_bus_click(BADGE_SRC_A, false)
	canvas._handle_bus_click(BADGE_SRC_B, false)
	canvas._handle_bus_click(BADGE_PATH_1, false)
	check("refusal fixture: two nets picked, pathing on top from one vertex",
			canvas._bus_nets.size() == 2 and canvas._bus_layer == "top"
				and canvas._bus_spine_points.size() == 1,
			"nets=%s layer=%s spine=%d" % [str(canvas._bus_nets), canvas._bus_layer,
				canvas._bus_spine_points.size()])
	check("refusal: one vertex is not yet a plan — nothing refused, nothing announced",
			canvas.bus_refusal() == "" and announced.is_empty(),
			"refusal=%s announced=%s" % [canvas.bus_refusal(), str(announced)])

	# ── The fold, planned INDEPENDENTLY to get the expected words ─────────────
	var oracle: Dictionary = PT.bus_plan(panel.get_data(), ["NA", "NB"],
		PackedVector2Array([BADGE_PATH_1, BADGE_FOLD]), "top",
		PackedStringArray(["U1.1", "U2.1"]), PackedStringArray())
	var expected := str(oracle.get("error", ""))
	var oracle_findings: Array = oracle.get("findings", []) if oracle.get("findings", []) is Array else []
	# THE ORACLE IS THE PLAN'S OWN CLASS. A fold is bad-but-BUILDABLE: the
	# finish gesture lands this copper and repeats the broken rules, so the
	# words the panel holds must say that and not "refused".
	check("refusal oracle: bus_plan itself flags this spine, says why, and "
			+ "would still BUILD it",
			not bool(oracle.get("ok", true)) and not expected.is_empty()
				and bool(oracle.get("buildable", false)) and oracle_findings.size() >= 1,
			"%s (buildable=%s findings=%d)" % [expected,
				str(oracle.get("buildable", false)), oracle_findings.size()])

	canvas._handle_bus_click(BADGE_FOLD, false)
	check("refusal: the canvas reports the refusal in bus_plan's own words",
			canvas.bus_refusal() == expected, canvas.bus_refusal())
	check("refusal: the panel reads those same words — and the same CLASS — "
			+ "back off the canvas, holding no copy of either",
			panel.bus_refusal_text() == expected
				and bool(canvas.bus_plan_buildable()) and bool(panel.bus_plan_lands())
				and int(canvas.bus_finding_count()) == oracle_findings.size()
				and int(panel.bus_finding_count()) == oracle_findings.size(),
			"%s (lands=%s findings=%d)" % [panel.bus_refusal_text(),
				str(panel.bus_plan_lands()), int(panel.bus_finding_count())])
	check("refusal: the crossing was announced exactly once, as refused",
			announced == [true], str(announced))
	# BOTH CLASSES OF NO, in one place. The live one is the buildable kind, so
	# the line counts findings and must not say REFUSED; the geometry-less kind
	# is unreachable by clicking this fixture (every gesture-made plan has
	# geometry), so it is read off the pure builder the label goes through.
	var lands_lead := "BUS WILL LAND WITH %d FINDING%s:" % [
		oracle_findings.size(), "" if oracle_findings.size() == 1 else "S"]
	check("refusal: the STATUS LINE carries the reason, led by what the finish "
			+ "gesture will DO — this bus lands, and only a plan with no "
			+ "geometry is still called REFUSED",
			str(panel._status_label.text).contains(expected)
				and str(panel._status_label.text).contains(lands_lead)
				and not str(panel._status_label.text).contains("BUS REFUSED")
				and P.bus_status_lead(expected, false, 0).begins_with("BUS REFUSED: " + expected)
				and P.bus_status_lead(expected, true, 1).begins_with("BUS WILL LAND WITH 1 FINDING: ")
				and P.bus_status_lead("", true, 0) == "",
			"%s || unbuildable lead: %s" % [str(panel._status_label.text),
				P.bus_status_lead(expected, false, 0)])
	check("refusal: …and the full text is on the tooltip, which no ellipsis trims",
			str(panel._status_label.tooltip_text).contains(expected),
			str(panel._status_label.tooltip_text))

	# ── HELD: it outlasts a transient message AND the refresh that clears one ─
	panel._show_transient_status("a passing message")
	check("refusal: a transient message does NOT displace it — the line carries "
			+ "the passing words and the standing refusal at once",
			str(panel._status_label.text).contains("a passing message")
				and str(panel._status_label.text).contains(expected),
			str(panel._status_label.text))
	panel._update_status()          # exactly what the 2s transient timer calls
	check("refusal: …and the refresh that clears the transient leaves the "
			+ "refusal where it is",
			str(panel._status_label.text).contains(expected)
				and not str(panel._status_label.text).contains("a passing message"),
			str(panel._status_label.text))

	# ── The badge wears the refusal, and it is the canvas's own colour ────────
	check("refusal: the badge's live pip takes the SPINE's refusal colour",
			P.bus_badge_pip_color("active", true) == canvas.BUS_REFUSAL_COLOR,
			str(P.bus_badge_pip_color("active", true)))
	var retinted := true
	for state in ["active", "done", "pending"]:
		var tinted: Color = P.bus_badge_pip_color(str(state), true)
		retinted = retinted and Color(tinted, 1.0) == canvas.BUS_REFUSAL_COLOR \
			and tinted != P.bus_badge_pip_color(str(state), false)
	check("refusal: EVERY pip is retinted, and none of the three keeps its "
			+ "ordinary phase colour", retinted)

	# ── It does not clear itself, and it clears when the state does ───────────
	canvas._handle_bus_click(BADGE_PATH_2, false)
	check("refusal: a later good vertex does not cure a fold already in the "
			+ "spine — the refusal stands and nothing new is announced",
			canvas.bus_refusal() == expected and announced == [true],
			"refusal=%s announced=%s" % [canvas.bus_refusal(), str(announced)])
	canvas._cancel_bus_step(false)
	check("refusal oracle (ladder): Esc peeled PATH, so the folded spine is gone",
			canvas._bus_spine_points.is_empty() and canvas._bus_nets.size() == 2,
			"spine=%d nets=%d" % [canvas._bus_spine_points.size(), canvas._bus_nets.size()])
	check("refusal: …and the refusal cleared with it, announced once as clear",
			canvas.bus_refusal() == "" and panel.bus_refusal_text() == ""
				and announced == [true, false], str(announced))
	check("refusal: the status line drops it too — nothing is held that no "
			+ "longer stands",
			not str(panel._status_label.text).contains(expected),
			str(panel._status_label.text))

	panel.queue_free()
	await process_frame


# ── Board-level undo/redo ─────────────────────────────────────────────────────
#
# ORACLE: the SERIALIZED BOARD (trace and via counts out of to_board_dict) and
# the model's own history_index either side of each key press, plus the
# rendered status label text — never the reply of the code under test. The
# step label the status must name is read off the history entry the bus commit
# recorded, BEFORE any undo runs, so the expectation owes nothing to the undo
# path. The hint case asserts the board did NOT move while a route hint was
# selected, which is the whole contract for that branch.

const UNDO_STATION := Vector2(35.0, 25.0)
const UNDO_TGT_B := Vector2(60.0, 14.0)
## Clear board, far from every pad and vertex: where the finishing double-click
## lands.
const UNDO_EMPTY := Vector2(40.0, 35.0)


func _ctrl_key(keycode: Key, shift: bool = false) -> InputEventKey:
	var ek := InputEventKey.new()
	ek.keycode = keycode
	ek.pressed = true
	ek.ctrl_pressed = true
	ek.shift_pressed = shift
	return ek


func _board_counts(panel: Variant) -> Array:
	var doc: Dictionary = panel.get_data().to_board_dict()
	return [(doc.get("traces", []) as Array).size(), (doc.get("vias", []) as Array).size()]


## Commit a two-net bus with a via station on the badge board: sources on the
## left, spine (25,25) -> (35,25) [station, bottom] -> (45,25), targets right.
func _commit_station_bus(panel: Variant, canvas: Variant) -> void:
	panel._toggle_tool_mode(canvas.ToolMode.BUS)
	await process_frame
	canvas._handle_bus_click(BADGE_SRC_A, false)
	canvas._handle_bus_click(BADGE_SRC_B, false)
	canvas._handle_bus_click(BADGE_PATH_1, false)
	canvas.working_layer = "bottom"
	canvas._handle_bus_click(UNDO_STATION, false)
	canvas._handle_bus_click(BADGE_PATH_2, false)
	canvas._handle_bus_click(BADGE_TGT_A, false)
	canvas._handle_bus_click(UNDO_TGT_B, false)
	canvas._handle_bus_click(UNDO_EMPTY, false)
	canvas._handle_bus_click(UNDO_EMPTY, true)
	await process_frame


func _test_board_undo_redo() -> void:
	print("\n-- Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y step the board history, and say so --")
	var panel: Variant = await _mount_panel_in_tree()
	var canvas: Variant = panel._canvas
	var data: Variant = panel.get_data()
	data.from_board_dict(_bus_badge_board())
	canvas.snap_to_grid = false
	await process_frame

	var history_before: int = data.history.size()
	await _commit_station_bus(panel, canvas)
	var landed: Array = _board_counts(panel)
	check("undo fixture: the station bus landed copper on both layers plus its vias",
			landed[0] == 4 and landed[1] == 2 and data.history.size() == history_before + 1,
			"traces=%d vias=%d history=%d" % [landed[0], landed[1], data.history.size()])
	if landed[0] != 4:
		panel.queue_free()
		return
	# The label the commit recorded — what every route must name.
	var step_label: String = str((data.history[data.history_index] as Dictionary).get("action", ""))
	check("undo fixture: the commit recorded a named step", not step_label.is_empty(), step_label)
	var index_after_commit: int = data.history_index

	# ── Ctrl+Z ────────────────────────────────────────────────────────────────
	panel._unhandled_key_input(_ctrl_key(KEY_Z))
	var after_undo: Array = _board_counts(panel)
	check("Ctrl+Z removes every trace and via of the bus step",
			after_undo[0] == 0 and after_undo[1] == 0 and data.history_index == index_after_commit - 1,
			"traces=%d vias=%d index=%d" % [after_undo[0], after_undo[1], data.history_index])
	check("...and the status line names the step it undid",
			str(panel._status_label.text).contains("Undid")
				and str(panel._status_label.text).contains(step_label),
			str(panel._status_label.text))

	# ── Ctrl+Shift+Z ──────────────────────────────────────────────────────────
	panel._unhandled_key_input(_ctrl_key(KEY_Z, true))
	var after_redo: Array = _board_counts(panel)
	check("Ctrl+Shift+Z restores the traces and vias",
			after_redo[0] == 4 and after_redo[1] == 2 and data.history_index == index_after_commit,
			"traces=%d vias=%d" % [after_redo[0], after_redo[1]])
	check("...and the status line names the step it redid",
			str(panel._status_label.text).contains("Redid")
				and str(panel._status_label.text).contains(step_label),
			str(panel._status_label.text))

	# ── Ctrl+Y is redo too ────────────────────────────────────────────────────
	panel._unhandled_key_input(_ctrl_key(KEY_Z))
	panel._unhandled_key_input(_ctrl_key(KEY_Y))
	var after_y: Array = _board_counts(panel)
	check("Ctrl+Y redoes exactly as Ctrl+Shift+Z does",
			after_y[0] == 4 and after_y[1] == 2 and data.history_index == index_after_commit,
			"traces=%d vias=%d" % [after_y[0], after_y[1]])

	# ── With a route hint selected the key is the HINT's ─────────────────────
	var host: Variant = panel._annotation_host
	var env: Dictionary = host.build_route_hint_envelope(
		0.0, 0.0, "", "F.Cu", "waypoint", [[5.0, 30.0], [15.0, 30.0]], "human")
	var hint_id: String = str(host.add_annotation_v2(env))
	host.set_selected_annotation_id(hint_id)
	check("hint fixture: one route hint is selected",
			host.get_selected_annotation_id() == hint_id
				and str(host.get_by_id(hint_id).get("kind", "")) == "pcb_route_hint")
	panel._unhandled_key_input(_ctrl_key(KEY_Z))
	var with_hint: Array = _board_counts(panel)
	check("with a route hint selected Ctrl+Z leaves the board history alone",
			with_hint[0] == 4 and with_hint[1] == 2 and data.history_index == index_after_commit,
			"traces=%d vias=%d index=%d" % [with_hint[0], with_hint[1], data.history_index])
	host.set_selected_annotation_id("")

	# ── The host hook pair and the verbs take the same path ──────────────────
	check("the host's undo hook reverts the step", panel._on_panel_undo_request()
			and _board_counts(panel)[0] == 0)
	check("the host's redo hook restores it", panel._on_panel_redo_request()
			and _board_counts(panel)[0] == 4)

	var undo_reply: Dictionary = await panel.handle_tool("minerva_pcb_undo", {})
	check("minerva_pcb_undo reverts the step and names it with the depths",
			bool(undo_reply.get("ok", false)) and str(undo_reply.get("action", "")) == step_label
				and int(undo_reply.get("undo_depth", -1)) == index_after_commit - 1
				and int(undo_reply.get("redo_depth", -1)) == 1
				and _board_counts(panel)[0] == 0,
			str(undo_reply))
	check("...and the status line names it, the same as the key did",
			str(panel._status_label.text).contains("Undid")
				and str(panel._status_label.text).contains(step_label),
			str(panel._status_label.text))
	var redo_reply: Dictionary = await panel.handle_tool("minerva_pcb_redo", {})
	check("minerva_pcb_redo restores the step",
			bool(redo_reply.get("ok", false)) and str(redo_reply.get("action", "")) == step_label
				and int(redo_reply.get("redo_depth", -1)) == 0 and _board_counts(panel)[0] == 4,
			str(redo_reply))
	var nothing: Dictionary = await panel.handle_tool("minerva_pcb_redo", {})
	check("minerva_pcb_redo refuses when nothing was undone",
			not bool(nothing.get("ok", true)) and str(nothing.get("error", "")).contains("nothing_to_redo"),
			str(nothing))
	# Walk the undo side to its floor: the load state is step 0 and never undone.
	var floor_reply: Dictionary = {}
	for _i in range(index_after_commit + 1):
		floor_reply = await panel.handle_tool("minerva_pcb_undo", {})
	check("minerva_pcb_undo refuses at the bottom of the history",
			not bool(floor_reply.get("ok", true)) and str(floor_reply.get("error", "")).contains("nothing_to_undo")
				and data.history_index == 0,
			str(floor_reply))
	panel.queue_free()
	await process_frame


# ── Selection-drag threshold ──────────────────────────────────────────────────
#
# ORACLE: the serialized trace list and history.size() either side of two real
# press/motion/release gestures on NA's lane, driven through the canvas's own
# _gui_input. A 2 px wobble must leave both untouched; a 20 px drag must change
# the points and record exactly one step.

## A point on NA's top-layer lane: NA rides the -0.255 lane (0.2mm tracks at
## 0.3mm clearance, laid pitch 0.51) of the spine at y = 25, between its source
## station and the station fan-out.
const DRAG_ON_LANE := Vector2(30.0, 24.745)


func _mouse_button(canvas: Variant, screen: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = screen
	canvas._gui_input(ev)


func _mouse_move(canvas: Variant, screen: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = screen
	canvas._gui_input(mm)


func _test_selection_drag_threshold() -> void:
	print("\n-- a press with a wobble moves no copper; a real drag still does --")
	var panel: Variant = await _mount_panel_in_tree()
	var canvas: Variant = panel._canvas
	var data: Variant = panel.get_data()
	data.from_board_dict(_bus_badge_board())
	canvas.snap_to_grid = false
	await process_frame
	await _commit_station_bus(panel, canvas)
	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	await process_frame

	var start: Vector2 = canvas.world_to_screen(DRAG_ON_LANE)
	var hit: Array = canvas._entity_at(DRAG_ON_LANE)
	check("drag fixture: the press point is on a trace", str(hit[0]) == canvas.KIND_TRACE, str(hit))
	var traces_before: Array = data.to_board_dict().get("traces", [])
	var history_before: int = data.history.size()

	# A click with a 2 px wobble in it.
	_mouse_button(canvas, start, true)
	check("the press arms a drag without moving anything",
			not canvas.is_dragging_selection and canvas._selection_drag_pending)
	_mouse_move(canvas, start + Vector2(2.0, 0.0))
	check("2 px of travel does not go live", not canvas.is_dragging_selection)
	_mouse_button(canvas, start + Vector2(2.0, 0.0), false)
	check("a wobbled click moves no copper and records no step",
			data.to_board_dict().get("traces", []) == traces_before
				and data.history.size() == history_before,
			"history %d -> %d" % [history_before, data.history.size()])

	# A real drag of the (now selected) trace.
	_mouse_button(canvas, start, true)
	_mouse_move(canvas, start + Vector2(20.0, 0.0))
	check("20 px of travel goes live", canvas.is_dragging_selection)
	_mouse_button(canvas, start + Vector2(20.0, 0.0), false)
	check("a real drag moves the trace and records exactly one step",
			data.to_board_dict().get("traces", []) != traces_before
				and data.history.size() == history_before + 1,
			"history %d -> %d" % [history_before, data.history.size()])
	panel.queue_free()
	await process_frame
