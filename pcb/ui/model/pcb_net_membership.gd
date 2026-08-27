extends RefCounted
## The pin→net membership verbs, and the load-time report for a board that
## arrives already double-booked.
##
## ONE REPRESENTATION. Membership lives in each PCBNet's own `pins` list and
## nowhere else — there is no per-pin net field. get_nets walks that list;
## pin_info, the canvas pad labels and the route-intent guard all go through
## PCBData.find_net_for_pin, which walks the same list; to_board_dict() (and so
## pcb.serialize and export_yaml) emits it. So the three surfaces cannot
## disagree about WHAT the nets hold.
##
## They could still disagree about what a PIN holds, because find_net_for_pin
## answers with the first net it finds while get_nets/export_yaml show every
## net a pin is listed on. That gap only exists while a pin is on two nets, so
## it is closed at the two places a membership can be written: PCBData.
## connect_pin_to_net MOVES rather than adds, and a board loaded from outside is
## scanned by conflicts() and reported rather than silently resolved.
##
## Off-tree module — NO class_name, reached by relative preload.

const _PcbUndoStepScript := preload("pcb_undo_step.gd")


## Every net that currently lists this pin. Normally 0 or 1 entries — the plural
## form exists so a conflicted board (loaded from a source that listed the pin
## twice) is handled rather than half-handled. PCBData.find_net_for_pin is the
## singular hot-path form and stays allocation-free; this one is only reached
## from the two membership verbs.
static func nets_holding(data, component_id: String, pin_name: String) -> Array:
	var out: Array = []
	for net_name in data.nets:
		if data.nets[net_name].has_pin(component_id, pin_name):
			out.append(str(net_name))
	return out


## Move every named pin onto `net_name`, creating the net if it does not exist,
## as ONE undo step. `pins` is the verb's [{component, pin}] array.
##
## Returns {net_name, connected_pins, moved?} where `moved` is [{pin, from}] for
## each pin taken off another net — the one fact the caller cannot recover
## afterwards, since the previous membership is gone by the time it reads back.
static func connect_pins(data, net_name: String, pins: Array) -> Dictionary:
	var pairs := _pin_pairs(pins)
	var connected: Array = []
	var moved: Array = []
	for pair in pairs:
		var ref := "%s.%s" % [pair[0], pair[1]]
		connected.append(ref)
		for from in nets_holding(data, str(pair[0]), str(pair[1])):
			if str(from) != net_name:
				moved.append({"pin": ref, "from": str(from)})

	_PcbUndoStepScript.compose(data, _connect_label(net_name, pairs.size()),
		func() -> Variant:
			for pair in pairs:
				data.connect_pin_to_net(net_name, str(pair[0]), str(pair[1]))
			return null)

	var out := {"net_name": net_name, "connected_pins": connected}
	if not moved.is_empty():
		out["moved"] = moved
	return out


## Take every named pin off whatever net holds it, as ONE undo step.
##
## `expected_net`, when non-empty, is a GUARD, not a selector: a pin that is not
## on that net refuses the WHOLE call rather than being taken off the net the
## caller did not mean. A pin on no net at all is not an error — it is already
## in the asked-for state — and is reported under `not_connected`.
##
## Returns {disconnected: [{pin, net}], not_connected?} or a refusal
## {error, note, wrong_net} that mutates nothing.
static func disconnect_pins(data, pins: Array, expected_net: String = "") -> Dictionary:
	var pairs := _pin_pairs(pins)
	var plan: Array = []
	var not_connected: Array = []
	var wrong_net: Array = []
	for pair in pairs:
		var ref := "%s.%s" % [pair[0], pair[1]]
		var holders := nets_holding(data, str(pair[0]), str(pair[1]))
		if holders.is_empty():
			not_connected.append(ref)
			continue
		if not expected_net.is_empty() and not holders.has(expected_net):
			wrong_net.append({"pin": ref, "net": str(holders[0])})
			continue
		plan.append({"ref": ref, "pair": pair, "nets": holders})

	if not wrong_net.is_empty():
		return {
			"error": "pin_not_on_net",
			"note": "net_name is a guard: these pins are on a different net. "
				+ "Drop net_name to remove them from whatever net holds them.",
			"wrong_net": wrong_net,
		}

	var disconnected: Array = []
	for row in plan:
		for net_name in (row["nets"] as Array):
			disconnected.append({"pin": row["ref"], "net": str(net_name)})

	_PcbUndoStepScript.compose(data, _disconnect_label(plan),
		func() -> Variant:
			for row in plan:
				var pair: Array = row["pair"]
				for net_name in (row["nets"] as Array):
					data.disconnect_pin_from_net(str(net_name), str(pair[0]), str(pair[1]))
			return null)

	var out := {"disconnected": disconnected}
	if not not_connected.is_empty():
		out["not_connected"] = not_connected
	return out


## Pins a canonical board dict lists under more than one net, one sentence each,
## sorted by pin ref. A pin on two nets is a netlist short, and the live model
## answers "which net" arbitrarily for it — so a load NAMES it instead of
## letting whichever net happens to be read first become the answer, and instead
## of dropping a membership the source deliberately wrote. Empty for every board
## that holds the invariant.
static func conflicts(board: Dictionary) -> PackedStringArray:
	var holders := {}
	for entry in (board.get("nets", []) as Array):
		if not (entry is Dictionary):
			continue
		var net_name := str((entry as Dictionary).get("name", ""))
		for ref in ((entry as Dictionary).get("pins", []) as Array):
			var key := str(ref)
			if not holders.has(key):
				holders[key] = []
			# Deduped per net: the same pin written twice inside ONE net is not
			# a conflict (PCBNet.add_pin collapses it), only two DIFFERENT nets.
			if not (holders[key] as Array).has(net_name):
				(holders[key] as Array).append(net_name)

	var refs := holders.keys()
	refs.sort()
	var out := PackedStringArray()
	for ref in refs:
		var on: Array = holders[ref]
		if on.size() > 1:
			out.append("%s is listed on %d nets (%s) — a pin belongs to one net" % [
				str(ref), on.size(), ", ".join(PackedStringArray(on))])
	return out


## The held status-bar lead for conflicts(), or "" when there are none. Same
## shape and separator as pcb_load_checks.status_lead, which it sits in front
## of: a short-circuited netlist is the more urgent of the two.
static func conflict_status_lead(notes: PackedStringArray) -> String:
	if notes.is_empty():
		return ""
	return "NET CONFLICT: %s  •  " % "  •  ".join(notes)


## Normalise the verbs' [{component, pin}] argument array to [[comp, pin], …],
## dropping entries that do not name both.
static func _pin_pairs(pins: Array) -> Array:
	var out: Array = []
	for entry in pins:
		if not (entry is Dictionary):
			continue
		var comp := str((entry as Dictionary).get("component", ""))
		var pin := str((entry as Dictionary).get("pin", ""))
		if not comp.is_empty() and not pin.is_empty():
			out.append([comp, pin])
	return out


static func _connect_label(net_name: String, count: int) -> String:
	if count == 1:
		return "Connect pin to %s" % net_name
	return "Connect %d pins to %s" % [count, net_name]


static func _disconnect_label(plan: Array) -> String:
	if plan.size() == 1:
		return "Disconnect %s" % str((plan[0] as Dictionary)["ref"])
	return "Disconnect %d pins" % plan.size()
