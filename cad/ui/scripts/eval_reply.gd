extends RefCounted
## What an evaluation or interference reply looks like ON THE MCP WIRE.
##
## The panel's own report carries a records digest: one entry per reference
## NODE, naming the mesh and the pose every ray was cast against. The clearance
## join compares it against the state it is about to measure, which is the only
## way a report about references that have since moved can be refused — so the
## panel must keep it whole.
##
## An LLM never compares it with anything but ANOTHER reply's copy. A board of
## forty-five nodes makes that field five kilobytes, repeated on every doc_write
## and every interference report, and freshness is a question a hash answers as
## well as the list does. So the wire carries the hash and the panel keeps the
## list; nothing else about the reply changes.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: CADPanel (doc_read / doc_write) and panel_tools (check_interference).

## Hex characters of the short digest. Sixty-four bits of SHA-256: two reports
## about different reference sets colliding here would have to be looked for.
const SHORT_DIGEST_CHARS: int = 16


## The short form of a full digest — and "" for "", so an absent field stays
## absent rather than becoming the hash of nothing.
static func short_digest(full: String) -> String:
	if full.is_empty():
		return ""
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(full.to_utf8_buffer())
	return hasher.finish().hex_encode().substr(0, SHORT_DIGEST_CHARS)


## An interference report as MCP should render it. A COPY: the caller's report
## is the panel's own, and the join reads the full digest out of it later.
static func interference_for_mcp(report: Dictionary) -> Dictionary:
	var out := report.duplicate(true)
	if out.has("records_digest"):
		out["records_digest"] = short_digest(str(out["records_digest"]))
	return out


## A last_eval dictionary as MCP should render it, interference report and all.
static func last_eval_for_mcp(last_eval: Dictionary) -> Dictionary:
	var out := last_eval.duplicate(true)
	var report: Variant = out.get("interference", null)
	if report is Dictionary:
		out["interference"] = interference_for_mcp(report as Dictionary)
	return out
