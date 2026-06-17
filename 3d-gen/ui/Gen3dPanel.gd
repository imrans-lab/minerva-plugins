class_name Gen3d_Panel
extends MinervaPluginPanel
## 3D Generator panel — preview generated GLB meshes + Generate controls.
##
## Off-tree class_name gotcha:
##   This plugin lives outside Minerva's res:// tree, so the Godot parser cache
##   cannot resolve plugin-local class_names from typed field declarations.
##   Fields whose types are plugin-local scripts (OrbitCamera) are typed with
##   the platform BASE class (Camera3D) and assigned via preload(...).new() or
##   get_node_or_null(). All plugin-local script interaction uses duck typing.

# ── Script preloads ──────────────────────────────────────────────────────────
## OrbitCamera script — preloaded by path relative to this script's directory.
## Typed as Script (not OrbitCamera) because OrbitCamera class_name is not
## resolvable from off-tree. The camera node is typed Camera3D (base class).
const _OrbitCameraScript: Script = preload("scripts/orbit_camera.gd")

# ── Mode constants ───────────────────────────────────────────────────────────
const MODE_TEXT: int = 0
const MODE_IMAGE: int = 1

# ── UI node references (set in _ready) ───────────────────────────────────────

## Main portrait VBox — single column, fills panel.
var _main_vbox: VBoxContainer = null

## Mode toggle (Text→3D = 0, Image→3D = 1).
var _mode_toggle: OptionButton = null

## Text-mode controls.
var _text_section: VBoxContainer = null
var _prompt_edit: TextEdit = null
var _neg_prompt_edit: TextEdit = null

## Image-mode controls.
var _image_section: VBoxContainer = null
var _image_path_edit: LineEdit = null

## Shared controls (both modes).
var _steps_spin: SpinBox = null
var _guidance_spin: SpinBox = null

## Seed spinbox.
var _seed_spin: SpinBox = null

## Action buttons.
var _generate_btn: Button = null
var _regenerate_btn: Button = null
var _save_btn: Button = null

## Status label.
var _status_label: Label = null

## SubViewportContainer + SubViewport + world root + camera.
var _viewport_container: SubViewportContainer = null
var _sub_viewport: SubViewport = null
var _world_root: Node3D = null
## Camera typed as Camera3D (base) — OrbitCamera class_name is plugin-local.
var _camera: Camera3D = null

## Currently loaded mesh node (GLB scene root added under _world_root).
var _current_mesh_node: Node3D = null

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
	_mode_toggle.add_item("Text → 3D", MODE_TEXT)
	_mode_toggle.add_item("Image → 3D", MODE_IMAGE)
	_mode_toggle.select(MODE_TEXT)
	_mode_toggle.item_selected.connect(_on_mode_selected)
	_settings_vbox.add_child(_mode_toggle)

	_settings_vbox.add_child(HSeparator.new())

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

	# ── Image-mode section ─────────────────────────────────────────────────
	_image_section = VBoxContainer.new()
	_image_section.name = "ImageSection"
	_image_section.visible = false
	_settings_vbox.add_child(_image_section)

	var img_label := Label.new()
	img_label.text = "Image Path"
	_image_section.add_child(img_label)

	var img_row := HBoxContainer.new()
	img_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_image_section.add_child(img_row)

	_image_path_edit = LineEdit.new()
	_image_path_edit.name = "ImagePathEdit"
	_image_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_image_path_edit.placeholder_text = "/path/to/image.png"
	img_row.add_child(_image_path_edit)

	var browse_btn := Button.new()
	browse_btn.text = "Browse…"
	browse_btn.pressed.connect(_on_browse_pressed)
	img_row.add_child(browse_btn)

	_settings_vbox.add_child(HSeparator.new())

	# ── Shared parameters ──────────────────────────────────────────────────
	var steps_label := Label.new()
	steps_label.name = "StepsLabel"
	steps_label.text = "Steps"
	_settings_vbox.add_child(steps_label)

	_steps_spin = SpinBox.new()
	_steps_spin.name = "StepsSpin"
	_steps_spin.min_value = 1
	_steps_spin.max_value = 50
	_steps_spin.value = 25
	_steps_spin.step = 1
	_steps_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_vbox.add_child(_steps_spin)

	var guidance_label := Label.new()
	guidance_label.text = "Guidance"
	_settings_vbox.add_child(guidance_label)

	_guidance_spin = SpinBox.new()
	_guidance_spin.name = "GuidanceSpin"
	_guidance_spin.min_value = 1.0
	_guidance_spin.max_value = 15.0
	_guidance_spin.value = 5.5
	_guidance_spin.step = 0.5
	_guidance_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_vbox.add_child(_guidance_spin)

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
	prompt_label.name = "PromptLabel"
	prompt_label.text = "Prompt"
	_main_vbox.add_child(prompt_label)

	_prompt_edit = TextEdit.new()
	_prompt_edit.name = "PromptEdit"
	_prompt_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prompt_edit.custom_minimum_size = Vector2(0, 80)
	_prompt_edit.placeholder_text = "Describe the 3D object…"
	_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_main_vbox.add_child(_prompt_edit)

	# Image-mode has no main-column prompt; the image path lives in settings.
	# We show a brief label so the user knows to open settings.
	var img_hint_label := Label.new()
	img_hint_label.name = "ImageHintLabel"
	img_hint_label.text = "Reference image path set in ⚙ Settings."
	img_hint_label.visible = false
	_main_vbox.add_child(img_hint_label)

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

	# ── 3D viewport viewer ─────────────────────────────────────────────────
	_build_viewport_column()


# ── Viewport (called from _build_main_column) ─────────────────────────────────

func _build_viewport_column() -> void:
	_viewport_container = SubViewportContainer.new()
	_viewport_container.name = "ViewportContainer"
	_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_container.stretch = true
	_main_vbox.add_child(_viewport_container)

	_sub_viewport = SubViewport.new()
	_sub_viewport.name = "SubViewport"
	_sub_viewport.transparent_bg = false
	_viewport_container.add_child(_sub_viewport)

	# World root node.
	_world_root = Node3D.new()
	_world_root.name = "WorldRoot"
	_sub_viewport.add_child(_world_root)

	# WorldEnvironment with ambient light so generated meshes are visible.
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.15, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.7
	world_env.environment = env
	_world_root.add_child(world_env)

	# Directional light so the mesh has shading.
	var dir_light := DirectionalLight3D.new()
	dir_light.name = "DirectionalLight"
	dir_light.light_energy = 1.2
	dir_light.rotation_degrees = Vector3(-45, 45, 0)
	_world_root.add_child(dir_light)

	# OrbitCamera — instantiated from the preloaded script. Untyped: Script.new()
	# returns Object, so `:=` cannot infer a type (off-tree class_name is stripped).
	var cam_scene: Camera3D = _OrbitCameraScript.new()  # script extends Camera3D
	cam_scene.name = "OrbitCamera"
	_world_root.add_child(cam_scene)
	_camera = cam_scene as Camera3D


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
	# Main column: show the right prompt widget.
	if _prompt_edit != null:
		_prompt_edit.visible = (mode == MODE_TEXT)
	if _main_vbox != null:
		var pl := _main_vbox.get_node_or_null("PromptLabel")
		if pl != null:
			pl.visible = (mode == MODE_TEXT)
		var hint := _main_vbox.get_node_or_null("ImageHintLabel")
		if hint != null:
			hint.visible = (mode == MODE_IMAGE)
	# Settings popup sections.
	if _text_section != null:
		_text_section.visible = (mode == MODE_TEXT)
	if _image_section != null:
		_image_section.visible = (mode == MODE_IMAGE)
	# Adjust steps range by mode.
	if _steps_spin != null:
		if mode == MODE_TEXT:
			_steps_spin.min_value = 1
			_steps_spin.max_value = 50
			if _steps_spin.value > 50:
				_steps_spin.value = 25
		else:  # IMAGE
			_steps_spin.min_value = 10
			_steps_spin.max_value = 100
			if _steps_spin.value < 10:
				_steps_spin.value = 30


# ── Browse (file picker) ─────────────────────────────────────────────────────

func _on_browse_pressed() -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_set_status("Error: IPC not available for file picker.")
		return
	var reply_id: String = "gen:browse:%d" % Time.get_ticks_usec()
	request.emit("capability:host.dialogs.file_picker", {
		"title": "Select Reference Image",
		"mode": "open",
		"filters": ["*.png", "*.jpg", "*.jpeg", "*.webp"],
	}, reply_id)
	var reply: Dictionary = await ipc.await_reply(reply_id, 60000)
	if not bool(reply.get("success", false)):
		_set_status("File picker failed: %s" % str(reply.get("error_message", "unknown")))
		return
	var result: Dictionary = reply.get("result", {}) as Dictionary
	if bool(result.get("cancelled", false)):
		return  # User cancelled — no status update needed.
	var path: String = str(result.get("path", ""))
	if path != "" and _image_path_edit != null:
		_image_path_edit.text = path


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
	var steps: int = int(_steps_spin.value)
	var guidance: float = _guidance_spin.value

	if mode == MODE_TEXT:
		var prompt: String = _prompt_edit.text.strip_edges()
		if prompt.is_empty():
			_set_status("Please enter a prompt.")
			return {}
		var args: Dictionary = {
			"positive_prompt": prompt,
			"seed": -1,
			"steps": steps,
			"guidance": guidance,
		}
		var neg: String = _neg_prompt_edit.text.strip_edges()
		if not neg.is_empty():
			args["negative_prompt"] = neg
		return args
	else:  # MODE_IMAGE
		var img_path: String = _image_path_edit.text.strip_edges()
		if img_path.is_empty():
			_set_status("Please select a reference image.")
			return {}
		return {
			"image_path": img_path,
			"seed": -1,
			"steps": steps,
			"guidance": guidance,
		}


func _run_generate(mode: int, args: Dictionary) -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_set_status("Error: IPC helper not attached.")
		return

	_set_in_flight(true)
	_set_status("Generating…")

	var channel: String = (
		"minerva_gen3d_text_to_3d" if mode == MODE_TEXT
		else "minerva_gen3d_image_to_3d"
	)
	var reply_id: String = "gen:%d" % Time.get_ticks_usec()
	request.emit(channel, args, reply_id)

	var reply: Dictionary = await ipc.await_reply(reply_id, 600000)
	_set_in_flight(false)

	if not bool(reply.get("success", false)):
		var err_msg: String = str(reply.get("error_message", str(reply.get("error_code", "unknown error"))))
		_set_status("Generation failed: %s" % err_msg)
		return

	var result: Dictionary = reply.get("result", {}) as Dictionary
	var glb_path: String = str(result.get("path", ""))
	if glb_path.is_empty():
		_set_status("Generation failed: reply had no path.")
		return

	_last_artifact_path = glb_path
	_set_status("Loading mesh…")
	var ok: bool = _load_glb(glb_path)
	if ok:
		_set_status("Done. File: %s" % glb_path.get_file())
		_save_btn.disabled = false
		_regenerate_btn.disabled = false
	else:
		_set_status("Generated but failed to load GLB: %s" % glb_path)


# ── GLB loading ──────────────────────────────────────────────────────────────

func _load_glb(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_warning("[Gen3dPanel] _load_glb: file not found: %s" % path)
		return false

	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var err: int = doc.append_from_file(path, st)
	if err != OK:
		push_warning("[Gen3dPanel] _load_glb: append_from_file error %d for %s" % [err, path])
		return false

	var scene: Node = doc.generate_scene(st)
	if scene == null:
		push_warning("[Gen3dPanel] _load_glb: generate_scene returned null for %s" % path)
		return false

	# Free previous mesh node.
	if _current_mesh_node != null and is_instance_valid(_current_mesh_node):
		_current_mesh_node.queue_free()
		_current_mesh_node = null

	scene.name = "GeneratedMesh"
	_world_root.add_child(scene)
	_current_mesh_node = scene as Node3D

	# Shape-only meshes (text_to_3d) ship no material and render flat white —
	# clay-coat them so the form reads under the lighting.
	_apply_clay_material(scene)

	# Frame the camera on the loaded mesh AABB.
	_frame_camera_on_mesh(scene)
	return true


## Give untextured meshes a matte clay material so geometry is legible. Meshes
## that already carry a real material (a future textured GLB) are left untouched.
func _apply_clay_material(root: Node) -> void:
	var clay := StandardMaterial3D.new()
	clay.albedo_color = Color(0.74, 0.74, 0.78)
	clay.roughness = 0.85
	clay.metallic = 0.0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var has_mat := mi.material_override != null
			if not has_mat and mi.mesh != null:
				for s in mi.mesh.get_surface_count():
					if mi.mesh.surface_get_material(s) != null \
							or mi.get_surface_override_material(s) != null:
						has_mat = true
						break
			if not has_mat:
				mi.material_override = clay
		for i in n.get_child_count():
			stack.push_back(n.get_child(i))


func _frame_camera_on_mesh(mesh_node: Node) -> void:
	if _camera == null or mesh_node == null:
		return
	# Accumulate AABB from all MeshInstance3D descendants.
	var aabb := AABB()
	var found := false
	var stack: Array = [mesh_node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var local_aabb: AABB = mi.get_aabb()
			var global_aabb: AABB = mi.global_transform * local_aabb
			if not found:
				aabb = global_aabb
				found = true
			else:
				aabb = aabb.merge(global_aabb)
		for i in n.get_child_count():
			stack.push_back(n.get_child(i))

	if not found:
		return

	var center: Vector3 = aabb.get_center()
	var size: float = aabb.get_longest_axis_size()
	var dist: float = max(size * 2.2, 0.4)

	# Duck-type the OrbitCamera's set_target / set_distance (typed Camera3D at
	# the field level, but actual runtime type is OrbitCamera which has these).
	if _camera.has_method("set_target"):
		_camera.call("set_target", center)
	if _camera.has_method("set_distance"):
		_camera.call("set_distance", dist)


# ── Save (file picker for output path) ───────────────────────────────────────

func _on_save_pressed() -> void:
	if _last_artifact_path.is_empty():
		_set_status("Nothing to save yet.")
		return
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_set_status("Error: IPC not available for file picker.")
		return
	var reply_id: String = "gen:save:%d" % Time.get_ticks_usec()
	request.emit("capability:host.dialogs.file_picker", {
		"title": "Save GLB As…",
		"mode": "save",
		"filters": ["*.glb"],
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

## Called by the platform broker for any ipc_channels push from the backend.
## Handles gen3d.progress event messages.
func receive(channel: String, payload: Dictionary) -> void:
	match channel:
		"gen3d.progress":
			_last_progress_msg = str(payload.get("message", ""))
			# While in-flight the ticker folds this into the live status line.
			if not _in_flight:
				_set_status(_last_progress_msg)


# ── Plugin platform lifecycle hooks ──────────────────────────────────────────

func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx


func _on_panel_unload() -> void:
	# Nothing to teardown beyond what Godot handles automatically.
	pass


func _on_panel_save_request() -> Dictionary:
	var mode: int = _mode_toggle.get_item_id(_mode_toggle.selected) if _mode_toggle != null else MODE_TEXT
	return {
		"version": 1,
		"mode": mode,
		"positive_prompt": _prompt_edit.text if _prompt_edit != null else "",
		"negative_prompt": _neg_prompt_edit.text if _neg_prompt_edit != null else "",
		"image_path": _image_path_edit.text if _image_path_edit != null else "",
		"steps": int(_steps_spin.value) if _steps_spin != null else 25,
		"guidance": _guidance_spin.value if _guidance_spin != null else 5.5,
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

	if _prompt_edit != null:
		_prompt_edit.text = str(document.get("positive_prompt", ""))
	if _neg_prompt_edit != null:
		_neg_prompt_edit.text = str(document.get("negative_prompt", ""))
	if _image_path_edit != null:
		_image_path_edit.text = str(document.get("image_path", ""))
	if _steps_spin != null:
		_steps_spin.value = float(document.get("steps", _steps_spin.value))
	if _guidance_spin != null:
		_guidance_spin.value = float(document.get("guidance", _guidance_spin.value))

	var artifact_path: String = str(document.get("last_artifact_path", ""))
	if artifact_path != "" and FileAccess.file_exists(artifact_path):
		_last_artifact_path = artifact_path
		_set_status("Reloading last mesh…")
		var ok: bool = _load_glb(artifact_path)
		if ok:
			_set_status("Restored: %s" % artifact_path.get_file())
			if _save_btn != null:
				_save_btn.disabled = false
			if _regenerate_btn != null:
				_regenerate_btn.disabled = false
		else:
			_set_status("Could not reload: %s" % artifact_path)


# ── Helpers ──────────────────────────────────────────────────────────────────

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
	# when the backend sends no intermediate progress (3d/movie can run minutes).
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
