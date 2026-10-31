extends RefCounted
## Pure reconciliation of declarations across one design run's two reports.
## Pair indices are owned by ExpectedContacts; geometry and freshness remain
## owned by the measuring legs. Never infer contact from a positive gap.
const _ReplyShape: Script = preload("reply_shape.gd")
const _Expected: Script = preload("expected_contacts.gd")


## A raw clearance ticket owns its original parameters. It cannot be
## re-graded by collecting it under a new design request. A single measured
## solid can answer one part only, whose identity must match the fresh leg.
static func ticket_error(args: Dictionary, interference_legs: Array,
		clearance: Dictionary) -> String:
	if str(clearance.get("status", "")) == "running":
		return ""
	if interference_legs.size() != 1 or clearance.has("parts"):
		return "one clearance ticket cannot answer a design check over multiple parts"
	if float(clearance.get("required_mm", INF)) != float(args["required_mm"]):
		return "clearance ticket measured a different required_mm; start a new measurement"
	var scope: Dictionary = {"reference": str(args.get("reference", "")),
		"node": str(args.get("node", ""))}
	if clearance.get("measurement_scope", {}) != scope:
		return "clearance ticket measured a different reference/node scope; start a new measurement"
	var parsed: Dictionary = _Expected.parse(args)
	var entries: Array = parsed["entries"]
	if not (parsed["errors"] as Array).is_empty():
		return "current expected_contacts are invalid"
	var expected_digest: String = "" if entries.is_empty() else _Expected.declarations_digest(entries)
	if str(clearance.get("expected_contacts_digest", "")) != expected_digest:
		return "clearance ticket measured different expected_contacts; start a new measurement"
	var leg: Dictionary = interference_legs[0]
	var report: Dictionary = leg["report"]
	var joined: Dictionary = clearance.get("interference_evidence", {})
	if not _current(report) or not clearance_certified(clearance):
		return "clearance ticket has no fresh bounded evidence for this design check"
	for field: String in ["scope_digest", "records_digest", "gauge_generation"]:
		if not report.has(field) or joined.get(field) != report[field]:
			return "clearance ticket measured different solid/reference geometry; start a new measurement"
	if report.get("measurement_scope", {}) != scope:
		return "interference leg measured a different reference/node scope"
	# The digest binds the captured solid to this one current render target;
	# collection itself does not carry the per-part wrapper's display label.
	clearance["part"] = str(leg["part"])
	return ""


static func reconcile(interference_legs: Array, clearance_legs: Array,
		state: Dictionary) -> Array:
	var satisfied: Array = []
	for leg: Dictionary in interference_legs:
		var part: String = str(leg["part"])
		var report: Dictionary = leg["report"]
		var remaining: int = 0
		for declaration: Dictionary in report.get("expected_contacts_unmatched", []):
			var proof: Dictionary = {}
			for clearance_leg: Dictionary in clearance_legs:
				if str(clearance_leg["part"]) != part:
					continue
				proof = _flush_proof(report, clearance_leg["report"], declaration)
				if not proof.is_empty():
					break
			if proof.is_empty():
				remaining += 1
			else:
				proof["part"] = part
				satisfied.append(proof)
		if remaining > 0:
			state["unknown"] = true
			(state["notes"] as Array).append(("%d expected contact(s) for part '%s' "
				+ "matched no certified contact in this check; unmatched declarations "
				+ "remain advisory") % [remaining, part])
	return satisfied


static func _flush_proof(interference: Dictionary, clearance: Dictionary,
		declaration: Dictionary) -> Dictionary:
	if not _current(interference) or not clearance_certified(clearance) \
			or bool(interference.get("truncated_coverage", true)) \
			or float(declaration.get("declared_required_mm", INF)) != 0.0:
		return {}
	var joined: Dictionary = clearance.get("interference_evidence", {})
	if joined.get("fresh", false) != true:
		return {}
	for field: String in ["scope_digest", "records_digest", "gauge_generation"]:
		if not interference.has(field) or joined.get(field) != interference[field]:
			return {}
	var declarations: String = str(interference.get("expected_contacts_digest", ""))
	if declarations.is_empty() \
			or declarations != str(clearance.get("expected_contacts_digest", "")):
		return {}
	if not interference.has("measurement_scope") \
			or interference["measurement_scope"] != clearance.get("measurement_scope", {}):
		return {}
	var index: int = int(declaration.get("declaration_index", -1))
	if index < 0:
		return {}
	for pair: Dictionary in clearance.get("declared_clearance", []):
		if pair.get("pass", false) != true or not bool(pair.get("expected", false)) \
				or not bool(pair.get("touching", false)) \
				or float(pair.get("min_mm", INF)) != 0.0 \
				or float(pair.get("required_mm", INF)) != 0.0 \
				or _ReplyShape.pair_uncertified(pair) \
				or bool(pair.get("interference", false)) \
				or bool(pair.get("containment_undecidable", false)):
			continue
		var answered: Array = pair.get("expected_contact_indices", [])
		if not answered.has(index) or _crosses_or_undecided(interference, pair):
			continue
		return {"declaration_index": index, "reference": str(pair.get("reference", "")),
			"node": str(pair.get("node", "")), "declared_required_mm": 0.0,
			"min_mm": 0.0, "certified": true, "status": "satisfied",
			"evidence": "same-check bounded clearance measured touching; fresh interference found no crossing"}
	return {}


static func _crosses_or_undecided(report: Dictionary, pair: Dictionary) -> bool:
	for field: String in ["pairs", "expected_contacts", "undecidable"]:
		for row: Dictionary in report.get(field, []):
			if str(row.get("reference", "")) != str(pair.get("reference", "")):
				continue
			var node: String = str(row.get("node", ""))
			if node != str(pair.get("node", "")) and not (field == "undecidable" and node.is_empty()):
				continue
			if field != "expected_contacts" or str(row.get("measured", "")) == "overlap" \
					or row.get("certified", true) == false:
				return true
	return false


static func _current(report: Dictionary) -> bool:
	return bool(report.get("success", true)) and not report.has("error") \
		and report.get("checked", false) == true \
		and not bool(report.get("stale", false)) \
		and not bool(report.get("references_moved", false)) \
		and str(report.get("design_scope_error", "")).is_empty() \
		and str(report.get("status", "")) != "running"


static func clearance_certified(report: Dictionary) -> bool:
	var joined: Dictionary = report.get("interference_evidence", {})
	return _current(report) and report.get("tolerance_bounded", false) == true \
		and joined.get("fresh", false) == true
