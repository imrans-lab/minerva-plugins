extends SceneTree

func _init() -> void:
	await process_frame
	var script: GDScript = load("res://../../minerva-plugins/sheets/tests/helpers/staging_body.gd")
	if script == null or not script.can_instantiate():
		printerr("FAIL: Sheets staging body did not compile")
		quit(1)
		return
	var body: Node = script.new()
	body.connect("completed", func(code: int) -> void: quit(code))
	root.add_child(body)
	create_timer(180.0).timeout.connect(func() -> void:
		printerr("FAIL: Sheets staging timed out")
		quit(1))
