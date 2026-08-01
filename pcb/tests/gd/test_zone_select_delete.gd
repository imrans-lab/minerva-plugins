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
	_run_lock_gates_on_delete()
	_run_menu_delta_pins()
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


# ── Campaign 2 boundary: BT-05, BT-06, BT-66, BT-67, BT-69 ────────────────────
#
# DELTA DISCIPLINE. Commit 9b887e9 already re-pinned this suite to the menu path
# (_run_vertex_context_menu above). What follows is ONLY what that commit does
# not measure:
#   * BT-66 — the menu is driven through the POPUP'S OWN id_pressed SIGNAL, and
#     the resulting journal ENTRY SHAPE is compared against the direct call's.
#     9b887e9 calls _on_context_menu_pressed() directly and asserts a count.
#   * BT-67 — the refusal's JOURNAL LENGTH. 9b887e9 asserts the outline and the
#     message; a refusal that journalled anyway would pass it.
#   * BT-69 — a group of THREE, clicked on a member that is not the first.
#     9b887e9 pins "Delete group (2 parts)", which a hardcoded 2 also satisfies.
#   * BT-05 / BT-06 — lock gates on delete; no coverage at all before this.


func _outline_of(data, zone_id: String) -> Array:
	var z: Dictionary = data.get_zone(zone_id)
	return (z.get("outline", []) as Array).duplicate(true)


## BT-05 — locked components and traces are never deleted; zones have NO lock.
##
## ORACLE: the journal length AND the serialized entity count before/after, not
## the remover's return value. The zone leg is the deliberate asymmetry: a lock
## gate invented for zones would red it.
func _run_lock_gates_on_delete() -> void:
	print("\n-- BT-05/BT-06: lock gates on delete --")
	var canvas = PcbCanvasScript.new()
	var data = _data_with_zones()
	canvas.data = data

	var comp = load("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd").new()
	comp.id = "U1"
	comp.position = Vector2(5, 5)
	comp.locked = true
	data.add_component(comp)
	var trace = load("res://../../minerva-plugins/pcb/ui/model/pcb_trace.gd").new()
	trace.net_name = "GND"
	trace.layer = "top"
	trace.width = 0.25
	var wps: Array[Vector2] = [Vector2(50, 5), Vector2(56, 5)]
	trace.waypoints = wps
	trace.locked = true
	data.add_trace(trace)
	var trace_id: String = str(trace.id)

	# ── locked component: the eraser's own doorway, one click at a time ───────
	var j0: int = data.change_journal.size()
	var comps0: int = (data.to_board_dict().get("components", []) as Array).size()
	canvas._delete_picked_entity(canvas.KIND_COMPONENT, "U1", "Erase")
	check("BT-05: a locked COMPONENT survives the eraser (count unchanged)",
		(data.to_board_dict().get("components", []) as Array).size() == comps0)
	check("BT-05: …and nothing was journalled", data.change_journal.size() == j0)

	# ── locked trace ──────────────────────────────────────────────────────────
	var traces0: int = (data.to_board_dict().get("traces", []) as Array).size()
	canvas._delete_picked_entity(canvas.KIND_TRACE, trace_id, "Erase")
	check("BT-05: a locked TRACE survives the eraser",
		(data.to_board_dict().get("traces", []) as Array).size() == traces0)
	check("BT-05: …and still nothing was journalled", data.change_journal.size() == j0)

	# ── a zone carrying a stray `locked` property still deletes ───────────────
	# Zones have no lock in the board contract. Inventing one here would be a
	# silent behaviour change, so the absence is pinned deliberately.
	data.get_zone("zone:pour_bottom")["locked"] = true
	var zones0: int = data.zones.size()
	canvas._delete_picked_entity(canvas.KIND_ZONE, "zone:pour_bottom", "Erase")
	check("BT-05: a zone with a `locked` property STILL deletes (zones have no lock)",
		data.zones.size() == zones0 - 1)

	# ── BT-06: batch delete clears the WHOLE selection, locked survivors too ──
	#
	# ORACLE: selection_count == 0 after the batch, WHILE the locked entity is
	# still present in the serialized board — the pair is the assertion. Clearing
	# only the deleted ids leaves the locked survivor selected.
	canvas._clear_selection()
	canvas._add_to_selection(canvas.KIND_COMPONENT, "U1")       # locked
	canvas._add_to_selection(canvas.KIND_ZONE, "zone:ko_top")   # deletable
	check("BT-06 fixture: a mixed locked/unlocked selection",
		canvas.selection_count() == 2)
	canvas._delete_selection()
	check("BT-06: the whole selection is cleared after the batch",
		canvas.selection_count() == 0, )
	check("BT-06: …while the LOCKED entity is still in the serialized board",
		_board_has_component(data, "U1"))
	check("BT-06: …and the unlocked one is gone", data.get_zone("zone:ko_top").is_empty())

	canvas.free()


func _board_has_component(data, ref: String) -> bool:
	for c in (data.to_board_dict().get("components", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("ref", "")) == ref:
			return true
	return false


## BT-66 / BT-67 / BT-69 — the measured deltas over 9b887e9's menu pins.
func _run_menu_delta_pins() -> void:
	print("\n-- BT-66/67/69: menu deltas over 9b887e9 --")

	# ── BT-66: the POPUP'S OWN SIGNAL, and journal ENTRY SHAPE equality ───────
	#
	# ORACLE: two entry points, one journal shape. 9b887e9 calls the handler
	# directly; a menu item wired to a bespoke mutation path would pass that and
	# fail this. And the id_pressed leg proves the popup is actually CONNECTED —
	# a menu whose items are built but never wired is invisible to a direct call.
	var menu_entry: Dictionary = _delete_one_vertex_via_signal()
	var direct_entry: Dictionary = _delete_one_vertex_directly()
	check("BT-66: the popup's id_pressed signal reaches the action at all",
		not menu_entry.is_empty())
	check("BT-66: menu-path and direct-call journal entries have the SAME KEY SET",
		_key_set(menu_entry) == _key_set(direct_entry))
	check("BT-66: …and the same details key set",
		_key_set(menu_entry.get("details", {})) == _key_set(direct_entry.get("details", {})))
	check("BT-66: …and the same action + op",
		str(menu_entry.get("action", "")) == str(direct_entry.get("action", ""))
		and str((menu_entry.get("details", {}) as Dictionary).get("op", ""))
			== str((direct_entry.get("details", {}) as Dictionary).get("op", "")))

	# ── BT-67: the refusal leaves the JOURNAL LENGTH untouched ────────────────
	var canvas = PcbCanvasScript.new()
	var data = _data_with_zones()
	canvas.data = data
	canvas.zoom = 10.0
	canvas._create_context_menu()
	canvas.selected_zone_ids.append("zone:ko_top")
	# Take the keepout square (4 points) down to a triangle first.
	canvas._context_menu_vertex = canvas._zone_vertex_hit(Vector2(10, 10))
	canvas._on_context_menu_pressed(canvas.MENU_ID_DELETE_VERTEX)
	check("BT-67 fixture: the zone is at the 3-point minimum",
		_outline_size(data, "zone:ko_top") == 3)

	var messages: Array = []
	canvas.zone_tool_message.connect(func(t: String) -> void: messages.append(t))
	var j_before: int = data.change_journal.size()
	var h_before: int = data.history.size()
	canvas._context_menu_vertex = canvas._zone_vertex_hit(Vector2(20, 10))
	check("BT-67 fixture: a surviving corner still has a handle",
		not canvas._context_menu_vertex.is_empty())
	canvas._on_context_menu_pressed(canvas.MENU_ID_DELETE_VERTEX)
	check("BT-67: the refusal left the JOURNAL LENGTH unchanged",
		data.change_journal.size() == j_before)
	check("BT-67: …and the HISTORY unchanged (no dead undo step)",
		data.history.size() == h_before)
	check("BT-67: …and it was said out loud",
		messages.size() == 1 and messages[0].contains("at least 3 points"))
	canvas.free()

	# ── BT-69: the grouped-delete label carries the REAL member count ─────────
	#
	# ORACLE: the integer parsed out of the menu item's own text, compared to the
	# group's actual membership. Three members, and the click lands on the LAST
	# one — a label built from the selection (rather than the group) reds here,
	# and so does a hardcoded 2.
	var c2 = PcbCanvasScript.new()
	var d2 = _data_with_zones()
	c2.data = d2
	c2._create_context_menu()
	for ref in ["U1", "R1", "C1"]:
		var comp = load("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd").new()
		comp.id = ref
		comp.position = Vector2(50, 50)
		d2.add_component(comp)
	d2.group_components(["U1", "R1", "C1"])
	c2._clear_selection()
	c2._context_menu_target = [c2.KIND_COMPONENT, "C1"]
	c2.context_menu_world_pos = Vector2(50, 50)
	c2._update_context_menu_for_selection()
	var label := _menu_text_starting_with(c2, "Delete group")
	check("BT-69: the grouped Delete item exists (%s)" % label, label != "")
	check("BT-69: its integer == the group's REAL member count (3)",
		_first_int(label) == 3)
	c2.free()


func _key_set(d: Variant) -> Array:
	if not (d is Dictionary):
		return []
	var ks: Array = (d as Dictionary).keys().duplicate()
	ks.sort()
	return ks


func _first_int(s: String) -> int:
	var re := RegEx.new()
	re.compile("[0-9]+")
	var m := re.search(s)
	return int(m.get_string(0)) if m != null else -1


func _menu_text_starting_with(canvas, prefix: String) -> String:
	for i in canvas.context_menu.item_count:
		var t: String = canvas.context_menu.get_item_text(i)
		if t.begins_with(prefix):
			return t
	return ""


## Delete one vertex by EMITTING the popup's own id_pressed signal — the wiring
## a direct handler call skips entirely. Returns the journal entry produced.
func _delete_one_vertex_via_signal() -> Dictionary:
	var canvas = PcbCanvasScript.new()
	var data = _data_with_zones()
	canvas.data = data
	canvas.zoom = 10.0
	canvas._create_context_menu()
	canvas.selected_zone_ids.append("zone:pour_top")
	canvas._context_menu_vertex = canvas._zone_vertex_hit(Vector2(0, 0))
	canvas._context_menu_target = canvas._entity_at(Vector2(0, 0))
	canvas.context_menu_world_pos = Vector2(0, 0)
	canvas._update_context_menu_for_selection()
	var before: int = data.change_journal.size()
	canvas.context_menu.id_pressed.emit(canvas.MENU_ID_DELETE_VERTEX)
	var entry: Dictionary = {}
	if data.change_journal.size() > before:
		entry = (data.change_journal[data.change_journal.size() - 1] as Dictionary).duplicate(true)
	canvas.free()
	return entry


## The same delete through the direct (non-menu) handler — the shape to compare.
func _delete_one_vertex_directly() -> Dictionary:
	var canvas = PcbCanvasScript.new()
	var data = _data_with_zones()
	canvas.data = data
	canvas.zoom = 10.0
	canvas._create_context_menu()
	canvas.selected_zone_ids.append("zone:pour_top")
	var hit: Dictionary = canvas._zone_vertex_hit(Vector2(0, 0))
	var before: int = data.change_journal.size()
	# The GESTURE-level function itself — a genuinely different entry point from
	# the popup's id_pressed. (Routing this through _on_context_menu_pressed too
	# would compare the menu path with itself: measured, a bespoke menu-only
	# mutation path then passes the shape comparison.)
	canvas._delete_zone_vertex(hit)
	var entry: Dictionary = {}
	if data.change_journal.size() > before:
		entry = (data.change_journal[data.change_journal.size() - 1] as Dictionary).duplicate(true)
	canvas.free()
	return entry
