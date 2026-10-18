class_name Sheets_Panel
extends "res://Scripts/Services/Plugins/MinervaPluginPanel.gd"
## Staging panel. The spreadsheet domain is added in the following slices.

var create_count: int = 0
var icon_loaded: bool = false

func _on_panel_loaded(context: Dictionary) -> void:
	if context.get("document_action", "") == "create":
		create_count += 1
	var script: Script = get_script()
	var path: String = script.resource_path.get_base_dir().path_join("../icons/bold_icon_24.png")
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	icon_loaded = image != null and not image.is_empty()
	if icon_loaded:
		var button: Button = $Toolbar/Format
		button.icon = ImageTexture.create_from_image(image)

func _on_panel_save_request() -> Dictionary:
	return {"version": 1}

func _on_panel_load_request(_document: Dictionary) -> void:
	pass
