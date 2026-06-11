extends MinervaPluginPanel
## PCB editor panel — Round 1 placeholder.
##
## This is a scaffold: a PanelContainer with a centered label. The real PCB
## canvas, the Python worker, and the full tool surface land in later rounds.
##
## Off-tree class_name gotcha (feedback_off_tree_plugin_class_names): this plugin
## lives OUTSIDE Minerva's res:// tree, so Godot's parser cache cannot resolve
## plugin-local class_names. This script therefore declares NO `class_name` and
## does NOT preload any sibling plugin scripts — it extends the CORE base
## MinervaPluginPanel (which IS in res:// and resolvable) and is standalone-
## loadable on its own.
##
## The _on_panel_save_request / _on_panel_load_request overrides exist so the
## manifest's project_state / host_owned_save capabilities pass install-time
## validation (PluginDefinition.validate_capabilities regex-scans for them).
## They round-trip a minimal placeholder document until the canvas exists.

const PLACEHOLDER_TEXT := "PCB Editor — plugin scaffold (worker + canvas land in later rounds)"

## Last document restored via _on_panel_load_request, echoed back on save so the
## host's save/load round-trip is non-lossy even before real state exists.
var _doc_state: Dictionary = {}


func _on_panel_loaded(_ctx: Dictionary) -> void:
	# Build the placeholder UI in code so the .tscn stays minimal and the panel
	# renders the same whether mounted by the host or instantiated bare in tests.
	var label := Label.new()
	label.text = PLACEHOLDER_TEXT
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(label)


## Return the panel's save state. Placeholder: a versioned marker plus whatever
## was last loaded, so the host_owned save and project_state capture round-trip.
func _on_panel_save_request() -> Dictionary:
	var doc := {
		"version": 1,
		"kind": "minpcb_scaffold",
	}
	doc.merge(_doc_state, true)
	return doc


## Restore state previously returned by _on_panel_save_request. Placeholder:
## stash it so the next save reflects it; the canvas will consume it later.
func _on_panel_load_request(document: Dictionary) -> void:
	_doc_state = document.duplicate(true)
