extends RefCounted
## WHAT A PROMOTION CHANGES IN THE DESIGN OF RECORD.
##
## promote() already deserializes the file it is about to overwrite — the copper
## regression guard needs the prior board — so the prior design and the live
## design are both in hand at that moment, and everything below rides on data
## that is already there: no extra read, no extra worker hop.
##
## WHY IT EXISTS, the mechanism in one line: entity COUNTS cannot show a
## changed field — re-valuing U3 from 10k to 22k leaves every count on the
## board identical — so the promotion that overwrites a hand-edit on disk and
## the promotion that changes nothing produce the same numbers. This names the
## ref and the field instead.
##
## ADVISORY, never gating. Nothing here can refuse a write: promotion stays
## gated on the worker's correctness findings alone. This is the report that
## rides the reply and the status line.
##
## Every function is static and takes board dicts only — no panel, no worker, no
## file — so the whole comparison is exercisable headlessly.


## The sidecar's canonical stringifier, reused rather than copied: a
## representation-independent text for any JSON-ish value, so 180 against 180.0
## (a YAML round trip floats every number) and two dictionary literals built in
## different orders do not read as an edit. Its set-sorting of all-Dictionary
## arrays is right here too — an assembly `placements` list is a set of physical
## instances, not a sequence.
const PcbRoutingSidecar := preload("model/pcb_routing_sidecar.gd")


## The authored per-component fields compared by string identity.
##
## THE KNOWN LIMIT, stated: `pins`, `pads` and `graphics` are NOT compared.
## They are the geometry half of a component — pin-level overrides of a
## resolved land, and the copper/artwork a `pads`-authored board owns outright
## — and they are arrays whose from/to would swamp the report a person reads.
## A promotion that changes only pad geometry therefore reports no field here.
## `refdes_placement` (where the designator sits) is out for the same reason it
## is not identity: it moves silkscreen, not the part.
const TEXT_FIELDS := ["value", "footprint", "layer", "symbol", "group_id"]

## The authored per-component fields compared as millimetres/degrees.
const NUMERIC_FIELDS := ["x_mm", "y_mm", "rotation_deg"]

## Below this two numbers are the same quantity written differently — the
## file's decimals against the model's float — not a move. Tighter than any
## fabricable tolerance, so a real edit is never rounded away.
const EPS := 1e-6


## The delta between the file being overwritten and the board being written.
##
## Shape (every key always present, so "nothing changed" is an OBSERVATION and
## not an absent key):
##   components_added   : [ref, …]
##   components_removed : [ref, …]
##   components_changed : [{ref, fields: {<field>: {from, to}}}, …] — one entry
##                        per changed authored field, `assembly.<key>` for the
##                        assembly block's own fields (mpn, manufacturer,
##                        comment, house_parts, populate, paste, placements)
##   nets_added         : [name, …]
##   nets_removed       : [name, …]
##   nets_changed       : [{net, traces:{from,to}, vias:{from,to}}, …] — only
##                        nets whose copper COUNT moved; a net that kept its
##                        counts is not repeated here.
## Every list is sorted, so two runs over the same pair of boards produce
## identical text and a reply is diffable against an earlier one.
static func compute(prior_board: Dictionary, board: Dictionary) -> Dictionary:
	var prior_comps := _components_by_ref(prior_board)
	var live_comps := _components_by_ref(board)

	var added: Array = []
	var removed: Array = []
	var changed: Array = []
	for ref in live_comps:
		if not prior_comps.has(ref):
			added.append(ref)
	for ref in prior_comps:
		if not live_comps.has(ref):
			removed.append(ref)
			continue
		var fields := _component_fields(prior_comps[ref], live_comps[ref])
		if not fields.is_empty():
			changed.append({"ref": ref, "fields": fields})
	added.sort()
	removed.sort()
	changed.sort_custom(func(a, b): return str(a["ref"]) < str(b["ref"]))

	var prior_nets := _net_names(prior_board)
	var live_nets := _net_names(board)
	var nets_added: Array = []
	var nets_removed: Array = []
	for n in live_nets:
		if not prior_nets.has(n):
			nets_added.append(n)
	for n in prior_nets:
		if not live_nets.has(n):
			nets_removed.append(n)
	nets_added.sort()
	nets_removed.sort()

	var prior_copper := _copper_counts(prior_board)
	var live_copper := _copper_counts(board)
	var copper_names: Dictionary = {}
	for n in prior_copper:
		copper_names[n] = true
	for n in live_copper:
		copper_names[n] = true
	var net_names: Array = copper_names.keys()
	net_names.sort()
	var nets_changed: Array = []
	for n in net_names:
		var before: Dictionary = prior_copper.get(n, {"traces": 0, "vias": 0})
		var after: Dictionary = live_copper.get(n, {"traces": 0, "vias": 0})
		if int(before["traces"]) == int(after["traces"]) \
				and int(before["vias"]) == int(after["vias"]):
			continue
		nets_changed.append({
			"net": str(n),
			"traces": {"from": int(before["traces"]), "to": int(after["traces"])},
			"vias": {"from": int(before["vias"]), "to": int(after["vias"])},
		})

	return {
		"components_added": added,
		"components_removed": removed,
		"components_changed": changed,
		"nets_added": nets_added,
		"nets_removed": nets_removed,
		"nets_changed": nets_changed,
	}


## Nothing authored moved — the promotion rewrote the design it found.
static func is_unchanged(delta: Dictionary) -> bool:
	for k in delta:
		var v: Variant = delta[k]
		if v is Array and not (v as Array).is_empty():
			return false
	return true


## The status line's clause, "" when nothing moved. The changed-component count
## leads because a changed field is the case the old count delta could not see
## at all.
static func summary_text(delta: Dictionary) -> String:
	var parts: Array = []
	var changed: Array = delta.get("components_changed", [])
	if not changed.is_empty():
		parts.append("%d component(s) changed" % changed.size())
	var added: Array = delta.get("components_added", [])
	var removed: Array = delta.get("components_removed", [])
	if not added.is_empty() or not removed.is_empty():
		parts.append("components +%d/-%d" % [added.size(), removed.size()])
	var nets_added: Array = delta.get("nets_added", [])
	var nets_removed: Array = delta.get("nets_removed", [])
	if not nets_added.is_empty() or not nets_removed.is_empty():
		parts.append("nets +%d/-%d" % [nets_added.size(), nets_removed.size()])
	var nets_changed: Array = delta.get("nets_changed", [])
	if not nets_changed.is_empty():
		parts.append("copper moved on %d net(s)" % nets_changed.size())
	return ", ".join(PackedStringArray(parts))


## ref → component dict. A component with no ref cannot be diffed by identity
## and is skipped rather than merged into one nameless bucket.
static func _components_by_ref(board: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for c in (board.get("components", []) as Array):
		if not (c is Dictionary):
			continue
		var ref := str((c as Dictionary).get("ref", ""))
		if not ref.is_empty():
			out[ref] = c
	return out


## The authored fields that differ between one component's two versions.
## Absent and empty are ONE state for a present-only key (`value` is written
## only when set), so clearing a value reads as "" and not as a vanished field.
static func _component_fields(before: Dictionary, after: Dictionary) -> Dictionary:
	var fields: Dictionary = {}
	for key in TEXT_FIELDS:
		var b := str(before.get(key, ""))
		var a := str(after.get(key, ""))
		if b != a:
			fields[key] = {"from": b, "to": a}
	for key in NUMERIC_FIELDS:
		var bn := float(before.get(key, 0.0))
		var an := float(after.get(key, 0.0))
		if absf(bn - an) > EPS:
			fields[key] = {"from": bn, "to": an}
	# The assembly block is compared KEY BY KEY rather than whole, so the reply
	# names the field that moved (an mpn) instead of two blocks to eyeball. The
	# union of both sides' keys, because the schema is all-optional at the
	# codec: an added key is as real a change as an edited one.
	var b_asm: Dictionary = before.get("assembly", {}) if before.get("assembly") is Dictionary else {}
	var a_asm: Dictionary = after.get("assembly", {}) if after.get("assembly") is Dictionary else {}
	var asm_keys: Dictionary = {}
	for k in b_asm:
		asm_keys[k] = true
	for k in a_asm:
		asm_keys[k] = true
	var sorted_keys: Array = asm_keys.keys()
	sorted_keys.sort()
	for k in sorted_keys:
		# The canonical form is the comparison, so a container (house_parts,
		# placements) cannot fake a change through key order or int/float
		# representation, while the reported values stay the authored ones.
		if PcbRoutingSidecar._canonical(b_asm.get(k, null)) \
				== PcbRoutingSidecar._canonical(a_asm.get(k, null)):
			continue
		fields["assembly.%s" % str(k)] = {
			"from": b_asm.get(k, null), "to": a_asm.get(k, null)}
	return fields


## The declared net names, as a set.
static func _net_names(board: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for n in (board.get("nets", []) as Array):
		if n is Dictionary:
			var name := str((n as Dictionary).get("name", ""))
			if not name.is_empty():
				out[name] = true
	return out


## net → {traces, vias}, counted off the copper itself rather than the net list,
## so copper on a net the board never declared is still reported.
static func _copper_counts(board: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for t in (board.get("traces", []) as Array):
		if t is Dictionary:
			var n := str((t as Dictionary).get("net", ""))
			if not n.is_empty():
				_bump(out, n, "traces")
	for v in (board.get("vias", []) as Array):
		if v is Dictionary:
			var n := str((v as Dictionary).get("net", ""))
			if not n.is_empty():
				_bump(out, n, "vias")
	return out


static func _bump(counts: Dictionary, net: String, kind: String) -> void:
	if not counts.has(net):
		counts[net] = {"traces": 0, "vias": 0}
	var entry: Dictionary = counts[net]
	entry[kind] = int(entry[kind]) + 1
