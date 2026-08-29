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
##   a zone        data.get_zone + zone_kind — what minerva_pcb_describe_zone
##                 returns
##   a via         pcb_region_describe.via_entry — the row minerva_pcb_list_vias
##                 returns for that via
##   a group line  data.group_member_ids / group_anchor_id / is_group_locked —
##                 the facts minerva_pcb_group_components reports back
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
## starts a full gap away from it. 19 px: the owner found 14 too tight to read
## past the cursor (work item 01a04b85e620).
const GAP_PX := 19.0
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

## A component's card: refdes, value, footprint, layer, rotation, position, and
## — for a grouped part only — its group (member count, anchor, lock).
## Empty when the board has no such component — an empty card is what says
## "nothing to show", so callers never need a second "is there anything" call.
##
## `spatial` is a pcb_spatial_index bound to the live board (duck-typed, as
## every cross-module reach in this plugin is); the group facts are read off
## the board it is bound to.
static func component_lines(spatial, component_id: String) -> PackedStringArray:
	if spatial == null or component_id.is_empty():
		return PackedStringArray()
	var ctx: Dictionary = spatial.describe_component_context(component_id)
	if ctx.is_empty():
		return PackedStringArray()
	var pos: Dictionary = ctx.get("position", {})
	var lines := PackedStringArray([
		str(ctx.get("id", component_id)),
		"Value: %s" % _or_dash(str(ctx.get("value", ""))),
		"Footprint: %s" % _or_dash(str(ctx.get("footprint", ""))),
		"Layer: %s" % _or_dash(str(ctx.get("layer", ""))),
		"Rotation: %s°" % _num(float(ctx.get("rotation", 0.0))),
		"Position: (%s, %s) mm" % [_num(float(pos.get("x", 0.0))),
			_num(float(pos.get("y", 0.0)))],
	])
	var data = spatial.data
	var group_id := str(data.component_group_id(component_id)) if data != null else ""
	if not group_id.is_empty():
		lines.append("Group: %d parts, anchor %s%s" % [
			data.group_member_ids(group_id).size(),
			str(data.group_anchor_id(group_id)),
			" (locked)" if data.is_group_locked(group_id) else ""])
	return lines


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
	# The row for the trace already in hand, WITHOUT the free-end scan: the card
	# shows none of it, and paying for it would weigh every pad, via, trace and
	# pour on the board against this trace's ends on every pointer move.
	var row: Dictionary = _PcbRegionDescribe.trace_row(data, trace, false)
	return PackedStringArray([
		trace_id,
		"Net: %s" % _or_dash(str(row.get("net", ""))),
		"Width: %s mm" % _num(float(row.get("width_mm", 0.0))),
		"Layer: %s" % _or_dash(str(row.get("layer", ""))),
		"Length: %s mm" % _num(_PcbTraceGeometry.length(
			_polyline(row.get("points", [])))),
	])


## A zone's card: id, kind, net, layer — the fields minerva_pcb_describe_zone
## answers with, read the same way (get_zone + zone_kind).
static func zone_lines(data, zone_id: String) -> PackedStringArray:
	if data == null or zone_id.is_empty():
		return PackedStringArray()
	var zone: Dictionary = data.get_zone(zone_id)
	if zone.is_empty():
		return PackedStringArray()
	return PackedStringArray([
		zone_id,
		"Kind: %s" % _or_dash(str(data.zone_kind(zone))),
		"Net: %s" % _or_dash(str(zone.get("net", ""))),
		"Layer: %s" % _or_dash(str(zone.get("layer", ""))),
	])


## A via's card: id, position, net, size, drill — read off the row
## pcb_region_describe.via_entry emits, which is what minerva_pcb_list_vias
## returns for that via. via_entry builds the board's copper index to answer
## span/touch, which the card does not show; the cost is paid once per hovered
## via, not per pointer move (the canvas derives content on entity change).
static func via_lines(data, via_id: String) -> PackedStringArray:
	if data == null or via_id.is_empty():
		return PackedStringArray()
	var via: Dictionary = data.get_via(via_id)
	if via.is_empty():
		return PackedStringArray()
	var row: Dictionary = _PcbRegionDescribe.via_entry(data, via)
	return PackedStringArray([
		via_id,
		"Position: (%s, %s) mm" % [_num(float(row.get("x_mm", 0.0))),
			_num(float(row.get("y_mm", 0.0)))],
		"Net: %s" % _or_dash(str(row.get("net_name", ""))),
		"Size: %s mm" % _num(float(row.get("size_mm", 0.0))),
		"Drill: %s mm" % _num(float(row.get("drill_mm", 0.0))),
	])


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
## FALLBACK, when no diagonal fits (a card larger than the space beside the
## cursor), in the order the two rules are given up:
##
##   1. the card is CLIPPED to the canvas on any axis it overflows, then its
##      origin clamped inside. Clamping alone cannot keep an oversized card in:
##      with `size > canvas` the only legal origin is 0 and the far edge still
##      overhangs, which is exactly what painted a card past the panel edge.
##      The returned rect is therefore never larger than the canvas, and callers
##      that assumed `rect.size == size` must read the rect instead.
##   2. if that still covers the pointer, the card is moved off it: a full gap
##      to whichever side has more room, else FLUSH against the pointer so it
##      sits on the card's edge rather than under its middle. A card that fills
##      the canvas outright cannot clear the pointer at all, and the flush
##      placement is the closest thing to obeying the rule that is left.
##
## Staying inside wins over covering nothing, because half a card is still
## readable while a card painted outside the panel is not painted at all.
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
	var fitted := Vector2(minf(size.x, canvas_size.x), minf(size.y, canvas_size.y))
	var span := Vector2(maxf(0.0, canvas_size.x - fitted.x),
		maxf(0.0, canvas_size.y - fitted.y))
	var clamped := Rect2(Vector2(clampf(right, 0.0, span.x),
		clampf(below, 0.0, span.y)), fitted)
	if not clamped.has_point(anchor):
		return clamped
	# Still over the pointer. Try a full gap to the roomier side, then flush
	# above it, then flush below it; the flush placements put the pointer on the
	# card's own edge, which is the best a nearly-canvas-sized card can do.
	var roomier := above if anchor.y > canvas_size.y * 0.5 else below
	var tops: Array[float] = [roomier, anchor.y - fitted.y, anchor.y]
	for y in tops:
		var candidate := Rect2(
			Vector2(clamped.position.x, clampf(y, 0.0, span.y)), fitted)
		if not candidate.has_point(anchor):
			return candidate
	clamped.position.y = clampf(anchor.y - fitted.y, 0.0, span.y)
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
