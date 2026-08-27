extends RefCounted
## Which sides of a pad a trace can reach it from, clear of the pad's own
## component's other pads.
##
## Board frame, y down: "north" is -y, "south" +y, "east" +x, "west" -x. A
## trace of `width` leaves the pad centred on the pad's own centre line and
## runs straight outward; a side is REACHABLE when no other pad of the same
## component lies in that outward strip, widened by `clearance` on each flank
## (the copper-to-copper rule), anywhere beyond the pad's edge. Foreign
## components are not consulted — a neighbour part is a routing obstacle, not
## a property of the pad.
##
## Lands are axis-aligned world rectangles here (a land's world AABB from
## pcb_component.get_pad_world_transform); a rotated land is judged by its box,
## which errs on the blocking side.
##
## Library module: static, pure, pinned with plain rectangles.

const SIDES := ["north", "east", "south", "west"]


## The sides of `pad` a `width` trace can leave from, clear of every rect in
## `others` by `clearance`. All four when `others` is empty.
static func approach_sides(pad: Rect2, others: Array, width: float, clearance: float) -> PackedStringArray:
	var out := PackedStringArray()
	var centre: Vector2 = pad.get_center()
	var half: float = maxf(0.0, width) * 0.5 + maxf(0.0, clearance)
	for side in SIDES:
		var blocked := false
		for raw in others:
			var other: Rect2 = raw
			if _blocks(str(side), pad, centre, half, other):
				blocked = true
				break
		if not blocked:
			out.append(str(side))
	return out


## Does `other` sit in the outward strip on `side`? The strip spans the pad's
## centre line +/- `half` across, and everything beyond the pad's edge along.
static func _blocks(side: String, pad: Rect2, centre: Vector2, half: float, other: Rect2) -> bool:
	match side:
		"north":
			return _spans(other.position.x, other.end.x, centre.x, half) \
				and other.position.y < pad.position.y
		"south":
			return _spans(other.position.x, other.end.x, centre.x, half) \
				and other.end.y > pad.end.y
		"west":
			return _spans(other.position.y, other.end.y, centre.y, half) \
				and other.position.x < pad.position.x
		"east":
			return _spans(other.position.y, other.end.y, centre.y, half) \
				and other.end.x > pad.end.x
	return false


## Does the interval [lo, hi] overlap the open strip (c - half, c + half)?
static func _spans(lo: float, hi: float, c: float, half: float) -> bool:
	return hi > c - half and lo < c + half


## A land's axis-aligned world BOX from the {position, size, rotation}
## pcb_component.get_pad_world_transform hands back: the box that contains the
## land at its world angle. Judging a turned land by its box errs on the
## blocking side, which is the side this module wants to err on.
##
## The angle is honoured HERE rather than by a width/height swap inside the
## transform, so an arbitrary land angle (and a negative component angle, which
## the old swap's `int(rotation) % 180 == 90` test missed) lands correctly.
static func land_rect(world: Dictionary) -> Rect2:
	var pos: Vector2 = world.get("position", Vector2.ZERO)
	var size: Vector2 = world.get("size", Vector2.ZERO)
	var half: Vector2 = size * 0.5
	var rot := deg_to_rad(-float(world.get("rotation", 0.0)))
	if is_zero_approx(sin(rot)) and is_zero_approx(cos(rot) - 1.0):
		return Rect2(pos - half, size)
	var extent := Vector2(
		absf(half.x * cos(rot)) + absf(half.y * sin(rot)),
		absf(half.x * sin(rot)) + absf(half.y * cos(rot)))
	return Rect2(pos - extent, extent * 2.0)


## approach_sides for pin `pin` of component `comp` at the board's `width` and
## `clearance`: the pin's own lands merged into one box against every land of
## the component's other pins. A pin with no land geometry (a bare point pin)
## is a zero-size box at its position.
static func pin_approach_sides(comp, pin: String, width: float, clearance: float) -> PackedStringArray:
	var mine: Array = []
	var others: Array = []
	for raw in comp.pads:
		var land: Dictionary = raw
		var rect: Rect2 = land_rect(comp.get_pad_world_transform(land))
		if str(land.get("number", "")) == pin:
			mine.append(rect)
		else:
			others.append(rect)
	var target: Rect2
	if mine.is_empty():
		target = Rect2(comp.get_pin_world_position(pin), Vector2.ZERO)
	else:
		target = mine[0]
		for r in mine:
			target = target.merge(r)
	return approach_sides(target, others, width, clearance)


## The board's rule pair for the reach test: the declared trace width (else
## the authored width) and the declared clearance.
static func board_rules(data) -> Array:
	var width: float = float(data.design_rule_trace_width())
	if width <= 0.0:
		width = float(data.authored_trace_width())
	return [width, float(data.design_rule_clearance())]
