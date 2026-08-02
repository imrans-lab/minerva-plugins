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
