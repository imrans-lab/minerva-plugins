extends SceneTree
## A PCB TAB'S NOTE CARRIES THE BOARD, NOT A PICTURE OF ONE.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_pcb_note_hooks.gd
##
## THE DEFECT. A PCB tab implemented neither plugin-note hook, so Save to Note
## and the chat-inject toggle fell to the host's default
## (Editor._create_plugin_scene_screenshot_note): a screenshot of the panel
## viewport as a flat image note. That note carries no board — Edit cannot
## reopen it — and it shows the live camera, so a tab zoomed in on one connector
## injected that connector into the chat as "the board".
##
## WHAT THIS PINS.
##
##   1. THE PAYLOAD IS THE SAVED BOARD. Not a screenshot, not a path: the same
##      dict _on_panel_save_request writes. The oracle is a WHOLE-BOARD TOKEN —
##      PCBPanel._whole_board_token, a SHA-256 over the canonical dict with key
##      order normalised, code neither hook touches — taken over the source
##      board and over a FRESH model restored from the note. Equal tokens mean
##      every component, net, trace, via, rule and stage came back.
##
##      The token is taken over the SAVED form on both sides, because that is
##      what the note carries and the difference is deliberate: footprint_
##      resolved says a resolve succeeded against THIS machine's library, and a
##      note travelling to another machine must not assert it. Section 1 reads
##      that flag on both sides rather than leaving it to the token.
##
##   2. THE PREVIEW IS FIT TO THE BOARD. The capture pcb_note asks for is sized
##      to the board's own aspect at a long edge that leaves a 1 mm designator
##      several pixels tall — not the live camera, not the pane's aspect.
##
##      NOT A SCREENSHOT, of necessity: headless Godot has no rendering device
##      and pcb_canvas.capture_to_image returns null there by design. What
##      is observable is the capture the module ASKS FOR, so CaptureCanvas below
##      records the size and the fit flag and returns a real Image of exactly
##      that size — the assertions then read the note's own preview_image.
##
##   3. THE CAPTION IS THE BOARD'S OWN FACTS. Name, size, stack, stage, four
##      counts, source path — asserted as one exact string computed BY HAND from
##      the fixture below, because alt text IS the note for a provider with no
##      image channel.
##
##   4. A NOTE THIS PANEL DID NOT WRITE IS REFUSED, and refused without
##      touching the board that is loaded.
##
## FAILS AGAINST OLD: PCBPanel implemented neither hook and pcb_note.gd did not
## exist, so build_note/restore_board have nowhere to resolve.

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbNote := preload("res://../../minerva-plugins/pcb/ui/pcb_note.gd")
const PcbViewFit := preload("res://../../minerva-plugins/pcb/ui/pcb_view_fit.gd")

## Loaded rather than preloaded, the way the other suites reach the panel: this
## is the ONE thing taken from PCBPanel — the whole-board token the round trip
## is judged by.
var PanelScript: Variant = load("res://../../minerva-plugins/pcb/ui/PCBPanel.gd")

const FP := "Resistor_SMD:R_0805_2012Metric"
const SOURCE_PATH := "/tmp/pcb-note-hooks/note_hooks_board.yaml"
const CTX := {"plugin_id": "pcb", "panel_name": "pcb_panel", "tab_title": "note-hooks"}

## Hand-computed from _fixture_board(): name, then size + stack + stage, then
## the four counts (1 net / 1 trace / 1 via exercise the singular forms, 2
## components the plural), then the adopted source. Millimetre figures carry no
## trailing zeros.
const EXPECTED_CAPTION := "note-hooks — 60 x 40 mm, 4 layers, stage vias_only" \
	+ " — 2 components, 1 net, 1 trace, 1 via — " + SOURCE_PATH

## A 1 mm silk designator must survive the preview. 8 px is the floor; the
## fixture's 60 mm board is far above it (1536 / 60 = 25.6 px per mm).
const MIN_PREVIEW_PX_PER_MM := 8.0
const EPS := 0.001

var _pass := 0
var _fail := 0


## The capture stand-in — see §2 of the header for why the pixels cannot be
## real here. It answers the one method pcb_note calls, records what was asked
## for, and returns an Image of exactly the requested size.
class CaptureCanvas extends RefCounted:
	var last_width: int = 0
	var last_height: int = 0
	var last_fit: bool = false
	var calls: int = 0

	func capture_to_image(width: int, height: int, fit: bool = true) -> Image:
		calls += 1
		last_width = width
		last_height = height
		last_fit = fit
		var img := Image.create(width, height, false, Image.FORMAT_RGB8)
		img.fill(Color(0.05, 0.15, 0.05))
		return img


func _init() -> void:
	print("=== A PCB tab's note carries the board ===\n")
	await _run_the_note_carries_the_saved_board()
	await _run_restore_into_a_fresh_model()
	await _run_the_preview_is_fit_to_the_board()
	await _run_the_caption_is_the_board_itself()
	await _run_a_foreign_payload_is_refused()
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


# ── fixture ───────────────────────────────────────────────────────────────────

## A small four-layer board carrying one of everything the caption counts, with
## every entity id stated so nothing is minted on the way back. R1 owns its
## geometry (a `pads` key) and is flagged resolved-against-this-library, which
## is the session state the note must NOT carry.
func _fixture_board() -> Dictionary:
	return {
		"version": 1,
		"name": "note-hooks",
		"width_mm": 60.0, "height_mm": 40.0,
		"layers": ["top", "inner1", "inner2", "bottom"],
		"design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
			"via_diameter_mm": 0.8, "via_drill_mm": 0.4},
		"fabrication_stage": "vias_only",
		"components": [
			{
				"ref": "R1", "footprint": FP, "value": "1k",
				"x_mm": 12.0, "y_mm": 10.0, "rotation_deg": 0.0, "layer": "top",
				"footprint_resolved": true,
				"pins": [{"number": "1", "x_mm": -0.9125, "y_mm": 0.0},
					{"number": "2", "x_mm": 0.9125, "y_mm": 0.0}],
				"pads": [
					{"number": "1", "type": "smd", "shape": "roundrect",
						"position": {"x": -0.9125, "y": 0.0},
						"size": {"width": 1.025, "height": 1.4},
						"layers": ["F.Cu", "F.Mask", "F.Paste"],
						"drill": {"x": 0.0, "y": 0.0}},
					{"number": "2", "type": "smd", "shape": "roundrect",
						"position": {"x": 0.9125, "y": 0.0},
						"size": {"width": 1.025, "height": 1.4},
						"layers": ["F.Cu", "F.Mask", "F.Paste"],
						"drill": {"x": 0.0, "y": 0.0}},
				],
				"graphics": [{"kind": "poly", "layer": "F.CrtYd", "width": 0.05,
					"points": [{"x": -1.68, "y": -0.95}, {"x": 1.68, "y": -0.95},
						{"x": 1.68, "y": 0.95}, {"x": -1.68, "y": 0.95}]}],
			},
			{
				"ref": "R2", "footprint": FP, "value": "10k",
				"x_mm": 30.0, "y_mm": 22.0, "rotation_deg": 90.0, "layer": "top",
				"pins": [{"number": "1", "x_mm": -0.9125, "y_mm": 0.0},
					{"number": "2", "x_mm": 0.9125, "y_mm": 0.0}],
			},
		],
		"nets": [{"name": "NET1", "pins": ["R1.2", "R2.1"]}],
		"traces": [{"id": "trace:aa00", "net": "NET1", "layer": "top",
			"width_mm": 0.3,
			"points": [{"x_mm": 12.9125, "y_mm": 10.0},
				{"x_mm": 30.0, "y_mm": 21.0875}]}],
		"vias": [{"id": "via:bb11", "x_mm": 20.0, "y_mm": 16.0,
			"diameter_mm": 0.8, "drill_mm": 0.4, "net": "NET1",
			"from_layer": "top", "to_layer": "bottom"}],
	}


## A board loaded the way the panel's YAML import loads one: with this host's
## resolve beside it, so the session-only footprint_resolved flag is genuinely
## live on R1 (on the model — never on the dict).
func _loaded_fixture():
	var data = PCBData.new()
	data.from_board_dict(_fixture_board(), {"R1": {"footprint_resolved": true}})
	return data


## The whole-board token over the SAVED form — the shape the note carries. See
## §1 of the header for why the session-only key is excluded on both sides.
func _saved_token(data) -> String:
	return PanelScript._whole_board_token(PCBData.strip_session_state(data.to_board_dict()))


func _counts(data) -> Array:
	return [data.get_component_count(), data.get_net_count(),
		data.get_trace_count(), data.vias.size()]


# ── sections ──────────────────────────────────────────────────────────────────

func _run_the_note_carries_the_saved_board() -> void:
	print("-- 1/5. the note a tab hands the host is a plugin_data note carrying the saved board --")
	var data = _loaded_fixture()
	var canvas := CaptureCanvas.new()
	var note: Dictionary = await PcbNote.build_note(CTX, data, canvas, SOURCE_PATH)

	check("it is a plugin_data note, addressed to the pcb panel the ctx names",
		str(note.get("kind", "")) == "plugin_data"
			and str(note.get("plugin_id", "")) == "pcb"
			and str(note.get("panel_name", "")) == "pcb_panel")

	var payload: Dictionary = note.get("payload", {}) if note.get("payload", null) is Dictionary else {}
	check("its payload declares the schema and carries a board dict",
		int(payload.get("version", 0)) == PcbNote.PAYLOAD_VERSION
			and payload.get("board", null) is Dictionary)

	var board: Dictionary = payload.get("board", {})

	var live_r1 = data.get_component("R1")
	check("…and this machine's library resolution is left behind: live on the board (%s), absent from the note"
			% str(live_r1.footprint_resolved),
		bool(live_r1.footprint_resolved)
			and not (board["components"][0] as Dictionary).has("footprint_resolved"))

	check("the payload names the canonical source the board was adopted from",
		str(payload.get("source_path", "")) == SOURCE_PATH)


func _run_restore_into_a_fresh_model() -> void:
	print("-- 2/5. restoring the note into a FRESH model reproduces the same board --")
	var data = _loaded_fixture()
	var note: Dictionary = await PcbNote.build_note(CTX, data, CaptureCanvas.new(), SOURCE_PATH)
	var payload: Dictionary = note.get("payload", {})

	var fresh = PCBData.new()
	check("the fresh model is a DIFFERENT board before the restore (the control)",
		_saved_token(fresh) != _saved_token(data))

	check("the restore accepts the note this panel wrote",
		PcbNote.restore_board(payload, fresh))
	check("the restored board is the source board — same whole-board token",
		_saved_token(fresh) == _saved_token(data))
	check("…including every population count (%s vs %s)" % [str(_counts(fresh)), str(_counts(data))],
		_counts(fresh) == _counts(data))


func _run_the_preview_is_fit_to_the_board() -> void:
	print("-- 3/5. the preview is the whole board, fitted, at a legible resolution --")
	var data = _loaded_fixture()
	var canvas := CaptureCanvas.new()
	var note: Dictionary = await PcbNote.build_note(CTX, data, canvas, SOURCE_PATH)
	var preview: Variant = note.get("preview_image", null)

	check("the note carries a non-empty preview Image",
		preview is Image and not (preview as Image).is_empty())

	var img: Image = preview as Image
	var board_aspect: float = float(data.board_width) / float(data.board_height)
	var image_aspect: float = float(img.get_width()) / float(img.get_height())
	check("its aspect is the BOARD's (%.4f vs %.4f), so nothing is spent on letterboxing"
			% [image_aspect, board_aspect],
		absf(image_aspect - board_aspect) < 0.01)

	check("the capture was asked to FIT — the whole board, not the live camera",
		canvas.calls == 1 and canvas.last_fit)

	check("its long edge is the full preview resolution (%d x %d)" % [img.get_width(), img.get_height()],
		maxi(img.get_width(), img.get_height()) == PcbNote.PREVIEW_LONG_EDGE_PX)

	var px_per_mm: float = float(img.get_width()) / float(data.board_width)
	check("…so a 1 mm designator lands %.1f px tall, past the %.0f px floor"
			% [px_per_mm, MIN_PREVIEW_PX_PER_MM],
		px_per_mm >= MIN_PREVIEW_PX_PER_MM)

	# The fit the capture will perform is over pcb_view_fit's content rect, not
	# the bare board rect. On this fixture the parts sit inside the outline, so
	# the two are the same rect and the aspect asserted above is the fit's.
	var content: Rect2 = PcbViewFit.board_content_rect(data)
	check("the fitted content IS the board outline here — both parts sit inside it",
		absf(content.size.x - float(data.board_width)) < EPS
			and absf(content.size.y - float(data.board_height)) < EPS)


func _run_the_caption_is_the_board_itself() -> void:
	print("-- 4/5. the alt text is the board's own facts, and nothing is computed for it --")
	var data = _loaded_fixture()
	var note: Dictionary = await PcbNote.build_note(CTX, data, CaptureCanvas.new(), SOURCE_PATH)
	check("the caption reads exactly as hand-computed from the fixture — got %s"
			% str(note.get("preview_alt_text", "")),
		str(note.get("preview_alt_text", "")) == EXPECTED_CAPTION)

	var unsaved: Dictionary = await PcbNote.build_note(CTX, data, CaptureCanvas.new(), "")
	check("a board with no adopted source ends at the counts, with no empty path hung on it",
		str(unsaved.get("preview_alt_text", ""))
			== EXPECTED_CAPTION.substr(0, EXPECTED_CAPTION.length() - SOURCE_PATH.length() - 3))
	check("…and its payload carries no source_path at all",
		not (unsaved.get("payload", {}) as Dictionary).has("source_path"))


func _run_a_foreign_payload_is_refused() -> void:
	print("-- 5/5. a payload this panel did not write is refused, and refuses without damage --")
	var data = _loaded_fixture()
	var before: String = _saved_token(data)

	check("a payload from another schema version is refused",
		not PcbNote.restore_board({"version": 99, "board": {"name": "other"}}, data))
	check("…and the board that was loaded is untouched",
		_saved_token(data) == before)
	check("a payload whose board is not a Dictionary is refused",
		not PcbNote.restore_board({"version": PcbNote.PAYLOAD_VERSION, "board": "a board"}, data))

	# No canvas (headless, or a panel not yet mounted): the note must still be a
	# plugin_data note — the host backfills its own screenshot for the missing
	# preview, so the round trip survives a capture that could not run.
	var no_canvas: Dictionary = await PcbNote.build_note(CTX, data, null, SOURCE_PATH)
	check("a note built with no canvas is still a plugin_data note with the board and the caption",
		str(no_canvas.get("kind", "")) == "plugin_data"
			and (no_canvas.get("payload", {}) as Dictionary).get("board", null) is Dictionary
			and str(no_canvas.get("preview_alt_text", "")) == EXPECTED_CAPTION)
	check("…and it omits preview_image rather than carrying an empty one",
		not no_canvas.has("preview_image"))
