extends RefCounted
## THE EMITTED ARTWORK, MADE LEGIBLE — palette, banner and layer picker for the
## exact fabrication preview.
##
## Off-tree module: NO class_name, reached by relative preload. Every function
## is STATIC. pcb_canvas.gd holds the adopted rows and calls draw(); nothing
## about how the preview LOOKS lives in the canvas.
##
## WHY THIS FILE EXISTS. gerbonara renders every emitted artifact with
## fg="black" on a `style="background-color:white"` root. Godot's rasterizer
## honours the fills and ignores the root style, so stacked layers land as
## black-on-transparent over a near-black canvas: present and unreadable, which
## makes the fabrication gate a human checks by eye read as passed. Three things
## keep it legible, and all three are here:
##
##   1. INK. Each layer's SVG is recoloured to a palette entry before it is
##      rasterized (recolor_svg). Gerber carries no colour — black is
##      gerbonara's arbitrary default, not part of the artifact — so choosing a
##      per-layer ink changes nothing about the bytes, whose sha256 is taken
##      from the emitted text upstream of this file.
##   2. RESOLUTION. Silk strokes are ~0.12 mm. At the SVG's intrinsic size
##      (mm at 96 dpi) that is well under one pixel, so the strokes fall into
##      the alpha channel regardless of colour. Layers are rasterized at the
##      size they will be drawn (see adopt).
##   3. ONE LAYER AT A TIME. Ten layers composited is a picture of no layer.
##      The pick isolates one; "all" keeps the composite for orientation.
##
## THE BANNER IS NOT ON THE BOARD. Identity, counts and the incomplete-artifact
## admission occupy a band ACROSS THE TOP, and the artwork is letterboxed into
## what is left (banner_rect / art_rect never intersect). Text over the board
## hides the geometry it is describing.

## The pick that shows every emitted layer at once.
const PICK_ALL := "all"

## The canvas ground this view paints for itself, so the contrast of every ink
## below is a property of this file rather than of the caller's clear colour.
const GROUND := Color(0.08, 0.08, 0.08)
const BANNER_BG := Color(0.13, 0.13, 0.16, 0.97)
const BANNER_TEXT := Color(0.92, 0.92, 0.95)
const BANNER_WARN := Color(1.0, 0.66, 0.30)

## Alpha for a layer that is NOT the top group while every layer is composited.
##
## THE COMPOSITE CANNOT SATISFY ONE BAR. Silk over undimmed copper is 1.9:1 and
## unreadable; copper dimmed enough to carry silk cannot itself hold 4.5:1
## against the ground. So the two views answer different questions and are held
## to different standards: an ISOLATED layer (the pick, and the view a human
## checks a board in) is opaque and clears WCAG 1.4.3's 4.5:1 for text, while
## the composite is an orientation view whose under-layers are graphics and
## clear WCAG 1.4.11's 3:1. This value is the largest that keeps silk-on-copper
## above 4.5 while leaving every under-ink above 3. Both bars are recomputed by
## the suite, not asserted.
const UNDER_ALPHA := 0.55

## Layers that stay at full alpha in the composite: what a human reads a board
## BY. Everything else recedes under them.
const TOP_KEYS: Array[String] = ["f_silks", "b_silks", "edge_cuts"]

## INK BY EMITTED-LAYER KEY. Every entry clears 4.5:1 against GROUND on its own
## (pinned by the suite, which recomputes the ratio rather than trusting the
## table), and neighbouring roles are separated in hue as well as luminance so
## copper / mask / silk / outline are told apart and not merely seen.
const INK := {
	"f_cu": Color(0.98, 0.62, 0.30),
	"b_cu": Color(0.42, 0.78, 0.98),
	"f_mask": Color(0.45, 0.90, 0.55),
	"b_mask": Color(0.35, 0.80, 0.72),
	"f_paste": Color(0.72, 0.80, 0.86),
	"b_paste": Color(0.66, 0.72, 0.82),
	"f_silks": Color(0.96, 0.96, 0.96),
	"b_silks": Color(0.80, 0.72, 0.98),
	"edge_cuts": Color(1.00, 0.92, 0.35),
	"pth": Color(1.00, 0.55, 0.62),
	"npth": Color(0.98, 0.72, 0.45),
}
## Inner copper, by stack index read out of the key ("in1_cu" -> 0). Cycled, so
## a stack deeper than this list still draws in a legible ink rather than the
## grey fallback.
const INNER_CU_INK: Array[Color] = [
	Color(0.86, 0.70, 0.98), Color(0.70, 0.98, 0.80),
	Color(0.98, 0.86, 0.55), Color(0.98, 0.65, 0.85),
]
const FALLBACK_INK := Color(0.85, 0.85, 0.85)

## Draw order within the composite, low first. A layer whose key is unknown
## sits with copper: it is more likely to be copper than to be an outline.
const _RANK := {
	"f_mask": 0, "b_mask": 0, "f_paste": 1, "b_paste": 1,
	"f_cu": 2, "b_cu": 2, "pth": 3, "npth": 3,
	"f_silks": 4, "b_silks": 4, "edge_cuts": 5,
}
const _RANK_DEFAULT := 2

## Rasterization target, in pixels of WIDTH. The lower bound keeps sub-pixel
## silk legible on a narrow panel; the upper bound is the widest a layer is ever
## drawn at.
const MIN_RASTER_PX := 640.0
const MAX_RASTER_PX := 1600.0

## THE MEMORY BOUNDS, which a width bound alone is not: a raster is
## width x width*aspect, so a 10:300 board outline taken to 1600 px wide is
## 48000 px tall — 300 MPx of RGBA, once per emitted layer. These cap the two
## quantities that actually cost memory, and raster_width solves the width back
## out of them. The area cap sits above the square case (1600 x 1600 =
## 2.56 MPx), so an ordinary board still rasterizes at full width.
const MAX_RASTER_DIMENSION_PX := 4096.0
const MAX_RASTER_AREA_PX := 3_000_000.0

const _BANNER_LINE_H := 16.0
const _BANNER_PAD := 8.0
const _LEGEND_ROW_H := 15.0
const _LEGEND_CHIP_W := 86.0
const _FONT_SIZE := 12


## The emitted filename's layer suffix, lowercased: the key everything here is
## table-driven on. "Board-F_SilkS.gbr" -> "f_silks"; "Board-PTH.drl" -> "pth".
##
## Suffix-after-the-last-dash rather than a fixed list, so an inner layer or a
## profile this build does not know about still gets its own key (and therefore
## its own pick and its own ink) instead of collapsing into "other".
static func layer_key(file_name: String) -> String:
	return layer_label(file_name).to_lower()


## The same suffix as EMITTED — what the fab will see on the file — for the
## picker and the banner. Falls back to the whole filename when there is no
## dash to cut on.
static func layer_label(file_name: String) -> String:
	var base := file_name.get_file().get_basename()
	var dash := base.rfind("-")
	if dash >= 0 and dash + 1 < base.length():
		return base.substr(dash + 1)
	return base if not base.is_empty() else file_name


static func ink_for(key: String) -> Color:
	if INK.has(key):
		return INK[key]
	if key.begins_with("in") and key.ends_with("_cu"):
		var digits := key.substr(2, key.length() - 5)
		if digits.is_valid_int():
			return INNER_CU_INK[maxi(int(digits) - 1, 0) % INNER_CU_INK.size()]
	return FALLBACK_INK


## Alpha this layer is drawn at, given the current pick. An isolated layer is
## always opaque: there is nothing under it for it to blend with, and dimming
## the one thing the human asked to see would be perverse.
static func draw_alpha(key: String, pick: String) -> float:
	if pick != PICK_ALL:
		return 1.0
	return 1.0 if key in TOP_KEYS else UNDER_ALPHA


## Recolour gerbonara's output. It writes exactly two colour literals —
## fill="black" and stroke="black" for artwork, plus a root
## style="background-color:white" the engine ignores — so this is a total
## substitution, not a best-effort one. `fill="none"` is left alone.
static func recolor_svg(svg: String, ink: Color) -> String:
	var hex := "#" + ink.to_html(false)
	return svg.replace("=\"black\"", "=\"%s\"" % hex)


## The pixel width a layer is actually rasterized at for a canvas this wide —
## the clamp, said once, so `adopt` records the same number `refit` compares
## against and a re-raster is decided on the effective width rather than the raw
## canvas one.
##
## `aspect` is the artwork's intrinsic height/width. The memory bounds are on
## the RASTER, not on its width, so a tall board's width comes down until both
## hold — below MIN_RASTER_PX if it must, because that is a legibility floor and
## it yields to a memory ceiling.
static func raster_width(target_px: float, aspect: float = 1.0) -> float:
	var tall := maxf(aspect, 0.0001)
	var width := clampf(target_px, MIN_RASTER_PX, MAX_RASTER_PX)
	width = minf(width, MAX_RASTER_DIMENSION_PX / tall)   # bounds the height
	width = minf(width, sqrt(MAX_RASTER_AREA_PX / tall))  # bounds the area
	# FLOORED: the engine rounds the scaled height up as readily as down, and a
	# bound that is only met on average is not a bound.
	return maxf(floorf(width), 1.0)


## An image's height/width — the shape the memory bounds are solved against.
static func aspect_of(img: Image) -> float:
	return float(img.get_height()) / maxf(float(img.get_width()), 1.0)


## Rasterize one recoloured SVG at the width it will be DRAWN at.
##
## Two loads, deliberately: the intrinsic size is only knowable from a parsed
## document, and the intrinsic size (mm resolved at 96 dpi) puts 0.12 mm silk
## under one pixel. The first load also supplies the aspect the memory bounds
## are solved against. Returns null when the engine cannot parse it — the caller
## accounts for that file rather than dropping it.
##
## THE SCALE GOES BOTH WAYS. `raster_width` is a bound, not a target to grow
## towards: a board whose intrinsic mm-at-96-dpi size already exceeds it (wide
## enough, or tall and narrow enough) has to come DOWN, or the memory bounds
## hold only for artwork that happened to start small. The engine takes a scale
## below 1.0; the resize is the fallback for when it refuses one.
static func rasterize(svg: String, target_px: float) -> Image:
	var img := Image.new()
	if img.load_svg_from_string(svg, 1.0) != OK:
		return null
	var intrinsic := float(img.get_width())
	if intrinsic <= 0.0:
		return null
	var scale := raster_width(target_px, aspect_of(img)) / intrinsic
	if is_equal_approx(scale, 1.0):
		return img
	var sharp := Image.new()
	if sharp.load_svg_from_string(svg, scale) == OK:
		return sharp
	if scale < 1.0:
		# Truncating, for the reason raster_width floors: a bound met by
		# rounding is not met.
		img.resize(maxi(int(intrinsic * scale), 1),
			maxi(int(float(img.get_height()) * scale), 1),
			Image.INTERPOLATE_BILINEAR)
	return img


## Turn a worker fab_preview reply into drawable rows.
##
## `layers` carries the SVG strings; `unrendered` the files the worker already
## could not draw. Returns {layers, unrendered, pick} — EVERY input file leaves
## in exactly one of the two lists, because a preview that quietly drops a layer
## presents a known-incomplete artifact set as complete.
##
## `pick` comes back "all" whenever the held pick names a layer this artifact
## set does not contain: the banner always names what is being shown, so the
## reset is on screen rather than silent.
static func adopt(layers: Array, unrendered: Array, held_pick: String,
		target_px: float) -> Dictionary:
	var rows: Array = []
	var missed: Array = unrendered.duplicate(true)
	for entry in layers:
		if not (entry is Dictionary):
			missed.append({"name": "(malformed layer entry)",
				"reason": "the worker reply carried a layer that was not a record"})
			continue
		var lay: Dictionary = entry
		var name := str(lay.get("name", "?"))
		var key := layer_key(name)
		var svg := str(lay.get("svg", ""))
		var inked := "" if svg.is_empty() else recolor_svg(svg, ink_for(key))
		var img: Image = null if inked.is_empty() else rasterize(inked, target_px)
		if img == null:
			missed.append({"name": name,
				"reason": "the engine could not rasterize the worker's SVG for this layer"})
			continue
		var aspect := aspect_of(img)
		rows.append({
			"name": name,
			"label": layer_label(name),
			"key": key,
			"kind": str(lay.get("kind", "")),
			"sha256": str(lay.get("sha256", "")),
			"byte_length": int(lay.get("byte_length", 0)),
			# THE SOURCE IS KEPT, not just its raster: the artwork outlives the
			# canvas width it was first drawn for, and `refit` needs the document
			# back to redraw it sharper. `raster_px` is the width this texture
			# was made at and `aspect` its shape — together they are what refit
			# needs to solve the same bounds without reparsing the document.
			"svg": inked,
			"aspect": aspect,
			"raster_px": raster_width(target_px, aspect),
			"texture": ImageTexture.create_from_image(img),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _RANK.get(str(a["key"]), _RANK_DEFAULT) < _RANK.get(str(b["key"]), _RANK_DEFAULT))
	var pick := held_pick if held_pick in choices(rows) else PICK_ALL
	return {"layers": rows, "unrendered": missed, "pick": pick}


## Re-rasterize held rows for a canvas that has GROWN since they were adopted.
##
## `adopt` rasterizes at the width the artwork will be drawn at, which is right
## until the panel is widened: the texture then stretches and 0.12 mm silk goes
## soft, which is the resolution problem the two-load raster exists to solve.
## Returns the rows to hold — the same array when nothing moved, so a
## caller can assign unconditionally and a resize that changes nothing costs one
## comparison per layer.
##
## GROWTH ONLY. A narrower canvas draws the finer raster scaled down, which is
## already correct and cheaper than re-rasterizing; re-rastering on a shrink
## would also mean re-decoding every layer through the whole of a drag.
static func refit(rows: Array, target_px: float) -> Array:
	var out: Array = []
	var moved := false
	for row_v in rows:
		if not (row_v is Dictionary):
			out.append(row_v)
			continue
		var row: Dictionary = row_v
		var svg := str(row.get("svg", ""))
		var want := raster_width(target_px, float(row.get("aspect", 1.0)))
		if svg.is_empty() or want <= float(row.get("raster_px", 0.0)):
			out.append(row)
			continue
		var img := rasterize(svg, want)
		if img == null:
			# The document rasterized once already, so this is a transient engine
			# failure, not a layer we cannot draw: KEEP the coarser texture
			# rather than dropping a layer out of a complete artifact set.
			out.append(row)
			continue
		var fresh := row.duplicate()
		fresh["raster_px"] = want
		fresh["texture"] = ImageTexture.create_from_image(img)
		out.append(fresh)
		moved = true
	return out if moved else rows


## Every value the picker may be set to for the artwork currently held: "all"
## first, then one key per emitted layer in draw order.
static func choices(rows: Array) -> Array:
	var out: Array = [PICK_ALL]
	for row in rows:
		var key := str((row as Dictionary).get("key", ""))
		if not key.is_empty() and not (key in out):
			out.append(key)
	return out


static func _row_for(rows: Array, pick: String) -> Dictionary:
	for row in rows:
		if str((row as Dictionary).get("key", "")) == pick:
			return row
	return {}


## The banner's text, top line first. `note` is the caller's identity line
## (layer count, total bytes, the first artifact's hash).
static func banner_lines(rows: Array, unrendered: Array, note: String,
		pick: String) -> Array:
	var lines: Array = []
	if rows.is_empty():
		lines.append("Fab preview: nothing rendered yet.")
	elif pick == PICK_ALL:
		lines.append("Showing: all %d emitted layer(s)" % rows.size())
	else:
		var row := _row_for(rows, pick)
		lines.append("Showing: %s — %s  %d B  sha %s…" % [
			str(row.get("label", pick)), str(row.get("name", "")),
			int(row.get("byte_length", 0)), str(row.get("sha256", "")).substr(0, 12)])
	if not note.is_empty():
		lines.append(note)
	if not unrendered.is_empty():
		lines.append("INCOMPLETE — %d emitted file(s) not shown:" % unrendered.size())
		for u in unrendered:
			lines.append("    %s — %s" % [str((u as Dictionary).get("name", "?")),
				str((u as Dictionary).get("reason", ""))])
	return lines


## How many legend rows the chips wrap into. 0 when there is no legend (a single
## isolated layer names itself on the "Showing:" line).
static func _legend_rows(rows: Array, pick: String, width: float) -> int:
	if rows.is_empty() or pick != PICK_ALL:
		return 0
	var per_row := maxi(int((width - 2.0 * _BANNER_PAD) / _LEGEND_CHIP_W), 1)
	return int(ceil(float(rows.size()) / float(per_row)))


## THE BAND THE TEXT LIVES IN — always across the top, never over the artwork.
static func banner_rect(canvas_size: Vector2, rows: Array, unrendered: Array,
		note: String, pick: String) -> Rect2:
	var lines := banner_lines(rows, unrendered, note, pick)
	var height := 2.0 * _BANNER_PAD + float(lines.size()) * _BANNER_LINE_H \
		+ float(_legend_rows(rows, pick, canvas_size.x)) * _LEGEND_ROW_H
	# A banner is a caption, not the view. Past this share of the canvas the
	# artwork stops being inspectable, so the text scrolls out of the band
	# rather than pushing the board off the bottom.
	return Rect2(Vector2.ZERO, Vector2(canvas_size.x,
		minf(height, maxf(canvas_size.y * 0.4, 1.0))))


## The artwork's rect: letterboxed into what the banner leaves, NEVER stretched.
## A preview that changes the shape of the board makes every judgement a
## reviewer draws from it about clearance, spacing or fit wrong by an unstated
## factor.
static func art_rect(canvas_size: Vector2, art_px: Vector2, banner_h: float) -> Rect2:
	var free := Rect2(Vector2(0.0, banner_h),
		Vector2(canvas_size.x, maxf(canvas_size.y - banner_h, 1.0)))
	var fit := minf(free.size.x / maxf(art_px.x, 1.0), free.size.y / maxf(art_px.y, 1.0))
	var drawn: Vector2 = art_px * fit
	return Rect2(free.position + (free.size - drawn) * 0.5, drawn)


## Draw the whole preview onto `ci`. Ground, artwork, banner — in that order,
## so the banner is opaque over the ground and the artwork never reaches it.
static func draw(ci: CanvasItem, canvas_size: Vector2, rows: Array,
		unrendered: Array, note: String, pick: String) -> void:
	ci.draw_rect(Rect2(Vector2.ZERO, canvas_size), GROUND)
	var banner := banner_rect(canvas_size, rows, unrendered, note, pick)
	if not rows.is_empty():
		var first: Texture2D = (rows[0] as Dictionary).get("texture")
		var art: Vector2 = first.get_size() if first != null else canvas_size
		var rect := art_rect(canvas_size, art, banner.size.y)
		for row in rows:
			var key := str((row as Dictionary).get("key", ""))
			if pick != PICK_ALL and key != pick:
				continue
			var tex: Texture2D = (row as Dictionary).get("texture")
			if tex != null:
				ci.draw_texture_rect(tex, rect, false,
					Color(1, 1, 1, draw_alpha(key, pick)))
	_draw_banner(ci, canvas_size, banner, rows, unrendered, note, pick)


static func _draw_banner(ci: CanvasItem, canvas_size: Vector2, banner: Rect2,
		rows: Array, unrendered: Array, note: String, pick: String) -> void:
	ci.draw_rect(banner, BANNER_BG)
	var font := ThemeDB.fallback_font
	var text_w := int(canvas_size.x - 2.0 * _BANNER_PAD)
	var y := banner.position.y + _BANNER_PAD + _BANNER_LINE_H - 4.0
	for line in banner_lines(rows, unrendered, note, pick):
		if y > banner.end.y:
			return
		var tint := BANNER_WARN if str(line).begins_with("INCOMPLETE") else BANNER_TEXT
		ci.draw_string(font, Vector2(_BANNER_PAD, y), str(line),
			HORIZONTAL_ALIGNMENT_LEFT, text_w, _FONT_SIZE, tint)
		y += _BANNER_LINE_H
	if _legend_rows(rows, pick, canvas_size.x) == 0:
		return
	# THE LEGEND names the inks while everything is composited — without it the
	# colours are merely different, not identifiable.
	var x := _BANNER_PAD
	for row in rows:
		if x + _LEGEND_CHIP_W > canvas_size.x - _BANNER_PAD:
			x = _BANNER_PAD
			y += _LEGEND_ROW_H
		if y > banner.end.y:
			return
		var key := str((row as Dictionary).get("key", ""))
		ci.draw_rect(Rect2(Vector2(x, y - 8.0), Vector2(9.0, 9.0)), ink_for(key))
		ci.draw_string(font, Vector2(x + 13.0, y), str((row as Dictionary).get("label", key)),
			HORIZONTAL_ALIGNMENT_LEFT, int(_LEGEND_CHIP_W - 15.0), 10, BANNER_TEXT)
		x += _LEGEND_CHIP_W


## ── THE VIEW MENU'S PICKER SECTION ──────────────────────────────────────────
##
## Built here rather than in the panel for the same reason the palette is: the
## panel owns WHEN the section exists, this file owns what is in it. Ids are
## base_id (the separator), base_id+1 ("All layers"), then base_id+2+row index —
## so menu_key below is the exact inverse and the two cannot drift.

## The base id the panel mounts this section at. It sits above every other
## View-menu id family in PCBPanel, so that popup's one teardown sweep (remove
## every id at or above its layer base) clears these items with the rest.
const MENU_ID_BASE := 1000


## The picker for whatever artwork `canvas` is holding — the panel's whole half
## of building it.
static func build_canvas_menu(popup: PopupMenu, canvas) -> void:
	if canvas == null:
		return
	build_menu_section(popup, MENU_ID_BASE, canvas._fab_preview_layers,
		str(canvas.fab_preview_layer))


## Route a View-menu id to the canvas's pick. Returns true for every id in this
## section's range, so the caller stops before its own lower ranges — whose
## tests are open-ended `id > base` comparisons — can swallow one.
static func handle_menu_id(canvas, id: int) -> bool:
	if id < MENU_ID_BASE:
		return false
	if canvas != null:
		var key := menu_key(canvas._fab_preview_layers, MENU_ID_BASE, id)
		if not key.is_empty():
			canvas.set_fab_preview_layer(key)
	return true


static func build_menu_section(popup: PopupMenu, base_id: int, rows: Array,
		pick: String) -> void:
	if rows.is_empty():
		return
	popup.add_separator("Fab preview layer", base_id)
	popup.add_radio_check_item("All layers", base_id + 1)
	popup.set_item_checked(popup.get_item_index(base_id + 1), pick == PICK_ALL)
	for i in rows.size():
		var row: Dictionary = rows[i]
		var id: int = base_id + 2 + i
		popup.add_radio_check_item(str(row.get("label", row.get("key", "?"))), id)
		popup.set_item_checked(popup.get_item_index(id),
			pick == str(row.get("key", "")))


## The pick a menu id names, or "" for an id outside this section.
static func menu_key(rows: Array, base_id: int, id: int) -> String:
	if id == base_id + 1:
		return PICK_ALL
	var index := id - base_id - 2
	if index >= 0 and index < rows.size():
		return str((rows[index] as Dictionary).get("key", ""))
	return ""


## ── CONTRAST, AS ARITHMETIC ─────────────────────────────────────────────────
##
## Here rather than in the suite because the palette above is only defensible if
## something recomputes it: a headless Godot has no rendered image to sample
## (minerva_pcb_get_image degrades to null there), so the suite measures the
## RASTERIZED LAYER PIXEL through these two functions instead of a screenshot.

static func relative_luminance(c: Color) -> float:
	var parts := [c.r, c.g, c.b]
	var lin: Array[float] = []
	for v in parts:
		var f := float(v)
		lin.append(f / 12.92 if f <= 0.04045 else pow((f + 0.055) / 1.055, 2.4))
	return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


static func contrast_ratio(a: Color, b: Color) -> float:
	var la := relative_luminance(a)
	var lb := relative_luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


## What a pixel of `ink` drawn at `alpha` actually looks like over `ground` —
## the colour the eye receives, which is what a contrast ratio is about.
static func composite(ink: Color, alpha: float, ground: Color) -> Color:
	return Color(
		ink.r * alpha + ground.r * (1.0 - alpha),
		ink.g * alpha + ground.g * (1.0 - alpha),
		ink.b * alpha + ground.b * (1.0 - alpha))
