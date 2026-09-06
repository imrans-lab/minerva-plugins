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
## The same rule shapes the rest of the wire form: last_eval carries the
## interference report as a status line and the reference rows only when one
## failed. Both are one named verb away, and an agent polling for "did my
## edit land" reads neither.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: CADPanel (doc_read / doc_write / await_eval) and panel_tools
## (check_interference, which reports the FULL report).

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


## An interference report as a STATUS line: did the check run, how many nodes
## did the solid meet, and which. The crossing points — dozens per node, in
## two frames each — are the whole size of the report and are one call to
## minerva_cad_check_interference away, which re-asks the same question
## against the geometry standing now.
static func lean_interference(report: Dictionary) -> Dictionary:
	var nodes: Array = []
	for entry in (report.get("pairs", []) as Array):
		var pair: Dictionary = entry
		nodes.append("%s/%s" % [str(pair.get("reference", "")),
			str(pair.get("node", ""))])
	var lean := {
		"checked": bool(report.get("checked", false)),
		"count": int(report.get("count", 0)),
		"point_count": int(report.get("point_count", 0)),
		"nodes": nodes,
	}
	# The one field of the full report that is not re-derivable by asking
	# again: which reference set the check ran against. Sixteen characters.
	if report.has("records_digest"):
		lean["records_digest"] = short_digest(str(report["records_digest"]))
	var undecidable: Array = report.get("undecidable", []) as Array
	if not undecidable.is_empty():
		lean["undecidable"] = undecidable
	if not str(report.get("reason", "")).is_empty():
		lean["reason"] = str(report["reason"])
	if int(lean["count"]) > 0 or not undecidable.is_empty():
		lean["detail"] = "minerva_cad_check_interference returns the crossing "\
			+ "points, in both frames, per node"
	return lean


## The innermost frame of a worker traceback, as the exception line followed by
## the deepest "File ..." line. A kernel failure's message names the DSL binding
## that was building; this names the call inside the kernel that raised, which
## is what tells two failure modes of the same binding apart. Empty for a
## payload with no traceback.
static func innermost_frame(tb: String) -> String:
	var trimmed: String = tb.strip_edges()
	if trimmed.is_empty():
		return ""
	var lines: PackedStringArray = trimmed.split("\n", false)
	if lines.is_empty():
		return ""
	var exception_line: String = lines[lines.size() - 1].strip_edges()
	for i in range(lines.size() - 1, -1, -1):
		var candidate: String = lines[i].strip_edges()
		if candidate.begins_with("File \""):
			return "%s\n  %s" % [exception_line, candidate]
	return exception_line


## A last_eval dictionary as MCP should render it: the verdict, the numbers
## that describe the solid, and a STATUS line for the interference check.
##
## An agent polling for "did my edit land" reads status; on a real board the
## interference report and the per-reference load statistics are most of the
## reply and it reads neither. Both are one named call away — the report from
## minerva_cad_check_interference, the reference rows from
## minerva_cad_references — and a reference that failed to load still travels
## here, because nothing else in the reply says the board is missing.
static func last_eval_for_mcp(last_eval: Dictionary) -> Dictionary:
	var out := last_eval.duplicate(true)
	var report: Variant = out.get("interference", null)
	if report is Dictionary:
		out["interference"] = lean_interference(report as Dictionary)
	var references: Variant = out.get("references", null)
	if references is Array:
		var failed: Array = []
		for entry in (references as Array):
			var row: Dictionary = entry
			if str(row.get("status", "ok")) != "ok" \
					or not str(row.get("warning", "")).is_empty():
				failed.append(row)
		if failed.is_empty():
			out.erase("references")
		else:
			out["references"] = failed
			out["references_note"] = "only the references that failed to load "\
				+ "or carry a warning; minerva_cad_references lists them all"
	return out
