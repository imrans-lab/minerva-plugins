extends SceneTree
## Real host overlay pixels on all four CAD panes; no application session required.
const PANEL := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const Overlay := preload("res://Scripts/Services/Annotations/AnnotationOverlay.gd")
var passed := 0
var failed := 0

func _init() -> void:
	await process_frame
	root.size = Vector2i(1280, 900)
	var panel = load(PANEL).instantiate()
	root.add_child(panel)
	panel._apply_width_class(&"lg")
	var host: Object = panel._annotation_host
	var overlay := Overlay.new()
	panel.add_child(overlay)
	overlay.set_host(host)
	await settle()
	var before := root.get_texture().get_image()
	var prepared: Dictionary = host.prepare_source_annotations([
		{"id": "fit", "at_mm": [0,0,0], "text": "Inspection datum",
		"dimension": "diameter", "nominal_mm": 4, "deviations_mm": [0,0.2]}])
	host.set_source_annotations(prepared.annotations, {"source_digest": "fixture"})
	await settle()
	var after := root.get_texture().get_image()
	for pane: Dictionary in host.get_panes():
		var rect := Rect2i(pane.viewport_rect)
		var changed := 0
		for y in range(maxi(rect.position.y,0), mini(rect.end.y,after.get_height())):
			for x in range(maxi(rect.position.x,0), mini(rect.end.x,after.get_width())):
				if before.get_pixel(x,y) != after.get_pixel(x,y):
					changed += 1
		if changed > 100:
			passed += 1
			print("ok: source annotation changed ", changed, " pixels in ", rect)
		else:
			failed += 1
			printerr("FAIL: no source overlay pixels in ", rect)
	after.save_png("user://source-annotations-four-panes.png")
	overlay.set_host(null)
	panel.queue_free()
	await settle()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(0 if passed == 4 and failed == 0 else 1)

func settle() -> void:
	for i in range(5):
		await process_frame
	RenderingServer.force_draw(false)
