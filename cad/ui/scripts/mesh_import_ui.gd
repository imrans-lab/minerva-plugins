extends RefCounted
## The panel side of the GUI "Import mesh…" action: the file picker, the button
## in each layout, and the one edit the picked file turns into.
##
## The owner picks a mesh file and the panel appends `refN = mesh("path")` to
## the document's own source. Everything the action produces is DSL text, so the
## pose verbs, undo, save and an LLM reading the file all keep working on it —
## and the MCP parity for this action is minerva_doc_write, not a new verb.
##
## The write goes to the DocumentBuffer the substrate attached, which is the one
## the paired text editor is showing. Writing anywhere else — _pending_dsl_text
## alone, a fresh buffer, the file on disk — forks the document in two.
##
## The text decisions — which binding name, which spelling of the path, what the
## line looks like — all live in mesh_import.gd, which never touches a node.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/mesh_import_ui.gd")

const _MeshImport: Script = preload("mesh_import.gd")

## The panel that owns this module. Read through duck typing (its document
## path, its source edit and its banner) — never typed, off-tree.
var _panel: Object = null

## Scene nodes behind the GUI import action: the file picker and the button in
## each layout. Both buttons run the same handler.
var _mesh_import_dialog: FileDialog = null
var _import_buttons: Array[Button] = []

## What the last import decided, for the panel's own reporting:
## {ok, line, name, path, absolute, warning, error}. Empty until one runs.
var _last_import: Dictionary = {}


## Resolve the panel's import controls and connect them. Called from _ready.
func attach(panel: Object) -> void:
	_panel = panel
	_mesh_import_dialog = panel.get_node_or_null("MeshImportDialog") as FileDialog
	if _mesh_import_dialog != null:
		# Filters come from the loader's own format list, so nothing can be
		# loadable without being pickable (or the other way round).
		_mesh_import_dialog.filters = _MeshImport.dialog_filters()
		# Connected to the PANEL's handler, not this module's: the picker is a
		# scene node and the panel is the thing it belongs to, so that is the
		# Callable identity anything checking the wiring will look for.
		if not _mesh_import_dialog.file_selected.is_connected(panel._on_mesh_file_selected):
			_mesh_import_dialog.file_selected.connect(panel._on_mesh_file_selected)

	_import_buttons.clear()
	for button_path in [
		"ResponsiveContainer/WideLayout/WideSidebar/ImportMeshButton",
		"ResponsiveContainer/NarrowLayout/ProjectionRow/ImportMeshButton",
	]:
		var button := panel.get_node_or_null(button_path) as Button
		if button == null:
			continue
		if not button.pressed.is_connected(panel._on_import_mesh_pressed):
			button.pressed.connect(panel._on_import_mesh_pressed)
		_import_buttons.append(button)


func on_import_pressed() -> void:
	if _mesh_import_dialog == null:
		return
	# Open beside the document, which is where a portable relative path can be
	# written; an unsaved document has nowhere to start from.
	if not _panel._document_path.is_empty():
		_mesh_import_dialog.current_dir = _panel._document_path.get_base_dir()
	_mesh_import_dialog.popup_centered_ratio(0.7)


## Append one `refN = mesh("path")` line for `absolute_path` to the document
## and re-evaluate. Public because the file dialog is not the only caller worth
## having: this is the whole action, and it takes a path.
##
## Returns the import plan — {ok, line, name, path, absolute, warning, error}.
func import_file(absolute_path: String) -> Dictionary:
	var plan: Dictionary = _MeshImport.plan_import(
		_panel._current_source(), absolute_path, _panel._document_path)
	_last_import = plan

	if not bool(plan.get("ok", false)):
		var problem: String = str(plan.get("error", ""))
		push_warning("[CADPanel] import mesh: %s" % problem)
		_panel._show_eval_error("Import mesh — %s" % problem)
		return plan

	_panel._apply_source_edit(str(plan["source"]))

	var warning: String = str(plan.get("warning", ""))
	if not warning.is_empty():
		# Same banner as an evaluation error: it is the panel's one visible
		# message surface, and the next evaluation clears it.
		push_warning("[CADPanel] import mesh: %s" % warning)
		_panel._import_notice = "Import mesh — %s" % warning
		_panel._show_eval_error(_panel._import_notice)
	return plan
