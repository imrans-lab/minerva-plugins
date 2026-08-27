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
const _PcbPadRowScript := preload("pcb_pad_row.gd")


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
##
## VALIDATED BEFORE ANYTHING IS WRITTEN, and refused ALL-OR-NOTHING: a malformed
## entry is not dropped (that reports success for work nobody did) and a pin the
## board does not carry is not connected (that writes a ref into the netlist no
## component answers to, invisible until export). Refusals name themselves:
## invalid_pin, pin_not_found.
static func connect_pins(data, net_name: String, pins: Array) -> Dictionary:
	var checked := _pin_pairs_checked(pins)
	var invalid: Array = checked["invalid"]
	if not invalid.is_empty():
		return {
			"error": "invalid_pin",
			"note": "every entry needs both a component and a pin; nothing was connected",
			"invalid": invalid,
		}
	var pairs: Array = checked["pairs"]
	var missing: Array = []
	for pair in pairs:
		if not _board_has_pin(data, str(pair[0]), str(pair[1])):
			missing.append("%s.%s" % [pair[0], pair[1]])
	if not missing.is_empty():
		return {
			"error": "pin_not_found",
			"note": "the board carries no such pin; nothing was connected",
			"pins": missing,
		}
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
		# THE GUARD NARROWS WHAT IS REMOVED, not just what is allowed. On a
		# conflicted board a pin can be listed on two nets, and "take it off
		# GND" must leave the other membership exactly where it was — removing
		# both would silently resolve a conflict the caller never mentioned.
		var targets: Array = [expected_net] if not expected_net.is_empty() else holders
		plan.append({"ref": ref, "pair": pair, "nets": targets})

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


## MOVE one pin's net onto another pin, as ONE undo step — the "Move net to…"
## act on a pad selection. The source pin comes off the net and the destination
## pin goes on it; a destination that was on some OTHER net is taken off it
## (connect_pin_to_net's own move rule) and that displacement is REPORTED,
## because it is the one fact the caller cannot read back afterwards.
##
## Refusals mutate nothing and name themselves: same_pin, pin_not_found,
## pin_has_no_net (there is no net to move).
static func move_net(data, from_ref: String, to_ref: String) -> Dictionary:
	if from_ref == to_ref:
		return {"error": "same_pin", "note": "source and destination are the same pin"}
	var from_pair := _ref_pair(data, from_ref)
	if from_pair.is_empty():
		return {"error": "pin_not_found", "pin": from_ref}
	var to_pair := _ref_pair(data, to_ref)
	if to_pair.is_empty():
		return {"error": "pin_not_found", "pin": to_ref}

	var holders := nets_holding(data, str(from_pair[0]), str(from_pair[1]))
	if holders.is_empty():
		return {"error": "pin_has_no_net", "pin": from_ref,
			"note": "there is no net on %s to move — connect it first" % from_ref}
	# A CONFLICTED SOURCE IS REFUSED BY NAME. Taking holders[0] picks by
	# Dictionary iteration order, so which of the two nets moved would depend on
	# how the board was loaded — and the other one would be silently dropped off
	# the pin as well. Both are named so the caller can say which it meant.
	if holders.size() > 1:
		return {"error": "pin_on_multiple_nets", "pin": from_ref, "nets": holders,
			"note": "%s is listed on %d nets (%s) — disconnect it from all but the "
				% [from_ref, holders.size(), ", ".join(PackedStringArray(holders))]
				+ "one you mean before moving it"}
	var net_name := str(holders[0])
	var displaced: Array = []
	for other in nets_holding(data, str(to_pair[0]), str(to_pair[1])):
		if str(other) != net_name:
			displaced.append({"pin": to_ref, "from": str(other)})

	_PcbUndoStepScript.compose(data, "Move %s to %s" % [net_name, to_ref],
		func() -> Variant:
			for held in holders:
				data.disconnect_pin_from_net(str(held), str(from_pair[0]), str(from_pair[1]))
			data.connect_pin_to_net(net_name, str(to_pair[0]), str(to_pair[1]))
			return null)

	var out := {"net_name": net_name, "from": from_ref, "to": to_ref}
	if not displaced.is_empty():
		out["displaced"] = displaced
	return out


## EXCHANGE the nets of two pins, as ONE undo step — the BTN3/BTN4 swap the
## owner does by hand today. A pin on no net is a legal side of the swap (the
## other pin's net moves to it and it gives back nothing), but two netless pins
## have nothing to exchange and are refused.
##
## Refusals mutate nothing and name themselves: same_pin, pin_not_found,
## nothing_to_swap, already_same_net.
static func swap_nets(data, ref_a: String, ref_b: String) -> Dictionary:
	if ref_a == ref_b:
		return {"error": "same_pin", "note": "a pin cannot swap nets with itself"}
	var pair_a := _ref_pair(data, ref_a)
	if pair_a.is_empty():
		return {"error": "pin_not_found", "pin": ref_a}
	var pair_b := _ref_pair(data, ref_b)
	if pair_b.is_empty():
		return {"error": "pin_not_found", "pin": ref_b}

	var held_a := nets_holding(data, str(pair_a[0]), str(pair_a[1]))
	var held_b := nets_holding(data, str(pair_b[0]), str(pair_b[1]))
	if held_a.is_empty() and held_b.is_empty():
		return {"error": "nothing_to_swap", "note":
			"neither %s nor %s is on a net" % [ref_a, ref_b]}
	# Same refusal as move_net's, and for the same reason: a pin on two nets has
	# no single net to give, and held_x[0] would pick one by load order.
	for side in [[ref_a, held_a], [ref_b, held_b]]:
		var held: Array = side[1]
		if held.size() > 1:
			return {"error": "pin_on_multiple_nets", "pin": str(side[0]), "nets": held,
				"note": "%s is listed on %d nets (%s) — a swap has no single net to "
					% [str(side[0]), held.size(), ", ".join(PackedStringArray(held))]
					+ "exchange until that is resolved"}
	var net_a := str(held_a[0]) if not held_a.is_empty() else ""
	var net_b := str(held_b[0]) if not held_b.is_empty() else ""
	if net_a == net_b:
		return {"error": "already_same_net", "net_name": net_a,
			"note": "both pins are already on %s — a swap would change nothing" % net_a}

	_PcbUndoStepScript.compose(data, "Swap nets %s / %s" % [ref_a, ref_b],
		func() -> Variant:
			# Both memberships come off FIRST: connecting one pin before the
			# other has let go would hand connect_pin_to_net a pin that is
			# still on the net it is about to receive.
			for held in held_a:
				data.disconnect_pin_from_net(str(held), str(pair_a[0]), str(pair_a[1]))
			for held in held_b:
				data.disconnect_pin_from_net(str(held), str(pair_b[0]), str(pair_b[1]))
			if not net_b.is_empty():
				data.connect_pin_to_net(net_b, str(pair_a[0]), str(pair_a[1]))
			if not net_a.is_empty():
				data.connect_pin_to_net(net_a, str(pair_b[0]), str(pair_b[1]))
			return null)

	return {"swapped": [
		{"pin": ref_a, "was": net_a, "now": net_b},
		{"pin": ref_b, "was": net_b, "now": net_a},
	]}


## "REF.PIN" → [component_id, pin] when the board really carries that pin,
## else []. The two verbs above address pins the way the pad row and the canvas
## selection do, rather than by a second {component, pin} argument shape.
static func _ref_pair(data, ref: String) -> Array:
	var parts := _PcbPadRowScript.parse_ref(ref)
	if parts.is_empty() or data == null:
		return []
	var comp = data.get_component(str(parts[0]))
	if comp == null or not comp.pins.has(str(parts[1])):
		return []
	return [str(parts[0]), str(parts[1])]


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


## True when `data` really carries this component's pin. The membership verbs
## address pins by {component, pin}, so this is the by-parts form of the check
## _ref_pair does for a "REF.PIN" string.
static func _board_has_pin(data, component_id: String, pin_name: String) -> bool:
	if data == null:
		return false
	var comp = data.get_component(component_id)
	return comp != null and comp.pins.has(pin_name)


## _pin_pairs, plus the entries it could not read: {pairs: [[comp, pin], …],
## invalid: [<the offending entry, described>]}. A caller that must refuse a
## malformed entry rather than drop it reads this one.
static func _pin_pairs_checked(pins: Array) -> Dictionary:
	var pairs: Array = []
	var invalid: Array = []
	for entry in pins:
		if not (entry is Dictionary):
			invalid.append(str(entry))
			continue
		var comp := str((entry as Dictionary).get("component", ""))
		var pin := str((entry as Dictionary).get("pin", ""))
		if comp.is_empty() or pin.is_empty():
			invalid.append(str(entry))
			continue
		pairs.append([comp, pin])
	return {"pairs": pairs, "invalid": invalid}


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
