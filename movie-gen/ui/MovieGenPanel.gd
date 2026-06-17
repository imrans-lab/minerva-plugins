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
const MODE_I2V: int = 2

# ── Host icons (chat's icons — panels run in-process so res:// = Minerva) ──────
const ICON_SEND := "res://assets/icons/send_icons/send_icon_24_no_bg.png"
const ICON_DOWNLOAD := "res://assets/icons/download_icons/download_white.png"
const ICON_GEAR := "res://assets/icons/gear_icons/gears_icon_24_no_bg.png"

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
## Keyframe-selection block — lives in the MAIN column (primary input for the
## image→image workflow), shown only in FLF2V mode.
var _flf_keyframes_section: VBoxContainer = null
var _flf_prompt_edit: TextEdit = null
var _flf_neg_prompt_edit: TextEdit = null
var _first_frame_path_edit: LineEdit = null
var _last_frame_path_edit: LineEdit = null
var _first_frame_preview: TextureRect = null
var _last_frame_preview: TextureRect = null

## Image-note pickers — source the two keyframes from open IMAGE notes instead
## of raw paths. Each resolves the chosen note to an on-disk PNG (via the host
## minerva_get_note proxy) and funnels it through the path LineEdit below, so the
## file-path + Browse fallback still works unchanged.
var _first_frame_note_picker: OptionButton = null
var _last_frame_note_picker: OptionButton = null
## Cached [{note_id, title}] of IMAGE-kind notes, indexed by OptionButton item id.
var _image_notes: Array = []
var _first_frame_note_id: String = ""
var _last_frame_note_id: String = ""

## Column container nodes (so i2v mode can hide the Last-frame column) + the
## First-frame title label (retitled "Start Frame" in i2v mode).
var _first_frame_column: VBoxContainer = null
var _last_frame_column: VBoxContainer = null
var _first_frame_label: Label = null

## Shared parameters.
var _width_spin: SpinBox = null
var _height_spin: SpinBox = null
var _length_spin: SpinBox = null
var _fps_spin: SpinBox = null
var _steps_spin: SpinBox = null
var _switch_step_spin: SpinBox = null
var _cfg_spin: SpinBox = null
var _seed_spin: SpinBox = null
var _crf_spin: SpinBox = null

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

	# (The mode chooser lives in the main column — see _build_main_column.)

	# ── FLF2V-mode settings (negative prompt; keyframes are in the main column) ──
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

	# (Keyframe selection lives in the MAIN column — see _build_flf_keyframes() —
	# because choosing the two images IS the primary input for image→image.)

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

	_settings_vbox.add_child(_make_label("Video Quality (CRF: lower = better, 18 ≈ lossless)"))
	_crf_spin = _make_spinbox("CRFSpin", 0, 28, 18, 1)
	_settings_vbox.add_child(_crf_spin)

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


# ── Keyframe selection (FLF2V primary input) ──────────────────────────────────

## Build the First/Last keyframe pickers into `_flf_keyframes_section` (added to
## the main column by the caller). Each keyframe offers an image-note dropdown
## (the primary way to choose) plus a path field + Browse as a fallback, and a
## compact preview. Hidden unless the mode is FLF2V.
func _build_flf_keyframes() -> void:
	_flf_keyframes_section = VBoxContainer.new()
	_flf_keyframes_section.name = "FLFKeyframesSection"
	_flf_keyframes_section.visible = false
	_flf_keyframes_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Header + refresh.
	var notes_header_row := HBoxContainer.new()
	notes_header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flf_keyframes_section.add_child(notes_header_row)

	var notes_header := Label.new()
	notes_header.text = "Keyframes (from image notes)"
	notes_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	notes_header_row.add_child(notes_header)

	var refresh_notes_btn := Button.new()
	refresh_notes_btn.name = "RefreshNotesBtn"
	refresh_notes_btn.text = "↻"
	refresh_notes_btn.tooltip_text = "Re-scan open notes for images"
	refresh_notes_btn.pressed.connect(_on_refresh_notes_pressed)
	notes_header_row.add_child(refresh_notes_btn)

	# Both keyframes side-by-side: First on the left half, Last on the right half.
	var frames_row := HBoxContainer.new()
	frames_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frames_row.add_theme_constant_override("separation", 8)
	_flf_keyframes_section.add_child(frames_row)

	var first := _build_keyframe_column("First Frame")
	_first_frame_column = first[0]
	_first_frame_label = _first_frame_column.get_child(0) as Label  # the title label
	frames_row.add_child(_first_frame_column)
	_first_frame_note_picker = first[1]
	_first_frame_preview = first[2]
	_first_frame_path_edit = first[3]
	_first_frame_note_picker.item_selected.connect(_on_first_note_picked)
	_first_frame_path_edit.text_changed.connect(_on_first_frame_path_changed)
	(first[4] as Button).pressed.connect(_on_browse_first_frame_pressed)

	var last := _build_keyframe_column("Last Frame")
	_last_frame_column = last[0]
	frames_row.add_child(_last_frame_column)
	_last_frame_note_picker = last[1]
	_last_frame_preview = last[2]
	_last_frame_path_edit = last[3]
	_last_frame_note_picker.item_selected.connect(_on_last_note_picked)
	_last_frame_path_edit.text_changed.connect(_on_last_frame_path_changed)
	(last[4] as Button).pressed.connect(_on_browse_last_frame_pressed)


## Build one compact keyframe column (one of the two side-by-side halves):
## a title, a preview on top, then the image-note dropdown over a compact
## path + Browse fallback. Returns [column, picker, preview, path_edit, browse_btn].
func _build_keyframe_column(label_text: String) -> Array:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL  # the two columns split 50/50
	col.add_theme_constant_override("separation", 2)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(lbl)

	# Preview on top — fills the column width, fixed height, scaled to fit.
	# EXPAND_IGNORE_SIZE stops the texture's native resolution from dictating the
	# control's minimum size (which used to overflow and shove controls off-screen).
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(0, 110)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.clip_contents = true
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(preview)

	# Note-image dropdown (primary way to choose).
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.clip_text = true
	col.add_child(picker)

	# Compact path + Browse fallback.
	var path_row := HBoxContainer.new()
	path_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(path_row)

	var path_edit := LineEdit.new()
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.placeholder_text = "…or a path"
	path_row.add_child(path_edit)

	var browse_btn := Button.new()
	browse_btn.text = "📂"
	browse_btn.tooltip_text = "Browse for an image file"
	path_row.add_child(browse_btn)

	return [col, picker, preview, path_edit, browse_btn]


# ── Main portrait column ──────────────────────────────────────────────────────

func _build_main_column() -> void:
	# Wrap the whole column in a vertical ScrollContainer so the controls stay
	# reachable even if content exceeds the (variable) pane height — nothing can
	# be pushed into an unreachable area.
	var scroll := ScrollContainer.new()
	scroll.name = "MainScroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_main_vbox = VBoxContainer.new()
	_main_vbox.name = "MainVBox"
	_main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# NOT vertical-expand: inside a ScrollContainer an expanding child is stretched
	# to the viewport and its overflow is CLIPPED (no scrollbar engages), which cut
	# off the video + transport row at the bottom. Sizing to content lets the
	# ScrollContainer scroll instead.
	_main_vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	scroll.add_child(_main_vbox)

	# ── Mode chooser (primary control — top of the main column) ─────────────
	var mode_row := HBoxContainer.new()
	mode_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.add_child(mode_row)

	var mode_label := Label.new()
	mode_label.text = "Mode"
	mode_row.add_child(mode_label)

	_mode_toggle = OptionButton.new()
	_mode_toggle.name = "ModeToggle"
	_mode_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_toggle.add_item("Text → Video", MODE_TEXT)
	_mode_toggle.add_item("Image → Video", MODE_I2V)
	_mode_toggle.add_item("First-Last Frame → Video", MODE_FLF2V)
	_mode_toggle.select(MODE_TEXT)
	_mode_toggle.item_selected.connect(_on_mode_selected)
	mode_row.add_child(_mode_toggle)

	# ── Keyframe selection (FLF2V) — primary input, lives in the main column ──
	_build_flf_keyframes()
	_main_vbox.add_child(_flf_keyframes_section)

	# ── Prompt area — placed at the bottom, just above the action row, so the
	# inputs (mode, keyframes) read top-down into the prompt then the Send row. ─
	var prompt_label := Label.new()
	prompt_label.name = "TextPromptLabel"
	prompt_label.text = "Prompt"
	_main_vbox.add_child(prompt_label)

	_prompt_edit = TextEdit.new()
	_prompt_edit.name = "PromptEdit"
	_prompt_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prompt_edit.custom_minimum_size = Vector2(0, 80)
	_prompt_edit.placeholder_text = "Describe the video to generate…"
	_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_main_vbox.add_child(_prompt_edit)

	# FLF2V prompt (separate TextEdit; mode logic shows exactly one prompt).
	var flf_prompt_label := Label.new()
	flf_prompt_label.name = "FLFPromptLabel"
	flf_prompt_label.text = "Prompt (optional)"
	flf_prompt_label.visible = false
	_main_vbox.add_child(flf_prompt_label)

	_flf_prompt_edit = TextEdit.new()
	_flf_prompt_edit.name = "FLFPromptEdit"
	_flf_prompt_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flf_prompt_edit.custom_minimum_size = Vector2(0, 80)
	_flf_prompt_edit.placeholder_text = "Describe the motion or transition (optional)…"
	_flf_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_flf_prompt_edit.visible = false
	_main_vbox.add_child(_flf_prompt_edit)

	# ── Button row: a compact, right-aligned flat icon toolbar ─────────────
	# Order left→right: Settings · Download · Send (send is the rightmost action).
	var btn_row := HBoxContainer.new()
	btn_row.name = "ButtonRow"
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	_main_vbox.add_child(btn_row)

	var settings_btn := Button.new()
	settings_btn.name = "SettingsBtn"
	settings_btn.flat = true
	_set_icon_button(settings_btn, ICON_GEAR, "⚙ Settings", "Settings")
	settings_btn.pressed.connect(_on_settings_pressed)
	btn_row.add_child(settings_btn)

	_save_btn = Button.new()
	_save_btn.name = "SaveBtn"
	_save_btn.flat = true
	_set_icon_button(_save_btn, ICON_DOWNLOAD, "Save…", "Download / export the video")
	_save_btn.disabled = true
	_save_btn.pressed.connect(_on_save_pressed)
	btn_row.add_child(_save_btn)

	_generate_btn = Button.new()
	_generate_btn.name = "GenerateBtn"
	_generate_btn.flat = true
	_set_icon_button(_generate_btn, ICON_SEND, "Generate", "Generate")
	_generate_btn.pressed.connect(_on_generate_pressed)
	btn_row.add_child(_generate_btn)

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
	# Deterministic fixed height (NOT vertical-expand): inside the ScrollContainer
	# an expanding child gets ambiguous sizing and the frame clipped at the bottom.
	# A fixed height keeps the whole viewer + the transport row below it on-screen.
	_aspect_container.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_aspect_container.custom_minimum_size = Vector2(0, 260)
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
	# Keep the keyframe pickers current whenever the user opens Settings in FLF mode.
	if _mode_toggle != null and _mode_toggle.get_item_id(_mode_toggle.selected) == MODE_FLF2V:
		_refresh_image_notes()


func _on_settings_close_pressed() -> void:
	if _settings_popup != null:
		_settings_popup.hide()


# ── Mode handling ────────────────────────────────────────────────────────────

func _on_mode_selected(index: int) -> void:
	var mode: int = _mode_toggle.get_item_id(index)
	_apply_mode(mode)


func _apply_mode(mode: int) -> void:
	# FLF2V and I2V are both keyframe-driven video modes: they share the keyframe
	# section + the (optional) motion prompt. I2V differs only in using a single
	# Start frame (the Last-frame column is hidden).
	var is_kf := (mode == MODE_FLF2V or mode == MODE_I2V)

	# Main column: show the right prompt TextEdit + its label.
	if _prompt_edit != null:
		_prompt_edit.visible = (mode == MODE_TEXT)
	if _flf_prompt_edit != null:
		_flf_prompt_edit.visible = is_kf
	# Show exactly one "Prompt" label (text mode vs the keyframe modes).
	if _main_vbox != null:
		var text_lbl := _main_vbox.get_node_or_null("TextPromptLabel")
		if text_lbl != null:
			text_lbl.visible = (mode == MODE_TEXT)
		var flf_lbl := _main_vbox.get_node_or_null("FLFPromptLabel")
		if flf_lbl != null:
			flf_lbl.visible = is_kf
	# Keyframe selection (main column) — for both video keyframe modes.
	if _flf_keyframes_section != null:
		_flf_keyframes_section.visible = is_kf
	# I2V uses only the Start frame: hide the Last-frame column and retitle.
	if _last_frame_column != null:
		_last_frame_column.visible = (mode == MODE_FLF2V)
	if _first_frame_label != null:
		_first_frame_label.text = "Start Frame" if mode == MODE_I2V else "First Frame"
	# Settings popup: show the right section.
	if _text_section != null:
		_text_section.visible = (mode == MODE_TEXT)
	if _flf_section != null:
		_flf_section.visible = is_kf

	# Entering a keyframe mode: refresh the image-note dropdowns (fire-and-forget;
	# no-op if IPC isn't attached yet, e.g. during load).
	if is_kf:
		_refresh_image_notes()


# ── Browse helpers ───────────────────────────────────────────────────────────

func _on_browse_first_frame_pressed() -> void:
	var path: String = await _pick_image_file("Select First Keyframe")
	if path != "" and _first_frame_path_edit != null:
		_first_frame_path_edit.text = path
		_load_frame_preview(_first_frame_preview, path)
		_sync_output_dims_from_keyframes()


func _on_browse_last_frame_pressed() -> void:
	var path: String = await _pick_image_file("Select Last Keyframe")
	if path != "" and _last_frame_path_edit != null:
		_last_frame_path_edit.text = path
		_load_frame_preview(_last_frame_preview, path)
		_sync_output_dims_from_keyframes()


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
	if FileAccess.file_exists(text):
		_sync_output_dims_from_keyframes()


func _on_last_frame_path_changed(text: String) -> void:
	_load_frame_preview(_last_frame_preview, text)
	if FileAccess.file_exists(text):
		_sync_output_dims_from_keyframes()


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


## Match the output Width/Height to the chosen keyframe's aspect ratio. Without
## this the generator keeps its landscape default (832×480) and a portrait/square
## keyframe comes back squished or cropped. Uses the first frame when set, else
## the last; snaps to the model's valid ranges and a multiple of 16.
func _sync_output_dims_from_keyframes() -> void:
	if _width_spin == null or _height_spin == null:
		return
	var path := ""
	if _first_frame_path_edit != null and FileAccess.file_exists(_first_frame_path_edit.text):
		path = _first_frame_path_edit.text
	elif _last_frame_path_edit != null and FileAccess.file_exists(_last_frame_path_edit.text):
		path = _last_frame_path_edit.text
	if path.is_empty():
		return
	var img := Image.new()
	if img.load(path) != OK or img.is_empty():
		return
	var dims := _fit_output_dims(img.get_width(), img.get_height())
	_width_spin.value = dims.x
	_height_spin.value = dims.y
	_set_status("Output set to %d×%d to match the keyframe." % [dims.x, dims.y])


## Fit a source WxH into the model's valid ranges (width 256–1280, height 256–720)
## preserving aspect, snapped to a multiple of 16. Extreme aspect ratios clamp to
## the range bounds (minor distortion) rather than failing.
func _fit_output_dims(src_w: int, src_h: int) -> Vector2i:
	const MIN_SIDE := 256.0
	const MAX_W := 1280.0
	const MAX_H := 720.0
	const STEP := 16.0
	if src_w <= 0 or src_h <= 0:
		return Vector2i(int(_width_spin.value), int(_height_spin.value))
	var w := float(src_w)
	var h := float(src_h)
	# Scale down to fit the max box (never upscale past native).
	var down := minf(minf(MAX_W / w, MAX_H / h), 1.0)
	w *= down
	h *= down
	# Scale up if we fell below the minimum on either side.
	var up := maxf(maxf(MIN_SIDE / w, MIN_SIDE / h), 1.0)
	w *= up
	h *= up
	# Snap to STEP and clamp to the valid ranges.
	var fw := clampf(roundf(w / STEP) * STEP, MIN_SIDE, MAX_W)
	var fh := clampf(roundf(h / STEP) * STEP, MIN_SIDE, MAX_H)
	return Vector2i(int(fw), int(fh))


# ── Image-note pickers ────────────────────────────────────────────────────────

func _on_refresh_notes_pressed() -> void:
	await _refresh_image_notes()


## Pull the open notes from the host, keep only IMAGE-kind ones, and rebuild both
## keyframe dropdowns. Reached via the mcp.proxy:minerva_list_notes capability.
func _refresh_image_notes() -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return
	var reply_id: String = "movgen:listnotes:%d" % Time.get_ticks_usec()
	request.emit("capability:mcp.proxy:minerva_list_notes", {}, reply_id)
	var reply: Dictionary = await ipc.await_reply(reply_id, 15000)
	if not bool(reply.get("success", false)):
		return
	var tool_res: Dictionary = reply.get("result", {}) as Dictionary
	var notes: Array = tool_res.get("notes", []) as Array
	_image_notes.clear()
	for n in notes:
		if str((n as Dictionary).get("type", "")).to_upper() == "IMAGE":
			_image_notes.append({
				"note_id": str((n as Dictionary).get("note_id", "")),
				"title": str((n as Dictionary).get("title", "")),
			})
	_rebuild_note_pickers()


## Repopulate a single picker, preserving the current selection by note_id when
## that note is still present after the refresh.
func _populate_note_picker(picker: OptionButton, selected_note_id: String) -> void:
	if picker == null:
		return
	picker.clear()
	if _image_notes.is_empty():
		picker.add_item("(no image notes open)", -1)
		picker.set_item_disabled(0, true)
		return
	picker.add_item("— Select image note —", -1)
	var select_idx: int = 0
	for i in _image_notes.size():
		var entry: Dictionary = _image_notes[i]
		var title: String = entry.get("title", "")
		picker.add_item(title if not title.is_empty() else "(untitled)", i)
		if entry.get("note_id", "") == selected_note_id and not selected_note_id.is_empty():
			select_idx = picker.item_count - 1
	picker.select(select_idx)


func _rebuild_note_pickers() -> void:
	_populate_note_picker(_first_frame_note_picker, _first_frame_note_id)
	_populate_note_picker(_last_frame_note_picker, _last_frame_note_id)


func _on_first_note_picked(index: int) -> void:
	await _apply_note_pick(_first_frame_note_picker, index, true)


func _on_last_note_picked(index: int) -> void:
	await _apply_note_pick(_last_frame_note_picker, index, false)


## Resolve the chosen note's image to disk and feed it into the keyframe's path
## field + preview. `is_first` selects which slot to fill.
func _apply_note_pick(picker: OptionButton, index: int, is_first: bool) -> void:
	if picker == null:
		return
	var item_id: int = picker.get_item_id(index)
	if item_id < 0 or item_id >= _image_notes.size():
		return  # placeholder / sentinel row
	var entry: Dictionary = _image_notes[item_id]
	var note_id: String = entry.get("note_id", "")
	var title: String = entry.get("title", "")
	if note_id.is_empty():
		return
	var path: String = await _resolve_note_image(note_id)
	if path.is_empty():
		_set_status("Could not load image from note '%s'." % title)
		return
	if is_first:
		_first_frame_note_id = note_id
		if _first_frame_path_edit != null:
			_first_frame_path_edit.text = path
		_load_frame_preview(_first_frame_preview, path)
	else:
		_last_frame_note_id = note_id
		if _last_frame_path_edit != null:
			_last_frame_path_edit.text = path
		_load_frame_preview(_last_frame_preview, path)
	_sync_output_dims_from_keyframes()


## Ask the host to export the note's image to a PNG on disk and return its path.
## Reached via the mcp.proxy:minerva_get_note capability (substrate exports IMAGE
## notes to user://plugin_note_images/<uuid>.png and reports image_path).
func _resolve_note_image(note_id: String) -> String:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return ""
	var reply_id: String = "movgen:getnote:%d" % Time.get_ticks_usec()
	request.emit("capability:mcp.proxy:minerva_get_note", {"note_id": note_id}, reply_id)
	var reply: Dictionary = await ipc.await_reply(reply_id, 15000)
	if not bool(reply.get("success", false)):
		return ""
	var tool_res: Dictionary = reply.get("result", {}) as Dictionary
	return str(tool_res.get("image_path", ""))


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
		"crf": int(_crf_spin.value),
		# Panel previews the result inline, so opt out of the host OS-viewer
		# surfacing (that default is for agent-driven MCP calls).
		"background": true,
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
	elif mode == MODE_I2V:
		# Single start keyframe; prompt OPTIONAL (the keyframe drives it).
		var start_path: String = _first_frame_path_edit.text.strip_edges()
		if start_path.is_empty():
			_set_status("Please select a start keyframe image.")
			return {}
		shared["start_frame_path"] = start_path
		var i2v_prompt: String = _flf_prompt_edit.text.strip_edges()
		if not i2v_prompt.is_empty():
			shared["positive_prompt"] = i2v_prompt
		var i2v_neg: String = _flf_neg_prompt_edit.text.strip_edges()
		if not i2v_neg.is_empty():
			shared["negative_prompt"] = i2v_neg
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
		# Prompt is OPTIONAL for image→image — the two keyframes drive it. Only
		# send positive_prompt when the user actually typed one.
		shared["first_frame_path"] = first_path
		shared["last_frame_path"] = last_path
		if not prompt.is_empty():
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

	var channel: String = "minerva_movie_gen_flf2v"
	if mode == MODE_TEXT:
		channel = "minerva_movie_gen_text_to_video"
	elif mode == MODE_I2V:
		channel = "minerva_movie_gen_i2v"
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
		"crf": int(_crf_spin.value) if _crf_spin != null else 18,
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
	if _crf_spin != null:
		_crf_spin.value = float(document.get("crf", _crf_spin.value))

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


## Use a host icon (chat's send/download/gear) on a button; fall back to text if the
## asset isn't present in this Minerva build.
func _set_icon_button(btn: Button, icon_path: String, fallback_text: String, tip: String) -> void:
	var tex: Texture2D = load(icon_path)
	if tex != null:
		btn.icon = tex
		btn.text = ""
	else:
		btn.text = fallback_text
	btn.tooltip_text = tip
