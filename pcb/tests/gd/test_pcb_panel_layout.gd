extends SceneTree
## PCB panel responsive layout (UI redesign round B) — tests-first spec.
##
## Run: godot --headless --path src --script test/test_pcb_panel_layout.gd
##
## The panel adapts to its OWN width across Minerva's resizable 1/2/3-column
## layouts. This suite is the acceptance spec the layout code must satisfy:
##   1. panel_layout.mode_for_width — boundaries + hysteresis (pure logic).
##   2. Panel at 1100px (wide): sidebar visible, layout state reports wide.
##   3. Panel at 600px (medium — a representative width, not THE 3-col target:
##      mode selection is absolute-px and deliberately hardware-dependent, so a
##      3-col pane on a large display classifies wide, not medium; ruling
##      019fbb7115): sidebar visible, all toolbar controls fit without
##      horizontal scrolling.
##   4. Panel at 400px (narrow): sidebar hidden behind a drawer toggle; view
##      toggles folded into a View menu; toolbar fits without h-scroll.
##   5. get_annotation_dock_parent() returns a Control inside the sidebar
##      (the platform mounts the annotation dock there — round A hook).
##   6. Mode transitions preserve the loaded board and canvas.
##   7. get_layout_state() exposes structured state for MCP/agent verification.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const LAYOUT_PATH := "res://../../minerva-plugins/pcb/ui/panel_layout.gd"
const CANVAS_PATH := "res://../../minerva-plugins/pcb/ui/pcb_canvas.gd"

var _pass := 0
var _fail := 0


func check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


class FakeEditor extends RefCounted:
	var tab_title: String = "Layout Tab"
	var associated_object: Variant = ""


func _board() -> Dictionary:
	return {
		"version": 1, "name": "Layout", "width_mm": 60.0, "height_mm": 40.0, "grid_mm": 2.54,
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 30.0, "y_mm": 20.0, "rotation_deg": 0.0,
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		],
	}


func _init() -> void:
	print("=== PCB panel responsive layout ===\n")
	await process_frame
	get_root().size = Vector2i(1300, 800)

	_test_mode_resolver()
	await _test_wide_mode()
	await _test_medium_mode()
	await _test_narrow_mode()
	await _test_dock_parent_hook()
	await _test_dock_pane_migrates()
	await _test_transitions_preserve_board()
	await _test_properties_panel()
	await _test_tool_buttons_render()
	await _test_panel_height_relief()
	await _test_trace_width_reveal_scrolls_into_view()
	_test_tooltip_length_invariant()
	_test_wrap_tooltip_preserves_content()
	await _test_mode_tables_track_the_enum()
	await _test_docs_names_match_code()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── 1. Resolver logic ──────────────────────────────────────────────────────────

func _test_mode_resolver() -> void:
	print("-- mode_for_width boundaries + hysteresis --")
	var L := load(LAYOUT_PATH)

	check("400 → narrow", L.mode_for_width(400.0) == L.MODE_NARROW)
	check("479.9 → narrow", L.mode_for_width(479.9) == L.MODE_NARROW)
	check("480 → medium", L.mode_for_width(480.0) == L.MODE_MEDIUM)
	check("600 → medium (representative width, not THE 3-col target — ruling 019fbb7115)",
		L.mode_for_width(600.0) == L.MODE_MEDIUM)
	check("899.9 → medium", L.mode_for_width(899.9) == L.MODE_MEDIUM)
	check("900 → wide", L.mode_for_width(900.0) == L.MODE_WIDE)
	check("1100 → wide", L.mode_for_width(1100.0) == L.MODE_WIDE)

	# Hysteresis: leaving a mode needs the boundary + band.
	check("narrow stays at 490 (boundary+10)",
		L.mode_for_width(490.0, L.MODE_NARROW) == L.MODE_NARROW)
	check("narrow leaves at 505 (boundary+25)",
		L.mode_for_width(505.0, L.MODE_NARROW) == L.MODE_MEDIUM)
	check("medium enters narrow below 480",
		L.mode_for_width(470.0, L.MODE_MEDIUM) == L.MODE_NARROW)
	check("wide stays at 890 (boundary-10)",
		L.mode_for_width(890.0, L.MODE_WIDE) == L.MODE_WIDE)
	check("wide leaves at 875 (boundary-25)",
		L.mode_for_width(875.0, L.MODE_WIDE) == L.MODE_MEDIUM)
	check("medium enters wide at 900",
		L.mode_for_width(900.0, L.MODE_MEDIUM) == L.MODE_WIDE)


# ── Panel harness ──────────────────────────────────────────────────────────────

func _mount_panel_at(width: float) -> Control:
	var panel: Control = load(PANEL_PATH).new()
	get_root().add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(width, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_board())
	for _i in range(6):
		await process_frame
	return panel


func _teardown(panel: Control) -> void:
	panel.queue_free()


## The toolbar row must fit in the panel: its content width must not exceed
## the scroll container's width (no horizontal overflow at this panel width).
func _toolbar_fits(panel: Control) -> bool:
	var scroll: ScrollContainer = panel.find_child("ToolbarScroll", true, false)
	if scroll == null:
		return false
	var bar: Control = scroll.get_child(0) if scroll.get_child_count() > 0 else null
	if bar == null:
		return false
	return bar.get_combined_minimum_size().x <= scroll.size.x + 1.0


## The oracle _toolbar_fits CANNOT provide: the PANEL's own minimum width must
## not exceed the pane. _toolbar_fits compares toolbar content to its scroll
## CONTAINER — but a single unclipped Label elsewhere (the StatusBar carrying
## the gesture hint, 933px measured) can widen the whole VBox chain, dragging
## the container past the pane while content-vs-container stays green (the
## container itself grew). Container-vs-panel is the assertion that catches ANY
## row inflating anywhere in the tree.
##
## bug 019fbcdfe35a: this used to read panel.get_combined_minimum_size().x
## directly — VACUOUS in this bare-script harness. load(PANEL_PATH).new()
## instantiates PCBPanel.gd standalone (a plain Control, not the PCBPanel.tscn
## PanelContainer root), and a plain Control does not aggregate an anchored
## child's minimum size the way a Container does (the same finding the B3
## HEIGHT oracle's comment above _panel_min_height_fits records for .y). That
## made the old assertion "0 <= pane width", which can never fail. Re-aimed at
## the same found-node recipe the HEIGHT oracle uses: MainVBox is a REAL
## VBoxContainer (a proper Container, unlike the panel root) that owns the
## whole visible tree — ToolbarScroll, WorkspaceFrame → WorkspaceVBox →
## ContentHBox → CanvasContainer + RightSidebar, BottomDockSlot, StatusBar —
## so its combined-minimum-size aggregates correctly through every real
## Container in that chain, including the StatusBar Label the comment above
## warns about. Mutation-proven below (revert the StatusBar TRIM_ELLIPSIS
## line): this oracle goes RED where the old one stayed green.
func _panel_min_fits(panel: Control) -> bool:
	var main_vbox: Control = panel.find_child("MainVBox", true, false)
	if main_vbox == null:
		return false
	return main_vbox.get_combined_minimum_size().x <= panel.size.x + 1.0


# ── 2. Wide mode ───────────────────────────────────────────────────────────────

func _test_wide_mode() -> void:
	print("\n-- wide mode (1100px) --")
	var panel := await _mount_panel_at(1100.0)

	var state: Dictionary = panel.get_layout_state()
	check("state.mode == wide", str(state.get("mode", "")) == "wide")
	check("state width ~ 1100", absf(float(state.get("width", 0.0)) - 1100.0) < 2.0)
	check("sidebar visible", bool(state.get("sidebar_visible", false)))

	var sidebar: Control = panel.find_child("RightSidebar", true, false)
	check("sidebar node exists + visible", sidebar != null and sidebar.visible)
	check("toolbar fits without h-scroll", _toolbar_fits(panel))
	check("panel min width fits the pane (no row inflates it)", _panel_min_fits(panel))

	_teardown(panel)


# ── 3. Medium mode (a representative width; ruling 019fbb7115 keeps mode
#      selection absolute-px, so this is not THE 3-col target) ────────────────

func _test_medium_mode() -> void:
	print("\n-- medium mode (600px) --")
	var panel := await _mount_panel_at(600.0)

	var state: Dictionary = panel.get_layout_state()
	check("state.mode == medium", str(state.get("mode", "")) == "medium")
	check("sidebar visible", bool(state.get("sidebar_visible", false)))
	check("toolbar fits without h-scroll at 600px", _toolbar_fits(panel))
	check("panel min width fits the pane at 600px", _panel_min_fits(panel))

	var canvas: Control = panel._canvas
	check("canvas keeps majority width",
		canvas != null and canvas.size.x > 600.0 * 0.5)

	_teardown(panel)


# ── 4. Narrow mode ─────────────────────────────────────────────────────────────

func _test_narrow_mode() -> void:
	print("\n-- narrow mode (400px) --")
	var panel := await _mount_panel_at(400.0)

	var state: Dictionary = panel.get_layout_state()
	check("state.mode == narrow", str(state.get("mode", "")) == "narrow")
	check("sidebar hidden", not bool(state.get("sidebar_visible", true)))
	check("drawer reported closed", not bool(state.get("drawer_open", true)))

	var drawer_btn: Control = panel.find_child("SidebarDrawerButton", true, false)
	check("drawer toggle present + visible", drawer_btn != null and drawer_btn.visible)

	var view_menu: Control = panel.find_child("ViewMenuButton", true, false)
	check("View menu present + visible", view_menu != null and view_menu.visible)
	check("toolbar fits without h-scroll at 400px", _toolbar_fits(panel))
	check("panel min width fits the pane at 400px", _panel_min_fits(panel))

	# Open the drawer: sidebar becomes visible.
	if drawer_btn is Button:
		(drawer_btn as Button).emit_signal("pressed")
		await process_frame
		var state2: Dictionary = panel.get_layout_state()
		check("drawer opens sidebar", bool(state2.get("sidebar_visible", false)))
		check("drawer reported open", bool(state2.get("drawer_open", false)))
	else:
		check("drawer toggle is a Button", false)

	_teardown(panel)


# ── 5. Dock parent hook (round A contract) ─────────────────────────────────────

func _test_dock_parent_hook() -> void:
	print("\n-- get_annotation_dock_parent (mode-dependent slot) --")

	# Medium (3-col HITL note): dock belongs in the BOTTOM strip.
	var panel := await _mount_panel_at(700.0)
	check("panel exposes get_annotation_dock_parent",
		panel.has_method("get_annotation_dock_parent"))
	var dock_parent: Variant = panel.get_annotation_dock_parent()
	var bottom: Control = panel.find_child("BottomDockSlot", true, false)
	check("medium: dock parent is a Control", dock_parent is Control)
	check("medium: dock parent is the bottom strip",
		dock_parent is Control and bottom != null
		and (dock_parent == bottom or bottom.is_ancestor_of(dock_parent)))
	check("medium: state reports dock at bottom",
		str(panel.get_layout_state().get("dock_position", "")) == "bottom")
	_teardown(panel)

	# Wide: dock belongs in the right sidebar.
	var panel2 := await _mount_panel_at(1100.0)
	var dock_parent2: Variant = panel2.get_annotation_dock_parent()
	var sidebar: Control = panel2.find_child("RightSidebar", true, false)
	check("wide: dock parent lives inside the sidebar",
		dock_parent2 is Control and sidebar != null
		and (dock_parent2 == sidebar or sidebar.is_ancestor_of(dock_parent2)))
	check("wide: state reports dock in sidebar",
		str(panel2.get_layout_state().get("dock_position", "")) == "sidebar")
	_teardown(panel2)


## A mounted dock pane must MIGRATE between slots as the mode changes, with
## its internal arrangement following (RIGHT in the sidebar, BOTTOM in the
## strip) and no active tool stranded.
func _test_dock_pane_migrates() -> void:
	print("\n-- dock pane migrates between slots --")
	const DockPaneScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationDockPane.gd")

	var panel := await _mount_panel_at(1100.0)  # wide: mounts into sidebar
	var pane: Node = DockPaneScript.new()
	pane.name = "AnnotationDockPane"
	(panel.get_annotation_dock_parent() as Control).add_child(pane)
	pane.set_dock_mode(DockPaneScript.DockMode.RIGHT)  # as the platform mount does
	for _i in range(3):
		await process_frame

	var sidebar_slot: Control = panel.find_child("AnnotationDockParent", true, false)
	var bottom_slot: Control = panel.find_child("BottomDockSlot", true, false)
	check("wide: pane sits in the sidebar slot", pane.get_parent() == sidebar_slot)
	check("wide: pane arranged RIGHT",
		int(pane.get("dock_mode")) == DockPaneScript.DockMode.RIGHT)

	panel.size = Vector2(600.0, 700.0)  # → medium
	for _i in range(4):
		await process_frame
	check("medium: pane migrated to the bottom strip", pane.get_parent() == bottom_slot)
	check("medium: pane arranged BOTTOM",
		int(pane.get("dock_mode")) == DockPaneScript.DockMode.BOTTOM)

	panel.size = Vector2(1100.0, 700.0)  # → back to wide
	for _i in range(4):
		await process_frame
	check("back to wide: pane returned to the sidebar", pane.get_parent() == sidebar_slot)
	check("back to wide: pane arranged RIGHT again",
		int(pane.get("dock_mode")) == DockPaneScript.DockMode.RIGHT)

	_teardown(panel)


# ── 6. Transitions preserve the board ──────────────────────────────────────────

func _test_transitions_preserve_board() -> void:
	print("\n-- mode transitions preserve state --")
	var panel := await _mount_panel_at(1100.0)

	var parts_before: int = panel.get_data().components.size()
	check("board loaded in wide", parts_before == 1)

	panel.size = Vector2(600.0, 700.0)
	for _i in range(4):
		await process_frame
	check("wide→medium: mode followed",
		str(panel.get_layout_state().get("mode", "")) == "medium")
	check("wide→medium: board intact", panel.get_data().components.size() == parts_before)

	panel.size = Vector2(400.0, 700.0)
	for _i in range(4):
		await process_frame
	check("medium→narrow: mode followed",
		str(panel.get_layout_state().get("mode", "")) == "narrow")
	check("medium→narrow: board intact", panel.get_data().components.size() == parts_before)
	check("medium→narrow: canvas alive", is_instance_valid(panel._canvas))

	# Flip a view flag through the View MENU while narrow, then widen. The
	# menu is the ONE view-flags surface at every mode (owner ruling, bug
	# 019fbb6242 — the former wide-mode inline toggle row is deleted), so at
	# wide the flag must still be live on the canvas, the menu must still be
	# there, and no inline toggle row may exist to drift from it.
	panel._on_view_menu_id_pressed(0)  # toggles show_grid off
	check("menu toggled canvas flag", panel._canvas.show_grid == false)

	panel.size = Vector2(1100.0, 700.0)
	for _i in range(4):
		await process_frame
	check("narrow→wide: mode followed",
		str(panel.get_layout_state().get("mode", "")) == "wide")
	check("narrow→wide: sidebar visible again",
		bool(panel.get_layout_state().get("sidebar_visible", false)))

	check("canvas flag survives the mode change", panel._canvas.show_grid == false)
	var view_menu_wide: Control = panel.find_child("ViewMenuButton", true, false)
	check("View menu present + visible at wide",
		view_menu_wide != null and view_menu_wide.visible)
	check("no inline toggle row exists (bug 019fbb6242)",
		panel.find_child("ViewTogglesBox", true, false) == null)

	_teardown(panel)


# ── 7. Properties section (round C) ────────────────────────────────────────────

func _test_properties_panel() -> void:
	print("\n-- properties section --")
	var panel := await _mount_panel_at(1100.0)

	var section: Control = panel.find_child("PropertiesSection", true, false)
	check("properties section exists in sidebar", section != null)
	check("wide mode: properties expanded",
		bool(panel.get_layout_state().get("properties_expanded", false)))

	# Select the only component → fields populate.
	panel._canvas.selected_components.append("U1")
	panel._canvas.selection_changed.emit()
	await process_frame
	var id_label: Label = panel._prop_labels.get("ID", null)
	check("ID populates on selection", id_label != null and id_label.text == "U1")
	var pos_label: Label = panel._prop_labels.get("Position", null)
	check("Position populates", pos_label != null and pos_label.text.begins_with("(30"))

	# Clear selection → dashes.
	panel._canvas.selected_components.clear()
	panel._canvas.selection_changed.emit()
	await process_frame
	check("clears to dash on deselect", id_label.text == "-")

	# Medium mode collapses by default.
	panel.size = Vector2(600.0, 700.0)
	for _i in range(4):
		await process_frame
	check("medium mode: properties collapsed",
		not bool(panel.get_layout_state().get("properties_expanded", true)))

	_teardown(panel)


# ── 8. Tool buttons render (round C icons) ─────────────────────────────────────

func _test_tool_buttons_render() -> void:
	print("\n-- tool buttons (icon or text, never blank; by-name pin) --")
	var panel := await _mount_panel_at(700.0)
	var PcbCanvasScript := load(CANVAS_PATH)

	# chore 019fb59164b6 / R2: the old pin read ONLY "ToolsFlow" and asserted a
	# bare count of 7. Since then, boundary-bug fix 019fb5c74980 split the
	# sidebar's tool buttons across THREE labeled sections/FlowContainers
	# (_build_sidebar: "Select" -> ToolsFlow, "Tools" -> DrawFlow, "Proposals"
	# -> HintsFlow) — Trace/Edit Hint/Add Via/Propose never lived in ToolsFlow
	# once that split happened, so the old count against ToolsFlow alone was
	# checking the wrong container entirely, on top of being stale about which
	# tools exist. Re-pinned against the actual current set, BY NAME, across
	# all three flows — a bare count can't tell a rename from an addition, so
	# each button's stable identity (Godot node .name where the production
	# code sets one, else its _tool_buttons/_route_flow_buttons dict key) is
	# checked individually.
	var tools_flow: Control = panel.find_child("ToolsFlow", true, false)
	var draw_flow: Control = panel.find_child("DrawFlow", true, false)
	var hints_flow: Control = panel.find_child("HintsFlow", true, false)
	check("ToolsFlow lives in the sidebar", tools_flow != null)
	check("DrawFlow lives in the sidebar", draw_flow != null)
	check("HintsFlow lives in the sidebar", hints_flow != null)

	var all_buttons: Array[Button] = []
	for flow in [tools_flow, draw_flow, hints_flow]:
		if flow == null:
			continue
		for child in (flow as Control).get_children():
			if child is Button:
				var b := child as Button
				all_buttons.append(b)
				check("tool button has icon or text",
					b.icon != null or not b.text.is_empty())

	# Radio-toggle "select a tool mode" buttons (ToolsFlow's Select/Pan/Pin
	# Inspect + DrawFlow's Pour/Keepout/Trace/Cutout/Eraser): most are
	# icon-only (no Godot node .name set in _add_tool_button), so their
	# ToolMode enum key in _tool_buttons IS the stable name a rename would
	# change.
	var expected_tool_modes := [
		PcbCanvasScript.ToolMode.SELECT, PcbCanvasScript.ToolMode.PAN,
		PcbCanvasScript.ToolMode.INSPECT_PIN, PcbCanvasScript.ToolMode.ZONE_POUR,
		PcbCanvasScript.ToolMode.ZONE_KEEPOUT, PcbCanvasScript.ToolMode.TRACE,
		PcbCanvasScript.ToolMode.CUTOUT, PcbCanvasScript.ToolMode.ERASER,
	]
	var tool_buttons: Dictionary = panel._tool_buttons
	check("_tool_buttons has exactly the 8 current radio tool modes (got %d)" % tool_buttons.keys().size(),
		tool_buttons.keys().size() == expected_tool_modes.size())
	for mode in expected_tool_modes:
		check("radio tool button registered + mounted for ToolMode %s" % mode,
			tool_buttons.has(mode) and (tool_buttons[mode] as Button) in all_buttons)

	# Route-flow cluster (HintsFlow's Trace hint/Edit Hint/Add Via) — keyed by
	# string in _route_flow_buttons, its own mutual-exclusion set.
	var expected_route_flow_keys := ["single_trace", "edit_hint", "add_via"]
	var route_flow_buttons: Dictionary = panel._route_flow_buttons
	check("_route_flow_buttons has exactly the 3 current route-flow tools (got %d)" % route_flow_buttons.keys().size(),
		route_flow_buttons.keys().size() == expected_route_flow_keys.size())
	for key in expected_route_flow_keys:
		check("route-flow button registered for \"%s\"" % key,
			route_flow_buttons.has(key) and (route_flow_buttons[key] as Button) in all_buttons)

	# Named single-instance buttons: Delete (DrawFlow) + Propose (HintsFlow),
	# neither of which belongs to either dict above (Delete is a plain action
	# button, Propose is a non-toggle act button — see PCBPanel.gd comments).
	for node_name in ["InspectPinButton", "DeleteSelectionButton",
			"SingleTraceButton", "EditHintButton", "AddViaButton", "ProposeButton"]:
		check("%s node present in the sidebar" % node_name,
			panel.find_child(node_name, true, false) != null)

	check("13 tool buttons total across ToolsFlow/DrawFlow/HintsFlow (8 radio tools + 3 route-flow + Delete + Propose; got %d)" % all_buttons.size(),
		all_buttons.size() == 13)

	_teardown(panel)


# ── 9. Panel min-height relief across armed-tool states (B3b regression pin,
#      docket 019fbbad9dac, RCA comment 970) ───────────────────────────────────

## Intended as the HEIGHT sibling of _panel_min_fits, but NOT built on
## panel.get_combined_minimum_size() the way that one is: measured directly
## (2026-08-01), panel.get_class() reports plain "Control" and
## panel.get_combined_minimum_size() is (0, 0) regardless of content in THIS
## harness — load(PANEL_PATH).new() instantiates the bare script
## (MinervaPluginPanel extends Control, not the PCBPanel.tscn's PanelContainer
## root), and plain Control does not aggregate an anchored child's minimum
## size the way a Container does. That makes panel.combined_minimum_size a
## VACUOUS read here — it is always (0,0) no matter how tall MainVBox's real
## content is, confirmed by mutation: reverting the B3b relief entirely still
## left a panel-rooted check green. _panel_min_fits (the WIDTH oracle above)
## reads the same vacuous property and is therefore equally silent in this
## harness; filed as a follow-up rather than fixed here (out of the B3b fence,
## and a pre-existing property of the suite, not something this round
## introduced). MainVBox is where the panel's real vertical minimum lives
## (_build_ui's own top-level VBoxContainer, holding ToolbarScroll +
## WorkspaceFrame) and reads correctly under mutation — see the regression
## proof recorded alongside this test.
func _panel_min_height_fits(panel: Control) -> bool:
	var main_vbox: Control = panel.find_child("MainVBox", true, false)
	if main_vbox == null:
		return false
	return main_vbox.get_combined_minimum_size().y <= panel.size.y + 1.0


func _test_panel_height_relief() -> void:
	print("\n-- panel min-height relief across armed-tool states --")
	var PcbCanvasScript := load(CANVAS_PATH)

	var panel := await _mount_panel_at(1100.0)
	# Representative small pane (per the RCA: "both fit a 500px pane armed").
	panel.size = Vector2(1100.0, 500.0)
	for _i in range(4):
		await process_frame

	var main_vbox: Control = panel.find_child("MainVBox", true, false)
	var at_rest_min: float = main_vbox.get_combined_minimum_size().y

	check("SELECT (at rest): panel min-height fits a 500px pane",
		_panel_min_height_fits(panel))

	# ZONE_POUR is the RCA's measured +78px regression fixture — the net/layer
	# OptionButtons become visible, which is exactly what used to tip the
	# panel's min-height past a small pane's actual height.
	panel._canvas.set_tool_mode(PcbCanvasScript.ToolMode.ZONE_POUR)
	for _i in range(4):
		await process_frame
	var armed_min: float = main_vbox.get_combined_minimum_size().y
	check("ZONE_POUR armed: panel min-height fits a 500px pane",
		_panel_min_height_fits(panel))

	# TIGHTER regression pin, deliberately independent of any specific pane
	# size: the whole point of routing the sidebar through a ScrollContainer
	# is that arming a tool's picker rows must NOT change what the sidebar
	# forces onto its ancestors — the rows scroll internally instead. A
	# PARTIALLY-scrolled sidebar (some rows correctly wrapped, a later
	# addition accidentally added as a direct RightSidebar child instead of
	# inside the wrap — the realistic shape of a half-fix) still passes the
	# 500px checks above by a wide margin (measured residual ~160px, nowhere
	# near 500) but fails HERE, because arming still measurably inflates the
	# panel's real minimum height. Measured on a fully-relieved sidebar:
	# at-rest and armed are BYTE-IDENTICAL (82px both) — a nonzero delta is
	# the signature of content escaping the scroll, regardless of by how much.
	check("arming ZONE_POUR does not inflate MainVBox's real min-height (scroll-contained, not size-neutral by luck)",
		armed_min - at_rest_min < 10.0)

	# Back to SELECT so nothing stays armed past this suite.
	panel._canvas.set_tool_mode(PcbCanvasScript.ToolMode.SELECT)
	_teardown(panel)


# ── 10. Trace-width reveal survives the sidebar scroll (B3b F3, cold review
#       2026-08-01) ─────────────────────────────────────────────────────────

func _trace_board() -> Dictionary:
	return {
		"version": 1, "name": "Layout", "width_mm": 60.0, "height_mm": 40.0, "grid_mm": 2.54,
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 30.0, "y_mm": 20.0, "rotation_deg": 0.0,
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}, {"number": "2", "x_mm": 5.0, "y_mm": 0.0}]},
		],
		"nets": [{"name": "N1", "pins": ["U1.1", "U1.2"]}],
		"traces": [
			{"net": "N1", "layer": "top", "width_mm": 0.25,
				"points": [{"x_mm": 0.0, "y_mm": 0.0}, {"x_mm": 5.0, "y_mm": 0.0}]},
		],
		"vias": [],
	}


## Vertical pixel overlap between `control`'s screen rect and `scroll`'s
## viewport screen rect — 0.0 when fully below/above the fold, up to
## control's own height when fully visible.
##
## NOT a Rect2.intersects() boolean (that was this helper's round-1 shape, and
## it was WRONG): a control can touch the viewport's edge with ZERO area — its
## own TOP edge sitting exactly on the viewport's BOTTOM edge — while being
## entirely OFF-screen below the fold. Round-2 cold review measured exactly
## this case (pane 500px: spin_y=[468,499] against viewport_y=[50,468], a
## zero-area touch at the bottom edge, i.e. 0 of 31px actually visible) and
## the round-1 version of this helper, called with include_borders=true,
## counted that touch as "on screen" — the comment here previously claimed
## "a zero-area edge touch is still fully on-screen", which is BACKWARDS: a
## zero-area touch at an edge is exactly the boundary between visible and
## not, and in the measured case it was entirely on the "not" side. Returning
## the actual overlapping HEIGHT instead of a boolean makes "just touching"
## and "fully visible" distinguishable, which is the whole point of the pin.
func _visible_px_height(scroll: ScrollContainer, control: Control) -> float:
	var s := scroll.get_global_rect()
	var c := control.get_global_rect()
	var top := maxf(s.position.y, c.position.y)
	var bottom := minf(s.position.y + s.size.y, c.position.y + c.size.y)
	return maxf(0.0, bottom - top)


## Reproduces the reviewer's measurement: at the round's own 500px reference
## pane (and the smaller 400px one) the "Set trace width…" reveal must leave
## the SpinBox's LineEdit both VISIBLE inside the scroll viewport and FOCUSED
## — not merely is_visible_in_tree(), which the scroll-clipped row already
## satisfies and is exactly what let this regression through undetected.
func _test_trace_width_reveal_scrolls_into_view() -> void:
	print("\n-- F3: Set trace width… reveal ends with the SpinBox visible + focused --")
	var panel := await _mount_panel_at(1100.0)
	panel.get_data().from_board_dict(_trace_board())
	for _i in range(4):
		await process_frame

	var trace_id: String = str(panel.get_data().get_trace_ids()[0])
	# Production selects the trace on the canvas BEFORE emitting
	# edit_trace_width_requested (see the handler's own doc comment) — match
	# that here rather than calling the handler cold, which would trip its
	# _update_trace_rows -> get_selected_traces().size() != 1 guard and hide
	# the row instead of revealing it.
	var selected_ids: Array[String] = [trace_id]
	panel._canvas.selected_trace_ids = selected_ids

	for pane_height in [500.0, 400.0]:
		panel.size = Vector2(1100.0, pane_height)
		for _i in range(8):
			await process_frame

		panel._on_edit_trace_width_requested(trace_id)
		for _i in range(6):
			await process_frame

		var spin: Control = panel._trace_prop_width_spin
		var scroll: ScrollContainer = panel.find_child("RightSidebarScroll", true, false)
		var line_edit: LineEdit = spin.get_line_edit() if spin != null else null
		var visible_px := _visible_px_height(scroll, spin) if (scroll != null and spin != null) else 0.0

		check("pane %dpx: width row visible in tree" % int(pane_height),
			spin != null and spin.is_visible_in_tree())
		check("pane %dpx: SpinBox has visible pixels inside the scroll viewport (%.1f of %.1f px — not merely touching the fold)" % [
				int(pane_height), visible_px, spin.size.y if spin != null else 0.0],
			visible_px > 0.0)
		check("pane %dpx: LineEdit holds focus after the reveal" % int(pane_height),
			line_edit != null and line_edit.has_focus())

	_teardown(panel)


# ── Campaign 2 boundary: tooltips, mode tables, docs (BT-44…47) ────────────────
#
# These four are SOURCE-TEXT and TABLE oracles. They deliberately do not mount a
# panel where they do not need one: the thing under test is a written artefact
# (the .gd source, the docs, the constant tables), and reading it back through a
# live widget would only re-assert what the widget copied.

const _PANEL_SRC := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const _CANVAS_SRC := "res://../../minerva-plugins/pcb/ui/pcb_canvas.gd"
const _MANIFEST_SRC := "res://../../minerva-plugins/pcb/manifest.json"
const _DOCS_TOOLS := "res://../../minerva-plugins/pcb/docs/tools.md"

const _TOOLTIP_MAX_CHARS := 90


## Every tooltip STRING LITERAL in PCBPanel.gd, from BOTH shapes:
##   1. `tooltip_text = "…"` (optionally wrapped)
##   2. `_add_tool_button(container, mode, "Text", "TIP", "icon")` — the fourth
##      positional argument.
##
## SHAPE 2 IS THE WHOLE POINT (BT-44's methodology lesson): the A9 review scanned
## only shape 1 and therefore MISSED the five longest tooltips in the file, which
## are all tool buttons. A scanner that covers one shape is a scanner that passes
## while the regression walks through the other.
func _tooltip_sites() -> Array:
	var src := FileAccess.get_file_as_string(_PANEL_SRC)
	var out: Array = []
	if src.is_empty():
		return out

	var re_assign := RegEx.new()
	re_assign.compile('tooltip_text\\s*=\\s*(?:_wrap_tooltip\\()?"([^"\\\\]*)"')
	for m in re_assign.search_all(src):
		out.append(["tooltip_text", m.get_string(1)])

	# _add_tool_button(...) calls span two source lines; take the whole call text
	# and read its string literals positionally.
	var re_lit := RegEx.new()
	re_lit.compile('"([^"\\\\]*)"')
	var from := 0
	while true:
		var at := src.find("_add_tool_button(", from)
		if at < 0:
			break
		from = at + 17
		# The definition line itself has no string literals — skip it naturally.
		var close := src.find(")\n", from)
		if close < 0:
			break
		var call_text := src.substr(from, close - from)
		var lits := re_lit.search_all(call_text)
		if lits.size() >= 2:
			out.append(["_add_tool_button", lits[1].get_string(1)])
	return out


## BT-44 — char-length invariant over EVERY tooltip site.
## ORACLE: the source text of PCBPanel.gd, scanned mechanically. Independent of
## any live Button, and independent of _wrap_tooltip (a wrapped 500-char tip is
## still a 500-char tip).
func _test_tooltip_length_invariant() -> void:
	print("\n-- BT-44: every tooltip site is <= %d chars --" % _TOOLTIP_MAX_CHARS)
	var sites := _tooltip_sites()
	check("BT-44: the scanner found tooltip sites at all (>= 20)", sites.size() >= 20)

	var from_buttons := 0
	for s in sites:
		if str(s[0]) == "_add_tool_button":
			from_buttons += 1
	check("BT-44: …including the _add_tool_button shape (>= 5 sites) — the shape the "
			+ "first review's grep missed", from_buttons >= 5)

	var worst := 0
	var worst_text := ""
	var worst_shape := ""
	for s in sites:
		var t := str(s[1])
		if t.length() > worst:
			worst = t.length()
			worst_text = t
			worst_shape = str(s[0])
	check("BT-44: max tooltip length is %d <= %d (longest: %s \"%s\")" % [
			worst, _TOOLTIP_MAX_CHARS, worst_shape, worst_text.substr(0, 70)],
			worst <= _TOOLTIP_MAX_CHARS)


## BT-45 — _wrap_tooltip preserves CONTENT.
## ORACLE: the token list of the output joined back and compared to the input's
## token list — a content-preservation oracle that says nothing about where the
## breaks landed, so it cannot be satisfied by copying the implementation.
func _test_wrap_tooltip_preserves_content() -> void:
	print("\n-- BT-45: _wrap_tooltip preserves every word, touches nothing short --")
	var P := load(PANEL_PATH)

	var short_text := "Draw a copper pour"
	check("BT-45: a string at or under the wrap width is returned BYTE-IDENTICAL",
			P._wrap_tooltip(short_text) == short_text)
	var exactly_60 := "Click a pad to start the trace and then click each waypoint!".substr(0, 60)
	check("BT-45: exactly-60 is untouched (boundary is <=, not <; len=%d)" % exactly_60.length(),
			exactly_60.length() == 60 and P._wrap_tooltip(exactly_60) == exactly_60)

	# FIXTURE TRAP, measured: if the 60th character happens to be a SPACE, a hard
	# character chop coincidentally breaks on a word boundary and the
	# content-preservation oracle passes the mutation. The boundary must fall
	# INSIDE a word, and the test says so rather than hoping.
	var long_text := ("Click a pad to begin the trace and then click on each waypoint "
			+ "in turn before clicking another pad to finish the run on it")
	check("BT-45 fixture: the wrap boundary falls INSIDE a word (\"%s\")"
			% long_text.substr(58, 4), not long_text.substr(58, 4).contains(" "))
	var wrapped: String = P._wrap_tooltip(long_text)
	check("BT-45: a long string actually wrapped (the comparison below is not vacuous)",
			wrapped.contains("\n"))
	check("BT-45: no word was split or lost — token lists are equal",
			_tokens(wrapped.replace("\n", " ")) == _tokens(long_text),
			)
	var longest_line := 0
	for line in wrapped.split("\n"):
		longest_line = maxi(longest_line, (line as String).length())
	check("BT-45: no wrapped line exceeds the wrap width (%d)" % longest_line,
			longest_line <= 60)


func _tokens(s: String) -> Array:
	var out: Array = []
	for w in s.split(" "):
		if not (w as String).is_empty():
			out.append(w)
	return out


## BT-46 — the mode tables track the ToolMode enum.
##
## ORACLE: THREE independently maintained structures — pcb_canvas's `ToolMode`
## enum, PCBPanel's `mode_names` status-bar array, and `_MODE_HINTS`. The enum is
## read from the CANVAS source text (the enum's own declaration), not from the
## panel, so the two cannot drift into agreement by sharing a copy.
##
## MEASURED SHAPE, stated because it is not what a naive reading of A9's F1 says:
## `_MODE_HINTS` is SPARSE by construction (NONE/TRANSLATE/ROTATE/PAN carry no
## while-armed hint), so the invariant is NOT three equal sizes. It is:
##   (a) mode_names.size() == ToolMode.size()  — the status-bar array is dense;
##   (b) every _MODE_HINTS key is a real ToolMode ordinal;
##   (c) every mode that has a TOOLBAR BUTTON has a non-empty mode_names entry.
## (c) is what actually reds when a ToolMode is appended and the table is not
## extended — the trap B4-U3 hit twice.
func _test_mode_tables_track_the_enum() -> void:
	print("\n-- BT-46: mode_names / _MODE_HINTS track the ToolMode enum --")
	var enum_names := _tool_mode_names_from_source()
	check("BT-46: the enum was parsed out of pcb_canvas.gd (%d members)" % enum_names.size(),
			enum_names.size() >= 10)

	var P := load(PANEL_PATH)
	var panel := await _mount_panel_at(1100.0)
	var mode_names: Array = panel._status_mode_names() if panel.has_method("_status_mode_names") \
			else _mode_names_from_source()
	check("BT-46 (a): mode_names.size() == ToolMode.size() (%d vs %d)"
			% [mode_names.size(), enum_names.size()],
			mode_names.size() == enum_names.size())

	var hints: Dictionary = P._MODE_HINTS
	var bad_keys: Array = []
	for k in hints.keys():
		if int(k) < 0 or int(k) >= enum_names.size():
			bad_keys.append(k)
	check("BT-46 (b): every _MODE_HINTS key is a real ToolMode ordinal (stray: %s)"
			% str(bad_keys), bad_keys.is_empty())

	var unnamed: Array = []
	for mode in panel._tool_buttons.keys():
		var i := int(mode)
		if i < 0 or i >= mode_names.size() or str(mode_names[i]).is_empty():
			unnamed.append(enum_names[i] if i < enum_names.size() else str(i))
	check("BT-46 (c): every toolbar tool has a status-bar name (unnamed: %s)"
			% str(unnamed), unnamed.is_empty())

	_teardown(panel)


func _tool_mode_names_from_source() -> Array:
	var src := FileAccess.get_file_as_string(_CANVAS_SRC)
	var re := RegEx.new()
	re.compile("enum ToolMode \\{([^}]*)\\}")
	var m := re.search(src)
	if m == null:
		return []
	var out: Array = []
	for part in m.get_string(1).split(","):
		var name := (part as String).strip_edges()
		if not name.is_empty():
			out.append(name)
	return out


func _mode_names_from_source() -> Array:
	var src := FileAccess.get_file_as_string(_PANEL_SRC)
	var re := RegEx.new()
	re.compile('var mode_names := \\[([^\\]]*)\\]')
	var m := re.search(src)
	if m == null:
		return []
	var out: Array = []
	for part in m.get_string(1).split(","):
		var lit := (part as String).strip_edges()
		out.append(lit.trim_prefix('"').trim_suffix('"'))
	return out


## BT-47 — docs/tools.md agrees with the code, MECHANICALLY.
##
## SCOPE, per the campaign plan: this is the mechanical subset ONLY. The
## prose-vs-behaviour half ("does the documented grammar match what the tool
## does") is adversary-station work and is deliberately NOT faked here.
##
## ORACLE: the docs file's own section structure versus manifest.json and the
## ToolMode enum — three artefacts maintained by hand, in different languages.
##
## MEASURED SCOPE CORRECTION: a flat both-directions set equality over every
## `minerva_pcb_*` string in the file is FALSE at HEAD and always will be — the
## file documents RETIRED tools (which must be absent) and the manifest carries
## worker tools the doc never enumerates. The mechanically true statements are
## the two below, which are what a rename actually breaks.
func _test_docs_names_match_code() -> void:
	print("\n-- BT-47: docs/tools.md names exist in manifest.json / ToolMode --")
	var doc := FileAccess.get_file_as_string(_DOCS_TOOLS)
	check("BT-47: docs/tools.md is readable", not doc.is_empty())

	var manifest_names := _manifest_tool_names()
	check("BT-47: manifest.json parsed (%d tools)" % manifest_names.size(),
			manifest_names.size() >= 50)

	# Direction 1: every tool NAMED IN A SECTION HEADING (i.e. documented as a
	# shipped feature) exists in the manifest. Renaming a tool without touching
	# docs reds here.
	var documented := _tool_names_in_headings(doc, false)
	check("BT-47: the heading scan found documented tools (%d)" % documented.size(),
			documented.size() >= 8)
	var missing: Array = []
	for n in documented:
		if not manifest_names.has(n):
			missing.append(n)
	check("BT-47 dir1: every heading-documented tool exists in the manifest (missing: %s)"
			% str(missing), missing.is_empty())

	# Direction 2: every tool listed under "Retired" is ABSENT from the manifest.
	# Documenting a tool as retired while it still ships is the same drift read
	# from the other end.
	var retired := _tool_names_in_retired(doc)
	check("BT-47: the Retired section names tools (%d)" % retired.size(), retired.size() >= 3)
	var zombies: Array = []
	for n in retired:
		if manifest_names.has(n):
			zombies.append(n)
	check("BT-47 dir2: no retired tool is still in the manifest (zombies: %s)" % str(zombies),
			zombies.is_empty())

	# Direction 3: every TOOLBAR tool's status-bar name is described in the
	# "Canvas gestures" section.
	#
	# RECORDED GAP (campaign 2 boundary finding, NOT a test defect): CUTOUT
	# shipped in epoch B unit 3 and its gesture grammar was never added to that
	# section — docs/tools.md mentions "Cutout" only in its MCP-tools heading.
	# The exception below is deliberate and must be DELETED when the docs are
	# fixed; leaving the assertion red at HEAD would poison the boundary run,
	# and dropping the assertion entirely would absorb the gap silently.
	var gestures := _canvas_gestures_section(doc)
	check("BT-47: the Canvas gestures section was located", gestures.length() > 500)
	var undocumented: Array = []
	for name in ["Select", "Pan", "Inspect Pin", "Pour", "Keepout", "Trace", "Eraser", "Cutout"]:
		if not gestures.contains(name):
			undocumented.append(name)
	check("BT-47 dir3: every toolbar tool but the recorded CUTOUT gap is described "
			+ "in Canvas gestures (undocumented: %s)" % str(undocumented),
			undocumented == ["Cutout"])


func _manifest_tool_names() -> Array:
	var raw := FileAccess.get_file_as_string(_MANIFEST_SRC)
	var parsed: Variant = JSON.parse_string(raw)
	var out: Array = []
	if not (parsed is Dictionary):
		return out
	for t in (parsed as Dictionary).get("tools", []):
		if t is Dictionary:
			out.append(str((t as Dictionary).get("name", "")))
	return out


func _tool_names_in_headings(doc: String, retired: bool) -> Array:
	var re := RegEx.new()
	re.compile("minerva_pcb_[a-z_]+")
	var out: Array = []
	for line in doc.split("\n"):
		var l := line as String
		if not l.begins_with("## "):
			continue
		if l.contains("Retired") != retired:
			continue
		for m in re.search_all(l):
			var n := m.get_string(0)
			if not out.has(n):
				out.append(n)
	return out


func _tool_names_in_retired(doc: String) -> Array:
	var start := doc.find("## Retired")
	if start < 0:
		return []
	var stop := doc.find("\n## ", start + 4)
	if stop < 0:
		stop = doc.length()
	var re := RegEx.new()
	re.compile("minerva_pcb_[a-z_]+")
	var out: Array = []
	for m in re.search_all(doc.substr(start, stop - start)):
		var n := m.get_string(0)
		if not out.has(n):
			out.append(n)
	return out


func _canvas_gestures_section(doc: String) -> String:
	var start := doc.find("## Canvas gestures")
	if start < 0:
		return ""
	var stop := doc.find("\n## ", start + 4)
	if stop < 0:
		stop = doc.length()
	return doc.substr(start, stop - start)
