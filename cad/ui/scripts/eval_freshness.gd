extends RefCounted
## Is the geometry a check is about to measure the geometry the document
## describes?
##
## A measurement verb reaches the panel's colliders, and those are built from
## the last evaluation the panel PAINTED. The document buffer moves ahead of
## that on its own: an edit bumps the buffer's version the instant it lands,
## the panel debounces, the worker takes seconds or minutes, and an evaluation
## that fails paints nothing at all. A number that is right about geometry the
## document no longer describes is worse than no number: it is one a reader
## acts on.
##
## So every check reply and every await reply carries the same five fields:
##
##   source_version     the buffer version of the evaluation that PRODUCED
##                      the geometry being measured — the last one that
##                      painted, never merely the last one dispatched
##   buffer_version     the version the document is at now
##   evaluated_at       when the standing evaluation was stamped, unix seconds
##   evaluation_status  what that evaluation did: ok, error, timeout, pending
##   stale              whether the first two describe one document
##
## and a reply whose evaluation moved under it (or under the ticket it was
## collected by) also carries `started_source_version`, the version it was
## measured against, beside the current `buffer_version`;
##
## and a check verb asked while they disagree is REFUSED rather than answered:
## checked false with the reason, nothing measured, and minerva_cad_await_eval
## as the named way through. A refusal a caller can act on beats a number it
## cannot tell from a current one.
##
## A PANEL THAT CANNOT ANSWER IS NOT REFUSED. The freshness comes from the
## panel's own evaluation_freshness(); a panel without it (a stand-in, a
## restored note with no buffer) reports `known` false, nothing is stamped and
## nothing is blocked — this module never invents a verdict about a document it
## cannot see.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: ui/panel_tools.gd, around the verb dispatch.

## The verbs that MEASURE, and so must not run against geometry the document
## has moved past. The gauge is one of them: it mounts the evaluated solid in
## front of its pin. minerva_cad_await_eval is deliberately not among them: it
## is the way out of a stale panel.
const MEASURING_VERBS: Array = [
	"minerva_cad_gauge",
	"minerva_cad_material",
	"minerva_cad_check_motion",
	"minerva_cad_check_interference",
	"minerva_cad_check_clearance",
	"minerva_cad_check_fasteners",
	"minerva_cad_check_design",
]

## What the panel says about its own evaluation, or {known: false}.
static func read(panel) -> Dictionary:
	if panel == null or not is_instance_valid(panel) \
			or not panel.has_method("evaluation_freshness"):
		return {"known": false, "stale": false}
	return panel.evaluation_freshness()


## Must this verb be refused? Only a measuring verb, and only on a panel that
## reported a document ahead of its evaluation.
##
## THE GATE IS BEFORE, NEVER AFTER. A verb that has already cast its rays
## cannot be un-measured: by the time the reply exists the numbers are real
## numbers about a shape that has moved, and the only honest thing left is the
## stale stamp on the way out. So the gate is asked before dispatch, and again
## before each part leg that has not started yet — the two places where
## refusing still costs a caller nothing.
static func blocks(tool_name: String, freshness: Dictionary) -> bool:
	return bool(freshness.get("known", false)) \
		and bool(freshness.get("stale", false)) \
		and MEASURING_VERBS.has(tool_name)


static func requirement_error(args: Dictionary, freshness: Dictionary) -> String:
	if args.has("require_source_version"):
		if not freshness.get("known", false) or int(freshness.get("source_version", -1)) < 0:
			return "No completed source version is available. Build the document first."
		if int(args.require_source_version) != int(freshness.source_version):
			return "The displayed model does not match require_source_version."
	if args.has("require_source_digest"):
		var digest: String = str(freshness.get("provenance", {}).get("source_digest", ""))
		if digest.is_empty() or digest != str(args.require_source_digest):
			return "The displayed model does not match require_source_digest."
	if bool(args.get("accept_last_completed", false)) and freshness.get("provenance", {}).is_empty():
		return "No identified completed evaluation is available to accept. Build the document first."
	return ""

static func accepts_stale(args: Dictionary) -> bool:
	return bool(args.get("accept_last_completed", false))


## The refusal itself. `checked` false with a reason is not the same answer as
## "nothing is wrong", and the reason names the verb that clears it.
static func refusal(freshness: Dictionary) -> Dictionary:
	var reply := {
		"success": true,
		"checked": false,
		"pass": false,
		"reason": str(freshness.get("stale_reason", "")),
		"measured": false,
	}
	return stamp(reply, freshness)


## The verb that waits for the next evaluation to paint. The painted
## evaluation moving under it is its whole purpose, never a staleness.
const AWAIT_VERB: String = "minerva_cad_await_eval"


## Was this verb overtaken: did the panel paint a different evaluation
## between `before` and `after`, read around its dispatch? A measurement that
## started against one evaluation and returned after another was painted
## describes geometry the reply's own stamp would call current.
static func outrun(tool_name: String, before: Dictionary,
		after: Dictionary) -> bool:
	if tool_name == AWAIT_VERB:
		return false
	if not bool(before.get("known", false)) or not bool(after.get("known", false)):
		return false
	return int(before.get("source_version", -1)) != int(after.get("source_version", -1)) \
		or float(before.get("evaluated_at", 0.0)) != float(after.get("evaluated_at", 0.0)) \
		or str(before.get("provenance", {}).get("reference_digest", "")) != str(after.get("provenance", {}).get("reference_digest", ""))


## The stamp for a reply whose verb ran while the painted evaluation moved:
## stamped with the state it STARTED against, stale, and the reason naming
## both versions. The numbers were measured against the earlier evaluation
## (or an unknowable mix of the two), and neither is what the document shows.
## `started_source_version` is that earlier version on its own field, and
## `buffer_version` is the document's CURRENT version — a reply carrying the
## start's buffer version would say the document had not moved.
## `during` says over which stretch the evaluation moved.
static func stamp_moved(reply: Dictionary, before: Dictionary,
		after: Dictionary, during: String = "while this call ran") -> Dictionary:
	# A reply already stamped by the layer that measured (a collected ticket)
	# keeps that as its start; the stamp below never overwrites it.
	var started := int(reply.get("source_version",
		int(before.get("source_version", -1))))
	reply["result_valid"] = false
	if reply.has("pass"):
		reply["pass"] = null
	reply["stale"] = true
	reply["stale_reason"] = ("the evaluation changed %s: it "
		+ "started against the evaluation of version %d and version %d was "
		+ "painted before it returned, so the numbers describe geometry the "
		+ "document no longer shows — call again now that it is settled") \
		% [during, started, int(after.get("source_version", -1))]
	reply["started_source_version"] = started
	stamp(reply, before)
	reply["buffer_version"] = int(after.get("buffer_version", -1))
	return reply


## The stamp for a report collected by ticket: `started` is the freshness
## snapshot filed with the ticket when the measurement began, `now` the
## panel's freshness at collection. The numbers are about the evaluation
## that stood at the start, whatever painted since; a painted evaluation
## that moved in between makes the report stale, naming both versions.
static func stamp_ticket(reply: Dictionary, started: Dictionary,
		now: Dictionary) -> Dictionary:
	if outrun("", started, now):
		return stamp_moved(reply, started, now,
			"between this measurement starting and its ticket being collected")
	stamp(reply, started)
	if bool(now.get("known", false)):
		reply["buffer_version"] = int(now.get("buffer_version", -1))
	return reply


## The five fields on a reply that is going out. A reply from a panel that
## could not report its freshness is returned untouched: an absent stamp is
## honest where an invented one would not be.
static func stamp(reply: Dictionary, freshness: Dictionary) -> Dictionary:
	if not bool(freshness.get("known", false)):
		return reply
	# The SOURCE fields name the evaluation the numbers are about, and the
	# layer that measured knows that best: a report collected by ticket
	# arrives already naming the evaluation it started against, and the
	# outer stamp must not rename it after the evaluation that stands now.
	# The buffer version is always the document's now.
	if not reply.has("source_version"):
		reply["source_version"] = int(freshness.get("source_version", -1))
		if freshness.has("provenance"):
			reply["provenance"] = freshness.provenance.duplicate(true)
		if freshness.has("document_id"):
			reply["document_id"] = freshness.document_id
		reply["evaluated_at"] = float(freshness.get("evaluated_at", 0.0))
		# What the standing evaluation DID. Two replies can name the same
		# source_version for opposite reasons — one painted it, one failed on
		# the way to it — and only this field tells them apart.
		reply["evaluation_status"] = str(freshness.get("evaluation_status", ""))
	reply["buffer_version"] = int(freshness.get("buffer_version", -1))
	# Never DOWNGRADES: the verb layer marks a reply stale for its own reason
	# (the references re-posed under a measurement), and a document that is
	# settled says nothing about that.
	reply["stale"] = bool(reply.get("stale", false)) \
		or bool(freshness.get("stale", false))
	var reason := str(freshness.get("stale_reason", ""))
	if bool(reply["stale"]) and not reason.is_empty() \
			and str(reply.get("stale_reason", "")).is_empty():
		reply["stale_reason"] = reason
	return reply
