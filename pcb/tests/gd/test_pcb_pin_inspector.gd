extends SceneTree
## PCB pin inspector E2E-1 (WC-1, docket 019f6a8918fe).
##
## Run: godot --headless --path . --script test/test_pcb_pin_inspector.gd
## (run from the Minerva worktree's src/ directory)
##
## Boots the REAL PCBPanel + PcbAnnotationHost headless (real Window viewport,
## real canvas, real toolbar), builds a 3-component/2-net fixture board directly
## against the live pcb_data model (one geometry-named pin, one unconnected
## pin), and drives the INSPECT_PIN mode with REAL synthetic input
## (Viewport.push_input — mouse clicks + a Shift+P key event), exactly like
## test_pcb_canvas_input_probe.gd. MCP parity (minerva_pcb_pin_info) is
## dispatched through the REAL PluginToolRegistry.handle_tool_call path
## (executor "panel", DCR 019f6c3d0e3d C2 round) against the registered panel
## — headless, no subprocess required for panel-executed tools.
##
## REUSE SCAN (see work-cycle report): mount pattern copied from
## test_pcb_canvas_input_probe.gd's _mount_panel/_push_button/_push_motion.
## C2 migration (docket 019f6c45f09e): minerva_pcb_pin_info moved to the pcb
## plugin's own panel_tools.gd (executor "panel") — MCP parity now dispatches
## through the REAL PluginToolRegistry.handle_tool_call path (a registered
## PCBPanel via PluginScenePanelBroker), mirroring test_panel_executed_tools.gd's
## fixture wiring, instead of calling the old core module's handle() directly.
## No hit-test logic is reimplemented here — every assertion reads live UI
## state or calls through the real dispatcher.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")
const HoverCard := preload("res://../../minerva-plugins/pcb/ui/pcb_hover_card.gd")

const EDITOR_NAME := "PinInspectorProbe"
const PCB_PLUGIN_ID := "pcb"

var _pass := 0
var _fail := 0

var panel = null
var canvas = null
var host = null
var data = null
var registry: PluginToolRegistry = null

## Captured via canvas.pin_selected — the last emitted info Dictionary.
var _last_pin_selected: Dictionary = {"__unset__": true}


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB Pin Inspector E2E-1 ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	_test_pad_at_units()
	await _test_e2e_1_scenario()

	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture ─────────────────────────────────────────────────────────

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

	# PCBPanel's own zoom-to-fit is a ONE-SHOT deferred to the canvas's first
	# `resized` signal (queued back in _on_panel_loaded, before the fixture board
	# existed and before layout had settled) — timing-sensitive and NOT what we
	# want to depend on for exact-pixel pin clicks. Re-fit explicitly now that
	# the canvas has its final laid-out size AND the fixture board, so
	# world_to_screen() is deterministic for every click below.
	canvas.zoom_to_fit()
	await process_frame
	canvas.pin_selected.connect(func(info: Dictionary) -> void: _last_pin_selected = info)

	# Real PluginToolRegistry + PluginScenePanelBroker rig with `panel`
	# registered under EDITOR_NAME, owned by "pcb" — the same shape production
	# dispatch resolves against (contract §2.2/§2.3).
	registry = REGISTRY_DRIVER.new().build(panel, PCB_PLUGIN_ID, EDITOR_NAME, ["minerva_pcb_pin_info"])
	return registry != null


## 3 components, 2 nets, one geometry-named pin (U1.15 -> "3V3"), one
## deliberately unconnected pin (U1.2). Pins are spaced 8mm apart so an
## exact-position click is unambiguous even against pad_at's default 5mm
## inspector radius (a click AT a pin is distance 0 — always nearer than any
## neighbour at >=8mm, radius considerations aside).
func _build_fixture_board(d) -> void:
	d.board_width = 100.0
	d.board_height = 60.0

	var u1 = d.new_component()
	u1.id = "U1"
	u1.position = Vector2(20.0, 20.0)
	u1.pins = {"1": Vector2(0.0, 0.0), "15": Vector2(8.0, 0.0), "2": Vector2(16.0, 0.0)}
	u1.pads = [{
		"number": "15", "name": "3V3", "type": "smd", "shape": "rect",
		"position": Vector2(8.0, 0.0), "size": Vector2(1.0, 1.0),
		"drill": Vector2.ZERO, "layers": ["F.Cu"],
	}]
	# One pin carries a ROLE from the board's own pin table, so the hover card's
	# roles line has something real to report and the "no roles declared" branch
	# is exercised by the other two pins of the same part.
	u1.pin_extra["15"] = {"roles": ["strapping"]}
	d.add_component(u1)

	var u2 = d.new_component()
	u2.id = "U2"
	u2.position = Vector2(50.0, 20.0)
	u2.pins = {"A": Vector2(0.0, 0.0)}
	d.add_component(u2)

	var u3 = d.new_component()
	u3.id = "U3"
	u3.position = Vector2(75.0, 20.0)
	u3.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u3)

	d.connect_pin_to_net("GND", "U1", "1")
	d.connect_pin_to_net("GND", "U2", "A")
	d.connect_pin_to_net("VCC", "U1", "15")
	d.connect_pin_to_net("VCC", "U3", "1")
	# U1.2 stays unconnected — no connect_pin_to_net call.



## A pin_info reply's world position as [x, y]. The reply carries the pad row's
## {x_mm, y_mm}; this reads it back as the pair the checks above compare
## against get_pin_world_position, so the shape lives in ONE place
## in this suite too.
func _pos_of(reply: Dictionary) -> Array:
	var pos: Dictionary = reply.get("position", {})
	return [float(pos.get("x_mm", NAN)), float(pos.get("y_mm", NAN))]

# ── synthetic input helpers (copied convention from test_pcb_canvas_input_probe.gd) ──

func _push_button(pos: Vector2, btn: int, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _click(pos: Vector2) -> void:
	_push_button(pos, MOUSE_BUTTON_LEFT, true)


func _release(pos: Vector2) -> void:
	_push_button(pos, MOUSE_BUTTON_LEFT, false)


func _push_shift_p() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_P
	ev.shift_pressed = true
	ev.pressed = true
	get_root().push_input(ev, true)


func _push_escape() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	get_root().push_input(ev, true)


## A pad-free board point that is ON the canvas as it is laid out RIGHT NOW.
## Derived from the canvas's own rect corner, never cached — see the fixture
## sanity check for why.
func _empty_world_point() -> Vector2:
	return canvas.screen_to_world(Vector2(24.0, canvas.size.y - 24.0))


func _world_to_root_screen(world_pos: Vector2) -> Vector2:
	return canvas.get_global_transform() * canvas.world_to_screen(world_pos)


## The card's "nothing here" spelling, read off the production module so this
## suite cannot drift from it.
func _or_dash(value: String) -> String:
	return value if not value.is_empty() else HoverCard.EMPTY_VALUE


## One real hover motion at a board point, handed to the canvas the way the
## viewport hands it over: `Control._gui_input` receives CANVAS-LOCAL px.
##
## Pushed at the canvas rather than through `get_root().push_input` because a
## motion with NO button held has no `gui.mouse_focus` to route by, and the
## headless viewport has no live pointer for `gui_find_control` to hit-test
## with — the event is simply dropped. The button gestures above keep using
## push_input: a press establishes that focus, so they route.
func _move_world(world_pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = canvas.world_to_screen(world_pos)
	ev.global_position = canvas.get_global_transform() * ev.position
	canvas._gui_input(ev)


func _click_world(world_pos: Vector2) -> void:
	var pt := _world_to_root_screen(world_pos)
	_click(pt)


func _release_world(world_pos: Vector2) -> void:
	var pt := _world_to_root_screen(world_pos)
	_release(pt)


# ── E2E-1 scenario ───────────────────────────────────────────────────────────

func _test_e2e_1_scenario() -> void:
	print("-- E2E-1: toggle / click-select / display rule / MCP parity / clear --")

	var u1 = data.get_component("U1")
	var world_1: Vector2 = u1.get_pin_world_position("1")     # net-only (GND)
	var world_15: Vector2 = u1.get_pin_world_position("15")   # geometry name "3V3" + net VCC
	var world_2: Vector2 = u1.get_pin_world_position("2")     # unconnected
	# A guaranteed-on-canvas, far-from-any-pad point: derived from a LOCAL
	# corner of the canvas's OWN rect (post zoom-to-fit) rather than a fixed
	# board-mm literal — zoom_to_fit's content bbox (component BODIES, ~5x2.5mm,
	# not the wider pin spread this fixture uses) does not necessarily cover
	# every board-mm coordinate, so a hardcoded "far" point can land outside the
	# fitted view and silently miss the canvas control entirely.
	# Re-derived at every use rather than cached: the sidebar grows a section
	# once a pad is selected, which NARROWS the canvas, and a world point taken
	# from the earlier layout then maps outside it — the click would land on the
	# sidebar and never reach the tool.
	check("fixture: the empty point is actually pad-free (sanity)",
		host.pad_at(_empty_world_point()).is_empty(),
		"pad_at(empty)=%s" % str(host.pad_at(_empty_world_point())))

	# ── A. Toggle inspect mode via Shift+P (real key event), then click a
	#      net-connected, non-geometry pad. ──
	# Grab focus first (a real click on empty space, SELECT tool still active —
	# same mechanism the existing canvas probe relies on for keyboard tests).
	var focus_pt := _empty_world_point()
	_click_world(focus_pt)
	await process_frame
	_release_world(focus_pt)
	await process_frame

	check("A: SELECT is the resting tool before toggling",
		canvas.tool_mode == canvas.ToolMode.SELECT, "tool_mode=%d" % canvas.tool_mode)

	_push_shift_p()
	await process_frame

	check("A: Shift+P arms INSPECT_PIN", canvas.tool_mode == canvas.ToolMode.INSPECT_PIN,
		"tool_mode=%d" % canvas.tool_mode)
	check("A: toolbar Pin button reflects the mode", panel._inspect_pin_button.button_pressed,
		"button_pressed=%s" % str(panel._inspect_pin_button.button_pressed))

	_last_pin_selected = {"__unset__": true}
	_click_world(world_1)
	await process_frame
	_release_world(world_1)
	await process_frame

	check("A: pin_selected fired for U1.1", str(_last_pin_selected.get("ref", "")) == "U1.1",
		"got %s" % str(_last_pin_selected))
	# The pad's facts are on the CANVAS now, not in a sidebar section, and they
	# arrive on HOVER rather than on the click — so the pointer is moved onto
	# the same pad and the card is read.
	_move_world(world_1)
	await process_frame
	var a_card := Array(canvas._hover_card_lines)
	check("A: hover card titles the pad it is over", a_card.size() > 0 and a_card[0] == "U1.1",
		"got %s" % str(a_card))
	var a_net := str(_last_pin_selected.get("net", ""))
	check("A: net name shown (GND, no geometry name)", a_net == "GND", "net='%s'" % a_net)
	check("A: card display value = net (no geometry name to win)",
		a_card.has("Pin: GND"), "got %s" % str(a_card))
	var a_members: Array = _last_pin_selected.get("net_members", [])
	check("A: net_members = [U2.A]", a_members == ["U2.A"], "got %s" % str(a_members))

	# ── B. Click the geometry-named pin — geometry name wins over net. ──
	_last_pin_selected = {"__unset__": true}
	_click_world(world_15)
	await process_frame
	_release_world(world_15)
	await process_frame

	check("B: pin_selected fired for U1.15", str(_last_pin_selected.get("ref", "")) == "U1.15",
		"got %s" % str(_last_pin_selected))
	var b_pin_name := str(_last_pin_selected.get("pin_name", ""))
	var b_net := str(_last_pin_selected.get("net", ""))
	check("B: geometry pin_name is '3V3'", b_pin_name == "3V3", "pin_name='%s'" % b_pin_name)
	check("B: net is still VCC (present, just outranked)", b_net == "VCC", "net='%s'" % b_net)
	_move_world(world_15)
	await process_frame
	var b_card := Array(canvas._hover_card_lines)
	check("B: card display value = geometry name, NOT net",
		b_card.has("Pin: 3V3"), "got %s" % str(b_card))

	# ── C. Click the unconnected pin. ──
	_last_pin_selected = {"__unset__": true}
	_click_world(world_2)
	await process_frame
	_release_world(world_2)
	await process_frame

	check("C: pin_selected fired for U1.2", str(_last_pin_selected.get("ref", "")) == "U1.2",
		"got %s" % str(_last_pin_selected))
	var c_net := str(_last_pin_selected.get("net", ""))
	check("C: net is empty (unconnected)", c_net == "", "net='%s'" % c_net)
	_move_world(world_2)
	await process_frame
	var c_card := Array(canvas._hover_card_lines)
	check("C: card display value = '(unconnected)'",
		c_card.has("Pin: (unconnected)"), "got %s" % str(c_card))
	check("C: an unconnected pad's card says so on its Net line too",
		c_card.has("Net: %s" % _or_dash("")), "got %s" % str(c_card))

	# ── D. MCP parity: minerva_pcb_pin_info must match the UI exactly, for all
	#      three pins, plus net_members. ──
	var r1: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": "U1.1"})
	check("D: MCP U1.1 succeeds", bool(r1.get("success", false)), "got %s" % str(r1))
	check("D: MCP U1.1 net matches UI (GND)", str(r1.get("net", "")) == "GND", "got %s" % str(r1))
	check("D: MCP U1.1 display_name matches UI ('GND')",
		str(r1.get("display_name", "")) == "GND", "got %s" % str(r1))
	check("D: MCP U1.1 net_members matches UI ([U2.A])",
		r1.get("net_members", []) == ["U2.A"], "got %s" % str(r1.get("net_members", [])))
	# The reply carries "position" — the pad's WORLD position in board mm,
	# matching pcb_component.get_pin_world_position exactly (same rigid-body
	# transform pad_at()/pin_info() use internally). Its shape is the pad row's
	# {x_mm, y_mm}, not a bare [x, y] pair: pin_info answers in the ONE pad-row
	# shape minerva_pcb_get_selection and minerva_pcb_free_pins also use, and
	# two spellings of one coordinate in one reply family is the drift that
	# shape exists to prevent.
	check("D: MCP U1.1 position matches get_pin_world_position",
		_pos_of(r1) == [world_1.x, world_1.y], "got %s" % str(r1.get("position", {})))

	var r15: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": "U1.15"})
	check("D: MCP U1.15 pin_name matches UI ('3V3')",
		str(r15.get("pin_name", "")) == "3V3", "got %s" % str(r15))
	check("D: MCP U1.15 display_name = geometry name (wins over net)",
		str(r15.get("display_name", "")) == "3V3", "got %s" % str(r15))
	check("D: MCP U1.15 net_members matches UI ([U3.1])",
		r15.get("net_members", []) == ["U3.1"], "got %s" % str(r15.get("net_members", [])))
	check("D: MCP U1.15 position matches get_pin_world_position",
		_pos_of(r15) == [world_15.x, world_15.y], "got %s" % str(r15.get("position", {})))

	var r2: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": "U1.2"})
	check("D: MCP U1.2 display_name = '(unconnected)'",
		str(r2.get("display_name", "")) == "(unconnected)", "got %s" % str(r2))
	check("D: MCP U1.2 net_members is empty",
		(r2.get("net_members", []) as Array).is_empty(), "got %s" % str(r2.get("net_members", [])))
	check("D: MCP U1.2 position present even though the pin is unconnected",
		_pos_of(r2) == [world_2.x, world_2.y], "got %s" % str(r2.get("position", {})))

	# x_mm/y_mm variant hits the same pad as the ref variant.
	var r_xy: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info",
		{"editor_name": EDITOR_NAME, "x_mm": world_1.x, "y_mm": world_1.y})
	check("D: MCP x_mm/y_mm resolves the same pin as ref", str(r_xy.get("ref", "")) == "U1.1",
		"got %s" % str(r_xy))
	check("D: MCP x_mm/y_mm variant also carries position (both resolution paths covered)",
		_pos_of(r_xy) == [world_1.x, world_1.y], "got %s" % str(r_xy.get("position", {})))

	# ── D2. THE CARD AND THE VERB CANNOT DISAGREE. Every pad fact on the card is
	#     compared VERBATIM against the reply minerva_pcb_pin_info just gave for
	#     the same pad — the card is not allowed its own spelling of a net, a
	#     role or a layer, because it is not allowed its own derivation. ──
	for probe in [[world_1, r1], [world_15, r15], [world_2, r2]]:
		var at: Vector2 = probe[0]
		var reply: Dictionary = probe[1]
		var ref := str(reply.get("ref", ""))
		_move_world(at)
		await process_frame
		var card := Array(canvas._hover_card_lines)
		check("D2: %s card titles the ref the verb reports" % ref,
			card.size() > 0 and card[0] == ref, "got %s" % str(card))
		check("D2: %s card display name == the verb's display_name" % ref,
			card.has("Pin: %s" % str(reply.get("display_name", ""))), "got %s" % str(card))
		# A fact the verb answers "" for prints as an em dash on the card, which
		# is the card SAYING "nothing here" rather than leaving a blank row —
		# so the comparison is against the verb's value or that dash, never
		# against an empty string.
		var reply_layer := str(reply.get("layer", ""))
		check("D2: %s card layer == the verb's layer" % ref,
			card.has("Layer: %s" % _or_dash(reply_layer)),
			"got %s (verb layer '%s')" % [str(card), reply_layer])
		var reply_net := str(reply.get("net", ""))
		check("D2: %s card net == the verb's net" % ref,
			card.has("Net: %s" % _or_dash(reply_net)),
			"got %s (verb net '%s')" % [str(card), reply_net])
		# ROLES: present as a line exactly when the board declares any, and
		# naming every role the verb names — [] must not print an empty row.
		var reply_roles: Array = reply.get("roles", [])
		var role_line := ""
		for line in card:
			if str(line).begins_with("Roles: "):
				role_line = str(line)
		if reply_roles.is_empty():
			check("D2: %s carries no Roles line — the board declares none" % ref,
				role_line.is_empty(), "got '%s'" % role_line)
		else:
			var missing := ""
			for role in reply_roles:
				if not role_line.contains(str(role)):
					missing = str(role)
			check("D2: %s card Roles names every role the verb reports" % ref,
				not role_line.is_empty() and missing.is_empty(),
				"line '%s' missing '%s'" % [role_line, missing])

	# ── D3. IT IS PAINT, NOT A CONTROL: the card stays inside the canvas and
	#     never covers the point it describes, and no gesture leaves one up. ──
	_move_world(world_1)
	await process_frame
	var rect: Rect2 = canvas.hover_card_rect()
	check("D3: the card has a rect while a pad is hovered", rect.size.x > 0.0 and rect.size.y > 0.0,
		"rect=%s" % str(rect))
	check("D3: the card lies inside the canvas rect",
		rect.position.x >= 0.0 and rect.position.y >= 0.0
			and rect.end.x <= canvas.size.x and rect.end.y <= canvas.size.y,
		"rect=%s canvas=%s" % [str(rect), str(canvas.size)])
	check("D3: the card does not cover the hovered point",
		not rect.has_point(canvas.world_to_screen(world_1)),
		"rect=%s point=%s" % [str(rect), str(canvas.world_to_screen(world_1))])
	check("D3: the canvas still captures no input for it (mouse_filter unchanged)",
		canvas.mouse_filter == Control.MOUSE_FILTER_STOP)
	canvas.is_box_selecting = true
	check("D3: a marquee in progress suppresses the card entirely",
		canvas.hover_card_rect() == Rect2(), "rect=%s" % str(canvas.hover_card_rect()))
	canvas.is_box_selecting = false
	canvas.is_dragging_selection = true
	check("D3: so does a selection drag",
		canvas.hover_card_rect() == Rect2(), "rect=%s" % str(canvas.hover_card_rect()))
	canvas.is_dragging_selection = false

	# ── E. Click empty space clears; malformed/unknown MCP refs error cleanly. ──
	_last_pin_selected = {"__unset__": true}
	var clear_pt := _empty_world_point()
	_click_world(clear_pt)
	await process_frame
	_release_world(clear_pt)
	await process_frame

	check("E: click empty space clears (pin_selected({}))", _last_pin_selected.is_empty(),
		"got %s" % str(_last_pin_selected))
	_move_world(_empty_world_point())
	await process_frame
	check("E: hover card is gone one frame after the pointer leaves the pad",
		canvas._hover_card_lines.is_empty(), "got %s" % str(Array(canvas._hover_card_lines)))
	check("E: the sidebar carries no Pin Info section at all any more",
		panel.find_child("PinInfoSection", true, false) == null)

	var r_unknown: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": "ZZ9.99"})
	check("E: MCP unknown ref 'ZZ9.99' -> structured error, not a crash",
		not bool(r_unknown.get("success", true)) and r_unknown.has("error"), "got %s" % str(r_unknown))

	var r_malformed: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": "garbage"})
	check("E: MCP malformed ref (no dot) -> structured error",
		not bool(r_malformed.get("success", true)) and r_malformed.has("error"), "got %s" % str(r_malformed))

	var r_empty_ref: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": ""})
	check("E: MCP empty-string ref -> structured error",
		not bool(r_empty_ref.get("success", true)) and r_empty_ref.has("error"), "got %s" % str(r_empty_ref))

	var r_no_args: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME})
	check("E: MCP neither ref nor x_mm/y_mm -> structured error",
		not bool(r_no_args.get("success", true)) and r_no_args.has("error"), "got %s" % str(r_no_args))

	# This one crosses the DISPATCHER boundary (unknown editor_name never
	# reaches panel_tools.gd at all) so the error shape is PluginErrors'
	# structured editor_not_found, not panel_tools.gd's own _err({"error":…})
	# shape the other assertions in this scenario check — mechanical fallout
	# of routing through the real dispatcher (contract §2.2), not a behavior
	# change: still a structured, non-crashing error naming the bad editor.
	var r_bad_editor: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": "NoSuchEditor", "ref": "U1.1"})
	check("E: MCP unknown editor_name -> structured error",
		not bool(r_bad_editor.get("success", true)) and r_bad_editor.get("error_code", "") == "editor_not_found",
		"got %s" % str(r_bad_editor))

	# Bonus: Escape exits the mode; Shift+P toggles both directions. Still in
	# INSPECT_PIN here — nothing above exited it (clicking empty space only
	# clears the selection, per contract §3).
	check("bonus: still in INSPECT_PIN (empty-space click doesn't exit the mode)",
		canvas.tool_mode == canvas.ToolMode.INSPECT_PIN, "tool_mode=%d" % canvas.tool_mode)
	_push_escape()
	await process_frame
	check("bonus: Escape exits INSPECT_PIN back to Select",
		canvas.tool_mode == canvas.ToolMode.SELECT, "tool_mode=%d" % canvas.tool_mode)
	check("bonus: Escape also clears the hover card",
		canvas._hover_card_lines.is_empty(), "got %s" % str(Array(canvas._hover_card_lines)))

	_push_shift_p()
	await process_frame
	check("bonus: Shift+P re-arms INSPECT_PIN from Select",
		canvas.tool_mode == canvas.ToolMode.INSPECT_PIN, "tool_mode=%d" % canvas.tool_mode)
	_push_shift_p()
	await process_frame
	check("bonus: Shift+P toggles back off to Select",
		canvas.tool_mode == canvas.ToolMode.SELECT, "tool_mode=%d" % canvas.tool_mode)


# ── pad_at unit checks (welcome, not the gate) ──────────────────────────────

func _test_pad_at_units() -> void:
	print("-- pad_at unit checks (miss / nearest-wins / radius boundary / tie-break) --")

	check("pad_at: miss returns {} far from any pad",
		host.pad_at(Vector2(-500.0, -500.0)).is_empty())

	var u1 = data.get_component("U1")
	var world_1: Vector2 = u1.get_pin_world_position("1")

	var hit_exact: Dictionary = host.pad_at(world_1)
	check("pad_at: exact hit resolves U1.1", str(hit_exact.get("component", "")) == "U1"
		and str(hit_exact.get("pin", "")) == "1", "got %s" % str(hit_exact))

	# Radius boundary: a point exactly at the default radius (5.0mm) is inside
	# (<=); a hair beyond it is outside. Offset along Y (perpendicular to the
	# 8mm-spaced sibling pins on the X axis) so no other pad's radius overlaps
	# this probe point.
	var boundary_in := world_1 + Vector2(0.0, 5.0)
	var boundary_out := world_1 + Vector2(0.0, 5.01)
	var hit_boundary_in: Dictionary = host.pad_at(boundary_in, 5.0)
	check("pad_at: exactly-at-radius is a hit (inclusive boundary)",
		str(hit_boundary_in.get("component", "")) == "U1" and str(hit_boundary_in.get("pin", "")) == "1",
		"got %s" % str(hit_boundary_in))
	check("pad_at: just-outside-radius is a miss",
		host.pad_at(boundary_out, 5.0).is_empty())

	# Nearest-wins: a point 3mm from U1.1 and 5mm from U1.15 (8mm pin spacing) has
	# BOTH pads within the 5mm radius — the nearer one (U1.1) must win.
	var between_1_and_15 := world_1 + Vector2(3.0, 0.0)
	var hit_near: Dictionary = host.pad_at(between_1_and_15, 5.0)
	check("pad_at: nearest pad wins when two candidates are both in radius",
		str(hit_near.get("component", "")) == "U1" and str(hit_near.get("pin", "")) == "1",
		"got %s" % str(hit_near))

	# Deterministic tie-break: two equidistant synthetic pads resolve to the
	# lexicographically-first (component, pin).
	_test_pad_at_tie_break()

	# The rule the ranking above measures with: a pad's COPPER, not its centre.
	_test_pad_at_copper_extent()


func _test_pad_at_tie_break() -> void:
	# A separate throwaway board (via a second panel-free pcb_data instance is not
	# reachable off-tree without a class ref, so reuse the SAME data model with two
	# extra components placed equidistant from a probe point, then remove them).
	var probe := Vector2(90.0, 10.0)
	var b1 = data.new_component()
	b1.id = "ZTIE"
	b1.position = probe + Vector2(3.0, 0.0)
	b1.pins = {"9": Vector2(0.0, 0.0)}
	data.add_component(b1)

	var a1 = data.new_component()
	a1.id = "ATIE"
	a1.position = probe + Vector2(0.0, 3.0)
	a1.pins = {"9": Vector2(0.0, 0.0)}
	data.add_component(a1)

	var hit: Dictionary = host.pad_at(probe, 5.0)
	check("pad_at: equidistant tie breaks lexicographically (ATIE before ZTIE)",
		str(hit.get("component", "")) == "ATIE", "got %s" % str(hit))

	data.remove_component("ZTIE")
	data.remove_component("ATIE")


## A part whose pads are NOT all one size or shape: a long land, a small round
## land beside its far end, and a third land turned 90 degrees WITHIN the
## footprint. All geometry is component-local, so the same part measures the
## same at any component rotation.
func _add_land_probe_part(part_id: String, at: Vector2, rotation_deg: float):
	var c = data.new_component()
	c.id = part_id
	c.position = at
	c.rotation = rotation_deg
	c.pins = {"1": Vector2(0.0, 0.0), "2": Vector2(3.0, 0.0), "3": Vector2(0.0, 6.0)}
	c.pads = [
		{"number": "1", "type": "smd", "shape": "rect", "position": Vector2(0.0, 0.0),
			"size": Vector2(4.0, 1.6), "rotation": 0.0,
			"drill": Vector2.ZERO, "layers": ["F.Cu"]},
		{"number": "2", "type": "smd", "shape": "circle", "position": Vector2(3.0, 0.0),
			"size": Vector2(0.6, 0.6), "rotation": 0.0,
			"drill": Vector2.ZERO, "layers": ["F.Cu"]},
		{"number": "3", "type": "smd", "shape": "rect", "position": Vector2(0.0, 6.0),
			"size": Vector2(4.0, 1.6), "rotation": 90.0,
			"drill": Vector2.ZERO, "layers": ["F.Cu"]},
	]
	c.has_pad_geometry = true
	data.add_component(c)
	return c


## A click anywhere on a pad's copper is that pad.
##
## The probe part is built twice, unrotated and at 90 degrees, so the SAME local
## probe has to survive the component transform as well as each land's own
## rotation. Every probe is PLACED with the forward transform and RESOLVED by
## the pick's inverse of it, so a composition error fails the rotated part while
## the unrotated one still passes.
##
## ORACLE: the authored land sizes. Pin 1's land is 4.0mm long, so +-2.0mm along
## it is copper; pin 2 is a 0.6mm disc 3.0mm away. A point 1.7mm out is
## therefore ON pin 1 while being NEARER pin 2's CENTRE (1.3mm) than pin 1's
## (1.7mm) — pin 2 is the answer a centre-ranked pick gives, and the answer this
## one must not. Pin 3's land is the same 4.0 x 1.6 turned 90 degrees inside the
## footprint, so 1.7mm along the footprint's Y is copper while 1.7mm along its X
## is 0.9mm clear of the 1.6mm-wide land.
func _test_pad_at_copper_extent() -> void:
	var parts := [
		_add_land_probe_part("LAND0", Vector2(85.0, 45.0), 0.0),
		_add_land_probe_part("LAND90", Vector2(35.0, 50.0), 90.0),
	]
	for part in parts:
		var at := func(local: Vector2) -> Vector2:
			return part.position + (part.get_transform() * local)

		var far_end: Dictionary = host.pad_at(at.call(Vector2(1.7, 0.0)), 5.0)
		check("%s: a click on the long land's far end is that pad, not the small pad nearer its centre" % part.id,
			str(far_end.get("component", "")) == part.id
				and str(far_end.get("pin", "")) == "1", "got %s" % str(far_end))

		# The fine-work case that must survive: 0.4mm off the small pad's
		# centre is 0.1mm off its copper, and 1.4mm clear of the long land.
		var near_small: Dictionary = host.pad_at(at.call(Vector2(3.4, 0.0)), 5.0)
		check("%s: a click NEAR but not on the small pad still finds it" % part.id,
			str(near_small.get("component", "")) == part.id
				and str(near_small.get("pin", "")) == "2", "got %s" % str(near_small))

		# Radius 0.5mm: only true copper plus a hair of slack can answer, so
		# these two probes read the land's ORIENTATION and nothing else.
		var along: Dictionary = host.pad_at(at.call(Vector2(0.0, 7.7)), 0.5)
		check("%s: the turned land is copper 1.7mm along the footprint's Y" % part.id,
			str(along.get("component", "")) == part.id
				and str(along.get("pin", "")) == "3", "got %s" % str(along))
		check("%s: …and is not copper 1.7mm along its X, 0.9mm clear of the same land" % part.id,
			host.pad_at(at.call(Vector2(1.7, 6.0)), 0.5).is_empty(),
			"got %s" % str(host.pad_at(at.call(Vector2(1.7, 6.0)), 0.5)))

	data.remove_component("LAND0")
	data.remove_component("LAND90")


# ── assertion helper ─────────────────────────────────────────────────────────

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
