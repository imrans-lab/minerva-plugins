extends SceneTree
## A PAD IS A THING YOU CAN POINT AT — the Pin Select tool, the pad row, and
## the two net edits a pad selection affords.
##
## THE ACCEPTANCE CASE: select two pads, say "see these pins? move them to the
## other side of U1S", and the selection is what gets read. Universal Select
## picks the whole 44-pin part, so without a pad selection nothing returns
## kind:'pad' and a pin-level question can only be answered by guessing a refdes
## from a coordinate.
##
## What each section pins:
##   1  pcb_pad_row.gd — ONE pad shape, with `side` and `roles`.
##   2  the renderer and pin_copper_distance take the SAME land-to-world
##      transform. 2c is the discriminating check: drawing a land at the
##      COMPONENT's rotation while the hit test honours the land's own puts the
##      drawn corner where the hit test says there is no copper.
##   3  the canvas pad selection (selected_pad_refs, KIND_PAD, the "pads" key of
##      selection_snapshot) and bare P.
##   4  minerva_pcb_get_selection's pad entries; free_pins, move_net,
##      swap_nets and select.
##   5  move/rotate replies carried no `pads`, so "where did pin 1 land" was a
##      second round trip — the trip an agent got backwards twice in one night.
##
## THE ORACLES, named:
##   * geometry — pcb_component.pin_copper_distance, the copper hit test.
##     Section 2 asks it about the corners the RENDERER produces. Rendered
##     geometry == hit-test geometry is the rule this canvas states about
##     itself, and rotated lands were the one place it had stopped holding.
##   * the model — a net's own `pins` list, read back through
##     minerva_pcb_pin_info and minerva_pcb_get_nets, is what says a move or a
##     swap really happened; PCBData.history.size() is what says it was ONE
##     undo step, the same oracle test_pcb_net_membership.gd uses.
##   * real input — section 3's arming and first click go through
##     Viewport.push_input, not a direct method call, because the question
##     "does the tool actually receive its clicks with the annotation overlay
##     mounted" cannot be answered by calling the handler yourself.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_pcb_pin_select.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const PadRow := preload("res://../../minerva-plugins/pcb/ui/model/pcb_pad_row.gd")
const PinSelectTool := preload("res://../../minerva-plugins/pcb/ui/pcb_pin_select_tool.gd")
const PadApproach := preload("res://../../minerva-plugins/pcb/ui/model/pcb_pad_approach.gd")
const CopperContact := preload("res://../../minerva-plugins/pcb/ui/model/pcb_copper_contact.gd")

var _pass := 0
var _fail := 0

var panel: Variant = null
var canvas = null
var host = null
var data = null


class FakeEditor extends RefCounted:
	var tab_title: String = "PinSelectProbe"
	var associated_object: Variant = ""


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s%s" % [desc, ("" if detail == "" else " — " + detail)])


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)],
		actual == expected)


func check_near(desc: String, actual: float, expected: float, tol: float = 0.001) -> void:
	check("%s (expected ~%.4f, got %.4f)" % [desc, expected, actual],
		absf(actual - expected) <= tol)


func _init() -> void:
	print("=== Pin Select: a pad is a thing you can point at ===\n")
	await process_frame
	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	_test_1_pad_row()
	_test_2_land_transform()
	await _test_3_tool_and_selection()
	await _test_4_verbs()
	await _test_5_placement_replies()

	panel.queue_free()
	await process_frame
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture ──────────────────────────────────────────────────────────

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
	_build_fixture(data)
	for _i in range(4):
		await process_frame
	canvas = panel._canvas
	if canvas == null:
		return false
	canvas.zoom_to_fit()
	await process_frame
	return true


## A SOCKET, the shape the DCR is about: two columns of four pins, 2.54 pitch,
## columns 5.08 apart so the COLUMN axis is the shorter one — which is what a
## real 22-pin devkit socket looks like and what makes a corner pin resolve to
## its column rather than to the end of the part.
##
##   west column  x=-2.54   pins 1 2 3 4   (top to bottom)
##   east column  x=+2.54   pins 5 6 7 8
##
## Roles live in pin_extra, which is where a pin's canonical `roles` key lands
## and is re-emitted from — see section 1e, which proves that round trip rather
## than assuming it.
func _build_fixture(d) -> void:
	d.board_width = 100.0
	d.board_height = 60.0

	var u1s = d.new_component()
	u1s.id = "U1S"
	u1s.position = Vector2(30.0, 20.0)
	u1s.has_pad_geometry = true
	var ys := [-3.81, -1.27, 1.27, 3.81]
	for i in range(4):
		var west := Vector2(-2.54, float(ys[i]))
		var east := Vector2(2.54, float(ys[i]))
		u1s.pins[str(i + 1)] = west
		u1s.pins[str(i + 5)] = east
		u1s.pads.append(_land(str(i + 1), west))
		u1s.pads.append(_land(str(i + 5), east))
	u1s.pin_extra["1"] = {"roles": ["strapping"]}
	u1s.pin_extra["5"] = {"roles": ["uart_console"]}
	u1s.pin_extra["8"] = {"roles": ["adc", "adc"]}  # deduped by the row
	d.add_component(u1s)

	var j2 = d.new_component()
	j2.id = "J2"
	j2.position = Vector2(10.0, 20.0)
	j2.pins = {"1": Vector2(0.0, -1.27), "2": Vector2(0.0, 1.27)}
	d.add_component(j2)

	# A 2-pad part for the rotation convention (section 5): pad 1 is the WEST
	# one, the ordinary chip-resistor convention.
	var r1 = d.new_component()
	r1.id = "R1"
	r1.position = Vector2(60.0, 10.0)
	r1.pins = {"1": Vector2(-0.8, 0.0), "2": Vector2(0.8, 0.0)}
	d.add_component(r1)

	# THE REMORA FIXTURE: one land turned 90 degrees INSIDE an unrotated part.
	# Authored 2.0 x 0.5, so its true long axis runs NORTH-SOUTH in the world.
	var tp1 = d.new_component()
	tp1.id = "TP1"
	tp1.position = Vector2(70.0, 30.0)
	tp1.rotation = 0.0
	tp1.has_pad_geometry = true
	tp1.pins = {"1": Vector2(0.0, 0.0)}
	tp1.pads = [{
		"number": "1", "type": "smd", "shape": "rect",
		"position": Vector2(0.0, 0.0), "size": Vector2(2.0, 0.5),
		"rotation": 90.0, "drill": Vector2.ZERO, "layers": ["F.Cu"],
	}]
	d.add_component(tp1)

	d.connect_pin_to_net("I2C_SDA", "U1S", "6")
	d.connect_pin_to_net("I2C_SDA", "J2", "1")
	d.connect_pin_to_net("I2C_SCL", "U1S", "7")
	d.connect_pin_to_net("I2C_SCL", "J2", "2")


func _land(number: String, at: Vector2) -> Dictionary:
	return {"number": number, "type": "smd", "shape": "rect",
		"position": at, "size": Vector2(0.6, 0.6), "rotation": 0.0,
		"drill": Vector2.ZERO, "layers": ["F.Cu"]}


# ── 1. THE PAD ROW — one shape, defined once ─────────────────────────────────

func _test_1_pad_row() -> void:
	print("\n-- 1. the pad row: ref, net, position, layer, side, approach_sides, roles --")
	var u1s = data.get_component("U1S")

	var row6: Dictionary = PadRow.row(data, u1s, "6")
	check_eq("1a: kind is 'pad'", str(row6.get("kind", "")), "pad")
	check_eq("1a: ref is the one address form", str(row6.get("ref", "")), "U1S.6")
	check_eq("1a: …split out, so nobody re-parses it",
		[str(row6.get("component", "")), str(row6.get("pin", ""))], ["U1S", "6"])
	check_eq("1a: net comes from the model", str(row6.get("net", "")), "I2C_SDA")
	var pos6: Dictionary = row6.get("position", {})
	check_near("1a: position is the pad's WORLD x", float(pos6.get("x_mm", 0.0)), 32.54)
	check_near("1a: position is the pad's WORLD y", float(pos6.get("y_mm", 0.0)), 18.73)
	check_eq("1a: an F.Cu land on a top part is on 'top'", str(row6.get("layer", "")), "top")

	# THE HOLE TRIO. A plated barrel really does pierce every copper layer; an
	# UNPLATED one is drilled and never plated, so it is on NO layer — the same
	# reading the contact predicate takes (physical_pad_node returns a
	# no_copper_node for it). Answering "all" for both made a mechanical hole
	# look like the best-connected pin on the part.
	var holes = data.new_component()
	holes.id = "H1"
	holes.position = Vector2(80.0, 40.0)
	holes.has_pad_geometry = true
	# Pins 3 and 4 are the MULTI-LAND shape: one logical pin owning several
	# physical lands, with the NPTH record listed FIRST. A plated slot or a
	# drilled-and-soldered shield pin is authored exactly like this.
	holes.pins = {"1": Vector2(0.0, 0.0), "2": Vector2(2.0, 0.0),
		"3": Vector2(4.0, 0.0), "4": Vector2(6.0, 0.0)}
	holes.pads = [
		{"number": "1", "type": "thru_hole", "shape": "circle",
		 "position": Vector2(0.0, 0.0), "size": Vector2(1.6, 1.6),
		 "rotation": 0.0, "drill": Vector2(0.8, 0.8), "layers": ["F.Cu", "B.Cu"]},
		{"number": "2", "type": "np_thru_hole", "shape": "circle",
		 "position": Vector2(2.0, 0.0), "size": Vector2(3.2, 3.2),
		 "rotation": 0.0, "drill": Vector2(3.2, 3.2), "layers": ["F.Cu", "B.Cu"]},
		{"number": "3", "type": "np_thru_hole", "shape": "circle",
		 "position": Vector2(4.0, 0.0), "size": Vector2(1.2, 1.2),
		 "rotation": 0.0, "drill": Vector2(1.2, 1.2), "layers": ["F.Cu", "B.Cu"]},
		{"number": "3", "type": "smd", "shape": "rect",
		 "position": Vector2(4.0, 0.0), "size": Vector2(1.6, 1.6),
		 "rotation": 0.0, "drill": Vector2.ZERO, "layers": ["F.Cu"]},
		{"number": "4", "type": "np_thru_hole", "shape": "circle",
		 "position": Vector2(6.0, 0.0), "size": Vector2(1.2, 1.2),
		 "rotation": 0.0, "drill": Vector2(1.2, 1.2), "layers": ["F.Cu", "B.Cu"]},
		{"number": "4", "type": "thru_hole", "shape": "circle",
		 "position": Vector2(6.0, 0.0), "size": Vector2(1.6, 1.6),
		 "rotation": 0.0, "drill": Vector2(0.8, 0.8), "layers": ["F.Cu", "B.Cu"]},
	]
	data.add_component(holes)
	check_eq("1a2: a PLATED barrel is on every copper layer",
		PadRow.layer_for_pin(holes, "1"), "all")
	check_eq("1a2: an UNPLATED hole is on none of them, not all of them",
		PadRow.layer_for_pin(holes, "2"), "none")
	check_eq("1a2: …and the row says the same thing the model does",
		str((PadRow.row(data, holes, "2") as Dictionary).get("layer", "")), "none")
	check("1a2: …which is what the contact predicate already says",
		not CopperContact.node_has_copper(CopperContact.physical_pad_node(
			holes, holes.pads[1], PackedStringArray(["top", "bottom"]),
			Vector2.ZERO, false)))

	# THE COPPER-BEARING LANDS ANSWER, not whichever record comes first. Reading
	# only the first land called pin 3 copper-less because its NPTH record is
	# listed ahead of the smd land that plainly renders, routes and is committed
	# to. "none" survives only for a pin with no copper at all — pin 2 above.
	check_eq("1a3: a pin whose NPTH land is listed first still reports its copper",
		PadRow.layer_for_pin(holes, "3"), "top")
	check_eq("1a3: …and the row says the same thing",
		str((PadRow.row(data, holes, "3") as Dictionary).get("layer", "")), "top")
	check_eq("1a3: a plated barrel behind an NPTH land is still on every layer",
		PadRow.layer_for_pin(holes, "4"), "all")

	# SIDE — the whole point of "the other side of U1S". East-column pins say
	# east, west-column pins say west, and the CORNER pins resolve to their
	# column because the column axis is the shorter one.
	check_eq("1b: an east-column pin is on the east side", str(row6.get("side", "")), "east")
	check_eq("1b: a west-column pin is on the west side",
		str((PadRow.row(data, u1s, "2") as Dictionary).get("side", "")), "west")
	check_eq("1b: a corner pin resolves to its COLUMN, not to the end of the part",
		str((PadRow.row(data, u1s, "5") as Dictionary).get("side", "")), "east")
	check_eq("1b: a part with one pin has no side to speak of",
		str(PadRow.side_for_pin(data.get_component("TP1"), "1")), "")

	# APPROACH_SIDES is a different question, and the fixture is built so the
	# answer cannot depend on the board's width/clearance numbers: the west
	# strip is blocked by the facing pad at the same y, north and south by the
	# pads above and below in the same column, and nothing sits east of the
	# east column at all.
	check_eq("1c: approach_sides is where a TRACE may leave, not where the pad sits",
		row6.get("approach_sides", []), ["east"])

	# ROLES come from the BOARD's pin table, never from an agent's memory.
	check_eq("1d: a pin the board flags carries its role",
		(PadRow.row(data, u1s, "1") as Dictionary).get("roles", []), ["strapping"])
	check_eq("1d: …deduped and lowercased",
		(PadRow.row(data, u1s, "8") as Dictionary).get("roles", []), ["adc"])
	check_eq("1d: a pin the board says nothing about claims nothing",
		row6.get("roles", []), [])

	# The pin table survives the canonical document — this is what makes
	# authoring roles once in the board YAML worth doing.
	var probe = data.new_component()
	probe.load_from_board_dict({"ref": "PROBE", "x_mm": 0.0, "y_mm": 0.0,
		"pins": [{"number": "7", "x_mm": 0.0, "y_mm": 0.0, "roles": ["jtag"]}]})
	check_eq("1e: a canonical pin's `roles` key lands in pin_extra",
		(probe.pin_extra.get("7", {}) as Dictionary).get("roles", []), ["jtag"])
	var emitted: Array = (probe.to_board_dict().get("pins", []) as Array)
	check_eq("1e: …and is re-emitted verbatim",
		(emitted[0] as Dictionary).get("roles", []), ["jtag"])
	check_eq("1e: …so the row reads it back off a loaded board",
		PadRow.roles_for_pin(probe, "7"), ["jtag"])

	# FREE PINS: on no net, filterable by side and by role.
	var free_all: Array = PadRow.free_pins(data, u1s)
	check_eq("1f: six of the eight pins are on no net", free_all.size(), 6)
	var west_free: Array = PadRow.free_pins(data, u1s, "west")
	check_eq("1f: the west column has four free pins", west_free.size(), 4)
	var west_pins := PackedStringArray()
	for r in west_free:
		west_pins.append(str((r as Dictionary).get("pin", "")))
	check_eq("1f: …and they are the west column's", Array(west_pins), ["1", "2", "3", "4"])
	var usable: Array = PadRow.free_pins(data, u1s, "west", ["strapping"])
	check_eq("1f: excluding strapping drops pin 1", usable.size(), 3)
	check_eq("1f: …and only pin 1", str((usable[0] as Dictionary).get("pin", "")), "2")

	check_eq("1g: parse_ref splits at the LAST dot",
		PadRow.parse_ref("U1.S.GPIO8"), ["U1.S", "GPIO8"])
	check_eq("1g: a ref with no pin is not a ref", PadRow.parse_ref("U1S"), [])


# ── 2. ONE LAND-TO-WORLD TRANSFORM ───────────────────────────────────────────

func _test_2_land_transform() -> void:
	print("\n-- 2. rendered geometry == hit-test geometry, for a ROTATED land --")
	var tp1 = data.get_component("TP1")
	var land: Dictionary = tp1.pads[0]

	# 2a. The renderer's own geometry comes from the shared transform.
	var drawn: Dictionary = canvas.pad_draw_geometry(tp1, land)
	var owner_says: Dictionary = tp1.get_pad_world_transform(land)
	check("2a: the renderer reads the ONE transform",
		drawn["position"] == owner_says["position"] and drawn["size"] == owner_says["size"] \
		and is_equal_approx(float(drawn["rotation"]), float(owner_says["rotation"])),
		"drawn=%s owner=%s" % [str(drawn), str(owner_says)])
	check_near("2a: …which carries the LAND's own angle, not just the part's",
		float(drawn["rotation"]), 90.0)
	check("2a: …and never swaps width for height to fake it",
		(drawn["size"] as Vector2) == Vector2(2.0, 0.5), str(drawn["size"]))

	# 2b. THE ORACLE: every corner of the rendered
	# rectangle is inside pin_copper_distance's zero-distance region, and a
	# point just beyond each corner is outside it. Corners are derived exactly
	# as _draw_component_pads derives them — centre + corner rotated by the
	# NEGATED board angle — but in world mm, which world_to_screen is a plain
	# uniform scale and offset away from.
	var centre: Vector2 = drawn["position"]
	var half: Vector2 = (drawn["size"] as Vector2) * 0.5
	var rot := deg_to_rad(-float(drawn["rotation"]))
	var all_on := true
	var all_out := true
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner: Vector2 = centre + Vector2(half.x * sx, half.y * sy).rotated(rot)
			if tp1.pin_copper_distance("1", corner) > 0.0001:
				all_on = false
			var beyond: Vector2 = centre \
				+ Vector2((half.x + 0.05) * sx, (half.y + 0.05) * sy).rotated(rot)
			if tp1.pin_copper_distance("1", beyond) <= 0.0:
				all_out = false
	check("2b: every rendered corner is ON the copper the hit test finds", all_on)
	check("2b: …and just past each corner there is none", all_out)

	# 2c. THE DISAGREEMENT THE REMORA NAMES, stated as an assertion so it can
	# never come back: the OLD renderer drew this land unrotated, putting copper
	# on screen at the east end of a 2.0mm axis the hit test says is empty, and
	# drawing nothing at the north end where the copper actually is.
	check("2c: the land's TRUE long axis runs north-south",
		tp1.pin_copper_distance("1", centre + Vector2(0.0, 0.9)) == 0.0,
		"distance=%f" % tp1.pin_copper_distance("1", centre + Vector2(0.0, 0.9)))
	check("2c: …so the old renderer's east end is not copper at all",
		tp1.pin_copper_distance("1", centre + Vector2(0.9, 0.0)) > 0.0)
	check("2c: …nor is the old renderer's corner",
		tp1.pin_copper_distance("1", centre + Vector2(1.0, 0.25)) > 0.0)

	# 2d. The approach reader reads the same transform, and now boxes a turned
	# land by its real box: 2.0 x 0.5 turned 90 is 0.5 wide and 2.0 tall.
	var rect: Rect2 = PadApproach.land_rect(owner_says)
	check_near("2d: the land's world box is 0.5mm wide", rect.size.x, 0.5)
	check_near("2d: …and 2.0mm tall", rect.size.y, 2.0)

	# 2e. An UNROTATED land in an unrotated part is byte-identical to before —
	# the fix cannot have moved ordinary copper.
	var u1s = data.get_component("U1S")
	var plain: Dictionary = u1s.get_pad_world_transform(u1s.lands_for_pin("6")[0])
	check("2e: an unrotated land still lands exactly where it always did",
		(plain["position"] as Vector2).is_equal_approx(Vector2(32.54, 18.73)) \
		and float(plain["rotation"]) == 0.0, str(plain))


# ── 3. THE TOOL: arming, picking, shift-extending ────────────────────────────

func _test_3_tool_and_selection() -> void:
	print("\n-- 3. Pin Select: P arms it, a click selects a PAD, shift extends --")
	var u1s = data.get_component("U1S")
	var w6: Vector2 = u1s.get_pin_world_position("6")
	var w7: Vector2 = u1s.get_pin_world_position("7")
	# A guaranteed pad-free point derived from the canvas's OWN laid-out rect,
	# not a board-mm literal — the same rule test_pcb_pin_inspector.gd states.
	var empty_pt: Vector2 = canvas.screen_to_world(Vector2(24.0, canvas.size.y - 24.0))
	check("3a: the empty point really is pad-free (fixture sanity)",
		host.pad_at(empty_pt).is_empty(), str(host.pad_at(empty_pt)))

	# Focus the canvas with a real click, then arm with a real BARE P — the
	# binding the DCR asks for, and the one that had to be proved free.
	_click_world(empty_pt)
	await process_frame
	_release_world(empty_pt)
	await process_frame
	check("3b: SELECT is the resting tool", canvas.tool_mode == canvas.ToolMode.SELECT,
		"tool_mode=%d" % canvas.tool_mode)
	_push_key(KEY_P, false)
	await process_frame
	check("3b: bare P arms Pin Select", canvas.tool_mode == canvas.ToolMode.INSPECT_PIN,
		"tool_mode=%d" % canvas.tool_mode)
	check("3b: the toolbar button follows", panel._inspect_pin_button.button_pressed)

	# REAL INPUT, deliberately: the annotation overlay captures all mouse input
	# while an annotation tool is active, so "the tool receives its clicks" is
	# only answerable by pushing one through the mounted panel.
	_click_world(w6)
	await process_frame
	_release_world(w6)
	await process_frame
	check_eq("3c: a real click SELECTS the pad", Array(canvas.selected_pad_refs), ["U1S.6"])
	check_eq("3c: …and the snapshot every reader shares carries it",
		(canvas.selection_snapshot().get("pads", []) as Array), ["U1S.6"])
	# The one-pin READOUT the sidebar used to carry is gone — a pad's facts are
	# on the canvas hover card now. What survives here is the pad SELECTION,
	# asserted directly above.
	check("3c: …and no Pin Info section survives in the sidebar",
		panel.find_child("PinInfoSection", true, false) == null)

	# Shift extends. The algebra is the tool's, so it is also pinned directly:
	# a direct call cannot tell you the click arrives, and a click cannot tell
	# you what the rule is when four of them stack up.
	_shift_click_world(w7)
	await process_frame
	check_eq("3d: shift-click ADDS the second pad — the owner's 'these pins'",
		Array(canvas.selected_pad_refs), ["U1S.6", "U1S.7"])
	_shift_click_world(w6)
	await process_frame
	check_eq("3d: shift-clicking a selected pad REMOVES it",
		Array(canvas.selected_pad_refs), ["U1S.7"])

	check_eq("3e: a plain click replaces the whole selection",
		PinSelectTool.apply_click(["U1S.7", "U1S.6"], "U1S.1", false), ["U1S.1"])
	check_eq("3e: a plain click on empty space clears it",
		PinSelectTool.apply_click(["U1S.7"], "", false), [])
	check_eq("3e: a shift-click on empty space leaves it ALONE — a missed click "
		+ "must not throw away a selection the human built",
		PinSelectTool.apply_click(["U1S.7", "U1S.6"], "", true), ["U1S.7", "U1S.6"])

	# The halo reads the same transform the renderer does, so it cannot land
	# anywhere but on the copper it belongs to.
	var halo: Array = PinSelectTool.land_transforms(data, "TP1.1")
	check_eq("3f: the halo is one entry per LAND", halo.size(), 1)
	check_near("3f: …at the land's own world angle",
		float((halo[0] as Dictionary).get("rotation", 0.0)), 90.0)
	check_eq("3f: a pin with no land geometry still gets a mark",
		PinSelectTool.land_transforms(data, "J2.1").size(), 1)

	_click_world(empty_pt)
	await process_frame
	_release_world(empty_pt)
	await process_frame
	check_eq("3g: a plain click on empty canvas clears the pads",
		Array(canvas.selected_pad_refs), [])
	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	await process_frame


# ── 4. THE VERBS ─────────────────────────────────────────────────────────────

func _test_4_verbs() -> void:
	print("\n-- 4. get_selection carries pads; free_pins / move_net / swap_nets / select --")

	# get_selection: the deictic read, now pin-level.
	canvas.set_selected_pads(["U1S.6", "U1S.7"])
	await process_frame
	var sel: Dictionary = await panel.handle_tool("minerva_pcb_get_selection", {})
	var pad_rows: Array = []
	for e in (sel.get("selection", []) as Array):
		if str((e as Dictionary).get("kind", "")) == "pad":
			pad_rows.append(e)
	check_eq("4a: both selected pads come back as pad rows", pad_rows.size(), 2)
	var first: Dictionary = pad_rows[0]
	check_eq("4a: …addressed by ref", str(first.get("ref", "")), "U1S.6")
	check_eq("4a: …with id echoing the ref (a pad has no minted id)",
		str(first.get("id", "")), "U1S.6")
	check_eq("4a: …carrying the net the human is asking about",
		str(first.get("net", "")), "I2C_SDA")
	check_eq("4a: …and the side, which is what 'the other side' means",
		str(first.get("side", "")), "east")
	check("4a: …and a position", (first.get("position", {}) as Dictionary).has("x_mm"))

	# pin_info answers in the SAME shape, plus its own extras.
	var info: Dictionary = await panel.handle_tool("minerva_pcb_pin_info", {"ref": "U1S.6"})
	for key in ["kind", "ref", "component", "pin", "net", "position", "layer",
			"side", "approach_sides", "roles"]:
		check("4b: pin_info carries the pad row's `%s`" % key, info.has(key), str(info.keys()))
	check("4b: …and still carries the inspector's own extras",
		info.has("net_members") and info.has("trace_ids") and info.has("display_name"),
		str(info.keys()))
	check_eq("4b: the two surfaces agree on the row itself",
		[str(info.get("side", "")), str(info.get("layer", "")), info.get("approach_sides", [])],
		[str(first.get("side", "")), str(first.get("layer", "")), first.get("approach_sides", [])])

	# free_pins: "which free WEST pins can take I2C?"
	var free: Dictionary = await panel.handle_tool("minerva_pcb_free_pins",
		{"component_id": "U1S", "side": "west", "exclude_roles": ["strapping"]})
	check("4c: the free-pins read succeeds", bool(free.get("success", false)), str(free))
	check_eq("4c: three west pins are free and unflagged", int(free.get("free_count", -1)), 3)
	var free_refs := PackedStringArray()
	for r in (free.get("free_pins", []) as Array):
		free_refs.append(str((r as Dictionary).get("ref", "")))
	check_eq("4c: …and they are the ones the strapping filter left",
		Array(free_refs), ["U1S.2", "U1S.3", "U1S.4"])
	check_eq("4c: the rows are the SAME shape get_selection returns",
		str(((free.get("free_pins", []) as Array)[0] as Dictionary).get("kind", "")), "pad")
	var bad_side: Dictionary = await panel.handle_tool("minerva_pcb_free_pins",
		{"component_id": "U1S", "side": "up"})
	check("4c: a side that is not a side is refused by name",
		not bool(bad_side.get("success", true)), str(bad_side))

	# move_net: ONE undo step, and the netlist really moved.
	var depth: int = data.history.size()
	var moved: Dictionary = await panel.handle_tool("minerva_pcb_move_net",
		{"from": "U1S.6", "to": "U1S.2"})
	check("4d: the move succeeds", bool(moved.get("success", false)), str(moved))
	check_eq("4d: …naming the net that moved", str(moved.get("net_name", "")), "I2C_SDA")
	check_eq("4d: …as ONE undo step", data.history.size(), depth + 1)
	check_eq("4d: the source pin is off the net", data.find_net_for_pin("U1S", "6"), "")
	check_eq("4d: …and the destination is on it",
		data.find_net_for_pin("U1S", "2"), "I2C_SDA")
	check_eq("4d: the reply carries both pads AFTER the move, so nobody re-reads",
		(moved.get("pads", []) as Array).size(), 2)
	var refused: Dictionary = await panel.handle_tool("minerva_pcb_move_net",
		{"from": "U1S.6", "to": "U1S.3"})
	check_eq("4d: moving a net off a pin that has none refuses by name",
		str(refused.get("error", "")), "pin_has_no_net")
	check_eq("4d: …and mutates nothing", data.history.size(), depth + 1)

	# swap_nets: the BTN3/BTN4 case, one undo step.
	data.connect_pin_to_net("I2C_SDA", "U1S", "6")
	var swap_depth: int = data.history.size()
	var swapped: Dictionary = await panel.handle_tool("minerva_pcb_swap_nets",
		{"pins": ["U1S.6", "U1S.7"]})
	check("4e: the swap succeeds", bool(swapped.get("success", false)), str(swapped))
	check_eq("4e: …as ONE undo step", data.history.size(), swap_depth + 1)
	check_eq("4e: pin 6 now carries what pin 7 had",
		data.find_net_for_pin("U1S", "6"), "I2C_SCL")
	check_eq("4e: …and pin 7 what pin 6 had",
		data.find_net_for_pin("U1S", "7"), "I2C_SDA")
	var same_net: Dictionary = await panel.handle_tool("minerva_pcb_swap_nets",
		{"pins": ["U1S.3", "U1S.4"]})
	check_eq("4e: two netless pins have nothing to exchange",
		str(same_net.get("error", "")), "nothing_to_swap")
	var one_ref: Dictionary = await panel.handle_tool("minerva_pcb_swap_nets",
		{"pins": ["U1S.6"]})
	check("4e: a swap needs exactly two pins", not bool(one_ref.get("success", true)))

	# select: the agent points back.
	var pointed: Dictionary = await panel.handle_tool("minerva_pcb_select",
		{"pads": ["U1S.3", "U1S.4"], "entities": [{"kind": "component", "id": "J2"}]})
	check("4f: the agent can set the selection", bool(pointed.get("success", false)), str(pointed))
	check_eq("4f: …and the canvas really holds those pads",
		Array(canvas.selected_pad_refs), ["U1S.3", "U1S.4"])
	check("4f: …alongside the component", "J2" in Array(canvas.selected_components))
	var kinds := PackedStringArray()
	for e in (pointed.get("selection", []) as Array):
		kinds.append(str((e as Dictionary).get("kind", "")))
	check("4f: the reply IS get_selection's own read, so the two cannot diverge",
		Array(kinds).count("pad") == 2 and Array(kinds).has("component"), str(kinds))
	var partial: Dictionary = await panel.handle_tool("minerva_pcb_select",
		{"pads": ["U1S.1", "U1S.NOPE"]})
	check_eq("4g: a pad that no longer resolves is reported, not fatal",
		Array(canvas.selected_pad_refs), ["U1S.1"])
	check_eq("4g: …by name", (partial.get("not_found", []) as Array).size(), 1)
	var empty_call: Dictionary = await panel.handle_tool("minerva_pcb_select", {})
	check("4g: a select naming nothing is refused rather than clearing the canvas",
		not bool(empty_call.get("success", true)), str(empty_call))


# ── 5. WHERE DID PIN 1 LAND? ─────────────────────────────────────────────────

func _test_5_placement_replies() -> void:
	print("\n-- 5. move/rotate replies say where every pad went --")

	var moved: Dictionary = await panel.handle_tool("minerva_pcb_move_component",
		{"component_id": "R1", "x": 60.0, "y": 40.0, "snap_to_grid": false})
	check("5a: the move succeeds", bool(moved.get("success", false)), str(moved))
	var pads: Array = moved.get("pads", [])
	check_eq("5a: …and the reply carries every pad of the part", pads.size(), 2)
	check_eq("5a: …as pad rows", str((pads[0] as Dictionary).get("kind", "")), "pad")
	check_near("5a: pin 1 is where the model says it is",
		float(((pads[0] as Dictionary).get("position", {}) as Dictionary).get("y_mm", 0.0)), 40.0)

	# THE CONVENTION, pinned so it cannot be read backwards. `degrees` is the
	# KiCad angle the panel and the worker both apply as R(-angle) in the
	# board's Y-DOWN frame: a positive angle carries the +x axis toward -y. So
	# a pad WEST of the origin lands SOUTH (+y) at 90 and NORTH (-y) at 270 —
	# the same rule minerva_pcb_rotate_component's description states, now
	# readable straight off the reply.
	var r90: Dictionary = await panel.handle_tool("minerva_pcb_rotate_component",
		{"component_id": "R1", "degrees": 90})
	check("5b: the rotate succeeds", bool(r90.get("success", false)), str(r90))
	var p1_90: Dictionary = _pad_row_for(r90.get("pads", []), "1")
	check_near("5b: at rotation 90 the west pad lands SOUTH (+y)",
		float((p1_90.get("position", {}) as Dictionary).get("y_mm", 0.0)), 40.8)
	check_near("5b: …and on the part's own x",
		float((p1_90.get("position", {}) as Dictionary).get("x_mm", 0.0)), 60.0)

	var r270: Dictionary = await panel.handle_tool("minerva_pcb_rotate_component",
		{"component_id": "R1", "degrees": 270})
	var p1_270: Dictionary = _pad_row_for(r270.get("pads", []), "1")
	check_near("5c: at rotation 270 the same pad lands NORTH (-y)",
		float((p1_270.get("position", {}) as Dictionary).get("y_mm", 0.0)), 39.2)

	var relative: Dictionary = await panel.handle_tool("minerva_pcb_move_relative",
		{"component_id": "R1", "direction": "left"})
	check("5d: move_relative carries the pads too — one rule, not two",
		(relative.get("pads", []) as Array).size() == 2, str(relative.keys()))

	var refused: Dictionary = await panel.handle_tool("minerva_pcb_move_component",
		{"component_id": "NOPE", "x": 1.0, "y": 1.0})
	check("5e: a refusal carries no pads — nothing moved, so there is nowhere to report",
		not refused.has("pads"), str(refused))


func _pad_row_for(rows: Array, pin: String) -> Dictionary:
	for r in rows:
		if str((r as Dictionary).get("pin", "")) == pin:
			return r
	return {}


# ── synthetic input (convention from test_pcb_pin_inspector.gd) ──────────────

func _push_button(pos: Vector2, btn: int, pressed: bool, shift: bool = false) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = pressed
	ev.shift_pressed = shift
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _push_key(code: int, shift: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.shift_pressed = shift
	ev.pressed = true
	get_root().push_input(ev, true)


func _world_to_root_screen(world_pos: Vector2) -> Vector2:
	return canvas.get_global_transform() * canvas.world_to_screen(world_pos)


func _click_world(world_pos: Vector2) -> void:
	_push_button(_world_to_root_screen(world_pos), MOUSE_BUTTON_LEFT, true)


func _release_world(world_pos: Vector2) -> void:
	_push_button(_world_to_root_screen(world_pos), MOUSE_BUTTON_LEFT, false)


func _shift_click_world(world_pos: Vector2) -> void:
	var pt := _world_to_root_screen(world_pos)
	_push_button(pt, MOUSE_BUTTON_LEFT, true, true)
	_push_button(pt, MOUSE_BUTTON_LEFT, false, true)
