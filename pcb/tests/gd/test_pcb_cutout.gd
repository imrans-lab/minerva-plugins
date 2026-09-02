extends SceneTree
## Board CUT-OUTS — the GDScript authoring half (campaign 2 epoch B, unit 3).
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout>, or directly:
##   godot --headless --path src --script ../../minerva-plugins/pcb/tests/gd/test_pcb_cutout.gd
##
## Campaign-2 boundary entries BT-81 (GD half), BT-82, BT-83.
##
## The Python half of BT-81 (compile_board REFUSES a cutout-bearing board with
## the denylist message) is standing in pcb/worker/tests/test_compile_board.py and
## is NOT duplicated here. What this suite owns is the other language's end of the
## same contract: a board authored through the GDScript TOOL PATH, serialized, and
## handed off as a file. The worker binary is never invoked (the Minerva2 test
## scaffold has no src/bin, so every start_plugin returns Unavailable — see
## run-gd-tests.sh).

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const CANVAS_SRC := "res://../../minerva-plugins/pcb/ui/pcb_canvas.gd"

## Where the GD half leaves its serialized board for the cross-language hand-off.
const HANDOFF_PATH := "user://pcb_cutout_gd_handoff.json"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== PCB cut-outs (GD authoring half) ===\n")
	_test_tool_path_mints_a_cutout()
	_test_serialization_is_conditional()
	_test_zone_vertex_edit_excludes_cutout()
	_test_right_press_while_cutout_armed()
	_test_draw_order()
	_test_cross_language_handoff()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail.is_empty():
			printerr("  FAIL: %s" % desc)
		else:
			printerr("  FAIL: %s — %s" % [desc, detail])


func _board() -> Dictionary:
	return {
		"version": 1, "name": "CutoutBoard", "width_mm": 60.0, "height_mm": 40.0,
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 30.0, "y_mm": 20.0,
				"rotation_deg": 0.0, "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		],
	}


func _canvas_with_board():
	var canvas = PcbCanvasScript.new()
	var data = PCBData.new()
	data.from_board_dict(_board())
	canvas.data = data
	canvas.zoom = 8.0
	canvas.snap_to_grid = false
	return canvas


## BT-81 (GD half) — a 3-point cutout drawn through the TOOL PATH shows up as a
## real entity, and survives serialization.
##
## ORACLE: two representations that are not the tool's own state — the model's
## `cutouts` array, and `to_board_dict()`'s serialized list. The tool's
## `_cutout_points` buffer is never asserted on: it is the thing under test.
##
## The serialized board is also WRITTEN TO A FILE, so the Python half of this
## contract (test_compile_board.py's denylist refusal) can be pointed at a board
## the GDScript authoring path actually produced, rather than a hand-written
## fixture that only claims to look like one.
func _test_tool_path_mints_a_cutout() -> void:
	print("-- BT-81: tool path → cutouts[] → serialized board → file --")
	var canvas = _canvas_with_board()
	var data = canvas.data

	canvas.set_tool_mode(canvas.ToolMode.CUTOUT)
	check("BT-81 fixture: the cutout tool is armed",
			canvas.tool_mode == canvas.ToolMode.CUTOUT)
	check("BT-81 fixture: the board starts with no cutouts", data.cutouts.is_empty())

	# Three clicks, then the double-click that closes — the documented grammar.
	canvas._handle_cutout_click(Vector2(10.0, 10.0), false)
	canvas._handle_cutout_click(Vector2(20.0, 10.0), false)
	canvas._handle_cutout_click(Vector2(20.0, 20.0), false)
	canvas._handle_cutout_click(Vector2(20.0, 20.0), true)

	check("BT-81: the model gained exactly one cutout", data.cutouts.size() == 1,
			"cutouts=%d" % data.cutouts.size())
	var minted: Dictionary = data.cutouts[0] if data.cutouts.size() == 1 else {}
	check("BT-81: it carries an id", not str(minted.get("id", "")).is_empty(),
			str(minted))
	check("BT-81: its outline has 3 points",
			(minted.get("outline", []) as Array).size() == 3,
			"outline=%s" % str(minted.get("outline", [])))

	# SERIALIZED representation — the silent-drop point the round fixed.
	var board: Dictionary = data.to_board_dict()
	check("BT-81: to_board_dict() carries the cutout", board.has("cutouts")
			and (board["cutouts"] as Array).size() == 1,
			"keys=%s" % str(board.keys()))
	var ser: Dictionary = (board["cutouts"] as Array)[0] if board.has("cutouts") \
			and not (board["cutouts"] as Array).is_empty() else {}
	check("BT-81: the SERIALIZED outline still has 3 points",
			(ser.get("outline", []) as Array).size() == 3, str(ser))

	# Round-trip through from_board_dict — the other half of the silent drop.
	var reloaded = PCBData.new()
	reloaded.from_board_dict(board)
	check("BT-81: from_board_dict() restores it (round-trip, not one-way)",
			reloaded.cutouts.size() == 1
			and (reloaded.cutouts[0].get("outline", []) as Array).size() == 3,
			"reloaded=%s" % str(reloaded.cutouts))

	# Cross-language hand-off: the file the Python half can consume. No worker
	# binary is invoked here — this is a serialize-and-drop, nothing more.
	var f := FileAccess.open(HANDOFF_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(board, "  "))
		f.close()
	check("BT-81: the serialized board was written for the cross-language hand-off",
			FileAccess.file_exists(HANDOFF_PATH))
	var round_tripped: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(HANDOFF_PATH))
	check("BT-81: …and it re-parses with the cutout intact",
			round_tripped is Dictionary
			and (round_tripped as Dictionary).has("cutouts")
			and ((round_tripped as Dictionary)["cutouts"] as Array).size() == 1)

	canvas.free()


## BT-81, second leg — the conditional emit. A cutout-FREE board's canonical dict
## must stay byte-identical to what it was before cutouts existed.
##
## ORACLE: key absence in the serialized dict, compared against a board loaded
## from a pre-cutout board dict. An unconditional emit reds here while every
## assertion above stays green.
func _test_serialization_is_conditional() -> void:
	print("\n-- BT-81b: a cutout-free board's dict is byte-identical --")
	var data = PCBData.new()
	data.from_board_dict(_board())
	var clean: Dictionary = data.to_board_dict()
	check("BT-81b: no `cutouts` key on a cutout-free board", not clean.has("cutouts"),
			"keys=%s" % str(clean.keys()))

	# And the round-trip of that same dict is byte-identical, so a board saved by
	# a build WITH cutouts and one WITHOUT cannot be told apart.
	var again = PCBData.new()
	again.from_board_dict(clean)
	check("BT-81b: round-tripping a cutout-free board is byte-identical",
			again.to_board_dict() == clean)


## BT-82 — CUTOUT is excluded from the zone vertex-edit world.
##
## ORACLE: the predicate itself (a direct state read), AND the gesture — a
## right-press while CUTOUT is armed must land on the cutout path, not resolve a
## zone vertex handle. Excluding CUTOUT from the predicate but not from the
## right-press dispatch passes the first leg and reds the second.
func _test_zone_vertex_edit_excludes_cutout() -> void:
	print("\n-- BT-82: _zone_vertex_edit_active() is false while CUTOUT is armed --")
	var canvas = _canvas_with_board()
	var data = canvas.data
	# A selected zone with handles, so the predicate has something to be about.
	data.zones.append({"id": "zone:z", "net": "GND", "layer": "top",
		"kind": "copper_pour", "outline": [
			{"x_mm": 4.0, "y_mm": 4.0}, {"x_mm": 24.0, "y_mm": 4.0},
			{"x_mm": 24.0, "y_mm": 24.0}, {"x_mm": 4.0, "y_mm": 24.0}]})
	canvas.selected_zone_ids.append("zone:z")

	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	check("BT-82 baseline: vertex editing IS active in Select",
			canvas._zone_vertex_edit_active())
	check("BT-82 baseline: …and a corner really does hit a handle",
			not canvas._zone_vertex_hit(Vector2(4.0, 4.0)).is_empty())

	canvas.set_tool_mode(canvas.ToolMode.CUTOUT)
	check("BT-82: the predicate is FALSE while CUTOUT is armed (F1 regression pin)",
			not canvas._zone_vertex_edit_active())
	check("BT-82: …so the same corner resolves NO handle",
			canvas._zone_vertex_hit(Vector2(4.0, 4.0)).is_empty(),
			"a handle was still hit: %s" % str(canvas._zone_vertex_hit(Vector2(4.0, 4.0))))

	canvas.free()


## BT-82, gesture leg — a right-press while CUTOUT is armed cancels the cutout
## draw; it does not hijack into the zone-handle world.
func _test_right_press_while_cutout_armed() -> void:
	print("\n-- BT-82b: right-press while CUTOUT armed hits the cutout path --")
	var canvas = _canvas_with_board()
	canvas.set_tool_mode(canvas.ToolMode.CUTOUT)

	var messages: Array = []
	canvas.cutout_tool_message.connect(func(t: String) -> void: messages.append(t))

	canvas._handle_cutout_click(Vector2(10.0, 10.0), false)
	canvas._handle_cutout_click(Vector2(20.0, 10.0), false)
	check("BT-82b fixture: a cutout is in flight", canvas._cutout_points.size() == 2)

	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	ev.position = canvas.world_to_screen(Vector2(20.0, 10.0))
	canvas._handle_mouse_button(ev)

	check("BT-82b: the right-press CANCELLED the cutout draw",
			canvas._cutout_points.is_empty(),
			"%d points left" % canvas._cutout_points.size())
	check("BT-82b: …and said so", messages.size() == 1, str(messages))
	check("BT-82b: …and it did NOT arm a pan / resolve a zone-menu target "
			+ "(the cutout branch returns first)",
			not canvas.is_panning and canvas._context_menu_vertex.is_empty(),
			"is_panning=%s vertex=%s" % [str(canvas.is_panning),
					str(canvas._context_menu_vertex)])

	canvas.free()


## BT-83 — cutout PREVIEW draws above the copper layer items, while the committed
## cutout BASE draws under everything.
##
## ORACLE, and a correction to the plan's wording: this canvas is IMMEDIATE MODE.
## It has no drawable children, so there are no "canvas child order indices" to
## read — the z-order IS the statement order inside `_draw()`. The oracle used
## here is therefore the ORDER OF THE DRAW CALLS parsed out of the `_draw()`
## function body, which is a representation the drawing code does not itself
## consult (nothing at runtime reads its own source), and which a pixel baseline
## would only re-derive at far higher maintenance cost (see the campaign plan's
## BT-85 note recommending against a render baseline).
func _test_draw_order() -> void:
	print("\n-- BT-83: cutout base under, cutout preview over the copper --")
	var src := FileAccess.get_file_as_string(CANVAS_SRC)
	var body := _draw_body(src)
	check("BT-83: the _draw() body was located", body.length() > 200)

	var i_board := body.find("_draw_board()")
	var i_cutouts := body.find("_draw_cutouts()")
	var i_components := body.find("_draw_components()")
	var i_zones := body.find("_draw_zones()")
	var i_preview := body.find("_draw_cutout_preview()")
	var i_halos := body.find("_draw_cutout_halos()")
	var i_copper := body.find("_draw_copper()")
	check("BT-83: every draw call was found",
			i_board >= 0 and i_cutouts >= 0 and i_components >= 0 and i_zones >= 0
			and i_preview >= 0 and i_halos >= 0 and i_copper >= 0,
			"board=%d cutouts=%d comps=%d zones=%d preview=%d halos=%d copper=%d"
					% [i_board, i_cutouts, i_components, i_zones, i_preview, i_halos,
						i_copper])

	check("BT-83: the committed cutout BASE draws AFTER the board rect",
			i_board < i_cutouts, "board=%d cutouts=%d" % [i_board, i_cutouts])
	check("BT-83: …and UNDER the components (substrate-is-gone reading)",
			i_cutouts < i_components, "cutouts=%d comps=%d" % [i_cutouts, i_components])
	check("BT-83: the PREVIEW draws above the components",
			i_components < i_preview, "comps=%d preview=%d" % [i_components, i_preview])
	check("BT-83: …and above the zones, at the zone-preview depth",
			i_zones < i_preview, "zones=%d preview=%d" % [i_zones, i_preview])
	check("BT-83: the selection HALO sits at the same depth as the preview, "
			+ "above the components", i_components < i_halos)
	check("BT-83: the preview is still BELOW the copper it is being drawn against "
			+ "(copper stays the most legible thing)", i_preview < i_copper,
			"preview=%d copper=%d" % [i_preview, i_copper])


## The text of `func _draw()`'s body, up to the next top-level `func`.
func _draw_body(src: String) -> String:
	var start := src.find("func _draw() -> void:")
	if start < 0:
		return ""
	var stop := src.find("\nfunc ", start + 10)
	if stop < 0:
		stop = src.length()
	return src.substr(start, stop - start)


# ── G3. THE CROSS-LANGUAGE LEG, WIRED ───────────────────────────────────────
#
# BT-81's oracle is "two languages, one contract". The GD half above authored a
# cutout and dropped a serialized board at `user://pcb_cutout_gd_handoff.json`
# — and NOTHING READ IT. The completeness critic recorded the contract as one
# language, not two (gap 6). The D1 oracle-integrity review sharpened it: the GD
# side asserted only `outline.size() == 3` and never the x_mm/y_mm keys that
# Python's `board_validate._check_cutouts` and the Go codec actually require, so
# the serializer could have emitted `{x, y}` (or bare pairs) and stayed green on
# both sides of a hand-off that never happened.
#
# WHY A COMMITTED PAIRED LITERAL AND NOT A GENERATED FILE — the choice, recorded.
# `.github/workflows/pcb.yml` runs the GDScript suite in the `panel` job and
# pytest in `test` / `test-crossplatform` / `oracle`, on SEPARATE runners with
# SEPARATE checkouts. A file one job writes at runtime does not exist for the
# other, and `user://` is not even inside the repo. A generated artifact would
# therefore make the Python half read a file that is EITHER stale (committed
# from some developer's laptop) or absent (regenerated per-job). Both are worse
# than the alternative.
#
# So the hand-off is a COMMITTED FIXTURE that BOTH sides pin:
#   * this test asserts the GDScript serializer produces EXACTLY that content;
#   * `pcb/worker/tests/test_gd_handoff.py` loads the SAME bytes and asserts the
#     Python boundary accepts it and the Python compiler refuses it.
# Neither side can drift without the other going red, which is the contract the
# plan asked for. The fixture is written in JSON — a strict subset of YAML 1.2 —
# so GDScript's JSON parser and Python's `yaml.safe_load` read the identical
# bytes with stock parsers and no shared serializer. (That is also why it carries
# no comments: a `#` comment would be legal YAML and illegal JSON, and only one
# of the two readers would still work.)
#
# The MINTED ID is the one field that cannot be a literal — `mint_entity_id`
# produces fresh randomness per board. It is pinned by SHAPE on both sides
# ("cutout:" + 32 lowercase hex) and normalised to the fixture's id before the
# structural comparison; that is stated here so nobody reads the substitution as
# the test excusing itself.
const HANDOFF_FIXTURE := "res://../../minerva-plugins/pcb/worker/tests/testdata/gd_handoff_cutout.yaml"
const MINTED_ID_PATTERN := "^cutout:[0-9a-f]{32}$"


func _test_cross_language_handoff() -> void:
	print("\n-- G3 (BT-81 cross-language): the GD serializer matches the shared fixture --")
	var text := FileAccess.get_file_as_string(HANDOFF_FIXTURE)
	check("G3: the shared fixture is readable from the repo", text.length() > 50,
			HANDOFF_FIXTURE)
	var parsed: Variant = JSON.parse_string(text)
	check("G3: …and parses (JSON body, so BOTH languages read the same bytes)",
			parsed is Dictionary)
	if not (parsed is Dictionary):
		return
	var fixture: Dictionary = parsed

	# Author the SAME board through the tool path — three clicks and the closing
	# double-click, exactly the grammar BT-81 exercises above.
	var canvas = PcbCanvasScript.new()
	var data = PCBData.new()
	data.from_board_dict({
		"version": 1, "name": "GDHandoffCutout", "width_mm": 40.0, "height_mm": 30.0,
		"design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2,
			"via_diameter_mm": 0.6, "via_drill_mm": 0.3},
	})
	canvas.data = data
	canvas.snap_to_grid = false
	canvas.set_tool_mode(canvas.ToolMode.CUTOUT)
	canvas._handle_cutout_click(Vector2(8.0, 6.0), false)
	canvas._handle_cutout_click(Vector2(16.0, 6.0), false)
	canvas._handle_cutout_click(Vector2(16.0, 14.0), false)
	canvas._handle_cutout_click(Vector2(16.0, 14.0), true)

	var produced: Dictionary = data.to_board_dict()
	check("G3 fixture: the tool path minted exactly one cutout",
			(produced.get("cutouts", []) as Array).size() == 1, str(produced.get("cutouts", [])))

	# ── THE KEY CONTRACT, spelled out rather than implied by the deep compare, so
	# a failure says WHICH key went missing.
	var cut: Dictionary = (produced["cutouts"] as Array)[0]
	var cut_keys: Array = cut.keys()
	cut_keys.sort()
	check("G3: a serialized cutout carries exactly {id, outline} (%s)" % str(cut_keys),
			cut_keys == ["id", "outline"])
	var re := RegEx.new()
	re.compile(MINTED_ID_PATTERN)
	check("G3: its id is a minted persistent id (%s)" % str(cut.get("id", "")),
			re.search(str(cut.get("id", ""))) != null)
	var pts: Array = cut.get("outline", [])
	check("G3: the outline is a 3-point polygon (Python's invalid_cutout_outline floor)",
			pts.size() == 3, str(pts))
	var bad_point_keys: Array = []
	for p in pts:
		if not (p is Dictionary):
			bad_point_keys.append(str(p))
			continue
		var pk: Array = (p as Dictionary).keys()
		pk.sort()
		if pk != ["x_mm", "y_mm"]:
			bad_point_keys.append(str(pk))
	# THE key contract the GD half never pinned: mm-suffixed, not {x, y}.
	check("G3: every outline point carries exactly {x_mm, y_mm} (bad: %s)"
			% str(bad_point_keys), bad_point_keys.is_empty())

	# ── the whole-board comparison, id-normalised.
	var fixture_cut: Dictionary = ((fixture.get("cutouts", []) as Array)[0] as Dictionary) \
			if not (fixture.get("cutouts", []) as Array).is_empty() else {}
	check("G3: the FIXTURE's id has the same minted shape (both sides pin it)",
			re.search(str(fixture_cut.get("id", ""))) != null,
			str(fixture_cut.get("id", "")))
	var normalised: Dictionary = produced.duplicate(true)
	((normalised["cutouts"] as Array)[0] as Dictionary)["id"] = fixture_cut.get("id", "")

	# COMPARED AS WRITTEN, NOT AS HELD. Both sides go through the same JSON
	# encode/decode the hand-off itself goes through, for a measured reason:
	# GDScript's Dictionary deep-equality is TYPE-STRICT (int 1 and float 1.0 are
	# NOT equal to it, though `1 == 1.0` is true on the scalars), while
	# JSON.parse_string returns EVERY number as a float. Comparing the in-memory
	# dict against the parsed fixture therefore reds on `"version": 1` alone —
	# a difference that does not survive being written to the file and would be a
	# pure false alarm. Round-tripping both through JSON compares what actually
	# crosses the language boundary, and `JSON.stringify` sorts keys, so the two
	# strings below are a canonical byte-for-byte comparison.
	var as_written: Variant = JSON.parse_string(JSON.stringify(normalised))
	check("G3: the GD serializer's output IS the shared fixture, key for key",
			as_written == fixture,
			"produced=%s\n  fixture=%s" % [JSON.stringify(as_written), JSON.stringify(fixture)])
	check("G3: …byte-for-byte, in canonical (sorted-key) form",
			JSON.stringify(as_written) == JSON.stringify(fixture),
			"produced=%s\n  fixture=%s" % [JSON.stringify(as_written), JSON.stringify(fixture)])

	canvas.free()
