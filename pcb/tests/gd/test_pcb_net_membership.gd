extends SceneTree
## A PIN BELONGS TO AT MOST ONE NET.
##
## Before this station minerva_pcb_connect_net was additive: reassigning a pin
## left it on BOTH nets. That is a netlist short, and it is one the surfaces
## report differently — get_nets and the exported YAML list the pin under both,
## while pin_info (via PCBData.find_net_for_pin) picks whichever net comes
## first. The reassignment was also not an undo step at all: _connect_net never
## called save_to_history, so Ctrl+Z after a connect reverted whatever came
## BEFORE it.
##
## THE ORACLE this suite is built on is agreement between three INDEPENDENT
## readers of the board, never one of them restated:
##   * get_nets        — walks each PCBNet.pins
##   * pin_info        — PCBData.find_net_for_pin + the net's members
##   * export_yaml     — the board dict actually handed to the pcb.serialize
##                       channel, read out of the captured IPC payload (this is
##                       the real to_board_dict() the worker would turn into
##                       YAML — nothing about it is stubbed but the transport)
## A move that only some of them see fails here.
##
## RED against the old model: section 1's "GND no longer lists it" checks (all
## three readers), the one-undo checks, every history-depth check, and all of
## sections 3-5 (minerva_pcb_disconnect_net did not exist; neither did
## pcb_net_membership.gd / pcb_undo_step.gd). Section 2's shape checks on
## connect_net's reply are green before and after — connected_pins and success
## did not move.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_pcb_net_membership.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const Membership := preload("res://../../minerva-plugins/pcb/ui/model/pcb_net_membership.gd")
const UndoStep := preload("res://../../minerva-plugins/pcb/ui/model/pcb_undo_step.gd")

var _pass := 0
var _fail := 0


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


class FakeEditor extends RefCounted:
	var tab_title: String = "PCB Net Membership"


## Captures the payload of every plugin IPC request and answers with a canned
## envelope. The captured pcb.serialize payload IS the export_yaml oracle: it
## carries the board dict to_board_dict() produced, which is exactly what the
## worker would serialize.
class FakeIPC extends Node:
	var captured: Array = []
	var reply: Dictionary = {"success": true,
		"result": {"ok": true, "result": {"yaml": "name: fixture\n"}}}
	var _reply_id := ""

	func bind(panel_node) -> void:
		name = "_MinervaIPC"
		panel_node.add_child(self)
		panel_node.request.connect(_on_request)

	func _on_request(channel: String, payload: Dictionary, reply_id: String) -> void:
		captured.append({"channel": channel, "payload": payload})
		_reply_id = reply_id

	func last(channel: String) -> Dictionary:
		for i in range(captured.size() - 1, -1, -1):
			if str(captured[i]["channel"]) == channel:
				return captured[i]["payload"]
		return {}

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id:
			return {"success": false, "error_code": "timeout",
				"error_message": "no captured request"}
		return reply.duplicate(true)


# ── Fixture ───────────────────────────────────────────────────────────────────

## U1.5 + U2.1 on GND, U3.1 on SDA, U1.6 on nothing. Every net keeps a second
## member so a move can never be confused with a net disappearing.
func _fixture_board() -> Dictionary:
	return {
		"version": 1, "name": "membership", "width_mm": 40.0, "height_mm": 30.0,
		"layers": ["top", "bottom"],
		"components": [
			_comp("U1", 5.0, 5.0, ["5", "6"]),
			_comp("U2", 15.0, 5.0, ["1"]),
			_comp("U3", 25.0, 5.0, ["1"]),
		],
		"nets": [
			{"name": "GND", "pins": ["U1.5", "U2.1"]},
			{"name": "SDA", "pins": ["U3.1"]},
		],
	}


func _comp(ref: String, x: float, y: float, pins: Array) -> Dictionary:
	var pin_defs: Array = []
	var offset := 0.0
	for number in pins:
		pin_defs.append({"number": str(number), "x_mm": offset, "y_mm": 0.0,
			"pad_width_mm": 0.6, "pad_height_mm": 0.6})
		offset += 1.27
	return {"ref": ref, "footprint": "", "x_mm": x, "y_mm": y,
		"rotation_deg": 0, "layer": "top", "pins": pin_defs}


var _panel: Variant = null
var _ipc: FakeIPC = null


func _rig(board: Dictionary) -> void:
	_teardown()
	_panel = load(PANEL_PATH).new()
	get_root().add_child(_panel)
	_panel.position = Vector2.ZERO
	_panel.size = Vector2(900, 600)
	_panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	_panel.get_data().from_board_dict(board)
	_ipc = FakeIPC.new()
	_ipc.bind(_panel)
	await process_frame


func _teardown() -> void:
	if _panel != null:
		_panel.queue_free()
		_panel = null
		_ipc = null


func _data():
	return _panel.get_data()


# ── The three readers ─────────────────────────────────────────────────────────

## Reader 1: minerva_pcb_get_nets, as {net_name: [pin refs]}.
func _nets_from_verb() -> Dictionary:
	var reply: Dictionary = await _panel.handle_tool("minerva_pcb_get_nets", {})
	var out := {}
	for net in (reply.get("nets", []) as Array):
		out[str((net as Dictionary).get("name", ""))] = (net as Dictionary).get("pins", [])
	return out


## Reader 2: minerva_pcb_pin_info's own answer for one pin.
func _net_from_pin_info(ref: String) -> String:
	var reply: Dictionary = await _panel.handle_tool("minerva_pcb_pin_info", {"ref": ref})
	return str(reply.get("net", "<no reply>"))


## Reader 2b: the members pin_info reports for a pin, which is where a stale
## membership on ANOTHER pin's net would still show.
func _members_from_pin_info(ref: String) -> Array:
	var reply: Dictionary = await _panel.handle_tool("minerva_pcb_pin_info", {"ref": ref})
	return reply.get("net_members", [])


## Reader 3: the board dict export_yaml actually sends to pcb.serialize,
## as {net_name: [pin refs]}.
func _nets_from_export() -> Dictionary:
	await _panel.handle_tool("minerva_pcb_export_yaml", {})
	var payload: Dictionary = _ipc.last("pcb.serialize")
	var board: Dictionary = payload.get("board", {})
	var out := {}
	for net in (board.get("nets", []) as Array):
		out[str((net as Dictionary).get("name", ""))] = (net as Dictionary).get("pins", [])
	return out


## All three readers at once: does `ref` sit on `net` according to each?
## Returns [get_nets, pin_info, export_yaml] as bools.
func _on_net_per_reader(ref: String, net: String) -> Array:
	var by_verb: Dictionary = await _nets_from_verb()
	var by_export: Dictionary = await _nets_from_export()
	var by_pin_info: String = await _net_from_pin_info(ref)
	return [
		(by_verb.get(net, []) as Array).has(ref),
		by_pin_info == net,
		(by_export.get(net, []) as Array).has(ref),
	]


func _init() -> void:
	print("=== A pin belongs to at most one net ===\n")
	await process_frame
	await _run_connect_moves()
	await _run_reply_shape_and_one_step()
	await _run_disconnect()
	await _run_load_conflicts()
	await _run_undo_step_helper()
	await _run_refusals_write_nothing()
	_teardown()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── 1: connect MOVES, all three readers agree, ONE undo restores ─────────────

func _run_connect_moves() -> void:
	print("-- 1: connect moves the pin, and one undo puts it back --")
	await _rig(_fixture_board())
	var data = _data()

	var before: Array = await _on_net_per_reader("U1.5", "GND")
	check("1a: fixture — all three readers start with U1.5 on GND",
		before == [true, true, true], str(before))

	var depth_before: int = data.history.size()
	var reply: Dictionary = await _panel.handle_tool("minerva_pcb_connect_net",
		{"net_name": "SDA", "pins": [{"component": "U1", "pin": "5"}]})
	check("1b: the move succeeds", bool(reply.get("success", false)), str(reply))
	check_eq("1b: …and names what it took off another net",
		str(reply.get("moved", [])), str([{"pin": "U1.5", "from": "GND"}]))

	# THE DEFECT, stated three ways. Additively connecting leaves GND listing
	# U1.5 in the first and third, while the second silently picks one.
	var gnd_after: Array = await _on_net_per_reader("U1.5", "GND")
	check("1c: GND no longer lists U1.5 — get_nets, pin_info AND export_yaml",
		gnd_after == [false, false, false], str(gnd_after))
	var sda_after: Array = await _on_net_per_reader("U1.5", "SDA")
	check("1c: …and all three now put it on SDA",
		sda_after == [true, true, true], str(sda_after))
	var gnd_members: Array = await _members_from_pin_info("U2.1")
	check("1c: GND's remaining member does not still count U1.5 as a neighbour",
		not gnd_members.has("U1.5"), str(gnd_members))

	# ONE step: the move added exactly one snapshot, and one undo reverts it.
	check_eq("1d: the whole move is ONE history step",
		data.history.size(), depth_before + 1)
	var undo: Dictionary = await _panel.handle_tool("minerva_pcb_undo", {})
	check("1d: undo succeeds", bool(undo.get("success", false)), str(undo))
	var restored: Array = await _on_net_per_reader("U1.5", "GND")
	check("1d: ONE undo restores GND in all three readers",
		restored == [true, true, true], str(restored))
	var sda_restored: Array = await _on_net_per_reader("U1.5", "SDA")
	check("1d: …and SDA no longer lists it in any of them",
		sda_restored == [false, false, false], str(sda_restored))

	var redo: Dictionary = await _panel.handle_tool("minerva_pcb_redo", {})
	check("1e: redo succeeds", bool(redo.get("success", false)), str(redo))
	var redone: Array = await _on_net_per_reader("U1.5", "SDA")
	check("1e: redo re-applies the move everywhere",
		redone == [true, true, true], str(redone))


# ── 2: reply shape, no-op guard, and N pins in one step ─────────────────────

func _run_reply_shape_and_one_step() -> void:
	print("\n-- 2: reply shape, the no-op guard, and N pins in one step --")
	await _rig(_fixture_board())
	var data = _data()
	var load_depth: int = data.history.size()

	# Green before AND after: the established reply keys did not move.
	var fresh: Dictionary = await _panel.handle_tool("minerva_pcb_connect_net",
		{"net_name": "VCC", "pins": [
			{"component": "U1", "pin": "6"}, {"component": "U3", "pin": "1"}]})
	check_eq("2a: connected_pins still lists every pin asked for",
		str(fresh.get("connected_pins", [])), str(["U1.6", "U3.1"]))
	check_eq("2a: net_name still echoed", str(fresh.get("net_name", "")), "VCC")
	check_eq("2a: the pin that came off SDA is named, the unconnected one is not",
		str(fresh.get("moved", [])), str([{"pin": "U3.1", "from": "SDA"}]))

	var after_two: int = data.history.size()
	check_eq("2b: two pins moved in one call is still ONE history step",
		after_two, load_depth + 1)

	# Re-asking for a membership that already holds writes nothing at all: no
	# journal row, no history step, no revision bump.
	var journal_before: int = data.get_change_journal().size()
	var revision_before: int = int(data.board_revision)
	var again: Dictionary = await _panel.handle_tool("minerva_pcb_connect_net",
		{"net_name": "VCC", "pins": [{"component": "U1", "pin": "6"}]})
	check("2c: re-connecting a pin to the net it is already on succeeds",
		bool(again.get("success", false)), str(again))
	check("2c: …reports nothing moved", not again.has("moved"), str(again))
	check_eq("2c: …writes no journal row", data.get_change_journal().size(), journal_before)
	check_eq("2c: …leaves no history step", data.history.size(), after_two)
	check_eq("2c: …and does not bump the board revision",
		int(data.board_revision), revision_before)


# ── 3: minerva_pcb_disconnect_net ────────────────────────────────────────────

func _run_disconnect() -> void:
	print("\n-- 3: disconnect takes a pin off its net --")
	await _rig(_fixture_board())
	var data = _data()

	var depth_before: int = data.history.size()
	var out: Dictionary = await _panel.handle_tool("minerva_pcb_disconnect_net",
		{"pins": [{"component": "U2", "pin": "1"}]})
	check("3a: the disconnect succeeds", bool(out.get("success", false)), str(out))
	check_eq("3a: …naming the pin and the net it came off",
		str(out.get("disconnected", [])), str([{"pin": "U2.1", "net": "GND"}]))

	var gone: Array = await _on_net_per_reader("U2.1", "GND")
	check("3b: GND lists it in none of the three readers",
		gone == [false, false, false], str(gone))
	var no_net: String = await _net_from_pin_info("U2.1")
	check_eq("3b: pin_info reports no net at all", no_net, "")
	var surviving: Dictionary = await _nets_from_verb()
	check("3b: …while GND itself survives with its other member",
		(surviving.get("GND", []) as Array).has("U1.5"), str(surviving))

	check_eq("3c: the disconnect is ONE history step",
		data.history.size(), depth_before + 1)
	await _panel.handle_tool("minerva_pcb_undo", {})
	var back: Array = await _on_net_per_reader("U2.1", "GND")
	check("3c: ONE undo restores the membership in all three readers",
		back == [true, true, true], str(back))

	# THE GUARD. net_name states a belief; a stale one refuses the whole call.
	var depth_guard: int = data.history.size()
	var refused: Dictionary = await _panel.handle_tool("minerva_pcb_disconnect_net",
		{"pins": [{"component": "U3", "pin": "1"}], "net_name": "GND"})
	check("3d: a pin on a different net refuses",
		not bool(refused.get("success", true)), str(refused))
	check_eq("3d: …by name", str(refused.get("error", "")), "pin_not_on_net")
	check_eq("3d: …saying which net actually holds it",
		str(refused.get("wrong_net", [])), str([{"pin": "U3.1", "net": "SDA"}]))
	check_eq("3d: …and mutates nothing", data.history.size(), depth_guard)
	var still_sda: String = await _net_from_pin_info("U3.1")
	check_eq("3d: …the pin is still on SDA", still_sda, "SDA")

	# A pin on no net is already in the asked-for state, not an error.
	var journal_before: int = data.get_change_journal().size()
	var idle: Dictionary = await _panel.handle_tool("minerva_pcb_disconnect_net",
		{"pins": [{"component": "U1", "pin": "6"}]})
	check("3e: disconnecting an unconnected pin succeeds",
		bool(idle.get("success", false)), str(idle))
	check_eq("3e: …reporting it under not_connected",
		str(idle.get("not_connected", [])), str(["U1.6"]))
	check_eq("3e: …and writing nothing",
		data.get_change_journal().size(), journal_before)
	check_eq("3e: …no history step either", data.history.size(), depth_guard)


# ── 4: a board that arrives double-booked is REPORTED, not resolved ──────────

func _run_load_conflicts() -> void:
	print("\n-- 4: a conflicted source is named, and reconnecting heals it --")
	var clean: PackedStringArray = Membership.conflicts(_fixture_board())
	check("4a: a board holding the invariant reports nothing",
		clean.is_empty(), str(clean))
	check_eq("4a: …and holds no status lead",
		Membership.conflict_status_lead(clean), "")

	var conflicted: Dictionary = _fixture_board()
	conflicted["nets"] = [
		{"name": "GND", "pins": ["U1.5", "U2.1"]},
		{"name": "SDA", "pins": ["U3.1", "U1.5"]},
	]
	var notes: PackedStringArray = Membership.conflicts(conflicted)
	check_eq("4b: the double-booked pin is reported once", notes.size(), 1)
	check("4b: …naming the pin and both nets",
		notes.size() == 1 and str(notes[0]).contains("U1.5")
			and str(notes[0]).contains("GND") and str(notes[0]).contains("SDA"),
		str(notes))
	check("4b: …and leads the status line",
		Membership.conflict_status_lead(notes).begins_with("NET CONFLICT:"),
		Membership.conflict_status_lead(notes))

	# A pin written TWICE inside one net is not a conflict — the model dedupes it.
	var repeated: Dictionary = _fixture_board()
	repeated["nets"] = [{"name": "GND", "pins": ["U1.5", "U1.5"]}]
	var repeated_notes: PackedStringArray = Membership.conflicts(repeated)
	check("4c: the same pin twice inside ONE net is not a conflict",
		repeated_notes.is_empty(), str(repeated_notes))

	# HEALING: the move sweeps EVERY foreign membership, not just the first one
	# find_net_for_pin happens to return.
	await _rig(conflicted)
	var data = _data()
	check_eq("4d: the conflicted board really does list U1.5 twice",
		Membership.nets_holding(data, "U1", "5").size(), 2)
	await _panel.handle_tool("minerva_pcb_connect_net",
		{"net_name": "I2C", "pins": [{"component": "U1", "pin": "5"}]})
	check_eq("4d: reconnecting leaves exactly one membership",
		str(Membership.nets_holding(data, "U1", "5")), str(["I2C"]))
	var healed: Dictionary = await _nets_from_export()
	check("4d: …and the exported board agrees with get_nets and pin_info",
		not (healed.get("GND", []) as Array).has("U1.5")
			and not (healed.get("SDA", []) as Array).has("U1.5")
			and (healed.get("I2C", []) as Array).has("U1.5"),
		str(healed))


# ── 5: the undo-composition helper ──────────────────────────────────────────

func _run_undo_step_helper() -> void:
	print("\n-- 5: N mutations, one undo step --")
	await _rig(_fixture_board())
	var data = _data()

	var depth_before: int = data.history.size()
	var returned: Variant = UndoStep.compose(data, "Rewire three pins", func() -> Variant:
		data.connect_pin_to_net("I2C", "U1", "5")
		data.connect_pin_to_net("I2C", "U2", "1")
		data.connect_pin_to_net("I2C", "U3", "1")
		return "done")
	check_eq("5a: compose returns the body's own value", str(returned), "done")
	check_eq("5a: three mutations leave ONE history step",
		data.history.size(), depth_before + 1)
	check_eq("5a: …wearing the label it was given",
		str((data.history[data.history_index] as Dictionary).get("action", "")),
		"Rewire three pins")

	await _panel.handle_tool("minerva_pcb_undo", {})
	var reverted: Dictionary = await _nets_from_verb()
	check("5b: one undo reverts all three moves at once",
		(reverted.get("GND", []) as Array).has("U1.5")
			and (reverted.get("GND", []) as Array).has("U2.1")
			and (reverted.get("SDA", []) as Array).has("U3.1"),
		str(reverted))

	# A body that mutates nothing must not leave a step behind — otherwise a
	# refused verb would fill the history with reverts that do nothing.
	var depth_quiet: int = data.history.size()
	UndoStep.compose(data, "Touches nothing", func() -> Variant: return null)
	check_eq("5c: a body that mutates nothing leaves no history step",
		data.history.size(), depth_quiet)


# ── 6: a membership write that cannot be done is refused, not half-done ──────
#
# Every case here used to WRITE. connect_net dropped a malformed entry and
# reported success for it, and happily listed a pin no component carries — a ref
# the netlist keeps and nothing on the board answers to, invisible until export.
# The disconnect guard removed EVERY membership of a conflicted pin rather than
# the one it was told about, silently resolving a conflict nobody mentioned. And
# move/swap read holders[0] on such a pin: which net moved depended on load
# order, and the other membership was dropped along the way.

func _conflicted_board() -> Dictionary:
	var board: Dictionary = _fixture_board()
	board["nets"] = [
		{"name": "GND", "pins": ["U1.5", "U2.1"]},
		{"name": "SDA", "pins": ["U3.1", "U1.5"]},
	]
	return board


func _run_refusals_write_nothing() -> void:
	print("\n-- 6: refusals write nothing --")
	await _rig(_fixture_board())
	var data = _data()
	var depth_before: int = data.history.size()

	var nope: Dictionary = await _panel.handle_tool("minerva_pcb_connect_net",
		{"net_name": "GND", "pins": [
			{"component": "U1", "pin": "6"}, {"component": "NOPE", "pin": "1"}]})
	check("6a: a pin the board does not carry refuses the call",
		not bool(nope.get("success", true)), str(nope))
	check_eq("6a: by name", str(nope.get("error", "")), "pin_not_found")
	check("6a: naming the pin it could not find",
		str(nope.get("pins", [])).contains("NOPE.1"), str(nope))
	var after_bad: Dictionary = await _nets_from_verb()
	check("6a: the VALID pin in the same call was not connected — all or nothing",
		not (after_bad.get("GND", []) as Array).has("U1.6"), str(after_bad))
	check("6a: and the netlist gained no ref no component answers to",
		not (after_bad.get("GND", []) as Array).has("NOPE.1"), str(after_bad))
	check_eq("6a: no history step was written", data.history.size(), depth_before)

	var bad: Dictionary = await _panel.handle_tool("minerva_pcb_connect_net",
		{"net_name": "GND", "pins": [{"component": "U1"}]})
	check("6b: an entry naming no pin refuses, rather than being dropped",
		not bool(bad.get("success", true)), str(bad))
	check_eq("6b: by name", str(bad.get("error", "")), "invalid_pin")
	check_eq("6b: still no history step", data.history.size(), depth_before)

	# ── the guard NARROWS the removal ────────────────────────────────────────
	await _rig(_conflicted_board())
	var conflicted_data = _data()
	check_eq("6c: the fixture really lists U1.5 on two nets",
		Membership.nets_holding(conflicted_data, "U1", "5").size(), 2)
	var off: Dictionary = await _panel.handle_tool("minerva_pcb_disconnect_net",
		{"net_name": "GND", "pins": [{"component": "U1", "pin": "5"}]})
	check("6c: the guarded disconnect succeeds", bool(off.get("success", false)), str(off))
	check_eq("6c: ONLY the named net's membership went",
		str(Membership.nets_holding(conflicted_data, "U1", "5")), str(["SDA"]))
	check_eq("6c: and the reply names only that one removal",
		str(off.get("disconnected", [])), str([{"pin": "U1.5", "net": "GND"}]))

	# ── move / swap refuse a source that is on two nets ──────────────────────
	await _rig(_conflicted_board())
	var two_net = _data()
	var moved: Dictionary = Membership.move_net(two_net, "U1.5", "U3.1")
	check_eq("6d: move_net refuses a pin held by two nets",
		str(moved.get("error", "")), "pin_on_multiple_nets")
	check("6d: naming BOTH nets rather than picking by load order",
		str(moved.get("nets", [])).contains("GND") and str(moved.get("nets", [])).contains("SDA"),
		str(moved))
	check_eq("6d: and it moved nothing",
		Membership.nets_holding(two_net, "U1", "5").size(), 2)

	var swapped: Dictionary = Membership.swap_nets(two_net, "U1.5", "U2.1")
	check_eq("6e: swap_nets refuses the same source for the same reason",
		str(swapped.get("error", "")), "pin_on_multiple_nets")
	check_eq("6e: naming the pin", str(swapped.get("pin", "")), "U1.5")
	check_eq("6e: and swapped nothing",
		str(Membership.nets_holding(two_net, "U2", "1")), str(["GND"]))
