class_name Drive_Panel
extends MinervaPluginPanel
## Drive panel — shows sync status, lists projects, and allows manual sync.
##
## Off-tree class_name gotcha:
##   This plugin lives outside Minerva's res:// tree, so the Godot parser cache
##   cannot resolve plugin-local class_names from typed field declarations.
##   All node references use base-class typing only.

# ── UI node references (set in _build_ui) ────────────────────────────────────

## Single-column root layout that fills the pane.
var _main_vbox: VBoxContainer = null

## Header row: device/connection label + action buttons.
var _header_row: HFlowContainer = null
var _device_label: Label = null
var _sync_btn: Button = null
var _add_btn: Button = null
var _remove_btn: Button = null
var _reveal_btn: Button = null
var _open_ext_btn: Button = null
var _download_btn: Button = null
var _open_btn: Button = null
var _folder_btn: Button = null

# ── Extra state ───────────────────────────────────────────────────────────────

## Cached effective folder path returned by the last minerva_drive_status call.
## Shown in the device label and used for display purposes only.
var _current_folder: String = ""

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
	# A single column that fills the pane: the toolbar wraps its buttons and the
	# tree takes the remaining height, so the panel stays usable at any width.
	_main_vbox = VBoxContainer.new()
	_main_vbox.name = "MainVBox"
	_main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	_main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_main_vbox)

	# Device / connection status on its own full-width line.
	_device_label = Label.new()
	_device_label.name = "DeviceLabel"
	_device_label.text = "Drive: checking…"
	_device_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_device_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_main_vbox.add_child(_device_label)

	# Toolbar that WRAPS its buttons to new lines when the pane is narrow, so the
	# actions never overflow horizontally.
	_header_row = HFlowContainer.new()
	_header_row.name = "Toolbar"
	_header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.add_child(_header_row)

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

	_download_btn = Button.new()
	_download_btn.name = "DownloadBtn"
	_download_btn.text = "Download…"
	_download_btn.tooltip_text = "Save the current cloud version of the selected project to a file"
	_download_btn.disabled = true
	_download_btn.pressed.connect(_on_download_pressed)
	_header_row.add_child(_download_btn)

	_open_btn = Button.new()
	_open_btn.name = "OpenBtn"
	_open_btn.text = "Open"
	_open_btn.tooltip_text = "Pull the latest version and open the selected project in Minerva"
	_open_btn.disabled = true
	_open_btn.pressed.connect(_on_open_pressed)
	_header_row.add_child(_open_btn)

	_folder_btn = Button.new()
	_folder_btn.name = "FolderBtn"
	_folder_btn.text = "Drive folder…"
	_folder_btn.tooltip_text = "Choose the local folder where Drive stores and pulls files"
	_folder_btn.pressed.connect(_on_folder_pressed)
	_header_row.add_child(_folder_btn)

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
	# Fill the remaining height; the tree scrolls its own rows internally.
	_project_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_project_tree.custom_minimum_size = Vector2(0, 120)
	_project_tree.item_selected.connect(_on_row_selected)
	_project_tree.item_activated.connect(_on_row_activated)
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
	# Cache folder for display; falls back gracefully if the backend is older
	# and doesn't include the field yet.
	_current_folder = str(result.get("folder", ""))
	var folder_short: String = _current_folder.get_file() if not _current_folder.is_empty() else ""
	if not connected:
		if folder_short.is_empty():
			_set_device_label("Offline  ·  %d file(s)" % count)
		else:
			_set_device_label("Offline  ·  %d file(s)  ·  %s" % [count, folder_short])
	elif device.is_empty():
		if folder_short.is_empty():
			_set_device_label("Drive: connected  ·  %d project(s)" % count)
		else:
			_set_device_label("Drive: connected  ·  %d project(s)  ·  %s" % [count, folder_short])
	else:
		if folder_short.is_empty():
			_set_device_label("%s  ·  %s  ·  %d project(s)" % [
				device,
				"connected" if connected else "offline",
				count,
			])
		else:
			_set_device_label("%s  ·  %s  ·  %d project(s)  ·  %s" % [
				device,
				"connected" if connected else "offline",
				count,
				folder_short,
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
	if _download_btn != null:
		_download_btn.disabled = true
	if _open_btn != null:
		_open_btn.disabled = true
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
		item.set_metadata(1, str(proj.get("proj_uuid", "")))
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
	var deferred: Array = result.get("deferred", []) as Array

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
	if deferred.size() > 0:
		msg_parts.append("%d open project(s) not synced — close to reconcile: %s" % [
			deferred.size(), ", ".join(deferred)
		])
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


## Let the user choose a new Drive folder via the host file-picker in dir mode.
## Falls back gracefully if the host picker doesn't support "dir" mode —
## in that case we show an informational message rather than crashing.
## Choosing a folder does NOT move any existing tracked or materialised files.
func _on_folder_pressed() -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_show_status("IPC unavailable — cannot change folder.")
		return
	# Ask the host for a directory picker.
	var pick_id: String = "drive:folder_pick:%d" % Time.get_ticks_usec()
	request.emit("capability:host.dialogs.file_picker", {
		"title": "Choose Drive folder",
		"mode": "dir",
	}, pick_id)
	var pick: Dictionary = await ipc.await_reply(pick_id, 120000)
	if not bool(pick.get("success", false)):
		# The host may not support "dir" mode — surface a clear message rather
		# than silently doing nothing.
		var err: String = str(pick.get("error_message", str(pick.get("error_code", "unknown"))))
		_show_status(
			"Folder picker unavailable (%s). " % err
			+ "Use the minerva_drive_set_folder MCP tool to set the path directly."
		)
		return
	var presult: Dictionary = pick.get("result", {}) as Dictionary
	if bool(presult.get("cancelled", false)):
		return
	var chosen: String = str(presult.get("path", ""))
	if chosen.is_empty():
		return
	# Apply the new folder.
	var set_id: String = "drive:set_folder:%d" % Time.get_ticks_usec()
	request.emit("minerva_drive_set_folder", {"path": chosen}, set_id)
	var reply: Dictionary = await ipc.await_reply(set_id, 15000)
	if not bool(reply.get("success", false)):
		_show_status("Set folder failed: %s" % str(reply.get("error_message", str(reply.get("error_code", "unknown")))))
		return
	var result: Dictionary = reply.get("result", {}) as Dictionary
	if not bool(result.get("ok", false)):
		_show_status("Set folder error: %s" % str(result.get("error", "unknown")))
		return
	var new_folder: String = str(result.get("folder", chosen))
	_show_status(
		"Drive folder set to: %s  (existing tracked files are NOT moved)" % new_folder
	)
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


## Enable row actions based on what the selected row provides.
## Reveal/Open/Remove require a local path; Download only requires a proj_uuid
## so it works for Cloud-only rows that have no local file yet.
func _on_row_selected() -> void:
	if _project_tree == null:
		return
	var item := _project_tree.get_selected()
	var has_path: bool = item != null and str(item.get_metadata(0)) != ""
	var has_uuid: bool = item != null and str(item.get_metadata(1)) != ""
	if _remove_btn != null:
		_remove_btn.disabled = not has_path
	if _reveal_btn != null:
		_reveal_btn.disabled = not has_path
	if _open_ext_btn != null:
		_open_ext_btn.disabled = not has_path
	if _download_btn != null:
		_download_btn.disabled = not has_uuid
	if _open_btn != null:
		_open_btn.disabled = not has_uuid


## Save the current cloud version of the selected project to a user-chosen path.
func _on_download_pressed() -> void:
	if _project_tree == null:
		return
	var item: TreeItem = _project_tree.get_selected()
	if item == null:
		return
	var proj_uuid: String = str(item.get_metadata(1))
	if proj_uuid.is_empty():
		return
	var proj_name: String = item.get_text(0)
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_show_status("IPC unavailable — cannot download.")
		return
	# Ask the user where to save the file.
	var pick_id: String = "drive:download_pick:%d" % Time.get_ticks_usec()
	request.emit("capability:host.dialogs.file_picker", {
		"title": "Download a copy as…",
		"mode": "save",
		"filters": ["*"],
		"filename": proj_name,
	}, pick_id)
	var pick: Dictionary = await ipc.await_reply(pick_id, 120000)
	if not bool(pick.get("success", false)):
		_show_status("File picker failed: %s" % str(pick.get("error_message", "unknown")))
		return
	var presult: Dictionary = pick.get("result", {}) as Dictionary
	if bool(presult.get("cancelled", false)):
		return
	var dest: String = str(presult.get("path", ""))
	if dest.is_empty():
		return
	# Download and write.
	_show_status("Downloading…")
	var exp_id: String = "drive:export:%d" % Time.get_ticks_usec()
	request.emit("minerva_drive_export", {"proj_uuid": proj_uuid, "dest_path": dest}, exp_id)
	var reply: Dictionary = await ipc.await_reply(exp_id, 120000)
	if not bool(reply.get("success", false)):
		_show_status("Download failed: %s" % str(reply.get("error_message", str(reply.get("error_code", "unknown")))))
		return
	var result: Dictionary = reply.get("result", {}) as Dictionary
	if not bool(result.get("ok", false)):
		_show_status("Download error: %s" % str(result.get("error", "unknown")))
		return
	var written: int = int(result.get("bytes_written", 0))
	_show_status("Downloaded %s (%d bytes) to: %s" % [str(result.get("name", proj_name)), written, dest])


## Open button pressed — delegates to the shared helper.
func _on_open_pressed() -> void:
	if _project_tree == null:
		return
	var item: TreeItem = _project_tree.get_selected()
	if item == null:
		return
	var proj_uuid: String = str(item.get_metadata(1))
	await _open_project(proj_uuid)


## Double-click or Enter on a tree row — open that project.
func _on_row_activated() -> void:
	if _project_tree == null:
		return
	var item: TreeItem = _project_tree.get_selected()
	if item == null:
		return
	var proj_uuid: String = str(item.get_metadata(1))
	await _open_project(proj_uuid)


## Pull the latest cloud version and open it in Minerva. Refuses when the
## current project has unsaved changes (backend enforces the same guard).
func _open_project(proj_uuid: String) -> void:
	if proj_uuid.is_empty():
		return
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_show_status("IPC unavailable — cannot open project.")
		return
	_show_status("Opening…")
	var rid: String = "drive:open:%d" % Time.get_ticks_usec()
	request.emit("minerva_drive_open", {"proj_uuid": proj_uuid}, rid)
	var reply: Dictionary = await ipc.await_reply(rid, 120000)
	if not bool(reply.get("success", false)):
		_show_status("Open failed: %s" % str(reply.get("error_message", str(reply.get("error_code", "unknown")))))
		return
	var result: Dictionary = reply.get("result", {}) as Dictionary
	if not bool(result.get("ok", false)):
		if bool(result.get("needs_save", false)):
			_show_status(str(result.get("message", "Save your current project first, then open.")))
		else:
			_show_status("Open error: %s" % str(result.get("error", "unknown")))
		return
	_show_status("Opened %s" % str(result.get("name", proj_uuid)))
	await _refresh()


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
