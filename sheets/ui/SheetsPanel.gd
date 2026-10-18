class_name Sheets_Panel
extends "res://Scripts/Services/Plugins/MinervaPluginPanel.gd"
## Staging panel. The spreadsheet domain is added in the following slices.

func _on_panel_loaded(_context: Dictionary) -> void:
	var script: Script = get_script()
	var path: String = script.resource_path.get_base_dir().path_join("../icons/bold_icon_24.png")
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image != null and not image.is_empty():
		var button: Button = $Toolbar/Format
		button.icon = ImageTexture.create_from_image(image)

func _on_panel_save_request() -> Dictionary:
	return {"version": 1}

func _on_panel_load_request(_document: Dictionary) -> void:
	pass

func handle_tool(_tool_name: String, _arguments: Dictionary) -> Dictionary:
	return {"success": false, "error_code": "sheets_staging", "error_message": "Spreadsheet editing is not available in this staging build."}
