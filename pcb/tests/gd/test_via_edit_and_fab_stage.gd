extends SceneTree
## DCR 01a0033a12a9 changes 2 and 3 — minerva_pcb_update_via (editing a PLACED
## via) and minerva_pcb_fabrication_stage (the board's declared manufacturing
## intent).
##
## Run (via a Minerva checkout as the Godot host):
##   pcb/scripts/run-gd-tests.sh <path-to-minerva-checkout>
##
## WHY THESE TWO SHARE A SUITE. They are the two halves of the owner's model
## that station C2 left unbuilt: a via is a first-class ENTITY, so it must be
## adjustable after placement (change 2), and a board made ONLY of vias must be
## able to say so rather than reading as a wall of unrouted nets (change 3).
## Splitting them would hide that the second exists because of the first.
##
## THE GAPS, measured before writing a line: PCBData.move_via had exactly ONE
## caller (pcb_canvas._end_selection_drag), so an agent could delete and
## re-create a via — losing the id traces are authored against — but never move
## it; and net/size/drill could not be changed on ANY surface, GUI or MCP.
## "fabrication_stage" appeared zero times in the repo.
##
## REUSE SCAN: panel boot, check helpers and the mount pattern follow
## test_direct_copper_verbs.gd, which follows test_view_state.gd. Assertions
## read back through the MODEL (data.get_via, data.fabrication_stage) rather
## than trusting a verb's reply — the reply is the thing under test.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCBDataScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
## Preloaded, not a global: off-tree plugin scripts carry no class_name, so
## PcbNet is not in scope here the way it would be for a host script.
const PcbNet := preload("res://../../minerva-plugins/pcb/ui/model/pcb_net.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Via editing + fabrication stage (DCR 01a0033a12a9 ch. 2/3) ===\n")
	await _run_update_via_absent_key_means_unchanged()
	await _run_update_via_moves_and_move_via_delegates()
	await _run_update_via_argument_refusals()
	await _run_update_via_refusal_changes_nothing()
	await _run_growing_a_via_onto_a_trace_snaps_and_inherits()
	await _run_update_via_noop_is_success_not_refusal()
	await _run_fabrication_stage_defaults_to_routed()
	await _run_fabrication_stage_declares_and_refuses()
	await _run_fabrication_stage_round_trips_and_undoes()
	await _run_fabrication_stage_picker_is_the_gui_half()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


## Float comparison for any value that has passed through a SpinBox or a
## geometric projection. A SpinBox rounds to its `step`, so 0.4 comes back as
## 0.4000000000000000222 and `==` fails while printing "expected 0.4, got 0.4"
## — a failure message that tells you nothing, which is exactly how this was
## found. Not a weakening: the values under test here are mm dimensions, and
## is_equal_approx's epsilon is far below any dimension a fab could hold.
func check_approx(desc: String, actual: float, expected: float) -> void:
	check("%s (expected ~%s, got %s)" % [desc, str(expected), str(actual)],
		is_equal_approx(actual, expected))


class FakeEditor extends RefCounted:
	var tab_title: String = "ViaEditProbe"
	var associated_object: Variant = ""


## A panel MOUNTED IN THE REAL TREE. plugin_panel_driver.load_panel only calls
## script.new(), so _ready()/_build_ui() never run and every OptionButton stays
## null — which is exactly what these GUI assertions are about.
func _mount() -> Variant:
	var panel: Variant = load(PCB_PANEL_SCRIPT_PATH).new()
	get_root().add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(1100, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	for _i in range(6):
		await process_frame
	return panel


func _unmount(panel: Variant) -> void:
	if panel != null and panel is Node:
		(panel as Node).queue_free()
	await process_frame


func _ctx() -> Dictionary:
	var panel = await _mount()
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var data = panel.get_data()
	# Four layers, so "the span is always through" has something to be wrong
	# about; on a 2-layer board top<->bottom is the only span there is.
	if data != null and data.has_method("set_board_layers"):
		data.set_board_layers(["top", "in1", "in2", "bottom"])
	for net_name in ["GND", "N1", "N2"]:
		var net = PcbNet.new()
		net.name = net_name
		data.add_net(net)
	return {"panel": panel, "host": host, "data": data}


func _place(host, x: float, y: float, net_name: String = "") -> String:
	var args := {"x_mm": x, "y_mm": y}
	if not net_name.is_empty():
		args["net_name"] = net_name
	return str(PanelTools._place_via(host, args).get("via_id", ""))


# ── 1. an absent argument is not an instruction to clear the field ────────────

func _run_update_via_absent_key_means_unchanged() -> void:
	print("-- 1. absent key means UNCHANGED, never blanked --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var via_id := _place(host, 10.0, 12.0, "GND")
	var res: Dictionary = PanelTools._update_via(host, {"via_id": via_id, "net_name": "N1"})
	check("a net-only edit succeeds", bool(res.get("success", false)))

	# A partial edit that blanked the rest of the via is the failure mode this
	# whole contract exists to prevent, so every OTHER field is asserted.
	var stored: Dictionary = data.get_via(via_id)
	check_eq("the net changed", str(stored.get("net_name", "")), "N1")
	check_eq("the position did NOT", data.via_position(stored), Vector2(10.0, 12.0))
	check_eq("the size did NOT", float(stored.get("size", 0.0)), 0.8)
	check_eq("the drill did NOT", float(stored.get("drill", 0.0)), 0.4)
	check_eq("the span did NOT (from)", str(stored.get("from_layer", "")), "top")
	check_eq("the span did NOT (to)", str(stored.get("to_layer", "")), "bottom")
	check_eq("and the id is kept — delete-and-replace would have lost it",
		str(res.get("via_id", "")), via_id)

	# Now the geometry half, independently.
	var sized: Dictionary = PanelTools._update_via(host,
		{"via_id": via_id, "size_mm": 1.2, "drill_mm": 0.6})
	check("a size+drill edit succeeds", bool(sized.get("success", false)))
	stored = data.get_via(via_id)
	check_eq("size applied", float(stored.get("size", 0.0)), 1.2)
	check_eq("drill applied", float(stored.get("drill", 0.0)), 0.6)
	check_eq("the net survived the geometry edit", str(stored.get("net_name", "")), "N1")

	await _unmount(ctx["panel"])


# ── 2. it moves a via, and move_via is the same rule ──────────────────────────

func _run_update_via_moves_and_move_via_delegates() -> void:
	print("-- 2. update_via moves a via; move_via is position-only sugar over it --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var via_id := _place(host, 8.0, 8.0, "GND")
	var res: Dictionary = PanelTools._update_via(host,
		{"via_id": via_id, "x_mm": 20.0, "y_mm": 15.0})
	check("the move succeeds", bool(res.get("success", false)))
	check_eq("the model moved", data.via_position(data.get_via(via_id)), Vector2(20.0, 15.0))
	check("the reply reports it changed", bool(res.get("changed", false)))

	# ONE RULE, TWO ENTRY POINTS. The canvas drag calls move_via; if that stopped
	# routing through update_via the human and the agent would drift apart —
	# which is the exact defect class this epoch exists to close.
	var moved: Dictionary = data.move_via(via_id, Vector2(25.0, 5.0))
	check("move_via succeeds", bool(moved.get("ok", false)))
	check_eq("and moves the same model", data.via_position(data.get_via(via_id)), Vector2(25.0, 5.0))
	check("move_via reports the fields update_via reports",
		moved.has("size") and moved.has("drill") and moved.has("net_name"))

	# The journal names the edit ONCE, whatever it changed.
	var entries: Array = data.get_change_journal()
	var updates := 0
	for entry in entries:
		if str((entry as Dictionary).get("action", "")) == "update_via":
			updates += 1
	check("both edits journalled as update_via", updates >= 2)

	await _unmount(ctx["panel"])


# ── 3. argument refusals, by name ─────────────────────────────────────────────

func _run_update_via_argument_refusals() -> void:
	print("-- 3. every bad argument is refused by name, never coerced --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var via_id := _place(host, 10.0, 10.0, "GND")

	var unknown: Dictionary = PanelTools._update_via(host, {"via_id": "via_nope", "size_mm": 1.0})
	check("an unknown via_id refuses", not bool(unknown.get("success", true)))

	var nothing: Dictionary = PanelTools._update_via(host, {"via_id": via_id})
	check("an edit with no fields refuses rather than succeeding vacuously",
		not bool(nothing.get("success", true)))

	# A via moves as a POINT. One coordinate without the other would pair a new
	# value with a stale one and land copper somewhere nobody asked for.
	var half: Dictionary = PanelTools._update_via(host, {"via_id": via_id, "x_mm": 20.0})
	check("x_mm without y_mm refuses", not bool(half.get("success", true)))
	var half_y: Dictionary = PanelTools._update_via(host, {"via_id": via_id, "y_mm": 20.0})
	check("y_mm without x_mm refuses", not bool(half_y.get("success", true)))

	# float("nope") is 0.0 in GDScript, so a non-numeric argument that was
	# coerced instead of refused would shrink the via to nothing or move it to
	# the origin, silently.
	var texty: Dictionary = PanelTools._update_via(host, {"via_id": via_id, "size_mm": "big"})
	check("a non-numeric size refuses", not bool(texty.get("success", true)))

	for banned in ["from_layer", "to_layer", "layers"]:
		var args := {"via_id": via_id}
		args[banned] = "in1"
		var res: Dictionary = PanelTools._update_via(host, args)
		check("'%s' is refused" % banned, not bool(res.get("success", true)))
		check_eq("named span_not_selectable for '%s'" % banned,
			str(res.get("error", "")), "span_not_selectable")

	var undeclared: Dictionary = PanelTools._update_via(host,
		{"via_id": via_id, "net_name": "NOT_A_NET"})
	check("an undeclared net refuses", not bool(undeclared.get("success", true)))

	# NOTHING above may have touched the via.
	var stored: Dictionary = data.get_via(via_id)
	check_eq("after every refusal the position is untouched",
		data.via_position(stored), Vector2(10.0, 10.0))
	check_eq("...and the size", float(stored.get("size", 0.0)), 0.8)
	check_eq("...and the net", str(stored.get("net_name", "")), "GND")

	await _unmount(ctx["panel"])


# ── 4. validated in FULL before anything is applied ───────────────────────────

func _run_update_via_refusal_changes_nothing() -> void:
	print("-- 4. a refused multi-field edit leaves the via whole, not half-applied --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var via_id := _place(host, 12.0, 12.0, "GND")

	# A legal net + an ILLEGAL geometry in one call. If the fields were applied
	# as they were read, the net would land and the geometry would not — the
	# half-applied state the "validated in full" contract promises cannot exist.
	var res: Dictionary = PanelTools._update_via(host,
		{"via_id": via_id, "net_name": "N1", "size_mm": 0.4, "drill_mm": 0.9})
	check("drill wider than pad refuses", not bool(res.get("success", true)))
	check_eq("named via_not_placeable", str(res.get("error", "")), "via_not_placeable")

	var stored: Dictionary = data.get_via(via_id)
	check_eq("the NET did not land either", str(stored.get("net_name", "")), "GND")
	check_eq("the size is untouched", float(stored.get("size", 0.0)), 0.8)
	check_eq("the drill is untouched", float(stored.get("drill", 0.0)), 0.4)

	# Off the board is the other whole-edit refusal.
	var off: Dictionary = PanelTools._update_via(host,
		{"via_id": via_id, "x_mm": float(data.board_width) + 40.0, "y_mm": 5.0})
	check("a move off the board refuses", not bool(off.get("success", true)))
	check_eq("and the via stayed put", data.via_position(data.get_via(via_id)), Vector2(12.0, 12.0))

	await _unmount(ctx["panel"])


# ── 5. growing a via can move it, because copper touching copper is a junction ─

func _run_growing_a_via_onto_a_trace_snaps_and_inherits() -> void:
	print("-- 5. a via grown until it reaches a trace snaps to it and inherits its net --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	# A horizontal N2 run, and a NETLESS via parked just clear of it: 0.45mm off
	# the centreline, where a 0.8mm pad (radius 0.4) plus half a 0.25mm trace
	# (0.125) reaches only 0.525... so it DOES touch at 0.8. Place it further
	# out and grow it in.
	data.create_trace_entity("N2", "top",
		[Vector2(5.0, 11.0), Vector2(30.0, 11.0)], 0.25)
	var via_id := _place(host, 15.0, 12.0)
	var stored: Dictionary = data.get_via(via_id)
	check_eq("the via starts standalone and netless", str(stored.get("net_name", "")), "")
	check_eq("...at the point asked for", data.via_position(stored), Vector2(15.0, 12.0))

	# Capture radius is size*0.5 + width*0.5. At 0.8 that is 0.525 < 1.0 (clear).
	# At 2.0 it is 1.125 > 1.0 — the annulus now physically overlaps the trace.
	var grown: Dictionary = PanelTools._update_via(host, {"via_id": via_id, "size_mm": 2.0})
	check("the grow succeeds", bool(grown.get("success", false)))
	check("the reply SAYS it snapped rather than hiding it",
		bool(grown.get("snapped_to_trace", false)))

	stored = data.get_via(via_id)
	check_approx("it moved onto the trace centreline", data.via_position(stored).y, 11.0)
	check_approx("x is unchanged — it snapped, it did not slide", data.via_position(stored).x, 15.0)
	# The alternative is bug 01a003e2fb6e: an offset, netless hole that merely
	# LOOKS connected.
	check_eq("it inherited the trace's net", str(stored.get("net_name", "")), "N2")
	check_eq("and the reply reports the RESULT, not the request",
		str(grown.get("net_name", "")), "N2")

	await _unmount(ctx["panel"])


# ── 6. a no-op edit is success, not a refusal and not an undo step ────────────

func _run_update_via_noop_is_success_not_refusal() -> void:
	print("-- 6. re-applying the values a via already has is a successful no-op --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var via_id := _place(host, 9.0, 9.0, "GND")
	var before_history: int = data.history.size()

	var res: Dictionary = PanelTools._update_via(host,
		{"via_id": via_id, "x_mm": 9.0, "y_mm": 9.0, "net_name": "GND",
		 "size_mm": 0.8, "drill_mm": 0.4})
	check("it succeeds", bool(res.get("success", false)))
	# The distinction that matters: a caller must be able to tell "nothing
	# needed changing" from "I refused you".
	check("but reports changed:false", not bool(res.get("changed", true)))
	check_eq("and pushed NO undo step", data.history.size(), before_history)

	await _unmount(ctx["panel"])


# ── 8. the stage a board declares nothing about ───────────────────────────────

func _run_fabrication_stage_defaults_to_routed() -> void:
	print("-- 8. an undeclared board IS a routed board --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	check_eq("the model defaults to routed", str(data.fabrication_stage), "routed")

	var read: Dictionary = PanelTools._fabrication_stage(host, {})
	check("reading without a stage argument succeeds", bool(read.get("success", false)))
	check_eq("and reports routed", str(read.get("fabrication_stage", "")), "routed")
	check("routing is not deferred", not bool(read.get("routing_deferred", true)))
	check_eq("the reply names every stage a caller may pick",
		(read.get("known_stages", []) as Array).size(), 3)

	await _unmount(ctx["panel"])


# ── 9. declaring one, and the refusals that keep the declaration true ─────────

func _run_fabrication_stage_declares_and_refuses() -> void:
	print("-- 9. a stage can be declared, and vias_only must be TRUE to declare --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var vias_only: Dictionary = PanelTools._fabrication_stage(host, {"stage": "vias_only"})
	check("declaring vias_only on a traceless board succeeds",
		bool(vias_only.get("success", false)))
	check_eq("the model holds it", str(data.fabrication_stage), "vias_only")
	check("and the reply says routing is deferred", bool(vias_only.get("routing_deferred", false)))

	var unknown: Dictionary = PanelTools._fabrication_stage(host, {"stage": "vias-only"})
	check("a typo refuses rather than defaulting either way",
		not bool(unknown.get("success", true)))
	check_eq("named invalid_fabrication_stage",
		str(unknown.get("error", "")), "invalid_fabrication_stage")
	check_eq("and the declaration is unchanged", str(data.fabrication_stage), "vias_only")

	var wrong_type: Dictionary = PanelTools._fabrication_stage(host, {"stage": 7})
	check("a non-string stage refuses", not bool(wrong_type.get("success", true)))

	# Now give the board a trace. "vias_only" would be a FALSE declaration, and
	# without this refusal the two deferred stages are pure synonyms.
	data.set_fabrication_stage("routed")
	data.create_trace_entity("N1", "top", [Vector2(4.0, 4.0), Vector2(20.0, 4.0)], 0.25)
	var contradicted: Dictionary = PanelTools._fabrication_stage(host, {"stage": "vias_only"})
	check("vias_only refuses on a board that HAS traces",
		not bool(contradicted.get("success", true)))
	check("the refusal points at the stage that would be true",
		"routing_deferred" in str(contradicted.get("note", "")))
	check_eq("nothing was declared", str(data.fabrication_stage), "routed")

	var deferred: Dictionary = PanelTools._fabrication_stage(host, {"stage": "routing_deferred"})
	check("...and the looser stage IS accepted on that same board",
		bool(deferred.get("success", false)))
	check_eq("the model holds it", str(data.fabrication_stage), "routing_deferred")

	await _unmount(ctx["panel"])


# ── 10. it survives a save/load round trip, and an undo ───────────────────────

func _run_fabrication_stage_round_trips_and_undoes() -> void:
	print("-- 10. the declaration round-trips, is absent when routed, and undoes --")
	var ctx: Dictionary = await _ctx()
	var data = ctx["data"]

	# ABSENT when routed, so every board that predates this field serializes
	# byte-identically and no golden moves.
	check("a routed board emits no fabrication_stage key",
		not data.to_board_dict().has("fabrication_stage"))

	data.set_fabrication_stage("vias_only")
	var dict: Dictionary = data.to_board_dict()
	check_eq("a declared stage IS emitted", str(dict.get("fabrication_stage", "")), "vias_only")

	var fresh = PCBDataScript.new(100.0, 100.0)
	fresh.from_board_dict(dict)
	check_eq("and it survives the load", str(fresh.fabrication_stage), "vias_only")

	# A token this build does not know normalises to routed rather than being
	# carried — the conservative direction, where an unrouted net stays a defect.
	var bogus := dict.duplicate(true)
	bogus["fabrication_stage"] = "lased_later"
	var fresh2 = PCBDataScript.new(100.0, 100.0)
	fresh2.from_board_dict(bogus)
	check_eq("an unknown token loads as routed", str(fresh2.fabrication_stage), "routed")

	# Undo. The stage is a mutator, so a snapshot that omitted it would leave
	# the declaration behind while every other bucket rewound.
	data.set_fabrication_stage("routed")
	data.save_to_history("baseline")
	data.set_fabrication_stage("routing_deferred")
	data.save_to_history("declare")
	check_eq("declared before the undo", str(data.fabrication_stage), "routing_deferred")
	data.undo()
	check_eq("undo rewinds the declaration", str(data.fabrication_stage), "routed")

	await _unmount(ctx["panel"])


# ── 11. the GUI half of the declaration ───────────────────────────────────────

func _run_fabrication_stage_picker_is_the_gui_half() -> void:
	print("-- 11. the Fabrication picker declares a stage with no MCP call --")
	var ctx: Dictionary = await _ctx()
	var panel = ctx["panel"]
	var data = ctx["data"]

	# A via-only board is the fiber-laser customer's actual deliverable and the
	# owner drives this panel with buttons only, so an MCP-only declaration
	# would leave the person who most needs it unable to make it.
	check("the picker exists", panel._fabrication_stage_option != null)
	check_eq("offering exactly the three known stages",
		panel._fabrication_stage_option.item_count, 3)
	check("...and it is BOARD-level, so it is visible with nothing selected",
		panel._fabrication_stage_option.visible)

	# It shows what the board says, not a stale default.
	data.set_fabrication_stage("routing_deferred")
	panel._update_properties()
	check_eq("the picker follows the model",
		str(panel._fabrication_stage_option.get_item_metadata(
			panel._fabrication_stage_option.selected)), "routing_deferred")

	# DRIVE THE CONTROL. Find vias_only's index rather than assuming the order.
	var target := -1
	for i in range(panel._fabrication_stage_option.item_count):
		if str(panel._fabrication_stage_option.get_item_metadata(i)) == "vias_only":
			target = i
	check("vias_only is offered", target >= 0)
	panel._on_fabrication_stage_selected(target)
	check_eq("picking it declared it on the BOARD", str(data.fabrication_stage), "vias_only")

	await _unmount(ctx["panel"])
