class_name Drive_Panel
extends MinervaPluginPanel
## Drive panel — shows plugin status and provides a manual status check button.
##
## Off-tree class_name gotcha:
##   This plugin lives outside Minerva's res:// tree, so the Godot parser cache
##   cannot resolve plugin-local class_names from typed field declarations.
##   All node references use base-class typing only.

# ── UI node references (set in _ready) ───────────────────────────────────────

## Main vertical layout — single column, fills the panel.
var _main_vbox: VBoxContainer = null

## Label showing the last status response from the backend.
var _status_label: Label = null

## Button that calls minerva_drive_status and refreshes the display.
var _check_btn: Button = null

# ── State ─────────────────────────────────────────────────────────────────────

var _in_flight: bool = false


# ── Godot lifecycle ──────────────────────────────────────────────────────────

func _ready() -> void:
	# Build all UI in code (mirrors PCBEditor pattern — .tscn is a thin wrapper).
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()


# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "MainScroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_main_vbox = VBoxContainer.new()
	_main_vbox.name = "MainVBox"
	_main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	scroll.add_child(_main_vbox)

	var title := Label.new()
	title.text = "Drive"
	_main_vbox.add_child(title)

	_main_vbox.add_child(HSeparator.new())

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = "Status: not checked."
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.add_child(_status_label)

	_check_btn = Button.new()
	_check_btn.name = "CheckBtn"
	_check_btn.text = "Check Status"
	_check_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_check_btn.pressed.connect(_on_check_pressed)
	_main_vbox.add_child(_check_btn)


# ── Status check ──────────────────────────────────────────────────────────────

func _on_check_pressed() -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_set_status("Error: IPC not available.")
		return

	_set_in_flight(true)
	_set_status("Checking…")

	var reply_id: String = "drive:status:%d" % Time.get_ticks_usec()
	request.emit("minerva_drive_status", {}, reply_id)

	var reply: Dictionary = await ipc.await_reply(reply_id, 10000)
	_set_in_flight(false)

	if not bool(reply.get("success", false)):
		var err: String = str(reply.get("error_message", str(reply.get("error_code", "unknown"))))
		_set_status("Error: %s" % err)
		return

	var result: Dictionary = reply.get("result", {}) as Dictionary
	var status: String = str(result.get("status", "unknown"))
	var ready: bool = bool(result.get("ready", false))
	_set_status("status=%s  ready=%s" % [status, str(ready)])


# ── Plugin platform lifecycle hooks ──────────────────────────────────────────

func _on_panel_loaded(_ctx: Dictionary) -> void:
	pass


func _on_panel_unload() -> void:
	pass


func _on_panel_save_request() -> Dictionary:
	return {"version": 1}


func _on_panel_load_request(_document: Dictionary) -> void:
	pass


# ── Helpers ───────────────────────────────────────────────────────────────────

func _set_in_flight(in_flight: bool) -> void:
	_in_flight = in_flight
	if _check_btn != null:
		_check_btn.disabled = in_flight


func _set_status(msg: String) -> void:
	if _status_label != null:
		_status_label.text = "Status: %s" % msg
