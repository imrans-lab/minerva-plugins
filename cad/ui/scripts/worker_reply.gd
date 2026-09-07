extends RefCounted
## One place that opens a worker reply.
##
## A panel request goes through the host broker, so what call_backend() returns
## is TWO envelopes deep:
##
##   {success, result: {ok, result|error}, error_code?, error_message?}
##
## the outer one the broker's (did the request reach the plugin at all) and the
## inner one the worker's own (did the method answer). Reading the outer
## `result` as if it were the worker's answer finds none of the fields it is
## looking for and silently reports an empty answer — which is
## indistinguishable from a part with no such features in it.
##
## Every caller unwraps through here so there is one shape to read and one
## place for that mistake to be made.


## Open one reply. Returns the worker's own result Dictionary, or
## {error: "...", transient?} naming the layer that failed. `what` names the
## request in the error text ("clearance", "the solid's B-Rep features").
##
## `transient` marks a failure that says nothing about the request: the reply
## never arrived, never reached the worker, or the worker gave the request up
## (a timeout, a cancellation). A caller that remembers refusals must not
## remember these — the same request asked again can succeed — while an error
## the worker DECIDED on is the same error every time it is asked.
static func unwrap(envelope: Variant, what: String) -> Dictionary:
	if not (envelope is Dictionary):
		return {"error": "the %s request came back as no reply at all" % what,
			"transient": true}
	var reply: Dictionary = envelope
	if not bool(reply.get("success", false)):
		return {"error": "the %s request did not reach the worker: %s %s"
			% [what, str(reply.get("error_code", "unknown")),
				str(reply.get("error_message", ""))], "transient": true}
	var payload: Variant = reply.get("result", {})
	if not (payload is Dictionary):
		return {"error": "the worker's %s reply was malformed" % what,
			"transient": true}
	var body: Dictionary = payload
	if not bool(body.get("ok", false)):
		var raw: Variant = body.get("error", {})
		var kind: String = str((raw as Dictionary).get("kind", "")) \
			if raw is Dictionary else ""
		var message: String = str((raw as Dictionary).get("message", "")) \
			if raw is Dictionary else str(raw)
		var out := {"error": message if not message.is_empty() \
			else "the worker refused the %s request" % what}
		if kind == "cancelled" or kind == "timeout":
			out["transient"] = true
		return out
	var result: Variant = body.get("result", {})
	if not (result is Dictionary):
		return {"error": "the worker's %s reply carried no result" % what}
	return result
