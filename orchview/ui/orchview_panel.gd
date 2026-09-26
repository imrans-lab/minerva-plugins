extends Control

## The Orchestration View panel: a read-only tree of W1 work records —
## objectives → tasks → dispatch attempts → role instances → actors — from
## the backend's minerva_orchview_panel_tree channel.
##
## Refresh is incremental. Each tick sends the last cursor (a digest of the
## record revisions) and the last evidence digest (the host's session facts);
## when neither moved the backend answers `unchanged` and nothing is re-read or
## redrawn except the observation time. When either moved, the pages are read
## again from the first, following continuations, and the tree is rebuilt with
## its selection and collapsed rows kept.
##
## "Changes since" compares the current tree with a tree the panel kept
## earlier (one entry per distinct cursor seen, newest first), by each node's
## recorded facts.
##
## Navigation goes straight to host tools over capability channels: a record
## opens in the Docket view through minerva_docket_gui_open; a selected node's
## runs are asked of minerva_agent_session_job_status, a run's log comes from
## minerva_agent_session_job_log, and an artifact opens with minerva_os_open.
##
## Each refresh cycle is metered: the panel counts its calls and wall time and
## adds up the `overhead` each backend reply reports; the footer shows it.

signal request(channel: String, payload: Dictionary, reply_id: String)

const Text := preload("orchview_text.gd")

const CHANNEL := "minerva_orchview_panel_tree"
const CALL_TIMEOUT_MS := 30000
const NAV_TIMEOUT_MS := 15000
## The most log the host returns in one read (minerva_agent_session_job_log).
const LOG_TAIL_BYTES := 49152
## Job classes that never change once reported.
const FINAL_RUN_CLASSES: PackedStringArray = ["succeeded", "failed", "timed_out", "interrupted", "unknown"]
## No reply for this long makes every node's activity unknown (stale).
const STALE_AFTER_MS := 30000
## A tree larger than this many pages is shown as far as it was read.
const MAX_PAGES := 50
const MAX_HISTORY := 20

const COLOR_BLOCKED := Color(0.95, 0.45, 0.45)
const COLOR_UNOWNED := Color(0.95, 0.65, 0.3)
const COLOR_CHANGED := Color(0.95, 0.9, 0.4)
const COLOR_UNKNOWN := Color(0.6, 0.6, 0.6)
const COLUMN_METRICS := 4

@onready var _status: Label = %Status
@onready var _since_picker: OptionButton = %SincePicker
@onready var _refresh_button: Button = %RefreshButton
@onready var _tree: Tree = %Tree
@onready var _details: RichTextLabel = %Details
@onready var _poll_timer: Timer = %PollTimer
@onready var _overhead: Label = %Overhead
@onready var _log_dialog: AcceptDialog = %LogDialog
@onready var _log_text: TextEdit = %LogText

## id → node Dictionary (children removed); the tree's structure is kept in
## _children and _roots, in the order the pages delivered it.
var _nodes: Dictionary = {}
var _children: Dictionary = {}
var _roots: PackedStringArray = []
var _cursor: String = ""
var _evidence: String = ""
var _scope: String = ""
var _projects: PackedStringArray = []
var _truncated: bool = false
var _evidence_error: String = ""

## The newest observation time the host confirmed, and when (ticks) the last
## reply of any kind arrived.
var _confirmed_at: String = ""
var _last_ok_msec: int = -1
var _last_error: String = ""
var _was_stale: bool = false

## Earlier trees: [{cursor, at, prints: {id: fingerprint}}], newest first.
var _history: Array[Dictionary] = []
var _selected_id: String = ""
var _collapsed: Dictionary = {}
var _busy: bool = false
var _reply_seq: int = 0
var _items: Dictionary = {}

## "session/job" → the host's job status, or {error}; final ones are kept.
var _runs: Dictionary = {}
## The outcome of the last navigation click, shown in the status line.
var _nav_message: String = ""
## The refresh cycle being metered, the last finished one, and running totals.
var _cycle: Dictionary = {}
var _last_overhead: Dictionary = {}
var _totals: Dictionary = {"cycles": 0, "host_calls": 0, "bytes_read": 0, "nav_calls": 0}


func _ready() -> void:
	_tree.columns = 5
	_tree.set_column_title(0, "Node")
	_tree.set_column_title(1, "Recorded stage")
	_tree.set_column_title(2, "Owner")
	_tree.set_column_title(3, "Observed activity")
	_tree.set_column_title(COLUMN_METRICS, "Tokens / time")
	_tree.set_column_expand_ratio(0, 3)
	_tree.set_column_expand_ratio(1, 2)
	_tree.set_column_expand_ratio(2, 2)
	_tree.set_column_expand_ratio(3, 3)
	_tree.set_column_expand_ratio(COLUMN_METRICS, 2)
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_collapsed.connect(_on_item_collapsed)
	_details.meta_clicked.connect(_on_link_clicked)
	_refresh_button.pressed.connect(_on_refresh_pressed)
	_since_picker.item_selected.connect(func(_index: int) -> void: _render())
	_poll_timer.timeout.connect(_on_tick)
	_rebuild_since_picker()
	_show_status()
	_overhead.text = Text.overhead_text(_last_overhead, _totals)


func _on_panel_loaded(_ctx: Dictionary) -> void:
	_poll_timer.start()
	_poll()


func _on_panel_unload() -> void:
	_poll_timer.stop()


func _on_tick() -> void:
	var stale := _is_stale()
	if stale != _was_stale:
		_was_stale = stale
		_render()
	_poll()


func _on_refresh_pressed() -> void:
	_cursor = ""
	_poll()


# ── Reading ──────────────────────────────────────────────────────────────────

func _poll() -> void:
	if _busy:
		return
	_busy = true
	_cycle = {"started_msec": Time.get_ticks_msec(), "panel_calls": 0, "host_calls": 0, "by_tool": {},
		"bytes_read": 0, "reply_bytes": 0, "worker_ms": 0.0, "wait_ms": 0.0, "full_reload": false}
	var args: Dictionary = {}
	if not _cursor.is_empty():
		args = {"since": _cursor, "evidence_since": _evidence}
	var first: Dictionary = await _call(args)
	if not is_inside_tree():
		return
	if first.is_empty():
		_end_cycle()
		_busy = false
		_show_status()
		return
	var was_stale := _is_stale()
	_accept_reply(first)
	if bool(first.get("unchanged", false)):
		_end_cycle()
		_busy = false
		if was_stale:
			_render()
		else:
			_render_observation()
		return
	var pages: Array[Dictionary] = [first]
	var token := str(first.get("continuation", ""))
	while not token.is_empty() and pages.size() < MAX_PAGES:
		var page: Dictionary = await _call({"continuation": token})
		if not is_inside_tree():
			return
		if page.is_empty():
			_end_cycle()
			_busy = false
			_show_status()
			return
		_accept_reply(page)
		if bool(page.get("continuation_reset", false)):
			pages.clear()
		pages.append(page)
		token = str(page.get("continuation", ""))
	_end_cycle()
	_apply(pages, not token.is_empty())
	_busy = false


func _accept_reply(reply: Dictionary) -> void:
	_confirmed_at = str(reply.get("observed_at", _confirmed_at))
	_last_ok_msec = Time.get_ticks_msec()
	_last_error = ""
	_was_stale = false
	_evidence_error = str(reply.get("evidence_error", ""))


## One call on the tree channel; {} on failure, with _last_error set. The
## reply's `overhead` is added to the cycle being metered.
func _call(args: Dictionary) -> Dictionary:
	_cycle["panel_calls"] = int(_cycle.get("panel_calls", 0)) + 1
	var reply := await _send(CHANNEL, args, CALL_TIMEOUT_MS)
	if not bool(reply.get("success", false)):
		_last_error = str(reply.get("error_message", reply.get("error_code", "the backend did not answer")))
		return {}
	var body: Variant = reply.get("result")
	if not body is Dictionary or not bool((body as Dictionary).get("ok", true)):
		_last_error = str((body as Dictionary).get("error", "unreadable reply")) if body is Dictionary else "unreadable reply"
		return {}
	_meter(body.get("overhead"))
	return body


## One request on a declared channel: the host's {success, result} or
## {success: false, error_code, error_message} reply.
func _send(channel: String, args: Dictionary, timeout_ms: int) -> Dictionary:
	var ipc: Node = get_node_or_null("_MinervaIPC")
	if ipc == null:
		return {"success": false, "error_message": "this panel is not registered with the host"}
	if ipc.has_method("request_bulk"):
		return await ipc.request_bulk(channel, args, timeout_ms)
	_reply_seq += 1
	var reply_id := "orchview-%d-%d" % [get_instance_id(), _reply_seq]
	request.emit(channel, args, reply_id)
	return await ipc.await_reply(reply_id, timeout_ms)


func _meter(reported: Variant) -> void:
	if not reported is Dictionary:
		return
	var o: Dictionary = reported
	var host: Dictionary = o.get("host") if o.get("host") is Dictionary else {}
	_cycle["host_calls"] = int(_cycle.get("host_calls", 0)) + int(host.get("calls", 0))
	_cycle["bytes_read"] = int(_cycle.get("bytes_read", 0)) + int(host.get("bytes_read", 0))
	_cycle["wait_ms"] = float(_cycle.get("wait_ms", 0.0)) + float(host.get("wait_ms", 0.0))
	_cycle["reply_bytes"] = int(_cycle.get("reply_bytes", 0)) + int(o.get("reply_bytes", 0))
	_cycle["worker_ms"] = float(_cycle.get("worker_ms", 0.0)) + float(o.get("worker_ms", 0.0))
	_cycle["full_reload"] = bool(_cycle.get("full_reload", false)) or bool(o.get("full_reload", false))
	var by_tool: Dictionary = _cycle.get("by_tool", {})
	var reported_tools: Dictionary = host.get("by_tool") if host.get("by_tool") is Dictionary else {}
	for tool: String in reported_tools:
		by_tool[tool] = int(by_tool.get(tool, 0)) + int(reported_tools[tool])
	_cycle["by_tool"] = by_tool


## Close the metered cycle: keep it as the last and add it to the totals.
func _end_cycle() -> void:
	_cycle["wall_ms"] = Time.get_ticks_msec() - int(_cycle.get("started_msec", Time.get_ticks_msec()))
	_cycle["at"] = _confirmed_at
	_last_overhead = _cycle
	_totals["cycles"] = int(_totals["cycles"]) + 1
	_totals["host_calls"] = int(_totals["host_calls"]) + int(_cycle.get("host_calls", 0))
	_totals["bytes_read"] = int(_totals["bytes_read"]) + int(_cycle.get("bytes_read", 0))
	_overhead.text = Text.overhead_text(_last_overhead, _totals)


## Replace the held tree with the pages' nodes.
func _apply(pages: Array[Dictionary], cut_short: bool) -> void:
	_nodes.clear()
	_children.clear()
	_roots = []
	for page: Dictionary in pages:
		for root: Variant in _as_array(page.get("tree")):
			if root is Dictionary:
				_absorb(root, str((root as Dictionary).get("parent", "")))
	var last: Dictionary = pages[pages.size() - 1]
	_cursor = str(last.get("cursor", ""))
	_evidence = str(last.get("evidence", ""))
	_scope = str(last.get("scope", ""))
	_truncated = cut_short or bool(last.get("truncated", false))
	_projects = PackedStringArray(_as_array(last.get("projects")).map(func(p: Variant) -> String: return str(p)))
	_remember()
	_render()


func _absorb(node: Dictionary, parent: String) -> void:
	var id := str(node.get("id", ""))
	var own: Dictionary = node.duplicate()
	own.erase("children")
	_nodes[id] = own
	if not parent.is_empty() and _nodes.has(parent):
		var siblings: PackedStringArray = _children.get(parent, PackedStringArray())
		siblings.append(id)
		_children[parent] = siblings
	else:
		_roots.append(id)
	for child: Variant in _as_array(node.get("children")):
		if child is Dictionary:
			_absorb(child, id)


## Keep this tree for "changes since", once per distinct cursor.
func _remember() -> void:
	if not _history.is_empty() and str(_history[0].get("cursor", "")) == _cursor:
		return
	var prints: Dictionary = {}
	for id: String in _nodes:
		prints[id] = Text.fingerprint(_nodes[id])
	_history.push_front({"cursor": _cursor, "at": _confirmed_at, "prints": prints})
	if _history.size() > MAX_HISTORY:
		_history.resize(MAX_HISTORY)
	_rebuild_since_picker()


func _rebuild_since_picker() -> void:
	var chosen := _baseline_cursor()
	_since_picker.clear()
	_since_picker.add_item("(no comparison)")
	_since_picker.set_item_metadata(0, "")
	for entry: Dictionary in _history.slice(1):
		var cursor := str(entry.get("cursor", ""))
		_since_picker.add_item("%s  ·  %s" % [Text.local_time(str(entry.get("at", ""))), cursor.right(8)])
		_since_picker.set_item_metadata(_since_picker.item_count - 1, cursor)
	for index: int in _since_picker.item_count:
		if str(_since_picker.get_item_metadata(index)) == chosen:
			_since_picker.select(index)


func _baseline_cursor() -> String:
	if _since_picker.item_count == 0 or _since_picker.selected < 0:
		return ""
	return str(_since_picker.get_item_metadata(_since_picker.selected))


## id → "changed" / "new" against the chosen baseline, and the ids removed.
func _changes() -> Dictionary:
	var baseline := _baseline_cursor()
	var marks: Dictionary = {}
	var removed: PackedStringArray = []
	if baseline.is_empty():
		return {"marks": marks, "removed": removed}
	var prints: Dictionary = {}
	for entry: Dictionary in _history:
		if str(entry.get("cursor", "")) == baseline:
			prints = entry.get("prints", {})
	for id: String in _nodes:
		if not prints.has(id):
			marks[id] = "new since the chosen revision"
		elif str(prints[id]) != Text.fingerprint(_nodes[id]):
			marks[id] = "changed since the chosen revision"
	for id: String in prints:
		if not _nodes.has(id):
			removed.append(id)
	return {"marks": marks, "removed": removed}


# ── Drawing ──────────────────────────────────────────────────────────────────

func _render() -> void:
	var changes := _changes()
	var marks: Dictionary = changes["marks"]
	var stale := _is_stale()
	_tree.clear()
	_items.clear()
	var root := _tree.create_item()
	for id: String in _roots:
		_add_row(root, id, marks, stale)
	var removed: PackedStringArray = changes["removed"]
	if not removed.is_empty():
		var gone := _tree.create_item(root)
		gone.set_text(0, "removed since the chosen revision (%d)" % removed.size())
		gone.set_custom_color(0, COLOR_CHANGED)
		for id: String in removed:
			_tree.create_item(gone).set_text(0, id)
	if _items.has(_selected_id):
		var selected: TreeItem = _items[_selected_id]
		selected.select(0)
		_tree.scroll_to_item(selected)
	_show_details()
	_show_status()


func _add_row(parent: TreeItem, id: String, marks: Dictionary, stale: bool) -> void:
	var node: Dictionary = _nodes[id]
	var item := _tree.create_item(parent)
	_items[id] = item
	item.set_metadata(0, id)
	var label := Text.label_text(node)
	if marks.has(id):
		label = "● " + label
		item.set_custom_color(0, COLOR_CHANGED)
	item.set_text(0, label)
	item.set_tooltip_text(0, id)
	item.set_text(1, Text.stage_text(node))
	if bool(node.get("blocked", false)):
		item.set_custom_color(1, COLOR_BLOCKED)
	elif bool(node.get("unowned", false)):
		item.set_custom_color(1, COLOR_UNOWNED)
	item.set_text(2, Text.owner_text(node))
	item.set_text(3, Text.activity_text(node, _confirmed_at, stale))
	if not Text.activity_is_known(node, stale):
		item.set_custom_color(3, COLOR_UNKNOWN)
	item.set_text(COLUMN_METRICS, Text.metrics_summary(node))
	if not Text.is_measured(node):
		item.set_custom_color(COLUMN_METRICS, COLOR_UNKNOWN)
	if str(node.get("kind", "")) == "objective":
		_add_remaining(item, node)
	for child: String in _children.get(id, PackedStringArray()):
		_add_row(item, child, marks, stale)
	item.collapsed = _collapsed.has(id)


## The objective's remaining acceptance criteria as rows under it.
func _add_remaining(item: TreeItem, node: Dictionary) -> void:
	var total := int(node.get("remaining_total", 0))
	var group := _tree.create_item(item)
	group.set_text(0, "remaining acceptance (%d)" % total if total > 0 else "remaining acceptance: none")
	group.set_selectable(0, false)
	var shown := _as_array(node.get("remaining"))
	for criterion: Variant in shown:
		if criterion is Dictionary:
			var row := _tree.create_item(group)
			row.set_text(0, str((criterion as Dictionary).get("text", "")))
			row.set_tooltip_text(0, str((criterion as Dictionary).get("task", "")))
			row.set_text(2, str((criterion as Dictionary).get("task", "")))
	if total > shown.size():
		_tree.create_item(group).set_text(0, "… %d more (see the tasks)" % (total - shown.size()))


func _render_observation() -> void:
	var stale := _is_stale()
	for id: String in _items:
		var item: TreeItem = _items[id]
		item.set_text(3, Text.activity_text(_nodes[id], _confirmed_at, stale))
	_show_details()
	_show_status()


func _show_details() -> void:
	if not _nodes.has(_selected_id):
		_details.text = "Select a node to see its recorded stage, ownership, cross-links, remaining acceptance and observed activity."
		return
	var marks: Dictionary = _changes()["marks"]
	_details.text = Text.details(_nodes[_selected_id], _nodes, _confirmed_at, _is_stale(),
		str(marks.get(_selected_id, "")), _runs)


func _show_status() -> void:
	var parts: PackedStringArray = []
	parts.append("%d nodes" % _nodes.size() + (" (partial read)" if _truncated else ""))
	if not _scope.is_empty():
		parts.append("scope " + _scope)
	if not _projects.is_empty():
		parts.append("projects " + ", ".join(_projects))
	if not _cursor.is_empty():
		parts.append("cursor " + _cursor.right(8))
	if not _confirmed_at.is_empty():
		parts.append("evidence read " + Text.local_time(_confirmed_at))
	if not _evidence_error.is_empty():
		parts.append("session evidence unavailable: " + _evidence_error)
	if not _last_error.is_empty():
		parts.append("last read failed: " + _last_error)
	if not _nav_message.is_empty():
		parts.append(_nav_message)
	_status.text = "  ·  ".join(parts)


func _is_stale() -> bool:
	return _last_ok_msec < 0 or Time.get_ticks_msec() - _last_ok_msec > STALE_AFTER_MS


func _on_item_selected() -> void:
	var item := _tree.get_selected()
	if item == null or item.get_metadata(0) == null:
		return
	_selected_id = str(item.get_metadata(0))
	_show_details()
	_resolve_runs(_selected_id)


func _on_item_collapsed(item: TreeItem) -> void:
	if item.get_metadata(0) == null:
		return
	var id := str(item.get_metadata(0))
	if item.collapsed:
		_collapsed[id] = true
	else:
		_collapsed.erase(id)


## Details links: node:<id> selects in the tree; open:<project:id> opens the
## record; copy:<text> copies; log:<session/job> shows the run's log;
## artifact:<host path> opens the file.
func _on_link_clicked(meta: Variant) -> void:
	var link := str(meta)
	var scheme := link.get_slice(":", 0)
	var value := link.substr(scheme.length() + 1)
	match scheme:
		"node":
			_select(value)
		"open":
			_open_record(value)
		"copy":
			DisplayServer.clipboard_set(value)
			_nav_message = "copied " + value
			_show_status()
		"log":
			_open_log(value)
		"artifact":
			_open_artifact(value)


func _select(id: String) -> void:
	if not _items.has(id):
		return
	_selected_id = id
	var item: TreeItem = _items[id]
	var up := item.get_parent()
	while up != null:
		up.collapsed = false
		up = up.get_parent()
	item.select(0)
	_tree.scroll_to_item(item)
	_show_details()
	_resolve_runs(id)


# ── Navigation ───────────────────────────────────────────────────────────────

## A host tool through its capability channel: the tool's result, or
## {error} when the host or the tool refused.
func _host_tool(tool: String, args: Dictionary) -> Dictionary:
	_totals["nav_calls"] = int(_totals["nav_calls"]) + 1
	var reply := await _send("capability:mcp.proxy:" + tool, args, NAV_TIMEOUT_MS)
	if not bool(reply.get("success", false)):
		return {"error": str(reply.get("error_message", reply.get("error_code", "the host did not answer")))}
	var body: Variant = reply.get("result")
	if body is Dictionary and (body as Dictionary).get("content") is Array:
		var content: Array = (body as Dictionary)["content"]
		if content.size() == 1 and content[0] is Dictionary:
			var parsed: Variant = JSON.parse_string(str((content[0] as Dictionary).get("text", "")))
			if parsed is Dictionary:
				body = parsed
	if not body is Dictionary:
		return {"error": "unreadable reply from " + tool}
	var result: Dictionary = body
	if result.get("ok", true) == false or result.has("error"):
		return {"error": str(result.get("error", result.get("message", "refused")))}
	return result


## Open a record (project:id) in the host's Docket view.
func _open_record(key: String) -> void:
	var project := key.get_slice(":", 0)
	var id := key.substr(project.length() + 1)
	var result := await _host_tool("minerva_docket_gui_open", {"id": id, "project": project})
	_nav_message = ("could not open %s: %s" % [key, result["error"]]) if result.has("error") else "opened " + key
	_show_status()


## Ask the host about each run of the node that has no final answer yet,
## then redraw the details if the node is still selected.
func _resolve_runs(id: String) -> void:
	if not _nodes.has(id):
		return
	var refs: Variant = (_nodes[id] as Dictionary).get("refs")
	if not refs is Dictionary:
		return
	for run: Variant in _as_array((refs as Dictionary).get("runs")):
		if not run is Dictionary:
			continue
		var session := str((run as Dictionary).get("session", ""))
		var job := str((run as Dictionary).get("job", ""))
		var key := session + "/" + job
		if session.is_empty() or job.is_empty() or _run_is_final(key):
			continue
		var status := await _host_tool("minerva_agent_session_job_status", {"name": session, "job": job})
		if not is_inside_tree():
			return
		_runs[key] = status
		if _selected_id == id:
			_show_details()


func _run_is_final(key: String) -> bool:
	var known: Dictionary = _runs.get(key, {})
	return bool(known.get("final", false)) and str(known.get("class", "")) in FINAL_RUN_CLASSES


## Show the tail of a run's log (session/job) in the log dialog.
func _open_log(key: String) -> void:
	var session := key.get_slice("/", 0)
	var job := key.get_slice("/", 1)
	var result := await _host_tool("minerva_agent_session_job_log", {"name": session, "job": job, "tail": LOG_TAIL_BYTES})
	if not is_inside_tree():
		return
	if result.has("error"):
		_nav_message = "could not read the log of %s: %s" % [key, result["error"]]
		_show_status()
		return
	var size := int(result.get("size", 0))
	_log_dialog.title = "Log — run %s (%s, %s%s)" % [key, str(result.get("class", "?")), String.humanize_size(size),
		", last %s shown" % String.humanize_size(LOG_TAIL_BYTES) if bool(result.get("truncated", false)) else ""]
	_log_text.text = str(result.get("log", ""))
	_log_dialog.popup_centered_ratio(0.7)
	_nav_message = ""
	_show_status()


func _open_artifact(path: String) -> void:
	var result := await _host_tool("minerva_os_open", {"path": path})
	_nav_message = ("could not open %s: %s" % [path, result["error"]]) if result.has("error") else "opened " + path
	_show_status()


static func _as_array(value: Variant) -> Array:
	return value if value is Array else []
