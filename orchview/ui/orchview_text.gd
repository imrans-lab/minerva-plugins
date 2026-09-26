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
		str(int(node.get("remaining_total", 0))), JSON.stringify(_dict(node, "links"))]))


## The details pane for one node, as BBCode. Cross-link targets that are in
## the loaded tree become [url] links the panel follows.
static func details(node: Dictionary, loaded: Dictionary, confirmed_at: String, stale: bool,
		change: String) -> String:
	var out: PackedStringArray = []
	out.append("[b]%s[/b]" % esc(label_text(node)))
	out.append("[color=gray]%s[/color]" % esc(str(node.get("id", ""))))
	if not change.is_empty():
		out.append("[color=yellow]%s[/color]" % esc(change))
	if bool(node.get("partial", false)):
		out.append("[i]Shown only as the path to records you may see; its other children are withheld.[/i]")

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
		return "[url=%s]%s[/url]" % [target, esc(target)]
	return esc(target) + " [color=gray](not in view)[/color]"


static func _dict(from: Dictionary, key: String) -> Dictionary:
	var value: Variant = from.get(key)
	return value if value is Dictionary else {}


static func _array(from: Dictionary, key: String) -> Array:
	var value: Variant = from.get(key)
	return value if value is Array else []
