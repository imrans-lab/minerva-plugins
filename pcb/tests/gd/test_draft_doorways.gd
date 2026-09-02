extends SceneTree
## Epoch UX4 station 7 (docket 019fe081c966; DCR 019fe07523ca S7, A8):
## the authoring-destination flag and the Proposals-area draft doorways —
## one gesture, two doorways, ONE commit-site branch.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_draft_doorways.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const CANVAS_PATH := "res://../../minerva-plugins/pcb/ui/pcb_canvas.gd"

var _pass := 0
var _fail := 0


class FakeEditor extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== Draft doorways: authoring destination + Proposals-area toggles ===\n")
	await process_frame
	await _run_destination_lifecycle()
	await _run_radio_families()
	await _run_commit_branch_zone()
	await _run_commit_branch_cutout()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


func _board() -> Dictionary:
	return {
		"version": 1, "name": "doorways", "width_mm": 40.0, "height_mm": 40.0,
		"design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [], "nets": [{"name": "GND", "pins": []}],
		"traces": [], "vias": [],
	}


func _mount_panel() -> Control:
	var panel: Control = load(PANEL_PATH).new()
	get_root().add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(700, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_board())
	for _i in range(6):
		await process_frame
	return panel


func _teardown(panel: Control) -> void:
	panel.queue_free()


# ── 1. destination lifecycle: one arming press, never outlives it ─────────────

func _run_destination_lifecycle() -> void:
	print("-- 1. destination lifecycle --")
	var panel := await _mount_panel()
	var canvas = panel._canvas
	var Modes = load(CANVAS_PATH).ToolMode

	check_eq("resting destination is DIRECT", str(canvas.authoring_destination), "direct")

	panel._toggle_draft_tool(Modes.ZONE_KEEPOUT)
	check_eq("draft toggle arms the tool", int(canvas.tool_mode), int(Modes.ZONE_KEEPOUT))
	check_eq("…as DRAFT", str(canvas.authoring_destination), "draft")

	# Any tool CHANGE resets the destination.
	canvas.set_tool_mode(Modes.CUTOUT)
	check_eq("switching tools resets to DIRECT", str(canvas.authoring_destination), "direct")

	# Re-click on the armed draft toggle disarms to Select + direct.
	panel._toggle_draft_tool(Modes.CUTOUT)
	check_eq("(fixture) cutout draft-armed", str(canvas.authoring_destination), "draft")
	panel._toggle_draft_tool(Modes.CUTOUT)
	check_eq("re-click disarms to Select", int(canvas.tool_mode), int(Modes.SELECT))
	check_eq("…and the destination is DIRECT again", str(canvas.authoring_destination), "direct")

	# Cross-family same-mode press = a DESTINATION switch, not a disarm.
	panel._toggle_draft_tool(Modes.ZONE_POUR)
	panel._toggle_tool_mode(Modes.ZONE_POUR)
	check_eq("direct press on a draft-armed mode keeps the tool", int(canvas.tool_mode), int(Modes.ZONE_POUR))
	check_eq("…switching destination to DIRECT", str(canvas.authoring_destination), "direct")
	panel._toggle_draft_tool(Modes.ZONE_POUR)
	check_eq("draft press on a direct-armed mode keeps the tool", int(canvas.tool_mode), int(Modes.ZONE_POUR))
	check_eq("…switching destination to DRAFT", str(canvas.authoring_destination), "draft")
	_teardown(panel)


# ── 2. the radio shows WHICH doorway armed the tool ───────────────────────────

func _run_radio_families() -> void:
	print("-- 2. radio families: exactly one family lights --")
	var panel := await _mount_panel()
	var Modes = load(CANVAS_PATH).ToolMode
	var direct_btn: Button = panel._tool_buttons[Modes.ZONE_KEEPOUT]
	var draft_btn: Button = panel._draft_tool_buttons[Modes.ZONE_KEEPOUT]

	panel._toggle_tool_mode(Modes.ZONE_KEEPOUT)
	check("direct arm lights the Tools button", direct_btn.button_pressed)
	check("…not the draft toggle", not draft_btn.button_pressed)

	panel._toggle_draft_tool(Modes.ZONE_KEEPOUT)
	check("draft arm lights the draft toggle", draft_btn.button_pressed)
	check("…and releases the Tools button", not direct_btn.button_pressed)

	panel._toggle_draft_tool(Modes.ZONE_KEEPOUT)
	check("disarm releases both", not draft_btn.button_pressed and not direct_btn.button_pressed)
	_teardown(panel)


# ── 3. the ONE commit-site branch: zone ───────────────────────────────────────

func _run_commit_branch_zone() -> void:
	print("-- 3. zone commit: DRAFT stages a ghost, DIRECT writes the board --")
	var panel := await _mount_panel()
	var canvas = panel._canvas
	var data = panel.get_data()
	var store = panel.get_staged_store()
	var Modes = load(CANVAS_PATH).ToolMode

	# DRAFT commit: no board write, no history entry, one live ghost.
	panel._toggle_draft_tool(Modes.ZONE_KEEPOUT)
	var hist_before: int = data.history.size()
	canvas._zone_points = PackedVector2Array([Vector2(2, 2), Vector2(8, 2), Vector2(8, 8)])
	canvas._commit_zone()
	check_eq("DRAFT commit writes NO board zone", data.zones.size(), 0)
	check_eq("…adds NO history entry (staging is not a board mutation)",
		data.history.size(), hist_before)
	check_eq("…and stages ONE live ghost", store.staged_payloads("zone").size(), 1)
	var ghost: Dictionary = store.staged_payloads("zone")[0]
	check_eq("…of the armed kind", str(ghost.get("kind", "")), "keepout")
	check_eq("…authored as human (the canvas doorway)", str(
		(store.get_entry(store.staged_id_for_entity(str(ghost.get("id", "")))) as Dictionary)
			.get("author", "")), "human")
	check("the draw state reset (commit consumed the polygon)", canvas._zone_points.is_empty())

	# DIRECT commit of the same gesture: board write + history, no new ghost.
	panel._toggle_tool_mode(Modes.ZONE_KEEPOUT)
	canvas._zone_points = PackedVector2Array([Vector2(12, 12), Vector2(18, 12), Vector2(18, 18)])
	canvas._commit_zone()
	check_eq("DIRECT commit writes the board", data.zones.size(), 1)
	check_eq("…with a history entry", data.history.size(), hist_before + 1)
	check_eq("…and stages nothing new", store.staged_payloads("zone").size(), 1)
	_teardown(panel)


# ── 4. the ONE commit-site branch: cutout ─────────────────────────────────────

func _run_commit_branch_cutout() -> void:
	print("-- 4. cutout commit: same branch, same contract --")
	var panel := await _mount_panel()
	var canvas = panel._canvas
	var data = panel.get_data()
	var store = panel.get_staged_store()
	var Modes = load(CANVAS_PATH).ToolMode

	panel._toggle_draft_tool(Modes.CUTOUT)
	var hist_before: int = data.history.size()
	canvas._cutout_points = PackedVector2Array([Vector2(20, 20), Vector2(26, 20), Vector2(26, 26)])
	canvas._commit_cutout()
	check_eq("DRAFT commit writes NO board cutout", data.cutouts.size(), 0)
	check_eq("…no history entry", data.history.size(), hist_before)
	check_eq("…one live cutout ghost", store.staged_payloads("cutout").size(), 1)

	panel._toggle_tool_mode(Modes.CUTOUT)
	canvas._cutout_points = PackedVector2Array([Vector2(30, 30), Vector2(36, 30), Vector2(36, 36)])
	canvas._commit_cutout()
	check_eq("DIRECT commit writes the board", data.cutouts.size(), 1)
	check_eq("…with a history entry", data.history.size(), hist_before + 1)
	check_eq("…and stages nothing new", store.staged_payloads("cutout").size(), 1)
	_teardown(panel)
