extends RefCounted
## What a copper pour CONDUCTS: the one reader of a zone's compiled fill.
##
## Off-tree module — NO class_name, siblings reached by relative preload (see
## pcb_canvas.gd's port note). Every function here is STATIC and pure.
##
## A pour conducts as its COMPILED FILL, never as its authored outline. The
## outline is a request; the fill is what survives clearance carving, keepouts,
## cutouts and the board-edge inset, and those can cut one outline into regions
## that DO NOT conduct to each other. Reading the outline would credit joins the
## copper does not make.
##
## The fill's DECODING lives here rather than in any one consumer because two
## now ask the same question — the ratsnest (what is already joined?) and the
## Trace tool (may this click end the run?) — and a second decoder would be a
## second answer about one plane. The worker asks it too, from
## worker/pcb_worker/zone_copper.py, over the fill it computed itself.
##
## FILL IS DERIVED STATE, held only in memory and dropped whenever the board
## moves — see pcb_data.gd's ZONE_FILL_KEY, which is the only writer. A pour
## with no fill contributes NO connection: an unproven join stays an airwire
## rather than becoming a silent merge, and a fill kept past the board it
## describes would report a pad as already served when it is not.

const PcbCopperContact := preload("pcb_copper_contact.gd")


## Every filled region of `zone` as one conductor node each, on the zone's own
## layer. Empty for a pour with no fill, a computed-empty pour, a non-pour zone,
## or fill data this module refuses (see fill_regions).
static func region_nodes(zone: Dictionary) -> Array:
	var out: Array = []
	if not is_copper_pour(zone):
		return out
	for region in fill_regions(zone):
		out.append(PcbCopperContact.region_node(region,
			zone.get("layer", "top")))
	return out


## The net a zone is at. Zones spell it "net" (pcb_data.build_zone_payload);
## "net_name" is accepted as the fallback the other copper kinds use.
static func zone_net(zone: Dictionary) -> String:
	return str(zone.get("net", zone.get("net_name", "")))


## Is this zone a copper POUR (as opposed to a keepout, which emits no copper)?
## An unstated kind is a pour — the schema's own default. Mirrors
## pcb_data.zone_kind's normalisation, spelled here rather than called, because
## pcb_data preloads THIS module for its own free-end rule and a const preload
## cycle is a hard load error.
static func is_copper_pour(zone: Dictionary) -> bool:
	var kind := str(zone.get("kind", "")).strip_edges().to_lower()
	return kind.is_empty() or kind == "copper_pour"


## Does `copper` reach the filled copper of any pour on `net`? The question the
## Trace tool asks of a click, answered through the SAME predicate and the same
## node kinds the ratsnest and the connectivity DRC read — so a click the tool
## accepts as a landing lands on copper those two agree is joined.
##
## THE NET IS DECIDED HERE, not by the predicate. nodes_touch is net-blind (two
## pieces of copper either meet or they do not), so a caller that must not join
## two potentials has to say so, and this is where the Trace tool says it: a
## click in a FOREIGN plane is copper, but it is not this run's copper.
##
## Returns {id, layer, net} for the pour reached, or {} — the id so the caller
## can name what it landed on, and a Dictionary rather than a bare id so an
## id-less pour (its id is then "") still reports the hit.
static func pour_hit(zones, copper: Dictionary, net: String) -> Dictionary:
	if not (zones is Array) or net.is_empty():
		return {}
	for zone in (zones as Array):
		if not (zone is Dictionary):
			continue
		if zone_net(zone as Dictionary) != net:
			continue
		for region in region_nodes(zone as Dictionary):
			if PcbCopperContact.nodes_touch(copper, region as Dictionary):
				return {"id": str((zone as Dictionary).get("id", "")),
					"layer": str((zone as Dictionary).get("layer", "")),
					"net": net}
	return {}


## A pour's compiled fill regions, when the zone dict carries them: `fill` is an
## Array of regions, each an Array of {x_mm, y_mm} points — the same point
## encoding as the authored outline, one polygon ring per separately filled
## region. Returns them as PackedVector2Array polygons; empty when the fill is
## absent or legitimately produced no copper.
##
## DAMAGED FILL DATA IS NOT COPPER. Any damage anywhere in the fill — a region
## that is not an Array, a point that is not a finite-numbered {x_mm, y_mm}
## Dictionary, a ring that encloses no area — rejects the ENTIRE fill, intact
## sibling regions included: a fill that is partly wrong is a compile output
## that cannot be trusted, and treating any of it as copper could erase an
## airwire the board still needs. Rejection only ever KEEPS airwires.
static func fill_regions(zone: Dictionary) -> Array:
	var out: Array = []
	var fill = zone.get("fill")
	if not (fill is Array):
		return out
	for region in fill:
		var pts := _fill_region_ring(region)
		if pts.is_empty():
			return []
		out.append(pts)
	return out


## One fill region decoded into its polygon ring, or empty when the region is
## not usable as copper. Every point must be present, a Dictionary, and carry
## finite numeric x_mm AND y_mm — a damaged point is never repaired with a
## defaulted coordinate and never skipped, because either builds a
## plausible-looking shape out of data that no longer describes one. The ring
## must also enclose real area: a collinear or coincident ring is a line, not
## a region of copper.
##
## The area is judged on the payload's own numbers, BEFORE the reduction to
## Vector2: that reduction rounds each coordinate to the vector type's
## precision, and a shoelace sum over absolute board coordinates carries the
## rounding as cancellation noise that grows with the ring's distance from the
## origin — enough to lift a zero-area ring past the cutoff. The reduced points
## must remain finite too: a finite Float64 coordinate can overflow Vector2 and
## turn a bounded polygon into infinite geometry. See _ring_area_2x for how the
## sum is kept at the ring's own scale.
static func _fill_region_ring(region) -> PackedVector2Array:
	var empty := PackedVector2Array()
	if not (region is Array):
		return empty
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	for p in region:
		if not (p is Dictionary):
			return empty
		var x = (p as Dictionary).get("x_mm")
		var y = (p as Dictionary).get("y_mm")
		if not (_finite_number(x) and _finite_number(y)):
			return empty
		xs.append(float(x))
		ys.append(float(y))
	if xs.size() < 3:
		return empty
	# Less enclosed area than the coincidence tolerance can resolve is no
	# area at all.
	if _ring_area_2x(xs, ys) <= PcbCopperContact.TOUCH_EPS_MM * PcbCopperContact.TOUCH_EPS_MM:
		return empty
	var pts := PackedVector2Array()
	for i in xs.size():
		var point := Vector2(xs[i], ys[i])
		if not (is_finite(point.x) and is_finite(point.y)):
			return empty
		pts.append(point)
	return pts


static func _finite_number(v) -> bool:
	if v is int:
		return true
	return v is float and is_finite(v)


## Twice the area a ring encloses (shoelace), sign dropped. Every coordinate
## is translated to the ring's first point before it enters the sum, so the
## terms — and their float cancellation noise — scale with the ring's own
## extent rather than with where the ring sits on the board: the verdict is
## the same at any offset from the origin.
static func _ring_area_2x(xs: PackedFloat64Array, ys: PackedFloat64Array) -> float:
	var s := 0.0
	var n := xs.size()
	for i in n:
		var j := (i + 1) % n
		var ax := xs[i] - xs[0]
		var ay := ys[i] - ys[0]
		var bx := xs[j] - xs[0]
		var by := ys[j] - ys[0]
		s += ax * by - bx * ay
	return absf(s)
