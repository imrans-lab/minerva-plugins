extends RefCounted
## THE HOVER CARD — a bordered multi-line box painted on the board canvas that
## says what the pointer is resting on.
##
## Off-tree module — NO class_name, siblings reached by relative preload (see
## pcb_canvas.gd's port note). Everything here is STATIC and pure; the board is
## never mutated and no canvas state is read.
##
## ── NOTHING HERE IS A NEW DERIVATION ─────────────────────────────────────────
## The card is display-only, so every fact on it is the fact the matching read
## verb already answers with. This module formats; it never computes a property:
##
##   a component   spatial_index.describe_component_context — what
##                 minerva_pcb_describe_component returns
##   a pad / pin   host.pin_info + host.pin_display_name — what
##                 minerva_pcb_pin_info returns, including its display rule
##   a trace       pcb_region_describe.traces_in_region — the row
##                 minerva_pcb_describe_region reports for that trace, with
##                 its length summed over the very points that row carries
##
## So the card and the verb cannot disagree. Adding a line means finding the
## surface that already owns the answer, never writing a second rule.
##
## ── IT IS PAINT, NOT A CONTROL ───────────────────────────────────────────────
## The card is drawn in immediate mode by the canvas, so it captures no input,
## has no children and cannot steal a click from the entity it describes. Two
## placement rules keep it from getting in the way, both enforced by rect_for:
## it stays inside the canvas rect, and it never covers the hovered point.

const _PcbRegionDescribe := preload("model/pcb_region_describe.gd")
const _PcbTraceGeometry := preload("model/pcb_trace_geometry.gd")

## Inner padding between the border and the text block, in screen px.
const PAD_PX := Vector2(8.0, 5.0)
## Clearance kept between the hovered point and the nearest card edge. Also what
## guarantees the card cannot contain that point: every candidate placement
## starts a full gap away from it.
const GAP_PX := 14.0
## Extra leading between rows, on top of the font's own line height.
const LINE_GAP_PX := 2.0
const BORDER_PX := 1.0

const BG_COLOR := Color(0.09, 0.10, 0.13, 0.93)
const BORDER_COLOR := Color(0.55, 0.60, 0.68, 0.95)
const TEXT_COLOR := Color(0.90, 0.92, 0.95, 1.0)
## The first line is the entity's address (refdes, REF.PIN, trace id) — the
## thing the rest of the card is about, so it is the one line that is coloured.
const TITLE_COLOR := Color(1.0, 0.85, 0.40, 1.0)

## What a fact the board does not carry prints as. A dash SAYS "nothing here";
## a blank row leaves the reader guessing whether the card failed to fill it.
const EMPTY_VALUE := "—"


# ── CONTENT ──────────────────────────────────────────────────────────────────

## A component's card: refdes, value, footprint, layer, rotation, position.
## Empty when the board has no such component — an empty card is what says
## "nothing to show", so callers never need a second "is there anything" call.
##
## `spatial` is a pcb_spatial_index bound to the live board (duck-typed, as
## every cross-module reach in this plugin is).
static func component_lines(spatial, component_id: String) -> PackedStringArray:
	if spatial == null or component_id.is_empty():
		return PackedStringArray()
	var ctx: Dictionary = spatial.describe_component_context(component_id)
	if ctx.is_empty():
		return PackedStringArray()
	var pos: Dictionary = ctx.get("position", {})
	return PackedStringArray([
		str(ctx.get("id", component_id)),
		"Value: %s" % _or_dash(str(ctx.get("value", ""))),
		"Footprint: %s" % _or_dash(str(ctx.get("footprint", ""))),
		"Layer: %s" % _or_dash(str(ctx.get("layer", ""))),
		"Rotation: %s°" % _num(float(ctx.get("rotation", 0.0))),
		"Position: (%s, %s) mm" % [_num(float(pos.get("x", 0.0))),
			_num(float(pos.get("y", 0.0)))],
	])


## A pad's card: REF.PIN, the pin's display name, its roles, its net, its layer.
##
## The display name is host.pin_display_name — the SAME rule minerva_pcb_pin_info
## reports as `display_name` (footprint geometry name > net > "(unconnected)"),
## so the card cannot name a pin differently from the verb.
##
## `host` is a PcbAnnotationHost (pin_info + pin_display_name), duck-typed.
static func pad_lines(host, component: String, pin: String) -> PackedStringArray:
	if host == null or component.is_empty() or pin.is_empty():
		return PackedStringArray()
	if not host.has_method("pin_info"):
		return PackedStringArray()
	var info: Dictionary = host.pin_info(component, pin)
	if info.is_empty():
		return PackedStringArray()
	var display := ""
	if host.has_method("pin_display_name"):
		display = str(host.pin_display_name(info))
	var lines := PackedStringArray([str(info.get("ref", "%s.%s" % [component, pin]))])
	if not display.is_empty():
		lines.append("Pin: %s" % display)
	var roles: Array = info.get("roles", [])
	if not roles.is_empty():
		lines.append("Roles: %s" % ", ".join(_strings(roles)))
	lines.append("Net: %s" % _or_dash(str(info.get("net", ""))))
	lines.append("Layer: %s" % _or_dash(str(info.get("layer", ""))))
	return lines


## A trace's card: id, net, width, layer, length.
##
## Every value is read off the row pcb_region_describe emits for this trace, so
## the card reports what minerva_pcb_describe_region reports. LENGTH is not on
## that row, and is summed here over the row's OWN `points` — derived from the
## reported polyline rather than from a second read of the model, so a card can
## never quote a length belonging to different geometry than the one it names.
static func trace_lines(data, trace_id: String) -> PackedStringArray:
	if data == null or trace_id.is_empty():
		return PackedStringArray()
	var trace = data.get_trace(trace_id)
	if trace == null:
		return PackedStringArray()
	# The trace's own bounds is the smallest region guaranteed to contain it,
	# so the region read below is asked exactly one question: this trace.
	var rows: Array = _PcbRegionDescribe.traces_in_region(
		data, trace.get_bounding_rect(), "")
	for raw in rows:
		var row: Dictionary = raw
		if str(row.get("trace_id", "")) != trace_id:
			continue
		return PackedStringArray([
			trace_id,
			"Net: %s" % _or_dash(str(row.get("net", ""))),
			"Width: %s mm" % _num(float(row.get("width_mm", 0.0))),
			"Layer: %s" % _or_dash(str(row.get("layer", ""))),
			"Length: %s mm" % _num(_PcbTraceGeometry.length(
				_polyline(row.get("points", [])))),
		])
	return PackedStringArray()


## An Array of anything into the PackedStringArray String.join needs.
static func _strings(values: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for v in values:
		out.append(str(v))
	return out


## A region-describe `points` array back into the polyline it describes.
static func _polyline(points: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for raw in points:
		var p: Dictionary = raw
		out.append(Vector2(float(p.get("x_mm", 0.0)), float(p.get("y_mm", 0.0))))
	return out


## Board numbers read at a glance, not to four decimals: trailing zeros and a
## bare ".0" are dropped so "0.25", "3" and "-1.5" all print as themselves.
static func _num(value: float) -> String:
	var text := "%.3f" % value
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return "0" if text == "-0" or text.is_empty() else text


static func _or_dash(text: String) -> String:
	return EMPTY_VALUE if text.strip_edges().is_empty() else text


# ── GEOMETRY ─────────────────────────────────────────────────────────────────

## The card's pixel size for these lines in this font. Vector2.ZERO with no
## lines or no font, which draw_into and rect_for both read as "no card".
static func measure(lines: PackedStringArray, font: Font, font_size: int) -> Vector2:
	if lines.is_empty() or font == null:
		return Vector2.ZERO
	var width := 0.0
	for line in lines:
		width = maxf(width, font.get_string_size(
			line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var line_h := font.get_height(font_size)
	var height := lines.size() * line_h + (lines.size() - 1) * LINE_GAP_PX
	return Vector2(width, height) + PAD_PX * 2.0


## Where a card of `size` goes for a pointer at `anchor`, inside a canvas of
## `canvas_size`. Both placement rules live here:
##
##   INSIDE THE CANVAS — a card clipped by the panel edge is a card whose last
##   line is missing, and the missing line is as likely as any to be the one
##   being read. So the four diagonal placements are tried in turn and the first
##   that fits whole is taken.
##
##   NEVER OVER THE POINTER — the card exists to describe the thing under the
##   cursor, so covering it would defeat the feature. Every candidate starts a
##   full GAP_PX away from the anchor, so none of them can contain it.
##
## FALLBACK: when no diagonal fits (a card larger than the space beside the
## cursor), the box is clamped into the canvas and then pushed off the anchor
## along the axis with the most room. A card taller or wider than the canvas
## itself cannot satisfy both rules; staying inside wins, because half a card is
## still readable while a card painted outside the panel is not painted at all.
static func rect_for(size: Vector2, anchor: Vector2, canvas_size: Vector2,
		gap: float = GAP_PX) -> Rect2:
	if size == Vector2.ZERO:
		return Rect2()
	var right := anchor.x + gap
	var left := anchor.x - gap - size.x
	var below := anchor.y + gap
	var above := anchor.y - gap - size.y
	for pos in [Vector2(right, below), Vector2(left, below),
			Vector2(right, above), Vector2(left, above)]:
		var candidate := Rect2(pos, size)
		if candidate.position.x >= 0.0 and candidate.position.y >= 0.0 \
				and candidate.end.x <= canvas_size.x \
				and candidate.end.y <= canvas_size.y:
			return candidate
	var clamped := Rect2(Vector2(
		clampf(right, 0.0, maxf(0.0, canvas_size.x - size.x)),
		clampf(below, 0.0, maxf(0.0, canvas_size.y - size.y))), size)
	if not clamped.has_point(anchor):
		return clamped
	# Push to whichever side of the pointer has more room, then re-clamp.
	var pushed := above if anchor.y > canvas_size.y * 0.5 else below
	clamped.position.y = clampf(pushed, 0.0, maxf(0.0, canvas_size.y - size.y))
	return clamped


# ── PAINT ────────────────────────────────────────────────────────────────────

## Paint the card into `canvas` (any CanvasItem, called from its _draw). Silent
## no-op for an empty card, so the caller never needs a guard of its own.
static func draw_into(canvas: CanvasItem, lines: PackedStringArray, rect: Rect2,
		font: Font, font_size: int) -> void:
	if lines.is_empty() or font == null or rect.size == Vector2.ZERO:
		return
	canvas.draw_rect(rect, BG_COLOR, true)
	canvas.draw_rect(rect, BORDER_COLOR, false, BORDER_PX)
	var line_h := font.get_height(font_size)
	var baseline := rect.position + PAD_PX + Vector2(0.0, font.get_ascent(font_size))
	for i in lines.size():
		canvas.draw_string(font, baseline, lines[i], HORIZONTAL_ALIGNMENT_LEFT,
			-1, font_size, TITLE_COLOR if i == 0 else TEXT_COLOR)
		baseline.y += line_h + LINE_GAP_PX
