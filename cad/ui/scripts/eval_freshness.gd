extends RefCounted
## Is the geometry a check is about to measure the geometry the document
## describes?
##
## A measurement verb reaches the panel's colliders, and those are built from
## the last evaluation the panel PAINTED. The document buffer moves ahead of
## that on its own: an edit bumps the buffer's version the instant it lands,
## the panel debounces, the worker takes seconds or minutes, and every call in
## between measures the previous shape. Nothing in the reply used to say so,
## and an answer that is right about geometry nobody has any more is worse than
## no answer — it is one a reader acts on.
##
## So every check reply and every await reply carries the same four fields:
##
##   source_version   the buffer version the standing evaluation was of
##   buffer_version   the version the document is at now
##   evaluated_at     when that evaluation was stamped, unix seconds
##   stale            whether those two describe one document
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
## has moved past. minerva_cad_await_eval is deliberately not among them: it is
## the way out of a stale panel.
const MEASURING_VERBS: Array = [
	"minerva_cad_material",
	"minerva_cad_check_interference",
	"minerva_cad_check_clearance",
	"minerva_cad_check_fasteners",
	"minerva_cad_check_design",
]

## The verbs whose replies carry the stamp: the measuring ones, and the await
## that exists to clear it.
const STAMPED_VERBS: Array = [
	"minerva_cad_material",
	"minerva_cad_check_interference",
	"minerva_cad_check_clearance",
	"minerva_cad_check_fasteners",
	"minerva_cad_check_design",
	"minerva_cad_await_eval",
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


## The four fields on a reply that is going out. A reply from a panel that
## could not report its freshness is returned untouched: an absent stamp is
## honest where an invented one would not be.
static func stamp(reply: Dictionary, freshness: Dictionary) -> Dictionary:
	if not bool(freshness.get("known", false)):
		return reply
	reply["source_version"] = int(freshness.get("source_version", -1))
	reply["buffer_version"] = int(freshness.get("buffer_version", -1))
	reply["evaluated_at"] = float(freshness.get("evaluated_at", 0.0))
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
