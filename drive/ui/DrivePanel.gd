class_name Drive_Panel
extends MinervaPluginPanel
## Drive panel — shows sync status, lists projects, and allows manual sync.
##
## Off-tree class_name gotcha:
##   This plugin lives outside Minerva's res:// tree, so the Godot parser cache
##   cannot resolve plugin-local class_names from typed field declarations.
##   All node references use base-class typing only.

# ── UI node references (set in _build_ui) ────────────────────────────────────

## Outer scroll so the panel remains usable at any pane height.
var _scroll: ScrollContainer = null

## Single-column root layout.
var _main_vbox: VBoxContainer = null

## Header row: device/connection label + action buttons.
var _header_row: HBoxContainer = null
var _device_label: Label = null
var _sync_btn: Button = null
var _add_btn: Button = null
var _remove_btn: Button = null
var _reveal_btn: Button = null
var _open_ext_btn: Button = null

## Status line: shows sync result, errors, or connectivity problems.
var _status_label: Label = null

## Tree showing one row per project.
var _project_tree: Tree = null

# ── State ─────────────────────────────────────────────────────────────────────

var _in_flight: bool = false


# ── Godot lifecycle ───────────────────────────────────────────────────────────

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()


# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	_scroll = ScrollContainer.new()
	_scroll.name = "MainScroll"
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_main_vbox = VBoxContainer.new()
	_main_vbox.name = "MainVBox"
	_main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# SIZE_SHRINK_BEGIN inside a ScrollContainer: content drives height so the
	# scrollbar engages rather than clipping when the list overflows.
	_main_vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_scroll.add_child(_main_vbox)

	# ── Header row ────────────────────────────────────────────────────────────
	_header_row = HBoxContainer.new()
	_header_row.name = "HeaderRow"
	_header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.add_child(_header_row)

	_device_label = Label.new()
	_device_label.name = "DeviceLabel"
	_device_label.text = "Drive: checking…"
	_device_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_device_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_header_row.add_child(_device_label)

	_add_btn = Button.new()
	_add_btn.name = "AddBtn"
	_add_btn.text = "+ Add"
	_add_btn.tooltip_text = "Choose a file to sync"
	_add_btn.pressed.connect(_on_add_pressed)
	_header_row.add_child(_add_btn)

	_remove_btn = Button.new()
	_remove_btn.name = "RemoveBtn"
	_remove_btn.text = "Remove"
	_remove_btn.tooltip_text = "Stop syncing the selected file"
	_remove_btn.disabled = true
	_remove_btn.pressed.connect(_on_remove_pressed)
	_header_row.add_child(_remove_btn)

	_reveal_btn = Button.new()
	_reveal_btn.name = "RevealBtn"
	_reveal_btn.text = "Reveal"
	_reveal_btn.tooltip_text = "Show the selected file in the system file manager"
	_reveal_btn.disabled = true
	_reveal_btn.pressed.connect(_on_reveal_pressed)
	_header_row.add_child(_reveal_btn)

	_open_ext_btn = Button.new()
	_open_ext_btn.name = "OpenExtBtn"
	_open_ext_btn.text = "Open externally"
	_open_ext_btn.tooltip_text = "Open the selected file in its OS default application"
	_open_ext_btn.disabled = true
	_open_ext_btn.pressed.connect(_on_open_ext_pressed)
	_header_row.add_child(_open_ext_btn)

	_sync_btn = Button.new()
	_sync_btn.name = "SyncBtn"
	_sync_btn.text = "Sync Now"
	_sync_btn.pressed.connect(_on_sync_pressed)
	_header_row.add_child(_sync_btn)

	_main_vbox.add_child(HSeparator.new())

	# ── Status line ───────────────────────────────────────────────────────────
	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = ""
	_status_label.visible = false
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.add_child(_status_label)

	# ── Project tree ──────────────────────────────────────────────────────────
	# Columns: Name | Status | Local ver | Cloud ver
	_project_tree = Tree.new()
	_project_tree.name = "ProjectTree"
	_project_tree.columns = 4
	_project_tree.column_titles_visible = true
	# Hide the synthetic root so the project rows are the top-level items. Use
	# the Tree property — making the root TreeItem invisible would also hide all
	# of its children (every row).
	_project_tree.hide_root = true
	_project_tree.set_column_title(0, "Project")
	_project_tree.set_column_title(1, "Status")
	_project_tree.set_column_title(2, "Local")
	_project_tree.set_column_title(3, "Cloud")
	_project_tree.set_column_expand(0, true)
	_project_tree.set_column_expand(1, false)
	_project_tree.set_column_expand(2, false)
	_project_tree.set_column_expand(3, false)
	_project_tree.set_column_custom_minimum_width(1, 110)
	_project_tree.set_column_custom_minimum_width(2, 60)
	_project_tree.set_column_custom_minimum_width(3, 60)
	_project_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Fixed height keeps the tree visible without pushing everything off-screen
	# in narrow pane heights; the outer ScrollContainer handles overflow.
	_project_tree.custom_minimum_size = Vector2(0, 300)
	_project_tree.item_selected.connect(_on_row_selected)
	_main_vbox.add_child(_project_tree)


# ── Refresh (status + project list) ──────────────────────────────────────────

func _refresh() -> void:
	await _fetch_status()
	await _fetch_list()


func _fetch_status() -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_set_device_label("Drive: IPC unavailable.")
		return
	var reply_id: String = "drive:status:%d" % Time.get_ticks_usec()
	request.emit("minerva_drive_status", {}, reply_id)
	var reply: Dictionary = await ipc.await_reply(reply_id, 10000)
	if not bool(reply.get("success", false)):
		var err: String = str(reply.get("error_message", str(reply.get("error_code", "unknown"))))
		_set_device_label("Drive: error — %s" % err)
		return
	var result: Dictionary = reply.get("result", {}) as Dictionary
	var connected: bool = bool(result.get("connected", false))
	var device: String = str(result.get("device", ""))
	var count: int = int(result.get("project_count", 0))
	if not connected:
		_set_device_label("Offline  ·  %d file(s)" % count)
	elif device.is_empty():
		_set_device_label("Drive: connected  ·  %d project(s)" % count)
	else:
		_set_device_label("%s  ·  %s  ·  %d project(s)" % [
			device,
			"connected" if connected else "offline",
			count,
		])


func _fetch_list() -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return
	var reply_id: String = "drive:list:%d" % Time.get_ticks_usec()
	request.emit("minerva_drive_list", {}, reply_id)
	var reply: Dictionary = await ipc.await_reply(reply_id, 15000)
	if not bool(reply.get("success", false)):
		var err: String = str(reply.get("error_message", str(reply.get("error_code", "unknown"))))
		_show_status("Could not load project list: %s" % err)
		return
	var result: Dictionary = reply.get("result", {}) as Dictionary
	var projects: Array = result.get("projects", []) as Array
	_populate_tree(projects)


func _populate_tree(projects: Array) -> void:
	if _project_tree == null:
		return
	_project_tree.clear()
	if _remove_btn != null:
		_remove_btn.disabled = true
	if _reveal_btn != null:
		_reveal_btn.disabled = true
	if _open_ext_btn != null:
		_open_ext_btn.disabled = true
	var root: TreeItem = _project_tree.create_item()
	if projects.is_empty():
		var empty_item: TreeItem = _project_tree.create_item(root)
		empty_item.set_text(0, "(no projects)")
		empty_item.set_selectable(0, false)
		return
	for entry in projects:
		var proj: Dictionary = entry as Dictionary
		var item: TreeItem = _project_tree.create_item(root)
		item.set_metadata(0, str(proj.get("path", "")))
		item.set_text(0, str(proj.get("name", "(unnamed)")))
		var status: String = str(proj.get("status", "unknown"))
		item.set_text(1, _format_status(status))
		item.set_text(2, str(int(proj.get("local_version", 0))))
		item.set_text(3, str(int(proj.get("cloud_version", 0))))
		# Highlight rows that need attention.
		if status in ["conflict", "cloud_ahead", "local_ahead"]:
			item.set_custom_color(1, _status_color(status))


# ── Sync ──────────────────────────────────────────────────────────────────────

func _on_sync_pressed() -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_show_status("IPC unavailable — cannot sync.")
		return
	_set_in_flight(true)
	_show_status("Syncing…")

	var reply_id: String = "drive:sync:%d" % Time.get_ticks_usec()
	request.emit("minerva_drive_sync", {}, reply_id)
	var reply: Dictionary = await ipc.await_reply(reply_id, 120000)
	_set_in_flight(false)

	if not bool(reply.get("success", false)):
		var err: String = str(reply.get("error_message", str(reply.get("error_code", "unknown"))))
		_show_status("Sync failed: %s" % err)
		return

	var result: Dictionary = reply.get("result", {}) as Dictionary
	var ok: bool = bool(result.get("ok", false))
	var pushed: Array = result.get("pushed", []) as Array
	var pulled: Array = result.get("pulled", []) as Array
	var conflicts: Array = result.get("conflicts", []) as Array
	var errors: Array = result.get("errors", []) as Array

	var msg_parts: Array = []
	if ok:
		msg_parts.append("Sync complete.")
	else:
		msg_parts.append("Sync finished with problems.")
	if pushed.size() > 0:
		msg_parts.append("Pushed: %d" % pushed.size())
	if pulled.size() > 0:
		msg_parts.append("Pulled: %d" % pulled.size())
	if conflicts.size() > 0:
		var names: Array = []
		for c in conflicts:
			var cd: Dictionary = c as Dictionary
			names.append(str(cd.get("name", "?")))
		msg_parts.append("%d conflict copy(s) created: %s" % [conflicts.size(), ", ".join(names)])
	if errors.size() > 0:
		msg_parts.append("Errors: %s" % "  |  ".join(errors))
	_show_status("  ·  ".join(msg_parts))

	# Refresh display after sync.
	await _fetch_status()
	await _fetch_list()


# ── Add / remove tracked files ────────────────────────────────────────────────

func _on_add_pressed() -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_show_status("IPC unavailable — cannot add.")
		return
	# Pick a file to sync.
	var pick_id: String = "drive:pick:%d" % Time.get_ticks_usec()
	request.emit("capability:host.dialogs.file_picker", {
		"title": "Choose a file to sync",
		"mode": "open",
		"filters": ["*"],
	}, pick_id)
	var pick: Dictionary = await ipc.await_reply(pick_id, 120000)
	if not bool(pick.get("success", false)):
		_show_status("File picker failed: %s" % str(pick.get("error_message", "unknown")))
		return
	var presult: Dictionary = pick.get("result", {}) as Dictionary
	if bool(presult.get("cancelled", false)):
		return
	var path: String = str(presult.get("path", ""))
	if path.is_empty():
		return
	# Register it.
	var add_id: String = "drive:add:%d" % Time.get_ticks_usec()
	request.emit("minerva_drive_add", {"path": path}, add_id)
	var reply: Dictionary = await ipc.await_reply(add_id, 15000)
	if not bool(reply.get("success", false)):
		_show_status("Add failed: %s" % str(reply.get("error_message", str(reply.get("error_code", "unknown")))))
		return
	_show_status("Added to sync: %s" % path)
	await _refresh()


func _on_remove_pressed() -> void:
	if _project_tree == null:
		return
	var item: TreeItem = _project_tree.get_selected()
	if item == null:
		return
	var path: String = str(item.get_metadata(0))
	if path.is_empty():
		return
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_show_status("IPC unavailable — cannot remove.")
		return
	var rid: String = "drive:remove:%d" % Time.get_ticks_usec()
	request.emit("minerva_drive_remove", {"path": path}, rid)
	var reply: Dictionary = await ipc.await_reply(rid, 15000)
	if not bool(reply.get("success", false)):
		_show_status("Remove failed: %s" % str(reply.get("error_message", str(reply.get("error_code", "unknown")))))
		return
	_show_status("Stopped syncing: %s" % path)
	await _refresh()


## Open the containing folder of the selected row's path in the OS file manager.
func _on_reveal_pressed() -> void:
	if _project_tree == null:
		return
	var item: TreeItem = _project_tree.get_selected()
	if item == null:
		return
	var path: String = str(item.get_metadata(0))
	if path.is_empty():
		return
	var folder: String = path.get_base_dir()
	if folder.is_empty():
		_show_status("Cannot determine containing folder for: %s" % path)
		return
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_show_status("IPC unavailable — cannot reveal.")
		return
	var rid: String = "drive:reveal:%d" % Time.get_ticks_usec()
	request.emit("capability:mcp.proxy:minerva_os_open", {"path": folder}, rid)
	var reply: Dictionary = await ipc.await_reply(rid, 15000)
	if not bool(reply.get("success", false)):
		_show_status("Reveal failed: %s" % str(reply.get("error_message", str(reply.get("error_code", "unknown")))))


## Open the selected row's file in its OS default application.
func _on_open_ext_pressed() -> void:
	if _project_tree == null:
		return
	var item: TreeItem = _project_tree.get_selected()
	if item == null:
		return
	var path: String = str(item.get_metadata(0))
	if path.is_empty():
		return
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_show_status("IPC unavailable — cannot open externally.")
		return
	var rid: String = "drive:open_ext:%d" % Time.get_ticks_usec()
	request.emit("capability:mcp.proxy:minerva_os_open", {"path": path}, rid)
	var reply: Dictionary = await ipc.await_reply(rid, 15000)
	if not bool(reply.get("success", false)):
		_show_status("Open externally failed: %s" % str(reply.get("error_message", str(reply.get("error_code", "unknown")))))


## Enable row actions only when the selected row maps to a local path (cloud-only
## rows have none).
func _on_row_selected() -> void:
	if _project_tree == null:
		return
	var item := _project_tree.get_selected()
	var has_path: bool = item != null and str(item.get_metadata(0)) != ""
	if _remove_btn != null:
		_remove_btn.disabled = not has_path
	if _reveal_btn != null:
		_reveal_btn.disabled = not has_path
	if _open_ext_btn != null:
		_open_ext_btn.disabled = not has_path


# ── Plugin event hook ─────────────────────────────────────────────────────────

func receive(channel: String, payload: Dictionary) -> void:
	super(channel, payload)


# ── Plugin platform lifecycle hooks ──────────────────────────────────────────

## The host attaches the IPC helper and fires this once the panel is fully
## registered, so the first data load belongs here — not _ready, where
## $_MinervaIPC is not attached yet.
func _on_panel_loaded(_ctx: Dictionary) -> void:
	_refresh()


func _on_panel_unload() -> void:
	pass


func _on_panel_save_request() -> Dictionary:
	return {"version": 1}


func _on_panel_load_request(_document: Dictionary) -> void:
	pass


# ── Helpers ───────────────────────────────────────────────────────────────────

func _set_in_flight(in_flight: bool) -> void:
	_in_flight = in_flight
	if _sync_btn != null:
		_sync_btn.disabled = in_flight


func _set_device_label(text: String) -> void:
	if _device_label != null:
		_device_label.text = text


func _show_status(msg: String) -> void:
	if _status_label == null:
		return
	if msg.is_empty():
		_status_label.text = ""
		_status_label.visible = false
	else:
		_status_label.text = msg
		_status_label.visible = true


func _format_status(status: String) -> String:
	match status:
		"synced":        return "Synced"
		"local_only":    return "Local only"
		"cloud_only":    return "Cloud only"
		"local_ahead":   return "Local ahead"
		"cloud_ahead":   return "Cloud ahead"
		"conflict":      return "Conflict"
		_:               return status


func _status_color(status: String) -> Color:
	match status:
		"conflict":    return Color(1.0, 0.35, 0.35)   # red
		"cloud_ahead": return Color(0.4, 0.75, 1.0)    # blue
		"local_ahead": return Color(1.0, 0.85, 0.3)    # amber
		_:             return Color(1, 1, 1)
