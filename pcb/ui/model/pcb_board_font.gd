extends RefCounted
## Board stroke-font renderer (GDScript side) — the panel's half of the board
## text contract.
##
## Mirrors pcb/worker/pcb_worker/board_font.py's `render()` / `text_width()`
## rule-for-rule, over the glyph table mirrored in the sibling
## `pcb_board_font_data.gd`. Two languages, one authored source: the panel
## cannot import the Python renderer, and what the editor DRAWS has to be the
## same shape the fab RECEIVES or the WYSIWYG claim is false.
##
## The parity that matters is checked, not assumed. The glyph TABLE is compared
## number-for-number by worker/tests/test_board_font.py; the RENDERER is pinned
## by tests/gd/test_board_graphics.gd, which asserts the same fixture numbers
## the Python suite asserts ("Minerva v2" at size 1.5 -> width 11.5 mm, F-side
## x-extent [10, 21.5], B-side [-1.5, 10] about an anchor at x=10).
##
## Off-tree plugin: NO class_name (see sibling pcb_layer_stack.gd) — reached via
## a relative preload():
##     const PcbBoardFont := preload("pcb_board_font.gd")

const PcbBoardFontData := preload("pcb_board_font_data.gd")


## Advance width of `text` at `size_mm` cap height, in mm.
##
## Grid units accumulate as INTEGERS and are scaled exactly once at the end —
## the same discipline as the Python side, and for the same reason: scaling per
## glyph and summing drifts, and a drifting width silently disagrees with
## render()'s own alignment maths for centred text.
static func text_width(text: String, size_mm: float = 1.0) -> float:
	if text.is_empty():
		return 0.0
	var units := 0
	for i in text.length():
		units += _advance(text[i])
	units += PcbBoardFontData.GLYPH_GAP * (text.length() - 1)
	return float(units) * PcbBoardFontData.UNIT * size_mm


static func _advance(ch: String) -> int:
	var entry: Array = PcbBoardFontData.GLYPHS.get(
		ch, PcbBoardFontData.GLYPHS[PcbBoardFontData.MISSING_GLYPH_CHAR])
	return int(entry[0])


## Render `text` to glyph-LOCAL open stroke polylines, anchored at the origin
## with the baseline at y = 0.
##
## `size_mm` is CAP HEIGHT: a capital is exactly that tall.
##
## `mirror` X-reflects the string about its own anchor — what back-side
## (B.SilkS) legend takes so it reads correctly once the board is flipped. The
## reflection is about the ANCHOR, never the board origin, so mirroring never
## MOVES the text.
##
## Returns { "polylines": Array[Array[Vector2]], "missing": Array[String],
##           "width_mm": float }. Unknown characters draw a box and are listed
## in `missing` rather than being dropped — a dropped character shortens a
## legend without saying so.
##
## Rotation and translation are NOT applied here; `place()` does that, so there
## is one rotation implementation rather than one per call site.
static func render(text: String, size_mm: float = 1.0, mirror: bool = false,
		h_align: String = "left") -> Dictionary:
	var scale: float = PcbBoardFontData.UNIT * size_mm
	var width := text_width(text, size_mm)
	var align_dx := -width / 2.0 if h_align == "center" else 0.0

	var polylines: Array = []
	var missing: Array = []
	var pen := 0
	for i in text.length():
		var ch: String = text[i]
		var entry: Variant = PcbBoardFontData.GLYPHS.get(ch)
		if entry == null:
			entry = PcbBoardFontData.GLYPHS[PcbBoardFontData.MISSING_GLYPH_CHAR]
			if not missing.has(ch):
				missing.append(ch)
		var advance := int(entry[0])
		for stroke in entry[1]:
			var pts: Array = []
			for pt in stroke:
				pts.append(Vector2(
					(float(pt[0]) + pen) * scale + align_dx,
					(float(pt[1]) - PcbBoardFontData.BASELINE_ROW) * scale))
			polylines.append(pts)
		pen += advance + PcbBoardFontData.GLYPH_GAP

	if mirror:
		for stroke in polylines:
			for j in stroke.size():
				var p: Vector2 = stroke[j]
				stroke[j] = Vector2(-p.x, p.y)

	return {"polylines": polylines, "missing": missing, "width_mm": width}


## Place glyph-local strokes at a board position with a rotation.
##
## KiCad's footprint-angle convention (the angle is NEGATED), matching
## geometry.rotate_local_offset in the worker so the panel and the compiler
## place the same string at the same coordinates. 0 degrees short-circuits
## exactly, with no float drift.
static func place(polylines: Array, x_mm: float, y_mm: float,
		rotation_deg: float = 0.0) -> Array:
	var origin := Vector2(x_mm, y_mm)
	if is_zero_approx(rotation_deg):
		var flat: Array = []
		for stroke in polylines:
			var out: Array = []
			for p in stroke:
				out.append(origin + (p as Vector2))
			flat.append(out)
		return flat
	var r := deg_to_rad(-rotation_deg)
	var c := cos(r)
	var s := sin(r)
	var placed: Array = []
	for stroke in polylines:
		var out: Array = []
		for pv in stroke:
			var p: Vector2 = pv
			out.append(origin + Vector2(p.x * c - p.y * s, p.x * s + p.y * c))
		placed.append(out)
	return placed


## Render AND place in one call — board-absolute strokes for `text`.
## Returns { "polylines", "missing", "width_mm", "bounds": Rect2 }.
static func strokes_for(text: String, x_mm: float, y_mm: float, size_mm: float,
		rotation_deg: float = 0.0, mirror: bool = false,
		h_align: String = "left") -> Dictionary:
	var r := render(text, size_mm, mirror, h_align)
	var placed := place(r["polylines"], x_mm, y_mm, rotation_deg)
	return {
		"polylines": placed,
		"missing": r["missing"],
		"width_mm": r["width_mm"],
		"bounds": bounds_of(placed),
	}


## Axis-aligned bounds of already-placed strokes. An empty set yields a zero-size
## Rect2 at the origin rather than an inverted one.
static func bounds_of(polylines: Array) -> Rect2:
	var seen := false
	var rect := Rect2()
	for stroke in polylines:
		for pv in stroke:
			var p: Vector2 = pv
			if not seen:
				rect = Rect2(p, Vector2.ZERO)
				seen = true
			else:
				rect = rect.expand(p)
	return rect
