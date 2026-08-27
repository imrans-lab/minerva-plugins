extends SceneTree
## Board-level graphics on the panel side.
##
## Artwork the BOARD owns rather than a component. The only other graphic owner
## is a footprint, so without this a back-side copyright line has to be hung off
## whatever part is nearby, in absolute board coordinates that part's own
## placement corrupts the moment anyone moves it.
##
## WHY THIS SUITE EXISTS ALONGSIDE THE PYTHON ONE. The panel derives its preview
## strokes from the GDScript font mirror and the worker derives the FABRICATED
## strokes from the Python table. Each side is internally consistent, so a drift
## between them shows up nowhere except on the physical board. This suite
## asserts the SAME FIXTURE NUMBERS worker/tests/test_board_graphics.py asserts
## ("Minerva v2" at size 1.5 anchored at x=10: width 11.5 mm, front x-extent
## [10, 21.5], back [-1.5, 10]), so a drifted renderer fails HERE rather than at
## a fab house.
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout> (same convention as
## every suite here — see test_routing_workspace_model.gd's header).

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PcbBoardGraphic := preload("res://../../minerva-plugins/pcb/ui/model/pcb_board_graphic.gd")
const PcbBoardFont := preload("res://../../minerva-plugins/pcb/ui/model/pcb_board_font.gd")
const PcbEntityId := preload("res://../../minerva-plugins/pcb/ui/model/pcb_entity_id.gd")

const ANCHOR_X := 10.0
const ANCHOR_Y := 10.0
const TEXT := "Minerva v2"
const SIZE := 1.5

## Half the default stroke — the ink a bounds reports beyond the centreline.
const HALF_STROKE := 0.075
const EPS := 1e-6

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Board graphics ===\n")
	_run_font_fixture_numbers()
	_run_mirror_convention()
	_run_model_round_trip()
	_run_undo_is_one_step()
	await _run_verbs()
	_run_canvas_selection_and_delete()
	await _run_selection_seams()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: " + desc)
	else:
		_fail += 1
		printerr("  FAIL: " + desc + ("" if detail.is_empty() else "  (" + detail + ")"))


func check_near(desc: String, got: float, want: float) -> void:
	check(desc, absf(got - want) < EPS, "got %f, want %f" % [got, want])


func _text_graphic(layer: String, id: String = "") -> Dictionary:
	var built: Dictionary = PcbBoardGraphic.build_text(
		TEXT, ANCHOR_X, ANCHOR_Y, layer, SIZE, 0.0, id)
	assert(built["ok"], "fixture build_text refused: " + str(built.get("error", "")))
	return built["graphic"]


func _data_with(graphics: Array):
	var data = PCBData.new()
	for g in graphics:
		data.add_board_graphic(g)
	# A BASELINE history entry: undo() restores the PREVIOUS entry, so a board
	# whose history holds only the post-delete snapshot has nothing to undo to.
	data.save_to_history("baseline")
	return data


# --------------------------------------------------------------------------
# The font, pinned to the same numbers the Python suite pins
# --------------------------------------------------------------------------

func _run_font_fixture_numbers() -> void:
	print("-- font fixture numbers (mirrored from worker/tests/test_board_font.py) --")
	check_near("\"Minerva v2\" at size 1.5 is 11.5 mm wide",
		PcbBoardFont.text_width(TEXT, SIZE), 11.5)

	# size IS cap height: an "M" at 1.5 is exactly 1.5 mm tall, baseline at y=0.
	var m := PcbBoardFont.render("M", SIZE)
	var min_y := INF
	var max_y := -INF
	for stroke in m["polylines"]:
		for pv in stroke:
			var p: Vector2 = pv
			min_y = minf(min_y, p.y)
			max_y = maxf(max_y, p.y)
	check_near("cap height equals size (M at 1.5 spans 1.5 mm)", max_y - min_y, 1.5)
	check_near("baseline sits at y = 0", max_y, 0.0)

	# Unknown glyphs draw a box and are REPORTED. Dropping one would shorten a
	# legend silently; drawing "?" would be a lie the reader cannot detect.
	var odd := PcbBoardFont.render("AµB", 1.0)
	check("unknown glyph is reported, not dropped", odd["missing"] == ["µ"],
		str(odd["missing"]))
	check("unknown glyph still occupies its advance",
		absf(float(odd["width_mm"]) - PcbBoardFont.text_width("AµB", 1.0)) < EPS)

	# Scale linearity with a space in the string — the discriminating fixture for
	# the double-scaled-advance bug stroke_font.py records against itself.
	check("text_width scales linearly through a space",
		absf(PcbBoardFont.text_width("R1 C2", 2.0)
			- PcbBoardFont.text_width("R1 C2", 1.0) * 2.0) < EPS)


# --------------------------------------------------------------------------
# R7 — the mirror convention, on the panel side
# --------------------------------------------------------------------------

func _bounds_of(graphic: Dictionary) -> Rect2:
	return PcbBoardGraphic.bounds(graphic)


func _run_mirror_convention() -> void:
	print("-- mirror convention (risk R7) --")
	var front := _text_graphic("F.SilkS")
	var back := _text_graphic("B.SilkS")

	var fb := _bounds_of(front)
	var bb := _bounds_of(back)
	# THE INK, not the centreline: a stroke is half its width wide on each side
	# of the path, and a bounds that stops at the path says a legend drawn along
	# the rim fits when it overhangs.
	check_near("F.SilkS text starts half a stroke before the anchor x",
		fb.position.x, 10.0 - HALF_STROKE)
	check_near("F.SilkS text ends half a stroke past anchor + width",
		fb.end.x, 21.5 + HALF_STROKE)
	check_near("B.SilkS text starts half a stroke before anchor - width",
		bb.position.x, -1.5 - HALF_STROKE)
	check_near("B.SilkS text ends half a stroke past the anchor x",
		bb.end.x, 10.0 + HALF_STROKE)
	check_near("the box is exactly one stroke wider than the strokes it holds",
		fb.size.x - PcbBoardFont.text_width(TEXT, SIZE), HALF_STROKE * 2.0)

	# The reflection is about the text's OWN anchor (x=10), never the board
	# origin: reflecting about x=0 would put the label at [-21.5, -10], off the
	# board, and would mean asking for text at a position MOVED it.
	check("B is the X-mirror of F about the anchor, not the origin",
		absf(bb.position.x - (2.0 * ANCHOR_X - fb.end.x)) < EPS
			and absf(bb.end.x - (2.0 * ANCHOR_X - fb.position.x)) < EPS)

	# Y is untouched — a Y-mirror would print the legend upside down, which looks
	# stable and blesses perfectly.
	check_near("mirroring leaves y alone (min)", bb.position.y, fb.position.y)
	check_near("mirroring leaves y alone (max)", bb.end.y, fb.end.y)

	# Point for point, so symmetric artwork cannot satisfy the extents by luck.
	var fs: Array = PcbBoardGraphic.display(front)["polylines"]
	var bs: Array = PcbBoardGraphic.display(back)["polylines"]
	check("front and back draw the same number of strokes", fs.size() == bs.size(),
		"%d vs %d" % [fs.size(), bs.size()])
	var pointwise := fs.size() == bs.size()
	if pointwise:
		for i in fs.size():
			var a: Array = fs[i]
			var b: Array = bs[i]
			if a.size() != b.size():
				pointwise = false
				break
			for j in a.size():
				var pa: Vector2 = a[j]
				var pb: Vector2 = b[j]
				if absf((2.0 * ANCHOR_X - pa.x) - pb.x) > EPS or absf(pa.y - pb.y) > EPS:
					pointwise = false
					break
	check("every back point is its front twin reflected about x=10", pointwise)
	check("back artwork is NOT identical to front (negative control)", fs != bs)

	# Mirroring is derived from the LAYER, so the editor cannot show back text
	# that would come out backwards on the fab.
	check("B.SilkS mirrors by default", PcbBoardGraphic.mirror_for(back))
	check("F.SilkS does not mirror", not PcbBoardGraphic.mirror_for(front))

	# Centred text mirrors IN PLACE — the alignment a back-side label usually
	# wants: the glyphs reverse, the block does not slide across its anchor.
	var centred: Dictionary = PcbBoardGraphic.build_text(
		TEXT, ANCHOR_X, ANCHOR_Y, "F.SilkS", SIZE, 0.0, "", -1.0, "center")["graphic"]
	var centred_back: Dictionary = PcbBoardGraphic.build_text(
		TEXT, ANCHOR_X, ANCHOR_Y, "B.SilkS", SIZE, 0.0, "", -1.0, "center")["graphic"]
	check("centred text mirrors in place",
		absf(_bounds_of(centred).position.x - _bounds_of(centred_back).position.x) < EPS)


# --------------------------------------------------------------------------
# Model: held verbatim, round-trips, text stays provenance
# --------------------------------------------------------------------------

func _run_model_round_trip() -> void:
	print("-- model round trip --")
	var graphic := _text_graphic("B.SilkS")
	var data = _data_with([graphic])

	check("id is a minted graphic id",
		PcbEntityId.is_minted(PcbBoardGraphic.ENTITY_TYPE, str(graphic["id"])),
		str(graphic["id"]))

	# The board stores the STRING, not the strokes. This is what turns 65 lines
	# of hand-generated polylines into one editable line of YAML.
	check("text is stored as provenance, not baked geometry",
		graphic.has("text") and not graphic.has("points") and not graphic.has("strokes"))

	var board_dict: Dictionary = data.to_board_dict()
	check("to_board_dict emits board_graphics", board_dict.has("board_graphics"))
	check("exactly one graphic is emitted",
		(board_dict["board_graphics"] as Array).size() == 1)

	var reloaded = PCBData.new()
	reloaded.from_board_dict(board_dict)
	check("from_board_dict restores it", reloaded.board_graphics.size() == 1)
	var back: Dictionary = reloaded.get_board_graphic(str(graphic["id"]))
	check("the id survives the round trip unchanged", not back.is_empty())
	check("the text survives the round trip", str(back.get("text", "")) == TEXT)
	# Identical bounds after the round trip: the whole point of storing
	# provenance is that re-deriving reproduces the same artwork.
	var before := _bounds_of(graphic)
	var after := _bounds_of(back)
	check("bounds are identical after the round trip",
		absf(before.position.x - after.position.x) < EPS
			and absf(before.end.x - after.end.x) < EPS
			and absf(before.position.y - after.position.y) < EPS
			and absf(before.end.y - after.end.y) < EPS)

	# The conditional-emit rule: a board with no artwork must stay byte-identical
	# to what it was before this field existed.
	var plain = PCBData.new()
	check("an artwork-free board emits no board_graphics key",
		not plain.to_board_dict().has("board_graphics"))


func _run_undo_is_one_step() -> void:
	print("-- undo --")
	var data = PCBData.new()
	data.save_to_history("baseline")
	var graphic := _text_graphic("F.SilkS")
	data.add_board_graphic(graphic)
	data.save_to_history("Add silk text")
	check("the graphic is on the board", data.board_graphics.size() == 1)

	data.undo()
	check("ONE undo removes the whole text, all strokes at once",
		data.board_graphics.size() == 0, "%d left" % data.board_graphics.size())
	data.redo()
	check("redo restores it", data.board_graphics.size() == 1)
	check("redo restores the SAME id",
		str(data.board_graphics[0].get("id", "")) == str(graphic["id"]))

	# Delete then undo — the affordance the DCR asks for.
	data.remove_board_graphic(str(graphic["id"]))
	data.save_to_history("Delete board graphic")
	check("delete removes it", data.board_graphics.size() == 0)
	data.undo()
	check("ONE undo restores a deleted graphic", data.board_graphics.size() == 1)


# --------------------------------------------------------------------------
# The MCP verbs
# --------------------------------------------------------------------------

class _FakeHost:
	extends RefCounted
	var data
	## panel_tools._get_data duck-types the host on this exact name.
	func get_board_data():
		return data


func _host_with(data) -> _FakeHost:
	var host := _FakeHost.new()
	host.data = data
	return host


## Call one verb and report whether it REFUSED.
##
## A helper rather than an inline expression because `await f(...).get("ok")`
## binds the await to `.get`, not to the coroutine — Godot rejects it, and the
## shape that does parse (`(await f(...)).get(...)`) reads worse than a name.
func _refused(host, tool: String, args: Dictionary) -> bool:
	var reply: Dictionary = await PanelTools.handle(host, tool, args)
	return not bool(reply.get("success", false))


func _run_verbs() -> void:
	print("-- MCP verbs --")
	var data = PCBData.new()
	var host := _host_with(data)

	var reply: Dictionary = await PanelTools.handle(host, "minerva_pcb_add_silk_text", {
		"editor_name": "pcb", "text": TEXT, "layer": "B.SilkS",
		"position": {"x_mm": ANCHOR_X, "y_mm": ANCHOR_Y}, "size_mm": SIZE,
	})
	check("add_silk_text succeeds", bool(reply.get("success", false)), str(reply))
	if bool(reply.get("success", false)):
		# _ok() MERGES the payload into a flat envelope — there is no nested
		# "result" key to unwrap.
		var body: Dictionary = reply
		check("the reply carries the graphic id",
			PcbEntityId.is_minted("graphic", str(body.get("graphic_id", ""))),
			str(body.get("graphic_id", "")))
		check("the reply says the text is mirrored", bool(body.get("mirrored", false)))
		var bounds: Dictionary = body.get("bounds", {})
		check("the reply carries the mirrored bounds, as INK",
			absf(float(bounds.get("min_x_mm", 0.0)) - (-1.5 - HALF_STROKE)) < EPS
				and absf(float(bounds.get("max_x_mm", 0.0)) - (10.0 + HALF_STROKE)) < EPS,
			str(bounds))
		check("the board actually gained it", data.board_graphics.size() == 1)

	# Refusals are explicit, never silent.
	check("copper is refused for text", await _refused(host, "minerva_pcb_add_silk_text", {
		"editor_name": "pcb", "text": "x", "layer": "top",
		"position": {"x_mm": 1, "y_mm": 1}}))
	check("empty text is refused", await _refused(host, "minerva_pcb_add_silk_text", {
		"editor_name": "pcb", "text": "", "layer": "F.SilkS",
		"position": {"x_mm": 1, "y_mm": 1}}))
	check("a missing position is refused", await _refused(host, "minerva_pcb_add_silk_text", {
		"editor_name": "pcb", "text": "x", "layer": "F.SilkS"}))

	# add_graphic: exactly one geometry key.
	var geo: Dictionary = await PanelTools.handle(host, "minerva_pcb_add_graphic", {
		"editor_name": "pcb", "layer": "F.CrtYd", "width_mm": 0.2,
		"rect": {"start": {"x_mm": 1, "y_mm": 1}, "end": {"x_mm": 9, "y_mm": 5}},
	})
	check("add_graphic accepts a rect", bool(geo.get("success", false)), str(geo))
	check("two geometry keys are refused", await _refused(host, "minerva_pcb_add_graphic", {
		"editor_name": "pcb", "layer": "F.SilkS",
		"rect": {"start": {"x_mm": 1, "y_mm": 1}, "end": {"x_mm": 2, "y_mm": 2}},
		"circle": {"center": {"x_mm": 1, "y_mm": 1}, "radius_mm": 1},
	}))
	check("no geometry key is refused", await _refused(host, "minerva_pcb_add_graphic", {
		"editor_name": "pcb", "layer": "F.SilkS"}))
	check("Edge.Cuts is refused", await _refused(host, "minerva_pcb_add_graphic", {
		"editor_name": "pcb", "layer": "Edge.Cuts",
		"points": [{"x_mm": 1, "y_mm": 1}, {"x_mm": 2, "y_mm": 2}]}))

	# AN UNMINTED SUPPLIED ID IS REFUSED HERE, where it names one entry — Go's
	# Validate refuses it at save/export, against the whole board, long after
	# the caller was told its artwork landed.
	var before_unminted: int = data.board_graphics.size()
	check("an unminted id is refused for geometry",
		await _refused(host, "minerva_pcb_add_graphic", {
			"editor_name": "pcb", "layer": "F.SilkS", "id": "graphic:NOPE",
			"points": [{"x_mm": 1, "y_mm": 1}, {"x_mm": 2, "y_mm": 2}]}))
	check("an unminted id is refused for text",
		await _refused(host, "minerva_pcb_add_silk_text", {
			"editor_name": "pcb", "text": "x", "layer": "F.SilkS", "id": "graphic:NOPE",
			"position": {"x_mm": 1, "y_mm": 1}}))
	check("the model refuses it directly too, and mints nothing",
		not bool(PcbBoardGraphic.build_text(
			"x", 1.0, 1.0, "F.SilkS", 1.0, 0.0, "not-an-id")["ok"]))
	check("a MINTED id is still honoured",
		bool(PcbBoardGraphic.build_text("x", 1.0, 1.0, "F.SilkS", 1.0, 0.0,
			"graphic:" + "a".repeat(32))["ok"]))

	# ONE ID NAMES ONE GRAPHIC: several polylines plus an id used to land
	# artwork the caller could not delete by the id it asked for.
	check("several polylines plus a supplied id is refused",
		await _refused(host, "minerva_pcb_add_graphic", {
			"editor_name": "pcb", "layer": "F.SilkS",
			"id": "graphic:" + "b".repeat(32),
			"polylines": [
				[{"x_mm": 1, "y_mm": 1}, {"x_mm": 2, "y_mm": 2}],
				[{"x_mm": 3, "y_mm": 3}, {"x_mm": 4, "y_mm": 4}]]}))
	check("...and none of them was written", data.board_graphics.size() == before_unminted)
	var one_id: Dictionary = await PanelTools.handle(host, "minerva_pcb_add_graphic", {
		"editor_name": "pcb", "layer": "F.SilkS", "id": "graphic:" + "c".repeat(32),
		"polylines": [[{"x_mm": 1, "y_mm": 1}, {"x_mm": 2, "y_mm": 2}]]})
	check("ONE polyline with a supplied id still lands under that id",
		bool(one_id.get("success", false))
			and str(one_id.get("graphic_id", "")) == "graphic:" + "c".repeat(32),
		str(one_id))

	# delete_graphic by id, and an unknown id is an error rather than a no-op.
	var target := str(data.board_graphics[0].get("id", ""))
	var deleted: Dictionary = await PanelTools.handle(host, "minerva_pcb_delete_graphic",
		{"editor_name": "pcb", "graphic_id": target})
	check("delete_graphic removes by id", bool(deleted.get("success", false)), str(deleted))
	check("the graphic is gone", data.get_board_graphic(target).is_empty())
	check("an unknown id is an explicit error",
		await _refused(host, "minerva_pcb_delete_graphic",
			{"editor_name": "pcb", "graphic_id": "graphic:" + "0".repeat(32)}))


# --------------------------------------------------------------------------
# Canvas: pick, select, delete
# --------------------------------------------------------------------------

func _run_canvas_selection_and_delete() -> void:
	print("-- canvas selection + delete --")
	var graphic := _text_graphic("F.SilkS")
	var data = _data_with([graphic])
	var canvas = PcbCanvasScript.new()
	canvas.data = data
	canvas.zoom = 10.0

	var gid := str(graphic["id"])
	# Pick a point ON a stroke: the first point of the first stroke is on the
	# artwork by construction, so this is not a guess about glyph shape.
	var strokes: Array = PcbBoardGraphic.display(graphic)["polylines"]
	var on_art: Vector2 = (strokes[0] as Array)[0]
	var hit: Array = canvas._entity_at(on_art)
	check("a click on the artwork picks the graphic",
		hit.size() == 2 and str(hit[0]) == canvas.KIND_BOARD_GRAPHIC and str(hit[1]) == gid,
		str(hit))

	# Far away picks nothing.
	var miss: Array = canvas._entity_at(Vector2(500, 500))
	check("a click far away picks nothing", str(miss[0]).is_empty())

	# Hidden silk is unpickable — the same gate that hides it must stop it
	# stealing clicks.
	canvas.show_silk = false
	check("hidden silk is not pickable", canvas._board_graphic_at(on_art).is_empty())
	canvas.show_silk = true

	canvas._add_to_selection(canvas.KIND_BOARD_GRAPHIC, gid)
	check("it can be selected", canvas.is_entity_selected(canvas.KIND_BOARD_GRAPHIC, gid))
	check("selection_count counts it", canvas.selection_count() == 1)
	check("the public getter reports it",
		canvas.get_selected_board_graphics() == [gid])
	check("the snapshot reports it",
		(canvas.selection_snapshot().get("board_graphics", []) as Array) == [gid])
	check("the delete label names what it is, not the kind token",
		canvas._entity_action_label("Delete", canvas.KIND_BOARD_GRAPHIC, gid) == "Delete text")
	check("it has no lock concept",
		not canvas._is_entity_locked(canvas.KIND_BOARD_GRAPHIC, gid))

	# The batch Delete path — the literal kind array is not derived, so a kind
	# missing from it selects, highlights, and then survives Delete silently.
	canvas._delete_selection()
	check("Delete removes it from the board", data.board_graphics.size() == 0)
	check("Delete clears it from the selection",
		not canvas.is_entity_selected(canvas.KIND_BOARD_GRAPHIC, gid))
	data.undo()
	check("ONE undo restores it after a canvas delete", data.board_graphics.size() == 1)

	canvas.free()


# --------------------------------------------------------------------------
# The two selection seams — a graphic the human can select, the agent can too
# --------------------------------------------------------------------------
#
# Selection is a two-way channel: minerva_pcb_select is how an agent points at
# something, minerva_pcb_get_selection is how it reads what is pointed at. Board
# graphics were on the canvas's side of both and on neither of these, so "select
# that copyright line" and "what have I got selected" both went silent about the
# one kind of artwork the board itself owns.

class _FakeEditor:
	extends RefCounted
	var tab_title: String = "Board graphics"


class _SelectHost:
	extends RefCounted
	var data
	var panel
	func get_board_data():
		return data
	func get_panel():
		return panel


func _run_selection_seams() -> void:
	print("-- selection seams --")
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel("res://../../minerva-plugins/pcb/ui/PCBPanel.gd")
	get_root().add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size = Vector2(900, 700)
	panel._on_panel_loaded({"editor": _FakeEditor.new(), "file_path": ""})
	for _i in range(4):
		await process_frame

	var data = panel.get_data()
	var graphic := _text_graphic("F.SilkS")
	data.add_board_graphic(graphic)
	var gid := str(graphic["id"])

	var selected: Dictionary = panel.select_entities([{"kind": "board_graphic", "id": gid}])
	check("minerva_pcb_select resolves a board graphic",
		bool(selected.get("ok", false)) and int(selected.get("selected", 0)) == 1,
		str(selected))
	check("...and the canvas really holds it",
		(panel.get_selection_state().get("board_graphics", []) as Array).has(gid))

	var host := _SelectHost.new()
	host.data = data
	host.panel = panel
	var read: Dictionary = await PanelTools.handle(host, "minerva_pcb_get_selection",
		{"editor_name": "pcb"})
	var found: Dictionary = {}
	for entry in (read.get("selection", read.get("entries", [])) as Array):
		if entry is Dictionary and str((entry as Dictionary).get("kind", "")) == "board_graphic":
			found = entry
	check("get_selection reports the selected graphic", not found.is_empty(), str(read))
	if not found.is_empty():
		check("...by its id", str(found.get("id", "")) == gid, str(found.get("id", "")))
		check("...and describes it the way every other reader does",
			found.has("bounds") and str(found.get("layer", "")) == "F.SilkS")

	var missing: Dictionary = panel.select_entities([
		{"kind": "board_graphic", "id": "graphic:" + "0".repeat(32)}])
	check("an id no graphic answers to is reported, not selected",
		(missing.get("not_found", []) as Array).size() == 1
			and int(missing.get("selected", -1)) == 0, str(missing))

	driver.free_panel(panel)
