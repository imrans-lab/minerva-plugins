extends SceneTree
## THE FAB PREVIEW A HUMAN CAN ACTUALLY READ (bug: the emitted-artwork overlay
## was unreadable, and the flag stayed up over stale artwork).
##
## The preview is the WYSIWYG gate before fabrication and the only human who
## checks it works entirely from the GUI, so an unreadable preview does not
## merely look bad — the gate fails OPEN. What
## shipped was black-on-transparent artwork (gerbonara renders fg="black" on a
## root style Godot ignores) rasterized at the SVG's intrinsic mm-at-96dpi size,
## so 0.12 mm silk was sub-pixel, ten layers were composited into one smear, and
## the identity header was drawn ON the board it described.
##
## ORACLES, and where each number comes from:
##
##   1. CONTRAST IS RECOMPUTED, NEVER ASSERTED FROM THE TABLE. Section 1 walks
##      the palette and measures WCAG relative luminance, so a future palette
##      edit that darkens an ink reds here. The end-to-end measurement runs a
##      VERBATIM emitted silk layer (worker fab_preview output, captured below)
##      through the production recolour + rasterize path and samples the
##      rasterized PIXEL — at a coordinate solved from the fixture's OWN path
##      geometry, so the assertion reads the stroke rather than whatever the
##      alpha channel happens to peak at.
##
##      NOT A SCREENSHOT, deliberately and of necessity: headless Godot has no
##      rendering device, and minerva_pcb_get_image degrades to a null envelope
##      there (pinned by test_pcb_panel_tools). Image.load_svg_from_string is
##      CPU rasterization and DOES run headless, so the pixel sampled here is
##      the same pixel draw_texture_rect would put on screen; the draw-time
##      modulate alpha is applied by the same PcbFabPreview.draw_alpha the draw
##      uses, over the same ground PcbFabPreview.draw paints.
##
##   2. THE BANNER IS NOT ON THE BOARD. Section 2 asserts banner_rect and
##      art_rect do not intersect at the 554 px panel width the complaint was
##      raised at, and that the artwork keeps its aspect.
##
##   3. ONE LAYER AT A TIME, REACHABLE FROM BOTH SURFACES. Sections 3 and 4:
##      the picker's vocabulary comes from the artifact set, the View menu's
##      ids invert exactly, and minerva_pcb_view_state reads and writes the
##      same value through the same setter.
##
##   3b. THE PREVIEW IS A VIEW, NOT A PICTURE. Section 6 drives the real
##      camera: the artwork is placed through the same world-to-screen
##      transform the editor's own view uses, so it MOVES with a pan and GROWS
##      with a zoom — two observations of the same rect at two camera states,
##      which a fixed letterbox cannot satisfy. The same section drives a real
##      drag through the canvas's own _gui_input twice — once with the preview
##      down, once with it up — and reads the BOARD DICT after each. The
##      preview-down arm is the control that proves the gesture is an edit at
##      all; the preview-up arm is the claim.
##
##   4. A STALE PREVIEW RETRACTS ITS FLAG, AND ONLY A STALE ONE. Section 5
##      drives both stale paths for real — a board edit under a live preview,
##      and a board that moves while the worker is running — and reads the
##      flag, the human's status lead and the agent's overlay_unavailable.
##      Section 7 drives the other side: the canonical board dict IS what the
##      worker renders from, so a re-load of the same board, an MCP preference
##      write and a view change leave the preview standing, while a component
##      move and a board resize take it down.
##
##   5. A FITTED CAPTURE FRAMES WHAT THE SCREEN FRAMES. Section 8 runs the
##      capture's own framing decision over a real copy canvas and compares the
##      camera it produces with the camera on screen — with the no-preview
##      board fit as the control, which is a DIFFERENT camera and is what made
##      the seam real.
##
##   6. THE DARK INKS ARE STILL MARKS. Section 9: holes are black and the
##      outline dark purple because both are absences of material, so both are
##      rasterized in the rim colour and tinted at draw time. The rasterized
##      pixel and the modulate are measured, and the picker's swatches are read
##      out of a real PopupMenu.
##
## Run: godot --headless --path src --script \
##   res://../../minerva-plugins/pcb/tests/gd/test_fab_preview_legibility.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const FabPreview := preload("res://../../minerva-plugins/pcb/ui/model/pcb_fab_preview.gd")
const OverlayFetch := preload("res://../../minerva-plugins/pcb/ui/model/pcb_overlay_fetch.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbViewFit := preload("res://../../minerva-plugins/pcb/ui/pcb_view_fit.gd")

var PanelTools: Variant = load("res://../../minerva-plugins/pcb/ui/panel_tools.gd")

## WCAG AA for normal text. The reported defect was artwork "below human
## reading capability", so this is the bar the fix is held to.
const MIN_CONTRAST := 4.5
## WCAG 1.4.11 for non-text graphics. The composite view's under-layers are
## held to this and not to MIN_CONTRAST — see PcbFabPreview.UNDER_ALPHA for why
## one bar cannot cover both views.
const MIN_GRAPHIC_CONTRAST := 3.0

## The panel width the preview was found unreadable at.
const PANEL_W := 554.0
const PANEL_H := 420.0

## VERBATIM worker output — pcb.fab_preview on pcb/spikes/gerber/board.yaml,
## the F_SilkS layer, truncated to two strokes. Copied rather than regenerated
## so this suite pins the SHAPE the worker actually emits (fill="none",
## stroke="black", stroke-width in mm, a root style the engine ignores). A
## paraphrased fixture would keep passing after gerbonara changed its output.
const SILK_SVG := """<?xml version="1.0" encoding="utf-8"?>
<svg width="40.05mm" height="30.049999999999997mm" viewBox="-0.025 -30.025 40.05 30.049999999999997" style="background-color:white" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
  <g transform="translate(-0.025 0.025) scale(1 -1) translate(0.025 30.025)">
    <path d="M 9.773 -9.265 L 10.227 -9.265" fill="none" stroke="black" stroke-linecap="round" stroke-linejoin="round" stroke-width="0.12"/>
    <path d="M 4.0 -15.0 L 36.0 -15.0" fill="none" stroke="black" stroke-linecap="round" stroke-linejoin="round" stroke-width="0.12"/>
  </g>
</svg>"""

## WHERE THAT STROKE IS, in the same path coordinates written above: the long
## stroke's two ends, and a point that lies on NEITHER stroke. Sampling a KNOWN
## coordinate is what makes 1h an assertion about the stroke — a whole-image
## alpha maximum is satisfied by an opaque ground, or by any other ink, with
## the stroke entirely absent.
const STROKE_A := Vector2(4.0, -15.0)
const STROKE_B := Vector2(36.0, -15.0)
const OFF_STROKE := Vector2(20.0, -25.0)

## The fixture's own viewBox, verbatim from its header — the second half of the
## path-to-pixel mapping.
const VIEWBOX_MIN := Vector2(-0.025, -30.025)
const VIEWBOX_SIZE := Vector2(40.05, 30.049999999999997)

## Half the sampling window, in pixels. A 0.12 mm stroke across a 40.05 mm
## viewBox is under 2 px at these raster widths, so the window absorbs the
## rounding between the exact coordinate and the pixel grid while staying far
## narrower than the gap to the other stroke.
const SAMPLE_R := 2

## A 10 x 300 mm board outline — the 1:30 aspect a WIDTH-only raster cap lets
## through. Taken to MAX_RASTER_PX wide it would be 48000 px tall.
const TALL_SVG := """<?xml version="1.0" encoding="utf-8"?>
<svg width="10mm" height="300mm" viewBox="0 0 10 300" style="background-color:white" xmlns="http://www.w3.org/2000/svg">
  <path d="M 0.5 0.5 L 9.5 0.5 L 9.5 299.5 L 0.5 299.5 Z" fill="none" stroke="black" stroke-linecap="round" stroke-width="0.12"/>
</svg>"""

## A 5000 x 200 mm outline: the case where the INTRINSIC raster is already over
## the caps. mm resolved at 96 dpi is ~18900 px wide before any scaling, so this
## is the shape a raster step that only ever scales UP hands straight through.
const OVERSIZED_SVG := """<?xml version="1.0" encoding="utf-8"?>
<svg width="5000mm" height="200mm" viewBox="0 0 5000 200" style="background-color:white" xmlns="http://www.w3.org/2000/svg">
  <path d="M 0.5 0.5 L 4999.5 0.5 L 4999.5 199.5 L 0.5 199.5 Z" fill="none" stroke="black" stroke-linecap="round" stroke-width="0.12"/>
</svg>"""

## The emitted filenames of a real ten-layer board, in EMISSION order (not draw
## order) so the sort under test has something to do.
const EMITTED := [
	"GerberSpikeBoard-F_Cu.gbr", "GerberSpikeBoard-B_Cu.gbr",
	"GerberSpikeBoard-F_Paste.gbr", "GerberSpikeBoard-B_Paste.gbr",
	"GerberSpikeBoard-F_Mask.gbr", "GerberSpikeBoard-B_Mask.gbr",
	"GerberSpikeBoard-F_SilkS.gbr", "GerberSpikeBoard-B_SilkS.gbr",
	"GerberSpikeBoard-Edge_Cuts.gbr",
	"GerberSpikeBoard-PTH.drl", "GerberSpikeBoard-NPTH.drl",
]

var _fail := 0
var _passed := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, ("" if detail == "" else " — " + detail)])


class FakeEditor extends RefCounted:
	var tab_title: String = ""


## Capture-only IPC (same seam idiom as test_board_by_path.gd's CaptureIPC):
## records what the panel emitted and answers with a canned reply, so the REAL
## sender runs to completion. `on_reply` is the hook this suite adds — it fires
## between the request and the answer, which is the only place a board can move
## "while the worker is running".
class FabIPC extends Node:
	var captured: Array = []
	var overrides: Dictionary = {}
	var on_reply: Callable = Callable()
	var _reply_id := ""
	var _last_channel := ""

	func bind(panel_node) -> void:
		name = "_MinervaIPC"
		panel_node.add_child(self)
		panel_node.request.connect(_on_request)

	func _on_request(channel: String, payload: Dictionary, reply_id: String) -> void:
		captured.append({"channel": channel, "payload": payload})
		_reply_id = reply_id
		_last_channel = channel

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id:
			return {"success": false, "error_code": "timeout",
				"error_message": "no captured request"}
		if on_reply.is_valid():
			on_reply.call(_last_channel)
		if overrides.has(_last_channel):
			return {"success": true,
				"result": {"ok": true, "result": overrides[_last_channel]}}
		return {"success": true, "result": {"ok": true, "result": {
			"success": true, "routes": [], "unrouted": [], "yaml": "name: canned",
			"status": "pass", "findings": [],
			"assembly": {"status": "pass", "findings": []},
			"warnings": []}}}


func _tiny_board(board_name: String = "legibility") -> Dictionary:
	return {"version": 1, "name": board_name, "width_mm": 40.0, "height_mm": 30.0,
		"layers": ["top", "bottom"], "components": [],
		"nets": [{"name": "GND", "pins": []}]}


## A worker fab_preview result whose every layer carries the real silk SVG. The
## GEOMETRY is not what these sections measure — the accounting, the keys and
## the picking are — and one shared document keeps the fixture honest about
## what a layer record looks like.
func _reply_layers(names: Array = EMITTED) -> Array:
	var out: Array = []
	for i in names.size():
		out.append({"name": str(names[i]), "kind": "gerber",
			"sha256": "%064x" % (i + 1), "byte_length": 100 + i, "svg": SILK_SVG})
	return out


func _rig() -> Dictionary:
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_tiny_board())
	var ipc := FabIPC.new()
	ipc.bind(panel)
	return {"panel": panel, "ipc": ipc}


func _init() -> void:
	print("=== fab preview: legible artwork, a banner off the board, one layer at a time ===\n")
	_run_contrast()
	_run_banner_geometry()
	_run_picker()
	await _run_mcp_parity()
	await _run_stale_retraction()
	await _run_camera_and_input()
	await _run_survives_non_edits()
	await _run_capture_framing()
	_run_dark_inks()
	print("\n=== Results: %d passed, %d failed ===" % [_passed, _fail])
	quit(1 if _fail > 0 else 0)


# ── 1. INK ────────────────────────────────────────────────────────────────────

func _run_contrast() -> void:
	print("-- 1: every ink is readable, measured not asserted --")

	# ACCUMULATED into one assertion per group: a check() per ink would make the
	# suite total depend on how many layers the palette happens to name.
	var dim: Array = []
	for key in FabPreview.INK:
		# AGAINST THE GROUND IT IS READ ON, which is not the same surface for
		# every ink: a rimmed layer's mark is surrounded by RIM, so RIM is what
		# its ink has to stand out from (FabPreview.read_ground).
		var ratio: float = FabPreview.contrast_ratio(FabPreview.INK[key],
			FabPreview.read_ground(str(key)))
		if ratio < MIN_CONTRAST:
			dim.append("%s=%.2f" % [str(key), ratio])
	for i in FabPreview.INNER_CU_INK.size():
		var inner: float = FabPreview.contrast_ratio(
			FabPreview.INNER_CU_INK[i], FabPreview.GROUND)
		if inner < MIN_CONTRAST:
			dim.append("in%d=%.2f" % [i + 1, inner])
	var fb: float = FabPreview.contrast_ratio(FabPreview.FALLBACK_INK, FabPreview.GROUND)
	if fb < MIN_CONTRAST:
		dim.append("fallback=%.2f" % fb)
	check("1a: every palette ink clears %.1f:1 on the ground it is read against (dim: %s)"
		% [MIN_CONTRAST, str(dim)], dim.is_empty())

	# THE RIM IS LOAD-BEARING, and RIMMED_KEYS must name exactly the inks that
	# need it. 1a proves none that needs a rim is missing from the list (it
	# would have failed against the bare ground); this proves none is on the
	# list that does not need one — otherwise the list could be padded until 1a
	# passed by moving the goalposts rather than by the palette being readable.
	var rim_on_ground: float = FabPreview.contrast_ratio(FabPreview.RIM, FabPreview.GROUND)
	var needless: Array = []
	for key in FabPreview.RIMMED_KEYS:
		if FabPreview.contrast_ratio(FabPreview.ink_for(str(key)),
				FabPreview.GROUND) >= MIN_CONTRAST:
			needless.append(str(key))
	check("1a2: the rim reads %.2f:1 on the ground, and every rimmed ink would FAIL without it (needless: %s)"
		% [rim_on_ground, str(needless)],
		rim_on_ground >= MIN_CONTRAST and needless.is_empty())

	# THE SANITY ARM. If the luminance maths cannot tell black-on-near-black
	# from a light ink, 1a proves nothing — this is the shipped defect, scored.
	# It is also why the drill ink is rimmed rather than left to stand alone.
	var black_ratio: float = FabPreview.contrast_ratio(Color(0, 0, 0), FabPreview.GROUND)
	check("1b: ...and the shipped black-on-dark artwork FAILS the same measure (%.2f:1)"
		% black_ratio, black_ratio < MIN_CONTRAST)

	# THE COMPOSITE. With every layer shown, a silk stroke's ground is another
	# layer, not the canvas — so the dimming of the under-group is what has to
	# hold the ratio up.
	var copper_bed: Color = FabPreview.composite(FabPreview.INK["f_cu"],
		FabPreview.draw_alpha("f_cu", FabPreview.PICK_ALL), FabPreview.GROUND)
	var silk_on_copper: float = FabPreview.contrast_ratio(
		FabPreview.composite(FabPreview.INK["f_silks"],
			FabPreview.draw_alpha("f_silks", FabPreview.PICK_ALL), copper_bed),
		copper_bed)
	check("1c: composited, silk still clears %.1f:1 against dimmed copper (%.2f:1)"
		% [MIN_CONTRAST, silk_on_copper], silk_on_copper >= MIN_CONTRAST)

	# The other side of that trade: dimming the under-group far enough to carry
	# silk must not sink it below the graphics bar against the canvas ground.
	# Rimmed inks are excluded: they are opaque top-group layers whose
	# readability is a property of their rim (1a/1a2), not of this dimming.
	var sunk: Array = []
	for key in FabPreview.INK:
		if FabPreview.is_rimmed(str(key)):
			continue
		var a: float = FabPreview.draw_alpha(str(key), FabPreview.PICK_ALL)
		var r: float = FabPreview.contrast_ratio(
			FabPreview.composite(FabPreview.INK[key], a, FabPreview.GROUND),
			FabPreview.GROUND)
		if r < MIN_GRAPHIC_CONTRAST:
			sunk.append("%s=%.2f" % [str(key), r])
	check("1c2: ...and no under-layer sinks below %.1f:1 in the composite (sunk: %s)"
		% [MIN_GRAPHIC_CONTRAST, str(sunk)], sunk.is_empty())

	# ── THE END-TO-END MEASUREMENT ───────────────────────────────────────────
	# Production recolour + production rasterize over a VERBATIM emitted layer,
	# then the actual pixel.
	print("-- 1d..1h3: the rasterized silk pixel itself --")
	var ink: Color = FabPreview.ink_for("f_silks")
	var recoloured: String = FabPreview.recolor_svg(SILK_SVG, ink)
	check("1d: the recolour is total — no black literal survives",
		recoloured.findn("=\"black\"") == -1)
	check("1e: ...and fill=\"none\" is left alone (a stroke must not become a blob)",
		recoloured.count("fill=\"none\"") == SILK_SVG.count("fill=\"none\""))

	var img: Image = FabPreview.rasterize(recoloured, PANEL_W)
	check("1f: the engine rasterizes the emitted SVG headlessly", img != null)
	if img == null:
		return
	# RESOLUTION IS HALF THE BUG: 0.12 mm strokes at the SVG's intrinsic size
	# (40.05 mm resolved at 96 dpi ~ 151 px) are well under one pixel and vanish
	# into the alpha channel no matter what colour they are.
	check("1g: ...at the width it will be drawn at, not the intrinsic 96-dpi size (%d px)"
		% img.get_width(), float(img.get_width()) >= FabPreview.MIN_RASTER_PX - 1.0)

	var stroke_uv := _path_to_uv((STROKE_A + STROKE_B) * 0.5)
	var stroke := _covered_pixel_at(img, stroke_uv)
	check("1h1: the long stroke is WHERE THE SVG PUTS IT — its midpoint is inked (coverage %.2f)"
		% stroke.a, stroke.a > 0.0, "uv=%s in %dx%d" % [
			str(stroke_uv), img.get_width(), img.get_height()])
	var off := _covered_pixel_at(img, _path_to_uv(OFF_STROKE))
	check("1h2: ...and a coordinate on no stroke is bare (coverage %.2f) — artwork, not a field"
		% off.a, off.a <= 0.01)

	var alpha: float = stroke.a * FabPreview.draw_alpha("f_silks", "f_silks")
	var on_screen: Color = FabPreview.composite(stroke, alpha, FabPreview.GROUND)
	var measured: float = FabPreview.contrast_ratio(on_screen, FabPreview.GROUND)
	check("1h3: that stroke pixel reads %.2f:1 against its ground (need %.1f, coverage %.2f)"
		% [measured, MIN_CONTRAST, stroke.a], measured >= MIN_CONTRAST,
		"pixel=%s composited=%s" % [str(stroke), str(on_screen)])

	# ── THE MEMORY BOUND IS ON THE RASTER, NOT ON ITS WIDTH ──────────────────
	# A width-only cap lets a tall board straight through: 1:30 at
	# MAX_RASTER_PX wide is 48000 px tall — ~300 MPx of RGBA for ONE of the
	# eleven layers a board emits.
	print("-- 1i..1j: a tall board's raster stays inside the memory bounds --")
	var tall: Image = FabPreview.rasterize(
		FabPreview.recolor_svg(TALL_SVG, ink), FabPreview.MAX_RASTER_PX)
	check("1i: the engine rasterizes the 10:300 outline", tall != null)
	if tall != null:
		var area := float(tall.get_width()) * float(tall.get_height())
		var longest := float(maxi(tall.get_width(), tall.get_height()))
		check("1j: ...inside the area and dimension caps (%d x %d = %.2f MPx)"
			% [tall.get_width(), tall.get_height(), area / 1.0e6],
			area <= FabPreview.MAX_RASTER_AREA_PX
				and longest <= FabPreview.MAX_RASTER_DIMENSION_PX,
			"longest=%.0f cap=%.0f" % [longest, FabPreview.MAX_RASTER_DIMENSION_PX])

	# ...and the caps hold in the other direction too: a board whose INTRINSIC
	# mm-at-96-dpi raster is already over them must be scaled DOWN, not passed
	# through because there was nothing to gain by scaling up.
	var huge: Image = FabPreview.rasterize(
		FabPreview.recolor_svg(OVERSIZED_SVG, ink), FabPreview.MAX_RASTER_PX)
	check("1k: the engine rasterizes the 5000 x 200 outline", huge != null)
	if huge != null:
		var huge_area := float(huge.get_width()) * float(huge.get_height())
		var huge_longest := float(maxi(huge.get_width(), huge.get_height()))
		check("1l: ...an intrinsically oversized board is downscaled inside both caps (%d x %d = %.2f MPx)"
			% [huge.get_width(), huge.get_height(), huge_area / 1.0e6],
			huge_area <= FabPreview.MAX_RASTER_AREA_PX
				and huge_longest <= FabPreview.MAX_RASTER_DIMENSION_PX,
			"longest=%.0f cap=%.0f" % [huge_longest, FabPreview.MAX_RASTER_DIMENSION_PX])


## One of the fixture's path coordinates as a FRACTION of the raster, whatever
## width it was rasterized at.
##
## Two steps, both read off the SVG above and nothing else:
##
##   1. the one group transform, in SVG order — translate(0.025, 30.025), the
##      scale(1, -1) y flip, then translate(-0.025, 0.025) — which collapses to
##      (x, -y - 30.0) in user space;
##   2. the viewBox normalization.
##
## The long stroke's midpoint therefore lands at exactly (0.5, 0.5), a number
## that can be checked by hand against the fixture.
func _path_to_uv(p: Vector2) -> Vector2:
	var user := Vector2(p.x + 0.025, -(p.y + 30.025)) + Vector2(-0.025, 0.025)
	return (user - VIEWBOX_MIN) / VIEWBOX_SIZE


## The most-covered pixel within SAMPLE_R of `uv` — the ink the eye lands on at
## a coordinate the caller already knows the artwork should occupy. Antialiased
## edges are dimmer by construction and are not what "is this stroke readable"
## asks about; coverage of ZERO here means the stroke is not drawn at all.
func _covered_pixel_at(img: Image, uv: Vector2) -> Color:
	var cx := int(roundf(uv.x * float(img.get_width())))
	var cy := int(roundf(uv.y * float(img.get_height())))
	var best := Color(0, 0, 0, 0)
	for dy in range(-SAMPLE_R, SAMPLE_R + 1):
		for dx in range(-SAMPLE_R, SAMPLE_R + 1):
			var px := img.get_pixel(
				clampi(cx + dx, 0, img.get_width() - 1),
				clampi(cy + dy, 0, img.get_height() - 1))
			if px.a > best.a:
				best = px
	return best


# ── 2. THE BANNER IS NOT ON THE BOARD ─────────────────────────────────────────

func _run_banner_geometry() -> void:
	print("\n-- 2: the header never occupies the board rect --")
	var adopted: Dictionary = FabPreview.adopt(_reply_layers(), [],
		FabPreview.PICK_ALL, PANEL_W)
	var rows: Array = adopted["layers"]
	var canvas := Vector2(PANEL_W, PANEL_H)
	var note := "11 layer(s) from the emitted artifacts — 7841 bytes total; GerberSpikeBoard-F_Cu.gbr 0a1b2c3d4e5f…"

	var banner: Rect2 = FabPreview.banner_rect(canvas, rows, [], note, FabPreview.PICK_ALL)
	var art: Rect2 = FabPreview.art_rect(canvas, Vector2(640, 480), banner.size.y)
	check("2a: the banner and the artwork do not intersect at %d px" % int(PANEL_W),
		not banner.intersects(art), "banner=%s art=%s" % [str(banner), str(art)])
	check("2b: the artwork starts below the banner, inside the canvas",
		art.position.y >= banner.end.y - 0.001 and art.end.y <= canvas.y + 0.001
			and art.position.x >= -0.001 and art.end.x <= canvas.x + 0.001, str(art))
	check("2c: the artwork is letterboxed, not stretched (4:3 in, 4:3 out)",
		absf(art.size.x / art.size.y - 640.0 / 480.0) < 0.01,
		"%s -> %.4f" % [str(art.size), art.size.x / art.size.y])

	# A banner that grows without bound would push the board off the bottom —
	# the same defect in the other direction.
	var many: Array = []
	for i in 40:
		many.append({"name": "x%d.gbr" % i, "reason": "unreadable fixture reason"})
	var tall: Rect2 = FabPreview.banner_rect(canvas, rows, many, note, FabPreview.PICK_ALL)
	var art_tall: Rect2 = FabPreview.art_rect(canvas, Vector2(640, 480), tall.size.y)
	check("2d: forty unrendered files cannot push the board off the canvas",
		tall.size.y <= canvas.y * 0.4 + 0.001 and art_tall.size.y > 1.0,
		"banner=%.1f art=%s" % [tall.size.y, str(art_tall)])
	check("2e: ...and they still intersect nothing", not tall.intersects(art_tall))

	# File identity is still on screen — moved off the board, not deleted. It is
	# what ties the picture to the artifact that would ship.
	var lines: Array = FabPreview.banner_lines(rows, [], note, FabPreview.PICK_ALL)
	check("2f: the banner still carries the artifact identity line", note in lines)
	check("2g: ...and names what is being shown", str(lines[0]).findn("all 11") != -1,
		str(lines[0]))
	var one: Array = FabPreview.banner_lines(rows, [], note, "f_silks")
	check("2h: an isolated layer names its own file and hash",
		str(one[0]).findn("F_SilkS") != -1 and str(one[0]).findn("sha ") != -1,
		str(one[0]))
	# THE ALARM MEANS SOMETHING, which is a claim about both directions.
	#
	# Every emission carries a .gbrjob manifest — JSON metadata with nothing to
	# draw — so counting it as a layer the preview failed to show raised
	# INCOMPLETE on every board that ever previewed. An alarm that is always on
	# is an alarm nobody reads, and the one it would have to survive is a real
	# missing copper layer.
	var job_only: Array = FabPreview.banner_lines(rows, [
		{"name": "job.gbrjob", "kind": FabPreview.MISS_JOB,
			"reason": "job manifest — metadata, not artwork"}], note,
		FabPreview.PICK_ALL)
	var alarmed := func(lines: Array) -> bool:
		for l in lines:
			if str(l).begins_with("INCOMPLETE"):
				return true
		return false
	check("2i: a complete emission does NOT alarm over its own job manifest",
		not alarmed.call(job_only), str(job_only))
	check("2j: ...but the manifest is still accounted for, unalarmingly",
		"(1 emitted file(s) carry no artwork — job manifest)" in job_only,
		str(job_only))
	var missing: Array = FabPreview.banner_lines(rows, [
		{"name": "job.gbrjob", "kind": FabPreview.MISS_JOB, "reason": "metadata"},
		{"name": "Board-F_Cu.gbr", "kind": FabPreview.MISS_ARTWORK,
			"reason": "gerbonara could not parse the emitted file"}], note,
		FabPreview.PICK_ALL)
	check("2k: a genuinely missing artwork layer DOES alarm, and names itself",
		alarmed.call(missing) and "INCOMPLETE — 1 emitted artwork file(s) not shown:"
			in missing and str(missing).findn("F_Cu") != -1, str(missing))
	# An older worker labels nothing. Falling back to the suffix keeps the alarm
	# honest on both sides rather than reverting to always-on.
	var unlabelled: Array = FabPreview.banner_lines(rows, [
		{"name": "job.gbrjob", "reason": "metadata"},
		{"name": "Board-B_Cu.gbr", "reason": "unreadable"}], note,
		FabPreview.PICK_ALL)
	check("2l: an unlabelled skip is classified by its suffix, not counted blind",
		alarmed.call(unlabelled)
			and "INCOMPLETE — 1 emitted artwork file(s) not shown:" in unlabelled,
		str(unlabelled))


# ── 3. THE PICKER ─────────────────────────────────────────────────────────────

func _run_picker() -> void:
	print("\n-- 3: one emitted layer at a time --")
	check("3a: the key comes off the emitted filename",
		FabPreview.layer_key("GerberSpikeBoard-F_SilkS.gbr") == "f_silks"
		and FabPreview.layer_key("GerberSpikeBoard-PTH.drl") == "pth"
		and FabPreview.layer_key("Board-In2_Cu.gbr") == "in2_cu")
	check("3b: the label is the suffix AS EMITTED, for a human",
		FabPreview.layer_label("GerberSpikeBoard-Edge_Cuts.gbr") == "Edge_Cuts")
	check("3c: an unknown layer gets its OWN key, not a shared 'other' bucket",
		FabPreview.layer_key("Board-Weird_Profile.gbr") == "weird_profile")
	check("3d: inner copper gets its own ink, not the grey fallback",
		FabPreview.ink_for("in1_cu") != FabPreview.FALLBACK_INK
			and FabPreview.ink_for("in1_cu") != FabPreview.ink_for("in2_cu"))

	var adopted: Dictionary = FabPreview.adopt(_reply_layers(), [], FabPreview.PICK_ALL, PANEL_W)
	var rows: Array = adopted["layers"]
	check("3e: every emitted file is accounted for exactly once",
		rows.size() + (adopted["unrendered"] as Array).size() == EMITTED.size())
	var choices: Array = FabPreview.choices(rows)
	check("3f: 'all' leads the picker, then one entry per emitted layer",
		choices.size() == EMITTED.size() + 1 and choices[0] == FabPreview.PICK_ALL
			and "f_silks" in choices and "pth" in choices, str(choices))
	check("3g: silk and the outline draw LAST, over the copper they annotate",
		str((rows[rows.size() - 1] as Dictionary)["key"]) == "edge_cuts"
			and str((rows[0] as Dictionary)["key"]).ends_with("_mask"),
		str(choices))

	check("3h: an isolated layer is opaque; a composited under-layer recedes",
		FabPreview.draw_alpha("f_cu", "f_cu") == 1.0
			and FabPreview.draw_alpha("f_cu", FabPreview.PICK_ALL) < 1.0
			and FabPreview.draw_alpha("f_silks", FabPreview.PICK_ALL) == 1.0)

	# A held pick the NEW artifact set does not carry resets — and the banner
	# says what is shown, so the reset is on screen rather than silent.
	var narrowed: Dictionary = FabPreview.adopt(
		_reply_layers(["Board-F_Cu.gbr"]), [], "f_silks", PANEL_W)
	check("3i: a pick the new artifact set has no file for resets to 'all'",
		str(narrowed["pick"]) == FabPreview.PICK_ALL)
	var kept: Dictionary = FabPreview.adopt(_reply_layers(), [], "b_silks", PANEL_W)
	check("3j: ...and one it does carry is kept across a refetch",
		str(kept["pick"]) == "b_silks")

	# A malformed record is ACCOUNTED FOR, never dropped: a viewer counting
	# what it can see would otherwise be short by one with nothing to explain it.
	var malformed: Dictionary = FabPreview.adopt(["not a record"], [],
		FabPreview.PICK_ALL, PANEL_W)
	check("3k: a malformed layer entry lands in unrendered, not the bin",
		(malformed["layers"] as Array).is_empty()
			and (malformed["unrendered"] as Array).size() == 1)

	# THE MENU IS THE SAME CONTROL. build_menu_section and menu_key are inverse;
	# a drift between them would hand the picker a key for the wrong layer.
	var popup := PopupMenu.new()
	FabPreview.build_menu_section(popup, 1000, rows, "f_silks")
	var mismatched: Array = []
	for i in rows.size():
		if FabPreview.menu_key(rows, 1000, 1002 + i) != str((rows[i] as Dictionary)["key"]):
			mismatched.append(i)
	check("3l: every View-menu id resolves to its own layer (mismatched: %s)"
		% str(mismatched), mismatched.is_empty())
	check("3m: ...and the 'All layers' id resolves to 'all'",
		FabPreview.menu_key(rows, 1000, 1001) == FabPreview.PICK_ALL)
	check("3n: ...while an id outside the section resolves to nothing",
		FabPreview.menu_key(rows, 1000, 999) == "")
	check("3o: the menu shows the human's pick as checked",
		popup.is_item_checked(popup.get_item_index(
			1002 + FabPreview.choices(rows).find("f_silks") - 1)))
	popup.free()


# ── 4. GUI AND MCP ARE ONE CONTROL ────────────────────────────────────────────

func _run_mcp_parity() -> void:
	print("\n-- 4: minerva_pcb_view_state reads and writes the picker --")
	var rig := _rig()
	var panel = rig["panel"]
	var ipc: FabIPC = rig["ipc"]
	ipc.overrides["pcb.fab_preview"] = {
		"layers": _reply_layers(), "unrendered": [], "warnings": []}
	var raised: bool = await panel.set_view_flag("show_fab_preview", true)
	check("4a: the preview comes up holding artwork",
		raised and bool(panel._canvas.get("show_fab_preview"))
			and (panel._canvas._fab_preview_layers as Array).size() == EMITTED.size())

	var host = panel._annotation_host
	var vs: Dictionary = await PanelTools.handle(host, "minerva_pcb_view_state",
		{"editor_name": "PCB1"})
	check("4b: view_state reports the pick and the menu of legal values",
		str(vs.get("fab_preview_layer", "")) == FabPreview.PICK_ALL
			and "f_silks" in (vs.get("fab_preview_layers", []) as Array), str(vs))

	var set_one: Dictionary = await PanelTools.handle(host, "minerva_pcb_view_state",
		{"editor_name": "PCB1", "fab_preview_layer": "f_silks"})
	check("4c: an agent can isolate one emitted layer",
		bool(set_one.get("success", false))
			and str(set_one.get("fab_preview_layer", "")) == "f_silks"
			and "fab_preview_layer" in (set_one.get("changed", []) as Array), str(set_one))
	check("4d: ...and it is the CANVAS that moved, not just the reply",
		str(panel._canvas.get("fab_preview_layer")) == "f_silks")

	var bad: Dictionary = await PanelTools.handle(host, "minerva_pcb_view_state",
		{"editor_name": "PCB1", "fab_preview_layer": "in7_cu"})
	check("4e: a layer this artifact set never emitted is refused by name",
		not bool(bad.get("success", true))
			and str(bad.get("error", "")) == "layer_not_emitted"
			and "f_silks" in (bad.get("available", []) as Array), str(bad))
	check("4f: ...and the refusal leaves the pick where it was",
		str(panel._canvas.get("fab_preview_layer")) == "f_silks")

	# THE GUI HALF OF PARITY: the View menu's own id, through the panel's own
	# handler, must land on the same canvas value the MCP verb writes.
	panel._on_view_menu_id_pressed(1000 + 2
		+ (FabPreview.choices(panel._canvas._fab_preview_layers).find("b_cu") - 1))
	check("4g: the View menu picker writes the same value the MCP verb does",
		str(panel._canvas.get("fab_preview_layer")) == "b_cu")

	# The pick is DRAW STATE, so a capture that omitted it would show a
	# different picture from the screen — the class of defect the mirror exists
	# to prevent.
	check("4h: the pick reaches an off-screen capture",
		"fab_preview_layer" in panel._canvas.CAPTURE_MIRRORED_FIELDS)
	panel.free()


# ── 5. A STALE PREVIEW IS NOT A PREVIEW ───────────────────────────────────────

func _run_stale_retraction() -> void:
	print("\n-- 5: a stale preview retracts its flag and says why --")
	var rig := _rig()
	var panel = rig["panel"]
	var ipc: FabIPC = rig["ipc"]
	ipc.overrides["pcb.fab_preview"] = {
		"layers": _reply_layers(), "unrendered": [], "warnings": []}
	await panel.set_view_flag("show_fab_preview", true)
	check("5a: the preview is up before the board moves",
		bool(panel._canvas.get("show_fab_preview")))

	# THE EDIT PATH, driven for real through the model's own signal.
	panel.get_data().from_board_dict(_tiny_board("moved"))
	check("5b: a board edit under a live preview takes the flag DOWN",
		not bool(panel._canvas.get("show_fab_preview")))
	check("5c: ...and the human is told why, on the held status lead",
		str(panel._status_label.text).findn("Fab preview OFF") != -1,
		str(panel._status_label.text))
	check("5d: ...in words that say what to do next",
		str(panel._status_label.text).findn("re-open") != -1,
		str(panel._status_label.text))

	var host = panel._annotation_host
	var vs: Dictionary = await PanelTools.handle(host, "minerva_pcb_view_state",
		{"editor_name": "PCB1"})
	check("5e: the agent reads the same retraction, not a raised flag",
		not bool((vs.get("flags", {}) as Dictionary).get("show_fab_preview", true))
			and (vs.get("overlay_unavailable", {}) as Dictionary).has("show_fab_preview"),
		str(vs))
	check("5f: ...and gets the SAME sentence the human does, not a wire code",
		str((vs.get("overlay_unavailable", {}) as Dictionary).get("show_fab_preview", ""))
			== OverlayFetch.STALE_BOARD_EDITED)

	# THE IN-FLIGHT PATH: the board moves between the request and the reply,
	# which is the only moment the request-token comparison exists for.
	#
	# The move is a DIRECT model write, not from_board_dict, on purpose. Every
	# signalling edit now reaches _invalidate_fab_preview and is retracted by
	# the branch above before the reply lands — so the only board moves the
	# token guard is still there to catch are the ones data_changed does not
	# cover (the panel says so itself where it relays journal_entry_added), and
	# a fixture that edited through the signal would exercise 5b again while
	# claiming to test this.
	ipc.on_reply = func(channel: String) -> void:
		if channel == "pcb.fab_preview":
			panel.get_data().board_name = "moved-in-flight"
	var raised: bool = await panel.set_view_flag("show_fab_preview", true)
	check("5g: a board that moves mid-fetch leaves the flag DOWN",
		not raised and not bool(panel._canvas.get("show_fab_preview")))
	var vs2: Dictionary = await PanelTools.handle(host, "minerva_pcb_view_state",
		{"editor_name": "PCB1"})
	check("5h: ...and says so in its own words, not the edit case's",
		str((vs2.get("overlay_unavailable", {}) as Dictionary).get("show_fab_preview", ""))
			== OverlayFetch.STALE_BOARD_MOVED_IN_FLIGHT, str(vs2))
	check("5i: ...and the two stale sentences are actually different",
		OverlayFetch.STALE_BOARD_EDITED != OverlayFetch.STALE_BOARD_MOVED_IN_FLIGHT)
	check("5j: ...and neither is drawn INSIDE the missing preview, where nobody could read it",
		(panel._canvas._fab_preview_layers as Array).is_empty()
			and str(panel._canvas._fab_preview_note).is_empty())
	ipc.on_reply = Callable()

	# THE OTHER HALF OF THE INVARIANT: a preview that is actually holding
	# artwork keeps its flag and retires whatever it last failed with.
	var ok: bool = await panel.set_view_flag("show_fab_preview", true)
	check("5k: a fetch that returned artwork leaves the flag UP",
		ok and bool(panel._canvas.get("show_fab_preview")))
	check("5l: ...and retires the standing reason",
		str(panel._status_label.text).findn("Fab preview OFF") == -1,
		str(panel._status_label.text))
	panel.free()


# ── 6. THE PREVIEW IS A VIEW, NOT A PICTURE ───────────────────────────────────
#
# WHAT WAS WRONG. The artwork was letterboxed into the canvas rect and drawn
# there whatever the camera said, so it could not be panned or zoomed and a
# human could not get close enough to a part to judge it — which is the entire
# job of a fabrication preview. Worse, the canvas still ran its EDITING grammar
# underneath: a drag aimed at panning moved whatever was under the cursor, the
# board edit invalidated the live preview, and the layer picker then refused
# every layer it had just advertised.

## The worker's own bounds for the 40 x 30 spike board, in the BOARD
## coordinates it reports them in (`bounds_board_mm`) — the outline plus the
## half stroke-width the artwork actually occupies.
const BOARD_BOUNDS := {"min_x": -0.025, "min_y": -0.025,
	"max_x": 40.025, "max_y": 30.025}

## Where the one part sits, and how far the drag travels. 40 px at zoom 10 is
## 4 mm — well past DRAG_TRAVEL_PX, and past the 2.54 mm grid the move snaps to,
## so a move that lands must change the board.
const PART_MM := Vector2(5.0, 5.0)
const DRAG_PX := Vector2(40.0, 0.0)


func _board_with_part() -> Dictionary:
	var board := _tiny_board("camera")
	board["grid_mm"] = 2.54
	board["components"] = [{"ref": "R1", "footprint": "R_0805", "value": "1k",
		"x_mm": PART_MM.x, "y_mm": PART_MM.y, "rotation_deg": 0.0, "layer": "top",
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
			"pad_width_mm": 1.0, "pad_height_mm": 1.0}]}]
	return board


## A canvas IN THE TREE holding the artwork — _gui_input returns early outside
## it, so a rig that skipped this would assert nothing at all.
##
## The frame yield is what makes "in the tree" true rather than merely intended.
## This suite runs from _init(), the SceneTree's own constructor, and the root
## Window is only attached to the tree later, in SceneTree.initialize(); a node
## added to root before that is a child of a rootless Window, so
## is_inside_tree() stays FALSE and pcb_canvas._gui_input discards every event
## on its first line. One process_frame lands after initialize(), which
## propagates the tree down to this canvas (and fires its _enter_tree/_ready).
func _canvas_rig() -> Variant:
	var data = PCBData.new()
	data.from_board_dict(_board_with_part())
	var canvas = PcbCanvasScript.new()
	canvas.data = data
	root.add_child(canvas)
	await process_frame
	# AFTER the add: entering the tree can re-run the container sort, and a
	# canvas sized to nothing would make every screen-rect assertion vacuous.
	canvas.size = Vector2(PANEL_W, PANEL_H)
	return canvas


func _press(canvas, at: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = at
	canvas._gui_input(ev)


func _motion(canvas, at: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = at
	canvas._gui_input(ev)


## The whole board as ONE comparable value. Serialized rather than compared as a
## Dictionary so the assertion cannot quietly become a reference check.
func _board_text(canvas) -> String:
	return JSON.stringify(canvas.data.to_board_dict(), "", true, true)


## Press, travel, release — the gesture a human makes trying to move the view.
func _drag(canvas, from: Vector2, to: Vector2) -> void:
	_press(canvas, from, true)
	_motion(canvas, to)
	_press(canvas, to, false)


func _run_camera_and_input() -> void:
	print("\n-- 6: the artwork rides the board camera, and only the camera --")

	check("6a: the reply's bounds become a board-space rect",
		FabPreview.board_rect(BOARD_BOUNDS).size.is_equal_approx(Vector2(40.05, 30.05)),
		str(FabPreview.board_rect(BOARD_BOUNDS)))
	check("6b: a missing or degenerate bounds reply places nothing",
		FabPreview.board_rect(null) == Rect2()
			and FabPreview.board_rect({"min_x": 1.0, "min_y": 1.0,
				"max_x": 1.0, "max_y": 1.0}) == Rect2())

	var canvas = await _canvas_rig()
	canvas.set_fab_preview(_reply_layers(), [], "note", BOARD_BOUNDS)
	check("6c: the preview opens holding the artwork AND its extent",
		(canvas._fab_preview_layers as Array).size() == EMITTED.size()
			and canvas._fab_preview_bounds.size.x > 0.0)

	# THE CAMERA CONVENTION, written out from pcb_canvas's own declaration
	# (world_to_screen = world*zoom + pan_offset + size/2) rather than read back
	# out of the function under test.
	canvas.zoom = 10.0
	canvas.pan_offset = Vector2.ZERO
	var placed: Rect2 = canvas.fab_preview_screen_rect()
	var expect_pos: Vector2 = canvas._fab_preview_bounds.position * 10.0 + canvas.size / 2.0
	check("6d: the artwork lands where the board camera puts it",
		placed.position.is_equal_approx(expect_pos)
			and placed.size.is_equal_approx(canvas._fab_preview_bounds.size * 10.0),
		"%s vs %s" % [str(placed), str(expect_pos)])

	# TWO OBSERVATIONS AT TWO CAMERA STATES. A letterbox into the canvas rect
	# answers both identically, which is exactly what was wrong.
	canvas.pan_offset = Vector2(37.0, -11.0)
	var panned: Rect2 = canvas.fab_preview_screen_rect()
	check("6e: a pan MOVES the artwork by the pan, and only by the pan",
		(panned.position - placed.position).is_equal_approx(Vector2(37.0, -11.0))
			and panned.size.is_equal_approx(placed.size), str(panned))
	canvas.pan_offset = Vector2.ZERO
	canvas.zoom = 20.0
	var zoomed: Rect2 = canvas.fab_preview_screen_rect()
	check("6f: a zoom GROWS it by the zoom — the board can be inspected closely",
		zoomed.size.is_equal_approx(placed.size * 2.0), str(zoomed))
	check("6g: ...and it is that rect the draw places the artwork in",
		FabPreview.placement(canvas.size, Vector2(640, 480), 40.0, zoomed) == zoomed)
	check("6h: ...while a reply with no bounds still letterboxes, as before",
		FabPreview.placement(canvas.size, Vector2(640, 480), 40.0, Rect2())
			== FabPreview.art_rect(canvas.size, Vector2(640, 480), 40.0))

	# ── THE INPUT HALF ──────────────────────────────────────────────────────
	#
	# THE CONTROL ARM FIRST. Without it "the board did not move" is satisfied by
	# a gesture that was never an edit — a threshold not crossed, a component
	# not hit, a canvas not in the tree.
	canvas.show_fab_preview = false
	canvas.zoom = 10.0
	canvas.pan_offset = Vector2.ZERO
	var grab: Vector2 = canvas.world_to_screen(PART_MM)
	var before := _board_text(canvas)
	_drag(canvas, grab, grab + DRAG_PX)
	check("6i: CONTROL — with the preview down that drag really does edit the board",
		_board_text(canvas) != before, "the gesture never moved the part; 6j proves nothing")

	# THE CLAIM. Same canvas, same gesture, preview up.
	canvas.data.from_board_dict(_board_with_part())
	canvas.show_fab_preview = true
	canvas.zoom = 10.0
	canvas.pan_offset = Vector2.ZERO
	var guarded_before := _board_text(canvas)
	var selection_before: Array = (canvas.selected_components as Array).duplicate()
	var pan_before: Vector2 = canvas.pan_offset
	_drag(canvas, grab, grab + DRAG_PX)
	check("6j: under the preview the SAME drag leaves the board untouched",
		_board_text(canvas) == guarded_before)
	check("6k: ...because it panned the view instead",
		(canvas.pan_offset - pan_before).is_equal_approx(DRAG_PX),
		str(canvas.pan_offset))
	check("6l: ...and nothing was selected out from under the human either",
		(canvas.selected_components as Array) == selection_before)

	# The wheel is the other half of "I cannot see parts closely". Driven from a
	# zoom where the artwork is ALREADY drawn wider than it was rasterized for,
	# so 6n is a statement about the refit and not about the clamp's floor.
	canvas.zoom = 30.0
	var zoom_before: float = canvas.zoom
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = canvas.size / 2.0
	canvas._gui_input(wheel)
	check("6m: the wheel zooms the preview", canvas.zoom > zoom_before,
		"%f -> %f" % [zoom_before, canvas.zoom])
	# Zooming in draws the artwork wider than it was rasterized for, which is the
	# resolution half of the legibility problem arriving through the camera.
	var raster: float = float((canvas._fab_preview_layers[0] as Dictionary)
		.get("raster_px", 0.0))
	check("6n: ...and the raster is refit to the width it is now drawn at",
		raster >= minf(canvas.fab_preview_screen_rect().size.x,
			FabPreview.MAX_RASTER_PX) - 2.0,
		"raster=%.0f drawn=%.0f" % [raster, canvas.fab_preview_screen_rect().size.x])

	# A key that deletes on the live canvas must do nothing over artwork.
	var key := InputEventKey.new()
	key.keycode = KEY_DELETE
	key.pressed = true
	var key_before := _board_text(canvas)
	canvas._gui_input(key)
	check("6o: no key reaches the board while the preview owns the surface",
		_board_text(canvas) == key_before)

	# The extent is DRAW STATE: a capture without it would place the artwork
	# somewhere else than the screen does.
	check("6p: the artwork's extent reaches an off-screen capture",
		"_fab_preview_bounds" in canvas.CAPTURE_MIRRORED_FIELDS)
	canvas.queue_free()


# ── 7. THE PREVIEW SURVIVES WHAT DOES NOT REACH THE FAB ───────────────────────
#
# WHAT WAS WRONG. Invalidation was wired to the model's generic data_changed,
# so the POLICY was "any model touch blanks the preview and retracts the View
# flag" — a re-load of the very same board took the preview down and left the
# layer picker refusing every layer it had just advertised, with nothing on
# screen a human could connect to anything they did.
#
# THE RULE NOW IS THE BOARD, NOT THE SIGNAL: the canonical board dict is
# exactly what the worker renders the artwork from, so the preview stands while
# that dict's token is unchanged and drops the moment it moves. These
# assertions read the PANEL'S OBSERVABLE STATE — the flag and the held layers —
# and never which signal fired, because the rule is about the board and a test
# about the wiring would pass again the next time the wiring was wrong.


## The rig of section 5, holding a board with a part on it so a component move
## is available as the artwork-changing arm.
func _preview_rig() -> Dictionary:
	var rig := _rig()
	var panel = rig["panel"]
	var ipc: FabIPC = rig["ipc"]
	panel.get_data().from_board_dict(_board_with_part())
	ipc.overrides["pcb.fab_preview"] = {
		"layers": _reply_layers(), "unrendered": [], "warnings": []}
	return rig


## The two observations that together mean "the preview is still up": the flag
## an agent and the View menu both read, and the artwork actually held.
func _preview_is_live(panel) -> bool:
	return bool(panel._canvas.get("show_fab_preview")) \
		and (panel._canvas._fab_preview_layers as Array).size() == EMITTED.size()


func _run_survives_non_edits() -> void:
	print("\n-- 7: only an edit that reaches the emitter takes the preview down --")
	var rig := _preview_rig()
	var panel = rig["panel"]
	var host = panel._annotation_host
	await panel.set_view_flag("show_fab_preview", true)
	check("7a: the preview is up holding artwork before anything touches the model",
		_preview_is_live(panel))

	# A RE-LOAD OF THE SAME BOARD. The real path a save/reload round trip, an
	# autosave restate or a redundant load_board takes: data_changed fires,
	# every layer of the model is rebuilt, and NOT ONE emitted byte differs.
	var before_reload := JSON.stringify(panel.get_data().to_board_dict(), "", true, true)
	panel.get_data().from_board_dict(_board_with_part())
	var after_reload := JSON.stringify(panel.get_data().to_board_dict(), "", true, true)
	# The precondition rides in the same assertion: if the reload did NOT
	# reproduce the board byte for byte then this proves nothing about the rule,
	# and the detail says which half gave way.
	check("7b: re-loading the SAME board leaves the preview standing",
		after_reload == before_reload and _preview_is_live(panel),
		"board unchanged=%s preview live=%s" % [
			str(after_reload == before_reload), str(_preview_is_live(panel))])

	# An MCP preference write — the owner's own case. It never touches the
	# board, so it cannot change what the fab receives.
	var pref: Dictionary = await PanelTools.handle(host, "minerva_pcb_set_preference",
		{"editor_name": "PCB1", "key": "trace_width_mm", "value": 0.4})
	check("7c: an MCP preference write goes through AND leaves the preview up",
		bool(pref.get("success", false)) and _preview_is_live(panel), str(pref))

	# A view change — pan and zoom are the gestures the preview EXISTS to
	# support (section 6); one of them ending it would be self-defeating.
	var view: Dictionary = await PanelTools.handle(host, "minerva_pcb_set_view",
		{"editor_name": "PCB1", "zoom": 12.0})
	check("7d: a view change goes through AND leaves the preview up",
		bool(view.get("success", false)) and _preview_is_live(panel), str(view))

	# THE CLAIM IS ONLY WORTH ANYTHING WITH THE OTHER ARM. A component move is
	# copper, mask, paste and silk all moving at once; the artwork on screen
	# stops describing the board and must go.
	var comp_ids: Array = panel.get_data().components.keys()
	check("7e: CONTROL — the fixture board really does carry a component to move",
		comp_ids.size() == 1, str(comp_ids))
	panel.get_data().move_component(str(comp_ids[0]), Vector2(20.0, 12.0))
	check("7f: moving a component DOES take the preview down",
		not bool(panel._canvas.get("show_fab_preview"))
			and (panel._canvas._fab_preview_layers as Array).is_empty())
	check("7g: ...and says why, in the same words a board edit always did",
		str(panel._status_label.text).findn("Fab preview OFF") != -1,
		str(panel._status_label.text))
	panel.free()

	# THE OUTLINE IS ARTWORK TOO — a resize moves Edge.Cuts and every layer's
	# frame, and is the case a "components and traces" rule would have missed.
	var rig2 := _preview_rig()
	var panel2 = rig2["panel"]
	await panel2.set_view_flag("show_fab_preview", true)
	panel2.get_data().set_board_size(55.0, 30.0)
	check("7h: resizing the board takes the preview down as well",
		not bool(panel2._canvas.get("show_fab_preview")))
	panel2.free()


# ── 8. A FITTED CAPTURE FRAMES WHAT THE SCREEN FRAMES ─────────────────────────
#
# WHAT WAS WRONG. capture_to_image(fit=true) framed the BOARD rect while the
# preview draws the ARTWORK rect — the outline plus half a stroke width, padded
# by a fraction of itself instead of by the preview's own margin. The two
# extents nearly coincide, so the picture an agent captured looked right and
# was at a different scale from the one the human was looking at: a WYSIWYG
# seam that reads as a rounding error.
#
# capture_to_image itself cannot run here (it returns null with no rendering
# device, pinned by test_pcb_panel_tools), so this drives the framing decision
# it delegates to — _frame_board_for_capture over a real copy canvas — and
# compares the camera it produces with the camera on screen.

func _run_capture_framing() -> void:
	print("\n-- 8: a fitted capture of the preview is at the screen's scale --")
	var canvas = await _canvas_rig()
	canvas.show_fab_preview = true
	canvas.set_fab_preview(_reply_layers(), [], "note", BOARD_BOUNDS)
	var on_screen: Rect2 = canvas.fab_preview_screen_rect()
	check("8a: the screen frames the artwork on adoption",
		on_screen.size.x > 1.0 and on_screen.size.y > 1.0, str(on_screen))

	# The capture copy, built and mirrored exactly the way capture_to_image
	# builds it, at the same size so the two cameras are comparable at all.
	var copy = PcbCanvasScript.new()
	copy.size = canvas.size
	copy.data = canvas.data
	canvas.mirror_capture_state_onto(copy)
	canvas._frame_board_for_capture(copy)
	check("8b: the fitted capture takes the SAME camera the screen has",
		is_equal_approx(copy.zoom, canvas.zoom)
			and copy.pan_offset.is_equal_approx(canvas.pan_offset),
		"copy zoom=%.4f pan=%s vs screen zoom=%.4f pan=%s" % [
			copy.zoom, str(copy.pan_offset), canvas.zoom, str(canvas.pan_offset)])
	check("8c: ...so the artwork lands in the same rect in both",
		copy.fab_preview_screen_rect().position.is_equal_approx(on_screen.position)
			and copy.fab_preview_screen_rect().size.is_equal_approx(on_screen.size),
		"%s vs %s" % [str(copy.fab_preview_screen_rect()), str(on_screen)])

	# THE CONTROL. Without the preview the fit is still the board fit — and it
	# is a DIFFERENT camera, which is what made the seam real rather than
	# theoretical. If these two agreed by accident 8b would prove nothing.
	var bare = PcbCanvasScript.new()
	bare.size = canvas.size
	bare.data = canvas.data
	bare.show_fab_preview = false
	canvas._frame_board_for_capture(bare)
	var board_fit: float = PcbViewFit.fit_zoom(
		PcbViewFit.board_content_rect(canvas.data), bare.size,
		bare.min_zoom, bare.max_zoom)
	check("8d: with no preview the fitted capture still frames the BOARD",
		is_equal_approx(bare.zoom, board_fit), "%.4f vs %.4f" % [bare.zoom, board_fit])
	check("8e: CONTROL — the two framings really do differ (%.4f vs %.4f)"
		% [bare.zoom, copy.zoom], not is_equal_approx(bare.zoom, copy.zoom))
	copy.queue_free()
	bare.queue_free()
	canvas.queue_free()


# ── 9. HOLES ARE BLACK, THE OUTLINE IS DARK PURPLE ────────────────────────────
#
# Both are ABSENCES of material and read dark, and a dark mark on this ground
# is no mark at all — so those layers are rasterized in the RIM colour and the
# ink is applied at draw time, over four offset rim draws. The palette, the
# banner legend and the View-menu picker all take the colour from one place, so
# a swatch cannot advertise a colour the canvas does not paint.

func _run_dark_inks() -> void:
	print("\n-- 9: the two dark inks, their rim, and the swatches that name them --")
	var drill: Color = FabPreview.ink_for("pth")
	var edge: Color = FabPreview.ink_for("edge_cuts")
	check("9a: both drill layers are BLACK",
		drill == Color(0, 0, 0) and FabPreview.ink_for("npth") == Color(0, 0, 0),
		"pth=%s npth=%s" % [str(drill), str(FabPreview.ink_for("npth"))])
	# "Dark purple" described rather than copied: blue-dominant with red second
	# (that is purple, not blue and not magenta), and darker than the bar an ink
	# has to clear unaided (that is what makes it need the rim).
	check("9b: the board outline is a DARK PURPLE",
		edge.b > edge.r and edge.r > edge.g
			and FabPreview.contrast_ratio(edge, FabPreview.GROUND) < MIN_CONTRAST,
		"%s at %.2f:1 on the ground" % [str(edge),
			FabPreview.contrast_ratio(edge, FabPreview.GROUND)])
	check("9c: those three keys are exactly the rimmed ones",
		FabPreview.is_rimmed("pth") and FabPreview.is_rimmed("npth")
			and FabPreview.is_rimmed("edge_cuts")
			and not FabPreview.is_rimmed("f_cu")
			and not FabPreview.is_rimmed("f_silks"))

	# THE PRODUCTION PATH, end to end: adopt a drill layer and read the pixel
	# that was actually rasterized. A rimmed layer's raster carries the RIM —
	# the ink arrives as the draw-time modulate — and the two multiplied
	# together are what the eye receives.
	var adopted: Dictionary = FabPreview.adopt(
		_reply_layers(["GerberSpikeBoard-PTH.drl"]), [], "pth", PANEL_W)
	var rows: Array = adopted["layers"]
	check("9d: the drill layer is adopted", rows.size() == 1)
	if rows.size() == 1:
		var tex: ImageTexture = (rows[0] as Dictionary).get("texture")
		var pixel := _covered_pixel_at(tex.get_image(),
			_path_to_uv((STROKE_A + STROKE_B) * 0.5))
		check("9e: a rimmed layer is RASTERIZED in the rim, not in its ink (%s)"
			% str(pixel),
			pixel.a > 0.0 and absf(pixel.r - FabPreview.RIM.r) < 0.02
				and absf(pixel.g - FabPreview.RIM.g) < 0.02
				and absf(pixel.b - FabPreview.RIM.b) < 0.02)
		var mod: Color = FabPreview.draw_modulate("pth", "pth")
		var painted := Color(pixel.r * mod.r, pixel.g * mod.g, pixel.b * mod.b)
		check("9f: ...and the modulate multiplies it to exactly the ink (%s)"
			% str(painted),
			absf(painted.r - drill.r) < 0.02 and absf(painted.g - drill.g) < 0.02
				and absf(painted.b - drill.b) < 0.02)
	check("9g: an un-rimmed layer still carries its ink and is drawn untinted",
		FabPreview.raster_ink("f_cu") == FabPreview.ink_for("f_cu")
			and FabPreview.draw_modulate("f_cu", "f_cu") == Color(1, 1, 1, 1))

	# THE PICKER NAMES THE COLOUR THE CANVAS PAINTS. A swatch that disagreed
	# would send a human looking for the wrong mark.
	var all_rows: Array = (FabPreview.adopt(_reply_layers(), [],
		FabPreview.PICK_ALL, PANEL_W))["layers"]
	var popup := PopupMenu.new()
	FabPreview.build_menu_section(popup, 1000, all_rows, FabPreview.PICK_ALL)
	var wrong: Array = []
	for i in all_rows.size():
		var key := str((all_rows[i] as Dictionary)["key"])
		var icon: Texture2D = popup.get_item_icon(popup.get_item_index(1002 + i))
		if icon == null:
			wrong.append("%s=no swatch" % key)
			continue
		var img := icon.get_image()
		var centre := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
		if not _same_ink(centre, FabPreview.ink_for(key)):
			wrong.append("%s=%s" % [key, str(centre)])
		# A rimmed layer's chip carries its rim too, or the black one would be
		# the same invisible mark on the menu that the rim exists to prevent.
		if FabPreview.is_rimmed(key) and not _same_ink(img.get_pixel(0, 0), FabPreview.RIM):
			wrong.append("%s=unrimmed chip" % key)
	check("9h: every picker swatch is the ink that layer is painted in (wrong: %s)"
		% str(wrong), wrong.is_empty())
	popup.free()


## Two colours the same to the eye, and to an 8-bit image. A swatch is stored
## as RGBA8, so an ink quantizes to the nearest 1/255 on the way in and an
## exact comparison would fail on every colour that is not a whole step.
func _same_ink(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01
