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
	_run_vertex_context_menu()
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


## The vertex CONTEXT MENU (B1u5, docket 019fbb968e, owner ruling: "I expect right
## click to be a menu, with delete as an option").
##
## This replaces the A5 gesture pin. A5 deleted a vertex on right-PRESS, with no
## menu and no modifier; the ruling retired that. What is pinned here is the menu
## path that took its place — same hit, same journal entry, same refusal, reached
## by choosing an item instead of by the press itself. The FIRST assertion is that
## the old entry point is gone, because a replacement that leaves the original
## gesture wired up has replaced nothing.
##
## Drives the menu the way the release half does: the press resolves the target
## into _context_menu_vertex / _context_menu_target, then _update_context_menu_for_
## selection builds and _on_context_menu_pressed acts. (The real push_input gesture
## over the whole path is pinned in test_pcb_canvas_input_probe.gd — this suite is
## the model-level half.)
func _run_vertex_context_menu() -> void:
	print("-- context menu: vertex delete replaces the A5 gesture --")
	var canvas = PcbCanvasScript.new()
	var data = _data_with_zones()
	canvas.data = data
	canvas.zoom = 10.0
	canvas._create_context_menu()
	data.save_to_history("baseline")

	check("the A5 instant-delete gesture is GONE (no _delete_zone_vertex_at)",
		not canvas.has_method("_delete_zone_vertex_at"))

	# Select the 4-point top pour so its handles exist.
	canvas.selected_zone_ids.append("zone:pour_top")
	var hit: Dictionary = canvas._zone_vertex_hit(Vector2(0, 0))
	check("a handle of the selected zone is hit at its corner",
		not hit.is_empty() and int(hit["index"]) == 0)

	# The press half writes these; the release half reads them.
	canvas.context_menu_world_pos = Vector2(0, 0)
	canvas._context_menu_vertex = hit
	canvas._context_menu_target = canvas._entity_at(Vector2(0, 0))
	canvas._update_context_menu_for_selection()
	check("the menu offers Delete vertex", _menu_has(canvas, "Delete vertex"))
	check("Delete vertex is enabled above the minimum",
		not _menu_disabled(canvas, "Delete vertex"))

	canvas._on_context_menu_pressed(canvas.MENU_ID_DELETE_VERTEX)
	check("choosing it deletes the vertex", _outline_size(data, "zone:pour_top") == 3)
	var deletes: Array = []
	for entry in data.change_journal:
		if str(entry.get("action", "")) != "edit_zone_outline":
			continue
		if str((entry["details"] as Dictionary).get("op", "")) == "delete_vertex":
			deletes.append(entry)
	check("the menu path journals delete_vertex, exactly as the gesture did",
		deletes.size() == 1
			and str((deletes[0]["details"] as Dictionary)["zone_id"]) == "zone:pour_top")
	check("undo restores the vertex",
		data.undo() and _outline_size(data, "zone:pour_top") == 4)

	# MIN-3 REFUSAL, through the menu, VISIBLY. Take it back down to a triangle
	# first, then try to delete a fourth time.
	var messages: Array = []
	canvas.zone_tool_message.connect(func(t: String) -> void: messages.append(t))
	canvas._on_context_menu_pressed(canvas.MENU_ID_DELETE_VERTEX)  # 4 -> 3
	# A SURVIVING corner: the two deletes above both took index 0, so (0,0) is no
	# longer a vertex of the triangle. (40,0) is.
	canvas._context_menu_vertex = canvas._zone_vertex_hit(Vector2(40, 0))
	check("a triangle still shows its handles",
		not canvas._context_menu_vertex.is_empty())
	canvas._on_context_menu_pressed(canvas.MENU_ID_DELETE_VERTEX)  # refused
	check("the minimum is refused, not silently obeyed",
		_outline_size(data, "zone:pour_top") == 3)
	check("and the refusal is SAID, on the channel the panel shows",
		messages.size() == 1 and messages[0].contains("at least 3 points"))

	# "Insert vertex here" — the discoverable doorway onto the edge-tap gesture.
	# Same gate (_zone_edge_insert_candidate), same journalled write.
	data.undo()  # back to a square
	var mid_edge := Vector2(20, 0)  # on the top edge, between corners 0 and 1
	canvas._context_menu_vertex = canvas._zone_vertex_hit(mid_edge)
	canvas._context_menu_target = canvas._entity_at(mid_edge)
	canvas._context_menu_edge_insert = canvas._zone_edge_insert_candidate(
		mid_edge, str(canvas._context_menu_target[0]), str(canvas._context_menu_target[1]))
	canvas.context_menu_world_pos = mid_edge
	canvas._update_context_menu_for_selection()
	check("an edge offers Insert vertex here, and NOT Delete vertex",
		_menu_has(canvas, "Insert vertex here") and not _menu_has(canvas, "Delete vertex"))
	var before: int = _outline_size(data, "zone:pour_top")
	canvas._on_context_menu_pressed(canvas.MENU_ID_INSERT_VERTEX)
	check("choosing it grows the outline by one point",
		_outline_size(data, "zone:pour_top") == before + 1)

	# Empty space: the menu is exactly the stub it always was.
	canvas._context_menu_vertex = {}
	canvas._context_menu_edge_insert = {}
	canvas._context_menu_target = ["", ""]
	canvas.context_menu_world_pos = Vector2(500, 500)
	canvas._clear_selection()
	canvas._update_context_menu_for_selection()
	check("empty-space right-click is unchanged: one disabled (no actions)",
		canvas.context_menu.item_count == 1
			and canvas.context_menu.get_item_text(0) == "(no actions)"
			and canvas.context_menu.is_item_disabled(0))

	canvas.free()


## Outline point count read off the STORED list, not through the model's static
## decoder: this suite's preloads are the two-up "res://../../minerva-plugins/..."
## form every pcb suite uses, and a statically-resolved call through them is
## checked against whatever sits at that path on the host running the gate. Read
## dynamically, the same way `canvas` and `data` themselves are.
func _outline_size(data, zone_id: String) -> int:
	return (data.get_zone(zone_id)["outline"] as Array).size()


func _menu_index(canvas, text: String) -> int:
	for i in canvas.context_menu.item_count:
		if canvas.context_menu.get_item_text(i) == text:
			return i
	return -1


func _menu_has(canvas, text: String) -> bool:
	return _menu_index(canvas, text) >= 0


func _menu_disabled(canvas, text: String) -> bool:
	var i := _menu_index(canvas, text)
	return i >= 0 and canvas.context_menu.is_item_disabled(i)
