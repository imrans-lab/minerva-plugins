class_name Scansort_Panel
extends MinervaPluginPanel
## Scansort vault browser panel — T7 R1 substrate.
##
## Layout:
##   VBoxContainer
##     HSplitContainer
##       Panel        LeftPane   — file tree
##       Panel        RightPane  — detail/status view
##     HBoxContainer  StatusPanel
##
## R7: Internal toolbar removed. A "File" MenuButton is injected into the
## editor chrome bar via get_editor_actions().
## R8: Settings dialog dropped. Model selection for classify calls inherited
##     from Minerva's Chat panel quick-select via _resolve_chat_model_for_classify().
##
## Open-vault flow (R1):
##   1. User clicks File → "Open Vault…"
##   2. FileDialog opens; user picks a .ssort file
##   3. Panel calls minerva_scansort_check_vault_has_password
##   4a. No password → calls minerva_scansort_open_vault → enters "vault ready" state
##   4b. Has password → shows PasswordDialog in ENTER mode
##       → user submits → calls minerva_scansort_verify_password
##       → on success → calls minerva_scansort_open_vault → enters "vault ready" state
##
## Create-vault flow (R1):
##   1. User clicks File → "New Vault…"
##   2. FileDialog (SAVE_FILE mode) opens; user picks location + .ssort name
##   3. Panel calls minerva_scansort_create_vault
##   4. Shows PasswordDialog in SET mode (optional — user can skip)
##   5. If password set → calls minerva_scansort_set_password
##   6. Enters "vault ready" state
##
## R2 will populate LeftPane / RightPane via vault_opened signal.
##
## Ported from: ccsandbox/experiments/scansort/scripts/ui/app_shell.gd
## Architectural differences from experiment:
##   - No class_name autoloads (ScanFileTree, ScanVaultPanel, etc.)
##   - No VaultStore direct calls — all vault operations go via conn.call_tool()
##   - PasswordDialog adapted: does not hold a VaultStore reference
##   - Plugin connection guard in every _on_*_pressed handler

## Preload the password dialog script (off-tree: no class_name).
const _PasswordDialog: Script = preload("password_dialog.gd")

## U4: unified scan-tree component + providers (off-tree: no class_name).
const _ScanTree:       Script = preload("scan_tree.gd")
const _SourceProvider: Script = preload("scan_tree_source_provider.gd")
const _VaultProvider:  Script = preload("scan_tree_vault_provider.gd")
const _StatusPanel:    Script = preload("status_panel.gd")

## R3: add-document dialog (off-tree: no class_name).
const _AddDocumentDialog: Script = preload("add_document_dialog.gd")

## R4: edit-details and rules-editor dialogs (off-tree: no class_name).
const _EditDetailsDialog: Script  = preload("edit_details_dialog.gd")
const _RulesEditorDialog: Script  = preload("rules_editor_dialog.gd")

## R5: vault registry dialog (off-tree: no class_name).
const _VaultRegistryDialog: Script = preload("vault_registry_dialog.gd")

const _SettingsDialog: Script       = preload("settings_dialog.gd")
const _RecoverySheetDialog: Script  = preload("recovery_sheet_dialog.gd")
const _UiScale: Script         = preload("ui_scale.gd")

## U7: disk tree provider (off-tree: no class_name).
const _DiskProvider: Script = preload("scan_tree_disk_provider.gd")

## W5: destination registry provider — vault or directory destination.
const _DestinationProvider: Script = preload("scan_tree_destination_provider.gd")

## W5b: aggregate area providers (one per kind) for the two-area splitter layout.
const _AreaProvider: Script = preload("scan_tree_area_provider.gd")

## W5g: extract-target picker dialog (off-tree: no class_name).
const _ExtractTargetDialog: Script = preload("extract_target_dialog.gd")

## RCA 019e4ca264: per-vault password store (off-tree: no class_name).
const _VaultPasswordStore: Script = preload("vault_password_store.gd")

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted after a vault has been opened successfully.
## R2 panels listen to this to populate their views.
## vault_path: absolute path to the opened .ssort file
## vault_info: Dictionary returned by minerva_scansort_open_vault
signal vault_opened(vault_path: String, vault_info: Dictionary)

## Emitted when the active vault is closed.
signal vault_closed()

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## Context dict passed by the platform via _on_panel_loaded.
var _ctx: Dictionary = {}

## Absolute path of the currently open vault (empty if none).
var _active_vault_path: String = ""

## True if a vault is open.
var _vault_is_open: bool = false

# ---------------------------------------------------------------------------
# B1: session tracking — labels the panel has registered in the plugin session
# ---------------------------------------------------------------------------

## Label under which the active vault was registered (empty = none registered).
var _session_vault_label: String = ""

## Label under which the active source dir was registered (empty = none).
var _session_source_label: String = ""

## Labels of directory destinations registered this session.
var _session_dir_labels: Array[String] = []

## RCA 019e4ca264: per-vault password store. scansort allows multiple vaults
## open at once, so the password cannot live in a single slot — it is keyed by
## canonicalised vault path. Never logged. Replaces the old `_vault_password`.
var _vault_password_store: RefCounted = _VaultPasswordStore.new()

## R3: FileDialog for picking a document to ingest (separate from vault picker).
var _doc_file_dialog: FileDialog = null

## R7 polish: cached reference to the chrome MenuButton's popup so we can
## enable/disable vault-required items as the vault state changes. Lifetime
## is the editor's — guarded with is_instance_valid before every access.
var _chrome_popup: PopupMenu = null

# ---------------------------------------------------------------------------
# UI widgets
# ---------------------------------------------------------------------------

## R7: No internal toolbar. The File menu is returned via get_editor_actions()
## and lives in the editor chrome bar.
##
## U4: 2-column layout — SourcePane | DestPane — each hosting a unified
## scan_tree bound to a provider, with the status panel as a bottom bar.
## Process All / Stop live in the editor chrome bar (get_editor_actions),
## not in the panel.
## W5: DestPane is dynamic: N stacked scan_tree sub-trees, one per registered
##     destination (from minerva_scansort_destination_list). The old fixed
##     vault+disk pair is replaced by the destination registry.
var _source_tree: Tree = null
## W5: No longer used for main vault tree — kept for backward-compat reads in
##     tests that check "_dest_tree". Points to the first dest tree or null.
var _dest_tree:   Tree = null
## W5: No longer the fixed disk tree. Kept as null; tests that check "_disk_tree"
##     should migrate to the destinations array.
var _disk_tree:   Tree = null
var _source_provider: Object = null

## Per-file progress map, populated from kind=document events with file_path
## extras. Keys are rel_paths from the plugin; values are {status, target?, reason?}.
## Pushed to _source_provider.set_doc_progress on each event so the source pane
## renders live status badges in COL_DATE.
var _doc_progress: Dictionary = {}
## W5: U7's fixed dest/disk providers are subsumed by the per-destination
## _dest_providers array; these two stay declared (null) for smoke-test
## member checks (R195) — the dynamic model replaces their function.
var _dest_provider:   Object = null
var _disk_provider:   Object = null

## W5: per-registered-destination state. Parallel arrays indexed by position.
##   _dest_registry      — Array[Dictionary]  — destination dicts from destination_list
##   _dest_trees         — Array[Tree]         — one scan_tree per destination
##   _dest_providers     — Array[Object]       — one DestinationProvider per destination
##   _dest_containers    — Array[VBoxContainer] — one section container per destination
## All four are rebuilt together in _refresh_dest_pane().
var _dest_registry:    Array = []
var _dest_trees:       Array = []
var _dest_providers:   Array = []
var _dest_containers:  Array = []

## W5: The VBoxContainer that holds all destination sections + the add button.
## Child of the DestPane column, created in _build_ui().
var _dest_scroll_content: VBoxContainer = null

## W5: registry_path required by destination_add/list/remove tools.
## Lazily defaults to a machine-local per-user file so directory destinations
## can be managed before any vault is open.
var _registry_path: String = ""

## W5b: Two-area splitter layout — Vault area + Directory area, each backed
## by an aggregate AreaProvider that renders all destinations of that kind
## as top-level virtual-root rows with inline [Remove][Reprocess][Lock] buttons.
var _vault_area_tree: Tree = null
var _dir_area_tree: Tree = null
var _vault_area_provider: Object = null
var _dir_area_provider: Object = null

## Chrome-bar buttons — created in get_editor_actions(); the editor owns and
## frees them on teardown, so guard with is_instance_valid before use.
var _process_btn: Button = null
var _stop_btn:    Button = null

## Header-level destination menu for controlled batch extraction.
var _extract_marked_menu: MenuButton = null
var _context_menu: PopupMenu = null
var _context_menu_key: String = ""
var _context_menu_kind: String = ""
var _context_menu_role: String = ""
var _context_menu_dirs: Array = []

# ---------------------------------------------------------------------------
# U5: batch pipeline session state
# ---------------------------------------------------------------------------

## Set of absolute source paths processed during the current session.
## Used as a set; value is always true. Never persisted.
var _processed_keys: Dictionary = {}

## Subset of _processed_keys flagged low-confidence. Never persisted.
var _low_confidence_keys: Dictionary = {}

## Set to true by _on_stop_pressed(); the batch loop checks this between
## files and breaks early.
var _process_cancelled: bool = false

const DESTINATION_REGISTRY_FILENAME := "dest_registry.json"
var _status_panel: HBoxContainer = null

## File dialog (reused for open and create).
var _file_dialog: FileDialog = null

## Password dialog instance (created once, reused).
var _password_dialog: AcceptDialog = null

## Pending action while waiting for password dialog:
##   "open"   — waiting for password to open existing vault
##   "create" — waiting for password to protect a newly-created vault (optional)
##   ""       — no pending action
var _pending_password_action: String = ""

## Path involved in the current pending password action.
var _pending_vault_path: String = ""

## File dialog mode pending (to distinguish open vs create).
var _file_dialog_mode: String = ""  # "open" | "create"

# ---------------------------------------------------------------------------
# U6: inject-to-chat cache
# ---------------------------------------------------------------------------

## Pre-extracted text from the checked source files, rebuilt whenever the
## source-pane checkboxes change.  Empty string = nothing to inject.
var _inject_payload_cache: String = ""

## True when the user has toggled the inject-to-chat switch on.
var _inject_enabled: bool = false

# ---------------------------------------------------------------------------
# Platform hooks
# ---------------------------------------------------------------------------

func _ready() -> void:
	_build_ui()
	set_status("No vault open.")
	_subscribe_broker_progress()
	_subscribe_plugin_events()
	# Bootstrap source/destination data loaders so the panel reflects plugin
	# state immediately, without requiring the user to open a vault first.
	# Deferred so the plugin connection has a chance to come up first.
	call_deferred("_bootstrap_panel_state_if_needed")


func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx


func _on_panel_unload() -> void:
	# B1: close all session entries this panel registered.
	var conn := _get_connection()
	if conn != null:
		if not _session_vault_label.is_empty():
			await conn.call_tool(
				"minerva_scansort_session_close_vault",
				{"label": _session_vault_label},
			)
			_session_vault_label = ""
		if not _session_source_label.is_empty():
			await conn.call_tool(
				"minerva_scansort_session_close_source",
				{"label": _session_source_label},
			)
			_session_source_label = ""
		for dir_label in _session_dir_labels:
			await conn.call_tool(
				"minerva_scansort_session_close_directory",
				{"label": dir_label},
			)
		_session_dir_labels.clear()

	if _file_dialog != null and is_instance_valid(_file_dialog):
		_file_dialog.queue_free()
	if _password_dialog != null and is_instance_valid(_password_dialog):
		_password_dialog.queue_free()
	if _context_menu != null and is_instance_valid(_context_menu):
		_context_menu.queue_free()

# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	# U4: 2-column layout — SourcePane | DestPane — with the status panel as a
	# bottom bar. Process All / Stop live in the editor chrome bar, contributed
	# via get_editor_actions(); R7: no internal toolbar.
	var layout := VBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layout)

	var columns := HBoxContainer.new()
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 4)
	layout.add_child(columns)

	# --- Left column: source pane ---
	var source_col := VBoxContainer.new()
	source_col.name = "SourcePane"
	source_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	source_col.custom_minimum_size.x = 200
	var source_hdr := HBoxContainer.new()
	var source_header := Label.new()
	source_header.text = "Source"
	source_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_hdr.add_child(source_header)
	var source_add_btn := Button.new()
	source_add_btn.text = "+"
	source_add_btn.tooltip_text = "Pick the incoming source directory…"
	source_add_btn.flat = false
	source_add_btn.pressed.connect(_on_source_add_pressed)
	source_hdr.add_child(source_add_btn)
	source_col.add_child(source_hdr)
	_source_tree = _ScanTree.new()
	source_col.add_child(_source_tree)
	columns.add_child(source_col)

	# --- Right column: destination pane (W5b: VSplitContainer two-area layout) ---
	var dest_col := VBoxContainer.new()
	dest_col.name = "DestPane"
	dest_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dest_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dest_col.custom_minimum_size.x = 200

	# W5b: VSplitContainer — top = Vault area, bottom = Directory area.
	var dest_split := VSplitContainer.new()
	dest_split.name = "DestSplit"
	dest_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dest_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dest_col.add_child(dest_split)

	# --- Vault area (top half) ---
	var vault_area := VBoxContainer.new()
	vault_area.name = "VaultArea"
	vault_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vault_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vault_area.custom_minimum_size.y = 80

	var vault_hdr := HBoxContainer.new()
	var vault_hdr_lbl := Label.new()
	vault_hdr_lbl.text = "Vaults"
	vault_hdr_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vault_hdr.add_child(vault_hdr_lbl)
	_extract_marked_menu = MenuButton.new()
	_extract_marked_menu.text = "Extract Marked To"
	_extract_marked_menu.tooltip_text = "Extract checked vault documents to a registered directory destination."
	_extract_marked_menu.disabled = true
	_extract_marked_menu.size_flags_horizontal = Control.SIZE_SHRINK_END
	var extract_popup := _extract_marked_menu.get_popup()
	extract_popup.about_to_popup.connect(_populate_extract_marked_popup)
	extract_popup.id_pressed.connect(_on_extract_marked_menu_id_pressed)
	vault_hdr.add_child(_extract_marked_menu)
	var vault_add_btn := Button.new()
	vault_add_btn.text = "+"
	vault_add_btn.tooltip_text = "Add a vault destination…"
	vault_add_btn.flat = false
	vault_add_btn.custom_minimum_size.x = 30
	vault_add_btn.pressed.connect(_on_dest_add_for_kind.bind("vault"))
	vault_hdr.add_child(vault_add_btn)
	vault_area.add_child(vault_hdr)

	_vault_area_tree = _ScanTree.new()
	_vault_area_tree.tree_role = "dest:vault"
	_vault_area_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vault_area_tree.file_dropped.connect(_on_area_tree_file_dropped)
	_vault_area_tree.dest_button_pressed.connect(
		func(dest_id: String, action: String) -> void:
			_on_area_dest_button_pressed(dest_id, action)
	)
	# W5d: wire file_activated so double-click / open button opens the document.
	_vault_area_tree.file_activated.connect(
		func(key: String) -> void:
			_on_area_tree_file_activated(key)
	)
	_vault_area_tree.context_requested.connect(_on_area_tree_context_requested)
	vault_area.add_child(_vault_area_tree)
	dest_split.add_child(vault_area)

	# --- Directory area (bottom half) ---
	var dir_area := VBoxContainer.new()
	dir_area.name = "DirArea"
	dir_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dir_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dir_area.custom_minimum_size.y = 80

	var dir_hdr := HBoxContainer.new()
	var dir_hdr_lbl := Label.new()
	dir_hdr_lbl.text = "Directories"
	dir_hdr_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dir_hdr.add_child(dir_hdr_lbl)
	var dir_add_btn := Button.new()
	dir_add_btn.text = "+"
	dir_add_btn.tooltip_text = "Add a directory destination…"
	dir_add_btn.flat = false
	dir_add_btn.custom_minimum_size.x = 30
	dir_add_btn.pressed.connect(_on_dest_add_for_kind.bind("directory"))
	dir_hdr.add_child(dir_add_btn)
	dir_area.add_child(dir_hdr)

	_dir_area_tree = _ScanTree.new()
	_dir_area_tree.tree_role = "dest:directory"
	_dir_area_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dir_area_tree.file_dropped.connect(_on_area_tree_file_dropped)
	_dir_area_tree.dest_button_pressed.connect(
		func(dest_id: String, action: String) -> void:
			_on_area_dest_button_pressed(dest_id, action)
	)
	# W5d: wire file_activated for directory file rows (open directly via shell).
	_dir_area_tree.file_activated.connect(
		func(key: String) -> void:
			_on_area_tree_file_activated(key)
	)
	_dir_area_tree.context_requested.connect(_on_area_tree_context_requested)
	dir_area.add_child(_dir_area_tree)
	dest_split.add_child(dir_area)

	# W5: keep _dest_scroll_content as a hidden off-screen VBoxContainer so that
	# pre-existing tests that check "panel._dest_scroll_content != null" still pass.
	# _add_dest_section (called directly by T/V test groups) will append into it.
	_dest_scroll_content = VBoxContainer.new()
	_dest_scroll_content.name = "_DestScrollContent"
	_dest_scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dest_scroll_content.visible = false
	dest_col.add_child(_dest_scroll_content)

	columns.add_child(dest_col)

	# --- Status bar along the bottom ---
	_status_panel = _StatusPanel.new()
	_status_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(_status_panel)

	# U6: assign source role for drag context.
	_source_tree.tree_role = "source"
	# Rebuild inject payload whenever source checkboxes change.
	_source_tree.check_toggled.connect(_on_source_check_toggled)
	# Double-click an unsorted source file → open it. The source provider's
	# row key is the absolute file path, so _on_area_tree_file_activated's
	# path branch (OS.shell_open) handles it directly.
	_source_tree.file_activated.connect(_on_area_tree_file_activated)

# ---------------------------------------------------------------------------
# Menu handling
# ---------------------------------------------------------------------------

func _on_file_menu_id_pressed(id: int) -> void:
	match id:
		0: _on_new_vault_pressed()
		1: _on_open_vault_pressed()
		2: _on_close_session_pressed()
		3: _on_add_document_pressed()
		4: _on_rules_editor_pressed()
		5: _on_vault_registry_pressed()
		8: _on_clear_cache_pressed()
		11: _on_settings_pressed()
		12: _on_export_marked_pressed()
		13: _on_recovery_sheet_pressed()


func _on_new_vault_pressed() -> void:
	_file_dialog_mode = "create"
	_open_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, "Create New Vault")


func _on_open_vault_pressed() -> void:
	_file_dialog_mode = "open"
	_open_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, "Open Vault")


func _on_close_vault_pressed() -> void:
	if not _vault_is_open:
		set_status("No vault is open.")
		return
	_vault_password_store.forget(_active_vault_path)  # drop just this vault's password
	_active_vault_path = ""
	_vault_is_open = false
	set_status("Vault closed.")
	vault_closed.emit()
	# R2: clear views.
	_on_vault_closed_r2()
	_refresh_chrome_menu_state()


## DCR 019e3d67: File→Close drops the entire scansort session back to its
## initialized state. Calls minerva_scansort_session_reset (in-memory only —
## no disk side-effects), then mirrors the existing source/vault close paths
## to clear local panel state + refresh both panes. Always safe to invoke on
## an empty session (the MCP tool reports zero counts and the panel re-zeros
## its local label bookkeeping).
func _on_close_session_pressed() -> void:
	var conn := _get_connection()
	if conn != null:
		var result: Dictionary = await conn.call_tool(
			"minerva_scansort_session_reset",
			{},
		)
		if not result.get("ok", false):
			set_status("Close session failed: %s" % result.get("error", "unknown"))
			return
		var cleared: Dictionary = result.get("cleared", {})
		set_status(
			"Session closed (vaults: %d, dirs: %d, sources: %d)."
			% [int(cleared.get("vaults", 0)), int(cleared.get("dirs", 0)), int(cleared.get("sources", 0))]
		)
	else:
		set_status("Session closed.")

	# Mirror _on_vault_closed_r2 to clear local vault chrome + emit close.
	# Session reset drops every vault, so clear the whole password store.
	_active_vault_path = ""
	_vault_is_open = false
	_vault_password_store.clear()
	vault_closed.emit()
	_on_vault_closed_r2()

	# Drop our local label bookkeeping — the broker already cleared its side.
	_session_vault_label = ""
	_session_source_label = ""
	_session_dir_labels.clear()

	# Refresh the source pane (mirror of _do_set_source_dir / vault-close paths).
	if _source_tree != null and is_instance_valid(_source_tree):
		_source_tree.set_provider(null)
		_source_tree.populate([])

	# Refresh the destination trees if their providers are still wired up.
	_refresh_all_dest_trees_if_ready()
	_refresh_chrome_menu_state()


## DCR 019e41a5: File→Clear Cache deletes the `.scansort-state.json` source
## manifest under every currently-open source so the next Start re-scans
## those files instead of skipping them. Vault, vault dedup, library, and
## in-memory session all untouched. Modal confirm before action.
func _on_clear_cache_pressed() -> void:
	# Get source count via broker (single source of truth — panel only tracks
	# one label but the broker can have more).
	var conn := _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	var state: Dictionary = await conn.call_tool("minerva_scansort_session_state", {})
	if not state.get("ok", false):
		set_status("Clear cache: failed to read session state.")
		return
	var sources: Array = state.get("sources", [])
	var n: int = sources.size()
	if n == 0:
		set_status("Clear cache: no sources open.")
		return

	var dlg := ConfirmationDialog.new()
	dlg.title = "Clear Cache"
	dlg.dialog_text = (
		"Clear cache for %d source(s)?\n\nFiles will be re-processed on the next run.\n"
		% n
	)
	dlg.confirmed.connect(func() -> void:
		await _do_clear_cache()
		dlg.queue_free()
	)
	dlg.canceled.connect(func() -> void:
		dlg.queue_free()
	)
	add_child(dlg)
	dlg.popup_centered(Vector2i(420, 160))


func _do_clear_cache() -> void:
	var conn := _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_clear_source_cache",
		{},
	)
	if not result.get("ok", false):
		set_status("Clear cache failed: %s" % result.get("error", "unknown"))
		return
	var cleared: int = int(result.get("cleared", 0))
	var attempted: int = int(result.get("attempted", 0))
	set_status("Cleared cache for %d of %d source(s)." % [cleared, attempted])

# ---------------------------------------------------------------------------
# File dialog
# ---------------------------------------------------------------------------

func _open_file_dialog(mode: FileDialog.FileMode, dialog_title: String) -> void:
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_UiScale.apply_to(_file_dialog)
		# Browse the real filesystem, not Godot's res:// resource view.
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.file_selected.connect(_on_file_selected)
		_file_dialog.canceled.connect(_on_file_dialog_cancelled)
		add_child(_file_dialog)

	_file_dialog.file_mode = mode
	_file_dialog.title = dialog_title
	_file_dialog.filters = PackedStringArray(["*.ssort ; Scansort Vault"])
	_file_dialog.popup_centered(Vector2i(700, 500))


func _on_file_selected(path: String) -> void:
	if _file_dialog_mode == "open":
		_begin_open_vault(path)
	elif _file_dialog_mode == "create":
		_begin_create_vault(path)
	_file_dialog_mode = ""


func _on_file_dialog_cancelled() -> void:
	_file_dialog_mode = ""

# ---------------------------------------------------------------------------
# Create vault flow
# ---------------------------------------------------------------------------

func _begin_create_vault(path: String) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	set_status("Creating vault...")
	var vault_name: String = path.get_file().get_basename()
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_create_vault",
		{"path": path, "name": vault_name}
	)
	if not result.get("ok", false):
		set_status("ERROR: create_vault failed — %s" % result.get("error", "unknown"))
		return

	set_status("Vault created. Set a password (optional)...")
	_pending_vault_path = path
	_pending_password_action = "create"
	_show_password_dialog_set()


func _on_create_vault_password_submitted(password: String, hint: String, _mode: int) -> void:
	if password.is_empty():
		# No password chosen — open the vault directly. Record it as a known
		# (non-encrypted) vault so document opens don't ask to "open its vault".
		_vault_password_store.set_password(_pending_vault_path, "")
		await _do_open_vault(_pending_vault_path)
		_pending_vault_path = ""
		_pending_password_action = ""
		return

	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	set_status("Setting vault password...")
	var set_result: Dictionary = await conn.call_tool(
		"minerva_scansort_set_password",
		{"path": _pending_vault_path, "password": password}
	)
	if not set_result.get("ok", false):
		set_status("ERROR: set_password failed — %s" % set_result.get("error", "unknown"))
		if is_instance_valid(_password_dialog):
			_password_dialog.show_error("set_password failed: %s" % set_result.get("error", "unknown"))
		return

	if not hint.is_empty():
		# Best-effort: ignore errors on hint storage.
		await conn.call_tool(
			"minerva_scansort_update_project_key",
			{"path": _pending_vault_path, "key": "password_hint", "value": hint}
		)

	# R3: cache the password (per-vault) so the ingest pipeline can use it.
	_vault_password_store.set_password(_pending_vault_path, password)
	await _do_open_vault(_pending_vault_path)
	_pending_vault_path = ""
	_pending_password_action = ""

# ---------------------------------------------------------------------------
# Open vault flow
# ---------------------------------------------------------------------------

func _begin_open_vault(path: String) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	set_status("Checking vault...")
	var pw_check: Dictionary = await conn.call_tool(
		"minerva_scansort_check_vault_has_password",
		{"path": path}
	)
	if not pw_check.get("ok", false):
		set_status("ERROR: check_vault_has_password failed — %s" % pw_check.get("error", "unknown"))
		return

	var has_pw: bool = pw_check.get("has_password", false)
	if not has_pw:
		# No password — open directly. Record it as a known (non-encrypted)
		# vault so document opens don't ask to "open its vault".
		_vault_password_store.set_password(path, "")
		await _do_open_vault(path)
		return

	# Has password — ask the user.
	var hint: String = pw_check.get("hint", "")
	_pending_vault_path = path
	_pending_password_action = "open"
	_show_password_dialog_enter(hint)


func _on_open_vault_password_submitted(password: String, _hint: String, _mode: int) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	set_status("Verifying password...")
	var verify: Dictionary = await conn.call_tool(
		"minerva_scansort_verify_password",
		{"path": _pending_vault_path, "password": password}
	)
	if not verify.get("ok", false):
		set_status("ERROR: verify_password failed — %s" % verify.get("error", "unknown"))
		if is_instance_valid(_password_dialog):
			_password_dialog.show_error("verify_password error: %s" % verify.get("error", "unknown"))
		return

	if not verify.get("verified", false):
		set_status("Incorrect password.")
		if is_instance_valid(_password_dialog):
			_password_dialog.show_wrong_password_error()
		return

	# R3: cache the password (per-vault) for use in the ingest pipeline.
	_vault_password_store.set_password(_pending_vault_path, password)
	await _do_open_vault(_pending_vault_path)
	_pending_vault_path = ""
	_pending_password_action = ""


## Final step: call open_vault and transition to vault-ready state.
func _do_open_vault(path: String) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	set_status("Opening vault...")
	var open_result: Dictionary = await conn.call_tool(
		"minerva_scansort_open_vault",
		{"path": path}
	)
	if not open_result.get("ok", false):
		set_status("ERROR: open_vault failed — %s" % open_result.get("error", "unknown"))
		return

	_active_vault_path = path
	_vault_is_open = true
	# open_vault returns {ok, info: {name, ...}} — name is nested, not flat.
	var vault_info: Dictionary = open_result.get("info", {})
	var vault_name: String = vault_info.get("name", path.get_file())
	set_status("Vault open: %s" % vault_name)
	_refresh_chrome_menu_state()
	vault_opened.emit(path, open_result)
	# R2: populate views.
	_on_vault_opened_r2(path, open_result)

# ---------------------------------------------------------------------------
# Password dialog helpers
# ---------------------------------------------------------------------------

func _ensure_password_dialog() -> void:
	if _password_dialog == null or not is_instance_valid(_password_dialog):
		_password_dialog = _PasswordDialog.new()
		add_child(_password_dialog)


func _show_password_dialog_set() -> void:
	_ensure_password_dialog()
	# Disconnect any stale connections.
	if _password_dialog.password_submitted.is_connected(_on_create_vault_password_submitted):
		_password_dialog.password_submitted.disconnect(_on_create_vault_password_submitted)
	if _password_dialog.password_submitted.is_connected(_on_open_vault_password_submitted):
		_password_dialog.password_submitted.disconnect(_on_open_vault_password_submitted)
	_password_dialog.password_submitted.connect(_on_create_vault_password_submitted)
	_password_dialog.show_set_password()


func _show_password_dialog_enter(hint: String) -> void:
	_ensure_password_dialog()
	# Disconnect any stale connections.
	if _password_dialog.password_submitted.is_connected(_on_open_vault_password_submitted):
		_password_dialog.password_submitted.disconnect(_on_open_vault_password_submitted)
	if _password_dialog.password_submitted.is_connected(_on_create_vault_password_submitted):
		_password_dialog.password_submitted.disconnect(_on_create_vault_password_submitted)
	_password_dialog.password_submitted.connect(_on_open_vault_password_submitted)
	_password_dialog.show_enter_password(hint)

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# R2 view coordination
# ---------------------------------------------------------------------------

func _on_vault_opened_r2(path: String, open_result: Dictionary) -> void:
	var conn := _get_connection()
	# open_vault returns {ok, info: {name, ...}} — name is nested, not flat.
	var vault_info: Dictionary = open_result.get("info", {})
	var vault_name: String = vault_info.get("name", path.get_file())

	# U4: bind the source provider to its scan_tree and refresh.
	# The source provider takes the vault path so it can flag in-vault files.
	_source_provider = _SourceProvider.new()
	_source_provider.init(conn, path)
	if _source_tree != null and is_instance_valid(_source_tree):
		_source_tree.set_provider(_source_provider)
		await _source_tree.refresh()

	# W5: destination routing is machine-local, not vault-local.  Keep any
	# registry path already chosen by no-vault directory setup; otherwise use
	# the default per-user destination registry.
	_ensure_destination_registry_path()

	# W5c: auto-register the open vault as a machine-local routing target.
	# This is idempotent — "already registered" errors are treated as success.
	# The area tree rendering (below) does NOT depend on this succeeding.
	if conn != null and not _registry_path.is_empty():
		var vault_label: String = path.get_file().get_basename()
		var reg_result: Dictionary = await conn.call_tool(
			"minerva_scansort_destination_add",
			{
				"registry_path": _registry_path,
				"kind":          "vault",
				"path":          path,
				"label":         vault_label,
			},
		)
		if not reg_result.get("ok", false):
			var reg_err: String = str(reg_result.get("error", ""))
			if not reg_err.contains("already registered"):
				push_warning("[ScansortPanel] auto-register vault failed: %s" % reg_err)
			# Either already registered (idempotent OK) or warning logged — continue either way.

	# W5: load destinations and build the dynamic right column (legacy stacked sections).
	await _refresh_dest_pane(conn)

	# W5b / W5c: build/refresh the two-area aggregate trees.
	# The vault area renders the open vault directly from its file; no registry dependency.
	await _refresh_area_trees(conn)

	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.init(conn)
		_status_panel.set_vault(vault_name, 0)
		_status_panel.set_status("Idle")

	# B1: register this vault in the session.
	if conn != null:
		var vault_label: String = path.get_file().get_basename()
		_session_vault_label = vault_label
		await conn.call_tool(
			"minerva_scansort_session_open_vault",
			{"label": vault_label, "path": path},
		)


func _on_vault_closed_r2() -> void:
	# B1: deregister vault from session before clearing local state.
	if not _session_vault_label.is_empty():
		var conn := _get_connection()
		if conn != null:
			await conn.call_tool(
				"minerva_scansort_session_close_vault",
				{"label": _session_vault_label},
			)
		_session_vault_label = ""

	if _source_tree != null and is_instance_valid(_source_tree):
		_source_tree.set_provider(null)
		_source_tree.populate([])
	# W5: clear all destination trees.
	_clear_dest_pane()
	# W5b: clear area trees.
	if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
		_vault_area_tree.set_provider(null)
		_vault_area_tree.populate([])
	if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
		_dir_area_tree.set_provider(null)
		_dir_area_tree.populate([])
	_vault_area_provider = null
	_dir_area_provider = null
	_source_provider = null
	_registry_path = ""
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.clear()


# ---------------------------------------------------------------------------
# W5: destination registry UI — build / refresh / add / remove
# ---------------------------------------------------------------------------

## Remove all destination section nodes from the scroll content and clear
## the parallel arrays. Does NOT free the providers (RefCounted — auto-freed).
func _clear_dest_pane() -> void:
	for container in _dest_containers:
		if container != null and is_instance_valid(container):
			container.queue_free()
	_dest_registry.clear()
	_dest_trees.clear()
	_dest_providers.clear()
	_dest_containers.clear()
	_dest_tree = null
	_disk_tree = null


## Fetch destination_list and rebuild the stacked sub-trees.
## Async — awaits an MCP call then awaits each tree's refresh().
func _refresh_dest_pane(conn: Object) -> void:
	_clear_dest_pane()
	if _dest_scroll_content == null or not is_instance_valid(_dest_scroll_content):
		return
	if conn == null:
		return
	if _registry_path.is_empty():
		return

	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_destination_list",
		{"registry_path": _registry_path},
	)
	if not result.get("ok", false):
		push_warning("[ScansortPanel] destination_list failed: %s" % result.get("error", "unknown"))
		return

	var destinations: Array = result.get("destinations", [])
	_dest_registry = destinations.duplicate(true)

	for dest: Dictionary in destinations:
		_add_dest_section(conn, dest)

	# Back-compat: _dest_tree points to first destination tree (if any) so tests
	# that check panel._dest_tree still see a non-null Tree after open.
	if _dest_trees.size() > 0:
		_dest_tree = _dest_trees[0]

	# Refresh each destination tree sequentially so the UI settles before return.
	for i: int in range(_dest_trees.size()):
		var tree: Tree = _dest_trees[i]
		if tree != null and is_instance_valid(tree):
			await (tree as Object).call("refresh")


## Build one destination section: header row (label + reprocess + lock + remove) + scan_tree.
## W8: adds a Reprocess button and a locked toggle to each section header.
func _add_dest_section(conn: Object, dest: Dictionary) -> void:
	if _dest_scroll_content == null or not is_instance_valid(_dest_scroll_content):
		return

	var dest_id: String  = str(dest.get("id", ""))
	var label: String    = str(dest.get("label", dest.get("path", dest_id)))
	var kind: String     = str(dest.get("kind", ""))
	var is_locked: bool  = bool(dest.get("locked", false))

	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_theme_constant_override("separation", 2)
	_dest_scroll_content.add_child(section)

	# Header: "[kind icon] label" + reprocess btn + lock toggle + "×" remove button.
	var hdr := HBoxContainer.new()
	var hdr_lbl := Label.new()
	var kind_icon: String = "V:" if kind == "vault" else "D:"
	hdr_lbl.text = "%s %s" % [kind_icon, label]
	hdr_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr.add_child(hdr_lbl)

	# W8: Reprocess button — disabled when locked.
	var reprocess_btn := Button.new()
	reprocess_btn.name = "ReprocessBtn"
	reprocess_btn.text = "⟳"
	reprocess_btn.tooltip_text = "Reprocess: clear this destination's state for a clean re-run"
	reprocess_btn.flat = true
	reprocess_btn.disabled = is_locked
	var captured_id   := dest_id
	var captured_label := label
	reprocess_btn.pressed.connect(func() -> void:
		_on_dest_reprocess_pressed(captured_id, captured_label)
	)
	hdr.add_child(reprocess_btn)

	# W8: Locked toggle (CheckBox). Checked = destination is locked/final.
	var lock_check := CheckBox.new()
	lock_check.name = "LockCheck"
	lock_check.text = "🔒"
	lock_check.button_pressed = is_locked
	lock_check.tooltip_text = "Lock this destination to prevent reprocessing"
	lock_check.toggled.connect(func(pressed: bool) -> void:
		_on_dest_locked_toggled(captured_id, pressed, reprocess_btn)
	)
	hdr.add_child(lock_check)

	var remove_btn := Button.new()
	remove_btn.text = "×"
	remove_btn.tooltip_text = "Remove this destination from the registry"
	remove_btn.flat = true
	# Capture dest_id by value for the closure.
	remove_btn.pressed.connect(func() -> void:
		_on_dest_remove_pressed(captured_id)
	)
	hdr.add_child(remove_btn)
	section.add_child(hdr)

	# Scan tree for this destination.
	var st: Tree = _ScanTree.new()
	st.size_flags_vertical = Control.SIZE_EXPAND_FILL
	st.custom_minimum_size.y = 80
	st.tree_role = "dest:%s" % dest_id
	section.add_child(st)

	# Provider.
	var provider: Object = _DestinationProvider.new()
	provider.init(conn, _registry_path, dest)
	st.set_provider(provider)

	# Wire drop handler: pass dest_id so the handler knows which destination.
	var captured_dest := dest.duplicate(true)
	st.file_dropped.connect(func(drag_data: Dictionary, target_key: String, target_kind: String) -> void:
		_on_tree_file_dropped(drag_data, target_key, target_kind, captured_dest)
	)

	_dest_trees.append(st)
	_dest_providers.append(provider)
	_dest_containers.append(section)


## Refresh all existing destination trees from their providers.
## W5b: also refreshes the two aggregate area trees.
func _refresh_all_dest_trees() -> void:
	for tree in _dest_trees:
		if tree != null and is_instance_valid(tree):
			await (tree as Object).call("refresh")
	# W5b: refresh the area trees too.
	if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
		await _vault_area_tree.refresh()
	if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
		await _dir_area_tree.refresh()


## W5b / W5c: Build / refresh the two aggregate area providers and populate the area trees.
## For the vault area the open vault path is passed explicitly so it is always
## rendered directly from its file (W5c — not registry-dependent).
func _refresh_area_trees(conn: Object) -> void:
	if conn == null:
		return
	# Vault area requires an open vault path (W5c); directory area requires a registry path.
	# Either can be empty without crashing — the providers return [] gracefully.
	# Build / replace providers (RefCounted — old refs auto-freed on reassign).
	_vault_area_provider = _AreaProvider.new()
	_vault_area_provider.init(conn, _registry_path, "vault", _active_vault_path)
	_dir_area_provider = _AreaProvider.new()
	_dir_area_provider.init(conn, _registry_path, "directory")

	if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
		_vault_area_tree.set_provider(_vault_area_provider)
		await _vault_area_tree.refresh()
	if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
		_dir_area_tree.set_provider(_dir_area_provider)
		await _dir_area_tree.refresh()


## W5b: handler for dest_button_pressed emitted by either area tree.
## Resolves dest_id and dispatches to the appropriate action.
func _on_area_dest_button_pressed(dest_id: String, action: String) -> void:
	var conn = _get_connection()
	if conn == null:
		return
	if not _ensure_destination_registry_path():
		return
	# Find the destination dict for label + locked state from either provider.
	var dest_dict: Dictionary = _find_dest_by_id(dest_id)
	var dest_label: String = str(dest_dict.get("label", dest_id))
	var is_locked: bool = bool(dest_dict.get("locked", false))

	match action:
		"remove":
			# W5d: disallow removing the currently-open vault (it is the primary context).
			var dest_path: String = str(dest_dict.get("path", ""))
			if not dest_path.is_empty() and dest_path == _active_vault_path:
				set_status("Cannot remove the currently-open vault destination.")
				return
			_on_dest_remove_pressed(dest_id)
		"reprocess":
			_on_dest_reprocess_pressed(dest_id, dest_label)
		"lock_toggle":
			# Toggle locked state; pass null for the reprocess_btn (not available here).
			_on_dest_locked_toggled(dest_id, not is_locked, null)
		"settings":
			# W5d: vault-level settings popup — "Set/Change Password…" and other vault ops.
			_on_vault_dest_settings_pressed(dest_id, dest_dict)
		"encrypt":
			# W5h: dest_id is a "doc:<id>" key here, not a destination id.
			_on_doc_encrypt_toggle(dest_id, true)
		"decrypt":
			_on_doc_encrypt_toggle(dest_id, false)


## W5h: encrypt or decrypt a single vault document at rest. `doc_key` is a
## "doc:<id>" tree key; `want_encrypted` is the desired new state. Fire-and-
## forget (called from a button handler); awaits the MCP call internally.
func _on_doc_encrypt_toggle(doc_key: String, want_encrypted: bool) -> void:
	if not doc_key.begins_with("doc:"):
		return
	var doc_id: int = int(doc_key.substr(4))
	var vault_path: String = _find_vault_path_for_doc_key(doc_key)
	if vault_path.is_empty():
		vault_path = _active_vault_path
	if vault_path.is_empty():
		set_status("Cannot change encryption: vault path unknown.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	var enc_pw: String = _vault_password_store.get_password(vault_path)
	if enc_pw.is_empty():
		set_status("Set a vault password first to encrypt/decrypt documents.")
		return
	set_status("%s document…" % ("Encrypting" if want_encrypted else "Decrypting"))
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_set_document_encrypted",
		{
			"vault_path": vault_path,
			"doc_id": doc_id,
			"encrypt": want_encrypted,
			"password": enc_pw,
		}
	)
	if not result.get("ok", false):
		set_status("ERROR: %s" % result.get("error", "unknown"))
		return
	set_status("Document %s." % ("encrypted" if want_encrypted else "decrypted"))
	# Refresh the vault area tree so the lock icon reflects the new state.
	if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
		await _vault_area_tree.refresh()


## W5b: find a destination dict from the area providers' last_destinations cache.
func _find_dest_by_id(dest_id: String) -> Dictionary:
	# Check vault provider first.
	if _vault_area_provider != null:
		var dests: Array = _vault_area_provider.get("last_destinations") if "last_destinations" in _vault_area_provider else []
		for d: Dictionary in dests:
			if str(d.get("id", "")) == dest_id:
				return d
	# Then directory provider.
	if _dir_area_provider != null:
		var dests: Array = _dir_area_provider.get("last_destinations") if "last_destinations" in _dir_area_provider else []
		for d: Dictionary in dests:
			if str(d.get("id", "")) == dest_id:
				return d
	# Also check _dest_registry (populated by _refresh_dest_pane).
	for d: Dictionary in _dest_registry:
		if str(d.get("id", "")) == dest_id:
			return d
	return {}


## W5d: handler for file_activated emitted by an area tree or the source tree.
## key starts with "doc:" → vault document: extract to temp dir then shell_open.
## key is an absolute path → directory or source file: shell_open directly.
func _on_area_tree_file_activated(key: String) -> void:
	if key.begins_with("doc:"):
		# Vault document — need to extract it first.
		var doc_id: int = int(key.substr(4))
		# Find the vault_path this doc belongs to by scanning the active tree item metas.
		# We look up the item in both area trees and read the vault_path meta set by scan_tree.
		var vault_path: String = _find_vault_path_for_doc_key(key)
		if vault_path.is_empty():
			# Fall back to the open vault path (most documents live there).
			vault_path = _active_vault_path
		if vault_path.is_empty():
			set_status("Cannot open document: vault path unknown.")
			return
		var conn = _get_connection()
		if conn == null:
			set_status("ERROR: scansort plugin not running.")
			return
		# Extract to a temp subdir under the user data dir.
		var tmp_dir: String = OS.get_user_data_dir().path_join("scansort_preview")
		DirAccess.make_dir_recursive_absolute(tmp_dir)
		# W5f / RCA 019e4ca264: pass the document's own vault password so
		# encrypted documents can be decrypted on extract. The per-vault store
		# keeps a password for every opened vault, so a document in any open
		# vault — not just the active one — gets the right password.
		var extract_args: Dictionary = {
			"vault_path": vault_path, "doc_id": doc_id, "dest": tmp_dir,
		}
		var pw: String = _vault_password_store.get_password(vault_path)
		if not pw.is_empty():
			extract_args["password"] = pw
		set_status("Extracting document…")
		var result: Dictionary = await conn.call_tool(
			"minerva_scansort_extract_document",
			extract_args
		)
		# extract_document returns {ok: true, path: "/abs/path/to/file"} on success.
		if not result.get("ok", false):
			var err_msg: String = str(result.get("error", "unknown"))
			# W5f / RCA 019e4ca264: an encrypt/password error only means
			# "open its vault first" when the document's vault genuinely is
			# NOT in the store. An unlocked vault that still errors is a real
			# backend failure and must surface as such.
			if not _vault_password_store.has_vault(vault_path) and (
				err_msg.to_lower().contains("encrypt")
				or err_msg.to_lower().contains("password")
			):
				set_status(
					"This document is encrypted. Open its vault first to unlock it."
				)
			else:
				set_status("ERROR: extract_document failed — %s" % err_msg)
			return
		var out_path: String = str(result.get("path", ""))
		if out_path.is_empty():
			set_status("ERROR: extract_document returned no path.")
			return
		set_status("Opening: %s" % out_path.get_file())
		OS.shell_open(out_path)
	else:
		# Directory file — absolute path, open directly.
		if key.is_empty():
			return
		set_status("Opening: %s" % key.get_file())
		OS.shell_open(key)


func _on_area_tree_context_requested(key: String, global_position: Vector2, kind: String, role: String) -> void:
	if key.is_empty():
		return
	if _context_menu == null or not is_instance_valid(_context_menu):
		_context_menu = PopupMenu.new()
		_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
		add_child(_context_menu)
	_context_menu.clear()
	_context_menu_key = key
	_context_menu_kind = kind
	_context_menu_role = role
	_context_menu_dirs = _directory_destinations()

	if role == "dest:vault" and key.begins_with("doc:"):
		_context_menu.add_item("Open", 0)
		_context_menu.add_item("Edit Details...", 1)
		var item: TreeItem = _find_item_by_key(_vault_area_tree, key) if _vault_area_tree != null else null
		var encrypted: bool = bool(item.get_meta("encrypted", false)) if item != null else false
		_context_menu.add_item("Decrypt" if encrypted else "Encrypt", 3 if encrypted else 2)
		_context_menu.add_separator()
		if _context_menu_dirs.is_empty():
			_context_menu.add_item("Add a directory destination first", 900)
		else:
			for i in range(_context_menu_dirs.size()):
				var dest: Dictionary = _context_menu_dirs[i]
				var label: String = str(dest.get("label", dest.get("path", "Directory")))
				_context_menu.add_item("Extract To %s" % label, 1000 + i)
			_context_menu.add_separator()
			_context_menu.add_item("Add Directory Destination...", 900)
	elif role == "dest:directory":
		if kind == "file":
			_context_menu.add_item("Open", 0)
		else:
			_context_menu.add_item("Extract Marked Here", 5)
			_context_menu.add_item("Open Folder", 6)
	else:
		return

	_context_menu.position = Vector2i(int(global_position.x), int(global_position.y))
	_context_menu.popup()


func _on_context_menu_id_pressed(id: int) -> void:
	if id == 900:
		_on_dest_add_for_kind("directory")
		return
	if id == 0:
		if _context_menu_role == "dest:directory" and _context_menu_kind == "folder":
			var dir_path: String = _resolve_dir_path_from_key(_context_menu_key)
			if not dir_path.is_empty():
				OS.shell_open(dir_path)
		else:
			_on_area_tree_file_activated(_context_menu_key)
		return
	if id == 1:
		if _context_menu_key.begins_with("doc:"):
			_on_edit_doc_pressed(int(_context_menu_key.substr(4)))
		return
	if id == 2 or id == 3:
		_on_doc_encrypt_toggle(_context_menu_key, id == 2)
		return
	if id == 5:
		var dest_dir: String = _resolve_dir_path_from_key(_context_menu_key)
		await _extract_checked_to_directory(dest_dir, dest_dir.get_file())
		return
	if id == 6:
		var dir_path: String = _resolve_dir_path_from_key(_context_menu_key)
		if not dir_path.is_empty():
			OS.shell_open(dir_path)
		return
	if id >= 1000:
		var idx := id - 1000
		if idx < 0 or idx >= _context_menu_dirs.size():
			return
		var dest: Dictionary = _context_menu_dirs[idx]
		var path: String = str(dest.get("path", ""))
		var label: String = str(dest.get("label", path.get_file()))
		await _extract_doc_keys_to_directory([_context_menu_key], path, label)


## W5d: walk both area trees to find the vault_path meta on the item with the given key.
## Returns "" if not found (caller falls back to _active_vault_path).
func _find_vault_path_for_doc_key(key: String) -> String:
	for tree in [_vault_area_tree, _dir_area_tree]:
		if tree == null or not is_instance_valid(tree):
			continue
		var found: TreeItem = _find_item_by_key(tree as Tree, key)
		if found != null and found.has_meta("vault_path"):
			var vp: String = str(found.get_meta("vault_path", ""))
			if not vp.is_empty():
				return vp
	return ""


## W5d: vault destination [Settings] button → PopupMenu with vault-level actions.
## Shows "Set/Change Password…" (reuses existing password dialog flow).
func _on_vault_dest_settings_pressed(dest_id: String, dest_dict: Dictionary) -> void:
	var dest_path: String = str(dest_dict.get("path", ""))
	# Only support settings for the open vault for now (the only vault with a live conn).
	if dest_path != _active_vault_path:
		set_status("Settings are only available for the currently-open vault.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	# Build a one-item PopupMenu anchored to the mouse position.
	var menu := PopupMenu.new()
	menu.add_item("Set / Change Password…", 0)
	add_child(menu)
	menu.id_pressed.connect(func(id: int) -> void:
		match id:
			0:
				# Reuse the existing set-password dialog flow.
				_pending_vault_path = _active_vault_path
				_pending_password_action = "create"
				_show_password_dialog_set()
		if is_instance_valid(menu):
			menu.queue_free()
	)
	menu.popup_on_parent(Rect2i(
		int(get_viewport().get_mouse_position().x),
		int(get_viewport().get_mouse_position().y),
		0, 0))


## W5b: file_dropped handler wired to both area trees.
## Resolves the destination from the drop target key (which is either "dest:<id>"
## for a top-level row, or a category/file key nested inside a destination).
## Walks up the item's parent chain to find the "dest:<id>" ancestor.
## W5g: vault-doc drops (role "dest:vault") onto directory rows are intercepted
## here and routed to _on_vault_doc_dropped_to_dir instead of classify logic.
func _on_area_tree_file_dropped(drag_data: Dictionary, target_key: String, target_kind: String) -> void:
	var role: String = str(drag_data.get("role", ""))

	# W5g: vault-doc → directory extract gesture.
	# A drag_data whose role is "dest:vault" carries a vault document key ("doc:<id>")
	# and vault_path.  The target is a row in the directory area tree (a dest:<id>
	# directory destination row or a dir:<name> subfolder row).
	if role == "dest:vault":
		await _on_vault_doc_dropped_to_dir(drag_data, target_key)
		return

	# Original classify / reclassify path — resolve which vault destination the
	# target row belongs to, then delegate to _on_tree_file_dropped.
	var dest_id: String = ""
	var dest_dict: Dictionary = {}

	if target_key.begins_with("dest:"):
		dest_id = target_key.substr(5)  # strip "dest:"
		dest_dict = _find_dest_by_id(dest_id)
	else:
		# Walk up the active tree's item hierarchy to find the dest ancestor.
		# Determine which tree emitted (vault or dir area tree).
		var tree_that_dropped: Tree = null
		if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
			# We find the item by key in both trees.
			var item = _find_item_by_key(_vault_area_tree, target_key)
			if item != null:
				tree_that_dropped = _vault_area_tree
		if tree_that_dropped == null and _dir_area_tree != null and is_instance_valid(_dir_area_tree):
			var item = _find_item_by_key(_dir_area_tree, target_key)
			if item != null:
				tree_that_dropped = _dir_area_tree
		if tree_that_dropped != null:
			var item = _find_item_by_key(tree_that_dropped, target_key)
			# Walk up to root's direct child (top-level dest row).
			while item != null:
				var parent = item.get_parent()
				if parent == null or parent == tree_that_dropped.get_root():
					break
				item = parent
			if item != null:
				var item_key: String = str(item.get_metadata(1))
				if item_key.begins_with("dest:"):
					dest_id = item_key.substr(5)
					dest_dict = _find_dest_by_id(dest_id)

	# Delegate to the main drop handler with the resolved dest context.
	_on_tree_file_dropped(drag_data, target_key, target_kind, dest_dict)


## W5g: handle a vault doc row dropped onto a directory tree row.
## Resolves the filesystem directory path from target_key and calls extract_document.
func _on_vault_doc_dropped_to_dir(drag_data: Dictionary, target_key: String) -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var drag_key: String = str(drag_data.get("key", ""))
	if not drag_key.begins_with("doc:"):
		return  # unexpected — only doc rows should have role dest:vault
	var doc_id: int = int(drag_key.substr(4))

	# vault_path is embedded in drag data by _get_drag_data (W5g).
	var vault_path: String = str(drag_data.get("vault_path", ""))
	if vault_path.is_empty():
		vault_path = _find_vault_path_for_doc_key(drag_key)
	if vault_path.is_empty():
		vault_path = _active_vault_path
	if vault_path.is_empty():
		set_status("Cannot extract: vault path unknown.")
		return

	# Resolve the target filesystem directory from target_key.
	# target_key may be:
	#   "dest:<id>"   — top-level directory destination row → use dest.path
	#   "dir:<name>"  — subfolder row → walk up to the "dest:<id>" ancestor + append name
	var dest_dir: String = _resolve_dir_path_from_key(target_key)
	if dest_dir.is_empty():
		set_status("Cannot extract: could not resolve target directory.")
		return

	var extract_args: Dictionary = {
		"vault_path": vault_path,
		"doc_id":     doc_id,
		"dest":       dest_dir,
	}
	var drag_pw: String = _vault_password_store.get_password(vault_path)
	if not drag_pw.is_empty():
		extract_args["password"] = drag_pw

	set_status("Extracting…")
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_document",
		extract_args
	)
	if not result.get("ok", false):
		var err: String = str(result.get("error", "unknown"))
		push_warning("[ScansortPanel] drag-extract: doc_id %d failed — %s" % [doc_id, err])
		set_status("Extract failed: %s" % err)
		return

	var out_file: String = str(result.get("path", ""))
	set_status("Extracted %s → %s" % [out_file.get_file(), dest_dir])

	# Refresh the directory tree so the new file shows up.
	if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
		await _dir_area_tree.refresh()


## W5g: resolve an absolute filesystem directory path from a dir-area tree key.
## "dest:<id>"  → look up destination.path in the dir provider's last_destinations.
## "dir:<name>" → walk up the dir tree to find the dest:<id> ancestor, then
##                 append the subfolder name.
func _resolve_dir_path_from_key(key: String) -> String:
	if key.begins_with("dest:"):
		var dest_id: String = key.substr(5)
		var dest_dict: Dictionary = _find_dest_by_id(dest_id)
		return str(dest_dict.get("path", ""))

	if key.begins_with("dir:"):
		var subfolder: String = key.substr(4)
		# Walk the dir area tree to find the parent dest:<id> ancestor.
		if _dir_area_tree == null or not is_instance_valid(_dir_area_tree):
			return ""
		var item: TreeItem = _find_item_by_key(_dir_area_tree, key)
		if item == null:
			return ""
		# Walk upward until we hit a "dest:…" key.
		var ancestor: TreeItem = item.get_parent()
		while ancestor != null and ancestor != _dir_area_tree.get_root():
			var anc_key: String = str(ancestor.get_metadata(1))
			if anc_key.begins_with("dest:"):
				var dest_id: String = anc_key.substr(5)
				var dest_dict: Dictionary = _find_dest_by_id(dest_id)
				var base_path: String = str(dest_dict.get("path", ""))
				if base_path.is_empty():
					return ""
				# Only append if subfolder is not the virtual "(root)" marker.
				if subfolder == "(root)":
					return base_path
				return base_path.path_join(subfolder)
			ancestor = ancestor.get_parent()
		return ""

	return ""


## W5b: helper — find a TreeItem by its COL_NAME metadata key, searching from root.
func _find_item_by_key(tree: Tree, key: String) -> TreeItem:
	var root: TreeItem = tree.get_root()
	if root == null:
		return null
	return _find_item_recursive(root, key)


func _find_item_recursive(item: TreeItem, key: String) -> TreeItem:
	if str(item.get_metadata(1)) == key:
		return item
	var child: TreeItem = item.get_first_child()
	while child != null:
		var found: TreeItem = _find_item_recursive(child, key)
		if found != null:
			return found
		child = child.get_next()
	return null


## "+" on the Source pane: picks an incoming directory and calls set_source_dir.
## Refreshes the source tree if a provider is bound (i.e. a vault is open).
func _on_source_add_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var picker := FileDialog.new()
	_UiScale.apply_to(picker)
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	picker.title = "Select Incoming Source Directory"

	picker.dir_selected.connect(func(p: String) -> void:
		picker.queue_free()
		_do_set_source_dir(conn, p)
	)
	picker.canceled.connect(func() -> void: picker.queue_free())
	add_child(picker)
	picker.popup_centered(Vector2i(700, 500))


func _do_set_source_dir(conn: Object, path: String) -> void:
	set_status("Setting source directory…")
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_set_source_dir",
		{"path": path, "recursive": true},
	)
	if not result.get("ok", false):
		set_status("Set source directory failed: %s" % result.get("error", "unknown"))
		return
	set_status("Source directory: %s" % path)
	# P0: the source pane must populate even if no vault is open yet.
	# _source_provider was historically created only inside _on_vault_opened_r2,
	# leaving the left pane empty when the user sets source-dir first.
	if _source_provider == null:
		_source_provider = _SourceProvider.new()
		_source_provider.init(conn, _active_vault_path)
		if _source_tree != null and is_instance_valid(_source_tree):
			_source_tree.set_provider(_source_provider)
	if _source_tree != null and is_instance_valid(_source_tree):
		await _source_tree.refresh()

	# B1: register this source directory in the session (close old one first if present).
	# Label must NOT be a path — use the basename, or a literal fallback for root-like paths.
	var src_label: String = path.get_file()
	if src_label.is_empty():
		src_label = "source"
	if not _session_source_label.is_empty():
		await conn.call_tool(
			"minerva_scansort_session_close_source",
			{"label": _session_source_label},
		)
	_session_source_label = src_label
	await conn.call_tool(
		"minerva_scansort_session_open_source",
		{"label": src_label, "path": path},
	)
	# DCR 019e41a5: source-gated File→Clear Cache item must refresh now.
	_refresh_chrome_menu_state()


## W5b: per-kind Add button handler — opens the add-destination dialog
## pre-set to the given kind ("vault" or "directory").
func _on_dest_add_for_kind(kind: String) -> void:
	if kind == "vault" and not _vault_is_open:
		_on_new_vault_pressed()
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	if not _ensure_destination_registry_path():
		set_status("No destination registry path.")
		return

	set_status("Adding %s destination..." % ("vault" if kind == "vault" else "directory"))
	var dlg := AcceptDialog.new()
	dlg.title = "Add %s Destination" % ("Vault" if kind == "vault" else "Directory")
	dlg.min_size = Vector2i(520, 220)
	_UiScale.apply_to(dlg)

	var vbox := VBoxContainer.new()
	dlg.add_child(vbox)

	# Label field.
	var label_row := HBoxContainer.new()
	var label_lbl := Label.new()
	label_lbl.text = "Label:"
	label_row.add_child(label_lbl)
	var label_edit := LineEdit.new()
	label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label_edit.placeholder_text = "e.g. Archived Invoices"
	label_row.add_child(label_edit)
	vbox.add_child(label_row)

	# Path field + browse button.
	var path_row := HBoxContainer.new()
	var path_lbl := Label.new()
	path_lbl.text = "Path:"
	path_row.add_child(path_lbl)
	var path_edit := LineEdit.new()
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if kind == "vault":
		path_edit.placeholder_text = "/absolute/path/to/vault.ssort"
	else:
		path_edit.placeholder_text = "/absolute/path/to/directory"
	path_row.add_child(path_edit)
	var browse_btn := Button.new()
	browse_btn.text = "…"
	path_row.add_child(browse_btn)
	vbox.add_child(path_row)

	add_child(dlg)

	browse_btn.pressed.connect(func() -> void:
		var picker := FileDialog.new()
		_UiScale.apply_to(picker)
		picker.access = FileDialog.ACCESS_FILESYSTEM
		if kind == "vault":
			picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			picker.filters = PackedStringArray(["*.ssort ; Scansort Vault"])
			picker.title = "Select Vault File"
		else:
			picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
			picker.title = "Select Directory"
		picker.file_selected.connect(func(p: String) -> void:
			path_edit.text = p
			picker.queue_free()
		)
		picker.dir_selected.connect(func(p: String) -> void:
			path_edit.text = p
			picker.queue_free()
		)
		picker.canceled.connect(func() -> void: picker.queue_free())
		add_child(picker)
		picker.popup_centered(Vector2i(700, 500))
	)

	dlg.confirmed.connect(func() -> void:
		var dest_path: String = path_edit.text.strip_edges()
		var dest_label: String = label_edit.text.strip_edges()
		if dest_path.is_empty():
			set_status("Add destination: path is required.")
			dlg.queue_free()
			return
		if dest_label.is_empty():
			dest_label = dest_path.get_file()
		_do_add_destination(conn, kind, dest_path, dest_label)
		dlg.queue_free()
	)
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered(Vector2i(520, 220))


## "+" add-destination button handler. Shows a simple dialog to pick kind + path.
func _on_dest_add_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	if not _ensure_destination_registry_path():
		set_status("No destination registry path.")
		return

	# Build a simple inline add-destination dialog (AcceptDialog + VBoxContainer).
	var dlg := AcceptDialog.new()
	dlg.title = "Add Destination"
	dlg.min_size = Vector2i(440, 220)
	_UiScale.apply_to(dlg)

	var vbox := VBoxContainer.new()
	dlg.add_child(vbox)

	# Kind selector.
	var kind_row := HBoxContainer.new()
	var kind_lbl := Label.new()
	kind_lbl.text = "Kind:"
	kind_row.add_child(kind_lbl)
	var kind_opt := OptionButton.new()
	kind_opt.add_item("Vault (.ssort)")
	kind_opt.add_item("Directory")
	kind_row.add_child(kind_opt)
	vbox.add_child(kind_row)

	# Label field.
	var label_row := HBoxContainer.new()
	var label_lbl := Label.new()
	label_lbl.text = "Label:"
	label_row.add_child(label_lbl)
	var label_edit := LineEdit.new()
	label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label_edit.placeholder_text = "e.g. Archived Invoices"
	label_row.add_child(label_edit)
	vbox.add_child(label_row)

	# Path field + browse button.
	var path_row := HBoxContainer.new()
	var path_lbl := Label.new()
	path_lbl.text = "Path:"
	path_row.add_child(path_lbl)
	var path_edit := LineEdit.new()
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.placeholder_text = "/absolute/path/to/vault.ssort or /directory"
	path_row.add_child(path_edit)
	var browse_btn := Button.new()
	browse_btn.text = "…"
	browse_btn.tooltip_text = "Browse for a vault or directory"
	path_row.add_child(browse_btn)
	vbox.add_child(path_row)

	add_child(dlg)

	# Browse button opens a file/directory picker.
	browse_btn.pressed.connect(func() -> void:
		var picker := FileDialog.new()
		_UiScale.apply_to(picker)
		picker.access = FileDialog.ACCESS_FILESYSTEM
		if kind_opt.selected == 0:
			picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			picker.filters = PackedStringArray(["*.ssort ; Scansort Vault"])
			picker.title = "Select Vault File"
		else:
			picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
			picker.title = "Select Directory"
		picker.file_selected.connect(func(p: String) -> void:
			path_edit.text = p
			picker.queue_free()
		)
		picker.dir_selected.connect(func(p: String) -> void:
			path_edit.text = p
			picker.queue_free()
		)
		picker.canceled.connect(func() -> void: picker.queue_free())
		add_child(picker)
		picker.popup_centered(Vector2i(700, 500))
	)

	dlg.confirmed.connect(func() -> void:
		var kind_str: String = "vault" if kind_opt.selected == 0 else "directory"
		var dest_path: String = path_edit.text.strip_edges()
		var dest_label: String = label_edit.text.strip_edges()
		if dest_path.is_empty():
			set_status("Add destination: path is required.")
			dlg.queue_free()
			return
		if dest_label.is_empty():
			dest_label = dest_path.get_file()
		_do_add_destination(conn, kind_str, dest_path, dest_label)
		dlg.queue_free()
	)
	dlg.canceled.connect(func() -> void: dlg.queue_free())

	dlg.popup_centered()


## Call destination_add then refresh the pane.
func _do_add_destination(conn: Object, kind: String, path: String, label: String) -> void:
	if not _ensure_destination_registry_path():
		set_status("No destination registry path.")
		return
	set_status("Adding destination…")
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_destination_add",
		{
			"registry_path": _registry_path,
			"kind":          kind,
			"path":          path,
			"label":         label,
		},
	)
	if not result.get("ok", false):
		set_status("ERROR: destination_add failed — %s" % result.get("error", "unknown"))
		return
	set_status("Destination added.")

	# B1: register directory destinations in the session.
	if kind == "directory":
		var dir_label: String = label if not label.is_empty() else path.get_file()
		_session_dir_labels.append(dir_label)
		await conn.call_tool(
			"minerva_scansort_session_open_directory",
			{"label": dir_label, "path": path},
		)

	await _refresh_dest_pane(conn)
	await _refresh_area_trees(conn)


## "×" remove-destination button handler.
func _on_dest_remove_pressed(dest_id: String) -> void:
	var conn = _get_connection()
	if conn == null:
		return
	if not _ensure_destination_registry_path():
		return

	set_status("Removing destination…")
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_destination_remove",
		{
			"registry_path": _registry_path,
			"id":            dest_id,
		},
	)
	if not result.get("ok", false):
		set_status("ERROR: destination_remove failed — %s" % result.get("error", "unknown"))
		return
	set_status("Destination removed.")
	await _refresh_dest_pane(conn)
	await _refresh_area_trees(conn)


## W8: Reprocess button handler — shows confirm dialog then calls backend.
## Called when the user clicks the ⟳ button on a destination's header.
## MUST show a confirm dialog before doing anything destructive.
func _on_dest_reprocess_pressed(dest_id: String, dest_label: String) -> void:
	var conn = _get_connection()
	if conn == null:
		return
	if not _ensure_destination_registry_path():
		return

	# Show confirm dialog — do NOT call the backend without explicit user confirmation.
	var dlg := AcceptDialog.new()
	dlg.title = "Confirm Reprocess"
	dlg.dialog_text = (
		"Reprocess destination '%s'?\n\n" % dest_label
		+ "This will PERMANENTLY DELETE all filed output for this destination\n"
		+ "(files in a directory, or document rows in a vault).\n\n"
		+ "The operation cannot be undone. Process All will re-populate it on the next run."
	)
	dlg.ok_button_text = "Reprocess"
	add_child(dlg)

	var confirmed := false
	dlg.confirmed.connect(func() -> void:
		confirmed = true
	)
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered(Vector2i(480, 220))

	# Wait for dialog to be dismissed.
	await dlg.visibility_changed
	if not confirmed:
		if is_instance_valid(dlg):
			dlg.queue_free()
		return
	if is_instance_valid(dlg):
		dlg.queue_free()

	# User confirmed — now call the backend.
	set_status("Reprocessing destination '%s'..." % dest_label)
	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_reprocess_destination",
		{
			"registry_path":  _registry_path,
			"destination_id": dest_id,
		},
	)
	if not result.get("ok", false):
		set_status("ERROR: reprocess_destination failed — %s" % result.get("error", "unknown"))
		return
	var summary: String = str(result.get("summary", "Done."))
	set_status("Reprocessed: %s" % summary)
	# Refresh this destination's sub-tree so the UI reflects the cleared state.
	await _refresh_dest_pane(conn)
	await _refresh_area_trees(conn)


## W8: Locked toggle handler — calls set_destination_locked and updates the
## Reprocess button's disabled state immediately (no full pane refresh needed).
func _on_dest_locked_toggled(dest_id: String, locked: bool, reprocess_btn: Button) -> void:
	var conn = _get_connection()
	if conn == null:
		return
	if not _ensure_destination_registry_path():
		return

	var result: Dictionary = await conn.call_tool(
		"minerva_scansort_set_destination_locked",
		{
			"registry_path":  _registry_path,
			"destination_id": dest_id,
			"locked":         locked,
		},
	)
	if not result.get("ok", false):
		set_status("ERROR: set_destination_locked failed — %s" % result.get("error", "unknown"))
		return

	# Sync the Reprocess button's disabled state immediately (UX — backend refuses
	# regardless, but this gives instant visual feedback).
	if reprocess_btn != null and is_instance_valid(reprocess_btn):
		reprocess_btn.disabled = locked
	set_status("Destination %s." % ("locked" if locked else "unlocked"))


# ---------------------------------------------------------------------------
# R3: Add Document flow
# ---------------------------------------------------------------------------

## Called when user picks "Add Document…" from the File menu.
func _on_add_document_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	# Show a document-picker FileDialog (separate from the vault picker).
	if _doc_file_dialog == null:
		_doc_file_dialog = FileDialog.new()
		_UiScale.apply_to(_doc_file_dialog)
		# Browse the real filesystem, not Godot's res:// resource view.
		_doc_file_dialog.access     = FileDialog.ACCESS_FILESYSTEM
		_doc_file_dialog.file_mode  = FileDialog.FILE_MODE_OPEN_FILE
		_doc_file_dialog.title      = "Add Document to Vault"
		_doc_file_dialog.file_selected.connect(_on_doc_file_selected)
		_doc_file_dialog.canceled.connect(_on_doc_file_dialog_cancelled)
		add_child(_doc_file_dialog)

	_doc_file_dialog.filters = PackedStringArray([
		"*.pdf *.txt *.csv *.md *.json *.xml *.html *.docx *.xlsx *.xls *.png *.jpg *.jpeg *.tiff *.bmp *.webp ; Supported Documents"
	])
	_doc_file_dialog.popup_centered(Vector2i(700, 500))


func _on_doc_file_selected(file_path: String) -> void:
	_ingest_pipeline(file_path)


func _on_doc_file_dialog_cancelled() -> void:
	pass  # Nothing to do — user cancelled before picking a file.


## Ingest pipeline: extract → dedup → classify → dialog → insert.
## All call_tool calls must be awaited.
func _ingest_pipeline(file_path: String) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	if not _vault_is_open:
		set_status("No vault open.")
		return

	# -- Step 1: Extract text + fingerprints --
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Extracting text…")

	var extract_res: Dictionary = await conn.call_tool(
		"minerva_scansort_extract_text",
		{"file_path": file_path}
	)
	# extract_text returns a FLAT dict with `success` (not `ok`).
	if not extract_res.get("success", false):
		_show_pipeline_error("Extraction failed: " + str(extract_res.get("error", "unknown")))
		return

	var sha256:    String = str(extract_res.get("sha256",   ""))
	var char_count: int   = int(extract_res.get("char_count", 0))
	var full_text: String = str(extract_res.get("full_text", ""))
	var simhash:   String = str(extract_res.get("simhash",  "0000000000000000"))
	var dhash:     String = str(extract_res.get("dhash",    "0000000000000000"))

	# -- Step 2: Dedup check (SHA-256 in current vault) --
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Checking for duplicates…")

	# check_sha256 returns {found: bool, doc_id: ...} — no `ok` wrapper.
	var dup_res: Dictionary = await conn.call_tool(
		"minerva_scansort_check_sha256",
		{"vault_path": _active_vault_path, "sha256": sha256}
	)
	if dup_res.get("found", false):
		_show_pipeline_info("This document is already in the vault.")
		if _status_panel != null and is_instance_valid(_status_panel):
			_status_panel.set_status("Idle")
		return

	# -- Step 3: Classify (text vs vision mode) --
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Classifying…")

	# R9: inherit model spec from chrome OptionButton; hardcoded max_chars.
	const MAX_CLASSIFY_CHARS := 4000
	var model_desc: Dictionary = _resolve_chat_model_for_classify()
	var model_spec: Dictionary = model_desc.get("model_spec", {}) as Dictionary if model_desc.get("model_spec") is Dictionary else {}
	var classify_args: Dictionary = {
		"vault_path": _active_vault_path,
		"model":      "default",
	}
	# Only attach spec when non-empty — broker rejects empty {} as "unknown kind".
	if not model_spec.is_empty():
		classify_args["model_spec"] = model_spec
	# Use password only if set (never log it). The ingest pipeline targets the
	# active vault, so look it up by _active_vault_path.
	var classify_pw: String = _vault_password_store.get_password(_active_vault_path)
	if not classify_pw.is_empty():
		classify_args["password"] = classify_pw

	const VISION_THRESHOLD := 50
	if char_count >= VISION_THRESHOLD:
		classify_args["mode"]          = "text"
		classify_args["document_text"] = full_text
		if MAX_CLASSIFY_CHARS > 0:
			classify_args["max_text_chars"] = MAX_CLASSIFY_CHARS
	else:
		# Vision mode — render pages first.
		var render_res: Dictionary = await conn.call_tool(
			"minerva_scansort_render_pages",
			{"file_path": file_path, "max_pages": 2, "dpi": 96}
		)
		# render_pages also returns a FLAT dict with `success`.
		if not render_res.get("success", false):
			_show_pipeline_error("Render failed: " + str(render_res.get("error", "unknown")))
			return
		classify_args["mode"]        = "vision"
		classify_args["page_images"] = render_res.get("pages", [])

	var classify_res: Dictionary = await conn.call_tool(
		"minerva_scansort_classify_document",
		classify_args
	)
	# classify_document returns {ok: true, classification: {...}} or {error: ...}.
	if not classify_res.get("ok", false):
		_show_pipeline_error("Classification failed: " + str(classify_res.get("error", "unknown")))
		if _status_panel != null and is_instance_valid(_status_panel):
			_status_panel.set_status("Idle")
		return

	var classification: Dictionary = classify_res.get("classification", {})

	# Augment classification with fingerprints + source info.
	classification["sha256"]      = sha256
	classification["simhash"]     = simhash
	classification["dhash"]       = dhash
	classification["source_file"] = file_path
	# Carry rule_snapshot through the dialog so the vault keeps a per-doc record
	# of the rule revision that produced this classification (vault v1.1.0+).
	classification["rule_snapshot"] = classify_res.get("rule_snapshot", "")

	# -- Step 4: Show dialog so user can review / edit --
	var dlg = _AddDocumentDialog.new()
	dlg.set_proposal(classification)
	add_child(dlg)
	dlg.accepted.connect(
		func(final: Dictionary) -> void:
			dlg.queue_free()
			_on_add_dialog_accepted(final, file_path, sha256, simhash, dhash)
	)
	dlg.cancelled.connect(
		func() -> void:
			dlg.queue_free()
			_on_add_dialog_cancelled()
	)
	dlg.popup_centered()

	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Waiting for user review…")


func _on_add_dialog_accepted(
		final: Dictionary,
		file_path: String,
		sha256: String,
		simhash: String,
		dhash: String) -> void:
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Storing in vault…")

	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var insert_args: Dictionary = {
		"vault_path":   _active_vault_path,
		"file_path":    file_path,
		"category":     final.get("category",    ""),
		"confidence":   float(final.get("confidence", 0.0)),
		"sender":       final.get("sender",      ""),
		"description":  final.get("description", ""),
		"doc_date":     final.get("doc_date",    ""),
		"status":       "classified",
		"sha256":       sha256,
		"simhash":      simhash,
		"dhash":        dhash,
		"source_path":  file_path,
		"rule_snapshot": str(final.get("rule_snapshot", "")),
	}
	# Pass password only if set. Ingest pipeline targets the active vault.
	var insert_pw: String = _vault_password_store.get_password(_active_vault_path)
	if not insert_pw.is_empty():
		insert_args["password"] = insert_pw

	var insert_res: Dictionary = await conn.call_tool(
		"minerva_scansort_insert_document",
		insert_args
	)
	# insert_document returns {ok: true, doc_id: N}.
	if not insert_res.get("ok", false):
		_show_pipeline_error("Insert failed: " + str(insert_res.get("error", "unknown")))
		return

	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Idle")
	set_status("Document added to vault.")

	# W5: refresh all destination trees so the new document shows up,
	# and re-scan the source pane so the just-ingested file shows its in-vault mark.
	await _refresh_all_dest_trees()
	if _source_tree != null and is_instance_valid(_source_tree):
		await _source_tree.refresh()


func _on_add_dialog_cancelled() -> void:
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Idle")
	set_status("Add document cancelled.")


## Called when the user clicks the "Process All" button in the chrome bar.
## C7 (DCR 019e564809a9): drives the new process_plan + process_run flow.
## process_plan enumerates files upfront and returns a stable batch_id;
## process_run(batch_id, limit=1) iterates one file at a time so the Stop
## button can interrupt between files via process_cancel(batch_id). The
## controller (C3) accumulates totals across iterations under the same
## batch_id — fixing bug 019e5802d5d8 (cycle-2's per-call reset).
func _on_process_all_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	if not _vault_is_open:
		set_status("No vault open.")
		return

	_process_cancelled = false

	# Enter running state: Process disabled, Stop ENABLED for the duration.
	if _process_btn != null and is_instance_valid(_process_btn):
		_process_btn.disabled = true
	if _extract_marked_menu != null and is_instance_valid(_extract_marked_menu):
		_extract_marked_menu.disabled = true
	if _stop_btn != null and is_instance_valid(_stop_btn):
		_stop_btn.disabled = false
	set_status("Processing…")

	# Model spec (Settings override → chat-panel inheritance) + audit settings.
	var model_desc: Dictionary = _resolve_chat_model_for_classify()
	var model_spec: Dictionary = model_desc.get("model_spec", {}) as Dictionary if model_desc.get("model_spec") is Dictionary else {}
	var audit_enabled: bool = _SettingsDialog.ScansortSettings.load_audit_log_enabled()
	var audit_path: String  = _SettingsDialog.ScansortSettings.load_audit_log_path()

	# Step 1 — process_plan. Enumerates files + installs batch in the
	# plugin's controller. Scope=all_sources processes every file under
	# every open source (the same set the cycle-2 process() walk used).
	var plan_args: Dictionary = {"scope": {"kind": "all_sources"}}
	var plan_result: Dictionary = await conn.call_tool("minerva_scansort_process_plan", plan_args)
	if not plan_result.get("ok", false):
		set_status("Plan failed: %s" % plan_result.get("error", "unknown"))
		_restore_buttons()
		return
	var batch_id: String = str(plan_result.get("batch_id", ""))
	var total: int = int(plan_result.get("total", 0))
	if total == 0:
		set_status("No source files to process.")
		_restore_buttons()
		return

	# Step 2 — per-file process_run loop. Stop button sets _process_cancelled
	# locally AND fires process_cancel(batch_id) so the plugin honours the
	# inter-file gate even if a process_run call is mid-flight.
	var moved: int         = 0
	var conflicts: int     = 0
	var unprocessable: int = 0
	var skipped: int       = 0
	var cancelled: bool    = false
	var failed_msg: String = ""

	var run_args_base: Dictionary = {"batch_id": batch_id, "limit": 1}
	if not model_spec.is_empty():
		run_args_base["model_spec"] = model_spec
	if audit_enabled and not audit_path.is_empty():
		run_args_base["audit_enabled"] = true
		run_args_base["audit_path"] = audit_path

	for i in range(total):
		if _process_cancelled:
			cancelled = true
			# Tell the plugin too so a mid-flight process_run bails at its gate.
			await conn.call_tool("minerva_scansort_process_cancel", {"batch_id": batch_id})
			break

		var run_result: Dictionary = await conn.call_tool("minerva_scansort_process_run", run_args_base)
		if not run_result.get("ok", false):
			failed_msg = "process_run failed at file %d/%d: %s" % [i + 1, total, run_result.get("error", "unknown")]
			break

		# Snapshot returned by process_run carries the accumulated batch
		# totals — read directly, don't sum per-iteration as cycle-2 did.
		var snapshot: Dictionary = run_result.get("snapshot", {}) as Dictionary
		var totals: Dictionary = snapshot.get("totals", {}) as Dictionary
		moved         = int(totals.get("placed", 0))
		skipped       = int(totals.get("skipped", 0))
		# Plugin lumps placement errors + conflicts into errored; expose
		# the combined number for now (G13 column gives provenance).
		unprocessable = int(totals.get("errored", 0))
		conflicts     = 0
		set_status("Processing %d/%d…" % [int(totals.get("total", 0)), total])

		# If the plugin already reports terminal state (drained or
		# cancelled mid-file), exit the loop cleanly.
		var st: String = str(snapshot.get("state", ""))
		if st == "completed" or st == "cancelled" or st == "errored":
			if st == "cancelled":
				cancelled = true
			break

	_restore_buttons()

	# Refresh trees so placed documents + processed-state marks show.
	await _refresh_all_dest_trees()
	if _source_tree != null and is_instance_valid(_source_tree):
		await _source_tree.refresh()

	if not failed_msg.is_empty():
		set_status(failed_msg)
		return

	var verb: String = "Stopped after" if cancelled else "Processed"
	# C7: per-rule + per-destination tallies are still available via
	# process_status's snapshot but we no longer accumulate them client-side
	# (the controller tracks per-disposition totals; the per-rule histogram
	# would require a process_status fetch after each iteration — heavier
	# than the cycle-2 by-call summing, and the user-visible status line
	# already carries the headline numbers).
	set_status(
		"%s %d/%d — %d moved, %d unprocessable, %d already-done" % [
			verb, (moved + skipped + unprocessable), total, moved, unprocessable, skipped
		]
	)


## Restore "Process" + "Stop" + extract-marked menu buttons to their idle
## states. Called on every exit path from _on_process_all_pressed so the
## Stop button never sticks ENABLED after the batch finishes.
func _restore_buttons() -> void:
	if _process_btn != null and is_instance_valid(_process_btn):
		_process_btn.disabled = not _vault_is_open
	if _extract_marked_menu != null and is_instance_valid(_extract_marked_menu):
		_extract_marked_menu.disabled = not _vault_is_open
	if _stop_btn != null and is_instance_valid(_stop_btn):
		_stop_btn.disabled = true


## Stop button — sets the local cancel flag AND (in the running batch)
## fires process_cancel(batch_id) so the plugin's inter-file gate bails
## even if a process_run call is mid-flight. The current file finishes
## (bounded by the per-file MCP timeout); the batch halts after it.
func _on_stop_pressed() -> void:
	_process_cancelled = true
	if _stop_btn != null and is_instance_valid(_stop_btn):
		_stop_btn.disabled = true
	set_status("Stopping…")


## Clear session state (processed + low-confidence sets) and refresh the
## source tree so ✓ marks are removed. Public — U6 may expose a UI trigger.
func clear_processed_state() -> void:
	_processed_keys.clear()
	_low_confidence_keys.clear()
	_push_session_marks_to_provider()
	if _source_tree != null and is_instance_valid(_source_tree):
		await _source_tree.refresh()


## Push the current session mark sets into the source provider so the next
## refresh() reflects up-to-date ✓ marks without a full list_source_files
## round-trip.
func _push_session_marks_to_provider() -> void:
	if _source_provider != null and _source_provider.has_method("set_session_marks"):
		_source_provider.set_session_marks(_processed_keys, _low_confidence_keys)


## Show a non-blocking error in the status bar / status panel.
## Toolbar carries the error message; pipeline-state panel returns to Idle so
## subsequent runs aren't gated on the user noticing the stale label.
func _show_pipeline_error(msg: String) -> void:
	set_status("ERROR: " + msg)
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status("Idle")
	push_warning("[ScansortPanel] pipeline error: " + msg)


## Show a non-blocking info message.
func _show_pipeline_info(msg: String) -> void:
	set_status(msg)
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status(msg)


# ---------------------------------------------------------------------------
# R4: Edit Document flow
# ---------------------------------------------------------------------------

## Edit Document flow. Currently unwired after the U4 layout rewrite — the
## old trigger (vault_view's edit_details_requested) is gone; a right-click
## re-entry point is Tier-2 work. Kept intact so that re-wiring is trivial.
## Fetches the full document, loads rules for the category dropdown, then
## shows EditDetailsDialog. On accept, calls update_document and refreshes.
func _on_edit_doc_pressed(doc_id: int) -> void:
	if not _vault_is_open:
		set_status("No vault open.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	# Fetch current document metadata from the active vault.
	var doc_args: Dictionary = {"vault_path": _active_vault_path, "doc_id": doc_id}
	var doc_pw: String = _vault_password_store.get_password(_active_vault_path)
	if not doc_pw.is_empty():
		doc_args["password"] = doc_pw

	var doc_result: Dictionary = await conn.call_tool("minerva_scansort_get_document", doc_args)
	if not doc_result.get("ok", false):
		set_status("ERROR: get_document failed — %s" % doc_result.get("error", "unknown"))
		return

	var doc: Dictionary = doc_result.get("document", {})

	# W12 (DCR 019e33bf): fetch rules for the category dropdown from the
	# global library rather than the deprecated path-driven list_rules tool.
	# The library tool is session/path-free and is the canonical surface
	# after the path-free DCR (019e2cc988ec, superseded by 019e33bf).
	var rules_result: Dictionary = await conn.call_tool("minerva_scansort_library_list_rules", {})
	var rules: Array = []
	if rules_result.get("ok", false):
		rules = rules_result.get("rules", [])

	# Show the dialog.
	var dlg = _EditDetailsDialog.new()
	dlg.set_document(doc, rules)
	add_child(dlg)
	dlg.accepted.connect(
		func(updated_fields: Dictionary) -> void:
			dlg.queue_free()
			_on_edit_dialog_accepted(doc_id, updated_fields)
	)
	dlg.cancelled.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered()


func _on_edit_dialog_accepted(doc_id: int, updated_fields: Dictionary) -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var upd_args: Dictionary = {
		"vault_path": _active_vault_path,
		"doc_id":     doc_id,
	}
	# Merge updated fields into the call args.
	for k: String in updated_fields:
		upd_args[k] = updated_fields[k]
	var upd_pw: String = _vault_password_store.get_password(_active_vault_path)
	if not upd_pw.is_empty():
		upd_args["password"] = upd_pw

	var upd_result: Dictionary = await conn.call_tool("minerva_scansort_update_document", upd_args)
	if not upd_result.get("ok", false):
		set_status("ERROR: update_document failed — %s" % upd_result.get("error", "unknown"))
		return

	set_status("Document updated.")
	# W5: refresh all destination trees so updated metadata is visible.
	await _refresh_all_dest_trees()


# ---------------------------------------------------------------------------
# R4: Rules Editor flow
# ---------------------------------------------------------------------------

## Sibling rules path for the currently-open vault.
## /a/b/foo.ssort → /a/b/foo.rules.json. Empty if no vault is open.
func _vault_rules_path() -> String:
	if _active_vault_path.is_empty():
		return ""
	var base_dir: String = _active_vault_path.get_base_dir()
	var stem: String     = _active_vault_path.get_file().get_basename()
	return "%s/%s.rules.json" % [base_dir, stem]


## User-level library rules path. Lives in the Minerva per-user data dir so
## it survives across vaults and across project tree moves.
func _library_rules_path() -> String:
	return OS.get_user_data_dir() + "/scansort_rules.json"


## Machine-local destination registry path.  This is intentionally not stored
## next to a vault: directories can be configured before any vault is open.
func _default_destination_registry_path() -> String:
	var env_path: String = OS.get_environment("SCANSORT_DESTINATION_REGISTRY")
	if env_path.is_empty():
		env_path = OS.get_environment("SCANSORT_DEST_REGISTRY")
	if not env_path.is_empty():
		return env_path

	var user_dir: String = OS.get_user_data_dir()
	if not user_dir.is_empty():
		return user_dir.path_join(DESTINATION_REGISTRY_FILENAME)

	var home_dir: String = OS.get_environment("HOME")
	if not home_dir.is_empty():
		return home_dir.path_join(".config").path_join("scansort").path_join(DESTINATION_REGISTRY_FILENAME)
	return "/tmp/%s" % DESTINATION_REGISTRY_FILENAME


func _ensure_destination_registry_path() -> bool:
	if _registry_path.is_empty():
		_registry_path = _default_destination_registry_path()
	return not _registry_path.is_empty()


## Called when user picks "Rules…" from the File menu (id 4).
## Opens the library-only Classification Rules dialog (DCR 019e33bf — no per-vault sidecars).
func _on_rules_editor_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var dlg = _RulesEditorDialog.new()
	add_child(dlg)
	dlg.init(conn)
	dlg.rules_changed.connect(
		func() -> void:
			pass  # panel has no cached rules list to invalidate
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(1000, 700))


# ---------------------------------------------------------------------------
# R5: Vault Registry flow
# ---------------------------------------------------------------------------

## Called when user picks "Vault Registry…" from the File menu.
func _on_vault_registry_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var dlg = _VaultRegistryDialog.new()
	add_child(dlg)
	dlg.init(conn)
	dlg.vault_picked.connect(
		func(picked_path: String, _picked_name: String) -> void:
			# User double-clicked a vault entry — switch to it.
			# Close the current vault first (if any), then begin open flow.
			if _vault_is_open:
				_on_close_vault_pressed()
			_file_dialog_mode = "open"
			_begin_open_vault(picked_path)
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(600, 400))


# ---------------------------------------------------------------------------
# R8: Chat model inheritance
# ---------------------------------------------------------------------------

## R9: Resolve the model spec to use for classify_document calls.
## Returns {model_spec: Dictionary} — reads from the chrome OptionButton
## Resolves the classification model spec.
##
## Precedence:
##   1. Per-plugin user override stored in scansort_settings.json (set via
##      the Settings dialog). Travels across vaults.
##   2. Chat panel's currently-selected model (inherit mode — the default).
##
## Returns {"model_spec": Dictionary} — empty Dict when neither layer
## supplies a spec (headless tests / no chat / inherit + chat unset). The
## caller's classify call site drops empty specs from args (broker rejects
## empty {} as "unknown kind").
func _resolve_chat_model_for_classify() -> Dictionary:
	# Layer 1: per-plugin override.
	var override: Dictionary = _SettingsDialog.ScansortSettings.load_model_override()
	if not override.is_empty():
		return {"model_spec": override}

	# Layer 2: inherit chat panel's current selection.
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() != null else null
	if so == null:
		return {"model_spec": {}}
	var chats = so.get("Chats") if "Chats" in so else null
	if chats == null or not chats.has_method("get_active_model_spec"):
		return {"model_spec": {}}
	var spec = chats.get_active_model_spec()
	var dict_spec: Dictionary = spec as Dictionary if spec is Dictionary else {}
	return {"model_spec": dict_spec}


## Called when user picks "Settings…" from the File menu (id 11).
## Always available — settings are user-level, not vault-gated.
func _on_settings_pressed() -> void:
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	var dlg = _SettingsDialog.new()
	add_child(dlg)
	dlg.init(conn, _active_vault_path)
	dlg.settings_changed.connect(
		func() -> void:
			set_status("Scansort settings saved.")
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(580, 420))


## Called when user picks "Recovery Sheet…" from the File menu.
func _on_recovery_sheet_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var dlg = _RecoverySheetDialog.new()
	add_child(dlg)
	dlg.init(conn, _active_vault_path, _vault_password_store.get_password(_active_vault_path))
	dlg.recovery_changed.connect(
		func() -> void:
			set_status("Recovery sheet metadata saved.")
	)
	dlg.closed.connect(
		func() -> void:
			dlg.queue_free()
	)
	dlg.popup_centered(Vector2i(660, 560))


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

## Return the scansort PluginConnection, or null if unavailable.
func _get_connection() -> Object:
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so == null:
		push_error("[ScansortPanel] SingletonObject not found")
		return null
	var pm = so.get("plugin_manager") if "plugin_manager" in so else null
	if pm == null:
		push_error("[ScansortPanel] SingletonObject.plugin_manager not found")
		return null
	var conn = pm.get_connection("scansort")
	if conn == null:
		push_warning("[ScansortPanel] scansort plugin not running — start it first")
	return conn


## Editor actions API — returns Controls to insert into the editor chrome bar.
## Called by Editor._apply_plugin_chrome_actions() after the panel is mounted.
## Returns a fresh MenuButton each call; the editor owns and frees it on teardown.
func get_editor_actions() -> Array:
	# Process All / Stop — contributed to the chrome bar, left of the File menu.
	# Disabled placeholders until U5 wires the batch pipeline. Icons match the
	# chat panel's submit / stop buttons; style matches the File MenuButton
	# (flat = false, icon-only + tooltip).
	_process_btn = Button.new()
	_process_btn.flat = false
	_process_btn.icon = load("res://assets/icons/send_icons/send_icon_24_no_bg.png")
	_process_btn.tooltip_text = "Process All — extract, classify and file every source document."
	_process_btn.disabled = not _vault_is_open
	_process_btn.pressed.connect(_on_process_all_pressed)
	_stop_btn = Button.new()
	_stop_btn.flat = false
	_stop_btn.icon = load("res://assets/icons/stop_icons/stop-sign-24.png")
	_stop_btn.tooltip_text = "Stop the running batch."
	_stop_btn.disabled = true
	_stop_btn.pressed.connect(_on_stop_pressed)

	var menu := MenuButton.new()
	# Reuse Minerva's drawer icon for the File menu; tooltip explains it.
	var icon: Texture2D = load("res://assets/icons/drawer.png")
	if icon != null:
		menu.icon = icon
	else:
		menu.text = "File"
	menu.tooltip_text = "Scansort File menu"
	menu.flat = false
	var popup := menu.get_popup()
	popup.add_item("New Vault...", 0)
	popup.add_item("Open Vault...", 1)
	popup.add_separator()
	popup.add_item("Add Document...", 3)
	popup.add_item("Rules...", 4)
	popup.add_separator()
	popup.add_item("Vault Registry...", 5)
	popup.add_separator()
	popup.add_item("Settings...", 11)
	popup.add_separator()
	popup.add_item("Extract Marked To...", 12)
	popup.add_item("Recovery Sheet...", 13)
	popup.add_separator()
	# DCR 019e3d67: File→Close drops the entire session (vault + source + dirs)
	# back to an initialized state in-memory. Disk side-effects: none.
	popup.add_item("Close", 2)
	# DCR 019e41a5: File→Clear Cache wipes the .scansort-state.json source
	# manifests so the next Start re-processes from scratch. Source-gated.
	popup.add_item("Clear Cache", 8)
	popup.id_pressed.connect(_on_file_menu_id_pressed)
	# Cache the popup so vault state changes can grey out gated items.
	_chrome_popup = popup
	_refresh_chrome_menu_state()

	# Scansort inherits the chat panel's model selection at classify time via
	# _resolve_chat_model_for_classify() → ChatPane.get_active_model_spec().
	# No per-panel model picker.
	# Process | Stop | File — buttons land left of the File menu in the chrome.
	return [_process_btn, _stop_btn, menu]


## Disable File-menu items that require an open vault when no vault is open.
## Always enabled: New Vault (0), Open Vault (1), Close (2 — DCR 019e3d67:
## now session-wide and a no-op on an empty session), Rules… (4),
## Vault Registry (5).
## Vault-gated: Add Document (3), Extract Marked (12), Recovery Sheet (13).
## Source-gated: Clear Cache (8 — DCR 019e41a5: needs ≥1 open source).
func _refresh_chrome_menu_state() -> void:
	if _chrome_popup == null or not is_instance_valid(_chrome_popup):
		return
	var vault_gated: Array[int] = [3, 7, 12, 13]
	for item_id in vault_gated:
		var idx: int = _chrome_popup.get_item_index(item_id)
		if idx >= 0:
			_chrome_popup.set_item_disabled(idx, not _vault_is_open)
	# DCR 019e41a5: Clear Cache enabled iff a source is open. Panel tracks
	# one source label (multi-source is broker-only); empty string = no source.
	var clear_cache_idx: int = _chrome_popup.get_item_index(8)
	if clear_cache_idx >= 0:
		_chrome_popup.set_item_disabled(clear_cache_idx, _session_source_label.is_empty())
	# U5: enable Process All when a vault is open (and no run is in progress).
	if _process_btn != null and is_instance_valid(_process_btn):
		_process_btn.disabled = not _vault_is_open
	if _extract_marked_menu != null and is_instance_valid(_extract_marked_menu):
		_extract_marked_menu.disabled = not _vault_is_open


# ---------------------------------------------------------------------------
# U6: drag-to-classify / drag-to-reclassify
# ---------------------------------------------------------------------------

## Handles drops from any tree onto a destination folder row.
## W5: dest_context is the destination dict for the tree that received the drop
##     (may be empty if called from a non-registry path, though that no longer
##     occurs with the new wiring).
## drag_data.role == "source"  → classify source file into target category.
## drag_data.role starts with "dest:"  → reclassify within that destination.
func _on_tree_file_dropped(drag_data: Dictionary, target_key: String, _target_kind: String, dest_context: Dictionary = {}) -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	# Determine which vault to use: prefer dest_context's vault path (for vault
	# destinations), fall back to the open vault.
	var dest_kind: String    = str(dest_context.get("kind", ""))
	var dest_vault: String   = _active_vault_path
	if dest_kind == "vault":
		dest_vault = str(dest_context.get("path", _active_vault_path))

	var category: String = target_key.substr(4)  # strip "cat:" prefix
	var role: String     = str(drag_data.get("role", ""))
	var drag_key: String = str(drag_data.get("key", ""))

	if role == "source":
		# Drag-to-classify: source file path → insert with user-assigned category.
		var fname: String = drag_key.get_file()

		# Extract text + fingerprints.
		var extract_res: Dictionary = await conn.call_tool(
			"minerva_scansort_extract_text",
			{"file_path": drag_key}
		)
		if not extract_res.get("success", false):
			set_status("ERROR: extraction failed — %s" % str(extract_res.get("error", "unknown")))
			return

		var sha256:  String = str(extract_res.get("sha256",  ""))
		var simhash: String = str(extract_res.get("simhash", "0000000000000000"))
		var dhash:   String = str(extract_res.get("dhash",   "0000000000000000"))

		# Dedup check against the target destination vault.
		var dup_res: Dictionary = await conn.call_tool(
			"minerva_scansort_check_sha256",
			{"vault_path": dest_vault, "sha256": sha256}
		)
		if dup_res.get("found", false):
			set_status("Already in vault.")
			return

		# Insert with user-assigned category (no AI classify step).
		var insert_args: Dictionary = {
			"vault_path":    dest_vault,
			"file_path":     drag_key,
			"category":      category,
			"confidence":    1.0,
			"sender":        "",
			"description":   "",
			"doc_date":      "",
			"status":        "classified",
			"sha256":        sha256,
			"simhash":       simhash,
			"dhash":         dhash,
			"source_path":   drag_key,
			"rule_snapshot": "",
		}
		var dest_insert_pw: String = _vault_password_store.get_password(dest_vault)
		if not dest_insert_pw.is_empty():
			insert_args["password"] = dest_insert_pw

		var insert_res: Dictionary = await conn.call_tool(
			"minerva_scansort_insert_document",
			insert_args
		)
		if not insert_res.get("ok", false):
			set_status("ERROR: insert failed — %s" % str(insert_res.get("error", "unknown")))
			return

		set_status("Filed %s → %s" % [fname, category])
		# W5: refresh all destination trees + source.
		await _refresh_all_dest_trees()
		if _source_tree != null and is_instance_valid(_source_tree):
			await _source_tree.refresh()

	elif role == "vault" or role.begins_with("dest:"):
		# Drag-to-reclassify: doc:<id> → update category in the destination vault.
		var doc_id: int = int(drag_key.substr(4))  # strip "doc:" prefix
		var upd_args: Dictionary = {
			"vault_path": dest_vault,
			"doc_id":     doc_id,
			"category":   category,
		}
		var dest_upd_pw: String = _vault_password_store.get_password(dest_vault)
		if not dest_upd_pw.is_empty():
			upd_args["password"] = dest_upd_pw

		var upd_res: Dictionary = await conn.call_tool(
			"minerva_scansort_update_document",
			upd_args
		)
		if not upd_res.get("ok", false):
			set_status("ERROR: reclassify failed — %s" % str(upd_res.get("error", "unknown")))
			return

		set_status("Reclassified → %s" % category)
		# W5: refresh all destination trees.
		await _refresh_all_dest_trees()


# ---------------------------------------------------------------------------
# U6: Extract vault documents to directory destinations
# ---------------------------------------------------------------------------

func _directory_destinations() -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	if _dir_area_provider != null and "last_destinations" in _dir_area_provider:
		for d: Dictionary in _dir_area_provider.get("last_destinations"):
			if str(d.get("kind", "")) != "directory":
				continue
			var id_key: String = str(d.get("id", d.get("path", "")))
			if id_key.is_empty() or seen.has(id_key):
				continue
			seen[id_key] = true
			result.append(d)
	for d: Dictionary in _dest_registry:
		if str(d.get("kind", "")) != "directory":
			continue
		var id_key: String = str(d.get("id", d.get("path", "")))
		if id_key.is_empty() or seen.has(id_key):
			continue
		seen[id_key] = true
		result.append(d)
	return result


func _get_checked_vault_doc_keys() -> Array:
	var keys: Array = []
	if _vault_area_tree == null or not is_instance_valid(_vault_area_tree):
		return keys
	for k: String in _vault_area_tree.get_checked_keys():
		if k.begins_with("doc:"):
			keys.append(k)
	return keys


func _count_encrypted_doc_keys(keys: Array) -> int:
	var count := 0
	for key: String in keys:
		var item: TreeItem = _find_item_by_key(_vault_area_tree, key) if _vault_area_tree != null else null
		if item != null and bool(item.get_meta("encrypted", false)):
			count += 1
	return count


func _populate_extract_marked_popup() -> void:
	if _extract_marked_menu == null or not is_instance_valid(_extract_marked_menu):
		return
	var popup: PopupMenu = _extract_marked_menu.get_popup()
	popup.clear()
	var keys: Array = _get_checked_vault_doc_keys()
	var dirs: Array = _directory_destinations()
	if keys.is_empty():
		popup.add_item("No vault documents marked", -1)
		popup.set_item_disabled(0, true)
		return
	if dirs.is_empty():
		popup.add_item("Add a directory destination first", 900)
		return
	for i in range(dirs.size()):
		var dest: Dictionary = dirs[i]
		var label: String = str(dest.get("label", dest.get("path", "Directory")))
		var path: String = str(dest.get("path", ""))
		popup.add_item("%s  [%s]" % [label, path], 1000 + i)
		popup.set_item_metadata(popup.item_count - 1, dest)
	popup.add_separator()
	popup.add_item("Add Directory Destination...", 900)


func _on_extract_marked_menu_id_pressed(id: int) -> void:
	if id == 900:
		_on_dest_add_for_kind("directory")
		return
	if id < 1000:
		return
	var idx := id - 1000
	var dirs: Array = _directory_destinations()
	if idx < 0 or idx >= dirs.size():
		return
	var dest: Dictionary = dirs[idx]
	var path: String = str(dest.get("path", ""))
	var label: String = str(dest.get("label", path.get_file()))
	await _extract_checked_to_directory(path, label)


func _extract_checked_to_directory(dest_path: String, dest_label: String) -> void:
	var keys: Array = _get_checked_vault_doc_keys()
	if keys.is_empty():
		set_status("No documents marked for extraction.")
		return
	await _extract_doc_keys_to_directory(keys, dest_path, dest_label)


## W5i: Extracts checked vault documents to a registered directory destination.
## If invoked from the File menu and multiple directory destinations exist, the
## modal picker lists only those destinations; it no longer browses arbitrary paths.
func _on_export_marked_pressed() -> void:
	if not _vault_is_open:
		set_status("Open a vault first.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return
	var keys: Array = _get_checked_vault_doc_keys()
	if keys.is_empty():
		set_status("No documents marked for extraction.")
		return

	var dir_dests: Array = _directory_destinations()
	if dir_dests.is_empty():
		set_status("Add a directory destination before extracting.")
		return
	if dir_dests.size() == 1:
		var only: Dictionary = dir_dests[0]
		await _extract_doc_keys_to_directory(keys, str(only.get("path", "")), str(only.get("label", only.get("path", "Directory"))))
		return

	var dlg: AcceptDialog = _ExtractTargetDialog.new()
	(dlg as Object).call("set_destinations", dir_dests)
	add_child(dlg)

	var chosen_path: String = ""
	var got_choice: bool = false

	(dlg as Object).target_chosen.connect(func(p: String) -> void:
		chosen_path = p
		got_choice  = true
	)
	(dlg as Object).cancelled.connect(func() -> void:
		got_choice = true  # signal received, path stays empty
	)

	dlg.popup_centered(Vector2i(500, 320))

	# Wait until the dialog emits one of its signals.
	while not got_choice:
		await Engine.get_main_loop().process_frame

	if is_instance_valid(dlg):
		dlg.queue_free()

	if chosen_path.is_empty():
		return  # user cancelled

	await _extract_doc_keys_to_directory(keys, chosen_path, chosen_path.get_file())


func _extract_doc_keys_to_directory(keys: Array, chosen_path: String, dest_label: String) -> void:
	if chosen_path.is_empty():
		set_status("Cannot extract: target directory is empty.")
		return
	var conn = _get_connection()
	if conn == null:
		set_status("ERROR: scansort plugin not running.")
		return

	var encrypted_count: int = _count_encrypted_doc_keys(keys)
	# RCA 019e4ca264: keys may span multiple vaults. Block only when an
	# encrypted document belongs to a vault with no recorded password.
	if encrypted_count > 0:
		for key: String in keys:
			var item: TreeItem = _find_item_by_key(_vault_area_tree, key) if _vault_area_tree != null else null
			if item == null or not bool(item.get_meta("encrypted", false)):
				continue
			var ev_path: String = _find_vault_path_for_doc_key(key)
			if ev_path.is_empty():
				ev_path = _active_vault_path
			if _vault_password_store.get_password(ev_path).is_empty():
				set_status("Unlock the vault before extracting encrypted documents.")
				return
	set_status("Extracting %d document(s)%s to %s..." % [
		keys.size(),
		" (%d encrypted)" % encrypted_count if encrypted_count > 0 else "",
		dest_label if not dest_label.is_empty() else chosen_path,
	])

	var extracted: int = 0
	var failed: int    = 0

	for key: String in keys:
		var doc_id: int = int(key.substr(4))
		var vault_path: String = _find_vault_path_for_doc_key(key)
		if vault_path.is_empty():
			vault_path = _active_vault_path
		if vault_path.is_empty():
			push_warning("[ScansortPanel] extract_marked: no vault_path for key %s" % key)
			failed += 1
			continue

		var extract_args: Dictionary = {
			"vault_path": vault_path,
			"doc_id":     doc_id,
			"dest":       chosen_path,
		}
		var marked_pw: String = _vault_password_store.get_password(vault_path)
		if not marked_pw.is_empty():
			extract_args["password"] = marked_pw

		var result: Dictionary = await conn.call_tool(
			"minerva_scansort_extract_document",
			extract_args
		)
		if not result.get("ok", false):
			var err: String = str(result.get("error", "unknown"))
			push_warning("[ScansortPanel] extract_marked: doc_id %d failed — %s" % [doc_id, err])
			failed += 1
		else:
			extracted += 1

	set_status("Extracted %d, %d failed" % [extracted, failed])
	if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
		await _dir_area_tree.refresh()


# ---------------------------------------------------------------------------
# U6: inject-to-chat
# ---------------------------------------------------------------------------

## Called when source-pane checkboxes change.
## Rebuilds _inject_payload_cache from the extracted text of all checked files.
## Async — each file may require an MCP round-trip.
func _on_source_check_toggled() -> void:
	var conn = _get_connection()
	if conn == null:
		_inject_payload_cache = ""
		return

	var keys: Array = _source_tree.get_checked_keys() if _source_tree != null and is_instance_valid(_source_tree) else []
	if keys.is_empty():
		_inject_payload_cache = ""
		return

	const MAX_FILE_CHARS := 20000
	var blob: String = ""

	for file_path: String in keys:
		var extract_res: Dictionary = await conn.call_tool(
			"minerva_scansort_extract_text",
			{"file_path": file_path}
		)
		if not extract_res.get("success", false):
			continue
		var text: String = str(extract_res.get("full_text", ""))
		if text.length() > MAX_FILE_CHARS:
			text = text.substr(0, MAX_FILE_CHARS) + "\n…[truncated]"
		blob += "=== %s ===\n%s\n\n" % [file_path.get_file(), text]

	_inject_payload_cache = blob


## Platform hook: called when the user toggles the inject-to-chat switch.
## If enabled but no source files are checked yet, nudges the user.
func _on_panel_inject_toggle_changed(enabled: bool) -> void:
	_inject_enabled = enabled
	if enabled and _inject_payload_cache.is_empty():
		set_status("Inject to Chat: check source files first.")


## Platform hook: called synchronously when a note is requested for chat injection.
## MUST NOT use await — PluginScenePanelHost.invoke_create_note does not await it.
## Returns null when no cache is ready (platform falls back to a screenshot).
## Returns a text-kind payload dict that Editor._build_note_from_plugin_payload
## recognises when the cache is populated.
func _on_panel_create_note_request(_ctx: Dictionary) -> Variant:
	if _inject_payload_cache.is_empty():
		return null
	return {
		"kind":    "text",
		"title":   "Scansort source files",
		"content": _inject_payload_cache,
	}


func set_status(text: String) -> void:
	# R7: _status_label removed (toolbar gone). Route status to the bottom panel.
	if _status_panel != null and is_instance_valid(_status_panel):
		_status_panel.set_status(text)


## True if a vault is currently open.
func has_open_vault() -> bool:
	return _vault_is_open


## Returns the absolute path of the open vault, or "" if none.
func get_active_vault_path() -> String:
	return _active_vault_path


# ---------------------------------------------------------------------------
# Broker progress subscription (visibility for plugin-driven chat calls)
# ---------------------------------------------------------------------------

var _broker_chat_count: int = 0
var _broker_chat_last_ms: int = 0

func _subscribe_broker_progress() -> void:
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() else null
	if so == null:
		return
	var broker = so.get("plugin_capability_broker") if "plugin_capability_broker" in so else null
	if broker == null:
		return
	if broker.has_signal("plugin_chat_invoked"):
		broker.plugin_chat_invoked.connect(_on_broker_chat_invoked)
	if broker.has_signal("plugin_chat_completed"):
		broker.plugin_chat_completed.connect(_on_broker_chat_completed)

func _on_broker_chat_invoked(plugin_id: String, _provider_name: String, _model_name: String) -> void:
	if plugin_id != "scansort":
		return
	# Counters retained for debugging; status text is now driven by the
	# per-file kind=document event stream so "Processing <file>" stays
	# stable across the chat call instead of flickering "Classifying — call #N".
	_broker_chat_count += 1

func _on_broker_chat_completed(plugin_id: String, _provider_name: String, _model_name: String, duration_ms: int, _ok: bool, _tokens_in: int, _tokens_out: int, _error: String) -> void:
	if plugin_id != "scansort":
		return
	_broker_chat_last_ms = duration_ms


## Subscribe to PluginEventBroker so MCP-driven mutations (set_source_dir,
## destination_add, library rule changes, …) refresh the panel in lockstep.
## The plugin's main.rs emits a JSON-RPC `minerva/plugin_event` notification
## after every successful mutating tools/call; the broker translates that
## into the `plugin_event` signal on `SingletonObject.plugin_event_broker`.
func _subscribe_plugin_events() -> void:
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject") if Engine.get_main_loop() else null
	if so == null:
		return
	var event_broker = so.get("plugin_event_broker") if "plugin_event_broker" in so else null
	if event_broker == null:
		return
	if event_broker.has_signal("plugin_event") and not event_broker.plugin_event.is_connected(_on_plugin_event):
		event_broker.plugin_event.connect(_on_plugin_event)


## Route scansort `state_changed` events to the matching refresh routine.
## Other plugins' events and non-state-changed events are ignored. Refresh
## paths are idempotent — re-firing them on a panel-originated mutation
## just re-reads the same state and is harmless.
func _on_plugin_event(p_id: String, event_name: String, payload: Dictionary) -> void:
	if p_id != "scansort" or event_name != "state_changed":
		return
	var kind: String = str(payload.get("kind", ""))
	# Append a debug marker to /tmp/scansort-debug.log so the autonomous test
	# loop can confirm signal reception independent of whether the matching
	# refresh actually rendered. instance_id distinguishes events in a
	# multi-panel scenario (Option A — every panel still receives; this
	# confirms the multi-subscribe works).
	var f := FileAccess.open("/tmp/scansort-debug.log", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("/tmp/scansort-debug.log", FileAccess.WRITE)
	if f != null:
		f.seek_end()
		var ts: int = int(Time.get_unix_time_from_system() * 1000.0)
		f.store_line("%d [panel:%d] recv state_changed kind=%s" % [ts, get_instance_id(), kind])
		f.close()
	match kind:
		"source":
			# Source dir changed → invalidate per-file progress; old rel_paths
			# no longer apply to the new source.
			_doc_progress.clear()
			_push_doc_progress_to_source_provider()
			_refresh_source_tree_if_ready()
		"destination", "registry", "vault":
			_refresh_all_dest_trees_if_ready()
		"document":
			# Per-file progress event: payload carries file_path + status (+ target/reason).
			# Update local map, mirror in-flight file to bottom status bar, push to
			# source provider, refresh BOTH dest and source trees.
			var file_path: String = str(payload.get("file_path", ""))
			if not file_path.is_empty():
				var status_str: String = str(payload.get("status", ""))
				var entry: Dictionary = { "status": status_str }
				if payload.has("target"):
					entry["target"] = str(payload.get("target", ""))
				if payload.has("reason"):
					entry["reason"] = str(payload.get("reason", ""))
				_doc_progress[file_path] = entry
				# Bottom status bar: show "Processing <file>" during classify and
				# leave it on that filename across the per-file terminal events
				# so the bar stays stable until the NEXT file's classifying
				# event arrives. Errors override with "Error processing <file>:
				# <reason>" so the user notices failures.
				if _status_panel != null and is_instance_valid(_status_panel):
					if status_str == "classifying":
						_status_panel.set_status("Processing %s" % file_path)
					elif status_str == "unprocessable":
						var rsn: String = str(payload.get("reason", "unknown"))
						_status_panel.set_status("Error processing %s: %s" % [file_path, rsn])
					# "moved" / "conflict" → leave the bar on the previous
					# "Processing <file>" text; it'll be replaced by the next
					# file's classifying event or by an error.
				_push_doc_progress_to_source_provider()
				_refresh_source_tree_if_ready()
			_refresh_all_dest_trees_if_ready()
		"library_rule":
			# Rules editor is modal; nothing to refresh on the main pane today.
			# Kept as an explicit no-op so future rules-pane work has a hook.
			pass
		"session":
			# kind=session is no longer emitted by the plugin after W0 changes;
			# kept as a harmless explicit no-op for safety.
			pass
		_:
			# Unknown kinds (document, rule) — no panel surface.
			pass


## Silence the base MinervaPluginPanel.receive() warning for state_changed
## events. The actual handling is done via the direct plugin_event signal
## subscription in _on_plugin_event — we don't need (or want) the implicit
## push_to_panel path for these, because it only routes to the last-registered
## panel instance, which would break multi-panel observability.
func receive(channel: String, payload: Dictionary) -> void:
	if channel == "state_changed":
		return  # handled via direct signal subscription
	super(channel, payload)


## Push _doc_progress into the source provider so the next refresh renders
## per-file status badges. No-op when the provider isn't initialized yet.
func _push_doc_progress_to_source_provider() -> void:
	if _source_provider == null:
		return
	if _source_provider.has_method("set_doc_progress"):
		_source_provider.set_doc_progress(_doc_progress)


## Idempotent guarded refresh for the source tree. Works even with no vault
## open — the source dir is process-global plugin state, not vault-scoped.
## Bails only when the source tree node has been freed (panel teardown race)
## OR the plugin connection isn't available yet.
func _refresh_source_tree_if_ready() -> void:
	if _source_tree == null or not is_instance_valid(_source_tree):
		return
	_bootstrap_panel_state_if_needed()
	_push_doc_progress_to_source_provider()
	_source_tree.refresh()


## Idempotent guarded refresh for both destination areas (vault + directory).
## The destinations registry lives independently of any vault, so this works
## with no vault open. Bootstraps the area providers on first use.
func _refresh_all_dest_trees_if_ready() -> void:
	_bootstrap_panel_state_if_needed()
	if _vault_area_provider == null or _dir_area_provider == null:
		return
	_refresh_all_dest_trees()


## Lazy init for the source provider, registry path, and destination area
## providers. Called from _ready (deferred) and from each refresh handler so
## the panel works whether bootstrap happens first via _ready or via the
## first state_changed event arriving. All steps are individually no-op if
## already done. Triggers an initial refresh on first init so the panel
## displays current plugin state without waiting for a user click.
func _bootstrap_panel_state_if_needed() -> void:
	var conn = _get_connection()
	if conn == null:
		return  # plugin not running yet; refresh handlers will retry

	var did_init: bool = false

	# Source provider with empty vault path — files have no in_vault flag.
	if _source_provider == null:
		_source_provider = _SourceProvider.new()
		_source_provider.init(conn, "")
		if _source_tree != null and is_instance_valid(_source_tree):
			_source_tree.set_provider(_source_provider)
		did_init = true

	# Registry path defaults to per-user; idempotent.
	_ensure_destination_registry_path()

	# Destination area providers — these need _registry_path to fetch list.
	if _vault_area_provider == null:
		_vault_area_provider = _AreaProvider.new()
		_vault_area_provider.init(conn, _registry_path, "vault", _active_vault_path)
		if _vault_area_tree != null and is_instance_valid(_vault_area_tree):
			_vault_area_tree.set_provider(_vault_area_provider)
		did_init = true
	if _dir_area_provider == null:
		_dir_area_provider = _AreaProvider.new()
		_dir_area_provider.init(conn, _registry_path, "directory")
		if _dir_area_tree != null and is_instance_valid(_dir_area_tree):
			_dir_area_tree.set_provider(_dir_area_provider)
		did_init = true

	# On first init, kick a refresh so the panel shows current plugin state
	# without waiting for a state_changed event or user click.
	if did_init:
		if _source_tree != null and is_instance_valid(_source_tree):
			_source_tree.refresh()
		_refresh_all_dest_trees()
