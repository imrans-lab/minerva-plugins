class_name Moviegen_Panel
extends MinervaPluginPanel
## Movie Generator panel — preview generated MP4 videos + Generate controls.
##
## Off-tree class_name gotcha:
##   This plugin lives outside Minerva's res:// tree, so the Godot parser cache
##   cannot resolve plugin-local class_names from typed field declarations.
##   All node references use base-class typing only.

# ── Mode constants ───────────────────────────────────────────────────────────
const MODE_TEXT: int = 0
const MODE_FLF2V: int = 1

# ── UI node references (set in _ready) ───────────────────────────────────────

## Main portrait VBox — single column, fills panel.
var _main_vbox: VBoxContainer = null

## Mode toggle (Text→Video = 0, First-Last-Frame = 1).
var _mode_toggle: OptionButton = null

## Text-mode controls.
var _text_section: VBoxContainer = null
var _prompt_edit: TextEdit = null
var _neg_prompt_edit: TextEdit = null

## FLF2V-mode controls.
var _flf_section: VBoxContainer = null
var _flf_prompt_edit: TextEdit = null
var _flf_neg_prompt_edit: TextEdit = null
var _first_frame_path_edit: LineEdit = null
var _last_frame_path_edit: LineEdit = null
var _first_frame_preview: TextureRect = null
var _last_frame_preview: TextureRect = null

## Shared parameters.
var _width_spin: SpinBox = null
var _height_spin: SpinBox = null
var _length_spin: SpinBox = null
var _fps_spin: SpinBox = null
var _steps_spin: SpinBox = null
var _switch_step_spin: SpinBox = null
var _cfg_spin: SpinBox = null
var _seed_spin: SpinBox = null

## Action buttons.
var _generate_btn: Button = null
var _regenerate_btn: Button = null
var _save_btn: Button = null

## Status label.
var _status_label: Label = null

## AspectRatioContainer wrapping the video player so it letterboxes correctly.
var _aspect_container: AspectRatioContainer = null

## VideoStreamPlayer for previewing generated MP4.
var _video_player: VideoStreamPlayer = null
## Loop the preview (generated clips are short) so motion stays visible.
var _loop_video: bool = true

## Play/Pause and Restart buttons for the video.
var _play_pause_btn: Button = null
var _restart_btn: Button = null

## Settings popup + its scroll/vbox.
var _settings_popup: PopupPanel = null
var _settings_vbox: VBoxContainer = null

# ── State ────────────────────────────────────────────────────────────────────

var _ctx: Dictionary = {}
var _in_flight: bool = false

## Last args used for Regenerate.
var _last_args: Dictionary = {}
var _last_mode: int = MODE_TEXT
var _last_artifact_path: String = ""


# ── Godot lifecycle ──────────────────────────────────────────────────────────

func _ready() -> void:
	# Build all UI in code (mirrors PCBEditor pattern — .tscn is a thin wrapper).
	set_anchors_preset(Control.PRESET_FULL_RECT)

	_build_settings_popup()
	_build_main_column()

	# Connect resize (no split offset logic needed for portrait layout).
	resized.connect(_on_panel_resized)


func _on_panel_resized() -> void:
	# Portrait VBox fills the panel automatically; nothing to adjust.
	pass


# ── Settings popup ────────────────────────────────────────────────────────────

func _build_settings_popup() -> void:
	_settings_popup = PopupPanel.new()
	_settings_popup.name = "SettingsPopup"
	add_child(_settings_popup)

	var scroll := ScrollContainer.new()
	scroll.name = "SettingsScroll"
	scroll.custom_minimum_size = Vector2(400, 480)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_settings_popup.add_child(scroll)

	_settings_vbox = VBoxContainer.new()
	_settings_vbox.name = "SettingsVBox"
	_settings_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_settings_vbox)

	# ── Mode toggle ────────────────────────────────────────────────────────
	var mode_label := Label.new()
	mode_label.text = "Mode"
	_settings_vbox.add_child(mode_label)

	_mode_toggle = OptionButton.new()
	_mode_toggle.name = "ModeToggle"
	_mode_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_toggle.add_item("Text → Video", MODE_TEXT)
	_mode_toggle.add_item("First-Last Frame → Video", MODE_FLF2V)
	_mode_toggle.select(MODE_TEXT)
	_mode_toggle.item_selected.connect(_on_mode_selected)
	_settings_vbox.add_child(_mode_toggle)

	_settings_vbox.add_child(HSeparator.new())

	# ── FLF2V-mode section (negative prompt + keyframe pickers) ───────────
	_flf_section = VBoxContainer.new()
	_flf_section.name = "FLFSection"
	_flf_section.visible = false
	_settings_vbox.add_child(_flf_section)

	var flf_neg_label := Label.new()
	flf_neg_label.text = "Negative Prompt (optional)"
	_flf_section.add_child(flf_neg_label)

	_flf_neg_prompt_edit = TextEdit.new()
	_flf_neg_prompt_edit.name = "FLFNegPromptEdit"
	_flf_neg_prompt_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flf_neg_prompt_edit.custom_minimum_size = Vector2(0, 50)
	_flf_neg_prompt_edit.placeholder_text = "Things to avoid…"
	_flf_neg_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_flf_section.add_child(_flf_neg_prompt_edit)

	_flf_section.add_child(HSeparator.new())

	# First frame picker.
	var first_frame_label := Label.new()
	first_frame_label.text = "First Frame"
	_flf_section.add_child(first_frame_label)

	_first_frame_preview = TextureRect.new()
	_first_frame_preview.name = "FirstFramePreview"
	_first_frame_preview.custom_minimum_size = Vector2(0, 60)
	_first_frame_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_first_frame_preview.expand_mode = TextureRect.EXPAND_FIT_WIDTH
	_flf_section.add_child(_first_frame_preview)

	var first_row := HBoxContainer.new()
	first_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flf_section.add_child(first_row)

	_first_frame_path_edit = LineEdit.new()
	_first_frame_path_edit.name = "FirstFramePathEdit"
	_first_frame_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_first_frame_path_edit.placeholder_text = "/path/to/first.png"
	_first_frame_path_edit.text_changed.connect(_on_first_frame_path_changed)
	first_row.add_child(_first_frame_path_edit)

	var first_browse_btn := Button.new()
	first_browse_btn.text = "Browse…"
	first_browse_btn.pressed.connect(_on_browse_first_frame_pressed)
	first_row.add_child(first_browse_btn)

	# Last frame picker.
	var last_frame_label := Label.new()
	last_frame_label.text = "Last Frame"
	_flf_section.add_child(last_frame_label)

	_last_frame_preview = TextureRect.new()
	_last_frame_preview.name = "LastFramePreview"
	_last_frame_preview.custom_minimum_size = Vector2(0, 60)
	_last_frame_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_last_frame_preview.expand_mode = TextureRect.EXPAND_FIT_WIDTH
	_flf_section.add_child(_last_frame_preview)

	var last_row := HBoxContainer.new()
	last_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flf_section.add_child(last_row)

	_last_frame_path_edit = LineEdit.new()
	_last_frame_path_edit.name = "LastFramePathEdit"
	_last_frame_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_last_frame_path_edit.placeholder_text = "/path/to/last.png"
	_last_frame_path_edit.text_changed.connect(_on_last_frame_path_changed)
	last_row.add_child(_last_frame_path_edit)

	var last_browse_btn := Button.new()
	last_browse_btn.text = "Browse…"
	last_browse_btn.pressed.connect(_on_browse_last_frame_pressed)
	last_row.add_child(last_browse_btn)

	_flf_section.add_child(HSeparator.new())

	# ── Text-mode negative prompt ──────────────────────────────────────────
	_text_section = VBoxContainer.new()
	_text_section.name = "TextSection"
	_settings_vbox.add_child(_text_section)

	var neg_label := Label.new()
	neg_label.text = "Negative Prompt (optional)"
	_text_section.add_child(neg_label)

	_neg_prompt_edit = TextEdit.new()
	_neg_prompt_edit.name = "NegPromptEdit"
	_neg_prompt_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_neg_prompt_edit.custom_minimum_size = Vector2(0, 50)
	_neg_prompt_edit.placeholder_text = "Things to avoid…"
	_neg_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_text_section.add_child(_neg_prompt_edit)

	_settings_vbox.add_child(HSeparator.new())

	# ── Shared parameters ──────────────────────────────────────────────────
	_settings_vbox.add_child(_make_label("Width"))
	_width_spin = _make_spinbox("WidthSpin", 256, 1280, 832, 1)
	_settings_vbox.add_child(_width_spin)

	_settings_vbox.add_child(_make_label("Height"))
	_height_spin = _make_spinbox("HeightSpin", 256, 720, 480, 1)
	_settings_vbox.add_child(_height_spin)

	_settings_vbox.add_child(_make_label("Length (frames)"))
	_length_spin = _make_spinbox("LengthSpin", 17, 121, 33, 1)
	_settings_vbox.add_child(_length_spin)

	_settings_vbox.add_child(_make_label("FPS"))
	_fps_spin = _make_spinbox("FPSSpin", 8, 30, 16, 1)
	_settings_vbox.add_child(_fps_spin)

	_settings_vbox.add_child(_make_label("Steps"))
	_steps_spin = _make_spinbox("StepsSpin", 4, 40, 16, 1)
	_settings_vbox.add_child(_steps_spin)

	_settings_vbox.add_child(_make_label("Switch Step"))
	_switch_step_spin = _make_spinbox("SwitchStepSpin", 1, 39, 8, 1)
	_settings_vbox.add_child(_switch_step_spin)

	_settings_vbox.add_child(_make_label("CFG Scale"))
	_cfg_spin = _make_spinbox("CFGSpin", 1.0, 12.0, 5.0, 0.5)
	_settings_vbox.add_child(_cfg_spin)

	_settings_vbox.add_child(_make_label("Seed (-1 = random)"))
	_seed_spin = _make_spinbox("SeedSpin", -1, 2147483647, -1, 1)
	_settings_vbox.add_child(_seed_spin)

	_settings_vbox.add_child(HSeparator.new())

	# ── Regenerate (settings popup) ────────────────────────────────────────
	_regenerate_btn = Button.new()
	_regenerate_btn.name = "RegenerateBtn"
	_regenerate_btn.text = "Regenerate"
	_regenerate_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_regenerate_btn.disabled = true
	_regenerate_btn.pressed.connect(_on_regenerate_pressed)
	_settings_vbox.add_child(_regenerate_btn)

	# ── Close button ───────────────────────────────────────────────────────
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.pressed.connect(_on_settings_close_pressed)
	_settings_vbox.add_child(close_btn)


# ── Main portrait column ──────────────────────────────────────────────────────

func _build_main_column() -> void:
	_main_vbox = VBoxContainer.new()
	_main_vbox.name = "MainVBox"
	_main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	_main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_main_vbox)

	# ── Prompt area (text mode) ────────────────────────────────────────────
	var prompt_label := Label.new()
	prompt_label.text = "Prompt"
	_main_vbox.add_child(prompt_label)

	_prompt_edit = TextEdit.new()
	_prompt_edit.name = "PromptEdit"
	_prompt_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prompt_edit.custom_minimum_size = Vector2(0, 80)
	_prompt_edit.placeholder_text = "Describe the video to generate…"
	_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_main_vbox.add_child(_prompt_edit)

	# ── FLF2V prompt area ──────────────────────────────────────────────────
	# _flf_section was already created in _build_settings_popup; the FLF prompt
	# is in the main column here (separate TextEdit, hidden by mode logic).
	var flf_prompt_label := Label.new()
	flf_prompt_label.name = "FLFPromptLabel"
	flf_prompt_label.text = "Prompt"
	flf_prompt_label.visible = false
	_main_vbox.add_child(flf_prompt_label)

	_flf_prompt_edit = TextEdit.new()
	_flf_prompt_edit.name = "FLFPromptEdit"
	_flf_prompt_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flf_prompt_edit.custom_minimum_size = Vector2(0, 80)
	_flf_prompt_edit.placeholder_text = "Describe the motion or transition…"
	_flf_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_flf_prompt_edit.visible = false
	_main_vbox.add_child(_flf_prompt_edit)

	# Store the FLF prompt label so _apply_mode can show/hide it.
	# We reference it by name from the parent later.

	# ── Button row: Generate | Save | ⚙ Settings ──────────────────────────
	var btn_row := HBoxContainer.new()
	btn_row.name = "ButtonRow"
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.add_child(btn_row)

	_generate_btn = Button.new()
	_generate_btn.name = "GenerateBtn"
	_generate_btn.text = "Generate"
	_generate_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_generate_btn.pressed.connect(_on_generate_pressed)
	btn_row.add_child(_generate_btn)

	_save_btn = Button.new()
	_save_btn.name = "SaveBtn"
	_save_btn.text = "Save…"
	_save_btn.disabled = true
	_save_btn.pressed.connect(_on_save_pressed)
	btn_row.add_child(_save_btn)

	var settings_btn := Button.new()
	settings_btn.name = "SettingsBtn"
	settings_btn.text = "⚙ Settings"
	settings_btn.pressed.connect(_on_settings_pressed)
	btn_row.add_child(settings_btn)

	# ── Status label ───────────────────────────────────────────────────────
	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = "Ready."
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.add_child(_status_label)

	# ── Video viewer (AspectRatioContainer → VideoStreamPlayer) ───────────
	_aspect_container = AspectRatioContainer.new()
	_aspect_container.name = "AspectContainer"
	_aspect_container.ratio = 16.0 / 9.0
	_aspect_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_aspect_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_vbox.add_child(_aspect_container)

	_video_player = VideoStreamPlayer.new()
	_video_player.name = "VideoPlayer"
	_video_player.expand = true  # scale the decoded frame into the control rect
	_video_player.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_video_player.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_aspect_container.add_child(_video_player)
	# Short previews (~2 s) would otherwise play once and freeze on the last frame —
	# loop so the motion stays continuously visible.
	_video_player.finished.connect(_on_video_finished)

	# ── Transport row (below viewer) ───────────────────────────────────────
	var transport_row := HBoxContainer.new()
	transport_row.name = "TransportRow"
	transport_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.add_child(transport_row)

	_play_pause_btn = Button.new()
	_play_pause_btn.name = "PlayPauseBtn"
	_play_pause_btn.text = "Play"
	_play_pause_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_play_pause_btn.disabled = true
	_play_pause_btn.pressed.connect(_on_play_pause_pressed)
	transport_row.add_child(_play_pause_btn)

	_restart_btn = Button.new()
	_restart_btn.name = "RestartBtn"
	_restart_btn.text = "Restart"
	_restart_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_restart_btn.disabled = true
	_restart_btn.pressed.connect(_on_restart_pressed)
	transport_row.add_child(_restart_btn)


# ── Settings popup open/close ────────────────────────────────────────────────

func _on_settings_pressed() -> void:
	if _settings_popup != null:
		_settings_popup.popup_centered(Vector2i(420, 520))


func _on_settings_close_pressed() -> void:
	if _settings_popup != null:
		_settings_popup.hide()


# ── Mode handling ────────────────────────────────────────────────────────────

func _on_mode_selected(index: int) -> void:
	var mode: int = _mode_toggle.get_item_id(index)
	_apply_mode(mode)


func _apply_mode(mode: int) -> void:
	# Main column: show the right prompt TextEdit.
	if _prompt_edit != null:
		_prompt_edit.visible = (mode == MODE_TEXT)
	if _flf_prompt_edit != null:
		_flf_prompt_edit.visible = (mode == MODE_FLF2V)
	# Also show/hide the FLF prompt label (sibling named "FLFPromptLabel").
	if _main_vbox != null:
		var lbl := _main_vbox.get_node_or_null("FLFPromptLabel")
		if lbl != null:
			lbl.visible = (mode == MODE_FLF2V)
	# Settings popup: show the right section.
	if _text_section != null:
		_text_section.visible = (mode == MODE_TEXT)
	if _flf_section != null:
		_flf_section.visible = (mode == MODE_FLF2V)


# ── Browse helpers ───────────────────────────────────────────────────────────

func _on_browse_first_frame_pressed() -> void:
	var path: String = await _pick_image_file("Select First Keyframe")
	if path != "" and _first_frame_path_edit != null:
		_first_frame_path_edit.text = path
		_load_frame_preview(_first_frame_preview, path)


func _on_browse_last_frame_pressed() -> void:
	var path: String = await _pick_image_file("Select Last Keyframe")
	if path != "" and _last_frame_path_edit != null:
		_last_frame_path_edit.text = path
		_load_frame_preview(_last_frame_preview, path)


func _pick_image_file(title: String) -> String:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_set_status("Error: IPC not available for file picker.")
		return ""
	var reply_id: String = "movgen:browse:%d" % Time.get_ticks_usec()
	request.emit("capability:host.dialogs.file_picker", {
		"title": title,
		"mode": "open",
		"filters": ["*.png", "*.jpg", "*.jpeg", "*.webp"],
	}, reply_id)
	var reply: Dictionary = await ipc.await_reply(reply_id, 60000)
	if not bool(reply.get("success", false)):
		_set_status("File picker failed: %s" % str(reply.get("error_message", "unknown")))
		return ""
	var result: Dictionary = reply.get("result", {}) as Dictionary
	if bool(result.get("cancelled", false)):
		return ""
	return str(result.get("path", ""))


func _on_first_frame_path_changed(text: String) -> void:
	_load_frame_preview(_first_frame_preview, text)


func _on_last_frame_path_changed(text: String) -> void:
	_load_frame_preview(_last_frame_preview, text)


func _load_frame_preview(preview: TextureRect, path: String) -> void:
	if preview == null:
		return
	if path == "" or not FileAccess.file_exists(path):
		preview.texture = null
		return
	var img := Image.new()
	var err: int = img.load(path)
	if err != OK:
		preview.texture = null
		return
	preview.texture = ImageTexture.create_from_image(img)


# ── Generate / Regenerate ────────────────────────────────────────────────────

func _on_generate_pressed() -> void:
	var mode: int = _mode_toggle.get_item_id(_mode_toggle.selected)
	var args: Dictionary = _build_args(mode)
	if args.is_empty():
		return  # _build_args already set status on validation failure.
	_last_mode = mode
	_last_args = args.duplicate(true)
	await _run_generate(mode, args)


func _on_regenerate_pressed() -> void:
	if _last_args.is_empty():
		return
	await _run_generate(_last_mode, _last_args)


func _build_args(mode: int) -> Dictionary:
	var shared: Dictionary = {
		"width": int(_width_spin.value),
		"height": int(_height_spin.value),
		"length": int(_length_spin.value),
		"fps": int(_fps_spin.value),
		"seed": int(_seed_spin.value),
		"steps": int(_steps_spin.value),
		"switch_step": int(_switch_step_spin.value),
		"cfg": _cfg_spin.value,
	}

	if mode == MODE_TEXT:
		var prompt: String = _prompt_edit.text.strip_edges()
		if prompt.is_empty():
			_set_status("Please enter a prompt.")
			return {}
		shared["positive_prompt"] = prompt
		var neg: String = _neg_prompt_edit.text.strip_edges()
		if not neg.is_empty():
			shared["negative_prompt"] = neg
		return shared
	else:  # MODE_FLF2V
		var first_path: String = _first_frame_path_edit.text.strip_edges()
		var last_path: String = _last_frame_path_edit.text.strip_edges()
		var prompt: String = _flf_prompt_edit.text.strip_edges()
		if first_path.is_empty():
			_set_status("Please select a first keyframe image.")
			return {}
		if last_path.is_empty():
			_set_status("Please select a last keyframe image.")
			return {}
		if prompt.is_empty():
			_set_status("Please enter a prompt.")
			return {}
		shared["first_frame_path"] = first_path
		shared["last_frame_path"] = last_path
		shared["positive_prompt"] = prompt
		var neg: String = _flf_neg_prompt_edit.text.strip_edges()
		if not neg.is_empty():
			shared["negative_prompt"] = neg
		return shared


func _run_generate(mode: int, args: Dictionary) -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_set_status("Error: IPC helper not attached.")
		return

	_set_in_flight(true)
	_set_status("Generating…")

	var channel: String = (
		"minerva_movie_gen_text_to_video" if mode == MODE_TEXT
		else "minerva_movie_gen_flf2v"
	)
	var reply_id: String = "movgen:%d" % Time.get_ticks_usec()
	request.emit(channel, args, reply_id)

	var reply: Dictionary = await ipc.await_reply(reply_id, 1800000)  # up to 30 min for heavy video
	_set_in_flight(false)

	if not bool(reply.get("success", false)):
		var err_msg: String = str(reply.get("error_message", str(reply.get("error_code", "unknown error"))))
		_set_status("Generation failed: %s" % err_msg)
		return

	var result: Dictionary = reply.get("result", {}) as Dictionary
	var mp4_path: String = str(result.get("path", ""))
	if mp4_path.is_empty():
		_set_status("Generation failed: reply had no path.")
		return

	_last_artifact_path = mp4_path
	_set_status("Loading video…")
	var ok: bool = _load_video(mp4_path)
	if ok:
		_set_status("Done. File: %s" % mp4_path.get_file())
		_save_btn.disabled = false
		_regenerate_btn.disabled = false
	else:
		_set_status("Generated but failed to load video: %s" % mp4_path)


# ── Video loading ─────────────────────────────────────────────────────────────

func _load_video(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_warning("[MovieGenPanel] _load_video: file not found: %s" % path)
		return false

	if _video_player == null:
		push_warning("[MovieGenPanel] _load_video: _video_player is null")
		return false

	# Stop any currently playing video first.
	if _video_player.is_playing():
		_video_player.stop()

	# Mirror video_player.gd's exact FFmpegVideoStream assignment pattern.
	var video_resource: VideoStream
	if ClassDB.class_exists("FFmpegVideoStream"):
		video_resource = ClassDB.instantiate("FFmpegVideoStream")
		video_resource.file = path
	else:
		# Fallback: Theora only supports .ogv — log a warning for mp4.
		push_warning("[MovieGenPanel] FFmpegVideoStream not available; falling back to Theora (mp4 will not play).")
		video_resource = VideoStreamTheora.new()
		video_resource.file = path

	_video_player.stream = video_resource
	_video_player.play()
	_keep_rendering(true)

	if _play_pause_btn != null:
		_play_pause_btn.text = "Pause"
		_play_pause_btn.disabled = false
	if _restart_btn != null:
		_restart_btn.disabled = false

	# Update AspectRatioContainer ratio from the chosen Width/Height spinboxes.
	if _aspect_container != null and _width_spin != null and _height_spin != null:
		var w: float = _width_spin.value
		var h: float = _height_spin.value
		if h > 0.0:
			_aspect_container.ratio = w / h
		else:
			_aspect_container.ratio = 16.0 / 9.0

	return true


# ── Video transport ───────────────────────────────────────────────────────────

func _on_play_pause_pressed() -> void:
	if _video_player == null:
		return
	if not _video_player.is_playing():
		_video_player.stream_position = 0
		_video_player.play()
		_keep_rendering(true)
		if _play_pause_btn != null:
			_play_pause_btn.text = "Pause"
	else:
		_video_player.paused = not _video_player.paused
		_keep_rendering(not _video_player.paused)
		if _play_pause_btn != null:
			_play_pause_btn.text = "Play" if _video_player.paused else "Pause"


func _on_restart_pressed() -> void:
	if _video_player == null:
		return
	_video_player.stop()
	_video_player.play()
	_keep_rendering(true)
	if _play_pause_btn != null:
		_play_pause_btn.text = "Pause"


## Loop the short preview clip rather than freezing on the final frame.
func _on_video_finished() -> void:
	if _loop_video and _video_player != null and _video_player.stream != null:
		_video_player.stream_position = 0.0
		_video_player.play()
		_keep_rendering(true)


## Minerva runs with low_processor_mode=true (project.godot) — it only refreshes the
## screen on input/changes, which makes continuous video stutter (frames advance only
## when the mouse moves). Disable low-processor mode while a clip plays; restore it
## when stopped/paused/unloaded so the idle app stays light.
func _keep_rendering(on: bool) -> void:
	OS.low_processor_usage_mode = not on


# ── Save (file picker for output path) ───────────────────────────────────────

func _on_save_pressed() -> void:
	if _last_artifact_path.is_empty():
		_set_status("Nothing to save yet.")
		return
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_set_status("Error: IPC not available for file picker.")
		return
	var reply_id: String = "movgen:save:%d" % Time.get_ticks_usec()
	request.emit("capability:host.dialogs.file_picker", {
		"title": "Save MP4 As…",
		"mode": "save",
		"filters": ["*.mp4"],
	}, reply_id)
	var reply: Dictionary = await ipc.await_reply(reply_id, 60000)
	if not bool(reply.get("success", false)):
		_set_status("Save picker failed: %s" % str(reply.get("error_message", "unknown")))
		return
	var result: Dictionary = reply.get("result", {}) as Dictionary
	if bool(result.get("cancelled", false)):
		return
	var dest: String = str(result.get("path", ""))
	if dest.is_empty():
		return
	var da := DirAccess.open("/")
	if da == null:
		_set_status("Cannot copy file: DirAccess unavailable.")
		return
	var copy_err: int = da.copy(_last_artifact_path, dest)
	if copy_err != OK:
		_set_status("Copy failed (err %d)." % copy_err)
	else:
		_set_status("Saved to: %s" % dest.get_file())


# ── IPC progress push ────────────────────────────────────────────────────────

## Called by the platform broker for push events from the backend.
## Handles movie_gen.progress event messages.
func receive(channel: String, payload: Dictionary) -> void:
	match channel:
		"movie_gen.progress":
			_last_progress_msg = str(payload.get("message", ""))
			# While in-flight the ticker folds this into the live status line.
			if not _in_flight:
				_set_status(_last_progress_msg)


# ── Plugin platform lifecycle hooks ──────────────────────────────────────────

func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx


func _on_panel_unload() -> void:
	# Stop video playback on unload.
	if _video_player != null and _video_player.is_playing():
		_video_player.stop()
	_keep_rendering(false)  # restore low-processor mode


func _on_panel_save_request() -> Dictionary:
	var mode: int = _mode_toggle.get_item_id(_mode_toggle.selected) if _mode_toggle != null else MODE_TEXT
	var positive_prompt: String = ""
	var flf_positive_prompt: String = ""
	if mode == MODE_TEXT:
		positive_prompt = _prompt_edit.text if _prompt_edit != null else ""
	else:
		flf_positive_prompt = _flf_prompt_edit.text if _flf_prompt_edit != null else ""
	return {
		"version": 1,
		"mode": mode,
		"positive_prompt": positive_prompt if mode == MODE_TEXT else flf_positive_prompt,
		"negative_prompt": (
			_neg_prompt_edit.text if (_neg_prompt_edit != null and mode == MODE_TEXT) else
			(_flf_neg_prompt_edit.text if _flf_neg_prompt_edit != null else "")
		),
		"first_frame_path": _first_frame_path_edit.text if _first_frame_path_edit != null else "",
		"last_frame_path": _last_frame_path_edit.text if _last_frame_path_edit != null else "",
		"width": int(_width_spin.value) if _width_spin != null else 1280,
		"height": int(_height_spin.value) if _height_spin != null else 720,
		"length": int(_length_spin.value) if _length_spin != null else 81,
		"fps": int(_fps_spin.value) if _fps_spin != null else 16,
		"seed": int(_seed_spin.value) if _seed_spin != null else -1,
		"steps": int(_steps_spin.value) if _steps_spin != null else 20,
		"switch_step": int(_switch_step_spin.value) if _switch_step_spin != null else 10,
		"cfg": _cfg_spin.value if _cfg_spin != null else 5.0,
		"last_artifact_path": _last_artifact_path,
	}


func _on_panel_load_request(document: Dictionary) -> void:
	var mode: int = int(document.get("mode", MODE_TEXT))
	if _mode_toggle != null:
		for i in _mode_toggle.item_count:
			if _mode_toggle.get_item_id(i) == mode:
				_mode_toggle.select(i)
				break
	_apply_mode(mode)

	# Restore text-mode prompt fields.
	if _prompt_edit != null:
		_prompt_edit.text = str(document.get("positive_prompt", "")) if mode == MODE_TEXT else ""
	if _neg_prompt_edit != null:
		_neg_prompt_edit.text = str(document.get("negative_prompt", "")) if mode == MODE_TEXT else ""

	# Restore FLF2V fields.
	if _flf_prompt_edit != null:
		_flf_prompt_edit.text = str(document.get("positive_prompt", "")) if mode == MODE_FLF2V else ""
	if _flf_neg_prompt_edit != null:
		_flf_neg_prompt_edit.text = str(document.get("negative_prompt", "")) if mode == MODE_FLF2V else ""
	if _first_frame_path_edit != null:
		var ffp: String = str(document.get("first_frame_path", ""))
		_first_frame_path_edit.text = ffp
		_load_frame_preview(_first_frame_preview, ffp)
	if _last_frame_path_edit != null:
		var lfp: String = str(document.get("last_frame_path", ""))
		_last_frame_path_edit.text = lfp
		_load_frame_preview(_last_frame_preview, lfp)

	# Restore shared spinboxes — accept float (GDScript JSON round-trips ints as float).
	if _width_spin != null:
		_width_spin.value = float(document.get("width", _width_spin.value))
	if _height_spin != null:
		_height_spin.value = float(document.get("height", _height_spin.value))
	if _length_spin != null:
		_length_spin.value = float(document.get("length", _length_spin.value))
	if _fps_spin != null:
		_fps_spin.value = float(document.get("fps", _fps_spin.value))
	if _seed_spin != null:
		_seed_spin.value = float(document.get("seed", _seed_spin.value))
	if _steps_spin != null:
		_steps_spin.value = float(document.get("steps", _steps_spin.value))
	if _switch_step_spin != null:
		_switch_step_spin.value = float(document.get("switch_step", _switch_step_spin.value))
	if _cfg_spin != null:
		_cfg_spin.value = float(document.get("cfg", _cfg_spin.value))

	# Reload last artifact if it still exists on disk.
	var artifact_path: String = str(document.get("last_artifact_path", ""))
	if artifact_path != "" and FileAccess.file_exists(artifact_path):
		_last_artifact_path = artifact_path
		_set_status("Reloading last video…")
		var ok: bool = _load_video(artifact_path)
		if ok:
			_set_status("Restored: %s" % artifact_path.get_file())
			if _save_btn != null:
				_save_btn.disabled = false
			if _regenerate_btn != null:
				_regenerate_btn.disabled = false
		else:
			_set_status("Could not reload: %s" % artifact_path)


# ── Helpers ──────────────────────────────────────────────────────────────────

func _make_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	return lbl


func _make_spinbox(node_name: String, min_v: float, max_v: float, default_v: float, step_v: float) -> SpinBox:
	var sb := SpinBox.new()
	sb.name = node_name
	sb.min_value = min_v
	sb.max_value = max_v
	sb.value = default_v
	sb.step = step_v
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return sb


var _gen_start_ms: int = 0
var _gen_timer: Timer = null
var _last_progress_msg: String = ""


func _set_in_flight(in_flight: bool) -> void:
	_in_flight = in_flight
	if _generate_btn != null:
		_generate_btn.disabled = in_flight
	if _regenerate_btn != null and not _last_args.is_empty():
		_regenerate_btn.disabled = in_flight
	# Drive a live "⏳ Generating… (m:ss)" ticker so the run is visibly alive even
	# when the backend sends no intermediate progress (video can run minutes).
	if in_flight:
		_last_progress_msg = ""
		_gen_start_ms = Time.get_ticks_msec()
		_ensure_gen_timer()
		_gen_timer.start()
		_on_gen_tick()
	elif _gen_timer != null:
		_gen_timer.stop()


func _ensure_gen_timer() -> void:
	if _gen_timer == null:
		_gen_timer = Timer.new()
		_gen_timer.wait_time = 1.0
		_gen_timer.one_shot = false
		_gen_timer.timeout.connect(_on_gen_tick)
		add_child(_gen_timer)


func _on_gen_tick() -> void:
	var secs := int((Time.get_ticks_msec() - _gen_start_ms) / 1000.0)
	var extra := "" if _last_progress_msg.is_empty() else " — " + _last_progress_msg
	_set_status("⏳ Generating… (%d:%02d)%s" % [secs / 60, secs % 60, extra])


func _set_status(msg: String) -> void:
	if _status_label != null:
		_status_label.text = msg
