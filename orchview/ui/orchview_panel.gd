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

signal request(channel: String, payload: Dictionary, reply_id: String)

const Text := preload("orchview_text.gd")

const CHANNEL := "minerva_orchview_panel_tree"
const CALL_TIMEOUT_MS := 30000
## No reply for this long makes every node's activity unknown (stale).
const STALE_AFTER_MS := 30000
## A tree larger than this many pages is shown as far as it was read.
const MAX_PAGES := 50
const MAX_HISTORY := 20

const COLOR_BLOCKED := Color(0.95, 0.45, 0.45)
const COLOR_UNOWNED := Color(0.95, 0.65, 0.3)
const COLOR_CHANGED := Color(0.95, 0.9, 0.4)
const COLOR_UNKNOWN := Color(0.6, 0.6, 0.6)

@onready var _status: Label = %Status
@onready var _since_picker: OptionButton = %SincePicker
@onready var _refresh_button: Button = %RefreshButton
@onready var _tree: Tree = %Tree
@onready var _details: RichTextLabel = %Details
@onready var _poll_timer: Timer = %PollTimer

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


func _ready() -> void:
	_tree.columns = 4
	_tree.set_column_title(0, "Node")
	_tree.set_column_title(1, "Recorded stage")
	_tree.set_column_title(2, "Owner")
	_tree.set_column_title(3, "Observed activity")
	_tree.set_column_expand_ratio(0, 3)
	_tree.set_column_expand_ratio(1, 2)
	_tree.set_column_expand_ratio(2, 2)
	_tree.set_column_expand_ratio(3, 3)
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_collapsed.connect(_on_item_collapsed)
	_details.meta_clicked.connect(_on_link_clicked)
	_refresh_button.pressed.connect(_on_refresh_pressed)
	_since_picker.item_selected.connect(func(_index: int) -> void: _render())
	_poll_timer.timeout.connect(_on_tick)
	_rebuild_since_picker()
	_show_status()


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
	var args: Dictionary = {}
	if not _cursor.is_empty():
		args = {"since": _cursor, "evidence_since": _evidence}
	var first: Dictionary = await _call(args)
	if not is_inside_tree():
		return
	if first.is_empty():
		_busy = false
		_show_status()
		return
	var was_stale := _is_stale()
	_accept_reply(first)
	if bool(first.get("unchanged", false)):
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
			_busy = false
			_show_status()
			return
		_accept_reply(page)
		if bool(page.get("continuation_reset", false)):
			pages.clear()
		pages.append(page)
		token = str(page.get("continuation", ""))
	_apply(pages, not token.is_empty())
	_busy = false


func _accept_reply(reply: Dictionary) -> void:
	_confirmed_at = str(reply.get("observed_at", _confirmed_at))
	_last_ok_msec = Time.get_ticks_msec()
	_last_error = ""
	_was_stale = false
	_evidence_error = str(reply.get("evidence_error", ""))


## One call on the tree channel; {} on failure, with _last_error set.
func _call(args: Dictionary) -> Dictionary:
	var ipc: Node = get_node_or_null("_MinervaIPC")
	if ipc == null:
		_last_error = "this panel is not registered with the host"
		return {}
	var reply: Dictionary
	if ipc.has_method("request_bulk"):
		reply = await ipc.request_bulk(CHANNEL, args, CALL_TIMEOUT_MS)
	else:
		_reply_seq += 1
		var reply_id := "orchview-%d-%d" % [get_instance_id(), _reply_seq]
		request.emit(CHANNEL, args, reply_id)
		reply = await ipc.await_reply(reply_id, CALL_TIMEOUT_MS)
	if not bool(reply.get("success", false)):
		_last_error = str(reply.get("error_message", reply.get("error_code", "the backend did not answer")))
		return {}
	var body: Variant = reply.get("result")
	if not body is Dictionary or not bool((body as Dictionary).get("ok", true)):
		_last_error = str((body as Dictionary).get("error", "unreadable reply")) if body is Dictionary else "unreadable reply"
		return {}
	return body


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
		str(marks.get(_selected_id, "")))


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
	_status.text = "  ·  ".join(parts)


func _is_stale() -> bool:
	return _last_ok_msec < 0 or Time.get_ticks_msec() - _last_ok_msec > STALE_AFTER_MS


func _on_item_selected() -> void:
	var item := _tree.get_selected()
	if item == null or item.get_metadata(0) == null:
		return
	_selected_id = str(item.get_metadata(0))
	_show_details()


func _on_item_collapsed(item: TreeItem) -> void:
	if item.get_metadata(0) == null:
		return
	var id := str(item.get_metadata(0))
	if item.collapsed:
		_collapsed[id] = true
	else:
		_collapsed.erase(id)


func _on_link_clicked(meta: Variant) -> void:
	var id := str(meta)
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


static func _as_array(value: Variant) -> Array:
	return value if value is Array else []
