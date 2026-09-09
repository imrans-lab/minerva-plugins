extends RefCounted
## Shared leader and label presentation for CAD annotation kinds.

# Visual constants — leader+box callout.
const _BOX_FILL := Color(0.08, 0.09, 0.11, 0.94)
const _BOX_STROKE := Color(0.55, 0.60, 0.68, 0.90)
const _TITLE_COLOR := Color(0.92, 0.94, 0.97, 1.0)
const _TEXT_COLOR := Color(0.86, 0.88, 0.92, 1.0)
const _LEADER_COLOR := Color(0.75, 0.80, 0.88, 0.85)
const _STALE_ALPHA: float = 0.35
const _TITLE_FONT_SIZE: int = 13
const _TEXT_FONT_SIZE: int = 12
const _BOX_PAD := Vector2(8.0, 6.0)
const _BOX_WIDTH: float = 200.0          # auto-wrap width incl. padding
const _LINE_SPACING: float = 2.0
const _ANCHOR_DOT_RADIUS: float = 3.5


static func draw(
	ctx: AnnotationRenderContext,
	anchor_screen: Vector2,
	box_screen: Vector2,
	title_text: String,
	text: String,
	is_stale: bool
) -> void:
	var alpha: float = _STALE_ALPHA if is_stale else 1.0
	var leader_color := Color(_LEADER_COLOR.r, _LEADER_COLOR.g, _LEADER_COLOR.b, _LEADER_COLOR.a * alpha)
	var fill_color := Color(_BOX_FILL.r, _BOX_FILL.g, _BOX_FILL.b, _BOX_FILL.a * alpha)
	var stroke_color := Color(_BOX_STROKE.r, _BOX_STROKE.g, _BOX_STROKE.b, _BOX_STROKE.a * alpha)
	var title_color := Color(_TITLE_COLOR.r, _TITLE_COLOR.g, _TITLE_COLOR.b, _TITLE_COLOR.a * alpha)
	var text_color := Color(_TEXT_COLOR.r, _TEXT_COLOR.g, _TEXT_COLOR.b, _TEXT_COLOR.a * alpha)

	var font: Font = ThemeDB.fallback_font

	# Layout: title line + wrapped body lines. Box width fixed at _BOX_WIDTH.
	var content_w: float = _BOX_WIDTH - _BOX_PAD.x * 2.0
	var body_lines: PackedStringArray = _wrap_text(font, text, _TEXT_FONT_SIZE, content_w)

	var title_h: float = float(_TITLE_FONT_SIZE)
	var body_line_h: float = float(_TEXT_FONT_SIZE) + _LINE_SPACING
	var has_body := not body_lines.is_empty() and body_lines[0] != ""
	var content_h: float = title_h
	if has_body:
		content_h += _LINE_SPACING + body_line_h * float(body_lines.size()) - _LINE_SPACING
	var box_size := Vector2(_BOX_WIDTH, content_h + _BOX_PAD.y * 2.0)
	var box_rect := Rect2(box_screen - box_size * 0.5, box_size)

	# Leader: from anchor_screen to nearest edge of the box rect (clipped).
	var leader_target: Vector2 = _clip_point_to_rect(anchor_screen, box_rect)
	ctx.draw_line(anchor_screen, leader_target, leader_color, 1.2)
	_draw_anchor_dot(ctx, anchor_screen, leader_color)

	# Box.
	ctx.draw_rect(box_rect, fill_color, true)
	ctx.draw_rect(box_rect, stroke_color, false, 1.0)

	# Title (top-center).
	if font != null:
		var title_w: float = font.get_string_size(
			title_text, HORIZONTAL_ALIGNMENT_LEFT, -1, _TITLE_FONT_SIZE
		).x
		var title_pos := Vector2(
			box_rect.position.x + (box_size.x - title_w) * 0.5,
			box_rect.position.y + _BOX_PAD.y + title_h - 2.0
		)
		ctx.draw_string(font, title_pos, title_text, title_color, _TITLE_FONT_SIZE)

		# Body lines (left-aligned under the title).
		if has_body:
			var y: float = box_rect.position.y + _BOX_PAD.y + title_h + _LINE_SPACING + body_line_h - 2.0
			for line in body_lines:
				var line_pos := Vector2(box_rect.position.x + _BOX_PAD.x, y)
				ctx.draw_string(font, line_pos, line, text_color, _TEXT_FONT_SIZE)
				y += body_line_h


static func _draw_anchor_dot(ctx: AnnotationRenderContext, pos: Vector2, color: Color) -> void:
	var segments := 10
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	for i in range(segments):
		var angle := TAU * float(i) / float(segments)
		pts.append(pos + Vector2(cos(angle), sin(angle)) * _ANCHOR_DOT_RADIUS)
		cols.append(color)
	if pts.size() >= 3:
		ctx.draw_polygon(pts, cols)


## Word-wrap `text` to fit within `width` pixels. Returns one entry per line.
## Greedy algorithm: fills each line with as many whitespace-separated tokens
## as fit. A single token longer than `width` overflows on its own line.
static func _wrap_text(font: Font, text: String, font_size: int, width: float) -> PackedStringArray:
	var out := PackedStringArray()
	if text == "":
		out.append("")
		return out
	if font == null:
		out.append(text)
		return out
	var words: PackedStringArray = text.split(" ", false)
	var current := ""
	for word in words:
		var trial: String = word if current == "" else current + " " + word
		var trial_w: float = font.get_string_size(
			trial, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size
		).x
		if trial_w <= width:
			current = trial
		else:
			if current != "":
				out.append(current)
			current = word
	if current != "":
		out.append(current)
	if out.is_empty():
		out.append("")
	return out


## Clip a point to the edge of a rect (for leader endpoint placement).
## When the point is outside the rect, returns the nearest point on the rect's
## border. When inside, returns the rect's center.
static func _clip_point_to_rect(p: Vector2, rect: Rect2) -> Vector2:
	if rect.has_point(p):
		return rect.get_center()
	var center := rect.get_center()
	var dir: Vector2 = (p - center)
	if dir.length_squared() < 0.0001:
		return center
	# Find intersection of the ray center→p with the rect border.
	var half := rect.size * 0.5
	var tx: float = INF
	if dir.x > 0.0001:
		tx = half.x / dir.x
	elif dir.x < -0.0001:
		tx = -half.x / dir.x
	var ty: float = INF
	if dir.y > 0.0001:
		ty = half.y / dir.y
	elif dir.y < -0.0001:
		ty = -half.y / dir.y
	var t: float = min(tx, ty)
	return center + dir * t


