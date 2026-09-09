extends RefCounted
## Compilation policy is independent of document synchronization.
## Both GUI and MCP use this controller; the panel owns evaluation and painting.

const ROWS := [
	"ResponsiveContainer/WideLayout/WideSidebar/BuildControls",
	"ResponsiveContainer/NarrowLayout/BuildControls",
]
var mode := "automatic"
var dispatched_source := ""
var painted_source := ""
var has_painted := false
var _owner: WeakRef
var _icons: Dictionary = {}

func _init(panel: Node) -> void:
	_owner = weakref(panel)

func wire() -> void:
	var panel: Node = _owner.get_ref()
	for path in ROWS:
		var row := panel.get_node_or_null(path)
		if row == null:
			continue
		var choice: Button = row.get_node("Mode")
		_set_icon(choice, "automatic_build.svg", "Auto")
		if not choice.toggled.is_connected(_on_mode):
			choice.toggled.connect(_on_mode)
		var button: Button = row.get_node("Build")
		_set_icon(button, "build_latest.svg", "Build")
		if not button.pressed.is_connected(build_latest):
			button.pressed.connect(build_latest)
	refresh()

func _on_mode(automatic: bool) -> void:
	set_mode("automatic" if automatic else "manual")

## Plugin assets are outside the host's import database, as in PCB's toolbar.
func _set_icon(button: Button, filename: String, fallback: String) -> void:
	if not _icons.has(filename):
		var path: String = get_script().resource_path.get_base_dir().path_join("../icons/" + filename)
		var image := Image.load_from_file(ProjectSettings.globalize_path(path))
		_icons[filename] = ImageTexture.create_from_image(image) if image != null else null
	button.icon = _icons[filename]
	button.text = fallback if button.icon == null else ""

func set_mode(value: String) -> Dictionary:
	if value not in ["automatic", "manual"]:
		return {"success": false, "error": "mode must be automatic or manual"}
	var panel: Node = _owner.get_ref()
	var changed := mode != value
	mode = value
	if mode == "manual" and panel._eval_debounce_timer != null:
		panel._eval_debounce_timer.stop()
	if changed and mode == "automatic" and state().build_required:
		panel._start_eval_debounce()
	refresh()
	return state()

func build_latest() -> Dictionary:
	var panel: Node = _owner.get_ref()
	panel.verify_dependencies()
	var source: String = panel._current_source()
	if panel._eval_debounce_timer != null:
		panel._eval_debounce_timer.stop()
	# A second click joins the identical in-flight snapshot.
	if panel._inflight_request_id.is_empty() or source != dispatched_source:
		panel._evaluate_with_request_id(source)
	refresh()
	return state()

func state() -> Dictionary:
	var panel: Node = _owner.get_ref()
	var required: bool = not has_painted or panel._current_source() != painted_source or panel._dependencies.is_stale()
	if panel._painted_buffer_version >= 0:
		required = required or panel._buffer_version > panel._painted_buffer_version
	var status := "building" if panel._evaluation_is_unsettled() else "current"
	if status != "building":
		if str(panel._last_eval_result.get("status", "")) in ["error", "timeout", "cancelled"]:
			status = "error"
		elif required:
			status = "needs_build"
	return {"success": true, "mode": mode, "status": status,
		"build_required": required, "request_id": panel._inflight_request_id}

func refresh() -> void:
	var panel: Node = _owner.get_ref()
	var current := state()
	for path in ROWS:
		var row := panel.get_node_or_null(path)
		if row == null:
			continue
		var choice: Button = row.get_node("Mode")
		choice.set_pressed_no_signal(mode == "automatic")
		choice.tooltip_text = ("Automatic builds: on. Click for Manual mode.\nEdits compile after a short pause."
			if mode == "automatic" else "Automatic builds: off (Manual mode).\nClick to enable. Text edits still synchronize.")
		var status: String = {
			"current": "Current", "needs_build": "Build required",
			"building": "Building…", "error": "Build failed",
		}[current.status]
		var button: Button = row.get_node("Build")
		button.tooltip_text = "Build latest — %s\nCompile the current source now." % status
		button.modulate = Color(1.0, 0.75, 0.35) if current.build_required else Color.WHITE
