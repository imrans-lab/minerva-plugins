extends SceneTree
## Regression: committed zones are selectable and deletable from the canvas —
## docket 019fb5d9083a (delete slice), HITL 2026-07-31: "I can't delete the
## existing pour — no way to select and remove it by human UI."
##
## Covers the whole slice: the model's remove_zone (journalled, undo/redo via
## mutate-then-snapshot), the Select tool's zone hit-test rules (pour = outline
## only, keepout = interior too, layer filter + show_zones respected), and the
## canvas delete path clearing the selection.
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout> (same convention as
## every suite here — see test_routing_workspace_model.gd's header).

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Zone select + delete (019fb5d9083a slice) ===\n")
	_run_model_remove_zone()
	_run_zone_hit_test()
	_run_canvas_delete_path()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + desc)
	else:
		_fail += 1
		printerr("  FAIL: " + desc)


func _square(x0: float, y0: float, x1: float, y1: float) -> Array:
	return [
		{"x_mm": x0, "y_mm": y0}, {"x_mm": x1, "y_mm": y0},
		{"x_mm": x1, "y_mm": y1}, {"x_mm": x0, "y_mm": y1},
	]


## A board with a big top GND pour (0..40), a small top keepout inside it
## (10..20), and a bottom pour off to the side (60..70).
func _data_with_zones():
	var data = PCBData.new()
	data.zones.append({"id": "zone:pour_top", "net": "GND", "layer": "top", "kind": "copper_pour", "outline": _square(0, 0, 40, 40)})
	data.zones.append({"id": "zone:ko_top", "layer": "top", "kind": "keepout", "outline": _square(10, 10, 20, 20)})
	data.zones.append({"id": "zone:pour_bottom", "net": "GND", "layer": "bottom", "kind": "copper_pour", "outline": _square(60, 60, 70, 70)})
	return data


func _run_model_remove_zone() -> void:
	print("-- model: remove_zone + undo/redo --")
	var data = _data_with_zones()
	data.save_to_history("baseline")

	check("remove_zone returns false for an unknown id",
		not data.remove_zone("zone:nope") and data.zones.size() == 3)

	check("remove_zone removes the pour", data.remove_zone("zone:pour_top"))
	check("only the named zone is gone", data.zones.size() == 2
		and str(data.zones[0].get("id", "")) == "zone:ko_top")
	var journal: Array = data.change_journal.filter(
		func(e): return e.get("action", "") == "remove_zone")
	check("removal is journalled with the zone's identity",
		journal.size() == 1 and journal[0]["details"]["zone_id"] == "zone:pour_top"
		and journal[0]["details"]["kind"] == "copper_pour")

	# Mutate-then-snapshot (bug 019fb5ad791c): undo restores, redo re-deletes.
	data.save_to_history("delete zone")
	check("undo restores the deleted zone", data.undo() and data.zones.size() == 3)
	check("redo re-deletes it", data.redo() and data.zones.size() == 2)


func _run_zone_hit_test() -> void:
	print("-- canvas: _zone_at hit rules --")
	var canvas = PcbCanvasScript.new()
	canvas.data = _data_with_zones()
	canvas.zoom = 10.0  # tolerance = 3px / zoom = 0.3 mm

	check("keepout interior click hits the keepout",
		canvas._zone_at(Vector2(15, 15)) == "zone:ko_top")
	check("pour outline click hits the pour",
		canvas._zone_at(Vector2(0.1, 30)) == "zone:pour_top")
	check("pour INTERIOR click misses (falls through to box-select)",
		canvas._zone_at(Vector2(30, 5)) == "")

	canvas.trace_layer_filter = "top"
	check("layer filter hides the bottom pour's outline",
		canvas._zone_at(Vector2(60.1, 65)) == "")
	canvas.trace_layer_filter = "bottom"
	check("bottom view hits the bottom pour",
		canvas._zone_at(Vector2(60.1, 65)) == "zone:pour_bottom")
	check("bottom view hides the top keepout",
		canvas._zone_at(Vector2(15, 15)) == "")

	canvas.trace_layer_filter = "all"
	canvas.show_zones = false
	check("hidden zones never claim a click",
		canvas._zone_at(Vector2(15, 15)) == "")

	canvas.free()


func _run_canvas_delete_path() -> void:
	print("-- canvas: delete clears selection and the zone --")
	var canvas = PcbCanvasScript.new()
	var data = _data_with_zones()
	canvas.data = data
	data.save_to_history("baseline")

	canvas.selected_zone_id = "zone:ko_top"
	canvas._delete_selected_zone()
	check("zone removed from the model", data.zones.size() == 2)
	check("selection cleared", canvas.selected_zone_id == "")
	check("undo after canvas delete restores the zone",
		data.undo() and data.zones.size() == 3)

	# _clear_selection drops a zone pick (Escape / click-elsewhere path).
	canvas.selected_zone_id = "zone:pour_top"
	canvas._clear_selection()
	check("_clear_selection drops the zone pick", canvas.selected_zone_id == "")

	canvas.free()
