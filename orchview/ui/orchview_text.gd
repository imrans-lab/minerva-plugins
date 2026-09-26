extends RefCounted

## Text for one read-model node, shared by the tree rows and the details pane.
##
## A node (orchview/internal/readmodel Node, decoded from JSON) carries its
## recorded stage (what the records say), its ownership, and its activity
## (what the host observed). They are rendered as separate facts: the stage
## text never mentions activity, and the activity text only ever reports the
## host's liveness vocabulary, an observation time, or "unknown".


## Recorded stage: status and the result/outcome/review/test facts, then the
## flags the read model derived from records.
static func stage_text(node: Dictionary) -> String:
	var stage: Dictionary = _dict(node, "stage")
	if stage.is_empty():
		return ""
	var parts: PackedStringArray = [str(stage.get("status", ""))]
	for key: String in ["result", "outcome", "review", "test"]:
		var value := str(stage.get(key, ""))
		if not value.is_empty():
			parts.append("%s: %s" % [key, value])
	var deferred: Array = _array(stage, "deferred")
	if not deferred.is_empty():
		parts.append("deferred: %d" % deferred.size())
	for flag: String in flags(node):
		parts.append(flag)
	return " · ".join(parts)


## The record-derived flags, upper-case so they stand out in a row.
static func flags(node: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	if bool(node.get("blocked", false)):
		out.append("BLOCKED")
	if bool(node.get("unowned", false)):
		out.append("UNOWNED")
	if bool(node.get("outcome_unrecorded", false)):
		out.append("OUTCOME UNRECORDED")
	if bool(node.get("partial", false)):
		out.append("PARTIAL")
	if bool(node.get("orphan", false)):
		out.append("ORPHAN")
	return out


## Intent (assigned_to), the claim and the addressee, kept apart.
static func owner_text(node: Dictionary) -> String:
	var owner: Dictionary = _dict(node, "owner")
	var parts: PackedStringArray = []
	for pair: Array in [["assigned_to", "assigned"], ["claim_holder", "claimed by"], ["directed_to", "to"]]:
		var value := str(owner.get(pair[0], ""))
		if not value.is_empty():
			parts.append("%s %s" % [pair[1], value])
	return " · ".join(parts)


## Observed activity. `confirmed_at` is the newest time the host's session
## evidence was read and found as the tree shows it; `stale` is set when no
## reply has arrived recently, which makes every node unknown.
static func activity_text(node: Dictionary, confirmed_at: String, stale: bool) -> String:
	var activity: Dictionary = _dict(node, "activity")
	if stale:
		return "unknown — evidence stale (last reply %s)" % local_time(confirmed_at)
	if bool(activity.get("unknown", true)):
		var sessions: Array = _array(activity, "sessions")
		if sessions.size() > 1:
			return "unknown — %d sessions share this principal" % sessions.size()
		if str(node.get("kind", "")) == "actor" and sessions.size() == 1:
			return "unknown — session %s reports no usable state" % str(sessions[0])
		return "unknown — no session evidence"
	var parts: PackedStringArray = []
	var liveness := str(activity.get("liveness", ""))
	if not liveness.is_empty():
		parts.append("session " + liveness)
	parts.append("last observed " + local_time(confirmed_at))
	var last_activity := str(activity.get("last_activity_at", ""))
	parts.append("last activity " + (local_time(last_activity) if not last_activity.is_empty() else "unknown"))
	return " · ".join(parts)


static func activity_is_known(node: Dictionary, stale: bool) -> bool:
	return not stale and not bool(_dict(node, "activity").get("unknown", true))


## The first column: kind, title and record revision.
static func label_text(node: Dictionary) -> String:
	var kind := str(node.get("kind", ""))
	var title := str(node.get("title", ""))
	var text := "%s: %s" % [kind, title if not title.is_empty() else str(node.get("id", ""))]
	if node.get("revision") != null:
		text += "  (rev %d)" % int(node.get("revision"))
	var hidden := int(node.get("children_hidden", 0))
	if hidden > 0:
		text += "  [+%d below depth limit]" % hidden
	return text


## What "changed since" compares: every recorded fact the tree shows.
## Observed activity is not part of it.
static func fingerprint(node: Dictionary) -> String:
	var rev: String = str(int(node.get("revision"))) if node.get("revision") != null else "-"
	return "|".join(PackedStringArray([rev, stage_text(node), owner_text(node),
		str(int(node.get("remaining_total", 0))), JSON.stringify(_dict(node, "links")),
		JSON.stringify(_dict(node, "refs")), JSON.stringify(_dict(node, "metrics"))]))


## The record a node opens: its own for objectives, tasks and attempts; the
## attempt's for a role or actor, whose ids extend the attempt's.
static func record_id(node: Dictionary) -> String:
	return str(node.get("id", "")).get_slice("/role:", 0)


## The token/time column: a summary of the MEASUREMENTS table the process
## recorded on this record, or "not measured" when it recorded none. Role and
## actor rows are not records and show nothing.
static func metrics_summary(node: Dictionary) -> String:
	var kind := str(node.get("kind", ""))
	if kind == "role" or kind == "actor":
		return ""
	var metrics: Dictionary = _dict(node, "metrics")
	if metrics.is_empty():
		return "not measured"
	var rows: Array = _array(metrics, "rows")
	var unknown := 0
	for row: Variant in rows:
		for cell: Variant in (row as Array if row is Array else []):
			if is_unknown_cell(str(cell)):
				unknown += 1
	var text := "%d rows" % int(metrics.get("rows_total", rows.size()))
	text += " · %d unknown" % unknown if unknown > 0 else " · none unknown"
	if coverage_column(metrics) < 0:
		text += " · no coverage column"
	return text


static func is_measured(node: Dictionary) -> bool:
	return not _dict(node, "metrics").is_empty()


## A cell the process left unknown: empty, "?", or starting with "unknown".
static func is_unknown_cell(cell: String) -> bool:
	var t := cell.strip_edges().to_lower()
	return t.is_empty() or t == "?" or t.begins_with("unknown")


## The index of the table's coverage column (a header naming coverage), or -1.
static func coverage_column(metrics: Dictionary) -> int:
	var columns: Array = _array(metrics, "columns")
	for i: int in columns.size():
		if str(columns[i]).to_lower().contains("coverage"):
			return i
	return -1


## The MEASUREMENTS table as BBCode, cell for cell: unknown cells are marked,
## the coverage column is set apart, and nothing is summed.
static func metrics_bbcode(node: Dictionary) -> String:
	var metrics: Dictionary = _dict(node, "metrics")
	if metrics.is_empty():
		return "  not measured — the process recorded no MEASUREMENTS table on this record"
	var columns: Array = _array(metrics, "columns")
	var rows: Array = _array(metrics, "rows")
	var coverage := coverage_column(metrics)
	var out: PackedStringArray = []
	out.append("[table=%d]" % maxi(columns.size(), 1))
	for i: int in columns.size():
		out.append("[cell][b]%s[/b][/cell]" % esc(str(columns[i])))
	for row: Variant in rows:
		var cells: Array = row as Array if row is Array else []
		for i: int in columns.size():
			var cell := str(cells[i]) if i < cells.size() else ""
			var text := esc(cell)
			if is_unknown_cell(cell):
				text = "[color=orange]%s[/color]" % (text if not cell.strip_edges().is_empty() else "unknown")
			elif i == coverage:
				text = "[i]%s[/i]" % text
			out.append("[cell]%s  [/cell]" % text)
	out.append("[/table]")
	var total := int(metrics.get("rows_total", rows.size()))
	if total > rows.size():
		out.append("  … %d more rows on the record" % (total - rows.size()))
	if coverage < 0:
		out.append("  [color=orange]no coverage column supplied[/color]")
	out.append("  [color=gray]As the process recorded it; unknown stays unknown and nothing is summed.[/color]")
	return "\n".join(out)


## Where the node leads: its record, the commits its tags name, its reviews
## and its runs. `runs` holds what the host last said about each run
## ("session/job" → job status, or {error}); a run not yet asked about reads
## "asking the host".
static func refs_bbcode(node: Dictionary, loaded: Dictionary, runs: Dictionary) -> String:
	var out: PackedStringArray = []
	var record := record_id(node)
	var kind := str(node.get("kind", ""))
	var own := "its attempt's record" if kind == "role" or kind == "actor" else "record"
	out.append("  [url=open:%s]Open %s in Docket[/url]  [color=gray](%s)[/color]" % [record, own, esc(record)])
	var refs: Dictionary = _dict(node, "refs")
	for rev: Variant in _array(refs, "revisions"):
		if rev is Dictionary:
			out.append("  " + _revision_line(rev))
	var review := str(_dict(node, "stage").get("review", ""))
	if not review.is_empty() or not _array(refs, "reviews").is_empty():
		out.append("  review: %s — findings are comments on the task record" % esc(review if not review.is_empty() else "no review: fact recorded"))
	for target: Variant in _array(refs, "reviews"):
		out.append("  reviewer attempt " + _link(str(target), loaded))
	for run: Variant in _array(refs, "runs"):
		if run is Dictionary:
			out.append_array(_run_lines(run, runs))
	return "\n".join(out)


static func _revision_line(rev: Dictionary) -> String:
	var sha := str(rev.get("sha", ""))
	if sha.is_empty():
		return "%s [color=gray](unreadable revision tag)[/color]" % esc(str(rev.get("tag", "")))
	var where := str(rev.get("repo", ""))
	if not str(rev.get("branch", "")).is_empty():
		where += " " + str(rev.get("branch", ""))
	return "%s %s @ %s  [url=copy:%s]copy[/url]" % [esc(str(rev.get("kind", ""))), esc(where), esc(sha.left(12)), sha]


static func _run_lines(run: Dictionary, runs: Dictionary) -> PackedStringArray:
	var session := str(run.get("session", ""))
	var job := str(run.get("job", ""))
	if session.is_empty() or job.is_empty():
		return PackedStringArray(["  %s [color=gray](unreadable run tag)[/color]" % esc(str(run.get("tag", "")))])
	var key := session + "/" + job
	var lines: PackedStringArray = []
	if not runs.has(key):
		lines.append("  run %s — asking the host…" % esc(key))
		return lines
	var status: Dictionary = runs[key]
	if status.has("error"):
		lines.append("  run %s — [color=orange]not available: %s[/color]" % [esc(key), esc(str(status["error"]))])
		return lines
	var cls := str(status.get("class", "unknown"))
	lines.append("  run %s — %s: %s  [url=log:%s]open log[/url]" % [esc(key), esc(cls),
		esc(str(status.get("detail", ""))), key])
	var result: Dictionary = _dict(status, "result")
	var revision := str(result.get("revision", status.get("revision", "")))
	if not revision.is_empty():
		lines.append("    ran at %s  [url=copy:%s]copy[/url]" % [esc(revision.left(12)), revision])
	for artifact: Variant in _array(result, "artifacts"):
		if artifact is Dictionary:
			lines.append("    " + _artifact_line(artifact, cls))
	return lines


## A present artifact links to its file; one that is gone reads missing.
static func _artifact_line(artifact: Dictionary, cls: String) -> String:
	var path := esc(str(artifact.get("path", "")))
	if not bool(artifact.get("present", false)):
		return "artifact %s — [color=orange]missing[/color]" % path
	var line := "artifact [url=artifact:%s]%s[/url]" % [str(artifact.get("host_path", "")), path]
	if not bool(artifact.get("complete", false)):
		line += " [color=gray](not claimed complete: job %s)[/color]" % esc(cls)
	return line


## The viewer's own cost: the last refresh cycle and the running total since
## the panel opened. Viewer cost only; it says nothing about the work itself.
static func overhead_text(last: Dictionary, totals: Dictionary) -> String:
	if last.is_empty():
		return "Viewer cost: no refresh measured yet."
	var tools: PackedStringArray = []
	var by_tool: Dictionary = _dict(last, "by_tool")
	for tool: String in by_tool:
		tools.append("%s %d" % [tool, int(by_tool[tool])])
	return ("Viewer cost, last refresh at %s: %d panel call(s) · %d host call(s)%s · %s from the host, %s to the panel" +
		" · backend %.0f ms (%.0f ms waiting on the host) · panel wall %d ms%s.  Since opened: %d refreshes," +
		" %d host calls, %s read, %d navigation calls.") % [
		local_time(str(last.get("at", ""))), int(last.get("panel_calls", 0)), int(last.get("host_calls", 0)),
		(" (" + ", ".join(tools) + ")") if not tools.is_empty() else "",
		String.humanize_size(int(last.get("bytes_read", 0))), String.humanize_size(int(last.get("reply_bytes", 0))),
		float(last.get("worker_ms", 0.0)), float(last.get("wait_ms", 0.0)), int(last.get("wall_ms", 0)),
		" · full reload" if bool(last.get("full_reload", false)) else "",
		int(totals.get("cycles", 0)), int(totals.get("host_calls", 0)),
		String.humanize_size(int(totals.get("bytes_read", 0))), int(totals.get("nav_calls", 0))]


## The details pane for one node, as BBCode. Cross-link targets that are in
## the loaded tree become [url] links the panel follows.
static func details(node: Dictionary, loaded: Dictionary, confirmed_at: String, stale: bool,
		change: String, runs: Dictionary) -> String:
	var out: PackedStringArray = []
	out.append("[b]%s[/b]" % esc(label_text(node)))
	out.append("[color=gray]%s[/color]" % esc(str(node.get("id", ""))))
	if not change.is_empty():
		out.append("[color=yellow]%s[/color]" % esc(change))
	if bool(node.get("partial", false)):
		out.append("[i]Shown only as the path to records you may see; its other children are withheld.[/i]")

	out.append("\n[b]Record, revisions, reviews and runs[/b]")
	out.append(refs_bbcode(node, loaded, runs))

	out.append("\n[b]Recorded stage[/b] (from the records)")
	var stage: Dictionary = _dict(node, "stage")
	if stage.is_empty():
		out.append("  none recorded on this node")
	for key: String in ["status", "result", "outcome", "review", "test", "resolution"]:
		var value := str(stage.get(key, ""))
		if not value.is_empty():
			out.append("  %s: %s" % [key, esc(value)])
	for item: Variant in _array(stage, "deferred"):
		out.append("  deferred: %s" % esc(str(item)))
	for flag: String in flags(node):
		out.append("  [color=orange]%s[/color]" % flag)

	var owner := owner_text(node)
	out.append("\n[b]Ownership[/b]")
	out.append("  " + (esc(owner) if not owner.is_empty() else "none recorded"))

	var links: Dictionary = _dict(node, "links")
	if not links.is_empty():
		out.append("\n[b]Cross-links[/b]")
		var blocked_by := str(links.get("blocked_by", ""))
		if not blocked_by.is_empty():
			out.append("  blocked by " + _link(blocked_by, loaded))
		for pair: Array in [["blocks", "blocks"], ["retry_of", "retry of"], ["retried_by", "retried by"]]:
			for target: Variant in _array(links, pair[0]):
				out.append("  %s %s" % [pair[1], _link(str(target), loaded)])

	var remaining: Array = _array(node, "remaining")
	var total := int(node.get("remaining_total", 0))
	if total > 0:
		out.append("\n[b]Remaining acceptance[/b] (%d)" % total)
		for criterion: Variant in remaining:
			if criterion is Dictionary:
				var c: Dictionary = criterion
				out.append("  • %s  [color=gray](%s)[/color]" % [esc(str(c.get("text", ""))),
					_link(str(c.get("task", "")), loaded)])
		if total > remaining.size():
			out.append("  … %d more not shown" % (total - remaining.size()))

	var kind := str(node.get("kind", ""))
	if kind != "role" and kind != "actor":
		out.append("\n[b]Tokens and time[/b] (as the process recorded them)")
		out.append(metrics_bbcode(node))

	out.append("\n[b]Observed activity[/b] (from the host, not the records)")
	out.append("  " + esc(activity_text(node, confirmed_at, stale)))
	var sessions: Array = _array(_dict(node, "activity"), "sessions")
	if not sessions.is_empty():
		out.append("  sessions: " + esc(", ".join(PackedStringArray(sessions.map(func(s: Variant) -> String: return str(s))))))
	return "\n".join(out)


## A UTC RFC 3339 time as local "YYYY-MM-DD HH:MM:SS"; "?" when empty.
static func local_time(rfc3339: String) -> String:
	if rfc3339.length() < 19:
		return "?"
	var unix := Time.get_unix_time_from_datetime_string(rfc3339.substr(0, 19))
	var bias_minutes := int(Time.get_time_zone_from_system().get("bias", 0))
	return Time.get_datetime_string_from_unix_time(unix + bias_minutes * 60, true)


static func esc(text: String) -> String:
	return text.replace("[", "[lb]")


static func _link(target: String, loaded: Dictionary) -> String:
	if loaded.has(target):
		return "[url=node:%s]%s[/url]" % [target, esc(target)]
	return esc(target) + " [color=gray](not in view)[/color]"


static func _dict(from: Dictionary, key: String) -> Dictionary:
	var value: Variant = from.get(key)
	return value if value is Dictionary else {}


static func _array(from: Dictionary, key: String) -> Array:
	var value: Variant = from.get(key)
	return value if value is Array else []
