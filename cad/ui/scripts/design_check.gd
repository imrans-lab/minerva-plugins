extends RefCounted
## minerva_cad_check_design — "is this design still wrong, and where?", once.
##
## The acceptance loop is edit → check everything → fix the worst row, and
## "check everything" used to be three verbs, three reply shapes and a hand
## merge of the interference node list into the clearance report. This runs
## the same three checks and returns the rows that FAILED, the counts of what
## it did not show, and one verdict over the lot.
##
## NOTHING IS MEASURED HERE. Every number comes from the three checks exactly
## as their own verbs run them — this file sequences them and folds three
## replies into one. A check it could not run is never folded into a clean
## answer: it lands in `checks` with the reason and makes the verdict
## advisory.
##
## ONE CHECK AT A TIME. Interference and fasteners share the panel's single
## solid collider and refuse a second caller with `busy`, so the legs are
## awaited one after another and this verb can never queue behind itself. A
## `busy` from the panel's OWN per-evaluation check is a passing state, not an
## answer, so it is retried a few frames later before it is reported.
##
## THE SLOW ONE IS LAST. Clearance re-tessellates the solid in the worker and
## is the only leg that can outrun the caller's window; running it last means
## the reply that carries its ticket still carries the interference and
## fastener rows. Collecting that ticket re-runs the other two, so a collected
## reply has the same shape and every row in it describes the geometry
## standing now.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: ui/panel_tools.gd (the verb layer).

## How many times a leg refused with `busy` is asked again, and how many idle
## frames apart. The holder is a per-evaluation check with a physics step in
## it; a handful of frames is enough for it to finish and short enough that a
## caller waiting on this verb never wonders whether it hung.
const BUSY_ATTEMPTS: int = 4
const BUSY_FRAMES: int = 8

## Failing clearance pairs kept by default. The rows arrive closest-first, and
## an edit acts on the tightest one; the rest are counted in `hidden_counts`.
const DEFAULT_CLEARANCE_LIMIT: int = 10

## Crossing points kept per interference row. The row's job here is to name
## the pair and put the reader at the crash; the full point list, in both
## frames, is one minerva_cad_check_interference call away.
const MAX_CROSSING_POINTS: int = 3


## Run the three checks and fold them into one reply.
##
## The three verbs are handed in as Callables rather than reached for: this
## script is preloaded BY the verb layer, and preloading it back would be a
## cycle. `per_part` is the same per-part wrapper every check verb goes
## through, so `parts` works here exactly as it works there.
static func run(panel, args: Dictionary, per_part: Callable,
		interference: Callable, clearance: Callable,
		fasteners: Callable) -> Dictionary:
	var handle := str(args.get("ticket", "")).strip_edges()
	var required_mm := float(args.get("required_mm", 0.0))
	if required_mm <= 0.0:
		return {"success": false, "error": "check_design needs required_mm: "
			+ "the gap you want between the solid and everything else, in "
			+ "millimetres. It is what the clearance leg grades against; the "
			+ "contacts the design MEANS to have go in expected_contacts."}

	var state := {
		"notes": [],
		"checks": {},
		"counts": {},
		"unknown": false,
		# part -> ticket for every clearance leg still in the worker. A
		# part-scoped call has one leg per part, and a ticket that did not
		# travel is a measurement nobody can collect.
		"tickets": {},
	}

	var solid_args := args.duplicate(true)
	# The ticket names a clearance measurement and nothing else; the other two
	# legs would read it as a scope they do not have.
	solid_args.erase("ticket")

	var interference_rows: Array = _fold_interference(
		await _unbusy(panel, solid_args, per_part, interference), state)
	var fastener_rows: Array = await _run_fasteners(
		panel, solid_args, per_part, fasteners, state)

	var clearance_args := args.duplicate(true)
	clearance_args["failing_only"] = true
	if int(clearance_args.get("limit", 0)) <= 0:
		clearance_args["limit"] = DEFAULT_CLEARANCE_LIMIT
	var clearance_reply: Dictionary = {}
	if handle.is_empty():
		clearance_reply = await _unbusy(panel, clearance_args, per_part, clearance)
	else:
		# A ticket is collected directly: the per-part wrapper would start a
		# second measurement beside the one being collected.
		clearance_reply = await clearance.call(panel, clearance_args)
	var clearance_rows: Array = _fold_clearance(clearance_reply, state)

	var failing := interference_rows.size() + clearance_rows.size() \
		+ fastener_rows.size()
	var out := {
		"success": true,
		"units": "mm",
		"verdict": "fail" if failing > 0 else \
			("advisory" if bool(state["unknown"]) else "pass"),
		"required_mm": required_mm,
		"interference": interference_rows,
		"clearance": clearance_rows,
		"fasteners": fastener_rows,
		"failing_rows": failing,
		"hidden_counts": state["counts"],
		"checks": state["checks"],
		"verdict_note": "fail = a row below is wrong. advisory = nothing "
			+ "failed but something could not be decided — read `checks` and "
			+ "`notes`. pass = every check ran and every row cleared, with "
			+ "the contacts in expected_contacts held out by name.",
	}
	if not (state["notes"] as Array).is_empty():
		out["notes"] = state["notes"]
	_attach_tickets(out, state["tickets"] as Dictionary)
	return out


## The clearance tickets a reply has to carry, whichever shape they came in.
## One part (or none) is one ticket, collected by calling this verb again
## with it; several parts are one ticket EACH, and each is collected on its
## own through minerva_cad_check_clearance, because this verb's own ticket
## argument names one measurement.
static func _attach_tickets(out: Dictionary, tickets: Dictionary) -> void:
	if tickets.is_empty():
		return
	out["status"] = "running"
	if tickets.size() == 1:
		var ticket := str(tickets.values()[0])
		out["ticket"] = ticket
		out["tickets"] = {"clearance": ticket}
		out["ticket_note"] = ("the clearance leg is still in the worker; the "
			+ "interference and fastener rows above are complete. Call "
			+ "minerva_cad_check_design again with ticket=\"%s\" to collect "
			+ "it — that call re-runs the other two legs, so its verdict is "
			+ "over the geometry standing then.") % ticket
		return
	out["tickets"] = {"clearance": tickets.duplicate()}
	out["ticket_note"] = ("the clearance leg is still in the worker for %d "
		+ "parts, one ticket each under tickets.clearance; the interference "
		+ "and fastener rows above are complete. Collect each with "
		+ "minerva_cad_check_clearance ticket=<ticket> (failing_only=true "
		+ "for the rows this verb would show), or call this verb again "
		+ "without parts= once they have had their window.") % tickets.size()


# ---------------------------------------------------------------------------
# Running the legs
# ---------------------------------------------------------------------------

## Run one leg, asking again while it comes back `busy`.
##
## `busy` is the collider reservation refusing a second caller — nothing was
## measured and nothing is wrong. Every other reply, including a failure, is
## returned on the first attempt.
static func _unbusy(panel, args: Dictionary, per_part: Callable,
		verb: Callable) -> Dictionary:
	var reply: Dictionary = {}
	for attempt in range(BUSY_ATTEMPTS):
		reply = await per_part.call(panel, args, verb)
		if not _is_busy(reply):
			return reply
		await _idle(BUSY_FRAMES)
	return reply


## Did this reply — or any part of it — come back refused for the collider?
static func _is_busy(reply: Dictionary) -> bool:
	for leg in _legs(reply):
		if bool((leg["report"] as Dictionary).get("busy", false)):
			return true
	return false


## Give the frames back, so whoever holds the collider can finish.
static func _idle(frames: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for frame in range(frames):
		await tree.process_frame


## The fastener leg, which only runs when a screw was named. A caller asking
## about clearance alone said so by leaving `screw` out; that is a scope, not
## something the check could not decide, so it does not make the verdict
## advisory.
static func _run_fasteners(panel, args: Dictionary, per_part: Callable,
		fasteners: Callable, state: Dictionary) -> Array:
	var screw: Dictionary = args.get("screw", {}) as Dictionary
	if float(screw.get("dia_mm", 0.0)) <= 0.0:
		(state["checks"] as Dictionary)["fasteners"] = "not asked for: pass "\
			+ "screw: {dia_mm, length_mm} to check the joints too"
		return []
	return _fold_fasteners(
		await _unbusy(panel, args, per_part, fasteners), state)


# ---------------------------------------------------------------------------
# Folding the replies
# ---------------------------------------------------------------------------

## One entry per part a reply covers: {part, report}. A reply that was not
## part-scoped is one entry whose report is the reply itself, so every fold
## below reads one shape.
static func _legs(reply: Dictionary) -> Array:
	if not (reply.get("parts", null) is Array):
		return [{"part": str(reply.get("part", "")), "report": reply}]
	var out: Array = []
	for entry in (reply["parts"] as Array):
		var row: Dictionary = entry
		out.append({"part": str(row.get("part", "")), "report": row})
	return out


## The failing interference rows: the (reference, node) pairs the solid runs
## into, minus the ones expected_contacts declared and the check excused.
static func _fold_interference(reply: Dictionary, state: Dictionary) -> Array:
	var rows: Array = []
	var pairs := 0
	var points := 0
	var hidden := 0
	for leg in _legs(reply):
		var part := str(leg["part"])
		var report: Dictionary = leg["report"]
		if not _leg_ran(report, "interference", part, state):
			continue
		pairs += int(report.get("count", 0))
		points += int(report.get("point_count", 0))
		for entry in (report.get("pairs", []) as Array):
			var pair: Dictionary = (entry as Dictionary).duplicate(true)
			var crossings: Array = pair.get("points_mm", []) as Array
			if crossings.size() > MAX_CROSSING_POINTS:
				pair["points_mm"] = crossings.slice(0, MAX_CROSSING_POINTS)
				hidden += crossings.size() - MAX_CROSSING_POINTS
			if not part.is_empty():
				pair["part"] = part
			rows.append(pair)
		var undecidable: Array = report.get("undecidable", []) as Array
		if not undecidable.is_empty():
			_unknown(state, ("interference could not decide containment for "
				+ "%d node(s)%s; minerva_cad_check_interference lists them")
				% [undecidable.size(), _of(part)])
		# A declared contact is held out of the pairs on a measured depth that
		# is not an upper bound, so the exclusion is advisory and the check
		# says so with pass false and a reason; that is never folded to pass.
		_fold_unproven(report, "interference", part, state)
		var unmatched: Array = report.get("expected_contacts_unmatched", []) as Array
		if not unmatched.is_empty():
			_unknown(state, ("%d expected contact(s)%s matched nothing that "
				+ "was measured — a declaration that has gone stale excuses "
				+ "nothing") % [unmatched.size(), _of(part)])
	_count(state, "interference_pairs", pairs)
	_count(state, "interference_points", points)
	_count(state, "interference_points_hidden", hidden)
	return rows


## The failing clearance rows. The verb layer has already dropped the pairs
## that cleared and kept the closest of what is left, and its own counts say
## how many rows are behind the filter. The leg's own verdict is read as
## well: a report that failed for a reason no row carries is folded as
## unknown, never as clean.
static func _fold_clearance(reply: Dictionary, state: Dictionary) -> Array:
	var rows: Array = []
	var total := 0
	var failing := 0
	var hidden := 0
	for leg in _legs(reply):
		var part := str(leg["part"])
		var report: Dictionary = leg["report"]
		if str(report.get("status", "")) == "running":
			_unknown(state, "clearance is still measuring in the worker%s"
				% _of(part))
			(state["checks"] as Dictionary)["clearance"] = "still running — "\
				+ "collect its ticket"
			var ticket := str(report.get("ticket", ""))
			if not ticket.is_empty():
				(state["tickets"] as Dictionary)[part] = ticket
			continue
		if not _leg_ran(report, "clearance", part, state):
			continue
		total += int(report.get("pairs_total", 0))
		failing += int(report.get("pairs_failing", 0))
		hidden += int(report.get("pairs_hidden", 0))
		for entry in (report.get("pairs", []) as Array):
			var pair: Dictionary = (entry as Dictionary).duplicate(true)
			if not part.is_empty():
				pair["part"] = part
			rows.append(pair)
		if (bool(report.get("advisory", false)) \
				or not bool(report.get("tolerance_bounded", true))) \
				and str(report.get("pass_reason", "")).is_empty():
			_unknown(state, "clearance is advisory%s: its tessellation "
				+ "tolerance could not be bounded, so no pair is certified"
				% _of(part))
		if bool(report.get("references_moved", false)):
			_unknown(state, "reference geometry moved while clearance was "
				+ "measured%s; ask again" % _of(part))
		_fold_unproven(report, "clearance", part, state)
	_count(state, "clearance_pairs_total", total)
	_count(state, "clearance_pairs_failing", failing)
	_count(state, "clearance_pairs_hidden", hidden)
	return rows


## The screws that will not go in. A row the check measured but could not
## grade — a size ISO 273 does not tabulate, so coaxiality is `null` — is not
## a failure and does not travel as one; it makes the verdict advisory.
static func _fold_fasteners(reply: Dictionary, state: Dictionary) -> Array:
	var rows: Array = []
	var screws := 0
	for leg in _legs(reply):
		var part := str(leg["part"])
		var report: Dictionary = leg["report"]
		if not _leg_ran(report, "fasteners", part, state):
			continue
		screws += int(report.get("count", 0))
		for entry in (report.get("screws", []) as Array):
			var screw: Dictionary = entry
			var coaxiality: Dictionary = screw.get("coaxiality", {}) as Dictionary
			if coaxiality.get("pass", true) == null:
				_unknown(state, ("a screw%s could not be graded for "
					+ "coaxiality: %s") % [_of(part),
					str(coaxiality.get("clearance_source", "no clearance "
						+ "hole is tabulated for that size; pass "
						+ "clearance_hole_dia_mm"))])
			if bool(screw.get("pass", false)):
				continue
			var row: Dictionary = screw.duplicate(true)
			if not part.is_empty():
				row["part"] = part
			rows.append(row)
	_count(state, "fastener_screws", screws)
	_count(state, "fastener_screws_failing", rows.size())
	return rows


# ---------------------------------------------------------------------------
# Bookkeeping
# ---------------------------------------------------------------------------

## Did this leg produce an answer? A leg that errored or came back
## `checked: false` is recorded with its reason and makes the verdict
## advisory — an empty row list from a check that never ran must not read as
## a clean one.
static func _leg_ran(report: Dictionary, leg: String, part: String,
		state: Dictionary) -> bool:
	var checks: Dictionary = state["checks"]
	if report.has("error") or not bool(report.get("success", true)):
		_unknown(state, "%s did not run%s: %s"
			% [leg, _of(part), str(report.get("error", "no reason given"))])
		checks[leg] = "could not run: %s" % str(report.get("error", ""))
		return false
	if not bool(report.get("checked", false)):
		_unknown(state, "%s did not run%s: %s"
			% [leg, _of(part), str(report.get("reason", "no reason given"))])
		checks[leg] = "could not run: %s" % str(report.get("reason", ""))
		return false
	checks[leg] = "ran"
	return true


## A leg whose own verdict is false for a reason its rows do not show — a
## stale interference join, a declaration that could only be applied
## advisorily, a region the pair is ungraded outside of — is folded as
## unknown, so the design verdict never reads pass off a leg that said no.
static func _fold_unproven(report: Dictionary, leg: String, part: String,
		state: Dictionary) -> void:
	if bool(report.get("pass", false)):
		return
	var reason := str(report.get("pass_reason", ""))
	if reason.is_empty():
		return
	_unknown(state, "%s%s did not pass: %s" % [leg, _of(part), reason])


## Record something the checks could not settle. The verdict can be no better
## than advisory from here.
static func _unknown(state: Dictionary, note: String) -> void:
	state["unknown"] = true
	(state["notes"] as Array).append(note)


## Add to a count, keeping the key out of the reply while it is zero: a count
## of nothing is not a thing that was hidden.
static func _count(state: Dictionary, key: String, value: int) -> void:
	if value <= 0:
		return
	var counts: Dictionary = state["counts"]
	counts[key] = int(counts.get(key, 0)) + value


## " for part 'lid'", or "" when the document was checked as one shape.
static func _of(part: String) -> String:
	return "" if part.is_empty() else " for part '%s'" % part
